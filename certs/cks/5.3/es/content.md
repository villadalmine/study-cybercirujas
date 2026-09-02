# 5.3 Minimizar el acceso externo a la red

> **Dominio**: System Hardening — **Peso en el examen**: 2,5 % — **Versión del examen**: CKS v1.34
> **Alcance**: reducir la superficie de ataque de red *de los nodos mismos* (alcanzabilidad del host, sockets en escucha, firewall del host, primitivas de exposición) — la capa que está **por debajo** del plano de autorización de Kubernetes.

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 Un nodo es una máquina Linux que filtra

El modelo mental que la mayoría de los ingenieros carga es "el clúster es la frontera de seguridad". No lo es. Un nodo de Kubernetes es un host Linux de propósito general que además ejecuta un container runtime, y una instalación estándar de `kubeadm` deja una superficie TCP sorprendentemente amplia enlazada a `0.0.0.0`. Cada uno de esos sockets es alcanzable por cualquier cosa que pueda rutear hacia la IP del nodo — la LAN corporativa, un security group mal configurado en la nube, un peering de VPC, un pod comprometido usando `hostNetwork: true`, o un salto lateral desde un tenant adyacente.

La propiedad crítica a internalizar: **NetworkPolicy no protege el network namespace del host.** Con cualquier CNI mainstream, un objeto `NetworkPolicy` selecciona *pods*. No tiene ninguna opinión sobre el tráfico destinado a `10.0.0.21:10250`, a `sshd`, a `etcd`, o a un pod con `hostNetwork`. Tres clases enteras de exposición quedan por debajo:

| Plano | Objetivo de ejemplo | ¿Protegido por NetworkPolicy? | Protegido por qué |
|---|---|---|---|
| Ingreso al nodo desde fuera del clúster | `6443`, `10250`, `22`, rango NodePort | ❌ | SG/NACL de nube + firewall del host + `nodePortAddresses` |
| Ingreso al nodo desde dentro del clúster (pod → nodo) | `10250`, `2379`, IMDS vía el nodo | ❌ (el tráfico sale del netns del pod hacia el host) | Firewall del host / host policy del CNI / hop-limit de IMDS |
| Egreso del nodo | Beacon de C2, exfiltración de imágenes, `169.254.169.254` | Parcialmente (solo egreso de pods) | `output` del firewall del host + egress gateway/proxy |

### 1.2 Lo que realmente te cuesta un puerto expuesto

Esto no es teórico. Cada caso es una cadena de compromiso total del clúster documentada y reproducible:

| Puerto | Componente | Modo de falla cuando es alcanzable | Resultado |
|---|---|---|---|
| `10250/tcp` | API del kubelet (HTTPS) | `authentication.anonymous.enabled: true` **o** `authorization.mode: AlwaysAllow` | `POST /run/{ns}/{pod}/{container}` → ejecución arbitraria de comandos en **cualquier** pod de ese nodo → robo de todos los tokens de ServiceAccount montados |
| `10255/tcp` | kubelet read-only (HTTP, sin auth) | Habilitado en absoluto | `GET /pods` vuelca los PodSpecs completos: variables de entorno, nombres de secrets, rutas de montaje de tokens, registries de imágenes. Una mina de oro de reconocimiento puro |
| `2379/tcp` | Cliente de etcd | `--client-cert-auth=false` o certificado alcanzable | Lectura/escritura total de cada objeto del clúster, **incluidos los Secrets sin cifrar** |
| `2380/tcp` | Par (peer) de etcd | Alcanzable fuera de la subred | Unir un miembro rogue → inyección de estado del clúster |
| `10257` / `10259` | controller-manager / scheduler | Enlazados a `0.0.0.0` | `/metrics`, volcados de heap de `/debug/pprof` (pueden contener tokens), disrupción de la elección de líder |
| `30000–32767` | NodePort | Cualquier Service de `type: NodePort` | El puerto se abre en **todos los nodos del clúster**, en **todas las interfaces**, incluidos los nodos del control plane |
| `169.254.169.254` (egreso) | IMDS de la nube | Alcanzable desde el netns del pod | SSRF en una app → credenciales del rol de la instancia → toma del clúster/cuenta |
| `22/tcp` | sshd | Autenticación por contraseña, login de root, alcanzable desde todo el mundo | Propiedad directa del nodo; `/etc/kubernetes/pki/*` está ahí mismo |

### 1.3 El problema de amplificación de NodePort

Esta es la primitiva de exposición peor entendida del examen y de producción. Cuando un desarrollador en el namespace `team-a` crea:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: admin-ui
  namespace: team-a
spec:
  type: NodePort
  selector: { app: admin-ui }
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 31380
```

kube-proxy programa `31380` en **cada nodo**, escuchando en **cada dirección**, porque `nodePortAddresses` está vacío por defecto. Un permiso RBAC acotado a un namespace para crear Services acaba de perforar un agujero en el perímetro de toda la flota, también en los nodos del control plane. No hay ningún control de admisión para esto de fábrica.

### 1.4 Defensa en profundidad: los cuatro anillos

```
                  ┌─────────────────────────────────────────────┐
   Ring 0         │ Cloud SG / NACL / physical VLAN + private   │  ← coarse, fails open on misconfig
                  │ control-plane endpoint                      │
                  ├─────────────────────────────────────────────┤
   Ring 1         │ Host firewall: nftables on every node       │  ← survives CNI failure, survives
                  │ (prerouting + input + forward + output)     │    kube-proxy, node-local truth
                  ├─────────────────────────────────────────────┤
   Ring 2         │ CNI host policy (Cilium host firewall /     │  ← declarative, cluster-wide,
                  │ Calico HostEndpoint) + kube-proxy           │    label-driven, GitOps-able
                  │ nodePortAddresses + service-node-port-range │
                  ├─────────────────────────────────────────────┤
   Ring 3         │ Component binding + authn/authz             │  ← the last line: even if reachable,
                  │ (readOnlyPort:0, anonymous:false, Webhook,  │    it must still refuse you
                  │  bind-address 127.0.0.1, client-cert-auth)  │
                  ├─────────────────────────────────────────────┤
   Ring 4         │ Admission control: forbid NodePort /        │  ← prevent the hole from ever
                  │ externalIPs / hostNetwork / hostPort        │    being requested
                  └─────────────────────────────────────────────┘
```

CKS 5.3 es esencialmente los anillos 1–4. El anillo 0 lo heredás de la plataforma; no confíes solo en él — un único error de Terraform con `0.0.0.0/0` abre todo, y el firewall del host es lo que hace ese error sobrevivible.

---

## 2. Comparaciones técnicas y compromisos

### 2.1 La superficie de escucha por defecto (kubeadm, v1.34)

Los valores de abajo son los de `kubeadm` por defecto; verificalos en tu propio clúster con `ss -tulpn`.

| Puerto | Proto | Componente | Bind por defecto | Llamadores legítimos | Hardening |
|---|---|---|---|---|---|
| 6443 | TCP | kube-apiserver | `0.0.0.0` | Todos (kubelets, kubectl, LB) | LB privado, allowlist de SG, OIDC/mTLS |
| 2379 | TCP | Cliente de etcd | `127.0.0.1` + IP del nodo | kube-apiserver en el mismo nodo | `--client-cert-auth=true`, restringir a la subred del control plane |
| 2380 | TCP | Peer de etcd | IP del nodo | Otros miembros de etcd | `--peer-client-cert-auth=true`, solo subred del control plane |
| 2381 | TCP | Métricas de etcd | `127.0.0.1` | Scrape local / sidecar | Mantener en loopback |
| 10250 | TCP | API del kubelet | `0.0.0.0` | kube-apiserver, metrics-server | `anonymous: false`, `mode: Webhook`, firewall hacia las IPs del control plane |
| 10255 | TCP | kubelet read-only | deshabilitado (`0`) | **nadie** | Mantener `readOnlyPort: 0`; nunca reactivar |
| 10248 | TCP | healthz del kubelet | `127.0.0.1` | Local | Mantener en loopback |
| 10256 | TCP | healthz de kube-proxy | `0.0.0.0` | Health checks del LB de la nube | Restringir a la subred del LB, o enlazar a loopback si no hay LB externo |
| 10249 | TCP | Métricas de kube-proxy | `127.0.0.1` | Scrape local | Mantener en loopback |
| 10257 | TCP | kube-controller-manager | `127.0.0.1` (kubeadm) | Local | Verificar — el default upstream es `0.0.0.0` |
| 10259 | TCP | kube-scheduler | `127.0.0.1` (kubeadm) | Local | Igual |
| 30000–32767 | TCP/UDP | Services NodePort | todas las direcciones | Depende | `nodePortAddresses`, achicar el rango, denegar por admisión |
| 8472 | UDP | VXLAN (Flannel/Cilium) | todas | Nodos pares | Solo subred de nodos |
| 4240 | TCP | Health de Cilium | todas | Nodos pares | Solo subred de nodos |
| 4789 | UDP | VXLAN (Calico) | todas | Nodos pares | Solo subred de nodos |
| 179 | TCP | BGP de Calico | todas | Nodos pares / ToR | Solo subred de nodos / ToR |
| 5473 | TCP | Typha de Calico | todas | Felix en los nodos | Solo subred de nodos |
| 51820/51871 | UDP | WireGuard (Cilium/Calico) | todas | Nodos pares | Solo subred de nodos |

> **Trampa**: bloquear los puertos del data plane del CNI (8472, 4789, 4240, 179, 51820) es la caída autoinfligida n.º 1 al endurecer nodos. Los síntomas están en §5.

### 2.2 Dónde aplicar: comparación de capas

| Capa | Granularidad | Sobrevive a una caída del CNI | Sobrevive a un reinicio del nodo | Apta para GitOps | Radio de impacto de un error | Protege el netns del host | Mejor para |
|---|---|---|---|---|---|---|---|
| SG / NACL de nube | CIDR + puerto | ✅ | ✅ | ✅ (IaC) | Toda la VPC | ✅ | Perímetro grueso, norte-sur |
| **nftables en el nodo** | CIDR, iface, estado de ct, uid, tasa | ✅ | ✅ (`nftables.service`) | ⚠️ (gestión de configuración) | Un nodo (riesgo de quedarte afuera) | ✅ | La base no negociable |
| firewalld / ufw | zonas / reglas simples | ✅ | ✅ | ⚠️ | Un nodo | ✅ | Flotas gestionadas por la distro — **con salvedades** |
| Host firewall de Cilium (CCNP + `nodeSelector`) | identidad, label, CIDR, puerto | ❌ (agente caído ⇒ estado de la política en riesgo) | ✅ | ✅ | Toda la flota (riesgo de quedarte afuera) | ✅ | Política de nodo declarativa a escala |
| `HostEndpoint` + `GlobalNetworkPolicy` de Calico | label, CIDR, puerto, pre-DNAT | ❌ | ✅ | ✅ | Toda la flota | ✅ | Lo mismo, con `preDNAT` para NodePort |
| `NetworkPolicy` (core de k8s) | label de pod, ns, CIDR, puerto | ❌ | ✅ | ✅ | Namespace | ❌ | Tráfico este-oeste entre pods (tema 1.1) |
| Service mesh (mTLS/AuthZ) | identidad de workload, L7 | ❌ | ✅ | ✅ | Mesh | ❌ | Authz L7, no perímetro |
| Control de admisión (VAP/Kyverno) | forma del objeto de la API | n/a | ✅ | ✅ | Clúster | solo prevención | Evitar que se pidan los agujeros |

**Veredicto arquitectónico**: nftables en cada nodo es el piso — es la única capa que es simultáneamente local al nodo, independiente del CNI, y aplicada por el kernel antes de que cualquier componente de userspace tenga voto. La host policy del CNI se apoya *encima* para gestión declarativa a escala de flota. Ninguna reemplaza a la otra.

### 2.3 Comparación de backends de firewall (y la interacción con kube-proxy)

| Backend | Ruta del kernel | Coexiste con kube-proxy en modo `iptables` | Coexiste con kube-proxy en modo `nftables` | ¿El reload vacía las reglas de k8s? | Recomendación |
|---|---|---|---|---|---|
| `iptables-legacy` | `x_tables` | ⚠️ Split-brain si kube-proxy usa `iptables-nft` | ⚠️ | No (pero hay peleas de ordenamiento de reglas) | Evitar en distros modernas |
| `iptables-nft` (por defecto en RHEL9/Deb12) | `nf_tables` vía traducción | ✅ | ✅ | No | Aceptable |
| **`nft` nativo** | `nf_tables` | ✅ (tablas separadas, hooks independientes) | ✅ (kube-proxy es dueño de `table ip kube-proxy`) | No | **Preferido** |
| `firewalld` | backend `nf_tables` | ⚠️ Históricamente `--reload` vaciaba las cadenas de kube-proxy | ⚠️ | **Sí, históricamente** | Solo si no queda otra; fijá la versión y probá los reloads |
| `ufw` | `iptables-nft` | ⚠️ `ufw reload` reescribe el ordenamiento de `INPUT` | ⚠️ | Parcialmente | Solo para laboratorio |

Dos hechos que hacen de `nft` nativo la respuesta correcta:

1. **Múltiples cadenas base pueden engancharse al mismo hook de netfilter.** Tu `table inet k8s_node` y la `table ip kube-proxy` de kube-proxy son objetos independientes recorridos en orden de prioridad. Ninguna vacía a la otra. `iptables -F` / `firewalld --reload` no ofrecen esa garantía.
2. **Podés engancharte a una prioridad *anterior* al NAT**, que es la única forma de filtrar correctamente el tráfico NodePort (§2.5).

> **Nota v1.34**: el backend `nftables` de kube-proxy (KEP-3866) pasó a beta en v1.31 y a GA en la línea v1.33, pero todavía **no** es el default en v1.34. Confirmalo en tu clúster:
> `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'`

### 2.4 Comparación de primitivas de exposición externa

| Mecanismo | Dónde se abren puertos | Requiere control de admisión para restringirlo | Auditabilidad | Postura recomendada |
|---|---|---|---|---|
| `type: ClusterIP` | en ningún lado externamente | — | alta | ✅ Por defecto |
| `type: NodePort` | 30000–32767 en **todos los nodos, todas las NICs** | ✅ denegar por política | baja (enterrado en specs de Service) | ❌ Prohibir salvo break-glass |
| `type: LoadBalancer` | LB de nube → NodePort en todos los nodos | ✅ forzar esquema `internal` | media | ⚠️ Solo interno por defecto |
| `spec.externalIPs` | el tráfico hacia IPs arbitrarias es secuestrado a nivel de todo el clúster | ✅ plugin `DenyServiceExternalIPs` | muy baja | ❌ Deshabilitar a nivel de admisión |
| `hostPort` | ese puerto en el nodo donde se agendó | ✅ PSS `baseline` | baja | ❌ Salvo DaemonSets de infraestructura |
| `hostNetwork: true` | **todos** los puertos del contenedor en el nodo, saltea NetworkPolicy | ✅ PSS `baseline` | baja | ❌ Salvo CNI/monitoreo |
| Controlador Ingress | un LB, TLS terminado, ruteo L7, hook de WAF | n/a | alta (objetos Ingress) | ✅ El camino autorizado |
| Gateway API | igual, más rico, con separación de roles | n/a | alta | ✅ Donde esté disponible |
| `kubectl port-forward` | efímero, en la laptop del operador, autenticado + auditado | n/a | alta (log de auditoría) | ✅ Para depuración |

### 2.5 Recorrido por netfilter: dónde un paquete es realmente filtrable

Esta tabla es la diferencia entre una regla que funciona y una regla que en silencio no hace nada.

| Tráfico | Hooks recorridos (en orden) | Punto de filtrado correcto |
|---|---|---|
| Hacia un proceso del host (`sshd`, kubelet, etcd) | `prerouting raw(-300)` → `conntrack(-200)` → `prerouting mangle(-150)` → `prerouting dstnat(-100)` → **ruteo: local** → `input filter(0)` | `input` ✅ |
| Hacia un NodePort → DNAT hacia una IP de pod | `prerouting raw` → `conntrack` → `prerouting mangle` → **`prerouting dstnat` — kube-proxy hace DNAT acá** → **ruteo: no local** → `forward filter(0)` → `postrouting srcnat(100)` | `prerouting` con prioridad < `-100`, o `forward` ✅ — **`input` NUNCA coincide** ❌ |
| Hacia un `hostPort` → DNAT por el plugin `portmap` del CNI | idéntico a NodePort (`CNI-HOSTPORT-DNAT` en `prerouting nat`) | igual que NodePort |
| Desde el host hacia afuera | `output filter(0)` → `postrouting srcnat` | `output` ✅ |
| Desde un pod hacia afuera (veth → host → WAN) | `prerouting` → `forward filter` → `postrouting srcnat` (masquerade) | `forward` ✅ |

**El bug de hardening más común de todos**: un operador escribe `nft add rule inet filter input tcp dport 30000-32767 drop`, verifica que la regla existe, y el NodePort sigue siendo alcanzable desde internet. Siempre lo va a ser — al paquete se le hace DNAT a una IP de pod en `prerouting` y por lo tanto se rutea a `forward`, nunca a `input`. Respuestas correctas: filtrar en `hook prerouting priority -150`, filtrar en `forward`, o definir `nodePortAddresses` para que kube-proxy directamente nunca instale la regla para esa interfaz.

> Caso borde por completitud: con `externalTrafficPolicy: Local` **y** un pod backend con `hostNetwork`, el destino del DNAT es la IP del nodo misma, así que el paquete *sí* llega a `input`. No te apoyes en esa asimetría — filtrá en `prerouting`.

---

## 3. Manifiestos completos e infraestructura

### 3.1 Inventario de referencia antes de tocar nada

```bash
$ sudo ss -tulpn
Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
udp    UNCONN  0       0         127.0.0.53%lo:53          0.0.0.0:*      users:(("systemd-resolve",pid=712,fd=14))
udp    UNCONN  0       0          10.0.0.11%ens3:68          0.0.0.0:*      users:(("systemd-network",pid=698,fd=20))
udp    UNCONN  0       0               0.0.0.0:8472         0.0.0.0:*
tcp    LISTEN  0       4096          127.0.0.1:10248        0.0.0.0:*      users:(("kubelet",pid=1201,fd=25))
tcp    LISTEN  0       4096          127.0.0.1:10249        0.0.0.0:*      users:(("kube-proxy",pid=2310,fd=15))
tcp    LISTEN  0       4096          127.0.0.1:2379         0.0.0.0:*      users:(("etcd",pid=1690,fd=8))
tcp    LISTEN  0       4096          10.0.0.11:2379         0.0.0.0:*      users:(("etcd",pid=1690,fd=9))
tcp    LISTEN  0       4096          10.0.0.11:2380         0.0.0.0:*      users:(("etcd",pid=1690,fd=7))
tcp    LISTEN  0       4096          127.0.0.1:2381         0.0.0.0:*      users:(("etcd",pid=1690,fd=6))
tcp    LISTEN  0       4096          127.0.0.1:10257        0.0.0.0:*      users:(("kube-controller",pid=1655,fd=3))
tcp    LISTEN  0       4096          127.0.0.1:10259        0.0.0.0:*      users:(("kube-scheduler",pid=1633,fd=3))
tcp    LISTEN  0       4096                  *:6443               *:*      users:(("kube-apiserver",pid=1712,fd=3))
tcp    LISTEN  0       4096                  *:10250              *:*      users:(("kubelet",pid=1201,fd=24))
tcp    LISTEN  0       4096                  *:10256              *:*      users:(("kube-proxy",pid=2310,fd=17))
tcp    LISTEN  0       128                   *:22                 *:*      users:(("sshd",pid=964,fd=4))
tcp    LISTEN  0       4096                  *:111                *:*      users:(("rpcbind",pid=690,fd=8))
tcp    LISTEN  0       5             127.0.0.1:631          0.0.0.0:*      users:(("cupsd",pid=701,fd=7))
```

Dos líneas de ahí deberían hacerte frenar: `rpcbind` en `*:111` y `cupsd`. Ninguno tiene lugar en un nodo de Kubernetes. Esa es la mitad de "minimizar la huella del sistema operativo del host" de este objetivo encontrándose con la mitad de red.

Inventario legible por máquina de todo lo enlazado a una dirección que no sea loopback:

```bash
$ sudo ss -Hltunp | awk '{print $1, $5, $7}' \
    | grep -vE '127\.0\.0\.[0-9]+:|\[::1\]:' \
    | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u
tcp  *:10250                kubelet
tcp  *:10256                kube-proxy
tcp  *:111                  rpcbind
tcp  *:22                   sshd
tcp  *:6443                 kube-apiserver
tcp  10.0.0.11:2379         etcd
tcp  10.0.0.11:2380         etcd
udp  0.0.0.0:8472           -
```

### 3.2 Sacar lo que no debería estar escuchando en absoluto

```bash
$ systemctl list-units --type=socket --state=active --no-pager --no-legend
  avahi-daemon.socket    loaded active running Avahi mDNS/DNS-SD Stack Activation Socket
  cups.socket            loaded active running CUPS Scheduler
  dbus.socket            loaded active running D-Bus System Message Bus Socket
  rpcbind.socket         loaded active running RPCbind Server Activation Socket
  systemd-udevd-control.socket loaded active running udev Control Socket

$ sudo systemctl disable --now avahi-daemon.socket avahi-daemon.service \
                                cups.socket cups.service \
                                rpcbind.socket rpcbind.service
Removed "/etc/systemd/system/sockets.target.wants/avahi-daemon.socket".
Removed "/etc/systemd/system/multi-user.target.wants/cups.service".
Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".

$ sudo systemctl mask avahi-daemon.socket cups.socket rpcbind.socket
Created symlink /etc/systemd/system/avahi-daemon.socket → /dev/null.
Created symlink /etc/systemd/system/cups.socket → /dev/null.
Created symlink /etc/systemd/system/rpcbind.socket → /dev/null.
```

`mask` en lugar de `disable` importa: una actualización de paquete o una dependencia activada por socket puede reactivar una unidad meramente deshabilitada; una unidad enmascarada no puede arrancar.

### 3.3 `/etc/nftables.conf` — nodo worker, completo

```nft
#!/usr/sbin/nft -f
#
# /etc/nftables.conf — Kubernetes worker node baseline (CKS v1.34 reference)
# Enforcement model:
#   prerouting_guard  : filters NodePort/hostPort BEFORE kube-proxy DNAT (priority -150)
#   input             : default-deny for traffic terminating on the host
#   forward           : pod egress restrictions (link-local metadata)
#   output            : host egress restrictions
#
# Apply with:  sudo nft -f /etc/nftables.conf
# Persist with: sudo systemctl enable --now nftables.service

flush ruleset

define WAN_IF    = "ens3"
define POD_CIDR  = 10.244.0.0/16
define SVC_CIDR  = 10.96.0.0/12
define IMDS      = 169.254.169.254

table inet k8s_node {

    # --- address sets: the only thing you edit day to day -------------------
    set admin_cidrs {
        type ipv4_addr
        flags interval
        comment "Bastion hosts / SRE jump boxes allowed to SSH"
        elements = { 10.0.100.0/24, 198.51.100.7/32 }
    }

    set control_plane {
        type ipv4_addr
        comment "kube-apiserver source IPs allowed to reach the kubelet"
        elements = { 10.0.0.11, 10.0.0.12, 10.0.0.13 }
    }

    set cluster_nodes {
        type ipv4_addr
        flags interval
        comment "All node IPs: CNI data plane and node-to-node health"
        elements = { 10.0.0.0/24 }
    }

    set lb_subnets {
        type ipv4_addr
        flags interval
        comment "Cloud/HAProxy load balancers allowed to health-check and hit NodePorts"
        elements = { 10.0.200.0/24 }
    }

    # --- ring 1a: pre-DNAT guard -------------------------------------------
    # Runs at priority -150: AFTER conntrack (-200) so ct state is valid,
    # BEFORE dstnat (-100) so kube-proxy has not yet rewritten the destination.
    # This is the ONLY correct place to filter NodePort and hostPort traffic.
    chain prerouting_guard {
        type filter hook prerouting priority -150; policy accept;

        iifname != $WAN_IF accept
        ct state established,related accept

        ip saddr @cluster_nodes accept
        ip saddr @admin_cidrs   accept
        ip saddr @lb_subnets tcp dport 30000-32767 accept
        ip saddr @lb_subnets udp dport 30000-32767 accept

        tcp dport 30000-32767 limit rate 5/minute log prefix "nft nodeport-drop: " level warn
        tcp dport 30000-32767 counter drop
        udp dport 30000-32767 counter drop
    }

    # --- ring 1b: host-terminated traffic ----------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid counter drop

        # CNI / overlay interfaces are trusted; pods reach node services
        # through these, not through the WAN NIC.
        iifname "cilium_host" accept
        iifname "cilium_net"  accept
        iifname "lxc*"        accept
        iifname "cni0"        accept
        iifname "flannel.1"   accept
        iifname "vxlan.calico" accept

        # DHCP client (broadcast replies do not match conntrack)
        udp sport 67 udp dport 68 accept

        # ICMP: keep PMTUD working or you will chase phantom TLS hangs
        ip protocol icmp icmp type { echo-request, echo-reply,
                                     destination-unreachable,
                                     time-exceeded, parameter-problem } \
            limit rate 20/second accept
        meta l4proto ipv6-icmp accept

        # --- SSH: bastion only, rate limited, everything else logged --------
        ip saddr @admin_cidrs tcp dport 22 ct state new \
            limit rate 6/minute burst 3 packets accept
        ip saddr @admin_cidrs tcp dport 22 accept
        tcp dport 22 limit rate 5/minute log prefix "nft ssh-drop: " level warn
        tcp dport 22 counter drop

        # --- kubelet API: control plane and peer nodes only ----------------
        ip saddr @control_plane  tcp dport 10250 accept
        ip saddr @cluster_nodes  tcp dport 10250 accept

        # --- kube-proxy healthz: load balancers + peers --------------------
        ip saddr @lb_subnets     tcp dport 10256 accept
        ip saddr @cluster_nodes  tcp dport 10256 accept

        # --- CNI data plane: peer nodes only -------------------------------
        # Cilium: 8472/udp VXLAN, 4240/tcp health, 51871/udp WireGuard
        # Calico: 4789/udp VXLAN, 179/tcp BGP, 5473/tcp Typha, 51820/udp WG
        ip saddr @cluster_nodes udp dport { 8472, 4789, 51820, 51871 } accept
        ip saddr @cluster_nodes tcp dport { 4240, 179, 5473 } accept

        # --- node exporter, scraped from the monitoring subnet only --------
        ip saddr @cluster_nodes tcp dport 9100 accept

        limit rate 10/second log prefix "nft input-drop: " level info flags all
        counter drop
    }

    # --- ring 1c: transit traffic (pod egress, NodePort after DNAT) ---------
    chain forward {
        type filter hook forward priority filter; policy accept;

        ct state established,related accept

        # Pods must never reach the cloud instance metadata service.
        # NOTE: with Cilium in full eBPF host-routing mode this hook may be
        # bypassed — enforce the same rule with a CiliumNetworkPolicy too.
        ip saddr $POD_CIDR ip daddr $IMDS \
            limit rate 5/minute log prefix "nft imds-drop: " level warn
        ip saddr $POD_CIDR ip daddr $IMDS counter drop

        # Pods must not reach the node management subnet directly.
        ip saddr $POD_CIDR ip daddr 10.0.100.0/24 counter drop

        # Belt-and-braces for NodePort that slipped past prerouting_guard.
        iifname $WAN_IF ip daddr $POD_CIDR ct state new \
            tcp dport 30000-32767 counter drop
    }

    # --- ring 1d: host egress ----------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;

        # Everything else on the host is allowed out; tighten per environment.
        # Example lockdown of an unused protocol family:
        meta l4proto sctp counter drop
    }
}
```

Aplicalo con un timer de rollback para que un error no pueda dejarte afuera:

```bash
$ sudo cp /etc/nftables.conf /etc/nftables.conf.bak
$ sudo nft -c -f /etc/nftables.conf.new           # syntax check only, does not load
$ sudo systemd-run --on-active=180 --unit=nft-rollback \
      /usr/sbin/nft -f /etc/nftables.conf.bak
Running timer as unit: nft-rollback.timer
Will run service as unit: nft-rollback.service

$ sudo nft -f /etc/nftables.conf.new
# --- open a SECOND ssh session now and confirm it works ---
$ sudo systemctl stop nft-rollback.timer
$ sudo cp /etc/nftables.conf.new /etc/nftables.conf
$ sudo systemctl enable --now nftables.service
Created symlink /etc/systemd/system/multi-user.target.wants/nftables.service → /usr/lib/systemd/system/nftables.service.
```

En Fedora/RHEL, asegurate de que `firewalld` no esté peleando con vos:

```bash
$ sudo systemctl disable --now firewalld
$ sudo systemctl mask firewalld
Created symlink /etc/systemd/system/firewalld.service → /dev/null.
```

### 3.4 `/etc/nftables.conf` — delta del control plane

Agregá esta tabla (o estas cadenas) en los nodos del control plane:

```nft
table inet k8s_control_plane {
    set etcd_peers {
        type ipv4_addr
        comment "Other etcd members ONLY — never the worker subnet"
        elements = { 10.0.0.11, 10.0.0.12, 10.0.0.13 }
    }

    set apiserver_clients {
        type ipv4_addr
        flags interval
        comment "Nodes, LBs, and the SRE bastion subnet"
        elements = { 10.0.0.0/24, 10.0.200.0/24, 10.0.100.0/24 }
    }

    chain input {
        type filter hook input priority filter + 5; policy accept;

        # etcd: strictly peer-to-peer. A worker node reaching 2379 is an
        # incident, not a feature.
        ip saddr @etcd_peers tcp dport { 2379, 2380 } accept
        tcp dport { 2379, 2380 } \
            log prefix "nft etcd-drop: " level warn counter drop

        # kube-apiserver
        ip saddr @apiserver_clients tcp dport 6443 accept
        tcp dport 6443 counter drop

        # controller-manager / scheduler must never be reachable off-box.
        tcp dport { 10257, 10259 } \
            log prefix "nft cp-secure-port-drop: " level warn counter drop
    }
}
```

> Fijate en el `priority filter + 5`: esta cadena se recorre *después* de la cadena `input` de `k8s_node` (prioridad 0). Como `k8s_node input` tiene `policy drop`, los paquetes que ella descarta nunca llegan acá. Mantené la política de la cadena del control plane en `accept` y apoyate en drops explícitos, o fusioná ambas en una sola tabla. Mezclar default-deny entre dos cadenas base del mismo hook es una fuente clásica de "la regla existe pero nada coincide".

### 3.5 Anillo 2 — kube-proxy: dejar de abrir NodePorts en todos lados

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    app: kube-proxy
data:
  config.conf: |-
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    bindAddress: 0.0.0.0
    bindAddressHardFail: false
    clientConnection:
      acceptContentTypes: ""
      burst: 10
      contentType: application/vnd.kubernetes.protobuf
      kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
      qps: 5
    clusterCIDR: 10.244.0.0/16
    configSyncPeriod: 15m0s
    conntrack:
      maxPerCore: 32768
      min: 131072
      tcpCloseWaitTimeout: 1h0m0s
      tcpEstablishedTimeout: 24h0m0s
    detectLocalMode: ClusterCIDR
    enableProfiling: false
    healthzBindAddress: 0.0.0.0:10256
    hostnameOverride: ""
    iptables:
      localhostNodePorts: false
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 1s
      syncPeriod: 30s
    ipvs:
      excludeCIDRs: null
      minSyncPeriod: 0s
      scheduler: ""
      strictARP: false
      syncPeriod: 30s
    metricsBindAddress: 127.0.0.1:10249
    mode: iptables
    # ── THE control that matters for 5.3 ────────────────────────────────
    # kube-proxy only installs NodePort rules for addresses inside these
    # CIDRs. An empty list (the default) means "every address on the node",
    # which is how NodePorts end up reachable from the public NIC.
    nodePortAddresses:
      - 10.0.0.0/24
    # ────────────────────────────────────────────────────────────────────
    oomScoreAdj: -999
    portRange: ""
    showHiddenMetricsForVersion: ""
```

```bash
$ kubectl -n kube-system apply -f kube-proxy-cm.yaml
configmap/kube-proxy configured

$ kubectl -n kube-system rollout restart daemonset/kube-proxy
daemonset.apps/kube-proxy restarted

$ kubectl -n kube-system rollout status daemonset/kube-proxy
Waiting for daemon set "kube-proxy" rollout to finish: 2 out of 4 new pods have been updated...
daemon set "kube-proxy" successfully rolled out
```

Compromisos que hay que declarar explícitamente:

| Ajuste | Efecto | Costo |
|---|---|---|
| `nodePortAddresses: [10.0.0.0/24]` | Los NodePorts se enlazan solo en la NIC privada | Un LB externo fuera de ese CIDR ya no puede alcanzar los NodePorts directamente |
| `enableProfiling: false` | Elimina `/debug/pprof` del servidor healthz | No hay pprof en vivo; usá builds de depuración efímeros |
| `metricsBindAddress: 127.0.0.1:10249` | Las métricas no son alcanzables desde fuera del nodo | Prometheus tiene que hacer scrape vía un sidecar hostNetwork o el node exporter |
| `healthzBindAddress: 127.0.0.1:10256` | Cierra 10256 por completo | **Rompe los health checks del LB de la nube** con `externalTrafficPolicy: Local` — dejalo en `0.0.0.0` y filtralo por firewall hacia la subred del LB |
| `iptables.localhostNodePorts: false` | Los NodePorts no son alcanzables vía `127.0.0.1` | Los bucles de depuración local deben usar la IP del nodo |

Los releases recientes de kube-proxy además aceptan el valor especial `nodePortAddresses: ["primary"]` (enlazar solo en la IP primaria del nodo). Verificá su disponibilidad en el clúster que tenés enfrente antes de depender de él:

```bash
$ kubectl -n kube-system exec ds/kube-proxy -- kube-proxy --help 2>&1 | grep -A3 nodeport-addresses
      --nodeport-addresses strings   A list of CIDR ranges that contain valid node IPs, or
                                     alternatively, the single string 'primary'. ...
```

Achicá el rango mismo en el API server para que el agujero sea chico incluso cuando se permitan NodePorts:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (excerpt)
    - --service-node-port-range=30000-30100
```

### 3.6 Anillo 3 — binding de componentes y authn/authz

`/var/lib/kubelet/config.yaml` (completo, con las partes que importan para 5.3 marcadas):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0                 # bind address of the 10250 API
port: 10250
readOnlyPort: 0                  # ← 10255 must stay closed. Never set this to 10255.
healthzBindAddress: 127.0.0.1    # ← 10248 stays on loopback
healthzPort: 10248
authentication:
  anonymous:
    enabled: false               # ← unauthenticated callers get 401
  webhook:
    enabled: true                # ← bearer tokens validated via TokenReview
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # ← mTLS against the cluster CA
authorization:
  mode: Webhook                  # ← never AlwaysAllow; SubjectAccessReview per request
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
tlsCertFile: /var/lib/kubelet/pki/kubelet.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet.key
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
tlsMinVersion: VersionTLS12
rotateCertificates: true
serverTLSBootstrap: true
protectKernelDefaults: true
makeIPTablesUtilChains: true
streamingConnectionIdleTimeout: 5m0s
enableDebuggingHandlers: true    # set false to remove exec/attach/portforward
                                 # from the kubelet — breaks `kubectl exec`
eventRecordQPS: 5
clusterDomain: cluster.local
clusterDNS:
  - 10.96.0.10
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests
```

```bash
$ sudo systemctl restart kubelet
$ sudo journalctl -u kubelet -n 5 --no-pager
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.113 4188 server.go:466] "Kubelet version" kubeletVersion="v1.34.1"
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.311 4188 server.go:1245] "Started kubelet"
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.315 4188 server.go:236] "Starting to listen" address="0.0.0.0" port=10250
```

`/etc/kubernetes/manifests/kube-apiserver.yaml` — los flags relevantes para el acceso externo:

```yaml
    - --bind-address=0.0.0.0                       # cannot be loopback in a multi-node cluster
    - --secure-port=6443
    - --anonymous-auth=false
    - --profiling=false
    - --service-node-port-range=30000-30100
    - --enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs,PodSecurity
    - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS
    - --egress-selector-config-file=/etc/kubernetes/konnectivity/egress-selector.yaml
```

`DenyServiceExternalIPs` es un plugin de admisión incorporado que rechaza cualquier Service que especifique `spec.externalIPs` — el arreglo más barato posible para la peor primitiva de exposición de la API.

`/etc/kubernetes/manifests/etcd.yaml`:

```yaml
    - --listen-client-urls=https://127.0.0.1:2379,https://10.0.0.11:2379
    - --advertise-client-urls=https://10.0.0.11:2379
    - --listen-peer-urls=https://10.0.0.11:2380
    - --listen-metrics-urls=http://127.0.0.1:2381
    - --client-cert-auth=true
    - --peer-client-cert-auth=true
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

`kube-controller-manager` / `kube-scheduler`:

```yaml
    - --bind-address=127.0.0.1
    - --profiling=false
```

**Konnectivity — minimizar el egreso del API server.** Por defecto el API server disca `10250` y los endpoints de pods/services directamente desde la red del control plane. `EgressSelectorConfiguration` canaliza eso a través de un proxy para que el control plane no necesite ninguna ruta directa hacia la red del clúster:

```yaml
# /etc/kubernetes/konnectivity/egress-selector.yaml
apiVersion: apiserver.k8s.io/v1beta1
kind: EgressSelectorConfiguration
egressSelections:
  - name: cluster
    connection:
      proxyProtocol: GRPC
      transport:
        uds:
          udsName: /etc/kubernetes/konnectivity-server/konnectivity-server.socket
  - name: controlplane
    connection:
      proxyProtocol: Direct
  - name: etcd
    connection:
      proxyProtocol: Direct
```

### 3.7 Anillo 2 — host firewall de Cilium (política de nodo declarativa)

Habilitá el host firewall y decile a Cilium a qué dispositivos engancharse:

```bash
$ helm upgrade cilium cilium/cilium --version 1.18.1 \
    --namespace kube-system --reuse-values \
    --set hostFirewall.enabled=true \
    --set devices='{ens3}'
Release "cilium" has been upgraded. Happy Helming!

$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
```

**Siempre auditá antes de aplicar** — una `CiliumClusterwideNetworkPolicy` con un `nodeSelector` da vuelta el host endpoint de default-allow a default-deny y puede dejar afuera a toda la flota de una sola vez:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint list | grep 'reserved:host'
1364       Disabled           Disabled          1          reserved:host   ready

$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint config 1364 PolicyAuditMode=Enabled
Endpoint 1364 configuration updated successfully
```

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: host-firewall-workers
spec:
  description: >-
    Default-deny on the host network namespace of worker nodes. Only the
    control plane, peer nodes, the bastion subnet and the load balancers may
    open new connections to a node.
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Cilium-internal entities: health checks, peer nodes, the API server,
    # and traffic originating from the node itself.
    - fromEntities:
        - health
        - remote-node
        - kube-apiserver
        - host

    # kubelet API strictly from control-plane addresses.
    - fromCIDRSet:
        - cidr: 10.0.0.11/32
        - cidr: 10.0.0.12/32
        - cidr: 10.0.0.13/32
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP

    # SSH strictly from the bastion subnet.
    - fromCIDRSet:
        - cidr: 10.0.100.0/24
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP

    # Load-balancer health checks.
    - fromCIDRSet:
        - cidr: 10.0.200.0/24
      toPorts:
        - ports:
            - port: "10256"
              protocol: TCP

    # CNI data plane between nodes.
    - fromCIDRSet:
        - cidr: 10.0.0.0/24
      toPorts:
        - ports:
            - port: "8472"
              protocol: UDP
            - port: "4240"
              protocol: TCP
            - port: "51871"
              protocol: UDP
  egress:
    - toEntities:
        - remote-node
        - kube-apiserver
        - cluster
    # DNS and package/registry egress via the corporate proxy only.
    - toCIDRSet:
        - cidr: 10.0.50.0/24
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "3128"
              protocol: TCP
    # Explicitly deny the metadata service from the host too.
    - toCIDRSet:
        - cidr: 0.0.0.0/0
          except:
            - 169.254.169.254/32
```

Leé los veredictos de auditoría antes de aplicar:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg monitor -t policy-verdict --related-to 1364
Policy verdict log: flow 0x0 local EP ID 1364, remote ID 6, proto 6, ingress, action audit, match none, 10.0.77.4:51234 -> 10.0.0.21:9100 tcp SYN
Policy verdict log: flow 0x0 local EP ID 1364, remote ID 1, proto 6, ingress, action allow, match L3-L4, 10.0.0.11:44210 -> 10.0.0.21:10250 tcp SYN
```

La línea `action audit, match none` es una conexión que *habría sido descartada* — scraping de node-exporter en 9100 desde una subred de monitoreo que no está en la política. Corregí la política, reauditá hasta que el log quede limpio, y después:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint config 1364 PolicyAuditMode=Disabled
Endpoint 1364 configuration updated successfully
```

### 3.8 Anillo 2 — host endpoints de Calico (con pre-DNAT)

```yaml
apiVersion: projectcalico.org/v3
kind: HostEndpoint
metadata:
  name: node-1-ens3
  labels:
    host-endpoint: "true"
    role: k8s-worker
spec:
  interfaceName: ens3
  node: node-1
  expectedIPs:
    - 10.0.0.21
---
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: node-perimeter
spec:
  selector: has(host-endpoint)
  order: 100
  # preDNAT + applyOnForward is what lets this policy see NodePort traffic
  # BEFORE kube-proxy rewrites the destination — the Calico equivalent of the
  # nftables prerouting_guard chain.
  preDNAT: true
  applyOnForward: true
  types:
    - Ingress
  ingress:
    - action: Allow
      source:
        nets:
          - 10.0.0.0/24      # peer nodes
          - 10.0.100.0/24    # bastion
          - 10.0.200.0/24    # load balancers
    - action: Log
      protocol: TCP
      destination:
        ports: [30000, 30001, 30002]
    - action: Deny
      protocol: TCP
      destination:
        ports: ["30000:32767"]
    - action: Deny
      protocol: UDP
      destination:
        ports: ["30000:32767"]
```

> **Advertencia de bloqueo con Calico**: en el instante en que existe un `HostEndpoint` para una interfaz, Calico le aplica default-deny, quedando abiertos únicamente los puertos *failsafe*. Inspeccioná y, si hace falta, ampliá los failsafes **antes** de crear el HostEndpoint:
> ```bash
> $ calicoctl get felixconfiguration default -o yaml | grep -A20 failsafe
> ```
> Los valores por defecto incluyen entrada en 22, 68, 179, 2379, 2380, 5473, 6443, 6666, 6667 y salida en 53, 67, 179, 2379, 2380, 5473, 6443, 6666, 6667. Nunca saques 22 y 6443 de la lista de entrada en un host remoto.

### 3.9 Anillo 4 — control de admisión: evitar que el agujero siquiera se pida

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: restrict-external-service-exposure
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["services"]
  validations:
    - expression: "object.spec.type != 'NodePort'"
      message: >-
        Service type NodePort is not permitted: it opens a port on every node
        in the cluster. Expose the workload through the shared Ingress
        controller instead.
      reason: Forbidden

    - expression: >-
        object.spec.type != 'LoadBalancer' ||
        (has(object.metadata.annotations) &&
         'service.beta.kubernetes.io/aws-load-balancer-scheme' in object.metadata.annotations &&
         object.metadata.annotations['service.beta.kubernetes.io/aws-load-balancer-scheme'] == 'internal')
      message: >-
        LoadBalancer Services must be annotated
        service.beta.kubernetes.io/aws-load-balancer-scheme=internal.
        Internet-facing load balancers require a platform-team exception.
      reason: Forbidden

    - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
      message: >-
        spec.externalIPs is forbidden: it lets a namespaced object hijack
        arbitrary destination IPs cluster-wide.
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: restrict-external-service-exposure-binding
spec:
  policyName: restrict-external-service-exposure
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "ingress-nginx", "platform-break-glass"]
```

```bash
$ kubectl apply -f restrict-external-service-exposure.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/restrict-external-service-exposure created
validatingadmissionpolicybinding.admissionregistration.k8s.io/restrict-external-service-exposure-binding created

$ kubectl -n team-a create service nodeport admin-ui --tcp=80:8080
error: failed to create NodePort service: services "admin-ui" is forbidden:
ValidatingAdmissionPolicy 'restrict-external-service-exposure' with binding
'restrict-external-service-exposure-binding' denied request: Service type
NodePort is not permitted: it opens a port on every node in the cluster.
Expose the workload through the shared Ingress controller instead.
```

Cerrá `hostNetwork` y `hostPort` con la admisión Pod Security incorporada — `baseline` prohíbe ambos:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
```

```bash
$ kubectl -n team-a run hn --image=nginx:1.27 --overrides='{"spec":{"hostNetwork":true}}'
Error from server (Forbidden): pods "hn" is forbidden: violates PodSecurity
"baseline:v1.34": host namespaces (hostNetwork=true)
```

### 3.10 Egreso de pods: bloquear el servicio de metadata en la capa de la API

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-internet-except-linklocal
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    # CoreDNS only
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Public internet, with every RFC1918 range and the whole 169.254.0.0/16
    # link-local block carved out. 169.254.169.254 is the cloud IMDS.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

Complementá en la capa de nube — en AWS, IMDSv2 con un hop limit de 1 hace que el servicio de metadata sea inalcanzable desde dentro del network namespace de un pod, sin importar la política:

```bash
$ aws ec2 modify-instance-metadata-options \
    --instance-id i-0abc123def4567890 \
    --http-tokens required \
    --http-put-response-hop-limit 1 \
    --http-endpoint enabled
{
    "InstanceId": "i-0abc123def4567890",
    "InstanceMetadataOptions": {
        "State": "pending",
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 1,
        "HttpEndpoint": "enabled"
    }
}
```

### 3.11 `/etc/ssh/sshd_config.d/50-hardening.conf`

```
# Bind only to the management interface; do not answer on the public NIC.
AddressFamily inet
ListenAddress 10.0.0.21

# Authentication
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowGroups k8s-admins
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20

# Forwarding: disabling TCP forwarding also blocks `ssh -L` tunnels to the
# API server. Keep it off on workers; allow it on the bastion only.
AllowTcpForwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no

# Session hygiene
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
LogLevel VERBOSE
Banner /etc/issue.net

# Crypto
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
```

```bash
$ sudo sshd -t && echo "config OK"
config OK

$ sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|allowtcpforwarding|listenaddress|allowgroups)'
listenaddress 10.0.0.21:22
permitrootlogin no
passwordauthentication no
allowtcpforwarding no
allowgroups k8s-admins

$ sudo systemctl reload sshd
```

---

## 4. Verificación: probar que la superficie está realmente cerrada

### 4.1 Escaneo de puertos externo desde fuera del perímetro

```bash
$ sudo nmap -Pn -n -sS --reason \
    -p 22,111,179,2379,2380,4240,5473,6443,9100,10248,10249,10250,10255,10256,10257,10259,30000-30100 \
    10.0.0.21
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-04 09:58 UTC
Nmap scan report for 10.0.0.21
Host is up, received user-set (0.00061s latency).
Not shown: 114 filtered tcp ports (no-response)
PORT      STATE  SERVICE      REASON
22/tcp    open   ssh          syn-ack ttl 64
10250/tcp open   unknown      syn-ack ttl 64
10256/tcp open   unknown      syn-ack ttl 64

Nmap done: 1 IP address (1 host up) scanned in 2.31 seconds
```

El mismo escaneo desde un host fuera de `admin_cidrs` y fuera de `cluster_nodes`:

```bash
$ sudo nmap -Pn -n -sS -p 22,10250,10256,30000-30100 10.0.0.21
Nmap scan report for 10.0.0.21
Host is up, received user-set (0.00088s latency).
All 104 scanned ports on 10.0.0.21 are in ignored states.
Not shown: 104 filtered tcp ports (no-response)

Nmap done: 1 IP address (1 host up) scanned in 2.14 seconds
```

`filtered` (sin respuesta) en lugar de `closed` (RST) es lo que produce una política `drop`, y es lo que querés: no le da ninguna señal al escáner.

### 4.2 Alcanzabilidad y autorización del kubelet

```bash
# Anonymous, before hardening — full pod inventory, no credentials:
$ curl -sk https://10.0.0.21:10250/pods | jq -r '.items[].metadata.name' | head -3
kube-proxy-8bh2t
cilium-x2n7q
payments-api-7d9f8c5b4-lm2xk

# After anonymous-auth=false:
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.0.21:10250/pods
401

$ curl -sk https://10.0.0.21:10250/pods
Unauthorized

# With a valid but unprivileged ServiceAccount token — authenticated, denied:
$ TOKEN=$(kubectl -n team-a create token default)
$ curl -sk -H "Authorization: Bearer $TOKEN" https://10.0.0.21:10250/pods
Forbidden (user=system:serviceaccount:team-a:default, verb=get,
resource=nodes, subresource=proxy)

# Read-only port must refuse the connection outright:
$ curl -s --max-time 3 http://10.0.0.21:10255/pods; echo "exit=$?"
exit=7
```

El código de salida 7 de `curl` es "failed to connect" — el socket no existe. Eso es `readOnlyPort: 0` haciendo su trabajo.

### 4.3 etcd debe rechazar todo lo que no sea un peer del control plane

```bash
$ ETCDCTL_API=3 etcdctl --endpoints=https://10.0.0.11:2379 \
    --command-timeout=5s get / --prefix --keys-only
{"level":"warn","ts":"2026-08-04T10:02:44.881Z","logger":"etcd-client",
 "caller":"v3@v3.5.16/retry_interceptor.go:63",
 "msg":"retrying of unary invoker failed",
 "error":"rpc error: code = DeadlineExceeded desc = latest balancer error:
 last connection error: connection error: desc = \"transport: authentication
 handshake failed: tls: failed to verify certificate: x509: certificate
 signed by unknown authority\""}
Error: context deadline exceeded

# Even skipping verification, client-cert-auth blocks it:
$ ETCDCTL_API=3 etcdctl --endpoints=https://10.0.0.11:2379 \
    --insecure-skip-tls-verify --command-timeout=5s endpoint health
{"level":"warn", ... "error":"... remote error: tls: certificate required"}
https://10.0.0.11:2379 is unhealthy: failed to commit proposal: context deadline exceeded

# From a worker node, the firewall should not even complete the handshake:
$ nc -zv -w3 10.0.0.11 2379
nc: connect to 10.0.0.11 port 2379 (tcp) timed out: Operation now in progress
```

### 4.4 El NodePort realmente es inalcanzable (la regla que la gente hace mal)

```bash
$ kubectl -n team-a get svc admin-ui -o wide
NAME       TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE   SELECTOR
admin-ui   NodePort   10.96.201.44   <none>        80:31380/TCP   4m    app=admin-ui

# From inside the node subnet (allowed):
$ curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.21:31380/
200

# From outside every allowed set:
$ curl -s --max-time 4 -o /dev/null -w '%{http_code}\n' http://10.0.0.21:31380/
000
curl: (28) Connection timed out after 4001 milliseconds

# Confirm the drop counter is actually incrementing — this is the proof that
# your rule, not luck, is doing the blocking:
$ sudo nft list chain inet k8s_node prerouting_guard
table inet k8s_node {
        chain prerouting_guard {
                type filter hook prerouting priority mangle; policy accept;
                iifname != "ens3" accept
                ct state established,related accept
                ip saddr @cluster_nodes accept
                ip saddr @admin_cidrs accept
                ip saddr @lb_subnets tcp dport 30000-32767 accept
                ip saddr @lb_subnets udp dport 30000-32767 accept
                tcp dport 30000-32767 limit rate 5/minute log prefix "nft nodeport-drop: " level warn
                tcp dport 30000-32767 counter packets 12 bytes 720 drop
                udp dport 30000-32767 counter packets 0 bytes 0 drop
        }
}

$ sudo journalctl -k -n 3 --no-pager | grep nodeport-drop
Aug 04 10:07:19 node-1 kernel: nft nodeport-drop: IN=ens3 OUT= MAC=... SRC=203.0.113.90 DST=10.0.0.21 LEN=60 PROTO=TCP SPT=51882 DPT=31380 SYN
```

Verificación cruzada de que kube-proxy dejó de instalar la regla de NodePort en direcciones no permitidas:

```bash
$ sudo iptables -t nat -L KUBE-NODEPORTS -n --line-numbers
Chain KUBE-NODEPORTS (1 references)
num  target                     prot opt source       destination
1    KUBE-EXT-XPGD46QRK7WJZT7O  tcp  --  0.0.0.0/0    10.0.0.21   /* team-a/admin-ui */ tcp dpt:31380
```

Con `nodePortAddresses` sin definir, `destination` diría `0.0.0.0/0`. El destino acotado es el efecto visible del ajuste.

Si tu clúster corre kube-proxy en modo `nftables`:

```bash
$ sudo nft list table ip kube-proxy | grep -A6 'chain nodeport'
        chain nodeports {
                ip daddr @nodeport-ips meta l4proto tcp th dport 31380 goto service-XPGD46QR-team-a/admin-ui/tcp/http
        }

$ sudo nft list set ip kube-proxy nodeport-ips
table ip kube-proxy {
        set nodeport-ips {
                type ipv4_addr
                comment "IPs that accept NodePort traffic"
                elements = { 10.0.0.21 }
        }
}
```

### 4.5 Auditoría de las primitivas de exposición en todo el clúster

```bash
$ kubectl get svc -A -o json | jq -r '
    .items[]
    | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer" or (.spec.externalIPs|length>0))
    | [.metadata.namespace, .metadata.name, .spec.type,
       ((.spec.ports//[])|map(.nodePort|tostring)|join(",")),
       ((.spec.externalIPs//[])|join(","))]
    | @tsv' | column -t
team-a       admin-ui        NodePort      31380       
team-b       metrics-proxy   NodePort      30099       
ingress-nginx ingress-nginx-controller LoadBalancer 31234,30987  
legacy       vip-service     ClusterIP                 192.0.2.44

$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select(.spec.hostNetwork==true
             or ([.spec.containers[].ports//[] | .[]?.hostPort] | map(select(. != null)) | length > 0))
    | [.metadata.namespace, .metadata.name,
       (.spec.hostNetwork|tostring),
       ([.spec.containers[].ports//[] | .[]?.hostPort] | map(select(.!=null)) | join(","))]
    | @tsv' | column -t
kube-system  cilium-x2n7q            true
kube-system  kube-proxy-8bh2t        true
monitoring   node-exporter-4kd9v     true   9100
team-c       legacy-agent-6f8b7      false  8125
```

`legacy/vip-service` con un `spec.externalIPs` de `192.0.2.44` y `team-c/legacy-agent` enlazando `hostPort: 8125` son ambos hallazgos. Ninguno se habría creado con lo de §3.9 en su lugar.

### 4.6 Correr el benchmark de CIS y leer los controles de red

```bash
$ kube-bench run --targets master,node --check 1.2.16,1.3.2,1.4.2,4.2.4,4.2.10 --noremediations
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.16 Ensure that the --profiling argument is set to false
[INFO] 1.3 Controller Manager
[PASS] 1.3.2 Ensure that the --profiling argument is set to false
[INFO] 1.4 Scheduler
[PASS] 1.4.2 Ensure that the --bind-address argument is set to 127.0.0.1
[INFO] 4 Worker Node Security Configuration
[INFO] 4.2 Kubelet
[PASS] 4.2.4 Verify that the --read-only-port argument is set to 0
[PASS] 4.2.10 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set

== Summary total ==
5 checks PASS
0 checks FAIL
0 checks WARN
0 checks INFO
```

---

## 5. Diagnóstico de fallas

### 5.1 Síntoma → causa → comando → arreglo

| Síntoma | Causa más probable | Comando de diagnóstico | Arreglo |
|---|---|---|---|
| La regla existe, el NodePort sigue alcanzable desde la WAN | Se filtra en `input`; al paquete se le hace DNAT en `prerouting` y se rutea a `forward` | `sudo nft list chain inet k8s_node input` muestra `counter packets 0` | Mover la regla a `hook prerouting priority -150`, o definir `nodePortAddresses` |
| `kubectl exec/logs/port-forward` se cuelga y después `error: unable to upgrade connection: ... i/o timeout` | 10250 bloqueado desde las IPs del control plane | `nc -zv <cp-ip-as-source> <node-ip> 10250` desde un nodo del control plane | Agregar las IPs del control plane a la regla de permiso de 10250 |
| `kubectl top nodes` → `Metrics API not available` | El pod metrics-server (no el API server) es el que llama a 10250 | `kubectl -n kube-system logs deploy/metrics-server \| tail` muestra `dial tcp 10.0.0.21:10250: i/o timeout` | Permitir el CIDR de pods, o la IP del nodo si metrics-server usa `hostNetwork` |
| Los pods del nodo A no alcanzan a los pods del nodo B; el tráfico en el mismo nodo anda bien | Puerto de overlay descartado (8472/4789 UDP, 51820/51871 WireGuard) | `sudo nft list chain inet k8s_node input \| grep -E '8472\|4789'` y `journalctl -k \| grep input-drop \| grep DPT=8472` | Permitir el puerto del CNI desde `@cluster_nodes` |
| `cilium-health status` de Cilium muestra pares inalcanzables | 4240/tcp descartado | `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --all-health` | Permitir 4240 desde `@cluster_nodes` |
| Los nodos de Calico muestran `BGP not established` | 179/tcp descartado | `calicoctl node status` | Permitir 179 desde `@cluster_nodes` / ToR |
| El LB de la nube marca todos los nodos como no saludables | `healthzBindAddress` movido a loopback, o 10256 bloqueado por firewall desde la subred del LB | `curl -s http://<node-ip>:10256/healthz` desde la subred del LB | Mantener 10256 en `0.0.0.0`, permitir solo `@lb_subnets` |
| Una sesión existente sobrevive a una nueva regla DROP | La entrada de conntrack ya está `ESTABLISHED`; `ct state established accept` coincide primero | `sudo conntrack -L -d 10.0.0.21 --dport 31380` | `sudo conntrack -D -d 10.0.0.21 -p tcp --dport 31380` |
| Todas las reglas de kube-proxy desaparecen tras un cambio de configuración | `firewalld --reload` vació las tablas | `sudo iptables -t nat -L KUBE-SERVICES -n \| wc -l` devuelve ~2 | Parar/enmascarar firewalld; `kubectl -n kube-system rollout restart ds/kube-proxy` para reprogramar |
| Los handshakes TLS se cuelgan exactamente alrededor de los 1500 bytes | ICMP `fragmentation-needed` descartado, PMTUD roto | `ping -M do -s 1472 <peer>` | Permitir `icmp type destination-unreachable` en `input` |
| Toda la flota inalcanzable justo después de aplicar una CCNP | Host firewall de Cilium aplicado sin una pasada de auditoría | Acceso por consola/serie → `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled` | Auditar siempre primero; mantener una vía serie/consola |
| El nodo bien, pero una interfaz queda en default-deny con Calico | Se creó un `HostEndpoint`; solo quedan abiertos los failsafes | `calicoctl get felixconfiguration default -o yaml` | Ampliar `failsafeInboundHostPorts` antes de crear HostEndpoints |
| El pod sigue alcanzando `169.254.169.254` pese a la regla en `forward` | El host-routing eBPF de Cilium saltea el hook `forward` de netfilter | `kubectl exec -it pod -- curl -s -m2 169.254.169.254/latest/meta-data/` devuelve datos | Aplicar con un `except` de egreso en una `CiliumNetworkPolicy`, y poner el hop-limit 1 de IMDSv2 |

### 5.2 Trazar un paquete a través de los hooks

Cuando una regla "debería" coincidir y no lo hace, dejá de adivinar y trazá:

```bash
$ sudo nft add table inet trace_debug
$ sudo nft add chain inet trace_debug prerouting \
    '{ type filter hook prerouting priority -350; }'
$ sudo nft add rule inet trace_debug prerouting \
    ip saddr 203.0.113.90 tcp dport 31380 meta nftrace set 1

$ sudo nft monitor trace
trace id 3f2a1b04 inet trace_debug prerouting packet: iif "ens3" ip saddr 203.0.113.90 ip daddr 10.0.0.21 tcp sport 51900 tcp dport 31380 tcp flags == syn
trace id 3f2a1b04 inet trace_debug prerouting rule ip saddr 203.0.113.90 tcp dport 31380 meta nftrace set 1 (verdict continue)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule iifname != "ens3" accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ct state established,related accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ip saddr @cluster_nodes accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ip saddr @admin_cidrs accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule tcp dport 30000-32767 counter packets 13 bytes 780 drop (verdict drop)

$ sudo nft delete table inet trace_debug
```

La traza muestra el paquete muriendo en `prerouting_guard` antes de llegar siquiera a `nat`. Si en cambio lo ves atravesar `nat` y aterrizar en `forward`, tus reglas de `input` nunca estuvieron en el camino — ese es el error de §2.5, probado en vez de asumido.

El equivalente en `iptables` para clústeres que siguen con herramientas legacy:

```bash
$ sudo modprobe nf_log_ipv4
$ sudo sysctl -w net.netfilter.nf_log.2=nf_log_ipv4
net.netfilter.nf_log.2 = nf_log_ipv4
$ sudo iptables -t raw -I PREROUTING 1 -p tcp --dport 31380 -j TRACE
$ sudo journalctl -k -f | grep TRACE
kernel: TRACE: raw:PREROUTING:policy:2 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: nat:PREROUTING:rule:1 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: nat:KUBE-NODEPORTS:rule:1 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: filter:FORWARD:rule:3 IN=ens3 OUT=lxc9f2a SRC=203.0.113.90 DST=10.244.1.17 PROTO=TCP SPT=51900 DPT=8080
$ sudo iptables -t raw -D PREROUTING -p tcp --dport 31380 -j TRACE
```

`filter:FORWARD` en la cuarta línea, con `DST` ya reescrito a la IP del pod — el paquete nunca tocó `INPUT`. Borrá siempre la regla TRACE; es extremadamente ruidosa.

### 5.3 Conntrack rancio: por qué tu nuevo DROP "no tomó efecto"

```bash
$ sudo conntrack -L -d 10.0.0.21 -p tcp --dport 31380 2>/dev/null
tcp 6 86395 ESTABLISHED src=203.0.113.90 dst=10.0.0.21 sport=51882 dport=31380 \
    src=10.244.1.17 dst=203.0.113.90 sport=8080 dport=51882 [ASSURED] mark=0 use=1
conntrack v1.4.7 (conntrack-tools): 1 flow entries have been shown.

$ sudo conntrack -D -d 10.0.0.21 -p tcp --dport 31380
tcp 6 86394 ESTABLISHED src=203.0.113.90 dst=10.0.0.21 sport=51882 dport=31380 ...
conntrack v1.4.7 (conntrack-tools): 1 flow entries have been deleted.
```

Cualquier regla `ct state established,related accept` mantiene vivos indefinidamente los flujos preexistentes — con `tcpEstablishedTimeout: 24h` en la configuración de kube-proxy, la sesión de un atacante sobrevive a tu arreglo por un día. Vaciar conntrack para la tupla afectada es un paso obligatorio de la contención del incidente, no una optimización.

### 5.4 Verificar las restricciones de egreso del host

```bash
# From a pod — must fail after the NetworkPolicy and forward rule:
$ kubectl -n team-a run probe --rm -it --restart=Never --image=nicolaka/netshoot -- \
    curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/meta-data/
000
command terminated with exit code 28
pod "probe" deleted

# From the node — should still work if the kubelet needs IMDS, blocked otherwise:
$ curl -s -m 3 -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
    -X PUT http://169.254.169.254/latest/api/token | head -c 20
AQAEAO1sX3F0aGVyZW...

$ sudo journalctl -k --since '5 min ago' | grep imds-drop
Aug 04 10:22:03 node-1 kernel: nft imds-drop: IN=lxc9f2a OUT=ens3 SRC=10.244.1.17 DST=169.254.169.254 LEN=60 PROTO=TCP SPT=44112 DPT=80 SYN
```

### 5.5 Detección continua de deriva

Un hardening único no vale nada sin un chequeo que falle a los gritos. El chequeo mínimo viable a nivel de nodo, ejecutable desde CI o desde un DaemonSet:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-node-exposure.sh — exits non-zero on drift
set -euo pipefail

ALLOWED='^(22|6443|10250|10256|2379|2380)$'
fail=0

while read -r proto addr; do
    port="${addr##*:}"
    [[ "$addr" =~ ^(127\.|\[::1\]) ]] && continue
    if ! [[ "$port" =~ $ALLOWED ]]; then
        echo "DRIFT: unexpected listener ${proto} ${addr}" >&2
        fail=1
    fi
done < <(ss -Hltn | awk '{print "tcp", $4}')

if ! nft list chain inet k8s_node input >/dev/null 2>&1; then
    echo "DRIFT: nftables table inet k8s_node is missing" >&2
    fail=1
fi

if [[ "$(nft -j list chain inet k8s_node input \
        | jq -r '.nftables[] | select(.chain) | .chain.policy')" != "drop" ]]; then
    echo "DRIFT: input chain policy is not drop" >&2
    fail=1
fi

if grep -qE '^\s*readOnlyPort:\s*(?!0)' /var/lib/kubelet/config.yaml 2>/dev/null; then
    echo "DRIFT: kubelet readOnlyPort is not 0" >&2
    fail=1
fi

exit "$fail"
```

```bash
$ sudo /usr/local/sbin/verify-node-exposure.sh; echo "exit=$?"
exit=0

# After someone re-enables rpcbind:
$ sudo /usr/local/sbin/verify-node-exposure.sh; echo "exit=$?"
DRIFT: unexpected listener tcp 0.0.0.0:111
exit=1
```

---

## 6. Checklist para el día del examen

1. `ss -tulpn` primero — nunca adivines la superficie de escucha.
2. `readOnlyPort: 0`, `anonymous.enabled: false`, `authorization.mode: Webhook` en `/var/lib/kubelet/config.yaml`, después `systemctl restart kubelet`.
3. `--bind-address=127.0.0.1` en controller-manager y scheduler; `--profiling=false` en los tres componentes del control plane.
4. etcd con `--client-cert-auth=true`, `--listen-client-urls` restringido.
5. El filtrado de NodePort va en `prerouting` (prioridad `-150`) o en `forward`, **nunca** en `input`; o definí `nodePortAddresses` en el ConfigMap de kube-proxy.
6. Nunca bloquees `8472/udp`, `4789/udp`, `4240/tcp`, `179/tcp`, `51820/udp` entre IPs de nodos.
7. Enmascará, no solo deshabilites, las unidades de socket innecesarias.
8. Prepará siempre un rollback (`systemd-run --on-active`) antes de aplicar un ruleset default-deny en un nodo remoto, y auditá siempre antes de aplicar una host policy de Cilium/Calico.
9. Después de cualquier regla DROP, vaciá las entradas de conntrack que coincidan.
10. Probalo con `nmap` desde afuera más los contadores de las reglas — una regla no verificada es una hipótesis.

---

## Referencias

**Currículum**
- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Repositorio de currículums de CNCF: https://github.com/cncf/curriculum

**Kubernetes — superficie de red y componentes**
- Ports and Protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Autenticación/autorización del kubelet: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Referencia de la API KubeletConfiguration (v1beta1): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Referencia de la API de configuración de kube-proxy (v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Virtual IPs and Service proxies (incl. modo proxy nftables): https://kubernetes.io/docs/reference/networking/virtual-ips/
- Referencia de línea de comandos de kube-apiserver: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Service (NodePort, LoadBalancer, externalIPs): https://kubernetes.io/docs/concepts/services-networking/service/
- Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Gateway API: https://kubernetes.io/docs/concepts/services-networking/gateway/

**Kubernetes — política y admisión**
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Controladores de admisión (incl. `DenyServiceExternalIPs`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Securing a cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Controlling access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Set up Konnectivity service: https://kubernetes.io/docs/tasks/extend-kubernetes/setup-konnectivity/

**Política a nivel de host del CNI**
- Cilium Host Firewall: https://docs.cilium.io/en/stable/security/host-firewall/
- Referencia de network policy de Cilium: https://docs.cilium.io/en/stable/security/policy/
- Reglas de firewall / puertos requeridos de Cilium: https://docs.cilium.io/en/stable/operations/system_requirements/
- Calico — protect hosts (HostEndpoint): https://docs.tigera.io/calico/latest/network-policy/hosts/protect-hosts
- Calico — configuración de Felix (puertos failsafe): https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- Calico — GlobalNetworkPolicy (`preDNAT`, `applyOnForward`): https://docs.tigera.io/calico/latest/reference/resources/globalnetworkpolicy

**Firewalling del host Linux**
- Wiki de nftables: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- Hooks y prioridades de Netfilter: https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks
- Manual de `nft(8)`: https://www.netfilter.org/projects/nftables/manpage.html
- conntrack-tools: https://conntrack-tools.netfilter.org/
- Documentación de firewalld: https://firewalld.org/documentation/
- `sshd_config(5)`: https://man.openbsd.org/sshd_config

**Benchmarks y metadata de nube**
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench: https://github.com/aquasecurity/kube-bench
- AWS EC2 Instance Metadata Service (IMDSv2, hop limit): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- GKE Workload Identity (metadata concealment): https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Azure IMDS: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service