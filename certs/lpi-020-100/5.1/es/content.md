# Material de Estudio de Nivel de Producción: LPI Security Essentials (Examen 020-100, Versión 1.0)
## Tema 020.1 / Tema 5.1: Identidad y Privacidad
**Peso:** 20 | **Rol Objetivo:** Senior SRE / Principal Platform Architect

---

## 1. Motivación de Producción y Problema Arquitectónico

En entornos cloud-native empresariales, la infraestructura de identidad constituye el límite de seguridad central de los sistemas modernos. El modelo de seguridad tradicional basado en perímetro—que se apoya en límites de red (VPCs, firewalls e IPs internas)—se desmorona ante entornos contenedorizados dinámicos, clusters de Kubernetes multi-región, despliegues en el edge y fuerzas de trabajo remotas. La arquitectura moderna exige una **Zero Trust Architecture (ZTA)** fundamentada en **NIST SP 800-207**, donde la verificación explícita de identidad, la autorización de menor privilegio y la gestión criptográfica de sesiones se aplican para cada solicitud, ya sea iniciada por un usuario o por un service worker.

### El Problema Arquitectónico: Fragmentación de Identidad y Aplicación de Privacidad

Las arquitecturas empresariales frecuentemente sufren de tres vulnerabilidades sistémicas principales de identidad:

1. **Fragmentación de Identidad y Colapso de AAA:**
   Desplegar repositorios de usuarios dispares a través de servidores LDAP heredados, IdPs cloud-native (Okta, Keycloak, Auth0) y bases de datos locales de aplicaciones crea una Autenticación, Autorización y Contabilidad (Authentication, Authorization, and Accounting - AAA) fragmentada. Esto genera cuentas huérfanas, aplicación inconsistente de autenticación de múltiples factores (MFA), escalación silenciosa de privilegios y vacíos de logs durante auditorías de cumplimiento.
2. **Seguridad de Sesión y Mala Gestión de Tokens:**
   Las aplicaciones a menudo luchan por equilibrar la escala stateless con la revocación rápida. Los tokens firmados criptográficamente (por ejemplo, JSON Web Tokens - JWTs) liberan a los microservicios de las búsquedas de validación en la base de datos, pero introducen ventanas de vulnerabilidad si las claves asimétricas se comprometen, ocurren vulnerabilidades de fallback de algoritmo (`alg: "none"`), o los refresh tokens de corta duración se almacenan de forma insegura en el almacenamiento local del navegador (`localStorage`) en lugar de cookies `HttpOnly`, `SameSite=Strict`, `Secure`.
3. **Fuga de PII y Violaciones de Cumplimiento de Privacidad:**
   Los marcos regulatorios (GDPR, CCPA, HIPAA) exigen una estricta minimización de datos, derecho al olvido y protecciones criptográficas de datos en reposo (data-at-rest). Las arquitecturas de microservicios con frecuencia exponen Información de Identificación Personal (Personally Identifiable Information - PII)—como números de seguro social, correos electrónicos y direcciones IP—en logs de aplicaciones, sistemas de rastreo distribuido (OpenTelemetry) y capas de caché no encriptadas (Redis/Memcached).

### Diagrama de Arquitectura de Producción: Topología de Identidad y Privacidad Empresarial

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

## 2. Comparativas Técnicas y Tablas de Trade-offs

### Tabla 2.1: Protocolos de Directorio y Autenticación Federada

