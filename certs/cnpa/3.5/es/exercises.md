# Tema 3.5 — CI/CD Relationship Fundamentals and Integration

## Ejercicios guiados

> **Nivel:** producción / platform engineering. **Duración estimada:** 90–120 min.
> **Modelo mental que vamos a construir:** CI y CD **no son un solo pipeline**, son dos dominios con responsabilidades, dueños y modelos de ejecución distintos que se comunican **a través de un contrato inmutable** (la imagen OCI referenciada por *digest*) y **a través de Git** (el estado deseado declarativo). Todo el ejercicio consiste en materializar esa frontera y luego integrarla correctamente.

---

### Prerrequisitos y preparación del entorno

Necesitás un host Linux/macOS con Docker (o Podman), `kubectl`, y conexión saliente. Vamos a usar **kind** para el cluster, **ttl.sh** como registry efímero anónimo (no requiere login), **Argo CD** como motor de CD *pull-based*, **cosign** para supply chain y **Kyverno** como *admission gate*.

**Pasos:**

1. Verificá las herramientas base y su versión:

   ```bash
   docker version --format '{{.Server.Version}}'
   kubectl version --client -o yaml | grep gitVersion
   kind version
   ```

   Salida esperada (aproximada):

   ```
   27.3.1
       gitVersion: v1.31.0
   kind v0.24.0 go1.22.6 linux/amd64
   ```

2. Instalá los CLIs que faltan (`kind`, `argocd`, `cosign`, `crane`):

   ```bash
   go install sigs.k8s.io/kind@v0.24.0            # o descarga del release
   brew install argocd cosign crane               # en Linux: baja los binarios de cada release
   ```

3. Creá un cluster local de un nodo:

   ```bash
   kind create cluster --name cnpa-cicd
   kubectl cluster-info --context kind-cnpa-cicd
   ```

   Salida esperada:

   ```
   Kubernetes control plane is running at https://127.0.0.1:XXXXX
   CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
   ```

4. Preparate un directorio de trabajo:

   ```bash
   mkdir -p ~/cnpa-3.5/{app,gitops} && cd ~/cnpa-3.5
   ```

**Preguntas de comprensión (Bloque 0):**

- **P0.1** — ¿Por qué usamos un registry (ttl.sh) y no cargamos la imagen directo al cluster con `kind load`? ¿Qué principio de la relación CI/CD se rompería si el CD leyera la imagen del disco del runner de CI en lugar de un registry?
- **P0.2** — En este lab, ¿qué rol cumple `kind` respecto de la separación de dominios: es parte de "CI", de "CD", o de la *plataforma* sobre la que corre el CD?

---

### Ejercicio 1 — La frontera entre CI y CD: el artefacto inmutable como contrato

**Objetivo:** entender qué produce CI (build + test + package + publish) y por qué el **digest** —no el tag— es el contrato que CD debe consumir.

**Pasos:**

1. Creá una aplicación trivial en `app/`:

   ```bash
   cat > app/index.html <<'EOF'
   <h1>CNPA 3.5 — build v1</h1>
   EOF

   cat > app/Dockerfile <<'EOF'
   FROM nginx:1.27-alpine
   COPY index.html /usr/share/nginx/html/index.html
   EOF
   ```

2. **Fase CI (imperativa, efímera):** build + push a un registry. Simulamos el runner con tu shell. Usamos `ttl.sh` con TTL de 1 h:

   ```bash
   export IMG=ttl.sh/cnpa-3-5-$(id -u):1h
   docker build -t "$IMG" app/
   docker push "$IMG"
   ```

   Salida (fijate en la última línea):

   ```
   The push refers to repository [ttl.sh/cnpa-3-5-1000]
   1h: digest: sha256:9f2c...e41a size: 1985
   ```

3. Capturá el **digest** —el identificador criptográfico e inmutable del artefacto—:

   ```bash
   export DIGEST=$(crane digest "$IMG")
   echo "Tag consumido por humanos:  $IMG"
   echo "Digest = contrato para CD:  $DIGEST"
   ```

   Salida:

   ```
   Tag consumido por humanos:  ttl.sh/cnpa-3-5-1000:1h
   Digest = contrato para CD:  sha256:9f2c...e41a
   ```

