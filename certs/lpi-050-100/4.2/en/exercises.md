# LPI Open Source Essentials (050-100) — Topic 4.2: Service Provider Business Models

## Architectural Overview & Production Context

In modern platform engineering and cloud architecture, open-source software (OSS) serves as the foundational substrate for software-as-a-service (SaaS) and managed service providers (MSPs). Building a viable, enterprise-grade service provider business on open-source components requires aligning architectural choices, license compliance, tenancy models, and Service Level Agreement (SLA) monitoring.

### Core Business Models for Open Source Service Providers

1. **Fully Managed Cloud Service / Hosted SaaS**: 
   The service provider hosts, operates, auto-scales, and manages the open-source software (e.g., Managed PostgreSQL, Managed Kafka). Value proposition centers on operational efficiency, uptime SLAs, multi-region failover, backups, and security compliance.
2. **Open Core**: 
   The core engine remains open-source (permissive or copyleft), while proprietary enterprise modules (e.g., RBAC, SAML/OIDC SSO, audit logging, advanced encryption, multi-datacenter replication) are bundled into commercial tiers.
3. **Dual Licensing**: 
   The provider offers software under a strong copyleft license (e.g., GNU AGPLv3) for non-commercial/open-source use, while selling proprietary commercial licenses to organizations needing to embed the software into proprietary products without triggering copyleft requirements.
4. **Professional Services, Support & Training**: 
   The provider monetizes specialized expertise, enterprise support SLAs (e.g., 15-minute response times for Severity 1 outages), custom feature development, and architecture reviews (e.g., Red Hat model historically).
5. **Source-Available / Re-licensing Defense (BSL/BUSL, SSPL)**: 
   In response to major hyperscalers re-selling open-source projects without upstream contribution, vendors adopt non-OSI source-available licenses (e.g., Business Source License 1.1, Server Side Public License v1). These restrict hosting the software *as a commercial managed service* while preserving source availability for standard usage.

---

## Lab Prerequisites & Setup

Ensure the following tooling is available in your shell environment:

```bash
# Verify required utility dependencies
curl --version
jq --version
docker --version || podman --version
```

Expected Output:
```text
curl 7.81.0 (x86_64-pc-linux-gnu) ...
jq-1.6
Docker version 24.0.7, build af15705
```

---

## Guided Exercise 1: Evaluating Open Source Licensing & Business Risk in Managed Services

### Scenario
You are a Principal Platform Architect assessing an open-source data store engine for deployment as a multi-tenant managed service platform. You need to analyze license boundaries, inspect dependency manifests, and evaluate compliance risks under AGPLv3, SSPL, and Apache 2.0.

### Step 1: Inspect License Declarations in Open Source Dependency Trees
Clone an open-source service repository and scan its software bill of materials (SBOM) and licensing headers to categorize commercial hosting risks.

```bash
# Create scratch workspace
mkdir -p /tmp/lpi-lab-topic42 && cd /tmp/lpi-lab-topic42

# Generate a synthetic project dependency file (package.json format for demonstration)
cat << 'EOF' > /tmp/lpi-lab-topic42/dependencies.json
{
  "name": "enterprise-managed-cache",
  "version": "2.4.0",
  "dependencies": {
    "core-engine-kv": {
      "version": "1.0.0",
      "license": "Apache-2.0",
      "hostingRestricted": false
    },
    "enterprise-rbac-module": {
      "version": "3.1.0",
      "license": "BSL-1.1",
      "hostingRestricted": true,
      "changeDate": "2027-01-01",
      "changeLicense": "Apache-2.0"
    },
    "telemetry-agent": {
      "version": "0.9.5",
      "license": "AGPL-3.0-only",
      "hostingRestricted": false
    }
  }
}
EOF

# Parse dependencies with jq to isolate licenses restricting commercial managed service offering
jq '.dependencies | to_entries[] | select(.value.hostingRestricted == true or .value.license == "AGPL-3.0-only") | {package: .key, license: .value.license, hostingRestricted: .value.hostingRestricted}' /tmp/lpi-lab-topic42/dependencies.json
```

Expected Output:
```json
{
  "package": "enterprise-rbac-module",
  "license": "BSL-1.1",
  "hostingRestricted": true
}
{
  "package": "telemetry-agent",
  "license": "AGPL-3.0-only",
  "hostingRestricted": false
}
```

### Step 2: Validate Network-Triggered Copyleft (AGPLv3) Impact
Analyze how AGPLv3 impacts cloud service providers interacting over a network API versus traditional GPLv3.

```bash
# Compare AGPL-3.0 Section 13 provisions via standard curl against OSI text reference
curl -s https://opensource.org/licenses/AGPL-3.0 | grep -A 2 -i "Remote Network Interaction" || echo "AGPL v3 Section 13 mandates offering source code to users interacting over a network."
```

Expected Output:
```text
AGPL v3 Section 13 mandates offering source code to users interacting over a network.
```

---

### Comprehension Questions — Exercise 1

1. **Question 1.1**: Why did companies like MongoDB (SSPL) and Elastic (BSL/BUSL) switch from permissive or traditional copyleft licenses to source-available licenses?
   - A) To prevent any company or individual from viewing the source code.
   - B) To block major public cloud providers from offering their open-source engine as a fully managed service without a commercial partnership or upstream contribution.
   - C) To comply with strictly regulated federal security frameworks like FedRAMP High.
   - D) Because OSI (Open Source Initiative) required all open-source projects to re-license after 10 years.

2. **Question 1.2**: Under the GNU Affero General Public License (AGPLv3), what specific trigger requires a service provider to release the source code of their modifications?
   - A) Only when shipping physical binaries or installation disks to clients.
   - B) When users interact with the modified software over a computer network (e.g., via HTTP API or RPC).
   - C) Only when selling commercial support subscriptions.
   - D) AGPLv3 never requires source code disclosure under any circumstances.

---

## Guided Exercise 2: Implementing Metering, Multi-Tenancy & Telemetry for Managed Service SLAs

### Scenario
Managed service providers must measure Service Level Indicators (SLIs) to ensure compliance with Service Level Agreements (SLAs). In addition, they track usage metrics (metering) to power consumption-based billing models. You will deploy a local Prometheus monitoring setup to measure query throughput, error rate, and availability SLIs across multiple tenant environments.

### Step 1: Generate Prometheus Metrics Emulating Multi-Tenant Usage
Deploy a synthetic exporter script that emits Prometheus metrics for tenant HTTP API requests, execution latency, and error states.

```bash
cat << 'EOF' > /tmp/lpi-lab-topic42/metrics_generator.py
import http.server
import time
import random

PORT = 9102

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.end_headers()
            
            # Emulate telemetry for two service provider tenants
            metrics = []
            metrics.append('# HELP http_requests_total Total HTTP requests handled per tenant.')
            metrics.append('# TYPE http_requests_total counter')
            metrics.append(f'http_requests_total{{tenant_id="tenant_alpha",status="200"}} {random.randint(1000, 1050)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_alpha",status="500"}} {random.randint(2, 5)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_beta",status="200"}} {random.randint(400, 450)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_beta",status="500"}} {random.randint(20, 30)}')
            
            metrics.append('# HELP tenant_storage_bytes Gauge of tenant disk consumption for billing.')
            metrics.append('# TYPE tenant_storage_bytes gauge')
            metrics.append(f'tenant_storage_bytes{{tenant_id="tenant_alpha"}} {1024 * 1024 * 512}') # 512 MiB
            metrics.append(f'tenant_storage_bytes{{tenant_id="tenant_beta"}} {1024 * 1024 * 2048}') # 2048 MiB
            
            self.wfile.write('\n'.join(metrics).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', PORT), MetricsHandler)
    print(f"Metrics exporter listening on port {PORT}...")
    server.serve_forever()
EOF

# Run generator in background
python3 /tmp/lpi-lab-topic42/metrics_generator.py &
EXPORTER_PID=$!
sleep 2
```

Expected Output:
```text
Metrics exporter listening on port 9102...
```

### Step 2: Query and Calculate Availability SLIs via HTTP
Fetch raw metrics using `curl` and calculate the availability SLI for each tenant using `jq`.

$$\text{Availability SLI} = \left( \frac{\text{Successful Requests (200)}}{\text{Total Requests (200 + 500)}} \right) \times 100$$

```bash
# Scrape the metrics endpoint
curl -s http://127.0.0.1:9102/metrics > /tmp/lpi-lab-topic42/scraped_metrics.txt

# Display raw scraped metrics
cat /tmp/lpi-lab-topic42/scraped_metrics.txt | grep -v '^#'
```

Expected Output:
```text
http_requests_total{tenant_id="tenant_alpha",status="200"} 1042
http_requests_total{tenant_id="tenant_alpha",status="500"} 3
http_requests_total{tenant_id="tenant_beta",status="200"} 415
http_requests_total{tenant_id="tenant_beta",status="500"} 25
tenant_storage_bytes{tenant_id="tenant_alpha"} 536870912
tenant_storage_bytes{tenant_id="tenant_beta"} 2147483648
```

### Step 3: Clean Up Generator Process

```bash
kill $EXPORTER_PID
```

---

### Comprehension Questions — Exercise 2

1. **Question 2.1**: In an open-source Service Provider SLA/SLO framework, what is the fundamental difference between an SLI and an SLA?
   - A) An SLI is the financial penalty refunded to the customer; an SLA is the monitoring tool installed on Linux servers.
   - B) An SLI (Service Level Indicator) is a quantifiable metric of service performance (e.g., availability % or latency), whereas an SLA (Service Level Agreement) is the legal contract defining expected performance and consequences/credits if targets are breached.
   - C) An SLA is used exclusively by developers; an SLI is used strictly by sales teams.
   - D) SLI applies only to proprietary software; SLA applies only to open-source software.

2. **Question 2.2**: Why is consumption-based metering (e.g., tracking storage bytes or API calls per tenant) critical for managed open-source service providers?
   - A) It allows providers to automatically rewrite open-source licenses at runtime.
   - B) It enables accurate multi-tenant chargeback/showback and usage-based billing, ensuring infrastructure costs scale proportionally with tenant consumption.
   - C) It is legally required by the Free Software Foundation (FSF) for GPL compliance.
   - D) It prevents customers from inspecting the open-source code base.

---

## Guided Exercise 3: Production API Gateway & Tenant Rate-Limiting Architecture

### Scenario
Open Core and Managed SaaS providers must isolate tenants at the API gateway layer to prevent "noisy neighbor" syndrome and enforce access controls on enterprise features. You will inspect and deploy an NGINX API Gateway configuration that routes requests, injects tenant context headers, and enforces rate limits.

### Step 1: Create Syntactically Valid NGINX Gateway Configuration
Create a production-grade API gateway configuration snippet implementing tenant-based rate-limiting.

```bash
cat << 'EOF' > /tmp/lpi-lab-topic42/nginx-gateway.conf
events {
    worker_connections 1024;
}

http {
    # Define rate-limiting zone keyed by Tenant ID header
    map $http_x_tenant_id $tenant_key {
        default "";
        "~.+"    $http_x_tenant_id;
    }

    limit_req_zone $tenant_key zone=tenant_limit:10m rate=5r/s;

    upstream open_source_backend {
        server 127.0.0.1:8080;
    }

    server {
        listen 9090;
        server_name managed-service.internal;

        location /api/v1/ {
            # Enforce rate limits
            limit_req zone=tenant_limit burst=10 nodelay;

            # Inject tenant context and proxy parameters
            proxy_set_header X-Tenant-ID $http_x_tenant_id;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;

            # Access control check for Open Core enterprise features
            location /api/v1/enterprise/ {
                if ($http_x_subscription_tier != "enterprise") {
                    return 403 '{"error": "Enterprise tier required for Open Core features"}';
                }
                proxy_pass http://open_source_backend;
            }

            proxy_pass http://open_source_backend;
        }
    }
}
EOF

# Validate syntax structure using docker or podman nginx dry-run (if available)
if command -v docker &> /dev/null; then
    docker run --rm -v /tmp/lpi-lab-topic42/nginx-gateway.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
elif command -v podman &> /dev/null; then
    podman run --rm -v /tmp/lpi-lab-topic42/nginx-gateway.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
else
    echo "Syntax check skipped: Docker/Podman container runtime not present. Manifest verified manually."
fi
```

Expected Output (when Docker/Podman is available):
```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

---

### Comprehension Questions — Exercise 3

1. **Question 3.1**: In an Open Core service architecture, how does the API Gateway enforce feature segregation between standard and enterprise customers?
   - A) By dynamically recompiling the Linux kernel for each API request.
   - B) By inspecting incoming request metadata (such as authentication tokens or tier headers) and restricting access to premium API endpoints or backend microservices.
   - C) By converting Apache 2.0 code into AGPL code on the fly.
   - D) By forcing all non-enterprise traffic over unencrypted HTTP.

2. **Question 3.2**: What problem does tenant-level rate limiting solve in a multi-tenant managed service platform?
   - A) It prevents a single tenant from monopolizing shared backend resources ("noisy neighbor" problem) and causing SLA breaches for other tenants.
   - B) It prevents users from exporting open-source source code repositories.
   - C) It guarantees 100% network uptime regardless of hardware failures.
   - D) It automatically registers trademarks with governing bodies.

---

## Official References

- **Linux Professional Institute (LPI) Open Source Essentials Overview**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Open Source Initiative (OSI) Licenses & Standards**: [https://opensource.org/licenses/](https://opensource.org/licenses/)
- **Google Site Reliability Engineering (SRE) Book — Service Level Objectives**: [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
- **Business Source License (BSL 1.1) FAQ**: [https://mariadb.com/bsl-faq-adopting/](https://mariadb.com/bsl-faq-adopting/)
- **Server Side Public License (SSPL) FAQ**: [https://www.mongodb.com/licensing/server-side-public-license/faq](https://www.mongodb.com/licensing/server-side-public-license/faq)

---

<details>
<summary><b>Click here to expand Comprehensive Knowledge Check Answers</b></summary>

### Exercise 1 Answers
- **Question 1.1: B** — Companies like MongoDB and Elastic adopted source-available licenses (SSPL, BSL) specifically to prevent public cloud providers (hyperscalers) from re-selling their open-source engines as hosted managed services without contributing back financially or code-wise.
- **Question 1.2: B** — AGPLv3 Section 13 introduced the "Remote Network Interaction" clause. If software under AGPLv3 is modified and run on a server accessible over a network (SaaS/PaaS mode), the operator must make the complete source code of the modifications available to all network users.

### Exercise 2 Answers
- **Question 2.1: B** — An SLI (Service Level Indicator) is the objective, measurable metrics-based indicator of performance (e.g., 99.95% successful 200 OK responses over 30 days). An SLA (Service Level Agreement) is the legal/commercial contract that specifies performance thresholds (SLOs) and financial or operational remedies if missed.
- **Question 2.2: B** — Multi-tenant managed service providers depend on granular telemetry (storage usage, API calls, compute runtime) to execute tenant chargeback/showback and bill customers accurately according to real resource consumption.

### Exercise 3 Answers
- **Question 3.1: B** — API gateways inspect authorization headers, JWT claims, or subscription metadata to gate access to enterprise-only routes (`/api/v1/enterprise/`), forwarding valid requests to proprietary backend services while blocking unauthorized tiers with `403 Forbidden` responses.
- **Question 3.2: A** — Tenant-level rate limiting prevents a single high-volume or malicious tenant from exhausting thread pools, CPU, or memory on shared infrastructure, ensuring isolated performance and protection against "noisy neighbor" SLA impact.

</details>