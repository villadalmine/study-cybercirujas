# Tema 5.4 — Using Automation Frameworks for Self-Service Provisioning

> **Certificación:** CNPE (Cloud Native Platform Engineering) · **Peso:** 6.25 %
> **Perfil:** Platform Architect / SRE Senior · **Nivel:** Producción

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El cuello de botella del *ticket ops*

En una organización sin plataforma, el flujo para que un equipo de desarrollo obtenga una base de datos, un cluster o un bucket es siempre el mismo antipatrón:

```
Dev → Jira ticket → cola de Ops → ejecución manual (o semi-manual) → handoff → drift
```

Este modelo tiene tres fallas estructurales que un Platform Engineer debe erradicar:

1. **Latencia acoplada al headcount de Ops.** El *lead time* de aprovisionamiento crece linealmente con la demanda y está topeado por la disponibilidad de un equipo central. Es el opuesto de la escalabilidad.
2. **Deriva de configuración (*snowflake infrastructure*).** Cada ejecución manual produce recursos ligeramente distintos. No hay una fuente de verdad reconciliada; hay N estados divergentes.
3. **Carga cognitiva mal distribuida.** El desarrollador debe conocer IAM, VPCs, `StorageClass`, parámetros de RDS… conocimiento que no aporta a su producto. Team Topologies llama a esto *extraneous cognitive load*.

### 1.2 La tesis de Platform Engineering: *self-service* con *golden paths*

La respuesta de CNPE es tratar la **plataforma como un producto** (Platform-as-a-Product) cuyos clientes son los equipos de desarrollo internos. El aprovisionamiento *self-service* se apoya en dos abstracciones complementarias:

- **Golden path / paved road:** un camino opinado, pre-aprobado y automatizado para la tarea del 80 % de los casos. No prohíbe salirse del camino, pero hace que el camino correcto sea el más fácil.
- **Abstracción de plataforma (API interna):** el desarrollador declara *intención* de alto nivel (`quiero una PostgreSQL de 20 GB`), no *implementación* (subnets, security groups, parameter groups). La plataforma traduce intención → recursos concretos, aplica *guardrails* y reconcilia.

El diagrama de fuerzas del *self-service* de producción:

```
┌────────────────────────────────────────────────────────────────┐
│                    PLANO DE EXPERIENCIA (UX)                     │
│   Backstage Portal · Port · CLI interna · PR en Git             │
│   → El dev expresa INTENCIÓN de alto nivel                      │
└───────────────────────────┬────────────────────────────────────┘
                            │  (claim / Template / Score / PR)
┌───────────────────────────▼────────────────────────────────────┐
│              PLANO DE CONTROL (orquestación)                    │
│   Crossplane · Kratix · Cluster API · Terraform Controller      │
│   → Traduce intención → recursos; RECONCILIA continuamente      │
├──────────────────────────────────────────────────────────────  ┤
│              PLANO DE GOBIERNO (guardrails)                     │
│   Kyverno / OPA Gatekeeper · RBAC · Cost policies · OpenCost    │
└───────────────────────────┬────────────────────────────────────┘
                            │  (managed resources)
┌───────────────────────────▼────────────────────────────────────┐
│              INFRAESTRUCTURA (cloud + k8s)                      │
│   AWS/GCP/Azure · Kubernetes · DBs · redes · DNS               │
└────────────────────────────────────────────────────────────────┘
```

### 1.3 Por qué el *control plane pattern* (reconciliación) gana en producción

El salto arquitectónico central del tema es pasar de **ejecución** (correr un script, aplicar Terraform una vez) a **reconciliación** (un controlador que compara estado deseado vs. observado en un loop infinito y converge). La diferencia no es cosmética:

| Propiedad | Ejecución imperativa (script/plan-apply) | Reconciliación (control plane) |
|---|---|---|
| Corrección de drift | Manual, requiere re-ejecutar | Automática y continua |
| Fuente de verdad | El último `apply` (efímero) | El objeto en `etcd` (persistente) |
| Modelo de fallo | *Fail-and-stop*, estado a medias | *Retry con backoff* hasta converger |
| Auditoría | Logs de CI dispersos | `kubectl get`, eventos, conditions |
| Extensibilidad | Módulos/roles | CRDs + controllers (KRM) |

El **Kubernetes Resource Model (KRM)** se vuelve la lingua franca del aprovisionamiento: todo —una base de datos RDS, un repositorio de GitHub, un registro DNS— se representa como objeto declarativo reconciliado por un controlador. Esto es lo que habilita que herramientas como Crossplane y Kratix conviertan a Kubernetes en un *universal control plane*.

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Frameworks de aprovisionamiento

| Dimensión | **Crossplane** | **Terraform / OpenTofu** | **Ansible (AAP/EDA)** | **Cluster API (CAPI)** | **Kratix** |
|---|---|---|---|---|---|
| Modelo | Reconciliación (KRM) | Plan-apply (por defecto) | Push imperativo (idempotente) | Reconciliación (KRM) | Reconciliación (Promises) |
| Estado | `etcd` (no state file externo) | State file (S3/Consul/TFC) | Sin estado (fact-driven) | `etcd` | `etcd` + destinos |
| Drift correction | Continua, nativa | No (salvo re-plan/`refresh`) | No (re-run) | Continua | Continua |
| Unidad de abstracción | XRD + Composition | Módulo | Role / Playbook | ClusterClass | Promise |
| Multi-tenancy | Claims namespaced + RBAC | Workspaces | Inventarios | Namespaces | Destinations |
| Curva de aprendizaje | Alta (composición) | Media | Baja-media | Alta | Media |
| Madurez ecosistema | Amplia (Upbound providers) | Enorme (miles de providers) | Enorme | k8s-céntrico | Emergente |
| Fit ideal | API interna de recursos | IaC generalista | Config de SO / day-2 | Provisión de clusters | Plataforma como producto |

> **Regla de arquitecto:** no son excluyentes. Un patrón de producción frecuente es Crossplane como *control plane* de recursos, con `provider-terraform` o `tofu-controller` para reutilizar módulos Terraform ya existentes, y Cluster API por debajo para los clusters mismos.

### 2.2 Orquestadores de IDP / portales de *self-service*

| | **Backstage** | **Port** | **Humanitec** | **Kratix** | **KubeVela** |
|---|---|---|---|---|---|
| Naturaleza | Portal + catálogo (CNCF incubating) | SaaS, catálogo + acciones | SaaS, Platform Orchestrator | Framework OSS server-side | Delivery engine (OAM) |
| Self-service | Software Templates (scaffolder) | Self-service actions | Score → deployment sets | Promises + Requests | Applications (OAM) |
| Motor de ejecución | Externo (CI/GitOps) | Externo (webhooks/Argo) | Interno (matcher) | Pipelines internos | Interno |
| Hosting | Self-hosted | SaaS | SaaS | Self-hosted | Self-hosted |
| Lock-in | Bajo (OSS) | Medio | Medio-alto | Bajo | Bajo |
| Sweet spot | Grandes orgs, catálogo rico | Time-to-value rápido | Orquestación dinámica | Vender plataforma "as a service" | Multi-cluster app delivery |

### 2.3 Entrega: *push* vs. *pull* GitOps para el *self-service*

| | Push (CI aplica `kubectl`/`terraform`) | Pull (Argo CD / Flux reconcilia) |
|---|---|---|
| Credenciales de cluster | En el runner de CI (riesgo) | Dentro del cluster (menor superficie) |
| Drift | No detectado entre runs | Detectado y corregido |
| Auditoría | Logs de CI | Estado + historia en Git |
| Recomendación CNPE | Solo para *bootstrap* | **Estándar de producción** |

---

## 3. Manifiestos YAML e infraestructura completos

Construiremos un *golden path* end-to-end: **el dev pide una PostgreSQL desde Backstage → PR a Git → Crossplane la aprovisiona en AWS → Kyverno impone guardrails**.

### 3.1 Crossplane — Provider y ProviderConfig

```yaml
# provider.yaml — instala el provider RDS (familia Upbound, granular)
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.16.0
  # RuntimeConfig sustituye al deprecado ControllerConfig
  runtimeConfigRef:
    name: default
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: default
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              args:
                - --enable-management-policies   # habilita ObserveOnly, etc.
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  memory: 512Mi
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: IRSA          # IAM Roles for Service Accounts — sin secretos estáticos
  # Alternativa con Secret:
  # credentials:
  #   source: Secret
  #   secretRef:
  #     namespace: crossplane-system
  #     name: aws-creds
  #     key: creds
```

> **Nota de seguridad de producción:** `source: IRSA` (o `WebIdentity`/Workload Identity en GKE) elimina las llaves de larga vida. Nunca embebas `aws_access_key_id` en un `Secret` de larga duración si el cloud ofrece federación OIDC.

### 3.2 Crossplane — CompositeResourceDefinition (XRD): la API interna

```yaml
# xrd.yaml — define la API que verá el desarrollador
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.acme.internal
spec:
  group: database.acme.internal
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:                 # el claim es el objeto namespaced que usa el dev
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: postgresql-aws
  connectionSecretKeys:       # llaves expuestas al app team vía connection secret
    - username
    - password
    - endpoint
    - port
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
                      maximum: 500
                    size:
                      type: string
                      description: T-shirt size del engine
                      enum: [small, medium, large]
                      default: small
                    region:
                      type: string
                      default: us-east-1
                  required:
                    - storageGB
              required:
                - parameters
            status:
              type: object
              properties:
                endpoint:
                  type: string
```

### 3.3 Crossplane — Composition en modo Pipeline (composition functions)

El modo `Pipeline` con *composition functions* es el enfoque recomendado desde Crossplane v1.14+; reemplaza el antiguo `resources` con `patchSets` embebidos.

```yaml
# composition.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: database.acme.internal/v1alpha1
    kind: XPostgreSQLInstance
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: rds-subnet-group
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: SubnetGroup
              spec:
                forProvider:
                  region: us-east-1
                  subnetIdSelector:
                    matchLabels:
                      network: internal
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: Instance
              spec:
                forProvider:
                  region: us-east-1
                  engine: postgres
                  engineVersion: "15.5"
                  instanceClass: db.t3.small
                  username: masteruser
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: ""       # patch lo completa por-claim
                    key: password
                  dbSubnetGroupNameSelector:
                    matchControllerRef: true
                  storageEncrypted: true
                  skipFinalSnapshot: false
                  publiclyAccessible: false
            connectionDetails:
              - name: endpoint
                type: FromFieldPath
                fromFieldPath: status.atProvider.address
              - name: port
                type: FromFieldPath
                fromFieldPath: status.atProvider.port
              - name: username
                type: FromFieldPath
                fromFieldPath: spec.forProvider.username
              - name: password
                type: FromConnectionSecretKey
                fromConnectionSecretKey: password
            patches:
              # storageGB del claim → allocatedStorage del RDS
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              # región propagada
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              # t-shirt size → instanceClass, con map
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.size
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      small: db.t3.small
                      medium: db.t3.medium
                      large: db.r6g.large
              # nombre único del secret de password por claim
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.uid
                toFieldPath: spec.forProvider.passwordSecretRef.name
                transforms:
                  - type: string
                    string:
                      fmt: "%s-pw"
    - step: auto-ready
      functionRef:
        name: function-auto-ready   # marca el XR Ready cuando los MRs lo están
```

Las *composition functions* usadas se instalan como paquetes:

```yaml
# functions.yaml
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.0
```

### 3.4 El *claim* — lo único que escribe el desarrollador

```yaml
# claim.yaml — vive en el namespace del equipo, va por PR a Git
apiVersion: database.acme.internal/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-payments
spec:
  parameters:
    storageGB: 50
    size: medium
    region: us-east-1
  compositionRef:
    name: postgresql-aws
  writeConnectionSecretToRef:
    name: orders-db-conn     # aquí aparecen endpoint/user/password
```

### 3.5 Guardrail — política Kyverno sobre los claims

```yaml
# policy.yaml — impone límites que la XRD sola no cubre (p.ej. región permitida)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-db-region
  annotations:
    policies.kyverno.io/description: >-
      Los claims de PostgreSQL solo pueden aprovisionar en regiones aprobadas
      y deben llevar etiqueta de cost-center.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: allowed-regions
      match:
        any:
          - resources:
              kinds:
                - database.acme.internal/v1alpha1/PostgreSQLInstance
      validate:
        message: "region debe ser us-east-1 o eu-west-1"
        pattern:
          spec:
            parameters:
              region: "us-east-1 | eu-west-1"
    - name: require-cost-center
      match:
        any:
          - resources:
              kinds:
                - database.acme.internal/v1alpha1/PostgreSQLInstance
      validate:
        message: "falta la label acme.internal/cost-center"
        pattern:
          metadata:
            labels:
              acme.internal/cost-center: "?*"
```

### 3.6 Backstage — Software Template (scaffolder) que genera el claim

```yaml
# template.yaml — catalogado en Backstage; produce un PR con el claim de 3.4
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: postgresql-golden-path
  title: PostgreSQL (self-service)
  description: Aprovisiona una PostgreSQL gestionada por Crossplane vía GitOps
  tags: [database, aws, golden-path]
spec:
  owner: platform-team
  type: resource
  parameters:
    - title: Configuración de la base de datos
      required: [name, storageGB, size]
      properties:
        name:
          title: Nombre
          type: string
          pattern: '^[a-z][a-z0-9-]{2,30}$'
        storageGB:
          title: Almacenamiento (GB)
          type: integer
          default: 20
          minimum: 20
          maximum: 500
        size:
          title: Tamaño
          type: string
          default: small
          enum: [small, medium, large]
        team:
          title: Namespace del equipo
          type: string
          ui:field: OwnerPicker
  steps:
    - id: fetch
      name: Renderizar claim
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          storageGB: ${{ parameters.storageGB }}
          size: ${{ parameters.size }}
          team: ${{ parameters.team }}
    - id: pr
      name: Abrir Pull Request
      action: publish:github:pull-request
      input:
        repoUrl: github.com?owner=acme&repo=platform-claims
        branchName: add-db-${{ parameters.name }}
        title: "feat: PostgreSQL ${{ parameters.name }}"
        description: Generado por el golden path de Backstage
        targetPath: claims/${{ parameters.team }}
    - id: register
      name: Registrar en catálogo
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.pr.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Pull Request
        url: ${{ steps.pr.output.remoteUrl }}
```

### 3.7 Argo CD — Application que reconcilia los claims (pull GitOps)

```yaml
# app-claims.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-claims
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://github.com/acme/platform-claims.git
    targetRevision: main
    path: claims
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true       # corrige drift: reaplica si alguien edita a mano
    syncOptions:
      - CreateNamespace=true
```

### 3.8 (Alternativa) Kratix — Promise: la plataforma como producto

```yaml
# promise.yaml — empaqueta API + dependencias + pipeline en un solo objeto
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
spec:
  api:                       # el CRD que verá el consumidor
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.acme.io
    spec:
      group: acme.io
      names:
        kind: postgresql
        plural: postgresqls
        singular: postgresql
      scope: Namespaced
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
                      enum: [small, large]
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: create-db
                image: acme/postgresql-request-pipeline:v1.0.0
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Instalación de Crossplane y verificación de providers

```console
$ helm repo add crossplane-stable https://charts.crossplane.io/stable
$ helm install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait
NAME: crossplane
LAST DEPLOYED: Fri Aug  7 10:12:03 2026
NAMESPACE: crossplane-system
STATUS: deployed
REVISION: 1

$ kubectl apply -f provider.yaml
provider.pkg.crossplane.io/provider-aws-rds created

$ kubectl get providers
NAME                INSTALLED   HEALTHY   PACKAGE                                                 AGE
provider-aws-rds    True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.16.0        94s
```

Un provider `INSTALLED=True HEALTHY=False` casi siempre significa que la imagen del runtime falló al arrancar (revisar `kubectl get pods -n crossplane-system` y `describe`).

### 4.2 Aplicar XRD, Composition y functions

```console
$ kubectl apply -f functions.yaml -f xrd.yaml -f composition.yaml
function.pkg.crossplane.io/function-patch-and-transform created
function.pkg.crossplane.io/function-auto-ready created
compositeresourcedefinition.apiextensions.crossplane.io/xpostgresqlinstances.database.acme.internal created
composition.apiextensions.crossplane.io/postgresql-aws created

$ kubectl get xrd
NAME                                              ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.database.acme.internal       True          True      12s
```

`ESTABLISHED=True` indica que el XR CRD ya está registrado; `OFFERED=True` que el claim CRD también (porque definimos `claimNames`).

### 4.3 Crear el claim y trazar la composición

```console
$ kubectl apply -f claim.yaml
postgresqlinstance.database.acme.internal/orders-db created

$ kubectl get postgresqlinstance -n team-payments
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      20s
```

La herramienta clave de diagnóstico es `crossplane beta trace`, que muestra el árbol claim → XR → managed resources con sus conditions:

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-payments
NAME                                    SYNCED   READY   STATUS
PostgreSQLInstance/orders-db            True     False   Waiting: ...
└─ XPostgreSQLInstance/orders-db-7fk2x  True     False   Creating: Composed resources not ready
   ├─ SubnetGroup/orders-db-7fk2x-sg    True     True    Available
   └─ Instance/orders-db-7fk2x-9m4qд    True     False   Creating: RDS instance is creating
```

Cuando el RDS termina de crearse (~5–8 min):

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-payments
NAME                                    SYNCED   READY   STATUS
PostgreSQLInstance/orders-db            True     True    Available
└─ XPostgreSQLInstance/orders-db-7fk2x  True     True    Available
   ├─ SubnetGroup/orders-db-7fk2x-sg    True     True    Available
   └─ Instance/orders-db-7fk2x-9m4qд    True     True    Available

$ kubectl get secret orders-db-conn -n team-payments \
    -o jsonpath='{.data.endpoint}' | base64 -d
orders-db-7fk2x.abc123.us-east-1.rds.amazonaws.com
```

### 4.4 Verificar el guardrail Kyverno

```console
$ cat bad-claim.yaml
apiVersion: database.acme.internal/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: eu-db
  namespace: team-payments
spec:
  parameters: { storageGB: 20, size: small, region: ap-south-1 }

$ kubectl apply -f bad-claim.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource PostgreSQLInstance/team-payments/eu-db was blocked due to the following policies

restrict-db-region:
  allowed-regions: 'region debe ser us-east-1 o eu-west-1'
  require-cost-center: 'falta la label acme.internal/cost-center'
```

### 4.5 Empaquetar y publicar una Configuration (xpkg)

Las XRDs + Compositions se distribuyen como *Configuration package* versionado (OCI), no como YAML suelto:

```console
$ crossplane xpkg build --package-root=. \
    --package-file=postgresql-config.xpkg
crossplane: built package: postgresql-config.xpkg

$ crossplane xpkg push \
    -f postgresql-config.xpkg \
    xpkg.upbound.io/acme/platform-postgresql:v1.2.0
xpkg pushed to xpkg.upbound.io/acme/platform-postgresql:v1.2.0
```

### 4.6 Terraform/OpenTofu reutilizado desde el control plane (tofu-controller)

```console
$ kubectl get terraforms -A
NAMESPACE   NAME         READY   STATUS                        AGE
infra       vpc-shared   True    No drift: main@a1b2c3d        3d

$ kubectl -n infra describe terraform vpc-shared | grep -A4 Conditions
  Conditions:
    Type:    Ready
    Status:  True
    Reason:  TerraformOutputsAvailable
    Message: Outputs written to secret 'vpc-shared-outputs'
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 El binomio de conditions: `Synced` vs. `Ready`

Todo objeto de Crossplane expone dos conditions ortogonales; entender la matriz es el 80 % del debugging:

| `SYNCED` | `READY` | Interpretación | Acción |
|---|---|---|---|
| True | True | Recurso existe y converge | OK |
| True | False | Reconcilia bien, pero el recurso externo aún no está listo | Esperar (creación en curso) o revisar estado del cloud |
| False | False | El controlador **no puede** reconciliar | **Aquí está el bug** (credenciales, permisos, campo inválido) |
| False | True | Estado transitorio raro | Revisar eventos |

**Regla:** `SYNCED=False` es un problema de la plataforma; `READY=False` con `SYNCED=True` suele ser tiempo o el proveedor cloud.

### 5.2 Árbol de decisión de diagnóstico

```
Claim no progresa
├─ ¿El claim tiene un XR? (kubectl describe claim → 'Composite Resource')
│   └─ No → falla la selección de Composition
│       → revisar compositionRef / matchLabels / defaultCompositionRef
├─ ¿El XR tiene managed resources? (crossplane beta trace)
│   └─ No → error en el pipeline de composición
│       → kubectl describe composite <xr>; buscar eventos de function-*
├─ ¿Los MRs están SYNCED=False?
│   └─ Sí → problema de provider
│       → kubectl -n crossplane-system logs deploy/<provider> 
│       → causas típicas: credenciales (ProviderConfig), IAM/RBAC,
│         campo forProvider inválido, cuota del cloud
└─ ¿SYNCED=True, READY=False y no avanza?
    └─ Estado del recurso en el cloud (consola/API); cuota; dependencia
```

### 5.3 Comandos de diagnóstico esenciales

```console
# Ver el evento exacto que bloquea un managed resource
$ kubectl describe instance.rds.aws.upbound.io orders-db-7fk2x-9m4q | \
    sed -n '/Events:/,$p'
Events:
  Type     Reason                   Age   From                   Message
  ----     ------                   ----  ----                   -------
  Warning  CannotObserveExternalResource  2m  managed/instance   observe failed:
    cannot run refresh: AccessDenied: User is not authorized to perform:
    rds:DescribeDBInstances

# Logs del provider (la fuente de verdad de los errores de API cloud)
$ kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-aws-rds \
    --tail=20 | grep -i error

# ¿Qué composition eligió realmente el XR?
$ kubectl get xpostgresqlinstance orders-db-7fk2x \
    -o jsonpath='{.spec.compositionRef.name}{"\n"}'
postgresql-aws

# Verificar que las composition functions están sanas
$ kubectl get functions
NAME                            INSTALLED   HEALTHY   AGE
function-patch-and-transform    True        True      1h
function-auto-ready             True        True      1h
```

### 5.4 Fallas de producción frecuentes y su firma

| Síntoma | Causa raíz probable | Verificación / fix |
|---|---|---|
| `Provider HEALTHY=False` | Runtime pod crashea (RBAC, límites de memoria) | `kubectl -n crossplane-system get pods`; subir `memory` en DeploymentRuntimeConfig |
| Claim sin XR | No matchea ninguna Composition | Revisar `compositionRef`/`compositionSelector.matchLabels` vs. labels de la Composition |
| MR `AccessDenied` | IAM/IRSA sin permisos | Ampliar policy del rol; validar `ProviderConfig` |
| MR `SYNCED=False`, campo inválido | Patch escribe un valor fuera de rango del API cloud | `describe` del MR; corregir Composition, no el MR |
| Connection secret vacío | `connectionDetails`/`writeConnectionSecretToRef` mal | Verificar `connectionSecretKeys` en XRD y `connectionDetails` en Composition |
| Drift reaparece tras editar a mano | Reconciliación (¡esperado!) | Editar la Composition/claim en Git, no el recurso vivo |
| Template de Backstage falla en `publish` | Token/PAT sin scope de repo | Revisar integraciones en `app-config.yaml`; scopes del token |
| Argo CD `OutOfSync` permanente | El controller muta campos que Argo no ignora | Añadir `ignoreDifferences` para campos gestionados por Crossplane |

### 5.5 Validación pre-merge (shift-left) del *golden path*

Antes de que un claim llegue al cluster, valídalo en CI para no depender solo del admission webhook:

```console
# Render + validación de políticas en el pipeline del PR
$ kyverno apply policy.yaml --resource claim.yaml
Applying 2 policy rule(s) to 1 resource(s)...

pass: 2, fail: 0, warn: 0, error: 0, skip: 0

# Validación de sintaxis del XRD/Composition (dry-run server-side)
$ kubectl apply --dry-run=server -f xrd.yaml -f composition.yaml
compositeresourcedefinition.apiextensions.crossplane.io/... configured (server dry run)
composition.apiextensions.crossplane.io/postgresql-aws configured (server dry run)
```

### 5.6 Observabilidad y *day-2* del plano de control

- **Métricas:** Crossplane expone métricas Prometheus (`crossplane_managed_resource_exists`, latencias de reconciliación). Alertar sobre MRs con `SYNCED=False` sostenido.
- **Costos:** integrar OpenCost/Kubecost + tags de cost-center impuestos por Kyverno (§3.5) para *showback*.
- **SLO del self-service:** medir *lead time* del claim (creación → `READY=True`) como SLI del producto plataforma; es la métrica que justifica la inversión frente al *ticket ops* (§1.1).

---

## 6. Referencias

- CNCF — CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Crossplane — Documentación oficial: https://docs.crossplane.io/
- Crossplane — Composition functions: https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane — CompositeResourceDefinitions: https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane — CLI (`crossplane beta trace`, `xpkg`): https://docs.crossplane.io/latest/cli/
- Upbound — Official Providers (marketplace): https://marketplace.upbound.io/
- Backstage — Software Templates (scaffolder): https://backstage.io/docs/features/software-templates/
- Backstage — Scaffolder actions: https://backstage.io/docs/features/software-templates/builtin-actions/
- Kratix — Documentación (Promises): https://docs.kratix.io/
- Cluster API — The Cluster API Book: https://cluster-api.sigs.k8s.io/
- Kyverno — Documentación de políticas: https://kyverno.io/docs/
- Argo CD — Declarative GitOps: https://argo-cd.readthedocs.io/
- Flux `tofu-controller`: https://flux-iac.github.io/tofu-controller/
- OpenTofu — Documentación: https://opentofu.org/docs/
- Score — Workload specification: https://docs.score.dev/
- KubeVela / Open Application Model: https://kubevela.io/docs/
- CNCF Platforms White Paper (Platform Engineering): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- Team Topologies (carga cognitiva, platform-as-a-product): https://teamtopologies.com/