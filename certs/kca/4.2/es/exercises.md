# KCA 4.2 — Selección de Recursos — Ejercicios Guiados

> **Dominio 4 · Tema 4.2 · Peso en el examen 3.33%**
> Seleccionar objetos y nodos de Kubernetes con **labels**, **label selectors** (basados en igualdad y en conjuntos), y **field selectors** — y entender cómo esos mismos selectores *vinculan* objetos en tiempo de ejecución (Service → Pods, controlador → Pods, Pod → Node). Al terminar deberías poder explicar *por qué* un Service tiene cero endpoints, *por qué* un Deployment rechaza un `kubectl apply`, y *por qué* un Pod queda en `Pending`.
>
> **Fuentes**
> - Labels and Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
> - Field Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
> - Referencia de `kubectl get` — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_get/
> - Service (selector → EndpointSlice) — https://kubernetes.io/docs/concepts/services-networking/service/
> - Assigning Pods to Nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
> - Deployment `.spec.selector` — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#selector

---

## Prerequisitos

Cualquier cluster de un solo nodo sirve (`kind`, `minikube`, o un cluster de laboratorio). Verificá:

```console
$ kubectl version --output=json | grep -m1 gitVersion
    "gitVersion": "v1.31.0",
$ kubectl get nodes
NAME                 STATUS   ROLES           AGE   VERSION
kind-control-plane   Ready    control-plane   9m    v1.31.0
```

Trabajá en un namespace descartable para que la limpieza sea trivial:

```console
$ kubectl create namespace rs-lab
namespace/rs-lab created
$ kubectl config set-context --current --namespace=rs-lab
Context "kind-kind" modified.
```

---

## Ejercicio 1 — Labels y selectores basados en igualdad

Los labels son la **única** dimensión de consulta de primera clase que el API server indexa para metadatos arbitrarios del usuario. Un selector es un filtro *ANDeado* a través de sus términos; nunca hace OR.

1. Creá tres Pods con conjuntos de labels solapados:

   ```console
   $ kubectl run web-a  --image=nginx:1.27 --labels="app=web,tier=frontend,env=prod"
   $ kubectl run web-b  --image=nginx:1.27 --labels="app=web,tier=frontend,env=qa"
   $ kubectl run api-a  --image=nginx:1.27 --labels="app=api,tier=backend,env=prod"
   ```

2. Listá los labels como columnas:

   ```console
   $ kubectl get pods --show-labels
   NAME    READY   STATUS    RESTARTS   AGE   LABELS
   api-a   1/1     Running   0          20s   app=api,env=prod,tier=backend
   web-a   1/1     Running   0          25s   app=web,env=prod,tier=frontend
   web-b   1/1     Running   0          22s   app=web,env=qa,tier=frontend
   ```

3. Filtrá con un selector basado en igualdad (`-l` / `--selector`). Notá que la coma es un **AND** lógico:

   ```console
   $ kubectl get pods -l app=web,env=prod
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          40s
   ```

4. Usá desigualdad (`!=`) y promové un label a columna con `-L`:

   ```console
   $ kubectl get pods -l 'env!=qa' -L tier
   NAME    READY   STATUS    RESTARTS   AGE   TIER
   api-a   1/1     Running   0          55s   backend
   web-a   1/1     Running   0          60s   frontend
   ```

5. Modificá un label en el lugar y volvé a consultar. `--overwrite` es obligatorio para cambiar una clave existente:

   ```console
   $ kubectl label pod web-b env=prod --overwrite
   pod/web-b labeled
   $ kubectl get pods -l app=web,env=prod
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          75s
   web-b   1/1     Running   0          72s
   ```

**Verificación de comprensión 1**
- **1a.** En el paso 3, ¿por qué `-l app=web,env=prod` devuelve solo `web-a` y no `web-b`, aunque ambos son `app=web`?
- **1b.** ¿Qué pasa si ejecutás `kubectl label pod web-b env=stage` *sin* `--overwrite`, dado que `env` ya existe?
- **1c.** Querés "todos los Pods que sean `app=web` **o** `app=api`". ¿Puede un único selector basado en igualdad expresar eso? ¿Por qué sí o por qué no?

---

## Ejercicio 2 — Selectores basados en conjuntos

Los selectores basados en conjuntos agregan los operadores `in`, `notin`, `exists` (`key`), y `does-not-exist` (`!key`). Son estrictamente más expresivos que los basados en igualdad y son los que usan los controladores por debajo (`matchExpressions`).

1. `in` matchea un **conjunto** de valores (esto es lo más cercano a un OR):

   ```console
   $ kubectl get pods -l 'app in (web,api),env in (prod)'
   NAME    READY   STATUS    RESTARTS   AGE
   api-a   1/1     Running   0          2m
   web-a   1/1     Running   0          2m
   web-b   1/1     Running   0          2m
   ```

2. `notin` excluye un conjunto:

   ```console
   $ kubectl get pods -l 'tier notin (backend)'
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          2m
   web-b   1/1     Running   0          2m
   ```

3. Existencia (`key`) y no-existencia (`!key`). Agregá un Pod que carezca de `tier`, luego seleccioná según la *presencia* de la clave sin importar su valor:

   ```console
   $ kubectl run cache-a --image=redis:7 --labels="app=cache,env=prod"
   $ kubectl get pods -l 'tier'          # key exists, any value
   NAME    READY   STATUS    RESTARTS   AGE
   api-a   1/1     Running   0          3m
   web-a   1/1     Running   0          3m
   web-b   1/1     Running   0          3m
   $ kubectl get pods -l '!tier'         # key absent
   NAME      READY   STATUS    RESTARTS   AGE
   cache-a   1/1     Running   0          20s
   ```

4. Combiná términos basados en conjuntos y en igualdad en una sola expresión (siguen siendo ANDeados):

   ```console
   $ kubectl get pods -l 'app in (web,cache),env=prod,tier'
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          3m
   web-b   1/1     Running   0          3m
   ```

**Verificación de comprensión 2**
- **2a.** `cache-a` tiene `env=prod` y `app=cache`. ¿Por qué lo excluye el selector del paso 4 aunque satisface dos de los tres términos?
- **2b.** Reescribí `-l 'env!=qa'` (basado en igualdad) como un selector basado en conjuntos equivalente. ¿Son semánticamente idénticos para un Pod que **no** tiene ningún label `env`?
- **2c.** ¿Qué operadores de este ejercicio pueden aparecer dentro de un bloque `matchExpressions` de un selector de Deployment, y cuál es la palabra clave JSON de cada uno?

---

## Ejercicio 3 — Field selectors

Los label selectors consultan *metadatos asignados por el usuario*. Los **field selectors** consultan los *campos estructurales propios* del objeto (`status.phase`, `spec.nodeName`, `metadata.namespace`, …). El conjunto de campos seleccionables es fijo por tipo de recurso — no es JSONPath arbitrario.

1. Filtrá Pods por fase del ciclo de vida (un campo de `status`):

   ```console
   $ kubectl get pods --field-selector status.phase=Running
   NAME      READY   STATUS    RESTARTS   AGE
   api-a     1/1     Running   0          4m
   cache-a   1/1     Running   0          1m
   web-a     1/1     Running   0          4m
   web-b     1/1     Running   0          4m
   ```

2. Filtrá por objetivo de scheduling (`spec.nodeName`) y combiná términos con una coma (AND):

   ```console
   $ kubectl get pods --field-selector spec.nodeName=kind-control-plane,status.phase=Running -o name
   pod/api-a
   pod/cache-a
   pod/web-a
   pod/web-b
   ```

3. Los field selectors son la forma idiomática de filtrar **Events**, que no tienen labels útiles:

   ```console
   $ kubectl get events --field-selector type=Warning,involvedObject.kind=Pod
   LAST SEEN   TYPE      REASON      OBJECT        MESSAGE
   30s         Warning   BackOff     pod/broken    Back-off restarting failed container
   ```

4. Pedí un campo no soportado y leé el error — esto te enseña que el conjunto permitido se aplica del lado del servidor:

   ```console
   $ kubectl get pods --field-selector spec.containers[0].image=nginx:1.27
   Error from server (BadRequest): Unable to find "/v1, Resource=pods" that match label selector "", field selector "spec.containers[0].image=nginx:1.27": field label not supported: spec.containers[0].image
   ```

5. Los field selectors y los label selectors se componen — ambos se envían al API server y se ANDean ahí:

   ```console
   $ kubectl get pods -l app=web --field-selector status.phase=Running
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          5m
   web-b   1/1     Running   0          5m
   ```

**Verificación de comprensión 3**
- **3a.** ¿Por qué podés filtrar por `status.phase` pero *no* por `spec.containers[0].image` (paso 4)? ¿Dónde está definida esa lista de permitidos?
- **3b.** Un field selector y un label selector en el mismo `kubectl get` — ¿se evalúan como AND o como OR? ¿El filtrado ocurre en `kubectl` o en el API server?
- **3c.** ¿Por qué los field selectors son la herramienta recomendada para consultar Events, mientras que los labels se recomiendan para Pods?

---

## Ejercicio 4 — Selectores que *vinculan*: Service → Pods

El `.spec.selector` de un Service es un **mapa plano de labels** (igualdad implícita, todas las claves ANDeadas). El controlador de EndpointSlice lo resuelve continuamente a un conjunto de IPs de Pods listos. Si el selector no matchea nada, el Service no tiene backends — una caída silenciosa y extremadamente común.

1. Aplicá un Service cuyo selector matchee los Pods de frontend:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: rs-lab
   spec:
     selector:
       app: web
       tier: frontend
     ports:
       - name: http
         port: 80
         targetPort: 80
   ```

   ```console
   $ kubectl apply -f web-svc.yaml
   service/web created
   ```

2. Confirmá que el selector se resolvió a endpoints. Preferí EndpointSlices (el data plane moderno):

   ```console
   $ kubectl get endpointslices -l kubernetes.io/service-name=web
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
   web-abcde   IPv4          80      10.244.0.7,10.244.0.8   10s
   ```

3. Ahora **rompé** el selector — introducí un error de tipeo que ningún Pod satisface:

   ```console
   $ kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web","tier":"front-end"}}}'
   service/web patched
   $ kubectl get endpointslices -l kubernetes.io/service-name=web
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
   web-abcde   IPv4          80      <unset>     40s
   ```

4. Diagnosticá el conjunto de backends vacío como lo harías en producción. `kubectl describe` muestra los endpoints resueltos y el selector lado a lado:

   ```console
   $ kubectl describe svc web | egrep 'Selector|Endpoints'
   Selector:          app=web,tier=front-end
   Endpoints:
   ```

5. Restaurá el selector correcto y confirmá que los endpoints vuelven:

   ```console
   $ kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web","tier":"frontend"}}}'
   service/web patched
   $ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{.items[0].endpoints[*].addresses[0]}'
   10.244.0.7 10.244.0.8
   ```

**Verificación de comprensión 4**
- **4a.** El `.spec.selector` de un Service no puede expresar `matchExpressions` — solo un mapa plano. ¿Qué operador está usando implícitamente cada par clave/valor de ese mapa, y cómo se combinan varios pares?
- **4b.** En el paso 3 el Service todavía existe y tiene un ClusterIP estable, pero el tráfico hacia él falla. ¿Cuál es el síntoma exacto en tiempo de ejecución, y qué objeto inspeccionarías primero para confirmar la causa?
- **4c.** Dos de tus tres Pods `app=web` eran `frontend`; un tercer Pod es `app=web,tier=backend`. ¿El Service original del paso 1 le enviaría tráfico? Justificá usando la regla del ANDeo.

---

## Ejercicio 5 — Selectores de controladores: `matchLabels`, `matchExpressions`, inmutabilidad

Los Deployments/ReplicaSets/etc. usan un objeto **`LabelSelector`** (`matchLabels` + `matchExpressions`), que es mucho más expresivo que el mapa plano de un Service — y, en `apps/v1`, **inmutable después de la creación**. El selector es cómo el controlador *reclama la propiedad* de los Pods; cambiarlo dejaría huérfano al ReplicaSet actual.

1. Aplicá un Deployment cuyo selector use tanto `matchLabels` como `matchExpressions`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: shop
     namespace: rs-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: shop
       matchExpressions:
         - key: tier
           operator: In
           values: ["frontend", "backend"]
     template:
       metadata:
         labels:
           app: shop
           tier: frontend
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - containerPort: 80
   ```

   ```console
   $ kubectl apply -f shop-deploy.yaml
   deployment.apps/shop created
   $ kubectl get rs -l app=shop
   NAME              DESIRED   CURRENT   READY   AGE
   shop-7d9f6c8b5c   2         2         2       12s
   ```

2. Confirmá que el ReplicaSet heredó el mismo selector y está reclamando los Pods:

   ```console
   $ kubectl get pods -l 'app=shop,tier in (frontend,backend)' -o name
   pod/shop-7d9f6c8b5c-4nq2p
   pod/shop-7d9f6c8b5c-9xk7w
   ```

3. Intentá cambiar el selector — esto **debe fallar** en `apps/v1`:

   ```console
   $ kubectl patch deployment shop --type=merge \
       -p '{"spec":{"selector":{"matchLabels":{"app":"store"}}}}'
   The Deployment "shop" is invalid: spec.selector: Invalid value: ...: field is immutable
   ```

4. Verificá el mecanismo de protección: los labels del template **deben** satisfacer el selector. Intentá aplicar un Deployment cuyo template no matchee su propio selector:

   ```console
   $ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: bad, namespace: rs-lab }
   spec:
     replicas: 1
     selector: { matchLabels: { app: bad } }
     template:
       metadata: { labels: { app: WRONG } }
       spec: { containers: [ { name: c, image: nginx:1.27 } ] }
   EOF
   The Deployment "bad" is invalid: spec.template.metadata.labels: Invalid value: map[string]string{"app":"WRONG"}: `selector` does not match template `labels`
   ```

5. Observá el **orphaning** — el mecanismo contra el que protege la inmutabilidad del selector. Borrá el Deployment pero conservá sus Pods, y luego mirá cómo sobreviven porque nada los vuelve a seleccionar:

   ```console
   $ kubectl delete deployment shop --cascade=orphan
   deployment.apps "shop" deleted
   $ kubectl get pods -l app=shop
   NAME                    READY   STATUS    RESTARTS   AGE
   shop-7d9f6c8b5c-4nq2p   1/1     Running   0          3m
   shop-7d9f6c8b5c-9xk7w   1/1     Running   0          3m
   ```

**Verificación de comprensión 5**
- **5a.** ¿Por qué Kubernetes hace que `.spec.selector` sea inmutable en `apps/v1`? Describí el problema de propiedad que causaría un selector mutable usando el término "orphan".
- **5b.** En el paso 4, el API server rechazó el objeto *antes* de que se creara ningún Pod. ¿Qué invariante entre `.spec.selector` y `.spec.template.metadata.labels` se está aplicando, y por qué es necesaria para que el controlador funcione?
- **5c.** El selector de un Service es un mapa plano pero el de un Deployment es un `LabelSelector`. Dá una selección concreta que un Deployment pueda expresar y un Service no.

---

## Ejercicio 6 — Selección de nodo: `nodeSelector` y node affinity

La misma maquinaria de selectores decide *dónde* corre un Pod. `nodeSelector` es la forma más simple: un mapa plano de labels que un nodo **debe** tener. Node affinity es el superconjunto expresivo, basado en conjuntos (`In`, `NotIn`, `Exists`, …) con variantes `required` vs `preferred`.

1. Inspeccioná los labels incorporados de un nodo (existen sin que configures nada):

   ```console
   $ kubectl get node kind-control-plane -o jsonpath='{.metadata.labels}' | tr ',' '\n' | egrep 'os|hostname'
   "kubernetes.io/hostname":"kind-control-plane"
   "kubernetes.io/os":"linux"
   ```

2. Agregá un label de nodo personalizado que represente una clase de hardware:

   ```console
   $ kubectl label node kind-control-plane disktype=ssd
   node/kind-control-plane labeled
   ```

3. Programá un Pod que *requiera* ese label vía `nodeSelector`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: ssd-pod
     namespace: rs-lab
   spec:
     nodeSelector:
       disktype: ssd
       kubernetes.io/os: linux
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   ```console
   $ kubectl apply -f ssd-pod.yaml
   pod/ssd-pod created
   $ kubectl get pod ssd-pod -o wide
   NAME      READY   STATUS    RESTARTS   AGE   IP            NODE
   ssd-pod   1/1     Running   0          8s    10.244.0.9    kind-control-plane
   ```

4. Ahora exigí un label que **ningún nodo tiene**, y leé el veredicto del scheduler — este es el diagnóstico canónico de `Pending`-para siempre:

   ```console
   $ kubectl run gpu-pod --image=nginx:1.27 --overrides='{"spec":{"nodeSelector":{"disktype":"nvme"}}}'
   $ kubectl get pod gpu-pod
   NAME      READY   STATUS    RESTARTS   AGE
   gpu-pod   0/1     Pending   0          15s
   $ kubectl describe pod gpu-pod | sed -n '/Events/,$p'
   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  20s   default-scheduler  0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector.
   ```

5. Expresá la misma intención con **node affinity**, que — a diferencia de `nodeSelector` — soporta operadores basados en conjuntos:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: affinity-pod
     namespace: rs-lab
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: disktype
                   operator: In
                   values: ["ssd", "nvme"]
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   ```console
   $ kubectl apply -f affinity-pod.yaml
   pod/affinity-pod created
   $ kubectl get pod affinity-pod -o wide
   NAME           READY   STATUS    RESTARTS   AGE   NODE
   affinity-pod   1/1     Running   0          6s    kind-control-plane
   ```

**Verificación de comprensión 6**
- **6a.** En el paso 4 el Pod está en `Pending`, no en `Failed`. ¿Qué te dice ese estado sobre *cuándo* ocurre la selección y qué hace el scheduler cuando ningún nodo matchea?
- **6b.** `IgnoredDuringExecution` aparece en el nombre del campo de affinity. Si *quitaras* el label `disktype=ssd` del nodo *después* de que `ssd-pod` ya estaba corriendo, ¿sería desalojado el Pod? ¿Por qué?
- **6c.** Nombrá dos cosas que node affinity puede expresar y `nodeSelector` no.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1a.** Un selector de igualdad separado por comas es un **AND** lógico a través de todos los términos. `app=web,env=prod` requiere *tanto* `app=web` **como** `env=prod`. En ese punto del laboratorio `web-b` era `env=qa`, por lo que falló el segundo término. (Después del relabeleo del paso 5 también matchearía.)
- **1b.** Se rechaza. `kubectl label` se niega a cambiar una clave que ya existe a menos que pases `--overwrite`:
  `error: 'env' already has a value (prod), and --overwrite is false`. Esto previene el clobbering accidental de labels sobre los que los controladores podrían estar seleccionando.
- **1c.** No. Un único selector basado en igualdad solo puede ANDear términos; no tiene OR. "`app=web` **o** `app=api`" requiere un selector *basado en conjuntos*: `-l 'app in (web,api)'`. (Ver Ejercicio 2.)

### Ejercicio 2
- **2a.** Todos los términos de un selector son ANDeados sin importar el estilo. `'app in (web,cache),env=prod,tier'` requiere que la clave `tier` **exista**. `cache-a` fue creado solo con `app` y `env`, así que falla el término `tier` (Exists) y queda excluido a pesar de matchear los otros dos.
- **2b.** `-l 'env!=qa'` ⇔ `-l 'env notin (qa)'`. **Sin embargo, difieren para un Pod que no tiene ningún label `env`.** Según la documentación, los operadores de igualdad `!=` y basado en conjuntos `notin` matchean objetos que tienen la clave con un valor distinto **y** objetos que *no* tienen la clave — es decir, ambos incluyen objetos sin ese label. (Contrastá con `=`/`in`, que requieren que la clave esté presente.) Así que en este caso específico son equivalentes, incluido para el Pod sin label. La trampa a recordar: `key!=value` **no** significa "tiene la clave con un valor distinto" — un objeto al que le falta la clave igual matchea.
- **2c.** `matchExpressions` soporta `In`, `NotIn`, `Exists`, `DoesNotExist` (las palabras clave JSON de `operator`). `in`→`In`, `notin`→`NotIn`, `key` (exists)→`Exists`, `!key`→`DoesNotExist`. La igualdad `=`/`==` mapea a `In` con un único valor.

### Ejercicio 3
- **3a.** El API server solo soporta field selectors sobre una **lista de permitidos fija, por recurso**, de campos (registrada en la estrategia de registry de cada tipo en el servidor), no JSONPath arbitrario hacia dentro del objeto. `metadata.name`, `metadata.namespace`, y unos pocos curados como `status.phase`, `spec.nodeName` están registrados para Pods; `spec.containers[0].image` no lo está, por lo que el servidor devuelve `field label not supported`.
- **3b.** **AND**, y el filtrado ocurre **del lado del servidor**. Ambos selectores se codifican en el query string de la petición `LIST`/`WATCH` y los evalúa el API server; `kubectl` no post-filtra. Por eso los selectores escalan — el servidor devuelve solo los objetos que matchean.
- **3c.** Los Events casi no llevan labels de usuario pero tienen campos estructurales ricos (`involvedObject.kind`, `involvedObject.name`, `type`, `reason`), así que los field selectors son el filtro natural. Los Pods, en cambio, están pensados para organizarse y consultarse por labels asignados por el usuario (`app`, `tier`, `env`), que es sobre lo que también seleccionan los controladores y los Services.

### Ejercicio 4
- **4a.** Cada par clave/valor en un `.spec.selector` de Service es una **igualdad implícita** (`key=value`), y los múltiples pares se combinan con **AND**. No hay sintaxis basada en conjuntos ni OR; un selector de Service es estrictamente un `map[string]string` plano.
- **4b.** El Service conserva su ClusterIP y su nombre DNS, pero su EndpointSlice tiene **cero direcciones listas**, así que kube-proxy no tiene a dónde reenviar — las conexiones expiran o son rechazadas sin backend. Inspeccioná el **EndpointSlice** (`kubectl get endpointslices -l kubernetes.io/service-name=<svc>`) o `kubectl describe svc` y confirmá que `Endpoints:` está vacío; luego compará el selector del Service con los labels reales del Pod.
- **4c.** No. El selector del paso 1 es `app=web` **AND** `tier=frontend`. Un Pod etiquetado `app=web,tier=backend` satisface el primer término pero falla el segundo, y como los términos se ANDean, queda excluido. Solo sería seleccionado si el selector del Service quitara el término `tier` o si el Pod se re-etiquetara `tier=frontend`.

### Ejercicio 5
- **5a.** Un Deployment reclama y administra Pods *por selector* (a través de su ReplicaSet). Si el selector pudiera cambiar, el controlador dejaría de matchear su ReplicaSet/Pods existentes — esos quedan **huérfanos** (corriendo pero no administrados), mientras el controlador levanta un conjunto nuevo para satisfacer el nuevo selector, duplicando silenciosamente la carga de trabajo y filtrando los Pods viejos. `apps/v1` hace que `.spec.selector` sea inmutable para hacer imposible esta clase de accidente; el camino soportado es crear un nuevo Deployment.
- **5b.** La invariante es que `.spec.template.metadata.labels` **debe ser un superconjunto que satisfaga `.spec.selector`**. Si los Pods que estampa un controlador no llevaran labels que matcheen su propio selector, el controlador crearía Pods que luego no puede seleccionar/poseer — entraría en un loop infinito, sin contarlos nunca hacia `replicas`. El API server rechaza el objeto de entrada para prevenir eso.
- **5c.** Un Service solo puede ANDear pares de igualdad. Un `LabelSelector` de Deployment puede usar `matchExpressions` con operadores basados en conjuntos — p. ej. `tier In (frontend, backend)`, o `Exists`/`DoesNotExist` sobre una clave — que ningún selector de Service puede expresar.

### Ejercicio 6
- **6a.** `Pending` significa que el Pod es un objeto de la API válido y persistido que **todavía no ha sido vinculado a un nodo**. La selección de nodo ocurre en **tiempo de scheduling**: el scheduler filtra los nodos según el `nodeSelector`/affinity del Pod, no encuentra ninguno factible, emite un evento `FailedScheduling`, y vuelve a encolar el Pod. Nunca "falla" — espera indefinidamente a que aparezca un nodo que satisfaga el selector (p. ej. etiquetando un nodo o mediante cluster autoscaling).
- **6b.** No, sigue corriendo. `requiredDuringSchedulingIgnoredDuringExecution` aplica la regla **solo en tiempo de scheduling**; la mitad `IgnoredDuringExecution` significa que los cambios de labels en el nodo posteriores se ignoran para los Pods que ya están corriendo. Quitar `disktype=ssd` bloquearía el *futuro* scheduling de tales Pods pero nunca desalojaría al actual. (Una variante de desalojo-al-cambiar — `RequiredDuringExecution` — no está implementada.)
- **6c.** Cualquier dos de: (1) operadores basados en conjuntos (`In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`) en lugar de solo igualdad; (2) reglas **soft/preferred** (`preferredDuringScheduling…`) con pesos, mientras que `nodeSelector` es estrictamente hard/required; (3) múltiples `nodeSelectorTerms` OReados entre sí (los términos son OR, los `matchExpressions` dentro de un término son AND), dando disyunciones que `nodeSelector` no puede expresar.

</details>

---

## Limpieza

```console
$ kubectl delete namespace rs-lab
$ kubectl label node kind-control-plane disktype-
$ kubectl config set-context --current --namespace=default