4. Demostrá por qué el tag **no** es un contrato: reconstruí "otra versión" pisando el mismo tag y observá que el digest cambia aunque el tag no:

   ```bash
   echo '<h1>CNPA 3.5 — build v2 (mutación silenciosa)</h1>' > app/index.html
   docker build -t "$IMG" app/ && docker push "$IMG"
   echo "Nuevo digest bajo el MISMO tag: $(crane digest "$IMG")"
   ```

   El tag `:1h` ahora apunta a un `sha256:` distinto. Un CD que despliegue `:1h` obtendría **contenido diferente** en cada `imagePullPolicy: Always`, sin ninguna traza en Git.

**Preguntas de comprensión (Bloque 1):**

- **P1.1** — Enumerá las etapas canónicas de un pipeline de **CI** y decí cuál es su *output* final destinado a CD. ¿Dónde termina CI y empieza CD?
- **P1.2** — El paso 4 muestra una "mutación silenciosa". Explicá cómo referenciar la imagen por `@sha256:...` (digest-pinning) elimina esa clase de fallo, y qué propiedad del OCI image manifest lo garantiza.
- **P1.3** — CI corre en runners **efímeros** y **push-based**; CD (como veremos) suele ser **pull-based** y de larga vida. ¿Qué implicancia tiene esto para dónde viven las credenciales del cluster? ¿Debería el runner de CI tener `kubectl apply` sobre producción?

---

### Ejercicio 2 — El handoff CI → CD ocurre por Git, no por API del cluster

**Objetivo:** materializar el punto de integración. CI no despliega: **CI actualiza el estado deseado en un repositorio de configuración**, y ese commit es el evento que dispara al CD.

**Pasos:**

1. Iniciá el *config repo* (separado del *app repo*: separación de responsabilidades):

   ```bash
   cd ~/cnpa-3.5/gitops && git init -q
   mkdir -p apps/web
   ```

2. Escribí el manifiesto declarativo del estado deseado, pineando la imagen por **digest**:

   ```bash
   cat > apps/web/deployment.yaml <<EOF
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     labels: { app: web }
   spec:
     replicas: 2
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: ${IMG%%:*}@${DIGEST}
             ports:
               - containerPort: 80
   EOF
   git add -A && git commit -qm "deploy web @ ${DIGEST}"
   ```

3. Simulá el **paso final del pipeline de CI** —el *image bump*— como haría un job de CD-trigger. Este es el único "escritor" que CI necesita, y escribe a **Git**, no a la API de Kubernetes:

   ```bash
   # Reconstruimos "una release nueva" y actualizamos el estado deseado en Git
   NEW_DIGEST=$(crane digest "$IMG")
   sed -i "s#@sha256:[a-f0-9]\{64\}#@${NEW_DIGEST}#" apps/web/deployment.yaml
   git commit -qam "ci: bump web to ${NEW_DIGEST}"
   git log --oneline
   ```

   Salida:

   ```
   3b1f2a0 ci: bump web to sha256:....
   a90c7d4 deploy web @ sha256:9f2c...e41a
   ```

4. Observá la propiedad clave: el **historial de Git es el registro de auditoría del deployment**. Cada cambio de lo que corre en el cluster es un commit atribuible y reversible con `git revert`.

**Preguntas de comprensión (Bloque 2):**

- **P2.1** — ¿Por qué se recomienda separar el *app repo* (código fuente) del *config repo* (manifiestos)? Nombrá al menos dos consecuencias operativas de mezclarlos (pensá en loops de trigger y en RBAC).
- **P2.2** — En el paso 3, ¿quién tiene permiso de escritura sobre qué? Contrastá el modelo "el runner de CI hace `git push` al config repo" con "el runner de CI hace `kubectl apply`". ¿Cuál reduce el *blast radius* de un runner comprometido?
- **P2.3** — Un `git revert` del último commit, ¿qué provoca en un sistema GitOps correctamente configurado? ¿Necesitás tocar el cluster manualmente para hacer un rollback?

---

### Ejercicio 3 — El lado CD: Argo CD y el modelo *pull-based*

**Objetivo:** instalar el motor de CD y ver que **reconcilia** el cluster contra Git de forma continua, en lugar de recibir un `apply` empujado desde afuera.

**Pasos:**

1. Instalá Argo CD:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
   ```

2. Para tener un `repoURL` accesible desde el cluster, usaremos un repo público de ejemplo del proyecto (más adelante, en el Ejercicio 4, cerramos el loop con tu propio repo). Creá una `Application` declarativa —fijate que **la propia config del CD también es GitOps**:

   ```bash
   cat <<'EOF' | kubectl apply -f -
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
   EOF
   ```

3. Observá la reconciliación *pull-based* (Argo CD detecta la deriva y la corrige solo):

   ```bash
   kubectl -n argocd get applications.argoproj.io guestbook \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```

   Salida esperada (tras unos segundos):

   ```
   NAME        SYNC     HEALTH
   guestbook   Synced   Healthy
   ```

4. **Probá el `selfHeal`** (la esencia del CD declarativo): rompé el estado a mano y mirá cómo el CD lo restaura hacia el estado deseado de Git, **sin que nadie relance un pipeline**:

   ```bash
   kubectl -n guestbook scale deploy guestbook-ui --replicas=5
   sleep 20
   kubectl -n guestbook get deploy guestbook-ui -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Salida esperada:

   ```
   1
   ```

   Argo CD detectó la deriva contra Git (`replicas: 1`) y la revirtió.

**Preguntas de comprensión (Bloque 3):**

- **P3.1** — Definí *drift* y explicá qué hace `selfHeal: true`. ¿Por qué esto es imposible en un modelo puramente *push* donde CI hace `kubectl apply` y se olvida?
- **P3.2** — Contrastá **push-based CD** (el pipeline tiene credenciales y empuja al cluster) vs **pull-based CD** (un agente dentro del cluster tira de Git). Nombrá una ventaja de seguridad y una de escalabilidad multi-cluster del modelo pull.
- **P3.3** — En este ejercicio, ¿la `Application` de Argo CD es un objeto de CI o de CD? ¿Qué significa que "la configuración del CD también sea declarativa y viva en un cluster" (pista: *app-of-apps* / autogestión)?

---

### Ejercicio 4 — Cerrar el loop: de commit a cluster sin `kubectl apply` manual

**Objetivo:** integrar los dos dominios de punta a punta. El *image bump* del Ejercicio 2 (output de CI) debe llegar al cluster **únicamente** por reconciliación de CD.

**Pasos:**

1. Publicá tu `config repo` local en un repo remoto que controles (fork de `argocd-example-apps` o un repo nuevo). Suponé que queda en `https://github.com/<tu-usuario>/cnpa-gitops.git` con el `apps/web/deployment.yaml` del Ejercicio 2. Añadí también un `Service`:

   ```bash
   cat > apps/web/service.yaml <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
       - port: 80
         targetPort: 80
   EOF
   git add -A && git commit -qm "add web service" && git push
   ```

2. Registrá la `Application` apuntando a **tu** repo:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: web
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<tu-usuario>/cnpa-gitops.git
       targetRevision: HEAD
       path: apps/web
     destination:
       server: https://kubernetes.default.svc
       namespace: web
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [ CreateNamespace=true ]
   EOF
   ```

3. Verificá que llegó el estado v1 al cluster:

   ```bash
   kubectl -n web get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

4. **Simulá una release completa CI → CD.** En tu shell (haciendo de runner de CI): rebuild, push, y *bump* del digest en Git. Después **no toques el cluster**:

   ```bash
   echo '<h1>CNPA 3.5 — release desde CI</h1>' > ~/cnpa-3.5/app/index.html
   docker build -t "$IMG" ~/cnpa-3.5/app/ && docker push "$IMG"
   D=$(crane digest "$IMG")
   sed -i "s#@sha256:[a-f0-9]\{64\}#@${D}#" apps/web/deployment.yaml
   git commit -qam "ci: release ${D}" && git push
   ```

5. Observá el *sync* automático (Argo CD *polleará* el repo cada ~3 min por defecto, o disparalo con webhook / `argocd app get`):

   ```bash
   watch -n5 "kubectl -n web get deploy web \
     -o jsonpath='{.spec.template.spec.containers[0].image}{\"\n\"}'"
   ```

   Cuando el digest en el cluster coincida con `$D`, el loop está cerrado: **un commit generado por CI produjo un cambio en producción a través del CD, y no hubo un solo `kubectl apply` manual.**

**Preguntas de comprensión (Bloque 4):**

- **P4.1** — Trazá el evento completo "un dev mergea a `main`" hasta "el pod nuevo corre en el cluster", nombrando cada sistema que interviene y **qué artefacto/estado** pasa de uno al siguiente. ¿En qué punto exacto está la costura CI/CD?
- **P4.2** — El *polling* de 3 min introduce latencia. ¿Cómo la reducís sin volver al modelo push (pista: webhook del repo → `argocd-server`)? ¿Por qué esto sigue siendo *pull* aunque haya un webhook?
- **P4.3** — Escribir el digest en el YAML con `sed` es frágil. Nombrá dos patrones de plataforma que resuelven el *image bump* de forma robusta (pensá en un controller que observa el registry, y en render de manifiestos por overlays).

---

### Ejercicio 5 — Integración de supply chain: firmar en CI, verificar en CD

**Objetivo:** el punto de integración CI/CD es también un *trust boundary*. CI **firma** el artefacto; el CD **rechaza en admission** cualquier imagen no firmada. Esto conecta 3.5 con la seguridad de la cadena de suministro.

**Pasos:**

1. **Lado CI** — generá un par de claves y firmá la imagen por digest (nunca por tag):

   ```bash
   cosign generate-key-pair            # crea cosign.key / cosign.pub (usá una passphrase de lab)
   cosign sign --yes "${IMG%%:*}@$(crane digest "$IMG")"
   ```

   Salida (resumen):

   ```
   Pushing signature to: ttl.sh/cnpa-3-5-1000
   ```

2. Verificá manualmente la firma (lo que el gate de CD hará automáticamente):

   ```bash
   cosign verify --key cosign.pub "${IMG%%:*}@$(crane digest "$IMG")" | jq '.[0].critical.image'
   ```

   Salida:

   ```json
   { "docker-manifest-digest": "sha256:...." }
   ```

3. **Lado CD** — instalá Kyverno como *admission controller* y definí una policy que solo admite imágenes firmadas con **tu** clave:

   ```bash
   kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s

   cat <<EOF | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-web-signature
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: check-cosign
         match:
           any:
             - resources: { kinds: [ Pod ] }
         verifyImages:
           - imageReferences: [ "ttl.sh/cnpa-3-5-*" ]
             mutateDigest: true
             attestors:
               - count: 1
                 entries:
                   - keys:
                       publicKey: |-
   $(sed 's/^/                         /' cosign.pub)
   EOF
   ```

