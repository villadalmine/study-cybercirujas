# 2.4 Configuración de RBAC, Roles y Permisos de Kyverno

## 1. El problema en producción: el mínimo privilegio se cruza con la automatización de políticas

A Kyverno suele presentárselo como "el admission controller que se escribe en YAML", y para reglas `validate` puras ese modelo mental se sostiene — el trabajo ocurre al vuelo sobre el objeto `AdmissionReview` y Kyverno nunca toca el API server en tu nombre. En el momento en que una política hace algo *fuera* de la admission request, el panorama cambia por completo, y ahí es donde se origina la mayoría de los incidentes en producción.

Tres tipos de regla actúan sobre estado del clúster que no es el recurso bajo admisión:

- **`generate`** — Kyverno *crea* un recurso acompañante (una `NetworkPolicy` por defecto en cada namespace, un pull-secret en cada namespace de tenant, un `ResourceQuota`, etc.).
- **`mutate` con `targets:` (mutate-existing)** — Kyverno *parchea* recursos que ya existen y que no son el disparador.
- **`ClusterCleanupPolicy` / `CleanupPolicy`** — Kyverno *elimina* recursos según una planificación.

Cada una de estas operaciones la ejecuta un controlador de Kyverno actuando con su propia `ServiceAccount`, no como el usuario que la disparó. Y dado que **desde Kyverno 1.10 el proyecto entrega deliberadamente ServiceAccounts de mínimo privilegio** — el histórico permiso cercano a `cluster-admin` fue eliminado porque convertía a cada autor de políticas en un administrador de clúster de facto. La consecuencia, que el examen KCA evalúa directamente y que muerde a todo operador nuevo, es:

> Una regla `generate` o `mutate-existing` sobre un kind de recurso para el cual el controlador **no tiene RBAC** no falla en tiempo de admisión. El recurso disparador se admite normalmente, la política muestra `Ready: true`, y el efecto colateral simplemente nunca ocurre, en silencio. La falla vive en el status de un `UpdateRequest` y en una línea de log del controlador — en ningún lugar que un `kubectl get cpol` casual vaya a mostrar.

Configurar RBAC correctamente no es, por lo tanto, un endurecimiento opcional; es la diferencia entre una política que funciona y una política que miente sobre funcionar. Este tema trata la mecánica de esa configuración: qué controlador necesita qué permiso, cómo Kyverno extiende sus propios roles mediante la agregación nativa de ClusterRoles de Kubernetes, cómo acotar los permisos al menor radio de impacto posible, y cómo diagnosticar la falla silenciosa.

---

## 2. El modelo de controladores y dónde viven los permisos

Desde 1.10 Kyverno corre como **cuatro controladores independientes**, cada uno un `Deployment` separado con su propia `ServiceAccount` en el namespace `kyverno`. Separarlos es lo que hace posible el mínimo privilegio — el camino de admisión no carga poder de borrado, el camino de cleanup no carga poder de admisión.

| Controlador | ServiceAccount (`ns: kyverno`) | Clave de etiqueta de agregación | Responsable de | Típicamente necesita RBAC *extra* para… |
|---|---|---|---|---|
| Admission | `kyverno-admission-controller` | `rbac.kyverno.io/aggregate-to-admission-controller` | Webhooks de validación/mutación, evaluación de `context` | `get`/`list` sobre recursos referenciados por `apiCall` / `configMap` / `globalReference` en el contexto |
| Background | `kyverno-background-controller` | `rbac.kyverno.io/aggregate-to-background-controller` | `generate` y `mutate-existing`, reconciliación en segundo plano | `create`/`update`/`delete`/`get`/`list`/`watch` sobre cada **kind generado o mutado como target** |
| Reports | `kyverno-reports-controller` | `rbac.kyverno.io/aggregate-to-reports-controller` | Construir `PolicyReport` / `ClusterPolicyReport` | `get`/`list`/`watch` sobre los kinds que debe escanear (viene amplio por defecto) |
| Cleanup | `kyverno-cleanup-controller` | `rbac.kyverno.io/aggregate-to-cleanup-controller` | Ejecutar las planificaciones de `CleanupPolicy` | `list`/`watch`/`delete` sobre cada **kind objetivo de cleanup** |

### 2.1 Cómo Kyverno extiende sus propios permisos: agregación nativa de ClusterRoles

Kyverno no usa un sistema de permisos propio. Se apoya enteramente en los **ClusterRoles agregados de Kubernetes** (el `clusterrole-aggregation-controller` del `kube-controller-manager`). Para cada controlador entrega un *par* de ClusterRoles:

- `kyverno:<controller>` — una **cáscara de agregación**. Sus `rules:` están vacías en el manifiesto; lleva un `aggregationRule` que selecciona otros ClusterRoles por etiqueta.
- `kyverno:<controller>:core` — las reglas base que Kyverno necesita para sí mismo, con la etiqueta de agregación para que el controller-manager las pliegue dentro de la cáscara.

```console
$ kubectl get clusterroles | grep '^kyverno:'
kyverno:admission-controller             2024-06-11T09:20:14Z
kyverno:admission-controller:core        2024-06-11T09:20:14Z
kyverno:background-controller            2024-06-11T09:20:14Z
kyverno:background-controller:core       2024-06-11T09:20:14Z
kyverno:cleanup-controller               2024-06-11T09:20:14Z
kyverno:cleanup-controller:core          2024-06-11T09:20:14Z
kyverno:reports-controller               2024-06-11T09:20:14Z
kyverno:reports-controller:core          2024-06-11T09:20:14Z
kyverno:rbac:admin:policies              2024-06-11T09:20:14Z
kyverno:rbac:admin:policyreports         2024-06-11T09:20:14Z
kyverno:rbac:admin:reports               2024-06-11T09:20:14Z
kyverno:rbac:view:policies               2024-06-11T09:20:14Z
kyverno:rbac:view:policyreports          2024-06-11T09:20:14Z
```

Inspeccionar la cáscara muestra el selector de agregación y las reglas *pobladas* que el controller-manager copió desde cada rol coincidente:

```console
$ kubectl get clusterrole kyverno:background-controller -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller
  labels:
    app.kubernetes.io/part-of: kyverno
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:                       # <-- filled in by kube-controller-manager, do not edit
- apiGroups: ["kyverno.io"]
  resources: ["updaterequests","updaterequests/status","policies","clusterpolicies"]
  verbs: ["create","delete","get","list","patch","update","watch","deletecollection"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get","list","watch"]
# ...core rules only; note: no networkpolicies, no secrets, no configmaps update
```

**El patrón que vas a usar todo el tiempo:** para otorgarle un permiso nuevo a un controlador, nunca editás `kyverno:<controller>` (el controller-manager sobrescribe sus `rules`) ni editás `:core` (el próximo upgrade de Helm lo sobrescribe). Creás un ClusterRole **nuevo** que lleve la etiqueta de agregación correcta. El controller-manager detecta la etiqueta y pliega tus reglas dentro de la cáscara automáticamente en cuestión de segundos. Este es el hecho operativo más importante de este tema.

### 2.2 La otra agregación: exponer los CRDs de Kyverno a roles humanos

Por separado, Kyverno agrega sus CRDs a los **ClusterRoles integrados `admin`/`edit`/`view` de Kubernetes** usando las etiquetas estándar `rbac.authorization.k8s.io/aggregate-to-*`, de modo que un `admin` de namespace pueda gestionar objetos `Policy` namespaced y reportes sin un permiso a medida:

```console
$ kubectl get clusterrole kyverno:rbac:admin:policies -o yaml | yq '.metadata.labels'
app.kubernetes.io/part-of: kyverno
rbac.authorization.k8s.io/aggregate-to-admin: "true"
rbac.authorization.k8s.io/aggregate-to-edit: "true"
```

Mantené los dos espacios de agregación bien diferenciados — responden preguntas distintas:

