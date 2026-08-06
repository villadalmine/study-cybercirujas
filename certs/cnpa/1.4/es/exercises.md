# 1.4 Platform Architecture and Core Capabilities — Ejercicios guiados

> **Entorno requerido:** Docker, `kind` ≥ 0.27, `kubectl` ≥ 1.32, `helm` ≥ 3.16, `curl` y `python3`. Todos los ejercicios corren en local, sin credenciales cloud. Las versiones de charts y packages están **fijadas** (pinned) para que el laboratorio sea reproducible; en producción harías lo mismo, por las mismas razones.
>
> **Tiempo estimado:** 90–120 minutos.
>
> **Hilo conductor:** vas a construir una plataforma mínima con sus capacidades núcleo según el [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/): un **platform control plane** (Crossplane) que expone una **self-service API** (`WebApp`), un **golden path template** (Backstage) que la consume, y la **observability de la plataforma misma** — no de los workloads.

---

## Ejercicio 1 — Separar los planos: Kubernetes control plane vs. platform control plane

La arquitectura de toda plataforma cloud native se razona en capas: el **data plane** donde corren los workloads, el **Kubernetes control plane** que reconcilia el estado del cluster, y encima el **platform control plane** que reconcilia abstracciones de mayor nivel (bases de datos, entornos, aplicaciones completas). Antes de instalar nada, hay que poder señalar cada plano con el dedo.

### Pasos

1. Creá un cluster `kind` con un nodo de control plane y dos workers, para que la separación de planos sea física y no solo conceptual:

   ```bash
   cat <<EOF > kind-platform.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   EOF

   kind create cluster --name cnpa-14 --config kind-platform.yaml
   ```

   Salida esperada (resumida):

   ```
   Creating cluster "cnpa-14" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦 📦 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
    ✓ Joining worker nodes 🚜
   Set kubectl context to "kind-cnpa-14"
   ```

2. Enumerá los nodos y observá los roles:

   ```bash
   kubectl get nodes
   ```

   ```
   NAME                    STATUS   ROLES           AGE   VERSION
   cnpa-14-control-plane   Ready    control-plane   2m    v1.33.1
   cnpa-14-worker          Ready    <none>          90s   v1.33.1
   cnpa-14-worker2         Ready    <none>          90s   v1.33.1
   ```

3. Listá los componentes del Kubernetes control plane y verificá en qué nodo corren:

   ```bash
   kubectl get pods -n kube-system -o wide | grep -E 'apiserver|etcd|scheduler|controller-manager'
   ```

   ```
   etcd-cnpa-14-control-plane                      1/1   Running   0   2m   ...   cnpa-14-control-plane
   kube-apiserver-cnpa-14-control-plane            1/1   Running   0   2m   ...   cnpa-14-control-plane
   kube-controller-manager-cnpa-14-control-plane   1/1   Running   0   2m   ...   cnpa-14-control-plane
   kube-scheduler-cnpa-14-control-plane            1/1   Running   0   2m   ...   cnpa-14-control-plane
   ```

4. Registrá el inventario de APIs que existe hoy — este es tu punto de comparación para el Ejercicio 2:

   ```bash
   kubectl api-resources --api-group=platform.acme.io
   ```

   ```
   error: the server doesn't have a resource type "" in group "platform.acme.io"
   ```

   Todavía no existe ninguna API de plataforma. Todo lo que el cluster sabe ofrecer son primitivas de Kubernetes.

### Preguntas

**1.1** — De las capacidades que enumera el CNCF Platforms White Paper (web portals, APIs de provisioning, golden path templates, automation de build/deploy, development environments, observability, infrastructure/data/messaging services), ¿cuáles provee un cluster Kubernetes recién creado como este, y cuáles faltan por completo?

**1.2** — Crossplane, que vas a instalar en el próximo ejercicio, corre como Pods sobre los workers — es decir, sobre el data plane de Kubernetes. ¿En qué sentido es entonces un "control plane"? ¿Qué define a un componente como parte de un control plane: dónde corre, o qué hace?

**1.3** — El white paper insiste en que una plataforma es **"a product, not a project"**. ¿Qué implicancias concretas de arquitectura tiene esa frase? Nombrá al menos tres.

---

## Ejercicio 2 — Construir la self-service API de la plataforma con Crossplane

La capacidad núcleo "APIs for automatically provisioning" no significa "los desarrolladores tienen acceso a `kubectl`". Significa que la plataforma expone **su propia API**, con el vocabulario del dominio (una `WebApp`, no un Deployment + Service + HPA), y que detrás de esa API el platform team decide la implementación. Acá la construís de punta a punta.

### Pasos

