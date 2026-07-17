# Debugging in Kubernetes

## Introducción

Debuggear aplicaciones en Kubernetes requiere combinar varias fuentes de información: el estado del Pod, los logs de los containers, los events del cluster, y en casos más profundos, herramientas de inspección a nivel de node. El examen CKAD evalúa la capacidad de diagnosticar rápidamente por qué un Pod no arranca, por qué un container se reinicia, o por qué una aplicación no responde, usando exclusivamente `kubectl` y unas pocas herramientas complementarias.

El flujo de debugging típico sigue este orden:

1. `kubectl get pods` → ver el estado general (`STATUS`, `RESTARTS`).
2. `kubectl describe pod <pod>` → ver `Events` y `Conditions`.
3. `kubectl logs <pod> [-c <container>]` → ver la salida de la aplicación.
4. `kubectl exec -it <pod> -- sh` → inspección interactiva dentro del container.
5. `kubectl debug` → cuando el container no tiene shell o herramientas, o cuando el problema es a nivel de node.

## Estados de Pod y su diagnóstico

### Pending

El Pod no fue scheduled o sus containers no arrancaron. Se diagnostica con `describe`:

```bash
$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
web-7d9f8   0/1     Pending   0          2m

$ kubectl describe pod web-7d9f8
...
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  2m    default-scheduler  0/3 nodes are available:
           3 Insufficient cpu.
```

Causas típicas: `requests` de CPU/memoria que ningún node puede satisfacer, `nodeSelector`/`affinity` que no matchea ningún node, `taints` sin la `toleration` correspondiente, o un `PersistentVolumeClaim` que no puede ser bound.

### ImagePullBackOff / ErrImagePull

```bash
$ kubectl describe pod web-7d9f8
Events:
  Warning  Failed     Failed to pull image "nginx:1.99": rpc error:
           code = NotFound desc = failed to pull and unpack image
  Normal   BackOff    Back-off pulling image "nginx:1.99"
```

Suele ser un tag inexistente, un typo en el nombre del repositorio, o falta de `imagePullSecrets` para un registry privado.

### CrashLoopBackOff

El container arranca y termina (crash) repetidamente. Kubernetes espera cada vez más tiempo entre reintentos (backoff exponencial). Es clave revisar los logs del intento **anterior**, ya que el container actual puede estar recién reiniciado sin output todavía:

```bash
$ kubectl logs web-7d9f8 --previous
Error: cannot connect to database at db:5432: connection refused
```

También conviene ver el `exit code` del último container terminado:

```bash
$ kubectl describe pod web-7d9f8
Last State:  Terminated
  Reason:    Error
  Exit Code: 1
```

Exit codes comunes a reconocer:

| Exit code | Significado |
|---|---|
| `0` | Salida normal, sin error |
| `1` | Error general de la aplicación |
| `137` | `SIGKILL` (128+9) — a menudo por `OOMKilled` o `kubectl delete --force` |
| `143` | `SIGTERM` (128+15) — terminación normal por shutdown/rolling update |

### OOMKilled

```bash
$ kubectl describe pod web-7d9f8
Last State:   Terminated
  Reason:     OOMKilled
  Exit Code:  137
```

El container excedió su `resources.limits.memory`. Solución: aumentar el limit o corregir un memory leak en la aplicación.

## `kubectl logs`

Opciones más usadas en el examen:

```bash
# Logs del container actual
kubectl logs web-7d9f8

# Container específico en un Pod multi-container
kubectl logs web-7d9f8 -c sidecar

# Logs del container anterior (útil en CrashLoopBackOff)
kubectl logs web-7d9f8 --previous

# Seguir el stream en tiempo real
kubectl logs -f web-7d9f8

# Últimas N líneas
kubectl logs web-7d9f8 --tail=50

# Logs desde hace 10 minutos
kubectl logs web-7d9f8 --since=10m

# Logs de todos los containers de un Deployment (requiere label selector)
kubectl logs -l app=web --all-containers=true --prefix=true
```

## `kubectl exec`

Permite ejecutar comandos dentro de un container en ejecución, útil para inspeccionar filesystem, variables de entorno, conectividad de red, o procesos:

```bash
# Shell interactiva
kubectl exec -it web-7d9f8 -- sh

# Comando puntual
kubectl exec web-7d9f8 -- env

# Contra un container específico
kubectl exec -it web-7d9f8 -c sidecar -- bash

# Probar conectividad a otro Service desde dentro del cluster
kubectl exec -it web-7d9f8 -- curl -sv http://backend-svc:8080/health
```

`kubectl exec` requiere que el container tenga un shell disponible. Muchas imágenes "distroless" o `scratch` no lo tienen, lo que lleva a la siguiente herramienta.

## `kubectl debug` y ephemeral containers

`kubectl debug` (estable desde 1.23+) resuelve el caso en que el container no tiene shell, herramientas de red, o directamente crashea antes de poder hacer `exec`.

### Ephemeral container en un Pod existente

Inyecta un container temporal con herramientas de debug en un Pod ya corriendo, compartiendo namespaces (network, PID según se configure):

```bash
kubectl debug web-7d9f8 -it --image=busybox:1.36 --target=web
```

`--target` hace que el ephemeral container comparta el namespace de procesos del container objetivo, permitiendo ver sus procesos con `ps` incluso si la imagen original no incluye esa utilidad.

### Copiar el Pod para debuggear sin afectar el original

Útil cuando no se quiere modificar un Pod en producción o el container ya crasheó:

```bash
kubectl debug web-7d9f8 -it --image=busybox:1.36 --copy-to=web-debug --container=app -- sh
```

Esto crea `web-debug`, una copia del Pod, reemplazando el container indicado para poder entrar con una shell.

### Debug de un node

Crea un Pod privilegiado en el node indicado, montando el filesystem del host en `/host`, para inspeccionar el sistema operativo, `crictl`, o `journalctl` del node:

```bash
kubectl debug node/worker-2 -it --image=busybox:1.36

# Dentro del Pod de debug:
chroot /host
crictl ps -a
journalctl -u kubelet -n 100
```

## Debugging de probes (liveness / readiness / startup)

Si un Pod queda en `Running` pero `READY 0/1`, el problema suele ser la `readinessProbe`:

```bash
$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
web-7d9f8   0/1     Running   0          5m

$ kubectl describe pod web-7d9f8
Events:
  Warning  Unhealthy  30s (x5 over 2m)  kubelet  Readiness probe failed:
           HTTP probe failed with statuscode: 503
```

Si en cambio se ve `RESTARTS` incrementando junto con eventos `Unhealthy` seguidos de `Killing`, es la `livenessProbe` la que está matando el container:

```bash
Warning  Unhealthy  Liveness probe failed: Get "http://10.244.1.5:8080/healthz":
                     dial tcp 10.244.1.5:8080: connect: connection refused
Normal   Killing    Container app failed liveness probe, will be restarted
```

Causas comunes: `initialDelaySeconds` demasiado corto para el tiempo real de arranque de la app (se resuelve mejor con `startupProbe`), path o puerto incorrecto en la probe, o `timeoutSeconds` insuficiente bajo carga.

## Debugging de recursos (`kubectl top`)

Requiere `metrics-server` instalado en el cluster:

```bash
$ kubectl top pod web-7d9f8
NAME        CPU(cores)   MEMORY(bytes)
web-7d9f8   950m         480Mi

$ kubectl top node
NAME       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-1   1800m        90%    3200Mi          82%
```

Útil para confirmar throttling de CPU (uso pegado cerca del `limit`) o presión de memoria antes de un `OOMKilled`.

## Debugging de Services y networking

Cuando un Pod no puede alcanzar un Service, el checklist es:

```bash
# ¿El Service tiene endpoints?
kubectl get endpoints backend-svc
# Si aparece <none>, el selector del Service no matchea ningún label de Pod

# Comparar selector del Service con los labels reales del Pod
kubectl get svc backend-svc -o jsonpath='{.spec.selector}'
kubectl get pods --show-labels

# Verificar que el Pod destino responde localmente
kubectl exec -it backend-7d9f8 -- curl -s localhost:8080/health

# Probar resolución DNS interna desde otro Pod
kubectl exec -it web-7d9f8 -- nslookup backend-svc.default.svc.cluster.local

# Exponer temporalmente un puerto para probar desde la máquina local
kubectl port-forward pod/backend-7d9f8 8080:8080
```

Si `nslookup` falla, conviene revisar el estado de `coredns`: `kubectl -n kube-system get pods -l k8s-app=kube-dns` y sus logs.

## `kubectl get events`

Vista global de eventos del namespace, ordenados por timestamp, útil para correlacionar problemas entre varios objetos (Pod, ReplicaSet, Node):

```bash
kubectl get events --sort-by=.metadata.creationTimestamp
kubectl get events --field-selector type=Warning
```

## Tabla resumen de comandos

| Comando | Uso |
|---|---|
| `kubectl describe pod <pod>` | Events, Conditions, Last State, exit code |
| `kubectl logs [-c] [--previous] [-f]` | Salida de la aplicación |
| `kubectl exec -it <pod> -- sh` | Inspección interactiva (requiere shell en imagen) |
| `kubectl debug <pod> --copy-to=... --target=...` | Debug sin shell o sin afectar el Pod original |
| `kubectl debug node/<node>` | Inspección a nivel de node (`crictl`, `journalctl`) |
| `kubectl top pod\|node` | Uso de CPU/memoria (requiere metrics-server) |
| `kubectl get endpoints <svc>` | Verificar que el Service tiene backends |
| `kubectl port-forward` | Probar un Pod/Service sin exponerlo |

## Referencias

- CNCF, *CKAD Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes docs, *Debug Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Debug with ephemeral containers*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-ephemeral-container/
- Kubernetes docs, *Debugging Kubernetes Nodes with crictl*: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- Kubernetes docs, *Debug a StatefulSet*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-statefulset/
- Kubernetes docs, *Troubleshoot Services*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes docs, *Resource Metrics Pipeline (metrics-server)*: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes docs, *Configure Liveness, Readiness and Startup Probes*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- `kubectl` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands