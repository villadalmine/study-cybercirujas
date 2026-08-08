# Ejercicios guiados — Tema 5.1: Simplified Access to Platform Capabilities for Developers

> **Contexto del tema.** El objetivo de una plataforma interna (IDP, *Internal Developer Platform*) no es darle a cada developer acceso crudo a Kubernetes, sino **exponer capacidades de plataforma detrás de interfaces simples y con opinión** (*paved roads* / *golden paths*): APIs declarativas, catálogos de servicios, portales y especificaciones de workload agnósticas. La medida de éxito es la reducción de la **carga cognitiva** del developer sin sacrificar la gobernanza del equipo de plataforma. Estos ejercicios recorren la escalera completa: la API como interfaz (Kubernetes Resource Model), la abstracción de infraestructura (Crossplane), la especificación de intención portable (Score) y el punto de entrada self-service (Backstage).
>
> **Requisitos previos.** `docker`, `kind` (o `minikube`), `kubectl` ≥ 1.28, `helm` ≥ 3.12 y conexión a internet. Todos los labs son locales y no requieren credenciales de cloud.

---

## Ejercicio 1 — El Kubernetes Resource Model (KRM) como interfaz de plataforma

**Objetivo:** entender por qué "acceso simplificado" empieza por modelar cada capability como una **API declarativa uniforme**, y por qué un CRD sin controller es una interfaz vacía.

### Pasos

1. Creá un cluster local dedicado:

   ```bash
   kind create cluster --name idp-lab
   ```

   Salida esperada (abreviada):

   ```
   Creating cluster "idp-lab" ...
    ✓ Ensuring node image (kindest/node:v1.31.2) 🖼
    ✓ Preparing nodes 📦
    ✓ Starting control-plane 🕹️
   Set kubectl context to "kind-idp-lab"
   ```

2. Mirá **cuántas capabilities** expone la API por defecto y su forma:

   ```bash
   kubectl api-resources --output=name | wc -l
   kubectl api-resources | head -n 8
   ```

   Salida típica:

   ```
   62
   NAME                    SHORTNAMES   APIVERSION    NAMESPACED   KIND
   bindings                             v1            true         Binding
   componentstatuses       cs           v1            false        ComponentStatus
   configmaps              cm           v1            true         ConfigMap
   endpoints               ep           v1            true         Endpoints
   events                  ev           v1            true         Event
   namespaces             ns           v1            false        Namespace
   nodes                  no           v1            false        Node
   persistentvolumeclaims  pvc          v1            true         PersistentVolumeClaim
   ```

3. Comprobá que la API es **auto-documentada** (clave para el self-service: el developer descubre el contrato sin leer un wiki):

   ```bash
   kubectl explain pod.spec.containers.resources --recursive
   ```

4. Ahora **agregá una capability nueva** a la interfaz de la plataforma con un `CustomResourceDefinition`. Guardalo como `xrd-toy.yaml`:

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: databases.platform.example.com
   spec:
     group: platform.example.com
     scope: Namespaced
     names:
       plural: databases
       singular: database
       kind: Database
       shortNames: ["db"]
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
                   engine:
                     type: string
                     enum: ["postgres", "mysql"]
                   sizeGB:
                     type: integer
                     minimum: 1
                 required: ["engine"]
   ```

   ```bash
   kubectl apply -f xrd-toy.yaml
   kubectl api-resources | grep platform.example.com
   kubectl explain database.spec
   ```

   La nueva capability aparece indistinguible de las nativas:

   ```
   databases   db   platform.example.com/v1alpha1   true   Database
   ```

5. Un developer "consume" la capability con **el mismo workflow de siempre** (`kubectl apply` / GitOps), sin conocer la implementación. Guardá `db-claim.yaml`:

   ```yaml
   apiVersion: platform.example.com/v1alpha1
   kind: Database
   metadata:
     name: orders-db
   spec:
     engine: postgres
     sizeGB: 20
   ```

   ```bash
   kubectl apply -f db-claim.yaml
   kubectl get database orders-db -o yaml | grep -A3 spec:
   ```

6. Verificá qué pasó realmente en el cluster:

   ```bash
   kubectl get pods,statefulsets -A | grep -i orders
   ```

   Salida:

   ```
   (sin resultados)
   ```

> **Preguntas de comprensión — Bloque 1**
> 1. En el paso 4, ¿por qué el `openAPIV3Schema` con `enum` y `minimum` es parte del "acceso simplificado" y no solo una validación técnica?
> 2. En el paso 6 no se creó ninguna base de datos real. ¿Qué le falta a un CRD para convertirse en una capability funcional, y cómo se llama ese patrón?
> 3. Enunciá dos propiedades del KRM (frente a, por ejemplo, un endpoint REST ad-hoc por capability) que lo hacen una buena base para una interfaz de plataforma unificada.

---

## Ejercicio 2 — Crossplane: exponer una capability con Composition + Claim

**Objetivo:** cerrar el hueco del Ejercicio 1. El equipo de plataforma define **qué se aprovisiona** (Composition) y **qué contrato ve el developer** (XRD/Claim); el developer pide "un entorno de app" con un manifiesto mínimo y la plataforma materializa múltiples recursos reales.

### Pasos

1. Instalá Crossplane:

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace --wait
   kubectl get pods -n crossplane-system
   ```

   Esperá `crossplane` y `crossplane-rbac-manager` en `Running`.

2. Instalá el provider que materializa recursos **dentro** del cluster (sin credenciales de cloud) y la function de composición. Guardá `providers.yaml`:

   ```yaml
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-kubernetes
   spec:
     package: xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.16.0
   ---
   apiVersion: pkg.crossplane.io/v1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.8.2
   ```

   ```bash
   kubectl apply -f providers.yaml
   kubectl get providers,functions
   ```

   Esperá `INSTALLED=True` y `HEALTHY=True` en ambos.

3. **Gotcha crítico de diagnóstico** (causa #1 de Claims que quedan colgados): el `ServiceAccount` de `provider-kubernetes` necesita RBAC para crear objetos, y un `ProviderConfig` con identidad inyectada. Guardá `provider-config.yaml`:

   ```yaml
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   ```

   ```bash
   # Otorga permisos al SA del provider (en un lab; en prod, RBAC de mínimo privilegio)
   SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | head -1)
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole cluster-admin \
     --serviceaccount="crossplane-system:$(basename $SA)"
   kubectl apply -f provider-config.yaml
   ```

4. El equipo de plataforma define el **contrato del developer** (XRD). Guardá `xrd.yaml`:

   ```yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xappenvironments.platform.example.com
   spec:
     group: platform.example.com
     names:
       kind: XAppEnvironment
       plural: xappenvironments
     claimNames:
       kind: AppEnvironment
       plural: appenvironments
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
                   team:
                     type: string
                   size:
                     type: string
                     enum: ["small", "large"]
                     default: "small"
                 required: ["team"]
   ```

5. El equipo de plataforma define **cómo se materializa** (Composition, modo Pipeline con function). Guardá `composition.yaml`:

   ```yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: appenvironment-incluster
   spec:
     compositeTypeRef:
       apiVersion: platform.example.com/v1alpha1
       kind: XAppEnvironment
     mode: Pipeline
     pipeline:
       - step: patch-and-transform
         functionRef:
           name: function-patch-and-transform
         input:
           apiVersion: pt.fn.crossplane.io/v1beta1
           kind: Resources
           resources:
             - name: team-namespace
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha2
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: Namespace
                       metadata:
                         name: placeholder
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.team
                   toFieldPath: spec.forProvider.manifest.metadata.name
             - name: quota-config
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha2
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: ConfigMap
                       metadata:
                         namespace: crossplane-system
                         name: placeholder
                       data:
                         tier: small
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: metadata.name
                   toFieldPath: spec.forProvider.manifest.metadata.name
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.size
                   toFieldPath: spec.forProvider.manifest.data.tier
   ```

   ```bash
   kubectl apply -f xrd.yaml
   # Esperá a que el XRD esté establecido antes de aplicar la Composition:
   kubectl wait --for=condition=Established xrd/xappenvironments.platform.example.com --timeout=60s
   kubectl apply -f composition.yaml
   ```

6. **El developer** —sin saber nada de providers, functions ni namespaces— pide su entorno. Guardá `claim.yaml`:

   ```yaml
   apiVersion: platform.example.com/v1alpha1
   kind: AppEnvironment
   metadata:
     name: payments
     namespace: default
   spec:
     team: payments
     size: large
   ```

   ```bash
   kubectl apply -f claim.yaml
   ```

7. Observá cómo un Claim de 8 líneas se expande en el árbol de recursos reales:

   ```bash
   kubectl get appenvironment payments
   kubectl get namespace payments
   kubectl get configmap -n crossplane-system | grep payments
   ```

   Diagnóstico de la cadena Claim → Composite → Managed:

   ```bash
   kubectl get appenvironment payments -o jsonpath='{.status.conditions}' | jq
   kubectl get object   # los Managed Resources creados
   ```

   Cuando todo está sano verás `SYNCED=True READY=True`.

> **Preguntas de comprensión — Bloque 2**
> 1. Separamos **XRD** (`AppEnvironment` con solo `team` y `size`) de **Composition** (Namespace + ConfigMap con `provider-kubernetes`). ¿Qué principio de plataforma habilita esa separación y qué gana el equipo de plataforma al poder cambiar la Composition sin tocar el Claim?
> 2. En el paso 3 forzamos `cluster-admin` para el provider. Un Claim queda en `SYNCED=False`. ¿Qué comando usarías primero para ver la causa raíz y por qué el RBAC es el sospechoso habitual?
> 3. ¿Cuál es la diferencia funcional entre el `Database` CRD del Ejercicio 1 y este `AppEnvironment`? Conectalo con la respuesta a la pregunta 1.2.

---

## Ejercicio 3 — Score: intención de workload portable entre plataformas

**Objetivo:** ver la interfaz self-service **desde el lado del developer**: una única especificación (`score.yaml`) que declara la *intención* del workload y sus dependencias de forma agnóstica, y que la plataforma traduce a manifiestos concretos (Kubernetes, Docker Compose). Score es un proyecto de la CNCF (Sandbox).

### Pasos

1. Instalá `score-compose` y `score-k8s` (binarios independientes):

   ```bash
   # Ejemplo con los releases de GitHub (ajustá la versión al último release):
   curl -fsSL https://github.com/score-spec/score-k8s/releases/latest/download/score-k8s_linux_amd64.tar.gz | tar xz
   sudo mv score-k8s /usr/local/bin/
   score-k8s --version
   ```

2. Escribí **una sola** especificación de intención. Guardá `score.yaml`:

   ```yaml
   apiVersion: score.dev/v1b1
   metadata:
     name: hello-api
   containers:
     main:
       image: ghcr.io/score-spec/sample-app:sha-7076631
       variables:
         DB_HOST: "${resources.db.host}"
         DB_PORT: "${resources.db.port}"
         DB_NAME: "${resources.db.name}"
         DB_USER: "${resources.db.username}"
         DB_PASSWORD: "${resources.db.password}"
       resources:
         requests: { cpu: "100m", memory: "128Mi" }
         limits:   { cpu: "500m", memory: "256Mi" }
   service:
     ports:
       www:
         port: 8080
         targetPort: 8080
   resources:
     db:
       type: postgres
   ```

3. Generá los manifiestos de **Kubernetes** a partir de la intención:

   ```bash
   score-k8s init
   score-k8s generate score.yaml --output manifests.yaml
   ```

4. Inspeccioná qué produjo la plataforma. Fijate que el developer **nunca escribió** un `Deployment`, un `Service`, un `Secret` ni un `StatefulSet` de Postgres:

   ```bash
   grep -E '^kind:' manifests.yaml | sort | uniq -c
   ```

   Salida típica:

   ```
      1 ConfigMap
      1 Deployment
      1 Secret
      1 Service
      1 StatefulSet
   ```

5. Verificá cómo se **resolvieron los placeholders** `${resources.db.*}` a datos reales del recurso aprovisionado:

   ```bash
   grep -A6 'name: DB_HOST' manifests.yaml
   ```

   Deberías ver que `DB_HOST` apunta al Service del Postgres que la plataforma decidió crear, y las credenciales referencian un `Secret`.

6. La **misma** intención, **otra** plataforma (portabilidad — el argumento central de Score):

   ```bash
   curl -fsSL https://github.com/score-spec/score-compose/releases/latest/download/score-compose_linux_amd64.tar.gz | tar xz
   sudo mv score-compose /usr/local/bin/
   score-compose init
   score-compose generate score.yaml
   docker compose up -d
   docker compose ps
   ```

   El mismo `score.yaml` levantó el stack en Docker Compose sin un solo cambio.

> **Preguntas de comprensión — Bloque 3**
> 1. Distinguí los dos usos de la palabra `resources` en `score.yaml` (dentro de `containers.main` vs. a nivel raíz). ¿Cuál expresa *intención del developer* y cuál *acoplamiento a la plataforma*?
> 2. El developer escribió `db: { type: postgres }`, no un `StatefulSet`. ¿Qué es un **provisioner/resource type** en Score y por qué esa indirección es lo que hace portable la especificación?
> 3. Compará Score con el Claim de Crossplane del Ejercicio 2: ambos "esconden" la implementación. ¿En qué **capa** actúa cada uno y por qué son complementarios y no rivales?

---

## Ejercicio 4 — Backstage: golden paths con Software Templates y Catalog

**Objetivo:** el punto de entrada humano al self-service. Backstage (CNCF, Incubating) combina un **Software Catalog** (inventario de todo lo que existe y quién lo posee) con el **Scaffolder** (formularios que generan y registran servicios). Un golden path se vuelve un botón.

### Pasos

1. Generá una app de Backstage (Node.js ≥ 20 y Yarn requeridos):

   ```bash
   npx @backstage/create-app@latest --path backstage-lab
   cd backstage-lab
   yarn dev   # abre http://localhost:3000
   ```

2. Entendé la unidad del catálogo. Todo componente se describe con un `catalog-info.yaml`. Guardalo como referencia:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: hello-api
     description: Sample API service
     annotations:
       backstage.io/techdocs-ref: dir:.
       github.com/project-slug: myorg/hello-api
     tags: ["nodejs"]
   spec:
     type: service
     lifecycle: production
     owner: platform-team
     system: payments
   ```

3. Definí un **golden path** como un `Template` del Scaffolder. Guardá `template.yaml`:

   ```yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: nodejs-microservice
     title: Node.js Microservice (Golden Path)
     description: Servicio Node.js con CI, Dockerfile y registro en catálogo
     tags: ["recommended", "nodejs"]
   spec:
     owner: platform-team
     type: service
     parameters:
       - title: Detalles del servicio
         required: ["name", "owner"]
         properties:
           name:
             title: Name
             type: string
             pattern: '^[a-z0-9-]+$'
           owner:
             title: Owner
             type: string
             ui:field: OwnerPicker
             ui:options:
               catalogFilter: { kind: Group }
       - title: Ubicación del repositorio
         required: ["repoUrl"]
         properties:
           repoUrl:
             title: Repository Location
             type: string
             ui:field: RepoUrlPicker
             ui:options:
               allowedHosts: ["github.com"]
     steps:
       - id: fetch
         name: Render del skeleton
         action: fetch:template
         input:
           url: ./skeleton
           values:
             name: ${{ parameters.name }}
             owner: ${{ parameters.owner }}
       - id: publish
         name: Publicar en GitHub
         action: publish:github
         input:
           repoUrl: ${{ parameters.repoUrl }}
           defaultBranch: main
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

4. Registrá el template para que aparezca en *Create...*. En `app-config.yaml`, dentro de `catalog.locations`, agregá:

   ```yaml
   catalog:
     locations:
       - type: url
         target: https://github.com/myorg/software-templates/blob/main/template.yaml
         rules:
           - allow: [Template]
   ```

5. En la UI (`Create...`) elegí el template, completá el formulario y ejecutá. Observá los tres efectos del golden path:
   - se **materializa** un repo con estructura estándar (skeleton renderizado con las `values`),
   - se **registra** automáticamente en el catálogo (`catalog:register`),
   - queda **atribuido** a un `owner` (gobernanza y ownership desde el minuto cero).

> **Preguntas de comprensión — Bloque 4**
> 1. Un `Template` tiene dos secciones bien distintas: `parameters` y `steps`. ¿Qué reduce cada una respecto de la experiencia de "creá el repo a mano"?
> 2. El paso `catalog:register` es lo que evita el "catálogo fantasma". Explicá por qué acoplar *scaffolding* y *registro* es un principio de golden path y no un detalle de implementación.
> 3. El campo `owner` es obligatorio en `parameters` y en `catalog-info.yaml`. ¿Por qué el ownership es un requisito de *acceso simplificado* y no una carga burocrática? Relacionalo con la escalabilidad del equipo de plataforma.

---

## Fuentes oficiales

- CNCF Platforms White Paper — TAG App Delivery: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- Kubernetes — Custom Resources / API extension: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — API concepts: https://kubernetes.io/docs/reference/using-api/api-concepts/
- Crossplane — Compositions, XRDs y Claims: https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane — provider-kubernetes: https://github.com/crossplane-contrib/provider-kubernetes
- Score — especificación y CLIs: https://docs.score.dev/
- Backstage — Software Catalog: https://backstage.io/docs/features/software-catalog/
- Backstage — Software Templates (Scaffolder): https://backstage.io/docs/features/software-templates/

---

<details>
<summary><strong>Respuestas — verificación de comprensión</strong></summary>

### Bloque 1 — KRM como interfaz

1. **El schema *es* la interfaz.** El `enum`/`minimum` convierte el contrato en algo descubrible (`kubectl explain`) y auto-validado: el developer recibe rechazo inmediato de `apply` ante un valor inválido, sin necesidad de documentación externa ni de un revisor humano. Esto es *shift-left* de la validación y es parte de la simplificación, no un extra: reduce el ciclo de feedback y elimina una clase entera de tickets al equipo de plataforma.
2. Le falta un **controller/operator** que *reconcilie* el estado deseado del CR con el mundo real (el patrón **operator / controller loop**: *watch → diff → act*). Un CRD por sí solo agrega una entrada a la API y persiste el objeto en etcd, pero **no ejecuta ninguna acción**. Por eso el Ejercicio 2 introduce Crossplane, que aporta el motor de reconciliación que le faltaba a este CRD "de juguete".
3. Dos de: (a) **uniformidad** — todas las capabilities (nativas y extendidas) comparten el mismo verbo/CLI/RBAC/audit-log/GitOps, por lo que aprender una es aprenderlas todas; (b) **declaratividad + reconciliación continua** — el developer describe el *qué*, no el *cómo*, y el sistema converge y se auto-repara; (c) **auto-documentación** vía OpenAPI (`kubectl explain`); (d) **modelo de seguridad unificado** (RBAC/admission) en lugar de auth ad-hoc por servicio.

### Bloque 2 — Crossplane

1. Es la **separación de intereses entre developer y equipo de plataforma** (o *separation of concerns* / *encapsulation*). El XRD es el contrato estable y estrecho; la Composition es la implementación oculta. Al cambiar la Composition (p. ej. pasar de `provider-kubernetes` a un provider de cloud real, agregar un `NetworkPolicy` o cambiar límites por *tier*) **sin tocar el Claim**, el equipo de plataforma puede evolucionar, endurecer o migrar la infraestructura de forma transparente para todos los developers: gobernanza centralizada sin coordinación por equipo.
2. Primero `kubectl describe` sobre el Managed Resource o el Composite: `kubectl get object` y luego `kubectl describe object <nombre>` (o `kubectl describe appenvironment payments`), mirando `status.conditions` y los `Events`. El RBAC es el sospechoso habitual porque `provider-kubernetes` actúa con su **propio ServiceAccount**; si ese SA no tiene permiso para crear el recurso objetivo, el Managed Resource queda `SYNCED=False` con un error `forbidden` / `cannot create resource`, aunque el XRD y la Composition sean correctos.
3. El `Database` del Ejercicio 1 es una API **inerte**: valida y persiste, pero nadie actúa sobre él. El `AppEnvironment` es una API **respaldada por un motor de reconciliación** (Crossplane) que la Composition conecta a recursos reales. Es exactamente el "controller faltante" de la respuesta 1.2, y esa reconciliación es lo que habilita la separación de la respuesta 2.1.

### Bloque 3 — Score

1. `containers.main.resources` (CPU/memoria) es **intención del developer** sobre su propio código: cuánto consume, independiente de la plataforma. El `resources` de nivel raíz (p. ej. `db`) declara **dependencias externas** cuya provisión pertenece a la plataforma; el `type: postgres` es un punto de acoplamiento *resuelto por la plataforma*, no por el developer. La misma palabra, dos capas distintas.
2. Un **resource type / provisioner** es la regla que la plataforma registra para saber cómo materializar un `type` dado (`postgres` → un StatefulSet en `score-k8s`, un contenedor en `score-compose`, o un RDS gestionado en producción). La indirección hace portable la especificación porque el `score.yaml` referencia una *abstracción* (`type: postgres`) y no una implementación: cada plataforma sustituye su propio provisioner sin que el developer cambie una línea.
3. Actúan en **capas distintas**. Score es la interfaz **del developer** (la *intención* del workload, previa a cualquier cluster; portable entre entornos). Crossplane es la interfaz **del control plane** (aprovisionamiento e infraestructura real dentro de Kubernetes). Son complementarios: un `score.yaml` puede *generar* un Claim de Crossplane como uno de sus outputs — el provisioner de Score delega el aprovisionamiento en Crossplane. No compiten; se apilan.

### Bloque 4 — Backstage

1. `parameters` reduce la **carga cognitiva de decisión**: en vez de recordar convenciones, hosts permitidos y formatos, el developer completa un formulario validado (`pattern`, pickers). `steps` reduce la **carga de ejecución**: automatiza el render del skeleton, la creación del repo y el registro, eliminando pasos manuales y errores de copiar-pegar. Juntos convierten un runbook de varios pasos propenso a error en una acción reproducible.
2. Porque un golden path que crea un servicio pero **no lo registra** produce *drift* inmediato: el catálogo deja de reflejar la realidad, se pierde la visibilidad de ownership/dependencias y el valor del catálogo se degrada con cada uso. Acoplar *scaffolding* + *registro* garantiza el invariante "todo lo que existe está en el catálogo", que es la premisa sobre la que se apoyan búsqueda, TechDocs, scorecards y auditoría. Es un principio, no un detalle, porque protege esa propiedad del sistema completo.
3. El ownership obligatorio es lo que permite que el self-service **escale sin que el equipo de plataforma se vuelva un cuello de botella**: cada servicio tiene un dueño claro para on-call, aprobaciones, deprecaciones y notificaciones de seguridad, de modo que la plataforma no tiene que rastrear "de quién es esto" ante cada incidente. Sin ownership el self-service genera un pasivo (servicios huérfanos) que colapsa sobre la plataforma; capturarlo en el momento de creación (barato, un campo del formulario) evita un costo enorme más tarde. Por eso es habilitador del acceso simplificado, no burocracia.

</details>