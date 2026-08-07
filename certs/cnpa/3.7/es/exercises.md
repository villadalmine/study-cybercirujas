# Ejercicios guiados — Tema 3.7: GitOps for Multi-Environment Application Management

> **Objetivo del tema.** Modelar el ciclo de vida de una aplicación a través de `dev → staging → prod` de forma declarativa, donde Git es la *única* fuente de verdad y un controlador (Argo CD / Flux) reconcilia el estado deseado contra el clúster. Vas a construir la estructura de repositorio, desplegarla con un GitOps controller, promover cambios entre entornos, escalar a N entornos con `ApplicationSet`, y operar drift/self-heal.
>
> **Prerequisitos de laboratorio.** Un clúster (kind/minikube sirve), `kubectl`, `kustomize` (o `kubectl -k`), `helm`, y acceso a un repositorio Git propio (podés usar uno local con `git init --bare` o GitHub). Los ejemplos asumen Argo CD como controller de referencia porque es el más frecuente en el examen, con una sección paralela para Flux.

---

## Ejercicio 1 — Estructura de repositorio multi-entorno con Kustomize (base + overlays)

La decisión estructural que más impacto tiene en GitOps multi-entorno es **cómo se comparte lo común y se aísla lo específico de cada entorno**. Kustomize resuelve esto con un `base` sin duplicación y `overlays` que parchean.

### Pasos

1. Creá el esqueleto del repositorio de configuración:

   ```bash
   mkdir -p gitops-repo/apps/web/base
   mkdir -p gitops-repo/apps/web/overlays/{dev,staging,prod}
   cd gitops-repo
   git init
   ```

2. Escribí el `base` — un `Deployment` y un `Service` genéricos, sin ningún valor específico de entorno:

   ```yaml
   # apps/web/base/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: web
             image: ghcr.io/acme/web:0.1.0
             ports:
               - containerPort: 8080
             resources:
               requests:
                 cpu: 50m
                 memory: 64Mi
               limits:
                 cpu: 250m
                 memory: 128Mi
   ```

   ```yaml
   # apps/web/base/service.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web
     ports:
       - port: 80
         targetPort: 8080
   ```

   ```yaml
   # apps/web/base/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   commonLabels:
     app.kubernetes.io/part-of: web-platform
   ```

3. Escribí el overlay `dev`. Un overlay declara `base` como recurso y aplica *patches* estratégicos y transformadores:

   ```yaml
   # apps/web/overlays/dev/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-dev
   nameSuffix: -dev
   commonLabels:
     env: dev
   resources:
     - ../../base
   images:
     - name: ghcr.io/acme/web
       newTag: 0.1.0-rc.4        # dev sigue la punta
   replicas:
     - name: web
       count: 1
   ```

4. El overlay `staging` — mismo esquema, valores distintos:

   ```yaml
   # apps/web/overlays/staging/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-staging
   nameSuffix: -staging
   commonLabels:
     env: staging
   resources:
     - ../../base
   images:
     - name: ghcr.io/acme/web
       newTag: 0.1.0-rc.4        # staging = candidato a release
   replicas:
     - name: web
       count: 2
   ```

5. El overlay `prod`, con un patch explícito para endurecer el `Deployment` (probes, `securityContext`, réplicas mayores):

   ```yaml
   # apps/web/overlays/prod/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-prod
   nameSuffix: -prod
   commonLabels:
     env: prod
   resources:
     - ../../base
   images:
     - name: ghcr.io/acme/web
       newTag: 0.1.0              # prod = versión estable liberada
   replicas:
     - name: web
       count: 4
   patches:
     - target:
         kind: Deployment
         name: web
       patch: |-
         - op: add
           path: /spec/template/spec/containers/0/readinessProbe
           value:
             httpGet:
               path: /healthz
               port: 8080
             initialDelaySeconds: 5
             periodSeconds: 10
         - op: add
           path: /spec/template/spec/containers/0/livenessProbe
           value:
             httpGet:
               path: /healthz
               port: 8080
             initialDelaySeconds: 15
             periodSeconds: 20
   ```

6. Renderizá cada entorno **sin aplicarlo** y compará las diferencias. Este `build` es exactamente lo que el GitOps controller va a materializar:

   ```bash
   kustomize build apps/web/overlays/dev     > /tmp/dev.yaml
   kustomize build apps/web/overlays/prod    > /tmp/prod.yaml
   diff <(grep -E 'name:|replicas:|image:|namespace' /tmp/dev.yaml) \
        <(grep -E 'name:|replicas:|image:|namespace' /tmp/prod.yaml)
   ```

   Salida esperada (recortada) — se ve el nombre con sufijo, el namespace y el tag divergiendo:

   ```diff
   < namespace: web-dev
   < replicas: 1
   < image: ghcr.io/acme/web:0.1.0-rc.4
   ---
   > namespace: web-prod
   > replicas: 4
   > image: ghcr.io/acme/web:0.1.0
   ```

7. Confirmá el commit inicial:

   ```bash
   git add . && git commit -m "web: base + dev/staging/prod overlays"
   ```

### Preguntas de comprensión

1. ¿Por qué el tag de imagen se fija en cada **overlay** y no en el `base`? ¿Qué patrón anti-GitOps introducirías si el `base` usara `image: web:latest`?
2. Explicá la diferencia entre `commonLabels` (en base) y el `commonLabels: {env: dev}` del overlay. ¿Cuál de los dos rompe el `selector` de un `Deployment` ya desplegado si lo cambiás en caliente, y por qué?
3. `nameSuffix: -dev` hace que el recurso se llame `web-dev`. ¿Qué problema operativo evita tener nombres distintos por entorno cuando después mires todo desde un mismo Argo CD? ¿Qué te obliga a cuidar en el `Service.spec.selector`?
4. El overlay `prod` agrega probes con un JSON6902 patch en vez de un strategic merge patch. ¿En qué caso concreto el `op: add` sobre `/spec/template/spec/containers/0/...` fallaría, y cómo lo mitigás?

---

## Ejercicio 2 — Instalar Argo CD y desplegar el entorno `dev` de forma declarativa

Ahora conectamos el repositorio al clúster. La regla de oro: **el propio Argo CD `Application` también vive en Git** (nada se crea a mano en producción; acá lo hacemos imperativo solo para aprender la mecánica).

### Pasos

1. Instalá Argo CD:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
   ```

2. Obtené la contraseña inicial y accedé a la API/CLI:

   ```bash
   argocd admin initial-password -n argocd
   kubectl -n argocd port-forward svc/argocd-server 8080:443 &
   argocd login localhost:8080 --username admin --insecure
   ```

3. Definí una `Application` que apunte al overlay `dev`. Guardala en el repo bajo `argocd/web-dev.yaml`:

   ```yaml
   # argocd/web-dev.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: web-dev
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/acme/gitops-repo.git
       targetRevision: main
       path: apps/web/overlays/dev
     destination:
       server: https://kubernetes.default.svc
       namespace: web-dev
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

4. Aplicá la `Application` y observá la reconciliación:

   ```bash
   kubectl apply -f argocd/web-dev.yaml
   argocd app get web-dev
   ```

   Salida esperada (recortada):

   ```
   Name:               argocd/web-dev
   Project:            default
   Sync Policy:        Automated (Prune, SelfHeal)
   Sync Status:        Synced to main (a1b2c3d)
   Health Status:      Healthy

   GROUP  KIND        NAMESPACE  NAME      STATUS  HEALTH   HOOK
          Service     web-dev    web-dev   Synced  Healthy
   apps   Deployment  web-dev    web-dev   Synced  Healthy
   ```

5. Verificá que el estado en el clúster coincide con el `kustomize build` del Ejercicio 1:

   ```bash
   kubectl -n web-dev get deploy,svc
   kubectl -n web-dev get deploy web-dev -o jsonpath='{.spec.replicas}{"\n"}'
   ```

### Preguntas de comprensión

1. `finalizers: [resources-finalizer.argocd.argoproj.io]` — ¿qué pasa con los objetos hijos (`Deployment`, `Service`) cuando borrás la `Application` **con** ese finalizer versus sin él? ¿Cómo se llama ese comportamiento?
2. `prune: true` y `selfHeal: true` no son lo mismo. Dado un operador que edita `replicas` a mano con `kubectl scale`, ¿cuál de los dos revierte el cambio? Dado que alguien borra el `resources` del `kustomization.yaml` y commitea, ¿cuál de los dos elimina el objeto del clúster?
3. La `Application` vive en el namespace `argocd`, pero sus recursos van a `web-dev`. ¿Por qué el `destination.namespace` no reemplaza al `namespace:` que ya trae el overlay de Kustomize? ¿Qué gana `CreateNamespace=true` acá?
4. ¿Por qué desplegar la `Application` con `kubectl apply` en un entorno real es un olor a problema, aunque el `Deployment` que crea sí sea "GitOps-compliant"? ¿Cómo se resuelve? (pista: Ejercicio 5)

---

## Ejercicio 3 — Promoción de `dev → staging → prod` vía Git

Acá está el corazón del tema. La promoción **no** es "hacer deploy a prod": es **un cambio en Git** que mueve la versión probada de un overlay al siguiente. El controller hace el resto.

### Pasos

