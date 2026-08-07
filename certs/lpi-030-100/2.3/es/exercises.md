# LPI 030-100 (v1.0) Topic 2.3: Referencias HTML y Recursos Embebidos
## Ejercicios Guiados de Nivel de Producción y Laboratorios de Diagnóstico

**Peso del tema:** 5  
**Certificación objetivo:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Referencia oficial:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  
**Especificaciones de estándares:** [WHATWG HTML Living Standard](https://html.spec.whatwg.org/multipage/), [RFC 3986 - Uniform Resource Identifier (URI): Generic Syntax](https://datatracker.ietf.org/doc/html/rfc3986), [W3C Fetch Standard](https://fetch.spec.whatwg.org/)

---

### Prerrequisitos y Configuración del Laboratorio
Asegúrate de tener un entorno de terminal tipo Unix moderno con `curl`, `python3` (o `npx http-server`) y utilidades estándar de inspección de red instaladas.

Ejecutá los siguientes comandos bash para establecer el árbol de proyecto base:

```bash
mkdir -p lpi-lab-2.3/{css,js,media/images,media/video,docs,api}
cd lpi-lab-2.3
touch index.html docs/manual.html css/styles.css js/app.js
```

---

### Ejercicio 1: Mecánica de Resolución de URL, Path Traversal y Diagnósticos de Encabezados HTTP

#### Visión General de la Arquitectura de Producción
La resolución de URL en los navegadores web sigue algoritmos estrictos especificados en **RFC 3986**. El navegador resuelve las URIs relativas con respecto a una **Base URI** (por defecto, la dirección URL del documento actual o modificada mediante `<base href="...">`). 

* **Absolute URLs** (`https://example.com/assets/main.css`): Contienen esquema, autoridad, ruta y query/fragment opcional. Inmunes a cambios en la Base URI.
* **Protocol-Relative URLs** (`//cdn.example.com/lib.js`): Heredan el esquema de la página actual (`http:` vs `https:`). *Depreciadas en arquitecturas modernas exclusivamente HTTPS para prevenir degradaciones de seguridad por Mixed Content.*
* **Root-Relative Paths** (`/css/styles.css`): Resueltas desde la raíz del dominio de origen de nivel superior.
* **Document-Relative Paths** (`../js/app.js`): Resueltas de forma relativa al directorio de la ruta del documento actual.

```
       [ Client Browser ]
               │
               ├─► Document Path:  https://app.example.com/docs/admin/settings.html
               ├─► Target Reference: "../../css/main.css"
               │
      [ URI Resolution Algorithm (RFC 3986) ]
               │
               ├─► Step 1: Parse Base Directory -> https://app.example.com/docs/admin/
               ├─► Step 2: Pop "admin/"         -> https://app.example.com/docs/
               ├─► Step 3: Pop "docs/"          -> https://app.example.com/
               └─► Step 4: Append target        -> https://app.example.com/css/main.css
```

#### Paso 1.1: Crear Referencias Document-Relative y Root-Relative
Crea el archivo `docs/manual.html` con referencias que demuestren la resolución de rutas a través de subdirectorios anidados:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <base href="/docs/">
    <title>SRE Technical Manual</title>
    <!-- Resolved relative to <base href="/docs/"> -> /docs/../css/styles.css -> /css/styles.css -->
    <link rel="stylesheet" href="../css/styles.css">
</head>
<body>
    <header>
        <h1>System Architecture Manual</h1>
    </header>
    <main>
        <!-- Document-Relative Hyperlink with Anchor -->
        <a href="#section-storage">Jump to Storage Section</a> |
        <a href="../index.html" target="_blank" rel="noopener noreferrer">Back to Portal Root</a> |
        <!-- Root-Relative File Download -->
        <a href="/media/video/architecture-overview.mp4" download="sys-arch.mp4">Download Briefing</a>
        
        <section id="section-storage" style="margin-top: 1000px;">
            <h2>Storage Mechanics</h2>
            <p>Distributed block store operational metrics...</p>
        </section>
    </main>
</body>
</html>
```

#### Paso 1.2: Iniciar Servidor de Prueba Local y Validar Path Traversal mediante cURL
Ejecuta un servidor Web local para simular un servidor web edge NGINX sirviendo archivos estáticos:

```bash
python3 -m http.server 8080 &
SERVER_PID=$!
```

Verifica los encabezados de respuesta y los códigos de estado usando `curl` con el modo verbose habilitado:

```bash
curl -I -H "User-Agent: SRE-Diagnostic-Agent" http://localhost:8080/docs/manual.html
```

*Salida Esperada en Terminal:*
```http
HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.10.12
Date: Thu, 06 Aug 2026 18:55:00 GMT
Content-type: text/html
Content-Length: 954
Last-Modified: Thu, 06 Aug 2026 18:54:12 GMT
```

Verifica la carga relativa de recursos solicitando el archivo CSS referenciado mediante path traversal:

```bash
curl -i http://localhost:8080/css/styles.css
```

---

#### Preguntas de Comprensión - Ejercicio 1

1. Si `<base href="https://cdn.enterprise.io/assets/v2/">` está declarado en un documento HTML ubicado en `https://app.enterprise.io/dashboard/index.html`, ¿a qué URL absoluta exacta se resolverá `<a href="../reports/summary.pdf">`?
2. ¿Cuáles son las implicaciones de seguridad de usar `target="_blank"` sin `rel="noopener noreferrer"` en hipervínculos externos?
3. Al usar el atributo `download` en un elemento `<a>` (por ejemplo, `<a href="https://thirdparty.com/data.json" download>`), ¿bajo qué condición específica los navegadores modernos ignorarán la directiva `download` y realizarán una navegación inline en su lugar?

---

### Ejercicio 2: Imágenes Embebidas Responsivas y Mecánica del Pipeline de Imágenes

#### Visión General de la Arquitectura de Producción
Embeber gráficos rasterizados y vectoriales de manera eficiente requiere gestionar los compromisos de rendimiento entre cambios dinámicos de diseño (CLS), sobrecarga de carga útil en bytes y la orientación a la densidad del viewport responsivo.

```
                  [ Viewport Width / Device DPI ]
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
 [ Screen Width < 768px ]                   [ Screen Width >= 768px ]
          │                                           │
  <source media="(max-width: 767px)"              <img srcset="hero-800.jpg 800w,
          srcset="mobile-hero.avif">                       hero-1600.jpg 1600w"
          │                                            sizes="(max-width: 1200px) 100vw, 1200px">
          │                                           │
          └─────────────────────┬─────────────────────┘
                                ▼
               [ Browser Image Decoding Engine ]
                                │
                     decoding="async" (Non-blocking)
                     loading="lazy"   (Off-screen deferral)
```

* **Atributos de `<img>`**:
  * `alt`: Texto alternativo en el árbol de accesibilidad. Obligatorio para el cumplimiento válido de la especificación.
  * `width` y `height`: Definen la relación de aspecto nativa (por ejemplo, `aspect-ratio: width / height`) para permitir que los motores de layout del navegador reserven espacio *antes* de que se complete la descarga de la imagen, previniendo el Cumulative Layout Shift (CLS).
  * `loading="lazy"`: Difiere la obtención (fetch) hasta que la imagen alcanza una distancia umbral desde el viewport visual basada en métricas de IntersectionObserver.
  * `decoding="async"`: Decodifica la imagen fuera del hilo principal de renderizado para reducir la caída de fotogramas (frame drops).
* **Elemento `<picture>`**: Un contenedor alrededor de etiquetas `<source>` que permite Art Direction (media queries) declarativa explícita y Negociación de Formato (AVIF -> WebP -> PNG/JPG fallback).

#### Paso 2.1: Construir Marcas de Gráficos Responsivos Sintácticamente Válidas
Actualiza `index.html` con un bloque de imagen responsiva optimizado:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Production System Dashboard</title>
</head>
<body>
    <main>
        <h1>Cluster Performance Metrics</h1>
        
        <!-- Art Direction & Format Negotiation Wrapper -->
        <picture>
            <!-- High-efficiency AVIF format for mobile layout -->
            <source media="(max-width: 600px)" srcset="/media/images/chart-mobile.avif" type="image/avif">
            <!-- WebP format for high-res desktop views -->
            <source media="(min-width: 601px)" srcset="/media/images/chart-desktop.webp" type="image/webp">
            <!-- Fallback <img> element (Mandatory inside <picture>) -->
            <img src="/media/images/chart-fallback.png" 
                 alt="Real-time cluster throughput chart showing 45k RPS peak" 
                 width="1200" 
                 height="600" 
                 loading="lazy" 
                 decoding="async">
        </picture>

        <!-- Density-based Resolution Switching -->
        <img src="/media/images/logo-1x.png" 
             srcset="/media/images/logo-1x.png 1x, /media/images/logo-2x.png 2x" 
             alt="Enterprise Platform Logo"
             width="200" 
             height="50">
    </main>
</body>
</html>
```

#### Paso 2.2: Simular la Negociación de Formato del Navegador con cURL
Inspecciona los encabezados HTTP de negociación de contenido transmitidos por navegadores cliente modernos al solicitar endpoints de imágenes:

```bash
curl -I -H "Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" http://localhost:8080/media/images/chart-fallback.png
```

---

#### Preguntas de Comprensión - Ejercicio 2

1. ¿Por qué una etiqueta `<img>` siempre debe incluirse como hijo dentro de un elemento `<picture>`?
2. ¿Cómo mitigan los atributos explícitos `width` y `height` en los elementos `<img>` modernos el Cumulative Layout Shift (CLS), incluso cuando CSS invalida el ancho mostrado de la imagen a `100%`?
3. Si un elemento `<img>` incluye tanto `loading="lazy"` como una posición dentro de la línea base del viewport "above-the-fold", ¿qué penalización de rendimiento ocurre?

---

### Ejercicio 3: Streams de Medios HTML5 (`<audio>` y `<video>`) y Byte-Range Fetching

#### Visión General de la Arquitectura de Producción
La integración de medios HTML5 reemplaza los plugins externos heredados con motores de decodificación nativos del navegador. La entrega moderna de video depende de solicitudes HTTP/1.1 Byte-Range (`Range: bytes=start-end`) para admitir la búsqueda dinámica (seeking) y el almacenamiento en búfer incremental sin descargar cargas útiles completas de medios.

```
  [ Browser HTML5 Media Engine ]                     [ NGINX / Storage Server ]
                │                                                │
                ├─────── GET /media/stream.mp4 ─────────────────►│
                │        Header: Range: bytes=0-1023             │
                │                                                │
                │◄────── HTTP/1.1 206 Partial Content ───────────┤
                │        Header: Content-Range: bytes 0-1023/52428800
                │        Header: Content-Length: 1024            │
                │        Payload: [ First 1KB video header ]     │
```

#### Paso 3.1: Construir Marcas de Video Sintácticamente Válidas y Completas
Crea un bloque de medios HTML5 que contenga múltiples codecs de origen para fallback, subtítulos (`<track>`) y atributos de controles de video personalizados:

```html
<section id="media-player">
    <h2>Datacenter Incident Post-Mortem Video</h2>
    <video controls 
           preload="metadata" 
           poster="/media/images/poster-frame.jpg" 
           width="800" 
           height="450" 
           muted>
        <!-- Modern royalty-free WebM / AV1 video codec -->
        <source src="/media/video/incident-briefing.webm" type="video/webm; codecs=&quot;vp9, opus&quot;">
        <!-- High-compatibility MP4 / H.264 video codec -->
        <source src="/media/video/incident-briefing.mp4" type="video/mp4; codecs=&quot;avc1.42E01E, mp4a.40.2&quot;">
        
        <!-- Accessibility Subtitles & Closed Captions -->
        <track kind="captions" src="/media/video/captions-en.vtt" srclang="en" label="English Captions" default>
        <track kind="subtitles" src="/media/video/subtitles-es.vtt" srclang="es" label="Subtítulos en Español">
        
        <!-- Fallback text for obsolete user agents lacking HTML5 media support -->
        <p>Your environment does not support HTML5 video playback. 
           <a href="/media/video/incident-briefing.mp4">Download media container directly</a>.
        </p>
    </video>

    <h2>System Alert Sound</h2>
    <audio controls preload="none">
        <source src="/media/alert.opus" type="audio/ogg; codecs=opus">
        <source src="/media/alert.mp3" type="audio/mpeg">
        Audio element unsupported by platform.
    </audio>
</section>
```

#### Paso 3.2: Verificar el Streaming Byte-Range de Contenido Parcial mediante CLI
Prueba si tu servidor web maneja correctamente el streaming de contenido parcial (código de estado HTTP `206`) necesario para una búsqueda rápida (seeking) en elementos de audio/video HTML5.

Genera un archivo binario ficticio de 1MB que represente un stream de video:

```bash
dd if=/dev/zero of=media/video/incident-briefing.mp4 bs=1M count=1
```

Envía una solicitud de byte-range dirigida a los primeros 1024 bytes de la carga útil del video:

```bash
curl -i -H "Range: bytes=0-1023" http://localhost:8080/media/video/incident-briefing.mp4
```

*Salida Esperada en Terminal:*
```http
HTTP/1.0 206 Partial Content
Server: SimpleHTTP/0.6 Python/3.10.12
Date: Thu, 06 Aug 2026 18:56:00 GMT
Content-type: video/mp4
Content-Range: bytes 0-1023/1048576
Content-Length: 1024
Last-Modified: Thu, 06 Aug 2026 18:55:50 GMT
```

---

#### Preguntas de Comprensión - Ejercicio 3

1. ¿Cuál es la diferencia operativa entre `preload="none"`, `preload="metadata"` y `preload="auto"` en un elemento `<video>` HTML5?
2. ¿Qué código de estado de respuesta HTTP y encabezados debe devolver un servidor Web de producción para permitir que un navegador busque libremente marcas de tiempo arbitrarias dentro de un stream de `<video>` HTML5?
3. ¿Por qué el atributo `muted` es obligatorio en los navegadores modernos si un ingeniero tiene la intención de activar el atributo `autoplay` en una etiqueta `<video>`?

---

### Ejercicio 4: Inline Frames (`<iframe>`), Contextual Sandboxing y Límites de Seguridad

#### Visión General de la Arquitectura de Producción
El elemento `<iframe>` crea un contexto de navegación anidado, embebiendo un documento HTML externo dentro del documento anfitrión actual. Los iframes sin restricciones presentan severos vectores de ataque a la seguridad, incluyendo Clickjacking, propagación de Cross-Site Scripting (XSS) y acceso no autorizado al DOM a través de `window.parent`.

```
┌────────────────────────────────────────────────────────────────────────┐
│ Host Document (https://portal.enterprise.io)                           │
│                                                                        │
│  <iframe src="https://metrics.thirdparty.com"                          │
│          sandbox="allow-scripts allow-forms"                           │
│          allow="geolocation 'none'; camera 'none'">                    │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Nested Browsing Context (Isolated Origin)                        │  │
│  │                                                                  │  │
│  │ - Unique null Origin (Prevented from accessing parent DOM)       │  │
│  │ - Top-level navigation blocked (allow-top-navigation omitted)    │  │
│  │ - Popup creation blocked (allow-popups omitted)                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

#### Paso 4.1: Implementar una Integración de `<iframe>` Endurecida

Add a security-hardened iframe block into `index.html`:

```html
<section id="external-metrics">
    <h2>Third-Party Status Dashboard</h2>
    <iframe src="https://status.external-cloud.com/embed" 
            title="External Service Operational Status" 
            width="100%" 
            height="400" 
            loading="lazy" 
            sandbox="allow-scripts allow-forms"
            allow="accelerometer 'none'; camera 'none'; encrypted-media 'none'; geolocation 'none'"
            referrerpolicy="no-referrer">
    </iframe>
</section>
```

#### Paso 4.2: Diagnosticar Encabezados de Restricción de Frames mediante cURL
Los sitios web evitan ser embebidos en contenedores `<iframe>` no autorizados para prevenir Clickjacking. Inspecciona los encabezados de seguridad de los sitios objetivo usando `curl`:

```bash
curl -I -s https://www.google.com | grep -iE "x-frame-options|content-security-policy"
```

*Salida Esperada en Terminal:*
```http
x-frame-options: SAMEORIGIN
content-security-policy: frame-ancestors 'self';
```

---

#### Preguntas de Comprensión - Ejercicio 4

1. ¿Qué límite de seguridad específico se produce cuando un `<iframe>` tiene el atributo `sandbox=""` establecido sin ningún valor?
2. Si un iframe contiene `sandbox="allow-scripts allow-same-origin"`, ¿por qué esta combinación vulnera las garantías de seguridad del sandbox?
3. ¿Cuál es la diferencia funcional fundamental entre el encabezado de respuesta HTTP `X-Frame-Options` y la directiva `Content-Security-Policy: frame-ancestors`?

---

### Ejercicio 5: Critical Rendering Path, Vinculación de Recursos y Modos de Ejecución de Scripts

#### Visión General de la Arquitectura de Producción
Las hojas de estilo externas (`<link rel="stylesheet">`) y scripts (`<script>`) controlan directamente el comportamiento de bloqueo del parser HTML, la optimización del Critical Rendering Path y el Time-To-Interactive (TTI).

```
Parser Blocked vs Async/Defer Flow:

HTML Parser:  ───[Parse DOM]───►[BLOCKED BY SCRIPT]───────────────►[Resume DOM Parse]──►
Normal Script:                   └───[Fetch JS]───►[Execute JS]──┘

HTML Parser:  ───[Parse DOM]──────────────────────────────────────►[DOM Complete]───────►
Defer Script:  └───[Fetch JS (Background)]────────────────────────►[Execute JS]

HTML Parser:  ───[Parse DOM]──────────────►[PAUSED]───────────────►[Resume DOM Parse]──►
Async Script:  └───[Fetch JS (Background)]─►[Execute JS Immediately]──┘
```

* **`<script src="app.js">` (Predeterminado)**: Pausa la lectura (parsing) de HTML inmediatamente, obtiene el script de forma síncrona a través de la red, lo ejecuta inmediatamente y luego reanuda el parsing de HTML.
* **`<script src="app.js" defer>`**: Obtiene el script de forma asíncrona en segundo plano mientras continúa el parsing de HTML. Ejecuta los scripts en el **orden exacto del DOM** *después* de que se complete el parsing del DOM, justo antes de `DOMContentLoaded`.
* **`<script src="app.js" async>`**: Obtiene el script de forma asíncrona en segundo plano. Se ejecuta **inmediatamente al completar la obtención (fetch)**, pausando el parser HTML si está activo. El orden de ejecución no es determinista.
* **`<script type="module" src="app.js">`**: Se trata automáticamente como `defer` por defecto. Alcance delimitado strictly a módulos ES.
* **`<link rel="preload" href="..." as="...">`**: Instrucción obligatoria de obtención de alta prioridad para descargar recursos críticos (fuentes, CSS clave) de forma temprana en el waterfall.
* **`<link rel="preconnect" href="...">`**: Inicia la búsqueda DNS temprana, el handshake TLS y el establecimiento de la conexión TCP con dominios de terceros.

#### Paso 5.1: Construir un Document Head y Asset Pipeline Optimizado
Actualiza la etiqueta `<head>` de `index.html` con las relaciones de enlace de recursos correctas:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SRE Performance Portal</title>

    <!-- 1. Preconnect to third-party API origin (DNS + TCP + TLS handshake) -->
    <link rel="preconnect" href="https://api.telemetry.io" crossorigin>

    <!-- 2. Preload critical web font required above-the-fold -->
    <link rel="preload" href="/css/fonts/inter-v12-latin-regular.woff2" as="font" type="font/woff2" crossorigin>

    <!-- 3. Render-blocking CSS stylesheet -->
    <link rel="stylesheet" href="/css/styles.css">

    <!-- 4. Asynchronous non-critical third-party analytics script -->
    <script src="https://cdn.telemetry.io/tracker.js" async></script>

    <!-- 5. Deferred application logic requiring full DOM tree availability -->
    <script src="/js/app.js" defer></script>
    
    <!-- 6. Favicon and Manifest linkage -->
    <link rel="icon" type="image/png" sizes="32x32" href="/media/images/favicon-32x32.png">
    <link rel="manifest" href="/site.webmanifest">
</head>
<body>
    <h1>Platform Metrics</h1>
</body>
</html>
```

#### Paso 5.2: Rastrear Resource Hints y Encabezados de Red mediante CLI
Inspecciona el DNS prefetching y los encabezados link de HTTP a través de cURL:

```bash
curl -I http://localhost:8080/index.html
```

---

#### Preguntas de Comprensión - Ejercicio 5

1. Si el script A (`<script src="a.js" async>`) pesa 500KB y el script B (`<script src="b.js" async>`) pesa 10KB, ¿qué script tiene garantizada la ejecución en primer lugar?
2. ¿Por qué el atributo `crossorigin` es estrictamente requerido en `<link rel="preload" href="font.woff2" as="font" crossorigin>` incluso si el archivo de fuente reside exactamente en el mismo servidor de origen?
3. ¿Cuál es la diferencia entre `<link rel="preconnect">` y `<link rel="dns-prefetch">`, y cuándo debería usarse `dns-prefetch` como fallback?

---

<details>
<summary><strong>Haz clic aquí para revelar las Soluciones y Explicaciones Técnicas Detalladas</strong></summary>

### Soluciones y Clave de Respuestas

#### Respuestas del Ejercicio 1

1. **URL Resolution Target**: `https://cdn.enterprise.io/assets/reports/summary.pdf`  
   *Explicación*: La etiqueta `<base>` redefine la URL base para todas las referencias relativas del documento a `https://cdn.enterprise.io/assets/v2/`. Al resolver `../reports/summary.pdf` se elimina el nivel de carpeta actual (`v2/`) de la ruta base, obteniendo `https://cdn.enterprise.io/assets/reports/summary.pdf`, ignorando por completo la ubicación URI real de la página anfitriona (`https://app.enterprise.io/dashboard/index.html`).

2. **Implicaciones de Seguridad al Omitir `rel="noopener"`**:  
   Al abrir un enlace usando `target="_blank"` sin `rel="noopener"`, la página de destino obtiene acceso al contexto de ejecución de la ventana de origen a través del objeto de JavaScript `window.opener`. El sitio externo enlazado puede ejecutar `window.opener.location = "https://phishing-attack.com"`, redirigiendo silenciosamente la pestaña en segundo plano del usuario a un sitio malicioso. Incluir `rel="noopener"` establece `window.opener` como `null`. Nota: Los navegadores modernos (Chrome 88+, Firefox 79+, Safari 12.1+) establecen `rel="noopener"` por defecto para `target="_blank"`, pero definir explícitamente `rel="noopener noreferrer"` sigue siendo obligatorio para la compatibilidad defensiva entre navegadores antiguos.

3. **Condiciones que Anulan el Atributo `download`**:  
   El atributo `download` solo funciona para **same-origin URLs** o esquemas blob/data. Si el `href` apunta a un recurso de origen cruzado (`https://thirdparty.com/data.json`), el modelo de seguridad del navegador ignora el atributo `download` y las reglas estándar de navegación/disposición de contenido HTTP inline toman el control.

---

#### Respuestas del Ejercicio 2

1. **Obligatoriedad de `<img>` dentro de `<picture>`**:  
   El elemento `<picture>` es sintácticamente un contenedor estructural que proporciona criterios de selección a través de sus elementos hijo `<source>`. La etiqueta `<img>` anidada cumple dos funciones críticas: (a) actúa como la caja de renderizado real en el árbol DOM (los estilos CSS aplicados a `<picture>` no renderizan la imagen; los estilos de layout deben dirigirse a `img`), y (b) actúa como mecanismo de fallback para navegadores que no admiten `<picture>` o si ninguna de las media queries de `<source>` coincide.

2. **Mitigación de CLS con los Atributos `width` y `height`**:  
   Los motores de renderizado de los navegadores modernos extraen los valores enteros de `width` y `height` para calcular una relación de aspecto intrínseca (`aspect-ratio: width / height`). Cuando CSS establece `width: 100%; height: auto;`, el navegador calcula automáticamente la altura requerida según el ancho del contenedor *antes* de descargar el binario de la imagen. Esto reserva el espacio de layout vertical exacto, eliminando saltos de página y manteniendo el Cumulative Layout Shift (CLS) en 0.

3. **Penalización de Rendimiento de `loading="lazy"` Above-the-Fold**:  
   Aplicar `loading="lazy"` a una imagen ubicada en el viewport inicial primario retrasa su obtención (fetch). El motor de layout debe completar el parsing inicial de layout, determinar que el elemento se cruza con el viewport y luego iniciar la solicitud de la imagen. Esto añade un retraso de procesamiento a la métrica Largest Contentful Paint (LCP). Las imágenes above-the-fold deben usar carga eager (el valor por defecto) y opcionalmente `<link rel="preload">`.

---

#### Respuestas del Ejercicio 3

1. **Modos del Atributo `preload`**:  
   * `preload="none"`: Indica al navegador que NO almacene en búfer ningún dato de medios hasta que el usuario active explícitamente la reproducción. Ahorra ancho de banda del servidor.
   * `preload="metadata"`: Instruye al navegador a obtener únicamente los metadatos iniciales del encabezado del contenedor de medios (duración, dimensiones, disposición de pistas de audio, tasa de fotogramas).
   * `preload="auto"`: Dirige al navegador a almacenar en búfer de manera agresiva todo el archivo de medios en segundo plano antes de que comience la reproducción.

2. **Requisitos del Servidor HTTP para la Búsqueda de Medios (Seeking)**:  
   El servidor web debe admitir **HTTP Byte-Range Requests**. Debe responder a las solicitudes de rango HEAD o GET con:
   * Código de estado: `206 Partial Content`
   * Encabezado: `Accept-Ranges: bytes`
   * Encabezado: `Content-Range: bytes <start>-<end>/<total_bytes>`

3. **Requisito de `autoplay` y `muted`**:  
   Para evitar experiencias de usuario disruptivas, las Autoplay Policies de los navegadores modernos bloquean la reproducción automática de streams de audio/video con sonido sin interacciones de gestos previas del usuario. Establecer el atributo `muted` omite este bloqueo, permitiendo que la reproducción visual de video comience automáticamente.

---

#### Respuestas del Ejercicio 4

1. **Entorno Estricto de `sandbox=""`**:  
   Un atributo `sandbox` vacío aplica el nivel máximo de restricciones de seguridad. El documento embebido:
   * Tiene asignado un origen nulo único e aislado (evitando el acceso a cookies, localStorage y APIs del DOM).
   * Tiene la ejecución de JavaScript completamente deshabilitada.
   * No puede enviar formularios.
   * No puede abrir ventanas emergentes (popups) ni nuevas ventanas.
   * No puede ejecutar navegación de frame de nivel superior.

2. **Vulnerabilidad de Combinar `allow-scripts` y `allow-same-origin`**:  
   Si un iframe está alojado en el **mismo origen** que la aplicación principal y contiene tanto `allow-scripts` como `allow-same-origin`, el script embebido puede ejecutar JavaScript de forma programática para eliminar el atributo `sandbox` de su propio elemento frame contenedor (`window.parent.document.querySelector('iframe').removeAttribute('sandbox')`) y recargarse a sí mismo, escapando efectivamente de todas las restricciones del sandbox.

3. **`X-Frame-Options` vs CSP `frame-ancestors`**:  
   * `X-Frame-Options` es un encabezado HTTP heredado que solo admite directivas básicas (`DENY`, `SAMEORIGIN`). No puede evaluar políticas complejas de origen ni múltiples listas de dominios permitidos.
   * `Content-Security-Policy: frame-ancestors` es el estándar moderno. Permite definiciones granulares de listas blancas (por ejemplo, `frame-ancestors 'self' https://app.example.com https://*.partner.com`), admite contextos de workers y tiene prioridad sobre `X-Frame-Options` en los navegadores modernos.

---

#### Respuestas del Ejercicio 5

1. **Orden de Ejecución de `async`**:  
   El **Script B** se ejecutará primero. Los scripts `async` se obtienen completamente en segundo plano sin bloquear el parsing y se ejecutan inmediatamente al llegar. Dado que el Script B (10KB) termina de descargarse mucho más rápido a través de la red que el Script A (500KB), el Script B se ejecuta primero. `async` **no ofrece ninguna garantía en el orden de ejecución**.

2. **`crossorigin` en Preloading de Fuentes**:  
   La especificación CSS exige que las fuentes web se obtengan utilizando el **modo anónimo CORS (CORS Anonymous Mode)**, incluso cuando se sirven exactamente desde el mismo host de origen que el documento HTML. Si `<link rel="preload" as="font">` omite el atributo `crossorigin`, el navegador obtiene la fuente dos veces: una para la solicitud genérica de preload sin CORS y una segunda vez cuando el motor CSS activa la solicitud de fuente obligatoria con CORS.

3. **`preconnect` vs `dns-prefetch`**:  
   * `preconnect` realiza resolución DNS + handshake de 3 vías TCP + negociación TLS. Conlleva una mayor sobrecarga de sockets de red/CPU y debe reservarse para 1 a 3 orígenes críticos requeridos inmediatamente por el pipeline de renderizado.
   * `dns-prefetch` realiza **únicamente** la búsqueda inicial de DNS (resolución de dirección IP). Consume recursos mínimos. `dns-prefetch` debe usarse como fallback para navegadores heredados que carecen de soporte para `preconnect`, o para orígenes de dominio con los que se contactará más adelante durante la interacción del usuario.

</details>