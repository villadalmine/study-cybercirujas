# 2.1 Arquitectura y Componentes de Cilium

**Peso del dominio: 20%** — es el bloque más pesado de toda la CCA. Casi todos los demás dominios (policy, service mesh, ClusterMesh, observabilidad, troubleshooting) son una *consecuencia* de la arquitectura que se describe acá. Si podés dibujar el grafo de componentes, nombrar los mapas eBPF que hay detrás de cada funcionalidad y explicar qué se rompe cuando cada proceso muere, el resto del examen pasa a ser deducción en vez de memorización.

---

## 1. El problema de producción que Cilium existe para resolver

### 1.1 La crisis de identidad de la dirección IP

El networking de Kubernetes heredó una suposición de los años 90: **una dirección IP identifica a una carga de trabajo**. `NetworkPolicy`, `iptables`, security groups, firewalls y logs de auditoría codifican todos esta suposición. En un clúster donde un Deployment rota cada 40 segundos, la suposición es falsa de una manera que no es simplemente incómoda — es un problema de *corrección*:

* El Pod `10.244.3.17` es `payments-api` a las 14:02:11 y `crypto-miner-debug-shell` a las 14:02:19.
* Una regla de `iptables` que referencia `10.244.3.17` es una **condición de carrera con consecuencia de seguridad**. La ventana entre el borrado del pod, la reutilización de la IP y la reprogramación de la regla es un hueco real y explotado.
* Entre clústeres y entre nubes, el espacio de IPs se solapa directamente. `10.244.0.0/16` en `eu-prod` y `10.244.0.0/16` en `us-prod` son cargas de trabajo distintas con direcciones idénticas.

La decisión arquitectónica fundacional de Cilium es **desacoplar la política del direccionamiento**: a cada carga de trabajo se le asigna una *identidad de seguridad*, un valor numérico derivado de sus labels, y el datapath aplica la política sobre `(identidad origen, identidad destino, puerto, protocolo, regla L7)`. Las IPs pasan a ser una clave de búsqueda en una tabla de identidades (`ipcache`), no el sujeto de la política.

### 1.2 El muro de escalabilidad de `kube-proxy`

`kube-proxy` en modo `iptables` construye una cadena lineal de reglas por Service y por backend. La evaluación de reglas es **O(n)** en la cantidad de Services y —lo crítico— cada actualización reescribe y recarga atómicamente la tabla entera vía `iptables-restore`.

Números reales de producción en clústeres grandes:

| Services | reglas iptables (aprox.) | latencia de recarga de `iptables-restore` | búsqueda por paquete |
|---|---|---|---|
| 1.000 | ~20.000 | ~250 ms | recorrido de cadena O(n) |
| 5.000 | ~100.000 | ~2–5 s | recorrido de cadena O(n) |
| 20.000 | ~400.000 | 30 s – varios minutos | recorrido de cadena O(n) |

En la parte alta de esa tabla, un único evento de escalado de un Deployment frena la programación de Services en todo el clúster durante minutos. Mientras tanto el datapath eBPF usa una **búsqueda en hash map — O(1)** — y actualiza una *sola entrada de mapa* ante el cambio de un solo backend, sin recarga global y sin lock.

### 1.3 El impuesto del sidecar

El modelo clásico de service mesh inyecta un sidecar Envoy por pod. Cada request procesado en L7 atraviesa el stack de red **cuatro veces adicionales** (pod → loopback del sidecar, sidecar → host, host → sidecar, sidecar → pod), a costa de latencia, ~50–100 MiB de RSS por pod, y una carga operativa de webhooks de inyección y carreras de ciclo de vida (`istio-proxy` sobreviviendo al contenedor de la aplicación, deadlocks de orden de init).

La respuesta de Cilium es **un Envoy por nodo**, alcanzado mediante redirección de sockets con eBPF en vez de `REDIRECT` de iptables, y sólo para el tráfico que realmente necesita semántica L7. Todo lo demás se queda en el kernel.

### 1.4 El agujero negro de observabilidad

`tcpdump` en un nodo cargado es, en el mejor caso, una herramienta de muestreo, y en el peor un incidente de producción. Los flow logs de un CNI que sólo ve IPs no pueden responder *"qué servicio llamó a qué servicio"*. Cilium emite eventos desde el propio datapath, ya anotados con identidad de origen, identidad de destino, veredicto, motivo de descarte y (para L7) método/path HTTP o consulta DNS — porque el punto de aplicación y el punto de observación son el mismo programa eBPF.

> **Tesis arquitectónica para recordar en el examen:** Cilium mueve conectividad, seguridad y observabilidad a un *único* datapath de kernel programable, indexado por *identidad*, programado por un *agente por nodo*, y coordinado por CRDs en el API server de Kubernetes.

---

## 2. eBPF: el sustrato, con la profundidad que el examen espera

eBPF es una máquina virtual sandboxeada dentro del kernel de Linux. Los programas son:

1. **Escritos** en C restringido, compilados por LLVM/clang a bytecode eBPF.
2. **Verificados** en tiempo de carga — el verificador prueba la terminación (bucles acotados), la seguridad de memoria (cada dereferencia de puntero tiene chequeo de rango) y la corrección de privilegios. Un programa que no puede probarse seguro es *rechazado*; no puede provocar un panic del kernel.
3. **Compilados JIT** a código máquina nativo, así que corren a velocidad casi nativa.
4. **Enganchados** a un hook, donde se ejecutan ante cada evento en ese hook.
5. **Con estado** mediante *mapas* — estructuras de datos del kernel compartidas entre programas eBPF y el espacio de usuario.

### 2.1 Puntos de enganche usados por el datapath de Cilium

| Hook | Punto de enganche en el kernel | Objeto de Cilium | Qué corre ahí |
|---|---|---|---|
| **XDP** | driver de la NIC, antes del `sk_buff` | `bpf_xdp.o` | Aceleración de NodePort/LB, descartes de DDoS, búsquedas `cilium_lb4_*` a line rate |
| **tc ingress/egress** (qdisc `clsact`) | Después de la asignación del `sk_buff` | `bpf_lxc.o` | Aplicación de política por endpoint, resolución de identidad, CT, redirección L7 |
| **tc en dispositivo de host** | NIC física/bond | `bpf_host.o`, `bpf_netdev.o` | Host firewall, NodePort, masquerading, direccionamiento de cifrado |
| **tc en dispositivo de túnel** | `cilium_vxlan` / `cilium_geneve` | `bpf_overlay.o` | Desencapsulado, extracción de identidad desde los metadatos del túnel |
| **cgroup v2 socket ops** | `connect()`, `sendmsg()`, `recvmsg()`, `getpeername()` | `bpf_sock.o` | **Balanceo de carga basado en sockets** — VIP del Service → backend traducido *antes de que exista un paquete* |
| **sockmap / sockops** | Establecimiento de socket TCP | `bpf_sockops.o` | Reenvío a nivel de socket en el mismo nodo (evita por completo el stack TCP/IP) |
| **tracing / kprobes** | Funciones del kernel | helpers del monitor | Motivos de descarte, notificaciones de traza |

La consecuencia del **hook connect de cgroup** es el dato más relevante para el examen sobre el datapath: con el reemplazo de `kube-proxy` habilitado, un pod que se conecta a `10.96.0.1:443` nunca envía un paquete a `10.96.0.1`. El propio `connect()` reescribe el destino a la IP de un pod backend. **No hay DNAT en el camino del paquete, no hay entrada de conntrack para la VIP, y no hay costo de traducción inversa**.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -A6 'KubeProxyReplacement'
KubeProxyReplacement:    True   [eth0   10.0.1.11 fe80::5054:ff:fe12:3456 (Direct Routing)]
  Protocols:             TCP, UDP
  Devices:               eth0   10.0.1.11 fe80::5054:ff:fe12:3456 (Direct Routing)
  Mode:                  SNAT
  Backend Selection:     Random
  Session Affinity:      Enabled
  Graceful Termination:  Enabled
  NAT46/64 Support:      Disabled
  XDP Acceleration:      Native
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

### 2.2 Los mapas eBPF que tenés que saber nombrar

Los mapas *son* el estado del datapath. Cada funcionalidad de Cilium es "un mapa más un programa que lo lee".

| Mapa | Tipo | Alcance | Propósito | Se inspecciona con |
|---|---|---|---|---|
| `cilium_lxc` | hash | nodo | Índice de endpoints (pods): IP → endpoint ID, identidad, MAC, ifindex | `cilium-dbg bpf endpoint list` |
| `cilium_ipcache` | LPM trie | nodo | **IP/CIDR → identidad de seguridad + endpoint del túnel** — la tabla de resolución de identidad | `cilium-dbg bpf ipcache list` |
| `cilium_policy_v2_<epID>` | hash | endpoint | Tuplas `(identidad, puerto, proto, dirección)` permitidas para un endpoint | `cilium-dbg bpf policy get <epID>` |
| `cilium_ct4_global` / `cilium_ct6_global` | LRU hash | nodo | Connection tracking (TCP), también guarda el veredicto de política del flujo | `cilium-dbg bpf ct list global` |
| `cilium_ct_any4_global` | LRU hash | nodo | Conntrack no-TCP (UDP, ICMP) | `cilium-dbg bpf ct list global` |
| `cilium_lb4_services_v2` | hash | nodo | Frontend del Service (VIP:puerto) → cantidad de slots de backend + flags | `cilium-dbg bpf lb list` |
| `cilium_lb4_backends_v3` | hash | nodo | ID de backend → IP:puerto del pod, estado (active/terminating/quarantined) | `cilium-dbg bpf lb list --backends` |
| `cilium_lb4_reverse_nat` | hash | nodo | Traducción inversa para respuestas de NodePort en modo SNAT | `cilium-dbg bpf lb list --revnat` |
| `cilium_lb4_affinity` | LRU hash | nodo | Estado de `sessionAffinity: ClientIP` | — |
| `cilium_lb4_maglev` | hash de arrays | nodo | Tablas de backends con hash consistente Maglev | `cilium-dbg bpf lb maglev list` |
| `cilium_snat_v4_external` | LRU hash | nodo | Tabla NAT del masquerading eBPF | `cilium-dbg bpf nat list` |
| `cilium_tunnel_map` | hash | nodo | CIDR / IP de pod remoto → IP del nodo remoto (endpoint VXLAN/Geneve) | `cilium-dbg bpf tunnel list` |
| `cilium_node_map` | hash | nodo | ID de nodo ↔ IP de nodo (usado por cifrado, egress gateway) | `cilium-dbg bpf nodeid list` |
| `cilium_events` | perf ring buffer | nodo | Canal de eventos datapath → espacio de usuario que alimenta **Hubble** y `cilium-dbg monitor` | `cilium-dbg monitor` |
| `cilium_metrics` | hash por CPU | nodo | Contadores del datapath (descartes por motivo, reenvíos) | `cilium-dbg bpf metrics list` |
| `cilium_egress_gw_policy_v4` | LPM trie | nodo | Egress gateway: `(src, dstCIDR)` → gateway + IP de egreso | `cilium-dbg bpf egress list` |
| `cilium_ipmasq_v4` | LPM trie | nodo | CIDRs sin masquerade estilo ip-masq-agent | `cilium-dbg bpf ipmasq list` |
| `cilium_auth_map` | hash | nodo | Estado de autenticación mutua (SPIFFE) para `authentication.mode: required` | `cilium-dbg bpf auth list` |
| `cilium_l2_responder_v4` | hash | nodo | Anuncios L2 (respuestas ARP para IPs de LB) | `cilium-dbg bpf l2responder list` |
| `cilium_call_policy` | prog array | nodo | **Mapa de tail-call** — cómo `bpf_host.o` salta a un programa de política por endpoint | — |

Los mapas viven en el montaje **bpffs** en `/sys/fs/bpf/tc/globals/`. Ésta es la razón por la que `cilium-agent` monta bpffs desde el host y *no* desde un `emptyDir`: el tiempo de vida del mapa debe exceder al del agente, para que **un reinicio del agente no corte tráfico**.

```
$ sudo ls /sys/fs/bpf/tc/globals/ | head -20
cilium_auth_map
cilium_call_policy
cilium_calls_00341
cilium_calls_hostns_01245
cilium_capture_cache
cilium_ct4_global
cilium_ct_any4_global
cilium_events
cilium_ipcache_v2
cilium_ipv4_frag_datagrams
cilium_lb4_affinity
cilium_lb4_backends_v3
cilium_lb4_reverse_nat
cilium_lb4_reverse_sk
cilium_lb4_services_v2
cilium_lb_affinity_match
cilium_lxc
cilium_metrics
cilium_node_map
cilium_nodeport_neigh4
```

---

## 3. El inventario de componentes

Ésta es la tabla que hay que poder reproducir de memoria.

| Componente | Objeto de Kubernetes | Cardinalidad | Plano | Dependencia dura | Radio de impacto si cae |
|---|---|---|---|---|---|
| **cilium-agent** | DaemonSet `cilium` | 1 por nodo | Control + programación del datapath | kube-apiserver (o kvstore) | **El tráfico existente sigue fluyendo** (eBPF está en el kernel). Ningún pod *nuevo* puede obtener red en ese nodo; las actualizaciones de política y de Services se frenan para ese nodo; los flujos de Hubble se detienen |
| **cilium-cni** | binario `/opt/cni/bin/cilium-cni` | 1 por nodo | Configuración del datapath | socket unix de cilium-agent | Falla la creación del sandbox del pod en ese nodo → `ContainerCreating` |
| **cilium-operator** | Deployment (2 réplicas, HA vía Lease) | 1–2 por clúster | Control | kube-apiserver | Se detiene la asignación IPAM de PodCIDR (los *nodos* nuevos no obtienen CIDRs), se detiene el GC de identidades, se detiene la sincronización de CiliumEndpointSlice, se detiene LB-IPAM, se detiene la reconciliación de Ingress/Gateway. **El tráfico existente no se ve afectado** |
| **cilium-envoy** | DaemonSet `cilium-envoy` | 1 por nodo | Datapath L7 | socket xDS de cilium-agent | Falla el tráfico de política L7 / Ingress / Gateway API / mesh L7. L3/L4 no se ve afectado |
| **hubble** (embebido) | dentro de cilium-agent | 1 por nodo | Observabilidad | mapa `cilium_events` | Se pierde la visibilidad de flujos local al nodo |
| **hubble-relay** | Deployment | 1+ por clúster | Observabilidad | servicio hubble peer en cada agente | Falla `hubble observe` a nivel clúster; por nodo sigue funcionando vía `cilium-dbg monitor` |
| **hubble-ui** | Deployment | 1 por clúster | Observabilidad | hubble-relay | Sólo cae la UI web |
| **clustermesh-apiserver** | Deployment (contenedores etcd + apiserver) | 1+ por *clúster* en la malla | Control (multiclúster) | kube-apiserver local | Los clústeres remotos dejan de recibir actualizaciones de estado; los endpoints remotos **cacheados** siguen funcionando hasta quedar obsoletos |
| **cilium-cli** (`cilium`) | binario fuera del clúster | laptop del operador / CI | Herramientas | kubeconfig | Nada; es un cliente |

### 3.1 El diagrama de arquitectura para memorizar

```
                     ┌──────────────────────────────────────────────┐
                     │            kube-apiserver (CRDs)             │
                     │  CiliumNetworkPolicy  CiliumEndpoint         │
                     │  CiliumIdentity       CiliumNode             │
                     │  CiliumEndpointSlice  CiliumLBIPPool ...     │
                     └───────┬──────────────────────────┬───────────┘
                             │ watch/update             │ watch/update
                             │                          │
             ┌───────────────┴─────────┐      ┌─────────┴──────────────┐
             │     cilium-operator     │      │  clustermesh-apiserver │
             │  · cluster-pool IPAM    │      │  · etcd (2379, mTLS)   │
             │  · identity GC          │      │  · exports identities, │
             │  · CES controller       │      │    endpoints, services │
             │  · LB-IPAM / BGP        │      └─────────┬──────────────┘
             │  · Ingress / GW API     │                │
             │  · CiliumEndpoint GC    │                │ remote watch
             └─────────────────────────┘                │
                                                        │
 ══════════════════════════ per node ═══════════════════│══════════════════
                                                        │
   ┌────────────────────────────────────────────────────┴─────────────────┐
   │  cilium-agent (DaemonSet, hostNetwork, privileged/CAP_*)             │
   │                                                                      │
   │  k8s watchers → StateDB/Hive cells → Endpoint Manager                │
   │        │                                  │                          │
   │        ├─► Identity Allocator ────────────┤                          │
   │        ├─► Policy Repository ─► Policy Calculation ─► SelectorCache  │
   │        ├─► IPCache / Node Discovery                                  │
   │        ├─► Service/LB Manager                                        │
   │        ├─► IPAM                                                      │
   │        ├─► DNS Proxy (ToFQDN)                                        │
   │        ├─► Hubble Observer  ──► gRPC :4244 ──► hubble-relay :4245    │
   │        └─► Datapath Loader (clang → tc/XDP/cgroup)                   │
   │                       │                                              │
   │       xDS over unix socket │  /var/run/cilium/envoy/sockets/xds.sock │
   └───────────────────────┼──────────────────────┼──────────────────────┘
                           │                      │
              ┌────────────┴─────────┐            │ writes
              │  cilium-envoy (DS)   │            ▼
              │  L7 HTTP/gRPC/Kafka  │   ┌────────────────────────────────┐
              │  Ingress / GW API    │   │  eBPF maps  /sys/fs/bpf/tc/... │
              └──────────────────────┘   │  + programs on XDP/tc/cgroup   │
                                         └────────────────────────────────┘
                                                    ▲
              ┌──────────────┐   CNI ADD/DEL        │ writes cilium_lxc
              │  containerd  ├──► /opt/cni/bin/cilium-cni ──► agent unix sock
              └──────────────┘
```

---

## 4. Internals de `cilium-agent`

El agente es un binario Go construido sobre **Hive**, un framework de inyección de dependencias que organiza al agente en *cells* (módulos con ciclos de vida explícitos). Las versiones recientes exponen el estado en tiempo de ejecución a través de **StateDB**, una base de datos en memoria, transaccional, basada en un radix tree inmutable, con tablas de dispositivos, rutas, direcciones de nodo, salud y más.

### 4.1 Subsistemas

**Watchers de Kubernetes.** Informers sobre `Pod`, `Service`, `EndpointSlice`, `Node`, `Namespace`, `NetworkPolicy` y cada CRD de Cilium. El agente es un *lector* de intención y un *escritor* de estado (`CiliumEndpoint`, `CiliumNode`).

**Endpoint Manager.** Es dueño del ciclo de vida de cada endpoint local. Un *endpoint* es cualquier cosa con una interfaz de red gestionada por Cilium: un pod, el propio host (`reserved:host`), el endpoint de salud y el endpoint de ingress. Cada uno tiene un **endpoint ID** numérico local al nodo y una máquina de estados:

```
waiting-for-identity → waiting-to-regenerate → regenerating → ready
                                     ↑                │
                                     └── disconnected ┘
```

**Identity Allocator.** Convierte un conjunto de labels en una identidad numérica. En modo CRD (por defecto) lo hace creando/reutilizando un objeto `CiliumIdentity`; en modo kvstore, mediante una clave en etcd. La asignación es *global al clúster* — el mismo conjunto de labels produce la misma identidad en todos los nodos, que es lo que hace coherente la aplicación distribuida de políticas.

**Policy Repository + SelectorCache.** Contiene todos los objetos `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy` y `NetworkPolicy` de upstream. Ante cualquier cambio, recalcula qué identidades coinciden con cada selector y produce, por endpoint, un conjunto plano de entradas permitidas `(identidad, puerto, protocolo, redirección L7)`. Sólo se regeneran los endpoints cuya política *efectiva* cambió — esa incrementalidad es la razón por la que un clúster de 5.000 pods no se derrite cuando se edita una política.

**IPCache.** El puente entre direccionamiento e identidad. Cada IP conocida del clúster (pods locales, pods remotos, nodos, CIDRs externos provenientes de políticas, IPs resueltas por FQDN) mapea a una identidad y, en modo túnel, al nodo que la posee. Se escribe en el LPM trie `cilium_ipcache`.

**Datapath Loader.** Genera cabeceras C por endpoint (`ep_config.h`), compila con clang (usando un **cache de plantillas** para que configuraciones idénticas reutilicen un objeto precompilado) y engancha vía `tc`/`bpf` netlink. Los archivos objeto y las cabeceras por endpoint viven bajo `/var/run/cilium/state/<endpointID>/`.

**Proxies.** El **proxy DNS** está *en proceso dentro del agente* (no en Envoy) — intercepta DNS vía tproxy para las reglas `toFQDNs` y puebla el cache de FQDN y el ipcache. **Envoy** maneja la política L7 de HTTP/gRPC/Kafka y el Ingress/Gateway API.

**cilium-health.** Sondea a todos los demás nodos por ICMP y HTTP en el puerto **4240**, tanto de IP-de-nodo a IP-de-nodo como de endpoint-de-salud a endpoint-de-salud (vía el veth `cilium_health`), lo que distingue *alcanzabilidad del nodo* de *alcanzabilidad de la red de pods*.

**Monitor.** Lee el perf ring buffer `cilium_events` y lo distribuye a los clientes de `cilium-dbg monitor` y al observer de Hubble.

### 4.2 El pipeline de regeneración de endpoints

Éste es el flujo interno de mayor valor para el troubleshooting:

```
1. Trigger      : new pod / label change / policy change / identity change
2. Identity     : labels → allocate or resolve numeric identity (CiliumIdentity)
3. Policy calc  : SelectorCache → resolved L4 + L7 policy map entries
4. Header gen   : write ep_config.h into /var/run/cilium/state/<epID>/
5. Compile      : clang → bpf_lxc.o   (template cache hit ⇒ skipped)
6. Load         : tc filter replace on the veth (ingress + egress)
7. Map update   : cilium_policy_v2_<epID>, cilium_lxc, cilium_ipcache
8. State        : endpoint → ready ; CiliumEndpoint status updated
```

La latencia de una regeneración **en frío** (con compilación) es de cientos de milisegundos; una **en caliente** (acierto de plantilla, sólo actualización de mapas) es de milisegundos de un dígito. Por eso el churn de labels en un Deployment grande es barato, pero un cambio de configuración que fuerza recompilación global no lo es.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4          STATUS
           ENFORCEMENT        ENFORCEMENT                                                                                                ENFORCEMENT
164        Enabled            Disabled          46212      k8s:app=payments-api                                            10.244.1.87   ready
                                                           k8s:io.cilium.k8s.policy.cluster=eu-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=payments
                                                           k8s:io.kubernetes.pod.namespace=payments
712        Disabled           Disabled          4          reserved:health                                                 10.244.1.201  ready
1188       Enabled            Enabled           52901      k8s:app=frontend                                                10.244.1.14   ready
                                                           k8s:io.cilium.k8s.policy.cluster=eu-prod
                                                           k8s:io.kubernetes.pod.namespace=shop
2455       Disabled           Disabled          1          reserved:host                                                                 ready
3021       Enabled            Disabled          16777231   reserved:ingress                                                10.244.1.3    ready
```

Leé esa tabla con atención — es una forma favorita en el examen:

* `POLICY ENFORCEMENT` es **por dirección**. `Disabled` significa *ninguna política selecciona este endpoint en esa dirección*, así que todo está permitido (default-allow). **No** significa que el tráfico esté bloqueado.
* Identidad `4` = `reserved:health`, `1` = `reserved:host` — identidades reservadas, no derivadas de labels.
* `16777231` está por encima de `2^24` → una identidad **local al nodo** (ver §6.2).

---

## 5. `cilium-operator`

El operator se ocupa del trabajo que debe suceder **una vez por clúster**, no una vez por nodo. Está deliberadamente **fuera del datapath**: ningún paquete depende de él.

| Responsabilidad | Detalle | Síntoma de falla |
|---|---|---|
| **IPAM cluster-pool** | Recorta `/24`s de `clusterPoolIPv4PodCIDRList` y los escribe en `CiliumNode.spec.ipam.podCIDRs` | Los nodos nuevos quedan `NotReady`, el agente loguea `waiting for IPAM to be initialized` |
| **IPAM de nube (ENI/Azure/AlibabaCloud)** | Habla con la API de la nube para adjuntar ENIs/IPs y preasignar un pool caliente | Pods trabados en `ContainerCreating`, `failed to allocate IP` |
| **Recolección de basura de identidades** | Borra objetos `CiliumIdentity` sin endpoint vivo; basado en heartbeat | Fuga de identidades → hinchazón de etcd/API server, eventual agotamiento de identidades |
| **GC de CiliumEndpoint** | Elimina objetos `CiliumEndpoint` obsoletos de pods muertos | Flujos obsoletos atribuidos a cargas de trabajo muertas |
| **Controlador CiliumEndpointSlice** | Agrupa `CiliumEndpoint` en slices para recortar el tráfico de watch al apiserver a escala | Alta carga del apiserver con más de 5k pods |
| **LB-IPAM** | Asigna IPs de `status.loadBalancer.ingress` desde `CiliumLoadBalancerIPPool` | `Service type=LoadBalancer` queda en `<pending>` |
| **Ingress / Gateway API** | Traduce objetos `Ingress` y de Gateway API a `CiliumEnvoyConfig` | Las rutas de Ingress nunca se programan |
| **Heartbeat del kvstore** | Escribe una clave de heartbeat para que los agentes detecten un kvstore muerto | Los agentes no pueden distinguir un kvstore obsoleto de uno sano |
| **GC de nodos** | Borra `CiliumNode` de nodos eliminados | Quedan túneles y entradas de ipcache hacia nodos muertos |

La HA es **elección de líder activo/pasivo** sobre un `Lease` en `kube-system`:

```
$ kubectl -n kube-system get lease cilium-operator-resource-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
cilium-operator-6c9d4f7b8d-x2r4k

$ kubectl -n kube-system logs deploy/cilium-operator | grep -i leader
level=info msg="Leading the operator HA deployment" subsys=cilium-operator-generic
```

---

## 6. El modelo de identidad

### 6.1 De labels a un número

No todos los labels participan. Por defecto se usan los labels `k8s:` **excepto** un conjunto filtrado (`pod-template-hash`, `controller-revision-hash`, `statefulset.kubernetes.io/pod-name`, anotaciones). Esto es deliberado: incluir `pod-template-hash` acuñaría una identidad nueva en cada rollout, arruinando todo el diseño. El filtro es configurable mediante la clave `labels` del ConfigMap.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity list | head -12
ID         LABELS
1          reserved:host
2          reserved:world
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
46212      k8s:app=payments-api
           k8s:io.cilium.k8s.namespace.labels.env=prod
           k8s:io.cilium.k8s.policy.cluster=eu-prod
           k8s:io.cilium.k8s.policy.serviceaccount=payments
           k8s:io.kubernetes.pod.namespace=payments
```

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity get 46212 -o json | jq '.[0].labels'
[
  "k8s:app=payments-api",
  "k8s:io.cilium.k8s.namespace.labels.env=prod",
  "k8s:io.cilium.k8s.policy.cluster=eu-prod",
  "k8s:io.cilium.k8s.policy.serviceaccount=payments",
  "k8s:io.kubernetes.pod.namespace=payments"
]
```

### 6.2 Rangos numéricos de identidad

| Rango | Clase | Alcance | Ejemplos |
|---|---|---|---|
| `1`–`255` | **Reservadas** | Fijas, independientes del clúster | `host=1`, `world=2`, `health=4`, `init=5`, `remote-node=6`, `kube-apiserver=7`, `ingress=8` |
| `256`–`65535` | **De alcance de clúster** | Globales al clúster; asignadas por la CRD `CiliumIdentity` o el kvstore | Toda identidad de carga de trabajo derivada de labels |
| `≥ 2^24` (16777216) | **Locales al nodo** | Sólo tienen significado en el nodo que las asignó | Identidades de CIDR desde `toCIDR`, IPs derivadas de FQDN, instancias de `reserved:ingress` por nodo |
| `(clusterID << 16) \| localID` | **ClusterMesh** | Shard por clúster | Clúster 3, local 4711 → rango `196_x` |

El desplazamiento de ClusterMesh es la razón por la que el valor por defecto de `max-connected-clusters` es **255** (8 bits de cluster ID, 16 bits de ID local). Subirlo a 511 reparticiona la disposición de bits y es un ajuste **a nivel de clúster, disruptivo y de un solo sentido** — debe elegirse en el momento de la instalación para cada clúster de la malla.

### 6.3 El ipcache: donde la identidad se encuentra con el cable

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf ipcache list | head -14
IP PREFIX/ADDRESS       IDENTITY
0.0.0.0/0               identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.11/32            identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.12/32            identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.13/32            identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.14/32          identity=52901 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.87/32          identity=46212 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.2.0/24           identity=2 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.2.31/32          identity=52901 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.3.0/24           identity=2 encryptkey=0 tunnelendpoint=10.0.1.13 flags=<none>
34.117.59.81/32         identity=16777224 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
172.20.0.0/16           identity=16777221 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
192.168.10.20/32        identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

Dos cosas para extraer:

1. **`tunnelendpoint`** es distinto de cero sólo para prefijos de pods remotos en modo túnel — esa columna *es* la tabla de enrutamiento del overlay.
2. `34.117.59.81/32 → 16777224` es una identidad **derivada de FQDN, local al nodo**: el proxy DNS vio una coincidencia de `toFQDNs`, la resolvió y acuñó una identidad local para que el datapath pueda aplicar política sobre ella.

---

## 7. Modos del datapath y sus compromisos

### 7.1 Modo de enrutamiento

| Dimensión | **Túnel (VXLAN / Geneve)** | **Enrutamiento nativo** |
|---|---|---|
| Requisito del underlay | Ninguno — cualquier alcanzabilidad L3 entre nodos | El underlay **debe** enrutar el CIDR de pods (BGP, rutas de VPC de la nube, o misma L2 con `auto-direct-node-routes`) |
| Costo de MTU | ~50 bytes de overhead → 1450 sobre un underlay de 1500 | Cero |
| Throughput | Menor (encap/decap, a menudo sin offload de NIC para Geneve) | El más alto |
| Propagación de identidad | Transportada **en la cabecera del túnel** (VNI de VXLAN / TLV de Geneve) — gratis | Requiere búsqueda en el ipcache en el nodo receptor, o metadatos de IPsec/WireGuard |
| Integración con LB de nube | Las IPs de pod son invisibles para el LB de la nube | Las IPs de pod son directamente direccionables (AWS ENI, Azure) |
| Depurabilidad | El dispositivo `cilium_vxlan` es un punto de captura limpio | Los paquetes parecen tráfico enrutado común |
| Escalado horizontal de nodos | Trivial | Escalado de tabla de rutas / sesiones BGP |
| Uso típico | On-prem, subredes mixtas, multi-AZ con fronteras L3 | Nube con IPAM nativo de ENI/VPC, racks de una sola L2, fabrics BGP |

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf tunnel list
TUNNEL          VALUE
10.244.2.0:0    10.0.1.12:0
10.244.3.0:0    10.0.1.13:0
10.244.4.0:0    10.0.1.14:0
```

### 7.2 Reemplazo de kube-proxy — comparación del manejo de Services

| | **kube-proxy iptables** | **kube-proxy IPVS** | **eBPF de Cilium** |
|---|---|---|---|
| Complejidad de búsqueda | recorrido de cadena O(n) | hash O(1) | **hash O(1)** |
| Costo de actualización | Recarga completa de la tabla | Operaciones ipvsadm por servicio | **Escritura de una sola entrada de mapa** |
| ClusterIP este-oeste | DNAT en el camino del paquete | DNAT en el camino del paquete | **A nivel de socket (`connect()`), sin DNAT de paquete** |
| Conntrack para ClusterIP | Requerido | Requerido | **No requerido** (socket LB) |
| DSR para NodePort | No | No | **Sí** (`bpf-lb-mode: dsr`) |
| Aceleración XDP | No | No | **Sí** (`loadBalancer.acceleration: native`) |
| Hashing consistente | No | Limitado | **Maglev** |
| Preservación de la IP de origen | Sólo con `externalTrafficPolicy: Local` | Igual | DSR o `Local`, más modo híbrido |
| Terminación grácil de backends | Débil | Débil | **Sí** (los backends en terminación drenan) |
| Observabilidad | Sólo contadores | Sólo contadores | Por flujo vía Hubble |

El reemplazo puede ser **`true`** (completo) o **`false`** (coexistir con kube-proxy, eBPF maneja sólo lo que se habilita explícitamente). La habilitación parcial se expresa mediante los flags individuales (`enable-node-port`, `enable-external-ips`, `enable-host-port`, `enable-socket-lb`).

### 7.3 SNAT vs DSR vs Híbrido para NodePort

| Modo | Camino de retorno | IP de origen que ve el backend | Impacto en MTU | Restricción |
|---|---|---|---|---|
| **SNAT** | Por el nodo de ingreso (hairpin) | IP del nodo (salvo `externalTrafficPolicy: Local`) | Ninguno | Salto extra, estado NAT extra |
| **DSR** | El nodo del backend responde **directamente** al cliente | IP real del cliente | La cabecera de opción/IPIP agrega bytes | El underlay debe aceptar enrutamiento asimétrico; sin RPF estricto |
| **Híbrido** | DSR para TCP, SNAT para UDP | Mixta | Mixto | Mejor opción por defecto cuando UDP rompe DSR |

### 7.4 Masquerading

| Modo | Implementación | Requisito | Notas |
|---|---|---|---|
| **Masquerading eBPF** (`bpf.masquerade: true`) | `bpf_host.o` + `cilium_snat_v4_external` | Kernel ≥ 4.19, reemplazo de `kube-proxy`, dispositivos detectados | Más rápido, sin iptables; `cilium-dbg bpf nat list` |
| **Masquerading con iptables** | Reglas `POSTROUTING` en la cadena `CILIUM_POST_nat` | Cualquiera | Fallback por defecto; visible en `iptables-save` |
| **Deshabilitado** | — | El underlay enruta el CIDR de pods | Requerido para que la IP de origen sea correcta hacia servicios on-prem |

### 7.5 Cifrado

| | **WireGuard** | **IPsec (ESP)** |
|---|---|---|
| Superficie de configuración | `encryption.type: wireguard`, claves autogeneradas por nodo | Claves precompartidas en un Secret, rotación manual |
| Requisito de kernel | ≥ 5.6 (o el módulo wireguard) | Stack XFRM |
| Overhead de MTU | ~60 bytes | ~50–60 bytes (depende del cifrador) |
| FIPS | No validado FIPS | Cifradores compatibles con FIPS disponibles |
| Nodo-a-nodo vs pod-a-pod | Túneles nodo-a-nodo que transportan tráfico de pods | SAs por nodo; identidad transportada en el SPI/mark |
| Simplicidad operativa | **Alta** — rotación de claves automática al reiniciar el nodo | Baja — la rotación de claves es un procedimiento documentado de varios pasos |
| Inspección | `cilium-dbg encrypt status` | `cilium-dbg encrypt status` |

---

## 8. `cilium-envoy` y el datapath L7

Desde Cilium 1.16 Envoy corre como su **propio DaemonSet** (`cilium-envoy`) en vez de embebido en el proceso del agente. La separación importa operativamente: un OOM o crash-loop de Envoy ya no se lleva puesto al agente — y por lo tanto al datapath L3/L4 — y Envoy se puede actualizar con otra cadencia.

**Cableado:**

* Agente → Envoy: configuración vía **xDS sobre un socket unix**: `/var/run/cilium/envoy/sockets/xds.sock`.
* Envoy → agente para veredictos de política y access logs: `/var/run/cilium/envoy/sockets/access_log.sock`.
* Interfaz de administración: `/var/run/cilium/envoy/sockets/admin.sock` (un socket unix, deliberadamente no un puerto TCP).
* Configuración de bootstrap desde el ConfigMap `cilium-envoy-config`, montada en `/var/run/cilium/envoy/bootstrap-config.json`.
* Métricas de Prometheus: **:9964**.

**Mecánica de la redirección:** cuando una política contiene una regla L7 (`toPorts[].rules.http`), la entrada del mapa de política por endpoint para ese `(identidad, puerto)` lleva un **puerto de proxy**. `bpf_lxc.o` establece una marca en el skb y usa tproxy para dirigir el paquete al listener local de Envoy. Envoy recibe la conexión *con la 5-tupla original preservada* (vía el listener filter `cilium.bpf_metadata`, que recupera la identidad de origen desde el ipcache), aplica las reglas L7 con el filtro `cilium.l7policy`, y reenvía.

**Punto clave de examen:** una regla L7 hace que toda la entrada `toPorts` pase a aplicarse en L7. El tráfico que no parsea como el protocolo declarado se descarta, y el flujo aparece en Hubble con información de veredicto `L7` en lugar de sólo `Forwarded`/`Dropped`.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg policy get --all | head -40
[
  {
    "endpointSelector": {
      "matchLabels": { "k8s:app": "payments-api", "k8s:io.kubernetes.pod.namespace": "payments" }
    },
    "ingress": [
      {
        "fromEndpoints": [
          { "matchLabels": { "k8s:app": "frontend", "k8s:io.kubernetes.pod.namespace": "shop" } }
        ],
        "toPorts": [
          {
            "ports": [ { "port": "8080", "protocol": "TCP" } ],
            "rules": {
              "http": [ { "method": "GET", "path": "/api/v1/charges(/.*)?$" } ]
            }
          }
        ]
      }
    ],
    "labels": [
      { "key": "io.cilium.k8s.policy.derived-from", "value": "CiliumNetworkPolicy", "source": "k8s" },
      { "key": "io.cilium.k8s.policy.name", "value": "payments-l7", "source": "k8s" },
      { "key": "io.cilium.k8s.policy.namespace", "value": "payments", "source": "k8s" }
    ]
  }
]
Revision: 47
```

---

## 9. Hubble

Hubble son **tres capas**, y confundirlas es el error clásico de troubleshooting:

| Capa | Dónde | Puerto | Alcance | ¿Falla de forma independiente? |
|---|---|---|---|---|
| **Hubble (embebido)** | dentro de `cilium-agent` | gRPC **4244** (`hubble.listenAddress`) | Un nodo | Sí — `hubble.enabled=false` deja el datapath intacto |
| **Hubble Relay** | Deployment | gRPC **4245** | Todo el clúster (fan-out al servicio peer de cada agente) | Sí |
| **Hubble UI** | Deployment | HTTP **8081** (svc), contenedores backend + frontend | Todo el clúster | Sí |

**Camino de datos de un flujo:** programa eBPF → perf ring buffer `cilium_events` → monitor del agente → observer de Hubble → **ring buffer** en memoria (por defecto `hubble.eventBufferCapacity: 4095` eventos por nodo) → stream gRPC / exportador de métricas / archivo de log de flujos.

Ese ring buffer en memoria es lo que hay que internalizar: **Hubble no es una base de datos.** Los flujos se pierden al reiniciar el agente y se van desalojando continuamente. Para retención se exporta — `hubble.export.static` a un archivo para un log shipper, o `hubble.metrics` a Prometheus, o Hubble Timescape (Isovalent Enterprise).

Las métricas son opt-in por contexto, y **la cardinalidad es un riesgo de producción**:

```yaml
hubble:
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop:sourceContext=pod;destinationContext=pod
      - tcp
      - flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - port-distribution
      - icmp
      - httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction
```

Agregar `sourceContext=pod` en `flow` en un clúster con miles de pods de vida corta produce una cardinalidad de labels no acotada. Preferí `workload-name` antes que `pod`.

```
$ hubble observe --namespace payments --verdict DROPPED --last 5
Sep  1 09:14:02.113: shop/frontend-7d9c8b5f6-2xqzk:41022 (ID:52901) -> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 09:14:02.113: shop/frontend-7d9c8b5f6-2xqzk:41022 (ID:52901) <> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 09:14:03.221: shop/frontend-7d9c8b5f6-2xqzk:41024 (ID:52901) -> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 09:14:05.998: kube-system/coredns-7db6d8ff4d-4gk7z:53 (ID:23409) <> shop/cart-6b7f8c9d5-plm4x:38821 (ID:19022) Policy denied DROPPED (UDP)
Sep  1 09:14:06.004: shop/cart-6b7f8c9d5-plm4x:38821 (ID:19022) -> kube-system/coredns-7db6d8ff4d-4gk7z:53 (ID:23409) policy-verdict:none EGRESS DENIED (UDP)
```

```
$ hubble observe --http-status 5xx --protocol http --last 3 -o json | jq -c '{t:.time, src:.source.pod_name, dst:.destination.pod_name, http:.l7.http}'
{"t":"2026-09-01T09:15:11.442Z","src":"frontend-7d9c8b5f6-2xqzk","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":503,"method":"POST","url":"http://payments-api:8080/api/v1/charges","protocol":"HTTP/1.1"}}
{"t":"2026-09-01T09:15:11.889Z","src":"frontend-7d9c8b5f6-2xqzk","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":503,"method":"POST","url":"http://payments-api:8080/api/v1/charges","protocol":"HTTP/1.1"}}
{"t":"2026-09-01T09:15:12.331Z","src":"checkout-58d9f7b4c-9rt2v","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":500,"method":"GET","url":"http://payments-api:8080/healthz","protocol":"HTTP/1.1"}}
```

---

## 10. ClusterMesh

`clustermesh-apiserver` es un Deployment que contiene **dos contenedores**: un `etcd` embebido y un proceso `clustermesh-apiserver` que replica las identidades, endpoints, nodos y servicios globales del clúster local dentro de ese etcd. Los agentes de los clústeres remotos se conectan a él como **clientes etcd de sólo lectura sobre mTLS**.

Requisitos que el examen evalúa:

1. **`cluster-name` y `cluster-id` únicos** (1–255 por defecto) por clúster. Un `cluster-id` duplicado corrompe la asignación de identidades en toda la malla.
2. **CIDRs de Pod no solapados** entre todos los clústeres.
3. **Alcanzabilidad nodo-a-nodo** entre clústeres para la red de pods (o túneles/cifrado entre ellos).
4. El `clustermesh-apiserver` debe ser **alcanzable desde los clústeres remotos** — LoadBalancer, NodePort, o un camino de red compartido — en **2379/TCP**.
5. CA de la malla: todos los clústeres deben confiar en una **CA común** para el mTLS entre agentes y apiservers remotos.

Los servicios globales son opt-in por Service mediante anotaciones:

```yaml
metadata:
  annotations:
    service.cilium.io/global: "true"                 # backends from all clusters
    service.cilium.io/shared: "true"                 # export this cluster's backends to the mesh
    service.cilium.io/affinity: "local"              # prefer local backends; fail over remote
    service.cilium.io/global-sync-endpoint-slices: "true"
```

```
$ cilium clustermesh status --context eu-prod
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 10.0.9.44:2379
✅ Deployment clustermesh-apiserver is ready
ℹ️  KVStoreMesh is enabled

✅ All 6 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]

🔌 Cluster Connections:
  - us-prod: 6/6 configured, 6/6 connected

🔀 Global services: [ min:4 / avg:4.0 / max:4 ]
```

**KVStoreMesh** (un modo de operación de `clustermesh-apiserver`) agrega una capa de caché: en vez de que cada agente del clúster A observe directamente el apiserver del clúster B, el `clustermesh-apiserver` local cachea el estado remoto y los agentes observan localmente. Esto convierte una matriz de conexiones N×M en N+M y es el modo recomendado a escala.

---

## 11. Manifiestos completos de infraestructura

### 11.1 Valores de Helm de producción (`values-prod.yaml`) — completos

```yaml
# Cilium production values — native routing + full kube-proxy replacement,
# WireGuard node-to-node encryption, Hubble with Prometheus export.
# Install:
#   helm repo add cilium https://helm.cilium.io/
#   helm upgrade --install cilium cilium/cilium --version 1.16.5 \
#     --namespace kube-system -f values-prod.yaml

k8sServiceHost: api.eu-prod.internal
k8sServicePort: 6443

cluster:
  name: eu-prod
  id: 1

# ---------- Datapath ----------
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: 10.244.0.0/16
enableIPv4Masquerade: true
enableIPv6Masquerade: false
bpf:
  masquerade: true
  hostLegacyRouting: false
  preallocateMaps: true
  lbMapMax: 131072
  policyMapMax: 32768
  mapDynamicSizeRatio: 0.0025
  monitorAggregation: medium
  monitorInterval: 5s
  monitorFlags: all
  tproxy: true

ipv4:
  enabled: true
ipv6:
  enabled: false

# ---------- IPAM ----------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24

# ---------- kube-proxy replacement ----------
kubeProxyReplacement: "true"
k8sServiceLookupOrder: ""
socketLB:
  enabled: true
  hostNamespaceOnly: false
loadBalancer:
  algorithm: maglev
  mode: hybrid
  acceleration: native
  serviceTopology: true
maglev:
  tableSize: 16381
  hashSeed: "JLfvgnHc2kaSUFaI"
nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true
devices: "eth+ bond+"

# ---------- Encryption ----------
encryption:
  enabled: true
  type: wireguard
  nodeEncryption: true
  wireguard:
    persistentKeepalive: 0s

# ---------- Policy ----------
policyEnforcementMode: default
policyAuditMode: false
hostFirewall:
  enabled: true
enableCiliumEndpointSlice: true
identityAllocationMode: crd
identityChangeGracePeriod: 5s
labels: "k8s:app k8s:name k8s:component k8s:tier k8s:io.kubernetes.pod.namespace k8s:io.cilium.k8s.policy.* k8s:io.cilium.k8s.namespace.labels.*"

dnsProxy:
  enableTransparentMode: true
  minTtl: 3600
  maxDeferredConnectionDeletes: 10000
  endpointMaxIpPerHostname: 100

# ---------- L7 / Envoy ----------
envoy:
  enabled: true
  prometheus:
    enabled: true
    port: "9964"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
ingressController:
  enabled: true
  loadbalancerMode: shared
  default: false
  enforceHttps: true
gatewayAPI:
  enabled: false

# ---------- Observability ----------
hubble:
  enabled: true
  eventBufferCapacity: 16383
  eventQueueSize: 0
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop:sourceContext=workload-name;destinationContext=workload-name
      - tcp
      - flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - port-distribution
      - icmp
      - httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction
    serviceMonitor:
      enabled: true
    dashboards:
      enabled: true
      namespace: monitoring
  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
    prometheus:
      enabled: true
      port: 9966
      serviceMonitor:
        enabled: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 512Mi
  ui:
    enabled: true
    replicas: 1
  tls:
    auto:
      enabled: true
      method: helm
      certValidityDuration: 1095

# ---------- Prometheus ----------
prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true
    trustCRDsExist: true
operator:
  replicas: 2
  rollOutPods: true
  prometheus:
    enabled: true
    port: 9963
    serviceMonitor:
      enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 1Gi
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1

# ---------- Agent runtime ----------
rollOutCiliumPods: true
priorityClassName: system-node-critical
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    memory: 4Gi
cni:
  exclusive: true
  logFile: /var/run/cilium/cilium-cni.log
  install: true
  chainingMode: none

# ---------- ClusterMesh ----------
clustermesh:
  useAPIServer: true
  apiserver:
    kvstoremesh:
      enabled: true
    replicas: 2
    service:
      type: LoadBalancer
    tls:
      auto:
        enabled: true
        method: certmanager
        certManagerIssuerRef:
          group: cert-manager.io
          kind: ClusterIssuer
          name: mesh-ca

# ---------- Upgrade safety ----------
upgradeCompatibility: "1.16"
```

### 11.2 El ConfigMap `cilium-config` que esto renderiza (extracto del objeto real)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  agent-not-ready-taint-key: node.cilium.io/agent-not-ready
  arping-refresh-period: 30s
  auto-direct-node-routes: "true"
  bpf-lb-algorithm: maglev
  bpf-lb-external-clusterip: "false"
  bpf-lb-map-max: "131072"
  bpf-lb-maglev-table-size: "16381"
  bpf-lb-mode: hybrid
  bpf-map-dynamic-size-ratio: "0.0025"
  bpf-policy-map-max: "32768"
  bpf-root: /sys/fs/bpf
  cgroup-root: /run/cilium/cgroupv2
  cluster-id: "1"
  cluster-name: eu-prod
  cni-exclusive: "true"
  cni-log-file: /var/run/cilium/cilium-cni.log
  custom-cni-conf: "false"
  debug: "false"
  enable-auto-protect-node-port-range: "true"
  enable-bpf-clock-probe: "false"
  enable-bpf-masquerade: "true"
  enable-cilium-endpoint-slice: "true"
  enable-endpoint-health-checking: "true"
  enable-endpoint-routes: "false"
  enable-health-check-nodeport: "true"
  enable-health-checking: "true"
  enable-host-firewall: "true"
  enable-hubble: "true"
  enable-ipv4: "true"
  enable-ipv4-masquerade: "true"
  enable-ipv6: "false"
  enable-k8s-networkpolicy: "true"
  enable-l2-neigh-discovery: "true"
  enable-l7-proxy: "true"
  enable-local-redirect-policy: "false"
  enable-metrics: "true"
  enable-node-port: "true"
  enable-policy: default
  enable-remote-node-identity: "true"
  enable-sctp: "false"
  enable-svc-source-range-check: "true"
  enable-wireguard: "true"
  enable-xt-socket-fallback: "true"
  encrypt-node: "true"
  hubble-disable-tls: "false"
  hubble-event-buffer-capacity: "16383"
  hubble-listen-address: ":4244"
  hubble-metrics-server: ":9965"
  hubble-socket-path: /var/run/cilium/hubble.sock
  identity-allocation-mode: crd
  identity-gc-interval: 15m0s
  identity-heartbeat-timeout: 30m0s
  install-no-conntrack-iptables-rules: "false"
  ipam: cluster-pool
  ipv4-native-routing-cidr: 10.244.0.0/16
  kube-proxy-replacement: "true"
  monitor-aggregation: medium
  monitor-aggregation-flags: all
  monitor-aggregation-interval: 5s
  node-port-bind-protection: "true"
  nodes-gc-interval: 5m0s
  operator-api-serve-addr: 127.0.0.1:9234
  operator-prometheus-serve-addr: :9963
  preallocate-bpf-maps: "true"
  procfs: /host/proc
  prometheus-serve-addr: :9962
  proxy-connect-timeout: "2"
  remove-cilium-node-taints: "true"
  routing-mode: native
  set-cilium-is-up-condition: "true"
  set-cilium-node-taints: "true"
  sync-k8s-nodes: "true"
  sync-k8s-services: "true"
  tofqdns-dns-reject-response-code: refused
  tofqdns-enable-dns-compression: "true"
  tofqdns-endpoint-max-ip-per-hostname: "100"
  tofqdns-idle-connection-grace-period: 0s
  tofqdns-max-deferred-connection-deletes: "10000"
  tofqdns-proxy-response-max-delay: 100ms
  tunnel-protocol: vxlan
  write-cni-conf-when-ready: /host/etc/cni/net.d/05-cilium.conflist
```

### 11.3 El DaemonSet `cilium` — las partes que explican la arquitectura

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cilium
  namespace: kube-system
  labels:
    k8s-app: cilium
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 2
  template:
    metadata:
      labels:
        k8s-app: cilium
      annotations:
        container.apparmor.security.beta.kubernetes.io/cilium-agent: unconfined
        container.apparmor.security.beta.kubernetes.io/clean-cilium-state: unconfined
    spec:
      # hostNetwork is mandatory: the agent programs the host's devices and
      # must reach the apiserver before pod networking exists.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      restartPolicy: Always
      priorityClassName: system-node-critical
      serviceAccountName: cilium
      terminationGracePeriodSeconds: 1
      # Tolerate everything: the CNI must start on a NotReady node.
      tolerations:
        - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  k8s-app: cilium
              topologyKey: kubernetes.io/hostname

      initContainers:
        # 1. Mount cgroup v2 for the socket-LB (cgroup connect) hooks.
        - name: mount-cgroup
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - sh
            - -ec
            - |
              cp /usr/bin/cilium-mount /hostbin/cilium-mount;
              nsenter --cgroup=/hostproc/1/ns/cgroup --mount=/hostproc/1/ns/mnt \
                "${BIN_PATH}/cilium-mount" $CGROUP_ROOT;
              rm /hostbin/cilium-mount
          env:
            - name: CGROUP_ROOT
              value: /run/cilium/cgroupv2
            - name: BIN_PATH
              value: /opt/cni/bin
          securityContext:
            privileged: true
          volumeMounts:
            - name: hostproc
              mountPath: /hostproc
            - name: cni-path
              mountPath: /hostbin

        # 2. Sysctl overrides required by the datapath (rp_filter, forwarding).
        - name: apply-sysctl-overwrites
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - sh
            - -ec
            - |
              cp /usr/bin/cilium-sysctlfix /hostbin/cilium-sysctlfix;
              nsenter --mount=/hostproc/1/ns/mnt "${BIN_PATH}/cilium-sysctlfix";
              rm /hostbin/cilium-sysctlfix
          env:
            - name: BIN_PATH
              value: /opt/cni/bin
          securityContext:
            privileged: true
          volumeMounts:
            - name: hostproc
              mountPath: /hostproc
            - name: cni-path
              mountPath: /hostbin

        # 3. Mount bpffs inside the agent's mount namespace.
        - name: mount-bpf-fs
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /bin/bash
            - -c
            - --
          args:
            - 'mount | grep "/sys/fs/bpf type bpf" || mount -t bpf bpf /sys/fs/bpf'
          securityContext:
            privileged: true
          volumeMounts:
            - name: bpf-maps
              mountPath: /sys/fs/bpf
              mountPropagation: Bidirectional

        # 4. Optional teardown of previous datapath state on restart.
        - name: clean-cilium-state
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /init-container.sh
          env:
            - name: CILIUM_ALL_STATE
              valueFrom:
                configMapKeyRef:
                  name: cilium-config
                  key: clean-cilium-state
                  optional: true
            - name: CILIUM_BPF_STATE
              valueFrom:
                configMapKeyRef:
                  name: cilium-config
                  key: clean-cilium-bpf-state
                  optional: true
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              add:
                - NET_ADMIN
                - SYS_MODULE
                - SYS_ADMIN
                - SYS_RESOURCE
              drop:
                - ALL
          volumeMounts:
            - name: bpf-maps
              mountPath: /sys/fs/bpf
            - name: cilium-cgroup
              mountPath: /run/cilium/cgroupv2
              mountPropagation: HostToContainer
            - name: cilium-run
              mountPath: /var/run/cilium

        # 5. Place the CNI binaries on the host.
        - name: install-cni-binaries
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /install-plugin.sh
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: cni-path
              mountPath: /host/opt/cni/bin

      containers:
        - name: cilium-agent
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - cilium-agent
          args:
            - --config-dir=/tmp/cilium/config-map
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: spec.nodeName
            - name: CILIUM_K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: metadata.namespace
            - name: KUBERNETES_SERVICE_HOST
              value: api.eu-prod.internal
            - name: KUBERNETES_SERVICE_PORT
              value: "6443"
          ports:
            - name: peer-service
              containerPort: 4244
              hostPort: 4244
              protocol: TCP
            - name: prometheus
              containerPort: 9962
              hostPort: 9962
              protocol: TCP
            - name: hubble-metrics
              containerPort: 9965
              hostPort: 9965
              protocol: TCP
          startupProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            failureThreshold: 105
            periodSeconds: 2
            successThreshold: 1
          livenessProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            periodSeconds: 30
            successThreshold: 1
            failureThreshold: 10
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            periodSeconds: 30
            successThreshold: 1
            failureThreshold: 3
            timeoutSeconds: 5
          lifecycle:
            preStop:
              exec:
                command:
                  - /cni-uninstall.sh
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              add:
                - CHOWN
                - KILL
                - NET_ADMIN
                - NET_RAW
                - IPC_LOCK
                - SYS_MODULE
                - SYS_ADMIN
                - SYS_RESOURCE
                - DAC_OVERRIDE
                - FOWNER
                - SETGID
                - SETUID
              drop:
                - ALL
          volumeMounts:
            - name: cilium-run
              mountPath: /var/run/cilium
            - name: bpf-maps
              mountPath: /sys/fs/bpf
              mountPropagation: HostToContainer
            - name: cilium-cgroup
              mountPath: /run/cilium/cgroupv2
              mountPropagation: HostToContainer
            - name: cni-path
              mountPath: /host/opt/cni/bin
            - name: etc-cni-netd
              mountPath: /host/etc/cni/net.d
            - name: clustermesh-secrets
              mountPath: /var/lib/cilium/clustermesh
              readOnly: true
            - name: lib-modules
              mountPath: /lib/modules
              readOnly: true
            - name: xtables-lock
              mountPath: /run/xtables.lock
            - name: hubble-tls
              mountPath: /var/lib/cilium/tls/hubble
              readOnly: true
            - name: tmp
              mountPath: /tmp
            - name: envoy-sockets
              mountPath: /var/run/cilium/envoy/sockets

      volumes:
        - name: tmp
          emptyDir: {}
        # Host-backed: state must survive an agent restart.
        - name: cilium-run
          hostPath:
            path: /var/run/cilium
            type: DirectoryOrCreate
        - name: bpf-maps
          hostPath:
            path: /sys/fs/bpf
            type: DirectoryOrCreate
        - name: hostproc
          hostPath:
            path: /proc
            type: Directory
        - name: cilium-cgroup
          hostPath:
            path: /run/cilium/cgroupv2
            type: DirectoryOrCreate
        - name: cni-path
          hostPath:
            path: /opt/cni/bin
            type: DirectoryOrCreate
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d
            type: DirectoryOrCreate
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
        - name: envoy-sockets
          hostPath:
            path: /var/run/cilium/envoy/sockets
            type: DirectoryOrCreate
        - name: clustermesh-secrets
          projected:
            defaultMode: 256
            sources:
              - secret:
                  name: cilium-clustermesh
                  optional: true
              - secret:
                  name: clustermesh-apiserver-remote-cert
                  optional: true
                  items:
                    - key: tls.key
                      path: common-etcd-client.key
                    - key: tls.crt
                      path: common-etcd-client.crt
                    - key: ca.crt
                      path: common-etcd-client-ca.crt
        - name: hubble-tls
          projected:
            defaultMode: 256
            sources:
              - secret:
                  name: hubble-server-certs
                  optional: true
                  items:
                    - key: tls.crt
                      path: server.crt
                    - key: tls.key
                      path: server.key
                    - key: ca.crt
                      path: client-ca.crt
```

**Qué hay que notar, porque esto es arquitectura y no relleno:**

* `hostNetwork: true` + `tolerations: [{operator: Exists}]` — el CNI debe correr antes de que el nodo esté Ready y antes de que exista la red de pods.
* `bpf-maps` montado desde `/sys/fs/bpf` con `mountPropagation` — el tiempo de vida de los mapas está desacoplado del tiempo de vida del contenedor. **Reiniciar el agente no corta el tráfico existente.**
* `cilium-cgroup` en `/run/cilium/cgroupv2` — requerido para el socket LB.
* `preStop: /cni-uninstall.sh` — quita la configuración del CNI para que el kubelet no intente planificar pods en un nodo sin CNI funcionando.
* El `startupProbe` tiene `failureThreshold: 105, periodSeconds: 2` ≈ **3,5 minutos** de gracia: la compilación inicial del datapath en un nodo en frío es lenta, y un probe más ajustado provoca crash-loops.
* `agent-not-ready-taint-key: node.cilium.io/agent-not-ready` — el nodo queda con taint hasta que el agente esté listo, evitando que se planifiquen pods en un nodo sin datapath.

### 11.4 Configuración del CNI instalada en el host

```json
{
  "cniVersion": "1.0.0",
  "name": "cilium",
  "plugins": [
    {
      "type": "cilium-cni",
      "log-file": "/var/run/cilium/cilium-cni.log",
      "enable-debug": false,
      "ipam": {
        "type": "cilium-cni"
      }
    }
  ]
}
```

### 11.5 Carga de trabajo de verificación + política — completa y aplicable

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: arch-lab
  labels:
    env: lab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: arch-lab
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: data
    spec:
      containers:
        - name: echo
          image: gcr.io/k8s-staging-gateway-api/echo-basic:v20231214-v1.0.0-140-gf544a46e
          ports:
            - name: http
              containerPort: 3000
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: arch-lab
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - name: http
      port: 8080
      targetPort: 3000
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: arch-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
        tier: front
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.11.0
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-l7
  namespace: arch-lab
spec:
  description: "Only app=client may GET /healthz and /api/* on backend:3000"
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      toPorts:
        - ports:
            - port: "3000"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/healthz"
              - method: GET
                path: "/api/.*"
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
---
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-health-and-dns-everywhere
spec:
  description: "Baseline: never break cilium-health or cluster DNS"
  endpointSelector: {}
  ingress:
    - fromEntities:
        - health
        - remote-node
  egress:
    - toEntities:
        - health
        - remote-node
        - kube-apiserver
```

### 11.6 Override por nodo con `CiliumNodeConfig`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  name: debug-on-canary-nodes
  namespace: kube-system
spec:
  nodeSelector:
    matchLabels:
      cilium.io/profile: canary
  defaults:
    debug: "true"
    debug-verbose: "flow datapath"
    monitor-aggregation: "none"
```

### 11.7 Clúster de laboratorio reproducible (kind) con Cilium como único CNI

```yaml
# kind-cilium.yaml
#   kind create cluster --config kind-cilium.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
nodes:
  - role: control-plane
  - role: worker
  - role: worker
networking:
  disableDefaultCNI: true   # no kindnet
  kubeProxyMode: none       # full eBPF kube-proxy replacement
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
```

```
$ kind create cluster --config kind-cilium.yaml
$ docker exec cca-lab-control-plane mount | grep bpf
none on /sys/fs/bpf type bpf (rw,nosuid,nodev,noexec,relatime,mode=700)

$ helm repo add cilium https://helm.cilium.io/ && helm repo update
$ helm install cilium cilium/cilium --version 1.16.5 \
    --namespace kube-system \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=cca-lab-control-plane \
    --set k8sServicePort=6443 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
NAME: cilium
LAST DEPLOYED: Tue Sep  1 09:02:41 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1

$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet         cilium            Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet         cilium-envoy      Desired: 3, Ready: 3/3, Available: 3/3
Deployment        cilium-operator   Desired: 1, Ready: 1/1, Available: 1/1
Deployment        hubble-relay      Desired: 1, Ready: 1/1, Available: 1/1
Deployment        hubble-ui         Desired: 1, Ready: 1/1, Available: 1/1
Cluster Pods:     12/12 managed by Cilium
```

---

## 12. Verificación y diagnóstico

### 12.1 La escalera de diagnóstico — de lo más barato primero

| Peldaño | Comando | Qué responde |
|---|---|---|
| 0 | `cilium status --wait` | ¿Están todos los componentes planificados, listos y con versiones consistentes? |
| 1 | `cilium-dbg status --verbose` | En **este nodo**: reemplazo de kube-proxy, IPAM, cifrado, presión de mapas, fallas de controladores |
| 2 | `cilium-dbg endpoint list` | ¿Mi pod es un endpoint gestionado? ¿Se aplica política en esa dirección? |
| 3 | `cilium-dbg identity list` / `identity get` | ¿Los labels que creo que existen forman realmente la identidad? |
| 4 | `cilium-dbg bpf ipcache list` | ¿El datapath conoce la identidad de esta IP y el nodo que la posee? |
| 5 | `cilium-dbg policy get` / `bpf policy get <ep>` | ¿Qué está *realmente* programado, frente a lo que dice la CRD? |
| 6 | `hubble observe --verdict DROPPED` | ¿Qué flujos se descartan, y con qué motivo? |
| 7 | `cilium-dbg monitor -t drop --related-to <ep>` | Eventos crudos del datapath, sin agregación |
| 8 | `cilium connectivity test` | Prueba funcional de punta a punta sobre ~50 escenarios |
| 9 | `cilium sysdump` | Todo, empaquetado, para escalar el caso |

### 12.2 `cilium-dbg status --verbose` — salida real anotada

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose
KVStore:                Ok   Disabled
Kubernetes:             Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:        ["EndpointSliceOrEndpoint", "cilium/v2::CiliumClusterwideNetworkPolicy", "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy", "cilium/v2::CiliumNode", "core/v1::Namespace", "core/v1::Pods", "core/v1::Service", "networking.k8s.io/v1::NetworkPolicy"]
KubeProxyReplacement:   True   [eth0   10.0.1.11 (Direct Routing)]
Host firewall:          Enabled   [eth0]
SRv6:                   Disabled
CNI Chaining:           none
CNI Config file:        successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                 Ok   1.16.5 (v1.16.5-a1b2c3d4)
NodeMonitor:            Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:   Ok
IPAM:                   IPv4: 27/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.1 (router)
  10.244.1.14 (shop/frontend-7d9c8b5f6-2xqzk)
  10.244.1.87 (payments/payments-api-5f7b9d4c8-jk2mn)
  10.244.1.201 (health)
IPv4 BIG TCP:           Disabled
IPv6 BIG TCP:           Disabled
BandwidthManager:       EDT with BPF [CUBIC] [eth0]
Host Routing:           BPF
Masquerading:           BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:   ktime
Controller Status:      142/142 healthy
Proxy Status:           OK, ip 10.244.1.1, 2 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:  min 256, max 65535
Hubble:                 Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 412.77   Metrics: Ok
Encryption:             Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: t6X...=, Port: 51871, Peers: 5)]
Cluster health:         6/6 reachable   (2026-09-01T09:16:02Z)
  Name                  IP              Node        Endpoints
  eu-prod/node-01       10.0.1.11       reachable   reachable
  eu-prod/node-02       10.0.1.12       reachable   reachable
  eu-prod/node-03       10.0.1.13       reachable   reachable
  eu-prod/node-04       10.0.1.14       reachable   reachable
  eu-prod/node-05       10.0.1.15       reachable   reachable
  eu-prod/node-06       10.0.1.16       reachable   reachable
Modules Health:
  agent
  ├── controlplane                                                     
  │   ├── auth                             [OK] Primed (2m, x1)
  │   ├── cilium-endpoint-slice-controller [OK] Synchronized (5m, x3)
  │   ├── daemon                           [OK] daemon-validate-config (12m, x1)
  │   └── endpoint-manager                 [OK] cilium-endpoint-27 (3s, x841)
  └── datapath                                                          
      ├── agent-liveness-updater           [OK] Running (12m, x1)
      ├── l2-responder                     [OK] Primed (12m, x1)
      └── node-address                     [OK] 3 addresses (12m, x1)
```

**Leé específicamente estas líneas:**

* `Controller Status: 142/142 healthy` — cualquier `x/y` donde `x < y` significa que un controlador en segundo plano está fallando; ejecutá `cilium-dbg status --all-controllers`.
* `Hubble: Current/Max Flows: 16383/16383 (100.00%)` — el ring está **lleno**, lo cual es el estado estacionario normal, no un error. Significa que los flujos viejos se están desalojando.
* `Host Routing: BPF` vs `Legacy` — `Legacy` significa que el tráfico atraviesa el stack de iptables/enrutamiento del host; una regresión silenciosa de rendimiento causada normalmente por un kernel no soportado.
* `Proxy Status: ... Envoy: external` — Envoy es el DaemonSet separado, no el embebido.
* `Cluster health: 6/6 reachable` con dos columnas: **Node** (camino por la IP del nodo) y **Endpoints** (camino por la red de pods). `reachable / unreachable` significa que el underlay está bien pero el overlay de pods está roto — ese par localiza una falla al instante.

### 12.3 Verificación de la programación de Services de punta a punta

```
$ kubectl -n arch-lab get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'
10.96.184.22

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A4 10.96.184.22
ID   Frontend               Service Type   Backend
17   10.96.184.22:8080/TCP  ClusterIP      1 => 10.244.1.31:3000/TCP (active)
                                           2 => 10.244.2.44:3000/TCP (active)
                                           3 => 10.244.3.19:3000/TCP (active)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list | grep -A4 10.96.184.22
SERVICE ADDRESS        BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.96.184.22:8080/TCP  0.0.0.0:0 (17) (0) [ClusterIP, non-routable]
                       10.244.1.31:3000/TCP (17) (1)
                       10.244.2.44:3000/TCP (17) (2)
                       10.244.3.19:3000/TCP (17) (3)
```

El slot `0` contiene los metadatos del frontend (cantidad de backends, flags); los slots `1..n` son los backends. Si `cilium-dbg service list` muestra backends pero `bpf lb list` no, **el espacio de usuario y el datapath divergieron** — un mapa lleno o una actualización de mapa fallida.

Probá que el socket LB está haciendo el trabajo — el paquete nunca lleva la VIP:

```
$ kubectl -n arch-lab exec deploy/client -- curl -s -o /dev/null -w '%{remote_ip}:%{remote_port}\n' http://backend:8080/healthz
10.244.2.44:3000
```

El cliente marcó `backend:8080` (→ `10.96.184.22:8080`) y `curl` reporta el peer como una **IP de pod**, porque el `connect()` fue reescrito en el hook de cgroup.

### 12.4 El test de conectividad completo

```
$ cilium connectivity test --test-namespace cilium-test
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [eu-prod] Creating namespace cilium-test for connectivity check...
✨ [eu-prod] Deploying echo-same-node service...
✨ [eu-prod] Deploying DNS test server configmap...
⌛ [eu-prod] Waiting for deployment cilium-test/client to become ready...
⌛ [eu-prod] Waiting for CiliumEndpoint for pod cilium-test/client-6f6788d7cc-9zx4t to appear...
🏃 Running 82 tests ...
[=] Test [no-policies] .........................
[=] Test [allow-all-except-world] ..............
[=] Test [client-ingress] ......
[=] Test [echo-ingress] ........
[=] Test [client-egress-l7] ....................
[=] Test [dns-only] ............
[=] Test [to-fqdns] ........
[=] Test [pod-to-pod-encryption] ......
[=] Test [health] ..
[=] Test [north-south-loadbalancing] ..........
✅ [eu-prod] 82/82 tests successful (0 warnings)
```

Una falla imprime el comando exacto, los flujos de ambos lados y el veredicto esperado frente al observado — es el artefacto más útil para adjuntar a un reporte de bug, junto con `cilium sysdump`.

### 12.5 Catálogo de fallas

| Síntoma | Causa más probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| Pods trabados en `ContainerCreating`, `plugin type="cilium-cni" failed` | El agente no está listo en ese nodo, o falta la configuración del CNI | `kubectl -n kube-system logs -l k8s-app=cilium -c cilium-agent --tail=50`; `ls /etc/cni/net.d/` | Arreglar el arranque del agente; verificar que `cni.exclusive` no haya eliminado la configuración de otro CNI que todavía necesitás |
| `Unable to allocate IP` | Cluster-pool agotado, u operator caído | `cilium-dbg status --verbose \| grep IPAM`; `kubectl -n kube-system get ciliumnode <node> -o yaml` | Agrandar `clusterPoolIPv4PodCIDRList` / arreglar el operator |
| El nodo queda `NotReady`, taint `node.cilium.io/agent-not-ready` | El agente falla el readiness | `kubectl -n kube-system describe pod -l k8s-app=cilium` | Ver el motivo de la falla del probe; normalmente el montaje de bpffs/cgroup o un kernel demasiado viejo |
| Se permite tráfico que una política debería denegar | `policyAuditMode` activo, o el endpoint no tiene política en esa dirección | `cilium-dbg endpoint list` (mirar la columna `ENFORCEMENT`); `cilium-dbg config \| grep -i audit` | Desactivar el modo audit; agregar una política que seleccione el endpoint |
| `Policy denied DROPPED` para tráfico que debería estar permitido | Desajuste de identidad — los labels que seleccionaste están filtrados o pertenecen a otro namespace | `cilium-dbg identity get <id>`; `hubble observe --verdict DROPPED -o json \| jq .source.labels` | Seleccionar sobre labels que realmente sobrevivan al filtro de labels |
| Sólo falla el tráfico *entre nodos* | Asimetría de túnel/ruta/MTU/cifrado | `cilium-dbg bpf tunnel list`; matriz de salud de `cilium status`; `ip route` | Arreglar las rutas del underlay, la MTU, o el firewall en 8472/6081/51871 |
| Descartes intermitentes bajo carga, `Map insertion failed` | Mapa eBPF lleno (CT, NAT, política, LB) | `cilium-dbg bpf ct list global \| wc -l`; métrica `cilium_bpf_map_pressure` | Subir `bpf-ct-global-*-max`, `bpf-lb-map-max`, `bpf-policy-map-max` (**requiere reiniciar el agente**) |
| La política L7 nunca coincide; las conexiones se cuelgan | `cilium-envoy` caído o socket xDS no montado | `kubectl -n kube-system get ds cilium-envoy`; `cilium-dbg status \| grep Proxy` | Reiniciar `cilium-envoy`; verificar el volumen hostPath `envoy-sockets` |
| `hubble observe` vacío pero `cilium-dbg monitor` funciona | Relay no puede alcanzar los peers, o desajuste de TLS | `cilium hubble port-forward &`; `kubectl -n kube-system logs deploy/hubble-relay` | Regenerar los certificados de Hubble; verificar la alcanzabilidad del puerto 4244 |
| La resolución DNS falla sólo para pods restringidos por `toFQDNs` | El proxy DNS no está en modo transparente, o el egreso a CoreDNS no está permitido | `hubble observe --protocol dns --verdict DROPPED` | Agregar una regla de egreso explícita hacia `kube-dns` en UDP/53 **con una regla L7 `dns`** |
| Después de una actualización, todos los Services rotos | Se salteó `upgradeCompatibility` → cambio de formato de mapas | `cilium-dbg status`; logs del agente `unable to open map` | Seguir el camino de actualización documentado; fijar `upgradeCompatibility` a la minor anterior |

### 12.6 Motivos de descarte del datapath, directo desde los contadores

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf metrics list
REASON                           DIRECTION   PACKETS   BYTES
Policy denied                    INGRESS     18422     1104920
Policy denied                    EGRESS      3311      198660
Invalid source ip                INGRESS     0         0
Unsupported L3 protocol          INGRESS     412       24720
CT: Truncated or invalid header   INGRESS     7         420
Stale or unroutable IP           EGRESS      64        3840
Success                          INGRESS     91882314  71229381020
Success                          EGRESS      88401277  64110228893
```

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --related-to 164
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8a1f2c3d to endpoint 164, ifindex 42, file bpf_lxc.c:1998, , identity 52901->46212: 10.244.1.14:41022 -> 10.244.1.87:8080 tcp SYN
xx drop (Policy denied) flow 0x8a1f2c3e to endpoint 164, ifindex 42, file bpf_lxc.c:1998, , identity 52901->46212: 10.244.1.14:41024 -> 10.244.1.87:8080 tcp SYN
```

`identity 52901->46212` y `file bpf_lxc.c:1998` son los dos campos que convierten "está roto" en "la política de ingreso del endpoint destino no tiene una regla para la identidad de origen 52901".

### 12.7 Presión de mapas — la métrica sobre la que alertar

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s http://127.0.0.1:9962/metrics | grep cilium_bpf_map_pressure | sort -k2 -rn | head -6
cilium_bpf_map_pressure{map_name="cilium_ct4_global"} 0.71
cilium_bpf_map_pressure{map_name="cilium_lb4_backends_v3"} 0.44
cilium_bpf_map_pressure{map_name="cilium_snat_v4_external"} 0.38
cilium_bpf_map_pressure{map_name="cilium_ipcache"} 0.22
cilium_bpf_map_pressure{map_name="cilium_lxc"} 0.11
cilium_bpf_map_pressure{map_name="cilium_policy_v2_00164"} 0.03
```

Una `PrometheusRule` que vale la pena desplegar:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-datapath
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: cilium-datapath
      rules:
        - alert: CiliumBPFMapPressureHigh
          expr: cilium_bpf_map_pressure > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "eBPF map {{ $labels.map_name }} above 85% on {{ $labels.node }}"
            runbook: "Increase the corresponding *-map-max option; requires an agent restart."
        - alert: CiliumAgentUnreachableNodes
          expr: cilium_unreachable_nodes > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cilium reports {{ $value }} unreachable nodes from {{ $labels.node }}"
        - alert: CiliumEndpointRegenerationFailing
          expr: rate(cilium_endpoint_regeneration_total{outcome="fail"}[10m]) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Endpoint regeneration failing on {{ $labels.node }}"
        - alert: CiliumPolicyImportErrors
          expr: increase(cilium_policy_import_errors_total[15m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "Cilium rejected a policy on {{ $labels.node }}"
        - alert: CiliumOperatorNoLeader
          expr: absent(cilium_operator_process_start_time_seconds) == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No cilium-operator instance is reporting metrics"
```

### 12.8 El artefacto de escalamiento

```
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M)
🔮 Detected Cilium installation in namespace "kube-system"
🔍 Collecting Kubernetes nodes
🔍 Collecting Kubernetes events / pods / services / endpoints
🔍 Collecting Cilium CRDs (CiliumNetworkPolicy, CiliumEndpoint, CiliumIdentity, CiliumNode)
🔍 Collecting Cilium agent logs, `cilium-dbg status --verbose`, bpf map dumps, endpoint list
🔍 Collecting Hubble flows (last 10000 per node)
🗳 Compiling sysdump
✅ The sysdump has been saved to cilium-sysdump-20260901-0918.zip
```

Un sysdump contiene la política completa, todas las identidades, todos los endpoints y los flujos recientes — tratalo como **sensible**: expone toda tu topología de red y tu taxonomía de labels.

---

## 13. Decisiones de diseño a nivel de plataforma y sus consecuencias

| Decisión | Opción A | Opción B | Elegí A cuando | ¿Irreversible? |
|---|---|---|---|---|
| Backend de identidades | **CRD** (por defecto) | **kvstore (etcd)** | Querés cero infraestructura extra; clúster con menos de ~5k identidades | La migración es disruptiva |
| IPAM | **cluster-pool** | **kubernetes** / **ENI** / **azure** / **multi-pool** | Cilium debería ser dueño de la asignación de PodCIDR | Cambiar el modo de IPAM requiere recrear los pods |
| Enrutamiento | **native** | **tunnel** | El underlay enruta los CIDRs de pods; necesitás máximo throughput | Cambiarlo requiere un reinicio rodante + reprogramación de rutas |
| kube-proxy | **replacement=true** | coexistir | Kernel ≥ 5.x, querés DSR/Maglev/XDP | Quitar kube-proxy es fácil de revertir; habilitar el socket LB no está libre de sorpresas con algunos montajes de CNI encadenado |
| Sincronización de endpoints | `CiliumEndpoint` | **`CiliumEndpointSlice`** | ≥ ~5k pods, la carga de watch del apiserver importa | El cambio es seguro pero provoca una tormenta de resincronización |
| Cifrado | **WireGuard** | IPsec | Querés simplicidad operativa y nada de gestión de claves | Cambiar requiere un despliegue coordinado; el modo mixto está roto |
| Proxy L7 | **DaemonSet cilium-envoy** | (embebido, legacy) | Siempre, en ≥ 1.16 | — |
| Ancho del Cluster ID | `max-connected-clusters=255` | `511` | Nunca vas a superar los 255 clústeres | **Sí — debe ser idéntico en toda la malla, fijado en el momento de la instalación** |
| Retención de Hubble | métricas + exportación | sólo en memoria | Necesitás análisis forense post-incidente | — |

### 13.1 Requisitos mínimos de funcionalidades del kernel

| Funcionalidad | Kernel mínimo | Notas |
|---|---|---|
| Datapath base de Cilium | 4.19.57 | 5.10+ muy recomendado; 6.1+ preferido |
| eBPF host routing | 5.10 | Si no, cae a `Legacy` — verificá `Host Routing:` en el status |
| Masquerading eBPF | 4.19 | Necesita el reemplazo de kube-proxy |
| Socket LB (cgroup) | 4.19 | El arreglo de `getpeername()` necesita 5.x para corrección completa |
| Bandwidth Manager (EDT/fq) | 5.1 | |
| WireGuard | 5.6 | O el módulo wireguard |
| BBR para pods | 5.18 | |
| BIG TCP (IPv6/IPv4) | 5.19 / 6.3 | |
| Aceleración XDP nativa | depende del driver | No todos los drivers de NIC soportan XDP nativo |

---

## 14. Hoja de repaso crítica para el examen

**Puertos**

| Puerto | Componente |
|---|---|
| 4240/TCP | sondeos de nodo y endpoint de `cilium-health` |
| 4244/TCP | servidor Hubble (por agente, servicio peer) |
| 4245/TCP | Hubble Relay |
| 2379/TCP | etcd de `clustermesh-apiserver` |
| 8472/UDP | VXLAN |
| 6081/UDP | Geneve |
| 51871/UDP | WireGuard |
| 9962 / 9963 / 9964 / 9965 / 9966 | Prometheus: agente / operator / envoy / hubble (agente) / hubble-relay |
| 9879 | API de salud del agente (probes) |
| 9234 | API de salud del operator |

**Rutas**

| Ruta | Significado |
|---|---|
| `/sys/fs/bpf/tc/globals/` | mapas eBPF (bpffs) |
| `/run/cilium/cgroupv2` | montaje de cgroup v2 para el socket LB |
| `/var/run/cilium/state/<epID>/` | Cabeceras y objetos generados por endpoint |
| `/var/run/cilium/cilium.sock` | API REST del agente (usada por `cilium-dbg` y el plugin CNI) |
| `/var/run/cilium/hubble.sock` | Socket local de Hubble |
| `/var/run/cilium/envoy/sockets/` | Sockets de xDS, access-log y admin |
| `/opt/cni/bin/cilium-cni` | Binario del plugin CNI |
| `/etc/cni/net.d/05-cilium.conflist` | Configuración del CNI |

**Identidades reservadas:** `1 host`, `2 world`, `4 health`, `5 init`, `6 remote-node`, `7 kube-apiserver`, `8 ingress`.

**Dos CLIs, no los confundas:**
* `cilium` (cilium-cli) — corre **fuera** del clúster, habla con la API de Kubernetes. `cilium status`, `cilium install`, `cilium connectivity test`, `cilium sysdump`, `cilium clustermesh`.
* `cilium-dbg` — corre **dentro** del pod del agente, habla con el socket unix del agente. `cilium-dbg endpoint list`, `cilium-dbg bpf …`, `cilium-dbg monitor`, `cilium-dbg policy get`. (En Cilium ≤ 1.15 este binario dentro del pod se llamaba `cilium`; `cilium-dbg` es el nombre actual y `cilium` sigue existiendo como alias dentro del pod.)

**Resúmenes de una línea que responden la mayoría de las preguntas de arquitectura:**
* El agente programa el datapath; **no está sobre el datapath**. Matarlo no detiene el tráfico existente.
* El operator hace la contabilidad a nivel de clúster; **tampoco está sobre el datapath**.
* La política se aplica sobre la **identidad**, resuelta desde el **ipcache**, almacenada en **mapas de política por endpoint**.
* L7 significa **Envoy** (HTTP/gRPC/Kafka) o el **proxy DNS dentro del agente** (ToFQDN); todo lo demás se queda en eBPF.
* Hubble es un **ring buffer**, no almacenamiento.

---

## Referencias

- CNCF Cilium Certified Associate (CCA) curriculum — https://github.com/cncf/curriculum (raw: https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md)
- Cilium — Component Overview — https://docs.cilium.io/en/stable/overview/component-overview/
- Cilium — Introduction & Concepts — https://docs.cilium.io/en/stable/overview/intro/
- Cilium — eBPF Datapath — https://docs.cilium.io/en/stable/network/ebpf/
- Cilium — Life of a Packet — https://docs.cilium.io/en/stable/network/ebpf/lifeofapacket/
- Cilium — Security Identities & Terminology — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Cilium — Routing (Encapsulation & Native Routing) — https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium — Kubernetes Without kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Cilium — IPAM — https://docs.cilium.io/en/stable/network/concepts/ipam/
- Cilium — Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Cilium — Transparent Encryption (WireGuard / IPsec) — https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — Network Policy (CNP / CCNP) — https://docs.cilium.io/en/stable/security/policy/
- Cilium — Kubernetes CRD list — https://docs.cilium.io/en/stable/network/kubernetes/ciliumnetworkpolicy/
- Cilium — Hubble Overview — https://docs.cilium.io/en/stable/overview/intro/#what-is-hubble
- Cilium — Hubble Setup & Metrics — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium — Hubble Metrics Reference — https://docs.cilium.io/en/stable/observability/metrics/
- Cilium — Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
- Cilium — KVStoreMesh — https://docs.cilium.io/en/stable/network/clustermesh/kvstoremesh/
- Cilium — Envoy (L7 proxy) — https://docs.cilium.io/en/stable/security/network/proxy/envoy/
- Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium — System Requirements (kernel, ports) — https://docs.cilium.io/en/stable/operations/system_requirements/
- Cilium — Helm Reference (`values.yaml`) — https://docs.cilium.io/en/stable/helm-reference/
- Cilium — Command Reference (`cilium-dbg`) — https://docs.cilium.io/en/stable/cmdref/
- Cilium CLI (`cilium-cli`) — https://github.com/cilium/cilium-cli
- Cilium source: reserved identities — https://github.com/cilium/cilium/blob/main/pkg/identity/reserved.go
- Cilium source: eBPF datapath (`bpf/`) — https://github.com/cilium/cilium/tree/main/bpf
- eBPF documentation — https://ebpf.io/what-is-ebpf/
- Kubernetes — CNI Network Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Kubernetes — Service `kube-proxy` modes — https://kubernetes.io/docs/reference/networking/virtual-ips/
- kind — Cluster configuration — https://kind.sigs.k8s.io/docs/user/configuration/