# Ejercicios guiados — CNPE Tema 2.3: Diagnóstico y remediación de incidentes de plataforma

> **Alcance.** Estos ejercicios reproducen incidentes reales de plataforma sobre Kubernetes y su stack de observabilidad, y te obligan a diagnosticarlos con un método sistemático antes de remediarlos. La meta no es memorizar comandos sueltos, sino construir el flujo *señal → hipótesis → confirmación → remediación → verificación → prevención* que un Platform Engineer aplica durante un incidente.
>
> **Requisitos previos.** Un cluster de práctica desechable (`kind`, `minikube`, k3d o un cluster de laboratorio) con `kubectl` configurado, y opcionalmente `kube-prometheus-stack` instalado para los ejercicios 5 y 7. Trabajá siempre en un namespace dedicado para poder limpiar sin efectos colaterales.
>
> ```bash
> kubectl create namespace incident-lab
> kubectl config set-context --current --namespace=incident-lab
> ```
>
> **Fuentes de referencia:**
> - CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
> - Debug Running Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
> - Debug Services — https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
> - Debug DNS — https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
> - Monitor Node Health / Cluster — https://kubernetes.io/docs/tasks/debug/debug-cluster/
> - Resource metrics pipeline — https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
> - Prometheus querying basics — https://prometheus.io/docs/prometheus/latest/querying/basics/
> - CNCF Postmortem culture (Google SRE, referencia adoptada por CNCF) — https://sre.google/sre-book/postmortem-culture/

---

## Ejercicio 1 — Triage inicial: mapear el estado del cluster antes de tocar nada

**Escenario.** Recibís una alerta genérica: *"la plataforma está lenta / algo falla en `incident-lab`"*. No hay más contexto. Antes de formular hipótesis necesitás una foto objetiva del estado. La regla de oro del triage: **observá antes de intervenir**; cada `kubectl delete` o `rollout restart` prematuro destruye evidencia.

1. Desplegá un conjunto de cargas para tener sobre qué diagnosticar:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   kubectl create deployment broken --image=nginx:doesnotexist --replicas=2
   kubectl expose deployment web --port=80 --target-port=80
   ```

2. Tomá la foto global de recursos y eventos, ordenando los eventos por tiempo:

   ```bash
   kubectl get pods -o wide
   kubectl get events --sort-by=.lastTimestamp | tail -n 15
   ```

   Salida esperada (abreviada):

   ```
   NAME                      READY   STATUS             RESTARTS   AGE   IP           NODE
   broken-6d4c8b9f7-4wq2z    0/1     ImagePullBackOff   0          40s   10.244.1.7   kind-worker
   broken-6d4c8b9f7-lm9pk    0/1     ErrImagePull       0          40s   10.244.2.5   kind-worker2
   web-77b9d4c8c9-2xk4l      1/1     Running            0          40s   10.244.1.6   kind-worker
   ...
   ```

   ```
   LAST SEEN   TYPE      REASON        OBJECT                       MESSAGE
   38s         Warning   Failed        pod/broken-6d4c8b9f7-4wq2z   Failed to pull image "nginx:doesnotexist": ... not found
   38s         Warning   Failed        pod/broken-6d4c8b9f7-4wq2z   Error: ErrImagePull
   25s         Normal    BackOff       pod/broken-6d4c8b9f7-4wq2z   Back-off pulling image "nginx:doesnotexist"
   ```

3. Cuantificá el "radio de impacto": cuántos Pods NO están sanos frente al total.

   ```bash
   kubectl get pods --no-headers | awk '{print $3}' | sort | uniq -c
   ```

   Salida esperada:

   ```
         2 ImagePullBackOff
         3 Running
   ```

**Preguntas de verificación (bloque 1)**

1. ¿Por qué el primer comando ante un incidente ambiguo debe ser observacional (`get`, `describe`, `events`) y no correctivo (`delete`, `restart`)?
2. ¿Qué diferencia hay entre los estados `ErrImagePull` e `ImagePullBackOff`, y qué te dice esa transición sobre el comportamiento del kubelet?
3. `kubectl get events` por defecto no ordena cronológicamente. ¿Por qué `--sort-by=.lastTimestamp` es importante y qué limitación tiene el campo `lastTimestamp` para reconstruir la línea de tiempo de un incidente?

---

## Ejercicio 2 — CrashLoopBackOff: distinguir fallo de aplicación de fallo de configuración

**Escenario.** Un servicio arranca y muere en bucle. `CrashLoopBackOff` es un *síntoma*, no una *causa*: solo dice que el contenedor termina y el kubelet lo reinicia con backoff exponencial. Tu trabajo es encontrar la causa raíz.

1. Desplegá una carga que falla por configuración (falta una variable de entorno obligatoria simulada con un comando que sale con código ≠ 0):

   ```yaml
   # crasher.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: crasher
     labels:
       app: crasher
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: crasher
     template:
       metadata:
         labels:
           app: crasher
       spec:
         containers:
           - name: app
             image: busybox:1.36
             command: ["/bin/sh", "-c"]
             args:
               - |
                 if [ -z "$REQUIRED_TOKEN" ]; then
                   echo "FATAL: REQUIRED_TOKEN is not set" >&2
                   exit 1
                 fi
                 sleep 3600
   ```

   ```bash
   kubectl apply -f crasher.yaml
   ```

2. Esperá unos segundos y confirmá el bucle:

   ```bash
   kubectl get pod -l app=crasher
   ```

   ```
   NAME                       READY   STATUS             RESTARTS      AGE
   crasher-5c9b7d8f6-t2mzn    0/1     CrashLoopBackOff   3 (20s ago)   70s
   ```

3. Leé los logs del contenedor que **acaba de morir** (no el actual, que puede no haber arrancado). El flag `--previous` es la clave:

   ```bash
   kubectl logs -l app=crasher --previous --tail=20
   ```

   ```
   FATAL: REQUIRED_TOKEN is not set
   ```

4. Correlacioná con el `describe` para ver el `Last State`, el `Exit Code` y la `Reason`:

   ```bash
   kubectl describe pod -l app=crasher | sed -n '/Last State/,/Ready/p'
   ```

   ```
       Last State:     Terminated
         Reason:       Error
         Exit Code:    1
         Started:      Thu, 07 Aug 2026 14:20:11 +0000
         Finished:     Thu, 07 Aug 2026 14:20:11 +0000
   ```

5. Remediá inyectando la configuración faltante y verificá la convergencia:

   ```bash
   kubectl set env deployment/crasher REQUIRED_TOKEN=abc123
   kubectl rollout status deployment/crasher --timeout=60s
   ```

   ```
   deployment "crasher" successfully rolled out
   ```

**Preguntas de verificación (bloque 2)**

1. ¿Por qué `kubectl logs --previous` es imprescindible en un `CrashLoopBackOff` y qué habrías visto (o no) sin ese flag?
2. Un `Exit Code: 1` con `Reason: Error` vs. un `Exit Code: 137` con `Reason: OOMKilled` apuntan a causas raíz completamente distintas. Explicá qué representa cada uno y cómo cambiaría tu remediación.
3. El `RESTARTS` crecía y el `AGE` del Pod se mantenía. ¿Qué te dice esto sobre si el kubelet reemplaza el Pod o reinicia el contenedor dentro del mismo Pod, y qué recurso conserva su identidad (IP, nombre)?

---

## Ejercicio 3 — Pods en Pending: descifrar por qué el scheduler no coloca la carga

**Escenario.** Un Deployment se aplica pero los Pods quedan en `Pending` indefinidamente. `Pending` significa que el objeto existe en la API pero el scheduler no encontró un nodo válido, o el nodo no puede admitir el Pod. El mensaje del scheduler es el diagnóstico.

1. Provocá un fallo de scheduling pidiendo más CPU de la que existe en cualquier nodo:

   ```yaml
   # greedy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: greedy
   spec:
     replicas: 1
     selector:
       matchLabels: { app: greedy }
     template:
       metadata:
         labels: { app: greedy }
       spec:
         containers:
           - name: app
             image: nginx:1.27
             resources:
               requests:
                 cpu: "64"        # 64 cores: ningún nodo de lab los tiene
                 memory: "1Gi"
   ```

   ```bash
   kubectl apply -f greedy.yaml
   kubectl get pod -l app=greedy
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   greedy-7f8c9d5b4-nq6vx    0/1     Pending   0          15s
   ```

2. Leé el motivo exacto en los eventos del Pod (siempre al final del `describe`):

   ```bash
   kubectl describe pod -l app=greedy | tail -n 8
   ```

   ```
   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  20s   default-scheduler  0/3 nodes are available: 3 Insufficient cpu.
                                                          preemption: 0/3 nodes are available: 3 No preemption victims found.
   ```

3. Comprobá la capacidad real y lo ya reservado (allocatable vs. requests) del cluster:

   ```bash
   kubectl describe nodes | grep -A5 "Allocated resources"
   ```

   ```
     Allocated resources:
       Resource           Requests    Limits
       cpu                750m (18%)  0 (0%)
       memory             190Mi (2%)  0 (0%)
   ```

4. Remediá ajustando el request a algo que quepa, y verificá:

   ```bash
   kubectl patch deployment greedy --type=json \
     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"250m"}]'
   kubectl get pod -l app=greedy -w --timeout=60s
   ```

   ```
   greedy-6b5d7c9f8-abcde    1/1     Running   0    8s
   ```

**Preguntas de verificación (bloque 3)**

1. El scheduler diferencia dos fases: *filtering* (Predicates) y *scoring* (Priorities). El mensaje `Insufficient cpu` ¿en cuál de las dos fases se produjo, y qué implica que el mensaje mencione `preemption: ... No preemption victims found`?
2. Además de `Insufficient cpu`, enumerá al menos tres causas frecuentes de `Pending` que verías en el mismo campo `Events` (pista: taints, volúmenes, afinidad).
3. ¿Por qué se compara contra *allocatable* y no contra *capacity* del nodo? ¿Qué consume la diferencia entre ambos?

---

## Ejercicio 4 — Conectividad de Service y resolución DNS: el clásico "no llega el tráfico"

**Escenario.** Una aplicación no puede alcanzar a otra por su nombre de Service. El fallo puede estar en el DNS (CoreDNS), en el `selector` del Service, en los endpoints, o en una `NetworkPolicy`. Vas a bisecar la ruta de red de afuera hacia adentro.

1. Asegurate de tener el Service `web` del ejercicio 1 y lanzá un Pod cliente de diagnóstico efímero:

   ```bash
   kubectl run netcheck --image=nicolaka/netshoot --restart=Never -it --rm -- /bin/bash
   ```

2. Dentro del Pod, resolvé el nombre del Service (prueba de DNS) y luego probá la conexión TCP (prueba de datapath):

   ```bash
   nslookup web.incident-lab.svc.cluster.local
   curl -s -o /dev/null -w "%{http_code}\n" http://web.incident-lab.svc.cluster.local
   ```

   Salida esperada de un camino sano:

   ```
   Server:    10.96.0.10
   Address:   10.96.0.10#53
   Name:      web.incident-lab.svc.cluster.local
   Address:   10.96.31.42
   200
   ```

3. Ahora **rompé** el Service cambiando su selector para que no matchee ningún Pod (fuera del Pod de diagnóstico, en otra terminal):

   ```bash
   kubectl patch service web -p '{"spec":{"selector":{"app":"noexiste"}}}'
   ```

4. Verificá el efecto sobre los **endpoints** (aquí es donde se rompe el datapath aunque el DNS siga resolviendo):

   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=web
   kubectl get endpoints web
   ```

   ```
   NAME         ADDRESSTYPE   PORTS   ENDPOINTS   AGE
   web-abc12    IPv4          <unset> <unset>     5m
   ```
   ```
   NAME   ENDPOINTS   AGE
   web    <none>      5m
   ```

5. Reproducí el fallo desde el cliente: el DNS resuelve (la ClusterIP existe) pero la conexión cuelga o da *connection refused / timeout* porque no hay backends:

   ```bash
   # dentro del Pod netcheck
   nslookup web.incident-lab.svc.cluster.local   # sigue resolviendo la ClusterIP
   curl -m 5 http://web.incident-lab.svc.cluster.local ; echo "exit=$?"
   ```
   ```
   curl: (28) Connection timed out after 5001 milliseconds
   exit=28
   ```

6. Remediá restaurando el selector correcto y confirmá que los endpoints reaparecen:

   ```bash
   kubectl patch service web -p '{"spec":{"selector":{"app":"web"}}}'
   kubectl get endpoints web
   ```
   ```
   NAME   ENDPOINTS                                      AGE
   web    10.244.1.6:80,10.244.2.4:80,10.244.2.6:80      6m
   ```

**Preguntas de verificación (bloque 4)**

1. En el paso 5 el DNS resolvía pero el `curl` fallaba. Explicá por qué la ClusterIP existe y responde a DNS aun cuando el Service no tiene ningún endpoint, y qué componente (CoreDNS, kube-proxy, controller de endpoints) es responsable de cada parte.
2. Describí la cadena completa que traduce `web.incident-lab.svc.cluster.local:80` hasta un Pod concreto: ¿qué rol juega el `EndpointSlice`, y qué componente programa las reglas iptables/IPVS que hacen el balanceo?
3. Si `nslookup` **fallara** en lugar de resolver, ¿qué tres cosas revisarías, en orden, para aislar si el problema es de CoreDNS o del propio Pod (pista: `/etc/resolv.conf`, Pods de CoreDNS, `ConfigMap coredns`)?

---

## Ejercicio 5 — Nodo NotReady y presión de recursos: bajar del Pod al host

**Escenario.** Varios Pods de un mismo nodo empiezan a fallar o a ser evictados. El problema no está en las aplicaciones sino en el nodo. Un Platform Engineer debe saber leer las `Conditions` del nodo y el estado del kubelet.

1. Inspeccioná el estado y las condiciones de los nodos:

   ```bash
   kubectl get nodes
   kubectl describe node <NODE> | sed -n '/Conditions:/,/Addresses:/p'
   ```

   Salida de un nodo con problemas de disco:

   ```
   Conditions:
     Type                 Status    Reason                       Message
     ----                 ------    ------                       -------
     MemoryPressure       False     KubeletHasSufficientMemory   kubelet has sufficient memory available
     DiskPressure         True      KubeletHasDiskPressure       kubelet has disk pressure
     PIDPressure          False     KubeletHasSufficientPID      kubelet has sufficient PID available
     Ready                True      KubeletReady                 kubelet is posting ready status
   ```

