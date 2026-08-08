# Ejercicios Guiados — Tema 5.3: Developer Portals for Platform Adoption (Backstage)

> **Objetivo del tema.** Un Internal Developer Portal (IDP) no es un dashboard más: es el *plano de control de la experiencia del desarrollador*. Backstage —donado por Spotify a la CNCF y hoy en estado *Incubating*— convierte el conocimiento disperso de una plataforma (quién es dueño de qué servicio, cómo se crea uno nuevo, dónde está su documentación, en qué cluster corre) en un catálogo consultable y en *golden paths* auto-servicio. En estos ejercicios vas a montar un Backstage real, poblar su Software Catalog, publicar un Software Template, servir TechDocs, conectar Kubernetes y aplicar el Permissions framework. Cada bloque cierra con preguntas de verificación; las respuestas están al final.
>
> **Prerrequisitos.** Node.js 20 LTS o 22, `yarn` 4.x (Backstage usa Yarn PnP/node-modules), `git`, un `kubectl` con acceso a un cluster de prueba (kind/minikube sirve), y un Personal Access Token de GitHub con scope `repo` y `workflow` para las integraciones. Todos los comandos se ejecutan en una VM/host de trabajo, no en producción.

---

## Ejercicio 1 — Scaffolding del portal y anatomía del monorepo

En este bloque creás la app y entendés por qué Backstage es un *framework* (código que vos compilás y desplegás), no un producto instalable.

1. Generá una nueva app. El scaffolder oficial arma un monorepo con dos paquetes: `packages/app` (frontend React) y `packages/backend` (Node.js):

   ```bash
   npx @backstage/create-app@latest
   # Prompt: "Enter a name for the app [required]" -> plataforma-idp
   ```

   Salida esperada (recortada):

   ```
   Creating the app...
    Checking if the directory is available:
      checking      plataforma-idp ✔
    Executing template migrations:
      copying       .npmrc ✔
      templating    package.json.hbs ✔
      ...
    Moving to final location:
      moving        plataforma-idp ✔
    Installing dependencies:
      determining   yarn version ✔
      executing     yarn install ✔

    🥇  Successfully created plataforma-idp
   ```

2. Inspeccioná la estructura mínima que te importa:

   ```bash
   cd plataforma-idp
   ls -1
   ```

   ```
   app-config.yaml
   app-config.production.yaml
   backstage.json
   catalog-info.yaml
   package.json
   packages/
   plugins/
   yarn.lock
   ```

3. Abrí `packages/backend/src/index.ts`. En Backstage moderno (new backend system) el backend se compone declarativamente. Verificá que se vea así:

   ```typescript
   import { createBackend } from '@backstage/backend-defaults';

   const backend = createBackend();

   backend.add(import('@backstage/plugin-app-backend'));
   backend.add(import('@backstage/plugin-catalog-backend'));
   backend.add(import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'));
   backend.add(import('@backstage/plugin-scaffolder-backend'));
   backend.add(import('@backstage/plugin-techdocs-backend'));
   backend.add(import('@backstage/plugin-auth-backend'));
   backend.add(import('@backstage/plugin-auth-backend-module-guest-provider'));
   backend.add(import('@backstage/plugin-permission-backend'));
   backend.add(import('@backstage/plugin-permission-backend-module-allow-all-policy'));

   backend.start();
   ```

4. Levantá el portal en modo desarrollo (arranca frontend en `:3000` y backend en `:7007`):

   ```bash
   yarn start
   ```

   ```
   [0] webpack compiled successfully
   [1] {"level":"info","message":"Listening on :7007","service":"backstage"}
   ```

   Abrí `http://localhost:3000`. Vas a caer en el **Software Catalog** vacío (salvo los ejemplos que trae el scaffolder).

**Preguntas de verificación 1**

- **1.a** ¿Por qué se dice que Backstage es un framework y no una aplicación *shrink-wrapped*? ¿Qué implica eso para la estrategia de upgrades de la plataforma?
- **1.b** ¿Qué responsabilidad cumple `@backstage/plugin-app-backend` dentro del backend, si el frontend React se compila aparte?
- **1.c** El backend arranca con `plugin-permission-backend-module-allow-all-policy`. ¿Qué hace exactamente esa policy y por qué es un riesgo dejarla en producción?

---

## Ejercicio 2 — El Software Catalog: registrar un Component

El corazón de la adopción es que *cada cosa que corre tenga dueño y esté descubible*. El catálogo se puebla con archivos `catalog-info.yaml` versionados **junto al código** del servicio (Catalog-as-Code).

1. En el repo de un servicio de ejemplo (podés crear una carpeta local `svc-payments/`), creá `catalog-info.yaml`:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: payments-api
     description: Servicio de procesamiento de pagos
     annotations:
       github.com/project-slug: acme/payments-api
       backstage.io/techdocs-ref: dir:.
     tags:
       - java
       - spring-boot
     links:
       - url: https://grafana.acme.internal/d/payments
         title: Dashboard de latencia
         icon: dashboard
   spec:
     type: service
     lifecycle: production
     owner: team-payments
     system: checkout
     providesApis:
       - payments-rest
     dependsOn:
       - resource:payments-db
   ```

2. Registrá la entidad manualmente desde la UI: **Create → Register Existing Component**, pegá la URL raw del `catalog-info.yaml` (por ejemplo `https://github.com/acme/payments-api/blob/main/catalog-info.yaml`). Backstage crea internamente una entidad `kind: Location` que apunta al archivo y de ahí ingesta el `Component`.

3. Validá la entidad *antes* de commitear con el CLI, para no romper el catálogo con YAML inválido:

   ```bash
   yarn backstage-cli repo lint    # lint del monorepo
   npx @backstage/cli@latest validate-catalog-info svc-payments/catalog-info.yaml 2>/dev/null \
     || curl -s http://localhost:7007/api/catalog/entities/by-name/component/default/payments-api | jq '.metadata.name, .spec.owner'
   ```

   ```
   "payments-api"
   "team-payments"
   ```

4. Consultá el catálogo por la API REST (útil para automatización y auditoría de ownership):

   ```bash
   curl -s "http://localhost:7007/api/catalog/entities?filter=kind=component,spec.lifecycle=production" \
     | jq -r '.[] | "\(.metadata.name)\t\(.spec.owner)"'
   ```

   ```
   payments-api    team-payments
   ```

5. Provocá un error deliberado: cambiá `owner: team-payments` por `owner:` (vacío) y re-procesá. En **Catalog → payments-api → una pestaña de errores** o en los logs del backend vas a ver el processing error, y la entidad queda marcada como *orphan* o con error, no se descarta en silencio.

**Preguntas de verificación 2**

- **2.a** El `owner` es `team-payments`, no un email. ¿Qué tipo de entidad debe existir para que ese owner resuelva correctamente, y qué pasa en la UI si no existe?
- **2.b** Diferenciá `kind: Component` de `kind: Location`. Cuando registrás una URL en la UI, ¿cuál de los dos se crea primero y cuál es su rol?
- **2.c** ¿Por qué es preferible el *Catalog-as-Code* (el YAML vive en el repo del servicio) frente a cargar entidades a mano en la UI? Nombrá dos consecuencias sobre la calidad del catálogo a escala.
- **2.d** La anotación `backstage.io/techdocs-ref: dir:.` no hace nada por sí sola. ¿Qué otro componente del stack tiene que estar habilitado para que produzca efecto?

---

## Ejercicio 3 — El modelo de entidades: System, Domain, API y relaciones

Un catálogo plano de componentes no escala. El *system model* de Backstage impone una jerarquía —`Domain → System → Component/Resource/API`— que es lo que permite responder "¿qué se rompe si toco esto?".

