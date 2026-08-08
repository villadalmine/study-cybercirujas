# Ejercicios guiados — Tema 4.3: Denial of Service (KCSA)

> **Objetivo:** reproducir de forma controlada las clases de Denial of Service (DoS) que aparecen en el *Kubernetes Threat Model* del KCSA —agotamiento de recursos de cómputo, de PIDs, de almacenamiento efímero y del control plane— y aplicar los controles nativos que los contienen: `requests`/`limits`, `LimitRange`, `ResourceQuota`, `PodPidsLimit`, node-pressure eviction y API Priority and Fairness (APF).
>
> **Modelo de amenaza (contexto KCSA):** un DoS en Kubernetes rara vez es un flood externo clásico. El vector dominante es *interno y multi-tenant*: un workload —comprometido, malicioso o simplemente mal configurado— consume recursos compartidos hasta degradar a los vecinos (*noisy neighbor*) o al propio nodo/API server. El principio de defensa es siempre el mismo: **todo recurso compartido debe tener un límite explícito y un mecanismo de reclamo (eviction / rechazo).**

## Entorno de laboratorio

Necesitás un cluster donde puedas ver nodos y, en algunos pasos, tocar la config del kubelet. Un `kind` o `minikube` de un solo nodo alcanza. Los outputs son ilustrativos: los valores exactos varían según tu runtime y versión.

```bash
kubectl version --output=json | grep -E 'gitVersion' | head -2
kubectl create namespace dos-lab
kubectl config set-context --current --namespace=dos-lab
```

Fuente del temario: KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

---

## Ejercicio 1 — Reproducir un DoS por resource exhaustion (memoria)

Un contenedor **sin `limits`** puede reclamar toda la memoria del nodo. Vamos a verlo y luego a contenerlo.

1. Creá un Pod que consume 900 MB de RAM y **no declara límites**:

   ```yaml
   # memory-hog.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
     namespace: dos-lab
   spec:
     containers:
     - name: stress
       image: polinux/stress:1.0.4
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "900M", "--vm-hang", "0"]
   ```

   ```bash
   kubectl apply -f memory-hog.yaml
   ```

2. Observá cómo escala su consumo (necesitás metrics-server; si no lo tenés, mirá `kubectl describe node`):

   ```bash
   kubectl top pod memory-hog
   # NAME         CPU(cores)   MEMORY(bytes)
   # memory-hog   2m           902Mi
   ```

3. Comprobá que el Pod **no fue frenado por Kubernetes**: sin `limits`, el único que puede matarlo es el OOM killer del kernel del nodo cuando el nodo entra en memory pressure, afectando potencialmente a *otros* Pods.

   ```bash
   kubectl get pod memory-hog -o jsonpath='{.spec.containers[0].resources}'
   # {}     <-- vacío: ni requests ni limits
   ```

4. Limpiá:

   ```bash
   kubectl delete pod memory-hog
   ```

> **Preguntas de comprobación**
> 1. Sin `requests` ni `limits`, ¿en qué **QoS class** cae este Pod y por qué eso lo hace el *primer* candidato a ser desalojado bajo memory pressure?
> 2. ¿Cuál es la diferencia práctica entre que a un Pod lo mate el **OOM killer del kernel** y que Kubernetes lo desaloje por **node-pressure eviction**? ¿Cuál de los dos respeta la QoS class?
> 3. ¿Por qué un límite de memoria protege *al vecino* pero un pico de CPU sin límite es, en general, menos peligroso para la estabilidad del nodo?

---

## Ejercicio 2 — Contención con `requests` y `limits`

1. Volvé a lanzar el mismo stress, ahora **acotado** a 256Mi, pero pidiéndole que use 300M (por encima del límite):

   ```yaml
   # memory-hog-limited.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog-limited
     namespace: dos-lab
   spec:
     containers:
     - name: stress
       image: polinux/stress:1.0.4
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "300M", "--vm-hang", "0"]
       resources:
         requests:
           cpu: "100m"
           memory: "128Mi"
         limits:
           cpu: "250m"
           memory: "256Mi"
   ```

   ```bash
   kubectl apply -f memory-hog-limited.yaml
   ```

2. Observá el resultado: el contenedor supera su `memory limit` y es terminado por OOM **dentro de su propio cgroup**, sin tocar al resto del nodo:

   ```bash
   kubectl get pod memory-hog-limited
   # NAME                 READY   STATUS      RESTARTS      AGE
   # memory-hog-limited   0/1     OOMKilled   2 (10s ago)   35s

   kubectl describe pod memory-hog-limited | grep -A3 'Last State'
   #     Last State:     Terminated
   #       Reason:       OOMKilled
   #       Exit Code:    137
   ```

3. Reducí el consumo a 200M (por debajo del límite) y confirmá que ahora es estable:

   ```bash
   kubectl delete pod memory-hog-limited
   sed 's/300M/200M/' memory-hog-limited.yaml | kubectl apply -f -
   kubectl get pod memory-hog-limited
   # NAME                 READY   STATUS    RESTARTS   AGE
   # memory-hog-limited   1/1     Running   0          20s
   ```

4. Limpiá: `kubectl delete pod memory-hog-limited`.

> **Preguntas de comprobación**
> 1. El contenedor fue `OOMKilled` con **Exit Code 137**. ¿De dónde sale 137 y qué señal representa?
> 2. Si en vez de exceder el **memory limit** el contenedor excediera el **CPU limit**, ¿lo matarían igual? Describí qué le pasa a un contenedor que topa su límite de CPU.
> 3. Este Pod tiene `requests` y `limits` iguales solo en memoria pero distintos en CPU. ¿Qué **QoS class** le asigna Kubernetes? ¿Qué haría falta para que fuera `Guaranteed`?

---

## Ejercicio 3 — `LimitRange`: imponer defaults y techos por namespace

El Ejercicio 1 mostró el problema real: un Pod puede *omitir* los límites. `LimitRange` fuerza defaults y prohíbe valores fuera de rango en todo el namespace.

1. Aplicá una `LimitRange`:

   ```yaml
   # limitrange.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: mem-cpu-defaults
     namespace: dos-lab
   spec:
     limits:
     - type: Container
       default:                 # se aplica como 'limits' si el Pod no los pone
         cpu: "500m"
         memory: "256Mi"
       defaultRequest:          # se aplica como 'requests' si el Pod no los pone
         cpu: "100m"
         memory: "128Mi"
       max:                     # techo: rechaza Pods que pidan más
         cpu: "1"
         memory: "512Mi"
       min:
         cpu: "50m"
         memory: "64Mi"
       maxLimitRequestRatio:    # limit no puede ser >4x el request (evita overcommit abusivo)
         cpu: "4"
   ```

   ```bash
   kubectl apply -f limitrange.yaml
   ```

2. Lanzá un Pod **sin recursos** y comprobá que se le **inyectan los defaults**:

   ```bash
   kubectl run defaulted --image=busybox:1.36 --restart=Never -- sleep 3600
   kubectl get pod defaulted -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
   # {
   #     "limits":   { "cpu": "500m", "memory": "256Mi" },
   #     "requests": { "cpu": "100m", "memory": "128Mi" }
   # }
   ```

3. Intentá violar el techo `max`:

   ```bash
   kubectl run toobig --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"toobig","image":"busybox:1.36","resources":{"limits":{"memory":"1Gi"}}}]}}' \
     -- sleep 3600
   # Error from server (Forbidden): pods "toobig" is forbidden:
   #   maximum memory usage per Container is 512Mi, but limit is 1Gi
   ```

4. Limpiá: `kubectl delete pod defaulted --ignore-not-found`.

> **Preguntas de comprobación**
> 1. ¿En qué **etapa del ciclo de admisión** actúa `LimitRange` —antes o después de persistir el objeto— y por qué eso importa para su rol como control de DoS?
> 2. Un `LimitRange` con `default` pero **sin** `defaultRequest`: ¿qué valor toma el `request` de un contenedor que no lo declara? (Pista: hay una regla de derivación.)
> 3. ¿Para qué sirve `maxLimitRequestRatio` frente a un atacante que intenta *reservar poco y consumir mucho*?

---

## Ejercicio 4 — `ResourceQuota`: un techo agregado para el namespace

`LimitRange` acota *cada* contenedor; nada impide crear **miles** de Pods pequeños. `ResourceQuota` pone un tope al **total** del namespace y también al **número de objetos** (que es otro vector de DoS: agotar etcd/API con objetos).

1. Aplicá la quota:

   ```yaml
   # resourcequota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: dos-lab-quota
     namespace: dos-lab
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
       count/configmaps: "20"
       count/services.loadbalancers: "1"
   ```

   ```bash
   kubectl apply -f resourcequota.yaml
   kubectl describe resourcequota dos-lab-quota
   # Name:            dos-lab-quota
   # Resource         Used  Hard
   # --------         ----  ----
   # limits.cpu       0     4
   # limits.memory    0     4Gi
   # pods             0     10
   # requests.cpu     0     2
   # requests.memory  0     2Gi
   ```

2. Saturá el conteo de Pods para ver el rechazo:

   ```bash
   for i in $(seq 1 11); do
     kubectl run q$i --image=busybox:1.36 --restart=Never -- sleep 3600
   done
   # ...
   # Error from server (Forbidden): pods "q11" is forbidden:
   #   exceeded quota: dos-lab-quota, requested: pods=1, used: pods=10, limited: pods=10
   ```

3. Probá que la quota de cómputo también rechaza aunque falte solo memoria, y que **exige** que los Pods declaren recursos (por eso `LimitRange` y `ResourceQuota` se usan juntos):

   ```bash
   kubectl describe resourcequota dos-lab-quota | sed -n '3,10p'
   ```

4. Limpiá:

   ```bash
   kubectl delete pod -l run --all --ignore-not-found
   for i in $(seq 1 10); do kubectl delete pod q$i --ignore-not-found; done
   ```

> **Preguntas de comprobación**
> 1. Con una `ResourceQuota` que limita `requests.cpu`/`requests.memory` activa en el namespace, ¿qué pasa si intentás crear un Pod **sin** `requests`? ¿Por qué esto hace que `LimitRange` sea prácticamente obligatorio como compañero?
> 2. `count/services.loadbalancers: "1"` frena un vector de DoS específico. ¿Cuál, y por qué apunta al **costo económico** además del técnico?
> 3. ¿Por qué limitar `count/configmaps` (o secrets) es una defensa de DoS contra **etcd/API server** y no solo contra el cómputo del nodo?

---

## Ejercicio 5 — PID exhaustion (fork bomb) y `PodPidsLimit`

Los PIDs son un recurso finito y **compartido a nivel de nodo**. Un fork bomb agota la tabla de procesos y ningún proceso nuevo —ni siquiera del kubelet o de otros Pods— puede arrancar.

1. Lanzá un Pod que spawnea procesos sin freno y **sin** límite de PIDs:

   ```yaml
   # fork-bomb.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: fork-bomb
     namespace: dos-lab
   spec:
     containers:
     - name: bomb
       image: busybox:1.36
       command: ["sh", "-c", "n=0; while true; do sleep 3600 & n=$((n+1)); done"]
   ```

   ```bash
   kubectl apply -f fork-bomb.yaml
   ```

2. Contá los procesos dentro del contenedor (crecen sin tope):

   ```bash
   kubectl exec fork-bomb -- sh -c 'ps | wc -l'
   # 1043
   ```

3. Detené la bomba (`kubectl delete pod fork-bomb --grace-period=0 --force`) y aplicá el control. El límite por Pod se configura **en el kubelet del nodo**, no en el manifiesto del Pod:

   ```yaml
   # /var/lib/kubelet/config.yaml (fragmento) — requiere reiniciar el kubelet
   apiVersion: kubelet.config.k8s.io/v1beta1
   kind: KubeletConfiguration
   podPidsLimit: 100          # techo de PIDs por Pod
   evictionHard:
     pid.available: "1000"    # reserva de PIDs del nodo: si baja de esto, hay eviction
   ```

4. Con `podPidsLimit: 100`, relanzá el fork bomb y observá que `fork` falla **dentro** del Pod, sin arrastrar al nodo:

   ```bash
   kubectl apply -f fork-bomb.yaml
   kubectl logs fork-bomb | tail -1
   # sh: can't fork: Resource temporarily unavailable
   ```

5. Limpiá: `kubectl delete pod fork-bomb --ignore-not-found`.

> **Preguntas de comprobación**
> 1. ¿Por qué `podPidsLimit` **no** se declara en `spec.containers[].resources` como memoria/CPU, sino en la config del kubelet? ¿Qué implica eso para un cluster multi-tenant que no controlás a nivel de nodo?
> 2. Diferenciá `podPidsLimit` de la señal de eviction `pid.available`. ¿Cuál protege al *nodo entero* y cuál al *aislamiento entre Pods*?
> 3. ¿Por qué un límite de memoria **no** habría contenido este ataque, aunque el fork bomb también consume RAM?

---

## Ejercicio 6 — Ephemeral storage exhaustion y node-pressure eviction

Llenar el disco del nodo (`/var/lib/kubelet`, logs, capa de escritura del contenedor, `emptyDir`) es DoS: el kubelet entra en disk pressure y empieza a desalojar Pods.

1. Creá un Pod que escribe a un `emptyDir` con un **límite de `ephemeral-storage`** de 512Mi, pero intenta escribir 2 GB:

   ```yaml
   # disk-hog.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: disk-hog
     namespace: dos-lab
   spec:
     containers:
     - name: filler
       image: busybox:1.36
       command: ["sh", "-c", "dd if=/dev/zero of=/data/fill bs=1M count=2000; sleep 3600"]
       resources:
         requests:
           ephemeral-storage: "256Mi"
         limits:
           ephemeral-storage: "512Mi"
       volumeMounts:
       - name: scratch
         mountPath: /data
     volumes:
     - name: scratch
       emptyDir: {}
   ```

   ```bash
   kubectl apply -f disk-hog.yaml
   ```

2. Observá que el kubelet **desaloja** el Pod al superar su límite de almacenamiento efímero (el uso de `emptyDir` no-memoria cuenta contra ese límite):

   ```bash
   kubectl get pod disk-hog -w
   # NAME       READY   STATUS    RESTARTS   AGE
   # disk-hog   1/1     Running   0          8s
   # disk-hog   0/1     Evicted   0          14s

   kubectl describe pod disk-hog | grep -A2 -i 'reason\|message'
   # Status:   Failed
   # Reason:   Evicted
   # Message:  Pod ephemeral local storage usage exceeds the total limit of containers 512Mi.
   ```

3. Relacioná esto con el mecanismo de nodo. Las señales de eviction relevantes al almacenamiento son `nodefs.available` y `imagefs.available`; cuando cruzan sus umbrales, el kubelet desaloja Pods por orden de QoS y de uso relativo:

   ```bash
   kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="DiskPressure")].status}'
   # False   (True si el nodo estuviera bajo presión de disco)
   ```

4. Limpiá: `kubectl delete pod disk-hog --ignore-not-found`.

> **Preguntas de comprobación**
> 1. El Pod fue `Evicted`, no `OOMKilled`. ¿Por qué el almacenamiento efímero usa **eviction** (kubelet) y no un OOM-kill del kernel como la memoria?
> 2. ¿Qué tres fuentes de escritura suma el kubelet para contabilizar `ephemeral-storage` de un contenedor/Pod?
> 3. Bajo `DiskPressure`, entre un Pod `Guaranteed` que respeta su límite y uno `BestEffort` que escribe mucho, ¿a cuál desaloja primero el kubelet y según qué criterio?

---

## Ejercicio 7 — Proteger el control plane: API Priority and Fairness (APF)

El API server es un recurso compartido crítico. Un cliente que lo inunda de requests (list de todos los Pods en loop, watch masivos) puede degradar a todos. APF clasifica las requests en *flows* y les asigna concurrencia por `PriorityLevelConfiguration`, aislando el tráfico crítico del abusivo.

1. Inspeccioná los objetos APF incorporados:

   ```bash
   kubectl get prioritylevelconfigurations
   # NAME              TYPE      NOMINALCONCURRENCYSHARES   QUEUES   ...
   # catch-all         Limited   5                         <none>
   # exempt            Exempt    <none>                     <none>
   # global-default    Limited   20                         128
   # leader-election   Limited   10                         16
   # node-high         Limited   40                         64
   # system            Limited   30                         64
   # workload-high     Limited   40                         128
   # workload-low      Limited   100                        128

   kubectl get flowschemas
   # NAME                          PRIORITYLEVEL     MATCHINGPRECEDENCE   ...
   # exempt                        exempt            1
   # system-leader-election        leader-election   100
   # kube-controller-manager       workload-high     800
   # service-accounts              workload-low      9000
   # catch-all                     catch-all         10000
   ```

2. Mirá las cabeceras que el API server añade a cada respuesta, indicando en qué flow cayó tu request:

   ```bash
   kubectl get --raw='/api/v1/namespaces/dos-lab/pods?limit=1' -v=8 2>&1 \
     | grep -i 'X-Kubernetes-PF'
   # X-Kubernetes-PF-FlowSchema-UID: 6f0f...   (qué FlowSchema matcheó)
   # X-Kubernetes-PF-PriorityLevel-UID: 3a2b... (qué PriorityLevel lo atendió)
   ```

3. Volcá el estado de concurrencia en vivo (útil para diagnosticar un DoS en curso: mirás qué priority level está encolando o rechazando):

   ```bash
   kubectl get --raw '/debug/api_priority_and_fairness/dump_priority_levels'
   # PriorityLevelName   ...   IsQuiescing   NominalCL   ExecutingRequests   WaitingRequests
   # workload-low        ...   false         100         0                   0
   # ...
   ```

4. Observá el comportamiento defensivo: cuando la concurrencia de un priority level se satura y su cola se llena, las requests **excedentes reciben HTTP 429 (Too Many Requests)** con `Retry-After`, en lugar de tumbar el API server. El tráfico de otros flows sigue fluyendo.

> **Preguntas de comprobación**
> 1. ¿En qué se diferencia la protección de APF (**fairness/aislamiento entre flows**) de los flags `--max-requests-inflight` / `--max-mutating-requests-inflight` (**tope global**)? ¿Por qué un tope global solo no evita el *starvation* de un tenant sobre otro?
> 2. Un `PriorityLevelConfiguration` de tipo `Exempt` no encola ni limita. ¿Qué tráfico *debe* ir ahí y por qué ponerlo bajo límite sería en sí mismo un riesgo de DoS del cluster?
> 3. ¿Por qué un **429 con `Retry-After`** es un resultado *deseable* frente a un flood, comparado con un `500`/timeout o con el API server cayéndose?
> 4. ¿Qué otro componente del control plane tiene su propio tope anti-DoS por tamaño de base de datos (`--quota-backend-bytes`, por defecto ~2 GiB) que, al superarse, pone al cluster en modo **solo lectura** con una alarma `NOSPACE`?

---

## Respuestas

<details>
<summary>Mostrar respuestas</summary>

### Ejercicio 1
1. Sin `requests` ni `limits` el Pod es **`BestEffort`**. Es el primer candidato a eviction porque no reservó nada: el scheduler no le garantizó recursos y el kubelet, bajo memory pressure, desaloja primero `BestEffort`, luego `Burstable` que exceden su request, y por último `Guaranteed`. No haber pedido recursos = ninguna prioridad de retención.
2. El **OOM killer del kernel** actúa a nivel de cgroup/nodo cuando la memoria física se agota; elige víctimas por un `oom_score` heurístico y **no conoce la QoS class de Kubernetes** (aunque Kubernetes ajusta el `oom_score_adj` para sesgarlo hacia BestEffort). La **node-pressure eviction** la ejecuta el *kubelet*, es ordenada, respeta QoS class y da grace period; actúa *antes* de que el kernel tenga que matar. Solo la eviction del kubelet respeta la QoS class de forma explícita.
3. La memoria es **incompresible**: no se puede "prestar de a poco"; cuando falta, algo muere, y el daño se propaga a vecinos en el mismo nodo. La CPU es **compresible**: un exceso solo produce *throttling* (el proceso corre más lento), degradando al ofensor sin matar a nadie. Por eso el límite de memoria es la defensa de estabilidad más importante.

### Ejercicio 2
1. **137 = 128 + 9**. Es la convención de exit code para "terminado por señal *N*": 128 + `SIGKILL(9)`. El OOM killer envía SIGKILL, de ahí 137. (De la misma forma, 143 = 128 + `SIGTERM(15)`.)
2. **No lo matan.** El CPU es compresible: al topar su `cpu limit` el contenedor sufre **CFS throttling** —se le retienen ciclos y corre más lento— pero sigue vivo. Solo el exceso de **memoria** dispara OOM-kill.
3. Es **`Burstable`**: tiene requests/limits pero memoria y CPU no son todos iguales (además CPU request ≠ CPU limit). Para ser **`Guaranteed`** cada contenedor debe tener `requests == limits` en **CPU y memoria** simultáneamente.

### Ejercicio 3
1. Actúa como **admission controller** (mutating + validating), es decir **antes de persistir** el objeto en etcd. Importa porque rechaza o corrige la spec en el momento de la creación: un Pod que violaría el techo nunca llega a existir ni a consumir recursos, que es exactamente lo que se quiere de un control preventivo de DoS.
2. Si hay `default` (para `limits`) pero no `defaultRequest`, el `request` **se iguala al `default`** (al valor del limit). Regla de derivación de la `LimitRange`: en ausencia de `defaultRequest`, request = default(limit).
3. `maxLimitRequestRatio` acota cuánto puede exceder el `limit` al `request`. Un atacante que reserva poco (`request` bajo, para colar muchos Pods bajo la `ResourceQuota` de requests) pero pone un `limit` enorme genera **overcommit peligroso**: el nodo promete más de lo reservado y colapsa bajo carga. El ratio máximo impide ese engaño.

### Ejercicio 4
1. La creación es **rechazada**: cuando una `ResourceQuota` limita un recurso de cómputo (`requests.cpu`, etc.), **todo Pod del namespace debe declarar ese recurso**. Sin `LimitRange` que inyecte defaults, cada `kubectl run` sin recursos fallaría; por eso ambos se despliegan juntos —`LimitRange` garantiza que los Pods tengan valores, `ResourceQuota` acota la suma.
2. Frena la creación descontrolada de **Services de tipo LoadBalancer**. Cada uno aprovisiona un balanceador en el cloud provider: crear cientos es un DoS técnico (agota IPs/quota del proveedor) **y** económico (cada LB factura por hora). Es el ejemplo canónico de DoS que ataca la *factura*, no solo el cluster.
3. Cada objeto (ConfigMap, Secret, etc.) se persiste en **etcd** y se sirve por el **API server**. Crear millones agota el espacio de etcd (que tiene su propia quota, ver Ej. 7) y satura la memoria/latencia del API server con listas y watches. Limitar el *conteo* de objetos protege al control plane, un plano de ataque distinto del cómputo del nodo.

### Ejercicio 5
1. El límite de PIDs es una propiedad del **nodo** (la tabla de PIDs es un recurso del kernel del host), y su asignación por Pod la administra el kubelet, no el scheduler; por eso vive en `KubeletConfiguration` (`podPidsLimit`) y no en la spec del Pod. Implicación: en un cluster gestionado/multi-tenant donde no controlás el kubelet, **no podés fijar este límite tú mismo**; dependés de que el operador del nodo lo haya configurado (y podés complementar con políticas de admisión que restrinjan cargas peligrosas).
2. `podPidsLimit` acota los PIDs de **cada Pod** → provee **aislamiento entre Pods** (un fork bomb no roba PIDs a su vecino). `pid.available` es una **señal de node-pressure eviction**: reserva una cantidad de PIDs para el nodo y, si el disponible baja del umbral, el kubelet **desaloja Pods** para proteger al **nodo entero** (kubelet, runtime, etc.). Uno aísla; el otro salva el nodo.
3. Un fork bomb agota **PIDs**, un recurso independiente de la memoria. Miles de procesos `sleep` consumen muy poca RAM cada uno, así que el límite de memoria podría no dispararse mientras la tabla de procesos ya está llena y ningún `fork()` nuevo funciona. Cada tipo de recurso finito necesita su propio control.

### Ejercicio 6
1. El disco es **incompresible pero recuperable de forma ordenada**: no hay un mecanismo del kernel análogo al OOM killer que libere disco matando un proceso, así que es el **kubelet** quien monitorea el uso y **desaloja** Pods (liberando sus `emptyDir`/capa de escritura) para recuperar espacio. Es una decisión de scheduling/QoS, no una reacción del kernel.
2. (a) La **capa de escritura del contenedor** (writable layer del rootfs), (b) los **logs del contenedor** que escribe el runtime, y (c) los volúmenes **`emptyDir`** de tipo no-memoria. La suma de las tres se contabiliza contra `ephemeral-storage`.
3. Desaloja primero al **`BestEffort`** (o al `Burstable` que excede su request de storage). Bajo `DiskPressure` el kubelet ordena las víctimas por QoS class y, dentro de la misma clase, por cuánto exceden su request; un `Guaranteed` que respeta su límite es el último en caer. El que "escribe mucho" y no reservó es el primero.

### Ejercicio 7
1. `--max-requests-inflight`/`--max-mutating-requests-inflight` son un **tope global único**: una vez alcanzado, *cualquier* request se rechaza por igual, así que un cliente abusivo que llena el cupo puede dejar sin servicio al `kube-scheduler` o a un leader-election crítico (*starvation*). APF divide la concurrencia en **priority levels** con `FlowSchemas` que aíslan por identidad/tipo de request: el tráfico crítico tiene su propio cupo garantizado y el abusivo se ahoga en su propio flow sin robarle capacidad al resto. Fairness ≠ tope global.
2. Debe ir el tráfico que **no puede encolarse ni descartarse nunca sin romper el cluster**: típicamente requests de componentes del sistema como el propio `system:masters`/healthchecks del control plane y leader-election crítico. Ponerlos bajo límite/cola sería un DoS autoinfligido: si se encolan o reciben 429, los componentes que sostienen el cluster fallarían.
3. Un **429 con `Retry-After`** es una señal **explícita y accionable**: el cliente sabe que fue limitado y *cuándo reintentar* (los clientes de Kubernetes hacen backoff automático), y el API server sigue **vivo y sirviendo a los demás**. Un `500`/timeout o una caída del API server es indistinguible de un fallo real, no da guía de reintento y afecta a *todos* los clientes: es precisamente el resultado que APF existe para evitar.
4. **etcd**. Su flag `--quota-backend-bytes` (por defecto ~2 GiB, recomendado no superar ~8 GiB) topa el tamaño de la base de datos; al excederlo, etcd levanta la alarma `NOSPACE` y pone el cluster en **modo solo lectura** hasta compactar/desfragmentar y limpiar la alarma. Es el control anti-DoS del almacenamiento del control plane, complementario al límite de *conteo de objetos* de la `ResourceQuota` del Ejercicio 4.

</details>

---

### Fuentes oficiales

- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Managing Resources for Containers (`requests`/`limits`, QoS): https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Process ID Limits and Reservations (`podPidsLimit`, `pid.available`): https://kubernetes.io/docs/concepts/policy/pid-limiting/
- Node-pressure Eviction (memoria, disco, PIDs): https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Local Ephemeral Storage: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage
- API Priority and Fairness: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Operating etcd for Kubernetes (`--quota-backend-bytes`, alarma `NOSPACE`): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/