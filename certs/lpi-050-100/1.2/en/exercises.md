# LPI Open Source Essentials (050-100) — Topic 1.2: Software Architecture

## Official Reference Sources
- [LPI Open Source Essentials Overview & Objectives](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## Architectural Deep Dive & Mechanical Context

Modern software engineering relies on well-defined architectural patterns to determine how computation, state management, networking, and data processing are distributed across nodes.

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

### Key Architectural Paradigms & Trade-offs

1. **Client-Server Model**: Separates the user presentation layer (Client) from data storage and core business computation (Server).
2. **Thin Clients vs. Thick (Fat) Clients**:
   - *Thin Client*: Performs minimal local execution; relies almost entirely on the remote server for processing and business logic (e.g., standard web browser rendering static HTML or terminal via SSH). *Trade-off*: Low client resource utilization, but high network dependency and bandwidth sensitivity.
   - *Thick/Fat Client*: Executes significant logic, data processing, and validation locally before interacting with remote storage or APIs (e.g., IDEs, desktop applications, heavy CLI tools). *Trade-off*: Works offline or with degraded network connectivity, but consumes high local compute/memory resources and introduces client update synchronization challenges.
3. **Multi-Page Applications (MPAs) vs. Single-Page Applications (SPAs)**:
   - *MPA*: Every navigation trigger prompts the server to render and return a full HTML page. *Trade-off*: Simple state management and strong initial SEO, but higher server render overhead and page refresh latency.
   - *SPA*: Loads a single HTML skeleton and a JavaScript bundle once. Subsequent UI mutations and updates occur dynamically by fetching raw data payload (JSON) via asynchronous client-side API requests (AJAX/Fetch). *Trade-off*: High initial load time, but fluid user experience, lower bandwidth consumption, and decoupled backend APIs.
4. **Application Programming Interfaces (APIs)**: Standardized contracts (e.g., REST over HTTP/JSON, gRPC over HTTP/2) permitting decoupled systems to communicate.

---

## Hands-On Guided Exercises

### Exercise 1: Analyzing Client-Server Architecture & Thin vs. Thick Client Processing

In this exercise, you will deploy a lightweight backend API and simulate both a **Thin Client** pattern (server-side rendering and response calculation) and a **Thick/Fat Client** pattern (local processing of raw datasets fetched via API).

#### Step 1.1: Deploy the Backend API Server
Create a file named `server.py` containing a production-grade Python standard library HTTP server:

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

Run the server in the background:
```bash
python3 server.py &
```
*Expected Output:*
```text
[+] Server active on http://127.0.0.1:8080
```

#### Step 1.2: Execute Thin Client Request
Simulate a thin client fetching a fully rendered presentation layer from the server:
```bash
curl -i -X GET http://127.0.0.1:8080/thin-client-render
```
*Expected Output:*
```text
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
Content-Type: text/html

<html><body><h1>System Alerts</h1><p>Critical Nodes: WEB-NODE-01, API-NODE-01</p></body></html>
```

#### Step 1.3: Execute Thick (Fat) Client Processing
Execute a command where the client fetches raw structured JSON from the API and executes filtering, sorting, and transformation locally using `jq`:

```bash
curl -s http://127.0.0.1:8080/api/v1/metrics | jq '.[] | select(.cpu_usage > 85.0) | {node: .name, load: .cpu_usage}'
```
*Expected Output:*
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

#### Verification Questions — Exercise 1
1. In Step 1.2, which component performed the filtering logic for `cpu_usage > 85.0`?
2. In Step 1.3, if 10,000 users run the `jq` filter concurrently on their local workstations, how does the CPU consumption on the API server compare to Step 1.2?
3. Name one key operational security advantage a Thin Client model holds over a Thick Client model when handling sensitive enterprise business logic.

---

### Exercise 2: Single-Page Application (SPA) vs. Multi-Page Application (MPA) Web Delivery

In this exercise, you will construct a production NGINX virtual host manifest configured to host a **Single-Page Application (SPA)** with URI fallback routing, compare it to MPA routing, and verify the HTTP delivery characteristics.

#### Step 2.1: Inspect the SPA Index Manifest
Create directory `/tmp/spa-root` and an `index.html` file representing a client-side SPA shell:

```bash
mkdir -p /tmp/spa-root
```

Create `/tmp/spa-root/index.html`:
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

#### Step 2.2: Configure NGINX Reverse Proxy for SPA Fallback Routing
Create `/tmp/nginx-spa.conf` with complete, syntactically valid NGINX syntax to enforce client-side route fallback via `try_files`:

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

Start NGINX using this configuration:
```bash
nginx -c /tmp/nginx-spa.conf
```

#### Step 2.3: Verify SPA URI Fallback Mechanics
Execute HTTP requests against non-existent static paths `/dashboard` and `/settings`:

```bash
curl -i http://127.0.0.1:8090/dashboard
```
*Expected Output:*
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

Notice that `/dashboard` returns `HTTP 200 OK` with the contents of `index.html` rather than an HTTP 404 error.

#### Verification Questions — Exercise 2
1. Why does NGINX require the directive `try_files $uri $uri/ /index.html;` when serving Single-Page Applications (SPAs)? What would happen if a user refreshed the browser while navigating to `/dashboard` without this directive?
2. In a Multi-Page Application (MPA), what handles route transitions such as clicking a link to `/settings`?
3. Describe the impact of SPAs on initial load latency versus subsequent page view latency.

---

### Exercise 3: API Architecture, REST Constraints, and OpenAPI Contract Enforcement

In this exercise, you will interact with a RESTful API service, validate HTTP verbs, inspect payload formats, and analyze API schema specifications.

#### Step 3.1: Interact with RESTful Endpoints via HTTP CLI
Use `curl` to perform CRUD operational calls against an API service and observe header mechanics and status codes.

1. Fetch resource collection:
```bash
curl -i -H "Accept: application/json" http://127.0.0.1:8080/api/v1/metrics
```
*Expected Output:*
```text
HTTP/1.0 200 OK
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
Content-Type: application/json

[{"id": 1, "name": "web-node-01", "cpu_usage": 88.5, "status": "WARN"}, ...]
```

2. Request an invalid API path to observe HTTP protocol error handling:
```bash
curl -i http://127.0.0.1:8080/api/v1/undefined-resource
```
*Expected Output:*
```text
HTTP/1.0 404 Not Found
Server: BaseHTTP/0.6 Python/3.x
Date: Thu, 06 Aug 2026 19:00:00 GMT
...
```

#### Step 3.2: Analyze an OpenAPI 3.0 (Swagger) Schema Manifest
Examine the production OpenAPI specification below (`openapi.json`), which formalizes the API contract between clients and backend microservices:

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

#### Verification Questions — Exercise 3
1. What property of RESTful architecture ensures that client state is not stored on the server between requests?
2. How do OpenAPI specifications assist modern software development teams in decoupling client (frontend) and server (backend) engineering?
3. Which standard HTTP status code range represents Client Errors (e.g., invalid payload schema sent by a thick client)?

---

### Exercise 4: Production Architectural Diagnostics & Network Socket Inspection

In this exercise, you will use standard Linux diagnostics utilities (`ss`, `lsof`, `tcpdump`) to trace client-server communication channels and socket bindings.

#### Step 4.1: Inspect Active Network Socket Listening State
Execute `ss` (Socket Statistics) to identify listening TCP sockets, process names, and network bindings across the host:

```bash
ss -tulpn | grep -E '8080|8090'
```
*Expected Output:*
```text
tcp   LISTEN 0      128        127.0.0.1:8080      0.0.0.0:*    users:(("python3",pid=12345,fd=3))
tcp   LISTEN 0      511        0.0.0.0:8090        0.0.0.0:*    users:(("nginx",pid=67890,fd=6))
```

#### Step 4.2: Map File Descriptors and Network Connections using lsof
Trace open socket file descriptors associated with the NGINX master/worker processes:

```bash
lsof -iTCP:8090 -sTCP:LISTEN
```
*Expected Output:*
```text
COMMAND   PID  USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx   67890  root    6u  IPv4  45920      0t0  TCP *:8090 (LISTEN)
```

#### Step 4.3: Capture Client-Server Packet Headers via tcpdump
Capture TCP traffic on the loopback interface (`lo`) for port 8080 while generating a client request:

1. In Terminal 1, execute `tcpdump`:
```bash
sudo tcpdump -i lo -nn -A port 8080
```

2. In Terminal 2, send an HTTP request:
```bash
curl http://127.0.0.1:8080/api/v1/metrics
```

*Expected Output in Terminal 1:*
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

#### Step 4.4: Clean Up Background Processes
Terminate the background Python server and NGINX instance created during the exercises:

```bash
kill $(pgrep -f "python3 server.py")
nginx -s stop -c /tmp/nginx-spa.conf
```

#### Verification Questions — Exercise 4
1. What does socket state `LISTEN` signify in a client-server architecture?
2. In the `ss -tulpn` output, what is the architectural implication of binding a server to `127.0.0.1:8080` versus `0.0.0.0:8080`?
3. Which OSI layer is being analyzed when using `tcpdump` to view HTTP request headers (`GET /api/v1/metrics`) versus raw TCP flags (`Flags [P.]`)?

---

## Solutions & Answer Key

<details>
<summary>Click here to expand the Answers and Verification Explanations</summary>

### Exercise 1 Solutions
1. **Server Component**: The Python HTTP server running `server.py` performed the filtering logic (`if n["cpu_usage"] > 85.0`) inside the `/thin-client-render` handler and returned pre-rendered HTML.
2. **CPU Consumption Comparison**: In Step 1.3 (Thick/Fat Client), the server only serializes and streams raw JSON data. The CPU work of filtering and parsing (`jq`) is distributed across the 10,000 client workstations. Consequently, server CPU consumption in Step 1.3 is significantly lower than in Step 1.2 under high concurrent client load.
3. **Operational Security Advantage**: In a Thin Client model, intellectual property, proprietary business formulas, and backend system schemas remain protected within the secure server environment and are never exposed to client-side reverse engineering or tampering.

### Exercise 2 Solutions
1. **SPA Routing Mechanics**: In SPAs, routing between pages (e.g., `/dashboard`, `/settings`) is handled client-side by JavaScript using browser history APIs (`pushState`/`popstate`). When a user manually accesses or refreshes `http://127.0.0.1:8090/dashboard`, the web server looks for a physical file named `/tmp/spa-root/dashboard`. Because that file does not exist, NGINX would return a `404 Not Found` error without `try_files $uri $uri/ /index.html;`. The `try_files` directive forces NGINX to return `index.html`, enabling the client-side JavaScript router to parse the path and render the correct view.
2. **MPA Route Transition**: In an MPA, the web browser sends a new HTTP `GET` request to the server for every link clicked. The server processes the request, renders a complete new HTML document, and returns it to the browser.
3. **Latency Impact**: SPAs exhibit higher initial load latency because the entire JavaScript bundle and CSS must be downloaded first. However, subsequent route changes display near-zero network page refresh latency because only raw JSON data payloads are fetched asynchronously over the wire.

### Exercise 3 Solutions
1. **Statelessness (Stateless Constraint)**: RESTful architecture dictates that each request from a client to a server must contain all the information necessary to understand and complete the request. The server does not store client session context in memory between requests.
2. **Decoupling via API Contracts**: OpenAPI schemas provide a clear, machine-readable interface definition. Frontend developers can mock API responses based on the schema, and backend developers can implement business logic to match the schema independently. Automated validation tools can also verify requests and responses against the contract.
3. **HTTP 4xx Status Codes**: 4xx HTTP status codes (e.g., `400 Bad Request`, `401 Unauthorized`, `404 Not Found`) indicate client-side errors, such as malformed request syntax or invalid path targets.

### Exercise 4 Solutions
1. **Socket `LISTEN` State**: `LISTEN` indicates that a server process has opened a network socket, bound it to an IP address and port number, and is actively waiting for incoming client TCP connection requests (SYN packets).
2. **Binding IP Implications**:
   - `127.0.0.1:8080`: Binds exclusively to the local loopback network interface. The service is only accessible to processes running on the same local host (isolated from external networks).
   - `0.0.0.0:8080`: Binds to all available IPv4 network interfaces on the system. The service is accessible to external network clients (subject to firewall rules).
3. **OSI Model Layers**: Viewing HTTP request headers (`GET /api/v1/metrics`) operates at **Layer 7 (Application Layer)**, whereas inspecting TCP connection flags (`Flags [P.]`, sequence numbers, window size) operates at **Layer 4 (Transport Layer)**.

</details>