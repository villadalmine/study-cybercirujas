# 4.3 — The Business Value of APIs

**Certification:** Google Cloud Digital Leader (`gcp-cdl`), exam version 2026-08-12
**Domain 4:** Trust and security / modernization value — objective weight **6.0**
**Audience level:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: the architectural problem an API program actually solves

### 1.1 The N×M integration explosion

Every enterprise that has not treated interfaces as products ends up with the same failure mode. Given `N` producing systems and `M` consuming systems, ad-hoc point-to-point integration converges on `O(N×M)` bespoke connectors. Each connector carries its own auth scheme, its own retry semantics, its own serialization, its own on-call rotation, and its own undocumented coupling to a database schema.

```
        Point-to-point (N=6, M=8)          API-mediated (N=6, M=8)
        48 potential integrations          6 producer contracts + 8 consumer bindings

  ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐    ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
  │ P1│ │ P2│ │ P3│ │ P4│ │ P5│ │ P6│    │ P1│ │ P2│ │ P3│ │ P4│ │ P5│ │ P6│
  └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘    └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘
    ╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳       └─────┴─────┴──┬──┴─────┴─────┘
    ╳╳ every line is a bespoke contract ╳╳          ┌──────┴───────┐
    ╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳       │ API management │  ← one policy plane:
  ┌─┴─┐ ┌─┴─┐ ┌─┴─┐ ┌─┴─┐ ┌─┴─┐ ┌─┴─┐    │  (Apigee /     │    authn, quota, cache,
  │ C1│ │ C2│ │...│ │...│ │...│ │ C8│    │   API Gateway) │    analytics, versioning
  └───┘ └───┘ └───┘ └───┘ └───┘ └───┘    └──────┬───────┘
                                            ┌────┴────┬────┬────┐
                                          ┌─┴─┐ ┌─┴─┐ ...  ┌─┴─┐
                                          │ C1│ │ C2│      │ C8│
                                          └───┘ └───┘      └───┘
```

The business value statement the Cloud Digital Leader exam wants you to be able to make is not "APIs are good engineering." It is this:

> An API converts an internal capability into a **reusable, metered, independently versioned asset** whose consumers can be onboarded without a project, a contract negotiation, or a coordinated release.

The architectural consequence is that integration cost moves from **variable and quadratic** to **fixed and linear**. That is a balance-sheet statement, not an aesthetic one.

### 1.2 The three value pools

| Value pool | Mechanism | Measurable business metric | Typical owner |
|---|---|---|---|
| **Internal efficiency** | Reuse of existing capability instead of rebuild; self-service consumption | Integration lead time (weeks → days); duplicated-system count; internal chargeback per 1k calls | Platform engineering |
| **Ecosystem / partner reach** | Partners build on your capability without you writing their code | Time-to-first-successful-call (TTFSC); number of active partner apps; partner-attributed GMV | Digital / partnerships |
| **Direct monetization** | The API *is* the product; metered billing per call, per tier, or revenue-share | ARPU per developer; revenue per 1k calls; conversion free → paid tier | Product / commercial |

A fourth, frequently under-modelled pool:

| **Modernization optionality** | An API façade in front of a mainframe/monolith lets the backend be replaced without touching consumers (strangler-fig) | % of traffic served by new backend; number of consumers requiring change during cutover (target: **zero**) | Architecture |

### 1.3 The SRE framing: an API is an SLO with a price tag

Once an interface has external consumers who pay — in money or in internal chargeback — the reliability conversation changes shape:

- The **SLI** is defined at the API contract boundary (proxy-observed availability and latency), not at the pod.
- The **error budget** becomes a commercial instrument: it is what you are permitted to spend on change velocity before you owe a service credit.
- **Rate limiting is not only protection, it is packaging.** The same `Quota` policy that prevents a backend meltdown is the mechanism that differentiates the Free tier from the Gold tier. This dual purpose is the single most exam-relevant technical fact in this objective.

---

## 2. The Google Cloud API surface: technical comparison

Google Cloud ships three distinct products in this space, and the CDL exam expects you to place each one correctly.

### 2.1 Product selection matrix

| Dimension | **Apigee (X / hybrid)** | **API Gateway** | **Cloud Endpoints (ESPv2)** |
|---|---|---|---|
| Positioning | Full-lifecycle API **management** platform | Managed gateway for serverless backends | Self-managed proxy (Envoy-based) you deploy next to your service |
| Control plane | Google-managed, multi-tenant management plane; runtime in your project | Fully managed, regional | You run the proxy; Service Management/Service Control are managed |
| Deployment topology | Regional runtime instance(s), exposed via external Application Load Balancer + PSC NEG | Regional managed gateway, `*.gateway.dev` hostname | Sidecar or front proxy on GKE, Cloud Run, GCE, App Engine flex |
| Spec format | OpenAPI 2.0/3.x for design + import; runtime behaviour from proxy bundle policies | **OpenAPI 2.0 only** (Swagger) with `x-google-*` extensions | **OpenAPI 2.0 only**, or gRPC service config + proto descriptor |
| Policy model | ~50 declarative policies (OAuthV2, JWT, SpikeArrest, Quota, ResponseCache, ServiceCallout, message transformation, JS/Java callouts) | Fixed set: API key, JWT auth, per-consumer quota, backend routing | Same fixed set as API Gateway (shared ESPv2 lineage) |
| Mediation / transformation | Yes — REST↔SOAP, payload rewrite, orchestration, conditional routing | No | No (gRPC↔JSON transcoding only) |
| Developer portal | Yes (integrated portal + Drupal-based option) | No | No |
| **Monetization / rate plans** | **Yes** — API products, rate plans, billing docs | No | No |
| Analytics | Deep: per-proxy, per-product, per-developer, per-app, custom dimensions, retention | Cloud Monitoring / Cloud Logging metrics | Cloud Monitoring / Cloud Logging metrics |
| Advanced API Security | Yes (abuse detection, security scores, misconfiguration detection) | No (compose with Cloud Armor) | No (compose with Cloud Armor) |
| Cost profile | Subscription (Standard/Enterprise/Enterprise Plus) or pay-as-you-go by environment type | Per-call, low | Proxy compute + Service Control calls |
| Typical fit | Partner/public API programs, monetized APIs, mainframe façade, org-wide governance | Cloud Run / Cloud Functions APIs needing a key + JWT gate | gRPC services on GKE; you already own the deployment |

**Decision heuristic:**

```
Do you need to charge, package, or govern the API as a product,
or expose it to third parties you do not control?
    YES → Apigee
    NO  → Is the backend serverless (Cloud Run / Functions / App Engine)?
              YES → API Gateway
              NO  → Are you on GKE and/or gRPC, and willing to run the proxy?
                        YES → Cloud Endpoints (ESPv2)
                        NO  → Plain external Application Load Balancer + Cloud Armor
```

### 2.2 Interface style trade-offs

The "business value" argument is style-dependent. Choosing gRPC for a partner-facing public API destroys the ecosystem value pool because your partners' junior developers cannot `curl` it.

| Style | Wire | Discoverability | Partner onboarding cost | Latency / payload | Breaking-change blast radius | Best value pool |
|---|---|---|---|---|---|---|
| **REST/JSON over HTTP/1.1** | Text, cacheable | Highest (OpenAPI, browsable) | Lowest — `curl` works | Highest bytes, ~1 RTT/call | Contained by URI versioning | Ecosystem, monetization |
| **gRPC over HTTP/2** | Protobuf, binary | Low without tooling (needs `.proto` + reflection) | High (codegen toolchain) | ~30–60% smaller payloads, multiplexed streams | Protobuf field-number rules make additive change safe | Internal efficiency |
| **GraphQL** | JSON, single endpoint | Introspective, self-documenting | Medium | Fewer round-trips; N+1 risk on resolvers | Deprecation-per-field, no URI version | Consumer-driven UIs |
| **Async / event (Pub/Sub, Kafka)** | JSON/Avro/Proto | Schema-registry dependent | High (needs consumer infra) | Decoupled, no sync latency budget | Schema evolution rules | Internal decoupling, fan-out |
| **Webhooks (you call them)** | JSON | Low | Medium (partner must host an endpoint) | Push, no polling cost | Retry/idempotency contract is the hard part | Partner integration |

**Production note:** the highest-value production pattern is *not* "pick one." It is **gRPC internally, REST at the edge**, with the boundary translation done once — by ESPv2 transcoding or by an Apigee proxy — so internal efficiency and external reach are both purchased without asking service teams to maintain two hand-written implementations.

### 2.3 Authentication model trade-offs

| Mechanism | Identifies | Revocable | Suitable for | Failure mode you will actually see |
|---|---|---|---|---|
| **API key** | The *app*, not the user | Yes (per key) | Traffic identification, quota attribution, free tiers | Keys in public Git repos; keys in query strings landing in access logs |
| **OAuth 2.0 client credentials** | The *app*, cryptographically | Yes (token TTL + revocation) | Server-to-server partner access | Token caching absent → token endpoint becomes the bottleneck |
| **OAuth 2.0 authorization code + PKCE** | The *end user* | Yes | Third-party apps acting on a user's behalf | Redirect-URI misconfiguration; consent-screen scope creep |
| **JWT (external IdP)** | App or user, offline-verifiable | Only via short TTL / denylist | Zero-trust, high-throughput (no introspection RTT) | Clock skew; `aud` mismatch; JWKS cache not refreshed after key rotation |
| **mTLS** | The client's certificate | Yes (CRL/short-lived certs) | Regulated B2B, PSD2/FAPI | Certificate expiry at 03:00 on a Sunday |
| **Google-signed ID token (IAM)** | A Google service account | Yes | Internal service-to-service on GCP | `roles/run.invoker` missing → 403 that looks like an app bug |

**Layer them.** In production, API key for *attribution and packaging*, OAuth/JWT for *authorization*, mTLS for *channel trust* where regulation demands it. The API key answers "who do I bill?"; the token answers "what may they do?"

### 2.4 Monetization models

| Model | Metering unit | Where enforced | Revenue predictability | Adoption friction |
|---|---|---|---|---|
| **Free / open** | none | Spike arrest only | none (indirect value) | lowest |
| **Freemium** | calls/month, hard cap | `Quota` policy per API product | low | low |
| **Pay-as-you-go** | per call, per MB, per transaction | Quota + analytics-driven billing export | medium (volume-linked) | medium |
| **Tiered (Bronze/Silver/Gold)** | calls/sec + calls/month + SLA | Distinct API products, distinct rate plans | high | medium |
| **Revenue share** | % of transaction value the API enables | Custom attribute captured in analytics | high, aligned | high (needs contract) |
| **Internal chargeback** | calls/month per cost centre | Quota per developer app, exported to billing | n/a — cost transparency | low |

Apigee expresses this natively: **API proxy** (runtime) → **API product** (the packaged, sellable bundle of proxy resources + quota) → **developer** → **developer app** (holds credentials) → **rate plan** (the price). Internalize that chain; it is the mechanical expression of "business value of APIs."

---

## 3. Complete infrastructure and manifests

### 3.1 Apigee X foundation — Terraform

```hcl
# terraform/apigee/main.tf
# Apigee X org + regional runtime instance + environment + env group,
# exposed through a global external Application Load Balancer via a PSC NEG.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region"     { type = string  default = "us-central1" }
variable "hostname"   { type = string  default = "api.example.com" }

locals {
  apigee_services = [
    "apigee.googleapis.com",
    "servicenetworking.googleapis.com",
    "compute.googleapis.com",
    "cloudkms.googleapis.com",
  ]
}

resource "google_project_service" "apigee" {
  for_each           = toset(local.apigee_services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Networking: Apigee runtime is placed in a Google-managed tenant project and
# reached over VPC peering. It requires a /22 for the runtime plus a /28 for
# support/troubleshooting access. These ranges must NOT overlap anything else.
# ---------------------------------------------------------------------------

resource "google_compute_network" "apigee" {
  name                    = "apigee-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apigee]
}

resource "google_compute_global_address" "apigee_range" {
  name          = "apigee-runtime-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 22
  address       = "10.90.0.0"
  network       = google_compute_network.apigee.id
}

resource "google_compute_global_address" "apigee_support_range" {
  name          = "apigee-support-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 28
  address       = "10.91.0.0"
  network       = google_compute_network.apigee.id
}

resource "google_service_networking_connection" "apigee" {
  network = google_compute_network.apigee.id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.apigee_range.name,
    google_compute_global_address.apigee_support_range.name,
  ]
}

# ---------------------------------------------------------------------------
# Customer-managed encryption for the runtime database and disks.
# ---------------------------------------------------------------------------

resource "google_kms_key_ring" "apigee" {
  name     = "apigee-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "apigee_db" {
  name            = "apigee-database-key"
  key_ring        = google_kms_key_ring.apigee.id
  rotation_period = "7776000s" # 90 days
  lifecycle { prevent_destroy = true }
}

# ---------------------------------------------------------------------------
# Apigee organization (1:1 with the GCP project) and runtime.
# ---------------------------------------------------------------------------

resource "google_apigee_organization" "org" {
  project_id                           = var.project_id
  analytics_region                     = var.region
  authorized_network                   = google_compute_network.apigee.id
  runtime_database_encryption_key_name = google_kms_crypto_key.apigee_db.id
  billing_type                         = "PAYG"     # or SUBSCRIPTION
  description                          = "Public and partner API program"
  depends_on = [
    google_service_networking_connection.apigee,
    google_project_service.apigee,
  ]
}

resource "google_apigee_environment" "prod" {
  org_id       = google_apigee_organization.org.id
  name         = "prod"
  display_name = "Production"
  description  = "Externally exposed, monetized traffic"
  type         = "COMPREHENSIVE" # BASE | INTERMEDIATE | COMPREHENSIVE (PAYG)
  deployment_type = "PROXY"
  api_proxy_type  = "PROGRAMMABLE"
}

resource "google_apigee_envgroup" "external" {
  org_id    = google_apigee_organization.org.id
  name      = "external"
  hostnames = [var.hostname]
}

resource "google_apigee_envgroup_attachment" "external_prod" {
  envgroup_id = google_apigee_envgroup.external.id
  environment = google_apigee_environment.prod.name
}

resource "google_apigee_instance" "runtime" {
  name                     = "instance-${var.region}"
  location                 = var.region
  org_id                   = google_apigee_organization.org.id
  disk_encryption_key_name = google_kms_crypto_key.apigee_db.id
}

resource "google_apigee_instance_attachment" "prod" {
  instance_id = google_apigee_instance.runtime.id
  environment = google_apigee_environment.prod.name
}

# ---------------------------------------------------------------------------
# Northbound exposure: PSC NEG -> backend service -> global external ALB.
# ---------------------------------------------------------------------------

resource "google_compute_region_network_endpoint_group" "apigee_psc" {
  name                  = "apigee-psc-neg"
  region                = var.region
  network               = google_compute_network.apigee.id
  network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
  psc_target_service    = google_apigee_instance.runtime.service_attachment
}

resource "google_compute_backend_service" "apigee" {
  name                  = "apigee-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_name             = "https"
  timeout_sec           = 60
  security_policy       = google_compute_security_policy.edge.id

  backend {
    group           = google_compute_region_network_endpoint_group.apigee_psc.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_managed_ssl_certificate" "api" {
  name = "api-cert"
  managed { domains = [var.hostname] }
}

resource "google_compute_url_map" "api" {
  name            = "apigee-urlmap"
  default_service = google_compute_backend_service.apigee.id
}

resource "google_compute_target_https_proxy" "api" {
  name             = "apigee-https-proxy"
  url_map          = google_compute_url_map.api.id
  ssl_certificates = [google_compute_managed_ssl_certificate.api.id]
}

resource "google_compute_global_address" "lb_ip" {
  name = "apigee-lb-ip"
}

resource "google_compute_global_forwarding_rule" "api" {
  name                  = "apigee-https-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.api.id
  ip_address            = google_compute_global_address.lb_ip.id
}

# ---------------------------------------------------------------------------
# Edge protection. Cloud Armor is the volumetric/L7 shield in FRONT of the
# API's own business-tier quotas. The two are complementary, not redundant.
# ---------------------------------------------------------------------------

resource "google_compute_security_policy" "edge" {
  name        = "api-edge-policy"
  description = "Volumetric + OWASP protection ahead of Apigee"

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr { expression = "evaluatePreconfiguredExpr('sqli-v33-stable')" }
    }
    description = "OWASP CRS - SQL injection"
  }

  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 1200
        interval_sec = 60
      }
    }
    description = "Per-IP volumetric ceiling, well above any paid tier"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    description = "Default allow"
  }
}

output "lb_ip"             { value = google_compute_global_address.lb_ip.address }
output "service_attachment"{ value = google_apigee_instance.runtime.service_attachment }
```

### 3.2 The Apigee proxy bundle — where packaging is actually enforced

Bundle layout:

```
apiproxy/
├── payments-v1.xml
├── proxies/
│   └── default.xml
├── targets/
│   └── default.xml
└── policies/
    ├── VAK-VerifyKey.xml
    ├── SA-SpikeArrest.xml
    ├── Q-ProductQuota.xml
    ├── RC-CatalogCache.xml
    ├── AM-RemoveKeyHeader.xml
    ├── AM-QuotaHeaders.xml
    └── RF-QuotaExceeded.xml
```

**`apiproxy/payments-v1.xml`**

```xml
<APIProxy revision="1" name="payments-v1">
  <DisplayName>Payments API v1</DisplayName>
  <Description>Externally monetized payments capability.</Description>
  <ProxyEndpoints>
    <ProxyEndpoint>default</ProxyEndpoint>
  </ProxyEndpoints>
  <TargetEndpoints>
    <TargetEndpoint>default</TargetEndpoint>
  </TargetEndpoints>
</APIProxy>
```

**`apiproxy/proxies/default.xml`** — the policy chain in execution order:

```xml
<ProxyEndpoint name="default">
  <Description>Northbound entry point for /v1/payments</Description>

  <PreFlow name="PreFlow">
    <Request>
      <!-- 1. Backend protection FIRST: a smoothed rate that no single
              client can breach, evaluated before any expensive lookup. -->
      <Step><Name>SA-SpikeArrest</Name></Step>

      <!-- 2. Identify the calling app. This resolves the API product,
              the developer, and the quota attributes attached to them. -->
      <Step><Name>VAK-VerifyKey</Name></Step>

      <!-- 3. Business-tier metering, driven by the product's own settings. -->
      <Step><Name>Q-ProductQuota</Name></Step>

      <!-- 4. Never forward the credential to the backend. -->
      <Step><Name>AM-RemoveKeyHeader</Name></Step>
    </Request>
    <Response>
      <Step><Name>AM-QuotaHeaders</Name></Step>
    </Response>
  </PreFlow>

  <Flows>
    <Flow name="GetPayment">
      <Description>Read a single payment</Description>
      <Condition>(proxy.pathsuffix MatchesPath "/payments/*") and (request.verb = "GET")</Condition>
      <Request>
        <Step><Name>RC-CatalogCache</Name></Step>
      </Request>
      <Response>
        <Step><Name>RC-CatalogCache</Name></Step>
      </Response>
    </Flow>

    <Flow name="CreatePayment">
      <Description>Create a payment</Description>
      <Condition>(proxy.pathsuffix MatchesPath "/payments") and (request.verb = "POST")</Condition>
    </Flow>

    <Flow name="UnknownResource">
      <Description>Explicit 404 rather than a backend passthrough</Description>
      <Request>
        <Step><Name>RF-NotFound</Name></Step>
      </Request>
    </Flow>
  </Flows>

  <FaultRules>
    <FaultRule name="QuotaViolation">
      <Step><Name>RF-QuotaExceeded</Name></Step>
      <Condition>(fault.name = "QuotaViolation")</Condition>
    </FaultRule>
  </FaultRules>

  <HTTPProxyConnection>
    <BasePath>/v1</BasePath>
    <VirtualHost>secure</VirtualHost>
  </HTTPProxyConnection>

  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
```

**`apiproxy/policies/SA-SpikeArrest.xml`**

```xml
<SpikeArrest continueOnError="false" enabled="true" name="SA-SpikeArrest">
  <DisplayName>Spike Arrest - backend protection</DisplayName>
  <!-- 200 per second, smoothed to one request every 5 ms per message
       processor. This is a shock absorber, NOT a business quota. -->
  <Rate>200ps</Rate>
  <UseEffectiveCount>true</UseEffectiveCount>
  <Identifier ref="client.ip"/>
</SpikeArrest>
```

**`apiproxy/policies/VAK-VerifyKey.xml`**

```xml
<VerifyAPIKey continueOnError="false" enabled="true" name="VAK-VerifyKey">
  <DisplayName>Verify API Key</DisplayName>
  <!-- Header, never a query parameter: query strings are written to
       access logs, browser history and referrer headers. -->
  <APIKey ref="request.header.x-api-key"/>
</VerifyAPIKey>
```

**`apiproxy/policies/Q-ProductQuota.xml`** — the monetization enforcement point:

```xml
<Quota continueOnError="false" enabled="true" name="Q-ProductQuota" type="calendar">
  <DisplayName>Product Quota</DisplayName>
  <!-- Every limit is dereferenced from the API PRODUCT the key resolved to.
       Selling a new tier therefore requires zero proxy changes: you create
       a new API product with different quota settings and issue keys against
       it. This indirection is the whole point. -->
  <Identifier ref="verifyapikey.VAK-VerifyKey.client_id"/>
  <Allow countRef="verifyapikey.VAK-VerifyKey.apiproduct.developer.quota.limit"/>
  <Interval ref="verifyapikey.VAK-VerifyKey.apiproduct.developer.quota.interval"/>
  <TimeUnit ref="verifyapikey.VAK-VerifyKey.apiproduct.developer.quota.timeunit"/>
  <StartTime>2026-01-01 00:00:00</StartTime>
  <Distributed>true</Distributed>
  <Synchronous>false</Synchronous>
  <AsynchronousConfiguration>
    <SyncIntervalInSeconds>10</SyncIntervalInSeconds>
    <SyncMessageCount>5</SyncMessageCount>
  </AsynchronousConfiguration>
</Quota>
```

**`apiproxy/policies/AM-QuotaHeaders.xml`** — the developer-experience half of the same feature:

```xml
<AssignMessage continueOnError="false" enabled="true" name="AM-QuotaHeaders">
  <DisplayName>Expose quota state to the caller</DisplayName>
  <Set>
    <Headers>
      <Header name="X-RateLimit-Limit">{ratelimit.Q-ProductQuota.allowed.count}</Header>
      <Header name="X-RateLimit-Remaining">{ratelimit.Q-ProductQuota.available.count}</Header>
      <Header name="X-RateLimit-Reset">{ratelimit.Q-ProductQuota.expiry.time}</Header>
    </Headers>
  </Set>
  <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
  <AssignTo createNew="false" transport="http" type="response"/>
</AssignMessage>
```

**`apiproxy/policies/RF-QuotaExceeded.xml`** — a 429 that a partner can act on:

```xml
<RaiseFault continueOnError="false" enabled="true" name="RF-QuotaExceeded">
  <DisplayName>429 Too Many Requests</DisplayName>
  <FaultResponse>
    <Set>
      <Headers>
        <Header name="Content-Type">application/problem+json</Header>
        <Header name="Retry-After">{ratelimit.Q-ProductQuota.expiry.time}</Header>
      </Headers>
      <Payload contentType="application/problem+json">{
  "type": "https://api.example.com/problems/quota-exceeded",
  "title": "Monthly quota exceeded",
  "status": 429,
  "detail": "Your plan allows {ratelimit.Q-ProductQuota.allowed.count} calls per interval. Upgrade at https://developers.example.com/plans",
  "instance": "{messageid}"
}</Payload>
      <StatusCode>429</StatusCode>
      <ReasonPhrase>Too Many Requests</ReasonPhrase>
    </Set>
  </FaultResponse>
  <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
</RaiseFault>
```

**`apiproxy/targets/default.xml`** — with retry semantics and circuit-breaker-adjacent timeouts:

```xml
<TargetEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <HTTPTargetConnection>
    <URL>https://payments-backend.internal.example.com</URL>
    <Properties>
      <Property name="connect.timeout.millis">2000</Property>
      <Property name="io.timeout.millis">8000</Property>
      <Property name="supports.http10">false</Property>
      <Property name="request.retain.headers.enabled">false</Property>
      <Property name="keepalive.timeout.millis">60000</Property>
      <Property name="success.codes">2xx,3xx</Property>
    </Properties>
    <SSLInfo>
      <Enabled>true</Enabled>
      <ClientAuthEnabled>true</ClientAuthEnabled>
      <KeyStore>ref://payments-mtls-keystore</KeyStore>
      <KeyAlias>payments-client</KeyAlias>
      <TrustStore>payments-truststore</TrustStore>
      <IgnoreValidationErrors>false</IgnoreValidationErrors>
    </SSLInfo>
  </HTTPTargetConnection>
</TargetEndpoint>
```

### 3.3 API Gateway — full OpenAPI 2.0 config

Use this when the backend is Cloud Run and you need a key + JWT gate, not a product catalogue.

```yaml
# openapi/orders-gateway.yaml
# API Gateway requires OpenAPI 2.0 (Swagger). OpenAPI 3.x is NOT accepted.
swagger: "2.0"
info:
  title: orders-api
  description: Order management API exposed through API Gateway
  version: "1.0.0"
  contact:
    name: Platform Engineering
    url: https://developers.example.com/support
host: orders-gw-8fq1x2z.uc.gateway.dev
schemes:
  - https
produces:
  - application/json
consumes:
  - application/json

# ---------------------------------------------------------------------------
# Quota definition. Metrics are declared once, then referenced per operation
# with x-google-quota. This is API Gateway's (much simpler) equivalent of an
# Apigee API product.
# ---------------------------------------------------------------------------
x-google-management:
  metrics:
    - name: "read-requests"
      displayName: "Read requests"
      valueType: INT64
      metricKind: DELTA
    - name: "write-requests"
      displayName: "Write requests"
      valueType: INT64
      metricKind: DELTA
  quota:
    limits:
      - name: "read-limit"
        metric: "read-requests"
        unit: "1/min/{project}"
        values:
          STANDARD: 1000
      - name: "write-limit"
        metric: "write-requests"
        unit: "1/min/{project}"
        values:
          STANDARD: 100

securityDefinitions:
  api_key:
    type: "apiKey"
    name: "key"
    in: "query"
  partner_jwt:
    authorizationUrl: ""
    flow: "implicit"
    type: "oauth2"
    x-google-issuer: "https://auth.partner.example.com/"
    x-google-jwks_uri: "https://auth.partner.example.com/.well-known/jwks.json"
    x-google-audiences: "orders-api.example.com"
    x-google-jwt-locations:
      - header: "Authorization"
        value_prefix: "Bearer "

paths:
  /v1/orders:
    get:
      summary: List orders
      operationId: listOrders
      security:
        - api_key: []
        - partner_jwt: []
      x-google-backend:
        address: https://orders-svc-7hd2k9uc-uc.a.run.app/v1/orders
        protocol: h2
        deadline: 15.0
        path_translation: APPEND_PATH_TO_ADDRESS
      x-google-quota:
        metricCosts:
          "read-requests": 1
      parameters:
        - name: limit
          in: query
          required: false
          type: integer
          default: 50
          maximum: 500
          minimum: 1
        - name: cursor
          in: query
          required: false
          type: string
      responses:
        "200":
          description: A page of orders
          schema:
            $ref: "#/definitions/OrderPage"
        "401":
          description: Missing or invalid credentials
        "429":
          description: Quota exceeded

    post:
      summary: Create an order
      operationId: createOrder
      security:
        - partner_jwt: []
      x-google-backend:
        address: https://orders-svc-7hd2k9uc-uc.a.run.app/v1/orders
        protocol: h2
        deadline: 30.0
        path_translation: APPEND_PATH_TO_ADDRESS
      x-google-quota:
        metricCosts:
          "write-requests": 1
      parameters:
        - name: body
          in: body
          required: true
          schema:
            $ref: "#/definitions/OrderRequest"
      responses:
        "201":
          description: Order created
          schema:
            $ref: "#/definitions/Order"
        "400":
          description: Validation error
        "409":
          description: Idempotency key already used

  /v1/orders/{orderId}:
    get:
      summary: Get one order
      operationId: getOrder
      security:
        - api_key: []
        - partner_jwt: []
      x-google-backend:
        address: https://orders-svc-7hd2k9uc-uc.a.run.app/v1/orders/{orderId}
        protocol: h2
        deadline: 15.0
        path_translation: APPEND_PATH_TO_ADDRESS
      x-google-quota:
        metricCosts:
          "read-requests": 1
      parameters:
        - name: orderId
          in: path
          required: true
          type: string
      responses:
        "200":
          description: The order
          schema:
            $ref: "#/definitions/Order"
        "404":
          description: Not found

definitions:
  Order:
    type: object
    required: [id, status, amountMinor, currency, createdAt]
    properties:
      id:          { type: string, example: "ord_01JD3Q7YB2" }
      status:      { type: string, enum: [PENDING, AUTHORIZED, CAPTURED, REFUNDED, FAILED] }
      amountMinor: { type: integer, format: int64, description: "Amount in the currency's minor unit" }
      currency:    { type: string, pattern: "^[A-Z]{3}$", example: "EUR" }
      createdAt:   { type: string, format: date-time }
  OrderRequest:
    type: object
    required: [amountMinor, currency, idempotencyKey]
    properties:
      amountMinor:    { type: integer, format: int64, minimum: 1 }
      currency:       { type: string, pattern: "^[A-Z]{3}$" }
      idempotencyKey: { type: string, minLength: 16, maxLength: 64 }
  OrderPage:
    type: object
    properties:
      items:
        type: array
        items: { $ref: "#/definitions/Order" }
      nextCursor: { type: string }
```

### 3.4 Cloud Endpoints on GKE — ESPv2 sidecar, complete manifest

```yaml
# k8s/orders-endpoints.yaml
# gRPC service on GKE with an ESPv2 sidecar performing JSON<->gRPC transcoding,
# API key checking and JWT validation at the pod boundary.
---
apiVersion: v1
kind: Namespace
metadata:
  name: orders
  labels:
    app.kubernetes.io/part-of: api-platform
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-sa
  namespace: orders
  annotations:
    # Workload Identity: the ESPv2 sidecar needs servicecontrol.services.check
    # and .report against the managed Endpoints service.
    iam.gke.io/gcp-service-account: orders-esp@example-prod.iam.gserviceaccount.com
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: esp-config
  namespace: orders
data:
  ENDPOINTS_SERVICE_NAME: "orders.endpoints.example-prod.cloud.goog"
  ROLLOUT_STRATEGY: "managed"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: orders
  labels:
    app: orders
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: orders
  template:
    metadata:
      labels:
        app: orders
    spec:
      serviceAccountName: orders-sa
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: orders
      containers:
        # -------------------------------------------------------------------
        # ESPv2: the Envoy-based Extensible Service Proxy. It is the ONLY
        # container with a Service port; the app listens on loopback.
        # -------------------------------------------------------------------
        - name: esp
          image: gcr.io/endpoints-release/endpoints-runtime:2
          args:
            - --listener_port=8443
            - --backend=grpc://127.0.0.1:9000
            - --service=$(ENDPOINTS_SERVICE_NAME)
            - --rollout_strategy=$(ROLLOUT_STRATEGY)
            - --ssl_server_cert_path=/etc/esp/ssl
            - --healthz=/healthz
            - --cors_preset=basic
            - --cors_allow_origin=https://app.example.com
            - --underscores_in_headers
          env:
            - name: ENDPOINTS_SERVICE_NAME
              valueFrom:
                configMapKeyRef: { name: esp-config, key: ENDPOINTS_SERVICE_NAME }
            - name: ROLLOUT_STRATEGY
              valueFrom:
                configMapKeyRef: { name: esp-config, key: ROLLOUT_STRATEGY }
          ports:
            - name: https
              containerPort: 8443
          volumeMounts:
            - name: esp-ssl
              mountPath: /etc/esp/ssl
              readOnly: true
          readinessProbe:
            httpGet: { path: /healthz, port: 8443, scheme: HTTPS }
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: 8443, scheme: HTTPS }
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 5
          resources:
            requests: { cpu: "200m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }

        # -------------------------------------------------------------------
        # The business service. gRPC on loopback only — unreachable without
        # traversing ESPv2, so auth cannot be bypassed inside the pod network.
        # -------------------------------------------------------------------
        - name: orders
          image: europe-docker.pkg.dev/example-prod/apps/orders:1.14.2
          args: ["--listen=127.0.0.1:9000"]
          env:
            - name: DB_DSN
              valueFrom:
                secretKeyRef: { name: orders-db, key: dsn }
          readinessProbe:
            grpc: { port: 9000 }
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests: { cpu: "500m", memory: "512Mi" }
            limits:   { cpu: "2",    memory: "1Gi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: esp-ssl
          secret:
            secretName: esp-ssl-cert
---
apiVersion: v1
kind: Service
metadata:
  name: orders
  namespace: orders
  annotations:
    cloud.google.com/app-protocols: '{"https":"HTTP2"}'
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app: orders
  ports:
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: orders
  namespace: orders
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: orders
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 65 }
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders
  namespace: orders
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: orders
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: orders-ingress
  namespace: orders
spec:
  podSelector:
    matchLabels:
      app: orders
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-system }
      ports:
        - protocol: TCP
          port: 8443
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  namespace: orders
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "orders-api-ip"
    networking.gke.io/managed-certificates: "orders-cert"
spec:
  rules:
    - host: orders.example.com
      http:
        paths:
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: orders
                port:
                  number: 443
```

### 3.5 SLO as code — the reliability half of the commercial contract

```yaml
# slo/orders-availability.yaml
# Applied via: gcloud alpha monitoring slos create ... (or the Monitoring API).
displayName: "Orders API - 99.9% availability, 28d rolling"
goal: 0.999
rollingPeriod: 2419200s   # 28 days
serviceLevelIndicator:
  requestBased:
    goodTotalRatio:
      # "Good" excludes 429: a quota rejection is the product working
      # as designed, not an availability failure. Counting it would make
      # the error budget hostage to a single abusive partner.
      goodServiceFilter: >-
        metric.type="serviceruntime.googleapis.com/api/request_count"
        resource.type="consumed_api"
        resource.label."service"="orders.endpoints.example-prod.cloud.goog"
        metric.label."response_code_class"!="5xx"
      totalServiceFilter: >-
        metric.type="serviceruntime.googleapis.com/api/request_count"
        resource.type="consumed_api"
        resource.label."service"="orders.endpoints.example-prod.cloud.goog"
---
displayName: "Orders API - 95% of reads under 300ms, 28d rolling"
goal: 0.95
rollingPeriod: 2419200s
serviceLevelIndicator:
  requestBased:
    distributionCut:
      distributionFilter: >-
        metric.type="serviceruntime.googleapis.com/api/request_latencies"
        resource.type="consumed_api"
        resource.label."service"="orders.endpoints.example-prod.cloud.goog"
      range:
        min: 0
        max: 300
```

---

## 4. CLI: build, deploy, package, sell, observe

### 4.1 Provision and inspect the Apigee organization

```console
$ export PROJECT_ID=example-prod
$ export ORG=$PROJECT_ID
$ export REGION=us-central1
$ gcloud config set project "$PROJECT_ID"
Updated property [core/project].

$ gcloud alpha apigee organizations describe "$ORG" --format=yaml
analyticsRegion: us-central1
apiConsumerDataLocation: us-central1
authorizedNetwork: projects/example-prod/global/networks/apigee-vpc
billingType: PAYG
caCertificate: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
createdAt: '1755043201943'
description: Public and partner API program
environments:
- prod
- staging
name: example-prod
projectId: example-prod
runtimeDatabaseEncryptionKeyName: projects/example-prod/locations/us-central1/keyRings/apigee-keyring/cryptoKeys/apigee-database-key
runtimeType: CLOUD
state: ACTIVE
subscriptionType: PAYG

$ gcloud alpha apigee environments list --organization="$ORG"
prod
staging

$ gcloud alpha apigee instances describe instance-us-central1 \
    --organization="$ORG" --format="value(host,serviceAttachment,state)"
10.90.0.2	projects/f8a2c1-tp/regions/us-central1/serviceAttachments/apigee-us-central1-xk3q	ACTIVE
```

### 4.2 Deploy the proxy bundle

```console
$ cd apis/payments-v1
$ zip -r payments-v1.zip apiproxy -x '*.DS_Store'
  adding: apiproxy/ (stored 0%)
  adding: apiproxy/payments-v1.xml (deflated 41%)
  adding: apiproxy/proxies/default.xml (deflated 68%)
  adding: apiproxy/targets/default.xml (deflated 59%)
  adding: apiproxy/policies/VAK-VerifyKey.xml (deflated 34%)
  adding: apiproxy/policies/SA-SpikeArrest.xml (deflated 38%)
  adding: apiproxy/policies/Q-ProductQuota.xml (deflated 55%)
  adding: apiproxy/policies/RC-CatalogCache.xml (deflated 44%)
  adding: apiproxy/policies/AM-RemoveKeyHeader.xml (deflated 36%)
  adding: apiproxy/policies/AM-QuotaHeaders.xml (deflated 47%)
  adding: apiproxy/policies/RF-QuotaExceeded.xml (deflated 52%)

$ export TOKEN=$(gcloud auth print-access-token)

$ curl -sS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@payments-v1.zip" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/apis?action=import&name=payments-v1" \
  | jq '{name, revision}'
{
  "name": "payments-v1",
  "revision": "7"
}

$ gcloud alpha apigee deployments create \
    --organization="$ORG" --environment=prod \
    --api=payments-v1 --revision=7
Created deployment of API proxy [payments-v1] revision [7] to environment [prod].

$ gcloud alpha apigee deployments list --organization="$ORG" --environment=prod \
    --format="table(apiProxy,revision,state)"
API_PROXY      REVISION  STATE
payments-v1    7         READY
catalog-v2     3         READY
identity-v1    12        READY
```

### 4.3 Package it as a sellable product

This is the step that turns an endpoint into a business asset. Note that no proxy code changes.

```console
$ cat > product-payments-gold.json <<'JSON'
{
  "name": "payments-gold",
  "displayName": "Payments API - Gold",
  "description": "500,000 calls/month, 99.95% availability SLA, priority support",
  "approvalType": "manual",
  "environments": ["prod"],
  "operationGroup": {
    "operationConfigType": "proxy",
    "operationConfigs": [{
      "apiSource": "payments-v1",
      "operations": [
        { "resource": "/payments",   "methods": ["GET", "POST"] },
        { "resource": "/payments/*", "methods": ["GET"] },
        { "resource": "/refunds",    "methods": ["POST"] }
      ],
      "quota": { "limit": "500000", "interval": "1", "timeUnit": "month" }
    }]
  },
  "attributes": [
    { "name": "access",   "value": "public" },
    { "name": "tier",     "value": "gold" },
    { "name": "slaTarget","value": "99.95" }
  ]
}
JSON

$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @product-payments-gold.json \
    "https://apigee.googleapis.com/v1/organizations/$ORG/apiproducts" \
  | jq '{name, approvalType, quota: .operationGroup.operationConfigs[0].quota}'
{
  "name": "payments-gold",
  "approvalType": "manual",
  "quota": {
    "limit": "500000",
    "interval": "1",
    "timeUnit": "month"
  }
}

$ gcloud alpha apigee products list --organization="$ORG"
payments-free
payments-silver
payments-gold
catalog-public
```

Onboard a partner and mint credentials:

```console
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"email":"dev@partner.example","firstName":"Ada","lastName":"Lovelace","userName":"ada"}' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/developers" | jq -r '.developerId'
a5f0c1e2-7b34-4d19-9c88-0f21ab7e6d43

$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"partner-checkout","apiProducts":["payments-gold"],"callbackUrl":"https://partner.example/oauth/cb"}' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/developers/dev@partner.example/apps" \
  | jq '.credentials[0] | {consumerKey, status, apiProducts: [.apiProducts[].apiproduct]}'
{
  "consumerKey": "kQ7bZ2mX9pR4tW1sN6vL8cY3hJ0dF5gA",
  "status": "pending",
  "apiProducts": [
    "payments-gold"
  ]
}
```

Note `"status": "pending"` — `approvalType: manual` means the key exists but will be rejected at runtime until approved. That is a *commercial* control implemented in the *runtime* plane.

```console
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/developers/dev@partner.example/apps/partner-checkout/keys/kQ7bZ2mX9pR4tW1sN6vL8cY3hJ0dF5gA/apiproducts/payments-gold?action=approve"
$ echo "HTTP exit: $?"
HTTP exit: 0
```

Attach a rate plan (the price):

```console
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "gold-monthly-2026",
      "displayName": "Gold - EUR 499/month + EUR 0.0008/call over 500k",
      "billingPeriod": "MONTHLY",
      "paymentFundingModel": "POSTPAID",
      "currencyCode": "EUR",
      "state": "PUBLISHED",
      "fixedRecurringFee": { "currencyCode": "EUR", "units": "499" },
      "consumptionPricingType": "FIXED_PER_UNIT",
      "consumptionPricingRates": [
        { "fee": { "currencyCode": "EUR", "nanos": 800000 } }
      ],
      "startTime": "1767225600000"
    }' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/apiproducts/payments-gold/rateplans" \
  | jq '{name, state, fixedRecurringFee}'
{
  "name": "gold-monthly-2026",
  "state": "PUBLISHED",
  "fixedRecurringFee": {
    "currencyCode": "EUR",
    "units": "499"
  }
}
```

### 4.4 Exercise the API and observe the packaging

```console
$ export KEY=kQ7bZ2mX9pR4tW1sN6vL8cY3hJ0dF5gA

$ curl -sS -D- -o /dev/null \
    -H "x-api-key: $KEY" \
    https://api.example.com/v1/payments/pay_01JD3Q7YB2
HTTP/2 200
content-type: application/json
x-ratelimit-limit: 500000
x-ratelimit-remaining: 499987
x-ratelimit-reset: 1767225599000
x-request-id: 8f2c1a44-6d31-4e0b-b7a9-0c5e19d3b210
cache-control: private, max-age=30
server: apigee
date: Tue, 08 Sep 2026 09:14:22 GMT

$ curl -sS -D- -o /dev/null https://api.example.com/v1/payments/pay_01JD3Q7YB2
HTTP/2 401
content-type: application/json
www-authenticate: ApiKey realm="api.example.com"
x-request-id: 1b9d4e07-2a55-4c8e-9f13-77aa0e2c4d6b

$ for i in $(seq 1 3); do
    curl -sS -o /dev/null -w '%{http_code} ' -H "x-api-key: $KEY_FREE_TIER" \
      https://api.example.com/v1/payments
  done; echo
200 200 429

$ curl -sS -H "x-api-key: $KEY_FREE_TIER" https://api.example.com/v1/payments | jq
{
  "type": "https://api.example.com/problems/quota-exceeded",
  "title": "Monthly quota exceeded",
  "status": 429,
  "detail": "Your plan allows 1000 calls per interval. Upgrade at https://developers.example.com/plans",
  "instance": "rrt-4f9c2b1e8a-7-14022-9"
}
```

### 4.5 Query the analytics that price the product

```console
$ curl -sS -G -H "Authorization: Bearer $TOKEN" \
    --data-urlencode 'select=sum(message_count),avg(total_response_time),sum(is_error)' \
    --data-urlencode 'timeRange=08/01/2026 00:00~09/01/2026 00:00' \
    --data-urlencode 'timeUnit=month' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/stats/apiproduct" \
  | jq -r '.environments[0].dimensions[]
      | [.name,
         (.metrics[] | select(.name=="sum(message_count)") | .values[0]),
         (.metrics[] | select(.name=="avg(total_response_time)") | .values[0]),
         (.metrics[] | select(.name=="sum(is_error)") | .values[0])]
      | @tsv' \
  | column -t -N "PRODUCT,CALLS,AVG_MS,ERRORS"
PRODUCT         CALLS      AVG_MS   ERRORS
payments-gold   4128377    48.2     1204
payments-silver 981022     51.7     2988
payments-free   2447901    54.9     41022
catalog-public  11238044   12.4     880
```

Read that table as a business document, not a metrics dump:

- `payments-free` produces 2.45M calls and 41k errors — **most of them 429s**, i.e. the free tier hitting its cap. That is the conversion funnel, and it is measurable.
- `catalog-public` is 11.2M calls at 12.4 ms — almost certainly cache hits. Near-zero marginal cost; a candidate to bundle free as an adoption driver.
- `payments-gold` is 4.1M calls: 3.6M over the 500k included allowance across all Gold apps → overage revenue is a first-class line item you can compute from this query alone.

### 4.6 Deploy the API Gateway variant end-to-end

```console
$ gcloud services enable apigateway.googleapis.com \
    servicemanagement.googleapis.com servicecontrol.googleapis.com
Operation "operations/acat.p2-841203445977-9e2f0c1b-..." finished successfully.

$ gcloud api-gateway apis create orders-api --project="$PROJECT_ID"
Waiting for API [orders-api] to be created...done.

$ gcloud api-gateway api-configs create orders-cfg-v3 \
    --api=orders-api \
    --openapi-spec=openapi/orders-gateway.yaml \
    --backend-auth-service-account=orders-gw@example-prod.iam.gserviceaccount.com \
    --project="$PROJECT_ID"
Waiting for API config [orders-cfg-v3] to be created for API [orders-api]...done.

$ gcloud api-gateway gateways create orders-gw \
    --api=orders-api --api-config=orders-cfg-v3 \
    --location=us-central1 --project="$PROJECT_ID"
Waiting for gateway [orders-gw] to be created...done.

$ gcloud api-gateway gateways describe orders-gw --location=us-central1 \
    --format="value(defaultHostname,state)"
orders-gw-8fq1x2z.uc.gateway.dev	ACTIVE

$ gcloud api-gateway api-configs list --api=orders-api \
    --format="table(name.basename(),state,createTime)"
NAME            STATE   CREATE_TIME
orders-cfg-v1   ACTIVE  2026-07-02T11:03:19Z
orders-cfg-v2   ACTIVE  2026-08-14T09:41:55Z
orders-cfg-v3   ACTIVE  2026-09-08T08:52:10Z

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    "https://orders-gw-8fq1x2z.uc.gateway.dev/v1/orders?key=$GW_KEY"
200
```

Promoting a new config is a **gateway update**, not a recreate — the hostname is stable, so consumers are untouched:

```console
$ gcloud api-gateway gateways update orders-gw \
    --api=orders-api --api-config=orders-cfg-v3 --location=us-central1
Waiting for gateway [orders-gw] to be updated...done.
```

### 4.7 Deploy the Cloud Endpoints service config

```console
$ gcloud endpoints services deploy openapi/orders-endpoints.yaml
Waiting for async operation operations/serviceConfigs.orders.endpoints.example-prod.cloud.goog:9f1a... to complete...
Operation finished successfully. The following command can describe the Operation details:
 gcloud endpoints operations describe operations/serviceConfigs.orders.endpoints.example-prod.cloud.goog:9f1a...

Service Configuration [2026-09-08r0] uploaded for service [orders.endpoints.example-prod.cloud.goog]

$ gcloud endpoints configs list --service=orders.endpoints.example-prod.cloud.goog \
    --format="table(id,name)" --limit=3
CONFIG_ID      NAME
2026-09-08r0   orders.endpoints.example-prod.cloud.goog
2026-08-19r1   orders.endpoints.example-prod.cloud.goog
2026-08-19r0   orders.endpoints.example-prod.cloud.goog

$ kubectl -n orders rollout restart deployment/orders
deployment.apps/orders restarted

$ kubectl -n orders rollout status deployment/orders --timeout=180s
Waiting for deployment "orders" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "orders" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "orders" successfully rolled out
```

With `--rollout_strategy=managed`, ESPv2 polls for the latest config and picks it up without a restart; the restart above is only shown for the pinned-config case.

---

## 5. Verification and failure diagnosis

### 5.1 Pre-deploy verification ladder

Run these in order. Each rung is cheap and catches a distinct class of failure.

```console
# 1. Does the OpenAPI document parse and satisfy the 2.0 constraints?
$ npx --yes @redocly/cli lint openapi/orders-gateway.yaml
validating openapi/orders-gateway.yaml...
openapi/orders-gateway.yaml: validated in 214ms

Woohoo! Your API description is valid. 🎉

# 2. Will the config be accepted WITHOUT creating anything (dry run via
#    a throwaway config that you then delete)?
$ gcloud api-gateway api-configs create orders-cfg-lint \
    --api=orders-api --openapi-spec=openapi/orders-gateway.yaml 2>&1 | tail -3
Waiting for API config [orders-cfg-lint] to be created for API [orders-api]...done.
$ gcloud api-gateway api-configs delete orders-cfg-lint --api=orders-api --quiet
Deleted config [orders-cfg-lint].

# 3. Does the Apigee bundle pass static validation before deployment?
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: multipart/form-data" -F "file=@payments-v1.zip" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/apis?action=validate&name=payments-v1" \
  | jq '{name, revision}'
{
  "name": "payments-v1",
  "revision": "8"
}

# 4. Is the deployed revision actually serving?
$ gcloud alpha apigee deployments describe --organization="$ORG" \
    --environment=prod --api=payments-v1 --format="value(state)"
READY

# 5. Contract test against the live edge, not against localhost.
$ npx --yes @stoplight/prism-cli proxy openapi/orders-gateway.yaml \
    https://orders-gw-8fq1x2z.uc.gateway.dev --errors &
$ curl -sS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:4010/v1/orders?key=$GW_KEY"
200
```

### 5.2 Failure catalogue

| Symptom | Most likely cause | Confirming command | Fix |
|---|---|---|---|
| `401` with `"Method doesn't allow unregistered callers"` | ESPv2/API Gateway required an API key; none sent, or the key belongs to a different project | `curl -D- ".../v1/orders"` — check `www-authenticate` | Send `?key=` / `x-api-key`; verify the key's project matches the managed service |
| `403 API_KEY_SERVICE_BLOCKED` | The key exists but the Endpoints/API Gateway managed service is not enabled on the *consumer* project | `gcloud services list --enabled --project=<consumer> \| grep endpoints` | `gcloud services enable orders.endpoints.<proj>.cloud.goog --project=<consumer>` |
| `403` from a Cloud Run backend behind API Gateway | The gateway's service account lacks `roles/run.invoker` | `gcloud run services get-iam-policy orders-svc --region=us-central1` | `gcloud run services add-iam-policy-binding orders-svc --member=serviceAccount:orders-gw@... --role=roles/run.invoker` |
| `JWT validation failed: Audience doesn't match` | `x-google-audiences` ≠ the `aud` claim the IdP issues | `printf '%s' "$JWT" \| cut -d. -f2 \| base64 -d 2>/dev/null \| jq .aud` | Align the spec's `x-google-audiences` with the IdP's audience, redeploy the config |
| Intermittent `401` right after an IdP key rotation | Stale JWKS cache in the proxy | Compare `kid` in the JWT header against the live JWKS | Overlap old/new keys in the JWKS for ≥ the cache TTL before retiring the old key |
| `429` far below the documented plan limit | Apigee `Quota` counting per message processor because `Distributed` is false | Inspect `Q-ProductQuota.xml` | Set `<Distributed>true</Distributed>`; with `Synchronous=false`, accept slight overage at interval boundaries |
| `429` under Cloud Armor, not the API | The edge rate-limit rule is tighter than the sold tier | `gcloud compute security-policies describe api-edge-policy` | Raise the Cloud Armor threshold above the highest tier's burst; Armor is a volumetric floor, not the product limit |
| `503` / `Backend unavailable` on Apigee only | Target `io.timeout.millis` shorter than the backend's p99 | Correlate `target_response_time` against `total_response_time` in analytics | Raise `io.timeout.millis`, or fix the slow backend path — do not raise blindly |
| `502` with `upstream connect error` on ESPv2 | The app container is not listening on the `--backend` address/port | `kubectl -n orders exec deploy/orders -c esp -- wget -qO- 127.0.0.1:9000/healthz` | Align the app's listen address with `--backend` |
| Apigee proxy deploys but returns `404` for every path | `<BasePath>` collides with another proxy, or the request host is not in the env group | `gcloud alpha apigee envgroups describe external --organization=$ORG` | Make base paths unique per environment; add the hostname to the env group |
| TLS handshake failure to `api.example.com` | Managed certificate still `PROVISIONING` (DNS not pointing at the LB IP) | `gcloud compute ssl-certificates describe api-cert --global --format="value(managed.status,managed.domainStatus)"` | Point the A record at the LB IP and wait; status must reach `ACTIVE` |
| Analytics show far fewer calls than the LB | Requests terminating at Cloud Armor or the LB before reaching the proxy | Compare LB request count in Cloud Monitoring with Apigee `message_count` | Inspect Cloud Armor logs for `deny` verdicts |

### 5.3 Diagnostic sessions and live tracing

Apigee's Debug (trace) session captures the full policy execution path for a sampled slice of traffic:

```console
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"filter":"request.header.x-debug = \"1\"","timeout":"600","count":20}' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/apis/payments-v1/revisions/7/debugsessions" \
  | jq '{name, count, timeout}'
{
  "name": "b7c19a3e-0d55-4f11-9a2b-6e8104cc2f77",
  "count": 20,
  "timeout": "600"
}

$ curl -sS -H "x-api-key: $KEY" -H "x-debug: 1" \
    -o /dev/null -w '%{http_code}\n' https://api.example.com/v1/payments/pay_01JD3Q7YB2
200

$ SESSION=b7c19a3e-0d55-4f11-9a2b-6e8104cc2f77
$ curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/apis/payments-v1/revisions/7/debugsessions/$SESSION/data" \
  | jq -r '.[0]'
rrt-4f9c2b1e8a-7-14022-9

$ curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/apis/payments-v1/revisions/7/debugsessions/$SESSION/data/rrt-4f9c2b1e8a-7-14022-9" \
  | jq -r '.point[] | select(.id=="Execution" or .id=="StateChange") as $p
           | ($p.results[]? | select(.ActionResult=="DebugInfo") | .properties.property[]?
              | select(.name=="Step") | "\(.value)")' 2>/dev/null | head
SA-SpikeArrest
VAK-VerifyKey
Q-ProductQuota
AM-RemoveKeyHeader
RC-CatalogCache
AM-QuotaHeaders
```

ESPv2 diagnostics on GKE:

```console
$ kubectl -n orders logs deploy/orders -c esp --tail=20
INFO: Starting ESPv2 with config: orders.endpoints.example-prod.cloud.goog
INFO: Fetching service config ID from the rollouts service
INFO: Service config ID: 2026-09-08r0
INFO: Transcoding enabled for 14 gRPC methods
WARNING: JWKS cache miss for issuer https://auth.partner.example.com/, fetching
INFO: Envoy listening on 0.0.0.0:8443 (TLS)

$ kubectl -n orders exec deploy/orders -c esp -- \
    wget -qO- http://127.0.0.1:8001/stats 2>/dev/null \
  | grep -E 'http.ingress_http.downstream_rq_(2xx|4xx|5xx|xx)'
http.ingress_http.downstream_rq_2xx: 184203
http.ingress_http.downstream_rq_4xx: 2911
http.ingress_http.downstream_rq_5xx: 17

$ kubectl -n orders exec deploy/orders -c esp -- \
    wget -qO- http://127.0.0.1:8001/clusters 2>/dev/null \
  | grep -E 'backend-cluster.*(health_flags|cx_active)'
backend-cluster-127.0.0.1_9000::127.0.0.1:9000::cx_active::12
backend-cluster-127.0.0.1_9000::127.0.0.1:9000::health_flags::healthy
```

Correlated log query across the edge:

```console
$ gcloud logging read '
    resource.type="apigee.googleapis.com/Environment"
    AND severity>=WARNING
    AND jsonPayload.response_status_code>=500' \
    --limit=5 --freshness=1h \
    --format="table(timestamp, jsonPayload.api_proxy, jsonPayload.response_status_code, jsonPayload.fault_source)"
TIMESTAMP                       API_PROXY      RESPONSE_STATUS_CODE  FAULT_SOURCE
2026-09-08T08:41:02.118Z        payments-v1    503                   target
2026-09-08T08:41:02.443Z        payments-v1    503                   target
2026-09-08T08:41:03.007Z        payments-v1    504                   target
2026-09-08T08:52:19.882Z        catalog-v2     500                   policy
2026-09-08T08:52:20.114Z        catalog-v2     500                   policy
```

`fault_source` is the single most useful field in that table: `target` means your backend, `policy` means your gateway configuration. It routes the page to the correct team in one glance.

### 5.4 Verifying the *business* claims, not just the plumbing

A green dashboard does not prove the API is delivering value. These are the checks that do:

```console
# Time-to-first-successful-call for a brand-new developer app.
$ gcloud logging read '
    resource.type="apigee.googleapis.com/Environment"
    AND jsonPayload.developer_app="partner-checkout"
    AND jsonPayload.response_status_code=200' \
    --limit=1 --order=asc --format="value(timestamp)"
2026-09-08T10:07:44.219Z
# App created 2026-09-08T09:52:10Z -> TTFSC = 15m34s.

# Which products carry traffic, and which are shelfware?
$ curl -sS -G -H "Authorization: Bearer $TOKEN" \
    --data-urlencode 'select=sum(message_count)' \
    --data-urlencode 'timeRange=08/08/2026 00:00~09/08/2026 00:00' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/stats/apiproduct" \
  | jq -r '.environments[0].dimensions[] | "\(.name)\t\(.metrics[0].values[0])"' \
  | awk -F'\t' '$2+0 < 1000 { print "SHELFWARE: " $1 " (" $2 " calls/30d)" }'
SHELFWARE: legacy-fx-quotes (312 calls/30d)
SHELFWARE: partner-beta-v0 (0 calls/30d)

# 429 rate per product = the upgrade signal (or the mis-sized-tier alarm).
$ curl -sS -G -H "Authorization: Bearer $TOKEN" \
    --data-urlencode 'select=sum(message_count)' \
    --data-urlencode 'filter=(response_status_code eq 429)' \
    --data-urlencode 'timeRange=09/01/2026 00:00~09/08/2026 00:00' \
    "https://apigee.googleapis.com/v1/organizations/$ORG/environments/prod/stats/apiproduct" \
  | jq -r '.environments[0].dimensions[] | "\(.name)\t\(.metrics[0].values[0])"' \
  | column -t -N "PRODUCT,THROTTLED_7D"
PRODUCT          THROTTLED_7D
payments-free    9841
payments-silver  204
payments-gold    0
```

Three products, three different readings of the same metric. `payments-free` throttling heavily is the funnel working. `payments-silver` throttling at all is worth a conversation — either the tier is mis-sized or a customer has outgrown it. `payments-gold` at zero confirms the premium tier is genuinely unconstrained, which is what the customer paid for.

### 5.5 Governance verification

An API program without an inventory decays into the same N×M mess it was built to escape. Enforce discoverability:

```console
# Every proxy in prod must map to at least one published API product.
$ comm -23 \
    <(gcloud alpha apigee deployments list --organization="$ORG" --environment=prod \
        --format="value(apiProxy)" | sort -u) \
    <(gcloud alpha apigee products list --organization="$ORG" --format="value(name)" \
      | while read -r p; do
          gcloud alpha apigee products describe "$p" --organization="$ORG" \
            --format="value(operationGroup.operationConfigs[].apiSource)"
        done | tr ',' '\n' | sed '/^$/d' | sort -u)
identity-v1
# -> identity-v1 is deployed but unsellable and undiscoverable. Fail the CI gate.
```

---

## 6. Exam-oriented synthesis

Compressed to what a Cloud Digital Leader question actually tests:

| If the question mentions… | The intended answer is… | Because |
|---|---|---|
| "monetize", "rate plans", "developer portal", "partner ecosystem", "API products" | **Apigee** | Only Apigee has products, rate plans, portals, and monetization |
| "expose a Cloud Run / Cloud Functions service with a key and JWT, minimal ops" | **API Gateway** | Fully managed, serverless-native, no policy platform needed |
| "gRPC service on GKE", "we already run the proxy" | **Cloud Endpoints (ESPv2)** | Sidecar model with gRPC transcoding |
| "unlock a mainframe / legacy monolith without rewriting it" | **Apigee as a façade** (strangler-fig) | Mediation and protocol translation preserve consumers during migration |
| "DDoS, OWASP, IP allowlist, volumetric attack" | **Cloud Armor** in front of the gateway | Business quota ≠ volumetric defence |
| "catalogue and govern APIs across many teams" | **API hub** (+ Apigee) | Discovery/governance layer over the estate |
| "reduce integration cost between internal systems" | **API-led reuse**, internal chargeback | Quadratic → linear integration cost |
| "new revenue stream from existing data/capability" | **API productization + rate plans** | The API is the product |

**Four sentences worth memorizing verbatim:**

1. An API turns an internal capability into a reusable, metered, versioned product that consumers adopt self-service.
2. Apigee manages the *lifecycle and commerce* of APIs; API Gateway and Cloud Endpoints *serve* them.
3. The same quota mechanism that protects the backend is the mechanism that packages and prices the offering.
4. An API façade decouples the consumer contract from the backend implementation, which is what makes incremental modernization possible at all.

---

## 7. Referencias

**Exam guide**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Apigee**
- Apigee documentation — https://cloud.google.com/apigee/docs
- Apigee X provisioning overview — https://cloud.google.com/apigee/docs/api-platform/get-started/overview
- Policy reference — https://cloud.google.com/apigee/docs/api-platform/reference/policies/reference-overview-policy
- Quota policy — https://cloud.google.com/apigee/docs/api-platform/reference/policies/quota-policy
- SpikeArrest policy — https://cloud.google.com/apigee/docs/api-platform/reference/policies/spike-arrest-policy
- VerifyAPIKey policy — https://cloud.google.com/apigee/docs/api-platform/reference/policies/verify-api-key-policy
- API products — https://cloud.google.com/apigee/docs/api-platform/publish/what-api-product
- Monetization and rate plans — https://cloud.google.com/apigee/docs/api-platform/monetization/overview
- Analytics metrics, dimensions and filters — https://cloud.google.com/apigee/docs/api-platform/analytics/analytics-reference
- Debug (trace) sessions — https://cloud.google.com/apigee/docs/api-platform/debug/trace
- Northbound networking with PSC — https://cloud.google.com/apigee/docs/api-platform/system-administration/northbound-networking-psc-google-managed
- Apigee Advanced API Security — https://cloud.google.com/apigee/docs/api-security
- Apigee API management REST API — https://cloud.google.com/apigee/docs/reference/apis/apigee/rest
- Apigee pricing — https://cloud.google.com/apigee/pricing

**API Gateway**
- API Gateway documentation — https://cloud.google.com/api-gateway/docs
- OpenAPI overview and `x-google-*` extensions — https://cloud.google.com/api-gateway/docs/openapi-overview
- Configuring quotas — https://cloud.google.com/api-gateway/docs/quotas-overview
- Authenticating with JWT — https://cloud.google.com/api-gateway/docs/authenticating-users-jwt
- `gcloud api-gateway` reference — https://cloud.google.com/sdk/gcloud/reference/api-gateway

**Cloud Endpoints**
- Cloud Endpoints documentation — https://cloud.google.com/endpoints/docs
- ESPv2 on GKE (OpenAPI) — https://cloud.google.com/endpoints/docs/openapi/get-started-kubernetes-engine
- ESPv2 startup options — https://cloud.google.com/endpoints/docs/openapi/specify-esp-v2-startup-options
- gRPC transcoding — https://cloud.google.com/endpoints/docs/grpc/transcoding

**Supporting platform**
- Cloud Armor security policies — https://cloud.google.com/armor/docs/security-policy-overview
- Cloud Armor rate limiting — https://cloud.google.com/armor/docs/rate-limiting-overview
- External Application Load Balancer overview — https://cloud.google.com/load-balancing/docs/https
- Private Service Connect — https://cloud.google.com/vpc/docs/private-service-connect
- Service-level objectives in Cloud Monitoring — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- API design guide (Google AIP) — https://cloud.google.com/apis/design
- API Improvement Proposals — https://google.aip.dev/
- Terraform Google provider, Apigee resources — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/apigee_organization

**Standards**
- OpenAPI Specification 2.0 (Swagger) — https://spec.openapis.org/oas/v2.0
- RFC 9457 — Problem Details for HTTP APIs — https://www.rfc-editor.org/rfc/rfc9457
- RFC 6749 — The OAuth 2.0 Authorization Framework — https://www.rfc-editor.org/rfc/rfc6749
- RFC 7519 — JSON Web Token (JWT) — https://www.rfc-editor.org/rfc/rfc7519
- RFC 6585 §4 — 429 Too Many Requests — https://www.rfc-editor.org/rfc/rfc6585#section-4