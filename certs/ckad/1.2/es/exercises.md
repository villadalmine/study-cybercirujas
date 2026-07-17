# Ejercicios guiados — 1.2 Choose and use the right workload resource

> **Requisitos previos:** un cluster de Kubernetes funcionando (minikube, kind o similar) y `kubectl` configurado. Todos los ejercicios usan el namespace `workloads-lab` que se crea en el primer paso.

---

## Preparación

1. Creá un namespace para trabajar aislado y configuralo como default del contexto:

   ```bash
   kubectl create namespace workloads-lab
   kubectl config set-context --current --namespace=workloads-lab
   ```

2. Verificá que el namespace activo sea el correcto:

   ```bash
   kubectl config view --minify | grep namespace
   ```

---

## Ejercicio 1 — Deployment: crear, inspeccionar y escalar

1. Creá un Deployment de forma imperativa:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   ```

2. Observá los tres niveles de objetos que se crearon:

   ```bash
   kubectl get deployments,replicasets,pods
   ```

3. Mirá el nombre completo de los Pods. Fijate en el patrón `web-<hash>-<sufijo>`.

4. Escalá el Deployment a 5 réplicas y observá el resultado:

   ```bash
   kubectl scale deployment web --replicas=5
   kubectl get pods --watch
   ```

   (Cortá el watch con `Ctrl+C` cuando los 5 Pods estén `Running`.)

5. Borrá uno de los Pods a mano y observá qué pasa:

   ```bash
   kubectl delete pod <nombre-de-un-pod-web>
   kubectl get pods
   ```

**Preguntas:**

- **1.a** ¿Qué objeto creó los Pods: el Deployment o el ReplicaSet? ¿Qué rol cumple cada uno?
- **1.b** ¿Por qué al borrar un Pod aparece uno nuevo casi de inmediato? ¿Qué componente lo recrea?
- **1.c** ¿Qué parte del nombre del Pod identifica al ReplicaSet al que pertenece?

---

## Ejercicio 2 — Rollout y rollback de un Deployment

1. Actualizá la imagen del Deployment y registrá el cambio:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.28
   ```

2. Seguí el progreso del rollout:

   ```bash
   kubectl rollout status deployment/web
   ```

3. Mirá cuántos ReplicaSets existen ahora y sus réplicas:

   ```bash
   kubectl get replicasets
   ```

4. Consultá el historial de revisiones:

   ```bash
   kubectl rollout history deployment/web
   ```

5. Ahora rompé el Deployment a propósito con una imagen inexistente:

   ```bash
   kubectl set image deployment/web nginx=nginx:no-existe
   kubectl get pods
   ```

   Observá los Pods en estado `ImagePullBackOff` / `ErrImagePull`.

6. Volvé a la revisión anterior:

   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   ```

7. Inspeccioná la estrategia de actualización del Deployment:

   ```bash
   kubectl describe deployment web | grep -A 3 StrategyType
   ```

**Preguntas:**

- **2.a** Durante el rollout del paso 1, ¿los Pods viejos se borran todos de golpe? ¿Qué controla los valores `maxUnavailable` y `maxSurge`?
- **2.b** ¿Por qué después del paso 5 el sitio seguía teniendo Pods `Running` a pesar de la imagen rota?
- **2.c** ¿Por qué el ReplicaSet viejo queda con 0 réplicas en lugar de borrarse? ¿Qué campo del Deployment limita cuántos se conservan?
- **2.d** ¿Qué diferencia hay entre la estrategia `RollingUpdate` y `Recreate`, y en qué caso usarías `Recreate`?

---

## Ejercicio 3 — DaemonSet: un Pod por nodo

1. Un DaemonSet no se puede crear con `kubectl create`, así que generá primero un manifest de Deployment y adaptalo:

   ```bash
   kubectl create deployment agente --image=busybox:1.36 \
     --dry-run=client -o yaml > daemonset.yaml
   ```

2. Editá `daemonset.yaml`: cambiá `kind: Deployment` por `kind: DaemonSet`, borrá el campo `replicas` y el campo `strategy` (si aparece), y agregale un comando al container para que no termine enseguida. Debe quedar similar a:

   ```yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: agente
   spec:
     selector:
       matchLabels:
         app: agente
     template:
       metadata:
         labels:
           app: agente
       spec:
         containers:
         - name: busybox
           image: busybox:1.36
           command: ["sleep", "infinity"]
   ```

3. Aplicalo y observá dónde corre cada Pod:

   ```bash
   kubectl apply -f daemonset.yaml
   kubectl get pods -o wide
   kubectl get nodes
   ```

4. Compará la cantidad de Pods del DaemonSet con la cantidad de nodos del cluster.

**Preguntas:**

- **3.a** ¿Por qué el DaemonSet no tiene campo `replicas`? ¿Quién decide cuántos Pods hay?
- **3.b** Si mañana se agrega un nodo nuevo al cluster, ¿qué pasa con este DaemonSet, sin que nadie toque nada?
- **3.c** Nombrá dos casos de uso típicos donde un DaemonSet es la elección correcta en lugar de un Deployment.

---

## Ejercicio 4 — Job: tareas que terminan

1. Creá un Job simple que calcule π y termine:

   ```bash
   kubectl create job pi --image=perl:5.34 -- perl -Mbignum=bpi -wle 'print bpi(200)'
   ```

2. Observá su ciclo de vida y su salida:

   ```bash
   kubectl get jobs,pods
   kubectl logs job/pi
   ```

3. Fijate en el estado final del Pod: no dice `Running`, dice `Completed`.

4. Ahora creá un Job con varias ejecuciones. Guardá esto como `job-lote.yaml` y aplicalo:

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: lote
   spec:
     completions: 6
     parallelism: 2
     backoffLimit: 3
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: tarea
           image: busybox:1.36
           command: ["sh", "-c", "echo procesando item; sleep 5"]
   ```

   ```bash
   kubectl apply -f job-lote.yaml
   kubectl get pods --watch
   ```

5. Cuando termine, revisá el resumen:

   ```bash
   kubectl get job lote
   ```

**Preguntas:**

- **4.a** ¿Qué significan `completions: 6` y `parallelism: 2` combinados? ¿Cuántos Pods viste corriendo a la vez?
- **4.b** ¿Qué hace `backoffLimit: 3` si el comando del container falla?
- **4.c** ¿Por qué un Job exige `restartPolicy: Never` o `OnFailure`, y no acepta `Always` (el default de un Deployment)?
- **4.d** Si necesitás correr un script de migración de base de datos una única vez, ¿usás un Deployment o un Job? ¿Por qué?

---

## Ejercicio 5 — CronJob: tareas programadas

1. Creá un CronJob que corra cada minuto:

   ```bash
   kubectl create cronjob reloj --image=busybox:1.36 \
     --schedule="*/1 * * * *" -- date
   ```

2. Esperá un par de minutos y observá lo que se va creando:

   ```bash
   kubectl get cronjobs,jobs,pods
   ```

3. Leé la salida de la última ejecución:

   ```bash
   kubectl logs job/<nombre-del-job-mas-reciente>
   ```

4. Inspeccioná los campos de control del CronJob:

   ```bash
   kubectl get cronjob reloj -o yaml | grep -E "concurrencyPolicy|successfulJobsHistoryLimit|failedJobsHistoryLimit|suspend"
   ```

5. Suspendé el CronJob sin borrarlo y verificá que deja de crear Jobs:

   ```bash
   kubectl patch cronjob reloj -p '{"spec":{"suspend":true}}'
   kubectl get cronjob reloj
   ```

6. Disparalo manualmente una vez, fuera del schedule (muy útil en el examen para probar sin esperar):

   ```bash
   kubectl create job reloj-manual --from=cronjob/reloj
   kubectl logs job/reloj-manual
   ```

