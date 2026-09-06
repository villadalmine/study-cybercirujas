# 2.4 — Describe Azure identity, access, and security

> **Examen**: AZ-900 (versión del temario 2026-07-20) · **Dominio**: Describe Azure management and governance / Azure architecture and services · **Peso**: 9.62
> **Perfil del lector**: Platform Architect / SRE. El examen pregunta *qué* es cada control; este material además cubre *cómo se aplica en runtime*, *qué se rompe* y *cómo demostrás que funciona*.

---

## 1. El problema de producción

Considerá un parque realista: 1 tenant de Microsoft Entra, 6 suscripciones repartidas entre `prod`, `nonprod` y `sandbox`, ~180 ingenieros, 3 clústers AKS, ~40 pipelines de CI/CD, una docena de aplicaciones SaaS y un conjunto de organizaciones asociadas que necesitan acceso a un portal de diseño compartido.

Los modos de falla que este dominio existe para prevenir no son hipotéticos:

1. **Privilegio permanente.** Alguien otorgó `Owner` con alcance de suscripción al grupo del equipo de plataforma "temporalmente" durante una migración. Tres años después, 42 personas pueden borrar los recursos de la suscripción de producción, y nadie puede nombrarlas sin ejecutar una consulta.
2. **Secretos de larga vida en CI.** Un pipeline se autentica contra Azure con un client secret de service principal guardado en un variable group. El secreto vence a los 2 años, está copiado en otros tres pipelines y aparece en un log de build con `set -x`. Rotarlo exige un cambio coordinado entre equipos, así que nunca ocurre.
3. **La suposición del perímetro.** El modelo de seguridad es "estás dentro de la VPN, por lo tanto sos de confianza". Una credencial obtenida por phishing desde el portátil no gestionado de un contratista es indistinguible de una legítima, porque la única señal verificada es *usuario + contraseña*.
4. **Bypass del data plane.** Las storage accounts tienen `allowSharedKeyAccess = true`. Cada asignación de rol RBAC sobre la storage account es decorativa: cualquiera que tenga la clave de cuenta de 512 bits tiene acceso total a los datos, sin atribución posible en los logs.
5. **Sin línea base de postura.** Nadie puede responder "¿cuáles de nuestros 2.400 recursos incumplen nuestra propia línea base, y cuáles de esos son efectivamente alcanzables desde internet?" sin una auditoría manual de dos semanas.

La respuesta de Azure no es un producto. Es un **sistema en capas** en el que cooperan cuatro superficies de autorización distintas, y el error arquitectónico más común, con diferencia, es confundirlas:

| Superficie | Pregunta que responde | Punto de aplicación | Señal de falla |
|---|---|---|---|
| **Authentication** (Microsoft Entra ID) | *¿Quién sos, y con qué fuerza lo demostraste?* | Endpoint de tokens de Entra ID (`login.microsoftonline.com`) | Códigos de error `AADSTS*` |
| **Conditional Access** | *Dado quién/dónde/qué/cuán riesgoso, ¿debería emitirse este token siquiera — y con qué claims?* | Endpoint de tokens de Entra ID, post-autenticación | `AADSTS53003`, `AADSTS50076` |
| **Azure RBAC** | *¿Este principal tiene permitido realizar esta operación sobre este recurso?* | Azure Resource Manager (`management.azure.com`) y data planes conscientes de RBAC | HTTP 403 `AuthorizationFailed` |
| **Azure Policy** | *¿Se le permite al recurso existir con esta forma?* | ARM, en el momento de admisión de la petición | HTTP 403 `RequestDisallowedByPolicy` |

> **Modelo mental para llevarse al examen y a producción:** *Entra ID dice quién sos. Conditional Access dice bajo qué condiciones podés obtener un token. RBAC dice qué puede hacer esa identidad. Azure Policy dice qué forma puede tener el recurso. Defender for Cloud dice qué tan mal hiciste las cuatro cosas.*

---

## 2. Servicios de directorio

### 2.1 Los tres directorios, y por qué no son intercambiables

El malentendido de mayores consecuencias en este dominio es tratar a **Microsoft Entra ID** como "Active Directory en la nube". No lo es. Es un producto distinto que resuelve un problema distinto con protocolos distintos.

| Dimensión | **AD DS** (on-premises) | **Microsoft Entra ID** | **Microsoft Entra Domain Services** |
|---|---|---|---|
| Modelo de despliegue | Vos operás domain controllers (VMs/hardware) | PaaS multi-tenant, operado por Microsoft | Dominio gestionado, operado por Microsoft, inyectado en *tu* VNet |
| Propósito principal | Identidad de LAN empresarial para Windows | Identidad a escala de internet para apps y APIs | Lift-and-shift de apps legacy que necesitan Kerberos/LDAP pero no DCs |
| Estructura | Jerárquica: forest → domain → OU | **Plana**: sin OUs, sin forests, sin dominios en el sentido de AD | Jerárquica (un único dominio gestionado, se permiten OUs propias) |
| Protocolos de auth | Kerberos, NTLM, LDAP | **OAuth 2.0, OpenID Connect, SAML 2.0, WS-Federation, SCIM** | Kerberos, NTLM, LDAP, LDAPS |
| Interfaz de consulta | LDAP | **Microsoft Graph (REST)** | LDAP |
| Group Policy (GPO) | Sí, completo | **No** | Sí (GPOs integradas, editables) |
| Domain join | Sí | **No** — "Entra joined" es un registro cloud distinto | Sí |
| Extensión de esquema | Sí | No (solo directory extensions / custom security attributes) | **No** |
| Trusts | Forest trusts bidireccionales | N/A (usa B2B / cross-tenant access en su lugar) | Forest trust unidireccional saliente hacia on-prem (SKU Enterprise+) |
| ¿Obtenés `Domain Admin`? | Sí | N/A | **No** — obtenés `AAD DC Administrators`, un grupo delegado |
| Dirección de sincronización | — | ← Entra Connect / Cloud Sync desde AD DS | **Unidireccional de Entra ID → dominio gestionado**; las escrituras no vuelven |
| Driver de costo típico | VMs de DC + licenciamiento | Nivel de licencia por usuario | SKU por hora según cantidad de objetos |

**Regla de decisión arquitectónica:**

- La aplicación habla OIDC/SAML/Graph → **Entra ID**. Nada más.
- La aplicación exige Kerberos/LDAP sí o sí y te negás a correr DCs en Azure → **Entra Domain Services**.
- Necesitás extensiones de esquema, trusts bidireccionales o `Domain Admin` → **AD DS sobre VMs IaaS**. Domain Services no lo va a hacer, y descubrirlo después de la migración sale caro.

**Trampa híbrida (relevante para el examen):** el password writeback (que el self-service password reset escriba de vuelta al AD on-premises) requiere **Entra ID P1**, y la sincronización de Entra ID hacia Entra Domain Services es **unidireccional**. Un reseteo de contraseña hecho directamente dentro del dominio gestionado no es visible para Entra ID; los usuarios deben cambiar contraseñas a través de Entra ID (o del AD on-premises, que luego sincroniza) para que el dominio gestionado reciba el hash.

### 2.2 La topología tenant / subscription / management group

```
Microsoft Entra tenant  (the identity boundary — users, groups, SPs, app registrations)
│
└── Root management group  (id == tenant id)
    ├── mg-platform
    │   └── sub-connectivity, sub-identity, sub-management
    ├── mg-landingzones
    │   ├── mg-corp   → sub-prod-eu, sub-prod-us
    │   └── mg-online → sub-public-api
    └── mg-sandbox
        └── sub-sandbox-*
```

Hechos que se evalúan y que además importan operativamente:

- Una **suscripción confía en exactamente un tenant** a la vez, y una suscripción tiene **exactamente un management group padre**.
- La jerarquía de management groups admite **6 niveles** (root + 5). Las asignaciones de rol y de política **se heredan hacia abajo** y son **aditivas**.
- El tenant es el **límite de seguridad para la identidad**; la suscripción es el **límite de facturación y, por convención, de radio de impacto** para los recursos.
- Mover una suscripción entre tenants (`az account tenant`… no existe — es una operación de portal/soporte) **deja huérfana cada asignación de Azure RBAC**, porque los object IDs de los principals viven en el tenant viejo. Planificá una tanda de reasignación.

### 2.3 Niveles de licenciamiento — qué es lo que realmente no podés hacer sin pagar

| Capacidad | Free | **P1** | **P2** | Entra ID Governance |
|---|:--:|:--:|:--:|:--:|
| SSO a SaaS y recursos de Azure | ✅ | ✅ | ✅ | ✅ |
| Security defaults (línea base de MFA para todo el tenant) | ✅ | ✅ | ✅ | ✅ |
| **Cambio** de contraseña autoservicio (usuarios cloud) | ✅ | ✅ | ✅ | ✅ |
| **Reseteo** de contraseña autoservicio + **writeback a AD DS** | ❌ | ✅ | ✅ | ✅ |
| **Conditional Access** | ❌ | ✅ | ✅ | ✅ |
| Grupos de membresía dinámica | ❌ | ✅ | ✅ | ✅ |
| Asignación de licencias basada en grupos | ❌ | ✅ | ✅ | ✅ |
| Microsoft Entra Application Proxy | ❌ | ✅ | ✅ | ✅ |
| Monitorización con Connect Health | ❌ | ✅ | ✅ | ✅ |
| **Identity Protection** (detección de riesgo, CA basada en riesgo) | ❌ | ❌ | ✅ | ✅ |
| **Privileged Identity Management (PIM)** — elevación de rol JIT | ❌ | ❌ | ✅ | ✅ |
| Access reviews | ❌ | ❌ | ✅ | ✅ |
| Entitlement management, lifecycle workflows | ❌ | ❌ | ❌ | ✅ |

> **Las dos líneas que deciden tu arquitectura:** *Conditional Access es P1.* *PIM y las políticas basadas en riesgo son P2.* Si el presupuesto se detiene en Free, tu único control a nivel de tenant son los **security defaults**, que son todo-o-nada y **mutuamente excluyentes con cualquier política de Conditional Access** — habilitar CA exige deshabilitar los security defaults, y viceversa.

### 2.4 El modelo de objetos

| Objeto | Qué es | Ciclo de vida | Credencial |
|---|---|---|---|
| **User** | Persona (member o guest) | Gestionado / sincronizado desde AD DS | Contraseña, FIDO2, Hello, certificado |
| **Group** | De seguridad o de Microsoft 365; asignado o dinámico | Manual o por regla | — |
| **App registration** | La *definición* de una aplicación, global a su tenant de origen | Propiedad del desarrollador | — |
| **Service principal** | La *instancia local* de una app en un tenant; lo que RBAC realmente apunta | Uno por tenant por app | Client secret, certificado, **federated credential** |
| **Managed identity** | Un service principal cuya credencial Azure crea, guarda y rota por vos | System-assigned: atada a un recurso. User-assigned: recurso independiente | **Ninguna que llegues a ver** |

**Managed identity system-assigned vs user-assigned:**

| | System-assigned | User-assigned |
|---|---|---|
| Cardinalidad | 1:1 con un recurso | N:M — muchos recursos comparten una identidad |
| Ciclo de vida | Se elimina con el recurso | Recurso ARM independiente |
| ¿Sobreviven las asignaciones de rol a la recreación del recurso? | **No** — `principalId` nuevo cada vez | **Sí** |
| Buena para | Una única VM, una única Function App | Despliegues blue/green, cargas de trabajo en AKS, flotas VMSS, cualquier cosa que IaC recree |

> **Regla de SRE:** si un `taint`/`replace` de Terraform destruiría y recrearía el recurso, usá una identidad **user-assigned**. Si no, cada redespliegue rompe silenciosamente la autorización y te pasás una hora con un 403.

### 2.5 CLI — inspeccionar el directorio

```console
$ az account show --output table
EnvironmentName    HomeTenantId                          IsDefault    Name                 State    TenantId
-----------------  ------------------------------------  -----------  -------------------  -------  ------------------------------------
AzureCloud         3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10  True         sub-prod-eu          Enabled  3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10

$ az ad signed-in-user show --query "{upn:userPrincipalName, id:id, type:userType}" -o json
{
  "id": "b7f2d9c4-1e88-4a52-9f3d-6c0a5b81e274",
  "type": "Member",
  "upn": "sre-lead@contoso.com"
}

$ az account management-group list --query "[].{name:name, display:displayName}" -o table
Name              Display
----------------  ----------------------
mg-platform       Platform
mg-landingzones   Landing Zones
mg-corp           Corp
mg-online         Online
mg-sandbox        Sandbox
```

Creá una managed identity user-assigned y leé de vuelta los dos IDs que importan:

```console
$ az identity create \
    --name id-workload-payments \
    --resource-group rg-identity-prod \
    --location westeurope \
    --query "{clientId:clientId, principalId:principalId, id:id}" -o json
{
  "clientId": "9d41a0b6-2c7f-4e3a-b915-8ad0f6c1e552",
  "id": "/subscriptions/3f9c1a7e-.../resourceGroups/rg-identity-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-workload-payments",
  "principalId": "e2a8b551-73cd-49f0-9b2a-1d47cf30ab99"
}
```

> `clientId` es lo que presenta la **aplicación** al pedir un token. `principalId` (el object ID del service principal) es lo que apuntan las **asignaciones de rol de RBAC**. Confundirlos produce una asignación de rol que referencia a un principal inexistente — que Azure va a aceptar sin quejarse y que nunca va a funcionar.

---

## 3. Métodos de autenticación

### 3.1 La mecánica del single sign-on

SSO no es "una contraseña en todos lados". Es **intermediación de tokens**: el usuario se autentica una vez contra Entra ID, recibe un *refresh token* de larga vida y un *access token* de corta vida, y cada aplicación posterior recibe un token nuevo, acotado y firmado sin un nuevo pedido de credencial.

```
Browser/CLI              Entra ID                       Resource (ARM, Graph, your API)
    │                       │                                    │
    │──1 authorize request─►│                                    │
    │  (client_id, scope,   │                                    │
    │   redirect_uri, PKCE) │                                    │
    │                       │──2 evaluate Conditional Access────►│ (internal)
    │◄─3 MFA / device / TAP─┤                                    │
    │──4 code──────────────►│                                    │
    │◄─5 access_token (~60–90 min), id_token, refresh_token (90d sliding)
    │                                                            │
    │──6 Authorization: Bearer <access_token>───────────────────►│
    │                                              7 validate sig, iss, aud, exp, scp/roles
```

Consecuencias que tenés que contemplar en el diseño:

- Un access token emitido es **válido hasta que expira**; revocar un usuario no mata instantáneamente las sesiones en vuelo. Eso es lo que arregla la **Continuous Access Evaluation (CAE)**: para recursos compatibles con CAE (Microsoft Graph, Exchange Online, SharePoint Online, Teams), Entra ID emite **tokens de larga vida (hasta ~28 h)** pero el recurso *se suscribe* a eventos críticos — cuenta deshabilitada, contraseña cambiada, token revocado, cambio de ubicación de red — y rechaza el token casi en tiempo real. CAE cambia vida del token por latencia de revocación, y es una mejora estricta.
- SSO concentra el riesgo. Ahora una sola credencial abre todo, que es precisamente por qué **MFA no es opcional en un parque con SSO** — es el control compensatorio que hace seguro al SSO.

### 3.2 Comparación de métodos de autenticación

El examen quiere "MFA = dos o más de *algo que sabés / tenés / sos*". Producción quiere **resistencia al phishing**, que es una propiedad más estricta: resistencia a un proxy adversary-in-the-middle en tiempo real (tipo Evilginx) que retransmite tanto la contraseña como el OTP.

| Método | Factores | Resistente a phishing | Fricción de UX | Carga operativa | Veredicto |
|---|---|:--:|---|---|---|
| Solo contraseña | sabés | ❌ | baja | baja | Inaceptable para cualquier ruta privilegiada |
| OTP por SMS / voz | sabés + tenés | ❌ (SIM swap, relay AiTM) | media | baja | Solo como fallback legacy; Microsoft lo desaconseja activamente |
| OATH TOTP por software | sabés + tenés | ❌ (retransmisible) | media | baja | Mejor que SMS, igual retransmisible |
| **Authenticator push + number matching** | sabés + tenés | ⚠️ parcial | baja | baja | Buen valor por defecto para el personal; el number matching mata los ataques de MFA fatigue |
| **Authenticator passwordless phone sign-in** | tenés + sabés/sos (desbloqueo del dispositivo) | ⚠️ parcial | **muy baja** | baja | Fuerte valor por defecto para el personal |
| **Windows Hello for Business** | tenés (ligado al TPM) + sabés/sos | ✅ | muy baja | media (aprovisionamiento de dispositivos) | Lo mejor para una flota Windows gestionada |
| **Llave de seguridad FIDO2 / passkey** | tenés + sabés/sos | ✅ | baja | media (distribución de llaves, manejo de pérdidas) | **Lo mejor para admins y break-glass** |
| **Certificate-Based Authentication (CBA)** | tenés (smartcard/PIV) | ✅ | media | alta (propiedad de la PKI) | Parques regulados / gubernamentales |
| **Temporary Access Pass (TAP)** | tenés (código acotado en el tiempo) | ❌ por diseño | baja | baja | **Solo para bootstrapping**: onboarding, recuperación por pérdida de llave |

Las **authentication strengths** convierten esta tabla en un control aplicable. En lugar de otorgar "MFA" (cualquier segundo factor), una política de Conditional Access puede exigir la strength integrada **`Phishing-resistant MFA`**, que solo acepta Windows Hello for Business, FIDO2 y CBA. Es el control de identidad de mayor apalancamiento disponible, y es lo que aplicás a los Global Administrators y al management plane de Azure.

### 3.3 CLI — enumerar métodos registrados e inspeccionar un token

```console
$ az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/users/sre-lead@contoso.com/authentication/methods" \
    --query "value[].{type:'@odata.type', id:id}" -o table
Type                                                              Id
----------------------------------------------------------------  ------------------------------------
#microsoft.graph.passwordAuthenticationMethod                     28c10230-6103-485e-b985-444c60001490
#microsoft.graph.fido2AuthenticationMethod                        c9f6bd7e-3a41-4f0d-8e21-9b7c5a2d6ef3
#microsoft.graph.microsoftAuthenticatorAuthenticationMethod        1a5b9d02-77cf-4d3e-a10b-e5c8f3971b4a
```

Decodificá el access token para ver *cómo* se autenticó la sesión — es la forma más rápida de probar o refutar "se aplicó MFA":

```console
$ az account get-access-token --resource https://management.azure.com --query accessToken -o tsv \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, iss, oid, upn, amr, acr, wids, scp, exp}'
{
  "aud": "https://management.azure.com",
  "iss": "https://sts.windows.net/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/",
  "oid": "b7f2d9c4-1e88-4a52-9f3d-6c0a5b81e274",
  "upn": "sre-lead@contoso.com",
  "amr": ["pwd", "mfa"],
  "acr": "1",
  "wids": ["b79fbf4d-3ef9-4689-8143-76b194e85509"],
  "scp": "user_impersonation",
  "exp": 1789432104
}
```

Cómo leer esta salida:

| Claim | Significado | Qué verificar |
|---|---|---|
| `amr` | Authentication Methods References | `"mfa"` presente ⇒ se satisfizo un segundo factor. `["pwd"]` solo ⇒ un único factor |
| `oid` | El object ID inmutable del principal | Esto — no `upn` — es lo que RBAC hace coincidir |
| `wids` | IDs de plantilla de **directory role** de Entra en el token | `b79fbf4d-…` es un ID conocido bien conocido; resolvelo, no lo adivines |
| `scp` / `roles` | Scopes delegados / permisos de aplicación | `scp` ⇒ actuando en nombre de un usuario; `roles` ⇒ solo app |
| `aud` | Audiencia prevista | Un token de Graph **no** va a funcionar contra ARM. Un `aud` desalineado está entre las 3 causas principales de 401 |

> **Nunca** pegues un access token de producción en un decodificador JWT online. Es una credencial bearer viva. Decodificalo localmente, como arriba.

---

## 4. Identidades externas

Bajo este encabezado viven cuatro productos distintos, y elegir mal significa reconstruir una pila de autenticación.

| | **B2B collaboration** | **B2B direct connect** | **Azure AD B2C** | **Microsoft Entra External ID** (tenant externo) |
|---|---|---|---|---|
| Audiencia | *Empleados* de partners | *Empleados* de partners, canales compartidos de Teams | Consumidores / ciudadanos (CIAM) | Consumidores *y* socios comerciales (CIAM, generación actual) |
| Objeto creado en tu tenant | **Guest user** (`UPN` = `partner_contoso.com#EXT#@yourtenant.onmicrosoft.com`) | **Ninguno** — no existe objeto guest | Usuario en un **tenant B2C separado** | Usuario en un **tenant externo separado** |
| Quién autentica al usuario | Su tenant **de origen** | Su tenant **de origen** | Tu tenant B2C | Tu tenant externo |
| Credencial gestionada por | El partner | El partner | Vos | Vos |
| Branding | El de tu tenant, limitado | N/A | Totalmente personalizable (user flows / custom policies / IEF) | Totalmente personalizable |
| IdPs sociales (Google, Facebook, Apple) | Limitado (Google, one-time passcode) | ❌ | ✅ | ✅ |
| Escala objetivo | Miles de partners | Miles | **Millones** | **Millones** |
| Aplica Conditional Access | ✅ (las políticas de tu tenant) | ✅ (cross-tenant access settings) | ✅ (específico de B2C) | ✅ |
| Licenciamiento | Basado en MAU, con nivel gratuito generoso | Incluido | Basado en MAU | Basado en MAU |
| Estado | Actual | Actual | **Soportado; los proyectos nuevos se dirigen a External ID** | **Dirección actual** |

### 4.1 Cross-tenant access settings — el control que hace seguro a B2B

El comportamiento por defecto de B2B es permisivo: cualquier invitado de cualquier tenant puede ser agregado. Los **cross-tenant access settings** te permiten restringir la colaboración entrante y saliente por tenant asociado y — algo crítico — **confiar en el claim de MFA del partner** para que los invitados no tengan que volver a registrar MFA en tu tenant.

```console
$ az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/default" \
    --query "{inbound:b2bCollaborationInbound.usersAndGroups.accessType, mfaTrust:inboundTrust.isMfaAccepted, compliantDeviceTrust:inboundTrust.isCompliantDeviceAccepted}" -o json
{
  "compliantDeviceTrust": false,
  "inbound": "allowed",
  "mfaTrust": false
}
```

Configurá una política específica de partner que confíe en sus claims de MFA y de dispositivo compatible:

```console
$ az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners" \
    --headers "Content-Type=application/json" \
    --body '{
      "tenantId": "8d21f4c9-6b07-4e5a-9c13-2f8e0a44b761",
      "inboundTrust": {
        "isMfaAccepted": true,
        "isCompliantDeviceAccepted": true,
        "isHybridAzureADJoinedDeviceAccepted": false
      },
      "b2bCollaborationInbound": {
        "usersAndGroups": { "accessType": "allowed",
          "targets": [{ "target": "c4f18a72-9e33-4b5d-8a07-ee2d61c9f048", "targetType": "group" }] },
        "applications": { "accessType": "allowed",
          "targets": [{ "target": "AllApplications", "targetType": "application" }] }
      }
    }'
```

> **Compromiso que hay que enunciar explícitamente:** confiar en el MFA de un partner elimina fricción y registro duplicado de MFA, pero transfiere la garantía a *su* higiene de identidad. Confiá en el MFA de tenants con los que tenés una postura de seguridad contractual; no confíes por defecto.

---

## 5. Microsoft Entra Conditional Access

### 5.1 El motor de evaluación

Conditional Access es un **motor de políticas si-entonces evaluado en el momento de emisión del token**. Es la implementación práctica de "verificar explícitamente".

```
        SIGNALS                    →   DECISION            →   SESSION CONTROLS
  ┌──────────────────────┐            ┌──────────────┐        ┌────────────────────────┐
  │ user / group / role  │            │ BLOCK        │        │ sign-in frequency      │
  │ target resource      │            │              │        │ persistent browser     │
  │ network / named loc  │  ──────►   │ GRANT with:  │  ────► │ app-enforced restrict. │
  │ device platform      │            │  • MFA       │        │ CA App Control (MDCA)  │
  │ device state         │            │  • auth      │        │ continuous access eval │
  │ client app type      │            │    strength  │        │ token protection       │
  │ sign-in risk  (P2)   │            │  • compliant │        └────────────────────────┘
  │ user risk     (P2)   │            │    device    │
  │ insider risk         │            │  • hybrid    │
  │ authentication flow  │            │    join      │
  └──────────────────────┘            │  • approved  │
                                      │    client    │
                                      │  • app prot. │
                                      │  • ToU       │
                                      └──────────────┘
```

Reglas del motor que se evalúan y que causan caídas:

1. **Se evalúan todas las políticas coincidentes. Cada una debe satisfacerse.** Los grant controls entre políticas se combinan efectivamente con `AND`; dentro de una política elegís `Require all` o `Require one`.
2. **Block gana.** Cualquier política que evalúe a Block termina la decisión sin importar ningún Grant.
3. **Las exclusiones vencen a las inclusiones.** Un usuario que está en un grupo incluido y en uno excluido queda **excluido**.
4. **CA corre después de la autenticación de primer factor.** La contraseña ya está validada cuando CA evalúa. CA no puede detener la *verificación* de la credencial; detiene la *emisión del token*.
5. **Los protocolos de autenticación legacy (POP3, IMAP, SMTP AUTH, Office antiguo) no pueden hacer MFA interactivo.** Hay que bloquearlos con una política dedicada dirigida a `Other clients`, si no son un bypass completo de MFA.

### 5.2 Conjunto de políticas de referencia

Una línea base de producción mínima viable son cuatro políticas, desplegadas primero en **report-only**:

| # | Nombre | Objetivo | Condición | Control |
|---|---|---|---|---|
| CA01 | Block legacy authentication | Todos los usuarios, excl. break-glass | Client app = *Exchange ActiveSync, Other clients* | **Block** |
| CA02 | Require MFA for all users | Todos los usuarios, excl. break-glass y cuentas de servicio | Todas las cloud apps | Grant: **MFA** |
| CA03 | Phishing-resistant MFA for admins | Directory roles: Global Admin, Privileged Role Admin, Security Admin, User Access Admin | Todas las cloud apps | Grant: **Authentication strength = Phishing-resistant MFA** |
| CA04 | Require compliant device for Azure management | Todos los usuarios, excl. break-glass | App = *Windows Azure Service Management API* | Grant: **MFA AND compliant device**; Session: sign-in frequency **4 h**, navegador no persistente |

### 5.3 Manifiesto completo de la política (JSON de Microsoft Graph — la representación canónica)

```json
{
  "displayName": "CA04 - Azure management requires phishing-resistant MFA and a compliant device",
  "state": "enabledForReportingButNotEnforced",
  "conditions": {
    "users": {
      "includeUsers": ["All"],
      "excludeUsers": [
        "a1c07f3e-9d24-4b6a-8f51-0e3b7d92ca68",
        "f6b3e850-2a19-4c7d-b4e2-91ad0c6f7315"
      ],
      "excludeGroups": ["7e29d4a1-5c60-4f83-9b12-3ad8e07c5f94"],
      "includeRoles": [],
      "excludeRoles": []
    },
    "applications": {
      "includeApplications": ["797f4846-ba00-4fd7-ba43-dac1f8f63013"],
      "excludeApplications": [],
      "includeUserActions": []
    },
    "clientAppTypes": ["all"],
    "platforms": {
      "includePlatforms": ["all"],
      "excludePlatforms": []
    },
    "locations": {
      "includeLocations": ["All"],
      "excludeLocations": ["AllTrusted"]
    },
    "signInRiskLevels": [],
    "userRiskLevels": []
  },
  "grantControls": {
    "operator": "AND",
    "builtInControls": ["compliantDevice"],
    "authenticationStrength": {
      "id": "00000000-0000-0000-0000-000000000004"
    },
    "customAuthenticationFactors": [],
    "termsOfUse": []
  },
  "sessionControls": {
    "signInFrequency": {
      "value": 4,
      "type": "hours",
      "authenticationType": "primaryAndSecondaryAuthentication",
      "frequencyInterval": "timeBased",
      "isEnabled": true
    },
    "persistentBrowser": {
      "mode": "never",
      "isEnabled": true
    },
    "continuousAccessEvaluation": {
      "mode": "strictLocation"
    }
  }
}
```

> `797f4846-ba00-4fd7-ba43-dac1f8f63013` es el application ID bien conocido de la **Windows Azure Service Management API** — el recurso detrás del portal de Azure, Azure CLI y Azure PowerShell. Apuntar a él es la forma de proteger específicamente el **control plane** sin tocar Microsoft 365.
> `00000000-0000-0000-0000-000000000004` es la política de authentication strength integrada **Phishing-resistant MFA**.

Creala y leela de vuelta:

```console
$ az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
    --headers "Content-Type=application/json" \
    --body @ca04-azure-management.json \
    --query "{id:id, state:state}" -o json
{
  "id": "5b0e9a41-72c8-4d16-bf39-c8a2e5407d61",
  "state": "enabledForReportingButNotEnforced"
}

$ az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
    --query "value[].{name:displayName, state:state}" -o table
Name                                                                    State
----------------------------------------------------------------------  ---------------------------------------
CA01 - Block legacy authentication                                      enabled
CA02 - Require MFA for all users                                        enabled
CA03 - Phishing-resistant MFA for privileged directory roles            enabled
CA04 - Azure management requires phishing-resistant MFA and a compliant device  enabledForReportingButNotEnforced
```

### 5.4 La misma política en Terraform (parque declarativo)

```hcl
terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID."
}

# Break-glass accounts are excluded from EVERY Conditional Access policy.
# They are FIDO2-only, have permanently assigned Global Administrator, live in
# no group, and are alerted on at every sign-in. Losing them means losing the tenant.
data "azuread_group" "break_glass" {
  display_name     = "sg-breakglass-excluded-from-ca"
  security_enabled = true
}

resource "azuread_conditional_access_policy" "azure_management" {
  display_name = "CA04 - Azure management requires phishing-resistant MFA and a compliant device"
  state        = "enabledForReportingButNotEnforced"

  conditions {
    client_app_types = ["all"]

    applications {
      # Windows Azure Service Management API: portal, az CLI, Az PowerShell, ARM REST.
      included_applications = ["797f4846-ba00-4fd7-ba43-dac1f8f63013"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = [data.azuread_group.break_glass.object_id]
    }

    platforms {
      included_platforms = ["all"]
    }

    locations {
      included_locations = ["All"]
      excluded_locations = ["AllTrusted"]
    }
  }

  grant_controls {
    operator                          = "AND"
    built_in_controls                 = ["compliantDevice"]
    authentication_strength_policy_id = "/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000004"
  }

  session_controls {
    sign_in_frequency                 = 4
    sign_in_frequency_period          = "hours"
    sign_in_frequency_authentication_type = "primaryAndSecondaryAuthentication"
    persistent_browser_mode           = "never"
  }
}

resource "azuread_conditional_access_policy" "block_legacy_auth" {
  display_name = "CA01 - Block legacy authentication"
  state        = "enabled"

  conditions {
    # exchangeActiveSync + other = the protocols that cannot do interactive MFA.
    client_app_types = ["exchangeActiveSync", "other"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = [data.azuread_group.break_glass.object_id]
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}
```

### 5.5 Las reglas operativas no negociables

1. **Cuentas break-glass.** Dos cuentas solo-cloud, con UPN `*.onmicrosoft.com` (nunca un dominio propio federado), llaves FIDO2 guardadas en cajas fuertes físicas separadas, Global Administrator asignado permanentemente, **excluidas de toda política de CA**, y con una regla de alerta que se dispara ante cualquier inicio de sesión. Sin esto, una política de CA mal configurada deja a todos los administradores fuera del tenant sin más vía de recuperación que un caso de soporte de Microsoft.
2. **Report-only primero, siempre.** Desplegá cada política como `enabledForReportingButNotEnforced`, dejala correr al menos un ciclo de negocio completo (7 días como mínimo, para capturar los trabajos batch semanales), y después leé los resultados report-only en los sign-in logs antes de aplicarla.
3. **Probá con What If.** La herramienta *What If* de Conditional Access evalúa un inicio de sesión hipotético (usuario × app × dispositivo × ubicación × riesgo) contra el conjunto de políticas vivo y devuelve qué políticas aplican.
4. **Las cuentas de servicio son la excepción que tenés que diseñar, no descubrir.** Una carga de trabajo no interactiva no puede satisfacer MFA interactivo. Dale una **workload identity** (§7), acotala con una **política de Conditional Access para workload identities** restringida a una named location, y excluila de las políticas de MFA dirigidas a usuarios — explícitamente, por object ID, nunca con un "bueno, no está en el grupo".

---

## 6. Control de acceso basado en roles de Azure (RBAC)

### 6.1 La asignación de tres partes

```
                    ROLE ASSIGNMENT
    ┌───────────────────┬───────────────────┬────────────────────┐
    │ SECURITY PRINCIPAL│  ROLE DEFINITION  │       SCOPE        │
    ├───────────────────┼───────────────────┼────────────────────┤
    │ user              │ Owner             │ management group   │
    │ group  ◄─ prefer  │ Contributor       │ subscription       │
    │ service principal │ Reader            │ resource group     │
    │ managed identity  │ <custom role>     │ resource           │
    └───────────────────┴───────────────────┴────────────────────┘
```

Semántica:

- **Unión aditiva.** Los permisos efectivos son la unión de cada asignación en cada scope de la cadena de ancestros. No existe "denegar por ausencia de una concesión superior".
- **La herencia es solo hacia abajo.** `Reader` en el management group aplica a cada suscripción, resource group y recurso por debajo.
- **Las deny assignments anulan las concesiones**, pero no podés escribirlas directamente. Las crean las Azure managed applications y los **deployment stacks** con deny settings.
- **Las asignaciones no son instantáneas.** Contá hasta ~10 minutos de propagación a todas las cachés regionales de ARM; además el token tiene que refrescarse si el cambio involucra membresía de grupo.

### 6.2 Anatomía de una definición de rol

```json
{
  "Name": "Platform SRE - Diagnose Production",
  "Id": null,
  "IsCustom": true,
  "Description": "Read-only across production plus the specific write actions required to diagnose an incident: restart compute, read Key Vault secret metadata (never values), start network captures, and read log data. Deliberately excludes all delete actions and all data-plane secret reads.",
  "Actions": [
    "*/read",
    "Microsoft.Compute/virtualMachines/restart/action",
    "Microsoft.Compute/virtualMachineScaleSets/restart/action",
    "Microsoft.Web/sites/restart/action",
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
    "Microsoft.Network/networkWatchers/packetCaptures/*",
    "Microsoft.Network/networkWatchers/queryTroubleshootResult/action",
    "Microsoft.Network/networkWatchers/connectivityCheck/action",
    "Microsoft.Insights/eventtypes/values/read",
    "Microsoft.OperationalInsights/workspaces/query/action",
    "Microsoft.Support/*"
  ],
  "NotActions": [
    "Microsoft.Authorization/*/write",
    "Microsoft.Authorization/elevateAccess/action",
    "Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.KeyVault/vaults/accessPolicies/write"
  ],
  "DataActions": [
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
  ],
  "NotDataActions": [
    "Microsoft.KeyVault/vaults/secrets/getSecret/action"
  ],
  "AssignableScopes": [
    "/providers/Microsoft.Management/managementGroups/mg-corp"
  ]
}
```

| Campo | Gobierna | Evaluación |
|---|---|---|
| `Actions` | **Control plane** — operaciones sobre el *objeto* recurso vía ARM | Unión de todas las coincidencias |
| `NotActions` | Sustracción de `Actions` **solo dentro de esta definición** | **No es un deny** — otra asignación de rol igual puede otorgarlo |
| `DataActions` | **Data plane** — operaciones sobre los datos *dentro* del recurso (blobs, secrets, mensajes de cola) | Solo tiene sentido para data planes conscientes de RBAC |
| `NotDataActions` | Sustracción de `DataActions` | La misma salvedad que `NotActions` |
| `AssignableScopes` | Dónde puede *asignarse* la definición | Es obligatorio; un scope de management group hace que el rol sea reutilizable entre suscripciones |

> **La trampa de `NotActions`, evaluada y real:** `NotActions` *no* es una regla de denegación. Si un principal tiene este rol personalizado **y** además `Contributor` en algún punto de la cadena, puede escribir objetos de autorización. En Azure RBAC el mínimo privilegio se logra **no otorgando el rol más amplio**, no restándole cosas.

Desplegalo:

```console
$ az role definition create --role-definition @sre-diagnose-production.json \
    --query "{name:roleName, id:name, type:roleType}" -o json
{
  "id": "c58d1e7a-4b93-4f20-a6d5-88ef0c31b742",
  "name": "Platform SRE - Diagnose Production",
  "type": "CustomRole"
}
```

### 6.3 Azure RBAC vs roles de Entra vs Azure Policy vs Key Vault access policies

Esta tabla es lo de mayor rendimiento en todo el dominio. Confundir estas cosas produce tanto fracasos en el examen como incidentes en producción.

| | **Azure RBAC** | **Roles de Microsoft Entra** | **Azure Policy** | **Key Vault access policies** (legacy) |
|---|---|---|---|---|
| Gobierna | **Recursos** de Azure (VMs, storage, AKS…) | **Objetos de directorio** (usuarios, grupos, apps, políticas de CA) | **Configuración/forma del recurso** | Operaciones de data plane sobre un vault |
| Rol de ejemplo | `Contributor`, `Storage Blob Data Reader` | `Global Administrator`, `User Administrator` | `Deny`, `Audit`, `DeployIfNotExists` | Get/List/Set sobre Secrets |
| Modelo de scope | MG → Sub → RG → Recurso | **Todo el tenant** (+ administrative units, roles acotados) | MG → Sub → RG | Un único vault, sin herencia |
| Punto de aplicación | ARM + data planes conscientes de RBAC | Entra ID / Microsoft Graph | Admisión en ARM | El propio Key Vault |
| Modelo de efecto | Solo **Allow** (+ deny assignments poco frecuentes) | Allow | **Deny / Audit / Modify / Deploy** | Allow |
| ¿Denegaciones posibles? | Rara vez | No | **Sí — ese es su trabajo** | No |
| Gestionado en IaC como | `Microsoft.Authorization/roleAssignments` | Graph / provider `azuread` | `Microsoft.Authorization/policyDefinitions` | `Microsoft.KeyVault/vaults/accessPolicies` |
| Recomendación | ✅ | ✅ | ✅ | ⚠️ **Migrar a Azure RBAC** |

Dos hechos cruzados:

- Un **Global Administrator no tiene permisos de Azure RBAC por defecto.** Puede *otorgárselos a sí mismo* activando **Access management for Azure resources**, lo que asigna `User Access Administrator` en el scope raíz `/`. Ese interruptor es uno de los eventos de auditoría de mayor valor del tenant.
- Key Vault soporta ambos modelos. **Azure RBAC es el recomendado**: las access policies no se heredan, no son visibles para `az role assignment list`, topan en 1.024 entradas y son invisibles para la mayoría del tooling de postura.

### 6.4 Límites de escala

| Límite | Valor | Consecuencia |
|---|---|---|
| Asignaciones de rol por suscripción | **4.000** | Asigná a **grupos**, nunca a usuarios. Un modelo por usuario agota esto |
| Asignaciones de rol por management group | 500 | Reservá el scope de MG para un puñado de roles de plataforma |
| Definiciones de rol personalizadas por tenant | 5.000 | De sobra; la restricción es la comprensión humana, no el límite |
| Anidamiento de management groups | 6 niveles (root + 5) | Diseñá la jerarquía antes de necesitar el nivel 7 |
| Grupos en un JWT antes del overage | ~200 (SAML ~150) | Pasado eso, el token lleva `hasgroups` + `_claim_names` y la app **debe** llamar a Graph. La autorización basada en grupos se rompe silenciosamente a escala |

> Verificá contra el documento de límites vivo antes de diseñar contra un número — los límites de Azure cambian. La *forma* de la restricción (asigná a grupos; ojo con el overage de grupos) no cambia.

### 6.5 Bicep completo — carga de trabajo de mínimo privilegio con una managed identity user-assigned

```bicep
targetScope = 'resourceGroup'

@description('Deployment environment; used for naming and for tagging.')
@allowed(['dev', 'stg', 'prod'])
param environment string = 'prod'

@description('Azure region for all resources in this deployment.')
param location string = resourceGroup().location

@description('Object ID of the Entra security group that owns this workload.')
param workloadOwnerGroupObjectId string

@description('OIDC issuer URL of the AKS cluster that will federate to this identity.')
param aksOidcIssuerUrl string

@description('Kubernetes namespace of the consuming workload.')
param k8sNamespace string = 'payments'

@description('Kubernetes ServiceAccount name of the consuming workload.')
param k8sServiceAccount string = 'sa-payments-api'

var suffix = uniqueString(resourceGroup().id)
var kvName = 'kv-pay-${environment}-${take(suffix, 6)}'
var saName = 'stpay${environment}${take(suffix, 8)}'

// ---------------------------------------------------------------------------
// Well-known built-in role definition GUIDs. These are stable across every
// Azure tenant; resolving them by name at deploy time is slower and can be
// ambiguous, so they are pinned here with a comment naming each one.
// ---------------------------------------------------------------------------
var roleIds = {
  keyVaultSecretsUser:      '4633458b-17de-408a-b874-0445c86b69e6'  // read secret VALUES, no management
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // read/write/delete blobs
  storageBlobDataReader:     '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  reader:                    'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

// ---------------------------------------------------------------------------
// The workload identity. User-assigned, so that a cluster or deployment
// rebuild does not invalidate every downstream role assignment.
// ---------------------------------------------------------------------------
resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-payments-${environment}'
  location: location
  tags: {
    environment: environment
    workload: 'payments'
    managedBy: 'bicep'
  }
}

// Federated credential: lets the AKS ServiceAccount token be exchanged for an
// Entra ID token. No client secret exists anywhere in this system.
resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: workloadIdentity
  name: 'fic-aks-${k8sNamespace}-${k8sServiceAccount}'
  properties: {
    issuer: aksOidcIssuerUrl
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sServiceAccount}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

// ---------------------------------------------------------------------------
// Key Vault, in RBAC authorization mode. Access policies are explicitly NOT
// used: they do not inherit, are invisible to `az role assignment list`, and
// are not evaluated by posture tooling.
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
  tags: {
    environment: environment
    workload: 'payments'
  }
}

// ---------------------------------------------------------------------------
// Storage account with shared key access DISABLED. This is what makes the RBAC
// assignments below load-bearing rather than decorative: with shared keys on,
// anyone holding the 512-bit account key bypasses RBAC entirely and the access
// is unattributable in the diagnostic logs.
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: {
    name: environment == 'prod' ? 'Standard_ZRS' : 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
  tags: {
    environment: environment
    workload: 'payments'
  }
}

// ---------------------------------------------------------------------------
// Role assignments. The name MUST be a deterministic GUID derived from
// (scope, principal, role) so that redeployment is idempotent instead of
// producing RoleAssignmentUpdateNotPermitted.
// ---------------------------------------------------------------------------
resource raSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, workloadIdentity.id, roleIds.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Payments API reads its own connection secrets. Data plane only; cannot manage the vault.'
  }
}

resource raBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, workloadIdentity.id, roleIds.storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Payments API reads and writes settlement blobs.'
  }
}

// Humans get READ-ONLY. Write paths go through CI/CD, which uses the workload
// identity above. Nobody holds standing write access to production data.
resource raOwnerGroupReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, workloadOwnerGroupObjectId, roleIds.reader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.reader)
    principalId: workloadOwnerGroupObjectId
    principalType: 'Group'
    description: 'Owning team: read-only standing access. Write is obtained just-in-time via PIM.'
  }
}

output workloadIdentityClientId string = workloadIdentity.properties.clientId
output workloadIdentityPrincipalId string = workloadIdentity.properties.principalId
output keyVaultUri string = keyVault.properties.vaultUri
output storageAccountName string = storage.name
```

Desplegá y confirmá:

```console
$ az deployment group create \
    --resource-group rg-payments-prod \
    --template-file payments-identity.bicep \
    --parameters environment=prod \
                 workloadOwnerGroupObjectId=c4f18a72-9e33-4b5d-8a07-ee2d61c9f048 \
                 aksOidcIssuerUrl="$(az aks show -g rg-aks-prod -n aks-prod-weu --query oidcIssuerProfile.issuerUrl -o tsv)" \
    --query "properties.{state:provisioningState, outputs:outputs}" -o json
{
  "outputs": {
    "keyVaultUri":               { "type": "String", "value": "https://kv-pay-prod-a9f31c.vault.azure.net/" },
    "storageAccountName":        { "type": "String", "value": "stpayproda9f31c4e" },
    "workloadIdentityClientId":  { "type": "String", "value": "9d41a0b6-2c7f-4e3a-b915-8ad0f6c1e552" },
    "workloadIdentityPrincipalId": { "type": "String", "value": "e2a8b551-73cd-49f0-9b2a-1d47cf30ab99" }
  },
  "state": "Succeeded"
}
```

### 6.6 Cerrar el bypass del data plane con Azure Policy

RBAC sobre una storage account no significa nada mientras el acceso por shared key esté habilitado. Esta política personalizada hace que el cierre sea estructural y no aspiracional:

```json
{
  "properties": {
    "displayName": "Storage accounts must disable shared key access (force Entra ID authorization)",
    "description": "Denies creation or update of a storage account with allowSharedKeyAccess enabled. Shared keys grant unattributable, full data-plane access that bypasses every Azure RBAC assignment and every Conditional Access policy on the account.",
    "policyType": "Custom",
    "mode": "Indexed",
    "metadata": {
      "version": "1.0.0",
      "category": "Storage"
    },
    "parameters": {
      "effect": {
        "type": "String",
        "metadata": {
          "displayName": "Effect",
          "description": "Deny blocks the request at admission; Audit records non-compliance only."
        },
        "allowedValues": ["Audit", "Deny", "Disabled"],
        "defaultValue": "Deny"
      },
      "exemptedAccounts": {
        "type": "Array",
        "metadata": {
          "displayName": "Exempted storage account names",
          "description": "Named accounts that still require shared keys for a documented legacy dependency. Every entry needs an expiry date in the change record."
        },
        "defaultValue": []
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "equals": "Microsoft.Storage/storageAccounts"
          },
          {
            "not": {
              "field": "name",
              "in": "[parameters('exemptedAccounts')]"
            }
          },
          {
            "anyOf": [
              {
                "field": "Microsoft.Storage/storageAccounts/allowSharedKeyAccess",
                "exists": "false"
              },
              {
                "field": "Microsoft.Storage/storageAccounts/allowSharedKeyAccess",
                "equals": "true"
              }
            ]
          }
        ]
      },
      "then": {
        "effect": "[parameters('effect')]"
      }
    }
  }
}
```

```console
$ az policy definition create \
    --name deny-storage-shared-key \
    --display-name "Storage accounts must disable shared key access" \
    --rules @deny-storage-shared-key.rules.json \
    --params @deny-storage-shared-key.params.json \
    --mode Indexed \
    --management-group mg-corp \
    --query "{id:name, type:policyType}" -o json
{
  "id": "deny-storage-shared-key",
  "type": "Custom"
}

$ az policy assignment create \
    --name enforce-no-shared-key \
    --display-name "Enforce: no storage shared keys in Corp" \
    --policy "/providers/Microsoft.Management/managementGroups/mg-corp/providers/Microsoft.Authorization/policyDefinitions/deny-storage-shared-key" \
    --scope "/providers/Microsoft.Management/managementGroups/mg-corp" \
    --params '{"effect":{"value":"Deny"}}' \
    --query "{name:name, enforcement:enforcementMode}" -o json
{
  "enforcement": "Default",
  "name": "enforce-no-shared-key"
}
```

Verificá que el deny realmente se dispara:

```console
$ az storage account create -n stlegacytest01 -g rg-sandbox -l westeurope \
    --sku Standard_LRS --allow-shared-key-access true
(RequestDisallowedByPolicy) Resource 'stlegacytest01' was disallowed by policy. Policy identifiers:
'[{"policyAssignment":{"name":"Enforce: no storage shared keys in Corp",
"id":"/providers/Microsoft.Management/managementGroups/mg-corp/providers/Microsoft.Authorization/policyAssignments/enforce-no-shared-key"},
"policyDefinition":{"name":"Storage accounts must disable shared key access",
"id":"/providers/Microsoft.Management/managementGroups/mg-corp/providers/Microsoft.Authorization/policyDefinitions/deny-storage-shared-key"}}]'
Code: RequestDisallowedByPolicy
```

> **Distinguí los dos 403.** `RequestDisallowedByPolicy` significa *la forma del recurso está prohibida* — Azure Policy. `AuthorizationFailed` significa *no tenés permiso para realizar esta operación* — Azure RBAC. Subsistema distinto, arreglo distinto.

### 6.7 Privilegio just-in-time (PIM)

Un `Owner`/`Contributor` permanente es el mayor riesgo de identidad en la mayoría de los parques de Azure. **Privileged Identity Management** (Entra ID P2) convierte una asignación de *activa* a *elegible*: el principal no tiene nada hasta que activa, con justificación, aprobación opcional, MFA y una duración máxima.

| | Asignación permanente | **Asignación elegible de PIM** |
|---|---|---|
| Permiso mantenido en reposo | Total | **Ninguno** |
| Radio de impacto de un token robado | Rol completo | Solo lectura, hasta la activación |
| La activación requiere | — | MFA + justificación (+ aprobador, + ref. de ticket) |
| Duración | Permanente | Acotada en el tiempo (p. ej. 4 h), expira sola |
| Rastro de auditoría | Solo las operaciones | Las operaciones **más el motivo y el aprobador** |
| Costo | Incluido | Requiere **Entra ID P2** |

PIM aplica tanto a los **directory roles de Entra** como a los **roles de Azure RBAC** (como asignaciones de rol *elegibles* con la API `Microsoft.Authorization/roleEligibilityScheduleRequests`).

---

## 7. Workload identity — cerrar el problema del secreto en CI/CD

Esta es la sección que elimina el modo de falla #2 de la §1, y es la respuesta moderna a "cómo se autentica un pipeline o un Pod contra Azure sin un secreto".

| Enfoque | Material secreto | Rotación | Radio de impacto si se filtra | Dónde funciona |
|---|---|---|---|---|
| SP + **client secret** | Sí, una cadena bearer | Manual, expira (máx. 24 meses) | **Total, hasta la expiración** — usable desde cualquier lado | En cualquier lado |
| SP + **certificado** | Sí, una clave privada | Manual, expira | Total, hasta la expiración | En cualquier lado |
| **Managed identity** (system/user-assigned) | **Ninguno** | Automática, por Azure | Requiere ejecución de código *en el recurso de Azure* | Solo cómputo de Azure |
| **Workload identity federation (OIDC)** | **Ninguno** | N/A — las assertions duran ~10 min | Requiere control del subject OIDC confiado | GitHub, GitLab, AKS, Azure DevOps, cualquier IdP OIDC |

**Elegí en este orden: managed identity → workload identity federation → certificado → secreto.** Un client secret en una variable de CI es un último recurso con una expiración documentada, no un valor por defecto.

### 7.1 Workload identity en AKS — manifiestos completos

Habilitá el OIDC issuer y el mutating webhook en el clúster:

```console
$ az aks update -g rg-aks-prod -n aks-prod-weu \
    --enable-oidc-issuer --enable-workload-identity \
    --query "{oidc:oidcIssuerProfile.enabled, wi:securityProfile.workloadIdentity.enabled}" -o json
{
  "oidc": true,
  "wi": true
}

$ az aks show -g rg-aks-prod -n aks-prod-weu --query oidcIssuerProfile.issuerUrl -o tsv
https://westeurope.oic.prod-aks.azure.com/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/6b1e4d27-9a0c-4f83-b2e5-71cd8f406a93/
```

```yaml
# ---------------------------------------------------------------------------
# payments-workload-identity.yaml
# AKS workload identity: the ServiceAccount token is exchanged for an Entra ID
# access token. No Kubernetes Secret, no client secret, nothing to rotate.
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-payments-api
  namespace: payments
  annotations:
    # clientId of the user-assigned managed identity. NOT the principalId.
    # This value is what the webhook injects as AZURE_CLIENT_ID.
    azure.workload.identity/client-id: "9d41a0b6-2c7f-4e3a-b915-8ad0f6c1e552"
    azure.workload.identity/tenant-id: "3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10"
    # Projected service account token lifetime, in seconds. Default 3600.
    azure.workload.identity/service-account-token-expiration: "3600"
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        # This label is MANDATORY. Without it the mutating webhook does not
        # touch the Pod: no projected token volume, no AZURE_* env vars, and
        # the SDK falls through to the next credential in the chain.
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: sa-payments-api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: crcontoso.azurecr.io/payments-api:2.14.3
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            # Explicitly declared for clarity; the webhook injects these
            # automatically when the label above is present:
            #   AZURE_CLIENT_ID, AZURE_TENANT_ID,
            #   AZURE_FEDERATED_TOKEN_FILE, AZURE_AUTHORITY_HOST
            - name: KEYVAULT_URI
              value: "https://kv-pay-prod-a9f31c.vault.azure.net/"
            - name: STORAGE_ACCOUNT
              value: "stpayproda9f31c4e"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

Verificá que la inyección realmente ocurrió:

```console
$ kubectl -n payments get pod -l app.kubernetes.io/name=payments-api -o jsonpath='{.items[0].spec.containers[0].env}' | jq
[
  { "name": "KEYVAULT_URI",   "value": "https://kv-pay-prod-a9f31c.vault.azure.net/" },
  { "name": "STORAGE_ACCOUNT","value": "stpayproda9f31c4e" },
  { "name": "AZURE_CLIENT_ID","value": "9d41a0b6-2c7f-4e3a-b915-8ad0f6c1e552" },
  { "name": "AZURE_TENANT_ID","value": "3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10" },
  { "name": "AZURE_FEDERATED_TOKEN_FILE", "value": "/var/run/secrets/azure/tokens/azure-identity-token" },
  { "name": "AZURE_AUTHORITY_HOST", "value": "https://login.microsoftonline.com/" }
]

$ kubectl -n payments exec deploy/payments-api -- \
    cat /var/run/secrets/azure/tokens/azure-identity-token | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, iss, sub, exp}'
{
  "aud": ["api://AzureADTokenExchange"],
  "iss": "https://westeurope.oic.prod-aks.azure.com/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/6b1e4d27-9a0c-4f83-b2e5-71cd8f406a93/",
  "sub": "system:serviceaccount:payments:sa-payments-api",
  "exp": 1789435704
}
```

> Los `iss`, `sub` y `aud` de arriba deben coincidir con la federated identity credential **byte por byte**. Un renombrado de namespace, un renombrado de ServiceAccount o una reconstrucción del clúster (nuevo issuer URL) rompen la confianza y producen `AADSTS70021`.

### 7.2 GitHub Actions — OIDC hacia Azure, cero secretos

```console
$ az ad app create --display-name "gh-oidc-payments-deploy" --query "{appId:appId, id:id}" -o json
{
  "appId": "4c7b2e91-6d38-4a05-9f27-b3e1c8a04d56",
  "id": "0f81a6d3-52bc-4e79-a1d4-77c9e2b5f308"
}

$ az ad sp create --id 4c7b2e91-6d38-4a05-9f27-b3e1c8a04d56 --query "{objectId:id}" -o json
{
  "objectId": "d3a19f67-4c25-4b80-92e6-5f7a01cd3b48"
}

$ az ad app federated-credential create \
    --id 0f81a6d3-52bc-4e79-a1d4-77c9e2b5f308 \
    --parameters '{
      "name": "gh-contoso-payments-env-production",
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "repo:contoso/payments:environment:production",
      "description": "GitHub Actions, production environment only. Not branch-scoped.",
      "audiences": ["api://AzureADTokenExchange"]
    }'

$ az role assignment create \
    --assignee-object-id d3a19f67-4c25-4b80-92e6-5f7a01cd3b48 \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/resourceGroups/rg-payments-prod" \
    --query "{role:roleDefinitionName, scope:scope}" -o json
{
  "role": "Contributor",
  "scope": "/subscriptions/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/resourceGroups/rg-payments-prod"
}
```

```yaml
# .github/workflows/deploy-production.yml
name: Deploy payments API to production

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

# Least privilege at the workflow level. id-token: write is what allows the
# runner to request an OIDC assertion from GitHub's token service.
permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy-production
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    # The GitHub Environment name is part of the federated credential SUBJECT.
    # Changing it here without changing the federated credential yields
    # AADSTS70021 at login time.
    environment:
      name: production
      url: https://payments.contoso.com

    steps:
      - name: Check out the repository
        uses: actions/checkout@v4

      # No AZURE_CLIENT_SECRET anywhere. These three values are identifiers,
      # not credentials: they are safe in repository variables.
      - name: Sign in to Azure with OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Prove which identity we are running as
        run: |
          az account show --query "{sub:name, tenant:tenantId}" -o json
          az ad signed-in-user show 2>/dev/null \
            || echo "Running as a service principal (expected: no signed-in user)."

      - name: Validate the infrastructure template before deploying
        run: |
          az deployment group validate \
            --resource-group rg-payments-prod \
            --template-file infra/payments-identity.bicep \
            --parameters environment=prod \
                         workloadOwnerGroupObjectId=${{ vars.OWNER_GROUP_OBJECT_ID }} \
                         aksOidcIssuerUrl=${{ vars.AKS_OIDC_ISSUER_URL }} \
            --output none

      - name: Show what would change (what-if)
        run: |
          az deployment group what-if \
            --resource-group rg-payments-prod \
            --template-file infra/payments-identity.bicep \
            --parameters environment=prod \
                         workloadOwnerGroupObjectId=${{ vars.OWNER_GROUP_OBJECT_ID }} \
                         aksOidcIssuerUrl=${{ vars.AKS_OIDC_ISSUER_URL }}

      - name: Deploy
        run: |
          az deployment group create \
            --name "payments-${GITHUB_SHA::8}" \
            --resource-group rg-payments-prod \
            --template-file infra/payments-identity.bicep \
            --parameters environment=prod \
                         workloadOwnerGroupObjectId=${{ vars.OWNER_GROUP_OBJECT_ID }} \
                         aksOidcIssuerUrl=${{ vars.AKS_OIDC_ISSUER_URL }} \
            --output table
```

> **Acotá el subject de la federated credential tanto como el workflow lo permita.** `repo:contoso/payments:ref:refs/heads/main` es mejor que `repo:contoso/payments:pull_request`; `repo:contoso/payments:environment:production` es todavía mejor, porque un GitHub Environment agrega revisores obligatorios y restricciones de rama por encima. Un subject `repo:contoso/payments:*` — nunca escribas uno — significa que cualquier rama de ese repositorio, incluida una que abra un colaborador, puede desplegar a producción.

---

## 8. Zero Trust

Zero Trust no es un producto. Es la suposición de diseño de que **la ubicación de red de una petición no aporta ningún valor de autorización**.

### 8.1 Tres principios rectores

| Principio | Significado | Implementación concreta en Azure |
|---|---|---|
| **Verify explicitly** | Autenticar y autorizar con **todas** las señales disponibles: identidad, ubicación, salud del dispositivo, servicio, carga de trabajo, clasificación de datos, anomalías | Conditional Access con cumplimiento del dispositivo + authentication strengths + riesgo de Identity Protection |
| **Use least privilege access** | Just-in-time, just-enough-access (JIT/JEA), políticas adaptativas basadas en riesgo, protección de datos | Asignaciones elegibles de PIM, roles RBAC personalizados, condiciones ABAC, acceso JIT a VMs |
| **Assume breach** | Minimizar el radio de impacto, segmentar el acceso, verificar el cifrado extremo a extremo, usar analítica para impulsar la detección y respuesta | Segmentación de red, private endpoints, Defender for Cloud + Microsoft Sentinel, CAE |

### 8.2 Los seis pilares, mapeados a controles

| Pilar | Pregunta | Controles principales de Azure |
|---|---|---|
| **Identities** | ¿El principal está verificado y con mínimo privilegio? | Entra ID, MFA/passwordless, Conditional Access, PIM, Identity Protection, access reviews |
| **Endpoints / devices** | ¿El dispositivo es conocido, sano y compatible? | Políticas de cumplimiento de Intune, Entra device join, grant `compliantDevice` de CA, Defender for Endpoint |
| **Applications** | ¿Las apps están descubiertas, con permisos y monitorizadas? | App registrations + políticas de consentimiento, Defender for Cloud Apps, Application Proxy, controles de sesión |
| **Data** | ¿Los datos están clasificados, etiquetados y cifrados? | Purview Information Protection, cifrado en reposo/en tránsito, Defender for Storage, claves gestionadas por el cliente |
| **Infrastructure** | ¿La configuración está endurecida y se detecta la deriva? | Azure Policy, Defender for Cloud, acceso JIT a VMs, Update Manager, Bicep/Terraform como única ruta de escritura |
| **Networks** | ¿La red está segmentada y el tráfico inspeccionado? | NSGs, Azure Firewall + IDPS, private endpoints, DDoS Protection, WAF, micro-segmentación |
| *(transversal)* **Visibility, automation, orchestration** | ¿Podés ver y responder? | Azure Monitor, Log Analytics, Microsoft Sentinel, playbooks de Logic Apps |

### 8.3 Del perímetro a Zero Trust — la diferencia práctica

| | Modelo clásico de perímetro | Modelo Zero Trust |
|---|---|---|
| Ancla de confianza | Ubicación de red ("dentro de la VPN") | **Identidad verificada + dispositivo verificado**, por petición |
| Frecuencia de autenticación | Una vez, al conectar la VPN | Continuamente (CAE, sign-in frequency) |
| Movimiento lateral | Trivial una vez adentro | Restringido por la autorización por recurso |
| Acceso remoto | VPN a una red plana | Acceso por aplicación; Application Proxy / Private Access |
| Contratista con portátil personal | Acceso completo a la red | Bloqueado por el grant de cumplimiento del dispositivo |
| Credencial robada | Acceso total | Bloqueada por MFA + riesgo + estado del dispositivo |
| Auth servidor a servidor | Secretos compartidos, listas de IPs permitidas | Managed identities y workload identity federation |

---

## 9. Defensa en profundidad

La defensa en profundidad aplica **controles independientes y superpuestos** de modo que ninguna falla individual produzca una brecha. La medida de una capa no es si funciona — es qué sigue en pie cuando no funciona.

| Capa | Objetivo | Controles de Azure | Si falla solo esta capa, qué te salva |
|---|---|---|---|
| **Física** | Impedir el acceso físico al hardware | Controles del datacenter de Microsoft, biometría, destrucción segura de medios — **responsabilidad tuya solo en on-prem/híbrido** | Cifrado en reposo |
| **Identidad y acceso** | Solo entran principals verificados; mínimo privilegio | Entra ID, MFA, Conditional Access, RBAC, PIM | Segmentación de red + logging |
| **Perímetro** | Absorber ataques volumétricos, filtrar en el borde | DDoS Protection, Azure Firewall, Front Door + WAF | NSGs y autorización a nivel de aplicación |
| **Red** | Limitar el movimiento lateral; segmentar | NSGs, ASGs, private endpoints, service endpoints, forced tunnelling, sin IPs públicas | Firewall del host, RBAC por recurso |
| **Cómputo** | Endurecer y parchear hosts y contenedores | Update Manager, Defender for Servers, cifrado de disco, Trusted Launch, Pod Security Standards, escaneo de imágenes | Autorización a nivel de aplicación, cifrado de datos |
| **Aplicación** | Eliminar vulnerabilidades a nivel de aplicación | SDLC seguro, secretos en Key Vault, escaneo de dependencias, reglas de WAF, managed identity | Cifrado de datos, monitorización |
| **Datos** | Proteger el activo en sí | Cifrado en reposo (SSE/CMK) y en tránsito (TLS 1.2+), clasificación con Purview, roles RBAC de data plane, soft delete + purge protection, almacenamiento inmutable | Backups, y divulgación honesta |

**Tríada CIA** — la propiedad que defiende cada capa:

| | Definición | Control representativo de Azure |
|---|---|---|
| **Confidencialidad** | Solo los principals autorizados pueden leerlo | Cifrado, RBAC, private endpoints, Key Vault |
| **Integridad** | Los datos no se alteran de forma indetectable | Hashing/firmado, blob storage inmutable, monitorización de integridad de archivos, acotado de escritura por RBAC |
| **Disponibilidad** | Los principals autorizados pueden alcanzarlo cuando lo necesitan | Availability zones, DDoS Protection, backups, geo-redundancia, Site Recovery |

> **Corolario práctico:** la storage account de la §6.5 establece `allowSharedKeyAccess: false` **y** `publicNetworkAccess: Disabled` **y** `minimumTlsVersion: TLS1_2` **y** roles de datos de RBAC. Cualquiera de esos por separado es evitable. Juntos, un atacante necesita un token de Entra válido, desde una ruta de red permitida, sobre una sesión TLS moderna, con una asignación de rol de data plane coincidente.

---

## 10. Microsoft Defender for Cloud

### 10.1 Qué es

Defender for Cloud es una **CNAPP** — Cloud-Native Application Protection Platform — que combina dos funciones que a menudo se venden por separado:

| Función | Sigla | Responde | Se entrega como |
|---|---|---|---|
| Cloud Security Posture Management | **CSPM** | *¿Está mal mi configuración?* | Secure Score, recomendaciones, panel de cumplimiento normativo, análisis de rutas de ataque |
| Cloud Workload Protection | **CWPP** | *¿Me están atacando ahora mismo?* | Planes de Defender: alertas en runtime, EDR, escaneo de malware, detección conductual |

Más **DevOps security** (postura de repositorios de Azure DevOps / GitHub / GitLab) y conectores **multicloud** para AWS y GCP, que es por lo que la vista del parque no es solo de Azure.

### 10.2 Gratis vs pago — un límite preciso

| Capacidad | CSPM fundacional (**gratis**, activo por defecto) | Defender CSPM (pago) | Planes de carga de trabajo de Defender (pago) |
|---|:--:|:--:|:--:|
| Secure Score | ✅ | ✅ | ✅ |
| Recomendaciones de seguridad | ✅ | ✅ | ✅ |
| Evaluación del Microsoft Cloud Security Benchmark | ✅ | ✅ | ✅ |
| Inventario de activos | ✅ | ✅ | ✅ |
| Conectores multicloud (AWS/GCP) | ✅ | ✅ | ✅ |
| **Análisis de rutas de ataque** | ❌ | ✅ | — |
| **Cloud Security Explorer** (consulta de grafo) | ❌ | ✅ | — |
| Escaneo agentless de vulnerabilidades y secretos | ❌ | ✅ | — |
| Paquetes de cumplimiento normativo más allá de MCSB | ❌ | ✅ | — |
| **Detección de amenazas / alertas de seguridad** | ❌ | ❌ | ✅ |
| Detección y respuesta en endpoints (vía MDE) | ❌ | ❌ | ✅ (Servers) |
| Acceso just-in-time a VMs | ❌ | ❌ | ✅ (Servers P2) |
| Monitorización de integridad de archivos | ❌ | ❌ | ✅ (Servers P2) |
| Escaneo de malware al subir | ❌ | ❌ | ✅ (Storage) |

> **La línea que se evalúa:** la evaluación de postura y el Secure Score son **gratis y siempre activos**. Cualquier cosa que *detecte un ataque en curso* requiere un plan de Defender pago.

### 10.3 Planes y qué protege cada uno

| Plan | Protege | Capacidad distintiva |
|---|---|---|
| Defender for **Servers** P1 | VMs de Azure/AWS/GCP/on-prem (Arc) | Integración con Microsoft Defender for Endpoint |
| Defender for **Servers** P2 | Lo mismo | + evaluación de vulnerabilidades, acceso JIT a VMs, FIM, controles adaptativos, 500 MB/día de ingesta gratuita |
| Defender for **Containers** | AKS/EKS/GKE/K8s habilitado con Arc, registries | Escaneo de imágenes en el registry, detecciones sobre el audit log de K8s, admission control vía Azure Policy for Kubernetes |
| Defender for **Storage** | Storage accounts | Escaneo de malware al subir, detección de amenazas sobre datos sensibles, alertas de acceso anómalo |
| Defender for **Databases** | SQL (Azure/VM/Arc), relacionales open source, Cosmos DB | Detección de inyección SQL, patrones de consulta anómalos |
| Defender for **Key Vault** | Vaults | Patrones inusuales de acceso a secretos, acceso desde IPs sospechosas/Tor |
| Defender for **Resource Manager** | El propio control plane de ARM | Asignaciones de rol sospechosas, `elevateAccess`, borrado masivo, firmas de toolkits |
| Defender for **App Service** | Aplicaciones web | Detección de web shells, DNS colgante |
| Defender for **APIs** | APIs publicadas en API Management | Endpoints sin autenticar/expuestos, exposición de datos sensibles, abuso de API |
| Defender for **AI Services** | Azure OpenAI / servicios de IA | Detecciones de prompt injection y exfiltración de datos |

### 10.4 Secure Score — cómo se calcula el número

Las recomendaciones se agrupan en **security controls**. Cada control tiene un valor máximo de puntos; ganás una fracción de él proporcional a los recursos sanos.

```
control_score   = max_points × (healthy_resources / total_resources)
secure_score(%) = Σ control_score / Σ max_points × 100
```

Consecuencias operativas:

- **Un control se acredita parcialmente.** Remediar 8 de 10 VMs gana el 80 % de los puntos de ese control, no cero.
- **Los controles pesan de forma desigual.** "Enable MFA" pesa muchísimo más que una recomendación cosmética — el Secure Score es un backlog priorizado, no una lista de tildes.
- **Agregar recursos baja el puntaje sin que nada haya empeorado.** Incorporar una nueva suscripción aumenta `total_resources`. Seguí el puntaje *por scope* y alertá sobre *deltas*, no sobre el número absoluto.
- **El puntaje no es un estado de cumplimiento.** Para eso usá el panel **Regulatory compliance**; la iniciativa asignada por defecto es el **Microsoft Cloud Security Benchmark (MCSB)**.

### 10.5 CLI

```console
$ az security pricing list --query "value[?pricingTier=='Standard'].{plan:name, tier:pricingTier, subplan:subPlan}" -o table
Plan                     Tier      Subplan
-----------------------  --------  ---------
VirtualMachines          Standard  P2
StorageAccounts          Standard  DefenderForStorageV2
KeyVaults                Standard
Arm                      Standard
Containers               Standard
CloudPosture             Standard

$ az security pricing create -n VirtualMachines --tier Standard --subplan P2 \
    --query "{plan:name, tier:pricingTier, subplan:subPlan}" -o json
{
  "plan": "VirtualMachines",
  "subplan": "P2",
  "tier": "Standard"
}

$ az security secure-score list --query "value[].{scope:name, current:properties.score.current, max:properties.score.max, pct:properties.score.percentage}" -o table
Scope     Current    Max    Pct
--------  ---------  -----  ------
ascScore  41.83      58     0.7212

$ az security assessment list \
    --query "value[?properties.status.code=='Unhealthy'].{resource:properties.resourceDetails.Id, finding:properties.displayName, severity:properties.metadata.severity}" \
    -o table | head -12
Resource                                                            Finding                                                              Severity
------------------------------------------------------------------  -------------------------------------------------------------------  --------
/subscriptions/3f9c.../storageAccounts/stlegacyarchive01            Storage accounts should prevent shared key access                    High
/subscriptions/3f9c.../virtualMachines/vm-legacy-app-02             Machines should have vulnerability findings resolved                 High
/subscriptions/3f9c.../managedClusters/aks-nonprod-weu              Azure Kubernetes Service clusters should have local auth disabled    Medium
/subscriptions/3f9c.../vaults/kv-shared-legacy                      Key vaults should have soft delete enabled                           High
/subscriptions/3f9c.../sites/app-partner-portal                     App Service apps should only be accessible over HTTPS                Medium

$ az security alert list --query "[?properties.status=='Active'].{name:properties.alertDisplayName, sev:properties.severity, resource:properties.compromisedEntity, time:properties.timeGeneratedUtc}" -o table
Name                                                          Sev      Resource                 Time
------------------------------------------------------------  -------  -----------------------  --------------------------
Suspicious role assignment detected                           High     sub-prod-eu              2026-09-05T22:14:07.318Z
Unusual amount of data extracted from a storage account       Medium   stpayproda9f31c4e        2026-09-06T03:41:55.902Z
Access from a Tor exit node to a Key Vault                    High     kv-shared-legacy         2026-09-06T01:07:22.114Z
```

Conectá las alertas al correo y a un workspace de Log Analytics para que lleguen a la rotación de guardia y no a una hoja del portal que nadie abre:

```console
$ az security contact create --name default \
    --emails "sre-oncall@contoso.com;security-ops@contoso.com" \
    --alert-notifications On --alerts-admins On \
    --query "{emails:email, notify:alertNotifications}" -o json
{
  "emails": "sre-oncall@contoso.com;security-ops@contoso.com",
  "notify": "On"
}
```

---

## 11. Verificación y diagnóstico de fallas

### 11.1 El runbook de `AuthorizationFailed`

Este es el 403 más común en Azure y tiene exactamente seis causas.

```console
$ az storage blob list --account-name stpayproda9f31c4e --container-name settlements --auth-mode login
(AuthorizationPermissionMismatch) This request is not authorized to perform this operation using this permission.
RequestId:8f2a1c07-501e-004c-3d19-b7c4e2000000
Time:2026-09-06T09:12:41.7710233Z
```

Recorré la escalera en orden — cada paso elimina una causa:

**Paso 1 — Confirmá qué principal sos realmente.** Más caídas vienen de estar autenticado con la identidad equivocada que de cualquier error de configuración.

```console
$ az account show --query "{sub:name, user:user.name, type:user.type}" -o json
{
  "sub": "sub-prod-eu",
  "type": "servicePrincipal",
  "user": "4c7b2e91-6d38-4a05-9f27-b3e1c8a04d56"
}
```

**Paso 2 — Enumerá cada asignación efectiva, incluidas las heredadas y las derivadas de grupos.** El `az role assignment list` por defecto no muestra ninguna de las dos, que es por lo que "lo revisé y el rol está" tan seguido está equivocado.

```console
$ az role assignment list \
    --assignee 4c7b2e91-6d38-4a05-9f27-b3e1c8a04d56 \
    --all --include-inherited --include-groups \
    --query "[].{role:roleDefinitionName, scope:scope, via:principalType}" -o table