1. Definí el resto del grafo en un archivo `catalog/checkout.yaml`, usando `---` para separar documentos YAML:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Domain
   metadata:
     name: commerce
     description: Todo lo que factura dinero
   spec:
     owner: group:default/platform
   ---
   apiVersion: backstage.io/v1alpha1
   kind: System
   metadata:
     name: checkout
   spec:
     owner: team-payments
     domain: commerce
   ---
   apiVersion: backstage.io/v1alpha1
   kind: API
   metadata:
     name: payments-rest
   spec:
     type: openapi
     lifecycle: production
     owner: team-payments
     system: checkout
     definition:
       $text: ./openapi/payments.yaml
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Resource
   metadata:
     name: payments-db
   spec:
     type: database
     owner: team-payments
     system: checkout
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Group
   metadata:
     name: team-payments
   spec:
     type: team
     children: []
   ---
   apiVersion: backstage.io/v1alpha1
   kind: User
   metadata:
     name: jdoe
   spec:
     memberOf:
       - team-payments
   ```

2. Registrá el archivo como un `Location` estático en `app-config.yaml` para que se ingeste al arrancar (ideal para entidades organizacionales que no viven en un repo de servicio):

   ```yaml
   catalog:
     locations:
       - type: file
         target: ../../catalog/checkout.yaml
         rules:
           - allow: [Domain, System, API, Resource, Group, User]
   ```

3. Reiniciá el backend y abrí `payments-api` en la UI. Andá a la pestaña **Relations** o al *catalog graph*. Vas a ver el grafo tejido automáticamente por las relaciones inversas:

   ```
   commerce (Domain)
     └── checkout (System)
           ├── payments-api (Component) ──providesApi──> payments-rest (API)
           ├── payments-rest (API)
           └── payments-db (Resource) <──dependsOn── payments-api
   ```

4. Verificá que Backstage generó las relaciones *recíprocas* sin que las hayas escrito. Vos pusiste `providesApis: [payments-rest]` en el Component; consultá la API entity:

   ```bash
   curl -s http://localhost:7007/api/catalog/entities/by-name/api/default/payments-rest \
     | jq '.relations[] | {type, targetRef}'
   ```

   ```
   { "type": "apiProvidedBy", "targetRef": "component:default/payments-api" }
   { "type": "ownedBy",       "targetRef": "group:default/team-payments" }
   { "type": "partOf",        "targetRef": "system:default/checkout" }
   ```

**Preguntas de verificación 3**

- **3.a** Escribiste `providesApis` sólo en el Component, pero la API entity muestra una relación `apiProvidedBy`. ¿De dónde salió? ¿Qué principio del catálogo evita que tengas que mantener las dos puntas a mano?
- **3.b** ¿Cuál es la diferencia semántica entre `System` y `Domain`, y por qué un `Component` pertenece (`partOf`) a un System pero no directamente a un Domain?
- **3.c** Un `Resource` (la base de datos) y una `API` son ambos "cosas del System". ¿Cuándo modelás algo como `Resource` y cuándo como `API`? Dá el criterio.
- **3.d** El bloque `rules: allow: [...]` del `Location` no incluye `Component`. Si el archivo `checkout.yaml` tuviera un `Component`, ¿qué pasaría al ingestarlo, y por qué es una salvaguarda útil?

---

## Ejercicio 4 — Software Templates (Scaffolder): el golden path auto-servicio

Acá está el *driver* real de adopción: en vez de una wiki que dice "cómo crear un microservicio", el desarrollador rellena un formulario y obtiene un repo con CI, Dockerfile, `catalog-info.yaml` y todo el andamiaje, ya registrado en el catálogo.

1. Creá un Software Template en `templates/microservice/template.yaml`:

   ```yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: nodejs-microservice
     title: Node.js Microservice (golden path)
     description: Servicio Express con Dockerfile, CI y registro en catálogo
     tags:
       - recommended
       - nodejs
   spec:
     owner: group:default/platform
     type: service
     parameters:
       - title: Identidad del servicio
         required: [name, owner]
         properties:
           name:
             title: Nombre
             type: string
             pattern: '^[a-z0-9-]+$'
             ui:autofocus: true
           owner:
             title: Owner
             type: string
             ui:field: OwnerPicker
             ui:options:
               catalogFilter:
                 kind: Group
       - title: Repositorio
         required: [repoUrl]
         properties:
           repoUrl:
             title: Ubicación
             type: string
             ui:field: RepoUrlPicker
             ui:options:
               allowedHosts: [github.com]
     steps:
       - id: fetch
         name: Fetch skeleton + template
         action: fetch:template
         input:
           url: ./skeleton
           values:
             name: ${{ parameters.name }}
             owner: ${{ parameters.owner }}
       - id: publish
         name: Publish to GitHub
         action: publish:github
         input:
           repoUrl: ${{ parameters.repoUrl }}
           description: 'Creado desde el golden path'
           defaultBranch: main
           repoVisibility: private
       - id: register
         name: Register in catalog
         action: catalog:register
         input:
           repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
           catalogInfoPath: '/catalog-info.yaml'
     output:
       links:
         - title: Repositorio
           url: ${{ steps.publish.output.remoteUrl }}
         - title: Ver en el catálogo
           entityRef: ${{ steps.register.output.entityRef }}
   ```

2. Creá el `skeleton/` que el template va a materializar. Todo archivo puede llevar placeholders `${{ values.x }}` interpolados con nunjucks:

   ```bash
   mkdir -p templates/microservice/skeleton
   ```

   `templates/microservice/skeleton/catalog-info.yaml`:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: ${{ values.name }}
   spec:
     type: service
     lifecycle: experimental
     owner: ${{ values.owner }}
   ```

3. Habilitá la integración de GitHub en `app-config.yaml` (necesaria para `publish:github`) usando una variable de entorno, nunca un token en claro:

   ```yaml
   integrations:
     github:
       - host: github.com
         token: ${GITHUB_TOKEN}
   ```

   ```bash
   export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
   ```

4. Registrá el template como un `Location` (mismo mecanismo que cualquier entidad) y reiniciá:

   ```yaml
   catalog:
     locations:
       - type: file
         target: ../../templates/microservice/template.yaml
         rules:
           - allow: [Template]
   ```

5. En la UI: **Create → elegí "Node.js Microservice" → Choose**. Completá el formulario y ejecutá. Observá el log en vivo de los tres steps (`fetch`, `publish`, `register`). Al terminar:

   ```
   Run of nodejs-microservice
   ✔ Fetch skeleton + template   (0.8s)
   ✔ Publish to GitHub           (3.2s)
   ✔ Register in catalog         (1.1s)

   Created https://github.com/acme/mi-servicio
   Entity component:default/mi-servicio is now in the catalog.
   ```

**Preguntas de verificación 4**

- **4.a** El campo `owner` usa `ui:field: OwnerPicker` con `catalogFilter: { kind: Group }`. Explicá cómo esto acopla el *scaffolder* con el *catalog* y por qué mejora la calidad del ownership desde el minuto cero de un servicio nuevo.
- **4.b** ¿Por qué el step `catalog:register` es lo que cierra el círculo de la adopción? ¿Qué pasaría con el descubrimiento del servicio si lo omitieras?
- **4.c** El `template.yaml` (nunjucks `${{ }}` evaluado por el scaffolder) y los archivos del `skeleton/` (nunjucks `${{ values.x }}` evaluado en el step `fetch:template`) usan la misma sintaxis pero se procesan en momentos distintos. ¿Por qué el `catalog-info.yaml` del skeleton NO se interpola cuando el scaffolder parsea el template?
- **4.d** El servicio nace con `lifecycle: experimental`. Desde la óptica de platform engineering, ¿por qué es sano que el golden path fije un lifecycle conservador por default en vez de `production`?

---

## Ejercicio 5 — TechDocs: documentación como código, al lado del servicio

La documentación que vive lejos del código se pudre. TechDocs renderiza docs Markdown (via MkDocs) *desde el mismo repo* y las sirve dentro del portal, indexadas y buscables.

1. En `svc-payments/` agregá la estructura MkDocs:

   ```bash
   mkdir -p svc-payments/docs
   ```

   `svc-payments/mkdocs.yml`:

   ```yaml
   site_name: payments-api
   nav:
     - Home: index.md
     - Runbook: runbook.md
   plugins:
     - techdocs-core
   ```

   `svc-payments/docs/index.md`:

   ```markdown
   # payments-api

   Servicio de pagos. SLA 99.95%. On-call: #team-payments.
   ```

2. Confirmá que el `Component` ya tiene la anotación que enlaza docs con entidad (la pusiste en el Ejercicio 2):

   ```yaml
   metadata:
     annotations:
       backstage.io/techdocs-ref: dir:.
   ```

3. En modo dev, TechDocs genera "on the fly": abrí `payments-api → pestaña Docs`. Backstage invoca el generador y renderiza. Verificalo también por CLI:

   ```bash
   npx @techdocs/cli generate --source-dir svc-payments --output-dir svc-payments/site --no-docker
   ```

   ```
   info: Generating documentation...
   info: Successfully generated docs from svc-payments into svc-payments/site
   ```

4. Para producción, la generación **on-the-fly no escala**: se usa el patrón *build-then-publish*. En CI, tras el merge, se compila y se sube a object storage (S3/GCS/Azure). Configurá el backend para leer desde ahí:

   ```yaml
   techdocs:
     builder: 'external'          # el backend NO genera; sólo sirve
     generator:
       runIn: 'local'
     publisher:
       type: 'awsS3'
       awsS3:
         bucketName: 'acme-techdocs'
         region: 'us-east-1'
   ```

   Y en el pipeline de CI del servicio:

   ```bash
   npx @techdocs/cli generate --source-dir . --output-dir ./site
   npx @techdocs/cli publish --publisher-type awsS3 \
     --storage-name acme-techdocs \
     --entity default/component/payments-api
   ```

**Preguntas de verificación 5**

- **5.a** Contrastá `techdocs.builder: 'local'` vs `'external'`. ¿Qué carga se le quita al backend de Backstage al pasar a `'external'`, y por qué eso importa cuando tenés 500 servicios documentados?
- **5.b** ¿Qué relación de dependencia hay entre TechDocs y el Software Catalog? Es decir, ¿podría existir una página de TechDocs para algo que no está en el catálogo?
- **5.c** El comando `publish` recibe `--entity default/component/payments-api`. ¿Por qué el publisher necesita conocer el *entity ref* y no le alcanza con el nombre del bucket?

---

## Ejercicio 6 — Plugin de Kubernetes: cerrar la brecha entre "servicio" y "workload que corre"

Un IDP que sólo tiene metadata es una guía telefónica. El plugin de Kubernetes trae el estado *runtime* —pods, deployments, health— a la vista del propio Component, filtrado por labels.

1. Agregá los plugins de Kubernetes. Frontend en `packages/app` y backend:

   ```bash
   yarn --cwd packages/app add @backstage/plugin-kubernetes
   yarn --cwd packages/backend add @backstage/plugin-kubernetes-backend
   ```

   Y en `packages/backend/src/index.ts`:

   ```typescript
   backend.add(import('@backstage/plugin-kubernetes-backend'));
   ```

2. Configurá el *cluster locator* en `app-config.yaml`. Para un lab, `serviceAccount` con un token; en producción se prefiere `oidc` o `aws`/`gke` con roles:

   ```yaml
   kubernetes:
     serviceLocatorMethod:
       type: 'multiTenant'
     clusterLocatorMethods:
       - type: 'config'
         clusters:
           - name: lab-cluster
             url: https://127.0.0.1:6443
             authProvider: 'serviceAccount'
             serviceAccountToken: ${K8S_SA_TOKEN}
             skipTLSVerify: true          # SOLO lab
   ```

3. Creá un ServiceAccount de solo-lectura en el cluster (principio de menor privilegio para el portal):

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: backstage-reader
     namespace: default
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: backstage-reader
   rules:
     - apiGroups: ['', 'apps']
       resources: ['pods', 'services', 'deployments', 'replicasets', 'configmaps']
       verbs: ['get', 'list', 'watch']
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: backstage-reader
   subjects:
     - kind: ServiceAccount
       name: backstage-reader
       namespace: default
   roleRef:
     kind: ClusterRole
     name: backstage-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f backstage-reader.yaml
   export K8S_SA_TOKEN=$(kubectl create token backstage-reader --duration=8760h)
   ```

4. Conectá el workload con la entidad. Backstage encuentra los recursos por *label selector*, así que anotá el Component **y** etiquetá el Deployment con el mismo id:

   `catalog-info.yaml` (agregar anotación):

   ```yaml
   metadata:
     annotations:
       backstage.io/kubernetes-id: payments-api
   ```

   Deployment en el cluster:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: payments-api
     labels:
       backstage.io/kubernetes-id: payments-api
   spec:
     selector:
       matchLabels:
         app: payments-api
     template:
       metadata:
         labels:
           app: payments-api
           backstage.io/kubernetes-id: payments-api
       spec:
         containers:
           - name: app
             image: nginx:1.27
   ```

5. Reiniciá y abrí `payments-api → pestaña Kubernetes`. Deberías ver el Deployment, sus pods y el estado agregado:

   ```
   Cluster: lab-cluster
   Deployment payments-api    1/1 available
     Pod payments-api-7c9f...  Running   Ready
   ```

**Preguntas de verificación 6**

- **6.a** El plugin usa el label `backstage.io/kubernetes-id`, no el nombre del Deployment. ¿Qué flexibilidad te da desacoplar el *identificador de agrupación* del nombre de los objetos K8s? Dá un caso donde un Component agrupe recursos con nombres distintos.
- **6.b** El ClusterRole otorgado es `get/list/watch` sobre un puñado de recursos, sin `create/update/delete`. Justificá esta decisión desde la superficie de ataque del portal.
- **6.c** ¿Por qué `skipTLSVerify: true` y un token de 1 año son aceptables en el lab pero inaceptables en producción? ¿Qué mecanismo usarías en su lugar para un cluster productivo?

---

## Ejercicio 7 — Permissions framework: quién puede ver y hacer qué

A escala, "todos ven y hacen todo" (la `allow-all-policy` del Ejercicio 1) es inaceptable. El Permissions framework de Backstage evalúa cada acción sensible contra una policy en código.

1. Sacá la policy permisiva y agregá la tuya. Remové del backend:

   ```typescript
   // backend.add(import('@backstage/plugin-permission-backend-module-allow-all-policy'));
   ```

2. Escribí una policy custom como módulo de backend. En `packages/backend/src/plugins/permissionPolicy.ts`:

   ```typescript
   import { createBackendModule } from '@backstage/backend-plugin-api';
   import { policyExtensionPoint } from '@backstage/plugin-permission-node/alpha';
   import {
     PolicyDecision,
     AuthorizeResult,
   } from '@backstage/plugin-permission-common';
   import {
     PermissionPolicy,
     PolicyQuery,
     PolicyQueryUser,
   } from '@backstage/plugin-permission-node';
   import {
     catalogEntityDeletePermission,
   } from '@backstage/plugin-catalog-common/alpha';

   class PlataformaPolicy implements PermissionPolicy {
     async handle(
       request: PolicyQuery,
       user?: PolicyQueryUser,
     ): Promise<PolicyDecision> {
       // Borrar entidades del catálogo: sólo el grupo platform.
       if (request.permission.name === catalogEntityDeletePermission.name) {
         const groups = user?.info.ownershipEntityRefs ?? [];
         if (groups.includes('group:default/platform')) {
           return { result: AuthorizeResult.ALLOW };
         }
         return { result: AuthorizeResult.DENY };
       }
       // Todo lo demás: permitido a usuarios autenticados.
       return { result: AuthorizeResult.ALLOW };
     }
   }

   export const permissionPolicyModule = createBackendModule({
     pluginId: 'permission',
     moduleId: 'plataforma-policy',
     register(reg) {
       reg.registerInit({
         deps: { policy: policyExtensionPoint },
         async init({ policy }) {
           policy.setPolicy(new PlataformaPolicy());
         },
       });
     },
   });
   ```

3. Registrala:

   ```typescript
   backend.add(import('./plugins/permissionPolicy'));
   ```

4. Habilitá el enforcement (por default el permission framework está *deshabilitado* y todo pasa):

   ```yaml
   permission:
     enabled: true
   ```

5. Probá el comportamiento: autenticado como un usuario que NO está en `group:default/platform`, intentá **Unregister entity** sobre `payments-api` desde la UI. La acción debe fallar:

   ```
   Not allowed to perform this action
   ```

   El mismo request por API devuelve `403`:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     -X DELETE http://localhost:7007/api/catalog/entities/by-uid/<uid> \
     -H "Authorization: Bearer <token-de-usuario-no-platform>"
   ```

   ```
   403
   ```

**Preguntas de verificación 7**

- **7.a** La policy decide en base a `user.info.ownershipEntityRefs`. ¿De dónde sale esa lista y qué componente del Ejercicio 3 tuvo que estar bien modelado para que la pertenencia a `group:default/platform` sea confiable?
- **7.b** Backstage distingue entre autenticación (*authn*) y autorización (*authz*). ¿En cuál de las dos actúa este Permissions framework, y qué otro plugin cubre la otra mitad?
- **7.c** Existe un tipo de decisión intermedia entre `ALLOW` y `DENY`: las *conditional decisions* (`AuthorizeResult.CONDITIONAL`). ¿Qué problema de rendimiento/escala resuelven frente a evaluar `ALLOW/DENY` entidad por entidad? Pensá en filtrar una lista de 10.000 componentes.

---

## Ejercicio 8 — Discovery automático y medición de la adopción

Registrar entidades a mano no sobrevive a 300 repos. El *auto-discovery* rastrea una organización de GitHub y ingesta todo `catalog-info.yaml` que encuentre; luego medís qué tan sano está el catálogo.

1. Agregá el provider de discovery de GitHub al backend:

   ```bash
   yarn --cwd packages/backend add @backstage/plugin-catalog-backend-module-github
   ```

   ```typescript
   backend.add(import('@backstage/plugin-catalog-backend-module-github'));
   ```

2. Configurá el *entity provider* en `app-config.yaml` para barrer una org completa por schedule:

   ```yaml
   catalog:
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
   ```

3. Reiniciá y observá el log del provider poblando el catálogo sin intervención manual:

   ```
   {"level":"info","message":"Reading GitHub repositories from acme","plugin":"catalog"}
   {"level":"info","message":"Committing 42 entities (added=42, removed=0)","plugin":"catalog"}
   ```

4. Medí adopción con la API del catálogo. Por ejemplo, *cobertura de ownership* (componentes sin dueño real son deuda de plataforma) y *cobertura de docs*:

   ```bash
   # Componentes totales vs. con TechDocs
   TOTAL=$(curl -s "http://localhost:7007/api/catalog/entities?filter=kind=component" | jq 'length')
   DOCS=$(curl -s "http://localhost:7007/api/catalog/entities?filter=kind=component,metadata.annotations.backstage.io/techdocs-ref" | jq 'length')
   echo "Docs coverage: $DOCS / $TOTAL"
   ```

   ```
   Docs coverage: 31 / 42
   ```

5. Detectá entidades *orphan* (referidas pero nunca definidas — típico de un `owner` que apunta a un Group inexistente). Backstage las marca con la anotación `backstage.io/orphan: 'true'`:

   ```bash
   curl -s "http://localhost:7007/api/catalog/entities?filter=metadata.annotations.backstage.io/orphan=true" \
     | jq -r '.[].metadata.name'
   ```

**Preguntas de verificación 8**

- **8.a** El discovery corre con `schedule.frequency: { minutes: 30 }`. Explicá el modelo de *reconciliación* del catálogo: si borrás un `catalog-info.yaml` de un repo, ¿qué pasa con su entidad en el próximo ciclo, y por qué eso hace del catálogo un espejo del estado real y no un registro que sólo crece?
- **8.b** El auto-discovery encontró 42 entidades pero sólo 31 tienen docs. Como platform engineer, ¿por qué esta métrica es más accionable para impulsar adopción que "cantidad de usuarios logueados en el portal"?
- **8.c** ¿Cuál es el riesgo de dejar `repository: '.*'` (barrer *todo*) en una organización grande, en términos de rate limits de la API de GitHub y de ruido en el catálogo? ¿Cómo lo acotarías?

---

## Respuestas

<details>
<summary>Mostrar / ocultar respuestas</summary>

### Ejercicio 1

- **1.a** Backstage entrega *código fuente* (un monorepo) que la organización compila, extiende con plugins y despliega como imagen propia; no hay un binario "instalable" con features fijas. Implica que cada upgrade es un *bump* de dependencias sobre tu fork/monorepo (seguir los `@backstage/create-app` release notes y el `backstage-cli versions:bump`), con posibilidad de breaking changes en tus plugins custom. El upside es extensibilidad total; el costo es que la plataforma se hace dueña del ciclo de vida del portal, como de cualquier otro servicio interno.
- **1.b** `plugin-app-backend` **sirve el bundle estático del frontend** (el React ya compilado) desde el propio backend Node y le inyecta la configuración de runtime (`app-config` filtrada por visibilidad `frontend`). Así, en producción, un único proceso/imagen sirve API y UI, y el frontend recibe config sin recompilar.
- **1.c** La `allow-all-policy` hace que el Permissions framework devuelva `ALLOW` para *toda* acción, de cualquier usuario. Es el default para que el portal "funcione" recién scaffoldeado, pero en producción significa que cualquiera puede, por ejemplo, *unregister* entidades o ejecutar templates sin restricción. Hay que reemplazarla por una policy real (Ejercicio 7).

### Ejercicio 2

- **2.a** Debe existir una entidad `kind: Group` (o `User`) cuyo nombre resuelva a `team-payments`. Si no existe, Backstage crea/muestra una referencia *dangling*: la entidad aparece con owner pero el link no resuelve, y el `payments-api` puede quedar marcado como referenciando un target inexistente (relación a un target orphan). El ownership deja de ser confiable para RBAC y para "quién está de guardia".
- **2.b** `Location` es una entidad *meta*: apunta a una URL/archivo y le dice al catálogo "leé entidades de acá". `Component` es la entidad de negocio real. Al registrar una URL en la UI, Backstage crea primero el `Location` (el puntero, con su ingestión y refresco periódico); el `Component` se *deriva* de procesar el archivo que el Location referencia.
- **2.c** Catalog-as-Code: (1) el YAML se versiona y revisa junto al código, así el ownership/metadata evoluciona con el servicio y no se desincroniza; (2) el auto-discovery lo ingesta sin trabajo manual y lo *reconcilia* (si el repo cambia o desaparece, el catálogo se actualiza), evitando el "catálogo cementerio" de entidades cargadas a mano que nadie mantiene.
- **2.d** TechDocs (Ejercicio 5). La anotación `techdocs-ref` sólo declara *dónde* están las fuentes; sin el plugin de TechDocs habilitado y su `mkdocs.yml`, no se genera ni se sirve ninguna doc.

### Ejercicio 3

- **3.a** De la *relación recíproca* que el catálogo calcula automáticamente: al procesar `providesApis: [payments-rest]` en el Component, Backstage genera la arista `apiProvidedBy` en la API entity. El principio es que las relaciones se derivan de un solo lado declarado; no mantenés las dos puntas, lo que elimina la clase entera de bugs de inconsistencia bidireccional.
- **3.b** `Domain` agrupa Systems que comparten *terminología / área de negocio* (p. ej. "commerce"); es la capa más abstracta. `System` es una colección de recursos/componentes/APIs que se despliegan y operan juntos como una unidad funcional (el *boundary* de un producto). Un `Component` es `partOf` un System porque el System es su contenedor operativo directo; el Domain agrupa Systems, no Components, para mantener una jerarquía de exactamente un nivel de abstracción por capa.
- **3.c** `API` modela una *interfaz consumible* con contrato (OpenAPI/gRPC/GraphQL/AsyncAPI): algo que otros componentes *consumen* mediante `consumesApis`. `Resource` modela *infraestructura* que el System necesita para operar (bases de datos, buckets, colas, clusters): algo que se *provisiona/depende*, no que expone un contrato de API. Criterio: si tiene un contrato de interfaz que otro servicio invoca → `API`; si es infra sobre la que el servicio corre → `Resource`.
- **3.d** El `Location` sólo permite ingestar los kinds listados en `allow`. Si el archivo trajera un `Component` no permitido, ese `Component` sería **rechazado** con un policy error y no entraría al catálogo. Es una salvaguarda de gobierno: evita que un archivo "organizacional" (Domains, Groups, Users) inyecte por error componentes de servicio que deberían venir de sus propios repos vía discovery, manteniendo separadas las fuentes de verdad.

### Ejercicio 4

- **4.a** El `OwnerPicker` con `catalogFilter: { kind: Group }` consulta el propio catálogo y sólo ofrece Groups que *ya existen*. Así el servicio nace con un `owner` que resuelve a una entidad real (no un string libre tipeado a mano), y el ownership es válido desde el primer commit. Acopla scaffolder↔catalog: el golden path no puede producir un servicio huérfano.
- **4.b** `catalog:register` inserta el `catalog-info.yaml` del repo recién creado como un `Location`, de modo que el nuevo servicio aparece en el catálogo *inmediatamente*. Sin ese step, el repo existiría pero sería invisible en el portal hasta que alguien lo registrara a mano o hasta el próximo ciclo de discovery — rompiendo el círculo "crear → descubrible" que sostiene la adopción.
- **4.c** Porque `fetch:template` marca ese directorio como plantilla a interpolar *en tiempo de ejecución del step*, con el contexto `values`. Cuando el scaffolder *parsea el `template.yaml`*, sólo evalúa las expresiones del propio template (`${{ parameters.x }}`, `${{ steps.y.output }}`); los archivos del `skeleton/` se tratan como contenido opaco hasta que el step `fetch:template` los procesa, momento en que `${{ values.name }}` se resuelve. Son dos pasadas de nunjucks en dos momentos y contextos distintos.
- **4.d** `experimental` señala honestamente que el servicio es nuevo y no probado: no debería aparecer como dependencia "production" de nadie, ni disparar alertas/SLA como si fuera crítico. El promote a `production` es una decisión explícita y revisable. Fijar un default conservador evita que el catálogo se llene de servicios que *dicen* ser productivos sin serlo, preservando la señal del campo `lifecycle`.

### Ejercicio 5

- **5.a** Con `builder: 'local'`, el backend de Backstage *genera* las docs on-the-fly la primera vez que alguien las pide (corre MkDocs en el proceso del backend): consume CPU/memoria y agrega latencia, y no escala a cientos de servicios. Con `builder: 'external'`, la generación ocurre en el CI de cada servicio y Backstage sólo *sirve* HTML ya compilado desde object storage: el backend se vuelve un lector de storage barato y horizontalmente escalable. Con 500 servicios, `local` colapsaría el portal; `external` lo mantiene liviano.
- **5.b** TechDocs depende del catálogo: cada sitio de docs está *indexado por el entity ref* de un Component (u otra entidad). No puede existir una página de TechDocs "suelta" sin una entidad asociada — la ruta de docs en el portal es `/docs/<namespace>/<kind>/<name>`, derivada del catálogo. La entidad es la clave primaria.
- **5.c** Porque el publisher escribe (y el reader luego busca) las docs en una ruta *namespaced por el entity ref* dentro del bucket (p. ej. `default/component/payments-api/`). El nombre del bucket sólo dice *dónde* está el storage; el entity ref dice *bajo qué clave* guardar/leer, para que el backend, dado un Component, sepa exactamente qué prefijo servir. Sin él, no habría forma de mapear entidad → HTML.

### Ejercicio 6

- **6.a** Al agrupar por el label `backstage.io/kubernetes-id` en vez de por nombre de objeto, un mismo Component puede reunir recursos heterogéneos y con nombres arbitrarios: p. ej. un servicio cuyo Deployment se llama `payments-api-blue`, su HPA `pay-scaler` y su Service `pay-svc` — todos con el label `backstage.io/kubernetes-id: payments-api` aparecen juntos bajo el Component. Desacopla la *identidad lógica en el portal* de los nombres físicos en el cluster (útil con blue/green, canary, o naming heredado).
- **6.b** El portal sólo necesita *observar* estado para mostrarlo; darle `get/list/watch` y nada más respeta el menor privilegio. Si las credenciales del backend se filtraran, el atacante podría leer metadata de workloads pero **no modificar ni borrar** nada en el cluster. Otorgar `create/update/delete` convertiría un portal comprometido en un vector de escalada directo sobre producción.
- **6.c** En el lab, el cluster es efímero y sin datos reales, así que saltarse TLS y usar un token largo simplifica. En producción, `skipTLSVerify: true` habilita MITM contra el API server, y un token de 1 año es una credencial de larga vida difícil de rotar y de gran impacto si se filtra. En su lugar: verificar TLS con el CA real (`caData`), y usar autenticación federada de corta duración — `authProvider: 'oidc'`, o los providers `aws`/`gke`/`azure` que emiten tokens efímeros por request en vez de un secreto estático.

### Ejercicio 7

- **7.a** `ownershipEntityRefs` la construye el sistema de identidad de Backstage al resolver el usuario contra el catálogo: incluye su `User` entity más todos los `Group` de los que es miembro (transitivamente, siguiendo `memberOf`/`children`). Depende de que los `Group`/`User` del Ejercicio 3 estén bien modelados: si `team-payments`/`platform` y sus membresías no existen o están mal, la policy decide sobre datos falsos. El grafo organizacional del catálogo es el sustrato de la autorización.
- **7.b** Actúa en **autorización (authz)**: decide si un usuario *ya autenticado* puede realizar una acción. La *autenticación (authn)* — quién es el usuario — la cubren los `auth` providers (`plugin-auth-backend` + un módulo como GitHub/OIDC/guest). Authn establece la identidad; el Permissions framework decide qué puede hacer esa identidad.
- **7.c** Una *conditional decision* devuelve, en vez de un veredicto por entidad, un *filtro* que el plugin dueño del recurso aplica en su propia capa de datos (p. ej. el catálogo traduce la condición a un filtro de query). Para listar 10.000 componentes, evaluar `ALLOW/DENY` uno por uno obligaría a materializar y verificar los 10.000 en memoria; con `CONDITIONAL`, la restricción (p. ej. "sólo los que soy owner") se empuja al backend de datos, que devuelve directamente el subconjunto autorizado. Resuelve el problema de rendimiento/escala de la autorización sobre colecciones grandes.

### Ejercicio 8

- **8.a** El entity provider trata el resultado de cada barrido como el *estado deseado* de las entidades que administra: hace un *diff* contra lo que tiene y aplica `added`/`removed`. Si borrás un `catalog-info.yaml`, en el próximo ciclo el provider ya no lo encuentra y **remueve** su entidad del catálogo. Por eso el catálogo es un espejo reconciliado del estado real de los repos, no un log append-only que sólo crece y acumula fantasmas.
- **8.b** Porque *docs coverage* (31/42) es una métrica de **calidad/completitud del catálogo** directamente accionable: identifica los 11 servicios sin documentar y te da una lista de trabajo concreta para mover la aguja de adopción. "Usuarios logueados" es una *vanity metric*: mide tráfico, no valor entregado ni salud de la plataforma; podés tener muchos logins y un catálogo inútil. La adopción real se mide por cobertura de ownership, docs, golden-path usage, no por presencia.
- **8.c** Barrer `.*` en una org grande genera muchísimas llamadas a la API de GitHub por ciclo (búsqueda + lectura por repo), acercándote a los *rate limits* (5.000 req/h por token), y arrastra al catálogo repos irrelevantes (forks, archivados, experimentos) como ruido u orphans. Se acota afinando `filters` (por topic, por prefijo/patrón de nombre, excluyendo `archived`), espaciando `schedule.frequency`, o usando un GitHub App con mayor cuota y *installation tokens* en vez de un PAT personal.

</details>