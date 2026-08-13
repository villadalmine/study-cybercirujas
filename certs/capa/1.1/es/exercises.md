# Topic 1.1 — Fundamentos del Proyecto Argo · Ejercicios Guiados

> **Peso del dominio en el examen: 20%** · Certificación: **CAPA** (Certified Argo Project Associate)
>
> Estos labs asumen un clúster de Kubernetes funcionando (`kind`, `minikube` o k3s sirven) y un `kubectl` que ya lo apunte. Cada ejercicio es una secuencia de pasos numerados que ejecutás en una terminal, seguida de preguntas de comprensión. Las respuestas consolidadas están en la sección desplegable al final del todo — tratá de responder antes de expandirla.
>
> **Chequeo de sanidad antes de empezar:**
> ```bash
> kubectl version --output=json | grep -i gitVersion
> kubectl get nodes
> ```
> Deberías ver al menos un nodo en estado `Ready`.

---

## Exercise 1 — Mapeando el Proyecto Argo: cuatro herramientas, un diseño

**Objetivo:** Aprender *qué* es el Proyecto Argo y *qué* problema resuelve cada uno de sus cuatro componentes, para que nunca confundas Argo CD (entrega continua) con Argo Workflows (orquestación de jobs) en el examen.

El Proyecto Argo es un proyecto **CNCF Graduated** (graduado en 2022-12) compuesto por cuatro herramientas instalables de forma independiente pero componibles:

| Componente | Categoría | Pregunta central que responde |
|---|---|---|
| **Argo Workflows** | Orquestación de workflows / jobs | "Ejecutá este DAG de múltiples pasos de contenedores hasta completarse." |
| **Argo CD** | Entrega Continua (GitOps) | "Mantené el clúster coincidiendo con lo que dice Git." |
| **Argo Rollouts** | Entrega Progresiva | "Desplegá esta versión nueva de forma gradual y segura." |
| **Argo Events** | Automatización dirigida por eventos | "Cuando pasa *X*, disparar *Y*." |

1. Confirmá que entendés las versiones objetivo leyendo el release que publica cada proyecto. (Todavía no instales nada — solo observá el patrón de nombres.)
   ```bash
   curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest        | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-workflows/releases/latest | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-rollouts/releases/latest  | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-events/releases/latest    | grep '"tag_name"'
   ```
   Forma esperada de cada línea:
   ```
     "tag_name": "v2.13.2",
   ```

2. Creá los cuatro namespaces convencionales ahora para que el resto de los labs caigan en lugares predecibles:
   ```bash
   kubectl create namespace argo          # Argo Workflows
   kubectl create namespace argocd        # Argo CD
   kubectl create namespace argo-rollouts # Argo Rollouts
   kubectl create namespace argo-events   # Argo Events
   ```
   Esperado:
   ```
   namespace/argo created
   namespace/argocd created
   namespace/argo-rollouts created
   namespace/argo-events created
   ```

**Preguntas de comprensión — 1**

- **1a.** Un equipo te pide "desplazar gradualmente el 10% del tráfico de producción a `v2` y hacer rollback automático si sube la tasa de error." ¿Qué componente de Argo es ese, y cuál *no* es?
- **1b.** ¿Qué te dice "CNCF Graduated" sobre la madurez del proyecto en relación a "Incubating" o "Sandbox"?
- **1c.** Argo CD y Argo Rollouts se despliegan juntos con frecuencia. ¿Cuál es la división de trabajo entre ellos?

---

## Exercise 2 — La arquitectura compartida: CRDs + controllers + reconciliación

**Objetivo:** Ver que *las cuatro* herramientas de Argo están construidas sobre el mismo patrón Kubernetes-nativo — una **Custom Resource Definition (CRD)** que describe el estado deseado, más un **controller** que continuamente **reconcilia** el estado real hacia él. Esta es la idea arquitectónica más importante del Topic 1.1.

1. Instalá solo el plano de control de Argo Workflows para tener CRDs reales que inspeccionar (fijá una versión en vez de `latest` por reproducibilidad):
   ```bash
   ARGO_WF_VERSION=v3.6.2
   kubectl apply -n argo \
     -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WF_VERSION}/quick-start-minimal.yaml"
   ```

2. Esperá a que el controller y el API server estén listos:
   ```bash
   kubectl -n argo rollout status deployment/workflow-controller
   kubectl -n argo rollout status deployment/argo-server
   ```
   Esperado:
   ```
   deployment "workflow-controller" successfully rolled out
   deployment "argo-server" successfully rolled out
   ```

