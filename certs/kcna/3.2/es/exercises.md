# Ejercicios guiados: Scheduling (KCNA 3.2)

> Fuente de referencia: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

Estos ejercicios asumen un cluster local con al menos 2 nodos worker (por ejemplo `kind` con `kind create cluster --config` de múltiples nodos, o `minikube start --nodes 3`). Si tu cluster tiene un solo nodo, algunos comandos van a mostrar resultados distintos a los esperados; se indica en cada caso.

---

## Ejercicio 1: Ver cómo el kube-scheduler asigna un Pod a un Node

El `kube-scheduler` es el componente del control plane que decide en qué Node corre cada Pod, basándose en requests de recursos, constraints, afinidad y otros factores.

1. Listá los nodos disponibles y sus roles:
   ```bash
   kubectl get nodes -o wide
   ```
2. Creá un Pod simple sin ninguna restricción de scheduling:
   ```bash
   kubectl run nginx-demo --image=nginx --restart=Never
   ```
3. Revisá en qué Node terminó corriendo:
   ```bash
   kubectl get pod nginx-demo -o wide
   ```
4. Inspeccioná los eventos del Pod para ver la decisión del scheduler:
   ```bash
   kubectl describe pod nginx-demo | grep -A5 Events
   ```

**Preguntas de comprensión:**
1. ¿Qué componente del control plane aparece como `Source` o `From` en el evento de tipo `Scheduled`?
2. Si el cluster tiene un solo Node, ¿tiene sentido hablar de "decisión" del scheduler? ¿Por qué igual pasa por el proceso de scheduling?

---

## Ejercicio 2: Restringir el scheduling con `nodeSelector`

`nodeSelector` es el mecanismo más simple para forzar que un Pod corra solo en Nodes con determinada label.

1. Etiquetá uno de tus Nodes (reemplazá `<node-name>` por uno real de `kubectl get nodes`):
   ```bash
   kubectl label node <node-name> disk=ssd
   ```
2. Creá un manifest `pod-nodeselector.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-ssd
   spec:
     nodeSelector:
       disk: ssd
     containers:
       - name: nginx
         image: nginx
   ```
3. Aplicalo y verificá dónde corrió:
   ```bash
   kubectl apply -f pod-nodeselector.yaml
   kubectl get pod nginx-ssd -o wide
   ```
4. Ahora borrá la label del Node y creá un segundo Pod idéntico (con otro `name`) para ver qué pasa cuando ningún Node cumple el selector:
   ```bash
   kubectl label node <node-name> disk-
   kubectl apply -f pod-nodeselector.yaml
   kubectl get pod nginx-ssd -o wide
   ```
   > Nota: si reusás el mismo `name`, vas a tener que borrar el Pod anterior primero (`kubectl delete pod nginx-ssd`).

**Preguntas de comprensión:**
1. ¿Qué `status.phase` muestra un Pod cuyo `nodeSelector` no matchea ninguna label existente en el cluster?
2. ¿`nodeSelector` es una restricción "hard" (obligatoria) o "soft" (preferida)?

---

## Ejercicio 3: Node Affinity con reglas más expresivas

Node affinity extiende `nodeSelector` con operadores lógicos (`In`, `NotIn`, `Exists`, etc.) y con la posibilidad de expresar preferencias en vez de requisitos estrictos.

1. Etiquetá un Node con un valor entre varios posibles:
   ```bash
   kubectl label node <node-name> zone=us-east-1a
   ```
2. Creá `pod-affinity.yaml` usando `requiredDuringSchedulingIgnoredDuringExecution`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-affinity
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: zone
                   operator: In
                   values:
                     - us-east-1a
                     - us-east-1b
     containers:
       - name: nginx
         image: nginx
   ```
3. Aplicalo y confirmá el Node asignado:
   ```bash
   kubectl apply -f pod-affinity.yaml
   kubectl get pod nginx-affinity -o wide
   ```
4. Cambiá la sección a `preferredDuringSchedulingIgnoredDuringExecution` con un `weight`, apuntando a una label que ningún Node tiene, y volvé a aplicar. Observá que el Pod igual se schedulea.

**Preguntas de comprensión:**
1. ¿Qué diferencia hay entre `requiredDuringSchedulingIgnoredDuringExecution` y `preferredDuringSchedulingIgnoredDuringExecution`?
2. ¿Qué significa la parte `IgnoredDuringExecution` del nombre? ¿Qué pasa si la label del Node cambia después de que el Pod ya está corriendo?

---

## Ejercicio 4: Taints y Tolerations

Mientras que affinity se define en el Pod para "atraerlo" hacia ciertos Nodes, los taints se definen en el Node para "repeler" Pods, salvo que estos declaren una toleration explícita.

1. Aplicá un taint a un Node:
   ```bash
   kubectl taint nodes <node-name> workload=batch:NoSchedule
   ```
2. Intentá correr un Pod normal (sin toleration) y observá que el scheduler evita ese Node si hay otros disponibles:
   ```bash
   kubectl run nginx-notaint --image=nginx --restart=Never
   kubectl get pod nginx-notaint -o wide
   ```
3. Creá `pod-toleration.yaml` con una toleration que matchee el taint:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-tolerado
   spec:
     tolerations:
       - key: "workload"
         operator: "Equal"
         value: "batch"
         effect: "NoSchedule"
     containers:
       - name: nginx
         image: nginx
   ```
