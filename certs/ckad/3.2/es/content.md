# 3.2 — Use built-in CLI tools to monitor Kubernetes applications

**Peso en el examen: 4%**

Monitorear aplicaciones en Kubernetes durante el examen CKAD significa una sola cosa: dominar `kubectl` y sus subcomandos de observación. No hay Prometheus ni Grafana en el examen; las herramientas "built-in" son `kubectl top`, `kubectl get`, `kubectl describe`, `kubectl events` y `kubectl logs`. Este tema se enfoca en las métricas de uso de recursos (CPU y memoria) y en la observación del estado de los objetos.

## 1. El pipeline de métricas: metrics-server

`kubectl top` no funciona por sí solo: depende del **Metrics API** (`metrics.k8s.io`), que en la práctica lo implementa el **metrics-server**. Este componente recolecta CPU y memoria desde el **kubelet** de cada nodo y las expone vía el API server.

```
kubelet (cAdvisor) ──> metrics-server ──> Metrics API ──> kubectl top
```

En el examen el cluster ya viene con metrics-server instalado. Si en tu laboratorio ves este error, es que falta instalarlo:

```
error: Metrics API not available
```

Podés verificar que el API de métricas está disponible con:

```bash
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True   20d
```

Puntos clave sobre las métricas:

- Son **instantáneas** (uso actual), no series de tiempo. No hay histórico.
- CPU se mide en **cores** o **millicores** (`m`): `250m` = 0,25 CPU.
- Memoria se mide en bytes con sufijos binarios: `Mi` (mebibytes), `Gi` (gibibytes).

## 2. kubectl top: uso de CPU y memoria

### 2.1 Nodos

```bash
kubectl top nodes
```

Salida típica:

```
NAME           CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
controlplane   231m         11%      1913Mi          49%
node01         89m          4%       1023Mi          26%
```

- `CPU(%)` y `MEMORY(%)` son relativos a la **capacidad allocatable** del nodo.
- Útil para responder preguntas del estilo *"identificá el nodo con mayor consumo de memoria y guardá su nombre en un archivo"*.

### 2.2 Pods

```bash
kubectl top pods                      # namespace actual
kubectl top pods -n prod              # otro namespace
kubectl top pods -A                   # todos los namespaces
kubectl top pods -l app=web           # filtrado por label selector
```

Salida típica:

```
NAME                   CPU(cores)   MEMORY(bytes)
web-5f7b9d6c4-abcde    12m          45Mi
web-5f7b9d6c4-fghij    250m         310Mi
worker-0               890m         1200Mi
```

### 2.3 Flags que resuelven preguntas de examen

**Ordenar** por consumo (muy frecuente en el examen):

```bash
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
```

El orden es **descendente**: el pod que más consume queda primero. Un patrón típico de ejercicio:

```bash
# "Encontrá el pod que más CPU consume con label app=stress
#  y escribí su nombre en /tmp/answer.txt"
kubectl top pods -l app=stress --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /tmp/answer.txt
```

**Desglose por contenedor** (para pods multi-container o con sidecars):

```bash
kubectl top pods web-5f7b9d6c4-abcde --containers
```

```
POD                   NAME        CPU(cores)   MEMORY(bytes)
web-5f7b9d6c4-abcde   app         10m          38Mi
web-5f7b9d6c4-abcde   log-agent   2m           7Mi
```

Otros flags útiles: `--no-headers` (facilita scripting) y `--sum` (agrega una fila con el total).

### 2.4 Relación con requests y limits

`kubectl top` muestra **uso real**, no lo declarado en el manifest. Para comparar contra `requests`/`limits` combinalo con:

```bash
kubectl describe pod web-5f7b9d6c4-abcde | grep -A4 Limits
kubectl get pod web-5f7b9d6c4-abcde -o jsonpath='{.spec.containers[*].resources}'
```

Esto importa para diagnosticar: un contenedor cuyo uso de memoria se acerca a su `limit` es candidato a un **OOMKill**; un pod que usa mucho más CPU que su `request` puede sufrir **throttling** si tiene `limit` de CPU.

## 3. Observar el estado con kubectl get

`kubectl get` es la vista rápida de salud de la aplicación:

```bash
kubectl get pods
```

```
NAME                   READY   STATUS             RESTARTS      AGE
web-5f7b9d6c4-abcde    1/1     Running            0             2d
api-7c9f8b5d6-xyz12    0/1     CrashLoopBackOff   7 (45s ago)   12m
```

Qué mirar:

- **READY `0/1`**: el contenedor corre pero la **readiness probe** falla, o el contenedor no arrancó.
- **RESTARTS** alto: la **liveness probe** falla o el proceso crashea (`CrashLoopBackOff`).
- **STATUS**: `Pending` (no se pudo schedule­ar o falta la imagen), `ImagePullBackOff`, `OOMKilled` (visible en `describe`), etc.

Modos útiles para monitoreo continuo:

```bash
kubectl get pods -w                          # --watch: stream de cambios
kubectl get pods -o wide                     # agrega IP y nodo
kubectl get deploy web                       # réplicas READY/UP-TO-DATE/AVAILABLE
kubectl rollout status deployment/web       # espera a que el rollout converja
```

## 4. kubectl describe y los events

Cuando `get` muestra un problema, `describe` explica el porqué:

```bash
kubectl describe pod api-7c9f8b5d6-xyz12
```

Al final de la salida aparece la sección **Events**, que registra lo que hizo el cluster con ese objeto:

```
Events:
  Type     Reason     Age                 From               Message
  ----     ------     ----                ----               -------
  Normal   Scheduled  12m                 default-scheduler  Successfully assigned default/api-... to node01
  Normal   Pulled     10m (x5 over 12m)   kubelet            Container image "api:2.1" already present on machine
  Warning  BackOff    2m (x32 over 11m)   kubelet            Back-off restarting failed container
  Warning  Unhealthy  90s (x8 over 11m)   kubelet            Liveness probe failed: HTTP probe failed with statuscode: 500
```

También podés consultar los events directamente, sin pasar por un objeto puntual:

```bash
kubectl events                                   # events del namespace actual
kubectl events --for pod/api-7c9f8b5d6-xyz12     # de un objeto específico
kubectl events --types=Warning                   # solo warnings
kubectl events -w                                # en vivo
```

`kubectl events` (estable desde v1.26) reemplaza al viejo `kubectl get events`, con mejor ordenamiento por defecto (cronológico). La forma clásica todavía sirve y aparece en muchos materiales:

```bash
kubectl get events --sort-by=.metadata.creationTimestamp
```

Los events se retienen por defecto **una hora**: si el problema pasó hace más tiempo, no van a estar.

## 5. kubectl logs como herramienta de monitoreo

Los logs se tratan en profundidad en el tema 3.1, pero para monitoreo recordá el modo "seguimiento":

```bash
kubectl logs -f deploy/web                     # stream en vivo
kubectl logs --since=5m api-7c9f8b5d6-xyz12    # últimos 5 minutos
kubectl logs --tail=50 -l app=web --prefix     # últimas 50 líneas de todos los pods del selector
kubectl logs api-7c9f8b5d6-xyz12 --previous    # instancia anterior (clave en CrashLoopBackOff)
```

## 6. Flujo de diagnóstico recomendado para el examen

1. `kubectl get pods` — ¿qué pod está mal? (READY, STATUS, RESTARTS)
2. `kubectl describe pod <pod>` — ¿qué dicen los **Events**? (probes, imagen, scheduling, OOM)
3. `kubectl logs <pod> [--previous]` — ¿qué dice la aplicación?
4. `kubectl top pods --sort-by=...` — ¿es un problema de recursos? Comparar con `requests`/`limits`.

Practicá los flags `--sort-by`, `-l`, `--containers` y `--no-headers` hasta que salgan de memoria: las preguntas de este tema suelen ser rápidas ("identificá el pod que más consume y guardalo en un archivo") y son puntos casi regalados si conocés la sintaxis exacta.

## Referencias

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Resource metrics pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes — `kubectl top`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_top/
- Kubernetes — `kubectl events`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_events/
- Kubernetes — Debug running pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Tools for monitoring resources: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/
- metrics-server (SIG Instrumentation): https://github.com/kubernetes-sigs/metrics-server
- Kubernetes — kubectl Quick Reference: https://kubernetes.io/docs/reference/kubectl/quick-reference/