4. **Probá que el gate funciona en ambos sentidos.** Una imagen firmada pasa; una sin firmar se **rechaza en admission** (no llega a correr):

   ```bash
   # (a) firmada -> admitida
   kubectl -n web run ok --image="${IMG%%:*}@$(crane digest "$IMG")" --restart=Never

   # (b) imagen ajena/no firmada -> rechazada
   kubectl -n web run bad --image=nginx:1.27-alpine --restart=Never
   ```

   Salida esperada de (b):

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ... image verification failed for nginx:1.27-alpine: no signatures found
   ```

**Preguntas de comprensión (Bloque 5):**

- **P5.1** — ¿Por qué la firma se aplica sobre el **digest** y no sobre el tag? ¿Qué ataque quedaría abierto si firmáramos `ttl.sh/...:1h`?
- **P5.2** — El gate vive en el *admission control* del cluster (lado CD), no en el pipeline (lado CI). ¿Qué garantía extra da verificar en admission frente a verificar solo dentro del pipeline de CI?
- **P5.3** — Relacioná este ejercicio con **SLSA** y las **provenance attestations**. Además de "está firmada", ¿qué otra pregunta responde una attestation de provenance sobre el vínculo CI↔artefacto?

---

### Ejercicio 6 — Progressive delivery: cuando el CD decide con métricas (opcional)

**Objetivo:** ver que el CD moderno no solo aplica YAML: puede **promover o abortar** una release según señales de runtime, cerrando la relación con observabilidad (dominio 3.x).

**Pasos:**

1. Instalá Argo Rollouts:

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
   ```

2. Reemplazá el `Deployment` por un `Rollout` con estrategia *canary* (pegalo en tu config repo si querés integrarlo con el Ejercicio 4):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: web
   spec:
     replicas: 4
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: ttl.sh/cnpa-3-5-1000@sha256:REEMPLAZAR
             ports: [ { containerPort: 80 } ]
     strategy:
       canary:
         steps:
           - setWeight: 25
           - pause: { duration: 30s }
           - setWeight: 50
           - pause: {}          # pausa manual: requiere promote explícito
           - setWeight: 100
   ```

3. Dispará una nueva versión (cambiá el digest) y observá la promoción por pasos:

   ```bash
   kubectl argo rollouts get rollout web --watch
   ```

   Verás el peso del canary subir 25% → 50% y **detenerse** hasta un `kubectl argo rollouts promote web`.

**Preguntas de comprensión (Bloque 6):**

- **P6.1** — En un canary con `pause: {}` indefinida, ¿qué sistema decide si la release avanza? Nombrá la señal (métrica) que conectarías vía `AnalysisTemplate` para automatizar el *go/no-go*.
- **P6.2** — ¿Progressive delivery pertenece a CI o a CD? Justificá por qué la decisión de "promover al 100%" no puede vivir en el pipeline de CI.

---

### Limpieza

```bash
kind delete cluster --name cnpa-cicd
rm -f cosign.key cosign.pub
```

---

<details>
<summary><strong>Respuestas y justificaciones</strong> (abrí solo después de intentar)</summary>

**Bloque 0**

- **P0.1** — El registry es el **punto de integración desacoplado** entre CI y CD: CI publica ahí y CD consume de ahí, sin que ninguno conozca la existencia del otro. `kind load` acoplaría CD al sistema de archivos del runner de CI, lo que rompe el principio de que el artefacto debe ser **direccionable, versionado e inmutable** desde cualquier cluster (imposible en multi-cluster) y elimina la traza de dónde vino la imagen. El artefacto compartido —no el disco compartido— es el contrato.
- **P0.2** — `kind` es la **plataforma** (el "runtime" del dominio CD). No es CI (no construye artefactos) ni CD (no reconcilia); es el sustrato sobre el cual el motor de CD (Argo CD) actúa. En platform engineering esta distinción importa: el equipo de plataforma provee el cluster; los equipos de app consumen golden paths de CI/CD por encima.

**Bloque 1**

- **P1.1** — Etapas CI: *checkout → build → unit/integration tests → package (imagen OCI/Helm chart) → scan (SAST/deps/CVE) → publish al registry* (opcionalmente *sign + SBOM + provenance*). El **output final** es el **artefacto inmutable publicado** (imagen por digest, más sus attestations). CI **termina** cuando el artefacto está publicado y verificado; CD **empieza** cuando alguien declara "quiero *este digest* corriendo en *este entorno*". La costura es el registry + el commit de estado deseado.
- **P1.2** — Con `image: repo@sha256:...` el runtime siempre pull-ea *exactamente ese contenido*; el digest es el hash del *image manifest* (OCI image-spec), y cambiar un byte del contenido cambia el digest. Un tag es un puntero mutable; un digest es *content-addressable*. Digest-pinning convierte "desplegá lo que sea que apunte `:1h` hoy" en "desplegá este bit-exacto", eliminando mutaciones silenciosas y haciendo el deploy reproducible y auditable.
- **P1.3** — Como CI es efímero y potencialmente ejecuta código de PRs no confiables, **no debería** tener credenciales de `kubectl apply` sobre producción: un runner comprometido tendría acceso directo al cluster. Las credenciales del cluster deben vivir **dentro** del cluster, en el agente pull-based (Argo CD/Flux), que solo confía en Git. CI escribe a Git; CD, con las llaves, tira de Git. Esto reduce drásticamente el *blast radius*.

**Bloque 2**

- **P2.1** — Separar app repo de config repo: (1) evita *loops de CI* (un commit de *image bump* en el mismo repo re-dispararía el build); (2) permite **RBAC distinto** (devs con write al código; plataforma/automatización con write a config); (3) el historial de "qué corre" queda limpio y separado del historial de "qué se codeó"; (4) permite reusar un mismo config repo para promover el mismo artefacto entre entornos.
- **P2.2** — Con "`git push` al config repo", el runner solo necesita un token de escritura a **un repo**; el peor caso es un commit malicioso —revisable, revertible y **rechazado por el gate de admission** si la imagen no está firmada. Con "`kubectl apply`", el runner tiene un kubeconfig con poder sobre el cluster; un runner comprometido = cluster comprometido, sin punto de control intermedio. El modelo Git reduce el blast radius.
- **P2.3** — En GitOps correcto, `git revert` del último commit hace que el estado deseado vuelva a la versión anterior; el agente de CD detecta la diferencia y **reconcilia el cluster automáticamente** al estado previo. El rollback es un cambio en Git, no una operación manual sobre el cluster: mismo mecanismo que el roll-forward, auditable e idéntico en cualquier entorno.

**Bloque 3**

- **P3.1** — *Drift* es cualquier diferencia entre el estado real del cluster (*live*) y el estado deseado declarado en Git. `selfHeal: true` hace que el controller revierta automáticamente esa deriva hacia Git. En un modelo push puro, tras el `apply` nadie sigue observando: si alguien escala a mano o un operador borra un objeto, nada lo corrige hasta el próximo pipeline. El CD pull-based reconcilia **continuamente**, no una sola vez.
- **P3.2** — Push: el pipeline tiene el kubeconfig y empuja cambios. Pull: un agente en el cluster tira de Git. **Seguridad**: en pull, las credenciales del cluster nunca salen del cluster y no viven en el CI; la superficie externa se reduce a Git. **Escalabilidad multi-cluster**: en pull, agregar 50 clusters es agregar 50 agentes que tiran del mismo repo; en push, el pipeline necesitaría credenciales y conectividad hacia los 50 (fan-out frágil, red inversa).
- **P3.3** — Es un objeto de **CD**: describe *estado deseado de despliegue*. Que la config del CD sea declarativa y viva en el cluster habilita el patrón **app-of-apps** y la **autogestión**: una `Application` raíz gestiona a las demás (incluida la instalación del propio Argo CD) desde Git, de modo que el CD se aplica GitOps a sí mismo y no hay configuración *snowflake* fuera de control de versiones.

**Bloque 4**

- **P4.1** — dev mergea a `main` (app repo) → webhook dispara **CI** → build/test/package → **push imagen por digest** al registry (+ sign/SBOM) → job final de CI hace **`git commit`/`push` del image bump** al **config repo** → **CD** (Argo CD) detecta el nuevo commit (poll o webhook) → renderiza y **applica** los manifiestos → el scheduler crea el Pod → el kubelet pull-ea la imagen (verificada en admission) → Pod corriendo. **La costura CI/CD** está entre "imagen publicada + commit al config repo" (fin de CI) y "detección del commit + reconciliación" (inicio de CD). Los artefactos que cruzan: la **imagen por digest** (por el registry) y el **estado deseado** (por Git).
- **P4.2** — Configurás un **webhook** del repo hacia `argocd-server`, que dispara una reconciliación inmediata en vez de esperar el poll de 3 min. Sigue siendo *pull*: el webhook solo **notifica "revisá Git ahora"**; Argo CD sigue siendo quien **tira** del repo y **decide** aplicar, con sus propias credenciales dentro del cluster. Nadie empuja manifiestos al cluster desde afuera.
- **P4.3** — (1) Un **image updater/automation controller** (Argo CD Image Updater o Flux Image Automation) que observa el registry, descubre nuevos digests que matchean una policy y hace el bump/commit por vos. (2) **Render de manifiestos** con Kustomize (`images:` overlay) o Helm (`values`), de modo que el digest se setea en un solo lugar tipado y no con `sed` sobre YAML crudo. Ambos eliminan la fragilidad textual y hacen el bump auditable.

**Bloque 5**

- **P5.1** — Se firma el **digest** porque es lo único inmutable: firmar `:1h` no garantiza nada, ya que el tag puede reapuntarse a otra imagen después de firmar (ataque *tag-mutation* / re-tag malicioso), y la firma quedaría "válida" sobre contenido que ya cambió. Firmar el digest ata la firma al bit-exacto del artefacto.
- **P5.2** — Verificar en **admission** garantiza que **toda** carga que intente correr —venga del pipeline oficial, de un `kubectl run` manual, de otro pipeline, o de un atacante con acceso a la API— pasa por el mismo control. Verificar solo en CI protege únicamente el camino feliz; cualquiera que despliegue *fuera* de ese pipeline lo saltea. El gate en el cluster hace la política **inevitable**, no opcional.
- **P5.3** — SLSA formaliza niveles de integridad de la cadena de build; una **provenance attestation** (firmada) responde, además de "esta imagen está firmada": **quién/qué la construyó, desde qué fuente (commit), con qué builder y con qué parámetros**. Es decir, prueba el vínculo verificable "este artefacto salió de *este* pipeline sobre *este* código", no solo "alguien con la llave lo firmó". El gate puede exigir provenance, no solo firma.

**Bloque 6**

- **P6.1** — Con `pause: {}` indefinida decide un **humano** (`argo rollouts promote`) o un **`AnalysisTemplate`** que evalúa una métrica. Señales típicas: *success rate* / *error rate* (p. ej. ratio de HTTP 5xx desde Prometheus), latencia p95/p99, o tasa de restart del canary. Si la métrica cruza el umbral, Argo Rollouts **aborta y hace rollback** automáticamente; si se mantiene sana, promueve.
- **P6.2** — Progressive delivery es **CD**: opera sobre artefactos ya construidos, gestionando *cómo* se expone la nueva versión al tráfico real en runtime. La decisión de promover al 100% depende de **señales de producción** (tráfico, métricas de usuarios reales) que **no existen** en el momento del build; el pipeline de CI ya terminó y no tiene visibilidad del comportamiento en runtime. Por eso la promoción vive en el plano de CD, junto a la observabilidad.

</details>

---

### Fuentes oficiales

- CNCF Curriculum (CNPA): https://github.com/cncf/curriculum
- OpenGitOps — principios: https://opengitops.dev/
- Argo CD — docs: https://argo-cd.readthedocs.io/en/stable/
- Argo Rollouts — docs: https://argo-rollouts.readthedocs.io/en/stable/
- Flux — image automation: https://fluxcd.io/flux/guides/image-update/
- Tekton Pipelines — docs: https://tekton.dev/docs/pipelines/
- OCI Image Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- Sigstore / cosign — docs: https://docs.sigstore.dev/
- SLSA (Supply-chain Levels for Software Artifacts): https://slsa.dev/spec/
- Kyverno — verify images: https://kyverno.io/docs/writing-policies/verify-images/
- kind — Quick Start: https://kind.sigs.k8s.io/docs/user/quick-start/
- ttl.sh — ephemeral registry: https://ttl.sh/