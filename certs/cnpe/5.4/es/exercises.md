# Ejercicios guiados — Tema 5.4: Using Automation Frameworks for Self-Service Provisioning

> **Objetivo.** Construir, consumir y diagnosticar plataformas de *self-service provisioning* con los frameworks de automatización que la industria usa hoy: **Crossplane** (control planes y abstracciones), **Backstage** (golden paths con el Scaffolder), **Kratix** (la plataforma como producto vía *Promises*) y **Argo CD ApplicationSets** (self-service declarativo por GitOps). Al terminar vas a entender la mecánica interna que separa un *self-service portal* de un simple `kubectl apply`: el contrato de API, la reconciliación asíncrona, la separación de responsabilidades platform/app y los patrones de diagnóstico.
>
> **Prerrequisitos.**
> - Un cluster local descartable. Usaremos **kind** (`kind v0.23+`) sobre Docker/Podman.
> - `kubectl v1.29+`, `helm v3.14+`, y el CLI de Crossplane (`crossplane`).
> - Acceso saliente a `xpkg.upbound.io` y `charts.crossplane.io`.
> - Todos los comandos asumen `bash`. Cada bloque es idempotente salvo aviso.
>
> **Modelo mental (léelo antes de empezar).** El self-service provisioning tiene **dos personas**: el *platform engineer*, que **publica una API** (una abstracción con opciones limitadas y opinadas), y el *application developer*, que **consume esa API** sin ver la implementación. Los ejercicios están divididos por esa frontera: primero te ponés el sombrero de plataforma y publicás; después el de developer y consumís. Esa separación es el corazón del tema.

---

## Ejercicio 1 — Publicar una abstracción de self-service con Crossplane (XRD → Composition → Claim)

Vamos a exponer una API `PostgreSQLInstance` que el developer pide con tres parámetros, y que por debajo materializa recursos reales de Kubernetes. Usamos `provider-kubernetes` para que corra en cualquier cluster sin credenciales de nube.

### Bloque 1.1 — Levantar el cluster e instalar Crossplane

**Paso 1.** Creá el cluster:

```bash
kind create cluster --name selfservice --image kindest/node:v1.30.0
kubectl config use-context kind-selfservice
```

Salida esperada (fin):

```
Set kubectl context to "kind-selfservice"
```

**Paso 2.** Instalá el control plane de Crossplane con Helm:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --wait
```

Salida esperada (fin):

```
NAME: crossplane
STATUS: deployed
```

**Paso 3.** Verificá que el core arrancó:

```bash
kubectl -n crossplane-system get deploy
```

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
crossplane                 1/1     1            1           40s
crossplane-rbac-manager    1/1     1            1           40s
```

> ❓ **Preguntas del bloque 1.1**
> **Q1.** Crossplane extiende la Kubernetes API server con sus propios recursos en vez de correr un servidor aparte. ¿Qué mecanismo de Kubernetes usa para eso y qué ventaja operativa concreta te da para el self-service (pensá en RBAC, auditoría y `kubectl`)?
> **Q2.** ¿Por qué el patrón de Crossplane es *asíncrono* (reconciliación continua) y no *request/response* como un `POST` a una API REST tradicional? ¿Qué implica eso para lo que ve el developer justo después de crear su recurso?

### Bloque 1.2 — Instalar el Provider y la Function (la implementación)

**Paso 4.** Instalá `provider-kubernetes` (para crear objetos K8s) y `function-patch-and-transform` (el motor de composición moderno, basado en pipeline):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
EOF
```

**Paso 5.** Esperá a que ambos queden `HEALTHY=True` e `INSTALLED=True`:

```bash
kubectl get providers,functions
```

```
NAME                                                     INSTALLED   HEALTHY   PACKAGE                                                              AGE
provider.pkg.crossplane.io/provider-kubernetes           True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1       60s

NAME                                                          INSTALLED   HEALTHY   PACKAGE                                                                        AGE
function.pkg.crossplane.io/function-patch-and-transform       True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0        60s
```

**Paso 6.** `provider-kubernetes` corre con su propia ServiceAccount y **sin permisos por defecto** — este es el gotcha #1 de producción. Dale los permisos que necesita para crear objetos en el cluster (en producción se acota con un `ClusterRole` mínimo, acá usamos `cluster-admin` para el laboratorio):

```bash
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed 's|serviceaccount/||')
kubectl create clusterrolebinding provider-kubernetes-admin \
  --clusterrole cluster-admin \
  --serviceaccount="crossplane-system:${SA}"
```

**Paso 7.** Configurá el `ProviderConfig` para que el provider use su identidad *in-cluster*:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
EOF
```

> ❓ **Preguntas del bloque 1.2**
> **Q3.** ¿Cuál es la diferencia de rol entre un **Provider** y una **Function** en Crossplane moderno? ¿Por qué la composición dejó de ser "patch & transform nativo" en el `Composition` y pasó a un *pipeline* de functions?
> **Q4.** En el Paso 6 tuviste que crear un `ClusterRoleBinding` manual. Explicá por qué el provider no viene con esos permisos y qué riesgo de seguridad estarías introduciendo si en producción le das `cluster-admin` en vez de un rol acotado.

### Bloque 1.3 — Definir la API (XRD) y su implementación (Composition)

**Paso 8.** Publicá el **CompositeResourceDefinition (XRD)** — este *es* el contrato de self-service. Fijate que expone solo `storageGB` y `region`, y `claimNames` habilita que el developer lo pida de forma *namespaced*:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.example.org
spec:
  group: database.example.org
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: xpostgresqlinstances.database.example.org
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
                      minimum: 5
                      maximum: 100
                    region:
                      type: string
                      enum: ["us-east", "eu-west", "sa-east"]
                  required:
                    - storageGB
                    - region
              required:
                - parameters
EOF
```

**Paso 9.** Publicá la **Composition** (la implementación oculta). Traduce los parámetros del developer en un `ConfigMap` real (aquí como stand-in de un recurso provisionado):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.database.example.org
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
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
          - name: db-config
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
                      namespace: default
                      name: placeholder
                    data:
                      storageGB: "0"
                      region: "unset"
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.storageGB
                toFieldPath: spec.forProvider.manifest.data.storageGB
                transforms:
                  - type: convert
                    convert:
                      toType: string
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.manifest.data.region
EOF
```

**Paso 10.** Confirmá que la nueva API existe en el cluster:

```bash
kubectl api-resources | grep database.example.org
```

```
postgresqlinstances    database.example.org/v1alpha1   true    PostgreSQLInstance
xpostgresqlinstances   database.example.org/v1alpha1   false   XPostgreSQLInstance
```

> ❓ **Preguntas del bloque 1.3**
> **Q5.** El XRD del Paso 8 usa `minimum/maximum` en `storageGB` y `enum` en `region`. ¿Por qué validar en el *schema* de la API es superior a validar dentro de la Composition o en un pipeline de CI? ¿Qué principio de plataforma-como-producto encarna eso?
> **Q6.** ¿Qué diferencia hay entre el **Composite Resource (XR)** — cluster-scoped, prefijo `X` — y el **Claim** — namespaced, sin prefijo? ¿Por qué el developer usa el Claim y no el XR directamente?

### Bloque 1.4 — Consumir la API como developer

**Paso 11.** Cambiate de sombrero: sos un developer. Pedís una base de datos con un manifiesto mínimo (no ves nada de la implementación):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: default
spec:
  parameters:
    storageGB: 20
    region: us-east
EOF
```

**Paso 12.** Observá la reconciliación. Al principio `SYNCED=True` pero `READY=False`, hasta que el recurso compuesto queda listo:

```bash
kubectl get postgresqlinstance orders-db -w
```

```
NAME        SYNCED   READY   CONNECTION-SECRET   AGE
orders-db   True     False                       3s
orders-db   True     True                        12s
```

**Paso 13.** Verificá que la abstracción produjo un recurso real:

```bash
kubectl get configmap orders-db-xxxxx -o jsonpath='{.data}' ; echo
```

> Tip: obtené el nombre exacto con `kubectl get object` (el XR generó un `ConfigMap` cuyo nombre = nombre del XR).

```json
{"region":"us-east","storageGB":"20"}
```

**Paso 14.** Inspeccioná el árbol de composición completo con el CLI — esta es la herramienta de diagnóstico clave:

```bash
crossplane beta trace postgresqlinstance.database.example.org/orders-db -n default
```

```
NAME                                          SYNCED   READY   STATUS
PostgreSQLInstance/orders-db (default)        True     True    Available
└─ XPostgreSQLInstance/orders-db-abcde        True     True    Available
   └─ Object/orders-db-abcde                  True     True    Available
```

> ❓ **Preguntas del bloque 1.4**
> **Q7.** El developer creó un `PostgreSQLInstance` (Claim) en el namespace `default`, pero `crossplane beta trace` muestra un `XPostgreSQLInstance` con sufijo aleatorio. Explicá la relación Claim → XR → recurso compuesto y qué se guarda dónde.
> **Q8.** El developer nunca escribió `region: us-east` en un objeto que él controle la implementación. Nombrá **dos** cosas concretas que el platform engineer puede cambiar en la Composition (proveedor, versión de motor, red, backups) **sin que el developer toque su Claim**. ¿Qué propiedad del self-service demuestra esto?

---

## Ejercicio 2 — Golden paths con Backstage Software Templates (Scaffolder)

Crossplane resuelve el "qué se provisiona". Backstage resuelve el "cómo lo descubre y lo dispara el developer" con un formulario en un *Internal Developer Portal*. Acá modelamos un **golden path**: crear un microservicio completo (código + repo + registro en catálogo) desde un template.

### Bloque 2.1 — Anatomía de un Software Template

**Paso 1.** Guardá el siguiente template. Un `Template` de Backstage tiene tres partes que debés identificar: `parameters` (el formulario), `steps` (las acciones del Scaffolder) y `output` (los links de resultado):

```yaml
# template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: nodejs-microservice
  title: Node.js Microservice (Golden Path)
  description: Crea un microservicio Node.js con Dockerfile, manifiestos y GitOps listos.
  tags:
    - recommended
    - nodejs
spec:
  owner: platform-team
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
              kind: [Group]
    - title: Destino
      required: [repoUrl]
      properties:
        repoUrl:
          title: Repositorio
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts: [github.com]
  steps:
    - id: fetch
      name: Generar código desde el skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
    - id: publish
      name: Publicar el repositorio
      action: publish:github
      input:
        repoUrl: ${{ parameters.repoUrl }}
        description: Microservicio ${{ parameters.name }}
        defaultBranch: main
    - id: register
      name: Registrar en el catálogo
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
  output:
    links:
      - title: Repositorio
        url: ${{ steps.publish.output.remoteUrl }}
      - title: Abrir en el catálogo
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
```

**Paso 2.** Registrá el template para que aparezca en el portal (opción declarativa vía `app-config.yaml`):

```yaml
# fragmento de app-config.yaml
catalog:
  locations:
    - type: url
      target: https://github.com/org/software-templates/blob/main/template.yaml
      rules:
        - allow: [Template]
```

**Paso 3.** Reiniciá/recargá Backstage y verificá que el catálogo lo tomó (usando la API del backend del catálogo):

```bash
curl -s "http://localhost:7007/api/catalog/entities?filter=kind=template,metadata.name=nodejs-microservice" \
  | jq '.[].metadata.name'
```

```
"nodejs-microservice"
```

> ❓ **Preguntas del bloque 2.1**
> **Q9.** Los `parameters` se renderizan como formulario usando JSON Schema. ¿Qué gana el platform engineer al declarar `pattern: '^[a-z0-9-]+$'` y `ui:field: RepoUrlPicker` en el schema, en vez de dejar campos de texto libre?
> **Q10.** El `output.entityRef` sale de `steps.register.output`. Explicá por qué el paso `catalog:register` es lo que convierte a Backstage en un IDP *vivo* y no en un mero generador de boilerplate. ¿Qué se rompe en el "day 2" si omitís ese paso?

### Bloque 2.2 — Integrar el golden path con Crossplane

**Paso 4.** El poder real aparece cuando el Scaffolder no solo crea código, sino que dispara el provisioning del Ejercicio 1. Agregá un step que renderice un Claim en el repo GitOps del developer:

```yaml
    - id: request-db
      name: Solicitar base de datos (Crossplane Claim)
      action: fetch:template
      input:
        url: ./skeleton-db          # contiene un postgresqlinstance.yaml parametrizado
        targetPath: ./manifests
        values:
          name: ${{ parameters.name }}-db
          region: ${{ parameters.region }}
```

Donde `skeleton-db/postgresqlinstance.yaml` es exactamente la API que publicaste:

```yaml
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: ${{ values.name }}
spec:
  parameters:
    storageGB: 20
    region: ${{ values.region }}
```

> ❓ **Preguntas del bloque 2.2**
> **Q11.** Con este step, el developer llena **un formulario** y obtiene código + repo + base de datos aprovisionada. Identificá los dos frameworks de automatización que colaboran acá y cuál es la responsabilidad de cada uno (interfaz vs. ejecución).
> **Q12.** Backstage escribe el Claim en un repo y Argo CD/Flux lo aplica al cluster; Backstage **no** aplica el manifiesto directamente. ¿Por qué ese "commit en vez de apply" es preferible en un self-service de producción? (pensá en auditoría, drift y rollback).

---

## Ejercicio 3 — La plataforma como producto con Kratix Promises

Kratix modela un enfoque distinto: cada capacidad de self-service es una **Promise** que empaqueta la API *y* el workflow que la cumple. Es "platform as a product" hecho recurso de Kubernetes.

### Bloque 3.1 — Instalar Kratix y publicar una Promise

**Paso 1.** Instalá el operator de Kratix y su dependencia (usa MinIO/BucketStateStore o GitStateStore como *scheduling*):

```bash
kubectl apply -f https://github.com/syntasso/kratix/releases/latest/download/kratix.yaml
kubectl apply -f https://github.com/syntasso/kratix/releases/latest/download/minio-install.yaml
kubectl -n kratix-platform-system rollout status deploy/kratix-platform-controller-manager
```

**Paso 2.** Publicá una **Promise** que expone un tipo `postgresql`. Fijate en las dos partes: `api` (el CRD que ve el developer) y `workflows.resource.configure` (el pipeline que corre cuando alguien pide un recurso):

```yaml
# promise.yaml
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: postgresql
spec:
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: postgresqls.example.promise.syntasso.io
    spec:
      group: example.promise.syntasso.io
      scope: Namespaced
      names:
        kind: postgresql
        plural: postgresqls
        singular: postgresql
      versions:
        - name: v1
          served: true
          storage: true
          schema:
            openAPIV3Schema:
              type: object
              properties:
                spec:
                  type: object
                  properties:
                    teamId:
                      type: string
                    size:
                      type: string
                      default: small
                      enum: [small, medium, large]
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
                image: ghcr.io/org/postgres-request-pipeline:v1.0.0
```

```bash
kubectl apply -f promise.yaml
kubectl get promises
```

```
NAME         STATUS      KIND         GROUP                          VERSION
postgresql   Available   postgresql   example.promise.syntasso.io    v1
```

> ❓ **Preguntas del bloque 3.1**
> **Q13.** Una Promise empaqueta *API + dependencias + workflow* en un solo objeto versionable. Comparado con el Ejercicio 1 (donde XRD y Composition son objetos separados), ¿qué ventaja de distribución/portabilidad te da tener todo en una Promise? ¿Y qué desventaja de granularidad?
> **Q14.** El `workflows.resource.configure` es un **contenedor arbitrario**, no un motor de patch declarativo. ¿Qué te permite hacer eso que la composición declarativa de Crossplane no puede hacer fácilmente, y qué costo de mantenibilidad/seguridad introduce?

### Bloque 3.2 — Consumir la Promise

**Paso 3.** Como developer, pedí un recurso contra la API que la Promise creó:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: example.promise.syntasso.io/v1
kind: postgresql
metadata:
  name: orders
  namespace: default
spec:
  teamId: payments
  size: small
EOF
```

**Paso 4.** Kratix dispara el pipeline; observá el Job que lo ejecuta:

```bash
kubectl get pods -l kratix.io/promise-name=postgresql
```

```
NAME                                        READY   STATUS      RESTARTS   AGE
kratix-postgresql-orders-instance-abc12     0/1     Completed   0          25s
```

> ❓ **Preguntas del bloque 3.2**
> **Q15.** El pipeline corrió como un `Job` que salió `Completed`. Contrastá este modelo (pipeline imperativo que corre una vez por evento) con la reconciliación **continua** de Crossplane del Ejercicio 1: ¿cuál corrige *drift* automáticamente y por qué importa en producción?

---

## Ejercicio 4 — Self-service declarativo con Argo CD ApplicationSets

No todo self-service necesita un control plane nuevo. Un patrón muy usado es: **"el developer crea una carpeta/PR en Git y la plataforma materializa un entorno completo automáticamente"**. Eso es un `ApplicationSet` con un *generator*.

### Bloque 4.1 — Generar entornos por convención

**Paso 1.** Instalá Argo CD (incluye el controlador de ApplicationSet):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-applicationset-controller
```

**Paso 2.** Publicá un `ApplicationSet` con **Git directory generator**: por cada carpeta bajo `tenants/*` del repo, se crea automáticamente una `Application` con su namespace:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/org/tenants.git
        revision: HEAD
        directories:
          - path: tenants/*
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/tenants.git
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
EOF
```

**Paso 3.** Verificá que el controlador generó una `Application` por cada carpeta existente:

```bash
kubectl -n argocd get applications
```

```
NAME       SYNC STATUS   HEALTH STATUS
team-a     Synced        Healthy
team-b     Synced        Healthy
```

> ❓ **Preguntas del bloque 4.1**
> **Q16.** El self-service acá es: "el developer abre un PR agregando `tenants/team-c/`, y al mergear aparece su entorno". ¿Qué genera exactamente el `git` generator y qué campo del template (`{{.path.basename}}`) determina el aislamiento por namespace?
> **Q17.** `syncPolicy.automated` tiene `prune: true` y `selfHeal: true`. Explicá qué hace cada uno y por qué `selfHeal` es lo que convierte a esto en una plataforma que resiste el drift (a diferencia del pipeline one-shot del Ejercicio 3).

### Bloque 4.2 — Self-service efímero por Pull Request

**Paso 4.** Cambiá el generator a **Pull Request generator**: cada PR abierto crea un *preview environment* que se destruye al cerrarlo. Este es un patrón de self-service muy potente:

```yaml
  generators:
    - pullRequest:
        github:
          owner: org
          repo: app
          tokenRef:
            secretName: github-token
            key: token
        requeueAfterSeconds: 60
```

Con el template usando `{{.number}}` y `{{.head_sha}}` para nombrar el entorno.

> ❓ **Preguntas del bloque 4.2**
> **Q18.** El PR generator materializa un entorno por PR y lo elimina al cerrarlo (gracias al *pruning* del ApplicationSet). Nombrá dos beneficios de negocio de este self-service efímero y un riesgo de costos/capacidad que el platform engineer debe mitigar.

---

## Ejercicio 5 — Diagnóstico de pipelines de self-service (troubleshooting de producción)

Un self-service que falla en silencio es peor que no tenerlo. Acá practicás el *runbook* de diagnóstico cuando "el developer pidió algo y no pasa nada".

### Bloque 5.1 — Un Claim de Crossplane atascado

**Paso 1.** Rompé la RBAC a propósito para simular el fallo más común y creá un nuevo Claim:

```bash
kubectl delete clusterrolebinding provider-kubernetes-admin
cat <<'EOF' | kubectl apply -f -
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: broken-db
  namespace: default
spec:
  parameters:
    storageGB: 15
    region: eu-west
EOF
```

**Paso 2.** El Claim queda `READY=False`. Escalá el diagnóstico en orden — Claim → XR → recurso compuesto:

```bash
crossplane beta trace postgresqlinstance.database.example.org/broken-db -n default
```

```
NAME                                       SYNCED   READY   STATUS
PostgreSQLInstance/broken-db (default)     True     False   Waiting: ...
└─ XPostgreSQLInstance/broken-db-xyz98     True     False   Creating
   └─ Object/broken-db-xyz98               False    -       CannotCreate: ... is forbidden
```

**Paso 3.** Confirmá la causa raíz en los events del recurso compuesto y en los logs del provider:

```bash
kubectl describe object broken-db-xyz98 | sed -n '/Events/,$p'
kubectl -n crossplane-system logs deploy/provider-kubernetes-* --tail=20
```

```
Warning  CannotCreateExternalResource  ... configmaps is forbidden: User
"system:serviceaccount:crossplane-system:provider-kubernetes-..." cannot create
resource "configmaps" ...
```

**Paso 4.** Aplicá el fix y observá la auto-recuperación (sin recrear el Claim — es reconciliación continua):

```bash
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed 's|serviceaccount/||')
kubectl create clusterrolebinding provider-kubernetes-admin \
  --clusterrole cluster-admin --serviceaccount="crossplane-system:${SA}"
kubectl get postgresqlinstance broken-db -w
```

> ❓ **Preguntas del bloque 5.1**
> **Q19.** El Claim mostraba `SYNCED=True, READY=False` mientras el `Object` compuesto mostraba `SYNCED=False`. Explicá qué significa cada columna (`SYNCED` vs `READY`) y por qué el fallo real estaba "abajo" en el árbol y no en el Claim que ve el developer.
> **Q20.** En el Paso 4 no recreaste nada: apenas restaurada la RBAC, el recurso se materializó solo. ¿Qué propiedad del modelo de operator/controller hace esto posible, y qué implica para el diseño de un self-service resiliente frente a fallos transitorios (una API de nube caída, un rate limit)?

### Bloque 5.2 — Un ApplicationSet que no genera

**Paso 5.** Si `kubectl -n argocd get applications` no muestra nada esperado, seguí este orden de diagnóstico:

```bash
# 1. ¿El generator ve el repo? Logs del controlador de ApplicationSet:
kubectl -n argocd logs deploy/argocd-applicationset-controller --tail=30

# 2. ¿El estado del ApplicationSet reporta error de generación?
kubectl -n argocd describe applicationset tenant-apps | sed -n '/Status/,$p'
```

> ❓ **Preguntas del bloque 5.2**
> **Q21.** Un developer se queja de que su `Application` sí se generó pero quedó `OutOfSync` y no se aplica. El `ApplicationSet` no tiene `syncPolicy.automated`. ¿Cuál es la causa y por qué es importante distinguir **"la App no se generó"** (problema del generator/ApplicationSet controller) de **"la App se generó pero no sincroniza"** (problema del Application controller)?

---

## Cierre — Síntesis transversal

> ❓ **Preguntas integradoras**
> **Q22.** Ubicá cada framework de este tema en el eje **interfaz ↔ ejecución** del self-service: Backstage, Crossplane, Kratix, Argo CD ApplicationSet. ¿Cuáles son primariamente *la puerta de entrada* del developer y cuáles *el motor de provisioning*? ¿Por qué en una plataforma madura conviven?
> **Q23.** Los cuatro frameworks comparten un principio central del CNCF Platforms Whitepaper: exponer *capacidades* mediante *interfaces bien definidas* en vez de dar acceso crudo a la infraestructura. Explicá con tus palabras por qué "una API opinada y acotada" es más valiosa para el negocio que "acceso total a Terraform/kubectl", citando tres dimensiones (velocidad, seguridad/compliance, carga cognitiva).

---

## Fuentes oficiales

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Crossplane — Composite Resources, XRDs y Compositions — https://docs.crossplane.io/latest/concepts/
- Crossplane — Composition Functions (pipeline mode) — https://docs.crossplane.io/latest/concepts/compositions/
- crossplane-contrib/provider-kubernetes — https://github.com/crossplane-contrib/provider-kubernetes
- crossplane-contrib/function-patch-and-transform — https://github.com/crossplane-contrib/function-patch-and-transform
- Backstage — Software Templates (Scaffolder) — https://backstage.io/docs/features/software-templates/
- Backstage — Writing Templates & built-in actions — https://backstage.io/docs/features/software-templates/writing-templates
- Kratix — Promises y Workflows — https://docs.kratix.io/
- Argo CD — ApplicationSet controller y generators — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD — Git & Pull Request generators — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators/
- CNCF Platforms Whitepaper (TAG App Delivery) — https://tag-app-delivery.cncf.io/whitepapers/platforms/

---

<details>
<summary><strong>Respuestas — verificá tu comprensión</strong></summary>

**Q1.** Crossplane registra **Custom Resource Definitions (CRDs)** y actúa como un conjunto de controllers; sus tipos viven *dentro* del mismo API server de Kubernetes vía el mecanismo de *aggregation/extension* de CRDs. Ventaja operativa: reusás toda la maquinaria existente — `kubectl` funciona sin plugins, el **RBAC** de Kubernetes controla quién puede pedir qué (podés dar `create postgresqlinstances` a un equipo y nada más), y el **audit log** del API server registra cada provisioning como cualquier otra operación. No necesitás un portal ni una base de datos aparte para el estado deseado.

**Q2.** Porque el estado *real* (una base de datos, una VM) tarda en converger y puede fallar y reintentarse. Crossplane guarda el *estado deseado* y un controller **reconcilia continuamente** hacia él. Implicación para el developer: justo después de `kubectl apply` su recurso existe pero está `READY=False`; la creación es una promesa que se cumple asíncronamente, no una respuesta inmediata. Debe observar `status`/conditions, no asumir éxito por el código de retorno del apply.

**Q3.** Un **Provider** aporta el *dominio de recursos externos* (CRDs como `Object`, `Bucket`, `RDSInstance`) y los controllers que hablan con la API externa. Una **Function** es un componente del *pipeline de composición* que, dado el XR, calcula qué recursos componer (patch & transform, Go templating, KCL, etc.). Se separó de "patch & transform nativo" porque embeder toda la lógica de transformación en el schema del `Composition` no escalaba: era difícil de testear, no componible y sin lenguaje de programación. El pipeline de functions es modular, testeable y extensible.

**Q4.** El provider corre bajo su propia ServiceAccount y Crossplane no le concede permisos sobre recursos arbitrarios del cluster por defecto — sería una escalada de privilegios automática. Vos definís explícitamente qué puede tocar. Riesgo de `cluster-admin`: cualquier Composition (o una comprometida) podría crear/borrar *cualquier* objeto del cluster, y un Claim de un developer podría, vía composición mal diseñada, materializar recursos privilegiados. En producción se acota con un `ClusterRole` mínimo (solo los verbos/recursos que las Compositions realmente crean).

**Q5.** Validar en el schema hace que la API **rechace** el request inválido en el momento del `apply`, con un error claro para el developer, antes de crear nada — es *fail-fast* y self-documenting (el schema ES la documentación de opciones válidas). Validar dentro de la Composition o en CI detecta el error más tarde, cuando ya hay un objeto creado en estado inválido, o requiere un roundtrip de CI. Encarna el principio de **"paved road / golden path con guardrails"**: la plataforma ofrece opciones seguras y limitadas por diseño, no libertad total.

**Q6.** El **XR** (`XPostgreSQLInstance`) es cluster-scoped y representa la instancia "real" gestionada por la plataforma; el **Claim** (`PostgreSQLInstance`) es namespaced y es el *handle* que el developer crea en su propio namespace. Crossplane crea automáticamente un XR por cada Claim. El developer usa el Claim porque respeta las fronteras de multi-tenancy (RBAC por namespace, quotas) y no necesita permisos cluster-scoped; el XR es detalle de la plataforma.

**Q7.** El developer crea el **Claim** `orders-db` en `default`. Crossplane genera un **XR** (`orders-db-abcde`, cluster-scoped, sufijo aleatorio) enlazado a ese Claim. El XR, según la Composition, crea el/los **recursos compuestos** (aquí un `Object` que a su vez produce el `ConfigMap`). El estado deseado del developer vive en el Claim; el estado de implementación y las referencias a recursos externos viven en el XR y sus recursos compuestos. Borrar el Claim propaga el borrado hacia abajo.

**Q8.** Ejemplos: (a) cambiar el proveedor real (de un `ConfigMap` de laboratorio a un `RDSInstance` de AWS o un `Database` de Cloud SQL); (b) cambiar la versión del motor, agregar backups automáticos, cambiar la red/subnet, o añadir un `Secret` de conexión — todo editando la Composition. El developer sigue pidiendo `storageGB` y `region`. Demuestra la **separación interfaz/implementación**: la API es un contrato estable y la implementación evoluciona por detrás (incluso migrás de nube) sin romper a los consumidores.

**Q9.** Gana **validación y UX consistentes en el punto de entrada**: el `pattern` impide nombres inválidos antes de generar nada, y `RepoUrlPicker`/`OwnerPicker` restringen a hosts y entidades permitidas del catálogo, evitando typos y valores fuera de política. Es la misma filosofía de guardrails que el XRD de Crossplane, pero en la capa de portal: el formulario *es* la especificación de lo permitido.

**Q10.** `catalog:register` inserta la nueva entidad (con su `catalog-info.yaml`) en el catálogo de Backstage, de modo que el servicio recién creado queda **descubrible, con owner, docs, dependencias y relaciones** desde el minuto cero. Sin ese paso, Backstage solo generó código y un repo: en el "day 2" el servicio es invisible para el portal — nadie lo encuentra, no tiene owner asignado, no aparece en los dashboards ni en el software catalog, y se pierde el propósito de un IDP (que es el *sistema de registro* de todo lo que existe).

**Q11.** **Backstage** = la *interfaz* (el formulario/golden path que el developer usa para expresar su intención). **Crossplane** = el *motor de ejecución* (la API que materializa la base de datos con reconciliación continua). Backstage no sabe crear bases de datos; solo renderiza un Claim contra la API que Crossplane publica. Cada uno hace lo que hace bien: descubrimiento/experiencia vs. provisioning/reconciliación.

**Q12.** Porque "commit en vez de apply" mantiene Git como **fuente única de verdad**: queda un registro auditable de quién pidió qué y cuándo (el commit/PR), el estado deseado es versionado y revisable, el *drift* se corrige solo si usás GitOps con self-heal, y el **rollback** es un `git revert`. Si Backstage aplicara directo al cluster, perderías la trazabilidad, no habría revisión previa, y el cluster podría divergir de cualquier registro.

**Q13.** Ventaja: una Promise es **una unidad portable y versionable** — la instalás en otro cluster/plataforma con un solo `kubectl apply` y trae su API, sus dependencias y su workflow juntos; es ideal para distribuir capacidades "llave en mano" entre equipos/plataformas (marketplace de Promises). Desventaja: **menor granularidad/composabilidad** — al acoplar API+workflow, es menos flexible mezclar y versionar sus partes por separado que con XRD y Composition, que evolucionan de forma independiente.

**Q14.** Un contenedor arbitrario te deja ejecutar **cualquier lógica imperativa** (llamar APIs externas, correr `terraform`, scripts, herramientas propietarias, orquestación compleja) que sería difícil o imposible de expresar en composición puramente declarativa. Costo: introducís **código que hay que mantener, testear y asegurar** — el pipeline es una superficie de ataque (imagen de contenedor con credenciales), puede tener bugs no detectables por validación de schema, y su comportamiento no es tan auditable/predecible como un modelo declarativo.

**Q15.** **Crossplane** corrige drift automáticamente: su controller reconcilia de forma continua, así que si alguien borra o modifica el recurso real, lo vuelve al estado deseado. El pipeline de Kratix es un `Job` que corre **una vez por evento** (`Completed`); no vigila el estado después. Importa en producción porque el drift (cambios manuales, fallos parciales, borrados accidentales) es inevitable, y una plataforma que solo actúa "al pedido" deja los recursos divergir en silencio hasta el próximo evento. (Kratix puede re-disparar workflows, pero el modelo base es event-driven, no reconciliación continua.)

**Q16.** El `git` directory generator produce **un parámetro por cada carpeta** que matchea `tenants/*`, y por cada uno el `template` instancia una `Application` de Argo CD. `{{.path.basename}}` (el nombre de la carpeta, p.ej. `team-a`) se usa tanto como nombre de la Application como namespace de destino, logrando aislamiento por tenant. Agregar `tenants/team-c/` y mergear hace que el controlador genere `team-c` automáticamente.

**Q17.** `prune: true` **borra** del cluster los recursos que ya no están en Git (mantiene el cluster en paridad exacta con el repo). `selfHeal: true` **revierte** cualquier cambio hecho directo en el cluster que difiera de Git, reaplicando el estado deseado. `selfHeal` es lo que da resiliencia al drift: a diferencia del pipeline one-shot de Kratix, acá el Application controller reconcilia continuamente contra Git, así que un `kubectl edit` manual se deshace solo.

**Q18.** Beneficios: (a) cada PR obtiene un **entorno aislado y realista** para review/QA/demo sin pisar a otros, acelerando el feedback; (b) el ciclo es **totalmente self-service y automático** — no hay que pedirle a nadie que provisione un entorno de prueba. Riesgo: **proliferación de entornos** (cada PR abierto consume CPU/memoria/costo); mitigación: límites de recursos/quotas por preview, TTL/expiración, y confiar en el *pruning* al cerrar el PR para no dejar entornos huérfanos.

**Q19.** `SYNCED` indica que Crossplane logró **traducir y aplicar** el estado deseado hacia el recurso (la reconciliación llegó sin error de composición). `READY` indica que el recurso **existe y está operativo** en el sistema externo. El Claim mostraba `SYNCED=True` porque la composición se resolvió bien, pero `READY=False` porque el recurso subyacente nunca se creó. El fallo real estaba en el `Object` compuesto (`SYNCED=False`, RBAC forbidden): por eso siempre se diagnostica **bajando el árbol** (`crossplane beta trace`) hasta el recurso hoja, no en el Claim.

**Q20.** Lo hace posible el modelo de **controller con loop de reconciliación**: el controller no ejecuta una vez y se olvida, sino que reintenta continuamente hasta que estado real = estado deseado (con backoff). Al restaurar la RBAC, el siguiente ciclo simplemente tuvo éxito. Para diseñar self-service resiliente: los fallos transitorios (API de nube caída, rate limit, permiso temporalmente ausente) **se auto-recuperan** sin intervención humana ni recrear el request — el sistema es *eventually consistent* y tolerante a fallos por construcción.

**Q21.** Causa: sin `syncPolicy.automated`, el `ApplicationSet` **genera** correctamente las `Application` pero la sincronización queda **manual** — hay que hacer sync explícito (UI/CLI), por eso queda `OutOfSync`. Importa distinguir las dos capas porque involucran controllers y fixes distintos: "no se generó" es problema del **ApplicationSet controller / generator** (repo inaccesible, glob que no matchea, token inválido — se ve en sus logs), mientras que "se generó pero no sincroniza" es problema del **Application controller / syncPolicy** (falta `automated`, hook fallido, recurso inválido — se ve en el status de la Application). Diagnosticar la capa equivocada te hace perder tiempo.

**Q22.**
- **Interfaz (puerta de entrada del developer):** **Backstage** (portal/formulario/golden paths) y, en menor medida, el **Git repo** que alimenta el ApplicationSet (la interfaz "por PR").
- **Ejecución (motor de provisioning):** **Crossplane** (control plane con reconciliación continua), **Kratix** (Promises + workflows) y **Argo CD ApplicationSet** (materialización declarativa desde Git).
Conviven porque resuelven problemas distintos: un IDP sin motor no aprovisiona nada, y un motor sin interfaz obliga al developer a conocer YAML/CRDs internos. Una plataforma madura combina una capa de experiencia (Backstage) que dispara motores de provisioning (Crossplane/Kratix) entregados por GitOps (Argo CD), cada capa con su responsabilidad clara.

**Q23.** Una API opinada y acotada aporta: **(1) Velocidad** — el developer expresa intención ("quiero una DB de 20GB en us-east") sin aprender Terraform, redes ni IAM; el time-to-provision cae de días a minutos. **(2) Seguridad/compliance** — la plataforma codifica los guardrails (encriptación, backups, tags, regiones permitidas, límites) en la implementación, así que *toda* provisión cumple política por construcción, en vez de depender de que cada equipo lo haga bien con acceso crudo. **(3) Carga cognitiva** — el developer razona sobre *su* dominio, no sobre la infraestructura; la complejidad (proveedores, versiones, cableado) queda encapsulada y es responsabilidad del equipo de plataforma. Dar "acceso total a Terraform/kubectl" invierte las tres: más lento (todos reinventan), más inseguro (cada uno puede saltarse controles) y más costoso cognitivamente (todos deben ser expertos en infra). Es el principio central del CNCF Platforms Whitepaper: las plataformas exponen *capabilities* mediante *interfaces bien definidas*, no acceso directo a la infraestructura.

</details>