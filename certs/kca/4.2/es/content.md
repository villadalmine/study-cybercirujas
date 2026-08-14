# 4.2 Selección de Recursos

> **Dominio 4 · Peso del examen: 3.33** · Perfil SRE avanzado / Arquitecto de Plataforma
>
> La *selección* es la abstracción portante del plano de control de Kubernetes. Casi nada en Kubernetes referencia a otro objeto por nombre o IP — los controllers, Services, políticas y schedulers descubren todos los recursos sobre los que actúan *haciendo coincidir* criterios declarativos. Este tema cubre los tres subsistemas de selección distintos y los modos de fallo que cada uno produce en producción: **label selectors** (seleccionar objetos por identidad), **field selectors** (seleccionar objetos por su estado en vivo), y **selección de node/topology** (seleccionar *dónde* aterrizan los recursos de una carga de trabajo).

---

## 1. Motivación: el problema arquitectónico que resuelve la selección

### 1.1 Por qué nada referencia a nada por nombre

Un orquestador ingenuo dejaría que un balanceador de carga apuntara a una lista fija de IPs de backend. En un cluster donde los Pods son ganado — creados, matados, reprogramados en nodos nuevos con IPs nuevas docenas de veces por hora por los bucles de control del Deployment y del node-autoscaler — esa lista fija queda obsoleta en segundos. Cada controller necesitaría ser notificado en cada evento del ciclo de vida de un Pod, y el acoplamiento entre un Service y sus backends sería una dependencia dura y frágil.

Kubernetes invierte esto con **acoplamiento débil a través de la selección**. Un Service no sabe qué Pods lo sirven; declara un *predicado* (`selector: app=web`) y un controller reconcilia continuamente la realidad contra ese predicado. Se agrega un Pod que coincide → se une al conjunto de backends. Se elimina uno → sale. Sin editar el Service, sin reinicio, sin cableado de notificación. El mismo patrón impulsa:

| Consumidor | Qué selecciona | Mecanismo de selección |
|---|---|---|
| `Service` | Pods Ready para balancear la carga | `.spec.selector` (mapa de igualdad) → EndpointSlices |
| `Deployment` / `ReplicaSet` / `DaemonSet` / `StatefulSet` | Pods que posee y cuenta | `.spec.selector.matchLabels` / `matchExpressions` |
| `NetworkPolicy` | Pods a los que se aplica la política; peers permitidos | `podSelector`, `namespaceSelector` |
| `PodDisruptionBudget` | Pods cuyos desalojos voluntarios regula | `.spec.selector` |
| Pod (anti-)affinity | Peers Pods con los que colocarse / evitar | `labelSelector` + `topologyKey` |
| `topologySpreadConstraints` | Pods a distribuir de forma pareja | `labelSelector` + `topologyKey` |
| Ajuste de nodo del scheduler | Nodos a los que un Pod puede vincularse | `nodeSelector`, `nodeAffinity` |
| `kubectl` / operators | Cualquier conjunto de objetos sobre el que operar | `-l` / `--field-selector` |

El incidente de producción recurrente que este diseño *previene* es "el balanceador de carga está apuntando a backends muertos". El incidente recurrente que *introduce* es el **selector drift**: una discrepancia de un solo carácter entre un selector y las labels que se suponía que debía coincidir produce silenciosamente un conjunto vacío. Un Service con un selector que no coincide no da error — devuelve cero endpoints y todos los clientes reciben connection-refused. Aprender a diagnosticar eso (§5) es el núcleo práctico de este tema.

### 1.2 Los tres ejes de la "selección de recursos"

El término está sobrecargado. Mantené estos separados — usan sintaxis diferente, operadores diferentes, y fallan de forma diferente:

| Eje | Pregunta que responde | Superficie de API primaria | Backend |
|---|---|---|---|
| **Selección de objetos** | *¿Sobre qué objetos actúa este controller/política?* | Label selectors | Watch cache, indexado por labels |
| **Selección de estado** | *¿Qué objetos están actualmente en el estado X?* | Field selectors | Índices de campo del apiserver |
| **Selección de ubicación** | *¿En qué node / topology deben aterrizar los recursos de este Pod?* | `nodeSelector`, node affinity, topology spread | Filtro+puntuación del kube-scheduler |

---

## 2. Label selectors — seleccionar objetos por identidad

Las labels son metadatos clave/valor (`app=web`, `tier=frontend`); un **label selector** es una consulta sobre ellas. Hay dos gramáticas.

### 2.1 Basado en igualdad vs basado en conjuntos

```
# Equality-based (operators: = , == , != ; comma = logical AND)
environment = production
tier != frontend
environment=production,tier=frontend            # AND of both

# Set-based (operators: in , notin , exists / !exists)
environment in (production, qa)
tier notin (frontend, backend)
partition                                         # key exists (any value)
!partition                                        # key does NOT exist
environment in (production),!canary               # AND: in-set AND key absent
```

Ambas gramáticas pueden mezclarse en una única cadena `kubectl -l`. `=` y `==` son sinónimos.

| | Basado en igualdad | Basado en conjuntos |
|---|---|---|
| Operadores | `=`, `==`, `!=` | `In`, `NotIn`, `Exists`, `DoesNotExist` |
| Coincidencia multi-valor | ✗ (un valor por clave) | ✓ (`In (a, b, c)`) |
| Prueba de existencia | ✗ | ✓ (`Exists` / `DoesNotExist`) |
| Soportado por `Service`, `ReplicationController` legacy | ✓ (solo esto) | ✗ |
| Soportado por `Deployment`, `ReplicaSet`, `DaemonSet`, `Job`, `NetworkPolicy`, PDB, affinity | ✓ | ✓ |
| Semántica de valor vacío | `key=` coincide con la cadena vacía | `In ("")` coincide con la cadena vacía |

**Regla general:** un `Service.spec.selector` es un *mapa*, así que es solo de igualdad y cada entrada se une con AND. Todo lo moderno (`.spec.selector` en los workload controllers) usa el objeto estructurado `LabelSelector` que soporta ambos.

### 2.2 El objeto estructurado `LabelSelector`

Los controllers modernos no usan la cadena plana. Usan `matchLabels` (mapa, igualdad, unido con AND) más `matchExpressions` (lista, basado en conjuntos, unido con AND), y los dos bloques a su vez se unen con AND:

```yaml
selector:
  matchLabels:
    app: web              # app == web  AND
  matchExpressions:
    - key: tier           # tier ∈ {frontend, edge}  AND
      operator: In
      values: [frontend, edge]
    - key: track          # track ∉ {canary}  AND
      operator: NotIn
      values: [canary]
    - key: temporary      # label "temporary" must NOT exist
      operator: DoesNotExist
```

Semántica que muerde a la gente:

- `operator: Exists` / `DoesNotExist` **requieren que `values` esté vacío u omitido**. Suministrar valores → error de validación de la API.
- `operator: In` / `NotIn` **requieren una lista `values` no vacía**.
- `matchLabels: {app: web}` es exactamente equivalente a una entrada de `matchExpressions` `{key: app, operator: In, values: [web]}`.
- Un **selector vacío** se comporta de forma diferente según el contexto y es la fuente individual más común de sorpresa:

| Valor de selector vacío | Significado |
|---|---|
| `selector: {}` en un Deployment/ReplicaSet | Selecciona **todos** los Pods del namespace — peligroso, usualmente rechazado porque no puede coincidir con el template de forma única |
| `podSelector: {}` en un `spec` de NetworkPolicy | Selecciona **todos** los Pods del namespace de la política (idioma intencional para "default deny/allow all") |
| `spec.selector` ausente en un Service | El Service es **headless/manual** — sin EndpointSlices auto-poblados; gestionás los Endpoints vos mismo o es `ExternalName` |
| `namespaceSelector: {}` en NetworkPolicy | Selecciona **todos los namespaces** |

### 2.3 Dos invariantes que el apiserver impone sobre los workload controllers

1. **`.spec.selector` debe coincidir con `.spec.template.metadata.labels`.** El controller debe poder seleccionar los Pods que estampa. Si las labels del template no satisfacen el selector, se rechaza el create/update.
2. **`.spec.selector` es inmutable** en `Deployment`, `ReplicaSet`, `StatefulSet` y `DaemonSet` (`apps/v1`). No podés re-apuntar un controller existente a un conjunto de Pods diferente — tenés que eliminar y recrear. Esto existe precisamente para impedir que un controller silenciosamente deje huérfanos a sus Pods en ejecución y adopte un conjunto no relacionado.

Ambos se demuestran como fallos en §5.

---

## 3. Manifiestos completos, de grado producción

### 3.1 Deployment con un selector preciso basado en conjuntos

Un Deployment consciente de canary que posee solo Pods `web` del track estable y se niega a adoptar Pods canary que comparten la label `app`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: storefront
  labels:
    app: web
    track: stable
spec:
  replicas: 4
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: web
    matchExpressions:
      - key: track
        operator: In
        values: [stable]        # this Deployment owns ONLY stable-track pods
  template:
    metadata:
      labels:
        app: web                # must satisfy selector above...
        track: stable           # ...including this
        tier: frontend
    spec:
      containers:
        - name: web
          image: registry.k8s.io/nginx-slim:0.27
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "250m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          readinessProbe:        # <-- gates EndpointSlice membership (§3.2)
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 3
```

### 3.2 Service seleccionando los mismos Pods — y por qué importa la readiness

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: storefront
spec:
  selector:
    app: web
    tier: frontend            # equality map: app==web AND tier==frontend
  ports:
    - name: http
      port: 80
      targetPort: 8080
  # NOTE: no set-based selectors here — Service.spec.selector is equality-only.
  # It will select BOTH stable and canary web pods if both carry tier=frontend.
```

El EndpointSlice controller agrega un Pod a las EndpointSlices de este Service solo cuando el Pod **coincide con el selector Y está `Ready`** (readiness probe pasando). Un Pod que coincide pero no está Ready está presente en la slice con `conditions.ready: false` y no recibe tráfico. Por esto un selector puede ser *correcto* y el conjunto de endpoints seguir vacío — cada Pod que coincide está fallando la readiness.

### 3.3 NetworkPolicy — tres selectors, tres roles

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-from-gateway
  namespace: storefront
spec:
  podSelector:                 # role 1: which pods THIS policy governs
    matchLabels:
      app: web
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:   # role 2: source namespaces...
            matchLabels:
              kubernetes.io/metadata.name: ingress-system
          podSelector:         # role 3: ...AND source pods within them
            matchLabels:
              app: gateway
      ports:
        - protocol: TCP
          port: 8080
```

Semántica crítica: dentro de un único elemento `from`, `namespaceSelector` y `podSelector` se unen con **AND** (Pods gateway *en* ingress-system). Divididos entre dos ítems de lista `-` se unirían con **OR**. Esta distinción AND/OR es una trampa de examen de primer nivel y un agujero de política en el mundo real.

### 3.4 Selección de ubicación — node affinity + topology spread + anti-affinity

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: storefront
spec:
  replicas: 6
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:   # HARD filter
            nodeSelectorTerms:
              - matchExpressions:                            # terms are ORed;
                  - key: topology.kubernetes.io/zone         # exprs within a term ANDed
                    operator: In
                    values: [us-east-1a, us-east-1b]
                  - key: node.kubernetes.io/instance-type
                    operator: NotIn
                    values: [t3.micro]
          preferredDuringSchedulingIgnoredDuringExecution:  # SOFT score
            - weight: 80
              preference:
                matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values: [amd64]
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: web }
              topologyKey: kubernetes.io/hostname            # ≤1 web pod per node
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: web }                        # spread THESE pods evenly
      containers:
        - name: web
          image: registry.k8s.io/nginx-slim:0.27
          resources:
            requests: { cpu: "250m", memory: "128Mi" }
```

| Primitiva de ubicación | Operadores | Duro/blando | Selecciona |
|---|---|---|---|
| `nodeSelector` | solo igualdad | duro | nodos por label |
| `nodeAffinity.required…` | In/NotIn/Exists/DoesNotExist/**Gt/Lt** | duro | nodos por expresión (Gt/Lt habilitan coincidencias numéricas) |
| `nodeAffinity.preferred…` | igual + `weight` 1–100 | blando | nodos, ponderados |
| `podAffinity`/`podAntiAffinity` | label selector + `topologyKey` | duro o blando | dominios de topology que contienen Pods coincidentes |
| `topologySpreadConstraints` | label selector + `topologyKey` + `maxSkew` | `DoNotSchedule` (duro) / `ScheduleAnyway` (blando) | distribución pareja de Pods coincidentes |

`nodeName` es la vía de escape: establecer `.spec.nodeName` vincula el Pod directamente y **saltea el scheduler por completo** — sin filtrado, sin affinity, sin verificación de ajuste de recursos. Usar solo para depuración o pods estáticos tipo DaemonSet.

---

## 4. Field selectors — seleccionar objetos por su estado en vivo

Los field selectors consultan **valores de campos de recursos**, no labels. Son evaluados por el apiserver contra una *lista de permitidos fija, por recurso* de campos indexados — no podés seleccionar sobre un campo arbitrario.

```
# Universal (all resource types):
metadata.name
metadata.namespace

# Pods (the richest set):
status.phase          spec.nodeName          spec.schedulerName
status.podIP          spec.serviceAccountName spec.restartPolicy
status.nominatedNodeName

# Nodes:
metadata.name         spec.unschedulable

# Events:
involvedObject.kind   involvedObject.name    reason    type    source
```

Los operadores son **solo `=`, `==`, `!=`** — sin basado en conjuntos, sin `Gt`/`Lt`. Coma = AND.

| | Label selector (`-l`) | Field selector (`--field-selector`) |
|---|---|---|
| Consulta | `metadata.labels` | un conjunto curado de campos spec/status |
| Operadores | igualdad **y** basado en conjuntos | solo igualdad |
| Extensible | ✓ (agregar cualquier label) | ✗ (lista fija por recurso) |
| Uso típico | "¿qué app/tier?" (identidad) | "¿cuáles están Running / en el nodo X?" (estado) |
| Filtrado del lado del servidor | ✓ | ✓ |

Intentar un campo no soportado devuelve un error duro, p. ej. `field label not supported: status.hostIP`. Esto es deliberado: los campos no indexados forzarían escaneos de colección completa.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Base: inspeccionar labels y seleccionar objetos

```console
$ kubectl get pods -n storefront --show-labels
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m    app=web,pod-template-hash=6c9f7b8d4,tier=frontend,track=stable
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m    app=web,pod-template-hash=6c9f7b8d4,tier=frontend,track=stable
web-canary-79bd-abc    1/1     Running   0          3m    app=web,pod-template-hash=79bd0,tier=frontend,track=canary

# Equality-based, ANDed:
$ kubectl get pods -n storefront -l 'app=web,track=stable'
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m

# Set-based — everything on a non-canary track:
$ kubectl get pods -n storefront -l 'app=web,track notin (canary)'
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
web-6c9f7b8d4-5pl2m    1/1     Running   0          9m

# Project label values as columns with -L:
$ kubectl get pods -n storefront -L track,tier
NAME                   READY   STATUS    RESTARTS   AGE   TRACK    TIER
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m    stable   frontend
web-canary-79bd-abc    1/1     Running   0          3m    canary   frontend
```

Combiná selección de label + field para responder "qué Pods estables están realmente Running en un nodo dado":

```console
$ kubectl get pods -n storefront \
    -l app=web,track=stable \
    --field-selector status.phase=Running,spec.nodeName=ip-10-0-1-23
NAME                   READY   STATUS    RESTARTS   AGE
web-6c9f7b8d4-2xk9p    1/1     Running   0          9m
```

### 5.2 El fallo de producción #1: Service con cero endpoints

Síntoma: los clientes reciben `connection refused` / `no route to host` al golpear un Service que "claramente existe".

```console
$ kubectl get endpoints web -n storefront
NAME   ENDPOINTS   AGE
web    <none>      6m                 # <-- red flag: no backends

$ kubectl get endpointslices -n storefront -l kubernetes.io/service-name=web
NAME         ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-abc12    IPv4          8080    <unset>     6m
```

Diagnosticá comparando el selector del Service contra las labels reales del Pod:

```console
$ kubectl get svc web -n storefront -o jsonpath='{.spec.selector}{"\n"}'
{"app":"web","tier":"frontend"}

$ kubectl get pods -n storefront -l app=web,tier=frontend
No resources found in storefront namespace.
```

El selector es `app=web,tier=frontend`, pero los Pods están etiquetados como `app=web,tier=web-frontend` — un desvío de una palabra. Dos verificaciones cruzadas:

```console
# Ask directly: does anything match the exact selector?
$ kubectl get pods -n storefront -l app=web,tier=frontend -o name
# (empty) -> selector matches nothing

# What DO the pods carry?
$ kubectl get pods -n storefront -l app=web -o \
    jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels.tier}{"\n"}{end}'
web-6c9f7b8d4-2xk9p  web-frontend
web-6c9f7b8d4-5pl2m  web-frontend
```

Corregí el lado que esté mal (aquí, re-etiquetá o arreglá el Service). Una segunda variante, más sutil: el selector coincide, pero cada Pod está **not Ready**, así que nunca entra en la slice:

```console
$ kubectl get endpointslices -n storefront -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses}{" ready="}{.conditions.ready}{"\n"}{end}'
["10.0.3.14"] ready=false
["10.0.3.15"] ready=false          # matched, but readiness probe failing -> no traffic
```

### 5.3 Discrepancia selector/template al crear

```console
$ kubectl apply -f web-deploy.yaml
The Deployment "web" is invalid: spec.template.metadata.labels: Invalid value:
map[string]string{"app":"web", "tier":"frontend"}: `selector` does not match
template `labels`
```

El `.spec.selector` requiere `track In [stable]`, pero el template del Pod omite `track`. El controller nunca podría seleccionar los Pods que crea → rechazado en admission. Solución: agregar `track: stable` a `template.metadata.labels`.

### 5.4 Inmutabilidad del selector

```console
$ kubectl patch deployment web -n storefront \
    --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":"webv2"}}}}'
The Deployment "web" is invalid: spec.selector: Invalid value:
v1.LabelSelector{...MatchLabels:map[string]string{"app":"webv2"}...}:
field is immutable
```

No podés re-apuntar un controller en vivo. Recrealo (`kubectl delete deployment web` y luego aplicá el nuevo), o ejecutá un Deployment nuevo en paralelo y desplazá el tráfico.

### 5.5 Pods huérfanos / adoptados por selectors superpuestos

Dos controllers cuyos selectors se superponen pelearán por los mismos Pods. Detectá la propiedad vía `ownerReferences`:

```console
$ kubectl get pod web-6c9f7b8d4-2xk9p -n storefront \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
ReplicaSet/web-6c9f7b8d4

# A pod with NO ownerReferences that still matches a selector is an ADOPTION risk:
$ kubectl get pods -n storefront -l app=web \
    -o jsonpath='{range .items[*]}{.metadata.name}{" owner="}{.metadata.ownerReferences[0].name}{"\n"}{end}'
web-6c9f7b8d4-2xk9p  owner=web-6c9f7b8d4
legacy-web-manual    owner=            # <-- bare pod matching selector -> may be adopted/counted
```

Un Pod desnudo que lleva `app=web` será **contado por** el ReplicaSet del Deployment (coincide con el selector) y hasta puede ser escalado hacia abajo como si fuera una réplica. Protegete contra esto con selectors más específicos (`track In [stable]`) y nunca ejecutes Pods desnudos que compartan las labels de identidad de una carga de trabajo.

### 5.6 La selección de ubicación no coincidió con ningún nodo

```console
$ kubectl get pod web-xxx -n storefront
NAME       READY   STATUS    RESTARTS   AGE
web-xxx    0/1     Pending   0          40s

$ kubectl describe pod web-xxx -n storefront | sed -n '/Events/,$p'
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  38s   default-scheduler  0/6 nodes are available:
           2 node(s) didn't match Pod's node affinity/selector,
           3 node(s) didn't match pod anti-affinity rules,
           1 Insufficient cpu. preemption: 0/6 nodes are available.
```

Leé el recuento literalmente: node-affinity eliminó 2, anti-affinity 3, ajuste de recursos 1. Verificá que las labels del nodo que la affinity esperaba realmente existan:

```console
$ kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
NAME            STATUS   ROLES    AGE   VERSION   ZONE         INSTANCE-TYPE
ip-10-0-1-23    Ready    <none>   21d   v1.31.4   us-east-1a   m5.large
ip-10-0-2-51    Ready    <none>   21d   v1.31.4   us-east-1c   m5.large   # <-- zone not in [1a,1b]
```

Aquí la affinity requería la zona `us-east-1a`/`1b`, pero la mitad de la flota está en `1c`, y la anti-affinity de hostname limita a un Pod por nodo — así que seis réplicas no pueden caber en dos nodos elegibles. Soluciones: ampliar los `values` de zona, relajar la anti-affinity de hostname a `preferred`, o agregar nodos con labels coincidentes.

### 5.7 Checklist de verificación

```console
# 1. Does the selector match the intended objects, and only those?
kubectl get pods -l '<selector>' -o name

# 2. For a Service, does selection resolve to Ready endpoints?
kubectl get endpointslices -l kubernetes.io/service-name=<svc> \
  -o custom-columns=SLICE:.metadata.name,READY:.endpoints[*].conditions.ready

# 3. Does the controller's selector match its own template?
kubectl get deploy <name> -o jsonpath='{.spec.selector}{"\n"}{.spec.template.metadata.labels}{"\n"}'

# 4. Any bare pods that a controller could adopt?
kubectl get pods -l '<controller-selector>' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences}{"\n"}{end}'

# 5. For placement failures, read the scheduler's per-reason node tally:
kubectl describe pod <name> | grep -A5 Events
```

---

## 6. Referencias

- Labels and Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Field Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
- LabelSelector API definition — https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/label-selector/
- Service (`spec.selector`, headless, endpoints) — https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices (readiness → membership) — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Deployments (selector immutability, template matching) — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet (adoption via selectors, `ownerReferences`) — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Assigning Pods to Nodes (`nodeSelector`, node affinity, inter-pod affinity) — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Network Policies (podSelector / namespaceSelector AND-vs-OR) — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Disruption Budget (`spec.selector`) — https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- kubectl reference (`-l`, `--field-selector`, `-L`, `--show-labels`) — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
- kubectl cheat sheet — https://kubernetes.io/docs/reference/kubectl/cheatsheet/