| Prefijo de etiqueta | Agrega hacia | Responde |
|---|---|---|
| `rbac.kyverno.io/aggregate-to-*` | ClusterRoles de los controladores de Kyverno | "¿Qué pueden hacerle al clúster las ServiceAccounts de Kyverno?" |
| `rbac.authorization.k8s.io/aggregate-to-*` | Los integrados `admin`/`edit`/`view` | "¿Qué pueden hacerle *los humanos* a los objetos de Kyverno?" |

---

## 3. Enfoques comparados para otorgarle un permiso a un controlador

Hay más de una forma de darle al background controller `create networkpolicies`. No son equivalentes en radio de impacto ni en seguridad frente a upgrades.

| Enfoque | Cómo | Radio de impacto | ¿Sobrevive upgrades? | Cuándo usarlo |
|---|---|---|---|---|
| **ClusterRole agregado** (recomendado) | Nuevo ClusterRole con `rbac.kyverno.io/aggregate-to-background-controller: "true"` | Todo el clúster para ese kind | ✅ sobrevive a los upgrades de Helm | Opción por defecto; la política aplica a muchos/todos los namespaces |
| **Role namespaced + RoleBinding** | `Role` en un namespace vinculado a la SA del controlador | Un solo namespace | ✅ | Generate/mutate confinado a uno o pocos namespaces de tenants; el alcance más ajustado |
| **Parchear el rol `:core`** | Editar `kyverno:background-controller:core` in situ | Todo el clúster | ❌ lo sobrescribe el próximo `helm upgrade` | Nunca en producción |
| **Parchear la cáscara de agregación** | Editar las `rules` de `kyverno:background-controller` | — | ❌ el controller-manager lo sobrescribe en segundos | Nunca — ni siquiera persiste |
| **Permiso comodín** (`*/*`) | ClusterRole con `apiGroups/resources/verbs: ["*"]` + etiqueta | Todo | ✅ (técnicamente) | Nunca — reintroduce la superficie de escalación de privilegios previa a 1.10 |

**Resumen del trade-off.** Preferí el *Role/RoleBinding namespaced* siempre que los targets de la política vivan en un conjunto conocido de namespaces — es la única opción que acota el poder del controlador al lugar donde la política efectivamente actúa, algo enormemente importante para kinds sensibles como `secrets`, `roles` y `serviceaccounts`. Recurrí al *ClusterRole agregado* cuando la política es genuinamente de alcance global (por ejemplo, una `NetworkPolicy` por defecto en cada namespace). Todo lo demás es o no persistente, o una mina para el próximo upgrade.

---

## 4. Manifiestos completos

### 4.1 Una política `generate` y el RBAC que requiere

El caso clásico: imponer una `NetworkPolicy` default-deny en cada namespace.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-networkpolicy
spec:
  # generate rules are inherently background work; they must be able to run
  background: true
  # also reconcile namespaces that already existed when the policy was created
  generateExisting: true
  rules:
  - name: default-deny-per-namespace
    match:
      any:
      - resources:
          kinds:
          - Namespace
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
          - kube-node-lease
          - kyverno
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny
      namespace: "{{ request.object.metadata.name }}"
      synchronize: true         # keep the generated object in lock-step with the source
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
```

Aplicada sobre una instalación recién hecha de Kyverno, esto **no hace nada** — el background controller no puede crear `NetworkPolicy`. El permiso requerido, como ClusterRole agregado:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:generate-networkpolicies
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups:
  - networking.k8s.io
  resources:
  - networkpolicies
  # synchronize:true means the controller must also reconcile & tear down,
  # so update/delete are mandatory, not just create
  verbs:
  - create
  - update
  - delete
  - get
  - list
  - watch
```

> **Regla práctica sobre los verbos.** `create` por sí solo alcanza únicamente para un generate de una sola vez con `synchronize: false`. Con `synchronize: true` (la elección habitual) tenés que agregar `update`, `delete`, `get`, `list`, `watch`, porque ahora el controlador es dueño del ciclo de vida del objeto generado.

### 4.2 Una política `mutate-existing` y su RBAC

Se dispara con un namespace y estampa una etiqueta de gestión en cada `ConfigMap` que ya esté dentro de él.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: label-existing-configmaps
spec:
  background: true
  # re-run against existing targets whenever this policy is created/updated
  mutateExistingOnPolicyUpdate: true
  rules:
  - name: stamp-managed-by
    match:
      any:
      - resources:
          kinds:
          - Namespace
    mutate:
      targets:
      - apiVersion: v1
        kind: ConfigMap
        namespace: "{{ request.object.metadata.name }}"
      patchStrategicMerge:
        metadata:
          labels:
            managed-by: kyverno
```

Permiso requerido (background controller — mutate-existing corre ahí, *no* en el admission controller):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "update"]   # no create/delete needed for a patch
```

### 4.3 Acotar el permiso a un solo namespace (patrón de mínimo privilegio)

Si una política solo genera `Secret`s en `team-a`, **no** le des al background controller la creación de secrets en todo el clúster. Vinculá en cambio un `Role` namespaced — es la opción más ajustada y la que hay que elegir para kinds sensibles.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kyverno:generate-secrets
  namespace: team-a
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update", "delete", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kyverno:generate-secrets
  namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kyverno:generate-secrets
subjects:
- kind: ServiceAccount
  name: kyverno-background-controller
  namespace: kyverno
```

Como un `RoleBinding` otorga permisos únicamente dentro de su propio namespace, el controlador ahora puede escribir secrets en `team-a` y en ningún otro lado — aun cuando el objeto `ClusterPolicy` en sí tenga alcance de clúster. Las etiquetas de agregación **no tienen ningún efecto** acá; el acotamiento por namespace se logra puramente a través del subject del `RoleBinding`.

### 4.4 Una `CleanupPolicy` y el RBAC del cleanup controller

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: remove-empty-configmaps
spec:
  match:
    any:
    - resources:
        kinds:
        - ConfigMap
  conditions:
    all:
    - key: "{{ target.data | length(@) || `0` }}"
      operator: Equals
      value: 0
  schedule: "*/10 * * * *"
```

El cleanup controller tiene que poder *encontrar* y *eliminar* el kind objetivo:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "delete"]
```

### 4.5 Un `context` en tiempo de admisión que necesita RBAC de lectura

Una regla `validate` que consulta el estado vivo del clúster mediante `apiCall` corre en el **admission controller**, así que el permiso va a ese controlador — un detalle que se pasa por alto con frecuencia porque la política "se siente" como validación pura.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-unique-ingress-host
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-duplicate-host
    match:
      any:
      - resources:
          kinds: ["Ingress"]
    context:
    - name: existingIngresses
      apiCall:
        urlPath: "/apis/networking.k8s.io/v1/ingresses"
        jmesPath: "items[].spec.rules[].host"
    validate:
      message: "Ingress host must be unique across the cluster."
      deny:
        conditions:
          any:
          - key: "{{ request.object.spec.rules[].host }}"
            operator: AnyIn
            value: "{{ existingIngresses }}"
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:read-ingresses
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list"]
```

Sin este permiso el `apiCall` falla, y según el `failurePolicy` el webhook o bien **bloquea todas las admisiones de Ingress** (`Fail`) o bien saltea la verificación en silencio (`Ignore`) — ambos son incidentes de producción con la misma causa raíz.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La herramienta principal: impersonación con `kubectl auth can-i`

Esta es la comprobación más rápida y decisiva. Hacé exactamente la pregunta que hará el controlador, *como* la ServiceAccount del controlador, en el namespace objetivo.

```console
# Before applying the aggregated ClusterRole from 4.1:
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n default
no

# After applying it (aggregation propagates in a few seconds):
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n default
yes
```

El subject de impersonación es siempre `system:serviceaccount:<namespace>:<sa-name>`. Auditá el conjunto *completo* de permisos efectivos de un controlador con:

```console
$ kubectl auth can-i --list \
    --as=system:serviceaccount:kyverno:kyverno-background-controller | head
Resources                                Non-Resource URLs   Resource Names   Verbs
updaterequests.kyverno.io                []                  []               [create delete get list ...]
networkpolicies.networking.k8s.io        []                  []               [create update delete get ...]
namespaces                               []                  []               [get list watch]
...
```

### 5.2 Confirmar que la agregación efectivamente tuvo efecto

Un error común es un typo en la clave de la etiqueta, o un valor `true` (booleano) en lugar de `"true"` (string). Verificá que el controller-manager haya plegado tus reglas:

```console
$ kubectl get clusterrole kyverno:background-controller -o yaml \
    | yq '.rules[] | select(.resources[] == "networkpolicies")'
apiGroups: ["networking.k8s.io"]
resources: ["networkpolicies"]
verbs: ["create","update","delete","get","list","watch"]
```

Si esto no devuelve nada pero tu rol independiente claramente tiene la regla, la etiqueta está mal. Compará directamente:

```console
$ kubectl get clusterrole kyverno:generate-networkpolicies \
    -o jsonpath='{.metadata.labels}' | jq
{
  "app.kubernetes.io/part-of": "kyverno",
  "rbac.kyverno.io/aggregate-to-background-controller": "true"
}
```

### 5.3 Leer la falla donde realmente vive

Las operaciones de generate y mutate-existing fluyen a través de recursos personalizados `UpdateRequest` en el namespace `kyverno`. Una verificación de RBAC fallida aparece ahí y en el log del controlador — no en el status de la política.

```console
$ kubectl -n kyverno get updaterequests
NAME          POLICY                       RULETYPE   RESOURCEKIND   RESOURCENAME   STATE
ur-7bkq2      add-default-networkpolicy    generate   Namespace      default        Failed

$ kubectl -n kyverno get updaterequest ur-7bkq2 -o jsonpath='{.status.state}: {.status.message}{"\n"}'
Failed: networkpolicies.networking.k8s.io is forbidden: User "system:serviceaccount:kyverno:kyverno-background-controller" cannot create resource "networkpolicies" in API group "networking.k8s.io" in the namespace "default"
```

```console
$ kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i forbidden
E0611 ... "failed to process update request" err="networkpolicies.networking.k8s.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"networkpolicies\" in API group \"networking.k8s.io\" in the namespace \"default\"" policy="add-default-networkpolicy"
```

Para una falla de `context` en tiempo de admisión (§4.5), mirá el admission controller y, si `failurePolicy: Fail`, el rechazo del webhook que ve el usuario:

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i "apiCall\|forbidden"
ERROR ... failed to execute APICall ... ingresses.networking.k8s.io is forbidden: ... cannot list resource "ingresses"

$ kubectl apply -f new-ingress.yaml
Error from server: error when creating "new-ingress.yaml": admission webhook "validate.kyverno.svc-fail"
denied the request: failed to load context: failed to execute APICall for context entry existingIngresses
```

### 5.4 Tabla de referencia de modos de falla

| Síntoma | Causa raíz | Dónde se manifiesta | Solución |
|---|---|---|---|
| La regla `generate` no crea nada, la política figura `Ready` | Al background controller le falta `create` (y/o los verbos de ciclo de vida) sobre el kind objetivo | `UpdateRequest` en `Failed`; log del background-controller con `forbidden` | Agregar un ClusterRole a **background** (§4.1) o un Role namespaced (§4.3) |
| `mutate-existing` no hace nada | Al background controller le falta `update`/`get`/`list` sobre el target | Igual que arriba | Agregar a **background** (§4.2) |
| El objeto generado deriva / no se limpia | `synchronize: true` pero faltan `update`/`delete` | log del background-controller | Agregar los verbos de ciclo de vida al rol |
| La `CleanupPolicy` deja recursos atrás | Al cleanup controller le falta `delete`/`list` sobre el target | log del cleanup-controller | Agregar a **cleanup** (§4.4) |
| La admisión de Ingress/Pod se bloquea de golpe | El `context` con `apiCall` falla, `failurePolicy: Fail` | log del admission-controller; denegación del webhook al usuario | Agregar los verbos de lectura a **admission** (§4.5) |
| Las reglas del rol agregado nunca aparecen | Clave de etiqueta incorrecta, o `true` booleano en vez de `"true"` string, o falta `part-of` | `kubectl get clusterrole kyverno:<c>` no muestra reglas nuevas | Corregir la etiqueta exactamente (§5.2) |
| Un humano no puede editar `Policy` namespaced | La agregación del CRD hacia `admin` fue eliminada o sobrescrita | `kubectl auth can-i` como ese usuario | Restaurar la etiqueta `rbac.authorization.k8s.io/aggregate-to-admin` |

---

## 6. Endurecimiento de seguridad: RBAC es la superficie de escalación de privilegios

Los controladores de Kyverno corren continuamente con lo que sea que les agregues, y sus acciones se disparan por *eventos de recursos ordinarios*. Eso hace que el exceso de permisos sea un camino de escalación real, no teórico:

- **Nunca** le otorgues al background controller `create`/`update` amplios sobre `secrets`, `serviceaccounts`, `roles`, `rolebindings`, `clusterroles` o `clusterrolebindings` en un clúster multi-tenant. Si una política que genera esos objetos puede ser disparada por la acción de un usuario de bajo privilegio (por ejemplo, crear un namespace o un `ConfigMap`), ese usuario tomó prestado, en los hechos, el poder del controlador. Acotá esto con **`RoleBinding`s namespaced** (§4.3) y auditalos explícitamente.
- **Nunca** agregues un rol con comodín `*/*/*`. Revierte por completo el sentido del rediseño de mínimo privilegio con controladores separados de 1.10 y devuelve a Kyverno a ser un daemon equivalente a cluster-admin. Auditalo: `kubectl auth can-i --list --as=system:serviceaccount:kyverno:kyverno-background-controller` nunca debería leerse como `cluster-admin`.
- **Controlá quién puede escribir políticas.** Como `kyverno:rbac:admin:policies` agrega la gestión de `Policy` namespaced al rol integrado `admin`, cualquier administrador de namespace puede escribir una `Policy`. Combinado con un permiso generoso en el controlador, eso es un vector de escalación. Revisá qué humanos tienen `admin` y si los permisos del controlador sobre kinds sensibles están acotados por namespace.
- **Hacé coincidir el `failurePolicy` con el permiso del contexto.** Un `context` que necesita RBAC más `failurePolicy: Fail` significa que un permiso faltante es una caída a nivel de clúster para ese kind de recurso; un permiso faltante más `Ignore` significa un bypass de seguridad silencioso. Decidilo deliberadamente, y verificá que la SA de admisión tenga el permiso de lectura antes de publicar.
- **Diffeá los roles entregados después de cada upgrade.** `helm upgrade` vuelve a renderizar `:core` y las cáscaras; tus roles *agregados* adicionales quedan intactos (ese es el punto), pero confirmá que el contrato de etiquetas no haya cambiado volviendo a correr la verificación de §5.2 después del upgrade.

---

## 7. Referencias

- Kyverno — Installation, *Roles and Permissions / Customizing Permissions*: <https://kyverno.io/docs/installation/customization/>
- Kyverno — *Generate Rules* (RBAC del background controller, `synchronize`, `generateExisting`): <https://kyverno.io/docs/writing-policies/generate/>
- Kyverno — *Mutate Existing Resources* (`targets`, `mutateExistingOnPolicyUpdate`): <https://kyverno.io/docs/writing-policies/mutate/#mutate-existing-resources>
- Kyverno — *Cleanup Policies* (`ClusterCleanupPolicy`, cleanup controller): <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — *High Availability & Architecture* (los cuatro controladores y sus ServiceAccounts): <https://kyverno.io/docs/high-availability/>
- Kyverno — *Troubleshooting* (estados de `UpdateRequest`, logs de los controladores): <https://kyverno.io/docs/troubleshooting/>
- Kubernetes — *Using RBAC Authorization → Aggregated ClusterRoles*: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles>
- Kubernetes — *Authenticating → ServiceAccount user names & impersonation* (`system:serviceaccount:<ns>:<name>`): <https://kubernetes.io/docs/reference/access-authn-authz/authentication/#service-account-tokens>
- CNCF — *Kyverno Certified Associate (KCA) Curriculum*: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>