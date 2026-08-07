# Ejercicios Guiados — Tema 3.6: GitOps Basics, Controllers, and Workflows

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión 2025-04-01
> **Peso en el examen:** 2.25
> **Prerrequisitos de laboratorio:** un cluster Kubernetes funcional (`kind`, `minikube` o k3d sirve), `kubectl >= 1.28`, `git`, y acceso a Internet para clonar los repos de ejemplo. Los ejercicios de Argo CD y Flux instalan CRDs y controllers reales, así que usá un cluster desechable.

Los cuatro **principios de OpenGitOps** (proyecto CNCF Sandbox) atraviesan todos los ejercicios y conviene tenerlos presentes desde el principio:

1. **Declarativo** — el estado deseado del sistema se expresa de forma declarativa.
2. **Versionado e inmutable** — el estado deseado se almacena versionado e inmutable (Git como *source of truth*).
3. **Extraído automáticamente (pulled)** — agentes de software extraen el estado deseado desde la fuente.
4. **Reconciliado continuamente** — agentes observan el estado real y **reconcilian** contra el deseado.

Fuentes oficiales: <https://opengitops.dev/> · <https://github.com/open-gitops/documents> · <https://argo-cd.readthedocs.io/> · <https://fluxcd.io/flux/> · Curriculum: <https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf>

---

## Ejercicio 1 — Instalar un GitOps controller (Argo CD) y observar el reconciliation loop

**Objetivo:** desplegar el controller pull-based, registrar una `Application` declarativa que apunta a un repo Git y ver cómo el estado se materializa sin ningún `kubectl apply` de la app.

1. Creá el namespace del controller e instalá Argo CD desde su manifiesto oficial `stable`:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Esperá a que el controller principal y el repo-server estén listos. El **`application-controller`** es el componente que ejecuta el reconciliation loop:

   ```bash
   kubectl -n argocd rollout status statefulset/argocd-application-controller
   kubectl -n argocd get pods
   ```

   Salida esperada (abreviada):

   ```
   NAME                                                READY   STATUS    RESTARTS   AGE
   argocd-application-controller-0                     1/1     Running   0          92s
   argocd-repo-server-6b7f8c9d4b-l9k2p                 1/1     Running   0          92s
   argocd-server-7c9f5b6d88-4mn7t                      1/1     Running   0          92s
   argocd-redis-6c8f5b7d9c-x2q8r                       1/1     Running   0          92s
   argocd-applicationset-controller-59d7...            1/1     Running   0          92s
   ```

3. Registrá una `Application` **de forma declarativa** (esto es GitOps: incluso la definición de la app es un manifiesto). Guardalo como `guestbook-app.yaml`:

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
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   kubectl apply -f guestbook-app.yaml
   ```

4. Observá el estado de sincronización. Fijate que arranca en `OutOfSync` porque todavía **no** definimos sync automático:

   ```bash
   kubectl -n argocd get application guestbook \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```

   Salida esperada:

   ```
   NAME        SYNC        HEALTH
   guestbook   OutOfSync   Missing
   ```

5. Disparar la sincronización manual con el CLI. Primero exponé el server y logueate:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
   PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
            -o jsonpath="{.data.password}" | base64 -d)
   argocd login localhost:8080 --username admin --password "$PASS" --insecure
   argocd app sync guestbook
   ```

   Salida esperada (final):

   ```
   Operation:          Sync
   Sync Revision:      53e28ff20cc530b9ada2173fbbde64d341c1a1d7
   Phase:              Succeeded
   Message:            successfully synced (all tasks run)

   GROUP  KIND        NAMESPACE  NAME          STATUS  HEALTH   HOOK  MESSAGE
          Service     guestbook  guestbook-ui  Synced  Healthy        service/guestbook-ui created
   apps   Deployment  guestbook  guestbook-ui  Synced  Healthy        deployment.apps/guestbook-ui created
   ```

> **Preguntas de comprensión**
>
> - **Q1.** ¿Por qué la `Application` comienza en `OutOfSync` / `Missing` aunque el manifiesto ya esté aplicado en el cluster?
> - **Q2.** ¿Qué componente de Argo CD ejecuta el reconciliation loop y cuál solo renderiza/clona el repositorio? ¿Por qué esa separación importa para el aislamiento de credenciales?
> - **Q3.** El estudiante nunca corrió `kubectl apply` sobre el `Deployment` de guestbook. ¿Cuál de los cuatro principios de OpenGitOps explica que la app igual se haya creado?

---

## Ejercicio 2 — Reconciliación continua: drift detection, self-heal y prune

**Objetivo:** activar `automated` sync y provocar *drift* manual para ver al controller revertir cambios imperativos. Esta es la diferencia práctica entre "CI/CD push" y "GitOps pull + reconciliación continua".

1. Convertí la app a sincronización automática con auto-heal y pruning. Podés parchear el recurso vivo (declarativo, igual queda versionable):

   ```bash
   kubectl -n argocd patch application guestbook --type merge -p '{
     "spec": { "syncPolicy": { "automated": { "prune": true, "selfHeal": true } } }
   }'
   ```

2. Provocá **drift** editando el estado real del cluster por fuera de Git (una acción imperativa "prohibida" en GitOps):

   ```bash
   kubectl -n guestbook scale deployment guestbook-ui --replicas=5
   kubectl -n guestbook get deployment guestbook-ui -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Salida inmediata: `5`

3. Esperá un ciclo de reconciliación (por defecto Argo CD reconcilia cada ~180 s, pero `selfHeal` reacciona a los eventos de watch mucho antes) y volvé a mirar:

   ```bash
   kubectl -n guestbook get deployment guestbook-ui -o jsonpath='{.spec.replicas}{"\n"}'
   argocd app get guestbook --refresh -o wide
   ```

   Salida esperada tras el self-heal:

   ```
   1
   ```

   ```
   Name:               argocd/guestbook
   Sync Status:        Synced to HEAD (53e28ff)
   Health Status:      Healthy
   ...
   CONDITIONS:         <none>
   ```

4. Ahora probá **prune**: agregá un recurso huérfano que Git no conoce y observá que el controller lo detecta como fuera de estado, pero **no** lo borra salvo que esté marcado para pruning y provenga de una fuente rastreada:

   ```bash
   kubectl -n guestbook create configmap rogue --from-literal=foo=bar
   argocd app get guestbook | grep -i rogue || echo "ConfigMap 'rogue' no es tracked: Argo no lo gestiona"
   ```

   Salida esperada:

   ```
   ConfigMap 'rogue' no es tracked: Argo no lo gestiona
   ```

5. Inspeccioná el historial de sincronizaciones (auditoría de despliegues, uno de los beneficios de GitOps):

   ```bash
   argocd app history guestbook
   ```

   Salida esperada:

   ```
   ID  DATE                           REVISION
   0   2025-04-01 14:22:03 -0300 -03  53e28ff20cc530b9ada2173fbbde64d341c1a1d7
   ```

> **Preguntas de comprensión**
>
> - **Q4.** Con `selfHeal: true`, el `replicas=5` volvió a `1`. ¿De dónde tomó Argo CD el "1"? ¿El controller preguntó al operador o consultó otra fuente?
> - **Q5.** El `ConfigMap rogue` sobrevivió aunque `prune: true` está activo. ¿Qué distingue a un recurso *pruneable* de uno que Argo CD simplemente ignora? (pista: labels/annotations de tracking).
> - **Q6.** Explicá con tus palabras por qué la reconciliación continua convierte al drift en un evento **transitorio** y no en un estado permanente. ¿Qué implica esto para el "configuration drift" clásico de la infraestructura pre-GitOps?

---

## Ejercicio 3 — El mismo patrón con Flux: `GitRepository` + `Kustomization`

**Objetivo:** ver que "GitOps controller" no es sinónimo de "Argo CD". Flux descompone la reconciliación en CRDs separados (una *source* y un *reconciler*), lo que hace explícita la arquitectura de dos etapas: **fetch** y **apply**.

1. Instalá el CLI de Flux y verificá que el cluster cumple los prerrequisitos:

   ```bash
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux check --pre
   ```

   Salida esperada:

   ```
   ► checking prerequisites
   ✔ Kubernetes 1.29.2 >=1.28.0-0
   ✔ prerequisites checks passed
   ```

2. Instalá los controllers de Flux en el cluster (sin bootstrap a un repo real, solo los componentes):

   ```bash
   flux install
   kubectl -n flux-system get pods
   ```

   Salida esperada (abreviada):

   ```
   NAME                                       READY   STATUS    RESTARTS   AGE
   helm-controller-6b8f...                    1/1     Running   0          40s
   kustomize-controller-7d9c...               1/1     Running   0          40s
   notification-controller-5f7b...            1/1     Running   0          40s
   source-controller-8c6d...                  1/1     Running   0          40s
   ```

3. Declará la **source** (principio 3: *pulled automatically*). El `source-controller` va a clonar y verificar el repo cada intervalo:

   ```bash
   flux create source git podinfo \
     --url=https://github.com/stefanprodan/podinfo \
     --branch=master \
     --interval=1m \
     --export > podinfo-source.yaml
   cat podinfo-source.yaml
   ```

   Contenido generado:

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 1m0s
     ref:
       branch: master
     url: https://github.com/stefanprodan/podinfo
   ```

4. Declará la **`Kustomization`** (principio 4: *reconciled continuously*). Este CRD es el reconciler que aplica el path renderizado del source:

   ```bash
   kubectl apply -f podinfo-source.yaml
   flux create kustomization podinfo \
     --source=GitRepository/podinfo \
     --path="./kustomize" \
     --prune=true \
     --interval=5m \
     --target-namespace=default \
     --export | kubectl apply -f -
   ```

5. Verificá la reconciliación y forzá una manual:

   ```bash
   flux get kustomizations
   flux reconcile kustomization podinfo --with-source
   kubectl -n default get deploy podinfo
   ```

   Salida esperada:

   ```
   NAME     REVISION           SUSPENDED   READY   MESSAGE
   podinfo  master@sha1:9d918a  False       True    Applied revision: master@sha1:9d918a

   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo   2/2     2            2           35s
   ```

> **Preguntas de comprensión**
>
> - **Q7.** Flux separa `GitRepository` de `Kustomization`; Argo CD junta ambos conceptos en un solo `Application`. Nombrá una ventaja operativa concreta de tener el *fetch* y el *apply* como recursos independientes.
> - **Q8.** Ambos controllers implementan el mismo modelo pull. ¿Qué significa "pull-based" respecto a dónde viven las credenciales del cluster, comparado con un pipeline de CI que hace `kubectl apply` (push-based)?
> - **Q9.** El campo `interval: 1m` del `GitRepository` y el `interval: 5m` de la `Kustomization` controlan cosas distintas. ¿Qué reconcilia cada intervalo?

---

## Ejercicio 4 — Workflow GitOps completo: promoción por Pull Request y overlays de entorno

**Objetivo:** modelar el flujo de trabajo real de un equipo de plataforma. El cambio no se hace con `kubectl`; se hace con un **commit + PR**, y el merge es el disparador del despliegue. Practicamos también la promoción `staging → production` con Kustomize overlays.

1. Estructurá un repo de configuración con la disposición canónica *base + overlays*:

   ```bash
   mkdir -p fleet-infra/apps/podinfo/{base,overlays/staging,overlays/production}
   cd fleet-infra
   ```

   `apps/podinfo/base/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - https://github.com/stefanprodan/podinfo/kustomize?ref=6.7.0
   images:
     - name: ghcr.io/stefanprodan/podinfo
       newTag: 6.7.0
   ```

   `apps/podinfo/overlays/staging/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: staging
   resources:
     - ../../base
   replicas:
     - name: podinfo
       count: 1
   ```

   `apps/podinfo/overlays/production/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: production
   resources:
     - ../../base
   replicas:
     - name: podinfo
       count: 4
   ```

2. Validá localmente que cada overlay renderiza (esto es el equivalente GitOps del "compila antes de mergear"):

   ```bash
   kubectl kustomize apps/podinfo/overlays/staging | grep -E 'kind: Deployment|replicas:'
   kubectl kustomize apps/podinfo/overlays/production | grep -E 'kind: Deployment|replicas:'
   ```

   Salida esperada:

   ```
   kind: Deployment
     replicas: 1
   kind: Deployment
     replicas: 4
   ```

3. Versioná e inicializá (principio 2: *versioned and immutable*):

   ```bash
   git init -q && git add . && git commit -q -m "chore: podinfo base + staging/production overlays"
   ```

4. Simulá una **promoción de versión** vía PR. En una rama, subís la imagen de `6.7.0` a `6.7.1` **solo en el base** y dejás que ambos entornos hereden el cambio de forma controlada:

   ```bash
   git switch -c promote/podinfo-6.7.1
   sed -i 's/newTag: 6.7.0/newTag: 6.7.1/' apps/podinfo/base/kustomization.yaml
   git commit -qam "feat(podinfo): promote image to 6.7.1"
   git --no-pager diff main -- apps/podinfo/base/kustomization.yaml
   ```

   Salida esperada:

   ```diff
   -      newTag: 6.7.0
   +      newTag: 6.7.1
   ```

5. Registrá **dos** `Application`/`Kustomization` (una por overlay) apuntando al mismo repo pero a paths distintos. Con Argo CD, `production` con sync **manual** y `staging` con sync **automático** modela un *gate* de aprobación:

   ```yaml
   # applications.yaml (Argo CD)
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata: { name: podinfo-staging, namespace: argocd }
   spec:
     project: default
     source:
       repoURL: https://github.com/<org>/fleet-infra.git
       targetRevision: main
       path: apps/podinfo/overlays/staging
     destination: { server: https://kubernetes.default.svc, namespace: staging }
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [ CreateNamespace=true ]
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata: { name: podinfo-production, namespace: argocd }
   spec:
     project: default
     source:
       repoURL: https://github.com/<org>/fleet-infra.git
       targetRevision: main
       path: apps/podinfo/overlays/production
     destination: { server: https://kubernetes.default.svc, namespace: production }
     syncPolicy:
       syncOptions: [ CreateNamespace=true ]   # sin automated -> sync manual = gate
   ```

   El flujo humano queda: **merge del PR a `main` → `staging` se auto-sincroniza → validación → `argocd app sync podinfo-production` (o merge de un PR de promoción) → producción**.

> **Preguntas de comprensión**
>
> - **Q10.** En este workflow, ¿cuál es el **evento** que dispara un despliegue? ¿Qué reemplaza al clásico `kubectl set image` ejecutado por un humano o por un job de CI?
> - **Q11.** `staging` tiene `automated` y `production` no. ¿Qué patrón de gobernanza (approval gate) modela esa asimetría, y por qué es más auditable que un botón de "deploy" en una UI de CI?
> - **Q12.** Un incidente en producción exige rollback inmediato. En GitOps, ¿cuál es la operación de rollback y por qué es intrínsecamente reproducible? Nombrá dos formas de hacerlo (una con Git, una con el controller).
> - **Q13.** ¿Por qué cambiar `newTag` en el `base` y no directamente en cada overlay reduce el riesgo de drift entre entornos? ¿Qué principio DRY de configuración estás aplicando?

---

## Ejercicio 5 — Diagnóstico avanzado de fallos de sincronización

**Objetivo:** los `Sync failed`, health checks degradados y sync waves/hooks son el pan de cada día de un platform engineer. Practicamos leer el estado del controller y aislar la causa raíz.

1. Provocá un fallo de sync **determinístico**: apuntá una app a un path que contiene un manifiesto inválido (namespace inexistente sin `CreateNamespace`):

   ```yaml
   # broken-app.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata: { name: broken, namespace: argocd }
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination: { server: https://kubernetes.default.svc, namespace: no-existe }
     syncPolicy:
       automated: {}
   ```

   ```bash
   kubectl apply -f broken-app.yaml
   ```

2. Leé la condición de error directamente del status del recurso (fuente de verdad del controller, no de la UI):

   ```bash
   kubectl -n argocd get application broken \
     -o jsonpath='{.status.conditions[*].message}{"\n"}'
   argocd app get broken
   ```

   Salida esperada (extracto):

   ```
   Operation:     Sync
   Phase:         Failed
   Message:       one or more objects failed to apply, reason: namespaces "no-existe" not found
   Sync Status:   OutOfSync
   Health Status: Missing
   ```

3. Distinguí **Sync status** de **Health status** — son ejes ortogonales. Forzá un health degradado sin fallo de sync: escalá una imagen a un tag inexistente en una app ya sincronizada y observá `Progressing → Degraded`:

   ```bash
   argocd app get guestbook -o json \
     | jq -r '.status | "sync=\(.sync.status) health=\(.health.status)"'
   ```

   Salida esperada tras un tag roto:

   ```
   sync=Synced health=Degraded
   ```

4. Inspeccioná los logs del `application-controller` para ver el reconciliation loop en acción (nivel de detalle que la UI no muestra):

   ```bash
   kubectl -n argocd logs statefulset/argocd-application-controller \
     | grep -i "broken" | tail -n 5
   ```

   Salida esperada (extracto):

   ```
   level=info msg="Comparing app state" application=argocd/broken
   level=warning msg="Failed to sync" application=argocd/broken error="namespaces \"no-existe\" not found"
   ```

5. Corregí de forma declarativa (añadiendo `CreateNamespace=true`), reconciliá y confirmá:

   ```bash
   kubectl -n argocd patch application broken --type merge -p '{
     "spec": { "syncPolicy": { "syncOptions": ["CreateNamespace=true"] } }
   }'
   argocd app sync broken
   argocd app get broken -o json | jq -r '.status | "sync=\(.sync.status) health=\(.health.status)"'
   ```

   Salida esperada:

   ```
   sync=Synced health=Healthy
   ```

> **Preguntas de comprensión**
>
> - **Q14.** `Sync Status` y `Health Status` pueden combinarse en cuatro cuadrantes. Dá un ejemplo real de `Synced + Degraded` y otro de `OutOfSync + Healthy`, y explicá por qué son estados distintos.
> - **Q15.** El mensaje de error vivía en `.status.conditions`. ¿Por qué en GitOps es preferible diagnosticar leyendo el **status del CRD** antes que revisar logs de un pipeline de CI?
> - **Q16.** La corrección se hizo cambiando el manifiesto, no ejecutando `kubectl create namespace no-existe`. ¿Qué habría pasado si "arreglabas" el problema creando el namespace a mano? Relacionalo con el drift del Ejercicio 2.

---

## Respuestas

<details>
<summary>Mostrar respuestas y explicaciones</summary>

**Q1.** Aplicar el manifiesto `Application` solo registra la *intención* ante Argo CD; el recurso `Application` es metadata para el controller, no la app en sí. El controller compara el estado deseado (lo que dice el repo Git en `path: guestbook`) contra el estado real del cluster (donde todavía no existe nada), por eso reporta `OutOfSync` / `Missing`. Sin `syncPolicy.automated`, la materialización requiere un `sync` explícito. Es la separación entre *declarar la fuente de verdad* y *reconciliar hacia ella*.

**Q2.** El **`argocd-application-controller`** (un StatefulSet) ejecuta el reconciliation loop: compara, detecta drift y aplica. El **`argocd-repo-server`** clona el repo y renderiza los manifiestos (Helm/Kustomize/plain YAML) en memoria, sin credenciales de cluster. La separación importa porque el repo-server maneja secretos de acceso a Git pero **no** tiene permisos sobre el cluster, y el controller tiene permisos sobre el cluster pero no ejecuta plantillas arbitrarias de repos; reduce la superficie de ataque (defense in depth).

**Q3.** El principio **4 — reconciliado continuamente** (junto con el **3 — pulled automatically**): el agente extrae el estado deseado del repo y reconcilia el cluster hacia él. El operador nunca hace push; el controller *pull*ea y aplica. El `Deployment` se creó como efecto de la reconciliación disparada por el `sync`.

**Q4.** Del **repositorio Git**, no de ninguna interacción humana. El repo declara `replicas: 1` (o el default del manifiesto). `selfHeal` detecta que el estado real (`5`) difiere del deseado (`1`) y reaplica el deseado. Git es el *single source of truth*: el cluster converge hacia Git, nunca al revés.

**Q5.** Argo CD solo gestiona (y por tanto puede *prunear*) recursos que él mismo creó y que llevan sus **tracking labels/annotations** (`app.kubernetes.io/instance` o la annotation `argocd.argoproj.io/tracking-id`, según el `trackingMethod` configurado) y que están dentro del `path`/destination de una `Application`. El `ConfigMap rogue` se creó imperativamente, sin esos metadatos y sin origen en Git, así que Argo lo considera ajeno y lo ignora. `prune` solo borra recursos *tracked* que desaparecieron del source, no cualquier objeto del namespace.

**Q6.** Porque el loop corre continuamente (por watch-events + un resync periódico, ~180 s por defecto en Argo CD). Cualquier cambio imperativo dura, como mucho, hasta el próximo ciclo de reconciliación, tras lo cual el sistema vuelve al estado de Git. En la infra pre-GitOps, el drift se **acumulaba** silenciosamente (servidores "mascota" que divergían de su plantilla) hasta volverse irreproducible; con reconciliación continua el drift es un transitorio auto-corregido y el estado documentado en Git siempre coincide con producción.

**Q7.** Ventajas de separar `GitRepository` (fetch) de `Kustomization` (apply): (a) **reuso** — múltiples `Kustomization` pueden consumir un mismo `GitRepository` con distintos paths/intervalos sin re-clonar; (b) **diagnóstico granular** — un fallo de red al clonar aparece en el status del `GitRepository`, y un error de `apply` en el de la `Kustomization`, aislando la causa; (c) **verificación de origen** independiente (firmas, checksums) en la source, desacoplada de la política de despliegue. Cualquiera de estas es válida.

**Q8.** "Pull-based" significa que el agente vive **dentro** del cluster y él extrae los cambios; las credenciales del cluster **nunca salen** de él. En un CI push-based, el runner externo necesita un `kubeconfig` con permisos amplios exportado fuera del perímetro del cluster (en un secret de CI), que es un vector de fuga y un objetivo de robo de credenciales. GitOps invierte el flujo: el cluster se sincroniza solo, y el sistema externo (Git) solo necesita permiso de *lectura*.

**Q9.** El `interval` del `GitRepository` (1m) controla cada cuánto el `source-controller` **re-clona y verifica el repo** para detectar nuevos commits (produce un nuevo *artifact*/revision). El `interval` de la `Kustomization` (5m) controla cada cuánto el `kustomize-controller` **re-renderiza y re-aplica** el artifact actual al cluster (reconciliación del estado del cluster, incluye self-heal del drift). Uno vigila Git; el otro vigila el cluster.

**Q10.** El evento disparador es el **merge de un commit a la rama observada** (p. ej. `main`). El controller detecta el nuevo `targetRevision` y reconcilia. Reemplaza al `kubectl set image` / `kubectl apply` imperativo: el humano o CI ya no toca el cluster, solo modifica Git. El *deploy* se vuelve un efecto secundario auditable de un cambio de código de configuración.

**Q11.** Modela un **approval gate por entorno**: staging se despliega solo (feedback rápido), producción requiere una acción explícita (un `argocd app sync` o el merge de un PR de promoción con revisión obligatoria). Es más auditable que un botón de UI porque la aprobación queda como un artefacto versionado —el PR de promoción con su autor, revisores y timestamp en el historial de Git— en lugar de un click efímero sin traza reproducible.

**Q12.** El rollback es **revertir el estado deseado en Git a una revisión previa conocida-buena**; como Git es inmutable y versionado, esa revisión es un artefacto exacto y reproducible (no "recordás" cómo estaba, lo tenés commiteado). Dos formas: (1) **Git** — `git revert <commit>` y merge, dejando traza del rollback; el controller reconcilia al estado anterior. (2) **Controller** — `argocd app rollback <app> <history-id>` (o apuntar `targetRevision` a un tag/commit anterior), que resincroniza a un despliegue histórico. La opción Git es preferible porque mantiene Git como fuente de verdad; el rollback del controller es una intervención rápida que luego conviene reflejar en Git para no crear drift.

**Q13.** Cambiar `newTag` una sola vez en el `base` hace que **ambos** overlays hereden exactamente la misma imagen, eliminando la posibilidad de que staging y production corran versiones distintas por un edit olvidado. Estás aplicando **DRY** (Don't Repeat Yourself) a la configuración: una única definición canónica del valor compartido, con los overlays expresando *solo las diferencias* (réplicas, namespace). Duplicar el tag en cada overlay reintroduce el riesgo de divergencia manual.

**Q14.** Son ejes ortogonales. **`Synced + Degraded`**: el cluster coincide exactamente con Git (sync OK) pero la app no está sana —p. ej. el manifiesto referencia un tag de imagen inexistente, así que el `Deployment` está `Synced` pero sus pods entran en `ImagePullBackOff` y el health es `Degraded`. **`OutOfSync + Healthy`**: la app corriendo funciona perfectamente (health OK) pero alguien commiteó un cambio a Git que el cluster todavía no aplicó (sync manual pendiente), o hubo un cambio imperativo aún no reconciliado. Sync mide *coincidencia con Git*; Health mide *salud operativa del workload*.

**Q15.** Porque en GitOps el **status del CRD es la fuente autoritativa del reconciliation loop**: refleja el resultado real de la comparación deseado-vs-real y persiste (no se pierde cuando termina un job). Los logs de un pipeline de CI son efímeros, describen el intento de push desde afuera y no saben nada de la reconciliación continua posterior. `.status.conditions` / `argocd app get` te dice *por qué el cluster no converge ahora mismo*, que es exactamente la pregunta de diagnóstico.

**Q16.** Si creabas el namespace a mano, la app sincronizaría, pero habrías introducido **drift permanente**: existe un recurso (`namespace/no-existe`) que no está declarado en Git. En el próximo cluster recreado desde Git ese namespace no existiría y el fallo volvería —el arreglo no es reproducible. La corrección GitOps correcta es declarar la creación del namespace (`CreateNamespace=true` o un manifiesto `Namespace` en el repo), de modo que la solución quede versionada y el estado de Git siga siendo una descripción completa y reproducible del sistema. Es el mismo aprendizaje del Ejercicio 2: el estado real converge a Git, así que todo lo necesario debe vivir en Git.

</details>