# Ejercicios guiados — Tema 1.1: Declarative Resource Management and Infrastructure Concepts

> **Entorno de laboratorio:** necesitás un cluster local (`kind` o `minikube`), `kubectl` ≥ 1.29 (Kustomize viene integrado), y para los ejercicios 6 y 7, acceso a Internet desde el cluster y el binario `tofu` (OpenTofu ≥ 1.7). Todos los ejercicios son idempotentes: si algo falla, podés volver a ejecutar desde el paso 1 del ejercicio.

---

## Ejercicio 1 — Imperativo vs. declarativo: por qué `apply` y no `create`

El modelo declarativo es la base de todo lo que sigue en la certificación: GitOps, IaC y los controllers de Kubernetes son variaciones del mismo principio — *declarás el estado deseado y un sistema converge hacia él*. Este ejercicio expone la diferencia mecánica entre ambos modos.

1. Creá un Deployment de forma **imperativa**:

   ```bash
   kubectl create deployment web --image=nginx:1.27
   ```

   Salida esperada:

   ```
   deployment.apps/web created
   ```

2. Ejecutá **exactamente el mismo comando** otra vez:

   ```bash
   kubectl create deployment web --image=nginx:1.27
   ```

   Salida esperada:

   ```
   error: failed to create deployment: deployments.apps "web" already exists
   ```

3. Borrá el Deployment y creá el manifiesto declarativo equivalente:

   ```bash
   kubectl delete deployment web
   ```

   ```yaml
   # deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     labels:
       app: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - containerPort: 80
             resources:
               requests:
                 cpu: 100m
                 memory: 64Mi
               limits:
                 memory: 128Mi
   ```

4. Aplicalo dos veces seguidas y observá la diferencia de comportamiento:

   ```bash
   kubectl apply -f deployment.yaml
   kubectl apply -f deployment.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/web created
   deployment.apps/web unchanged
   ```

5. Inspeccioná qué guardó `apply` en el objeto para poder ser idempotente:

   ```bash
   kubectl get deployment web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | head -c 300
   ```

   Vas a ver un JSON con la última configuración aplicada — es la tercera pata del **three-way merge** (configuración anterior, configuración nueva, estado vivo en el cluster) que `kubectl apply` calcula en modo client-side.

**Preguntas:**

- **P1.1** — ¿Por qué el paso 2 falla y el paso 4 dice `unchanged`? ¿Qué propiedad formal del modelo declarativo demuestra esto?
- **P1.2** — Si un compañero ejecuta `kubectl edit deployment web` y agrega una annotation a mano, ¿qué le pasa a esa annotation cuando vos volvés a correr `kubectl apply -f deployment.yaml`? ¿Por qué?
- **P1.3** — ¿Qué información usa el three-way merge que un two-way merge (comparar solo manifiesto vs. cluster) no tiene, y qué problema concreto resuelve?

---

## Ejercicio 2 — El reconciliation loop: desired state vs. observed state

Kubernetes no "ejecuta" tu manifiesto: lo persiste en etcd y un conjunto de controllers corre un bucle infinito comparando `spec` (deseado) contra `status` (observado), actuando sobre la diferencia. Vas a verlo en vivo.

1. Con el Deployment `web` del ejercicio 1 aplicado, abrí una terminal con un watch:

   ```bash
   kubectl get pods -l app=web -w
   ```

2. En otra terminal, borrá uno de los Pods (simulás la muerte de un nodo o un OOMKill):

   ```bash
   kubectl delete pod -l app=web --field-selector=status.phase=Running \
     $(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}') 2>/dev/null || \
   kubectl delete pod $(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
   ```

   En la terminal del watch vas a ver algo como:

   ```
   web-7d4b9c6f88-x2kqp   1/1   Running       0     3m
   web-7d4b9c6f88-x2kqp   1/1   Terminating   0     3m
   web-7d4b9c6f88-9jw4t   0/1   Pending       0     0s
   web-7d4b9c6f88-9jw4t   0/1   ContainerCreating   0   0s
   web-7d4b9c6f88-9jw4t   1/1   Running       0     2s
   ```

   Nadie ejecutó un comando de "recuperación": el nuevo Pod aparece porque el estado observado (1 réplica) dejó de coincidir con el deseado (2).

