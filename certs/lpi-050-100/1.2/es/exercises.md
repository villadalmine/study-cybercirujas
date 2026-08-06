# LPI Open Source Essentials (050-100) — Topic 1.2: Arquitectura de Software

## Fuentes de Referencia Oficiales
- [LPI Open Source Essentials Overview & Objectives](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## Análisis Arquitectónico Profundo y Contexto Mecánico

La ingeniería de software moderna se basa en patrones arquitectónicos bien definidos para determinar cómo se distribuyen el cómputo, la gestión de estado, las redes y el procesamiento de datos a través de los nodos.

```
       +-----------------------------------------------------------------------+
       |                         CLIENT COMPUTING LAYER                        |
       |                                                                       |
       |   +--------------------------+          +-------------------------+   |
       |   |  Thin Client (Browser)   |          | Thick/Fat Client (CLI)  |   |
       |   |   - UI Rendering         |          |  - Local Data Validation|   |
       |   |   - Minimal State        |          |  - Heavy Local Processing|  |
       |   +------------+-------------+          +------------+------------+   |
       +----------------|-------------------------------------|----------------+
                        | HTTP/HTTPS                          | REST API
                        v                                     v
       +-----------------------------------------------------------------------+
       |                      APPLICATION & GATEWAY LAYER                      |
       |                                                                       |
       |   +---------------------------------------------------------------+   |
       |   |  Reverse Proxy / Ingress Gateway (e.g., NGINX / Envoy)       |   |
       |   |   - TLS Termination, Routing, Static SPA Hosting              |   |
       |   +-------------------------------+-------------------------------+   |
       +-----------------------------------|-----------------------------------+
                                           v HTTP / gRPC
       +-----------------------------------------------------------------------+
       |                        BACKEND SERVICES LAYER                         |
       |                                                                       |
       |   +-------------------------+           +-------------------------+   |
       |   |   API Microservice A    | <-------> |   API Microservice B    |   |
       |   |  (Stateless Processing) |   gRPC    |   (Domain Logic Engine) |   |
       |   +------------+------------+           +------------+------------+   |
       +----------------|-------------------------------------|----------------+
                        v SQL                                 v Redis Protocol
       +-----------------------------------------------------------------------+
       |                         DATA & STORAGE LAYER                          |
       |   +-------------------------+           +-------------------------+   |
       |   | PostgreSQL Database     |           | Redis In-Memory Cache   |   |
       |   +-------------------------+           +-------------------------+   |
       +-----------------------------------------------------------------------+
```

### Paradigmas Arquitectónicos Clave y Trade-offs

1. **Modelo Client-Server**: Separa la capa de presentación del usuario (Client) del almacenamiento de datos y el cómputo central del negocio (Server).
2. **Thin Clients vs. Thick (Fat) Clients**:
   - *Thin Client*: Realiza una ejecución local mínima; depende casi por completo del servidor remoto para el procesamiento y la lógica de negocio (por ejemplo, un navegador web estándar renderizando HTML estático o una terminal a través de SSH). *Trade-off*: Baja utilización de recursos del cliente, pero alta dependencia de la red y sensibilidad al ancho de banda.
   - *Thick/Fat Client*: Ejecuta lógica significativa, procesamiento de datos y validación de forma local antes de interactuar con el almacenamiento remoto o las APIs (por ejemplo, IDEs, aplicaciones de escritorio, herramientas de CLI pesadas). *Trade-off*: Funciona offline o con conectividad de red degradada, pero consume altos recursos locales de cómputo/memoria e introduce desafíos de sincronización de actualizaciones del cliente.
3. **Multi-Page Applications (MPAs) vs. Single-Page Applications (SPAs)**:
   - *MPA*: Cada disparador de navegación solicita al servidor renderizar y devolver una página HTML completa. *Trade-off*: Gestión de estado simple y SEO inicial fuerte, pero mayor sobrecoste de renderizado en el servidor y latencia de refresco de página.
   - *SPA*: Carga un único esqueleto HTML y un bundle de JavaScript una sola vez. Las mutaciones de UI y actualizaciones posteriores ocurren dinámicamente al obtener el payload de datos puros (JSON) mediante solicitudes de API asíncronas del lado del cliente (AJAX/Fetch). *Trade-off*: Alto tiempo de carga inicial, pero experiencia de usuario fluida, menor consumo de ancho de banda y APIs de backend desacopladas.
4. **Application Programming Interfaces (APIs)**: Contratos estandarizados (por ejemplo, REST sobre HTTP/JSON, gRPC sobre HTTP/2) que permiten que los sistemas desacoplados se comuniquen.

---

## Ejercicios Guiados Prácticos

### Ejercicio 1: Analizando la Arquitectura Client-Server y el Procesamiento de Thin vs. Thick Client

En este ejercicio, desplegarás una API de backend ligera y simularás tanto un patrón de **Thin Client** (renderizado del lado del servidor y cálculo de respuestas) como un patrón de **Thick/Fat Client** (procesamiento local de conjuntos de datos puros obtenidos a través de la API).

#### Paso 1.1: Desplegar el Servidor de API Backend
Crea un archivo llamado `server.py` que contenga un servidor HTTP de producción basado en la librería estándar de Python:

```python
#!/usr/bin/env python3
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

DATASET = [
    {"id": 1, "name": "web-node-01", "cpu_usage": 88.5, "status": "WARN"},
    {"id": 2, "name": "db-node-01", "cpu_usage": 42.1, "status": "OK"},
    {"id": 3, "name": "api-node-01", "cpu_usage": 94.2, "status": "CRITICAL"},
    {"id": 4, "name": "cache-node-01", "cpu_usage": 12.0, "status": "OK"}
]

class ArchitectureDemoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/thin-client-render":
            # Thin client endpoint: Server does calculation & returns formatted presentation
            critical_nodes = [n["name"].upper() for n in DATASET if n["cpu_usage"] > 85.0]
            html_output = f"<html><body><h1>System Alerts</h1><p>Critical Nodes: {', '.join(critical_nodes)}</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(html_output.encode('utf-8'))
        elif self.path == "/api/v1/metrics":
            # Thick client endpoint: Server returns raw structured data payload
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(DATASET).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    server = HTTPServer(('127.0.0.1', 8080), ArchitectureDemoHandler)
    print("[+] Server active on http://127.0.0.1:8080")
    server.serve_forever()
```

Ejecuta el servidor en segundo plano:
```bash
python3 server.py &
```
*Salida esperada:*
```text
[+] Server active on http://127.0.0.1:8080
```

#### Paso 1.2: Ejecutar la Solicitud de Thin Client
Simula un Thin Client obteniendo una capa de presentación completamente renderizada desde el servidor:
```bash
curl -i -X GET http://127.0.0.1:8080/thin-client-render
```
*Salida esperada:*
```text
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
Content-Type: text/html

<html><body><h1>System Alerts</h1><p>Critical Nodes: WEB-NODE-01, API-NODE-01</p></body></html>
```

#### Paso 1.3: Ejecutar el Procesamiento de Thick (Fat) Client
Ejecuta un comando donde el cliente obtiene JSON estructurado puro desde la API y ejecuta filtrado, ordenamiento y transformación localmente usando `jq`:

```bash
curl -s http://127.0.0.1:8080/api/v1/metrics | jq '.[] | select(.cpu_usage > 85.0) | {node: .name, load: .cpu_usage}'
```
*Salida esperada:*
```json
{
  "node": "web-node-01",
  "load": 88.5
}
{
  "node": "api-node-01",
  "load": 94.2
}
```

#### Preguntas de Verificación — Ejercicio 1
1. En el Paso 1.2, ¿qué componente realizó la lógica de filtrado para `cpu_usage > 85.0`?
2. En el Paso 1.3, si 10,000 usuarios ejecutan el filtro `jq` de forma concurrente en sus estaciones de trabajo locales, ¿cómo se compara el consumo de CPU en el servidor de API con respecto al Paso 1.2?
3. Nombra una ventaja clave de seguridad operacional que posee el modelo Thin Client sobre un modelo Thick Client al manejar lógica de negocio empresarial sensible.

---

### Ejercicio 2: Entrega Web de Single-Page Application (SPA) vs. Multi-Page Application (MPA)

En este ejercicio, construirás un manifiesto de host virtual de NGINX de producción configurado para alojar una **Single-Page Application (SPA)** con enrutamiento de fallback por URI, lo compararás con el enrutamiento de MPA y verificarás las características de entrega HTTP.

#### Paso 2.1: Inspeccionar el Manifiesto Index de la SPA
Crea el directorio `/tmp/spa-root` y un archivo `index.html` que represente el shell de la SPA del lado del cliente:

```bash
mkdir -p /tmp/spa-root
```

Crea `/tmp/spa-root/index.html`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Production SPA</title>
</head>
<body>
    <div id="app">Loading application...</div>
    <script>
        // Client-side Router Mechanics
        function renderRoute() {
            const path = window.location.pathname;
            const app = document.getElementById('app');
            if (path === '/dashboard') {
                app.innerHTML = '<h1>Dashboard View</h1><p>Client-side rendered.</p>';
            } else if (path === '/settings') {
                app.innerHTML = '<h1>Settings View</h1><p>Client-side rendered.</p>';
            } else {
                app.innerHTML = '<h1>Home View</h1><p>Client-side rendered.</p>';
            }
        }
        window.addEventListener('popstate', renderRoute);
        window.onload = renderRoute;
    </script>
</body>
</html>
```

#### Paso 2.2: Configurar NGINX Reverse Proxy para Enrutamiento Fallback de SPA
Crea `/tmp/nginx-spa.conf` con sintaxis de NGINX completa y sintácticamente válida para forzar el fallback de rutas del lado del cliente mediante `try_files`:

```nginx
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    server {
        listen 8090;
        server_name localhost;
        root /tmp/spa-root;

        # SPA Routing Directive: If requested file/dir doesn't exist, fall back to index.html
        location / {
            try_files $uri $uri/ /index.html;
        }

        # API Reverse Proxy Directive (Decoupled Backend)
        location /api/ {
            proxy_pass http://127.0.0.1:8080/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
```

Inicia NGINX usando esta configuración:
```bash
nginx -c /tmp/nginx-spa.conf
```

#### Paso 2.3: Verificar la Mecánica de Fallback URI de la SPA
Ejecuta solicitudes HTTP contra las rutas estáticas no existentes `/dashboard` y `/settings`:

```bash
curl -i http://127.0.0.1:8090/dashboard
```
*Salida esperada:*
```text
HTTP/1.1 200 OK
Server: nginx/1.x.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
Content-Type: text/html
Content-Length: 765
...

<!DOCTYPE html>
<html lang="en">
...
```

Observa que `/dashboard` devuelve `HTTP 200 OK` con el contenido de `index.html` en lugar de un error HTTP 404.

#### Preguntas de Verificación — Ejercicio 2
1. ¿Por qué NGINX requiere la directiva `try_files $uri $uri/ /index.html;` al servir Single-Page Applications (SPAs)? ¿Qué sucedería si un usuario refrescara el navegador mientras navega a `/dashboard` sin esta directiva?
2. En una Multi-Page Application (MPA), ¿qué maneja las transiciones de rutas, como hacer clic en un enlace a `/settings`?
3. Describe el impacto de las SPAs en la latencia de carga inicial en comparación con la latencia de visualización de páginas posteriores.

---

### Ejercicio 3: Arquitectura de API, Restricciones REST y Cumplimiento de Contrato OpenAPI

En este ejercicio, interactuarás con un servicio de API RESTful, validarás verbos HTTP, inspeccionarás formatos de payload y analizarás especificaciones de esquema de API.

#### Paso 3.1: Interactuar con Endpoints RESTful a través de CLI HTTP
Usa `curl` para realizar llamadas operacionales CRUD contra un servicio de API y observa la mecánica de los encabezados y los códigos de estado.

1. Obtener la colección de recursos:
```bash
curl -i -H "Accept: application/json" http://127.0.0.1:8080/api/v1/metrics
```
*Salida esperada:*
```text
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
Content-Type: application/json

[{"id": 1, "name": "web-node-01", "cpu_usage": 88.5, "status": "WARN"}, ...]
```

2. Solicitar una ruta de API inválida para observar el manejo de errores del protocolo HTTP:
```bash
curl -i http://127.0.0.1:8080/api/v1/undefined-resource
```
*Salida esperada:*
```text
HTTP/1.0 404 Not Found
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
...
```

#### Paso 3.2: Analizar un Manifiesto de Esquema OpenAPI 3.0 (Swagger)
Examina la especificación de OpenAPI de producción a continuación (`openapi.json`), la cual formaliza el contrato de API entre los clientes y los microservicios de backend:

```json
{
  "openapi": "3.0.3",
  "info": {
    "title": "Platform Infrastructure Metrics API",
    "version": "1.0.0",
    "description": "Production REST API contract for node monitoring."
  },
  "paths": {
    "/api/v1/metrics": {
      "get": {
        "summary": "Retrieve node metrics list",
        "operationId": "getMetrics",
        "responses": {
          "200": {
            "description": "Successful operation",
            "content": {
              "application/json": {
                "schema": {
                  "type": "array",
                  "items": {
                    "$ref": "#/components/schemas/NodeMetric"
                  }
                }
              }
            }
          }
        }
      }
    }
  },
  "components": {
    "schemas": {
      "NodeMetric": {
        "type": "object",
        "required": ["id", "name", "cpu_usage", "status"],
        "properties": {
          "id": { "type": "integer", "format": "int64" },
          "name": { "type": "string" },
          "cpu_usage": { "type": "number", "format": "float" },
          "status": { "type": "string", "enum": ["OK", "WARN", "CRITICAL"] }
        }
      }
    }
  }
}
```

#### Preguntas de Verificación — Ejercicio 3
1. ¿Qué propiedad de la arquitectura RESTful garantiza que el estado del cliente no se almacene en el servidor entre solicitudes?
2. ¿Cómo ayudan las especificaciones de OpenAPI a los equipos modernos de desarrollo de software a desacoplar la ingeniería del cliente (frontend) y del servidor (backend)?
3. ¿Qué rango estándar de códigos de estado HTTP representa los Errores del Cliente (por ejemplo, un esquema de payload inválido enviado por un Thick Client)?

---

### Ejercicio 4: Diagnóstico Arquitectónico de Producción e Inspección de Sockets de Red

En este ejercicio, usarás utilidades estándar de diagnóstico de Linux (`ss`, `lsof`, `tcpdump`) para rastrear los canales de comunicación client-server y las vinculaciones de sockets.

#### Paso 4.1: Inspeccionar el Estado de Escucha de Sockets de Red Activos
Ejecuta `ss` (Socket Statistics) para identificar sockets TCP en escucha, nombres de procesos y vinculaciones de red en el host:

```bash
ss -tulpn | grep -E '8080|8090'
```
*Salida esperada:*
```text
tcp   LISTEN 0      128        127.0.0.1:8080      0.0.0.0:*    users:(("python3",pid=12345,fd=3))
tcp   LISTEN 0      511        0.0.0.0:8090        0.0.0.0:*    users:(("nginx",pid=67890,fd=6))
```

#### Paso 4.2: Mapear Descriptores de Archivo y Conexiones de Red Usando lsof
Rastrea los descriptores de archivo de sockets abiertos asociados con los procesos maestro/trabajador de NGINX:

```bash
lsof -iTCP:8090 -sTCP:LISTEN
```
*Salida esperada:*
```text
COMMAND   PID  USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx   67890  root    6u  IPv4  45920      0t0  TCP *:8090 (LISTEN)
```

#### Paso 4.3: Capturar Encabezados de Paquetes Client-Server a Través de tcpdump
Captura el tráfico TCP en la interfaz de loopback (`lo`) para el puerto 8080 mientras generas una solicitud de cliente:

1. En la Terminal 1, ejecuta `tcpdump`:
```bash
sudo tcpdump -i lo -nn -A port 8080
```

2. En la Terminal 2, envía una solicitud HTTP:
```bash
curl http://127.0.0.1:8080/api/v1/metrics
```

*Salida esperada en la Terminal 1:*
```text
19:05:00.123456 IP 127.0.0.1.42110 > 127.0.0.1.8080: Flags [P.], seq 1:85, ack 1, win 512, length 84
E..v..@.@..v...........>.....(............
.W...GET /api/v1/metrics HTTP/1.1
Host: 127.0.0.1:8080
User-Agent: curl/7.81.0
Accept: */*

19:05:00.124111 IP 127.0.0.1.8080 > 127.0.0.1.42110: Flags [P.], seq 1:215, ack 85, win 512, length 214
E.....@.@..................>(...W.........
.X...HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:05:00 GMT
Content-Type: application/json

[{"id": 1, "name": "web-node-01", "cpu_usage": 88.5, "status": "WARN"}, ...]
```

#### Paso 4.4: Limpiar Procesos en Segundo Plano
Termina el servidor de Python en segundo plano y la instancia de NGINX creados durante los ejercicios:

```bash
kill $(pgrep -f "python3 server.py")
nginx -s stop -c /tmp/nginx-spa.conf
```

#### Preguntas de Verificación — Ejercicio 4
1. ¿Qué significa el estado de socket `LISTEN` en una arquitectura client-server?
2. En la salida de `ss -tulpn`, ¿cuál es la implicación arquitectónica de vincular un servidor a `127.0.0.1:8080` en comparación con `0.0.0.0:8080`?
3. ¿Qué capa del modelo OSI se está analizando cuando se usa `tcpdump` para ver encabezados de solicitud HTTP (`GET /api/v1/metrics`) versus flags TCP puros (`Flags [P.]`)?

---

## Soluciones y Clave de Respuestas

<details>
<summary>Haz clic aquí para desplegar las Respuestas y Explicaciones de Verificación</summary>

### Soluciones del Ejercicio 1
1. **Componente Servidor**: El servidor HTTP de Python que ejecuta `server.py` realizó la lógica de filtrado (`if n["cpu_usage"] > 85.0`) dentro del manejador `/thin-client-render` y devolvió HTML pre-renderizado.
2. **Comparación de Consumo de CPU**: En el Paso 1.3 (Thick/Fat Client), el servidor solo serializa y transmite datos JSON puros. El trabajo de CPU para filtrar y analizar (`jq`) se distribuye entre las 10,000 estaciones de trabajo de los clientes. En consecuencia, el consumo de CPU del servidor en el Paso 1.3 es significativamente menor que en el Paso 1.2 bajo una alta carga de clientes concurrentes.
3. **Ventaja de Seguridad Operacional**: En un modelo Thin Client, la propiedad intelectual, las fórmulas de negocio propietarias y los esquemas del sistema backend permanecen protegidos dentro del entorno seguro del servidor y nunca se exponen a ingeniería inversa o manipulación en el lado del cliente.

### Soluciones del Ejercicio 2
1. **Mecánica de Enrutamiento de SPA**: En las SPAs, el enrutamiento entre páginas (por ejemplo, `/dashboard`, `/settings`) es manejado del lado del cliente por JavaScript utilizando APIs de historial del navegador (`pushState`/`popstate`). Cuando un usuario accede manualmente o refresca `http://127.0.0.1:8090/dashboard`, el servidor web busca un archivo físico llamado `/tmp/spa-root/dashboard`. Dado que ese archivo no existe, NGINX devolvería un error `404 Not Found` sin `try_files $uri $uri/ /index.html;`. La directiva `try_files` fuerza a NGINX a devolver `index.html`, permitiendo que el enrutador de JavaScript del lado del cliente analice la ruta y renderice la vista correcta.
2. **Transición de Rutas en MPA**: En una MPA, el navegador web envía una nueva solicitud HTTP `GET` al servidor por cada enlace en el que se hace clic. El servidor procesa la solicitud, renderiza un documento HTML completo nuevo y lo devuelve al navegador.
3. **Impacto en la Latencia**: Las SPAs exhiben una latencia de carga inicial mayor porque todo el bundle de JavaScript y CSS debe descargarse primero. Sin embargo, los cambios de ruta posteriores muestran una latencia de refresco de página en red casi nula porque solo se obtienen payloads de datos JSON puros de forma asíncrona a través de la red.

### Soluciones del Ejercicio 3
1. **Ausencia de Estado (Restricción Stateless)**: La arquitectura RESTful dicta que cada solicitud de un cliente a un servidor debe contener toda la información necesaria para comprender y completar la solicitud. El servidor no almacena el contexto de sesión del cliente en memoria entre solicitudes.
2. **Desacoplamiento a través de Contratos de API**: Los esquemas de OpenAPI proporcionan una definición de interfaz clara y legible por máquinas. Los desarrolladores frontend pueden simular (mock) respuestas de API basadas en el esquema, y los desarrolladores backend pueden implementar la lógica de negocio para que coincida de forma independiente con el esquema. Las herramientas de validación automatizadas también pueden verificar solicitudes y respuestas contra el contrato.
3. **Códigos de Estado HTTP 4xx**: Los códigos de estado HTTP 4xx (por ejemplo, `400 Bad Request`, `401 Unauthorized`, `404 Not Found`) indican errores del lado del cliente, tales como sintaxis de solicitud mal formada o destinos de ruta inválidos.

### Soluciones del Ejercicio 4
1. **Estado `LISTEN` del Socket**: `LISTEN` indica que un proceso de servidor ha abierto un socket de red, lo ha vinculado a una dirección IP y número de puerto, y está esperando activamente solicitudes de conexión TCP de clientes entrantes (paquetes SYN).
2. **Implicaciones de Vinculación de IP**:
   - `127.0.0.1:8080`: Se vincula exclusivamente a la interfaz de red loopback local. El servicio solo es accesible para procesos que se ejecutan en el mismo host local (aislado de redes externas).
   - `0.0.0.0:8080`: Se vincula a todas las interfaces de red IPv4 disponibles en el sistema. El servicio es accesible para clientes de redes externas (sujeto a reglas de firewall).
3. **Capas del Modelo OSI**: Visualizar encabezados de solicitudes HTTP (`GET /api/v1/metrics`) opera en la **Capa 7 (Capa de Aplicación)**, mientras que inspeccionar flags de conexión TCP (`Flags [P.]`, números de secuencia, tamaño de ventana) opera en la **Capa 4 (Capa de Transporte)**.

</details>