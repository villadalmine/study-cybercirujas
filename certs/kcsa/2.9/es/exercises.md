# KCSA Tema 2.9: Laboratorio Guiado Práctico de Redes de Contenedores

**Dominio de Certificación:** Kubernetes Security Associate (KCSA)  
**Peso del Dominio:** 2.0  
**Versión Objetivo:** Kubernetes v1.30+  
**Referencias Oficiales:**  
* [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
* [Kubernetes Documentation: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)  
* [CNCF CNI Specification](https://github.com/containernetworking/cni/blob/main/SPEC.md)  
* [Cilium Security Architecture](https://docs.cilium.io/en/stable/security/)  
* [Calico Network Policy Architecture](https://docs.tigera.io/calico/latest/network-policy/)  

---

## Requisitos Previos y Entorno del Laboratorio
Asegurate de tener acceso a un clúster de Kubernetes que ejecute un plugin de CNI que admita la aplicación de `NetworkPolicy` (por ejemplo, Calico, Cilium o Flannel con Kube-Router). Los comandos utilizan `kubectl`, herramientas de red estándar de Linux (`ip`, `nsenter`) y diagnósticos de CNI.

---

## Ejercicio 1: Aislamiento de Linux Network Namespace e Inspección del CNI Data Plane

### Contexto Arquitectónico
Las redes de contenedores se basan en los namespaces de red de Linux (`netns`), pares de ethernet virtual (`veth`) y binarios de CNI. Cuando se crea un Pod, el plugin de CRI invoca al plugin de CNI a través de la API de especificación de CNI (comando `ADD`). El plugin de CNI crea un par `veth`, mueve un extremo al namespace de red del Pod (renombrado a `eth0`), conecta el extremo del host a un bridge o hook de eBPF, asigna una dirección IP y configura el enrutamiento y el firewall del host.

```
+-------------------------------------------------------------------------+
| Host Network Namespace (Node)                                           |
|                                                                         |
|  +-------------------------+            +----------------------------+  |
|  | CNI Bridge / eBPF Maps  |            | iptables / netfilter /     |  |
|  | (e.g. cni0 / cilium_host) |           | conntrack engine           |  |
|  +------------+------------+            +--------------+-------------+  |
|               |                                        |                |
|           vethX1234                                    |                |
|               | (veth pair boundary)                   |                |
+---------------+----------------------------------------+----------------+
                |
+---------------+---------------------------------------------------------+
| Pod Network Namespace (Target Pod)                                     |
|               |                                                         |
|             eth0 (10.244.1.15/24)                                       |
|               |                                                         |
|         [ App Container ]                                               |
+-------------------------------------------------------------------------+
```

### Pasos de Ejecución

1. Crear un namespace aislado `net-sec-lab` y desplegar un workload para inspeccionar:
```bash
kubectl create namespace net-sec-lab
kubectl run target-app --namespace=net-sec-lab --image=nginx:1.25-alpine --port=80
kubectl wait --for=condition=Ready pod/target-app -n net-sec-lab --timeout=60s
```
*Salida Esperada:*
```text
namespace/net-sec-lab created
pod/target-app created
pod/target-app condition met
```

2. Identificar el Node que ejecuta el Pod y el Container ID objetivo usando `kubectl`:
```bash
POD_NODE=$(kubectl get pod target-app -n net-sec-lab -o jsonpath='{.spec.nodeName}')
CONTAINER_ID=$(kubectl get pod target-app -n net-sec-lab -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
echo "Node: ${POD_NODE} | ContainerID: ${CONTAINER_ID}"
```
*Salida Esperada:*
```text
Node: worker-node-01 | ContainerID: a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0
```

3. Obtener el PID del Sandbox Network Namespace para el Pod usando `crictl` o `nerdctl` en el nodo worker (o mediante el socket del container runtime):
```bash
# Executed on the worker node:
PSTATUS=$(crictl inspectp --output json $(crictl pods --name target-app -q))
PID=$(echo $PSTATUS | jq '.info.pid')
echo "Pod Network Namespace PID: ${PID}"
```
*Salida Esperada:*
```text
Pod Network Namespace PID: 12458
```

4. Inspeccionar la interfaz de red y las rutas dentro del namespace de red del Pod desde el host:
```bash
nsenter -t ${PID} -n ip addr show dev eth0
nsenter -t ${PID} -n ip route show
```
*Salida Esperada:*
```text
3: eth0@if14: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP group default 
    link/ether 6e:4a:32:89:12:ef brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.1.15/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
default via 10.244.1.1 dev eth0 
10.244.1.0/24 dev eth0 scope link src 10.244.1.15 
```

5. Encontrar el índice de la interfaz `veth` correspondiente en el lado del host (índice `14` de `@if14`):
```bash
ip link show | grep -B1 "if3:"
```
*Salida Esperada:*
```text
14: vethb9a1c2d@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master cni0 state UP group default 
    link/ether 22:33:44:55:66:77 brd ff:ff:ff:ff:ff:ff link-netnsid 1
```

---

### Preguntas de Verificación (Ejercicio 1)

1. **Pregunta 1.1:** ¿Por qué la interfaz `veth` dentro del namespace del Pod hace referencia a `@if14`, mientras que la interfaz en el namespace del host hace referencia a `@if3`? ¿Qué límite de seguridad impone este mecanismo?
2. **Pregunta 1.2:** Si un atacante ejecuta un exploit de escape de contenedor (container breakout) y obtiene `CAP_NET_ADMIN` dentro de un Pod que no es `hostNetwork`, ¿puede reconfigurar las rutas de las interfaces o inspeccionar el tráfico de otros namespaces de red en el host?

---

## Ejercicio 2: Implementación de Microsegmentación Zero-Trust con NetworkPolicies

### Contexto Arquitectónico
De forma predeterminada, las redes en Kubernetes utilizan un modelo de red plana no segmentada: cualquier Pod puede comunicarse con cualquier otro Pod a través de todos los namespaces. Una `NetworkPolicy` actúa como un firewall de Ingress/Egress evaluado en el CNI data plane (a través de `iptables`, `IPVS` o mapas de `eBPF`). 

Cuando se aplica una `NetworkPolicy` a un namespace seleccionando un conjunto de Pods:
1. Los Pods seleccionados pasan de **Unisolated** (no aislados) a **Isolated** (aislados) para los tipos de política declarados (`Ingress`, `Egress` o ambos).
2. El tráfico que no esté permitido explícitamente por una regla de `ingress` o `egress` se descarta (Denegación Predeterminada Implícita / Implicit Default Deny).
3. La aplicación de `NetworkPolicy` es **stateful** (con estado): el tráfico de retorno para los flujos de conexión permitidos se autoriza automáticamente mediante las tablas de seguimiento de conexiones de `conntrack` o eBPF.

```
+----------------------------------------------------------------------------------+
| Namespace: net-sec-lab                                                           |
|                                                                                  |
|  +-------------------+        +--------------------+        +-----------------+  |
|  |   client-frontend |        |   backend-api      |        |   db-storage    |  |
|  | (role=frontend)   |        |  (role=backend)    |        |   (role=db)     |  |
|  +---------+---------+        +---------+----------+        +--------+--------+  |
|            |                            |                            |           |
|            | TCP/8080 (Allowed)         | TCP/5432 (Allowed)         |           |
|            +--------------------------->+--------------------------->+           |
|                                                                                  |
|            X-------------------------------------------------------->X           |
|                     TCP/5432 Direct Access BLOCKED (Default Deny)                |
+----------------------------------------------------------------------------------+
```

### Pasos de Ejecución

1. Desplegar un stack de aplicaciones de múltiples capas en `net-sec-lab`:
```bash
# Create Backend API
kubectl run backend-api -n net-sec-lab --image=nginx:1.25-alpine --labels="app=backend-api,tier=api" --port=8080
# Create Database
kubectl run db-storage -n net-sec-lab --image=nginx:1.25-alpine --labels="app=db-storage,tier=db" --port=5432
# Create Frontend Client
kubectl run client-frontend -n net-sec-lab --image=alpine:3.19 --labels="app=client-frontend,tier=frontend" -- sleep 3600

kubectl wait --for=condition=Ready pod --all -n net-sec-lab --timeout=60s
```
*Salida Esperada:*
```text
pod/backend-api created
pod/db-storage created
pod/client-frontend created
pod/backend-api condition met
pod/db-storage condition met
pod/client-frontend condition met
```

2. Obtener las direcciones IP internas de todos los pods:
```bash
BACKEND_IP=$(kubectl get pod backend-api -n net-sec-lab -o jsonpath='{.status.podIP}')
DB_IP=$(kubectl get pod db-storage -n net-sec-lab -o jsonpath='{.status.podIP}')
echo "Backend IP: ${BACKEND_IP} | DB IP: ${DB_IP}"
```
*Salida Esperada:*
```text
Backend IP: 10.244.1.16 | DB IP: 10.244.1.17
```

3. Verificar la conectividad no segmentada antes de aplicar las políticas:
```bash
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Salida Esperada:*
```text
10.244.1.17 (10.244.1.17:5432): open
```

4. Aplicar un manifiesto de NetworkPolicy de **Default Deny All Ingress and Egress** para aislar el namespace `net-sec-lab`:

```yaml
# default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: net-sec-lab
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```
Guardar y aplicar:
```bash
kubectl apply -f default-deny-all.yaml
```
*Salida Esperada:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
```

5. Confirmar que la comunicación ahora está bloqueada:
```bash
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Salida Esperada:*
```text
nc: bad address '10.244.1.17'
# or connection timed out after 2 seconds
```

6. Aplicar una política zero-trust que permita:
   - `client-frontend` acceder a `backend-api` en TCP 8080.
   - `backend-api` acceder a `db-storage` en TCP 5432.
   - Egress esencial de CoreDNS (UDP 53) para resolución DNS.

```yaml
# microsegmentation-rules.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: net-sec-lab
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: client-frontend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: db-storage
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend-api
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-egress-to-db
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: db-storage
    ports:
    - protocol: TCP
      port: 5432
```
Guardar y aplicar:
```bash
kubectl apply -f microsegmentation-rules.yaml
```
*Salida Esperada:*
```text
networkpolicy.networking.k8s.io/allow-dns-egress created
networkpolicy.networking.k8s.io/allow-frontend-to-backend created
networkpolicy.networking.k8s.io/allow-backend-to-db created
networkpolicy.networking.k8s.io/allow-backend-egress-to-db created
```

7. Ejecutar comandos de verificación de red:
```bash
# Test 1: Frontend to Backend (Should Succeed if port matches)
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${BACKEND_IP} 8080

# Test 2: Frontend to DB (Must Fail - Direct access prohibited)
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Salida Esperada:*
```text
10.244.1.16 (10.244.1.16:8080): open
nc: 10.244.1.17 (10.244.1.17:5432): Operation timed out
```

---

### Preguntas de Verificación (Ejercicio 2)

1. **Pregunta 2.1:** En `allow-frontend-to-backend`, ¿por qué especificamos `podSelector` debajo de `spec` para apuntar a `app: backend-api`, mientras que `app: client-frontend` está dentro de la lista `ingress.from`?
2. **Pregunta 2.2:** ¿Qué sucede si se omite `allow-backend-egress-to-db`, pero `allow-backend-to-db` (Ingress en DB) y `default-deny-all` están activos? ¿Tendrá éxito la solicitud?
3. **Pregunta 2.3:** Considerá un elemento `ingress` que combina `podSelector` y `namespaceSelector`:
   ```yaml
   ingress:
   - from:
     - namespaceSelector:
         matchLabels:
           env: prod
       podSelector:
         matchLabels:
           role: worker
   ```
   ¿En qué se diferencia esta evaluación en comparación con elementos de lista separados debajo de `from`:
   ```yaml
   ingress:
   - from:
     - namespaceSelector:
         matchLabels:
           env: prod
     - podSelector:
         matchLabels:
           role: worker
   ```

---

## Ejercicio 3: Diagnósticos del CNI Data Plane y Solución de Problemas de eBPF / iptables

### Contexto Arquitectónico
Cuando ocurre un descarte de paquetes por `NetworkPolicy`, la solución de problemas requiere diagnosticar si el problema se encuentra en la capa de DNS, la capa del motor de políticas de CNI, la capa de netfilter o la capa de túnel overlay.

En los CNI basados en `iptables` (por ejemplo, Calico en modo estándar), las reglas de política se programan en cadenas específicas de iptables (`cali-pi-...` / `cali-po-...`).  
En los CNI basados en `eBPF` (por ejemplo, Cilium), el filtrado ocurre directamente en la capa de sockets de Linux o en hooks de Ingress/Egress de TC (Traffic Control) utilizando mapas eBPF, omitiendo netfilter por completo.

```
iptables Engine (Traditional CNI):
[ Packet ] ---> TC ---> PREROUTING ---> FORWARD ---> cali-FORWARD ---> cali-pi-eth0 (Policy Check) ---> DROP/ACCEPT

eBPF Engine (Modern CNI):
[ Packet ] ---> Network Interface (TC Hook / XDP) ---> eBPF Program (Map Lookup: cilium_policy) ---> DROP/PASS
```

### Pasos de Ejecución

1. Inspeccionar objetos de `NetworkPolicy` activos y sus selectores:
```bash
kubectl get netpol -n net-sec-lab -o wide
```
*Salida Esperada:*
```text
NAME                         POD-SELECTOR        AGE   INGRESS-OWNERS   EGRESS-OWNERS
allow-backend-egress-to-db   app=backend-api     2m    <none>           <none>
allow-backend-to-db          app=db-storage      2m    <none>           <none>
allow-dns-egress             <none>              2m    <none>           <none>
allow-frontend-to-backend    app=backend-api     2m    <none>           <none>
default-deny-all             <none>              2m    <none>           <none>
```

2. Rastrear eventos de descarte (drop) en un Node basado en iptables:
```bash
# Executed on Node running the target Pod
iptables-save | grep -E "KUBE-NWPOLICY|cali-DROP|cilium" | head -n 20
```
*Salida Esperada (ejemplo de Calico):*
```text
:cali-pi-vethb9a1c2d - [0:0]
:cali-po-vethb9a1c2d - [0:0]
-A cali-pi-vethb9a1c2d -m comment --comment "cali:wX9_aBcDe123" -m state --state RELATED,ESTABLISHED -j ACCEPT
-A cali-pi-vethb9a1c2d -m comment --comment "cali:drop-default" -j MARK --set-xmark 0x10000/0x10000
-A cali-pi-vethb9a1c2d -m mark --mark 0x10000/0x10000 -j DROP
```

3. Rastrear veredictos de descarte de políticas en un Node con CNI basado en Cilium:
```bash
# Executed inside the Cilium agent pod on the target node
cilium monitor --type drop
```
*Salida Esperada:*
```text
xx drop (Policy denied) flow 0x0 to endpoint 1421, drop origin policy-ingress, bad-ip: 10.244.1.18 -> 10.244.1.17
```

4. Realizar una captura de paquetes dentro del namespace de red de `client-frontend` para inspeccionar los paquetes descartados (notar los reintentos de TCP SYN sin respuesta SYN-ACK cuando el CNI los descarta de forma independiente del estado o silenciosa):
```bash
nsenter -t ${PID} -n tcpdump -nn -i eth0 dst ${DB_IP} and port 5432
```
*Salida Esperada:*
```text
19:42:01.102938 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
19:42:02.104112 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
19:42:04.108221 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
^C
3 packets captured
3 packets received by filter
0 packets dropped by kernel
```

---

### Preguntas de Verificación (Ejercicio 3)

1. **Pregunta 3.1:** En la salida de `tcpdump`, vemos múltiples paquetes `Flags [S]` (SYN) retransmitidos sin recibir `[R.]` (RST) o `[S.]` (SYN-ACK). ¿Qué indica este patrón con respecto a cómo las políticas de red del CNI aplican el descarte de paquetes (Silent Drop vs Reject)?
2. **Pregunta 3.2:** Si un CNI usa eBPF (por ejemplo, Cilium en modo de reemplazo de kube-proxy), ¿por qué los comandos estándar `iptables-save` no mostrarán reglas activas de `NetworkPolicy`?

---

## Ejercicio 4: Cifrado Overlay y Seguridad en Tránsito (IPsec / WireGuard)

### Contexto Arquitectónico
Las Interfaces de Red de Contenedores (CNI) pueden cifrar el tráfico de Pod a Pod a través de los límites entre Nodes utilizando mecanismos de cifrado overlay como WireGuard o IPsec. Esto proporciona defensa en profundidad contra la inspección de red (sniffing) a nivel de nodo sin requerir modificaciones en la aplicación ni proxies de service mesh.

```
+------------------------+                        +------------------------+
| Node A (192.168.1.10)  |                        | Node B (192.168.1.11)  |
|                        |                        |                        |
|  [ Pod A: 10.244.1.5 ] |                        |  [ Pod B: 10.244.2.8 ] |
|           |            |                        |           ^            |
|     eth0 / veth        |                        |     eth0 / veth        |
|           v            |                        |           |            |
|   +---------------+    |                        |    +---------------+   |
|   | WireGuard/    |    |  Encrypted ESP/UDP    |    | WireGuard/    |   |
|   | IPsec Interface    +=======================>+    | IPsec Interface   |
|   +---------------+    | (Port 51820 / IPsec)   |    +---------------+   |
+------------------------+                        +------------------------+
```

### Pasos de Ejecución

1. Verificar el estado de la interfaz WireGuard en los nodos host cuando el cifrado transparente de CNI está habilitado:
```bash
# Executed on Node host
wg show
```
*Salida Esperada:*
```text
interface: cilium_wg0
  public key: 4xK9...aB8=
  private key: (hidden)
  listening port: 51820

peer: 7yL1...cD9=
  endpoint: 192.168.1.11:51820
  allowed ips: 10.244.2.0/24
  latest handshake: 12 seconds ago
  transfer: 1.42 MiB received, 2.18 MiB sent
```

2. Capturar el tráfico de la interfaz física entre nodos usando `tcpdump` para verificar que la carga útil entre Pods esté cifrada:
```bash
# Run on the physical host interface (e.g., eth0) while generating traffic between Pods across nodes:
tcpdump -i eth0 -n "port 51820 or proto 50"
```
*Salida Esperada:*
```text
19:45:10.110291 IP 192.168.1.10.51820 > 192.168.1.11.51820: UDP, length 148
19:45:10.112411 IP 192.168.1.11.51820 > 192.168.1.10.51820: UDP, length 180
```

---

### Preguntas de Verificación (Ejercicio 4)

1. **Pregunta 4.1:** ¿En qué se diferencia el cifrado transparente overlay del CNI (por ejemplo, WireGuard/IPsec) del mTLS a nivel de aplicación aplicado por una Service Mesh (por ejemplo, Istio/Linkerd) en términos de granularidad de autenticación y capa OSI de ejecución?
2. **Pregunta 4.2:** ¿El cifrado WireGuard del CNI cifra el tráfico de Pod a Pod que ocurre entre dos contenedores que se ejecutan en el *mismo* Node de Kubernetes?

---

## Comandos de Limpieza
```bash
kubectl delete namespace net-sec-lab
```

---

<details>
<summary><b>Hacé clic aquí para desplegar las Respuestas y Explicaciones Técnicas Detalladas</b></summary>

### Respuestas al Ejercicio 1

* **Respuesta 1.1:**  
  Un par `veth` (virtual ethernet) actúa como un cable virtual bidireccional que conecta dos namespaces de red. El índice de interfaz 3 (`eth0`) dentro del namespace de red del Pod está enlazado directamente con el índice de interfaz 14 (`vethb9a1c2d`) en el namespace de red del host (y viceversa).  
  *Límite de Seguridad:* Los namespaces de red de Linux aíslan el stack de red (interfaces, tablas de enrutamiento, reglas de iptables, sockets). El contenedor del Pod no puede ver, realizar bind ni manipular interfaces de red del host a menos que se configure `hostNetwork: true` en el `securityContext` del Pod.

* **Respuesta 1.2:**  
  **No.** Incluso si un atacante obtiene `CAP_NET_ADMIN` dentro de un contenedor de un Pod, las restricciones de los límites de namespace de Linux limitan su privilegio administrativo estrictamente al namespace de red de ese Pod. No pueden alterar rutas, modificar interfaces ni inspeccionar el tráfico en el host o en los namespaces de otros Pods porque no poseen `CAP_NET_ADMIN` dentro del namespace de red inicial del host (`init_net`).

---

### Respuestas al Ejercicio 2

* **Respuesta 2.1:**  
  En la sintaxis de `NetworkPolicy` de Kubernetes:
  * `spec.podSelector` define los **Pods Objetivo** a los que se aplica la política de firewall (en este caso, los pods `backend-api` que reciben el tráfico).
  * `spec.ingress.from.podSelector` define los **Pods de Origen Permitidos** que tienen autorización para iniciar conexiones entrantes a los pods objetivo.

* **Respuesta 2.2:**  
  **La solicitud será bloqueada.** Debido a que `default-deny-all` declara ambos tipos de política, `Ingress` y `Egress`, `backend-api` queda aislado tanto para el tráfico entrante como para el saliente.  
  Si bien `allow-backend-to-db` permite el *Ingress* en `db-storage`, `backend-api` no puede *iniciar* el handshake TCP de egress a menos que una política de `Egress` explícita (`allow-backend-egress-to-db`) permita a `backend-api` enviar paquetes hacia afuera en el puerto 5432.

* **Respuesta 2.3:**  
  * **Un único elemento en el arreglo con ambos selectores (evaluación AND):**
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            env: prod
        podSelector:
          matchLabels:
            role: worker
    ```
    Coincide con los Pods que tienen `role: worker` **Y** residen dentro de un namespace etiquetado con `env: prod`.
  * **Múltiples elementos en el arreglo (evaluación OR):**
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            env: prod
      - podSelector:
          matchLabels:
            role: worker
    ```
    Coincide con **CUALQUIER** Pod en un namespace etiquetado con `env: prod` **O** cualquier Pod en el namespace *actual* con la etiqueta `role: worker`.

---

### Respuestas al Ejercicio 3

* **Respuesta 3.1:**  
  Los paquetes `Flags [S]` (SYN) repetidos sin ninguna respuesta `RST` o `ACK` indican una acción de política de **Descarte Silencioso (FILTER / DROP)**. El firewall del CNI descarta los paquetes entrantes de forma silenciosa en lugar de enviar un paquete TCP RST o ICMP Port Unreachable (`REJECT`). Esto provoca que el stack TCP del cliente se quede colgado esperando un timeout durante la iniciación de la conexión (estado `SYN_SENT`).

* **Respuesta 3.2:**  
  Los CNI basados en eBPF ejecutan el código de filtrado de red directamente en hooks del kernel (por ejemplo, el clasificador TC de eBPF o XDP) antes de que los paquetes lleguen al subsistema `netfilter` de Linux. Como los paquetes omiten por completo los hooks de `iptables`, los comandos estándar `iptables-save` o `iptables -L` no mostrarán reglas de política ni contadores; el estado de seguridad se mantiene dentro de los mapas BPF del kernel eBPF (`cilium_policy_*`).

---

### Respuestas al Ejercicio 4

* **Respuesta 4.1:**  
  * **Cifrado Overlay Transparente del CNI (WireGuard/IPsec):** Opera en la Capa 3 (Capa de Red). Cifra paquetes IP de host a host que transportan tráfico de Pods. Autentica Nodos (identidad de la máquina) pero carece de identidad criptográfica de Pod o de conocimiento de la Capa 7 (encabezados HTTP/gRPC).
  * **Service Mesh mTLS (Istio/Linkerd):** Opera en la Capa 7 (Capa de Aplicación) a través de proxies sidecar/ambient. Proporciona **identidad SPIFFE de Pod a Pod** criptográfica, rotación de certificados mTLS, autorización detallada de URI/métodos HTTP y telemetría.

* **Respuesta 4.2:**  
  **No.** El cifrado WireGuard/IPsec del CNI se activa cuando el tráfico atraviesa las interfaces de red de los nodos a través del límite físico del host. Los Pods que se ejecutan en el *mismo* Node de Kubernetes se comunican internamente a través de switches virtual bridge locales o mapas de memoria eBPF, omitiendo por completo la interfaz del túnel WireGuard de host a host.

</details>