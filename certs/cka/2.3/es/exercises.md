# CKA 2.3 — Monitor cluster and application resource usage

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Este tema cubre cómo observar el consumo de CPU y memoria a nivel de `Node` y de `Pod`, entender de dónde salen esos números (el pipeline de métricas), y usar esa información para diagnosticar problemas de scheduling, `OOMKilled` y presión de recursos en los nodos. Todos los comandos asumen que ya tenés un cluster funcionando y `kubectl` configurado contra él.

---

## Ejercicio 1 — El pipeline de métricas y `metrics-server`

`kubectl top` no lee métricas "mágicamente": depende de que exista el componente `metrics-server` corriendo en el cluster, que a su vez agrega datos que el `kubelet` recolecta de `cAdvisor` en cada nodo y los expone a través de la Metrics API (`metrics.k8s.io`).

1. Verificá si `metrics-server` ya está instalado:

   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```

2. Si no existe, instalalo (en clusters de práctica tipo kind/minikube suele necesitar el flag de TLS inseguro porque los certificados del kubelet no son válidos para el hostname interno):

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

3. Si los Pods de `metrics-server` quedan en estado `Running` pero `kubectl top` sigue fallando, revisá los logs y agregá el flag `--kubelet-insecure-tls` editando el Deployment:

   ```bash
   kubectl logs -n kube-system deployment/metrics-server
   kubectl edit deployment metrics-server -n kube-system
   # agregar en args del container: --kubelet-insecure-tls
   ```

4. Confirmá que la Metrics API está disponible como `APIService`:

   ```bash
   kubectl get apiservices | grep metrics
   ```

5. Esperá a que el Deployment esté listo y probá una primera consulta:

   ```bash
   kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
   kubectl top nodes
   ```

<details>
<summary>Preguntas de este bloque</summary>

**P1.** Si `metrics-server` no está instalado, ¿qué comandos del CKA dejan de funcionar y por qué?
**P2.** ¿Qué componente en cada nodo es la fuente original de los datos de uso de CPU/memoria que termina agregando `metrics-server`?
**P3.** ¿La Metrics API (`metrics.k8s.io`) almacena un historial de métricas o solo el valor más reciente?

</details>

---

## Ejercicio 2 — `kubectl top`: nodos, Pods y containers

1. Listá el consumo actual de todos los nodos, ordenado por CPU:

   ```bash
   kubectl top nodes --sort-by=cpu
   ```

2. Creá un namespace de trabajo y desplegá una carga de prueba con requests definidos:

   ```bash
   kubectl create namespace monitoring-demo

   kubectl run load-demo --image=nginx --namespace=monitoring-demo \
     --requests='cpu=50m,memory=64Mi' --limits='cpu=200m,memory=128Mi'
   ```

3. Listá el consumo de Pods en ese namespace, y luego desglosado por container:

   ```bash
   kubectl top pods -n monitoring-demo
   kubectl top pods -n monitoring-demo --containers
   ```

4. Listá el consumo de todos los Pods del cluster, sin filtrar por namespace, ordenado por memoria:

   ```bash
   kubectl top pods --all-namespaces --sort-by=memory
   ```

<details>
<summary>Preguntas de este bloque</summary>

**P4.** ¿Qué diferencia hay entre `kubectl top pods` y `kubectl top pods --containers` en un Pod multi-container?
**P5.** Un Pod nuevo tarda unos segundos en aparecer en `kubectl top pods`. ¿Por qué ocurre ese delay?
**P6.** ¿`kubectl top` te muestra el valor de `requests`/`limits` configurado, o solo el uso real medido?

</details>

---

## Ejercicio 3 — Capacity, Allocatable y requests a nivel de nodo

Cada nodo reporta tres números distintos relacionados a recursos: `Capacity` (todo el hardware físico), `Allocatable` (lo que Kubernetes puede repartir, descontando lo reservado para el SO y el propio kubelet) y la suma de `requests` de los Pods ya agendados.

1. Elegí un nodo cualquiera y mirá su sección de recursos:

   ```bash
   kubectl get nodes
   kubectl describe node <nombre-del-nodo>
   ```

2. Dentro del output, buscá específicamente las secciones `Capacity`, `Allocatable` y, más abajo, `Allocated resources`:

   ```bash
   kubectl describe node <nombre-del-nodo> | grep -A 5 "Capacity:"
   kubectl describe node <nombre-del-nodo> | grep -A 5 "Allocatable:"
   kubectl describe node <nombre-del-nodo> | grep -A 10 "Allocated resources"
   ```

3. Desplegá un Pod que pida más CPU de la que queda disponible en el nodo (ajustá el número según el tamaño real de tu nodo) para forzar un `Pending`:

   ```bash
   kubectl run oversized --image=nginx -n monitoring-demo \
     --requests='cpu=100' --limits='cpu=100'

   kubectl get pod oversized -n monitoring-demo
   kubectl describe pod oversized -n monitoring-demo | grep -A 5 Events
   ```

4. Limpiá el Pod de prueba:

   ```bash
   kubectl delete pod oversized -n monitoring-demo
   ```

<details>
<summary>Preguntas de este bloque</summary>

**P7.** ¿Por qué el `scheduler` mira la suma de `requests` de los Pods ya corriendo y no el uso real (`kubectl top`) al decidir si un nuevo Pod entra en un nodo?
**P8.** ¿Qué evento y mensaje esperás ver en `kubectl describe pod` cuando un Pod queda `Pending` por falta de CPU disponible?
**P9.** ¿Por qué `Allocatable` suele ser menor que `Capacity` en un nodo real (no en un cluster de laboratorio minimalista)?

</details>

---

## Ejercicio 4 — Diagnosticar un `OOMKilled` con métricas y eventos

Cuando un container excede su `memory limit`, el kernel lo mata (no hay "throttling" de memoria como sí existe para CPU). Kubernetes lo reporta como `OOMKilled`.

1. Creá un manifiesto para un Pod cuyo container consume más memoria de la que su `limit` permite:

   ```yaml
   # oom-demo.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: oom-demo
     namespace: monitoring-demo
   spec:
     containers:
     - name: hog
       image: polinux/stress
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
   ```

2. Aplicalo y observá su estado durante los siguientes segundos:

   ```bash
   kubectl apply -f oom-demo.yaml
   kubectl get pod oom-demo -n monitoring-demo -w
   ```

3. Una vez que reinicia, inspeccioná el estado anterior del container:

   ```bash
   kubectl describe pod oom-demo -n monitoring-demo | grep -A 10 "Last State"
   ```

4. Revisá los eventos del namespace ordenados por momento en que ocurrieron:

   ```bash
   kubectl get events -n monitoring-demo --sort-by='.lastTimestamp'
   ```

5. Confirmá el conteo de reinicios del container:

   ```bash
   kubectl get pod oom-demo -n monitoring-demo -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
   ```

6. Limpiá el recurso:

   ```bash
   kubectl delete -f oom-demo.yaml
   ```

<details>
<summary>Preguntas de este bloque</summary>

**P10.** ¿Qué `reason` exacto aparece en `Last State` cuando un container es matado por exceder su `memory limit`?
**P11.** Si en lugar de `memory limit` el container excediera su `cpu limit`, ¿el Pod sería terminado igual? ¿Por qué la respuesta es distinta a la de memoria?
**P12.** ¿Qué política de reinicio (`restartPolicy`) hace que este Pod vuelva a levantar después del `OOMKilled`, y qué pasaría con `restartPolicy: Never`?

</details>

---

## Ejercicio 5 — Node conditions y presión de recursos

Además del uso de CPU/memoria por Pod, el `kubelet` reporta condiciones de salud del propio nodo que afectan el scheduling y pueden disparar evicciones.

1. Mirá las `Conditions` reportadas por cada nodo:

   ```bash
   kubectl describe nodes | grep -A 15 "Conditions:"
   ```

2. Enfocá solo el estado resumido con una salida más compacta:

   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,MEMORY_PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,PID_PRESSURE:.status.conditions[?(@.type=="PIDPressure")].status'
   ```

3. Revisá si algún nodo tiene `Taints` relacionados a presión de recursos (Kubernetes los agrega automáticamente cuando una condición se activa):

   ```bash
   kubectl describe nodes | grep -A 3 "Taints:"
   ```

4. Consultá los eventos a nivel de cluster (no de un namespace) para ver si hubo evicciones recientes:

   ```bash
   kubectl get events --all-namespaces --field-selector reason=Evicted
   ```

<details>
<summary>Preguntas de este bloque</summary>

**P13.** ¿Qué taint agrega automáticamente Kubernetes a un nodo que entra en `MemoryPressure`, y qué efecto tiene sobre los Pods ya corriendo ahí?
**P14.** Si `kubectl get nodes` muestra `Ready` pero `describe node` muestra `MemoryPressure: True`, ¿el nodo sigue aceptando nuevos Pods sin `toleration`?
**P15.** ¿Qué diferencia hay entre un Pod terminado por `OOMKilled` (Ejercicio 4) y un Pod terminado por `Evicted` a nivel de nodo?

</details>

---

<details>
<summary><strong>Respuestas</strong></summary>

**P1.** `kubectl top nodes`, `kubectl top pods` y cualquier `HorizontalPodAutoscaler` basado en métricas de recursos (`cpu`/`memory`) dejan de funcionar, porque todos consultan la Metrics API (`metrics.k8s.io`), que es servida por `metrics-server`. Sin ese componente la API simplemente no existe registrada en el `APIService`, y los comandos devuelven error de conexión.

**P2.** `cAdvisor`, embebido dentro del `kubelet` de cada nodo. `cAdvisor` recolecta el uso real de CPU/memoria de cada container consultando cgroups, y el `kubelet` expone eso vía su Summary API; `metrics-server` hace scraping periódico de esa API en todos los nodos y lo agrega.

**P3.** Solo el valor más reciente (in-memory, sin persistencia). `metrics-server` no es una solución de monitoreo histórico: para series temporales hace falta algo como Prometheus, que sí almacena y permite graficar tendencias en el tiempo.

**P4.** `kubectl top pods` suma el uso de todos los containers del Pod y muestra un solo número por Pod. `kubectl top pods --containers` desglosa el uso individual de cada container, útil en Pods con sidecars donde un container puede estar consumiendo mucho más que otro.

**P5.** `metrics-server` hace polling periódico (por defecto cada 15 segundos aprox.) contra los kubelets, no recibe push en tiempo real. Un Pod recién creado no tiene todavía una muestra recolectada hasta el próximo ciclo de scraping.

**P6.** Solo el uso real medido en el momento de la consulta. Para ver `requests`/`limits` configurados hay que usar `kubectl describe pod` o `kubectl get pod -o yaml`, no `kubectl top`.

**P7.** Porque el scheduler decide antes de que el Pod arranque, cuando todavía no hay ningún uso real que medir. Además, basarse en uso real permitiría sobrecomprometer un nodo (varios Pods con uso bajo en un momento dado, pero que en conjunto podrían picar todos a la vez y quedarse sin recursos); `requests` es la garantía mínima que Kubernetes reserva por contrato.

**P8.** Un evento con `reason: FailedScheduling` y un mensaje del tipo "0/N nodes are available: N Insufficient cpu", generado por el scheduler al no encontrar ningún nodo cuya CPU disponible (`Allocatable` menos `requests` ya comprometidos) alcance para el nuevo Pod.

**P9.** Porque `Allocatable` descuenta explícitamente lo reservado para el sistema operativo (`system-reserved`), el propio `kubelet` y el runtime de containers (`kube-reserved`), y el umbral de eviction (`eviction-hard`). En un cluster de laboratorio esos flags suelen no estar configurados, por lo que ambos valores coinciden.

**P10.** `OOMKilled`, visible en el campo `reason` dentro de `lastState.terminated` (o en la sección `Last State` del output de `kubectl describe pod`), junto con `exitCode: 137` (128 + señal 9/SIGKILL).

**P11.** No, el Pod no se termina. La CPU es un recurso "compresible": si un container excede su `cpu limit`, el kernel simplemente le aplica *throttling* (le reduce el tiempo de CPU asignado vía CFS quotas) sin matar el proceso. La memoria es "incompresible": no se le puede "quitar" memoria a un proceso en ejecución, así que la única opción del kernel es matarlo.

**P12.** `restartPolicy: Always` (o `OnFailure`, que también cubre este caso) hace que el kubelet vuelva a levantar el container localmente en el mismo Pod tras el `OOMKilled`, incrementando `restartCount`. Con `restartPolicy: Never`, el container quedaría en estado `Terminated` con `reason: OOMKilled` sin reintentos, y el Pod pasaría a fase `Failed`.

**P13.** El taint `node.kubernetes.io/memory-pressure:NoSchedule`. No expulsa automáticamente los Pods que ya están corriendo en el nodo, pero impide que se agenden Pods nuevos ahí (salvo que tengan una `toleration` explícita para ese taint), y puede eventualmente derivar en evicciones si la presión de memoria se vuelve crítica.

**P14.** Sí puede seguir marcado `Ready` mientras tiene `MemoryPressure: True` — son señales independientes. Pero como el taint `NoSchedule` se aplica automáticamente ante esa condición, en la práctica no acepta Pods nuevos sin `toleration`, aunque su estado general siga siendo `Ready`.

**P15.** `OOMKilled` es una acción del kernel sobre un container puntual que excedió su propio `memory limit` (cgroup), y el Pod normalmente se reinicia localmente en el mismo nodo. `Evicted` es una decisión del `kubelet` a nivel de todo el nodo cuando los recursos globales del nodo (no de un container individual) caen por debajo de los `eviction thresholds`; ahí el kubelet elige qué Pods sacrificar (según prioridad y exceso sobre `requests`) y esos Pods no se reprograman automáticamente en el mismo nodo — si tienen un controlador (Deployment, etc.) el scheduler los vuelve a ubicar, potencialmente en otro nodo.

</details>