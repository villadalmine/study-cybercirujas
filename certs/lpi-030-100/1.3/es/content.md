# LPI-030-100: Web Development Essentials (v1.0)
## Topic 1.3: HTTP Basics (Weight: 7.5) — Advanced SRE & Platform Architecture Guide

---

### 1. Motivación en Producción y Planteamiento del Problema Arquitectónico

El Protocolo de Transferencia de Hipertexto (HTTP) es la base de la capa de aplicación de la web distribuida moderna. Arquitectónicamente, HTTP está diseñado como un **protocolo de solicitud-respuesta sin estado** (stateless request-response protocol) que opera sobre capas de transporte modernas (TCP/IP y UDP/QUIC). 

En entornos de producción empresariales, la Ingeniería de Confiabilidad del Sitio (Site Reliability Engineering, SRE) y la Arquitectura de Plataforma modernas están definidas por cómo se meida, escala, asegura y optimiza HTTP a través de microservicios, edge proxies y Redes de Distribución de Contenido (CDNs).

```
+-----------------------------------------------------------------------------------+
|                                  CLIENT LAYER                                     |
|                      (Browsers, Mobile Apps, Microservices)                       |
+-----------------------------------------------------------------------------------+
                                         |
                                         | HTTP/2 or HTTP/3 over TLS 1.3
                                         v
+-----------------------------------------------------------------------------------+
|                                EDGE / INGRESS LAYER                               |
|       (Cloudflare / NGINX / Envoy / Kubernetes Ingress Controller)                |
|                                                                                   |
|  - TLS Termination & ALPN Negotiation                                             |
|  - CORS Enforcement & Security Headers                                            |
|  - Cache Invalidation & Edge Revalidation (ETag, Cache-Control)                   |
|  - Connection Pooling & HTTP Keep-Alive Translation                               |
+-----------------------------------------------------------------------------------+
                                         |
                                         | HTTP/1.1 Pool (gRPC / HTTP/2 optional)
                                         v
+-----------------------------------------------------------------------------------+
|                               BACKEND SERVICES                                    |
|                      (Stateless Microservice Pods)                                |
|                                                                                   |
|  - Dynamic Rendering / REST / GraphQL APIs                                        |
|  - Session Token Validation (JWT / Redis Cookie Sessions)                         |
+-----------------------------------------------------------------------------------+
```

#### 1.1 El Paradigma Stateless vs. Las Necesidades de Aplicaciones Stateful
HTTP es intencionalmente sin estado (stateless): cada transacción de solicitud-respuesta se trata de forma aislada. Sin embargo, las cargas de trabajo del mundo real (por ejemplo, autenticación de usuarios, carritos de compras, procesamiento transaccional) requieren un contexto persistente. 

Para cerrar esta brecha arquitectónica sin introducir un acoplamiento con estado (stateful) en la capa del servidor, los sistemas dependen de patrones de estado externalizado:
* **Propagación de Cookies en el Lado del Cliente:** Estandarizada mediante el RFC 6265, los servidores pasan directivas set-cookie que instruyen a los clientes a enviar identificadores de sesión opacos o claims autocontenidos de regreso con las solicitudes subsiguientes.
* **Almacenes de Sesión Distribuidos:** Los microservicios consultan almacenes de clave-valor centralizados y de alta disponibilidad (por ejemplo, Redis Cluster) utilizando tokens de sesión para resolver el estado sin violar la elasticidad horizontal de los microservicios.

#### 1.2 Mecánica de la Capa de Transporte: Ciclo de Vida de la Conexión TCP y Sobrecarga de Keep-Alive
En la capa de red, iniciar una solicitud HTTP/1.0 no optimizada requiere un TCP 3-Way Handshake estándar (`SYN` -> `SYN-ACK` -> `ACK`), seguido de un handshake TLS 1.3 (1 RTT), la transmisión real de la solicitud/respuesta HTTP, y el cierre de TCP (`FIN` -> `ACK`).

```
Client                                  Server
  |------------------ SYN ----------------->|  \
  |<--------------- SYN-ACK ----------------|   |-- TCP 3-Way Handshake (1 RTT)
  |------------------ ACK ----------------->|  /
  |---------------- ClientHello ------------>|  \
  |<-- ServerHello, Certificate, Finished --|   |-- TLS 1.3 Handshake (1 RTT)
  |---------------- Finished --------------->|  /
  |------------- HTTP GET Request --------->|  \
  |<------------ HTTP 200 OK Response ------|   |-- Application Data (1 RTT)
  |------------------ FIN ----------------->|  \
  |<----------------- ACK ------------------|   |-- Connection Teardown
```

Sin la reutilización de conexiones, un endpoint de alto rendimiento que procesa $10,000\text{ req/sec}$ agotará los puertos efímeros locales (`ip_local_port_range`), llevando a los sockets al estado `TIME_WAIT`, lo que resulta en la inanición de sockets a nivel de kernel y una latencia elevada.

**HTTP Keep-Alive (Conexiones Persistentes)** mitiga esto manteniendo un socket TCP abierto a través de múltiples solicitudes HTTP, eliminando la latencia de re-handshake y reduciendo la sobrecarga de CPU en los edge proxies.

#### 1.3 Bloqueo de Cabeza de Línea (Head-of-Line, HoL) y Evolución del Protocolo
* **Bloqueo HoL en HTTP/1.1:** Aunque HTTP/1.1 introdujo Keep-Alive y pipelining, las solicitudes a través de una sola conexión TCP deben completarse strictly de forma secuencial. Una consulta lenta en el backend que procese la Solicitud #1 bloquea la entrega de la Solicitud #2 y #3 en el mismo tubo TCP.
* **Multiplexación en HTTP/2:** HTTP/2 introduce una capa de entramado binario (binary framing layer) que divide los mensajes en tramas independientes mapeadas a streams. Múltiples solicitudes y respuestas se entretejen de forma concurrente sobre un solo socket TCP.
* **HTTP/3 (QUIC):** Resuelve el **bloqueo HoL a nivel de TCP**. En HTTP/2, si se pierde un solo paquete TCP, el kernel del sistema operativo detiene todos los streams en ese socket hasta que el paquete se retransmita. HTTP/3 reemplaza TCP por QUIC sobre UDP, garantizando que la pérdida de paquetes en el Stream A no detenga la entrega independiente de datos en el Stream B.

---

### 2. Análisis Técnico Profundo y Matriz de Balances (Trade-Offs)

#### Tabla 2.1: Comparación de la Arquitectura de Protocolos

| Atributo Arquitectónico | HTTP/1.1 (RFC 9112) | HTTP/2 (RFC 9113) | HTTP/3 (RFC 9114) |
| :--- | :--- | :--- | :--- |
| **Protocolo de Transporte** | TCP | TCP | UDP (vía QUIC) |
| **Formato de Entramado** | Texto Plano / ASCII | Capa de Entramado Binario (Binary Framing Layer) | Capa de Entramado Binario (Binary Framing Layer) |
| **Multiplexación** | No (Secuencial por socket; Pipelining roto en la práctica) | Sí (Multiplexación en la capa de aplicación sobre 1 conexión TCP) | Sí (Multiplexación nativa sobre streams QUIC independientes) |
| **Bloqueo Head-of-Line** | Nivel de Aplicación y Transporte | Nivel de Transporte Solamente (La pérdida de TCP bloquea todos los streams) | Resuelto (Entrega de tramas por stream) |
| **Compresión de Encabezados** | Ninguna (Encabezados ASCII puros) | HPACK (Tablas Estáticas/Dinámicas + Huffman) | QPACK (Decodificación de encabezados de stream fuera de orden) |
| **Integración TLS** | Opcional (TLS 1.2 / 1.3 vía SNI) | Obligatoria en la práctica (Negociación ALPN `h2`) | Totalmente Integrada (TLS 1.3 embebido en la carga útil de QUIC) |
| **Migración de Conexión** | No (Vinculada a la tupla de 4 IP/Puerto) | No (Vinculada a la tupla de 4 IP/Puerto) | Sí (El Connection ID persiste a través de cambios de red IP) |

#### Tabla 2.2: Semántica de Métodos HTTP (RFC 9110)

| Método | Seguro | Idempotente | Cuerpo de Solicitud Permitido | Cacheable | Caso de Uso Principal en Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `GET` | **Sí** | **Sí** | No (No definido por el RFC) | **Sí** | Obtención de estado sin mutación. Cadenas de consulta (Query strings) en la URI. |
| `HEAD` | **Sí** | **Sí** | No | **Sí** | Health checks, verificación de frescura de caché a través de encabezados de respuesta sin descarga del cuerpo. |
| `POST` | No | No | **Sí** | Excepcionalmente | Creación de recursos no idempotentes, envío de cargas de formularios, ejecución de acciones. |
| `PUT` | No | **Sí** | **Sí** | No | Reemplazo completo del estado de un recurso objetivo en una URI conocida. |
| `DELETE` | No | **Sí** | Opcional | No | Eliminación del estado del recurso objetivo en una URI especificada. |
| `OPTIONS`| **Sí** | **Sí** | No | No | Solicitudes CORS Preflight para consultar las capacidades de un servidor de distinto origen (cross-origin). |
| `PATCH` | No | No | **Sí** | No | Aplicación de modificaciones parciales a un recurso (RFC 5789). |

#### Tabla 2.3: Mecánica de Caché HTTP y Revalidación

| Directiva de Caché / Encabezado | Tipo | Alcance | Descripción de Comportamiento | Trade-off de SRE en Producción |
| :--- | :--- | :--- | :--- | :--- |
| `Cache-Control: public, max-age=3600` | Respuesta | Cliente y CDNs | La respuesta se puede almacenar en caché por cualquier nodo intermedio hasta por 3600 segundos. | Reduce significativamente la carga en el origen; arriesga servir datos obsoletos durante despliegues de emergencia. |
| `Cache-Control: private, no-cache` | Respuesta | Solo Navegador | El cliente puede almacenar en caché, pero **debe revalidar** con el origen vía `ETag`/`If-None-Match` antes de su uso. | Garantiza la frescura en cada hit mientras reduce el ancho de banda a través de `304 Not Modified`. |
| `Cache-Control: no-store` | Respuesta | Todas las Cachés | Almacenamiento en caché prohibido. No se permite escritura en memoria o almacenamiento. | Obligatorio para cargas sensibles de PII/Financieras; aumenta la carga en los servidores de origen. |
| `ETag: "v104-abc"` | Encabezado | Validación | Hash validador fuerte de entidad generado por el origen según el contenido del archivo. | Alto costo de CPU para hashing dinámico, pero ahorra ancho de banda de red saliente vía `GET` condicional. |
| `Vary: Accept-Encoding, User-Agent` | Respuesta | CDNs / Proxies | Indica a las cachés que generen claves de entrada basadas en encabezados específicos junto con la URI. | Evita enviar contenido comprimido en gzip a clientes no compatibles; fragmenta las claves de caché, reduciendo el hit ratio. |

#### Tabla 2.4: Arquitectura de Gestión de Estado y Sesión

| Dimensión | Sesión Basada en Cookies (Stateful) | Bearer JWT Token (Stateless) |
| :--- | :--- | :--- |
| **Ubicación de Almacenamiento** | Browser Cookie Store / Capa de Servidores Redis | `LocalStorage` del navegador, `SessionStorage` o Memoria |
| **Atributos de Seguridad** | `HttpOnly`, `Secure`, `SameSite=Strict/Lax/None` | Adjuntado manualmente en `Authorization: Bearer <token>` |
| **Vulnerabilidad CSRF** | **Alta** (El navegador adjunta las cookies automáticamente; requiere tokens CSRF) | **Baja** (Los encabezados no se adjuntan automáticamente por solicitudes cross-origin del navegador) |
| **Vulnerabilidad XSS** | **Mitigada** si el flag `HttpOnly` previene el acceso desde JS (`document.cookie`) | **Alta** si se almacena en `LocalStorage` (Accesible a través de scripts de XSS maliciosos) |
| **Velocidad de Revocación** | **Instantánea** (Eliminar clave en el cluster de Redis) | **Difícil** (Debe esperar la expiración del token o consultar una lista negra de revocación distribuida) |

---

### 3. Infraestructura de Producción y Manifiestos

#### 3.1 Configuración Completa de NGINX Reverse Proxy para Producción (`nginx-edge-proxy.conf`)
La siguiente configuración implementa ajuste de parámetros HTTP de grado de producción, agrupamiento de conexiones (connection pooling) Keep-Alive, terminación HTTP/2, manejo de CORS, encabezados de seguridad estrictos y reglas de revalidación de caché.

```nginx
# /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Performance Optimizations
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    types_hash_max_size 2048;
    server_tokens   off;

    # Timeouts & Connection Tuning
    keepalive_timeout  65;
    keepalive_requests 10000;
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;

    # Upstream Pool with Keep-Alive to Backend Microservices
    upstream backend_api_cluster {
        server 10.244.1.45:8080 max_fails=3 fail_timeout=10s;
        server 10.244.2.89:8080 max_fails=3 fail_timeout=10s;
        
        # Maintain a persistent pool of idle Keep-Alive connections to backends
        keepalive 64;
    }

    # Microservice Edge Server Block
    server {
        listen 443 ssl http2;
        server_name api.production.internal;

        ssl_certificate /etc/ssl/certs/api_production.crt;
        ssl_certificate_key /etc/ssl/private/api_production.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        # Global Security Headers
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self';" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

        # Static Asset Caching Endpoint
        location /static/ {
            root /var/www/assets;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # API Dynamic Routing Endpoint
        location /api/v1/ {
            # CORS Preflight Handling
            if ($request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' 'https://dashboard.production.internal' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
                add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, Origin, X-Requested-With' always;
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Type' 'text/plain; charset=utf-8';
                add_header 'Content-Length' 0;
                return 204;
            }

            add_header 'Access-Control-Allow-Origin' 'https://dashboard.production.internal' always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;

            # HTTP Proxy Translation Controls
            proxy_pass http://backend_api_cluster;
            proxy_http_version 1.1;
            
            # Clear Connection header to enable upstream Keep-Alive socket reuse
            proxy_set_header Connection "";
            
            # Forward Original HTTP Headers to Upstream Context
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Buffer Configurations for High Throughput
            proxy_buffering on;
            proxy_buffer_size 8k;
            proxy_buffers 8 64k;
            proxy_busy_buffers_size 128k;

            # Upstream Timeout Definitions
            proxy_connect_timeout 3s;
            proxy_read_timeout 15s;
            proxy_send_timeout 15s;
        }
    }
}
```

#### 3.2 Manifiesto Completo de Kubernetes NGINX Ingress y Deployment (`k8s-ingress-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-api-backend
  namespace: production
  labels:
    app.kubernetes.io/name: http-api-backend
    app.kubernetes.io/part-of: core-platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app: http-api-backend
  template:
    metadata:
      labels:
        app: http-api-backend
    spec:
      containers:
      - name: api-container
        image: registry.production.internal/platform/api:v2.4.1
        ports:
        - name: http-port
          containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /healthz
            port: http-port
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 2
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: http-port
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: http-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: http-api-backend
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: http-port
    protocol: TCP
    name: http
  selector:
    app: http-api-backend
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: http-api-ingress
  namespace: production
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "5"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://dashboard.production.internal"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Service-ID: core-api-v2";
      more_set_headers "Cache-Control: no-cache, private";
spec:
  tls:
  - hosts:
    - api.production.internal
    secretName: api-production-tls-secret
  rules:
  - host: api.production.internal
    http:
      paths:
      - path: /api/v1
        pathType: Prefix
        backend:
          service:
            name: http-api-service
            port:
              number: 80
```

---

### 4. Comandos CLI Reales y Salidas de Terminal Sin Procesar

#### 4.1 Escenario 1: Inspección Detallada (Verbose) de Solicitud HTTP/1.1 (`curl`)
Ejecutando una inspección de carga útil `POST` autenticada con encabezados personalizados:

```bash
$ curl -i -v -X POST "https://api.production.internal/api/v1/resource" \
  -H "Host: api.production.internal" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" \
  -d '{"resource_name":"k8s-cluster-01","environment":"production"}'
```

```http
*   Trying 192.168.1.100:443...
* Connected to api.production.internal (192.168.1.100) port 443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN, server accepted to use http/1.1
* Server certificate:
*  subject: CN=api.production.internal
*  start date: Aug 01 00:00:00 2026 GMT
*  expire date: Nov 01 00:00:00 2026 GMT
*  issuer: C=US; O=Let's Encrypt; CN=R3

> POST /api/v1/resource HTTP/1.1
> Host: api.production.internal
> User-Agent: curl/7.88.1
> Content-Type: application/json
> Accept: application/json
> Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
> Content-Length: 61
> 

< HTTP/1.1 201 Created
< Server: nginx
< Date: Thu, 06 Aug 2026 18:50:00 GMT
< Content-Type: application/json; charset=utf-8
< Content-Length: 118
< Connection: keep-alive
< ETag: W/"76-a1b2c3d4e5"
< Cache-Control: no-cache, private
< X-Content-Type-Options: nosniff
< X-Frame-Options: DENY
< Access-Control-Allow-Origin: https://dashboard.production.internal
< Access-Control-Allow-Credentials: true
< Set-Cookie: __Host-SessionId=s%3A987654321; Path=/; Secure; HttpOnly; SameSite=Strict
< 
{
  "status": "success",
  "data": {
    "id": "res-99482",
    "resource_name": "k8s-cluster-01",
    "environment": "production"
  }
}
* Connection #0 to host api.production.internal left intact
```

#### 4.2 Escenario 2: Negociación de Protocolo TLS ALPN vía `openssl`
Verificando si un edge proxy soporta HTTP/2 (`h2`) a través de la Negociación de Protocolo en la Capa de Aplicación (ALPN):

```bash
$ openssl s_client -connect api.production.internal:443 -alpn h2 -servername api.production.internal < /dev/null
```

```text
CONNECTED(00000003)
depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
verify return:1
depth=1 C = US, O = Let's Encrypt, CN = R3
verify return:1
depth=0 CN = api.production.internal
verify return:1
---
Certificate chain
 0 s:CN = api.production.internal
   i:C = US, O = Let's Encrypt, CN = R3
   a:PKEY: rsaEncryption, 2048 (bits); conds: pkcs1 cryptographic
---
Server certificate
-----BEGIN CERTIFICATE-----
MIIFdTCCBG2gAwIBAgISA17xR8kL4A234...
-----END CERTIFICATE-----
subject=CN = api.production.internal
issuer=C = US, O = Let's Encrypt, CN = R3
---
No client certificate CA names sent
Peer signing digest: SHA256
Peer signature type: RSA-PSS
Server Temp Key: X25519, 253 bits
---
SSL handshake has read 3450 bytes and written 392 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
ALPN protocol: h2
Early data was not sent
Verify return code: 0 (ok)
---
DONE
```

#### 4.3 Escenario 3: Captura de Paquetes en Tiempo Real vía `tshark`
Filtrando códigos de estado y encabezados HTTP en la capa de la interfaz de red:

```bash
$ sudo tshark -i eth0 -n -Y "http.request or http.response" \
  -T fields -e frame.time_relative -e ip.src -e ip.dst -e http.request.method \
  -e http.request.uri -e http.response.status_code -e http.response.phrase
```

```text
0.000000000 10.244.0.5 -> 10.244.1.45 GET /api/v1/healthz  
0.001243110 10.244.1.45 -> 10.244.0.5   200 OK
4.120485922 10.244.0.12 -> 10.244.1.45 POST /api/v1/checkout  
4.482019481 10.244.1.45 -> 10.244.0.12   504 Gateway Timeout
8.910243102 10.244.0.18 -> 10.244.1.45 OPTIONS /api/v1/user  
8.910948192 10.244.1.45 -> 10.244.0.18   204 No Content
```

---

### 5. Guía de Verificación, Diagnóstico de Fallas y Troubleshooting para SRE

```
                        HTTP INCIDENT DIAGNOSTIC FLOW
                                      |
                           [Check HTTP Status Code]
                                      |
         +----------------------------+----------------------------+
         |                                                         |
     [5xx Series]                                              [4xx Series]
         |                                                         |
   +-----+-----+                                             +-----+-----+
   |           |                                             |           |
[502 Bad    [504 Gateway                                 [403/CORS]   [429 Rate
Gateway]     Timeout]                                        |         Limited]
   |           |                                             |           |
 Check       Check Upstream                            Check Missing   Check Token
Upstream     Read Timeout                              Headers & OPTIONS Bucket / Redis
 Process     or DB Lock                                 Preflight       Limits
 Alive       Exhaustion
```

#### 5.1 Matriz de Troubleshooting para Incidentes Comunes en Producción

##### Caso 1: `502 Bad Gateway` vs. `504 Gateway Timeout`
* **Causa Raíz (502 Bad Gateway):** El edge proxy recibió un segmento explícito `RST` (TCP Reset) o `FIN` desde el servicio de aplicación upstream mientras intentaba conectarse. El proceso se cayó, los hilos de trabajo (worker threads) se colgaron o la cola del socket backlog estaba llena.
* **Causa Raíz (504 Gateway Timeout):** El edge proxy estableció con éxito una conexión por socket TCP con el upstream, pero el upstream no envió una carga útil de respuesta HTTP dentro del `proxy_read_timeout` (por ejemplo, consulta a la base de datos de larga duración, interbloqueo de hilos no controlado).
* **Flujo de Trabajo de Diagnóstico:**
  1. Inspeccionar los logs de error del proxy (`/var/log/nginx/error.log`):
     * *Firma de 502:* `connect() failed (111: Connection refused) while connecting to upstream`
     * *Firma de 504:* `upstream timed out (110: Connection timed out) while reading response header from upstream`
  2. Verificar el listener del socket del contenedor del backend:
     ```bash
     $ kubectl logs deployment/http-api-backend -n production --tail=100
     $ nc -zv 10.244.1.45 8080
     ```

##### Caso 2: Bloqueo de Compartición de Recursos de Origen Cruzado (CORS)
* **Síntoma:** El navegador bloquea la ejecución de JavaScript en el lado del cliente al procesar datos de respuesta con el error: `Access to fetch at 'https://api.production.internal' from origin 'https://dashboard.production.internal' has been blocked by CORS policy`.
* **Causa Raíz:** 
  1. Ausencia de `Access-Control-Allow-Origin` que coincida con el origen del cliente.
  2. Fallo en la llamada de preflight OPTIONS debido a que el backend retorna un código de estado distinto de 2xx en el preflight.
  3. Intento de enviar credenciales (encabezado `Cookie`/`Authorization`) cuando `Access-Control-Allow-Credentials` es `false` o `Access-Control-Allow-Origin` está configurado con comodín `*`.
* **Flujo de Trabajo de Diagnóstico:**
  Ejecutar prueba manual de preflight OPTIONS con curl:
  ```bash
  $ curl -i -X OPTIONS "https://api.production.internal/api/v1/resource" \
    -H "Origin: https://dashboard.production.internal" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Authorization, Content-Type"
  ```
  *Expectativa:* Estado HTTP `204 No Content` o `200 OK` con encabezados CORS válidos.

##### Caso 3: Envenenamiento de Caché (Cache Poisoning) y Contaminación de Datos Obsoletos
* **Síntoma:** Los clientes ven estados en caché incorrectos a través de sesiones de usuario después de un despliegue.
* **Causa Raíz:** El origen omitió el encabezado `Vary: Cookie` o `Vary: Authorization` mientras retornaba una respuesta cacheable (`Cache-Control: public`). Las CDNs intermedias agregaron cargas útiles de respuesta a través de múltiples usuarios utilizando la URI como única clave de caché.
* **Flujo de Trabajo de Diagnóstico:**
  1. Inspeccionar los encabezados de respuesta usando `curl -I`:
     ```bash
     $ curl -I -H "Authorization: Bearer token-A" https://api.production.internal/api/v1/user/profile
     ```
  2. Verificar la presencia del encabezado `Vary` y los alcances correctos de `Cache-Control`:
     ```http
     HTTP/1.1 200 OK
     Cache-Control: private, no-cache
     Vary: Authorization, Accept-Encoding
     ```

##### Caso 4: Pérdida de Cookie / Pérdida de Sesión a Través de Subdominios
* **Síntoma:** El navegador pierde el estado de la sesión de autenticación al navegar entre `app.production.internal` y `api.production.internal`.
* **Causa Raíz:**
  1. El atributo `Domain` de la cookie se configuró explícitamente como `app.production.internal` en lugar del comodín padre `.production.internal`.
  2. Cookie configurada con `SameSite=Strict`, lo que previene la propagación del estado de navegación de nivel superior a través de subdominios.
  3. Ausencia del atributo `Secure` al operar bajo HTTPS, provocando que los navegadores modernos rechacen `Set-Cookie`.
* **Flujo de Trabajo de Diagnóstico:**
  Inspeccionar los atributos del encabezado set-cookie en bruto:
  ```bash
  $ curl -i https://api.production.internal/api/v1/login | grep -i "set-cookie"
  ```
  *Resultado Correcto:*
  ```http
  Set-Cookie: session_token=xyz123; Domain=.production.internal; Path=/; Secure; HttpOnly; SameSite=Lax
  ```

---

### 6. Referencias

1. **Sitio Oficial de Linux Professional Institute (LPI)**
   [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
2. **IETF RFC 9110: HTTP Semantics (Estandarizado en Junio de 2022)**
   [https://www.rfc-editor.org/rfc/rfc9110.html](https://www.rfc-editor.org/rfc/rfc9110.html)
3. **IETF RFC 9111: HTTP Caching**
   [https://www.rfc-editor.org/rfc/rfc9111.html](https://www.rfc-editor.org/rfc/rfc9111.html)
4. **IETF RFC 9112: HTTP/1.1 Protocol Specifications**
   [https://www.rfc-editor.org/rfc/rfc9112.html](https://www.rfc-editor.org/rfc/rfc9112.html)
5. **IETF RFC 9113: HTTP/2 Specification**
   [https://www.rfc-editor.org/rfc/rfc9113.html](https://www.rfc-editor.org/rfc/rfc9113.html)
6. **IETF RFC 9114: HTTP/3 Protocol Specification**
   [https://www.rfc-editor.org/rfc/rfc9114.html](https://www.rfc-editor.org/rfc/rfc9114.html)
7. **MDN Web Docs: HTTP Protocols and Headers**
   [https://developer.mozilla.org/en-US/docs/Web/HTTP](https://developer.mozilla.org/en-US/docs/Web/HTTP)
8. **Documentación de Arquitectura y Ajuste del Núcleo de NGINX**
   [https://nginx.org/en/docs/](https://nginx.org/en/docs/)