# Tema 4.3: Infrastructure Provisioning with Kubernetes (Crossplane/Kratix)

> **Certificación:** CNPA — Cloud Native Platform Engineering Associate · **Versión de examen:** 2025-04-01 · **Peso:** 3.0
>
> **Dominio:** Platform Engineering — usar el control plane de Kubernetes como motor de provisioning de infraestructura y de APIs de plataforma.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema que resuelve

La forma tradicional de provisionar infraestructura (Terraform/Pulumi ejecutado desde CI) es **client-side y push-based**: un pipeline corre `apply`, lee el `tfstate`, calcula un diff y ejecuta cambios contra las APIs del cloud. Ese modelo tiene tres debilidades estructurales para una plataforma interna (IDP — Internal Developer Platform):

1. **No hay reconciliación continua.** El `apply` es un evento puntual. Entre `apply` y `apply` la infraestructura puede driftear (alguien tocó la consola de AWS, un operador borró un recurso) y nadie lo corrige hasta la próxima corrida. El estado deseado no es *activamente defendido*.
2. **El estado vive fuera del cluster.** El `tfstate` es una fuente de verdad paralela, con locking propio, secretos embebidos y una superficie de corrupción independiente. No es observable con `kubectl`, no participa de RBAC de Kubernetes, no emite `Events`.
3. **La abstracción se filtra hacia el desarrollador.** Si el equipo de aplicaciones necesita una base de datos, o aprende Terraform y los detalles de RDS, o abre un ticket. No existe una **API de autoservicio** con la forma del dominio del negocio (`kind: PostgreSQLInstance` con `size: small`), respaldada por opiniones de la plataforma (backups, encryption, tags de FinOps).

El patrón **control-plane provisioning** invierte esto: la infraestructura se representa como **Custom Resources** dentro de Kubernetes, y un **controller que corre en un loop de reconciliación** la mantiene convergente con el estado deseado. Kubernetes deja de ser "donde corren los contenedores" y pasa a ser **el universal control plane**: un motor de reconciliación declarativo, con etcd como store, RBAC, admission control, watch/informer y CRDs como sistema de tipos extensible.

