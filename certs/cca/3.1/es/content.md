# 3.1 Redes de Kubernetes con Cilium

> **Plataforma de referencia para todos los comandos y manifiestos de este capítulo**
> Cilium `v1.16.5` (Helm chart `1.16.5`), Kubernetes `v1.31`, kernel `6.6` en los nodos, jerarquía unificada `cgroup v2`, `kube-proxy` **no instalado**.
> Donde un CRD o una clave de Helm cambió entre releases menores, se señala en línea. El formato de salida de la CLI depende de la versión: tratá las formas de abajo como canónicas para 1.16 y, en otras versiones, releé los campos, no las columnas.

---

## 1. El problema arquitectónico que esto resuelve

### 1.1 Qué exige realmente Kubernetes, y qué deja abierto

El modelo de red de Kubernetes tiene tres frases:

1. Cada Pod recibe su propia dirección IP.
2. Los Pods de un nodo pueden comunicarse con todos los Pods de todos los nodos **sin NAT**.
3. Los agentes de un nodo (kubelet, daemons del sistema) pueden alcanzar a todos los Pods de ese nodo.

Todo lo demás — cómo se asigna la IP, cómo cruza el paquete el cable, cómo un `ClusterIP` se convierte en un backend, cómo se aplica la política, cómo observás cualquiera de esas cosas — queda delegado a un plugin CNI. Kubernetes no incluye ningún datapath. `kube-proxy` tampoco es un datapath; es un controlador que *escribe* reglas en un datapath que el kernel ya tenía (`iptables` o `ipvs`).

Esa delegación es donde se rompen los clústers de producción, y se rompe en cuatro lugares distintos.

### 1.2 Modo de fallo 1 — `iptables` es una lista lineal, y los Services son un camino caliente

`kube-proxy` en modo `iptables` traduce cada Service a una cadena de reglas `KUBE-SERVICES`, y cada Service a una cadena `KUBE-SVC-*` que se abre estadísticamente hacia cadenas `KUBE-SEP-*`, una por endpoint. El kernel evalúa esas reglas **secuencialmente** por paquete hasta que una coincide.

Las consecuencias no son teóricas:

| Síntoma | Mecanismo |
|---|---|
| La latencia de conexión p99 crece con la cantidad total de Services, no con el tráfico hacia *tu* Service | Cada paquete recorre el mismo prefijo compartido `KUBE-SERVICES` |
| Un rollout de un Deployment degrada brevemente Services no relacionados | `iptables-restore` reescribe **toda la tabla** bajo el lock de `xtables`; no hay actualización incremental |
| La latencia de programación de endpoints llega a decenas de segundos con ~5k Services / ~20k endpoints | El número de reglas es `O(services × endpoints)`; la sincronización es un re-renderizado completo |
| Reiniciar el `kube-proxy` de un nodo corta conexiones en vuelo | El conjunto de reglas se reemplaza, no se parchea |

El modo `ipvs` arregla la complejidad de la búsqueda (tabla hash, `O(1)`) pero no el problema de propiedad: sigue viviendo fuera del CNI, sigue necesitando `iptables` para casos borde de masquerade/`nodePort`, y sigue indexando todo por direcciones IP.

### 1.3 Modo de fallo 2 — las direcciones IP son la primitiva de identidad equivocada

Una IP de Pod es válida durante la vida del Pod, que en un clúster sano son minutos. Cualquier control de seguridad indexado por IP persigue un blanco móvil:

- La política debe recalcularse en cada evento de rotación de Pods, y la ventana entre "IP reasignada" y "regla actualizada" es una **ventana de atribución errónea**: el tráfico se autoriza contra el inquilino anterior de esa dirección.
- Los logs de auditoría indexados por IP no se pueden correlacionar a posteriori a menos que hayas retenido el historial completo de IPAM.
- Los entornos multiclúster y cloud-native reutilizan CIDRs; la IP ni siquiera es globalmente única.

La respuesta de Cilium es la **identidad de seguridad**: un ID numérico de alcance clúster derivado de las *labels* del Pod, asignado una vez por conjunto distinto de labels y compartido por cada Pod que lleve ese conjunto. La política se compila a tuplas `(identity, port, protocol, direction)`. Un Pod reprogramado en otro nodo con una IP nueva conserva la misma identidad, y no ocurre ninguna recompilación de políticas.

### 1.4 Modo de fallo 3 — el paquete sale del kernel demasiadas veces

El camino heredado para un paquete Pod-a-Pod en el mismo nodo cruza el par veth, entra en el namespace de red del host, atraviesa `netfilter` `PREROUTING` → decisión de ruteo → `FORWARD` → `POSTROUTING`, y después baja por otro veth. Agregá un sidecar proxy y además cruzás la capa de sockets cuatro veces por salto.

eBPF le permite a Cilium enganchar programas en los puntos *más tempranos* del stack — `tc` `clsact` ingress/egress en cada dispositivo, `XDP` en el driver, y hooks de socket en `cgroup` — y usar `bpf_redirect_peer()` / `bpf_redirect_neigh()` para entregar el paquete directamente al dispositivo destino, salteando todo el recorrido de `netfilter` y ruteo del host.

### 1.5 Modo de fallo 4 — no podés ver nada de eso

Los contadores de `iptables -L -n -v` te dicen que se descartó un paquete. No te dicen *qué* workload, *por qué*, ni *contra qué* política. No hay registro consciente del protocolo ni exportación a nivel de flujo sin agregar un sidecar de service mesh o un sidecar de captura de paquetes. Cilium emite eventos estructurados desde el datapath (perf ring buffer → `cilium monitor` → Hubble) que llevan identidad de origen/destino, veredicto, motivo del descarte, y el archivo y la línea de origen del programa eBPF que tomó la decisión.

### 1.6 El intercambio que se está haciendo

eBPF no es gratis. Comprás:

- Latencia menor y **más plana** (independiente del tamaño del clúster).
- Política basada en identidad que sobrevive a la rotación de IPs.
- Política L3–L7, balanceo de carga, masquerade, cifrado y observabilidad en **un** datapath con un solo conjunto de mapas.

Pagás con:

- Un **piso duro de versión de kernel**. Las funcionalidades dependen de la capacidad del kernel, no de la versión de Cilium.
- Un datapath opaco para tu tooling existente — `tcpdump` en `eth0` no te va a mostrar una entrega por `bpf_redirect_peer()`, e `iptables -L` muestra una tabla casi vacía.
- El **dimensionado de mapas** BPF se vuelve una dimensión de planificación de capacidad que antes no tenías.
- Los reinicios del agente tienen un radio de impacto (proxy L7, proxy DNS) que los reinicios de `kube-proxy` no tenían.

---

## 2. La arquitectura de Cilium

### 2.1 Componentes del plano de control

| Componente | Tipo | Responsabilidad | Impacto ante fallo |
|---|---|---|---|
| `cilium-agent` | DaemonSet, `hostNetwork`, privilegiado | Observa K8s + CRDs, asigna identidades, compila y carga eBPF, puebla los mapas, ejecuta el control del proxy L7/DNS, sirve la API de salud + métricas | **El tráfico existente sigue fluyendo** — el datapath está en el kernel. Los Pods nuevos no obtienen red; la política deja de converger; el proxy DNS para políticas `toFQDNs` queda caído |
| `cilium-operator` | Deployment (2 réplicas, con elección de líder) | IPAM de alcance clúster (`cluster-pool`, ENI), recolección de basura de `CiliumIdentity`/`CiliumEndpoint`, generación de `CiliumEndpointSlice`, asignación de LB-IPAM, GC de Node/CRD de K8s | Los nodos nuevos no reciben PodCIDR; se acumulan identidades obsoletas; no se asignan IPs de LB. El tráfico existente no se ve afectado |
| plugin CNI `cilium` | Binario en el nodo, depositado por el init container del agente | Invocado por el runtime de contenedores en ADD/DEL de Pod; crea el par veth, llama a la API local del agente | Si falta o el socket del agente es inalcanzable, los Pods quedan en `ContainerCreating` |
| `cilium-envoy` | DaemonSet (**modo de despliegue por defecto desde 1.16**) | Proxy L7 para política HTTP/Kafka, Ingress, Gateway API, `CiliumEnvoyConfig` | El tráfico filtrado en L7 se rompe; L3/L4 no se ve afectado |
| `hubble-relay` | Deployment | Agrega los servidores gRPC de Hubble por nodo en una única API de flujos de alcance clúster | Solo observabilidad |
| `clustermesh-apiserver` | Deployment | Exporta identidades/endpoints/services locales a clústers remotos | El estado entre clústers deja de converger |

El **almacenamiento de identidades** es `crd` (por defecto — objetos `CiliumIdentity` en el API server) o `kvstore` (un etcd externo). El modo CRD elimina una dependencia pero pone la rotación de identidades sobre el API server; el modo `kvstore` escala más. Cilium 1.17 agrega un modo `doublewrite` para migrar entre ambos sin downtime.

### 2.2 El datapath: dónde se engancha cada programa

| Objeto eBPF | Enganche | Rol |
|---|---|---|
| `bpf_xdp.c` → `cil_xdp_entry` | XDP, driver nativo en el dispositivo físico | Búsqueda NodePort/LB pre-`skb`; forwarding DSR; prefiltro DDoS |
| `bpf_host.c` → `cil_from_netdev` / `cil_to_netdev` | `tc` ingress/egress en dispositivos físicos | LB norte-sur, masquerade eBPF, firewall de host, entrega al cifrado |
| `bpf_host.c` → `cil_from_host` / `cil_to_host` | `tc` en el par `cilium_host`/`cilium_net` | Camino host ↔ Pod, política de host |
| `bpf_lxc.c` → `cil_from_container` | `tc` ingress en cada veth `lxcXXXXX` | Adjunta la identidad de origen, política de **egress**, traducción de servicios, redirección |
| `bpf_lxc.c` → `cil_to_container` | `tc` egress en cada veth `lxcXXXXX` | Política de **ingress**, entrega dentro del Pod |
| `bpf_overlay.c` → `cil_from_overlay` / `cil_to_overlay` | `tc` en `cilium_vxlan` / `cilium_geneve` | Encapsulado/desencapsulado, extracción de identidad desde la cabecera del túnel |
| `bpf_sock.c` → `cil_sock4_connect`, `cil_sock4_sendmsg`, … | `cgroup/connect4`, `sendmsg4`, `recvmsg4`, `getpeername4` | **Socket LB**: traducción ClusterIP → backend en el momento de `connect()`, antes de que exista un paquete |
| `bpf_network.c` | `tc` en el dispositivo de cifrado | Restauración de identidad post-descifrado (IPsec) |

### 2.3 Los mapas que guardan todo el estado

