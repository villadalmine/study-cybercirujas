# Fundamentos de Cilium — Ejercicios Guiados
### CCA · Dominio 1.1 (peso en el examen 20%)

> **Qué vas a construir.** Un clúster Kubernetes de tres nodos **sin CNI y sin kube-proxy**, para después instalar Cilium en él y desarmar el datapath capa por capa: pares veth y puntos de enganche eBPF, los mapas `cilium_lxc` / `cilium_ipcache` / `cilium_lb4_*`, las identidades de seguridad, el mapa de túneles, el balanceo de carga a nivel de socket y, finalmente, la política basada en identidad con aplicación en L3/L4 y L7.
>
> **Cómo trabajar con esto.** Cada paso numerado está pensado para ser ejecutado. Las salidas mostradas tienen forma real, pero **tus IDs, IPs, ifindexes y números de identidad van a diferir** — ese es justamente el punto: tenés que aprender a leer la estructura, no a memorizar los valores. Después de cada bloque hay preguntas de verificación (**Q1 … Q34**); todas las respuestas están en la sección plegable al final.
>
> **Nota de versión.** Escrito contra **Cilium 1.16.x sobre Kubernetes 1.31**. Tres cosas son sensibles a la versión y están señaladas en línea: (a) el CLI dentro del agente pasó de llamarse `cilium` a `cilium-dbg` en 1.15; (b) `kubeProxyReplacement` sólo acepta `true`/`false` desde 1.16 (`strict`/`partial`/`probe` fueron eliminados); (c) el DaemonSet independiente `cilium-envoy` está habilitado por defecto desde 1.16. Ejecutá `cilium version --client` y `kubectl -n kube-system exec ds/cilium -- cilium-dbg version` antes de dar nada por sentado.

**Prerrequisitos en tu estación de trabajo:** `docker` (o podman con el proveedor de kind), `kind` ≥ 0.24, `kubectl` ≥ 1.30, el CLI `cilium` ≥ 0.16, el CLI `hubble` ≥ 1.16, y un kernel Linux ≥ 5.10 en la máquina que ejecuta los contenedores (5.15+ muy recomendado — varias funcionalidades de abajo se degradan silenciosamente en kernels más viejos).

---

## Convenciones del laboratorio

Definí esto una vez por shell. Todo lo que sigue depende de ello.

```bash
export CLUSTER=cca-lab
export CILIUM_VERSION=1.16.5

# Shorthand for "run this inside the Cilium agent on a given node".
# $1 = node name, rest = command
cnode() { local n="$1"; shift
  kubectl -n kube-system exec -it \
    "$(kubectl -n kube-system get pod -l k8s-app=cilium \
        --field-selector spec.nodeName="$n" -o name | head -1)" \
    -c cilium-agent -- "$@"
}

# Shorthand for "run this inside *some* agent" (fine for cluster-wide reads)
cany() { kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- "$@"; }
```

---

## Ejercicio 1 — Construir un clúster sin CNI y sin kube-proxy

El clúster kind por defecto trae `kindnetd` (un CNI) y `kube-proxy` (una implementación de Service). Cilium reemplaza a ambos. Instalarlo por encima de ellos produce un clúster que *aparenta* funcionar mientras dos datapaths se pelean por los mismos paquetes — la causa más común, por lejos, de "mi NetworkPolicy no se aplica" en el campo.

1. **Escribí la definición del clúster.**

```yaml
# kind-cca.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Do not install kindnetd; the cluster stays NotReady until a CNI arrives.
  disableDefaultCNI: true
  # Do not run kube-proxy at all; Cilium will own Service translation.
  kubeProxyMode: none
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. **Creálo.**

```bash
kind create cluster --config kind-cca.yaml
kubectl config use-context kind-cca-lab
```

3. **Observá el clúster en su estado roto — esto es lo esperado.**

```bash
kubectl get nodes -o wide
```

```
NAME                      STATUS     ROLES           AGE   VERSION   INTERNAL-IP
cca-lab-control-plane     NotReady   control-plane   47s   v1.31.2   172.18.0.2
cca-lab-worker            NotReady   <none>          31s   v1.31.2   172.18.0.3
cca-lab-worker2           NotReady   <none>          31s   v1.31.2   172.18.0.4
```

4. **Confirmá *por qué* los nodos están NotReady.**

```bash
kubectl describe node cca-lab-worker | grep -A2 'Ready '
```

```
  Ready   False   ...   KubeletNotReady   container runtime network not ready:
          NetworkReady=false reason:NetworkPluginNotReady
          message:Network plugin returns error: cni plugin not initialized
```

5. **Confirmá que kube-proxy realmente está ausente.**

```bash
kubectl -n kube-system get ds
kubectl get pods -A -o wide | grep -c kube-proxy || echo "no kube-proxy pods"
```

6. **Capturá el endpoint del API server** — sin kube-proxy, el agente Cilium no puede alcanzar `10.96.0.1:443` (nada traduce esa VIP todavía), así que necesita la dirección real para arrancar.

```bash
API_SERVER_IP=$(docker inspect -f \
  '{{ .NetworkSettings.Networks.kind.IPAddress }}' cca-lab-control-plane)
API_SERVER_PORT=6443
echo "$API_SERVER_IP:$API_SERVER_PORT"     # e.g. 172.18.0.2:6443
```

> **Q1.** Los nodos están `NotReady`, y sin embargo `kubectl get nodes` funciona y el kubelet está corriendo. ¿Qué subsistema específico del kubelet está fallando, y por qué los static pods del control plane (etcd, kube-apiserver) igual arrancan?
>
> **Q2.** ¿Por qué tenés que pasarle `k8sServiceHost`/`k8sServicePort` explícitamente a Cilium en este clúster, pero *no* en un clúster que todavía corre kube-proxy? Describí el ciclo exacto del huevo y la gallina.
>
> **Q3.** Te salteaste `kubeProxyMode: none` e instalaste Cilium con `kubeProxyReplacement=true` de todos modos. Ahora están presentes tanto las reglas iptables/IPVS de kube-proxy como el LB de socket en eBPF de Cilium. ¿En qué punto de la ruta de `connect()` de un pod actúa cada uno, y cuál gana para una conexión a un ClusterIP originada en un pod?

---

## Ejercicio 2 — Instalar Cilium y leer el control plane

7. **Instalá.** Los valores de Helm de abajo son los que el examen espera que reconozcas.

```bash
cilium install --version "$CILIUM_VERSION" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$API_SERVER_IP" \
  --set k8sServicePort="$API_SERVER_PORT" \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set operator.replicas=1 \
  --set bpf.monitorAggregation=none
```

`bpf.monitorAggregation=none` deshabilita la fusión de eventos para que `cilium-dbg monitor` muestre *todos* los eventos de paquete en el Ejercicio 7. Nunca hagas esto en producción — es un costo medible por paquete.

8. **Esperá la convergencia y leé el resumen.**

```bash
cilium status --wait
```

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet         cilium             Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet         cilium-envoy       Desired: 3, Ready: 3/3, Available: 3/3
Deployment        cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
Containers:       cilium             Running: 3
                  cilium-envoy       Running: 3
                  cilium-operator    Running: 1
Cluster Pods:     3/3 managed by Cilium
Helm chart version: 1.16.5
```

9. **Los nodos pasan a Ready.** El archivo de configuración CNI lo escribe en disco el init container del agente.

```bash
kubectl get nodes
docker exec cca-lab-worker ls -l /etc/cni/net.d/
docker exec cca-lab-worker cat /etc/cni/net.d/05-cilium.conflist
```

```
{
  "cniVersion": "0.3.1",
  "name": "cilium",
  "plugins": [
    {
       "type": "cilium-cni",
       "enable-debug": false,
       "log-file": "/var/run/cilium/cilium-cni.log"
    }
  ]
}
```

10. **Enumerá qué hace realmente cada componente.**

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l name=cilium-operator -o wide
kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o wide
```

11. **Leé la visión que el agente tiene de sí mismo** (fijate en el nombre del binario — `cilium-dbg`, no `cilium`):

```bash
cany cilium-dbg status --verbose | head -45
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:         ["cilium/v2::CiliumClusterwideNetworkPolicy", ...]
KubeProxyReplacement:    True   [eth0   172.18.0.3 fe80::42:acff:fe12:3 (Direct Routing)]
Host firewall:           Disabled
SRv6:                    Disabled
CNI Chaining:            none
Cilium:                  Ok   1.16.5 (v1.16.5-xxxxxxxx)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 3/254 allocated from 10.0.1.0/24,
Allocated addresses:
  10.0.1.115 (health)
  10.0.1.211 (kube-system/coredns-...)
  10.0.1.87  (router)
ClusterMesh:             0/0 clusters ready
IPv4 BIG TCP:            Disabled
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
Encryption:              Disabled
Cluster health:          3/3 reachable
```

12. **Compará la configuración efectiva del agente con la que pediste.**

```bash
cilium config view | grep -E 'routing-mode|tunnel|ipam|kube-proxy|enable-policy|enable-ipv4'
cany cilium-dbg config | head -30
```

> **Q4.** Nombrá los cuatro componentes de Cilium que podés ver en este clúster e indicá, en una oración cada uno, qué se rompe si se elimina únicamente ese componente: `cilium` (DaemonSet), `cilium-operator` (Deployment), `cilium-envoy` (DaemonSet), `cilium-cni` (el binario en disco).
>
> **Q5.** `cilium-operator` corre con una réplica. Los pods se siguen programando y conectando mientras está caído — ¿por cuánto tiempo, y qué es lo primero que falla? (Pista: pensá en qué le pertenece al operator con `ipam.mode=cluster-pool`.)
>
> **Q6.** `Routing: Network: Tunnel [vxlan] Host: BPF`. ¿A qué se refiere "Host: BPF", y en qué se diferencia del modo de ruteo "Network"?
>
> **Q7.** `Attach Mode: TCX` y `Device Mode: veth`. ¿Qué es TCX, qué versión del kernel lo introdujo, y a qué recurre Cilium cuando no está disponible?
>
> **Q8.** La configuración de kind declara `podSubnet: 10.244.0.0/16`, pero el agente reporta asignaciones desde `10.0.1.0/24`. Explicá con precisión por qué, y nombrá el campo del CRD `CiliumNode` donde se registra el rango por nodo.

---

## Ejercicio 3 — El datapath por nodo: interfaces, hooks y mapas

Desplegá primero las cargas de trabajo para tener algo que mirar.

13. **Desplegá la demo de Star Wars** (canónica en Cilium; la ruta L7 del Ejercicio 8 depende de ella).

```yaml
# starwars.yaml
apiVersion: v1
kind: Service
metadata:
  name: deathstar
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  selector:
    org: empire
    class: deathstar
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deathstar
spec:
  replicas: 2
  selector:
    matchLabels:
      org: empire
      class: deathstar
  template:
    metadata:
      labels:
        org: empire
        class: deathstar
    spec:
      containers:
        - name: deathstar
          image: docker.io/cilium/starwars
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: tiefighter
  labels:
    org: empire
    class: tiefighter
spec:
  containers:
    - name: spaceship
      image: docker.io/tgraf/netperf
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: xwing
  labels:
    org: alliance
    class: xwing
spec:
  containers:
    - name: spaceship
      image: docker.io/tgraf/netperf
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f starwars.yaml
kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -o wide
```

14. **Mirá las interfaces del lado del host en un nodo.**

```bash
docker exec cca-lab-worker ip -brief link show
```

```
lo               UNKNOWN  00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
cilium_net@cilium_host  UP  9a:1c:...  <BROADCAST,MULTICAST,UP,LOWER_UP>
cilium_host@cilium_net  UP  4e:8b:...  <BROADCAST,MULTICAST,UP,LOWER_UP>
cilium_vxlan     UNKNOWN  16:df:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
lxc_health@if9   UP       ba:22:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
lxc8a3f21c94b17@if11 UP   3e:04:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
eth0@if12        UP       02:42:ac:12:00:03 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

15. **Correlacioná una interfaz `lxc*` con el pod que la posee.**

```bash
POD=$(kubectl get pod -l class=tiefighter -o jsonpath='{.metadata.name}')
NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')

# ifindex of eth0 *inside* the pod
kubectl exec "$POD" -- cat /sys/class/net/eth0/iflink
# -> 11

# the host device with that ifindex is the peer
docker exec "$NODE" ip -o link | awk -F': ' '$1==11 {print}'
```

16. **Listá los programas eBPF enganchados a ese dispositivo.**

```bash
LXC=lxc8a3f21c94b17    # substitute yours
cnode "$NODE" bpftool net show dev "$LXC"
```

```
tc:
xdp:
flow_dissector:
netfilter:
tcx/ingress:
  cil_from_container prog_id 412 link_id 33
tcx/egress:
  cil_to_container prog_id 415 link_id 34
```

17. **Inspeccioná uno de esos programas y los mapas que mantiene abiertos.**

```bash
cnode "$NODE" bpftool prog show id 412
cnode "$NODE" bpftool prog show id 412 --json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["map_ids"])'
```

```
412: sched_cls  name cil_from_container  tag 9d1f0a7c2b3e4d55
     loaded_at 2026-09-01T11:02:41+0000  uid 0
     xlated 41288B  jited 23904B  memlock 45056B
     map_ids 88,91,93,104,117,120
     btf_id 55
```

18. **Enumerá el conjunto de mapas pineados.**

```bash
cnode "$NODE" ls -1 /sys/fs/bpf/tc/globals/ | sort
cnode "$NODE" cilium-dbg map list --verbose | head -30
```

```
cilium_call_policy
cilium_calls_00412
cilium_ct4_global
cilium_ct_any4_global
cilium_events
cilium_ipcache
cilium_lb4_backends_v3
cilium_lb4_reverse_nat
cilium_lb4_services_v2
cilium_lxc
cilium_metrics
cilium_node_map
cilium_policy_v2_00412
cilium_runtime_config
cilium_tunnel_map
```

19. **Leé el mapa de endpoints — la tabla de "quién vive en este nodo".**

```bash
cnode "$NODE" cilium-dbg bpf endpoint list
```

```
IP ADDRESS        LOCAL ENDPOINT INFO
10.0.1.87:0       id=2623  sec_id=10530 flags=0x0000 ifindex=11  mac=3E:04:.. nodemac=..
10.0.1.115:0      id=191   sec_id=4     flags=0x0000 ifindex=9   mac=BA:22:.. nodemac=..
172.18.0.3:0      (localhost)
```

> **Q9.** `cilium_net` y `cilium_host` son un par veth entre sí, no con ningún pod. ¿Para qué sirve ese par, y qué IP lleva `cilium_host`?
>
> **Q10.** El programa en el dispositivo del lado del host del pod se llama `cil_from_container` y está enganchado en **`tcx/ingress`**. El tráfico que *sale* del pod lo golpea. Explicá por qué "ingress" es la dirección correcta acá — ¿desde el punto de vista de quién?
>
> **Q11.** Los programas se pinean bajo `/sys/fs/bpf/tc/globals/`. ¿Por qué Cilium pinea los mapas a un bpffs en lugar de confiar en la referencia del propio programa? ¿Qué sobrevive a un reinicio del agente, y qué hace el agente al arrancar como consecuencia?
>
> **Q12.** `cilium_calls_00412` y `cilium_policy_v2_00412` son por endpoint, mientras que `cilium_ipcache` y `cilium_ct4_global` son globales al nodo. ¿Por qué el mapa de políticas es por endpoint pero el conntrack es global por defecto? Nombrá el flag del agente que hace el conntrack por endpoint y una razón por la que no querrías eso.
>
> **Q13.** Borrá un pod y recreálo inmediatamente. Su ID de endpoint cambia, pero `cilium_lxc` nunca acumula entradas obsoletas. ¿Qué componente hace esa limpieza, y a través de qué interfaz (CNI, watch de Kubernetes, o ambos)?

---

## Ejercicio 4 — Endpoints, labels e identidades de seguridad

Este es el núcleo conceptual del dominio: **Cilium no escribe políticas sobre direcciones IP; escribe políticas sobre identidades, y las identidades se derivan de labels.**

20. **Listá los endpoints de un nodo y leé la columna de identidad.**

```bash
cnode "$NODE" cilium-dbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                   IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
191        Disabled           Disabled          4          reserved:health                               10.0.1.115   ready
842        Disabled           Disabled          1          k8s:node-role.kubernetes.io/worker
                                                           reserved:host                                              ready
2623       Disabled           Disabled          33807      k8s:class=tiefighter                          10.0.1.87    ready
                                                           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
                                                           k8s:io.cilium.k8s.policy.cluster=default
                                                           k8s:io.cilium.k8s.policy.serviceaccount=default
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
```

21. **Listá las identidades que el clúster asignó.**

```bash
cany cilium-dbg identity list
kubectl get ciliumidentities.cilium.io
```

```
ID      LABELS
1       reserved:host
2       reserved:world
3       reserved:unmanaged
4       reserved:health
5       reserved:init
6       reserved:remote-node
7       reserved:kube-apiserver
8       reserved:ingress
9       reserved:world-ipv4
10530   k8s:class=deathstar
        k8s:io.kubernetes.pod.namespace=default
        k8s:org=empire
        ...
33807   k8s:class=tiefighter
        ...
51402   k8s:class=xwing
        k8s:org=alliance
        ...
```

22. **Inspeccioná una identidad en detalle, y su objeto CRD de respaldo.**

```bash
cany cilium-dbg identity get 10530
kubectl get ciliumidentity 10530 -o yaml | head -30
```

23. **Probá que la identidad sigue a los labels, no a los pods.** Escalá el deployment y mirá cómo la cantidad de identidades queda plana.

```bash
kubectl scale deploy/deathstar --replicas=4
kubectl wait --for=condition=Ready pod -l class=deathstar --timeout=90s
kubectl get ciliumendpoints.cilium.io
```

```
NAME                         ENDPOINT ID   IDENTITY ID   INGRESS   EGRESS   IPV4         STATUS
deathstar-6fb5694d48-5hmds   1287          10530         <status>  <status> 10.0.2.31    ready
deathstar-6fb5694d48-9k4xq   2044          10530         <status>  <status> 10.0.1.203   ready
deathstar-6fb5694d48-p2rlz   3311          10530         <status>  <status> 10.0.2.140   ready
deathstar-6fb5694d48-wq7fn   1902          10530         <status>  <status> 10.0.1.66    ready
tiefighter                   2623          33807         <status>  <status> 10.0.1.87    ready
xwing                        1455          51402         <status>  <status> 10.0.2.88    ready
```

24. **Ahora cambiá un label y mirá aparecer una *nueva* identidad.**

```bash
cany cilium-dbg identity list | wc -l
kubectl label pod xwing tier=frontend
sleep 3
kubectl get ciliumendpoint xwing -o jsonpath='{.status.identity.id}{"\n"}'
cany cilium-dbg identity list | wc -l
```

25. **Revertilo y confirmá la recolección de basura.**

```bash
kubectl label pod xwing tier-
sleep 5
kubectl get ciliumidentities.cilium.io --sort-by=.metadata.creationTimestamp | tail -5
```

> **Q14.** Cuatro pods `deathstar` en dos nodos comparten la identidad `10530`. Indicá la consecuencia para el tamaño del mapa de políticas eBPF: ¿cuántas entradas necesita una regla "allow from tiefighter", y cómo escala eso cuando las réplicas crecen a 400?
>
> **Q15.** De la lista de labels del endpoint 2623, nombrá los dos labels que Cilium sintetiza y que **no** existen en el objeto pod de Kubernetes, y explicá qué hace expresable cada uno en una política.
>
> **Q16.** `reserved:world` es `2`, `reserved:remote-node` es `6`, `reserved:host` es `1`. Un pod en worker1 se conecta a un pod en worker2. ¿Qué identidad va en el *paquete* en cada salto, y por qué `remote-node` es distinto de `host`?
>
> **Q17.** Las identidades locales al clúster se numeran desde 256 en adelante. Las identidades derivadas de CIDR aparecen como números muy grandes (≥ 16777216). ¿Qué distinción estructural codifica ese bit, y por qué una identidad CIDR no puede asignarse a nivel de clúster como una basada en labels?
>
> **Q18.** Agregar `tier=frontend` produjo una nueva identidad. Indicá el riesgo operativo que esto crea en un clúster donde un mutating webhook inyecta un label único (por ejemplo, un SHA de build) en cada pod.
>
> **Q19.** `CiliumIdentity` es acá un CRD de alcance de clúster. Nombrá el backend alternativo de asignación de identidades que soporta Cilium, y una razón concreta para elegirlo por sobre los CRDs.

---

## Ejercicio 5 — ipcache, modo de ruteo y el mapa de túneles

El mapa de endpoints responde "quién es local". El **ipcache** responde "quién es *cualquiera*, en cualquier lugar, y cómo llego a él".

26. **Leé el ipcache.**

```bash
cnode "$NODE" cilium-dbg bpf ipcache list | head -20
```

```
IP PREFIX/ADDRESS   IDENTITY
0.0.0.0/0           identity=2 encryptkey=0
10.0.0.0/24         identity=6 encryptkey=0 tunnelendpoint=172.18.0.2
10.0.1.87/32        identity=33807 encryptkey=0 tunnelendpoint=0.0.0.0
10.0.1.115/32       identity=4 encryptkey=0 tunnelendpoint=0.0.0.0
10.0.2.0/24         identity=6 encryptkey=0 tunnelendpoint=172.18.0.4
10.0.2.31/32        identity=10530 encryptkey=0 tunnelendpoint=172.18.0.4
172.18.0.3/32       identity=1 encryptkey=0
172.18.0.4/32       identity=6 encryptkey=0
```

27. **Leé el mapa de túneles — la tabla de reenvío del overlay.**

```bash
cnode "$NODE" cilium-dbg bpf tunnel list
```

```
TUNNEL       VALUE
10.0.0.0:0   172.18.0.2:0
10.0.2.0:0   172.18.0.4:0
```

28. **Verificá la MTU que el agente le entregó a los pods.**

```bash
kubectl exec tiefighter -- ip link show eth0 | head -2
docker exec "$NODE" ip link show eth0 | head -2
```

```
2: eth0@if11: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...   # pod
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...  # node
```

29. **Observá la encapsulación en el cable.** Generá tráfico entre nodos y capturá VXLAN en el uplink del nodo.

```bash
# terminal A
docker exec cca-lab-worker timeout 20 \
  tcpdump -ni eth0 'udp port 8472' -c 6 -vv

# terminal B
DS=$(kubectl get svc deathstar -o jsonpath='{.spec.clusterIP}')
kubectl exec tiefighter -- \
  sh -c 'for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code}\n" \
         -XPOST http://deathstar/v1/request-landing; done'
```

```
11:41:07.220314 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 128)
    172.18.0.3.36815 > 172.18.0.4.8472: VXLAN, flags [I] (0x08), vni 0
    IP (tos 0x0, ttl 63, id 12094, ..., length 78)
    10.0.1.87.44210 > 10.0.2.31.80: Flags [S], seq 2718281828, win 64240, length 0
```

30. **Leé el mapa de nodos (la tabla de "qué nodo es cuál" usada para ruteo nativo y health).**

```bash
cnode "$NODE" cilium-dbg bpf nodeid list | head
cany cilium-dbg node list
```

31. **Comparate con la alternativa.** **No** apliques esto en el clúster de laboratorio a menos que quieras reconstruirlo — leelo y predecí en su lugar:

```bash
# Native routing: no encapsulation. Requires the underlay to route PodCIDRs.
cilium upgrade --reuse-values \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
  --set autoDirectNodeRoutes=true
```

> **Q20.** En el ipcache, `10.0.2.31/32` tiene `tunnelendpoint=172.18.0.4` mientras que `10.0.1.87/32` tiene `tunnelendpoint=0.0.0.0`. ¿Qué significa el valor cero, y qué hace distinto el datapath en cada caso?
>
> **Q21.** El ipcache tiene tanto un `/24` para el rango de pods del nodo remoto **como** entradas `/32` para pods remotos individuales. ¿Por qué ambos? ¿Cuál provee la identidad de seguridad para las decisiones de política, y qué pasa si sólo está el `/24` cuando llega un paquete?
>
> **Q22.** La MTU del pod es 1450 mientras que la del nodo es 1500. Derivá los 50 bytes. ¿Qué síntoma aparece si forzás la MTU del pod a 1500 en modo VXLAN — y por qué un `curl` a un endpoint chico tiene éxito mientras que un `POST` grande se cuelga?
>
> **Q23.** `--set routingMode=native --set autoDirectNodeRoutes=true` funciona en este clúster kind pero fallaría en la mayoría de las VPC de nube sin trabajo adicional. Indicá el requisito de underlay que asume `autoDirectNodeRoutes`, y nombrá la alternativa cloud-native que ofrece Cilium en su lugar.
>
> **Q24.** En modo de ruteo nativo, ¿qué pasa con el dispositivo `cilium_vxlan` y con `cilium_tunnel_map`? ¿Qué mapa asume el trabajo de "cómo llego a ese nodo"?

---

## Ejercicio 6 — Reemplazo de kube-proxy y los mapas del balanceador de carga

32. **Confirmá que el reemplazo está totalmente activo.**

```bash
cany cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/^$/p'
```

```
KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0   172.18.0.3 (Direct Routing)
  Mode:                   SNAT
  Backend Selection:      Random
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Disabled
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

33. **Leé la tabla de servicios tal como la ve el agente, y después como la ve el datapath.**

```bash
cany cilium-dbg service list
cany cilium-dbg bpf lb list
```

```
ID   Frontend              Service Type   Backend
1    10.96.0.1:443/TCP     ClusterIP      1 => 172.18.0.2:6443/TCP (active)
2    10.96.0.10:53/UDP     ClusterIP      1 => 10.0.1.211:53/UDP (active)
                                          2 => 10.0.2.99:53/UDP (active)
3    10.96.0.10:53/TCP     ClusterIP      1 => 10.0.1.211:53/TCP (active)
                                          2 => 10.0.2.99:53/TCP (active)
7    10.96.184.22:80/TCP   ClusterIP      1 => 10.0.2.31:80/TCP (active)
                                          2 => 10.0.1.203:80/TCP (active)
                                          3 => 10.0.2.140:80/TCP (active)
                                          4 => 10.0.1.66:80/TCP (active)
```

34. **Probá que la traducción ocurre en el momento del `connect()`, no en el cable.** Iniciá una captura en la propia interfaz del pod, y después hacé curl al ClusterIP.

```bash
# terminal A — capture inside the pod's netns
kubectl exec tiefighter -- timeout 15 tcpdump -ni eth0 'tcp port 80' -c 4

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' \
  -XPOST http://10.96.184.22/v1/request-landing
```

Observá la dirección de destino en la captura:

```
11:52:44.101223 IP 10.0.1.87.51124 > 10.0.2.31.80: Flags [S], seq ...
```

35. **Confirmá que no hay reglas de Service en iptables.**

```bash
docker exec "$NODE" iptables-save | grep -c KUBE-SERVICES || echo "0 KUBE-SERVICES chains"
docker exec "$NODE" iptables-save | grep -c CILIUM || true
```

36. **Observá la decisión del LB de socket directamente** (requiere `Socket LB Tracing: Enabled`):

```bash
# terminal A
cnode "$NODE" cilium-dbg monitor -t trace-sock

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null http://10.96.184.22/
```

```
xx [pre-xlate-rev] cgroup_id: 8123 sock_cookie: 41028, dst [10.0.2.31]:80 tcp
xx [post-xlate-fwd] cgroup_id: 8123 sock_cookie: 41028, dst [10.0.2.31]:80 tcp
```

37. **Ejercitá NodePort y mirá la entrada de NAT inverso.**

```bash
kubectl patch svc deathstar -p '{"spec":{"type":"NodePort"}}'
NP=$(kubectl get svc deathstar -o jsonpath='{.spec.ports[0].nodePort}')
curl -s -o /dev/null -w '%{http_code}\n' "http://172.18.0.3:$NP/"
cany cilium-dbg bpf lb list --revnat
kubectl patch svc deathstar -p '{"spec":{"type":"ClusterIP"}}'
```

> **Q25.** La captura dentro del pod muestra el destino como `10.0.2.31:80`, nunca `10.96.184.22:80`. ¿En qué hook del kernel ocurrió la traducción, y cuál es la consecuencia de rendimiento frente al DNAT en `iptables`/conntrack?
>
> **Q26.** El LB de socket reescribe el destino en `connect()`. ¿Qué tipo de cliente queda, por lo tanto, *fuera* de su cobertura, y qué mecanismo se ocupa de esos en su lugar? (Considerá un pod en el namespace de red del host, y tráfico que entra al nodo desde afuera.)
>
> **Q27.** `Mode: SNAT` aparece bajo KubeProxyReplacement Details. ¿Qué se está SNATeando, en qué escenario, y cuál es el modo alternativo que lo evita? Nombrá una contrapartida de esa alternativa.
>
> **Q28.** `Graceful Termination: Enabled`. Un pod backend entra en `Terminating`. ¿Qué estado toma su entrada en `cilium_lb4_backends_v3`, y qué pasa con (a) las conexiones existentes y (b) las conexiones nuevas?
>
> **Q29.** Tenés que depurar "el ClusterIP funciona desde un pod pero no desde el nodo mismo". Dá las tres verificaciones que correrías, en orden, y qué probaría cada una.

---

## Ejercicio 7 — Observabilidad: `cilium-dbg monitor` y Hubble

38. **Eventos crudos del datapath, desde el ring buffer de perf.**

```bash
# terminal A
cnode "$NODE" cilium-dbg monitor -v --type drop --type trace

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null \
  -XPOST http://deathstar/v1/request-landing
```

```
-> endpoint 2623 flow 0x8f2a1c34 , identity 10530->33807 state reply ifindex lxc8a3f21c94b17 orig-ip 10.0.2.31: 10.0.2.31:80 -> 10.0.1.87:44210 tcp ACK
-> stack flow 0x3b1e0022 , identity 33807->10530 state new ifindex 0 orig-ip 0.0.0.0: 10.0.1.87:44210 -> 10.0.2.31:80 tcp SYN
```

39. **Habilitá Hubble y su UI.**

```bash
cilium hubble enable --ui
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=hubble-relay
```

40. **Apuntá el CLI a Relay y verificalo.**

```bash
cilium hubble port-forward &          # local 4245 -> hubble-relay
sleep 3
hubble status
```

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,288/12,288 (100.00%)
Flows/s: 21.14
Connected Nodes: 3/3
```

41. **Observá flujos con contexto de identidad.**

```bash
kubectl exec tiefighter -- \
  sh -c 'for i in $(seq 5); do curl -s -o /dev/null \
         -XPOST http://deathstar/v1/request-landing; done'

hubble observe --last 10 --pod default/tiefighter
```

```
Sep  1 12:03:11.412: default/tiefighter:44210 (ID:33807) -> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) to-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:03:11.413: default/tiefighter:44210 (ID:33807) -> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:03:11.414: default/deathstar-6fb5694d48-5hmds:80 (ID:10530) -> default/tiefighter:44210 (ID:33807) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
```

42. **Filtrá de la manera en que vas a necesitar bajo la presión de tiempo del examen.**

```bash
hubble observe --verdict DROPPED --last 20
hubble observe --to-label class=deathstar --protocol tcp --port 80 -f
hubble observe --namespace kube-system --type l7 --last 20
hubble observe -o json --last 1 | python3 -m json.tool | head -40
```

43. **Abrí la UI** (opcional, requiere navegador):

```bash
cilium hubble ui        # opens http://localhost:12000
```

> **Q30.** `cilium-dbg monitor` y `hubble observe` leen ambos la misma fuente de eventos subyacente. Nombrala, e indicá dos cosas que `hubble observe` te da y que `cilium-dbg monitor` no puede.
>
> **Q31.** En el paso 38 viste `to-overlay` y `to-endpoint` para una sola petición HTTP. Explicá la diferencia, y decí cuál aparece en el nodo *origen* frente al nodo *destino*.
>
> **Q32.** Configuraste `bpf.monitorAggregation=none` al momento de instalar. ¿Cuál es el valor por defecto, qué agrega, y qué vas a *dejar de ver* si lo volvés al valor por defecto antes de la prueba de drops del Ejercicio 8?

---

## Ejercicio 8 — Primera CiliumNetworkPolicy: L3/L4, después L7

44. **Establecé la línea base: todos hablan con todos.**

```bash
for p in tiefighter xwing; do
  echo -n "$p -> deathstar: "
  kubectl exec "$p" -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
    -XPOST http://deathstar/v1/request-landing
done
```

```
tiefighter -> deathstar: 200
xwing -> deathstar: 200
```

45. **Aplicá una política de ingress L3/L4 basada en identidad.**

```yaml
# cnp-l34.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-empire-only
  namespace: default
spec:
  description: "Only endpoints labelled org=empire may reach the deathstar on 80/TCP"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

```bash
kubectl apply -f cnp-l34.yaml
kubectl get cnp deathstar-empire-only -o wide
```

46. **Observá cómo se activa la aplicación, por dirección.**

```bash
cany cilium-dbg endpoint list | grep -E 'ENDPOINT|deathstar|33807|51402'
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
1287       Enabled            Disabled          10530      k8s:class=deathstar ...
2623       Disabled           Disabled          33807      k8s:class=tiefighter ...
```

47. **Volvé a probar.**

```bash
kubectl exec tiefighter -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing        # 200
kubectl exec xwing      -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing        # hangs, then exits 28
```

48. **Mirá el drop desde ambas capas de observabilidad.**

```bash
hubble observe --verdict DROPPED --last 5
```

```
Sep  1 12:14:02.905: default/xwing:52104 (ID:51402) <> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) Policy denied DROPPED (TCP Flags: SYN)
```

```bash
DS_NODE=$(kubectl get pod -l class=deathstar -o jsonpath='{.items[0].spec.nodeName}')
cnode "$DS_NODE" cilium-dbg monitor -t drop
```

```
xx drop (Policy denied) flow 0x0 to endpoint 1287, ifindex 15, file bpf_lxc.c:2054,
   identity 51402->10530: 10.0.2.88:52104 -> 10.0.2.31:80 tcp SYN
```

49. **Leé el mapa de políticas compilado para el endpoint que aplica la política.**

```bash
cnode "$DS_NODE" cilium-dbg bpf policy get 1287
```

```
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
Allow    Ingress     33807      k8s:class=tiefighter          80/TCP       NONE         disabled    2914    24
                                k8s:org=empire
Allow    Ingress     10530      k8s:class=deathstar           80/TCP       NONE         disabled    0       0
                                k8s:org=empire
Allow    Egress      0          reserved:unknown              ANY          NONE         disabled    18422   142
```

50. **Usá el trazador de políticas para responder "¿esto estaría permitido?" sin enviar un paquete.**

```bash
cnode "$DS_NODE" cilium-dbg policy trace \
  --src-identity 51402 --dst-identity 10530 --dport 80/TCP
```

51. **Ahora subí a L7.** Reemplazá la política para que sólo se permita `POST /v1/request-landing`.

```yaml
# cnp-l7.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-empire-only
  namespace: default
spec:
  description: "Empire ships may only request landing; no other HTTP verb or path"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
```

```bash
kubectl apply -f cnp-l7.yaml
kubectl exec tiefighter -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing         # 200
kubectl exec tiefighter -- curl -s -m 5 -w '%{http_code}\n' \
  -XPUT http://deathstar/v1/exhaust-port             # 403 Access denied
```

52. **Confirmá que el proxy está ahora en la ruta.**

```bash
cnode "$DS_NODE" cilium-dbg bpf policy get 1287 | grep -E 'PROXY|Allow'
cnode "$DS_NODE" cilium-dbg status --verbose | grep -A5 'Proxy Status'
hubble observe --type l7 --last 5
```

```
Sep  1 12:21:44.010: default/tiefighter:44780 (ID:33807) -> default/deathstar-...:80 (ID:10530) http-request FORWARDED (HTTP/1.1 POST http://deathstar/v1/request-landing)
Sep  1 12:21:49.552: default/tiefighter:44782 (ID:33807) -> default/deathstar-...:80 (ID:10530) http-request DROPPED (HTTP/1.1 PUT http://deathstar/v1/exhaust-port)
```

> **Q33.** Dos modos de falla, dos síntomas: la denegación L3/L4 hizo que `curl` **se colgara hasta el timeout**, la denegación L7 devolvió **HTTP 403 inmediatamente**. Explicá el mecanismo detrás de cada uno, y decí qué te informa cada uno sobre dónde murió el paquete.
>
> **Q34.** En el paso 49, egress muestra un único `Allow Egress → identity 0 / reserved:unknown / ANY`. ¿Por qué egress está completamente abierto en un endpoint que tiene una política de ingress? Enunciá la regla sobre default-deny en Cilium, y cómo harías que egress sea default-deny para este endpoint con una edición mínima.

---

## Ejercicio 9 — Validar y después desmontar

53. **Corré la suite de conformidad incorporada.** Con una política aplicada va a fallar — quitala primero.

```bash
kubectl delete cnp deathstar-empire-only
cilium connectivity test --test-namespace cilium-test
```

```
✅ [cca-lab] 47/47 tests successful (0 warnings)
```

54. **Hacé una última verificación de cordura de todo el stack.**

```bash
cilium status
cany cilium-dbg status --brief          # -> OK
cany cilium-dbg-health status 2>/dev/null || cany cilium-health status
```

55. **Desmontá.**

```bash
kubectl delete -f starwars.yaml --ignore-not-found
cilium connectivity test --test-namespace cilium-test --purge 2>/dev/null || \
  kubectl delete ns cilium-test --ignore-not-found
kind delete cluster --name "$CLUSTER"
```

---

<details>
<summary><strong>Respuestas (Q1 – Q34)</strong></summary>

### Ejercicio 1

**A1.** El subsistema que falla es la **verificación del plugin de red CRI del kubelet**: el kubelet sondea buscando una configuración CNI válida en `--cni-conf-dir` (`/etc/cni/net.d`) y un binario correspondiente en `/opt/cni/bin`; al no encontrar ninguno establece la condición `NetworkReady=false`, que se manifiesta como `NotReady`. Los static pods del control plane igual arrancan porque corren con `hostNetwork: true` — usan el namespace de red del nodo directamente y nunca invocan al plugin CNI. Esto es exactamente por qué `kubectl` sigue funcionando: el API server está en `172.18.0.2:6443`, la propia IP del nodo.

**A2.** Sin kube-proxy, nada programa el ClusterIP `10.96.0.1:443`. El ciclo: el agente Cilium necesita el API server para leer objetos de Kubernetes → el endpoint del API dentro del clúster es una VIP de Service → la VIP sólo se traduce una vez que Cilium mismo instaló el Service en `cilium_lb4_services_v2` → lo cual requiere haber leído el Service desde el API server. Pasar `k8sServiceHost`/`k8sServicePort` rompe el ciclo dándole al agente una dirección concreta. Con kube-proxy presente, éste ya programó la VIP en iptables/IPVS antes de que Cilium arranque, así que `10.96.0.1:443` resuelve y no hace falta ningún override.

**A3.** El LB de socket de Cilium corre en los **hooks BPF de cgroup** (`connect4`/`connect6`, `sendmsg`, `recvmsg`) — es decir, dentro de la syscall `connect()`, *antes de que exista un paquete*. El DNAT de iptables de kube-proxy corre en la **tabla `nat` de netfilter en `OUTPUT`/`PREROUTING`**, sobre un paquete que ya está en el cable. Por lo tanto Cilium gana para el tráfico a ClusterIP originado en pods: el destino del socket ya fue reescrito a una IP de backend para cuando netfilter lo ve, así que las reglas de `KUBE-SERVICES` nunca coinciden. El peligro no es "cuál gana" sino la inconsistencia: las rutas de NodePort y del namespace del host todavía pueden atravesar las reglas de kube-proxy, dándote dos tablas de Service independientes y divergentes, y entradas de conntrack obsoletas.

### Ejercicio 2

**A4.**
- **DaemonSet `cilium` (agente)** — uno por nodo; compila y engancha los programas eBPF, es dueño de cada mapa BPF de ese nodo, asigna IPs, traduce objetos de Kubernetes a estado del datapath, expone el servidor de Hubble. Borralo: los flujos existentes siguen funcionando (los programas eBPF permanecen cargados y los mapas siguen pineados), pero ningún pod *nuevo* obtiene red y ningún cambio de política/Service se aplica en ese nodo.
- **Deployment `cilium-operator`** — de alcance de clúster, una o dos réplicas, fuera del datapath. Es dueño del IPAM a nivel de clúster (recortar PodCIDRs por `CiliumNode`), la recolección de basura de `CiliumIdentity`, la GC de `CiliumEndpoint`, el heartbeat del kvstore. Borralo: el datapath queda intacto, pero mirá A5.
- **DaemonSet `cilium-envoy`** — el proxy L7. Desde 1.16 corre como su propio DaemonSet en lugar de estar embebido en el agente, para que un reinicio del agente no tire abajo conexiones L7 en curso. Borralo: la política L3/L4 no se ve afectada; toda política con una regla `http`/`kafka`/`dns` pierde la capacidad de aplicarse y el tráfico afectado es descartado.
- **`cilium-cni`** — el binario CNI que el kubelet ejecuta al crear el sandbox del pod; habla con el agente local por un socket Unix para obtener una IP y crear el endpoint. Borralo: ningún pod nuevo puede tener red en ese nodo (`FailedCreatePodSandBox`); los pods en ejecución no se ven afectados.

**A5.** En `ipam.mode=cluster-pool` el operator es quien asigna el PodCIDR de cada nodo en `CiliumNode.spec.ipam.podCIDRs`. Cada nodo ya recibió un `/24` y mantiene un pool local, así que los pods siguen obteniendo red mientras ese pool tenga direcciones libres. Lo primero que se rompe es **un nodo que agota su pool, o un nodo *nuevo* que se une y nunca recibe un PodCIDR** — su agente se queda reportando `waiting for IPAM`, y todo pod programado allí falla al iniciar. Lo segundo es que se detiene la recolección de basura de `CiliumIdentity`, con lo cual las identidades se filtran.

**A6.** `Network: Tunnel [vxlan]` es cómo los paquetes van **entre nodos** (encapsulados en VXLAN). `Host: BPF` es cómo los paquetes atraviesan el **namespace de red del host en el camino hacia y desde el pod** — el "eBPF host routing" de Cilium evita la parte alta del stack de red del host (netfilter, búsquedas en la tabla de ruteo) redirigiendo directamente desde el programa BPF del dispositivo físico hacia el dispositivo del pod. Son ortogonales: podés tener BPF host routing tanto con ruteo de red por túnel como nativo. Sin él (`Host: Legacy`) los paquetes toman la ruta normal de iptables/ruteo, costando throughput y latencia.

**A7.** **TCX** (`BPF_PROG_TYPE_SCHED_CLS` enganchado vía `bpf_link` en `BPF_TCX_INGRESS`/`BPF_TCX_EGRESS`) es una API de enganche del kernel introducida en **Linux 6.6**. Reemplaza el viejo enganche de clasificador/qdisc de `tc` con propiedad basada en links, dando reemplazo atómico, orden determinista entre múltiples programas, y desenganche automático cuando el dueño del link termina — lo cual elimina toda una clase de bugs de "filtro tc obsoleto que quedó tras un crash del agente". Cuando el kernel es más viejo, Cilium recurre al clásico **tc BPF vía una qdisc `clsact`** (`tc filter add dev … ingress bpf …`), visible con `tc filter show dev <lxc> ingress`.

**A8.** `podSubnet` en la configuración de kind sólo lo consume el kube-controller-manager (`--cluster-cidr`) y el CNI por defecto — que deshabilitaste. El **IPAM cluster-pool de Cilium lo ignora por completo** y recorta desde su propio `clusterPoolIPv4PodCIDRList`, cuyo valor por defecto es `10.0.0.0/8` con `clusterPoolIPv4MaskSize: 24`. El rango por nodo se registra en el CRD `CiliumNode` en **`spec.ipam.podCIDRs`** (verificá con `kubectl get ciliumnode cca-lab-worker -o jsonpath='{.spec.ipam.podCIDRs}'`). Para respetar la subred de kind pondrías `--set ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}`; para que Cilium lea `node.spec.podCIDR` en su lugar, usá `--set ipam.mode=kubernetes`.

### Ejercicio 3

**A9.** `cilium_host`/`cilium_net` es el par veth que conecta el **namespace de red del host con el datapath gestionado por Cilium**. `cilium_host` lleva la **IP de router** del nodo (también llamada la IP de `cilium_host` o IP de gateway) — la primera dirección del PodCIDR del nodo, del estilo `10.0.1.87` en la lista `Allocated addresses` bajo la etiqueta `(router)`. La ruta por defecto de cada pod apunta a ella (`default via <router-ip> dev eth0`), y es la dirección de origen usada para el tráfico originado en el host que debe aparentar venir desde dentro de la red de pods (por ejemplo, sondas de salud que atraviesan el overlay).

**A10.** La dirección se nombra **desde el punto de vista del kernel del host sobre ese dispositivo**, no del pod. El dispositivo `lxcXXXX` vive en el namespace del host y es el par del `eth0` del pod. Un paquete que el pod *envía* llega al extremo del host del veth como **ingress en `lxcXXXX`** — de ahí `cil_from_container` en `tcx/ingress`. Simétricamente, un paquete destinado *al* pod se transmite hacia afuera de `lxcXXXX`, es decir **egress**, manejado por `cil_to_container`. Entender esto al revés es una fuente clásica de confusión al leer `bpftool net show`.

**A11.** Un mapa BPF vive sólo mientras algo mantenga un descriptor de archivo hacia él. Pinearlo a bpffs (`/sys/fs/bpf`) crea una referencia de sistema de archivos que mantiene el mapa vivo **independientemente del proceso del agente**. Consecuencia: cuando el agente se reinicia o se actualiza, los mapas — y por lo tanto la tabla de conntrack, el ipcache, las tablas de LB y los mapas de políticas — **sobreviven**, así que las conexiones existentes no se rompen y la traducción de Service sigue funcionando durante la ventana de reinicio. Al arrancar, el agente **reabre los mapas pineados y los reconcilia** contra el estado deseado desde Kubernetes, agregando/quitando deltas en lugar de reconstruir desde cero. Si la *definición* del mapa cambió (nuevo layout de clave/valor en una versión nueva de Cilium), el agente detecta el desajuste, lo despinea y lo recrea — que es por lo que las actualizaciones que cambian layouts de mapas causan una breve pérdida del estado correspondiente.

**A12.** El **mapa de políticas es por endpoint** porque el conjunto de veredictos de política es una propiedad de las reglas de una identidad: el datapath hace una sola búsqueda con clave `(identidad del peer, puerto, protocolo, dirección)` en el mapa de *ese* endpoint, así que la búsqueda queda O(1) y pequeña sin importar cuántas otras cargas de trabajo existan en el nodo. Hacerlo global forzaría a meter el ID del endpoint en la clave y haría explotar tanto el espacio de claves como la estructura de tail calls. El **conntrack es global** porque es un recurso compartido del nodo — un único LRU hash grande y predimensionado es mucho más eficiente en memoria que N tablas por endpoint que cada una tiene que dimensionarse para el peor caso, y permite que el nodo limite la memoria total de conntrack. El flag para conntrack por endpoint es **`--enable-endpoint-routes` combinado con la opción legacy de CT por endpoint (`conntrack-local` / `--enable-local-conntrack`)**; la razón para evitarlo es la amplificación de memoria y la pérdida de una única política de contabilidad/desalojo de conntrack a nivel de nodo — con cientos de endpoints por nodo, multiplicás el overhead de la tabla por la cantidad de endpoints.

**A13.** Ambos, y la distinción importa. La **llamada `DEL` del plugin CNI** es la ruta principal: el kubelet invoca `cilium-cni DEL` al desmontar el sandbox, lo cual le indica al agente que quite el endpoint, libere la IP y borre la entrada de `cilium_lxc`. Como el `DEL` de CNI puede perderse (reinicio del nodo, crash del kubelet, agente caído durante el borrado), el agente además corre un **pase de restauración/reconciliación contra el watch de pods de Kubernetes** al arrancar y periódicamente, borrando endpoints cuyo pod ya no existe. A nivel de clúster, `cilium-operator` hace GC de objetos `CiliumEndpoint` huérfanos. Nada depende de un único mecanismo.

### Ejercicio 4

**A14.** Exactamente **una** entrada: `Allow / Ingress / identity 33807 / 80 TCP`. Esa entrada es idéntica en cada nodo que hospeda un pod `deathstar`, e idéntica en el mapa de políticas de cada endpoint `deathstar`. Escalar a **400 réplicas agrega cero entradas al mapa de políticas** — la identidad se deriva del conjunto de labels, y 400 pods con labels idénticos colapsan a una identidad. Esta es la propiedad central de escalado del modelo de Cilium frente a implementaciones basadas en conjuntos de IPs, donde una regla "allow from X" crece linealmente con la cantidad de réplicas de X y cada evento de escalado dispara un recálculo del conjunto de reglas en cada nodo.

**A15.** Los dos labels sintetizados son:
- **`k8s:io.kubernetes.pod.namespace=default`** — hace que el namespace sea parte de la identidad, para que `endpointSelector` y `fromEndpoints` puedan expresar alcance por namespace (y para que pods con labels idénticos en namespaces distintos obtengan identidades *diferentes*). Cilium también agrega `k8s:io.cilium.k8s.namespace.labels.<key>=<value>` reflejando los propios labels del objeto namespace, que es lo que permite que funcione `fromEndpoints: matchLabels: {io.cilium.k8s.namespace.labels.team: payments}`.
- **`k8s:io.cilium.k8s.policy.serviceaccount=default`** — hace que la ServiceAccount del pod sea parte de la identidad, habilitando política basada en ServiceAccount (`fromEndpoints: matchLabels: {io.cilium.k8s.policy.serviceaccount: frontend}`), es decir, política atada a la identidad de la carga de trabajo en lugar de a labels de pod que un atacante podría fijar.

(`k8s:io.cilium.k8s.policy.cluster=default` es el tercero, y es lo que hace que las identidades sean inequívocas a través de un ClusterMesh.)

**A16.** El paquete lleva la **identidad del pod origen** (por ejemplo `33807`) de punta a punta — ese es todo el punto: la identidad viaja con el paquete, en el campo reservado/adyacente al VNI de la cabecera VXLAN en modo túnel, o en un campo adyacente de IPsec/WireGuard o vía la búsqueda en el ipcache en modo nativo. El programa `cil_to_container` del nodo receptor usa esa identidad para la búsqueda de política. `reserved:host` (1) y `reserved:remote-node` (6) son distintos porque **"el host en el que estoy corriendo" y "algún otro nodo del clúster" ameritan niveles de confianza diferentes**: el tráfico desde el namespace del host local (sondas de salud del kubelet, pods hostNetwork) es inherentemente local y se permite por defecto, mientras que el tráfico desde un nodo *remoto* es un principal de seguridad distinto que quizás quieras normar por separado — esto es lo que hace expresable el Host Firewall (`CiliumClusterwideNetworkPolicy` con `nodeSelector`). Antes de que existiera esta separación, los nodos remotos se englobaban en `reserved:host` y no podían distinguirse.

**A17.** El bit alto (`1 << 24`, es decir 16777216) marca una **identidad de alcance local**: una que sólo tiene significado en el nodo que la asignó. Las identidades basadas en labels se asignan **a nivel de clúster** mediante un asignador compartido (el CRD `CiliumIdentity` o el kvstore) para que la identidad `10530` signifique el mismo conjunto de labels en cada nodo — requisito, porque el número viaja dentro del paquete. Las identidades CIDR no pueden funcionar así porque se derivan de **el conjunto de reglas de política CIDR que un nodo dado tiene que aplicar**, y el mismo prefijo IP puede estar cubierto por prefijos distintos y solapados en nodos distintos; el mapeo es una función local al nodo de su árbol local de longest-prefix-match, no un hecho global. Por eso se asignan desde un rango local al nodo y nunca se ponen en el cable como identidad de peer para que un nodo remoto las interprete.

**A18.** Cada combinación única de labels produce un nuevo objeto `CiliumIdentity` y una nueva identidad numérica. Un webhook que inyecta un SHA por build da **una identidad por pod**, lo cual destruye toda la propiedad de escalado: las identidades crecen linealmente con la cantidad de pods, los objetos `CiliumIdentity` inundan etcd, la GC del operator se atrasa, los mapas de políticas crecen linealmente con la cantidad de peers, y podés llegar al techo de identidades locales al clúster (rango por defecto 256–65535). La mitigación es `--labels` / el `labels:` de Helm en el agente — una lista blanca explícita (o una regex `--exclude-labels`) de qué claves de label participan en el cálculo de identidad. Auditar esa lista es un paso estándar de endurecimiento en producción.

**A19.** La alternativa es un **backend kvstore — etcd** (`identityAllocationMode: kvstore`, históricamente también Consul). Razones para elegirlo: la asignación y propagación de identidades pasa por un etcd dedicado en lugar del API server de Kubernetes, lo cual saca escrituras de identidad de altísima rotación del propio etcd del clúster y de su fan-out de watches — esto importa a gran escala (miles de nodos / alta rotación de pods), y un kvstore dedicado también es el transporte usado por ClusterMesh. El costo es un componente con estado adicional que hay que operar, asegurar y respaldar; el modo CRD es el predeterminado desde 1.6 precisamente porque la mayoría de los clústeres prefiere no tener una dependencia extra.

### Ejercicio 5

**A20.** `tunnelendpoint=0.0.0.0` significa **"esta IP es local a este nodo"** — no hay endpoint de túnel remoto hacia el cual encapsular; el datapath resuelve el destino en `cilium_lxc` y redirige directo al dispositivo del pod local (`redirect_peer`/`redirect_neigh`), sin tocar nunca el overlay. Un `tunnelendpoint` distinto de cero significa que el destino está en **ese** nodo remoto, así que el paquete se empuja hacia `cilium_vxlan` con el destino externo fijado en `172.18.0.4`. Concretamente: el tráfico pod-a-pod dentro del mismo nodo nunca se encapsula y nunca sale del nodo.

**A21.** Responden preguntas distintas en momentos distintos.
- El **`/32`** es la entrada autoritativa por endpoint: provee la **identidad de seguridad** para la búsqueda de política, más el endpoint de túnel exacto. Las decisiones de política usan esto.
- El **`/24`** es el resumen a nivel de nodo, instalado cuando se aprende un `CiliumNode`. Provee alcanzabilidad y la identidad `reserved:remote-node` para el *nodo*, y es lo que permite que un paquete sea reenviado al nodo correcto incluso para un destino cuyo `/32` todavía no se aprendió.

El ipcache es un **trie de longest-prefix-match (LPM)**, así que un `/32` específico siempre gana sobre el `/24` que lo cubre. Si sólo está el `/24` cuando llega un paquete, la búsqueda resuelve a la identidad `6` (`reserved:remote-node`) en lugar de la identidad real de la carga de trabajo, y una regla "allow from `class=tiefighter`" **no** va a coincidir — el paquete se descarta como `Policy denied`. Este es el mecanismo detrás de los clásicos drops transitorios justo después de que un pod arranca en un nodo remoto, antes de que se complete la propagación del ipcache.

**A22.** Overhead de VXLAN = **cabecera Ethernet externa 14 + cabecera IPv4 externa 20 + cabecera UDP externa 8 + cabecera VXLAN 8 = 50 bytes**. 1500 − 50 = **1450**.

Si forzás la MTU del pod a 1500, una trama de pod de 1500 bytes completos se vuelve de 1550 bytes tras la encapsulación, excediendo la MTU de 1500 del enlace del nodo. Las peticiones chicas tienen éxito porque nunca producen un segmento de tamaño completo; un `POST` grande se cuelga porque los segmentos de *datos* son de tamaño completo y se descartan, mientras que el handshake y las cabeceras pasaron. Clásico **agujero negro de PMTU**: TCP retransmite el mismo segmento sobredimensionado para siempre. Es intermitente y dependiente del tráfico, que es lo que lo hace tan doloroso de diagnosticar — y es por eso que `hubble observe` mostrando un handshake limpio seguido de silencio debería empujarte directo a la MTU.

**A23.** `autoDirectNodeRoutes` instala una ruta simple del kernel en cada nodo diciendo "el PodCIDR remoto X es alcanzable vía la IP del nodo Y". Eso sólo funciona si **todos los nodos están en el mismo segmento L2 / red L3 directamente conectada** — el siguiente salto debe ser directamente alcanzable, y ningún router intermedio debe necesitar conocer los PodCIDRs. En una VPC de nube, nodos en distintas subredes están separados por el router de la VPC, que no tiene ruta para las IPs de pods, así que los paquetes se descartan o la verificación de origen/destino los rechaza. La alternativa cloud-native es **IPAM del proveedor de nube con ruteo nativo**: `ipam.mode=eni` en AWS (los pods obtienen IPs reales de la VPC desde direcciones secundarias de ENI, así que la VPC las rutea nativamente), `ipam.mode=azure` / IPAM delegado de Azure, o el modo `gke` en GKE con rangos de alias IP. La alternativa genérica cuando el underlay habla BGP es el **BGP Control Plane** de Cilium (`CiliumBGPClusterConfig`), anunciando los PodCIDRs al fabric.

**A24.** En modo de ruteo nativo el agente **no crea `cilium_vxlan` en absoluto** (o lo elimina), y **`cilium_tunnel_map` no se usa** — las entradas del ipcache llevan `tunnelendpoint=0.0.0.0` también para pods remotos, porque no hay encapsulación. El trabajo de "cómo llego a ese nodo" pasa a la **tabla de ruteo del propio host** (poblada por `autoDirectNodeRoutes`, por BGP, o por la tabla de rutas de la VPC de la nube), consultada a través de `cilium_node_map` / el ipcache para la identidad y mediante la búsqueda FIB normal (`bpf_fib_lookup`) para el siguiente salto. La MTU del pod también sube a la MTU completa del underlay, ya que desaparece el overhead de 50 bytes.

### Ejercicio 6

**A25.** La traducción ocurrió en el **hook BPF de cgroup v2 `cgroup/connect4`**, dentro de la syscall `connect()`, antes de que se construyera ningún paquete — la dirección de destino del socket se reescribe del ClusterIP a un backend seleccionado, así que el primerísimo SYN en el cable ya lleva `10.0.2.31:80`. Consecuencia de rendimiento frente al DNAT de iptables: (a) **sin NAT por paquete** — la traducción es una vez por conexión, al armar el socket, no en cada paquete; (b) **no hace falta una entrada de conntrack para la traducción del Service en sí** ni una búsqueda de NAT inverso en la ruta de retorno, ya que el socket nunca mintió sobre su destino; (c) **búsqueda hash O(1)** en lugar de un recorrido lineal de las cadenas `KUBE-SERVICES`/`KUBE-SVC-*` que crece con la cantidad de Services. El resultado práctico es que la latencia se mantiene plana a medida que crece el número de Services, mientras que el modo iptables se degrada de forma medible pasados unos pocos miles de Services.

**A26.** El LB de socket sólo cubre clientes cuyo `connect()`/`sendmsg()` ocurre **dentro de un cgroup al que están enganchados los programas BPF de Cilium** — es decir, pods gestionados por Cilium, y (con el enganche en la raíz del cgroup) procesos del namespace del host en ese nodo. **No** cubre tráfico que nunca hizo `connect()` localmente: paquetes que **llegan al nodo desde afuera** (NodePort, LoadBalancer, externalIPs, HostPort), y tráfico desde namespaces de red fuera del alcance de cgroups de Cilium. Esos los manejan los **programas BPF de tc/XDP en los dispositivos físicos del nodo** (`cil_from_netdev` en `tcx/ingress` sobre `eth0`, o un programa XDP cuando `loadBalancer.acceleration=native`), que hacen un DNAT real más una entrada en `cilium_lb4_reverse_nat` para poder destraducir la respuesta. `Socket LB Coverage: Full` en la salida de status te dice que el hook de cgroup del namespace del host también está enganchado; `Hostns-only` o un montaje de cgroup faltante significa que no lo está.

**A27.** Lo que se SNATea es la **dirección de origen de un paquete NodePort/LoadBalancer que tiene que ser reenviado a un backend en un nodo *distinto***. El nodo A recibe la petición, elige un backend en el nodo B, y debe asegurar que la respuesta vuelva por el nodo A (que tiene el estado de NAT inverso), así que reemplaza la IP de origen del cliente con la IP del nodo A. La contrapartida es la bien conocida: **el backend pierde la IP de origen original del cliente**, y hay un salto extra. La alternativa es **DSR (Direct Server Return)**, `--set loadBalancer.mode=dsr`, donde el nodo B responde directamente al cliente con la VIP del Service como origen, preservando la IP del cliente y reduciendo a la mitad la ruta de retorno. Sus contrapartidas: el destino original debe llevarse al nodo B fuera de banda (una opción IPv4 / cabecera de extensión IPv6, o una opción Geneve — `loadBalancer.dsrDispatch`), que algunos middleboxes y fabrics de nube quitan o descartan; requiere que la ruta de respuesta de B al cliente sea ruteable; y cuesta MTU. `loadBalancer.mode=hybrid` usa DSR para TCP y SNAT para UDP como compromiso.

**A28.** El backend pasa al estado **`terminating`** en `cilium_lb4_backends_v3` (visible como `(terminating)` en `cilium-dbg bpf lb list`) en lugar de ser borrado. En consecuencia: **(a) las conexiones existentes siguen siendo atendidas** — la entrada de conntrack todavía resuelve a ese backend, así que las peticiones en vuelo y las conexiones keep-alive terminan limpiamente; **(b) las conexiones nuevas nunca se le envían** — queda excluido del conjunto de selección de backends, así que ningún SYN nuevo cae en un pod que se está apagando. La entrada se elimina sólo una vez que el endpoint se borra por completo. Esto es lo que convierte una actualización progresiva de "una ráfaga de resets de conexión" en un drenaje limpio, y depende de que los campos de condición terminating del `EndpointSlice` de Kubernetes se propaguen (`enableK8sTerminatingEndpoint`, activo por defecto).

**A29.** En orden:

1. **`cany cilium-dbg service list`** (o `bpf lb list`) — confirma que el Service existe en el datapath con backends vivos, para empezar. Si falta o tiene cero backends, el problema está más arriba (EndpointSlice, selector, operator), no en la ruta del host, y parás acá.
2. **`cany cilium-dbg status --verbose | grep -A6 'KubeProxyReplacement Details'`, leyendo `Socket LB Coverage`** — `Full` significa que el hook de cgroup está enganchado en la raíz del cgroup y que los procesos del namespace del host *sí* están cubiertos; cualquier otra cosa (o un montaje de cgroup v2 malo/faltante en `/run/cilium/cgroupv2`) explica exactamente este síntoma: los pods funcionan, el host no. Esta es, por lejos, la causa más probable.
3. **`cnode $NODE cilium-dbg monitor -t trace-sock -t drop` mientras reproducís desde el nodo** (`docker exec <node> curl <clusterIP>`) — si no ves ningún evento `trace-sock`, la syscall no está siendo interceptada, confirmando (2). Si ves la traducción pero después un drop, tenés un problema de política o de ruteo en su lugar, y `-t drop` lo nombra. Una cuarta verificación útil cuando el tráfico del host debe salir por un dispositivo: comprobá que `Devices:` en la salida de status realmente liste la interfaz por la que el nodo rutea hacia afuera (`--set devices=`), ya que un dispositivo no listado no tiene `cil_from_netdev` enganchado.

### Ejercicio 7

**A30.** Ambos consumen la misma fuente: el **ring buffer de perf `cilium_events` (`BPF_MAP_TYPE_PERF_EVENT_ARRAY`)**, en el cual los programas del datapath empujan registros de trace/drop/debug/veredicto de política. `cilium-dbg monitor` es un tap crudo y local al nodo sobre ese buffer. `hubble observe` da, entre otras cosas:
- **Agregación a nivel de clúster** — Hubble Relay se abre en abanico hacia el servidor Hubble de cada nodo (gRPC en `:4244`) y fusiona los flujos, así que un solo comando muestra ambos extremos de un flujo entre nodos. `cilium-dbg monitor` sólo muestra un nodo.
- **Enriquecimiento con Kubernetes y DNS más un modelo consultable** — los eventos crudos llevan identidades numéricas e IPs; Hubble las resuelve a `namespace/pod`, nombres de servicio, FQDNs y labels, mantiene un ring buffer de flujos recientes que podés consultar retroactivamente (`--last`, `--since`), filtra del lado del servidor (`--verdict`, `--to-label`, `--protocol`, `--http-status`), emite JSON estructurado, y exporta registros L7 y métricas de Prometheus.

**A31.** Son **puntos de observación de trace** distintos en el datapath:
- **`to-overlay`** — emitido en el **nodo origen**, en el momento en que el paquete se entrega al dispositivo de túnel (`cilium_vxlan`) para su encapsulación hacia el nodo remoto.
- **`to-endpoint`** — emitido en el **nodo destino**, en el momento en que el paquete se entrega al dispositivo del pod objetivo (`cil_to_container` en la interfaz `lxc*`), *después* del veredicto de política de ingress.

Ver `to-overlay` sin un `to-endpoint` que le corresponda es la firma de un paquete perdido entre nodos — MTU del underlay, un firewall bloqueando UDP/8472, o una entrada faltante en el mapa de túneles. (Los puntos acompañantes son `to-stack`, `to-network`, `to-proxy` y `from-*`; `cilium-dbg monitor -t trace` los muestra todos.)

**A32.** El valor por defecto es **`bpf.monitorAggregation=maximum`**. Suprime eventos de trace repetidos para un flujo que ya está en un estado de conntrack conocido, emitiendo una notificación sólo cuando cambian los **flags TCP** observados (SYN, FIN, RST) o una vez por intervalo de agregación (`bpf.monitorInterval`, por defecto `5s`) — reduciendo drásticamente la presión sobre el ring buffer y el CPU en nodos ocupados. Volvelo al valor por defecto y **dejás de ver traces de reenvío por paquete para conexiones establecidas**: vas a obtener el SYN y el FIN pero no los paquetes intermedios. Crucialmente, **los eventos de drop nunca se agregan** — `--type drop` y las notificaciones de veredicto de política siempre se entregan — así que la prueba de denegación del Ejercicio 8 funciona idénticamente con el valor por defecto. Esa es la postura correcta en producción: mantené la agregación activa, y confiá en los drops más los traces por cambio de flags.

### Ejercicio 8

**A33.**
- **Denegación L3/L4 → cuelgue.** El veredicto se toma en eBPF dentro de `cil_to_container` antes de que el paquete llegue siquiera al pod, y el paquete se **descarta silenciosamente** — sin RST, sin ICMP administratively-prohibited. El SYN del cliente simplemente se desvanece, así que TCP lo retransmite (1s, 2s, 4s …) hasta que `curl -m 5` se rinde con código de salida 28. La conexión **nunca se estableció**; nada por encima de L4 estuvo involucrado. Esto es deliberado: un drop silencioso no filtra nada a un escáner sobre si el objetivo existe.
- **Denegación L7 → 403 inmediato.** Con una regla `http` presente, el programa eBPF **permite la conexión TCP y la redirige al proxy Envoy local** (aparece un `PROXY PORT` en `cilium-dbg bpf policy get`). Envoy completa el handshake TCP y el parseo TLS/HTTP, evalúa la línea de petición contra la regla, y — como `PUT /v1/exhaust-port` no coincide con ninguna regla — sintetiza él mismo una respuesta **`403 Access denied`**. El backend nunca ve la petición.

Diagnósticamente: **un cuelgue significa que el paquete murió en L3/L4 en eBPF; un 403 significa que murió en L7 en Envoy**, lo cual además te dice que la capa L3/L4 lo *permitió* y que tu problema es el matcher HTTP, no el selector de identidad.

**A34.** El default-deny de Cilium es **por endpoint y por dirección**. Un endpoint pasa a default-deny **sólo en las direcciones para las cuales al menos una regla lo selecciona**. `deathstar` está seleccionado por una política que tiene una sección `ingress:` y ninguna sección `egress:`, así que ingress pasa a `Enabled` (default-deny + los allows listados) mientras que **egress permanece `Disabled`** — completamente irrestricto, que es por lo que el mapa de políticas muestra el catch-all `Allow Egress → identity 0 (reserved:unknown) → ANY`. Los otros endpoints (`tiefighter`, `xwing`) no están seleccionados en absoluto y quedan `Disabled` en ambas direcciones.

La edición mínima para hacer egress default-deny es agregar una **sección egress vacía** a la misma política — su presencia es lo que dispara la aplicación en esa dirección:

```yaml
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
  egress: []          # <- selects the endpoint for egress; denies everything
```

En la práctica nunca enviarías `egress: []` pelado — rompe el DNS. La forma de producción permite CoreDNS explícitamente:

```yaml
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
```

El modismo equivalente en una `NetworkPolicy` estándar de Kubernetes es `policyTypes: [Ingress, Egress]` con una lista `egress` vacía; `CiliumNetworkPolicy` infiere los tipos de política a partir de qué secciones están presentes.

</details>

---

## Fuentes oficiales

- Currícula CCA — <https://github.com/cncf/curriculum/blob/master/cca/README.md>
- Introducción a Cilium y descripción de componentes — <https://docs.cilium.io/en/stable/overview/intro/> · <https://docs.cilium.io/en/stable/overview/component-overview/>
- Terminología: endpoints, identidad, labels — <https://docs.cilium.io/en/stable/gettingstarted/terminology/>
- Instalación con kind — <https://docs.cilium.io/en/stable/installation/kind/>
- Conceptos y modos de IPAM — <https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Modos de ruteo (encapsulación / nativo) — <https://docs.cilium.io/en/stable/network/concepts/routing/>
- Internals del datapath eBPF — <https://docs.cilium.io/en/stable/reference-guides/bpf/>
- Reemplazo de kube-proxy — <https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Referencia de network policy (CNP, L3/L4/L7) — <https://docs.cilium.io/en/stable/security/policy/>
- Observabilidad con Hubble — <https://docs.cilium.io/en/stable/observability/hubble/>
- Referencia de comandos de `cilium-dbg` — <https://docs.cilium.io/en/stable/cmdref/cilium-dbg/>
- Guía de troubleshooting — <https://docs.cilium.io/en/stable/operations/troubleshooting/>
- Inicio rápido de kind — <https://kind.sigs.k8s.io/docs/user/quick-start/>