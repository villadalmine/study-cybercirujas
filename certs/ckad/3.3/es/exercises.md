# CKAD 3.3 — Utilize container logs

**Peso en el examen:** 4
**Fuente de referencia:** [CKAD Curriculum v1.35 (PDF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)
**Documentación oficial complementaria:** [kubectl logs — referencia](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/) · [Logging Architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)

---

## Preparación del entorno

1. Creá un namespace dedicado para estos ejercicios:

```bash
kubectl create namespace ckad-logs
kubectl config set-context --current --namespace=ckad-logs
```

2. Confirmá que el namespace quedó seleccionado por defecto:

```bash
kubectl config view --minify | grep namespace:
```

**Preguntas de comprensión — Bloque 0**

1. Cuando un container escribe en `stdout`/`stderr`, ¿quién es responsable de capturar y almacenar esas líneas antes de que `kubectl logs` pueda leerlas?

---

## Bloque 1 — `kubectl logs` básico

3. Creá el siguiente Pod, que emite una línea de log cada 2 segundos:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-basic
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "i=0; while true; do i=$((i+1)); echo \"$(date -Iseconds) log-line-$i\"; sleep 2; done"]
```

```bash
kubectl apply -f logger-basic.yaml
kubectl wait --for=condition=Ready pod/logger-basic --timeout=30s
```

4. Esperá unos segundos y consultá el historial completo de logs:

```bash
kubectl logs logger-basic
```

5. Repetí la consulta pidiendo solo las últimas 5 líneas:

```bash
kubectl logs logger-basic --tail=5
```

6. Ahora pedí solo lo que se generó en los últimos 10 segundos:

```bash
kubectl logs logger-basic --since=10s
```

7. Volvé a pedir los logs, pero esta vez con timestamps explícitos del kubelet (útil cuando el propio log no incluye fecha):

```bash
kubectl logs logger-basic --timestamps
```

**Preguntas de comprensión — Bloque 1**

2. ¿Qué diferencia hay entre el timestamp que agrega `--timestamps` y el que ya viene impreso dentro de cada línea por el propio `command` del container?
3. Si el container ya terminó (`Completed`) hace una hora, ¿`kubectl logs` sigue devolviendo su salida? ¿Por qué sí o por qué no?

---

## Bloque 2 — Seguir logs en tiempo real (`-f`)

8. Abrí un stream en vivo de los logs del mismo Pod:

```bash
kubectl logs -f logger-basic
```

9. Dejalo corriendo unos segundos, observá cómo llegan nuevas líneas, y cortalo con `Ctrl+C`.

10. Combinalo con `--tail` para no traer todo el historial al conectar el stream:

```bash
kubectl logs -f --tail=3 logger-basic
```

**Preguntas de comprensión — Bloque 2**

4. Si mientras estás con `kubectl logs -f` corriendo el Pod es eliminado (`kubectl delete pod logger-basic`) en otra terminal, ¿qué le pasa al stream?
5. ¿`kubectl logs -f` reintenta automáticamente la conexión si el container se reinicia mientras el stream está abierto?

---

## Bloque 3 — Pods multi-container

11. Creá un Pod con dos containers, cada uno logueando algo distinto:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-multi
spec:
  containers:
  - name: web
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo \"web: request handled\"; sleep 3; done"]
  - name: worker
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo \"worker: job processed\"; sleep 5; done"]
```

```bash
kubectl apply -f logger-multi.yaml
```

12. Intentá pedir los logs sin especificar container:

```bash
kubectl logs logger-multi
```

13. Ahora indicá explícitamente cuál container querés ver:

```bash
kubectl logs logger-multi -c web
kubectl logs logger-multi -c worker
```

14. Traé los logs de todos los containers a la vez, con el nombre de cada uno como prefijo:

```bash
kubectl logs logger-multi --all-containers=true --prefix=true
```

**Preguntas de comprensión — Bloque 3**

6. ¿Qué mensaje de error da `kubectl logs` en el paso 12, y qué te está pidiendo que hagas?
7. ¿Para qué sirve `--prefix=true` cuando trabajás con `--all-containers=true`?

---

## Bloque 4 — Logs de una instancia anterior del container (`--previous`)

15. Creá un Pod cuyo container se cae después de arrancar (esto va a generar reinicios y eventualmente `CrashLoopBackOff`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-crash
spec:
  restartPolicy: Always
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "echo \"starting up\"; sleep 5; echo \"fatal: simulated crash\"; exit 1"]
```

```bash
kubectl apply -f logger-crash.yaml
```

16. Esperá a que se produzca al menos un reinicio:

```bash
kubectl get pod logger-crash -w
```

(cortá con `Ctrl+C` cuando `RESTARTS` sea 1 o más).

17. Consultá los logs de la instancia **actual** del container y luego los de la instancia **anterior**:

```bash
kubectl logs logger-crash
kubectl logs logger-crash --previous
```

**Preguntas de comprensión — Bloque 4**

8. ¿Por qué `kubectl logs logger-crash` (sin `--previous`) puede mostrarte muy pocas líneas o directamente "starting up" otra vez, en vez del error fatal que ya ocurrió antes?
9. Si el Pod entero (no solo el container) es recreado —por ejemplo porque lo borraste y lo volviste a aplicar—, ¿`--previous` sigue teniendo logs disponibles? ¿Por qué?

---

## Bloque 5 — Patrón sidecar de logging (streaming sidecar)

Muchas aplicaciones legacy escriben sus logs en un archivo dentro del filesystem en vez de en `stdout`. El patrón sidecar resuelve esto agregando un segundo container que lee ese archivo y lo emite por su propio `stdout`, para que `kubectl logs` (y cualquier agente de logging del cluster) pueda capturarlo igual.

18. Creá el siguiente Pod, donde `app` escribe en un archivo compartido y `log-shipper` lo tailea hacia su propio stdout:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger-sidecar
spec:
  volumes:
  - name: shared-logs
    emptyDir: {}
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "i=0; while true; do i=$((i+1)); echo \"$(date -Iseconds) app-event-$i\" >> /var/log/app/app.log; sleep 2; done"]
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
  - name: log-shipper
    image: busybox:1.36
    command: ["sh", "-c", "touch /var/log/app/app.log; tail -n+1 -f /var/log/app/app.log"]
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
```

