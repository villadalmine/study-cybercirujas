# Tema 5.1 — Simplified Access to Platform Capabilities for Developers

> **Certificación:** Cloud Native Platform Engineering Associate (CNPA) · Examen 2025-04-01
> **Dominio 5 — Developer Experience** · Peso del subtema: **2.0**

---

## 1. Motivación y problema arquitectónico de producción

El problema que este subtema resuelve no es tecnológico en origen: es **organizacional y de flujo**. En una organización que corre Kubernetes "crudo", cada equipo de producto (stream-aligned team, en la nomenclatura de *Team Topologies*) que necesita una base de datos, un bucket, un DNS record o un namespace con RBAC correcto debe convertirse, a tiempo parcial, en experto de infraestructura, o bien abrir un ticket y esperar. Ambos caminos degradan el **flow**:

- **La vía "hágalo usted mismo" (unbounded self-service):** el desarrollador copia un `deployment.yaml` de Stack Overflow, no configura `resources.requests`, `PodDisruptionBudget`, `NetworkPolicy` ni `readinessProbe`, y el equipo de plataforma descubre el problema en producción. La superficie de decisión que se le expone al desarrollador es enorme y sin barandas.
- **La vía "abra un ticket" (ticket-ops / ITIL):** cada aprovisionamiento es un handoff síncrono humano. El *lead time for changes* —una de las cuatro métricas DORA— se dispara de minutos a días. El equipo de plataforma se vuelve un cuello de botella y un *bottleneck team*.

El marco conceptual que el examen CNPA exige entender es el de **carga cognitiva** (*cognitive load*). Manning/Skelton distinguen:

| Tipo de carga | Definición | Quién debe absorberla |
|---|---|---|
| **Intrínseca** | Complejidad esencial del dominio de negocio del equipo | El stream-aligned team (es su valor) |
| **Extrínseca** (*extraneous*) | Cómo desplegar, cablear TLS, versionar Helm, configurar IAM | **Debe eliminarse** vía la plataforma |
| **Pertinente** (*germane*) | Relaciones que agregan valor de aprendizaje | Se preserva |

El objetivo de *simplified access* es **reducir la carga cognitiva extrínseca a casi cero** para el consumidor, sin ocultar lo esencial. La Internal Developer Platform (IDP) es, en la taxonomía de Team Topologies, un **Platform Team** que ofrece sus capacidades como **X-as-a-Service** a los stream-aligned teams: la interacción es de bajo ancho de banda, self-service, y no requiere colaboración síncrona.

El *CNCF Platforms White Paper* define esto como las **capacidades de plataforma** ofrecidas a través de **interfaces** consumibles: *"platforms provide their capabilities via self-service interfaces which reduce the cognitive load on the platform's users"*. El principio rector es **platform-as-a-product**: la plataforma tiene usuarios internos, un *product owner*, un roadmap y se mide por adopción y satisfacción, no por tickets cerrados.

### El concepto central: Golden Paths (paved roads)

Un **golden path** (o *paved road*, término de Netflix) es un camino **opinado, soportado y bien iluminado** para una tarea común: "crear un microservicio Go con CI/CD, observabilidad y base de datos". No es obligatorio —el desarrollador puede salirse—, pero es el camino de **menor resistencia** y el único con soporte del platform team. El golden path materializa el trade-off arquitectónico clave del tema:

> **Abstracción vs. flexibilidad.** Demasiada abstracción crea una plataforma opaca y frustrante (el desarrollador no puede hacer lo que necesita y no entiende por qué falla). Demasiado poca reexpone la carga cognitiva. El golden path resuelve esto con la regla **"80/20 con puerta de escape"**: cubrir el 80% de los casos con abstracción total, y dejar un *escape hatch* documentado para el 20% restante.

---

## 2. Comparativas técnicas y tablas de trade-offs

### 2.1 Interfaces de consumo (cómo el desarrollador "toca" la plataforma)

Una plataforma madura no ofrece **una** interfaz sino un conjunto coherente sobre el mismo backend declarativo.

