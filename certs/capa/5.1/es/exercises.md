# Ejercicios guiados — Tema 5.1: Argo Events (CAPA, peso 20%)

Estos ejercicios te llevan desde un cluster vacío hasta un pipeline orientado a eventos que funciona, y de ahí a las técnicas de diagnóstico que necesitás cuando los eventos fallan silenciosamente al dispararse. Trabajalos en orden — cada uno construye el estado del que depende el siguiente. Ejecutá cada comando contra un cluster descartable (kind/minikube/k3d están bien); nada de esto es destructivo, pero los triggers sí crean objetos reales.

**Fuentes de referencia**
- Currículo de CNCF: <https://github.com/cncf/curriculum/blob/master/capa/README.md>
- Documentación de Argo Events (conceptos y arquitectura): <https://argoproj.github.io/argo-events/>
- EventBus: <https://argoproj.github.io/argo-events/concepts/eventbus/>
- Webhook EventSource: <https://argoproj.github.io/argo-events/eventsources/setup/webhook/>
- Filtros de Sensor: <https://argoproj.github.io/argo-events/sensors/filters/intro/>
- Parametrización de Trigger: <https://argoproj.github.io/argo-events/sensors/trigger-conditions/>

**Modelo mental antes de empezar.** Argo Events tiene exactamente cuatro partes móviles y forman un tubo unidireccional:

```
external system ──▶ EventSource ──(CloudEvent)──▶ EventBus ──▶ Sensor ──▶ Trigger ──▶ K8s / Workflow / HTTP / ...
```

- **EventSource** — un Deployment que *ingiere* desde el mundo exterior (webhook, calendar, Kafka, SQS, un watch de recurso de Kubernetes, ...), normaliza cada evento en un **CloudEvent** y lo publica en el EventBus.
- **EventBus** — el transporte. Por defecto, un StatefulSet de NATS **JetStream**. Desacopla las sources de los sensors y es el único componente que ambos lados comparten.
- **Sensor** — un Deployment que *se suscribe* al EventBus, evalúa **dependencies** y **filters**, y cuando se cumple su condición de trigger, dispara uno o más **Triggers**.
- **Trigger** — la acción: crear un objeto de K8s, enviar un Argo Workflow, llamar a un endpoint HTTP, publicar en Kafka, etc.

Mantené ese diagrama en la cabeza — la mayoría de las fallas reales son "¿qué flecha está rota?".

---

## Ejercicio 1 — Instalar el controller y aprovisionar un EventBus

1. Creá el namespace e instalá el controller + los CRDs:

   ```bash
   kubectl create namespace argo-events
   kubectl apply -n argo-events \
     -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml
   ```

2. Confirmá que el controller está corriendo y que los CRDs están registrados:

   ```bash
   kubectl -n argo-events get deploy
   kubectl get crd | grep argoproj.io
   ```

   Esperado:

   ```
   NAME                 READY   UP-TO-DATE   AVAILABLE   AGE
   controller-manager   1/1     1            1           40s

   eventbus.argoproj.io          2026-08-12T...
   eventsources.argoproj.io      2026-08-12T...
   sensors.argoproj.io           2026-08-12T...
   ```

3. Aprovisioná un EventBus de JetStream llamado `default`. El nombre importa — los EventSources y Sensors que omiten `eventBusName` se enlazan a `default`.

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: EventBus
   metadata:
     name: default
   spec:
     jetstream:
       version: latest
       replicas: 3
   EOF
   ```

4. Observá cómo el EventBus aprovisiona su StatefulSet y alcanza una condición Deployed:

   ```bash
   kubectl -n argo-events get statefulset
   kubectl -n argo-events get eventbus default \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   ```

   Esperado:

   ```
   NAME                  READY   AGE
   eventbus-default-js   3/3     55s

   Deployed=True
   Configured=True
   ```

**Chequeo de comprensión**

- Q1.1 — ¿Por qué el EventBus se materializa como un **StatefulSet** en lugar de un Deployment? ¿Qué se rompería si fuera un Deployment con 3 réplicas detrás de un único Service?
- Q1.2 — Aplicaste un EventBus llamado `default`. Un colega crea un segundo EventBus llamado `ci` en el mismo namespace. ¿El tráfico existente de `default` se mueve a `ci`? ¿Qué único campo decide qué bus usa un EventSource/Sensor?
- Q1.3 — El StatefulSet se llama `eventbus-default-js`. Si en cambio hubieras desplegado el bus legacy `spec.nats.native`, ¿cuál sería el sufijo del StatefulSet, y por qué importa operativamente el sufijo?

---

## Ejercicio 2 — Webhook EventSource y el envoltorio de CloudEvents

1. Creá un EventSource de webhook. La clave del mapa bajo `webhook:` (`example`) es el **nombre del evento** — memorizala, el Sensor la referencia por esa cadena exacta.

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: EventSource
   metadata:
     name: webhook
   spec:
     service:
       ports:
         - port: 12000
           targetPort: 12000
     webhook:
       example:
         port: "12000"
         endpoint: /example
         method: POST
   EOF
   ```

2. Observá lo que el controller materializó a partir de ese spec — un Deployment *y* un Service que nunca escribiste a mano:

   ```bash
   kubectl -n argo-events get deploy,svc -l eventsource-name=webhook
   ```

   Esperado:

   ```
   NAME                                    READY   UP-TO-DATE   AVAILABLE
   deployment.apps/webhook-eventsource     1/1     1            1

   NAME                              TYPE        CLUSTER-IP     PORT(S)
   service/webhook-eventsource-svc   ClusterIP   10.96.71.5     12000/TCP
   ```

3. Hacé port-forward del Service generado y enviá un evento real:

   ```bash
   kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
   curl -si -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' \
     -d '{"message":"hello","value":75}'
   ```

   Respuesta esperada: `HTTP/1.1 200 OK` con el body `success`.

4. Confirmá que el EventSource publicó en el bus:

   ```bash
   kubectl -n argo-events logs -l eventsource-name=webhook --tail=5
   ```

   Esperado (recortado):

   ```
   {"level":"info","logger":"argo-events.eventsource","msg":"succeeded to publish an event","eventSourceName":"webhook","eventName":"example"}
   ```

**Chequeo de comprensión**

- Q2.1 — Escribiste un bloque `service:` pero ningún manifiesto de `Service` ni de `Deployment`. ¿Qué componente los creó, y qué label les estampó a ambos para que puedan seleccionarse juntos?
- Q2.2 — El evento que hiciste POST llega al bus como un **CloudEvent**, no como tu JSON crudo. Esbozá las dos partes de nivel superior de ese envoltorio, y decí dónde adentro cae tu body `{"message":"hello","value":75}`. (Pista: la ruta que vas a usar más adelante es `body.message`, no `message`.)
- Q2.3 — El paso 4 dice "succeeded to publish an event" pero **todavía no existe ningún Sensor**. ¿Se procesó el evento? ¿Dónde está ahora, y qué propiedad del EventBus determina si un Sensor creado *después* todavía puede consumirlo?

---

## Ejercicio 3 — Sensor, trigger de K8s, y el RBAC que lo hace disparar

Un Sensor dispara acciones en el API server, así que su ServiceAccount — **no el tuyo** — debe estar autorizado. Esta es la razón más común por la que un Sensor "correcto" no hace nada.

1. Creá el ServiceAccount y el RBAC de mínimo privilegio para el trigger:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: operate-workflow-sa
     namespace: argo-events
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: operate-workflow-role
     namespace: argo-events
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["create", "get", "list", "watch"]
     - apiGroups: ["argoproj.io"]
       resources: ["workflows"]
       verbs: ["create", "get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: operate-workflow-binding
     namespace: argo-events
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: operate-workflow-role
   subjects:
     - kind: ServiceAccount
       name: operate-workflow-sa
       namespace: argo-events
   EOF
   ```

2. Creá un Sensor cuya única dependency coincida *exactamente* con los nombres de EventSource/evento y cuyo trigger cree un Pod:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
     triggers:
       - template:
           name: webhook-pod-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: hello-event-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: busybox
                       command: ["echo"]
                       args: ["an event fired me"]
   EOF
   ```

3. Dispará un evento (reutilizá el port-forward del Ejercicio 2, reinicialo si murió):

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"go"}'
   ```

4. Verificá que el Sensor procesó el trigger y que nació un Pod:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=5
   kubectl -n argo-events get pods -l events.argoproj.io/sensor=webhook
   ```

   Esperado (recortado):

   ```
   {"level":"info","logger":"argo-events.sensor","msg":"successfully processed the trigger","triggerName":"webhook-pod-trigger"}

   NAME                READY   STATUS      RESTARTS   AGE
   hello-event-4t9qz   0/1     Completed   0          6s
   ```

**Chequeo de comprensión**

- Q3.1 — Comentá `spec.template.serviceAccountName` y volvé a aplicar. El pod del Sensor sigue sano, el evento se sigue publicando, pero no aparece ningún Pod. ¿Dónde se manifiesta el error, y qué estado HTTP le devolverá el API server al Sensor?
- Q3.2 — La dependency de tu Sensor dice `eventName: example`. Renombrás la clave del mapa del webhook a `demo` en el EventSource pero te olvidás de actualizar el Sensor. No se dispara nada. ¿Cuál de los cuatro componentes registró el éxito de "publish", y cuál está ahora descartando silenciosamente el evento — y por qué eso no aparece como un error?
- Q3.3 — El trigger usa `generateName: hello-event-` en lugar de un `name:` fijo. ¿Qué pasaría en el **segundo** evento si hubieras usado un `name:` fijo y `operation: create`? ¿A qué valor de `operation` cambiarías para una semántica de "mantener este objeto reconciliado con el último evento"?

---

## Ejercicio 4 — Filters: hacer selectivo a un Sensor

Una dependency cruda se dispara con *todos* los eventos que coinciden. Los filters permiten que un Sensor acepte algunos eventos y descarte otros. Argo Events evalúa los filters en un orden fijo — **expr → data → context → time → script** — y *todos* los tipos de filter configurados deben pasar (AND lógico entre tipos).

1. Reemplazá la dependency con lógica filtrada. Esta se dispara solo cuando `value > 50` **y** el message no está vacío:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
         filters:
           dataLogicalOperator: "and"
           data:
             - path: body.value
               type: number
               comparator: ">"
               value:
                 - "50"
           exprs:
             - expr: 'msg != ""'
               fields:
                 - name: msg
                   path: body.message
     triggers:
       - template:
           name: webhook-pod-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: filtered-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: busybox
                       command: ["echo"]
                       args: ["passed the filter"]
   EOF
   ```

2. Enviá un evento que debería ser **rechazado** (`value` por debajo del umbral):

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"low","value":10}'
   ```

3. Enviá un evento que debería ser **aceptado**:

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"high","value":99}'
   ```

4. Inspeccioná los logs del Sensor y confirmá que se creó exactamente un Pod:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=15 | grep -i filter
   kubectl -n argo-events get pods -l events.argoproj.io/sensor=webhook | grep filtered-
   ```

**Chequeo de comprensión**

- Q4.1 — ¿Por qué el `value` del data filter se escribe como la **cadena** `"50"` y el campo se tipa `type: number`? ¿Qué controla en realidad el campo `type` durante la comparación?
- Q4.2 — Configuraste tanto un filter `data` como un filter `exprs` en la misma dependency. ¿Se combinan con AND u OR *entre los dos tipos de filter*? ¿Qué campo cambiarías para que las dos condiciones `data` (si tuvieras dos) se combinen con OR en su lugar?
- Q4.3 — Un compañero quiere "disparar solo de lunes a viernes, 09:00–17:00 UTC". ¿Qué tipo de filter cubre eso, y mira el payload del evento o el context/time del evento? Nombrá un caso límite que hace que los time filters sean sorprendentes cerca de la medianoche.

---

## Ejercicio 5 — Parametrización y un trigger de Argo Workflow

El verdadero poder de Argo Events es inyectar datos del evento *dentro* del objeto disparado. Acá el `message` del payload del webhook se convierte en un parameter del Workflow.

1. (Si Argo Workflows no está instalado, instalá solo el controller/CRDs para que los objetos `Workflow` sean honrados:)

   ```bash
   kubectl create namespace argo 2>/dev/null || true
   kubectl apply -n argo \
     -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/install.yaml
   ```

2. Apuntá el trigger a un `argoWorkflow` y parametrizalo. `parameters[].src` lee una clave del evento; `dest` es una ruta dentro del recurso renderizado:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
     triggers:
       - template:
           name: webhook-workflow-trigger
           argoWorkflow:
             operation: submit
             source:
               resource:
                 apiVersion: argoproj.io/v1alpha1
                 kind: Workflow
                 metadata:
                   generateName: from-event-
                 spec:
                   entrypoint: echo
                   arguments:
                     parameters:
                       - name: message
                         value: "default-if-unset"
                   templates:
                     - name: echo
                       inputs:
                         parameters:
                           - name: message
                       container:
                         image: busybox
                         command: ["echo"]
                         args: ["{{inputs.parameters.message}}"]
             parameters:
               - src:
                   dependencyName: test-dep
                   dataKey: body.message
                 dest: spec.arguments.parameters.0.value
   EOF
   ```

3. Dispará un evento y observá cómo fluye el parameter:

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"provisioned-by-event"}'
   kubectl -n argo-events get workflows
   ```

   Esperado:

   ```
   NAME             STATUS      AGE
   from-event-x7k2  Succeeded   12s
   ```

4. Confirmá que el valor inyectado realmente llegó al container:

   ```bash
   POD=$(kubectl -n argo-events get pod -l workflows.argoproj.io/completed=true \
         -o jsonpath='{.items[-1:].metadata.name}')
   kubectl -n argo-events logs "$POD" -c main
   ```

   Esperado: `provisioned-by-event`

**Chequeo de comprensión**

- Q5.1 — `dest: spec.arguments.parameters.0.value` usa un índice numérico. ¿A qué se refiere el `0`, y qué pasa si cambia el orden de la lista `parameters` del template fuente?
- Q5.2 — El spec del Workflow trae un `value: "default-if-unset"` hardcodeado. ¿Bajo qué condición ese default sobrevive dentro del Workflow en ejecución en lugar del valor del evento? (Pista: pensá en que `dataKey` resuelva a una ruta inexistente.)
- Q5.3 — Usaste `operation: submit` para un Workflow. Si en cambio apuntaras un trigger de K8s a un Deployment existente y quisieras que el evento actualice su image tag, ¿qué `operation` y qué campo extra (más allá de `parameters`) necesitarías para que el Sensor haga patch en lugar de reemplazar?

---

## Ejercicio 6 — Diagnóstico: el manual del "no pasó nada"

Los sistemas orientados a eventos fallan *silenciosamente* — sin error, simplemente sin acción. Este ejercicio es un simulacro deliberado de rotura y diagnóstico. Ejecutá cada chequeo de arriba hacia abajo; el primero que sea anormal es tu culpable.

1. **Rompelo a propósito.** Introducí una discrepancia de nombres:

   ```bash
   kubectl -n argo-events patch sensor webhook --type=json \
     -p='[{"op":"replace","path":"/spec/dependencies/0/eventName","value":"typo"}]'
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"where did I go"}'
   ```

2. **Peldaño 1 — ¿está sano el bus?** Un EventBus degradado detiene todo:

   ```bash
   kubectl -n argo-events get eventbus default \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   kubectl -n argo-events get pods -l controller=eventbus-controller
   ```

3. **Peldaño 2 — ¿publicó la source?** Buscá la confirmación de publish:

   ```bash
   kubectl -n argo-events logs -l eventsource-name=webhook --tail=3 | grep -i publish
   ```

4. **Peldaño 3 — ¿el sensor recibió y evaluó?** Acá es donde se ve la discrepancia:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=20
   ```

   Vas a ver el evento llegar pero ninguna línea `successfully processed the trigger`, porque la dependency `test-dep` ahora espera el evento `typo` que nunca llega.

5. **Peldaño 4 — problemas a nivel del controller** (validación de CRD, cableado del EventBus):

   ```bash
   kubectl -n argo-events logs deploy/controller-manager --tail=30
   ```

6. **Arreglalo y confirmá la recuperación:**

   ```bash
   kubectl -n argo-events patch sensor webhook --type=json \
     -p='[{"op":"replace","path":"/spec/dependencies/0/eventName","value":"example"}]'
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"back online"}'
   kubectl -n argo-events logs -l sensor-name=webhook --tail=3 | grep processed
   ```

**Chequeo de comprensión**

- Q6.1 — Ordená los cuatro "peldaños" (salud del EventBus, publish del EventSource, recepción/evaluación del Sensor, controller) como un árbol de decisión. Si el Peldaño 2 muestra un publish exitoso pero el Peldaño 3 muestra que el evento nunca llegó al Sensor en absoluto, ¿qué componente es el principal sospechoso — y en qué se diferencia de que el Peldaño 3 muestre el evento llegando pero sin disparar?
- Q6.2 — Dos Sensors comparten accidentalmente el mismo EventBus *y* el mismo `name` de dependency. Explicá por qué el naming de durable-consumer en JetStream puede hacer que un Sensor "robe" los eventos del otro. ¿Qué campo los aísla?
- Q6.3 — Un trigger falla de forma intermitente contra un endpoint HTTP downstream inestable. ¿Qué construcción a nivel del Sensor permite que el trigger reintente con backoff, y cuál es el riesgo de combinar reintentos agresivos con un trigger `create` no idempotente?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1 — EventBus y controller**

- **A1.1** — Los nodos de JetStream/NATS son *pares con estado*: cada uno tiene una identidad estable, un volumen persistente para el almacén de mensajes, y forman un cluster (quorum RAFT para JetStream) que requiere identidades de red estables (`eventbus-default-js-0/1/2`). Un StatefulSet da nombres de pod ordenados y estables y PVCs por pod. Un Deployment común daría pods efímeros e intercambiables detrás de una única IP — los nodos no podrían formar un cluster estable, la elección de quorum/líder oscilaría, y los mensajes persistidos se perderían o quedarían en split-brain al reprogramarse.
- **A1.2** — No. Los buses son independientes; el tráfico existente se queda en `default`. El campo `spec.eventBusName` en un EventSource y en un Sensor decide la pertenencia; cuando se omite, toma por defecto `default`. Para mover el tráfico a `ci` pondrías `eventBusName: ci` tanto en la source como en el sensor (ambos deben coincidir, o no pueden encontrarse).
- **A1.3** — El bus legacy native NATS Streaming materializa un StatefulSet con sufijo `-stan` (`eventbus-default-stan`); JetStream materializa `-js`. El sufijo te dice de un vistazo en qué transporte estás, lo cual importa porque NATS Streaming (STAN) está deprecado/EOL, tiene una persistencia y una semántica de durable-consumer distintas, y modos de falla distintos a JetStream. Diagnosticar "mensajes no reproducidos" difiere entre los dos.

**Ejercicio 2 — Webhook EventSource y CloudEvents**

- **A2.1** — El **controller** de Argo Events reconcilia el CR de EventSource en un Deployment (`webhook-eventsource`) y, porque especificaste un bloque `service:`, un Service (`webhook-eventsource-svc`). Ambos llevan el label `eventsource-name=webhook`, que es la razón por la que `-l eventsource-name=webhook` los selecciona juntos.
- **A2.2** — Un CloudEvent tiene un **`context`** (metadata: `id`, `source` = el nombre del EventSource, `type`, `subject` = el nombre del evento `example`, `specversion`, `time`) y un payload **`data`**. Para la source de webhook, `data` es `{"header": {...}, "body": {...}}`. Tu JSON cae bajo `data.body`, así que `message` se alcanza como `body.message` (el prefijo `data.` es implícito en `dataKey`/`path`).
- **A2.3** — Sí, se publicó en el EventBus y luego se **descartó**, porque sin ningún subscriber no había un durable consumer que lo retuviera. Que un Sensor *posterior* pueda reproducirlo depende de la persistencia/retención del EventBus y de si existe un durable consumer con una política de replay — por defecto, un Sensor creado después del evento **no** verá eventos históricos; consume desde el punto en que se suscribe. (Por esto siempre creás el Sensor antes de disparar eventos de prueba, o contás con volver a dispararlos.)

**Ejercicio 3 — Sensor, trigger, RBAC**

- **A3.1** — El *pod* del Sensor está bien; la falla está en la ejecución del trigger contra el API server. El Sensor registra un error de trigger y el API server devuelve **HTTP 403 Forbidden** (`pods is forbidden: User "system:serviceaccount:argo-events:default" cannot create resource "pods"`). Arreglo = darle al `serviceAccountName` del Sensor un Role/RoleBinding que permita `create` sobre el recurso objetivo.
- **A3.2** — El **EventSource** registró "succeeded to publish an event" — su trabajo (ingerir → publicar) tuvo éxito sin importar ningún consumer. El **Sensor** está ahora descartando el evento porque su dependency filtra por `eventName: example` mientras que el evento llega como `demo`; un evento que no coincide simplemente no satisface ninguna dependency, y "ninguna dependency coincidió" es una condición normal, no de error — así que se registra a nivel debug/info, no como error. Nada está "mal" desde la perspectiva de ningún componente individual, que es exactamente por qué las discrepancias de nombres son tan difíciles de detectar.
- **A3.3** — Con un `name:` fijo y `operation: create`, el create del segundo evento devolvería **AlreadyExists (HTTP 409)** y el trigger daría error. `generateName` evita esto acuñando un nombre único por evento. Para "reconciliar este objeto con el último evento", cambiá a `operation: update` (o `patch`), que hace upsert/muta el objeto existente en lugar de fallar.

**Ejercicio 4 — Filters**

- **A4.1** — Las entradas `value` de un filter siempre se serializan como cadenas en YAML; `type: number` le indica al motor de filtros que **parsee tanto el campo del evento como el valor de comparación como números** antes de aplicar `comparator`. Sin `type: number`, `">"` sobre `"10"` vs `"50"` sería una comparación de *cadenas* (lexicográfica), donde `"9" > "50"` es verdadero — un bug de filtro clásico. `type` selecciona la semántica de comparación (number/string/bool).
- **A4.2** — Entre tipos de filter *diferentes* (`data` y `exprs`), el resultado se combina con **AND** lógico — cada tipo configurado debe pasar. Dentro de la lista `data`, el campo `dataLogicalOperator` (`"and"`/`"or"`) controla cómo se combinan múltiples condiciones `data`; el análogo `exprLogicalOperator` gobierna múltiples `exprs`. Así que para hacer OR de dos condiciones data ponés `dataLogicalOperator: "or"`.
- **A4.3** — El **time filter** cubre las ventanas de horario laboral; inspecciona el **context time del evento** (`context.time`), no el payload. El caso límite sorprendente: un time filter con `start` posterior a `stop` (p. ej. `start: "22:00:00"`, `stop: "06:00:00"`) se interpreta como una ventana que **cruza la medianoche**, y todo se evalúa en **UTC** — confundir eso con la hora local es el típico bug de "¿por qué se disparó a la hora equivocada?".

**Ejercicio 5 — Parametrización y trigger de Workflow**

- **A5.1** — `spec.arguments.parameters.0.value` direcciona el **primer elemento (índice 0)** del array `parameters` en el Workflow renderizado — acá el parameter `message`. Si cambia el orden de los parameters del template fuente, el índice `0` ahora apunta a un parameter *diferente* y vas a inyectar el valor del evento en el campo equivocado. Preferí mantener estable el orden de la lista, o (en versiones más nuevas de Argo Events) apuntar por una ruta estable donde esté soportado.
- **A5.2** — El default hardcodeado sobrevive cuando `dataKey: body.message` **no logra resolverse** — es decir, el evento no tiene `body.message`. La resolución del parameter recae en el valor ya presente en `dest` (el default del template). Así que un evento malformado o un campo del body renombrado envía silenciosamente `default-if-unset` a producción. También podés poner `src.value` como fallback explícito en el propio parameter.
- **A5.3** — Usá `operation: update` (o `patch`) en lugar de `create`, y configurá apropiadamente el manejo de `k8s.patchStrategy`/`liveObject` del trigger (para un strategic-merge o JSON patch aportás el documento de patch; para `update` tenés que hacer fetch-and-merge). Los parameters igual inyectan el nuevo image tag vía `dest`, pero la operation debe ser una que mute el objeto vivo en lugar de crear uno nuevo.

**Ejercicio 6 — Diagnóstico**

- **A6.1** — Árbol de decisión, de afuera hacia adentro: **(1) ¿EventBus sano?** (si `Deployed`/`Configured` no están en `True`, arreglá el bus primero — nada más puede funcionar). **(2) ¿EventSource publicó?** (hacé grep de "succeeded to publish"). **(3) ¿El Sensor recibió y evaluó?** **(4) ¿Errores del controller?** Si el Peldaño 2 muestra un publish exitoso pero el Peldaño 3 muestra que el evento **nunca llegó al Sensor**, el principal sospechoso es el **cableado del EventBus** — un `eventBusName` que no coincide entre source y sensor, o un consumer del bus degradado — los dos extremos no están en el mismo bus. Si en cambio el evento **llega pero no dispara**, la falla está *dentro del Sensor*: una discrepancia de nombre/evento de la dependency o un filter que lo rechaza. Mismo síntoma ("sin acción"), arreglo completamente distinto.
- **A6.2** — En JetStream, cada dependency de Sensor se mapea a un **durable consumer** cuyo nombre se deriva de la identidad EventBus + dependency. Dos Sensors en el mismo bus que reutilizan el mismo `name` de dependency pueden resolverse al **mismo durable consumer**, y JetStream entrega cada mensaje a un durable consumer **una sola vez** — así que los dos Sensors compiten y uno "roba" los mensajes que el otro esperaba. Aislalos dándole a cada Sensor sus propios nombres de dependency (y, para un aislamiento más fuerte, un `eventBusName` separado).
- **A6.3** — El **`retryStrategy`** del template del trigger (`steps`, `duration`, `factor`, `jitter`) provee retry-con-backoff. El peligro con un trigger `create` no idempotente son los **efectos secundarios duplicados**: un reintento que en realidad tuvo éxito pero cuya respuesta se perdió creará un *segundo* objeto/Workflow. Mitigalo con operaciones idempotentes (`generateName` colisiona menos pero igual duplica en el reintento; preferí un nombre determinístico + `update`/upsert, o dedup basado en el `context.id` del CloudEvent).

</details>