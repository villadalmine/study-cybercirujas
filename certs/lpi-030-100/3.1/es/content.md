# LPI 030-100: Topic 3.1 – CSS Basics
**Exam Module:** 3. CSS Content Styling  
**Topic:** 3.1 CSS Basics  
**Target Certification:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Weight:** 2.5 (Profundidad técnica escalada para Senior SRE & Platform Architecture)

---

## 1. Motivación y problema arquitectónico de producción

En las arquitecturas web cloud-native modernas, Cascading Style Sheets (CSS) a menudo se tratan simplemente como metadatos de presentación. Sin embargo, desde una perspectiva de SRE y Platform Architecture, **CSS es una dependencia de bloqueo síncrona en la ruta crítica** que gobierna directamente el **Critical Rendering Path (CRP)** del motor de cliente del navegador.

```
       [ HTML Stream ]
              │
              ▼
       [ DOM Construction ] ──────┐
                                  ├─► [ Render Tree ] ──► [ Layout ] ──► [ Paint ] ──► [ Composite ]
       [ CSS Stream ]             │
              │                   │
              ▼                   │
       [ CSSOM Construction ] ────┘
  (Blocks Render Tree Assembly)
```

### El problema arquitectónico: CSS como un cuello de botella de bloqueo de renderizado (Render-Blocking Bottleneck)

Cuando un motor de navegador (por ejemplo, Blink, Gecko, WebKit) analiza un documento HTML y encuentra un recurso CSS externo (`<link rel="stylesheet">`), detiene de inmediato la **construcción del Render Tree**. Aunque el análisis de HTML DOM puede continuar de forma concurrente (en algunas pasadas de tokenización), el navegador **no puede pintar ningún píxel en la pantalla** hasta que el CSS Object Model (**CSSOM**) esté completamente construido. 

Esta restricción arquitectónica introduce severos modos de falla en producción si no se diseña adecuadamente:

1. **Estancamiento de First Contentful Paint (FCP):** Una obtención de CSS lenta a través de la red (alto Time-To-First-Byte, picos de latencia en CDNs o payloads estáticos no comprimidos) bloquea el navegador cliente en un estado en blanco.
2. **Cumulative Layout Shift (CLS):** Hojas de estilo impredecibles o inyectadas de forma asíncrona recalculan la geometría tarde en el ciclo de vida del renderizado, desencadenando costosos recalculamientos de diseño (reflows) y repaints que degradan las Core Web Vitals.
3. **Contaminación de memoria por cascada y especificidad (Cascade and Specificity Memory Pollution):** Declaraciones de reglas mal estructuradas con gráficos de especificidad profundos causan complejidad de ejecución durante el rule matching del navegador, aumentando la utilización de la CPU durante la mutación del DOM.
4. **Violaciones de Content Security Policy (CSP):** El uso no restringido de inline styles (`style="..."`) abre vectores de ataque para Cross-Site Scripting (XSS) y exfiltración de datos basada en CSS, lo que obliga a los equipos de plataforma a configurar cabeceras de seguridad estrictas (`style-src`).

---

## 2. Mecánica teórica: Parser de CSS, CSSOM y matemática de especificidad

### Mecánica del motor de CSS: Del parser al CSSOM

El procesamiento de CSS sigue un pipeline determinista ejecutado dentro del hilo del motor del navegador:

1. **De bytes a caracteres:** Los bytes sin procesar de la red (`0x68 0x31...`) se decodifican según la codificación de caracteres (UTF-8).
2. **Tokenización:** Los caracteres se convierten en tokens (`IdentToken`, `FunctionToken`, `HashToken`, `DelimToken`).
3. **Generación de nodos:** Los tokens se mapean a nodos de regla que contienen selectores, propiedades, valores y flags (`!important`).
4. **Construcción del CSSOM:** El parser construye una estructura de árbol que representa las reglas jerárquicas en cascada.

```
Bytes  ──►  Characters  ──►  Tokens  ──►  Nodes  ──►  CSSOM Tree
```

### Matemática de vectores de especificidad

Cuando múltiples reglas apuntan al mismo nodo del DOM, el motor del navegador evalúa la precedencia de las reglas utilizando un vector de especificidad de 4 tuplas:

$$\mathbf{S} = (a, b, c, d)$$

Donde:
* $a$: Inline styles (definidos directamente en el atributo HTML `style="..."`) $\rightarrow$ Valor: $1$ o $0$.
* $b$: Conteo de selectores de ID (`#header`, `#nav`) $\rightarrow$ Conteo entero.
* $c$: Selectores de clase, selectores de atributos y pseudoclases (`.btn`, `[type="text"]`, `:hover`) $\rightarrow$ Conteo entero.
* $d$: Selectores de elemento (tipo) y pseudoelementos (`div`, `h1`, `::before`) $\rightarrow$ Conteo entero.

> **Nota:** El selector universal (`*`), los combinadores (`+`, `>`, `~`, ` `) y la pseudoclase de negación (`:not()`) añaden especificidad $0$ a la tupla del vector (aunque los selectores dentro de `:not()` sí añaden especificidad).

#### Algoritmo de comparación de especificidad
Las tuplas de vectores se comparan lexicográficamente de izquierda a derecha ($a \rightarrow b \rightarrow c \rightarrow d$):

$$\mathbf{S_1} > \mathbf{S_2} \iff \exists i \in \{a,b,c,d\} \text{ s.t. } S_{1,i} > S_{2,i} \land (\forall j < i, S_{1,j} = S_{2,j})$$

```
Example Evaluation:
Rule 1: #nav .menu-item a:hover     => S1 = (0, 1, 2, 1)
Rule 2: body #container div ul li a => S2 = (0, 1, 0, 5)

Comparison:
S1[a] == S2[a] == 0
S1[b] == S2[b] == 1
S1[c] (2) > S2[c] (0) => Rule 1 WINS, regardless of S2 having 5 element selectors.
```

---

## 3. Comparaciones técnicas y matrices de trade-offs

### Tabla 3.1: Comparación de métodos de integración de CSS

| Característica / Métrica | Inline Styles (`style="..."`) | Internal Styles (`<style>`) | External Stylesheet (`<link>`) |
| :--- | :--- | :--- | :--- |
| **Ubicación** | Directamente en atributos del DOM | Bloque HTML `<head>` | Archivo `.css` independiente a través de HTTP |
| **Sobrecarga de red** | Duplica el código CSS en cada elemento; infla el payload HTML. | Una sola obtención por página HTML; no se puede compartir entre rutas. | Solicitud HTTP adicional (mitigada por HTTP/2/3 y HTTP Caching). |
| **Capacidad de almacenamiento en caché del navegador**| No almacenable en caché independientemente del HTML DOM. | Vinculado al TTL de almacenamiento en caché del documento HTML. | **Alta**: Almacenable en caché en la capa CDN/Navegador (`immutable`). |
| **Cumplimiento de CSP** | Requiere `'unsafe-inline'` en `style-src` (Riesgo de seguridad). | Requiere Hashes SHA-256 o Nonces en cabeceras CSP. | Totalmente conforme a través de declaraciones de dominios de origen seguros. |
| **Mantenibilidad** | La peor: Viola DRY; imposible de mantener globalmente. | Moderada: Alcance restringido a un solo documento HTML. | **Óptima**: Design tokens centralizados y hojas de estilo modulares. |
| **Impacto en el renderizado** | Analizado durante la tokenización del DOM; alto peso en el árbol DOM. | Bloquea el renderizado inicial; analizado antes de finalizar el body del DOM. | Bloquea el renderizado hasta que se obtiene/analiza; soporta `preload` asíncrono. |

### Tabla 3.2: Estrategias de entrega de CSS para plataformas de alta disponibilidad

| Estrategia | Mecánica de implementación | Impacto en latencia de FCP | Impacto en ancho de banda y CPU | Caso de uso recomendado |
| :--- | :--- | :--- | :--- | :--- |
| **Enlace externo síncrono** | `<link rel="stylesheet" href="app.css">` | Alto (Bloquea el renderizado hasta completar la descarga por red) | Transferencia de red estándar; almacenado en caché tras la carga inicial | Bundles CSS pequeños (umbral de ruta crítica < 14 KB) |
| **Inlining de ruta crítica** | Incluye en línea el CSS ATF (Above-the-Fold) en `<style>`, difiere el CSS restante | **Óptimo** (Cero bloqueo de red para el pintado inicial del viewport) | Ligero aumento del tamaño de HTML; transmisión duplicada si HTML no se almacena en caché | Landing Pages empresariales, entrega en el Edge para E-commerce |
| **Preload y swap asíncrono** | `<link rel="preload" as="style" href="defer.css" onload="this.rel='stylesheet'">` | Bajo (Descarga el archivo en un hilo en segundo plano sin bloquear el CRP) | Obtención no bloqueante; breve retraso antes de aplicar estilos no críticos | Elementos de UI no críticos, pies de página, temas de modales |
| **HTTP/2 Server Push (Legacy) / Early Hints (103)** | El servidor emite HTTP `103 Early Hints` con cabecera de enlace a `<style.css>` antes del cuerpo de respuesta | Muy bajo (Inicia la descarga de assets mientras ocurre la generación de HTML) | Maximiza la utilización del canal; requiere stack de servidor HTTP/2 o HTTP/3 | Micro-frontends renderizados en el lado del servidor (SSR) |

---

## 4. Manifests completos y sintácticamente válidos de infraestructura de producción y aplicación

Para demostrar el despliegue en producción de assets estáticos de CSS, proporcionamos un stack de infraestructura completo, sin recortes y sintácticamente válido, que incluye una configuración de servidor de archivos estáticos Nginx, manifests de despliegue de Kubernetes y código de aplicación HTML5/CSS3 listo para producción.

### 4.1 Configuración de servidor de assets estáticos CSS en Nginx (`nginx.conf`)

Esta configuración optimiza el manejo de tipos MIME, habilita la compresión Brotli/Gzip, fuerza HTTP/2, configura cabeceras de seguridad (CSP) y establece almacenamiento en caché inmutable para CSS estático.

```nginx
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Performance Tuning
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Compression Configuration
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/css
        text/plain
        text/javascript
        application/javascript
        application/json
        image/svg+xml;

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name _;

        root /usr/share/nginx/html;
        index index.html;

        # Security Headers & Content Security Policy (CSP)
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'nonce-rAnd0mN0nc3V4lu3'; object-src 'none'; base-uri 'self';" always;

        # Explicit handling for CSS Assets with Hashing Cache Strategy
        location ~* \.(?:css)$ {
            types {
                text/css css;
            }
            add_header Content-Type "text/css; charset=utf-8";
            add_header Cache-Control "public, max-age=31536000, immutable";
            add_header Access-Control-Allow-Origin "*";
            access_log off;
            expires 365d;
        }

        # Root fallback
        location / {
            try_files $uri $uri/ /index.html;
            add_header Cache-Control "no-cache, must-revalidate";
        }
    }
}
```

### 4.2 Manifest de infraestructura de producción en Kubernetes (`k8s-css-asset-delivery.yaml`)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: static-assets
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-css-config
  namespace: static-assets
data:
  nginx.conf: |
    user nginx;
    worker_processes auto;
    events { worker_connections 1024; }
    http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;
        server {
            listen 80;
            root /usr/share/nginx/html;
            location ~* \.css$ {
                add_header Content-Type "text/css; charset=utf-8";
                add_header Cache-Control "public, max-age=31536000, immutable";
            }
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: css-asset-server
  namespace: static-assets
  labels:
    app.kubernetes.io/name: css-asset-server
    app.kubernetes.io/component: cdn-edge
spec:
  replicas: 3
  selector:
    matchLabels:
      app: css-asset-server
  template:
    metadata:
      labels:
        app: css-asset-server
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
          name: http
        resources:
          limits:
            cpu: "250m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "32Mi"
        livenessProbe:
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 2
          periodSeconds: 5
        volumeMounts:
        - name: config-volume
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: config-volume
        configMap:
          name: nginx-css-config
---
apiVersion: v1
kind: Service
metadata:
  name: css-asset-service
  namespace: static-assets
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    name: http
  selector:
    app: css-asset-server
```

### 4.3 Código de aplicación HTML5 & CSS3 validado para producción

#### Archivo 1: `assets/css/main.v1a2b3c4.css`

```css
/* ==========================================================================
   PRODUCTION DESIGN TOKENS & RESET (CSS VARIABLES)
   ========================================================================== */
:root {
    --color-primary: #0284c7;
    --color-primary-hover: #0369a1;
    --color-background: #0f172a;
    --color-surface: #1e293b;
    --color-text-main: #f8fafc;
    --color-text-muted: #94a3b8;
    
    --font-family-base: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    --font-family-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    
    --spacing-xs: 0.25rem;
    --spacing-sm: 0.5rem;
    --spacing-md: 1.0rem;
    --spacing-lg: 1.5rem;
    --spacing-xl: 2.0rem;

    --border-radius-sm: 0.375rem;
    --border-radius-md: 0.5rem;

    --transition-fast: 150ms ease-in-out;
}

/* CSS Reset for Consistent Cross-Browser Layout Base */
*, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
}

body {
    background-color: var(--color-background);
    color: var(--color-text-main);
    font-family: var(--font-family-base);
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
}

/* ==========================================================================
   COMPONENT STYLES (SPECIFICITY CONSTRUCTIVE DEMONSTRATION)
   ========================================================================== */

/* Element Selector: Specificity (0,0,0,1) */
header {
    background-color: var(--color-surface);
    padding: var(--spacing-md) var(--spacing-lg);
    border-bottom: 1px solid #334155;
}

/* Class Selector: Specificity (0,0,1,0) */
.nav-container {
    display: flex;
    justify-content: space-between;
    align-items: center;
    max-width: 1200px;
    margin: 0 auto;
}

/* Attribute Selector + Pseudo-class: Specificity (0,0,2,0) */
.nav-link[data-active="true"]:hover {
    color: var(--color-primary-hover);
    text-decoration: underline;
}

/* ID Selector: Specificity (0,1,0,0) */
#main-content {
    max-width: 1200px;
    margin: var(--spacing-xl) auto;
    padding: 0 var(--spacing-md);
}

.card {
    background-color: var(--color-surface);
    border-radius: var(--border-radius-md);
    padding: var(--spacing-lg);
    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
}

.card .title {
    color: var(--color-primary);
    font-size: 1.5rem;
    margin-bottom: var(--spacing-sm);
}

.code-block {
    font-family: var(--font-family-mono);
    background-color: #020617;
    padding: var(--spacing-md);
    border-radius: var(--border-radius-sm);
    color: #38bdf8;
    overflow-x: auto;
}
```

#### Archivo 2: `index.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Production SRE Architecture Guide for LPI 030-100 CSS Basics">
    <title>LPI 030-100 Topic 3.1: CSS Basics Architecture</title>

    <!-- Critical Path Above-The-Fold Inline CSS (Prevents Render-Blocking FCP) -->
    <style nonce="rAnd0mN0nc3V4lu3">
        body { background-color: #0f172a; color: #f8fafc; font-family: system-ui, sans-serif; }
        .critical-spinner { display: none; }
    </style>

    <!-- External Version-Hashed CSS Stylesheet -->
    <link rel="stylesheet" href="assets/css/main.v1a2b3c4.css" type="text/css">
</head>
<body>
    <header>
        <div class="nav-container">
            <h1>Platform Architecture SRE Guide</h1>
            <nav>
                <a href="#main" class="nav-link" data-active="true">Dashboard</a>
            </nav>
        </div>
    </header>

    <main id="main-content">
        <section class="card">
            <h2 class="title">Topic 3.1 CSS Execution Diagnostics</h2>
            <p>Evaluating critical path CSSOM generation and specificity compliance.</p>
            <pre class="code-block"><code>$ curl -Iv https://cdn.platform.internal/assets/css/main.v1a2b3c4.css</code></pre>
        </section>
    </main>
</body>
</html>
```

---

## 5. Comandos CLI reales y salidas esperadas de terminal

Los SRE de plataforma deben inspeccionar los assets estáticos directamente mediante herramientas de línea de comandos para verificar los tipos MIME, cabeceras HTTP, algoritmos de compresión y la eficiencia de las reglas de especificidad.

### 5.1 Verificación de cabeceras HTTP/2, tipo MIME y Cache-Control mediante `curl`

Ejecutá `curl` con inspección de cabeceras (`-I`) y registro detallado (`-v`) contra el servicio de assets desplegado:

```bash
curl -Iv https://localhost:8080/assets/css/main.v1a2b3c4.css -H "Accept-Encoding: gzip, deflate, br"
```

#### Salida esperada de terminal:
```text
*   Trying 127.0.0.1:8080...
* Connected to localhost (127.0.0.1) port 8080
* ALPN: offers h2, http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN: server accepted h2
> HEAD /assets/css/main.v1a2b3c4.css HTTP/2
> Host: localhost:8080
> User-Agent: curl/8.5.0
> Accept: */*
> Accept-Encoding: gzip, deflate, br
> 
< HTTP/2 200 
< server: nginx/1.25.3
< date: Fri, 07 Aug 2026 05:15:00 GMT
< content-type: text/css; charset=utf-8
< content-length: 742
< last-modified: Fri, 07 Aug 2026 04:00:00 GMT
< etag: "66b2ef80-2e6"
< accept-ranges: bytes
< content-encoding: br
< cache-control: public, max-age=31536000, immutable
< access-control-allow-origin: *
< x-content-type-options: nosniff
< content-security-policy: default-src 'self'; style-src 'self' 'nonce-rAnd0mN0nc3V4lu3';
<
```

### 5.2 Linting de especificidad de CSS y violaciones de sintaxis mediante el CLI de `stylelint`

Ejecutá `stylelint` para detectar errores de sintaxis, reglas de alta especificidad o declaraciones `!important` prohibidas:

```bash
npx stylelint "assets/css/*.css" --config '{"rules": {"selector-max-specificity": "0,3,0", "declaration-no-important": true}}'
```

#### Salida esperada de terminal:
```text
assets/css/main.v1a2b3c4.css
 42:5  ✖  Unexpected !important in property "color"   declaration-no-important
 89:1  ✖  Expected specificity of "#main #nav .item" to be less than 0,3,0   selector-max-specificity

✖ 2 problems (2 errors, 0 warnings)
```

### 5.3 Auditoría de CSS con bloqueo de renderizado mediante el CLI de Google Lighthouse

Ejecutá una auditoría de Lighthouse en Chrome headless para verificar que CSS no esté estancando el First Contentful Paint (FCP):

```bash
npx lighthouse http://localhost:8080 --only-categories=performance --chrome-flags="--headless" --output=json | jq '.audits["render-blocking-resources"]'
```

#### Salida esperada de terminal:
```json
{
  "id": "render-blocking-resources",
  "title": "Eliminate render-blocking resources",
  "description": "Resources are blocking the first paint of your page. Consider delivering critical CSS inline and deferring all non-critical CSS.",
  "score": 1,
  "numericValue": 0,
  "numericUnit": "millisecond",
  "displayValue": "Potential savings of 0 ms",
  "details": {
    "type": "table",
    "items": [],
    "overallSavingsMs": 0
  }
}
```

---

## 6. Guía de diagnóstico y verificación de fallas

### Matriz diagnóstica para fallas de CSS en producción

```
                       [ Issue Detected ]
                               │
       ┌───────────────────────┴───────────────────────┐
       ▼                                               ▼
[ Styles Not Applied ]                       [ Rendering Stalled / FCP ]
       │                                               │
       ├─► Check HTTP Content-Type                     ├─► Check Asset Payload Size
       │   (Must be `text/css`)                        │   (Compress via Gzip/Brotli)
       │                                               │
       ├─► Check CSP Restrictions                      └─► Check Preload / Critical CSS
       │   (`Refused to load style...`)                    (Ensure non-blocking fetch)
       │
       └─► Calculate Specificity Vector
           (Determine if overridden by higher tuple)
```

#### Escenario de incidente 1: `Refused to apply style because its MIME type ('text/html') is not 'text/css'`
* **Causa raíz:** El navegador solicitó un archivo CSS, pero el servidor Nginx/Ingress upstream devolvió una página HTML de respaldo `404 Not Found` con `Content-Type: text/html`.
* **Pasos de verificación:**
  1. Inspeccioná la pestaña de red (Network tab) o ejecutá `curl -I https://<domain>/assets/css/missing.css`.
  2. Verificá si `Content-Type` reporta `text/html` en lugar de `text/css`.
* **Remediación:** Corregí el enrutamiento de assets estáticos dentro de la directiva `try_files` de Nginx y asegurá la correcta propagación del hash de los assets de build.

#### Escenario de incidente 2: Falla por sobrescritura de regla CSS (colisión de especificidad)
* **Causa raíz:** Un desarrollador agregó una regla de clase `.button { color: red; }` esperando dar estilo a un enlace, pero una regla existente `nav ul li a` (Especificidad `0,0,0,4`) sobrescribe a `.button` (Especificidad `0,0,1,0`).
* **Pasos de verificación:**
  1. Calculá los vectores de especificidad:
     * Regla A: `nav ul li a` $\rightarrow \mathbf{S_A} = (0, 0, 0, 4)$
     * Regla B: `.button` $\rightarrow \mathbf{S_B} = (0, 0, 1, 0)$
  2. La regla B tiene un conteo de clases más alto ($c=1 > c=0$), por lo que la regla B *gana*. Sin embargo, si la regla A fuera `body #nav a` $\rightarrow \mathbf{S_A} = (0, 1, 0, 2)$, la regla A gana porque $b=1 > b=0$.
* **Remediación:** Refactorizá los selectores a un peso equivalente o aprovechá la metodología BEM (Block Element Modifier) para mantener la especificidad plana: `(0, 0, 1, 0)`.

#### Escenario de incidente 3: CSP bloqueando estilos críticos inline
* **Causa raíz:** La consola del navegador muestra: `Refused to apply inline style because it violates the following Content Security Policy directive: "style-src 'self'"`.
* **Pasos de verificación:**
  1. Inspeccioná la consola del navegador en busca de reportes de violación de CSP.
  2. Verificá las cabeceras de respuesta usando `curl -Iv`.
* **Remediación:** Adjuntá un hash criptográfico válido (SHA-256) del bloque `<style>` inline o pasá un `nonce` dinámico por solicitud a la cabecera CSP:
  `style-src 'self' 'nonce-<random-base64>'`.

---

## 7. Referencias

* **Linux Professional Institute (LPI) Web Development Essentials:**  
  [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **LPI Wiki – Exam 030-100 Objectives:**  
  [https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0](https://wiki.lpi.org/wiki/Web_Development_Essentials_Objectives_V1.0)
* **W3C CSS Syntax Module Level 3 Specification:**  
  [https://www.w3.org/TR/css-syntax-3/](https://www.w3.org/TR/css-syntax-3/)
* **W3C CSS Selectors Level 4 Specificity Calculations:**  
  [https://www.w3.org/TR/selectors-4/#specificity-rules](https://www.w3.org/TR/selectors-4/#specificity-rules)
* **MDN Web Docs – The Critical Rendering Path:**  
  [https://developer.mozilla.org/en-US/docs/Web/Performance/Critical_rendering_path](https://developer.mozilla.org/en-US/docs/Web/Performance/Critical_rendering_path)