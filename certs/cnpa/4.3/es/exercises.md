# Ejercicios guiados — Tema 4.3: Infrastructure Provisioning with Kubernetes (Crossplane/Kratix)

> **Certificación:** CNPA (examen 2025-04-01) · **Peso:** 3.0
> **Objetivo:** provisionar infraestructura usando la API de Kubernetes como control plane. Vas a construir abstracciones de plataforma con **Crossplane** (reconciliación declarativa vía Managed Resources y Compositions) y con **Kratix** (Promises + pipelines imperativos sobre un modelo GitOps).
>
> **Requisitos del lab:** un cluster desechable ([`kind`](https://kind.sigs.k8s.io/) o `minikube`), `kubectl` ≥ 1.28, `helm` ≥ 3.12 y salida a Internet para bajar packages. Ninguna credencial cloud: usamos `provider-kubernetes`, así todo lo que provisionás es observable en el mismo cluster y no cuesta dinero.
>
> Ejecutá los bloques en orden; cada uno deja estado que el siguiente reutiliza.

---

## Bloque 0 — Preparar el control plane

Levantamos un cluster limpio que va a hacer de **management cluster** (control plane de plataforma).

```bash
# 1. Cluster desechable
kind create cluster --name cnpa-43 --wait 120s

# 2. Instalar la CLI de Crossplane (kubectl plugin + binario `crossplane`)
curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh
sudo mv crossplane /usr/local/bin/
crossplane version
```

```bash
# 3. Instalar Crossplane vía Helm en su propio namespace
kubectl create namespace crossplane-system
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane \
  --namespace crossplane-system \
  crossplane-stable/crossplane \
  --version 1.18.0
```

```bash
# 4. Verificar el core
kubectl get pods -n crossplane-system
```

Salida esperada (los dos Deployments del core: el controller y el RBAC manager):

```
NAME                                       READY   STATUS    RESTARTS   AGE
crossplane-6d9f7c8b4-abcde                 1/1     Running   0          40s
crossplane-rbac-manager-7c9b6d5f4-fghij    1/1     Running   0          40s
```

```bash
# 5. Ver los CRDs base que Crossplane registra
kubectl get crds | grep crossplane.io | head
```

```
compositeresourcedefinitions.apiextensions.crossplane.io   2026-08-07T...
compositions.apiextensions.crossplane.io                   2026-08-07T...
functions.pkg.crossplane.io                                2026-08-07T...
providers.pkg.crossplane.io                                2026-08-07T...
```

**Preguntas de comprensión (Bloque 0)**

1. Crossplane no provisiona nada por sí solo tras el `helm install`. ¿Qué componente hace falta instalar aparte para que aparezcan CRDs de recursos concretos (buckets, bases de datos, namespaces), y por qué ese diseño es *pluggable*?
2. ¿Qué diferencia hay entre el pod `crossplane` y `crossplane-rbac-manager`? ¿Qué problema resuelve el segundo cuando instalás Providers y XRDs nuevos?
3. En este lab el cluster de `kind` cumple dos roles a la vez. ¿Cuáles son, y por qué en producción los separarías?

---

## Bloque 1 — Instalar un Provider y su ProviderConfig

Un **Provider** es un package (imagen OCI `xpkg`) que trae un controller y un set de CRDs de **Managed Resources**. Instalamos `provider-kubernetes`, que gestiona objetos de Kubernetes como si fueran infraestructura externa.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.15.0
EOF
```

```bash
# Esperar a que el package se instale y quede sano
kubectl get providers
```

```
NAME                  INSTALLED   HEALTHY   PACKAGE                                                              AGE
provider-kubernetes   True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.15.0       55s
```

El controller del provider corre con una **ServiceAccount** propia. Para que pueda crear objetos en *este* cluster (identidad inyectada), hay que darle permisos:

```bash
# Descubrir la SA del provider y bindearla (lab: cluster-admin; en prod, mínimo privilegio)
SA=$(kubectl -n crossplane-system get sa -o name \
  | grep provider-kubernetes \
  | sed -e 's|serviceaccount/|crossplane-system:|g')
kubectl create clusterrolebinding provider-kubernetes-admin \
  --clusterrole cluster-admin \
  --serviceaccount="${SA}"
```

```bash
# Un ProviderConfig le dice al provider CÓMO autenticarse. InjectedIdentity = la SA del pod.
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

**Preguntas de comprensión (Bloque 1)**

1. `INSTALLED=True` y `HEALTHY=True` significan cosas distintas. ¿Qué valida cada una, y qué escenario deja `INSTALLED=True` pero `HEALTHY=False`?
2. Separá conceptualmente **Provider**, **ProviderConfig** y **Managed Resource**. ¿Por qué el ProviderConfig es un objeto aparte y no un campo dentro de cada Managed Resource?
3. Con un provider cloud real (p. ej. `provider-aws`), `source: InjectedIdentity` normalmente se reemplaza por `source: Secret` o por IRSA/Workload Identity. ¿Qué riesgo de seguridad introduce guardar credenciales cloud en un `Secret` del management cluster, y qué alternativa lo mitiga?

---

## Bloque 2 — Managed Resource: reconciliación 1:1

Un **Managed Resource (MR)** representa *una* pieza de infraestructura externa y mapea 1:1 contra ella. Creamos un `Object` que gestiona un `Namespace`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: Object
metadata:
  name: demo-namespace
spec:
  forProvider:
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: crossplane-demo
        labels:
          managed-by: crossplane
  providerConfigRef:
    name: default
EOF
```

```bash
kubectl get objects
```

```
NAME             SYNCED   READY   AGE
demo-namespace   True     True    12s
```

```bash
# El Namespace fue creado por el controller, no por vos:
kubectl get ns crossplane-demo --show-labels
```

```
NAME              STATUS   AGE   LABELS
crossplane-demo   Active   15s   kubernetes.io/metadata.name=crossplane-demo,managed-by=crossplane
```

Ahora **probá la reconciliación**: borrá el objeto externo a mano y observá cómo Crossplane lo recrea.

```bash
kubectl delete ns crossplane-demo
sleep 8
kubectl get ns crossplane-demo
```

```
NAME              STATUS   AGE
crossplane-demo   Active   3s     # <-- recreado: el estado deseado es la MR
```

Inspeccioná las `conditions` de la MR (el mecanismo con el que Crossplane comunica estado):

```bash
kubectl get object demo-namespace -o jsonpath='{.status.conditions}' | jq
```

```json
[
  { "type": "Synced", "status": "True", "reason": "ReconcileSuccess" },
  { "type": "Ready",  "status": "True", "reason": "Available" }
]
```

**Preguntas de comprensión (Bloque 2)**

1. `SYNCED` y `READY` son las dos conditions clave de toda Managed Resource. Definí qué garantiza cada una. Si un `Object` muestra `SYNCED=True, READY=False`, ¿qué está pasando?
2. Recreaste el Namespace borrándolo. Explicá el **control loop** que produjo ese comportamiento: ¿de dónde saca Crossplane el estado deseado y con qué frecuencia lo compara contra el estado observado?
3. La regla CLAUDE del repo dice "nunca persistir texto crudo". Acá `spec.forProvider.manifest` guarda el manifiesto embebido. ¿Qué implica eso para `kubectl delete object`? ¿Qué controla `spec.deletionPolicy` (`Delete` vs `Orphan`) y cuándo elegirías cada uno?

---

## Bloque 3 — Definir tu propia API de plataforma: XRD + Composition + Claim

Acá está el corazón de Crossplane como *platform engineering*: exponés una API de alto nivel a tus desarrolladores y ocultás los MRs. Tres piezas:

- **XRD** (`CompositeResourceDefinition`): define el *esquema* de tu API (el XR cluster-scoped y su Claim namespaced).
- **Composition**: define *cómo* se materializa ese XR en Managed Resources concretos.
- **Composition Function**: el motor que ejecuta la Composition (pipeline). Instalamos `function-patch-and-transform`.

### 3.1 — Instalar la function

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
EOF

kubectl get functions
```

```
NAME                           INSTALLED   HEALTHY   PACKAGE                                                                       AGE
function-patch-and-transform   True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0        30s
```

### 3.2 — El XRD (la API que verá el desarrollador)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xapps.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XApp
    plural: xapps
  claimNames:
    kind: App
    plural: apps
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
                    environment:
                      type: string
                      enum: ["dev", "staging", "prod"]
                    team:
                      type: string
                  required: ["environment", "team"]
              required: ["parameters"]
            status:
              type: object
              properties:
                namespaceName:
                  type: string
EOF
```

### 3.3 — La Composition (cómo se materializa el XApp)

Componemos **dos** Managed Resources: un `Namespace` y un `ConfigMap` dentro de él, con valores parcheados desde los `parameters` del Claim.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xapps.platform.acme.io
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XApp
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          # ---- Managed Resource 1: Namespace ----
          - name: app-namespace
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha1
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: Namespace
                    metadata: {}
                providerConfigRef:
                  name: default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.team
                toFieldPath: spec.forProvider.manifest.metadata.name
                transforms:
                  - type: string
                    string:
                      fmt: "team-%s"
              # Publica el nombre calculado de vuelta al status del XR
              - type: ToCompositeFieldPath
                fromFieldPath: spec.forProvider.manifest.metadata.name
                toFieldPath: status.namespaceName
          # ---- Managed Resource 2: ConfigMap ----
          - name: app-config
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha1
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: ConfigMap
                    metadata:
                      name: app-metadata
                    data: {}
                providerConfigRef:
                  name: default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.team
                toFieldPath: spec.forProvider.manifest.metadata.namespace
                transforms:
                  - type: string
                    string:
                      fmt: "team-%s"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.environment
                toFieldPath: spec.forProvider.manifest.data.environment
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.team
                toFieldPath: spec.forProvider.manifest.data.team
EOF
```

**Preguntas de comprensión (Bloque 3)**

1. Un **XR** (Composite Resource) es cluster-scoped y su **Claim** es namespaced. ¿Por qué Crossplane ofrece ambos, y cuál es el que le das a un desarrollador de aplicaciones? ¿Qué rol cumple `referenceable: true` en la versión del XRD?
2. En la Composition usaste `FromCompositeFieldPath` y `ToCompositeFieldPath`. Explicá la **dirección** de cada uno y por qué el `ToCompositeFieldPath` hacia `status.namespaceName` es útil para el consumidor de la API.
3. `mode: Pipeline` con una Function reemplazó al viejo modo "Resources" nativo. ¿Qué ventaja arquitectónica aporta ejecutar Compositions como un *pipeline de functions* en lugar de patches estáticos embebidos? Nombrá otra function que podrías encadenar y para qué.

---

## Bloque 4 — Consumir la abstracción: crear un Claim

Ahora actuás como el **desarrollador**. No sabés nada de `provider-kubernetes` ni de Objects: solo usás la API `App`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.acme.io/v1alpha1
kind: App
metadata:
  name: checkout
  namespace: default
spec:
  parameters:
    environment: dev
    team: payments
EOF
```

```bash
kubectl get app checkout
```

```
NAME       SYNCED   READY   CONNECTION-SECRET   AGE
checkout   True     True                        20s
```

```bash
# El Claim creó un XR cluster-scoped, que creó 2 Objects, que crearon 2 recursos K8s reales:
kubectl get xapp
kubectl get objects
kubectl get ns team-payments
kubectl get configmap app-metadata -n team-payments -o jsonpath='{.data}' | jq
```

```
NAME             SYNCED   READY   COMPOSITION              AGE
checkout-7q2x9   True     True    xapps.platform.acme.io   25s

NAME                     SYNCED   READY   AGE
checkout-7q2x9-abc12     True     True    25s
checkout-7q2x9-def34     True     True    25s

NAME            STATUS   AGE
team-payments   Active   25s

{ "environment": "dev", "team": "payments" }
```

```bash
# El status calculado volvió al XR/Claim:
kubectl get xapp -o jsonpath='{.items[0].status.namespaceName}'
# -> team-payments
```

**Preguntas de comprensión (Bloque 4)**

1. Trazá la **cadena de propiedad** completa: `App` (Claim) → `XApp` (XR) → `Object` (MR) → recurso real. ¿Qué mecanismo de Kubernetes (`ownerReferences`) garantiza que al borrar el Claim se limpie todo hacia abajo?
2. El campo `CONNECTION-SECRET` salió vacío. En un caso real (una base de datos compuesta) ese secret llevaría host/usuario/password. ¿Cómo llegan esos valores desde los MRs hasta un Secret en el namespace del Claim, y por qué eso desacopla al desarrollador de dónde vive la infraestructura?
3. El nombre del XR es `checkout-7q2x9`, no `checkout`. ¿Por qué Crossplane le agrega un sufijo aleatorio al XR generado desde un Claim?

---

## Bloque 5 — Diagnóstico avanzado con `crossplane beta trace`

Cuando la cadena tiene 4 niveles, `kubectl describe` por objeto no escala. La CLI trae un visor de árbol.

```bash
crossplane beta trace app.platform.acme.io/checkout -n default
```

```
NAME                              SYNCED   READY   STATUS
App/checkout (default)            True     True
└─ XApp/checkout-7q2x9            True     True
   ├─ Object/checkout-7q2x9-abc12 True     True    Available
   └─ Object/checkout-7q2x9-def34 True     True    Available
```

Ahora **rompé la abstracción a propósito** para practicar el diagnóstico: quitá el ClusterRoleBinding del provider y forzá una reconciliación.

```bash
kubectl delete clusterrolebinding provider-kubernetes-admin

# Forzar re-reconcile tocando el XApp (annotation cosmética)
kubectl annotate app checkout -n default debug/kick="$(date +%s)" --overwrite
sleep 10
crossplane beta trace app.platform.acme.io/checkout -n default
```

```
NAME                              SYNCED   READY   STATUS
App/checkout (default)            True     False
└─ XApp/checkout-7q2x9            True     False
   ├─ Object/checkout-7q2x9-abc12 False    True    ReconcileError: cannot ... forbidden
   └─ Object/checkout-7q2x9-def34 False    True    ReconcileError: cannot ... forbidden
```

```bash
# Confirmar la causa raíz en los events de un MR:
kubectl describe object checkout-7q2x9-abc12 | sed -n '/Events/,$p'
```

```
Events:
  Type     Reason                   Age   From                     Message
  ----     ------                   ----  ----                     -------
  Warning  CannotObserveObject      8s    kubernetes/object        namespaces is forbidden: User "system:serviceaccount:crossplane-system:provider-kubernetes-..." cannot get resource "namespaces"
```

Restaurá el binding y verificá la recuperación automática:

```bash
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|g')
kubectl create clusterrolebinding provider-kubernetes-admin --clusterrole cluster-admin --serviceaccount="${SA}"
sleep 10
crossplane beta trace app.platform.acme.io/checkout -n default   # vuelve a True/True
```

**Preguntas de comprensión (Bloque 5)**

1. Al romper el RBAC, `SYNCED` pasó a `False` pero `READY` seguía `True` unos segundos. Explicá por qué: ¿qué "verdad" temporal representa `READY=True` cuando `SYNCED=False`, y por qué esa combinación es una señal de *drift* peligrosa en producción?
2. El error de fondo apareció en los **Events del Managed Resource**, no en el Claim. Describí la estrategia de diagnóstico correcta en Crossplane: ¿por qué siempre bajás desde el Claim hacia los MRs y no al revés?
3. No reiniciaste ningún pod para recuperarte: bastó recrear el binding. ¿Qué propiedad del modelo de reconciliación hace que la recuperación sea automática y qué implica esto para la operación de una plataforma (self-healing)?

---

## Bloque 6 — Kratix: Promises y pipelines imperativos

Kratix ataca el mismo problema (dar APIs de plataforma) con una filosofía distinta: en vez de reconciliación declarativa de MRs, ejecuta **pipelines** (contenedores) que *generan* manifiestos y los distribuye por **GitOps** a los clusters destino. La unidad de empaquetado es la **Promise**.

Una Promise tiene tres partes:

- `spec.api` — un CRD: la API que ofrecés (p. ej. `App`).
- `spec.dependencies` — recursos que se instalan en la plataforma al aplicar la Promise (operators, CRDs, etc.).
- `spec.workflows` — pipelines que corren cuando se instala la Promise (`promise.configure`) o cuando llega un **Resource Request** (`resource.configure`).

### 6.1 — Instalar Kratix

```bash
# Dependencia: cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s

# Core de Kratix
kubectl apply -f https://raw.githubusercontent.com/syntasso/kratix/main/distribution/kratix.yaml
kubectl wait --for=condition=Available deployment -n kratix-platform-system --all --timeout=180s
```

> El State Store (MinIO/S3 o Git), el/los **Destination** y **Flux** que sincroniza los outputs se configuran siguiendo el quick-start oficial (single-cluster). Ver <https://kratix.io/docs/main/quick-start>. En este bloque el foco es el **flujo Promise → Resource Request → Pipeline → output**, que es lo evaluable.

### 6.2 — Escribir y aplicar una Promise

Esta Promise expone una API `App` cuyo pipeline **genera un Deployment** a partir de la imagen que pida el usuario. El pipeline es un contenedor auto-contenido (no hay que buildear nada).

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.kratix.io/v1alpha1
kind: Promise
metadata:
  name: app
spec:
  api:
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: apps.example.promise.acme.io
    spec:
      group: example.promise.acme.io
      scope: Namespaced
      names:
        kind: App
        plural: apps
        singular: app
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
                    image:
                      type: string
                  required: ["image"]
  workflows:
    resource:
      configure:
        - apiVersion: platform.kratix.io/v1alpha1
          kind: Pipeline
          metadata:
            name: instance-configure
          spec:
            containers:
              - name: create-deployment
                image: mikefarah/yq:4
                command: ["sh", "-c"]
                args:
                  - |
                    name=$(yq '.metadata.name'  /kratix/input/object.yaml)
                    img=$(yq  '.spec.image'      /kratix/input/object.yaml)
                    cat > /kratix/output/deployment.yaml <<YAML
                    apiVersion: apps/v1
                    kind: Deployment
                    metadata:
                      name: ${name}
                    spec:
                      replicas: 2
                      selector:
                        matchLabels: { app: ${name} }
                      template:
                        metadata:
                          labels: { app: ${name} }
                        spec:
                          containers:
                            - name: ${name}
                              image: ${img}
                    YAML
EOF
```

```bash
# La Promise instaló el CRD "App" en el cluster
kubectl get promises
kubectl get crds | grep example.promise.acme.io
```

```
NAME   STATUS      KIND   API VERSION                       VERSION   AGE
app    Available   App    example.promise.acme.io/v1        v1        30s

apps.example.promise.acme.io   2026-08-07T...
```

### 6.3 — Hacer un Resource Request y observar el pipeline

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: example.promise.acme.io/v1
kind: App
metadata:
  name: web
  namespace: default
spec:
  image: nginx:1.27
EOF
```

```bash
# Kratix lanza un Job/Pod con tu contenedor. Miralo:
kubectl get pods -l kratix.io/promise-name=app
kubectl get works,workplacements -A
```

```
NAME                                  READY   STATUS      RESTARTS   AGE
web-instance-configure-abc12-xyz      0/1     Completed   0          18s

NAME                                        AGE
work.platform.kratix.io/app-web-...         18s
workplacement.platform.kratix.io/app-web-.. 15s
```

El contenedor leyó el request en `/kratix/input/object.yaml` y escribió `deployment.yaml` en `/kratix/output/`. Kratix envolvió ese output en un **Work**, el **Scheduler** lo colocó en un **Destination** (creando un **WorkPlacement**), y Flux lo aplicó. Verificá el resultado:

```bash
kubectl get deployment web
```

```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    2/2     2            2           40s
```

**Preguntas de comprensión (Bloque 6)**

1. Describí el **contrato del pipeline** de Kratix: ¿qué recibe el contenedor en `/kratix/input/`, dónde escribe los manifiestos de salida, y para qué sirve el directorio `/kratix/metadata/` (p. ej. `destination-selectors.yaml`)?
2. En Kratix la salida del pipeline **no** se aplica directamente al cluster: se convierte en un **Work**, el Scheduler lo asigna a un **Destination** (WorkPlacement) y **Flux** lo sincroniza desde el State Store. ¿Qué gana la plataforma al meter GitOps entre la generación del manifiesto y su aplicación?
3. Diferenciá los dos workflows de una Promise: `promise.configure` vs `resource.configure`. ¿Cuál usarías para instalar un operator del que dependen todas las instancias, y cuál para materializar cada instancia pedida?

---

## Bloque 7 — Crossplane vs Kratix: elegir la herramienta

No compiten frontalmente; resuelven "self-service de infraestructura sobre Kubernetes" con modelos opuestos. Compará ejecutando mentalmente lo que construiste.

| Eje | Crossplane | Kratix |
|---|---|---|
| Modelo | Reconciliación declarativa continua de Managed Resources | Pipelines imperativos que **generan** manifiestos una vez por evento |
| Drift | Detectado y corregido de forma continua (self-healing, Bloque 5) | El output es GitOps: el drift lo corrige Flux/Argo, no Kratix |
| Lenguaje de la lógica | Compositions + Functions (patch-and-transform, Go templating, KCL, Python) | **Cualquier** lenguaje: el pipeline es un contenedor arbitrario |
| Distribución multi-cluster | El control plane provisiona directo vía providers | Nativa: Scheduler + Destinations + State Store |
| "Batteries" de una API | XRD (schema) + Composition (materialización) | Promise = API + dependencies + workflows en un objeto |

**Preguntas de comprensión (Bloque 7)**

1. Un equipo necesita provisionar RDS, S3 y una VPC con **corrección continua de drift** y estado siempre reconciliado contra la nube. ¿Crossplane o Kratix? Justificá con lo que viste en el Bloque 5.
2. Otro equipo necesita empaquetar un flujo que corre `terraform apply`, luego un script Python que registra el recurso en un CMDB, y finalmente distribuye manifiestos a 3 clusters por región. ¿Qué herramienta encaja mejor y por qué el modelo de pipeline lo hace más natural?
3. ¿Es sensato **combinar** ambos? Describí un patrón donde una **Promise de Kratix** entregue como dependency/output objetos de **Crossplane** (XRDs/Claims). ¿Qué aporta cada capa en ese diseño?

---

## Limpieza

```bash
kind delete cluster --name cnpa-43
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

1. **Falta instalar un `Provider`.** El core de Crossplane solo trae la maquinaria de packaging (Providers, Functions, Configurations) y el motor de composición (XRDs, Compositions); no conoce ningún recurso concreto. Cada Provider es un package OCI que aporta su propio controller y sus CRDs de Managed Resources. El diseño es *pluggable* precisamente para que el core sea estable y agnóstico: agregás capacidades (AWS, GCP, Kubernetes, Helm, SQL…) instalando packages sin tocar el core, y podés versionarlos/actualizarlos de forma independiente.
2. El pod `crossplane` corre el **reconciliador principal** (packages, composición, MRs). El `crossplane-rbac-manager` **genera automáticamente los ClusterRoles/Bindings** que el core y los controllers necesitan cuando aparecen CRDs nuevos (al instalar un Provider o crear un XRD). Sin él tendrías que escribir RBAC a mano cada vez que agregás una API — resuelve el problema de que las APIs de Crossplane son dinámicas.
3. Hace de **management/control plane** (corre Crossplane y sus controllers) y a la vez de **workload/target cluster** (aloja los recursos que provisionamos vía `provider-kubernetes`). En producción se separan porque el control plane debe ser un cluster endurecido, de larga vida, con las credenciales de provisioning, mientras que los targets son efímeros/multi-tenant; mezclarlos concentra el radio de explosión y las credenciales cloud en el mismo lugar donde corren cargas de terceros.

### Bloque 1

1. `INSTALLED=True` significa que el package **se descargó, se resolvió y sus CRDs quedaron registrados**. `HEALTHY=True` significa que el **Deployment del controller del provider está corriendo y sano**. Un package cuya imagen del controller no arranca (imagen inexistente, `CrashLoopBackOff`, falta de recursos) queda `INSTALLED=True, HEALTHY=False`.
2. **Provider** = el software (controller + CRDs) que sabe hablar con un backend. **ProviderConfig** = *cómo* autenticar/qué endpoint usar (una config nombrada, reutilizable). **Managed Resource** = una instancia concreta de infraestructura que referencia un ProviderConfig. Se separa el ProviderConfig para poder tener **varias credenciales/cuentas** (p. ej. `dev`, `prod`, distintas regiones) y que cada MR elija cuál usar vía `providerConfigRef`, sin repetir credenciales en cada recurso.
3. Un `Secret` con credenciales cloud en el management cluster es un objetivo de alto valor: cualquiera con lectura de Secrets en ese namespace obtiene acceso al cloud. Lo mitigás con **identidad federada sin secretos de larga vida**: IRSA (AWS), Workload Identity (GCP) o Azure Workload Identity, donde el pod del provider asume un rol vía OIDC y las credenciales son temporales y rotadas automáticamente.

### Bloque 2

1. `SYNCED` = Crossplane **pudo comunicar el estado deseado al backend** (la última reconciliación no dio error). `READY` = **el recurso externo existe y está operativo/disponible**. `SYNCED=True, READY=False` es normal durante el aprovisionamiento (la API aceptó la orden pero el recurso todavía se está creando, p. ej. una DB que tarda minutos).
2. El controller ejecuta un **control loop**: lee el estado deseado desde `spec.forProvider` de la MR (fuente de verdad), **observa** el estado real en el backend, y si difieren, **actúa** (create/update). Corre continuamente (por watch + un intervalo de re-sync, por defecto ~1 min). Al borrar el Namespace, la próxima observación detectó ausencia y el loop lo recreó.
3. La MR **es** la fuente de verdad, así que `kubectl delete object` dispara `deletionPolicy`. Con `Delete` (default) borra también el recurso externo; con `Orphan` deja el recurso externo vivo y solo remueve la MR. Elegís `Orphan` cuando querés dejar de gestionar algo sin destruirlo (migraciones, recursos con datos), y `Delete` para ciclo de vida completo/efímero.

### Bloque 3

1. El **XR** es la representación cluster-scoped y "cruda" del recurso compuesto; el **Claim** es su proyección namespaced, sujeta a RBAC por namespace y multi-tenancy. Al desarrollador de aplicaciones le das el **Claim** (`App`), no el XR. `referenceable: true` marca la versión del XRD que puede ser referenciada por Compositions (y usada como tipo del XR); es obligatorio para que una Composition pueda apuntar a esa versión.
2. `FromCompositeFieldPath` copia **del XR hacia el MR** (parámetros del usuario → configuración del recurso). `ToCompositeFieldPath` copia **del MR hacia el status del XR** (valores calculados/observados → API pública). Publicar `status.namespaceName` es útil porque el consumidor descubre el nombre real generado (`team-payments`) sin conocer la mecánica interna: se vuelve parte del contrato.
3. El modo Pipeline convierte la lógica de composición en **funciones componibles y versionadas**, ejecutables en secuencia, en vez de patches estáticos limitados a copiar/transformar campos. Ganás: lógica arbitraria (condicionales, loops, llamadas externas), testing independiente de cada función, y reutilización. Otra function encadenable: `function-auto-ready` (para derivar la readiness del XR de sus recursos), `function-go-templating` o `function-kcl`/`function-python` (para generar recursos con lógica de template completa).

### Bloque 4

1. `App` (Claim, namespaced) es dueño del `XApp` (XR, cluster-scoped) vía `resourceRef`/`claimRef`; el `XApp` es dueño de los dos `Object` (MRs) vía `ownerReferences`; cada `Object` gestiona su recurso real y lo limpia según `deletionPolicy`. Las **`ownerReferences`** activan el **garbage collection en cascada** de Kubernetes: borrar el Claim propaga el borrado hacia abajo (con `compositeDeletePolicy`/foreground se espera a que terminen).
2. Los MRs escriben sus **connection details** (endpoints, credenciales generadas) que la Composition agrega y publica en un **connection Secret**; Crossplane lo **proyecta al namespace del Claim** con el nombre indicado en `spec.writeConnectionSecretToRef`. Así el desarrollador consume host/usuario/password desde un Secret local **sin saber** en qué cloud/región vive la base: la abstracción desacopla consumo de emplazamiento.
3. Un Claim puede regenerarse/recrearse y podría haber varios XRs asociados a lo largo del tiempo; el **sufijo aleatorio** garantiza nombres únicos a nivel cluster para los XRs (que son cluster-scoped) y evita colisiones entre Claims homónimos en distintos namespaces.

### Bloque 5

1. `READY=True` reflejaba que los recursos **seguían existiendo y disponibles** en el cluster (verdad observada hasta ese momento), mientras `SYNCED=False` indicaba que Crossplane **ya no podía reconciliar** (RBAC denegado). Esa combinación es peligrosa porque significa "el recurso está vivo pero **ya no lo controlo**": cualquier cambio deseado no se aplica y el drift crece silenciosamente hasta que algo se rompe.
2. Los Claims/XRs agregan estado pero la **causa raíz vive en el MR**, que es quien habla con el backend y emite el error real en sus `conditions`/Events. Por eso la estrategia correcta es **descender**: `crossplane beta trace` desde el Claim para ver qué nivel está en rojo, y luego `kubectl describe` del MR concreto para leer el mensaje del provider. Ir al revés te haría adivinar.
3. La recuperación es automática porque el modelo es de **reconciliación continua sin estado imperativo**: el controller reintenta el loop periódicamente; en cuanto el permiso volvió, la siguiente observación tuvo éxito y convergió. Para operar una plataforma esto significa **self-healing**: no necesitás reiniciar pods ni re-aplicar manifiestos tras un fallo transitorio (RBAC, red, rate limit) — el sistema se cura solo cuando la causa desaparece.

### Bloque 6

1. El contenedor recibe el objeto del Resource Request completo en **`/kratix/input/object.yaml`** (y otros inputs en ese directorio). Escribe los manifiestos que debe distribuir en **`/kratix/output/`** (todo lo que quede ahí se convierte en un Work). **`/kratix/metadata/`** lleva metadatos que Kratix interpreta: `destination-selectors.yaml` (a qué Destinations enrutar el output vía labels) y `status.yaml` (para reflejar estado en el Resource Request).
2. Meter GitOps entre generación y aplicación aporta: **auditoría e historial** (todo output queda versionado en el State Store), **reconciliación/anti-drift** delegada a Flux/Argo en cada destino, **distribución multi-cluster** desacoplada (el pipeline no necesita acceso a los targets, solo escribe al store), y **separación de responsabilidades** (el pipeline decide *qué*, el GitOps decide *cuándo/dónde se aplica*).
3. `promise.configure` corre **una vez al instalar/actualizar la Promise**: ideal para instalar dependencias compartidas (un operator, CRDs, un namespace base). `resource.configure` corre **por cada Resource Request**: ahí materializás la instancia concreta que pidió el usuario. El operator compartido → `promise.configure`; el Deployment por instancia → `resource.configure`.

### Bloque 7

1. **Crossplane.** Su fuerte es la reconciliación declarativa continua: mantiene RDS/S3/VPC alineados con `spec.forProvider` y corrige drift automáticamente (lo viste en el Bloque 5: recreó el Namespace y se recuperó solo tras el fallo de RBAC). Kratix generaría los manifiestos una vez y delegaría la corrección de drift a GitOps, pero no modela el estado del recurso cloud como objeto reconciliado 1:1.
2. **Kratix.** El pipeline es un **contenedor arbitrario**, así que encadenar `terraform apply` + un script Python contra un CMDB + distribución multi-región es natural: cada paso es una imagen, la salida se enruta a Destinations por labels y GitOps la aplica en cada región. En Crossplane tendrías que envolver todo eso en providers/functions, y la lógica imperativa con efectos externos (CMDB) no encaja en el modelo declarativo.
3. Sí, es un patrón real y potente: una **Promise de Kratix** puede traer en `dependencies` los XRDs/Compositions/Providers de Crossplane (bootstrap de la capacidad) y su `resource.configure` puede **emitir Claims de Crossplane** como output. Kratix aporta el empaquetado de la API de plataforma, los workflows imperativos y la distribución GitOps multi-cluster; Crossplane aporta la reconciliación continua y el self-healing del recurso cloud subyacente. Cada capa hace lo que mejor hace.

</details>

---

### Fuentes

- CNCF CNPA Curriculum — <https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf>
- Crossplane — Concepts (Providers, Managed Resources, ProviderConfig) — <https://docs.crossplane.io/latest/concepts/>
- Crossplane — Composite Resource Definitions — <https://docs.crossplane.io/latest/concepts/composite-resource-definitions/>
- Crossplane — Compositions — <https://docs.crossplane.io/latest/concepts/compositions/>
- Crossplane — Composition Functions — <https://docs.crossplane.io/latest/concepts/composition-functions/>
- Crossplane — CLI reference (`beta trace`) — <https://docs.crossplane.io/latest/cli/command-reference/>
- provider-kubernetes — <https://github.com/crossplane-contrib/provider-kubernetes>
- function-patch-and-transform — <https://github.com/crossplane-contrib/function-patch-and-transform>
- Kratix — Main concepts — <https://kratix.io/docs/main/main-concepts>
- Kratix — Promises (intro y estructura) — <https://kratix.io/docs/main/reference/promises/intro>
- Kratix — Quick start (State Store, Destinations, Flux) — <https://kratix.io/docs/main/quick-start>