Role                          Scope                                                                          Via
----------------------------  -----------------------------------------------------------------------------  ---------------
Reader                        /subscriptions/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10                             ServicePrincipal
Contributor                   /subscriptions/3f9c1a7e-.../resourceGroups/rg-payments-prod                     ServicePrincipal
```

**Diagnóstico:** `Contributor` es un rol de **control plane**. Otorga `Microsoft.Storage/storageAccounts/*` — incluido `listKeys` — pero **no lleva `DataActions`**. Leer el *contenido* de un blob requiere un rol de datos.

**Paso 3 — Demostralo contra la definición del rol en lugar de hacerlo de memoria.**

```console
$ az role definition list --name "Contributor" \
    --query "[0].permissions[0].{actions:actions, notActions:notActions, dataActions:dataActions}" -o json
{
  "actions": ["*"],
  "dataActions": null,
  "notActions": [
    "Microsoft.Authorization/*/Delete",
    "Microsoft.Authorization/*/Write",
    "Microsoft.Authorization/elevateAccess/Action",
    "Microsoft.Blueprint/blueprintAssignments/write",
    "Microsoft.Blueprint/blueprintAssignments/delete",
    "Microsoft.Compute/galleries/share/action",
    "Microsoft.Purview/consents/write"
  ]
}
```

`"dataActions": null` — confirmado.

**Paso 4 — Corregí en el scope más acotado que funcione.**

```console
$ az role assignment create \
    --assignee-object-id d3a19f67-4c25-4b80-92e6-5f7a01cd3b48 \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" \
    --scope "/subscriptions/3f9c1a7e-.../resourceGroups/rg-payments-prod/providers/Microsoft.Storage/storageAccounts/stpayproda9f31c4e/blobServices/default/containers/settlements" \
    --query "{role:roleDefinitionName, scope:scope}" -o json
{
  "role": "Storage Blob Data Reader",
  "scope": "/subscriptions/3f9c1a7e-.../containers/settlements"
}
```

**Paso 5 — Esperá la propagación y volvé a verificar. No concluyas "no funcionó" dentro de los primeros 10 minutos.**

```console
$ sleep 120 && az storage blob list --account-name stpayproda9f31c4e --container-name settlements --auth-mode login -o table
Name                              Blob Type    Blob Tier    Length     Content Type              Last Modified
--------------------------------  -----------  -----------  ---------  ------------------------  -------------------------
2026/09/05/settlement-eu.parquet  BlockBlob    Hot          18874368   application/octet-stream  2026-09-05T23:58:11+00:00
2026/09/06/settlement-eu.parquet  BlockBlob    Hot          19398656   application/octet-stream  2026-09-06T05:02:47+00:00
```

**Paso 6 — Si sigue fallando, usá la verificación autoritativa.** `az role assignment list` muestra asignaciones; `checkAccess` evalúa la **decisión efectiva**, incluidas las deny assignments y las condiciones ABAC.

```console
$ az rest --method POST \
    --url "https://management.azure.com/subscriptions/3f9c1a7e-58d2-4b6f-9e01-77a4c2ab3d10/providers/Microsoft.Authorization/checkAccess?api-version=2022-04-01" \
    --body '{
      "subject": { "attributes": { "ObjectId": "d3a19f67-4c25-4b80-92e6-5f7a01cd3b48" } },
      "actions": [ { "id": "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read", "isDataAction": true } ],
      "resource": { "id": "/subscriptions/3f9c1a7e-.../storageAccounts/stpayproda9f31c4e/blobServices/default/containers/settlements" }
    }' -o json
{
  "accessDecisions": [
    {
      "accessDecision": "Allowed",
      "actionId": "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "roleAssignment": {
        "id": "/subscriptions/3f9c1a7e-.../providers/Microsoft.Authorization/roleAssignments/7d4a1c92-...",
        "roleDefinitionId": "/subscriptions/3f9c1a7e-.../roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
      },
      "denyAssignment": null
    }
  ]
}
```

### 11.2 Decodificador de errores `AADSTS`

Toda falla de autenticación de Entra ID lleva un código `AADSTS`. Memorizar los principales convierte una investigación de 30 minutos en una de 30 segundos.

| Código | Significado | Lo primero que hay que revisar |
|---|---|---|
| `AADSTS50126` | Usuario o contraseña inválidos | Credencial genuinamente mala — o un dominio federado que enruta el inicio de sesión a otro lado |
| `AADSTS50076` | Se requiere MFA, hace falta interacción | Política de CA exigiendo MFA en un flujo no interactivo. Dale a la carga de trabajo una workload identity |
| `AADSTS50079` | El usuario debe registrarse en MFA | Una campaña/política de registro alcanzó a un usuario no registrado. Emitile un **TAP** |
| `AADSTS53003` | **Bloqueado por Conditional Access** | Leé la entrada del sign-in log: nombra la política exacta. Revisá inclusiones vs exclusiones |
| `AADSTS530003` | El dispositivo no es compatible | Estado de cumplimiento en Intune; dispositivo no inscrito o evaluación desactualizada |
| `AADSTS50105` | El usuario no tiene un rol asignado para la aplicación | La app tiene *user assignment required* = Yes y este usuario/grupo no está asignado |
| `AADSTS50158` | Desafío de seguridad externo no satisfecho | Un control personalizado / MFA de terceros no se completó |
| `AADSTS700016` | Aplicación no encontrada en el directorio | Tenant equivocado, o el SP nunca se creó en este tenant (`az ad sp create --id <appId>`) |
| `AADSTS7000215` | Client secret inválido | Secreto vencido, rotado, o con un salto de línea al final. **Pasate a workload identity federation** |
| `AADSTS700024` | La client assertion no está dentro de su rango de validez temporal | Desfase de reloj en el runner, o una assertion cacheada obsoleta |
| **`AADSTS70021`** | **No se encontró un registro de identidad federada que coincida con la assertion presentada** | Desajuste de `issuer`/`subject`/`audience`. La falla nº 1 de workload identity |
| `AADSTS500011` | Resource principal no encontrado en el tenant | `--resource`/scope equivocado; el SP del recurso no existe en este tenant |
| `AADSTS900023` | Nombre / ID de tenant inválido | Error de tipeo, o autenticación contra la nube equivocada (`AzureUSGovernment` vs `AzureCloud`) |
| `AADSTS50177` | La cuenta de usuario externo no existe en el tenant | El invitado B2B nunca canjeó la invitación, o fue eliminado |

### 11.3 Diagnosticar `AADSTS70021` de punta a punta

Síntoma, desde un Pod:

```console
$ kubectl -n payments logs deploy/payments-api --tail=5
ERROR  DefaultAzureCredential failed to retrieve a token from the included credentials.
       WorkloadIdentityCredential: authentication failed
       AADSTS70021: No matching federated identity record found for presented assertion.
       Assertion Issuer: 'https://westeurope.oic.prod-aks.azure.com/3f9c1a7e-.../6b1e4d27-.../'
       Assertion Subject: 'system:serviceaccount:payments:sa-payments-api'
       Assertion Audience: 'api://AzureADTokenExchange'
       Trace ID: 1c8f3a02-7b45-4e91-b0d2-9e4a6c517f38
```

Compará los tres campos contra la credencial registrada — el mensaje de error convenientemente imprime los tres:

```console
$ az identity federated-credential list \
    --identity-name id-payments-prod --resource-group rg-identity-prod \
    --query "[].{name:name, issuer:issuer, subject:subject, aud:audiences[0]}" -o json
[
  {
    "aud": "api://AzureADTokenExchange",
    "issuer": "https://westeurope.oic.prod-aks.azure.com/3f9c1a7e-.../6b1e4d27-.../",
    "name": "fic-aks-payments-sa-payments-api",
    "subject": "system:serviceaccount:payments-api:sa-payments-api"
  }
]
```

**Diagnóstico:** el namespace del subject es `payments-api` en la federated credential, pero el Pod corre en `payments`. La coincidencia del subject es exacta y sensible a mayúsculas.

```console
$ az identity federated-credential update \
    --identity-name id-payments-prod --resource-group rg-identity-prod \
    --name fic-aks-payments-sa-payments-api \
    --subject "system:serviceaccount:payments:sa-payments-api" \
    --query subject -o tsv
system:serviceaccount:payments:sa-payments-api

$ kubectl -n payments rollout restart deployment/payments-api
deployment.apps/payments-api restarted

$ kubectl -n payments logs deploy/payments-api --tail=2
INFO  WorkloadIdentityCredential: token acquired for https://vault.azure.net/.default (expires 2026-09-06T10:41:02Z)
INFO  payments-api listening on :8080
```

**Checklist de `AADSTS70021`, en el orden que lo encuentra más rápido:**

1. `subject` — namespace *y* nombre del ServiceAccount, exactos y sensibles a mayúsculas.
2. `issuer` — la URL del OIDC issuer de AKS, **incluida la barra final**. Un clúster reconstruido tiene un issuer *nuevo*.
3. `audiences` — debe ser `api://AzureADTokenExchange`.
4. La plantilla del Pod lleva la etiqueta `azure.workload.identity/use: "true"`.
5. La anotación del ServiceAccount `azure.workload.identity/client-id` contiene el **clientId**, no el principalId.
6. El webhook está corriendo: `kubectl -n kube-system get pods -l azure-workload-identity.io/system=true`.

### 11.4 Diagnosticar "Conditional Access bloqueó algo"

`AADSTS53003` nombra la política — pero solo en el sign-in log, no en el error del cliente. Conseguí el log:

```console
$ az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=userPrincipalName eq 'contractor@partner.com' and status/errorCode ne 0&\$top=1" \
    --query "value[0].{time:createdDateTime, app:appDisplayName, err:status.errorCode, reason:status.failureReason, ip:ipAddress, device:deviceDetail.operatingSystem, compliant:deviceDetail.isCompliant, ca:conditionalAccessStatus, policies:appliedConditionalAccessPolicies[?result=='failure'].displayName}" -o json
{
  "app": "Azure Portal",
  "ca": "failure",
  "compliant": false,
  "device": "MacOs",
  "err": 53003,
  "ip": "203.0.113.47",
  "policies": [
    "CA04 - Azure management requires phishing-resistant MFA and a compliant device"
  ],
  "reason": "Access has been blocked by Conditional Access policies. The access policy does not allow token issuance.",
  "time": "2026-09-06T08:47:19Z"
}
```

Está todo lo necesario acá: la política `CA04`, el grant control no satisfecho, `isCompliant: false` en un dispositivo macOS no gestionado. El control funcionó como fue diseñado; la remediación es inscribir el dispositivo, no una exclusión en la política.

Leé los resultados report-only **antes** de aplicar la política — esta es la consulta que previene la caída:

```kusto
SigninLogs
| where TimeGenerated > ago(7d)
| mv-expand policy = todynamic(ConditionalAccessPolicies)
| where tostring(policy.displayName) startswith "CA04"
| extend Result = tostring(policy.result)
| where Result in ("reportOnlyFailure", "reportOnlyInterrupted")
| summarize
    Users        = dcount(UserPrincipalName),
    SignIns      = count(),
    SampleUsers  = make_set(UserPrincipalName, 10)
  by Result, AppDisplayName
| order by SignIns desc
```

Si eso devuelve 400 usuarios en 6 aplicaciones, aplicar la política mañana es una caída. Si devuelve 3 dispositivos conocidos no gestionados, aplicala.

### 11.5 Conditional Access What If — probar antes de romper

```console
$ az rest --method POST \
    --url "https://graph.microsoft.com/beta/identity/conditionalAccess/evaluate" \
    --headers "Content-Type=application/json" \
    --body '{
      "signInIdentity": {
        "@odata.type": "#microsoft.graph.userSignIn",
        "userId": "b7f2d9c4-1e88-4a52-9f3d-6c0a5b81e274"
      },
      "signInContext": {
        "@odata.type": "#microsoft.graph.signInContext",
        "includeApplications": ["797f4846-ba00-4fd7-ba43-dac1f8f63013"]
      },
      "signInConditions": {
        "devicePlatform": "macOS",
        "clientAppType": "browser",
        "signInRiskLevel": "medium",
        "isCompliantDevice": false,
        "country": "DE"
      }
    }' \
    --query "value[].{policy:displayName, result:policyApplies, controls:analysis.grantControlsResult}" -o table
Policy                                                                          Result    Controls
------------------------------------------------------------------------------  --------  ----------
CA01 - Block legacy authentication                                              False     notApplied
CA02 - Require MFA for all users                                                True      required
CA03 - Phishing-resistant MFA for privileged directory roles                    False     notApplied
CA04 - Azure management requires phishing-resistant MFA and a compliant device   True      required
```

### 11.6 La managed identity no funciona en una VM

```console
$ curl -sS -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" | jq
{
  "error": "invalid_request",
  "error_description": "Identity not found"
}
```

`Identity not found` desde IMDS significa que la **identidad no está adjunta al recurso** — es un problema de configuración de ARM, no de token:

```console
$ az vm identity show -g rg-payments-prod -n vm-batch-01 -o json
null

$ az vm identity assign -g rg-payments-prod -n vm-batch-01 \
    --identities /subscriptions/3f9c1a7e-.../resourceGroups/rg-identity-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-payments-prod \
    --query userAssignedIdentities -o json
{
  "/subscriptions/3f9c1a7e-.../userAssignedIdentities/id-payments-prod": {
    "clientId": "9d41a0b6-2c7f-4e3a-b915-8ad0f6c1e552",
    "principalId": "e2a8b551-73cd-49f0-9b2a-1d47cf30ab99"
  }
}
```

> Con **más de una** identidad user-assigned adjunta, IMDS **exige desambiguación**: agregá `&client_id=<clientId>`. Omitirlo devuelve `multiple_matching_identities`. Es una sorpresa frecuente en VMSS con múltiples cargas de trabajo.

### 11.7 Consultas de detección permanentes

Poné estas en un workspace de Log Analytics o en Microsoft Sentinel y alertá sobre ellas. Cubren los eventos de identidad de mayor señal en un parque de Azure.

```kusto
// 1. Privilege escalation on the Azure control plane: any role assignment write
//    that grants Owner or User Access Administrator.
AzureActivity
| where TimeGenerated > ago(1d)
| where OperationNameValue =~ "MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/WRITE"
| where ActivityStatusValue == "Success"
| extend props = todynamic(Properties)
| extend RoleDefId = tostring(parse_json(tostring(props.requestbody)).Properties.RoleDefinitionId)
| where RoleDefId has_any (
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",   // Owner
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9")   // User Access Administrator
| project TimeGenerated, Caller, CallerIpAddress, _ResourceId, RoleDefId
| order by TimeGenerated desc
```

```kusto
// 2. Break-glass account usage. Any hit here is a page, unconditionally.
let BreakGlass = dynamic([
    "breakglass01@contoso.onmicrosoft.com",
    "breakglass02@contoso.onmicrosoft.com"]);
SigninLogs
| where TimeGenerated > ago(30d)
| where UserPrincipalName in~ (BreakGlass)
| project TimeGenerated, UserPrincipalName, AppDisplayName, IPAddress,
          Location, ResultType, ResultDescription, ClientAppUsed
| order by TimeGenerated desc
```

```kusto
// 3. Legacy authentication still succeeding — every hit is an MFA bypass.
SigninLogs
| where TimeGenerated > ago(7d)
| where ClientAppUsed in ("Other clients", "IMAP4", "POP3", "SMTP", "Exchange ActiveSync", "MAPI Over HTTP")
| where ResultType == 0
| summarize SignIns = count(), IPs = dcount(IPAddress),
            Apps = make_set(AppDisplayName, 5)
  by UserPrincipalName, ClientAppUsed
| order by SignIns desc
```

```kusto
// 4. Interactive sign-ins by service principals that should never be interactive,
//    and successful sign-ins from a service principal outside expected locations.
AADServicePrincipalSignInLogs
| where TimeGenerated > ago(7d)
| where ResultType == 0
| summarize SignIns = count(), Countries = make_set(tostring(parse_json(tostring(Location))), 10)
  by ServicePrincipalName, IPAddress
| where array_length(Countries) > 1
| order by SignIns desc
```

```kusto
// 5. Conditional Access coverage gap: successful sign-ins where NO policy applied.
SigninLogs
| where TimeGenerated > ago(7d)
| where ResultType == 0
| where ConditionalAccessStatus == "notApplied"
| summarize SignIns = count(), Users = dcount(UserPrincipalName)
  by AppDisplayName, ClientAppUsed
| order by SignIns desc
```

### 11.8 Checklist de verificación previa a producción

| # | Verificación | Comando / evidencia | Criterio de aprobación |
|---|---|---|---|
| 1 | Sin Owner permanente con scope de suscripción para personas | `az role assignment list --scope /subscriptions/<id> --role Owner --include-groups -o table` | Solo break-glass y entradas elegibles de PIM |
| 2 | Cada asignación de rol apunta a un grupo o a una workload identity, nunca a un usuario | lo mismo, `--query "[?principalType=='User']"` | Vacío |
| 3 | Break-glass excluidas de todas las políticas de CA | Graph `conditionalAccess/policies`, buscar los grupos excluidos | Presente en cada política |
| 4 | Autenticación legacy bloqueada | Consulta KQL 3 de arriba | 0 inicios de sesión exitosos |
| 5 | Los admins requieren MFA resistente a phishing | CA03 existe, `state == enabled` | ✅ |
| 6 | Sin client secrets de CI/CD | `az ad app credential list --id <appId>` para cada app de CI | `passwordCredentials` vacío |
| 7 | Federated credentials acotadas a un entorno o una rama, nunca un comodín | `az ad app federated-credential list` | Sin `*` en `subject` |
| 8 | Key Vaults en modo RBAC | `az keyvault list --query "[?!properties.enableRbacAuthorization].name"` | Vacío |
| 9 | Shared keys de storage deshabilitadas | `az storage account list --query "[?allowSharedKeyAccess].name"` | Vacío |
| 10 | Planes de Defender habilitados en las suscripciones de producción | `az security pricing list -o table` | Planes requeridos en `Standard` |
| 11 | Tendencia del Secure Score registrada por scope | `az security secure-score list` | Seguida, con alerta ante delta negativo |
| 12 | Políticas de CA desplegadas en report-only ≥7 días antes de aplicarlas | Consulta KQL de report-only | Revisada, excepciones documentadas |

---

## 12. Destilados enfocados al examen

Los pares de mayor confusión, resueltos en una línea cada uno:

| Si la pregunta dice… | La respuesta es… | Porque |
|---|---|---|
| "gestionar usuarios, grupos y app registrations" | **Roles de Microsoft Entra** (p. ej. User Administrator) | Objetos de directorio, no recursos de Azure |
| "gestionar VMs, storage, redes" | **Azure RBAC** (p. ej. Contributor) | Recursos de Azure vía ARM |
| "impedir que un recurso se cree con la forma/región/SKU equivocada" | **Azure Policy** | RBAC no tiene deny para la forma; Policy sí |
| "una app necesita Kerberos/LDAP sin operar domain controllers" | **Microsoft Entra Domain Services** | Entra ID no habla Kerberos ni LDAP |
| "empleados de un partner necesitan acceso a nuestro SharePoint" | **B2B collaboration** | Objeto guest, autentica el tenant de origen del partner |
| "un millón de consumidores inician sesión con Google o una cuenta local" | **Azure AD B2C / Microsoft Entra External ID** | Escala CIAM, tenant separado, branding propio |
| "requerir MFA solo cuando el riesgo del inicio de sesión es alto" | **Conditional Access + Identity Protection (P2)** | Las señales de riesgo requieren P2 |
| "otorgar derechos de admin solo por 4 horas con aprobación" | **PIM (P2)** | Asignaciones elegibles, no activas |
| "sin contraseña en absoluto, no se puede phishear" | **FIDO2 / Windows Hello for Business / CBA** | Criptográfico, ligado al origen |
| "nunca confiar, siempre verificar, asumir la brecha" | **Zero Trust** | Los tres principios rectores |
| "múltiples capas independientes para que una falla no sea una brecha" | **Defensa en profundidad** | Física → identidad → perímetro → red → cómputo → app → datos |
| "mostrame mi puntaje de postura de seguridad y cómo mejorarlo" | **Microsoft Defender for Cloud** (Secure Score, CSPM gratis) | La postura es gratis; la detección de amenazas se paga |
| "alertame de que una VM está siendo atacada ahora mismo" | **Defender for Cloud, plan de carga de trabajo pago** | La detección requiere un plan de Defender |
| "la línea base gratuita de MFA para todo el tenant" | **Security defaults** | Gratis; mutuamente excluyente con Conditional Access |

Diez hechos con más probabilidad de aparecer textualmente:

1. Entra ID es **plano** — sin OUs, sin GPOs, sin Kerberos, sin LDAP.
2. **Conditional Access requiere Entra ID P1**; PIM e Identity Protection requieren **P2**.
3. **Security defaults y Conditional Access son mutuamente excluyentes.**
4. Una suscripción confía en **un** tenant; una jerarquía de management groups tiene **6 niveles** de profundidad incluyendo la raíz.
5. Azure RBAC es **aditivo**; `NotActions` resta dentro de una definición y **no** es un deny.
6. **Las deny assignments anulan los allow**, y no podés escribirlas a mano.
7. Zero Trust: **verify explicitly, least privilege, assume breach**.
8. Capas de defensa en profundidad: **física, identidad y acceso, perímetro, red, cómputo, aplicación, datos**.
9. El **CSPM/Secure Score de Defender for Cloud es gratis**; los **planes de protección de cargas de trabajo cuestan dinero**.
10. **MFA = dos o más de** algo que sabés / tenés / sos. Dos contraseñas no son MFA.

---

## Referencias

**Examen y guía de estudio**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Learning path: Describe Azure identity, access, and security — https://learn.microsoft.com/en-us/training/paths/describe-azure-identity-governance-privacy-compliance/

**Servicios de directorio**
- What is Microsoft Entra ID? — https://learn.microsoft.com/en-us/entra/fundamentals/whatis
- Compare AD DS, Microsoft Entra ID, and Microsoft Entra Domain Services — https://learn.microsoft.com/en-us/entra/identity/domain-services/compare-identity-solutions
- What is Microsoft Entra Domain Services? — https://learn.microsoft.com/en-us/entra/identity/domain-services/overview
- Microsoft Entra plans and pricing — https://www.microsoft.com/en-us/security/business/microsoft-entra-pricing
- Microsoft Entra ID feature comparison — https://learn.microsoft.com/en-us/entra/fundamentals/licensing

**Autenticación**
- Authentication methods in Microsoft Entra ID — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-methods
- Passwordless authentication options — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passwordless
- Microsoft Entra multifactor authentication — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-mfa-howitworks
- Conditional Access authentication strengths — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths
- Temporary Access Pass — https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass
- Single sign-on to applications — https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-single-sign-on
- Continuous access evaluation — https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation
- Microsoft identity platform access tokens — https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens

**Identidades externas**
- Microsoft Entra External ID overview — https://learn.microsoft.com/en-us/entra/external-id/external-identities-overview
- B2B collaboration overview — https://learn.microsoft.com/en-us/entra/external-id/what-is-b2b
- B2B direct connect — https://learn.microsoft.com/en-us/entra/external-id/b2b-direct-connect-overview
- Cross-tenant access settings — https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview
- Azure AD B2C overview — https://learn.microsoft.com/en-us/azure/active-directory-b2c/overview

**Conditional Access**
- What is Conditional Access? — https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview
- Building a Conditional Access policy — https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-policies
- Conditional Access templates — https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-policy-common
- Manage emergency access (break-glass) accounts — https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access
- Conditional Access What If tool — https://learn.microsoft.com/en-us/entra/identity/conditional-access/what-if-tool
- Security defaults — https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults
- Graph API: conditionalAccessPolicy resource — https://learn.microsoft.com/en-us/graph/api/resources/conditionalaccesspolicy

**Azure RBAC**
- What is Azure RBAC? — https://learn.microsoft.com/en-us/azure/role-based-access-control/overview
- Azure built-in roles — https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
- Understand Azure role definitions — https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions
- Understand scope for Azure RBAC — https://learn.microsoft.com/en-us/azure/role-based-access-control/scope-overview
- Understand Azure deny assignments — https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments
- Troubleshoot Azure RBAC — https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting
- Azure RBAC limits — https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshoot-limits
- Attribute-based access control (ABAC) — https://learn.microsoft.com/en-us/azure/role-based-access-control/conditions-overview
- Compare Azure RBAC and Microsoft Entra roles — https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-overview
- Elevate access to manage all Azure subscriptions — https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin
- Privileged Identity Management — https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure

**Workload identity**
- Managed identities for Azure resources — https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
- Workload identity federation — https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
- Configure a federated identity credential — https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust
- AKS workload identity — https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- Deploy and configure workload identity on AKS — https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster
- GitHub Actions: authenticate to Azure with OpenID Connect — https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect

**Zero Trust y defensa en profundidad**
- Zero Trust guidance center — https://learn.microsoft.com/en-us/security/zero-trust/
- Zero Trust deployment plan with Microsoft 365 / Azure — https://learn.microsoft.com/en-us/security/zero-trust/deploy/overview
- Zero Trust identity pillar — https://learn.microsoft.com/en-us/security/zero-trust/deploy/identity
- Azure security best practices and patterns — https://learn.microsoft.com/en-us/azure/security/fundamentals/best-practices-and-patterns
- Microsoft Cloud Security Benchmark — https://learn.microsoft.com/en-us/security/benchmark/azure/

**Microsoft Defender for Cloud**
- What is Microsoft Defender for Cloud? — https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-cloud-introduction
- Secure Score — https://learn.microsoft.com/en-us/azure/defender-for-cloud/secure-score-security-controls
- Defender for Cloud plans and pricing — https://learn.microsoft.com/en-us/azure/defender-for-cloud/plan-defender-for-servers-select-plan
- Defender CSPM — https://learn.microsoft.com/en-us/azure/defender-for-cloud/concept-cloud-security-posture-management
- Just-in-time VM access — https://learn.microsoft.com/en-us/azure/defender-for-cloud/just-in-time-access-overview
- Regulatory compliance dashboard — https://learn.microsoft.com/en-us/azure/defender-for-cloud/regulatory-compliance-dashboard

**Diagnóstico y herramientas**
- Microsoft Entra authentication and authorization error codes — https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
- Sign-in logs in Microsoft Entra ID — https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins
- `az role assignment` reference — https://learn.microsoft.com/en-us/cli/azure/role/assignment
- `az identity federated-credential` reference — https://learn.microsoft.com/en-us/cli/azure/identity/federated-credential
- `az security` reference — https://learn.microsoft.com/en-us/cli/azure/security
- Azure Policy definition structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure
- Bicep `Microsoft.Authorization/roleAssignments` — https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
- Terraform `azuread_conditional_access_policy` — https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/conditional_access_policy