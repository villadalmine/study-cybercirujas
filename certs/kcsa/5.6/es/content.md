# Guía de estudio KCSA: Tema 5.6 – Conectividad

**Dominio:** Seguridad de Microservicios y Plataforma  
**Peso del examen:** 2.29%  
**Nivel objetivo:** Arquitecto Principal de Plataforma / SRE Senior  

---

## 1. Motivación arquitectónica y planteamiento del problema en producción

En las implementaciones por defecto de CNI en Kubernetes (por ejemplo, Flannel estándar o Calico/Cilium sin configurar), la red del cluster opera en un **modelo de tráfico Este-Oeste plano y no segmentado**. Cada Pod puede enrutar paquetes directamente a cualquier otro Pod entre namespaces utilizando enrutamiento IP sin autenticación ni inspección de protocolos. 

```
[ Compromised Pod (Namespace: dev) ] 
               │
               ▼ (Unrestricted IP Routing / East-West Flat Network)
[ Payment Database Pod (Namespace: prod) ]  <-- CRITICAL EXPLOIT VECTOR
```

### Vectores de amenaza y riesgos en producción
1. **Movimiento lateral post-explotación:** Si un atacante compromete un servicio de borde expuesto públicamente vulnerable (por ejemplo, a través de una vulnerabilidad de ejecución remota de código), la red plana permite un reconocimiento sin restricciones y la exfiltración de datos contra microservicios internos, endpoints del control plane o Pods de bases de datos.
2. **Falta de verificación de identidad:** El enrutamiento IP estándar se basa puramente en direcciones IP. El IP spoofing, la recreación de Pods (rotación de IPs / IP churn) o el envenenamiento de caché ARP/ND en redes overlay no cifradas pueden llevar a una suplantación de identidad no autorizada.
3. **Exfiltración de datos salientes (Egress):** Sin controles de egress, los Pods comprometidos pueden establecer conexiones TCP salientes a servidores externos de Comando y Control (C2) o exfiltrar datos sensibles a través de puertos no estándar.
4. **Falta de cifrado a nivel de cable (Wire-Level Encryption):** El tráfico de red intra-cluster a través de subredes VPC en nubes públicas o hosts bare-metal de múltiples racks viaja en texto plano, lo que lo hace vulnerable a la captura de paquetes (packet sniffing) y ataques man-in-the-middle (MitM).

### Requisitos de la Arquitectura de Red Zero Trust (ZTNA)
Para lograr el cumplimiento normativo (PCI-DSS, SOC 2, HIPAA) y una postura de zero-trust, los equipos de ingeniería de plataforma deben aplicar:
- **Aislamiento predeterminado de denegación (Default-Deny Ingress/Egress):** Evaluación explícita de políticas basadas en inclusión (opt-in) para todas las rutas de comunicación.
- **Límites de mínimo privilegio en Capa 4 y Capa 7:** Restringir el acceso no solo por IP/Puerto, sino también por Service Accounts verificadas criptográficamente, métodos HTTP y rutas de URL.
- **Cifrado a nivel de cable (Wire-Level Encryption):** Cifrado transparente IPsec o WireGuard en la capa del CNI, combinado con mTLS (Mutual TLS) en la capa de aplicación.

---

## 2. Comparativa técnica y matriz de compensaciones (Trade-offs)

| Vector / Dimensión | Kubernetes Native NetworkPolicy (L4) | Cilium CRD Policies (L4 + L7 + FQDN) | Service Mesh mTLS (Istio / Linkerd) | CNI Transparent Encryption (WireGuard / IPsec) |
| :--- | :--- | :--- | :--- | :--- |
| **Capa de aplicación de políticas (Enforcement Layer)** | Capa 3 / Capa 4 (IP, CIDR, Puerto, Protocolo) | Capa 3 / Capa 4 / Capa 7 (HTTP, gRPC, Kafka, FQDN) | Capa 7 (mTLS, JWT, RBAC, Enrutamiento HTTP) | Capa 3 (Nivel de cable Nodo a Nodo / Pod a Pod) |
| **Mecanismo de implementación** | `iptables`, `ipvs` o mapas eBPF del CNI | Probes eBPF del kernel de Linux y proxies Envoy inline | Proxy sidecar (Envoy) o daemon a nivel de nodo/Ambient | Módulo WireGuard a nivel de kernel o IPsec ESP |
| **Impacto en el rendimiento** | De bajo a alto (`iptables` escala $O(N)$ con la cantidad de políticas) | Extremadamente bajo (velocidad de búsqueda $O(1)$ mediante mapas Hash eBPF) | De moderado a alto (latencia de Sidecar + sobrecarga de memoria) | Bajo (criptografía acelerada por hardware) |
| **Mecanismo de identidad** | Namespace y Labels de Pod | Labels de identidad + IDs de seguridad eBPF | Certificados X.509 SVID (SPIFFE/SPIRE) | Clave pública de Máquina/Nodo o IPsec SA |
| **Conocimiento de protocolos L7** | Ninguno | Completo (Ruta/Verbo HTTP, Método gRPC, regex FQDN) | Completo (HTTP, gRPC, WebSockets) | Ninguno (solo capa de red) |
| **Autenticación criptográfica** | Ninguna | Opcional (integración con SPIFFE) | Handshake mTLS criptográfico por conexión | Cifrado de túnel simétrico / asimétrico |
| **Complejidad operativa** | Baja (primitivas nativas de la API de K8s) | Media (requiere CNI eBPF y CRDs personalizados) | Alta (requiere Control Plane, Autoridad de Certificación, ciclo de vida de Envoy) | Baja-Media (Flag de configuración de CNI) |

---

## 3. Manifiestos de producción completos y especificaciones de infraestructura

Los siguientes manifiestos construyen un entorno de producción aislado de múltiples capas en el namespace `payments-prod` utilizando redes estrictas de mínimo privilegio.

### 3.1 Namespace de producción y cargas de trabajo (Workloads) aisladas

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments-prod
  labels:
    environment: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-serviceaccount
  namespace: payments-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-db
  namespace: payments-prod
  labels:
    app.kubernetes.io/name: payment-db
    tier: database
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-db
      tier: database
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-db
        tier: database
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_PASSWORD
          value: "SecureProductionPassword123!"
        resources:
          limits:
            cpu: "1"
            memory: "1Gi"
          requests:
            cpu: "250m"
            memory: "256Mi"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 70
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: payment-db-svc
  namespace: payments-prod
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: postgres
    protocol: TCP
    name: postgres
  selector:
    app.kubernetes.io/name: payment-db
    tier: database
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payments-prod
  labels:
    app.kubernetes.io/name: payment-api
    tier: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-api
      tier: api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-api
        tier: api
    spec:
      serviceAccountName: api-serviceaccount
      containers:
      - name: api
        image: nginx:1.25-alpine
        ports:
        - containerPort: 8080
          name: http
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 101
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: payment-api-svc
  namespace: payments-prod
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app.kubernetes.io/name: payment-api
    tier: api
```

---

### 3.2 NetworkPolicies nativas de Kubernetes (Aislamiento estricto en L4)

#### Denegación por defecto de todo Ingress y Egress
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

#### Política de Egress para CoreDNS (Requerida para Service Discovery)
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-coredns-egress
  namespace: payments-prod
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

#### Política de comunicación multicapa de grano fino
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-db
  namespace: payments-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: payment-db
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: payment-api
          tier: api
    ports:
    - protocol: TCP
      port: 5432
```

---

### 3.3 Política de Egress avanzada de L7 y FQDN (`CiliumNetworkPolicy`)

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: payment-api-l7-egress-rules
  namespace: payments-prod
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: payment-api
      tier: api
  egress:
  # Allow internal DB access at L4
  - toEndpoints:
    - matchLabels:
        app.kubernetes.io/name: payment-db
        tier: database
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
  # Allow External Payment Gateway via FQDN and enforce HTTPS L7 filtering
  - toFQDNs:
    - matchName: "api.stripe.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charges"
```

---

### 3.4 Recurso Ingress con terminación TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payment-ingress
  namespace: payments-prod
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  tls:
  - hosts:
    - payments.example.com
    secretName: payments-tls-cert
  rules:
  - host: payments.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: payment-api-svc
            port:
              number: 8080
```

---

## 4. Comandos reales de ejecución en CLI y salidas esperadas en terminal

### 4.1 Aplicación de manifiestos de red y verificación del estado de políticas

```bash
$ kubectl apply -f payment-workloads.yaml
namespace/payments-prod created
serviceaccount/api-serviceaccount created
deployment.apps/payment-db created
service/payment-db-svc created
deployment.apps/payment-api created
service/payment-api-svc created

$ kubectl apply -f network-policies.yaml
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-coredns-egress created
networkpolicy.networking.k8s.io/allow-api-to-db created

$ kubectl get networkpolicies -n payments-prod -o wide
NAME                   POD-SELECTOR                       AGE   POLICY-TYPES
allow-api-to-db        app.kubernetes.io/name=payment-db  12s   Ingress
allow-coredns-egress   <none>                             12s   Egress
default-deny-all       <none>                             12s   Ingress,Egress
```

---

### 4.2 Validación del tráfico permitido (API -> Base de datos)

```bash
$ API_POD=$(kubectl get pod -n payments-prod -l app.kubernetes.io/name=payment-api -o jsonpath='{.items[0].metadata.name}')
$ DB_SVC_IP=$(kubectl get svc -n payments-prod payment-db-svc -o jsonpath='{.spec.clusterIP}')

$ kubectl exec -n payments-prod -it $API_POD -- nc -zv -w 3 $DB_SVC_IP 5432
payment-db-svc.payments-prod.svc.cluster.local (10.96.142.88:5432) open
```

---

### 4.3 Prueba de denegación por defecto y aplicación de políticas (Pod no autorizado -> Base de datos)

```bash
$ kubectl run unauthorized-test --image=alpine:3.18 -n payments-prod -it --rm -- sh
If you don't see a command prompt, try pressing enter.
/ # nc -zv -w 3 payment-db-svc 5432
nc: payment-db-svc (10.96.142.88:5432): Operation timed out
/ # ping -c 2 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
--- 8.8.8.8 ping statistics ---
2 packets transmitted, 0 packets received, 100% packet loss
/ # exit
Session ended, pod payments-prod/unauthorized-test deleted
```

---

### 4.4 Depuración del estado de cifrado de WireGuard en el CNI (Cilium CLI)

```bash
$ cilium status --verbose | grep -A 5 "Encryption"
Encryption: Wireguard
  Mode: Wireguard
  Keys: 1/1 active
  Interface: cilium_wg0
  Node-to-Node: Enabled
  Pod-to-Pod: Enabled
```

---

### 4.5 Inspección de mapas de red eBPF de bajo nivel

```bash
$ CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- cilium bpf policy dump
POLICY MAP: DATAPATH POLICY MAP (v2)
POLICY   DIRECTION   IDENTITY   PORT/PROTO   BYTES   PACKETS   ACTION
Rule 1   Ingress     45210      5432/TCP     4082    62        ALLOW
Rule 2   Egress      1          53/UDP       1240    18        ALLOW
Rule 3   Ingress     ANY        ANY          582     12        DROP (Default Deny)
```

---

## 5. Guía de solución de problemas (Runbook) para verificación, diagnóstico y fallos

### Diagrama de flujo de diagnóstico

```
[ Connectivity Issue Detected ]
              │
              ▼
[ 1. Check Pod DNS Resolution ] ──(Fails)──► Check CoreDNS Egress Policy (Port 53 UDP/TCP)
              │
           (Passes)
              ▼
[ 2. Verify Selectors & Labels ] ──(Mismatch)──► Fix matchLabels / podSelector
              │
           (Passes)
              ▼
[ 3. Inspect CNI Agent Logs ] ──(Sync Error)──► Restart CNI Agent DaemonSet
              │
           (Passes)
              ▼
[ 4. Analyze eBPF / iptables Drops ] ──► Check 'cilium monitor --type drop' or 'iptables-save'
```

---

### 5.1 Modos de fallo comunes en producción

#### Problema A: Tiempo de espera agotado (Timeout) en la resolución DNS de Egress
* **Síntoma:** Los Pods no pueden resolver los nombres de servicio (`payment-db-svc.payments-prod.svc.cluster.local`), mostrando `Host unreachable` o `Name or service not known`.
* **Causa raíz:** Se aplicó una NetworkPolicy `default-deny-all` sin una regla explícita de egress que permita el tráfico a CoreDNS (`kube-dns`) en el puerto 53 UDP/TCP.
* **Remediación:** Aplicar la política `allow-coredns-egress` dirigida al namespace `kube-system`.

#### Problema B: Incompatibilidad (Mismatch) de selectores de NetworkPolicy entre namespaces
* **Síntoma:** La política de ingress no logra permitir llamadas a la API entre namespaces a pesar de contar con un `namespaceSelector` explícito.
* **Causa raíz:** El namespace de destino carece de los labels coincidentes. `namespaceSelector` coincide con labels en el objeto `Namespace` en sí, **no** con la cadena del nombre del namespace (a menos que se use la label estándar `kubernetes.io/metadata.name`).
* **Remediación:** Asegurarse de que los namespaces tengan aplicados los labels correctos (`kubectl label ns payments-prod environment=production`).

#### Problema C: Motor de políticas del CNI desincronizado / Mapa eBPF lleno
* **Síntoma:** Los Pods no logran transmitir paquetes incluso cuando los manifiestos de NetworkPolicy parecen sintácticamente válidos.
* **Causa raíz:** El daemon del CNI falló al reconciliar el estado del mapa BPF debido a límites de mapa agotados o desbordamiento del ring buffer del kernel de Linux.
* **Runbook de remediación:**

```bash
# 1. Describe the failing NetworkPolicy to check validation errors
$ kubectl describe networkpolicy allow-api-to-db -n payments-prod

# 2. Monitor live network drops using Hubble / Cilium Monitor
$ kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- cilium monitor --type drop
XX drop (Policy denied) flow 0x3f5ab120 to endpoint 40125, drop-reason Policy denied, Verdict Drop, PolicyID 3

# 3. Check iptables drop counters (if using iptables-based CNI like Calico/Kube-Router)
$ iptables-save | grep -i "KUBE-NWPOLICY"
-A KUBE-NWPOLICY-DEFAULT-DENY -m comment --comment "default-deny-all policy" -j DROP

# 4. Verify Node network interfaces and MTU mismatch
$ ip link show | grep -E "cilium|calico|flannel|wireguard"
14: cilium_wg0: <MTU 1420,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN group default
```

---

## 6. Referencias

- **CNCF KCSA Exam Curriculum:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Official Documentation – Network Policies:**  
  https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **Kubernetes Security Task Guide – Declare Network Policy:**  
  https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- **Cilium Security Architecture & Policy Engine:**  
  https://docs.cilium.io/en/stable/security/policy/
- **Istio Security Architecture & Authorization Policies:**  
  https://istio.io/latest/docs/concepts/security/
- **Kubernetes Ingress & TLS Termination Specification:**  
  https://kubernetes.io/docs/concepts/services-networking/ingress/#tls