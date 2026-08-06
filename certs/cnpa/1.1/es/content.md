# 1.1 — Declarative Resource Management and Infrastructure Concepts

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión 2025-04-01
> **Peso en el examen:** 7.2 %
> **Dominio:** Platform Engineering Core Fundamentals

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema: infraestructura imperativa y *configuration drift*

En una operación imperativa, el estado del sistema es el resultado acumulado de una secuencia de comandos ejecutados por humanos o scripts: `kubectl scale`, `kubectl edit`, un `ssh` seguido de un `systemctl restart`, un cambio manual en la consola del cloud provider. Este modelo tiene cuatro fallas estructurales que en producción se pagan caras:

1. **No hay fuente de verdad.** El estado real vive únicamente en el sistema en ejecución. Si el cluster se pierde, la única "documentación" del estado era el cluster mismo. El *disaster recovery* se convierte en arqueología.
2. **Configuration drift.** Cada intervención manual (`kubectl edit` a las 3 AM durante un incidente) crea una divergencia entre lo que el equipo *cree* que está desplegado y lo que *realmente* está desplegado. El drift es invisible hasta que rompe algo: el clásico "en staging funciona" suele ser drift no detectado en producción.
3. **Operaciones no idempotentes.** `kubectl create -f app.yaml` falla si el recurso ya existe (`AlreadyExists`). Un script imperativo interrumpido a la mitad deja el sistema en un estado intermedio desconocido, y re-ejecutarlo no es seguro.
4. **Sin auditabilidad ni rollback.** No hay historial de "quién cambió qué, cuándo y por qué". El rollback es "acordate de qué valor tenía antes".

### 1.2 La solución: gestión declarativa y reconciliación

El modelo declarativo invierte la relación: el operador declara el **estado deseado** (*desired state*, el campo `spec` en Kubernetes) y un **controller** ejecuta un *reconciliation loop* que compara continuamente ese estado deseado con el **estado observado** (*observed state*, el campo `status`) y calcula las acciones necesarias para converger:

```
        ┌──────────────────────────────────────────────┐
        │              Reconciliation Loop             │
        │                                              │
        │   observe() ──► diff(desired, observed)      │
        │      ▲                    │                  │
        │      │                    ▼                  │
        │   cluster ◄────────── act()                  │
        └──────────────────────────────────────────────┘
```

Propiedades arquitectónicas clave que el examen espera que puedas justificar:

- **Idempotencia:** aplicar el mismo manifiesto N veces produce el mismo resultado que aplicarlo una vez. `kubectl apply` es idempotente; `kubectl create` no.
- **Convergencia:** el sistema tiende al estado deseado aunque el camino falle parcialmente. Si un nodo muere, el `ReplicaSet` controller detecta que `status.readyReplicas < spec.replicas` y crea Pods nuevos sin intervención humana.
- **Level-triggered vs edge-triggered:** los controllers de Kubernetes son *level-triggered*: reaccionan al **estado actual completo**, no a eventos individuales. Si un controller pierde un evento (restart, partición de red), la siguiente pasada de reconciliación corrige igual, porque compara niveles (`spec` vs `status`), no deltas. Un sistema *edge-triggered* que pierde un evento queda inconsistente para siempre. Esta es la razón de fondo por la que Kubernetes tolera fallas de sus propios componentes de control.
- **Separación `spec`/`status`:** `spec` lo escribe el usuario (o un controller de nivel superior); `status` lo escribe exclusivamente el controller responsable. Son incluso *subresources* distintos en la API (`/status`), con RBAC separable.

### 1.3 Extensión a la infraestructura: Infrastructure as Code (IaC)

El mismo principio aplicado fuera del cluster es **Infrastructure as Code**: la infraestructura (VPCs, buckets, bases de datos gestionadas, los propios clusters) se define en archivos versionados y una herramienta converge la realidad hacia esa definición. Hay dos familias con mecánicas internas muy distintas:

- **Modelo *one-shot* con state file (Terraform / OpenTofu):** el estado deseado se aplica cuando un humano o un pipeline ejecuta `terraform apply`. El "estado observado" se cachea en un *state file*. Entre ejecuciones **no hay reconciliación**: el drift se detecta recién en el próximo `terraform plan`.
- **Modelo control plane con reconciliación continua (Crossplane, Cluster API, ACK, Config Connector):** la infraestructura externa se representa como recursos de la API de Kubernetes (CRDs) y controllers la reconcilian continuamente, igual que un `Deployment`. Si alguien borra el bucket a mano en la consola, el controller lo recrea.

La combinación de gestión declarativa + repositorio Git como única fuente de verdad + agente que reconcilia automáticamente es **GitOps**, formalizado por el proyecto CNCF **OpenGitOps** en cuatro principios (v1.0.0): el estado deseado es (1) **declarativo**, (2) **versionado e inmutable**, (3) **extraído automáticamente** (*pulled*, no *pushed*) y (4) **reconciliado continuamente**. Esto se desarrolla en profundidad en los temas de GitOps del curriculum; acá importa que reconozcas que GitOps es una *consecuencia* del modelo declarativo, no una tecnología independiente.

---

## 2. Mecánica interna en Kubernetes: cómo se aplica realmente un manifiesto

### 2.1 Las tres modalidades de gestión de objetos

Kubernetes documenta tres técnicas mutuamente excluyentes por recurso:

| Modalidad | Comandos | Opera sobre | Idempotente | Historial de cambios | Uso legítimo en producción |
|---|---|---|---|---|---|
| **Imperative commands** | `kubectl run`, `kubectl scale`, `kubectl expose`, `kubectl edit` | Objetos vivos | No | Ninguno | Debugging, experimentos en dev, `kubectl scale` durante un incidente (registrando el cambio después en Git) |
| **Imperative object configuration** | `kubectl create -f`, `kubectl replace -f`, `kubectl delete -f` | Archivos individuales | No (`create` falla si existe; `replace` **reemplaza el objeto completo** y pisa cambios de otros actores) | Solo si los archivos están en Git | Bootstrap puntual; pipelines legacy |
| **Declarative object configuration** | `kubectl apply -f <dir> -R`, `kubectl diff -f` | Directorios de manifiestos | **Sí** | Git + merge inteligente de campos | **Estándar de producción**, base de GitOps |

El punto de examen: **no mezclar modalidades sobre el mismo objeto**. Un `kubectl replace` sobre un recurso gestionado con `apply` destruye los cambios hechos por otros actores (por ejemplo, la anotación de *rollover* o los `replicas` que gestiona un HPA), porque `replace` no hace merge: sustituye el objeto entero.

### 2.2 Client-Side Apply (CSA): three-way merge

`kubectl apply` clásico calcula un **three-way merge** entre tres versiones:

1. La configuración **nueva** (el archivo que estás aplicando).
2. El objeto **vivo** en el cluster.
3. La **última configuración aplicada**, que kubectl guarda serializada en la anotación `kubectl.kubernetes.io/last-applied-configuration`.

La tercera versión existe para resolver el problema de los **campos eliminados**: si un campo estaba en el *last-applied* y ya no está en el archivo nuevo, `apply` lo borra del objeto vivo. Si un campo está en el objeto vivo pero nunca estuvo en el *last-applied* (lo seteó otro controller, por ejemplo un HPA escribiendo `spec.replicas`), `apply` **no lo toca**. Sin esa anotación, sería imposible distinguir "el usuario borró este campo" de "este campo lo puso otro".

Limitaciones de CSA que motivaron su sucesor:

- El merge ocurre **en el cliente**: dos operadores con versiones distintas de kubectl pueden calcular merges distintos.
- La anotación tiene límite de tamaño práctico (es parte del objeto, cuenta contra el límite de etcd de ~1.5 MiB) y se corrompe si alguien mezcla herramientas.
- La propiedad de campos es binaria (está o no está en la anotación); no hay noción de *múltiples* gestores conviviendo con detección de conflictos.

### 2.3 Server-Side Apply (SSA): field management

**Server-Side Apply** (GA desde Kubernetes 1.22) mueve el merge al API server e introduce **field ownership** explícito: cada campo del objeto registra qué *field manager* lo escribió, en el metadato `metadata.managedFields`. El manager es un string que identifica al actor (`kubectl`, `argocd-controller`, `kube-controller-manager`, un operator propio).

Mecánica:

- Se invoca con `kubectl apply --server-side` (verbo HTTP `PATCH` con `Content-Type: application/apply-patch+yaml`).
- El API server hace el merge usando los *merge strategies* declarados en el esquema OpenAPI de cada tipo (`x-kubernetes-list-map-keys`, `x-kubernetes-list-type: map|set|atomic`), de forma determinística e independiente de la versión del cliente.
- Si el apply intenta cambiar un campo cuyo owner es **otro** manager, el server devuelve **HTTP 409 Conflict** listando los campos y managers en conflicto. Esto convierte el problema silencioso de "dos actores pisándose un campo" en un error explícito.
- `--force-conflicts` transfiere la propiedad del campo al manager que fuerza. Es la escotilla de escape, no el flujo normal.

Caso de producción arquetípico: un `Deployment` con `spec.replicas: 3` en Git, y un `HorizontalPodAutoscaler` gestionando esas réplicas. Con SSA, el HPA (`kube-controller-manager`) es owner de `spec.replicas`; cada `apply` desde el pipeline entra en conflicto. La solución correcta **no** es `--force-conflicts` (produciría un tira-y-afloje entre el pipeline y el HPA): es **eliminar `replicas` del manifiesto** y ceder la propiedad del campo al HPA. Argo CD y Flux implementan exactamente esta semántica (`ignoreDifferences` / SSA nativo).

| Dimensión | Client-Side Apply | Server-Side Apply |
|---|---|---|
| Lugar del merge | kubectl (cliente) | API server |
| Registro de propiedad | Anotación `last-applied-configuration` (un solo "dueño" implícito) | `managedFields` (N managers concurrentes, por campo) |
| Detección de conflictos entre actores | No — último en escribir gana silenciosamente | Sí — HTTP 409 con detalle de campo y manager |
| Determinismo del merge | Depende de la versión del cliente | Esquema OpenAPI del server, determinístico |
| Objetos grandes (CRDs extensos) | Riesgo: anotación gigante | Sin anotación; `managedFields` es estructurado |
| Uso por controllers/operators | Impracticable | Diseñado para eso (patrón *apply* en controller-runtime) |
| Estado en el examen y en tooling | Legacy soportado | Default en Argo CD (opcional), Flux (siempre), Helm ≥ 3.16 (opcional), recomendado para automatización |

### 2.4 Concurrencia optimista: `resourceVersion`

Toda escritura a la API pasa por **optimistic concurrency control**: cada objeto lleva `metadata.resourceVersion` (derivado del índice de modificación de etcd). Un `UPDATE` que llega con un `resourceVersion` viejo recibe HTTP 409 `Conflict` y el cliente debe releer y reintentar (`RetryOnConflict` en client-go). Los controllers están escritos asumiendo estos reintentos — otra consecuencia del diseño *level-triggered*: reintentar es siempre seguro porque la reconciliación parte del estado actual.

---

## 3. Composición de configuración: manifiestos crudos, Kustomize y Helm

Un platform engineer no gestiona un manifiesto: gestiona cientos, por entorno (`dev`/`staging`/`prod`), por cluster y por tenant. Las tres estrategias dominantes:

| Criterio | YAML plano (`apply -f dir/ -R`) | **Kustomize** (`apply -k`) | **Helm** |
|---|---|---|---|
| Modelo | Copias literales | *Overlays* declarativos sin templates (patch sobre una base común) | Templating (Go templates) + gestor de releases |
| Duplicación entre entornos | Total (N copias completas) | Nula: base única + deltas por entorno | Nula: un chart + un `values.yaml` por entorno |
| Turing-completeness | No | **No — deliberadamente**: el resultado es predecible por inspección | Sí (condicionales, loops, `tpl`) — potencia y a la vez superficie de bugs de render |
| Estado de release | No | No | Sí: Secrets `sh.helm.release.v1.*` por namespace, con historial y `rollback` |
| Distribución a terceros | Pobre | Media (repos Git, remote bases) | **Excelente**: charts versionados en registries OCI, `dependencies` |
| Integración | **Nativa en kubectl** (`-k`, desde v1.14) | Binario propio (`kustomize`) o kubectl | Binario propio (`helm`) |
| Riesgo típico en producción | Drift entre copias | Patches que dejan de matchear tras renombrar la base (fallan **loudly** en build, lo cual es bueno) | Charts de terceros con defaults inseguros; lógica de template no testeada |
| Encaje GitOps | Directo | Directo (Argo CD y Flux lo renderizan nativamente) | Directo (Flux `HelmRelease` CRD; Argo CD renderiza con `helm template`, sin estado de release Helm) |

Criterio de decisión que el examen premia: **Kustomize para configuración propia por entorno** (predecibilidad, sin lógica), **Helm para software empaquetado y distribuible** (terceros, parametrización rica). Son componibles: Kustomize puede post-procesar la salida de un chart (`helmCharts` field / `helm template | kustomize`).

---

## 4. Manifiestos completos de referencia

### 4.1 Aplicación base gestionada declarativamente

Estructura de repositorio (patrón *base + overlays*):

```
app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    └── production/
        ├── kustomization.yaml
        └── patch-resources.yaml
```

`app/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: shop
spec:
  # NOTA: sin 'replicas'. La propiedad del campo se cede al HPA
  # para no generar conflictos de field ownership con SSA.
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: ghcr.io/example/web:1.4.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

`app/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
```

`app/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/managed-by: kustomize
```

### 4.2 Overlay de producción

`app/overlays/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop-prod
namePrefix: prod-
resources:
  - ../../base
images:
  - name: ghcr.io/example/web
    newTag: 1.4.2   # pin explícito por entorno; lo actualiza el pipeline o Flux image automation
patches:
  - path: patch-resources.yaml
    target:
      kind: Deployment
      name: web
```

`app/overlays/production/patch-resources.yaml` (*strategic merge patch*):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    spec:
      containers:
        - name: web
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 1Gi
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: web
```

### 4.3 IaC one-shot: el mismo estado deseado en Terraform

`main.tf` (completo y aplicable — provisiona el namespace y una quota del entorno):

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
  backend "s3" {                # state file remoto con locking: obligatorio en equipo
    bucket         = "example-tf-state"
    key            = "platform/shop-prod.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks"
    encrypt        = true
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "kubernetes_namespace" "shop_prod" {
  metadata {
    name = "shop-prod"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "kubernetes_resource_quota" "shop_prod" {
  metadata {
    name      = "compute-quota"
    namespace = kubernetes_namespace.shop_prod.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "20"
      "requests.memory" = "40Gi"
      "limits.memory"   = "80Gi"
      "pods"            = "100"
    }
  }
}
```

Contraste conceptual con el modelo control-plane (Crossplane / Cluster API):

| Dimensión | Terraform / OpenTofu | Crossplane / Cluster API |
|---|---|---|
| Registro del estado observado | State file (S3 + lock) | `status` de CRs en etcd |
| Momento de reconciliación | Solo en `plan`/`apply` (humano o CI) | **Continua** (controllers) |
| Corrección de drift | Manual: próximo `plan` lo muestra | Automática: el controller revierte el cambio manual |
| Lenguaje | HCL | YAML sobre la API de Kubernetes (composable con RBAC, admission, GitOps) |
| Modelo operativo | Push desde pipeline | Pull desde el cluster de management |
| Riesgo característico | State file corrupto/bloqueado; drift entre ejecuciones | El cluster de management es SPOF de la plataforma; hay que protegerlo y poder reconstruirlo |

---

## 5. Comandos CLI y salidas reales

### 5.1 Render y aplicación declarativa con dry-run previo

```
$ kubectl kustomize app/overlays/production | head -n 12
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: web
  name: prod-web
  namespace: shop-prod
spec:
  ports:
  - name: http
    port: 80
```

```
$ kubectl apply -k app/overlays/production --server-side --dry-run=server
service/prod-web serverside-applied (server dry run)
deployment.apps/prod-web serverside-applied (server dry run)

$ kubectl apply -k app/overlays/production --server-side
service/prod-web serverside-applied
deployment.apps/prod-web serverside-applied
```

`--dry-run=server` (a diferencia de `client`) pasa por **admission webhooks y validación real** del API server sin persistir: es el smoke test correcto antes de tocar producción.

### 5.2 Detección de drift con `kubectl diff`

Alguien hizo `kubectl edit` y cambió la imagen a mano:

```
$ kubectl diff -k app/overlays/production
diff -u -N /tmp/LIVE-1272837490/apps.v1.Deployment.shop-prod.prod-web /tmp/MERGED-2519937428/apps.v1.Deployment.shop-prod.prod-web
--- /tmp/LIVE-1272837490/apps.v1.Deployment.shop-prod.prod-web
+++ /tmp/MERGED-2519937428/apps.v1.Deployment.shop-prod.prod-web
@@ -48,7 +48,7 @@
       containers:
-      - image: ghcr.io/example/web:1.4.1
+      - image: ghcr.io/example/web:1.4.2
         name: web

$ echo $?
1
```

Los *exit codes* de `kubectl diff` son scriptables: **0** = sin diferencias, **1** = hay diferencias, **>1** = error. Un job de CI que corre `kubectl diff` y alerta con exit 1 es un detector de drift minimalista; Argo CD y Flux hacen esto continuamente (`OutOfSync` / eventos de reconciliación).

### 5.3 Conflicto de field ownership con SSA

El pipeline intenta re-aplicar `replicas: 3` sobre un Deployment cuyo `spec.replicas` gestiona el HPA:

```
$ kubectl apply --server-side -f deployment-with-replicas.yaml
error: Apply failed with 1 conflict: conflict with "kube-controller-manager" using apps/v1: .spec.replicas
Please review the fields above--they currently have other field managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in that case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

Resolución correcta: quitar `replicas` del manifiesto (ver §2.3). Inspección de la propiedad de campos:

```
$ kubectl get deployment prod-web -n shop-prod -o yaml --show-managed-fields | \
    yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}'
manager: kubectl
operation: Apply
manager: kube-controller-manager
operation: Update
```

### 5.4 Rollout y rollback

```
$ kubectl rollout status deployment/prod-web -n shop-prod
Waiting for deployment "prod-web" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "prod-web" successfully rolled out

$ kubectl rollout history deployment/prod-web -n shop-prod
deployment.apps/prod-web
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

$ kubectl rollout undo deployment/prod-web -n shop-prod --to-revision=1
deployment.apps/prod-web rolled back
```

En un flujo GitOps estricto, `rollout undo` es una herramienta de **incidente**: el rollback canónico es `git revert` + reconciliación, porque un `undo` manual reintroduce drift respecto de Git (el agente GitOps lo va a revertir de vuelta en la próxima sincronización — con `selfHeal` activado, en segundos).

### 5.5 Pruning: borrar lo que ya no está declarado

`apply` crea y actualiza, pero **no borra** recursos removidos del repositorio. Opciones:

```
$ KUBECTL_APPLYSET=true kubectl apply -n shop-prod \
    --prune --applyset=configmaps/shop-prod-applyset \
    -k app/overlays/production
service/prod-web serverside-applied
deployment.apps/prod-web serverside-applied
configmap/old-feature-flags pruned
```

El mecanismo legacy `--prune` basado en labels + `--prune-allowlist` es notoriamente peligroso (un selector demasiado amplio borra recursos ajenos); **ApplySet** (KEP-3659, alpha desde v1.27, de ahí la variable de entorno) registra la membresía explícitamente en un objeto padre. En la práctica de plataforma, el pruning se delega al agente GitOps: `prune: true` en Flux `Kustomization` o `syncPolicy.automated.prune: true` en Argo CD `Application`, que mantienen inventario propio y son la forma segura.

### 5.6 IaC one-shot: ciclo Terraform

```
$ terraform init
Initializing the backend...
Successfully configured the backend "s3"!
Initializing provider plugins...
- Installing hashicorp/kubernetes v2.31.0...
Terraform has been successfully initialized!

$ terraform plan -out=tfplan
Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  + create

  # kubernetes_namespace.shop_prod will be created
  + resource "kubernetes_namespace" "shop_prod" { ... }

  # kubernetes_resource_quota.shop_prod will be created
  + resource "kubernetes_resource_quota" "shop_prod" { ... }

Plan: 2 to add, 0 to change, 0 to destroy.

$ terraform apply tfplan
kubernetes_namespace.shop_prod: Creating...
kubernetes_namespace.shop_prod: Creation complete after 0s [id=shop-prod]
kubernetes_resource_quota.shop_prod: Creating...
kubernetes_resource_quota.shop_prod: Creation complete after 0s [id=shop-prod/compute-quota]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

El par `plan -out` + `apply <planfile>` garantiza que se ejecuta **exactamente** lo revisado (y no un plan recalculado que pudo cambiar entre medio) — el equivalente IaC del `--dry-run=server` seguido del apply del mismo render.

---

## 6. Guía de verificación y diagnóstico de fallas

### 6.1 Checklist de verificación post-apply

1. **¿El apply llegó al server?** `kubectl apply ... --server-side` sin errores, y `kubectl diff` retorna exit 0 inmediatamente después.
2. **¿El controller convergió?** `kubectl rollout status` para workloads; para cualquier recurso, comparar `metadata.generation` (incrementa con cada cambio de `spec`) contra `status.observedGeneration` — si `observedGeneration < generation`, el controller **todavía no procesó** tu cambio (o está roto).
3. **¿Las conditions están sanas?** `kubectl get deployment prod-web -o jsonpath='{.status.conditions}' | yq -P` — buscar `Available=True` y `Progressing=True` con reason `NewReplicaSetAvailable`. `ProgressDeadlineExceeded` = rollout atascado.
4. **¿Quién es dueño de qué?** Ante valores que "vuelven solos", `--show-managed-fields` identifica al otro actor (HPA, operator, mutating webhook re-escribiendo).

### 6.2 Tabla de fallas: síntoma → causa raíz → acción

| Síntoma | Causa raíz probable | Diagnóstico y acción |
|---|---|---|
| `Error from server (AlreadyExists)` | Uso de `create` sobre recurso existente (mezcla de modalidades) | Migrar a `apply`; si falta la anotación last-applied, un primer `apply` la crea con warning |
| `error: Apply failed with N conflicts` (HTTP 409) | Otro field manager posee el campo (HPA, operator, otro pipeline) | `--show-managed-fields`; ceder el campo (quitarlo del manifiesto) o, si la propiedad es legítimamente tuya, `--force-conflicts` **una vez** y arreglar al otro actor |
| `field is immutable` (p. ej. `spec.selector` de Deployment, `spec.clusterIP`, `storageClassName` de PVC) | Cambio sobre campo inmutable por diseño | No hay patch posible: crear recurso nuevo y migrar tráfico, o `delete` + `apply` asumiendo la interrupción |
| El valor que aplico "revierte solo" a los segundos | Un controller/webhook con reconciliación continua es owner efectivo (GitOps `selfHeal`, operator, mutating webhook) | `kubectl get events`, `managedFields`; el fix va en la fuente de verdad de ese controller (Git, CR del operator), no en el objeto |
| `kubectl diff` muestra drift permanente que el apply nunca cierra | Defaulting/normalización del server (campos con defaults, orden de listas atómicas) o webhook mutando | Comparar con `--server-side --dry-run=server -o yaml`; alinear el manifiesto con la forma normalizada |
| Rollout atascado: `1 old replicas are pending termination` | Nueva revisión no pasa `readinessProbe` con `maxUnavailable: 0` | `kubectl describe pod` + `kubectl logs --previous`; `rollout undo` para restaurar servicio, luego arreglar la imagen/probe en Git |
| `unable to recognize ...: no matches for kind "X" in version "Y"` | CRD no instalada aún (orden de apply) o API removida tras upgrade | Aplicar CRDs primero (waves/dependencias en el agente GitOps; `kubectl get crd x -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'` debe dar `True`); para APIs removidas, migrar `apiVersion` |
| `namespaces "shop-prod" not found` durante apply masivo | Orden de creación dentro del batch | Kustomize ordena namespaces primero automáticamente; con YAML plano, separar bootstrap o reintentar (idempotencia hace el retry seguro) |
| Recursos huérfanos que nadie borra | `apply` no hace prune por defecto | ApplySet o prune del agente GitOps (§5.5); auditar con el inventario del agente (`kubectl get applications -n argocd`, `flux tree kustomization <name>`) |
| Terraform: `Error acquiring the state lock` | `apply` anterior muerto sin liberar el lock, o ejecución concurrente | Verificar que **no** haya otro apply corriendo; recién entonces `terraform force-unlock <LOCK_ID>` |
| Terraform: plan quiere recrear recursos que existen | State file desincronizado (recursos creados a mano o state perdido) | `terraform state list` / `terraform import` para adoptar recursos; nunca "apply y que borre" |

### 6.3 Técnica avanzada: aislar quién muta el objeto

Cuando un objeto cambia y no sabés quién lo hace, el audit log del API server es la fuente definitiva; sin acceso a él, la aproximación rápida:

```
$ kubectl get deployment prod-web -n shop-prod -o yaml --show-managed-fields | \
    yq '.metadata.managedFields[] | .manager + " " + .operation + " " + .time'
kubectl Apply 2026-08-06T10:12:03Z
kube-controller-manager Update 2026-08-06T10:12:41Z
argocd-controller Apply 2026-08-06T10:13:05Z
```

El `time` por manager señala al último escritor de cada conjunto de campos. Un manager inesperado (por ejemplo, un mutating webhook aparece como el manager del propio webhook server) reduce el sospechoso en segundos, sin tocar el audit log.

---

## 7. Referencias

- Kubernetes — Kubernetes Object Management (las tres modalidades): https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- Kubernetes — Declarative Management of Kubernetes Objects Using Configuration Files: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply (field management, conflictos, merge strategies): https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Declarative Management using Kustomize: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kubectl / Kustomize reference (kubectl book): https://kubectl.docs.kubernetes.io/
- KEP-3659 — ApplySet: kubectl apply --prune redesign: https://github.com/kubernetes/enhancements/tree/master/keps/sig-cli/3659-kubectl-apply-prune
- OpenGitOps — GitOps Principles v1.0.0 (CNCF): https://opengitops.dev/
- Helm — Documentación oficial: https://helm.sh/docs/
- Flux — Documentación oficial: https://fluxcd.io/flux/
- Argo CD — Documentación oficial: https://argo-cd.readthedocs.io/en/stable/
- Crossplane — Documentación oficial: https://docs.crossplane.io/
- Cluster API — The Cluster API Book: https://cluster-api.sigs.k8s.io/
- Terraform — Documentación oficial: https://developer.hashicorp.com/terraform/docs
- CNCF — CNPA Curriculum: https://github.com/cncf/curriculum
- CNCF — Certified Cloud Native Platform Engineering Associate (CNPA): https://www.cncf.io/training/certification/cnpa/