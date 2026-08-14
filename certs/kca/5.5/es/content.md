# 5.5 Reglas de generación

> **Dominio 5 — Escritura de políticas** · Peso en el examen: **2,91 %**
> Aplica a `kyverno.io/v1` / `kyverno.io/v2beta1` `ClusterPolicy` y `Policy`, `spec.rules[].generate`.

---

## 1. El problema arquitectónico

Toda plataforma Kubernetes multi-tenant choca contra el mismo muro el primer día: **un `Namespace` es una caja vacía**. El API server lo va a crear sin ningún reparo con cero NetworkPolicies, cero ResourceQuota, sin LimitRange, sin credenciales de descarga de imágenes y sin RBAC. Desde el momento en que `kubectl create ns team-payments` retorna hasta que una persona o un pipeline provisiona las barreras de seguridad, ese namespace es un radio de impacto ilimitado y totalmente conectado sentado dentro del clúster.

Los remedios clásicos tienen todos alguna fuga:

| Enfoque | Dónde se rompe en producción |
|---|---|
| Plantilla de namespace en Helm/Kustomize, aplicada por CI | Solo cubre los namespaces creados *a través* del pipeline. Cualquiera con RBAC de `create namespace` lo evita por completo. |
| GitOps app-of-apps (Argo CD / Flux) por tenant | Correcto, pero la latencia de aprovisionamiento es un ciclo completo de reconciliación; además requiere un commit en Git por cada namespace, lo que no compone con portales de autoservicio. |
| Controlador / operador propio | Correcto y rápido, pero ahora sos dueño de un controlador: elección de líder, caché de informers, reintentos/backoff, RBAC, actualizaciones, observabilidad. Semanas de trabajo para copiar una `NetworkPolicy`. |
| Hierarchical Namespace Controller (HNC), Capsule | Sólidos para jerarquía y propagación, pero son un segundo plano de control opinado, con sus propios CRDs y su propio modelo de tenancy. |
| Regla `validate` que *rechaza* namespaces sin NetworkPolicy | Imposible: la NetworkPolicy no puede existir antes que el namespace donde vive. La validación solo puede prohibir, nunca provisionar. |

Una **regla de generación** de Kyverno colapsa todo esto en un objeto de política declarativo: *cuando aparece un recurso que coincide con X, asegurá que exista un recurso Y y, opcionalmente, mantené Y convergente para siempre.* Es un controlador que escribís en YAML, ejecutándose dentro de un controlador que ya operás para validación y mutación.

El segundo problema que resuelve es el **drift**. `synchronize: true` convierte la regla de un bootstrap de una sola vez en un bucle de reconciliación continua sobre el objeto generado. Una persona desarrolladora que borra la NetworkPolicy `default-deny` para depurar conectividad la recupera dentro de un intervalo de reconciliación, sin llamada al buscapersonas y sin un revert en Git.

El tercero — y el que la mayoría de los equipos descubre tarde — es la **configuración con fan-out**. Cambiás el bloque `data` en una política y todas las copias derivadas convergen a lo largo de 3000 namespaces. Eso es un apalancamiento enorme, y es exactamente tan peligroso como suena; §10 cubre los controles de radio de impacto.

---

## 2. Dónde se ejecuta realmente una regla generate

Este es el modelo mental más importante para el examen y para las guardias. **Una regla generate no corre en el webhook de admisión.** No forma parte de la transacción de admisión del disparador.

```
                      ┌──────────────────────────────────────────────────────────┐
  kubectl create ns   │                     kube-apiserver                       │
  team-payments  ───► │  auth ─► mutating admission ─► validating admission ─► etcd
                      └────────────┬──────────────────────────┬──────────────────┘
                                   │ AdmissionReview          │ watch
                                   ▼                          │
                      ┌────────────────────────┐              │
                      │ kyverno-admission-     │              │
                      │ controller (webhook)   │              │
                      │  • evaluates match/    │              │
                      │    exclude/precondition│              │
                      │  • creates an          │              │
                      │    UpdateRequest (UR)  │              │
                      └────────────┬───────────┘              │
                                   │ CREATE ur-xxxxx          │
                                   ▼   (ns: kyverno)          │
                      ┌────────────────────────┐              │
                      │ UpdateRequest CR       │◄─────────────┘
                      │ spec.type: generate    │
                      │ status.state: Pending  │
                      └────────────┬───────────┘
                                   │ informer
                                   ▼
                      ┌────────────────────────┐
                      │ kyverno-background-    │  resolves context/variables
                      │ controller             │  renders data|clone|cloneList
                      │  (SA: kyverno-         │  CREATE/UPDATE downstream
                      │   background-controller│  writes status.generatedResources
                      └────────────┬───────────┘
                                   │
                                   ▼
                      NetworkPolicy/team-payments/default-deny-ingress
                      labels: generate.kyverno.io/policy-name=...
                              generate.kyverno.io/trigger-name=...
```

De este diseño se desprenden cuatro consecuencias, y cada una es un incidente esperando a ocurrir si no las interiorizás:

1. **La generación es eventualmente consistente.** La llamada `create namespace` retorna `Created` antes de que la NetworkPolicy exista. Un pipeline que crea un namespace e inmediatamente agenda Pods tiene una ventana de carrera real y reproducible (típicamente de decenas a cientos de milisegundos, pero no acotada cuando el controlador de background está saturado).
2. **La identidad es la del controlador de background, no la del usuario.** El recurso derivado lo escribe `system:serviceaccount:kyverno:kyverno-background-controller`. Si esa ServiceAccount carece de RBAC para el tipo de destino, el disparador igual tiene éxito y la generación falla silenciosamente dentro del estado del UR. Kyverno **no puede otorgar lo que él mismo no posee**: la prevención de escalada de privilegios del API server se le aplica como a cualquier otro sujeto.
3. **Las fallas son asíncronas y, por lo tanto, invisibles para el usuario.** `kubectl create ns` imprime éxito. La falla vive en `UpdateRequest.status`, en un Event de Kubernetes sobre el disparador y en el log del controlador de background. Alertá sobre los tres.
4. **Registrar una regla generate pone a Kyverno en el camino de admisión del tipo disparador.** Una regla que coincide con `Namespace` hace que Kyverno agregue `namespaces` a su webhook de recursos. Con `failurePolicy: Fail`, una caída de Kyverno ahora bloquea la creación de namespaces en todo el clúster. Es un trade-off deliberado: elegilo conscientemente.

### Por qué labels y no `ownerReferences`

Kyverno vincula los recursos derivados con su disparador mediante **labels**, no mediante owner references, y reimplementa la semántica de borrado por su cuenta. Eso no es pereza; el recolector de basura de Kubernetes prohíbe la topología que generate necesita:

| Propietario | Dependiente | ¿Legal? | Comportamiento del GC |
|---|---|---|---|
| De alcance de clúster (p. ej. `Namespace`) | Con namespace (p. ej. `NetworkPolicy`) | Sí | Borrado en cascada normal |
| Con namespace, **mismo** namespace | Con namespace | Sí | Borrado en cascada normal |
| Con namespace, **distinto** namespace | Con namespace | **No** | Se trata como inválido; el dependiente es **borrado** y se emite un evento `OwnerRefInvalidNamespace` |
| Con namespace | De alcance de clúster | **No** | La owner reference es irresoluble; el dependiente nunca se recolecta |

Una regla `clone` que copia `platform-system/harbor-pull-secret` dentro de `team-payments` es precisamente la tercera fila. Si Kyverno hubiera usado owner references, el API server habría borrado cada Secret generado poco después de crearlo. De ahí el contrato de labels:

```
app.kubernetes.io/managed-by:                  kyverno
generate.kyverno.io/policy-name:               sync-registry-credentials
generate.kyverno.io/policy-namespace:          ""            # empty for ClusterPolicy
generate.kyverno.io/rule-name:                 clone-pull-secret
generate.kyverno.io/trigger-group:             ""
generate.kyverno.io/trigger-version:           v1
generate.kyverno.io/trigger-kind:              Namespace
generate.kyverno.io/trigger-name:              team-payments
generate.kyverno.io/trigger-namespace:         ""
```

Estos labels son la **única** clave de unión entre política, disparador y recurso derivado. Si los quitás (un overlay bienintencionado de `commonLabels` de Kustomize lo hará), Kyverno pierde la capacidad de sincronizar o limpiar ese objeto. Tratalos como un espacio de nombres de claves de label protegido.

> **Nota de versiones.** Los conjuntos de claves de label y las versiones de la API `UpdateRequest` cambiaron entre releases (`GenerateRequest` → `UpdateRequest`; `kyverno.io/v1beta1` → `kyverno.io/v2`). Confirmá contra `kubectl explain updaterequest.spec` en el clúster que estés operando.

---

## 3. Superficie de la API

```yaml
rules:
  - name: <string>                     # required, unique within the policy
    match: {...}                       # selects the TRIGGER, not the downstream
    exclude: {...}
    preconditions: {...}               # JMESPath gate, evaluated before generation
    context: [...]                     # configMap | apiCall | variable | imageRegistry | globalReference
    generate:
      apiVersion: <group/version>      # downstream API version
      kind: <Kind>                     # downstream kind
      name: <string>                   # downstream name (variables allowed)
      namespace: <string>              # downstream namespace (omit for cluster-scoped)
      synchronize: <bool>              # default false
      orphanDownstreamOnPolicyDelete: <bool>   # default false  (>= 1.10)
      generateExisting: <bool>         # rule-level backfill      (newer releases)

      # exactly ONE of the following payload sources:
      data: {...}                      # inline definition
      clone:                           # copy one existing resource
        namespace: <string>
        name: <string>
      cloneList:                       # copy N existing resources by selector
        namespace: <string>
        kinds: [<group/version/Kind>, ...]
        selector: {matchLabels: {...}}
      foreach:                         # loop over a list (>= 1.11)
        - list: <jmespath>
          apiVersion: ...
          kind: ...
          name: ...
          namespace: ...
          data|clone|cloneList: ...
```

Campos a nivel de `spec` que cambian el comportamiento de generate:

| Campo | Efecto |
|---|---|
| `spec.background` | Debe ser `true` para `generateExisting` y para la reconciliación en background. Kyverno rechaza `background: true` en reglas que referencian `{{request.userInfo.*}}` / `{{request.roles}}` / `{{serviceAccountName}}`, porque esos datos no existen fuera de un AdmissionReview. |
| `spec.generateExisting` | Aplica la regla a recursos que ya existían cuando la política fue creada/actualizada. Nombre antiguo: `spec.generateExistingOnPolicyUpdate`. |
| `spec.failurePolicy` | `Fail` (por defecto) hace que una caída de Kyverno bloquee la admisión *del disparador*. `Ignore` cambia enforcement por disponibilidad. |
| `spec.schemaValidation` | Kyverno valida el bloque `data` contra el esquema OpenAPI del CRD de destino donde esté disponible. |

Dos reglas de alcance duras que vale la pena memorizar:

- **Una `Policy` con namespace solo puede generar dentro de su propio namespace.** La generación entre namespaces requiere una `ClusterPolicy`.
- **`match` describe el disparador.** Un error muy común entre principiantes es escribir `match: kinds: [NetworkPolicy]` cuando la intención es "generar una NetworkPolicy para cada Namespace". El disparador es el `Namespace`.

---

## 4. Fuente del payload: `data` vs `clone` vs `cloneList`

| Dimensión | `data` | `clone` | `cloneList` |
|---|---|---|---|
| Fuente de verdad | El propio manifiesto de la política | Un recurso vivo en el clúster | N recursos vivos seleccionados por labels |
| Interpolación de variables | Completa (`{{request.*}}`, contexto) | Ninguna — copia literal | Ninguna — copia literal |
| Agregar labels/anotaciones al derivado | Sí, en línea | **No** — `data` y `clone` son mutuamente excluyentes | **No** |
| Material secreto en Git | Presente en la política → **no usar para Secrets** | Se queda en el clúster (o en tu destino de sincronización ESO/Vault) | Igual |
| Historia de rotación | Editás la política → fan-out | Actualizás el Secret origen → fan-out (con `synchronize: true`) | Igual |
| Nombre del derivado | Explícito, puede ser plantillado | Heredado del origen | Heredado de cada origen |
| Cantidad de derivados por disparador | 1 (o N con `foreach`) | 1 | N (cardinalidad del selector) |
| Uso típico | NetworkPolicy, ResourceQuota, LimitRange, RoleBinding, ConfigMap | `imagePullSecret`, bundle de CA, Secret TLS wildcard | "propagar todo lo etiquetado con `propagate=true`" |

Heurística de decisión usada en la práctica:

- El contenido **se deriva del disparador** (nombre del namespace, label de tier del tenant, anotación) → `data`.
- El contenido es **sensible o rotado por otro sistema** (External Secrets Operator, cert-manager, Vault) → `clone`, y dejá que el otro sistema sea dueño del origen.
- El conjunto de cosas a propagar es **abierto y gestionado por el equipo de plataforma mediante labels** → `cloneList`.

> **`clone` requiere que el controlador de background pueda hacer `get`/`list`/`watch` sobre el origen.** Si el origen vive en un namespace excluido por los `resourceFilters` del ConfigMap `kyverno`, el clon fallará o nunca se resincronizará. Esta es la causa número uno de "el Secret se creó una vez y nunca más se actualizó".

---

## 5. Semántica de sincronización — la tabla de estados completa

`synchronize` es el campo que decide si escribiste un script de bootstrap o un controlador. Aprendete esta tabla de memoria.

| Evento | `synchronize: false` | `synchronize: true` |
|---|---|---|
| Disparador creado (coincide) | Derivado creado | Derivado creado |
| Disparador actualizado, sigue coincidiendo | Sin efecto | Derivado re-reconciliado desde el origen/data actual |
| Disparador actualizado, **ya no** coincide (label eliminado) | Derivado queda en su lugar | Derivado **eliminado** |
| Disparador eliminado | Derivado queda en su lugar | Derivado **eliminado** |
| Derivado mutado por un usuario | El drift persiste para siempre | Revertido al estado deseado de la política |
| Derivado eliminado por un usuario | No se recrea | Se recrea |
| Recurso origen del `clone` actualizado | El derivado queda obsoleto | El derivado se actualiza para coincidir con el origen |
| Recurso origen del `clone` eliminado | El derivado permanece | La reconciliación da error; el derivado **no** se elimina automáticamente |
| Bloque `data` de la política editado | Solo los derivados *nuevos* reciben el contenido nuevo | **Todos** los derivados se actualizan (fan-out) |
| Regla eliminada / política eliminada | El derivado queda en su lugar | El derivado se elimina, salvo `orphanDownstreamOnPolicyDelete: true` |
| Namespace del derivado eliminado | Desaparece vía GC nativo | Desaparece; se recrea solo si se recrea el disparador |

Tres lecturas operativas de esta tabla:

1. **`synchronize: true` + `orphanDownstreamOnPolicyDelete: false` (los valores por defecto que obtenés al pedirlo explícitamente) significa que `kubectl delete cpol namespace-baseline` borra todas las NetworkPolicy que alguna vez creó.** En un clúster de 2000 namespaces eso es una eliminación instantánea de las políticas de red de todo el clúster. Poné `orphanDownstreamOnPolicyDelete: true` en todo lo crítico para la seguridad, o protegé el objeto de política con una regla `validate` / disciplina de finalizers.
2. **`synchronize: false` no es "enforcement más débil", es "sin enforcement después de t₀".** Usalo solo donde el objeto generado sea genuinamente una *semilla* que el tenant debe poseer y hacer evolucionar (un `ConfigMap` inicial, un `Ingress` de ejemplo).
3. **La fila "ya no coincide → eliminado" es una trampa con los selectores de labels.** Un tenant que quita `tenant.example.com/managed: "true"` de su propio namespace — cosa que puede hacer si tiene `patch namespace` — borra su propia quota y su política de red. Protegé el label con una regla `validate` aparte que prohíba eliminarlo.

---

## 6. RBAC: el modo de falla con el que todos tropiezan primero

El controlador de background de Kyverno viene con permisos para un conjunto core conservador. **Todo lo demás lo tenés que otorgar explícitamente**, mediante un `ClusterRole` que lleve el label de agregación:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller:tenant-baseline
  labels:
    # This label is the contract. Kyverno's background-controller ClusterRole is an
    # aggregated role; anything labelled here is merged into it by the API server's
    # ClusterRole aggregation controller, with no Kyverno restart required.
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups: [""]
    resources:
      - resourcequotas
      - limitranges
      - configmaps
      - secrets
      - serviceaccounts
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings", "roles"]
    # 'bind' and 'escalate' are REQUIRED to create a RoleBinding that references a
    # ClusterRole whose permissions Kyverno does not itself hold. Without them the
    # API server rejects the write with a privilege-escalation error, even though
    # 'create rolebindings' is granted.
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "bind", "escalate"]

  - apiGroups: ["cert-manager.io"]
    resources: ["certificates"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Verificá que la concesión haya surtido efecto *con la identidad del controlador*, nunca con la tuya:

```console
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n team-payments
yes

$ kubectl auth can-i create rolebindings \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n team-payments
yes

$ kubectl get clusterrole kyverno:background-controller -o jsonpath='{.aggregationRule}' | jq
{
  "clusterRoleSelectors": [
    {
      "matchLabels": {
        "rbac.kyverno.io/aggregate-to-background-controller": "true"
      }
    }
  ]
}
```

Existen labels hermanos para los otros controladores — `rbac.kyverno.io/aggregate-to-admission-controller`, `...-to-reports-controller`, `...-to-cleanup-controller`. Otorgá al *más estrecho* que lo necesite; la generación solo necesita el controlador de background.

---

## 7. Manifiestos de producción

### 7.1 Bootstrap de baseline del tenant — `data`, con una quota por niveles resuelta desde un ConfigMap

La fuente de verdad del equipo de plataforma para el dimensionamiento:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-system
  labels:
    tenant.example.com/managed: "false"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-tiers
  namespace: platform-system
data:
  tiers: |
    [
      {"name": "bronze", "cpu": "4",  "memory": "8Gi",   "pods": "30",  "pvc": "5",  "nodeports": "0"},
      {"name": "silver", "cpu": "16", "memory": "32Gi",  "pods": "120", "pvc": "20", "nodeports": "2"},
      {"name": "gold",   "cpu": "64", "memory": "128Gi", "pods": "400", "pvc": "60", "nodeports": "8"}
    ]
```

La política:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-namespace-baseline
  annotations:
    policies.kyverno.io/title: Tenant Namespace Baseline
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Namespace, NetworkPolicy, ResourceQuota, LimitRange
    policies.kyverno.io/description: >-
      Provisions and continuously reconciles the mandatory guardrails for every
      namespace labelled tenant.example.com/managed=true: a default-deny ingress
      NetworkPolicy, a ResourceQuota sized from the tenant tier, and a LimitRange
      that forces every container to carry requests. Generated objects are
      orphaned on policy deletion so that removing the policy never silently
      removes the network guardrails of a running fleet.
spec:
  # Generate rules always execute in the background controller. background:true is
  # additionally required so that generateExisting can backfill pre-existing
  # namespaces, and so drift is reconciled outside admission events.
  background: true
  generateExisting: true
  # If Kyverno is unavailable we would rather let namespace creation succeed and
  # backfill on recovery than block the whole platform. Flip to Fail once the
  # Kyverno deployment is genuinely HA and you have an SLO to back it.
  failurePolicy: Ignore

  rules:
    # ---------------------------------------------------------------------------
    - name: default-deny-ingress
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      exclude:
        any:
          - resources:
              kinds:
                - Namespace
              names:
                - "kube-*"
                - "kyverno"
                - "platform-system"
                - "default"
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        # Deleting this policy must NOT strip network isolation from the fleet.
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
              app.kubernetes.io/managed-by: kyverno
            annotations:
              # Argo CD would otherwise flag this object as out-of-sync/extraneous
              # in any Application whose destination is this namespace.
              argocd.argoproj.io/compare-options: IgnoreExtraneous
              argocd.argoproj.io/sync-options: Prune=false
              # Flux equivalent.
              kustomize.toolkit.fluxcd.io/prune: disabled
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
            ingress:
              # Same-namespace traffic is permitted; everything else is denied.
              - from:
                  - podSelector: {}
              # Allow the ingress controller in.
              - from:
                  - namespaceSelector:
                      matchLabels:
                        kubernetes.io/metadata.name: ingress-nginx

    # ---------------------------------------------------------------------------
    - name: tenant-resourcequota
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      context:
        # Resolve the tier label with a safe default, so an unlabelled namespace
        # gets the smallest quota rather than an unresolved-variable rule error.
        - name: tierName
          variable:
            jmesPath: request.object.metadata.labels."tenant.example.com/tier"
            default: bronze
        - name: tiersCM
          configMap:
            name: tenant-tiers
            namespace: platform-system
        # ConfigMap values are always strings; parse_json turns the embedded JSON
        # document into a real list we can filter with JMESPath.
        - name: tier
          variable:
            jmesPath: "parse_json(tiersCM.data.tiers)[?name=='{{ tierName }}'] | [0]"
      preconditions:
        all:
          - key: "{{ tier.name || '' }}"
            operator: NotEquals
            value: ""
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
              tenant.example.com/tier: "{{ tier.name }}"
            annotations:
              argocd.argoproj.io/compare-options: IgnoreExtraneous
          spec:
            hard:
              requests.cpu: "{{ tier.cpu }}"
              requests.memory: "{{ tier.memory }}"
              limits.cpu: "{{ tier.cpu }}"
              limits.memory: "{{ tier.memory }}"
              pods: "{{ tier.pods }}"
              persistentvolumeclaims: "{{ tier.pvc }}"
              services.nodeports: "{{ tier.nodeports }}"
              count/jobs.batch: "50"

    # ---------------------------------------------------------------------------
    - name: tenant-limitrange
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      generate:
        apiVersion: v1
        kind: LimitRange
        name: tenant-defaults
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
          spec:
            limits:
              - type: Container
                default:
                  cpu: "500m"
                  memory: "512Mi"
                defaultRequest:
                  cpu: "100m"
                  memory: "128Mi"
                max:
                  cpu: "4"
                  memory: "8Gi"
                min:
                  cpu: "10m"
                  memory: "16Mi"
              - type: PersistentVolumeClaim
                max:
                  storage: "500Gi"
                min:
                  storage: "1Gi"
```

**Notas de diseño incrustadas arriba, hechas explícitas:**

- `operations: [CREATE, UPDATE]` — `UPDATE` importa. Es lo que hace que un namespace que *pasa a ser* gestionado (label agregado después) dispare el aprovisionamiento.
- `default: bronze` en la entrada de contexto `tierName` convierte un label ausente de un *error de regla* (que aparece como `PolicyError` y un UR fallido) en un fallback seguro. Las variables sin resolver en reglas generate son una causa principal de URs atascados.
- El bloque `preconditions` protege contra un label de tier que nombre un nivel inexistente en el ConfigMap: `tier` sería `null` y `{{ tier.cpu }}` no se podría resolver. Saltear es el comportamiento correcto — el namespace no recibe quota y se dispara la alerta de quota faltante, en lugar de que la regla entera falle en bucle.
- `orphanDownstreamOnPolicyDelete: true` en las tres reglas. Eliminar la política debería ser un cambio en el plano de control, no una caída del plano de datos.

### 7.2 Distribución de credenciales de registro — `clone`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-registry-credentials
  annotations:
    policies.kyverno.io/title: Propagate Registry Pull Secret
    policies.kyverno.io/category: Supply Chain
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Clones the platform registry pull secret into every tenant namespace and
      keeps it converged. The source secret is owned by External Secrets Operator,
      so credential rotation in Vault propagates fleet-wide with no policy change.
spec:
  background: true
  generateExisting: true
  rules:
    - name: clone-harbor-pull-secret
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      exclude:
        any:
          - resources:
              kinds:
                - Namespace
              names:
                - "kube-*"
                - "kyverno"
                - "platform-system"
      generate:
        apiVersion: v1
        kind: Secret
        name: harbor-pull-secret
        namespace: "{{ request.object.metadata.name }}"
        # With synchronize:true Kyverno watches the SOURCE. When ESO rewrites
        # platform-system/harbor-pull-secret after a Vault rotation, every clone
        # is updated. This is the entire reason to prefer clone over data here:
        # the credential never enters a policy manifest, therefore never enters Git.
        synchronize: true
        orphanDownstreamOnPolicyDelete: false
        clone:
          namespace: platform-system
          name: harbor-pull-secret
```

La pieza complementaria — la generación pone el Secret en el namespace, pero los Pods todavía necesitan referenciarlo. Eso es una regla **mutate-existing**, no una regla generate, y el emparejamiento es un punto habitual tanto de examen como de diseño:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: attach-pull-secret-to-default-sa
spec:
  background: true
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: add-imagepullsecret
      match:
        any:
          - resources:
              kinds:
                - Secret
              names:
                - harbor-pull-secret
              operations:
                - CREATE
                - UPDATE
      mutate:
        targets:
          - apiVersion: v1
            kind: ServiceAccount
            name: default
            namespace: "{{ request.object.metadata.namespace }}"
        patchStrategicMerge:
          imagePullSecrets:
            - name: harbor-pull-secret
```

### 7.3 Propagación dirigida por selector — `cloneList`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-platform-bundles
  annotations:
    policies.kyverno.io/title: Propagate Platform Bundles
    policies.kyverno.io/description: >-
      Copies every ConfigMap and Secret in platform-system carrying the label
      tenant.example.com/propagate=true into every managed namespace. Adding a new
      bundle is a label on one object, not a policy change.
spec:
  background: true
  generateExisting: true
  rules:
    - name: clone-labelled-bundles
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      generate:
        # No apiVersion/kind/name here: cloneList derives all three from each
        # matched source object. Only the destination namespace is specified.
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: false
        cloneList:
          namespace: platform-system
          kinds:
            - v1/ConfigMap
            - v1/Secret
          selector:
            matchLabels:
              tenant.example.com/propagate: "true"
```

Los orígenes, para completar:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: corporate-ca-bundle
  namespace: platform-system
  labels:
    tenant.example.com/propagate: "true"
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    MIIDXTCCAkWgAwIBAgIJAKl3xk8kQ2mBMA0GCSqGSIb3DQEBCwUAMEUxCzAJBgNV
    ...
    -----END CERTIFICATE-----
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-endpoint
  namespace: platform-system
  labels:
    tenant.example.com/propagate: "true"
data:
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```

**El trade-off de escala en una sola frase:** la cardinalidad de `cloneList` se multiplica. Tres bundles etiquetados × 2000 namespaces = 6000 objetos derivados, cada uno con su propio camino de reconciliación y cada uno consumiendo etcd. Etiquetá un cuarto bundle y acabás de emitir 2000 escrituras a la API con un solo `kubectl label`.

### 7.4 `foreach` — un derivado por elemento (Kyverno ≥ 1.11)

Generar un `Certificate` de cert-manager por host en cada Ingress:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-certificates-per-ingress-host
  annotations:
    policies.kyverno.io/title: Certificate per Ingress Host
    policies.kyverno.io/description: >-
      Emits one cert-manager Certificate per host listed on an Ingress annotated
      for automatic TLS, without requiring tenants to understand cert-manager.
spec:
  background: true
  rules:
    - name: certificate-per-host
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/auto-tls: "true"
      preconditions:
        all:
          - key: "{{ request.object.spec.rules[?host] | length(@) }}"
            operator: GreaterThan
            value: 0
      generate:
        foreach:
          - list: "request.object.spec.rules[?host]"
            apiVersion: cert-manager.io/v1
            kind: Certificate
            # Hostnames contain dots, which are legal in a DNS-subdomain name but
            # make downstream naming ambiguous. Normalise to dashes.
            name: "{{ replace_all(element.host, '.', '-') }}-tls"
            namespace: "{{ request.object.metadata.namespace }}"
            synchronize: true
            orphanDownstreamOnPolicyDelete: false
            data:
              metadata:
                labels:
                  app.kubernetes.io/managed-by: kyverno
                  tenant.example.com/source-ingress: "{{ request.object.metadata.name }}"
              spec:
                secretName: "{{ replace_all(element.host, '.', '-') }}-tls"
                duration: 2160h    # 90d
                renewBefore: 720h  # 30d
                privateKey:
                  algorithm: ECDSA
                  size: 256
                  rotationPolicy: Always
                dnsNames:
                  - "{{ element.host }}"
                usages:
                  - server auth
                issuerRef:
                  name: letsencrypt-prod
                  kind: ClusterIssuer
                  group: cert-manager.io
```

Fijate en la semántica de eliminación: con `synchronize: true`, borrar un host de `spec.rules` provoca que el `Certificate` correspondiente sea eliminado en la siguiente reconciliación, porque ese derivado ya no está en el conjunto deseado renderizado.

### 7.5 Backfill de un clúster existente

`generateExisting` es lo que convierte una política nueva de "aplica a los namespaces creados de ahora en más" a "aplica a toda la flota". Dos formas:

```yaml
# Spec-level: applies to every generate rule in the policy.
spec:
  background: true
  generateExisting: true
```

```yaml
# Rule-level (newer releases): scope the backfill to one rule, so you can roll out
# a cheap NetworkPolicy backfill immediately and defer an expensive one.
    - name: default-deny-ingress
      generate:
        generateExisting: true
        ...
```

El backfill se dispara por **creación o actualización de la política**, no por un horario. Volver a disparar un backfill sin cambiar el comportamiento se hace tocando una anotación inocua:

```console
$ kubectl annotate cpol tenant-namespace-baseline \
    platform.example.com/backfill-epoch="7" --overwrite
clusterpolicy.kyverno.io/tenant-namespace-baseline annotated
```

**No hagas esto en un clúster grande en horario laboral.** Un backfill enumera cada recurso coincidente y encola un `UpdateRequest` por (disparador × regla). Tres reglas sobre 2000 namespaces son 6000 URs materializados en etcd y drenados a través de la cola de trabajo del controlador de background.

---

## 8. CLI: bucle de verificación con salida real

### 8.1 Sin conexión — validá antes de que el clúster lo vea siquiera

```console
$ kyverno version
Version: 1.13.2
Time: 2025-01-28T09:12:44Z
Git commit ID: 4f1c0b93c7e2f1a6d21b8b3f9d5e7a1c2b6f8d40

$ kyverno apply policy/tenant-namespace-baseline.yaml \
    --resource test/namespace-team-payments.yaml \
    --values-file test/values.yaml \
    --output out/

Applying 3 policy rule(s) to 1 resource(s)...

pass: 3, fail: 0, warn: 0, error: 0, skip: 0

$ ls out/
LimitRange-team-payments-tenant-defaults.yaml
NetworkPolicy-team-payments-default-deny-ingress.yaml
ResourceQuota-team-payments-tenant-quota.yaml

$ cat out/ResourceQuota-team-payments-tenant-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  labels:
    app.kubernetes.io/part-of: tenant-baseline
    tenant.example.com/tier: silver
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
  name: tenant-quota
  namespace: team-payments
spec:
  hard:
    count/jobs.batch: "50"
    limits.cpu: "16"
    limits.memory: 32Gi
    persistentvolumeclaims: "20"
    pods: "120"
    requests.cpu: "16"
    requests.memory: 32Gi
    services.nodeports: "2"
```

El `--values-file` provee el contexto del ConfigMap para que la ejecución offline resuelva las mismas variables que resolvería el clúster:

```yaml
---
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
metadata:
  name: baseline-values
policies:
  - name: tenant-namespace-baseline
    resources:
      - name: team-payments
        values: {}
namespaceSelector: []
globalValues: {}
```

Fijar la salida esperada como test de regresión:

```yaml
---
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: tenant-namespace-baseline
policies:
  - ../policy/tenant-namespace-baseline.yaml
resources:
  - namespace-team-payments.yaml
variables: values.yaml
results:
  - policy: tenant-namespace-baseline
    rule: default-deny-ingress
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/networkpolicy-default-deny-ingress.yaml
    result: pass
  - policy: tenant-namespace-baseline
    rule: tenant-resourcequota
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/resourcequota-tenant-quota.yaml
    result: pass
  - policy: tenant-namespace-baseline
    rule: tenant-limitrange
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/limitrange-tenant-defaults.yaml
    result: pass
```

```console
$ kyverno test . --detailed-results

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 3 policy rules to 1 resource ...
  Checking results ...

│────│───────────────────────────│──────────────────────│──────────────────────────│────────│
│ ID │ POLICY                    │ RULE                 │ RESOURCE                 │ RESULT │
│────│───────────────────────────│──────────────────────│──────────────────────────│────────│
│ 1  │ tenant-namespace-baseline │ default-deny-ingress │ /Namespace/team-payments │ Pass   │
│ 2  │ tenant-namespace-baseline │ tenant-resourcequota │ /Namespace/team-payments │ Pass   │
│ 3  │ tenant-namespace-baseline │ tenant-limitrange    │ /Namespace/team-payments │ Pass   │
│────│───────────────────────────│──────────────────────│──────────────────────────│────────│

Test Summary: 3 tests passed and 0 tests failed
```

`generatedResource` realiza una comparación estructural del derivado renderizado contra un archivo golden. Este es el único mecanismo que atrapa una regresión del bloque `data` antes de que se propague por toda la flota — ponelo en CI.

### 8.2 En el clúster — la secuencia estándar de verificación

```console
$ kubectl apply -f policy/tenant-namespace-baseline.yaml
clusterpolicy.kyverno.io/tenant-namespace-baseline created

$ kubectl get cpol tenant-namespace-baseline
NAME                        ADMISSION   BACKGROUND   READY   AGE   MESSAGE
tenant-namespace-baseline   true        true         True    9s    Ready

$ kubectl create namespace team-payments
namespace/team-payments created

$ kubectl label namespace team-payments \
    tenant.example.com/managed=true tenant.example.com/tier=silver
namespace/team-payments labeled
```

El `UpdateRequest` es la verdad de base para "¿ocurrió la generación?":

```console
$ kubectl -n kyverno get updaterequests
NAME       POLICY                      RULE                   RESOURCEKIND   RESOURCENAME    RESOURCENAMESPACE   STATUS      AGE
ur-2t9hq   tenant-namespace-baseline   default-deny-ingress   Namespace      team-payments                       Completed   4s
ur-b7wkn   tenant-namespace-baseline   tenant-resourcequota   Namespace      team-payments                       Completed   4s
ur-x4mzc   tenant-namespace-baseline   tenant-limitrange      Namespace      team-payments                       Completed   4s

$ kubectl -n kyverno get ur ur-b7wkn -o yaml
apiVersion: kyverno.io/v2
kind: UpdateRequest
metadata:
  generateName: ur-
  labels:
    generate.kyverno.io/policy-name: tenant-namespace-baseline
    generate.kyverno.io/rule-name: tenant-resourcequota
    generate.kyverno.io/trigger-kind: Namespace
    generate.kyverno.io/trigger-name: team-payments
    generate.kyverno.io/trigger-namespace: ""
  name: ur-b7wkn
  namespace: kyverno
spec:
  policy: tenant-namespace-baseline
  rule: tenant-resourcequota
  type: generate
  resource:
    apiVersion: v1
    kind: Namespace
    name: team-payments
status:
  state: Completed
  generatedResources:
    - apiVersion: v1
      kind: ResourceQuota
      name: tenant-quota
      namespace: team-payments
```

Confirmá el derivado y sus labels de trazabilidad:

```console
$ kubectl -n team-payments get networkpolicy,resourcequota,limitrange
NAME                                                  POD-SELECTOR   AGE
networkpolicy.networking.k8s.io/default-deny-ingress   <none>         31s

NAME                    AGE   REQUEST                                                              LIMIT
resourcequota/tenant-quota   31s   count/jobs.batch: 0/50, persistentvolumeclaims: 0/20, pods: 0/120, requests.cpu: 0/16, requests.memory: 0/32Gi, services.nodeports: 0/2   limits.cpu: 0/16, limits.memory: 0/32Gi

NAME                          CREATED AT
limitrange/tenant-defaults    2026-08-13T09:41:07Z

$ kubectl -n team-payments get netpol default-deny-ingress \
    -o jsonpath='{.metadata.labels}' | jq
{
  "app.kubernetes.io/managed-by": "kyverno",
  "app.kubernetes.io/part-of": "tenant-baseline",
  "generate.kyverno.io/policy-name": "tenant-namespace-baseline",
  "generate.kyverno.io/policy-namespace": "",
  "generate.kyverno.io/rule-name": "default-deny-ingress",
  "generate.kyverno.io/trigger-group": "",
  "generate.kyverno.io/trigger-kind": "Namespace",
  "generate.kyverno.io/trigger-name": "team-payments",
  "generate.kyverno.io/trigger-namespace": "",
  "generate.kyverno.io/trigger-version": "v1"
}
```

Demostrá que `synchronize` realmente reconcilia — la prueba que todo equipo de plataforma debería correr antes de confiar en la regla:

```console
$ kubectl -n team-payments delete netpol default-deny-ingress
networkpolicy.networking.k8s.io "default-deny-ingress" deleted

$ sleep 5 && kubectl -n team-payments get netpol
NAME                   POD-SELECTOR   AGE
default-deny-ingress   <none>         3s

$ kubectl -n team-payments patch netpol default-deny-ingress \
    --type=json -p='[{"op":"replace","path":"/spec/ingress","value":[{}]}]'
networkpolicy.networking.k8s.io/default-deny-ingress patched

$ sleep 5 && kubectl -n team-payments get netpol default-deny-ingress \
    -o jsonpath='{.spec.ingress}' | jq
[
  {
    "from": [
      { "podSelector": {} }
    ]
  },
  {
    "from": [
      { "namespaceSelector": { "matchLabels": { "kubernetes.io/metadata.name": "ingress-nginx" } } }
    ]
  }
]
```

El parche permisivo `[{}]` fue revertido. Esa es toda la propuesta de valor de `synchronize: true` en una sola transcripción de terminal.

Consulta de auditoría para toda la flota — encontrar cada namespace que debería tener el baseline y no lo tiene:

```console
$ comm -23 \
    <(kubectl get ns -l tenant.example.com/managed=true -o name | sed 's|namespace/||' | sort) \
    <(kubectl get netpol -A -l generate.kyverno.io/policy-name=tenant-namespace-baseline \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
team-legacy-billing
team-sandbox-03
```

---

## 9. Diagnóstico de fallas

### 9.1 Orden de triage

```console
# 1. Is the policy admitted and Ready?
$ kubectl get cpol tenant-namespace-baseline -o wide

# 2. Was an UpdateRequest created at all?  (No UR => the ADMISSION side never matched.)
$ kubectl -n kyverno get ur \
    -l generate.kyverno.io/policy-name=tenant-namespace-baseline

# 3. If a UR exists, what does it say?  (UR exists but not Completed => BACKGROUND side.)
$ kubectl -n kyverno get ur <name> -o jsonpath='{.status}' | jq

# 4. Kubernetes Events on the trigger.
$ kubectl get events -A --field-selector involvedObject.name=team-payments \
    --sort-by=.lastTimestamp

# 5. The controller that actually did the work.
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=200 \
    | grep -iE 'generat|updaterequest|forbidden'
```

Esa bifurcación en el paso 2 es la bisección diagnóstica clave: **la ausencia de UR es un problema del lado de admisión** (match/exclude, registro del webhook, `resourceFilters`); **un UR que nunca se completa es un problema del lado de background** (RBAC, resolución de variables, esquema, origen faltante).

### 9.2 Taxonomía de fallas

| Síntoma | Causa raíz | Comando de confirmación | Solución |
|---|---|---|---|
| No se crea ningún `UpdateRequest` | El tipo disparador no está en el webhook de Kyverno (autoUpdateWebhooks deshabilitado, o Kyverno se reinició antes de sincronizar la política) | `kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml \| grep -A5 namespaces` | Reaplicá la política; verificá `--autoUpdateWebhooks=true` |
| Sin UR; el disparador claramente coincide | El namespace/tipo del disparador está excluido por `resourceFilters` en el ConfigMap `kyverno` | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Quitá la entrada del filtro, o movés el disparador fuera del namespace filtrado |
| Sin UR; el `match` parece correcto | El `match` se escribió contra el tipo *derivado* en lugar del disparador | Releé `spec.rules[].match.any[].resources.kinds` | Hacé match con el disparador |
| UR atascado en `Pending`, controlador de background inactivo | Controlador de background caído / en crash-loop / sin líder | `kubectl -n kyverno get pods -l app.kubernetes.io/component=background-controller` | Restaurá el deployment; revisá límites de recursos y OOMKills |
| UR `Failed`, el log muestra `is forbidden` | La SA del controlador de background carece de RBAC sobre el tipo derivado | `kubectl auth can-i create <res> --as=system:serviceaccount:kyverno:kyverno-background-controller -n <ns>` | Agregá un ClusterRole agregado (§6) |
| UR `Failed` solo en RoleBinding | Faltan los verbos `bind`/`escalate` — prevención de escalada de privilegios | Lo mismo, con `--subresource` sin definir; leé el mensaje exacto del API server | Agregá `bind` y `escalate` |
| UR `Failed`: `variable substitution failed` / `failed to resolve` | La ruta JMESPath no existe en el disparador, o la entrada de contexto devolvió `null` | `kyverno apply` offline con el YAML exacto del disparador | Agregá `default:` a la variable de contexto, o una guarda con `preconditions` |
| El derivado se crea pero se borra de inmediato | Algo puso una `ownerReference` entre namespaces; o el disparador dejó de coincidir | `kubectl get events -n <ns> \| grep OwnerRefInvalidNamespace` | Quitá la owner reference; no agregues owner references a mano en objetos generados |
| El derivado nunca se actualiza cuando cambia el origen | `synchronize: false`; o el namespace origen está filtrado; o se quitaron los labels de watch del origen del clon | `kubectl get <source> -o jsonpath='{.metadata.labels}'` | Poné `synchronize: true`; sacá el filtro del namespace origen |
| El derivado revierte una edición legítima del tenant | `synchronize: true` está haciendo exactamente su trabajo | — | Usá `synchronize: false` para semillas, o acotá el bloque `data` solo a los campos que te pertenecen |
| Todo desapareció después de `kubectl delete cpol` | `orphanDownstreamOnPolicyDelete: false` (por defecto) con `synchronize: true` | `kubectl get cpol` (ya no está) + logs de auditoría | Poné `orphanDownstreamOnPolicyDelete: true` antes de borrar; restaurá reaplicando la política con `generateExisting: true` |
| Argo CD muestra el namespace permanentemente `OutOfSync` | El objeto generado es extraño al estado deseado de la Application | Diff en la UI de Argo | `argocd.argoproj.io/compare-options: IgnoreExtraneous` en el objeto generado, o una entrada `resource.exclusions` en Argo |
| Los Pods arrancaron antes de que existiera la NetworkPolicy | Generación asíncrona — por diseño | Comparar el `creationTimestamp` del Pod con el de la NetworkPolicy | Aceptá la consistencia eventual, y agregá una regla `validate` que deniegue Pods en namespaces gestionados que carezcan de la barrera |
| `generateExisting` no hizo nada | `spec.background: false`, o la política nunca se actualizó después de agregar el flag | `kubectl get cpol <n> -o jsonpath='{.spec.background} {.spec.generateExisting}'` | Poné `background: true`; tocá una anotación para volver a disparar |

### 9.3 Transcripciones reales de fallas

**Denegación de RBAC:**

```console
$ kubectl -n kyverno get ur -l generate.kyverno.io/policy-name=generate-certificates-per-ingress-host
NAME       POLICY                                   RULE                   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS   AGE
ur-9qk4d   generate-certificates-per-ingress-host   certificate-per-host   Ingress        payments-api   team-payments       Failed   22s

$ kubectl -n kyverno get ur ur-9qk4d -o jsonpath='{.status}' | jq
{
  "state": "Failed",
  "message": "failed to create resource certificates.cert-manager.io/v1: certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"certificates\" in API group \"cert-manager.io\" in the namespace \"team-payments\"",
  "retryCount": 3
}

$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=5
E0813 09:52:14.774318       1 controller.go:318] "reconcile failed" err="failed to create resource certificates.cert-manager.io/v1: certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"certificates\" in API group \"cert-manager.io\" in the namespace \"team-payments\"" controller="updaterequest" UpdateRequest="kyverno/ur-9qk4d"

$ kubectl auth can-i create certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n team-payments
no
```

Corregí, y después confirmá que el reintento converge sin tocar el disparador:

```console
$ kubectl apply -f rbac/kyverno-background-certmanager.yaml
clusterrole.rbac.authorization.k8s.io/kyverno:background-controller:cert-manager created

$ kubectl auth can-i create certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n team-payments
yes

$ kubectl -n team-payments annotate ingress payments-api kyverno.io/retry="1" --overwrite
ingress.networking.k8s.io/payments-api annotated

$ kubectl -n team-payments get certificates
NAME                          READY   SECRET                        AGE
api-payments-example-com-tls  True    api-payments-example-com-tls  18s
```

**Variable sin resolver:**

```console
$ kubectl -n kyverno get ur ur-mm81f -o jsonpath='{.status.message}'
failed to substitute variables in generate rule: failed to resolve tier.cpu at path /spec/hard/requests.cpu: JMESPath query failed: Unknown key "cpu" in path

$ kubectl get ns team-legacy-billing -o jsonpath='{.metadata.labels}' | jq
{
  "kubernetes.io/metadata.name": "team-legacy-billing",
  "tenant.example.com/managed": "true",
  "tenant.example.com/tier": "platinum"
}
```

El namespace declara un tier `platinum` que no existe en `tenant-tiers`; el filtro JMESPath devolvió `null` y la guarda de `preconditions` era lo que debería haberlo salteado. La reproducción offline:

```console
$ kyverno apply policy/tenant-namespace-baseline.yaml \
    --resource /tmp/ns-legacy.yaml

Applying 3 policy rule(s) to 1 resource(s)...

skipped: tenant-namespace-baseline/tenant-resourcequota on /Namespace/team-legacy-billing

pass: 2, fail: 0, warn: 0, error: 0, skip: 1
```

`skip` en lugar de `error` — que es lo que te compra la precondición, y por qué la ejecución offline siempre debería ser parte del ciclo.

---

## 10. Escala, radio de impacto y límites operativos

| Preocupación | Mecanismo | Mitigación |
|---|---|---|
| Volumen de URs | Un UR por (evento de disparador × regla generate). Una política de 3 reglas con backfill sobre 2000 namespaces = 6000 URs en etcd. | Desplegá regla por regla; usá `generateExisting` a nivel de regla; vigilá el conteo de objetos en etcd y `apiserver_storage_objects`. |
| Fan-out al editar `data` | `synchronize: true` propaga una edición de la política a todos los derivados. | Hacé canary con un selector de labels (`tenant.example.com/baseline-channel: canary`), promové re-etiquetando. Dos políticas, dos canales. |
| Rendimiento del controlador de background | Una única cola de trabajo con concurrencia acotada. El backlog se manifiesta como un conteo creciente de URs `Pending` y latencia de generación en aumento. | Alertá sobre `count(kube_customresource … state="Pending") > N` y sobre la antigüedad de los URs; escalá el deployment del controlador de background y sus límites de CPU. |
| Acoplamiento al camino de admisión | Una regla generate sobre `Namespace` pone a Kyverno en el camino de cada CREATE de namespace. | `failurePolicy: Ignore` para políticas que solo aprovisionan; corré el controlador de admisión en HA con un PDB; reservá `Fail` solo para políticas cuyo bypass sea un evento de seguridad. |
| Radio de impacto del borrado | `kubectl delete cpol` con `synchronize: true` y comportamiento de huérfanos por defecto elimina todos los derivados. | `orphanDownstreamOnPolicyDelete: true`; una `ClusterPolicy` de validación que deniegue `DELETE` sobre las políticas baseline salvo desde una ServiceAccount de emergencia. |
| Proliferación de secretos | Un `clone` de un pull secret a N namespaces significa N copias de una credencial, cada una legible por cualquiera con `get secrets` en ese namespace. | Limitá la credencial a solo descarga; rotá en el origen; considerá un token por namespace a nivel de registro. |
| Namespaces en Terminating | La generación dentro de un namespace en `Terminating` falla y reintenta. | Excluí los namespaces en terminación con una precondición sobre `request.object.status.phase`. |

**Cerrar la brecha asíncrona.** Emparejá la regla generate con una regla validate para que la *ventana* quede acotada por la admisión y no por la latencia de reconciliación:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-baseline-before-workloads
  annotations:
    policies.kyverno.io/description: >-
      Closes the eventual-consistency window of tenant-namespace-baseline. A Pod
      cannot be admitted into a managed namespace until the generated NetworkPolicy
      actually exists, so no workload ever runs unisolated.
spec:
  background: false
  validationFailureAction: Enforce
  rules:
    - name: netpol-must-exist
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
              namespaceSelector:
                matchLabels:
                  tenant.example.com/managed: "true"
      context:
        - name: netpols
          apiCall:
            urlPath: "/apis/networking.k8s.io/v1/namespaces/{{ request.namespace }}/networkpolicies"
            jmesPath: "items[?metadata.name=='default-deny-ingress'] | length(@)"
      validate:
        message: >-
          The tenant baseline NetworkPolicy is not yet present in namespace
          {{ request.namespace }}. Kyverno provisions it asynchronously; retry in
          a few seconds. If this persists, the platform team has an open incident.
        deny:
          conditions:
            all:
              - key: "{{ netpols }}"
                operator: Equals
                value: 0
```

```console
$ kubectl -n team-payments run probe --image=nginx:1.27
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/team-payments/probe was blocked due to the following policies

require-baseline-before-workloads:
  netpol-must-exist: 'The tenant baseline NetworkPolicy is not yet present in namespace
    team-payments. Kyverno provisions it asynchronously; retry in a few seconds. If
    this persists, the platform team has an open incident.'
```

Este es el patrón que vale la pena llevarse de todo el tema: **`generate` provisiona, `validate` garantiza.** Ninguno por separado te da una barrera de seguridad cerrada.

---

## 11. Interacción con GitOps

Los recursos generados existen en el clúster pero no en Git. Por lo tanto, todo motor GitOps que reconcilie los verá como drift.

| Motor | Síntoma | Remedio |
|---|---|---|
| Argo CD | La Application queda permanentemente `OutOfSync`; el prune automático borra el objeto generado; Kyverno lo recrea; bucle | Anotá el derivado con `argocd.argoproj.io/compare-options: IgnoreExtraneous` y `argocd.argoproj.io/sync-options: Prune=false` (solo posible con `data`, no con `clone`), o agregá una entrada `resource.exclusions` a nivel de clúster en `argocd-cm` basada en `app.kubernetes.io/managed-by: kyverno` |
| Flux | La Kustomization recolecta el objeto como basura | `kustomize.toolkit.fluxcd.io/prune: disabled` en el derivado, o acotá el inventario de la Kustomization |

Con `clone` no podés inyectar anotaciones, porque `clone` y `data` son mutuamente excluyentes. Las opciones viables son (a) poner las anotaciones en el **origen** para que cada copia las herede, o (b) excluir a nivel del motor en lugar de por objeto. La opción (a) es preferible: mantiene la excepción declarativa y ubicada junto a la cosa que se propaga.

---

## 12. Checklist de examen

- El `match` de una regla generate selecciona el **disparador**, nunca el recurso generado.
- La generación corre en el **controlador de background** mediante un **`UpdateRequest`**, de forma asíncrona, fuera de la transacción de admisión.
- El derivado se escribe como `system:serviceaccount:kyverno:kyverno-background-controller`. Falta de RBAC → el disparador igual tiene éxito, la generación falla en silencio dentro del estado del UR.
- Extendé el RBAC con un `ClusterRole` etiquetado `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
- Exactamente uno de `data`, `clone`, `cloneList` (o un `foreach` que contenga uno de ellos). `data` admite variables; `clone`/`cloneList` no.
- `synchronize: true` ⇒ el derivado se reconcilia ante drift, se actualiza cuando cambia el origen o la política, **y se elimina cuando el disparador se elimina o deja de coincidir**.
- `orphanDownstreamOnPolicyDelete: true` conserva los recursos derivados cuando se elimina la política o la regla. El valor por defecto es `false`.
- `generateExisting: true` (requiere `spec.background: true`) hace backfill de recursos que ya existen; se dispara al crear/actualizar la política, no por temporizador.
- Una `Policy` con namespace genera solo dentro de su propio namespace; la generación entre namespaces necesita una `ClusterPolicy`.
- El vínculo se establece con labels `generate.kyverno.io/*`, **no** con owner references — porque las owner references entre namespaces son inválidas en Kubernetes.
- `kubectl -n kyverno get ur` es el primer comando en toda investigación de una regla generate.
- Las reglas que referencian `{{request.userInfo.*}}` no pueden correr con `background: true` y, por lo tanto, no pueden usar `generateExisting`.

> **Nota prospectiva.** Los releases recientes de Kyverno introducen tipos de política basados en CEL bajo `policies.kyverno.io/v1alpha1` (`ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, …) que se alinean con el modelo ValidatingAdmissionPolicy de Kubernetes upstream. El examen KCA y la abrumadora mayoría de los despliegues productivos apuntan a la API `kyverno.io/v1` `ClusterPolicy`/`Policy` descrita acá. Verificá `kubectl api-resources --api-group=policies.kyverno.io` en tu propio clúster antes de asumir disponibilidad, y verificá los nombres de campo con `kubectl explain` para la versión exacta que corrés.

---

## Referencias

**Kyverno — documentación oficial**
- Reglas generate: https://kyverno.io/docs/writing-policies/generate/
- Escritura de políticas (índice): https://kyverno.io/docs/writing-policies/
- Variables, contexto y JMESPath: https://kyverno.io/docs/writing-policies/variables/
- Filtros personalizados de JMESPath (`parse_json`, `replace_all`, …): https://kyverno.io/docs/writing-policies/jmespath/
- Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Mutar recursos existentes: https://kyverno.io/docs/writing-policies/mutate/
- CLI de Kyverno (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Instalación y personalización (RBAC, ConfigMap, `resourceFilters`, webhooks): https://kyverno.io/docs/installation/customization/
- Resolución de problemas: https://kyverno.io/docs/troubleshooting/
- Biblioteca de políticas (ejemplos de generate de calidad productiva): https://kyverno.io/policies/
- Código fuente y tipos de la API: https://github.com/kyverno/kyverno
- Código fuente de la biblioteca de políticas: https://github.com/kyverno/policies

**Kubernetes — documentación oficial**
- Propietarios y dependientes (restricciones de owner references entre namespaces): https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/
- Recolección de basura: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- RBAC — prevención de escalada de privilegios, `bind` y `escalate`: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
- ClusterRoles agregados: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
- Control de admisión dinámico (`failurePolicy` del webhook): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Políticas de red: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Cuotas de recursos: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Rangos de límites: https://kubernetes.io/docs/concepts/policy/limit-range/

**Certificación**
- Currículum de KCA (CNCF): https://github.com/cncf/curriculum
- Kyverno Certified Associate (Linux Foundation): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Ecosistema referenciado en los ejemplos**
- API `Certificate` de cert-manager: https://cert-manager.io/docs/usage/certificate/
- Opciones de comparación y exclusiones de recursos de Argo CD: https://argo-cd.readthedocs.io/en/stable/user-guide/compare-options/
- Pruning de Kustomization en Flux: https://fluxcd.io/flux/components/kustomize/kustomizations/