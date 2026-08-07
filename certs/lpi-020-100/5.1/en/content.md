# Production-Grade Study Material: LPI Security Essentials (Exam 020-100, Version 1.0)
## Topic 020.1 / Topic 5.1: Identity and Privacy
**Weight:** 20 | **Target Role:** Senior SRE / Principal Platform Architect

---

## 1. Production Motivation and Architectural Problem

In enterprise cloud-native environments, identity infrastructure forms the core security boundary of modern systems. Legacy perimeter-based security model—which relies on network boundaries (VPCs, firewalls, and internal IPs)—crumbles under dynamic containerized environments, multi-region Kubernetes clusters, edge deployments, and remote workforces. Modern architecture mandates a **Zero Trust Architecture (ZTA)** grounded in **NIST SP 800-207**, where explicit identity verification, least-privilege authorization, and cryptographic session management are enforced for every request, whether initiated by a user or a service worker.

### The Architectural Problem: Identity Fragmentation & Privacy Enforcement

Enterprise architectures frequently suffer from three main systemic identity vulnerabilities:

1. **Identity Fragmentation & AAA Breakdown:**
   Deploying disparate user repositories across legacy LDAP servers, cloud-native IdPs (Okta, Keycloak, Auth0), and local application databases creates fragmented Authentication, Authorization, and Accounting (AAA). This leads to orphan accounts, inconsistent multi-factor authentication (MFA) enforcement, silent privilege escalation, and log gaps during compliance audits.
2. **Session Security & Token Mismanagement:**
   Applications often struggle to balance stateless scale with rapid revocation. Cryptographically signed tokens (e.g., JSON Web Tokens - JWTs) offload database validation lookups from microservices, but introduce vulnerability windows if asymmetric keys are compromised, algorithm fallback vulnerabilities (`alg: "none"`) occur, or short lived refresh tokens are insecurely stored in browser local storage (`localStorage`) instead of `HttpOnly`, `SameSite=Strict`, `Secure` cookies.
3. **PII Spill and Privacy Compliance Violations:**
   Regulatory frameworks (GDPR, CCPA, HIPAA) enforce strict data minimization, right-to-be-forgotten, and data-at-rest cryptographic protections. Microservice architectures frequently expose Personally Identifiable Information (PII)—such as social security numbers, emails, and IP addresses—in application logs, distributed tracing systems (OpenTelemetry), and unencrypted cache layers (Redis/Memcached).

### Production Architecture Diagram: Enterprise Identity & Privacy Topology

```mermaid
flowchart TD
    subgraph External Client Boundary
        User[Browser / Mobile Client]
    end

    subgraph Edge Tier / Ingress
        Ingress[Envoy API Gateway / Ingress Controller]
        OAuthProxy[OAuth2-Proxy / ForwardAuth]
    end

    subgraph Centralized Identity Provider (IdP)
        Keycloak[Keycloak / Dex OIDC Core]
        JWKS[JWKS Endpoint /keys]
        DB[(IdP PostgreSQL State DB)]
    end

    subgraph Cryptographic Control Plane
        Vault[HashiCorp Vault / Transit KMS]
    end

    subgraph Application Service Mesh
        AuthFilter[Istio Envoy Filter / JWT Validator]
        MicroserviceA[Core API Microservice]
        Vector[Vector Log Collector / PII Scrubber]
        RedisCache[(Encrypted Redis Session Store)]
    end

    subgraph Log Aggregation & SIEM
        Elastic[Elasticsearch / OpenSearch Audit Trail]
    end

    User -->|1. Unauthenticated HTTP GET| Ingress
    Ingress -->|2. ForwardAuth Check| OAuthProxy
    OAuthProxy -->|3. Redirect 302 OIDC Auth Code| Keycloak
    Keycloak <-->|4. Validate Credentials & MFA| DB
    Keycloak -->|5. Issue ID/Access Token JWT + Refresh Cookie| User
    User -->|6. Authenticated Request + Bearer JWT| Ingress
    Ingress -->|7. Forward with Header| AuthFilter
    AuthFilter <-->|8. Fetch Public Keys / Cache JWKS| JWKS
    AuthFilter -->|9. Pass Verified Claims | MicroserviceA
    MicroserviceA <-->|10. Encrypt/Decrypt PII via Transit Engine| Vault
    MicroserviceA <-->|11. Validate Session State| RedisCache
    MicroserviceA -->|12. Stdout JSON Logs| Vector
    Vector -->|13. Regex Scrub PII -> Ship Audit Logs| Elastic
```

---

## 2. Technical Comparisons & Trade-off Tables

### Table 2.1: Federated Authentication & Directory Protocols

| Protocol / Standard | Primary Transport Layer | Token / Payload Format | Cryptography / Signing Mechanism | Revocation Real-Time Capability | Primary Production Use Case | SRE Operational Overhead |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **OpenID Connect (OIDC)** | HTTPS / REST (JSON) | JSON Web Token (JWT / JWS / JWE) | Asymmetric (RSA-256/384/512, ECDSA P-256, Ed25519) | Low to Medium (Short TTLs + Revocation List or Back-Channel Logout) | Modern Web, Mobile, API Gateway, Kubernetes OIDC SSO | Low (Standardized JSON endpoints, public JWKS caching) |
| **SAML 2.0** | HTTP POST / Redirect (XML) | XML Assertion | XML Digital Signature (XMLDSig) / X.509 Certificate | Low (Relies on short validity windows or SLO binding) | Enterprise B2B Federation, Legacy SaaS Integrations | High (XML parsing vulnerability surface, certificate rollover management) |
| **OAuth 2.0 (Framework)** | HTTPS / REST | Opaque Bearer / JWT | Protocol dependent (Bearer tokens, Mutual TLS / mTLS bound, DPoP) | High (For opaque tokens evaluated via Token Introspection RFC 7662) | Authorization / Delegation framework (Not natively an AuthN protocol) | Medium (Requires managing token scopes and introspection load) |
| **LDAP / LDAPS** | TCP 389 / TCP 636 (TLS) | ASN.1 BER Encoded Data | TLS Transport Encryption / SASL Digest | Immediate (Direct Directory Query on Bind) | Internal Enterprise Identity Directories, Legacy Infrastructure (PAM/NSS) | High (Requires dedicated directory replication topologies, schema management) |

### Table 2.2: Session State Architectures (Stateless JWT vs. Stateful Server-Side Sessions)

| Technical Dimension | Cryptographically Signed JWT (Stateless) | Opaque Tokens with Centralized Store (Stateful) | Hybrid (Short-Lived JWT + Refresh Token Rotation) |
| :--- | :--- | :--- | :--- |
| **Scalability Pattern** | Horizontal ($O(1)$ verification via in-memory public key) | Constrained by storage layer throughput ($O(\text{DB IOPS})$) | High ($O(1)$ for data plane, centralized store for token refresh cycle) |
| **Revocation Latency** | Eventual (Bounded by token expiry duration, e.g., 5-15 mins) | Immediate (Instant eviction from Redis/Database) | Immediate on refresh; Eventual within Access Token TTL window |
| **Network Traffic Overhead** | High (Large HTTP Header overhead due to claims/signatures) | Low (Small 32-byte UUID or random string) | Medium (Compact access token + HTTP cookie for refresh token) |
| **Replay Attack Vulnerability** | High if token stolen before expiration (Requires JTI blacklisting) | Low (Server instantly invalidates token state upon threat detection) | Mitigated via Refresh Token Rotation and DPoP / mTLS sender-constraining |
| **Key Management Burden** | High (Requires JWKS key rotation pipelines and distribution) | Low (Symmetric secret storage in key-value store) | High (Requires both JWKS infrastructure and Redis cluster lifecycle) |

### Table 2.3: Data Privacy Cryptographic & Masking Patterns

| Mechanism | Technical Implementation | Reversibility | Searchability / Queryability | GDPR Compliance Impact | Performance Overhead |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **AES-256-GCM Encryption** | Authenticated Encryption with Associated Data (AEAD) | Reversible (With access to KMS Private/Symmetric Key) | Non-searchable without deterministic IV (Unrecommended for sensitive PII) | High (Data encrypted at rest meets regulatory mandate) | Low (Hardware accelerated via AES-NI CPU instructions) |
| **Format-Preserving Encryption (FPE)** | FF1 / FF3-1 algorithms (AES mode) | Reversible (With key and domain configuration) | Fully searchable (Matches input formatting rules, e.g., Credit Card numbers) | Medium to High (Preserves format while obscuring actual values) | Medium (Computationally heavier than standard AES) |
| **Cryptographic Tokenization** | Random Salted HMAC (SHA-256) or Vault Transit UUID | Reversible via centralized secure Token Vault lookup | Searchable via exact token match | High (Original PII isolated inside isolated secure vault) | Medium (Network round-trip to Tokenization Vault required) |
| **Dynamic Data Masking (DDM)** | Log ingestion regex / SQL Proxy transformation | Irreversible at point of display | Non-searchable | Critical for log compliance (Prevents leakage in SIEM/APM) | Extremely Low (In-memory stream string substitution) |

