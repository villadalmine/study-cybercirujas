# Ejercicios Guiados — Tema 1.3: Optimizing Multi-Tenancy Resource Usage (CNPE)

> **Objetivo del laboratorio.** Vas a construir, de forma incremental, los controles que hacen que varios *tenants* compartan un cluster sin pisarse: cuotas duras por namespace, defaults e invariantes de recursos, clases de QoS, prioridad/preemption entre tiers, *bin-packing* del scheduler, y visibilidad de costo (*showback*). Cada bloque termina con preguntas de comprobación. Las respuestas están al final, colapsadas.
>
> **Prerrequisitos.** Un cluster con permisos de `cluster-admin` (kind, minikube, k3s o un cluster de laboratorio). Verificá antes de empezar:
>
> ```bash
> kubectl version --output=yaml | grep -A2 serverVersion
> kubectl get nodes -o wide
> kubectl top nodes   # requiere metrics-server; instalalo si falla
> ```
>
> Trabajaremos con dos tenants ficticios: **`team-a`** (tier *premium*, cargas productivas) y **`team-b`** (tier *standard*, cargas batch). Todo lo que sigue es reproducible; no hay pasos que dependan de estado previo no declarado.

---

## Ejercicio 1 — ResourceQuota: el límite duro por tenant

El primer control de multi-tenancy es evitar que un tenant consuma todo el cluster. Un `ResourceQuota` fija techos **agregados** por namespace sobre `requests`, `limits` y conteo de objetos.

**Pasos:**

1. Creá los namespaces de los dos tenants y etiquetalos:

   ```bash
   kubectl create namespace team-a
   kubectl create namespace team-b
   kubectl label namespace team-a tenant=team-a tier=premium
   kubectl label namespace team-b tenant=team-b tier=standard
   ```

2. Aplicá una `ResourceQuota` a `team-b` que limite CPU/memoria agregados y también el número de objetos:

   ```yaml
   # quota-team-b.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-quota
     namespace: team-b
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 4Gi
       limits.cpu: "4"
       limits.memory: 8Gi
       pods: "10"
       count/deployments.apps: "5"
       count/services: "5"
       persistentvolumeclaims: "4"
   ```

   ```bash
   kubectl apply -f quota-team-b.yaml
   ```

3. Inspeccioná el estado actual (used vs hard):

   ```bash
   kubectl describe resourcequota tenant-quota -n team-b
   ```

   Salida esperada (todo en cero al inicio):

   ```
   Name:                   tenant-quota
   Namespace:              team-b
   Resource                Used  Hard
   --------                ----  ----
   count/deployments.apps  0     5
   count/services          0     5
   limits.cpu              0     4
   limits.memory           0     8Gi
   persistentvolumeclaims  0     4
   pods                    0     10
   requests.cpu            0     2
   requests.memory         0     4Gi
   ```

