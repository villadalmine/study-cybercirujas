# Tema 5.3 — Developer Portals for Platform Adoption (Backstage)

**Certificación:** CNPA (Cloud Native Platform Engineering Associate) · Examen 2025-04-01
**Dominio 5 — Platform Advocacy & Adoption · Peso: 2.0**

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El problema no es técnico, es de carga cognitiva

Una plataforma interna (IDP, *Internal Developer Platform*) madura expone decenas de capacidades: clusters Kubernetes multi-tenant, pipelines de CI/CD, GitOps con Argo CD/Flux, secretos con External Secrets, service mesh, observabilidad con Prometheus/Grafana/OpenTelemetry, policy-as-code con Kyverno/OPA. Cada una tiene su propia API, su propia UI y su propia curva de aprendizaje.

El fracaso clásico de adopción no es que la plataforma sea mala, sino que **el desarrollador de un equipo stream-aligned no sabe qué existe, quién es dueño de qué, ni cómo empezar sin abrir cinco tickets**. El *CNCF Platforms White Paper* (TAG App Delivery) formaliza esto: una plataforma se define por sus **interfaces** — y el portal de desarrolladores es la interfaz de descubrimiento y self-service por excelencia, complementaria a la CLI, las APIs y GitOps.

En términos de *Team Topologies*, el portal es cómo el **platform team** reduce la carga cognitiva de los **stream-aligned teams**: convierte conocimiento tribal ("preguntá a Juan cómo se despliega") en **golden paths** documentados y ejecutables. Sin portal, la *Thinnest Viable Platform* (TVP) suele degenerar en un wiki desactualizado.

### 1.2 Los tres problemas concretos que resuelve un portal

| Problema | Síntoma en producción | Primitiva del portal |
|---|---|---|
| **Descubribilidad** | "¿Existe ya un servicio de notificaciones? ¿Quién lo mantiene?" | **Software Catalog** (grafo de entidades) |
| **Onboarding / time-to-first-deploy** | Un servicio nuevo tarda 2 semanas en tener repo, CI, namespace y dashboards | **Software Templates / Scaffolder** (golden paths) |
| **Documentación que se pudre** | El README miente; la wiki tiene 8 meses | **TechDocs** (docs-like-code, versionada con el código) |

Backstage —creado en Spotify, donado a la CNCF en 2020, hoy proyecto **Incubating**— es la implementación de referencia de estos tres pilares más un framework de plugins para integrar el resto de la plataforma (Kubernetes, CI, cost insights, PagerDuty, etc.).

### 1.3 El problema arquitectónico interno de Backstage

Backstage **no es una aplicación monolítica**: es un framework. Su arquitectura tiene tres capas cuyo acoplamiento define casi todos los problemas operativos:

```
┌────────────────────────────────────────────────────────────┐
│  Frontend (React SPA)                                        │
│   · App shell + plugins de frontend (@backstage/plugin-*)    │
│   · Se compila a estático y se sirve por plugin-app-backend  │
└───────────────▲────────────────────────────────────────────┘
                │  HTTP (/api/<plugin>/...)
┌───────────────┴────────────────────────────────────────────┐
│  Backend (Node.js) — "new backend system"                   │
│   · createBackend() + backend.add(import('plugin'))         │
│   · Catalog · Scaffolder · TechDocs · Auth · Permission ·   │
│     Search · Kubernetes                                      │
└───────────────▲───────────────────────▲────────────────────┘
                │                        │
        ┌───────┴───────┐        ┌───────┴────────┐
        │  PostgreSQL   │        │ Object storage │
        │ (catálogo,    │        │  (TechDocs:    │
        │  tasks, etc.) │        │   GCS/S3/Blob) │
        └───────────────┘        └────────────────┘
```

La consecuencia arquitectónica clave: **el catálogo es un motor de procesamiento asíncrono con estado en Postgres**, no una base de datos pasiva. Cada entidad pasa por un *processing loop* (fetch → parse → process → stitch) en un intervalo. Entender ese loop es lo que separa "el portal no muestra mi servicio" de un diagnóstico real (§5).

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Modelo de entidades del Software Catalog

El catálogo es un **grafo dirigido de entidades tipadas**. Conocer los `kind` y sus relaciones es evaluable y es la base de todo el resto.

| `kind` | Representa | Relaciones típicas (`spec`) |
|---|---|---|
| **Component** | Software desplegable/consumible (`service`, `website`, `library`) | `owner`, `system`, `providesApis`, `consumesApis`, `dependsOn`, `subcomponentOf` |
| **API** | Contrato (OpenAPI, gRPC, AsyncAPI, GraphQL) | `owner`, `system`, `definition` |
| **Resource** | Infraestructura (DB, bucket, topic Kafka) | `owner`, `system`, `dependsOn` |
| **System** | Colección de componentes/recursos que forman una capacidad | `owner`, `domain` |
| **Domain** | Área de negocio que agrupa systems | `owner` |
| **Group** | Equipo / unidad organizativa | `parent`, `children`, `members` |
| **User** | Persona | `memberOf` |
| **Location** | Puntero a otras entidades (ingesta) | `target`, `targets` |
| **Template** | Golden path ejecutable (Scaffolder) | `parameters`, `steps`, `output` |

**Regla de examen:** las relaciones `providesApis`/`consumesApis`/`dependsOn`/`ownedBy`/`partOf` se *derivan* de estos campos y se materializan como aristas del grafo — no se escriben a mano, las calcula el `BuiltinKindsEntityProcessor` durante el stitching.

### 2.2 Build vs Buy — Backstage OSS self-hosted vs IDP como SaaS

Decisión de plataforma clásica y explícitamente evaluable en el dominio de adopción.

| Dimensión | **Backstage OSS (self-hosted)** | **SaaS IDP** (Port, Cortex, OpsLevel) | **Backstage gestionado** (Roadie, Spotify Portal) |
|---|---|---|---|
| Modelo de extensión | Plugins TypeScript/React — poder total | Config declarativa (blueprints/YAML), no-code | Plugins Backstage sin operar la infra |
| Time-to-value | Semanas–meses (montar backend, DB, auth) | Días | Días–semanas |
| Coste operativo | Node + Postgres + storage + upgrades tú | Cero infra, licencia por dev | Licencia; infra gestionada |
| Data model | Grafo de entidades extensible, tú lo defines | Modelo propietario configurable | Grafo Backstage |
| Lock-in | Ninguno (Apache 2.0, CNCF) | Alto (modelo y plugins propietarios) | Medio (Backstage estándar, hosting propietario) |
| Upgrades | **Tu responsabilidad** — ritmo mensual, breaking changes | Transparentes | Gestionados |
| Ideal para | Org con equipo de plataforma con capacidad de front/back TS | Org que quiere resultado, no mantener un framework | Quiere Backstage sin operar Node/Postgres |

**Trade-off central:** Backstage OSS maximiza flexibilidad y elimina lock-in a coste de un *producto interno que hay que mantener* (frontend React + backend Node + DB + el ciclo de upgrades más agresivo del ecosistema). El anti-patrón número uno de adopción es adoptar Backstage sin asignar un equipo con dueño; se convierte en otro artefacto abandonado.

### 2.3 TechDocs — estrategias de build y publish

| Estrategia | `techdocs.builder` | `generator.runIn` | `publisher.type` | Cuándo |
|---|---|---|---|---|
| **Local / basic** | `local` | `docker` o `local` | `local` (disco del pod) | POC, dev. **No** en prod: efímero, no escala horizontal |
| **External (recomendado prod)** | `external` | `local` (en CI) | `awsS3` / `googleGcs` / `azureBlobStorage` | Prod. La build ocurre en CI; el portal solo sirve HTML pre-renderizado |

**Regla de examen:** en producción con réplicas múltiples, `builder: 'local'` es un anti-patrón — cada pod construiría por su cuenta y el HTML no se comparte. La arquitectura correcta es **build en CI → publish a object storage → el backend solo lee**.

---

## 3. Manifiestos e infraestructura completos

### 3.1 `catalog-info.yaml` — descriptor de entidad (Component + System + API)

Archivo que vive **junto al código** del servicio y es la unidad de ingesta.

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: petstore
  namespace: default
  title: Petstore Service
  description: Servicio de gestión de mascotas y pagos asociados.
  labels:
    tier: "1"
  tags:
    - java
    - payments
  annotations:
    backstage.io/techdocs-ref: dir:.
    github.com/project-slug: acme/petstore
    backstage.io/kubernetes-id: petstore
    backstage.io/kubernetes-namespace: payments
    pagerduty.com/service-id: PXXXXXX
    prometheus.io/rule: petstore_slo_burn
  links:
    - url: https://grafana.acme.example.com/d/petstore
      title: Dashboard SLO
      icon: dashboard
spec:
  type: service
  lifecycle: production
  owner: group:default/team-payments
  system: payments-platform
  providesApis:
    - petstore-api
  consumesApis:
    - auth-api
  dependsOn:
    - resource:default/petstore-db
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: petstore-api
  description: API REST del servicio petstore (OpenAPI 3.0).
spec:
  type: openapi
  lifecycle: production
  owner: group:default/team-payments
  system: payments-platform
  definition:
    $text: ./openapi/petstore.yaml
---
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: petstore-db
  description: Cloud SQL Postgres de petstore.
spec:
  type: database
  lifecycle: production
  owner: group:default/team-payments
  system: payments-platform
---
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: payments-platform
  description: Capacidad de pagos end-to-end.
spec:
  owner: group:default/team-payments
  domain: commerce
```

### 3.2 `template.yaml` — golden path del Scaffolder (`v1beta3`)

Golden path completo: pide parámetros → renderiza skeleton → publica repo en GitHub → registra en el catálogo.

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: golden-path-microservice
  title: Golden Path · Microservicio Java (Spring Boot)
  description: |
    Crea un microservicio con CI, Dockerfile, chart de Helm,
    catalog-info.yaml y TechDocs. Repo + namespace + dashboards listos.
  tags:
    - recommended
    - java
    - spring-boot
spec:
  owner: group:default/platform-team
  type: service

  parameters:
    - title: Identidad del componente
      required:
        - component_id
        - owner
      properties:
        component_id:
          title: Nombre
          type: string
          description: Único, kebab-case. Será el nombre del repo y del Component.
          pattern: '^[a-z0-9]+(-[a-z0-9]+)*$'
          ui:autofocus: true
        description:
          title: Descripción
          type: string
        owner:
          title: Equipo dueño
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group

    - title: Destino del repositorio
      required:
        - repoUrl
      properties:
        repoUrl:
          title: Repositorio
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts:
              - github.com

  steps:
    - id: fetch
      name: Renderizar skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          component_id: ${{ parameters.component_id }}
          description: ${{ parameters.description }}
          owner: ${{ parameters.owner }}
          destination: ${{ parameters.repoUrl | parseRepoUrl }}

    - id: publish
      name: Publicar en GitHub
      action: publish:github
      input:
        repoUrl: ${{ parameters.repoUrl }}
        description: ${{ parameters.description }}
        defaultBranch: main
        repoVisibility: internal
        protectDefaultBranch: true
        requireCodeOwnerReviews: true

    - id: register
      name: Registrar en el catálogo
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps['publish'].output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'

  output:
    links:
      - title: Repositorio
        url: ${{ steps['publish'].output.remoteUrl }}
      - title: Abrir en el catálogo
        icon: catalog
        entityRef: ${{ steps['register'].output.entityRef }}
```

### 3.3 `app-config.production.yaml` — configuración del backend

```yaml
app:
  title: Acme Platform Portal
  baseUrl: https://portal.acme.example.com

organization:
  name: Acme

backend:
  baseUrl: https://portal.acme.example.com
  listen:
    port: 7007
    host: 0.0.0.0
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: https://portal.acme.example.com
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
      ssl:
        rejectUnauthorized: false

integrations:
  github:
    - host: github.com
      apps:
        - $include: /etc/backstage/secrets/github-app-credentials.yaml

auth:
  environment: production
  providers:
    github:
      production:
        clientId: ${AUTH_GITHUB_CLIENT_ID}
        clientSecret: ${AUTH_GITHUB_CLIENT_SECRET}
        signIn:
          resolvers:
            - resolver: usernameMatchingUserEntityName

catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Domain, Group, User, Template]
  providers:
    github:
      acmeOrg:
        organization: 'acme'
        catalogPath: '/catalog-info.yaml'
        filters:
          branch: 'main'
          repository: '.*'
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 3 }
  locations:
    - type: url
      target: https://github.com/acme/platform-catalog/blob/main/org/groups.yaml
      rules:
        - allow: [Group, User]

techdocs:
  builder: 'external'
  generator:
    runIn: 'local'
  publisher:
    type: 'googleGcs'
    googleGcs:
      bucketName: 'acme-techdocs'

kubernetes:
  serviceLocatorMethod:
    type: 'multiTenant'
  clusterLocatorMethods:
    - type: 'config'
      clusters:
        - name: prod
          url: https://k8s.acme.example.com
          authProvider: 'serviceAccount'
          serviceAccountToken: ${K8S_SA_TOKEN}
          caData: ${K8S_CA_DATA}

permission:
  enabled: true
```

### 3.4 `packages/backend/src/index.ts` — new backend system

```typescript
import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// App shell (sirve el frontend compilado)
backend.add(import('@backstage/plugin-app-backend'));

// Catálogo + modelo de entidades de Scaffolder + descubrimiento en GitHub
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);
backend.add(import('@backstage/plugin-catalog-backend-module-github'));

// Scaffolder (golden paths)
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));

// TechDocs
backend.add(import('@backstage/plugin-techdocs-backend'));

// Auth
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(import('@backstage/plugin-auth-backend-module-github-provider'));

// Permission framework (política real, no allow-all, en prod)
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(import('@internal/plugin-permission-policy-acme'));

// Search
backend.add(import('@backstage/plugin-search-backend'));
backend.add(import('@backstage/plugin-search-backend-module-catalog'));
backend.add(import('@backstage/plugin-search-backend-module-techdocs'));

// Kubernetes
backend.add(import('@backstage/plugin-kubernetes-backend'));

backend.start();
```

### 3.5 Despliegue en Kubernetes con el Helm chart oficial

`values.yaml`:

```yaml
backstage:
  image:
    registry: ghcr.io
    repository: acme/backstage
    tag: "2026.08.07-1"
    pullPolicy: IfNotPresent
  command: ["node", "packages/backend"]
  args:
    - "--config"
    - "app-config.yaml"
    - "--config"
    - "app-config.production.yaml"
  replicas: 2
  extraEnvVarsSecrets:
    - acme-portal-secrets
  extraVolumeMounts:
    - name: github-app
      mountPath: /etc/backstage/secrets
      readOnly: true
  extraVolumes:
    - name: github-app
      secret:
        secretName: acme-github-app
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits: { cpu: "1", memory: 1Gi }

ingress:
  enabled: true
  className: nginx
  host: portal.acme.example.com
  tls:
    enabled: true
    secretName: portal-acme-tls

service:
  type: ClusterIP
  ports:
    backend: 7007

postgresql:
  enabled: true
  auth:
    username: bn_backstage
    database: backstage
    existingSecret: acme-portal-postgresql
  primary:
    persistence:
      enabled: true
      size: 20Gi
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Bootstrap de una instancia nueva

```console
$ npx @backstage/create-app@latest --path acme-portal
? Enter a name for the app [required] acme-portal
Creating the app...
 Checking if the directory is available:
  checking      acme-portal ✔
 Executing template with variables:
  templating    app-config.yaml.hbs ✔
  templating    package.json.hbs ✔
 Installing dependencies:
  determining   yarn version ✔
  executing     yarn install ✔
🥇  Successfully created acme-portal

$ cd acme-portal && yarn dev
[0] Loaded config from app-config.yaml
[1] webpack compiled successfully
[0] 2026-08-07T14:22:10.114Z catalog info Performing database migration
[0] 2026-08-07T14:22:11.402Z rootHttpRouter info Listening on :7007
[1] <i> [webpack-dev-server] Project is running at http://localhost:3000/
```

### 4.2 Verificar que el catálogo procesó las entidades

```console
$ curl -s "http://localhost:7007/api/catalog/entities?filter=kind=component" \
    -H "Authorization: Bearer $TOKEN" | jq '.[].metadata.name'
"petstore"
"auth-service"
"billing-worker"

$ curl -s "http://localhost:7007/api/catalog/entities/by-name/component/default/petstore" \
    -H "Authorization: Bearer $TOKEN" \
  | jq '{name:.metadata.name, owner:.spec.owner, relations:[.relations[].type] | unique}'
{
  "name": "petstore",
  "owner": "group:default/team-payments",
  "relations": [
    "dependsOn",
    "ownedBy",
    "partOf",
    "providesApi"
  ]
}
```

### 4.3 Registrar una location manualmente y forzar refresh

```console
$ curl -s -X POST "http://localhost:7007/api/catalog/locations" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"type":"url","target":"https://github.com/acme/petstore/blob/main/catalog-info.yaml"}' \
  | jq '.entities[].metadata.name'
"petstore"
"petstore-api"
"petstore-db"

# Forzar reprocesado inmediato (sin esperar el intervalo del provider)
$ curl -s -X POST "http://localhost:7007/api/catalog/refresh" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"entityRef":"component:default/petstore"}' -w '%{http_code}\n' -o /dev/null
201
```

### 4.4 Ejecutar un golden path por API (equivalente a la UI)

```console
$ curl -s -X POST "http://localhost:7007/api/scaffolder/v2/tasks" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{
          "templateRef": "template:default/golden-path-microservice",
          "values": { "component_id": "notifications",
                      "owner": "group:default/team-messaging",
                      "repoUrl": "github.com?owner=acme&repo=notifications" }
        }' | jq
{ "taskId": "b9f3c1a2-7d44-4f0e-9d2f-2f1c8e5a1b73" }

$ curl -s "http://localhost:7007/api/scaffolder/v2/tasks/b9f3c1a2-.../events" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[].body.message' | tail -5
Cloning into skeleton...
Publishing to github.com/acme/notifications
Committing files to main
Registering component:default/notifications in catalog
Task completed with status: completed
```

### 4.5 Despliegue con Helm y verificación

```console
$ helm repo add backstage https://backstage.github.io/charts && helm repo update
"backstage" has been added to your repositories

$ helm upgrade --install acme-portal backstage/backstage \
    -n backstage --create-namespace -f values.yaml
Release "acme-portal" does not exist. Installing it now.
NAME: acme-portal
STATUS: deployed
REVISION: 1

$ kubectl -n backstage get pods
NAME                             READY   STATUS    RESTARTS   AGE
acme-portal-7c9f5b8d4c-4rk2p     1/1     Running   0          92s
acme-portal-7c9f5b8d4c-hn8vq     1/1     Running   0          92s
acme-portal-postgresql-0         1/1     Running   0          92s

$ kubectl -n backstage exec deploy/acme-portal -- \
    wget -qO- localhost:7007/.backstage/health/v1/readiness
{"status":"ok"}
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El processing loop: mapa mental para diagnosticar

