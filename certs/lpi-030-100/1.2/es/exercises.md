# LPI Web Development Essentials (Examen 030-100, Versión 1.0)
## Topic 1.2: Arquitectura de Aplicaciones Web

**Peso del Tema de Examen:** 5  
**Nivel de Rol Objetivo:** Candidato a SRE / Platform Architect  
**Referencia Oficial:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)

---

### Visión General de la Arquitectura y Fundamentos Teóricos

La arquitectura moderna de aplicaciones web empresariales se basa en una separación de responsabilidades multicapa (multi-tiered separation of concerns) diseñada para lograr alta disponibilidad, escalabilidad horizontal lineal, aislamiento de seguridad y mantenibilidad.

```
                   +-------------------------------------------------------+
                   |                 Client Tier (Browser)                 |
                   | Dynamic DOM Rendering, JS Engine, Local Storage/Cookies|
                   +-------------------------------------------------------+
                                               |
                                        HTTP / HTTPS (TLS 1.3)
                                               v
                   +-------------------------------------------------------+
                   |           Edge Tier / Web Server (e.g., NGINX)        |
                   | TLS Termination, Static Asset Delivery, Reverse Proxy |
                   +-------------------------------------------------------+
                                               |
                                     Internal Upstream TCP Pool
                                               v
                   +-------------------------------------------------------+
                   |     Application Tier (Node.js / Express App Server)    |
                   |    Business Logic, Routing, Authentication, APIs      |
                   +-------------------------------------------------------+
                        |                                             |
            TCP / SQL (Port 5432)                             RESP (Port 6379)
                        v                                             v
+-----------------------------------------------+   +------------------------------------+
|  Relational Database Tier (PostgreSQL RDBMS)  |   |  NoSQL Cache & State Tier (Redis)  |
|  ACID Compliance, Structured Schemas, Joins   |   | Session Store, Key-Value Caching   |
+-----------------------------------------------+   +------------------------------------+
```

1. **Client Tier (Front-End):** Se ejecuta dentro de los navegadores web de los usuarios. Es responsable de renderizar la Interfaz de Usuario (UI), gestionar el Client-Side Rendering (CSR), manejar eventos del DOM e invocar APIs del backend de forma asíncrona.
2. **Web Server & Edge Tier:** Software dedicado (como NGINX o Apache HTTP Server) optimizado para manejar conexiones HTTP sincrónicas, terminar TLS, servir assets estáticos (HTML, CSS, imágenes) mediante llamadas al sistema zero-copy (`sendfile`), aplicar rate limiting y realizar reverse proxy del tráfico dinámico hacia los servidores de aplicaciones del backend.
3. **Application Server Tier:** Contiene el código ejecutable de la aplicación (por ejemplo, Node.js, Python/Django, Java/Spring). Procesa la lógica de negocio, autentica solicitudes, procesa transformaciones de payload y gestiona transacciones de base de datos.
4. **Data & State Tier:** 
   - **Relational Databases (SQL):** Aplican esquemas estrictos, restricciones de foreign key y propiedades ACID (Atomicidad, Consistencia, Aislamiento, Durabilidad) para datos de dominio relacional (por ejemplo, PostgreSQL, MySQL).
   - **Non-Relational Databases (NoSQL / In-Memory):** Manejan datos no estructurados, estado de sesión distribuido, almacenamiento de documentos o almacenamiento en caché de alto rendimiento y latencia submilisegundo (por ejemplo, Redis, MongoDB).

---

### Lab 1: Analizando la Arquitectura Cliente-Servidor y la Delegación por Reverse Proxy

#### Escenario
Estás desplegando una arquitectura de Aplicación Web lista para producción. Desacoplarás el **Web Server / Reverse Proxy** (NGINX) del **Application Server** (Node.js/Express) para garantizar que los archivos estáticos se sirvan de manera eficiente mientras que las solicitudes dinámicas se reenvíen de forma segura con los encabezados de reenvío de IP de cliente adecuados.

#### Pasos de Ejecución

1. Creá un directorio de trabajo limpio para los servicios de la aplicación:
```bash
mkdir -p ~/web-architecture-lab/app ~/web-architecture-lab/nginx
cd ~/web-architecture-lab
```

2. Creá el archivo del servidor de aplicaciones Node.js (`app/server.js`) implementando un servicio HTTP liviano que exponga encabezados de diagnóstico y el estado en tiempo de ejecución:

```javascript
// ~/web-architecture-lab/app/server.js
const http = require('http');
const PORT = 3000;

const server = http.createServer((req, res) => {
    if (req.url === '/api/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status: 'UP',
            timestamp: new Date().toISOString(),
            upstream_received_headers: req.headers,
            client_ip_detected: req.headers['x-forwarded-for'] || req.socket.remoteAddress
        }, null, 2));
        return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('404 Not Found - Route handled by Application Server');
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[APP SERVER] Listening on http://127.0.0.1:${PORT}`);
});
```

3. Creá el archivo de configuración del servidor web NGINX (`nginx/nginx.conf`) operando como un Reverse Proxy con pool de sockets upstream y enrutamiento de assets estáticos:

```nginx
# ~/web-architecture-lab/nginx/nginx.conf
worker_processes auto;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format custom_combined '$remote_addr - $remote_user [$time_local] "$request" '
                               '$status $body_bytes_sent "$http_referer" '
                               '"$http_user_agent" upstream: "$upstream_addr" '
                               'response_time: $request_time';

    access_log /tmp/access.log custom_combined;
    error_log  /tmp/error.log warn;

    # Upstream definition for Application Server pool
    upstream nodejs_app_backend {
        server 127.0.0.1:3000 max_fails=3 fail_timeout=10s;
        keepalive 32; # Keep-alive connection pool to application tier
    }

    server {
        listen 8080 default_server;
        server_name localhost;

        # Root directory for static assets served directly by NGINX
        root /tmp/public_html;
        index index.html;

        # Static Asset Rule: Handled directly by Web Server
        location / {
            try_files $uri $uri/ =404;
            expires 1h;
            add_header Cache-Control "public, no-transform";
        }

        # Dynamic API Rule: Delegated to Application Server Tier via Reverse Proxy
        location /api/ {
            proxy_pass http://nodejs_app_backend;
            
            # HTTP 1.1 protocol enablement for keepalive sockets
            proxy_http_version 1.1;
            proxy_set_header Connection "";

            # Essential Reverse Proxy Headers for Identity Propagation
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Proxy Buffering & Timeouts
            proxy_connect_timeout 5s;
            proxy_read_timeout 60s;
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 4k;
        }
    }
}
```

4. Creá el directorio y el archivo de asset HTML estático servido directamente por NGINX:
```bash
mkdir -p /tmp/public_html
cat << 'EOF' > /tmp/public_html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Enterprise Web Architecture</title>
</head>
<body>
    <h1>Static Asset Delivered via Edge NGINX Web Server</h1>
</body>
</html>
EOF
```

5. Ejecutá la verificación de validación de sintaxis de NGINX:
```bash
nginx -t -c ~/web-architecture-lab/nginx/nginx.conf
```
*Resultado Esperado:*
```text
nginx: the configuration file /home/user/web-architecture-lab/nginx/nginx.conf syntax is ok
nginx: configuration file /home/user/web-architecture-lab/nginx/nginx.conf test is successful
```

6. Iniciá el servidor backend Node.js en segundo plano e iniciá NGINX haciendo referencia a la configuración personalizada:
```bash
node ~/web-architecture-lab/app/server.js &
APP_PID=$!
nginx -c ~/web-architecture-lab/nginx/nginx.conf
```

7. Ejecutá una solicitud de diagnóstico HTTP detallada (verbose) dirigida al asset estático a través del puerto 8080:
```bash
curl -v http://localhost:8080/index.html
```
*Fragmento de Resultado Esperado:*
```text
*   Trying 127.0.0.1:8080...
* Connected to localhost (127.0.0.1) port 8080
> GET /index.html HTTP/1.1
> Host: localhost:8080
> User-Agent: curl/7.81.0
> 
< HTTP/1.1 200 OK
< Server: nginx
< Content-Type: text/html
< Content-Length: 161
< Cache-Control: public, no-transform
< 
<!DOCTYPE html>
...
```

8. Ejecutá una solicitud `curl` de diagnóstico dirigida a la ruta de la API dinámicas del backend `/api/health`:
```bash
curl -s http://localhost:8080/api/health | jq .
```
*Fragmento de Resultado Esperado:*
```json
{
  "status": "UP",
  "timestamp": "2026-08-06T18:50:00.000Z",
  "upstream_received_headers": {
    "host": "localhost",
    "x-real-ip": "127.0.0.1",
    "x-forwarded-for": "127.0.0.1",
    "x-forwarded-proto": "http",
    "connection": ""
  },
  "client_ip_detected": "127.0.0.1"
}
```

9. Verificá los sockets en escucha a través de ambas capas usando `ss`:
```bash
ss -tulpn | grep -E '8080|3000'
```
*Resultado Esperado:*
```text
tcp   LISTEN 0      512        127.0.0.1:3000      0.0.0.0:*    users:(("node",pid=...,fd=18))
tcp   LISTEN 0      512          0.0.0.0:8080      0.0.0.0:*    users:(("nginx",pid=...,fd=6))
```

10. Limpiá los procesos activos para el Lab 1:
```bash
nginx -c ~/web-architecture-lab/nginx/nginx.conf -s stop
kill $APP_PID
```

---

#### Preguntas de Verificación — Lab 1

**Pregunta 1.1:** ¿Cuál es el principal compromiso (trade-off) operativo de delegar la entrega de assets estáticos a NGINX en lugar de servir esos archivos directamente a través de un servidor de aplicaciones Node.js?  
A) Node.js maneja I/O de un solo hilo más rápido que NGINX debido a las optimizaciones del event loop asíncrono para sistemas de archivos.  
B) NGINX utiliza optimizaciones del kernel de bajo nivel (acceso a memoria zero-copy mediante `sendfile`), liberando al event loop de un solo hilo del servidor de aplicaciones del overhead de I/O de bloque.  
C) Node.js comprime automáticamente los archivos estáticos, mientras que NGINX requiere un plugin externo para la compresión gzip/brotli.  
D) Servir archivos desde Node.js omite la caché de páginas del sistema operativo, lo que hace que el uso de memoria sea impredecible.

**Pregunta 1.2:** En el fragmento de configuración de NGINX anterior, ¿por qué se inyectan explícitamente `X-Real-IP` y `X-Forwarded-For` en los encabezados del proxy (`proxy_set_header`) antes de llegar al servidor de aplicaciones Node.js upstream?  
A) Sin estos encabezados, el servidor de aplicaciones backend ve la dirección IP del reverse proxy NGINX como la IP del cliente entrante, rompiendo la geolocalización, el registro de auditoría (audit logging) y el rate limiting.  
B) El servidor de aplicaciones Node.js rechaza cualquier solicitud HTTP que no contenga `X-Forwarded-For` con el código de estado HTTP 400 Bad Request.  
C) NGINX usa estos encabezados internamente para determinar qué nodo del bloque de servidores `upstream` debe manejar la solicitud.  
D) `X-Forwarded-For` es obligatorio para establecer conexiones TCP Keepalive entre NGINX y el navegador del cliente.

---

### Lab 2: Mecánica de Almacenamiento Multicapa (Integración de SQL Relacional vs. NoSQL No Relacional)

#### Escenario
Una capa de Aplicación Web debe interactuar con dos motores de base de datos distintos: una **Base de Datos SQL Relacional (PostgreSQL)** para registros transaccionales y estructurados de cuentas de usuario, y una **Caché NoSQL / In-Memory No Relacional (Redis)** para la gestión de sesiones efímeras de alta velocidad. Inicializarás ambas estructuras de datos, ejecutarás consultas de diagnóstico y analizarás cómo se desacopla el estado de los servidores de aplicaciones.

```
                        +----------------------------+
                        |  Node.js Application Server |
                        +----------------------------+
                               /              \
         Structured ACID Data /                \ Ephemeral Session State
                             v                  v
                 +---------------+        +---------------+
                 |  PostgreSQL   |        |     Redis     |
                 | (Relational)  |        |    (NoSQL)    |
                 +---------------+        +---------------+
```

#### Pasos de Ejecución

1. Creá un archivo de definición de esquema para la base de datos Relacional (`~/web-architecture-lab/schema.sql`):

```sql
-- ~/web-architecture-lab/schema.sql
-- Relational Tier: Enforces schema, strict data types, foreign keys, and indexes.

DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    total_amount NUMERIC(10, 2) NOT NULL CHECK (total_amount >= 0),
    status VARCHAR(20) DEFAULT 'PENDING',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orders_user_id ON orders(user_id);

