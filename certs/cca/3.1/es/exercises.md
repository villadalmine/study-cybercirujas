# CCA 3.1 — Kubernetes Networking con Cilium
## Ejercicios guiados (laboratorio de nivel productivo)

> **Peso en el examen:** 20 %
> **Fuente de referencia:** [Currícula CCA](https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md)
> **Documentación de referencia usada a lo largo del texto:** [docs.cilium.io — Concepts / Networking](https://docs.cilium.io/en/stable/network/), [Kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/), [IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/), [Routing](https://docs.cilium.io/en/stable/network/concepts/routing/), [Masquerading](https://docs.cilium.io/en/stable/network/concepts/masquerading/)

---

## 0. Prerrequisitos del laboratorio

Necesitás un host Linux (se recomienda kernel ≥ 5.10, ≥ 5.15 para el attach TCX), Docker, `kind` ≥ 0.23, `kubectl`, `helm` y la CLI `cilium` (`cilium-cli` ≥ v0.16).

```bash
# Verify the kernel is new enough for the full eBPF datapath
uname -r
# 6.8.0-45-generic

# Verify BPF filesystem support and cgroup v2 (required by socket-LB)
mount | grep -E 'bpf|cgroup2'
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)

cilium version --client
# cilium-cli: v0.16.20 compiled with go1.23.2 on linux/amd64
```

Dos convenciones que se usan en todos los ejercicios:

* `cilium` (la CLI en tu laptop) gestiona la **instalación**.
* `cilium-dbg` (el binario **dentro** del pod del agente) inspecciona el **datapath**. En Cilium ≤ 1.14 ese binario se llamaba `cilium`; desde 1.15 es `cilium-dbg` para eliminar la ambigüedad. Confundir estos dos es la fuente más común de tiempo perdido en el laboratorio del examen.

---

## Ejercicio 1 — El contrato CNI: un clúster sin red

**Objetivo:** observar exactamente qué partes de Kubernetes se rompen sin un plugin CNI, para después poder atribuir cada comportamiento recuperado a un subsistema concreto de Cilium.

### Pasos

1. Escribí la definición del clúster. Fijate en las tres decisiones deliberadas: sin CNI por defecto, sin kube-proxy, y un Pod CIDR que coincide con el default del cluster-pool de Cilium.

```bash
cat > kind-cca.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-net
networking:
  disableDefaultCNI: true      # no kindnet
  kubeProxyMode: "none"        # no iptables/IPVS service proxy
  podSubnet: "10.0.0.0/8"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --config kind-cca.yaml
```

2. Inspeccioná el estado de readiness de los nodos y el motivo detrás de él.

```bash
kubectl get nodes
```

```
NAME                     STATUS     ROLES           AGE   VERSION
cca-net-control-plane    NotReady   control-plane   45s   v1.31.0
cca-net-worker           NotReady   <none>          25s   v1.31.0
cca-net-worker2          NotReady   <none>          25s   v1.31.0
```

```bash
kubectl describe node cca-net-worker | grep -A3 'Ready '
```

```
  Ready   False   Fri, 01 Sep 2026 10:02:11 +0000   KubeletNotReady
          container runtime network not ready: NetworkReady=false
          reason:NetworkPluginNotReady message:Network plugin returns error:
          cni plugin not initialized
```

3. Confirmá que el directorio de configuración CNI está vacío y que el kubelet lo está sondeando.

```bash
docker exec cca-net-worker ls -la /etc/cni/net.d/
```

```
total 8
drwxr-xr-x 1 root root 4096 Sep  1 10:02 .
drwxrwxr-x 1 root root 4096 Sep  1 10:02 ..
```

4. Observá qué Pods siguen programándose y cuáles no.

```bash
kubectl get pods -A -o wide
```

```
NAMESPACE     NAME                                            READY   STATUS    IP            NODE
kube-system   coredns-7c65d6cfc9-8xk4p                        0/1     Pending   <none>        <none>
kube-system   etcd-cca-net-control-plane                      1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-apiserver-cca-net-control-plane            1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-controller-manager-cca-net-control-plane   1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-scheduler-cca-net-control-plane            1/1     Running   172.18.0.2    cca-net-control-plane
```

5. Mirá qué cree el API server sobre los Pod CIDRs, incluso sin ningún CNI instalado.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
```

```
NAME                    PODCIDR
cca-net-control-plane   10.0.0.0/24
cca-net-worker          10.1.0.0/24
cca-net-worker2         10.2.0.0/24
```

### Comprobá tu comprensión — Bloque 1

* **Q1.1** — Los Pods del control-plane (`etcd`, `kube-apiserver`) están `Running` con IP `172.18.0.2` mientras que CoreDNS está `Pending`. ¿Qué propiedad de los Pods del control-plane los hace inmunes a la ausencia de CNI, y cuál es exactamente la IP que llevan?
* **Q1.2** — ¿Qué componente reporta realmente `NetworkPluginNotReady`: el API server, el scheduler o el kubelet? ¿De dónde obtiene ese componente la señal?
* **Q1.3** — `kube-controller-manager` ya asignó `10.1.0.0/24` a `cca-net-worker`. Si ahora instalás Cilium con `ipam.mode=cluster-pool`, ¿los Pods de ese nodo recibirán direcciones de `10.1.0.0/24`? Justificá.
* **Q1.4** — Nombrá los dos artefactos que un plugin CNI debe colocar en el sistema de archivos del nodo para que el kubelet considere que la red está lista.

---

## Ejercicio 2 — Instalar Cilium y leer el estado del datapath

**Objetivo:** instalar Cilium como CNI **y** como service proxy, y después aprender a leer `cilium-dbg status --verbose` línea por línea. Esa única salida responde aproximadamente un tercio de las preguntas de datapath que te van a hacer.

### Pasos

1. Instalá Cilium con cada perilla relevante explicitada en vez de dejada por defecto. Ser explícito es el punto: en el examen tenés que saber qué valor produce qué datapath.

```bash
cilium install --version 1.16.5 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=cca-net-control-plane \
  --set k8sServicePort=6443 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={10.0.0.0/8} \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set bpf.masquerade=true \
  --set operator.replicas=1
```

```
ℹ️  Using Cilium version 1.16.5
🔮 Auto-detected cluster name: kind-cca-net
🔮 Auto-detected kube-proxy has not been installed
ℹ️  Cilium will fully replace all functionalities of kube-proxy
```

2. Esperá la convergencia y leé el resumen a nivel de la CLI.

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

DaemonSet              cilium                   Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 3
                       cilium-envoy             Running: 3
                       cilium-operator          Running: 1
Cluster Pods:          3/3 managed by Cilium
Helm chart version:    1.16.5
```

3. Verificá que el nodo ahora está Ready y que apareció el archivo de configuración CNI.

```bash
kubectl get nodes
docker exec cca-net-worker cat /etc/cni/net.d/05-cilium.conflist
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

4. Creá un alias de conveniencia que apunte al agente en uno de los workers. Todos los ejercicios posteriores lo usan.

```bash
export CIL_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=cca-net-worker \
  -o jsonpath='{.items[0].metadata.name}')
alias cdbg="kubectl -n kube-system exec -i $CIL_POD -c cilium-agent -- cilium-dbg"
echo $CIL_POD
```

5. Leé el estado completo del datapath.

```bash
cdbg status --verbose | head -45
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.0) [linux/amd64]
KubeProxyReplacement:    True   [eth0   172.18.0.3 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
Cilium:                  Ok   1.16.5 (v1.16.5-a1b2c3d4)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 3/254 allocated from 10.0.1.0/24,
Allocated addresses:
  10.0.1.19 (kube-system/coredns-7c65d6cfc9-8xk4p)
  10.0.1.135 (health)
  10.0.1.170 (router)
ClusterMesh:             0/0 clusters ready
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       48/48 healthy
Proxy Status:            OK, ip 10.0.1.170, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Encryption:              Disabled
Cluster health:          3/3 reachable   (2026-09-01T10:14:02Z)
Modules Health:          Stopped(0) Degraded(0) OK(82)
```

6. Inspeccioná los detalles específicos del reemplazo de kube-proxy.

```bash
cdbg status --verbose | grep -A14 'KubeProxyReplacement Details'
```

```
KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0  172.18.0.3 fe80::42:acff:fe12:3 (Direct Routing)
  Mode:                   SNAT
  Backend Selection:      Random
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Disabled
  Services:
  - ClusterIP:            Enabled
  - NodePort:             Enabled (Range: 30000-32767)
  - LoadBalancer:         Enabled
  - externalIPs:          Enabled
  - HostPort:             Enabled
```

### Comprobá tu comprensión — Bloque 2

* **Q2.1** — `Routing: Network: Tunnel [vxlan]   Host: BPF`. Descomponé esta línea: ¿qué describe *Network*, qué describe *Host*, y qué diría cada campo si hubieras instalado con `routingMode=native` y `bpf.masquerade=false`?
* **Q2.2** — La línea `IPAM` muestra `3/254 allocated from 10.0.1.0/24`, pero el `.spec.podCIDR` de este nodo era `10.1.0.0/24`. ¿Qué componente asignó `10.0.1.0/24`, y dónde se persiste esa asignación?
* **Q2.3** — Tres de las direcciones asignadas no pertenecen a ningún Pod de usuario: `health`, `router`, y un Pod de CoreDNS. ¿Para qué se usa la IP `router` (también llamada IP `cilium_host`), y para qué se usa `health`?
* **Q2.4** — ¿Por qué `cilium install` requiere `k8sServiceHost` / `k8sServicePort` cuando kube-proxy está ausente? Describí la circularidad de bootstrap que esto rompe.
* **Q2.5** — `Attach Mode: TCX`. ¿Cuál es la alternativa, y qué versión del kernel introdujo TCX?

---

## Ejercicio 3 — IPAM: cómo un Pod obtiene su dirección

**Objetivo:** trazar una dirección IP desde el pool del operator, pasando por el CRD `CiliumNode`, hasta el `CiliumEndpoint` y finalmente hasta el par veth en el netns del Pod.

### Pasos

1. Mirá el objeto de asignación por nodo.

```bash
kubectl get ciliumnodes
```

```
NAME                    CILIUMINTERNALIP   INTERNALIP    AGE
cca-net-control-plane   10.0.0.144         172.18.0.2    6m
cca-net-worker          10.0.1.170         172.18.0.3    6m
cca-net-worker2         10.0.2.61          172.18.0.4    6m
```

```bash
kubectl get ciliumnode cca-net-worker -o jsonpath='{.spec.ipam.podCIDRs}{"\n"}'
```

```
["10.0.1.0/24"]
```

2. Desplegá una carga de trabajo distribuida entre ambos workers.

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=4
kubectl rollout status deploy/web
kubectl get pods -o wide -l app=web
```

```
NAME                   READY   STATUS    IP           NODE
web-6f8d4c9b7-2wqzr    1/1     Running   10.0.1.201   cca-net-worker
web-6f8d4c9b7-6rjhk    1/1     Running   10.0.2.118   cca-net-worker2
web-6f8d4c9b7-9lbxc    1/1     Running   10.0.1.44    cca-net-worker
web-6f8d4c9b7-pmt8z    1/1     Running   10.0.2.203   cca-net-worker2
```

3. Mirá el objeto del lado de Cilium para uno de los Pods.

```bash
kubectl get ciliumendpoints
```

```
NAME                  SECURITY IDENTITY   ENDPOINT STATE   IPV4         IPV6
web-6f8d4c9b7-2wqzr   14127               ready            10.0.1.201
web-6f8d4c9b7-6rjhk   14127               ready            10.0.2.118
web-6f8d4c9b7-9lbxc   14127               ready            10.0.1.44
web-6f8d4c9b7-pmt8z   14127               ready            10.0.2.203
```

4. Correlacioná con la tabla de endpoints del agente en `cca-net-worker`.

```bash
cdbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS                              IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
331        Disabled           Disabled          4          reserved:health                     10.0.1.135   ready
794        Disabled           Disabled          14127      k8s:app=web                         10.0.1.44    ready
1288       Disabled           Disabled          1          reserved:host                                    ready
2104       Disabled           Disabled          14127      k8s:app=web                         10.0.1.201   ready
3376       Disabled           Disabled          25911      k8s:k8s-app=kube-dns                10.0.1.19    ready
```

5. Inspeccioná la plomería del datapath en el nodo para el endpoint `2104`.

```bash
cdbg endpoint get 2104 -o jsonpath='{[0].status.networking}' | python3 -m json.tool
```

```json
{
    "addressing": [{"ipv4": "10.0.1.201", "ipv4-pool-name": "default"}],
    "host-mac": "3e:1a:9c:44:8b:02",
    "interface-index": 14,
    "interface-name": "lxc7f3a19d2c0e4",
    "mac": "ba:0c:11:8e:7d:41"
}
```

```bash
docker exec cca-net-worker ip -d link show lxc7f3a19d2c0e4
```

```
14: lxc7f3a19d2c0e4@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP
    link/ether 3e:1a:9c:44:8b:02 brd ff:ff:ff:ff:ff:ff link-netnsid 2
    veth
```

6. Confirmá los programas eBPF adjuntos a esa interfaz.

```bash
docker exec cca-net-worker bpftool net show dev lxc7f3a19d2c0e4
```

```
tc:
lxc7f3a19d2c0e4(14) tcx/ingress cil_from_container prog_id 412 link_id 39
lxc7f3a19d2c0e4(14) tcx/egress cil_to_container prog_id 418 link_id 40
```

7. Mirá dentro del namespace de red del Pod.

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- ip route
```

```
default via 10.0.1.170 dev eth0 mtu 1450
10.0.1.170 dev eth0 scope link
```

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- ip neigh
```

```
10.0.1.170 dev eth0 lladdr 3e:1a:9c:44:8b:02 PERMANENT
```

### Comprobá tu comprensión — Bloque 3

* **Q3.1** — El gateway por defecto del Pod es `10.0.1.170`, que es la IP `cilium_host` (router) del nodo, y la entrada ARP para él es `PERMANENT`. ¿Por qué Cilium instala una entrada de vecino estática en lugar de depender de la resolución ARP? ¿A qué dirección MAC apunta?
* **Q3.2** — Cada Pod tiene exactamente dos rutas y una configuración de estilo `/32` en vez de una ruta de subred hacia `10.0.1.0/24`. Explicá la intención de diseño — ¿dónde se toma realmente la decisión de forwarding?
* **Q3.3** — La interfaz `lxc*` tiene `mtu 1450` mientras que la `eth0` del nodo tiene 1500. Calculá el delta de 50 bytes para VXLAN. ¿Cuál sería el valor con Geneve, y con cifrado WireGuard habilitado encima?
* **Q3.4** — Los cuatro Pods `web` comparten la identidad de seguridad `14127`, y la identidad es idéntica en ambos nodos. ¿Cuál es el alcance de una identidad de seguridad, y qué componente la asigna?
* **Q3.5** — El endpoint `1288` tiene identidad `1` (`reserved:host`) y no tiene IPv4 en el listado. ¿Qué representa este endpoint, y por qué importa para los Pods `hostNetwork`?

---

## Ejercicio 4 — Modo de routing: tunnel (VXLAN) versus native routing

**Objetivo:** ver la encapsulación en el cable, leer el mapa de túneles, después cambiar el clúster a native routing y observar el cambio en el datapath.

### Pasos

1. Leé el mapa de túneles en `cca-net-worker`. Mapea *Pod CIDR remoto* → *IP de underlay del nodo remoto*.

```bash
cdbg bpf tunnel list
```

```
TUNNEL         VALUE
10.0.0.0:0     172.18.0.2:0
10.0.2.0:0     172.18.0.4:0
```

2. Confirmá el dispositivo de túnel y su puerto.

```bash
docker exec cca-net-worker ip -d link show cilium_vxlan
```

```
6: cilium_vxlan: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN
    link/ether 4a:8e:11:0f:2b:73 brd ff:ff:ff:ff:ff:ff
    vxlan external id 0 srcport 0 0 dstport 8472 nolearning ttl auto ageing 300 udpcsum
```

3. Capturá un paquete Pod-a-Pod entre nodos en la interfaz de underlay. En una terminal:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'udp port 8472' -c 4 -vv
```

En una segunda terminal, generá el tráfico (origen en `worker`, destino en `worker2`):

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- curl -s -o /dev/null -w '%{http_code}\n' http://10.0.2.118
```

Captura esperada:

```
10:31:44.118203 172.18.0.3.51923 > 172.18.0.4.8472: VXLAN, flags [I] (0x08), vni 0
    10.0.1.201.44112 > 10.0.2.118.80: Flags [S], seq 2839114923, win 64860,
      options [mss 1410,sackOK,TS val 913 ecr 0,nop,wscale 7], length 0
10:31:44.118688 172.18.0.4.39117 > 172.18.0.3.8472: VXLAN, flags [I] (0x08), vni 0
    10.0.2.118.80 > 10.0.1.201.44112: Flags [S.], seq 1194772341, ack 2839114924, ...
```

4. Notá la *ausencia* de source NAT: el origen interno sigue siendo la IP del Pod `10.0.1.201`. Verificá por qué leyendo el CIDR de masquerade.

```bash
cdbg status | grep Masquerading
```

```
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

5. Ahora cambiá el clúster a **native routing**. En kind, todos los nodos están sobre el mismo bridge de Docker, así que son adyacentes en L2 y `autoDirectNodeRoutes` puede instalar las rutas.

```bash
cilium upgrade --reuse-values \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Verificá el nuevo datapath.

```bash
cdbg status | grep -E 'Routing|Masquerading'
```

```
Routing:        Network: Native   Host: BPF
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

```bash
docker exec cca-net-worker ip route
```

```
default via 172.18.0.1 dev eth0
10.0.0.0/24 via 172.18.0.2 dev eth0 proto kernel
10.0.1.0/24 via 10.0.1.170 dev cilium_host proto kernel src 10.0.1.170
10.0.1.170 dev cilium_host proto kernel scope link
10.0.2.0/24 via 172.18.0.4 dev eth0 proto kernel
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.3
```

7. Confirmá que el mapa de túneles ahora está vacío y que la MTU se recuperó.

```bash
cdbg bpf tunnel list
```

```
TUNNEL   VALUE
```

```bash
kubectl delete pod -l app=web --wait
kubectl exec deploy/web -- ip link show eth0 | head -1
```

```
25: eth0@if26: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
```

8. Capturá de nuevo — el paquete ahora está sin encapsular.

```bash
docker exec cca-net-worker tcpdump -ni eth0 'net 10.0.0.0/8 and tcp port 80' -c 2
```

```
10:44:02.771 IP 10.0.1.58.49224 > 10.0.2.91.80: Flags [S], seq 771290033, win 64240, length 0
10:44:02.772 IP 10.0.2.91.80 > 10.0.1.58.49224: Flags [S.], seq 33091772, ack 771290034, length 0
```

### Comprobá tu comprensión — Bloque 4

* **Q4.1** — El dispositivo VXLAN usa el puerto destino **8472**, no el 4789 asignado por la IANA. ¿Por qué? ¿Qué puerto usaría Geneve?
* **Q4.2** — El dispositivo `cilium_vxlan` muestra `external` e `id 0` (VNI 0). ¿Qué significa "modo external", y qué componente provee la clave de túnel en tiempo de ejecución?
* **Q4.3** — En el paso 3 la IP de origen interna es la IP del Pod, sin masquerade. Enunciá la regla de masquerading que Cilium aplica por defecto y por qué `10.0.2.118` está exenta de ella.
* **Q4.4** — `autoDirectNodeRoutes=true` funcionó en kind. Nombrá la precondición topológica que requiere, y describí qué tenés que hacer en su lugar en una VPC cloud donde los nodos están en subredes distintas.
* **Q4.5** — Después de cambiar a native routing, ¿por qué los Pods existentes mantuvieron MTU 1450 hasta ser recreados? ¿Cuál es el procedimiento seguro en producción para este cambio?
* **Q4.6** — `ipv4NativeRoutingCIDR=10.0.0.0/8` es obligatorio en modo native con BPF masquerade. ¿Qué hace el agente con el tráfico destinado *fuera* de ese CIDR?

---

## Ejercicio 5 — Identidad, ipcache, y cómo Cilium sabe quién es quién

**Objetivo:** entender el modelo de identidad, que es el sustrato tanto de la policy como de la observabilidad.

### Pasos

1. Listá las identidades a nivel de clúster.

```bash
kubectl get ciliumidentities
```

```
NAME    NAMESPACE     AGE
14127   default       21m
25911   kube-system   28m
39204   kube-system   28m
```

2. Inspeccioná el conjunto de etiquetas de una identidad.

```bash
cdbg identity get 14127
```

```
ID      LABELS
14127   k8s:app=web
        k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
        k8s:io.cilium.k8s.policy.cluster=kind-cca-net
        k8s:io.cilium.k8s.policy.serviceaccount=default
        k8s:io.kubernetes.pod.namespace=default
```

3. Listá las identidades reservadas.

```bash
cdbg identity list | head -12
```

```
ID     LABELS
1      reserved:host
2      reserved:world
3      reserved:unmanaged
4      reserved:health
5      reserved:init
6      reserved:remote-node
7      reserved:kube-apiserver
8      reserved:ingress
```

4. Leé el ipcache — el mapa IP → identidad (+ endpoint de túnel) que consulta cada programa eBPF.

```bash
cdbg bpf ipcache list | head -12
```

```
IP PREFIX/ADDRESS   IDENTITY
0.0.0.0/0           identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.44/32        identity=14127 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.170/32       identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.2.118/32       identity=14127 encryptkey=0 tunnelendpoint=172.18.0.4 flags=<none>
10.0.2.0/24         identity=2 encryptkey=0 tunnelendpoint=172.18.0.4 flags=<none>
172.18.0.2/32       identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
172.18.0.4/32       identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

5. Comprobá que la identidad se deriva de las etiquetas, no de la IP: agregá una etiqueta y mirá cómo cambia la identidad.

```bash
kubectl label pod -l app=web tier=frontend
sleep 5
kubectl get ciliumendpoints -l app=web
```

```
NAME                  SECURITY IDENTITY   ENDPOINT STATE   IPV4
web-6f8d4c9b7-2wqzr   51338               ready            10.0.1.201
web-6f8d4c9b7-6rjhk   51338               ready            10.0.2.118
web-6f8d4c9b7-9lbxc   51338               ready            10.0.1.44
web-6f8d4c9b7-pmt8z   51338               ready            10.0.2.203
```

6. Confirmá que el ipcache se actualizó también en el *otro* nodo.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg bpf ipcache get 10.0.1.201
```

```
10.0.1.201 maps to identity identity=51338 encryptkey=0 tunnelendpoint=172.18.0.3 flags=<none>
```

### Comprobá tu comprensión — Bloque 5

* **Q5.1** — La identidad `14127` fue asignada una sola vez y usada por cuatro Pods en dos nodos. ¿Cuál es el rango numérico para las identidades de alcance de clúster ("globales"), y dónde se almacenan en una instalación en modo CRD?
* **Q5.2** — En el ipcache, `10.0.2.118/32` tiene `tunnelendpoint=172.18.0.4` mientras que `10.0.1.44/32` tiene `0.0.0.0`. Explicá ambos valores desde la perspectiva del agente en `cca-net-worker`.
* **Q5.3** — Distinguí `reserved:host` (1) de `reserved:remote-node` (6). ¿Por qué Cilium separó estas dos, y qué se rompe si escribís una policy asumiendo que son lo mismo?
* **Q5.4** — `0.0.0.0/0 → identity=2 (reserved:world)`. Dada la semántica de longest-prefix-match, ¿qué le pasa a un paquete destinado a una IP que tiene una entrada de ipcache más específica, por ejemplo una entrada de policy basada en CIDR?
* **Q5.5** — Agregar la etiqueta `tier=frontend` cambió la identidad de `14127` a `51338`. ¿Cuál es la consecuencia de seguridad de esto durante la ventana de propagación, y qué funcionalidad de Cilium existe para evitar un hueco de policy en endpoints nuevos?

---

## Ejercicio 6 — Reemplazo de kube-proxy: servicios en eBPF

**Objetivo:** leer los mapas eBPF de servicios y backends, y demostrar el balanceo de carga a nivel de socket (traducción en tiempo de conexión) como algo distinto del NAT a nivel de paquete.

### Pasos

1. Exponé el deployment y leé las tablas de servicio.

```bash
kubectl expose deployment web --port=80 --target-port=80 --name=web-svc
kubectl get svc web-svc
```

```
NAME      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.142.201   <none>        80/TCP    8s
```

```bash
cdbg service list
```

```
ID   Frontend               Service Type   Backend
1    10.96.0.1:443/TCP      ClusterIP      1 => 172.18.0.2:6443 (active)
2    10.96.0.10:53/UDP      ClusterIP      1 => 10.0.1.19:53 (active)
                                           2 => 10.0.2.31:53 (active)
3    10.96.0.10:53/TCP      ClusterIP      1 => 10.0.1.19:53 (active)
                                           2 => 10.0.2.31:53 (active)
4    10.96.0.10:9153/TCP    ClusterIP      1 => 10.0.1.19:9153 (active)
                                           2 => 10.0.2.31:9153 (active)
9    10.96.142.201:80/TCP   ClusterIP      1 => 10.0.1.201:80 (active)
                                           2 => 10.0.1.44:80 (active)
                                           3 => 10.0.2.118:80 (active)
                                           4 => 10.0.2.203:80 (active)
```

2. Leé el mapa eBPF crudo que está detrás.

```bash
cdbg bpf lb list | grep -A5 '10.96.142.201'
```

```
10.96.142.201:80/TCP (0)   0.0.0.0:0 (9) (0) [ClusterIP, non-routable]
10.96.142.201:80/TCP (1)   10.0.1.201:80 (9) (1)
10.96.142.201:80/TCP (2)   10.0.1.44:80 (9) (2)
10.96.142.201:80/TCP (3)   10.0.2.118:80 (9) (3)
10.96.142.201:80/TCP (4)   10.0.2.203:80 (9) (4)
```

3. Confirmá que **no** hay reglas de iptables haciendo traducción de servicio.

```bash
docker exec cca-net-worker iptables-save -t nat | grep -c KUBE-SERVICES
```

```
0
```

```bash
docker exec cca-net-worker iptables-save -t nat | grep -c CILIUM
```

```
6
```

4. Demostrá el socket LB. Ejecutá un cliente y capturá dentro del namespace propio del Pod.

```bash
kubectl run client --image=nicolaka/netshoot:v0.13 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/client
```

Terminal A — capturá dentro del Pod cliente:

```bash
kubectl exec client -- timeout 15 tcpdump -ni eth0 'tcp port 80' -c 2
```

Terminal B — generá la petición:

```bash
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web-svc
```

Salida de la Terminal A:

```
10:58:31.402 IP 10.0.1.77.38412 > 10.0.1.44.80: Flags [S], seq 405512093, win 64860, length 0
10:58:31.403 IP 10.0.1.44.80 > 10.0.1.77.38412: Flags [S.], seq 2210345, ack 405512094, length 0
```

5. Confirmá desde el espacio de usuario dentro del Pod que el kernel ya reescribió el peer.

```bash
kubectl exec client -- sh -c 'curl -s -o /dev/null http://web-svc & sleep 1; ss -tnp | grep :80'
```

```
ESTAB  0  0   10.0.1.77:38416   10.0.1.44:80   users:(("curl",pid=41,fd=5))
```

6. Verificá los programas adjuntos al cgroup que lo implementan.

```bash
docker exec cca-net-worker bpftool cgroup show /run/cilium/cgroupv2
```

```
ID    AttachType        AttachFlags  Name
231   cgroup_inet4_connect          cil_sock4_connect
233   cgroup_inet4_post_bind        cil_sock4_post_bind
235   cgroup_inet4_getpeername      cil_sock4_getpeername
239   cgroup_udp4_sendmsg           cil_sock4_sendmsg
241   cgroup_udp4_recvmsg           cil_sock4_recvmsg
```

7. Chequeo de distribución.

```bash
for i in $(seq 1 20); do
  kubectl exec client -- curl -s http://web-svc -o /dev/null -w '%{remote_ip}\n'
done | sort | uniq -c
```

```
      6 10.0.1.201
      4 10.0.1.44
      5 10.0.2.118
      5 10.0.2.203
```

### Comprobá tu comprensión — Bloque 6

* **Q6.1** — El `tcpdump` dentro del Pod cliente muestra la IP del **backend** `10.0.1.44`, nunca la ClusterIP `10.96.142.201`. ¿En qué punto del camino de syscalls ocurrió la traducción, y qué programa eBPF la hizo?
* **Q6.2** — Dado Q6.1, ¿qué ve una aplicación si llama a `getpeername(2)` sobre ese socket, y por qué Cilium adjunta `cil_sock4_getpeername`?
* **Q6.3** — La entrada `10.96.142.201:80/TCP (0)` mapea a `0.0.0.0:0` y está marcada como `[ClusterIP, non-routable]`. ¿Para qué sirve el slot 0?
* **Q6.4** — `iptables -t nat` todavía contiene 6 reglas `CILIUM` incluso con reemplazo completo de kube-proxy. ¿Para qué sirven esas reglas, y por qué no son traducción de servicio?
* **Q6.5** — Acá el socket LB tiene cobertura `Full`. ¿En qué circunstancia `cilium-dbg status` reportaría `Socket LB Coverage: Hostns-only`, y qué datapath maneja el tráfico de Pods en ese caso?
* **Q6.6** — Un colega afirma "el socket LB rompe la NetworkPolicy de Kubernetes del lado del cliente porque la ClusterIP desaparece antes de que corra la policy". ¿Es correcto? Razoná sobre dónde se evalúa la policy de egress.

---

## Ejercicio 7 — NodePort, preservación de la IP de origen, DSR y Maglev

**Objetivo:** entender los tres caminos de servicio accesibles externamente y los trade-offs de `SNAT` versus `DSR` versus `Hybrid`, y de selección de backend `Random` versus `Maglev`.

### Pasos

1. Convertí el servicio a NodePort e inspeccioná los frontends generados.

```bash
kubectl patch svc web-svc -p '{"spec":{"type":"NodePort"}}'
kubectl get svc web-svc
```

```
NAME      TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-svc   NodePort   10.96.142.201   <none>        80:31544/TCP   22m
```

```bash
cdbg service list | grep -A8 31544
```

```
9    10.96.142.201:80/TCP    ClusterIP   1 => 10.0.1.201:80 (active)
                                         2 => 10.0.1.44:80 (active)
                                         3 => 10.0.2.118:80 (active)
                                         4 => 10.0.2.203:80 (active)
10   0.0.0.0:31544/TCP       NodePort    1 => 10.0.1.201:80 (active)
                                         ...
11   172.18.0.3:31544/TCP    NodePort    1 => 10.0.1.201:80 (active)
                                         ...
```

2. Llamá al NodePort desde **fuera** del clúster y observá la IP de origen que ve el backend.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix
```

```
[pod/web-6f8d4c9b7-pmt8z/nginx] 172.18.0.3 - - [01/Sep/2026:11:12:07 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.5.0"
```

3. Observá el estado de SNAT que hizo que la respuesta volviera correctamente.

```bash
cdbg bpf nat list | grep 31544 | head -4
```

```
TCP IN 172.18.0.1:54120 -> 172.18.0.3:31544 XLATE_DST 172.18.0.3:54120  Created=12sec ago NeedsCT=1
TCP OUT 172.18.0.3:54120 -> 10.0.2.203:80 XLATE_SRC 172.18.0.1:54120  Created=12sec ago NeedsCT=1
```

4. Poné `externalTrafficPolicy: Local` y volvé a probar.

```bash
kubectl patch svc web-svc -p '{"spec":{"externalTrafficPolicy":"Local"}}'
cdbg service list | grep -A4 '172.18.0.3:31544'
```

```
11   172.18.0.3:31544/TCP   NodePort   1 => 10.0.1.201:80 (active)
                                       2 => 10.0.1.44:80 (active)
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix | grep -v '^$'
```

```
[pod/web-6f8d4c9b7-9lbxc/nginx] 172.18.0.1 - - [01/Sep/2026:11:15:44 +0000] "GET / HTTP/1.1" 200 615
```

5. Cambiá el balanceador a **DSR con dispatch Geneve** y selección de backend **Maglev**.

```bash
cilium upgrade --reuse-values \
  --set loadBalancer.mode=dsr \
  --set loadBalancer.dsrDispatch=geneve \
  --set loadBalancer.algorithm=maglev \
  --set maglev.tableSize=16381 \
  --set maglev.hashSeed=$(head -c12 /dev/urandom | base64 -w0)

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Confirmá el nuevo modo.

```bash
cdbg status --verbose | grep -E 'Mode:|Backend Selection'
```

```
  Mode:                  DSR
  Backend Selection:     Maglev (Table Size: 16381)
```

7. Inspeccioná la tabla de lookup de Maglev para el servicio.

```bash
cdbg bpf lb maglev list
```

```
SVC ID   LOOKUP TABLE
9        [2 4 1 3 2 1 4 3 1 2 3 4 4 1 2 3 ...]
10       [3 1 4 2 3 4 1 2 2 3 1 4 ...]
```

8. Restablecé `externalTrafficPolicy` a `Cluster` y verificá que con DSR la IP del cliente sobrevive incluso en un salto entre nodos.

```bash
kubectl patch svc web-svc -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
curl -s -o /dev/null http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix
```

```
[pod/web-6f8d4c9b7-6rjhk/nginx] 172.18.0.1 - - [01/Sep/2026:11:22:03 +0000] "GET / HTTP/1.1" 200 615
```

### Comprobá tu comprensión — Bloque 7

* **Q7.1** — En el paso 1 se crearon tres frontends para un solo servicio: `10.96.142.201:80`, `0.0.0.0:31544` y `172.18.0.3:31544`. ¿Para qué sirve cada uno, y por qué un frontend comodín `0.0.0.0` no alcanza por sí solo?
* **Q7.2** — Con modo SNAT y `externalTrafficPolicy: Cluster`, nginx registró `172.18.0.3` (el nodo) en lugar del cliente real. Explicá el mecanismo y nombrá el trade-off exacto que hace `externalTrafficPolicy: Local` para arreglarlo.
* **Q7.3** — En modo DSR con `externalTrafficPolicy: Cluster`, la IP del cliente `172.18.0.1` se preservó **y** la petición fue servida por un Pod en un nodo distinto. Describí el camino de retorno del paquete de respuesta — ¿desde qué nodo sale, y qué dirección de origen lleva?
* **Q7.4** — DSR necesita transmitir el VIP/puerto original del servicio al nodo del backend. Compará las tres opciones de `dsrDispatch` (`opt`, `geneve`, `ipip`) y nombrá un entorno concreto donde `opt` falla.
* **Q7.5** — `maglev.tableSize=16381`. ¿Por qué tiene que ser un número primo, y cuál es la consecuencia operativa de que dos nodos del mismo clúster tengan valores distintos de `maglev.hashSeed`?
* **Q7.6** — Contrastá la selección de backend `Random` y `Maglev` para una conexión *nueva* cuando se elimina un backend. ¿Cuál causa que se re-hasheen menos flujos existentes en otros nodos, y por qué esto importa específicamente con DSR?

---

## Ejercicio 8 — Masquerading y egress hacia el mundo exterior

**Objetivo:** distinguir el masquerading eBPF del masquerading iptables, y controlar qué destinos quedan exentos.

### Pasos

1. Confirmá el modo de masquerade y la interfaz a la que está ligado.

```bash
cdbg status | grep Masquerading
```

```
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

2. Verificá que no hay ninguna regla de masquerade en iptables para el tráfico de Pods.

```bash
docker exec cca-net-worker iptables-save -t nat | grep -i masq
```

```
(no output)
```

3. Generá egress hacia una dirección fuera del clúster y capturá en el uplink del nodo.

Terminal A:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'icmp' -c 2
```

Terminal B:

```bash
kubectl exec client -- ping -c 2 172.18.0.1
```

Salida de la Terminal A:

```
11:33:12.881 IP 172.18.0.3 > 172.18.0.1: ICMP echo request, id 12, seq 1, length 64
11:33:12.881 IP 172.18.0.1 > 172.18.0.3: ICMP echo reply, id 12, seq 1, length 64
```

4. Inspeccioná la entrada del mapa NAT creada para eso.

```bash
cdbg bpf nat list | grep ICMP | head -2
```

```
ICMP OUT 10.0.1.77:12 -> 172.18.0.1:0 XLATE_SRC 172.18.0.3:32410 Created=3sec ago NeedsCT=1
ICMP IN 172.18.0.1:32410 -> 172.18.0.3:0 XLATE_DST 10.0.1.77:12 Created=3sec ago NeedsCT=1
```

5. Agregá una exención para que el tráfico hacia un CIDR externo específico conserve la IP de origen del Pod.

```bash
cilium upgrade --reuse-values \
  --set ipMasqAgent.enabled=true \
  --set ipMasqAgent.config.nonMasqueradeCIDRs='{172.18.0.0/16}' \
  --set ipMasqAgent.config.masqLinkLocal=false

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Verificá el mapa de exenciones y volvé a probar.

```bash
cdbg bpf ipmasq list
```

```
IP PREFIX/ADDRESS
169.254.0.0/16
172.18.0.0/16
```

Terminal A:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'icmp' -c 1
```

Terminal B:

```bash
kubectl exec client -- ping -c 1 172.18.0.1
```

Salida de la Terminal A:

```
11:41:55.220 IP 10.0.1.77 > 172.18.0.1: ICMP echo request, id 14, seq 1, length 64
```

### Comprobá tu comprensión — Bloque 8

* **Q8.1** — Con `bpf.masquerade=true`, ¿en qué hook y sobre qué interfaz se realiza el masquerade? ¿Cuál es el equivalente cuando `bpf.masquerade=false`?
* **Q8.2** — La línea `Masquerading` muestra el CIDR `10.0.0.0/8`. Enunciá con precisión el predicado que usa Cilium para decidir "masquerade o no" en modo native routing.
* **Q8.3** — En el paso 4, el campo `id` de ICMP `12` fue reescrito a `32410` en `XLATE_SRC`. ¿Por qué un echo ICMP necesita un "puerto" de NAT?
* **Q8.4** — Después del cambio de `ipMasqAgent`, el ping salió del nodo con origen `10.0.1.77`. ¿Qué debe ser cierto sobre la red `172.18.0.0/16` para que vuelva la respuesta? Nombrá el modo de falla si no lo es.
* **Q8.5** — Necesitás que *todo* el egress de un namespace salga del clúster con una única IP fija, incluible en una allowlist. ¿Cuál es la funcionalidad correcta de Cilium, qué CRD la implementa, y qué requiere de `bpf.masquerade`?

---

## Ejercicio 9 — Diagnosticar el datapath de punta a punta

**Objetivo:** construir la secuencia refleja para "el tráfico no funciona": verificar, observar, y después rastrear los drops.

### Pasos

1. Ejecutá la suite de conectividad incorporada. Es la señal única más rápida.

```bash
cilium connectivity test --test-concurrency 2
```

```
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [kind-cca-net] Creating namespace cilium-test-1 for connectivity check...
⌛ [kind-cca-net] Waiting for deployments [client client2 echo-same-node] to become ready...
🏃 Running 1/78 tests: no-unexpected-packet-drops
🏃 Running 12/78 tests: pod-to-pod
...
✅ [kind-cca-net] All 78 tests (312 actions) successful, 15 tests skipped, 0 scenarios skipped.
```

2. Introducí una falla: apuntá el Service a un selector que no coincide con nada.

```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web-typo"}}}'
kubectl exec client -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://web-svc
```

```
000
```

3. Diagnosticá primero desde la tabla de servicios — la verificación más barata.

```bash
cdbg service list | grep 10.96.142.201
```

```
9    10.96.142.201:80/TCP   ClusterIP
```

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-svc
```

```
NAME            ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-svc-x9k2m   IPv4          <unset> <unset>     41m
```

4. Reparalo y pasá a una falla genuinamente a nivel de datapath: un drop por policy.

```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'

cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-allow-nothing
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: web
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: nonexistent
EOF
```

5. Confirmá que el enforcement se activó en los endpoints.

```bash
cdbg endpoint list | grep web
```

```
794    Enabled    Disabled    51338    k8s:app=web    10.0.1.44    ready
2104   Enabled    Disabled    51338    k8s:app=web    10.0.1.201   ready
```

6. Rastreá el drop en vivo con el monitor.

Terminal A:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg monitor --type drop
```

Terminal B:

```bash
kubectl exec client -- curl -s -m 3 -o /dev/null http://web-svc
```

Salida de la Terminal A:

```
Listening for events on 8 CPUs with 64x4096 of shared memory
xx drop (Policy denied) flow 0x8f2a1c33 to endpoint 794, ifindex 14,
   file bpf_lxc.c:2011, identity 39117->51338: 10.0.1.77:51204 -> 10.0.1.44:80 tcp SYN
```

7. La misma respuesta a través de Hubble, que es lo que vas a usar realmente en producción.

```bash
cilium hubble enable
cilium status --wait
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 >/dev/null 2>&1 &
sleep 3
hubble observe --to-label app=web --verdict DROPPED --last 5
```

```
Sep  1 11:58:20.114: default/client:51210 (ID:39117) -> default/web-6f8d4c9b7-9lbxc:80 (ID:51338) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 11:58:21.117: default/client:51210 (ID:39117) -> default/web-6f8d4c9b7-9lbxc:80 (ID:51338) Policy denied DROPPED (TCP Flags: SYN)
```

8. Confirmá el veredicto directamente desde el motor de policy, sin generar tráfico.

```bash
cdbg policy trace --src-identity 39117 --dst-identity 51338 --dport 80/TCP
```

```
Resolving ingress policy for [k8s:app=web k8s:io.kubernetes.pod.namespace=default]
* Rule {"matchLabels":{"any:app":"web",...}}: selected
    Allows from labels {"matchLabels":{"any:app":"nonexistent",...}}
      No label match for [k8s:run=client ...]
1/1 rules selected
Found no allow rule
Ingress verdict: denied

Final verdict: DENIED
```

9. Limpiá la falla y confirmá la recuperación.

```bash
kubectl delete cnp web-allow-nothing
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web-svc
```

```
200
```

### Comprobá tu comprensión — Bloque 9

* **Q9.1** — En el paso 3, el servicio tenía un frontend pero cero backends, y el síntoma fue el código de salida 28 de `curl` / HTTP `000` (timeout), no `connection refused`. Explicá por qué una lista de backends vacía produce timeout en vez de un reset, dado el socket LB.
* **Q9.2** — La línea del monitor dice `file bpf_lxc.c:2011` y `to endpoint 794`. ¿Qué te dice el nombre del archivo sobre *dónde* en el datapath ocurrió el drop, y esto es enforcement de ingress o de egress?
* **Q9.3** — `identity 39117->51338`. ¿Cuál es el origen y cuál el destino, y cómo convertirías cada número en un conjunto de etiquetas legible por humanos?
* **Q9.4** — `cilium connectivity test` imprimió "Monitor aggregation detected, will skip some flow validation steps". ¿Qué es la agregación del monitor, qué valor de Helm la controla, y cuál es el costo de ponerla en `none`?
* **Q9.5** — Tanto `cilium-dbg monitor` como `hubble observe` mostraron el mismo drop. Enunciá dos razones concretas de producción para preferir Hubble.
* **Q9.6** — Ordená estas cuatro verificaciones de la más barata a la más cara para "el Pod A no puede alcanzar el Service B", y justificá el orden: `cilium-dbg monitor --type drop`, `kubectl get endpointslices`, `cilium connectivity test`, `cilium-dbg service list`.

---

## Ejercicio 10 — Limpieza

```bash
kubectl delete deployment web
kubectl delete svc web-svc
kubectl delete pod client
cilium uninstall
kind delete cluster --name cca-net
```

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar todos los bloques</summary>

### Bloque 1 — El contrato CNI

**A1.1** — Son `hostNetwork: true` (Pods estáticos manifestados desde `/etc/kubernetes/manifests`). Un Pod con red del host comparte el namespace de red raíz del nodo, así que el kubelet nunca invoca la operación CNI `ADD` para él: no hay netns de sandbox que cablear ni IP que asignar. La IP `172.18.0.2` es la dirección propia del nodo en el bridge de Docker — la IP del nodo, no una IP de Pod. Por eso los componentes del control-plane pueden hacer bootstrap antes de que exista cualquier plugin de red, y también es la razón por la que un CNI roto nunca se lleva puesto al API server.

**A1.2** — El **kubelet**. Llama al endpoint de estado del container runtime (CRI `Status()`), y containerd reporta `NetworkReady=false` porque no encontró ninguna configuración CNI válida en `--cni-conf-dir` (por defecto `/etc/cni/net.d`). El kubelet propaga eso a la condición `Ready` del objeto Node. El scheduler entonces se niega a colocar Pods que no sean de red del host; por eso CoreDNS queda `Pending`.

**A1.3** — **No.** `.spec.podCIDR` lo escribe el controlador node-ipam de `kube-controller-manager` y es autoritativo solo para los modos de IPAM que lo consumen — es decir, `ipam.mode=kubernetes`. Con `ipam.mode=cluster-pool` (el default de Cilium), el **cilium-operator** talla `/24`s por nodo a partir de `clusterPoolIPv4PodCIDRList` y los escribe en `CiliumNode.spec.ipam.podCIDRs`. Las dos asignaciones son independientes, que es exactamente por qué el nodo del laboratorio termina con `10.0.1.0/24` mientras `.spec.podCIDR` sigue diciendo `10.1.0.0/24`. Confundirlas es un error de diagnóstico clásico.

**A1.4** — (1) Un archivo de configuración CNI en `/etc/cni/net.d/` (Cilium instala `05-cilium.conflist`), y (2) el binario del plugin CNI en `/opt/cni/bin/` (`cilium-cni`). El agente de Cilium copia ambos desde su propia imagen al arrancar, mediante el init container `install-cni-binaries` más el escritor de configuración CNI del agente.

---

### Bloque 2 — Instalación y estado

**A2.1** —
* *Network* = cómo llega un paquete de nodo a nodo: `Tunnel [vxlan]`, `Tunnel [geneve]`, o `Native`.
* *Host* = cómo llega un paquete entre el stack del host y el endpoint en el nodo local: `BPF` (host routing eBPF, los paquetes van de endpoint a endpoint enteramente en eBPF, saltándose el camino de iptables/netfilter del host) o `Legacy` (los paquetes atraviesan el stack superior del host).

Con `routingMode=native` y `bpf.masquerade=false` verías `Routing: Network: Native   Host: BPF` y `Masquerading: IPTables`. Notá que `Host: BPF` depende del soporte del kernel y de los prerrequisitos del host routing eBPF, no de la configuración de masquerade — son perillas ortogonales que la gente confunde con frecuencia.

**A2.2** — Lo asignó el **cilium-operator**, a partir de `ipam.operator.clusterPoolIPv4PodCIDRList=10.0.0.0/8` cortado en `/24`s. Se persiste en el CRD `CiliumNode` en `.spec.ipam.podCIDRs`. El agente luego lee su propio objeto `CiliumNode` e inicializa el asignador local a partir de él. Por eso el operator es una dependencia dura para la programación de Pods en modo cluster-pool: si el operator está caído y se une un nodo nuevo, ese nodo no obtiene CIDR y ningún Pod llega a levantarse en él.

**A2.3** —
* **router** = la IP `cilium_host`. Es el gateway por defecto dentro de cada netns de Pod en ese nodo y la dirección de origen que Cilium usa para el extremo local del datapath. También es la dirección a la que el proxy L7 (Envoy) hace bind para el tráfico redirigido.
* **health** = la IP del endpoint `cilium-health`, un endpoint de sondeo por nodo. Los agentes ejecutan sondas periódicas de conectividad nodo-a-nodo y endpoint-a-endpoint contra los endpoints de health de los demás; el resultado es la línea `Cluster health: 3/3 reachable` y la salida de health de `cilium-dbg status --verbose`. Es tu primera señal de que un par de nodos específico perdió conectividad de datapath.

**A2.4** — Circularidad: Cilium *es* el service proxy, así que es lo que normalmente traduciría la ClusterIP de `kubernetes.default.svc` (`10.96.0.1:443`) al endpoint real del API server. Pero el agente tiene que alcanzar el API server **antes** de haber programado ningún mapa de servicios, para poder leer su propia configuración y el objeto `CiliumNode`. `k8sServiceHost`/`k8sServicePort` le dan al agente una dirección directa, sin traducir, contra la cual hacer bootstrap. Una vez en marcha, programa `10.96.0.1:443` en el mapa LB de eBPF para todos los demás. (En clústeres gestionados podés usar en su lugar configuraciones al estilo `kubeProxyReplacementHealthzBindAddr` o mantener un kube-proxy mínimo; pero con kube-proxy completamente ausente, estos dos valores son obligatorios.)

**A2.5** — La alternativa es **`tc` (clsact/`tc` BPF legacy)**. **TCX** es el mecanismo de attach más nuevo basado en BPF links para programas estilo tc, introducido en **Linux 6.6**. TCX da semántica de propiedad (los programas se adjuntan vía un `bpf_link`, así que no pueden ser desadjuntados silenciosamente por otra herramienta, como un `tc filter del` perdido), más un ordenamiento determinista respecto de otros programas TCX. En la práctica: en ≥ 6.6 Cilium convive de forma mucho más segura con otros agentes basados en tc.

---

### Bloque 3 — IPAM y plomería de endpoints

**A3.1** — Cilium instala una entrada de vecino estática (`PERMANENT`) para que el Pod nunca tenga que hacer ARP por su gateway. No hay nada del otro lado que respondería una petición ARP en el sentido convencional — el peer veth `lxc*` no es un router haciendo L3 normal, es un punto de hook donde eBPF toma el control de inmediato. Eliminar ARP también elimina toda una clase de carreras de arranque y un broadcast por Pod. La MAC a la que apunta, `3e:1a:9c:44:8b:02`, es la **MAC del veth del lado host (`lxc*`)**, que coincide con `host-mac` en el estado de networking del endpoint.

**A3.2** — El Pod solo tiene `default via <router>` más una ruta de alcance link hacia el router. Deliberadamente **no** hay ruta de subred, así que *cada* paquete — incluso hacia un Pod en el mismo nodo dentro del mismo `/24` — se envía a la MAC del gateway y golpea `cil_from_container` en el ingress TCX del veth. La decisión de forwarding ocurre por lo tanto enteramente en eBPF, donde Cilium puede consultar el ipcache, aplicar policy por identidad, y rutear el tráfico local-a-local directamente hacia el endpoint peer sin pasar por la tabla de routing del host ni por netfilter. La uniformidad es el punto: un solo camino de código, un solo punto de enforcement de policy, sin atajos de misma subred que evadirían el enforcement.

**A3.3** — El overhead de VXLAN es de 50 bytes: 14 (Ethernet externo) + 20 (IPv4 externo) + 8 (UDP) + 8 (cabecera VXLAN) = 50, así que 1500 − 50 = **1450**. Geneve sin opciones tiene el mismo overhead base (14 + 20 + 8 + 8 = 50), pero Cilium reserva headroom adicional cuando se usan opciones Geneve (por ejemplo el dispatch Geneve de DSR), así que no asumas un número fijo — leelo de `cilium-dbg status --verbose | grep -i mtu`. **WireGuard** agrega **60 bytes** encima de lo que cueste el modo subyacente (`routingMode=native` + WireGuard → 1440; tunnel + WireGuard → todavía menos). La regla operativa: nunca hardcodees la MTU; dejá que Cilium la autodetecte, o seteá `MTU` explícitamente y verificá con `cilium-dbg status`.

**A3.4** — Una identidad de seguridad tiene **alcance de clúster** (global), derivada de forma determinista del conjunto de etiquetas *relevantes para seguridad* del endpoint — namespace de Kubernetes, etiquetas del Pod, service account, nombre del clúster — después de filtrar las etiquetas excluidas por la configuración `labels`/`--labels`. La asigna el **cilium-agent** a través del asignador de identidades, respaldado en modo CRD por objetos `CiliumIdentity` en el API server (o por el kvstore en modo kvstore). Como es derivada de etiquetas y global, cuatro Pods en dos nodos con etiquetas idénticas colapsan a una sola identidad — que es precisamente lo que hace que la policy escale independientemente de la cantidad de Pods.

**A3.5** — El endpoint `1288` / identidad `1` / `reserved:host` es **el nodo local en sí** — el namespace de red del host, representado como un endpoint para que Cilium pueda aplicar policy al tráfico que entra y sale del stack del host (esta es la base de la funcionalidad Host Firewall). No tiene IPv4 de Pod en el listado porque cubre *todas* las direcciones propias del nodo, no una. Consecuencia para los Pods `hostNetwork: true`: **no** tienen un endpoint de Cilium dedicado ni identidad por Pod — desde la perspectiva del datapath, son el host. Por lo tanto son invisibles para las policies que seleccionan Pods y solo son alcanzados por reglas `reserved:host` / de host firewall. Esto sorprende a la gente constantemente: una `NetworkPolicy` que selecciona las etiquetas de un Pod con red del host no hace nada.

---

### Bloque 4 — Modos de routing

**A4.1** — 8472 es el **puerto VXLAN pre-estándar de Linux**, elegido por la implementación de Linux antes de que la IANA asignara el 4789, y mantenido por Cilium como default por compatibilidad con despliegues y reglas de firewall existentes. Es configurable vía `tunnelPort`. **Geneve** usa **6081** (el puerto asignado por la IANA). Consecuencia práctica: tus security groups / firewall deben permitir UDP 8472 (o 6081) entre nodos, más los puertos de health check, o vas a tener el síntoma clásico de "el tráfico dentro del mismo nodo funciona, el tráfico entre nodos se cuelga".

**A4.2** — "Modo external" (`ip link ... vxlan external`) significa que el dispositivo no lleva **ningún VNI ni endpoint remoto fijo** en su propia configuración. En cambio, la clave del túnel — IP remota y VNI — es provista por paquete en tiempo de ejecución por el programa eBPF, vía `bpf_skb_set_tunnel_key()`, usando el valor buscado en el mapa de túneles (`cilium_tunnel_map`) o en el campo `tunnelendpoint` del ipcache. Por eso aparecen `id 0` y ningún `remote` en `ip -d link`, y por eso un solo dispositivo sirve a cada nodo remoto. El componente que provee la clave es el **datapath eBPF del cilium-agent** (`bpf_overlay.c` / `bpf_lxc.c`).

**A4.3** — Regla por defecto: hacer masquerade del tráfico que **sale del clúster**, es decir, tráfico cuyo destino *no* es un destino conocido del clúster/Pod, y preservar la IP del Pod para todo lo interno. Concretamente en esta configuración, `10.0.2.118` está dentro de `ipv4NativeRoutingCIDR` / el Pod CIDR del clúster *y* tiene una entrada de ipcache que la identifica como un endpoint del clúster, así que se trata como intra-clúster y queda exenta. Preservar la IP de origen real del Pod no es un lujo — la policy basada en identidad, la atribución de Hubble y la lógica de IP de origen a nivel de aplicación dependen de ella.

**A4.4** — `autoDirectNodeRoutes` instala una ruta simple `remotePodCIDR via remoteNodeIP dev <uplink>` en cada nodo. Eso solo funciona si **todos los nodos están en el mismo segmento L2** (directamente alcanzables sin salto de router), porque la IP del nodo debe ser resoluble como next hop on-link. En una VPC cloud con nodos en subredes distintas tenés que hacer que el underlay mismo conozca los Pod CIDRs: usar el IPAM nativo del cloud (`ipam.mode=eni` / `azure` / `gke`, donde las IPs de Pod son IPs reales de la VPC), o anunciar los Pod CIDRs con el **BGP Control Plane** (`CiliumBGPClusterConfig`/`CiliumBGPPeerConfig`) hacia el fabric, o agregar rutas a la tabla de rutas de la VPC. Si no podés hacer ninguna de esas, quedate en modo tunnel — ese es exactamente el problema que la encapsulación existe para resolver.

**A4.5** — La MTU se escribe en el `eth0` del Pod en el momento del `ADD` del CNI, es decir, cuando se crea el sandbox. Cambiar la configuración del agente no reescribe retroactivamente un netns ya configurado, así que los Pods en ejecución mantienen el valor viejo hasta ser recreados. Procedimiento seguro en producción: cambiar la configuración, rotar el DaemonSet del agente, y después **drenar y rotar las cargas de trabajo nodo por nodo** (o hacer el cambio durante una rotación de nodos planificada). Saltearse la rotación de cargas deja Pods con 1450 en una red de 1500 — lo cual es inofensivo — pero la dirección inversa (tunnel habilitado mientras los Pods todavía tienen 1500) causa black-holing silencioso de paquetes grandes y fallas de PMTUD, el síntoma más desagradable de esta área.

**A4.6** — El tráfico destinado **fuera** de `ipv4NativeRoutingCIDR` se considera que está saliendo del clúster y por lo tanto se le hace **masquerade** a la IP del nodo por el programa eBPF de masquerade en el egress del dispositivo uplink. El tráfico **dentro** del CIDR se asume nativamente ruteable por el underlay y se deja con su IP de origen de Pod. Por eso el valor debe cubrir exactamente todo el espacio de direcciones de Pods (y, donde corresponda, de nodos): demasiado estrecho y al tráfico intra-clúster se le hace SNAT, destruyendo la atribución de identidad; demasiado amplio y el tráfico genuinamente externo escapa sin masquerade y es descartado por el fabric como no ruteable.

---

### Bloque 5 — Identidad e ipcache

**A5.1** — Las identidades globales ocupan **256 – 65535** (`Global Identity Range: min 256, max 65535` en la salida de status). 1–255 es el rango reservado; por encima de 65535 están los rangos especiales usados para identidades de alcance local (identidades CIDR, identidades de remote-node en algunas configuraciones). En **modo CRD** (el default, `identityAllocationMode=crd`) se almacenan como objetos `CiliumIdentity` de alcance de clúster en el API server de Kubernetes; en modo `kvstore` viven en etcd. Límite práctico: el espacio de identidades globales es finito, y el churn de etiquetas (por ejemplo, inyectar una etiqueta única por Pod) lo va a agotar — este es un patrón real de incidente en producción.

**A5.2** — Desde el punto de vista de `cca-net-worker`:
* `10.0.2.118/32 → tunnelendpoint=172.18.0.4` — un Pod **remoto**. Para alcanzarlo, encapsular y enviar al nodo `172.18.0.4`. El ipcache es lo que provee el destino de túnel a `bpf_skb_set_tunnel_key()`.
* `10.0.1.44/32 → tunnelendpoint=0.0.0.0` — un endpoint **local**. No hace falta túnel; el datapath lo resuelve a través del mapa de endpoints local y entrega directo al veth peer.

En modo native routing todos los campos `tunnelendpoint` pasan a `0.0.0.0` porque el underlay rutea el paquete.

**A5.3** — `reserved:host` (1) es **el nodo local** — el netns del host del nodo donde corre el agente. `reserved:remote-node` (6) es **cualquier otro nodo** del clúster (o de un ClusterMesh). Se separaron porque colapsarlos hace que `reserved:host` signifique "cualquier nodo en cualquier lado", lo cual es demasiado amplio para reglas de host firewall: una regla pensada para permitir que el kubelet de *este* nodo alcance un Pod permitiría silenciosamente a cada nodo del clúster. Si escribís una policy asumiendo que son lo mismo, o bien sobre-permitís (tratando a nodos remotos como host local confiable) o bien rompés los health checks y las probes del kubelet (denegando tráfico `remote-node` que lleva sondas de salud originadas en nodos). Notá la historia de `policyCIDRMatchMode` y `enable-remote-node-identity` acá — en versiones modernas remote-node siempre es una identidad distinta.

**A5.4** — El ipcache es un **trie LPM (longest-prefix-match)**. El destino de un paquete resuelve a la entrada coincidente *más específica*. `0.0.0.0/0 → 2 (reserved:world)` es el fallback catch-all, así que cualquier cosa sin una coincidencia mejor se clasifica como `world`. Cuando escribís una regla de policy `toCIDR`/`toCIDRSet`, Cilium asigna una **identidad CIDR de alcance local** e inserta el prefijo correspondiente en el ipcache; un paquete hacia una dirección dentro de ese prefijo entonces resuelve a la identidad CIDR en vez de a `world`, y se aplica la policy para esa identidad. Así es exactamente como funciona la policy de egress basada en CIDR y por qué una regla `toCIDR: 0.0.0.0/0` y una regla `toEntities: world` se comportan de forma sutilmente distinta.

**A5.5** — Durante la ventana de propagación, la identidad del endpoint se está reasignando y la nueva identidad debe empujarse al ipcache y al mapa de policy de cada nodo. Si una policy permitía la identidad *vieja* y no la nueva (o viceversa), hay un intervalo breve donde los flujos pueden ser descartados o, peor, permitidos bajo una identidad obsoleta. La funcionalidad que cierra el hueco para endpoints **recién creados** es **`endpointStatus`/policy-enforcement-at-init**: un endpoint nuevo arranca en `reserved:init` (identidad 5) con la policy ya aplicada, de modo que nunca queda "abierto" mientras se resuelve su identidad. Para cambios de etiquetas en endpoints existentes, el endpoint entra en estado de regeneración y Cilium regenera su programa BPF de policy antes de considerar completo el cambio; que `cilium-dbg endpoint list` muestre `regenerating` en vez de `ready` es la señal observable. Operativamente: no mutes etiquetas relevantes para seguridad en Pods de producción en ejecución.

---

### Bloque 6 — Reemplazo de kube-proxy

**A6.1** — La traducción ocurrió en el momento del **`connect(2)`**, antes de que se construyera un solo paquete, en el programa **`cil_sock4_connect`** adjunto al hook de cgroup v2 `cgroup/connect4`. Reescribió la dirección de destino del socket, de la ClusterIP a una dirección de backend elegida, in situ. Como el socket mismo ahora apunta a `10.0.1.44:80`, cada paquete que el kernel emite a continuación ya lleva la IP del backend — no queda nada para que `tcpdump` vea. El beneficio es que el DNAT por paquete y el costo asociado de conntrack se eliminan por completo para el tráfico Pod-a-Service dentro de la jerarquía de cgroups del nodo.

**A6.2** — `getpeername(2)` devolvería naturalmente la dirección del **backend** `10.0.1.44:80`, no la ClusterIP que la aplicación pidió. Algunas aplicaciones comparan la dirección del peer contra la que marcaron (lógica de SNI/hostname de TLS, algunos clientes gRPC y Java, y notablemente cualquier cosa que lleve su propia contabilidad de direcciones) y se rompen. Cilium adjunta **`cil_sock4_getpeername`** al hook `cgroup/getpeername4` para reescribir la respuesta de vuelta al VIP original del servicio, restaurando la ilusión de que el socket está conectado a la ClusterIP.

**A6.3** — El slot 0 es la **entrada "maestra" del servicio**: contiene metadatos a nivel de servicio en vez de un backend — cantidad de backends, flags del servicio (`ClusterIP`, `NodePort`, `LoadBalancer`, `non-routable`, configuración de afinidad, `externalTrafficPolicy`), y el índice de NAT inverso. Los backends viven en los slots 1..N. `non-routable` acá significa que el frontend es una ClusterIP que nunca debe rutearse en el cable — existe solo como clave de lookup. Cuando leas `cilium-dbg bpf lb list`, esperá siempre una línea de slot 0 por frontend.

**A6.4** — Son las propias cadenas de mantenimiento de Cilium, no DNAT de servicio. Típicamente: reglas para excluir el tráfico gestionado por Cilium del procesamiento de otros agentes, las cadenas `CILIUM_OUTPUT`/`CILIUM_POST_nat` usadas para la contabilidad de redirección al proxy L7 y para marcado, y — cuando `bpf.masquerade=false` — la regla de masquerade propiamente dicha (ausente acá). Cilium también usa reglas de connmark/`--set-xmark` para coordinarse con el kernel para el tráfico proxeado. El punto clave para el examen: **cero reglas `KUBE-SERVICES`** es la prueba positiva de que el reemplazo de kube-proxy está haciendo el trabajo de servicios; la presencia de cadenas `CILIUM_*` es normal y no está relacionada.

**A6.5** — `Socket LB Coverage: Hostns-only` aparece cuando el socket LB se restringe deliberadamente al **namespace de red del host** — se setea vía `socketLB.hostNamespaceOnly=true`. Necesitás esto cuando algo más dentro del netns del Pod debe observar o interceptar la ClusterIP original: lo más común, un service mesh basado en sidecars (Istio/Linkerd) cuya redirección de iptables espera ver el VIP, o lógica eBPF/`SO_ORIGINAL_DST` propia. En ese caso el tráfico de Pods lo maneja en su lugar el **LB eBPF por paquete en la capa tc/TCX** sobre la interfaz `lxc*` (DNAT + conntrack en `bpf_lxc.c`), que es levemente más caro pero preserva el VIP dentro del netns del Pod.

**A6.6** — El colega está **equivocado**. La policy de egress de Cilium se evalúa por **identidad**, y la identidad del destino se resuelve desde el ipcache usando la IP del backend *post-traducción* — que mapea a la identidad del Pod backend, exactamente la cosa que querés autorizar. Además, Cilium soporta `toServices` en `CiliumNetworkPolicy`, que resuelve a los endpoints subyacentes. Lo que el socket LB *sí* cambia es cualquier cosa que inspeccione la ClusterIP literal en el cable — por ejemplo, una regla `toCIDR` escrita contra el CIDR de servicios, que no va a coincidir porque el paquete nunca lleva esa dirección. El patrón correcto es seleccionar el backend por etiqueta (`toEndpoints`) o por `toServices`, nunca por el CIDR del VIP de servicio.

---

### Bloque 7 — Tráfico externo, DSR, Maglev

**A7.1** —
* `10.96.142.201:80` — el frontend **ClusterIP**, para clientes dentro del clúster.
* `0.0.0.0:31544` — el frontend **NodePort comodín**, que hace match del NodePort en cualquier dirección que el datapath vea, incluidas direcciones no conocidas al momento de programar (y es lo que usa el camino de socket LB para acceder al NodePort desde el namespace del host).
* `172.18.0.3:31544` — un frontend **NodePort explícito por dispositivo**, ligado a la dirección de cada dispositivo detectado en `devices`.

El comodín solo no alcanza porque Cilium debe distinguir el tráfico realmente dirigido a la IP de *este nodo* en el NodePort — necesario para la contabilidad correcta de NAT inverso, para las decisiones de `externalTrafficPolicy: Local`, y para evitar secuestrar tráfico que meramente transita el nodo. Los nodos multi-homed obtienen un frontend explícito por dirección de dispositivo.

**A7.2** — Con `externalTrafficPolicy: Cluster` y `loadBalancer.mode=snat`, el nodo receptor puede reenviar la petición a un backend en un nodo *distinto*. Para que la respuesta vuelva por el mismo nodo (de modo que pueda deshacerse el NAT y devolverse al cliente), el nodo de ingreso reescribe la dirección de **origen** a su propia IP (`172.18.0.3`). El backend por lo tanto ve al nodo, no al cliente.

`externalTrafficPolicy: Local` lo arregla **restringiendo el conjunto de backends a los Pods locales del nodo receptor** — sin salto entre nodos, así que no hace falta SNAT y la IP del cliente sobrevive. El trade-off es doble: (1) **distribución de carga despareja**, ya que el tráfico se reparte por nodo en vez de por cantidad de backends — un nodo con 1 réplica recibe la misma porción que un nodo con 5; y (2) **blackholing de tráfico en nodos sin backends locales**, por lo cual un LB externo debe usar el `healthCheckNodePort` del servicio para dejar de enviarles tráfico a esos nodos. Fijate en el paso 4 que la lista de backends del frontend se redujo de 4 a 2.

**A7.3** — En DSR, el nodo de ingreso reenvía la petición al nodo del backend **sin** reescribir la dirección de origen; la IP del cliente `172.18.0.1` se preserva de punta a punta. El datapath del nodo del backend, habiendo aprendido el VIP y puerto originales del servicio a partir del mecanismo de dispatch de DSR, arma el NAT inverso localmente y la respuesta se envía **directamente desde el nodo del backend al cliente**, salteando por completo al nodo de ingreso. La dirección de origen de la respuesta es el **VIP/NodePort original del servicio** (`172.18.0.3:31544`), no la IP del Pod backend — de lo contrario el conntrack del cliente la rechazaría como un paquete no solicitado de un peer desconocido.

Esa asimetría es todo el punto de DSR (un salto de salida en vez de dos, y sin cuello de botella en el camino de retorno en el nodo de ingreso), y también su principal restricción de despliegue: el fabric debe permitir que un nodo emita paquetes con origen en una dirección que no le pertenece.

**A7.4** —
* **`opt`** — codifica el VIP/puerto en una **opción IPv4** (una opción específica de Cilium) agregada a la cabecera original. Lo más barato (poco overhead, sin encapsulación extra) pero en efecto solo IPv4 y frágil: muchos fabrics cloud, middleboxes de hardware y appliances de seguridad **descartan paquetes IPv4 que llevan opciones desconocidas**. AWS y varios fabrics empresariales son entornos concretos donde `opt` hace blackhole silencioso del tráfico.
* **`geneve`** — encapsula en **Geneve** y lleva la dirección del servicio en una opción TLV de Geneve. Funciona para IPv4 e IPv6, sobrevive fabrics a los que no les gustan las opciones IP, cuesta ~50 bytes de MTU. Es la opción más ampliamente compatible y la razón por la que el laboratorio la usa.
* **`ipip`** — encapsulación **IP-in-IP** que lleva los metadatos en la cabecera externa. Disponible para IPv4 e IPv6; requiere que el fabric permita el protocolo 4/41, cosa que muchos security groups no hacen por defecto.

**A7.5** — El tamaño de la tabla de lookup de Maglev debe ser **primo** porque la permutación del algoritmo para cada backend se genera como `offset + i * skip mod M`, y la garantía de que la permutación de cada backend visita **cada** slot de la tabla exactamente una vez — que es lo que produce una población casi perfecta y uniformemente distribuida — se sostiene solo cuando `M` es primo y coprimo con el valor de skip. Un `M` compuesto dejaría que la permutación de un backend ciclara por un subconjunto de slots, arruinando tanto el balance como las propiedades de disrupción. 16381 es el default (un primo justo por debajo de 2^14).

Si dos nodos tienen valores **distintos de `maglev.hashSeed`**, calculan **tablas de lookup distintas** para el mismo servicio y conjunto de backends. Por lo tanto van a discrepar sobre a qué backend pertenece una 5-tupla dada. Con DSR — donde el nodo de ingreso y el camino de respuesta pueden diferir, y donde la selección consistente entre nodos es la razón entera para usar Maglev — esto produce **conexiones rotas ante cualquier cambio de camino**, y con `externalTrafficPolicy: Cluster` socava la consistencia que hace que Maglev valga su memoria extra. La semilla debe ser idéntica en todo el clúster; Helm genera una en el momento de la instalación y `--reuse-values` la preserva, por lo cual tenés que tener cuidado de no regenerarla accidentalmente en un upgrade.

**A7.6** — Con **`Random`**, cada nodo elige un backend al azar de forma independiente por cada conexión nueva. Eliminar un backend no afecta los flujos *establecidos* (el conntrack los fija), pero no hay consistencia entre nodos ni garantía sobre cómo se redistribuyen los flujos nuevos.

Con **`Maglev`**, la elección de backend es una función determinista de la 5-tupla y del conjunto de backends, idéntica en cada nodo que comparta la semilla. Eliminar un backend de N perturba solo alrededor de `1/N` de las entradas de la tabla — esto es *hashing consistente* con disrupción mínima. Menos flujos existentes aterrizan en un backend distinto del que tenían antes.

Esto importa específicamente con **DSR** porque DSR depende de que cualquier nodo que reciba un paquete de un flujo existente pueda rutearlo al mismo backend — el nodo de ingreso puede cambiar (re-hash de ECMP aguas arriba, falla de nodo, VIP anycast), y no hay conntrack compartido entre nodos para consultar. Maglev convierte "a qué backend pertenece esta 5-tupla" en una respuesta sin estado e independiente del nodo, de modo que un flujo sobrevive a un cambio de nodo de ingreso. Con `Random`, el nuevo nodo de ingreso elegiría un backend distinto y la conexión se resetearía.

---

### Bloque 8 — Masquerading

**A8.1** — Con `bpf.masquerade=true`, el masquerading lo realiza el programa eBPF adjunto en el **hook de egress tc/TCX del/los dispositivo(s) nativo(s)/uplink** listados en `devices` (acá `eth0`) — el camino `cil_to_netdev` en `bpf_host.c` — usando el mapa NAT propio de Cilium (`cilium_snat_v4_external`), completamente independiente del conntrack de netfilter. Con `bpf.masquerade=false`, el masquerading cae de vuelta a una **regla `MASQUERADE` de iptables** en la cadena `POSTROUTING` de la tabla `nat` (en una cadena `CILIUM_POST_nat`), usando el conntrack de netfilter del kernel. El camino eBPF es más rápido, no puebla el conntrack de netfilter (evitando el agotamiento de la tabla bajo alto churn de egress), y es un prerrequisito para funcionalidades como el Egress Gateway.

**A8.2** — En modo native routing: hacer masquerade de un paquete que sale del nodo por un dispositivo con masquerade habilitado **si y solo si su destino está fuera de `ipv4NativeRoutingCIDR`** y su origen es una IP de Pod gestionada por Cilium — con las exenciones adicionales de que (a) el destino no es otro nodo del clúster, y (b) el destino no está listado en los CIDRs de no-masquerade del ip-masq-agent cuando ese agente está habilitado. Todo lo que esté dentro de `ipv4NativeRoutingCIDR` conserva su dirección de origen de Pod. En modo tunnel el predicado equivalente es "el destino no es un endpoint conocido del clúster / nodo remoto", ya que el tráfico intra-clúster va por el túnel y nunca llega al hook de masquerade en el uplink de la misma manera.

**A8.3** — El echo ICMP no tiene puertos L4, así que una implementación de NAT no puede usar un puerto para demultiplexar el tráfico de retorno. En su lugar reescribe el campo **identifier** de ICMP, que cumple el mismo propósito: varios Pods pueden hacer ping al mismo host externo concurrentemente, y el nodo necesita una clave por flujo para mapear cada *reply* de echo de vuelta al Pod originante correcto. El mapa NAT de Cilium por lo tanto trata el id de ICMP como el "puerto" — de ahí que `10.0.1.77:12` se convierta en `172.18.0.3:32410`. Este es comportamiento NAPT estándar para ICMP (RFC 5508), no un invento de Cilium.

**A8.4** — El underlay `172.18.0.0/16` debe tener una **ruta de vuelta al Pod CIDR `10.0.0.0/8` vía el nodo correcto**. De lo contrario el destino recibe un paquete desde `10.0.1.77`, responde a `10.0.1.77`, y su tabla de rutas no tiene idea de dónde está eso — la respuesta se descarta o se envía a un gateway por defecto que la hace desaparecer. El modo de falla es **tráfico unidireccional**: `tcpdump` en el nodo muestra la petición saliendo, no vuelve nada, y la aplicación reporta timeout. Esta es la trampa estándar con los CIDRs de no-masquerade de `ipMasqAgent`: eximir un destino del SNAT solo es seguro si la red de ese destino puede rutear hacia tu Pod CIDR. En la práctica, usá CIDRs de no-masquerade para redes on-prem donde anunciaste el Pod CIDR (vía BGP o rutas estáticas), nunca para internet.

**A8.5** — El **Egress Gateway**, implementado por el CRD **`CiliumEgressGatewayPolicy`**. Selecciona Pods de origen (por namespace/etiqueta) y CIDRs de destino, y rutea su egress a través de un nodo gateway designado, donde al tráfico se le hace SNAT a una **IP de egress** específica de ese nodo. Esa única IP estable es la que le das a la parte externa para su allowlist. Requisitos: `egressGateway.enabled=true`, **`bpf.masquerade=true`** (la funcionalidad está construida sobre el camino de masquerade/NAT de eBPF y no funciona con masquerading por iptables), reemplazo de kube-proxy habilitado, y un kernel adecuado. Tené en cuenta la implicancia de disponibilidad: el nodo gateway se convierte en un cuello de botella y un dominio de falla para el egress de ese namespace — dimensionalo y emparejalo en consecuencia.

---

### Bloque 9 — Diagnóstico

**A9.1** — Con socket LB, el hook de `connect(2)` busca `10.96.142.201:80` en el mapa de servicios. El frontend sigue existiendo (el slot 0 está presente) pero tiene **cero backends**, así que no hay dirección a la cual reescribir. El comportamiento de Cilium en ese caso es dejar que la conexión sea descartada en vez de rechazarla: el paquete o bien no se emite hacia un destino válido o bien se descarta en el datapath, así que el cliente no ve **ninguna respuesta** y su stack TCP retransmite el SYN hasta que salta el timeout de `curl` — de ahí el `000` y el código de salida 28. Un `connection refused` requeriría un RST de algo que sea dueño de la dirección, y nada lo es. Esta distinción es útil para el diagnóstico: *timeout* en una ClusterIP apunta a "sin backends / drop por policy / datapath"; *refused* apunta a "existe un backend y está rechazando activamente", es decir, un problema a nivel de aplicación.

**A9.2** — **`bpf_lxc.c`** es el programa adjunto a la **interfaz veth (`lxc*`) del Pod** — es decir, el drop ocurrió en el datapath del *endpoint de destino*, no en el uplink (`bpf_host.c`) ni en el overlay (`bpf_overlay.c`). Combinado con `to endpoint 794`, este es el paquete llegando al endpoint, así que es **enforcement de policy de ingress** en el destino — consistente con que `cilium-dbg endpoint list` muestre `POLICY (ingress) ENFORCEMENT: Enabled` para los endpoints `web` y `Disabled` para egress. Leer el nombre del archivo es la forma más rápida de localizar un drop: `bpf_lxc.c` = en un Pod, `bpf_host.c` = en el host/uplink, `bpf_overlay.c` = en el camino del túnel, `bpf_sock.c` = capa de socket.

**A9.3** — El formato es `identity <origen>-><destino>`. Así que **39117 es el origen** (el Pod `client`) y **51338 es el destino** (los Pods `web`, después del re-etiquetado `tier=frontend` del Ejercicio 5). Resolvé cualquiera con `cilium-dbg identity get <id>` dentro de un pod del agente, o a nivel de clúster con `kubectl get ciliumidentity <id> -o yaml` (el campo `security-labels`). Hubble hace esto por vos automáticamente, imprimiendo `default/client (ID:39117)`.

**A9.4** — La **agregación del monitor** suprime eventos de datapath repetidos de la misma conexión para reducir el volumen de eventos empujados al ring buffer del monitor/Hubble — por ejemplo, reportando solo el primer paquete de un flujo en cada dirección y cualquier paquete con flags TCP nuevos, en vez de cada paquete. Se controla con **`bpf.monitorAggregation`** (valores `none`, `low`, `medium` (default), `maximum`), con `bpf.monitorInterval` y `bpf.monitorFlags` como refinamientos. Ponerlo en `none` te da cada evento de cada paquete — invaluable cuando perseguís un drop intermitente a mitad de flujo — pero el costo es significativo: CPU alto en el agente, throughput alto del perf ring, y un riesgo real de **eventos perdidos** y mayor latencia en nodos ocupados. Bajalo temporalmente en un nodo, nunca en todo el clúster en producción.

**A9.5** — Dos razones de producción, de entre varias válidas:
1. **Vista agregada a nivel de todo el clúster.** `cilium-dbg monitor` muestra solo el nodo en el que hiciste exec; con Hubble Relay, `hubble observe` consulta todos los nodos a la vez. Cuando todavía no sabés en qué nodo está el drop — el caso normal — la herramienta por nodo significa N sesiones de exec y una carrera contra el ring buffer.
2. **Resolución de identidades y filtrado conscientes de Kubernetes.** Hubble imprime `default/client:51210 (ID:39117) -> default/web-...:80`, resolviendo identidades a nombres de namespace/Pod, y soporta filtros del lado del servidor (`--to-label`, `--verdict DROPPED`, `--protocol`, `--namespace`) más visibilidad L7. `cilium-dbg monitor` te da números crudos de identidad que tenés que resolver a mano.

También válido: Hubble no requiere hacer `exec` dentro de un pod de sistema privilegiado (mejor postura de RBAC), exporta métricas y puede persistir flujos, y tiene una UI para visualizar el mapa de servicios.

**A9.6** — De lo más barato a lo más caro:

1. **`kubectl get endpointslices`** — una sola lectura de la API, sin mutar el clúster, sin acceso privilegiado. Responde "¿el Service tiene algún backend?", que es la causa raíz más común. Empezá siempre acá.
2. **`cilium-dbg service list`** — un exec en un agente, volcado de mapas de solo lectura. Responde "¿Cilium programó lo que dice el API server?", aislando un problema de sincronización control-plane-a-datapath de un problema de objetos de Kubernetes.
3. **`cilium-dbg monitor --type drop`** — requiere un exec privilegiado, transmite eventos en vivo (así que tenés que reproducir el tráfico), e impone overhead real en un nodo ocupado. Usalo una vez que sepas *qué* nodo mirar, que es lo que te dicen los dos primeros pasos.
4. **`cilium connectivity test`** — por lejos el más caro: crea namespaces, deployments y servicios, corre decenas de pruebas durante varios minutos, y consume recursos del clúster. Es una verificación amplia de regresión para "¿la instalación está sana?", no un diagnóstico dirigido a un flujo con falla. Corrélo después de un cambio o un upgrade, no como primera respuesta a un solo servicio roto.

El principio general: moverse desde el *estado declarativo* (objetos de la API) → *estado programado* (mapas eBPF) → *comportamiento observado* (eventos en vivo) → *validación sintética* (suite de pruebas). Cada paso cuesta más y acota menos.

</details>

---

## Fuentes

* Currícula CCA — https://github.com/cncf/curriculum/blob/master/cca/README.md
* Cilium — Networking concepts — https://docs.cilium.io/en/stable/network/concepts/
* Cilium — Routing modes — https://docs.cilium.io/en/stable/network/concepts/routing/
* Cilium — IP Address Management — https://docs.cilium.io/en/stable/network/concepts/ipam/
* Cilium — Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
* Cilium — Kubernetes without kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
* Cilium — Egress Gateway — https://docs.cilium.io/en/stable/network/egress-gateway/
* Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
* Cilium — Helm reference — https://docs.cilium.io/en/stable/helm-reference/
* Hubble — Observability — https://docs.cilium.io/en/stable/observability/hubble/
* Maglev: A Fast and Reliable Software Network Load Balancer (Google, NSDI 2016) — https://research.google/pubs/pub44824/
* RFC 5508 — NAT Behavioral Requirements for ICMP — https://datatracker.ietf.org/doc/html/rfc5508