| Protocolo / Estándar | Capa Primaria de Transporte | Formato de Token / Payload | Mecanismo de Criptografía / Firma | Capacidad de Revocación en Tiempo Real | Caso de Uso Principal en Producción | Overhead Operativo de SRE |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **OpenID Connect (OIDC)** | HTTPS / REST (JSON) | JSON Web Token (JWT / JWS / JWE) | Asimétrica (RSA-256/384/512, ECDSA P-256, Ed25519) | Baja a Media (TTLs cortos + Lista de Revocación o Back-Channel Logout) | Web moderna, Móvil, API Gateway, Kubernetes OIDC SSO | Bajo (Endpoints JSON estandarizados, almacenamiento en caché de JWKS público) |
| **SAML 2.0** | HTTP POST / Redirect (XML) | Aserción XML | Firma Digital XML (XMLDSig) / Certificado X.509 | Baja (Se apoya en ventanas de validez cortas o vinculación SLO) | Federación B2B Empresarial, Integraciones SaaS Heredadas | Alto (Superficie de vulnerabilidad en parsing XML, gestión de rotación de certificados) |
| **OAuth 2.0 (Framework)** | HTTPS / REST | Bearer Opaco / JWT | Dependiente del protocolo (Tokens Bearer, Mutual TLS / mTLS bound, DPoP) | Alta (Para tokens opacos evaluados mediante Token Introspection RFC 7662) | Marco de Autorización / Delegación (No es nativamente un protocolo de AuthN) | Medio (Requiere gestionar scopes de tokens y carga de introspección) |
| **LDAP / LDAPS** | TCP 389 / TCP 636 (TLS) | Datos Codificados ASN.1 BER | Cifrado de Transporte TLS / SASL Digest | Inmediata (Consulta directa al directorio en Bind) | Directorios de Identidad Empresariales Internos, Infraestructura Heredada (PAM/NSS) | Alto (Requiere topologías dedicadas de replicación de directorios, gestión de esquema) |

### Tabla 2.2: Arquitecturas de Estado de Sesión (JWT Stateless vs. Sesiones Stateful del Lado del Servidor)

| Dimensión Técnica | JWT Firmado Criptográficamente (Stateless) | Tokens Opacos con Almacén Centralizado (Stateful) | Híbrido (JWT de Corta Duración + Rotación de Refresh Token) |
| :--- | :--- | :--- | :--- |
| **Patrón de Escalabilidad** | Horizontal ($O(1)$ verificación mediante clave pública en memoria) | Limitado por el rendimiento de la capa de almacenamiento ($O(\text{DB IOPS})$) | Alto ($O(1)$ para el plano de datos, almacén centralizado para el ciclo de refresh de tokens) |
| **Latencia de Revocación** | Eventual (Acotada por la duración de expiración del token, ej. 5-15 mins) | Inmediata (Evicción instantánea desde Redis/Base de Datos) | Inmediata al refrescar; Eventual dentro de la ventana de TTL del Access Token |
| **Overhead de Tráfico de Red** | Alto (Gran overhead de HTTP Header debido a claims/firmas) | Bajo (UUID pequeño de 32 bytes o cadena aleatoria) | Medio (Access token compacto + HTTP cookie para refresh token) |
| **Vulnerabilidad a Ataques de Replay** | Alta si el token es robado antes de la expiración (Requiere lista negra de JTI) | Baja (El servidor invalida instantáneamente el estado del token al detectar una amenaza) | Mitigada mediante Rotación de Refresh Token y restricción de emisor DPoP / mTLS |
| **Carga de Gestión de Claves** | Alta (Requiere pipelines de rotación de claves JWKS y distribución) | Baja (Almacenamiento de secreto simétrico en almacén clave-valor) | Alta (Requiere tanto infraestructura JWKS como el ciclo de vida del cluster de Redis) |

### Tabla 2.3: Patrones Criptográficos y de Enmascaramiento para Privacidad de Datos

| Mecanismo | Implementación Técnica | Reversibilidad | Capacidad de Búsqueda / Consulta | Impacto en Cumplimiento GDPR | Overhead de Rendimiento |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Cifrado AES-256-GCM** | Cifrado Autenticado con Datos Asociados (AEAD) | Reversible (Con acceso a la Clave Simétrica/Privada del KMS) | No buscable sin IV determinista (No recomendado para PII sensible) | Alto (Los datos cifrados en reposo cumplen con el mandato regulatorio) | Bajo (Acelerado por hardware mediante instrucciones CPU AES-NI) |
| **Format-Preserving Encryption (FPE)** | Algoritmos FF1 / FF3-1 (modo AES) | Reversible (Con clave y configuración de dominio) | Totalmente buscable (Coincide con reglas de formato de entrada, ej. números de tarjetas de crédito) | Medio a Alto (Conserva el formato mientras oscurece los valores reales) | Medio (Computacionalmente más pesado que AES estándar) |
| **Tokenización Criptográfica** | HMAC Aleatorio con Salt (SHA-256) o Vault Transit UUID | Reversible mediante búsqueda centralizada en Vault seguro de Tokens | Buscable mediante coincidencia exacta de token | Alto (PII original aislada dentro de un vault seguro aislado) | Medio (Se requiere round-trip de red al Vault de Tokenización) |
| **Enmascaramiento Dinámico de Datos (DDM)** | Regex de ingesta de logs / Transformación de SQL Proxy | Irreversible en el punto de visualización | No buscable | Crítico para el cumplimiento de logs (Evita fugas en SIEM/APM) | Extremadamente Bajo (Sustitución de cadenas en flujo en memoria) |

---

## 3. Manifiestos de Configuración e Infraestructura YAML Completos

### Manifiesto 3.1: Configuración de Realm de Keycloak para Producción (`realm-production-security.json`)
Este manifiesto JSON completo define un Realm de Keycloak empresarial que aplica OTP/MFA obligatorio, políticas de contraseñas strictly, Brute Force Protection, mapeos de Clientes OIDC y algoritmos de firma de tokens RS256.

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

### Manifiesto 3.2: Arquitectura de OIDC y RBAC para API Server de Kubernetes (`k8s-oidc-rbac.yaml`)
Este manifiesto de Kubernetes configura la autenticación del cluster respaldada por un Proveedor OIDC externo, incluyendo un RoleBinding automatizado que mapea grupos OIDC a roles de administración de plataforma.

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

### Manifiesto 3.3: Configuración de Motor y Política de Cifrado HashiCorp Vault Transit (`vault-transit-privacy.hcl`)
Esta configuración HCL de HashiCorp Vault declara una política zero-trust que permite a las cargas de trabajo de aplicaciones realizar operaciones criptográficas (Encrypt/Decrypt/Datakey) sobre campos de PII sin exponer las claves maestras de cifrado en bruto.

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

### Manifiesto 3.4: Procesador de Logs Vector para Redacción de PII en Vuelo (`vector-pii-scrubber.yaml`)
Esta configuración despliega Vector como un pipeline de flujo de logs de SRE que parsea logs JSON en stdout de aplicaciones y limpia correos electrónicos, SSNs y tarjetas de crédito usando expresiones regulares antes de exportar al almacenamiento de auditoría a largo plazo.

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

## 4. Comandos CLI Reales y Salidas de Terminal ($)

### Escenario 4.1: Inspección y Validación de un Documento de Descubrimiento OIDC de IdP
Los SREs deben verificar los endpoints de descubrimiento criptográfico de un proveedor de identidad antes de registrar las configuraciones del cluster.

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

### Escenario 4.2: Adquisición Programática de Tokens OIDC mediante el Flujo OAuth2 Client Credentials
Solicitud de un access token de servicio e inspección de la estructura de su JSON Web Token (JWT) firmado criptográficamente.

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

### Escenario 4.3: Verificación Manual de Claims de JWT y Decodificación Base64 en Terminal
Parsing del header y los payloads del cuerpo del token JWT devuelto para auditar los claims.

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

### Escenario 4.4: Cifrado de Sobre (Envelope Encryption) de PII Sensible usando la API Transit de HashiCorp Vault
Ejecución de cifrado a nivel de campo sobre un correo electrónico de usuario sensible (`user.john.doe@production.internal`) usando HashiCorp Vault Transit KMS.

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

### Escenario 4.5: Reversión de Texto Cifrado de PII a Texto Plano mediante la API de Vault
Descifrado del texto cifrado utilizando el token de servicio autorizado de Vault.

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

## 5. Guía de Verificación y Diagnóstico de Fallas

### Árbol de Decisión para Resolución de Problemas

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

### Caso de Diagnóstico 1: Falla en la Verificación de Firma de JWT (`JWKS Key Mismatch`)

#### Síntoma:
Los microservicios rechazan repentinamente las solicitudes entrantes válidas de usuarios con `HTTP 401 Unauthorized`. Los logs de los microservicios emiten:
`Error: Failed to verify JWT signature: Kid 'rsa-2026-05' not found in cached JWKS`.

#### Análisis de Causa Raíz:
El Proveedor de Identidad completó un ciclo automático programado de Rotación de Claves (Key Rotation), generando un nuevo Key ID (`kid: rsa-2026-05`). Los microservicios y Envoy Proxies almacenaron en caché la respuesta previa del endpoint JWKS en memoria sin implementar un webhook de invalidación de caché o una actualización dinámica en segundo plano al encontrar encabezados `kid` desconocidos.

#### Diagnóstico y Resolución Paso a Paso:

1. **Verificar las Claves Públicas Actuales del IdP a través del Endpoint JWKS:**
   ```bash
   $ curl -s "https://idp.production.internal/realms/production-security-realm/protocol/openid-connect/certs" | jq '.keys[] | {kid, kty, alg, use}'
   ```
   *Salida Esperada:*
   ```json
   {
     "kid": "rsa-2026-05",
     "kty": "RSA",
     "alg": "RS256",
     "use": "sig"
   }
   ```

2. **Verificar el Estado de la Caché Local de JWKS del Microservicio:**
   Verificar el endpoint de métricas del API Gateway / Istio Envoy Proxy:
   ```bash
   $ curl -s "http://localhost:15000/stats" | grep "jwks"
   ```
   *Salida mostrando caché desactualizada:*
   ```text
   envoy.http.jwt_authn.jwks_fetch_failed: 412
   envoy.http.jwt_authn.jwks_cache_miss: 1542
   ```

3. **Acción de Remediación:**
   Emitir una señal de recarga de configuración o activar una evicción administrativa de caché para obtener el payload fresco de JWKS sin interrumpir los pods:
   ```bash
   # Send flush signal to local Envoy API sidecar
   $ curl -s -X POST "http://127.0.0.1:15000/logging?jwt=debug"
   $ kubectl rollout restart deployment/api-gateway-service -n production
   ```

---

### Caso de Diagnóstico 2: Fuga Inadvertida de PII en Logs Centralizados de Auditoría en Elastic

#### Síntoma:
Un escaneo de auditoría de cumplimiento señala direcciones de correo electrónico de usuarios y tokens de tarjetas de crédito sin redactar apareciendo en logs de Elasticsearch bajo el `index: audit-logs-*`.

#### Análisis de Causa Raíz:
Los desarrolladores de aplicaciones desplegaron un nuevo microservicio de pasarela de pagos que registraba en logs structs completos de payload (`log.Infof("Processing order: %+v", orderPayload)`) en lugar de campos de texto sanitizados. El parser de logs aguas abajo carecía de reglas regex que coincidieran con los nuevos subdominios de correo electrónico anidados conformes a RFC.

#### Diagnóstico y Resolución Paso a Paso:

1. **Consultar al Agregador de Logs sobre Fugas Activas:**
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
   *Salida:*
   ```json
   {
     "value": 1420,
     "relation": "eq"
   }
   ```

2. **Aislar el Pod con Fugas y Transmitir la Salida:**
   ```bash
   $ kubectl logs -n production -l app=payment-service --tail=50 | grep -E "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+"
   ```

3. **Acción de Remediación (Hotfix de Configuración de Vector y Eliminación de Documentos de Índice Comprometidos):**
   - Aplicar el Manifiesto 3.4 (`vector-pii-scrubber.yaml`) para forzar la redacción estricta en el flujo.
   - Ejecutar una tarea `update_by_query` in-situ en Elasticsearch para purgar los campos sensibles:
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

## 6. Referencias

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