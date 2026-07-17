# 3.1 — Implement probes and health checks · Ejercicios guiados

> **Requisitos:** un cluster de práctica (minikube, kind o similar) y `kubectl` configurado. Trabajá en un namespace limpio:
>
> ```bash
> kubectl create namespace probes-lab
> kubectl config set-context --current --namespace=probes-lab
> ```

---

## Ejercicio 1 — Liveness probe con `exec`

Una **liveness probe** le dice al kubelet si el container sigue vivo. Si falla, el kubelet **reinicia el container**. Vamos a simular una app que "se cuelga" después de 30 segundos.

1. Creá el archivo `liveness-exec.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: liveness-exec
   spec:
     containers:
     - name: app
       image: busybox:1.36
       args:
       - /bin/sh
       - -c
       - touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
       livenessProbe:
         exec:
           command:
           - cat
           - /tmp/healthy
         initialDelaySeconds: 5
         periodSeconds: 5
   ```

2. Aplicalo y observá el Pod en tiempo real:

   ```bash
   kubectl apply -f liveness-exec.yaml
   kubectl get pod liveness-exec -w
   ```

3. Esperá ~60 segundos. Vas a ver que la columna `RESTARTS` empieza a incrementar. Cortá el watch con `Ctrl+C`.

4. Mirá los eventos para entender qué pasó:

   ```bash
   kubectl describe pod liveness-exec
   ```

   Buscá en la sección `Events` líneas del tipo `Liveness probe failed` y `Container app failed liveness probe, will be restarted`.

**Preguntas:**

- **P1.** Con `periodSeconds: 5` y el `failureThreshold` por defecto, ¿cuántos segundos pasan (aproximadamente) entre que se borra `/tmp/healthy` y el reinicio del container?
- **P2.** ¿Por qué aumenta el contador `RESTARTS` en lugar de crearse un Pod nuevo con otro nombre?

---

## Ejercicio 2 — Liveness probe con `httpGet` y auto-reparación

Las probes HTTP consideran **éxito cualquier código de estado ≥ 200 y < 400**. Vamos a romper un nginx a propósito y ver cómo la liveness probe lo "cura".

1. Creá el archivo `liveness-http.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: liveness-http
   spec:
     containers:
     - name: web
       image: nginx:1.27
       ports:
       - containerPort: 80
       livenessProbe:
         httpGet:
           path: /
           port: 80
         initialDelaySeconds: 3
         periodSeconds: 5
   ```

2. Aplicalo y verificá que quede `Running` con `0` restarts:

   ```bash
   kubectl apply -f liveness-http.yaml
   kubectl get pod liveness-http
   ```

3. Ahora rompé la app: borrá la página que responde en `/`:

   ```bash
   kubectl exec liveness-http -- rm /usr/share/nginx/html/index.html
   ```

   Sin `index.html`, nginx responde `403 Forbidden` en `/`.

4. Observá el Pod durante ~30 segundos:

   ```bash
   kubectl get pod liveness-http -w
   ```

5. Cuando veas `RESTARTS: 1`, verificá que la página volvió:

   ```bash
   kubectl exec liveness-http -- ls /usr/share/nginx/html/
   ```

**Preguntas:**

- **P3.** ¿Por qué un `403 Forbidden` hace fallar la probe si el proceso nginx sigue corriendo y respondiendo?
- **P4.** ¿Por qué después del reinicio `index.html` volvió a existir, si nadie lo recreó a mano?

---

## Ejercicio 3 — Readiness probe y su efecto en el Service

Una **readiness probe** no reinicia nada: decide si el Pod **recibe tráfico**. Mientras falla, el Pod se saca de los endpoints del Service.

1. Creá el archivo `readiness.yaml` con un Deployment y su Service:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
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
         - name: web
           image: nginx:1.27
           ports:
           - containerPort: 80
           readinessProbe:
             exec:
               command:
               - cat
               - /tmp/ready
             periodSeconds: 5
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web
     ports:
     - port: 80
       targetPort: 80
   ```

2. Aplicalo y mirá el estado:

   ```bash
   kubectl apply -f readiness.yaml
   kubectl get pods -l app=web
   ```

   Los Pods están `Running` pero la columna `READY` muestra `0/1`, porque `/tmp/ready` no existe.

3. Confirmá que el Service **no tiene endpoints**:

   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=web
   ```

4. "Habilitá" uno solo de los Pods (reemplazá `<POD1>` por el nombre real):

   ```bash
   kubectl exec <POD1> -- touch /tmp/ready
   ```

5. Repetí los comandos del paso 2 y 3: un Pod pasa a `1/1` y su IP aparece en el EndpointSlice; el otro sigue fuera.

6. Notá que ningún Pod fue reiniciado en todo el ejercicio:

   ```bash
   kubectl get pods -l app=web
   ```

**Preguntas:**

- **P5.** ¿Cuál es la diferencia clave entre el efecto de una liveness probe fallida y una readiness probe fallida?
- **P6.** Durante un rolling update de un Deployment, ¿qué rol cumple la readiness probe para evitar downtime?
- **P7.** Si un Pod de este Deployment pierde su readiness después de haber estado `Ready` (por ejemplo, alguien borra `/tmp/ready`), ¿qué pasa con él?

---

## Ejercicio 4 — Startup probe para apps que arrancan lento

Una app que tarda mucho en arrancar puede ser asesinada por su propia liveness probe antes de estar lista. La **startup probe** desactiva las otras probes hasta que el arranque termina.

1. Creá el archivo `startup.yaml`. La app simula un arranque de ~40 segundos:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: slow-start
   spec:
     containers:
     - name: app
       image: busybox:1.36
       args:
       - /bin/sh
       - -c
       - sleep 40; touch /tmp/started; sleep 3600
       startupProbe:
         exec:
           command:
           - cat
           - /tmp/started
         periodSeconds: 5
         failureThreshold: 12
       livenessProbe:
         exec:
           command:
           - cat
           - /tmp/started
         periodSeconds: 5
         failureThreshold: 2
   ```

2. Aplicalo y observá:

   ```bash
   kubectl apply -f startup.yaml
   kubectl get pod slow-start -w
   ```

   El Pod tarda ~40–45 segundos en pasar a `READY 1/1`, **sin ningún restart**.

3. Verificá en los eventos que la startup probe falló varias veces sin consecuencias fatales:

   ```bash
   kubectl describe pod slow-start | grep -A5 Events
   ```

4. Para comparar, editá el manifiesto: borrá el bloque `startupProbe` completo, borrá el Pod y volvé a aplicar:

   ```bash
   kubectl delete pod slow-start
   kubectl apply -f startup.yaml
   kubectl get pod slow-start -w
   ```

   Ahora la liveness probe (que tolera solo 2 fallos × 5s) mata el container antes de que termine el `sleep 40`, una y otra vez: el Pod entra en `CrashLoopBackOff`.

**Preguntas:**

- **P8.** Con `periodSeconds: 5` y `failureThreshold: 12`, ¿cuánto tiempo máximo de arranque tolera esta startup probe?
- **P9.** ¿Por qué la startup probe es mejor solución que ponerle un `initialDelaySeconds: 60` a la liveness probe?
- **P10.** ¿La liveness probe y la readiness probe se ejecutan mientras la startup probe todavía no tuvo éxito?

---

## Ejercicio 5 — `tcpSocket` y los parámetros de las probes

No todas las apps hablan HTTP. Para bases de datos y similares se usa `tcpSocket`: la probe tiene éxito si logra abrir la conexión TCP.

1. Creá un Pod con redis y probe TCP, esta vez de forma rápida con `kubectl run` + edición. Primero generá la base:

   ```bash
   kubectl run redis --image=redis:7 --dry-run=client -o yaml > redis.yaml
   ```

2. Editá `redis.yaml` y agregale al container las dos probes:

   ```yaml
       readinessProbe:
         tcpSocket:
           port: 6379
         initialDelaySeconds: 2
         periodSeconds: 5
       livenessProbe:
         tcpSocket:
           port: 6379
         initialDelaySeconds: 10
         periodSeconds: 10
         timeoutSeconds: 2
   ```

3. Aplicá y confirmá que queda `1/1 Running`:

   ```bash
   kubectl apply -f redis.yaml
   kubectl get pod redis
   ```

4. En el examen no hay tiempo para buscar en la documentación cada campo. Practicá sacarlos con `kubectl explain`:

   ```bash
   kubectl explain pod.spec.containers.livenessProbe
   kubectl explain pod.spec.containers.livenessProbe.httpGet
   ```

   Leé en la salida los valores por defecto de `periodSeconds`, `timeoutSeconds`, `failureThreshold` y `successThreshold`.

5. Limpieza final del laboratorio:

   ```bash
   kubectl delete namespace probes-lab
   kubectl config set-context --current --namespace=default
   ```

**Preguntas:**

- **P11.** ¿Cuáles son los valores por defecto de `periodSeconds`, `timeoutSeconds`, `failureThreshold` y `successThreshold`?
- **P12.** ¿Para qué probe está **prohibido** que `successThreshold` sea distinto de 1, y por qué tiene sentido esa restricción?
- **P13.** Nombrá los cuatro mecanismos de chequeo que puede usar una probe.

---

## Respuestas

<details>
<summary>Ver respuestas</summary>

- **P1.** El `failureThreshold` por defecto es **3**. Con `periodSeconds: 5`, el kubelet necesita 3 fallos consecutivos: aproximadamente **15 segundos** (más algún margen por el momento exacto de cada chequeo) entre que el archivo desaparece y el reinicio.

- **P2.** La liveness probe la maneja el **kubelet**, que reinicia el **container** dentro del mismo Pod según su `restartPolicy` (por defecto `Always`). El Pod nunca se destruye ni se reprograma: conserva nombre, IP y nodo; solo cambia el container, y eso se refleja en `RESTARTS`.

- **P3.** Una probe `httpGet` no chequea si el proceso vive, sino la **respuesta HTTP**: solo los códigos ≥ 200 y < 400 cuentan como éxito. `403` está fuera de ese rango, así que la probe falla aunque nginx esté corriendo. Es justamente el valor de las probes: detectan apps "vivas pero rotas".

- **P4.** Al reiniciar, el kubelet crea un **container nuevo desde la imagen**, descartando la capa de escritura donde se había borrado el archivo. Todo lo que no esté en un volumen se pierde (o se recupera, en este caso) con cada restart.

- **P5.** Liveness fallida → el kubelet **reinicia el container**. Readiness fallida → el Pod se marca `NotReady` y se **quita de los endpoints del Service** (no recibe tráfico), pero el container sigue corriendo intacto.

- **P6.** Durante el rollout, el Deployment espera a que los Pods nuevos estén `Ready` antes de seguir bajando los viejos (respetando `maxUnavailable`/`maxSurge`). Sin readiness probe, un Pod se considera listo apenas arranca el container, y el Service podría enviar tráfico a réplicas que aún no pueden atenderlo.

- **P7.** No pasa nada destructivo: el Pod vuelve a `NotReady`, se retira de los endpoints del Service y deja de recibir tráfico. Si la probe vuelve a tener éxito (según `successThreshold`), el Pod se reincorpora automáticamente. Nunca se reinicia por readiness.

- **P8.** `12 × 5s = 60 segundos` como máximo (más el tiempo del primer chequeo). Si en ese lapso la probe no tiene éxito, el container se reinicia como si hubiera fallado la liveness.

- **P9.** `initialDelaySeconds: 60` penaliza **todos** los arranques con una espera fija: si la app arranca en 5 segundos, igual queda 60 segundos sin protección de liveness. La startup probe se adapta: apenas tiene éxito, cede el control a las otras probes, y a la vez tolera arranques lentos hasta su límite (`failureThreshold × periodSeconds`).

- **P10.** No. Mientras la startup probe no haya tenido éxito, la liveness y la readiness probes están **deshabilitadas**. Recién cuando la startup probe pasa, las otras dos empiezan a ejecutarse.

- **P11.** Por defecto: `periodSeconds: 10`, `timeoutSeconds: 1`, `failureThreshold: 3`, `successThreshold: 1`. (`initialDelaySeconds` es 0 si no se indica.)

- **P12.** Para la **liveness** (y también la startup) probe, `successThreshold` debe ser 1. Tiene sentido: después de un reinicio el container arranca "de cero"; exigir varios éxitos consecutivos para declararlo vivo no aporta nada y complicaría el ciclo de reinicio. En cambio, en readiness puede ser útil exigir varios éxitos antes de volver a enviar tráfico.

- **P13.** `exec` (ejecuta un comando dentro del container; éxito si sale con código 0), `httpGet` (éxito si el código HTTP es ≥ 200 y < 400), `tcpSocket` (éxito si se puede abrir la conexión TCP) y `grpc` (éxito si el servicio responde `SERVING` al health-checking protocol de gRPC).

</details>

---

## Referencias

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle (container probes): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes