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

Hypertext Transfer Protocol (HTTP) is an application-layer protocol situated at Layer 7 of the OSI model. It relies on a request-response messaging pattern over a reliable transport-layer stream (typically TCP at Layer 4, port 80 for plaintext HTTP or port 443 for HTTPS).

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
HTTP/1.1 relies on ASCII text-based framing structured with explicit carriage return (`\r`, ASCII 13) and linefeed (`\n`, ASCII 10) sequences (`CRLF`).

* **HTTP Request Frame Structure:**
  1. **Request-Line:** `METHOD` + `SP` + `Request-URI` + `SP` + `HTTP-Version` + `CRLF` (e.g., `GET /api/v1/health HTTP/1.1\r\n`)
  2. **Header Fields:** `Field-Name` + `:` + `SP` + `Field-Value` + `CRLF`
  3. **Empty Line:** `CRLF` (Signals end of headers)
  4. **Message Body (Optional):** Raw octets whose length is defined by `Content-Length` or `Transfer-Encoding: chunked`.

* **HTTP Response Frame Structure:**
  1. **Status-Line:** `HTTP-Version` + `SP` + `Status-Code` + `SP` + `Reason-Phrase` + `CRLF` (e.g., `HTTP/1.1 200 OK\r\n`)
  2. **Header Fields:** `Field-Name` + `:` + `SP` + `Field-Value` + `CRLF`
  3. **Empty Line:** `CRLF`
  4. **Message Body (Optional):** Payload data.

### 2.2 Method Semantics: Safety and Idempotency
Understanding method properties is vital for API architecture, caching strategy, and retry logic in distributed systems:

* **Safe Methods:** Methods that do not modify server state (read-only).  
  * *Examples:* `GET`, `HEAD`, `OPTIONS`.
* **Idempotent Methods:** Methods where multiple identical requests produce the same side-effects on the server state as a single request.  
  * *Examples:* `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`, `TRACE`.
* **Non-Idempotent / Unsafe Methods:** Operations where repeating requests causes cumulative side-effects.  
  * *Examples:* `POST`, `PATCH`.

| Method | Safe | Idempotent | Request Body Allowed | Primary Production Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `GET` | **Yes** | **Yes** | No (Ignored) | Retrieve resource representation |
| `HEAD` | **Yes** | **Yes** | No | Retrieve headers only (health checks / cache validation) |
| `POST` | **No** | **No** | **Yes** | Create sub-resource / process data |
| `PUT` | **No** | **Yes** | **Yes** | Replace resource entirely (or create at explicit URI) |
| `PATCH` | **No** | **No** | **Yes** | Apply partial modifications to a resource |
| `DELETE` | **No** | **Yes** | Optional | Remove target resource |
| `OPTIONS`| **Yes** | **Yes** | Optional | Query server capability / CORS preflight |

### 2.3 HTTP Status Code Classification (RFC 9110)
Status codes are 3-digit integers categorized into five ranges:

1. **`1xx` Informational:** Request received, continuing process. (e.g., `100 Continue`, `101 Switching Protocols`).
2. **`2xx` Successful:** Action successfully received, understood, and accepted.
   * `200 OK`: Standard success response.
   * `201 Created`: Resource successfully created (must return a `Location` header).
   * `204 No Content`: Action executed successfully; response body is explicitly empty.
3. **`3xx` Redirection:** Further action must be taken by client.
   * `301 Moved Permanently`: Permanent redirect; search engines and clients cache this location long-term.
   * `302 Found`: Temporary redirect (legacy behaviour).
   * `304 Not Modified`: Conditional GET request header (`If-None-Match`/`If-Modified-Since`) validated match; body is empty to save bandwidth.
   * `307 Temporary Redirect` / `308 Permanent Redirect`: Modern redirects preserving original HTTP method and body.
4. **`4xx` Client Error:** Request contains bad syntax or cannot be fulfilled.
   * `400 Bad Request`: Malformed syntax or invalid payload validation.
   * `401 Unauthorized`: Authentication credential missing or invalid (requires `WWW-Authenticate`).
   * `403 Forbidden`: Authentication succeeded, but authorization/RBAC permission is denied.
   * `404 Not Found`: Target resource URI does not exist.
   * `405 Method Not Allowed`: HTTP method not supported for target resource (requires `Allow` header).
   * `429 Too Many Requests`: Rate-limiting threshold breached.
5. **`5xx` Server Error:** Server failed to fulfill an apparently valid request.
   * `500 Internal Server Error`: Unhandled application exception.
   * `502 Bad Gateway`: Upstream server returned invalid payload to ingress controller/proxy.
   * `503 Service Unavailable`: Server down for maintenance or capacity overload (often combined with `Retry-After`).
   * `504 Gateway Timeout`: Proxy connection/read timeout while waiting for upstream response.

---

## 3. Hands-On Guided Lab Exercises

### Exercise 1: Crafting Raw HTTP/1.1 Request/Response Frames via Netcat (`nc`)

#### Task Goal
Manually construct a syntactically valid HTTP/1.1 socket payload using `netcat` to observe CRLF line termination, mandatory `Host` headers, and HTTP keep-alive connection behavior.

#### Step-by-Step Instructions

1. Open your terminal and start a raw TCP connection to an HTTP server using `nc` (or `ncat`):
```bash
nc -C httpbin.org 80
```
*(Note: `-C` ensures `CRLF` (`\r\n`) is transmitted on line breaks).*

2. Manually type the raw HTTP request line and headers. Press `Enter` twice after the last header to send the empty line `\r\n`:
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

**Question 1.1:** What happens if you omit the `Host: httpbin.org` header in a raw HTTP/1.1 request when communicating with a modern virtual-hosting proxy or web server?  
**Question 1.2:** Why is the trailing empty line (`\r\n\r\n`) strictly required by RFC 9112 after the request headers?

---

### Exercise 2: Inspecting Method Semantics, Idempotency, and Headers via `curl`

#### Task Goal
Use `curl` in verbose mode (`-v`) to observe request lines, status codes (`201 Created`, `405 Method Not Allowed`), response headers, and payload boundaries across different HTTP methods.

#### Step-by-Step Instructions

1. **Execute a conditional `GET` request** to inspect cache control mechanics (`304 Not Modified` vs `200 OK`):
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

2. **Send a `POST` request with JSON data** to observe `Content-Type` header semantics and a `200 OK` / `201 Created` status code:
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

3. **Issue an unsupported method request** to trigger an HTTP `405 Method Not Allowed` response:
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

**Question 2.1:** What header must a server return alongside a `405 Method Not Allowed` response code according to RFC 9110, and why is this critical for client auto-discovery?  
**Question 2.2:** An API client attempts to perform network retries after receiving network timeouts. Why can the client safely retry a failed `PUT` request automatically, but MUST NOT automatically retry a failed `POST` request without explicit client transaction framing?

---

### Exercise 3: State Management & Session Lifecycle Mechanics (Cookies vs. Tokens)

#### Task Goal
Analyze stateless HTTP protocol extension mechanisms: traditional server-side state using `Set-Cookie` directives (with `HttpOnly`, `Secure`, and `SameSite` flags) vs. stateless authorization headers using JSON Web Tokens (JWT).

#### Step-by-Step Instructions

1. **Simulate a server setting a secure session cookie:**
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

2. **Simulate token-based stateless authentication** using an `Authorization` header:
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

**Question 3.1:** What security vulnerabilities do the `HttpOnly`, `Secure`, and `SameSite=Strict` attributes mitigate when set on a `Set-Cookie` response header?  
**Question 3.2:** How does state management differ architecturally between session-based cookies stored in memory/Redis on the backend vs stateless Bearer Tokens in the `Authorization` header?

---

### Exercise 4: TLS Handshake, SNI, and HTTPS Traffic Diagnostics with OpenSSL

#### Task Goal
Decouple Layer 4 TCP connection establishment from Layer 6 TLS 1.3 cryptographic handshakes. Inspect Server Name Indication (SNI) negotiation and TLS certificate chains using `openssl s_client`.

#### Step-by-Step Instructions

1. Execute an OpenSSL diagnostic connection to an HTTPS endpoint to observe the TLS handshake:
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

2. Once connected, write a raw HTTP/1.1 GET request over the encrypted socket:
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

**Question 4.1:** What role does Server Name Indication (SNI) play during the TLS handshake prior to sending the HTTP `Host` header?  
**Question 4.2:** Why is HTTP traffic inspection via network packet sniffers (`tcpdump`/`wireshark`) unreadable on port 443 without access to session keys or private keys?

---

### Exercise 5: Reverse Proxy Header Propagation & Diagnostic Packet Capture

#### Task Goal
Examine how reverse proxies (e.g., NGINX, HAProxy, Ingress Controllers) alter HTTP headers during traffic forwarding, and capture raw HTTP packets using `tshark` or `tcpdump`.

#### Production Manifest: NGINX Reverse Proxy Configuration
Below is a syntactically valid production NGINX reverse proxy configuration block designed to forward client client IP addresses and protocol metadata to upstream application clusters.

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

1. Start `tshark` on your local network interface to capture plaintext HTTP headers:
```bash
sudo tshark -i any -n -Y "http.request or http.response" -T fields \
  -e frame.time_relative -e ip.src -e ip.dst -e http.request.method \
  -e http.request.uri -e http.response.code
```

2. Generate traffic in a secondary terminal:
```bash
curl -s http://httpbin.org/get > /dev/null
```

#### Expected CLI Output
```text
0.000000000 192.168.1.100 -> 34.233.208.115 GET /get 
0.142312984 34.233.208.115 -> 192.168.1.100   200
```

#### Step Verification Questions

**Question 5.1:** Why must an upstream web application trust the `X-Forwarded-For` header ONLY if it comes from a verified internal reverse proxy IP address?  
**Question 5.2:** What SRE operational issue arises if `proxy_http_version 1.1` and `proxy_set_header Connection ""` are omitted when proxying requests to an upstream microservice cluster?

---

## 4. Solutions & Technical Explanations

<details>
<summary><strong>Click to expand Solution Key & Comprehensive Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:**  
  According to **RFC 9112 Section 3.2**, HTTP/1.1 requires the `Host` header field in all requests. If the `Host` header is missing or empty, modern web servers and reverse proxies (e.g., NGINX, Apache, Cloudflare) MUST reject the request with an **`HTTP/1.1 400 Bad Request`** status code. The `Host` header allows a single web server sharing a single IP address to host hundreds of distinct domains (Virtual Hosting).

* **Answer 1.2:**  
  The HTTP framing specification uses `CRLFCRLF` (`\r\n\r\n`) as a boundary delimiter. The first `\r\n` ends the last HTTP header line. The second `\r\n` produces an empty line, which unambiguously instructs the HTTP parser that the header section is complete and that any subsequent octets represent the message body (if dictated by `Content-Length` or `Transfer-Encoding`).

---

### Exercise 2 Solutions

* **Answer 2.1:**  
  According to **RFC 9110 Section 15.5.6**, when a server returns `405 Method Not Allowed`, it **MUST generate an `Allow` header field** in the response. The `Allow` header lists the set of HTTP methods currently supported by the target resource (e.g., `Allow: GET, POST, HEAD`). This allows clients and automated web crawlers to dynamically discover supported capabilities without guessing.

* **Answer 2.2:**  
  `PUT` is an **idempotent** method. Replacing a resource at `/api/v1/users/123` ten times with the identical payload yields the exact same server state as executing it once. Thus, automated SRE retry logic can re-issue failed `PUT` requests upon encountering TCP network disconnects.  
  `POST`, however, is **non-idempotent**. Retrying a `POST /api/v1/charges` request after a client timeout risks creating duplicate operations on the backend (e.g., charging a customer credit card twice). Automatic retries of non-idempotent requests require an **Idempotency-Key** header pattern at the application level.

---

### Exercise 3 Solutions

* **Answer 3.1:**  
  * `HttpOnly`: Prevents client-side scripts (e.g., JavaScript `document.cookie`) from accessing the cookie, mitigating **Cross-Site Scripting (XSS)** session hijacking.
  * `Secure`: Instructs the browser to transmit the cookie over encrypted **HTTPS connections only**, preventing plaintext leakage over insecure networks (Wi-Fi eavesdropping).
  * `SameSite=Strict`: Restricts the browser from sending the cookie with cross-site requests, mitigating **Cross-Site Request Forgery (CSRF)** attacks.

* **Answer 3.2:**  
  * **Session-Based Cookies (Stateful):** The client stores a session identifier in a cookie. The actual state (user profile, permissions, session data) is held in server memory or a centralized database (e.g., Redis). Invalidation is instantaneous (delete key from Redis), but requires backend lookup overhead on every HTTP request.
  * **Bearer Tokens / JWTs (Stateless):** The client transmits a cryptographically signed token (containing identity claims) in the `Authorization: Bearer <token>` header. The backend verifies the cryptographic signature without querying a database. This scales horizontally across microservices, but immediate revocation before token expiration is difficult without maintaining a token blacklist.

---

### Exercise 4 Solutions

* **Answer 4.1:**  
  Server Name Indication (**SNI**) is an extension to the TLS protocol (Layer 6) sent inside the initial plaintext `ClientHello` message. Because TLS negotiation occurs *before* the encrypted HTTP session begins (and therefore *before* the HTTP `Host` header can be sent), SNI informs the TLS server which domain certificate to present to the client. Without SNI, servers hosting multiple TLS certificates on a single IP address would be unable to choose the correct certificate during the TLS handshake.

* **Answer 4.2:**  
  TLS 1.3 encrypts all Layer 7 Application Data (including HTTP methods, headers, URIs, cookies, and bodies) using symmetric encryption keys established during the TLS key exchange (e.g., Elliptic-curve Diffie-Hellman). Packet sniffers like `tcpdump` can only inspect TCP payload bytes, which appear as unreadable ciphertext without the session keys.

---

### Exercise 5 Solutions

* **Answer 5.1:**  
  HTTP headers can be easily spoofed by external malicious actors. If an attacker sends a request directly to an ingress node containing a fake header such as `X-Forwarded-For: 8.8.8.8`, an untrusting backend application might treat `8.8.8.8` as the legitimate origin IP address, bypassing IP-based rate limiting or authentication filters. Upstream applications must strip or overwrite `X-Forwarded-For` unless the request originates from a trusted internal proxy IP address.

* **Answer 5.2:**  
  By default, proxy engines (like NGINX) use HTTP/1.0 for upstream requests and send `Connection: close`. This causes the proxy to open and close a new TCP connection to the upstream application service for every single incoming request. Under heavy load, this leads to **TCP port exhaustion (TIME_WAIT bucket overflow)**, excessive CPU consumption from TCP handshakes, latency degradation, and potential `502 Bad Gateway` errors. Using `proxy_http_version 1.1` and clearing the `Connection` header enables persistent TCP connection pooling (`keepalive`).

</details>