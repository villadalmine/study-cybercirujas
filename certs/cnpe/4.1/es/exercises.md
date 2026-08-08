# Ejercicios Guiados — Tema 4.1: Implementing GitOps Workflows for Application and Infrastructure Deployment

> **Prerrequisitos del entorno de laboratorio**
> - Un clúster Kubernetes ≥ 1.28 (kind, k3d o minikube sirven). Verificá con `kubectl version -o yaml`.
> - `kubectl`, `git`, `helm` (v3) y `kustomize` en el `PATH`.
> - La CLI `argocd` (v2.11+) y la CLI `flux` (v2.3+). Se instalan en los ejercicios donde se usan.
> - Un repositorio Git al que puedas hacer push (GitHub/GitLab, o un Gitea local). Los ejemplos usan `https://github.com/<TU_USUARIO>/gitops-lab.git`.
>
> **Nota conceptual antes de arrancar.** GitOps, tal como lo formaliza el **OpenGitOps Working Group** de la CNCF, descansa sobre cuatro principios ([opengitops.dev/#principles](https://opengitops.dev)): el sistema deseado es (1) **declarativo**, (2) **versionado e inmutable** en Git, (3) **traído automáticamente** (*pulled*) por agentes, y (4) **reconciliado continuamente** para converger el estado real al deseado. Todo lo que sigue es una demostración operativa de esos cuatro principios.

---

## Ejercicio 1 — Instalar Argo CD y observar el modelo *pull-based* de reconciliación

**Objetivo:** desplegar el control-plane de Argo CD, entender que el agente vive *dentro* del clúster y hace *pull* del repositorio, y verificar la reconciliación continua.

### Pasos

1. Creá el namespace y aplicá el manifiesto de instalación oficial (versión fijada, nunca `stable` en producción):

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
   ```

2. Esperá a que el control-plane esté listo y observá qué componentes se crearon:

   ```bash
   kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
   kubectl -n argocd get deploy
   ```

   Salida esperada (aproximada):

   ```
   NAME                                READY   UP-TO-DATE   AVAILABLE   AGE
   argocd-applicationset-controller    1/1     1            1           2m
   argocd-dex-server                   1/1     1            1           2m
   argocd-notifications-controller     1/1     1            1           2m
   argocd-redis                        1/1     1            1           2m
   argocd-repo-server                  1/1     1            1           2m
   argocd-server                       1/1     1            1           2m
   ```
   *(El `argocd-application-controller` es un `StatefulSet`, no aparece en `get deploy`.)*

3. Verificá que el reconciliador principal es un StatefulSet y observá su rol:

   ```bash
   kubectl -n argocd get statefulset argocd-application-controller
   ```

4. Instalá la CLI y logueate. Obtené la contraseña inicial del `admin` (guardada en un Secret) y hacé port-forward:

   ```bash
   ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d)
   kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
   argocd login localhost:8080 --username admin --password "$ARGO_PWD" --insecure
   ```

   Salida esperada:

   ```
   'admin:login' logged in successfully
   Context 'localhost:8080' updated
   ```

**Preguntas de comprensión (bloque 1)**

1. El `argocd-application-controller` está implementado como `StatefulSet` y no como `Deployment`. ¿Qué propiedad del reconciliador justifica esa elección de workload?
2. En este modelo, ¿quién inicia la conexión: el clúster hacia Git, o un CI externo hacia el clúster? ¿Por qué esa dirección es una ventaja de seguridad frente a un pipeline *push-based* clásico?
3. ¿Cuál de los cuatro principios de OpenGitOps queda demostrado por el hecho de que el controlador siga corriendo y comparando estado aunque nadie haga push?

---

## Ejercicio 2 — Primera `Application`, drift detection y self-heal

**Objetivo:** declarar una `Application`, observar `OutOfSync` vs `Synced`, provocar *drift* manual y ver la diferencia entre reconciliación automática con y sin `selfHeal`.

### Pasos

1. Preparás un repo con un manifiesto simple. En tu `gitops-lab`, creá `apps/guestbook/deployment.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: guestbook
     labels: { app: guestbook }
   spec:
     replicas: 2
     selector:
       matchLabels: { app: guestbook }
     template:
       metadata:
         labels: { app: guestbook }
       spec:
         containers:
           - name: guestbook
             image: gcr.io/google-samples/gb-frontend:v5
             ports:
               - containerPort: 80
   ```

   Commiteá y pusheá:

   ```bash
   git add apps/guestbook/deployment.yaml
   git commit -m "feat: guestbook deployment"
   git push
   ```

2. Declará la `Application` de Argo CD. Empezamos **sin** política automática para ver la sincronización manual:

   ```yaml
   # application-guestbook.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<TU_USUARIO>/gitops-lab.git
       targetRevision: main
       path: apps/guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: guestbook
     syncPolicy:
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   kubectl apply -f application-guestbook.yaml
   argocd app get guestbook
   ```

   Salida esperada (recortada): el estado será `OutOfSync` y `Healthy`/`Missing` porque todavía no sincronizaste:

   ```
   Name:               argocd/guestbook
   Sync Status:        OutOfSync from main
   Health Status:      Missing
   ```

3. Sincronizá manualmente y observá el cambio de estado:

   ```bash
   argocd app sync guestbook
   argocd app get guestbook
   ```

   Ahora debería aparecer `Sync Status: Synced` y `Health Status: Healthy`.

4. **Provocá drift.** Editá el objeto vivo salteándote Git (esto es exactamente lo que GitOps prohíbe hacer en producción):

   ```bash
   kubectl -n guestbook scale deployment guestbook --replicas=5
   argocd app get guestbook
   ```

   Argo CD detecta el drift: `Sync Status: OutOfSync`. Aún así, las 5 réplicas siguen corriendo — la reconciliación automática no está activada.

5. Activá `automated` **con** `selfHeal` y `prune`, luego reintroducí el drift:

   ```bash
   argocd app set guestbook --sync-policy automated --self-heal --auto-prune
   kubectl -n guestbook scale deployment guestbook --replicas=5
   sleep 15
   kubectl -n guestbook get deploy guestbook
   ```

   Salida esperada: el controlador revierte el cambio a `replicas: 2` (el valor de Git) en cuestión de segundos.

   ```
   NAME        READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook   2/2     2            2           6m
   ```

**Preguntas de comprensión (bloque 2)**

1. En el paso 4 el estado quedó `OutOfSync` pero las 5 réplicas siguieron vivas. ¿Qué hace exactamente `selfHeal=true` que cambia ese comportamiento en el paso 5?
2. `auto-prune` (o `prune`) desactivado por defecto. Describí un escenario de producción en el que hacer sync con `prune` activado sin querer borre recursos legítimos. ¿Cómo lo mitigás?
3. Distinguí *drift detection* de *self-heal*: ¿puede un sistema GitOps detectar drift sin corregirlo automáticamente? ¿Cuándo querrías esa configuración deliberadamente?

---

## Ejercicio 3 — Sync waves y hooks: ordenar el despliegue

**Objetivo:** controlar el orden de aplicación de recursos con `argocd.argoproj.io/sync-wave` y ejecutar tareas de una sola vez con `PreSync` hooks.

### Pasos

1. Agregá a `apps/ordered/` tres manifiestos que deben aplicarse en orden: primero un `Namespace`/`ConfigMap`, luego una migración de base de datos (hook), y por último la app.

   `apps/ordered/00-config.yaml`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
     annotations:
       argocd.argoproj.io/sync-wave: "0"
   data:
     LOG_LEVEL: info
   ```

   `apps/ordered/10-migration.yaml` (Job como `PreSync` hook):

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: db-migrate
     annotations:
       argocd.argoproj.io/hook: PreSync
       argocd.argoproj.io/hook-delete-policy: HookSucceeded
   spec:
     backoffLimit: 2
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: migrate
             image: busybox:1.36
             command: ["sh", "-c", "echo 'running migration...'; sleep 5; echo done"]
   ```

   `apps/ordered/20-deploy.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     annotations:
       argocd.argoproj.io/sync-wave: "1"
     labels: { app: web }
   spec:
     replicas: 1
     selector: { matchLabels: { app: web } }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: nginx:1.27-alpine
   ```

2. Commiteá, pusheá y creá la Application apuntando a `apps/ordered`. Sincronizá observando el orden en vivo:

   ```bash
   argocd app sync ordered --watch
   ```

   En la salida verás que el hook `PreSync` (`db-migrate`) corre y termina **antes** de que se cree/actualice `web`, y que el `ConfigMap` (wave 0) precede al `Deployment` (wave 1).

3. Confirmá que el Job se borró tras completarse (por `hook-delete-policy: HookSucceeded`):

   ```bash
   kubectl -n ordered get jobs
   ```

   Salida esperada: `No resources found in ordered namespace.`

**Preguntas de comprensión (bloque 3)**

1. Dentro de una misma wave, ¿en qué orden aplica Argo CD los recursos? ¿Y qué garantiza la barrera entre waves respecto de la *health* de los recursos de la wave anterior?
2. ¿Por qué una migración de base de datos encaja mejor como `PreSync` hook que como un recurso con `sync-wave: "-1"`? Pensá en qué pasa cuando la migración falla.
3. La `hook-delete-policy` alternativa es `BeforeHookCreation`. ¿Qué problema de idempotencia resuelve frente a `HookSucceeded` cuando un hook queda a mitad de camino?

---

## Ejercicio 4 — App-of-Apps y ApplicationSet: escalar a muchas apps y muchos clústeres

**Objetivo:** gestionar N aplicaciones desde una sola raíz, y generar Applications dinámicamente con un `ApplicationSet` y un `git generator`.

### Pasos

1. **Patrón App-of-Apps.** Creá una Application "raíz" cuyo `path` contenga *otras* Applications:

   ```yaml
   # bootstrap/root.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: root
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<TU_USUARIO>/gitops-lab.git
       targetRevision: main
       path: bootstrap/apps      # <- carpeta con manifiestos Application
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated: { prune: true, selfHeal: true }
   ```

   En `bootstrap/apps/` colocás un archivo `Application` por cada app (guestbook, ordered, etc.). Al sincronizar `root`, Argo CD crea las hijas.

2. **ApplicationSet con git generator.** En vez de un archivo por app, generá Applications a partir de la *estructura de directorios* del repo. Supongamos que cada carpeta bajo `apps/` es una app desplegable:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: all-apps
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - git:
           repoURL: https://github.com/<TU_USUARIO>/gitops-lab.git
           revision: main
           directories:
             - path: apps/*
     template:
       metadata:
         name: '{{.path.basename}}'
       spec:
         project: default
         source:
           repoURL: https://github.com/<TU_USUARIO>/gitops-lab.git
           targetRevision: main
           path: '{{.path.path}}'
         destination:
           server: https://kubernetes.default.svc
           namespace: '{{.path.basename}}'
         syncPolicy:
           syncOptions: [CreateNamespace=true]
           automated: { prune: true, selfHeal: true }
   ```

   ```bash
   kubectl apply -f applicationset-all-apps.yaml
   kubectl -n argocd get applications
   ```

   Salida esperada: una Application por cada subdirectorio de `apps/`, con nombre = basename de la carpeta:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   Synced        Healthy
   ordered     Synced        Healthy
   ```

3. Probá la elasticidad: agregá una carpeta nueva `apps/redis/` con un manifiesto, commiteá y pusheá. Sin tocar el clúster, el `ApplicationSet` genera la Application `redis` en el siguiente ciclo.

**Preguntas de comprensión (bloque 4)**

1. App-of-Apps y ApplicationSet resuelven el mismo problema de escala. Nombrá dos capacidades del `ApplicationSet` (pensá en *multi-cluster* y en generación por matriz/lista) que el patrón App-of-Apps con archivos estáticos no te da.
2. Con `goTemplateOptions: ["missingkey=error"]`, ¿qué pasa si un template referencia una clave que el generator no produjo, y por qué eso es preferible al comportamiento por defecto en un pipeline de producción?
3. Un `ApplicationSet` con un `cluster generator` puede desplegar la misma app en 50 clústeres. ¿Cuál es el riesgo de *blast radius* de tener `selfHeal: true` en ese template, y cómo lo acotarías (pista: estrategias de rollout progresivo del propio ApplicationSet)?

---

## Ejercicio 5 — Flux CD: el mismo GitOps con GitRepository + Kustomization e image automation

**Objetivo:** implementar el mismo flujo con Flux para contrastar los dos reconciliadores de referencia de la CNCF, y automatizar la promoción de imágenes de vuelta a Git.

### Pasos

1. Instalá Flux y hacé el *bootstrap*. El bootstrap es distintivo: Flux se instala a sí mismo *y* commitea sus propios manifiestos al repo, volviéndose autogestionado:

   ```bash
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux check --pre
   export GITHUB_TOKEN=<tu_pat>
   flux bootstrap github \
     --owner=<TU_USUARIO> \
     --repository=gitops-lab \
     --branch=main \
     --path=clusters/lab \
     --personal
   ```

2. Declará una fuente (`GitRepository`) y una `Kustomization` que la reconcilie:

   ```yaml
   # clusters/lab/guestbook-source.yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: gitops-lab
     namespace: flux-system
   spec:
     interval: 1m
     url: https://github.com/<TU_USUARIO>/gitops-lab.git
     ref:
       branch: main
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: guestbook
     namespace: flux-system
   spec:
     interval: 10m
     retryInterval: 2m
     path: ./apps/guestbook
     prune: true
     sourceRef:
       kind: GitRepository
       name: gitops-lab
     targetNamespace: guestbook
   ```

3. Commiteá, pusheá y forzá una reconciliación inmediata en vez de esperar el `interval`:

   ```bash
   flux reconcile kustomization guestbook --with-source
   flux get kustomizations
   ```

   Salida esperada:

   ```
   NAME        REVISION        SUSPENDED   READY   MESSAGE
   guestbook   main@sha1:ab12   False       True    Applied revision: main@sha1:ab12
   ```

4. **Image automation (promoción de vuelta a Git).** Este es el mecanismo GitOps-puro para actualizar imágenes: Flux escanea el registry, elige un tag por policy y **commitea el cambio al repo** — no muta el clúster directamente. Instalá los controllers de imagen y declará:

   ```yaml
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImageRepository
   metadata: { name: guestbook, namespace: flux-system }
   spec:
     image: gcr.io/google-samples/gb-frontend
     interval: 5m
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImagePolicy
   metadata: { name: guestbook, namespace: flux-system }
   spec:
     imageRepositoryRef: { name: guestbook }
     policy:
       semver: { range: ">=5.0.0" }
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImageUpdateAutomation
   metadata: { name: guestbook, namespace: flux-system }
   spec:
     interval: 5m
     sourceRef: { kind: GitRepository, name: gitops-lab }
     git:
       commit:
         author: { email: fluxbot@example.com, name: fluxbot }
         messageTemplate: "chore: bump images\n\n{{ range .Updated.Images }}{{ println \"-\" . }}{{ end }}"
       push: { branch: main }
     update: { path: ./apps/guestbook, strategy: Setters }
   ```

   Y en el manifiesto marcás el campo actualizable con un *setter marker*:

   ```yaml
   image: gcr.io/google-samples/gb-frontend:v5 # {"$imagepolicy": "flux-system:guestbook"}
   ```

**Preguntas de comprensión (bloque 5)**

1. En el bootstrap, Flux commitea sus propios manifiestos al repo. ¿Qué propiedad operativa gana el propio agente GitOps al quedar bajo control de GitOps (pensá en cómo actualizás o recuperás Flux tras un desastre)?
2. En el `ImageUpdateAutomation`, el escaneo del registry **no** aplica la imagen nueva al clúster: escribe un commit en Git. ¿Por qué ese "rodeo" por Git es fundamentalmente más GitOps que un `kubectl set image` en un pipeline, y qué te da en términos de auditoría y rollback?
3. Contrastá los dos `interval` del `Kustomization` (`interval: 10m` vs `retryInterval: 2m`). ¿Qué representa cada uno y por qué querés que el de reintento sea más corto que el de reconciliación normal?

---

## Ejercicio 6 — GitOps para *infraestructura*: promoción por Pull Request y secretos

**Objetivo:** aplicar el mismo modelo declarativo a infraestructura y cerrar el gap de seguridad de los secretos, que **no** pueden vivir en texto plano en Git.

### Pasos

1. **Promoción entre entornos por PR.** En vez de `argocd app set`, la promoción de `staging`→`production` se hace como un cambio en Git revisable. Estructurá overlays con Kustomize:

   ```
   apps/web/
     base/kustomization.yaml
     overlays/staging/kustomization.yaml     # image tag: v1.4.0
     overlays/production/kustomization.yaml   # image tag: v1.3.0
   ```

   Promover a producción = un PR que cambia el tag en `overlays/production`. Simulá el diff que revisaría un aprobador:

   ```bash
   git switch -c promote-web-v1.4.0
   cd apps/web/overlays/production
   kustomize edit set image web=registry.example.com/web:v1.4.0
   git commit -am "promote: web v1.4.0 to production"
   git push -u origin promote-web-v1.4.0
   # -> se abre un PR; el merge dispara la reconciliación en prod
   ```

2. **Sealed Secrets** para no exponer credenciales en Git. Instalá el controller y sellá un secreto: el `SealedSecret` cifrado *sí* es seguro para commitear porque solo el controller del clúster tiene la clave privada.

   ```bash
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
   echo -n 's3cr3t-pass' | kubectl create secret generic db-cred \
     --dry-run=client --from-file=password=/dev/stdin -o yaml \
     | kubeseal --format yaml \
       --controller-namespace kube-system --controller-name sealed-secrets-controller \
     > apps/web/base/db-cred-sealed.yaml
   git add apps/web/base/db-cred-sealed.yaml && git commit -m "add sealed db credential"
   ```

   El `SealedSecret` resultante contiene solo ciphertext; el controller lo descifra *dentro* del clúster y produce el `Secret` real. Verificá:

   ```bash
   kubectl get sealedsecret,secret db-cred
   ```

3. **Verificá provenance / integridad.** En un flujo maduro, la fuente Git se firma y el reconciliador la verifica. Con Flux:

   ```yaml
   spec:
     ref: { branch: main }
     verify:
       mode: HEAD
       secretRef: { name: git-gpg-pubkeys }
   ```

   Con esto el `GitRepository` rechaza revisiones cuyo commit HEAD no esté firmado por una clave confiable.

**Preguntas de comprensión (bloque 6)**

1. ¿Por qué la promoción `staging`→`production` como *merge de PR* es superior, en términos de auditoría y control de cambios, a promover con un comando imperativo (`argocd app set`, `kubectl set image`)? Nombrá el artefacto exacto que queda como evidencia de la aprobación.
2. Un `SealedSecret` es seguro para commitear pero un `Secret` de Kubernetes no. Explicá dónde vive la clave privada de descifrado y por qué eso significa que un `SealedSecret` **solo** puede ser abierto por el clúster para el que fue sellado.
3. Al llevar infraestructura (redes, buckets, bases de datos vía Crossplane o el Terraform Controller) a GitOps, aparece el problema de *drift* en recursos que también pueden mutarse fuera del clúster (p. ej. alguien cambia una regla de firewall en la consola del cloud). ¿Por qué la reconciliación continua es aún más valiosa —y a la vez más delicada— para infraestructura que para una app stateless?

---

## Respuestas

<details>
<summary>Ver respuestas de todos los bloques</summary>

### Bloque 1 — Argo CD y el modelo pull

1. **StatefulSet por identidad estable y sharding, no por almacenamiento.** El `application-controller` mantiene identidad de red/pod estable y, en despliegues grandes, particiona (*shards*) el conjunto de Applications entre réplicas indexadas de forma determinista. Necesita un ordinal estable para el reparto de shards; un `Deployment` con pods intercambiables no lo garantiza. (No es por PersistentVolume: el estado deseado vive en Git y el observado en la API de K8s.)
2. **El clúster inicia la conexión hacia Git (pull).** El agente vive dentro del clúster y hace *pull* del repo; ningún sistema externo necesita credenciales de `kube-apiserver` ni acceso de red entrante al clúster. En un pipeline *push* clásico, el CI guarda un kubeconfig con permisos amplios y una filtración de ese runner compromete el clúster. Con *pull*, la superficie de ataque se reduce: el clúster solo necesita credenciales de *lectura* del repo, y no expone su API al exterior.
3. **Reconciliación continua (principio 4).** Que el controlador siga comparando estado deseado (Git) vs real (API) en loop, sin que nadie empuje nada, es exactamente "continuously reconciled". También se apoya en "software agents" que hacen *pull*.

### Bloque 2 — Drift y self-heal

1. **`selfHeal` reacciona a cambios en el *estado observado del clúster*, no solo a cambios en Git.** Sin él, `automated` sincroniza cuando cambia el repo, pero un drift hecho con `kubectl` deja el estado `OutOfSync` sin actuar. Con `selfHeal=true`, el controlador detecta la divergencia entre live y desired y re-aplica el manifiesto de Git, revirtiendo las 5 réplicas a 2.
2. **`prune` borra lo que ya no está en Git.** Escenario peligroso: refactorizás la estructura de carpetas o cambiás un `path`/`targetRevision` y, transitoriamente, Git deja de "ver" recursos que en realidad siguen siendo deseados → prune los elimina (p. ej. un `PersistentVolumeClaim` con datos). Mitigaciones: `PruneLast=true`, `prune-propagation`, la anotación `Prune=false` en recursos críticos, `finalizers`, y revisar el *dry-run* del diff antes de sincronizar. Muchos equipos dejan `prune` manual en producción.
3. **Sí, se pueden separar.** *Drift detection* es solo comparar y reportar `OutOfSync`; *self-heal* es corregir automáticamente. Querés detección sin corrección cuando necesitás una *ventana de intervención humana* (p. ej. un incidente en el que hiciste un hotfix imperativo consciente y no querés que el agente lo pise antes de portar el fix a Git), o en entornos donde el equipo aún no confía plenamente en la automatización y prefiere aprobar cada sync.

### Bloque 3 — Sync waves y hooks

1. **Dentro de una wave**, Argo CD aplica en un orden determinístico por *tipo de recurso* (respetando dependencias como namespaces/CRDs antes que sus instancias) y luego por nombre. **Entre waves**, hay una barrera: Argo CD no avanza a la wave siguiente hasta que todos los recursos de la wave actual estén `Healthy` (según sus health checks). Eso permite, p. ej., que una base de datos esté lista antes de arrancar la app que la consume.
2. **Un `PreSync` hook corre en su propia fase, antes de aplicar los recursos regulares, y su fallo aborta el sync completo.** Una migración de DB debe completar *con éxito* antes de tocar la app; si falla, no querés que la nueva versión del Deployment arranque contra un esquema a medio migrar. Un recurso con `sync-wave: "-1"` es parte del sync normal y no tiene la misma semántica de fase/abort ni el ciclo de vida de hook (creación/borrado gestionado).
3. **`BeforeHookCreation`** borra la instancia previa del hook *justo antes de crear la nueva*, garantizando que un Job que quedó a mitad (o `Failed`) de un sync anterior no bloquee la creación por conflicto de nombre. `HookSucceeded` solo borra si tuvo éxito, dejando el objeto fallido presente para inspección — útil para debug, pero puede chocar en el siguiente intento si el nombre es fijo.

### Bloque 4 — App-of-Apps y ApplicationSet

1. Dos capacidades del `ApplicationSet`: (a) **generación multi-cluster** con `cluster generator` — una Application por clúster registrado a partir de un template, algo imposible con archivos estáticos; (b) **generadores dinámicos y compuestos** (`list`, `git`, `matrix`, `merge`, `pull request`, `SCM provider`) que producen Applications a partir de datos externos (directorios, ramas, PRs abiertos), en vez de requerir un archivo `Application` escrito a mano por cada una.
2. Con `missingkey=error`, un template que referencia una clave inexistente **falla la generación de esa Application** en vez de renderizar un valor vacío. En producción eso es preferible porque un campo vacío silencioso (p. ej. un `namespace: ""` o un `path` truncado) puede desplegar en el lugar equivocado o crear recursos mal formados; fallar ruidosamente detiene el error en el generador.
3. El riesgo es que `selfHeal: true` aplicado por un template a 50 clústeres convierte cualquier commit malo en un despliegue instantáneo y simultáneo en toda la flota (blast radius = todos). Se acota con la **`RollingSync` / progressive rollout strategy** del `ApplicationSet` (que actualiza los clústeres en oleadas con criterios de salud entre ellas), sumado a canary/waves, environments escalonados (dev→staging→prod) y `maxUpdate` limitado por paso.

### Bloque 5 — Flux

1. El agente queda **autogestionado y reproducible**: actualizar Flux es un commit al repo (cambiás la versión de sus propios manifiestos y él se reconcilia a sí mismo), y la recuperación ante desastres es re-ejecutar `flux bootstrap` contra el mismo repo/path, que restaura todo el estado del control-plane desde Git. No hay configuración imperativa "fuera de Git" que puedas perder.
2. Porque escribir la imagen nueva como **commit en Git** mantiene a Git como *única fuente de verdad*: el estado desplegado siempre corresponde a un commit auditable, con autor, timestamp y mensaje. El rollback es `git revert`. Un `kubectl set image` en un pipeline muta el clúster directamente, creando drift respecto de Git (el repo ya no describe lo que corre) y perdiendo el registro de quién/cuándo/por qué; el rollback deja de ser un revert de Git.
3. `interval: 10m` es el período de **reconciliación normal** (cada cuánto Flux re-aplica y verifica convergencia aunque nada haya cambiado). `retryInterval: 2m` es el período de **reintento tras un fallo** de reconciliación. Querés el de reintento más corto para *recuperarte rápido* de errores transitorios (un registry caído, un timeout de API) sin esperar el ciclo normal completo, mientras que en estado sano un intervalo más largo reduce carga sobre la API y el repo.

### Bloque 6 — Infraestructura y secretos

1. El *merge de PR* deja como evidencia el **Pull Request aprobado y mergeado**: contiene el diff exacto, los revisores/aprobadores (con quién y cuándo aprobó, vía branch protection/CODEOWNERS), los checks de CI y el commit de merge inmutable. Un comando imperativo no produce ningún artefacto revisable ni exige aprobación de un segundo par; el cambio ocurre sin control de cambios ni traza reproducible.
2. La **clave privada de descifrado vive solo en el `sealed-secrets-controller` dentro del clúster** (generada por ese controller, nunca sale). `kubeseal` cifra usando la clave *pública* del controller y, por diseño, el ciphertext está ligado (por defecto) al *namespace + nombre* de destino, de modo que solo ese controller —en ese clúster— puede descifrarlo. Por eso el `SealedSecret` es seguro en Git: sin la clave privada del clúster, el ciphertext es inútil para un atacante.
3. Para infraestructura la reconciliación continua es **más valiosa** porque los recursos cloud son mutables desde muchas vías fuera del clúster (consola web, otro IaC, un script), así que el drift es más probable y más peligroso (una regla de firewall abierta a mano puede quedar meses); reconciliar continuamente la cierra de vuelta al estado declarado. Y es **más delicada** porque revertir infraestructura no es idempotente ni instantáneo como un pod: recrear/mutar una base de datos o una red puede causar downtime, pérdida de datos o dependencias colgadas, así que `prune`/self-heal sobre recursos con estado exige salvaguardas (deletion policies, `Retain`, revisión manual) mucho más estrictas que sobre una app stateless.

</details>