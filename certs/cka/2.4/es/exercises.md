# Ejercicios guiados — CKA 2.4: Manage and evaluate container output streams

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Requisitos previos: acceso a un cluster de Kubernetes (`kind`, `minikube` o similar) con permisos para crear `Pods` en un `namespace` de práctica, y `kubectl` configurado.

```bash
kubectl create namespace logs-lab
kubectl config set-context --current --namespace=logs-lab
```

---

## Ejercicio 1 — Logs básicos de un Pod

1. Creá un `Pod` que escriba una línea a `stdout` cada segundo:

```bash
kubectl run logger-basic --image=busybox --restart=Never -- \
  sh -c 'i=0; while true; do echo "línea $i"; i=$((i+1)); sleep 1; done'
```

2. Esperá a que esté `Running` y consultá sus logs:

```bash
kubectl get pod logger-basic -w
```

(Ctrl+C cuando el `STATUS` sea `Running`)

```bash
kubectl logs logger-basic
```

3. Repetí el comando `kubectl logs logger-basic` un par de veces con unos segundos de diferencia y observá cómo cambia la salida.

### Preguntas de comprensión

1. ¿Qué stream(s) captura `kubectl logs` por defecto: `stdout`, `stderr`, o ambos?
2. ¿`kubectl logs` sin `-f` te muestra el log completo acumulado o solo lo nuevo desde la última vez que lo corriste?

---

## Ejercicio 2 — Streaming y filtrado de logs

1. Seguí el log en tiempo real (`follow`):

```bash
kubectl logs -f logger-basic
```

Dejalo correr unos segundos y cortá con Ctrl+C.

2. Mostrá solo las últimas 5 líneas:

```bash
kubectl logs logger-basic --tail=5
```

3. Mostrá solo los logs de los últimos 10 segundos:

```bash
kubectl logs logger-basic --since=10s
```

4. Agregá timestamps a cada línea:

```bash
kubectl logs logger-basic --timestamps
```

5. Combiná varias opciones a la vez:

```bash
kubectl logs logger-basic --tail=3 --timestamps
```

### Preguntas de comprensión

1. ¿Qué diferencia hay entre `--since=10s` y `--since-time=<RFC3339>`?
2. Si necesitás ver únicamente errores recientes de un Pod que loguea mucho, ¿qué combinación de flags de `kubectl logs` usarías y por qué?

---

## Ejercicio 3 — Pods con múltiples contenedores

1. Creá un `Pod` con dos contenedores que loguean cosas distintas:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-logger
spec:
  containers:
  - name: web
    image: busybox
    command: ["sh", "-c", "while true; do echo web: pedido recibido; sleep 2; done"]
  - name: worker
    image: busybox
    command: ["sh", "-c", "while true; do echo worker: job procesado; sleep 3; done"]
EOF
```

2. Intentá ver los logs sin especificar contenedor:

```bash
kubectl logs multi-logger
```

3. Ahora especificá cada contenedor con `-c`:

```bash
kubectl logs multi-logger -c web
kubectl logs multi-logger -c worker
```

4. Mostrá los logs de todos los contenedores del Pod juntos, con prefijo indicando el origen:

```bash
kubectl logs multi-logger --all-containers=true --prefix
```

### Preguntas de comprensión

1. ¿Por qué `kubectl logs multi-logger` (sin `-c`) falla o pide más información cuando hay más de un `container`?
2. ¿Para qué sirve el flag `--prefix` cuando usás `--all-containers`?

---

## Ejercicio 4 — Logs de un contenedor que reinició (`--previous`)

1. Creá un `Pod` que falla después de unos segundos, provocando reinicios:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: crash-logger
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo iniciando; sleep 5; echo 'error fatal: saliendo'; exit 1"]
EOF
```

2. Observá cómo el `Pod` entra en `CrashLoopBackOff`:

```bash
kubectl get pod crash-logger -w
```

(Ctrl+C después de ver al menos un reinicio con `RESTARTS` en 1 o más)

3. Mirá los logs del contenedor actual (probablemente esperando el próximo intento):

```bash
kubectl logs crash-logger
```

4. Mirá los logs de la instancia **anterior** del contenedor, la que efectivamente falló:

```bash
kubectl logs crash-logger --previous
```

5. Revisá los `Events` del Pod para correlacionar con los logs:

```bash
kubectl describe pod crash-logger
```

### Preguntas de comprensión

1. ¿Qué diferencia hay entre lo que muestra `kubectl logs crash-logger` y `kubectl logs crash-logger --previous` en este escenario?
2. Cuando investigás un `CrashLoopBackOff` en el examen, ¿por qué conviene mirar tanto `--previous` como `kubectl describe pod` en lugar de solo uno de los dos?

---

## Ejercicio 5 — `stdout` vs `stderr`

1. Creá un `Pod` que escribe tanto en `stdout` como en `stderr`:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dual-stream
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "while true; do echo 'info: todo ok'; echo 'error: algo falló' >&2; sleep 2; done"]
EOF
```

2. Consultá los logs del Pod:

```bash
kubectl logs dual-stream
```

3. Observá el orden y mezcla de las líneas `info:` y `error:` en la salida.

### Preguntas de comprensión

1. ¿`kubectl logs` distingue entre líneas que vinieron de `stdout` y líneas que vinieron de `stderr`, o las combina en un solo stream?
2. Si quisieras separar `stdout` de `stderr` de una aplicación en Kubernetes, ¿a qué nivel tendrías que resolverlo (kubectl, la aplicación, o el container runtime)?

---

## Ejercicio 6 — Patrón sidecar de logging (streaming sidecar)

Este patrón se usa cuando una aplicación legada escribe logs a un archivo en vez de a `stdout`.

1. Creá un `Pod` con un contenedor principal que escribe a un archivo, un volumen `emptyDir` compartido, y un `sidecar` que tailea ese archivo hacia su propio `stdout`:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-logger
spec:
  volumes:
  - name: logs
    emptyDir: {}
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "while true; do echo \"$(date) evento de la app\" >> /var/log/app.log; sleep 2; done"]
    volumeMounts:
    - name: logs
      mountPath: /var/log
  - name: log-shipper
    image: busybox
    command: ["sh", "-c", "tail -F /var/log/app.log"]
    volumeMounts:
    - name: logs
      mountPath: /var/log
EOF
```

2. Verificá que el contenedor `app` no tiene salida útil por `kubectl logs`:

```bash
kubectl logs sidecar-logger -c app
```

3. Verificá que el `sidecar` sí expone el contenido del archivo como logs de Kubernetes:

```bash
kubectl logs sidecar-logger -c log-shipper -f
```

(Ctrl+C para cortar)

### Preguntas de comprensión

1. ¿Por qué `kubectl logs sidecar-logger -c app` no muestra los eventos que la aplicación escribe en `app.log`?
2. ¿Qué ventaja tiene este patrón de `sidecar` respecto a modificar la aplicación para que escriba directamente a `stdout`?

---

## Ejercicio 7 — Log rotation a nivel de nodo

1. Identificá en qué nodo corre alguno de los Pods anteriores:

```bash
kubectl get pod multi-logger -o wide
```

2. Abrí una sesión de debug en ese nodo:

```bash
kubectl debug node/<nombre-del-nodo> -it --image=busybox -- chroot /host sh
```

3. Dentro del nodo, listá los archivos de log de los contenedores:

```bash
ls -la /var/log/containers/ | head
ls -la /var/log/pods/ | head
```

4. Revisá la configuración de `log rotation` del `kubelet` (los campos pueden variar según cómo esté provisto el nodo):

```bash
cat /var/lib/kubelet/config.yaml | grep -i containerLog
```

Buscá los campos `containerLogMaxSize` y `containerLogMaxFiles`.

5. Salí de la sesión de debug:

```bash
exit
```

### Preguntas de comprensión

1. ¿Qué controla `containerLogMaxSize` en la configuración del `kubelet`?
2. Si un Pod genera muchísimos logs y el `container runtime` ya rotó y descartó los archivos más viejos, ¿por qué `kubectl logs` podría mostrarte un historial incompleto aunque el Pod nunca haya reiniciado?

---

## Ejercicio 8 — Troubleshooting integral

1. Aplicá este `Deployment`, que tiene un bug intencional:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: buggy-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: buggy-app
  template:
    metadata:
      labels:
        app: buggy-app
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 'cargando configuración...'; sleep 3; echo 'CONFIG_MISSING: variable API_KEY no definida' >&2; exit 1"]
EOF
```

2. Usá `kubectl get pods -l app=buggy-app` para encontrar el Pod y observá su estado a lo largo de un par de minutos.

3. Diagnosticá la causa raíz combinando estos tres comandos:

```bash
kubectl get pods -l app=buggy-app
kubectl describe pod -l app=buggy-app
kubectl logs -l app=buggy-app --previous
```

4. Corregí el `Deployment` (por ejemplo, agregando la variable de entorno faltante) y confirmá que el nuevo Pod queda `Running` sin reinicios:

```bash
kubectl set env deployment/buggy-app API_KEY=demo123
kubectl rollout status deployment/buggy-app
kubectl get pods -l app=buggy-app -w
```

### Preguntas de comprensión

1. ¿En qué orden conviene revisar `get pods`, `describe pod` y `logs --previous` cuando encontrás un `CrashLoopBackOff` en el examen, y qué información aporta cada uno?
2. ¿Por qué `kubectl logs -l app=buggy-app` (sin `--previous`) puede no mostrarte la causa del `crash` incluso apuntando al Pod correcto?

---

## Limpieza

```bash
kubectl delete namespace logs-lab
```

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
1. Por defecto captura tanto `stdout` como `stderr` del contenedor; Kubernetes no los distingue como streams separados en la salida de `kubectl logs`.
2. Te muestra el log completo acumulado desde que el contenedor arrancó (hasta el límite de retención/rotación), no solo lo nuevo. Cada invocación vuelve a mostrar todo el historial disponible.

**Ejercicio 2**
1. `--since=10s` es relativo al momento en que ejecutás el comando (una duración hacia atrás). `--since-time` toma un timestamp absoluto en formato RFC3339, útil para anclar la consulta a un instante exacto (por ejemplo, el momento en que empezó un incidente).
2. No hay un flag que filtre por contenido (`grep` de errores) directamente en `kubectl logs`; se combina con herramientas externas, por ejemplo `kubectl logs pod --since=10m | grep -i error`. Los flags de `kubectl logs` (`--tail`, `--since`) acotan por tiempo/cantidad, no por contenido.

**Ejercicio 3**
1. Porque Kubernetes no sabe de cuál de los `containers` del Pod querés ver los logs; `kubectl` exige `-c <container>` (o `--all-containers`) para desambiguar cuando hay más de uno.
2. `--prefix` antepone a cada línea el nombre del Pod y del contenedor de origen, lo cual es imprescindible para no confundir logs de distintos contenedores cuando se muestran mezclados con `--all-containers`.

**Ejercicio 4**
1. `kubectl logs crash-logger` muestra los logs de la instancia **actual** del contenedor (la que está corriendo o a punto de reintentar), que puede estar vacía o recién iniciada. `kubectl logs crash-logger --previous` muestra los logs de la instancia **anterior**, la que efectivamente terminó con el error `error fatal: saliendo` y `exit 1`.
2. Porque `describe pod` muestra los `Events` (por ejemplo `BackOff`, `Killing`, razones de reinicio y conteo de `restarts`) que dan contexto de *cuándo* y *por qué* Kubernetes reinició el contenedor, mientras que `--previous` da el detalle específico de la aplicación (el mensaje de error real). Ninguno de los dos por sí solo da el panorama completo.

**Ejercicio 5**
1. Los combina: `kubectl logs` muestra ambos streams intercalados en el orden en que fueron escritos, sin ninguna marca que indique de cuál stream vino cada línea.
2. Se resuelve a nivel de la aplicación (o de tooling externo de log aggregation), no en `kubectl` ni en el `container runtime` de forma nativa vía `kubectl logs`: la app tendría que loguear de forma estructurada (por ejemplo JSON con un campo `level`) para que un sistema de logging externo pueda separar/filtrar por severidad después de la ingesta.

**Ejercicio 6**
1. Porque el contenedor `app` escribe a un archivo (`/var/log/app.log`) en un volumen, no a su propio `stdout`; `kubectl logs` solo captura lo que el `container runtime` redirige desde el `stdout`/`stderr` del proceso del contenedor.
2. Permite capturar logs de aplicaciones legadas que no se pueden modificar fácilmente para loguear a `stdout`, sin tocar el código de la app: el `sidecar` hace de puente entre el archivo y el mecanismo estándar de logging de Kubernetes, integrándose con cualquier pipeline de log aggregation que ya lea logs vía `kubectl logs`/`container runtime`.

**Ejercicio 7**
1. Define el tamaño máximo que puede alcanzar un archivo de log de contenedor antes de que el `kubelet` lo rote (cree un archivo nuevo y comprima/descarte el viejo según `containerLogMaxFiles`).
2. Porque el `container runtime` rota los logs en disco según tamaño/cantidad de archivos configurados (`containerLogMaxSize`/`containerLogMaxFiles`), independientemente de si el Pod reinició o no; una vez que un archivo rotado se descarta, esas líneas ya no están disponibles para `kubectl logs`, aunque el contenedor siga siendo el mismo proceso corriendo sin interrupciones.

**Ejercicio 8**
1. Primero `get pods` para confirmar el estado (`CrashLoopBackOff`, conteo de `RESTARTS`); después `describe pod` para ver los `Events` recientes (motivo del último reinicio, `backoff`, límites); y por último `logs --previous` para ver el mensaje de error específico de la aplicación que causó la falla. Ir de lo general (estado) a lo específico (mensaje de error real) evita perder tiempo mirando el detalle antes de confirmar qué está pasando.
2. Porque tras un `crash`, Kubernetes crea una nueva instancia del contenedor para reintentar; `kubectl logs` sin `--previous` apunta a esa instancia nueva (que puede estar recién arrancando o en `waiting` con `CrashLoopBackOff` antes de reintentar), no a la instancia que falló y generó el error. El mensaje de la falla real solo está en los logs de la instancia terminada, accesibles con `--previous`.

</details>