**Preguntas:**

- **5.a** ¿Qué cadena de objetos crea un CronJob en cada ejecución, hasta llegar al container que corre?
- **5.b** ¿Qué significa el schedule `*/1 * * * *`? ¿Y cómo escribirías "todos los días a las 03:30"?
- **5.c** ¿Para qué sirve `concurrencyPolicy` y cuáles son sus tres valores posibles?
- **5.d** ¿Por qué `kubectl create job --from=cronjob/...` es más práctico que esperar al schedule cuando estás bajo el tiempo del examen?

---

## Ejercicio 6 — Elegir el recurso correcto (escenarios)

Sin ejecutar nada, decidí qué workload resource usarías en cada escenario. Después verificá contra las respuestas.

- **6.a** Una API REST stateless que debe estar siempre disponible, con actualizaciones sin downtime.
- **6.b** Un colector de logs que debe correr en **todos** los nodos, incluidos los que se agreguen a futuro.
- **6.c** Un backup de base de datos que debe ejecutarse todos los domingos a la 01:00.
- **6.d** Un procesamiento por lotes de 100 archivos, de a 10 en paralelo, que termina cuando procesó todo.
- **6.e** Una base de datos que necesita identidad de red estable (`db-0`, `db-1`, `db-2`) y un volumen persistente propio por réplica.
- **6.f** Un contenedor de debugging que necesitás correr una sola vez, interactivo, y descartar.

---

## Limpieza

1. Borrá todo el laboratorio de una vez:

   ```bash
   kubectl config set-context --current --namespace=default
   kubectl delete namespace workloads-lab
   ```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

- **1.a** Los Pods los crea el **ReplicaSet**. La cadena es: el Deployment gestiona ReplicaSets (versionado, rollouts, rollbacks) y cada ReplicaSet garantiza que exista el número deseado de Pods idénticos. El Deployment nunca crea Pods directamente.
- **1.b** El **ReplicaSet controller** (dentro del `kube-controller-manager`) detecta que el número de Pods observados (4) no coincide con el deseado (5) y crea uno nuevo para reconciliar el estado. Es el patrón declarativo de Kubernetes: se corrige la diferencia entre estado deseado y estado real.
- **1.c** El hash del medio: en `web-7d9f8c6b5-x2k4p`, la parte `web-7d9f8c6b5` es el nombre del ReplicaSet (el hash `7d9f8c6b5` corresponde al pod template) y `x2k4p` es el sufijo aleatorio del Pod.

### Ejercicio 2

- **2.a** No. Con la estrategia `RollingUpdate` (default), los Pods se reemplazan gradualmente. `maxSurge` define cuántos Pods extra por encima del número deseado se pueden crear durante la transición (default 25%), y `maxUnavailable` cuántos pueden faltar (default 25%). Así siempre hay capacidad sirviendo tráfico.
- **2.b** Justamente por el rolling update: Kubernetes intenta levantar los Pods nuevos primero y **no baja los viejos hasta que los nuevos estén listos**. Como la imagen `nginx:no-existe` nunca llega a `Ready`, los Pods de la revisión anterior siguen `Running`. Esto es una protección clave contra despliegues rotos.
- **2.c** El ReplicaSet viejo se conserva (escalado a 0) para poder hacer **rollback**: `kubectl rollout undo` simplemente vuelve a escalar el ReplicaSet anterior. El campo `spec.revisionHistoryLimit` (default 10) limita cuántos ReplicaSets antiguos se guardan.
- **2.d** `RollingUpdate` reemplaza Pods de a poco, sin downtime. `Recreate` mata **todos** los Pods viejos antes de crear los nuevos, con downtime. `Recreate` se usa cuando dos versiones no pueden coexistir, por ejemplo si comparten un volumen `ReadWriteOnce` o si la versión vieja corrompería datos de la nueva.

### Ejercicio 3

- **3.a** Porque la cantidad de Pods no la decide el usuario: el **DaemonSet controller** crea exactamente un Pod por cada nodo elegible (todos, o los que matcheen su `nodeSelector`/`affinity` y toleren los taints correspondientes). Un campo `replicas` no tendría sentido.
- **3.b** El controller detecta el nodo nuevo y le programa automáticamente un Pod del DaemonSet, sin intervención. Igual, si un nodo se elimina, su Pod desaparece sin ser reprogramado en otro lado.
- **3.c** Ejemplos típicos: agentes de logs (Fluentd, Fluent Bit), agentes de monitoreo por nodo (node-exporter de Prometheus), plugins de red (CNI) o de storage que necesitan presencia en cada nodo. Todos son casos "uno por nodo", no "N réplicas donde quepan".

### Ejercicio 4

- **4.a** El Job debe alcanzar **6 terminaciones exitosas** en total (`completions: 6`), corriendo **como máximo 2 Pods a la vez** (`parallelism: 2`). Deberías haber visto pares de Pods ejecutándose hasta sumar 6 `Completed`.
- **4.b** Es el número de reintentos ante fallas antes de marcar el Job como `Failed`. Con `backoffLimit: 3`, después de 3 reintentos fallidos (con backoff exponencial entre intentos) el Job se da por perdido y deja de crear Pods.
- **4.c** Porque un Job modela trabajo **finito**: el container debe poder terminar con exit code 0. Con `restartPolicy: Always` el kubelet reiniciaría el container eternamente y el Job jamás se completaría. `Never` deja que el Job cree Pods nuevos ante fallas; `OnFailure` reinicia el container en el mismo Pod.
- **4.d** Un **Job**. Una migración es una tarea que corre hasta terminar; un Deployment está pensado para procesos de larga vida y reiniciaría el container al terminar (lo tratás como crash), ejecutando la migración en loop.

### Ejercicio 5

- **5.a** CronJob → crea un **Job** en cada disparo del schedule → el Job crea un **Pod** → el Pod corre el container. Por eso en el paso 2 ves los tres tipos de objetos acumulándose.
- **5.b** `*/1 * * * *` = cada minuto. Los cinco campos son: minuto, hora, día del mes, mes, día de la semana. "Todos los días a las 03:30" sería `30 3 * * *`.
- **5.c** Controla qué pasa si llega el momento de una ejecución y la anterior todavía está corriendo: `Allow` (default) las deja solaparse, `Forbid` saltea la nueva, `Replace` cancela la vieja y arranca la nueva. Para trabajos que no toleran solapamiento (backups, por ejemplo), `Forbid` es lo habitual.
- **5.d** Porque crea un Job inmediato reutilizando el template del CronJob, sin esperar al próximo disparo del schedule. En el CKAD el tiempo es el recurso más escaso: te permite verificar que el CronJob funciona en segundos.

### Ejercicio 6

- **6.a** **Deployment** — stateless, réplicas intercambiables, rolling updates sin downtime.
- **6.b** **DaemonSet** — un Pod por nodo, incorporación automática de nodos nuevos.
- **6.c** **CronJob** — schedule `0 1 * * 0`; conviene `concurrencyPolicy: Forbid` para backups.
- **6.d** **Job** — con `completions: 100` y `parallelism: 10`; termina cuando alcanza las 100 terminaciones exitosas.
- **6.e** **StatefulSet** — da identidad estable y ordenada a los Pods (`db-0`, `db-1`...) y, mediante `volumeClaimTemplates`, un PersistentVolumeClaim propio por réplica. Un Deployment no puede garantizar nada de eso.
- **6.f** Un **Pod** directo (o `kubectl run --rm -it`) — es efímero, único y no necesita controller que lo supervise ni lo recree.

</details>

---

## Fuentes

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes — DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes — Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes — CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes — StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/