4. Desplegá una carga que **cabe** dentro de la cuota:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=2 -n team-b
   kubectl set resources deployment web -n team-b \
     --requests=cpu=250m,memory=256Mi --limits=cpu=500m,memory=512Mi
   kubectl rollout status deployment/web -n team-b
   ```

5. Ahora intentá escalar **por encima** de la cuota de CPU y observá el rechazo:

   ```bash
   kubectl scale deployment web --replicas=10 -n team-b
   kubectl get deployment web -n team-b
   kubectl describe replicaset -n team-b -l app=web | grep -A5 -i "quota\|failed"
   ```

   Salida esperada (el Deployment queda con réplicas insatisfechas):

   ```
   Warning  FailedCreate  ... Error creating: pods "web-xxxx" is forbidden:
   exceeded quota: tenant-quota, requested: requests.cpu=250m,
   used: requests.cpu=2, limited: requests.cpu=2
   ```

**Preguntas de comprobación (bloque 1):**

- **1.1** ¿Por qué el error aparece en el `ReplicaSet` (evento `FailedCreate`) y no directamente en el comando `kubectl scale`? ¿Qué te dice eso sobre *dónde* se aplica la cuota en el flujo de admisión?
- **1.2** Con `limits.cpu: "4"` y `requests.cpu: "2"`, ¿qué *overcommit ratio* de CPU estás autorizando para este tenant y qué riesgo introduce?
- **1.3** Aplicaste una cuota que incluye `requests.memory`. A partir de ese momento, ¿qué pasa si un Pod del namespace `team-b` se crea **sin** especificar `requests.memory`? (Pensá en la interacción con el `LimitRange` del ejercicio siguiente.)

---

## Ejercicio 2 — LimitRange: defaults, mínimos y la razón limit/request

Un `ResourceQuota` sobre `requests.*` **exige** que todo Pod declare requests; si no lo hace, el Pod es rechazado. El `LimitRange` resuelve eso inyectando defaults, y de paso acota el tamaño individual de contenedores y la relación entre `limit` y `request` (control directo del *noisy neighbor*).

**Pasos:**

1. Aplicá un `LimitRange` a `team-b`:

   ```yaml
   # limitrange-team-b.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-limits
     namespace: team-b
   spec:
     limits:
     - type: Container
       default:              # se usa como limit si no se declara
         cpu: 500m
         memory: 512Mi
       defaultRequest:       # se usa como request si no se declara
         cpu: 250m
         memory: 256Mi
       min:                  # tamaño mínimo por contenedor
         cpu: 50m
         memory: 64Mi
       max:                  # tamaño máximo por contenedor
         cpu: "1"
         memory: 1Gi
       maxLimitRequestRatio: # cota al overcommit por contenedor
         cpu: "4"
         memory: "2"
   ```

   ```bash
   kubectl apply -f limitrange-team-b.yaml
   ```

2. Creá un Pod **sin** requests ni limits y comprobá qué le inyectó el LimitRange:

   ```bash
   kubectl run probe --image=nginx:1.27 -n team-b
   kubectl get pod probe -n team-b \
     -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   ```

   Salida esperada (defaults inyectados por admisión):

   ```json
   {"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"250m","memory":"256Mi"}}
   ```

3. Intentá violar `max` con un contenedor que pide más CPU de la permitida:

   ```bash
   kubectl run toobig --image=nginx:1.27 -n team-b \
     --overrides='{"spec":{"containers":[{"name":"toobig","image":"nginx:1.27","resources":{"requests":{"cpu":"2"}}}]}}'
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): pods "toobig" is forbidden:
   maximum cpu usage per Container is 1, but request is 2
   ```

4. Intentá violar `maxLimitRequestRatio` de memoria (ratio pedido = 4, tope = 2):

   ```bash
   kubectl run skewed --image=nginx:1.27 -n team-b \
     --overrides='{"spec":{"containers":[{"name":"skewed","image":"nginx:1.27","resources":{"requests":{"memory":"128Mi"},"limits":{"memory":"512Mi"}}}]}}'
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): pods "skewed" is forbidden:
   memory max limit to request ratio per Container is 2, but provided ratio is 4.000000
   ```

5. Limpiá los Pods de prueba:

   ```bash
   kubectl delete pod probe -n team-b --ignore-not-found
   ```

**Preguntas de comprobación (bloque 2):**

- **2.1** El Ejercicio 1 falla si un Pod no declara `requests`, pero el Pod `probe` del paso 2 **sí** se creó sin declararlos. ¿Cómo se reconcilian ambas cosas? ¿En qué orden actúan `LimitRange` y `ResourceQuota` dentro de la cadena de admission?
- **2.2** ¿Qué problema concreto de multi-tenancy previene `maxLimitRequestRatio: memory: "2"` que `max: memory: 1Gi` **no** previene?
- **2.3** Un tenant argumenta que quiere Pods `BestEffort` (sin requests ni limits) para trabajos exploratorios baratos. Con este `LimitRange` aplicado, ¿es posible que ese tenant cree un Pod `BestEffort`? Justificá.

---

## Ejercicio 3 — Clases de QoS y el orden de desalojo bajo presión

El *overcommit* (sumar `limits` mayores que la capacidad física) solo es seguro si sabés a quién sacrifica el kubelet cuando el nodo entra en presión de memoria. Eso lo determina la **QoS class**, derivada automáticamente de cómo definiste requests/limits.

**Pasos:**

1. Creá los tres Pods canónicos, uno por clase de QoS, en `team-a`:

   ```yaml
   # qos-pods.yaml
   apiVersion: v1
   kind: Pod
   metadata: { name: qos-guaranteed, namespace: team-a }
   spec:
     containers:
     - name: app
       image: registry.k8s.io/pause:3.9
       resources:
         requests: { cpu: 200m, memory: 256Mi }
         limits:   { cpu: 200m, memory: 256Mi }   # request == limit ⇒ Guaranteed
   ---
   apiVersion: v1
   kind: Pod
   metadata: { name: qos-burstable, namespace: team-a }
   spec:
     containers:
     - name: app
       image: registry.k8s.io/pause:3.9
       resources:
         requests: { cpu: 100m, memory: 128Mi }
         limits:   { cpu: 300m, memory: 512Mi }   # request < limit ⇒ Burstable
   ---
   apiVersion: v1
   kind: Pod
   metadata: { name: qos-besteffort, namespace: team-a }
   spec:
     containers:
     - name: app
       image: registry.k8s.io/pause:3.9           # sin resources ⇒ BestEffort
   ```

   ```bash
   kubectl apply -f qos-pods.yaml
   ```

2. Verificá la clase asignada a cada uno:

   ```bash
   kubectl get pods -n team-a \
     -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
   ```

   Salida esperada:

   ```
   NAME             QOS
   qos-besteffort   BestEffort
   qos-burstable    Burstable
   qos-guaranteed   Guaranteed
   ```

3. Inspeccioná cómo el `oom_score_adj` refleja el orden de sacrificio (a mayor score, primero lo mata el kernel bajo OOM). Ejecutalo desde un nodo o con `crictl`; alternativa portable:

   ```bash
   for p in qos-guaranteed qos-burstable qos-besteffort; do
     echo -n "$p -> "
     kubectl get pod $p -n team-a -o jsonpath='{.status.qosClass}{"\n"}'
   done
   ```

   > **Nota de mecánica interna.** El kubelet asigna `oom_score_adj = -997` a Guaranteed, un valor calculado entre 2 y 999 a Burstable (inversamente proporcional a la memoria solicitada), y `1000` a BestEffort. Bajo *node-pressure eviction*, el kubelet ordena los candidatos primero por si exceden sus requests y luego por `Priority`; el OOM killer del kernel usa el `oom_score_adj`. Ambos mecanismos coinciden en sacrificar BestEffort → Burstable → Guaranteed.

4. (Opcional, si tu laboratorio lo permite) Provocá presión real con un Pod que reserve poca memoria pero consuma mucha, y observá el desalojo:

   ```bash
   kubectl run hog -n team-a --image=polinux/stress --restart=Never -- \
     stress --vm 1 --vm-bytes 1500M --vm-hang 0
   kubectl get events -n team-a --field-selector reason=Evicted
   ```

**Preguntas de comprobación (bloque 3):**

- **3.1** Un tenant define un contenedor con `requests.cpu: 500m` y `limits.cpu: 500m`, pero `requests.memory: 256Mi` y `limits.memory: 512Mi`. ¿Qué QoS class recibe el Pod y por qué? (Cuidado: es una trampa habitual.)
- **3.2** En términos de optimización de multi-tenancy: ¿por qué conviene que las cargas *productivas* de `team-a` sean `Guaranteed` aunque eso reduzca el nivel de overcommit que podés lograr en el nodo?
- **3.3** ¿Por qué el orden de *node-pressure eviction* del kubelet y el `oom_score_adj` del kernel pueden discrepar en casos límite, y qué recurso deberías fijar en `request` para que un Pod Burstable **no** sea desalojado antes de tiempo por memoria?

---

## Ejercicio 4 — PriorityClass y preemption entre tiers de tenant

Cuando el cluster está lleno, la multi-tenancy justa exige que el tier *premium* pueda desalojar al tier *standard*. Eso es `PriorityClass` + preemption del scheduler.

**Pasos:**

1. Creá dos `PriorityClass` globales:

   ```yaml
   # priorityclasses.yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: { name: tenant-premium }
   value: 1000000
   globalDefault: false
   preemptionPolicy: PreemptLowerPriority
   description: "Cargas productivas del tier premium (team-a)."
   ---
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: { name: tenant-standard }
   value: 10000
   globalDefault: false
   preemptionPolicy: PreemptLowerPriority
   description: "Cargas batch del tier standard (team-b)."
   ```

   ```bash
   kubectl apply -f priorityclasses.yaml
   ```

2. Saturá deliberadamente la capacidad con Pods de baja prioridad. Ajustá `memory` para que ~3-4 réplicas llenen un nodo de tu laboratorio:

   ```bash
   kubectl create deployment filler --image=registry.k8s.io/pause:3.9 -n team-b
   kubectl set resources deployment filler -n team-b --requests=memory=1Gi,cpu=500m
   kubectl patch deployment filler -n team-b --type merge \
     -p '{"spec":{"template":{"spec":{"priorityClassName":"tenant-standard"}}}}'
   kubectl scale deployment filler -n team-b --replicas=6
   kubectl get pods -n team-b -o wide
   ```

   Esperá a ver algunos Pods en `Pending` (el nodo se llenó).

3. Lanzá una carga *premium* que no entra sin desalojar:

   ```bash
   kubectl run critical -n team-a --image=registry.k8s.io/pause:3.9 \
     --overrides='{"spec":{"priorityClassName":"tenant-premium","containers":[{"name":"critical","image":"registry.k8s.io/pause:3.9","resources":{"requests":{"memory":"1Gi","cpu":"500m"}}}]}}'
   ```

4. Observá la preemption en los eventos del scheduler:

   ```bash
   kubectl get events -A --field-selector reason=Preempted \
     --sort-by=.lastTimestamp | tail -n 5
   kubectl describe pod critical -n team-a | grep -A3 -i "preempt\|scheduled"
   ```

   Salida esperada (el scheduler eligió víctimas de menor prioridad):

   ```
   Normal  Preempted  pod/filler-xxxx  Preempted by team-a/critical on node <node>
   Normal  Scheduled  pod/critical     Successfully assigned team-a/critical to <node>
   ```

**Preguntas de comprobación (bloque 4):**

- **4.1** ¿Qué diferencia hay entre `preemptionPolicy: PreemptLowerPriority` y `preemptionPolicy: Never`, y para qué tipo de carga (por ejemplo, jobs batch de larga duración) usarías `Never`?
- **4.2** El scheduler eligió víctimas del namespace `team-b`. La preemption, ¿respeta las fronteras de namespace o es una decisión a nivel de nodo? ¿Qué implicancia tiene esto para la *aislación* entre tenants?
- **4.3** ¿Cómo evitás que un tenant *standard* se asigne a sí mismo `tenant-premium` en el `priorityClassName` de sus Pods y burle el esquema de tiers? Nombrá el mecanismo de Kubernetes específico.

---

## Ejercicio 5 — Bin-packing del scheduler: densidad vs. dispersión

Para *optimizar* el uso de recursos (no solo repartirlos) querés que el scheduler **consolide** cargas en menos nodos, dejando nodos vacíos que el Cluster Autoscaler pueda apagar. El plugin `NodeResourcesFit` controla esa política de *scoring*.

**Pasos:**

1. Inspeccioná la estrategia de scoring vigente. En un cluster gestionado no siempre podés editarla, pero podés leer el `KubeSchedulerConfiguration` de referencia:

   ```yaml
   # scheduler-binpack.yaml  (referencia de configuración del kube-scheduler)
   apiVersion: kubescheduler.config.k8s.io/v1
   kind: KubeSchedulerConfiguration
   profiles:
   - schedulerName: default-scheduler
     pluginConfig:
     - name: NodeResourcesFit
       args:
         scoringStrategy:
           type: MostAllocated        # favorece nodos ya cargados ⇒ bin-packing
           resources:
           - name: cpu
             weight: 1
           - name: memory
             weight: 1
   ```

   > **Mecánica interna.** El default histórico es `LeastAllocated` (dispersa la carga, maximiza headroom por nodo). `MostAllocated` invierte la función de score y empaqueta. `RequestedToCapacityRatio` te da una curva de utilización configurable con `shape`, útil cuando querés empacar pero frenar antes del 100 %. Cambiar esto exige reiniciar el kube-scheduler con el nuevo config, algo posible en clusters self-managed (kubeadm) y no en la mayoría de los *managed*.

2. Sin tocar el scheduler, medí la distribución actual de requests por nodo (esto es lo que el scheduler intenta optimizar):

   ```bash
   kubectl describe nodes | grep -A6 "Allocated resources"
   ```

   Salida esperada (fragmento por nodo):

   ```
   Allocated resources:
     Resource           Requests      Limits
     cpu                1200m (30%)   3 (75%)
     memory             1536Mi (20%)  4Gi (53%)
   ```

3. Calculá el *headroom* y la fragmentación con una consulta agregada:

   ```bash
   kubectl get pods -A \
     -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,CPUREQ:.spec.containers[*].resources.requests.cpu' \
     --field-selector=status.phase=Running | sort -k3
   ```

4. Compará *requests* declarados contra uso real — la brecha es tu overcommit efectivo y tu oportunidad de ahorro:

   ```bash
   kubectl top pods -A --sum=true
   ```

   Si el `top` (uso real) es muy inferior a los requests agregados, tus tenants están **sobre-reservando**: candidatos ideales para un Vertical Pod Autoscaler en modo `recommendation`.

**Preguntas de comprobación (bloque 5):**

- **5.1** ¿En qué escenario de multi-tenancy `LeastAllocated` (dispersión) es preferible a `MostAllocated` (bin-packing), a pesar de dejar nodos a medio llenar?
- **5.2** El bin-packing agresivo (`MostAllocated`) puede sabotear al Cluster Autoscaler en el *scale-up* y también aumentar el *blast radius* de una caída de nodo. Explicá ambos efectos.
- **5.3** El scheduler puntúa según **requests**, no según **uso real**. Si tus tenants sobre-reservan un 3× (paso 4), ¿qué dos herramientas combinás para cerrar esa brecha sin comprometer disponibilidad, y cuál corre riesgo de conflicto con el HPA?

---

## Ejercicio 6 — Showback: atribuir consumo y costo por tenant

Optimizar multi-tenancy sin medir el consumo por tenant es imposible de sostener: sin *showback*, ningún equipo tiene incentivo para ajustar sus requests. Este ejercicio deriva un consumo atribuible por namespace y lo conecta con el modelo de OpenCost.

**Pasos:**

1. Verificá que tus namespaces de tenant tengan etiquetas de atribución consistentes (las pusimos en el Ejercicio 1):

   ```bash
   kubectl get ns -L tenant,tier
   ```

   Salida esperada:

   ```
   NAME     STATUS   AGE   TENANT    TIER
   team-a   Active   1h    team-a    premium
   team-b   Active   1h    team-b    standard
   ```

2. Sumá los `requests` de CPU y memoria por namespace — la base de un *showback* proporcional a la reserva:

   ```bash
   kubectl get pods -A --field-selector=status.phase=Running \
     -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.containers[*].resources.requests.cpu}{"\n"}{end}' \
     | awk '{a[$1]+=$2} END{for (n in a) printf "%-12s cpu_req=%s\n", n, a[n]}'
   ```

3. (Opcional, laboratorio con red) Instalá OpenCost, que traduce esos requests y uso en costo monetario por namespace/label:

   ```bash
   kubectl apply --namespace opencost -f \
     https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml
   kubectl -n opencost port-forward deploy/opencost 9003:9003 &
   curl -s "http://localhost:9003/allocation/compute?window=1d&aggregate=namespace" \
     | python3 -m json.tool | head -n 30
   ```

   El endpoint `/allocation` devuelve, por namespace, el costo de `cpuCost`, `ramCost`, `pvCost` y el *efficiency* (uso real / reservado) — exactamente la métrica que necesitás para exigirle a un tenant que ajuste sus requests.

4. Cerrá el laboratorio limpiando todo lo creado:

   ```bash
   kubectl delete ns team-a team-b --ignore-not-found
   kubectl delete priorityclass tenant-premium tenant-standard --ignore-not-found
   ```

**Preguntas de comprobación (bloque 6):**

- **6.1** El paso 2 atribuye costo por **requests**, no por uso real. ¿Por qué, en un modelo de multi-tenancy con reservas garantizadas, cobrar por *request reservado* es más justo que cobrar por *uso medido*?
- **6.2** ¿Por qué las etiquetas consistentes a nivel de namespace (`tenant`, `tier`) son un prerrequisito técnico —no solo cosmético— para cualquier sistema de *cost allocation*?
- **6.3** El campo `efficiency` de OpenCost (uso/reserva) de un tenant es 0.15 de forma sostenida. ¿Qué acción de optimización recomendás y con qué control de los ejercicios anteriores la hacés cumplir?

---

## Respuestas

<details>
<summary><strong>Ver respuestas de todos los bloques</strong></summary>

### Bloque 1 — ResourceQuota

**1.1** La `ResourceQuota` la aplica el *admission controller* `ResourceQuota` en el momento de crear el **Pod**, no el objeto de nivel superior. `kubectl scale` solo actualiza el campo `replicas` del Deployment (que sí se admite); es el `ReplicaSet` controller quien intenta crear los Pods excedentes, y ahí el admission controller los rechaza con `FailedCreate`. Lección: las cuotas se evalúan sobre los objetos que *consumen* recursos (Pods, PVCs), por eso los controladores de nivel superior degradan silenciosamente a "réplicas insatisfechas" en vez de fallar el comando. Referencia: <https://kubernetes.io/docs/concepts/policy/resource-quotas/>.

**1.2** El overcommit ratio autorizado es `limits.cpu / requests.cpu = 4 / 2 = 2×`. Significa que el tenant puede pedir hasta el doble de CPU en *limits* de lo que reserva en *requests*. El riesgo: si todos los Pods intentan usar su límite a la vez, el nodo entra en *CPU throttling* (la CPU es comprimible, así que no hay OOM, pero sí latencia). Es un trade-off deliberado entre densidad y previsibilidad de performance.

**1.3** Es rechazado. Cuando una `ResourceQuota` restringe `requests.memory` (o cualquier `requests.*`/`limits.*`), **todo** Pod del namespace debe declarar ese recurso o la creación falla con `must specify requests.memory`. Por eso el `LimitRange` del Ejercicio 2 es prácticamente obligatorio junto a una quota de recursos: inyecta los defaults que satisfacen la exigencia de la cuota.

### Bloque 2 — LimitRange

**2.1** El orden de admisión importa: el admission controller `LimitRanger` corre **antes** que el `ResourceQuota`. `LimitRanger` muta el Pod inyectando `defaultRequest`/`default`; recién entonces `ResourceQuota` valida un Pod que **ya** tiene requests. Por eso `probe` se creó sin declarar nada: para cuando la cuota lo vio, ya tenía `requests` inyectados. Sin el LimitRange, el mismo Pod habría sido rechazado (respuesta 1.3).

**2.2** `max: memory: 1Gi` acota el tamaño **absoluto** de un contenedor, pero no la relación entre lo reservado y lo que puede llegar a usar. `maxLimitRequestRatio: memory: "2"` acota el **overcommit por contenedor**: impide que un tenant reserve poco (`request: 128Mi`) pero se autorice a explotar hasta mucho (`limit: 512Mi`). Ese patrón es el clásico *noisy neighbor* de memoria: reservan barato, consumen caro, y al no ser memoria comprimible, provocan OOM en vecinos. El ratio lo prohíbe de raíz.

**2.3** No. Con este `LimitRange`, un Pod sin requests/limits recibe los `defaultRequest`/`default` inyectados, con lo que se vuelve **Burstable** (request < limit), nunca `BestEffort`. Para permitir `BestEffort` habría que quitar los defaults del LimitRange en ese namespace, lo cual entraría en conflicto con una `ResourceQuota` sobre `requests.*`. En un cluster multi-tenant bien gobernado, `BestEffort` suele estar deliberadamente vetado.

### Bloque 3 — QoS

**3.1** Recibe **Burstable**, no Guaranteed. La regla de `Guaranteed` exige que **cada** recurso (CPU *y* memoria) tenga `request == limit` en **todos** los contenedores. Acá la CPU cumple (500m/500m) pero la memoria no (256Mi/512Mi), así que basta ese único desajuste para degradar todo el Pod a Burstable. Es la trampa más común del tema. Referencia: <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>.

**3.2** Porque `Guaranteed` da a las cargas productivas dos garantías: (a) el kubelet las desaloja **últimas** bajo node-pressure eviction y les asigna el `oom_score_adj` más protegido; (b) con CPU `request == limit` obtienen su *cpu.share* completo y no compiten por ciclos. El costo es menor densidad (no podés overcommittear lo que está garantizado), pero para el tier premium la previsibilidad de latencia vale más que el ahorro de packing. El overcommit agresivo se reserva para el tier standard/batch.

**3.3** Discrepan porque son dos mecanismos distintos: la *eviction* del kubelet es proactiva (actúa ante *thresholds* como `memory.available<100Mi` y ordena candidatos por exceso-sobre-request y luego por `Priority`), mientras que el OOM killer del kernel es reactivo (dispara cuando la memoria física ya se agotó, usando `oom_score_adj`). Un Pod puede ser buen candidato por una métrica y no por la otra. Para que un Pod Burstable **no** sea desalojado prematuramente por memoria, hay que fijar `requests.memory` en un valor igual o mayor a su uso real: la eviction solo penaliza el **uso por encima del request**, así que un request bien dimensionado lo protege.

### Bloque 4 — PriorityClass y preemption

**4.1** `PreemptLowerPriority` (default) permite que, si el Pod no entra, el scheduler **desaloje** Pods de menor prioridad para hacerle lugar. `Never` hace que el Pod respete su prioridad para el *orden en la cola de scheduling* (se atiende antes que los de menor prioridad) pero **nunca desaloje** a nadie: si no hay lugar, espera en `Pending`. Usás `Never` para jobs batch de larga duración de alta prioridad que no querés que causen desalojos disruptivos —preferís que esperen capacidad antes que matar trabajo en curso de otros.

**4.2** La preemption es una decisión a **nivel de nodo/scheduler global**, no respeta fronteras de namespace: el scheduler busca víctimas de menor prioridad en *cualquier* namespace del nodo elegido. Implicancia crítica para aislación: un `PriorityClass` alto de un tenant puede desalojar Pods de **otro** tenant. Por eso la prioridad no es un mecanismo de aislación entre tenants; para aislación real se combina con separación por nodos (taints/tolerations, node affinity) o con cuotas de scope de prioridad (`scopeSelector` sobre `PriorityClass` en el `ResourceQuota`).

**4.3** Con un `ResourceQuota` que usa `scopeSelector` sobre el scope `PriorityClass`, o —más directo— con un **admission policy** (ValidatingAdmissionPolicy / OPA Gatekeeper / Kyverno) que restrinja qué `priorityClassName` puede usar cada namespace. Kubernetes no acopla `PriorityClass` a RBAC por sí solo: cualquiera que pueda crear Pods puede nombrar cualquier PriorityClass existente, así que la barrera se implementa en admisión. La combinación canónica es `ResourceQuota` con `scopeSelector: {scopeName: PriorityClass, operator: In, values: [tenant-standard]}` en `team-b`, que rechaza Pods premium en ese namespace.

### Bloque 5 — Bin-packing

**5.1** `LeastAllocated` (dispersión) es preferible cuando priorizás **disponibilidad y aislación de performance** sobre densidad: cargas latency-sensitive que necesitan headroom para picos sin throttling, o cuando querés minimizar el impacto de la caída de un nodo (menos Pods por nodo = menor blast radius). También ante autoscaling de Pods (HPA) que necesita margen inmediato para crecer sin esperar scale-up de nodos.

**5.2** (a) *Sabotaje al scale-up*: si `MostAllocated` empaqueta todo en los nodos existentes hasta saturarlos, el Cluster Autoscaler ve nodos "llenos" y Pods `Pending`, pero el packing puede dejar fragmentos inutilizables y disparar scale-up tardío o innecesario; peor aún, retrasa la señal de scale-up porque exprime hasta el último milicore antes de admitir que falta capacidad. (b) *Blast radius*: concentrar muchos Pods en pocos nodos significa que la caída de un solo nodo desaloja proporcionalmente más cargas; la densidad que ahorra dinero también concentra el riesgo. El equilibrio suele ser `RequestedToCapacityRatio` con una curva que empaca pero se frena, p. ej., en ~80 %.

**5.3** Combinás **Vertical Pod Autoscaler** (en modo `recommendation` u `Off` primero, para no reiniciar Pods ciegamente) para ajustar los `requests` sobre-reservados a valores realistas, con el **Cluster Autoscaler / Karpenter** para retirar los nodos que quedan vacíos tras el ajuste. El riesgo de conflicto es entre **VPA y HPA sobre el mismo recurso**: si el HPA escala por CPU y el VPA también ajusta CPU requests, se pelean; la regla es no dejar que ambos gobiernen la misma métrica (HPA sobre métricas custom/RPS, VPA sobre memoria, por ejemplo).

### Bloque 6 — Showback

**6.1** Porque en un modelo con reservas, el `request` es capacidad que el scheduler **aparta exclusivamente** para ese tenant: aunque el Pod use el 10 %, ese 90 % restante no está disponible para nadie más (queda contabilizado en `Allocated resources`). El tenant paga por la *exclusión* que impone al cluster, no por el consumo instantáneo. Cobrar solo por uso real premiaría el sobre-aprovisionamiento (reservar mucho, usar poco, pagar poco) y castigaría al cluster con fragmentación no cobrada. El `efficiency` (uso/reserva) es justamente la métrica que expone ese desperdicio.

**6.2** Porque un sistema de cost allocation **agrupa** el consumo por dimensión de negocio, y esa dimensión tiene que existir como metadato consultable. Sin etiquetas consistentes (`tenant`, `tier`) en cada namespace/Pod, el sistema solo puede reportar por objeto individual —ilegible— o por namespace crudo, y no puede consolidar cargas de un mismo tenant repartidas en varios namespaces, ni cruzar con centros de costo. Es un prerrequisito técnico: OpenCost y Kubecost *agregan por label*; sin el label, el eje de agregación no existe.

**6.3** Un `efficiency` de 0.15 sostenido significa que el tenant reserva ~6.7× lo que usa: sobre-aprovisionamiento severo. La acción es **reducir sus `requests`** hasta acercarlos al uso real (guiado por las recomendaciones del VPA, respuesta 5.3). Para que se cumpla y no vuelva a inflarlos, ajustás su `ResourceQuota` (Ejercicio 1) a un techo agregado acorde al uso real más un margen, y usás el `LimitRange` (Ejercicio 2) con `maxLimitRequestRatio` para impedir que compense el recorte de requests inflando los limits. Así el ahorro se vuelve estructural, no una promesa del tenant.

</details>

---

### Fuentes oficiales

- **Resource Quotas** — Kubernetes docs: <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
- **Limit Ranges** — Kubernetes docs: <https://kubernetes.io/docs/concepts/policy/limit-range/>
- **Pod Quality of Service Classes** — Kubernetes docs: <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>
- **Node-pressure Eviction** — Kubernetes docs: <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>
- **Pod Priority and Preemption** — Kubernetes docs: <https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/>
- **kube-scheduler Configuration (NodeResourcesFit / scoringStrategy)** — Kubernetes docs: <https://kubernetes.io/docs/reference/scheduling/config/>
- **Multi-tenancy** — Kubernetes docs: <https://kubernetes.io/docs/concepts/security/multi-tenancy/>
- **Vertical Pod Autoscaler** — kubernetes/autoscaler: <https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler>
- **OpenCost (cost allocation / showback)** — docs: <https://www.opencost.io/docs/>
- **CNPE Curriculum** — CNCF: <https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf>