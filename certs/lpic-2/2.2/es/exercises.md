# LPIC-2 (Examen 202-450, v4.5) — Tema 208: Servicios Web (Peso: 8)
**Guía Avanzada de Arquitectura de Producción, Configuración, Ajuste de Rendimiento y Diagnóstico**

---

## Documentación Oficial de Referencia
- **LPI Exam Objectives**: [LPIC-2 202-450 Exam Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Apache HTTP Server Documentation**: [Apache HTTPD 2.4 Documentation](https://httpd.apache.org/docs/2.4/)
- **NGINX Core Architecture & Modules**: [NGINX Reference Documentation](https://nginx.org/en/docs/)

---

## Módulo 1: Mecánica Interna y Configuración Avanzada de Apache HTTPD

### 1.1 Multi-Processing Modules (MPM): Comparación Arquitectónica Profunda

Apache HTTPD abstrae la concurrencia en el manejo de solicitudes a través de Multi-Processing Modules (MPMs). La elección del MPM correcto determina cómo el sistema operativo gestiona la memoria de los procesos, el cambio de contexto (context switching), los descriptores de archivo y los hilos worker bajo un tráfico de red intenso.

```
       +-----------------------------------------------------------------------+
       |                           APACHE HTTPD PARENT                         |
       |                             (Root Process)                            |
       +-----------------------------------------------------------------------+
           |                                |                              |
           v                                v                              v
+-----------------------+        +---------------------+        +---------------------+
|      MPM PREFORK      |        |     MPM WORKER      |        |      MPM EVENT      |
| Single Thread/Process |        | Multi-Threaded/Proc |        | Async Listener Event|
+-----------------------+        +---------------------+        +---------------------+
| Child Proc 1 (Worker) |        | Child Proc 1        |        | Child Proc 1        |
| Child Proc 2 (Worker) |        |  |- Thread 1        |        |  |- Listener (epoll)|
| Child Proc N (Worker) |        |  |- Thread 2        |        |  |- Worker Thread 1 |
|                       |        |  |- Thread N        |        |  |- Worker Thread N |
|  * High Memory Footpr |        |  * Shared Memory    |        |  * Dedicated Async  |
|  * Non-thread-safe PHP|        |  * Thread contention|        |    Keep-Alive Pool  |
+-----------------------+        +---------------------+        +---------------------+
```

#### 1. MPM Prefork (`mod_mpm_prefork`)
- **Modelo de Ejecución**: Arquitectura basada en procesos, no multihilo (non-threaded). Un proceso padre único gestiona un pool de procesos hijo worker monohilo. Cada hijo maneja exactamente una solicitud a la vez.
- **Perfil de Memoria**: Alto consumo de memoria (high memory footprint). El aislamiento de procesos garantiza la seguridad de memoria, evitando problemas de thread-safety con módulos que no son thread-safe (por ejemplo, `mod_php` heredado).
- **Comportamiento I/O**: I/O sincrónico bloqueante. Si un cliente inicia una conexión Keep-Alive de larga duración, el proceso worker dedicado permanece bloqueado y no disponible para atender solicitudes HTTP entrantes.

#### 2. MPM Worker (`mod_mpm_worker`)
- **Modelo de Ejecución**: Arquitectura híbrida multiproceso y multihilo. El proceso padre genera un número fijo de procesos hijo. Cada proceso hijo genera un número fijo de hilos worker y un único hilo listener.
- **Perfil de Memoria**: Bajo uso de memoria en comparación con Prefork. Espacio de direcciones de memoria compartida entre hilos dentro del mismo proceso.
- **Comportamiento I/O**: I/O sincrónico multihilo. Un hilo permanece vinculado a una conexión activa durante la duración de la transacción HTTP, incluidos los estados de espera de Keep-Alive.

#### 3. MPM Event (`mod_mpm_event`)
- **Modelo de Ejecución**: Arquitectura asincrónica orientada a eventos, multiproceso y multihilo basada en notificaciones de eventos del SO (`epoll` en Linux, `kqueue` en BSD).
- **Mecanismo Interno**: Un **Listener Thread** dedicado por proceso hijo escucha en el socket. Cuando llega un encabezado de solicitud HTTP, el listener entrega la conexión a un **Worker Thread** disponible.
- **Descarga de Keep-Alive (Keep-Alive Offloading)**: Una vez enviada la respuesta HTTP, si Keep-Alive está activo, el hilo worker **no** se bloquea. El descriptor de socket se devuelve a una lista de interés central de `epoll` gestionada por el hilo listener. Cuando llegan nuevos bytes en el socket Keep-Alive inactivo, el listener lo reasigna a un hilo worker. Esto permite que MPM Event mantenga decenas de miles de clientes Keep-Alive concurrentes utilizando un mínimo de hilos worker.

---

### 1.2 Resolución de Directorio de Contexto y Control de Acceso (`mod_authz_core`)

Apache procesa las directivas de configuración de acuerdo con un orden estricto de evaluación jerárquica, independientemente de su aparición en `httpd.conf`:

1. `<Directory>` (procesado desde la ruta más corta a la más larga)
2. `<DirectoryMatch>` (y regex `~`)
3. `<Files>` y `<FilesMatch>` (evaluados concurrentemente con bloques Directory)
4. `<Location>` y `<LocationMatch>` (evaluados estrictamente **después** de la resolución de rutas del sistema de archivos)

> **Regla Arquitectónica**: Use `<Directory>` para recursos del sistema de archivos y `<Location>` estrictamente para ubicaciones URI fuera del sistema de archivos (por ejemplo, endpoints de `mod_status` o rutas proxied). Aplicar controles de acceso a `<Location>` para archivos locales puede permitir la omisión de autorización (authorization bypasses) a través de symlinks o recorrido de rutas canónicas (canonical path traversal).

#### Configuración de Producción: `/etc/httpd/conf.d/vhost_production.conf` Completo

```apache
# /etc/httpd/conf.d/vhost_production.conf
# Syntactically Valid Apache 2.4 Advanced Production Configuration

<VirtualHost *:80>
    ServerName app.enterprise.internal
    ServerAlias www.app.enterprise.internal
    DocumentRoot "/var/www/html/app"
    ServerAdmin sysadmin@enterprise.internal

    # Global Defensive Base Directive
    <Directory "/">
        AllowOverride None
        Require all denied
    </Directory>

    # Application Root Context
    <Directory "/var/www/html/app">
        Options -Indexes +FollowSymLinks
        AllowOverride AuthConfig Options=ExecCGI,Indexes
        Require all granted
    </Directory>

    # Restricted Administrative Filesystem Area
    <Directory "/var/www/html/app/admin">
        Options -Indexes
        AllowOverride None
        
        AuthType Basic
        AuthName "Restricted Internal Platform Administration"
        AuthUserFile "/etc/httpd/security/.htpasswd"
        
        <RequireAll>
            Require valid-user
            Require ip 10.50.0.0/16 192.168.1.0/24
            Require not ip 10.50.99.100
        </RequireAll>
    </Directory>

    # Protect Hidden Dotfiles (e.g., .git, .env)
    <FilesMatch "^\.(?!well-known)">
        Require all denied
    </FilesMatch>

    # Custom Log Formats with Performance Microsecond Timing (%D)
    LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %D" combined_performance
    CustomLog "/var/log/httpd/app_access.log" combined_performance
    ErrorLog "/var/log/httpd/app_error.log"
    LogLevel warn
</VirtualHost>
```

---

## Módulo 2: Ajuste de Apache HTTPD, Cálculo de Recursos y Observabilidad

### 2.1 Cálculo de Dimensionamiento para `mod_mpm_event` Bajo Alta Concurrencia

Para calcular la capacidad máxima de clientes concurrentes y prevenir kernel panics por Out-Of-Memory (OOM), los administradores de sistemas deben alinear los límites de hilos con la memoria RAM disponible en el sistema.

#### Parámetros de Configuración
- `ServerLimit`: Límite máximo en el número de procesos hijo activos.
- `ThreadsPerChild`: Número exacto de hilos worker creados por cada proceso hijo.
- `MaxRequestWorkers`: Número total máximo de hilos worker que atienden solicitudes concurrentemente (`ServerLimit` × `ThreadsPerChild`).
- `AsyncRequestWorkerFactor`: Multiplicador que determina las conexiones Keep-Alive inactivas máximas permitidas por hilo worker (Por defecto: `2`).

#### Fórmula de Derivación Matemática:
$$\text{Max Processes} = \left\lfloor \frac{\text{Total RAM} - \text{OS/Buffer Reserve}}{\text{Average Child Process RSS Memory}} \right\rfloor$$

$$\text{MaxRequestWorkers} = \text{Max Processes} \times \text{ThreadsPerChild}$$

#### Ejemplo de Dimensionamiento Empresarial:
- RAM Total del Servidor: **16 GB**
- Reservada para SO/Monitoreo/Buffers: **4 GB**
- RAM Disponible para Apache: **12 GB** (12,288 MB)
- Memoria Promedio por Proceso Hijo `mod_mpm_event` (RSS): **60 MB**
- Objetivo de `ThreadsPerChild`: **64**

$$\text{Max Processes} = \left\lfloor \frac{12288 \text{ MB}}{60 \text{ MB}} \right\rfloor = 204 \text{ processes}$$

$$\text{MaxRequestWorkers} = 204 \times 64 = 13,056 \text{ threads}$$

#### Bloque de Directivas Sintácticamente Válido (`/etc/httpd/conf.modules.d/00-mpm.conf`):

```apache
# /etc/httpd/conf.modules.d/00-mpm.conf
LoadModule mpm_event_module modules/mod_mpm_event.so

<IfModule mpm_event_module>
    ServerLimit              25
    StartServers              5
    MinSpareThreads          128
    MaxSpareThreads          512
    ThreadsPerChild           64
    ThreadLimit               64
    MaxRequestWorkers       1600
    MaxConnectionsPerChild  10000
    AsyncRequestWorkerFactor   2
</IfModule>
```

---

### 2.2 Diagnósticos Profundos y Perfilado de Estado en Vivo a través de CLI

Para inspeccionar el estado del servidor sin una GUI, configure `mod_status` con `ExtendedStatus On`.

#### Directiva de Estado del Servidor (`/etc/httpd/conf.d/status.conf`):

```apache
<Location "/server-status">
    SetHandler server-status
    Require ip 127.0.0.1 10.50.0.0/16
</Location>
ExtendedStatus On
```

#### Ejecución de Comandos en Tiempo Real y Salida Esperada de la Máquina:

Ejecute una obtención no interactiva de métricas del servidor usando `curl`:

```bash
curl -s http://127.0.0.1/server-status?auto
```

**Salida Esperada del Comando:**
```text
Total Accesses: 450921
Total kBytes: 1849201
Uptime: 86400
CPULoad: .425
ReqPerSec: 5.21899
BytesPerSec: 21915.2
BytesPerReq: 4200.73
BusyWorkers: 14
IdleWorkers: 114
ConnsTotal: 48
ConnsAsyncWriting: 2
ConnsAsyncKeepAlive: 32
ConnsAsyncClosing: 2
Scoreboard: ____________W___W__W________W_W____W___W_W_W_W_____W_W________________________________________________________________________________________________________________________________________________________________________________________________
```

#### Interpretación de la Clave de Scoreboard:
- `_`: Esperando conexión
- `S`: Iniciando (Starting up)
- `R`: Leyendo solicitud (Reading Request)
- `W`: Enviando respuesta (Busy Worker)
- `K`: Keepalive (lectura)
- `D`: Búsqueda DNS (DNS Lookup)
- `C`: Cerrando conexión
- `L`: Registrando (Logging)
- `G`: Finalizando de forma gradual (Gracefully finishing)
- `I`: Limpieza de worker inactivo

---

## Módulo 3: Arquitectura NGINX y Reverse Proxy de Alto Rendimiento

### 3.1 Arquitectura Event Loop de NGINX vs Modelo de Procesos

NGINX se basa en una arquitectura asincrónica, no bloqueante y orientada a eventos, diseñada para eliminar la sobrecarga del cambio de contexto (context-switching) de los hilos.

```
+-----------------------------------------------------------------------+
|                             NGINX MASTER                              |
|                         (Reads Conf, Binds Ports)                     |
+-----------------------------------------------------------------------+
     |                                                             |
     v                                                             v
+------------------------------------+           +------------------------------------+
|           WORKER PROCESS 1         |           |           WORKER PROCESS 2         |
|  +------------------------------+  |           |  +------------------------------+  |
|  |       Non-Blocking I/O       |  |           |  |       Non-Blocking I/O       |  |
|  |     Event Loop (epoll)       |  |           |  |     Event Loop (epoll)       |  |
|  +------------------------------+  |           |  +------------------------------+  |
|    |           |           |       |           |    |           |           |       |
|    v           v           v       |           |    v           v           v       |
|  Socket 1   Socket 2   Socket N    |           |  Socket 1   Socket 2   Socket N    |
+------------------------------------+           +------------------------------------+
```

1. **Master Process**: Opera bajo privilegios de `root`. Realiza tareas privilegiadas: lee la configuración, valida la sintaxis, se vincula a sockets de red (`:80`, `:443`) y genera procesos worker.
2. **Worker Processes**: Procesos sin privilegios ejecutados bajo `nginx` o `www-data`. Cada worker ejecuta un bucle de eventos (event loop) continuo y no bloqueante aprovechando llamadas al sistema como `epoll_wait()`. Un solo proceso worker puede manejar miles de conexiones simultáneas sin generar hilos adicionales.
3. **File Descriptor Limits**: Cada conexión TCP requiere un socket con un descriptor de archivo dedicado. La cantidad teórica máxima de conexiones por worker está delimitada por `worker_connections` y el `ulimit -n` del sistema (`worker_rlimit_nofile`).

$$\text{Max Client Connections} = \text{worker\_processes} \times \text{worker\_connections}$$
*(Dividido por 2 al actuar como un Reverse Proxy debido a la sobrecarga de conexiones del backend).*

---

### 3.2 Motor del Algoritmo de Coincidencia de Location en NGINX

NGINX evalúa las directivas `location` utilizando una jerarquía de prioridad explícita. **No** se ejecuta simplemente de arriba a abajo.

#### Jerarquía de Prioridad de Resolución:
1. **Coincidencia Exacta de Cadena**: `location = /path` (Terminación inmediata al coincidir)
2. **Coincidencia de Prefijo Preferente**: `location ^~ /path` (Si coincide, detiene el escaneo de regex)
3. **Coincidencia de Expresión Regular**: `location ~ pattern` (Sensible a mayúsculas/minúsculas) o `location ~* pattern` (Insensible a mayúsculas/minúsculas) — evaluadas en orden secuencial del archivo.
4. **Coincidencia de Prefijo Estándar**: `location /path` (Se selecciona la coincidencia de prefijo más larga si no hay coincidencias de regex).

#### Tabla de Verdad de Coincidencia y Lógica de Ejecución:

| Modificador | Tipo de Coincidencia | Prioridad | ¿Detiene el Escaneo al Coincidir? |
| :--- | :--- | :--- | :--- |
| `=` | Coincidencia Exacta | 1 (La más alta) | **Sí** |
| `^~` | Coincidencia de Prefijo Preferente | 2 | **Sí** |
| `~` | Regex Sensible a Mayúsculas | 3 | **Sí** (Gana la primera regex coincidente) |
| `~*` | Regex Insensible a Mayúsculas | 3 | **Sí** (Gana la primera regex coincidente) |
| *(Ninguno)* | Coincidencia de Prefijo Genérica | 4 (La más baja) | **No** (Recuerda la coincidencia más larga, prueba las regex) |

---

### 3.3 Configuración de Reverse Proxy en NGINX para Producción

#### `/etc/nginx/nginx.conf` Completo:

```nginx
# /etc/nginx/nginx.conf
# Complete Syntactically Valid Production Configuration

user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format enterprise_json escape=json
      '{"time_local":"$time_local",'
      '"remote_addr":"$remote_addr",'
      '"request":"$request",'
      '"status": "$status",'
      '"body_bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"upstream_response_time":"$upstream_response_time",'
      '"upstream_addr":"$upstream_addr",'
      '"http_x_forwarded_for":"$http_x_forwarded_for"}';

    access_log /var/log/nginx/access.log enterprise_json;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Upstream Backend Pool definition with Keep-Alive connection pooling
    upstream backend_nodes {
        least_conn;
        server 10.100.1.10:8080 max_fails=3 fail_timeout=10s weight=5;
        server 10.100.1.11:8080 max_fails=3 fail_timeout=10s weight=5;
        server 10.100.1.12:8080 backup;

        # Keepalive connection pool to upstream nodes
        keepalive 32;
    }

    server {
        listen 80;
        server_name api.enterprise.internal;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name api.enterprise.internal;

        ssl_certificate /etc/pki/tls/certs/api_combined.crt;
        ssl_certificate_key /etc/pki/tls/private/api.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        # Static Asset Caching Context
        location ^~ /static/ {
            root /var/www/html/assets;
            expires 30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }

        # Dynamic Application Proxy Context
        location / {
            proxy_pass http://backend_nodes;
            proxy_http_version 1.1;
            
            # Connection reuse headers for HTTP/1.1 upstream keepalive
            proxy_set_header Connection "";
            
            # Client identification headers
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Advanced Buffer Tuning for High Throughput
            proxy_buffering on;
            proxy_buffer_size 8k;
            proxy_buffers 64 8k;
            proxy_busy_buffers_size 16k;

            # Timeouts
            proxy_connect_timeout 5s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
        }
    }
}
```

---

## Módulo 4: Ejercicios Prácticos Guiados de Laboratorio

### Ejercicio 1: Optimización de Apache MPM Event y Ajuste en Vivo

#### Objetivo
Configurar Apache HTTPD 2.4 para usar `mod_mpm_event`, aplicar límites calculados según los recursos, verificar la validez sintáctica y validar las operaciones de hilos utilizando herramientas de diagnóstico nativas de Linux.

#### Pasos Guiados

1. Verifique que `mod_mpm_event` esté cargado actualmente inspeccionando los módulos activos de Apache:
   ```bash
   httpd -M | grep mpm
   # Or on Debian/Ubuntu systems:
   apache2ctl -M | grep mpm
   ```
   *Salida Esperada:*
   ```text
   mpm_event_module (shared)
   ```

2. Abra `/etc/httpd/conf.modules.d/00-mpm.conf` (o `/etc/apache2/mods-available/mpm_event.conf`) en un editor y configure los parámetros correspondientes a un servidor objetivo con 8GB de RAM:
   ```apache
   <IfModule mpm_event_module>
       StartServers             3
       MinSpareThreads         64
       MaxSpareThreads        256
       ThreadLimit             64
       ThreadsPerChild         64
       MaxRequestWorkers     1024
       MaxConnectionsPerChild 5000
   </IfModule>
   ```

3. Realice una comprobación de sintaxis antes de recargar el demonio del sistema:
   ```bash
   apachectl configtest
   ```
   *Salida Esperada:*
   ```text
   Syntax OK
   ```

4. Recargue el servicio systemd para aplicar los cambios estructurales sin interrumpir los sockets activos:
   ```bash
   systemctl reload httpd
   ```

5. Ejecute `ss` para inspeccionar el estado del backlog de la cola de escucha del socket TCP para Apache:
   ```bash
   ss -tlpn '( sport = :80 || sport = :443 )'
   ```
   *Salida Esperada:*
   ```text
   State      Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
   LISTEN     0      511    *:80                *:*               users:(("httpd",pid=10234,fd=3),("httpd",pid=10235,fd=3))
   ```

---

#### Preguntas de Verificación — Ejercicio 1
1. **P1**: ¿Qué sucede si `MaxRequestWorkers` se configura en `1024` pero `ServerLimit` se mantiene en su valor por defecto de `16` con `ThreadsPerChild` configurado en `32`? 
2. **P2**: ¿Por qué `mpm_event` supera el rendimiento de `mpm_worker` al manejar miles de solicitudes de clientes HTTP Keep-Alive de larga duración?

---

### Ejercicio 2: Implementación de Reverse Proxy NGINX y Descarga SSL/TLS (SSL/TLS Offloading)

#### Objetivo
Desplegar un reverse proxy NGINX con un grupo de balanceo de carga upstream, configurar los parámetros de terminación SSL/TLS y verificar la propagación de encabezados de proxy.

#### Pasos Guiados

1. Pruebe la sintaxis de su archivo de configuración de NGINX:
   ```bash
   nginx -t
   ```
   *Salida Esperada:*
   ```text
   nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
   nginx: configuration file /etc/nginx/nginx.conf test is successful
   ```

2. Ejecute un volcado detallado de la configuración de NGINX completamente compilada para verificar los includes cargados:
   ```bash
   nginx -T | grep -E "(server_name|proxy_pass|upstream)"
   ```
   *Salida Esperada:*
   ```text
   upstream backend_nodes {
   server_name api.enterprise.internal;
   proxy_pass http://backend_nodes;
   ```

3. Emita una solicitud `curl` HTTP/2 detallada para verificar la negociación del handshake TLS y los encabezados de respuesta de seguridad personalizados:
   ```bash
   curl -ivk --resolve api.enterprise.internal:443:127.0.0.1 https://api.enterprise.internal/
   ```
   *Fragmento de Salida Esperada:*
   ```text
   * ALPN, offering h2
   * ALPN, offering http/1.1
   * SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
   * Server certificate:
   *  subject: C=US; O=Enterprise; CN=api.enterprise.internal
   > GET / HTTP/2
   > Host: api.enterprise.internal
   > user-agent: curl/7.76.1
   > accept: */*
   > 
   < HTTP/2 200 
   < server: nginx
   < date: Thu, 06 Aug 2026 10:29:24 GMT
   < content-type: text/html
   ```

4. Monitoree la salida de registros estructurados de NGINX en tiempo real usando `tail` para observar el enrutamiento hacia el upstream:
   ```bash
   tail -f /var/log/nginx/access.log
   ```

---

#### Preguntas de Verificación — Ejercicio 2
1. **P1**: En un bloque `upstream` de NGINX, ¿por qué se requiere explícitamente la directiva `proxy_set_header Connection "";` cuando se combina con la directiva `keepalive`?
2. **P2**: Dado los siguientes bloques de location:
   - `location /docs { ... }`
   - `location ~* ^/docs/.*\.html$ { ... }`
   - `location ^~ /docs/api { ... }`
   
   ¿Qué bloque manejará una solicitud para `/docs/api/index.html`? Explique el flujo de evaluación.

---

### Ejercicio 3: Diagnósticos Avanzados y Solución de Cuellos de Botella (Troubleshooting)

#### Objetivo
Diagnosticar la contención de recursos, errores HTTP 502 Bad Gateway y límites de descriptores de archivo utilizando comandos de rastreo del sistema y del estado de la red.

#### Pasos Guiados

1. Simule un límite agotado de descriptores de archivo del proceso revisando los límites del sistema y del proceso:
   ```bash
   cat /proc/$(cat /run/nginx.pid)/limits | grep "Max open files"
   ```
   *Salida Esperada:*
   ```text
   Max open files            65535                65535                files     
   ```

2. Rastree las llamadas al sistema activas ejecutadas por un proceso hijo de Apache bajo carga utilizando `strace`:
   ```bash
   strace -fp $(pgrep -f "httpd" | head -n 1) -e trace=accept4,epoll_wait,read,write
   ```
   *Salida Esperada:*
   ```text
   [pid 10236] epoll_wait(6, [{EPOLLIN, {u32=1, u64=1}}], 32, -1) = 1
   [pid 10236] accept4(3, {sa_family=AF_INET, sin_port=htons(49152), sin_addr=inet_addr("10.50.1.15")}, [16], SOCK_CLOEXEC|SOCK_NONBLOCK) = 4
   [pid 10236] read(4, "GET /index.html HTTP/1.1\r\nHost: "..., 8000) = 158
   [pid 10236] write(4, "HTTP/1.1 200 OK\r\nDate: Thu, 06 A"..., 342) = 342
   ```

3. Rastree las conexiones de socket establecidas con los backends para depurar errores `502 Bad Gateway` de NGINX:
   ```bash
   ss -t unresolved
   # Check state of upstream ports:
   ss -ta | grep -E "(8080|80|443)"
   ```
   *Salida Esperada:*
   ```text
   ESTAB      0      0      10.0.0.1:45322    10.100.1.10:8080
   SYN-SENT   0      1      10.0.0.1:45324    10.100.1.11:8080
   ```

---

#### Preguntas de Verificación — Ejercicio 3
1. **P1**: Si NGINX escribe `1024 worker_connections are not enough` en `/var/log/nginx/error.log`, ¿cuáles dos niveles de configuración independientes deben escalarse para resolver el cuello de botella?
2. **P2**: ¿Qué indica un error `HTTP 504 Gateway Timeout` en una configuración de reverse proxy NGINX, a diferencia de un error `HTTP 502 Bad Gateway`?

---

## Soluciones de los Ejercicios y Explicaciones Técnicas

<details>
<summary>Haga clic para desplegar las soluciones y explicaciones de los ejercicios</summary>

### Soluciones para el Ejercicio 1

- **R1**: Apache limitará automáticamente `MaxRequestWorkers` a `512` (`ServerLimit` × `ThreadsPerChild` = 16 × 32). Apache emitirá una advertencia de configuración al iniciar indicando que `MaxRequestWorkers` excede `ServerLimit` × `ThreadsPerChild` y reducirá `MaxRequestWorkers` para ajustar al límite de capacidad estructural. Para lograr 1024 workers con 32 hilos por hijo, `ServerLimit` debe elevarse explícitamente a `32`.
- **R2**: En `mpm_worker`, cada conexión activa (incluidos los clientes Keep-Alive inactivos) consume un hilo worker completo durante la duración del tiempo de espera (timeout). En `mpm_event`, los sockets Keep-Alive inactivos se transfieren de nuevo a un contexto de hilo listener central no bloqueante mediante `epoll`. Los hilos worker se liberan inmediatamente de vuelta al pool global de workers para atender solicitudes entrantes activas.

---

### Soluciones para el Ejercicio 2

- **R1**: NGINX utiliza por defecto HTTP/1.0 para el proxying hacia el upstream, lo que incluye un encabezado implícito `Connection: close` en las solicitudes enviadas a los servidores backend. La directiva `proxy_set_header Connection "";` elimina la instrucción `close`, permitiendo que las conexiones TCP HTTP/1.1 de larga duración permanezcan abiertas y se agrupen en pool dentro de la cola `keepalive` especificada en el `upstream`.
- **R2**: La solicitud `/docs/api/index.html` será manejada por `location ^~ /docs/api`. 
  - *Flujo de Evaluación*: 
    1. NGINX prueba primero las ubicaciones por prefijo. `/docs` coincide, pero `/docs/api` es una coincidencia de prefijo más larga.
    2. Debido a que `/docs/api` utiliza el modificador de prefijo preferente (`^~`), NGINX finaliza de inmediato la búsqueda de coincidencia de location y omite probar las expresiones regulares (`location ~* ^/docs/.*\.html$`). 
    3. La solicitud se enruta a `location ^~ /docs/api`.

---

### Soluciones para el Ejercicio 3

- **R1**: 
  1. **Nivel de Directiva de NGINX**: Incrementar `worker_connections` dentro del bloque de configuración `events {}` en `/etc/nginx/nginx.conf`.
  2. **Nivel de Descriptores de Archivo del Sistema Operativo**: Incrementar los límites de descriptores de archivo máximos del SO estableciendo `worker_rlimit_nofile` en `/etc/nginx/nginx.conf` y actualizando los límites de seguridad del sistema (`/etc/security/limits.conf` o la unidad de servicio systemd `LimitNOFILE=65535`).
- **R2**: 
  - **HTTP 502 Bad Gateway**: Indica que NGINX pudo conectarse al servidor upstream, pero el servidor upstream rechazó activamente la conexión, cerró el socket TCP prematuramente o devolvió una carga útil de respuesta HTTP inválida o corrupta.
  - **HTTP 504 Gateway Timeout**: Indica que NGINX estableció con éxito una conexión TCP con el backend upstream, pero el upstream no envió una carga útil de respuesta HTTP dentro del límite de tiempo configurado (`proxy_read_timeout`).

</details>