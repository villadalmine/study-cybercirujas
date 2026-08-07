# 4.2 · APIs for Self-Service Platforms — Custom Resource Definitions

> **Peso en el examen: 3.0** · Dominio 4 (Platform Engineering / Kubernetes as a Platform)
> Perfil: diseño y operación de APIs de plataforma sobre el Kubernetes Resource Model.

---

## 1. Motivación: el problema arquitectónico de la plataforma self-service

Una plataforma interna de desarrollo (IDP, *Internal Developer Platform*) fracasa cuando el equipo de plataforma se convierte en un *ticket queue*: cada `Namespace`, cada base de datos, cada certificado TLS pasa por un humano. El objetivo de Platform Engineering es invertir ese flujo — que el desarrollador **declare la intención** (`quiero una base de datos PostgreSQL de 20 GiB`) y que la plataforma **reconcilie la realidad** sin intervención manual, con guardarraíles impuestos por diseño.

El error clásico es construir ese self-service *fuera* de Kubernetes: una API REST bespoke en Go/Python, con su propia base de datos, su propio autenticación, su propio sistema de estado. En producción esto genera tres deudas estructurales:

1. **Deriva de estado (state drift).** Tu API bespoke escribe en su DB *y* aplica a Kubernetes. Los dos estados divergen: alguien hace `kubectl edit`, tu DB no se entera. No hay una única fuente de verdad.
2. **Reimplementación del control plane.** Reescribís watch, retry con backoff, optimistic concurrency, RBAC, auditoría, admission — todo lo que `kube-apiserver` ya te da gratis y probado a escala.
3. **Fricción de tooling.** `kubectl`, `helm`, Argo CD, `kustomize`, Backstage, OPA/Gatekeeper — todo el ecosistema habla el *Kubernetes Resource Model* (KRM). Una API fuera de KRM no participa de GitOps ni de las políticas del cluster.

La respuesta de Kubernetes es **extender su propia API** para que tus abstracciones de plataforma (`Database`, `AppClaim`, `TenantEnvironment`) sean ciudadanos de primera clase: objetos declarativos, versionados, validados, auditados y reconciliados por el mismo control plane. El mecanismo primario es la **Custom Resource Definition (CRD)**.

Una CRD registra un nuevo *kind* en `kube-apiserver`. A partir de ese momento:

```
$ kubectl get databases.platform.acme.io
$ kubectl explain database.spec
$ kubectl apply -f my-db.yaml
```

funcionan igual que para un `Pod`, con el mismo endpoint REST (`/apis/platform.acme.io/v1/namespaces/<ns>/databases`), la misma persistencia en etcd, el mismo RBAC, el mismo audit log y el mismo watch stream. El *dato* vive en el control plane; la *lógica* vive en un **controller** que observa esos objetos y actúa (patrón Operator). Este es el desacople central: **la CRD es la API; el controller es la implementación.**

---

## 2. El Kubernetes Resource Model como contrato de plataforma

Antes de la CRD, hay que entender qué contrato se está firmando. Todo objeto KRM tiene la misma forma:

| Campo | Propietario | Semántica |
|---|---|---|
| `apiVersion` / `kind` | API | Identidad del tipo (`group/version`, `Kind`) |
| `metadata` | Usuario + sistema | `name`, `namespace`, `labels`, `annotations`, `finalizers`, `ownerReferences`, `resourceVersion`, `uid` |
| `spec` | **Usuario** (intención deseada) | Lo que el usuario *quiere*. Nunca lo escribe el controller. |
| `status` | **Controller** (realidad observada) | Lo que el sistema *observó*. Nunca lo escribe el usuario. |

La separación `spec` / `status` no es cosmética: es el contrato de reconciliación. El usuario declara `spec`, el controller lo compara con la realidad y escribe `status` (idealmente vía el subrecurso `/status`, para que un `kubectl apply` del usuario no pise el estado y viceversa). Diseñar una CRD es diseñar ese contrato: qué campos de intención expone el desarrollador y qué campos de observación devuelve la plataforma.

---

## 3. Mecanismos de extensión de la API: comparativa de trade-offs

Kubernetes ofrece más de un camino para extender su API. Elegir mal cuesta caro en producción.

| Criterio | **CRD** | **Aggregated API Server** | **ConfigMap / Annotations** |
|---|---|---|---|
| Registro | `apiextensions.k8s.io/v1` (declarativo) | `apiregistration.k8s.io/v1` `APIService` + servidor propio | Ninguno (se abusa de tipos existentes) |
| Almacenamiento | etcd del cluster (gratis) | El que vos implementes (etcd propio, SQL, en memoria) | etcd (como `ConfigMap`) |
| Validación | OpenAPI v3 structural schema + CEL (`x-kubernetes-validations`) + admission webhooks | Código arbitrario Go | Ninguna nativa (validás en tu app) |
| Subrecursos | `/status`, `/scale` | Cualquiera (`/logs`, `/exec`, `/proxy`…) | No |
| Protobuf / performance | No (solo JSON) | Sí (serialización binaria, watch eficiente a gran escala) | JSON |
| Lógica en el read path | No (etcd sirve el objeto tal cual) | Sí (podés computar campos al leer) | No |
| Esfuerzo operativo | **Bajo** — un YAML | **Alto** — mantener un binario, TLS, HA, disponibilidad | Mínimo |
| Versionado / conversión | Múltiples versiones + conversion webhook | Manual, en tu código | No |
| Casos de uso | 95% de las APIs de plataforma; Operators; abstracciones self-service | `metrics.k8s.io`, `service-catalog`, APIs con storage no-etcd o campos computados | Config estática de un solo consumidor |

**Regla de decisión práctica:** empezá siempre con CRD. Solo escalá a un Aggregated API Server si necesitás (a) subrecursos arbitrarios como `/exec`, (b) almacenamiento que no sea etcd, (c) campos calculados en el momento de la lectura, o (d) protobuf por volumen extremo de objetos. El Aggregated API Server pone el *disponibilidad de la API de tu plataforma* en tus manos: si tu servidor cae, ese grupo de API desaparece del cluster. Con CRD, la API vive mientras viva el control plane.

**Anti-patrón: CRD vs. ConfigMap.** Usar `ConfigMap`/annotations como "objetos de plataforma" (p. ej. anotar un `Namespace` con `platform.acme.io/db-size: "20Gi"`) elimina validación, tipado, `kubectl explain`, RBAC por tipo, versionado y `additionalPrinterColumns`. Es aceptable solo para config estática consumida por un único componente que vos controlás. Para cualquier API expuesta a usuarios: CRD.

---

## 4. Anatomía de una CRD de producción

Una CRD de juguete tiene un `openAPIV3Schema` con `x-kubernetes-preserve-unknown-fields: true` y nada más. Una CRD de producción tiene **cinco propiedades no negociables**:

### 4.1 Structural schema (obligatorio en `v1`)

Desde `apiextensions.k8s.io/v1` (GA en Kubernetes 1.16; `v1beta1` eliminado en 1.22), el schema debe ser *structural*: cada campo tipado, `type` en la raíz y en cada objeto anidado, sin `oneOf`/`anyOf` en la raíz que rompan la estructura, y sin `x-kubernetes-preserve-unknown-fields` salvo donde se necesite pasar datos opacos. Un schema no-structural hace que la CRD reporte la condición `NonStructuralSchema=True` y deshabilita features como CEL y pruning.

### 4.2 Pruning y defaulting

- **Pruning** (`preserveUnknownFields: false`, el default y único valor válido en `v1`): campos que no están en el schema se descartan silenciosamente al persistir. Esto evita que el usuario "cuele" campos no validados.
- **Defaulting** (`default:` por campo): el apiserver rellena valores ausentes al escribir. Reduce boilerplate del usuario y evita ramas `if nil` en el controller.

### 4.3 Validación: OpenAPI + CEL

OpenAPI v3 cubre tipos, rangos, `enum`, `pattern`, `required`, `minimum`/`maximum`, `minLength`. Para reglas de negocio *entre campos* está **CEL** (`x-kubernetes-validations`, alpha 1.23 → beta 1.25 → **GA 1.29**), que ejecuta expresiones en el apiserver sin webhook:

```yaml
x-kubernetes-validations:
  - rule: "self.replicas <= self.maxReplicas"
    message: "replicas no puede exceder maxReplicas"
```

CEL reemplaza la mayoría de los validating webhooks: sin latencia de red, sin punto de fallo, sin certificado que rotar. La **validation ratcheting** (GA 1.30) permite que updates que no tocan un campo inválido pasen aunque ese campo ya no cumpla el schema — clave para evolucionar schemas sin bloquear a usuarios existentes.

### 4.4 Múltiples versiones + conversión

Toda API de plataforma evoluciona. Una CRD puede *servir* varias versiones (`served: true`) pero **almacenar exactamente una** (`storage: true`). La conversión entre versiones servidas es:

| Estrategia | Cuándo | Costo |
|---|---|---|
| `None` | Las versiones difieren solo en el nombre; los campos son idénticos | Cero |
| `Webhook` | Los campos cambian (rename, split, reshape) | Un webhook HTTPS con TLS que hay que mantener disponible |

### 4.5 Subrecursos, printer columns, categorías, campos seleccionables

- `subresources.status: {}` → habilita `/status`, separando RBAC y evitando pisadas spec/status.
- `subresources.scale` → integra tu CRD con `kubectl scale` y el HPA.
- `additionalPrinterColumns` → columnas en `kubectl get`.
- `categories: [all]` → tu recurso aparece en `kubectl get all`.
- `shortNames`, `singular`, `plural` → ergonomía.
- `selectableFields` (beta 1.32) → habilita `--field-selector` sobre campos de tu `spec`.

---

## 5. Manifiestos completos (sin recortar)

### 5.1 La CRD: `Database` con dos versiones, CEL, subrecursos y conversión

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.platform.acme.io      # DEBE ser <plural>.<group>
spec:
  group: platform.acme.io
  scope: Namespaced                       # o Cluster
  names:
    kind: Database
    listKind: DatabaseList
    singular: database
    plural: databases
    shortNames: [db]
    categories: [all, platform]
  conversion:
    strategy: Webhook
    webhook:
      conversionReviewVersions: ["v1", "v1beta1"]
      clientConfig:
        service:
          namespace: platform-system
          name: database-conversion-webhook
          path: /convert
          port: 443
        # caBundle lo inyecta cert-manager (ver ca-injector) o se pega en base64
  versions:
    - name: v1beta1
      served: true
      storage: false                      # servida pero NO almacenada
      deprecated: true
      deprecationWarning: "platform.acme.io/v1beta1 Database está deprecada; migrá a v1"
      schema:
        openAPIV3Schema:
          type: object
          required: [spec]
          properties:
            spec:
              type: object
              required: [engine, sizeGi]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                sizeGi:
                  type: integer
    - name: v1
      served: true
      storage: true                       # ÚNICA versión de almacenamiento
      schema:
        openAPIV3Schema:
          type: object
          required: [spec]
          properties:
            spec:
              type: object
              required: [engine, storage]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                  x-kubernetes-validations:
                    - rule: "self == oldSelf"
                      message: "engine es inmutable tras la creación"
                version:
                  type: string
                  default: "16"           # defaulting
                  pattern: '^[0-9]+$'
                storage:
                  type: object
                  required: [sizeGi]
                  properties:
                    sizeGi:
                      type: integer
                      minimum: 1
                      maximum: 65536
                    storageClass:
                      type: string
                highAvailability:
                  type: object
                  properties:
                    enabled:
                      type: boolean
                      default: false
                    replicas:
                      type: integer
                      minimum: 1
                      maximum: 9
                      default: 1
                  x-kubernetes-validations:
                    - rule: "!self.enabled || self.replicas >= 3"
                      message: "HA requiere al menos 3 replicas"
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Pending, Provisioning, Ready, Failed]
                endpoint:
                  type: string
                observedGeneration:
                  type: integer
                conditions:
                  type: array
                  items:
                    type: object
                    required: [type, status]
                    properties:
                      type: { type: string }
                      status: { type: string, enum: ["True", "False", "Unknown"] }
                      reason: { type: string }
                      message: { type: string }
                      lastTransitionTime: { type: string, format: date-time }
                  x-kubernetes-list-type: map
                  x-kubernetes-list-map-keys: [type]
      subresources:
        status: {}                         # habilita /status
        scale:
          specReplicasPath: .spec.highAvailability.replicas
          statusReplicasPath: .status.currentReplicas
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Size
          type: integer
          jsonPath: .spec.storage.sizeGi
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Endpoint
          type: string
          jsonPath: .status.endpoint
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

### 5.2 Instancia (el objeto que crea el desarrollador — self-service)

```yaml
apiVersion: platform.acme.io/v1
kind: Database
metadata:
  name: orders-db
  namespace: team-payments
spec:
  engine: postgres
  version: "16"
  storage:
    sizeGi: 20
    storageClass: fast-ssd
  highAvailability:
    enabled: true
    replicas: 3
```

### 5.3 RBAC con agregación (self-service con guardarraíles)

El equipo de plataforma define *quién* puede pedir qué. La agregación de RBAC hace que el rol `admin` de cada namespace herede permisos sobre la nueva CRD automáticamente:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:database-editor
  labels:
    # Estos ClusterRoles se agregan a los roles built-in del namespace:
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:database-viewer
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases", "databases/status"]
    verbs: ["get", "list", "watch"]
```

El **controller** necesita su propio `ServiceAccount` con permiso sobre `databases` **y** `databases/status` (subrecurso separado en RBAC), más los recursos derivados que crea (`StatefulSet`, `Service`, `Secret`):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:database-controller
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["platform.acme.io"]
    resources: ["databases/status", "databases/finalizers"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services", "secrets", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
```

### 5.4 Deployment del controller (Operator)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database-controller
  namespace: platform-system
spec:
  replicas: 2                              # HA con leader election
  selector:
    matchLabels: { app: database-controller }
  template:
    metadata:
      labels: { app: database-controller }
    spec:
      serviceAccountName: database-controller
      containers:
        - name: manager
          image: registry.acme.io/database-operator:v1.4.2
          args:
            - --leader-elect                # solo un pod reconcilia a la vez
            - --health-probe-bind-address=:8081
            - --metrics-bind-address=:8443
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          livenessProbe:
            httpGet: { path: /healthz, port: 8081 }
            initialDelaySeconds: 15
          readinessProbe:
            httpGet: { path: /readyz, port: 8081 }
```

### 5.5 Webhook de conversión con inyección de CA (cert-manager)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: database-conversion-webhook-cert
  namespace: platform-system
spec:
  secretName: database-conversion-webhook-tls
  dnsNames:
    - database-conversion-webhook.platform-system.svc
    - database-conversion-webhook.platform-system.svc.cluster.local
  issuerRef:
    name: platform-ca-issuer
    kind: ClusterIssuer
---
# La annotation le dice a cert-manager que inyecte el caBundle en la CRD:
# metadata.annotations:
#   cert-manager.io/inject-ca-from: platform-system/database-conversion-webhook-cert
```

---

## 6. El patrón Operator: el bucle de reconciliación

La CRD sin controller es un formulario que nadie lee. El controller implementa el **reconcile loop**: nivelado (*level-triggered*), no basado en eventos (*edge-triggered*). Observa el estado deseado (`spec`) y el observado, y converge — de forma idempotente, porque puede ejecutarse N veces sobre el mismo objeto.

```
                 watch (informer)
   ┌──────────────────────────────────────┐
   │  kube-apiserver (Database CRs)        │
   └───────────────┬──────────────────────┘
                   │  add/update/delete → workqueue
                   ▼
          ┌─────────────────┐
          │  Reconcile(req) │  idempotente, con retry+backoff
          └───────┬─────────┘
                  │  1. Get(Database)
                  │  2. ¿deletionTimestamp? → correr finalizer, quitar finalizer
                  │  3. Crear/actualizar StatefulSet, Service, Secret (con ownerReferences)
                  │  4. Observar realidad → patch a /status (phase, conditions, observedGeneration)
                  │  5. return {Requeue|RequeueAfter} o error → re-encola
                  ▼
          efectos en el cluster
```

Dos mecanismos de correctitud que la CRD habilita y el controller debe respetar:

- **`ownerReferences`**: los objetos derivados (`StatefulSet`, `Service`) apuntan al `Database` como owner. Al borrar el `Database`, garbage collection los borra en cascada. Sin esto, borrás la CR y quedan recursos huérfanos.
- **`finalizers`**: si la limpieza requiere acción externa (borrar un bucket S3, un DNS record), el controller agrega un finalizer al `metadata.finalizers`. El apiserver marca `deletionTimestamp` pero **no borra** el objeto hasta que el finalizer desaparezca. Esto convierte el borrado en una transacción confiable — y es la causa #1 de objetos "colgados" cuando el controller muere (§9).

- **`observedGeneration`**: el controller copia `metadata.generation` a `status.observedGeneration` cuando terminó de reconciliar. Comparar ambos dice si el `status` refleja el `spec` actual o uno viejo.

---

## 7. Self-service en la práctica: de CRD cruda a plataforma componible

Una CRD `Database` con un controller a medida es un Operator. Una **plataforma** self-service es un conjunto de APIs de alto nivel (*claims*) que el desarrollador consume sin conocer la implementación, y que componen recursos de bajo nivel. Los frameworks maduros construyen esto *sobre* CRDs:

| Framework | Abstracción sobre CRD | Modelo de composición | Cuándo |
|---|---|---|---|
| **Kubebuilder / Operator SDK** (controller-runtime) | Escribís la CRD + el controller en Go | Código imperativo Go | Lógica compleja, dominio propio, reconciliación no trivial |
| **Crossplane** | `CompositeResourceDefinition` (XRD) genera CRDs; `Composition` mapea a *Managed Resources* | Declarativo (Compositions / funciones) | Aprovisionar infra cloud (RDS, GKE, buckets) como KRM |
| **KubeVela** | `Application` (OAM) + `ComponentDefinition`/`TraitDefinition` (usan CUE) | Declarativo (OAM) | Golden paths de aplicaciones, plantillas |
| **Kratix** | `Promise` (empaqueta CRD + pipeline) | Pipelines de contenedores | Marketplace de servicios entre equipos plataforma/app |
| **Metacontroller** | Reusa CRDs existentes | Hooks web (JSON in/out) | Controllers simples sin escribir Go |

El patrón que la CNPA enfatiza es la **claim API**: el desarrollador aplica un objeto pequeño (`AppClaim`, `PostgreSQLInstance`) en su namespace; un *composite resource* con scope de cluster, gobernado por la plataforma, lo expande a decenas de recursos reales con políticas impuestas. Ejemplo en Crossplane:

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqls.platform.acme.io
spec:
  group: platform.acme.io
  names:      { kind: XPostgreSQL, plural: xpostgresqls }     # composite (cluster)
  claimNames: { kind: PostgreSQL,  plural: postgresqls }      # claim (namespaced, self-service)
  versions:
    - name: v1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    sizeGi: { type: integer }
                    region: { type: string, enum: [us-east-1, eu-west-1] }
                  required: [sizeGi]
```

Crossplane genera dos CRDs a partir de esto (la composite y la claim), y una `Composition` define cómo `sizeGi`/`region` se traducen a un `RDSInstance`, un `SubnetGroup`, un `SecurityGroup`. El desarrollador nunca ve AWS: aplica un `PostgreSQL` y recibe un endpoint. Ese es el fin último del tema — **la CRD es el ladrillo; la plataforma es el edificio.**

Complemento del portal: **Backstage** lista estas APIs en su Software Catalog y sus *Software Templates* (scaffolder) generan el YAML del claim y lo commitean a Git, cerrando el lazo GitOps. La CRD es lo que hace posible que Backstage, Argo CD y OPA hablen del mismo objeto.

---

## 8. Comandos CLI y salidas de terminal

**Registrar la CRD y verificar que se estableció:**

```console
$ kubectl apply -f database-crd.yaml
customresourcedefinition.apiextensions.k8s.io/databases.platform.acme.io created

$ kubectl get crd databases.platform.acme.io
NAME                          CREATED AT
databases.platform.acme.io    2026-08-07T14:22:10Z

$ kubectl get crd databases.platform.acme.io \
    -o jsonpath='{.status.conditions[*].type}{"\n"}'
NamesAccepted Established
```

**Descubrir el tipo — ya es ciudadano de primera clase:**

```console
$ kubectl api-resources --api-group=platform.acme.io
NAME        SHORTNAMES   APIVERSION              NAMESPACED   KIND
databases   db           platform.acme.io/v1     true         Database

$ kubectl explain database.spec.storage
KIND:       Database
VERSION:    platform.acme.io/v1

FIELD: storage <Object>

DESCRIPTION:
    <empty>
FIELDS:
  sizeGi        <integer> -required-
  storageClass  <string>
```

**Crear una instancia y verla con las printer columns:**

```console
$ kubectl apply -f orders-db.yaml
database.platform.acme.io/orders-db created

$ kubectl get db -n team-payments
NAME        ENGINE     SIZE   PHASE      ENDPOINT                             AGE
orders-db   postgres   20     Ready      orders-db.team-payments.svc:5432     45s

