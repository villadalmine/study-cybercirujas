# Tema 5.2 — API-Driven Service Catalogs and Infrastructure Abstractions

> Dominio 5 — *Platform APIs & Provisioning* · Peso en el examen: **2.0** · Perfil: SRE / Platform Architect

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El síntoma: "ticket ops" y el cuello de botella del equipo de plataforma

En una organización sin plataforma interna madura, cuando un equipo de aplicación necesita una base de datos, un bucket, un topic de Kafka o un cluster, el flujo real es:

1. El developer abre un ticket en Jira/ServiceNow describiendo lo que quiere en lenguaje natural.
2. El equipo de infraestructura interpreta el ticket, abre una consola cloud o corre Terraform a mano, y aprovisiona.
3. Devuelve credenciales por un canal informal (Slack, un secret pegado, un vault manual).
4. Cualquier cambio (crecer el disco, rotar credenciales, migrar de región) repite el ciclo completo.

Esto tiene tres fallas estructurales, no de proceso:

- **El equipo de plataforma es un componente síncrono en el camino crítico de cada equipo de producto.** Escala O(n) con la cantidad de equipos: es el anti-patrón que la disciplina de Platform Engineering existe para eliminar. La CNCF lo formaliza como la diferencia entre un *platform team* que construye **golden paths** self-service y un *ops team* que atiende tickets (CNCF *Platform Engineering Maturity Model*).
- **No hay una API.** Un ticket en prosa no es componible, no es versionable, no es testeable, no es idempotente y no tiene un contrato. No podés hacer GitOps sobre prosa.
- **La abstracción se filtra (leaky abstraction).** El developer termina necesitando entender IAM, VPCs, subnets, parameter groups de RDS — todo lo que la plataforma debería esconder detrás de un contrato mínimo.

### 1.2 La solución: exponer infraestructura como una API declarativa curada

La respuesta de la disciplina es tratar la plataforma **como un producto** cuya interfaz es una **API declarativa**, no una consola ni un runbook. Dos primitivas conceptuales:

- **Infrastructure abstraction (abstracción de infraestructura):** una API de alto nivel, curada por el platform team, que expone *solo* los parámetros que el consumidor necesita decidir (`storageGB`, `region`, `tier`) y esconde todo lo demás (networking, encryption at rest, backup policy, tags de FinOps, políticas de seguridad). El consumidor pide `PostgreSQLInstance` y no sabe — ni le importa — si por detrás es RDS, CloudSQL o un operator de Postgres en el propio cluster.
- **Service catalog (catálogo de servicios):** el registro descubrible de *qué* capacidades ofrece la plataforma, *quién* las posee, *qué* dependencias tienen y *cómo* se solicitan. Es la capa de discovery y self-service sobre las abstracciones.

La tesis arquitectónica dominante en el ecosistema cloud native es usar el **Kubernetes Resource Model (KRM)** como el plano de control universal para *toda* la infraestructura, no solo para workloads. El motivo es que KRM ya resuelve, de fábrica, los problemas difíciles de un catálogo de servicios de producción:

| Propiedad requerida por un catálogo de producción | Cómo la resuelve KRM |
|---|---|
| Contrato tipado y versionado | OpenAPI v3 schema en CRDs, con `served`/`storage` versions |
| Reconciliación continua (auto-remediación de drift) | Controllers level-triggered que convergen `status` hacia `spec` |
| RBAC granular por consumidor | El mismo `Role`/`RoleBinding` del cluster |
| Auditoría | Kubernetes audit log de cada `create`/`update`/`delete` |
| Validación y defaulting | Admission webhooks (validating/mutating), CEL validation rules |
| GitOps / declaratividad | El recurso *es* YAML en Git; Argo CD / Flux lo aplican |
| Descubribilidad programática | `kubectl api-resources`, discovery API |

El **problema de fondo** que este tema evalúa: cómo diseñar esa capa de API de forma que sea **estable para el consumidor** (el contrato no cambia cuando el platform team migra el backend), **segura por defecto** (políticas embebidas, no opcionales), **auto-servicio real** (sin intervención humana en el camino feliz) y **operable en day-2** (drift, rotación, upgrades, borrado seguro).

### 1.3 Las cuatro capas de una plataforma API-driven

Un diseño de producción separa responsabilidades en capas. Confundirlas es el error de arquitectura más común:

```
┌─────────────────────────────────────────────────────────────┐
│  Capa 4 — DISCOVERY / CATALOG                                │
│  Backstage Software Catalog · portal · scaffolder            │
│  "¿Qué existe? ¿Quién lo posee? ¿Cómo lo pido?"              │
├─────────────────────────────────────────────────────────────┤
│  Capa 3 — INTERFACE (API del consumidor)                     │
│  Crossplane Claim / XR · KubeVela Application · Score        │
│  "PostgreSQLInstance{ storageGB: 20 }" — contrato mínimo     │
├─────────────────────────────────────────────────────────────┤
│  Capa 2 — COMPOSITION (opinión del platform team)            │
│  Crossplane Composition · Kratix Promise pipeline · OAM      │
│  Traduce el contrato a N recursos concretos + políticas      │
├─────────────────────────────────────────────────────────────┤
│  Capa 1 — RESOURCE (primitivas de infraestructura)           │
│  Managed Resources (RDS Instance, VPC, SG) · Cloud APIs      │
│  Reconciliación 1:1 con la nube / provider                   │
└─────────────────────────────────────────────────────────────┘
```

Backstage vive en la capa 4 (discovery), Crossplane cubre las capas 1–3, Kratix cubre 2–3 y delega la 1, KubeVela/OAM cubre 2–3 para workloads, y el viejo Open Service Broker API es una implementación cerrada de las capas 1–3 con un modelo de plugin propio. El resto del tema desarrolla cada una con manifiestos completos.

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Modelos de aprovisionamiento: control plane vs. cliente imperativo

La decisión arquitectónica raíz es **dónde vive la lógica de reconciliación**: en un control plane que corre continuamente, o en un cliente (CLI/CI job) que ejecuta puntualmente.

| Dimensión | Terraform / OpenTofu | Pulumi | **Crossplane** | Cluster API (CAPI) | Kratix |
|---|---|---|---|---|---|
| Modelo de ejecución | Cliente imperativo (plan/apply) | Cliente imperativo | **Control plane (reconcilia siempre)** | Control plane | Control plane + pipeline GitOps |
| Estado (state) | Fichero de state externo (S3+lock) | Backend de state gestionado | **En etcd, es el objeto mismo** | En etcd | En etcd + Git |
| Detección/corrección de drift | Manual (`plan`), no continua | Manual | **Continua y automática** | Continua | Continua (delega en el destino) |
| Contrato hacia el developer | HCL / módulos | Lenguaje de programación | **CRD (API de K8s)** | CRD | CRD (Promise) |
| Superficie de abstracción | Módulos | Componentes/paquetes | **XRD + Composition** | Providers de infra | Promise (bundle empaquetable) |
| Day-2 (rotación, upgrade) | Re-`apply` desde CI | Re-`up` | **Nativo, sin humano** | Nativo | Nativo |
| Multi-tenancy | Workspaces / módulos | Stacks | **Namespaced Claims + RBAC** | Namespaces | Namespaces |
| Punto débil | State drift, apply fuera de banda no se corrige solo | Requiere runtime de lenguaje | Curva de aprendizaje de XRDs/Compositions; overhead de un control plane | Solo aprovisiona clusters | Ecosistema más joven |
| Punto fuerte | Ubicuo, enorme ecosistema de providers | Expresividad de un lenguaje real | Reconciliación continua + API nativa K8s | Estándar de facto para fleets de clusters | Empaquetado y distribución de capacidades ("Promise marketplace") |

**Lectura arquitectónica:** Terraform/Pulumi son excelentes *provisioners* pero clientes de "un disparo": si alguien cambia infra por la consola, el drift persiste hasta el próximo `apply`. Crossplane y Kratix convierten la infraestructura en objetos reconciliados: el drift se corrige solo porque el controller nunca deja de comparar `spec` vs. `status`. Ese es exactamente el requisito de un *catálogo de servicios de producción*, no de un script de provisioning. No es "uno u otro" en la práctica: es común envolver módulos Terraform con `provider-terraform` de Crossplane, o que Kratix ejecute Terraform dentro del pipeline de una Promise.

### 2.2 Capas de catálogo / abstracción: quién consume qué

| Herramienta | Capa (§1.3) | Consumidor primario | Contrato | Backend que abstrae | Estado del proyecto (CNCF) |
|---|---|---|---|---|---|
| **Backstage Software Catalog** | 4 (discovery) | Developer (portal web) | `catalog-info.yaml` (entidades) | *Cualquier cosa*; solo cataloga metadatos | CNCF Graduated |
| **Backstage Scaffolder (templates)** | 4→2 | Developer | `Template` entity | Genera repos + dispara la capa 2/3 | CNCF Graduated |
| **Crossplane** | 1–3 | Platform team (XRD/Comp) + Developer (Claim) | CRD generado por el XRD | Cloud APIs vía Providers | CNCF Incubating |
| **KubeVela / OAM** | 2–3 | Developer (Application) | `Application` (OAM) | Componentes + Traits | CNCF Incubating (OAM spec) |
| **Kratix** | 2–3 | Platform team (Promise) + Developer (Resource request) | CRD de la Promise | Delega en workers (Flux/Argo/Terraform) | CNCF Sandbox |
| **Score** | 3 | Developer | `score.yaml` (workload spec) | Traduce a K8s/Compose/Helm | CNCF Sandbox |
| **Open Service Broker API + Service Catalog** | 1–3 | Developer (ServiceInstance) | OSBAPI (REST) | Brokers propietarios | **Kubernetes Service Catalog: archivado/retired** |
| **Cluster API** | 1–2 | Platform team | `Cluster` / `MachineDeployment` | Infra de clusters | SIG-Cluster-Lifecycle |

**Trade-off central de diseño — Claim vs. Application vs. Score:** Crossplane te da control total del contrato (vos definís el XRD) pero exige que vos diseñes la API. KubeVela impone el modelo OAM (Component + Trait), más rápido de adoptar pero menos flexible. Score es deliberadamente el contrato más pobre y portable posible (una spec de workload agnóstica de plataforma) pensada para que el mismo `score.yaml` corra en local (Docker Compose) y en prod (K8s) — resuelve *portabilidad*, no *aprovisionamiento de infra*. No compiten: un stack maduro usa Backstage para discovery, un XRD de Crossplane como abstracción de infra, y Score/KubeVela para la abstracción del workload.

### 2.3 Open Service Broker API vs. el modelo KRM-nativo

Vale entender por qué el ecosistema migró del OSBAPI (heredado de Cloud Foundry) al modelo KRM:

| Aspecto | Open Service Broker API (OSBAPI) | Modelo KRM-nativo (Crossplane) |
|---|---|---|
| Protocolo | REST propio (catalog, provision, bind, deprovision) | La API de Kubernetes |
| Extensión | Escribir un broker HTTP que implemente la spec | Escribir un XRD + Composition (declarativo) |
| Reconciliación | El broker decide; no hay drift-correction estándar | Continua, por diseño |
| Estado en K8s | `ServiceInstance`/`ServiceBinding` (via Service Catalog) | El recurso *es* nativo |
| Ownership actual | `kubernetes-retired/service-catalog` (archivado) | Activo, CNCF Incubating |

**Conclusión para el examen:** OSBAPI sigue vivo en Cloud Foundry y en algunos marketplaces gestionados, y conviene reconocer `ServiceInstance`/`ServiceBinding`, pero **el Kubernetes Service Catalog está retirado**; el patrón cloud-native actual es CRD + controller (Crossplane/Operators), no brokers.

---

## 3. Manifiestos completos (sin recortar)

El caso guía: el platform team quiere ofrecer una capacidad **"PostgreSQL gestionado"** como una API self-service. Un developer del `team-a` debe poder pedir una base con `storageGB` y `region`, recibir un `Secret` con la conexión, y no tocar jamás RDS/IAM/VPC.

### 3.1 Capa 0 — instalar Crossplane y el provider

Instalación del core (Helm) y del provider oficial de Upbound para AWS RDS. Se usa la **provider family** de Upbound (el monolito `provider-aws` fue reemplazado por providers granulares por servicio para reducir memoria y superficie de CRDs).

```yaml
# provider-aws-rds.yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.1.0
  # runtimeConfigRef enlaza opciones de runtime (recursos, service account para IRSA)
  runtimeConfigRef:
    name: irsa-runtime
---
# DeploymentRuntimeConfig reemplaza al deprecado ControllerConfig.
# Aquí se inyecta el ServiceAccount con el annotation de IRSA (IAM Roles for Service Accounts),
# de modo que el provider asuma un rol IAM sin credenciales estáticas.
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: irsa-runtime
spec:
  serviceAccountTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/crossplane-provider-aws
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              resources:
                requests:
                  cpu: "100m"
                  memory: "256Mi"
                limits:
                  memory: "512Mi"
```

```yaml
# providerconfig-aws.yaml
# ProviderConfig le dice al provider CÓMO autenticarse. Con IRSA no hay secret.
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: IRSA   # alternativas: Secret | WebIdentity | Upbound
```

> Alternativa con credenciales estáticas (entornos sin IRSA). **Nunca** persistir estas claves en Git en claro; usar SOPS/Sealed Secrets/External Secrets:

```yaml
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

### 3.2 Instalar la Composition Function (modo Pipeline)

Desde Crossplane v1.17 la reconciliación de Compositions se hace con **funciones** (pipeline mode); el modo `resources` clásico (patch & transform nativo) está deprecado y removido en Crossplane v2. Se instala la función oficial de patch-and-transform y la de auto-ready:

```yaml
# functions.yaml
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
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.1
```

### 3.3 Capa 3 — el contrato del consumidor: `CompositeResourceDefinition` (XRD)

El XRD **genera la CRD** que verá el developer. Define el schema OpenAPI del contrato (lo mínimo), y con `claimNames` habilita una versión **namespaced** (el Claim) además del Composite (cluster-scoped).

```yaml
# xrd-postgres.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.example.org
spec:
  group: database.example.org
  names:
    kind: XPostgreSQLInstance          # el Composite Resource (XR), cluster-scoped
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance           # el Claim, namespaced — lo que pide el developer
    plural: postgresqlinstances
  # Estas claves DEBEN existir en el connection secret del XR; el contrato de conexión.
  connectionSecretKeys:
    - host
    - port
    - username
    - password
  defaultCompositionRef:
    name: xpostgresqlinstances.aws
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
                      description: "Tamaño del volumen en GiB."
                    region:
                      type: string
                      enum: ["us-east-1", "eu-west-1", "sa-east-1"]
                      description: "Región donde se aprovisiona la base."
                    tier:
                      type: string
                      enum: ["dev", "prod"]
                      default: "dev"
                      description: "dev = db.t3.micro; prod = db.r6g.large multi-AZ."
                  required:
                    - storageGB
                    - region
              required:
                - parameters
            status:
              type: object
              properties:
                address:
                  type: string
                  description: "Endpoint DNS de la base, propagado desde el provider."
                ready:
                  type: boolean
```

### 3.4 Capa 2 — la opinión del platform team: `Composition`

Traduce el contrato mínimo del developer a los recursos concretos + políticas embebidas (encryption, backups, tags de FinOps, multi-AZ en prod). Acá vive **toda** la complejidad que el developer no ve.

```yaml
# composition-postgres-aws.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.aws
  labels:
    provider: aws
    crossplane.io/xrd: xpostgresqlinstances.database.example.org
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
    kind: XPostgreSQLInstance
  writeConnectionSecretsToNamespace: crossplane-system
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          # ---------- Subnet group (networking oculto al developer) ----------
          - name: db-subnet-group
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: SubnetGroup
              spec:
                forProvider:
                  description: "Managed by Crossplane"
                  subnetIds:
                    - subnet-0a1b2c3d4e5f60001
                    - subnet-0a1b2c3d4e5f60002
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region

          # ---------- La instancia RDS ----------
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: Instance
              spec:
                forProvider:
                  engine: postgres
                  engineVersion: "15.4"
                  username: masteruser
                  # Password autogenerado y escrito a un secret por el provider.
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: rds-master-password
                    key: password
                  # Políticas NO negociables embebidas por el platform team:
                  storageEncrypted: true
                  backupRetentionPeriod: 7
                  deletionProtection: true
                  skipFinalSnapshot: false
                  publiclyAccessible: false
                  dbSubnetGroupNameSelector:
                    matchControllerRef: true
                  tags:
                    managed-by: crossplane
                    cost-center: platform
                writeConnectionSecretToRef:
                  namespace: crossplane-system
                  # nombre se parchea con el UID del XR para evitar colisiones
                  name: ""
            patches:
              # Contrato del developer -> parámetros concretos
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              # tier=prod => instancia grande + multi-AZ; tier=dev => micro
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      dev: db.t3.micro
                      prod: db.r6g.large
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.multiAz
                transforms:
                  - type: map
                    map:
                      dev: "false"
                      prod: "true"
                  - type: convert
                    convert:
                      toType: bool
              # Nombre único del connection secret = UID del XR
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.uid
                toFieldPath: spec.writeConnectionSecretToRef.name
                transforms:
                  - type: string
                    string:
                      fmt: "%s-postgresql"
              # Propaga el endpoint del provider de vuelta al status del XR
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.endpoint
                toFieldPath: status.address
              # Marca readiness del XR cuando la instancia está Available
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.status
                toFieldPath: status.ready
                transforms:
                  - type: match
                    match:
                      patterns:
                        - type: literal
                          literal: available
                          result: true
                      fallbackValue: false
            # Detalles de conexión que se exponen en el connection secret del XR
            connectionDetails:
              - name: host
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
                fromConnectionSecretKey: attribute.password

    # Segundo step: marca el XR Ready cuando todos los recursos compuestos lo están.
    - step: detect-readiness
      functionRef:
        name: function-auto-ready
```

### 3.5 Capa 3 (consumo) — el Claim que escribe el developer

Esto es **todo** lo que el developer del `team-a` ve y versiona en Git. Namespaced, con RBAC del namespace. No sabe qué hay debajo.

```yaml
# claim.yaml  (aplicado por el team-a vía Argo CD)
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-a
spec:
  parameters:
    storageGB: 50
    region: us-east-1
    tier: prod
  # dónde el developer quiere recibir sus credenciales, en su propio namespace
  writeConnectionSecretToRef:
    name: orders-db-conn
```

### 3.6 Capa 4 — discovery: entidades del Backstage Software Catalog

El catálogo de Backstage cataloga *metadatos y relaciones*, no aprovisiona. Se registran las entidades y sus dependencias. El `Resource` `orders-db` se enlaza al `Component` que lo usa.

```yaml
# catalog-info.yaml  (en el repo del team-a)
apiVersion: backstage.io/v1alpha1
kind: Domain
metadata:
  name: commerce
  description: Dominio de comercio y checkout.
spec:
  owner: group:default/team-a
---
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: checkout
spec:
  owner: group:default/team-a
  domain: commerce
---
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: orders-service
  description: Servicio de gestión de órdenes.
  annotations:
    backstage.io/kubernetes-id: orders-service
    argocd/app-name: orders-service
spec:
  type: service
  lifecycle: production
  owner: group:default/team-a
  system: checkout
  providesApis:
    - orders-api
  dependsOn:
    - resource:default/orders-db     # relación con el recurso de infra
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: orders-api
spec:
  type: openapi
  lifecycle: production
  owner: group:default/team-a
  system: checkout
  definition:
    $text: ./openapi.yaml
---
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: orders-db
  description: PostgreSQL gestionado (aprovisionado por Crossplane XRD).
  links:
    - url: https://console.aws.amazon.com/rds
      title: RDS Console
spec:
  type: database
  owner: group:default/team-a
  system: checkout
```

### 3.7 Capa 4→2 — self-service real: un Backstage Software Template (Scaffolder)

El template es lo que convierte al catálogo en *self-service*: el developer llena un formulario y el scaffolder genera el repo y *escribe el Claim* de Crossplane, cerrando el loop discovery → provisioning.

```yaml
# template-postgres.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: request-postgres
  title: Solicitar PostgreSQL gestionado
  description: Aprovisiona una base PostgreSQL vía el XRD de la plataforma.
spec:
  owner: group:default/platform-team
  type: resource
  parameters:
    - title: Parámetros de la base
      required: [name, storageGB, region, tier]
      properties:
        name:
          title: Nombre
          type: string
          pattern: '^[a-z0-9-]+$'
        storageGB:
          title: Tamaño (GiB)
          type: integer
          default: 20
        region:
          title: Región
          type: string
          enum: [us-east-1, eu-west-1, sa-east-1]
        tier:
          title: Tier
          type: string
          enum: [dev, prod]
          default: dev
  steps:
    - id: fetch
      name: Generar el Claim
      action: fetch:template
      input:
        url: ./skeleton          # contiene claim.yaml con placeholders ${{ ... }}
        values:
          name: ${{ parameters.name }}
          storageGB: ${{ parameters.storageGB }}
          region: ${{ parameters.region }}
          tier: ${{ parameters.tier }}
    - id: publish
      name: Publicar PR a GitOps
      action: publish:github:pull-request
      input:
        repoUrl: github.com?owner=acme&repo=gitops-team-a
        branchName: add-${{ parameters.name }}-db
        title: "feat: aprovisionar base ${{ parameters.name }}"
    - id: register
      name: Registrar en el catálogo
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Ver PR
        url: ${{ steps.publish.output.remoteUrl }}
```

### 3.8 Modelo alternativo — Kratix Promise (misma capacidad, otro paradigma)

Kratix empaqueta una capacidad completa (API + dependencias + pipeline) como una **Promise** distribuible. Útil para comparar el modelo "bundle empaquetable" contra el "XRD + Composition" de Crossplane.

```yaml
# promise-postgresql.yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
spec:
  # La API que verá el developer (Kratix crea esta CRD en el cluster de plataforma).
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.marketplace.kratix.io
    spec:
      group: marketplace.kratix.io
      scope: Namespaced
      names:
        plural: postgresqls
        singular: postgresql
        kind: PostgreSQL
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
  # Dependencias que Kratix instala en los clusters worker (p. ej. el operator).
  dependencies:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: postgres-operator
  # Pipeline que transforma el request del developer en manifiestos concretos.
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: render-postgres
                image: acme/kratix-postgres-pipeline:v1.0.0
```

### 3.9 Modelo alternativo — abstracción de workload con KubeVela (OAM)

Para la abstracción de la *aplicación* (no de la infra), el modelo OAM separa `Component` (qué) de `Trait` (cómo operarlo). El developer describe intención, no Deployments.

```yaml
# application.yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: orders-service
  namespace: team-a
spec:
  components:
    - name: orders
      type: webservice
      properties:
        image: acme/orders:1.4.2
        port: 8080
      traits:
        - type: scaler
          properties:
            replicas: 3
        - type: gateway
          properties:
            domain: orders.acme.internal
            http:
              "/": 8080
        # Consumo de la base aprovisionada por Crossplane
        - type: service-binding
          properties:
            envMappings:
              DB_HOST: { secret: orders-db-conn, key: host }
              DB_PASSWORD: { secret: orders-db-conn, key: password }
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar que el provider y las funciones están sanos

```console
$ kubectl get providers
NAME                          INSTALLED   HEALTHY   PACKAGE                                                AGE
provider-aws-rds              True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.1.0        6m
upbound-provider-family-aws   True        True      xpkg.upbound.io/upbound/provider-family-aws:v1.1.0     6m

$ kubectl get functions
NAME                            INSTALLED   HEALTHY   PACKAGE                                                             AGE
function-auto-ready             True        True      xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.1        6m
function-patch-and-transform    True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.8.2  6m

$ kubectl get providerconfig.aws.upbound.io
NAME      AGE
default   6m
```

### 4.2 Verificar que el contrato (XRD) quedó establecido y ofrecido

`ESTABLISHED=True` significa que la CRD del Composite existe; `OFFERED=True` que además se generó la CRD del Claim namespaced.

```console
$ kubectl get xrd
NAME                                        ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.database.example.org   True          True      4m

$ kubectl get composition
NAME                      XR-KIND               XR-APIVERSION                   AGE
xpostgresqlinstances.aws  XPostgreSQLInstance   database.example.org/v1alpha1   4m

# El XRD generó DOS CRDs consumibles:
$ kubectl api-resources | grep database.example.org
postgresqlinstances    database.example.org/v1alpha1   true    PostgreSQLInstance
xpostgresqlinstances   database.example.org/v1alpha1   false   XPostgreSQLInstance
```

### 4.3 Aplicar el Claim y observar el aprovisionamiento

```console
$ kubectl apply -f claim.yaml
postgresqlinstance.database.example.org/orders-db created

$ kubectl get postgresqlinstance -n team-a
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      20s

# El Claim creó un Composite (XR) cluster-scoped con nombre generado:
$ kubectl get xpostgresqlinstance
NAME               SYNCED   READY   COMPOSITION               AGE
orders-db-7f9k2    True     False   xpostgresqlinstances.aws  22s

# Los Managed Resources (primitivas reales) que la Composition creó:
$ kubectl get managed
NAME                                                  READY   SYNCED   EXTERNAL-NAME       AGE
subnetgroup.rds.aws.upbound.io/orders-db-7f9k2-sng    True    True     orders-db-7f9k2-sng 22s
instance.rds.aws.upbound.io/orders-db-7f9k2-rds       False   True     orders-db-7f9k2-rds 22s
```

Tras ~6–8 min RDS termina de aprovisionar y todo converge a `READY=True`:

```console
$ kubectl get postgresqlinstance -n team-a
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     True    orders-db-conn      8m
```

### 4.4 `crossplane trace` — la vista jerárquica (herramienta de diagnóstico #1)

```console
$ crossplane beta trace postgresqlinstance/orders-db -n team-a
NAME                                          SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-a)         True     True    Available
└─ XPostgreSQLInstance/orders-db-7f9k2        True     True    Available
   ├─ SubnetGroup/orders-db-7f9k2-sng         True     True    Available
   └─ Instance/orders-db-7f9k2-rds            True     True    Available
```

### 4.5 Verificar el connection secret entregado al developer

```console
$ kubectl get secret orders-db-conn -n team-a -o jsonpath='{.data}' | jq 'keys'
[
  "host",
  "password",
  "port",
  "username"
]

$ kubectl get secret orders-db-conn -n team-a -o jsonpath='{.data.host}' | base64 -d
orders-db-7f9k2-rds.abc123.us-east-1.rds.amazonaws.com
```

### 4.6 Consultar el Backstage catalog vía su API

```console
$ curl -s "http://backstage:7007/api/catalog/entities/by-name/component/default/orders-service" \
    | jq '{kind, name: .metadata.name, dependsOn: .relations}'
{
  "kind": "Component",
  "name": "orders-service",
  "dependsOn": [
    { "type": "dependsOn", "targetRef": "resource:default/orders-db" },
    { "type": "ownedBy",   "targetRef": "group:default/team-a" },
    { "type": "providesApi","targetRef": "api:default/orders-api" }
  ]
}
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 El árbol de decisión: leer las condiciones `SYNCED` y `READY`

Todo objeto de Crossplane (Claim, XR, Managed Resource) expone dos condiciones ortogonales. **Diagnosticar siempre en este orden:**

| `SYNCED` | `READY` | Significado | Dónde mirar primero |
|---|---|---|---|
| `False` | `False` | Crossplane no pudo *reconciliar la intención* con el provider (auth, schema, referencia inválida) | `kubectl describe` del recurso + logs del provider |
| `True` | `False` | La intención se envió al provider; la infra **todavía está creándose** o hay error externo | `status.atProvider` + eventos del Managed Resource |
| `True` | `True` | Todo convergió | — |
| `False` | `True` | Raro; drift entre spec y external post-ready | logs del provider |

`SYNCED=False` es un problema de **control plane / provider**; `READY=False` con `SYNCED=True` es un problema del **backend externo** (cuota AWS, subnet inválida, versión de engine inexistente).

### 5.2 Diagnóstico paso a paso

**Paso 1 — ¿el XRD quedó establecido?** Si un Claim no crea nada, la CRD puede no existir:

```console
$ kubectl get xrd xpostgresqlinstances.database.example.org -o jsonpath='{.status.conditions}' | jq
[
  { "type": "Established", "status": "True",  "reason": "WatchingCompositeResource" },
  { "type": "Offered",     "status": "True",  "reason": "WatchingCompositeResourceClaim" }
]
```

**Paso 2 — ¿el Claim seleccionó una Composition?** El error más común es que ninguna Composition matchea el `compositeTypeRef`, o hay ambigüedad:

```console
$ kubectl describe postgresqlinstance orders-db -n team-a
...
Events:
  Warning  CannotSelectComposition   12s   defined/compositeresourceclaim
      no CompositionRevision matches labels or the referenced Composition does not exist
```

Verificá que `spec.compositeTypeRef` de la Composition sea idéntico (group/version/kind) al XR del XRD, y que el `defaultCompositionRef` o `compositionSelector` resuelva a exactamente una.

**Paso 3 — ¿el provider puede autenticarse?** `SYNCED=False` en el Managed Resource casi siempre es auth:

```console
$ kubectl describe instance.rds.aws.upbound.io orders-db-7f9k2-rds
...
Events:
  Warning  CannotConnectToProvider   8s
      cannot get terraform setup: cannot get AWS credentials: failed to refresh
      cached credentials, no EC2 IMDS role found
```

→ Revisar el `ProviderConfig`, el annotation IRSA del ServiceAccount y el trust policy del rol IAM.

**Paso 4 — logs del provider (el error crudo del backend):**

```console
$ kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-aws-rds --tail=20
... "cannot create Instance" error="creating RDS DB Instance: InvalidParameterValue:
     Cannot find version 15.99 for postgres" resource="orders-db-7f9k2-rds"
```

→ El `engineVersion` del base de la Composition no existe en RDS. Se corrige en la Composition (capa 2), no en el Claim.

**Paso 5 — la trampa del borrado: finalizers y `deletionProtection`.** Un recurso "colgado" en `Terminating` casi siempre es un finalizer bloqueado porque el backend rechaza el delete:

```console
$ kubectl get instance.rds.aws.upbound.io orders-db-7f9k2-rds -o jsonpath='{.metadata.finalizers}'
["finalizer.managedresource.crossplane.io"]

$ kubectl describe instance.rds.aws.upbound.io orders-db-7f9k2-rds | grep -A2 Events
  Warning  CannotDeleteExternalResource
      DeleteDBInstance: InvalidParameterCombination: Cannot delete protected DB Instance,
      please disable deletion protection and try again.
```

→ En la Composition pusimos `deletionProtection: true` a propósito. El borrado seguro requiere primero desactivar la protección (patch en el XR/Claim), no eliminar finalizers a mano — hacerlo huerfaniza infra real que sigue facturando.

### 5.3 Verificar la Composition sin tocar infra real (render offline)

Antes de publicar una Composition, renderizala localmente para ver los Managed Resources que produciría, sin llamar a AWS:

```console
$ crossplane beta render claim.yaml composition-postgres-aws.yaml functions.yaml
---
apiVersion: rds.aws.upbound.io/v1beta1
kind: SubnetGroup
metadata:
  generateName: orders-db-
  labels:
    crossplane.io/composite: orders-db-7f9k2
spec:
  forProvider:
    region: us-east-1
    ...
---
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  generateName: orders-db-
spec:
  forProvider:
    allocatedStorage: 50
    instanceClass: db.r6g.large    # tier=prod se mapeó bien
    multiAz: true
    ...
```

Esto valida los patches y transforms en CI, y es el equivalente a `terraform plan` para el modelo de Compositions.

### 5.4 Checklist de readiness de producción para una nueva capacidad de catálogo

- [ ] El XRD reporta `Established=True` **y** `Offered=True`.
- [ ] `crossplane beta render` produce los Managed Resources esperados con los defaults de política (encryption, backups, tags) presentes.
- [ ] `compositeTypeRef` de la Composition == XR del XRD (group/version/kind exactos).
- [ ] El `connectionSecretKeys` del XRD == las claves reales de `connectionDetails` de la Composition.
- [ ] RBAC: el `Role` del namespace del developer permite `create/get` del Claim, **no** de los Managed Resources.
- [ ] Política de borrado: `deletionProtection` y `skipFinalSnapshot=false` en prod, con un runbook de teardown documentado.
- [ ] La entidad `Resource` correspondiente existe en el Backstage catalog y está enlazada por `dependsOn`.
- [ ] Provider corriendo con IRSA/Workload Identity, **sin** credenciales estáticas en Git.
- [ ] El Claim vive en Git y lo aplica Argo CD/Flux (GitOps), no `kubectl apply` manual.

---

## 6. Referencias

- CNCF Curriculum (CNPA): https://github.com/cncf/curriculum
- CNCF Platform Engineering Maturity Model (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNCF Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- Kubernetes — Custom Resources / CRDs: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — API Aggregation Layer: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/
- Crossplane — documentación: https://docs.crossplane.io/
- Crossplane — Composite Resource Definitions (XRDs): https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane — Compositions y Composition Functions: https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane — Managed Resources y Providers: https://docs.crossplane.io/latest/concepts/managed-resources/
- Upbound Marketplace (provider families & functions): https://marketplace.upbound.io/
- Backstage — Software Catalog: https://backstage.io/docs/features/software-catalog/
- Backstage — Descriptor Format (entities): https://backstage.io/docs/features/software-catalog/descriptor-format/
- Backstage — Software Templates (Scaffolder): https://backstage.io/docs/features/software-templates/
- Kratix — documentación y Promises: https://docs.kratix.io/
- KubeVela — documentación: https://kubevela.io/docs/
- Open Application Model (OAM): https://oam.dev/
- Score — spec de workload: https://docs.score.dev/
- Cluster API (CAPI): https://cluster-api.sigs.k8s.io/
- Open Service Broker API: https://www.openservicebrokerapi.org/
- Kubernetes Service Catalog (archivado/retired): https://github.com/kubernetes-retired/service-catalog