3. Listá las CRDs que registró la instalación. Este es el "vocabulario" que Argo agregó a la API de Kubernetes:
   ```bash
   kubectl get crd | grep argoproj.io
   ```
   Esperado (abreviado):
   ```
   clusterworkflowtemplates.argoproj.io   2026-08-12T...
   cronworkflows.argoproj.io              2026-08-12T...
   workflows.argoproj.io                  2026-08-12T...
   workflowtemplates.argoproj.io          2026-08-12T...
   ...
   ```

4. Inspeccioná el schema del kind `Workflow` directamente desde el API server — sin necesidad de docs:
   ```bash
   kubectl explain workflow.spec.entrypoint
   kubectl api-resources --api-group=argoproj.io
   ```
   Cola esperada del segundo comando:
   ```
   NAME                       SHORTNAMES   APIVERSION            NAMESPACED   KIND
   cronworkflows              cwf,cronwf   argoproj.io/v1alpha1  true         CronWorkflow
   workflows                  wf           argoproj.io/v1alpha1  true         Workflow
   workflowtemplates          wftmpl       argoproj.io/v1alpha1  true         WorkflowTemplate
   ...
   ```

5. Observá al controller haciendo su trabajo. En una terminal, transmití sus logs:
   ```bash
   kubectl -n argo logs deployment/workflow-controller -f
   ```
   Dejalo corriendo; lo vas a ver reaccionar en el Exercise 3.

**Preguntas de comprensión — 2**

- **2a.** ¿Cuáles son las dos mitades del patrón "operator/controller" de Kubernetes, y cuál mitad es el *estado deseado* versus el *agente que actúa*?
- **2b.** Las cuatro CRDs de Argo comparten el API group `argoproj.io` y la versión `v1alpha1`. Desde la perspectiva del examen, ¿por qué todo objeto de Argo que escribas empieza con `apiVersion: argoproj.io/v1alpha1`?
- **2c.** Ejecutaste `kubectl explain workflow.spec.entrypoint` y devolvió un schema. ¿Dónde vive físicamente ese schema en el clúster, y por qué importa eso para la validación *antes* de que se cree un Pod?
- **2d.** Definí "reconciliación" en una oración, como un bucle de control.

---

## Exercise 3 — Tu primer Argo Workflow (fundamentos de orquestación de jobs)

**Objetivo:** Enviar un DAG real de múltiples pasos, ver al controller crear Pods para cada nodo, y leer el resultado. Esto aterriza la idea de "Workflows = ejecutar contenedores hasta completarse".

1. Instalá el CLI `argo` (se muestra Linux amd64; ajustá para tu plataforma):
   ```bash
   ARGO_WF_VERSION=v3.6.2
   curl -sSL -o argo.gz \
     "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WF_VERSION}/argo-linux-amd64.gz"
   gunzip argo.gz && chmod +x argo && sudo mv argo /usr/local/bin/
   argo version --short
   ```
   Esperado:
   ```
   argo: v3.6.2
   ```

2. Escribí un workflow DAG. Guardalo como `hello-dag.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: hello-dag-        # server appends a random suffix
     namespace: argo
   spec:
     entrypoint: main                # which template starts the run
     templates:
       - name: main
         dag:
           tasks:
             - name: a
               template: echo
               arguments:
                 parameters: [{ name: msg, value: "I am task A" }]
             - name: b
               template: echo
               dependencies: [a]     # b runs only after a succeeds
               arguments:
                 parameters: [{ name: msg, value: "I am task B, after A" }]
             - name: c
               template: echo
               dependencies: [a]     # c also waits on a, runs in PARALLEL with b
               arguments:
                 parameters: [{ name: msg, value: "I am task C, after A" }]
       - name: echo
         inputs:
           parameters: [{ name: msg }]
         container:
           image: alpine:3.20
           command: [sh, -c]
           args: ["echo {{inputs.parameters.msg}}"]
   ```

3. Envialo y observalo ejecutarse hasta completarse:
   ```bash
   argo submit -n argo --watch hello-dag.yaml
   ```
   Esperado (estado final):
   ```
   Name:                hello-dag-abcde
   Namespace:           argo
   Status:              Succeeded
   Duration:            18 seconds
   
   STEP              TEMPLATE  PODNAME                   DURATION
    ✔ hello-dag-abcde  main
    ├─✔ a             echo      hello-dag-abcde-echo-...  6s
    ├─✔ b             echo      hello-dag-abcde-echo-...  5s
    └─✔ c             echo      hello-dag-abcde-echo-...  5s
   ```

4. Comprobá que la orquestación mapeó cada nodo del DAG a un Pod, luego leé la salida de un nodo:
   ```bash
   argo list -n argo
   kubectl -n argo get pods -l workflows.argoproj.io/workflow
   argo logs -n argo @latest
   ```
   Esperado (logs, el orden puede intercalarse):
   ```
   a:  I am task A
   b:  I am task B, after A
   c:  I am task C, after A
   ```

**Preguntas de comprensión — 3**

- **3a.** En el manifest, ¿por qué usamos `generateName` en vez de `name`?
- **3b.** Las tasks `b` y `c` ambas declaran `dependencies: [a]`. Dada la semántica del DAG, ¿cuál es la relación de ejecución entre `b` y `c`, y por qué?
- **3c.** ¿Cuántos Pods hizo crear este único objeto `Workflow` al controller, y cuál es el mapeo entre tasks del DAG y Pods acá?
- **3d.** ¿Qué selecciona `entrypoint: main`, y qué se rompería si lo pusieras en `echo`?
- **3e.** Después de la corrida, su estado fue `Succeeded`. ¿Dónde se almacena ese estado — en el CLI o en el clúster — y cómo lo releerías un día después?

---

## Exercise 4 — Tu primera Argo CD Application (fundamentos de GitOps)

**Objetivo:** Instalar Argo CD, registrar un repo de Git como la fuente de verdad, y observarlo llevar el clúster al estado declarado. Esto ancla los cuatro principios de GitOps: **declarativo, versionado en Git, tirado (pulled) automáticamente, reconciliado continuamente.**

1. Instalá Argo CD en el namespace `argocd`:
   ```bash
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deployment/argocd-server
   ```

2. Mirá los componentes que levanta una instalación estándar — notá que hay *varios* controllers, no uno solo:
   ```bash
   kubectl -n argocd get deploy,statefulset
   ```
   Esperado (abreviado):
   ```
   deployment.apps/argocd-applicationset-controller
   deployment.apps/argocd-dex-server
   deployment.apps/argocd-notifications-controller
   deployment.apps/argocd-redis
   deployment.apps/argocd-repo-server
   deployment.apps/argocd-server
   statefulset.apps/argocd-application-controller
   ```

3. Obtené la contraseña de admin autogenerada (Argo CD la almacena en un Secret en el primer arranque):
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   ```

4. Declará una `Application` — la CRD que le dice a Argo CD *qué repo* sincronizar *dónde*. Guardalo como `guestbook-app.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd                     # Applications live in the Argo CD namespace
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook                      # sub-directory holding the manifests
     destination:
       server: https://kubernetes.default.svc  # the in-cluster API
       namespace: guestbook
     syncPolicy:
       automated:                           # GitOps principle: pulled automatically
         prune: true                        # delete resources removed from Git
         selfHeal: true                     # revert manual drift back to Git
       syncOptions:
         - CreateNamespace=true
   ```

5. Aplicalo y observá a Argo CD reconciliar:
   ```bash
   kubectl apply -f guestbook-app.yaml
   kubectl -n argocd get application guestbook -w
   ```
   Progresión esperada:
   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   OutOfSync     Missing
   guestbook   Syncing       Progressing
   guestbook   Synced        Healthy
   ```

6. Confirmá que las cargas de trabajo que Git describió ahora existen en el clúster, y luego probá el **self-heal** introduciendo drift deliberadamente:
   ```bash
   kubectl -n guestbook get deploy,svc
   kubectl -n guestbook scale deployment/guestbook-ui --replicas=5   # manual drift
   kubectl -n guestbook get deploy guestbook-ui -w                    # watch it revert
   ```
   Esperado: las réplicas muestran brevemente `5`, luego Argo CD las vuelve a escalar al valor declarado en Git.

**Preguntas de comprensión — 4**

- **4a.** Nombrá los cuatro principios de GitOps y señalá el campo (o campos) exacto en el manifest `Application` que implementa "tirado automáticamente" y "reconciliado continuamente".
- **4b.** Escalaste el Deployment a 5 réplicas a mano y volvió de golpe. ¿Qué sub-campo de `syncPolicy` causó eso, y qué pasaría en cambio si fuera `false`?
- **4c.** `prune: true` — ¿qué borra, y qué quedaría atrás silenciosamente si fuera `false`?
- **4d.** El objeto `Application` vive en el namespace `argocd` pero las cargas de trabajo de guestbook viven en el namespace `guestbook`. Explicá cómo una `Application` en un namespace termina gestionando recursos en otro.
- **4e.** Argo CD es una herramienta de entrega **basada en pull**. Contrastá eso con un job de CI **basado en push** que corre `kubectl apply` — dá una ventaja de seguridad del pull.

---

## Exercise 5 — Tu primer Argo Rollout (fundamentos de entrega progresiva)

**Objetivo:** Reemplazar un `Deployment` estándar con un `Rollout` y conducir un release **canary** paso a paso. Esto aterriza "Rollouts = desplegar de forma gradual y segura".

1. Instalá el controller de Argo Rollouts y el plugin de kubectl:
   ```bash
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   kubectl -n argo-rollouts rollout status deployment/argo-rollouts

   curl -sSL -o kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   chmod +x kubectl-argo-rollouts && sudo mv kubectl-argo-rollouts /usr/local/bin/
   kubectl argo rollouts version
   ```

2. Declará un `Rollout` canary. Guardalo como `canary-rollout.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-demo
     namespace: default
   spec:
     replicas: 5
     revisionHistoryLimit: 2
     selector:
       matchLabels: { app: rollouts-demo }
     template:
       metadata:
         labels: { app: rollouts-demo }
       spec:
         containers:
           - name: rollouts-demo
             image: argoproj/rollouts-demo:blue
             ports: [{ containerPort: 8080 }]
             resources:
               requests: { cpu: 5m, memory: 32Mi }
     strategy:
       canary:                     # gradual, not all-at-once
         steps:
           - setWeight: 20         # send 20% to the new version
           - pause: {}             # pause INDEFINITELY until a human promotes
           - setWeight: 40
           - pause: { duration: 20s }
           - setWeight: 60
           - pause: { duration: 20s }
           - setWeight: 80
           - pause: { duration: 20s }
   ```

3. Crealo y abrí el dashboard en vivo para este rollout:
   ```bash
   kubectl apply -f canary-rollout.yaml
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```
   Estado inicial esperado (los 5 pods en la versión estable `blue`, todavía sin canary):
   ```
   Name:            rollouts-demo
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          8/8
     SetWeight:     100
     ActualWeight:  100
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas: Desired: 5 / Current: 5 / Updated: 5 / Available: 5
   ```

4. Dispará una actualización cambiando solo el image tag, luego observá al canary pausar en 20%:
   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```
   Esperado (pausado en el step 2 de 8):
   ```
   Status:        ॥ Paused
     Step:        1/8
     SetWeight:   20
     ActualWeight: 20
   Images:        argoproj/rollouts-demo:blue (stable)
                  argoproj/rollouts-demo:yellow (canary)
   Replicas: Desired: 5 / Current: 6 / Updated: 1 / Available: 5
   ```

5. Promocioná manualmente a través de los pasos restantes, luego verificá que la nueva versión ahora es estable:
   ```bash
   kubectl argo rollouts promote rollouts-demo
   kubectl argo rollouts get rollout rollouts-demo --watch   # completes the timed steps
   ```
   Estado final esperado: `Images: argoproj/rollouts-demo:yellow (stable)`.

6. (Opcional) Practicá un aborto de seguridad en vez de una promoción:
   ```bash
   kubectl argo rollouts set image rollouts-demo rollouts-demo=argoproj/rollouts-demo:red
   kubectl argo rollouts abort rollouts-demo     # roll back to stable immediately
   ```

**Preguntas de comprensión — 5**

- **5a.** Un `Rollout` es un reemplazo directo (drop-in) de qué objeto nativo de Kubernetes. ¿Qué agrega que el objeto nativo no puede hacer por sí solo?
- **5b.** En el paso 4, `Current: 6` mientras `Desired: 5`. ¿Por qué hay temporalmente 6 Pods durante un canary del 20% de 5 réplicas?
- **5c.** El primer `pause: {}` no tiene `duration`, pero las pausas posteriores tienen `duration: 20s`. ¿Cuál es la diferencia de comportamiento, y cuál requirió tu comando `promote`?
- **5d.** Cambiaste *solo* el image tag para disparar el rollout. ¿Qué campo dentro de `spec.template` hashea el controller para decidir "esto es una revisión nueva"?
- **5e.** `abort` vs `promote` — describí el estado final de cada uno sobre un canary pausado.

---

## Exercise 6 — Primitivas de Argo Events (fundamentos dirigidos por eventos)

**Objetivo:** Entender los tres objetos centrales de Argo Events y cómo una señal se convierte en una acción: **EventSource → EventBus → Sensor → trigger.**

1. Instalá Argo Events y su dependencia EventBus por defecto (NATS JetStream):
   ```bash
   kubectl apply -n argo-events \
     -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml
   kubectl -n argo-events rollout status deployment/controller-manager
   ```

2. Creá el `EventBus` — el backbone de transporte por el que hablan cada EventSource y Sensor. Guardalo como `eventbus.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: EventBus
   metadata:
     name: default            # Sensors/EventSources default to the bus named "default"
     namespace: argo-events
   spec:
     jetstream:
       version: latest
       replicas: 3
   ```
   ```bash
   kubectl apply -f eventbus.yaml
   kubectl -n argo-events get eventbus
   ```

3. Creá un `EventSource` que emita un evento en un cronograma fijo (una fuente "calendar" es la más simple para probar, no necesita ningún sistema externo). Guardalo como `eventsource.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: EventSource
   metadata:
     name: calendar
     namespace: argo-events
   spec:
     calendar:
       example-every-10s:
         interval: 10s        # emit an event named "example-every-10s" every 10 seconds
   ```

4. Creá un `Sensor` que escuche ese evento y dispare una acción (acá, crear un Pod efímero). Guardalo como `sensor.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: calendar-sensor
     namespace: argo-events
   spec:
     dependencies:
       - name: cal-dep
         eventSourceName: calendar          # must match the EventSource metadata.name
         eventName: example-every-10s        # must match the key under spec.calendar
     triggers:
       - template:
           name: log-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: cal-triggered-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: alpine:3.20
                       command: [echo, "an event fired and I was triggered"]
   ```

5. Aplicá la fuente y el sensor, luego observá cómo se crea un Pod cada ~10 segundos:
   ```bash
   kubectl apply -f eventsource.yaml
   kubectl apply -f sensor.yaml
   kubectl -n argo-events get pods -w
   ```
   Esperado: nuevos Pods `cal-triggered-xxxxx` apareciendo en el intervalo, cada uno corriendo hasta `Completed`.

**Preguntas de comprensión — 6**

- **6a.** Nombrá las tres CRDs de Argo Events de este lab y enunciá la única responsabilidad de cada una.
- **6b.** En el `Sensor`, `eventSourceName` y `eventName` deben coincidir con campos específicos del `EventSource`. ¿Qué campos, exactamente, y qué pasa si `eventName` está mal escrito?
- **6c.** ¿Cuál es el rol del `EventBus`, y por qué Argo Events inserta un message bus entre fuentes y sensores en vez de cablearlos directamente?
- **6d.** Un patrón común de producción es "un webhook EventSource dispara un Argo Workflow". ¿Qué dos componentes de Argo combina ese patrón, y qué reemplaza al trigger `k8s` para lanzar un Workflow?

---

## Exercise 7 — Viendo el único patrón detrás de los cuatro

**Objetivo:** Consolidar. Probate a vos mismo que Workflows, CD, Rollouts y Events son la *misma* idea arquitectónica — CRD declarativa + controller que reconcilia — instalada cuatro veces.

1. Enumerá cada CRD que registró cada herramienta de Argo:
   ```bash
   kubectl get crd -o name | grep argoproj.io | sort
   ```
   Esperado (abreviado, abarcando las cuatro herramientas):
   ```
   customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/eventbus.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/eventsources.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/experiments.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/rollouts.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/sensors.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/workflows.argoproj.io
   ...
   ```

2. Identificá el Pod controller detrás de cada herramienta:
   ```bash
   kubectl -n argo            get deploy workflow-controller
   kubectl -n argocd          get statefulset argocd-application-controller
   kubectl -n argo-rollouts   get deploy argo-rollouts
   kubectl -n argo-events     get deploy controller-manager
   ```

3. Completá este modelo mental (escribilo, no solo lo leas):

   | Herramienta | CRD principal | Controller que reconcilia | "Estado real" que conduce |
   |---|---|---|---|
   | Workflows | `Workflow` | `workflow-controller` | Pods corren hasta completarse |
   | Argo CD | `Application` | `argocd-application-controller` | Clúster == Git |
   | Rollouts | `Rollout` | controller `argo-rollouts` | El tráfico se desplaza gradualmente |
   | Argo Events | `Sensor` (+ `EventSource`) | `controller-manager` | Los triggers se disparan ante eventos |

**Preguntas de comprensión — 7**

- **7a.** Enunciá el patrón universal de Argo en una oración, usando las palabras *declarativo*, *controller* y *reconciliar*.
- **7b.** El controller de Argo CD es un `StatefulSet` mientras que los otros tres son `Deployments`. Sin memorizarlo, ¿qué implica "el estado deseado se almacena en el API server, no en el controller" sobre si perder un Pod controller pierde tus objetos `Application`/`Workflow`/`Rollout`?
- **7c.** "Argo CD despliega los *manifests*; Argo Rollouts controla *cómo progresan esos manifests*; Argo Workflows puede *ejecutar los pasos de CI/CD que los produjeron*; Argo Events *dispara todo el conjunto*." Mapeá cada cláusula a una de las cuatro herramientas y explicá por qué el proyecto las envía como una familia.

---

## Clean-up (opcional)

```bash
kubectl delete -f canary-rollout.yaml -f eventsource.yaml -f sensor.yaml -f eventbus.yaml --ignore-not-found
kubectl delete application guestbook -n argocd --ignore-not-found
kubectl delete namespace argo argocd argo-rollouts argo-events guestbook --ignore-not-found
```

---

<details>
<summary><strong>✅ Respuestas y explicaciones (expandir después de intentar)</strong></summary>

### Exercise 1

- **1a.** Eso es **Argo Rollouts** (entrega progresiva: ponderación de canary + rollback automático ante análisis de métricas). *No* es **Argo CD** — Argo CD decide *qué* versión debería desplegarse desde Git, pero aplica los cambios como un rollout estándar; el *desplazamiento gradual de tráfico con análisis automático* es tarea de Rollouts.
- **1b.** Los niveles de madurez de CNCF son **Sandbox → Incubating → Graduated**. "Graduated" es el nivel más alto: señala adopción amplia en producción, una comunidad multi-vendor saludable, procesos de seguridad/gobernanza documentados, y una API estable — seguro para estandarizar sobre él. Argo se graduó en diciembre de 2022.
- **1c.** **Argo CD** es el motor de GitOps: observa Git y mantiene los objetos declarados del clúster (incluido un manifest `Rollout`) en sincronía. **Argo Rollouts** es el motor de estrategia de despliegue: una vez que un objeto `Rollout` existe/cambia, su controller ejecuta los pasos de canary o blue-green y el desplazamiento de tráfico. Argo CD dice *"esta versión debería existir"*; Rollouts dice *"así es cómo llegar ahí de forma segura."*

### Exercise 2

- **2a.** Las dos mitades son la **Custom Resource (respaldada por una CRD)** = el *estado deseado / spec declarativa*, y el **controller** = el *agente que actúa* que corre un bucle de control. La CRD/CR es datos; el controller es comportamiento.
- **2b.** Todos los objetos de Argo pertenecen al mismo API group y versión porque cada herramienta **extiende la API de Kubernetes** vía CRDs registradas bajo `argoproj.io/v1alpha1`. En el examen, cualquier manifest de Argo — `Workflow`, `Application`, `Rollout`, `Sensor`, `EventSource`, `EventBus` — comienza con `apiVersion: argoproj.io/v1alpha1`; un `apiVersion` incorrecto es un distractor clásico.
- **2c.** El schema vive en el **objeto CRD almacenado en el API server del clúster (etcd)**. Como el API server contiene un schema OpenAPI para la CRD, puede **validar y rechazar un manifest mal formado en el momento del `kubectl apply`** — antes de que actúe cualquier controller y antes de que se agende cualquier Pod. La validación es del lado del servidor e independiente del controller.
- **2d.** La **reconciliación** es un bucle de control continuo que observa el estado real del mundo, lo compara con el estado deseado declarado, y toma acciones correctivas para cerrar la brecha — repetidamente, no una sola vez.

### Exercise 3

- **3a.** `generateName` le dice al API server que **agregue un sufijo aleatorio** y acuñe un nombre único (`hello-dag-abcde`). Como enviás muchas corridas del mismo workflow, un `name` fijo colisionaría con la corrida anterior; `generateName` permite que cada envío cree un objeto distinto.
- **3b.** `b` y `c` **corren en paralelo**. Cada uno depende solo de `a`, y no hay arista de dependencia entre `b` y `c`, así que una vez que `a` tiene éxito el controller agenda ambos simultáneamente. El DAG modela dependencias, y los hermanos independientes son concurrentes por defecto.
- **3c.** El controller creó **tres Pods** — uno por cada *task* del DAG que tiene un `container` (`a`, `b`, `c`). El template de nivel superior `main` es un orquestador de DAG y **no** obtiene su propio Pod worker; solo las invocaciones hoja `echo` se convierten en Pods. Mapeo acá: 1 task ⇒ 1 Pod.
- **3d.** `entrypoint: main` selecciona **desde qué template empieza la corrida**. Ponerlo en `echo` intentaría empezar en un template que *requiere un parámetro de entrada* (`msg`) sin argumentos suministrados, así que el workflow fallaría al correr correctamente (falta la entrada requerida) en vez de ejecutar el DAG.
- **3e.** El estado se almacena **en el clúster**, en el objeto `Workflow` mismo (`.status`), en etcd — no en el CLI. Un día después lo releés con `kubectl -n argo get wf <name> -o yaml` o `argo get -n argo <name>`; la salida de `argo --watch` era solo una vista en vivo de ese estado del lado del servidor.

### Exercise 4

- **4a.** Los cuatro principios de GitOps: **(1) Declarativo** — el sistema entero se describe como datos (los manifests en `path: guestbook`); **(2) Versionado e inmutable** — ese estado deseado vive en Git (`repoURL` + `targetRevision`); **(3) Tirado automáticamente** — un agente lo tira y lo aplica (`syncPolicy.automated`); **(4) Reconciliado continuamente** — el agente sigue observando y corrigiendo el drift (`selfHeal: true`, más el bucle de sync continuo de Argo CD). "Tirado automáticamente" ⇒ `syncPolicy.automated`; "reconciliado continuamente" ⇒ `selfHeal: true`.
- **4b.** `syncPolicy.automated.selfHeal: true` causó la reversión — Argo CD detectó que el estado en vivo divergía de Git y volvió a aplicar el `replicas` declarado en Git. Con `selfHeal: false`, la Application mostraría **`OutOfSync`** y dejaría tus 5 réplicas manuales en su lugar hasta que alguien sincronizara manualmente.
- **4c.** `prune: true` **borra los recursos del clúster que alguna vez fueron gestionados por esta Application pero que desde entonces fueron removidos de Git**. Con `prune: false`, esos objetos huérfanos quedan corriendo silenciosamente — una causa común de "lo borré de Git pero sigue en el clúster."
- **4d.** La `Application` es un objeto de control leído por el `argocd-application-controller`. Su `spec.destination` (`server` + `namespace`) le dice al controller **en qué clúster y namespace aplicar los manifests provenientes de la fuente**. Así que la *definición* de la Application vive en `argocd`, pero su *efecto* está en cualquier destino que nombre — acá, `guestbook`.
- **4e.** En modo **pull**, el agente de entrega corre *dentro* del clúster objetivo y llega *hacia afuera* a Git; ningún sistema de CI externo necesita credenciales de cluster-admin ni acceso entrante a la API. Eso achica la superficie de ataque: no le entregás credenciales de escritura del kube-apiserver a un runner de CI externo, y el API server del clúster no necesita estar expuesto a la red de CI.

### Exercise 5

- **5a.** Un `Rollout` es un reemplazo directo (drop-in) de un **`Deployment`** (misma forma de `replicas`/`selector`/`template`). Agrega **estrategias de despliegue avanzadas** — canary y blue-green con pasos de tráfico ponderado, pausas, análisis automático de métricas (`AnalysisTemplate`), y promote/abort manual — que un `Deployment` nativo (solo `RollingUpdate`/`Recreate`) no puede hacer.
- **5b.** Durante un canary del 20% de 5 réplicas, el controller mantiene los **5 Pods estables** disponibles *y* agrega **1 Pod canary** (20% de 5 = 1) para que la capacidad en vivo no se reduzca mientras se valida la nueva versión — de ahí `Current: 6`. Los Pods viejos solo se reducen a medida que aumenta el peso del canary.
- **5c.** `pause: {}` sin duration pausa **indefinidamente** — espera un `kubectl argo rollouts promote` humano. `pause: { duration: 20s }` **se reanuda automáticamente** después de 20 segundos. El indefinido (paso 2) es el que requirió tu comando `promote`; los cronometrados avanzaron por su cuenta.
- **5d.** El controller hashea **`spec.template`** (el template del Pod). Cualquier cambio ahí — incluido solo el image tag del contenedor — produce un nuevo pod-template hash, que el controller trata como una revisión nueva e inicia la estrategia canary. Cambiar algo fuera de `spec.template` (por ejemplo `replicas`) *no* dispara un nuevo rollout.
- **5e.** `promote` **avanza** el rollout al siguiente paso (o, con `--full`, directo al 100%), eventualmente haciendo del canary el nuevo estable. `abort` **hace rollback inmediato** a la última versión estable, escalando el canary a cero y dejando al estable anterior sirviendo el 100% del tráfico.

### Exercise 6

- **6a.** **`EventSource`** — se conecta a un sistema externo (calendar, webhook, S3, Kafka, …) y *produce* eventos hacia el bus. **`EventBus`** — el transporte (NATS JetStream por defecto) que lleva eventos de las fuentes a los sensores. **`Sensor`** — *se suscribe* a dependencias de eventos con nombre y, cuando se satisfacen, dispara **triggers** (crear un Pod, lanzar un Workflow, llamar a un endpoint HTTP, …).
- **6b.** En el `Sensor`, `dependencies[].eventSourceName` debe ser igual al `metadata.name` del `EventSource` (`calendar`), y `dependencies[].eventName` debe ser igual a la **clave bajo `spec.calendar`** (`example-every-10s`), no al nombre de la CRD. Si `eventName` está mal escrito, la dependencia **nunca coincide con un evento entrante**, así que el Sensor se queda inactivo y ningún trigger se dispara — sin error, lo que lo hace un bug sutil.
- **6c.** El `EventBus` es la **capa durable de transporte de mensajes** entre EventSources y Sensors. Desacoplarlos a través de un bus da **durabilidad/replay (persistencia de JetStream), fan-out (muchos sensores consumiendo una fuente), back-pressure, y escalado/reinicio independiente** de fuentes y sensores — nada de lo cual podría proveer un cable directo de fuente a sensor.
- **6d.** Combina **Argo Events** (el `EventSource` webhook + `Sensor`) con **Argo Workflows**. En vez del trigger `k8s`, el Sensor usa un **trigger `argoWorkflow`** (`triggers[].template.argoWorkflow`) cuyo `operation: submit` crea un objeto `Workflow` — un pipeline dirigido por eventos canónico.

### Exercise 7

- **7a.** Cada herramienta de Argo te deja **declarativamente** describir el estado deseado como una custom resource, y corre un **controller** dedicado que continuamente **reconcilia** el estado real del clúster hacia esa declaración.
- **7b.** Como el estado deseado (`Application`, `Workflow`, `Rollout`, `Sensor`, …) se persiste en el **API server / etcd**, no dentro del proceso del controller, **perder un Pod controller no pierde tus objetos**. Un nuevo Pod controller se reconecta, lee las mismas CRs del API server, y reanuda la reconciliación. `StatefulSet` vs `Deployment` es una decisión de implementación sobre el controller, no sobre dónde vive el estado.
- **7c.** **Argo CD** despliega los manifests (sync GitOps de *qué* corre); **Argo Rollouts** gobierna *cómo* progresa una nueva versión de esos manifests (seguridad canary/blue-green); **Argo Workflows** corre los pasos del pipeline (jobs de build/test/scan) que *producen y validan* los releases; **Argo Events** *dispara* los pipelines y syncs en respuesta a señales (webhook de git push, cronograma, mensaje). Se envían como una familia porque se componen en un bucle completo de entrega continua GitOps dirigido por eventos — cada uno cubriendo una fase distinta (trigger → build → deliver → progress) mientras comparten la misma base de CRD-más-controller.

</details>

---

### Sources (official)

- CNCF CAPA curriculum — <https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md>
- Argo Project (umbrella) — <https://argoproj.github.io/>
- Argo Workflows docs — <https://argo-workflows.readthedocs.io/en/latest/>
- Argo CD docs — <https://argo-cd.readthedocs.io/en/stable/>
- Argo Rollouts docs — <https://argo-rollouts.readthedocs.io/en/stable/>
- Argo Events docs — <https://argoproj.github.io/argo-events/>
- OpenGitOps principles (CNCF) — <https://opengitops.dev/>
- CNCF graduated projects — <https://www.cncf.io/projects/argo/>