# Tema 1.2: Arquitectura de Aplicaciones Web — Guía de Estudio para Producción

**Examen Objetivo:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Tema:** 1.2 Arquitectura de Aplicaciones Web  
**Peso:** 5  
**Nivel de Audiencia:** Principal Platform Architect / Senior SRE  

---

## 1. Arquitectura y Motivación Técnica

### 1.1 El Problema Arquitectónico en Producción
Las arquitecturas modernas de aplicaciones web existen para resolver un problema fundamental de producción: **cómo mantener alta disponibilidad, baja latencia y escalabilidad operacional bajo cargas de trabajo dinámicas e imprevistas, garantizando al mismo tiempo la consistencia de datos y la resiliencia del sistema.**

Una arquitectura simple de servidor único (naive single-server architecture) combina el servidor web estático, el runtime de la aplicación dinámica, la base de datos y el almacén de estado en un único dominio de fallo. Esto introduce cuellos de botella de producción críticos:
1. **Agotamiento Vertical de Recursos:** El renderizado dinámico limitado por CPU (CPU-bound) priva de recursos a los hilos de la base de datos limitados por E/S (I/O-bound).
2. **Punto Único de Fallo (SPOF):** La saturación de la tarjeta de interfaz de red (NIC), los kernel panics o las caídas no controladas de la aplicación dejan fuera de servicio todo el servicio web.
3. **Enredo de Estado (State Entanglement):** El estado de la sesión mantenido en la memoria del proceso impide el autoescalado horizontal a través de nodos de cómputo efímeros.

```
+-----------------------------------------------------------------------------------+
|                               Naive Architecture                                  |
|                                                                                   |
|  [ Client Browser ] ----> [ Single VM: NGINX + Node.js/Python + SQLite/Postgres ] |
|                                   (SPOF / Resource Contention)                    |
+-----------------------------------------------------------------------------------+
```

### 1.2 Mecánica Interna de la Arquitectura Desacoplada Multicapa
Para lograr resiliencia y elasticidad horizontal, las arquitecturas web de producción descomponen las responsabilidades a través de capas de ejecución especializadas:

```
[ Client ] 
    |
    v (HTTPS / TLS 1.3 - Port 443)
[ Layer 7 Load Balancer / Ingress Controller (e.g., HAProxy / NGINX Ingress) ]
    |
    +--------------------------------+--------------------------------+
    | (Static Requests)              | (Dynamic API Requests)         |
    v                                v                                v
[ CDN / Object Storage ]   [ Web/App Tier (Stateless Pods) ]   [ Web/App Tier ]
                                     |                |
                     +---------------+                +---------------+
                     | (Transient Read/Write)                         | (Persistent Data)
                     v                                                v
           [ Distributed Cache ]                            [ Database Tier ]
         (Redis / Key-Value Cluster)                    (Primary-Replica Cluster)
```

#### Desglose Mecánico:
* **Capa de Borde e Ingress de Tráfico:** Termina el cifrado TLS, ejecuta el filtrado de Web Application Firewall (WAF), hace cumplir la conformidad del protocolo HTTP y realiza proxy del tráfico L7 hacia abajo mediante conexiones HTTP/2 o HTTP/3 persistentes.
* **Capa Web/Aplicación Stateless:** Ejecuta la lógica de negocio dentro de micro-runtimes contenedorizados (ej. Go, Node.js, Python, Java). Las instancias de la aplicación almacenan **cero estado de sesión local** en discos efímeros locales.
* **Capa de Caching:** Descarga las operaciones de lectura de alta frecuencia de la capa de datos relacional utilizando estructuras de datos en memoria (latencia sub-milisegundo).
* **Capa de Persistencia:** Garantiza la conformidad ACID o la consistencia eventual utilizando topologías de replicación primary-replica con gestión de failover automatizada.

---

## 2. Trade-offs Técnicos y Comparativas

### 2.1 Estilos Arquitectónicos: Monolito vs. Microservicios vs. Serverless

| Vector | Arquitectura Monolítica | Arquitectura de Microservicios | Arquitectura Serverless / FaaS |
| :--- | :--- | :--- | :--- |
| **Complejidad Operacional** | Baja. Pipeline único, flujo de logs unificado. | Alta. Requiere distributed tracing, service discovery, mesh. | Media. El proveedor de nube gestiona el cómputo, el desarrollador gestiona los eventos. |
| **Aislamiento de Despliegue** | Bajo. Un solo bug puede tumbar todo el runtime. | Alto. Los fallos se contienen dentro de los límites de cada microservicio. | El más alto. Cada contexto de ejecución se ejecuta aislado en microVMs (ej. Firecracker). |
| **Consistencia de Datos** | Fuerte (transacciones ACID soportadas de forma nativa). | Eventual (patrón Saga, transacciones distribuidas, CDC). | Eventual/Externalizada (depende de las bases de datos aguas abajo/downstream). |
| **Perfil de Latencia** | Baja sobrecarga en llamadas intra-proceso (IPC en memoria). | La serialización de red (gRPC/JSON sobre TCP) añade latencia RPC. | Penalización por cold start (10ms - 2000ms dependiendo del runtime/VPC). |
| **Granularidad de Escalado** | Gruesa. Escala todo el stack de la aplicación junto. | Fina. Escala microservicios específicos limitados por CPU/RAM de forma independiente. | Micro. Escala invocaciones exactas de 0 a miles de forma instantánea. |

---

### 2.2 Capas de Gestión de Tráfico: Balanceo de Carga L4 vs. L7

```
Layer 4 (Transport Layer):
[ Client ] ---> [ IP:Port Router (e.g., IPVS/NLB) ] ---> TCP SYN/ACK Passthrough ---> [ Backend ]

Layer 7 (Application Layer):
[ Client ] ---> [ TLS Decryption | HTTP Headers Parsing (NGINX/HAProxy) ] ---> New TCP/HTTP Connection ---> [ Backend ]
```

| Dimensión | Balanceo de Carga Capa 4 (ej., IPVS, AWS NLB) | Balanceo de Carga Capa 7 (ej., NGINX, HAProxy, AWS ALB) |
| :--- | :--- | :--- |
| **Capa OSI** | Capa de Transporte (TCP/UDP). | Capa de Aplicación (HTTP, HTTPS, HTTP/2, gRPC, WebSocket). |
| **Capacidad de Inspección** | Solo tuplas de direcciones IP y puertos TCP/UDP. | URIs HTTP, headers, cookies, parámetros de query, cuerpos de payload. |
| **Rendimiento / Sobrecarga de CPU** | Rendimiento extremadamente alto, impacto mínimo en CPU (reenvío de paquetes en Kernel). | Mayor uso de CPU debido al descifrado TLS, asignación de buffers, parseo de headers. |
| **Decisiones de Enrutamiento** | Round-robin a nivel de conexión, least connections, IP hash. | Basado en ruta (`/api/v1`), basado en host (`api.domain.com`), afinidad por cookie. |
| **Capacidades de Seguridad** | Mitigación de SYN flood, limitación de tasa por IP (rate limiting). | Aplicación de WAF, filtrado de SQLi/XSS, validación de tokens OAuth/OIDC. |

---

### 2.3 Estrategias de Gestión de Estado

| Estrategia | Mecánica Arquitectónica | Trade-offs de SRE y Riesgos en Producción |
| :--- | :--- | :--- |
| **Sticky Sessions (Afinidad de Sesión)** | El Load Balancer fija la IP/Cookie del cliente a un servidor backend específico. | **Antipatrón para la elasticidad.** Causa una distribución desequilibrada de carga en los servidores (hotspots); el fallo de un nodo elimina las sesiones de usuario activas. |
| **Almacén en Memoria Centralizado** | ID de sesión enviado a través de Header/Cookie HTTP; estado recuperado desde un cluster Redis/Memcached. | **Estándar de la industria.** Permite pods de aplicación stateless. Añade 1-2ms de tiempo de ida y vuelta de red (round-trip) por petición; requiere una configuración de cache de alta disponibilidad. |
| **Tokens Cifrados del Lado del Cliente (JWT)** | Estado firmado criptográficamente y codificado directamente en los headers Authorization de HTTP. | Elimina las búsquedas de sesión del lado del servidor. **Riesgo:** Dificultad de revocación antes del vencimiento del TTL; el aumento del tamaño del token añade sobrecarga de ancho de banda. |

---

## 3. Infraestructura de Producción y Manifiestos Completos

Los siguientes manifiestos construyen una Arquitectura de Aplicación Web lista para producción en Kubernetes, que comprende:
1. Un **Reverse Proxy/Ingress Controller NGINX** con caching optimizado y terminación TLS.
2. Un **Deployment de Aplicación Backend Stateless** con probes de salud y soporte de autoescalado.
3. Un **Deployment y Service de la Capa de Caching Redis** de alta disponibilidad.

---

### 3.1 Configuración de Producción de Gateway/Reverse Proxy NGINX (`nginx.conf`)

```nginx
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Performance & Optimization Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Buffer Configurations
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;

    # Logging Metrics Configuration (JSON for Log Aggregators)
    log_format json_combined escape=json
      '{"time_local":"$time_local",'
      '"remote_addr":"$remote_addr",'
      '"request":"$request",'
      '"status": "$status",'
      '"body_bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"http_referrer":"$http_referer",'
      '"http_user_agent":"$http_user_agent",'
      '"upstream_addr":"$upstream_addr",'
      '"upstream_response_time":"$upstream_response_time",'
      '"upstream_status":"$upstream_status"}';

    access_log /var/log/nginx/access.log json_combined;
    error_log /var/log/nginx/error.log warn;

    # FastCGI / Upstream Caching Path
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=WEB_CACHE:10m max_size=1g inactive=60m use_temp_path=off;

    # Upstream Pool for Web Tier
    upstream web_backend_cluster {
        zone web_backend_cluster 64k;
        server 10.244.1.15:8080 max_fails=3 fail_timeout=10s;
        server 10.244.2.22:8080 max_fails=3 fail_timeout=10s;
        server 10.244.3.41:8080 max_fails=3 fail_timeout=10s;
        keepalive 32;
    }

    server {
        listen 80;
        server_name app.production.internal;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name app.production.internal;

        ssl_certificate /etc/ssl/certs/app_production.crt;
        ssl_certificate_key /etc/ssl/certs/app_production.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;

        # Security Headers
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self';" always;

        # Static Asset Caching Route
        location /static/ {
            alias /var/www/static/;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # Dynamic Application Route
        location / {
            proxy_pass http://web_backend_cluster;
            proxy_http_version 1.1;
            
            # HTTP Headers for Upstream Context Propagation
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Caching Directives
            proxy_cache WEB_CACHE;
            proxy_cache_bypass $http_authorization;
            proxy_no_cache $http_authorization;
            proxy_cache_valid 200 302 10m;
            proxy_cache_valid 404 1m;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}
```

---

### 3.2 Deployment de Kubernetes de la Capa de Aplicación Web Stateless (`web-app-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-deployment
  namespace: production
  labels:
    app.kubernetes.io/name: web-app
    app.kubernetes.io/tier: frontend-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
        app.kubernetes.io/tier: frontend-api
    spec:
      containers:
      - name: application-runtime
        image: registry.production.internal/web-app:v2.4.1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
          name: http-port
        env:
        - name: NODE_ENV
          value: "production"
        - name: REDIS_HOST
          value: "redis-service.production.svc.cluster.local"
        - name: REDIS_PORT
          value: "6379"
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "1000m"
            memory: "1024Mi"
        startupProbe:
          httpGet:
            path: /healthz/startup
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /healthz/liveness
            port: 8080
          periodSeconds: 10
          timeoutSeconds: 2
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /healthz/readiness
            port: 8080
          periodSeconds: 5
          timeoutSeconds: 2
          successThreshold: 1
          failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-app-service
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: web-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
```

---

### 3.3 Manifiesto de la Capa de Caching Redis (`cache-tier.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-cache
  namespace: production
  labels:
    app: redis-cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      containers:
      - name: redis
        image: redis:7.2-alpine
        command: ["redis-server", "--maxmemory", "384mb", "--maxmemory-policy", "allkeys-lru"]
        ports:
        - containerPort: 6379
          name: redis-port
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-service
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: redis-cache
  ports:
  - port: 6379
    targetPort: 6379
```

---

## 4. Ejecución Real en Terminal y Verificación de Salida

### 4.1 Validación del Enrutamiento HTTP Capa 7 y Estado del Cache mediante `curl`

Ejecute una petición HTTP al endpoint del load balancer/proxy para verificar el handshake TLS, los headers personalizados y el comportamiento del cache.

```bash
$ curl -Iv https://app.production.internal/api/v1/resource -H "User-Agent: SRE-Verification-Probe"
```

```text
*   Trying 192.168.10.50:443...
* Connected to app.production.internal (192.168.10.50) port 443 (#0)
* ALPN: offers h2, http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* Server certificate: app.production.internal (CN=app.production.internal)
> GET /api/v1/resource HTTP/2
> Host: app.production.internal
> User-Agent: SRE-Verification-Probe
> Accept: */*
> 
< HTTP/2 200 
< server: nginx
< date: Thu, 06 Aug 2026 22:15:00 GMT
< content-type: application/json; charset=utf-8
< content-length: 142
< x-frame-options: DENY
< x-content-type-options: nosniff
< x-xss-protection: 1; mode=block
< content-security-policy: default-src 'self';
< x-cache-status: MISS
< 
{
  "status": "success",
  "data": {
    "id": 8921,
    "payload": "stateless_execution_successful"
  }
}
* Connection #0 to host app.production.internal left intact
```

Ejecute una segunda petición idéntica para confirmar **Hits de Cache en Capa 7**:

```bash
$ curl -sI https://app.production.internal/api/v1/resource | grep -i "x-cache-status"
```

```text
x-cache-status: HIT
```

---

### 4.2 Verificación del Estado del Deployment de Pods de Kubernetes mediante `kubectl`

Inspeccione la salud operacional y la disponibilidad (readiness) de los pods de la capa web stateless.

```bash
$ kubectl get pods -n production -o wide -l app.kubernetes.io/tier=frontend-api
```

```text
NAME                                  READY   STATUS    RESTARTS   AGE   IP            NODE           NOMINATED NODE   READINESS GATES
web-app-deployment-7d5844784b-4q2lz   1/1     Running   0          14m   10.244.1.15   k8s-worker-01   <none>           <none>
web-app-deployment-7d5844784b-8x9mp   1/1     Running   0          14m   10.244.2.22   k8s-worker-02   <none>           <none>
web-app-deployment-7d5844784b-n9zlp   1/1     Running   0          14m   10.244.3.41   k8s-worker-03   <none>           <none>
```

---

### 4.3 Verificación de Endpoints Upstream y Balanceo de Carga de Services

Verifique que el Service de Kubernetes mapea correctamente los endpoints a las IPs de Pods activos:

```bash
$ kubectl get endpoints web-app-service -n production
```

```text
NAME              ENDPOINTS                                               AGE
web-app-service   10.244.1.15:8080,10.244.2.22:8080,10.244.3.41:8080   16m
```

---

## 5. Diagnóstico en Producción, Verificación y Análisis de Fallos

Al solucionar problemas de una arquitectura de aplicación web multicapa bajo estrés, los SRE siguen un flujo de trabajo diagnóstico sistemático capa por capa para aislar los dominios de fallo.

```
[ Diagnostic Workflow Flowchart ]

    [ Issue Reported: High Latency / 5xx Errors ]
                         |
                         v
       [ Step 1: Check Reverse Proxy / Ingress Logs ]
                         |
         +---------------+---------------+
         |                               |
  (HTTP 502/504 Bad Gateway)     (HTTP 500 Internal Error)
         |                               |
         v                               v
[ Step 2: Validate Upstream ]   [ Step 3: Inspect Pod Logs ]
 (Network/Socket Connectivity)   (Application Code/Exceptions)
         |                               |
         v                               v
[ Step 4: Capture Packets ]     [ Step 5: Check Cache/DB ]
   (tcpdump on Port 8080)         (Redis memory / DB locks)
```

---

### 5.1 Paso 1: Analizar los Logs de Ingress para Latencia Upstream y Códigos de Estado
Verifique si el proxy ingress está devolviendo 502 (Bad Gateway) o 504 (Gateway Timeout), indicando la degradación de un microservicio upstream.

```bash
$ tail -n 100 /var/log/nginx/access.log | jq 'select(.status >= 500)'
```

```json
{
  "time_local": "06/Aug/2026:22:20:11 +0000",
  "remote_addr": "172.16.4.12",
  "request": "POST /api/v1/checkout HTTP/2.0",
  "status": "504",
  "body_bytes_sent": "167",
  "request_time": "10.004",
  "upstream_addr": "10.244.2.22:8080",
  "upstream_response_time": "10.000",
  "upstream_status": "504"
}
```
**Diagnóstico:** El pod upstream (`10.244.2.22:8080`) no respondió dentro del tiempo de espera (timeout) de 10 segundos (`upstream_response_time: 10.000`).

---

### 5.2 Paso 2: Inspeccionar los Logs del Contenedor en Tiempo de Ejecución de la Aplicación
Examine los logs del pod degradado identificado en el Paso 1.

```bash
$ kubectl logs web-app-deployment-7d5844784b-8x9mp -n production --tail=50
```

```text
2026-08-06T22:20:05.112Z [ERROR] Failed to obtain connection from connection pool: RedisConnectionTimeoutError
    at RedisCluster.acquire (/app/node_modules/ioredis/lib/redis.js:412:11)
    at async SessionStore.get (/app/dist/session.js:88:21)
    at async /app/dist/server.js:142:9
2026-08-06T22:20:10.115Z [WARN] Request lifecycle aborted by client termination.
```
**Diagnóstico:** La capa de aplicación está bloqueada esperando la adquisición de una conexión desde la capa de cache Redis centralizada, lo que provoca el agotamiento de conexiones upstream.

---

### 5.3 Paso 3: Captura de Paquetes de Bajo Nivel y Verificación de Sockets (`tcpdump` y `netstat`)
Ejecute una captura de paquetes de bajo nivel dentro del nodo de la aplicación para verificar la salud del handshake TCP entre la capa web y la capa de cache.

```bash
$ tcpdump -i eth0 port 6379 -nn -vv -c 5
```

```text
22:22:01.401123 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2189381 ecr 0], length 0
22:22:02.403154 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2190383 ecr 0], length 0
22:22:04.407188 IP 10.244.2.22.48912 > 10.244.0.99.6379: Flags [S], seq 31120491, win 64240, options [mss 1460,sackOK,TS val 2192387 ecr 0], length 0
```
**Diagnóstico:** El pod de la aplicación está enviando paquetes TCP `SYN` (`Flags [S]`), pero no recibe **respuestas `SYN-ACK`** desde la IP de Redis (`10.244.0.99`). Esto indica un paquete descartado debido a una mala configuración de NetworkPolicy, o un pool de hilos de Redis agotado.

---

### 5.4 Tabla de Resumen Diagnóstico de Fallos de Arquitectura Web

| Síntoma | Causa Raíz | Comando de Verificación | Acción de Resolución |
| :--- | :--- | :--- | :--- |
| **HTTP 502 Bad Gateway** | El proceso upstream colapsó o el socket no escucha en el puerto destino. | `kubectl describe pod <pod-name>` (Verificar conteo de reinicios y códigos de salida). | Corregir fugas de memoria/excepciones en runtime; actualizar probes de salud del contenedor. |
| **HTTP 504 Gateway Timeout** | Contención de bloqueos en la base de datos downstream o llamada a API remota bloqueante. | `curl -w "%{time_connect}:%{time_starttransfer}\n"` | Incrementar los límites de tiempo de espera upstream o implementar colas en segundo plano asíncronas. |
| **HTTP 413 Payload Too Large** | El tamaño del cuerpo de la petición excede los límites del buffer del reverse proxy. | Inspeccionar logs de error de NGINX buscando `"client intended to send too large body"`. | Incrementar `client_max_body_size` en la configuración del reverse proxy. |
| **Pérdida de Sesión entre Peticiones** | La aplicación escribe sesiones en el disco local en lugar del cache Redis. | `kubectl exec -it <pod> -- ls /tmp/sessions` | Refactorizar el almacén de sesiones para usar un cluster clave-valor Redis externalizado. |

---

## 6. Referencias

* **Visión General y Objetivos de LPI Web Development Essentials:**  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
* **Arquitectura y Ajuste de Rendimiento del Servidor HTTP NGINX:**  
  https://nginx.org/en/docs/http/ngx_http_core_module.html
* **Documentación de Topología de Ingress y Service en Producción en Kubernetes:**  
  https://kubernetes.io/docs/concepts/services-networking/ingress/
* **IETF RFC 9110: Especificación de Arquitectura y Semántica HTTP:**  
  https://www.rfc-editor.org/rfc/rfc9110.html
* **Guías de Arquitectura de Sistemas de Alta Disponibilidad de Redis:**  
  https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/