2. Cuando un nodo entra en `DiskPressure`, el kubelet inicia *eviction*. Detectá Pods evictados y su razón:

   ```bash
   kubectl get pods -A --field-selector=status.phase=Failed
   kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail
   ```

   ```
   NAMESPACE      NAME              REASON    MESSAGE
   incident-lab   web-...-2xk4l     Evicted   The node was low on resource: ephemeral-storage.
   ```

3. Consultá métricas de nodo en vivo (requiere metrics-server) para cuantificar la presión:

   ```bash
   kubectl top nodes
   kubectl top pods -A --sort-by=memory | head
   ```

   ```
   NAME          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
   kind-worker   1820m        45%    6100Mi          78%
   ```

4. Si `Ready` fuera `Unknown`, el problema es el kubelet o su comunicación con el API server. Comprobá el heartbeat y el servicio en el host (vía nodo, `crictl` o SSH según tu entorno):

   ```bash
   # en el nodo afectado
   systemctl status kubelet --no-pager | head -n 5
   journalctl -u kubelet --since "10 min ago" | tail -n 20
   crictl ps -a | head          # contenedores que el runtime ve realmente
   ```

5. Remediá según la causa: liberá disco (imágenes/logs huérfanos) o acordoná el nodo para drenarlo de forma controlada mientras se repara:

   ```bash
   kubectl cordon <NODE>                    # no se programan Pods nuevos ahí
   kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data
   # ...reparación del host...
   kubectl uncordon <NODE>                   # se readmite scheduling
   ```

**Preguntas de verificación (bloque 5)**

1. Diferenciá los tres estados posibles de la condición `Ready`: `True`, `False` y `Unknown`. ¿Cuál indica que el kubelet dejó de reportar heartbeat, y qué mecanismo (node lease / `node-monitor-grace-period`) lo detecta?
2. Un nodo en `DiskPressure=True` evicta Pods siguiendo un orden de prioridad. ¿En qué orden se evictan las QoS classes (`Guaranteed`, `Burstable`, `BestEffort`) y por qué ese orden protege la estabilidad del nodo?
3. ¿Qué diferencia práctica hay entre `cordon` y `drain`, y por qué `drain` necesita `--ignore-daemonsets`? ¿Qué mecanismo puede impedir que un `drain` progrese y cómo lo diagnosticarías (pista: PodDisruptionBudget)?

---

## Ejercicio 6 — Remediación por rollback: revertir un despliegue defectuoso rápido

**Escenario.** Un despliegue nuevo introdujo una regresión (el "cambio" es la causa de incidente más frecuente en producción). La remediación correcta durante el incidente es **restaurar servicio primero** —normalmente con un rollback— y depurar la causa después.

1. Simulá una versión sana y luego una regresión (imagen inexistente que rompe el rollout):

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27
   kubectl rollout status deployment/web
   kubectl set image deployment/web nginx=nginx:1.99-broken
   ```

2. Observá que el rollout queda atascado sin derribar la versión anterior (gracias a la `RollingUpdate` con `maxUnavailable`):

   ```bash
   kubectl rollout status deployment/web --timeout=30s
   ```
   ```
   Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
   error: deadline exceeded (context deadline exceeded)
   ```
   ```bash
   kubectl get pods -l app=web
   ```
   ```
   web-<old>-...   1/1   Running            0   4m
   web-<old>-...   1/1   Running            0   4m
   web-<new>-...   0/1   ImagePullBackOff   0   40s
   ```

3. Revisá el historial de revisiones antes de revertir:

   ```bash
   kubectl rollout history deployment/web
   ```
   ```
   REVISION  CHANGE-CAUSE
   1         <none>
   2         <none>
   3         <none>
   ```

4. Remediá con rollback a la revisión sana y verificá la convergencia:

   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web --timeout=60s
   kubectl get pods -l app=web
   ```
   ```
   deployment "web" successfully rolled out
   web-<old>-...   1/1   Running   0   6m
   web-<old>-...   1/1   Running   0   6m
   web-<old>-...   1/1   Running   0   6m
   ```

**Preguntas de verificación (bloque 6)**

1. En el paso 2, la versión anterior siguió sirviendo tráfico pese al rollout roto. ¿Qué parámetros de la estrategia `RollingUpdate` (`maxUnavailable`, `maxSurge`) garantizan ese comportamiento y por qué son una red de seguridad de facto?
2. ¿Dónde vive el historial que hace posible `rollout undo`? ¿Qué recurso de Kubernetes almacena cada revisión y cómo controlás cuántas se conservan?
3. Durante un incidente, ¿por qué la doctrina SRE prioriza `rollback` sobre "arreglar hacia adelante" (fix-forward), y en qué caso concreto el rollback **no** es una opción válida (pista: migraciones de esquema de base de datos)?

---

## Ejercicio 7 — Diagnóstico dirigido por observabilidad: de la alerta al PromQL

**Escenario.** La observabilidad convierte el diagnóstico reactivo en dirigido. En vez de adivinar, consultás métricas. Este ejercicio usa Prometheus (por ejemplo vía `kube-prometheus-stack`) para localizar la carga culpable a partir de las señales doradas. Si no tenés Prometheus, leé las consultas y sus salidas como referencia.

1. Abrí el acceso a Prometheus (o usá Grafana → Explore):

   ```bash
   kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
   ```

2. Reproducí un caso de reinicios: aplicá de nuevo el `crasher.yaml` del ejercicio 2 sin la variable. Luego, en la UI de Prometheus (`http://localhost:9090`), consultá los reinicios por Pod en la última hora:

   ```promql
   sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0
   ```
   Salida esperada (tabla):
   ```
   {namespace="incident-lab", pod="crasher-5c9b7d8f6-t2mzn"}   6
   ```

3. Consultá saturación de memoria relativa al límite (para anticipar OOMKills), una señal dorada de *saturation*:

   ```promql
   max by (pod) (
     container_memory_working_set_bytes{namespace="incident-lab"}
     /
     (kube_pod_container_resource_limits{namespace="incident-lab", resource="memory"} > 0)
   )
   ```
   ```
   {pod="cache-0"}   0.94
   ```

4. Consultá la tasa de errores HTTP 5xx (señal dorada de *errors*), asumiendo métricas de un Ingress/servicio instrumentado:

   ```promql
   sum(rate(http_requests_total{namespace="incident-lab", code=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{namespace="incident-lab"}[5m]))
   ```
   ```
   {}   0.037     # 3.7% de las requests devuelven 5xx
   ```

5. Verificá qué reglas de alerta están activas ahora mismo (el puente entre métrica y notificación):

   ```bash
   kubectl -n monitoring get prometheusrules
   ```
   ```
   # o en la UI: Status -> Rules / Alerts -> estado 'firing'
   ```

**Preguntas de verificación (bloque 7)**

1. Nombrá las cuatro *golden signals* (SRE) y asociá cada consulta PromQL de este ejercicio con la señal que mide. ¿Cuál de las cuatro **no** se cubrió con ninguna consulta y cómo la medirías?
2. En el paso 2 se usó `increase(...[1h])` en lugar de leer el valor crudo del contador `kube_pod_container_status_restarts_total`. ¿Por qué `increase`/`rate` sobre un contador acumulativo, y qué problema causaría graficar el contador crudo tras un reinicio de Pod (reset a 0)?
3. Definí *error budget* y explicá cómo la tasa de 5xx del paso 4, sostenida, se traduce en consumo de presupuesto de error frente a un SLO de disponibilidad del 99.9%. ¿Qué decisión operativa dispara agotar ese presupuesto?

---

## Ejercicio 8 — Cierre del incidente: timeline, causa raíz y postmortem sin culpa

**Escenario.** El servicio ya está restaurado. El incidente **no termina** hasta capturar aprendizaje. Un Platform Engineer produce un postmortem *blameless* que convierte el incidente en mejoras de la plataforma.

1. Reconstruí la línea de tiempo objetiva a partir de la evidencia que capturaste (no de la memoria). Extraé eventos con marca temporal:

   ```bash
   kubectl get events -A --sort-by=.lastTimestamp \
     -o custom-columns='TIME:.lastTimestamp,NS:.metadata.namespace,REASON:.reason,OBJECT:.involvedObject.name,MSG:.message' \
     | grep -Ei 'Failed|Evicted|BackOff|Unhealthy|Killing' | tail -n 20
   ```

2. Redactá el postmortem con esta plantilla mínima (guardala como `postmortem-<fecha>.md`):

   ```markdown
   # Postmortem — <título breve del incidente>
   - **Fecha / duración:** 2026-08-07, 14:05–14:38 UTC (33 min)
   - **Severidad / impacto:** SEV2 — 3.7% de requests con 5xx; 2 Pods evictados
   - **Detección:** alerta `HighErrorRate` (firing 14:07) — MTTD 2 min
   - **Resolución:** rollback a revisión 2 — MTTR 31 min

   ## Timeline (UTC, hechos con evidencia)
   - 14:05  deploy de web:1.99-broken (revisión 3)
   - 14:07  alerta HighErrorRate firing
   - 14:20  identificado ImagePullBackOff en Pods nuevos
   - 14:36  `kubectl rollout undo` ejecutado
   - 14:38  error rate vuelve a línea base

   ## Causa raíz (los 5 porqués)
   Tag de imagen inexistente llegó a prod porque el pipeline no valida
   la existencia del artefacto antes de aplicar el manifiesto.

   ## Qué salió bien / qué salió mal
   ## Acciones de seguimiento (con dueño y ticket)
   - [ ] Gate de CI que verifica `docker manifest inspect` antes del deploy — @owner — JIRA-123
   - [ ] Alerta sobre `ImagePullBackOff` sostenido > 2 min — @owner — JIRA-124
   ```

3. Calculá y registrá las métricas de respuesta que alimentan la mejora continua:

   ```
   MTTD (Mean Time To Detect)   = t(alerta) - t(inicio del impacto)
   MTTA (Mean Time To Acknowledge) = t(reconocimiento) - t(alerta)
   MTTR (Mean Time To Recover)  = t(servicio restaurado) - t(inicio del impacto)
   ```

**Preguntas de verificación (bloque 8)**

1. ¿Qué significa exactamente que un postmortem sea *blameless* y por qué esa cultura produce mejor MTTR a largo plazo que una que asigna culpas a personas?
2. En la causa raíz se aplicaron "los 5 porqués". ¿Por qué el resultado apunta a un fallo del **sistema/pipeline** y no al ingeniero que ejecutó el deploy? Reescribí el último "porqué" para que la acción correctiva sea sistémica.
3. Distinguí MTTD, MTTA y MTTR. Si tu MTTR es bueno pero tu MTTD es malo, ¿qué parte de la plataforma invertirías en mejorar primero, y por qué esa priorización maximiza la reducción del impacto total del incidente?

---

## Limpieza

```bash
kubectl delete namespace incident-lab
kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Bloque 1 — Triage inicial

1. **Observar antes de intervenir** porque el estado del cluster *es* la evidencia. Un `delete`/`restart` prematuro borra logs (`--previous` deja de existir), reinicia contadores de `RESTARTS`, cambia IPs y puede enmascarar la causa raíz, forzándote a esperar a que el incidente se reproduzca. Además, sin conocer el radio de impacto podés "arreglar" el síntoma equivocado. La secuencia correcta es capturar `get/describe/events/logs` primero.
2. `ErrImagePull` es el resultado inmediato del **primer** intento fallido de descargar la imagen. `ImagePullBackOff` es lo que ocurre después: el kubelet aplica *backoff exponencial* entre reintentos (10s, 20s, 40s… hasta un tope de ~5 min) para no martillar el registry. La transición `ErrImagePull → ImagePullBackOff` te confirma que el kubelet ya reintentó y sigue fallando de forma persistente — no es un glitch transitorio, es un problema estable (tag inexistente, credenciales de registry, o red hacia el registry).
3. Sin `--sort-by=.lastTimestamp` los eventos salen en orden arbitrario y es imposible reconstruir la secuencia causal. **Limitación:** los eventos de Kubernetes se **compactan** (el mismo evento repetido actualiza `lastTimestamp` y un contador en lugar de crear entradas nuevas) y además **caducan** (TTL por defecto ~1 h). Por eso los eventos sirven para el *ahora* pero no son un registro histórico fiable: para la línea de tiempo de un postmortem necesitás logs/métricas persistentes, no solo `kubectl get events`.

### Bloque 2 — CrashLoopBackOff

1. En un `CrashLoopBackOff` el contenedor **actual** puede estar detenido o recién arrancando, así que `kubectl logs` (sin flag) suele devolver vacío o los logs de un intento que aún no falló. `--previous` lee el stdout/stderr de la **instancia anterior ya terminada**, que es justo la que contiene el mensaje fatal (`FATAL: REQUIRED_TOKEN is not set`). Sin él, no habrías visto la causa.
2. `Exit Code: 1` + `Reason: Error` = la **aplicación** decidió terminar con error (excepción no capturada, config faltante, dependencia caída). Remediación: arreglar config/código/dependencia. `Exit Code: 137` + `Reason: OOMKilled` = el **kernel** mató el proceso por exceder el límite de memoria (137 = 128 + 9, señal SIGKILL). Remediación: subir `resources.limits.memory`, corregir fugas de memoria, o ajustar el heap. Confundirlos lleva a "arreglar" recursos cuando el problema es lógico, o viceversa.
3. Que `RESTARTS` suba mientras el `AGE` del Pod se mantiene indica que el **kubelet reinicia el contenedor dentro del mismo Pod** (según `restartPolicy`), no crea un Pod nuevo. El Pod conserva su **identidad**: nombre, UID e IP. Solo un controlador superior (Deployment/ReplicaSet) crearía un Pod nuevo, lo que reiniciaría el `AGE` y cambiaría el nombre/IP.

### Bloque 3 — Pending

1. El mensaje `Insufficient cpu` se produce en la fase de **filtering (Predicates)**: ningún nodo pasa el filtro de recursos, por lo que nunca se llega a *scoring*. `No preemption victims found` significa que el scheduler intentó, como último recurso, desalojar Pods de menor prioridad para hacer sitio, pero no encontró candidatos cuyo desalojo permitiera colocar este Pod — por eso queda `Pending` en vez de expulsar a otros.
2. Otras causas típicas de `Pending` en `Events`: (a) **Taints sin toleration** — `node(s) had untolerated taint {key: value}`; (b) **Afinidad/anti-afinidad o nodeSelector** sin nodo que matchee — `didn't match Pod's node affinity/selector`; (c) **PVC no vinculable** — `pod has unbound immediate PersistentVolumeClaims` (no hay PV / StorageClass que satisfaga el claim); también `too many pods` (límite de Pods por nodo) y hostPort en conflicto.
3. Se compara contra **allocatable** porque *capacity* es el hardware total del nodo, pero una parte está reservada y no es programable para cargas: `kube-reserved` (kubelet, runtime), `system-reserved` (OS, sshd), y el `eviction-threshold` que el kubelet guarda para poder evictar antes de quedarse sin recursos. `allocatable = capacity − kube-reserved − system-reserved − eviction-threshold`. Programar contra capacity provocaría OOM del propio nodo.

### Bloque 4 — Service y DNS

1. La **ClusterIP es una IP virtual estable asignada al objeto Service en el momento de crearlo**, independiente de si tiene backends. **CoreDNS** resuelve el nombre a esa ClusterIP consultando el objeto Service en la API — sigue resolviendo aunque no haya endpoints. Lo que falta cuando el selector no matchea es el **EndpointSlice** poblado por el *endpoints/endpointslice controller*; sin endpoints, **kube-proxy** no programa reglas de reenvío hacia ningún Pod y el tráfico a la ClusterIP se descarta/timeout. Resumen: CoreDNS → nombre→ClusterIP; endpoint controller → Pods vivos que matchean; kube-proxy → ClusterIP→Pod real.
2. Cadena: (1) el cliente pregunta `web...svc.cluster.local` → **CoreDNS** devuelve la ClusterIP. (2) El cliente abre TCP a `ClusterIP:80`. (3) En el nodo, **kube-proxy** (o el CNI en modo eBPF, p.ej. Cilium) tiene reglas **iptables/IPVS** que hacen DNAT de `ClusterIP:80` hacia una de las IPs de Pod. (4) Esas IPs provienen del **EndpointSlice** asociado al Service, que el endpoint controller mantiene sincronizado con los Pods `Ready` que matchean el selector. El EndpointSlice es la fuente de verdad de "qué Pods están detrás del Service".
3. Si `nslookup` fallara: (a) **`cat /etc/resolv.conf` dentro del Pod** — ¿apunta a la ClusterIP de CoreDNS (típicamente `10.96.0.10`) y tiene el `search` correcto? (b) **`kubectl -n kube-system get pods -l k8s-app=kube-dns`** — ¿están los Pods de CoreDNS `Running` y sin reinicios? Revisá sus logs. (c) **`kubectl -n kube-system get configmap coredns -o yaml`** — ¿el `Corefile` es válido y con `forward` correcto para dominios externos? El orden va del Pod (lo más barato/cercano) hacia el servicio compartido.

### Bloque 5 — Nodo NotReady y presión

1. `Ready=True`: el kubelet reporta y admite Pods. `Ready=False`: el kubelet **está reportando** pero el nodo no está listo (p.ej. red del nodo caída, runtime no operativo) — es un fallo declarado. `Ready=Unknown`: el **kubelet dejó de enviar heartbeat**; el control plane no sabe nada. El heartbeat moderno usa **Node Lease** (objeto `Lease` renovado periódicamente en `kube-node-lease`); si el node-controller no ve renovación dentro del `node-monitor-grace-period` (~40s por defecto), marca `Ready=Unknown` y, pasado el timeout de eviction, expulsa los Pods.
2. Orden de eviction bajo presión: **`BestEffort` primero** (sin requests/limits, sacrificable), luego **`Burstable`** (los que más exceden sus *requests* se van antes), y **`Guaranteed` al final** (requests == limits en todos sus contenedores). El orden protege la estabilidad porque desaloja primero la carga que menos garantías pidió, preservando las cargas que reservaron recursos de forma estricta.
3. `cordon` marca el nodo como no-programable (`SchedulingDisabled`): no llegan Pods nuevos, pero **los existentes siguen corriendo**. `drain` = `cordon` **+** desalojo ordenado de los Pods actuales (respetando PDBs y `terminationGracePeriod`). Necesita `--ignore-daemonsets` porque los Pods gestionados por DaemonSet se recrearían inmediatamente en el mismo nodo (están anclados a él), así que `drain` fallaría o no tendría sentido desalojarlos. Un **PodDisruptionBudget** puede bloquear el `drain`: si desalojar un Pod violaría el `minAvailable`/`maxUnavailable`, la evicción se rechaza y `drain` se queda esperando — lo diagnosticás con `kubectl get pdb` y los eventos del `drain`.

### Bloque 6 — Rollback

1. `RollingUpdate` con `maxUnavailable` (cuántos Pods viejos pueden faltar durante la actualización) y `maxSurge` (cuántos Pods extra sobre el `replicas` deseado se permiten). Con los valores por defecto (25%/25%), Kubernetes **no derriba las réplicas viejas hasta que las nuevas están `Ready`**. Como los Pods nuevos nunca llegan a `Ready` (`ImagePullBackOff`), las réplicas viejas siguen sirviendo tráfico. Es una red de seguridad de facto: un rollout roto degrada capacidad pero no tumba el servicio.
2. El historial vive en los **ReplicaSets** que el Deployment conserva: cada revisión es un ReplicaSet con su propia plantilla de Pod (`kubectl get rs` los muestra, muchos con 0 réplicas). `rollout undo` simplemente vuelve a escalar el ReplicaSet de la revisión anterior. Controlás cuántas revisiones se guardan con `spec.revisionHistoryLimit` (por defecto 10); poner 0 elimina el historial y con él la capacidad de `rollout undo`.
3. **Rollback primero** porque restaura servicio de forma rápida y determinista (volvés a un estado conocido-bueno), mientras que "fix-forward" implica escribir, testear y desplegar código nuevo bajo presión, con alto riesgo de empeorar el incidente. El rollback **no** es válido cuando el cambio es **irreversible o rompe compatibilidad hacia atrás**: p.ej. una migración de esquema de base de datos ya aplicada, o un cambio de formato de datos persistidos que la versión vieja no sabe leer. Ahí el fix-forward (o un rollback coordinado de datos + código con migraciones reversibles) es la única salida — de ahí la práctica de migraciones *backward-compatible* / *expand-contract*.

### Bloque 7 — Observabilidad

1. Golden signals: **Latency, Traffic, Errors, Saturation**. Mapeo: paso 3 (memoria vs. límite) = **Saturation**; paso 4 (ratio de 5xx) = **Errors**; paso 2 (reinicios) es un proxy de salud pero no una de las cuatro puras. La **no cubierta** es **Latency** (y en parte Traffic): la medirías con histogramas de duración de request, p.ej. `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))` para el p99, y el Traffic con `sum(rate(http_requests_total[5m]))`.
2. `kube_pod_container_status_restarts_total` es un **contador acumulativo monótono**; su valor crudo (p.ej. "37") no dice *cuándo* ocurrieron los reinicios. `increase()`/`rate()` calculan cuánto creció en la ventana, respondiendo "¿reinició en la última hora?". Además, `rate`/`increase` **detectan y corrigen los resets a 0** (cuando el Pod/exportador se reinicia el contador vuelve a cero); graficar el contador crudo mostraría una caída a cero y luego una rampa, dando lecturas engañosas. Por eso siempre se envuelven los contadores en `rate`/`increase`.
3. **Error budget** = `1 − SLO`. Con un SLO de disponibilidad del 99.9% el presupuesto es 0.1% de las requests (o del tiempo) en la ventana (p.ej. mensual). Una tasa sostenida de **3.7% de 5xx consume el presupuesto 37× más rápido** de lo permitido: agotás el 0.1% en una fracción minúscula de la ventana. Agotar el error budget dispara la decisión operativa de **congelar despliegues de features y volcar el esfuerzo a fiabilidad** hasta recuperar presupuesto — el mecanismo que alinea velocidad de entrega con estabilidad.

### Bloque 8 — Postmortem

1. *Blameless* significa que el análisis asume que las personas actuaron **razonablemente con la información que tenían** y se centra en **qué del sistema permitió el error** (falta de guardrails, señales ambiguas, procesos frágiles), no en quién lo cometió. Mejora el MTTR a largo plazo porque la gente **reporta incidentes y errores sin miedo**, aportando la información honesta y completa que permite arreglar las causas sistémicas; una cultura de culpa produce ocultamiento, datos incompletos y los mismos incidentes repetidos.
2. Los 5 porqués llegan al sistema porque cada "porqué" pregunta *qué lo permitió*, no *quién lo hizo*: el ingeniero pudo desplegar un tag inexistente **porque el pipeline no validó la existencia del artefacto** — ese es un defecto del sistema reproducible por cualquiera. Reescritura sistémica del último porqué: *"…porque el pipeline de CD no ejecuta `docker manifest inspect` (o equivalente) para verificar que la imagen existe en el registry antes de aplicar el manifiesto; añadir ese gate impide la clase entera de fallo, no solo esta instancia."*
3. **MTTD** = tiempo hasta *detectar* (calidad de la observabilidad/alertas). **MTTA** = tiempo hasta que alguien *reconoce/toma* la alerta (proceso de on-call/escalado). **MTTR** = tiempo hasta *recuperar* el servicio. Si MTTR es bueno pero MTTD es malo, invertís primero en **detección** (mejores alertas sobre golden signals, menor ruido, cobertura de síntomas como `ImagePullBackOff`): el impacto total ≈ MTTD + tiempo de respuesta + MTTR, y si el incidente tarda mucho en **detectarse**, los usuarios sufren todo ese tiempo aunque después lo resuelvas rápido. Reducir el eslabón más largo (aquí MTTD) es lo que más recorta el impacto acumulado.

</details>