```bash
kubectl apply -f logger-sidecar.yaml
```

19. Confirmá que el container `app` casi no tiene salida propia por `kubectl logs`, pero el sidecar sí:

```bash
kubectl logs logger-sidecar -c app
kubectl logs logger-sidecar -c log-shipper
```

**Preguntas de comprensión — Bloque 5**

10. ¿Qué recurso de Kubernetes hace posible que ambos containers vean el mismo archivo `app.log`?
11. ¿Qué ventaja tiene este patrón frente a simplemente hacer `kubectl exec logger-sidecar -c app -- cat /var/log/app/app.log` cada vez que necesitás ver el log?

---

## Bloque 6 — Logs de un Job

20. Creá un Job de corta duración:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: log-job
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: reporter
        image: busybox:1.36
        command: ["sh", "-c", "echo 'job started'; sleep 3; echo 'job finished successfully'"]
```

```bash
kubectl apply -f log-job.yaml
kubectl wait --for=condition=complete job/log-job --timeout=30s
```

21. Consultá los logs directamente sobre el objeto Job, sin averiguar primero el nombre del Pod:

```bash
kubectl logs job/log-job
```

**Preguntas de comprensión — Bloque 6**

12. ¿Qué pasaría con `kubectl logs job/log-job` si el Job tuviera `parallelism: 3` y por lo tanto 3 Pods asociados?

---

## Limpieza

22. Eliminá todos los recursos creados:

```bash
kubectl delete namespace ckad-logs
```

---

<details>
<summary><strong>Respuestas</strong></summary>

1. El **container runtime** (containerd/CRI-O vía el kubelet) redirige `stdout`/`stderr` del proceso principal del container a archivos de log en el nodo; `kubectl logs` no lee la app directamente, sino que pide esos datos al kubelet del nodo donde corre el Pod.

2. `--timestamps` agrega un timestamp que pone el **kubelet** al momento de recibir cada línea (con precisión de nanosegundos, en UTC); el que imprime `date -Iseconds` dentro del `command` es generado por la aplicación misma y puede diferir levemente o tener otro formato. Son dos fuentes independientes.

3. Sí, sigue devolviendo la salida, siempre que el container (o su log en el nodo) no haya sido eliminado por rotación de logs o porque el Pod fue borrado. `kubectl logs` no requiere que el container esté corriendo, solo que sus logs sigan existiendo.

4. El stream de `kubectl logs -f` se corta apenas el container desaparece (el kubelet cierra la conexión), mostrando error o simplemente terminando; no hay reconexión automática a un Pod distinto.

5. No. `kubectl logs -f` sigue la salida de una instancia de container específica. Si ese container se reinicia, el stream termina (o puede mostrar un error de conexión) y hay que volver a ejecutar el comando; no salta solo a la nueva instancia.

6. Da un error indicando que el Pod tiene más de un container y que hay que especificar cuál con `-c <nombre>` (o usar `--all-containers`), porque `kubectl logs` no sabe a cuál referirse por defecto.

7. `--prefix=true` antepone a cada línea el nombre del Pod y el container de origen (por ejemplo `[pod/logger-multi/web]`), lo cual es indispensable para distinguir qué container generó cada línea cuando se mezclan varios streams en un mismo output.

8. Porque `kubectl logs` sin `--previous` muestra los logs de la **instancia actualmente activa** del container (la que arrancó después del último reinicio), que recién está en su ciclo de "starting up" y todavía no llegó al `exit 1`. El error anterior quedó en la instancia previa, que solo se ve con `--previous`.

9. No: `--previous` solo conserva logs de la instancia inmediatamente anterior **dentro del mismo Pod** (mismo `spec.containers`, gestionado por el mismo kubelet). Si el Pod entero se borra y se recrea, es un objeto nuevo sin historial de instancias previas; esos logs se pierden a menos que exista un sistema externo de log aggregation.

10. El volumen compartido `emptyDir`, montado en ambos containers en el mismo `mountPath` (`/var/log/app`). `emptyDir` vive mientras el Pod exista y es visible por todos los containers del Pod que lo monten.

11. El patrón sidecar hace que el log quede disponible de forma continua y estandarizada vía `kubectl logs` (y por lo tanto también vía cualquier agente de log aggregation del cluster que ya escuche `stdout`/`stderr`), sin necesidad de ejecutar comandos manuales bajo demanda ni depender de que el container seguirá vivo cuando quieras auditar el archivo.

12. `kubectl logs job/log-job` solo devuelve los logs de **uno** de los Pods del Job (típicamente falla o advierte si hay ambigüedad cuando hay más de un Pod). Con `parallelism > 1` conviene usar un selector de label sobre los Pods del Job, por ejemplo `kubectl logs -l job-name=log-job --all-containers=true --prefix=true`, para ver todos.

</details>