```
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg map list --verbose
Name                       Num entries   Num errors   Cache enabled
cilium_lxc                 14            0            true
cilium_ipcache             318           0            true
cilium_policy_01204        27            0            true
cilium_ct4_global          8912          0            false
cilium_ct_any4_global      412           0            false
cilium_snat_v4_external    1044          0            false
cilium_lb4_services_v2     96            0            true
cilium_lb4_backends_v3     141           0            true
cilium_lb4_reverse_nat     96            0            true
cilium_lb4_maglev          31            0            false
cilium_tunnel_map          2             0            true
cilium_node_map            3             0            true
cilium_metrics             46            0            false
cilium_events              8             0            false
```

| Mapa | Clave → Valor | Perilla de dimensionado | Por qué importa en producción |
|---|---|---|---|
| `cilium_lxc` | IP de Pod → endpoint ID, identidad, MAC, ifindex | fijo 65 535 | Tabla de endpoints locales; un fallo de búsqueda significa "no es local, andá a ver en ipcache" |
| `cilium_ipcache` | CIDR/IP → identidad, tunnel endpoint, clave de cifrado, node ID | `bpf-map-dynamic-size-ratio` | La tabla **global** IP→identidad. Toda decisión remota la lee. Entradas obsoletas = veredicto de política incorrecto |
| `cilium_policy_<epID>` | (identity, port, proto, dir) → allow/deny + redirección L7 | `bpf.policyMapMax` (por defecto 16 384) | Por endpoint. Desbordamiento = la política silenciosamente no se puede programar; vigilá `cilium_bpf_map_pressure` |
| `cilium_ct4_global` | 5-tupla → estado de conexión, `RevNAT`, `SourceSecurityID` | `bpf-ct-global-tcp-max` (524 288), `bpf-ct-global-any-max` (262 144) | Lleno = se descartan las conexiones nuevas. El incidente de capacidad más común de todos |
| `cilium_snat_v4_external` | tupla NAT → traducción | `bpf-nat-global-max` | Estado del masquerade eBPF |
| `cilium_lb4_services_v2` | frontend (IP:port:proto, slot) → slot de backend / backend ID | `bpf-lb-map-max` (65 536) | Frontends de Service, una entrada por slot de backend |
| `cilium_lb4_backends_v3` | backend ID → IP:port, estado (`active`/`terminating`/`quarantined`) | igual | La terminación grácil vive acá |
| `cilium_lb4_maglev` | service ID → tabla de búsqueda de hash consistente | `maglev.tableSize` | `tableSize × services × 4` bytes de memoria. Presupuestalo |
| `cilium_tunnel_map` | PodCIDR remoto → IP de underlay del nodo | — | Solo se puebla en modo túnel |

### 2.4 El modelo de identidad

```
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg identity list
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
25478      k8s:app=frontend
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=prod
           k8s:io.cilium.k8s.policy.cluster=leloir-prod
           k8s:io.cilium.k8s.policy.serviceaccount=frontend
           k8s:io.kubernetes.pod.namespace=prod
31902      k8s:app=payments
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=prod
           k8s:io.cilium.k8s.policy.cluster=leloir-prod
           k8s:io.cilium.k8s.policy.serviceaccount=payments
           k8s:io.kubernetes.pod.namespace=prod
16777217   cidr:10.90.10.0/24
           reserved:world
```

Reglas que un SRE tiene que internalizar:

- Los IDs **1–255** están reservados. `world` (2) es "cualquier cosa fuera del clúster"; en dual-stack 1.16+ además vas a ver `reserved:world-ipv4` y `reserved:world-ipv6`.
- Los IDs **256–65535** son de alcance clúster, asignados por el operator/kvstore e idénticos en todos los nodos.
- Los IDs **≥ 16777216** (`1 << 24`) son identidades **locales al nodo**, usadas para selectores CIDR y FQDN. *No* se comparten entre nodos, y por eso una política cargada de `toCIDR` no hace explotar el espacio global de identidades — pero sí hace explotar el ipcache por nodo.
- Solo contribuyen las labels con prefijo `k8s:` que pasan el filtro de labels relevantes para la identidad. **Agregar una label de alta cardinalidad** (un SHA de commit, un pod-template-hash usado como selector, un timestamp) a los Pods crea una identidad por valor. Este es el clásico incidente de "explosión de identidades": `cilium_identity` trepa, el GC del operator se atrasa, y el tiempo de regeneración de endpoints se dispara en todo el clúster.

### 2.5 Recorridos del paquete

**A. Pod → Pod, mismo nodo, BPF host routing**

```
app socket ──(cgroup/connect4: cil_sock4_connect — if dest is a ClusterIP, rewrite to backend)
   │
   └─> pod eth0 ──> lxc1a2b3c [tc ingress: cil_from_container]
                        │ 1. source identity from cilium_lxc (this endpoint)
                        │ 2. dest identity from cilium_ipcache
                        │ 3. EGRESS policy lookup in cilium_policy_<srcEP>
                        │ 4. dest is local -> cilium_lxc hit
                        └─> bpf_redirect_peer() ───> dest pod eth0
                                                       [tc egress cil_to_container: INGRESS policy]
```

El namespace de red del host, `netfilter` y la tabla de ruteo del host **nunca se tocan**. `bpf_redirect_peer()` requiere kernel ≥ 5.10; sin él, Cilium cae de vuelta a `bpf_redirect()` hacia el stack del host (`bpf.hostLegacyRouting=true`).

**B. Pod → Pod, nodo remoto, modo túnel (VXLAN)**

```
lxc [cil_from_container: src identity, egress policy]
   │  ipcache lookup -> (dst identity=31902, tunnelendpoint=10.10.0.5)
   └─> cilium_vxlan [cil_to_overlay]
          encapsulate; tunnel_id (VNI) := SOURCE SECURITY IDENTITY   <-- identity travels in-band
   ═══ underlay UDP/8472 ═══>
       remote cilium_vxlan [cil_from_overlay]
          decap; read identity from tunnel_id
          cilium_lxc lookup for dst -> INGRESS policy -> deliver
```

La identidad se transporta **dentro de la cabecera del túnel**. El nodo receptor no necesita una entrada fresca de ipcache para la IP de origen para aplicar correctamente la política de ingress. Este es el argumento individual más fuerte a favor del modo túnel en un clúster con rotación rápida.

**C. Pod → Pod, nodo remoto, ruteo nativo**

Sin encapsulado. El nodo receptor debe derivar la identidad de origen buscando la **IP de origen** en su propio `cilium_ipcache`. Si ese nodo todavía no aprendió el Pod de origen (el agente recién se reinició, el watch de CRDs va atrasado), el origen resuelve a `reserved:world` y la política de ingress lo deniega. El ruteo nativo, entonces, cambia el overhead de encapsulado por una **dependencia de convergencia**.

El underlay también debe rutear los PodCIDRs. Tres formas de organizarlo:
- `autoDirectNodeRoutes: true` — Cilium instala rutas `<remote PodCIDR> via <remote nodeIP>`. Solo válido cuando **todos los nodos comparten un dominio L2**.
- BGP Control Plane — cada nodo peerea con el ToR y anuncia su propio PodCIDR.
- Cloud-native — IPAM de ENI/Azure, donde las IPs de Pod son direcciones reales de la VPC.

**D. Pod → externo (masquerade)**

```
lxc [cil_from_container: egress policy vs identity 2 (world) or a CIDR identity]
   └─> host routing -> eth0 [tc egress: cil_to_netdev]
          if dst NOT in ipv4NativeRoutingCIDR:
             eBPF SNAT to node IP, state in cilium_snat_v4_external
   ═══> internet
```

`ipv4NativeRoutingCIDR` es la definición de "interno". Equivocarse ahí es la causa del ticket "¿por qué el tráfico de mi Pod hacia la base de datos on-prem llega con la IP del nodo?".

**E. Externo → NodePort con DSR + XDP**

```
NIC driver [XDP: cil_xdp_entry]
   cilium_lb4_services_v2 lookup on (nodeIP:31080)
   backend is on ANOTHER node, mode=dsr:
      encode original client IP+port (Geneve TLV or IPv4 option)
      XDP_TX straight back out the NIC  <-- never allocates an skb
   ═══>  backend node decodes, delivers to Pod
         reply goes DIRECTLY to the client, source = the VIP
```

---

## 3. Decisiones de diseño y sus compromisos

### 3.1 Datapath de Services

| Dimensión | `kube-proxy` iptables | `kube-proxy` IPVS | Cilium eBPF (`kubeProxyReplacement: true`) |
|---|---|---|---|
| Complejidad de búsqueda | recorrido de reglas `O(n)` | hash `O(1)` | mapa hash `O(1)` |
| Modelo de actualización | Re-render completo de la tabla bajo el lock de `xtables` | netlink incremental | Escritura de una sola entrada de mapa |
| Latencia de programación de endpoints @5k svc | segundos → decenas de segundos | sub-segundo | milisegundos |
| Punto de traducción de ClusterIP | `PREROUTING`/`OUTPUT`, después de que el paquete existe | igual | **syscall `connect()`** (socket LB) — costo por paquete nulo para Pod→Service |
| Preservación de la IP de origen para tráfico externo | solo `externalTrafficPolicy: Local` | igual | DSR preserva la IP del cliente con política `Cluster` |
| Selección de backend | `statistic random` | rr/wrr/lc/sh | `random` o hashing consistente **Maglev** |
| Terminación grácil | El endpoint se elimina abruptamente | igual | Estado de backend `terminating`, las conexiones existentes drenan |
| Soporte de `hostPort` | vía el plugin CNI portmap | igual | nativo en los mapas de LB |
| Piso de kernel | cualquiera | ≥ 4.19 con módulos IPVS | ≥ 4.19.57 mínimo; **5.10+** en la práctica |
| Depurabilidad con tooling heredado | excelente | buena | pobre — tenés que usar `cilium-dbg` |

**Recomendación.** Reemplazo completo (`kubeProxyReplacement: true`) para cualquier clúster por encima de ~50 nodos o ~500 Services. Por debajo de eso, el costo operativo de recapacitarse en `cilium-dbg` puede superar al beneficio; usá `kubeProxyReplacement: false` y mantené `kube-proxy`.

> Nota sobre el valor de Helm: en 1.15 y anteriores esta clave tomaba `"strict" | "probe" | "partial" | "disabled"`. Desde **1.16** es un booleano `true|false`, con las funcionalidades individuales activadas por `nodePort.enabled`, `socketLB.enabled`, `externalIPs.enabled`, `hostPort.enabled`.

### 3.2 Modo de ruteo

| | VXLAN (`tunnel`) | Geneve (`tunnel`) | Nativo + `autoDirectNodeRoutes` | Nativo + BGP | Cloud ENI/Azure IPAM |
|---|---|---|---|---|---|
| El underlay debe conocer los PodCIDRs | **No** | **No** | Solo ARP/L2 | Sí, vía BGP | Sí, VPC-native |
| Overhead de MTU (bytes) | 50 | 50 (+ TLV) | 0 | 0 | 0 |
| Identidad transportada in-band | **Sí** (VNI) | **Sí** (TLV) | No — búsqueda en ipcache | No | No |
| Restricción de topología de nodos | ninguna (un underlay ruteado L3 está bien) | ninguna | **todos los nodos en un mismo segmento L2** | ninguna | ninguna |
| Throughput vs bare metal | ~85–92 % (según offload) | ~85–92 % | ~99 % | ~99 % | ~99 % |
| Costo de CPU | encap/decap por paquete | encap/decap por paquete | el más bajo | el más bajo | el más bajo |
| Involucramiento del equipo de redes | nulo | nulo | nulo | **requerido** | IAM del cloud |
| Funciona con dispatch DSR `opt` | necesita dispatch `geneve` | sí | sí | sí | sí |
| IP de Pod visible para la VPC/firewalls | no | no | sí | sí | sí |
| Límite de densidad de Pods | máscara del PodCIDR | máscara del PodCIDR | máscara del PodCIDR | máscara del PodCIDR | **cuota de ENI/IP por tipo de instancia** |

**Recomendación.**
- Underlay desconocido u hostil, multi-AZ, rotación rápida de nodos, sin acceso al equipo de redes → **VXLAN**. La identidad in-band por sí sola elimina toda una clase de fallos transitorios de política.
- Controlás el fabric y necesitás velocidad de línea o IPs de Pod visibles para firewalls externos → **nativo + BGP**.
- Geneve sobre VXLAN solo cuando necesitás funcionalidades específicas de Geneve (dispatch DSR Geneve en modo túnel, o transporte de opciones para SRv6/HA del egress-gateway).
- El modo ENI del cloud te da IPs reales de la VPC e integración con security groups, al precio de un techo duro de Pods por nodo determinado por el tipo de instancia.

### 3.3 Aritmética de MTU — equivocarte acá te da un cuelgue intermitente, no una caída

| MTU del underlay | Modo | MTU efectiva del Pod | Fórmula |
|---|---|---|---|
| 1500 | nativo | 1500 | — |
| 1500 | VXLAN | 1450 | −50 (IP externo 20 + UDP 8 + VXLAN 8 + Eth interno 14) |
| 1500 | Geneve (sin opciones) | 1450 | −50 |
| 1500 | Geneve + DSR TLV | 1442 o menos | −50 −8 por opción |
| 1500 | nativo + WireGuard | 1420 | −80 |
| 1500 | VXLAN + WireGuard | 1370 | −50 −80 |
| 9000 (jumbo) | VXLAN | 8950 | −50 |

Cilium autodetecta la MTU del dispositivo y calcula la MTU de la ruta. **No puede** detectar un cuello de botella de MTU a tres saltos de distancia en tu underlay. Fijala explícitamente con el valor Helm `MTU` cuando tu path MTU no es la MTU del dispositivo local.

### 3.4 Balanceo de carga norte-sur

| | SNAT | DSR | Híbrido (`mode: hybrid`) |
|---|---|---|---|
| IP del cliente preservada en el backend | No | **Sí** | TCP: sí / UDP: no |
| Camino de retorno | vía el nodo de ingreso | directo desde el backend | mixto |
| Costo de salto extra | 1 | 0 | TCP: 0 |
| Requiere ruteo simétrico en el fabric | no | **sí** (o la respuesta la descartan uRPF/firewalls con estado) | para TCP |
| Impacto en la MTU | ninguno | `opt`: cabecera +8/+24; `geneve`: +50 | mixto |
| Funciona detrás de un LB de cloud con estado | sí | usualmente no | parcialmente |

`loadBalancer.dsrDispatch: opt` embebe la dirección del cliente en una opción IPv4 / cabecera de extensión IPv6 — barato, pero algunos switches y middleboxes descartan o pasan por slow-path los paquetes con opciones. El dispatch `geneve` encapsula en su lugar: más overhead, mucho más robusto, y el único dispatch DSR que funciona en modo túnel.

**Selección de backend:** `random` es sin estado y barato. `maglev` da hashing consistente, de modo que agregar o quitar un backend re-mapea solo ~`1/N` de los flujos y — crítico — cada nodo computa la **misma** tabla, así que un cliente que aterriza en un nodo de ingreso distinto igual llega al mismo backend. Requerido para DSR con `externalTrafficPolicy: Cluster` si te importa la estabilidad de los flujos. Costo: `tableSize × numServices × 4` bytes por nodo. `65521` primos × 500 servicios ≈ 131 MB. Usá `16381` salvo que tengas muchos backends por servicio.

### 3.5 Cifrado

| | IPsec (ESP) | WireGuard |
|---|---|---|
| Gestión de claves | rotás un Secret de K8s; las claves son de alcance clúster | par de claves por nodo, autogenerado, distribuido automáticamente vía `CiliumNode` |
| Throughput | mayor con AES-NI + offload por hardware | bueno, pero limitado por CPU (ChaCha20-Poly1305) |
| Requisito de kernel | stack XFRM | ≥ 5.6 (o el módulo `wireguard`) |
| Cifra | Pod-a-Pod; nodo-a-nodo con configuración extra | Pod-a-Pod; **todo** el tráfico de nodo con `nodeEncryption: true` |
| Identidad tras el descifrado | restaurada vía `bpf_network.c` + mapeo de SPI | restaurada vía ipcache |
| Modo de fallo operativo | la rotación de claves es un baile en dos fases; un SPI obsoleto descarta silenciosamente | desajuste de claves de peer → el flujo simplemente no se establece |
| Historia FIPS | madura | no validado por FIPS |
| Costo de MTU | ~56–80 B (según el cifrador) | 80 B |

**Recomendación.** WireGuard, salvo que un régimen de cumplimiento nombre a IPsec. La ergonomía de rotación de claves domina la diferencia de throughput en la práctica.

### 3.6 IPAM

| Modo | Quién asigna | IPs de Pod ruteables en la VPC | Techo de densidad | Usalo cuando |
|---|---|---|---|---|
| `cluster-pool` (por defecto) | el operator talla un `/24` por nodo desde un CIDR de clúster | no | 254/nodo | Por defecto. On-prem, kind, donde sea que seas dueño del CIDR |
| `kubernetes` | kube-controller-manager escribe `node.spec.podCIDR` | no | depende de la máscara | Ya corrés `--allocate-node-cidrs` y querés que Cilium lo siga |
| `multi-pool` | CRDs `CiliumPodIPPool`, selección por namespace/por pod | no | por pool | Clústers multi-tenant que necesitan CIDRs distintos por tenant para firewalls externos |
| `eni` / `azure` / `alibabacloud` | el operator adjunta ENIs / asigna IPs secundarias | **sí** | cuota de la instancia | Necesitás integración con SG o IPs de Pod visibles en la VPC |
| `crd` | vos, vía `CiliumNode.spec.ipam` | depende | — | Controlador de IPAM propio |

---

## 4. Infraestructura completa y manifiestos

### 4.1 Clúster de laboratorio reproducible (kind, sin kube-proxy, sin CNI por defecto)

`kind-cca.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Cilium is the CNI; kind must not install kindnet.
  disableDefaultCNI: true
  # Cilium replaces kube-proxy entirely.
  kubeProxyMode: none
  podSubnet: "10.20.0.0/14"
  serviceSubnet: "10.96.0.0/16"
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=a,egress-gw=true"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=b"
```

```bash
$ kind create cluster --config kind-cca.yaml
Creating cluster "cca-lab" ...
 ✓ Ensuring node image (kindest/node:v1.31.2) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cca-lab"

$ kubectl get nodes
NAME                   STATUS     ROLES           AGE   VERSION
cca-lab-control-plane  NotReady   control-plane   41s   v1.31.2
cca-lab-worker         NotReady   <none>          22s   v1.31.2
cca-lab-worker2        NotReady   <none>          22s   v1.31.2
```

`NotReady` es esperado y correcto: todavía no hay CNI, así que el kubelet reporta `NetworkReady=false`.

### 4.2 Valores Helm de producción — ruteo nativo + BGP + reemplazo de kube-proxy

`values-prod.yaml` (completo, sin nada omitido):

```yaml
# ---------------------------------------------------------------------------
# Cluster identity. `cluster.id` MUST be unique across every cluster that will
# ever join the same ClusterMesh; it is encoded into the identity space.
# ---------------------------------------------------------------------------
cluster:
  name: leloir-prod
  id: 1

# ---------------------------------------------------------------------------
# Full kube-proxy replacement. k8sServiceHost/Port are mandatory: with no
# kube-proxy, the agent cannot reach the API server through the `kubernetes`
# ClusterIP before it has programmed that ClusterIP itself (chicken and egg).
# ---------------------------------------------------------------------------
kubeProxyReplacement: true
k8sServiceHost: api.leloir.internal
k8sServicePort: 6443

nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true
socketLB:
  enabled: true
  # false => socket LB also applies inside pod netns (recommended).
  # true  => only host-namespace sockets, needed for some service meshes.
  hostNamespaceOnly: false

# ---------------------------------------------------------------------------
# Datapath: native routing. The underlay learns PodCIDRs via BGP (see 4.4),
# so autoDirectNodeRoutes stays OFF (nodes are not all on one L2 segment).
# ---------------------------------------------------------------------------
routingMode: native
ipv4NativeRoutingCIDR: "10.20.0.0/14"
autoDirectNodeRoutes: false
directRoutingDevice: "eth0"
devices: "eth0"

ipv4:
  enabled: true
ipv6:
  enabled: false

enableIPv4Masquerade: true
enableIPv6Masquerade: false

# Explicit MTU: our path MTU is 1500 even though some nodes have 9000 NICs.
MTU: 1500

# ---------------------------------------------------------------------------
# IPAM
# ---------------------------------------------------------------------------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.20.0.0/14"
    # /24 per node => 254 usable pod IPs per node, 1024 nodes max.
    clusterPoolIPv4MaskSize: 24

# ---------------------------------------------------------------------------
# eBPF datapath tuning
# ---------------------------------------------------------------------------
bpf:
  # eBPF masquerading in cil_to_netdev; removes the iptables MASQUERADE rules.
  masquerade: true
  # false => BPF host routing (bpf_redirect_peer). Requires kernel >= 5.10.
  hostLegacyRouting: false
  # Pre-allocate map memory at load time: predictable latency, higher RSS.
  preallocateMaps: true
  # Transparent proxy via TPROXY for L7/DNS redirects.
  tproxy: true
  # Per-endpoint policy map. Raise if you have many distinct peer identities.
  policyMapMax: 32768
  # Sizes CT/NAT/neigh maps as a ratio of total node memory.
  mapDynamicSizeRatio: 0.0025
  # Do not translate ClusterIP for traffic originating outside the cluster.
  lbExternalClusterIP: false

# Explicit conntrack ceilings; leave unset to let mapDynamicSizeRatio decide.
bpfClockProbe: true

# ---------------------------------------------------------------------------
# Load balancing
# ---------------------------------------------------------------------------
loadBalancer:
  algorithm: maglev
  mode: hybrid                # TCP -> DSR, UDP -> SNAT
  dsrDispatch: geneve         # robust across middleboxes; costs 50B MTU
  acceleration: native        # XDP on the driver; requires a supported NIC
  serviceTopology: true       # honour topology-aware hints

maglev:
  # Must be prime. 65521 * numServices * 4 bytes of memory per node.
  tableSize: 65521
  # Same seed on every cluster in a mesh so tables agree. Generate with:
  #   head -c12 /dev/urandom | base64 -w0
  hashSeed: "JLfvgnHc2kaSUFaI"

# ---------------------------------------------------------------------------
# BGP control plane (configuration lives in CRDs, see 4.4)
# ---------------------------------------------------------------------------
bgpControlPlane:
  enabled: true

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------
encryption:
  enabled: true
  type: wireguard
  # true also encrypts node-to-node (host) traffic. Costs CPU; verify with
  # `cilium-dbg encrypt status` before enabling in a latency-sensitive fleet.
  nodeEncryption: false
  wireguard:
    persistentKeepalive: 0s

# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------
policyEnforcementMode: default   # default | always | never
policyAuditMode: false
hostFirewall:
  enabled: true

l7Proxy: true
envoy:
  enabled: true                  # standalone DaemonSet (default since 1.16)

egressGateway:
  enabled: true

localRedirectPolicy: true

dnsProxy:
  enableTransparentMode: true
  minTtl: 3600
  maxDeferredConnectionDeletes: 10000
  endpointMaxIpPerHostname: 50

# ---------------------------------------------------------------------------
# Identity & scale
# ---------------------------------------------------------------------------
identityAllocationMode: crd
# Collapses N CiliumEndpoint watches into far fewer CiliumEndpointSlice
# watches. Mandatory above ~5k pods.
enableCiliumEndpointSlice: true

k8sClientRateLimit:
  qps: 50
  burst: 100

# ---------------------------------------------------------------------------
# Bandwidth manager (EDT-based egress shaping + BBR)
# ---------------------------------------------------------------------------
bandwidthManager:
  enabled: true
  bbr: true

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
hubble:
  enabled: true
  # Ring buffer size per node. 4095 flows at 60 flows/s is ~68 seconds of
  # history — export to a collector, do not rely on the buffer.
  eventBufferCapacity: 16383
  metrics:
    enabled:
      - "dns:query;ignoreAAAA"
      - "drop"
      - "tcp"
      - "flow"
      - "port-distribution"
      - "icmp"
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: true
  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
  ui:
    enabled: true
    replicas: 1

prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true

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
      memory: 512Mi

# ---------------------------------------------------------------------------
# Agent lifecycle
# ---------------------------------------------------------------------------
rollOutCiliumPods: true
cni:
  # Remove any other CNI config files from /etc/cni/net.d. Prevents the
  # classic "two CNIs installed, pods get IPs from the wrong one" incident.
  exclusive: true
  logFile: /var/run/cilium/cilium-cni.log

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    memory: 4Gi

# Set to the version you are upgrading FROM so the chart keeps datapath
# compatibility defaults during a rolling upgrade. Remove after the upgrade.
upgradeCompatibility: "1.15"

annotateK8sNode: false
```

Instalación:

```bash
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm upgrade --install cilium cilium/cilium \
    --version 1.16.5 \
    --namespace kube-system \
    --values values-prod.yaml \
    --wait --timeout 10m
Release "cilium" does not exist. Installing it now.
NAME: cilium
LAST DEPLOYED: Tue Sep  1 13:41:02 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

### 4.3 Datapath alternativo: modo túnel (opción portable por defecto)

Reemplazá el bloque de ruteo de arriba por:

```yaml
routingMode: tunnel
tunnelProtocol: vxlan     # or: geneve
tunnelPort: 8472          # 6081 for geneve
ipv4NativeRoutingCIDR: ""  # not used in tunnel mode
autoDirectNodeRoutes: false
directRoutingDevice: ""
# DSR opt-dispatch is not available in tunnel mode; use geneve dispatch
# or fall back to SNAT.
loadBalancer:
  algorithm: maglev
  mode: snat
  acceleration: disabled
MTU: 0                    # let Cilium subtract the 50-byte tunnel overhead
```

### 4.4 BGP Control Plane (API v2)

> Nota sobre la API: en **1.16** estos CRDs son `cilium.io/v2alpha1`. En 1.17+ se gradúan a `cilium.io/v2`. El objeto único heredado `CiliumBGPPeeringPolicy` (también `v2alpha1`) está deprecado — no mezcles los dos en el mismo nodo.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: leloir-tor
spec:
  nodeSelector:
    matchLabels:
      bgp-role: tor-peer
  bgpInstances:
    - name: instance-65001
      localASN: 65001
      # Router ID is derived from the node IP unless overridden per node with
      # a CiliumBGPNodeConfigOverride.
      peers:
        - name: tor-a
          peerASN: 65000
          peerAddress: 192.168.178.2
          peerConfigRef:
            name: tor-peer-config
        - name: tor-b
          peerASN: 65000
          peerAddress: 192.168.178.3
          peerConfigRef:
            name: tor-peer-config
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer-config
spec:
  # Aggressive timers: a dead ToR must be detected in single-digit seconds,
  # otherwise the fabric blackholes pod traffic for up to 90s.
  timers:
    connectRetryTimeSeconds: 12
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  # Survive a cilium-agent restart without withdrawing routes.
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  ebgpMultihop: 1
  authSecretRef: bgp-tor-md5      # Secret in kube-system with key "password"
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: leloir-prod
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: leloir-prod-advertisements
  labels:
    advertise: leloir-prod
spec:
  advertisements:
    # Each node advertises only the PodCIDR the operator gave it.
    - advertisementType: PodCIDR
      attributes:
        communities:
          standard: ["65000:100"]
    # LoadBalancer VIPs, /32, advertised by every node that has a local
    # backend when externalTrafficPolicy=Local (ECMP anycast otherwise).
    - advertisementType: Service
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          bgp-advertise: "true"
      attributes:
        communities:
          standard: ["65000:200"]
        localPreference: 200
---
apiVersion: v1
kind: Secret
metadata:
  name: bgp-tor-md5
  namespace: kube-system
type: Opaque
stringData:
  password: "replace-me-with-a-real-secret"
```

### 4.5 LB-IPAM y un Service anunciado

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: prod-vips
spec:
  blocks:
    - cidr: "192.168.180.0/24"
    - start: "192.168.181.10"
      stop: "192.168.181.60"
  serviceSelector:
    matchLabels:
      io.kubernetes.service.namespace: prod
  # Reserve network and broadcast addresses of each block.
  allowFirstLastIPs: "No"
  disabled: false
---
apiVersion: v1
kind: Service
metadata:
  name: storefront
  namespace: prod
  labels:
    bgp-advertise: "true"
  annotations:
    # Request a specific VIP out of the pool (optional).
    lbipam.cilium.io/ips: "192.168.180.42"
    # Restrict which pools may serve this service.
    lbipam.cilium.io/sharing-key: "storefront-shared"
spec:
  type: LoadBalancer
  # Local preserves the client IP and makes BGP advertise the VIP only from
  # nodes that actually run a backend — no extra hop, no blackhole.
  externalTrafficPolicy: Local
  loadBalancerSourceRanges:
    - "192.168.0.0/16"
    - "10.0.0.0/8"
  selector:
    app: storefront
  ports:
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
```

### 4.6 IPAM multi-pool (PodCIDRs por tenant)

Requiere `ipam.mode: multi-pool` en los valores de Helm.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: tenant-payments
spec:
  ipv4:
    cidrs:
      - "10.30.0.0/16"
    # /27 = 30 usable addresses per node from this pool.
    maskSize: 27
---
apiVersion: v1
kind: Pod
metadata:
  name: ledger-writer
  namespace: prod
  annotations:
    ipam.cilium.io/ip-pool: "tenant-payments"
spec:
  containers:
    - name: app
      image: ghcr.io/example/ledger-writer:1.4.2
      ports:
        - containerPort: 8080
```

### 4.7 Egress Gateway — una IP de origen estable para un firewall heredado

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-to-legacy-erp
spec:
  # Which pods' traffic is redirected.
  selectors:
    - podSelector:
        matchLabels:
          io.kubernetes.pod.namespace: prod
          app: payments
  # Only traffic to these destinations is redirected.
  destinationCIDRs:
    - "10.90.10.0/24"
  # Carve-outs that must keep the normal path (e.g. the on-prem resolver).
  excludedCIDRs:
    - "10.90.10.53/32"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gw: "true"
    # SNAT to the address configured on this interface of the gateway node.
    interface: eth1
```

Prerrequisitos: `egressGateway.enabled: true`, `bpf.masquerade: true`, `kubeProxyReplacement: true`. El nodo gateway es un **punto único de fallo y un cuello de botella de ancho de banda** — etiquetá a lo sumo un conjunto pequeño y dedicado de nodos y monitoreá la saturación de sus NICs.

### 4.8 Gestión de ancho de banda y redirección de DNS local al nodo

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-shipper
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: log-shipper
  template:
    metadata:
      labels:
        app: log-shipper
      annotations:
        # EDT-based shaping in the eBPF datapath, enforced at the source.
        kubernetes.io/egress-bandwidth: "50M"
    spec:
      containers:
        - name: shipper
          image: ghcr.io/example/log-shipper:2.9.0
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
---
# Transparently steer every pod's DNS traffic to a node-local cache without
# changing a single pod's /etc/resolv.conf.
apiVersion: cilium.io/v2
kind: CiliumLocalRedirectPolicy
metadata:
  name: nodelocaldns
  namespace: kube-system
spec:
  redirectFrontend:
    serviceMatcher:
      serviceName: kube-dns
      namespace: kube-system
  redirectBackend:
    localEndpointSelector:
      matchLabels:
        k8s-app: node-local-dns
    toPorts:
      - port: "53"
        name: dns
        protocol: UDP
      - port: "53"
        name: dns-tcp
        protocol: TCP
```

### 4.9 Política: L3/L4, egress consciente de DNS, HTTP L7 y firewall de host

```yaml
---
# Default-deny for the namespace. An empty ingress AND egress array selects
# everything and allows nothing — this is what "switches on" enforcement.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: prod
spec:
  description: "Default deny both directions for every pod in prod."
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-egress
  namespace: prod
spec:
  description: >-
    payments may resolve a restricted DNS namespace, call the ledger's write
    API only with POST, reach one external SaaS by FQDN, and talk to the
    apiserver. Nothing else.
  endpointSelector:
    matchLabels:
      app: payments
  egress:
    # 1. DNS, via the L7 DNS proxy. This rule is what populates the toFQDNs
    #    cache below; without it, toFQDNs can never match anything.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*.prod.svc.cluster.local"
              - matchPattern: "*.kube-system.svc.cluster.local"
              - matchName: "api.stripe.com"

    # 2. External SaaS by name. Cilium learns the IPs from the DNS proxy above
    #    and injects them as local CIDR identities into cilium_ipcache.
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # 3. East-west with L7 HTTP enforcement (redirected to Envoy).
    - toEndpoints:
        - matchLabels:
            app: ledger
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/entries"
                headers:
                  - "X-Tenant: .*"
              - method: "GET"
                path: "/healthz"

    # 4. The apiserver, via the reserved identity — survives control-plane
    #    IP changes, unlike a hand-written toCIDR.
    - toEntities:
        - kube-apiserver
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-ingress
  namespace: prod
spec:
  endpointSelector:
    matchLabels:
      app: payments
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    # Allow the cluster-internal health checker and Prometheus.
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
    - fromEntities:
        - health
---
# Host firewall. READ THE WARNING BELOW BEFORE APPLYING THIS.
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: host-lockdown-workers
spec:
  description: "Restrict what may reach the worker nodes' host namespace."
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Cluster-internal machinery: other nodes, health checks, VXLAN/WireGuard.
    - fromEntities:
        - remote-node
        - health
        - cluster
    # kubelet and metrics from the control plane and monitoring only.
    - fromEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP
    # SSH from the bastion subnet only.
    - fromCIDR:
        - "192.168.178.0/24"
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP
    # NodePort range from the load-balancer tier.
    - fromCIDR:
        - "192.168.179.0/24"
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
```

> **Advertencia sobre el firewall de host.** Una `CiliumClusterwideNetworkPolicy` con un `nodeSelector` pone el endpoint `reserved:host` del nodo en modo de aplicación. Omití SSH, el puerto del kubelet o los puertos de túnel/WireGuard y te dejás afuera del nodo sin ningún camino de recuperación in-band. Siempre escalonalo:
> ```bash
> $ HOST_EP=$(kubectl exec -n kube-system ds/cilium -- \
>     cilium-dbg endpoint list -o jsonpath='{[?(@.status.identity.id==1)].id}')
> $ kubectl exec -n kube-system ds/cilium -- \
>     cilium-dbg endpoint config $HOST_EP PolicyAuditMode=Enabled
> Endpoint 3129 configuration updated successfully
> ```
> Dejalo correr un ciclo de negocio completo, leé cada flujo `policy-verdict ... AUDITED` en Hubble, y recién ahí desactivá el modo auditoría.

### 4.10 Workloads de prueba

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    kubernetes.io/metadata.name: prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: curl
          image: quay.io/curl/curl:8.11.0
          command: ["sleep", "infinity"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
        - name: server
          image: quay.io/cilium/json-mock:v1.3.8
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: prod
spec:
  selector:
    app: payments
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

---

## 5. Verificación: probar que el datapath es el que creés

### 5.1 Salud a nivel de clúster (`cilium-cli`)

```bash
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 3
                       cilium-envoy             Running: 3
                       cilium-operator          Running: 2
                       hubble-relay             Running: 2
                       hubble-ui                Running: 1
Cluster Pods:          47/47 managed by Cilium
Helm chart version:    1.16.5
Image versions         cilium           quay.io/cilium/cilium:v1.16.5: 3
                       cilium-envoy     quay.io/cilium/cilium-envoy:v1.30.8: 3
                       cilium-operator  quay.io/cilium/operator-generic:v1.16.5: 2
                       hubble-relay     quay.io/cilium/hubble-relay:v1.16.5: 2
```

`Cluster Pods: 47/47 managed by Cilium` es la línea que importa. Cualquier cosa menor significa que existen Pods para los que Cilium no creó endpoints — normalmente restos de un CNI anterior, o Pods con `hostNetwork` (que están correctamente excluidos).

### 5.2 Configuración del datapath por nodo

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg status --verbose
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:         ["cilium/v2::CiliumClusterwideNetworkPolicy", "cilium/v2::CiliumEgressGatewayPolicy", "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy", "cilium/v2::CiliumNode", "core::Namespace", "core::Pods", "core::Service", "discovery::EndpointSlice", "networking.k8s.io::NetworkPolicy"]
KubeProxyReplacement:    True   [eth0   10.10.0.4 (Direct Routing)]
Host firewall:           Enabled   [eth0]
SRv6:                    Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.16.5 (v1.16.5-b7b9a3d2)
NodeMonitor:             Listening for events on 16 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 14/254 allocated from 10.20.1.0/24,
IPv4 BIG TCP:            Disabled
BandwidthManager:        EDT with BPF [BBR] [eth0]
Routing:                 Network: Native   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.20.0.0/14 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       61/61 healthy
Proxy Status:            OK, ip 10.20.1.204, 2 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 214.77   Metrics: Ok
Encryption:              Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: 9pS1n+..., Port: 51871, Peers: 2)]
Cluster health:          3/3 reachable   (2026-09-01T14:02:44Z)
Modules Health:          Stopped(0) Degraded(0) OK(118)

KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0 10.10.0.4 (Direct Routing)
  Mode:                   Hybrid
  Backend Selection:      Maglev (Table Size: 65521)
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Native
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

Las cinco líneas que leés primero, siempre:

| Línea | Qué prueba | Bandera roja |
|---|---|---|
| `KubeProxyReplacement: True [eth0 ... (Direct Routing)]` | El LB eBPF está activo en el dispositivo correcto | `False`, o el dispositivo listado es el equivocado |
| `Routing: Network: Native Host: BPF` | Tanto la decisión de red como la de ruteo de host coinciden con tu intención | `Host: Legacy` cuando configuraste `hostLegacyRouting: false` (kernel demasiado viejo) |
| `Masquerading: BPF [eth0] 10.20.0.0/14` | El SNAT está en eBPF y el CIDR "interno" es el que fijaste | `Masquerading: IPTables` |
| `Controller Status: 61/61 healthy` | Ningún reconciliador en segundo plano está trabado | cualquier `N/M` donde `N < M` |
| `Cluster health: 3/3 reachable` | El endpoint de salud de cada nodo responde tanto por el túnel como por el camino directo | `2/3` → corré `cilium-dbg status --all-health` |

Configuración efectiva en runtime, después de fusionar todo Helm/ConfigMap/flags:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg config --all | \
    grep -E 'enable-bpf-masquerade|routing-mode|kube-proxy-replacement|bpf-lb-mode|bpf-lb-algorithm|enable-host-firewall|enable-wireguard'
bpf-lb-algorithm                          maglev
bpf-lb-mode                               hybrid
enable-bpf-masquerade                     true
enable-host-firewall                      true
enable-wireguard                          true
kube-proxy-replacement                    true
routing-mode                              native
```

### 5.3 Endpoints, identidades, ipcache

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
187        Disabled           Disabled          4          reserved:health                                                 10.20.1.31   ready
1204       Enabled            Enabled           31902      k8s:app=payments                                                10.20.1.88   ready
                                                           k8s:io.cilium.k8s.policy.cluster=leloir-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=payments
                                                           k8s:io.kubernetes.pod.namespace=prod
2361       Enabled            Enabled           25478      k8s:app=frontend                                                10.20.1.113  ready
                                                           k8s:io.cilium.k8s.policy.cluster=leloir-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=frontend
                                                           k8s:io.kubernetes.pod.namespace=prod
3129       Enabled            Disabled          1          reserved:host                                                                ready
```

Leelo como una tabla de tres hechos por fila: **si la política se aplica**, **qué identidad**, **si el endpoint está `ready`**. Un endpoint trabado en `regenerating` durante más de unos pocos segundos es un problema de compilación de políticas; revisá `cilium-dbg endpoint get <id>` y el log del agente.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ipcache list | head -12
IP PREFIX/ADDRESS   IDENTITY
10.10.0.3/32        identity=6 encryptkey=3 tunnelendpoint=0.0.0.0 nodeid=0x0e11
10.10.0.4/32        identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.10.0.5/32        identity=6 encryptkey=3 tunnelendpoint=0.0.0.0 nodeid=0x2a7c
10.20.1.31/32       identity=4 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.1.88/32       identity=31902 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.1.113/32      identity=25478 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.2.19/32       identity=25478 encryptkey=3 tunnelendpoint=10.10.0.5 nodeid=0x2a7c
10.20.2.44/32       identity=31902 encryptkey=3 tunnelendpoint=10.10.0.5 nodeid=0x2a7c
0.0.0.0/0           identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
```

`tunnelendpoint=0.0.0.0` en IPs de Pods remotos es *correcto* en ruteo nativo y *un indicador de bug* en modo túnel. `encryptkey=3` en las entradas remotas confirma que se espera WireGuard para ese peer.

### 5.4 Balanceo de carga de Services

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg service list
ID   Frontend                Service Type   Backend
1    10.96.0.1:443/TCP       ClusterIP      1 => 10.10.0.3:6443 (active)
12   10.96.0.10:53/UDP       ClusterIP      1 => 10.20.1.7:53 (active)
                                            2 => 10.20.2.9:53 (active)
14   10.96.0.10:53/TCP       ClusterIP      1 => 10.20.1.7:53 (active)
                                            2 => 10.20.2.9:53 (active)
31   10.96.214.7:8080/TCP    ClusterIP      1 => 10.20.1.88:8080 (active)
                                            2 => 10.20.2.44:8080 (active)
44   192.168.180.42:443/TCP  LoadBalancer   1 => 10.20.1.51:8443 (active)
                                            2 => 10.20.2.62:8443 (terminating)
45   10.10.0.4:31080/TCP     NodePort       1 => 10.20.1.51:8443 (active)

$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf lb list --frontends | grep 10.96.214.7
10.96.214.7:8080/TCP (0)   0.0.0.0:0 (31) (0) [ClusterIP, non-routable]
10.96.214.7:8080/TCP (1)   10.20.1.88:8080 (31) (1)
10.96.214.7:8080/TCP (2)   10.20.2.44:8080 (31) (2)
```

El slot `(0)` es la entrada maestra que guarda la cantidad de backends y los flags; los slots `1..N` son los backends. Un frontend con el slot 0 presente y **sin** slots de backend es el clásico caso "el Service existe, el EndpointSlice está vacío".

**Probar que el socket LB está haciendo la traducción** — el paquete *nace* con la dirección del backend, así que `tcpdump` dentro del Pod nunca muestra el ClusterIP:

```bash
$ kubectl -n prod exec deploy/frontend -- curl -s -o /dev/null -w '%{remote_ip}\n' http://payments.prod.svc:8080/
10.20.2.44
```

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf sock list | head -5
Cookie   Backend ID   Service ID   Backend Address    Service Address
32418    2            31           10.20.2.44:8080    10.96.214.7:8080
32419    1            12           10.20.1.7:53       10.96.0.10:53
```

### 5.5 Confirmar que los programas eBPF están enganchados donde esperás

```bash
$ kubectl exec -n kube-system ds/cilium -- bpftool net show dev eth0
xdp:
eth0(2) driver id 1841

tc:
eth0(2) tcx/ingress cil_from_netdev prog_id 1802 link_id 41
eth0(2) tcx/egress cil_to_netdev prog_id 1809 link_id 42

flow_dissector:

netfilter:
```

`driver id` bajo `xdp:` significa XDP **nativo**. Si dice `generic id`, el driver de la NIC no soporta XDP y estás corriendo el fallback lento en modo `skb` — `loadBalancer.acceleration: native` se degradó silenciosamente. `tcx/` (en vez de `clsact/`) indica el modo de enganche moderno TCX, disponible en kernel ≥ 6.6 y reportado por `Attach Mode: TCX` en `cilium-dbg status`.

```bash
$ kubectl exec -n kube-system ds/cilium -- bpftool prog show | grep -c cil_
34

$ kubectl exec -n kube-system ds/cilium -- bpftool cgroup show /run/cilium/cgroupv2
ID    AttachType      AttachFlags     Name
1751  cgroup_inet4_connect             cil_sock4_connect
1754  cgroup_inet4_post_bind           cil_sock4_post_bind
1757  cgroup_udp4_sendmsg              cil_sock4_sendmsg
1760  cgroup_udp4_recvmsg              cil_sock4_recvmsg
1763  cgroup_inet4_getpeername         cil_sock4_getpeername
```

Una salida vacía de `bpftool cgroup show` es el síntoma definitivo de un fallo de socket LB — casi siempre `cgroup v2` sin montar, o el agente sin poder montarlo en `/run/cilium/cgroupv2`.

### 5.6 Verificar que realmente no queda residuo de `kube-proxy`

```bash
$ kubectl -n kube-system get ds kube-proxy
Error from server (NotFound): daemonsets.apps "kube-proxy" not found

$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c KUBE-SVC
0

$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c CILIUM
6
```

Seis cadenas `CILIUM_*` es normal incluso con `bpf.masquerade: true` — Cilium mantiene un conjunto pequeño para la redirección al proxy y para reglas `NOTRACK`. Cualquier conteo de `KUBE-SVC` distinto de cero en un nodo significa que reglas obsoletas de un `kube-proxy` eliminado siguen tapando el datapath eBPF; ver §6.5.

### 5.7 Observabilidad de flujos con Hubble

```bash
$ cilium hubble port-forward &
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 49,149/49,149 (100.00%)
Flows/s: 214.77
Connected Nodes: 3/3

$ hubble observe --namespace prod --follow --output compact
Sep  1 14:11:03.117: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) -> prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 14:11:03.117: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) <- prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Sep  1 14:11:03.118: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) -> prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) http-request FORWARDED (HTTP/1.1 GET http://payments.prod.svc:8080/healthz)
Sep  1 14:11:03.121: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) <- prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) http-response FORWARDED (HTTP/1.1 200 3ms (GET http://payments.prod.svc:8080/healthz))

$ hubble observe --verdict DROPPED --last 20
Sep  1 14:12:41.883: prod/frontend-6d9f7c8b5-2xk4t:44120 (ID:25478) <> prod/ledger-5b7c9d8f4-qm2pw:8080 (ID:44117) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  1 14:12:41.883: prod/frontend-6d9f7c8b5-2xk4t:44120 (ID:25478) <> prod/ledger-5b7c9d8f4-qm2pw:8080 (ID:44117) Policy denied DROPPED (TCP Flags: SYN)

$ hubble observe --verdict DROPPED --last 200 -o json | \
    jq -r '[.source.namespace + "/" + .source.pod_name,
            .destination.namespace + "/" + .destination.pod_name,
            (.l4.TCP.destination_port // .l4.UDP.destination_port // 0 | tostring),
            .drop_reason_desc] | @tsv' | sort | uniq -c | sort -rn
     87 prod/frontend-6d9f7c8b5-2xk4t  prod/ledger-5b7c9d8f4-qm2pw  8080  POLICY_DENIED
     11 prod/batch-runner-9f4c2       -/-                           443   POLICY_DENIED
```

Ese último pipeline — agrupar los descartes por `(src, dst, port, reason)` — es el comando más útil de todos cuando un rollout de política rompe algo y necesitás el radio de impacto en una sola pantalla.

### 5.8 La suite completa de conectividad

```bash
$ cilium connectivity test --test-namespace cilium-test
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [cca-lab] Creating namespace cilium-test-1 for connectivity check...
✨ [cca-lab] Deploying echo-same-node service...
✨ [cca-lab] Deploying DNS test server configmap...
⌛ [cca-lab] Waiting for deployment cilium-test-1/client to become ready...
⌛ [cca-lab] Waiting for CiliumEndpoint for pod cilium-test-1/echo-other-node-...
🏃[cilium-test-1] Running 82 tests ...
[=] [cilium-test-1] Test [no-policies] [1/82]
.................................
[=] [cilium-test-1] Test [client-egress-l7] [44/82]
.........
[=] [cilium-test-1] Test [north-south-loadbalancing] [61/82]
......
✅ [cilium-test-1] All 82 tests (417 actions) successful, 12 tests skipped, 1 scenarios skipped.
```

Correla después de cada upgrade y de cada cambio de configuración del datapath. `--test-concurrency`, `--include-unsafe-tests` y `--perf` la extienden; `--perf` corre `netperf` entre Pods y reporta throughput/latencia, que es la forma de cuantificar el costo de encender el cifrado.

### 5.9 Verificación de sesiones BGP

```bash
$ cilium bgp peers
Node             Local AS   Peer AS   Peer Address     Session State   Uptime     Family         Received   Advertised
cca-lab-worker   65001      65000     192.168.178.2    established     3h12m45s   ipv4/unicast   142        2
cca-lab-worker   65001      65000     192.168.178.3    established     3h12m44s   ipv4/unicast   142        2
cca-lab-worker2  65001      65000     192.168.178.2    established     3h12m41s   ipv4/unicast   142        1
cca-lab-worker2  65001      65000     192.168.178.3    established     3h12m40s   ipv4/unicast   142        1

$ cilium bgp routes advertised ipv4 unicast
Node             VRouter   Peer            Prefix              NextHop         Age        Attrs
cca-lab-worker   65001     192.168.178.2   10.20.1.0/24        192.168.178.11  3h12m45s   [{Origin: i} {AsPath: 65001} {Communities: 65000:100} {Nexthop: 192.168.178.11}]
cca-lab-worker   65001     192.168.178.2   192.168.180.42/32   192.168.178.11  1h04m11s   [{Origin: i} {AsPath: 65001} {Communities: 65000:200} {LocalPref: 200}]
```

Que los conteos de `Advertised` difieran entre nodos con `externalTrafficPolicy: Local` es esperado — solo los nodos que tienen un backend anuncian la VIP.

---

## 6. Diagnóstico de fallos

### 6.1 Orden de triage

```
Is the Pod getting an IP?
  no  -> §6.2 CNI / IPAM
  yes -> Is the endpoint 'ready' in `cilium-dbg endpoint list`?
           no  -> policy compilation / agent. `cilium-dbg endpoint get <id>`, agent logs
           yes -> Does traffic leave the source pod?
                    check `hubble observe --from-pod ...`
                    DROPPED with a reason -> §6.4 policy / §6.7 datapath drops
                    no flow at all        -> §6.6 socket LB / service programming
                    FORWARDED but no reply-> §6.3 MTU / §6.8 asymmetric routing
```

### 6.2 Pods trabados en `ContainerCreating`

```bash
$ kubectl -n prod describe pod frontend-6d9f7c8b5-9xzqk | tail -6
Events:
  Type     Reason                  Age                From     Message
  ----     ------                  ----               ----     -------
  Warning  FailedCreatePodSandBox  12s (x8 over 92s)  kubelet  Failed to create pod sandbox:
    plugin type="cilium-cni" name="cilium" failed (add): unable to allocate IP via local cilium agent:
    [POST /ipam][502] postIpamFailure  Unable to allocate IP: all pod CIDR ranges are exhausted
```

Tres causas distintas comparten este síntoma. Distinguilas:

```bash
# (a) IPAM exhausted on this node
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg status | grep IPAM
IPAM:   IPv4: 254/254 allocated from 10.20.1.0/24,

# (b) the agent is not running / its API socket is gone
$ kubectl -n kube-system get pods -l k8s-app=cilium -o wide
NAME           READY   STATUS             RESTARTS      AGE   NODE
cilium-7h2kp   0/1     CrashLoopBackOff   6 (31s ago)   4m    cca-lab-worker

# (c) two CNI configs on disk — another plugin is winning the lexical race
$ kubectl -n kube-system exec ds/cilium -- ls -1 /host/etc/cni/net.d/
05-cilium.conflist
10-kindnet.conflist            # <-- the offender
```

Soluciones, en orden:
- **(a)** subí `ipam.operator.clusterPoolIPv4MaskSize` (por ejemplo `/24` → `/23`) — esto afecta solo a asignaciones de nodos **nuevos**; los nodos existentes conservan su CIDR hasta que se recree el `CiliumNode`. O reducí la densidad de Pods por nodo. Verificá el margen en toda la flota antes de que te muerda:
  ```bash
  $ kubectl get ciliumnodes -o json | jq -r '.items[] |
      [.metadata.name, (.spec.ipam.podCIDRs | join(",")),
       (.status.ipam.used | length)] | @tsv'
  cca-lab-worker    10.20.1.0/24   254
  cca-lab-worker2   10.20.2.0/24   61
  ```
- **(b)** leé el log del agente; las tres causas principales son un kernel por debajo del piso de funcionalidades, `cgroup v2` imposible de montar, y un `k8sServiceHost` incorrecto.
- **(c)** poné `cni.exclusive: true` y reiniciá el agente, que limpia `/etc/cni/net.d`.

### 6.3 El agujero negro de MTU — los requests chicos funcionan, los grandes se cuelgan

Este es el fallo más caro de diagnosticar del capítulo, porque no se loguea nada y nada se contabiliza como descarte. `curl http://svc/healthz` funciona; un handshake TLS o cualquier respuesta de más de ~1,4 kB se cuelga para siempre.

```bash
$ kubectl -n prod exec deploy/frontend -- ip link show eth0
3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
                                                    ^^^^ suspicious in a tunnelled cluster

$ kubectl -n prod exec deploy/frontend -- \
    ping -M do -s 1472 -c 2 10.20.2.44
PING 10.20.2.44 (10.20.2.44) 1472(1500) bytes of data.
From 10.20.1.113 icmp_seq=1 Frag needed and DF set (mtu 1450)

--- 10.20.2.44 ping statistics ---
2 packets transmitted, 0 received, +1 errors, 100% packet loss
```

Bisectá el tamaño que funciona:

```bash
$ for s in 1500 1450 1422 1400; do
    printf '%5s: ' "$s"
    kubectl -n prod exec deploy/frontend -- \
      ping -M do -s $((s-28)) -c1 -W1 10.20.2.44 >/dev/null 2>&1 \
      && echo OK || echo FAIL
  done
 1500: FAIL
 1450: FAIL
 1422: OK
 1400: OK
```

Que 1422 funcione y 1450 falle en un clúster VXLAN + WireGuard es exactamente `1500 − 50 − 80 = 1370`… no: apunta a un camino de **1472 bytes** en algún lado, es decir, un dispositivo intermedio con una MTU reducida. Causas raíz ordenadas por frecuencia:

1. La path MTU del underlay es menor que la MTU de la NIC local (una VPN, un enlace de peering de VPC en el cloud, un salto GRE). Solución: fijar el valor Helm `MTU` a la path MTU real.
2. El ICMP "fragmentation needed" está bloqueado por un firewall, así que PMTUD falla silenciosamente. Solución: permitir ICMP tipo 3 código 4, o hacer clamp de la MTU.
3. Se encendió el cifrado sin volver a correr `helm upgrade` con una `MTU` actualizada y sin reiniciar los Pods — **los Pods existentes conservan la MTU vieja del veth**. Solución: rotar los workloads:
   ```bash
   $ kubectl get ns -o name | xargs -I{} kubectl -n $(basename {}) rollout restart deploy --all
   ```

### 6.4 La política deniega tráfico que creés haber permitido

```bash
$ hubble observe --from-pod prod/frontend --verdict DROPPED --last 5 -o json | \
    jq -r '"\(.source.identity) -> \(.destination.identity)  \(.event_type.type)  \(.drop_reason_desc)"'
25478 -> 44117  1  POLICY_DENIED
```

Resolvé las dos identidades y compará los conjuntos de labels — una política que "debería" coincidir casi siempre falla porque el selector está escrito contra una label que el Pod no lleva, o contra una label de namespace que no existe:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg identity get 44117
ID      LABELS
44117   k8s:app.kubernetes.io/name=ledger        # <-- policy selects app=ledger
        k8s:io.cilium.k8s.policy.cluster=leloir-prod
        k8s:io.cilium.k8s.policy.serviceaccount=ledger
        k8s:io.kubernetes.pod.namespace=prod
```

Después preguntale al datapath directamente, en vez de razonar sobre el YAML:

```bash
$ kubectl exec -n kube-system ds/cilium -- \
    cilium-dbg policy trace --src-identity 25478 --dst-identity 44117 --dport 8080/TCP
Resolving egress policy for [k8s:app=frontend k8s:io.kubernetes.pod.namespace=prod ...]
* Rule {"matchLabels":{"any:app":"frontend","k8s:io.kubernetes.pod.namespace":"prod"}}: selected
    Allows Egress port [{8080 0 TCP}]
      Requires: []
      Labels: [k8s:app=ledger]
    No label match for [k8s:app.kubernetes.io/name=ledger ...]
0/1 rules selected
Found no allow rule
Egress verdict: denied

Final verdict: DENIED
```

Y revisá el mapa de política compilado por endpoint, que es la verdad de campo:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf policy get 2361
DIRECTION   LABELS (source:key[=value])                  PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS   PREFIX
Allow       Egress   reserved:unknown                    ANY          NONE         disabled    0       0         0
Allow       Egress   k8s:app=payments                    8080/TCP     18441        disabled    4821    38        24
Allow       Egress   k8s:k8s-app=kube-dns                53/ANY       18442        disabled    1204    18        24
Allow       Ingress  k8s:app=frontend                    8080/TCP     NONE         disabled    9312    64        24
```

Un `PROXY PORT` distinto de cero confirma que el flujo se está redirigiendo a Envoy para evaluación L7. `PROXY PORT: NONE` en una regla que escribiste con un bloque `http:` significa que la regla L7 no se compiló — revisá `l7Proxy: true` y que `cilium-envoy` esté corriendo en ese nodo.

**Higiene de rollout.** Nunca apliques un nuevo default-deny a un namespace vivo sin modo auditoría primero:

```yaml
# add to the CNP's metadata, or set policyAuditMode: true cluster-wide
metadata:
  annotations:
    io.cilium/policy-audit-mode: "true"
```
```bash
$ hubble observe --verdict AUDIT --namespace prod --last 500 -o json | \
    jq -r '[.source.labels[]?|select(startswith("k8s:app"))] as $s |
           [$s[0], .destination.identity, (.l4.TCP.destination_port//0)] | @tsv' | sort -u
```
Cada línea de esa salida es una regla que todavía tenés que escribir.

### 6.5 Reglas obsoletas de `kube-proxy` tapando el datapath eBPF

Síntoma: después de migrar a `kubeProxyReplacement`, algunos Services funcionan y otros fallan intermitentemente, sin descartes en Hubble.

```bash
$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c KUBE-SVC
94
```

Eliminar el DaemonSet de `kube-proxy` **no** borra las reglas que escribió. Persisten hasta que el nodo reinicie o las vacíes. Ejecutá una vez por nodo:

```bash
$ kubectl -n kube-system delete ds kube-proxy
$ kubectl -n kube-system delete cm kube-proxy
$ for n in $(kubectl get nodes -o name); do
    kubectl debug $n --image=alpine:3.20 --profile=sysadmin -q -- \
      sh -c 'nsenter --target 1 --mount --uts --ipc --net --pid -- \
             sh -c "iptables-save | grep -v KUBE- | iptables-restore &&
                    ip link del kube-ipvs0 2>/dev/null; ipvsadm -C 2>/dev/null; true"'
  done
```

Después reverificá que el conteo sea `0`. Es una operación unidireccional que afecta al nodo — hacela nodo por nodo, drenando primero, en una ventana de mantenimiento.

### 6.6 Agotamiento de conntrack o de los mapas de LB

Síntoma: las conexiones nuevas fallan bajo carga mientras que las existentes andan bien; `hubble observe --verdict DROPPED` muestra `CT_MAP_INSERTION_FAILED`.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg map list --verbose | grep -E 'ct4|nat|lb4_services'
cilium_ct4_global          524288        0            false
cilium_snat_v4_external    511922        0            false
cilium_lb4_services_v2     65530         0            true

$ kubectl exec -n kube-system ds/cilium -- \
    curl -s localhost:9962/metrics | grep cilium_bpf_map_pressure | sort -t' ' -k2 -rn | head -3
cilium_bpf_map_pressure{map_name="cilium_ct4_global"} 0.998
cilium_bpf_map_pressure{map_name="cilium_snat_v4_external"} 0.976
cilium_bpf_map_pressure{map_name="cilium_lb4_services_v2"} 0.999
```

Solucionalo subiendo los techos y rotando el agente (redimensionar un mapa requiere recarga; las conexiones existentes en el mapa **se pierden**, así que drená el nodo):

```yaml
bpf:
  ctTcpMax: 1048576
  ctAnyMax: 524288
  natMax: 1048576
  lbMapMax: 131072
  mapDynamicSizeRatio: 0.005
```

Alerta permanente:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-datapath
  namespace: monitoring
spec:
  groups:
    - name: cilium.datapath
      rules:
        - alert: CiliumBPFMapPressureHigh
          expr: cilium_bpf_map_pressure > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "BPF map {{ $labels.map_name }} on {{ $labels.node }} is {{ $value | humanizePercentage }} full"
            runbook: "Raise the corresponding bpf.* Helm value and roll the agent after draining."
        - alert: CiliumPolicyDropSpike
          expr: sum by (node, reason) (rate(cilium_drop_count_total{reason="Policy denied"}[5m])) > 20
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Policy drop rate spike on {{ $labels.node }}"
        - alert: CiliumUnreachableNodes
          expr: cilium_unreachable_nodes > 0
          for: 5m
          labels:
            severity: critical
        - alert: CiliumEndpointRegenerationSlow
          expr: histogram_quantile(0.99, sum by (le, node) (rate(cilium_endpoint_regeneration_time_stats_seconds_bucket{scope="total"}[10m]))) > 10
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "p99 endpoint regeneration > 10s — usually identity churn or an oversized policy set"
        - alert: CiliumIdentityExplosion
          expr: cilium_identity{type="cluster_local"} > 45000
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Approaching the 65535 cluster-local identity ceiling"
```

### 6.7 Leer descartes crudos del datapath

Cuando Hubble no alcanza, andá al perf ring buffer:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v
Listening for events on 16 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8f2a1c3d to endpoint 1204, ifindex 24, file bpf_lxc.c:2004, , identity 25478->31902: 10.20.1.113:44120 -> 10.20.1.88:8080 tcp SYN
xx drop (Stale or unroutable IP) flow 0x1c04a9de to endpoint 0, ifindex 2, file bpf_host.c:1122, , identity 6->unknown: 10.10.0.9 -> 10.20.4.7 tcp SYN
xx drop (Unsupported L3 protocol) flow 0x7712bb01 to endpoint 0, ifindex 24, file bpf_lxc.c:1402, , identity 31902->0: 0.0.0.0 -> 0.0.0.0
```

| Motivo del descarte | Causa raíz más común |
|---|---|
| `Policy denied` | Desajuste de selector/label — §6.4 |
| `Stale or unroutable IP` | El ipcache no tiene entrada para el destino: se quitó un nodo, o la sincronización de CRD/kvstore va atrasada |
| `Invalid source ip` | Falló la verificación de spoofing de dirección de origen — un Pod usando una IP que no es la suya, o un Pod no gestionado |
| `CT: Map insertion failed` | Conntrack lleno — §6.6 |
| `No mapping for NAT masquerade` | Mapa de NAT agotado, o el dispositivo de salida no está en `devices` |
| `FIB lookup failed` | El host no tiene ruta al destino: ruteo nativo sin ruta al PodCIDR remoto |
| `Missed tail call` | El conjunto de programas del datapath es inconsistente — reiniciá el agente; si se repite, reportá un bug con un sysdump |
| `Unsupported protocol for NAT masquerade` | Algo distinto de TCP/UDP/ICMP siendo enmascarado (SCTP, ESP) |
| `Authentication required` | Política de autenticación mutua sin identidad SPIRE establecida |

El campo `file bpf_lxc.c:2004` es la ubicación exacta en el código fuente de la decisión — invaluable al leer el código del datapath upstream.

### 6.8 Ruteo nativo sin ruta al PodCIDR remoto

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop | grep 'FIB lookup'
xx drop (FIB lookup failed) flow 0x2a1c to endpoint 0, ifindex 2, file bpf_lxc.c:1691, , identity 25478->31902: 10.20.1.113:33420 -> 10.20.2.44:8080 tcp SYN

$ kubectl exec -n kube-system ds/cilium -- ip route get 10.20.2.44
RTNETLINK answers: Network is unreachable
```

El datapath eBPF deliberadamente **no** inventa rutas en modo nativo. O bien:
- los nodos están en un solo segmento L2 → poné `autoDirectNodeRoutes: true`;
- no lo están → BGP (§4.4), o rutas estáticas en el fabric, o cambiá a `routingMode: tunnel`.

Confirmá qué modo está en vigencia antes de seguir depurando:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf tunnel list
TUNNEL   VALUE
# empty in native routing — this is correct, not a fault
```

### 6.9 La política `toFQDNs` no permite nada

`toFQDNs` **solo** funciona si la misma política además permite DNS a través del proxy DNS L7. Sin el bloque `rules: dns:`, el proxy nunca ve la consulta, nunca aprende la respuesta, y el selector FQDN coincide con un conjunto vacío de IPs.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg fqdn cache list | head
Endpoint   Source       FQDN                 TTL    ExpirationTime                    IPs
1204       lookup       api.stripe.com.      60     2026-09-01T14:23:11.004Z          104.18.6.14,104.18.7.14

$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ipcache list | grep 104.18
104.18.6.14/32   identity=16777231 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
104.18.7.14/32   identity=16777231 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
```

Una caché de FQDN vacía con una política que se ve correcta significa que falta la regla DNS o que la consulta está yendo a otro lado distinto de los endpoints DNS seleccionados.

Dos advertencias de producción:
- **Los reinicios del agente interrumpen el DNS** de todos los Pods bajo una política `toFQDNs`, porque el proxy DNS vive en el agente. Mantené los reinicios de `rollOutCiliumPods` de a un nodo por vez y medí el hueco.
- Una CDN con un TTL corto y un pool grande de direcciones puede empujar un solo hostname más allá de `dnsProxy.endpointMaxIpPerHostname` (por defecto 50), tras lo cual se desalojan las IPs más viejas y conexiones que antes funcionaban empiezan a fallar de manera intermitente. Subí el límite o usá `toCIDRSet` para esos destinos.

### 6.10 Cifrado que en realidad no está cifrando

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
  Public key: 9pS1n+FQ0v0KcS3fA1qWQ2mZ1Y8cH0jV6t5RmL9pXQY=
  Number of peers: 2

$ kubectl exec -n kube-system ds/cilium -- wg show cilium_wg0
interface: cilium_wg0
  public key: 9pS1n+FQ0v0KcS3fA1qWQ2mZ1Y8cH0jV6t5RmL9pXQY=
  private key: (hidden)
  listening port: 51871

peer: hK2mF8xQ...
  endpoint: 10.10.0.5:51871
  allowed ips: 10.20.2.0/24, 10.10.0.5/32
  latest handshake: 41 seconds ago
  transfer: 1.24 GiB received, 894.11 MiB sent
```

`Number of peers` debe ser igual a `nodos − 1`. Menos significa que la clave pública de un nodo no se propagó — revisá el objeto `CiliumNode`:

```bash
$ kubectl get ciliumnode cca-lab-worker2 -o jsonpath='{.metadata.annotations}' | jq .
{
  "network.cilium.io/wg-pub-key": "hK2mF8xQ..."
}
```

Probalo de punta a punta desde el underlay en vez de confiar en la línea de estado:

```bash
$ kubectl debug node/cca-lab-worker --image=nicolaka/netshoot -q -- \
    tcpdump -ni eth0 -c 5 'host 10.10.0.5 and not port 51871'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes

0 packets captured
```

Cero paquetes entre IPs de nodos fuera del puerto de WireGuard es la prueba. Cualquier paquete Pod-a-Pod en texto claro ahí es un hallazgo.

### 6.11 Capturar todo para escalar el caso

```bash
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M)
🔍 Collecting Kubernetes nodes...
🔍 Collecting Cilium configuration...
🔍 Collecting Cilium BPF maps from all nodes...
🔍 Collecting Hubble flows from all nodes...
🔍 Collecting gops stats from Cilium pods...
✅ The sysdump has been saved to cilium-sysdump-20260901-1417.zip
```

El bundle contiene, por nodo: `cilium-dbg status --verbose`, el volcado de cada mapa BPF, el conjunto completo de políticas, listas de endpoints/identidades, logs del agente + operator, salida de `bpftool`, y una instantánea de flujos de Hubble. Es el primer adjunto correcto para cualquier issue upstream, y también la forma más rápida de comparar dos nodos que se comportan distinto. Contiene **IPs de Pods, labels y registros de flujos** — tratalo como sensible y redactalo antes de compartirlo fuera de la organización.

---

## 7. El modelo mental para llevar al examen y a producción

1. **Identidad, no IP.** Todo veredicto de política se resuelve como `(identidad de origen, identidad de destino, puerto, protocolo, dirección)`. Cuando algo se deniega, resolvé ambas identidades y compará los conjuntos de labels antes de leer ningún YAML.
2. **El ipcache es la tabla global de verdad.** `IP → identidad, tunnel endpoint, clave de cifrado`. El ruteo nativo depende de él para la política de ingress; el modo túnel transporta la identidad in-band y no depende.
3. **Tres capas de balanceo de carga.** Socket LB en `connect()` para Pod→Service; `tc` para este-oeste; XDP para norte-sur. Si Pod→Service funciona y NodePort no, estás mirando caminos de código distintos y mapas distintos.
4. **La configuración vive en tres lugares y tienen que coincidir.** Valores de Helm → el ConfigMap `cilium-config` → los flags efectivos del agente. `cilium-dbg config --all` es el único que cuenta.
5. **Los mapas son capacidad.** Conntrack, NAT, política por endpoint, tablas de LB y de Maglev tienen techos que dimensionaste (o dejaste por defecto). `cilium_bpf_map_pressure` va en tu dashboard desde el día uno.
6. **El agente no es el datapath.** El tráfico existente sobrevive a un reinicio del agente; los Pods nuevos, la convergencia de políticas y el proxy L7/DNS no.
7. **La versión del kernel habilita funcionalidades, no la versión de Cilium.** Leé `cilium-dbg status --verbose` y confirmá `Host Routing: BPF`, `Masquerading: BPF` y XDP nativo — un fallback degradado silenciosamente se ve idéntico desde el API server.
8. **Auditar antes de aplicar.** `PolicyAuditMode` para el firewall de host y para cada nuevo default-deny. El modo de fallo de equivocarse acá es un nodo bloqueado o una caída de todo un namespace.

---

## Referencias

**Documentación oficial de Cilium**
- Raíz de la documentación de Cilium — https://docs.cilium.io/en/stable/
- Vista general de componentes y arquitectura — https://docs.cilium.io/en/stable/overview/component-overview/
- Internals del datapath eBPF — https://docs.cilium.io/en/stable/reference-guides/bpf/
- Vida de un paquete — https://docs.cilium.io/en/stable/reference-guides/bpf/lifeofapacket/
- Modos de ruteo (encapsulado y nativo) — https://docs.cilium.io/en/stable/network/concepts/routing/
- Conceptos y modos de IPAM — https://docs.cilium.io/en/stable/network/concepts/ipam/
- Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Configuración de MTU — https://docs.cilium.io/en/stable/network/mtu/
- Kubernetes sin kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Reemplazo de kube-proxy (Maglev, DSR, XDP) — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#maglev-consistent-hashing
- BGP Control Plane (recursos v2) — https://docs.cilium.io/en/stable/network/bgp-control-plane/
- Gestión de direcciones IP de LoadBalancer — https://docs.cilium.io/en/stable/network/lb-ipam/
- Egress Gateway — https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- Bandwidth Manager — https://docs.cilium.io/en/stable/network/kubernetes/bandwidth-manager/
- Local Redirect Policy — https://docs.cilium.io/en/stable/network/kubernetes/local-redirect-policy/
- Cifrado transparente (IPsec y WireGuard) — https://docs.cilium.io/en/stable/security/network/encryption/
- Conceptos de network policy y referencia de CRDs — https://docs.cilium.io/en/stable/security/policy/
- Firewall de host — https://docs.cilium.io/en/stable/security/host-firewall/
- Política basada en DNS y `toFQDNs` — https://docs.cilium.io/en/stable/security/policy/language/#dns-based
- Troubleshooting de políticas y modo auditoría — https://docs.cilium.io/en/stable/security/policy/troubleshooting/
- Observabilidad con Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Referencia de monitoreo y métricas — https://docs.cilium.io/en/stable/observability/metrics/
- Guía de troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Requisitos del sistema (matriz de kernel y distribuciones) — https://docs.cilium.io/en/stable/operations/system_requirements/
- Referencia de Helm (todos los valores usados arriba) — https://docs.cilium.io/en/stable/helm-reference/
- Guía de upgrade — https://docs.cilium.io/en/stable/operations/upgrade/
- Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/
- Referencia de comandos de `cilium-dbg` — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Cilium CLI — https://github.com/cilium/cilium-cli
- Código fuente de Cilium (datapath bajo `bpf/`) — https://github.com/cilium/cilium

**Kubernetes upstream**
- Modelo de red del clúster — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- IPs virtuales y proxies de Service (modos de `kube-proxy`) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Ruteo consciente de la topología — https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/
- Gateway API — https://gateway-api.sigs.k8s.io/

**Certificación y currícula**
- Currícula CCA (fuente de la ponderación de este tema) — https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- Repositorio de currículas de la CNCF — https://github.com/cncf/curriculum
- Página del programa Cilium Certified Associate — https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Antecedentes**
- Documentación de eBPF — https://ebpf.io/what-is-ebpf/
- Páginas de manual de `bpftool` — https://docs.kernel.org/bpf/
- Maglev: A Fast and Reliable Software Network Load Balancer (Google, NSDI'16) — https://research.google/pubs/pub44824/
- Protocolo WireGuard — https://www.wireguard.com/protocol/
- Especificación CNI — https://github.com/containernetworking/cni/blob/main/SPEC.md