# 2.4 — Describe Azure identity, access, and security

> **Exam**: AZ-900 (syllabus version 2026-07-20) · **Domain**: Describe Azure management and governance / Azure architecture and services · **Weight**: 9.62
> **Reader profile**: Platform Architect / SRE. The exam asks *what* each control is; this material also covers *how it is enforced at runtime*, *what breaks*, and *how you prove it works*.

---

## 1. The production problem

Consider a realistic estate: 1 Microsoft Entra tenant, 6 subscriptions across `prod`, `nonprod` and `sandbox`, ~180 engineers, 3 AKS clusters, ~40 CI/CD pipelines, a dozen SaaS applications, and a set of partner organizations that need access to a shared design portal.

The failure modes that this domain exists to prevent are not hypothetical:

1. **Standing privilege.** Somebody granted `Owner` at subscription scope to the platform team's group "temporarily" during a migration. Three years later, 42 people can delete the production subscription's resources, and nobody can name them without running a query.
2. **Long-lived secrets in CI.** A pipeline authenticates to Azure with a service principal client secret stored in a variable group. The secret has a 2-year expiry, is copied into three other pipelines, and appears in a `set -x` build log. Rotation requires a coordinated change across teams, so it never happens.
3. **The perimeter assumption.** The security model is "you are inside the VPN, therefore you are trusted." A phished credential from a contractor's unmanaged laptop is indistinguishable from a legitimate one, because the only signal checked is *username + password*.
4. **Data-plane bypass.** Storage accounts have `allowSharedKeyAccess = true`. Every RBAC role assignment on the storage account is decorative: anyone holding the 512-bit account key has full data access, unattributable in logs.
5. **No posture baseline.** Nobody can answer "which of our 2,400 resources are non-compliant with our own baseline, and which of those are actually reachable from the internet?" without a two-week manual audit.

Azure's answer is not one product. It is a **layered system** in which four distinct authorization surfaces cooperate, and the single most common architectural mistake is confusing them:

| Surface | Question it answers | Enforcement point | Failure signal |
|---|---|---|---|
| **Authentication** (Microsoft Entra ID) | *Who are you, and how strongly did you prove it?* | Entra ID token endpoint (`login.microsoftonline.com`) | `AADSTS*` error codes |
| **Conditional Access** | *Given who/where/what/how risky, should this token be issued at all — and with which claims?* | Entra ID token endpoint, post-authentication | `AADSTS53003`, `AADSTS50076` |
| **Azure RBAC** | *Is this principal allowed to perform this operation on this resource?* | Azure Resource Manager (`management.azure.com`) and RBAC-aware data planes | HTTP 403 `AuthorizationFailed` |
| **Azure Policy** | *Is the resource itself allowed to exist in this shape?* | ARM, at request admission time | HTTP 403 `RequestDisallowedByPolicy` |

> **Mental model to carry into the exam and into production:** *Entra ID says who you are. Conditional Access says under what conditions you may get a token. RBAC says what that identity may do. Azure Policy says what the resource may look like. Defender for Cloud says how badly you got all four wrong.*

---

## 2. Directory services

### 2.1 The three directories, and why they are not interchangeable

The most consequential misunderstanding in this domain is treating **Microsoft Entra ID** as "Active Directory in the cloud." It is not. It is a different product solving a different problem with different protocols.

| Dimension | **AD DS** (on-premises) | **Microsoft Entra ID** | **Microsoft Entra Domain Services** |
|---|---|---|---|
| Deployment model | You run domain controllers (VMs/hardware) | Multi-tenant PaaS, Microsoft-operated | Managed domain, Microsoft-operated, injected into *your* VNet |
| Primary purpose | Enterprise LAN identity for Windows | Internet-scale identity for apps & APIs | Lift-and-shift legacy apps that need Kerberos/LDAP but no DCs |
| Structure | Hierarchical: forest → domain → OU | **Flat**: no OUs, no forests, no domains-in-the-AD-sense | Hierarchical (single managed domain, custom OUs allowed) |
| Auth protocols | Kerberos, NTLM, LDAP | **OAuth 2.0, OpenID Connect, SAML 2.0, WS-Federation, SCIM** | Kerberos, NTLM, LDAP, LDAPS |
| Query interface | LDAP | **Microsoft Graph (REST)** | LDAP |
| Group Policy (GPO) | Yes, full | **No** | Yes (built-in GPOs, editable) |
| Domain join | Yes | **No** — "Entra joined" is a different, cloud registration | Yes |
| Schema extension | Yes | No (directory extensions / custom security attributes only) | **No** |
| Trusts | Two-way forest trusts | N/A (uses B2B / cross-tenant access instead) | One-way outbound forest trust to on-prem (Enterprise SKU+) |
| You get `Domain Admin`? | Yes | N/A | **No** — you get `AAD DC Administrators`, a delegated group |
| Sync direction | — | ← Entra Connect / Cloud Sync from AD DS | **One-way from Entra ID → managed domain**; writes do not flow back |
| Typical cost driver | DC VMs + licensing | Per-user licence tier | Per-hour SKU by object count |

**Architectural decision rule:**

- Application speaks OIDC/SAML/Graph → **Entra ID**. Nothing else.
- Application hard-requires Kerberos/LDAP and you refuse to run DCs in Azure → **Entra Domain Services**.
- You need schema extensions, two-way trusts, or `Domain Admin` → **AD DS on IaaS VMs**. Domain Services will not do it, and discovering that after migration is expensive.

**Hybrid trap (exam-relevant):** password writeback (self-service password reset writing back to on-premises AD) requires **Entra ID P1**, and the sync from Entra ID to Entra Domain Services is **one-way**. A password reset performed directly inside the managed domain is not visible to Entra ID; users must change passwords through Entra ID (or on-premises AD, which then syncs) for the managed domain to receive the hash.

### 2.2 The tenant / subscription / management group topology

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

Facts that are tested and that also matter operationally:

- A **subscription trusts exactly one tenant** at a time, and a subscription has **exactly one parent management group**.
- Management group hierarchy supports **6 levels** (root + 5). Role assignments and policy assignments **inherit downward** and are **additive**.
- The tenant is the **security boundary for identity**; the subscription is the **billing and, conventionally, the blast-radius boundary** for resources.
- Moving a subscription between tenants (`az account tenant`… is not a thing — it is a portal/support operation) **orphans every Azure RBAC assignment**, because the principal object IDs live in the old tenant. Plan a re-assignment run.

### 2.3 Licensing tiers — what you actually cannot do without paying

| Capability | Free | **P1** | **P2** | Entra ID Governance |
|---|:--:|:--:|:--:|:--:|
| SSO to SaaS & Azure resources | ✅ | ✅ | ✅ | ✅ |
| Security defaults (tenant-wide MFA baseline) | ✅ | ✅ | ✅ | ✅ |
| Self-service **password change** (cloud users) | ✅ | ✅ | ✅ | ✅ |
| Self-service **password reset** + **writeback to AD DS** | ❌ | ✅ | ✅ | ✅ |
| **Conditional Access** | ❌ | ✅ | ✅ | ✅ |
| Dynamic membership groups | ❌ | ✅ | ✅ | ✅ |
| Group-based licence assignment | ❌ | ✅ | ✅ | ✅ |
| Microsoft Entra Application Proxy | ❌ | ✅ | ✅ | ✅ |
| Connect Health monitoring | ❌ | ✅ | ✅ | ✅ |
| **Identity Protection** (risk detection, risk-based CA) | ❌ | ❌ | ✅ | ✅ |
| **Privileged Identity Management (PIM)** — JIT role elevation | ❌ | ❌ | ✅ | ✅ |
| Access reviews | ❌ | ❌ | ✅ | ✅ |
| Entitlement management, lifecycle workflows | ❌ | ❌ | ❌ | ✅ |

> **The two lines that decide your architecture:** *Conditional Access is P1.* *PIM and risk-based policy are P2.* If the budget stops at Free, your only tenant-wide control is **security defaults**, which is all-or-nothing and **mutually exclusive with any Conditional Access policy** — enabling CA requires disabling security defaults, and vice versa.

### 2.4 The object model

| Object | What it is | Lifecycle | Credential |
|---|---|---|---|
| **User** | Human (member or guest) | Managed / synced from AD DS | Password, FIDO2, Hello, certificate |
| **Group** | Security or Microsoft 365; assigned or dynamic | Manual or rule-driven | — |
| **App registration** | The *definition* of an application, global to its home tenant | Developer-owned | — |
| **Service principal** | The *local instance* of an app in a tenant; the thing RBAC actually targets | One per tenant per app | Client secret, certificate, **federated credential** |
| **Managed identity** | A service principal whose credential Azure creates, stores and rotates for you | System-assigned: tied to a resource. User-assigned: standalone resource | **None you ever see** |

**System-assigned vs user-assigned managed identity:**

| | System-assigned | User-assigned |
|---|---|---|
| Cardinality | 1:1 with a resource | N:M — many resources share one identity |
| Lifecycle | Deleted with the resource | Independent ARM resource |
| Role assignments survive resource re-creation? | **No** — new `principalId` every time | **Yes** |
| Good for | A single VM, a single Function App | Blue/green deployments, AKS workloads, VMSS fleets, anything IaC re-creates |

> **SRE rule:** if a Terraform `taint`/`replace` would destroy and recreate the resource, use a **user-assigned** identity. Otherwise every redeploy silently breaks authorization and you spend an hour on a 403.

### 2.5 CLI — inspecting the directory

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

Create a user-assigned managed identity and read back the two IDs that matter:

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

> `clientId` is what the **application** presents when requesting a token. `principalId` (the service principal object ID) is what **RBAC role assignments** target. Mixing them up produces a role assignment that references a nonexistent principal — which Azure will happily accept and which will never work.

---

## 3. Authentication methods

### 3.1 The single sign-on mechanic

SSO is not "one password everywhere." It is **token brokering**: the user authenticates once against Entra ID, receives a long-lived *refresh token* and a short-lived *access token*, and every subsequent application receives a fresh, scoped, signed token without a new credential prompt.

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

Consequences you must design around:

- An issued access token is **valid until it expires**; revoking a user does not instantly kill in-flight sessions. This is what **Continuous Access Evaluation (CAE)** fixes: for CAE-aware resources (Microsoft Graph, Exchange Online, SharePoint Online, Teams), Entra ID issues **long-lived tokens (up to ~28 h)** but the resource *subscribes* to critical events — account disabled, password changed, token revoked, network location change — and rejects the token in near real time. CAE trades token lifetime for revocation latency, and it is a strict improvement.
- SSO concentrates risk. One credential now opens everything, which is precisely why **MFA is not optional on an SSO estate** — it is the compensating control that makes SSO safe.

### 3.2 Authentication method comparison

The exam wants "MFA = two or more of *something you know / have / are*." Production wants **phishing resistance**, which is a stricter property: resistance to a real-time adversary-in-the-middle proxy (Evilginx-class) that relays both the password and the OTP.

| Method | Factors | Phishing-resistant | UX friction | Ops burden | Verdict |
|---|---|:--:|---|---|---|
| Password only | know | ❌ | low | low | Unacceptable for any privileged path |
| SMS / voice OTP | know + have | ❌ (SIM swap, AiTM relay) | medium | low | Legacy fallback only; Microsoft actively discourages |
| Software OATH TOTP | know + have | ❌ (relayable) | medium | low | Better than SMS, still relayable |
| **Authenticator push + number matching** | know + have | ⚠️ partial | low | low | Good default for the workforce; number matching kills MFA-fatigue attacks |
| **Authenticator passwordless phone sign-in** | have + know/are (device unlock) | ⚠️ partial | **very low** | low | Strong workforce default |
| **Windows Hello for Business** | have (TPM-bound) + know/are | ✅ | very low | medium (device provisioning) | Best for managed Windows fleet |
| **FIDO2 / passkey security key** | have + know/are | ✅ | low | medium (key distribution, loss handling) | **Best for admins and break-glass** |
| **Certificate-Based Authentication (CBA)** | have (smartcard/PIV) | ✅ | medium | high (PKI ownership) | Regulated / government estates |
| **Temporary Access Pass (TAP)** | have (time-boxed code) | ❌ by design | low | low | **Bootstrapping only**: onboarding, key loss recovery |

**Authentication strengths** turn this table into an enforceable control. Instead of granting "MFA" (any second factor), a Conditional Access policy can require the built-in **`Phishing-resistant MFA`** strength, which accepts only Windows Hello for Business, FIDO2, and CBA. This is the single highest-leverage identity control available, and it is what you apply to Global Administrators and to the Azure management plane.

### 3.3 CLI — enumerating registered methods and inspecting a token

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

Decode the access token to see *how* the session was authenticated — this is the fastest way to prove or disprove "MFA was enforced":

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

Reading this output:

| Claim | Meaning | What to check |
|---|---|---|
| `amr` | Authentication Methods References | `"mfa"` present ⇒ a second factor was satisfied. `["pwd"]` alone ⇒ single factor |
| `oid` | The immutable object ID of the principal | This — not `upn` — is what RBAC matches |
| `wids` | Entra **directory role** template IDs in the token | `b79fbf4d-…` is a well-known well-known ID; resolve it, do not guess |
| `scp` / `roles` | Delegated scopes / application permissions | `scp` ⇒ acting on behalf of a user; `roles` ⇒ app-only |
| `aud` | Intended audience | A Graph token will **not** work against ARM. Mismatched `aud` is a top-3 cause of 401 |

> **Never** paste a production access token into an online JWT decoder. It is a live bearer credential. Decode locally, as above.

---

## 4. External identities

Four distinct products live under this heading, and choosing wrong means rebuilding an authentication stack.

| | **B2B collaboration** | **B2B direct connect** | **Azure AD B2C** | **Microsoft Entra External ID** (external tenant) |
|---|---|---|---|---|
| Audience | Partner *employees* | Partner *employees*, Teams shared channels | Consumers / citizens (CIAM) | Consumers *and* business partners (CIAM, current-generation) |
| Object created in your tenant | **Guest user** (`UPN` = `partner_contoso.com#EXT#@yourtenant.onmicrosoft.com`) | **None** — no guest object at all | User in a **separate B2C tenant** | User in a **separate external tenant** |
| Who authenticates the user | Their **home** tenant | Their **home** tenant | Your B2C tenant | Your external tenant |
| Credential managed by | Partner | Partner | You | You |
| Branding | Your tenant's, limited | N/A | Fully custom (user flows / custom policies / IEF) | Fully custom |
| Social IdPs (Google, Facebook, Apple) | Limited (Google, one-time passcode) | ❌ | ✅ | ✅ |
| Scale target | Thousands of partners | Thousands | **Millions** | **Millions** |
| Conditional Access applies | ✅ (your tenant's policies) | ✅ (cross-tenant access settings) | ✅ (B2C-specific) | ✅ |
| Licensing | MAU-based, generous free tier | Included | MAU-based | MAU-based |
| Status | Current | Current | **Supported; new projects steered to External ID** | **Current direction** |

### 4.1 Cross-tenant access settings — the control that makes B2B safe

Default B2B behaviour is permissive: any invited guest from any tenant can be added. **Cross-tenant access settings** let you constrain inbound and outbound collaboration per-partner-tenant, and — critically — **trust the partner's MFA claim** so guests are not forced to re-register MFA in your tenant.

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

Configure a partner-specific policy that trusts their MFA and compliant-device claims:

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

> **Trade-off to state explicitly:** trusting a partner's MFA removes friction and duplicate MFA registration, but transfers assurance to *their* identity hygiene. Trust MFA from tenants you have a contractual security posture with; do not trust it by default.

---

## 5. Microsoft Entra Conditional Access

### 5.1 The evaluation engine

Conditional Access is an **if-then policy engine evaluated at token issuance**. It is the practical implementation of "verify explicitly."

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

Rules of the engine that are tested and that cause outages:

1. **All matching policies are evaluated. Every one must be satisfied.** Grant controls across policies are effectively `AND`-ed; within one policy you choose `Require all` or `Require one`.
2. **Block wins.** Any policy that evaluates to Block terminates the decision regardless of every Grant.
3. **Exclusions beat inclusions.** A user in both an included and an excluded group is **excluded**.
4. **CA runs after first-factor authentication.** The password is already validated when CA evaluates. CA cannot stop credential *verification*; it stops *token issuance*.
5. **Legacy authentication protocols (POP3, IMAP, SMTP AUTH, older Office) cannot perform interactive MFA.** They must be blocked with a dedicated policy targeting `Other clients`, otherwise they are a complete MFA bypass.

### 5.2 Reference policy set

A minimum viable production baseline is four policies, deployed in **report-only** first:

| # | Name | Target | Condition | Control |
|---|---|---|---|---|
| CA01 | Block legacy authentication | All users, excl. break-glass | Client app = *Exchange ActiveSync, Other clients* | **Block** |
| CA02 | Require MFA for all users | All users, excl. break-glass & service accounts | All cloud apps | Grant: **MFA** |
| CA03 | Phishing-resistant MFA for admins | Directory roles: Global Admin, Privileged Role Admin, Security Admin, User Access Admin | All cloud apps | Grant: **Authentication strength = Phishing-resistant MFA** |
| CA04 | Require compliant device for Azure management | All users, excl. break-glass | App = *Windows Azure Service Management API* | Grant: **MFA AND compliant device**; Session: sign-in frequency **4 h**, non-persistent browser |

### 5.3 Full policy manifest (Microsoft Graph JSON — the canonical representation)

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

> `797f4846-ba00-4fd7-ba43-dac1f8f63013` is the well-known application ID of the **Windows Azure Service Management API** — the resource behind the Azure portal, Azure CLI, and Azure PowerShell. Targeting it is how you protect the **control plane** specifically without touching Microsoft 365.
> `00000000-0000-0000-0000-000000000004` is the built-in **Phishing-resistant MFA** authentication strength policy.

Create it and read it back:

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

### 5.4 Same policy as Terraform (declarative estate)

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

### 5.5 The non-negotiable operational rules

1. **Break-glass accounts.** Two cloud-only accounts, `*.onmicrosoft.com` UPN (never a federated custom domain), FIDO2 keys stored in separate physical safes, permanently assigned Global Administrator, **excluded from every CA policy**, with an alert rule firing on any sign-in. Without these, a misconfigured CA policy locks every administrator out of the tenant with no recovery path other than a Microsoft support case.
2. **Report-only first, always.** Deploy every policy as `enabledForReportingButNotEnforced`, let it run for at least one full business cycle (7 days minimum, to catch weekly batch jobs), then read the report-only results out of the sign-in logs before enforcing.
3. **Test with What If.** The Conditional Access *What If* tool evaluates a hypothetical sign-in (user × app × device × location × risk) against the live policy set and returns which policies apply.
4. **Service accounts are the exception you must design, not discover.** A non-interactive workload cannot satisfy interactive MFA. Give it a **workload identity** (§7), scope it with a **workload identity Conditional Access policy** restricted to a named location, and exclude it from user-targeted MFA policies — explicitly, by object ID, never by "well, it isn't in the group."

---

## 6. Azure role-based access control (RBAC)

### 6.1 The three-part assignment

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

Semantics:

- **Additive union.** Effective permissions are the union of every assignment at every scope in the ancestor chain. There is no "deny by absence of a higher grant."
- **Inheritance is downward only.** `Reader` at the management group applies to every subscription, resource group and resource beneath it.
- **Deny assignments override grants**, but you cannot author them directly. They are created by Azure managed applications and by **deployment stacks** with deny settings.
- **Assignments are not instant.** Allow up to ~10 minutes for propagation to all ARM regional caches; the token also has to be refreshed if the change involves group membership.

### 6.2 Anatomy of a role definition

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

| Field | Governs | Evaluation |
|---|---|---|
| `Actions` | **Control plane** — operations on the resource *object* via ARM | Union of all matched |
| `NotActions` | Subtraction from `Actions` **within this definition only** | **Not a deny** — another role assignment can still grant it |
| `DataActions` | **Data plane** — operations on data *inside* the resource (blobs, secrets, queue messages) | Only meaningful for RBAC-aware data planes |
| `NotDataActions` | Subtraction from `DataActions` | Same caveat as `NotActions` |
| `AssignableScopes` | Where the definition may be *assigned* | Must be set; a management-group scope makes the role reusable across subscriptions |

> **The `NotActions` trap, tested and real:** `NotActions` is *not* a deny rule. If a principal holds this custom role **and** `Contributor` elsewhere in the chain, they can write authorization objects. Least privilege in Azure RBAC is achieved by **not granting the broader role**, not by subtracting from it.

Deploy it:

```console
$ az role definition create --role-definition @sre-diagnose-production.json \
    --query "{name:roleName, id:name, type:roleType}" -o json
{
  "id": "c58d1e7a-4b93-4f20-a6d5-88ef0c31b742",
  "name": "Platform SRE - Diagnose Production",
  "type": "CustomRole"
}
```

### 6.3 Azure RBAC vs Entra roles vs Azure Policy vs Key Vault access policies

This table is the single highest-yield thing in the domain. Confusing these produces both exam failures and production incidents.

| | **Azure RBAC** | **Microsoft Entra roles** | **Azure Policy** | **Key Vault access policies** (legacy) |
|---|---|---|---|---|
| Governs | Azure **resources** (VMs, storage, AKS…) | **Directory objects** (users, groups, apps, CA policies) | **Resource configuration/shape** | Data-plane ops on one vault |
| Example role | `Contributor`, `Storage Blob Data Reader` | `Global Administrator`, `User Administrator` | `Deny`, `Audit`, `DeployIfNotExists` | Get/List/Set on Secrets |
| Scope model | MG → Sub → RG → Resource | **Tenant-wide** (+ administrative units, scoped roles) | MG → Sub → RG | Single vault, no inheritance |
| Enforcement point | ARM + RBAC-aware data planes | Entra ID / Microsoft Graph | ARM admission | Key Vault itself |
| Effect model | **Allow** only (+ rare deny assignments) | Allow | **Deny / Audit / Modify / Deploy** | Allow |
| Denies possible | Rarely | No | **Yes — this is its job** | No |
| Managed in IaC as | `Microsoft.Authorization/roleAssignments` | Graph / `azuread` provider | `Microsoft.Authorization/policyDefinitions` | `Microsoft.KeyVault/vaults/accessPolicies` |
| Recommendation | ✅ | ✅ | ✅ | ⚠️ **Migrate to Azure RBAC** |

Two crossover facts:

- A **Global Administrator has no Azure RBAC permission by default.** They can *grant themselves* one by toggling **Access management for Azure resources**, which assigns `User Access Administrator` at root scope `/`. That toggle is one of the highest-value audit events in the tenant.
- Key Vault supports both models. **Azure RBAC is the recommended one**: access policies do not inherit, are not visible to `az role assignment list`, cap at 1,024 entries, and are invisible to most posture tooling.

### 6.4 Scale limits

| Limit | Value | Consequence |
|---|---|---|
| Role assignments per subscription | **4,000** | Assign to **groups**, never to users. A per-user model exhausts this |
| Role assignments per management group | 500 | Reserve MG scope for a handful of platform-wide roles |
| Custom role definitions per tenant | 5,000 | Ample; the constraint is human comprehension, not the limit |
| Management group nesting | 6 levels (root + 5) | Design the hierarchy before you need level 7 |
| Groups in a JWT before overage | ~200 (SAML ~150) | Beyond it, the token carries `hasgroups` + `_claim_names` and the app **must** call Graph. Group-based authorization silently breaks at scale |

> Verify against the live limits document before designing to a number — Azure limits change. The *shape* of the constraint (assign to groups; watch group overage) does not.

### 6.5 Full Bicep — least-privilege workload with a user-assigned managed identity

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

Deploy and confirm:

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

### 6.6 Enforcing the data-plane bypass closure with Azure Policy

RBAC on a storage account is meaningless while shared key access is enabled. This custom policy makes the closure structural rather than aspirational:

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

Verify the deny actually fires:

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

> **Distinguish the two 403s.** `RequestDisallowedByPolicy` means *the resource shape is forbidden* — Azure Policy. `AuthorizationFailed` means *you are not permitted to perform this operation* — Azure RBAC. Different subsystem, different fix.

### 6.7 Just-in-time privilege (PIM)

Standing `Owner`/`Contributor` is the single largest identity risk in most Azure estates. **Privileged Identity Management** (Entra ID P2) converts an assignment from *active* to *eligible*: the principal holds nothing until they activate, with justification, optional approval, MFA, and a maximum duration.

| | Standing assignment | **PIM eligible assignment** |
|---|---|---|
| Permission held while idle | Full | **None** |
| Blast radius of a stolen token | Full role | Read-only, until activation |
| Activation requires | — | MFA + justification (+ approver, + ticket ref) |
| Duration | Permanent | Time-boxed (e.g. 4 h), auto-expires |
| Audit trail | Only the operations | Operations **plus the reason and approver** |
| Cost | Included | Requires **Entra ID P2** |

PIM applies to both **Entra directory roles** and **Azure RBAC roles** (as *eligible* role assignments with the `Microsoft.Authorization/roleEligibilityScheduleRequests` API).

---

## 7. Workload identity — closing the CI/CD secret problem

This is the section that eliminates failure mode #2 from §1, and it is the modern answer to "how does a pipeline or a Pod authenticate to Azure without a secret."

| Approach | Secret material | Rotation | Blast radius if leaked | Works where |
|---|---|---|---|---|
| SP + **client secret** | Yes, a bearer string | Manual, expires (max 24 mo) | **Total, until expiry** — usable from anywhere | Anywhere |
| SP + **certificate** | Yes, a private key | Manual, expires | Total, until expiry | Anywhere |
| **Managed identity** (system/user-assigned) | **None** | Automatic, by Azure | Requires code execution *on the Azure resource* | Azure compute only |
| **Workload identity federation (OIDC)** | **None** | N/A — assertions are ~10 min | Requires control of the trusted OIDC subject | GitHub, GitLab, AKS, Azure DevOps, any OIDC IdP |

**Choose in this order: managed identity → workload identity federation → certificate → secret.** A client secret in a CI variable is a last resort with a documented expiry, not a default.

### 7.1 AKS workload identity — complete manifests

Enable the OIDC issuer and the mutating webhook on the cluster:

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

Verify the injection actually happened:

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

> The `iss`, `sub` and `aud` above must match the federated identity credential **byte for byte**. A namespace rename, a ServiceAccount rename, or a cluster rebuild (new issuer URL) all break the trust and produce `AADSTS70021`.

### 7.2 GitHub Actions — OIDC to Azure, zero secrets

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

> **Scope the federated credential subject as tightly as the workflow allows.** `repo:contoso/payments:ref:refs/heads/main` is better than `repo:contoso/payments:pull_request`; `repo:contoso/payments:environment:production` is better still, because a GitHub Environment adds required reviewers and branch restrictions on top. A subject of `repo:contoso/payments:*` — never write one — means any branch in that repository, including one a contributor opens, can deploy to production.

---

## 8. Zero Trust

Zero Trust is not a product. It is the design assumption that **the network location of a request carries no authorization value**.

### 8.1 Three guiding principles

| Principle | Meaning | Concrete Azure implementation |
|---|---|---|
| **Verify explicitly** | Authenticate and authorize on **all** available signals: identity, location, device health, service, workload, data classification, anomalies | Conditional Access with device compliance + authentication strengths + Identity Protection risk |
| **Use least privilege access** | Just-in-time, just-enough-access (JIT/JEA), risk-based adaptive policy, data protection | PIM eligible assignments, custom RBAC roles, ABAC conditions, JIT VM access |
| **Assume breach** | Minimise blast radius, segment access, verify end-to-end encryption, use analytics to drive detection and response | Network segmentation, private endpoints, Defender for Cloud + Microsoft Sentinel, CAE |

### 8.2 The six pillars, mapped to controls

| Pillar | Question | Primary Azure controls |
|---|---|---|
| **Identities** | Is the principal verified and least-privileged? | Entra ID, MFA/passwordless, Conditional Access, PIM, Identity Protection, access reviews |
| **Endpoints / devices** | Is the device known, healthy and compliant? | Intune compliance policies, Entra device join, CA `compliantDevice` grant, Defender for Endpoint |
| **Applications** | Are apps discovered, permissioned and monitored? | App registrations + consent policies, Defender for Cloud Apps, Application Proxy, session controls |
| **Data** | Is data classified, labelled and encrypted? | Purview Information Protection, encryption at rest/in transit, Defender for Storage, customer-managed keys |
| **Infrastructure** | Is configuration hardened and drift detected? | Azure Policy, Defender for Cloud, JIT VM access, Update Manager, Bicep/Terraform as the only write path |
| **Networks** | Is the network segmented and traffic inspected? | NSGs, Azure Firewall + IDPS, private endpoints, DDoS Protection, WAF, micro-segmentation |
| *(cross-cutting)* **Visibility, automation, orchestration** | Can you see and respond? | Azure Monitor, Log Analytics, Microsoft Sentinel, Logic Apps playbooks |

### 8.3 From perimeter to Zero Trust — the practical delta

| | Classic perimeter model | Zero Trust model |
|---|---|---|
| Trust anchor | Network location ("inside the VPN") | **Verified identity + verified device**, per request |
| Authentication frequency | Once, at VPN connect | Continuously (CAE, sign-in frequency) |
| Lateral movement | Trivial once inside | Constrained by per-resource authorization |
| Remote access | VPN into a flat network | Per-application access; Application Proxy / Private Access |
| Contractor with a personal laptop | Full network access | Blocked by device-compliance grant |
| Stolen credential | Full access | Blocked by MFA + risk + device state |
| Server-to-server auth | Shared secrets, IP allow-lists | Managed identities and workload identity federation |

---

## 9. Defense in depth

Defense in depth applies **independent, overlapping controls** so that no single failure produces a breach. The measure of a layer is not whether it works — it is what still holds when it does not.

| Layer | Objective | Azure controls | If this layer alone fails, what saves you |
|---|---|---|---|
| **Physical** | Prevent physical access to hardware | Microsoft datacentre controls, biometrics, secure media destruction — **your responsibility only for on-prem/hybrid** | Encryption at rest |
| **Identity & access** | Only verified principals get in; least privilege | Entra ID, MFA, Conditional Access, RBAC, PIM | Network segmentation + logging |
| **Perimeter** | Absorb volumetric attacks, filter at the edge | DDoS Protection, Azure Firewall, Front Door + WAF | NSGs and application-layer authz |
| **Network** | Limit lateral movement; segment | NSGs, ASGs, private endpoints, service endpoints, forced tunnelling, no public IPs | Host firewall, per-resource RBAC |
| **Compute** | Harden and patch hosts and containers | Update Manager, Defender for Servers, disk encryption, Trusted Launch, Pod Security Standards, image scanning | Application-layer authz, data encryption |
| **Application** | Eliminate application-layer vulnerabilities | Secure SDLC, secrets in Key Vault, dependency scanning, WAF rules, managed identity | Data encryption, monitoring |
| **Data** | Protect the asset itself | Encryption at rest (SSE/CMK) and in transit (TLS 1.2+), Purview classification, RBAC data-plane roles, soft delete + purge protection, immutable storage | Backups, and honest disclosure |

**CIA triad** — the property each layer defends:

| | Definition | Representative Azure control |
|---|---|---|
| **Confidentiality** | Only authorised principals can read it | Encryption, RBAC, private endpoints, Key Vault |
| **Integrity** | Data is not altered undetectably | Hashing/signing, immutable blob storage, file integrity monitoring, RBAC write scoping |
| **Availability** | Authorised principals can reach it when needed | Availability zones, DDoS Protection, backups, geo-redundancy, Site Recovery |

> **Practical corollary:** the storage account in §6.5 sets `allowSharedKeyAccess: false` **and** `publicNetworkAccess: Disabled` **and** `minimumTlsVersion: TLS1_2` **and** RBAC data roles. Any one of those alone is bypassable. Together, an attacker needs a valid Entra token, from a permitted network path, over a modern TLS session, with a matching data-plane role assignment.

---

## 10. Microsoft Defender for Cloud

### 10.1 What it is

Defender for Cloud is a **CNAPP** — a Cloud-Native Application Protection Platform — combining two functions that are often sold separately:

| Function | Acronym | Answers | Delivered as |
|---|---|---|---|
| Cloud Security Posture Management | **CSPM** | *Is my configuration wrong?* | Secure Score, recommendations, regulatory compliance dashboard, attack path analysis |
| Cloud Workload Protection | **CWPP** | *Is something attacking me right now?* | Defender plans: runtime alerts, EDR, malware scanning, behavioural detection |

Plus **DevOps security** (posture of Azure DevOps / GitHub / GitLab repositories) and **multicloud** connectors for AWS and GCP, which is why the estate view is not Azure-only.

### 10.2 Free vs paid — a precise boundary

| Capability | Foundational CSPM (**free**, on by default) | Defender CSPM (paid) | Defender workload plans (paid) |
|---|:--:|:--:|:--:|
| Secure Score | ✅ | ✅ | ✅ |
| Security recommendations | ✅ | ✅ | ✅ |
| Microsoft Cloud Security Benchmark assessment | ✅ | ✅ | ✅ |
| Asset inventory | ✅ | ✅ | ✅ |
| Multicloud (AWS/GCP) connectors | ✅ | ✅ | ✅ |
| **Attack path analysis** | ❌ | ✅ | — |
| **Cloud Security Explorer** (graph query) | ❌ | ✅ | — |
| Agentless vulnerability & secret scanning | ❌ | ✅ | — |
| Regulatory compliance packs beyond MCSB | ❌ | ✅ | — |
| **Threat detection / security alerts** | ❌ | ❌ | ✅ |
| Endpoint detection & response (via MDE) | ❌ | ❌ | ✅ (Servers) |
| Just-in-time VM access | ❌ | ❌ | ✅ (Servers P2) |
| File integrity monitoring | ❌ | ❌ | ✅ (Servers P2) |
| Malware scanning on upload | ❌ | ❌ | ✅ (Storage) |

> **The line that is examined:** posture assessment and Secure Score are **free and always on**. Anything that *detects an attack in progress* requires a paid Defender plan.

### 10.3 Plans and what each protects

| Plan | Protects | Signature capability |
|---|---|---|
| Defender for **Servers** P1 | Azure/AWS/GCP/on-prem (Arc) VMs | Microsoft Defender for Endpoint integration |
| Defender for **Servers** P2 | Same | + vulnerability assessment, JIT VM access, FIM, adaptive controls, 500 MB/day free ingestion |
| Defender for **Containers** | AKS/EKS/GKE/Arc-enabled K8s, registries | Registry image scanning, K8s audit-log detections, admission control via Azure Policy for Kubernetes |
| Defender for **Storage** | Storage accounts | On-upload malware scanning, sensitive data threat detection, anomalous access alerts |
| Defender for **Databases** | SQL (Azure/VM/Arc), open-source relational, Cosmos DB | SQL injection detection, anomalous query patterns |
| Defender for **Key Vault** | Vaults | Unusual secret access patterns, access from suspicious IPs/Tor |
| Defender for **Resource Manager** | The ARM control plane itself | Suspicious role assignments, `elevateAccess`, mass deletion, toolkit signatures |
| Defender for **App Service** | Web apps | Web-shell detection, dangling DNS |
| Defender for **APIs** | API Management-published APIs | Unauthenticated/exposed endpoints, sensitive-data exposure, API abuse |
| Defender for **AI Services** | Azure OpenAI / AI services | Prompt-injection and data-exfiltration detections |

### 10.4 Secure Score — how the number is computed

Recommendations are grouped into **security controls**. Each control has a maximum point value; you earn a fraction of it proportional to healthy resources.

```
control_score   = max_points × (healthy_resources / total_resources)
secure_score(%) = Σ control_score / Σ max_points × 100
```

Operational consequences:

- **A control is partially credited.** Remediating 8 of 10 VMs earns 80 % of that control's points, not zero.
- **Controls are weighted unequally.** "Enable MFA" carries far more weight than a cosmetic recommendation — Secure Score is a prioritised backlog, not a checklist.
- **Adding resources lowers the score without anything regressing.** Onboarding a new subscription increases `total_resources`. Track the score *per scope* and alert on *deltas*, not on the absolute number.
- **The score is not a compliance status.** Use the **Regulatory compliance** dashboard for that; the default assigned initiative is the **Microsoft Cloud Security Benchmark (MCSB)**.

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

Wire alerts into email and to a Log Analytics workspace so they reach the on-call rotation rather than a portal blade nobody opens:

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

## 11. Verification and failure diagnosis

### 11.1 The `AuthorizationFailed` runbook

This is the most common 403 in Azure and it has exactly six causes.

```console
$ az storage blob list --account-name stpayproda9f31c4e --container-name settlements --auth-mode login
(AuthorizationPermissionMismatch) This request is not authorized to perform this operation using this permission.
RequestId:8f2a1c07-501e-004c-3d19-b7c4e2000000
Time:2026-09-06T09:12:41.7710233Z
```

Work the ladder in order — each step eliminates one cause:

**Step 1 — Confirm which principal you actually are.** More outages come from being signed in as the wrong identity than from any misconfiguration.

```console
$ az account show --query "{sub:name, user:user.name, type:user.type}" -o json
{
  "sub": "sub-prod-eu",
  "type": "servicePrincipal",
  "user": "4c7b2e91-6d38-4a05-9f27-b3e1c8a04d56"
}
```

**Step 2 — Enumerate every effective assignment, including inherited and group-derived ones.** The default `az role assignment list` shows neither, which is why "I checked and the role is there" is so often wrong.

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

**Diagnosis:** `Contributor` is a **control-plane** role. It grants `Microsoft.Storage/storageAccounts/*` — including `listKeys` — but it carries **no `DataActions`**. Reading a blob's *content* requires a data role.

**Step 3 — Prove it against the role definition rather than from memory.**

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

`"dataActions": null` — confirmed.

**Step 4 — Fix at the narrowest scope that works.**

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

**Step 5 — Wait for propagation, then re-verify. Do not conclude "it did not work" inside the first 10 minutes.**

```console
$ sleep 120 && az storage blob list --account-name stpayproda9f31c4e --container-name settlements --auth-mode login -o table
Name                              Blob Type    Blob Tier    Length     Content Type              Last Modified
--------------------------------  -----------  -----------  ---------  ------------------------  -------------------------
2026/09/05/settlement-eu.parquet  BlockBlob    Hot          18874368   application/octet-stream  2026-09-05T23:58:11+00:00
2026/09/06/settlement-eu.parquet  BlockBlob    Hot          19398656   application/octet-stream  2026-09-06T05:02:47+00:00
```

**Step 6 — If it still fails, use the authoritative check.** `az role assignment list` shows assignments; `checkAccess` evaluates the **effective decision**, including deny assignments and ABAC conditions.

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

### 11.2 `AADSTS` error decoder

Every Entra ID authentication failure carries an `AADSTS` code. Memorising the top ones converts a 30-minute investigation into a 30-second one.

| Code | Meaning | First thing to check |
|---|---|---|
| `AADSTS50126` | Invalid username or password | Genuine bad credential — or a federated domain routing the sign-in elsewhere |
| `AADSTS50076` | MFA required, interaction needed | CA policy demanding MFA on a non-interactive flow. Give the workload a workload identity |
| `AADSTS50079` | User must enrol in MFA | Registration campaign / policy hit an unregistered user. Issue a **TAP** |
| `AADSTS53003` | **Blocked by Conditional Access** | Read the sign-in log entry: it names the exact policy. Check inclusions vs exclusions |
| `AADSTS530003` | Device is not compliant | Intune compliance state; device not enrolled or evaluation stale |
| `AADSTS50105` | User is not assigned a role for the application | App has *user assignment required* = Yes and this user/group is not assigned |
| `AADSTS50158` | External security challenge not satisfied | A custom control / third-party MFA did not complete |
| `AADSTS700016` | Application not found in the directory | Wrong tenant, or the SP was never created in this tenant (`az ad sp create --id <appId>`) |
| `AADSTS7000215` | Invalid client secret | Secret expired, rotated, or has a trailing newline. **Move to workload identity federation** |
| `AADSTS700024` | Client assertion is not within its valid time range | Clock skew on the runner, or a stale cached assertion |
| **`AADSTS70021`** | **No matching federated identity record found for the presented assertion** | `issuer`/`subject`/`audience` mismatch. The #1 workload-identity failure |
| `AADSTS500011` | Resource principal not found in the tenant | Wrong `--resource`/scope; the resource's SP does not exist in this tenant |
| `AADSTS900023` | Invalid tenant name / ID | Typo, or authenticating against the wrong cloud (`AzureUSGovernment` vs `AzureCloud`) |
| `AADSTS50177` | External user account does not exist in the tenant | B2B guest was never redeemed, or was removed |

### 11.3 Diagnosing `AADSTS70021` end to end

Symptom, from a Pod:

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

Compare the three fields against the registered credential — the error message conveniently prints all three:

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

**Diagnosis:** subject namespace is `payments-api` in the federated credential, but the Pod runs in `payments`. Subject matching is exact and case-sensitive.

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

**`AADSTS70021` checklist, in the order that finds it fastest:**

1. `subject` — namespace *and* ServiceAccount name, exact and case-sensitive.
2. `issuer` — the AKS OIDC issuer URL, **including the trailing slash**. A rebuilt cluster has a *new* issuer.
3. `audiences` — must be `api://AzureADTokenExchange`.
4. The Pod template carries the label `azure.workload.identity/use: "true"`.
5. The ServiceAccount annotation `azure.workload.identity/client-id` holds the **clientId**, not the principalId.
6. The webhook is running: `kubectl -n kube-system get pods -l azure-workload-identity.io/system=true`.

### 11.4 Diagnosing "Conditional Access blocked something"

`AADSTS53003` names the policy — but only in the sign-in log, not in the client error. Get the log:

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

Everything needed is here: policy `CA04`, grant control not met, `isCompliant: false` on an unmanaged macOS device. The control worked as designed; the remediation is device enrolment, not a policy exclusion.

Read report-only results **before** enforcing — this is the query that prevents the outage:

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

If that returns 400 users across 6 applications, enforcing the policy tomorrow is an outage. If it returns 3 known-unmanaged devices, enforce it.

### 11.5 Conditional Access What If — test before you break

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

### 11.6 Managed identity not working on a VM

```console
$ curl -sS -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" | jq
{
  "error": "invalid_request",
  "error_description": "Identity not found"
}
```

`Identity not found` from IMDS means the **identity is not attached to the resource** — this is an ARM configuration problem, not a token problem:

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

> With **more than one** user-assigned identity attached, IMDS **requires disambiguation**: append `&client_id=<clientId>`. Omitting it returns `multiple_matching_identities`. This is a frequent surprise on VMSS with multiple workloads.

### 11.7 Standing detection queries

Put these in a Log Analytics workspace or Microsoft Sentinel and alert on them. They cover the highest-signal identity events in an Azure estate.

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

### 11.8 Pre-production verification checklist

| # | Check | Command / evidence | Pass criterion |
|---|---|---|---|
| 1 | No standing Owner at subscription scope for humans | `az role assignment list --scope /subscriptions/<id> --role Owner --include-groups -o table` | Only break-glass and PIM-eligible entries |
| 2 | Every role assignment targets a group or a workload identity, never a user | same, `--query "[?principalType=='User']"` | Empty |
| 3 | Break-glass excluded from all CA policies | Graph `conditionalAccess/policies`, grep excluded groups | Present in every policy |
| 4 | Legacy auth blocked | KQL query 3 above | 0 successful sign-ins |
| 5 | Admins require phishing-resistant MFA | CA03 exists, `state == enabled` | ✅ |
| 6 | No CI/CD client secrets | `az ad app credential list --id <appId>` for each CI app | `passwordCredentials` empty |
| 7 | Federated credentials scoped to an environment or a branch, never a wildcard | `az ad app federated-credential list` | No `*` in `subject` |
| 8 | Key Vaults in RBAC mode | `az keyvault list --query "[?!properties.enableRbacAuthorization].name"` | Empty |
| 9 | Storage shared keys disabled | `az storage account list --query "[?allowSharedKeyAccess].name"` | Empty |
| 10 | Defender plans enabled on production subscriptions | `az security pricing list -o table` | Required plans `Standard` |
| 11 | Secure Score trend recorded per scope | `az security secure-score list` | Tracked, alert on negative delta |
| 12 | CA policies deployed report-only for ≥7 days before enforcement | KQL report-only query | Reviewed, exceptions documented |

---

## 12. Exam-focused distillations

Highest-confusion pairs, resolved in one line each:

| If the question says… | The answer is… | Because |
|---|---|---|
| "manage users, groups and app registrations" | **Microsoft Entra roles** (e.g. User Administrator) | Directory objects, not Azure resources |
| "manage VMs, storage, networks" | **Azure RBAC** (e.g. Contributor) | Azure resources via ARM |
| "prevent a resource from being created in the wrong shape/region/SKU" | **Azure Policy** | RBAC has no deny for shape; Policy does |
| "an app needs Kerberos/LDAP without running domain controllers" | **Microsoft Entra Domain Services** | Entra ID does not speak Kerberos or LDAP |
| "partner employees need access to our SharePoint" | **B2B collaboration** | Guest object, partner's home tenant authenticates |
| "a million consumers sign in with Google or a local account" | **Azure AD B2C / Microsoft Entra External ID** | CIAM scale, separate tenant, custom branding |
| "require MFA only when sign-in risk is high" | **Conditional Access + Identity Protection (P2)** | Risk signals require P2 |
| "grant admin rights only for 4 hours with approval" | **PIM (P2)** | Eligible, not active, assignments |
| "no password at all, cannot be phished" | **FIDO2 / Windows Hello for Business / CBA** | Cryptographic, origin-bound |
| "never trust, always verify, assume breach" | **Zero Trust** | The three guiding principles |
| "multiple independent layers so one failure is not a breach" | **Defense in depth** | Physical → identity → perimeter → network → compute → app → data |
| "show me my security posture score and how to improve it" | **Microsoft Defender for Cloud** (Secure Score, free CSPM) | Posture is free; threat detection is paid |
| "alert me that a VM is being attacked right now" | **Defender for Cloud, paid workload plan** | Detection requires a Defender plan |
| "the free tenant-wide MFA baseline" | **Security defaults** | Free; mutually exclusive with Conditional Access |

Ten facts most likely to appear verbatim:

1. Entra ID is **flat** — no OUs, no GPOs, no Kerberos, no LDAP.
2. **Conditional Access requires Entra ID P1**; PIM and Identity Protection require **P2**.
3. **Security defaults and Conditional Access are mutually exclusive.**
4. A subscription trusts **one** tenant; a management group hierarchy is **6 levels** deep including root.
5. Azure RBAC is **additive**; `NotActions` subtracts within a definition and is **not** a deny.
6. **Deny assignments override allow**, and you cannot author them by hand.
7. Zero Trust: **verify explicitly, least privilege, assume breach**.
8. Defense in depth layers: **physical, identity & access, perimeter, network, compute, application, data**.
9. Defender for Cloud's **CSPM/Secure Score is free**; **workload protection plans cost money**.
10. **MFA = two or more of** something you know / have / are. Two passwords is not MFA.

---

## Referencias

**Exam and study guide**
- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Microsoft Certified: Azure Fundamentals — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/
- Learning path: Describe Azure identity, access, and security — https://learn.microsoft.com/en-us/training/paths/describe-azure-identity-governance-privacy-compliance/

**Directory services**
- What is Microsoft Entra ID? — https://learn.microsoft.com/en-us/entra/fundamentals/whatis
- Compare AD DS, Microsoft Entra ID, and Microsoft Entra Domain Services — https://learn.microsoft.com/en-us/entra/identity/domain-services/compare-identity-solutions
- What is Microsoft Entra Domain Services? — https://learn.microsoft.com/en-us/entra/identity/domain-services/overview
- Microsoft Entra plans and pricing — https://www.microsoft.com/en-us/security/business/microsoft-entra-pricing
- Microsoft Entra ID feature comparison — https://learn.microsoft.com/en-us/entra/fundamentals/licensing

**Authentication**
- Authentication methods in Microsoft Entra ID — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-methods
- Passwordless authentication options — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passwordless
- Microsoft Entra multifactor authentication — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-mfa-howitworks
- Conditional Access authentication strengths — https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths
- Temporary Access Pass — https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass
- Single sign-on to applications — https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-single-sign-on
- Continuous access evaluation — https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation
- Microsoft identity platform access tokens — https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens

**External identities**
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

**Zero Trust and defense in depth**
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

**Diagnostics and tooling**
- Microsoft Entra authentication and authorization error codes — https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
- Sign-in logs in Microsoft Entra ID — https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins
- `az role assignment` reference — https://learn.microsoft.com/en-us/cli/azure/role/assignment
- `az identity federated-credential` reference — https://learn.microsoft.com/en-us/cli/azure/identity/federated-credential
- `az security` reference — https://learn.microsoft.com/en-us/cli/azure/security
- Azure Policy definition structure — https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure
- Bicep `Microsoft.Authorization/roleAssignments` — https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
- Terraform `azuread_conditional_access_policy` — https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/conditional_access_policy