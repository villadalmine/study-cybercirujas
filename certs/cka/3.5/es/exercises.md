# Ejercicios guiados — 3.5 Configure Pod admission and scheduling (limits, node affinity, etc.)

> CKA v1.35 — Peso en el examen: 2.5
> Fuente de referencia: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Este tema combina dos mecanismos distintos que a veces se confunden:

- **Admission**: controles que corren en el `kube-apiserver` cuando el objeto ya fue aceptado sintácticamente, y que pueden mutarlo (`LimitRange`) o rechazarlo (`ResourceQuota`, `LimitRange` fuera de rango) **antes** de que exista en `etcd`.
- **Scheduling**: la decisión del `kube-scheduler` de en qué node correr un Pod que ya existe como objeto (`nodeSelector`, node affinity, taints/tolerations, pod affinity).

Los ejercicios siguen ese orden: primero admission, después scheduling.

---

## Ejercicio 1 — `LimitRange`: defaults y límites por Pod

1. Creá un namespace de trabajo:
   ```bash
   kubectl create namespace admission-lab
   ```
2. Definí un `LimitRange` que fije requests/limits por default y un máximo permitido por contenedor:
   ```yaml
   # limitrange.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: cpu-mem-limits
     namespace: admission-lab
   spec:
     limits:
       - type: Container
         default:
           cpu: "500m"
           memory: "256Mi"
         defaultRequest:
           cpu: "250m"
           memory: "128Mi"
         max:
           cpu: "1"
           memory: "512Mi"
   ```
3. Aplicalo:
   ```bash
   kubectl apply -f limitrange.yaml
   ```
4. Creá un Pod sin especificar `resources` y confirmá que el admission controller le inyectó los defaults:
   ```bash
   kubectl run sin-resources --image=nginx -n admission-lab
   kubectl get pod sin-resources -n admission-lab -o jsonpath='{.spec.containers[0].resources}'
   ```
5. Intentá crear un Pod que pida más CPU que el `max` definido:
   ```bash
   kubectl run excede-max --image=nginx -n admission-lab \
     --overrides='{"spec":{"containers":[{"name":"excede-max","image":"nginx","resources":{"requests":{"cpu":"2"}}}]}}'
   ```

**Preguntas de comprensión**

- ¿Qué diferencia hay entre `default` y `defaultRequest` dentro de un `LimitRange`?
- ¿El Pod del paso 5 llega a crearse como objeto en `etcd` y después falla el scheduling, o directamente se rechaza el request a la API?

---

## Ejercicio 2 — `ResourceQuota`: límites a nivel namespace

1. En el mismo namespace, definí una quota que limite tanto el uso agregado de recursos como la cantidad de objetos:
   ```yaml
   # quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: ns-quota
     namespace: admission-lab
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: "512Mi"
       pods: "3"
   ```
2. Aplicala:
   ```bash
   kubectl apply -f quota.yaml
   ```
3. Revisá el estado de uso actual:
   ```bash
   kubectl describe resourcequota ns-quota -n admission-lab
   ```
4. Creá Pods adicionales hasta superar el límite de `pods: "3"` (contando el que ya existe del ejercicio 1) y observá el mensaje de error:
   ```bash
   kubectl run extra-1 --image=nginx -n admission-lab
   kubectl run extra-2 --image=nginx -n admission-lab
   kubectl run extra-3 --image=nginx -n admission-lab
   ```

**Preguntas de comprensión**

- Si en el Ejercicio 1 no hubiera existido el `LimitRange` con `defaultRequest`, ¿qué habría pasado al crear un Pod sin `resources` explícitos en un namespace con `requests.cpu` en la quota?
- ¿Por qué conviene combinar `LimitRange` y `ResourceQuota` en namespaces multi-tenant?

---

## Ejercicio 3 — `nodeSelector`

1. Listá los nodes disponibles y etiquetá uno:
   ```bash
   kubectl get nodes
   kubectl label node <nombre-del-node> disktype=ssd
   ```
2. Creá un Pod que use ese label como criterio de scheduling:
   ```yaml
   # pod-nodeselector.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-ssd
     namespace: admission-lab
   spec:
     nodeSelector:
       disktype: ssd
     containers:
       - name: nginx
         image: nginx
   ```
3. Aplicalo y confirmá dónde quedó programado:
   ```bash
   kubectl apply -f pod-nodeselector.yaml
   kubectl get pod pod-ssd -n admission-lab -o wide
   ```
4. Editá el `nodeSelector` a un valor que ningún node tenga (por ejemplo `disktype: nvme`), volvé a aplicar como un Pod nuevo, y revisá los eventos:
   ```bash
   kubectl describe pod <pod-que-quedó-pending> -n admission-lab
   ```

**Preguntas de comprensión**

- ¿Qué componente evalúa el `nodeSelector`: el `kube-apiserver` en admission o el `kube-scheduler`?
- ¿Qué mensaje de evento aparece cuando ningún node matchea el selector?

---

## Ejercicio 4 — Node affinity (`required` vs `preferred`)

1. Etiquetá el node con un segundo label:
   ```bash
   kubectl label node <nombre-del-node> env=prod
   ```
2. Creá un Pod con `requiredDuringSchedulingIgnoredDuringExecution`:
   ```yaml
   # pod-affinity-required.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-required
     namespace: admission-lab
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: env
                   operator: In
                   values: ["prod"]
     containers:
       - name: nginx
         image: nginx
   ```
3. Aplicalo y confirmá el scheduling exitoso.
4. Creá un segundo Pod con `preferredDuringSchedulingIgnoredDuringExecution` apuntando a un label que **no** existe en ningún node (`env: staging`), con `weight: 50`, y comprobá que igual se programa:
   ```yaml
   # pod-affinity-preferred.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-preferred
     namespace: admission-lab
   spec:
     affinity:
       nodeAffinity:
         preferredDuringSchedulingIgnoredDuringExecution:
           - weight: 50
             preference:
               matchExpressions:
                 - key: env
                   operator: In
                   values: ["staging"]
     containers:
       - name: nginx
         image: nginx
   ```
   ```bash
   kubectl apply -f pod-affinity-preferred.yaml
   kubectl get pod pod-preferred -n admission-lab -o wide
   ```

**Preguntas de comprensión**

- ¿Qué pasa con un Pod cuya única regla es `required` si ningún node matchea al momento de crearlo?
- ¿Qué pasa con el Pod del paso 4, cuya preferencia no matchea ningún node?
- ¿Qué significa el sufijo `IgnoredDuringExecution` en ambos campos?

---

## Ejercicio 5 — Taints y tolerations

1. Aplicá un taint al node:
   ```bash
   kubectl taint nodes <nombre-del-node> dedicated=gpu:NoSchedule
   ```
2. Intentá crear un Pod común (sin toleration) y observá que queda `Pending` si no hay otro node disponible:
   ```bash
   kubectl run sin-toleration --image=nginx -n admission-lab
   kubectl get pod sin-toleration -n admission-lab
   ```
3. Creá un Pod con la toleration correspondiente:
   ```yaml
   # pod-toleration.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-con-toleration
     namespace: admission-lab
   spec:
     tolerations:
       - key: "dedicated"
         operator: "Equal"
         value: "gpu"
         effect: "NoSchedule"
     containers:
       - name: nginx
         image: nginx
   ```
   ```bash
   kubectl apply -f pod-toleration.yaml
   kubectl get pod pod-con-toleration -n admission-lab -o wide
   ```
4. Quitá el taint al terminar:
   ```bash
   kubectl taint nodes <nombre-del-node> dedicated=gpu:NoSchedule-
   ```

**Preguntas de comprensión**

- ¿Cuál es la diferencia práctica entre los efectos `NoSchedule`, `PreferNoSchedule` y `NoExecute`?
- Si un Pod ya está corriendo en un node y le agregan un taint `NoExecute` para el cual el Pod no tiene toleration, ¿qué ocurre?
- Una toleration en un Pod, ¿garantiza que ese Pod se va a programar en el node taintado, o solo lo habilita como candidato?

---

## Ejercicio 6 — Pod anti-affinity para distribuir réplicas

1. Creá un Deployment con `podAntiAffinity` para que sus réplicas eviten compartir node:
   ```yaml
   # deploy-antiaffinity.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: admission-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         affinity:
           podAntiAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               - labelSelector:
                   matchExpressions:
                     - key: app
                       operator: In
                       values: ["web"]
                 topologyKey: "kubernetes.io/hostname"
         containers:
           - name: nginx
             image: nginx
   ```
2. Aplicalo y verificá la distribución de Pods entre nodes:
   ```bash
   kubectl apply -f deploy-antiaffinity.yaml
   kubectl get pods -n admission-lab -l app=web -o wide
   ```
3. Escalá a más réplicas que nodes disponibles y observá qué pasa con las que no consiguen node:
   ```bash
   kubectl scale deployment web -n admission-lab --replicas=5
   kubectl get pods -n admission-lab -l app=web -o wide
   ```

**Preguntas de comprensión**

- ¿Para qué sirve `topologyKey` en una regla de pod affinity/anti-affinity?
- En un cluster de un solo node, ¿qué le pasa a las réplicas del paso 3 que no consiguen ubicarse?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- `defaultRequest` fija el valor de `resources.requests` cuando el contenedor no lo especifica; `default` fija `resources.limits` cuando el contenedor no lo especifica. Son campos independientes dentro del mismo `type: Container`.
- Se rechaza directamente en el request a la API: `LimitRange` actúa como admission controller y valida contra `max` antes de persistir el objeto en `etcd`. Nunca llega a existir como Pod, por lo tanto tampoco pasa por el scheduler.

**Ejercicio 2**
- El Pod habría sido rechazado por el admission controller de `ResourceQuota`: cuando una quota incluye `requests.cpu` (o `requests.memory`), todo Pod del namespace debe declarar esos requests explícitamente (de forma directa o vía `LimitRange`); si no los tiene, la creación falla con un error de "must specify limits/requests".
- Porque `LimitRange` resuelve el problema de que `ResourceQuota` exige requests/limits explícitos: sin defaults, cada manifiesto tendría que declararlos a mano o sería rechazado.

**Ejercicio 3**
- Lo evalúa el `kube-scheduler` durante la fase de filtering, no el admission controller. El Pod se crea igual como objeto; lo que cambia es a qué node se asigna (o si queda sin asignar).
- El evento indica algo como `0/N nodes are available: N node(s) didn't match Pod's node affinity/selector`, visible con `kubectl describe pod`, y el Pod queda en estado `Pending`.

**Ejercicio 4**
- El Pod queda `Pending`: una regla `required` es una condición dura (hard constraint) evaluada en el filtering del scheduler; si ningún node la cumple, no hay candidato posible.
- Se programa igual: `preferred` es una condición blanda (soft constraint) usada solo para puntuar nodes candidatos en la fase de scoring; si no matchea, simplemente no suma peso, pero cualquier node sigue siendo elegible.
- Indica que la regla solo se evalúa al momento de programar el Pod (scheduling). Si las labels del node cambian después y dejan de cumplir la condición, un Pod ya corriendo ahí **no** es desalojado ni re-evaluado.

**Ejercicio 5**
- `NoSchedule`: el scheduler no asigna nuevos Pods sin toleration al node, pero no afecta a los que ya corren ahí. `PreferNoSchedule` es la versión blanda de lo anterior (el scheduler intenta evitarlo, pero puede igual usarlo). `NoExecute` además expulsa (evict) a los Pods que ya están corriendo en el node y no toleran ese taint.
- El Pod es expulsado (evicted) del node, salvo que tenga una toleration para ese taint específico (opcionalmente con `tolerationSeconds` para retrasar la expulsión).
- Solo lo habilita como candidato: tolerar un taint permite que el scheduler considere ese node, pero no obliga a que el Pod termine ahí. Para forzar la ubicación hace falta combinarlo con node affinity o `nodeSelector`.

**Ejercicio 6**
- `topologyKey` define el dominio de agrupamiento sobre el que se aplica la regla (por ejemplo `kubernetes.io/hostname` para "un Pod por node", o una label de zona para "un Pod por zona"). El scheduler agrupa los nodes por el valor de esa label para decidir qué cuenta como "el mismo lugar".
- Quedan en `Pending`: con `requiredDuringSchedulingIgnoredDuringExecution` y `topologyKey: kubernetes.io/hostname`, el scheduler no permite más de un Pod del selector por node; si no hay nodes libres suficientes, las réplicas sobrantes no se programan hasta que aparezca capacidad nueva.

</details>
