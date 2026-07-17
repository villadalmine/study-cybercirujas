# 2.4 Manage and evaluate container output streams

## Introducción

En Kubernetes, los logs de un contenedor son la vía principal para diagnosticar qué está haciendo una aplicación y por qué falla. Kubernetes no impone un sistema de logging centralizado por defecto: lo que hace es capturar los streams estándar del proceso (`stdout` y `stderr`) de cada contenedor y dejarlos disponibles en el nodo, para que el kubelet y el container runtime (containerd o CRI-O, vía CRI) los expongan a través de la API mediante `kubectl logs`.

Este tema cubre tres capacidades que se evalúan en el examen: entender cómo se generan y almacenan esos streams, saber usar `kubectl logs` con todas sus variantes para inspeccionar contenedores (incluyendo multi-contenedor, init containers y contenedores reiniciados), y comprender los patrones de arquitectura de logging a nivel de clúster quep permiten centralizar esos streams.

## Streams estándar: stdout y stderr

La convención en contenedores (heredada de Docker) es que la aplicación **no debe escribir logs a archivos dentro del contenedor**. En cambio, debe escribir a:

- `stdout` (file descriptor 1): salida normal de la aplicación.
- `stderr` (file descriptor 2): errores y warnings.

El container runtime captura ambos streams y los persiste como archivos JSON (o en formato CRI) en el nodo, típicamente bajo `/var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container-name>/`, con symlinks en `/var/log/containers/`. El kubelet expone ese contenido a la API de Kubernetes cuando se ejecuta `kubectl logs`.

Si una aplicación escribe logs a un archivo en vez de a stdout/stderr, Kubernetes no los ve — hay que usar un sidecar que lea ese archivo y lo redirija (ver más abajo).

## El comando kubectl logs

### Sintaxis básica

```bash
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>
```

Si el pod tiene un solo contenedor, `-c` es opcional. Con varios contenedores, es obligatorio (o se debe usar `--all-containers`).

### Opciones más usadas

| Flag | Uso |
|---|---|
| `-f`, `--follow` | Sigue el stream en tiempo real (como `tail -f`) |
| `--previous` (`-p`) | Muestra los logs del contenedor **anterior** (útil tras un crash/restart) |
| `--since=1h` | Logs de la última hora |
| `--since-time=<RFC3339>` | Logs desde un timestamp específico |
| `--tail=50` | Últimas 50 líneas |
| `--timestamps` | Prefija cada línea con su timestamp |
| `-l app=web` | Logs de todos los pods que matchean el label selector |
| `--all-containers` | Logs de todos los contenedores del pod (incluye sidecars) |
| `--prefix` | Prefija cada línea con el nombre del pod/contenedor (útil junto a `-l`) |
| `--limit-bytes=1024` | Corta la salida a N bytes |
| `-n <namespace>` | Namespace del pod |

### Ejemplos con salidas

Ver los últimos logs de un pod de un solo contenedor:

```bash
kubectl logs webapp-6d9f8c7b4-x2plq
```

```
2026-07-16T10:01:03Z INFO  starting server on :8080
2026-07-16T10:01:03Z INFO  connected to db at postgres:5432
2026-07-16T10:02:11Z ERROR failed to reach payment-service: connection refused
```

Seguir logs en vivo de un contenedor específico dentro de un pod multi-contenedor:

```bash
kubectl logs -f webapp-6d9f8c7b4-x2plq -c app
```

Ver los logs del intento anterior de un contenedor que reinició (típico caso de troubleshooting):

```bash
kubectl get pods
```

```
NAME                       READY   STATUS             RESTARTS   AGE
webapp-6d9f8c7b4-x2plq     0/1     CrashLoopBackOff   4          6m
```

```bash
kubectl logs webapp-6d9f8c7b4-x2plq --previous
```

```
2026-07-16T09:58:40Z FATAL panic: config file /etc/webapp/config.yaml not found
```

`--previous` es clave: sin él, `kubectl logs` muestra el intento **actual**, que en un CrashLoopBackOff puede estar recién arrancando y no tener el error que causó el crash anterior.

Logs de todos los pods con un label, con prefijo identificando el pod:

```bash
kubectl logs -l app=webapp --all-containers --prefix --tail=20
```

```
[pod/webapp-6d9f8c7b4-x2plq/app] 2026-07-16T10:05:00Z INFO handling GET /health
[pod/webapp-6d9f8c7b4-x2plq/sidecar] 2026-07-16T10:05:00Z INFO shipping batch of 12 log lines
[pod/webapp-7f6d9b7c9-abcde/app] 2026-07-16T10:05:01Z INFO handling GET /health
```

### Logs de init containers

Los init containers también generan streams capturables, y son la primera parada cuando un pod queda en `Init:Error` o `Init:CrashLoopBackOff`:

```bash
kubectl get pod db-migrator-xyz
```

```
NAME              READY   STATUS       RESTARTS   AGE
db-migrator-xyz   0/1     Init:Error   2          90s
```

```bash
kubectl logs db-migrator-xyz -c wait-for-db
```

```
2026-07-16T10:10:00Z waiting for postgres:5432...
2026-07-16T10:10:30Z timeout: could not connect to postgres:5432
```

## Logs en pods multi-contenedor

Cuando un pod tiene varios contenedores (app + sidecars), cada uno tiene su propio stream de stdout/stderr independiente, capturado por separado por el runtime. Esto implica:

- `kubectl logs <pod>` sin `-c` falla con un error pidiendo especificar el contenedor si hay más de uno.
- Cada contenedor puede tener su propio `restartCount`, por lo que `--previous` aplica por contenedor, no por pod.
- `kubectl describe pod <pod>` muestra el estado (`Last State`, `Reason`, `Exit Code`) de cada contenedor individualmente — un buen primer paso antes de ir a los logs.

Ejemplo de `kubectl describe pod` mostrando el motivo de un exit no-cero, que orienta qué stream revisar:

```
Containers:
  app:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Thu, 16 Jul 2026 09:58:38 +0000
      Finished:     Thu, 16 Jul 2026 09:58:40 +0000
```

Un `Exit Code: 1` con `Reason: Error` orienta a mirar `stderr` vía `--previous`; un `Exit Code: 137` suele indicar `OOMKilled` (visible también en `Reason`), donde los logs de aplicación pueden no explicar nada y hay que mirar `kubectl describe` en vez de logs.

## Rotación de logs en el nodo

El kubelet gestiona la rotación de los logs de contenedor en disco (no `logrotate`) mediante parámetros de configuración del kubelet:

- `containerLogMaxSize`: tamaño máximo por archivo de log antes de rotar (default `10Mi`).
- `containerLogMaxFiles`: cantidad de archivos rotados a retener por contenedor (default `5`).

Estos se configuran en el `KubeletConfiguration` (archivo pasado con `--config` al kubelet, o vía `kubeletConfig` en algunas distros gestionadas):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerLogMaxSize: 20Mi
containerLogMaxFiles: 10
```

Esto es relevante para el examen porque `kubectl logs` solo puede mostrar lo que sigue existiendo en disco en el nodo: si un contenedor generó mucho output y rotó varias veces, los logs más viejos pueden haberse perdido, incluso con `--previous` (que solo cubre el intento inmediatamente anterior, no el historial completo).

## Arquitectura de logging a nivel de clúster

Kubernetes no incluye una solución de logging centralizada — eso queda fuera del clúster (Elasticsearch, Loki, Cloud Logging, etc.), pero el curriculum evalúa entender los **patrones** para llevar los streams ahí. Hay tres patrones principales:

### 1. Node-level logging agent (DaemonSet)

Un agente (Fluentd, Fluent Bit, Vector) corre como `DaemonSet` en cada nodo, monta `/var/log/pods` y `/var/log/containers` como `hostPath`, y envía todo lo que encuentra a un backend centralizado. Es el patrón más común porque un solo agente por nodo cubre todos los pods sin tocar sus specs.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.1
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
```

### 2. Sidecar container que redirige archivos a stdout

Cuando una aplicación legacy solo escribe logs a un archivo dentro del filesystem del contenedor, se agrega un sidecar que hace `tail -f` de ese archivo y lo emite por su propio stdout, para que quede capturable por el mecanismo estándar:

```yaml
spec:
  containers:
    - name: app
      image: legacy-app:1.0
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
    - name: log-tailer
      image: busybox:1.36
      args: [/bin/sh, -c, 'tail -n+1 -F /var/log/app/app.log']
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

Con este patrón, `kubectl logs <pod> -c log-tailer` muestra el contenido del archivo, y sigue siendo compatible con un node-level agent que lo recolecte.

### 3. Sidecar con agente de logging embebido

Variante del anterior donde, en vez de emitir por stdout, el sidecar corre su propio agente (Fluent Bit, etc.) y envía directamente al backend, sin depender de un DaemonSet a nivel de nodo. Da más control por pod (rutas/parseo distintos por app) a costa de un contenedor extra por cada pod, en vez de un agente compartido por nodo.

## Evaluar streams de salida para troubleshooting

En el examen, "evaluar" implica correlacionar logs con el estado del pod para diagnosticar rápido. Flujo típico:

1. `kubectl get pods` → identificar `STATUS` y `RESTARTS`.
2. `kubectl describe pod <pod>` → ver `Events`, `Last State`, `Exit Code`, `Reason` por contenedor.
3. `kubectl logs <pod> -c <container>` → estado actual.
4. `kubectl logs <pod> -c <container> --previous` → si hubo restart, para ver qué causó el crash anterior.
5. Si es multi-contenedor, repetir para cada contenedor sospechoso (o `--all-containers --prefix` para verlos todos de una).
6. Si el pod nunca llegó a `Running` (stuck en `Init:...` o `Pending`), revisar init containers y `describe` antes que logs del contenedor principal — puede no haber arrancado nunca.

Ejemplo integrador — un pod que crashea por falta de una variable de entorno:

```bash
kubectl get pods
```

```
NAME                     READY   STATUS             RESTARTS   AGE
worker-5b8f9c6d7-ttpqz   0/1     CrashLoopBackOff   6          10m
```

```bash
kubectl logs worker-5b8f9c6d7-ttpqz --previous --timestamps
```

```
2026-07-16T09:50:12Z INFO starting worker
2026-07-16T09:50:12Z FATAL required env var QUEUE_URL is not set
```

Con eso ya se sabe la causa exacta sin necesitar ninguna otra herramienta: falta configurar `QUEUE_URL` en el `Deployment` o `ConfigMap` asociado.

## Referencias

- CNCF, *Certified Kubernetes Administrator (CKA) Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs, *Logging Architecture*: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes docs, *kubectl logs reference*: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#logs
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Determine the Reason for Pod Failure*: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes docs, *Kubelet Configuration (v1beta1) — containerLogMaxSize/containerLogMaxFiles*: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/