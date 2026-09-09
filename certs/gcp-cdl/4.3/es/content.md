# 4.3 — El valor de negocio de las APIs

**Certificación:** Google Cloud Digital Leader (`gcp-cdl`), versión de examen 2026-08-12
**Dominio 4:** Confianza y seguridad / valor de la modernización — peso del objetivo **6.0**
**Nivel de audiencia:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el problema arquitectónico que realmente resuelve un programa de APIs

### 1.1 La explosión de integraciones N×M

Toda empresa que no haya tratado a las interfaces como productos termina en el mismo modo de falla. Dados `N` sistemas productores y `M` sistemas consumidores, la integración punto a punto ad hoc converge a `O(N×M)` conectores a medida. Cada conector carga con su propio esquema de autenticación, su propia semántica de reintentos, su propia serialización, su propia guardia de on-call y su propio acoplamiento no documentado a un esquema de base de datos.

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

La declaración de valor de negocio que el examen Cloud Digital Leader espera que sepas formular no es "las APIs son buena ingeniería". Es esta:

> Una API convierte una capacidad interna en un **activo reutilizable, medido y versionado de forma independiente**, cuyos consumidores pueden incorporarse sin un proyecto, sin una negociación contractual ni una release coordinada.

La consecuencia arquitectónica es que el costo de integración pasa de ser **variable y cuadrático** a **fijo y lineal**. Eso es una afirmación de balance contable, no estética.

### 1.2 Los tres pozos de valor

| Pozo de valor | Mecanismo | Métrica de negocio medible | Dueño típico |
|---|---|---|---|
| **Eficiencia interna** | Reutilización de una capacidad existente en lugar de reconstruirla; consumo self-service | Lead time de integración (semanas → días); cantidad de sistemas duplicados; chargeback interno por cada 1k llamadas | Platform engineering |
| **Alcance de ecosistema / partners** | Los partners construyen sobre tu capacidad sin que vos escribas su código | Time-to-first-successful-call (TTFSC); cantidad de apps de partners activas; GMV atribuido a partners | Digital / partnerships |
| **Monetización directa** | La API *es* el producto; facturación medida por llamada, por tier o por revenue-share | ARPU por developer; ingresos por cada 1k llamadas; conversión de tier free → paid | Producto / comercial |

Un cuarto pozo, frecuentemente sub-modelado:

| **Opcionalidad de modernización** | Una fachada de API delante de un mainframe/monolito permite reemplazar el backend sin tocar a los consumidores (strangler-fig) | % del tráfico servido por el nuevo backend; cantidad de consumidores que requieren cambios durante el cutover (objetivo: **cero**) | Arquitectura |

### 1.3 El encuadre SRE: una API es un SLO con etiqueta de precio

Una vez que una interfaz tiene consumidores externos que pagan — en dinero o en chargeback interno — la conversación sobre confiabilidad cambia de forma:

- El **SLI** se define en el límite del contrato de la API (disponibilidad y latencia observadas en el proxy), no en el pod.
- El **error budget** se convierte en un instrumento comercial: es lo que se te permite gastar en velocidad de cambio antes de deber un service credit.
- **El rate limiting no es solo protección, es packaging.** La misma política `Quota` que evita el colapso de un backend es el mecanismo que diferencia el tier Free del tier Gold. Este doble propósito es el hecho técnico más relevante para el examen dentro de este objetivo.

---

## 2. La superficie de APIs de Google Cloud: comparación técnica

Google Cloud ofrece tres productos distintos en este espacio, y el examen CDL espera que ubiques cada uno correctamente.

### 2.1 Matriz de selección de producto

| Dimensión | **Apigee (X / hybrid)** | **API Gateway** | **Cloud Endpoints (ESPv2)** |
|---|---|---|---|
| Posicionamiento | Plataforma de **gestión** de APIs de ciclo de vida completo | Gateway administrado para backends serverless | Proxy autogestionado (basado en Envoy) que desplegás junto a tu servicio |
| Control plane | Management plane multi-tenant administrado por Google; runtime en tu proyecto | Totalmente administrado, regional | Vos corrés el proxy; Service Management/Service Control son administrados |
| Topología de despliegue | Instancia(s) de runtime regionales, expuestas vía external Application Load Balancer + PSC NEG | Gateway administrado regional, hostname `*.gateway.dev` | Sidecar o front proxy en GKE, Cloud Run, GCE, App Engine flex |
| Formato de spec | OpenAPI 2.0/3.x para diseño + import; comportamiento en runtime desde las políticas del proxy bundle | **Solo OpenAPI 2.0** (Swagger) con extensiones `x-google-*` | **Solo OpenAPI 2.0**, o service config de gRPC + descriptor proto |
| Modelo de políticas | ~50 políticas declarativas (OAuthV2, JWT, SpikeArrest, Quota, ResponseCache, ServiceCallout, transformación de mensajes, callouts JS/Java) | Conjunto fijo: API key, autenticación JWT, quota por consumidor, ruteo al backend | El mismo conjunto fijo que API Gateway (linaje ESPv2 compartido) |
| Mediación / transformación | Sí — REST↔SOAP, reescritura de payload, orquestación, ruteo condicional | No | No (solo transcoding gRPC↔JSON) |
| Developer portal | Sí (portal integrado + opción basada en Drupal) | No | No |
| **Monetización / rate plans** | **Sí** — API products, rate plans, documentos de facturación | No | No |
| Analytics | Profundo: por proxy, por producto, por developer, por app, dimensiones personalizadas, retención | Métricas de Cloud Monitoring / Cloud Logging | Métricas de Cloud Monitoring / Cloud Logging |
| Advanced API Security | Sí (detección de abuso, security scores, detección de misconfiguraciones) | No (componer con Cloud Armor) | No (componer con Cloud Armor) |
| Perfil de costo | Suscripción (Standard/Enterprise/Enterprise Plus) o pay-as-you-go por tipo de entorno | Por llamada, bajo | Cómputo del proxy + llamadas a Service Control |
| Encaje típico | Programas de APIs públicas/de partners, APIs monetizadas, fachada de mainframe, gobernanza a nivel organización | APIs sobre Cloud Run / Cloud Functions que necesitan una puerta con key + JWT | Servicios gRPC en GKE; ya sos dueño del despliegue |

**Heurística de decisión:**

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

### 2.2 Trade-offs del estilo de interfaz

El argumento de "valor de negocio" depende del estilo. Elegir gRPC para una API pública de cara a partners destruye el pozo de valor del ecosistema, porque los developers junior de tus partners no pueden hacerle `curl`.

| Estilo | Wire | Descubribilidad | Costo de onboarding del partner | Latencia / payload | Radio de impacto de cambios rompientes | Mejor pozo de valor |
|---|---|---|---|---|---|---|
| **REST/JSON sobre HTTP/1.1** | Texto, cacheable | La más alta (OpenAPI, navegable) | El más bajo — `curl` funciona | Más bytes, ~1 RTT/llamada | Contenido por versionado en la URI | Ecosistema, monetización |
| **gRPC sobre HTTP/2** | Protobuf, binario | Baja sin tooling (necesita `.proto` + reflection) | Alto (toolchain de codegen) | Payloads ~30–60% más chicos, streams multiplexados | Las reglas de números de campo de Protobuf hacen seguro el cambio aditivo | Eficiencia interna |
| **GraphQL** | JSON, endpoint único | Introspectivo, autodocumentado | Medio | Menos round-trips; riesgo de N+1 en los resolvers | Deprecación por campo, sin versión en la URI | UIs guiadas por el consumidor |
| **Async / eventos (Pub/Sub, Kafka)** | JSON/Avro/Proto | Dependiente del schema registry | Alto (necesita infra del consumidor) | Desacoplado, sin presupuesto de latencia sincrónica | Reglas de evolución de esquema | Desacople interno, fan-out |
| **Webhooks (vos los llamás)** | JSON | Baja | Medio (el partner debe hostear un endpoint) | Push, sin costo de polling | El contrato de reintentos/idempotencia es la parte difícil | Integración con partners |

**Nota de producción:** el patrón de producción de mayor valor *no* es "elegir uno". Es **gRPC internamente, REST en el borde**, con la traducción de frontera hecha una sola vez — por transcoding de ESPv2 o por un proxy de Apigee — de modo que tanto la eficiencia interna como el alcance externo se compran sin pedirles a los equipos de servicio que mantengan dos implementaciones escritas a mano.

### 2.3 Trade-offs del modelo de autenticación

| Mecanismo | Identifica | Revocable | Adecuado para | Modo de falla que vas a ver de verdad |
|---|---|---|---|---|
| **API key** | La *app*, no al usuario | Sí (por key) | Identificación de tráfico, atribución de quota, tiers gratuitos | Keys en repos Git públicos; keys en query strings que terminan en los access logs |
| **OAuth 2.0 client credentials** | La *app*, criptográficamente | Sí (TTL del token + revocación) | Acceso server-to-server de partners | Ausencia de caché de tokens → el token endpoint se vuelve el cuello de botella |
| **OAuth 2.0 authorization code + PKCE** | Al *usuario final* | Sí | Apps de terceros actuando en nombre de un usuario | Redirect-URI mal configurado; scope creep en la pantalla de consentimiento |
| **JWT (IdP externo)** | App o usuario, verificable offline | Solo vía TTL corto / denylist | Zero-trust, alto throughput (sin RTT de introspección) | Clock skew; `aud` que no coincide; caché de JWKS no refrescada tras la rotación de claves |
| **mTLS** | El certificado del cliente | Sí (CRL/certificados de vida corta) | B2B regulado, PSD2/FAPI | Vencimiento del certificado a las 03:00 de un domingo |
| **ID token firmado por Google (IAM)** | Una service account de Google | Sí | Servicio a servicio interno en GCP | Falta `roles/run.invoker` → un 403 que parece un bug de la app |

**Ponelos en capas.** En producción, API key para *atribución y packaging*, OAuth/JWT para *autorización*, mTLS para *confianza del canal* donde la regulación lo exija. La API key responde "¿a quién le facturo?"; el token responde "¿qué puede hacer?".

### 2.4 Modelos de monetización

| Modelo | Unidad de medición | Dónde se aplica | Previsibilidad de ingresos | Fricción de adopción |
|---|---|---|---|---|
| **Free / abierto** | ninguna | Solo spike arrest | ninguna (valor indirecto) | la más baja |
| **Freemium** | llamadas/mes, tope duro | Política `Quota` por API product | baja | baja |
| **Pay-as-you-go** | por llamada, por MB, por transacción | Quota + export de facturación guiado por analytics | media (ligada al volumen) | media |
| **Por niveles (Bronze/Silver/Gold)** | llamadas/s + llamadas/mes + SLA | API products distintos, rate plans distintos | alta | media |
| **Revenue share** | % del valor de la transacción que la API habilita | Atributo personalizado capturado en analytics | alta, alineada | alta (requiere contrato) |
| **Chargeback interno** | llamadas/mes por centro de costo | Quota por developer app, exportada a facturación | n/a — transparencia de costos | baja |

Apigee expresa esto de forma nativa: **API proxy** (runtime) → **API product** (el paquete vendible de recursos del proxy + quota) → **developer** → **developer app** (contiene las credenciales) → **rate plan** (el precio). Internalizá esa cadena; es la expresión mecánica del "valor de negocio de las APIs".

---

## 3. Infraestructura y manifiestos completos

### 3.1 Fundación de Apigee X — Terraform

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

### 3.2 El proxy bundle de Apigee — donde el packaging realmente se aplica

Disposición del bundle:

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

**`apiproxy/proxies/default.xml`** — la cadena de políticas en orden de ejecución:

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

**`apiproxy/policies/Q-ProductQuota.xml`** — el punto de aplicación de la monetización:

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

**`apiproxy/policies/AM-QuotaHeaders.xml`** — la mitad de la misma funcionalidad que corresponde a la experiencia del developer:

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

**`apiproxy/policies/RF-QuotaExceeded.xml`** — un 429 sobre el que un partner puede actuar:

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

**`apiproxy/targets/default.xml`** — con semántica de reintentos y timeouts adyacentes a un circuit breaker:

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

### 3.3 API Gateway — configuración OpenAPI 2.0 completa

Usá esto cuando el backend es Cloud Run y necesitás una puerta con key + JWT, no un catálogo de productos.

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

### 3.4 Cloud Endpoints en GKE — sidecar ESPv2, manifiesto completo

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

### 3.5 SLO como código — la mitad de confiabilidad del contrato comercial

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

## 4. CLI: construir, desplegar, empaquetar, vender, observar

### 4.1 Aprovisionar e inspeccionar la organización de Apigee

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

### 4.2 Desplegar el proxy bundle

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

### 4.3 Empaquetarla como un producto vendible

Este es el paso que convierte un endpoint en un activo de negocio. Notá que no cambia nada del código del proxy.

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

Incorporar un partner y emitir credenciales:

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

Notá el `"status": "pending"` — `approvalType: manual` significa que la key existe pero será rechazada en runtime hasta que se apruebe. Eso es un control *comercial* implementado en el plano de *runtime*.

```console
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    "https://apigee.googleapis.com/v1/organizations/$ORG/developers/dev@partner.example/apps/partner-checkout/keys/kQ7bZ2mX9pR4tW1sN6vL8cY3hJ0dF5gA/apiproducts/payments-gold?action=approve"
$ echo "HTTP exit: $?"
HTTP exit: 0
```

Adjuntar un rate plan (el precio):

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

### 4.4 Ejercitar la API y observar el packaging

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

### 4.5 Consultar las analíticas que ponen precio al producto

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

Leé esa tabla como un documento de negocio, no como un volcado de métricas:

- `payments-free` produce 2,45 M de llamadas y 41k errores — **la mayoría de ellos 429s**, es decir, el tier gratuito chocando contra su tope. Ese es el embudo de conversión, y es medible.
- `catalog-public` son 11,2 M de llamadas a 12,4 ms — casi con certeza aciertos de caché. Costo marginal casi nulo; un candidato para incluir gratis como impulsor de adopción.
- `payments-gold` son 4,1 M de llamadas: 3,6 M por encima de los 500k incluidos entre todas las apps Gold → el ingreso por excedente es una línea de primer orden que podés calcular solo con esta consulta.

### 4.6 Desplegar la variante de API Gateway de punta a punta

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

Promover una configuración nueva es un **update del gateway**, no una recreación — el hostname es estable, así que los consumidores no se ven afectados:

```console
$ gcloud api-gateway gateways update orders-gw \
    --api=orders-api --api-config=orders-cfg-v3 --location=us-central1
Waiting for gateway [orders-gw] to be updated...done.
```

### 4.7 Desplegar el service config de Cloud Endpoints

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

Con `--rollout_strategy=managed`, ESPv2 hace polling de la última configuración y la toma sin necesidad de reiniciar; el restart de arriba se muestra solamente para el caso de configuración fijada.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Escalera de verificación previa al despliegue

Ejecutá estos pasos en orden. Cada peldaño es barato y atrapa una clase distinta de falla.

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

### 5.2 Catálogo de fallas

| Síntoma | Causa más probable | Comando de confirmación | Solución |
|---|---|---|---|
| `401` con `"Method doesn't allow unregistered callers"` | ESPv2/API Gateway requería una API key; no se envió ninguna, o la key pertenece a otro proyecto | `curl -D- ".../v1/orders"` — revisar `www-authenticate` | Enviar `?key=` / `x-api-key`; verificar que el proyecto de la key coincida con el managed service |
| `403 API_KEY_SERVICE_BLOCKED` | La key existe pero el managed service de Endpoints/API Gateway no está habilitado en el proyecto *consumidor* | `gcloud services list --enabled --project=<consumer> \| grep endpoints` | `gcloud services enable orders.endpoints.<proj>.cloud.goog --project=<consumer>` |
| `403` desde un backend de Cloud Run detrás de API Gateway | La service account del gateway no tiene `roles/run.invoker` | `gcloud run services get-iam-policy orders-svc --region=us-central1` | `gcloud run services add-iam-policy-binding orders-svc --member=serviceAccount:orders-gw@... --role=roles/run.invoker` |
| `JWT validation failed: Audience doesn't match` | `x-google-audiences` ≠ el claim `aud` que emite el IdP | `printf '%s' "$JWT" \| cut -d. -f2 \| base64 -d 2>/dev/null \| jq .aud` | Alinear el `x-google-audiences` de la spec con el audience del IdP y redesplegar la configuración |
| `401` intermitentes justo después de una rotación de claves del IdP | Caché de JWKS obsoleta en el proxy | Comparar el `kid` del header del JWT contra el JWKS en vivo | Solapar claves vieja/nueva en el JWKS durante al menos el TTL de la caché antes de retirar la vieja |
| `429` muy por debajo del límite documentado del plan | La `Quota` de Apigee cuenta por message processor porque `Distributed` está en false | Inspeccionar `Q-ProductQuota.xml` | Poner `<Distributed>true</Distributed>`; con `Synchronous=false`, aceptar un leve exceso en los límites de intervalo |
| `429` en Cloud Armor, no en la API | La regla de rate limit del borde es más estricta que el tier vendido | `gcloud compute security-policies describe api-edge-policy` | Subir el umbral de Cloud Armor por encima del burst del tier más alto; Armor es un piso volumétrico, no el límite del producto |
| `503` / `Backend unavailable` solo en Apigee | El `io.timeout.millis` del target es más corto que el p99 del backend | Correlacionar `target_response_time` contra `total_response_time` en analytics | Subir `io.timeout.millis`, o arreglar el camino lento del backend — no subirlo a ciegas |
| `502` con `upstream connect error` en ESPv2 | El contenedor de la aplicación no está escuchando en la dirección/puerto de `--backend` | `kubectl -n orders exec deploy/orders -c esp -- wget -qO- 127.0.0.1:9000/healthz` | Alinear la dirección de escucha de la app con `--backend` |
| El proxy de Apigee se despliega pero devuelve `404` para todas las rutas | El `<BasePath>` choca con otro proxy, o el host de la request no está en el env group | `gcloud alpha apigee envgroups describe external --organization=$ORG` | Hacer únicos los base paths por entorno; agregar el hostname al env group |
| Falla el handshake TLS contra `api.example.com` | El certificado administrado sigue en `PROVISIONING` (el DNS no apunta a la IP del LB) | `gcloud compute ssl-certificates describe api-cert --global --format="value(managed.status,managed.domainStatus)"` | Apuntar el registro A a la IP del LB y esperar; el estado debe llegar a `ACTIVE` |
| Analytics muestra muchas menos llamadas que el LB | Las requests terminan en Cloud Armor o en el LB antes de llegar al proxy | Comparar el request count del LB en Cloud Monitoring con el `message_count` de Apigee | Inspeccionar los logs de Cloud Armor buscando veredictos `deny` |

### 5.3 Sesiones de diagnóstico y trazado en vivo

La sesión de Debug (trace) de Apigee captura el camino completo de ejecución de políticas para una porción muestreada del tráfico:

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

Diagnóstico de ESPv2 en GKE:

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

Consulta de logs correlacionada a lo largo del borde:

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

`fault_source` es el campo más útil de esa tabla: `target` significa que es tu backend, `policy` significa que es la configuración de tu gateway. Dirige la página al equipo correcto de un solo vistazo.

### 5.4 Verificar las afirmaciones de *negocio*, no solo la plomería

Un dashboard en verde no prueba que la API esté entregando valor. Estas son las verificaciones que sí lo hacen:

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

Tres productos, tres lecturas distintas de la misma métrica. Que `payments-free` se throttlee fuerte es el embudo funcionando. Que `payments-silver` se throttlee siquiera un poco amerita una conversación — o el tier está mal dimensionado, o un cliente lo superó. Que `payments-gold` esté en cero confirma que el tier premium está genuinamente sin restricciones, que es lo que el cliente pagó.

### 5.5 Verificación de gobernanza

Un programa de APIs sin inventario se degrada hacia el mismo lío N×M del que se construyó para escapar. Hacé cumplir la descubribilidad:

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

## 6. Síntesis orientada al examen

Comprimido a lo que una pregunta de Cloud Digital Leader realmente evalúa:

| Si la pregunta menciona… | La respuesta buscada es… | Porque |
|---|---|---|
| "monetizar", "rate plans", "developer portal", "ecosistema de partners", "API products" | **Apigee** | Solo Apigee tiene products, rate plans, portales y monetización |
| "exponer un servicio de Cloud Run / Cloud Functions con una key y JWT, mínima operación" | **API Gateway** | Totalmente administrado, nativo de serverless, sin necesidad de una plataforma de políticas |
| "servicio gRPC en GKE", "ya corremos el proxy" | **Cloud Endpoints (ESPv2)** | Modelo de sidecar con transcoding gRPC |
| "desbloquear un mainframe / monolito legacy sin reescribirlo" | **Apigee como fachada** (strangler-fig) | La mediación y la traducción de protocolo preservan a los consumidores durante la migración |
| "DDoS, OWASP, allowlist de IPs, ataque volumétrico" | **Cloud Armor** delante del gateway | La quota de negocio ≠ defensa volumétrica |
| "catalogar y gobernar APIs de muchos equipos" | **API hub** (+ Apigee) | Capa de descubrimiento/gobernanza sobre el parque de APIs |
| "reducir el costo de integración entre sistemas internos" | **Reutilización guiada por APIs**, chargeback interno | Costo de integración cuadrático → lineal |
| "nueva fuente de ingresos a partir de datos/capacidades existentes" | **Productización de la API + rate plans** | La API es el producto |

**Cuatro frases que vale la pena memorizar literalmente:**

1. Una API convierte una capacidad interna en un producto reutilizable, medido y versionado que los consumidores adoptan de forma self-service.
2. Apigee gestiona el *ciclo de vida y el comercio* de las APIs; API Gateway y Cloud Endpoints las *sirven*.
3. El mismo mecanismo de quota que protege el backend es el mecanismo que empaqueta y pone precio a la oferta.
4. Una fachada de API desacopla el contrato del consumidor de la implementación del backend, que es lo que hace posible la modernización incremental en primer lugar.

---

## 7. Referencias

**Guía del examen**
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

**Plataforma de soporte**
- Cloud Armor security policies — https://cloud.google.com/armor/docs/security-policy-overview
- Cloud Armor rate limiting — https://cloud.google.com/armor/docs/rate-limiting-overview
- External Application Load Balancer overview — https://cloud.google.com/load-balancing/docs/https
- Private Service Connect — https://cloud.google.com/vpc/docs/private-service-connect
- Service-level objectives in Cloud Monitoring — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- API design guide (Google AIP) — https://cloud.google.com/apis/design
- API Improvement Proposals — https://google.aip.dev/
- Terraform Google provider, Apigee resources — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/apigee_organization

**Estándares**
- OpenAPI Specification 2.0 (Swagger) — https://spec.openapis.org/oas/v2.0
- RFC 9457 — Problem Details for HTTP APIs — https://www.rfc-editor.org/rfc/rfc9457
- RFC 6749 — The OAuth 2.0 Authorization Framework — https://www.rfc-editor.org/rfc/rfc6749
- RFC 7519 — JSON Web Token (JWT) — https://www.rfc-editor.org/rfc/rfc7519
- RFC 6585 §4 — 429 Too Many Requests — https://www.rfc-editor.org/rfc/rfc6585#section-4