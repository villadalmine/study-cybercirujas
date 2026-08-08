# Guía de Estudio KCSA: Dominio 4.5 – Atacante en la Red

**Exam Domain:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain Topic:** 4.5 Attacker on the Network  
**Domain Weight:** 2.29%  
**Target Audience:** Arquitectos Principales de Plataforma e Ingenieros SRE Senior  

---

## 1. Motivación y Problema Arquitectónico en Producción

### 1.1 Modelo de Amenazas en Redes Planas de Contenedores
El principio de diseño por defecto de las redes de Kubernetes (según lo especificado por la especificación de Interfaz de Red de Contenedores / CNI) requiere que cualquier Pod pueda comunicarse con cualquier otro Pod a través de todos los nodos sin Traducción de Direcciones de Red (NAT), a menos que esté explícitamente restringido. En un cluster no endurecido (unhardened), la red opera como una red IP plana y no segmentada de Capa 3/Capa 4.

```
       +-----------------------------------------------------------------------------------+
       |                               KUBERNETES CLUSTER                                  |
       |                                                                                   |
       |  [ Compromised Pod ]                                  [ Sensitive Pod ]           |
       |  (Attacker Footprint)                                 (Database / Payment Gateway)|
       |         |                                                       ^                 |
       |         | 1. Internal Reconnaissance (Nmap / DNS Enum)          |                 |
       |         +-------------------------------------------------------+                 |
       |         | 2. Plaintext Packet Sniffing (veth / VXLAN / Geneve)   |                 |
       |         | 3. East-West Lateral Movement                         |                 |
       |         v                                                       |                 |
       |  [ CoreDNS Pod ]                                                |                 |
       |         | 4. DNS Cache Poisoning / Spoofing                     |                 |
       |         v                                                       |                 |
       |  [ Cloud IMDS Endpoint ] (169.254.169.254)                       |                 |
       |         | 5. IAM Credential Exfiltration                        |                 |
       |         +-------------------------------------------------------+                 |
       +-----------------------------------------------------------------------------------+
```

Cuando un atacante obtiene la ejecución de código arbitrario dentro de un solo contenedor (por ejemplo, a través de una vulnerabilidad de ejecución remota de código, una dependencia comprometida o un ataque a la cadena de suministro), la topología de red plana presenta múltiples vectores de ataque:

1. **Reconocimiento Interno y Descubrimiento de Servicios:**
   - **Enumeración de DNS:** Al consultar CoreDNS (`/etc/resolv.conf`), un atacante puede realizar fuerza bruta o enumerar nombres de servicio (`*.namespace.svc.cluster.local`) para mapear arquitecturas internas sensibles.
   - **Escaneo de Puertos en Subredes:** Un atacante puede ejecutar escaneos sintéticos TCP/UDP SYN a través del rango de CIDR de Pods (por ejemplo, `10.244.0.0/16`) para localizar puertos internos no autenticados (por ejemplo, Redis en 6379, Memcached en 11211, endpoints no autenticados de JMX/métricas).

2. **Intercepción de Tráfico Este-Oeste No Cifrado:**
   - El tráfico entre Pods que se ejecutan en diferentes nodos generalmente se encapsula en protocolos overlay (VXLAN UDP 4789, Geneve UDP 6081) o se enruta de forma nativa sin cifrado.
   - Si un atacante obtiene acceso a nivel de host a un nodo o ejecuta una captura de paquetes dentro de un namespace de red compartido, puede capturar payloads sensibles (JWTs, encabezados de basic auth, API keys, consultas de base de datos) enviados sobre HTTP, gRPC o protocolos wire de base de datos no cifrados.

3. **Exfiltración del Servicio de Metadatos de Instancias Cloud (IMDS):**
   - Los Pods heredan el acceso a la red de las interfaces IP virtuales del host subyacente, incluida la IP link-local de Cloud Metadata (`169.254.169.254`).
   - Un atacante que alcance `http://169.254.169.254/latest/meta-data/iam/security-credentials/` en AWS (o endpoints equivalentes en GCP/Azure) puede extraer las credenciales del rol IAM del nodo worker, lo que conduce a una escalada de privilegios completa en la cuenta cloud.

4. **Spoofing de DNS y Redirección de Tráfico:**
   - En dominios de red L2 compartidos o no segmentados (o mediante la manipulación del puerto UDP 53), los atacantes pueden realizar DNS spoofing o envenenamiento de caché ARP para interceptar el tráfico destinado a servicios legítimos del cluster y redirigirlo a un pod malicioso bajo su control.

5. **Egress No Restringido y Comando y Control (C2):**
   - Las conexiones salientes desde los Pods hacia el internet público están permitidas por defecto. Los atacantes aprovechan esto para establecer reverse shells, exfiltrar datos robados sobre HTTPS/DNS tunneling o descargar payloads de ataque secundarios.

---

## 2. Comparaciones Técnicas y Análisis de Compromisos (Trade-Offs)

### Tabla 2.1: Arquitecturas de Aislamiento de Red (NetworkPolicies L3/L4 vs. Políticas L7 vs. CNI eBPF)

| Característica / Métrica | NetworkPolicy Nativa de Kubernetes (L3/L4) | Network Policies Basadas en eBPF (Cilium/Calico eBPF) | Seguridad de Service Mesh (Istio/Linkerd) |
| :--- | :--- | :--- | :--- |
| **Capa de Ejecución** | Capa 3 del modelo OSI (IP) y Capa 4 (puertos TCP/UDP) | Capa 3, Capa 4 y Capa 7 selectiva del modelo OSI | Capa 7 del modelo OSI (HTTP, gRPC, TLS SNI, Method, Path) |
| **Mecanismo de Ruta de Datos** | Reglas de `iptables` / IPVS de Linux agregadas por cadena | Programas de bytecode eBPF del Kernel adjuntos a `tc` (Traffic Control) y socket hooks | Proxies sidecar en espacio de usuario (Envoy) o proxies de nodo ambient |
| **Sobrecarga de Rendimiento** | Alta latencia escalada a $O(N)$ con grandes conjuntos de reglas debido a la evaluación secuencial de `iptables` | Extremadamente baja; búsquedas en tablas hash de $O(1)$ directamente en la memoria del kernel | Consumo de CPU/memoria de moderado a alto; introduce latencia sub-milisegundo por salto |
| **Mecanismo de Identidad** | Etiquetas Selectoras de Namespace y Pod (`k8s:app=frontend`) | Identidad Criptográfica (Identidades de Seguridad mapeadas a mapas eBPF) | Identidad criptográfica a través de certificados SPIFFE/SPIRE X.509 SVID |
| **Filtrado Orientado a DNS** | No (requiere bloques CIDR explícitos) | Sí (aplica egress por FQDN exacto / patrones regex) | Sí (mediante ServiceEntry y Egress Gateways) |
| **Seguridad Criptográfica** | Ninguna (el tráfico permanece en texto plano en la red) | Admite IPsec/WireGuard transparente de Nodo a Nodo / Pod a Pod | Aplica TLS Mutuo (mTLS) con validación de identidad y rotación automática de certificados |

### Tabla 2.2: Cifrado de Tráfico Intra-Cluster (WireGuard vs. IPsec vs. Service Mesh mTLS)

| Propiedad | WireGuard Transparente de CNI | IPsec Transparente de CNI | mTLS de Service Mesh (SPIFFE/SPIRE) |
| :--- | :--- | :--- | :--- |
| **Alcance del Cifrado** | Payloads de red de Nodo a Nodo y de Pod a Pod | Paquetes de Nodo a Nodo y de Pod a Pod (encapsulamiento ESP) | Flujo de payload de Aplicación a Aplicación (TLS 1.3) |
| **Kernel vs. Espacio de Usuario** | Módulo del Kernel de Linux (`wireguard.ko`) | Framework XFRM del Kernel de Linux y subsistema `crypto` | Procesamiento mediante proxy sidecar Envoy en espacio de usuario |
| **Intercambio y Gestión de Claves**| Claves públicas estáticas intercambiadas automáticamente a través del control plane del CNI | Daemon IKEv2 (StrongSwan/Charon) o programación manual de claves XFRM | SVIDs X.509 dinámicos de corta duración emitidos por una CA interna |
| **Rendimiento / Latencia** | Casi a velocidad de línea; aceleración por hardware de ChaCha20-Poly1305 | Alta sobrecarga de CPU a menos que esté activa la descarga por hardware AES-NI | Cambios de contexto adicionales en espacio de usuario; mayor consumo de memoria |
| **Compatibilidad con Inspección L7** | Cifra paquetes L3 de forma transparente; compatible con eBPF L7 | Cifra paquetes L3 de forma transparente | Enrutamiento nativo L7, políticas de autorización y rastreo distribuido |

---

## 3. Manifiestos de Infraestructura y YAML de Grado de Producción

### 3.1 Línea Base de Aislamiento de Red Zero-Trust Estricta
Este manifiesto implementa una estrategia completa de denegación por defecto (default-deny) tanto para Ingress como para Egress a través de un namespace, seguida de una política explícita que permite a los Pods comunicarse **únicamente** con CoreDNS en el puerto 53 (UDP/TCP).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production-workloads
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-coredns-egress
  namespace: production-workloads
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
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
```

### 3.2 Control Avanzado de Egress L7 y FQDN con CiliumNetworkPolicy
Esta política aplica reglas estrictas de egress en la Capa 7:
1. Bloquea todo acceso a la IP de Cloud Metadata de AWS (`169.254.169.254/32`).
2. Restringe el egress a endpoints de pago externos mediante coincidencias exactas de FQDN (`api.stripe.com`) sobre HTTPS (puerto 443).
3. Aplica la restricción de métodos HTTP L7 en las comunicaciones internas de microservicios.

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: secure-payment-service-policy
  namespace: production-workloads
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: payment-service
  ingress:
  - fromEndpoints:
    - matchLabels:
        app.kubernetes.io/name: checkout-frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charge"
  egress:
  # Explicitly deny Cloud Metadata Endpoint (IMDSv1/v2)
  - toCIDRSet:
    - cidr: "169.254.169.254/32"
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http: {}
    # Cilium treats unlisted egress as implicitly denied when egress rules exist
  # FQDN Based Egress Allowlist for External APIs
  - toFQDNs:
    - matchName: "api.stripe.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
  # Allow internal CoreDNS resolution required for FQDN resolution
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*"
```

### 3.3 Valores de Helm para Cifrado WireGuard Transparente Pod-a-Pod en Cilium
Desplegar Cilium con cifrado transparente nativo cifra todo el tráfico Este-Oeste dentro del kernel a través de WireGuard sin requerir modificaciones en las aplicaciones ni proxies sidecar.

```yaml
# cilium-helm-values.yaml
cilium:
  routingMode: "native"
  ipv4NativeRoutingCIDR: "10.244.0.0/16"
  autoDirectNodeRoutes: true
  
  # Enable eBPF Host Routing to bypass iptables overhead
  bpf:
    masquerade: true
    preallocateMaps: true
    
  # Cryptographic Encryption Configuration
  encryption:
    enabled: true
    type: wireguard
    wireguard:
      persistentKeepalive: 0
      userspaceFallback: false
    # Encrypt traffic between nodes as well as between pods
    nodeToNode: true

  # Enable L7 policy enforcement engine
  l7Proxy: true
```

### 3.4 TLS Mutuo (mTLS) de Istio y Política de Autorización L7 Estricta
Esta configuración deshabilita por completo la comunicación HTTP no cifrada dentro del namespace y aplica identidades SPIFFE verificadas criptográficamente.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: production-workloads
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: database-access-control
  namespace: production-workloads
spec:
  selector:
    matchLabels:
      app: postgresql-primary
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/production-workloads/sa/payment-service-sa"]
    to:
    - operation:
        ports: ["5432"]
        methods: ["TCP"]
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

### 4.1 Simulando el Reconocimiento de Red de un Atacante
Un atacante intenta enumerar servicios, capturar tráfico y alcanzar el servicio de metadatos de AWS desde el interior de un Pod comprometido.

```bash
$ kubectl exec -it compromised-pod-6d87487-x9z21 -n production-workloads -- sh

# 1. Attempting to reach Cloud Metadata Service (IMDSv1)
$ curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/
curl: (28) Connection timed out after 2001 milliseconds

# 2. Executing internal network scan on neighbor pods in the same CIDR block
$ nmap -p 80,443,5432,6379 10.244.1.0/24 -n --open
Starting Nmap 7.93 ( https://nmap.org ) at 2026-08-07 20:15 UTC
Nmap scan report for 10.244.1.15
Host is up (0.00045s latency).
PORT     STATE SERVICE
5432/tcp OPEN  postgresql
Nmap done: 256 IP addresses (12 hosts up) scanned in 2.14 seconds

# 3. Attempting to sniff wire traffic using raw socket capabilities
$ tcpdump -i eth0 -n -c 5
tcpdump: eth0: You don't have permission to capture on that device
(socket: Operation not permitted)
```

### 4.2 Verificando Caídas (Drops) Activas de NetworkPolicy a través de la CLI de Cilium
Los operadores de plataforma pueden inspeccionar eventos de drop de eBPF en tiempo real para auditar intentos denegados de movimiento lateral.

```bash
$ cilium monitor --type drop
Signal arrive from parent process, parsing events...
xx drop 65535 at status inform: 10.244.1.84:43212 -> 169.254.169.254:80, egress policy dropped packet (CiliumNetworkPolicy)
xx drop 65535 at status inform: 10.244.1.84:51234 -> 10.244.1.15:6379, egress policy dropped packet (NetworkPolicy)
```

### 4.3 Inspeccionando Mapas de Seguridad eBPF en un Nodo de Kubernetes
Inspección profunda de las tablas de mapas eBPF del kernel que aplican el aislamiento de políticas de red en el nodo worker.

```bash
$ kubectl exec -n kube-system cilium-qn8v2 -c cilium-agent -- cilium bpf policy get 1421
POLICY ENFORCEMENT DIRECTION  IDENTITY   PORT/PROTO   ACTION     PACKETS   BYTES     
Ingress                       24102      8080/TCP     ALLOW      41295     2890640   
Ingress                       0          ANY          DENY       142       8520      
Egress                        3          53/UDP       ALLOW      892       64224     
Egress                        0          ANY          DENY       512       30720     
```

### 4.4 Validando el Tráfico Este-Oeste Cifrado de Forma Transparente con WireGuard
Para verificar que el tráfico de contenedores Este-Oeste entre nodos esté completamente cifrado en la interfaz física (`eth0`), inspeccione el formato en la red utilizando `tcpdump`.

```bash
$ sudo tcpdump -i eth0 -n "src host 192.168.1.50 and dst host 192.168.1.51"
20:18:02.104921 IP 192.168.1.50.51820 > 192.168.1.51.51820: UDP, length 1420
20:18:02.105231 IP 192.168.1.51.51820 > 192.168.1.50.51820: UDP, length 88
```
*Observe que las IPs de los contenedores (`10.244.x.x`) y los payloads de las aplicaciones (HTTP/SQL) están completamente ausentes en la captura de red, reemplazados por completo por paquetes UDP de WireGuard en el puerto 51820.*

---

## 5. Guía de Solución de Problemas, Diagnóstico de Fallas y Verificación

### 5.1 Matriz de Solución de Problemas para Fallas de Seguridad en la Red

```
                                  [ Issue Reported ]
                                          |
                        +-----------------+-----------------+
                        |                                   |
              [ Connection Dropped ]             [ Traffic Unencrypted ]
                        |                                   |
           +------------+------------+                      v
           |                         |            Inspect CNI Encryption State:
  [ Ingress Drop ]          [ Egress Drop ]       $ cilium encrypt status
           |                         |            - Verify WireGuard/IPsec SA keys
           v                         v            - Check node firewall (UDP 51820/ESP)
 Check Policy Selectors   Check DNS & IMDS Rules
 - `podSelector` labels   - Verify Port 53 UDP
 - eBPF map entry         - FQDN resolution table
 - iptables TRACE         - Cloud Metadata deny
```

| Síntoma | Causa Raíz | Método de Diagnóstico | Remediación |
| :--- | :--- | :--- | :--- |
| El Pod no logra resolver los servicios internos del cluster (tiempo de espera agotado en la resolución DNS). | NetworkPolicy de Egress aplicada sin permitir el puerto 53 UDP/TCP hacia CoreDNS. | Ejecute `dig +time=2 auth-service.prod.svc.cluster.local` desde el pod; verifique las reglas de egress de la política. | Agregue una regla de Egress explícita apuntando a `kube-dns` en el namespace `kube-system` en el puerto 53. |
| La Política de Egress FQDN permite la conexión inicial, luego descarta paquetes de forma aleatoria. | Desajuste de TTL DNS entre la caché de la aplicación cliente y la tabla de búsqueda del proxy FQDN del CNI. | Ejecute `cilium fqdn cache list` y compare las direcciones IP con `dig <domain>`. | Aumente la configuración `max-ttl` del proxy DNS en la configuración del CNI (`dnsproxy-min-ttl`). |
| La conexión mTLS de Istio devuelve `503 Service Unavailable` con `UC` (Terminación de Conexión Upstream). | La aplicación cliente envía texto plano a un servidor en modo mTLS `STRICT` sin inyección de sidecar de Istio. | Revise los logs de Envoy: `kubectl logs <pod> -c istio-proxy` buscando `TLS_error`. | Asegúrese de que el namespace tenga la etiqueta `istio-injection=enabled` o configure `PeerAuthentication` en `PERMISSIVE` temporalmente. |
| El Pod aún puede alcanzar `169.254.169.254` a pesar de la NetworkPolicy. | El CNI no admite `toCIDRSet` o el pod opera en modo `hostNetwork: true`. | Pruebe `curl http://169.254.169.254/latest/meta-data/` desde el pod; verifique el campo `hostNetwork` en el PodSpec. | Configure `hostNetwork: false` o aplique IMDSv2 de AWS con `HttpTokens=required` y `HttpPutResponseHopLimit=1`. |

### 5.2 Recorrido de Diagnóstico: Depuración de Tráfico de Egress Bloqueado

#### Paso 1: Rastrear Caídas de Paquetes en `iptables` (para CNIs que no usan eBPF como Kube-Router/Flannel)
Si utiliza NetworkPolicies estándar basadas en iptables, agregue un objetivo `TRACE` para capturar los veredictos de paquetes dentro de `kern.log`:

```bash
$ sudo iptables -t raw -A PREROUTING -p tcp --dport 5432 -j TRACE
$ dmesg -T | grep "TRACE: filter:KUBE-NWPLCY-DEFAULT-DENY"
[Fri Aug  7 20:20:12 2026] IN=veth84a0b2 OUT=eth0 SRC=10.244.1.84 DST=10.244.1.15 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=41203 DF PROTO=TCP SPT=43212 DPT=5432 SEQ=10294821 ACK=0 WINDOW=64240 RES=0x00 SYN URGP=0
```

#### Paso 2: Validar la Validez del Certificado SPIFFE en mTLS de Service Mesh
Verifique que el certificado X.509 cargado en el sidecar proxy Envoy sea válido y no haya expirado:

```bash
$ istioctl proxy-config secret payment-service-789456-abc12.production-workloads
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                         EXPIRES
default           CERTIFICATE    Active     true           19028301928301928301928               2026-08-08T20:00:00Z
ROOTCA            CERTIFICATE    Active     true           98127391827391827391827               2036-08-07T20:00:00Z
```

---

## 6. Referencias

- **CNCF KCSA Official Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

- **Kubernetes Official Documentation – Network Policies:**  
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

- **Cilium Documentation – Network Policy & L7 Security:**  
  [https://docs.cilium.io/en/stable/security/policy/](https://docs.cilium.io/en/stable/security/policy/)

- **Cilium Documentation – Transparent Wireguard/IPsec Encryption:**  
  [https://docs.cilium.io/en/stable/security/network/encryption/](https://docs.cilium.io/en/stable/security/network/encryption/)

- **Istio Documentation – PeerAuthentication & Authorization Policies:**  
  [https://istio.io/latest/docs/concepts/security/](https://istio.io/latest/docs/concepts/security/)

- **AWS Documentation – Restricting Access to IMDSv2:**  
  [https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

- **NIST SP 800-190 – Application Container Security Guide:**  
  [https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf)