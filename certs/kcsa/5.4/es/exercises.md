# Módulo de Estudio para el Examen KCSA: Tema 5.4 — Service Mesh Security

**Certificación Objetivo:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 5:** Application & Workload Security  
**Tema 5.4:** Service Mesh Security  
**Peso del Dominio:** ~2.29%  
**Referencia Oficial:** [CNCF KCSA Curriculum (GitHub)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Deep-Dive Architecture & Production Mechanics

### 1.1 El Paradigma de Seguridad de Service Mesh

Un Service Mesh proporciona características de seguridad transparentes a nivel de infraestructura para las aplicaciones sin requerir modificaciones en el código. Desde la perspectiva de la arquitectura de seguridad, implementa una **Zero Trust Network Architecture (ZTNA)** dentro de los clusters de Kubernetes.

```
                          +-------------------------------------------------------+
                          |                   Control Plane                       |
                          | (e.g., Istiod / SPIRE Server / Linkerd Control Plane) |
                          +--------------------------+----------------------------+
                                                     |
                                           xDS / mTLS / X.509 CA
                                                     |
  +--------------------------------------------------v--------------------------------------------------+
  |  Data Plane (Pod Boundary)                                                                          |
  |                                                                                                     |
  |  +---------------------------+    iptables / eBPF redirect   +------------------------------------+  |
  |  |    Application Container  | <===========================> |        Sidecar Proxy               |  |
  |  |   (App code, plain HTTP)  |       localhost traffic       |        (Envoy Proxy)               |  |
  |  +---------------------------+                               +-----------------+------------------+  |
  +--------------------------------------------------------------------------------|--------------------+
                                                                                   |
                                                                        mTLS (X.509 SVID / SPIFFE)
                                                                                   |
  +--------------------------------------------------------------------------------v--------------------+
  |  Data Plane (Peer Pod Boundary)                                                                     |
  |                                                              +------------------------------------+  |
  |                                                              |     Peer Envoy Proxy               |  |
  |                                                              +-----------------+------------------+  |
  +-----------------------------------------------------------------------------------------------------+
```

#### Componentes Principales y Funciones de Seguridad

1. **Gestión de Identidad Criptográfica (SPIFFE/SPIRE & X.509 SVIDs):**
   - La identidad del workload se desacopla de las direcciones IP y los namespaces.
   - Los identificadores siguen el estándar SPIFFE ID (por ejemplo, `spiffe://cluster.local/ns/prod/sa/payment-service`).
   - Los certificados X.509 de corta duración (SVIDs) son emitidos, montados y rotados continuamente de forma automática (típicamente cada 12–24 horas) por los componentes del Control Plane (por ejemplo, `istiod` o agentes de SPIRE).

2. **Mutual TLS (mTLS) y Cifrado de Tráfico:**
   - **Permissive Mode:** Acepta tanto tráfico en texto plano como mTLS. Utilizado exclusivamente durante migraciones brownfield.
   - **Strict Mode:** Rechaza todo el tráfico en texto plano no cifrado en la interfaz del proxy mediante la validación del handshake TLS.

3. **Control de Acceso en Capa 4 y Capa 7 (RBAC y Authorization Policies):**
   - **Políticas L4:** Evalúan IPs de origen/destino, puertos e IDs de SPIFFE autenticados.
   - **Políticas L7:** Inspeccionan métodos HTTP, URIs, cabeceras, nombres de host y claims JWT extraídos de las cabeceras de la petición.

4. **Mecánica de Redirección de Tráfico:**
   - **Sidecar Model:** Utiliza reglas de `iptables` (a través de `initContainers` o plugins `CNI`) para redirigir el tráfico de `PREROUTING` y `OUTPUT` al puerto local `15001`/`15006` gestionado por Envoy.
   - **Ambient / Sidecarless Model:** Utiliza eBPF o proxies a nivel de nodo (ztunnel) para manejar el cifrado mTLS L4 por nodo, con proxies L7 opcionales (Waypoints) desplegados por namespace o ServiceAccount.

---

### 1.2 Architectural Trade-Off Analysis

| Dimensión Arquitectónica | Arquitectura Sidecar (Envoy por Pod) | Arquitectura Ambient / Sidecarless (ztunnel + Waypoint) |
| :--- | :--- | :--- |
| **Límite de Aislamiento de Seguridad** | **A nivel de Pod.** El compromiso de un solo sidecar proxy solo expone el espacio de memoria y los certificados de ese pod. | **A nivel de Nodo (L4) + A nivel de Pod (L7).** ztunnel se ejecuta como DaemonSet; un fallo de memoria podría impactar el mTLS L4 del nodo. |
| **Sobrecarga de Recursos** | Huella de memoria/CPU alta agregada en clusters grandes (10–50MB de RAM por sidecar). | Huella base baja a nivel de nodo para L4. Los recursos L7 se asignan dinámicamente mediante proxies Waypoint. |
| **Compatibilidad con Aplicaciones** | Requiere inyección de contenedores (`initContainers`, manipulación de `iptables` o CNI). | Completamente transparente para las especificaciones del Pod; no requiere inyección. Utiliza eBPF / enrutamiento Geneve a nivel de kernel. |
| **Superficie de Ataque** | Requiere capacidades elevadas de `NET_ADMIN` o `NET_RAW` durante el init, a menos que se despliegue un Service Mesh CNI. | Elimina por completo los requerimientos de `NET_ADMIN` en el pod. |

---

### 1.3 Official Reference URLs

- **Istio Security Architecture:** [https://istio.io/latest/docs/concepts/security/](https://istio.io/latest/docs/concepts/security/)
- **SPIFFE Concepts:** [https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)
- **CNCF KCSA Curriculum Specification:** [https://github.com/cncf/curriculum](https://github.com/cncf/curriculum)
- **Envoy Proxy Security Documentation:** [https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security)

---

## 2. Guided Production Lab Exercises

### Ejercicio 1: Aplicación de mTLS Estricto y Validación de Identidad Criptográfica SPIFFE

#### Objetivo
Configurar la aplicación de mTLS estricto a nivel de namespace utilizando primitivas de seguridad de Istio, verificar la validación de certificados y probar que las peticiones en texto plano no autenticadas se terminan en la Capa 4.

#### Paso 1: Preparar Namespaces y Desplegar Workloads de Prueba
Ejecutá los siguientes comandos para crear namespaces aislados, etiquetarlos para la inyección de sidecar y desplegar workloads de cliente y servidor.

```bash
kubectl create namespace mesh-secure
kubectl label namespace mesh-secure istio-injection=enabled

kubectl create namespace legacy-unmeshed
```

Aplicá el siguiente manifiesto para desplegar los workloads de `frontend` (cliente) y `backend` (servidor):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      serviceAccountName: backend-sa
      containers:
      - name: hashicorp-http-echo
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=secure-payload-v1"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: backend-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-client
  namespace: legacy-unmeshed
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-client
  template:
    metadata:
      labels:
        app: legacy-client
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
```

Aplicá el manifiesto:
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      serviceAccountName: backend-sa
      containers:
      - name: hashicorp-http-echo
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=secure-payload-v1"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: backend-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-client
  namespace: legacy-unmeshed
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-client
  template:
    metadata:
      labels:
        app: legacy-client
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF
```

#### Paso 2: Aplicar la Política PeerAuthentication STRICT
Aplicá un manifiesto de `PeerAuthentication` dirigido al namespace `mesh-secure` para rechazar el tráfico en texto plano.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: mesh-secure
spec:
  mtls:
    mode: STRICT
```

Ejecutá el comando:
```bash
kubectl apply -f - <<EOF
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

Salida esperada:
```
peerauthentication.security.istio.io/default-strict-mtls created
```

#### Paso 3: Validar el Rechazo de Conexiones desde Pods fuera del Mesh
Intentá ejecutar una petición HTTP directa desde el pod fuera del mesh en el namespace `legacy-unmeshed`:

```bash
LEGACY_POD=$(kubectl get pod -n legacy-unmeshed -l app=legacy-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n legacy-unmeshed "$LEGACY_POD" -- curl -sS --connect-timeout 3 http://backend-api.mesh-secure.svc.cluster.local:8080/
```

Salida esperada:
```
curl: (56) Recv failure: Connection reset by peer
```

---

#### Preguntas de Verificación — Ejercicio 1
1. **P1.1:** ¿Por qué la petición HTTP de `legacy-client` recibió `Connection reset by peer` en lugar de un código de estado HTTP `403 Forbidden`?
2. **P1.2:** Si el modo de `PeerAuthentication` se cambia a `PERMISSIVE`, ¿qué exposición de seguridad se introduce en la red del cluster?

---

### Ejercicio 2: Implementación de Microsegmentación L7 Zero Trust con Identificadores SPIFFE

#### Objetivo
Implementar una postura de seguridad explícita de Default Deny seguida de reglas finas de `AuthorizationPolicy` que apliquen la validación del método HTTP y del Subject Alternative Name (SAN) de SPIFFE.

#### Paso 1: Desplegar Clientes Autorizados y No Autorizados dentro del Mesh

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authorized-sa
  namespace: mesh-secure
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authorized-client
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: authorized-client
  template:
    metadata:
      labels:
        app: authorized-client
    spec:
      serviceAccountName: authorized-sa
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: unauthorized-sa
  namespace: mesh-secure
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unauthorized-client
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unauthorized-client
  template:
    metadata:
      labels:
        app: unauthorized-client
    spec:
      serviceAccountName: unauthorized-sa
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF
```

#### Paso 2: Implementar la Política de Autorización Global Default Deny
Construí una `AuthorizationPolicy` general con un `spec` vacío para aplicar Zero Trust denegando todas las peticiones entrantes en `mesh-secure`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: mesh-secure
spec:
  {}
```

Aplicá el manifiesto:
```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: mesh-secure
spec:
  {}
EOF
```

#### Paso 3: Implementar la Política de Autorización L7 de Menor Privilegio
Definí una `AuthorizationPolicy` que permita **únicamente** peticiones originadas desde la identidad SPIFFE `spiffe://cluster.local/ns/mesh-secure/sa/authorized-sa` enviando peticiones HTTP `GET` a la ruta `/` en `backend-api`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-backend-api-l7
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: backend-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/authorized-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/"]
```

Aplicá el manifiesto:
```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-backend-api-l7
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: backend-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/authorized-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/"]
EOF
```

#### Paso 4: Validar el Comportamiento de Acceso entre Workloads

1. **Probar desde la ServiceAccount Autorizada (`authorized-sa`):**
```bash
AUTH_POD=$(kubectl get pod -n mesh-secure -l app=authorized-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mesh-secure "$AUTH_POD" -c curl -- curl -i -s http://backend-api:8080/
```
Salida esperada:
```http
HTTP/1.1 200 OK
date: Fri, 07 Aug 2026 20:30:00 GMT
content-length: 18
content-type: text/plain; charset=utf-8
x-envoy-upstream-service-time: 1

secure-payload-v1
```

2. **Probar Método No Autorizado (`POST`) desde la ServiceAccount Autorizada:**
```bash
kubectl exec -n mesh-secure "$AUTH_POD" -c curl -- curl -i -s -X POST http://backend-api:8080/
```
Salida esperada:
```http
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:30:05 GMT
server: envoy

RBAC: access denied
```

3. **Probar desde la ServiceAccount No Autorizada (`unauthorized-sa`):**
```bash
UNAUTH_POD=$(kubectl get pod -n mesh-secure -l app=unauthorized-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mesh-secure "$UNAUTH_POD" -c curl -- curl -i -s http://backend-api:8080/
```
Salida esperada:
```http
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:30:10 GMT
server: envoy

RBAC: access denied
```

---

#### Preguntas de Verificación — Ejercicio 2
1. **P2.1:** ¿En qué capa de la pila OSI/TCP-IP se evalúa la decisión de autorización para la petición `#2` (HTTP `POST` no autorizado desde `authorized-sa`) en comparación con la petición `#3` desde `unauthorized-sa`?
2. **P2.2:** En el patrón de principal `cluster.local/ns/mesh-secure/sa/authorized-sa`, ¿qué componente garantiza que un pod malicioso no pueda suplantar esta cadena de principal?

---

### Ejercicio 3: Diagnóstico Avanzado, Extracción de Certificados SPIFFE y Auditoría de Seguridad de Envoy

#### Objetivo
Utilizar herramientas de diagnóstico (`istioctl`, `openssl` e interfaces administrativas locales de Envoy) para inspeccionar certificados X.509 SVID activos, extraer campos SAN y auditar cadenas de filtros de autorización dinámica en memoria.

#### Paso 1: Extraer el Certificado X.509 SVID Activo de la Memoria de Envoy
Ejecutá `istioctl proxy-config secret` para extraer los certificados activos cargados dentro del sidecar proxy del pod `backend-api`.

```bash
BACKEND_POD=$(kubectl get pod -n mesh-secure -l app=backend-api -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret "$BACKEND_POD".mesh-secure -o json > cert_dump.json
```

Filtrá y decodificá la cadena de certificados `default` activa utilizando `jq` y `openssl`:

```bash
jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' cert_dump.json | base64 -d | openssl x509 -noout -text -certopt no_header,no_version,no_serial,no_signame,no_validity,no_issuer,no_pubkey,no_sigdump
```

Fragmento de Salida Esperada:
```text
        Attributes:
            Requested Extensions:
                X509v3 Subject Alternative Name: critical
                    URI:spiffe://cluster.local/ns/mesh-secure/sa/backend-sa
                X509v3 Basic Constraints: critical
                    CA:FALSE
                X509v3 Key Usage: critical
                    Digital Signature, Key Encipherment
                X509v3 Extended Key Usage: 
                    TLS Web Server Authentication, TLS Web Client Authentication
```

#### Paso 2: Auditar Filtros de Listener Dinámicos y Aplicaciones de RBAC
Consultá el estado de configuración interna de Envoy utilizando `istioctl proxy-config listener` para inspeccionar las cadenas de seguridad entrantes dinámicas vinculadas al puerto `15006` (virtual listener entrante de Envoy).

```bash
istioctl proxy-config listener "$BACKEND_POD".mesh-secure --port 15006 -o json
```

Inspeccioná la salida para confirmar la presencia de `envoy.filters.network.rbac` y `envoy.filters.http.rbac` en las cadenas de filtros:

```json
[
    {
        "name": "virtualInbound",
        "address": {
            "socketAddress": {
                "address": "0.0.0.0",
                "portValue": 15006
            }
        },
        "filterChains": [
            {
                "filterChainMatch": {
                    "destinationPort": 8080,
                    "transportProtocol": "tls"
                },
                "filters": [
                    {
                        "name": "envoy.filters.network.http_connection_manager",
                        "typedConfig": {
                            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                            "httpFilters": [
                                {
                                    "name": "envoy.filters.http.rbac",
                                    "typedConfig": {
                                        "@type": "type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC"
                                    }
                                }
                            ]
                        }
                    }
                ]
            }
        ]
    }
]
```

#### Paso 3: Inspección Directa del Endpoint de Admin de Envoy vía Port-Forwarding
Exponé el endpoint administrativo de Envoy directamente para inspeccionar las métricas del motor de RBAC:

```bash
kubectl port-forward -n mesh-secure "$BACKEND_POD" 15000:15000 &
PF_PID=$!
sleep 2

curl -s http://127.0.0.1:15000/stats | grep "http.inbound_15006_8080.rbac"
kill $PF_PID
```

Salida esperada:
```text
http.inbound_15006_8080.rbac.allowed: 1
http.inbound_15006_8080.rbac.denied: 2
http.inbound_15006_8080.rbac.shadow_allowed: 0
http.inbound_15006_8080.rbac.shadow_denied: 0
```

---

#### Preguntas de Verificación — Ejercicio 3
1. **P3.1:** ¿Qué extensiones críticas de X.509 deben marcarse como `critical` en un certificado SPIFFE SVID válido según la especificación de SPIFFE?
2. **P3.2:** ¿Cómo puede un ingeniero diferenciar entre una petición descartada debido a un fallo en el handshake mTLS y una petición descartada por una `AuthorizationPolicy` utilizando métricas administrativas de Envoy?

---

## 3. Clave de Respuestas y Autoevaluación

<details>
<summary>Clic para desplegar la Clave de Respuestas y Explicaciones Técnicas</summary>

### Respuestas del Ejercicio 1

- **Respuesta a P1.1:**  
  Cuando `PeerAuthentication` está configurado con `mode: STRICT`, la aplicación de mTLS ocurre en la **Capa 4 (handshake TCP/TLS)** mediante el filtro de red de Envoy (`envoy.filters.network.metadata_exchange` / TLS Inspector). Dado que el cliente fuera del mesh no inicia un handshake TLS con un certificado de cliente válido confiado por la CA del Mesh, Envoy cierra inmediatamente el socket TCP a través de un paquete `TCP RST`. Nunca llega a la canalización de procesamiento HTTP de Capa 7, por lo que no se pueden generar códigos de respuesta HTTP (tales como `403 Forbidden`).

- **Respuesta a P1.2:**  
  El modo `PERMISSIVE` instruye al sidecar proxy a abrir listeners duales o inspeccionar dinámicamente los bytes entrantes iniciales en el socket (ALPN sniffing). Si un cliente inicia HTTP en texto plano, Envoy lo permite; si inicia mTLS, Envoy termina TLS.  
  *Riesgo de Seguridad:* Un atacante que obtenga acceso a la red del pod (o evada los firewalls perimetrales) puede ejecutar ataques de movimiento lateral en texto plano, realizar capturas de paquetes man-in-the-middle o suplantar tráfico no autenticado directamente hacia workloads integrados en el mesh sin presentar un SPIFFE SVID criptográfico válido.

---

### Respuestas del Ejercicio 2

- **Respuesta a P2.1:**  
  - **Petición #3 (SA No Autorizada):** Evaluada a **nivel de Verificación de Identidad de Capa 4/7**. El certificado mTLS del cliente presenta `spiffe://cluster.local/ns/mesh-secure/sa/unauthorized-sa`. El filtro RBAC HTTP de Envoy (`envoy.filters.http.rbac`) compara esta cadena de SAN SPIFFE contra los `principals` permitidos. Al no encontrar coincidencia, devuelve una respuesta HTTP `403 Forbidden`.
  - **Petición #2 (Método HTTP POST No Autorizado desde SA Autorizada):** Evaluada a **nivel de Protocolo de Aplicación de Capa 7**. La identidad coincide con `authorized-sa`, pero los metadatos operativos (`method: POST`) fallan en el motor de coincidencia `operation.methods`. El filtro RBAC HTTP rechaza la petición con HTTP `403 Forbidden`.

- **Respuesta a P2.2:**  
  La integridad criptográfica del principal SAN SPIFFE está garantizada por la **Entidad Certificadora del Control Plane (`istiod` / SPIRE Server)** y el **Protocolo de Handshake TLS**.  
  Durante el handshake mTLS:
  1. El sidecar del servidor verifica que el certificado X.509 del cliente fue firmado por la clave de la CA Raíz de confianza del Mesh.
  2. El sidecar del servidor verifica la validez del certificado (expiración, revocación).
  3. La extensión SAN `URI:spiffe://...` está vinculada criptográficamente al par de claves pública/privada poseído exclusivamente por el proxy de ese cliente (el cual recibe su clave privada a través de Unix Domain Sockets privados sobre Secret Discovery Service - SDS). La clave privada nunca abandona la memoria del pod.

---

### Respuestas del Ejercicio 3

- **Respuesta a P3.1:**  
  Según la especificación de SPIFFE X.509 SVID:
  - **Subject Alternative Name (SAN):** Debe estar presente y **DEBE** contener exactamente una entrada URI que represente el SPIFFE ID (por ejemplo, `spiffe://<domain>/ns/<namespace>/sa/<serviceaccount>`).
  - **Basic Constraints:** Debe estar marcada como `critical` con `CA:FALSE` para los certificados de workload, con el fin de evitar que proxies de workload comprometidos reemitan certificados subordinados a atacantes aguas abajo.
  - **Key Usage:** Debe estar marcada como `critical` con `Digital Signature` (y opcionalmente `Key Encipherment`).

- **Respuesta a P3.2:**  
  - **Fallos en el Handshake mTLS (L4):** Se registran en las métricas SSL de Envoy como `ssl.connection_error`, `ssl.handshake_failed` o `listener.downstream_cx_destroy` antes del procesamiento HTTP.
  - **Violaciones de Authorization Policy (L7):** Incrementan contadores de filtros RBAC específicos, nombrados explícitamente `http.inbound_<listener_id>.rbac.denied`. Además, las violaciones de RBAC generan entradas de registro de acceso (access log) con el flag de respuesta `FI` (AccessDenied por filtro descendente) o `RL` (Rate limited/RBAC denied) junto con el estado HTTP `403`.

</details>