$ kubectl get db -n team-payments -o wide
NAME        ENGINE     SIZE   PHASE   ENDPOINT                          AGE
orders-db   postgres   20     Ready   orders-db.team-payments.svc:5432  45s
```

**Ver la validación CEL rechazando en el apiserver (sin webhook):**

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: { name: bad-ha, namespace: team-payments }
spec:
  engine: postgres
  storage: { sizeGi: 5 }
  highAvailability: { enabled: true, replicas: 1 }
EOF
The Database "bad-ha" is invalid: spec.highAvailability: Invalid value:
"object": HA requiere al menos 3 replicas
```

**Ver la inmutabilidad CEL (`self == oldSelf`) al intentar cambiar el engine:**

```console
$ kubectl patch db orders-db -n team-payments --type=merge \
    -p '{"spec":{"engine":"mysql"}}'
The Database "orders-db" is invalid: spec.engine: Invalid value: "string":
engine es inmutable tras la creación
```

**Ver el warning de deprecación al usar la versión vieja:**

```console
$ kubectl apply -f legacy-db-v1beta1.yaml
Warning: platform.acme.io/v1beta1 Database está deprecada; migrá a v1
database.platform.acme.io/legacy-orders created
```

**Confirmar la versión de almacenamiento real en etcd (auditoría de migración):**

```console
$ kubectl get crd databases.platform.acme.io \
    -o jsonpath='{.status.storedVersions}{"\n"}'
["v1beta1","v1"]
```

> `storedVersions` con más de una entrada significa que hay objetos guardados en formatos viejos: hasta que no re-escribas todos a `v1` (p. ej. `kubectl get databases -A -o yaml | kubectl replace -f -`, o `kube-storage-version-migrator`), **no podés** quitar `v1beta1` de la lista de versiones.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 La CRD no se establece — `Established=False`

```console
$ kubectl get crd databases.platform.acme.io -o json | \
    jq '.status.conditions'
[
  {
    "type": "NamesAccepted",
    "status": "False",
    "reason": "ListKindConflict",
    "message": "\"DatabaseList\" is already in use"
  },
  { "type": "Established", "status": "False", "reason": "NotAccepted",
    "message": "not all names are accepted" }
]
```

**Causa:** colisión de nombres (`kind`, `plural`, `shortNames`) con otra CRD o recurso built-in. **Diagnóstico:** `kubectl api-resources | grep -i database`. **Fix:** renombrar. Recordá: `metadata.name` de la CRD *debe* ser exactamente `<plural>.<group>` o el apiserver rechaza la creación.

### 9.2 Schema no-structural — CEL y pruning deshabilitados

```console
$ kubectl get crd databases.platform.acme.io -o json | \
    jq '.status.conditions[] | select(.type=="NonStructuralSchema")'
{
  "type": "NonStructuralSchema", "status": "True", "reason": "Violations",
  "message": "spec.versions[0].schema.openAPIV3Schema.properties[spec].type: Required value: must not be empty for specified object fields"
}
```

**Causa:** falta `type: object` en un nivel anidado, o hay `oneOf`/`anyOf` en la raíz. **Fix:** completar `type` en cada objeto. Sin schema structural no funcionan CEL, defaulting ni pruning.

### 9.3 El objeto se crea pero nada pasa — `status.phase: Pending` para siempre

Checklist de diagnóstico (en orden):

```console
# ¿El controller está corriendo y es leader?
$ kubectl get deploy -n platform-system database-controller
NAME                  READY   UP-TO-DATE   AVAILABLE
database-controller   2/2     2            2

$ kubectl logs -n platform-system deploy/database-controller | grep -i lead
I0807 successfully acquired lease platform-system/database-controller

# ¿Tiene RBAC sobre el subrecurso /status?
$ kubectl auth can-i update databases/status \
    --as=system:serviceaccount:platform-system:database-controller
yes

# ¿Hay eventos del reconcile?
$ kubectl describe db orders-db -n team-payments | sed -n '/Events:/,$p'
Events:
  Type     Reason              Age   From                  Message
  ----     ------              ----  ----                  -------
  Warning  ReconcileError      12s   database-controller   failed to create StatefulSet: statefulsets.apps is forbidden
```

**Causa típica #1:** el controller puede editar `databases` pero **no** `databases/status` (subrecurso RBAC separado) → escribe pero nunca reporta `Ready`. **Causa típica #2:** falta permiso sobre los recursos derivados (`statefulsets.apps is forbidden`, arriba). Ambas se ven con `kubectl auth can-i` y en `Events`.

### 9.4 Fallo de conversión webhook

```console
$ kubectl get db orders-db -n team-payments
Error from server: conversion webhook for platform.acme.io/v1beta1, Kind=Database
failed: Post "https://database-conversion-webhook.platform-system.svc:443/convert":
x509: certificate signed by unknown authority
```

**Causa:** el `caBundle` de la CRD no coincide con el cert que sirve el webhook (rotación, inyección de cert-manager no aplicada). **Efecto grave:** si el webhook está caído o el TLS falla, **no podés ni leer** los objetos que necesitan conversión — la API queda inaccesible para esa versión. **Fix:** verificar la annotation `cert-manager.io/inject-ca-from`, que el `Certificate` esté `Ready`, y que el `Service`/`Endpoints` del webhook resuelvan:

```console
$ kubectl get endpoints -n platform-system database-conversion-webhook
NAME                          ENDPOINTS            AGE
database-conversion-webhook   10.244.2.7:8443      3h
```

### 9.5 Objeto que no se borra — finalizer huérfano

```console
$ kubectl delete db orders-db -n team-payments
database.platform.acme.io "orders-db" deleted     # ...y se cuelga

$ kubectl get db orders-db -n team-payments -o jsonpath='{.metadata.finalizers}'
["platform.acme.io/dispose-storage"]
```

**Causa:** el controller murió (o perdió RBAC sobre `databases/finalizers`) antes de completar la limpieza y quitar el finalizer. El apiserver tiene `deletionTimestamp` seteado pero espera al finalizer para siempre. **Fix correcto:** revivir el controller para que corra la limpieza. **Fix de emergencia** (asumiendo que ya limpiaste los recursos externos a mano — quitarlo *no* corre la limpieza):

```console
$ kubectl patch db orders-db -n team-payments --type=merge \
    -p '{"metadata":{"finalizers":[]}}'
database.platform.acme.io/orders-db patched
```

### 9.6 Validación de manifiestos en CI (dry-run del apiserver)

Antes de mergear, validá el CR contra el schema *real* del cluster sin persistir:

```console
$ kubectl apply --dry-run=server -f orders-db.yaml
database.platform.acme.io/orders-db created (server dry run)
```

`--dry-run=server` corre defaulting, CEL y admission webhooks; `--dry-run=client` no — solo validación local básica. Para self-service confiable, el gate de CI debe usar **server** dry-run.

### 9.7 Matriz de conditions de la CRD (referencia rápida)

| Condition | `True` significa | Acción si `False`/`True` inesperado |
|---|---|---|
| `NamesAccepted` | Nombres sin conflicto | Renombrar `kind`/`plural`/`shortNames` |
| `Established` | La CRD sirve tráfico | Resolver `NamesAccepted` primero |
| `NonStructuralSchema` | **Problema**: schema no structural | Agregar `type` faltantes; quitar `oneOf` de raíz |
| `KubernetesAPIApprovalPolicyConformant` | Grupo `*.k8s.io` aprobado | Agregar annotation `api-approved.kubernetes.io` con URL de PR, o no usar grupo `*.k8s.io` |
| `Terminating` | La CRD se está borrando | Esperar GC de todos los CRs |

---

## 10. Referencias

- Kubernetes — *Extend the Kubernetes API with CustomResourceDefinitions*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — *Custom Resources* (conceptos, CRD vs Aggregated API): https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — *Extending the Kubernetes API* (overview de mecanismos de extensión): https://kubernetes.io/docs/concepts/extend-kubernetes/
- Kubernetes — *Versions in CustomResourceDefinitions* (served/storage, conversion webhooks): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Kubernetes — *Validation rules (CEL) / `x-kubernetes-validations`*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes — *Structural schemas & pruning*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- Kubernetes — *Operator pattern*: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Kubernetes — *Finalizers*: https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Kubernetes — *Owner References & garbage collection*: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes — *Aggregation Layer / APIService*: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/
- Kubernetes — *Using RBAC Authorization* (aggregated ClusterRoles): https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
- CNCF — *CNPA Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- The Kubebuilder Book (controller-runtime): https://book.kubebuilder.io/
- Crossplane — *Composite Resource Definitions (XRDs)*: https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- KubeVela / Open Application Model: https://kubevela.io/docs/ · https://oam.dev/
- Kratix — *Promises*: https://docs.kratix.io/