# Tema 2.1 — Principios y prácticas de GitOps

## Ejercicios guiados

Estos ejercicios te hacen *construir* GitOps desde los primeros principios antes de tocar un controlador completo, de modo que cada comportamiento de una herramienta de producción (Flux, Argo CD) se corresponda con un mecanismo que ya implementaste a mano. Vas a necesitar: una shell de Linux/macOS, `git`, `kubectl`, `kind` (o cualquier clúster de Kubernetes descartable), y la CLI de `flux` para los últimos ejercicios.

Los cuatro principios que estás por ejercitar están definidos por el proyecto OpenGitOps (un grupo de trabajo de la CNCF) en [GitOps Principles v1.0.0](https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md):

| # | Principio | Esencia |
|---|-----------|---------|
| 1 | **Declarativo** | El estado deseado se expresa como datos (hechos), no como instrucciones |
| 2 | **Versionado e inmutable** | El estado deseado se almacena con historial completo; las versiones son inmutables |
| 3 | **Obtenido automáticamente (pull)** | Los agentes obtienen el estado deseado desde el almacén; el estado no se les empuja |
| 4 | **Reconciliado continuamente** | Los agentes observan continuamente el estado real y lo convergen hacia el estado deseado |

Fuentes de referencia usadas a lo largo del tema:

- https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- https://opengitops.dev/
- https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md
- https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md
- https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/declarative-object-management-configuration/
- https://kubernetes.io/docs/reference/using-api/server-side-apply/
- https://fluxcd.io/flux/concepts/
- https://argo-cd.readthedocs.io/en/stable/

---

## Ejercicio 1 — Estado deseado declarativo vs. comandos imperativos (Principio 1)

La palabra *declarativo* cumple una función precisa en GitOps: el estado deseado del sistema debe expresarse como **datos que se puedan almacenar, comparar (diff) y aplicar de forma idempotente** — no como una secuencia de comandos cuyo resultado depende del estado contra el que se ejecutaron.

### Pasos

1. Creá un clúster descartable:

   ```bash
   kind create cluster --name gitops-lab
   ```

2. Creá un directorio de trabajo y un manifiesto declarativo:

   ```bash
   mkdir -p ~/gitops-lab/manifests && cd ~/gitops-lab
   cat > manifests/nginx.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: default
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
           image: nginx:1.27.0
           ports:
           - containerPort: 80
           resources:
             requests:
               cpu: 50m
               memory: 64Mi
             limits:
               memory: 128Mi
   EOF
   ```

3. Primero, hacelo de la manera **imperativa**, dos veces, y observá el modo de falla:

   ```bash
   kubectl create deployment web-imperative --image=nginx:1.27.0 --replicas=2
   kubectl create deployment web-imperative --image=nginx:1.27.0 --replicas=2
   ```

   Salida esperada de la segunda invocación:

   ```
   error: failed to create deployment: deployments.apps "web-imperative" already exists
   ```

4. Ahora de la manera **declarativa**, también dos veces:

   ```bash
   kubectl apply -f manifests/nginx.yaml
   kubectl apply -f manifests/nginx.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/web created
   deployment.apps/web unchanged
   ```

   Fijate en `unchanged`: aplicar el mismo estado deseado otra vez no hace nada. Esta propiedad es la **idempotencia**, y es lo que hace que un bucle automatizado de reconciliación sea seguro de ejecutar para siempre.

5. Previsualizá un cambio *sin* aplicarlo. Editá `replicas: 2` → `replicas: 3` en `manifests/nginx.yaml`, y después:

   ```bash
   kubectl diff -f manifests/nginx.yaml; echo "exit code: $?"
   ```

   Salida esperada (abreviada):

   ```diff
   -  replicas: 2
   +  replicas: 3
   exit code: 1
   ```

   `kubectl diff` sale con `1` cuando existe una diferencia, `0` cuando el estado en vivo ya coincide, y `>1` ante errores reales — lo que hace que la comparación entre estado deseado y real sea programable. Esta es la primitiva que hay debajo de la función de "diff/drift" de toda herramienta GitOps.

6. Limpiá el experimento imperativo:

   ```bash
   kubectl delete deployment web-imperative
   ```

### Verificá tu comprensión

- **P1.1** — ¿Por qué `kubectl apply` puede ejecutarse en un bucle desatendido y `kubectl create` no? Nombrá la propiedad y explicá qué hizo distinto el segundo `apply` respecto del segundo `create` a nivel de la API.
- **P1.2** — Un colega propone mantener en Git un `setup.sh` lleno de comandos `kubectl create ...` y `kubectl scale ...` y lo llama "GitOps, porque el script está versionado". ¿Cuál de los cuatro principios viola esto, y qué capacidad concreta perdés?
- **P1.3** — El Principio 1 dice que el estado deseado se "expresa declarativamente". ¿GitOps exige YAML específicamente? ¿Qué exige realmente del formato el [glosario de OpenGitOps](https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md)?

---

## Ejercicio 2 — Git como almacén de estado versionado e inmutable (Principio 2)

El almacén del estado deseado debe proveer **versionado, inmutabilidad e historial completo**. Git es la elección canónica — no porque GitOps requiera Git, sino porque los commits son direccionables por contenido (un SHA identifica exactamente un árbol) y la manipulación del historial es detectable.

### Pasos

1. Convertí el directorio de manifiestos en la **fuente de verdad**:

   ```bash
   cd ~/gitops-lab
   git init --initial-branch=main
   git add manifests/nginx.yaml
   git commit -m "web: nginx 1.27.0, 3 replicas"
   ```

2. Hacé un cambio *como dato*: subí la versión de la imagen. Editá `nginx:1.27.0` → `nginx:1.27.1`, y después:

   ```bash
   git add -A
   git commit -m "web: bump nginx to 1.27.1"
   git log --oneline
   ```

   Salida esperada (tus SHAs van a diferir):

   ```
   9f3c2b1 web: bump nginx to 1.27.1
   4a81e77 web: nginx 1.27.0, 3 replicas
   ```

3. Demostrá la inmutabilidad mediante el direccionamiento por contenido. Preguntale a Git cómo se veía el manifiesto en cada versión:

   ```bash
   git show 4a81e77:manifests/nginx.yaml | grep image:
   git show 9f3c2b1:manifests/nginx.yaml | grep image:
   ```

   Salida esperada:

   ```
           image: nginx:1.27.0
           image: nginx:1.27.1
   ```

   Cualquier alteración del contenido del commit viejo cambiaría su SHA. El SHA *es* la versión.

4. Hacé rollback **como una operación de Git**, preservando el historial:

   ```bash
   git revert --no-edit HEAD
   git log --oneline
   ```

   Salida esperada:

   ```
   c07d4e2 Revert "web: bump nginx to 1.27.1"
   9f3c2b1 web: bump nginx to 1.27.1
   4a81e77 web: nginx 1.27.0, 3 replicas
   ```

   El árbol ahora coincide con el estado 1.27.0, pero el historial registra que la 1.27.1 existió, cuándo, y que fue revertida. Comparalo con `git reset --hard 4a81e77` + force-push, que *reescribiría* el historial — destruyendo el rastro de auditoría que el principio existe para proteger.

5. Marcá un estado conocido como bueno con una referencia inmutable:

   ```bash
   git tag -a v0.1.0 -m "known good: nginx 1.27.0, 3 replicas"
   ```

### Verificá tu comprensión

- **P2.1** — ¿Por qué `git revert` es el rollback conforme a GitOps, y `git reset --hard` + force-push una violación del Principio 2? Respondé en términos de lo que necesita un auditor (o una retrospectiva de incidente).
- **P2.2** — En un incidente de producción tenés que saber *exactamente* qué estaba desplegado a las 03:12. ¿Qué dos identificadores, juntos, responden esa pregunta en un sistema GitOps, y por qué "el número de build de CI" no es uno de ellos?
- **P2.3** — ¿El Principio 2 exige Git? Nombrá una propiedad que un almacén de estado debe tener para calificar, y un sistema de almacenamiento distinto de Git que pueda satisfacerla.

---

## Ejercicio 3 — Construí un reconciliador basado en pull en 15 líneas de shell (Principios 3 y 4)

Antes de instalar cualquier herramienta, vas a *ser* la herramienta. Un agente GitOps hace exactamente esto: obtiene el estado deseado desde el almacén, lo compara con el estado real, aplica. Construirlo a mano le quita toda la magia a Flux y Argo CD.

### Pasos

1. Creá un repositorio bare que haga el papel del remoto (en producción esto es GitHub/GitLab; la mecánica es idéntica):

   ```bash
   git clone --bare ~/gitops-lab ~/gitops-remote.git
   cd ~/gitops-lab
   git remote add origin ~/gitops-remote.git
   git push -u origin main
   ```

2. Escribí el reconciliador:

   ```bash
   cat > ~/reconciler.sh <<'EOF'
   #!/usr/bin/env bash
   # Minimal GitOps agent: pull desired state, converge actual state.
   set -euo pipefail
   REPO="$HOME/gitops-remote.git"
   WORKDIR="$(mktemp -d)"
   trap 'rm -rf "$WORKDIR"' EXIT
   git clone --quiet --depth 1 "$REPO" "$WORKDIR"
   REV="$(git -C "$WORKDIR" rev-parse --short HEAD)"
   if kubectl diff -f "$WORKDIR/manifests/" >/dev/null 2>&1; then
     echo "$(date -Is) rev=$REV in sync"
   else
     echo "$(date -Is) rev=$REV drift detected, reconciling"
     kubectl apply -f "$WORKDIR/manifests/"
   fi
   EOF
   chmod +x ~/reconciler.sh
   ```

3. Ejecutá un ciclo de reconciliación:

   ```bash
   ~/reconciler.sh
   ```

   Salida esperada (la primera ejecución aplica el estado 1.27.0 revertido del Ejercicio 2 por encima del 1.27.1 que aplicaste en el Ejercicio 1):

   ```
   2026-08-18T10:41:02+00:00 rev=c07d4e2 drift detected, reconciling
   deployment.apps/web configured
   ```

4. Arrancá el bucle **continuo** en una segunda terminal y dejalo corriendo:

   ```bash
   while true; do ~/reconciler.sh; sleep 15; done
   ```

5. Ahora atacá tu propio sistema. En la primera terminal, introducí drift de forma imperativa — el clásico hotfix de las 3 de la mañana:

   ```bash
   kubectl scale deployment web --replicas=10
   kubectl get deployment web -o jsonpath='{.spec.replicas}'; echo
   ```

   Salida esperada: `10` — brevemente. Dentro de los 15 segundos, la terminal del bucle muestra:

   ```
   2026-08-18T10:43:17+00:00 rev=c07d4e2 drift detected, reconciling
   deployment.apps/web configured
   ```

   y la cantidad de réplicas vuelve a `3`. El cambio manual fue **pisado** porque nunca existió en el estado deseado. Esto es corrección de drift, también conocida como auto-reparación (self-healing).

6. Hacé un cambio *legítimo* a la manera GitOps — a través del almacén, nunca a través del clúster:

   ```bash
   cd ~/gitops-lab
   sed -i 's/replicas: 3/replicas: 5/' manifests/nginx.yaml
   git commit -am "web: scale to 5 for launch traffic"
   git push origin main
   ```

   Dentro de un ciclo el bucle lo detecta y el deployment converge a 5 réplicas. Detené el bucle con `Ctrl-C` cuando termines.

7. Reflexioná sobre la topología de seguridad que acabás de construir: el agente del lado del clúster tenía credenciales para *leer* el repositorio y *escribir* en el clúster donde vive. Nada fuera del clúster tuvo nunca credenciales del clúster. Comparalo con un pipeline de push (CI ejecuta `kubectl apply`), donde un `KUBECONFIG` con acceso de escritura debe vivir en el sistema de CI — fuera del límite de confianza del clúster.

### Verificá tu comprensión

- **P3.1** — El Principio 3 dice que el estado deseado se *obtiene automáticamente*, y las notas de OpenGitOps agregan que no debería depender de ser notificado. Tu bucle sondea cada 15 s; muchas configuraciones además agregan un webhook desde el host de Git para disparar una sincronización inmediata. ¿Un sistema que reconcilia *únicamente* ante webhooks es conforme a GitOps? ¿Por qué sí o por qué no?
- **P3.2** — Enumerá dos ventajas concretas de seguridad u operativas del modelo pull sobre un modelo de push desde CI, en base a lo que observaste en el paso 7.
- **P3.3** — En el paso 5 tu arreglo imperativo fue revertido automáticamente. En un incidente real, a veces los ingenieros *necesitan* que un cambio manual sobreviva (break-glass). ¿Cuáles son dos maneras conformes de manejar esto sin abandonar GitOps?
- **P3.4** — Tu reconciliador trata al repositorio como autoritativo incluso para cambios que él no hizo. ¿Cómo se llama la discrepancia que detecta, y cuál es el término general para el proceso del paso 5 que la elimina?

---

## Ejercicio 4 — Los mismos principios con un controlador de producción: Flux (Principios 3 y 4 a escala)

A tu bucle de shell le faltan: reintentos con backoff, evaluación de salud, recolección de basura de recursos eliminados, reporte de estado como objetos de la API, y multi-tenancy. Flux agrega todo eso mientras implementa exactamente el bucle que escribiste. Documentación: https://fluxcd.io/flux/concepts/

### Pasos

1. Instalá los controladores de Flux (no hace falta acceso de escritura a Git para este ejercicio de solo lectura):

   ```bash
   flux install
   flux check
   ```

   Cola esperada de la salida:

   ```
   ✔ helm-controller: deployment ready
   ✔ kustomize-controller: deployment ready
   ✔ notification-controller: deployment ready
   ✔ source-controller: deployment ready
   ✔ all checks passed
   ```

2. Declará la **fuente** — dónde vive el estado deseado (equivalente al `git clone` de tu script):

   ```bash
   flux create source git podinfo \
     --url=https://github.com/stefanprodan/podinfo \
     --branch=master \
     --interval=1m
   ```

3. Declará la **reconciliación** — qué ruta aplicar y cómo (equivalente a tu `kubectl apply` + bucle):

   ```bash
   flux create kustomization podinfo \
     --source=GitRepository/podinfo \
     --path="./kustomize" \
     --target-namespace=default \
     --prune=true \
     --interval=1m \
     --wait --health-check-timeout=2m
   ```

   La salida esperada termina con:

   ```
   ✔ Kustomization podinfo is ready
   ```

4. Inspeccioná el estado reconciliado — fijate en que el estado de sincronización es en sí mismo un objeto de Kubernetes, con el SHA de Git aplicado registrado:

   ```bash
   flux get kustomizations
   ```

   Salida esperada:

   ```
   NAME     REVISION              SUSPENDED  READY  MESSAGE
   podinfo  master@sha1:073f1ec5  False      True   Applied revision: master@sha1:073f1ec5
   ```

