# AZ-900 — Topic 2.4: Describe Azure Identity, Access, and Security

## Guided Exercises

> **Exam weight:** 9.62 % — the largest single block of Domain 2. Everything here is *describe*-level on the exam, but the exercises below are written at operator level: you will see the real control plane, not a diagram of it.

---

## 0. Lab conventions and safety rules

Read this section before running anything. Identity is the one Azure surface where a careless `POST` locks **you** out of the tenant you are working in.

| Rule | Why |
|---|---|
| Use a **dedicated dev/test tenant** (Microsoft 365 Developer Program or a trial), never a production tenant. | Conditional Access and authentication-method policies are tenant-wide. |
| Create a **break-glass (emergency access) account** *before* Block 4, exclude it from every Conditional Access policy, and store its credential offline. | Microsoft's own guidance: at least two cloud-only emergency accounts, excluded from CA, not covered by MFA that can fail. |
| Every Conditional Access policy you create in this lab is created with `"state": "enabledForReportingButNotEnforced"` (report-only). | Report-only evaluates and logs the outcome without blocking anyone. |
| Prefer `--output table` for reading, `--output json` for scripting, `--query` (JMESPath) to prove a fact. | You will be asked to *prove* claims, not eyeball them. |
| Delete what you create (Block 10). | Guest users, custom roles and Defender plans all persist and some bill. |

### Tooling

```bash
# Azure CLI 2.60+ recommended; verify
az version --output table
```

```
Name                       Version
-------------------------  ---------
azure-cli                  2.67.0
azure-cli-core             2.67.0
azure-cli-telemetry        1.1.0
```

```bash
# Sign in interactively; --allow-no-subscriptions lets you work in a tenant
# where your account has directory roles but no Azure subscription.
az login --allow-no-subscriptions

# Pin the working subscription explicitly. Never rely on the default.
export SUB_ID="$(az account show --query id -o tsv)"
export TENANT_ID="$(az account show --query tenantId -o tsv)"
export RG="rg-az900-identity-lab"
export LOC="eastus"
echo "sub=$SUB_ID tenant=$TENANT_ID"
```

Azure CLI's `az ad *` commands talk to **Microsoft Graph**, not to the retired Azure AD Graph. Where no first-class command exists, we drop to `az rest`, which reuses your CLI token:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/organization" \
  --query "value[].{name:displayName, tenantId:id, type:tenantType}" -o table
```

```
Name              TenantId                              Type
----------------  ------------------------------------  --------
Contoso Lab       8f7c0e3a-1d44-4b2e-9a51-0c9b2f6ad7e1  AAD
```

---

## Block 1 — Directory services: Microsoft Entra ID and Entra Domain Services

**Concept under test:** Entra ID is *not* Active Directory Domain Services in the cloud. It is a different protocol family for a different problem.

### Steps

1. Identify the directory you are signed in to and the identity you are signed in as.

   ```bash
   az ad signed-in-user show \
     --query "{upn:userPrincipalName, id:id, type:userType, onPrem:onPremisesSyncEnabled}" -o table
   ```

   ```
   Upn                          Id                                    Type    OnPrem
   ---------------------------  ------------------------------------  ------  --------
   admin@contosolab.onmicrosoft.com  3b1e8f22-9c07-4d5a-8e11-6f0a2c4b93d7  Member
   ```

   `onPremisesSyncEnabled` is `null` for a cloud-only account and `true` for an account projected into Entra ID by **Microsoft Entra Connect Sync** / **Cloud Sync**.

2. Enumerate the directory's users and classify them by `userType`.

   ```bash
   az ad user list --query "[].{upn:userPrincipalName, type:userType, enabled:accountEnabled}" -o table
   ```

   ```
   Upn                                                   Type    Enabled
   ----------------------------------------------------  ------  ---------
   admin@contosolab.onmicrosoft.com                       Member  True
   bgl-emergency-01@contosolab.onmicrosoft.com            Member  True
   svc-pipeline@contosolab.onmicrosoft.com                Member  True
   ```

3. Create a security group. Groups — not users — are the unit of access assignment in every well-run tenant.

   ```bash
   az ad group create \
     --display-name "sg-az900-platform-readers" \
     --mail-nickname "sg-az900-platform-readers" \
     --description "Read-only platform access for the AZ-900 lab" \
     --query "{id:id, name:displayName, securityEnabled:securityEnabled}" -o json
   ```

   ```json
   {
     "id": "c4a2e77b-3f19-4a0d-9d6e-51bb8c2ff4a3",
     "name": "sg-az900-platform-readers",
     "securityEnabled": true
   }
   ```

   ```bash
   export GROUP_ID="c4a2e77b-3f19-4a0d-9d6e-51bb8c2ff4a3"
   ```

4. Inspect what a **service principal** looks like — the non-human identity Entra ID issues to applications. Note it lives in the same directory as your users.

   ```bash
   az ad sp list --filter "startswith(displayName,'Microsoft Graph')" \
     --query "[].{name:displayName, appId:appId, type:servicePrincipalType}" -o table
   ```

5. Look at the *protocol* boundary. Entra ID publishes an OpenID Connect discovery document; AD DS publishes nothing of the sort.

   ```bash
   curl -s "https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration" \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["token_endpoint"]); print(d["issuer"]); print(", ".join(d["response_types_supported"]))'
   ```

   ```
   https://login.microsoftonline.com/8f7c0e3a-1d44-4b2e-9a51-0c9b2f6ad7e1/oauth2/v2.0/token
   https://login.microsoftonline.com/8f7c0e3a-1d44-4b2e-9a51-0c9b2f6ad7e1/v2.0
   code, id_token, code id_token, id_token token
   ```

6. Read (do not create — it bills continuously) what a **Microsoft Entra Domain Services** managed domain would look like as an ARM resource:

   ```bash
   az provider show --namespace Microsoft.AAD \
     --query "resourceTypes[?resourceType=='DomainServices'].{type:resourceType, apiVersions:apiVersions[0]}" -o table
   ```

   ```
   Type            ApiVersions
   --------------  -------------
   DomainServices  2022-12-01
   ```

   An Entra Domain Services instance is deployed **into a virtual network subnet**, is billed hourly, and exposes **LDAP, Kerberos, NTLM and Group Policy** to VMs on that VNet. Entra ID itself exposes none of those.

### Comprehension questions — Block 1

- **Q1.** A legacy line-of-business application authenticates users with Kerberos and reads its OU structure over LDAP. The team wants to lift-and-shift it to Azure VMs without deploying and patching domain controllers. Which of the three directory options — Entra ID, Entra Domain Services, AD DS on IaaS VMs — fits, and what is disqualifying about each of the other two?
- **Q2.** In step 1, `onPremisesSyncEnabled` was `null`. What would `true` tell you about where that user object is *mastered*, and what is the practical consequence for `az ad user update --display-name`?
- **Q3.** Entra ID is described as "identity as a service." Name two protocols it speaks and two protocols it does **not** speak.
- **Q4.** Is a Microsoft Entra Domain Services managed domain a replica of your on-premises AD DS forest? Justify in terms of the direction of synchronization.
- **Q5.** Why does the tenant contain service principals alongside users? What single security property is lost if an automation pipeline signs in with a human user's credentials instead?

---

## Block 2 — Authentication methods: SSO, MFA, and passwordless

**Concept under test:** authentication proves *who*; the strength of that proof is a policy decision, and the policy is machine-readable.

### Steps

1. Read the tenant's **authentication methods policy** — the single object that governs which methods users may register and use.

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" \
     --query "authenticationMethodConfigurations[].{method:id, state:state}" -o table
   ```

   ```
   Method                     State
   -------------------------  --------
   Fido2                      disabled
   MicrosoftAuthenticator     enabled
   Sms                        disabled
   TemporaryAccessPass        disabled
   HardwareOath               disabled
   SoftwareOath               enabled
   Voice                      disabled
   Email                      disabled
   X509Certificate            disabled
   QrCodePin                  disabled
   ```

2. Inspect the FIDO2 configuration in detail. This is the **phishing-resistant passwordless** method.

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/policies/authenticationMethodConfigurations/Fido2" -o json
   ```

   ```json
   {
     "@odata.type": "#microsoft.graph.fido2AuthenticationMethodConfiguration",
     "id": "Fido2",
     "state": "disabled",
     "isAttestationEnforced": true,
     "isSelfServiceRegistrationAllowed": true,
     "keyRestrictions": {
       "aaGuids": [],
       "enforcementType": "block",
       "isEnforced": false
     },
     "includeTargets": [
       { "targetType": "group", "id": "all_users", "isRegistrationRequired": false }
     ]
   }
   ```

   `isAttestationEnforced: true` means Entra ID verifies the authenticator's manufacturer attestation against the FIDO Alliance Metadata Service — the tenant will refuse an unattested or software-emulated key. `keyRestrictions.aaGuids` would pin specific hardware models.

3. Enable FIDO2 for the lab group only (least blast radius). Graph requires the **full** configuration object on `PATCH`:

   ```bash
   az rest --method PATCH \
     --url "https://graph.microsoft.com/v1.0/policies/authenticationMethodConfigurations/Fido2" \
     --headers "Content-Type=application/json" \
     --body "{
       \"@odata.type\": \"#microsoft.graph.fido2AuthenticationMethodConfiguration\",
       \"id\": \"Fido2\",
       \"state\": \"enabled\",
       \"isAttestationEnforced\": true,
       \"isSelfServiceRegistrationAllowed\": true,
       \"includeTargets\": [
         { \"targetType\": \"group\", \"id\": \"${GROUP_ID}\", \"isRegistrationRequired\": false }
       ]
     }"
   ```

   A successful `PATCH` returns HTTP 204 with no body. Re-run step 1 to confirm `Fido2  enabled`.

4. Query **who has actually registered what**. Registration state, not policy state, is what survives an incident. (This report requires Microsoft Entra ID P1 or P2.)

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails" \
     --query "value[].{upn:userPrincipalName, mfa:isMfaRegistered, passwordless:isPasswordlessCapable, methods:join(',',methodsRegistered)}" -o table
   ```

   ```
   Upn                                          Mfa    Passwordless  Methods
   -------------------------------------------  -----  ------------  -----------------------------------------
   admin@contosolab.onmicrosoft.com             True   False         microsoftAuthenticatorPush,softwareOneTimePasscode
   bgl-emergency-01@contosolab.onmicrosoft.com  False  False
   svc-pipeline@contosolab.onmicrosoft.com      False  False
   ```

5. Observe **SSO** empirically. Acquire a token for one resource, then a second, and compare the sign-in count. From a browser signed in to `portal.azure.com`, open `https://myapps.microsoft.com` — no credential prompt appears. From the CLI, the equivalent is a silent second token issuance from the cached refresh token:

   ```bash
   az account get-access-token --resource "https://graph.microsoft.com" \
     --query "{resource:resource, expires:expiresOn}" -o table
   az account get-access-token --resource "https://management.azure.com" \
     --query "{resource:resource, expires:expiresOn}" -o table
   ```

   ```
   Resource                      Expires
   ----------------------------  -------------------
   https://graph.microsoft.com   2026-09-06 15:41:22
   Resource                       Expires
   -----------------------------  -------------------
   https://management.azure.com   2026-09-06 15:41:24
   ```

   Two access tokens, two different audiences, **one** authentication. That is SSO: the primary refresh token is exchanged for per-resource access tokens without re-proving identity.

6. Classify the methods you saw in step 1 into the three authentication factors, and separately into "passwordless / not passwordless" and "phishing-resistant / not phishing-resistant." Write your table before reading the answers.

### Comprehension questions — Block 2

- **Q6.** SMS one-time passcode and a FIDO2 security key both satisfy "multi-factor." Explain the concrete attack that defeats the first and not the second, and name the property that makes the difference.
- **Q7.** In step 3 you set `state: enabled` for FIDO2 but scoped `includeTargets` to one group. Did this *require* anyone to use FIDO2? Which Azure control would?
- **Q8.** A user reports "I signed in once this morning and I've been able to open Teams, the Azure portal and our SaaS expenses app all day without another prompt." Is this a misconfiguration? Name the token that makes it work and the two categories of control that can shorten it.
- **Q9.** Why is a **Temporary Access Pass (TAP)** categorized as an *onboarding* credential rather than a steady-state one? What problem does it solve for a brand-new employee who owns no registered method?
- **Q10.** Is "password + security question" multi-factor authentication? Justify using the three-factor taxonomy.
- **Q11.** Your break-glass account has no MFA registered (step 4, `isMfaRegistered: False`). Defend or refute this configuration.

---

## Block 3 — External identities: B2B and B2C

**Concept under test:** two products, two directions of trust, two tenant topologies.

### Steps

1. Invite a **B2B guest**. Use an address you control at another domain.

   ```bash
   az rest --method POST \
     --url "https://graph.microsoft.com/v1.0/invitations" \
     --headers "Content-Type=application/json" \
     --body '{
       "invitedUserEmailAddress": "partner.analyst@fabrikam.example",
       "invitedUserDisplayName": "Partner Analyst (Fabrikam)",
       "inviteRedirectUrl": "https://myapps.microsoft.com",
       "sendInvitationMessage": true,
       "invitedUserMessageInfo": {
         "customizedMessageBody": "AZ-900 lab — read-only access to the shared cost dashboard."
       }
     }' \
     --query "{status:status, user:invitedUser.id, redeemUrl:inviteRedeemUrl}" -o json
   ```

   ```json
   {
     "status": "PendingAcceptance",
     "user": "9d2b6f14-77ac-4e39-b0c8-2a53e1f80b6d",
     "redeemUrl": "https://login.microsoftonline.com/redeem?rd=https%3a%2f%2finvitations.microsoft.com%2fredeem%2f..."
   }
   ```

2. Verify how the guest is represented in **your** directory.

   ```bash
   az ad user list --filter "userType eq 'Guest'" \
     --query "[].{upn:userPrincipalName, mail:mail, type:userType, state:externalUserState}" -o table
   ```

   ```
   Upn                                                              Mail                             Type   State
   ---------------------------------------------------------------  -------------------------------  -----  -----------------
   partner.analyst_fabrikam.example#EXT#@contosolab.onmicrosoft.com  partner.analyst@fabrikam.example  Guest  PendingAcceptance
   ```

   Read the UPN carefully: `#EXT#@yourtenant`. There is a **user object** in your tenant, but there is **no credential** in your tenant. Authentication is delegated to Fabrikam's identity provider; your tenant only authorizes.

3. Add the guest to the lab group. This is the whole point of B2B: external people become assignable subjects of your normal access model.

   ```bash
   export GUEST_ID="9d2b6f14-77ac-4e39-b0c8-2a53e1f80b6d"
   az ad group member add --group "$GROUP_ID" --member-id "$GUEST_ID"
   az ad group member list --group "$GROUP_ID" --query "[].{name:displayName, type:userType}" -o table
   ```

4. Inspect the tenant's **external collaboration settings** — the guard rails on who may invite whom.

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" \
     --query "{guestRole:guestUserRoleId, whoCanInvite:allowInvitesFrom, usersCanCreateApps:defaultUserRolePermissions.allowedToCreateApps}" -o json
   ```

   ```json
   {
     "guestRole": "10dae51f-b6af-4016-8d66-8c2a99b929b3",
     "whoCanInvite": "everyone",
     "usersCanCreateApps": true
   }
   ```

   `10dae51f-…` is the **Guest User** template (restricted directory read). `2af84b1e-…` is *Restricted Guest* (no directory read). `a0b1b346-…` is *User* — a guest with the same directory permissions as a member, which is almost always wrong.

5. Contrast with **B2C**. There is nothing to inspect in your workforce tenant, and that is the lesson:

   ```bash
   az rest --method GET --url "https://graph.microsoft.com/v1.0/organization" \
     --query "value[].{name:displayName, type:tenantType}" -o table
   ```

   ```
   Name         Type
   -----------  ------
   Contoso Lab  AAD
   ```

   A B2C tenant reports `tenantType: "AAD B2C"`, is a **separate tenant with its own directory, its own user objects and its own sign-up user flows**, and is created from a different portal blade. Its consumers never appear in your workforce tenant. (Microsoft's current-generation offering for this scenario is **Microsoft Entra External ID for customers**; Azure AD B2C remains supported and is what the AZ-900 study guide names.)

### Comprehension questions — Block 3

- **Q12.** A guest's home tenant disables their account on their last day at Fabrikam. What happens the next time they try to open your shared dashboard, and *why* — trace the failure to the exact step in the flow.
- **Q13.** In step 2 the guest has a user object in your tenant but no password there. Which tenant enforces MFA on that sign-in — theirs, yours, or both? Explain how "MFA trust" settings change the answer.
- **Q14.** Your company launches a public retail app expecting 2 million shoppers who sign up with Google, Facebook or an email address. B2B or B2C? Give two structural reasons, not one.
- **Q15.** Why is B2B/External ID licensing based on **monthly active users (MAU)** rather than on the number of guest objects? What operational behaviour does that pricing model deliberately encourage?
- **Q16.** In step 4, `allowInvitesFrom: "everyone"` is the default. Describe the concrete risk in a large tenant and the least-restrictive setting that mitigates it.

---

## Block 4 — Microsoft Entra Conditional Access

**Concept under test:** Conditional Access is an *if-then policy engine over sign-in signals*. It requires Microsoft Entra ID P1 (risk-based conditions require P2).

> **Stop.** Confirm your break-glass account exists and you know its password before proceeding. Every policy below is created in report-only state. Do not change `state` to `enabled` in a tenant you cannot afford to lose.

### Steps

1. List the policies already present.

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
     --query "value[].{name:displayName, state:state, id:id}" -o table
   ```

   ```
   Name    State    Id
   ------  -------  ----
   ```

   An empty list plus a working tenant usually means **security defaults** are on. Check:

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" \
     --query "{name:displayName, enabled:isEnabled}" -o json
   ```

   ```json
   { "name": "Security Defaults", "enabled": true }
   ```

   Security defaults and Conditional Access are **mutually exclusive**: enabling a CA policy requires security defaults to be off.

2. Create a break-glass exclusion group and put the emergency account in it. This group is referenced by every policy you will ever write.

   ```bash
   az ad group create --display-name "sg-ca-breakglass-exclude" \
     --mail-nickname "sg-ca-breakglass-exclude" --query id -o tsv
   export BG_GROUP_ID="<paste-the-id>"
   ```

3. Create the canonical policy — **require MFA for administrators** — in report-only state. `62e90394-69f5-4237-9190-012177145e10` is the well-known, tenant-invariant template ID of the **Global Administrator** role.

   ```bash
   az rest --method POST \
     --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
     --headers "Content-Type=application/json" \
     --body "{
       \"displayName\": \"AZ900-RO: Require MFA for admin roles\",
       \"state\": \"enabledForReportingButNotEnforced\",
       \"conditions\": {
         \"users\": {
           \"includeRoles\": [\"62e90394-69f5-4237-9190-012177145e10\"],
           \"excludeGroups\": [\"${BG_GROUP_ID}\"]
         },
         \"applications\": { \"includeApplications\": [\"All\"] },
         \"clientAppTypes\": [\"all\"]
       },
       \"grantControls\": {
         \"operator\": \"OR\",
         \"builtInControls\": [\"mfa\"]
       }
     }" \
     --query "{id:id, name:displayName, state:state}" -o json
   ```

   ```json
   {
     "id": "1a7f5c90-6e2b-4c83-a0d9-77b4e6f1c2aa",
     "name": "AZ900-RO: Require MFA for admin roles",
     "state": "enabledForReportingButNotEnforced"
   }
   ```

4. Create a second, **location-conditioned** policy to see how signals compose. First define a named location:

   ```bash
   az rest --method POST \
     --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations" \
     --headers "Content-Type=application/json" \
     --body '{
       "@odata.type": "#microsoft.graph.countryNamedLocation",
       "displayName": "Permitted operating countries",
       "countriesAndRegions": ["AR", "ES", "US"],
       "includeUnknownCountriesAndRegions": false
     }' --query "{id:id, name:displayName}" -o json
   ```

   ```bash
   export LOC_ID="<paste-the-id>"
   az rest --method POST \
     --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
     --headers "Content-Type=application/json" \
     --body "{
       \"displayName\": \"AZ900-RO: Block sign-in outside permitted countries\",
       \"state\": \"enabledForReportingButNotEnforced\",
       \"conditions\": {
         \"users\": { \"includeUsers\": [\"All\"], \"excludeGroups\": [\"${BG_GROUP_ID}\"] },
         \"applications\": { \"includeApplications\": [\"All\"] },
         \"locations\": { \"includeLocations\": [\"All\"], \"excludeLocations\": [\"${LOC_ID}\"] },
         \"clientAppTypes\": [\"all\"]
       },
       \"grantControls\": { \"operator\": \"OR\", \"builtInControls\": [\"block\"] }
     }" --query "{name:displayName, state:state}" -o json
   ```

   Note the inversion: you cannot express "block if country ∉ {AR,ES,US}" directly. You include **All** locations and **exclude** the permitted one. Getting this backwards is the single most common Conditional Access outage.

5. Read the effect out of the sign-in logs. Report-only results appear in a separate collection from enforced ones. (Sign-in logs via Graph require P1/P2.)

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$top=5&\$select=createdDateTime,userPrincipalName,appDisplayName,conditionalAccessStatus,status" \
     --query "value[].{when:createdDateTime, who:userPrincipalName, app:appDisplayName, ca:conditionalAccessStatus, err:status.errorCode}" -o table
   ```

   ```
   When                      Who                               App                    Ca          Err
   ------------------------  --------------------------------  ---------------------  ----------  -----
   2026-09-06T14:22:07Z      admin@contosolab.onmicrosoft.com   Azure CLI              notApplied      0
   2026-09-06T14:19:51Z      admin@contosolab.onmicrosoft.com   Microsoft Azure Portal notApplied      0
   ```

   `conditionalAccessStatus` values are `success`, `failure`, and `notApplied`. Report-only outcomes are carried per-policy under `appliedConditionalAccessPolicies[].result`, with values including `reportOnlySuccess`, `reportOnlyFailure`, `reportOnlyNotApplied` and `reportOnlyInterrupted`.

6. Sit in report-only for a full business cycle (in the lab, inspect a handful of sign-ins) **before** you would ever flip `state` to `enabled`.

### Comprehension questions — Block 4

- **Q17.** Name the six signal categories Conditional Access can evaluate and the two categories of decision it can return. Where does "require a compliant device" sit, and what other Microsoft service must be present for that control to mean anything?
- **Q18.** In step 4 you wrote `includeLocations: ["All"]` with `excludeLocations: [permitted]`. Rewrite the intent in one sentence, then explain why the naïve formulation ("include the untrusted countries") is both unmaintainable and unsafe.
- **Q19.** Conditional Access is often called "the Zero Trust policy engine." Map each of the three Zero Trust principles onto a specific element of the policy JSON you posted in step 3.
- **Q20.** Security defaults and Conditional Access cannot both be active. For each, give one scenario where it is the correct choice, and name the licensing tier each requires.
- **Q21.** A policy is `enabledForReportingButNotEnforced`. A sign-in from Brazil produces `reportOnlyFailure` on the country policy. Was the user blocked? What would `enabled` have produced, and what is the operational value of the difference?
- **Q22.** Your break-glass account is excluded from all CA policies. Every exclusion is a hole. What compensating control makes this hole acceptable, and what would you monitor?

---

## Block 5 — Azure RBAC: scope, definition, assignment

**Concept under test:** an Azure role assignment is exactly three things — a **security principal**, a **role definition**, and a **scope** — and it is inherited downward.

### Steps

1. Create the scope hierarchy you will assign against.

   ```bash
   az group create --name "$RG" --location "$LOC" --output none
   az storage account create --name "stlabaz900$RANDOM" --resource-group "$RG" \
     --location "$LOC" --sku Standard_LRS --output none
   export SA_ID="$(az storage account list -g "$RG" --query '[0].id' -o tsv)"
   echo "$SA_ID"
   ```

   ```
   /subscriptions/2c9e.../resourceGroups/rg-az900-identity-lab/providers/Microsoft.Storage/storageAccounts/stlabaz90028417
   ```

   That string **is** the scope. Truncate it at any `/` boundary that ends a container and you have a broader scope. The four levels are: management group → subscription → resource group → resource.

2. Read a built-in role definition. Look at the `actions` array, not the name.

   ```bash
   az role definition list --name "Reader" \
     --query "[0].{name:roleName, type:roleType, actions:permissions[0].actions, notActions:permissions[0].notActions, dataActions:permissions[0].dataActions}" -o json
   ```

   ```json
   {
     "name": "Reader",
     "type": "BuiltInRole",
     "actions": ["*/read"],
     "notActions": [],
     "dataActions": [],
     "notDataActions": []
   }
   ```

3. Compare the three fundamental roles side by side. The differences are two strings.

   ```bash
   for R in Owner Contributor "User Access Administrator"; do
     echo "== $R"
     az role definition list --name "$R" \
       --query "[0].permissions[0].{actions:actions, notActions:notActions}" -o json
   done
   ```

   ```
   == Owner
   { "actions": ["*"], "notActions": [] }
   == Contributor
   {
     "actions": ["*"],
     "notActions": [
       "Microsoft.Authorization/*/Delete",
       "Microsoft.Authorization/*/Write",
       "Microsoft.Authorization/elevateAccess/Action",
       "Microsoft.Blueprint/blueprintAssignments/write",
       "Microsoft.Blueprint/blueprintAssignments/delete",
       "Microsoft.Compute/galleries/share/action"
     ]
   }
   == User Access Administrator
   {
     "actions": ["*/read", "Microsoft.Authorization/*", "Microsoft.Support/*"],
     "notActions": []
   }
   ```

   Contributor is Owner minus the ability to write authorization. That one exclusion is the entire privilege boundary.

4. Notice the **control plane / data plane** split. `Actions` govern the ARM management API; `DataActions` govern the data inside the resource.

   ```bash
   az role definition list --name "Storage Blob Data Reader" \
     --query "[0].permissions[0].{actions:actions, dataActions:dataActions}" -o json
   ```

   ```json
   {
     "actions": [
       "Microsoft.Storage/storageAccounts/blobServices/containers/read",
       "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"
     ],
     "dataActions": [
       "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
     ]
   }
   ```

   A user with **Owner** on a storage account can read every management property and can grant themselves blob access — but with no `DataActions` they cannot, at that instant, read a blob's bytes.

5. Assign **Reader** to the lab group at resource-group scope.

   ```bash
   az role assignment create \
     --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
     --role "Reader" \
     --scope "/subscriptions/${SUB_ID}/resourceGroups/${RG}" \
     --query "{role:roleDefinitionName, scope:scope, principal:principalId}" -o json
   ```

   ```json
   {
     "role": "Reader",
     "scope": "/subscriptions/2c9e.../resourceGroups/rg-az900-identity-lab",
     "principalId": "c4a2e77b-3f19-4a0d-9d6e-51bb8c2ff4a3"
   }
   ```

6. Prove **inheritance**. Ask for assignments at the *storage account* scope, with and without inherited ones.

   ```bash
   echo "--- direct at resource scope only:"
   az role assignment list --scope "$SA_ID" \
     --query "[].{role:roleDefinitionName, scope:scope}" -o table

   echo "--- including inherited:"
   az role assignment list --scope "$SA_ID" --include-inherited \
     --query "[].{role:roleDefinitionName, principal:principalName, scope:scope}" -o table
   ```

   ```
   --- direct at resource scope only:

   --- including inherited:
   Role      Principal                  Scope
   --------  -------------------------  ------------------------------------------------------------
   Reader    sg-az900-platform-readers  /subscriptions/2c9e.../resourceGroups/rg-az900-identity-lab
   Owner     admin@contosolab.onmi...   /subscriptions/2c9e...
   ```

   Nothing was assigned on the storage account, yet two roles apply to it. **Scope flows down and only down.**

7. Write a **custom role**. The requirement: restart VMs and read everything, but never create, delete or resize anything.

   ```bash
   cat > vm-operator-role.json <<EOF
   {
     "Name": "AZ900 Lab VM Restart Operator",
     "IsCustom": true,
     "Description": "Read all resources and restart virtual machines. No create, delete or resize.",
     "Actions": [
       "Microsoft.Compute/virtualMachines/read",
       "Microsoft.Compute/virtualMachines/restart/action",
       "Microsoft.Compute/virtualMachines/instanceView/read",
       "Microsoft.Insights/alertRules/read",
       "Microsoft.Resources/subscriptions/resourceGroups/read"
     ],
     "NotActions": [],
     "DataActions": [],
     "NotDataActions": [],
     "AssignableScopes": [
       "/subscriptions/${SUB_ID}/resourceGroups/${RG}"
     ]
   }
   EOF

   az role definition create --role-definition @vm-operator-role.json \
     --query "{name:roleName, type:roleType, id:name}" -o json
   ```

   ```json
   {
     "name": "AZ900 Lab VM Restart Operator",
     "roleType": "CustomRole",
     "id": "7d19b0ce-4a3f-4a20-9b6c-1e5db7f9a4c2"
   }
   ```

   Custom role definitions are stored **at tenant level**; `AssignableScopes` limits where they may be *assigned*. Root scope `/` is not permitted in `AssignableScopes`.

8. Reproduce the same assignment declaratively, as you would in a pipeline. Save as `role-assignment.bicep`:

   ```bicep
   targetScope = 'resourceGroup'

   @description('Object ID of the group receiving Reader.')
   param principalId string

   @allowed(['Group', 'User', 'ServicePrincipal'])
   param principalType string = 'Group'

   // Reader — built-in role definition IDs are tenant-invariant GUIDs.
   var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

   resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
     // The name must be a GUID deterministic in (scope, principal, role),
     // otherwise redeployment creates a duplicate or fails on conflict.
     name: guid(resourceGroup().id, principalId, readerRoleId)
     scope: resourceGroup()
     properties: {
       roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
       principalId: principalId
       principalType: principalType
     }
   }

   output assignmentId string = readerAssignment.id
   ```

   ```bash
   az deployment group create --resource-group "$RG" \
     --template-file role-assignment.bicep \
     --parameters principalId="$GROUP_ID" \
     --query "properties.provisioningState" -o tsv
   ```

   ```
   Succeeded
   ```

   Re-run it. It still returns `Succeeded` and creates nothing new — that is what `guid(scope, principal, role)` buys you.

9. Check for **deny assignments**, which are evaluated *before* role assignments and cannot be overridden:

   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" \
     --query "value[].{name:properties.denyAssignmentName, notActions:properties.permissions[0].notActions}" -o table
   ```

   An empty result is expected. Deny assignments are produced by Azure-managed constructs (Azure Managed Applications, Blueprints) to protect resources from the very subscription owners who host them.

### Comprehension questions — Block 5

- **Q23.** State the three components of an Azure role assignment and, for the assignment created in step 5, name the concrete value of each.
- **Q24.** A user is granted **Reader** at the subscription and **Contributor** at one resource group inside it. What are their effective permissions in that resource group, and in a sibling resource group? State the general rule Azure RBAC uses to combine assignments.
- **Q25.** In step 3, `Contributor.notActions` contains `Microsoft.Authorization/*/Write`. Is `NotActions` a deny rule? Explain the difference between `NotActions` and a deny assignment, using the evaluation order.
- **Q26.** A user is **Owner** of a storage account and reports "Access denied" reading a blob from Storage Explorer with their Entra credentials. The assignment is correct. Diagnose it, and give the exact role that fixes it.
- **Q27.** Why does a custom role definition forbid `/` in `AssignableScopes`? What would be true of a role that allowed it?
- **Q28.** In the Bicep in step 8, why is the resource *name* a deterministic `guid()` rather than something readable like `'reader-for-platform-group'`? Predict what a second deployment does under each choice.
- **Q29.** You must give an auditing firm read-only visibility over 40 subscriptions for one quarter. Describe the assignment you would make — principal, role, scope — and justify the scope level in one sentence.

---

## Block 6 — Microsoft Entra roles vs. Azure roles

**Concept under test:** two distinct authorization systems, two distinct planes, one very common exam trap.

### Steps

1. List your **Azure** role assignments (ARM plane):

   ```bash
   az role assignment list --all --assignee "$(az ad signed-in-user show --query id -o tsv)" \
     --query "[].{role:roleDefinitionName, scope:scope}" -o table
   ```

   ```
   Role    Scope
   ------  ---------------------------------------------
   Owner   /subscriptions/2c9e8b74-...-a1f2d3c4b5e6
   ```

2. List your **Entra ID** directory role assignments (Graph plane) — a completely different API:

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole" \
     --query "value[].{role:displayName, templateId:roleTemplateId}" -o table
   ```

   ```
   Role                   TemplateId
   ---------------------  ------------------------------------
   Global Administrator   62e90394-69f5-4237-9190-012177145e10
   ```

   Two lists, two systems. Neither command can see the other's assignments.

3. Test the boundary. As **Owner** of a subscription, try to read a directory object you have no directory role for — or better, observe the documented asymmetry: a Global Administrator has, by default, **no** access to Azure subscriptions. The documented escape hatch:

   ```bash
   # Grants the calling Global Administrator User Access Administrator at root scope "/".
   az rest --method POST \
     --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
   ```

   HTTP 200 with an empty body. Now verify what appeared:

   ```bash
   az role assignment list --scope "/" \
     --query "[].{role:roleDefinitionName, principal:principalName, scope:scope}" -o table
   ```

   ```
   Role                        Principal                         Scope
   --------------------------  --------------------------------  -------
   User Access Administrator   admin@contosolab.onmicrosoft.com  /
   ```

   This is one of the highest-privilege operations in Azure. It is logged, it does not expire on its own, and it should be removed immediately:

   ```bash
   az role assignment delete --assignee "$(az ad signed-in-user show --query id -o tsv)" \
     --role "User Access Administrator" --scope "/"
   ```

4. Note where **Privileged Identity Management (PIM)** fits: it makes both kinds of role assignment *eligible* rather than *active*, requiring activation with justification, approval and a time limit. PIM requires Microsoft Entra ID P2 (or Entra ID Governance).

### Comprehension questions — Block 6

- **Q30.** Complete the table from memory, then verify:

  | | Microsoft Entra roles | Azure roles (RBAC) |
  |---|---|---|
  | Governs what? | | |
  | Scope granularity | | |
  | Example high-privilege role | | |
  | API / plane | | |

- **Q31.** A Global Administrator says "I own the tenant, so I can delete any VM." Is that true out of the box? What must happen first, and what audit trail does it leave?
- **Q32.** Why is the `elevateAccess` operation deliberately *not* something you leave in place? Name the standing-privilege problem it creates and the Zero Trust principle it violates.
- **Q33.** PIM converts an assignment from **active** to **eligible**. Restate that in terms of the attacker's window of opportunity.

---

## Block 7 — Zero Trust and defense in depth

**Concept under test:** these are models, not products. The exercise is mapping — from principle to concrete control.

### Steps

1. Write out the **three Zero Trust principles** and the **six pillars** they are applied across, from memory.

2. Take this reference architecture and label every layer of **defense in depth** it exercises:

   > A public web app runs on Azure App Service behind Azure Front Door with a WAF policy. The app authenticates users via Entra ID with a Conditional Access policy requiring MFA. It reads secrets from Azure Key Vault using a **user-assigned managed identity**, granted `Key Vault Secrets User`. Its Azure SQL Database is reachable only through a private endpoint on a subnet protected by an NSG; Transparent Data Encryption is on. Storage is encrypted at rest with a customer-managed key. Diagnostic logs flow to a Log Analytics workspace; Defender for Cloud plans are enabled on App Service, SQL and Storage.

   Produce a table with one row per layer — physical, identity & access, perimeter, network, compute, application, data — naming the control from the paragraph that occupies it. Mark the layer that has **no** control from the paragraph and say who owns it.

3. Find the Zero Trust violation. Critique this design change proposal:

   > "To simplify the pipeline, we will store the SQL admin password in a pipeline variable, allow `0.0.0.0/0` on the SQL firewall for the duration of the deployment, and grant the deployment service principal **Owner** on the subscription so it never fails on a missing permission."

   For each of the three clauses, name the Zero Trust principle violated and the specific Azure control that fixes it.

4. Verify the managed-identity claim empirically — the "no credential at all" case:

   ```bash
   az identity create --name "id-az900-lab" --resource-group "$RG" \
     --query "{clientId:clientId, principalId:principalId}" -o json
   ```

   ```json
   {
     "clientId": "5e0a91c7-4b6d-4b30-8a2f-c1e7f0b93d55",
     "principalId": "b83f4d21-0a7e-4c9b-9f13-6d2e58a0c7b4"
   }
   ```

   ```bash
   # The identity is a first-class principal — assignable like any user or group.
   az role assignment create \
     --assignee-object-id "b83f4d21-0a7e-4c9b-9f13-6d2e58a0c7b4" \
     --assignee-principal-type ServicePrincipal \
     --role "Reader" --scope "/subscriptions/${SUB_ID}/resourceGroups/${RG}" \
     --query "roleDefinitionName" -o tsv
   ```

   ```
   Reader
   ```

   There is no secret anywhere in that flow — no password, no certificate, nothing to rotate or leak. That is the identity layer of defense in depth doing its job.

### Comprehension questions — Block 7

- **Q34.** State the three Zero Trust principles verbatim and give, for each, one control you configured earlier in this document.
- **Q35.** "Defense in depth is about having a firewall *and* antivirus." Refute this in terms of what the model actually assumes about each layer.
- **Q36.** In the architecture in step 2, which defense-in-depth layer has no control listed, and why is that correct rather than a gap?
- **Q37.** Zero Trust says "assume breach." Take the architecture in step 2, assume the App Service instance is fully compromised, and enumerate what the attacker can and cannot reach — and which specific control stops each thing they cannot reach.
- **Q38.** Explain why a managed identity is a stronger control than "a service principal with a client secret stored in Key Vault," even though both keep the secret out of source control.

---

## Block 8 — Microsoft Defender for Cloud

**Concept under test:** Defender for Cloud is two products in one blade — **CSPM** (are you configured correctly?) and **CWPP** (is something attacking you right now?).

### Steps

1. Register the provider and read the current plan state.

   ```bash
   az provider register --namespace Microsoft.Security --wait
   az security pricing list --query "value[].{plan:name, tier:pricingTier}" -o table
   ```

   ```
   Plan                     Tier
   -----------------------  -------
   VirtualMachines          Free
   SqlServers               Free
   AppServices              Free
   StorageAccounts          Free
   KeyVaults                Free
   Containers               Free
   CloudPosture             Free
   ```

   `Free` here means **foundational CSPM** — always on, no charge: secure score, recommendations, asset inventory. Every `Standard` tier is a paid Defender plan adding workload protection (threat detection, alerts).

2. Read the **secure score** — the single number CSPM produces.

   ```bash
   az security secure-scores list \
     --query "[].{name:displayName, current:score.current, max:score.max, pct:score.percentage}" -o table
   ```

   ```
   Name    Current    Max    Pct
   ------  ---------  -----  -----
   ascScore      18.4     58   0.32
   ```

3. Decompose the score into controls, so you can act on it rather than admire it.

   ```bash
   az security secure-score-controls list \
     --query "sort_by([].{control:displayName, healthy:healthyResourceCount, unhealthy:unhealthyResourceCount, points:score.max}, &points) | reverse(@) | [:6]" -o table
   ```

   ```
   Control                                   Healthy    Unhealthy    Points
   ----------------------------------------  ---------  -----------  --------
   Enable MFA                                        1            2        10
   Secure management ports                           0            1         8
   Apply system updates                              2            1         6
   Manage access and permissions                     4            3         4
   Enable encryption at rest                         3            0         4
   Remediate vulnerabilities                         0            2         6
   ```

   Two of the top three controls by point value are identity controls. That is not a coincidence — it is Microsoft's own weighting of where breaches start.

4. Enable one paid plan to see the CWPP side, then turn it straight back off. **This bills per resource per hour.**

   ```bash
   az security pricing create --name "StorageAccounts" --tier "Standard" \
     --query "{plan:name, tier:pricingTier}" -o json
   ```

   ```json
   { "plan": "StorageAccounts", "tier": "Standard" }
   ```

   ```bash
   # Revert immediately.
   az security pricing create --name "StorageAccounts" --tier "Free" --query "pricingTier" -o tsv
   ```

   ```
   Free
   ```

5. Read the recommendations feed — the raw material behind the score.

   ```bash
   az security assessment list \
     --query "[?properties.status.code=='Unhealthy'].{name:properties.displayName, severity:properties.metadata.severity}" \
     -o table 2>/dev/null | head -12
   ```

6. Note the compliance surface: Defender for Cloud continuously maps your posture against **regulatory compliance** standards (Microsoft Cloud Security Benchmark by default; ISO 27001, PCI DSS, NIST SP 800-53 and others can be added). That mapping is CSPM output, not a separate product.

### Comprehension questions — Block 8

- **Q39.** Distinguish CSPM from CWPP in one sentence each, and place secure score, just-in-time VM access, and regulatory compliance dashboards on the correct side.
- **Q40.** Your secure score is 32 %. A colleague proposes "let's get to 100 % this quarter." Give two reasons this is the wrong target and state what you would optimize instead.
- **Q41.** In step 1 every plan reads `Free`. Is Defender for Cloud therefore doing nothing? Name precisely what you still get and what you do not.
- **Q42.** Defender for Cloud advertises multicloud coverage. What does it need from an AWS or GCP account to produce recommendations, and which of the two halves (CSPM/CWPP) does that connection primarily serve first?
- **Q43.** Why is "Enable MFA" worth 10 points in step 3 while "Enable encryption at rest" is worth 4? Answer in terms of attack frequency, not in terms of Microsoft's opinion.

---

## Block 9 — Consolidated diagnostic scenarios

For each scenario, name (a) the failing control, (b) the exact CLI or Graph query you would run first, and (c) the fix. Write your answer before opening the answers section.

1. **S1.** A developer can see a Key Vault in the portal, open its blade, and read its access policies — but every attempt to read a secret's value returns `Forbidden`. They hold **Contributor** on the resource group.

2. **S2.** A newly hired contractor's guest account was created three weeks ago and shows `externalUserState: PendingAcceptance`. They insist they clicked the invitation link. Sign-in logs for their address show zero entries in your tenant.

3. **S3.** After a Conditional Access policy requiring compliant devices was enabled, an automation service principal running nightly ARM deployments began failing with `AADSTS53003: Access has been blocked by Conditional Access policies`.

4. **S4.** A support engineer needs to restart production VMs at 02:00 during incidents. Today they hold standing **Contributor** on the production subscription. Design the replacement using three of the mechanisms from this document.

5. **S5.** `az role assignment list --assignee <user> --scope <resource-group>` returns an empty array, yet the user demonstrably deletes resources in that resource group.

6. **S6.** Your tenant enables security defaults. Compliance requires "MFA for administrators, but service accounts calling from the datacenter IP range are exempt." Explain why the current configuration cannot express this and what must change.

---

## Block 10 — Cleanup

Run this in order. Role assignments must go before the role definition; the resource group before the group objects only if you want a clean `az role assignment list`.

```bash
# 1. Azure RBAC
az role assignment delete --assignee-object-id "$GROUP_ID" \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/${RG}" 2>/dev/null
az role definition delete --name "AZ900 Lab VM Restart Operator"
az role assignment delete --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "User Access Administrator" --scope "/" 2>/dev/null

# 2. Resources
az group delete --name "$RG" --yes --no-wait

# 3. Conditional Access (report-only policies still count against the tenant limit)
for P in $(az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
    --query "value[?starts_with(displayName,'AZ900-RO')].id" -o tsv); do
  az rest --method DELETE \
    --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/${P}"
  echo "deleted policy $P"
done
az rest --method DELETE \
  --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations/${LOC_ID}"

# 4. Directory objects
az ad user delete --id "$GUEST_ID"
az ad group delete --group "$GROUP_ID"
az ad group delete --group "$BG_GROUP_ID"   # only in a throwaway lab tenant

# 5. Confirm Defender plans are back to Free
az security pricing list --query "value[?pricingTier=='Standard'].name" -o tsv
```

The last command must print nothing.

---

## Reference sources

- AZ-900 study guide — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- What is Microsoft Entra ID — <https://learn.microsoft.com/en-us/entra/fundamentals/whatis>
- Compare Entra ID, Entra Domain Services and AD DS — <https://learn.microsoft.com/en-us/entra/identity/domain-services/compare-identity-solutions>
- Authentication methods in Microsoft Entra ID — <https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-methods>
- Passwordless authentication options — <https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passwordless>
- B2B collaboration overview — <https://learn.microsoft.com/en-us/entra/external-id/what-is-b2b>
- Azure AD B2C overview — <https://learn.microsoft.com/en-us/azure/active-directory-b2c/overview>
- Conditional Access overview — <https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview>
- Conditional Access report-only mode — <https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only>
- Emergency access accounts — <https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access>
- Security defaults — <https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults>
- What is Azure RBAC — <https://learn.microsoft.com/en-us/azure/role-based-access-control/overview>
- Azure built-in roles — <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles>
- Azure custom roles — <https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles>
- How Azure RBAC determines access — <https://learn.microsoft.com/en-us/azure/role-based-access-control/overview#how-azure-rbac-determines-if-a-user-has-access-to-a-resource>
- Deny assignments — <https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments>
- Compare Entra roles and Azure roles — <https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/concept-understand-roles>
- Elevate access to manage all subscriptions — <https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin>
- Zero Trust guidance center — <https://learn.microsoft.com/en-us/security/zero-trust/zero-trust-overview>
- Microsoft Defender for Cloud overview — <https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-cloud-introduction>
- Secure score in Defender for Cloud — <https://learn.microsoft.com/en-us/azure/defender-for-cloud/secure-score-security-controls>
- Managed identities for Azure resources — <https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview>

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Directory services

**A1.** **Entra Domain Services** is the fit. The application needs Kerberos, LDAP and an OU tree; Entra Domain Services provides exactly those as a managed service — Microsoft patches, backs up and provides HA for the domain controllers, which you never see.
- **Entra ID** is disqualified outright: it speaks OAuth 2.0 / OpenID Connect / SAML / WS-Fed / SCIM. It has **no** Kerberos ticket-granting service, **no** LDAP endpoint and **no** OU hierarchy. A Kerberos client has nothing to talk to.
- **AD DS on IaaS VMs** would technically work but is disqualified by the stated requirement "without deploying and patching domain controllers" — you would own the DC lifecycle, patching, backup, replication topology and site design.

**A2.** `onPremisesSyncEnabled: true` means the object is **mastered on-premises** in AD DS and projected into Entra ID by Entra Connect Sync / Cloud Sync. The cloud copy is downstream. Practically: `az ad user update --display-name` either fails or is silently reverted at the next sync cycle, because the on-premises attribute is authoritative. The fix is to change it in on-premises AD and let it flow up. (Entra Connect's group writeback and password writeback are narrow, explicitly configured exceptions to this one-way flow.)

**A3.** **Speaks:** OAuth 2.0, OpenID Connect, SAML 2.0, WS-Federation, SCIM (provisioning). **Does not speak:** Kerberos, LDAP, NTLM, Group Policy — nor does it have a concept of organizational units or a forest/domain trust model. Entra ID is flat: users, groups, service principals, no OU tree.

**A4.** No — it is not a replica of your forest. Synchronization is **one-way**, from **Entra ID → the managed domain**. Objects reach Entra ID either as cloud-only accounts or via Entra Connect from on-premises AD DS; Entra Domain Services then materializes them into its own managed domain. Changes made *inside* the managed domain (new OUs, new users you create there) do **not** flow back to Entra ID, and there is no trust replication with your on-premises forest unless you explicitly configure a one-way resource forest trust.

**A5.** Service principals exist because applications need identity too, and they need it with different lifecycle and credential semantics than humans. If a pipeline signs in as a human, you lose **attribution and independent lifecycle**: audit logs show the person, not the automation, so you cannot distinguish a nightly deploy from that person's manual action; the pipeline breaks the day they change their password, take leave with MFA enforced, or leave the company; and the pipeline inherits every permission that human holds rather than only what it needs. Add to that: you cannot apply MFA or Conditional Access designed for humans to a headless process without breaking it.

### Block 2 — Authentication methods

**A6.** The attack is **real-time phishing / adversary-in-the-middle (AiTM)**. A proxy page renders a convincing sign-in form, relays the credential to the real IdP, prompts the victim for the SMS code, relays that too, and captures the resulting session cookie. The victim really does receive a legitimate code from Microsoft; nothing looks wrong. FIDO2 defeats this because the authenticator performs a **cryptographic challenge–response bound to the origin (RP ID)** — the private key never leaves the hardware and the browser will not release an assertion to `contoso-login.attacker.example` for the credential registered to `login.microsoftonline.com`. The property is **origin binding / phishing resistance**; the secondary property is that no shared secret is transmitted at all.

**A7.** No. Enabling a method in the authentication methods policy makes it **available** — users in scope *may* register and use it. Nothing requires it. The control that *requires* strong authentication is **Conditional Access**, specifically a grant control requiring an **authentication strength** (the built-in *Phishing-resistant MFA* strength, which admits FIDO2, Windows Hello for Business and certificate-based authentication, and rejects SMS/voice/OTP). `isRegistrationRequired` in `includeTargets` nudges registration but is not an access control.

**A8.** Not a misconfiguration — that is SSO working as designed. The mechanism is the **primary refresh token (PRT)** on a joined/registered device (or the session cookie plus refresh token in a browser). It is exchanged silently for per-resource **access tokens**, each typically valid ~60–90 minutes; the user never re-authenticates because the PRT/refresh token is still valid. Two categories of control shorten it: (1) **Conditional Access session controls** — sign-in frequency, persistent browser session; and (2) **Continuous Access Evaluation (CAE)**, which lets the resource provider reject an access token mid-lifetime on a critical event (account disabled, password reset, network location change, admin-triggered revocation) rather than waiting for expiry.

**A9.** A TAP is a **time-limited, optionally single-use passcode** issued by an administrator. It is an onboarding credential because a new employee faces a bootstrap problem: to register a strong method (FIDO2 key, Windows Hello, Authenticator) they must first authenticate, and they have nothing to authenticate with. A TAP is the one-time strong-enough credential that gets them through that door and directly into registering a real method. It is deliberately unsuitable for steady state — it expires (minutes to hours), can be limited to one use, and being a shareable string it has none of FIDO2's phishing resistance. It is also the correct recovery path when someone loses their only registered device.

**A10.** No. Both are **something you know**. Multi-factor requires factors from **two different** categories out of: something you *know* (password, PIN, security answer), something you *have* (phone, FIDO2 key, certificate on a TPM), something you *are* (fingerprint, face). Two knowledge factors fail to the same attack — anything that discloses one (phishing, database breach, shoulder-surfing, social engineering) tends to disclose the other. Security questions are additionally weak because the answers are frequently public.

**A11.** **Defensible, but only with compensating controls.** The purpose of a break-glass account is to survive the failure of the very systems that protect everyone else — an MFA provider outage, a federation failure, a Conditional Access policy that locked out all admins, an expired federation certificate. Binding it to MFA reintroduces the dependency it exists to escape. What makes it acceptable: a **long random password** (Microsoft guidance: 16+ characters) split across sealed envelopes held by different people in a physical safe; **cloud-only** (`*.onmicrosoft.com`, never federated, never synced); permanently assigned Global Administrator rather than PIM-eligible; **excluded from every CA policy**; and **alerted on every single sign-in** via a Log Analytics / Sentinel rule that pages the security team. At least two such accounts, on different devices/paths. If any of that is missing, the configuration is not defensible — it is just an unmonitored admin account without MFA. Microsoft's current guidance also allows a *phishing-resistant, non-federated* method (a FIDO2 key in the safe) on one of the two accounts, which is stronger still.

### Block 3 — External identities

**A12.** They are blocked, and the block happens in **Fabrikam's** tenant, not yours. Trace: the guest browses to your app → your tenant's Entra ID sees the `#EXT#` user object and determines the home tenant from the domain → it **redirects the authentication to Fabrikam's Entra ID** → Fabrikam's tenant finds the account disabled and refuses to issue a token → no token, so no assertion ever comes back to your tenant → your tenant never gets to the authorization step. The guest object still exists in your directory and still holds your group membership; it is simply unusable because nothing can authenticate it. This is the core B2B security property — offboarding at the partner automatically revokes access at yours — and also its blind spot: stale guest objects accumulate, which is why **access reviews** exist.

**A13.** By default **the home tenant** performs the authentication and therefore applies its own MFA. Your tenant applies **authorization** and can *additionally* require MFA through Conditional Access — in which case the guest is challenged again in your tenant, a duplicate prompt that users find confusing. **Cross-tenant access settings** resolve this: in your inbound trust settings for Fabrikam you can enable *"Trust multifactor authentication from Microsoft Entra tenants"*, and then a home-tenant MFA claim in the incoming token satisfies your CA requirement without a second challenge. The same mechanism exists for *compliant device* and *hybrid joined device* claims. Trusting it is a judgment call: you are accepting Fabrikam's MFA posture as equivalent to your own.

**A14.** **B2C** (or its successor, Microsoft Entra External ID for customers). Two structural reasons:
1. **Tenant separation and object model.** Consumers must not become objects in the tenant that holds your employees, your groups, your Azure RBAC assignments and your internal apps. B2C is a *separate tenant* with its own directory, so a bug in a sign-up flow cannot expose your corporate directory. B2B guests, by contrast, are provisioned into your workforce tenant — the wrong place for two million strangers.
2. **Identity provider model and customization.** B2C is built for **self-service sign-up** against social/local identity providers (Google, Facebook, Apple, local email+password) with fully branded, customizable **user flows** and custom policies (Identity Experience Framework), including progressive profiling and custom attributes. B2B assumes the external person **already has an organizational identity** at a partner company that you invite by email; there is no self-service consumer sign-up, no branding of the partner's login page, and no social-IdP-first flow.

A third reason worth stating: scale and pricing. B2C/External ID is priced for consumer volumes; a two-million-guest workforce tenant is neither the intended shape nor the intended cost curve.

**A15.** Because the **cost driver is the authentication and token-issuance traffic**, not directory storage. A guest object that nobody uses consumes essentially nothing; a guest who signs in daily consumes authentication infrastructure, Conditional Access evaluation, logging and risk detection. MAU pricing charges for what actually costs. The behaviour it encourages is **inviting freely and leaving guests provisioned** rather than deleting and re-inviting to save money — which is exactly what you want, because delete/re-invite cycles break access mid-project and destroy the audit trail. (Note the incentive it does *not* create: it does not encourage cleaning up stale guests, which is a genuine security task — hence access reviews, driven by risk rather than by the invoice. Microsoft's External ID pricing includes a substantial free MAU tier; check the current pricing page for the figure.)

**A16.** The risk: `allowInvitesFrom: "everyone"` lets **any member user — and, in the default configuration, guests themselves — invite arbitrary external people into your directory**, where they immediately inherit whatever the Guest User role grants (by default, limited directory read: they can enumerate some users, groups and app registrations). In a large tenant this yields hundreds of guests nobody approved, no record of business justification, and a guest-invites-guest chain with no owner. The least-restrictive mitigation is `allowInvitesFrom: "adminsAndGuestInviters"` — members lose the ability to invite, but you can delegate the **Guest Inviter** directory role to the specific teams that need it, so legitimate collaboration is not centralized into a ticket queue. Pair it with **cross-tenant access settings** (allowlist the partner domains you actually work with) and **access reviews** on guest accounts. The stricter `none` blocks everyone but the admin roles and usually just drives people to shadow IT.

### Block 4 — Conditional Access

**A17.** **Signals (conditions):** user or group membership; IP location / named location; device (platform, state, filter); application or resource being accessed; real-time and calculated **risk** (sign-in risk and user risk, requiring Entra ID P2 / Identity Protection); client application type (browser, mobile/desktop app, legacy authentication clients such as POP/IMAP/SMTP). **Decisions:** **block** access, or **grant** access with requirements. Grant requirements include: require MFA, require authentication strength, require device to be marked compliant, require Entra hybrid joined device, require approved client app, require app protection policy, require password change, require terms of use.

"Require a compliant device" is a **grant control**. It is meaningless without **Microsoft Intune** (or a supported third-party MDM through partner compliance integration): compliance is a boolean stamped on the device object in Entra ID *by the MDM* after it evaluates a compliance policy — encryption on, OS version at or above a floor, no jailbreak, antivirus healthy. With no MDM, no device is ever marked compliant, and enabling the control locks out everyone.

**A18.** Intent: **"Block all sign-ins that do not originate from Argentina, Spain or the United States."** Conditional Access grammar has no "not in" operator for locations; the only way to express complement is include-everything-minus-exclusions. The naïve formulation — enumerate the untrusted countries in `includeLocations` — fails on two counts. **Unmaintainable:** there are ~250 country/region codes, so you would maintain a list of ~247 entries and update it every time the ISO list changes. **Unsafe:** it is *default-allow*. Any location you forget, any IP the geo-database cannot resolve to a country, any new region — all silently permitted. The include-All/exclude-permitted form is *default-deny*: anything you did not explicitly bless is blocked, and the `includeUnknownCountriesAndRegions: false` on the named location means unresolvable IPs fall outside the permitted set and are therefore blocked. Note also the honest limitation: country conditions rest on IP geolocation and are trivially defeated by a VPN, so this is a coarse control, not an authentication control.

**A19.**
- **Verify explicitly** → `conditions` plus `grantControls.builtInControls: ["mfa"]`. Access is not granted because the request carries a valid password; the policy evaluates who the principal is (`includeRoles`), what they are reaching (`includeApplications`), and how they are connecting (`clientAppTypes`), and then demands an additional, independent proof.
- **Use least privilege access** → `includeRoles: ["62e90394-…"]`. The policy targets exactly the Global Administrator role rather than all users: the strongest requirement is applied to the highest privilege, which is the operational expression of treating privilege as something scoped and justified rather than ambient. (In a full design this pairs with PIM, so the role is eligible rather than active, and the CA policy fires at activation.)
- **Assume breach** → `clientAppTypes: ["all"]` and `includeApplications: ["All"]`. The policy does not assume the credential is intact or that the attacker will arrive through the front door; it covers every application and every client type, including legacy authentication protocols that cannot do MFA and are therefore blocked outright. The break-glass exclusion belongs here too: it is a recovery path designed on the premise that the control plane itself will fail.

**A20.**
- **Security defaults** — correct for a small organization with no dedicated identity administrator, no Entra ID P1, and no need for exceptions. It enforces a fixed, non-configurable baseline: MFA registration required for all users, MFA enforced for administrators, MFA challenged for users on risky sign-ins, legacy authentication blocked, and privileged actions in the Azure portal protected. **License: free** (included in Entra ID Free).
- **Conditional Access** — correct as soon as you need *any* exception or *any* condition: exempt a service account from an IP range, require compliant devices for finance apps only, block by country, require phishing-resistant MFA for admins but standard MFA for everyone else. **License: Microsoft Entra ID P1** (included in Microsoft 365 E3/E5, EMS E3/E5); **P2** additionally for risk-based conditions (sign-in risk, user risk) via Identity Protection.

The trap: they are mutually exclusive, so the migration is "turn security defaults off and turn a full set of CA policies on" — and there is a window in between where the tenant is unprotected. Author and report-only-validate the policies *first*, then flip.

**A21.** **The user was not blocked.** Report-only mode evaluates the policy against the real sign-in and records the verdict it *would* have reached, then grants or denies based only on the policies that are actually `enabled`. `reportOnlyFailure` means "had this policy been enforced, this sign-in would have been blocked (or would have failed to satisfy the grant control)." Under `state: "enabled"` the same sign-in would have received `conditionalAccessStatus: failure` and the user would have seen `AADSTS53003 — Access has been blocked by Conditional Access policies`.

The operational value is that this is the only way to size the blast radius of an identity policy before it can hurt you. You learn, from real production traffic across a full business cycle, exactly which users, which service principals, which mobile clients and which travelling executives the policy would have broken — including the ones nobody remembered to mention. Every Conditional Access outage in the wild is a policy that skipped this step.

**A22.** The compensating control is **the safe itself plus alerting**: a long random credential physically split and sealed, cloud-only and non-federated so it depends on no external system, at least two such accounts on independent paths, and — the part that actually closes the hole — a **detection rule that fires on any authentication by these accounts**, routed to a pager rather than an inbox. Because the accounts are used approximately never, the false-positive rate is near zero, which makes the alert unusually trustworthy: a break-glass sign-in is either a genuine emergency you already know about or an incident.

What to monitor: every sign-in (success **and** failure), every directory role change involving these accounts, any change to the exclusion group's membership, and any modification or deletion of the CA policies themselves. Also review quarterly that the accounts still work — a break-glass credential that has silently expired is worse than none, because you are relying on it.

### Block 5 — Azure RBAC

**A23.** **Security principal** — the group `sg-az900-platform-readers`, object ID `c4a2e77b-3f19-4a0d-9d6e-51bb8c2ff4a3`. **Role definition** — `Reader`, whose sole permission is `*/read`. **Scope** — `/subscriptions/${SUB_ID}/resourceGroups/rg-az900-identity-lab`. (Security principals can be users, groups, service principals or managed identities; scopes can be management group, subscription, resource group or resource.)

**A24.** In that resource group: **Contributor** — full management of resources, but not the ability to grant access, because `Contributor.notActions` excludes `Microsoft.Authorization/*/Write`. In a sibling resource group: **Reader only**, inherited from the subscription assignment; the Contributor assignment is scoped to one resource group and does not travel sideways.

The general rule: **Azure RBAC is additive.** Effective permissions are the **union** of all applicable role assignments at the requested scope and every ancestor scope. There is no precedence between role assignments, no "more specific wins," and no way for one role assignment to subtract from another — `NotActions` only subtracts within its own definition. The single exception to additivity is a **deny assignment**, which is evaluated first and wins over everything.

**A25.** **`NotActions` is not a deny rule.** It is subtraction *inside one role definition*: effective permissions of that role = `Actions` minus `NotActions`. If a different role assignment grants the same operation, the user has it — `Contributor.notActions` excluding `Microsoft.Authorization/*/Write` does nothing to stop someone who is also **User Access Administrator** elsewhere in the hierarchy.

A **deny assignment** is a separate object that blocks a principal from an action **regardless of any role assignment**. The evaluation order is: **(1) deny assignments** — if any matches, access is denied, full stop; **(2) role assignments** — the additive union described above. So `NotActions` shapes what a role grants; a deny assignment overrides what every role grants. Deny assignments are created by Azure-managed constructs (Azure Managed Applications, Azure Blueprints) so a publisher can protect resources from the subscription owner hosting them; direct authoring is not a general-purpose tool.

**A26.** The **control plane / data plane** split. **Owner** grants `Actions: ["*"]` — every management operation on the storage account, including reading its properties, rotating its keys and changing its network rules. It grants **no `DataActions`**, and reading a blob's bytes with an Entra identity requires `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read`, which is a **DataAction**. Hence: full control of the container, no access to its contents.

The fix is to additionally assign a data-plane role — **`Storage Blob Data Reader`** for read-only, or `Storage Blob Data Contributor` for read/write — at the storage account, container, or (for finer scope) blob prefix level.

The instructive part is *why* this design exists: it lets you give the platform team operational control of a storage account without granting them sight of customer data. It is also why "Owner on the resource" is not a safe proxy for "can read the data" in an audit — and, conversely, why Owner is not really a boundary: the Owner can simply assign themselves `Storage Blob Data Reader`, or read the account keys and bypass Entra authorization entirely. Disabling shared key access (`allowSharedKeyAccess: false`) is what makes the data-plane role the actual gate.

**A27.** Because `/` is the **root (tenant) scope**, and a role assignable there would be assignable over **every management group and every subscription in the tenant, including subscriptions that do not yet exist**. Azure deliberately reserves that reach: root-scope assignment is not an ordinary operation but the outcome of `elevateAccess`, which is restricted to Global Administrators, individually logged, and expected to be reverted immediately.

A role that permitted `/` in `AssignableScopes` would be a **permanently tenant-wide, self-service privilege escalation vector**: anyone holding `Microsoft.Authorization/roleAssignments/write` anywhere could attach it at the top of the hierarchy. It would also break the containment property that makes management groups useful — the guarantee that an assignment's blast radius is bounded by a scope somebody explicitly chose. The intended pattern for broad reach is to list the **root management group** (or the relevant management group) in `AssignableScopes`, which is broad but still an object with an owner, an audit trail and a policy surface.

**A28.** Because `Microsoft.Authorization/roleAssignments` uses the resource **name** as the assignment's unique identifier, and it must be a GUID — the platform has no other key for "is this the same assignment?" `guid(resourceGroup().id, principalId, readerRoleId)` is a **pure function of the three things that define the assignment**, so the same inputs always produce the same name.

Second deployment, deterministic `guid()`: ARM computes the identical name, finds the existing assignment unchanged, and the deployment succeeds as a no-op — **idempotent**, which is the whole requirement for a pipeline that runs on every commit.

Second deployment, readable literal name: it fails immediately, because `'reader-for-platform-group'` is not a GUID and the resource provider rejects the name outright. Even if you supplied a hard-coded *valid* GUID, you would have created a different failure mode — that constant is not derived from the scope or the principal, so deploying the same template to a second resource group or with a different `principalId` would collide on a name that is supposed to be unique per assignment, or silently mean "the same assignment" for two things that are not. The determinism must come from the inputs, not from a constant.

**A29.** **Principal:** a **group** (e.g. `sg-external-audit-2026q3`) containing the firm's people as **B2B guests** — never individual user assignments, so onboarding and offboarding is one membership change and the audit trail is coherent. **Role:** **`Reader`** (`*/read` on the control plane) — and note explicitly that this grants no data-plane access; if the auditors need to read blob or Key Vault contents, that is a separate, deliberately scoped data role, not an upgrade to Contributor. **Scope:** the **management group** that contains the 40 subscriptions — a single assignment inherited by all of them.

Justification: management-group scope means one assignment instead of 40, it automatically covers subscriptions added to the group during the quarter, and revocation at the end of the engagement is one delete rather than a 40-item checklist you will get wrong.

Worth adding for a real engagement, though beyond the strict question: make the assignment **PIM-eligible with an expiration date** on the last day of the quarter so it self-revokes, and schedule an **access review** — "for one quarter" is a requirement the platform can enforce, and if you leave it to a calendar reminder the access will still be live next year.

### Block 6 — Entra roles vs. Azure roles

**A30.**

| | Microsoft Entra roles | Azure roles (RBAC) |
|---|---|---|
| **Governs what?** | Directory objects and Microsoft 365 / Entra services: users, groups, app registrations, service principals, devices, Conditional Access policies, domains, licences, Exchange/SharePoint/Intune administration | Azure **resources** managed through Azure Resource Manager: VMs, storage accounts, VNets, Key Vaults, AKS clusters — plus, via `DataActions`, the data inside some of them |
| **Scope granularity** | Primarily **tenant-wide**; a subset of roles supports **administrative units** and **app-scoped** (single service principal / single application) assignment | **Four levels**: management group → subscription → resource group → resource, with downward inheritance |
| **Example high-privilege role** | **Global Administrator** (also: Privileged Role Administrator, User Administrator, Application Administrator) | **Owner** (also: Contributor, User Access Administrator) |
| **API / plane** | **Microsoft Graph** — `graph.microsoft.com`, directory plane | **Azure Resource Manager** — `management.azure.com`, control plane |

The exam trap is the last row: the two are **independent authorization systems**. Neither `az role assignment list` nor `az rest` against Graph can see the other's assignments; being Owner of every subscription grants nothing in the directory, and being Global Administrator grants nothing over Azure resources.

**A31.** **Not true out of the box.** A Global Administrator holds directory power — they can create users, reset passwords, consent to applications, edit Conditional Access — but by default they have **zero** Azure RBAC assignments and therefore cannot see, let alone delete, any VM.

What must happen first: they invoke **`elevateAccess`**, which grants their own principal **User Access Administrator at root scope `/`**. That role does not by itself let them delete a VM either — `User Access Administrator` is `*/read` plus `Microsoft.Authorization/*` — but it lets them **assign themselves Owner** on any management group or subscription, and then delete whatever they like. Two steps, both deliberate.

Audit trail: the elevation writes a **directory audit log** entry in Entra ID and the subsequent root-scope role assignment appears in the **Azure Activity Log**, along with every later assignment they make. The `/`-scoped assignment is also plainly visible to anyone running `az role assignment list --scope "/"`. It is a loud operation by design — which is exactly why the correct posture is to alert on it rather than to assume it will not happen.

**A32.** Because it creates **standing privilege at the widest possible scope, held by a human, indefinitely** — the assignment does not expire on its own, and after the initial alert nothing surfaces it again. A single compromised session, phished token or stolen laptop then inherits control of every subscription in the tenant, present and future, with no further escalation step required. The blast radius is the whole estate and the exposure window is unbounded.

It violates **least privilege access** most directly — root scope is by definition more than any specific task requires, and "permanent" is more than any incident requires. It also violates **assume breach**: leaving it in place is a bet that the administrator's account will never be compromised, which is precisely the assumption Zero Trust tells you not to make. The correct pattern is elevate → do the one thing (usually: assign a properly scoped role to the right group) → **revoke immediately**, and treat any long-lived `/`-scoped assignment as an incident.

**A33.** An **active** assignment means the privilege is live 24/7: the attacker's window of opportunity is **the entire lifetime of the assignment** — every hour of every day, whether the person is working, asleep or on holiday. A stolen session at any moment yields full privilege instantly.

An **eligible** assignment means the privilege is dormant until the user **activates** it — which requires re-authentication (typically MFA), a written justification, optionally approval by another person, and which expires automatically after a bounded time (commonly 1–8 hours). The attacker's window shrinks from "always" to "only during the short, explicitly requested activation periods," and even landing inside that window is harder: the attacker must also satisfy the activation challenge. The rest of the time, the compromised account simply does not hold the role — there is nothing to steal.

The second-order benefit is detection: because activation is a discrete, justified, logged event, "who was Owner at 03:14 on Tuesday and why" becomes an answerable question instead of a shrug.

### Block 7 — Zero Trust and defense in depth

**A34.** The three principles:

1. **Verify explicitly** — always authenticate and authorize on all available data points (identity, location, device health, service, workload, data classification, anomalies). *Control from this document:* the Conditional Access policy in Block 4 requiring MFA for administrators, which evaluates user, role, application, client type and location rather than accepting the password alone.
2. **Use least privilege access** — limit with just-in-time and just-enough-access (JIT/JEA), risk-based adaptive policies and data protection. *Control from this document:* the custom **AZ900 Lab VM Restart Operator** role in Block 5, which grants exactly `virtualMachines/read` and `virtualMachines/restart/action` instead of Contributor; and the `Reader`-at-resource-group assignment rather than at subscription scope.
3. **Assume breach** — minimize blast radius, segment access, verify end-to-end encryption, use analytics to gain visibility and drive threat detection. *Control from this document:* the resource-group-scoped assignments that bound inheritance, the break-glass monitoring in Block 4, and Defender for Cloud's alerting in Block 8. The managed identity in step 4 also belongs here — there is no credential for a breach to exfiltrate.

**A35.** The refutation is that the sentence describes **two products at two layers**, whereas defense in depth is a statement about **assumed failure**. The model's premise is that **every layer will eventually be breached**, so each layer exists to slow the attacker, reduce what the breach reaches, and generate a detection opportunity — not to be the layer that finally works. Under that premise, the correct question is never "do I have a firewall and antivirus" but "if the WAF is bypassed, what does the attacker reach next, and what does that next layer cost them?"

Three consequences the naïve version misses. **Layers must be independent:** a firewall and an antivirus that both fail to the same stolen administrator credential are one layer wearing two hats. **The layers are a defined set, not a shopping list:** physical, identity & access, perimeter, network, compute, application, data — a gap at the data layer is not compensated by two products at the perimeter. **The innermost layer is the data:** encryption at rest, encryption in transit and data-plane authorization matter precisely because the model assumes the attacker gets past the network, which the firewall-and-antivirus framing treats as unthinkable.

**A36.**

| Layer | Control from the architecture |
|---|---|
| Physical | **None listed** |
| Identity & access | Entra ID authentication, Conditional Access requiring MFA, user-assigned managed identity with `Key Vault Secrets User` |
| Perimeter | Azure Front Door with a WAF policy (also DDoS protection at the platform edge) |
| Network | Private endpoint for Azure SQL, NSG on the subnet |
| Compute | App Service as a managed platform (patched runtime, no exposed OS); Defender for App Service |
| Application | The WAF's application-layer rules, plus Defender for App Service; app-level authorization in the app itself |
| Data | Transparent Data Encryption on SQL, customer-managed key encryption on Storage, `Key Vault Secrets User` scoping who reads which secret |

The empty layer is **physical**, and it is correct rather than a gap because it is **Microsoft's responsibility under the shared responsibility model**. In a PaaS deployment the customer never touches the datacenter: physical access control, biometrics, cameras, secure media destruction and facility resilience are operated by Azure and evidenced through third-party attestations (ISO 27001, SOC 1/2/3, PCI DSS), which you consume via the Service Trust Portal rather than implement. A control you cannot implement and are not accountable for is not a hole in your design — but it is still a layer you must be able to *evidence* to an auditor, which is why "not applicable" is the wrong phrasing and "provider-owned, attested" is the right one.

**A37.**

**Reachable.** The application's own process memory and disk, including any secret currently loaded. The **managed identity's token endpoint** on the instance metadata service — so the attacker can mint tokens as that identity and use everything it is authorized for: specifically, **read the secrets in Key Vault that `Key Vault Secrets User` covers**. With those secrets, and from inside the App Service's VNet integration, they can reach the **SQL database through the private endpoint** and read whatever the app's database principal can read. Outbound network egress, unless explicitly restricted.

**Unreachable, and what stops each:**
- **Writing or deleting Key Vault secrets, or reading certificates/keys** — `Key Vault Secrets User` is read-only over secrets; Key Vault RBAC scopes the data plane per operation type.
- **Other subscriptions, other resource groups, the ARM control plane generally** — the managed identity's **Azure RBAC assignments** bound it; a `Key Vault Secrets User` assignment on one vault grants nothing anywhere else. This is the least-privilege payoff.
- **The SQL database from anywhere but that subnet** — the **private endpoint** means SQL has no public endpoint to attack; the **NSG** constrains which subnet traffic may originate from. An attacker who exfiltrates the connection string cannot use it from their own machine.
- **Reading the SQL data files or storage blobs out from under the service** — **TDE** and **customer-managed key** encryption mean the bytes at rest are not usable without the key material, which lives in Key Vault under separate authorization.
- **The tenant's other users, or privilege escalation via identity** — the compromised workload holds no directory role; **Conditional Access + MFA** protects the human sign-in path, which the workload identity cannot traverse.
- **Doing all of this quietly** — **Log Analytics** diagnostic logs and **Defender for Cloud** plans on App Service, SQL and Storage generate the detection signal: anomalous Key Vault access patterns, unusual SQL queries, unexpected egress.

The honest summary: the blast radius is "one app's secrets and one database's data," not "the subscription." That gap between the two is what defense in depth bought, and the remaining exposure is what tells you where to invest next — narrower Key Vault scoping, a database principal with fewer rights, and egress restriction.

**A38.** Both keep the secret out of source control, but **a managed identity has no secret at all**, and that difference propagates:

- **Nothing to leak.** A client secret exists as a string; a string can be printed in a debug log, dumped in an exception, copied into a support ticket, cached in a build artifact, or read out of the vault by anyone with the vault's secrets permission. A managed identity's credential is provisioned and rotated by Azure and is never exposed to the workload — the app receives a short-lived **access token** from the instance metadata endpoint, not a long-lived credential.
- **Nothing to rotate, so nothing to expire.** Client secrets have expiry dates, and the classic Friday-night outage is a secret nobody renewed. Certificate-based service principals just move the problem to certificate expiry. Managed identity rotation is handled by the platform.
- **The bootstrap problem is solved, not moved.** "Secret in Key Vault" still requires the app to authenticate *to Key Vault* — with what? Either another secret (turtles all the way down) or a managed identity, in which case the managed identity was the actual solution.
- **Lifecycle is bound to the resource.** Delete the App Service and a system-assigned identity is deleted with it. An orphaned service principal with a valid secret can outlive the workload it was created for by years, which is how stale high-privilege credentials accumulate.
- **Blast radius on theft.** Steal a client secret and the attacker can authenticate as that principal **from anywhere, until it expires**. Steal a managed identity token and it is short-lived, and obtaining it required code execution on the resource in the first place — the attacker already had to be inside.

The residual weakness, stated honestly: an attacker with code execution on the resource *can* mint tokens from the metadata endpoint (see A37), so a managed identity does not protect against a compromised workload — it protects against credential theft, credential sprawl and credential expiry. Which is why the assignment on it still has to be least-privilege.

### Block 8 — Defender for Cloud

**A39.** **CSPM (Cloud Security Posture Management)** — continuously assesses configuration against a security benchmark and tells you where you are *misconfigured*, before anything happens. **CWPP (Cloud Workload Protection Platform)** — runtime threat detection and response on the workloads themselves, telling you something is *happening now*.

Placement: **Secure score → CSPM** (it is the aggregate measure of configuration posture). **Regulatory compliance dashboards → CSPM** (the same posture data mapped onto ISO 27001, PCI DSS, NIST SP 800-53). **Just-in-time VM access → CWPP** — it is delivered by the **Defender for Servers** paid plan and acts on the live attack surface by keeping management ports (RDP/SSH) closed and opening them, per-user and per-source-IP, only for a requested time window. The CSPM/CWPP line is not "prevention vs detection" but "assessment of state vs protection of running workloads"; JIT is preventive, and it is still CWPP.

**A40.** Two reasons 100 % is the wrong target:

1. **The score is a weighted average over recommendations Microsoft chose, not a measure of your risk.** It counts controls that may be irrelevant to your estate (recommendations for services you use trivially) and cannot see controls you satisfy by other means — a compensating control implemented outside Azure, a resource that is deliberately public because it serves a public website, a subscription that is a sandbox by design. Chasing the number rewards suppressing or "fixing" findings that never mattered.
2. **Cost of the last mile is unbounded and the marginal risk reduction is not.** The final percentage points typically require enabling paid Defender plans across every resource, remediating legacy workloads that cannot be changed without a migration project, and closing findings on systems scheduled for decommission. Meanwhile the score moves every time you deploy a resource, so "100 %" is not a state you hold — it is a state you touch and immediately lose, which converts a security programme into a treadmill.

What to optimize instead: **the highest-point, highest-severity controls that map to your actual threat model, tracked as a trend rather than an absolute.** Concretely — work the controls in step 3 top-down by point value (they are point-weighted precisely because they reflect breach frequency), fix *all* unhealthy resources within a control since partial remediation of a control earns partial credit, formally **exempt** the findings that are genuinely not applicable so the denominator reflects reality, and hold the line that the score should not *regress* release over release. A rising trend with documented exemptions is a defensible position to an auditor; "we hit 100 % in March" is not.

**A41.** It is doing a substantial amount — **foundational CSPM is free and always on** once the resource providers are registered. You still get: **asset inventory** across the subscription, **continuous security assessments** against the Microsoft Cloud Security Benchmark, the **secure score** and its per-control breakdown, **security recommendations** with remediation steps (many with one-click "Fix"), **regulatory compliance** visibility against the default benchmark, and the ability to define **exemptions** and enforce via Azure Policy.

What you do **not** get without the paid plans: **threat detection and security alerts** on workloads — no anomalous-blob-access alert on Storage, no SQL injection or brute-force alert on the database, no malware/behavioural detection or EDR integration on servers, no runtime container threat detection. Also absent: **just-in-time VM access**, **adaptive application controls**, **file integrity monitoring**, **agentless vulnerability assessment and secret scanning**, **attack path analysis and the cloud security graph** (which require Defender CSPM, itself a paid plan distinct from foundational CSPM).

The short version: free tells you **how you are configured**; paid tells you **that you are being attacked**. Neither substitutes for the other, and a tenant with a good secure score and no CWPP is a well-locked building with no alarm.

**A42.** It needs a **connector** — an authorized, read-only-by-default identity in the foreign account. For **AWS**, you create an AWS connector that provisions an **IAM role** Defender for Cloud assumes cross-account (via CloudFormation or Terraform templates Microsoft supplies); for **GCP**, a GCP connector using **workload identity federation** with a service account. In both cases the connector is granted permissions to **read configuration** across the account/project (or an entire AWS Organization / GCP organization), and the foreign resources then appear in Defender for Cloud's inventory as first-class assets.

That connection serves **CSPM first**, and necessarily so: reading configuration is sufficient to assess posture, produce recommendations, contribute to the secure score, and map findings onto compliance standards — all of which start working as soon as the connector is authorized. **CWPP comes second and costs more**, because protecting workloads requires reaching *into* them: the Defender for Servers plan on an EC2 or GCE instance needs the Azure Arc agent and the Defender agent deployed on each machine, Defender for Containers needs agents in the EKS/GKE cluster, and Defender for SQL needs coverage on the database engine. Configuration you can read from the control plane; runtime behaviour you have to instrument.

**A43.** Because the scores are weighted by **how often each control's absence actually appears in a real breach**, and the two failure modes are not remotely equally frequent.

**Credential attacks are the dominant initial access vector at cloud scale** — password spray, credential stuffing against reused passwords, phishing, and infostealer malware harvesting saved credentials. These are cheap, automated, run continuously against every tenant on the internet, and require no proximity to your infrastructure. MFA is the single control that breaks the overwhelming majority of them, because a valid password stops being sufficient. Microsoft's own telemetry has consistently put the reduction in account-compromise risk from MFA in the "over 99 %" range. A tenant without MFA is not theoretically at risk; it is being probed right now.

**Encryption at rest defends against a much rarer scenario**: physical theft of, or improper disposal of, the storage media in an Azure datacenter — a facility with biometric access control, continuous surveillance and attested media destruction. It also matters for compliance and for the customer-managed-key control story. But it does **nothing** against the attacker who arrives with valid credentials, because that attacker reads the data through the service, which decrypts transparently for them. Encryption at rest is table stakes and largely on by default; it is not where breaches are won or lost.

Hence the weighting: 10 points for the control that stops the attack you are facing hourly, 4 for the control that stops the attack that essentially never occurs in a hyperscale datacenter. The general lesson for reading secure score — the point values are a **frequency-weighted prior about attacker behaviour**, which is why working the list top-down is a better strategy than working it alphabetically or by ease of remediation.

### Block 9 — Diagnostic scenarios

**S1 — Key Vault: Contributor can see the vault but not read secrets.**
- **(a) Failing control:** the **control plane / data plane split**, exactly as in A26. `Contributor` grants `Actions: *` minus authorization writes — full management of the vault object — but **no data-plane permission** over secrets. Which data-plane model applies depends on the vault: if it uses **Azure RBAC for data plane** (`enableRbacAuthorization: true`), the developer needs a data role; if it uses the legacy **access policy** model, they need an access policy entry.
- **(b) First query:**
  ```bash
  az keyvault show --name <vault> \
    --query "{rbac:properties.enableRbacAuthorization, policies:properties.accessPolicies[].objectId}" -o json
  az role assignment list --scope "<vault-resource-id>" --include-inherited \
    --query "[].{role:roleDefinitionName, principal:principalName}" -o table
  ```
- **(c) Fix:** if `enableRbacAuthorization: true`, assign **`Key Vault Secrets User`** at the vault (or individual secret) scope. If it is `false`, add an access policy granting `get`/`list` on secrets — but the better fix is to migrate the vault to the RBAC model, so vault access is governed by the same system, the same audit trail and the same PIM/access-review tooling as everything else. Note the sharp edge worth telling the student: a Contributor **can** grant themselves the data role or flip the access policy, so Contributor is not a data boundary — it is a delay and an audit entry.

**S2 — Guest stuck at `PendingAcceptance`, zero sign-in log entries.**
- **(a) Failing control:** the invitation was never **redeemed** — and zero sign-ins in *your* tenant proves the failure happens before your tenant is ever reached. The realistic causes, in order: the invitation email was quarantined or never delivered at the partner; the contractor redeemed while signed in to a *different* account, so the consent bound elsewhere; the invitation redemption is blocked by **cross-tenant access settings** (your outbound/their inbound B2B collaboration settings, or a domain allowlist that omits their domain); or the redemption link expired.
- **(b) First query:**
  ```bash
  az ad user show --id "<guest-upn-with-#EXT#>" \
    --query "{state:externalUserState, changed:externalUserStateChangeDateTime, mail:mail}" -o json
  # Redemption attempts land in the directory audit log, not the sign-in log:
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?\$filter=activityDisplayName eq 'Redeem external user invite'&\$top=10" \
    --query "value[].{when:activityDateTime, result:result, reason:resultReason, target:targetResources[0].userPrincipalName}" -o table
  ```
- **(c) Fix:** re-issue the invitation with `sendInvitationMessage: true` **and** capture `inviteRedeemUrl` from the response, then send that URL to the contractor through a channel you control (the email is the fragile part, not the mechanism). Instruct them to open it in a **private browsing window** so a stale session cannot hijack the redemption. If the audit log shows the redemption was refused, check cross-tenant access settings on both sides and the partner's outbound policy. Do not delete and recreate the guest object as a first move — that discards group memberships and role assignments already attached to it.

**S3 — Service principal broken by a compliant-device Conditional Access policy.**
- **(a) Failing control:** a Conditional Access policy scoped to `includeUsers: ["All"]` with a **device-based grant control**. A service principal has **no device** — it cannot be Intune-enrolled, cannot be marked compliant, and cannot be Entra hybrid joined — so the grant control is unsatisfiable and the sign-in is refused with `AADSTS53003`. The deeper error is conceptual: **device controls are a human/interactive-session control**, and applying them to workload identities is a category mistake.
- **(b) First query:**
  ```bash
  # Which policies applied to that sign-in, and what did each conclude?
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=appId eq '<app-id>'&\$top=5" \
    --query "value[].{when:createdDateTime, err:status.errorCode, ca:conditionalAccessStatus, policies:appliedConditionalAccessPolicies[?result!='notApplied'].{name:displayName,result:result}}" -o json
  ```
  For a service principal, also check the workload-identity sign-in collection: `.../auditLogs/signIns?$filter=signInEventTypes/any(t: t eq 'servicePrincipal')`.
- **(c) Fix:** **exclude the service principal from the user-targeted policy** — but do not stop there, because an unconditional exclusion is a hole. Replace the coverage with a **Conditional Access policy for workload identities** (Microsoft Entra Workload ID Premium), which targets service principals and supports the conditions that *are* meaningful for a headless caller: **location** (restrict to the datacenter or build-agent IP ranges) and **risk** (Workload Identity Protection). Structurally, the correct pattern is two policies — one for humans with device and MFA controls, one for workload identities with network and risk controls — not one policy with a growing exclusion list. Better still, if the pipeline runs in Azure, replace the service principal's secret with a **managed identity** or **workload identity federation** so there is no credential to steal in the first place.

**S4 — Standing Contributor for 02:00 VM restarts.**

The replacement uses three mechanisms from this document:

1. **A custom role instead of Contributor.** The engineer needs to read VMs and restart them, not to create, resize, delete or reconfigure them. Assign the **`AZ900 Lab VM Restart Operator`** definition from Block 5 — `virtualMachines/read`, `virtualMachines/restart/action`, `instanceView/read`, plus the alert-rule and resource-group reads needed to navigate the portal. Compare the delta honestly: Contributor on a production subscription includes deleting the database, changing the network rules and detaching the disks. None of that is required to restart a VM at 02:00.
2. **PIM: eligible, not active.** Make the assignment **eligible** rather than active, with activation requiring MFA, a written justification and an incident ticket reference, bounded to a maximum of 4 hours and auto-expiring. At 02:00 the engineer activates in under a minute; at every other hour of the year the account holds nothing. This is A33 applied: the attacker's window collapses from "always" to "the handful of hours per quarter during a genuine incident," and every activation is a discrete, attributable, justified log entry.
3. **Conditional Access on the activation.** Require **MFA** — ideally an **authentication strength** of phishing-resistant MFA — at role activation, so a phished password cannot activate the role even during an incident. Add device compliance if the on-call engineers use managed devices.

Two supporting details that make it work in practice: assign to a **group** (`sg-oncall-vm-operators`) made PIM-eligible, so on-call rotation is a membership change rather than a role change; and scope the assignment to the **resource groups holding the production VMs**, not the subscription, so inheritance does not quietly extend it. Finally, alert on activations — a 02:00 activation with no corresponding incident is the signal you want.

**S5 — Empty `az role assignment list`, yet the user deletes resources.**
- **(a) Failing control:** nothing is failing — **the query is wrong.** `az role assignment list --assignee <user> --scope <rg>` shows assignments **at that exact scope** for that principal directly. It misses two things at once: assignments **inherited from ancestor scopes** (the subscription or a management group above it), and assignments held **through group membership** rather than by the user object.
- **(b) First query:**
  ```bash
  UID="$(az ad user show --id '<upn>' --query id -o tsv)"

  # Inherited scopes AND group-derived assignments, resolved transitively:
  az role assignment list --assignee "$UID" --all --include-inherited --include-groups \
    --query "[].{role:roleDefinitionName, scope:scope, via:principalName}" -o table

  # Cross-check the group path independently:
  az ad user get-member-groups --id "$UID" --query "[].displayName" -o table
  ```
  ```
  Role         Scope                                          Via
  -----------  ---------------------------------------------  --------------------------
  Contributor  /subscriptions/2c9e...                         sg-platform-engineers
  ```
- **(c) Fix:** there is nothing to remediate technically — the finding is that the effective permission comes from **`Contributor` at subscription scope via group membership**. Whether that is correct is a design question: if the user should only have rights in one resource group, remove them from the broad group and assign at the narrower scope. The durable lesson, and the one worth carrying into the exam and into production: **`--all --include-inherited --include-groups` is the only form of that command whose empty result means anything.** Without those flags, "no assignments" is not evidence of no access — a mistake that has produced false clean bills of health in real access reviews.

**S6 — Security defaults cannot express "MFA for admins, except service accounts from the datacenter range."**
- **(a) Failing control:** **security defaults is a fixed, non-configurable baseline.** It is deliberately all-or-nothing: MFA registration for all users, MFA for administrators, MFA on risky sign-ins, legacy authentication blocked, privileged portal actions protected — with **no conditions, no exclusions, no scoping and no per-application targeting**. The requirement contains an *exemption based on a network condition*, which is precisely the class of statement security defaults has no grammar for.
- **(b) First query:**
  ```bash
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" \
    --query "{name:displayName, enabled:isEnabled}" -o json
  ```
- **(c) Fix:** acquire **Microsoft Entra ID P1**, then migrate. Do it in this order, because the two are mutually exclusive and the gap between them is an exposure window:
  1. Author the replacement policies and set every one to **`enabledForReportingButNotEnforced`**. At minimum: require MFA for administrator roles; require MFA for all users; **block legacy authentication** (this is the one people forget, and security defaults was providing it silently); and a named location for the datacenter IP range with the service accounts excluded from the MFA policy only when the location condition matches.
  2. Create the break-glass exclusion group and verify it is referenced by every policy.
  3. Run report-only for a full business cycle and read `appliedConditionalAccessPolicies[].result` in the sign-in logs — this is where you discover the mobile client, the travelling director and the second service account nobody mentioned.
  4. Turn security defaults **off** and the policies **on** in the same maintenance window, in that order, with the break-glass credential in hand.

  Two design notes worth stating. A network-location exemption is a **weak** condition — IP ranges can be spoofed or reached through a compromised host inside the range — so treat it as a stopgap; the stronger answer is to replace the service accounts with **managed identities or workload identity federation** (no credential to protect, so no MFA exemption needed) and to govern them with a **workload-identity Conditional Access policy** rather than by excluding them from a human one. And never build the exemption as a permanent hole: give it an owner, an expiry and an access review.

</details>