Toda entidad recorre este ciclo asíncrono en el backend del catálogo:

```
Location/Provider ──► [ fetch ] ──► [ parse ] ──► [ process ] ──► [ stitch ] ──► DB final
                                        │              │
                                        ▼              ▼
                                    parse error   validation /
                                                  relation error
                                        └──────────┬───┘
                                                   ▼
                                       entity.status.items[].error
```

**El primer reflejo de diagnóstico es siempre leer `status.items`** de la entidad — ahí aparecen los errores de procesamiento, no en los logs por defecto.

### 5.2 Fallo: "registré el servicio pero no aparece"

```console
# 1) ¿Existe siquiera? Si devuelve 404, nunca se ingirió (location/provider mal).
$ curl -s -o /dev/null -w '%{http_code}\n' \
    "http://localhost:7007/api/catalog/entities/by-name/component/default/petstore" \
    -H "Authorization: Bearer $TOKEN"
404

# 2) ¿La location está registrada?
$ curl -s "http://localhost:7007/api/catalog/locations" \
    -H "Authorization: Bearer $TOKEN" | jq '.[].data.target'
"https://github.com/acme/auth-service/blob/main/catalog-info.yaml"
# → falta petstore: la ingesta nunca ocurrió (GitHub discovery no matcheó, o el archivo no está en main)
```

**Causas frecuentes y su firma:**

| Síntoma | Causa raíz | Verificación / arreglo |
|---|---|---|
| 404 permanente | `catalog-info.yaml` no está en `main`, o el filtro `repository`/`branch` del provider no matchea | Revisar `catalog.providers.github.<id>.filters`; confirmar rama |
| Aparece con `backstage.io/orphan: 'true'` | Su location la referenciaba otra entidad que ya no existe → quedó huérfana | Re-registrar la location raíz o eliminar la huérfana |
| Aparece pero sin dueño / relaciones rotas | `spec.owner` apunta a un Group que no está en el catálogo | Ingerir `Group`/`User` (location `org/groups.yaml`) **antes** que los Components |
| `kind` rechazado | La `rule` de la location no permite ese `kind` | Ajustar `rules: [{ allow: [...] }]` |

### 5.3 Fallo: entidad presente pero con errores de procesamiento

```console
$ curl -s "http://localhost:7007/api/catalog/entities/by-name/component/default/petstore" \
    -H "Authorization: Bearer $TOKEN" | jq '.status.items'
[
  {
    "type": "backstage.io/catalog-processing",
    "level": "error",
    "message": "InputError: Entity did not conform to schema: 'spec/owner' must be string",
    "error": {
      "name": "InputError",
      "message": "Entity did not conform to schema: 'spec/owner' must be string"
    }
  }
]
```

**Lectura:** el YAML se ingirió (parse OK) pero falló la validación de esquema en `process`. La entidad queda con estado anterior o degradada. Se corrige en el `catalog-info.yaml` fuente y se fuerza `POST /api/catalog/refresh`.

### 5.4 Fallo: TechDocs muestra "Documentation not found"

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    "http://localhost:7007/api/techdocs/static/docs/default/component/petstore/index.html" \
    -H "Authorization: Bearer $TOKEN"
404
```

Checklist de diagnóstico:

1. **¿La anotación existe?** `backstage.io/techdocs-ref: dir:.` en `metadata.annotations`.
2. **¿Existe `mkdocs.yml` en el repo?** Sin él, el generador no produce salida.
3. **¿Quién construye?** Con `builder: 'external'`, el HTML debe haberse publicado desde CI al bucket. Si el bucket está vacío, el CI no corrió `techdocs-cli generate && publish`:
   ```console
   $ gsutil ls gs://acme-techdocs/default/component/petstore/
   CommandException: One or more URLs matched no objects.
   ```
   → la pipeline de docs no publicó; el portal no construye en runtime en modo `external`.
4. Permisos del bucket / credenciales del publisher (`googleGcs`): un 403 del backend a GCS aparece en los logs del pod, no en `status.items`.

### 5.5 Fallo: login en loop / usuario no resuelve a una entidad

```console
$ kubectl -n backstage logs deploy/acme-portal | grep -i "sign-in"
auth warn Failed to sign in, unable to resolve user identity:
  no User entity found matching name "jdoe"
```

**Causa:** el `signIn.resolver` (`usernameMatchingUserEntityName`) exige que exista una entidad `User` con ese nombre en el catálogo. Si los `User`/`Group` de la organización no se ingirieron, ningún login funciona. Es el orden correcto de bootstrap: **primero org data, después servicios**.

### 5.6 Fallo: plugin de Kubernetes no muestra workloads

```console
$ curl -s "http://localhost:7007/api/kubernetes/services/petstore" \
    -H "Authorization: Bearer $TOKEN" | jq '.items[].cluster.name, .items[].errors'
"prod"
[{"errorType":"FETCH_ERROR","message":"Unauthorized"}]
```

Diagnóstico: la relación entidad↔workloads se hace por la anotación `backstage.io/kubernetes-id: petstore` (debe coincidir con el label `backstage.io/kubernetes-id` en el Deployment). El `Unauthorized` indica que el `serviceAccountToken` del cluster caducó o el RBAC del SA no tiene `get/list` sobre esos recursos. Verificar del lado del cluster:

```console
$ kubectl auth can-i list pods --as=system:serviceaccount:backstage:backstage-k8s-reader -n payments
no
```

### 5.7 Señales de salud a monitorear en producción

| Señal | Endpoint / fuente | Qué indica |
|---|---|---|
| Readiness/liveness | `/.backstage/health/v1/readiness` · `/liveness` | Backend arriba y DB alcanzable |
| Backlog de procesamiento | métricas `catalog_*` (processing duration, stitched entities) | Si crece, el loop no da abasto → subir réplicas/afinar `schedule` |
| Errores de entidad | `status.items[].level == error` agregados | Descriptores rotos en repos → deuda de catálogo |
| Latencia a Postgres | logs / métricas de DB | Cuello de botella #1 del catálogo a escala |
| Tasks de scaffolder fallidas | `/api/scaffolder/v2/tasks?status=failed` | Golden paths rotos → caída directa de adopción |

**Métrica de negocio (dominio de adopción):** el KPI que valida el portal no es "está desplegado", sino *time-to-first-deploy* y *% de servicios nuevos creados vía golden path*. Un catálogo con 0 errores pero que nadie usa es un fracaso de adopción, no de operación.

---

## 6. Referencias

- Backstage — Documentación oficial: https://backstage.io/docs/overview/what-is-backstage
- Software Catalog (modelo de entidades, formato del descriptor): https://backstage.io/docs/features/software-catalog/
- System Model & relaciones de entidades: https://backstage.io/docs/features/software-catalog/system-model
- Software Templates / Scaffolder (`template.yaml`, actions): https://backstage.io/docs/features/software-templates/
- TechDocs (builder/generator/publisher, arquitectura recomendada): https://backstage.io/docs/features/techdocs/architecture
- New Backend System (`createBackend`, `backend.add`): https://backstage.io/docs/backend-system/
- Authentication & sign-in resolvers: https://backstage.io/docs/auth/
- Permission Framework: https://backstage.io/docs/permissions/overview
- Deployment (Docker, Helm, Postgres): https://backstage.io/docs/deployment/
- Helm chart oficial de la comunidad: https://github.com/backstage/charts
- Repositorio del proyecto (Apache 2.0): https://github.com/backstage/backstage
- CNCF — Backstage (proyecto Incubating): https://www.cncf.io/projects/backstage/
- CNCF TAG App Delivery — Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNPA Curriculum (fuente del temario): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf