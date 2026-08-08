# CNCF KCSA Study Guide: Topic 2.9 – Container Networking

## 1. Problema Arquitectónico de Producción y Motivación

### El Modelo de Red Plana por Defecto de Kubernetes
Kubernetes exige una arquitectura de red plana y no segmentada: cada Pod debe ser capaz de comunicarse con cualquier otro Pod a través de todos los namespaces sin traducción de direcciones de red (NAT). Aunque este modelo simplifica el descubrimiento de servicios y el despliegue de aplicaciones, introduce una grave vulnerabilidad de seguridad en entornos de producción multitenant o empresariales: **cero aplicación inherente de límites Este-Oeste**.

Por defecto, un atacante que comprometa una aplicación de bajos privilegios (ej. un servicio web público vulnerable) hereda inmediatamente un alcance de red sin restricciones hacia:
* Microservicios internos de alto valor (ej. pasarelas de pago, servicios de autenticación).
* La infraestructura del control plane del cluster (`kube-apiserver` ejecutándose en el puerto 6443).
* Clusters de bases de datos sin autenticación, cachés de Redis y endpoints internos de ETCD.
* Endpoints de metadatos link-local del proveedor de nube (`169.254.169.254`), que exponen credenciales de instancias IAM.

```
+-----------------------------------------------------------------------------------+
|                            DEFAULT FLAT NETWORK MODEL                             |
|                                                                                   |
|  [ Compromised Pod ]  ======( Unrestricted Lateral Access )======> [ Payment DB ]  |
|   (Namespace: public)                                             (Namespace: db) |
|            ||                                                            ^        |
|            ||=======( SSRF Attack )=======> [ 169.254.169.254 ] ---------+        |
|                                             (Cloud Metadata)                      |
+-----------------------------------------------------------------------------------+
```

### Arquitectura y Mecánica de Bajo Nivel de Container Network Interface (CNI)
La Container Network Interface (CNI) estandariza cómo se configuran las interfaces de red para los contenedores Linux. Cuando el Kubelet instruye al container runtime (ej. `containerd`) para crear un sandbox de Pod, el runtime delega el aprovisionamiento de red al plugin de CNI configurado mediante payloads JSON en stdio.

#### El Ciclo de Vida de CNI:
1. **Creación del Network Namespace**: El runtime inicializa un network namespace (`netns`) aislado para el sandbox del Pod.
2. **Invocación de CNI (`ADD`)**: El runtime ejecuta el binario de CNI con variables de entorno (`CNI_COMMAND=ADD`, `CNI_CONTAINERID=...`, `CNI_NETNS=/proc/<pid>/ns/net`) y pasa la configuración JSON a través de `stdin`.
3. **Creación del Par Virtual Ethernet (`veth`)**:
   * El plugin de CNI crea un par `veth` (`vethX` en el `netns` root y `eth0` dentro del `netns` del contenedor).
   * Asigna una dirección IP desde la subred Pod CIDR asignada al Nodo (gestionada por Host-Local IPAM o plugins de CNI IPAM como Calico/Cilium IPAM).
   * Configura las rutas por defecto dentro del `netns` del contenedor apuntando al bridge del nodo (`cbr0`), interfaz gateway, o hook de tail-call de eBPF.
4. **Adición del Motor de Network Policy**: El agente de network policy del CNI (ej. `calico-node`, `cilium-agent`) detecta el evento del nuevo Pod a través del API server de Kubernetes e inyecta dinámicamente reglas de filtrado en el datapath del host (mapas de `iptables`, `IPVS`, o `eBPF`).

```
+-----------------------------------------------------------------------------------+
|                            POD & HOST NETNS CONNECTIONS                           |
|                                                                                   |
|   [ Pod Network Namespace ]                       [ Host Network Namespace ]      |
|  +-------------------------+                     +---------------------------+    |
|  | Interface: eth0         |                     | Interface: veth4a21b3     |    |
|  | IP: 10.244.1.15/24      | <=== veth pair ===>| IP: unassigned (Promisc)  |    |
|  | Route: default via gw   |                     | Connected to Bridge/eBPF  |    |
|  +-------------------------+                     +---------------------------+    |
+-----------------------------------------------------------------------------------+
```

---

## 2. Tablas de Comparación Técnica y Trade-offs

### Comparación Arquitectónica de Datapath: iptables vs. IPVS vs. eBPF

| Dimensión de Característica | Datapath `iptables` | Datapath `IPVS` | Datapath `eBPF` (Cilium / Calico eBPF) |
| :--- | :--- | :--- | :--- |
| **Complejidad Algorítmica** | Evaluación secuencial de reglas $O(N)$ por paquete. | Búsquedas en tabla hash $O(1)$ para balanceo de carga de Services. | Búsquedas en mapas BPF $O(1)$ para enrutamiento, balanceo de carga y políticas. |
| **Límite de Escalabilidad** | Se degrada significativamente pasados los ~5.000 Services (~20.000 reglas). Alto uso de CPU durante las actualizaciones. | Maneja 50.000+ Services de forma limpia. Utiliza `iptables` para NetworkPolicy. | Escala a 100.000+ Services y Pods con un overhead de latencia despreciable. |
| **Mecánica de Network Policy** | Inyecta llamadas a cadenas en la tabla `filter` (`FORWARD`, `INPUT`, `OUTPUT`). | Inyecta reglas en cadenas de `iptables`; IPVS solo maneja el modo IP-VS. | Adjunta programas BPF a `tc` (Traffic Control) ingress/egress y `XDP`. |
| **Bypass de Contexto de Kernel** | No. Procesamiento completo del stack de red de Linux por paquete. | No. Procesamiento completo del stack de red de Linux por paquete. | Sí. Omite el recorrido de `veth` mediante el cumplimiento a nivel de capa de sockets (`sockmap`). |
| **Impacto en Observabilidad** | Bajo. Requiere logs de trazado de `iptables` (targets `NFLOG` / `LOG`). | Bajo. Requiere `ipvsadm` e inspección del estado de seguimiento de conexiones (conntrack). | Alto. Trazado de eventos de paquetes en tiempo real a través del buffer `perf_event` y Cilium Hubble. |
| **Aplicación de Políticas L7** | Imposible de forma nativa. Requiere un proxy sidecar (Envoy/Istio). | Imposible de forma nativa. Requiere proxy sidecar. | Parseo nativo L7 de HTTP/gRPC/DNS mediante Envoy embebido / hooks de BPF. |

---

### Matriz de Capacidades de Seguridad de CNI Empresariales

| Capacidad de Seguridad | Flannel | Calico (Standard) | Cilium | Antrea |
| :--- | :--- | :--- | :--- | :--- |
| **Soporte de NetworkPolicy Estándar** | Ninguno (Requiere motor externo) | Completo (`networking.k8s.io/v1`) | Completo (`networking.k8s.io/v1`) | Completo (`networking.k8s.io/v1`) |
| **CRDs de Seguridad Personalizadas** | Ninguna | `GlobalNetworkPolicy` | `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy` | `ClusterNetworkPolicy` |
| **Aplicación de Políticas de Capa 7** | No | No (Requiere integración con Service Mesh) | Sí (HTTP nativo, FQDN de DNS, gRPC, Kafka) | Limitado (HTTP mediante integración con Envoy) |
| **Cifrado Nodo a Nodo en Tránsito**| Ninguno | IPsec / WireGuard | WireGuard / IPsec | IPsec / WireGuard |
| **Protección de Endpoints del Host** | No | Sí (`HostEndpoint`) | Sí (`CiliumNodeConfig` / Host Firewall) | Sí |
| **Aceleración Nativa eBPF** | No | Sí (modo eBPF opcional) | Sí (Arquitectura primaria) | Sí (a través de Open vSwitch eBPF) |

---

### Protocolos de Cifrado de Tráfico de Pods Nodo a Nodo

| Parámetro | WireGuard | IPsec (ESP) | mTLS (Sidecar / Ambient Service Mesh) |
| :--- | :--- | :--- | :--- |
| **Capa OSI** | Capa 3 (Capa de Red) | Capa 3 (Capa de Red) | Capa 7 (Capa de Aplicación) |
| **Primitivas Criptográficas** | ChaCha20-Poly1305, Curve25519, BLAKE2s | AES-GCM-256, SHA-2, IKEv2 | RSA 2048/4048, ECDSA P-256, TLS 1.3 |
| **Overhead de Rendimiento** | Muy Bajo (~1-3% de penalización de CPU, alto rendimiento) | Bajo a Medio (Soporta descarga por hardware AES-NI) | Alto (Cambios de contexto entre el proxy en espacio de usuario y el socket) |
| **Mecanismo de Identidad** | Claves Públicas Estáticas/Rotadas mapeadas a IPs de Nodos | Security Associations (SA) / Security Policies (SPD) | Certificados X.509 SVID emitidos por SPIRE/Istio CA |
| **Inspección de Identidad L7** | No (Cifra paquetes IP crudos de forma transparente) | No (Cifra paquetes IP crudos de forma transparente) | Sí (Valida SAN, SPIFFE ID, cabeceras HTTP) |

---

## 3. Manifiestos Completos de Nivel de Producción

### 3.1 `NetworkPolicy` de Producción Strict Zero-Trust (API Estándar de Kubernetes)

Esta política asegura un microservicio (`app: payment-api`) en el namespace `production`. Restringe el ingress estrictamente a pods frontend aprobados ejecutándose en `production`, limita el egress exclusivamente a la base de datos PostgreSQL interna en el namespace `database` en el puerto `5432`, permite la resolución DNS hacia `kube-dns`, y bloquea explícitamente el acceso a los servicios de metadatos de la nube (`169.254.169.254`).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-api-zero-trust-policy
  namespace: production
  labels:
    tier: payment
    security.aspect: network-segmentation
spec:
  podSelector:
    matchLabels:
      app: payment-api
  policyTypes:
  - Ingress
  - Egress

  # ---------------------------------------------------------------------------
  # INGRESS RULES: Default Deny active. Allow only explicit sources.
  # ---------------------------------------------------------------------------
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: production
      podSelector:
        matchLabels:
          app: payment-frontend
    ports:
    - protocol: TCP
      port: 8443

  # ---------------------------------------------------------------------------
  # EGRESS RULES: Restrict outbound destinations and block metadata services.
  # ---------------------------------------------------------------------------
  egress:
  # Rule 1: Allow DNS resolution to CoreDNS in kube-system
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

  # Rule 2: Allow access to PostgreSQL DB in 'database' namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: database
      podSelector:
        matchLabels:
          role: postgres-primary
    ports:
    - protocol: TCP
      port: 5432

  # Rule 3: Allow external HTTPS outbound EXCEPT Cloud Metadata (169.254.169.254/32)
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 443
```

---

### 3.2 Política Avanzada de Inspección FQDN y DNS de Capa 7 (`CiliumNetworkPolicy`)

Esta política aprovecha las capacidades de capa 7 de eBPF para restringir el tráfico de egress a nombres de dominio explícitos (`api.stripe.com` y `*.vault.internal`) resueltos dinámicamente mediante respuestas DNS interceptadas.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-api-l7-fqdn-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: payment-api

  egress:
  # Step 1: Intercept DNS queries to discover dynamic IPs for FQDNs
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"

  # Step 2: Restrict L7 Egress to designated third-party APIs and internal Vault
  - toFQDNs:
    - matchName: "api.stripe.com"
    - matchPattern: "*.vault.service.consul"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charges"
        - method: "GET"
          path: "/v1/vault/v1/secret/.*"
```

---

### 3.3 Default Deny Global a Nivel de Cluster (`Calico GlobalNetworkPolicy`)

Esta política a nivel de cluster activa una postura de zero-trust en todos los namespaces que no sean de sistema, garantizando que los namespaces recién creados denieguen por defecto todo el tráfico entrante y saliente hasta que una `NetworkPolicy` localizada lo permita explícitamente.

```yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: global-default-deny-all
spec:
  selector: >-
    kubernetes.io/metadata.name != 'kube-system' &&
    kubernetes.io/metadata.name != 'calico-system' &&
    kubernetes.io/metadata.name != 'kube-node-lease'
  types:
  - Ingress
  - Egress
  # Ingress and Egress list left empty: Implicitly drops all non-system traffic
```

---

## 4. Comandos CLI Reales y Salidas Exactas de Terminal

### 4.1 Inspeccionando Network Namespaces e Interfaces Virtuales de Pods en un Nodo

Localice el PID de un contenedor, ingrese a su network namespace e identifique su interfaz `veth` correspondiente del lado del host usando `ethtool`.

```bash
$ crictl ps --name payment-api-7b89569b9b-x9z4l
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS            CONTAINER ID
d4f1e8a9c12b3       c8f2b1a3d9e01       10 minutes ago      Running             payment-api         0                   d4f1e8a9c12b3

$ crictl inspect --output json d4f1e8a9c12b3 | jq '.info.pid'
142859

$ sudo nsenter -t 142859 -n ip addr show eth0
3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 8a:3f:9d:11:02:b4 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.1.15/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever

$ sudo nsenter -t 142859 -n ethtool -S eth0 | grep peer_ifindex
     peer_ifindex: 42

$ ip link show dev | grep '^42:'
42: veth4a21b3@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master cbr0 state UP group default
```

---

### 4.2 Verificando Network Policies Aplicadas con `kubectl`

Consulte las network policies aplicadas dentro de un namespace y describa las reglas de aplicación de políticas.

```bash
$ kubectl get networkpolicy -n production -o wide
NAME                            POD-SELECTOR      AGE   POLICY-TYPES   GEN
payment-api-zero-trust-policy   app=payment-api   4h    Ingress,Egress 1

$ kubectl describe networkpolicy payment-api-zero-trust-policy -n production
Name:         payment-api-zero-trust-policy
Namespace:    production
Created on:   2026-08-07 15:30:12 -0400 EDT
Labels:       security.aspect=network-segmentation
              tier=payment
Annotations:  <none>
Spec:
  PodSelector:     app=payment-api
  Allowing ingress traffic:
    To Port: 8443/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=production
      PodSelector: app=payment-frontend
  Allowing egress traffic:
    To Port: 53/UDP, 53/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=kube-system
      PodSelector: k8s-app=kube-dns
    --------------
    To Port: 5432/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=database
      PodSelector: role=postgres-primary
    --------------
    To Port: 443/TCP
    To IPBlock:
      CIDR: 0.0.0.0/0
      Except: 169.254.169.254/32, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
Policy Types: Ingress, Egress
```

---

### 4.3 Inspección de Bajo Nivel de eBPF y Caída de Paquetes (Packet Drop) a través de Cilium CLI y `bpftool`

Monitoree eventos de caída de paquetes (packet drop) de eBPF en tiempo real generados por violaciones de políticas usando `cilium monitor`.

```bash
$ kubectl exec -n kube-system cilium-5z8kl -- cilium monitor --type drop
Listening for events on 2 LBDs, 4 CPUS...
Press Ctrl-C to quit
xx drop 65535 at status egress policy dropped: (cilium-agent) egress 10.244.1.15:43982 -> 169.254.169.254:80 tcp SYN identity 49102->2 (reserved:host)
xx drop 65535 at status ingress policy dropped: (cilium-agent) ingress 10.244.2.88:51204 -> 10.244.1.15:8443 tcp SYN identity 10443->49102 (app=payment-api)

$ kubectl exec -n kube-system cilium-5z8kl -- bpftool map dump name cilium_policy_v2
key: 00 00 00 00 00 00 00 00  value: 01 00 00 00 00 00 00 00
key: 00 00 00 00 00 00 bf f6  value: 00 00 00 00 00 00 00 00
Found 2 elements
```

---

### 4.4 Depurando Reglas Legadas de Network Policy en `iptables`

Inspeccione las reglas de `iptables` del sistema generadas por plugins como Calico o kube-router en el network namespace del host.

```bash
$ sudo iptables-save -t filter | grep -E "cali-pi-|cali-po-|FORWARD"
:FORWARD DROP [0:0]
-A FORWARD -m comment --comment "cali:w36w8W8a9v4pG" -j cali-FORWARD
-A cali-FORWARD -m comment --comment "cali:H3aD92fK1l" -m physdev --physdev-is-bridged -j ACCEPT
-A cali-FORWARD -m comment --comment "cali:v8S1s4v7X1" -j cali-from-hep-forward
-A cali-pi-_Z9a8f7e6d5 -m comment --comment "cali:Rule:Match" -m set --match-set cali40-production-frontend src -p tcp -m tcp --dport 8443 -j ACCEPT
-A cali-pi-_Z9a8f7e6d5 -m comment --comment "cali:Implicit Drop" -j DROP
```

---

## 5. Guía de Diagnóstico y Resolución de Problemas (Troubleshooting)

```
+-----------------------------------------------------------------------------------+
|                        NETWORK TROUBLESHOOTING FLOWCHART                          |
|                                                                                   |
|                   [ Pod Traffic Dropped / Interrupted ]                           |
|                                     |                                             |
|                                     v                                             |
|                  /-------------------------------------\                          |
|                 / Is CNI Pod running on target node?    \                         |
|                 \  (e.g., cilium-agent, calico-node)    /                         |
|                  \-------------------------------------/                          |
|                               /             \                                     |
|                              /               \                                    |
|                            NO                 YES                                 |
|                            /                   \                                  |
|                           v                     v                                 |
|            [ Restart CNI DaemonSet ]    /-------------------------\               |
|            [ Check CNI Agent Logs  ]   / Is MTU matched across    \               |
|                                        \ CNI overlay and phys dev?/               |
|                                         \-------------------------/               |
|                                                     /         \                   |
|                                                    /           \                  |
|                                                  NO             YES               |
|                                                  /               \                |
|                                                 v                 v               |
|                                        [ Fix MTU Mismatch ]  /----------------\   |
|                                                              / Check NetPol   \   |
|                                                              \ Ingress/Egress /   |
|                                                               \---------------/   |
+-----------------------------------------------------------------------------------+
```

### Escenario 1: Resets de Conexión Intermitentes y Pérdida de Paquetes (Desajuste de MTU / MTU Mismatch)

#### Causa Raíz:
La encapsulación de la red overlay (ej. VXLAN agregando 50 bytes de overhead, Geneve agregando 50 bytes, o IPsec agregando hasta 73 bytes) provoca que la MTU efectiva de la interfaz virtual del contenedor (`eth0`) supere la MTU de la interfaz de red física subyacente (`eth0` en el nodo). Los paquetes más grandes que el MTU de la ruta (Path MTU) con el flag `DF` (Don't Fragment) activado son descartados silenciosamente.

#### Flujo de Trabajo de Diagnóstico:
1. Verifique la MTU de la interfaz física en el host:
   ```bash
   $ ip link show eth0 | grep mtu
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
   ```
2. Verifique la MTU de la interfaz CNI dentro del pod:
   ```bash
   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ip link show eth0
   3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
   ```
   *Análisis*: La MTU física es 1500, pero la MTU del contenedor también está configurada en 1500. Con la encapsulación VXLAN (50 bytes), la MTU del contenedor debe ser $\le 1450$.

3. Realice un ping con el flag DF activado para determinar con precisión el tamaño límite del payload:
   ```bash
   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ping -M do -s 1422 10.244.2.88
   PING 10.244.2.88 (10.244.2.88) 1422(1450) bytes of data.
   1430 bytes from 10.244.2.88: icmp_seq=1 ttl=63 time=0.412 ms

   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ping -M do -s 1423 10.244.2.88
   PING 10.244.2.88 (10.244.2.88) 1423(1451) bytes of data.
   ping: local error: Message too long, mtu=1450
   ```

#### Resolución:
Actualice el ConfigMap del CNI (ej. `cilium-config` o `calico-config`) para establecer `veth-mtu: "1450"` (o `mtu: 1450`), luego ejecute un rolling restart del DaemonSet del CNI.

---

### Escenario 2: Tráfico Bloqueado debido a una Mala Comprensión del Orden de Evaluación de NetworkPolicy

#### Causa Raíz:
Los ingenieros asumen que las NetworkPolicies actúan como firewalls secuenciales con un ordenamiento explícito de `ALLOW` / `DENY`. En Kubernetes:
* Si **ninguna** `NetworkPolicy` selecciona a un Pod, este se encuentra en **Modo No Aislado (Non-Isolated Mode)** (todo el ingress y egress está permitido).
* Tan pronto como **una sola** `NetworkPolicy` selecciona a un Pod, el Pod entra en **Modo Aislado (Isolated Mode)** para los `policyTypes` especificados (`Ingress`, `Egress`, o ambos).
* Las NetworkPolicies son **aditivas (lógica OR)**. No existe el concepto de una regla de `DENY` explícita en la API estándar `networking.k8s.io/v1` de Kubernetes.

#### Ejecución Paso a Paso del Diagnóstico:
1. Verifique si el Pod objetivo está aislado por alguna política existente:
   ```bash
   $ kubectl get netpol -n production -o json | jq '.items[] | select(.spec.podSelector.matchLabels.app=="payment-api") | .metadata.name'
   "payment-api-zero-trust-policy"
   ```

2. Verifique si los selectores de namespace carecen de la etiqueta de metadatos requerida creada automáticamente:
   ```bash
   # INCORRECT: Expecting 'name: production' when label is not set on namespace
   $ kubectl get ns production --show-labels
   NAME         STATUS   AGE   LABELS
   production   Active   10d   environment=prod

   # CORRECT: Match standard immutable metadata label
   # kubernetes.io/metadata.name: production
   ```

3. Rastreé caídas activas (drops) usando `tcpdump` en la interfaz `veth` del Pod objetivo en el nodo host:
   ```bash
   $ sudo tcpdump -nn -i veth4a21b3 tcp port 8443
   19:42:10.104921 IP 10.244.2.88.51204 > 10.244.1.15.8443: Flags [S], seq 382910482, win 64240, length 0
   19:42:11.108210 IP 10.244.2.88.51204 > 10.244.1.15.8443: Flags [S], seq 382910482, win 64240, length 0
   # Result: SYN packets arrive at veth interface but no SYN-ACK is returned (silent drop by host datapath filter)
   ```

---

### Escenario 3: Fuga de IPs de Pods en CNI y Handles Obsoletos de Network Namespace

#### Causa Raíz:
La alta rotación (churn) de Pods (ej. CronJobs de alta frecuencia o eventos de autoscaling) puede causar network namespaces no limpiados en `/var/run/netns/` o interfaces `veth` huérfanas, agotando el pool de CNI IPAM o la capacidad de la tabla ARP del host (`net.ipv4.neigh.default.gc_thresh3`).

#### Comandos de Diagnóstico y Remediación:
1. Verifique la existencia de network namespaces huérfanos:
   ```bash
   $ sudo ip netns list-id
   nsid 0 (ipns-d4f1e8a9c12b)
   nsid 1 (ipns-9a8b7c6d5e4f)

   $ ls -l /var/run/netns/
   total 0
   -r--r--r-- 1 root root 0 Aug  7 14:00 cni-8d9e0f1a-2b3c-4d5e-6f7a-8b9c0d1e2f3a
   -r--r--r-- 1 root root 0 Aug  7 14:05 cni-1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
   ```

2. Verifique el uso de la tabla ARP/Neighbor del kernel:
   ```bash
   $ sysctl net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3
   net.ipv4.neigh.default.gc_thresh1 = 128
   net.ipv4.neigh.default.gc_thresh2 = 512
   net.ipv4.neigh.default.gc_thresh3 = 1024

   $ ip neigh show | wc -l
   1021
   ```
   *Análisis*: La tabla ARP se está aproximando a `gc_thresh3` (1024 entradas), lo que causa caídas de paquetes en el kernel (`neighbor table overflow`).

3. Resuelva permanentemente ajustando `/etc/sysctl.d/99-k8s-cni.conf`:
   ```sysctl
   net.ipv4.neigh.default.gc_thresh1 = 1024
   net.ipv4.neigh.default.gc_thresh2 = 4096
   net.ipv4.neigh.default.gc_thresh3 = 8192
   ```
   Aplique inmediatamente sin reiniciar:
   ```bash
   $ sudo sysctl --system
   ```

---

## 6. Referencias

* **Repositorio del Curriculum de CNCF**: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Documentación Oficial de Kubernetes – Network Policies**: https://kubernetes.io/docs/concepts/services-networking/network-policies/
* **Documentación Oficial de Kubernetes – Cluster Networking**: https://kubernetes.io/docs/concepts/cluster-administration/networking/
* **Especificación CNI (Containernetworking)**: https://github.com/containernetworking/cni/blob/main/SPEC.md
* **Documentación de Cilium Security Policy**: https://docs.cilium.io/en/stable/security/policy/
* **Referencia de Network Policy de Project Calico**: https://docs.tigera.io/calico/latest/reference/resources/networkpolicy