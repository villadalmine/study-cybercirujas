# 1.1 Fundamentos de Cilium

> **Peso del dominio: 20%** — el bloque individual más grande del examen CCA, y el sustrato sobre el que se construye cada uno de los otros dominios (Network Policy, Observabilidad, Service Mesh, Cluster Mesh). Si no entendés la *identidad*, la *ipcache* y *dónde están enganchados los programas eBPF*, cada pregunta de troubleshooting de los demás dominios se vuelve adivinanza.

---

## 1. El problema arquitectónico que Cilium existe para resolver

### 1.1 Las dos mentiras del datapath de Kubernetes pre-eBPF

El networking de Kubernetes, tal como fue especificado originalmente, descansa sobre dos supuestos que dejan de ser ciertos a escala de producción:

**Mentira #1: "la dirección IP identifica a la carga de trabajo".**
Todo CNI basado en `iptables`, todo firewall heredado y toda ACL de tu red corporativa codifican la política como `10.244.3.17 puede hablar con 10.244.9.4`. En un clúster donde el rollout de un Deployment reemplaza cada IP de Pod en 40 segundos, y donde el mismo `/16` se recicla entre namespaces en cuestión de minutos, una IP es un *alquiler*, no una identidad. El modo de fallo no es teórico: la política converge más lento de lo que rota la carga de trabajo, así que existe una ventana en la que un Pod recién planificado hereda una IP que todavía carga la ACL del inquilino anterior. Eso es un bug de autorización silencioso que ninguna suite de tests atrapa.

**Mentira #2: "el paquete debe atravesar el stack de red completo".**
Un paquete Pod-a-Pod en el mismo nodo, con un par veth y un bridge, atraviesa: socket → TCP → IP → netfilter `OUTPUT` → routing → netfilter `POSTROUTING` → veth xmit → veth rx (softirq) → netfilter `PREROUTING` → routing → netfilter `FORWARD` → veth xmit → veth rx → netfilter `PREROUTING` → routing → netfilter `INPUT` → TCP → socket. El paquete se parsea, se sigue por conntrack y se re-enruta varias veces para moverse entre dos procesos del mismo kernel.

### 1.2 El argumento cuantitativo contra `kube-proxy` + `iptables`

`kube-proxy` en modo `iptables` programa una estructura de cadenas que es *lineal en la cantidad de services* y *lineal en la cantidad de backends por service*. Para cada service ClusterIP emite (aproximadamente) una regla de match en `KUBE-SERVICES`, una cadena `KUBE-SVC-XXXX` con una regla de salto probabilístico por endpoint, y una cadena `KUBE-SEP-XXXX` con dos reglas (mark-masq + DNAT) por endpoint.

| Forma del clúster | Services | Endpoints/svc | Reglas iptables aprox. | Sync completo de `iptables-restore` (observado) |
|---|---:|---:|---:|---:|
| Chico | 100 | 4 | ~2.000 | < 50 ms |
| Mediano | 1.000 | 8 | ~20.000 | ~0,5–1 s |
| Grande | 5.000 | 10 | ~120.000 | ~3–10 s |
| Muy grande | 10.000 | 20 | ~450.000 | decenas de segundos |

Emergen tres patologías distintas:

1. **El costo de actualización es O(reglas totales), no O(reglas cambiadas).** `kube-proxy` reescribe la tabla entera bajo el lock de `xtables`. Un cambio de Endpoint en un Service paga por los 10.000 Services. Por eso existe `--iptables-min-sync-period` — es un limitador de tasa que canjea *latencia de correctitud* (cuánto tiempo un backend terminado sigue recibiendo tráfico) por *CPU*.
2. **El costo de búsqueda es O(n) en el camino de match.** Netfilter recorre la lista de reglas. Un paquete a un service cercano al final de `KUBE-SERVICES` se evalúa contra miles de reglas previas. El modo IPVS arregla la *búsqueda* (tabla hash) pero no el modelo de identidad, y sigue dependiendo de netfilter para masquerading y política.
3. **El lock de `xtables` es un punto de serialización a nivel clúster**, compartido con cualquier otra cosa del nodo que toque iptables (Docker, otros CNIs, agentes de nodo, `firewalld`).

### 1.3 Qué cambia Cilium

Cilium reemplaza ambas mentiras:

- **La identidad reemplaza a la IP.** La identidad de seguridad de una carga de trabajo se deriva de sus *labels*. `10.244.3.17` no es una identidad; `k8s:app=deathstar, k8s:io.kubernetes.pod.namespace=default` sí lo es, y se mapea a una identidad numérica estable (por ejemplo `35109`) válida en todo el clúster (y, con Cluster Mesh, en toda la malla). La política se compila contra ese número. La rotación de Pods no invalida la política.
- **eBPF reemplaza el recorrido.** Programas enganchados en los hooks `tc`, XDP y cgroup realizan la búsqueda, la aplicación de política, el NAT y el forwarding con búsquedas en mapas hash (O(1)), cortocircuitando netfilter y (con BPF host routing) buena parte del stack de routing.

---

## 2. eBPF: el mecanismo, no el marketing

Te van a evaluar sobre *dónde* corren los programas de Cilium y *qué estado leen*. Eso exige conocer el sustrato.

### 2.1 El modelo de ejecución

eBPF es una máquina virtual dentro del kernel con un contrato de seguridad estricto:

| Etapa | Qué pasa | Modo de fallo que vas a ver |
|---|---|---|
| **Compile** | Clang/LLVM emite bytecode BPF desde C restringido (`bpf/*.c` en el árbol de Cilium) | Solo en tiempo de build |
| **Load** | Syscall `bpf()`, programa + FDs de mapas | `Failed to load program` en el log del agente |
| **Verify** | Análisis estático: bucles acotados, sin aritmética de punteros sin chequear, todos los accesos a memoria probados dentro de rango, ≤1M instrucciones analizadas | `permission denied` / volcado del log del verificador en los logs de `cilium-agent` |
| **JIT** | Bytecode → código máquina nativo (x86-64/arm64) | — |
| **Attach** | Programa enganchado a un hook (tc/XDP/cgroup/tracing) | `Unable to attach program to device` |

El verificador es la razón por la cual un programa eBPF no puede colgar el kernel ni entrar en bucle infinito, y también la razón por la que el datapath de Cilium usa **tail calls** (`bpf_tail_call()` vía los mapas program-array `cilium_calls_*`) — el presupuesto de instrucciones por programa obliga a partir el datapath en programas encadenados en vez de un monolito.

### 2.2 Mapas: el plano de estado compartido

Los mapas son el único estado durable y el único canal entre el datapath eBPF y el agente en espacio de usuario. Este es el hecho operativo más importante de todo el dominio: **`cilium-agent` es un plano de control que escribe mapas; no está en el camino del paquete.** Si el agente muere, el datapath sigue reenviando con el último estado programado.

| Mapa (pineado bajo `/sys/fs/bpf/tc/globals/`) | Tipo | Contenido | Leído por |
|---|---|---|---|
| `cilium_lxc` | hash | IP de endpoint local → ID de endpoint, MAC, ifindex, identidad | `bpf_lxc`, `bpf_host` |
| `cilium_ipcache` | trie LPM | **cualquier** IP/CIDR → identidad de seguridad + tunnel endpoint + clave de cifrado | todos los programas |
| `cilium_policy_v2_<epid>` | hash | (identidad, dirección, proto, puerto) → allow/deny + puerto de proxy | `bpf_lxc` |
| `cilium_ct4_global` / `cilium_ct6_global` | LRU hash | Entradas de connection tracking TCP | todos |
| `cilium_ct_any4_global` | LRU hash | Entradas CT no-TCP (UDP/ICMP) | todos |
| `cilium_lb4_services_v2` | hash | (IP de frontend, puerto, proto, slot) → slot de backend / ID de revNAT | `bpf_sock`, `bpf_host`, `bpf_lxc` |
| `cilium_lb4_backends_v3` | hash | ID de backend → IP, puerto, estado | ídem |
| `cilium_lb4_reverse_nat` | hash | ID de revNAT → frontend original (para reescribir respuestas) | ídem |
| `cilium_lb4_maglev` | array-of-array | Tabla de búsqueda Maglev por service (por defecto 16381 entradas) | ídem |
| `cilium_snat_v4_external` | LRU hash | Bindings NAT de masquerade | `bpf_host` |
| `cilium_tunnel_map` | hash | CIDR de pods remoto / IP de endpoint → IP de túnel del nodo remoto | `bpf_overlay`, `bpf_lxc` |
| `cilium_node_map` | hash | IP de nodo → ID de nodo (usado por egress gw / cifrado) | `bpf_host` |
| `cilium_events` | perf event array | Notificaciones datapath → agente (drops, traces, veredictos de política) | Hubble / `cilium monitor` |
| `cilium_metrics` | per-CPU hash | Contadores del datapath (razones de drop, conteos de forward) | `cilium-dbg bpf metrics list` |
| `cilium_calls_*` | prog array | Destinos de tail-call | datapath |

### 2.3 Puntos de enganche y el camino del paquete

```
                    ┌──────────────── application process ────────────────┐
                    │  connect() / sendmsg() / getpeername()              │
                    └──────────────────────┬──────────────────────────────┘
                                           │  cgroup/connect4  ── bpf_sock.c
                                           │  (SOCKET LB: ClusterIP rewritten
                                           │   to a backend IP *before* a packet
                                           │   ever exists — zero per-packet NAT)
                    ┌──────────────────────▼──────────────────────────────┐
                    │  TCP/IP stack inside the Pod netns                  │
                    └──────────────────────┬──────────────────────────────┘
                                           │ veth (or netkit) xmit
          ┌────────────────────────────────▼───────────────────────────────┐
          │ tc ingress on lxcXXXX (host side)  ── bpf_lxc.c "from-container"│
          │   • resolve source identity from cilium_lxc                    │
          │   • resolve dest identity from cilium_ipcache (LPM)            │
          │   • EGRESS policy lookup in cilium_policy_v2_<epid>            │
          │   • service translation (if not already done by socket LB)     │
          │   • conntrack create/lookup in cilium_ct4_global               │
          └────────────────┬───────────────────────┬───────────────────────┘
                           │ same node             │ remote node
           ┌───────────────▼──────────┐   ┌────────▼───────────────────────┐
           │ tc ingress on peer lxc   │   │ encap → cilium_vxlan (bpf_over- │
           │  bpf_lxc "to-container"  │   │ lay.c)  OR  native route out    │
           │  • INGRESS policy        │   │ eth0 (bpf_host.c "to-netdev":   │
           │  • deliver               │   │ masquerade, NodePort revDNAT)   │
           └──────────────────────────┘   └─────────────────────────────────┘

XDP (optional, driver-level, pre-skb): bpf_xdp.c — NodePort/LoadBalancer forwarding
and CIDR prefilter at line rate, before sk_buff allocation.
```

**Asimetría relevante para el examen:** el programa enganchado en `tc ingress` del *veth del lado host* maneja el tráfico de **egress** del Pod. Los paquetes que salen del Pod llegan al host como ingress. Esto confunde a quien lee la salida de `tc filter show`.

---

## 3. Arquitectura de componentes

### 3.1 Las piezas

| Componente | Tipo | Dónde corre | Responsabilidad | ¿Crítico en el datapath? |
|---|---|---|---|---|
| `cilium-agent` | DaemonSet | cada nodo | Observa la API de K8s; computa identidades y políticas; compila/carga eBPF; escribe mapas; ejecuta el proxy DNS; sirve la API de health | **No** (plano de control) |
| `cilium-cni` | binario en `/opt/cni/bin/cilium-cni` | cada nodo | CNI ADD/DEL invocado por el runtime de contenedores del kubelet; habla con el agente por `/var/run/cilium/cilium.sock` | Sí, para la creación de Pods |
| `cilium-operator` | Deployment (HA: 2 réplicas, con elección de líder) | cualquier nodo | Trabajo a nivel clúster: asignación de CIDR de IPAM por nodo, garbage collection de `CiliumIdentity`, GC de `CiliumEndpoint`, heartbeat del KVStore, reconciliación de Ingress/LB-IPAM | No |
| `cilium-envoy` | DaemonSet (por defecto desde 1.16) | cada nodo | Proxy L7 para política L7, Ingress, Gateway API, terminación mTLS | Solo para flujos redirigidos a L7 |
| `hubble-relay` | Deployment | cualquier nodo | Agrega el gRPC de Hubble por nodo en una única API a nivel clúster | No |
| `hubble-ui` | Deployment | cualquier nodo | Frontend web para Relay | No |
| `clustermesh-apiserver` | Deployment | cualquier nodo | Expone las identidades/endpoints/services de este clúster a clústeres remotos | No |
| `cilium-dbg` | binario **dentro** del pod del agente | — | Introspección de bajo nivel del estado y los mapas *de este nodo* | — |
| `cilium` (cilium-cli) | binario en tu estación de trabajo | — | Instalar/actualizar, `status`, `connectivity test`, `sysdump` | — |

> **Trampa de nombres (se evalúa con frecuencia):** desde v1.16 el binario dentro del pod es **`cilium-dbg`**; `cilium` dentro del pod es un shim de compatibilidad. La CLI `cilium` del lado host (`cilium-cli`) y el `cilium-dbg` del pod tienen subcomandos *distintos y sin solapamiento*. `cilium status` (host) reporta la salud de Deployment/DaemonSet; `cilium-dbg status` (pod) reporta el estado del datapath en un nodo.

### 3.2 Dónde vive el estado del clúster

Cilium necesita un almacén distribuido para identidades y metadatos de endpoints. Dos modos:

| | `identityAllocationMode: crd` (por defecto) | `identityAllocationMode: kvstore` |
|---|---|---|
| Almacén de respaldo | API de Kubernetes (CRs `CiliumIdentity`) | etcd externo (o el etcd de `clustermesh-apiserver`) |
| Infraestructura extra | ninguna | clúster etcd que operar, respaldar y rotarle TLS |
| Techo de escala | carga de watch/write sobre kube-apiserver; se degrada ante rotación de identidades muy alta (miles de identidades, rotación rápida) | mucho mayor; se desacopla de kube-apiserver |
| Radio de impacto de fallos | una caída del apiserver frena la asignación de identidades (el datapath existente sigue funcionando) | una caída de etcd la frena |
| Uso típico | 99% de los clústeres | clústeres muy grandes, Cluster Mesh a escala |
| Camino de migración | modos intermedios `doublewrite-readonly-kvstore` / `doublewrite-readonly-crd` | — |

### 3.3 Los CRDs que tenés que reconocer

```
$ kubectl get crd -o name | grep cilium
customresourcedefinition.apiextensions.k8s.io/ciliumbgpadvertisements.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgpclusterconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgpnodeconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgppeerconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumcidrgroups.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumclusterwidenetworkpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumendpoints.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumendpointslices.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumexternalworkloads.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumidentities.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumloadbalancerippools.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliuml2announcementpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumnetworkpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumnodes.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumpodippools.cilium.io
```

| CRD | Alcance | Qué es |
|---|---|---|
| `CiliumIdentity` (`ciliumid`) | clúster | El vínculo conjunto-de-labels ↔ identidad-numérica. Recolectado por el operator. |
| `CiliumEndpoint` (`cep`) | namespaced | Estado del datapath por Pod: identidad, IPs, estado de aplicación de política. Uno por Pod. |
| `CiliumEndpointSlice` (`ces`) | clúster | Agrupa muchos `CiliumEndpoint` en un solo objeto para recortar el tráfico de watch al apiserver a escala. |
| `CiliumNode` (`cn`) | clúster | Pool de IPAM por nodo, IPs del nodo, índice de clave de cifrado, IPs de health. |
| `CiliumNetworkPolicy` (`cnp`) | namespaced | Política L3/L4/L7 consciente de identidad. |
| `CiliumClusterwideNetworkPolicy` (`ccnp`) | clúster | Lo mismo, pero con alcance de clúster (y la única que puede seleccionar `reserved:host`). |
| `CiliumLoadBalancerIPPool` | clúster | Pools de direcciones de LB-IPAM para Services `type: LoadBalancer`. |

---

## 4. El modelo de identidad — el núcleo conceptual de Cilium

### 4.1 De labels a un número

1. El agente observa un Pod y recolecta sus labels.
2. Los **filtra** a través de la lista de allow/deny de labels (`--labels`, por defecto: descarta `pod-template-hash`, `controller-revision-hash` y otros labels de alta cardinalidad y rotación). *Ese filtrado es lo que mantiene acotada la cantidad de identidades* — sin él, cada rollout de ReplicaSet acuñaría identidades nuevas.
3. El conjunto de labels sobreviviente, ordenado canónicamente con prefijos de origen (`k8s:`, `container:`, `reserved:`, `unspec:`), es la **clave de identidad**.
4. El agente asigna (o reutiliza) una identidad numérica para esa clave vía el asignador CRD/kvstore.
5. Cada nodo aprende `IP → identidad` vía la **ipcache** y compila la política contra el número.

Dos Pods con labels (filtrados) idénticos **comparten una identidad**, incluso entre nodos y entre namespaces con los mismos labels. Escalar un Deployment de 3 a 300 réplicas crea **cero** identidades nuevas y **cero** entradas nuevas en el mapa de políticas.

### 4.2 Espacios numéricos de identidad

| Rango | Alcance | Significado |
|---:|---|---|
| `1`–`255` | reservado | Identidades bien conocidas, hardcodeadas |
| `256`–`65535` | global del clúster | Identidades de carga de trabajo derivadas de labels |
| `≥ 16777216` (`1<<24`) | **local al nodo** | Identidades derivadas de CIDR y FQDN — asignadas *localmente*, nunca compartidas, nunca válidas en otro nodo |
| `clusterID<<16 \| localID` | global de la malla | Con Cluster Mesh, el ID de clúster se codifica en los bits altos (por defecto `max-connected-clusters=255` → 8 bits de ID de clúster) |

**Identidades reservadas (memorizalas):**

| ID | Nombre | Significado |
|---:|---|---|
| 1 | `reserved:host` | El nodo local en sí (todas las IPs del host, incluida `cilium_host`) |
| 2 | `reserved:world` | Cualquier cosa fuera del clúster |
| 3 | `reserved:unmanaged` | Un endpoint que Cilium conoce pero no gestiona |
| 4 | `reserved:health` | El propio endpoint de health-check de Cilium (`cilium_health`) |
| 5 | `reserved:init` | Endpoint cuyos labels todavía no fueron resueltos (transitorio al arrancar el Pod) |
| 6 | `reserved:remote-node` | Cualquier **otro** nodo del clúster (o de la malla) |
| 7 | `reserved:kube-apiserver` | El o los API servers, dentro o fuera del clúster |
| 8 | `reserved:ingress` | Identidad de origen de Cilium Ingress/Gateway API |
| 9 | `reserved:world-ipv4` | `reserved:world` dividido, mitad IPv4 (dual-stack) |
| 10 | `reserved:world-ipv6` | `reserved:world` dividido, mitad IPv6 (dual-stack) |

> **Trampa de producción:** `reserved:host` y `reserved:remote-node` son distintos. Antes de Cilium 1.7, los nodos remotos formaban parte de `host`. Una política que permite `fromEntities: [host]` **no** permite otros nodos. Y el tráfico de `reserved:host` está **siempre permitido por defecto** salvo que el Host Firewall (`hostFirewall.enabled=true`) esté activo — esto es una propiedad de seguridad deliberada para evitar que te dejes afuera del nodo, y una fuente común de confusión del tipo "¿por qué mi política no bloquea al kubelet?".

### 4.3 La ipcache: el trie LPM que hace que todo funcione

La ipcache responde una pregunta para cada paquete: *dada esta IP, ¿qué identidad es, y si es remota, qué nodo la aloja?*

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf ipcache list
IP PREFIX/ADDRESS        IDENTITY
0.0.0.0/0                identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.10/32             identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.11/32             identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.12/32             identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.13/32             identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.9/32            identity=4 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.87/32           identity=24512 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.201/32          identity=35109 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.2.31/32           identity=35109 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.2.0/24            identity=6 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.3.0/24            identity=6 encryptkey=0 tunnelendpoint=10.0.1.13 flags=<none>
203.0.113.0/24           identity=16777218 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

Leelo con atención — codifica todo el diseño:

- `0.0.0.0/0 → identity=2` es la **ruta por defecto del espacio de identidades**: todo lo que no se conozca de otra forma es `reserved:world`.
- `10.244.2.31/32 → identity=35109, tunnelendpoint=10.0.1.12` — un Pod *remoto*: conocemos tanto su identidad (así podemos aplicar política localmente, en el origen) como el nodo hacia el cual encapsular.
- `203.0.113.0/24 → 16777218` — una **identidad CIDR de alcance local** creada por una regla de política `toCIDR` en este nodo. Ese número no significa nada en ningún otro nodo.
- El match de prefijo más largo hace que `10.244.2.31/32` (un pod específico) gane sobre `10.244.2.0/24` (el CIDR de pods del nodo remoto).

**La política de egress se aplica en el nodo de origen** porque el nodo de origen ya conoce la identidad del destino gracias a la ipcache. **La política de ingress se aplica en el nodo de destino.** Una sola conexión se evalúa entonces dos veces, por dos mapas de política distintos, en dos máquinas distintas.

### 4.4 Ver las identidades

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity list
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
9          reserved:world-ipv4
10         reserved:world-ipv6
6789       k8s:app=kube-dns
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=kube-system
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=coredns
           k8s:io.kubernetes.pod.namespace=kube-system
           k8s:k8s-app=kube-dns
24512      k8s:app.kubernetes.io/name=tiefighter
           k8s:class=tiefighter
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
35109      k8s:app.kubernetes.io/name=deathstar
           k8s:class=deathstar
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
16777218   cidr:203.0.113.0/24
           reserved:world
```

Fijate en los cuatro labels `k8s:` inyectados automáticamente presentes en toda identidad de carga de trabajo: namespace, labels del namespace (`io.cilium.k8s.namespace.labels.*`), service account (`io.cilium.k8s.policy.serviceaccount`) y nombre del clúster (`io.cilium.k8s.policy.cluster`). Esos son los que hacen posibles `namespaceSelector`, la política basada en ServiceAccount y la política de Cluster Mesh.

### 4.5 Endpoints

Un **endpoint** es la unidad de gestión del datapath de Cilium — normalmente un Pod, pero también `cilium_host` (el nodo mismo) y `cilium_health`.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4           STATUS
           ENFORCEMENT        ENFORCEMENT
196        Disabled           Disabled          4          reserved:health                                                 10.244.1.9     ready
742        Disabled           Disabled          6789       k8s:app=kube-dns                                                10.244.1.42    ready
                                                           k8s:io.kubernetes.pod.namespace=kube-system
                                                           k8s:k8s-app=kube-dns
1420       Enabled            Disabled          35109      k8s:app.kubernetes.io/name=deathstar                            10.244.1.201   ready
                                                           k8s:class=deathstar
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
2103       Disabled           Enabled           24512      k8s:app.kubernetes.io/name=tiefighter                           10.244.1.87    ready
                                                           k8s:class=tiefighter
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
3187       Disabled           Disabled          1          reserved:host                                                                  ready
```

**Estados del ciclo de vida del endpoint** (columna `STATUS`): `waiting-for-identity` → `waiting-to-regenerate` → `regenerating` → `ready`. También `restoring` (reinicio del agente, endpoints siendo readoptados desde `/var/run/cilium/state/`), `disconnecting`, `disconnected`, `invalid`.

Un endpoint trabado en `waiting-for-identity` significa que el asignador de identidades no puede alcanzar su almacén de respaldo (kube-apiserver o etcd). Un endpoint trabado en `regenerating` normalmente significa que la compilación/carga de eBPF está fallando — revisá el log del agente buscando salida del verificador.

**La aplicación de política es por dirección y por endpoint, y es implícitamente "permitir por defecto hasta ser seleccionado".** Un endpoint muestra `Enabled` para una dirección solo cuando al menos una regla de política lo selecciona en esa dirección. Este es el modelo de Kubernetes (semántica de `NetworkPolicy`) y es la razón por la que `tiefighter` arriba muestra `Egress: Enabled, Ingress: Disabled`.

---

## 5. Modos de datapath: encapsulación vs. routing nativo

### 5.1 La decisión

| | **Encapsulación** (`routingMode: tunnel`) | **Routing nativo** (`routingMode: native`) |
|---|---|---|
| Protocolos | VXLAN (UDP/8472, por defecto) o Geneve (UDP/6081) | ninguno — IP plano |
| Requisito del underlay | Solo alcanzabilidad IP entre nodos. Los CIDRs de pods son invisibles para la red. | El underlay **debe** enrutar los CIDRs de pods: o bien adyacencia L2 + `autoDirectNodeRoutes`, o un router que los aprenda (BGP, tablas de rutas del cloud) |
| Costo de MTU | −50 bytes (VXLAN y Geneve con opciones por defecto sobre IPv4) | 0 |
| Throughput | Menor: encap/decap + trabajo extra de checksum; el offload TSO/GRO varía según la NIC | El más alto |
| Nodos en múltiples subredes | Funciona de fábrica | Necesita BGP o rutas del cloud |
| Canal de metadatos | Las opciones de Geneve / el VNI de VXLAN llevan gratis la identidad de seguridad de origen | La identidad debe resolverse desde la ipcache en el destino (funciona, pero DSR necesita `dsrDispatch: opt` o `geneve` para llevar el estado) |
| Límites del proveedor cloud | Inmune a los límites de entradas en tablas de rutas | Las tablas de rutas de VPC de AWS topean ~50 entradas (100 a pedido) → techo duro de nodos salvo que se use modo ENI |
| Depurabilidad | `tcpdump` muestra tramas encapsuladas; necesita `-d cilium_vxlan` o filtros de decap | Trivial de hacer `tcpdump` |
| Por defecto en Cilium | **sí** (VXLAN) | opt-in |

**Aritmética de MTU que deberías poder hacer en el pizarrón:**

| MTU del underlay | Modo | MTU del Pod | Razón |
|---:|---|---:|---|
| 1500 | native | 1500 | — |
| 1500 | VXLAN | 1450 | 14 (Eth interno) + 8 (VXLAN) + 8 (UDP) + 20 (IPv4 externo) |
| 1500 | Geneve | 1450 | ídem, cabecera base Geneve de 8 bytes, sin opciones |
| 1500 | VXLAN + WireGuard | 1370 | WireGuard agrega 80 bytes por encima |
| 9000 | VXLAN | 8950 | underlay jumbo, mismo overhead |

Un desajuste de MTU es el clásico bug de "los requests chicos funcionan, las respuestas grandes se cuelgan": el handshake TCP y los GET HTTP cortos tienen éxito, una respuesta de 40 KB se traba. Verificá con `cilium-dbg status | grep MTU` y haciendo ping con `-M do -s <size>`.

### 5.2 Submodos del routing nativo

```yaml
# Direct routing on a flat L2 segment (all nodes on the same subnet)
routingMode: native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: true      # program a route per remote node's PodCIDR via its node IP
```

`autoDirectNodeRoutes: true` requiere **adyacencia L2 entre todos los nodos**. Sobre un underlay ruteado, en cambio, anunciás los CIDRs de pods con el plano de control BGP de Cilium (`CiliumBGPClusterConfig`) o te apoyás en la programación de rutas del proveedor cloud.

### 5.3 BPF host routing y netkit

Dos palancas de rendimiento ortogonales que se apilan sobre el routing nativo:

| Feature | Requiere | Qué elimina | Ganancia típica |
|---|---|---|---|
| **BPF host routing** (`bpf.masquerade` + routing nativo, se auto-habilita cuando es posible) | kernel ≥ 5.10, routing nativo, sin interferencia de iptables heredado | El recorrido de routing + netfilter del host; usa `bpf_redirect_peer()`/`bpf_redirect_neigh()` | Reducción significativa de latencia en pod↔pod y pod↔externo |
| **Dispositivos netkit** (`bpf.datapathMode: netkit`) | kernel ≥ 6.8 | El par veth en sí; el programa BPF corre en el contexto del par, eliminando un salto completo de softirq/encolado | Networking de pods acercándose al rendimiento de host-network |

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'Host Routing|Device Mode|Masquerading'
Host Routing:            BPF
Device Mode:             netkit
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
```

Si aparece `Host Routing: Legacy` cuando esperabas BPF, el log del agente indica el motivo (por ejemplo, modo túnel activo, o un requisito de ruta por endpoint).

---

## 6. Modos de IPAM

| Modo (`ipam.mode`) | Quién asigna el CIDR del nodo | Quién asigna la IP del Pod | Cuándo usarlo | Advertencia |
|---|---|---|---|---|
| `cluster-pool` (**por defecto**) | `cilium-operator`, dividiendo `clusterPoolIPv4PodCIDRList` en bloques de `/clusterPoolIPv4MaskSize`, escritos en `CiliumNode.spec.ipam.podCIDRs` | el agente, desde el bloque del nodo | La mayoría de los clústeres on-prem/autogestionados | El CIDR de pods es desconocido para el underlay → túnel o BGP |
| `kubernetes` | kube-controller-manager (`--allocate-node-cidrs`), leído de `Node.spec.podCIDR` | el agente | Cuando otro componente ya es dueño de la asignación de CIDR | Requiere el flag del controller-manager; `/24` por nodo fijado por `--node-cidr-mask-size` |
| `multi-pool` | el operator, desde múltiples CRs `CiliumPodIPPool` | el agente, con el pool elegido por anotación del Pod | Clústeres multi-tenant que necesitan IPs enrutables solo para algunos tenants | Feature más nueva; verificá el soporte por versión |
| `eni` (AWS) | el operator, vía la API de EC2 — engancha ENIs e IPs secundarias | el agente | EKS / AWS con IPs de pod totalmente enrutables en la VPC | El tipo de instancia limita la cantidad de ENIs/IPs; requiere IAM |
| `azure` | el operator vía la API de Azure | el agente | AKS con IPAM al estilo Azure CNI | — |
| `alibabacloud` | el operator | el agente | ENI de Alibaba | — |
| `crd` | un controlador externo escribe `CiliumNode.spec.ipam.pool` | el agente | Integraciones a medida | El asignador es tuyo |
| `delegated-plugin` | otro plugin de IPAM de CNI | ese plugin | Escenarios de encadenamiento de CNI | Cilium no puede reportar el estado de IPAM |

```
$ kubectl get ciliumnode worker-01 -o jsonpath='{.spec.ipam}' | jq
{
  "podCIDRs": [
    "10.244.1.0/24"
  ],
  "pool": {}
}

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 IPAM
IPAM:                    IPv4: 12/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.9 (health)
```

---

## 7. Reemplazo de kube-proxy y el datapath de services

### 7.1 Tres generaciones de balanceo de carga de services

| | `kube-proxy` iptables | `kube-proxy` IPVS | **Cilium eBPF** |
|---|---|---|---|
| Estructura de datos | cadenas lineales de reglas | tabla hash + scheduler IPVS | mapas hash eBPF + tabla Maglev opcional |
| Complejidad de búsqueda | O(n) reglas | O(1) | O(1) |
| Complejidad de actualización | O(reglas totales), reescritura completa de la tabla | O(cambiadas) | O(cambiadas) — escritura de una sola entrada de mapa |
| Dónde ocurre la traducción | por paquete, NAT de netfilter | por paquete, IPVS | **en `connect()`** para este-oeste (socket LB); por paquete en tc/XDP para norte-sur |
| NAT por paquete para TCP intra-clúster | sí | sí | **ninguno** — el socket queda conectado directamente al backend |
| `externalTrafficPolicy` / preservación de la IP de origen | SNAT salvo `Local` | SNAT salvo `Local` | DSR preserva la IP de origen incluso con `Cluster` |
| Hashing consistente ante cambio de backends | no (aleatorio/`probability`) | limitado | **Maglev** — disrupción mínima |
| Costo del health-check | conntrack + reglas | — | flag de estado en una entrada de mapa |
| Optimización local al nodo | no | no | `Local Redirect Policy`, preferencia por backends locales al nodo |

### 7.2 Balanceo de carga a nivel socket — la idea clave

Para un Pod del clúster que llama a `10.96.0.10:53`:

- **Con kube-proxy:** el Pod envía un paquete a `10.96.0.10`; netfilter le hace DNAT a `10.244.2.11`; se crea una entrada de conntrack; cada respuesta recibe NAT inverso. La aplicación cree que está hablando con `10.96.0.10`.
- **Con socket LB de Cilium:** un programa eBPF enganchado al cgroup intercepta la syscall `connect(2)` y **reescribe la dirección de destino en el socket mismo** antes de que exista ningún paquete. El kernel entonces abre una conexión normal a `10.244.2.11:53`. No hay NAT, ni costo por paquete, ni entrada de conntrack asociada al service. `getpeername4` está enganchado para que la aplicación siga observando `10.96.0.10` si pregunta.

Consecuencias para recordar:
- El socket LB requiere **cgroup v2** y el sistema de archivos cgroup2 montado (`/run/cilium/cgroupv2` por defecto). Por eso las instalaciones containerizadas/kind/CI a veces necesitan `cgroup.autoMount.enabled`.
- El socket LB aplica a los Pods que **comparten la jerarquía de cgroups del host**, lo que incluye Pods hostNetwork y procesos del nodo — de ahí `socketLB.hostNamespaceOnly` para entornos donde eso no se desea.
- Como no hay DNAT a nivel paquete para el tráfico este-oeste, `tcpdump` dentro del Pod muestra la **IP del backend**, no la ClusterIP. Esto sorprende a quien está depurando.

### 7.3 Norte-sur: SNAT vs DSR vs Hybrid

| Modo (`loadBalancer.mode`) | Camino de retorno | IP de origen del cliente | Requisito | Compromiso |
|---|---|---|---|---|
| `snat` (por defecto) | de vuelta por el nodo de ingreso | se pierde (salvo `externalTrafficPolicy: Local`) | ninguno | Salto extra; oculta la IP del cliente |
| `dsr` | el nodo del backend responde **directamente** al cliente | preservada | La respuesta debe ser enrutable hacia el cliente desde el nodo del backend; la IP/puerto de service original se transporta vía `dsrDispatch: opt` (opción IPv4 / cabecera de extensión IPv6) o `geneve` (opción Geneve, funciona a través de L3) | `opt` puede ser descartado por middleboxes/caminos sensibles a MTU |
| `hybrid` | DSR para TCP, SNAT para UDP | preservada para TCP | como DSR | Default pragmático para cargas mixtas |
| `annotation` | por Service, vía anotación | — | como DSR | Granularidad fina |

Algoritmo de selección de backend (`loadBalancer.algorithm`): `random` (por defecto) o `maglev` (hashing consistente; `maglev.tableSize` por defecto `16381`, `maglev.hashSeed` **debe ser idéntico en cada nodo**, si no los nodos discrepan sobre a qué backend pertenece un flujo y DSR se rompe).

### 7.4 Inspeccionar los mapas de services

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
ID   Frontend             Service Type   Backend
1    10.96.0.1:443/TCP    ClusterIP      1 => 10.0.1.10:6443/TCP (active)
2    10.96.0.10:53/UDP    ClusterIP      1 => 10.244.1.42:53/UDP (active)
                                         2 => 10.244.2.17:53/UDP (active)
3    10.96.0.10:53/TCP    ClusterIP      1 => 10.244.1.42:53/TCP (active)
                                         2 => 10.244.2.17:53/TCP (active)
4    10.96.0.10:9153/TCP  ClusterIP      1 => 10.244.1.42:9153/TCP (active)
                                         2 => 10.244.2.17:9153/TCP (active)
9    10.96.184.22:80/TCP  ClusterIP      1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
10   0.0.0.0:31234/TCP    NodePort       1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
11   10.0.1.11:31234/TCP  NodePort       1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
12   192.168.30.10:80/TCP LoadBalancer   1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list
SERVICE ADDRESS          BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.96.184.22:80/TCP      0.0.0.0:0 (9) (0) [ClusterIP, non-routable]
                         10.244.1.201:8080/TCP (9) (1)
                         10.244.2.31:8080/TCP (9) (2)
10.96.0.10:53/UDP        0.0.0.0:0 (2) (0) [ClusterIP, non-routable]
                         10.244.1.42:53/UDP (2) (1)
                         10.244.2.17:53/UDP (2) (2)
192.168.30.10:80/TCP     0.0.0.0:0 (12) (0) [LoadBalancer]
                         10.244.1.201:8080/TCP (12) (1)
                         10.244.2.31:8080/TCP (12) (2)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list --revnat
ID   BACKEND ADDRESS (REVNAT_ID) (SLOT)
2    10.96.0.10:53
9    10.96.184.22:80
12   192.168.30.10:80
```

**El slot 0 es la entrada maestra** (contiene el conteo de backends y los flags del service); los slots 1..N son los slots de backend. Un service que muestra el slot 0 con `count=0` y sin slots de backend es un service sin endpoints listos — esto es exactamente cómo se ve "connection refused / no route" desde el lado del datapath.

---

## 8. Configuración completa y desplegable

### 8.1 Un clúster de laboratorio reproducible (kind, sin CNI, sin kube-proxy)

`kind-cilium.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Cilium provides the CNI; disable kind's kindnet.
  disableDefaultCNI: true
  # Disable kube-proxy so Cilium can fully replace it.
  kubeProxyMode: "none"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-b"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-b"
```

```
$ kind create cluster --config kind-cilium.yaml
Creating cluster "cca-lab" ...
 ✓ Ensuring node image (kindest/node:v1.31.4) 🖼
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cca-lab"

$ kubectl get nodes
NAME                   STATUS     ROLES           AGE   VERSION
cca-lab-control-plane  NotReady   control-plane   47s   v1.31.4
cca-lab-worker         NotReady   <none>          31s   v1.31.4
cca-lab-worker2        NotReady   <none>          31s   v1.31.4
cca-lab-worker3        NotReady   <none>          31s   v1.31.4
```

`NotReady` es esperado y correcto: el kubelet reporta `NetworkReady=false` porque todavía no existe configuración de CNI. Esta es la falsa alarma "¿mi clúster está roto?" más común de todas.

### 8.2 Valores de Helm completos — línea base de producción

`values-cilium.yaml`:

```yaml
# ---------------------------------------------------------------------------
# Cilium production baseline. Every value below is deliberate; comments state
# the trade-off being taken. Tested against the 1.17 chart.
# ---------------------------------------------------------------------------

# --- Cluster identity (mandatory before any Cluster Mesh work) -------------
cluster:
  name: leloir
  id: 1                      # 1..255 with the default max-connected-clusters

k8sServiceHost: 10.0.1.10    # REQUIRED when kube-proxy is absent: the agent
k8sServicePort: 6443         # cannot resolve kubernetes.default without it.

# --- Datapath --------------------------------------------------------------
routingMode: native          # tunnel | native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: true   # valid only when all nodes share an L2 segment
enableIPv4Masquerade: true
enableIPv6Masquerade: false

bpf:
  masquerade: true           # eBPF masquerading instead of iptables
  hostLegacyRouting: false   # allow BPF host routing (kernel >= 5.10)
  preallocateMaps: false     # true = lower latency, higher constant memory
  lbExternalClusterIP: false
  # Sizing: raise these BEFORE you hit the ceiling; changing them restarts
  # the datapath and flushes state.
  ctTcpMax: 524288
  ctAnyMax: 262144
  natMax: 524288
  neighMax: 524288
  policyMapMax: 16384        # per-endpoint policy entries
  mapDynamicSizeRatio: 0.0025

# --- kube-proxy replacement -------------------------------------------------
kubeProxyReplacement: true   # 1.16+ uses true/false (was strict/partial/disabled)
k8sServiceProxyName: ""
socketLB:
  enabled: true
  hostNamespaceOnly: false
loadBalancer:
  mode: hybrid               # DSR for TCP, SNAT for UDP
  algorithm: maglev
  dsrDispatch: geneve        # survives L3 hops; 'opt' is IPv4-option based
  acceleration: disabled     # set to 'native' for XDP LB on supported NICs
  serviceTopology: true
maglev:
  tableSize: 16381           # prime; must match on every node
  hashSeed: "JLfvgnHc2kaSUFaI"   # MUST be identical cluster-wide
nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true

# --- IPAM -------------------------------------------------------------------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24     # 254 usable pod IPs per node

# --- Identity ---------------------------------------------------------------
identityAllocationMode: crd
identityChangeGracePeriod: 5s
# Keep identity cardinality bounded: never let deployment-generated labels in.
labels: "k8s:io\\.kubernetes\\.pod\\.namespace k8s:io\\.cilium\\.k8s\\.namespace\\.labels k8s:io\\.cilium\\.k8s\\.policy k8s:app k8s:app\\.kubernetes\\.io/name k8s:tier k8s:class k8s:org k8s:team k8s:env"

# --- Policy -----------------------------------------------------------------
policyEnforcementMode: default      # default | always | never
policyAuditMode: false              # true = log, do not drop. Use for rollout.
hostFirewall:
  enabled: false                    # enabling this can lock you out of nodes

# --- Encryption (choose ONE, or neither) ------------------------------------
encryption:
  enabled: false
  type: wireguard                   # wireguard | ipsec
  nodeEncryption: false
  wireguard:
    persistentKeepalive: 0s

# --- Observability ----------------------------------------------------------
hubble:
  enabled: true
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: false
  relay:
    enabled: true
    rollOutPods: true
  ui:
    enabled: true
  eventBufferCapacity: 16383        # per-node ring buffer of flows
  eventQueueSize: 0                 # 0 = auto (based on CPU count)

prometheus:
  enabled: true
  port: 9962
operator:
  prometheus:
    enabled: true
    port: 9963
  replicas: 2
  rollOutPods: true

# --- L7 / Envoy -------------------------------------------------------------
envoy:
  enabled: true                     # standalone DaemonSet (default since 1.16)
  log:
    defaultLevel: info

ingressController:
  enabled: false
gatewayAPI:
  enabled: false

# --- Resilience -------------------------------------------------------------
rollOutCiliumPods: true
priorityClassName: system-node-critical
resources:
  requests:
    cpu: 200m
    memory: 512Mi
operator:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

# --- Upgrade safety ---------------------------------------------------------
upgradeCompatibility: "1.17"
cni:
  exclusive: true                   # remove other CNI conf files from /etc/cni/net.d
  chainingMode: none

# --- Debug ------------------------------------------------------------------
debug:
  enabled: false
  verbose: ""                       # e.g. "flow datapath policy"
```

Instalación:

```
$ helm repo add cilium https://helm.cilium.io/
"cilium" has been added to your repositories

$ helm upgrade --install cilium cilium/cilium \
    --version 1.17.4 \
    --namespace kube-system \
    --values values-cilium.yaml \
    --wait --timeout 10m
Release "cilium" does not exist. Installing it now.
NAME: cilium
LAST DEPLOYED: Tue Sep  1 11:52:07 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

### 8.3 La configuración de runtime renderizada

Todo lo anterior termina en un único ConfigMap que el agente lee al arrancar. Leerlo es la forma más rápida de saber qué está corriendo *realmente* un clúster:

```
$ kubectl -n kube-system get configmap cilium-config -o yaml | head -60
apiVersion: v1
data:
  agent-not-ready-taint-key: node.cilium.io/agent-not-ready
  arping-refresh-period: 30s
  auto-direct-node-routes: "true"
  bpf-lb-algorithm: maglev
  bpf-lb-external-clusterip: "false"
  bpf-lb-maglev-table-size: "16381"
  bpf-lb-map-max: "65536"
  bpf-lb-mode: hybrid
  bpf-lb-dsr-dispatch: geneve
  bpf-map-dynamic-size-ratio: "0.0025"
  bpf-policy-map-max: "16384"
  bpf-root: /sys/fs/bpf
  cgroup-root: /run/cilium/cgroupv2
  cluster-id: "1"
  cluster-name: leloir
  cni-exclusive: "true"
  debug: "false"
  enable-bpf-masquerade: "true"
  enable-endpoint-health-checking: "true"
  enable-health-checking: "true"
  enable-hubble: "true"
  enable-ipv4: "true"
  enable-ipv4-masquerade: "true"
  enable-ipv6: "false"
  enable-l7-proxy: "true"
  enable-policy: default
  identity-allocation-mode: crd
  ipam: cluster-pool
  ipv4-native-routing-cidr: 10.244.0.0/16
  kube-proxy-replacement: "true"
  routing-mode: native
  tunnel-protocol: vxlan
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
```

> **Regla operativa:** nunca edites `cilium-config` a mano. El agente lo observa y algunas claves se recargan en caliente mientras que otras no, así que una edición manual produce un nodo cuyo datapath no coincide con su configuración y que revierte en la próxima corrida de Helm. Cambiá los valores a través de Helm y rotá el DaemonSet.

### 8.4 Una política basada en identidad (la recompensa)

Esto es lo que te compra la identidad — una regla que sobrevive a cada cambio de IP de Pod:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-access
  namespace: default
spec:
  description: "Only empire tiefighters may request landing; only on POST /v1/request-landing"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
            class: tiefighter
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
  egress:
    # DNS must be explicitly allowed once egress enforcement turns on.
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
    - toFQDNs:
        - matchName: "telemetry.empire.internal"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

Aplicar esto crea: una nueva entrada en `cilium_policy_v2_1420` con clave en la identidad `24512`, una redirección L7 al Envoy del nodo y (al resolverse el DNS) una identidad FQDN de **alcance local** en la ipcache para `telemetry.empire.internal`.

---

## 9. La escalera de verificación

### 9.1 Nivel 0 — ¿está sano el plano de control?

```
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 4, Ready: 4/4, Available: 4/4
DaemonSet              cilium-envoy             Desired: 4, Ready: 4/4, Available: 4/4
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 4
                       cilium-envoy             Running: 4
                       cilium-operator          Running: 2
                       hubble-relay             Running: 1
                       hubble-ui                Running: 1
Cluster Pods:          31/31 managed by Cilium
Helm chart version:    1.17.4
Image versions         cilium             quay.io/cilium/cilium:v1.17.4: 4
                       cilium-envoy       quay.io/cilium/cilium-envoy:v1.31.5-...: 4
                       cilium-operator    quay.io/cilium/operator-generic:v1.17.4: 2
                       hubble-relay       quay.io/cilium/hubble-relay:v1.17.4: 1
                       hubble-ui          quay.io/cilium/hubble-ui:v0.13.2: 1
```

`Cluster Pods: 31/31 managed by Cilium` es la línea que importa. `29/31` significa que dos Pods no tienen `CiliumEndpoint` — casi siempre Pods que venían corriendo bajo un CNI anterior y nunca se reiniciaron, o Pods hostNetwork (que quedan correctamente excluidos del denominador).

### 9.2 Nivel 1 — ¿está sano el datapath de este nodo?

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.4) [linux/amd64]
Kubernetes APIs:         ["EndpointSliceOrEndpoint", "cilium/v2::CiliumClusterwideNetworkPolicy",
                          "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy",
                          "cilium/v2::CiliumNode", "core/v1::Namespace", "core/v1::Pods",
                          "core/v1::Service", "networking.k8s.io/v1::NetworkPolicy"]
KubeProxyReplacement:    True   [eth0   10.0.1.11 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.17.4 (v1.17.4-6c4f9c1a)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 12/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.9 (health)
  10.244.1.42 (kube-system/coredns-7db6d8ff4d-4x9lp)
  10.244.1.87 (default/tiefighter-6d9b8f4c7-lm2vz)
  10.244.1.201 (default/deathstar-6f87496b94-8kx2m)
  10.244.1.254 (router)
ClusterMesh:             0/0 remote clusters ready
IPv4 BIG TCP:            Disabled
IPv6 BIG TCP:            Disabled
BandwidthManager:        Disabled
Routing:                 Network: Native   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       58/58 healthy
Proxy Status:            OK, ip 10.244.1.254, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 41.72   Metrics: Ok
Encryption:              Disabled
Cluster health:          4/4 reachable   (2026-09-01T12:03:44Z)
  Name                     IP              Node        Endpoints
  leloir/worker-01 (localhost)   10.0.1.11   reachable   reachable
  leloir/control-01              10.0.1.10   reachable   reachable
  leloir/worker-02               10.0.1.12   reachable   reachable
  leloir/worker-03               10.0.1.13   reachable   reachable
Modules Health:          Stopped(0) Degraded(0) OK(102)
BPF Maps:                dynamic sizing: on (ratio: 0.002500)
  Name                          Size
  Auth                          524288
  Non-TCP connection tracking   147903
  TCP connection tracking       295807
  Endpoint policy               65535
  IPv4 masquerading agent       16384
  IPv4 fragmentation            8192
  IPv4 service                  65536
  IPv4 service backend          65536
  IPv4 service reverse NAT      65536
  Metrics                       1024
  NAT                           295807
  Neighbor table                295807
  Global policy                 16384
  Session affinity              65536
  Signal                        8
  Sockmap                       65535
  Sock reverse NAT              65536
  Tunnel                        65536
```

Cada línea de acá es un diagnóstico. Leé primero `Controller Status: 58/58 healthy` y `Modules Health: ... Degraded(0)` — un conteo de degradados distinto de cero nombra al subsistema que falla.

### 9.3 Nivel 2 — ¿el tráfico funciona de verdad?

```
$ cilium connectivity test --test-concurrency 2
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [leloir] Creating namespace cilium-test-1 for connectivity check...
✨ [leloir] Deploying echo-same-node service...
✨ [leloir] Deploying DNS test server configmap...
✨ [leloir] Deploying same-node deployment...
✨ [leloir] Deploying client deployment...
✨ [leloir] Deploying client2 deployment...
✨ [leloir] Deploying echo-other-node service...
⌛ [leloir] Waiting for deployment cilium-test-1/client to become ready...
⌛ [leloir] Waiting for pod cilium-test-1/client-6f8b7d9c4-2xk8p to reach DNS server...
⌛ [leloir] Waiting for CiliumEndpoint for pod cilium-test-1/echo-same-node-...
🏃[cilium-test-1] Running 87 tests ...
[=] [cilium-test-1] Test [no-policies] [1/87]
.........................
[=] [cilium-test-1] Test [no-policies-from-outside] [2/87]
....
[=] [cilium-test-1] Test [allow-all-except-world] [4/87]
..........
[=] [cilium-test-1] Test [client-ingress] [5/87]
..
[=] [cilium-test-1] Test [echo-ingress] [8/87]
....
[=] [cilium-test-1] Test [dns-only] [21/87]
........
[=] [cilium-test-1] Test [to-fqdns] [22/87]
......
✅ [cilium-test-1] All 87 tests (412 actions) successful, 19 tests skipped, 0 scenarios skipped.
```

Los tests salteados son informativos: `19 tests skipped` normalmente significa que las suites de cifrado, Cluster Mesh, Ingress y egress-gateway se saltearon porque esas features están deshabilitadas. Ejecutá con filtros al estilo `--test '!pod-to-pod-encryption'` para acotar el alcance, y `--flow-validation=disabled` en clústeres con la agregación del monitor configurada alta.

### 9.4 Nivel 3 — observar los flujos

```
$ cilium hubble port-forward &
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 65,532/65,532 (100.00%)
Flows/s: 167.44
Connected Nodes: 4/4

$ hubble observe --namespace default --follow
Sep  1 12:04:11.219: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) -> kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) to-endpoint FORWARDED (UDP)
Sep  1 12:04:11.220: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) -> kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) dns-request proxy FORWARDED (DNS Query deathstar.default.svc.cluster.local. A)
Sep  1 12:04:11.221: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) <- kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) dns-response proxy FORWARDED (DNS Answer "10.96.184.22" TTL: 30)
Sep  1 12:04:11.223: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) -> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:04:11.224: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) -> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
Sep  1 12:04:11.229: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) <- default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) http-response FORWARDED (HTTP/1.1 200 6ms (POST http://deathstar.default.svc.cluster.local/v1/request-landing))
```

Fijate en los números de identidad en cada línea — Hubble reporta la *identidad*, no solo el nombre. Eso es lo que hace inequívoca la atribución de drops.

Tráfico denegado:

```
$ hubble observe --verdict DROPPED --last 5
Sep  1 12:07:02.110: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:07:02.110: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:07:03.145: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) Policy denied DROPPED (TCP Flags: SYN)
```

El par `policy-verdict:none INGRESS DENIED` + `Policy denied DROPPED` te dice: (a) la aplicación ocurrió en **ingress**, (b) en el endpoint de **destino**, (c) **ninguna** regla coincidió (`:none`; contrastá con `policy-verdict:L3-Only ALLOWED`).

---

## 10. Diagnóstico de fallos: un runbook operativo

### 10.1 Síntoma → comando → causa

| Síntoma | Primer comando | Causas probables |
|---|---|---|
| Nodos `NotReady`, `container runtime network not ready` | `kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=100` | Configuración de CNI no escrita; agente en crash-loop; `k8sServiceHost` ausente sin kube-proxy |
| `cilium-agent` en CrashLoopBackOff, `Unable to mount BPF filesystem` | `mount \| grep bpf` en el nodo | `/sys/fs/bpf` sin montar; el init container debería hacerlo — revisá los montajes `hostPath` y la política de seguridad del nodo |
| El agente loguea errores del verificador, endpoints trabados en `regenerating` | `kubectl -n kube-system logs ds/cilium -c cilium-agent \| grep -A40 "Verifier analysis"` | Kernel demasiado viejo para una feature solicitada; deshabilitá la feature o actualizá |
| Los Pods obtienen IPs pero no hay conectividad entre nodos | `cilium-dbg bpf ipcache list` en ambos nodos; `cilium-dbg status \| grep Routing` | Routing nativo sin rutas en el underlay; `autoDirectNodeRoutes` sobre un underlay ruteado (no L2); firewall bloqueando UDP/8472 |
| Handshake OK, las transferencias grandes se cuelgan | `cilium-dbg status \| grep MTU`; `ping -M do -s 1422` | Desajuste de MTU después de habilitar túnel o cifrado |
| Latencia DNS aleatoria de 5 s | `hubble observe --protocol dns --verdict DROPPED` | Presión sobre conntrack, o backlog del proxy DNS; revisá la ocupación de `cilium_ct_any4_global` |
| Los services resuelven pero las conexiones son rechazadas | `cilium-dbg service list \| grep <clusterIP>` | Entrada maestra de service con cero backends → EndpointSlice no lista |
| `kubectl exec/logs` roto pero el networking de Pods bien | `cilium-dbg bpf ipcache list \| grep <nodeIP>` | Falta la entrada `reserved:host`/`remote-node`; restos de kube-proxy; host firewall mal configurado |
| La política no se aplica en absoluto | `cilium-dbg endpoint list` (columnas ENFORCEMENT) | La política no selecciona nada (typo en un label); `policyAuditMode: true`; `policyEnforcementMode: never` |
| Política sobre-aplicada después de instalar | `cilium-dbg policy get` | Un default-deny a nivel clúster que te olvidaste; egress DNS no permitido |
| Los Pods nuevos no arrancan, `failed to allocate IP` | `kubectl get ciliumnode <node> -o yaml` | CIDR de pods del nodo agotado; ampliá el alcance de `clusterPoolIPv4MaskSize` o agregá CIDRs |
| Drops intermitentes bajo carga | `cilium-dbg bpf ct list global \| wc -l`; `cilium-dbg map get cilium_ct4_global` | Mapas CT/NAT al límite → desalojo LRU de flujos vivos. Subí `bpf.ctTcpMax`/`bpf.natMax` |
| `Policy map is full` en los logs | `cilium-dbg map get cilium_policy_v2_<id>` | >16384 entradas de política en un endpoint, normalmente por un conjunto `toCIDR` enorme — usá `CiliumCIDRGroup` o agregá prefijos |

### 10.2 Leer los drops directamente desde el datapath

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --type policy-verdict
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
Policy verdict log: flow 0x1f3ac2b1 local EP ID 1420, remote ID 41022, proto 6, ingress true, action deny, auth: disabled, match none, 10.244.3.55:38104 -> 10.244.1.201:8080 tcp SYN
xx drop (Policy denied) flow 0x1f3ac2b1 to endpoint 1420, ifindex 24, file bpf_lxc.c:2145, , identity 41022->35109: 10.244.3.55:38104 -> 10.244.1.201:8080 tcp SYN
```

El campo `file bpf_lxc.c:2145` no es decoración — es la ubicación exacta en el código fuente del datapath que descartó el paquete, lo que distingue "política denegada en el endpoint de destino" de "política denegada en el egress del origen".

Contadores agregados:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf metrics list
REASON                           DIRECTION   PACKETS   BYTES
Policy denied                    INGRESS     1247      74820
Success                          EGRESS      8829143   1204987222
Success                          INGRESS     8814002   994201338
Stale or unroutable IP           EGRESS      12        720
Unsupported L3 protocol          INGRESS     3         198
CT: Map insertion failed         EGRESS      0         0
Service backend not found        EGRESS      41        2460
```

**Razones de drop que tenés que saber interpretar:**

| Razón | Significado | Causa raíz típica |
|---|---|---|
| `Policy denied` | La búsqueda en el mapa de política no devolvió ninguna entrada de allow | CNP faltante/incorrecta; la identidad no es la que suponías |
| `Stale or unroutable IP` | La ipcache no tiene entrada, o el tunnel endpoint es desconocido | Nodo recién incorporado; ipcache aún no propagada; endpoint eliminado |
| `Service backend not found` | El mapa de LB tiene un frontend pero el slot de backend seleccionado está vacío | Rotación de EndpointSlice; backend en `terminating` |
| `CT: Map insertion failed` | Mapa de conntrack lleno | `ctTcpMax`/`ctAnyMax` subdimensionados para la tasa de conexiones |
| `Unsupported protocol for NAT masquerade` | El camino de masquerade vio un protocolo que no puede reescribir | Egress SCTP/GRE/ESP hacia internet |
| `No mapping for NAT masquerade` | Falló la búsqueda de NAT inverso | Desalojo del mapa de NAT bajo presión |
| `Missed tail call` | Un slot de tail-call no estaba poblado | Carrera al recargar el datapath; normalmente transitorio al arrancar el agente |
| `Authentication required` | Política de autenticación mutua en efecto, identidad aún no autenticada | Handshake de autenticación SPIFFE/mTLS pendiente |
| `VXLAN traffic disallowed` | Paquete de túnel desde un origen inesperado | Nodo no presente en la ipcache como `remote-node`; guardia anti-spoofing |

### 10.3 Confirmar que los programas eBPF están realmente enganchados

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool net show
xdp:

tc:
eth0(2) tcx/ingress cil_from_netdev prog_id 1842
eth0(2) tcx/egress cil_to_netdev prog_id 1847
cilium_host(4) tcx/ingress cil_to_host prog_id 1855
cilium_host(4) tcx/egress cil_from_host prog_id 1861
cilium_net(3) tcx/ingress cil_to_host prog_id 1866
lxc9f21c4a3b70e(24) tcx/ingress cil_from_container prog_id 1902
lxc9f21c4a3b70e(24) tcx/egress cil_to_container prog_id 1907

flow_dissector:

netfilter:

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool cgroup show /run/cilium/cgroupv2
ID     AttachType      AttachFlags     Name
1783   cgroup_inet4_connect               cil_sock4_connect
1785   cgroup_inet4_post_bind             cil_sock4_post_bind
1787   cgroup_inet4_getpeername           cil_sock4_getpeername
1789   cgroup_udp4_sendmsg                cil_sock4_sendmsg
1791   cgroup_udp4_recvmsg                cil_sock4_recvmsg

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool map show | head -20
12: lpm_trie  name cilium_ipcache  flags 0x1
        key 20B  value 16B  max_entries 512000  memlock 40960000B
14: hash  name cilium_lxc  flags 0x0
        key 20B  value 48B  max_entries 65535  memlock 7864320B
19: lru_hash  name cilium_ct4_global  flags 0x0
        key 20B  value 56B  max_entries 295807  memlock 30474240B
23: hash  name cilium_lb4_services_v2  flags 0x1
        key 12B  value 20B  max_entries 65536  memlock 5242880B
27: hash  name cilium_lb4_backends_v3  flags 0x1
        key 4B  value 16B  max_entries 65536  memlock 2621440B
31: perf_event_array  name cilium_events  flags 0x0
        key 4B  value 4B  max_entries 8
```

`tcx/ingress` (en lugar de los filtros más viejos del qdisc `clsact`) indica el modo de enganche **TCX**, disponible en kernel ≥ 6.6, que le da a Cilium un enganche estable y ordenado que otros usuarios de tc no pueden desplazar silenciosamente. En kernels más viejos vas a ver `clsact/ingress` y deberías revisar `tc filter show dev eth0 ingress` en busca de programas que compitan.

### 10.4 La malla de health propia de Cilium

Cilium corre un endpoint `reserved:health` por nodo y sondea continuamente el endpoint de health de cada otro nodo, tanto por la IP del nodo como por el camino de la red de pods:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg-health status
Probe time:   2026-09-01T12:09:12Z
Nodes:
  leloir/worker-01 (localhost):
    Host connectivity to 10.0.1.11:
      ICMP to stack:   OK, RTT=201.44µs
      HTTP to agent:   OK, RTT=142.77µs
    Endpoint connectivity to 10.244.1.9:
      ICMP to stack:   OK, RTT=188.02µs
      HTTP to agent:   OK, RTT=317.19µs
  leloir/worker-03:
    Host connectivity to 10.0.1.13:
      ICMP to stack:   OK, RTT=1.221ms
      HTTP to agent:   OK, RTT=1.884ms
    Endpoint connectivity to 10.244.3.9:
      ICMP to stack:   Connection timed out
      HTTP to agent:   Connection timed out
```

Esta salida es una bisección precisa: **conectividad de host OK pero conectividad de endpoint fallando** significa que el underlay está bien y que el camino de la *red de pods* hacia ese nodo está roto — MTU, puerto de túnel bloqueado, ruta faltante o entrada faltante en la ipcache. Si el host también falla, es el underlay mismo.

### 10.5 Cuándo necesitás escalar el caso

```
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M%S)
🔍 Collecting Kubernetes nodes
🔍 Collecting Kubernetes events
🔍 Collecting Kubernetes namespaces
🔍 Collecting Cilium network policies
🔍 Collecting Cilium endpoints
🔍 Collecting Cilium identities
🔍 Collecting Cilium BPF maps
🔍 Collecting cilium-bugtool output from Cilium pods
🔍 Collecting logs from Cilium pods
🔍 Collecting gops stats from Cilium pods
⚠️  The sysdump may contain sensitive information (e.g. Kubernetes secrets are NOT collected)
✅ Collected sysdump at "cilium-sysdump-20260901-121455.zip"
```

`cilium sysdump` es el único artefacto que hay que adjuntar a un reporte de bug o a un caso de soporte: contiene cada comando de esta sección, para cada nodo, en un mismo punto en el tiempo. Recolectalo **antes** de reiniciar nada — reiniciar el agente regenera los mapas y destruye la evidencia.

---

## 11. Vista consolidada de compromisos

### 11.1 Cilium vs. otros CNIs (arquitectónico, no de marketing)

| Dimensión | Flannel | Calico (iptables/eBPF) | Cilium |
|---|---|---|---|
| Datapath | VXLAN/host-gw, routing del kernel | iptables/ipsets, o modo eBPF | eBPF (tc/XDP/cgroup) |
| Identidad para política | ninguna (sin política) | conjuntos de IPs derivados de selectores de labels | **identidad de seguridad numérica**, derivada de labels |
| Capas de política | — | L3/L4 (+ L7 limitado vía Envoy sin sidecar en Calico Cloud) | L3/L4 **y L7 nativo** (HTTP, gRPC, Kafka, DNS) vía Envoy embebido |
| Reemplazo de kube-proxy | no | sí (modo eBPF) | sí, incluyendo socket LB + Maglev + DSR |
| Observabilidad | ninguna | logs de flujos (Enterprise) | **Hubble** — flujos conscientes de identidad, L7, métricas, mapa de services, todo OSS |
| Multi-clúster | no | limitado | Cluster Mesh con services globales e identidades a nivel malla |
| Cifrado transparente | no | WireGuard | WireGuard e IPsec, más nodo a nodo |
| Egress gateway | no | Enterprise | OSS |
| L2/BGP | host-gw | BGP (BIRD/GoBGP) | Plano de control BGP, anuncios L2, LB-IPAM |
| Piso de kernel | bajo | bajo (más alto para el modo eBPF) | **más alto** — requisitos reales de 5.4+/5.10+ |
| Complejidad operativa | muy baja | media | **alta** — el precio de la superficie de features |

Sé honesto sobre la última fila en una entrevista o en una revisión de diseño: los modos de fallo de Cilium exigen alfabetización a nivel kernel. Ese es el canje.

### 11.2 Matriz de feature a kernel

| Capacidad | Kernel mínimo |
|---|---:|
| Cilium base (releases recientes) | 5.4 |
| Socket LB (hooks `connect`/`sendmsg`) | 4.19 (5.7 para `getpeername` completo) |
| BPF host routing (`bpf_redirect_peer`) | 5.10 |
| Masquerading eBPF | 5.4 |
| Cifrado transparente WireGuard | 5.6 |
| Bandwidth Manager (EDT + `fq`) | 5.1 (BBR necesita 5.18) |
| Egress Gateway | 5.10 |
| IPv6 BIG TCP | 5.19 |
| IPv4 BIG TCP | 6.3 |
| Modo de enganche TCX | 6.6 |
| Modo de dispositivo netkit | 6.8 |

Confirmá siempre contra la página de *System Requirements* del propio release en vez de fiarte de la memoria — estos pisos se mueven entre versiones menores.

### 11.3 Doce hechos que vale la pena memorizar para el examen

1. La identidad viene de los **labels filtrados**, no de las IPs; conjuntos de labels idénticos comparten una identidad.
2. Identidades reservadas: `1 host`, `2 world`, `4 health`, `6 remote-node`, `7 kube-apiserver`.
3. Identidades globales del clúster: **256–65535**. Las identidades CIDR/FQDN son **locales al nodo**, ≥ `1<<24`.
4. La **ipcache** (trie LPM) mapea IP/CIDR → identidad + tunnel endpoint, y es lo que permite que el nodo *de origen* aplique la política de egress.
5. La política de egress se aplica en el nodo de origen; la de ingress, en el nodo de destino.
6. `cilium-agent` no está en el datapath; los mapas eBPF sí. Agente caído ≠ tráfico caído.
7. `cilium` (CLI del host) ≠ `cilium-dbg` (CLI dentro del pod).
8. El modo de routing por defecto es **tunnel/VXLAN**; `native` requiere que el underlay enrute los CIDRs de pods.
9. VXLAN/Geneve cuestan **50 bytes** de MTU; WireGuard agrega **80** más.
10. El socket LB traduce la ClusterIP en `connect()` — el tráfico este-oeste de services no tiene **NAT por paquete** ni entrada de conntrack de service.
11. `kubeProxyReplacement: true` requiere `k8sServiceHost`/`k8sServicePort` cuando kube-proxy no está presente.
12. La aplicación de política es por endpoint **y por dirección**, y se activa para una dirección solo cuando una regla selecciona ese endpoint en esa dirección.

---

## 12. Referencias

**CNCF / certificación**
- Currículum CCA (fuente de referencia para dominios y pesos): https://github.com/cncf/curriculum/blob/master/cca/README.md
- Repositorio de currículos de la CNCF: https://github.com/cncf/curriculum
- Página del programa Cilium Certified Associate: https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Documentación oficial de Cilium**
- Raíz de la documentación: https://docs.cilium.io/en/stable/
- Vista general de componentes / arquitectura: https://docs.cilium.io/en/stable/overview/component-overview/
- Introducción y casos de uso: https://docs.cilium.io/en/stable/overview/intro/
- Internals del datapath eBPF: https://docs.cilium.io/en/stable/reference-guides/bpf/
- La vida de un paquete: https://docs.cilium.io/en/stable/reference-guides/bpf/progtypes/
- Modelo de identidad de seguridad: https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Ciclo de vida del endpoint: https://docs.cilium.io/en/stable/reference-guides/bpf/architecture/
- Modos de routing (encapsulación / nativo): https://docs.cilium.io/en/stable/network/concepts/routing/
- Conceptos y modos de IPAM: https://docs.cilium.io/en/stable/network/concepts/ipam/
- Reemplazo de kube-proxy: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Masquerading: https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Configuración de MTU: https://docs.cilium.io/en/stable/network/mtu/
- Requisitos del sistema (versiones de kernel): https://docs.cilium.io/en/stable/operations/system_requirements/
- Referencia de Helm (todos los valores): https://docs.cilium.io/en/stable/helm-reference/
- Instalación con Helm: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Instalación con la CLI de Cilium: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
- Instalación rápida en Kind: https://docs.cilium.io/en/stable/installation/kind/
- Guía de troubleshooting: https://docs.cilium.io/en/stable/operations/troubleshooting/
- Hoja de referencia de comandos: https://docs.cilium.io/en/stable/cheatsheet/
- Referencia de comandos de `cilium-dbg`: https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Custom Resource Definitions: https://docs.cilium.io/en/stable/network/kubernetes/ciliumendpoint/
- Conceptos de network policy: https://docs.cilium.io/en/stable/security/policy/
- Hubble (instalación y uso): https://docs.cilium.io/en/stable/observability/hubble/
- Guía de tuning de rendimiento: https://docs.cilium.io/en/stable/operations/performance/tuning/
- Conceptos de Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/

**Código fuente y proyectos upstream**
- Fuente de Cilium (datapath bajo `bpf/`): https://github.com/cilium/cilium
- CLI de Cilium: https://github.com/cilium/cilium-cli
- Hubble: https://github.com/cilium/hubble
- Sitio y documentación del proyecto eBPF: https://ebpf.io/
- Documentación de BPF del kernel: https://docs.kernel.org/bpf/
- Documentación de `bpftool`: https://docs.kernel.org/bpf/bpftool.html

**Kubernetes**
- Modelo de networking del clúster: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service `ClusterIP`/`NodePort`/`LoadBalancer`: https://kubernetes.io/docs/concepts/services-networking/service/
- NetworkPolicy: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Referencia de `kube-proxy`: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Especificación de CNI: https://github.com/containernetworking/cni/blob/main/SPEC.md