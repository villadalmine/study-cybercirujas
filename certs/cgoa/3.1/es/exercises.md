# CGOA — Dominio 3.1: Herramientas e Implementación de GitOps
## Ejercicios Guiados (25% del examen)

> **Alcance.** Estos ejercicios ejercitan la mitad de *implementación* de GitOps: los reconciliadores (Flux CD, Argo CD), los renderizadores de manifiestos que estos manejan (Kustomize, Helm), las superficies de cadena de suministro que los rodean (artefactos OCI, automatización de imágenes, secretos cifrados) y la entrega progresiva. Cada paso está pensado para ser tipeado en un clúster real. Se muestran las salidas esperadas para que puedas comparar tu realidad contra la referencia.
>
> **Cómo trabajar esto.** Hacé los bloques en orden — los ejercicios posteriores dependen del estado anterior. Después de cada bloque hay preguntas de comprensión; respondelas *antes* de leer la sección plegable de respuestas al final. Las preguntas apuntan al razonamiento que evalúa el examen, no a la memorización de comandos.

---

## Ejercicio 0 — Entorno de laboratorio

**Objetivo:** un clúster descartable, un remoto Git y las CLI de ambos reconciliadores.

### Pasos

1. Creá un clúster local. Sirve cualquier Kubernetes conforme ≥ 1.30; acá se usa `kind` porque las imágenes de nodo están fijadas y son reproducibles.

   ```bash
   kind create cluster --name gitops --image kindest/node:v1.33.1
   ```

   ```
   Creating cluster "gitops" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
   Set kubectl context to "kind-gitops"
   ```

2. Verificá el contexto y la superficie de API sobre la que vas a reconciliar.

   ```bash
   kubectl config current-context
   kubectl get nodes -o wide
   ```

   ```
   kind-gitops
   NAME                   STATUS   ROLES           AGE   VERSION
   gitops-control-plane   Ready    control-plane   62s   v1.33.1
   ```

3. Instalá la CLI de Flux y verificá que el clúster es un destino válido *antes* de instalar nada.

   ```bash
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux --version
   flux check --pre
   ```

   ```
   flux version 2.6.4
   ► checking prerequisites
   ✔ Kubernetes 1.33.1 >=1.30.0-0
   ✔ prerequisites checks passed
   ```

4. Instalá la CLI de Argo CD (la vas a usar del Ejercicio 4 en adelante).

   ```bash
   curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
   argocd version --client --short
   ```

   ```
   argocd: v3.1.0+e8c5f2a
   ```

5. Creá un repositorio Git vacío llamado `gitops-cgoa` en tu proveedor Git y exportá las credenciales. Se requiere un PAT clásico con alcance `repo` (o un token de grano fino con *Contents: read & write* y *Administration: read & write*), porque el bootstrap crea una deploy key.

   ```bash
   export GITHUB_USER="<your-user>"
   export GITHUB_TOKEN="<your-pat>"
   ```

### Control de comprensión — Bloque 0

- **Q0.1** `flux check --pre` pasó, pero no inspeccionó *nada* acerca de tu repositorio Git. ¿De qué clase de fallo, entonces, no te protege, y qué comando cubre esa brecha después del bootstrap?
- **Q0.2** Vas a correr dos reconciliadores en un mismo clúster. Nombrá el modo de fallo concreto si ambos están configurados para gestionar el mismo `Deployment`, y describí qué observarías en el objeto.
- **Q0.3** ¿Por qué fijar `kindest/node:v1.33.1` (en vez de `:latest`) es en sí mismo una elección consistente con GitOps, aunque el clúster sea descartable?

---

## Ejercicio 1 — Bootstrap de Flux: el reconciliador gestiona su propia instalación

**Objetivo:** entender que `flux bootstrap` no es "un instalador" — es el acto de convertir a los controladores en una carga de trabajo reconciliada descrita en Git.

### Pasos

1. Hacé el bootstrap de Flux, solicitando los dos controladores opcionales de automatización de imágenes que vas a necesitar en el Ejercicio 8.

   ```bash
   flux bootstrap github \
     --owner="${GITHUB_USER}" \
     --repository=gitops-cgoa \
     --branch=main \
     --path=clusters/dev \
     --personal \
     --components-extra=image-reflector-controller,image-automation-controller
   ```

   ```
   ► connecting to github.com
   ► cloning branch "main" from Git repository "https://github.com/<user>/gitops-cgoa.git"
   ✔ cloned repository
   ► generating component manifests
   ✔ generated component manifests
   ✔ committed component manifests to "main" ("6b1f0c9")
   ► pushing component manifests to "https://github.com/<user>/gitops-cgoa.git"
   ► installing components in "flux-system" namespace
   ✔ installed components
   ✔ reconcilers are healthy!
   ► determining if source secret "flux-system/flux-system" exists
   ► generating source secret
   ✔ configured deploy key "flux-system-main-flux-system-./clusters/dev"
   ► applying source secret "flux-system/flux-system"
   ✔ reconciled source secret
   ► generating sync manifests
   ✔ committed sync manifests to "main" ("a3d47e1")
   ► pushing sync manifests to "https://github.com/<user>/gitops-cgoa.git"
   ► applying sync manifests
   ✔ reconciled sync configuration
   ► waiting for Kustomization "flux-system/flux-system" to be reconciled
   ✔ Kustomization reconciled successfully
   ► confirming components are healthy
   ✔ all components are healthy
   ```

2. Inspeccioná lo que el bootstrap escribió en Git.

   ```bash
   git clone https://github.com/${GITHUB_USER}/gitops-cgoa.git
   cd gitops-cgoa
   find clusters/dev -type f | sort
   ```

   ```
   clusters/dev/flux-system/gotk-components.yaml
   clusters/dev/flux-system/gotk-sync.yaml
   clusters/dev/flux-system/kustomization.yaml
   ```

3. Leé el manifiesto de sincronización — esta es la raíz de todo el árbol de reconciliación.

   ```bash
   cat clusters/dev/flux-system/gotk-sync.yaml
   ```

   ```yaml
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: flux-system
     namespace: flux-system
   spec:
     interval: 1m0s
     ref:
       branch: main
     secretRef:
       name: flux-system
     url: ssh://git@github.com/<user>/gitops-cgoa.git
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: flux-system
     namespace: flux-system
   spec:
     interval: 10m0s
     path: ./clusters/dev
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   ```

4. Observá el conjunto de controladores y los dos bucles de reconciliación por separado.

   ```bash
   kubectl -n flux-system get deploy
   flux get sources git
   flux get kustomizations
   ```

   ```
   NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
   helm-controller               1/1     1            1           3m
   image-automation-controller   1/1     1            1           3m
   image-reflector-controller    1/1     1            1           3m
   kustomize-controller          1/1     1            1           3m
   notification-controller       1/1     1            1           3m
   source-controller             1/1     1            1           3m

   NAME         REVISION            SUSPENDED  READY  MESSAGE
   flux-system  main@sha1:a3d47e1   False      True   stored artifact for revision 'main@sha1:a3d47e1'

   NAME         REVISION            SUSPENDED  READY  MESSAGE
   flux-system  main@sha1:a3d47e1   False      True   Applied revision: main@sha1:a3d47e1
   ```

5. Demostrá que la instalación ahora está *reconciliada*, no meramente *instalada*: borrá un controlador y dejá que Flux lo restaure.

   ```bash
   kubectl -n flux-system delete deploy notification-controller
   flux reconcile kustomization flux-system --with-source
   kubectl -n flux-system get deploy notification-controller
   ```

   ```
   deployment.apps "notification-controller" deleted
   ► annotating GitRepository flux-system in flux-system namespace
   ✔ GitRepository annotated
   ◎ waiting for GitRepository reconciliation
   ✔ fetched revision main@sha1:a3d47e1
   ► annotating Kustomization flux-system in flux-system namespace
   ✔ Kustomization annotated
   ◎ waiting for Kustomization reconciliation
   ✔ applied revision main@sha1:a3d47e1

   NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
   notification-controller   1/1     1            1           9s
   ```

### Control de comprensión — Bloque 1

- **Q1.1** `GitRepository.spec.interval` es `1m` y `Kustomization.spec.interval` es `10m`. Rastreá qué hace realmente cada temporizador, y establecé la latencia en el peor caso entre un `git push` y la llegada del cambio al clúster con esos valores.
- **Q1.2** En el paso 5 corriste `flux reconcile ... --with-source`. ¿Qué diferencia hay en la obtención del *source* cuando omitís esa flag, y por qué omitirla igual habría funcionado en este caso particular?
- **Q1.3** El `Kustomization` de la raíz tiene `prune: true`. Explicá con precisión cómo decide el controlador que un objeto es podable — qué compara, y dónde se guarda el registro.
- **Q1.4** El bootstrap escribió `gotk-components.yaml` en la misma ruta que reconcilia el `Kustomization` raíz. ¿Qué propiedad operativa te compra esa autorreferencia, y cuál es el único paso de actualización que esto **no** vuelve automático?

---

## Ejercicio 2 — Desplegar una aplicación con Flux + overlays de Kustomize

**Objetivo:** separar *source* de *renderizado* de *configuración de entorno*.

### Pasos

1. Creá una base para una aplicación de ejemplo. Desde la raíz del repo:

   ```bash
   mkdir -p apps/base/podinfo apps/dev
   ```

2. Escribí los manifiestos base.

   ```bash
   cat > apps/base/podinfo/deployment.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: podinfo
     labels:
       app.kubernetes.io/name: podinfo
   spec:
     replicas: 1
     selector:
       matchLabels:
         app.kubernetes.io/name: podinfo
     template:
       metadata:
         labels:
           app.kubernetes.io/name: podinfo
       spec:
         securityContext:
           runAsNonRoot: true
           seccompProfile:
             type: RuntimeDefault
         containers:
           - name: podinfo
             image: ghcr.io/stefanprodan/podinfo:6.7.0
             imagePullPolicy: IfNotPresent
             ports:
               - name: http
                 containerPort: 9898
             readinessProbe:
               httpGet:
                 path: /readyz
                 port: http
               initialDelaySeconds: 3
             livenessProbe:
               httpGet:
                 path: /healthz
                 port: http
               initialDelaySeconds: 5
             securityContext:
               allowPrivilegeEscalation: false
               capabilities:
                 drop: ["ALL"]
               readOnlyRootFilesystem: true
             resources:
               requests:
                 cpu: 10m
                 memory: 32Mi
               limits:
                 memory: 128Mi
   EOF

   cat > apps/base/podinfo/service.yaml <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: podinfo
     labels:
       app.kubernetes.io/name: podinfo
   spec:
     type: ClusterIP
     selector:
       app.kubernetes.io/name: podinfo
     ports:
       - name: http
         port: 9898
         targetPort: http
   EOF

   cat > apps/base/podinfo/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   EOF
   ```

3. Escribí el overlay `dev` — un namespace, un patch de réplicas y una etiqueta común.

   ```bash
   cat > apps/dev/namespace.yaml <<'EOF'
   apiVersion: v1
   kind: Namespace
   metadata:
     name: podinfo-dev
   EOF

   cat > apps/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-dev
   resources:
     - namespace.yaml
     - ../base/podinfo
   labels:
     - pairs:
         app.kubernetes.io/part-of: cgoa-lab
         environment: dev
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 2
   EOF
   ```

4. Renderizá localmente **antes** de commitear. Este es el bucle de feedback más barato posible y no cuesta ningún clúster.

   ```bash
   kubectl kustomize apps/dev | grep -E '^(kind|  name:|  namespace:|  replicas:)' 
   ```

   ```
   kind: Namespace
     name: podinfo-dev
   kind: Service
     name: podinfo
     namespace: podinfo-dev
   kind: Deployment
     name: podinfo
     namespace: podinfo-dev
     replicas: 2
   ```

5. Declará el `Kustomization` de Flux que reconcilia este overlay, y ubicalo en la ruta del clúster para que la raíz lo tome.

   ```bash
   cat > clusters/dev/apps.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: apps-dev
     namespace: flux-system
   spec:
     interval: 10m
     retryInterval: 1m
     timeout: 3m
     path: ./apps/dev
     prune: true
     wait: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     healthChecks:
       - apiVersion: apps/v1
         kind: Deployment
         name: podinfo
         namespace: podinfo-dev
   EOF
   ```

6. Commiteá, pusheá y forzá una reconciliación en vez de esperar el intervalo.

   ```bash
   git add apps clusters && git commit -m "feat: podinfo dev overlay" && git push
   flux reconcile kustomization flux-system --with-source
   flux get kustomizations
   ```

   ```
   NAME         REVISION            SUSPENDED  READY  MESSAGE
   apps-dev     main@sha1:c19be40   False      True   Applied revision: main@sha1:c19be40
   flux-system  main@sha1:c19be40   False      True   Applied revision: main@sha1:c19be40
   ```

7. Confirmá la carga de trabajo y rastreá un objeto individual de vuelta hasta su fuente de verdad.

   ```bash
   kubectl -n podinfo-dev get deploy,pod
   flux trace --kind=Deployment --api-version=apps/v1 --namespace=podinfo-dev podinfo
   ```

   ```
   NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/podinfo   2/2     2            2           31s

   Object:         Deployment/podinfo
   Namespace:      podinfo-dev
   Status:         Managed by Flux
   ---
   Kustomization:  apps-dev
   Namespace:      flux-system
   Path:           ./apps/dev
   Revision:       main@sha1:c19be40
   Status:         Last reconciled at 2026-08-18 10:41:12 +0000 UTC
   Message:        Applied revision: main@sha1:c19be40
   ---
   GitRepository:  flux-system
   Namespace:      flux-system
   URL:            ssh://git@github.com/<user>/gitops-cgoa.git
   Branch:         main
   Revision:       main@sha1:c19be40
   Status:         Last reconciled at 2026-08-18 10:41:11 +0000 UTC
   Message:        stored artifact for revision 'main@sha1:c19be40'
   ```

### Control de comprensión — Bloque 2

- **Q2.1** Ahora hay dos objetos llamados "Kustomization" en juego con `apiVersion`s *diferentes*. Nombrá ambos, y explicá cuál ejecuta el `kustomize-controller` y cuál simplemente *lee como datos*.
- **Q2.2** `apps-dev` establece `wait: true` **y** una entrada `healthChecks`. ¿Son redundantes? Describí la diferencia de comportamiento y cuándo usarías uno sin el otro.
- **Q2.3** En el overlay pusiste `includeSelectors: false` en las etiquetas comunes. Predecí, concretamente, qué se rompería en la *segunda* reconciliación si eso fuera `true`.
- **Q2.4** `flux trace` reportó una cadena de tres objetos. ¿Qué principio de GitOps vuelve auditable esa cadena, y cuál sería la evidencia equivalente si hubieras corrido `kubectl apply -f` a mano?

---

## Ejercicio 3 — Detección de drift, autorreparación y los límites de ambos

**Objetivo:** ver qué *considera* y qué *no considera* drift un reconciliador.

### Pasos

1. Introducí drift en un campo que el estado deseado declara.

   ```bash
   kubectl -n podinfo-dev scale deployment podinfo --replicas=5
   kubectl -n podinfo-dev get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   deployment.apps/podinfo scaled
   5
   ```

2. Disparar la reconciliación solo del Kustomization de la app (no hace falta refetch del source — Git no cambió).

   ```bash
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   ► annotating Kustomization apps-dev in flux-system namespace
   ✔ Kustomization annotated
   ◎ waiting for Kustomization reconciliation
   ✔ applied revision main@sha1:c19be40

   2
   ```

3. Ahora introducí drift en un campo que el estado deseado **no** declara.

   ```bash
   kubectl -n podinfo-dev set env deployment/podinfo INJECTED=by-hand
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
   ```

   ```
   deployment.apps/podinfo env updated
   ✔ applied revision main@sha1:c19be40

   [{"name":"INJECTED","value":"by-hand"}]
   ```

   La variable de entorno **sobrevivió**. Entendé por qué antes de continuar.

4. Inspeccioná el registro de gestión de campos que explica el paso 3.

   ```bash
   kubectl -n podinfo-dev get deploy podinfo --show-managed-fields -o yaml \
     | yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}'
   ```

   ```yaml
   manager: kustomize-controller
   operation: Apply
   manager: kubectl-set
   operation: Update
   ```

5. Corregilo declarativamente — el único remedio legítimo. Agregá el campo a Git para que quede en propiedad, o eliminá al intruso tomando la propiedad. Acá, forzar la propiedad de toda la plantilla de pod declarando una lista `env` vacía *no* es cómo funciona; en cambio, observá la vía de escape soportada:

   ```bash
   kubectl -n podinfo-dev delete deployment podinfo
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
   ```

   ```
   deployment.apps "podinfo" deleted
   ✔ applied revision main@sha1:c19be40

   ```

6. Probá el pruning. Sacá el Service de la base y confirmá que el objeto del clúster desaparece.

   ```bash
   sed -i '/service.yaml/d' apps/base/podinfo/kustomization.yaml
   git commit -am "chore: drop podinfo service" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl -n podinfo-dev get svc
   ```

   ```
   ✔ applied revision main@sha1:7f22ab3
   No resources found in podinfo-dev namespace.
   ```

7. Restauralo (lo necesitás más adelante).

   ```bash
   git revert --no-edit HEAD && git push
   flux reconcile kustomization flux-system --with-source
   ```

### Control de comprensión — Bloque 3

- **Q3.1** Las réplicas se revirtieron; la variable de entorno inyectada no. Dá el mecanismo — nombrá la característica de la API y la regla específica que produce esa asimetría.
- **Q3.2** Un colega propone "que Flux simplemente borre todo lo que no tiene en propiedad". Explicá, con un ejemplo concreto de un controlador, por qué eso es inseguro en un clúster real.
- **Q3.3** En el paso 6, el pruning eliminó el Service después del commit. Si en cambio se hubiera borrado en Git el directorio `apps/dev` *entero*, ¿qué haría `prune: true`, y qué te protege de hacerle eso accidentalmente a un namespace de producción?
- **Q3.4** Distinguí *detección de drift* de *corrección de drift*. Nombrá un escenario de producción donde querés deliberadamente detección con alertas pero **no** corrección automática.

---

## Ejercicio 4 — Argo CD: instalación, CRD Application y la comparación de tres vías

**Objetivo:** los mismos principios, un modelo de reconciliación distinto — renderizado del lado del clúster, un objeto `Application` explícito y una UI/API para la máquina de estados de sincronización.

### Pasos

1. Instalá Argo CD en su propio namespace. (En un montaje GitOps real este manifiesto provendría a su vez de Git — ver Q4.4.)

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
   ```

   ```
   deployment "argocd-server" successfully rolled out
   ```

2. Obtené la contraseña inicial de admin e iniciá sesión a través de un port-forward.

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
   ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d)
   argocd login localhost:8080 --username admin --password "$ARGOCD_PW" --insecure
   ```

   ```
   'admin:login' logged in successfully
   Context 'localhost:8080' updated
   ```

3. Declará una `Application`. Notá que es *declarativa* — creada a partir de un archivo en Git, no de `argocd app create`.

   ```bash
   cat > argocd/podinfo-staging.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: podinfo-staging
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/<user>/gitops-cgoa.git
       targetRevision: main
       path: apps/staging
     destination:
       server: https://kubernetes.default.svc
       namespace: podinfo-staging
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
         allowEmpty: false
       syncOptions:
         - CreateNamespace=true
         - ApplyOutOfSyncOnly=true
         - ServerSideApply=true
       retry:
         limit: 5
         backoff:
           duration: 5s
           factor: 2
           maxDuration: 3m
   EOF
   ```

4. Creá el overlay `staging` al que apunta.

   ```bash
   mkdir -p apps/staging
   cat > apps/staging/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-staging
   resources:
     - ../base/podinfo
   labels:
     - pairs:
         environment: staging
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
   EOF
   ```

5. Pusheá, luego aplicá la `Application` una vez (el bootstrap del propio árbol de Argo).

   ```bash
   git add argocd apps/staging && git commit -m "feat: argocd staging app" && git push
   kubectl apply -f argocd/podinfo-staging.yaml
   argocd app wait podinfo-staging --health --timeout 180
   ```

   ```
   application.argoproj.io/podinfo-staging created

   Name:               argocd/podinfo-staging
   Project:            default
   Server:             https://kubernetes.default.svc
   Namespace:          podinfo-staging
   Repo:               https://github.com/<user>/gitops-cgoa.git
   Target:             main
   Path:               apps/staging
   SyncWindow:         Sync Allowed
   Sync Policy:        Automated (Prune)
   Sync Status:        Synced to main (9d02c77)
   Health Status:      Healthy
   ```

6. Leé la vista por recurso y la maquinaria de diff live-vs-deseado.

   ```bash
   argocd app resources podinfo-staging
   kubectl -n podinfo-staging scale deploy podinfo --replicas=7
   argocd app diff podinfo-staging
   ```

   ```
   GROUP  KIND        NAMESPACE         NAME     ORPHANED  STATUS  HEALTH
          Service     podinfo-staging   podinfo  No        Synced  Healthy
   apps   Deployment  podinfo-staging   podinfo  No        Synced  Healthy

   ===== apps/Deployment podinfo-staging/podinfo ======
   3c3
   <   replicas: 7
   ---
   >   replicas: 3
   ```

7. Observá cómo la autorreparación cierra la brecha, luego confirmá.

   ```bash
   argocd app wait podinfo-staging --sync --timeout 120
   kubectl -n podinfo-staging get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   3
   ```

### Control de comprensión — Bloque 4

- **Q4.1** `syncPolicy.automated` tiene `prune` y `selfHeal` como booleanos independientes. Describí el comportamiento exacto de una `Application` con `selfHeal: true, prune: false` cuando un recurso se borra de Git y otro distinto se edita en el clúster.
- **Q4.2** `argocd app diff` imprimió una diferencia mientras `argocd app resources` reportaba `Synced`. Conciliá esas dos afirmaciones — ¿qué semántica de refresco lo explica?
- **Q4.3** La `Application` lleva `resources-finalizer.argocd.argoproj.io`. ¿Qué pasa si hacés `kubectl delete application podinfo-staging` **con** el finalizer versus **sin** él, y por qué esa elección es una decisión de política y no un detalle?
- **Q4.4** Argo CD se instaló acá con un `kubectl apply` crudo desde una URL. Nombrá dos propiedades GitOps concretas que perdiste al hacerlo, y esbozá cómo harías que Argo CD se gestione a sí mismo.
- **Q4.5** Se establecieron `ApplyOutOfSyncOnly=true` y `ServerSideApply=true`. Indicá qué problema operativo resuelve cada uno.

---

## Ejercicio 5 — Sync waves, hooks y garantías de orden

**Objetivo:** controlar el *orden* en un sistema cuyo comportamiento por defecto es "aplicar todo, converger eventualmente".

### Pasos

1. Agregá un paquete ordenado: un Job de migración que debe completarse antes de que la app se despliegue, y un ConfigMap que debe existir antes de ambos.

   ```bash
   mkdir -p apps/staging/ordering
   cat > apps/staging/ordering/configmap.yaml <<'EOF'
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: podinfo-config
     annotations:
       argocd.argoproj.io/sync-wave: "-1"
   data:
     PODINFO_UI_MESSAGE: "cgoa staging"
   EOF

   cat > apps/staging/ordering/migration-job.yaml <<'EOF'
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: podinfo-migrate
     annotations:
       argocd.argoproj.io/hook: PreSync
       argocd.argoproj.io/hook-delete-policy: HookSucceeded
   spec:
     backoffLimit: 2
     ttlSecondsAfterFinished: 300
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: migrate
             image: busybox:1.36
             command: ["sh", "-c", "echo 'running schema migration'; sleep 5; echo done"]
             securityContext:
               allowPrivilegeEscalation: false
               runAsNonRoot: true
               runAsUser: 65534
               capabilities:
                 drop: ["ALL"]
   EOF
   ```

2. Conectalos al overlay y dale al Deployment una wave posterior.

   ```bash
   cat > apps/staging/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-staging
   resources:
     - ../base/podinfo
     - ordering/configmap.yaml
     - ordering/migration-job.yaml
   labels:
     - pairs:
         environment: staging
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
         - op: add
           path: /metadata/annotations
           value:
             argocd.argoproj.io/sync-wave: "1"
         - op: add
           path: /spec/template/spec/containers/0/envFrom
           value:
             - configMapRef:
                 name: podinfo-config
   EOF
   ```

3. Pusheá y observá el orden en tiempo real.

   ```bash
   git add apps/staging && git commit -m "feat: sync waves + presync hook" && git push
   argocd app sync podinfo-staging --async
   watch -n1 'argocd app get podinfo-staging --output tree'
   ```

   ```
   KIND/NAME                        STATUS      HEALTH
   Job/podinfo-migrate              Running     Progressing   <- PreSync hook
   ConfigMap/podinfo-config         OutOfSync   -
   Deployment/podinfo               OutOfSync   Healthy
   ```

   luego, tras completarse el hook:

   ```
   KIND/NAME                        STATUS      HEALTH
   ConfigMap/podinfo-config         Synced      -             <- wave -1
   Deployment/podinfo               Synced      Progressing   <- wave 1
   └─ReplicaSet/podinfo-7c9f4b8d5   
     └─Pod/podinfo-7c9f4b8d5-x2klm  
   ```

4. Confirmá que el Job del hook fue recolectado por su política de borrado.

   ```bash
   kubectl -n podinfo-staging get jobs
   ```

   ```
   No resources found in podinfo-staging namespace.
   ```

5. Compará con el modelo de orden de Flux, que es *entre* Kustomizations en vez de adentro de uno. Agregá una arista de dependencia:

   ```bash
   cat > clusters/dev/infra.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: infra-dev
     namespace: flux-system
   spec:
     interval: 10m
     path: ./infra/dev
     prune: true
     wait: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   EOF

   # make apps depend on infra
   yq -i '.spec.dependsOn = [{"name": "infra-dev"}]' clusters/dev/apps.yaml
   mkdir -p infra/dev
   cat > infra/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources: []
   EOF
   git add clusters infra && git commit -m "feat: infra->apps dependency" && git push
   flux reconcile kustomization flux-system --with-source
   flux get kustomizations
   ```

   ```
   NAME         REVISION            SUSPENDED  READY  MESSAGE
   apps-dev     main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   flux-system  main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   infra-dev    main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   ```

### Control de comprensión — Bloque 5

- **Q5.1** Indicá la regla de orden que aplica Argo CD *dentro* de una sola wave, antes siquiera de considerar las waves. ¿Por qué eso hace que las waves sean necesarias solo para dependencias entre kinds que no puede inferir?
- **Q5.2** El Job de migración es un hook `PreSync`, no un recurso de wave `-2`. Dá dos comportamientos que obtenés del hook y que un Job ordenado por wave no proveería.
- **Q5.3** `dependsOn` de Flux y `sync-wave` de Argo expresan orden, pero con granularidades distintas. Describí un requisito que `dependsOn` puede expresar y `sync-wave` no, y uno donde ocurre lo inverso.
- **Q5.4** `infra-dev` tiene `wait: true`. Explicá por qué omitirlo dejaría silenciosamente a `dependsOn` casi sin sentido.

---

## Ejercicio 6 — Helm bajo GitOps: `HelmRelease` y el source Helm de Argo

**Objetivo:** correr un motor de plantillas dentro del bucle de reconciliación sin reintroducir un `helm upgrade` imperativo.

### Pasos

1. Lado Flux — declará el repositorio del chart y el release como datos.

   ```bash
   mkdir -p infra/dev/podinfo-helm
   cat > infra/dev/podinfo-helm/repository.yaml <<'EOF'
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 30m
     url: https://stefanprodan.github.io/podinfo
   EOF

   cat > infra/dev/podinfo-helm/release.yaml <<'EOF'
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: podinfo-helm
     namespace: flux-system
   spec:
     interval: 10m
     releaseName: podinfo-helm
     targetNamespace: podinfo-helm
     install:
       createNamespace: true
       remediation:
         retries: 3
     upgrade:
       remediation:
         retries: 3
         remediateLastFailure: true
       cleanupOnFail: true
     driftDetection:
       mode: enabled
     chart:
       spec:
         chart: podinfo
         version: "6.7.x"
         sourceRef:
           kind: HelmRepository
           name: podinfo
           namespace: flux-system
         interval: 30m
     values:
       replicaCount: 2
       ui:
         message: "reconciled by flux"
       resources:
         requests:
           cpu: 10m
           memory: 32Mi
   EOF

   cat > infra/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - podinfo-helm/repository.yaml
     - podinfo-helm/release.yaml
   EOF
   ```

2. Pusheá y reconciliá, luego inspeccioná el release.

   ```bash
   git add infra && git commit -m "feat: podinfo helmrelease" && git push
   flux reconcile kustomization flux-system --with-source
   flux get helmreleases -A
   kubectl -n podinfo-helm get deploy
   ```

   ```
   NAMESPACE    NAME          REVISION  SUSPENDED  READY  MESSAGE
   flux-system  podinfo-helm  6.7.1     False      True   Helm install succeeded for release podinfo-helm/podinfo-helm.v1 with chart podinfo@6.7.1

   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo-helm   2/2     2            2           41s
   ```

3. Demostrá la detección de drift de Helm. Cambiá un valor en el clúster, no en Git.

   ```bash
   kubectl -n podinfo-helm set env deploy/podinfo-helm PODINFO_UI_MESSAGE="tampered"
   flux reconcile helmrelease podinfo-helm
   kubectl -n podinfo-helm get deploy podinfo-helm \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}{"\n"}'
   ```

   ```
   ✔ applied revision 6.7.1
   reconciled by flux
   ```

4. Lado Argo CD — el equivalente, usando un chart como source de una `Application` con los values guardados en Git.

   ```bash
   cat > argocd/podinfo-helm-argo.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: podinfo-helm-argo
     namespace: argocd
   spec:
     project: default
     sources:
       - repoURL: https://stefanprodan.github.io/podinfo
         chart: podinfo
         targetRevision: 6.7.1
         helm:
           releaseName: podinfo-argo
           valueFiles:
             - $values/argocd/values/podinfo-staging.yaml
       - repoURL: https://github.com/<user>/gitops-cgoa.git
         targetRevision: main
         ref: values
     destination:
       server: https://kubernetes.default.svc
       namespace: podinfo-helm-argo
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   EOF

   mkdir -p argocd/values
   cat > argocd/values/podinfo-staging.yaml <<'EOF'
   replicaCount: 1
   ui:
     message: "reconciled by argo cd"
   EOF

   git add argocd && git commit -m "feat: multi-source helm app" && git push
   kubectl apply -f argocd/podinfo-helm-argo.yaml
   argocd app wait podinfo-helm-argo --health --timeout 180
   ```

5. Mirá qué envía realmente Argo al servidor de API.

   ```bash
   argocd app manifests podinfo-helm-argo | grep -E '^(kind|  name:)' | head
   kubectl -n podinfo-helm-argo get deploy -o wide
   ```

### Control de comprensión — Bloque 6

- **Q6.1** Ambas herramientas ejecutan un renderizado equivalente a `helm template`, pero solo una conserva un *registro* de release de Helm. ¿Cuál, dónde lo almacena, y nombrá una capacidad operativa que ese registro habilita y que el otro enfoque pierde.
- **Q6.2** El `HelmRelease` fija `version: "6.7.x"` mientras que la `Application` de Argo fija `targetRevision: 6.7.1`. Explicá qué rompe la garantía GitOps de *declarativo y versionado* en la primera forma, y cuándo un rango es de todos modos defendible.
- **Q6.3** La app de Argo usa dos `sources` con `ref: values`. Indicá qué problema de diseño resuelve esto y por qué simplemente forkear el chart dentro de tu repo suele ser peor.
- **Q6.4** `driftDetection.mode: enabled` hubo que activarlo explícitamente en el `HelmRelease`. ¿Por qué no es el valor por defecto, dado que Flux corrige el drift en Kustomizations comunes sin preguntar?

---

## Ejercicio 7 — Secretos: estado cifrado con SOPS en Git

**Objetivo:** conservar la propiedad de "todo en Git" sin poner credenciales en texto plano en Git.

### Pasos

1. Generá un par de claves `age` y cargá la mitad **privada** solamente en el clúster.

   ```bash
   age-keygen -o age.agekey
   export SOPS_AGE_RECIPIENT=$(grep 'public key:' age.agekey | awk '{print $4}')
   echo "$SOPS_AGE_RECIPIENT"
   ```

   ```
   Public key: age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
   age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
   ```

   ```bash
   cat age.agekey | kubectl -n flux-system create secret generic sops-age \
     --from-file=age.agekey=/dev/stdin
   ```

   ```
   secret/sops-age created
   ```

2. Agregá un `.sops.yaml` para que las reglas de cifrado sean a su vez declarativas y solo se cifren los *valores*.

   ```bash
   cat > .sops.yaml <<EOF
   creation_rules:
     - path_regex: .*\.sops\.yaml$
       encrypted_regex: "^(data|stringData)$"
       age: ${SOPS_AGE_RECIPIENT}
   EOF
   ```

3. Escribí el Secret en texto plano, cifralo in situ y verificá qué termina en Git.

   ```bash
   cat > apps/dev/podinfo-secret.sops.yaml <<'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: podinfo-credentials
     namespace: podinfo-dev
   type: Opaque
   stringData:
     API_TOKEN: "s3cr3t-do-not-commit-in-clear"
   EOF

   sops --encrypt --in-place apps/dev/podinfo-secret.sops.yaml
   head -12 apps/dev/podinfo-secret.sops.yaml
   ```

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
       name: podinfo-credentials
       namespace: podinfo-dev
   type: Opaque
   stringData:
       API_TOKEN: ENC[AES256_GCM,data:pQ9v2r...,iv:8Kx...,tag:mJ4...,type:str]
   sops:
       age:
           - recipient: age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
             enc: |
               -----BEGIN AGE ENCRYPTED FILE-----
   ```

   Notá que `apiVersion`, `kind`, `metadata` y `type` quedan **legibles** — eso es deliberado.

4. Decile al `Kustomization` de Flux cómo descifrar, e incluí el archivo en el overlay.

   ```bash
   yq -i '.resources += ["podinfo-secret.sops.yaml"]' apps/dev/kustomization.yaml
   yq -i '.spec.decryption = {"provider": "sops", "secretRef": {"name": "sops-age"}}' \
     clusters/dev/apps.yaml
   git add .sops.yaml apps clusters && git commit -m "feat: sops-encrypted secret" && git push
   flux reconcile kustomization flux-system --with-source
   ```

5. Verificá que el clúster tiene el texto plano y Git no.

   ```bash
   kubectl -n podinfo-dev get secret podinfo-credentials \
     -o jsonpath='{.data.API_TOKEN}' | base64 -d; echo
   git grep -c 's3cr3t-do-not-commit-in-clear' || echo "not present in working tree"
   ```

   ```
   s3cr3t-do-not-commit-in-clear
   not present in working tree
   ```

6. Borrá la clave privada localmente y confirmá que la reconciliación sigue funcionando — el clúster es la única autoridad de descifrado.

   ```bash
   shred -u age.agekey
   flux reconcile kustomization apps-dev
   ```

   ```
   ✔ applied revision main@sha1:b71c904
   ```

### Control de comprensión — Bloque 7

- **Q7.1** `encrypted_regex: "^(data|stringData)$"` deja la metadata en claro. Nombrá el flujo de trabajo GitOps específico que se rompería si todo el archivo fuera opaco, y la fuga de información específica que aceptás a cambio.
- **Q7.2** Compará SOPS-en-Git con un External Secrets Operator que tira de Vault. Para cada uno, indicá dónde vive la *fuente de verdad* del valor del secreto, y qué requiere una reconstrucción completa del clúster solo a partir de Git.
- **Q7.3** Sealed Secrets cifra con una clave pública en poder del controlador, acotada por namespace *y* nombre por defecto. Explicá qué previene ese acotamiento, y qué te cuesta cuando promovés un manifiesto de staging a producción.
- **Q7.4** Después del paso 6 ya no podés descifrar el archivo localmente. Describí la consecuencia para recuperación ante desastres y la política mínima de respaldo que vuelve seguro este diseño.

---

## Ejercicio 8 — Automatización de actualización de imágenes: cerrar el bucle CI→CD a través de Git

**Objetivo:** que las nuevas imágenes de contenedor lleguen al clúster *vía un commit*, nunca vía un pipeline que le habla al servidor de API.

### Pasos

1. Declará el escáner de imágenes y la política de selección.

   ```bash
   mkdir -p clusters/dev/automation
   cat > clusters/dev/automation/image.yaml <<'EOF'
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImageRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     image: ghcr.io/stefanprodan/podinfo
     interval: 5m
     exclusionList:
       - "^.*\\.sig$"
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImagePolicy
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     imageRepositoryRef:
       name: podinfo
     policy:
       semver:
         range: 6.7.x
   EOF
   ```

2. Declará quién escribe el commit y dónde.

   ```bash
   cat > clusters/dev/automation/update.yaml <<'EOF'
   apiVersion: image.toolkit.fluxcd.io/v1beta1
   kind: ImageUpdateAutomation
   metadata:
     name: podinfo-automation
     namespace: flux-system
   spec:
     interval: 5m
     sourceRef:
       kind: GitRepository
       name: flux-system
     git:
       checkout:
         ref:
           branch: main
       commit:
         author:
           name: fluxcdbot
           email: fluxcdbot@users.noreply.github.com
         messageTemplate: |
           chore(images): {{range .Changed.Changes}}{{.OldValue}} -> {{.NewValue}}{{end}}

           Automated image update by Flux image-automation-controller.
       push:
         branch: main
     update:
       path: ./apps/base/podinfo
       strategy: Setters
   EOF
   ```

3. Marcá el campo que debe reescribirse. El marcador es un comentario YAML que referencia la política por `namespace:name`.

   ```bash
   sed -i 's|image: ghcr.io/stefanprodan/podinfo:6.7.0|image: ghcr.io/stefanprodan/podinfo:6.7.0 # {"$imagepolicy": "flux-system:podinfo"}|' \
     apps/base/podinfo/deployment.yaml
   grep image: apps/base/podinfo/deployment.yaml
   ```

   ```
           image: ghcr.io/stefanprodan/podinfo:6.7.0 # {"$imagepolicy": "flux-system:podinfo"}
   ```

4. Pusheá y observá cómo la política resuelve un tag.

   ```bash
   git add apps clusters && git commit -m "feat: image update automation" && git push
   flux reconcile kustomization flux-system --with-source
   flux get images all -A
   ```

   ```
   NAMESPACE    NAME             LAST SCAN                 SUSPENDED  READY  MESSAGE
   flux-system  podinfo          2026-08-18T11:02:47Z      False      True   successful scan: found 41 tags

   NAMESPACE    NAME             LATEST IMAGE                            READY  MESSAGE
   flux-system  podinfo          ghcr.io/stefanprodan/podinfo:6.7.1      True   Latest image tag for 'ghcr.io/stefanprodan/podinfo' resolved to 6.7.1

   NAMESPACE    NAME                 LAST RUN                  SUSPENDED  READY  MESSAGE
   flux-system  podinfo-automation   2026-08-18T11:03:12Z      False      True   committed and pushed commit '4ac9e30' to branch 'main'
   ```

5. Leé el commit que escribió el controlador, luego confirmá que el clúster lo siguió.

   ```bash
   git pull --rebase
   git log -1 --format='%an <%ae>%n%n%B'
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   fluxcdbot <fluxcdbot@users.noreply.github.com>

   chore(images): ghcr.io/stefanprodan/podinfo:6.7.0 -> ghcr.io/stefanprodan/podinfo:6.7.1

   Automated image update by Flux image-automation-controller.

   ghcr.io/stefanprodan/podinfo:6.7.1
   ```

6. Hacelo con revisión previa en vez de push directo a main — la forma de producción.

   ```bash
   yq -i '.spec.git.push.branch = "flux-image-updates"' clusters/dev/automation/update.yaml
   git commit -am "chore: image updates via PR branch" && git push
   ```

### Control de comprensión — Bloque 8

- **Q8.1** La política es `semver: {range: 6.7.x}`. Explicá qué pasa el día que se publique `6.8.0`, y por qué ese es el comportamiento *deseado* para un actualizador automático.
- **Q8.2** En el paso 6 el controlador ahora pushea a `flux-image-updates` mientras el `GitRepository` sigue rastreando `main`. Describí el camino completo que ahora toma una imagen nueva hasta producción, y nombrá el punto de control humano.
- **Q8.3** Un compañero argumenta que es más simple que CI corra `kubectl set image` después de compilar. Enumerá tres propiedades de este ejercicio que ese enfoque resigna.
- **Q8.4** `ImageRepository` escanea el registro cada 5 minutos. Identificá las dos preocupaciones distintas de límite de tasa/credenciales que esto crea y cómo configurarías cada una.
- **Q8.5** ¿Por qué el marcador `$imagepolicy` vive en la **base** y no en el overlay `dev`, y qué saldría mal si marcaras ambos overlays de forma independiente?

---

## Ejercicio 9 — Entrega progresiva: canary con análisis usando Argo Rollouts

**Objetivo:** la propia estrategia de despliegue se vuelve estado declarativo, y la promoción es guiada por señales medidas.

### Pasos

1. Instalá Argo Rollouts y su plugin de kubectl.

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   curl -sSL -o /tmp/kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   sudo install -m 555 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
   kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=3m
   ```

2. Declará un `Rollout` con estrategia canary y una compuerta de análisis automatizada.

   ```bash
   mkdir -p apps/canary
   cat > apps/canary/analysis.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: success-rate
   spec:
     args:
       - name: service-name
     metrics:
       - name: request-success-rate
         interval: 30s
         count: 3
         successCondition: result[0] >= 0.95
         failureLimit: 1
         provider:
           prometheus:
             address: http://prometheus.monitoring.svc:9090
             query: |
               sum(rate(http_requests_total{
                 service="{{args.service-name}}", status!~"5.."
               }[1m]))
               /
               sum(rate(http_requests_total{
                 service="{{args.service-name}}"
               }[1m]))
   EOF

   cat > apps/canary/rollout.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: podinfo-canary
   spec:
     replicas: 4
     revisionHistoryLimit: 3
     selector:
       matchLabels:
         app: podinfo-canary
     template:
       metadata:
         labels:
           app: podinfo-canary
       spec:
         containers:
           - name: podinfo
             image: ghcr.io/stefanprodan/podinfo:6.7.0
             ports:
               - name: http
                 containerPort: 9898
             readinessProbe:
               httpGet:
                 path: /readyz
                 port: http
             resources:
               requests:
                 cpu: 10m
                 memory: 32Mi
     strategy:
       canary:
         analysis:
           templates:
             - templateName: success-rate
           startingStep: 2
           args:
             - name: service-name
               value: podinfo-canary
         steps:
           - setWeight: 20
           - pause: {duration: 30s}
           - setWeight: 50
           - pause: {duration: 30s}
           - setWeight: 100
   EOF

   cat > apps/canary/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-canary
   resources:
     - namespace.yaml
     - analysis.yaml
     - rollout.yaml
   EOF

   cat > apps/canary/namespace.yaml <<'EOF'
   apiVersion: v1
   kind: Namespace
   metadata:
     name: podinfo-canary
   EOF
   ```

3. Reconcilialo a través de Flux y observá el despliegue inicial (no canary).

   ```bash
   cat > clusters/dev/canary.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: canary-dev
     namespace: flux-system
   spec:
     interval: 10m
     path: ./apps/canary
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   EOF
   git add apps/canary clusters/dev/canary.yaml && git commit -m "feat: canary rollout" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary
   ```

   ```
   Name:            podinfo-canary
   Namespace:       podinfo-canary
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          5/5
     SetWeight:     100
     ActualWeight:  100
   Images:          ghcr.io/stefanprodan/podinfo:6.7.0 (stable)
   Replicas:
     Desired:       4
     Current:       4
     Updated:       4
     Ready:         4
     Available:     4
   ```

4. Disparar un canary cambiando la imagen **en Git**.

   ```bash
   sed -i 's|podinfo:6.7.0|podinfo:6.7.1|' apps/canary/rollout.yaml
   git commit -am "feat: podinfo 6.7.1 canary" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary --watch
   ```

   ```
   Name:            podinfo-canary
   Status:          ॥ Paused
   Message:         CanaryPauseStep
   Strategy:        Canary
     Step:          1/5
     SetWeight:     20
     ActualWeight:  20
   Images:          ghcr.io/stefanprodan/podinfo:6.7.0 (stable)
                    ghcr.io/stefanprodan/podinfo:6.7.1 (canary)
   Replicas:
     Desired:       4
     Current:       5
     Updated:       1
   ```

5. Abortá el rollout de forma imperativa, luego observá el conflicto con GitOps.

   ```bash
   kubectl argo rollouts abort podinfo-canary -n podinfo-canary
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | head -5
   flux reconcile kustomization canary-dev
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | head -5
   ```

   ```
   Name:            podinfo-canary
   Status:          ✖ Degraded
   Message:         RolloutAborted: Rollout aborted update to revision 2

   Name:            podinfo-canary
   Status:          ॥ Paused
   Message:         CanaryPauseStep
   ```

   El abort no sobrevivió a la reconciliación. Entendé por qué.

6. Hacé el rollback de la manera correcta — revertí el commit.

   ```bash
   git revert --no-edit HEAD && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | grep Images -A2
   ```

### Control de comprensión — Bloque 9

- **Q9.1** En el paso 5 el abort quedó deshecho. Nombrá el mecanismo exacto, y enunciá la regla general que ilustra sobre las acciones imperativas en un sistema autorreparable.
- **Q9.2** `startingStep: 2` significa que el análisis comienza después del primer paso de peso. ¿Qué compromiso operativo se está haciendo, y cuándo lo pondrías en `0`?
- **Q9.3** El `AnalysisTemplate` consulta a Prometheus. ¿Qué le pasa al rollout si Prometheus es inalcanzable, y qué campos controlan ese comportamiento?
- **Q9.4** Contrastá el rollback del paso 6 con `kubectl argo rollouts undo`. Ambos restauran 6.7.0 en el clúster — explicá por qué solo uno es un rollback *GitOps* y con qué te deja el otro.
- **Q9.5** Argo Rollouts usa un CRD `Rollout` que reemplaza al `Deployment`; Flagger maneja un `Deployment` estándar desde afuera. Indicá una consecuencia de cada elección para un equipo que ya corre muchos `Deployment`s.

---

## Ejercicio 10 — Observabilidad y diagnóstico del bucle de reconciliación

**Objetivo:** responder "¿por qué mi clúster no es lo que dice Git?" con evidencia, en menos de dos minutos.

### Pasos

1. Inyectá un fallo realista: un manifiesto que es YAML válido pero inválido contra la API.

   ```bash
   cat > apps/dev/broken.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: broken
   spec:
     replicas: "two"
     selector:
       matchLabels:
         app: broken
     template:
       metadata:
         labels:
           app: broken
       spec:
         containers:
           - name: c
             image: busybox:1.36
   EOF
   yq -i '.resources += ["broken.yaml"]' apps/dev/kustomization.yaml
   git add apps/dev && git commit -m "test: broken manifest" && git push
   flux reconcile kustomization flux-system --with-source
   ```

2. Triage de arriba hacia abajo. Primero, *cuál* objeto está no saludable en todo el clúster.

   ```bash
   flux get all -A --status-selector ready=false
   ```

   ```
   NAMESPACE    NAME                            REVISION  SUSPENDED  READY  MESSAGE
   flux-system  kustomization/apps-dev                    False      False  Deployment/podinfo-dev/broken dry-run failed: cannot convert string to int32
   ```

3. Luego las condiciones del objeto, que llevan la razón legible por máquina.

   ```bash
   kubectl -n flux-system get kustomization apps-dev \
     -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
   ```

   ```
   Ready       False   BuildFailed
   Reconciling True    ProgressingWithRetry
   ```

4. Luego los eventos, que llevan el orden.

   ```bash
   kubectl -n flux-system get events --field-selector involvedObject.name=apps-dev \
     --sort-by=.lastTimestamp | tail -5
   ```

5. Luego los logs del controlador, filtrados.

   ```bash
   flux logs --level=error --kind=Kustomization --name=apps-dev --since=10m
   ```

   ```
   2026-08-18T11:31:04.882Z error Kustomization/apps-dev.flux-system - Reconciler error
     Deployment/podinfo-dev/broken dry-run failed: cannot convert string to int32
   ```

6. Confirmá la propiedad crítica: **el estado bueno anterior no fue dañado**.

   ```bash
   kubectl -n podinfo-dev get deploy podinfo
   ```

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo   2/2     2            2           47m
   ```

7. Cableá una alerta para no descubrir esto haciendo polling. (`Provider` + `Alert`, usando un webhook genérico.)

   ```bash
   cat > clusters/dev/notifications.yaml <<'EOF'
   ---
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Provider
   metadata:
     name: on-call
     namespace: flux-system
   spec:
     type: generic
     address: http://alert-sink.monitoring.svc/flux
   ---
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Alert
   metadata:
     name: reconciliation-failures
     namespace: flux-system
   spec:
     providerRef:
       name: on-call
     eventSeverity: error
     eventSources:
       - kind: Kustomization
         name: '*'
       - kind: HelmRelease
         name: '*'
       - kind: ImageUpdateAutomation
         name: '*'
     suspend: false
   EOF
   ```

8. Arreglá hacia adelante y verificá la recuperación.

   ```bash
   git revert --no-edit HEAD
   git add clusters/dev/notifications.yaml && git commit -m "feat: failure alerts" && git push
   flux reconcile kustomization flux-system --with-source
   flux get all -A --status-selector ready=false
   ```

   ```
   ✗ no Flux objects found with ready=false status
   ```

9. Triage equivalente en Argo CD, para comparar.

   ```bash
   argocd app get podinfo-staging --hard-refresh
   argocd app history podinfo-staging
   kubectl -n argocd logs deploy/argocd-application-controller --tail=50 | grep -i error
   ```

### Control de comprensión — Bloque 10

- **Q10.1** El fallo se detectó en el *dry-run*, antes de que se aplicara nada. Nombrá la característica de la API de Kubernetes que lo hace posible y explicá por qué una aplicación parcial sería mucho peor en un sistema GitOps que en uno imperativo.
- **Q10.2** Durante el fallo, `podinfo` siguió corriendo en 2/2. Explicá qué te dice eso sobre la unidad de atomicidad de un `Kustomization` de Flux, y cómo habrías *reducido el radio de explosión* si `broken.yaml` hubiera estado en el mismo directorio que algo crítico.
- **Q10.3** El `Alert` establece `eventSeverity: error`. ¿Qué perdés al no alertar también sobre `info`, y qué ganás?
- **Q10.4** Dá la escalera diagnóstica ordenada usada en los pasos 2–5 (cuatro peldaños), e indicá qué responde cada peldaño que el anterior no puede.
- **Q10.5** Se usó `argocd app get --hard-refresh` en vez de `--refresh` a secas. Indicá la diferencia y nombrá un fallo para el que sirve específicamente.

---

## Limpieza

```bash
kind delete cluster --name gitops
```

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar las respuestas de todos los controles de comprensión</strong></summary>

### Bloque 0

**A0.1** `flux check --pre` valida solo el *destino*: la versión de Kubernetes y la capacidad del cliente de alcanzar el servidor de API. No sabe nada sobre alcanzabilidad del repositorio, credenciales, permisos de la deploy key, existencia de la rama o validez de la ruta. Esos fallos aparecen recién después del bootstrap, como un `GitRepository` cuya condición `Ready` es `False`. El comando que lo cubre es `flux check` (post-instalación) más `flux get sources git`, y para credenciales específicamente, leer la razón `GitOperationFailed` en el estado del `GitRepository`.

**A0.2** Si ambos reconciliadores tienen en propiedad el mismo `Deployment`, obtenés una **guerra de applies**: cada controlador ve la mutación del otro como drift y reescribe el objeto en cada reconciliación. Los síntomas observables son un `metadata.generation` y un `resourceVersion` que suben continuamente sin cambios en Git, tanto `kustomize-controller` como `argocd-controller` apareciendo en `metadata.managedFields` sobre conjuntos de campos solapados, y eventos constantes `Updated`/`SyncPerformed`. En el laboratorio se los mantiene separados por namespace y por directorio: Flux tiene en propiedad `apps/dev` e `infra/dev`, Argo tiene `apps/staging`.

**A0.3** Porque la versión del clúster es parte del estado deseado del sistema, y un `:latest` flotante vuelve al entorno no reproducible: la misma revisión de Git daría un resultado distinto según *cuándo* la corriste. GitOps exige que el estado deseado sea declarativo y versionado; ese requisito no se detiene en el límite de la aplicación. Una imagen de nodo fijada significa que un colega que reproduce tu bug obtiene tu bug.

### Bloque 1

**A1.1** `GitRepository.spec.interval` (1m) es cada cuánto el **source-controller** consulta al remoto, hace fetch y — si la revisión cambió — almacena un nuevo artefacto localmente y actualiza `status.artifact`. `Kustomization.spec.interval` (10m) es cada cuánto el **kustomize-controller** vuelve a renderizar el artefacto que ve actualmente y lo aplica, *sin importar* si la revisión cambió (esto es lo que corrige el drift). El controlador también reacciona ante un artefacto nuevo, pero la cota superior garantizada de la latencia es la suma: hasta 1 minuto para notar el push, más hasta 10 minutos hasta el próximo ciclo de apply — **peor caso ≈ 11 minutos**. El drift sin cambios en Git se corrige dentro de los 10 minutos.

**A1.2** Sin `--with-source`, `flux reconcile kustomization` anota solo el `Kustomization`, forzando un re-apply inmediato del artefacto que el source-controller **ya tiene**. Con `--with-source`, primero anota el `GitRepository` para forzar un fetch inmediato. En el paso 5 no se había pusheado nada — el borrado era drift del lado del clúster — así que el artefacto cacheado ya estaba al día y la forma simple habría restaurado el controlador de todos modos.

**A1.3** El controlador registra un inventario de cada objeto que aplicó en `Kustomization.status.inventory`, como una lista de entradas `id` (`namespace_name_group_kind`) más la versión del recurso. En cada reconciliación renderiza el nuevo conjunto deseado, lo compara contra el inventario almacenado, y borra los objetos presentes en el inventario *viejo* pero ausentes del *nuevo* renderizado. Así que el pruning está guiado por el propio registro de Flux de lo que tuvo en propiedad antes — no por heurísticas de etiquetas ni por nada que el clúster le diga. Los objetos que nunca aplicó nunca son candidatos.

**A1.4** La autorreferencia significa que el plano de control de Flux es a su vez estado deseado reconciliado: alguien que borra un controlador (paso 5) o desvía su configuración recibe una corrección automática, y la versión exacta del controlador en el clúster es auditable desde el historial de Git. Lo que **no** vuelve automático son las *actualizaciones de versión* — `gotk-components.yaml` es un renderizado estático de una release de Flux. Subir la versión de Flux todavía requiere regenerar ese archivo, que es lo que hace `flux bootstrap` (re-ejecutado) o `flux install --export`, seguido de un commit. Automatizar eso es exactamente lo que aborda la instalación basada en `OCIRepository` de `flux-system` o un `flux bootstrap` programado en CI.

### Bloque 2

**A2.1** Los dos son `kustomize.config.k8s.io/v1beta1` (el archivo propio de la **herramienta Kustomize**, `kustomization.yaml`, que describe bases, patches y transformers) y `kustomize.toolkit.fluxcd.io/v1` (el **CRD de Flux**, un objeto de clúster que dice *qué source, qué ruta, cada cuánto, con o sin prune*). El kustomize-controller *ejecuta* el CRD de Flux — es un objeto de Kubernetes reconciliado con estado y condiciones. *Lee* el archivo `kustomize.config.k8s.io` como datos de entrada al renderizar la ruta, exactamente como haría `kubectl kustomize`. Confundirlos es la trampa individual más común del CGOA.

**A2.2** No son redundantes. `wait: true` hace que el controlador se bloquee hasta que **todos** los objetos aplicados reporten readiness (usando las mismas heurísticas de readiness que `kubectl wait`) antes de marcar el `Kustomization` como `Ready`. `healthChecks` restringe la espera a una **lista explícita** de objetos. Poner ambos significa que Flux espera por todo *y* además se aplica la lista — en la práctica `healthChecks` es lo que usás *en lugar de* `wait: true` cuando el conjunto contiene objetos sin readiness significativo (ConfigMaps sueltos, CRDs) o lentos pero irrelevantes. Usá `wait: true` solo, para paquetes chicos y uniformemente chequeables; usá `healthChecks` solo, cuando necesitás que el gating de `dependsOn` dependa de dos o tres cargas de trabajo específicas.

**A2.3** `includeSelectors: true` inyectaría `environment: dev` y `app.kubernetes.io/part-of: cgoa-lab` en `Deployment.spec.selector.matchLabels` **y** en las etiquetas de la plantilla de pod. `spec.selector` en un `Deployment` es **inmutable** después de la creación. El primer apply tendría éxito (creando el Deployment con el selector extendido); un cambio posterior a esas etiquetas, o aplicar la misma base sobre un Deployment existente creado sin ellas, falla con `field is immutable`, y el `Kustomization` queda en `Ready=False` sin salida más que borrar el Deployment. Por eso el transformer moderno `labels:` tiene `includeSelectors: false` por defecto y por eso se desaconseja el viejo campo `commonLabels`.

**A2.4** Vuelve verificable la **trazabilidad / auditabilidad**: cualquier objeto en ejecución puede mapearse de vuelta a una revisión de Git específica, una ruta específica y el reconciliador que lo aplicó — que es la expresión operativa del principio de que el estado deseado es declarativo, versionado y continuamente reconciliado desde una única fuente de verdad. Con `kubectl apply -f` tu evidencia es `kubectl.kubernetes.io/last-applied-configuration` (el *contenido* aplicado, sin autor, sin revisión, sin repositorio) más el historial de shell que el operador haya conservado. Podés ver *qué* está corriendo; no podés probar *por qué* ni *desde dónde*.

### Bloque 3

**A3.1** El mecanismo es **server-side apply (SSA)** con propiedad de campos. El kustomize-controller aplica como field manager `kustomize-controller` con `force: true`, así que tiene en propiedad exactamente los campos presentes en su manifiesto renderizado. `spec.replicas` **está** en el manifiesto → en propiedad → el valor de cualquier otro manager se sobrescribe en el siguiente apply. `spec.template.spec.containers[0].env` **no** está en el manifiesto → no está en propiedad del controlador → SSA deja intactos los campos que pertenecen a otros managers (acá `kubectl-set`, vía una operación `Update`). La regla es: *SSA reconcilia los campos que declarás; no borra campos que nunca mencionaste.* Eso es una virtud — permite que HPAs, webhooks de mutación e inyectores de sidecars coexistan con GitOps.

**A3.2** Porque un objeto vivo de Kubernetes legítimamente lleva campos escritos por controladores que **no** están ni deben estar en Git: un HPA escribe `spec.replicas`, un webhook de service mesh o de vault inyecta contenedores sidecar y volúmenes, `cluster-autoscaler` y los schedulers escriben estado, los controladores de nube escriben `status.loadBalancer.ingress`, y `metadata.finalizers` son agregados por otros operadores. Un reconciliador que quitara todo campo no poseído pelearía con el HPA en cada ciclo (conteos de réplicas oscilantes), borraría sidecars inyectados (rompiendo mTLS) y eliminaría finalizers (causando recursos de nube huérfanos). La propiedad a nivel de campo es lo que hace a GitOps componible con el resto del ecosistema.

**A3.3** Borrar `apps/dev` en Git dejaría el renderizado vacío, así que todo objeto del inventario de `apps-dev` — Deployment, Service, Namespace, Secret — sería **borrado del clúster**. Protecciones, en orden creciente de fuerza: (a) `spec.suspend: true` en el `Kustomization` mientras reestructurás; (b) la anotación `kustomize.toolkit.fluxcd.io/prune: disabled` en objetos individuales que nunca deben borrarse; (c) protección de rama con revisión obligatoria en las rutas que respaldan producción; (d) equivalentes de `--prune=false` más el hecho de que Flux se niega a aplicar un resultado *vacío* si el build falla (un directorio vacío es un error de build, no un inventario vacío — pero un `kustomization.yaml` explícitamente vaciado **sí** es un renderizado vacío válido y va a podar). Las protecciones equivalentes en Argo CD son `allowEmpty: false` y la opción de sync `Prune=false`.

**A3.4** *Detección* es comparar el estado vivo contra el estado deseado y reportar el delta. *Corrección* es escribir el estado deseado de vuelta. Querés solo detección donde se requiere una decisión humana antes de que el cambio tome efecto: un **entorno de producción regulado con ventanas de control de cambios** (el delta debe quedar registrado y aprobado antes de cerrarse), un **clúster en respuesta a un incidente** donde un ingeniero de guardia escaló o parcheó algo deliberadamente y el auto-revert volvería a romper la caída, y cualquier **migración** donde el clúster está intencionalmente por delante de Git. Flux expresa esto con `spec.suspend: true` más alertas; Argo CD con `syncPolicy.automated` omitido (sync manual) — en ambos casos la señal `OutOfSync`/drift sigue disparándose.

### Bloque 4

**A4.1** Con `selfHeal: true, prune: false`: el recurso **editado** en el clúster se revierte automáticamente al estado de Git (eso es `selfHeal` — dispara una sincronización cuando el estado vivo diverge sin un cambio en Git). El recurso **borrado de Git** *no* se elimina del clúster; en cambio, la `Application` reporta `OutOfSync` con ese recurso marcado como `Prune` / `RequiresPruning`, y sigue corriendo indefinidamente hasta que alguien ejecute `argocd app sync --prune` o cambie la flag. El resultado es un clúster que acumula huérfanos en silencio mientras afirma autorrepararse — por eso `prune: false` siempre debería ir acompañado de alertas sobre `OutOfSync`.

**A4.2** `argocd app resources` lee el estado **cacheado** de la aplicación desde la última reconciliación del application controller. `argocd app diff` (sin flags) también usa el estado vivo cacheado, pero puede ir por delante del estado agregado mostrado porque el campo de estado del controlador se escribe al final de un ciclo de reconciliación. Entre el `kubectl scale` manual y la siguiente reconciliación (por defecto ~3 min de resync de la app, o inmediatamente ante un evento de watch), el agregado cacheado todavía puede leer `Synced` mientras el diff contra el estado vivo recién leído muestra 7 vs 3. `argocd app get --refresh` fuerza una re-comparación; `--hard-refresh` además descarta el caché de generación de manifiestos. La autorreparación cerró la brecha en el paso 7.

**A4.3** **Con** el finalizer, borrar la `Application` realiza un **borrado en cascada**: Argo CD elimina del clúster cada recurso del inventario de la app antes de permitir que se elimine el propio objeto `Application`. **Sin** él, solo desaparece el objeto `Application` y las cargas de trabajo siguen corriendo, ahora sin gestión y huérfanas. Es una decisión de política porque las dos respuestas a "¿qué significa borrar la definición de la app?" son ambas legítimas: para entornos de preview efímeros querés que todo se esfume; para una base de datos de producción compartida decididamente no querés que un typo de `kubectl delete app` te tumbe el StatefulSet. Elegí por `Application`, y acompañá la opción destructiva con RBAC sobre el delete de `applications`.

**A4.4** Perdido: (1) **versionado y auditabilidad** — no hay registro en Git de qué versión de Argo CD está instalada, `stable` es un tag móvil, y no podés diffear ni revertir la instalación; (2) **reconciliación continua / autorreparación** — nada corrige el drift en los propios Deployments, ConfigMaps o RBAC de Argo CD, así que una edición manual a `argocd-cm` persiste de forma invisible. Para arreglarlo, usá el patrón **app-of-apps / autogestión**: commiteá en Git una instalación de Argo CD fijada (overlay de Kustomize sobre un tag de release específico, o un `HelmRelease`/`Application` con source Helm fijada a una versión de chart), y creá una `Application` llamada por ejemplo `argocd` cuyo source sea esa ruta y cuyo destino sea el namespace `argocd`. Argo CD entonces se reconcilia a sí mismo. El paso de bootstrap restante — el primer apply que crea esa `Application` — es irreducible y es el mismo huevo-y-gallina que resuelve `flux bootstrap`.

**A4.5** `ApplyOutOfSyncOnly=true` hace que una sincronización envíe solo los recursos que el diff marcó como fuera de sync, en vez de reaplicar todo el conjunto de manifiestos. Resuelve la **carga sobre el servidor de API y la duración de la sincronización** en aplicaciones grandes (cientos de recursos), y reduce eventos `Update` espurios y la rotación de resourceVersion. `ServerSideApply=true` cambia el client-side apply (que mete el manifiesto entero dentro de la anotación `last-applied-configuration`) por SSA. Resuelve dos cosas: el **límite de 262 KB de tamaño de anotación** que rompe con CRDs grandes, y los **conflictos de propiedad de campos** con otros controladores — el mismo mecanismo analizado en A3.1, haciendo que el comportamiento de Argo coincida con la semántica de coexistencia de Flux.

### Bloque 5

**A5.1** Dentro de una wave, Argo CD aplica los recursos en un **orden fijo por kind** derivado de la convención de orden de Helm/`kubectl apply`: Namespaces, ResourceQuotas, NetworkPolicies, LimitRanges, PodSecurityPolicies, ServiceAccounts, Secrets, ConfigMaps, StorageClasses, PVs, PVCs, CustomResourceDefinitions, ClusterRoles/Bindings, Roles/Bindings, Services, luego cargas de trabajo (DaemonSet, Pod, ReplicaSet, Deployment, StatefulSet, Job, CronJob), luego Ingress/APIService. Los empates se rompen alfabéticamente por nombre. Ese orden incorporado ya maneja las dependencias estructurales comunes (el namespace antes que todo lo que va adentro, el CRD antes que su CR, el Secret antes que el Pod que lo monta), así que las waves solo hacen falta para las dependencias **semánticas** que el orden no puede inferir — "la base de datos debe migrarse antes de la versión de la app que espera el nuevo esquema", "el `ClusterIssuer` de cert-manager debe estar listo antes que el `Certificate`".

**A5.2** (1) **Ciclo de vida relativo a la sincronización, no al conjunto de recursos**: un hook `PreSync` corre *antes de cualquier* wave, y la sincronización **falla y se detiene** si el Job del hook falla — no se aplica nada más. Un Job en wave `-2` es solo un objeto; Argo lo aplica y sigue adelante cuando queda *creado*, no cuando *tiene éxito* (salvo que además agregues evaluación de salud), y un Job fallido deja una release aplicada a medias. (2) **Recolección automática de basura** vía `hook-delete-policy` (`HookSucceeded`, `HookFailed`, `BeforeHookCreation`) — los hooks no forman parte del inventario de la app, así que volver a correr la sincronización los recrea limpiamente, mientras que un Job común con nombre fijo falla al reaplicarse en la segunda sincronización porque `spec.template` es inmutable. También vale notar: los hooks `PostSync` y `SyncFail` no tienen equivalente alguno en waves.

**A5.3** `dependsOn` acota **unidades de reconciliación completas** a través de sources, namespaces e incluso rutas de Git distintas: "no apliques *nada* en `apps-dev` hasta que *todos* los objetos de `infra-dev` estén Ready". Una `sync-wave` no puede cruzar límites de `Application` — solo ordena dentro del conjunto de recursos de una app — así que el secuenciamiento a nivel de clúster (CRDs y operadores de un repo antes que las cargas de trabajo de otro) necesita `dependsOn` (o las waves propias de Argo en el patrón app-of-apps sobre los objetos `Application` padres). A la inversa, `sync-wave` puede expresar **orden de grano fino dentro de una única unidad** — ConfigMap en `-1`, Deployment en `1`, Ingress en `2`, todos en el mismo directorio — algo que `dependsOn` no puede hacer sin partir el directorio en objetos `Kustomization` separados, cada uno con su propio intervalo, estado e inventario.

**A5.4** `dependsOn` espera a que la condición `Ready` de la dependencia sea `True`. Sin `wait: true` (y sin `healthChecks`), un `Kustomization` reporta `Ready=True` apenas sus objetos fueron **aplicados exitosamente al servidor de API** — no cuando están corriendo. Así que `infra-dev` pasaría a Ready en el instante en que los CRDs y el Deployment del operador quedaran *creados*, y `apps-dev` aplicaría de inmediato custom resources cuyo controlador no arrancó y cuyos CRDs quizás todavía no están establecidos. Obtendrías errores intermitentes de `no matches for kind` que desaparecen al reintentar — el síntoma clásico. `wait: true` (o una lista explícita de `healthChecks`) es lo que convierte "aplicado" en "realmente usable", que es el único significado de "depende de" que sirve.

### Bloque 6

**A6.1** El **`HelmRelease` de Flux** conserva un registro de release de Helm real — el helm-controller usa el SDK de Helm y escribe el Secret estándar de release (`sh.helm.release.v1.<name>.v<N>`, de tipo `helm.sh/release.v1`) en el namespace destino. Argo CD por defecto ejecuta `helm template` y aplica la salida, así que **no** hay registro de release de Helm. Lo que habilita el registro: semántica de `helm history` / `helm rollback`, instalación/actualización atómica con rollback automático ante fallo (`upgrade.remediation.remediateLastFailure`, `cleanupOnFail`), ejecución correcta de los **hooks** del chart (`pre-install`, `post-upgrade`), y `helm test`. Lo que gana a cambio el enfoque de Argo: la salida renderizada es totalmente visible para el motor de diff de Argo y para `argocd app manifests`, así que el drift y el diff son por objeto en vez de por release, y no hay un segundo almacén de estado que se pueda perder.

**A6.2** `6.7.x` es un **rango**: el source-controller lo vuelve a resolver en cada `chart.spec.interval` y va a actualizar silenciosamente la release cuando se publique `6.7.2`. La revisión que corre en el clúster entonces no está determinada por la revisión de Git — dos clústeres en el mismo commit pueden correr versiones de chart distintas, y revertir el commit no revierte el chart. Eso rompe *declarativo + versionado + inmutable*. Es defendible cuando (a) el rango es estrecho y se confía en la disciplina de semver del chart, (b) está confinado a no-producción donde la captura rápida de parches vale más que la reproducibilidad, y (c) va acompañado de alertas sobre cambios de revisión del `HelmRelease` para que la actualización al menos sea *observada*. En producción, fijá exacto — y usá automatización de actualización de imagen/chart (Ejercicio 8) para que el salto llegue como un **commit** revisable, lo que te da frescura y reproducibilidad a la vez.

**A6.3** Resuelve el problema de **"chart de upstream, values locales"**: el chart pertenece a un tercero y está versionado en su repositorio, mientras que los values específicos del entorno son tuyos y pertenecen a tu repo Git bajo revisión. `ref: values` nombra el segundo source para que `$values/...` pueda resolver una ruta de `valueFiles` dentro de él, permitiendo que una sola `Application` combine un chart upstream sin modificar con tu configuración versionada. Forkear el chart dentro de tu repo es peor porque heredás el mantenimiento de todo el árbol de plantillas: cada release de upstream debe fusionarse a mano, las correcciones de seguridad se atrasan, y tu diff contra upstream crece hasta que el fork es efectivamente un chart nuevo. Mantener el chart externo y los values internos deja el límite en el lugar correcto — versionás tu *intención*, no la implementación de otros.

**A6.4** Porque para una release de Helm, "drift" es ambiguo y corregirlo es caro. La comparación normal del helm-controller es entre el **chart+values deseados y el último registro de release**, no entre la release y el estado vivo del clúster — así que con la detección de drift apagada, una actualización solo ocurre cuando cambian la versión del chart o los values. Encenderla hace que el controlador además renderice la release y la compare contra los objetos vivos en cada intervalo, lo que cuesta CPU y llamadas a la API proporcionales al tamaño de la release y — críticamente — puede entrar en conflicto con charts que legítimamente esperan mutaciones después de la instalación (campos inyectados por webhooks, charts cuyos propios hooks parchean recursos, plantillas basadas en `lookup` que no son determinísticas). Los Kustomizations comunes no tienen nada de esa ambigüedad: el manifiesto renderizado *es* el estado deseado, y la propiedad de campos de SSA ya acota la corrección de forma segura, así que puede venir encendido por defecto. Si la activás, `driftDetection.ignore` con punteros JSON es la vía de escape para los campos que pertenecen a otros controladores.

### Bloque 7

**A7.1** Dejar `apiVersion`, `kind`, `metadata` y `type` en claro es lo que permite que **Kustomize (y Flux, y la revisión de código) traten el archivo como un manifiesto**: los overlays pueden parchearlo, los transformers `namePrefix`/`namespace` se le aplican, el inventario de Flux puede rastrearlo, y quien revisa puede ver *que* se está agregando un Secret llamado `podinfo-credentials` a `podinfo-dev` y razonar sobre el radio de explosión sin descifrar nada. Si todo el archivo fuera opaco, sería un blob imparseable — sin patching, sin diffing, sin revisión estructural, y un renombre sería indistinguible de una rotación. La fuga aceptada es la **metadata**: la existencia, el nombre, el namespace, el tipo y los *nombres de claves* de cada secreto son públicos en el repositorio. Esa es una fuga real (mapea tu inventario de credenciales) y es la razón por la que el repo igual no debería ser legible por todo el mundo.

**A7.2** **SOPS-en-Git:** la fuente de verdad del *texto cifrado* es Git; la fuente de verdad del *texto plano* es Git más la clave privada. Una reconstrucción completa del clúster solo a partir de Git **no** es suficiente — primero hay que restaurar la clave privada de age/KMS en el clúster nuevo, tras lo cual todo lo demás se deriva del repositorio. **External Secrets Operator + Vault:** Git guarda solo un `ExternalSecret` — un *puntero* (qué ruta de Vault, qué claves, qué nombre de Secret destino). La fuente de verdad del valor es Vault. Una reconstrucción solo desde Git requiere un **Vault vivo, alcanzable y poblado** y autenticación/identidad de carga de trabajo funcionando para el clúster nuevo; el repositorio por sí solo no reconstruye nada. Compromiso: SOPS conserva la propiedad de bucle cerrado "Git es la fuente de verdad" y funciona sin conexión, pero rotar implica un commit y el historial de texto cifrado es permanente; ESO da rotación central, credenciales dinámicas/de vida corta y auditoría real, al costo de una dependencia dura en tiempo de ejecución fuera del bucle de Git.

**A7.3** El alcance por defecto de Sealed Secrets (`strict`) ata el texto cifrado **tanto** al namespace como al nombre del Secret destino. Esto previene una **escalada de privilegios por copiar y pegar**: una persona desarrolladora con acceso de escritura al namespace `team-b` no puede copiar la credencial sellada de la base de datos de producción desde los manifiestos de `prod/` a su propio namespace y hacer que el controlador se la descifre — el controlador se niega porque la metadata de sellado no coincide. El costo es que un manifiesto **no es portable entre entornos**: promover `staging/db-secret.yaml` a `prod/` requiere **volver a sellar** el valor contra el nombre y namespace de producción, lo que significa que el texto plano debe estar disponible para quien haga la promoción. Las vías de escape son el alcance `namespace-wide` (portable dentro de un namespace, aún aislado entre namespaces) y el alcance `cluster-wide` (totalmente portable, y descarta exactamente la protección descrita arriba — usalo solo para valores genuinamente no sensibles por namespace).

**A7.4** La consecuencia es que el Secret `sops-age` del **clúster es ahora la única copia de la clave de descifrado**. Si se pierde el clúster, todo archivo cifrado en Git queda permanentemente ilegible — el repositorio está intacto y es completamente inútil, y no hay ruta de recuperación porque age no tiene depósito de claves (key escrow). La política mínima segura: guardar la clave privada en al menos **dos ubicaciones independientes, durables y con control de acceso fuera del clúster** (un gestor de contraseñas o un HSM/respaldo en papel offline, más un almacén de secretos a nivel organización), documentar quién puede recuperarla, y **probar la restauración** descifrando un archivo conocido desde una máquina limpia. Mejor aún, usar `creation_rules` de `.sops.yaml` con **múltiples destinatarios** — una clave de KMS en la nube (AWS KMS / GCP KMS / Azure Key Vault, que aporta IAM, rotación y auditoría) junto a una o más claves age de emergencia — para que perder a cualquier custodio individual sea sobrevivible y revocar a un destinatario sea un commit de recifrado en vez de una catástrofe.

### Bloque 8

**A8.1** Nada. `semver: {range: 6.7.x}` equivale a `>=6.7.0 <6.8.0`, así que `6.8.0` está **fuera del rango** y la `ImagePolicy` va a seguir resolviendo al `6.7.z` más nuevo. Eso es lo deseado porque un salto **menor** puede traer cambios de comportamiento, nueva configuración obligatoria o defaults modificados — cosas que debería revisar una persona en un pull request, no aplicarse automáticamente a las 03:00. El trabajo de la automatización es hacer que la clase *segura* de actualizaciones (releases de parche: correcciones de bugs y CVEs dentro de un contrato estable) sea sin fricción, para que la clase *insegura* reciba la escasa atención humana. Pasar a 6.8 es entonces un commit deliberado de una línea que cambia el rango, y eso mismo es revisable y revertible. Para flujos de pre-release/CI la disciplina equivalente es una regex `filterTags` más ordenamiento `numerical` sobre una marca temporal de build, nunca un "último tag" sin filtrar.

**A8.2** El image-automation-controller resuelve el tag nuevo, reescribe el campo marcado y pushea un commit a la rama **`flux-image-updates`**. Como el `GitRepository` rastrea `main`, nada cambia en el clúster. Se abre un pull request de `flux-image-updates` → `main` (porque el push del controlador dispara una automatización del proveedor, o por un job programado); CI corre contra él; una **persona revisa y fusiona**. Solo el merge a `main` cambia lo que el source-controller obtiene, y el clúster converge en el siguiente intervalo. El punto de control humano es la **aprobación/merge del PR**, y es el único — que es precisamente por qué la protección de rama sobre `main` (revisiones obligatorias, status checks obligatorios, sin force-push) es un control de seguridad *del clúster* en GitOps, no apenas una configuración de higiene de código.

**A8.3** (1) **Auditabilidad y reproducibilidad** — con `kubectl set image` la imagen en ejecución no está en ningún lado de Git, así que el repositorio deja de describir al clúster, y una reconstrucción desde Git resucita la imagen vieja. (2) **Rollback** — revertir es un `git revert` en el modelo GitOps versus "acordate cuál era el tag anterior y corré otro comando imperativo" en el modelo de CI. (3) **Radio de explosión de credenciales** — el sistema de CI necesita credenciales de escritura sobre el *servidor de API de Kubernetes*, permanentemente, desde fuera del límite de confianza; en el modelo pull CI solo necesita pushear a un registro de contenedores, y nada fuera del clúster tiene jamás cluster-admin. Pérdidas secundarias: sin corrección de drift (la siguiente reconciliación revertiría el `kubectl set image` de todos modos, provocando una pelea), y sin compuerta de revisión.

**A8.4** (1) **Límites de tasa del registro / costo**: `ImageRepository` lista *todos* los tags en cada escaneo. Contra los límites anónimos de Docker Hub o un registro pago con facturación por request, un intervalo de 5 minutos sobre muchos repositorios sale caro. Mitigá alargando el `interval` (30m–1h suele alcanzar de sobra, dado que el PR lo revisa una persona igual), acotando con `exclusionList`/`filterTags` en la `ImagePolicy`, y — donde esté soportado — usando un webhook del registro más `flux reconcile image repository` en vez de polling. (2) **Credenciales para registros privados**: el controlador necesita autenticación con nivel de pull, configurada vía `spec.secretRef` apuntando a un Secret `kubernetes.io/dockerconfigjson`, vía `spec.serviceAccountName` con un imagePullSecret adjunto, o vía `spec.provider: aws|azure|gcp` para identidad de carga de trabajo en la nube (que evita almacenar credenciales estáticas del todo — la opción preferida). Notá que la automatización *también* necesita credenciales de **escritura en Git**, lo cual es una tercera preocupación separada: la deploy key del bootstrap debe habilitar escritura (`--read-write-key`) o hay que proveer un `secretRef` dedicado.

**A8.5** El marcador pertenece a la **base** porque la base es el único lugar donde la imagen se *declara*; los overlays solo parchean otros campos. `strategy: Setters` reescribe el valor en la ubicación marcada del archivo en disco, y el `update.path` (`./apps/base/podinfo`) acota qué archivos puede tocar el controlador. Si ambos overlays llevaran su propia línea `image:` marcada referenciando la misma `ImagePolicy`, cada overlay sería actualizado al mismo tag simultáneamente — lo que **destruye la capacidad de promover entre entornos**: staging y producción serían siempre idénticos, y no habría ninguna ventana en la que staging corra una versión que producción no. El patrón multi-entorno correcto es *políticas distintas por entorno* (por ejemplo una política `podinfo-staging` sobre un rango amplio y una `podinfo-prod` sobre uno estrecho, avanzado manualmente), cada una con su propio `ImageUpdateAutomation` acotado a la ruta de ese entorno — o, más comúnmente, automatización solo en staging y un PR de promoción escrito por una persona hacia producción.

### Bloque 9

**A9.1** `kubectl argo rollouts abort` establece campos `spec.pause`/de estado **en el objeto `Rollout` vivo** — es una mutación imperativa de un campo que el `Kustomization` de Flux renderiza desde Git. En la siguiente reconciliación, server-side apply restauró el objeto al estado declarado en Git (sin abort), y el controlador de Rollouts retomó el canary desde donde la spec decía que debía estar. La regla general: **en un sistema continuamente reconciliado, cualquier cambio imperativo a un campo que Git declara tiene una vida útil acotada por el intervalo de reconciliación.** Los comandos imperativos son herramientas de diagnóstico, no mecanismos de control. Las formas compatibles con GitOps de detener un rollout son suspender el reconciliador (`flux suspend kustomization canary-dev`) y luego actuar, o — correctamente — cambiar Git.

**A9.2** `startingStep: 2` significa que la corrida de análisis arranca recién cuando el rollout alcanza el índice de paso 2 (`setWeight: 50`), así que el primer paso del 20% transcurre **sin medición**. El compromiso es **calidad de señal versus exposición**: al 20% de peso sobre 4 réplicas el canary recibe muy poco tráfico como para que una consulta de tasa de éxito basada en rate sea estadísticamente significativa dentro de una ventana de 30 segundos — la métrica sería ruidosa y abortaría por nada. Esperar hasta el 50% compra un denominador utilizable a costa de exponer a más usuarios antes del primer veredicto automático. Ponelo en `0` cuando el canary recibe suficiente tráfico de inmediato (alto volumen de requests, o un servicio donde una ventana de 1 minuto al 20% igual arroja miles de requests) o cuando la métrica no es basada en rate — una sonda sintética, una métrica de un `Job` de smoke-test o un umbral de *conteo* de errores funciona bien con poco peso y debería gobernar el primerísimo paso.

**A9.3** Un error del proveedor **no** se trata como un éxito. El resultado de la métrica se registra como `Error`, lo que cuenta contra presupuestos adyacentes a `failureLimit` — específicamente, los errores consecutivos se gobiernan con `consecutiveErrorLimit` (por defecto 4); superarlo hace fallar el `AnalysisRun`, y un análisis fallido **aborta el rollout** y escala el canary a cero, dejando a la versión estable sirviendo. Los campos que controlan esto son `consecutiveErrorLimit` (cuántos errores de proveedor/transporte se toleran seguidos), `failureLimit` (cuántas mediciones pueden violar `successCondition`), `inconclusiveLimit` con una `inconclusiveCondition` explícita (para veredictos de "no se puede determinar", que pausan para decisión humana en vez de abortar), más `interval`/`count` que fijan el muestreo. El punto de diseño importante: **la telemetría no disponible falla en cerrado**, porque un canary que no podés medir es un canary que no podés aprobar — pero tenés que fijar `consecutiveErrorLimit` deliberadamente, o un reinicio breve de Prometheus abortará rollouts legítimos.

**A9.4** `git revert` cambia el **estado deseado**, así que el clúster converge a 6.7.0 *y se queda ahí*: el repositorio y el clúster coinciden, el rollback queda registrado como un commit revisable y atribuible, un clúster reconstruido reproduce el estado revertido, y cualquier otro clúster que rastree la misma rama también revierte. `kubectl argo rollouts undo` muta solo el `Rollout` vivo. Git sigue diciendo 6.7.1, así que ahora tenés **drift deliberado e invisible**: la siguiente reconciliación (o el siguiente commit no relacionado que toque esa ruta) reaplica 6.7.1 y redespliega silenciosamente la versión mala — la caída vuelve, sin causa obvia. Solo el primero es un rollback GitOps; el segundo es una anulación local temporal que hay que seguir de inmediato con un commit, y es la forma clásica en que un arreglo de las 2 de la mañana reaparece como un incidente de las 9.

**A9.5** **Argo Rollouts (el CRD `Rollout` reemplaza al `Deployment`)**: tenés que *migrar* cada carga de trabajo — cambiar el `kind`, ajustar todo lo que referencie al Deployment (el `scaleTargetRef` del HPA, algunos dashboards, la memoria muscular de kubectl, políticas de admisión y herramientas que se basan en `apps/v1 Deployment`) — y los charts de Helm de terceros que codifican `Deployment` a mano no pueden usarse sin modificación. A cambio obtenés el DSL completo de pasos (pesos, pausas, experimentos, blue-green con servicios de preview) como spec de primera clase y versionada, más una CLI/UI hecha a medida. **Flagger (maneja un `Deployment` estándar)**: conservás tus manifiestos y charts de `Deployment` existentes sin tocar — Flagger crea un Deployment primario en sombra y manipula Services/enrutamiento de la malla desde afuera — así que la adopción es incremental y reversible. El costo es un modelo más indirecto (dos Deployments por app, el original se escala a cero y queda *en propiedad* de Flagger, lo que sorprende a quien lee `kubectl get deploy`), una dependencia dura de un proveedor de tráfico soportado (Istio, Linkerd, NGINX, Gateway API, App Mesh…), y menos control expresivo de los pasos. Un equipo con un parque grande de `Deployment`s existentes y una service mesh suele encontrar a Flagger más barato de adoptar; un equipo que se estandariza en Argo CD y quiere el estado del rollout visible en la misma UI suele elegir Rollouts.

### Bloque 10

**A10.1** La característica es el **dry-run** del servidor de API (`kubectl apply --server-dry-run` / `?dryRun=All`), que ejecuta toda la cadena de admisión — decodificación, validación de esquema, webhooks de mutación y validación, chequeos de cuota — y devuelve el resultado **sin persistir nada en etcd**. Flux corre un dry-run server-side de todo el conjunto renderizado antes de aplicarlo. La aplicación parcial es mucho peor bajo GitOps que bajo operación imperativa porque el sistema es un **bucle, no un comando**: un `kubectl apply` imperativo que falla a medias deja un desastre que hay una persona parada ahí mismo para ver y limpiar. Un reconciliador que aplica a medias va a reintentar la misma aplicación parcial en cada intervalo, para siempre, produciendo un clúster que está permanentemente en un estado descrito por ninguna revisión de Git — ni la vieja ni la nueva — mientras el reconciliador emite un error que nadie está mirando. El todo-o-nada atómico preserva el invariante de que el clúster siempre coincide con *algún* commit.

**A10.2** La unidad de atomicidad de un `Kustomization` de Flux es la **ruta renderizada entera**: construye, hace dry-run y aplica como una sola transacción, y un fallo en cualquier lado aborta todo el apply — por eso `broken.yaml` impidió que aterrizara *cualquier* cambio de `apps/dev`, mientras que los objetos previamente aplicados quedaron corriendo intactos. Esa es la buena noticia (nada se dañó) y la mala (un solo manifiesto roto **bloquea todos los demás cambios de ese directorio**, incluido un arreglo urgente). Para reducir el radio de explosión, **partí la ruta en múltiples objetos `Kustomization`** con inventarios separados — por ejemplo `apps-dev-critical` para el servicio de pagos y `apps-dev-experimental` para todo lo demás — opcionalmente enlazados con `dependsOn`. Cada uno falla entonces de forma independiente. El principio general: el límite del `Kustomization` *es* tu límite de aislamiento de fallos, así que trazalo alrededor de cosas que deban fallar juntas.

**A10.3** Al alertar solo sobre `error` perdés la **señal positiva**: reconciliaciones exitosas, nuevas revisiones aplicadas, automatizaciones de imagen commiteadas, HelmReleases actualizados. Ese flujo es lo que alimenta las métricas de frecuencia de despliegue y lead time, lo que te permite correlacionar "el gráfico cambió de forma a las 14:02" con "la revisión `a3d47e1` se aplicó a las 14:01", y lo que te dice que un reconciliador está *vivo* y no meramente no-fallando — un controlador suspendido o en crash-loop no emite errores en absoluto. Lo que ganás es una **relación señal-ruido que una persona puede realmente sostener**: con `info`, un clúster con una docena de `Kustomization`s reconciliando cada 10 minutos genera un flujo constante, y el único fallo real se pierde adentro. La respuesta de producción son **dos objetos `Alert` con `providerRef`s distintos**: `error` (y `inclusionList` para objetos críticos específicos) al pager de guardia, e `info` a un canal de chat de baja prioridad o a un sumidero de eventos que alimente dashboards. La severidad es una decisión de enrutamiento, no de filtrado.

**A10.4** La escalera, y lo que responde de forma única cada peldaño:

1. `flux get all -A --status-selector ready=false` — **¿qué objeto está roto?** Acota todo el clúster a los reconciliadores que fallan en un solo comando. No puede decirte *por qué* más allá de un mensaje truncado.
2. `kubectl get <kind> <name> -o jsonpath='{.status.conditions...}'` — **¿cuál es el estado legible por máquina ahora mismo?** Da la `reason` (`BuildFailed`, `HealthCheckFailed`, `ArtifactFailed`, `ReconciliationSucceeded`) y si hay un reintento en curso (`Reconciling`/`Stalled`). Las condiciones son una *instantánea* — no pueden decirte qué pasó antes del intento actual.
3. `kubectl get events --field-selector involvedObject.name=...` — **¿cuál es la secuencia?** El orden, los conteos de repetición y las marcas temporales de primera/última vez distinguen "falló una vez y se recuperó" de "falla en cada intervalo desde hace seis horas". Los eventos están truncados y expiran (retención de 1h por defecto), y no llevan detalle interno del controlador.
4. `flux logs --level=error --kind=... --name=...` — **¿qué hizo realmente el controlador?** Cadenas de error completas, contexto de stack, el error exacto de renderizado o de la API. Este es el único peldaño que ve dentro del controlador, y el único que sobrevive a la expiración de eventos (si los logs se envían a algún lado).

La disciplina es ir **de arriba hacia abajo y parar apenas tenés la respuesta** — la mayoría de los fallos quedan completamente explicados en el peldaño 1 o 2, y saltar directo a los logs en un clúster grande es cómo un triage de dos minutos se vuelve de veinte.

**A10.5** `--refresh` fuerza al application controller a **volver a comparar** el estado deseado contra el vivo: relee el estado vivo del clúster y vuelve a correr el diff, pero puede reutilizar los **manifiestos renderizados cacheados** para la revisión actual de Git. `--hard-refresh` además **invalida el caché de generación de manifiestos** y vuelve a correr el renderizado del repo-server (`kustomize build` / `helm template`) desde cero. Es específicamente para fallos donde el *renderizado* está viejo o equivocado mientras la revisión de Git parece sin cambios: una **referencia upstream mutable** — un chart de Helm republicado bajo la misma versión, un `targetRevision` apuntando a un tag o rama móvil sobre el que se hizo force-push, una base remota de Kustomize obtenida por HTTP, o una dependencia de chart resuelta desde un índice de repositorio que desde entonces cambió. Síntoma: `argocd app get` insiste en que la app está `Synced` en la revisión X mientras los manifiestos que aplicaría son demostrablemente distintos de lo que esa revisión produce hoy. El `--refresh` a secas va a rediffear alegremente contra el mismo renderizado viejo y va a reportar que todo está bien.

</details>

---

## Fuentes oficiales

- CNCF GitOps Certified Associate (CGOA) curriculum — https://github.com/cncf/curriculum/blob/master/cgoa/README.md
- OpenGitOps Principles v1.0.0 — https://opengitops.dev/ · https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
- Flux CD documentation — https://fluxcd.io/flux/
  - Bootstrap — https://fluxcd.io/flux/installation/bootstrap/
  - `Kustomization` API — https://fluxcd.io/flux/components/kustomize/kustomizations/
  - `GitRepository` API — https://fluxcd.io/flux/components/source/gitrepositories/
  - `HelmRelease` API — https://fluxcd.io/flux/components/helm/helmreleases/
  - Image update automation — https://fluxcd.io/flux/guides/image-update/
  - SOPS secrets management — https://fluxcd.io/flux/guides/mozilla-sops/
  - Notifications / `Alert` & `Provider` — https://fluxcd.io/flux/components/notification/
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
  - `Application` specification — https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/
  - Automated sync policy — https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
  - Sync waves and resource hooks — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
  - Sync options (`ServerSideApply`, `ApplyOutOfSyncOnly`) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
  - Multiple sources for an Application — https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/
  - App of Apps pattern — https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Argo Rollouts documentation — https://argo-rollouts.readthedocs.io/en/stable/
  - Canary strategy — https://argo-rollouts.readthedocs.io/en/stable/features/canary/
  - Analysis and progressive delivery — https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Flagger documentation — https://docs.flagger.app/
- Kustomize reference — https://kubectl.docs.kubernetes.io/references/kustomize/
- Kubernetes Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Helm documentation — https://helm.sh/docs/
- SOPS — https://getsops.io/docs/ · age — https://github.com/FiloSottile/age
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator — https://external-secrets.io/latest/