1. Instalá Crossplane con las métricas habilitadas (las vas a necesitar en el Ejercicio 4):

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace \
     --version 1.20.0 \
     --set metrics.enabled=true \
     --wait

   kubectl get pods -n crossplane-system
   ```

   ```
   NAME                                       READY   STATUS    RESTARTS   AGE
   crossplane-6b5d7f9c65-x2m4q                1/1     Running   0          45s
   crossplane-rbac-manager-7c8fd6d54b-9kzlt   1/1     Running   0          45s
   ```

2. Instalá el provider que le permite a Crossplane gestionar recursos Kubernetes arbitrarios, y la function de composición:

   ```bash
   cat <<EOF | kubectl apply -f -
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
     package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.7.0
   EOF
   ```

   Esperá a que ambos estén `HEALTHY: True`:

   ```bash
   kubectl get providers,functions
   ```

   ```
   NAME                                               INSTALLED   HEALTHY   PACKAGE                                                              AGE
   provider.pkg.crossplane.io/provider-kubernetes     True        True      xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.16.0   60s

   NAME                                                        INSTALLED   HEALTHY   PACKAGE                                                                        AGE
   function.pkg.crossplane.io/function-patch-and-transform     True        True      xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.7.0     60s
   ```

3. Autorizá al provider a crear recursos en el cluster local (en el lab usamos `cluster-admin`; en producción sería un ClusterRole acotado a los kinds que la plataforma compone):

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name \
     | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|')

   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole cluster-admin --serviceaccount="${SA}"

   cat <<EOF | kubectl apply -f -
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   EOF
   ```

4. Definí el **contrato** de la API de plataforma — la `CompositeResourceDefinition` (XRD). Fijate que el schema solo expone lo que el equipo de aplicación debe decidir (`image`, `replicas`); todo lo demás es responsabilidad de la plataforma:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xwebapps.platform.acme.io
   spec:
     group: platform.acme.io
     names:
       kind: XWebApp
       plural: xwebapps
     claimNames:
       kind: WebApp
       plural: webapps
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
                   image:
                     type: string
                     description: Container image to deploy.
                   replicas:
                     type: integer
                     default: 1
                     minimum: 1
                     maximum: 10
                 required:
                   - image
   EOF
   ```

5. Definí la **implementación** — la `Composition`. Este manifiesto es propiedad exclusiva del platform team; los consumidores nunca lo ven:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: webapp-kubernetes
     labels:
       provider: kubernetes
   spec:
     compositeTypeRef:
       apiVersion: platform.acme.io/v1alpha1
       kind: XWebApp
     mode: Pipeline
     pipeline:
       - step: patch-and-transform
         functionRef:
           name: function-patch-and-transform
         input:
           apiVersion: pt.fn.crossplane.io/v1beta1
           kind: Resources
           resources:
             - name: deployment
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha2
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: apps/v1
                       kind: Deployment
                       metadata:
                         name: patched
                         namespace: patched
                         labels:
                           app.kubernetes.io/managed-by: crossplane
                       spec:
                         replicas: 1
                         selector:
                           matchLabels:
                             app.kubernetes.io/name: webapp
                         template:
                           metadata:
                             labels:
                               app.kubernetes.io/name: webapp
                           spec:
                             containers:
                               - name: app
                                 image: patched
                                 ports:
                                   - containerPort: 80
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: metadata.labels['crossplane.io/claim-name']
                   toFieldPath: spec.forProvider.manifest.metadata.name
                 - type: FromCompositeFieldPath
                   fromFieldPath: metadata.labels['crossplane.io/claim-namespace']
                   toFieldPath: spec.forProvider.manifest.metadata.namespace
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.image
                   toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].image
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.replicas
                   toFieldPath: spec.forProvider.manifest.spec.replicas
   EOF
   ```

6. Verificá que la API nueva es un ciudadano de primera clase del cluster — descubrible y auto-documentada:

   ```bash
   kubectl api-resources --api-group=platform.acme.io
   ```

   ```
   NAME       SHORTNAMES   APIVERSION                    NAMESPACED   KIND
   webapps                 platform.acme.io/v1alpha1     true         WebApp
   xwebapps                platform.acme.io/v1alpha1     false        XWebApp
   ```

   ```bash
   kubectl explain webapp.spec
   ```

   ```
   GROUP:      platform.acme.io
   KIND:       WebApp
   VERSION:    v1alpha1

   FIELD: spec <Object>

   FIELDS:
     image <string> -required-
       Container image to deploy.

     replicas <integer>
   ```

7. Ahora cambiá de rol: sos un **application team** que consume la plataforma. Creá un claim — notá que no aparece ni un solo concepto de infraestructura:

   ```bash
   kubectl create namespace team-a

   cat <<EOF | kubectl apply -f -
   apiVersion: platform.acme.io/v1alpha1
   kind: WebApp
   metadata:
     name: shop-frontend
     namespace: team-a
   spec:
     image: nginx:1.27
     replicas: 2
   EOF
   ```

8. Seguí la cadena de reconciliation completa, capa por capa:

   ```bash
   kubectl -n team-a get webapp
   ```

   ```
   NAME            SYNCED   READY   CONNECTION-SECRET   AGE
   shop-frontend   True     True                        74s
   ```

   ```bash
   kubectl get xwebapps
   ```

   ```
   NAME                  SYNCED   READY   COMPOSITION         AGE
   shop-frontend-7k2xp   True     True    webapp-kubernetes   78s
   ```

   ```bash
   kubectl get objects.kubernetes.crossplane.io
   ```

   ```
   NAME                        KIND         PROVIDERCONFIG   SYNCED   READY   AGE
   shop-frontend-7k2xp-b8s6w   Deployment   default          True     True    76s
   ```

   ```bash
   kubectl -n team-a get deployment shop-frontend
   ```

   ```
   NAME            READY   UP-TO-DATE   AVAILABLE   AGE
   shop-frontend   2/2     2            2           80s
   ```

9. Probá la **continuidad del control plane**: rompé el estado por debajo de la API y observá cómo la plataforma lo restituye. Borrá el Deployment directamente y forzá un ciclo de reconciliation (el provider repollea cada cierto intervalo; la annotation lo dispara ya):

   ```bash
   kubectl -n team-a delete deployment shop-frontend

   OBJ=$(kubectl get objects.kubernetes.crossplane.io -o name | head -1)
   kubectl annotate "${OBJ}" force-reconcile="$(date +%s)" --overwrite

   sleep 10
   kubectl -n team-a get deployment shop-frontend
   ```

   ```
   NAME            READY   UP-TO-DATE   AVAILABLE   AGE
   shop-frontend   2/2     2            2           9s
   ```

   El Deployment volvió. Nadie corrió un pipeline, nadie abrió un ticket: el estado deseado vive en el claim y el control plane converge hacia él, siempre.

### Preguntas

**2.1** — En este ejercicio escribiste cuatro tipos de manifiestos: XRD, Composition, ProviderConfig y claim. Para cada uno: ¿qué equipo lo posee en una organización real (platform team o application team), y qué interfaz forma entre ambos?

**2.2** — ¿Por qué el claim `WebApp` es **namespaced** mientras que el composite `XWebApp` es **cluster-scoped**? ¿Qué problema de multi-tenancy resuelve ese diseño?

**2.3** — El paso 9 demuestra una diferencia arquitectónica fundamental entre un platform control plane y un pipeline de CI/CD que hace `kubectl apply`. Explicala en términos de *cuándo* actúa cada uno y contra qué clase de fallas protege cada modelo.

**2.4** — Si mañana el platform team decide que las `WebApp` deben desplegarse en un cluster remoto de producción en lugar del cluster local, ¿qué manifiestos cambian y qué manifiestos de los equipos de aplicación se tocan? ¿Qué capacidad del white paper habilita exactamente esa propiedad?

---

## Ejercicio 3 — Autorar el golden path: un Software Template de Backstage que consume la API de plataforma

Un **golden path** es el camino soportado, documentado y de menor fricción para una tarea recurrente — crear un microservicio nuevo, en este caso. El portal (capacidad "web portals" del white paper) no reemplaza a la API: la **consume**. Acá vas a autorar el template que conecta el formulario del portal con el claim del Ejercicio 2.

### Pasos

1. Creá la estructura del template con su skeleton:

   ```bash
   mkdir -p golden-path/skeleton
   ```

2. Escribí el template del scaffolder. Cada `step` es una acción que el portal ejecuta en nombre del desarrollador:

   ```bash
   cat <<'EOF' > golden-path/template.yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: webapp-golden-path
     title: WebApp - Golden Path
     description: >-
       Crea un microservicio con repositorio, registro en el catálogo
       y despliegue self-service vía la API WebApp de la plataforma.
     tags:
       - recommended
       - golden-path
   spec:
     owner: group:platform-team
     type: service
     parameters:
       - title: Datos del servicio
         required:
           - name
           - owner
         properties:
           name:
             title: Nombre del servicio
             type: string
             pattern: '^[a-z0-9-]+$'
             description: Minusculas, numeros y guiones.
           owner:
             title: Equipo propietario
             type: string
             ui:field: OwnerPicker
           image:
             title: Imagen inicial
             type: string
             default: nginx:1.27
           replicas:
             title: Replicas
             type: integer
             default: 1
     steps:
       - id: fetch
         name: Generar esqueleto
         action: fetch:template
         input:
           url: ./skeleton
           values:
             name: ${{ parameters.name }}
             owner: ${{ parameters.owner }}
             image: ${{ parameters.image }}
             replicas: ${{ parameters.replicas }}
       - id: publish
         name: Publicar repositorio
         action: publish:github
         input:
           repoUrl: github.com?owner=acme-platform&repo=${{ parameters.name }}
           defaultBranch: main
       - id: register
         name: Registrar en el catalogo
         action: catalog:register
         input:
           repoContentsUrl: ${{ steps['publish'].output.repoContentsUrl }}
           catalogInfoPath: /catalog-info.yaml
     output:
       links:
         - title: Repositorio
           url: ${{ steps['publish'].output.remoteUrl }}
         - title: Componente en el catalogo
           icon: catalog
           entityRef: ${{ steps['register'].output.entityRef }}
   EOF
   ```

3. Escribí el skeleton. Es la parte decisiva: el esqueleto **contiene el claim de la plataforma**, así el servicio nace desplegable por la vía self-service, con ownership y metadata desde el día cero:

   ```bash
   cat <<'EOF' > golden-path/skeleton/catalog-info.yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: ${{ values.name }}
     annotations:
       backstage.io/kubernetes-id: ${{ values.name }}
   spec:
     type: service
     lifecycle: production
     owner: ${{ values.owner }}
   EOF

   cat <<'EOF' > golden-path/skeleton/webapp-claim.yaml
   apiVersion: platform.acme.io/v1alpha1
   kind: WebApp
   metadata:
     name: ${{ values.name }}
   spec:
     image: ${{ values.image }}
     replicas: ${{ values.replicas }}
   EOF
   ```