-- Insert seed data
INSERT INTO users (username, email) VALUES 
    ('alex_sre', 'alex@example.com'),
    ('dev_maria', 'maria@example.com');

INSERT INTO orders (user_id, total_amount, status) VALUES 
    (1, 149.99, 'COMPLETED'),
    (1, 89.50, 'SHIPPED'),
    (2, 299.00, 'PENDING');
```

2. Inicializá un contenedor de base de datos PostgreSQL local usando `docker` para ejecutar y verificar el esquema relacional:
```bash
docker run --name lab-postgres -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb -p 5432:5432 -d postgres:15-alpine
```

3. Esperá 3 segundos a que el contenedor inicie y luego poblá el esquema relacional de PostgreSQL usando `docker exec`:
```bash
sleep 3
docker exec -i lab-postgres psql -U postgres -d appdb < ~/web-architecture-lab/schema.sql
```
*Resultado Esperado:*
```text
DROP TABLE
DROP TABLE
CREATE TABLE
CREATE TABLE
CREATE INDEX
INSERT 0 2
INSERT 0 3
```

4. Ejecutá una consulta SQL Join demostrando integridad relacional y agregación transaccional:
```bash
docker exec -it lab-postgres psql -U postgres -d appdb -c "
SELECT 
    u.user_id, 
    u.username, 
    COUNT(o.order_id) AS total_orders, 
    SUM(o.total_amount) AS lifetime_value
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.username
ORDER BY lifetime_value DESC;"
```
*Resultado Esperado:*
```text
 user_id |  username  | total_orders | lifetime_value 
---------+------------+--------------+----------------
       2 | dev_maria  |            1 |         299.00
       1 | alex_sre   |            2 |         239.49
(2 rows)
```

5. Inicializá un contenedor de instancia local de Redis (Almacenamiento NoSQL Key-Value / In-Memory) para el estado de sesión dinámico:
```bash
docker run --name lab-redis -p 6379:6379 -d redis:7-alpine
```

6. Simulá la inserción de una sesión del servidor de aplicaciones en el almacenamiento NoSQL usando `redis-cli`:
```bash
# Set session key with JSON payload and TTL (Time-To-Live) of 3600 seconds
docker exec -it lab-redis redis-cli SET "session:sess_99a8f7d6" '{"user_id":1,"role":"admin","login_ip":"192.168.1.50"}' EX 3600

# Set a counter for API Rate Limiting (atomic operation)
docker exec -it lab-redis redis-cli INCR "ratelimit:ip_192.168.1.50"
docker exec -it lab-redis redis-cli EXPIRE "ratelimit:ip_192.168.1.50" 60
```
*Resultado Esperado:*
```text
OK
(integer) 1
(integer) 1
```

7. Consultá el almacenamiento NoSQL de Redis para verificar la latencia de recuperación de clave y el tiempo de expiración (TTL) restante:
```bash
docker exec -it lab-redis redis-cli GET "session:sess_99a8f7d6"
docker exec -it lab-redis redis-cli TTL "session:sess_99a8f7d6"
```
*Resultado Esperado:*
```text
"{\"user_id\":1,\"role\":\"admin\",\"login_ip\":\"192.168.1.50\"}"
(integer) 3595
```

8. Limpiá los contenedores del laboratorio:
```bash
docker rm -f lab-postgres lab-redis
```

---

#### Preguntas de Verificación — Lab 2

**Pregunta 2.1:** ¿Qué requisito fundamental impulsa a los arquitectos a utilizar un almacenamiento clave-valor NoSQL como Redis para el almacenamiento de sesiones de usuario en lugar de almacenar las sesiones directamente en tablas de bases de datos relacionales como PostgreSQL?  
A) Las bases de datos relacionales no pueden almacenar cadenas JSON, requiriendo que los campos de sesión se normalicen en columnas de tabla separadas.  
B) Almacenar lecturas/escrituras efímeras de alta frecuencia (como la búsqueda de sesión en cada solicitud HTTP) en bases de datos relacionales limitadas por disco genera sobrecarga de tablas (table bloat), overhead de bloqueos e I/O de disco innecesario, mientras que los almacenamientos clave-valor orientados a memoria ofrecen búsquedas en submilisegundos con expulsión automática por TTL.  
C) Redis garantiza un cumplimiento transaccional ACID estricto en clústeres distribuidos, mientras que PostgreSQL solo admite consistencia eventual.  
D) Las bases de datos relacionales invalidan automáticamente las cookies de sesión al cerrar el navegador del cliente, lo que imposibilita la gestión de sesiones.

**Pregunta 2.2:** ¿Cuál es el principal inconveniente arquitectónico de mantener el estado de sesión directamente en la memoria local (RAM) de instancias individuales del servidor de aplicaciones (Sticky Sessions / In-Memory State) en lugar de utilizar una capa de estado NoSQL centralizada?  
A) Las sesiones en memoria local consumen ciclos de reloj de CPU durante los cálculos del handshake TLS.  
B) Almacenar el estado localmente impide el autoescalado horizontal porque el enrutamiento debe fijar a los usuarios a instancias de servidor específicas; si una instancia falla o se escala hacia abajo, las sesiones de los usuarios afectados se pierden de inmediato.  
C) Las instancias de la aplicación Node.js sincronizan automáticamente los objetos de sesión en RAM local a través de los límites del servidor mediante HTTP multicast.  
D) Los sistemas operativos limitan los objetos JavaScript en memoria a 1024 bytes por conexión.

---

### Lab 3: Arquitecturas de Aplicaciones Modernas y Técnicas de Diagnóstico

#### Escenario
Como SRE / Platform Architect, debés evaluar patrones arquitectónicos (**Monolith vs. Microservices**, **Client-Side Rendering vs. Server-Side Rendering**) y dominar técnicas de diagnóstico (`curl`, rastreo de conexiones, análisis de encabezados) para depurar anomalías en la interacción entre front-end y back-end.

#### Matriz de Patrones de Arquitectura

| Característica / Dimensión | Monolithic Architecture | Microservices Architecture | Serverless / FaaS |
| :--- | :--- | :--- | :--- |
| **Deployment Unit** | Binario / artefacto único unificado | Artefactos de servicio independientes desacoplados | Manejadores de funciones atómicos |
| **Data Storage** | Esquema de base de datos único centralizado | Patrón de aislamiento Database-per-service | Almacenamientos de datos externos administrados |
| **Scaling Granularity** | Escala vertical y escala horizontal de la aplicación completa | Escala horizontal independiente por servicio | Escala de concurrencia instantánea impulsada por eventos |
| **Operational Complexity** | Baja complejidad inicial | Alta (requiere service mesh, rastreo distribuido) | Operaciones de servidor bajas; depuración local compleja |
| **Failure Domain** | Una sola falla derriba el monolito completo | Aislado a un microservicio específico | Aislado a la ejecución de una invocación individual |

#### Pasos de Ejecución (Herramientas de Diagnóstico)

1. Realizá un análisis detallado de tiempos HTTP usando `curl` para diagnosticar cuellos de botella de rendimiento a través de las capas arquitectónicas (resolución DNS, conexión TCP, handshake TLS, tiempo hasta el primer byte [TTFB] y tiempo total de transferencia):

Creá un archivo de formato personalizado de `curl` (`~/web-architecture-lab/curl-format.txt`):
```text
  time_namelookup:  %{time_namelookup}s\n
     time_connect:  %{time_connect}s\n
  time_appconnect:  %{time_appconnect}s\n
 time_pretransfer:  %{time_pretransfer}s\n
    time_redirect:  %{time_redirect}s\n
time_starttransfer:  %{time_starttransfer}s (TTFB)\n
                  ----------\n
       time_total:  %{time_total}s\n
```

2. Ejecutá una prueba de diagnóstico contra un endpoint externo utilizando la métrica de desglose de tiempo:
```bash
curl -s -w "@$HOME/web-architecture-lab/curl-format.txt" -o /dev/null https://www.lpi.org
```
*Resultado Esperado:*
```text
  time_namelookup:  0.012410s
     time_connect:  0.045120s
  time_appconnect:  0.089312s
 time_pretransfer:  0.089450s
    time_redirect:  0.000000s
time_starttransfer:  0.152340s (TTFB)
                  ----------
       time_total:  0.154120s
```

3. Rastreá los encabezados HTTP sin procesar (raw headers) y los payloads de solicitud-respuesta para auditar cross-origin (CORS), almacenamiento en caché y metadatos de identidad del servidor:
```bash
curl -I -s -H "User-Agent: Enterprise-Diagnostic-Bot/1.0" https://www.lpi.org
```
*Fragmento de Resultado Esperado:*
```text
HTTP/2 200 
date: Thu, 06 Aug 2026 18:50:00 GMT
content-type: text/html; charset=UTF-8
server: Nginx
cache-control: max-age=3600, public
strict-transport-security: max-age=31536000; includeSubDomains
```

4. Limpiá los archivos temporales de diagnóstico:
```bash
rm -rf ~/web-architecture-lab
```

---

#### Preguntas de Verificación — Lab 3

**Pregunta 3.1:** En el desarrollo web moderno, ¿cuál es la diferencia arquitectónica fundamental entre **Client-Side Rendering (CSR)** (por ejemplo, aplicaciones de página única [Single Page Applications] construidas con React/Vue) y **Server-Side Rendering (SSR)** (por ejemplo, Next.js/Nuxt)?  
A) CSR genera cadenas HTML completas en el servidor backend para cada solicitud, mientras que SSR ejecuta JavaScript dentro del navegador para construir HTML dinámicamente.  
B) CSR descarga un esqueleto HTML mínimo y grandes bundles de JavaScript, confiando en la CPU del navegador cliente para obtener datos de API y renderizar el DOM; SSR pre-renderiza HTML completamente poblado en el servidor por solicitud, mejorando el tiempo de carga inicial de la página (First Contentful Paint) y la optimización para motores de búsqueda (SEO).  
C) CSR requiere una base de datos relacional, mientras que SSR funciona exclusivamente con almacenamientos NoSQL.  
D) CSR elimina por completo la latencia de red al ejecutar la lógica del backend dentro de Web Workers.

**Pregunta 3.2:** ¿Qué patrón arquitectónico establece que cada microservicio independiente gestione su propia base de datos separada en lugar de compartir una única base de datos central monolítica?  
A) Shared Database Pattern  
B) Database-per-Service Pattern  
C) CQRS (Command Query Responsibility Segregation) Pattern  
D) Event Sourcing Pattern

**Pregunta 3.3:** Al analizar la latencia de una aplicación web usando `curl`, si `time_namelookup` es 0.005s, `time_connect` es 0.020s, pero `time_starttransfer` (TTFB) es 2.850s, ¿dónde se sitúa el cuello de botella de rendimiento?  
A) El resolvedor DNS de la interfaz de red local está descartando solicitudes.  
B) La ruta de red entre el cliente y el servidor tiene una alta pérdida física de paquetes.  
C) El servidor de aplicaciones o la capa de base de datos del backend está tomando un tiempo prolongado para procesar la lógica de negocio / consultas SQL antes de enviar el primer byte de respuesta.  
D) El motor de JavaScript del navegador del cliente no puede interpretar los archivos CSS.

---

<details>
<summary><strong>Respuestas y Explicaciones Detalladas</strong></summary>

### Soluciones del Lab 1

* **Pregunta 1.1: La respuesta correcta es B**
  * **Análisis Detallado:** NGINX está diseñado específicamente como un servidor web asíncrono y orientado a eventos. Al servir archivos estáticos desde el disco, NGINX utiliza la llamada al sistema del kernel `sendfile()`. Esto permite que los datos se transfieran directamente desde la caché de páginas del sistema operativo al buffer del socket de red sin copiar memoria en aplicaciones en espacio de usuario (Zero-Copy I/O). Por el contrario, Node.js se ejecuta en un event loop de JavaScript V8 de un solo hilo; requerir que Node.js lea archivos binarios del disco en buffers de memoria bloquea los ticks del event loop y desperdicia ancho de banda de memoria de la CPU que debería reservarse para la lógica de negocio dinámica.
* **Pregunta 1.2: La respuesta correcta es A**
  * **Análisis Detallado:** Cuando una aplicación web se ubica detrás de un Reverse Proxy (como NGINX, HAProxy o un ALB de AWS), el proxy termina la conexión TCP entrante del navegador cliente y establece una *nueva* conexión TCP con el servidor de aplicaciones upstream. En consecuencia, `req.socket.remoteAddress` en la capa de aplicación apunta a NGINX (`127.0.0.1` o IP del proxy). Para preservar la identidad del cliente para el rate limiting, auditoría de seguridad y geolocalización, NGINX debe adjuntar la IP real del cliente en los encabezados HTTP (`X-Real-IP` y `X-Forwarded-For`) antes de reenviar la solicitud.

---

### Soluciones del Lab 2

* **Pregunta 2.1: La respuesta correcta es B**
  * **Análisis Detallado:** Las bases de datos relacionales (PostgreSQL/MySQL) almacenan datos en almacenamiento de bloques persistente estructurado dentro de índices B-Tree, optimizados para consultas relacionales complejas, joins y consistencia transaccional (ACID). Cada escritura o actualización requiere el registro en un Write-Ahead Log (WAL) y la gestión de la contención de bloqueos (lock contention). Las sesiones de usuario son efímeras, se leen en casi todas las solicitudes HTTP y se actualizan constantemente. Ubicar el almacenamiento de sesiones en un motor NoSQL In-Memory como Redis elimina los cuellos de botella de I/O de disco, produciendo tiempos de respuesta de submilisegundos y utilizando políticas de expulsión por TTL en memoria (como LRU/volatile-ttl) para purgar automáticamente las sesiones expiradas sin el overhead de mantenimiento (vacuuming) de tablas.
* **Pregunta 2.2: La respuesta correcta es B**
  * **Análisis Detallado:** En una arquitectura web moderna cloud-native, los servidores de aplicaciones deben permanecer **sin estado** (stateless). Si un servidor de aplicaciones almacena el estado de sesión en su memoria de proceso local (RAM), el tráfico entrante de un usuario *siempre* debe enrutarse a esa instancia exacta de servidor ("Sticky Sessions" / Session Affinity). Esto rompe el autoescalado horizontal (Elasticidad), impide los despliegues blue/green sin tiempo de inactividad (zero-downtime deployments) y da como resultado la pérdida total de la sesión cada vez que una instancia de aplicación falla o es finalizada por un auto-scaler. Desacoplar el estado de la sesión a una capa centralizada de Redis permite que cualquier instancia de aplicación stateless sirva cualquier solicitud de cliente indistintamente.

---

### Soluciones del Lab 3

* **Pregunta 3.1: La respuesta correcta es B**
  * **Análisis Detallado:** En el Client-Side Rendering (CSR), el servidor web entrega un esqueleto (shell) HTML mínimo que contiene etiquetas de script `<script src="app.js">`. El navegador del usuario descarga el bundle de JavaScript, lo ejecuta localmente, llama a las APIs del backend de forma asíncrona mediante `fetch()` o `XMLHttpRequest` y construye el DOM de HTML dinámicamente. Esto crea una experiencia de carga inicial diferida (un deficiente First Contentful Paint / FCP) y presenta desafíos para los rastreadores de motores de búsqueda. En el Server-Side Rendering (SSR), el servidor ejecuta el motor de renderizado por solicitud, obtiene los recursos de base de datos necesarios y entrega el marcado HTML completamente renderizado al cliente, ofreciendo un renderizado visual instantáneo y características superiores de SEO.
* **Pregunta 3.2: La respuesta correcta es B**
  * **Análisis Detallado:** El **Database-per-Service Pattern** establece que los microservicios no deben acceder directamente a los almacenamientos de datos de otros. El aislamiento garantiza que los microservicios estén acoplados de forma débil (loosely coupled) y puedan evolucionar sus esquemas de manera independiente sin provocar fallas en cascada en otros equipos. La comunicación a través de los límites del servicio ocurre exclusivamente a través de APIs REST/gRPC bien definidas o buses de eventos asíncronos (por ejemplo, Kafka, RabbitMQ).
* **Pregunta 3.3: La respuesta correcta es C**
  * **Análisis Detallado:** La métrica `time_starttransfer` representa el Tiempo hasta el Primer Byte (TTFB)—el tiempo total transcurrido desde el envío inicial de la solicitud hasta que el primer byte de la respuesta HTTP llega al cliente. Dado que `time_namelookup` (DNS: 5ms) y `time_connect` (conexión TCP: 20ms) son extremadamente bajos, la ruta de red física y la resolución DNS están saludables. El retraso de 2.83 segundos entre el establecimiento de la conexión TCP y el TTFB demuestra que el cuello de botella se encuentra dentro de la lógica de aplicación del lado del servidor, como consultas de base de datos lentas sin indexar, timeouts de microservicios upstream o procesamiento intensivo de CPU antes de vaciar (flush) el flujo de respuesta HTTP.

</details>