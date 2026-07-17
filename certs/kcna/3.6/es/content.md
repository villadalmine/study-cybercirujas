# 3.6 Troubleshooting

El troubleshooting en Kubernetes es el proceso sistemático de diagnosticar por qué un objeto (Pod, Deployment, Service, Node) no se comporta como se espera. KCNA no evalúa troubleshooting avanzado de nivel SRE, pero sí espera que conozcas los comandos básicos de `kubectl` para inspeccionar estado, logs y eventos, y que puedas reconocer las causas más comunes de fallas en Pods, probes, recursos y networking.

## El flujo sistemático de diagnóstico

Ante cualquier problema, el orden recomendado es:

1. **Ver el estado general** con `kubectl get`.
2. **Profundizar** con `kubectl describe`, que muestra spec, status y — crucialmente — la sección `Events`.
3. **Revisar logs** de la aplicación con `kubectl logs`.
4. **Inspeccionar en vivo** con `kubectl exec` (o `kubectl debug` si el contenedor no tiene shell).
5. **Revisar eventos del cluster** con `kubectl get events`.

```bash
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl logs <pod-name> [-c <container>] [--previous]
kubectl exec -it <pod-name> -- sh
kubectl get events --sort-by=.lastTimestamp
```

`--previous` en `kubectl logs` es clave cuando el contenedor ya reinició: muestra los logs del intento anterior, no del actual (que puede no haber generado output todavía).

## Estados comunes de Pods

### Pending

El Pod fue aceptado por el API server pero no fue *scheduled* (o el scheduling ocurrió pero las imágenes/volúmenes no están listos). Causas típicas: recursos insuficientes en los Nodes, `nodeSelector`/`affinity` que ningún Node satisface, o `PersistentVolumeClaim` sin `PersistentVolume` disponible.

```bash
$ kubectl describe pod web-7f8d9-x2k1
...
Events:
  Type     Reason            Message
  ----     ------            -------
  Warning  FailedScheduling  0/3 nodes are available: 3 Insufficient cpu.
```

### ImagePullBackOff / ErrImagePull

Kubernetes no pudo descargar la imagen del container: nombre/tag mal escrito, registry privado sin `imagePullSecrets`, o rate limiting del registry.

```bash
$ kubectl describe pod api-6c9b7-p4q2
Events:
  Warning  Failed     Failed to pull image "myrepo/api:v1.2": rpc error: code = NotFound
  Warning  BackOff    Back-off pulling image "myrepo/api:v1.2"
```

### CrashLoopBackOff

El contenedor arranca, termina (con error o incluso con exit code 0) y Kubernetes lo reinicia con *backoff* exponencial. La causa está casi siempre en la app, no en Kubernetes: error de configuración, falta una variable de entorno, o el proceso principal termina inmediatamente.

```bash
$ kubectl get pods
NAME              READY   STATUS             RESTARTS   AGE
worker-5d8f-abcd  0/1     CrashLoopBackOff   6          8m

$ kubectl logs worker-5d8f-abcd --previous
Error: missing required env var DATABASE_URL
```

### OOMKilled

El contenedor superó su `resources.limits.memory` y el kernel lo mató. Se ve en `describe`, no necesariamente en `STATUS` de `get pods`.

```bash
$ kubectl describe pod cache-9f7b-1234
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Solución: subir el `limit` de memoria (si la app realmente lo necesita) o corregir un memory leak. Exit code 137 = 128 + SIGKILL(9), señal de que algo mató el proceso a la fuerza.

### Pod en `Unknown` o Node en `NotReady`

Si el `kubelet` de un Node deja de reportar heartbeats (caída de red, kubelet caído, disco lleno), el control plane marca sus Pods como `Unknown` y, tras el `pod-eviction-timeout`, los reprograma en otro Node.

```bash
$ kubectl get nodes
NAME       STATUS     ROLES    AGE   VERSION
worker-2   NotReady   <none>   30d   v1.29.1

$ kubectl describe node worker-2
Conditions:
  Type             Status  Reason
  ----             ------  ------
  MemoryPressure   True    KubeletHasInsufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  Ready            False   KubeletNotReady
```

## Troubleshooting de probes

Un `livenessProbe` mal configurado (timeout muy corto, endpoint incorrecto) provoca reinicios constantes de un contenedor sano; un `readinessProbe` que nunca pasa deja al Pod fuera del `Endpoints` del Service aunque esté `Running`.

```bash
$ kubectl describe pod app-3f2a-9k1m
Events:
  Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
  Normal   Killing    Container app failed liveness probe, will be restarted
```

Diagnóstico: revisar si el `RESTARTS` sube sin que haya errores en los logs de la app — suele indicar que el probe apunta a un path/puerto equivocado, no que la app esté rota.

## Troubleshooting de recursos

Además de OOM, un contenedor puede sufrir **CPU throttling** si excede su `limits.cpu`: no se cae, pero responde lento. Se detecta comparando el uso real contra el limit:

```bash
kubectl top pod <pod-name>
```

(requiere `metrics-server` instalado en el cluster).

## Troubleshooting de networking

Pasos típicos para "el Pod A no puede hablar con el Service B":

```bash
# 1. ¿El Service tiene endpoints?
kubectl get endpoints my-service

# 2. ¿Resuelve DNS desde adentro del Pod?
kubectl exec -it podA -- nslookup my-service

# 3. ¿Hay conectividad L4?
kubectl exec -it podA -- curl -v http://my-service:8080

# 4. ¿Hay una NetworkPolicy bloqueando el tráfico?
kubectl get networkpolicy -A
```

Si `endpoints` está vacío, el problema es casi siempre que los `selector` labels del Service no matchean los labels del Pod. Si DNS falla, revisar los Pods de CoreDNS (`kubectl -n kube-system get pods -l k8s-app=kube-dns`) y sus logs.

## Debug containers efímeros

Cuando la imagen del contenedor no tiene shell ni herramientas de debug (imágenes *distroless*), `kubectl debug` inyecta un contenedor efímero con acceso al mismo namespace de red/proceso sin modificar el Pod original:

```bash
kubectl debug -it my-pod --image=busybox:1.36 --target=my-container
```

## Comandos clave — resumen

| Comando | Uso |
|---|---|
| `kubectl get <recurso> -o wide` | Estado rápido, incluye Node/IP |
| `kubectl describe <recurso>` | Spec completo + sección `Events` |
| `kubectl logs [-c] [--previous]` | Logs del contenedor actual o del anterior |
| `kubectl exec -it -- sh` | Shell interactiva dentro del contenedor |
| `kubectl get events --sort-by=.lastTimestamp` | Eventos recientes del cluster |
| `kubectl top pod/node` | Uso de CPU/memoria (requiere metrics-server) |
| `kubectl debug` | Contenedor efímero de debug |

## Referencias

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs, *Troubleshooting Applications*: https://kubernetes.io/docs/tasks/debug/debug-application/
- Kubernetes docs, *Troubleshooting Clusters*: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Determine the Reason for Pod Failure*: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes docs, *Debug Services*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/