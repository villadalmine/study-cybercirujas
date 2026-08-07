# Technical Deep-Dive & Guided Exercises: LPI 030-100 Topic 1.3 – HTTP Basics

**Target Certification:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic:** 1.3 HTTP Basics  
**Exam Weight:** 7.5  
**Level:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Official References & Standards

* **LPI Web Development Essentials Overview:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **IETF RFC 9110 – HTTP Semantics:** [https://www.rfc-editor.org/rfc/rfc9110](https://www.rfc-editor.org/rfc/rfc9110)
* **IETF RFC 9112 – HTTP/1.1 Specification:** [https://www.rfc-editor.org/rfc/rfc9112](https://www.rfc-editor.org/rfc/rfc9112)
* **IETF RFC 6265 – HTTP State Management Mechanism (Cookies):** [https://www.rfc-editor.org/rfc/rfc6265](https://www.rfc-editor.org/rfc/rfc6265)
* **IETF RFC 8446 – The Transport Layer Security (TLS) Protocol Version 1.3:** [https://www.rfc-editor.org/rfc/rfc8446](https://www.rfc-editor.org/rfc/rfc8446)

---

## 2. Architecture & Mechanical Foundations

Hypertext Transfer Protocol (HTTP) es un protocolo de la capa de aplicación situado en la Capa 7 del modelo OSI. Se basa en un patrón de mensajería de solicitud-respuesta sobre un flujo confiable de la capa de transporte (típicamente TCP en la Capa 4, puerto 80 para HTTP en texto plano o puerto 443 para HTTPS).

```
+-----------------------------------------------------------------------+
|                     Layer 7: Application (HTTP/1.1)                   |
| Request Line / Status Line | Headers (CRLF) | Empty Line | Message Body|
+-----------------------------------------------------------------------+
|                    Layer 6/5: Security (TLS 1.2 / TLS 1.3)            |
|       ClientHello -> ServerHello -> Certificate -> Handshake Complete |
+-----------------------------------------------------------------------+
|                     Layer 4: Transport (TCP Protocol)                 |
|                   SYN -> SYN-ACK -> ACK (3-Way Handshake)              |
+-----------------------------------------------------------------------+
|                     Layer 3: Network (IP Routing & Packets)           |
+-----------------------------------------------------------------------+
```

### 2.1 Protocol Framing & Wire Syntax (RFC 9112)
HTTP/1.1 se basa en un enmarcado basado en texto ASCII estructurado con secuencias explícitas de retorno de carro (`\r`, ASCII 13) y salto de línea (`\n`, ASCII 10) (`CRLF`).

* **HTTP Request Frame Structure:**
  1. **Request-Line:** `METHOD` + `SP` + `Request-URI` + `SP` + `HTTP-Version` + `CRLF` (por ejemplo, `GET /api/v1/health HTTP/1.1\r\n`)
  2. **Header Fields:** `Field-Name` + `:` + `SP` + `Field-Value` + `CRLF`
  3. **Empty Line:** `CRLF` (Señala el final de los headers)
  4. **Message Body (Optional):** Octetos crudos cuya longitud está definida por `Content-Length` o `Transfer-Encoding: chunked`.

* **HTTP Response Frame Structure:**
  1. **Status-Line:** `HTTP-Version` + `SP` + `Status-Code` + `SP` + `Reason-Phrase` + `CRLF` (por ejemplo, `HTTP/1.1 200 OK\r\n`)
  2. **Header Fields:** `Field-Name` + `:` + `SP` + `Field-Value` + `CRLF`
  3. **Empty Line:** `CRLF`
  4. **Message Body (Optional):** Datos del payload.

### 2.2 Method Semantics: Safety and Idempotency
Comprender las propiedades de los métodos es vital para la arquitectura de API, la estrategia de caching y la lógica de reintento en sistemas distribuidos:

* **Safe Methods:** Métodos que no modifican el estado del servidor (read-only).  
  * *Ejemplos:* `GET`, `HEAD`, `OPTIONS`.
* **Idempotent Methods:** Métodos donde múltiples solicitudes idénticas producen los mismos efectos secundarios en el estado del servidor que una sola solicitud.  
  * *Ejemplos:* `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`, `TRACE`.
* **Non-Idempotent / Unsafe Methods:** Operaciones donde repetir solicitudes causa efectos secundarios acumulativos.  
  * *Ejemplos:* `POST`, `PATCH`.

| Method | Safe | Idempotent | Request Body Allowed | Primary Production Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `GET` | **Yes** | **Yes** | No (Ignored) | Obtener la representación del recurso |
| `HEAD` | **Yes** | **Yes** | No | Obtener solo los headers (health checks / validación de cache) |
| `POST` | **No** | **No** | **Yes** | Crear subrecurso / procesar datos |
| `PUT` | **No** | **Yes** | **Yes** | Reemplazar recurso completamente (o crear en una URI explícita) |
| `PATCH` | **No** | **No** | **Yes** | Aplicar modificaciones parciales a un recurso |
| `DELETE` | **No** | **Yes** | Optional | Eliminar el recurso objetivo |
| `OPTIONS`| **Yes** | **Yes** | Optional | Consultar capacidad del servidor / CORS preflight |

### 2.3 HTTP Status Code Classification (RFC 9110)
Los Status codes son enteros de 3 dígitos categorizados en cinco rangos:

1. **`1xx` Informational:** Solicitud recibida, continuando el proceso. (por ejemplo, `100 Continue`, `101 Switching Protocols`).
2. **`2xx` Successful:** Acción recibida, entendida y aceptada exitosamente.
   * `200 OK`: Respuesta de éxito estándar.
   * `201 Created`: Recurso creado exitosamente (debe retornar un header `Location`).
   * `204 No Content`: Acción ejecutada exitosamente; el cuerpo de la respuesta está explícitamente vacío.
3. **`3xx` Redirection:** El cliente debe tomar acciones adicionales.
   * `301 Moved Permanently`: Redirección permanente; los motores de búsqueda y clientes almacenan en cache esta ubicación a largo plazo.
   * `302 Found`: Redirección temporal (comportamiento legacy).
   * `304 Not Modified`: El header de solicitud conditional GET (`If-None-Match`/`If-Modified-Since`) validó una coincidencia; el cuerpo está vacío para ahorrar ancho de banda.
   * `307 Temporary Redirect` / `308 Permanent Redirect`: Redirecciones modernas que preservan el método HTTP original y el cuerpo.
4. **`4xx` Client Error:** La solicitud contiene sintaxis incorrecta o no se puede cumplir.
   * `400 Bad Request`: Sintaxis malformada o validación de payload inválida.
   * `401 Unauthorized`: Credencial de autenticación faltante o inválida (requiere `WWW-Authenticate`).
   * `403 Forbidden`: Autenticación exitosa, pero el permiso de autorización/RBAC es denegado.
   * `404 Not Found`: La URI del recurso objetivo no existe.
   * `405 Method Not Allowed`: Método HTTP no soportado para el recurso objetivo (requiere el header `Allow`).
   * `429 Too Many Requests`: Umbral de rate-limiting superado.
5. **`5xx` Server Error:** El servidor falló al cumplir una solicitud aparentemente válida.
   * `500 Internal Server Error`: Excepción de aplicación no manejada.
   * `502 Bad Gateway`: El servidor upstream retornó un payload inválido al ingress controller/proxy.
   * `503 Service Unavailable`: Servidor fuera de servicio por mantenimiento o sobrecarga de capacidad (a menudo combinado con `Retry-After`).
   * `504 Gateway Timeout`: Timeout de conexión/lectura del proxy mientras esperaba la respuesta del upstream.

---

## 3. Hands-On Guided Lab Exercises

### Exercise 1: Crafting Raw HTTP/1.1 Request/Response Frames via Netcat (`nc`)

#### Task Goal
Construir manualmente un payload de socket HTTP/1.1 sintácticamente válido usando `netcat` para observar la terminación de línea CRLF, headers `Host` obligatorios y el comportamiento de la conexión keep-alive de HTTP.

#### Step-by-Step Instructions

1. Abrí tu terminal e iniciá una conexión TCP en texto plano a un servidor HTTP usando `nc` (o `ncat`):
```bash
nc -C httpbin.org 80
```
*(Nota: `-C` asegura que `CRLF` (`\r\n`) sea transmitido en los saltos de línea).*

2. Escribí manualmente la línea de solicitud y los headers de HTTP en estado puro. Presioná `Enter` dos veces después del último header para enviar la línea vacía `\r\n`:
```http
GET /ip HTTP/1.1
Host: httpbin.org
User-Agent: ManualSREClient/1.0
Accept: application/json
Connection: close

```

#### Expected CLI Output
```http
HTTP/1.1 200 OK
Date: Thu, 06 Aug 2026 18:50:00 GMT
Content-Type: application/json
Content-Length: 33
Connection: close
Server: gunicorn/19.9.0
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true

{
  "origin": "203.0.113.45"
}
```

#### Step Verification Questions

**Question 1.1:** ¿Qué sucede si omitís el header `Host: httpbin.org` en una solicitud HTTP/1.1 cruda al comunicarte con un servidor web o proxy de virtual-hosting moderno?  
**Question 1.2:** ¿Por qué la línea vacía final (`\r\n\r\n`) es estrictamente requerida por la RFC 9112 después de los request headers?

---

### Exercise 2: Inspecting Method Semantics, Idempotency, and Headers via `curl`

#### Task Goal
Usar `curl` en modo verboso (`-v`) para observar líneas de solicitud, status codes (`201 Created`, `405 Method Not Allowed`), response headers y límites de payload a través de diferentes métodos HTTP.

#### Step-by-Step Instructions

1. **Ejecutar una solicitud `GET` condicional** para inspeccionar la mecánica del control de cache (`304 Not Modified` vs `200 OK`):
```bash
curl -v -H "If-None-Match: \"123456789\"" https://httpbin.org/etag/123456789
```

##### Expected Output Snippet
```http
> GET /etag/123456789 HTTP/1.1
> Host: httpbin.org
> User-Agent: curl/8.5.0
> Accept: */*
> If-None-Match: "123456789"
> 
< HTTP/1.1 304 NOT MODIFIED
< Date: Thu, 06 Aug 2026 18:50:00 GMT
< Connection: keep-alive
< ETag: "123456789"
< Access-Control-Allow-Origin: *
```

2. **Enviar una solicitud `POST` con datos JSON** para observar la semántica del header `Content-Type` y un status code `200 OK` / `201 Created`:
```bash
curl -v -X POST https://httpbin.org/post \
  -H "Content-Type: application/json" \
  -d '{"environment": "production", "service": "payment-gateway"}'
```

##### Expected Output Snippet
```http
> POST /post HTTP/1.1
> Host: httpbin.org
> User-Agent: curl/8.5.0
> Accept: */*
> Content-Type: application/json
> Content-Length: 59
> 
* upload completely sent off: 59 bytes
< HTTP/1.1 200 OK
< Content-Type: application/json
< Content-Length: 512
...
```

3. **Emitir una solicitud con un método no soportado** para activar una respuesta HTTP `405 Method Not Allowed`:
```bash
curl -v -X DELETE https://httpbin.org/get
```

##### Expected Output Snippet
```http
> DELETE /get HTTP/1.1
> Host: httpbin.org
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 405 METHOD NOT ALLOWED
< Date: Thu, 06 Aug 2026 18:50:00 GMT
< Content-Type: text/html
< Content-Length: 178
< Allow: GET, OPTIONS, HEAD
```

#### Step Verification Questions

**Question 2.1:** ¿Qué header debe retornar un servidor junto con el código de respuesta `405 Method Not Allowed` según la RFC 9110, y por qué es crítico para el auto-descubrimiento del cliente?  
**Question 2.2:** Un cliente de API intenta realizar reintentos de red después de recibir timeouts de red. ¿Por qué el cliente puede reintentar de manera segura una solicitud `PUT` fallida automáticamente, pero NO DEBE reintentar automáticamente una solicitud `POST` fallida sin una estructura de transacción explícita en el cliente?

---

### Exercise 3: State Management & Session Lifecycle Mechanics (Cookies vs. Tokens)

#### Task Goal
Analizar los mecanismos de extensión del protocolo HTTP sin estado: estado tradicional del lado del servidor usando directivas `Set-Cookie` (con flags `HttpOnly`, `Secure` y `SameSite`) frente a headers de autorización sin estado usando JSON Web Tokens (JWT).

#### Step-by-Step Instructions

1. **Simular un servidor estableciendo una cookie de sesión segura:**
```bash
curl -v https://httpbin.org/cookies/set?session_id=sre_sess_abc123987
```

##### Expected Output Snippet
```http
> GET /cookies/set?session_id=sre_sess_abc123987 HTTP/1.1
> Host: httpbin.org
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 302 FOUND
< Date: Thu, 06 Aug 2026 18:50:00 GMT
< Location: /cookies
< Set-Cookie: session_id=sre_sess_abc123987; Path=/
```

2. **Simular autenticación sin estado basada en tokens** usando un header `Authorization`:
```bash
curl -v -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlNSRUVuZ2luZWVyIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" \
  https://httpbin.org/headers
```

##### Expected Output Snippet
```http
> GET /headers HTTP/1.1
> Host: httpbin.org
> User-Agent: curl/8.5.0
> Accept: */*
> Authorization: Bearer eyJhbGciOiJIUzI1...
> 
< HTTP/1.1 200 OK
< Content-Type: application/json
```

#### Step Verification Questions

**Question 3.1:** ¿Qué vulnerabilidades de seguridad mitigan los atributos `HttpOnly`, `Secure` y `SameSite=Strict` cuando se configuran en un response header `Set-Cookie`?  
**Question 3.2:** ¿Cómo difiere la gestión de estado arquitectónicamente entre cookies basadas en sesión almacenadas en memoria/Redis en el backend frente a Bearer Tokens sin estado en el header `Authorization`?

---

### Exercise 4: TLS Handshake, SNI, and HTTPS Traffic Diagnostics with OpenSSL

#### Task Goal
Desacoplar el establecimiento de la conexión TCP de Capa 4 de los handshakes criptográficos TLS 1.3 de Capa 6. Inspeccionar la negociación de Server Name Indication (SNI) y las cadenas de certificados TLS usando `openssl s_client`.

#### Step-by-Step Instructions

1. Ejecutar una conexión de diagnóstico de OpenSSL a un endpoint HTTPS para observar el handshake de TLS:
```bash
openssl s_client -connect httpbin.org:443 -servername httpbin.org -tls1_3
```

#### Expected CLI Output
```text
CONNECTED(00000003)
---
Certificate chain
 0 s:CN = httpbin.org
   i:C = US, O = Let's Encrypt, CN = R3
   a:PKEY: rsaEncryption, 2048 (bits); conds: e=65537
---
Server certificate
-----BEGIN CERTIFICATE-----
MIIF... [Truncated Base64 Certificate Content] ...
-----END CERTIFICATE-----
subject=CN = httpbin.org
issuer=C = US, O = Let's Encrypt, CN = R3
---
No ALPN negotiated
Early data was not sent
Verify return code: 0 (ok)
---
SSL handshake has read 3012 bytes and written 380 bytes
Verification: OK
---
Re-negotiation handshake type: TLSv1.3
Server public key is 2048 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
Default protocol : TLSv1.3
Cipher           : TLS_AES_256_GCM_SHA384
```

2. Una vez conectado, escribí una solicitud GET de HTTP/1.1 cruda sobre el socket cifrado:
```http
GET /user-agent HTTP/1.1
Host: httpbin.org
Connection: close

```

#### Expected CLI Output
```http
HTTP/1.1 200 OK
Date: Thu, 06 Aug 2026 18:50:00 GMT
Content-Type: application/json
Content-Length: 42
Connection: close
Server: gunicorn/19.9.0

{
  "user-agent": "openssl s_client"
}
closed
```

#### Step Verification Questions

**Question 4.1:** ¿Qué rol desempeña Server Name Indication (SNI) durante el handshake TLS antes de enviar el header `Host` de HTTP?  
**Question 4.2:** ¿Por qué la inspección de tráfico HTTP mediante sniffers de paquetes de red (`tcpdump`/`wireshark`) no es legible en el puerto 443 sin acceso a las claves de sesión o claves privadas?

---

### Exercise 5: Reverse Proxy Header Propagation & Diagnostic Packet Capture

#### Task Goal
Examinar cómo los reverse proxies (por ejemplo, NGINX, HAProxy, Ingress Controllers) alteran los headers HTTP durante el reenvío de tráfico, y capturar paquetes HTTP crudos utilizando `tshark` o `tcpdump`.

#### Production Manifest: NGINX Reverse Proxy Configuration
A continuación se presenta un bloque de configuración de reverse proxy de NGINX de producción sintácticamente válido, diseñado para reenviar las direcciones IP de los clientes y los metadatos del protocolo a los clusters de aplicaciones upstream.

```nginx
# /etc/nginx/conf.d/sre_reverse_proxy.conf
upstream application_backend {
    server 127.0.0.1:8080 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 80 default_server;
    server_name proxy.example.internal;

    # Harden Server Tokens
    server_tokens off;

    location / {
        proxy_pass http://application_backend;

        # Preserve HTTP/1.1 Keep-Alive connections to upstream
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Standard Forwarded Headers (RFC 7239 / De-Facto Standards)
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # Timeouts for Gateway reliability
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
```

#### Step-by-Step Packet Diagnostics Instructions

1. Iniciar `tshark` en tu interfaz de red local para capturar headers HTTP en texto plano:
```bash
sudo tshark -i any -n -Y "http.request or http.response" -T fields \
  -e frame.time_relative -e ip.src -e ip.dst -e http.request.method \
  -e http.request.uri -e http.response.code
```

2. Generar tráfico en una segunda terminal:
```bash
curl -s http://httpbin.org/get > /dev/null
```

#### Expected CLI Output
```text
0.000000000 192.168.1.100 -> 34.233.208.115 GET /get 
0.142312984 34.233.208.115 -> 192.168.1.100   200
```

#### Step Verification Questions

**Question 5.1:** ¿Por qué una aplicación web upstream debe confiar en el header `X-Forwarded-For` ÚNICAMENTE si proviene de una dirección IP de reverse proxy interno verificada?  
**Question 5.2:** ¿Qué problema operativo de SRE surge si se omiten `proxy_http_version 1.1` y `proxy_set_header Connection ""` al realizar el proxying de solicitudes a un cluster de microservicios upstream?

---

## 4. Solutions & Technical Explanations

<details>
<summary><strong>Hacé clic para desplegar la Clave de Soluciones y Explicaciones Técnicas Detalladas</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:**  
  De acuerdo con la **RFC 9112 Sección 3.2**, HTTP/1.1 requiere el campo de header `Host` en todas las solicitudes. Si el header `Host` falta o está vacío, los servidores web modernos y reverse proxies (por ejemplo, NGINX, Apache, Cloudflare) DEBEN rechazar la solicitud con un status code **`HTTP/1.1 400 Bad Request`**. El header `Host` permite que un solo servidor web que comparte una única dirección IP aloje cientos de dominios distintos (Virtual Hosting).

* **Answer 1.2:**  
  La especificación del enmarcado HTTP utiliza `CRLFCRLF` (`\r\n\r\n`) como un delimitador de límite. El primer `\r\n` finaliza la última línea del header HTTP. El segundo `\r\n` produce una línea vacía, lo cual instruye inequívocamente al parser de HTTP que la sección de headers está completa y que cualquier octeto subsiguiente representa el cuerpo del mensaje (si lo dicta `Content-Length` o `Transfer-Encoding`).

---

### Exercise 2 Solutions

* **Answer 2.1:**  
  De acuerdo con la **RFC 9110 Sección 15.5.6**, cuando un servidor retorna `405 Method Not Allowed`, **DEBE generar un campo de header `Allow`** en la respuesta. El header `Allow` enumera el conjunto de métodos HTTP soportados actualmente por el recurso objetivo (por ejemplo, `Allow: GET, POST, HEAD`). Esto permite que los clientes y crawlers web automatizados descubran dinámicamente las capacidades soportadas sin adivinar.

* **Answer 2.2:**  
  `PUT` es un método **idempotente**. Reemplazar un recurso en `/api/v1/users/123` diez veces con el mismo payload idéntico produce exactamente el mismo estado del servidor que ejecutarlo una sola vez. Por lo tanto, la lógica de reintento automatizada de SRE puede volver a emitir solicitudes `PUT` fallidas al encontrar desconexiones de red TCP.  
  `POST`, sin embargo, es **no idempotente**. Reintentar una solicitud `POST /api/v1/charges` después de un timeout del cliente corre el riesgo de crear operaciones duplicadas en el backend (por ejemplo, cobrarle dos veces a la tarjeta de crédito de un cliente). Los reintentos automáticos de solicitudes no idempotentes requieren un patrón de header **Idempotency-Key** a nivel de aplicación.

---

### Exercise 3 Solutions

* **Answer 3.1:**  
  * `HttpOnly`: Impide que los scripts del lado del cliente (por ejemplo, JavaScript `document.cookie`) accedan a la cookie, mitigando el secuestro de sesión mediante **Cross-Site Scripting (XSS)**.
  * `Secure`: Instruye al navegador para transmitir la cookie **únicamente a través de conexiones HTTPS** cifradas, evitando filtraciones en texto plano sobre redes no seguras (escucha clandestina en Wi-Fi).
  * `SameSite=Strict`: Restringe al navegador el envío de la cookie en solicitudes entre sitios cruzados (cross-site), mitigando ataques de **Cross-Site Request Forgery (CSRF)**.

* **Answer 3.2:**  
  * **Session-Based Cookies (Stateful):** El cliente almacena un identificador de sesión en una cookie. El estado real (perfil de usuario, permisos, datos de sesión) se mantiene en la memoria del servidor o en una base de datos centralizada (por ejemplo, Redis). La invalidación es instantánea (eliminar la clave de Redis), pero requiere overhead de búsqueda en el backend en cada solicitud HTTP.
  * **Bearer Tokens / JWTs (Stateless):** El cliente transmite un token firmado criptográficamente (que contiene declaraciones de identidad) en el header `Authorization: Bearer <token>`. El backend verifica la firma criptográfica sin consultar una base de datos. Esto se escala horizontalmente a través de microservicios, pero la revocación inmediata antes del vencimiento del token es difícil sin mantener una lista negra de tokens.

---

### Exercise 4 Solutions

* **Answer 4.1:**  
  Server Name Indication (**SNI**) es una extensión del protocolo TLS (Capa 6) enviada dentro del mensaje inicial `ClientHello` en texto plano. Debido a que la negociación TLS ocurre *antes* de que comience la sesión HTTP cifrada (y por lo tanto *antes* de que se pueda enviar el header `Host` de HTTP), SNI informa al servidor TLS qué certificado de dominio presentar al cliente. Sin SNI, los servidores que alojan múltiples certificados TLS en una sola dirección IP no podrían elegir el certificado correcto durante el handshake de TLS.

* **Answer 4.2:**  
  TLS 1.3 cifra todos los datos de la aplicación de Capa 7 (incluidos métodos HTTP, headers, URIs, cookies y cuerpos) utilizando claves de cifrado simétricas establecidas durante el intercambio de claves TLS (por ejemplo, Elliptic-curve Diffie-Hellman). Los sniffers de paquetes como `tcpdump` solo pueden inspeccionar octetos de payload TCP, que aparecen como texto cifrado ilegible sin las claves de sesión.

---

### Exercise 5 Solutions

* **Answer 5.1:**  
  Los headers HTTP pueden ser falsificados (spoofing) fácilmente por actores maliciosos externos. Si un atacante envía una solicitud directamente a un nodo ingress que contiene un header falso como `X-Forwarded-For: 8.8.8.8`, una aplicación de backend que no desconfíe podría tratar a `8.8.8.8` como la dirección IP de origen legítima, eludiendo filtros de autenticación o rate-limiting basados en IP. Las aplicaciones upstream deben despojar o sobrescribir `X-Forwarded-For` a menos que la solicitud se origine desde una dirección IP de proxy interno de confianza.

* **Answer 5.2:**  
  Por defecto, los motores de proxy (como NGINX) usan HTTP/1.0 para las solicitudes upstream y envían `Connection: close`. Esto hace que el proxy abra y cierre una nueva conexión TCP hacia el servicio de aplicación upstream para cada solicitud entrante. Bajo carga pesada, esto provoca la **agotación de puertos TCP (desbordamiento del bucket TIME_WAIT)**, un consumo excesivo de CPU por handshakes TCP, degradación de la latencia y posibles errores `502 Bad Gateway`. Utilizar `proxy_http_version 1.1` y limpiar el header `Connection` habilita el pooling de conexiones TCP persistentes (`keepalive`).

</details>