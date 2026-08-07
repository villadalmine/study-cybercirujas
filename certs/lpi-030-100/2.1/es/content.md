# LPI 030-100: Tema 2.1 – Anatomía del documento HTML y arquitectura de entrega en el Edge

**Objetivo del examen**: LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Tema**: Tema 2.1 – Anatomía del documento HTML  
**Peso del tema**: 5  

---

## 1. Motivación arquitectónica de producción y problema de ingeniería

Desde la perspectiva de SRE y arquitectura de plataforma, un documento HTML no es simplemente un archivo de marcado estático; es el flujo de punto de entrada para el entorno de ejecución (runtime) del navegador, controlando directamente el **Critical Rendering Path (CRP)** y las métricas de rendimiento del navegador moderno (First Contentful Paint [FCP], Largest Contentful Paint [LCP], Interaction to Next Paint [INP]).

```
                                +-----------------------------------+
                                |     Edge Server / CDN Engine      |
                                | (HTTP/2 / HTTP/3 Byte Stream)     |
                                +-----------------+-----------------+
                                                  |
                                                  | Raw UTF-8 Bytes
                                                  v
                                +-----------------+-----------------+
                                |  Network Layer Buffer / Stream    |
                                +-----------------+-----------------+
                                                  |
                                                  | Byte Stream
                                                  v
                                +-----------------+-----------------+
                                |    HTML5 Parser & Tokenizer       |
                                |  (State Machine, WHATWG Spec)     |
                                +--------+----------------+---------+
                                         |                |
                       Speculative Tokens|                | Document Tokens
                                         v                v
                       +-----------------+--+   +---------+---------+
                       | Preload Scanner    |   | DOM Tree Builder  |
                       | (Fetch CSS/JS/Img)|   +---------+---------+
                       +--------------------+             |
                                                          v
                                                +---------+---------+
                                                |     DOM Tree      |
                                                +-------------------+
```

### 1.1 La mecánica de la máquina de estados de parsing HTML5
El navegador procesa las respuestas de red HTML de forma incremental como flujos de bytes (normalmente entregados a través de tramas TCP de 16 KB o flujos HTTP/2-HTTP/3 QUIC). El pipeline de parsing de HTML5 se ejecuta como una máquina de estados de dos etapas:

1. **Tokenización (Análisis léxico)**: Convierte flujos de bytes Unicode en tokens individuales (`DOCTYPE`, `StartTag`, `EndTag`, `Comment`, `Character`).
2. **Construcción del árbol**: Consume tokens para mutar y construir la estructura del árbol del Document Object Model (**DOM**).

Si el documento carece de una estructura anatómica adecuada (p. ej., falta `<!DOCTYPE html>`, `<meta charset="utf-8">` mal ubicado o elementos a nivel de bloque anidados dentro de elementos en línea), la máquina de estados de parsing desencadena un **re-parsing especulativo**, modos de renderizado de respaldo (**Quirks Mode**) o bloqueos del parser en el hilo principal.

### 1.2 El Preload Scanner (Preparser de inspección previa / Lookahead)
Los motores modernos (V8/Blink, Gecko, WebKit) generan un parser especulativo secundario y ligero llamado **Preload Scanner**. Mientras el parser principal está bloqueado por scripts síncronos o cargas útiles de CSSOM pendientes, el Preload Scanner examina los bytes crudos entrantes en busca de dependencias externas (`<link rel="stylesheet">`, `<script src="...">`, `<img src="...">`) para emitir solicitudes de red asíncronas de alta prioridad. La ubicación incorrecta de etiquetas de metadatos o scripts inline rompe el lookahead del Preload Scanner, retrasando el descubrimiento de recursos críticos.

### 1.3 Sobrecarga de memoria y límites del árbol DOM
Cada nodo de elemento HTML instanciado en el árbol DOM consume memoria heap dentro del proceso del navegador (aprox. 1 KB–4 KB por nodo, según los listeners vinculados, bindings de estilos calculados y wrappers de layout). Un árbol DOM sobredimensionado y no optimizado (>1.500 nodos, profundidad >32, nodos hijo >60) degrada los ciclos de recolección de basura, infla la huella de memoria en los nodos edge y ralentiza la recalculación de estilos.

---

## 2. Comparativas técnicas y matrices de balance (Trade-off Matrices)

### Tabla 2.1: Modos de renderizado (Impacto de `<!DOCTYPE html>`)

| Característica / Métrica | Modo estándar HTML5 (`<!DOCTYPE html>`) | Quirks Mode (DOCTYPE faltante/heredado) | Almost Quirks Mode (Trans/Frameset heredado) |
| :--- | :--- | :--- | :--- |
| **Comportamiento del motor de parsing** | Cumplimiento estricto del estándar WHATWG HTML | Emula los comportamientos anómalos (quirks) de renderizado de Internet Explorer 5.5 | Sigue la especificación CSS2 para layouts de elementos |
| **Cálculo del Box Model** | Box Model estándar W3C (`width` = ancho del contenido) | Box Model no estándar (`width` = contenido + padding + borde) | Box Model estándar W3C |
| **Dimensionamiento de tablas en línea** | Calcula las alturas de las celdas de la tabla mediante algoritmos de layout estándar | Calcula las alturas de las celdas en función del tamaño del contenedor de fuente | Calcula las alturas de las celdas en función del tamaño del contenedor de fuente |
| **Impacto en INP / LCP** | Pasadas de layout deterministas y optimizadas | Recálculos de layout impredecibles; layout thrashing | Variaciones menores de layout en componentes web heredados |
| **Riesgo de producción para SRE** | Bajo (Objetivo por defecto en producción) | **CRÍTICO**: Rompe los frameworks CSS modernos y los viewports responsivos | **MEDIO**: Renderizado inconsistente entre navegadores |

### Tabla 2.2: Estrategias de ejecución de scripts dentro del Head/Body del documento

| Estrategia | Sintaxis | Impacto de parsing en el hilo principal | Orden de ejecución | Estrategia de caché Edge/CDN | Riesgo de cuello de botella en CRP |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Síncrona** | `<script src="app.js"></script>` | **Bloquea el parsing** hasta que finalicen la descarga y la ejecución | Secuencial (A medida que se encuentra en el DOM) | Caché HTTP estándar | **ALTO**: Regresión directa de LCP/FCP |
| **Asíncrona** | `<script async src="app.js"></script>` | Descarga en paralelo; **bloquea el parsing** durante la ejecución | No determinista (Se ejecuta inmediatamente tras completar la descarga) | Caché inmutable en el edge | **MEDIO**: Puede ejecutarse antes de que el DOM esté completamente parseado |
| **Diferida** | `<script defer src="app.js"></script>` | Descarga en paralelo; **cero bloqueo del parser** | Orden estricto del DOM (Se ejecuta justo después de `DOMContentLoaded`) | Caché a largo plazo con hash de recursos | **BAJO**: Recomendado para bundles de aplicación generales |
| **Módulos ES** | `<script type="module" src="app.js">` | Defer por defecto; descarga el árbol de módulos de forma asíncrona | Ejecución secuencial del árbol tras el parsing del DOM | Caché granular en el edge basada en módulos | **BAJO**: Estándar moderno para aplicaciones empresariales |

---

## 3. Manifiestos de producción, infraestructura y anatomía completa del documento

### 3.1 Documento HTML5 de grado de producción (`index.html`)

A continuación se muestra una estructura completa y sintácticamente válida de un documento HTML5 que contiene encabezados de seguridad de grado de producción (vía fallback de Meta CSP), configuración de diseño responsivo, resource hints, jerarquía semántica accesible y metadatos de Open Graph.

```html
<!DOCTYPE html>
<html lang="en" dir="ltr">
<head>
  <!-- 1. Primary Encoding Declaration: MUST appear within the first 1024 bytes -->
  <meta charset="utf-8">
  
  <!-- 2. Responsive Viewport Controls -->
  <meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no">
  
  <!-- 3. Page Title & Primary SEO -->
  <title>Production Platform Engine - System Dashboard</title>
  <meta name="description" content="High-performance edge platform dashboard for infrastructure monitoring and control.">
  <meta name="robots" content="index, follow">

  <!-- 4. Security Metadata Fallback (Complementary to HTTP Headers) -->
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' https://static.example.com; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self' https://api.example.com; object-src 'none'; base-uri 'self'; frame-ancestors 'none';">

  <!-- 5. Network Resource Hints (Preconnect & Preload for CRP Optimization) -->
  <link rel="preconnect" href="https://fonts.googleapis.com" crossorigin>
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="preload" href="/assets/fonts/inter-var.woff2" as="font" type="font/woff2" crossorigin="anonymous">
  <link rel="preload" href="/assets/css/critical.css" as="style">
  <link rel="modulepreload" href="/assets/js/app.js">

  <!-- 6. Cascading Stylesheets -->
  <link rel="stylesheet" href="/assets/css/critical.css">
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap">

  <!-- 7. Favicon & Web Application Metadata -->
  <link rel="icon" type="image/svg+xml" href="/favicon.svg">
  <link rel="alternate icon" type="image/png" href="/favicon.png">
  <link rel="manifest" href="/site.webmanifest">
  <meta name="theme-color" content="#0f172a">

  <!-- 8. Open Graph & Social Card Protocols -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="Production Platform Engine">
  <meta property="og:description" content="Real-time telemetry and infrastructure control interface.">
  <meta property="og:url" content="https://dashboard.example.com/">
  <meta property="og:image" content="https://dashboard.example.com/assets/og-image.png">

  <!-- 9. Non-blocking Application Scripts -->
  <script type="module" src="/assets/js/app.js"></script>
</head>
<body>
  <!-- Semantic Document Structure -->
  <header role="banner" class="site-header">
    <div class="container">
      <div class="logo">
        <a href="/" aria-label="Home Dashboard">
          <img src="/assets/images/logo.svg" alt="Platform Logo" width="160" height="40" loading="eager">
        </a>
      </div>
      <nav role="navigation" aria-label="Primary Navigation" class="main-nav">
        <ul>
          <li><a href="/telemetry" class="nav-link active">Telemetry</a></li>
          <li><a href="/nodes" class="nav-link">Nodes</a></li>
          <li><a href="/security" class="nav-link">Security</a></li>
        </ul>
      </nav>
    </div>
  </header>

  <main role="main" id="main-content" class="content-wrapper">
    <section aria-labelledby="section-telemetry-heading" class="telemetry-panel">
      <h1 id="section-telemetry-heading">Cluster Performance Telemetry</h1>
      <p class="summary-text">Real-time status overview of globally distributed edge worker instances.</p>

      <div class="metrics-grid">
        <article class="metric-card">
          <h2>API Availability</h2>
          <p class="metric-value">99.999%</p>
        </article>
        <article class="metric-card">
          <h2>Mean Latency</h2>
          <p class="metric-value">12.4 ms</p>
        </article>
      </div>
    </section>
  </main>

  <footer role="contentinfo" class="site-footer">
    <div class="container">
      <p>&copy; 2026 Production Platform Engine Inc. All rights reserved.</p>
      <ul class="footer-links">
        <li><a href="/privacy">Privacy Policy</a></li>
        <li><a href="/terms">Terms of Service</a></li>
      </ul>
    </div>
  </footer>
</body>
</html>
```

---

### 3.2 Configuración en el edge de infraestructura Nginx y manifiestos de Kubernetes

Para servir el documento HTML correctamente según los estándares de producción de SRE, los servidores edge deben aplicar tipos MIME estrictos, declaraciones de codificación de caracteres, algoritmos de compresión y encabezados de seguridad.

#### Configuración en el edge de Nginx (`nginx.conf`)
```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 10244;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Explicit default charset enforcement for all HTML responses
    charset utf-8;
    source_charset utf-8;

    # Performance logging schema
    log_format main_ext '$remote_addr - $remote_user [$time_local] "$request" '
                        '$status $body_bytes_sent "$http_referer" '
                        '"$http_user_agent" "$http_x_forwarded_for" '
                        'rt=$request_time uct="$upstream_connect_time" uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main_ext;

    # Compression Settings for HTML & Static Assets
    gzip on;
    gzip_comp_level 6;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types
        text/html
        text/css
        text/plain
        text/xml
        application/javascript
        application/json
        application/xml
        image/svg+xml;

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name dashboard.example.com;

        root /usr/share/nginx/html;
        index index.html;

        # Hardened Production HTTP Headers for HTML Documents
        add_header Content-Type "text/html; charset=utf-8" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;

        location / {
            try_files $uri $uri/ /index.html;
        }

        # Cache static immutables referenced in HTML head
        location /assets/ {
            expires 1y;
            add_header Cache-Control "public, max-age=31536000, immutable";
            access_log off;
        }

        error_page 404 /index.html;
        error_page 500 502 503 504 /50x.html;
    }
}
```

#### Manifiesto Deployment & ConfigMap de Kubernetes (`deployment.yaml`)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: html-edge-nginx-config
  namespace: production-web
data:
  nginx.conf: |
    user nginx;
    worker_processes auto;
    events { worker_connections 4096; }
    http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;
        charset utf-8;
        server {
            listen 8080;
            root /usr/share/nginx/html;
            index index.html;
            add_header Content-Type "text/html; charset=utf-8" always;
            add_header X-Content-Type-Options "nosniff" always;
            location / {
                try_files $uri $uri/ /index.html;
            }
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: html-edge-app
  namespace: production-web
  labels:
    app.kubernetes.io/name: html-edge-app
    app.kubernetes.io/component: frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: html-edge-app
  template:
    metadata:
      labels:
        app: html-edge-app
    spec:
      containers:
        - name: nginx-server
          image: nginx:1.25.4-alpine
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 101
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: nginx-config-vol
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: html-content-vol
              mountPath: /usr/share/nginx/html
              readOnly: true
            - name: tmp-cache
              mountPath: /var/cache/nginx
            - name: tmp-run
              mountPath: /var/run
      volumes:
        - name: nginx-config-vol
          configMap:
            name: html-edge-nginx-config
        - name: html-content-vol
          configMap:
            name: html-document-source
        - name: tmp-cache
          emptyDir: {}
        - name: tmp-run
          emptyDir: {}
```

---

## 4. Comandos CLI reales y ejecución de salida de terminal

### 4.1 Verificación de encabezados en el edge y flujo de bytes HTTP/2 (`curl`)
Ejecute `curl` para inspeccionar los encabezados de respuesta HTTP, la negociación de contenido, las declaraciones de codificación y las transferencias de bytes crudos en la interfaz del nodo edge.

```bash
$ curl -Iv https://dashboard.example.com/
```

**Expected Terminal Output:**
```text
*   Trying 192.0.2.45:443...
* Connected to dashboard.example.com (192.0.2.45) port 443 (#0)
* ALPN: offers h2, http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* Using HTTP/2, stream 1
> GET / HTTP/2
> Host: dashboard.example.com
> user-agent: curl/8.5.0
> accept: */*
> 
< HTTP/2 200 
< server: nginx/1.25.4
< date: Thu, 06 Aug 2026 18:51:24 GMT
< content-type: text/html; charset=utf-8
< content-length: 3412
< strict-transport-security: max-age=31536000; includeSubDomains; preload
< x-content-type-options: nosniff
< x-frame-options: DENY
< referrer-policy: strict-origin-when-cross-origin
< permissions-policy: geolocation=(), microphone=(), camera=()
< cache-control: no-cache, no-store, must-revalidate
< content-encoding: gzip
< 
```

---

### 4.2 Validación automatizada de cumplimiento sintáctico y estructural (`vnu`)
Utilice el W3C Nu HTML Checker oficial (`vnu`) para ejecutar análisis estático sobre el flujo del documento de producción y capturar anatomías no conformes o declaraciones estructurales faltantes.

```bash
$ npx vnu-jar --format json index.html
```

**Expected Terminal Output:**
```json
{
  "messages": []
}
```

Si existe una falla anatómica (como omitir el elemento `title` o colocar una etiqueta `<meta>` dentro de `<body>`), la salida informa la línea exacta y el desplazamiento de columna:

```json
{
  "messages": [
    {
      "type": "error",
      "lastLine": 14,
      "lastColumn": 32,
      "firstColumn": 5,
      "message": "Element “meta” with attribute “charset” must appear inside the “head” element.",
      "extract": "<body>\n    <meta charset=\"utf-8\">\n   ",
      "hiliteStart": 10,
      "hiliteLength": 27
    }
  ]
}
```

---

### 4.3 Extracción del DOM e inspección estructural por CLI (`pup`)
Extraiga e inspeccione nodos del DOM directamente desde el flujo HTML en vivo utilizando selectores CSS con `pup`.

```bash
$ curl -s https://dashboard.example.com/ | pup 'head > meta[charset], head > title, body main section h1 text{}'
```

**Expected Terminal Output:**
```html
<meta charset="utf-8">
<title>
 Production Platform Engine - System Dashboard
</title>
Cluster Performance Telemetry
```

---

### 4.4 Auditoría de rendimiento automatizada mediante Lighthouse CLI (`lighthouse`)
Ejecute Lighthouse desde la terminal para medir la eficiencia del CRP, el tamaño del DOM y las métricas de cumplimiento del documento en comparación con los umbrales de producción.

```bash
$ lighthouse https://dashboard.example.com/ --only-categories=performance,best-practices,accessibility --output=json --output-path=./audit-results.json --quiet
$ jq '.categories | {performance: .performance.score, accessibility: .accessibility.score, best_practices: ."best-practices".score}' audit-results.json
```

**Expected Terminal Output:**
```json
{
  "performance": 1,
  "accessibility": 1,
  "best_practices": 1
}
```

---

## 5. Guía de verificación y resolución de fallas de SRE (Runbook)

### Matriz de diagnóstico

```
                          [ PRODUCTION ISSUE DETECTED ]
                                        |
     +----------------------------------+----------------------------------+
     |                                  |                                  |
[ Garbage Characters / ]      [ Layout Thrashing / ]         [ CSP / MIME Type Block ]
[ Unicode Errors       ]      [ Heavy Render Times ]         [ Security Violation   ]
     |                                  |                                  |
     v                                  v                                  v
+----------------------+      +----------------------+      +----------------------+
| Issue 5.1: UTF-8 BOM |      | Issue 5.2: Parser    |      | Issue 5.3: MIME      |
| & Charset Mismatch   |      | Blocking CRP Assets  |      | Sniffing Invalidation|
+----------------------+      +----------------------+      +----------------------+
```

---

### Problema 5.1: Corrupción de BOM UTF-8 y desajuste temprano en la codificación de caracteres

* **Síntoma**: La página muestra texto ilegible (`Ã©`, `ï»¿`, o ``), o el navegador no logra aplicar selectores CSS dirigidos a cadenas de atributos.
* **Causa raíz**: El archivo de origen se guardó con una Marca de orden de bytes (BOM: `0xEF,0xBB,0xBF`) o la etiqueta `<meta charset="utf-8">` está ubicada después de la línea 1024 en el documento, lo que provoca que el tokenizador cambie de estado de codificación a mitad del flujo.
* **Comando de diagnóstico**:
  ```bash
  $ xxd -g 1 index.html | head -n 2
  ```
  *Salida defectuosa (BOM presente)*:
  ```text
  00000000: ef bb bf 3c 21 44 4f 43 54 59 50 45 20 68 74 6d  ...<!DOCTYPE htm
  ```
* **Remediación**:
  1. Elimine la BOM usando `sed` o `dos2unix`:
     ```bash
     $ dos2unix -b -m index.html
     ```
  2. Asegúrese de que `<meta charset="utf-8">` esté posicionado como el **primer elemento hijo** dentro de `<head>`.
  3. Verifique que Nginx sirva el encabezado HTTP explícito: `Content-Type: text/html; charset=utf-8`.

---

### Problema 5.2: Script síncrono bloqueante del parser que degrada el CRP (Regresión de LCP/FCP)

* **Síntoma**: Lighthouse reporta un elevado First Contentful Paint (FCP > 3.0s) y alertas de bloqueo en el hilo principal.
* **Causa raíz**: Una etiqueta `<script src="bundle.js">` sin los atributos `defer` o `async` está ubicada en la sección `<head>`, pausando el tokenizador de HTML mientras el motor descarga y ejecuta la carga útil de JavaScript.
* **Comando de diagnóstico**:
  ```bash
  $ curl -s https://dashboard.example.com/ | pup 'head script'
  ```
  *Salida defectuosa*:
  ```html
  <script src="/assets/js/heavy-bundle.js"></script>
  ```
* **Remediación**:
  Modifique la declaración del script en el pipeline de build para usar `defer` o `type="module"`:
  ```html
  <!-- CORRECT: Non-blocking defer pattern -->
  <script defer src="/assets/js/heavy-bundle.js"></script>
  ```

---

### Problema 5.3: Rechazo por inspección de tipos MIME (MIME-Type Sniffing) (`X-Content-Type-Options: nosniff`)

* **Síntoma**: Los recursos declarados en el documento HTML (p. ej., `<link rel="stylesheet">` o `<script>`) no se cargan y muestran un error en consola: `Refused to execute script from '...' because its MIME type ('text/plain') is not executable, and strict MIME type checking is enabled.`
* **Causa raíz**: El servidor web omite el encabezado `Content-Type` correcto (p. ej., sirviendo CSS como `text/plain` o JS como `application/octet-stream`), lo que activa bloqueos de seguridad estrictos cuando se aplica `nosniff`.
* **Comando de diagnóstico**:
  ```bash
  $ curl -sI https://dashboard.example.com/assets/css/critical.css | grep -iE 'content-type|x-content-type-options'
  ```
  *Salida defectuosa*:
  ```text
  content-type: text/plain
  x-content-type-options: nosniff
  ```
* **Remediación**:
  Actualice la inclusión de `mime.types` en Nginx para vincular explícitamente las extensiones estáticas:
  ```nginx
  types {
      text/html                             html htm;
      text/css                              css;
      application/javascript                js;
      image/svg+xml                         svg;
  }
  ```

---

### Problema 5.4: Profundidad excesiva de nodos en el árbol DOM e inflación de memoria

* **Síntoma**: La pestaña del navegador experimenta un alto consumo de CPU durante las mutaciones del DOM, con tasas de cuadros de renderizado cayendo por debajo de 30 FPS.
* **Causa raíz**: Estructuras de marcado no semánticas y profundamente anidadas (p. ej., "divitis" creada por wrappers de frameworks no configurados) que superan las métricas de nodos DOM recomendadas (>1.500 nodos totales, profundidad >32).
* **Comando de diagnóstico**:
  ```bash
  $ curl -s https://dashboard.example.com/ | pup 'div div div div div' | wc -l
  ```
  Alternativamente, calcule el recuento total de nodos mediante un script CLI de Node.js:
  ```bash
  $ node -e '
    const fs = require("fs");
    const { JSDOM } = require("jsdom");
    const html = fs.readFileSync("index.html", "utf8");
    const dom = new JSDOM(html);
    const nodes = dom.window.document.getElementsByTagName("*").length;
    console.log(`Total DOM Nodes: ${nodes}`);
    if (nodes > 1500) console.error("CRITICAL: DOM Node Limit Exceeded (>1500)");
  '
  ```
* **Remediación**:
  Refactorice las estructuras de elementos para utilizar elementos semánticos planos de HTML5 (`<main>`, `<header>`, `<nav>`, `<article>`, `<section>`) en lugar de wrappers `<div>` anidados.

---

## 6. Referencias

* **LPI Web Development Essentials Overview**:  
  https://www.lpi.org/our-certifications/web-development-essentials-overview/
* **WHATWG HTML Living Standard - The Parsing Model**:  
  https://html.spec.whatwg.org/multipage/parsing.html#parsing
* **W3C Nu HTML Checker (`vnu`) Documentation**:  
  https://validator.github.io/validator/
* **MDN Web Docs - HTML Anatomy and Structure**:  
  https://developer.mozilla.org/en-US/docs/Learn/HTML/Introduction_to_HTML/Getting_started
* **MDN Web Docs - Critical Rendering Path**:  
  https://developer.mozilla.org/en-US/docs/Web/Performance/Critical_rendering_path
* **Google Chrome Developers - Preload Scanner Mechanics**:  
  https://developer.chrome.com/docs/capabilities/web-apis/preload-scanner