1. Registrá las tres `Application` (una por entorno). Reutilizá el patrón del Ejercicio 2 cambiando `name`, `path` y `namespace`. Confirmá que las tres están `Synced`:

   ```bash
   kubectl apply -f argocd/web-dev.yaml
   kubectl apply -f argocd/web-staging.yaml
   kubectl apply -f argocd/web-prod.yaml
   argocd app list -o wide
   ```

   ```
   NAME         SYNC STATUS  HEALTH   REVISION  PATH
   web-dev      Synced       Healthy  a1b2c3d   apps/web/overlays/dev
   web-staging  Synced       Healthy  a1b2c3d   apps/web/overlays/staging
   web-prod     Synced       Healthy  a1b2c3d   apps/web/overlays/prod
   ```

2. Simulá una nueva build validada en dev: cambiá el tag del overlay `dev` a `0.2.0-rc.1`.

   ```bash
   cd apps/web/overlays/dev
   kustomize edit set image ghcr.io/acme/web=ghcr.io/acme/web:0.2.0-rc.1
   cd -
   git commit -am "web/dev: bump to 0.2.0-rc.1"
   git push
   ```

   Argo CD detecta el commit y sincroniza **solo** `web-dev`. Confirmalo:

   ```bash
   argocd app wait web-dev --sync
   argocd app get web-dev | grep 'Sync Status'
   kubectl -n web-dev get deploy web-dev \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   # -> ghcr.io/acme/web:0.2.0-rc.1
   ```

3. **Promoción a staging.** La promoción es copiar el artefacto ya probado, no reconstruirlo. Movés el mismo tag al overlay `staging`:

   ```bash
   cd apps/web/overlays/staging
   kustomize edit set image ghcr.io/acme/web=ghcr.io/acme/web:0.2.0-rc.1
   cd -
   git commit -am "promote web 0.2.0-rc.1: dev -> staging"
   git push
   argocd app wait web-staging --sync
   ```

4. **Promoción a prod, con revisión humana.** Prod no debe auto-sincronizar cambios de imagen sin aprobación. Volvé manual el `syncPolicy` de prod (quitá `automated`) y dispará el sync explícitamente:

   ```yaml
   # argocd/web-prod.yaml (fragmento)
   syncPolicy:
     syncOptions:
       - CreateNamespace=true
     # sin bloque automated: la promoción a prod requiere sync manual
   ```

   ```bash
   kubectl apply -f argocd/web-prod.yaml     # actualiza la policy
   cd apps/web/overlays/prod
   kustomize edit set image ghcr.io/acme/web=ghcr.io/acme/web:0.2.0
   cd -
   git commit -am "release web 0.2.0: promote to prod"
   git push
   ```

   Ahora `web-prod` queda `OutOfSync` esperando aprobación:

   ```bash
   argocd app get web-prod | grep 'Sync Status'
   # -> Sync Status:  OutOfSync from main (e5f6g7h)
   ```

   Un release manager aprueba con:

   ```bash
   argocd app sync web-prod
   argocd app wait web-prod --sync --health
   ```

5. Auditá quién promovió qué. En GitOps la trazabilidad es el `git log`, no un ticket:

   ```bash
   git log --oneline -- apps/web/overlays/prod/kustomization.yaml
   ```

### Preguntas de comprensión

1. En el paso 3, `staging` recibe el tag `0.2.0-rc.1` **idéntico** al que corrió en dev. ¿Por qué promover el *mismo artefacto inmutable* (y no reconstruir la imagen para staging) es un principio central de GitOps? ¿Qué clase de bug hace imposible detectar el "rebuild per environment"?
2. Prod pasó a sync manual mientras dev y staging quedan automáticos. Nombrá el trade-off exacto: ¿qué ganás y qué perdés respecto de la promesa de "convergencia automática" de GitOps al meter una compuerta humana en prod?
3. Un colega propone promover haciendo `git merge dev → prod` de branches por entorno, en lugar de editar overlays en `main`. Enumerá dos problemas concretos del modelo *branch-per-environment* frente al modelo *directory-per-environment* que usamos acá.
4. Si en el paso 4 el commit a prod tuviera el tag `0.2.0` pero la imagen `0.2.0` **nunca se hubiera construido/pushado** al registry, ¿en qué estado quedan `Sync Status` y `Health Status` de `web-prod` después de `argocd app sync`? ¿Qué te dice eso sobre el límite entre "Git converge" y "la app arranca"?

---

## Ejercicio 4 — Escalar a N entornos con `ApplicationSet`

Mantener una `Application` por entorno escrita a mano no escala a 3 regiones × 4 entornos. `ApplicationSet` genera `Application`s a partir de un *generator*. Vamos con el **Git directory generator**, que crea una `Application` por cada overlay que exista en el repo.

### Pasos

1. Definí un `ApplicationSet` que descubra automáticamente cada carpeta bajo `overlays/`:

   ```yaml
   # argocd/web-appset.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: web
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - git:
           repoURL: https://github.com/acme/gitops-repo.git
           revision: main
           directories:
             - path: apps/web/overlays/*
     template:
       metadata:
         name: 'web-{{.path.basename}}'      # web-dev, web-staging, web-prod
       spec:
         project: default
         source:
           repoURL: https://github.com/acme/gitops-repo.git
           targetRevision: main
           path: '{{.path.path}}'
         destination:
           server: https://kubernetes.default.svc
           namespace: 'web-{{.path.basename}}'
         syncPolicy:
           automated:
             prune: true
             selfHeal: true
           syncOptions:
             - CreateNamespace=true
   ```

2. Antes de aplicar, **borrá** las `Application` manuales para que no colisionen con las generadas, luego aplicá el set:

   ```bash
   argocd app delete web-dev web-staging web-prod --cascade=false
   kubectl apply -f argocd/web-appset.yaml
   kubectl -n argocd get applications
   ```

   Salida esperada — tres `Application` generadas, una por directorio:

   ```
   NAME          SYNC STATUS   HEALTH STATUS
   web-dev       Synced        Healthy
   web-prod      Synced        Healthy
   web-staging   Synced        Healthy
   ```

3. Probá el poder del generator: agregá un cuarto entorno **solo creando una carpeta**:

   ```bash
   cp -r apps/web/overlays/staging apps/web/overlays/qa
   sed -i 's/staging/qa/g' apps/web/overlays/qa/kustomization.yaml
   git add apps/web/overlays/qa && git commit -m "web: add qa environment" && git push
   ```

   Tras el próximo `git generator` poll (default ~3 min, o forzalo), aparece `web-qa` sin tocar ningún `Application`:

   ```bash
   kubectl -n argocd get applications | grep web-qa
   # web-qa   Synced   Healthy
   ```

4. Variante con **list generator** cuando querés control explícito de parámetros por entorno (p.ej. distinto `destination.server` por clúster):

   ```yaml
   # argocd/web-appset-list.yaml (fragmento de generators)
   generators:
     - list:
         elements:
           - env: dev
             cluster: https://kubernetes.default.svc
             autosync: "true"
           - env: prod
             cluster: https://prod-cluster.example.com   # clúster remoto
             autosync: "false"
   ```

   El `template` consume `{{.env}}` y `{{.cluster}}`; el `autosync` puede condicionar el bloque `automated` con Go templating.

### Preguntas de comprensión

1. En el paso 3, agregar `web-qa` no requirió tocar ningún manifiesto de `Application`. Explicá el mecanismo: ¿qué recurso "posee" a las `Application` generadas, y qué pasa con `web-qa` si borrás la carpeta `overlays/qa` del repo?
2. El paso 2 usa `argocd app delete ... --cascade=false`. ¿Por qué `--cascade=false` es crítico acá para no causar un outage durante la migración de `Application` manuales a generadas?
3. Compará **Git directory generator** vs **list generator** para el caso "cada entorno vive en un clúster distinto". ¿Cuál elegirías y por qué el directory generator, por sí solo, no alcanza para setear `destination.server` por entorno?
4. `goTemplateOptions: ["missingkey=error"]` cambia el comportamiento ante una variable inexistente. En un `ApplicationSet` que genera `Application`s de prod, ¿por qué preferís que un template mal escrito **falle ruidosamente** en vez de renderizar un string vacío?

---

## Ejercicio 5 — Orden, hooks, drift y self-heal en producción

Un deploy multi-recurso a menudo tiene dependencias (migración de DB antes que la app). Y en prod hay que detectar y corregir *drift*. Argo CD lo modela con **sync waves**, **resource hooks** y **self-heal**.

### Pasos

1. Ordená el despliegue con `sync-wave`: una `ConfigMap` (wave 0), luego un `Job` de migración (wave 1), luego el `Deployment` (wave 2). Los waves menores se aplican y se esperan `Healthy` antes de pasar al siguiente:

   ```yaml
   # apps/web/base/config.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: web-config
     annotations:
       argocd.argoproj.io/sync-wave: "0"
   data:
     LOG_LEVEL: info
   ---
   # apps/web/base/migrate-job.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: web-migrate
     annotations:
       argocd.argoproj.io/hook: PreSync
       argocd.argoproj.io/hook-delete-policy: HookSucceeded
       argocd.argoproj.io/sync-wave: "1"
   spec:
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: migrate
             image: ghcr.io/acme/web:0.2.0
             command: ["/app/migrate", "--up"]
   ```

   El `Deployment` (del Ejercicio 1) recibe `argocd.argoproj.io/sync-wave: "2"` vía patch de overlay.

2. Aplicá y observá el orden real de reconciliación:

   ```bash
   argocd app sync web-prod
   argocd app get web-prod --show-operation
   ```

   Salida esperada — el hook `PreSync` corre antes que los recursos, y los waves se respetan:

   ```
   GROUP  KIND        NAME         STATUS   HOOK     MESSAGE
          ConfigMap   web-config   Synced            wave 0
   batch  Job         web-migrate  Succeeded PreSync  wave 1, hook completed
   apps   Deployment  web          Synced            wave 2
   ```

3. **Provocá drift** para ver self-heal en acción. Editá el clúster por fuera de Git:

   ```bash
   kubectl -n web-prod scale deploy/web-prod --replicas=9
   argocd app get web-prod | grep -E 'Sync Status|replicas'
   ```

   Con `selfHeal: true`, Argo CD detecta la diferencia y revierte a las 4 réplicas de Git en el próximo reconcile:

   ```bash
   argocd app wait web-prod --sync
   kubectl -n web-prod get deploy web-prod -o jsonpath='{.spec.replicas}{"\n"}'
   # -> 4   (Git ganó)
   ```

4. **Diferenciá drift de un cambio legítimo.** Inspeccioná exactamente qué difiere entre estado vivo y estado deseado:

   ```bash
   argocd app diff web-prod
   ```

   Salida esperada:

   ```diff
   ===== apps/Deployment web-prod/web-prod ======
   <   replicas: 9        # live
   >   replicas: 4        # desired (Git)
   ```

5. **Rollback declarativo.** Si `0.2.0` resultó defectuoso en prod, el rollback correcto es un `git revert`, no `argocd app rollback` (que deja el clúster fuera de sync con Git):

   ```bash
   git revert --no-edit HEAD          # revierte "release web 0.2.0"
   git push
   argocd app sync web-prod           # (manual, porque prod es manual)
   ```

### Preguntas de comprensión

1. `sync-wave` vs `hook: PreSync`: ambos ordenan, pero uno vive en el ciclo de vida del recurso y el otro es efímero. ¿Por qué la migración de DB va como `PreSync` hook con `hook-delete-policy: HookSucceeded` en lugar de un `Job` normal en wave 1? ¿Qué problema de idempotencia evita el `HookSucceeded`?
2. El paso 3 revierte el `kubectl scale` manual. Ahora imaginá que un **HPA** también gestiona `replicas` de ese `Deployment`. Explicá el conflicto que `selfHeal: true` crea con el HPA y cómo lo resolvés (pista: `ignoreDifferences`).
3. `argocd app rollback` vs `git revert`: ambos "vuelven atrás", pero solo uno mantiene el invariante de GitOps. Explicá por qué usar `argocd app rollback` en un entorno con auto-sync produce un cambio que dura segundos.
4. Si el `PreSync` hook (`web-migrate`) falla (exit 1), ¿se aplica igual el `Deployment` de wave 2? ¿En qué queda el `Sync Status` de la `Application`, y por qué este comportamiento es exactamente lo que querés para una migración de esquema?

---

## Ejercicio 6 — Aislamiento por entorno con `AppProject` y RBAC (bonus de producción)

En multi-entorno real, `dev` no debe poder desplegar en el namespace de `prod`, ni usar clústeres que no le corresponden. `AppProject` es la frontera de seguridad de Argo CD.

### Pasos

1. Creá un `AppProject` para prod con allow-lists estrictas de repos, destinos y tipos de recurso:

   ```yaml
   # argocd/project-prod.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: prod
     namespace: argocd
   spec:
     description: Producción — acceso restringido
     sourceRepos:
       - https://github.com/acme/gitops-repo.git
     destinations:
       - server: https://kubernetes.default.svc
         namespace: web-prod
     clusterResourceWhitelist:
       - group: ""
         kind: Namespace
     namespaceResourceBlacklist:
       - group: ""
         kind: ResourceQuota          # nadie toca quotas de prod vía GitOps app
     roles:
       - name: release-manager
         description: Puede sincronizar, no puede borrar
         policies:
           - p, proj:prod:release-manager, applications, sync, prod/*, allow
           - p, proj:prod:release-manager, applications, delete, prod/*, deny
   ```

2. Aplicá y asociá la `Application`/`ApplicationSet` de prod a este proyecto cambiando `spec.project: default` por `spec.project: prod`.

3. Verificá el enforcement intentando una operación prohibida:

   ```bash
   kubectl apply -f argocd/project-prod.yaml
   # Intentá que una app del proyecto prod apunte a otro namespace:
   argocd app set web-prod --dest-namespace web-dev
   ```

   Salida esperada — el proyecto rechaza el destino:

   ```
   FATA[0000] application destination {https://kubernetes.default.svc web-dev}
   is not permitted in project 'prod'
   ```

### Preguntas de comprensión

1. Diferenciá los tres muros que levanta el `AppProject`: `sourceRepos`, `destinations` y `namespaceResourceBlacklist`. Dá un ataque/error operativo que cada uno bloquea y que `default` (con `*`) no.
2. El rol `release-manager` permite `sync` pero deniega `delete`. ¿Cómo se traduce eso a "puede promover a prod pero no puede dejar prod vacío"? ¿Por qué separar estos verbos importa más en prod que en dev?
3. ¿Por qué poner `ResourceQuota` en `namespaceResourceBlacklist` de prod y no simplemente omitirla del repo? (pensá en qué controla el blacklist que la omisión no controla).

---

## Apéndice — Equivalencias en Flux (para no atarte a un solo controller)

El examen valora reconocer que GitOps es un *patrón*, no un producto. Mapa mínimo:

| Concepto | Argo CD | Flux |
|---|---|---|
| Fuente Git | `Application.spec.source` | `GitRepository` |
| Reconciliación de app | `Application` | `Kustomization` (de `kustomize.toolkit.fluxcd.io`) |
| Multi-app / fan-out | `ApplicationSet` | múltiples `Kustomization` + `dependsOn` |
| Auto-sync | `syncPolicy.automated` | `spec.prune: true` + intervalo de reconcile |
| Self-heal / drift | `selfHeal: true` | reconcile continuo (siempre corrige drift) |
| Orden de despliegue | `sync-wave` | `dependsOn` entre `Kustomization`s |
| Promoción de imagen | edición de overlay en Git | `ImageUpdateAutomation` + `ImagePolicy` |

### Pregunta de comprensión final

En Flux, un `Kustomization` reconcilia **siempre** contra Git en cada intervalo, sin un flag equivalente a `selfHeal: false`. ¿Qué implica esto respecto de la posibilidad de "hotfix manual temporal en el clúster" comparado con Argo CD? ¿En qué se parece esto a poner `selfHeal: true` en todos los entornos de Argo CD?

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Ejercicio 1

1. **El tag va en el overlay** porque cada entorno corre una versión distinta del mismo artefacto (dev = punta, prod = estable) y el `base` describe *qué es* la app, no *qué versión* corre. Poner `image: web:latest` en el `base` reintroduce el anti-patrón clásico anti-GitOps: el estado deseado deja de ser determinístico — dos `kustomize build` en momentos distintos resuelven `latest` a imágenes diferentes, el `git diff` deja de reflejar el cambio real desplegado, y el rollback por Git deja de ser confiable porque Git ya no describe la imagen exacta. GitOps exige artefactos **inmutables y pinneados por digest/tag**.
2. `commonLabels` del `base` (`part-of`) es semántico y estable. El `commonLabels: {env: dev}` del overlay inyecta labels **también en el `selector` y en `template.labels`** del `Deployment`. `Deployment.spec.selector.matchLabels` es **inmutable** una vez creado; si cambiás un `commonLabels` que alimenta el selector sobre un `Deployment` ya vivo, el `apply` es rechazado (`field is immutable`). Por eso los labels de entorno deben fijarse desde el inicio del ciclo de vida del recurso, no agregarse después. *(Nota: en Kustomize moderno se prefiere `labels:` con `includeSelectors` explícito precisamente para controlar si tocan el selector.)*
3. Nombres distintos por entorno (`web-dev`, `web-prod`) evitan **colisión de identidad** cuando un mismo Argo CD (o un mismo dashboard) observa todos los entornos: si todos se llamaran `web`, no distinguirías cuál es cuál en la vista de recursos, y un `ApplicationSet` mal armado podría apuntar dos `Application` al mismo objeto. Lo que tenés que cuidar: el `Service.spec.selector` debe seguir apuntando a los labels del pod (`app: web` + `env`), **no** al nombre con sufijo — los selectors matchean por label, no por nombre, así que `nameSuffix` no rompe el `Service` mientras el `commonLabels` mantenga el pareo.
4. Un `op: add` de JSON6902 sobre `/spec/template/spec/containers/0/readinessProbe` **falla si el path padre no existe** o si el índice `0` no está garantizado. Si `containers` estuviera vacío o el `base` cambiara el orden de containers, el patch apunta al container equivocado. Mitigación: usar un **strategic merge patch** (que matchea por `name: web` en vez de por índice), que es más robusto ante reordenamientos y ante campos ausentes.

### Ejercicio 2

1. **Con** el finalizer, al borrar la `Application` Argo CD ejecuta **cascade delete**: elimina primero los recursos hijos (`Deployment`, `Service`) y recién después la `Application`. **Sin** el finalizer, la `Application` se borra pero los recursos quedan **huérfanos** vivos en el clúster (orphaned resources). El comportamiento se llama *cascading deletion* mediante el `resources-finalizer.argocd.argoproj.io`.
2. `selfHeal` revierte el `kubectl scale` manual (drift entre live y desired). `prune` elimina el objeto cuando desaparece de Git (dejás de declararlo). Son ortogonales: `selfHeal` corrige *modificaciones* de recursos existentes; `prune` corrige *sobras* — recursos que Argo CD creó pero que ya no están en el estado deseado.
3. El overlay de Kustomize ya trae `namespace: web-dev` embebido en cada manifiesto renderizado. `destination.namespace` en Argo CD **solo aplica a recursos que no tienen namespace explícito**; como el overlay ya lo pone, prevalece el del manifiesto. `CreateNamespace=true` hace que Argo CD **cree el namespace `web-dev`** si no existe, evitando el error `namespaces "web-dev" not found` en el primer sync.
4. Crear la `Application` con `kubectl apply` a mano significa que el **objeto que orquesta GitOps no está él mismo bajo GitOps** (bootstrap manual, no reproducible, no auditable). El `Deployment` que crea sí es declarativo, pero la `Application` que lo gobierna vive fuera de Git. Se resuelve con el patrón **app-of-apps** o un `ApplicationSet` versionado en Git (Ejercicio 4), de modo que las propias `Application` también se reconcilien desde el repo.

### Ejercicio 3

1. Promover el **mismo artefacto inmutable** garantiza que lo que probaste en dev es *bit-por-bit* lo que corre en staging y prod. Si reconstruís la imagen por entorno, cambian dependencias transitivas, timestamps, o una base image que se movió — y aparecen los bugs **"funciona en dev, falla en prod"** que son imposibles de reproducir porque el binario nunca fue el mismo. GitOps = promover configuración que referencia un artefacto ya construido, no reconstruir.
2. Ganás **control de riesgo / compliance**: ningún cambio entra a prod sin aprobación humana explícita y auditable. Perdés parte de la **convergencia automática**: prod puede quedar `OutOfSync` (Git dice una cosa, el clúster otra) hasta que alguien apruebe; el "estado deseado en Git" y el "estado real" divergen a propósito durante la ventana de aprobación. Es un trade-off deliberado velocidad-vs-control, correcto para prod.
3. *Branch-per-environment*: (a) los cambios **derivan** entre branches vía merge, y los merges arrastran conflictos y cherry-picks que hacen que los entornos diverjan de formas difíciles de auditar (no sabés qué está realmente en prod sin comparar árboles); (b) es propenso a **drift de configuración estructural** — un fix aplicado a `prod` branch que nunca vuelve a `dev` branch. El modelo *directory-per-environment* en un solo `main` hace la diferencia entre entornos **explícita y diffeable en un solo lugar**, y la promoción es un commit atómico revisable.
4. `Sync Status: Synced` (Git convergió: el `Deployment` declara la imagen `0.2.0` correctamente y el objeto se aplicó) pero `Health Status: Degraded/Progressing` (los pods entran en `ImagePullBackOff` porque la imagen no existe en el registry). Esto ilustra el límite: **Argo CD garantiza que el clúster coincide con Git (sync), no que la aplicación funcione (health)**. Son dos señales distintas y ambas hay que mirarlas.

### Ejercicio 4

1. El `ApplicationSet` **posee** (owns, vía owner-reference) todas las `Application` generadas. Es un controller que reconcilia el conjunto de `Application` contra la salida del generator. Si borrás la carpeta `overlays/qa`, en el próximo poll el generator ya no emite ese elemento, y el `ApplicationSet` **borra la `Application` `web-qa`** (y, por cascade, sus recursos). El ciclo de vida de las apps es totalmente derivado del generator.
2. `--cascade=false` borra la `Application` manual **sin tocar sus recursos vivos** (`Deployment`/`Service` quedan corriendo). Así, cuando el `ApplicationSet` re-crea `web-dev` y hace `adopt` de esos recursos existentes, no hay ventana en la que los pods se destruyan y recreen. Sin `--cascade=false`, borrar las apps manuales tiraría abajo los `Deployment`s → **outage** durante la migración.
3. Elegís **list generator** (o matrix/cluster generator) porque necesitás setear `destination.server` explícitamente por entorno y ese dato **no existe en la estructura de directorios** — el Git directory generator solo conoce paths, no clústeres. El directory generator descubre *qué* desplegar; el list/cluster generator te da el *dónde* (qué clúster/servidor) como parámetro. Para "cada entorno en su clúster" se combinan (matrix generator) o se usa list con `cluster` explícito.
4. `missingkey=error` hace que una variable inexistente **aborte el render** en vez de producir un string vacío. En prod, un template que silenciosamente resuelve `namespace: 'web-'` (basename vacío) desplegaría al namespace equivocado o a uno inválido. Fallar ruidosamente convierte un bug de templating en un error de generación visible, no en un deploy silencioso a un destino incorrecto.

### Ejercicio 5

1. Un `PreSync` hook corre **antes** de aplicar cualquier recurso de la sync y su ciclo de vida es efímero (Argo lo maneja aparte del árbol de recursos). `hook-delete-policy: HookSucceeded` **borra el `Job` tras completarse con éxito**, de modo que la próxima sync crea un `Job` fresco. Un `Job` normal en wave 1 es un objeto con nombre fijo; re-aplicarlo cuando ya existió da conflicto (`Job` es prácticamente inmutable en su `spec.template`) o reejecuta la migración de forma no controlada. El `HookSucceeded` da la semántica "corré la migración una vez por sync, limpiala después".
2. Con `selfHeal: true`, Argo CD ve el `replicas` que el HPA subió (p.ej. a 9) como **drift** respecto de Git (4) y lo revierte, peleándose con el HPA en un loop. Se resuelve con `ignoreDifferences` sobre `/spec/replicas` del `Deployment` (o quitando `replicas` del manifiesto y dejándolo al HPA), para que Argo CD **ignore ese campo** en la comparación y no lo trate como drift.
3. `argocd app rollback` cambia el estado **vivo** del clúster a una revisión previa, pero **no toca Git**. Con auto-sync activo, Argo CD detecta inmediatamente que el clúster difiere de Git (que sigue apuntando a la versión mala) y **vuelve a sincronizar hacia adelante**, deshaciendo el rollback en segundos. El único rollback que respeta el invariante GitOps es cambiar Git (`git revert`) y sincronizar desde ahí.
4. **No.** Si el `PreSync` hook falla, la operación de sync se **aborta**: el `Deployment` de wave 2 **no se aplica**. La `Application` queda `OutOfSync` con la operación en estado `Failed`. Es exactamente lo deseado para una migración de esquema: si la migración de DB falla, **no querés** desplegar la nueva versión de la app que asume ese esquema — evitás correr código nuevo contra un esquema viejo.

### Ejercicio 6

1. `sourceRepos` bloquea que una `Application` del proyecto prod se alimente de un repo no confiable (evita que un repo comprometido inyecte manifiestos a prod). `destinations` bloquea que prod despliegue a un namespace/clúster que no le corresponde (evita el blast radius de un typo que manda a prod a `kube-system` o a otro clúster). `namespaceResourceBlacklist` bloquea *tipos de recurso* específicos aun dentro del namespace permitido (evita que una app toque `ResourceQuota` y se auto-otorgue capacidad). `default` con `*` en todo no bloquea ninguno de los tres.
2. `sync` permite converger prod hacia el estado deseado (promover un release). `delete` denegado impide que ese rol borre la `Application` y, por cascade, **deje prod sin recursos** (outage total). Separar los verbos implementa *least privilege*: el release manager hace su trabajo (promover) sin tener el poder de causar un incidente destructivo. En prod el costo de un `delete` accidental o malicioso es catastrófico; en dev es recuperable, por eso ahí la separación importa menos.
3. Omitir la `ResourceQuota` del repo solo significa "GitOps no la gestiona" — pero **cualquiera con acceso podría crear/editar una vía otra `Application` o a mano**. Ponerla en `namespaceResourceBlacklist` **prohíbe activamente** que *cualquier* `Application` del proyecto prod cree o modifique ese tipo de recurso, aunque el manifiesto apareciera en Git. El blacklist es un control de autorización (qué se permite tocar); la omisión es solo ausencia de declaración.

### Apéndice Flux

Flux reconcilia **siempre** contra Git en cada intervalo, así que un "hotfix manual" en el clúster (un `kubectl edit`) **se revierte automáticamente** en el próximo reconcile — no hay forma nativa de "pausar el self-heal" salवo suspender el `Kustomization` (`flux suspend`). Es equivalente a correr Argo CD con `selfHeal: true` en todos los entornos: el clúster es *derivado puro* de Git y toda intervención manual es transitoria. Implicación práctica: en ambos modelos, el "hotfix" correcto no es tocar el clúster sino commitear a Git (o suspender explícitamente la reconciliación mientras dura la intervención de emergencia, y documentarlo).

</details>

---

### Fuentes

- CNCF — *CNPA Curriculum* (dominio *GitOps for Multi-Environment Application Management*): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenGitOps — *GitOps Principles v1.0.0*: https://opengitops.dev/
- Argo CD — *Declarative Setup / Application*: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Argo CD — *ApplicationSet & Generators*: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD — *Sync Phases and Waves / Resource Hooks*: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/ y https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Argo CD — *Projects (AppProject) & RBAC*: https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Kustomize — *Reference / kustomization.yaml*: https://kubectl.docs.kubernetes.io/references/kustomize/
- Flux — *Ways of structuring your repositories*: https://fluxcd.io/flux/guides/repository-structure/