5. Atacalo, más fuerte que antes — borrá el Deployment entero:

   ```bash
   kubectl delete deployment podinfo
   flux reconcile kustomization podinfo --with-source
   kubectl get deployment podinfo
   ```

   Salida final esperada — resucitado desde el estado deseado:

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo   2/2     2            2           14s
   ```

6. Observá lo que tu bucle de shell nunca podría hacer — **prune**. El `kubectl apply` de tu script agrega y actualiza pero nunca borra: si sacás un manifiesto de Git, el objeto en vivo queda filtrado para siempre (un *huérfano*). Flux con `--prune=true` rastrea todo lo que creó y recolecta como basura los objetos que desaparecen de la fuente. Verificá el mecanismo:

   ```bash
   kubectl get deployment podinfo -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep kustomize.toolkit
   ```

   Salida esperada:

   ```
   "kustomize.toolkit.fluxcd.io/name":"podinfo"
   "kustomize.toolkit.fluxcd.io/namespace":"flux-system"
   ```

   Estas etiquetas son el marcador de inventario de Flux — así sabe qué objetos en vivo pertenecen a qué Kustomization, de modo que la eliminación por omisión sea segura.

7. Suspendé la reconciliación — el control break-glass de la P3.3, como una operación de primera clase y auditable:

   ```bash
   flux suspend kustomization podinfo
   flux get kustomizations
   ```

   La salida esperada muestra `SUSPENDED: True`. Los cambios manuales ahora van a persistir — de forma visible, temporal y reversible (`flux resume kustomization podinfo`).

### Verificá tu comprensión

- **P4.1** — Mapeá cada componente que usaste (`GitRepository`, `Kustomization`, `source-controller`, `kustomize-controller`) sobre las líneas de tu reconciliador de shell de 15 líneas del Ejercicio 3.
- **P4.2** — ¿Por qué el prune requiere un inventario (las etiquetas del paso 6)? Explicá el modo de falla de una estrategia ingenua de "borrar todo lo que no esté en el repositorio" en un clúster donde varios equipos — u operadores que no usan GitOps — también crean objetos.
- **P4.3** — En el paso 4 el objeto de estado registra `master@sha1:073f1ec5`. Conectá esto con la P2.2: ¿qué pregunta de auditoría responde almacenar la revisión aplicada *en el clúster* que Git por sí solo no puede responder?
- **P4.4** — Argo CD implementa los mismos principios con vocabulario distinto. ¿Cuáles son los equivalentes en Argo CD de (a) la fuente de estado deseado + ruta, y (b) la corrección de drift? (Ver https://argo-cd.readthedocs.io/en/stable/ — términos: `Application`, `syncPolicy.automated.selfHeal`.)

---

## Ejercicio 5 — Síntesis de prácticas: despliegue, rollback y el límite CI/CD

GitOps redibuja la línea entre CI y CD: CI *produce* artefactos y actualiza el estado deseado; el agente lo *entrega*. Nada en CI toca el clúster.

### Pasos

1. En papel (o en un archivo de borrador), desarrollá el flujo de producción para una versión nueva de una aplicación, en orden:

   ```
   1. Developer merges code PR            → CI builds image myapp:1.4.0, pushes to registry
   2. CI (or automation bot) opens a PR   → edits desired-state repo: image tag 1.3.2 → 1.4.0
   3. Human (or policy engine) approves   → merge to main
   4. Agent pulls within its interval     → detects new revision
   5. Agent applies, checks health        → cluster converges to 1.4.0
   6. Status reported                     → revision recorded in cluster + notifications
   ```

   Fijate en lo que está ausente: ningún `kubectl` en CI, ninguna credencial del clúster fuera del clúster, ningún humano ejecutando comandos en ningún momento después del merge.

2. Identificá los **dos repositorios** de este flujo y sus ciclos de vida diferentes: el *repositorio de la aplicación* (código, construido por CI) y el *repositorio de estado deseado* (manifiestos, observado por el agente). Anotá una razón para mantenerlos separados (pista: considerá qué significa un revert de cada uno, y quién necesita derechos de merge sobre cuál).

3. Simulá el simulacro de rollback de punta a punta con tu montaje del Ejercicio 3. Release defectuoso:

   ```bash
   cd ~/gitops-lab
   sed -i 's/nginx:1.27.0/nginx:1.99.99-doesnotexist/' manifests/nginx.yaml
   git commit -am "web: bump nginx to 1.99.99"
   git push origin main
   ~/reconciler.sh
   kubectl rollout status deployment/web --timeout=30s
   ```

   Salida esperada:

   ```
   error: deployment "web" exceeded its progress deadline
   ```

   ```bash
   kubectl get pods -l app=web | head -4
   ```

   ```
   NAME                   READY   STATUS             RESTARTS   AGE
   web-7d9f8c6b5-x2kqp    0/1     ImagePullBackOff   0          45s
   web-6b8d7f9c4-a1wzr    1/1     Running            0          20m
   ```

   Fijate en que los pods del ReplicaSet viejo siguen en `Running` — la propia lógica de rollout del controlador de Deployment contiene el radio de impacto mientras arreglás hacia adelante o hacés rollback.

4. Hacé el rollback a través del almacén, nunca a través del clúster:

   ```bash
   git revert --no-edit HEAD
   git push origin main
   ~/reconciler.sh
   kubectl rollout status deployment/web --timeout=60s
   ```

   Salida esperada:

   ```
   deployment "web" successfully rolled out
   ```

   Procedimiento de rollback completo: un `git revert`. Sin runbook especial, sin comandos a medida — la *ruta de despliegue y la ruta de rollback son la misma ruta*, que es por lo que están igualmente bien ensayadas.

5. Desmontá todo:

   ```bash
   kind delete cluster --name gitops-lab
   ```

### Verificá tu comprensión

- **P5.1** — Un pipeline ejecuta `kubectl apply` desde CI después de cada merge a main, usando manifiestos almacenados en Git. ¿Qué principios satisface, cuáles viola, y qué clase de falla no puede detectar que tu bucle del Ejercicio 3 sí detecta?
- **P5.2** — ¿Por qué `kubectl rollout undo` es un antipatrón en un clúster gestionado con GitOps, aunque "funcione"? ¿Qué divergencia de estado crea?
- **P5.3** — Dá dos razones por las que el repositorio de la aplicación y el repositorio de estado deseado suelen estar separados, tomadas del paso 2 y del comportamiento de CI (pista: ¿qué pasa si CI se dispara con cada commit en un repositorio combinado?).
- **P5.4** — GitOps está relacionado con, pero es distinto de, la Infraestructura como Código. Enunciá la relación en una sola oración: ¿qué provee IaC, y qué agregan encima los Principios 3 y 4?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**R1.1** — La propiedad es la **idempotencia**. `kubectl apply` declara un estado final deseado: el API server (con server-side apply, mediante la gestión de campos) calcula la diferencia entre el estado declarado y el objeto en vivo y realiza el parche mínimo — o nada, de ahí `unchanged`. `kubectl create` es una instrucción ("hacé que este objeto exista ahora") cuya validez depende del estado previo, así que reejecutarla es un error. Un bucle de reconciliación debe ejecutar la misma operación indefinidamente, por lo que toda operación dentro de él debe ser idempotente. Ver https://kubernetes.io/docs/reference/using-api/server-side-apply/

**R1.2** — Viola el **Principio 1 (Declarativo)**. Un script es una *secuencia de instrucciones*; su resultado depende del estado contra el que se ejecuta, no es idempotente, y no se puede comparar (diff) contra el estado en vivo. Perdés la capacidad de calcular drift (`kubectl diff` no tiene nada con qué comparar), y por lo tanto el Principio 4 (reconciliación continua) se vuelve imposible de implementar encima. Versionar un script satisface la letra del Principio 2 mientras vuelve inalcanzables el 1, el 3 y el 4.

**R1.3** — No. El [glosario de OpenGitOps](https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md) exige que el estado deseado se exprese *declarativamente* — como datos que describen resultados, no procedimientos. YAML, JSON, overlays de Kustomize, values de Helm, Jsonnet o HCL de Terraform califican todos, siempre que la expresión sea un dato a partir del cual un agente pueda calcular y aplicar un diff.

### Ejercicio 2

**R2.1** — `git revert` crea un commit *nuevo* cuyo árbol coincide con el estado anterior, preservando el historial completo: un auditor puede ver que la versión defectuosa fue desplegada, durante qué ventana, y cuándo se revirtió — que es precisamente la línea de tiempo del incidente que necesita una retrospectiva. `git reset --hard` + force-push *reescribe* el historial, destruyendo el registro de que el estado defectuoso alguna vez existió, violando el requisito del Principio 2 de un historial de versiones inmutable y completo (y rompiendo todo clon que hubiera hecho fetch del head viejo).

**R2.2** — El **SHA del commit de Git** del repositorio de estado deseado que el agente había aplicado, más la **revisión/estado aplicado registrado por el agente** en ese instante (por ejemplo, el `Applied revision: master@sha1:...` de Flux). Juntos prueban tanto lo que decía el almacén como aquello a lo que el clúster había convergido realmente. Un número de build de CI identifica una *construcción de artefacto*, no el estado deseado del sistema entero en un punto del tiempo, y nada garantiza que el clúster lo estuviera ejecutando a las 03:12.

**R2.3** — No — los principios hablan de un "almacén de estado", con Git como implementación dominante. Propiedades que califican: versionado, inmutabilidad de las versiones e historial completo recuperable. Un **registro OCI con artefactos inmutables y versionados** califica (Flux soporta fuentes `OCIRepository`); un bucket de S3 con versionado + object lock es otro ejemplo defendible. Un recurso compartido de archivos simple no lo es.

### Ejercicio 3

**R3.1** — No. La sincronización solo por webhook convierte al sistema en algo *dirigido por eventos y disparado por push*: si el webhook se pierde (partición de red, caída del host de Git, mala configuración), el estado deseado y el real divergen silenciosamente para siempre, y el drift introducido *en el clúster* (que no genera ningún webhook de Git — como en el paso 5) nunca se corrige. Los sistemas conformes reconcilian por intervalo *y* opcionalmente aceptan webhooks como optimización de latencia. El pull programado es el mecanismo de corrección; el webhook es solo un acelerador.

**R3.2** — (1) **Dirección de las credenciales**: las credenciales de escritura del clúster nunca salen del clúster; el agente solo necesita acceso de lectura al repositorio. Un sistema de CI comprometido puede proponer estado pero no puede tocar el clúster. (2) **Corrección de drift**: un pipeline de push solo actúa cuando Git cambia, así que las mutaciones del clúster fuera de banda (`kubectl` manual, un operador que se porta mal) persisten sin ser detectadas; el bucle de pull las detecta y las revierte en cada ciclo. (También es aceptable: postura de firewall — el clúster no necesita acceso entrante desde CI; y escalabilidad de flota — N clústeres hacen pull de un solo repositorio sin que el pipeline los conozca.)

**R3.3** — (1) **Suspender la reconciliación explícitamente** (por ejemplo, `flux suspend kustomization`, o deshabilitar el auto-sync en Argo CD) — la pausa en sí es visible y reversible — hacer el arreglo manual, después portarlo a Git y reanudar. (2) **Commitear el cambio de emergencia a Git primero** y dejar que el agente lo despliegue — con un intervalo corto o una reconciliación forzada esto es casi igual de rápido y nunca deja al almacén atrás. En ambos casos se restaura el invariante: Git termina coincidiendo con el clúster.

**R3.4** — La discrepancia es el **drift** (el estado real divergiendo del estado deseado). El proceso que la elimina es la **reconciliación** — específicamente la corrección automática de drift, comúnmente llamada **self-healing** (auto-reparación).

### Ejercicio 4

**R4.1** — `GitRepository` ≙ la declaración `REPO=` más el `git clone` (obtener el estado deseado; `source-controller` ejecuta ese bucle, verifica y empaqueta el artefacto). `Kustomization` ≙ la declaración de *qué aplicar de él* — la ruta `manifests/`, el intervalo y la política de aplicación; `kustomize-controller` la ejecuta: tus líneas de `kubectl diff`/`kubectl apply` más la verificación de salud, los reintentos y el pruning. Tu `while true; sleep 15` es el `interval` de cada controlador. La mejora clave: en Flux la *configuración del bucle es en sí misma estado declarativo* almacenado como objetos de Kubernetes — el reconciliador se configura con los mismos principios que hace cumplir.

**R4.2** — Sin un inventario, "borrar todo lo que no esté en el repositorio" no puede distinguir los objetos creados por *este* reconciliador de los creados por otros equipos, otras Kustomizations, operadores/controladores (que crean objetos que el repositorio nunca menciona), o el propio Kubernetes. Borraría masivamente recursos que nunca le pertenecieron. Las etiquetas de inventario acotan la recolección de basura exactamente al conjunto de objetos aplicados previamente por esta Kustomization, lo que convierte la remoción-desde-Git en una señal de borrado segura.

**R4.3** — Responde "**¿a qué convergió realmente el clúster en este momento?**". Git registra qué se *deseaba* y cuándo cambió; no puede decir si un clúster dado lo aplicó, ni cuándo (el agente puede estar fallando, suspendido o con retraso). El estado dentro del clúster cierra el bucle: revisión deseada (Git) vs. revisión aplicada (estado del clúster) — su diferencia es precisamente el retraso de sincronización o la falla que un operador necesita ver.

**R4.4** — (a) El recurso `Application` de Argo CD, cuyo `spec.source` (repoURL + path/chart + targetRevision) cumple el papel de `GitRepository` + la ruta de la `Kustomization`. (b) Sincronización automatizada con auto-reparación: `syncPolicy.automated: {selfHeal: true, prune: true}` — `selfHeal` revierte el drift en vivo, `prune` es el `--prune` de Flux. Argo CD llama "sync status" (`Synced`/`OutOfSync`) a la comparación entre deseado y real, y "sync" a la operación de convergencia. Ver https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/

### Ejercicio 5

**R5.1** — Satisface los Principios **1** (manifiestos declarativos) y **2** (almacén versionado). Viola el **3** — el estado es empujado por un sistema externo que posee credenciales del clúster, no obtenido por un agente dentro del clúster — y el **4** — corre solo ante eventos de merge, no de forma continua. La clase de falla indetectable: el **drift dentro del clúster** — cualquier mutación hecha directamente sobre el clúster (escalado manual, Deployment borrado, ConfigMap mutado) no genera ningún evento de Git, así que el pipeline nunca se entera; tu bucle lo detecta y lo corrige dentro de un intervalo.

**R5.2** — `kubectl rollout undo` cambia el estado en vivo (devuelve el Deployment a una plantilla de ReplicaSet anterior) sin cambiar el estado deseado en Git. La divergencia: Git sigue declarando la versión defectuosa, así que en el siguiente ciclo de reconciliación el agente la va a volver a aplicar y **volver a desplegar exactamente la versión que acabás de revertir** — la auto-reparación trabaja en tu contra. El rollback conforme es `git revert`, que mueve la *fuente de verdad* y deja que la convergencia haga el resto; despliegue y rollback comparten entonces una única ruta de código.

**R5.3** — (1) **Higiene de disparadores**: en un repositorio combinado, el commit del bot de CI que sube la versión en el manifiesto vuelve a disparar CI, produciendo bucles o builds desperdiciados, y cada commit de código de la aplicación vuelve a disparar espuriamente la reconciliación del despliegue. (2) **Ciclos de vida y permisos independientes**: revertir el repositorio de estado hace rollback de un *despliegue* sin revertir el *código*, y los derechos de merge difieren — los desarrolladores mergean código, mientras que los merges del repositorio de estado pueden requerir aprobación de un operador o de un motor de políticas. (También es aceptable: un solo repositorio de estado se despliega en abanico hacia muchos clústeres/entornos a los que un único repositorio de aplicación no se corresponde.)

**R5.4** — IaC provee los Principios 1 y 2 — infraestructura definida como datos declarativos y versionados; GitOps agrega el 3 y el 4: un agente autónomo dentro del clúster que continuamente *obtiene* esa definición y *reconcilia* el estado real contra ella, convirtiendo "podemos recrear el sistema desde el código" en "el sistema converge continuamente hacia el código, y el drift se corrige sin que ningún humano ejecute nada".

</details>