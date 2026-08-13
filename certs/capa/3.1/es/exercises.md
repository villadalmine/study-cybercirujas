# Argo CD — Ejercicios guiados (CAPA 3.1)

> **Prerrequisitos:** Un cluster de Kubernetes en ejecución (kind, minikube o k3d sirven), `kubectl` configurado contra él, y el CLI `argocd` instalado (`brew install argocd` / [descargar desde releases](https://github.com/argoproj/argo-cd/releases)). Cada comando de abajo está pensado para escribirse y observarse — leé la salida esperada, no te limites a copiar y pegar. Los términos técnicos se mantienen en inglés a propósito; son los términos que usan el examen y la API.
>
> **Fuentes:** Currículum CAPA de la CNCF ([cncf/curriculum `capa/README.md`](https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md)) · Documentación de Argo CD ([argo-cd.readthedocs.io/en/stable](https://argo-cd.readthedocs.io/en/stable/)).

---

## Ejercicio 1 — Instalar Argo CD y llegar a la API/UI

**Objetivo:** Poner en marcha Argo CD dentro del cluster y entender qué componentes acabás de desplegar.

1. Creá el namespace que Argo CD espera e instalá el manifiesto non-HA:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Observá cómo levantan las workloads. **No** avances hasta que cada pod esté `Running`/`1/1`:

   ```bash
   kubectl -n argocd get pods
   ```

   Esperado (los nombres/hashes varían):

   ```
   NAME                                                READY   STATUS    RESTARTS   AGE
   argocd-application-controller-0                     1/1     Running   0          90s
   argocd-applicationset-controller-6c8b7d9f5-abcde    1/1     Running   0          90s
   argocd-dex-server-7f9c6c8b7d-fghij                  1/1     Running   0          90s
   argocd-notifications-controller-5d6b7c8f9-klmno     1/1     Running   0          90s
   argocd-redis-6b8f7c9d5-pqrst                        1/1     Running   0          90s
   argocd-repo-server-7c9d8f6b5-uvwxy                  1/1     Running   0          90s
   argocd-server-6f8c7d9b5-z1234                       1/1     Running   0          90s
   ```

3. La contraseña inicial de admin se guarda en un secret. Leéla (nunca la subas al repo):

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d ; echo
   ```

4. Hacé port-forward del API server e iniciá sesión con el CLI. El server sirve gRPC y HTTP en el mismo puerto, así que `--insecure` se salta la verificación del certificado autofirmado para este lab:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 &
   argocd login localhost:8080 --username admin \
     --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
     --insecure
   ```

   Esperado:

   ```
   'admin:login' logged in successfully
   Context 'localhost:8080' updated
   ```

**Punto de control de comprensión**

- **Q1.1** — Instalaste varios deployments más un StatefulSet. ¿Cuál componente es el StatefulSet y *por qué* es un StatefulSet en lugar de un Deployment?
- **Q1.2** — Nombrá la función de cada uno de estos tres: `argocd-repo-server`, `argocd-application-controller`, `argocd-server`.
- **Q1.3** — La contraseña vive en `argocd-initial-admin-secret`. ¿Cuál es la acción recomendada después del primer login y qué pasa con ese secret?

---

## Ejercicio 2 — Tu primera Application: imperativa vs. declarativa

**Objetivo:** Crear la misma Application de dos maneras y entender que Argo CD es fundamentalmente *declarativo* — el CLI es una comodidad por encima de un CRD.

1. Creá una Application de forma imperativa apuntando al repo de ejemplo canónico:

   ```bash
   argocd app create guestbook \
     --repo https://github.com/argoproj/argocd-example-apps.git \
     --path guestbook \
     --dest-server https://kubernetes.default.svc \
     --dest-namespace default
   ```

2. Inspeccioná lo que Argo CD sabe ahora. Fijate en el `Sync Status` y el `Health Status`:

   ```bash
   argocd app get guestbook
   ```

   Esperado (abreviado):

   ```
   Name:               argocd/guestbook
   Project:            default
   Server:             https://kubernetes.default.svc
   Namespace:          default
   Repo:               https://github.com/argoproj/argocd-example-apps.git
   Target:
   Path:               guestbook
   SyncWindow:         Sync Allowed
   Sync Policy:        Manual
   Sync Status:        OutOfSync from  (53e28ff)
   Health Status:      Missing

   GROUP  KIND        NAMESPACE  NAME          STATUS     HEALTH   HOOK  MESSAGE
          Service     default    guestbook-ui  OutOfSync  Missing
   apps   Deployment  default    guestbook-ui  OutOfSync  Missing
   ```

3. La Application está registrada pero todavía no hay nada desplegado — la sync policy `Manual` significa que Argo CD no actuará por su cuenta. Dispará una sync:

   ```bash
   argocd app sync guestbook
   ```

4. Ahora borrá la app imperativa y recreála de forma declarativa para que puedas ver el objeto real. Guardá esto como `guestbook-app.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: default
     syncPolicy:
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   argocd app delete guestbook --yes
   kubectl apply -f guestbook-app.yaml
   ```

**Punto de control de comprensión**

- **Q2.1** — `argocd app create ...` y aplicar el YAML de la `Application` producen el mismo resultado. ¿Qué representación es la fuente de verdad y dónde vive físicamente el objeto?
- **Q2.2** — En el manifiesto se usa `targetRevision: HEAD`. ¿Por qué `HEAD` (o una rama mutable como `main`) es una elección riesgosa para una Application de producción, y qué fijarías en su lugar?
- **Q2.3** — ¿Para qué sirve el finalizer `resources-finalizer.argocd.argoproj.io`? ¿Qué diferencia de comportamiento ves cuando hacés `kubectl delete` de la Application *con* él vs. *sin* él?

---

## Ejercicio 3 — Sync automatizada: `prune`, `selfHeal` y drift

**Objetivo:** Activar la promesa central de GitOps — la reconciliación continua — y provocar drift para verlo corregirse.

1. Parcheá la Application para habilitar la sync automatizada con pruning y self-heal:

   ```bash
   kubectl -n argocd patch application guestbook --type merge -p '
   spec:
     syncPolicy:
       automated:
         prune: true
         selfHeal: true'
   ```

2. Confirmá que reconcilió a `Synced` / `Healthy`:

   ```bash
   argocd app get guestbook --refresh
   ```

3. **Provocá drift.** Escalá manualmente el Deployment vivo lejos del estado deseado de Git:

   ```bash
   kubectl -n default scale deployment guestbook-ui --replicas=5
   kubectl -n default get deployment guestbook-ui
   ```

4. Esperá unos segundos (la reconciliación por defecto es ~180s, pero `selfHeal` también reacciona al evento del cluster), luego volvé a chequear. El controller debería haber revertido el número de réplicas a lo que dice Git:

   ```bash
   argocd app get guestbook --refresh
   kubectl -n default get deployment guestbook-ui
   ```

5. **Provocá un escenario de prune.** Creá manualmente un recurso huérfano *dentro* del namespace rastreado por la app que Git no declara, luego observá que Argo CD **no** borra recursos que no le pertenecen:

   ```bash
   kubectl -n default create configmap not-in-git --from-literal=x=1
   argocd app get guestbook --refresh   # still Synced; the ConfigMap is untracked, not pruned
   ```

**Punto de control de comprensión**

- **Q3.1** — Distinguí `prune: true` de `selfHeal: true`. Dá un cambio concreto del que cada uno — y solo ese — es responsable de revertir.
- **Q3.2** — En el paso 5, el ConfigMap suelto no se borró a pesar de `prune: true`. ¿Por qué? ¿Qué determina si un recurso es candidato a *prune*?
- **Q3.3** — Con `selfHeal: false` (el valor por defecto incluso cuando `automated` está configurado), ¿qué pasa cuando alguien hace `kubectl edit` de un recurso vivo? ¿Cuál es el Sync Status de la app y Argo CD cambia algo?
- **Q3.4** — ¿Por qué se considera peligroso habilitar el `prune` automatizado sin una compuerta de revisión? Nombrá la sync option que agrega una red de seguridad contra el pruning de la *última* réplica de un tipo de recurso.

---

## Ejercicio 4 — Ordenar con sync waves y resource hooks

**Objetivo:** Controlar el *orden* dentro de una sync — la diferencia entre "aplicar todo de una vez" y "correr el Job de migración, esperar, y luego desplegar la app".

1. Entendé los dos mecanismos de ordenamiento:
   - **Sync phases** (vía `argocd.argoproj.io/hook`): `PreSync` → `Sync` → `PostSync`, más `SyncFail`.
   - **Sync waves** (vía `argocd.argoproj.io/sync-wave`, un entero, por defecto `0`): ordenamiento *dentro* de una fase, el más bajo primero, se permiten negativos.

2. Creá un manifiesto que corra un Job de migración de base de datos como un hook `PreSync`, y luego despliegue la app. Guardá como `ordered.yaml` y agregalo a un path/repo de prueba propio (o aplicalo directamente para explorar las annotations):

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
             image: migrate/migrate:v4.17.1
             args: ["-help"]
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
     annotations:
       argocd.argoproj.io/sync-wave: "0"
   data:
     ready: "true"
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     annotations:
       argocd.argoproj.io/sync-wave: "1"
   spec:
     replicas: 1
     selector: { matchLabels: { app: web } }
     template:
       metadata: { labels: { app: web } }
       spec:
         containers:
           - name: web
             image: nginx:1.27-alpine
   ```

3. Hacé la sync y observá el ordenamiento en vivo:

   ```bash
   argocd app sync <your-app> --prune
   argocd app get <your-app> --refresh
   ```

   Orden esperado en el árbol de recursos: el hook **PreSync** `db-migrate` corre y termina primero, luego dentro de la fase Sync se aplica `app-config` (wave 0) antes que `web` (wave 1). El Job del hook se borra una vez que tiene éxito.

**Punto de control de comprensión**

- **Q4.1** — Un hook `PreSync` (wave 5) y un recurso `Sync` (wave -10) están en la misma sync. ¿Cuál se aplica primero y por qué? (Enunciá la regla de precedencia entre fases y waves.)
- **Q4.2** — ¿Qué espera Argo CD entre waves antes de proceder a la siguiente?
- **Q4.3** — Contrastá los valores de `hook-delete-policy` `HookSucceeded`, `HookFailed` y `BeforeHookCreation`. ¿Cuál mantiene un Job de migración fallido para que puedas inspeccionarlo?
- **Q4.4** — ¿Cuándo usarías un hook `SyncFail`, y corre en una sync *sana*?

---

## Ejercicio 5 — Gestionar muchas apps: App-of-Apps y ApplicationSet

**Objetivo:** Escalar de una Application a flotas sin escribir a mano una `Application` por entorno/cluster.

1. **App-of-Apps.** Creá una Application padre cuyo path de Git contenga manifiestos `Application` *hijos*. Argo CD sincroniza al padre, que crea a los hijos, que sincronizan sus propias workloads. Bosquejo del padre:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: bootstrap
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/gitops.git
       targetRevision: HEAD
       path: apps            # this directory holds child Application YAMLs
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd     # children are Applications; they live in argocd
     syncPolicy:
       automated: { prune: true, selfHeal: true }
   ```

2. **ApplicationSet.** Reemplazá los hijos mantenidos a mano con un generator. Este generator `list` genera (templatiza) una Application por elemento:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: guestbook-fleet
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - list:
           elements:
             - cluster: dev
               url: https://kubernetes.default.svc
             - cluster: staging
               url: https://kubernetes.default.svc
     template:
       metadata:
         name: '{{.cluster}}-guestbook'
       spec:
         project: default
         source:
           repoURL: https://github.com/argoproj/argocd-example-apps.git
           targetRevision: HEAD
           path: guestbook
         destination:
           server: '{{.url}}'
           namespace: '{{.cluster}}-guestbook'
         syncPolicy:
           syncOptions: ["CreateNamespace=true"]
           automated: { prune: true, selfHeal: true }
   ```

3. Aplicalo y confirmá que las Applications generadas aparecen:

   ```bash
   kubectl apply -f applicationset.yaml
   kubectl -n argocd get applications
   ```

   Esperado:

   ```
   NAME               SYNC STATUS   HEALTH STATUS
   dev-guestbook      Synced        Healthy
   staging-guestbook  Synced        Healthy
   ```

**Punto de control de comprensión**

- **Q5.1** — Ambos patrones gestionan muchas apps. ¿Cuál es la diferencia fundamental en *cómo* llegan a existir las Applications hijas (quién las autora)?
- **Q5.2** — Nombrá tres generators de ApplicationSet además de `list`, y dá un caso de uso de una línea para cada uno.
- **Q5.3** — Borrás un `element` de la `list` del ApplicationSet. ¿Qué le pasa a esa Application generada y a sus workloads por defecto? ¿Qué campo controla si la Application removida se borra realmente?
- **Q5.4** — ¿Por qué el generator `git` suele emparejarse con el modo "directory" o "files" para incorporar un nuevo microservicio con un solo PR?

---

## Ejercicio 6 — Diffing, health y troubleshooting de `OutOfSync`

**Objetivo:** Leer el modelo de diff y de health de Argo CD como lo harías durante un incidente.

1. Introducí un cambio *legítimo pero externo* y observá el diff que Argo CD calcula entre lo deseado (Git) y lo vivo (cluster):

   ```bash
   kubectl -n default set image deployment/guestbook-ui guestbook-ui=gcr.io/heptio-images/ks-guestbook-demo:0.1
   argocd app diff guestbook
   ```

   Esperado (unified diff, vivo vs. deseado):

   ```
   ===== apps/Deployment default/guestbook-ui ======
   ...
   -         image: gcr.io/heptio-images/ks-guestbook-demo:0.1
   +         image: gcr.io/heptio-images/ks-guestbook-demo:0.2
   ```

2. Inspeccioná el health de un recurso cuyo health no es trivial (un Deployment está `Healthy` solo cuando su rollout se completa):

   ```bash
   argocd app get guestbook -o wide
   ```

3. **Suprimí diffs benignos.** Una molestia común en producción: un mutating admission controller o el API server inyecta campos (p. ej. `replicas` gestionado por un HPA). Agregá `ignoreDifferences` para que esos no causen un `OutOfSync` permanente:

   ```yaml
   spec:
     ignoreDifferences:
       - group: apps
         kind: Deployment
         jsonPointers:
           - /spec/replicas
   ```

4. Forzá una comparación fresca saltándote el cache del repo cuando sospechás un estado obsoleto:

   ```bash
   argocd app get guestbook --hard-refresh
   ```

**Punto de control de comprensión**

- **Q6.1** — Argo CD reporta `Sync Status` y `Health Status` como dos ejes independientes. Dá una combinación real donde una app esté `Synced` pero `Degraded`, y una donde esté `OutOfSync` pero `Healthy`.
- **Q6.2** — ¿Cuál es la diferencia entre `--refresh` y `--hard-refresh`? ¿Qué cache invalida cada uno?
- **Q6.3** — Agregás `ignoreDifferences` para `/spec/replicas`. ¿Cuál es el trade-off — a qué drift quedás ahora *ciego*?
- **Q6.4** — Para un `CustomResource` que Argo CD no entiende, el health se muestra como `Unknown`/`Progressing` para siempre. ¿Qué mecanismo te permite enseñarle a Argo CD cómo evaluar el health de ese CR?

---

## Ejercicio 7 — Multi-tenancy: AppProjects, RBAC y sync windows

**Objetivo:** Imponer barandas para que un equipo pueda autoservirse sin desplegar YAML de cluster-admin en `kube-system`.

1. Creá un `AppProject` que restrinja *dónde* y *qué* puede desplegar un equipo:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: team-a
     namespace: argocd
   spec:
     description: Team A tenant
     sourceRepos:
       - 'https://github.com/your-org/team-a-*'
     destinations:
       - server: https://kubernetes.default.svc
         namespace: 'team-a-*'
     clusterResourceWhitelist:
       - group: ''
         kind: Namespace
     namespaceResourceBlacklist:
       - group: ''
         kind: ResourceQuota
     roles:
       - name: deployer
         description: Sync rights within team-a
         policies:
           - p, proj:team-a:deployer, applications, sync, team-a/*, allow
           - p, proj:team-a:deployer, applications, get, team-a/*, allow
     syncWindows:
       - kind: deny
         schedule: '0 22 * * *'
         duration: 8h
         applications:
           - '*'
         manualSync: false
   ```

2. Aplicalo, luego intentá crear una Application en este proyecto que viole una restricción (p. ej. un repo fuera de `team-a-*` o un namespace de destino fuera de `team-a-*`):

   ```bash
   kubectl apply -f team-a-project.yaml
   argocd app create rogue \
     --project team-a \
     --repo https://github.com/other-org/app.git \
     --path . --dest-server https://kubernetes.default.svc --dest-namespace kube-system
   ```

   Esperado — la solicitud es rechazada:

   ```
   FATA[0000] rpc error: code = InvalidArgument desc = application repo https://github.com/other-org/app.git is not permitted in project 'team-a'
   ```

3. Inspeccioná la sync window de tipo deny: durante la ventana nocturna de 8 horas, las syncs automatizadas se bloquean:

   ```bash
   argocd app get <app-in-team-a>    # look for the SyncWindow line
   ```

**Punto de control de comprensión**

- **Q7.1** — Distinguí `clusterResourceWhitelist` de `namespaceResourceBlacklist`. ¿Por qué Argo CD tiene por defecto una whitelist de recursos de cluster vacía (es decir, ningún recurso cluster-scoped permitido a menos que esté listado)?
- **Q7.2** — Las líneas de política RBAC son `p, <subject>, <resource>, <action>, <object>, <effect>`. Decodificá `p, proj:team-a:deployer, applications, sync, team-a/*, allow`. ¿Con qué hace match el glob de objeto `team-a/*`?
- **Q7.3** — Una sync window `deny` con `manualSync: false` está activa. ¿Puede un operador aún sincronizar a mano? ¿Qué cambia si `manualSync: true`?
- **Q7.4** — ¿Cuál es el propósito de seguridad del AppProject `default`, y por qué endurecerlo o reemplazarlo es un paso temprano de hardening?

---

## Ejercicio 8 — Rollback e historial

**Objetivo:** Tratar un deploy malo como un evento reversible de primera clase.

1. Listá el historial de deploys que Argo CD retiene por Application:

   ```bash
   argocd app history guestbook
   ```

   Esperado:

   ```
   ID  DATE                           REVISION
   0   2026-08-12 09:14:02 +0000 UTC  (53e28ff)
   1   2026-08-12 10:02:41 +0000 UTC  (a1b2c3d)
   2   2026-08-12 11:30:18 +0000 UTC  (f4e5d6c)
   ```

2. Hacé rollback a una revisión previa conocida como buena por su ID de historial:

   ```bash
   argocd app rollback guestbook 1
   ```

3. Observá: el rollback fija la Application a esa revisión y — importante — **deshabilita la sync automatizada** para evitar que el controller re-aplique inmediatamente `HEAD` por encima de tu rollback.

**Punto de control de comprensión**

- **Q8.1** — ¿Por qué `argocd app rollback` debe pausar la sync automatizada? ¿Qué pasaría si no lo hiciera?
- **Q8.2** — El rollback restaura los *manifiestos* de una revisión vieja de Git. ¿Qué estado **no** restaura, y por qué "rollback de GitOps ≠ rollback de base de datos" es una advertencia importante?
- **Q8.3** — ¿De dónde viene el historial — del proveedor de Git, o del registro propio de Argo CD? ¿Cuál es la implicación si hacés `argocd app delete` y recreás la Application?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **A1.1** — `argocd-application-controller` es el StatefulSet. Es stateful porque es dueño del loop de reconciliación y reparte (shards) las Applications entre las réplicas del controller por una identidad estable; un ordinal/identidad de pod estable permite que el sharding sea determinista. (Redis es un Deployment porque es un cache descartable — Argo CD reconstruye su estado desde el cluster y Git, así que perder Redis no es pérdida de datos.)
- **A1.2** — `argocd-repo-server` clona los repos de Git y *renderiza* manifiestos (corre Helm/Kustomize/plugins) a YAML plano. `argocd-application-controller` compara ese estado deseado renderizado contra el estado vivo del cluster y realiza las syncs / reporta el health. `argocd-server` es el front end de API/gRPC + UI web (auth, aplicación de RBAC, servir el CLI y la UI) — **no** hace la reconciliación en sí.
- **A1.3** — Cambiá la contraseña de admin (`argocd account update-password`) y luego borrá `argocd-initial-admin-secret`. Es solo una comodidad de bootstrap; es seguro borrarlo una vez que iniciaste sesión y rotaste, y la buena práctica es deshabilitar por completo la cuenta local `admin` en favor de SSO/Dex.

**Ejercicio 2**

- **A2.1** — El custom resource `Application` es la fuente de verdad; el CLI solo crea/parchea ese CR vía la API. El objeto vive físicamente como una instancia de CRD en el namespace `argocd` del cluster (`kubectl -n argocd get applications`).
- **A2.2** — `HEAD`/`main` es *mutable* — cualquier push cambia silenciosamente el estado deseado, así que lo que se despliega no es reproducible y un commit malo se auto-propaga. Fijá un commit SHA de Git específico (o un tag inmutable) para producción, de modo que el estado desplegado sea determinista y auditable.
- **A2.3** — El finalizer dispara el **borrado en cascada**: borrar la Application primero elimina (prune) todos los recursos que gestiona, y luego remueve la Application. Sin el finalizer, borrar la Application deja las workloads desplegadas huérfanas/corriendo en el cluster (un borrado "non-cascading").

**Ejercicio 3**

- **A3.1** — `selfHeal: true` revierte cambios hechos *directamente sobre recursos vivos* que se desvían (drift) de Git (p. ej. alguien escaló réplicas o editó una imagen en el cluster). `prune: true` borra recursos que fueron *removidos de Git* pero todavía existen en el cluster. selfHeal arregla ediciones; prune remueve borrados.
- **A3.2** — El pruning solo aplica a recursos que Argo CD **rastrea** (los que aplicó previamente y etiquetó/anotó como pertenecientes a la app, p. ej. vía la label/annotation de tracking). El ConfigMap suelto se creó por fuera, no está en el conjunto gestionado de la app, así que se trata como no rastreado (untracked), no como candidato a prune.
- **A3.3** — Con `selfHeal: false`, un `kubectl edit` manual hace que la app pase a `OutOfSync`, y Argo CD **reporta** el drift pero **no** lo corrige — la reconciliación solo re-aplica desde Git ante un disparador de sync explícito/automático, no ante el drift en vivo. La workload conserva el valor editado hasta la próxima sync.
- **A3.4** — El auto-prune puede propagar en cascada un borrado accidental en Git hasta borrar recursos vivos en toda la flota sin una compuerta humana. La sync option `PruneLast=true` difiere el pruning al final de la sync; `PrunePropagationPolicy` controla la propagación del borrado; y el controller se niega a hacer prune hasta cero cuando el comportamiento "prune requires confirmation" / la guarda `allowEmpty` no se satisface (los `preserveResourcesOnDeletion` / `allowEmpty` de un ApplicationSet protegen contra borrar todo).

**Ejercicio 4**

- **A4.1** — El recurso **PreSync** se aplica primero. Las fases tienen precedencia absoluta sobre las waves: todo el PreSync corre (en orden de wave entre los recursos PreSync) antes que *cualquier* recurso Sync, sin importar que el recurso Sync tenga un número de wave menor/negativo. Las waves solo ordenan recursos *dentro de la misma fase*.
- **A4.2** — Argo CD espera a que todos los recursos de la wave actual queden **Healthy** (y a que los hooks de esa wave se completen) antes de empezar la siguiente wave.
- **A4.3** — `HookSucceeded` borra el objeto del hook después de que tiene éxito; `HookFailed` lo borra después de que falla; `BeforeHookCreation` borra la instancia *previa* del hook justo antes de crear la nueva (así queda exactamente uno entre corridas). Para mantener un Job de migración fallido para el post-mortem, usá `HookSucceeded` **únicamente** (o ninguna política de borrado) para que un fallo *no* se auto-borre.
- **A4.4** — Un hook `SyncFail` corre solo cuando la operación de sync falla (p. ej. para enviar una alerta, revertir una migración, o limpiar estado parcial). **No** corre en una sync exitosa/sana.

**Ejercicio 5**

- **A5.1** — En App-of-Apps, un humano autora y commitea cada manifiesto `Application` hijo a Git; el padre solo los aplica. En ApplicationSet, los hijos son *generados* programáticamente por el controller de ApplicationSet a partir de un generator + template — mantenés las entradas del generator, no un archivo por app.
- **A5.2** — `cluster` (desplegar una app en todos/los clusters registrados seleccionados — rollout multi-cluster); `git` (una app por directorio o por archivo de configuración descubierto en un repo — onboarding autoservicio vía PR); `matrix`/`merge` (combinar dos generators, p. ej. cada app × cada cluster); `pullRequest` (levantar un entorno de preview/efímero por cada PR abierto); `scmProvider` (una app por repo en una organización de GitHub/GitLab).
- **A5.3** — Por defecto la Application generada se borra, y como las Applications generadas llevan borrado en cascada, sus workloads también se remueven. `preserveResourcesOnDeletion: true` (y/o la configuración de finalizer del ApplicationSet) controla si los recursos subyacentes se limpian realmente vs. se dejan corriendo.
- **A5.4** — Con un generator `git` (directory/files), agregar un nuevo microservicio es solo commitear un nuevo directorio o archivo de values al repo vigilado; el controller lo descubre y genera la Application automáticamente — sin cambios en la config de Argo CD, así que el onboarding es un solo PR.

**Ejercicio 6**

- **A6.1** — `Synced` + `Degraded`: Git y el cluster coinciden exactamente, pero los pods del Deployment están en CrashLoop (imagen mala) — el estado deseado está aplicado, la workload simplemente está unhealthy. `OutOfSync` + `Healthy`: alguien pusheó un nuevo tag de imagen a Git (lo deseado cambió) pero la versión vieja en ejecución está perfectamente sana; la app está healthy pero ya no coincide con Git.
- **A6.2** — `--refresh` vuelve a comparar contra los manifiestos renderizados *cacheados* / el último fetch de Git (una reconciliación normal). `--hard-refresh` además invalida el cache de manifiestos del repo-server y re-renderiza desde Git, se usa cuando sospechás un render de Helm/Kustomize obsoleto o un estado de repo cacheado.
- **A6.3** — Ahora quedás ciego a *cualquier* cambio de réplicas, incluyendo un cambio accidental legítimo commiteado a Git o un escalado externo inesperado — Argo CD nunca más marcará el drift de `/spec/replicas`, así que dependés por completo de que el HPA/lo que sea que lo gestione esté correcto.
- **A6.4** — Un **custom health check** escrito en Lua, configurado en el ConfigMap `argocd-cm` (`resource.customizations.health.<group_kind>`), le enseña a Argo CD cómo mapear el status de ese CR a `Healthy`/`Progressing`/`Degraded`.

**Ejercicio 7**

- **A7.1** — `clusterResourceWhitelist` es una lista de permitidos para kinds *cluster-scoped* (p. ej. `Namespace`, `ClusterRole`); nada cluster-scoped puede crearse a menos que esté explícitamente listado. `namespaceResourceBlacklist` es una lista de denegados para kinds *namespaced*. La whitelist de cluster vacía por defecto es una postura de seguridad: los recursos cluster-scoped tienen un radio de impacto alto, así que a un proyecto tenant hay que otorgarle cada uno explícitamente en lugar de que los reciba por defecto.
- **A7.2** — Al subject `proj:team-a:deployer` (el rol del proyecto) se le permite la acción `sync` sobre el recurso `applications` para objetos que hacen match con `team-a/*`. El glob de objeto es `<project>/<application-name>`, así que `team-a/*` = cualquier Application en el proyecto `team-a`.
- **A7.3** — Con `manualSync: false`, una ventana `deny` activa también bloquea las syncs manuales — nadie puede sincronizar hasta que la ventana cierre. Con `manualSync: true`, las syncs automatizadas siguen bloqueadas durante la ventana pero un operador puede anular y sincronizar a mano (útil para arreglos de emergencia durante un congelamiento de cambios).
- **A7.4** — Toda Application sin un proyecto explícito cae en `default`, que viene completamente abierto (cualquier repo, cualquier destino, cualquier recurso). Dejarlo permisivo significa que una Application errónea o maliciosa puede desplegar cualquier cosa en cualquier lugar, así que endurecer o remover `default` y forzar a cada app a un proyecto acotado es un primer paso de hardening.

**Ejercicio 8**

- **A8.1** — Porque con la sync automatizada todavía activa, el controller detectaría inmediatamente que el estado vivo (la revisión revertida) está `OutOfSync` con el `HEAD` de Git y re-aplicaría `HEAD` — deshaciendo tu rollback en un solo loop de reconciliación. Pausar la auto-sync deja que el rollback se sostenga hasta que arregles Git.
- **A8.2** — Restaura solo los *manifiestos declarativos* (los objetos de Kubernetes). **No** restaura datos mutados por la app en ejecución — esquema/filas de base de datos, contenidos de PVC, estado externo. Una migración que corrió bajo el release malo no se revierte al revertir los manifiestos, y por eso un rollback de GitOps debe emparejarse con un plan explícito de rollback de datos/migración.
- **A8.3** — El historial es el registro propio de deploys por Application de Argo CD (las revisiones que efectivamente sincronizó), almacenado en el status de la Application, no en el log de Git. Si hacés `argocd app delete` y recreás la Application, ese historial se pierde — el nuevo objeto empieza un historial fresco aunque el repo de Git esté sin cambios.

</details>