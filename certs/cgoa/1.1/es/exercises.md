# CGOA — Tema 1.1: Fundamentos de GitOps
## Ejercicios Guiados

> **Prerrequisitos del entorno:** una estación de trabajo Linux/macOS con `docker`, `kind` ≥ 0.20, `kubectl` ≥ 1.29, `git` ≥ 2.40 y `curl`. Cada ejercicio es autocontenido e idempotente: si un paso falla, corregí la causa y volvé a ejecutarlo. Tiempo total estimado: 90–120 minutos.

Estos ejercicios te hacen *construir* GitOps desde los primeros principios antes de que toques una herramienta de GitOps. Vas a expresar el estado deseado de forma declarativa (Principio 1), versionarlo de manera inmutable en Git (Principio 2), escribir tu propio reconciliador basado en pull en ~15 líneas de bash (Principios 3 y 4), y recién entonces instalar Argo CD y reconocer que es el mismo bucle, endurecido para producción. Esto refleja cómo el grupo de trabajo OpenGitOps define GitOps: no una herramienta, sino cuatro propiedades de un sistema ([https://opengitops.dev/](https://opengitops.dev/)).

---

## Ejercicio 1 — Estado deseado, expresado declarativamente

El primer principio de OpenGitOps: *"Un sistema gestionado por GitOps debe tener su estado deseado expresado declarativamente."* Declarativo significa que registrás **qué** aspecto debe tener el sistema, nunca la secuencia de comandos que lo produjo.

1. Creá un directorio de trabajo y un clúster local:

   ```bash
   mkdir -p ~/cgoa-lab/desired && cd ~/cgoa-lab
   kind create cluster --name gitops-lab
   ```

   Salida esperada (abreviada):

   ```
   Creating cluster "gitops-lab" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
   Set kubectl context to "kind-gitops-lab"
   ```

2. Escribí el estado deseado de una carga de trabajo. Notá que este archivo no contiene verbos — ni "crear", ni "escalar", ni "actualizar":

   ```bash
   cat > desired/deployment.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: default
     labels:
       app.kubernetes.io/name: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app.kubernetes.io/name: web
     template:
       metadata:
         labels:
           app.kubernetes.io/name: web
       spec:
         containers:
         - name: nginx
           image: nginx:1.27.1
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

3. Aplicalo y verificá la convergencia:

   ```bash
   kubectl apply -f desired/
   kubectl get deploy web
   ```

   Salida esperada:

   ```
   deployment.apps/web created
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    2/2     2            2           14s
   ```

4. Volvé a aplicar el archivo idéntico — esta es la propiedad que hace segura la automatización de GitOps:

   ```bash
   kubectl apply -f desired/
   ```

   Salida esperada:

   ```
   deployment.apps/web unchanged
   ```

5. Ahora hacé la cosa *imperativa* que tenés que desaprender, y observá la consecuencia:

   ```bash
   kubectl scale deploy web --replicas=4
   kubectl diff -f desired/; echo "exit code: $?"
   ```

   Salida esperada (abreviada): un diff unificado que muestra el objeto vivo divergiendo del archivo, y el código de salida documentado para "se encontraron diferencias":

   ```diff
   -  generation: 2
   +  generation: 3
   ...
   -  replicas: 4
   +  replicas: 2
   exit code: 1
   ```

   Los códigos de salida de `kubectl diff` son parte de su contrato: `0` = sin drift, `1` = drift, `>1` = error ([https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/)). Vas a construir sobre esto en el Ejercicio 3.

6. Restaurá el estado deseado antes de continuar:

   ```bash
   kubectl apply -f desired/
   ```

**Comprobá tu comprensión**

- **Q1.1** — El clúster ahora corre 2 réplicas otra vez. En términos de GitOps, ¿cuál es el nombre de la condición que creaste en el paso 5, y qué dos "estados" separó?
- **Q1.2** — `kubectl scale` y editar `replicas:` en el archivo producen los mismos pods en ejecución. ¿Por qué solo uno de los dos es compatible con GitOps?
- **Q1.3** — ¿Por qué importa la idempotencia (el `unchanged` del paso 4) para un sistema donde un agente aplica el mismo estado en un bucle, potencialmente miles de veces por día?

---

## Ejercicio 2 — Versionado e inmutable

Principio 2: *"El estado deseado se almacena de una manera que impone inmutabilidad, versionado y retiene un historial de versiones completo."* Git satisface esto porque cada commit es un objeto inmutable direccionado por contenido — nunca editás la historia, la agregás al final.

1. Convertí el estado deseado en una fuente de verdad versionada:

   ```bash
   cd ~/cgoa-lab
   git init -b main
   git add desired/
   git commit -m "web: nginx 1.27.1, 2 replicas"
   ```

2. Inspeccioná lo que Git realmente almacenó. Un commit es un objeto direccionado por el hash SHA-1/SHA-256 de su propio contenido:

   ```bash
   git log --oneline
   git cat-file -p HEAD
   ```

   Salida esperada (tus hashes van a diferir):

   ```
   9f3c1aa web: nginx 1.27.1, 2 replicas
   tree 4b825dc6...
   author dalmine <...> 1755500000 +0200
   web: nginx 1.27.1, 2 replicas
   ```

3. Hacé un cambio *como una nueva versión*, nunca como una edición de una vieja:

   ```bash
   sed -i 's/replicas: 2/replicas: 3/' desired/deployment.yaml
   git commit -am "web: scale to 3 for launch traffic"
   git log --oneline
   ```

   Salida esperada:

   ```
   7d02e4f web: scale to 3 for launch traffic
   9f3c1aa web: nginx 1.27.1, 2 replicas
   ```

4. Revertí al estilo GitOps — un *nuevo* commit que reintroduce el estado viejo, preservando el rastro de auditoría:

   ```bash
   git revert --no-edit HEAD
   git log --oneline
   grep replicas desired/deployment.yaml
   ```

   Salida esperada:

   ```
   c11b9e0 Revert "web: scale to 3 for launch traffic"
   7d02e4f web: scale to 3 for launch traffic
   9f3c1aa web: nginx 1.27.1, 2 replicas
       replicas: 2
   ```

5. Marcá un estado conocido-bueno con una referencia inmutable:

   ```bash
   git tag -a v1.0.0 -m "baseline: known-good web stack"
   git show v1.0.0 --stat --oneline | head -3
   ```

**Comprobá tu comprensión**

- **Q2.1** — ¿Por qué `git revert` es el rollback canónico de GitOps, mientras que `git reset --hard` + force-push viola el Principio 2?
- **Q2.2** — Un auditor pregunta: "¿quién cambió la cantidad de réplicas, cuándo, y qué cambió exactamente?" ¿Qué único comando de Git responde las tres cosas, y por qué la respuesta no puede falsificarse a posteriori?
- **Q2.3** — El tag `v1.0.0` y la rama `main` ambos apuntan a commits. ¿Cuál es una *versión* inmutable en el sentido del Principio 2, y qué riesgo operativo asumís al hacer que un agente despliegue una referencia móvil como `HEAD` de `main`?

---

## Ejercicio 3 — Construí vos mismo el bucle de reconciliación

Principios 3 y 4: los agentes *traen* (pull) el estado deseado y *reconcilian continuamente* el estado vivo hacia él. Antes de instalar 200 MB de controlador, probá el concepto en bash. Este es un bucle **level-triggered** (disparado por nivel) — compara estados completos en cada ciclo — exactamente el modelo de un controlador de Kubernetes ([https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)).

1. Escribí el reconciliador. Clona la verdad (pull), hace diff (observa), aplica (actúa):

   ```bash
   cat > reconcile.sh <<'EOF'
   #!/usr/bin/env bash
   # Minimal level-triggered GitOps reconciler.
   # Pulls desired state from a Git repo, converges the cluster toward it.
   set -u
   REPO="$HOME/cgoa-lab"          # in production: an https:// or ssh:// remote
   WORKDIR="$(mktemp -d)"
   INTERVAL=5

   while true; do
     rm -rf "$WORKDIR/src"
     git clone --quiet --depth 1 "$REPO" "$WORKDIR/src"     # PULL
     kubectl diff -f "$WORKDIR/src/desired/" >/dev/null 2>&1 # OBSERVE
     rc=$?
     if [ "$rc" -eq 1 ]; then
       echo "$(date -Is) drift detected — reconciling"
       kubectl apply -f "$WORKDIR/src/desired/"              # ACT
     elif [ "$rc" -gt 1 ]; then
       echo "$(date -Is) ERROR: diff failed (rc=$rc), retrying next cycle"
     fi
     sleep "$INTERVAL"
   done
   EOF
   chmod +x reconcile.sh
   ```

2. Ejecutalo en una terminal y dejalo corriendo:

   ```bash
   ./reconcile.sh
   ```

3. En una **segunda terminal**, atacá el estado vivo (simulá a un humano aplicando un hotfix o a un nodo que falla):

   ```bash
   kubectl scale deploy web --replicas=5
   kubectl get deploy web -w
   ```

   Esperado: dentro de un intervalo, la primera terminal imprime `drift detected — reconciling` y el watch muestra las réplicas volviendo a 2 sin ninguna acción humana:

   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    5/5     5            5           9m
   web    2/5     2            2           9m
   web    2/2     2            2           9m
   ```

4. Ahora cambiá el estado *de la forma correcta* — a través de Git — y mirá al mismo bucle entregarlo:

   ```bash
   cd ~/cgoa-lab
   sed -i 's/replicas: 2/replicas: 3/' desired/deployment.yaml
   git commit -am "web: scale to 3"
   ```

   Esperado: el reconciliador lo toma dentro de un ciclo. El despliegue y el rollback son ahora *el mismo mecanismo* — un commit.

5. Fijate en lo que tu reconciliador **no puede** hacer (por esto existen las herramientas reales): nunca borra objetos eliminados de Git (sin pruning), aplica en orden de archivo (sin ordenamiento de dependencias ni gating por salud), reporta el estado solo a stdout (sin API de estado), y clona con tus credenciales personales (sin separación de identidad).

**Comprobá tu comprensión**

- **Q3.1** — Tu bucle es level-triggered: compara el estado deseado completo contra el vivo en cada ciclo. Un diseño edge-triggered en cambio reaccionaría a eventos de cambio individuales. ¿Qué modo de falla sobrevive el level-triggering y el edge-triggering no?
- **Q3.2** — El paso 3 demostró la corrección automática de drift. Nombrá las dos *fuentes* de drift contra las que esto protege en producción, y explicá por qué "nadie tiene acceso de escritura al clúster" no vuelve innecesario el bucle.
- **Q3.3** — En el paso 1 el comentario del script dice que un reconciliador de producción hace pull desde un remoto. ¿Dónde corre el reconciliador y dónde viven las credenciales del clúster en este modelo, comparado con un pipeline de CI que corre `kubectl apply` desde GitHub Actions? ¿Por qué este es el argumento de seguridad a favor de GitOps *basado en pull*?

Detené el reconciliador con `Ctrl-C` antes del Ejercicio 4.

---

## Ejercicio 4 — El mismo bucle, con calidad de producción: Argo CD

Argo CD implementa el bucle que acabás de escribir como un conjunto de controladores, con el CRD `Application` como *estado deseado acerca del estado deseado*: un registro declarativo de "qué repo, qué path, qué revisión, hacia qué clúster" ([https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)).

1. Instalá Argo CD y esperá a que converja:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd wait deploy --all --for=condition=Available --timeout=300s
   ```

   Líneas finales esperadas:

   ```
   deployment.apps/argocd-repo-server condition met
   deployment.apps/argocd-server condition met
   ```

2. Registrá una aplicación **declarativamente** — un `Application` es en sí mismo un objeto de Kubernetes que podrías (y en producción, deberías) guardar en Git:

   ```bash
   cat > app-guestbook.yaml <<'EOF'
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
   EOF
   kubectl apply -f app-guestbook.yaml
   ```

3. Observá los dos ejes de estado ortogonales que computa Argo CD:

   ```bash
   kubectl -n argocd get application guestbook
   ```

   Salida esperada:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   OutOfSync     Missing
   ```

   `OutOfSync` = Git y el clúster difieren (el `rc=1` de tu reconciliador). `Missing`/`Healthy` es un juicio aparte: ¿la carga de trabajo *viva* realmente está funcionando? Tu bucle de bash no tenía equivalente.

4. No hay política `automated` configurada, así que Argo CD detecta el drift pero espera a un humano — GitOps con una compuerta manual. Disparó la sincronización declarativamente:

   ```bash
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   sleep 20
   kubectl -n argocd get application guestbook
   kubectl -n guestbook get deploy
   ```

   Salida esperada:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   Synced        Healthy
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           25s
   ```

**Comprobá tu comprensión**

- **Q4.1** — El objeto `Application` nunca contiene el manifiesto del Deployment de guestbook. ¿Qué contiene en cambio, y por qué esa indirección hace que todo el sistema de entrega sea recuperable desde cero (`kubectl apply -f app-guestbook.yaml` en un clúster vacío)?
- **Q4.2** — Explicá la diferencia entre `SYNC STATUS` y `HEALTH STATUS` con un escenario concreto en el que una app esté `Synced` pero `Degraded`.
- **Q4.3** — En el paso 4 la app estaba `OutOfSync` y Argo CD no hizo nada. ¿Cuál de los cuatro principios de OpenGitOps *aún no* estaba cumpliendo el sistema, y qué campo del spec lo activa?

---

## Ejercicio 5 — Reconciliación continua: self-heal y prune

1. Habilitá la automatización completa — esto es el Principio 4 como configuración:

   ```bash
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

   El bloque de política resultante, tal como viviría en Git:

   ```yaml
   syncPolicy:
     automated:
       prune: true      # objects removed from Git are removed from the cluster
       selfHeal: true   # drift in live state is reverted without a new commit
     syncOptions:
     - CreateNamespace=true
   ```

2. Atacá el estado vivo dos veces, y mirá al controlador ganar las dos:

   ```bash
   kubectl -n guestbook scale deploy guestbook-ui --replicas=3
   sleep 15
   kubectl -n guestbook get deploy guestbook-ui

   kubectl -n guestbook delete deploy guestbook-ui
   sleep 15
   kubectl -n guestbook get deploy guestbook-ui
   ```

   Salida esperada — réplicas de vuelta en 1, y el Deployment borrado recreado con un `AGE` nuevo:

   ```
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           6m
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           9s
   ```

3. Leé el relato del propio controlador sobre lo que pasó:

   ```bash
   kubectl -n argocd logs statefulset/argocd-application-controller --since=2m \
     | grep -i "guestbook" | grep -iE "sync|drift|apply" | tail -5
   ```

**Comprobá tu comprensión**

- **Q5.1** — `selfHeal` revirtió tu escalado manual sin ningún commit nuevo en Git. Entonces, ¿cuál es el *único* camino de escritura legítimo hacia este clúster ahora, y qué implica eso para los procedimientos de emergencia "break-glass"?
- **Q5.2** — `prune: true` es la configuración que más temen los equipos. Describí el accidente exacto que habilita, y un mecanismo (del lado de Git o de Argo) que lo mitigue manteniendo el pruning activado.
- **Q5.3** — La reacción de self-heal por defecto de Argo CD es rápida (segundos), mientras que tu bucle de bash consultaba cada 5 s y un `git clone` de un monorepo grande podría tardar minutos. ¿Qué componente arquitectónico le permite a un controlador de producción detectar drift del *estado vivo* casi instantáneamente sin hacer polling al clúster? (Pista: es el mismo mecanismo que usa `kubectl get -w`.)

---

## Ejercicio 6 — Falla y rollback a través de Git

Se despliega un cambio malo. En GitOps el rollback es un commit, y el ejercicio consiste en probar que el bucle lo entrega. Usamos el repo local y tu reconciliador de bash, donde vos controlás la historia.

1. Reiniciá tu reconciliador del Ejercicio 3 en una segunda terminal:

   ```bash
   ./reconcile.sh
   ```

2. Desplegá una versión rota — un tag que no existe:

   ```bash
   cd ~/cgoa-lab
   sed -i 's/nginx:1.27.1/nginx:1.27.99-nonexistent/' desired/deployment.yaml
   git commit -am "web: bump nginx (BROKEN: tag does not exist)"
   ```

3. Observá el modo de falla. El reconciliador aplica exitosamente — el *API server* aceptó el manifiesto — pero el rollout no puede progresar:

   ```bash
   sleep 10
   kubectl get pods -l app.kubernetes.io/name=web
   kubectl rollout status deploy/web --timeout=30s
   ```

   Salida esperada:

   ```
   NAME                  READY   STATUS             RESTARTS   AGE
   web-5f9c7b6d4-x2kkq   0/1     ImagePullBackOff   0          45s
   web-7d4b8c9f6-a1b2c   1/1     Running            0          20m
   web-7d4b8c9f6-d3e4f   1/1     Running            0          20m
   error: timed out waiting for the condition
   ```

   Notá los dos ReplicaSets: la estrategia de actualización progresiva del Deployment todavía te está protegiendo — los pods viejos siguen sirviendo mientras el nuevo hace crash-loop. "Aplicado" y "sano" son afirmaciones distintas (esta es la distinción sync-vs-health de Argo CD de Q4.2, observada en la práctica).

4. Hacé rollback con la historia intacta, y dejá que el bucle converja:

   ```bash
   git revert --no-edit HEAD
   sleep 10
   kubectl get pods -l app.kubernetes.io/name=web
   git log --oneline | head -3
   ```

   Esperado: solo pods `Running` con `nginx:1.27.1`, y una historia que *muestra el incidente*:

   ```
   f00dcafe Revert "web: bump nginx (BROKEN: tag does not exist)"
   badc0de1 web: bump nginx (BROKEN: tag does not exist)
   c11b9e0  Revert "web: scale to 3 for launch traffic"
   ```

5. Limpieza:

   ```bash
   # Ctrl-C the reconciler, then:
   kind delete cluster --name gitops-lab
   ```

**Comprobá tu comprensión**

- **Q6.1** — Argo CD ofrece `argocd app rollback <app> <history-id>`, que re-sincroniza el clúster a una revisión previamente desplegada. ¿Por qué `git revert` sigue siendo el rollback preferido en producción, y qué le hace Argo CD a la sincronización automática cuando usás su comando de rollback en su lugar?
- **Q6.2** — En el paso 3, cada verificación que hace tu reconciliador de bash pasó, y sin embargo el servicio estaba a un pod fallido de una caída. ¿Qué capacidad, presente en Argo CD y ausente en tu bucle, cierra esta brecha — y en qué punto de una sincronización actuaría sobre ella una configuración de producción?
- **Q6.3** — Escribí la respuesta de una sola oración, para la revisión del incidente, a "¿cómo evitamos que el tag roto se despliegue de nuevo?" que sea compatible con GitOps (es decir, el arreglo vive *antes* del merge, no en el clúster).

---

## Fuentes de referencia

- Principios OpenGitOps v1.0.0 — [https://opengitops.dev/](https://opengitops.dev/) y [https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md](https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md)
- Currículum CGOA de la CNCF — [https://github.com/cncf/curriculum](https://github.com/cncf/curriculum)
- Kubernetes: Controladores (reconciliación level-triggered) — [https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)
- Referencia de `kubectl diff` (contrato de códigos de salida) — [https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/)
- Documentación de Argo CD: configuración declarativa, sincronización automatizada, estado de Sync/Health — [https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)
- Documentación de Flux: conceptos de GitOps (modelo de source/reconciliation) — [https://fluxcd.io/flux/concepts/](https://fluxcd.io/flux/concepts/)

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** — Creaste **drift** (divergencia de estado): el **estado vivo** (4 réplicas, observado desde el clúster) ya no coincidía con el **estado deseado** (2 réplicas, registrado en el archivo). GitOps es precisamente la disciplina de detectar y eliminar esta divergencia de forma continua, siempre en la dirección del estado declarado.

**A1.2** — `kubectl scale` muta el estado vivo directamente y no deja registro en la fuente de verdad; el cambio es invisible para la revisión, no está versionado, y será revertido por cualquier reconciliador. Editar `replicas:` en el archivo versionado cambia el estado *deseado*, que es revisable, versionado, y es hacia lo que convergen los agentes. Los mismos pods, dirección de autoridad opuesta: en GitOps, la autoridad fluye solo desde la declaración hacia el clúster, nunca al revés.

**A1.3** — Un reconciliador aplica el mismo estado en cada ciclo, haya drift o no (o después de errores transitorios, reintentos). Si apply no fuera idempotente — si volver a aplicar causara reinicios, objetos duplicados o errores — la reconciliación continua sería destructiva. `unchanged` es la propiedad que hace de "aplicar para siempre, en bucle" una arquitectura segura en lugar de un peligro.

### Ejercicio 2

**A2.1** — `git revert` crea un commit **nuevo** cuyo contenido restaura el estado viejo, así que la historia sigue siendo append-only y completa: el cambio malo, la decisión de deshacerlo, quién y cuándo — todo se conserva. `git reset --hard` + force-push **reescribe** la historia, destruyendo el registro de que el estado malo alguna vez existió. El Principio 2 exige inmutabilidad e *historial de versiones completo*; una historia falsificada además rompe todo agente y proceso de auditoría que asumía que los commits son permanentes.

**A2.2** — `git log -p desired/deployment.yaml` (o `git blame` para atribución a nivel de línea) muestra autor, marca de tiempo y diff exacto de cada cambio. No puede falsificarse a posteriori porque el ID de cada commit es un hash criptográfico de su contenido *y del ID de su padre*: alterar cualquier commit histórico cambia todos los hashes descendientes, lo que es inmediatamente visible en cada clon. (Los campos de autor son autodeclarados, y por eso las configuraciones de producción agregan commits firmados — `git commit -S` — y protección de ramas del lado del servidor.)

**A2.3** — El tag (específicamente un tag anotado, y por convención nunca movido) es la versión inmutable; `main` es un puntero móvil. Desplegar `HEAD` de `main` significa que la versión desplegada cambia cada vez que alguien mergea — no podés afirmar "producción corre v1.0.0", solo "producción corre lo que fuera main en la última sincronización", y un merge sin revisar se despliega solo. Los sistemas de producción fijan los releases a tags o SHAs de commits, y la promoción entre entornos es un cambio explícito de ese pin.

### Ejercicio 3

**A3.1** — Un **evento perdido o no recibido**. Los sistemas edge-triggered actúan solo cuando observan una notificación de cambio; si el observador está caído cuando se dispara el evento (caída, partición de red, webhook perdido), el cambio nunca se procesa y el sistema queda mal para siempre. Un bucle level-triggered recalcula la comparación completa deseado-vs-vivo en cada ciclo, así que cualquier cambio perdido se detecta en la pasada siguiente — el diseño se autocorrige después de una caída de duración arbitraria. Por esto tanto los controladores de Kubernetes como los agentes de GitOps son level-based.

**A3.2** — (1) **Drift humano**: hotfixes manuales con `kubectl`, ediciones de debugging, ajustes bien intencionados que nunca vuelven a Git. (2) **Drift del sistema**: controladores, admission webhooks, operadores o fallas que mutan/borran objetos (desalojos, jobs de limpieza de namespaces, el operador de un colega peleando por un campo). Quitar el acceso de escritura humano elimina solo la fuente (1); el clúster mismo sigue cambiando de estado, así que la reconciliación continua sigue siendo necesaria.

**A3.3** — En modo pull el reconciliador corre **dentro del clúster** (o de su límite de confianza) y las credenciales del clúster nunca salen de ahí; el único requisito saliente es acceso de lectura a Git. En modo push, un sistema de CI *fuera* del clúster tiene kubeconfig/credenciales de nivel admin, lo que significa: comprometer el CI es comprometer el clúster, las credenciales de todos los entornos se acumulan en el almacén de secretos del CI, y el clúster debe exponer su API a la red del CI. El pull invierte la confianza: Git no guarda ningún secreto capaz de escribir en el clúster, y la superficie de ataque se reduce a "¿podés lograr que se mergee un commit malicioso?" — que es exactamente la compuerta que la revisión de código ya defiende.

### Ejercicio 4

**A4.1** — Contiene un **puntero**: URL del repo, path, revisión objetivo y destino — estado deseado *acerca de* dónde vive el estado deseado. Como ambas capas son declarativas, todo el sistema de entrega es reconstruible solo desde Git: aplicás la Application (o una raíz "app-of-apps" que lista todas las Applications), y Argo CD vuelve a hacer pull y recrea todo lo que hay debajo. La recuperación ante desastres se vuelve `git clone` + un `kubectl apply`, que es el beneficio práctico de los Principios 1+2 aplicados recursivamente.

**A4.2** — `SYNC STATUS` compara los manifiestos de Git contra los objetos vivos: ¿son idénticos? `HEALTH STATUS` evalúa si los recursos vivos realmente están funcionando (Deployment progresando, réplicas disponibles, Ingress admitido, PVC vinculado). Escenario concreto de `Synced` + `Degraded`: commiteás un tag de imagen que no existe. Argo CD aplica el Deployment perfectamente — Git y el clúster coinciden, entonces `Synced` — pero los pods quedan en `ImagePullBackOff`, las réplicas nunca pasan a disponibles, y la evaluación de salud reporta `Degraded`. El paso 3 del Ejercicio 6 es exactamente este caso.

**A4.3** — El Principio 4, **reconciliado continuamente** — el sistema observó y *reportó* el drift pero no actuó sobre él (y podría argumentarse que el "traído y aplicado automáticamente" del Principio 3 está cumplido solo a medias). El campo es `spec.syncPolicy.automated` (con `selfHeal: true` extendiendo la automatización al drift del estado vivo, no solo a los commits nuevos). Hasta que se configure, Argo CD es un *detector* de drift con una compuerta manual — una configuración legítima como paso intermedio, pero no automatización GitOps completa.

### Ejercicio 5

**A5.1** — El único camino de escritura legítimo es **un commit mergeado al repositorio versionado**. Los cambios a nivel de kubectl ahora son cosméticos-hasta-que-se-reviertan. El break-glass, por lo tanto, tiene que diseñarse, no improvisarse: o un procedimiento explícito para pausar la reconciliación de la app afectada (deshabilitar `selfHeal`/automatización, actuar, después commitear el arreglo y volver a habilitar), o un camino de merge acelerado para emergencias. Un equipo que habilita `selfHeal` sin un procedimiento de break-glass documentado lo descubre a las 03:00 cuando el controlador les sigue revirtiendo la mitigación.

**A5.2** — El accidente: un refactor (mover/renombrar un path, un render defectuoso de Kustomize/Helm, el borrado accidental de un directorio) hace que ciertos objetos desaparezcan de la salida renderizada, y prune **borra los recursos vivos** — incluyendo, en el peor caso, los que tienen estado. Mitigaciones que mantienen el pruning activado: del lado de Git, revisión obligatoria + CI que renderice los manifiestos y compare la cantidad de objetos antes del merge; del lado de Argo, proteger recursos críticos con la opción de sync `Prune=false` o la anotación `argocd.argoproj.io/sync-options: Prune=false` en objetos específicos, para que el radio de impacto de un render malo los excluya.

**A5.3** — La **watch API** de Kubernetes (la maquinaria de informers/caché compartida construida sobre ella). El application controller mantiene watches abiertos sobre los tipos de recursos gestionados, así que cualquier mutación de un objeto vivo llega como un evento push en milisegundos, disparando una reevaluación — sin polling al clúster. Git, que por defecto no tiene un canal push equivalente, sigue siendo consultado por polling (por defecto cada 3 minutos) o acelerado con webhooks. Notá que la arquitectura es *disparada* por watch pero sigue siendo *basada* en nivel: el evento solo agenda una comparación completa deseado-vs-vivo, preservando la resiliencia de A3.1.

### Ejercicio 6

**A6.1** — `argocd app rollback` hace que el clúster corra un estado que **Git ya no declara** — la verdad se bifurcó: el repo dice una cosa, producción corre otra, y toda propiedad que GitOps prometía (fuente única de verdad, auditoría por historia, reproducibilidad) queda suspendida hasta que vuelvan a converger. Argo CD sabe esto, y por eso el rollback a un despliegue previo **deshabilita la sincronización automatizada** en la app (tiene que hacerlo, o la automatización volvería a desplegar inmediatamente la revisión mala). Es una palanca de emergencia. `git revert` mantiene la verdad y el clúster unificados y no necesita ningún modo especial — el rollback *es* un despliegue ordinario.

**A6.2** — **La evaluación de salud integrada en el proceso de sincronización.** Argo CD evalúa la salud por recurso (progreso del Deployment, disponibilidad de réplicas, más health checks personalizados en Lua para CRDs) y reporta `Degraded` incluso estando `Synced`. Una configuración de producción actúa sobre esto dentro de las **fases/waves de sincronización y los hooks**: los recursos se sincronizan en waves ordenadas, y una wave que falla las compuertas de salud detiene el rollout de las waves siguientes; combinado con un controlador de entrega progresiva (por ejemplo Argo Rollouts), un análisis fallido aborta y revierte el rollout automáticamente. El contrato de tu bucle de bash terminaba en "el API server lo aceptó".

**A6.3** — "Agregar un chequeo de CI previo al merge que resuelva cada referencia de imagen de contenedor en los manifiestos renderizados contra el registry (el tag existe, el digest está fijado), para que un tag inexistente haga fallar el pull request en vez del rollout." — La prevención compatible con GitOps siempre refuerza la compuerta que está delante de la fuente de verdad; para cuando el estado llega al clúster, los agentes lo despliegan sin juicio propio.

</details>