4. Aplicalo y verificá que este sí puede caer en el Node taintado:
   ```bash
   kubectl apply -f pod-toleration.yaml
   kubectl get pod nginx-tolerado -o wide
   ```
5. Limpiá el taint al terminar:
   ```bash
   kubectl taint nodes <node-name> workload=batch:NoSchedule-
   ```

**Preguntas de comprensión:**
1. Un Pod con la toleration correcta, ¿está *obligado* a correr en el Node taintado?
2. ¿Qué diferencia práctica hay entre los effects `NoSchedule`, `PreferNoSchedule` y `NoExecute`?

---

## Ejercicio 5: Resource requests y su impacto en el scheduling

El scheduler usa los `requests` de CPU/memoria declarados en cada container para decidir si un Node tiene capacidad disponible (filtra Nodes que no alcanzan a cubrir la suma de requests).

1. Consultá la capacidad asignable de tus Nodes:
   ```bash
   kubectl describe nodes | grep -A5 Allocatable
   ```
2. Creá `pod-requests.yaml` pidiendo un request de memoria deliberadamente enorme, mayor a la capacidad de cualquier Node:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-oversized
   spec:
     containers:
       - name: nginx
         image: nginx
         resources:
           requests:
             memory: "500Gi"
             cpu: "1"
   ```
3. Aplicalo y observá el estado resultante:
   ```bash
   kubectl apply -f pod-requests.yaml
   kubectl get pod nginx-oversized
   kubectl describe pod nginx-oversized | grep -A5 Events
   ```

**Preguntas de comprensión:**
1. ¿Qué mensaje de evento explica por qué el Pod no fue scheduleado?
2. ¿Los `limits` de un container también son considerados en la fase de filtrado de Nodes, o solo los `requests`?

---

## Ejercicio 6: Scheduling manual con `nodeName`

Es posible saltear al scheduler por completo indicando explícitamente el Node en el spec del Pod.

1. Creá `pod-nodename.yaml` (reemplazá `<node-name>` por uno real):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-manual
   spec:
     nodeName: <node-name>
     containers:
       - name: nginx
         image: nginx
   ```
2. Aplicalo y confirmá que corre exactamente donde indicaste:
   ```bash
   kubectl apply -f pod-nodename.yaml
   kubectl get pod nginx-manual -o wide
   ```
3. Revisá los eventos del Pod:
   ```bash
   kubectl describe pod nginx-manual | grep -A5 Events
   ```

**Preguntas de comprensión:**
1. ¿Aparece un evento de tipo `Scheduled` para este Pod? ¿Por qué?
2. ¿Qué controles de capacidad o afinidad se pierden al usar `nodeName` en vez de dejar que decida el scheduler?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
1. Aparece `kube-scheduler` (o `default-scheduler`) como fuente del evento `Scheduled`.
2. Sí: aunque solo haya un Node candidato, el Pod igual pasa por las fases de filtering y scoring del scheduler; simplemente hay un único resultado posible.

**Ejercicio 2**
1. El Pod queda en estado `Pending`, ya que no hay ningún Node que satisfaga el `nodeSelector`.
2. Es una restricción "hard": si ningún Node tiene la label exacta, el Pod nunca se schedulea (no hay noción de preferencia en `nodeSelector`).

**Ejercicio 3**
1. `required...` es una condición obligatoria: si ningún Node la cumple, el Pod queda `Pending`. `preferred...` es una preferencia con un `weight` que influye en el scoring, pero no bloquea el scheduling si ningún Node la cumple.
2. Significa que la regla de afinidad solo se evalúa en el momento de programar el Pod. Si la label del Node cambia después, el Pod ya en ejecución no es desalojado ni reprogramado.

**Ejercicio 4**
1. No necesariamente: la toleration solo *permite* que el Pod sea considerado para ese Node, pero no lo *fuerza* a correr ahí. El scheduler puede igualmente elegir otro Node sin taint.
2. `NoSchedule` impide que nuevos Pods sin toleration se scheduleen en el Node, pero no afecta a los que ya corren ahí. `PreferNoSchedule` es una versión "soft" (el scheduler intenta evitarlo, pero no lo garantiza). `NoExecute` además expulsa (evict) los Pods que ya están corriendo y no toleran el taint.

**Ejercicio 5**
1. Un evento tipo `FailedScheduling` con un mensaje como "Insufficient memory" indicando que ningún Node tiene memoria allocatable suficiente.
2. Solo los `requests` se usan en la fase de filtering (predicates) para decidir si un Node tiene capacidad disponible; los `limits` no son un criterio de scheduling, se aplican en runtime para contención de recursos (throttling/OOM).

**Ejercicio 6**
1. No aparece evento `Scheduled`, porque el Pod nunca pasa por el proceso del kube-scheduler: el kubelet del Node indicado simplemente lo arranca directamente.
2. Se pierden todos los checks del scheduler: verificación de recursos disponibles (requests vs allocatable), taints/tolerations, node affinity, y cualquier otro predicate o priority. Si el Node no tiene capacidad o tiene un taint incompatible, el Pod puede fallar en el kubelet en vez de quedar prolijamente `Pending`.

</details>