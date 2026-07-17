# 2.2 Debugging

## Introducción

Debugging en Kubernetes es el proceso de diagnosticar por qué un `Pod`, `Node` o componente del cluster no funciona como se espera. A diferencia de debuggear una aplicación monolítica, en Kubernetes el fallo puede originarse en múltiples capas: la definición del manifest, el scheduler, el kubelet, el container runtime, la red (CNI), o la aplicación misma dentro del container. Por eso el enfoque de troubleshooting es siempre "de afuera hacia adentro": primero se mira el estado del objeto a alto nivel, después los eventos del cluster, y por último los logs y el interior del container.

Las herramientas principales son subcomandos de `kubectl`: `describe`, `logs`, `exec`, `get events`, `top` y `debug`.

## `kubectl describe`: estado y eventos del objeto

Es el primer comando a correr ante cualquier problema. Muestra spec, status, y — lo más importante para debugging — la sección `Events` al final, con el historial reciente de lo que el scheduler y el kubelet hicieron con ese objeto.

```bash
kubectl describe pod my-app-7d9f8c6b5-x2n4k
```

Salida (recortada, foco en la parte útil para debugging):

```
Status:       Pending
Conditions:
  Type           Status
  PodScheduled   False
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  30s   default-scheduler   0/3 nodes are available:
                                                          3 Insufficient cpu.
```

Este ejemplo indica un problema de scheduling: el Pod no puede ubicarse en ningún Node porque el `resources.requests.cpu` pedido excede la capacidad disponible. `describe` también funciona sobre `node`, `deployment`, `service`, etc., y en cada caso la sección `Events` es la fuente principal de pistas.

## Estados comunes de fallo de un Pod

| `STATUS` reportado por `kubectl get pods` | Causa típica |
|---|---|
| `Pending` | Falta de recursos (CPU/memoria) en los Nodes, PVC sin bindear, taints sin toleration |
| `ImagePullBackOff` / `ErrImagePull` | Imagen inexistente, tag mal escrito, falta de `imagePullSecrets` para un registry privado |
| `CrashLoopBackOff` | El proceso principal del container termina (crashea) repetidamente; kubelet reintenta con backoff exponencial |
| `Error` / `OOMKilled` | El container terminó con código de error, a menudo por exceder `resources.limits.memory` |
| `Running` pero `READY 0/1` | Falla el readiness probe; el Pod está up pero no recibe tráfico del Service |

```bash
kubectl get pods
```
```
NAME                     READY   STATUS             RESTARTS   AGE
my-app-7d9f8c6b5-x2n4k   0/1     CrashLoopBackOff   5          4m
```

## `kubectl logs`: logs del container

Una vez identificado el Pod problemático, el siguiente paso es ver stdout/stderr del container.

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k
```

Si el Pod tiene múltiples containers, hay que especificar cuál:

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k -c sidecar
```

Casos particulares para `CrashLoopBackOff`: el container actual puede no tener logs útiles porque ya reinició. Ahí sirve `--previous` para ver los logs del container terminado anteriormente:

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k --previous
```

Para seguir logs en tiempo real (equivalente a `tail -f`):

```bash
kubectl logs -f my-app-7d9f8c6b5-x2n4k
```

## `kubectl exec`: inspección interactiva dentro del container

Cuando los logs no alcanzan, se puede abrir una shell dentro del container (si la imagen tiene una) para inspeccionar filesystem, variables de entorno o conectividad:

```bash
kubectl exec -it my-app-7d9f8c6b5-x2n4k -- /bin/sh
```

También sirve para correr un comando puntual sin sesión interactiva, por ejemplo verificar DNS interno del cluster:

```bash
kubectl exec my-app-7d9f8c6b5-x2n4k -- nslookup my-service.default.svc.cluster.local
```

`exec` requiere que el container ya esté `Running` y tenga un shell disponible; en imágenes `distroless` o `scratch` esto no es posible, para lo cual existen los ephemeral containers (ver más abajo).

## `kubectl get events`

Muestra el stream de eventos del cluster, útil para ver el panorama completo (no solo de un Pod) ordenado cronológicamente:

```bash
kubectl get events --sort-by='.lastTimestamp'
```

```
LAST SEEN   TYPE      REASON      OBJECT                        MESSAGE
2m          Warning   BackOff     pod/my-app-7d9f8c6b5-x2n4k    Back-off restarting failed container
1m          Normal    Pulled      pod/my-app-7d9f8c6b5-x2n4k    Container image already present on machine
```

## `kubectl debug`: ephemeral containers

Para debuggear Pods cuya imagen no tiene herramientas de diagnóstico (sin shell, sin `curl`, etc.), Kubernetes permite inyectar un **ephemeral container**: un container temporal que se agrega a un Pod ya corriendo, comparte su namespace de red/proceso, y trae sus propias herramientas.

```bash
kubectl debug -it my-app-7d9f8c6b5-x2n4k \
  --image=busybox:1.36 \
  --target=my-app
```

`--target` hace que el container de debug comparta el namespace de proceso con el container objetivo, permitiendo ver sus procesos (`ps aux`) desde afuera aunque la imagen original no tenga esas utilidades.

También se puede debuggear un Node completo, lo cual crea un Pod privilegiado con acceso al filesystem del Node vía `/host`:

```bash
kubectl debug node/worker-01 -it --image=busybox:1.36
```

## Chequeos de recursos y probes

Un fallo frecuente es `OOMKilled`, visible en `describe`:

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Esto indica que el container excedió `resources.limits.memory`. La solución no es "debugging" en sí sino ajustar límites o corregir un memory leak en la app.

Para verificar consumo actual de recursos (requiere metrics-server):

```bash
kubectl top pod my-app-7d9f8c6b5-x2n4k
```

Fallos de `livenessProbe`/`readinessProbe` también aparecen en `Events` como `Unhealthy`:

```
Warning  Unhealthy  10s  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
```

## Flujo típico de troubleshooting

1. `kubectl get pods` → identificar el Pod y su `STATUS`.
2. `kubectl describe pod <name>` → revisar `Events` y `Conditions`.
3. `kubectl logs <name> [--previous] [-c container]` → revisar logs de aplicación.
4. `kubectl exec -it <name> -- sh` o `kubectl debug` → inspección interna si logs no son suficientes.
5. `kubectl get events --sort-by='.lastTimestamp'` → contexto a nivel cluster si el problema no es específico del Pod (por ejemplo, problemas de Node o de networking).

## Referencias

- Curriculum oficial KCNA: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Debug Running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Debug Pods and ReplicationControllers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods-replication-controller/
- Debugging with an ephemeral debug container: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Debug a Node: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- Determine the Reason for Pod Failure: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- kubectl Cheat Sheet: https://kubernetes.io/docs/reference/kubectl/cheatsheet/