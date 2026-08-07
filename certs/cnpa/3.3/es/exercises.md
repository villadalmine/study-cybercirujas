# Ejercicios guiados — Tema 3.3: Continuous Integration Pipelines Overview and Architecture

Estos ejercicios asumen un cluster Kubernetes de laboratorio (`kind`, `minikube` o similar) con `kubectl` configurado, y acceso a un registry OCI (puede ser uno local con `kind` + `registry:2`, o `ghcr.io`). Cuando un comando requiere credenciales o un registry real, el ejercicio lo indica y ofrece una alternativa local.

El objetivo del tema es **arquitectura**: no memorizar la sintaxis de un CI concreto, sino entender qué hace cada etapa, dónde corre, con qué privilegios, qué produce y cómo se encadena. Los ejemplos usan Tekton (el proyecto CNCF de CI/CD declarativo nativo de Kubernetes) porque expone esa arquitectura como recursos observables, pero las preguntas de comprensión son transferibles a GitHub Actions, GitLab CI o Argo Workflows.

---

## Ejercicio 1 — Anatomía de las etapas de un pipeline de CI

Antes de ejecutar nada, vas a leer una definición de pipeline y descomponerla en su arquitectura lógica. La CI resuelve un problema concreto: **integrar cambios de código de forma automática y frecuente**, validando en cada commit que el árbol sigue construyendo, pasando tests y produciendo un artefacto reproducible.

### Pasos

1. Guardá el siguiente pipeline de ejemplo (estilo GitLab CI, elegido por ser un único archivo legible) en `ci-example.yml`:

   ```yaml
   stages:
     - build
     - test
     - scan
     - package

   compile:
     stage: build
     script:
       - go build -o bin/app ./...
     artifacts:
       paths:
         - bin/app
       expire_in: 1 hour

   unit-tests:
     stage: test
     script:
       - go test -race -coverprofile=cover.out ./...
     coverage: '/coverage: \d+\.\d+% of statements/'

   sast:
     stage: scan
     script:
       - govulncheck ./...
     allow_failure: false

   build-image:
     stage: package
     script:
       - kaniko --dockerfile=Dockerfile --destination=$REGISTRY/app:$CI_COMMIT_SHA
   ```

2. Identificá, para cada job, **qué produce** (un binario, un reporte, una imagen) y **qué consume** del job anterior. Notá que `compile` declara `artifacts:` y `build-image` no: preguntate por qué.

3. Marcá el punto donde el pipeline **debe fallar rápido** (fail-fast) para no gastar cómputo aguas abajo, y por qué `allow_failure: false` es la decisión de política, no la técnica.

4. Observá que la imagen se etiqueta con `$CI_COMMIT_SHA` y no con `latest`. Esa es una decisión de arquitectura sobre **trazabilidad e inmutabilidad**, no una preferencia estética.

**Preguntas de comprensión**

- 1a. ¿Cuál es la diferencia entre un *artifact* (como `bin/app`) y el *estado del workspace* entre jobs? ¿Por qué GitLab exige declarar los artifacts explícitamente en lugar de arrastrar todo el filesystem?
- 1b. Si `unit-tests` falla, ¿debería ejecutarse `sast`? Justificá en términos de coste de cómputo y de la definición misma de CI.
- 1c. ¿Por qué etiquetar la imagen con el commit SHA en lugar de `latest` es un requisito de arquitectura para poder hacer rollback y auditoría, y no solo una buena práctica?

---

## Ejercicio 2 — Build de imágenes *daemonless* dentro del cluster (Kaniko)

Un pipeline de CI que corre **dentro** de Kubernetes tiene un problema arquitectónico clásico: para construir una imagen OCI tradicionalmente necesitás el daemon de Docker, y montarle el socket (`/var/run/docker.sock`) a un contenedor equivale a darle root sobre el nodo. La solución nativa cloud es construir **sin daemon**: Kaniko, Buildah o `ko` construyen la imagen en user-space, capa por capa, y la empujan directo al registry.

### Pasos

1. Creá un `Dockerfile` mínimo y trivial de construir:

   ```dockerfile
   FROM alpine:3.20
   RUN echo "built in CI" > /etc/build-marker
   ENTRYPOINT ["cat", "/etc/build-marker"]
   ```

