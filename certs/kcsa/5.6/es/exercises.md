# Preparación para el Examen KCSA: Dominio 5.6 – Connectivity (Peso: 2.29%)

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Documento de referencia:** [CNCF KCSA Curriculum (v1.0.0)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
**Fuentes de documentación oficial:**  
- [Kubernetes PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)  
- [Kubernetes Network Policies Specification](https://kubernetes.io/docs/concepts/services-networking/network-policies/)  
- [Istio Security Architecture & PeerAuthentication](https://istio.io/latest/docs/concepts/security/)  
- [SPIFFE/SPIRE Architecture](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)  
- [Cilium eBPF Datapath & Policy Mechanics](https://docs.cilium.io/en/stable/security/policy/)

---

## Visión general técnica y mecánica interna

En entornos cloud-native, la **Connectivity** abarca el data plane, el control plane y las rutas de red de borde (edge network paths). La seguridad en este dominio se basa en una **Zero-Trust Network Architecture (ZTNA)** donde se asume que los perímetros de red físicos o de superposición (overlay) están comprometidos.

```
+-----------------------------------------------------------------------------------+
|                                CONTROL PLANE PKI                                  |
|  [ kube-apiserver ] <--- mTLS (X.509 Client Certs) ---> [ etcd / kubelet ]        |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                             POD-TO-POD DATA PLANE                                 |
|  +------------------------+                     +------------------------------+  |
|  | Pod A (Frontend)       |   mTLS / SPIFFE ID   | Pod B (Backend)              |  |
|  | [Envoy Proxy]          | ===================>| [Envoy Proxy]                |  |
|  +------------------------+                     +------------------------------+  |
|               |                                                |                  |
|               v                                                v                  |
|  +-----------------------------------------------------------------------------+  |
|  | eBPF / CNI NetworkPolicy Engine (Default Deny Ingress & Egress Isolation)   |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                            EDGE & EGRESS BOUNDARIES                               |
|  [ Ingress Controller (TLS 1.3 / SNI) ] ----> [ Egress Gateway (FQDN / CIDR) ]    |
+-----------------------------------------------------------------------------------+
```

1. **Arquitectura PKI de Control Plane y Nodos**: Kubernetes se basa en una jerarquía interna de Public Key Infrastructure (PKI). El API Server autentica componentes (Kubelet, Scheduler, Controller Manager, `kubectl`) utilizando certificados de cliente X.509 duales. El campo `Subject` codifica la identidad a través de `CN` (Common Name = User/ServiceAccount) y `O` (Organization = pertenencia a grupos).
2. **Microsegmentación en Capa 3/4 (NetworkPolicies)**: Los recursos nativos `NetworkPolicy` de Kubernetes operan en L3 (direcciones IP) y L4 (puertos TCP/UDP/SCTP). Los plugins CNI aplican estas reglas utilizando primitivas del kernel:
   - **iptables / netfilter**: Compara los encabezados de los paquetes contra cadenas (`KUBE-NWPLCY-*`).
   - **eBPF (Extended Berkeley Packet Filter)**: Adjunta programas BPF directamente a los hooks de ingress/egress de `tc` (Traffic Control) o capas de sockets (`sockmap`), omitiendo el overhead del stack de red y filtrando en la capa del driver del kernel.
3. **Identidad en Capa 7 y Service Mesh mTLS**: Las NetworkPolicies no pueden inspeccionar el payload de la aplicación ni verificar criptográficamente la identidad de los Pods (debido a vulnerabilidades por reutilización de IP). Los service meshes (por ejemplo, Istio, Linkerd) inyectan proxies sidecar (Envoy) utilizando reglas de redirección `PREROUTING` / `OUTPUT` de `iptables` (por ejemplo, puertos 15001/15006). La identidad se establece mediante **SPIFFE IDs** (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`) incrustados en los Subject Alternative Names (SANs) X.509 rotados por una CA interna.

---

## Ejercicios prácticos guiados

---

### Ejercicio 1: Auditoría de PKI del Control Plane y Autenticación Mutua mTLS

En este ejercicio, analizarás los certificados X.509 del control plane, verificarás las entradas SAN y diagnosticarás los requerimientos de autenticación mTLS en la interfaz de `kube-apiserver`.

#### Pasos de ejecución

1. Conéctate por SSH a tu nodo de control plane y lista los archivos de certificados utilizados por `kube-apiserver`:

```bash
ls -la /etc/kubernetes/pki/
```

*Resultado esperado:*
```text
drwxr-xr-x 3 root root 4096 Aug  7 10:00 .
drwxr-xr-x 4 root root 4096 Aug  7 10:00 ..
-rw-r--r-- 1 root root 1099 Aug  7 10:00 ca.crt
-rw------- 1 root root 1679 Aug  7 10:00 ca.key
-rw-r--r-- 1 root root 1272 Aug  7 10:00 apiserver.crt
-rw------- 1 root root 1679 Aug  7 10:00 apiserver.key
-rw-r--r-- 1 root root 1107 Aug  7 10:00 apiserver-kubelet-client.crt
-rw------- 1 root root 1675 Aug  7 10:00 apiserver-kubelet-client.key
-rw-r--r-- 1 root root 1066 Aug  7 10:00 front-proxy-ca.crt
-rw------- 1 root root 1679 Aug  7 10:00 front-proxy-ca.key
```

2. Inspecciona el Subject, Issuer y los Subject Alternative Names (SANs) X.509 del certificado de servidor del API Server:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -E "Subject:|Issuer:|DNS:|IP Address:"
```

*Resultado esperado:*
```text
        Issuer: CN = kubernetes
        Subject: CN = kube-apiserver
            DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.10
```

3. Inspecciona la identidad del cliente codificada dentro del certificado de cliente de admin utilizado por `kubectl`:

```bash
openssl x509 -in /etc/kubernetes/admin.conf --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null || \
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -text -noout | grep "Subject:"
```

*Resultado esperado:*
```text
        Subject: O = system:masters, CN = kubernetes-admin
```

4. Intenta un handshake TLS no autenticado contra el puerto seguro del API Server (6443) usando `curl` para verificar el rechazo del certificado de cliente:

```bash
curl -k -v https://127.0.0.1:6443/api/v1/namespaces
```

*Resultado esperado:*
```text
*   Trying 127.0.0.1:6443...
* Connected to 127.0.0.1 (127.0.0.1) port 6443 (#0)
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Request CERT (13):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS handshake, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* HTTP/2 stream 1 allocated
> GET /api/v1/namespaces HTTP/2
> Host: 127.0.0.1:6443
> User-Agent: curl/7.81.0
> Accept: */*
> 
< HTTP/2 401 
< audit-id: e3b890f1-4c12-4a09-91a2-63b7e9bbf011
< content-type: application/json
< x-content-type-options: nosniff
< content-length: 129
< 
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

5. Vuelve a emitir la solicitud pasando el certificado de cliente X.509 y la clave privada válidos:

```bash
curl --cacert /etc/kubernetes/pki/ca.crt \
     --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
     --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
     https://127.0.0.1:6443/api/v1/namespaces | grep '"name":' | head -n 3
```

*Resultado esperado:*
```text
        "name": "default",
        "name": "kube-node-lease",
        "name": "kube-system",
```

---

#### Preguntas de verificación – Bloque 1

1. **Pregunta 1.1**: En el Subject del certificado de cliente `O = system:masters, CN = kubernetes-admin`, ¿cómo interpreta el autorizador RBAC del API Server los atributos `O` y `CN` durante la evaluación de la solicitud?
2. **Pregunta 1.2**: ¿Por qué `kube-apiserver` requiere direcciones IP y FQDNs específicos declarados bajo la extensión `X509v3 Subject Alternative Name` en `apiserver.crt`, y qué fallo de validación criptográfica ocurre si un cliente se conecta a través de una IP que no figura en el SAN?

---

### Ejercicio 2: Implementación de Microsegmentación Zero-Trust de Pods con NetworkPolicies Granulares

En este ejercicio, crearás un namespace para una aplicación multi-capa (multi-tier), aplicarás una política estricta de Default-Deny-All y autorizarás selectivamente la comunicación L4 de ingress/egress.

#### Pasos de ejecución

1. Crea un namespace aislado `production-secure`:

```bash
kubectl create namespace production-secure
```

*Resultado esperado:*
```text
namespace/production-secure created
```

2. Despliega una configuración de Pods para `frontend`, `backend` y `database`:

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app.kubernetes.io/name: frontend
    tier: frontend
spec:
  containers:
  - name: nginx
    image: nginx:1.25-alpine
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: backend
  labels:
    app.kubernetes.io/name: backend
    tier: backend
spec:
  containers:
  - name: app
    image: hashicorp/http-echo:latest
    args: ["-listen=:8080", "-text=backend response"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: database
  labels:
    app.kubernetes.io/name: database
    tier: database
spec:
  containers:
  - name: db
    image: hashicorp/http-echo:latest
    args: ["-listen=:5432", "-text=db response"]
    ports:
    - containerPort: 5432
EOF
```

*Resultado esperado:*
```text
pod/frontend created
pod/backend created
pod/database created
```

3. Obtén las direcciones IP de los Pods y verifica la conectividad inicial sin restricciones desde `frontend` hacia `database`:

```bash
DB_IP=$(kubectl get pod database -n production-secure -o jsonpath='{.status.podIP}')
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Resultado esperado:*
```text
db response
```

4. Aplica una política de **Default Deny All Ingress y Egress** para aislar todo el namespace:

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production-secure
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

*Resultado esperado:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
```

5. Prueba nuevamente la conectividad desde `frontend` hacia `database`. Verifica que el tráfico se descarte en la capa del datapath del CNI:

```bash
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Resultado esperado:*
```text
wget: download timed out
command terminated with exit code 1
```

6. Aplica NetworkPolicies granulares para permitir:
   - Egress de `frontend` a `backend` en el puerto TCP 8080.
   - Ingress de `backend` desde `frontend` en el puerto TCP 8080.
   - Egress de `backend` a `database` en el puerto TCP 5432.
   - Ingress de `database` desde `backend` en el puerto TCP 5432.
   - Egress UDP 53 hacia `kube-dns` para todos los Pods.

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production-secure
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-egress-to-backend
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-database
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-egress-to-database
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: database
    ports:
    - protocol: TCP
      port: 5432
EOF
```

*Resultado esperado:*
```text
networkpolicy.networking.k8s.io/allow-dns-egress created
networkpolicy.networking.k8s.io/allow-frontend-to-backend created
networkpolicy.networking.k8s.io/allow-frontend-egress-to-backend created
networkpolicy.networking.k8s.io/allow-backend-to-database created
networkpolicy.networking.k8s.io/allow-backend-egress-to-database created
```

7. Valida los flujos de comunicación autorizados frente a los no autorizados:

```bash
BACKEND_IP=$(kubectl get pod backend -n production-secure -o jsonpath='{.status.podIP}')

# Authorized: Frontend -> Backend (Port 8080)
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${BACKEND_IP}:8080

# Unauthorized: Frontend -> Database (Port 5432 - Must Timeout)
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Resultado esperado:*
```text
backend response
wget: download timed out
command terminated with exit code 1
```

---

#### Preguntas de verificación – Bloque 2

1. **Pregunta 2.1**: Si un Pod coincide con múltiples objetos `NetworkPolicy` que seleccionan sus labels en el mismo namespace, ¿cómo resuelve el plugin CNI las reglas de permitir/denegar en conflicto?
2. **Pregunta 2.2**: ¿Por qué es obligatorio definir explícitamente una regla de política de `Egress` orientada al puerto UDP 53 en `kube-dns` al aplicar una política de egress default-deny, incluso cuando el tráfico IP interno pod-a-pod está explícitamente autorizado?

---

### Ejercicio 3: Aplicación de mTLS en Service Mesh e Inspección de Identidad Criptográfica (Istio / SPIFFE)

En este ejercicio, aplicarás mutual TLS transparente estricto (`PeerAuthentication`) usando Istio e inspeccionarás la intercepción de datapath de Envoy y las identidades de certificados X.509 de SPIFFE.

#### Pasos de ejecución

1. Crea un namespace `mesh-secure` y habilita la inyección automática del sidecar de Envoy:

```bash
kubectl create namespace mesh-secure
kubectl label namespace mesh-secure istio-injection=enabled
```

*Resultado esperado:*
```text
namespace/mesh-secure created
namespace/mesh-secure labeled
```

2. Despliega una arquitectura de microservicios de ejemplo compuesta por `client` y `server`:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: server-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: server-svc
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: server
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: mesh-secure
  labels:
    app: server
spec:
  serviceAccountName: server-sa
  containers:
  - name: server
    image: hashicorp/http-echo:latest
    args: ["-listen=:8080", "-text=secure mesh response"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: mesh-secure
  labels:
    app: client
spec:
  containers:
  - name: client
    image: curlimages/curl:latest
    command: ["sleep", "3600"]
EOF
```

*Resultado esperado:*
```text
serviceaccount/server-sa created
service/server-svc created
pod/server created
pod/client created
```

3. Verifica la inyección del proxy sidecar Envoy (`2/2` contenedores listos):

```bash
kubectl get pods -n mesh-secure
```

*Resultado esperado:*
```text
NAME     READY   STATUS    RESTARTS   AGE
client   2/2     Running   0          25s
server   2/2     Running   0          25s
```

4. Aplica el modo **STRICT mTLS** en todo el namespace `mesh-secure` utilizando `PeerAuthentication` de Istio:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: mesh-secure
spec:
  mtls:
    mode: STRICT
EOF
```

*Resultado esperado:*
```text
peerauthentication.security.istio.io/default-strict-mtls created
```

5. Aplica una `AuthorizationPolicy` que garantice que `server-svc` SOLO pueda ser invocado por solicitudes que porten una identidad SPIFFE válida perteneciente a `client`:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: restrict-server-access
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: server
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/default"]
    to:
    - operation:
        methods: ["GET"]
        ports: ["8080"]
EOF
```

*Resultado esperado:*
```text
authorizationpolicy.security.istio.io/restrict-server-access created
```

6. Inspecciona las reglas de redirección de bajo nivel de `iptables` de Envoy ejecutadas dentro del network namespace del Pod:

```bash
kubectl exec -n mesh-secure server -c istio-proxy -- sudo netstat -tlpn 2>/dev/null || \
kubectl exec -n mesh-secure server -c istio-proxy -- pilot-agent request GET config_dump | grep -i "15006" -B 2 -A 5 | head -n 10
```

*Resultado esperado:*
```text
    "name": "virtualInbound",
    "active_state": {
     "version_info": "2026-08-07T10:00:00Z/1",
     "listener": {
      "@type": "type.googleapis.com/envoy.config.listener.v3.Listener",
      "name": "virtualInbound",
      "address": {
       "socket_address": {
        "address": "0.0.0.0",
        "port_value": 15006
```

7. Extrae y decodifica el certificado SPIFFE SVID X.509 activo presentado por el sidecar Envoy:

```bash
kubectl exec -n mesh-secure server -c istio-proxy -- openssl s_client -connect 127.0.0.1:15006 -showcerts </dev/null 2>/dev/null | openssl x509 -text -noout | grep -A 2 "Subject Alternative Name"
```

*Resultado esperado:*
```text
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/mesh-secure/sa/server-sa
```

8. Prueba la conectividad mTLS válida de extremo a extremo (end-to-end) desde `client` hacia `server-svc`:

```bash
kubectl exec -n mesh-secure client -c client -- curl -s http://server-svc:8080
```

*Resultado esperado:*
```text
secure mesh response
```

---

#### Preguntas de verificación – Bloque 3

1. **Pregunta 3.1**: ¿Cuál es la diferencia entre los modos `PERMISSIVE` y `STRICT` en la política `PeerAuthentication` de Istio, y qué riesgo de seguridad introduce el modo `PERMISSIVE` en un cluster de producción multi-tenant?
2. **Pregunta 3.2**: ¿Cómo previene SPIFFE la suplantación de identidad (identity spoofing) entre microservicios, y dónde está incrustado el SPIFFE ID dentro de la credencial criptográfica de la carga de trabajo (workload)?

---

### Ejercicio 4: Endurecimiento de Ingress en el Borde y Prevención de Exfiltración en Egress

En este ejercicio, endurecerás la ruta de conectividad de Ingress con estándares TLS modernos (TLS 1.3, suites de cifrado fuertes) e implementarás un control de límite de Egress para bloquear la comunicación no aprobada con IPs/dominios externos.

#### Pasos de ejecución

1. Genera un par de claves de certificado TLS autofirmado para el dominio externo `api.example.com`:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout egress-ingress-tls.key \
  -out egress-ingress-tls.crt \
  -subj "/CN=api.example.com/O=EdgeSecurity" \
  -addext "subjectAltName=DNS:api.example.com"
```

*Resultado esperado:*
```text
Generating a RSA private key
...................................................................+++++
writing new private key to 'egress-ingress-tls.key'
-----
```

2. Almacena el par de claves en un Secret de tipo `tls` de Kubernetes dentro del namespace `default`:

```bash
kubectl create secret tls edge-tls-secret \
  --cert=egress-ingress-tls.crt \
  --key=egress-ingress-tls.key
```

*Resultado esperado:*
```text
secret/edge-tls-secret created
```

3. Despliega un recurso Ingress sintácticamente válido configurado para la terminación TLS, aplicando TLS 1.3 y encabezados de seguridad a través de anotaciones del Ingress:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hardened-edge-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-protocols: "TLSv1.3"
    nginx.ingress.kubernetes.io/ssl-ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "Strict-Transport-Security: max-age=31536000; includeSubDomains; preload";
      more_set_headers "X-Frame-Options: DENY";
      more_set_headers "X-Content-Type-Options: nosniff";
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.example.com
    secretName: edge-tls-secret
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes
            port:
              number: 443
EOF
```

*Resultado esperado:*
```text
ingress.networking.k8s.io/hardened-edge-ingress created
```

4. Crea una política de aislamiento de egress en el namespace `egress-restricted` que deniegue explícitamente las conexiones salientes a IPs públicas de Internet, permitiendo el acceso **únicamente** a redes internas RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`):

```bash
kubectl create namespace egress-restricted

kubectl apply -n egress-restricted -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-external-egress
  namespace: egress-restricted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  # Rule 1: Allow DNS resolution inside cluster
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Rule 2: Restrict HTTP/HTTPS outbound to internal corporate subnets only
  - to:
    - ipBlock:
        cidr: 10.0.0.0/8
    - ipBlock:
        cidr: 172.16.0.0/12
    - ipBlock:
        cidr: 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
EOF
```

*Resultado esperado:*
```text
namespace/egress-restricted created
networkpolicy.networking.k8s.io/block-external-egress created
```

5. Despliega un Pod de prueba en `egress-restricted` y verifica que los intentos de exfiltración de datos hacia Internet (por ejemplo, llamar a `1.1.1.1` o `google.com`) sean descartados por la política de egress:

```bash
kubectl run test-exfil --image=curlimages/curl -n egress-restricted -- sleep 3600

# Wait for pod to be running
kubectl wait --for=condition=Ready pod/test-exfil -n egress-restricted --timeout=30s

# Test connectivity to external public IP (1.1.1.1) - Must fail/timeout
kubectl exec -n egress-restricted test-exfil -- curl -s --connect-timeout 3 https://1.1.1.1
```

*Resultado esperado:*
```text
pod/test-exfil condition met
command terminated with exit code 28
```

---

#### Preguntas de verificación – Bloque 4

1. **Pregunta 4.1**: ¿Qué vulnerabilidad ocurre si un recurso Ingress termina TLS utilizando un protocolo desactualizado (por ejemplo, TLS 1.0/1.1 o cifer suites CBC débiles), y cómo mitiga HTTP Strict Transport Security (HSTS) los ataques activos de degradación (downgrade) Man-in-the-Middle?
2. **Pregunta 4.2**: ¿Por qué las reglas estándar de `ipBlock` de `NetworkPolicy` L4 de Kubernetes son insuficientes por sí solas para prevenir la exfiltración de datos a dominios externos alojados en IPs públicas dinámicas de la Nube o CDNs (por ejemplo, AWS S3, Cloudflare), y qué componente cloud-native resuelve esta brecha?

---

## Soluciones y Explicaciones Técnicas Detalladas

<details>
<summary>Haz clic aquí para ver las soluciones detalladas y respuestas para todos los ejercicios</summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1**:
  Durante el pipeline de procesamiento de solicitudes del API Server, una vez que un certificado de cliente X.509 supera la validación criptográfica contra `ca.crt`, el API Server extrae los metadatos de identidad del encabezado `Subject` X.509 del certificado:
  - **Common Name (`CN`)**: Mapeado directamente como la **User identity** autenticada (`kubernetes-admin`).
  - **Organization (`O`)**: Mapeado directamente como la pertenencia a **Grupos** (Group memberships) del usuario. El valor `system:masters` es un grupo del sistema incorporado para emergencias (break-glass) en Kubernetes.
  
  Durante la fase de **RBAC Authorization**, el API Server comprueba los objetos `ClusterRoleBinding`. El binding de cluster por defecto `cluster-admin` vincula el grupo `system:masters` al `ClusterRole` `cluster-admin`. Por lo tanto, cualquier cliente que presente un certificado válido firmado por la CA del cluster con `O=system:masters` omite las verificaciones explícitas de roles de RBAC y se le otorgan privilegios totales de root (verbos `*` en recursos `*`) en todo el cluster.

* **Respuesta 1.2**:
  La extensión `X509v3 Subject Alternative Name` (SAN) especifica todos los nombres de host (nombres DNS) y direcciones IP válidos a través de los cuales el servidor TLS puede ser abordado legalmente. Cuando un cliente TLS (como `kubectl` o `kubelet`) inicia un handshake TLS contra `https://10.96.0.1:6443` o `https://kubernetes.default.svc`, realiza la verificación del nombre de host comparando la cadena del endpoint de destino con las entradas SAN en `apiserver.crt`.
  
  Si se accede al API Server a través de una IP o nombre DNS que **no** esté presente en la lista SAN (por ejemplo, `https://192.168.99.100:6443`), la librería TLS del cliente termina la conexión durante la fase de handshake devolviendo:
  `x509: certificate is valid for 10.96.0.1, 192.168.1.10, not 192.168.99.100`.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1**:
  La evaluación de `NetworkPolicy` en Kubernetes sigue un modelo de **Permiso Aditivo (Unión)**:
  1. **Estado por defecto (Default State)**: Por defecto, si ninguna `NetworkPolicy` selecciona a un Pod, este no está aislado (permite todo el ingress y egress).
  2. **Disparador de Aislamiento (Isolation Trigger)**: Tan pronto como un Pod es seleccionado por al menos una `NetworkPolicy` que define `Ingress` o `Egress` bajo `policyTypes`, se aísla para esa dirección.
  3. **Precedencia de Reglas (Rule Precedence)**: No existen **reglas DENY explícitas** en las `NetworkPolicies` estándar de Kubernetes. Si múltiples políticas seleccionan el mismo Pod, la política efectiva es la **unión lógica OR** de todas las reglas individuales de permiso de `ingress` y `egress` entre todas las políticas seleccionadoras. Una conexión se permite si satisface al menos una regla coincidente en cualquier política coincidente; de lo contrario, se descarta.

* **Respuesta 2.2**:
  Cuando se aplica una política de Default-Deny Egress a un namespace (`podSelector: {}`, `policyTypes: ["Egress"]`), **todo el tráfico de red saliente de cada Pod en ese namespace se bloquea por defecto**, incluido el tráfico destinado a servicios internos del cluster.
  
  Cuando un Pod de aplicación intenta resolver un nombre de host (por ejemplo, `http://backend:8080`), el runtime de la aplicación envía un paquete de consulta DNS UDP a la IP del resolvedor DNS del cluster (por ejemplo, CoreDNS en `10.96.0.10:53`). Si el egress hacia `kube-dns` en el puerto UDP 53 no está explícitamente permitido, el paquete de consulta DNS se descarta silenciosamente en el datapath del nodo (iptables/eBPF). En consecuencia, el Pod experimenta un fallo de resolución DNS (`Host not found` o timeout) **antes** de que pueda intentar establecer una conexión TCP HTTP saliente hacia el servicio backend.

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1**:
  - **Modo `PERMISSIVE`**: Permite que la carga de trabajo (workload) de destino acepte **tanto** tráfico TCP sin cifrar en texto plano como tráfico cifrado con mTLS de forma simultánea. Este modo está destinado exclusivamente a un estado temporal durante la migración a un service mesh. En producción, el modo `PERMISSIVE` introduce un riesgo grave: un atacante que obtenga ejecución dentro del límite de la red puede eludir el cifrado mTLS de Envoy y rastrear (sniff) o inyectar tráfico sin cifrar en texto plano hacia los servicios de destino.
  - **Modo `STRICT`**: Exige que **todas** las conexiones TCP entrantes a la carga de trabajo deban estar cifradas mediante mTLS y presentar un certificado X.509 SPIFFE válido emitido por la CA del Mesh. Cualquier intento de conexión en texto plano o conexión que presente un certificado no confiable se reinicia (reset) inmediatamente en la capa de socket por el proxy Envoy (puerto del listener `virtualInbound` 15006).

* **Respuesta 3.2**:
  SPIFFE (Secure Production Identity Framework for Everyone) previene la suplantación de identidad (identity spoofing) al reemplazar la identidad de red mutable basada en IP con certificados X.509 verificados criptográficamente llamados **SVIDs (SPIFFE Verifiable Identity Documents)**.
  
  El SPIFFE ID se formatea como una cadena URI estructurada:
  `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account-name>`
  
  Esta URI está incrustada en el campo **`Subject Alternative Name (SAN)`** del certificado X.509 (específicamente bajo `URI:`). Durante el handshake mTLS, los proxies Envoy en ambos extremos extraen y validan la extensión SAN contra los certificados raíz de confianza distribuidos por el control plane (por ejemplo, Istiod). Debido a que el par de claves del certificado se genera directamente en la memoria del Pod y es de corta duración (se rota cada pocas horas), un atacante no puede suplantar la identidad de otra ServiceAccount sin poseer su clave privada.

---

### Soluciones del Ejercicio 4

* **Respuesta 4.1**:
  - **Protocolos/Cifrados Desactualizados**: TLS 1.0/1.1 y los cifer suites legacy en modo CBC son vulnerables a ataques criptográficos (por ejemplo, BEAST, POODLE, LUCKY13), permitiendo a atacantes que intercepten el tráfico de red descifrar sesiones de payload o falsificar tokens de autenticación. TLS 1.3 elimina las primitivas inseguras legacy, aplicando forward secrecy a través de Ephemeral Diffie-Hellman (ECDHE).
  - **HSTS (HTTP Strict Transport Security)**: HSTS envía un encabezado de respuesta HTTP (`Strict-Transport-Security: max-age=31536000; includeSubDomains`) indicando a los agentes de usuario y navegadores que **fuercen** automáticamente toda comunicación futura a través de HTTPS. Esto previene ataques de SSL-stripping en los cuales un interceptor Man-in-the-Middle (MitM) degrada una solicitud inicial `http://` a texto plano antes de que el servidor pueda ejecutar una redirección HTTP-a-HTTPS 301.

* **Respuesta 4.2**:
  Los objetos estándar de `NetworkPolicy` L4 de Kubernetes se basan en bloques estáticos de IP/CIDR (`ipBlock.cidr`). Los servicios externos modernos (por ejemplo, AWS S3, GitHub APIs, pasarelas de pago, CDNs) utilizan pools de IP dinámicos multirregión, enrutamiento Anycast y registros DNS A/AAAA que cambian rápidamente. Codificar directamente direcciones IP públicas en manifiestos de `ipBlock` es insostenible e inseguro.
  
  Para resolver esta brecha en el control de exfiltración, las arquitecturas cloud-native utilizan **Service Mesh Egress Gateways** o **FQDN-based L7 Network Policies** (tales como `CiliumNetworkPolicy` de Cilium con coincidencia de `fqdn`):
  - **Inspección DNS / Filtrado SNI**: El proxy de egress intercepta las solicitudes salientes, realiza la inspección de paquetes TLS Server Name Indication (SNI) o el análisis del encabezado HTTP Host, y evalúa el tráfico contra una lista blanca (whitelist) de dominios autorizados (por ejemplo, permitir exclusivamente `*.s3.amazonaws.com`) mientras descarta los intentos de egress no autorizados, independientemente de la dirección IP subyacente.

</details>