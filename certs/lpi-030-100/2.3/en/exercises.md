# LPI 030-100 (v1.0) Topic 2.3: HTML References and Embedded Resources
## Guided Production-Grade Exercises & Diagnostic Labs

**Topic Weight:** 5  
**Target Certification:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Official Reference:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  
**Standards Specifications:** [WHATWG HTML Living Standard](https://html.spec.whatwg.org/multipage/), [RFC 3986 - Uniform Resource Identifier (URI): Generic Syntax](https://datatracker.ietf.org/doc/html/rfc3986), [W3C Fetch Standard](https://fetch.spec.whatwg.org/)

---

### Prerequisites & Lab Setup
Ensure you have a modern Unix-like terminal environment with `curl`, `python3` (or `npx http-server`), and standard network inspection utilities installed.

Execute the following bash commands to establish your baseline project tree:

```bash
mkdir -p lpi-lab-2.3/{css,js,media/images,media/video,docs,api}
cd lpi-lab-2.3
touch index.html docs/manual.html css/styles.css js/app.js
```

---

### Exercise 1: URL Resolution Mechanics, Path Traversal, and HTTP Header Diagnostics

#### Production Architecture Overview
URL resolution in Web Browsers follows strict algorithms specified in **RFC 3986**. The browser resolves relative URIs against a **Base URI** (by default, the current document's address URL or modified via `<base href="...">`). 

* **Absolute URLs** (`https://example.com/assets/main.css`): Contain scheme, authority, path, and optional query/fragment. Immune to Base URI shifts.
* **Protocol-Relative URLs** (`//cdn.example.com/lib.js`): Inherit the current page's scheme (`http:` vs `https:`). *Deprecated in modern HTTPS-only architectures to prevent Mixed Content security downgrades.*
* **Root-Relative Paths** (`/css/styles.css`): Resolved from the top-level origin domain root.
* **Document-Relative Paths** (`../js/app.js`): Resolved relative to the current document path directory.

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

#### Step 1.1: Create Document-Relative and Root-Relative References
Create the file `docs/manual.html` with references demonstrating path resolution across nested subdirectories:

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

#### Step 1.2: Launch Local Test Server & Validate Path Traversal via cURL
Run a local Web server to mimic an NGINX edge web server serving static files:

```bash
python3 -m http.server 8080 &
SERVER_PID=$!
```

Verify response headers and status codes using `curl` with verbosity enabled:

```bash
curl -I -H "User-Agent: SRE-Diagnostic-Agent" http://localhost:8080/docs/manual.html
```

*Expected Terminal Output:*
```http
HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.10.12
Date: Thu, 06 Aug 2026 18:55:00 GMT
Content-type: text/html
Content-Length: 954
Last-Modified: Thu, 06 Aug 2026 18:54:12 GMT
```

Verify relative resource loading by requesting the CSS file referenced via path traversal:

```bash
curl -i http://localhost:8080/css/styles.css
```

---

#### Comprehension Questions - Exercise 1

1. If `<base href="https://cdn.enterprise.io/assets/v2/">` is declared in an HTML document located at `https://app.enterprise.io/dashboard/index.html`, to what exact absolute URL will `<a href="../reports/summary.pdf">` resolve?
2. What are the security implications of using `target="_blank"` without `rel="noopener noreferrer"` on external hyperlinks?
3. When using the `download` attribute on an `<a>` element (e.g., `<a href="https://thirdparty.com/data.json" download>`), under what specific condition will modern browsers ignore the `download` directive and perform inline navigation instead?

---

### Exercise 2: Responsive Embedded Images and Image Pipeline Mechanics

#### Production Architecture Overview
Embedding raster and vector graphics efficiently requires managing performance trade-offs between dynamic layout shifts (CLS), byte payload overhead, and responsive viewport density targeting.

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

* **`<img>` Attributes**:
  * `alt`: Accessibility fallback tree text. Mandatory for valid spec compliance.
  * `width` & `height`: Defines native aspect ratio (e.g., `aspect-ratio: width / height`) to allow browser layout engines to reserve space *before* image downloading completes, preventing Cumulative Layout Shift (CLS).
  * `loading="lazy"`: Defers fetch until image reaches a threshold distance from visual viewport based on IntersectionObserver metrics.
  * `decoding="async"`: Decodes image off the main rendering thread to reduce frame drops.
* **`<picture>` Element**: A wrapper around `<source>` tags allowing explicit declarative Art Direction (media queries) and Format Negotiation (AVIF -> WebP -> PNG/JPG fallback).

#### Step 2.1: Construct Syntactically Valid Responsive Graphic Markup
Update `index.html` with an optimized responsive image block:

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

#### Step 2.2: Simulate Browser Format Negotiation with cURL
Inspect HTTP content-negotiation headers transmitted by modern client browsers when requesting image endpoints:

```bash
curl -I -H "Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" http://localhost:8080/media/images/chart-fallback.png
```

---

#### Comprehension Questions - Exercise 2

1. Why must an `<img>` tag always be included as a child inside a `<picture>` element?
2. How do explicit `width` and `height` attributes on modern `<img>` elements mitigate Cumulative Layout Shift (CLS), even when CSS overrides the image's displayed width to `100%`?
3. If an `<img>` element includes both `loading="lazy"` and is positioned within the above-the-fold viewport baseline, what performance penalty occurs?

---

### Exercise 3: HTML5 Media Streams (`<audio>` & `<video>`) and Byte-Range Fetching

#### Production Architecture Overview
HTML5 media integration replaces legacy external plugins with native browser decoding engines. Modern video delivery depends on HTTP/1.1 Byte-Range requests (`Range: bytes=start-end`) to support dynamic seeking and incremental buffering without downloading entire media payloads.

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

#### Step 3.1: Construct Complete Syntactically Valid Video Markup
Create an HTML5 media block featuring multiple source fallback codecs, subtitles (`<track>`), and custom video controls attributes:

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

#### Step 3.2: Verify Partial Content Byte-Range Streaming via CLI
Test whether your web server properly handles partial content streaming (HTTP status code `206`) necessary for fast seeking in HTML5 audio/video elements.

Generate a dummy 1MB binary file representing a video stream:

```bash
dd if=/dev/zero of=media/video/incident-briefing.mp4 bs=1M count=1
```

Send a byte-range request targeting the first 1024 bytes of the video payload:

```bash
curl -i -H "Range: bytes=0-1023" http://localhost:8080/media/video/incident-briefing.mp4
```

*Expected Terminal Output:*
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

#### Comprehension Questions - Exercise 3

1. What is the operational difference between `preload="none"`, `preload="metadata"`, and `preload="auto"` on an HTML5 `<video>` element?
2. What HTTP response status code and headers must a production Web server return to allow a browser to seek freely to arbitrary timestamps within an HTML5 `<video>` stream?
3. Why is the `muted` attribute mandatory on modern browsers if an engineer intends to activate the `autoplay` attribute on a `<video>` tag?

---

### Exercise 4: Inline Frames (`<iframe>`), Contextual Sandboxing, and Security Boundaries

#### Production Architecture Overview
The `<iframe>` element creates a nested browsing context, embedding an external HTML document inside the current host document. Unrestricted iframes present severe security attack vectors including Clickjacking, Cross-Site Scripting (XSS) propagation, and unauthorized DOM access to `window.parent`.

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

#### Step 4.1: Implement Hardened `<iframe>` Integration
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

#### Step 4.2: Diagnose Frame Restriction Headers via cURL
Web sites prevent themselves from being embedded in unauthorized `<iframe>` containers to prevent Clickjacking. Inspect the security headers of target sites using `curl`:

```bash
curl -I -s https://www.google.com | grep -iE "x-frame-options|content-security-policy"
```

*Expected Terminal Output:*
```http
x-frame-options: SAMEORIGIN
content-security-policy: frame-ancestors 'self';
```

---

#### Comprehension Questions - Exercise 4

1. What specific security boundary occurs when an `<iframe>` has the `sandbox=""` attribute set without any values?
2. If an iframe contains `sandbox="allow-scripts allow-same-origin"`, why does this combination undermine the security guarantees of the sandbox?
3. What is the fundamental functional difference between the `X-Frame-Options` HTTP response header and the `Content-Security-Policy: frame-ancestors` directive?

---

### Exercise 5: Critical Rendering Path, Resource Linking, and Script Execution Modes

#### Production Architecture Overview
External style sheets (`<link rel="stylesheet">`) and scripts (`<script>`) directly control HTML parser blocking behavior, Critical Rendering Path optimization, and Time-To-Interactive (TTI).

```
Parser Blocked vs Async/Defer Flow:

HTML Parser:  ───[Parse DOM]───►[BLOCKED BY SCRIPT]───────────────►[Resume DOM Parse]──►
Normal Script:                   └───[Fetch JS]───►[Execute JS]──┘

HTML Parser:  ───[Parse DOM]──────────────────────────────────────►[DOM Complete]───────►
Defer Script:  └───[Fetch JS (Background)]────────────────────────►[Execute JS]

HTML Parser:  ───[Parse DOM]──────────────►[PAUSED]───────────────►[Resume DOM Parse]──►
Async Script:  └───[Fetch JS (Background)]─►[Execute JS Immediately]──┘
```

* **`<script src="app.js">` (Default)**: Pauses HTML parsing immediately, fetches the script synchronously over the network, executes it immediately, and then resumes HTML parsing.
* **`<script src="app.js" defer>`**: Fetches the script asynchronously in the background while HTML parsing continues. Executes scripts in **exact DOM order** *after* DOM parsing completes, right before `DOMContentLoaded`.
* **`<script src="app.js" async>`**: Fetches the script asynchronously in the background. Executes **immediately upon fetch completion**, pausing the HTML parser if active. Order of execution is non-deterministic.
* **`<script type="module" src="app.js">`**: Automatically treated as `defer` by default. Scoped strictly to ES modules.
* **`<link rel="preload" href="..." as="...">`**: Mandatory high-priority fetch instruction to download critical assets (fonts, key CSS) early in the waterfall.
* **`<link rel="preconnect" href="...">`**: Initiates early DNS lookup, TLS handshake, and TCP connection establishment to third-party domains.

#### Step 5.1: Build an Optimized Document Head & Asset Pipeline
Update the `<head>` tag of `index.html` with correct resource link relationships:

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

#### Step 5.2: Trace Resource Hints and Network Headers via CLI
Inspect DNS prefetching and HTTP link headers via cURL:

```bash
curl -I http://localhost:8080/index.html
```

---

#### Comprehension Questions - Exercise 5

1. If script A (`<script src="a.js" async>`) is 500KB and script B (`<script src="b.js" async>`) is 10KB, which script is guaranteed to execute first?
2. Why is the `crossorigin` attribute strictly required on `<link rel="preload" href="font.woff2" as="font" crossorigin>` even if the font file resides on the exact same origin server?
3. What is the difference between `<link rel="preconnect">` and `<link rel="dns-prefetch">`, and when should `dns-prefetch` be used as a fallback?

---

<details>
<summary><strong>Click here to reveal the Solutions and Detailed Technical Explanations</strong></summary>

### Solutions & Answer Key

#### Exercise 1 Answers

1. **URL Resolution Target**: `https://cdn.enterprise.io/assets/reports/summary.pdf`  
   *Explanation*: The `<base>` tag re-defines the base URL for all relative references in the document to `https://cdn.enterprise.io/assets/v2/`. Resolving `../reports/summary.pdf` pops the current folder level (`v2/`) from the base path, yielding `https://cdn.enterprise.io/assets/reports/summary.pdf`, completely ignoring the host page's actual URI location (`https://app.enterprise.io/dashboard/index.html`).

2. **Security Implications of Missing `rel="noopener"`**:  
   When opening a link using `target="_blank"` without `rel="noopener"`, the target page gains access to the opening window's execution context via the JavaScript `window.opener` object. The linked external site can execute `window.opener.location = "https://phishing-attack.com"`, silently redirecting the user's background tab to a malicious site. Including `rel="noopener"` sets `window.opener` to `null`. Note: Modern browsers (Chrome 88+, Firefox 79+, Safari 12.1+) set `rel="noopener"` by default for `target="_blank"`, but explicitly defining `rel="noopener noreferrer"` remains mandatory for defensive legacy cross-browser support.

3. **Conditions Overriding the `download` Attribute**:  
   The `download` attribute only functions for **same-origin URLs** or blob/data schemes. If the `href` points to a cross-origin resource (`https://thirdparty.com/data.json`), the browser security model ignores the `download` attribute, and standard inline HTTP content disposition/navigation rules take over.

---

#### Exercise 2 Answers

1. **Mandatory `<img>` inside `<picture>`**:  
   The `<picture>` element is syntactically a structural wrapper that provides selection criteria via its `<source>` child elements. The nested `<img>` tag serves two critical roles: (a) It acts as the actual rendering box in the DOM tree (CSS styles applied to `<picture>` do not render the image; layout styles must target `img`), and (b) It acts as the fallback mechanism for browsers that do not support `<picture>` or if none of the `<source>` media queries match.

2. **Mitigating CLS with `width` and `height` Attributes**:  
   Modern browser rendering engines extract the `width` and `height` integer values to calculate an intrinsic aspect ratio (`aspect-ratio: width / height`). When CSS sets `width: 100%; height: auto;`, the browser automatically computes the required height based on the container width *before* downloading the image binary. This reserves the exact vertical layout space, eliminating page jumps and keeping Cumulative Layout Shift (CLS) at 0.

3. **Performance Penalty of `loading="lazy"` Above-the-Fold**:  
   Applying `loading="lazy"` to an image located in the primary initial viewport delays its fetch. The layout engine must complete initial layout parsing, determine that the element intersects the viewport, and then initiate the image request. This adds processing delay to the Largest Contentful Paint (LCP) metric. Above-the-fold images should use eager loading (the default) and optionally `<link rel="preload">`.

---

#### Exercise 3 Answers

1. **`preload` Attribute Modes**:  
   * `preload="none"`: Hints to the browser NOT to buffer any media data until the user explicitly triggers play. Saves server bandwidth.
   * `preload="metadata"`: Instructs the browser to fetch only the initial media container header metadata (duration, dimensions, audio track layout, frame rate).
   * `preload="auto"`: Directs the browser to aggressively buffer the entire media file in the background before playback begins.

2. **HTTP Server Requirements for Media Seeking**:  
   The web server must support **HTTP Byte-Range Requests**. It must reply to HEAD or GET range requests with:
   * Status Code: `206 Partial Content`
   * Header: `Accept-Ranges: bytes`
   * Header: `Content-Range: bytes <start>-<end>/<total_bytes>`

3. **`autoplay` and `muted` Requirement**:  
   To prevent disruptive user experiences, modern browser Autoplay Policies block unmuted audio/video streams from playing automatically without explicit prior user gesture interactions. Setting the `muted` attribute bypasses this block, allowing visual video playback to start automatically.

---

#### Exercise 4 Answers

1. **Strict `sandbox=""` Environment**:  
   An empty `sandbox` attribute applies the maximum level of security restrictions. The embedded document:
   * Is assigned a unique, isolated null origin (preventing access to cookies, localStorage, and DOM APIs).
   * Has JavaScript execution completely disabled.
   * Cannot submit forms.
   * Cannot open popups or new windows.
   * Cannot execute top-level frame navigation.

2. **Combining `allow-scripts` and `allow-same-origin` Vulnerability**:  
   If an iframe is hosted on the **same origin** as the parent application and contains both `allow-scripts` and `allow-same-origin`, the embedded script can programmatically execute JavaScript to remove the `sandbox` attribute from its own container frame element (`window.parent.document.querySelector('iframe').removeAttribute('sandbox')`) and reload itself, effectively breaking out of all sandboxing constraints.

3. **`X-Frame-Options` vs CSP `frame-ancestors`**:  
   * `X-Frame-Options` is a legacy HTTP header that supports only basic directives (`DENY`, `SAMEORIGIN`). It cannot evaluate complex origin policies or multiple allowed domain lists.
   * `Content-Security-Policy: frame-ancestors` is the modern standard. It allows granular whitelist definitions (e.g., `frame-ancestors 'self' https://app.example.com https://*.partner.com`), supports worker contexts, and takes precedence over `X-Frame-Options` in modern browsers.

---

#### Exercise 5 Answers

1. **`async` Execution Ordering**:  
   **Script B** will execute first. `async` scripts are fetched completely in the background without blocking parsing, and execute immediately upon arrival. Because Script B (10KB) finishes downloading much faster over the network than Script A (500KB), Script B runs first. `async` offers **no guarantee of execution order**.

2. **`crossorigin` on Font Preloading**:  
   Web fonts are required by the CSS specification to be fetched using **CORS Anonymous Mode**, even when served from the exact same origin host as the HTML document. If `<link rel="preload" as="font">` omits the `crossorigin` attribute, the browser fetches the font twice: once for the generic non-CORS preload request, and a second time when the CSS engine triggers the mandatory CORS font request.

3. **`preconnect` vs `dns-prefetch`**:  
   * `preconnect` performs DNS resolution + TCP 3-way handshake + TLS negotiation. It carries higher CPU/network socket overhead and should be reserved for 1–3 critical origins immediately required by the rendering pipeline.
   * `dns-prefetch` performs **only** the initial DNS lookup (IP address resolution). It consumes minimal resources. `dns-prefetch` should be used as a fallback for legacy browsers that lack `preconnect` support, or for domain origins that will be contacted later during user interaction.

</details>