2. Poné a correr un registry local accesible desde el cluster (si usás `kind`, esto ya suele estar disponible en `localhost:5001`). Para minikube:

   ```bash
   kubectl create deployment registry --image=registry:2 --port=5000
   kubectl expose deployment registry --port=5000
   ```

3. Definí un Pod de Kaniko. Fijate que **no monta el socket de Docker** y que las credenciales del registry van en `/kaniko/.docker/config.json`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: kaniko-build
   spec:
     restartPolicy: Never
     containers:
       - name: kaniko
         image: gcr.io/kaniko-project/executor:v1.23.2
         args:
           - "--dockerfile=Dockerfile"
           - "--context=dir:///workspace"
           - "--destination=registry.default.svc.cluster.local:5000/demo:1.0.0"
           - "--insecure"          # solo para registry local sin TLS
         volumeMounts:
           - name: build-context
             mountPath: /workspace
     volumes:
       - name: build-context
         emptyDir: {}
   ```

   > Para un registry real usarías un `Secret` de tipo `kubernetes.io/dockerconfigjson` montado en `/kaniko/.docker/` y quitarías `--insecure`. El `emptyDir` de arriba está vacío a propósito: en un pipeline real, un Step previo (git clone) llena `/workspace`. Aquí el foco es el modelo de ejecución, no el contexto.

4. Aplicá el Pod y seguí sus logs:

   ```bash
   kubectl apply -f kaniko-build.yaml
   kubectl logs -f pod/kaniko-build
   ```

   Salida esperada (recortada):

   ```
   INFO[0000] Retrieving image manifest alpine:3.20
   INFO[0002] Building stage 'alpine:3.20' [idx: '0', base-idx: '-1']
   INFO[0003] Executing 0 build triggers
   INFO[0003] RUN echo "built in CI" > /etc/build-marker
   INFO[0004] Taking snapshot of full filesystem...
   INFO[0005] Pushing image to registry.default.svc.cluster.local:5000/demo:1.0.0
   INFO[0007] Pushed image to 1 destinations
   ```

5. Confirmá que el Pod corrió **sin privilegios de nodo**: no hubo `hostPath`, ni socket, ni `privileged: true`.

**Preguntas de comprensión**

- 2a. ¿Por qué montar `/var/run/docker.sock` en un contenedor de CI es equivalente a darle acceso root al nodo? ¿Qué operación puede hacer un atacante con ese socket?
- 2b. Kaniko toma "snapshots del filesystem" tras cada instrucción del Dockerfile. ¿Qué componente de la imagen OCI está construyendo con eso, y por qué ese diseño le permite prescindir del daemon de Docker?
- 2c. En este Pod, ¿dónde busca Kaniko las credenciales para empujar al registry, y qué tipo de objeto de Kubernetes usarías para inyectarlas en un entorno de producción?

---

## Ejercicio 3 — Arquitectura de Tekton: Step → Task → Pipeline → Run

Tekton modela cada concepto de la CI como un recurso de Kubernetes (CRD). Entender su jerarquía es entender la arquitectura de cualquier CI declarativo: la **definición** (reutilizable, versionada en Git) se separa de la **ejecución** (una instancia concreta, con estado, logs y resultado).

| Recurso | Rol | Análogo |
|---|---|---|
| `Step` | Un contenedor con un comando | Un job/script |
| `Task` | Secuencia de Steps → **un solo Pod** | Una etapa |
| `Pipeline` | DAG de Tasks | El pipeline completo |
| `TaskRun` / `PipelineRun` | Ejecución con estado de un Task/Pipeline | El "run" nº 42 |
| `Workspace` | Volumen compartido entre Tasks | Los artifacts/cache |
| `Results` | Valor de salida pasado entre Tasks | Variable de salida |

### Pasos

1. Instalá Tekton Pipelines y esperá a que el controller esté listo:

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
   kubectl -n tekton-pipelines rollout status deploy/tekton-pipelines-controller
   ```

2. Definí un `Task` con dos Steps. Observá que ambos Steps corren en el **mismo Pod** y por eso comparten el filesystem sin necesidad de un volumen explícito:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: build-info
   spec:
     params:
       - name: revision
         type: string
         default: "main"
     results:
       - name: commit-short
         description: "SHA corto derivado del parámetro"
     steps:
       - name: prepare
         image: alpine:3.20
         script: |
           #!/bin/sh
           echo "Preparando build de la revisión $(params.revision)"
           echo -n "$(params.revision)" | cut -c1-7 | tr -d '\n' > $(results.commit-short.path)
       - name: report
         image: alpine:3.20
         script: |
           #!/bin/sh
           echo "Step 2 ve lo que dejó el Step 1 (mismo Pod)"
   ```

3. Ejecutá el Task pasándole un parámetro. Un `TaskRun` es la **instancia de ejecución**:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: TaskRun
   metadata:
     generateName: build-info-run-
   spec:
     taskRef:
       name: build-info
     params:
       - name: revision
         value: "a1b2c3d4e5f6"
   ```

   ```bash
   kubectl create -f build-info-run.yaml
   ```

4. Inspeccioná la ejecución. Fijate que el `TaskRun` guarda estado y el `Result`:

   ```bash
   kubectl get taskruns
   kubectl get taskrun <nombre> -o jsonpath='{.status.results[0].value}{"\n"}'
   ```

   Salida esperada:

   ```
   a1b2c3
   ```

5. Ahora observá el Pod que el controller creó por debajo. **Esta es la clave arquitectónica**: vos creaste un CR, y el Tekton controller lo reconcilió a un Pod real:

   ```bash
   kubectl get pods -l tekton.dev/taskRun=<nombre>
   kubectl get pod <pod> -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'
   ```

   Vas a ver contenedores con nombres `step-prepare`, `step-report` (más los init de la entrypoint que Tekton inyecta para ordenar los Steps).

**Preguntas de comprensión**

- 3a. Un `Task` corre todos sus Steps en un único Pod; un `Pipeline` corre cada `Task` en su propio Pod. ¿Qué implica eso para compartir datos *entre Steps* frente a compartir datos *entre Tasks*, y qué recurso resuelve el segundo caso?
- 3b. ¿Cuál es la diferencia entre un `Task` y un `TaskRun`, y por qué esta separación definición/ejecución es la misma idea que separar una imagen de un contenedor, o una clase de una instancia?
- 3c. Vos aplicaste un manifiesto declarativo, pero terminó corriendo un Pod imperativo. ¿Qué componente hizo esa traducción, y cómo se llama ese patrón general en Kubernetes?
- 3d. ¿Para qué sirve un `Result` de Tekton, y por qué es preferible a que un Task escriba en un `Workspace` compartido cuando lo único que necesitás pasar es un valor corto como un SHA?

---

## Ejercicio 4 — Triggers: de un evento Git a un PipelineRun

Hasta acá disparaste ejecuciones a mano. Un pipeline de CI real se dispara por **eventos**: un push, un pull request, un tag. La arquitectura de triggers tiene tres piezas que conviene no confundir, porque separan *recibir el evento*, *extraer datos de él* y *plantillar la ejecución*.

- **EventListener** — un Service + Pod que escucha webhooks HTTP entrantes.
- **TriggerBinding** — extrae campos del payload del evento (p. ej. el SHA, la rama, la URL del repo).
- **TriggerTemplate** — la plantilla que, con esos campos, genera un `PipelineRun`.

### Pasos

1. Instalá Tekton Triggers:

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
   ```

2. Definí el `TriggerBinding` (qué extraer del payload) y el `TriggerTemplate` (qué crear con eso):

   ```yaml
   apiVersion: triggers.tekton.dev/v1beta1
   kind: TriggerBinding
   metadata:
     name: git-push-binding
   spec:
     params:
       - name: git-revision
         value: $(body.head_commit.id)
       - name: git-repo-url
         value: $(body.repository.clone_url)
   ---
   apiVersion: triggers.tekton.dev/v1beta1
   kind: TriggerTemplate
   metadata:
     name: build-info-template
   spec:
     params:
       - name: git-revision
       - name: git-repo-url
     resourcetemplates:
       - apiVersion: tekton.dev/v1
         kind: TaskRun
         metadata:
           generateName: build-info-triggered-
         spec:
           taskRef:
             name: build-info
           params:
             - name: revision
               value: $(tt.params.git-revision)
   ```

3. Definí el `EventListener` que une binding + template:

   ```yaml
   apiVersion: triggers.tekton.dev/v1beta1
   kind: EventListener
   metadata:
     name: git-listener
   spec:
     serviceAccountName: default
     triggers:
       - name: on-push
         bindings:
           - ref: git-push-binding
         template:
           ref: build-info-template
   ```

   > En producción, el `EventListener` lleva además un **interceptor** (`github`, `gitlab`, `cel`) que valida la firma HMAC del webhook y filtra por tipo de evento o rama. Sin eso, cualquiera que alcance el endpoint puede disparar builds.

4. Aplicá todo y exponé el EventListener localmente:

   ```bash
   kubectl apply -f triggers.yaml
   kubectl get svc el-git-listener
   kubectl port-forward svc/el-git-listener 8080:8080
   ```

5. Simulá el webhook que enviaría GitHub en un push, con un payload mínimo:

   ```bash
   curl -X POST http://localhost:8080 \
     -H 'Content-Type: application/json' \
     -d '{
       "head_commit": { "id": "deadbeef1234567890" },
       "repository": { "clone_url": "https://github.com/org/repo.git" }
     }'
   ```

   Respuesta esperada del EventListener:

   ```json
   {"eventListener":"git-listener","namespace":"default","eventListenerUID":"...","eventID":"..."}
   ```

6. Confirmá que el evento creó un nuevo `TaskRun` **automáticamente**, con la revisión extraída del payload:

   ```bash
   kubectl get taskruns -l triggers.tekton.dev/eventlistener=git-listener
   ```

**Preguntas de comprensión**

- 4a. Separá responsabilidades: ¿qué hace el `TriggerBinding` que **no** hace el `TriggerTemplate`, y por qué esta separación permite reusar la misma plantilla de PipelineRun con eventos de distintos proveedores (GitHub, GitLab, Gitea)?
- 4b. El `EventListener` es un endpoint HTTP expuesto. ¿Qué riesgo de seguridad introduce eso y qué componente (nombrado en el paso 3) lo mitiga validando el origen del evento?
- 4c. En CI, se distingue *push-based* (el sistema de CI reacciona a un webhook) de *poll-based* (el sistema consulta el repo cada X minutos). ¿A cuál corresponde esta arquitectura, y qué ventajas de latencia y de coste tiene frente a la otra?

---

## Ejercicio 5 — El pipeline como *quality gate*: SBOM y firma de la imagen

"Overview and Architecture" incluye entender que la CI moderna no solo construye: **decide si el artefacto tiene derecho a existir**. Dos etapas que hoy son estándar en cloud native: generar un SBOM (inventario de dependencias) y firmar la imagen para probar su procedencia. Ambas son etapas del pipeline como cualquier build o test.

### Pasos

1. Generá un SBOM de la imagen que construiste en el Ejercicio 2 (o de cualquier imagen local), con Syft:

   ```bash
   syft registry.default.svc.cluster.local:5000/demo:1.0.0 -o spdx-json=sbom.spdx.json
   ```

   Salida esperada (recortada):

   ```
    ✔ Parsed image
    ✔ Cataloged contents
      └── Packages          [15 packages]
   ```

2. Escaneá ese SBOM (o la imagen directamente) buscando vulnerabilidades conocidas con Grype. Este es el paso que **puede reprobar el gate**:

   ```bash
   grype sbom:sbom.spdx.json --fail-on high
   echo "exit code: $?"
   ```

   Si hay una vuln de severidad `high` o mayor, `grype` sale con código distinto de cero y, en un pipeline, la etapa falla y el artefacto no avanza.

3. Firmá la imagen con Cosign en modo *keyless* (identidad OIDC, sin gestionar claves privadas; firma y transparencia van a Fulcio y Rekor de Sigstore):

   ```bash
   COSIGN_EXPERIMENTAL=1 cosign sign registry.example.com/demo:1.0.0
   ```

4. Verificá la firma. Esto es lo que un *admission controller* (p. ej. Kyverno o la policy de Sigstore) ejecutaría en el cluster **antes** de admitir el Pod:

   ```bash
   cosign verify registry.example.com/demo:1.0.0 \
     --certificate-identity=<tu-identidad-oidc> \
     --certificate-oidc-issuer=https://token.actions.githubusercontent.com
   ```

5. Cerrá el círculo mental: SBOM → scan → build → sign son **etapas de pipeline**, no herramientas sueltas. El pipeline es el punto de control único donde procedencia, dependencias y política se aplican de forma reproducible en cada commit.

**Preguntas de comprensión**

- 5a. ¿Qué es un SBOM y por qué generarlo *en el pipeline*, en el mismo momento del build, es más fiable que escanear la imagen semanas después en el registry?
- 5b. En modo *keyless*, Cosign no usa una clave privada de larga vida. ¿De dónde saca entonces la identidad para firmar, y qué componente de Sigstore deja un registro público e inmutable de que la firma ocurrió?
- 5c. La firma se produce en la CI, pero la verificación ocurre en el momento del *deploy*. ¿Qué componente de Kubernetes hace cumplir la política de "solo imágenes firmadas por una identidad de confianza pueden correr", y por qué la CI por sí sola no puede garantizar eso?

---

## Respuestas

<details>
<summary>Ver soluciones y justificaciones</summary>

### Ejercicio 1

- **1a.** Un *artifact* es un conjunto de archivos que declarás explícitamente para que persista y esté disponible en jobs posteriores o para descarga; el *estado del workspace* (el directorio de trabajo completo) no se propaga automáticamente entre jobs porque cada job suele correr en un runner efímero y limpio. GitLab exige declararlos porque arrastrar el filesystem completo sería caro (subir/bajar todo a cada paso), no reproducible y poco explícito sobre qué es realmente el output de la etapa. Declarar artifacts hace el flujo de datos auditable.
- **1b.** No. Si `unit-tests` falla, ejecutar `sast` desperdicia cómputo sobre un árbol que ya sabemos que está roto. El principio es *fail-fast*: la CI existe para dar feedback rápido y barato; encadenar etapas tras un fallo contradice esa definición. La excepción consciente es cuando querés recolectar *todos* los fallos de una vez para el desarrollador, pero eso es una decisión deliberada, no el default.
- **1c.** Porque `latest` es una etiqueta mutable: dos builds distintos pueden apuntar al mismo tag, así que "la imagen que está en prod" deja de ser identificable. Etiquetar con el commit SHA hace que cada imagen sea **inmutable y trazable** a un punto exacto del historial de código: podés hacer rollback a una versión específica, correlacionar un incidente en runtime con el commit que lo introdujo, y garantizar que lo que se testeó es exactamente lo que se despliega. Es un requisito de arquitectura para la trazabilidad de la cadena de suministro, no un detalle cosmético.

### Ejercicio 2

- **2a.** El daemon de Docker corre como root en el nodo y el socket es su API completa. Un contenedor con acceso al socket puede pedirle al daemon que lance **otro** contenedor con `privileged: true`, con `hostPath` montando `/` del nodo, o con el namespace del host — obteniendo así control total del nodo y, por extensión, del cluster. Montar el socket rompe el aislamiento del contenedor por completo.
- **2b.** Está construyendo las **capas (layers)** de la imagen OCI: cada instrucción que modifica el filesystem produce una capa, y Kaniko toma un snapshot del filesystem para calcular el diff que constituye esa capa. Como Kaniko ejecuta las instrucciones y calcula los diffs en user-space dentro de su propio contenedor (sin pedirle a un daemon que lo haga), no necesita el daemon de Docker ni privilegios sobre el nodo.
- **2c.** En `/kaniko/.docker/config.json`. En producción se inyecta con un `Secret` de tipo `kubernetes.io/dockerconfigjson` montado como volumen en `/kaniko/.docker/` (o vía credential helpers para registries en la nube). En el ejemplo local se omitió porque el registry corre sin autenticación y con `--insecure`.

### Ejercicio 3

- **3a.** Como todos los Steps de un `Task` comparten el mismo Pod, comparten el filesystem del Pod automáticamente: un Step escribe un archivo y el siguiente lo lee sin configuración extra. Entre `Tasks`, en cambio, cada uno corre en su propio Pod (posiblemente en otro nodo), así que no comparten filesystem; para pasar datos hay que usar un `Workspace` (un volumen —típicamente un PVC— montado en ambos Tasks) o, para valores chicos, `Results`.
- **3b.** El `Task` es la **definición** reutilizable y versionada en Git (qué Steps, qué imágenes, qué params); el `TaskRun` es una **instancia de ejecución** concreta con estado, timestamps, logs y resultado. Es la misma relación que imagen↔contenedor o clase↔instancia: una plantilla inmutable frente a una ejecución con estado. Separar ambas permite reejecutar, auditar cada run por separado y versionar la definición sin tocar el historial de ejecuciones.
- **3c.** Lo hizo el **Tekton controller** (que corre en `tekton-pipelines`). El patrón general es el **controller/operator pattern** (bucle de reconciliación): un controlador observa el estado deseado declarado en un CR y actúa para converger el estado real hacia él — aquí, creando y supervisando el Pod que ejecuta los Steps.
- **3d.** Un `Result` transporta un valor pequeño de salida de un Task hacia otros Tasks del Pipeline (o hacia el status del Run). Es preferible a un Workspace compartido para un dato corto como un SHA porque no requiere aprovisionar ni montar un volumen, queda registrado en el `status` del run (observable con `kubectl`/`tkn`) y expresa explícitamente la dependencia de datos en el DAG. Los Workspaces se reservan para datos grandes (código fuente, cachés, binarios).

### Ejercicio 4

- **4a.** El `TriggerBinding` **extrae** valores del payload del evento (mapea `body.head_commit.id` → `git-revision`, etc.); el `TriggerTemplate` **genera** el recurso a ejecutar (el `TaskRun`/`PipelineRun`) usando esos valores como parámetros. La separación permite escribir un binding distinto por proveedor —porque el JSON de GitHub, GitLab y Gitea difiere— y reutilizar la misma plantilla de ejecución con todos ellos: la forma del evento se desacopla de la forma del build.
- **4b.** Al ser un endpoint HTTP público, cualquiera que lo alcance podría disparar builds arbitrarios (abuso de cómputo, o inyección de datos maliciosos en el payload). Lo mitiga un **interceptor** (`github`/`gitlab`/`cel`): valida la firma HMAC del webhook contra un secreto compartido, verificando que el evento realmente proviene del proveedor esperado, y filtra por tipo de evento o rama antes de crear cualquier Run.
- **4c.** Es *push-based*: el proveedor Git empuja el evento al `EventListener` vía webhook. Frente a *poll-based*, tiene **menor latencia** (el build arranca en el instante del push, no en el próximo ciclo de sondeo) y **menor coste** (no hay consultas periódicas gastando llamadas a la API del repo y cómputo cuando no hay cambios). El coste es que requiere un endpoint accesible desde el proveedor y su correspondiente securización.

### Ejercicio 5

- **5a.** Un SBOM (Software Bill of Materials) es el inventario completo de componentes y dependencias que contiene el artefacto —paquetes, versiones, licencias—. Generarlo en el pipeline, en el momento exacto del build, garantiza que refleja **precisamente** lo que se construyó: mismas versiones, mismas capas base, mismo contexto. Escanear después en el registry puede perder información de procedencia (cómo se armó) y sufre *drift* respecto de lo que realmente se compiló; además, el gate del pipeline puede detener un artefacto vulnerable antes de que llegue al registry, en lugar de descubrirlo cuando ya está desplegado.
- **5b.** La identidad viene de un **token OIDC** de corta vida del entorno de CI (por ejemplo, el token de identidad de GitHub Actions o el del proveedor OIDC configurado). Cosign lo presenta a **Fulcio**, que emite un certificado efímero atado a esa identidad para firmar. El registro público e inmutable de que la firma ocurrió lo mantiene **Rekor**, el log de transparencia de Sigstore. Así no hay claves privadas de larga vida que custodiar o que se puedan filtrar.
- **5c.** Lo hace cumplir un **admission controller** en el cluster (p. ej. Kyverno, o el policy-controller de Sigstore) mediante una `ValidatingAdmissionWebhook`: intercepta la creación de Pods y rechaza las imágenes que no tengan una firma válida de una identidad de confianza. La CI por sí sola no puede garantizarlo porque solo **produce** el artefacto firmado; nada impide que alguien intente desplegar en el cluster una imagen no firmada por otro camino. La garantía requiere aplicar la política **en el punto de admisión**, en runtime, no en el punto de construcción.

</details>

---

### Fuentes oficiales

- CNCF — *Cloud Native Platform Engineering Associate (CNPA) Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Tekton — *Pipelines Documentation* (Tasks, Pipelines, TaskRuns, PipelineRuns, Workspaces, Results): https://tekton.dev/docs/pipelines/
- Tekton — *Triggers Documentation* (EventListener, TriggerBinding, TriggerTemplate, Interceptors): https://tekton.dev/docs/triggers/
- Kaniko — *Building Images In Kubernetes*: https://github.com/GoogleContainerTools/kaniko
- Sigstore Cosign — *Signing and Verification*: https://docs.sigstore.dev/cosign/signing/overview/
- Anchore Syft — *SBOM Generation*: https://github.com/anchore/syft
- Anchore Grype — *Vulnerability Scanning*: https://github.com/anchore/grype