---

## 3. Complete YAML / Configuration Manifests & Infrastructure

### Manifest 3.1: Production Keycloak Realm Configuration (`realm-production-security.json`)
This complete JSON manifest defines an enterprise Keycloak Realm enforce mandatory OTP/MFA, strict password policies, Brute Force Protection, OIDC Client mappings, and RS256 token signature algorithms.

```json
{
  "id": "production-security-realm",
  "realm": "production-security-realm",
  "displayName": "Enterprise Production Security Realm",
  "enabled": true,
  "sslRequired": "all",
  "registrationAllowed": false,
  "registrationEmailAsUsername": false,
  "rememberMe": false,
  "verifyEmail": true,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": true,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,
  "permanentLockout": false,
  "maxFailureWaitSeconds": 900,
  "minimumQuickLoginWaitSeconds": 60,
  "waitIncrementSeconds": 60,
  "quickLoginCheckMilliSeconds": 1000,
  "maxDeltaTimeSeconds": 43200,
  "failureFactor": 5,
  "defaultSignatureAlgorithm": "RS256",
  "accessTokenLifespan": 300,
  "accessTokenLifespanForImplicitFlow": 900,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "offlineSessionIdleTimeout": 2592000,
  "accessCodeLifespan": 60,
  "accessCodeLifespanUserAction": 300,
  "accessCodeLifespanLogin": 1800,
  "actionTokenGeneratedByAdminLifespan": 43200,
  "actionTokenGeneratedByUserLifespan": 300,
  "passwordPolicy": "upperCase(1) and lowerCase(1) and specialChars(1) and digits(1) and length(14) and hashIterations(275000) and passwordHistory(5)",
  "otpPolicyType": "totp",
  "otpPolicyAlgorithm": "HmacSHA256",
  "otpPolicyInitialCounter": 0,
  "otpPolicyDigits": 6,
  "otpPolicyLookAheadWindow": 1,
  "otpPolicyPeriod": 30,
  "otpSupportedApplications": [
    "FreeOTP",
    "Google Authenticator"
  ],
  "components": {
    "org.keycloak.keys.KeyProvider": [
      {
        "id": "rsa-active-key-provider",
        "name": "rsa-generated",
        "providerId": "rsa-generated",
        "subComponents": {},
        "config": {
          "priority": [
            "100"
          ],
          "keySize": [
            "4096"
          ],
          "active": [
            "true"
          ],
          "enabled": [
            "true"
          ],
          "algorithm": [
            "RS256"
          ]
        }
      }
    ]
  },
  "clients": [
    {
      "clientId": "kubernetes-ingress-gateway",
      "name": "Kubernetes Edge Ingress OIDC Client",
      "description": "Production Gateway OIDC authentication client enforcing PKCE and Authorization Code Flow",
      "rootUrl": "https://api.production.internal",
      "baseUrl": "https://api.production.internal/",
      "surrogateAuthRequired": false,
      "enabled": true,
      "alwaysDisplayInConsole": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "s3cr3t-pr0ducti0n-0auth2-cli3nt-k3ycl04k-t0k3n",
      "redirectUris": [
        "https://api.production.internal/oauth2/callback"
      ],
      "webOrigins": [
        "https://api.production.internal"
      ],
      "notBefore": 0,
      "bearerOnly": false,
      "consentRequired": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": true,
      "publicClient": false,
      "frontchannelLogout": true,
      "protocol": "openid-connect",
      "attributes": {
        "oidc.cname.mfa.required": "true",
        "post.logout.redirect.uris": "https://api.production.internal/logout",
        "pkce.code.challenge.method": "S256",
        "use.refresh.tokens": "true",
        "tls.client.certificate.bound.access.tokens": "true"
      },
      "defaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email"
      ]
    }
  ]
}
```

---

### Manifest 3.2: Kubernetes API Server OIDC & RBAC Architecture (`k8s-oidc-rbac.yaml`)
This Kubernetes manifest configures cluster authentication backed by an external OIDC Provider, including automated RoleBinding mapping OIDC groups to platform admin roles.

```yaml
apiVersion: config.k8s.io/v1
kind: KubeapiserverConfiguration
metadata:
  name: production-kube-apiserver-oidc
spec:
  extraArgs:
    oidc-issuer-url: "https://idp.production.internal/realms/production-security-realm"
    oidc-client-id: "kubernetes-cluster-prod-01"
    oidc-username-claim: "sub"
    oidc-username-prefix: "oidc:"
    oidc-groups-claim: "groups"
    oidc-groups-prefix: "oidc-group:"
    oidc-ca-file: "/etc/kubernetes/pki/idp-ca.crt"
    oidc-required-claim: "email_verified=true"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-security-auditor
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "configmaps", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["audit.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-security-team-audit-binding
subjects:
  - kind: Group
    name: "oidc-group:sec-ops-team"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-security-auditor
  apiGroup: rbac.authorization.k8s.io
```

---

### Manifest 3.3: HashiCorp Vault Transit Engine Encryption Policy & Engine Config (`vault-transit-privacy.hcl`)
This HashiCorp Vault HCL configuration declares a zero-trust policy permitting application workloads to perform cryptographic operations (Encrypt/Decrypt/Datakey) on PII fields without exposing the raw master encryption keys.

```hcl
# Vault HCL Policy: App PII Transit Encryption & Tokenization
path "transit/encrypt/pii-data-key" {
  capabilities = ["update"]
}

path "transit/decrypt/pii-data-key" {
  capabilities = ["update"]
}

path "transit/datakey/plaintext/pii-data-key" {
  capabilities = ["update"]
}

path "transit/rewrap/pii-data-key" {
  capabilities = ["update"]
}

# Restrict management of key lifecycle exclusively to security operations
path "transit/keys/pii-data-key" {
  capabilities = ["read"]
}

# Access rule for system health and key discovery
path "sys/internal/ui/mounts/transit" {
  capabilities = ["read"]
}
```

---

### Manifest 3.4: Vector Log Processor for In-Flight PII Redaction (`vector-pii-scrubber.yaml`)
This configuration deploys Vector as an SRE log stream pipeline that parses JSON application stdout logs and scrubs emails, SSNs, and credit cards using regular expressions before exporting to long-term audit storage.

```yaml
data_dir: "/var/lib/vector"

sources:
  kubernetes_stdout:
    type: "kubernetes_logs"
    include_units: []

transforms:
  parse_json_logs:
    type: "remap"
    inputs:
      - "kubernetes_stdout"
    source: |
      .structured = parse_json(.message) ignore_errors
      if is_null(.structured) {
        .structured.raw_message = .message
      }

  redact_pii_payloads:
    type: "remap"
    inputs:
      - "parse_json_logs"
    source: |
      # Redact Social Security Numbers (SSN: XXX-XX-XXXX)
      .message = replace_fields(.message, r'\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b', "[REDACTED-SSN]")
      
      # Redact Email Addresses
      .message = replace_fields(.message, r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', "[REDACTED-EMAIL]")
      
      # Redact Credit Card Numbers (Luhn regex pattern)
      .message = replace_fields(.message, r'\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13})\b', "[REDACTED-CARD]")
      
      # Inject compliance audit metadata tag
      .privacy_scrubbed = true
      .scrubbed_timestamp = now()

sinks:
  centralized_audit_elasticsearch:
    type: "elasticsearch"
    inputs:
      - "redact_pii_payloads"
    endpoints:
      - "https://elasticsearch-audit.production.internal:9200"
    mode: "bulk"
    bulk:
      index: "audit-logs-%Y.%m.%d"
    auth:
      strategy: "basic"
      user: "vector-log-writer"
      password: "SuperSecureVectorServicePassword2026!"
    tls:
      ca_file: "/etc/vector/certs/ca.crt"
      verify_certificate: true
```

---

## 4. Real CLI Commands and Terminal Outputs ($)

### Scenario 4.1: Inspecting & Validating an OIDC IdP Discovery Document
SREs must verify the cryptographic discovery endpoints of an identity provider before registering cluster configurations.

```bash
$ curl -s -X GET "https://idp.production.internal/realms/production-security-realm/.well-known/openid-configuration" | jq '.'
```
```json
{
  "issuer": "https://idp.production.internal/realms/production-security-realm",
  "authorization_endpoint": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/auth",
  "token_endpoint": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/token",
  "introspection_endpoint": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/token/introspect",
  "userinfo_endpoint": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/userinfo",
  "end_session_endpoint": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/logout",
  "jwks_uri": "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/certs",
  "grant_types_supported": [
    "authorization_code",
    "implicit",
    "refresh_token",
    "client_credentials"
  ],
  "response_types_supported": [
    "code",
    "none",
    "id_token",
    "token",
    "id_token token",
    "code id_token"
  ],
  "subject_types_supported": [
    "public",
    "pairwise"
  ],
  "id_token_signing_alg_values_supported": [
    "PS256",
    "ES256",
    "RS256"
  ],
  "code_challenge_methods_supported": [
    "S256"
  ]
}
```

---

### Scenario 4.2: Programmatic OIDC Token Acquisition via OAuth2 Client Credentials Flow
Requesting a service access token and inspecting its cryptographically signed JSON Web Token (JWT) structure.

```bash
$ RESPONSE=$(curl -s -X POST "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=kubernetes-ingress-gateway" \
  -d "client_secret=s3cr3t-pr0ducti0n-0auth2-cli3nt-k3ycl04k-t0k3n")

$ echo $RESPONSE | jq '.'
```
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InJzYS1hY3RpdmUta2V5LXByb3ZpZGVyIn0.eyJleHAiOjE3ODgzNDAxMjUsImlhdCI6MTc4ODMzOTgyNSwianRpIjoiYTg5ZjMyMTEtOTRjNS00ZWQ5LTkwMTItZGM4ZjNmYTEyMDkwIiwiaXNzIjoiaHR0cHM6Ly9pZHAucHJvZHVjdGlvbi5pbnRlcm5hbC9yZWFsbXMvcHJvZHVjdGlvbi1zZWN1cml0eS1yZWFsbSIsImF1ZCI6ImFjY291bnQiLCJzdWIiOiJiNWY0MzEyOC00OGE2LTRkYjEtYWIzYS0wMGM5ODc2NTRjMzIxIiwidHlwIjoiQmVhcmVyIiwiYXpwIjoia3ViZXJuZXRlcy1pbmdyZXNzLWdhdGV3YXkiLCJzY29wZSI6ImVtYWlsIHByb2ZpbGUiLCJncm91cHMiOlsic2VjLW9wcy10ZWFtIiwicGxhdGZvcm0tYWRtaW5zIl0sImVtYWlsX3ZlcmlmaWVkIjp0cnVlfQ.aBcDeFgHiJkLmNoPqRsTuVwXyZ...",
  "expires_in": 300,
  "refresh_expires_in": 1800,
  "token_type": "Bearer",
  "not-before-policy": 0,
  "scope": "email profile"
}
```

---

### Scenario 4.3: Manual JWT Claims Verification & Base64 Decoding via Terminal
Parsing header and body payloads of the returned JWT token to audit claims.

```bash
$ ACCESS_TOKEN=$(echo $RESPONSE | jq -r '.access_token')

# Extract and Decode JWT Header
$ echo $ACCESS_TOKEN | cut -d'.' -f1 | base64 -d 2>/dev/null | jq '.'
```
```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "rsa-active-key-provider"
}
```

```bash
# Extract and Decode JWT Payload Claims
$ echo $ACCESS_TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.'
```
```json
{
  "exp": 1788340125,
  "iat": 1788339825,
  "jti": "a89f3211-94c5-4ed9-9012-dc8f3fa12090",
  "iss": "https://idp.production.internal/realms/production-security-realm",
  "aud": "account",
  "sub": "b5f43128-48a6-4db1-ab3a-00c987654c321",
  "typ": "Bearer",
  "azp": "kubernetes-ingress-gateway",
  "scope": "email profile",
  "groups": [
    "sec-ops-team",
    "platform-admins"
  ],
  "email_verified": true
}
```

---

### Scenario 4.4: Envelope Encryption of Sensitive PII using HashiCorp Vault Transit API
Executing field-level encryption on a sensitive user email (`user.john.doe@production.internal`) using HashiCorp Vault Transit KMS.

```bash
$ export VAULT_ADDR="https://vault.production.internal:8200"
$ export VAULT_TOKEN="hvs.CAESIBw5R-ProductionVaultTokenForPIIEncryption"

# Convert plaintext PII to Base64
$ PLAINTEXT_PII=$(echo -n "user.john.doe@production.internal" | base64)

# Execute Transit Engine Encryption Call
$ curl -s --request POST \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --data "{\"plaintext\": \"$PLAINTEXT_PII\"}" \
  "$VAULT_ADDR/v1/transit/encrypt/pii-data-key" | jq '.'
```
```json
{
  "request_id": "8f3b210a-3c41-987a-1122-aaee98765432",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": {
    "ciphertext": "vault:v1:89Fba+qZ9wL0kM2xYzOP1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ=="
  },
  "wrap_info": null,
  "warnings": null,
  "auth": null
}
```

---

### Scenario 4.5: Reversing PII Ciphertext back to Plaintext via Vault API
Decrypting ciphertext using the authorized Vault service token.

```bash
$ CIPHERTEXT="vault:v1:89Fba+qZ9wL0kM2xYzOP1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ=="

$ DECRYPT_RESPONSE=$(curl -s --request POST \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --data "{\"ciphertext\": \"$CIPHERTEXT\"}" \
  "$VAULT_ADDR/v1/transit/decrypt/pii-data-key")

$ RAW_B64=$(echo $DECRYPT_RESPONSE | jq -r '.data.plaintext')
$ echo $RAW_B64 | base64 -d
```
```text
user.john.doe@production.internal
```

---

## 5. Verification and Fault Diagnostic Guide

### Troubleshooting Decision Tree

```mermaid
flowchart TD
    Start[Identity / Privacy Failure Incident] --> Severity{Failure Domain?}
    
    Severity -->|401 / 403 HTTP Error| TokenIssue[Token & AuthN Troubleshooting]
    Severity -->|Unscrubbed PII in Logs| PrivacyIssue[Data Leak Troubleshooting]
    Severity -->|Slow Auth Latency| PerfIssue[Performance / JWKS Troubleshooting]

    TokenIssue --> CheckExpiry{JWT Expired? exp < now}
    CheckExpiry -->|Yes| Fix1[Issue Refresh Token / Align System NTP Time]
    CheckExpiry -->|No| CheckSignature{JWKS Key ID kid Match?}
    
    CheckSignature -->|No| Fix2[Force Refresh Cached JWKS Public Key Set]
    CheckSignature -->|Yes| Fix3[Verify OAuth Scopes / Group Claim RBAC Mappings]

    PrivacyIssue --> CheckVector[Verify Vector/Fluentbit Remap Transform]
    CheckVector --> Fix4[Update Regular Expression & Restart Collector DaemonSet]

    PerfIssue --> CheckJWKSCache[Verify Remote JWKS HTTP Fetch Timeouts]
    CheckJWKSCache --> Fix5[Enable Local In-Memory JWKS Key Store Caching]
```

---

### Diagnostic Case 1: JWT Signature Verification Failure (`JWKS Key Mismatch`)

#### Symptom:
Microservices suddenly reject incoming valid user requests with `HTTP 401 Unauthorized`. Microservice logs emit:
`Error: Failed to verify JWT signature: Kid 'rsa-2026-05' not found in cached JWKS`.

#### Root Cause Analysis:
The Identity Provider completed an automated scheduled Key Rotation cycle, generating a new Key ID (`kid: rsa-2026-05`). Microservices and Envoy Proxies cached the previous JWKS endpoint response in memory without implementing a cache invalidation webhook or dynamic background refresh on unknown `kid` headers.

#### Step-by-Step Diagnostic & Resolution:

1. **Verify Current IdP Public Keys via JWKS Endpoint:**
   ```bash
   $ curl -s "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/certs" | jq '.keys[] | {kid, kty, alg, use}'
   ```
   *Expected Output:*
   ```json
   {
     "kid": "rsa-2026-05",
     "kty": "RSA",
     "alg": "RS256",
     "use": "sig"
   }
   ```

2. **Verify Microservice Local JWKS Cache State:**
   Check the metrics endpoint of the API Gateway / Istio Envoy Proxy:
   ```bash
   $ curl -s "http://localhost:15000/stats" | grep "jwks"
   ```
   *Output showing stale cache:*
   ```text
   envoy.http.jwt_authn.jwks_fetch_failed: 412
   envoy.http.jwt_authn.jwks_cache_miss: 1542
   ```

3. **Remediation Action:**
   Issue a config reload signal or trigger an administrative cache eviction to fetch the fresh JWKS payload without taking down pods:
   ```bash
   # Send flush signal to local Envoy API sidecar
   $ curl -s -X POST "http://127.0.0.1:15000/logging?jwt=debug"
   $ kubectl rollout restart deployment/api-gateway-service -n production
   ```

---

### Diagnostic Case 2: Inadvertent PII Leakage in Elastic Centralized Audit Logs

#### Symptom:
A compliance audit scan flags un-redacted user email addresses and credit card tokens appearing in Elasticsearch logs under the `index: audit-logs-*`.

#### Root Cause Analysis:
Application developers deployed a new payment gateway microservice that logged raw payload structs (`log.Infof("Processing order: %+v", orderPayload)`) instead of sanitized string fields. The downstream log parser lacked regex rules matching new RFC-compliant nested email subdomains.

#### Step-by-Step Diagnostic & Resolution:

1. **Query Log Aggregator for Active Leaks:**
   ```bash
   $ curl -s -X POST "https://elasticsearch-audit.production.internal:9200/audit-logs-*/_search" \
     -H "Content-Type: application/json" \
     -u "vector-log-writer:SuperSecureVectorServicePassword2026!" \
     -d '{
       "query": {
         "regexp": {
           "message": ".*[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}.*"
         }
       }
     }' | jq '.hits.total'
   ```
   *Output:*
   ```json
   {
     "value": 1420,
     "relation": "eq"
   }
   ```

2. **Isolate Leaking Pod and Stream Output:**
   ```bash
   $ kubectl logs -n production -l app=payment-service --tail=50 | grep -E "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+"
   ```

3. **Remediation Action (Hotfix Vector Config & Delete Compromised Index Documents):**
   - Apply Manifest 3.4 (`vector-pii-scrubber.yaml`) to enforce strict stream scrubbing.
   - Execute an in-place Elasticsearch `update_by_query` task to purge sensitive fields:
   ```bash
   $ curl -s -X POST "https://elasticsearch-audit.production.internal:9200/audit-logs-*/_update_by_query" \
     -H "Content-Type: application/json" \
     -u "admin:AdminVaultPass2026!" \
     -d '{
       "script": {
         "source": "ctx._source.message = ctx._source.message.replaceAll(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2}/, \"[PURGED-REDACTED-EMAIL]\")",
         "lang": "painless"
       },
       "query": {
         "term": {
           "privacy_scrubbed": false
         }
       }
     }'
   ```

---

## 6. References

* **Linux Professional Institute (LPI) Security Essentials 020-100 Official Overview:**  
  [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
* **NIST Special Publication 800-63B: Digital Identity Guidelines (Authentication and Lifecycle Management):**  
  [https://pages.nist.gov/800-63-3/sp800-63b.html](https://pages.nist.gov/800-63-3/sp800-63b.html)
* **RFC 6749: The OAuth 2.0 Authorization Framework:**  
  [https://datatracker.ietf.org/doc/html/rfc6749](https://datatracker.ietf.org/doc/html/rfc6749)
* **RFC 7519: JSON Web Token (JWT) Specification:**  
  [https://datatracker.ietf.org/doc/html/rfc7519](https://datatracker.ietf.org/doc/html/rfc7519)
* **RFC 7662: OAuth 2.0 Token Introspection:**  
  [https://datatracker.ietf.org/doc/html/rfc7662](https://datatracker.ietf.org/doc/html/rfc7662)
* **OpenID Connect Core 1.0 Specification:**  
  [https://openid.net/specs/openid-connect-core-1_0.html](https://openid.net/specs/openid-connect-core-1_0.html)
* **NIST Special Publication 800-207: Zero Trust Architecture:**  
  [https://csrc.nist.gov/publications/detail/sp/800-207/final](https://csrc.nist.gov/publications/detail/sp/800-207/final)