3. Compará explícitamente ambos estados:

   ```bash
   kubectl get deployment web -o jsonpath='deseado={.spec.replicas} observado={.status.readyReplicas}{"\n"}'
   ```

   Salida esperada:

   ```
   deseado=2 observado=2
   ```

4. Revisá la cadena de eventos para identificar **qué controller** actuó:

   ```bash
   kubectl get events --sort-by=.lastTimestamp | grep -E 'ReplicaSet|Pod' | tail -5
   ```

   Salida esperada (recortada):

   ```
   ... Normal  SuccessfulCreate  replicaset/web-7d4b9c6f88  Created pod: web-7d4b9c6f88-9jw4t
   ... Normal  Scheduled         pod/web-7d4b9c6f88-9jw4t   Successfully assigned default/web-7d4b9c6f88-9jw4t to kind-control-plane
   ... Normal  Started           pod/web-7d4b9c6f88-9jw4t   Started container nginx
   ```

**Preguntas:**

- **P2.1** — ¿Qué controller recreó el Pod: el Deployment controller o el ReplicaSet controller? ¿Qué hace cada uno en la jerarquía Deployment → ReplicaSet → Pod?
- **P2.2** — ¿Por qué la documentación oficial describe los controllers como sistemas *level-triggered* (basados en estado) y no *edge-triggered* (basados en eventos)? ¿Qué ventaja operacional tiene eso frente a, por ejemplo, un script que reacciona a un webhook y se pierde el evento?
- **P2.3** — `spec` y `status` viven en el mismo objeto de la API. ¿Quién es el "dueño" de escritura de cada uno en una arquitectura sana?

---

## Ejercicio 3 — Server-Side Apply y field ownership: quién es dueño de cada campo

En una plataforma real conviven varios actores que escriben sobre los mismos objetos: el pipeline de CD, el HorizontalPodAutoscaler, un operador humano con `kubectl`. **Server-Side Apply (SSA)** mueve el merge del cliente al API server y registra la propiedad de cada campo en `metadata.managedFields`, lo que permite detectar conflictos en vez de pisarse silenciosamente.

1. Borrá el estado previo y aplicá el manifiesto en modo server-side, identificándote como el equipo de plataforma:

   ```bash
   kubectl delete deployment web --ignore-not-found
   kubectl apply --server-side --field-manager=platform-team -f deployment.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/web serverside-applied
   ```

2. Simulá que otro actor (el equipo de la aplicación) intenta declarar un valor distinto de `replicas`. Creá `replicas-patch.yaml`:

   ```yaml
   # replicas-patch.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 5
   ```

   ```bash
   kubectl apply --server-side --field-manager=app-team -f replicas-patch.yaml
   ```

   Salida esperada:

   ```
   error: Apply failed with 1 conflict: conflict with "platform-team": .spec.replicas
   Please review the fields above--they currently have other managers. Here
   are the ways you can resolve this conflict:
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

3. Resolvé el conflicto tomando propiedad explícita del campo:

   ```bash
   kubectl apply --server-side --field-manager=app-team --force-conflicts -f replicas-patch.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/web serverside-applied
   ```

4. Auditá quién es dueño de qué (desde v1.21 `managedFields` está oculto por defecto):

   ```bash
   kubectl get deployment web -o yaml --show-managed-fields | grep -A 4 'manager:'
   ```

   Vas a ver dos entradas: `platform-team` como manager de la mayoría del `spec`, y `app-team` como manager de `f:replicas`.

**Preguntas:**

- **P3.1** — ¿Qué problema concreto de producción resuelve el registro de field ownership que el client-side apply con `last-applied-configuration` no puede resolver?
- **P3.2** — El caso canónico de conflicto por `replicas` es la convivencia de un manifiesto GitOps con un **HorizontalPodAutoscaler**. ¿Cuál es la resolución correcta según la documentación oficial: `--force-conflicts` en el pipeline, o quitar `replicas` del manifiesto? ¿Por qué?
- **P3.3** — ¿Por qué las tres opciones que ofrece el mensaje de error (forzar, ceder el campo, co-poseer) son *todas* válidas semánticamente, y qué criterio usás para elegir en cada caso?

---

## Ejercicio 4 — Drift detection: `kubectl diff` antes de tocar nada

**Configuration drift** es la divergencia entre lo declarado (Git, tu manifiesto) y lo vivo (cluster). En producción, aplicar sin mirar el diff es equivalente a un `git push --force`: técnicamente converge, operacionalmente puede revertir un hotfix que alguien hizo a las 3 AM por una buena razón.

1. Simulá un hotfix manual hecho fuera del flujo declarativo:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.26 --field-manager=hotfix-manual
   ```

   Salida esperada:

   ```
   deployment.apps/web image updated
   ```

2. Antes de re-aplicar, detectá el drift **sin modificar nada**:

   ```bash
   kubectl diff -f deployment.yaml
   echo "exit code: $?"
   ```

   Salida esperada (recortada):

   ```diff
   -        image: nginx:1.26
   +        image: nginx:1.27
   ```
   ```
   exit code: 1
   ```

3. Verificá el contrato de exit codes, que es lo que permite usar `diff` en CI:

   ```bash
   kubectl apply -f deployment.yaml
   kubectl diff -f deployment.yaml
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   deployment.apps/web configured
   exit code: 0
   ```

4. Probá también la validación sin persistencia contra el API server real (pasa por admission webhooks y validación de schema, a diferencia de `--dry-run=client`):

   ```bash
   kubectl apply --dry-run=server -f deployment.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/web unchanged (server dry run)
   ```

**Preguntas:**

- **P4.1** — ¿Qué significa cada exit code de `kubectl diff` (0, 1, >1) y cómo lo aprovecharías en un job de CI que corre cada 10 minutos como detector de drift?
- **P4.2** — En el paso 3, el `apply` revirtió `nginx:1.26` → `nginx:1.27`. Si ese 1.26 era un rollback de emergencia legítimo, ¿cuál es el error de proceso de fondo y cómo lo previene un flujo GitOps?
- **P4.3** — ¿Qué diferencias concretas hay entre `--dry-run=client` y `--dry-run=server`, y por qué solo el segundo detecta que un mutating admission webhook va a alterar tu objeto?

---

## Ejercicio 5 — Kustomize: personalización declarativa sin templates

Un manifiesto por entorno multiplicado por N entornos es deuda garantizada. Kustomize (integrado en `kubectl`) resuelve la variación entre entornos con **bases y overlays** — parches estructurados sobre YAML puro, sin lenguaje de templating.

1. Armá esta estructura:

   ```
   kustom-lab/
   ├── base/
   │   ├── deployment.yaml      # el mismo del ejercicio 1
   │   └── kustomization.yaml
   └── overlays/
       └── prod/
           ├── kustomization.yaml
           └── patch-replicas.yaml
   ```

2. Contenido de `base/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
   commonLabels:
     app.kubernetes.io/managed-by: kustomize
   ```

3. Contenido de `overlays/prod/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base
   namePrefix: prod-
   images:
     - name: nginx
       newTag: "1.27.1"
   patches:
     - path: patch-replicas.yaml
   ```

   Y `overlays/prod/patch-replicas.yaml` (strategic merge patch):

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 4
   ```

4. Renderizá el overlay **sin aplicar** y verificá las tres transformaciones (prefijo de nombre, tag de imagen, réplicas):

   ```bash
   kubectl kustomize kustom-lab/overlays/prod | grep -E 'name: prod-|image:|replicas:'
   ```

   Salida esperada:

   ```
   name: prod-web
     replicas: 4
         image: nginx:1.27.1
   ```

5. Aplicá el overlay con el flag `-k`:

   ```bash
   kubectl apply -k kustom-lab/overlays/prod
   ```

   Salida esperada:

   ```
   deployment.apps/prod-web created
   ```

**Preguntas:**

- **P5.1** — ¿Cuál es la diferencia arquitectural entre el enfoque de Kustomize (overlays/patches sobre YAML válido) y el de Helm (templates con Go templating), y qué gana y qué pierde cada uno?
- **P5.2** — El paso 4 renderiza sin tocar el cluster. ¿Por qué esa separación *render → review → apply* es exactamente lo que necesita un flujo GitOps, y en qué punto del pipeline la insertarías?
- **P5.3** — Si mañana agregás `overlays/staging`, ¿cuántos archivos tocás de `base/`? ¿Qué principio de ingeniería estás aplicando?

---

## Ejercicio 6 — GitOps con Argo CD: el cluster converge hacia Git

GitOps lleva el reconciliation loop un nivel más arriba: el estado deseado ya no es "lo que alguien aplicó por última vez" sino **lo que está versionado en Git**, y un agente dentro del cluster (modelo *pull*) reconcilia continuamente contra ese repositorio.

1. Instalá Argo CD (esta instalación es, coherentemente, un `apply` declarativo):

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
   ```

2. Declarар una `Application` — notá que **no** usamos el CLI `argocd app create`: la aplicación misma es un recurso declarativo. Creá `app-guestbook.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: guestbook
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   kubectl apply -f app-guestbook.yaml
   ```

3. Esperá la convergencia y verificá:

   ```bash
   kubectl get application guestbook -n argocd
   ```

   Salida esperada (tras ~30 s):

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   Synced        Healthy
   ```

4. Provocá drift a propósito y mirá cómo `selfHeal` lo revierte:

   ```bash
   kubectl -n guestbook scale deployment guestbook-ui --replicas=5
   sleep 10
   kubectl -n guestbook get deployment guestbook-ui
   ```

   Salida esperada:

   ```
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           4m
   ```

   Las 5 réplicas duraron segundos: Argo CD detectó que el estado vivo divergía de Git y lo restauró **sin intervención humana**.

5. Verificá qué haría `prune: true`: borrá un recurso del cluster y observá que también se restaura; el prune actúa en la dirección inversa (recursos vivos que ya *no* están en Git se eliminan):

   ```bash
   kubectl -n guestbook delete service guestbook-ui
   sleep 10
   kubectl -n guestbook get service guestbook-ui
   ```

   El Service reaparece.

**Preguntas:**

- **P6.1** — Enunciá los cuatro principios de OpenGitOps (v1.0.0) y señalá qué paso de este ejercicio demuestra cada uno.
- **P6.2** — ¿Qué diferencia al modelo *pull* (el agente dentro del cluster trae los cambios) del modelo *push* (el pipeline de CI aplica con credenciales al cluster), en términos de superficie de ataque y de detección de drift?
- **P6.3** — En el paso 4, tanto el ReplicaSet controller (ejercicio 2) como Argo CD son reconciliation loops. ¿Contra qué fuente de verdad reconcilia cada uno, y por qué no compiten entre sí?
- **P6.4** — `selfHeal` revierte cambios manuales en segundos. ¿Cómo se hace entonces un cambio de emergencia legítimo en un cluster gestionado por GitOps?

---

## Ejercicio 7 — IaC idempotente con OpenTofu: convergencia bajo demanda

La infraestructura debajo del cluster (y a veces recursos dentro de él) también se gestiona declarativamente, pero con un modelo de reconciliación distinto: **bajo demanda** (`plan`/`apply`) en lugar de continuo. Vas a comprobar la idempotencia y la detección de drift con OpenTofu.

1. Creá un directorio `tofu-lab/` con este `main.tf`:

   ```hcl
   terraform {
     required_providers {
       kubernetes = {
         source  = "hashicorp/kubernetes"
         version = "~> 2.32"
       }
     }
   }

   provider "kubernetes" {
     config_path = "~/.kube/config"
   }

   resource "kubernetes_namespace" "platform" {
     metadata {
       name = "platform-dev"
       labels = {
         team        = "platform"
         environment = "dev"
       }
     }
   }
   ```

2. Inicializá y aplicá:

   ```bash
   cd tofu-lab
   tofu init
   tofu apply -auto-approve
   ```

   Salida esperada (recortada):

   ```
   Plan: 1 to add, 0 to change, 0 to destroy.
   kubernetes_namespace.platform: Creating...
   kubernetes_namespace.platform: Creation complete after 0s [id=platform-dev]

   Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
   ```

3. Verificá la idempotencia — un segundo `plan` no propone nada:

   ```bash
   tofu plan
   ```

   Salida esperada:

   ```
   No changes. Your infrastructure matches the configuration.
   ```

4. Provocá drift por fuera de la herramienta:

   ```bash
   kubectl label namespace platform-dev team=payments --overwrite
   ```

5. Volvé a planificar y observá la detección:

   ```bash
   tofu plan
   ```

   Salida esperada (recortada):

   ```
   kubernetes_namespace.platform: Refreshing state... [id=platform-dev]

     # kubernetes_namespace.platform will be updated in-place
     ~ resource "kubernetes_namespace" "platform" {
         ~ metadata {
             ~ labels = {
                 ~ "team" = "payments" -> "platform"
                   # (1 unchanged element hidden)
               }
           }
       }

   Plan: 0 to add, 1 to change, 0 to destroy.
   ```

   El drift existió desde el paso 4, pero **nadie lo supo hasta que alguien corrió `plan`**. Ese es el contraste central con los ejercicios 2 y 6.

6. Limpiá el laboratorio:

   ```bash
   tofu destroy -auto-approve
   ```

**Preguntas:**

- **P7.1** — ¿Qué rol cumple el *state file* de OpenTofu/Terraform, y qué tres fuentes compara `plan` para calcular el diff?
- **P7.2** — Compará el modelo de reconciliación de OpenTofu con el de un controller de Kubernetes y con Argo CD: ¿quién reconcilia, cuándo, y contra qué fuente de verdad? ¿Qué implica eso para la ventana de drift no detectado en cada caso?
- **P7.3** — Herramientas como Crossplane proponen gestionar infraestructura externa (buckets, bases de datos) con *controllers de Kubernetes* en vez de con `plan`/`apply`. ¿Qué propiedad del modelo de OpenTofu se pierde y cuál se gana con ese cambio?

---

## Fuentes

- Kubernetes — Object Management: https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- Kubernetes — Declarative Management of Objects Using Configuration Files: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Controllers: https://kubernetes.io/docs/concepts/architecture/controller/
- Kustomize (referencia oficial de kubectl): https://kubectl.docs.kubernetes.io/references/kustomize/
- OpenGitOps Principles v1.0.0: https://opengitops.dev/
- Argo CD — Declarative Setup y Automated Sync: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/ y https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- OpenTofu — Documentation: https://opentofu.org/docs/
- CNCF — CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

---

<details>
<summary><strong>Respuestas</strong></summary>

**P1.1** — `create` es imperativo: describe una *acción* ("creá esto"), y una acción repetida sobre un estado ya alcanzado es un error. `apply` es declarativo: describe un *estado* ("esto debe existir así"), y declarar dos veces el mismo estado es un no-op (`unchanged`). La propiedad demostrada es la **idempotencia**: aplicar N veces produce el mismo resultado que aplicar una vez. Es la propiedad que hace posible la automatización segura — un pipeline puede reintentar sin miedo.

**P1.2** — La annotation manual **sobrevive**. El three-way merge compara la configuración nueva contra la `last-applied-configuration`: como tu manifiesto nunca declaró esa annotation (ni antes ni ahora), `apply` no tiene motivo para tocarla. Solo elimina campos que *estaban* en la última configuración aplicada y *ya no están* en la nueva. Esto permite que campos gestionados por otros actores (por ejemplo, annotations de un ingress controller o `spec.replicas` escrito por un HPA) coexistan con tu manifiesto.

**P1.3** — El two-way merge solo ve "manifiesto vs. cluster", así que no puede distinguir entre *"este campo no está en mi manifiesto porque lo borré"* y *"este campo no está en mi manifiesto porque nunca fue mío"*. La `last-applied-configuration` aporta esa tercera referencia: si el campo estaba en la configuración anterior y desapareció de la nueva, hay que **eliminarlo** del cluster; si nunca estuvo, hay que **dejarlo en paz**. Sin esto, borrar una línea de un manifiesto no tendría efecto (o, peor, aplicar pisaría todo lo ajeno).

**P2.1** — El **ReplicaSet controller**. La jerarquía divide responsabilidades: el Deployment controller gestiona *rollouts* — crea y escala ReplicaSets para orquestar transiciones de versión (rolling update, rollback) — mientras que el ReplicaSet controller garantiza que en todo momento existan exactamente `spec.replicas` Pods que matcheen el selector. Cuando borraste el Pod, el Deployment no se enteró de nada relevante: su ReplicaSet seguía declarando 2 réplicas, y fue el ReplicaSet controller quien detectó 1 ≠ 2 y creó el reemplazo (visible en el evento `SuccessfulCreate` emitido por `replicaset/web-...`).

**P2.2** — Un sistema *edge-triggered* reacciona a la transición ("murió un Pod"); si el evento se pierde — restart del controller, partición de red, webhook caído — el sistema queda inconsistente para siempre porque nadie se lo vuelve a contar. Un sistema *level-triggered* observa el **estado** ("hay 1 Pod, deberían ser 2") en cada iteración del loop: no importa cuántos eventos se perdieron mientras estaba caído, en la próxima pasada converge igual. Es la razón por la que los controllers de Kubernetes se recuperan solos de sus propios crashes, y el mismo argumento por el que GitOps re-sincroniza periódicamente en vez de depender solo de webhooks de Git.

**P2.3** — `spec` lo escriben los **usuarios y herramientas de despliegue** (humanos, CI/CD, GitOps): es la declaración de intención. `status` lo escriben **solo los controllers**: es el reporte de la realidad observada. Un pipeline que escribe `status`, o un controller que muta `spec` de sus propios recursos sin ser el dueño designado del campo, rompe el contrato y genera loops de reconciliación en conflicto. (La excepción sana es un controller que escribe `spec` de *otro* recurso como parte de su trabajo, como el HPA escribiendo `spec.replicas` — y por eso existe el field ownership del ejercicio 3.)

**P3.1** — El client-side apply solo conoce *su propia* historia (la annotation `last-applied-configuration` de kubectl): no sabe qué campos escribieron otros actores ni puede detectar que dos herramientas se disputan el mismo campo — la última en escribir gana, silenciosamente. SSA registra en `managedFields` **qué manager posee cada campo individual**, y convierte la colisión en un **conflicto explícito** (HTTP 409) en el API server, sea cual sea el cliente que escriba. El problema de producción resuelto es el "tira y afloje" invisible: dos sistemas re-aplicando valores distintos del mismo campo en un loop infinito, cada uno convencido de estar corrigiendo drift.

**P3.2** — Quitar `replicas` del manifiesto. Con `--force-conflicts` el pipeline le arrebataría la propiedad del campo al HPA en cada sync, revirtiendo el escalado automático — y el HPA volvería a escalar, generando un loop de peleas (y rollouts espurios). Al eliminar `replicas` del manifiesto declarado, el pipeline **cede la propiedad** de ese campo y el HPA queda como único dueño; el Deployment usa el valor vivo. Es el patrón documentado tanto en la guía de SSA de Kubernetes como en la documentación de Argo CD para HPA. Regla general: el dueño de un campo debe ser el sistema con la información más fresca para decidirlo.

**P3.3** — Las tres opciones corresponden a tres intenciones distintas, y el error no puede adivinar cuál es la tuya: (a) **forzar** — sos la nueva fuente de verdad para ese campo (ej.: migraste la gestión de un recurso de una herramienta legacy al pipeline GitOps); (b) **ceder** — el otro manager tiene mejor información (ej.: HPA y `replicas`); (c) **co-poseer** — ambos declaran el mismo valor a propósito y cualquiera lo mantendrá si el otro se retira (ej.: un valor de seguridad que dos equipos quieren garantizar). El criterio es siempre *quién debe decidir este campo en régimen permanente*, no quién llegó primero.

**P4.1** — El contrato documentado de `kubectl diff` es: **0** = sin diferencias, **1** = hay diferencias, **>1** = error (kubeconfig inválido, API inaccesible, manifiesto malformado). En CI: exit 0 → verde silencioso; exit 1 → alerta de drift (con el diff como evidencia en el log) *sin* auto-remediar, o auto-remediación si esa es la política; >1 → fallo del job en sí, que debe alertar distinto (el detector está roto, no hay drift confirmado). Confundir 1 con >1 es el bug clásico de estos jobs: `set -e` mata el script en el exit 1 legítimo.

**P4.2** — El error de proceso es que existieron **dos fuentes de verdad**: el hotfix se hizo en el cluster pero no en el repositorio de manifiestos, así que la reconciliación posterior lo consideró drift y lo revirtió — correctamente según su información. GitOps lo previene invirtiendo el flujo de emergencia: el hotfix se hace **commiteando a Git** (un revert o un pin de imagen), y el agente lo despliega. Si de verdad hubo que tocar el cluster a mano primero, el cambio debe llegar a Git *antes* del próximo ciclo de sync — o pausarse la auto-sync explícitamente (ver P6.4).

**P4.3** — `--dry-run=client` valida localmente en kubectl: schema básico y poco más; nunca contacta al servidor. `--dry-run=server` envía la request real al API server con el flag de dry-run: pasa por autenticación, autorización, **validación completa del schema**, defaulting, y toda la cadena de **admission webhooks** (mutating y validating), sin persistir en etcd. Un mutating webhook (por ejemplo, uno que inyecta un sidecar o fuerza `securityContext`) se ejecuta y su efecto aparece en la respuesta — por eso solo el server-side dry-run te muestra el objeto *como realmente quedaría*, y puede rechazar lo que un validating webhook rechazaría en producción.

**P5.1** — Kustomize es **template-free**: la base y los overlays son YAML de Kubernetes sintácticamente válido, transformado estructuralmente (patches, prefijos, transformers). Ganás legibilidad (todo archivo es un manifiesto real que podés validar y lint-ear por sí solo), diffs limpios y cero lenguaje nuevo; perdés lógica: no hay condicionales, loops ni valores calculados. Helm usa Go templating sobre texto: ganás parametrización arbitraria, empaquetado, versionado y distribución (charts como artefacto instalable con dependencias); perdés que el template ya no es YAML válido hasta renderizarse, y la lógica embebida puede volverse ilegible. En plataformas reales conviven: Helm para software de terceros que consumís, Kustomize para tu propia configuración por entorno — e incluso Kustomize post-renderizando la salida de Helm.

**P5.2** — Porque separa la **construcción** del estado deseado de su **aplicación**, que es exactamente la frontera entre CI y CD en GitOps: el render (`kubectl kustomize`) es determinístico y se puede ejecutar en un pipeline sin credenciales del cluster, su salida se puede revisar en el pull request (el diff del YAML renderizado es el artefacto de review), y recién el agente GitOps aplica lo mergeado. La inserción natural: un job de CI que renderiza ambos lados del PR y comenta el diff resultante — el reviewer aprueba estados finales, no patches abstractos.

**P5.3** — **Cero** archivos de `base/`. Creás `overlays/staging/` con su `kustomization.yaml` apuntando a `../../base` y sus patches propios. El principio es **DRY** aplicado a configuración — la definición común vive en un solo lugar y cada entorno declara únicamente su *delta* — combinado con el principio open/closed: la base queda abierta a extensión (nuevos overlays) y cerrada a modificación.

**P6.1** — Los cuatro principios de OpenGitOps v1.0.0: **(1) Declarativo** — el estado deseado se expresa declarativamente: los manifiestos del repo `argocd-example-apps` y la propia `Application` CR (paso 2). **(2) Versionado e inmutable** — el estado vive en un almacenamiento que preserva historia: el repositorio Git referenciado por `repoURL` + `targetRevision` (paso 2). **(3) Extraído automáticamente (pulled)** — agentes aprueban y extraen el estado deseado de la fuente: Argo CD trae los cambios desde dentro del cluster sin que nadie los empuje (paso 3). **(4) Reconciliado continuamente** — agentes observan el estado real y actúan sobre la divergencia: el revert del scale manual y la restauración del Service borrado (pasos 4 y 5).

**P6.2** — *Superficie de ataque:* en push, el sistema de CI guarda credenciales con permisos de escritura sobre el cluster (a menudo cluster-admin), y CI es históricamente un objetivo blando — un compromiso del pipeline es un compromiso del cluster. En pull, ninguna credencial del cluster sale de él: el agente interno solo necesita acceso *de lectura* a Git y al registry; lo que se expone hacia afuera es mínimo. *Detección de drift:* un pipeline push solo actúa cuando algo lo dispara — entre ejecuciones, el drift es invisible. El agente pull reconcilia continuamente (Argo CD refresca cada ~3 minutos por defecto, más webhooks como optimización), así que el drift se detecta y opcionalmente se corrige en una ventana acotada y conocida.

**P6.3** — El ReplicaSet controller reconcilia el estado de los Pods contra el `spec` almacenado **en el API server (etcd)**. Argo CD reconcilia los objetos del API server contra **Git**. Son dos eslabones de la misma cadena a distinta altura: Git → (Argo CD) → objetos de la API → (controllers) → realidad en los nodos. No compiten porque operan sobre pares (fuente de verdad, objetivo) disjuntos: Argo CD jamás crea Pods, y el ReplicaSet controller jamás lee Git. El día que sí compiten es cuando dos agentes reconcilian *el mismo objeto contra fuentes distintas* — exactamente el caso HPA vs. manifiesto con `replicas` (P3.2).

**P6.4** — Por la vía rápida de Git: un commit de emergencia (revert, pin de imagen) que el agente sincroniza — con `selfHeal`, Git *es* el botón de emergencia, y el fix queda auditado y persistente. Si el procedimiento exige tocar el cluster directamente (por ejemplo, el propio Argo CD está involucrado en el incidente), primero se desactiva temporalmente la automatización — deshabilitar `syncPolicy.automated` o pausar el sync de esa `Application` — se interviene, y el paso final obligatorio del incidente es **portar el cambio a Git y reactivar el sync**. Lo que no existe en GitOps es el hotfix manual que "queda": o llega a Git, o la reconciliación lo borra.

**P7.1** — El state file es el **registro de qué recursos reales corresponden a qué bloques de configuración**: mapea `kubernetes_namespace.platform` → el namespace `platform-dev` concreto, con los atributos observados en el último refresh. `plan` compara **tres** fuentes: (1) la configuración (`.tf` — deseado), (2) el state (lo que la herramienta cree que existe), y (3) el mundo real (refresca cada recurso contra su API). Sin el state no podría saber que ese namespace es *suyo* (vs. uno homónimo creado por otro), ni detectar recursos que debe destruir porque desaparecieron de la configuración — es el mismo rol que cumple `last-applied-configuration`/`managedFields` en Kubernetes: la memoria de propiedad.

**P7.2** — OpenTofu: reconcilia **un humano o pipeline al invocar `plan`/`apply`**, bajo demanda, contra configuración + state; entre invocaciones el drift es invisible por tiempo indefinido — como comprobaste, el label alterado en el paso 4 no existió para nadie hasta el `plan` del paso 5. Controller de Kubernetes: reconcilia **un proceso dentro del cluster**, continuamente (nivel-triggered, resync periódico), contra el `spec` en etcd; ventana de drift de segundos. Argo CD: igual modelo continuo, pero contra Git; ventana de minutos (intervalo de refresh) o segundos (webhook). La consecuencia operacional: con IaC bajo demanda necesitás *agendar* la detección de drift (un `plan` periódico en CI que alerte en exit code de cambios, análogo a P4.1); con reconciliación continua la detección viene incluida y lo que agendás es la *revisión* de lo que el agente reporta.

**P7.3** — Se pierde el **plan como artefacto de decisión previa**: en el modelo `plan`/`apply` un humano ve el diff exacto ("1 to change, 2 to destroy") *antes* de que ocurra nada, y puede abortar; un controller de Crossplane converge continuamente sin ese checkpoint — el equivalente al "plan" hay que reconstruirlo con policies, revisión del recurso declarativo en el PR, y campos como `deletionPolicy`. Se gana la **reconciliación continua**: el drift en la infraestructura externa se detecta y corrige solo (con OpenTofu quedaba invisible hasta el próximo `plan`), la infraestructura se declara con el mismo modelo de recursos, RBAC y GitOps que las aplicaciones, y desaparece el state file como artefacto separado a proteger — el estado vive en el API server como todo lo demás. Es el mismo trade-off de todo el tema: control puntual con supervisión humana vs. convergencia autónoma con supervisión por políticas.

</details>