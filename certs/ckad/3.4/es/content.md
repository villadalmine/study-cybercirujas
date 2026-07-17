# 3.4 Debugging in Kubernetes

**Examen:** CKAD (versión 1.35) · **Peso:** 3

---

## 1. Qué cubre este tema

Los temas 3.1 a 3.3 dieron las herramientas para **observar** una aplicación (probes, `kubectl top`/`describe`/`events`, `kubectl logs`). Este tema se enfoca en las herramientas para **intervenir** sobre un Pod que ya está corriendo (o que se niega a arrancar) y averiguar qué pasa por dentro:

- `kubectl exec`: ejecutar comandos dentro de un contenedor que ya está corriendo.
- `kubectl debug`: adjuntar un **ephemeral container** a un Pod vivo, lanzar una copia del Pod para debug, o depurar un Node entero — clave cuando la imagen no tiene shell (imágenes *distroless*).
- `kubectl port-forward` y `kubectl proxy`: acceder a un Pod o a la API sin exponer un Service.
- `kubectl cp`: mover archivos hacia/desde un contenedor.
- Reconocer los `STATUS`/`REASON` más comunes de un Pod roto (`ImagePullBackOff`, `CrashLoopBackOff`, `Pending`, `OOMKilled`, etc.) y saber qué herramienta corresponde a cada caso.

---

## 2. `kubectl exec`: correr comandos dentro de un contenedor vivo

Requiere que el contenedor esté **Running** y tenga un binario ejecutable (shell u otro). Sirve para inspeccionar el filesystem, variables de entorno, o probar conectividad desde adentro del Pod.

```bash
$ kubectl exec web-7d9f8c9b8-9zj2q -- env | grep DB_HOST
DB_HOST=db.prod.svc.cluster.local

$ kubectl exec -it web-7d9f8c9b8-9zj2q -- sh
/ # cat /etc/resolv.conf
nameserver 10.96.0.10
search prod.svc.cluster.local svc.cluster.local cluster.local
/ # wget -qO- http://db:5432
```

Puntos de examen:

- `-it` (`--stdin --tty`) es obligatorio para una sesión interactiva; sin eso, `kubectl exec` solo corre el comando y devuelve la salida.
- El `--` separa las flags de `kubectl` del comando a ejecutar dentro del contenedor; sin él, `kubectl` puede interpretar mal flags como `-l`.
- En un Pod **multi-container**, hace falta `-c <nombre>` igual que con `kubectl logs`:

```bash
$ kubectl exec web-7d9f8c9b8-9zj2q -c sidecar -- ps aux
```

- Si el contenedor no tiene shell (`sh`/`bash`), `kubectl exec -it ... -- sh` falla:

```bash
$ kubectl exec -it api-6c9f7d8b5-4kxqz -- sh
error: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "...": OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH: unknown
```

Esto es la señal para pasar a `kubectl debug` (sección siguiente): la imagen es *distroless* o minimalista y no trae herramientas de diagnóstico.

---

## 3. `kubectl debug`: la herramienta central de este tema

`kubectl debug` cubre tres escenarios distintos. El examen suele pedir reconocer cuál aplica según la situación.

### 3.1 Ephemeral container: sumar herramientas a un Pod sin reiniciarlo

Un **ephemeral container** se inyecta en un Pod ya existente, comparte su Namespace de red (y opcionalmente de proceso), pero **no reinicia el Pod ni sus contenedores**. Es el reemplazo moderno de "instalar herramientas dentro de la imagen de producción".

```bash
$ kubectl debug -it api-6c9f7d8b5-4kxqz --image=busybox --target=api -- sh
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-8xqvz.
/ # wget -qO- http://localhost:8080/healthz
/ # nslookup db
Server:    10.96.0.10
Address:   10.96.0.10:53
Name:      db.prod.svc.cluster.local
Address:   10.96.12.44
```

- `--image` define la imagen del contenedor de debug (comúnmente `busybox`, `nicolaka/netshoot` para redes).
- `--target=<contenedor>` hace que el ephemeral container **comparta el Namespace de proceso** con ese contenedor específico, permitiendo ver sus procesos vía `ps` aunque `shareProcessNamespace` no esté habilitado a nivel Pod.
- El Pod queda con un contenedor extra permanentemente (no se puede borrar sin recrear el Pod) — pero como no afecta a los contenedores originales, es seguro de usar en un Pod que no se puede darse el lujo de reiniciar.

```bash
$ kubectl get pod api-6c9f7d8b5-4kxqz -o jsonpath='{.spec.ephemeralContainers[*].name}'
debugger-8xqvz
```

### 3.2 Copia del Pod para debug (`--copy-to`)

Cuando sí se puede tocar el Pod, o cuando el objetivo es **modificar el comando de arranque** para investigar (por ejemplo, un contenedor que crashea apenas arranca y no da tiempo a hacer `exec`), `kubectl debug` puede crear una **copia** del Pod con cambios:

```bash
$ kubectl debug api-6c9f7d8b5-4kxqz -it --copy-to=api-debug --container=api -- sh
Defaulting debug container name to debugger-8xqvz.
/ #
```

