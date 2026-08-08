# 5.2 Implementing Workflows for Self-Service Provisioning Using Platform APIs

> **Peso en el examen: 6.25** — Dominio "Platform APIs & Provisioning". Este módulo es el corazón operativo del rol de Platform Engineer: convertir la infraestructura en un *producto* consumible por API, no en una cola de tickets.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El cuello de botella que estamos eliminando

En una organización sin plataforma, provisionar una base de datos para un equipo de aplicación se parece a esto:

```
Dev abre ticket JIRA → Ops lee el ticket (T+2 días) → Ops corre terraform a mano →
Ops copia credenciales a un canal de Slack → Dev descubre que la versión es la equivocada →
reabre ticket → ... (T+9 días, config única e irreproducible)
```

Los tres fallos estructurales de este modelo son:

1. **Acoplamiento humano síncrono.** Cada provisión requiere un humano del equipo de plataforma en el camino crítico. La capacidad de provisión escala linealmente con la cantidad de SREs, no con la demanda.
2. **Snowflakes.** Cada recurso se crea con drift respecto del anterior. No hay una definición única de "una base de datos de producción de la compañía".
3. **Carga cognitiva desplazada al lugar equivocado.** El equipo de aplicación no debería necesitar saber qué es un `db_subnet_group` de RDS, un `parameter group` o una `KMS key` para pedir "una Postgres 16 de 50 GB".

La disciplina que resuelve esto es **Platform as a Product** (Team Topologies): el equipo de plataforma no ejecuta tareas, publica **capacidades autoservicio** detrás de una **API estable**, con *golden paths* — el camino pavimentado, opinado y seguro por defecto. El estudiante debe internalizar que **el entregable de un Platform Engineer es una API, no un cluster**.

### 1.2 La Platform API como contrato

El artefacto central es la **Platform API**: una superficie declarativa donde el consumidor expresa *intención* ("quiero una Postgres 16, 50 GB, en el entorno `staging`") y la plataforma se hace cargo del *cómo* (VPC, subnets, backups, cifrado, rotación de secretos, políticas de red, observabilidad).

```
┌───────────────────────────────────────────────────────────────┐
│  INTENCIÓN (lo que pide el consumidor)                          │
│  kind: PostgreSQLInstance                                       │
│  spec.parameters: { storageGB: 50, version: "16", env: staging}│
└───────────────────────────────────────────────────────────────┘
                          │  (Platform API — el contrato)
                          ▼
┌───────────────────────────────────────────────────────────────┐
│  IMPLEMENTACIÓN (lo que el equipo de plataforma decide)         │
│  RDS Instance + SubnetGroup + SecurityGroup + KMS key +         │
│  ParameterGroup + Secret rotation + NetworkPolicy + Dashboards  │
└───────────────────────────────────────────────────────────────┘
```

Este desacoplamiento intención/implementación es idéntico en espíritu al desacoplamiento interface/implementación en ingeniería de software. La Platform API es la *encapsulación*.

### 1.3 Por qué el Kubernetes Resource Model (KRM) es el sustrato universal

La decisión arquitectónica más importante del ecosistema CNCF es usar el **API server de Kubernetes como plano de control universal**, no solo como orquestador de contenedores. Las razones que un arquitecto debe poder defender:

- **Modelo declarativo, level-triggered.** El consumidor declara el estado deseado; un *controller* reconcilia continuamente hacia ese estado. A diferencia de un pipeline imperativo (edge-triggered, se ejecuta una vez y si falla queda a medias), la reconciliación es **auto-sanadora**: si alguien borra el RDS a mano, el controller lo vuelve a crear. Esta es la diferencia entre "provisioné" y "mantengo provisionado".
- **API server como servicio gratuito.** Autenticación (OIDC), autorización (RBAC), *admission control* (validating/mutating webhooks), *audit log*, *optimistic concurrency* (resourceVersion), *watch* streams y *schema validation* (OpenAPI v3) vienen dados. Construir esto desde cero para una API custom es meses de trabajo.
- **Extensibilidad por CRD.** Con `CustomResourceDefinition` cualquiera define nuevos *kinds* que se comportan como recursos nativos. La Platform API se vuelve, literalmente, tipos de Kubernetes.

El ciclo de reconciliación es el patrón mecánico subyacente a todo el tema:

```
        observe (watch)
             │
             ▼
   ┌──────────────────┐     estado deseado (spec)
   │   diff / plan    │ ◄── vs ──► estado real (status + mundo externo)
   └──────────────────┘
             │
             ▼
     act (create/update/delete en el provider)
             │
             └──────────► requeue (backoff) ──► observe ...
```

---

## 2. Anatomía de una Platform API y comparativas técnicas

### 2.1 Las cuatro capas de un workflow de self-service

Todo workflow de provisión de autoservicio de producción se descompone en cuatro capas. El error de diseño más común es colapsarlas (p. ej., meter lógica de provisión en un template de Backstage).

| Capa | Responsabilidad | Tecnologías CNCF típicas |
|---|---|---|
| **Interface / Experience** | Cómo el humano expresa la intención (portal, formulario, CLI, `kubectl`) | Backstage (scaffolder), Port, CLI custom, `kubectl apply` |
| **Orchestration / Workflow** | Pasos con estado: validar → aprobar → provisionar → notificar → registrar | Argo Workflows + Argo Events, Tekton, Temporal, GitOps reconcile |
| **Control Plane / Composition** | Traducir intención abstracta a recursos concretos y reconciliarlos | Crossplane (XRD/Composition), Kratix (Promise), KubeVela, Operators |
| **Providers / Infra** | Ejecutar las llamadas al mundo real (cloud, DNS, DBs) | Crossplane providers, Terraform/OpenTofu, cloud APIs |

### 2.2 Motores de plano de control: comparativa

| Criterio | **Crossplane** | **Kratix** | **Terraform/OpenTofu controller** | **Operator custom (Go/Kubebuilder)** | **Open Service Broker** |
|---|---|---|---|---|---|
| Modelo | KRM nativo, reconciliación continua | KRM + *Promises* (pipelines contenedorizados) | Wrappea HCL en un CR, `terraform apply` en loop | Código imperativo full-control | API REST catálogo/binding |
| Estado (state) | En el API server (managed resources) | En el API server + workers | State file externo (S3, etc.) — punto de fricción | Donde el autor decida | Interno del broker |
| Composición | Declarativa (Compositions + functions) | Imperativa (contenedores de pipeline) | Módulos HCL | Código arbitrario | Fija por el broker |
| Drift correction | Sí, continua | Sí, vía workflows | Solo si se re-ejecuta el plan | Depende del autor | No estándar |
| Curva de aprendizaje | Media-alta (functions, patches) | Media | Baja si ya sabés Terraform | Alta (escribir un operator) | Baja pero legacy |
| Multi-tenant claims | Nativo (Claims namespaced) | Nativo (resource requests) | No nativo | Manual | Sí |
| Mejor para | Estándar de facto para Platform APIs sobre cloud | Marketplace de capacidades "as-a-Service" internas | Reusar módulos Terraform existentes | Lógica de dominio muy específica | Integración con Cloud Foundry / legacy |

> **Recomendación de arquitecto:** Crossplane es el default del ecosistema CNCF para exponer infraestructura como API declarativa; Kratix brilla cuando querés empaquetar una *capacidad completa* (infra + operador + config + observabilidad) como un producto instalable ("Promise"). No son excluyentes: Kratix puede orquestar Crossplane por debajo.

### 2.3 Capa de interfaz (developer portal): comparativa

| Criterio | **Backstage Scaffolder** | **Port** | **`kubectl` / GitOps directo** | **CLI custom** |
|---|---|---|---|---|
| Modelo | Software Templates (nunjucks + actions) | Blueprints + self-service actions (SaaS/self-hosted) | Aplicar el Claim como YAML | Wrapper sobre la API |
| Catálogo integrado | Sí (Software Catalog) | Sí (Software Catalog nativo) | No | No |
| Costo de operación | Alto (mantener Backstage) | Bajo-medio (SaaS) | Nulo | Medio |
| Extensibilidad | Muy alta (custom actions/plugins) | Alta (config-driven) | N/A | Total |
| Público objetivo | Devs que quieren un portal unificado | Ídem, con menos operación | Plataforma / power users | Automatización, CI |

### 2.4 Orquestación: Push vs Pull

Esta es una decisión de diseño de examen. Los workflows de provisión pueden ejecutarse de dos maneras fundamentales:

| Dimensión | **Push (Argo Workflows / Tekton / Temporal)** | **Pull / GitOps (Argo CD / Flux reconciliando el Claim)** |
|---|---|---|
| Disparo | Evento imperativo (webhook, submit) | Commit a Git → reconciliación continua |
| Estado del workflow | Explícito, con pasos y DAG | Implícito en el reconciler |
| Aprobaciones / pasos humanos | Naturales (`suspend` steps) | Requieren PR / merge gates |
| Idempotencia | Hay que diseñarla | Intrínseca (declarativa) |
| Auditoría | Logs del workflow | Historia de Git (fuente de verdad) |
| Auto-sanación | No (corre una vez) | Sí (level-triggered) |
| Uso ideal | Provisión con **secuencia y decisiones** (Day-0: crear, aprobar, notificar) | **Mantener** el estado deseado (Day-2: el Claim vive en Git) |

**Patrón de producción recomendado (híbrido):** Argo Events + Argo Workflows para la *ceremonia* de onboarding (validar cuota, aprobar, abrir PR al repo de GitOps), y GitOps (Argo CD) para la *reconciliación continua* del Claim ya mergeado. El workflow no crea la base de datos: **abre un PR con el Claim**, y GitOps la crea. Así la fuente de verdad sigue siendo Git.

### 2.5 Diseño de la superficie de API: CRD vs Aggregated API vs Config-as-Data

| Criterio | **CRD** | **Aggregated API Server** | **Config-as-Data (kpt/config sync)** |
|---|---|---|---|
| Esfuerzo | Bajo (declarás el schema) | Alto (servidor propio, etcd/storage) | Bajo-medio |
| Validación | OpenAPI v3 + webhooks | Código arbitrario | Funciones sobre YAML |
| Lógica en lectura (imperative) | No | Sí (subresources custom, cálculo on-read) | No |
| Storage | etcd de k8s | El que elijas | Git |
| Cuándo | 95% de las Platform APIs | Necesitás endpoints computados / escala extrema | Flotas grandes, fan-out de config |

Para self-service provisioning, **CRD (vía Crossplane XRD) es la elección correcta casi siempre**. Aggregated API solo se justifica cuando necesitás respuestas computadas en tiempo de lectura o un modelo de storage distinto a etcd.

---

## 3. Manifiestos completos (sin recortar)

A continuación, una Platform API de producción end-to-end: el equipo de plataforma publica la capacidad `PostgreSQLInstance`; un dev la consume con un Claim de ~8 líneas; RBAC namespaced garantiza multi-tenancy; guardrails de política y un workflow de onboarding cierran el circuito.

### 3.1 Crossplane — CompositeResourceDefinition (XRD): el contrato público

```yaml
# xrd-postgresql.yaml — define el "tipo" de la Platform API
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XPostgreSQLInstance          # recurso composite (cluster-scoped)
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance           # el Claim namespaced que usa el dev
    plural: postgresqlinstances
  defaultCompositionRef:
    name: postgresql-aws               # implementación por defecto
  connectionSecretKeys:                # qué claves expone el secret de conexión
    - host
    - port
    - username
    - password
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
                      default: 20
                    version:
                      type: string
                      enum: ["13", "14", "15", "16"]
                      default: "16"
                    environment:
                      type: string
                      enum: ["dev", "staging", "prod"]
                      default: "dev"
                    region:
                      type: string
                      default: "us-east-1"
                  required:
                    - storageGB
              required:
                - parameters
            status:
              type: object
              properties:
                address:
                  description: Endpoint DNS de la instancia
                  type: string
                ready:
                  type: boolean
      additionalPrinterColumns:
        - name: ENV
          type: string
          jsonPath: ".spec.parameters.environment"
        - name: ADDRESS
          type: string
          jsonPath: ".status.address"
        - name: READY
          type: string
          jsonPath: ".status.conditions[?(@.type=='Ready')].status"
```

### 3.2 Crossplane — Composition en modo Pipeline (la implementación)

```yaml
# composition-postgresql-aws.yaml — traduce la intención a recursos AWS reales
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
  labels:
    provider: aws
    service: postgresql
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
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
          # --- 1) Subnet group ---
          - name: subnet-group
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: SubnetGroup
              spec:
                forProvider:
                  region: us-east-1
                  subnetIdSelector:
                    matchLabels:
                      access: private
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
          # --- 2) La instancia RDS ---
          - name: rds-instance
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: Instance
              spec:
                forProvider:
                  region: us-east-1
                  engine: postgres
                  instanceClass: db.t3.micro
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: ""                 # patcheado abajo (único por XR)
                    key: password
                  dbSubnetGroupNameSelector:
                    matchControllerRef: true
                  publiclyAccessible: false
                  storageEncrypted: true
                  skipFinalSnapshot: true
                  username: masteruser
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.version
                toFieldPath: spec.forProvider.engineVersion
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              # nombre del secret de password único por XR (evita colisiones)
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.uid
                toFieldPath: spec.forProvider.passwordSecretRef.name
                transforms:
                  - type: string
                    string:
                      fmt: "%s-master-pw"
              # instance class según environment
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.environment
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      dev: db.t3.micro
                      staging: db.t3.medium
                      prod: db.r6g.large
              # publicar el endpoint al status del XR
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.address
                toFieldPath: status.address
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.address
                toFieldPath: status.ready
                transforms:
                  - type: match
                    match:
                      patterns:
                        - type: regexp
                          regexp: ".+"
                          result: true
            # extraer detalles de conexión al connection secret
            connectionDetails:
              - name: host
                type: FromFieldPath
                fromFieldPath: status.atProvider.address
              - name: port
                type: FromValue
                value: "5432"
              - name: username
                type: FromFieldPath
                fromFieldPath: spec.forProvider.username
              - name: password
                type: FromConnectionSecretKey
                fromConnectionSecretKey: attribute.password
    # --- paso final: garantiza que el XR quede Ready cuando todo lo esté ---
    - step: ready
      functionRef:
        name: function-auto-ready
```

Las *composition functions* referenciadas se instalan como paquetes:

```yaml
# functions.yaml
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.0
```

Y el `ProviderConfig` que otorga credenciales al provider (nunca en el Claim del dev):

```yaml
# providerconfig-aws.yaml
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: IRSA          # IAM Roles for Service Accounts — sin llaves estáticas
```

### 3.3 El Claim: lo único que ve el consumidor

```yaml
# claim.yaml — vive en el namespace del equipo de aplicación, entra por GitOps
apiVersion: platform.acme.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-orders
spec:
  parameters:
    storageGB: 50
    version: "16"
    environment: staging
  compositionRef:
    name: postgresql-aws
  writeConnectionSecretToRef:
    name: orders-db-conn      # el Secret con host/port/user/password aparece aquí
```

Ocho líneas de intención. Toda la complejidad de RDS, subnets, cifrado, dimensionamiento por entorno y extracción de credenciales quedó encapsulada.

### 3.4 RBAC para self-service multi-tenant

El principio: **los devs pueden crear Claims en su namespace, jamás tocar Compositions, XRDs, ProviderConfigs ni managed resources.**

```yaml
# rbac-selfservice.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: postgresql-requester
  namespace: team-orders
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["postgresqlinstances"]           # solo el Claim namespaced
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]                        # leer su propio connection secret
    verbs: ["get", "list", "watch"]
    resourceNames: []                             # limitable por secret si se desea
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-orders-postgresql
  namespace: team-orders
subjects:
  - kind: Group
    name: "oidc:team-orders"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: postgresql-requester
  apiGroup: rbac.authorization.k8s.io
```

### 3.5 Guardrail de política con Kyverno (validación en admission)

La API declarativa por sí sola no impide que alguien pida una Postgres `prod` de 1 TB sin etiqueta de costo. Los guardrails viven en el *admission controller*:

```yaml
# policy-postgresql-guardrails.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: postgresql-provisioning-guardrails
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: prod-requires-cost-center
      match:
        any:
          - resources:
              kinds: ["platform.acme.io/v1alpha1/PostgreSQLInstance"]
      validate:
        message: "Los Claims 'prod' requieren la anotación acme.io/cost-center."
        pattern:
          spec:
            parameters:
              environment: "prod"
          metadata:
            annotations:
              acme.io/cost-center: "?*"
    - name: storage-ceiling-nonprod
      match:
        any:
          - resources:
              kinds: ["platform.acme.io/v1alpha1/PostgreSQLInstance"]
      preconditions:
        all:
          - key: "{{ request.object.spec.parameters.environment }}"
            operator: NotEquals
            value: "prod"
      validate:
        message: "storageGB no puede superar 200 fuera de prod."
        deny:
          conditions:
            all:
              - key: "{{ request.object.spec.parameters.storageGB }}"
                operator: GreaterThan
                value: 200
```

### 3.6 Workflow de onboarding: Argo Events + Argo Workflows (la ceremonia Day-0)

El portal dispara un evento; Argo Events lo captura y Argo Workflows ejecuta: validar cuota → esperar aprobación humana → abrir PR con el Claim → notificar. **El workflow no crea infra: abre un PR; GitOps reconcilia.**

```yaml
# eventsource-portal.yaml — recibe el webhook del portal
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: portal-webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    provision-request:
      port: "12000"
      endpoint: /provision
      method: POST
---
# sensor-provision.yaml — traduce el evento a un Workflow
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: provision-sensor
  namespace: argo-events
spec:
  dependencies:
    - name: portal-dep
      eventSourceName: portal-webhook
      eventName: provision-request
  triggers:
    - template:
        name: launch-provision-workflow
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: provision-postgres-
                namespace: argo-events
              spec:
                workflowTemplateRef:
                  name: provision-postgres
                arguments:
                  parameters:
                    - name: team
                    - name: storageGB
                    - name: environment
          parameters:
            - src:
                dependencyName: portal-dep
                dataKey: body.team
              dest: spec.arguments.parameters.0.value
            - src:
                dependencyName: portal-dep
                dataKey: body.storageGB
              dest: spec.arguments.parameters.1.value
            - src:
                dependencyName: portal-dep
                dataKey: body.environment
              dest: spec.arguments.parameters.2.value
```

```yaml
# workflowtemplate-provision.yaml — el DAG de onboarding, reutilizable
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: provision-postgres
  namespace: argo-events
spec:
  serviceAccountName: provisioner
  entrypoint: main
  arguments:
    parameters:
      - name: team
      - name: storageGB
      - name: environment
  templates:
    - name: main
      dag:
        tasks:
          - name: validate-quota
            template: validate-quota
          - name: approval
            template: approval-gate
            dependencies: [validate-quota]
            when: "'{{workflow.parameters.environment}}' == 'prod'"
          - name: open-pr
            template: open-claim-pr
            dependencies: [validate-quota, approval]
          - name: notify
            template: notify-slack
            dependencies: [open-pr]

    - name: validate-quota
      script:
        image: bitnami/kubectl:1.30
        command: [bash]
        source: |
          set -euo pipefail
          COUNT=$(kubectl get postgresqlinstances -n team-{{workflow.parameters.team}} \
                    --no-headers 2>/dev/null | wc -l)
          echo "Instancias actuales: $COUNT"
          if [ "$COUNT" -ge 5 ]; then
            echo "Cuota excedida (máx 5)"; exit 1
          fi

    - name: approval-gate            # paso humano: pausa hasta resume
      suspend: {}

    - name: open-claim-pr
      container:
        image: acme/claim-pr-bot:1.4.0
        env:
          - name: TEAM
            value: "{{workflow.parameters.team}}"
          - name: STORAGE_GB
            value: "{{workflow.parameters.storageGB}}"
          - name: ENVIRONMENT
            value: "{{workflow.parameters.environment}}"
        # el bot renderiza el Claim (§3.3) y abre un PR contra el repo de GitOps

    - name: notify-slack
      container:
        image: acme/slack-notify:2.1.0
        args: ["PR abierto para team-{{workflow.parameters.team}}"]
```

### 3.7 GitOps: Argo CD reconcilia el Claim mergeado (Day-2)

```yaml
# application-team-claims.yaml — cierra el loop: Git → cluster, auto-sanación
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: team-database-claims
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/acme/platform-gitops.git
        revision: main
        directories:
          - path: "claims/*"
  template:
    metadata:
      name: "{{path.basename}}-claims"
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-gitops.git
        targetRevision: main
        path: "{{path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "team-{{path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true          # si alguien borra el Claim a mano, se restaura
        syncOptions:
          - CreateNamespace=true
```

### 3.8 Interfaz: Backstage Software Template (scaffolder v1beta3)

```yaml
# template-postgresql.yaml — el formulario de self-service en el portal
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: postgresql-database
  title: PostgreSQL Database (Golden Path)
  description: Provisiona una Postgres gestionada por la plataforma vía GitOps.
  tags: [recommended, database, postgresql]
spec:
  owner: group:platform-team
  type: resource
  parameters:
    - title: Configuración de la base de datos
      required: [team, storageGB, environment]
      properties:
        team:
          title: Equipo / namespace
          type: string
          ui:field: OwnerPicker
        storageGB:
          title: Almacenamiento (GB)
          type: integer
          default: 20
          minimum: 20
          maximum: 1000
        version:
          title: Versión de PostgreSQL
          type: string
          enum: ["14", "15", "16"]
          default: "16"
        environment:
          title: Entorno
          type: string
          enum: [dev, staging, prod]
          default: dev
  steps:
    - id: fetch
      name: Renderizar el Claim
      action: fetch:template
      input:
        url: ./skeleton               # contiene claim.yaml con placeholders {{ }}
        values:
          team: ${{ parameters.team }}
          storageGB: ${{ parameters.storageGB }}
          version: ${{ parameters.version }}
          environment: ${{ parameters.environment }}
    - id: pr
      name: Abrir Pull Request al repo de GitOps
      action: publish:github:pull-request
      input:
        repoUrl: github.com?owner=acme&repo=platform-gitops
        branchName: provision-${{ parameters.team }}-db
        title: "Provisionar Postgres para ${{ parameters.team }}"
        targetPath: claims/${{ parameters.team }}
        description: Auto-generado por el Golden Path de Backstage.
    - id: register
      name: Registrar en el Software Catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.pr.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Ver Pull Request
        url: ${{ steps.pr.output.remoteUrl }}
```

### 3.9 Alternativa: la misma capacidad como Kratix Promise

Cuando querés distribuir la capacidad *completa* como producto instalable (no solo la infra):

```yaml
# promise-postgresql.yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
spec:
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.marketplace.acme.io
    spec:
      group: marketplace.acme.io
      scope: Namespaced
      names:
        plural: postgresqls
        singular: postgresql
        kind: postgresql
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
                    storageGB: { type: integer, default: 20 }
                    environment:
                      type: string
                      enum: [dev, staging, prod]
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: create-resources
                image: acme/postgres-request-pipeline:v1.0.0
                # el contenedor lee /kratix/input/object.yaml y escribe
                # los manifiestos resultantes en /kratix/output/
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Instalar y verificar la Platform API

```console
$ kubectl apply -f xrd-postgresql.yaml
compositeresourcedefinition.apiextensions.crossplane.io/xpostgresqlinstances.platform.acme.io created

$ kubectl apply -f functions.yaml -f composition-postgresql-aws.yaml -f providerconfig-aws.yaml
function.pkg.crossplane.io/function-patch-and-transform created
function.pkg.crossplane.io/function-auto-ready created
composition.apiextensions.crossplane.io/postgresql-aws created
providerconfig.aws.upbound.io/default created

$ kubectl get xrd
NAME                                          ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.platform.acme.io         True          True      41s

$ kubectl get composition
NAME             XR-KIND                 XR-APIVERSION                    AGE
postgresql-aws   XPostgreSQLInstance     platform.acme.io/v1alpha1        39s

$ kubectl get functions
NAME                            INSTALLED   HEALTHY   PACKAGE                                                                    AGE
function-auto-ready             True        True      xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.0               1m
function-patch-and-transform    True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0     1m
```

> **Verificación clave:** `ESTABLISHED=True` y `OFFERED=True` en el XRD. `OFFERED=True` confirma que el Claim namespaced (`PostgreSQLInstance`) está disponible para los devs. Si `OFFERED` está vacío, olvidaste `claimNames` en el XRD.

### 4.2 Consumir la capacidad (rol dev) y observar la reconciliación

```console
$ kubectl apply -f claim.yaml
postgresqlinstance.platform.acme.io/orders-db created

$ kubectl get postgresqlinstance -n team-orders
NAME        ENV       ADDRESS   READY   AGE
orders-db   staging             False   8s

$ kubectl get xpostgresqlinstances
NAME              ENV       ADDRESS   READY   AGE
orders-db-7x9kf   staging             False   9s
```

Traza jerárquica del Claim → XR → managed resources (la herramienta más útil del tema):

```console
$ crossplane beta trace postgresqlinstance orders-db -n team-orders
NAME                                             SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-orders)       True     False   Waiting: ...
└─ XPostgreSQLInstance/orders-db-7x9kf           True     False   Creating: Resources not ready
   ├─ SubnetGroup/orders-db-7x9kf-sg2mn          True     True    Available
   └─ Instance/orders-db-7x9kf-p4rtx             True     False   Creating: creating (state=creating)
```

Dos minutos después:

```console
$ crossplane beta trace postgresqlinstance orders-db -n team-orders
NAME                                             SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (team-orders)       True     True    Available
└─ XPostgreSQLInstance/orders-db-7x9kf           True     True    Available
   ├─ SubnetGroup/orders-db-7x9kf-sg2mn          True     True    Available
   └─ Instance/orders-db-7x9kf-p4rtx             True     True    Available

$ kubectl get postgresqlinstance -n team-orders
NAME        ENV       ADDRESS                                             READY   AGE
orders-db   staging   orders-db.abc123.us-east-1.rds.amazonaws.com        True    6m

$ kubectl get secret orders-db-conn -n team-orders \
    -o jsonpath='{.data.host}' | base64 -d
orders-db.abc123.us-east-1.rds.amazonaws.com
```

### 4.3 El workflow de onboarding

```console
$ curl -X POST http://portal-webhook.argo-events:12000/provision \
    -H 'Content-Type: application/json' \
    -d '{"team":"orders","storageGB":50,"environment":"prod"}'
success

$ argo list -n argo-events
NAME                       STATUS      AGE   DURATION   PRIORITY   MESSAGE
provision-postgres-8k2mx   Running     12s   12s        0

$ argo get provision-postgres-8k2mx -n argo-events
Name:                provision-postgres-8k2mx
Status:              Running
Created:             Fri Aug 07 14:22:10 -0300 (14 seconds ago)

STEP                        TEMPLATE          PODNAME                              DURATION
 ● provision-postgres-8k2mx main
 ├─✔ validate-quota         validate-quota    provision-postgres-8k2mx-3419...     6s
 └─◷ approval               approval-gate     (suspended)
```

Aprobación humana explícita (el `suspend` step) — auditable, con actor:

```console
$ argo resume provision-postgres-8k2mx -n argo-events
workflow provision-postgres-8k2mx resumed

$ argo get provision-postgres-8k2mx -n argo-events
STEP                        TEMPLATE          PODNAME                              DURATION
 ✔ provision-postgres-8k2mx main
 ├─✔ validate-quota         validate-quota    provision-postgres-8k2mx-3419...     6s
 ├─✔ approval               approval-gate
 ├─✔ open-pr                open-claim-pr     provision-postgres-8k2mx-2288...     8s
 └─✔ notify                 notify-slack      provision-postgres-8k2mx-9910...     2s
```

### 4.4 GitOps cierra el loop

```console
$ argocd app get team-database-claims
Name:               argocd/orders-claims
Project:            platform
Sync Status:        Synced to main (a3f9c21)
Health Status:      Healthy

GROUP                KIND                 NAMESPACE     NAME         STATUS   HEALTH
platform.acme.io     PostgreSQLInstance   team-orders   orders-db    Synced   Healthy
```

Prueba de auto-sanación (level-triggered):

```console
$ kubectl delete postgresqlinstance orders-db -n team-orders
postgresqlinstance.platform.acme.io "orders-db" deleted

$ sleep 20 && kubectl get postgresqlinstance -n team-orders
NAME        ENV       ADDRESS                                        READY   AGE
orders-db   staging   orders-db.abc123.us-east-1.rds.amazonaws.com   True    15s
# Argo CD lo restauró desde Git — la fuente de verdad ganó.
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 La escalera de verificación (qué está probado vs. asumido)

| Rung | Pregunta | Comando |
|---|---|---|
| 0 | ¿El tipo (Claim) existe y se ofrece? | `kubectl get xrd` → `OFFERED=True` |
| 1 | ¿El Claim fue admitido? | `kubectl get postgresqlinstance -n <ns>` |
| 2 | ¿El XR se compuso? | `crossplane beta trace ... ` |
| 3 | ¿Los managed resources sincronizaron? | columna `SYNCED` en la traza |
| 4 | ¿El recurso real está listo? | columna `READY` + `status.address` |
| 5 | ¿El connection secret existe y es legible? | `kubectl get secret <conn>` |

**Distinción crítica de examen:** `SYNCED=True` significa "Crossplane logró comunicar la intención al provider" (la API de AWS aceptó el request). `READY=True` significa "el recurso real existe y está operativo". Un recurso puede estar `SYNCED=True, READY=False` durante minutos (RDS tarda ~5-10 min en aprovisionar). `SYNCED=False` en cambio es *tu* problema: credenciales, referencia rota, schema inválido.

### 5.2 Fingerprints de fallas y remedios

**Falla A — El Claim queda pegado en `READY=False` y el XR no aparece.**

```console
$ kubectl describe postgresqlinstance orders-db -n team-orders
...
Events:
  Warning  CompositionSelection  ...  no Composition matches labels / defaultCompositionRef not found
```
*Causa:* `defaultCompositionRef.name` en el XRD apunta a una Composition inexistente, o el Claim no especifica `compositionRef`. *Remedio:* verificá `kubectl get composition`; alineá el nombre.

**Falla B — `SYNCED=False` en la managed resource.**

```console
$ crossplane beta trace postgresqlinstance orders-db -n team-orders
NAME                                   SYNCED   READY   STATUS
...
   └─ Instance/orders-db-7x9kf-p4rtx   False    -       ReconcileError: cannot create: AccessDenied
```
```console
$ kubectl -n crossplane-system logs deploy/provider-aws-rds --tail=20 | grep -i denied
... AccessDenied: User is not authorized to perform: rds:CreateDBInstance
```
*Causa:* el `ProviderConfig` no tiene permisos IAM. *Remedio:* revisá el rol IRSA / la policy adjunta; `SYNCED=False` + `AccessDenied` = problema de credenciales del provider, no del Claim.

**Falla C — La composition function falla.**

```console
$ kubectl describe xpostgresqlinstance orders-db-7x9kf
Events:
  Warning  ComposeResources  ...  pipeline step "patch-and-transform" failed:
           cannot run function-patch-and-transform: invalid patch fromFieldPath
```
```console
$ kubectl get functions
NAME                           INSTALLED   HEALTHY   ...
function-patch-and-transform   True        False     ...
$ kubectl -n crossplane-system logs deploy/function-patch-and-transform --tail=30
```
*Causa:* function no saludable o patch con `fromFieldPath` inexistente. *Remedio:* `HEALTHY=True` en `kubectl get functions`; validá que los `fromFieldPath` existan en el schema del XRD.

**Falla D — El guardrail de Kyverno rechaza el Claim (esperado, pero confuso para el dev).**

```console
$ kubectl apply -f claim-prod.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
  resource PostgreSQLInstance/team-orders/orders-db was blocked:
  Los Claims 'prod' requieren la anotación acme.io/cost-center.
```
*Remedio:* esto es correcto — el guardrail funciona. Añadí la anotación. Diagnóstico: `kubectl get clusterpolicy` + `kubectl describe cpol postgresql-provisioning-guardrails`.

**Falla E — El workflow de Argo queda `suspended` para siempre.**

```console
$ argo list -n argo-events
NAME                       STATUS       AGE   DURATION
provision-postgres-8k2mx   Running      2h    2h
```
*Causa:* nadie ejecutó `argo resume` sobre el `suspend` step de aprobación. *Remedio:* integrá el resume a un botón del portal / bot de Slack; considerá `suspend: { duration: "24h" }` para timeout automático.

**Falla F — `OFFERED` vacío en el XRD (los devs no pueden crear Claims).**

```console
$ kubectl get xrd
NAME                                    ESTABLISHED   OFFERED   AGE
xpostgresqlinstances.platform.acme.io   True                    3m
```
*Causa:* falta el bloque `claimNames` en el XRD. *Remedio:* agregarlo — sin `claimNames` solo existe el XR cluster-scoped, no el Claim namespaced.

### 5.3 Observabilidad de la Platform API

Métricas mínimas a instrumentar (Prometheus):

```promql
# Managed resources no sincronizados por más de 10m (fuga de provisión)
count(crossplane_managed_resource_ready{ready="False"}) by (kind) > 0

# Latencia de provisión (edad del Claim hasta Ready) — SLI del producto plataforma
histogram_quantile(0.95, rate(claim_time_to_ready_seconds_bucket[1h]))

# Workflows de onboarding fallidos
sum(rate(argo_workflows_count{status="Failed"}[15m])) by (workflowtemplate)

# Rechazos de admission por política (fricción del golden path)
sum(rate(kyverno_admission_requests_total{allowed="false"}[1h])) by (policy)
```

El **time-to-ready del Claim** es el SLI que define si tu Platform API es un producto usable. Un p95 de días equivale a no tener self-service.

### 5.4 Checklist de producción antes de publicar una capacidad

- [ ] XRD con `OFFERED=True` y schema con `enum`/`default`/`minimum`/`maximum` — validación en el borde.
- [ ] RBAC namespaced: devs solo crean Claims, nunca XRs/Compositions/ProviderConfigs.
- [ ] `ProviderConfig` con credenciales federadas (IRSA/Workload Identity), sin llaves estáticas.
- [ ] Guardrails de política (Kyverno/OPA) para cuota, costo y límites por entorno.
- [ ] Connection secret documentado (qué claves expone) y con RBAC de lectura acotado.
- [ ] Claim vive en Git; Argo CD/Flux con `selfHeal: true` — la fuente de verdad es Git, no el cluster.
- [ ] Golden path en el portal (Backstage/Port) que abre un PR, no que crea infra directo.
- [ ] SLI `time-to-ready` y alertas de managed resources no sincronizados.
- [ ] La capacidad se puede *desprovisionar* limpiamente (`kubectl delete claim` → cascada a managed resources, sin recursos huérfanos en la cloud).

---

## 6. Referencias

- **CNPE Curriculum (fuente del examen):** https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **CNCF Platforms White Paper (definición de plataforma y capacidades):** https://tag-app-delivery.cncf.io/whitepapers/platforms/
- **Crossplane — Composite Resources (XR/XRD/Claim):** https://docs.crossplane.io/latest/concepts/composite-resources/
- **Crossplane — Compositions & Composition Functions:** https://docs.crossplane.io/latest/concepts/compositions/
- **Crossplane — function-patch-and-transform:** https://github.com/crossplane-contrib/function-patch-and-transform
- **Kubernetes — Custom Resources & CRDs:** https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- **Kubernetes — Aggregation Layer:** https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/
- **Kubernetes — RBAC:** https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- **Backstage — Software Templates (Scaffolder):** https://backstage.io/docs/features/software-templates/
- **Backstage — Software Catalog:** https://backstage.io/docs/features/software-catalog/
- **Argo Workflows — Documentation:** https://argo-workflows.readthedocs.io/en/latest/
- **Argo Events — Sensors & EventSources:** https://argoproj.github.io/argo-events/
- **Argo CD — ApplicationSet:** https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- **Kratix — Promises (Platform as a Product):** https://docs.kratix.io/
- **Kyverno — Policy Reference:** https://kyverno.io/docs/writing-policies/
- **Upbound — AWS Provider (rds.aws.upbound.io):** https://marketplace.upbound.io/providers/upbound/provider-aws-rds
- **Team Topologies (Platform-as-a-Product, carga cognitiva):** https://teamtopologies.com/key-concepts