4. Validá que ambos archivos son YAML sintácticamente correcto (el templating `${{ }}` de Backstage es un scalar válido para el parser):

   ```bash
   python3 - <<'EOF'
   import yaml
   for f in ("golden-path/template.yaml",
             "golden-path/skeleton/catalog-info.yaml",
             "golden-path/skeleton/webapp-claim.yaml"):
       yaml.safe_load(open(f))
       print(f"{f}: OK")
   EOF
   ```

   ```
   golden-path/template.yaml: OK
   golden-path/skeleton/catalog-info.yaml: OK
   golden-path/skeleton/webapp-claim.yaml: OK
   ```

5. Simulá manualmente lo que el scaffolder haría con los parámetros `name=billing-api`, `owner=team-a`, `image=nginx:1.27`, `replicas=1`, y aplicá el claim resultante para cerrar el circuito portal → API → control plane:

   ```bash
   sed -e 's/\${{ values.name }}/billing-api/' \
       -e 's/\${{ values.image }}/nginx:1.27/' \
       -e 's/\${{ values.replicas }}/1/' \
       golden-path/skeleton/webapp-claim.yaml \
     | kubectl -n team-a apply -f -

   kubectl -n team-a get webapps
   ```

   ```
   webapp.platform.acme.io/billing-api created

   NAME            SYNCED   READY   CONNECTION-SECRET   AGE
   billing-api     True     True                        30s
   shop-frontend   True     True                        25m
   ```

### Preguntas

**3.1** — Recorré las capacidades del white paper y marcá cuáles toca este template concreto: ¿qué cubre, qué delega en el Ejercicio 2, y qué queda todavía sin cubrir en nuestra mini-plataforma?

**3.2** — ¿Qué diferencia a un *golden path* de una *golden cage*? ¿Qué decisión de diseño de este ejercicio preserva la salida de emergencia para un equipo con un caso de uso que el template no contempla?

**3.3** — El template declara `spec.owner: group:platform-team`. Desde la óptica "platform as a product", ¿qué obligaciones operativas acarrea esa línea? Pensá en qué pasa cuando 40 servicios fueron creados con la versión 1 del template y el platform team publica la versión 2.

---

## Ejercicio 4 — Observar la plataforma misma, no los workloads

El white paper lista "observability for workloads **and the platform itself**" como capacidad núcleo, y es la mitad de la frase que casi todos omiten. Si la self-service API está degradada, los desarrolladores no pueden provisionar aunque todos los workloads estén verdes. La plataforma tiene sus propios SLIs.

### Pasos

1. El primer punto de medición es el API server: toda interacción con tu API de plataforma pasa por ahí. Filtrá las métricas del grupo `platform.acme.io`:

   ```bash
   kubectl get --raw /metrics \
     | grep 'apiserver_request_total' \
     | grep 'platform.acme.io' \
     | head -4
   ```

   ```
   apiserver_request_total{code="200",component="apiserver",group="platform.acme.io",resource="webapps",scope="namespace",verb="APPLY",version="v1alpha1",...} 2
   apiserver_request_total{code="200",component="apiserver",group="platform.acme.io",resource="webapps",scope="namespace",verb="LIST",version="v1alpha1",...} 5
   apiserver_request_total{code="200",component="apiserver",group="platform.acme.io",resource="xwebapps",scope="cluster",verb="WATCH",version="v1alpha1",...} 3
   apiserver_request_total{code="201",component="apiserver",group="platform.acme.io",resource="webapps",scope="namespace",verb="POST",version="v1alpha1",...} 2
   ```

   Tu API de plataforma tiene tráfico medible con las mismas herramientas que cualquier API de Kubernetes — consecuencia directa de haberla construido *sobre* el API machinery en lugar de al costado.

2. El segundo punto de medición es el propio motor de reconciliation. Habilitaste `metrics.enabled=true` en el Ejercicio 2; exponé el endpoint y consultalo:

   ```bash
   kubectl -n crossplane-system port-forward deploy/crossplane 8080:8080 &
   sleep 2

   curl -s localhost:8080/metrics \
     | grep 'controller_runtime_reconcile_total' \
     | grep -E 'xwebapp|claim' \
     | head -4
   ```

   ```
   controller_runtime_reconcile_total{controller="composite/xwebapps.platform.acme.io",result="success"} 14
   controller_runtime_reconcile_total{controller="offered/webapps.platform.acme.io",result="success"} 11
   controller_runtime_reconcile_total{controller="composite/xwebapps.platform.acme.io",result="error"} 0
   controller_runtime_reconcile_total{controller="offered/webapps.platform.acme.io",result="error"} 0
   ```

3. Ahora provocá un error de plataforma **invisible para el usuario final** y encontralo en las métricas. Rompé el RBAC del provider:

   ```bash
   kubectl delete clusterrolebinding provider-kubernetes-admin

   cat <<EOF | kubectl -n team-a apply -f -
   apiVersion: platform.acme.io/v1alpha1
   kind: WebApp
   metadata:
     name: broken-app
   spec:
     image: nginx:1.27
   EOF

   sleep 30
   kubectl -n team-a get webapp broken-app
   ```

   ```
   NAME         SYNCED   READY   CONNECTION-SECRET   AGE
   broken-app   True     False                       32s
   ```

4. Diagnosticá con la técnica estándar de un platform engineer — descender por la cadena composite → managed resource → evento:

   ```bash
   kubectl describe objects.kubernetes.crossplane.io | grep -A 3 'Warning'
   ```

   ```
     Warning  CannotObserveExternalResource  12s (x6 over 30s)  managed/object.kubernetes.crossplane.io
     cannot get object: deployments.apps "broken-app" is forbidden: User
     "system:serviceaccount:crossplane-system:provider-kubernetes-..." cannot
     get resource "deployments" in API group "apps" in the namespace "team-a"
   ```

   Y confirmá que el contador de errores del provider lo registra (métrica de la managed resource reconciliation):

   ```bash
   kubectl -n crossplane-system port-forward "$(kubectl -n crossplane-system get pod -o name | grep provider-kubernetes | head -1)" 8081:8080 &
   sleep 2
   curl -s localhost:8081/metrics | grep 'controller_runtime_reconcile_total{controller="managed/object' 
   ```

   ```
   controller_runtime_reconcile_total{controller="managed/object.kubernetes.crossplane.io",result="error"} 6
   controller_runtime_reconcile_total{controller="managed/object.kubernetes.crossplane.io",result="success"} 23
   ```

5. Reparación: restaurá el binding y verificá la convergencia sin intervención adicional:

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name \
     | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|')
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole cluster-admin --serviceaccount="${SA}"

   sleep 60
   kubectl -n team-a get webapp broken-app
   ```

   ```
   NAME         SYNCED   READY   CONNECTION-SECRET   AGE
   broken-app   True     True                        2m
   ```

   Matá los `port-forward` en background antes de seguir: `kill %1 %2 2>/dev/null`.

### Preguntas

**4.1** — Con lo que mediste, proponé **dos SLIs concretos para la self-service API** de esta plataforma (con la métrica exacta de la que saldrían) y un SLO razonable para cada uno. Ninguno de los dos puede ser un SLI de workload.

**4.2** — En el paso 3, `SYNCED` quedó en `True` pero `READY` en `False`. ¿Qué mide cada columna exactamente, y por qué la distinción importa para decidir si la falla es de la plataforma o del recurso subyacente?

**4.3** — El error del paso 4 lo sufría el usuario ("mi app no levanta") pero la causa era de plataforma (RBAC del provider). ¿Qué mecanismo arquitectónico recomienda el white paper para que el usuario no tenga que hacer `kubectl describe` a tres niveles de profundidad? ¿Cómo lo implementarías sobre lo construido?

---

## Ejercicio 5 — Mapa de capacidades y madurez de tu mini-plataforma

Cerrás auditando lo construido contra los dos documentos de referencia del dominio: el [Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) (qué capacidades debe ofrecer una plataforma) y el [Platform Engineering Maturity Model](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/) (qué tan bien las ofrece). Este es exactamente el ejercicio que un platform architect hace con una plataforma real.

### Pasos

1. Construí la matriz de capacidades. Copiá esta tabla y completá las dos últimas columnas con lo hecho en los Ejercicios 1–4 (`✔` cubierta / `◐` parcial / `✘` ausente, más el componente que la implementa):

   | Capacidad (white paper) | Estado | Implementada por |
   |---|---|---|
   | Web portal para observar y provisionar | | |
   | APIs (y CLIs) de provisioning automático | | |
   | Golden path templates y docs | | |
   | Automation de build y test | | |
   | Automation de delivery y verification | | |
   | Development environments | | |
   | Observability (workloads y plataforma) | | |
   | Infrastructure services (compute, network, storage) | | |
   | Data services (DBs, caches, object stores) | | |
   | Messaging y event services | | |

2. Evaluá la madurez en dos de las dimensiones del Maturity Model. Para cada una, decidí en qué nivel está la mini-plataforma y anotá **la evidencia**:

   - **Interfaces** (¿cómo interactúan los usuarios?): de "custom processes por equipo" hasta "self-service integrado en el flujo del desarrollador".
   - **Operations** (¿quién opera lo provisionado?): de "cada equipo opera lo suyo a mano" hasta "la plataforma opera el ciclo de vida completo, upgrades incluidos".

3. Escribí el *next step* de mayor impacto: la única capacidad que agregarías el próximo trimestre, con una justificación de una línea basada en la matriz.

### Preguntas

**5.1** — El white paper propone empezar por la **"thinnest viable platform"** (TVP). ¿Nuestra mini-plataforma califica? ¿Qué criterio separa una TVP de "un montón de herramientas instaladas"?

**5.2** — Un arquitecto propone reemplazar todo lo construido por "acceso directo a `kubectl` + un repositorio de manifiestos de ejemplo bien documentados". ¿Qué capacidades del white paper sobreviven a ese diseño y cuáles se pierden? ¿En qué contexto organizacional esa propuesta sería, sin embargo, la correcta?

**5.3** — ¿Por qué el Maturity Model mide dimensiones como *Investment* y *Adoption* (organizacionales) además de las técnicas? ¿Qué modo de falla de plataformas reales captura eso que una matriz puramente técnica como la del paso 1 no ve?

---

## Limpieza

```bash
kind delete cluster --name cnpa-14
rm -rf kind-platform.yaml golden-path/
```

```
Deleting cluster "cnpa-14" ...
Deleted nodes: ["cnpa-14-control-plane" "cnpa-14-worker" "cnpa-14-worker2"]
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.1** — Un cluster recién creado provee solo la base de **infrastructure services**: compute runtime (kubelet + container runtime), programmable networking (CNI, Services) y block storage (CSI, la StorageClass `standard` de kind). Todo lo demás falta: no hay portal, no hay API de provisioning de nivel de dominio (solo primitivas: Deployment, Service…), no hay golden paths ni templates, no hay automation de build/delivery, no hay development environments gestionados, la observability se limita a `kubectl` y eventos (sin métricas agregadas ni dashboards), y no existen data services ni messaging services. Este es el argumento central del white paper: **Kubernetes es la fundación de una plataforma, no la plataforma** — el gap entre las primitivas y lo que un equipo de producto necesita es exactamente lo que el platform engineering llena.

**1.2** — Lo que define a un control plane es su **función**, no su ubicación: mantener un loop de reconciliation que compara estado deseado (declarado en una API) contra estado observado, y actúa para converger. Crossplane corre como Pods sobre workers — físicamente en el data plane de Kubernetes — pero funcionalmente es un control plane porque expone APIs declarativas (`WebApp`), almacena estado deseado en etcd vía el API server, y reconcilia continuamente. Es la misma relación que tiene `kube-controller-manager` con etcd: capas de control planes apiladas, cada una tratando a la inferior como su substrate. El patrón se repite hacia arriba: podés tener un management cluster cuyo único propósito es ser el platform control plane de una flota de clusters de workloads.

**1.3** — "Product, not project" implica, como mínimo: **(a) usuarios tratados como clientes** — la plataforma tiene interfaces diseñadas (APIs versionadas, portal, docs), no una wiki de instrucciones; se investiga qué necesitan los equipos antes de construir. **(b) Ciclo de vida continuo** — roadmap, versionado, deprecation policies, soporte; un proyecto termina, un producto se mantiene mientras tenga usuarios. **(c) Equipo propietario con financiamiento estable** — un platform team responsable de SLOs de la plataforma, no voluntarios de otros equipos. **(d) Adopción opcional y medida** — un producto compite por sus usuarios; si los equipos lo evitan, esa señal (adoption, en el maturity model) es el indicador de fracaso, cosa que un mandato corporativo enmascararía.

### Ejercicio 2

**2.1** —
- **XRD**: la posee el **platform team**. Es el **contrato público** de la API: define el vocabulario (`WebApp`), el schema y la validación. Es la interfaz entre ambos equipos, en el sentido estricto: lo único que un application team necesita conocer.
- **Composition**: la posee el **platform team**. Es la **implementación privada** del contrato: qué recursos concretos se crean y con qué configuración. Los application teams no la ven ni la referencian directamente; puede cambiar sin romperlos mientras el XRD se respete.
- **ProviderConfig** (y el binding RBAC): los posee el **platform team / operaciones**. Son las **credenciales y permisos** con los que la plataforma actúa; jamás se exponen a los consumidores — ese es el punto: el desarrollador provisiona sin poseer credenciales de infraestructura.
- **Claim (`WebApp`)**: lo posee el **application team**. Es la **solicitud self-service**, vive en su namespace y en su repositorio (idealmente aplicado por GitOps).

**2.2** — El claim namespaced permite aplicar **todo el aparato de multi-tenancy de Kubernetes** a la API de plataforma sin código adicional: RBAC (`team-a` solo puede crear `WebApp` en su namespace), ResourceQuota, y aislamiento de visibilidad entre equipos. El composite cluster-scoped existe porque la implementación puede necesitar recursos que trascienden el namespace del solicitante (recursos cloud, objetos en otros namespaces, configuración cluster-wide) y porque su ciclo de vida pertenece a la plataforma, no al tenant. La separación claim/XR es una frontera de privilegio: el usuario toca la cara namespaced de bajo privilegio; la plataforma opera la cara cluster-scoped de alto privilegio.

**2.3** — Un pipeline de CI/CD es **push y puntual**: actúa solo cuando se dispara (commit, cron, botón). Entre ejecuciones, nadie custodia el estado: un `kubectl delete` manual, un operador defectuoso o un upgrade que muta recursos pasan inadvertidos hasta el próximo run — y el próximo run podría incluso fallar sin que nadie mire. Un control plane es **reconciliation continua**: el estado deseado persiste en la API y un loop converge permanentemente hacia él, con lo cual protege contra *drift* (mutación fuera de banda), *borrado accidental* (paso 9) y *fallas transitorias* (reintenta con backoff hasta converger). El pipeline protege el momento del despliegue; el control plane protege todo el tiempo restante — que es casi todo el tiempo. Por eso la arquitectura de referencia moderna usa pipelines para *construir y proponer* estado deseado, y control planes (GitOps + Crossplane) para *mantenerlo*.

**2.4** — Cambia **solo la Composition** (y se agrega un `ProviderConfig` apuntando al kubeconfig del cluster remoto, con su Secret): el `Object` pasaría a referenciar `providerConfigRef: prod-cluster`. El XRD no cambia, por lo tanto **los claims de los equipos de aplicación no se tocan: cero**. Esa propiedad — evolucionar la implementación sin tocar a los consumidores — es la esencia de la capacidad **"APIs for automatically provisioning"** del white paper: la API es el contrato estable, la infraestructura de atrás es intercambiable. Es el mismo argumento por el que un cert puede empezar con un backend y terminar con otro: la interfaz fija desacopla.

### Ejercicio 3

**3.1** — El template cubre: **golden path templates y docs** (obviamente — el template *es* la capacidad, con `description`, defaults y validación como documentación ejecutable), parte de **web portal** (el formulario del scaffolder es la cara visible del portal; falta el catálogo desplegado en sí) y siembra la punta de **automation de build** (crea el repo donde un pipeline se engancharía). **Delega en el Ejercicio 2** el provisioning: el skeleton no contiene Deployments — contiene un claim `WebApp`; el template no sabe desplegar, sabe *pedir*. **Queda sin cubrir**: automation real de build/test y delivery (no hay pipeline CI), development environments, data/messaging services, y el despliegue del portal Backstage propiamente dicho con su catálogo y plugins.

**3.2** — Un golden path es **el camino más fácil, no el único**: pavimenta el caso común y deja salir al que lo necesita. Una golden cage bloquea toda desviación — y el efecto documentado es que los equipos con casos legítimos no cubiertos construyen shadow infrastructure por fuera, que es peor que la heterogeneidad que se quería evitar. La decisión de este ejercicio que preserva la salida: el template **genera archivos en un repositorio del equipo** (claim incluido) en lugar de provisionar de forma opaca. Un equipo puede editar el claim, agregar manifiestos propios o incluso no usar el template y escribir su claim a mano — porque la API `WebApp` es pública e independiente del portal. La capa de template y la capa de API están desacopladas: podés abandonar la primera sin perder la segunda.

**3.3** — `owner: group:platform-team` convierte el template en un producto con soporte: el platform team responde cuando el scaffolding falla, mantiene el skeleton actualizado (imágenes base, versiones del claim API, políticas de seguridad) y publica cambios con versionado y deprecation. El problema de los 40 servicios: un template estampa una **copia** del skeleton en cada repo; publicar la v2 no actualiza nada retroactivamente. Un producto maduro necesita estrategia para el stock existente — codemods/PRs automatizados hacia los repos generados, o mover cuanta más lógica posible **detrás de la API** (en la Composition), donde un cambio del platform team se propaga a todos los consumidores sin tocar sus repos. Regla práctica: el template debe contener el mínimo irreducible; todo lo que pueda vivir del lado de la plataforma, debe vivir ahí.

### Ejercicio 4

**4.1** — Ejemplos válidos (cualquier par bien fundado sirve):
- **Disponibilidad/corrección de la API de provisioning**: proporción de requests fallidos a la API de plataforma — `apiserver_request_total{group="platform.acme.io"}` filtrando `code=~"5.."` sobre el total. SLO ejemplo: **99.9% de requests sin error 5xx en 30 días**. Mide si los usuarios *pueden pedir*.
- **Salud de reconciliation**: tasa de error del motor — `controller_runtime_reconcile_total{result="error"}` sobre el total, por controller (`composite/...`, `managed/...`). SLO ejemplo: **< 1% de reconciles con error en ventana de 1 h**, con alerta si el error es sostenido. Mide si la plataforma *puede cumplir* lo pedido — el paso 3 mostró que puede degradarse con la API de escritura perfectamente sana.
- Alternativa igualmente buena: **provisioning lead time** — tiempo entre creación del claim y `Ready=True` (derivable de timestamps de condiciones), SLO tipo "p95 < 2 minutos". Es el equivalente plataforma del lead time de DORA.

**4.2** — `SYNCED` responde: ¿el control plane pudo **procesar** el recurso — encontrar su Composition, componer, persistir los recursos hijos deseados? `READY` responde: ¿el recurso subyacente alcanzó su condición de listo **en el mundo real**? El paso 3 dio `SYNCED=True, READY=False`: la maquinaria de composición funcionó (el problema no está en XRD/Composition/schema) pero el efecto externo falló (el provider no pudo crear el Deployment por RBAC). La distinción particiona el espacio de diagnóstico: `SYNCED=False` apunta a la capa de plataforma (Composition rota, function caída, referencia inválida); `SYNCED=True, READY=False` apunta a la capa de ejecución (permisos, recurso externo que no converge, dependencia ausente). Es la primera bifurcación del árbol de diagnóstico de un platform engineer.

**4.3** — El white paper pide que el portal ofrezca **observabilidad de lo provisionado en el mismo lugar donde se provisiona**: el usuario debería ver el estado y el motivo de la falla de su `WebApp` en la interfaz donde la creó, no excavando con `kubectl describe` por capas internas cuya existencia ni conoce. Sobre lo construido: (1) las **conditions ya se propagan** — el claim refleja `Ready=False` con `reason` y `message` heredados; el trabajo es de superficie: exponerlas. (2) En Backstage, el plugin de Kubernetes anclado a la annotation `backstage.io/kubernetes-id` (que el skeleton ya escribe) muestra el estado del claim y sus recursos en la página del componente. (3) Diseño de la Composition para que los mensajes de error que suben sean accionables por el usuario ("imagen inexistente") y los internos ("RBAC del provider") disparen alertas al platform team en lugar de filtrarse crudos al usuario. Principio: **el nivel de abstracción del error debe coincidir con el nivel de abstracción de la API** que el usuario consumió.

### Ejercicio 5

**Paso 1 (matriz de referencia)** —

| Capacidad | Estado | Implementada por |
|---|---|---|
| Web portal | ◐ | Template de Backstage autorado; portal/catálogo no desplegados |
| APIs de provisioning | ✔ | Crossplane: XRD + Composition (`WebApp`) |
| Golden path templates y docs | ✔ | `template.yaml` + skeleton con claim |
| Automation de build y test | ✘ | — |
| Automation de delivery y verification | ◐ | Reconciliation continua de Crossplane; sin pipeline CI ni verificación |
| Development environments | ✘ | — |
| Observability | ◐ | Métricas de apiserver y Crossplane consultadas a mano; sin stack de agregación ni dashboards |
| Infrastructure services | ✔ | Kubernetes (kind): compute, CNI, StorageClass |
| Data services | ✘ | — |
| Messaging/event services | ✘ | — |

**Paso 2 (evaluación razonable)** — *Interfaces*: nivel intermedio — existe una API self-service real con schema validado (más que "docs y ejemplos"), pero el portal no está operativo y parte del flujo fue manual (el `sed` del Ejercicio 3 simulando al scaffolder). *Operations*: nivel intermedio-alto para lo cubierto — la plataforma opera el ciclo de vida de lo provisionado (drift correction demostrada en 2.9 y 4.5), pero no hay gestión de upgrades de la plataforma misma ni de las abstracciones desplegadas. **Paso 3**: la respuesta defendible con la matriz es **automation de build/test + delivery** (CI que construya imagen y actualice el claim vía GitOps): es la única columna en `✘` que bloquea el flujo diario de un desarrollador; data services sería la segunda.

**5.1** — Califica como TVP en espíritu: hay **una** API, **un** golden path, y un usuario puede ir de cero a servicio corriendo por la vía pavimentada. El criterio que separa una TVP de "herramientas instaladas" no es la cantidad de componentes sino la **integración alrededor de un flujo de usuario completo**: una TVP cubre al menos un journey de punta a punta (crear → desplegar → observar), por delgado que sea, con interfaces diseñadas y un owner. Diez herramientas sin flujo integrado no son una plataforma delgada; son diez herramientas. El white paper recomienda TVP precisamente para validar adopción antes de invertir en amplitud — plataforma como producto: MVP primero.

**5.2** — Sobreviven: infrastructure services (el cluster sigue ahí) y una forma débil de golden path (los ejemplos documentados). Se pierden: la **API de dominio** (los usuarios vuelven a operar primitivas: cada equipo re-decide Deployment+Service+HPA+NetworkPolicy), el **límite de privilegio** (acceso `kubectl` amplio en lugar de un claim namespaced con RBAC fino), la **evolución centralizada** (un cambio de estándar = N pull requests a N repos en lugar de un cambio de Composition), y la **consistencia verificable** (los ejemplos se copian y divergen — drift por fotocopia). Contexto donde igual es lo correcto: organización chica (un puñado de equipos, todos con competencia Kubernetes sólida), dominio homogéneo y sin platform team financiado. El white paper es explícito en que la inversión en plataforma se justifica por la escala del problema de coordinación; construir un control plane para tres equipos expertos es sobre-ingeniería — y el maturity model diría que el nivel correcto de madurez es el que la organización necesita, no el máximo.

**5.3** — Porque el modo de falla dominante de las plataformas reales no es técnico: es la **plataforma técnicamente excelente que nadie usa** (se construyó sin investigar a los usuarios, se impuso por mandato, o su financiamiento murió al año y quedó huérfana — el "project" que nunca fue "product"). *Investment* captura si existe equipo y presupuesto sostenidos; *Adoption* captura si los usuarios la eligen — y la adopción voluntaria es la única métrica que no se puede falsear con un mandato. Una matriz técnica como la del paso 1 daría 10/10 a una plataforma completa con cero usuarios; el maturity model existe para que ese caso se vea como lo que es: un fracaso de producto con excelente ingeniería.

</details>

---

## Fuentes

- CNCF Platforms White Paper — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Crossplane: Composite Resources y Compositions — https://docs.crossplane.io/latest/concepts/composite-resources/ y https://docs.crossplane.io/latest/concepts/compositions/
- provider-kubernetes — https://github.com/crossplane-contrib/provider-kubernetes
- Backstage Software Templates — https://backstage.io/docs/features/software-templates/
- Kubernetes: Cluster Architecture — https://kubernetes.io/docs/concepts/architecture/
- kind — https://kind.sigs.k8s.io/docs/user/quick-start/