Con `--copy-to`, el Pod original **no se toca**: se crea un Pod nuevo (`api-debug`) con la misma spec. Combinado con `--container` y `--set-image`, permite reemplazar la imagen de un contenedor puntual en la copia:

```bash
$ kubectl debug api-6c9f7d8b5-4kxqz --copy-to=api-debug --set-image=api=api:1.4-debug
```

También sirve `--share-processes` para forzar que todos los contenedores de la copia compartan el Namespace de PID, y `--container` para elegir a cuál se le inyecta el contenedor de debug. Al terminar, la copia se borra manualmente:

```bash
$ kubectl delete pod api-debug
```

### 3.3 Debug de un Node

Cuando el problema no es del Pod sino del **Node** (kubelet, container runtime, filesystem del host), `kubectl debug` puede crear un Pod privilegiado en ese Node, montando su filesystem en `/host`:

```bash
$ kubectl debug node/node-2 -it --image=busybox
Creating debugging pod node-debugger-node-2-9j4kd with container debugger on node node-2.
/ # chroot /host
# systemctl status kubelet
# df -h /var/lib/kubelet
```

Este Pod de debug corre en `hostNetwork`/`hostPID` con el filesystem del Node bindeado en `/host`, y **hay que borrarlo a mano** al terminar (no se limpia solo):

```bash
$ kubectl get pods -o wide | grep node-debugger
node-debugger-node-2-9j4kd   1/1   Running   0   3m   node-2

$ kubectl delete pod node-debugger-node-2-9j4kd
```

---

## 4. `kubectl port-forward`: acceso directo sin Service

Expone un puerto local de la máquina del usuario hacia un puerto de un Pod (o Service), sin pasar por el Service/Ingress. Útil para probar una app directamente, evitando la capa de networking (tema 5) mientras se depura.

```bash
$ kubectl port-forward pod/web-7d9f8c9b8-9zj2q 8080:80
Forwarding from 127.0.0.1:8080 -> 80
Forwarding from [::1]:8080 -> 80
```

En otra terminal:

```bash
$ curl localhost:8080/healthz
ok
```

También funciona contra un Service (reenvía a uno de sus Pods backend) o un Deployment:

```bash
$ kubectl port-forward svc/web 8080:80
$ kubectl port-forward deployment/web 8080:8080
```

Notas de examen:

- El proceso queda **en foreground**, bloqueando la terminal hasta `Ctrl+C`; para liberar la terminal hace falta correrlo en background (`&`) o usar otra pestaña.
- Sirve para diagnosticar si el problema está en la **app misma** (con `port-forward` directo al Pod funciona) o en el **Service/networking** (con `port-forward` al Pod funciona, pero acceder vía Service no) — un patrón de diagnóstico frecuente en el examen.
- No requiere que el Pod tenga una `NodePort` ni un `LoadBalancer`; corre completamente a través de la API de Kubernetes (vía el `kube-apiserver` y el kubelet del Node).

---

## 5. `kubectl proxy`: acceso crudo a la API

Levanta un proxy local autenticado hacia el `kube-apiserver`, útil para explorar la API REST directamente (o acceder a UIs expuestas como Services sin `port-forward` por cada uno):

```bash
$ kubectl proxy --port=8001
Starting to serve on 127.0.0.1:8001
```

```bash
$ curl http://localhost:8001/api/v1/namespaces/prod/pods/web-7d9f8c9b8-9zj2q
{
  "kind": "Pod",
  ...
}

$ curl http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
```

A diferencia de `port-forward` (que apunta a un Pod/Service puntual), `kubectl proxy` da acceso a **toda la API**, usando las credenciales del `kubeconfig` actual — no hace falta pasar un token a mano.

---

## 6. `kubectl cp`: copiar archivos hacia/desde un contenedor

```bash
$ kubectl cp web-7d9f8c9b8-9zj2q:/var/log/app/error.log ./error.log
$ kubectl cp ./debug-script.sh web-7d9f8c9b8-9zj2q:/tmp/debug-script.sh -c web
```

Requiere que el contenedor tenga `tar` instalado (lo usa internamente para empaquetar); si la imagen es *distroless* y no lo tiene, `kubectl cp` falla — otro caso donde conviene un ephemeral container con `--target` en vez de intentar copiar archivos directamente.

---

## 7. Reconocer el problema: `STATUS`/`REASON` comunes

El examen espera que, mirando `kubectl get pods`, se identifique de entrada en qué **capa** está el problema y qué herramienta usar a continuación.

| STATUS / REASON | Capa del problema | Primer paso de diagnóstico |
|---|---|---|
| `Pending` | Scheduling (recursos insuficientes, taints, PVC sin bindear) | `kubectl describe pod` → sección `Events` (`FailedScheduling`) |
| `ImagePullBackOff` / `ErrImagePull` | Imagen (nombre mal escrito, tag inexistente, registry privado sin credenciales) | `kubectl describe pod` → `Events` (`Failed to pull image`) |
| `CreateContainerConfigError` | Referencia a un ConfigMap/Secret inexistente | `kubectl describe pod` → `Events` |
| `ContainerCreating` (colgado) | Volumen que no monta, CNI, `pull` lento | `kubectl describe pod` → `Events` |
| `CrashLoopBackOff` | La app arranca y termina sola (bug, config faltante) | `kubectl logs --previous` + `kubectl describe` (`Last State`) |
| `OOMKilled` (en `Last State`) | Memoria excede el `limit` | `kubectl top pod --containers`, revisar `resources.limits` (tema 4.4) |
| `Error` / `Completed` con `Exit Code != 0` | El proceso principal terminó con fallo | `kubectl logs --previous` |
| `Init:CrashLoopBackOff` / `Init:Error` | Falla en un `initContainer` | `kubectl logs -c <init> --previous` (tema 3.3) |
| Pod `Running` pero no responde | App viva pero rota a nivel funcional, o sin shell para inspeccionar | `kubectl exec` (si tiene shell) o `kubectl debug --target=` (si no) |

```bash
$ kubectl get pods -n prod
NAME                     READY   STATUS             RESTARTS   AGE
web-7d9f8c9b8-9zj2q      0/1     ImagePullBackOff   0          2m
cache-5f6b8d9c7-7hqxp    0/1     Pending            0          2m
api-6c9f7d8b5-4kxqz      1/1     Running            0          10m

$ kubectl describe pod cache-5f6b8d9c7-7hqxp | tail -5
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  -----------------  -------
  Warning  FailedScheduling  2m    default-scheduler  0/3 nodes are available: 3 Insufficient cpu.
```

---

## 8. Flujo de diagnóstico combinado

Integrando todo lo visto en 3.1–3.4, el orden habitual para resolver un Pod roto:

1. `kubectl get pods` → `STATUS`/`RESTARTS`, primera pista de la capa del problema (tabla arriba).
2. `kubectl describe pod <pod>` → `Conditions`, `Last State`, y sobre todo `Events` (tema 3.2).
3. Si el Pod arrancó al menos una vez: `kubectl logs [--previous] [-c <contenedor>]` (tema 3.3).
4. Si el Pod está `Running` pero se comporta mal: `kubectl exec -it <pod> -- sh` para inspeccionar desde adentro.
5. Si la imagen no tiene shell/herramientas: `kubectl debug -it <pod> --image=busybox --target=<contenedor>`.
6. Si el problema parece de networking: `kubectl port-forward` directo al Pod para aislar si es la app o el Service.
7. Si el problema es del Node (no del Pod): `kubectl debug node/<node>`.

```bash
$ kubectl get pods -l app=api
NAME                   READY   STATUS    RESTARTS   AGE
api-6c9f7d8b5-4kxqz    1/1     Running   0          15m

$ kubectl exec -it api-6c9f7d8b5-4kxqz -- sh
error: ... exec: "sh": executable file not found in $PATH: unknown

$ kubectl debug -it api-6c9f7d8b5-4kxqz --image=busybox --target=api -- sh
/ # wget -qO- http://localhost:8080/metrics | grep errors_total
errors_total 4213
```

---

## Resumen para el examen

- `kubectl exec -it <pod> [-c <contenedor>] -- <comando>` requiere el contenedor `Running` **y** un shell/binario disponible; el `--` separa flags de `kubectl` del comando remoto.
- `kubectl debug` tiene tres modos: **ephemeral container** (`--target`, no reinicia nada, queda pegado al Pod para siempre), **copia del Pod** (`--copy-to`, `--set-image`, no toca el original), y **debug de Node** (`node/<nombre>`, monta `/host`, hay que borrarlo a mano).
- Cuando `kubectl exec -- sh` falla por falta de shell (imagen *distroless*), la respuesta es `kubectl debug --target=<contenedor>`, no reinstalar herramientas en la imagen de producción.
- `kubectl port-forward` compara "¿funciona directo al Pod pero no vía Service?" para aislar problemas de aplicación vs. de networking; corre en foreground.
- `kubectl proxy` da acceso crudo a toda la API REST vía las credenciales del `kubeconfig`, a diferencia de `port-forward` que apunta a un recurso puntual.
- `kubectl cp` necesita `tar` en el contenedor destino; si no está, usar un ephemeral container en su lugar.
- Reconocer de un vistazo `Pending` (scheduling) vs. `ImagePullBackOff` (imagen) vs. `CrashLoopBackOff`/`OOMKilled` (app/recursos) ahorra tiempo: cada uno apunta a un comando distinto como siguiente paso.

---

## Referencias

- Kubernetes — Debug Running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Debug with an ephemeral debug container: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Kubernetes — Debugging Kubernetes Nodes with kubectl debug: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- Kubernetes — kubectl exec (reference): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#exec
- Kubernetes — kubectl port-forward (reference): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#port-forward
- Kubernetes — kubectl proxy (reference): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#proxy
- Kubernetes — kubectl cp (reference): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#cp
- Kubernetes — kubectl debug (reference): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#debug
- Kubernetes — Troubleshoot Applications: https://kubernetes.io/docs/tasks/debug/debug-application/
- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
