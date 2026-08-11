# 352.4 Plataformas de Orquestación de Contenedores

> **Contexto del examen** — LPIC-3 305-300, Tema 352, peso **5**. Este objetivo cubre la arquitectura de Kubernetes, los contratos de interfaz CRI/CNI/CSI, los objetos de carga de trabajo centrales (Pods, ReplicaSets, Deployments, Services, labels), `kubelet`/`kube-proxy`, Docker Swarm (services, tasks, nodes, stacks) y conocimiento de Helm, OpenShift, Rancher y OKD.

---

## 1. El problema arquitectónico: por qué existe la orquestación

Un único runtime de contenedores (`containerd`, Docker Engine, CRI-O) resuelve el *empaquetado y aislamiento en un solo host*. Responde a "ejecutá esta imagen con estos namespaces y cgroups". **No** responde a ninguna de las preguntas que una plataforma de producción realmente tiene:

- **Placement** — ¿cuál de mis 40 nodos tiene suficiente CPU/memoria asignable, la topología correcta (zona, GPU, SSD local) y ningún conflicto de anti-affinity?
- **Estado deseado** — pedí 6 réplicas; un nodo se murió y se llevó 2 de ellas. ¿Quién se da cuenta y quién las reemplaza?
- **Service discovery y balanceo de carga** — las réplicas son efímeras y obtienen IPs nuevas en cada reinicio. ¿Cómo llega un cliente al "servicio de pagos" sin conocer las IPs?
- **Rollout y rollback** — ¿cómo paso de `v1.4.2` a `v1.5.0` sin perder tráfico, y revierto en segundos cuando se dispara la tasa de errores?
- **Distribución de config y secrets** — ¿cómo obtienen 200 pods el mismo certificado TLS y la contraseña de la base de datos sin hornearlos en las imágenes?
- **Bin-packing y dominios de fallo** — ¿cómo mantengo alta la utilización *y* sobrevivo a la pérdida de un rack/zona?

La orquestación es el **control loop** que impulsa continuamente el estado observado del clúster hacia un estado deseado declarado. El modelo mental es un termostato, no un script: declarás `replicas: 6`, y los controllers *reconcilian* para siempre — ante la pérdida de un nodo, ante el crasheo de un proceso, ante un `kill` manual. Este es el concepto de producción más importante del objetivo:

```
        declare desired state (etcd)
                   │
                   ▼
   ┌──────────► reconcile loop ──────────┐
   │      (observe actual vs desired)     │
   │                                      ▼
observed state  ◄──────────────  act to close the gap
(kubelet, CRI, CNI)              (create/delete Pods, program routes)
```

Todo lo que sigue es una variación de este loop.

---

## 2. Arquitectura de Kubernetes

Un clúster de Kubernetes se divide en un **control plane** (el cerebro: decide *qué debe ser*) y **worker nodes** (el músculo: ejecutan los contenedores). El único componente con estado es `etcd`; todos los demás procesos del control plane son sin estado (stateless) y reconstruyen su vista observando el API server.

```
                       ┌──────────────────────── CONTROL PLANE ───────────────────────────┐
                       │                                                                    │
   kubectl / clients   │   ┌──────────────┐        ┌───────────────────────────────────┐   │
        │              │   │    etcd      │◄──────►│           kube-apiserver          │   │
        ▼   (HTTPS 6443)│   │ (raft, 2379) │        │  (REST, authN/authZ, admission,   │   │
   ┌─────────────┐      │   └──────────────┘        │   the ONLY thing that talks to etcd)│  │
   │ kube-apiserver│◄───┼──────────────────────────►└───────▲───────────▲──────────▲─────┘  │
   └─────────────┘      │                                   │ watch/act  │          │        │
                       │   ┌──────────────┐  ┌──────────────┴──┐  ┌──────┴───────┐  │        │
                       │   │ kube-scheduler│  │ kube-controller-│  │cloud-controller│ │       │
                       │   │  (binds Pod   │  │    manager      │  │   -manager    │ │        │
                       │   │   → Node)     │  │ (Node,ReplicaSet,│ │ (LB,routes,   │ │        │
                       │   └──────────────┘  │  Deployment,...) │  │  volumes)     │ │        │
                       │                     └─────────────────┘  └───────────────┘ │        │
                       └────────────────────────────────────────────────────────────┼───────┘
                                                                                     │
   ┌──────────────────────────── WORKER NODE (×N) ───────────────────────────────────┼──────┐
   │  ┌─────────┐   CRI    ┌───────────────┐   CNI    ┌──────────┐                    │      │
   │  │ kubelet │◄────────►│ container      │◄────────►│ CNI plugin│  (pod networking) │      │
   │  │(10250)  │ gRPC     │ runtime        │          └──────────┘                    │      │
   │  └────┬────┘          │(containerd/CRIO)│    CSI   ┌──────────┐                    │      │
   │       │               └───────────────┘◄────────►│CSI driver │  (volumes)         │      │
   │  ┌────▼─────┐                                     └──────────┘                    │      │
   │  │kube-proxy│  (programs iptables/IPVS/nftables for Service VIPs)                  │      │
   │  └──────────┘                                                                      │      │
   └────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Componentes del control plane

| Componente | Escucha en | Estado | Responsabilidad | Si se cae… |
|---|---|---|---|---|
| **kube-apiserver** | `:6443` (HTTPS) | Sin estado (escalable horizontalmente) | Puerta de entrada para todas las lecturas/escrituras; authN → authZ → admission → persistir en etcd. El **único** componente que toca etcd. | El clúster queda de solo lectura desde afuera; los Pods en ejecución siguen funcionando, pero no hay cambios ni auto-reparación. |
| **etcd** | `:2379` (cliente), `:2380` (peer) | **El** almacén con estado; replicado con Raft | Almacén clave-valor consistente y observable de todos los objetos del clúster. | Caída total del estado; pérdida de quorum = sin escrituras. Hacé backup. |
| **kube-scheduler** | `:10259` (HTTPS, métricas/health) | Sin estado | Observa Pods no programados, puntúa nodos (filters + priorities), escribe `.spec.nodeName`. | Los Pods nuevos quedan en `Pending`; los Pods existentes no se ven afectados. |
| **kube-controller-manager** | `:10257` | Sin estado (con elección de líder) | Ejecuta los controllers integrados: Node, ReplicaSet, Deployment, Job, EndpointSlice, ServiceAccount, etc. Cada uno es un reconcile loop. | La auto-reparación se detiene: los Pods muertos no se reemplazan, los Deployments no hacen roll. |
| **cloud-controller-manager** | `:10258` | Sin estado (con elección de líder) | Loops específicos de la nube: aprovisionar LoadBalancers, adjuntar volúmenes, etiquetar nodos con zona/tipo-de-instancia, eliminar objetos Node de VMs borradas. | Los LBs y rutas de la nube dejan de reconciliarse. |

**Punto clave del examen — todo pasa por el API server.** El `kubelet` no lee etcd. El scheduler no lee etcd. Todos hacen `watch` al API server, y el API server serializa a etcd. Por eso el API server es el límite de confianza (RBAC, admission webhooks, quotas) y el cuello de botella de escalado.

**Detalles internos de etcd que vale la pena conocer para producción:**
- Consenso vía **Raft**; necesitás un número **impar** de miembros (3 o 5) para que un quorum (`N/2 + 1`) sobreviva a los fallos. 3 miembros toleran 1 pérdida; 5 toleran 2.
- Los objetos se almacenan bajo claves como `/registry/pods/<namespace>/<name>` en formato Protobuf.
- El límite de tamaño de la base de datos por defecto es **2 GiB** (`--quota-backend-bytes`); superarlo pone a etcd en un estado de alarma de solo lectura — un incidente de producción clásico. Compactá y desfragmentá según un cronograma.

### 2.2 Componentes de nodo

- **kubelet** — el agente del nodo. *No* es un controller en el sentido del API; es lo que hace que la realidad coincida con una spec de Pod en **su** nodo. Observa el API server en busca de Pods asignados a su `nodeName`, llama a la **CRI** para crear sandboxes y contenedores, invoca la **CNI** para conectar la red, monta volúmenes vía **CSI**, ejecuta probes (liveness/readiness/startup) y reporta el estado del nodo/Pod. También gestiona Pods estáticos desde `/etc/kubernetes/manifests` (así se bootstrapea el propio control plane en `kubeadm`).
- **kube-proxy** — implementa la abstracción *Service* en cada nodo. Observa Services y EndpointSlices y programa el dataplane del kernel para que el tráfico hacia un `ClusterIP:port` de un Service sea DNAT'd/balanceado hacia una IP de Pod backend saludable. Modos: `iptables` (por defecto, cadenas de reglas O(n)), `IPVS` (tablas hash, escala a miles de Services) y el más nuevo `nftables`. Nota: con dataplanes eBPF (Cilium), kube-proxy puede ser *reemplazado* por completo.
- **container runtime** — la implementación de CRI (`containerd`, `CRI-O`) que realmente crea los contenedores vía un runtime OCI (`runc`, `crun`, `gVisor`, `Kata`).

---

## 3. Los contratos de interfaz: CRI, CNI, CSI

Kubernetes deliberadamente no implementa el runtime, la red ni el almacenamiento. Define **tres contratos enchufables (pluggable)** para que los proveedores compitan detrás de interfaces estables. Este es el objetivo "entender el rol de CRI/CNI/CSI", y se evalúa mucho.

| Interfaz | Nombre completo | Transporte | Consumidor | Ubicación de la config | Implementaciones de ejemplo |
|---|---|---|---|---|---|
| **CRI** | Container Runtime Interface | **gRPC** sobre un socket Unix | `kubelet` | `--container-runtime-endpoint` | containerd, CRI-O, (Docker vía cri-dockerd) |
| **CNI** | Container Network Interface | **exec** de un binario + JSON en stdin/stdout | kubelet/runtime | `/etc/cni/net.d/*.conf`, binarios en `/opt/cni/bin` | Calico, Cilium, Flannel, Weave, AWS VPC CNI |
| **CSI** | Container Storage Interface | **gRPC** (sidecar + driver de nodo) | kube-controller-manager + kubelet | `Deployment`/`DaemonSet` del driver + `StorageClass` | AWS EBS, Ceph-CSI, Longhorn, local-path |

### 3.1 CRI — y la eliminación de dockershim

El kubelet habla CRI (dos servicios gRPC: `RuntimeService` e `ImageService`) hacia un socket:

```
$ crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  1.7.13
RuntimeApiVersion:  v1
```

**Trampa histórica del examen:** el kubelet originalmente trataba a Docker Engine como caso especial mediante un adaptador in-tree llamado **dockershim**. Como Docker Engine no es nativo de CRI, dockershim fue **deprecado en Kubernetes 1.20 y eliminado en 1.24** (diciembre de 2021 / mayo de 2022). Las *imágenes* de Docker (OCI) siguen funcionando bien — simplemente apuntás el kubelet a `containerd` (que Docker usa por debajo) o instalás `cri-dockerd`. "Kubernetes eliminó Docker" siempre significó únicamente "eliminó dockershim".

El stack del runtime, de arriba hacia abajo:

```
kubelet ──CRI/gRPC──► containerd ──OCI──► runc ──clone(2)/cgroups──► your container
```

### 3.2 CNI — la red de pods

La CNI se invoca como un **binario**, no como una llamada a un daemon: el runtime hace exec de `/opt/cni/bin/<plugin>` con una config JSON en stdin y el verbo (`ADD`/`DEL`/`CHECK`) en una variable de entorno, y el plugin devuelve la IP asignada como JSON. El modelo de red de Kubernetes exige tres invariantes: **cada Pod obtiene su propia IP, todos los Pods pueden alcanzar a todos los Pods sin NAT, y el nodo puede alcanzar a todos los Pods**.

| Plugin | Dataplane | Encapsulación | NetworkPolicy | Destacado por |
|---|---|---|---|---|
| **Flannel** | Linux bridge | VXLAN (overlay) | ❌ (necesita add-on) | Simplicidad; clústeres de desarrollo |
| **Calico** | iptables/eBPF | Ninguna (BGP) o VXLAN/IPIP | ✅ (rica, incl. global) | Nativo de BGP, rendimiento sin overlay, política madura |
| **Cilium** | **eBPF** | VXLAN/Geneve o nativa | ✅ (L3–L7, basada en identidad) | Dataplane eBPF, reemplazo de kube-proxy, observabilidad con Hubble |
| **Weave Net** | userspace/kernel | VXLAN | ✅ | Facilidad de uso (proyecto ahora EOL) |
| **AWS VPC CNI** | ENIs nativas de VPC | Ninguna (IPs reales de VPC) | vía Calico | Los Pods obtienen IPs enrutables de la VPC |

Una config de CNI mínima en disco:

```json
{
  "cniVersion": "1.0.0",
  "name": "k8s-pod-network",
  "plugins": [
    {
      "type": "calico",
      "datastore_type": "kubernetes",
      "ipam": { "type": "calico-ipam" },
      "policy": { "type": "k8s" },
      "kubernetes": { "kubeconfig": "/etc/cni/net.d/calico-kubeconfig" }
    },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

Un clúster **sin** CNI instalada deja a cada nodo en `NotReady` y a los Pods atascados en `ContainerCreating` — el incidente de "el clúster nuevo no arranca" más común.

### 3.3 CSI — almacenamiento

CSI desacopla el ciclo de vida del volumen (aprovisionar, adjuntar, montar, snapshot, redimensionar) del núcleo de Kubernetes. Un driver se despacha como un **Deployment controller** (con los sidecars `external-provisioner`, `external-attacher`, `external-resizer`) más un **DaemonSet de nodo**. Los consumidores declaran una `StorageClass`; un `PersistentVolumeClaim` dispara el aprovisionamiento dinámico de un `PersistentVolume`.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com          # the CSI driver name
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer   # bind PV in the same zone as the scheduled Pod
```

---

## 4. Objetos de carga de trabajo centrales

El objetivo nombra **Pods, Services, ReplicaSets, Deployments y labels**. Entendelos como un stack en capas, cada una agregando una capacidad:

```
Deployment  ─ declarative rollout, rollback, revision history
   └─ owns ReplicaSet(s)  ─ maintains N identical Pod replicas
          └─ owns Pods    ─ smallest schedulable unit (1+ containers, shared net/IPC/volumes)
Service     ─ stable VIP + DNS + load-balancing over a label-selected set of Pods
Labels      ─ the glue: selectors on every object above resolve to a set of Pods
```

### 4.1 Pod — el átomo

Un Pod es un conjunto de contenedores co-programados que comparten un namespace de red (una IP, `localhost` compartido), IPC y volúmenes. El ciclo de vida es `Pending → Running → Succeeded/Failed`, gobernado por init containers, probes y restart policy.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-probe-demo
  labels:
    app: web
    tier: frontend
spec:
  # An init container runs to completion BEFORE app containers start.
  initContainers:
    - name: wait-for-db
      image: busybox:1.36
      command: ['sh', '-c', 'until nc -z db 5432; do echo waiting; sleep 2; done']
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
      resources:
        requests:            # used by the scheduler for bin-packing
          cpu: "100m"
          memory: "128Mi"
        limits:              # enforced by the kubelet/cgroups; exceed mem => OOMKilled
          cpu: "500m"
          memory: "256Mi"
      livenessProbe:         # restart the container if this fails
        httpGet: { path: /healthz, port: 80 }
        initialDelaySeconds: 10
        periodSeconds: 10
        failureThreshold: 3
      readinessProbe:        # remove from Service endpoints if this fails (no restart)
        httpGet: { path: /ready, port: 80 }
        periodSeconds: 5
      startupProbe:          # protects slow-starting apps from the liveness probe
        httpGet: { path: /healthz, port: 80 }
        failureThreshold: 30
        periodSeconds: 10
  restartPolicy: Always
```

**Requests vs limits** es el knob de producción peor entendido: los `requests` impulsan la programación y son el piso garantizado; los `limits` son el techo impuesto por los cgroups. CPU por encima del límite → *throttled*; memoria por encima del límite → *OOMKilled*. Establecer `requests == limits` produce la clase de QoS `Guaranteed` (la última en ser desalojada bajo presión del nodo).

### 4.2 ReplicaSet — el mantenedor de réplicas

Rara vez se crea directamente, pero es el reconcile loop detrás de los Deployments: mantener exactamente `.spec.replicas` Pods que coincidan con `.spec.selector` vivos.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:                # a Pod template; label MUST satisfy the selector
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
```

El selector es **inmutable** y basado en labels — por esto los labels son un objetivo de primera clase. Si un Pod suelto casualmente lleva `app: web`, el ReplicaSet lo *adoptará* y lo contará dentro del total de réplicas.

### 4.3 Deployment — rollouts declarativos

El objeto que casi siempre usás. Gestiona ReplicaSets para darte actualizaciones progresivas (rolling updates), historial de revisiones y rollback con un solo comando.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 4
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1      # at most 1 Pod down during the roll
      maxSurge: 1            # at most 1 extra Pod above desired during the roll
  minReadySeconds: 10
  template:
    metadata:
      labels:
        app: web
    spec:
      topologySpreadConstraints:      # spread replicas across zones for fault tolerance
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: web }
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: { path: /, port: 80 }
            periodSeconds: 5
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
```

**Mecánica del rollout:** ante un cambio en el template, el Deployment controller crea un ReplicaSet *nuevo* y lo escala hacia arriba mientras escala el viejo hacia abajo, respetando `maxSurge`/`maxUnavailable`. El `readinessProbe` es lo que hace esto seguro — un Pod nuevo recibe tráfico solo una vez que está Ready. `revisionHistoryLimit` mantiene los ReplicaSets viejos (escalados a 0) para que `kubectl rollout undo` sea instantáneo.

### 4.4 Service — red estable

Los Pods son ganado (cattle): se mueren y obtienen IPs nuevas. Un Service da un **ClusterIP + nombre DNS estables** y balancea la carga a través de los Pods que su selector coincide (vía EndpointSlices mantenidos por el endpoint controller y programados por kube-proxy).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: ClusterIP           # ClusterIP | NodePort | LoadBalancer | ExternalName
  selector:
    app: web                # matches the Deployment's Pod labels
  ports:
    - name: http
      port: 80              # the Service's stable port
      targetPort: 80        # the container's port
---
# NodePort exposes the Service on every node's IP at a high port (30000-32767)
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector: { app: web }
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

| Tipo de Service | Alcanzable desde | Respaldado por | Uso típico |
|---|---|---|---|
| **ClusterIP** | solo dentro del clúster | VIP de kube-proxy | Tráfico este-oeste, el predeterminado |
| **NodePort** | `<anyNodeIP>:30000-32767` | ClusterIP + puerto de nodo | Bare-metal, prueba externa rápida |
| **LoadBalancer** | IP de LB externa | cloud-controller-manager aprovisiona un LB | Norte-sur en la nube |
| **ExternalName** | CNAME a DNS externo | CNAME de kube-dns | Alias de servicios externos |
| **Headless (`clusterIP: None`)** | IPs de Pod directas vía DNS | sin VIP | StatefulSets, LB del lado del cliente |

Resolución DNS: un Service `web` en el namespace `prod` es alcanzable en `web.prod.svc.cluster.local` (CoreDNS). **Ingress** (un router HTTP L7) y la más nueva **Gateway API** se sitúan *delante de* los Services para enrutamiento por host/path y terminación TLS — vale la pena conocerlos, aunque los objetos centrales de arriba son los átomos evaluados.

---

## 5. `kubectl` — sesiones reales de terminal

`kubectl` es el cliente principal; habla HTTPS con el API server usando el contexto de `~/.kube/config`. Salida real abajo (con saltos de línea como los muestra una terminal):

```
$ kubectl apply -f deployment.yaml
deployment.apps/web created

$ kubectl get deploy,rs,pods -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   4/4     4            4           38s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6d4b9c8f7c   4         4         4       38s

NAME                   READY   STATUS    RESTARTS   AGE
pod/web-6d4b9c8f7c-2xk9p   1/1   Running   0          38s
pod/web-6d4b9c8f7c-8wq4d   1/1   Running   0          38s
pod/web-6d4b9c8f7c-lm7rv   1/1   Running   0          38s
pod/web-6d4b9c8f7c-t9c2z   1/1   Running   0          38s
```

Disparar y observar una actualización progresiva:

```
$ kubectl set image deployment/web nginx=nginx:1.27.1-alpine
deployment.apps/web image updated

$ kubectl rollout status deployment/web
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 3 of 4 updated replicas are available...
deployment "web" successfully rolled out

$ kubectl rollout history deployment/web
deployment.apps/web
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

$ kubectl rollout undo deployment/web --to-revision=1
deployment.apps/web rolled back
```

Inspeccionar dónde aterrizó un Pod y por qué, y luego leer la salud de los componentes del control plane:

```
$ kubectl get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE       
web-6d4b9c8f7c-2xk9p   1/1     Running   0          4m    10.244.2.15   worker-02  

$ kubectl get componentstatuses
NAME                 STATUS    MESSAGE   ERROR
scheduler            Healthy   ok
controller-manager   Healthy   ok
etcd-0               Healthy   ok

$ kubectl get nodes
NAME          STATUS   ROLES           AGE   VERSION
cp-01         Ready    control-plane   21d   v1.30.2
worker-01     Ready    <none>          21d   v1.30.2
worker-02     Ready    <none>          21d   v1.30.2
```

---

## 6. Docker Swarm

El modo Swarm es el orquestador integrado de Docker Engine: sin instalación de control plane aparte, un solo binario, compatible con `docker-compose`. El objetivo pide **services, tasks, nodes y stacks de swarm**.

### 6.1 Conceptos

- **Node** — un Docker Engine en el swarm; un **manager** (participa en el control plane basado en Raft) o un **worker** (solo ejecuta tasks). Los managers deben ser de número impar (3/5) para el quorum, exactamente como etcd.
- **Service** — la unidad declarativa: una imagen + cantidad deseada de réplicas (o `global` = una por nodo) + config de red/puertos. El análogo en Swarm de un Deployment.
- **Task** — una única instancia de contenedor de un service, programada en un nodo. La unidad atómica; un service con `replicas: 3` produce 3 tasks. (Un *task* de Swarm ≈ un *Pod* de Kubernetes.)
- **Stack** — un grupo de services definidos en un archivo Compose y desplegados juntos (`docker stack deploy`). El análogo en Swarm de un release de Helm / un conjunto de manifests.

La **routing mesh** integrada de Swarm publica el puerto de un service en **cada** nodo; el tráfico que llega a cualquier nodo se reenvía (vía IPVS en la red overlay `ingress`) a un task saludable, dándote una IP virtual (VIP) por service gratis.

### 6.2 Bootstrapeo y operación de un swarm

```
$ docker swarm init --advertise-addr 192.168.10.11
Swarm initialized: current node (kf3d9a...) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49nj1... 192.168.10.11:2377

$ docker swarm join-token worker
To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49nj1c8ax... 192.168.10.11:2377

# ── on each worker ──
$ docker swarm join --token SWMTKN-1-49nj1c8ax... 192.168.10.11:2377
This node joined a swarm as a worker.

$ docker node ls
ID              HOSTNAME    STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
kf3d9a... *     mgr-01      Ready    Active         Leader           27.1.1
q1p8s2...       wrk-01      Ready    Active                          27.1.1
z7c4v9...       wrk-02      Ready    Active                          27.1.1
```

Crear, inspeccionar y escalar un **service**:

```
$ docker service create --name web --replicas 3 -p 8080:80 nginx:1.27-alpine
x8f2q9v1k3n5
overall progress: 3 out of 3 tasks
1/3: running   [==================================================>]
2/3: running   [==================================================>]
3/3: running   [==================================================>]
verify: Service converged

$ docker service ls
ID             NAME   MODE         REPLICAS   IMAGE               PORTS
x8f2q9v1k3n5   web    replicated   3/3        nginx:1.27-alpine   *:8080->80/tcp

$ docker service ps web
ID          NAME    IMAGE               NODE     DESIRED STATE  CURRENT STATE
a1b2c3d4    web.1   nginx:1.27-alpine   wrk-01   Running        Running 2 min ago
e5f6g7h8    web.2   nginx:1.27-alpine   wrk-02   Running        Running 2 min ago
i9j0k1l2    web.3   nginx:1.27-alpine   mgr-01   Running        Running 2 min ago

$ docker service scale web=5
web scaled to 5
$ docker service update --image nginx:1.27.1-alpine web   # rolling update
```

Desplegar un **stack** desde un archivo Compose:

```yaml
# stack.yml
version: "3.9"
services:
  web:
    image: nginx:1.27-alpine
    ports:
      - "8080:80"
    deploy:
      replicas: 4
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == worker
    networks: [appnet]
  redis:
    image: redis:7-alpine
    deploy:
      replicas: 1
      placement:
        constraints: [node.labels.storage == ssd]
    networks: [appnet]
networks:
  appnet:
    driver: overlay
```

```
$ docker stack deploy -c stack.yml myapp
Creating network myapp_appnet
Creating service myapp_web
Creating service myapp_redis

$ docker stack services myapp
ID       NAME         MODE         REPLICAS   IMAGE
7hq2..   myapp_web    replicated   4/4        nginx:1.27-alpine
9kd8..   myapp_redis  replicated   1/1        redis:7-alpine

$ docker stack ps myapp
$ docker stack rm myapp        # tear the whole stack down
```

### 6.3 Swarm vs Kubernetes — tabla de compensaciones

| Dimensión | Docker Swarm | Kubernetes |
|---|---|---|
| Instalación / operación | Trivial (integrado en Docker) | Compleja (kubeadm, o gestionado) |
| Unidad de scheduling | Task (contenedor único) | Pod (1+ contenedores co-programados) |
| Almacén del control plane | Raft (integrado) | etcd (Raft) |
| Archivo declarativo | Compose (`docker stack`) | Manifests / Helm / Kustomize |
| Balanceo de carga | Routing mesh (VIP de IPVS) | Services + kube-proxy + Ingress |
| Autoescalado | ❌ (`scale` manual) | ✅ HPA / VPA / Cluster Autoscaler |
| Ecosistema / extensibilidad | Mínimo | Vasto (CRDs, operators, CNI/CSI/CRI) |
| Rolling update / rollback | ✅ (`update_config`) | ✅ (más rico, historial de revisiones) |
| Primitivas multi-contenedor | ❌ | ✅ (sidecars, init containers) |
| Trayectoria de producción | Estable pero con poco impulso | Estándar de la industria (CNCF) |

**Veredicto para el examen:** Swarm gana en *simplicidad y tiempo-hasta-el-primer-service*; Kubernetes gana en *extensibilidad, ecosistema y topologías de producción complejas*. Swarm es la opción pragmática para una flota pequeña y homogénea; Kubernetes es el predeterminado para cualquier cosa que necesite autoescalado, operators o un equipo grande.

---

## 7. Helm — el gestor de paquetes (conocimiento)

Helm empaqueta un conjunto de manifests como un **chart** (YAML templado + un `values.yaml`), que instalás como un **release** con nombre. Resuelve "tengo 30 manifests interrelacionados con los mismos 8 valores duplicados a lo largo de ellos" y provee releases versionados y revertibles.

Estructura de un chart:

```
mychart/
├── Chart.yaml          # name, version, appVersion, dependencies
├── values.yaml         # default parameter values
├── templates/
│   ├── deployment.yaml # Go-templated: {{ .Values.replicaCount }}
│   ├── service.yaml
│   └── _helpers.tpl
└── charts/             # vendored sub-charts (dependencies)
```

```
$ helm repo add bitnami https://charts.bitnami.com/bitnami
$ helm install my-nginx bitnami/nginx --set replicaCount=3
NAME: my-nginx
STATUS: deployed
REVISION: 1

$ helm list
NAME       NAMESPACE  REVISION  STATUS     CHART         APP VERSION
my-nginx   default    1         deployed   nginx-18.1.0  1.27.0

$ helm upgrade my-nginx bitnami/nginx --set replicaCount=5
$ helm rollback my-nginx 1
$ helm template my-nginx bitnami/nginx | kubectl apply --dry-run=server -f -
```

Helm 3 es **solo cliente** (sin "Tiller" en el clúster); el estado del release se almacena como Secrets en el namespace del release.

---

## 8. Conocimiento de distribuciones: OpenShift, Rancher, OKD

El objetivo pide **conocimiento** de estas — saber qué *es* cada una respecto a Kubernetes upstream.

| Producto | Proveedor | Qué es | Características distintivas |
|---|---|---|---|
| **OpenShift (OCP)** | Red Hat | Distribución de Kubernetes empresarial, opinada y *con soporte* | Registro de imágenes integrado, builds source-to-image (S2I), objetos `Route` (ingress HAProxy integrado), valores de seguridad más estrictos (SCCs, non-root por defecto), CLI `oc`, CI/CD integrado; corre sobre RHCOS. |
| **OKD** | Comunidad | La distribución comunitaria upstream y gratuita a partir de la cual se construye OpenShift | Misma arquitectura que OCP sin el soporte/suscripción de Red Hat; el "Fedora respecto al RHEL de OpenShift". |
| **Rancher** | SUSE | Una plataforma de **gestión multi-clúster** *por encima de* Kubernetes | Aprovisiona y gestiona muchos clústeres (RKE2/K3s, EKS, AKS, GKE) desde una UI/API; RBAC centralizado, catálogo, GitOps de flota (fleet). K3s (su distro liviana) es un único binario de ~60 MB para edge/IoT. |

Modelo mental: **OKD → OpenShift** es upstream → con soporte empresarial; **Rancher** es un gestor de flota que se sitúa por encima de los clústeres en lugar de ser una distribución sobre la cual ejecutás cargas de trabajo directamente.

---

## 9. Verificación y diagnóstico de fallos

La depuración de orquestación en producción es un **recorrido de arriba hacia abajo del reconcile loop**: ¿el objeto es aceptado? ¿programado? ¿la imagen se descargó? ¿tiene red? ¿está ready?

### 9.1 Los primeros cuatro comandos universales

```
$ kubectl get pods -A -o wide                # what state is everything in?
$ kubectl describe pod <pod>                 # Events at the bottom are gold
$ kubectl logs <pod> [-c <container>] --previous   # --previous = last crashed instance
$ kubectl get events --sort-by=.lastTimestamp     # cluster-wide timeline
```

### 9.2 Síntoma → causa → comando

| Estado del Pod | Causa probable | Diagnóstico |
|---|---|---|
| `Pending` | Ningún nodo encaja con requests/affinity/taints; sin CNI; PVC no ligado | `kubectl describe pod` → *FailedScheduling*; `kubectl describe node` para ver allocatable |
| `ContainerCreating` (atascado) | CNI no instalada/rota; el volumen no monta; descarga de imagen lenta | `kubectl describe pod`; revisá `/etc/cni/net.d`; `journalctl -u kubelet` |
| `ImagePullBackOff` / `ErrImagePull` | Nombre/tag de imagen incorrecto; registro privado, sin `imagePullSecret` | `kubectl describe pod` → error de pull; verificá el secret |
| `CrashLoopBackOff` | La app sale/hace panic; liveness probe fallando; config incorrecta | `kubectl logs --previous`; revisá path/port de la probe |
| `OOMKilled` (en el motivo de RESTARTS) | Uso de memoria > `limits.memory` | `kubectl describe pod` → *Last State: OOMKilled*; subí el límite o corregí el leak |
| `Running` pero `0/1 READY` | readinessProbe fallando → fuera de los endpoints del Service | `kubectl describe pod`; `kubectl get endpointslices` |

### 9.3 Ejemplos resueltos

**Un Pod no se programa:**

```
$ kubectl describe pod web-6d4b9c8f7c-2xk9p
...
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available:
           1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
           2 Insufficient cpu. preemption: 0/3 nodes are available.
```

→ Los dos workers carecen de CPU libre (`requests.cpu` demasiado alto) y el nodo del control plane está con taint. Bajá los requests, agregá capacidad o agregá una toleration.

**El Service no devuelve backends:**

```
$ kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-abc12   IPv4          80      <unset>     3m       # empty = selector/label mismatch
```

→ El `selector` del Service no coincide con los labels de los Pods, o todos los Pods están `NotReady`. Comprobá `kubectl get pods --show-labels` contra `kubectl get svc web -o yaml`.

### 9.4 Chequeos a nivel de control plane y de nodo

```
# Is the kubelet healthy on a NotReady node?
$ systemctl status kubelet
$ journalctl -u kubelet -f --no-pager

# Is the CRI up? (list containers the runtime actually sees)
$ sudo crictl ps
$ sudo crictl images

# etcd health and quorum (from a control-plane node)
$ ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key endpoint health
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 3.1ms

# Raw API-server reachability, bypassing kubectl niceties
$ kubectl get --raw='/readyz?verbose'
[+]ping ok
[+]etcd ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
readyz check passed
```

### 9.5 Verificación del lado de Swarm

```
$ docker node ls                       # all managers Reachable, one Leader?
$ docker service ps web --no-trunc      # per-task error messages, un-truncated
$ docker service inspect web --pretty
$ docker service logs web
$ docker events --filter 'type=service' # live control-plane events
```

Si los tasks oscilan entre `Ready` y `Shutdown`, leé la columna de error del *CURRENT STATE* en `docker service ps --no-trunc` (fallo de descarga de imagen, fallo del health-check, constraint de placement sin nodo que coincida).

---

## 10. Referencias

- LPI — Exam 305-300 Objectives (topic 352.4): https://www.lpi.org/our-certifications/exam-305-objectives/
- Kubernetes — Cluster Architecture: https://kubernetes.io/docs/concepts/architecture/
- Kubernetes — Control plane components: https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes — Pods: https://kubernetes.io/docs/concepts/workloads/pods/
- Kubernetes — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes — Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Labels and Selectors: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes — Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Kubernetes — Dockershim removal FAQ: https://kubernetes.io/dockershim/
- CNI specification (CNCF): https://github.com/containernetworking/cni/blob/main/SPEC.md
- Kubernetes — Network Plugins (CNI): https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Container Storage Interface (CSI) spec: https://github.com/container-storage-interface/spec/blob/master/spec.md
- Kubernetes — kubelet: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Kubernetes — kube-proxy / Service dataplane: https://kubernetes.io/docs/reference/networking/virtual-ips/
- etcd — operating documentation: https://etcd.io/docs/latest/op-guide/
- Docker — Swarm mode overview: https://docs.docker.com/engine/swarm/
- Docker — How swarm mode works (nodes, services, tasks): https://docs.docker.com/engine/swarm/how-swarm-mode-works/nodes/
- Docker — Deploy a stack to a swarm: https://docs.docker.com/engine/swarm/stack-deploy/
- Helm — Documentation: https://helm.sh/docs/
- Red Hat OpenShift — Documentation: https://docs.openshift.com/
- OKD — Community distribution: https://www.okd.io/
- Rancher (SUSE) — Documentation: https://ranchermanager.docs.rancher.com/