| Interfaz | Latencia de aprendizaje | Auditabilidad | Ideal para | Anti-patrón |
|---|---|---|---|---|
| **Portal web** (Backstage) | Muy baja (descubrible) | Media (necesita logs) | Onboarding, catálogo, scaffolding | Volverlo el *único* camino → cuello de botella de UI |
| **CLI** (`platform-cli`, `score`) | Baja | Alta (scripteable) | Bucle interno del dev, automatización | CLI que envuelve `kubectl` sin agregar barandas |
| **API declarativa (CRDs / GitOps)** | Media | **Muy alta** (Git = fuente de verdad) | Producción, IaC, aprobaciones | Exponer la API cruda de K8s como "la plataforma" |
| **IDE plugin** | Muy baja | Baja | Feedback en tiempo de escritura | Lógica de negocio en el plugin (se desincroniza) |
| **ChatOps** | Muy baja | Media | Operaciones puntuales, aprobaciones | Estado mutable solo en el chat |

**Regla de diseño (CNPA):** todas las interfaces deben converger en el **mismo modelo declarativo**. El portal no debe "hacer cosas" que la API no pueda; debe ser un *front-end* que emite el mismo recurso declarativo (idealmente un commit a Git). Esto se llama **interface convergence** y evita el *drift* entre "lo que hace el botón" y "lo que hace el YAML".

### 2.2 Mecanismos de abstracción (cómo se oculta la complejidad)

| Mecanismo | Modelo | Quién compone | Pros | Contras | Cuándo |
|---|---|---|---|---|---|
| **Helm chart parametrizado** | Templating de texto | Platform team | Ubicuo, simple | No es API; `values.yaml` crece sin control; sin estado reconciliado | Empaquetado, no como abstracción de plataforma |
| **Kubernetes Operator (CRD propio)** | Controller reconciliador | Ingeniero Go/Kubebuilder | Reconciliación nativa, semántica rica | Costo de construir/mantener un controller por capacidad | Capacidad con ciclo de vida complejo (ej. operador de DB) |
| **Crossplane (XRD + Composition)** | Composición declarativa de recursos | Platform team (sin código) | Compone cloud + K8s; API propia sin escribir controllers; reconciliado | Curva de aprendizaje; debugging de composiciones | Aprovisionamiento de infra multi-recurso |
| **Score** | Especificación de *workload* agnóstica | Desarrollador | Un solo spec → compose **o** k8s; separa dev-intent de platform-config | No aprovisiona infra por sí solo (necesita provisioners) | Definir *qué* necesita el workload sin *cómo* |
| **Kratix (Promises)** | Marketplace de capacidades como servicio | Platform team | Empaqueta capacidad + su pipeline + su scheduling | Otra pieza a operar | Ofrecer capacidades componibles multi-cluster |
| **Backstage Software Template** | Scaffolding (crea repo + registra) | Platform team | Excelente DX de arranque; catálogo | Es *day-0* (arranque), no reconcilia *day-2* | Golden path de creación |

**Trade-off arquitectónico clave — separación de responsabilidades:** el patrón ganador combina Score (el desarrollador declara **intención**: "necesito un postgres y un puerto 8080") con Crossplane o Kratix (el platform team define **cómo** se satisface esa intención en *este* entorno). Esto implementa la separación **Workload Spec ↔ Platform Config** que el examen valora: el mismo `score.yaml` corre en el laptop (`score-compose`) y en producción (`score-k8s`) sin que el desarrollador conozca la infraestructura subyacente.

### 2.3 Modelo de provisioning: push vs pull

| Eje | Push (imperativo, `kubectl apply` desde CI) | Pull (GitOps, Argo/Flux reconcilia) |
|---|---|---|
| Fuente de verdad | El pipeline | **Git** |
| Deriva de configuración | No detectada | **Reconciliada automáticamente** |
| Credenciales de cluster | En el CI (superficie de ataque) | Dentro del cluster (menor exposición) |
| Recomendación CNPA | Solo para bootstrap | **Preferido para self-service en prod** |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Score — el desarrollador declara *intención*, no infraestructura

`score.yaml` (lo escribe el **desarrollador**; es lo único que ve):

```yaml
apiVersion: score.dev/v1b1
metadata:
  name: orders-api

containers:
  orders-api:
    image: registry.example.org/orders-api:1.7.3
    variables:
      PORT: "8080"
      DB_CONNECTION: "postgres://${resources.db.username}:${resources.db.password}@${resources.db.host}:${resources.db.port}/${resources.db.name}"
    resources:
      requests:
        cpu: "250m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"

service:
  ports:
    www:
      port: 8080
      targetPort: 8080

resources:
  db:
    type: postgres
  dns:
    type: dns
  route:
    type: route
    params:
      host: ${resources.dns.host}
      path: /orders
      port: 8080
```

El desarrollador **nunca** menciona StatefulSets, PVCs, credenciales ni Ingress. El *platform team* define cómo se satisface cada `type` (postgres, dns, route) mediante *provisioners*. Este es el corazón de "simplified access": la superficie expuesta es la **intención del workload**.

### 3.2 Crossplane — la plataforma publica una API propia y componible

**(a) CompositeResourceDefinition (XRD)** — el platform team define la *forma* de la capacidad que ofrece. Esto **crea una nueva API en el cluster**:

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
    name: postgres-aws-standard
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
                    tier:
                      type: string
                      enum: ["dev", "standard", "prod"]
                  required:
                    - storageGB
                    - tier
              required:
                - parameters
            status:
              type: object
              properties:
                address:
                  type: string
```

**(b) Composition** — *cómo* se satisface la XRD (el platform team la define una vez; el desarrollador no la ve):

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgres-aws-standard
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: database.platform.example.org/v1alpha1
    kind: XPostgreSQLInstance
  resources:
    - name: rds-instance
      base:
        apiVersion: rds.aws.upbound.io/v1beta1
        kind: Instance
        spec:
          forProvider:
            region: eu-west-1
            engine: postgres
            engineVersion: "15.4"
            instanceClass: db.t3.medium
            username: masteruser
            autoGeneratePassword: true
            passwordSecretRef:
              namespace: crossplane-system
              name: postgres-conn
              key: password
            skipFinalSnapshot: true
            publiclyAccessible: false
          writeConnectionSecretToRef:
            namespace: crossplane-system
            name: postgres-conn
      patches:
        - fromFieldPath: "spec.parameters.storageGB"
          toFieldPath: "spec.forProvider.allocatedStorage"
        - fromFieldPath: "spec.parameters.tier"
          toFieldPath: "spec.forProvider.instanceClass"
          transforms:
            - type: map
              map:
                dev: db.t3.small
                standard: db.t3.medium
                prod: db.r6g.large
```

**(c) Claim** — lo que escribe el **desarrollador**. Es namespaced, self-service, y toda la complejidad de arriba desaparece:

```yaml
apiVersion: database.platform.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: team-orders
spec:
  parameters:
    storageGB: 50
    tier: standard
  writeConnectionSecretToRef:
    name: orders-db-conn
```

> **Nota de versión (examen 2025-04-01):** en Crossplane **v2** los *Claims* namespaced se están consolidando en **Composite Resources namespaced** y el patrón Claim se marca como legacy. El modelo mental —el desarrollador consume una API simple, el platform team compone lo complejo— es idéntico. Verificá siempre `crossplane version` contra la doc.

### 3.3 Backstage — Software Template (golden path de creación, *day-0*)

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: golden-path-go-service
  title: Go Microservice (Golden Path)
  description: Crea un microservicio Go con CI/CD, Dockerfile, observabilidad y catalogado
  tags:
    - recommended
    - golang
spec:
  owner: group:platform-team
  type: service
  parameters:
    - title: Identidad del servicio
      required:
        - name
        - owner
      properties:
        name:
          title: Nombre
          type: string
          pattern: '^[a-z0-9-]+$'
          ui:autofocus: true
        owner:
          title: Equipo propietario
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
    - title: Repositorio
      required:
        - repoUrl
      properties:
        repoUrl:
          title: Ubicación
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts:
              - github.com
  steps:
    - id: fetch
      name: Fetch skeleton + render
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
    - id: publish
      name: Publicar repositorio
      action: publish:github
      input:
        repoUrl: ${{ parameters.repoUrl }}
        defaultBranch: main
        description: 'Servicio ${{ parameters.name }} (golden path)'
    - id: register
      name: Registrar en el catálogo
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'
  output:
    links:
      - title: Repositorio
        url: ${{ steps.publish.output.remoteUrl }}
      - title: Ver en el catálogo
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
```

`catalog-info.yaml` (generado en el skeleton; hace el servicio **descubrible** — otro eje de "simplified access"):

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: orders-api
  description: API de gestión de órdenes
  annotations:
    backstage.io/kubernetes-id: orders-api
    argocd/app-name: orders-api
spec:
  type: service
  lifecycle: production
  owner: group:team-orders
  system: commerce
  providesApis:
    - orders-api-rest
  dependsOn:
    - resource:orders-db
```

### 3.4 RBAC — habilitar self-service **con barandas**

Self-service sin control es un incidente esperando ocurrir. Se otorga a los desarrolladores permiso para crear **Claims** (la API simplificada), **no** los recursos de infra subyacentes:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: self-service-db-consumer
  namespace: team-orders
rules:
  - apiGroups: ["database.platform.example.org"]
    resources: ["postgresqlinstances"]
    verbs: ["create", "get", "list", "watch", "delete"]
  # NO se otorga acceso a rds.aws.upbound.io: eso es responsabilidad de la plataforma
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-orders-db-self-service
  namespace: team-orders
subjects:
  - kind: Group
    name: team-orders
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: self-service-db-consumer
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Comandos CLI y salidas reales de terminal

### 4.1 Score: un spec, dos targets (paridad dev/prod)

```console
$ score-compose init
INFO: Initialised new score-compose state directory .score-compose

$ score-compose generate score.yaml --build orders-api=./src
INFO: Added container "orders-api"
INFO: Provisioned resource "db" (type: postgres)  -> service "db-orders-api"
INFO: Provisioned resource "dns"                   -> host "orders-api.localhost"
INFO: Wrote compose file "compose.yaml"

$ docker compose up -d
[+] Running 3/3
 ✔ Container orders-api-db-1        Started   0.4s
 ✔ Container orders-api-wait-db-1   Exited    0.9s
 ✔ Container orders-api-1          Started   1.2s
```

El **mismo** `score.yaml`, ahora a Kubernetes:

```console
$ score-k8s generate score.yaml -o manifests.yaml
INFO: Loaded 1 score file(s)
INFO: Resource "db"    provisioned by "postgres.default#orders-api.db"
INFO: Resource "route" provisioned -> Ingress "orders-api"
INFO: Wrote 4 manifest(s): Deployment, Service, Secret, Ingress

$ kubectl apply -f manifests.yaml
deployment.apps/orders-api created
service/orders-api created
secret/db-orders-api created
ingress.networking.k8s.io/orders-api created
```

### 4.2 Crossplane: consumir la API de la plataforma

```console
$ kubectl apply -f orders-db-claim.yaml
postgresqlinstance.database.platform.example.org/orders-db created

$ kubectl get postgresqlinstance -n team-orders
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False   orders-db-conn      35s

# Tras la reconciliación con AWS:
$ kubectl get postgresqlinstance orders-db -n team-orders
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     True    orders-db-conn      6m12s

$ kubectl get secret orders-db-conn -n team-orders -o jsonpath='{.data.endpoint}' | base64 -d
orders-db-9x2k.abc123.eu-west-1.rds.amazonaws.com
```

### 4.3 Backstage: ejecutar el golden path

```console
$ yarn backstage-cli repo start
[0] webpack compiled successfully
[1] Backend up on :7007 — plugin: scaffolder, catalog, kubernetes

# Tras completar el wizard en el portal, el scaffolder emite:
[scaffolder] Task 6f3a-... running template golden-path-go-service
[scaffolder]   step fetch:    ✔  rendered 14 files
[scaffolder]   step publish:  ✔  https://github.com/example-org/orders-api
[scaffolder]   step register: ✔  component:default/orders-api
[scaffolder] Task 6f3a-... completed
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Verificar que el self-service *realmente* funciona (RBAC)

Nunca asumas los permisos: probalos con `auth can-i` suplantando al usuario/grupo real.

```console
$ kubectl auth can-i create postgresqlinstances \
    --as-group=team-orders -n team-orders
yes

# La baranda: el dev NO debe poder tocar la infra subyacente
$ kubectl auth can-i create instances.rds.aws.upbound.io \
    --as-group=team-orders -n team-orders
no
```

Si el segundo devuelve `yes`, la abstracción está rota: el desarrollador puede saltarse la plataforma y crear recursos crudos.

### 5.2 Diagnóstico de un Claim de Crossplane atascado

Síntoma: `READY=False` persistente. El árbol de eventos es la herramienta clave:

```console
$ kubectl describe postgresqlinstance orders-db -n team-orders
...
Events:
  Warning  CannotCompose   4m   composite/orders-db-abc  cannot resolve
    resources: cannot render composed resource "rds-instance": patch failed:
    spec.parameters.tier: value "gold" not in map [dev standard prod]

# Confirmar en el XR y en el recurso gestionado:
$ crossplane beta trace postgresqlinstance/orders-db -n team-orders
NAME                          SYNCED  READY  STATUS
PostgreSQLInstance/orders-db  True    False  Waiting: ...
└─ XPostgreSQLInstance/...    True    False  Creating
   └─ Instance/orders-db-rds  False   -      ReconcileError: InvalidParameterValue
```

**Ladder de diagnóstico:** Claim → Composite (XR) → Managed Resource → Provider → API del cloud. El error casi siempre está en el eslabón donde `SYNCED` pasa a `False`.

### 5.3 Falla de scaffolding en Backstage

| Síntoma | Causa probable | Verificación |
|---|---|---|
| Template no aparece en `/create` | No registrado en `app-config` ni catálogo | `kubectl`/UI: buscar la entidad `kind: Template` |
| `publish:github` falla con 403 | Token del integration sin scope `repo` | Revisar `integrations.github` en `app-config.yaml` |
| Componente no aparece tras crear | `catalog-info.yaml` mal formado | Portal → *Inspect entity* → pestaña *Errors* |
| Variables `${{ }}` vacías | Paso previo no emitió el `output` | Ver *Task log* del scaffolder, paso por paso |

### 5.4 Score: verificar la separación intención/config

```console
# Validar el spec ANTES de generar (detecta placeholders sin resolver):
$ score-k8s generate score.yaml --dry-run
ERROR: resource "db": no provisioner registered for type "postgres"
       (hint: score-k8s provisioners list)

$ score-k8s provisioners list
TYPE       CLASS     PROVISIONER
postgres   default   template://community/postgres
dns        default   template://community/dns
```

Un error `no provisioner registered` significa que el desarrollador declaró una intención que **la plataforma de este entorno no sabe satisfacer** — el fallo correcto es que rompa en *generate*, no en producción.

### 5.5 Checklist de aceptación de un golden path (revisión de plataforma)

1. **Time-to-first-deploy:** un desarrollador nuevo, ¿llega de "cero" a "corriendo en dev" en < 30 min sin tocar a un humano? (métrica de DX)
2. **Escape hatch:** ¿existe y está documentado el camino para el 20% no cubierto?
3. **Interface convergence:** ¿el portal, la CLI y GitOps producen el *mismo* recurso declarativo?
4. **Barandas RBAC:** `auth can-i` confirma que se expone la API simplificada y **no** la cruda.
5. **Descubribilidad:** ¿el resultado queda registrado en el catálogo con `owner` y `lifecycle`?
6. **Day-2:** ¿hay reconciliación (GitOps/Crossplane) o el scaffolding es un fire-and-forget?

---

## 6. Referencias

- CNCF — *CNPA Curriculum* (fuente normativa del examen): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF TAG App Delivery — *Platforms White Paper* (definición de capacidades e interfaces self-service): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF — *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- Backstage — *Software Templates / Scaffolder*: https://backstage.io/docs/features/software-templates/
- Backstage — *Software Catalog (`catalog-info.yaml`)*: https://backstage.io/docs/features/software-catalog/descriptor-format
- Score — *Specification & CLI (`score-compose`, `score-k8s`)*: https://docs.score.dev/
- Crossplane — *Composite Resources, XRDs & Compositions*: https://docs.crossplane.io/latest/concepts/composite-resources/
- Kratix — *Promises (Compound capabilities as-a-service)*: https://docs.kratix.io/
- Kubernetes — *Using RBAC Authorization* (`auth can-i`, Roles, RoleBindings): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Team Topologies — *Cognitive Load & Platform-as-a-Service teams*: https://teamtopologies.com/key-concepts