```
┌──────────────────── MODELO CLIENT-SIDE (Terraform) ────────────────────┐
│  Git → CI runner → terraform apply → cloud API                          │
│                         │                                                │
│                    tfstate (S3+DynamoDB)   ← fuente de verdad externa    │
│  Reconciliación: SOLO cuando corre el pipeline (evento puntual)         │
└─────────────────────────────────────────────────────────────────────────┘

┌──────────────── MODELO CONTROL-PLANE (Crossplane) ─────────────────────┐
│  Git → Argo/Flux → kubectl apply → CR en etcd                           │
│                         │                                                │
│                    controller (loop infinito)                           │
│                         │  watch + reconcile cada Δt                     │
│                         ▼                                                │
│                    cloud API   ← drift corregido automáticamente        │
│  Reconciliación: CONTINUA (defiende el estado deseado)                  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Los dos proyectos y qué capa resuelve cada uno

Ambos son proyectos CNCF que usan Kubernetes como control plane, pero atacan capas distintas del problema de plataforma:

- **Crossplane** (CNCF Incubating) es un **provisioner y motor de composición de infraestructura**. Instala *providers* que traducen recursos cloud (RDS, S3, VPC) a CRDs (*Managed Resources*), y permite **componer** varios recursos de bajo nivel en una **API de plataforma de alto nivel** (una `PostgreSQLInstance` que por debajo es una `Instance` de RDS + un `SubnetGroup` + un `SecurityGroup`). Todo vive y se reconcilia en el cluster.
- **Kratix** (CNCF Sandbox, por Syntasso) es un **framework para construir plataformas**. Su unidad es la **Promise**: un paquete que combina *una API* (CRD), *sus dependencias* y *un pipeline* (workflow en contenedores) que se ejecuta cuando alguien pide un recurso. Kratix separa explícitamente el **platform cluster** (donde se piden las cosas) de los **worker clusters / Destinations** (donde corren), y entrega el resultado vía GitOps a través de un **State Store**.

La distinción clave para el examen: **Crossplane compone recursos declarativos y reconcilia continuamente en el cluster; Kratix orquesta pipelines imperativos y distribuye el resultado a múltiples destinos vía GitOps.** No son excluyentes — un caso común es una Promise de Kratix cuyo pipeline emite Managed Resources de Crossplane.

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Control-plane provisioning vs. client-side IaC

| Dimensión | Crossplane / Kratix (control-plane) | Terraform / OpenTofu / Pulumi (client-side) |
|---|---|---|
| Modelo de ejecución | Loop de reconciliación continuo | `apply` puntual (push) |
| Corrección de drift | Automática y permanente | Solo en la próxima corrida; `plan` la detecta |
| Fuente de verdad del estado | etcd (`status` del CR) | Fichero de state externo (S3, Cloud, TFC) |
| Superficie de API | CRDs + `kubectl` + RBAC + admission | HCL/SDK + backend propio de auth |
| Autoservicio | Nativo (aplicar un CR) | Requiere wrapper (módulos, TFC, Atlantis) |
| Secretos de conexión | Escritos como `Secret` de K8s | Outputs en el state (riesgo de exposición) |
| Curva de adopción | Alta (CRDs, compositions, RBAC) | Media (lenguaje maduro, tooling masivo) |
| Ecosistema de providers | Bueno y creciente; cobertura desigual | Enorme, el más completo del mercado |
| Orden explícito / grafos | Implícito por reconciliación + `DependsOn`/`Usage` | Grafo de dependencias explícito |
| Blast radius de un cambio | Acotado por CR / RBAC / namespace | Todo el state module puede recomputarse |

### 2.2 Crossplane vs. Kratix

| Dimensión | Crossplane | Kratix |
|---|---|---|
| Estado / madurez CNCF | Incubating | Sandbox |
| Abstracción central | Composition (XRD + Composition + XR/Claim) | Promise (API + dependencies + workflow) |
| Paradigma de composición | **Declarativo** (funciones que devuelven recursos deseados) | **Imperativo** (contenedores que ejecutan lógica arbitraria) |
| Motor de "cómo se construye" | Composition Functions (gRPC, pipeline) | Pipelines (Jobs de K8s con contenedores) |
| Multi-cluster | Un control plane; providers apuntan a clouds/otros clusters | Nativo: platform cluster + N Destinations |
| Distribución del resultado | El controller escribe directo en la cloud API | GitOps: escribe en State Store → Flux/Argo aplica en el worker |
| Reconciliación de lo provisto | Sí, continua (Managed Resources) | Depende: el pipeline es puntual; lo aplicado por Flux/Argo sí reconcilia |
| Scheduling a destinos | No es su foco | Nativo, por *labels* Destination↔Promise |
| Encaja mejor cuando… | Necesitás una **API cloud reconciliada y compuesta** | Necesitás **orquestar workflows heterogéneos** y repartir a muchos clusters |

### 2.3 Contra otros provisioners nativos de Kubernetes

| Herramienta | Ámbito | Diferencia frente a Crossplane |
|---|---|---|
| **Cluster API (CAPI)** | Provisiona **clusters de Kubernetes** (control planes + node pools) | CAPI es especializado en el ciclo de vida de *clusters*; Crossplane es genérico para *cualquier* infraestructura |
| **AWS Controllers for K8s (ACK)** | CRDs 1:1 con servicios de AWS | Sin capa de composición ni multi-cloud; solo AWS |
| **Config Connector (KCC)** | Recursos de GCP como CRDs | Idem, específico de GCP; sin XRD/Composition |
| **Azure Service Operator (ASO)** | Recursos de Azure como CRDs | Idem, específico de Azure |
| **Terraform** vía `provider-terraform` | Corre HCL desde Crossplane | Puente: reusás módulos TF pero perdés parte de la reconciliación nativa |

> **Regla de decisión (para el examen y para producción):** si el problema es *"quiero una API declarativa, reconciliada y compuesta de infraestructura dentro del cluster"* → Crossplane. Si es *"quiero empaquetar servicios de plataforma con lógica de negocio arbitraria y repartirlos a una flota de clusters"* → Kratix. Para *"quiero crear clusters"* → Cluster API.

---

## 3. Manifiestos completos

### 3.1 Crossplane — instalación y provider

```bash
# Instalación del control plane
$ helm repo add crossplane-stable https://charts.crossplane.io/stable
$ helm repo update
$ helm install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace \
    --set args='{--enable-usages}'
```

**Provider** (family provider de AWS, subpaquete S3). El `Provider` es un package que instala los CRDs de los Managed Resources y despliega su controller como Deployment:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v1.21.1
  # Política de revisiones: cuántas dejar y comportamiento en upgrade
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
```

**DeploymentRuntimeConfig** (sustituto de `ControllerConfig`, deprecado) para inyectar recursos/afinidad al pod del provider:

```yaml
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: aws-runtime
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  memory: 512Mi
```

**ProviderConfig** — dónde saca las credenciales el provider. Nunca embeber credenciales en el CR; referenciar un `Secret` (o mejor, IRSA / Workload Identity con `source: IRSA`):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
  namespace: crossplane-system
type: Opaque
stringData:
  creds: |
    [default]
    aws_access_key_id = AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
```

**Managed Resource** — el recurso cloud atómico. Este es el nivel "bajo" que normalmente NO expone el desarrollador:

```yaml
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: platform-artifacts-eu
spec:
  forProvider:
    region: eu-west-1
    tags:
      team: platform
      cost-center: "4211"
  providerConfigRef:
    name: default
  # deletionPolicy: qué hacer con el recurso cloud al borrar el CR
  deletionPolicy: Delete       # Delete | Orphan
  # managementPolicies: nivel de control del controller sobre el recurso
  managementPolicies: ["*"]    # p.ej. ["Observe"] para import read-only
```

### 3.2 Crossplane — la API de plataforma (Composition)

Tres piezas conforman la abstracción de alto nivel:

1. **CompositeResourceDefinition (XRD)** — define la API que verá el usuario (el "contrato").
2. **Composition** — define *cómo* se satisface esa API con Managed Resources.
3. **Composite Resource (XR)** / **Claim** — la instancia que crea el usuario.

**XRD** — publica `XPostgreSQLInstance` (cluster-scoped) y su Claim namespaced `PostgreSQLInstance`:

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.platform.example.org
spec:
  group: database.platform.example.org
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: xpostgresql.aws
  versions:
    - name: v1alpha1
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
                    storageGB:
                      type: integer
                      minimum: 20
                      maximum: 1000
                    size:
                      type: string
                      enum: ["small", "medium", "large"]
                    region:
                      type: string
                  required:
                    - storageGB
                    - size
              required:
                - parameters
            status:
              type: object
              properties:
                address:
                  description: Endpoint FQDN de la base de datos
                  type: string
      # Campos del status del XR que se exponen en 'kubectl get'
      additionalPrinterColumns:
        - name: SIZE
          type: string
          jsonPath: ".spec.parameters.size"
        - name: READY
          type: string
          jsonPath: ".status.conditions[?(@.type=='Ready')].status"
```

**Composition** en modo **Pipeline** con Composition Functions (el modo moderno; el antiguo `mode: Resources` de patch-and-transform nativo está deprecado desde v1.17). Requiere instalar las Functions primero:

```yaml
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.8.2
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.0
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresql.aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: database.platform.example.org/v1alpha1
    kind: XPostgreSQLInstance
  mode: Pipeline
  pipeline:
    - step: create-resources
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta2
              kind: Instance
              spec:
                forProvider:
                  region: eu-west-1
                  engine: postgres
                  engineVersion: "16.3"
                  instanceClass: db.t3.micro
                  username: adminuser
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: pg-conn
                    key: password
                  skipFinalSnapshot: true
                  publiclyAccessible: false
                  storageEncrypted: true
                providerConfigRef:
                  name: default
                writeConnectionSecretToRef:
                  namespace: crossplane-system
            patches:
              # Deriva el nombre del MR desde el UID del XR (unicidad)
              - type: FromCompositeFieldPath
                fromFieldPath: "spec.parameters.storageGB"
                toFieldPath: "spec.forProvider.allocatedStorage"
              - type: FromCompositeFieldPath
                fromFieldPath: "spec.parameters.region"
                toFieldPath: "spec.forProvider.region"
              # Mapea el 'size' abstracto a una instance class concreta
              - type: FromCompositeFieldPath
                fromFieldPath: "spec.parameters.size"
                toFieldPath: "spec.forProvider.instanceClass"
                transforms:
                  - type: map
                    map:
                      small: db.t3.micro
                      medium: db.t3.medium
                      large: db.r6g.large
              # Publica el endpoint de vuelta en el status del XR
              - type: ToCompositeFieldPath
                fromFieldPath: "status.atProvider.address"
                toFieldPath: "status.address"
            # Cómo saber que este recurso está listo
            readinessChecks:
              - type: MatchCondition
                matchCondition:
                  type: Ready
                  status: "True"
    # Marca el XR como Ready cuando todos los recursos lo están
    - step: automatically-detect-readiness
      functionRef:
        name: function-auto-ready
```

**Claim** — lo único que crea el desarrollador, en su namespace. Este es el "producto" de la plataforma:

```yaml
apiVersion: database.platform.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-payments
spec:
  parameters:
    storageGB: 50
    size: medium
    region: eu-west-1
  # El Secret con host/port/user/password se escribe aquí:
  writeConnectionSecretToRef:
    name: orders-db-conn
```

> **Nota Crossplane v2 (2025):** en v2 los XR pueden ser **namespaced**, los **Claims dejan de existir** como concepto separado (se usa un XR namespaced directamente), las Composition Functions son el **único** modo de composición, y aparecen **Operations** para day-2. El modelo XRD/Composition/Claim de arriba es el de la serie v1.x, que es el que la mayoría de la documentación y el currículum del examen 2025-04-01 asumen. Conocé ambos: la dirección es "menos ceremonia, todo namespaced, todo por functions".

### 3.3 Kratix — Promise, Destination y State Store

**BucketStateStore** — dónde Kratix escribe el estado deseado que luego un GitOps agent aplica en el worker:

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: BucketStateStore
metadata:
  name: default
spec:
  endpoint: minio.kratix-platform-system.svc.cluster.local
  insecure: true
  bucketName: kratix
  secretRef:
    name: minio-credentials
    namespace: default
```

**Destination** — un cluster (o namespace) que recibe recursos. El scheduling se hace por *labels*:

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: worker-dev-eu
  labels:
    environment: dev
    region: eu
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
  # Estructura de rutas dentro del bucket
  filepath:
    mode: nestedByMetadata
```

**Promise** — la pieza central. Empaqueta la API (`spec.api`), lo que hay que preinstalar en los destinos (`spec.dependencies`) y el workflow que corre por cada request (`spec.workflows.resource.configure`):

```yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
  labels:
    kratix.io/promise-version: v1.0.0
spec:
  # Programación: a qué destinos van los recursos de esta Promise
  destinationSelectors:
    - matchLabels:
        environment: dev
  # 1) La API que verán los usuarios (un CRD)
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.marketplace.kratix.io
    spec:
      group: marketplace.kratix.io
      scope: Namespaced
      names:
        kind: postgresql
        plural: postgresqls
        singular: postgresql
      versions:
        - name: v1alpha1
          served: true
          storage: true
          schema:
            openAPIV3Schema:
              type: object
              properties:
                spec:
                  type: object
                  properties:
                    size:
                      type: string
                      enum: ["small", "large"]
                      default: small
  # 2) Recursos que se instalan en cada Destination al aplicar la Promise
  dependencies:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: postgres-operator
    # (aquí irían el operador de Postgres, CRDs, RBAC, etc.)
  # 3) Workflows: qué ejecutar y cuándo
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: generate-postgres-manifest
                image: registry.example.org/postgres-request-pipeline:v1.0.0
    promise:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: promise-configure
          spec:
            containers:
              - name: install-operator
                image: registry.example.org/postgres-operator-installer:v1.0.0
```

**Contrato del contenedor de pipeline.** El contenedor lee el request en `/kratix/input/object.yaml`, escribe los recursos deseados en `/kratix/output/` y puede fijar metadata (destino, status) en `/kratix/metadata/`:

```bash
#!/usr/bin/env sh
set -euo pipefail

# Entrada: el CR que pidió el usuario
size=$(yq '.spec.size' /kratix/input/object.yaml)
name=$(yq '.metadata.name' /kratix/input/object.yaml)

# Traducir tamaño abstracto a instancia concreta del operador
[ "$size" = "large" ] && instances=3 || instances=1

# Salida: manifiesto que Kratix distribuirá al Destination vía State Store
cat > /kratix/output/postgres.yaml <<EOF
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: ${name}
spec:
  numberOfInstances: ${instances}
  postgresql:
    version: "16"
  volume:
    size: 10Gi
EOF

# Metadata opcional: sobrescribir destino, escribir status de vuelta al request
echo "message: Provisioned ${size} PostgreSQL (${instances} replicas)" \
  > /kratix/metadata/status.yaml
```

**Request de usuario** (equivalente al Claim de Crossplane):

```yaml
apiVersion: marketplace.kratix.io/v1alpha1
kind: postgresql
metadata:
  name: orders-db
  namespace: team-payments
spec:
  size: large
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Crossplane — flujo de trabajo y observación

```bash
$ kubectl get providers
NAME                INSTALLED   HEALTHY   PACKAGE                                             AGE
provider-aws-s3     True        True      xpkg.upbound.io/upbound/provider-aws-s3:v1.21.1     4m
provider-aws-rds    True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.21.1    4m

$ kubectl get functions
NAME                            INSTALLED   HEALTHY   PACKAGE                                                               AGE
function-patch-and-transform    True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform...   3m
function-auto-ready             True        True      xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.0         3m

$ kubectl apply -f claim.yaml
postgresqlinstance.database.platform.example.org/orders-db created

# El Claim crea un XR (cluster-scoped) con nombre autogenerado:
$ kubectl get postgresqlinstance -n team-payments
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      35s

$ kubectl get composite
NAME                         SYNCED   READY   COMPOSITION       AGE
orders-db-7f946             True     False   xpostgresql.aws   38s

# Todos los Managed Resources del cluster (nivel bajo):
$ kubectl get managed
NAME                                  READY   SYNCED   EXTERNAL-NAME          AGE
instance.rds.aws.upbound.io/orders-db-7f946-r2k9m   False   True    orders-db-7f946-r2k9m   50s
```

La herramienta de diagnóstico clave es **`crossplane beta trace`**, que muestra el árbol XR → recursos compuestos → Managed Resources con sus condiciones:

```bash
$ crossplane beta trace postgresqlinstance/orders-db -n team-payments
NAME                                      SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-payments)  True   False   Waiting: ...
└─ XPostgreSQLInstance/orders-db-7f946      True     False   Creating: Unready resources: rds-instance
   └─ Instance/orders-db-7f946-r2k9m        True     False   Creating: creating DB instance

# Minutos después:
$ crossplane beta trace postgresqlinstance/orders-db -n team-payments
NAME                                      SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-payments)  True   True    Available
└─ XPostgreSQLInstance/orders-db-7f946      True     True    Available
   └─ Instance/orders-db-7f946-r2k9m        True     True    Available

# El Secret de conexión aparece en el namespace del Claim:
$ kubectl get secret orders-db-conn -n team-payments -o jsonpath='{.data.endpoint}' | base64 -d
orders-db-7f946.abc123.eu-west-1.rds.amazonaws.com
```

Validar packages y renderizar una Composition **sin aplicarla** (dry-run local, muy útil en CI):

```bash
$ crossplane render xr.yaml composition.yaml functions.yaml
---
apiVersion: rds.aws.upbound.io/v1beta2
kind: Instance
metadata:
  annotations:
    crossplane.io/composition-resource-name: rds-instance
  generateName: orders-db-
spec:
  forProvider:
    allocatedStorage: 50
    instanceClass: db.t3.medium
    region: eu-west-1
    ...

$ crossplane validate provider-aws-rds.yaml composition.yaml
[✓] xpostgresql.aws validated successfully
```

### 4.2 Kratix — flujo de trabajo y observación

```bash
$ kubectl get promises
NAME         STATUS      KIND         API VERSION                          VERSION
postgresql   Available   postgresql   marketplace.kratix.io/v1alpha1       v1.0.0

$ kubectl get destinations
NAME            AGE
worker-dev-eu   12m

$ kubectl apply -f request.yaml
postgresql.marketplace.kratix.io/orders-db created

# Kratix crea un Work por request y lo coloca (WorkPlacement) en un Destination:
$ kubectl get works.platform.kratix.io -A
NAMESPACE       NAME                             AGE
team-payments   orders-db-postgresql-abc12       20s

$ kubectl get workplacements.platform.kratix.io -A
NAMESPACE       NAME                                       DESTINATION      AGE
team-payments   orders-db-postgresql-abc12.worker-dev-eu   worker-dev-eu    18s

# El pipeline corre como un Job en el platform cluster:
$ kubectl get jobs -n team-payments
NAME                                  COMPLETIONS   DURATION   AGE
kratix-postgresql-orders-db-instance  1/1           14s        40s

$ kubectl logs job/kratix-postgresql-orders-db-instance -n team-payments -c generate-postgres-manifest
Provisioned large PostgreSQL (3 replicas)
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Las dos condiciones que hay que leer siempre (Crossplane)

Todo Managed Resource y todo XR exponen dos condiciones ortogonales. Confundirlas es el error de diagnóstico más común:

| Condición | Significa | Si es `False`, mirar… |
|---|---|---|
| **`Synced`** | El controller **pudo hablar** con la cloud API y reconciliar la spec (auth, cuotas, campos válidos) | ProviderConfig, credenciales, permisos IAM, validación de campos |
| **`Ready`** | El recurso cloud **existe y está operativo** según su propio estado | El servicio cloud (aprovisionamiento en curso, límites de servicio) |

```bash
$ kubectl get instance.rds.aws.upbound.io/orders-db-7f946-r2k9m -o yaml | yq '.status.conditions'
- type: Synced
  status: "False"
  reason: ReconcileError
  message: "cannot create Instance: AccessDenied: User is not authorized to perform rds:CreateDBInstance"
- type: Ready
  status: "False"
  reason: Creating
```

`Synced=False` con `reason: ReconcileError` → **problema de plataforma** (IAM/credenciales/campo inválido/cuota). `Synced=True, Ready=False` durante rato prolongado → **el cloud tarda o falla** (revisar consola del proveedor). Complementá con eventos y logs del provider:

```bash
$ kubectl describe instance.rds.aws.upbound.io/orders-db-7f946-r2k9m | tail -n 15
Events:
  Type     Reason                   Age   From                                   Message
  ----     ------                   ----  ----                                   -------
  Warning  CannotCreateExternalResource  30s   managed/rds.aws.upbound.io/v1beta2, kind=instance
           cannot create: AccessDenied: rds:CreateDBInstance

$ kubectl -n crossplane-system logs deploy/provider-aws-rds-<hash> --tail=20 | grep -i error
```

### 5.2 Fallas típicas de Crossplane y su firma

| Síntoma | Causa raíz probable | Verificación / arreglo |
|---|---|---|
| `Provider INSTALLED=True, HEALTHY=False` | Imagen del provider no arranca / recursos insuficientes | `kubectl -n crossplane-system get pods`; `describe` del pod; `DeploymentRuntimeConfig` |
| Claim `SYNCED=False`, sin XR creado | Composition no seleccionada (falta `compositionRef`/label) | `kubectl describe` el XR; revisar `defaultCompositionRef` del XRD |
| XR `SYNCED=False: cannot resolve function` | Function no instalada o no `HEALTHY` | `kubectl get functions`; instalar `function-patch-and-transform` |
| MR queda en `Creating` para siempre | Campo obligatorio faltante o valor inválido para el cloud | `crossplane render` local; leer `status.conditions[].message` |
| Al borrar el Claim, el recurso cloud sobrevive | `deletionPolicy: Orphan` o dependencia `Usage` bloqueando | `kubectl get usages`; revisar `deletionPolicy` |
| Secret de conexión vacío | `writeConnectionSecretToRef` mal apuntado o el MR aún no `Ready` | Verificar namespace/nombre; esperar `Ready=True` |
| Drift: el recurso vuelve a un estado que "arreglé a mano" | Es el comportamiento correcto: el controller reconcilia. Para pausar: | anotar `crossplane.io/paused: "true"` en el MR |

```bash
# Pausar la reconciliación de un recurso (ventana de mantenimiento):
$ kubectl annotate instance.rds.aws.upbound.io/orders-db-7f946-r2k9m \
    crossplane.io/paused="true"

# Importar un recurso existente sin gestionarlo (observe-only):
#   managementPolicies: ["Observe"] + crossplane.io/external-name: <id real>
```

### 5.3 Fallas típicas de Kratix y su firma

| Síntoma | Causa raíz probable | Verificación / arreglo |
|---|---|---|
| Request creado pero **no hay WorkPlacement** | Ningún Destination matchea los `destinationSelectors` | `kubectl get destinations --show-labels`; alinear labels |
| Promise `STATUS != Available` | Falla el `promise.configure` (dependencias/operador) | `kubectl get jobs`; logs del pipeline de promise |
| Job del pipeline en `Error`/`BackoffLimitExceeded` | Bug en el contenedor; salida mal formada en `/kratix/output` | `kubectl logs job/<...>`; validar el YAML emitido |
| WorkPlacement creado pero el recurso no aparece en el worker | GitOps agent (Flux/Argo) no sincroniza el State Store | Revisar Flux/Argo en el worker; credenciales del bucket/git |
| Cambios al request no re-disparan el pipeline | Kratix re-ejecuta en cada update; si no, revisar el hash del input | `kubectl describe` el request; ver Jobs nuevos |

```bash
$ kubectl get destinations --show-labels
NAME            AGE   LABELS
worker-dev-eu   20m   environment=dev,region=eu

# Si la Promise pide environment=prod y no hay Destination con ese label,
# el Work queda pendiente sin WorkPlacement — no es un error, es scheduling sin match:
$ kubectl get works.platform.kratix.io -A
NAMESPACE       NAME                        AGE
team-payments   orders-db-postgresql-xyz    3m   # sin WorkPlacement asociado
```

### 5.4 Checklist de verificación de aprovisionamiento (producción)

1. **Provider/Function HEALTHY** antes de aplicar cualquier Composition (`kubectl get providers,functions`).
2. **`crossplane render` en CI** sobre XR+Composition+Functions: valida que el pipeline produce recursos correctos *sin* tocar el cloud.
3. **Claim/Request aplicado** → confirmar aparición del XR/Work en segundos.
4. **`crossplane beta trace`** hasta `Ready=True` en todos los niveles (Crossplane) o `WorkPlacement` + Job `Completed` (Kratix).
5. **Secret de conexión presente y no vacío** en el namespace del consumidor.
6. **Prueba de drift** (staging): modificar el recurso cloud a mano y verificar que el controller lo revierte (Crossplane) / que Flux/Argo lo re-sincroniza (Kratix).
7. **Prueba de borrado** con `deletionPolicy`/`Usage` esperados: confirmar que no quedan recursos huérfanos ni se borra algo aún en uso.

---

## 6. Referencias

- CNCF Curriculum — CNPA (Cloud Native Platform Engineering Associate): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Crossplane — Documentación oficial: https://docs.crossplane.io/
- Crossplane — Composite Resources & Compositions: https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane — Composition Functions: https://docs.crossplane.io/latest/concepts/composition-functions/
- Crossplane — Managed Resources y policies: https://docs.crossplane.io/latest/concepts/managed-resources/
- Crossplane — CLI (`render`, `beta trace`, `validate`): https://docs.crossplane.io/latest/cli/
- Crossplane v2 — What's new: https://docs.crossplane.io/v2.0/whats-new/
- Crossplane (proyecto CNCF): https://www.cncf.io/projects/crossplane/
- Upbound Marketplace (providers y functions): https://marketplace.upbound.io/
- Kratix — Documentación oficial: https://docs.kratix.io/
- Kratix — Promise: https://docs.kratix.io/main/reference/promises/intro
- Kratix — Workflows y pipelines: https://docs.kratix.io/main/reference/workflows/intro
- Kratix — Destinations y State Stores: https://docs.kratix.io/main/reference/destinations/intro
- Kratix (proyecto CNCF Sandbox): https://www.cncf.io/projects/kratix/
- Cluster API — The Cluster API Book: https://cluster-api.sigs.k8s.io/
- AWS Controllers for Kubernetes (ACK): https://aws-controllers-k8s.github.io/community/
- GCP Config Connector: https://cloud.google.com/config-connector/docs/overview
- Azure Service Operator: https://azure.github.io/azure-service-operator/