# Argo Workflows — Ejercicios guiados (CAPA, Dominio 2.1)

> **Formato.** Cada ejercicio es una secuencia numerada de comandos y manifiestos que ejecutás contra un cluster real. Después de cada bloque hay **verificaciones de comprensión**. Todas las respuestas están reunidas en la sección plegable al final.
>
> **Fuentes de referencia**
> - Currículum CNCF CAPA — https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
> - Documentación de Argo Workflows — https://argo-workflows.readthedocs.io/en/latest/
> - Referencia de campos del CRD Workflow — https://argo-workflows.readthedocs.io/en/latest/fields/

---

## Prerequisitos — instalar el controlador y la CLI

Necesitás un cluster de Kubernetes en ejecución (kind, minikube, k3d, o uno real) y `kubectl` apuntando a él.

### Pasos

1. Creá el namespace `argo` e instalá los manifiestos *quick-start* (incluye el workflow-controller, la API/UI del argo-server y un repositorio de artefactos MinIO):

   ```bash
   kubectl create namespace argo
   kubectl apply -n argo -f \
     https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/quick-start-minimal.yaml
   ```

2. Esperá a que el control plane quede listo:

   ```bash
   kubectl -n argo rollout status deploy/workflow-controller
   kubectl -n argo get pods
   ```

   Esperado (ilustrativo):

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   argo-server-6b8c9c8f7d-2xk4p           1/1     Running   0          40s
   minio-7d7c8f9c5b-nq7wm                 1/1     Running   0          40s
   workflow-controller-5f9c7b8d6c-lm2vq   1/1     Running   0          40s
   ```

3. Instalá la CLI `argo` (se muestra Linux amd64; usá la de tu plataforma):

   ```bash
   curl -sLO https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/argo-linux-amd64.gz
   gunzip argo-linux-amd64.gz
   chmod +x argo-linux-amd64
   sudo mv argo-linux-amd64 /usr/local/bin/argo
   argo version --short
   ```

   ```
   argo: v3.5.8
   ```

4. Configurá el namespace por defecto para poder omitir `-n argo` en los comandos siguientes:

   ```bash
   kubectl config set-context --current --namespace=argo
   ```

### Verificaciones de comprensión

- **Q1.** La instalación creó tres componentes de larga duración. ¿Cuál de ellos realmente *reconcilia* los objetos `Workflow` en Pods, y cuál es opcional para ejecutar workflows desde la CLI?
- **Q2.** Argo define sus objetos (`Workflow`, `WorkflowTemplate`, `CronWorkflow`, …) como CRDs bajo el grupo de API `argoproj.io/v1alpha1`. ¿Qué te dice eso sobre cómo se relacionan `argo submit` y `kubectl create -f workflow.yaml`?

---

## Ejercicio 1 — Tu primer `Workflow`: entrypoint y el template `container`

### Pasos

1. Creá `hello.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: hello-world-      # server appends a random suffix
   spec:
     entrypoint: main                 # which template to run first
     templates:
       - name: main
         container:
           image: busybox
           command: [echo]
           args: ["hello world"]
   ```

2. Enviálo y transmití el árbol de nodos hasta que termine:

   ```bash
   argo submit --watch hello.yaml
   ```

   Esperado (fotograma final, ilustrativo):

   ```
   Name:                hello-world-9d4qk
   Namespace:           argo
   ServiceAccount:      unset (will run with the default ServiceAccount)
   Status:              Succeeded
   Conditions:
    PodRunning          False
    Completed           True
   Created:             Wed Aug 12 10:03:11 +0000 (30 seconds ago)
   Started:             Wed Aug 12 10:03:11 +0000 (30 seconds ago)
   Finished:            Wed Aug 12 10:03:21 +0000 (20 seconds ago)
   Duration:            10 seconds
   Progress:            1/1

   STEP                    TEMPLATE  PODNAME            DURATION  MESSAGE
    ✔ hello-world-9d4qk    main      hello-world-9d4qk  8s
   ```

3. Listálo e inspeccionálo, luego leé los logs del container:

   ```bash
   argo list
   argo get @latest          # @latest is the most recently submitted workflow
   argo logs @latest
   ```

   ```
   hello-world-9d4qk: hello world
   ```

4. Mirá cómo el workflow se mapea a Kubernetes por debajo:

   ```bash
   kubectl get wf                          # 'wf' is the short name for workflows
   kubectl get pods -l workflows.argoproj.io/workflow=hello-world-9d4qk
   ```

### Verificaciones de comprensión

- **Q3.** Usaste `generateName` en lugar de `name`. ¿Qué se rompe si enviás el mismo archivo dos veces con `name: hello-world`, y por qué `generateName` lo evita?
- **Q4.** Un `Workflow` tiene muchos `templates` pero ejecutó solo uno. ¿Cuál es el rol exacto de `spec.entrypoint`, y cuántos Pods creó este workflow?
- **Q5.** La salida mostró `ServiceAccount: unset (will run with the default ServiceAccount)`. ¿Por qué el *executor* necesita permisos siquiera — qué hace que un simple `echo` no hace?

---

## Ejercicio 2 — `steps`: grupos secuenciales y fan-out paralelo

El template `steps` es una **lista de listas**. La lista externa se ejecuta **secuencialmente**; los ítems dentro de la misma lista interna se ejecutan **en paralelo**.

### Pasos

1. Creá `steps.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: steps-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: one            # group 1
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step one"}]
           - - name: two-a          # group 2 — two-a and two-b run together
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step two-a"}]
             - name: two-b
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step two-b"}]

       - name: echo
         inputs:
           parameters:
             - name: msg
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Enviálo y observá el orden en el árbol:

   ```bash
   argo submit --watch steps.yaml
   ```

   Forma esperada (ilustrativa):

   ```
   STEP            TEMPLATE  PODNAME             DURATION  MESSAGE
    ● steps-abc12  main
    ├─✔ one        echo      steps-abc12-1  6s
    ├─✔ two-a      echo      steps-abc12-2  5s
    └─✔ two-b      echo      steps-abc12-3  5s
   ```

3. Confirmá que los dos Pods del segundo grupo se solaparon en el tiempo:

   ```bash
   kubectl get pods -l workflows.argoproj.io/workflow=$(argo get @latest -o json | \
     jq -r .metadata.name) -o wide --sort-by=.status.startTime
   ```

### Verificaciones de comprensión

- **Q6.** Reescribí el YAML mentalmente para que `two-a` y `two-b` se ejecuten **uno tras otro** en lugar de juntos. ¿Qué caracteres cambiás, y nada más?
- **Q7.** El template `echo` se declara una vez pero se invoca tres veces con distintos `arguments.parameters`. Distinguí `inputs.parameters` (en el invocado) de `arguments.parameters` (en el invocador). ¿Cuál es la "firma de la función" y cuál el "sitio de llamada"?

---

## Ejercicio 3 — `dag`: grafos de dependencias (el diamante)

Un template `dag` declara `tasks` con `dependencies`. El controlador ejecuta una tarea en cuanto **todas** sus dependencias tuvieron éxito, maximizando el paralelismo.

### Pasos

1. Creá `dag-diamond.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: dag-diamond-
   spec:
     entrypoint: diamond
     templates:
       - name: diamond
         dag:
           tasks:
             - name: A
               template: echo
               arguments: {parameters: [{name: msg, value: A}]}
             - name: B
               dependencies: [A]
               template: echo
               arguments: {parameters: [{name: msg, value: B}]}
             - name: C
               dependencies: [A]
               template: echo
               arguments: {parameters: [{name: msg, value: C}]}
             - name: D
               dependencies: [B, C]
               template: echo
               arguments: {parameters: [{name: msg, value: D}]}

       - name: echo
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Enviálo y observá:

   ```bash
   argo submit --watch dag-diamond.yaml
   ```

   Esperado (ilustrativo):

   ```
   STEP                 TEMPLATE  PODNAME               DURATION
    ● dag-diamond-x7q2  diamond
    ├─✔ A               echo      dag-diamond-x7q2-1  6s
    ├─✔ B               echo      dag-diamond-x7q2-2  5s
    ├─✔ C               echo      dag-diamond-x7q2-3  5s
    └─✔ D               echo      dag-diamond-x7q2-4  6s
   ```

### Verificaciones de comprensión

- **Q8.** En términos de tiempo real (wall-clock), ¿en qué orden se ejecutaron `B` y `C` entre sí, y por qué `D` tiene garantizado ser el último?
- **Q9.** Podés expresar este mismo diamante con un template `steps`. ¿Cuál es la ventaja práctica de `dag` cuando el grafo es amplio e irregular (digamos 30 tareas con dependencias dispersas)?
- **Q10.** Si la tarea `C` **falla**, ¿qué le pasa a `D` y a `B` por defecto? (Considerá la semántica de fallo de `depends`.)

---

## Ejercicio 4 — Parámetros: resultados de `script` y parámetros de salida

Los templates `script` ejecutan código fuente en línea y capturan **stdout** como `outputs.result`. También podés emitir un **parámetro de salida** desde un archivo mediante `valueFrom.path`.

### Pasos

1. Creá `params.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: params-
   spec:
     entrypoint: main
     arguments:
       parameters:
         - name: seed
           value: "42"
     templates:
       - name: main
         steps:
           - - name: generate
               template: gen
           - - name: consume
               template: print
               arguments:
                 parameters:
                   - name: value
                     value: "{{steps.generate.outputs.result}}"

       - name: gen
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import random
             random.seed({{workflow.parameters.seed}})
             print(random.randint(1, 100))

       - name: print
         inputs:
           parameters: [{name: value}]
         container:
           image: busybox
           command: [sh, -c]
           args: ["echo got value {{inputs.parameters.value}}"]
   ```

2. Enviálo y leé el valor propagado:

   ```bash
   argo submit --watch params.yaml
   argo logs @latest
   ```

   ```
   params-k2m9x-2: got value 82
   ```

3. Sobrescribí el parámetro de nivel superior al momento de enviar:

   ```bash
   argo submit --watch params.yaml -p seed=7
   argo logs @latest
   ```

### Verificaciones de comprensión

- **Q11.** Rastreá los tres alcances (scopes) de parámetros usados aquí: `{{workflow.parameters.seed}}`, `{{steps.generate.outputs.result}}`, `{{inputs.parameters.value}}`. ¿En qué orden se sustituye cada uno de estos, y por quién?
- **Q12.** `outputs.result` capturó el número porque el script lo imprimió en stdout. Si en cambio escribieras el número en `/tmp/out` dentro de un template `container`, ¿qué bloque `outputs.parameters` lo expondría, y por qué el atajo `result` solo está disponible en los templates `script` (y `container`)?
- **Q13.** `-p seed=7` sobrescribió `spec.arguments.parameters`. ¿Dónde establecerías un *valor por defecto* que aplique cuando ni `-p` ni `arguments` proveen un valor?

---

## Ejercicio 5 — Artefactos: pasar archivos entre steps

Los parámetros transportan cadenas pequeñas; los **artefactos** transportan archivos/directorios, almacenados en un repositorio de artefactos (aquí, el MinIO que instaló el quick-start).

### Pasos

1. Creá `artifacts.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: artifact-passing-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: generate
               template: whalesay
           - - name: consume
               template: print-message
               arguments:
                 artifacts:
                   - name: message
                     from: "{{steps.generate.outputs.artifacts.hello-art}}"

       - name: whalesay
         container:
           image: docker/whalesay:latest
           command: [sh, -c]
           args: ["cowsay hello world | tee /tmp/hello_world.txt"]
         outputs:
           artifacts:
             - name: hello-art
               path: /tmp/hello_world.txt

       - name: print-message
         inputs:
           artifacts:
             - name: message
               path: /tmp/message      # controller mounts the artifact here
         container:
           image: busybox
           command: [sh, -c]
           args: ["cat /tmp/message"]
   ```

2. Enviálo y confirmá que el archivo cruzó el límite del Pod:

   ```bash
   argo submit --watch artifacts.yaml
   argo logs @latest | grep -A6 hello
   ```

3. Inspeccioná dónde Argo almacenó el artefacto:

   ```bash
   argo get @latest -o json | jq '.status.nodes[] | select(.outputs.artifacts) |
     {node: .displayName, artifacts: .outputs.artifacts}'
   ```

### Verificaciones de comprensión

- **Q14.** El step `generate` corrió en un Pod y `consume` en otro. Explicá, paso a paso, cómo los bytes llegaron de `/tmp/hello_world.txt` en el primer Pod a `/tmp/message` en el segundo — ¿qué comprime/sube y qué descarga?
- **Q15.** Si no hubiera configurado ningún repositorio de artefactos, este workflow fallaría en la etapa de *salida*. ¿Dónde se configura el repositorio de artefactos por defecto a nivel de cluster, y qué campo en un artefacto te permite sobrescribir el destino por artefacto?

---

## Ejercicio 6 — Bucles (`withItems`, `withParam`) y condicionales (`when`)

### Pasos

1. Bucle estático con `withItems`, luego un bucle dinámico con `withParam` alimentado por la salida JSON de un step. Creá `loops.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: loops-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: static-loop
               template: echo
               arguments: {parameters: [{name: msg, value: "{{item}}"}]}
               withItems: [cat, dog, fox]

           - - name: gen-list
               template: make-list
           - - name: dynamic-loop
               template: echo
               arguments: {parameters: [{name: msg, value: "{{item}}"}]}
               withParam: "{{steps.gen-list.outputs.result}}"

       - name: make-list
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import json
             print(json.dumps(["alpha", "beta"]))

       - name: echo
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Enviálo y contá el fan-out:

   ```bash
   argo submit --watch loops.yaml
   argo get @latest    # note the (0), (1), (2)… iteration nodes
   ```

3. Ahora un condicional. Creá `coinflip.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: coinflip-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: flip
               template: flip-coin
           - - name: heads
               template: say
               when: "{{steps.flip.outputs.result}} == heads"
               arguments: {parameters: [{name: msg, value: "it was heads"}]}
             - name: tails
               template: say
               when: "{{steps.flip.outputs.result}} == tails"
               arguments: {parameters: [{name: msg, value: "it was tails"}]}

       - name: flip-coin
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import random
             print("heads" if random.random() > 0.5 else "tails")

       - name: say
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

4. Enviálo unas cuantas veces y notá que una rama se omite en cada ejecución:

   ```bash
   argo submit --watch coinflip.yaml
   argo get @latest    # one of heads/tails shows as Skipped
   ```

### Verificaciones de comprensión

- **Q16.** `withItems` y `withParam` ambos hacen fan-out del mismo template. ¿Cuál es la diferencia esencial en *cuándo* se conoce la cardinalidad del bucle — tiempo de autoría vs. tiempo de ejecución — y qué restricción impone eso sobre la cadena que recibe `withParam`?
- **Q17.** En `coinflip.yaml`, la rama omitida aparece como `Skipped`, no `Failed`. ¿Por qué un `when` que evalúa a falso **no** hace fallar el workflow, y qué ve un step posterior como la fase de ese nodo?
- **Q18.** `{{item}}` hizo referencia al elemento actual del bucle. Si los ítems fueran **objetos** como `{"name": "a", "port": 80}`, ¿qué expresión extraería solo el port dentro de los arguments del template?

---

## Ejercicio 7 — Resiliencia: `retryStrategy` y handlers `onExit`

### Pasos

1. Creá `retry-exit.yaml` — un container que falla ~70% de las veces, reintentado con backoff exponencial, más un exit handler que siempre se ejecuta:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: retry-exit-
   spec:
     entrypoint: main
     onExit: notify              # runs on success OR failure
     templates:
       - name: main
         retryStrategy:
           limit: "5"
           retryPolicy: "OnFailure"     # Always | OnFailure | OnError | OnTransientError
           backoff:
             duration: "2"              # seconds
             factor: "2"                # 2s, 4s, 8s, …
             maxDuration: "1m"
         container:
           image: python:alpine3.6
           command: [python, -c]
           args:
             - |
               import random, sys
               sys.exit(1) if random.random() < 0.7 else print("succeeded")

       - name: notify
         container:
           image: busybox
           command: [sh, -c]
           args:
             - "echo workflow {{workflow.name}} finished with status {{workflow.status}}"
   ```

2. Enviálo y observá cómo se acumulan los nodos de reintento:

   ```bash
   argo submit --watch retry-exit.yaml
   argo get @latest      # note (1), (2), (3)… retry attempts under the main node
   ```

3. Leé el log del exit handler:

   ```bash
   argo logs @latest | grep finished
   ```

   ```
   retry-exit-p8w2q-onExit: workflow retry-exit-p8w2q finished with status Succeeded
   ```

### Verificaciones de comprensión

- **Q19.** Distinguí `retryPolicy: OnFailure` de `OnError`. Un Pod que el código de salida marca como fallido vs. un Pod que el *executor* no pudo iniciar (p. ej. error al descargar la imagen) — ¿qué política atrapa cuál, y por qué `Always` atrapa ambos?
- **Q20.** El exit handler imprimió `{{workflow.status}}`. Nombrá otras dos variables globales disponibles específicamente dentro de un handler `onExit` que le permiten ramificar según cómo terminó el workflow.
- **Q21.** Los reintentos y el backoff interactúan con `activeDeadlineSeconds`. Si el workflow alcanza su deadline en medio de un backoff, ¿el reintento pendiente igual se dispara? Razoná sobre qué límite es el que manda.

---

## Ejercicio 8 — Reutilización y planificación: `WorkflowTemplate` y `CronWorkflow`

### Pasos

1. Creá un `WorkflowTemplate` reutilizable en `wt.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: WorkflowTemplate
   metadata:
     name: print-message-wt
   spec:
     entrypoint: main
     arguments:
       parameters: [{name: msg, value: "default hello"}]
     templates:
       - name: main
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Registrálo y ejecutálo de dos maneras:

   ```bash
   argo template create wt.yaml
   argo template list

   # (a) submit a one-off Workflow from the template
   argo submit --from workflowtemplate/print-message-wt -p msg="from --from" --watch
   ```

   O referenciálo desde dentro de otro `Workflow` con `templateRef`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: caller-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: call
               templateRef:
                 name: print-message-wt
                 template: main
               arguments:
                 parameters: [{name: msg, value: "called via templateRef"}]
   ```

3. Ahora planificálo. Creá `cron.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: CronWorkflow
   metadata:
     name: hello-cron
   spec:
     schedule: "*/1 * * * *"           # every minute
     concurrencyPolicy: "Replace"      # Allow | Forbid | Replace
     startingDeadlineSeconds: 30
     successfulJobsHistoryLimit: 3
     failedJobsHistoryLimit: 1
     workflowSpec:
       entrypoint: main
       templates:
         - name: main
           container:
             image: busybox
             command: [sh, -c]
             args: ["echo scheduled run at $(date)"]
   ```

4. Aplicá y observá la planificación:

   ```bash
   argo cron create cron.yaml
   argo cron list
   argo cron get hello-cron
   # after a minute or two:
   argo list --prefix hello-cron
   ```

5. Limpiá cuando termines:

   ```bash
   argo cron delete hello-cron
   argo template delete print-message-wt
   ```

### Verificaciones de comprensión

- **Q22.** Compará las dos maneras de usar un `WorkflowTemplate`: `argo submit --from workflowtemplate/...` versus `templateRef` dentro de un `Workflow`. Una crea un `Workflow` independiente; la otra embebe una llamada. ¿Cuándo elegirías cada una?
- **Q23.** `concurrencyPolicy: Replace` — una ejecución todavía está en curso cuando llega el siguiente tick. ¿Qué hace el controlador, y en qué se diferenciarían `Forbid` y `Allow` en ese mismo tick?
- **Q24.** ¿Cuál es la diferencia entre un `WorkflowTemplate` y un `ClusterWorkflowTemplate`, y cómo cambia eso la forma en que un `templateRef` lo direcciona?

---

## Ejercicio 9 — Human-in-the-loop y throttling: `suspend` y `synchronization`

### Pasos

1. Un template `suspend` pausa hasta que lo reanudás (compuerta de aprobación). Creá `approval.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: approval-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: build
               template: say
               arguments: {parameters: [{name: msg, value: "building"}]}
           - - name: wait-approval
               template: approve
           - - name: deploy
               template: say
               arguments: {parameters: [{name: msg, value: "deploying"}]}

       - name: approve
         suspend: {}                  # add {duration: "20s"} for a timed pause

       - name: say
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Enviálo; se detendrá en `wait-approval`:

   ```bash
   argo submit approval.yaml
   argo get @latest        # status shows the suspend node Running/Suspended
   ```

3. Reanudálo (aquí es donde un aprobador hace clic en la UI, o llama a la API):

   ```bash
   argo resume @latest
   argo get @latest --watch
   ```

4. Ahora acotá la concurrencia con un semáforo. Primero un ConfigMap que contiene el límite:

   ```bash
   kubectl create configmap workflow-controller-configmap-sema \
     --from-literal=deploy=1 -n argo --dry-run=client -o yaml | kubectl apply -f -
   ```

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: limited-
   spec:
     entrypoint: main
     synchronization:
       semaphore:
         configMapKeyRef:
           name: workflow-controller-configmap-sema
           key: deploy               # value "1" ⇒ at most one holder at a time
     templates:
       - name: main
         container:
           image: busybox
           command: [sh, -c]
           args: ["echo holding the semaphore; sleep 20"]
   ```

5. Enviá este workflow **dos veces rápidamente** y observá cómo el segundo espera:

   ```bash
   argo submit --generate-name limited- limited.yaml
   argo submit --generate-name limited- limited.yaml
   argo list      # one Running, one Pending with a "Waiting for ... lock" message
   ```

### Verificaciones de comprensión

- **Q25.** Un nodo `suspend: {}` no ocupa ningún Pod mientras espera. ¿Por qué eso es operativamente más barato que un container que ejecuta `sleep` en un bucle sondeando la aprobación?
- **Q26.** Distinguí `synchronization.semaphore` de `synchronization.mutex`. Si fijás el valor del semáforo en `1`, ¿es equivalente a un mutex? ¿Qué puede expresar un semáforo que un mutex no puede?
- **Q27.** El semáforo/mutex se puede declarar a nivel de **workflow** o en un **template** individual. ¿Qué cambia respecto de *qué* se está throttleando cuando movés el bloque `synchronization` desde `spec` hacia un único template?

---

## Respuestas

<details>
<summary>Mostrar todas las respuestas (Q1–Q27)</summary>

**Q1.** El **workflow-controller** es el reconciliador: observa los objetos `Workflow` y crea/actualiza los Pods que ejecutan cada nodo. El **argo-server** (API + UI web) es opcional para el uso por CLI — `argo submit`/`kubectl apply` se comunican directamente con la API de Kubernetes, así que el controlador solo alcanza para ejecutar workflows. (MinIO es únicamente el backend de artefactos.)

**Q2.** Como los tipos de Argo son CRDs, un `Workflow` es un objeto de Kubernetes de primera clase. `argo submit file.yaml` y `kubectl create -f file.yaml` ambos simplemente crean el mismo recurso `Workflow` a través del API server; `argo` agrega comodidades (`--watch`, streaming de logs, `@latest`, sobrescritura de parámetros) pero el objeto que crea es idéntico. Referencia: https://argo-workflows.readthedocs.io/en/latest/workflow-concepts/

**Q3.** Con `name: hello-world`, el segundo envío colisiona con el objeto existente y la API devuelve `AlreadyExists`. `generateName` le indica al API server que agregue un sufijo aleatorio (`hello-world-9d4qk`), así que cada envío es un objeto único — el patrón idiomático para workflows que se envían repetidamente.

**Q4.** `spec.entrypoint` nombra el template que el controlador invoca primero; los demás solo se ejecutan si son alcanzados por un invocador (`steps`/`dag`) o un handler. Este workflow creó **un Pod** — un único template hoja `container` equivale a un Pod.

**Q5.** Argo inyecta un **executor** en cada Pod de workflow (el predeterminado es el executor *emissary*). El executor captura salidas (parámetros/artefactos/logs), reporta el estado del nodo, y gestiona el ciclo de vida del container principal. Por eso el ServiceAccount del Pod necesita RBAC (p. ej. para hacer patch de pods/obtener logs de pods), mientras que un simple `echo` no necesitaría nada.

**Q6.** Cambiá las dos entradas del segundo grupo de compartir una misma lista interna a ser cada una su propio ítem de la lista externa — es decir, convertí `- - name: two-a` … `  - name: two-b` (misma lista interna) en `- - name: two-a` … `- - name: two-b` (dos grupos externos separados). Misma-lista-interna ⇒ paralelo; lista-externa-separada ⇒ secuencial.

**Q7.** `inputs.parameters` en el template `echo` es la **firma** — declara los parámetros que el template requiere y sus valores por defecto. `arguments.parameters` en cada sitio de llamada es la **llamada**, vinculando valores concretos a esos inputs. Un template con `inputs` pero sin los `arguments` correspondientes en el sitio de llamada falla, a menos que el input tenga un `value` por defecto.

**Q8.** `B` y `C` ambos dependen solo de `A`, así que arrancan juntos y se ejecutan **concurrentemente**; su orden relativo de finalización es no determinista. `D` depende de `[B, C]`, así que el controlador no puede planificarlo hasta que ambos hayan tenido éxito — lo que lo vuelve el último.

**Q9.** `dag` te permite declarar las dependencias de cada tarea **localmente** (`dependencies: [B, C]`) y el controlador deriva el máximo paralelismo automáticamente. Con `steps` tenés que aplanar manualmente el grafo en grupos secuenciales, lo que fuerza barreras artificiales (un grupo entero debe terminar antes de que empiece el siguiente) — un desperdicio para grafos amplios y dispersos.

**Q10.** Por defecto una tarea se ejecuta solo cuando sus dependencias **tienen éxito**, así que si `C` falla, `D` no se ejecuta (aparece como fallido/omitido porque una dependencia falló), mientras que `B` — que no depende de `C` — igual corre hasta completarse. Podés cambiar esto con el campo más rico `depends` (p. ej. `A.Succeeded || A.Failed`, `C.Failed`) para construir ramas de manejo de errores.

**Q11.** Orden de sustitución:
1. `{{workflow.parameters.seed}}` — un **global**, sustituido por el controlador antes de que se cree el Pod `gen` (queda incrustado en el código fuente del script).
2. `{{steps.generate.outputs.result}}` — resuelto **después** de que `generate` termina y su resultado se conoce, luego pasado como argumento del step `consume`.
3. `{{inputs.parameters.value}}` — resuelto cuando el template `print` se instancia, vinculando el argumento del invocador al input del template.
Así que la sustitución es por etapas: primero los globales, luego las salidas de los steps a medida que están disponibles, luego los inputs en cada invocación.

**Q12.** Para un `container` que escribe en un archivo:
```yaml
outputs:
  parameters:
    - name: value
      valueFrom:
        path: /tmp/out
```
`outputs.result` es la captura de conveniencia de **stdout**, disponible en los templates `script` y `container` precisamente porque ejecutan un proceso cuyo stdout Argo puede capturar; templates como `resource`/`suspend` no tienen tal flujo de stdout, así que exponen salidas solo mediante `valueFrom` explícito.

**Q13.** Poné el valor por defecto en el **input del template** mismo: `inputs.parameters: [{name: value, value: "fallback"}]`. La precedencia de resolución es: `-p` de la CLI / override de la API → `spec.arguments.parameters` (o los `arguments` del sitio de llamada) → el `value` por defecto del input.

**Q14.** (1) Cuando `whalesay` termina, el executor de su Pod ve `outputs.artifacts.hello-art` con `path: /tmp/hello_world.txt`, empaqueta/comprime ese path con tar y lo **sube** al repositorio de artefactos (MinIO) bajo una clave atada al workflow/nodo. (2) `argo` registra la ubicación del artefacto en el estado del nodo. (3) Cuando `print-message` arranca, su executor lee la referencia del artefacto de entrada (`from: {{steps.generate.outputs.artifacts.hello-art}}`), **descarga** el objeto desde MinIO, y lo desempaqueta en `/tmp/message` antes de que el container principal ejecute `cat`.

**Q15.** El valor por defecto a nivel de cluster reside en la entrada **`artifact-repository`** del `workflow-controller-configmap` (o un repositorio referenciado por `artifactRepositoryRef`). Por artefacto, sobrescribís el destino especificando el backend en línea en el artefacto (`s3:`, `gcs:`, `azure:`, `http:`, `git:`, etc.) con su bucket/clave y credenciales `secretKeyRef`. Referencia: https://argo-workflows.readthedocs.io/en/latest/configure-artifact-repository/

**Q16.** `withItems` se conoce en **tiempo de autoría** — la lista es literal en el manifiesto, así que el controlador conoce la cardinalidad antes de que corra nada. `withParam` se conoce en **tiempo de ejecución** — consume la salida de un step previo. La restricción: la cadena entregada a `withParam` debe ser un **array JSON válido** (p. ej. `["a","b"]`); el controlador la parsea y hace fan-out de un hijo por elemento.

**Q17.** Un `when` que evalúa a falso marca el nodo como **Skipped**, que es una fase terminal *exitosa* a efectos del control de flujo — es una rama deliberada, no un error, así que no hace fallar el workflow. Los steps posteriores que dependen de un nodo omitido lo tratan como satisfecho-pero-sin-producir-salida (referenciar sus salidas sería un error, razón por la cual las ramas condicionales suelen converger en un step de unión (join) aparte).

**Q18.** Usá el accesor de campo de objeto sobre `item`: `"{{item.port}}"` (y `"{{item.name}}"` para el nombre). Argo expone los campos de cada elemento objeto como `{{item.<field>}}`.

**Q19.** `OnFailure` reintenta cuando el **container principal sale con código distinto de cero** (fallo a nivel de aplicación). `OnError` reintenta cuando Argo topa con un **error de infraestructura/executor** — el Pod no se pudo crear/iniciar, fue eliminado, falló la descarga de la imagen, se perdió el nodo, etc. `Always` = `OnFailure ∪ OnError`, así que atrapa ambos. (`OnTransientError` reintenta solo los errores identificados como transitorios, p. ej. mediante la lista de permitidos de errores transitorios por variable de entorno.)

**Q20.** Dentro de `onExit` tenés adicionalmente `{{workflow.failures}}` (una lista JSON de nodos fallidos con mensajes), más `{{workflow.duration}}`, `{{workflow.name}}`, `{{workflow.uid}}`, y `{{workflow.status}}` — comúnmente ramificás el handler con un `when: "{{workflow.status}} == Failed"`.

**Q21.** `activeDeadlineSeconds` (a nivel de workflow) es el que manda: cuando pasa el deadline, el controlador detiene el workflow y **no** dispara un reintento pendiente — el workflow queda fallido/terminado sin importar el `retryStrategy.limit` restante. La espera del backoff cuenta contra el deadline, así que un `maxDuration` largo puede ser recortado por un deadline de workflow más corto.

**Q22.** `argo submit --from workflowtemplate/X` crea un **`Workflow` independiente nuevo** a partir del template — ideal para ejecutar el template como un job (manualmente, desde CI, o planificado). `templateRef` **embebe una llamada** al template desde dentro de otro `Workflow`, así que componés bloques reutilizables dentro de un grafo más grande. Recurrí a `--from` para *ejecutar* un template; usá `templateRef` para *reutilizarlo* como componente.

**Q23.** Con `Replace`, cuando llega un nuevo tick mientras la ejecución previa sigue activa, el controlador **cancela la ejecución vieja e inicia la nueva**. `Forbid` **omite** el nuevo tick (conserva la que está corriendo). `Allow` (el predeterminado) las deja **solaparse**, ejecutándose concurrentemente.

**Q24.** Un `WorkflowTemplate` está **acotado a un namespace**; un `ClusterWorkflowTemplate` tiene **alcance de cluster** y se puede usar desde cualquier namespace. En un `templateRef`, direccionar un `ClusterWorkflowTemplate` agrega `clusterScope: true` (y descarta las suposiciones de namespace), p. ej. `templateRef: {name: X, template: main, clusterScope: true}`.

**Q25.** Un nodo `suspend` es puro estado del controlador — sin Pod, sin CPU/memoria reservada, sin imagen descargada — así que un workflow puede esperar horas o días una aprobación esencialmente gratis y sin ocupar un nodo. Un container que hace `sleep`-poll consume un espacio de Pod y recursos todo el tiempo y además necesita lógica de señalización externa.

**Q26.** Un `mutex` es un lock con nombre de capacidad **exactamente 1** (exclusión mutua). Un `semaphore` es un lock contador cuya capacidad proviene de un valor de ConfigMap. Fijar el semáforo en `1` es conductualmente equivalente a un mutex, pero un semáforo puede expresar **N > 1** — "como máximo N poseedores a la vez" — lo que un mutex no puede. Referencia: https://argo-workflows.readthedocs.io/en/latest/synchronization/

**Q27.** A **nivel de workflow** (`spec.synchronization`), el lock controla el *workflow entero* — solo N workflows completos lo poseen a la vez. Movido a un **template**, controla *cada invocación de ese template* — así que las muchas instancias paralelas de ese template dentro de un mismo workflow (p. ej. un step de fan-out) compiten por los mismos N espacios, throttleando esa única etapa sin limitar el resto del grafo.

</details>