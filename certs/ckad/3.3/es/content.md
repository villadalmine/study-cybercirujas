# Container Logs en Kubernetes (CKAD 1.35 — 3.3)

## 1. El modelo de logging en Kubernetes

Kubernetes no tiene un sistema de logging nativo que persista o indexe logs por sí mismo. El contrato es simple: cualquier proceso que corre dentro de un container debe escribir sus logs a **stdout** y **stderr**. El **container runtime** (containerd, CRI-O) captura esos streams y los persiste como archivos en el nodo (típicamente bajo `/var/log/containers/` y `/var/log/pods/`, con symlinks a `/var/lib/docker/containers/` o el equivalente en containerd).

`kubectl logs` es simplemente un cliente que le pide al **kubelet** del nodo esos archivos vía la Kubelet API. No hay agregación, ni almacenamiento persistente, ni búsqueda: eso queda fuera del scope del clúster base y se resuelve con arquitecturas de logging (sección 4).

Consecuencia práctica: si tu aplicación escribe logs a un archivo dentro del container en lugar de stdout/stderr, `kubectl logs` no va a mostrar nada.

## 2. `kubectl logs` — uso básico

```bash
kubectl logs mi-pod
```

Salida típica:

```
2026-07-13T10:15:02Z INFO  Starting server on :8080
2026-07-13T10:15:02Z INFO  Connected to database
2026-07-13T10:15:05Z WARN  Slow query detected (320ms)
```

Si el pod tiene un único container, no hace falta especificarlo. Si tiene más de uno, `kubectl logs` falla y pide que se indique cuál:

```bash
kubectl logs mi-pod
```
```
error: a container name must be specified for pod mi-pod, choose one of: [app sidecar-log]
```

## 3. Pods multi-container

```bash
kubectl logs mi-pod -c app
kubectl logs mi-pod --container=sidecar-log
```

Para ver los logs de **todos** los containers del pod de una sola vez (incluye init containers ya finalizados si corresponde):

```bash
kubectl logs mi-pod --all-containers=true
```

Cada línea se prefija con el nombre del container cuando se combina con `--prefix`:

```bash
kubectl logs mi-pod --all-containers=true --prefix
```
```
[pod/mi-pod/app] 2026-07-13T10:15:02Z INFO  Starting server on :8080
[pod/mi-pod/sidecar-log] 2026-07-13T10:15:02Z INFO  Tailing /var/log/app.log
```

Para logs de un **init container**:

```bash
kubectl logs mi-pod -c init-db
```

## 4. Logs de un crash o restart anterior

Cuando un container crashea y Kubernetes lo reinicia (`CrashLoopBackOff`), los logs del intento actual pueden no explicar nada porque el proceso recién arrancó. El log del intento anterior se recupera con `--previous` (o `-p`):

```bash
kubectl get pods
```
```
NAME      READY   STATUS             RESTARTS   AGE
mi-pod    0/1     CrashLoopBackOff   3          4m
```

```bash
kubectl logs mi-pod --previous
```
```
panic: connection refused to db:5432
goroutine 1 [running]:
main.connectDB(...)
	/app/main.go:42
```

Esto es uno de los patrones más comunes en el examen: diagnosticar un `CrashLoopBackOff` mirando el log del container terminado, no del que acaba de reiniciar.

## 5. Streaming en tiempo real (`--follow`)

```bash
kubectl logs -f mi-pod
```

Mantiene la conexión abierta y va imprimiendo líneas nuevas a medida que se generan, similar a `tail -f`. Se puede combinar con `-c` para un container específico:

```bash
kubectl logs -f mi-pod -c app
```

Con `--follow` sobre un pod que se reinicia, la conexión se corta cuando el container muere; hay que volver a ejecutar el comando (o usar `--previous` para ver qué pasó).

## 6. Filtrar por tiempo y cantidad

```bash
# últimas 50 líneas
kubectl logs mi-pod --tail=50

# logs de los últimos 10 minutos
kubectl logs mi-pod --since=10m

# logs desde un timestamp absoluto (RFC3339)
kubectl logs mi-pod --since-time=2026-07-13T10:00:00Z

# agregar timestamp a cada línea (útil si la app no lo hace)
kubectl logs mi-pod --timestamps
```

Combinado, un patrón habitual para debugging:

```bash
kubectl logs mi-pod -c app --tail=100 --timestamps -f
```

## 7. Logs de múltiples pods con selector

`kubectl logs` acepta `-l`/`--selector` para traer logs de todos los pods que matchean un label, útil con Deployments/ReplicaSets:

```bash
kubectl logs -l app=web --all-containers=true --max-log-requests=10
```

`--max-log-requests` limita cuántos pods se consultan en paralelo (default 5) para no saturar la API si el selector matchea muchos pods.

> Nota: `kubectl logs -l` no interlacea por timestamp, solo concatena; para inspección cronológica real en producción se usa un agregador (ver sección 8) o la herramienta externa `stern`, que no forma parte de `kubectl` core.

## 8. Arquitectura de logging: más allá de `kubectl logs`

`kubectl logs` solo funciona mientras el pod existe (o hasta que el kubelet rota/borra el archivo). Para retención y búsqueda histórica, Kubernetes define tres patrones (documentados en la Kubernetes Logging Architecture):

### a) Node-level logging agent
Un **DaemonSet** corre un agente (Fluentd, Fluent Bit, Filebeat) en cada nodo, montando `/var/log/pods` como `hostPath`, y envía los logs a un backend externo (Elasticsearch, Loki, CloudWatch, etc.). Es transparente para las aplicaciones: no requieren cambios.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
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

### b) Sidecar container con streaming
Cuando la aplicación escribe a un archivo en lugar de stdout (y no se puede modificar), se agrega un **sidecar container** en el mismo pod que lee ese archivo y lo vuelca a su propio stdout. Así `kubectl logs -c sidecar` (y el agente de nodo) sí lo captura.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-con-sidecar
spec:
  containers:
    - name: app
      image: mi-app:1.0
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
    - name: sidecar-log
      image: busybox:1.36
      args: [/bin/sh, -c, 'tail -n+1 -F /var/log/app/app.log']
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

Con este patrón, `app` escribe a `/var/log/app/app.log` (compartido vía `emptyDir`) y `sidecar-log` lo tailea a stdout, quedando visible con:

```bash
kubectl logs app-con-sidecar -c sidecar-log -f
```

### c) Sidecar con agente de logging embebido
Variante del anterior donde el sidecar no solo hace `tail`, sino que corre directamente un agente (Fluent Bit) configurado para ese pod específico y lo envía él mismo al backend, sin depender del DaemonSet de nodo. Da más control por aplicación pero es más costoso en recursos (un agente por pod en vez de uno por nodo).

## 9. Rotación de logs (log rotation)

El kubelet gestiona la rotación de logs por container para evitar llenar el disco del nodo, vía las flags `--container-log-max-size` (tamaño máximo por archivo, default `10Mi`) y `--container-log-max-files` (cantidad de archivos rotados a retener, default `5`). Cuando un archivo se rota o se borra, ese contenido deja de estar disponible vía `kubectl logs`: es otra razón por la que en producción se usa un agregador externo en vez de depender solo de `kubectl logs`.

## 10. Resumen de flags de `kubectl logs`

| Flag | Uso |
|---|---|
| `-c`, `--container` | Selecciona container en un pod multi-container |
| `--all-containers` | Logs de todos los containers del pod |
| `-p`, `--previous` | Logs del container anterior (tras crash/restart) |
| `-f`, `--follow` | Streaming en tiempo real |
| `--tail=N` | Últimas N líneas |
| `--since=DURATION` / `--since-time` | Filtro temporal |
| `--timestamps` | Antepone timestamp a cada línea |
| `-l`, `--selector` | Logs de todos los pods que matchean el label |
| `--max-log-requests` | Límite de pods consultados en paralelo con `-l` |
| `--prefix` | Antepone `[pod/container]` a cada línea (útil con `--all-containers` o `-l`) |

## Referencias

- Kubernetes Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- `kubectl logs` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#logs
- Debug Running Pods (incluye troubleshooting con logs y `--previous`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubelet log rotation flags (`--container-log-max-size`, `--container-log-max-files`): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- CKAD Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf