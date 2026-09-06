# AZ-900 — Tema 2.4: Describe Azure Identity, Access, and Security

## Ejercicios guiados

> **Peso en el examen:** 9,62 % — el bloque individual más grande del Dominio 2. Todo lo que hay acá es de nivel *describe* en el examen, pero los ejercicios de abajo están escritos a nivel de operador: vas a ver el plano de control real, no un diagrama de él.

---

## 0. Convenciones del laboratorio y reglas de seguridad

Leé esta sección antes de ejecutar nada. La identidad es la única superficie de Azure donde un `POST` descuidado te deja afuera **a vos** del tenant en el que estás trabajando.

| Regla | Por qué |
|---|---|
| Usá un **tenant dedicado de desarrollo/pruebas** (Microsoft 365 Developer Program o una prueba gratuita), nunca un tenant de producción. | Conditional Access y las políticas de métodos de autenticación son de alcance tenant-wide. |
| Creá una cuenta **break-glass (de acceso de emergencia)** *antes* del Bloque 4, excluila de todas las políticas de Conditional Access y guardá su credencial fuera de línea. | Guía de la propia Microsoft: al menos dos cuentas de emergencia cloud-only, excluidas de CA, no cubiertas por un MFA que pueda fallar. |
| Toda política de Conditional Access que crees en este laboratorio se crea con `"state": "enabledForReportingButNotEnforced"` (report-only). | Report-only evalúa y registra el resultado sin bloquear a nadie. |
| Preferí `--output table` para leer, `--output json` para automatizar, `--query` (JMESPath) para probar un hecho. | Se te va a pedir que *pruebes* afirmaciones, no que las mires de reojo. |
| Borrá lo que creaste (Bloque 10). | Los guest users, los custom roles y los planes de Defender persisten y algunos facturan. |

### Herramientas

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

Los comandos `az ad *` de Azure CLI hablan con **Microsoft Graph**, no con el retirado Azure AD Graph. Donde no existe un comando de primera clase, bajamos a `az rest`, que reutiliza tu token de la CLI:

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

## Bloque 1 — Servicios de directorio: Microsoft Entra ID y Entra Domain Services

**Concepto bajo evaluación:** Entra ID *no* es Active Directory Domain Services en la nube. Es otra familia de protocolos para otro problema.

### Pasos

1. Identificá el directorio en el que iniciaste sesión y la identidad con la que lo hiciste.

   ```bash
   az ad signed-in-user show \
     --query "{upn:userPrincipalName, id:id, type:userType, onPrem:onPremisesSyncEnabled}" -o table
   ```

   ```
   Upn                          Id                                    Type    OnPrem
   ---------------------------  ------------------------------------  ------  --------
   admin@contosolab.onmicrosoft.com  3b1e8f22-9c07-4d5a-8e11-6f0a2c4b93d7  Member
   ```

   `onPremisesSyncEnabled` es `null` para una cuenta cloud-only y `true` para una cuenta proyectada hacia Entra ID por **Microsoft Entra Connect Sync** / **Cloud Sync**.

2. Enumerá los usuarios del directorio y clasificalos por `userType`.

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

3. Creá un security group. Los grupos —no los usuarios— son la unidad de asignación de acceso en todo tenant bien administrado.

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

4. Inspeccioná cómo se ve un **service principal** — la identidad no humana que Entra ID emite a las aplicaciones. Fijate que vive en el mismo directorio que tus usuarios.

   ```bash
   az ad sp list --filter "startswith(displayName,'Microsoft Graph')" \
     --query "[].{name:displayName, appId:appId, type:servicePrincipalType}" -o table
   ```

5. Mirá el límite de *protocolo*. Entra ID publica un documento de descubrimiento de OpenID Connect; AD DS no publica nada parecido.

   ```bash
   curl -s "https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration" \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["token_endpoint"]); print(d["issuer"]); print(", ".join(d["response_types_supported"]))'
   ```

   ```
   https://login.microsoftonline.com/8f7c0e3a-1d44-4b2e-9a51-0c9b2f6ad7e1/oauth2/v2.0/token
   https://login.microsoftonline.com/8f7c0e3a-1d44-4b2e-9a51-0c9b2f6ad7e1/v2.0
   code, id_token, code id_token, id_token token
   ```

6. Leé (no crees — factura de forma continua) cómo se vería un dominio administrado de **Microsoft Entra Domain Services** como recurso ARM:

   ```bash
   az provider show --namespace Microsoft.AAD \
     --query "resourceTypes[?resourceType=='DomainServices'].{type:resourceType, apiVersions:apiVersions[0]}" -o table
   ```

   ```
   Type            ApiVersions
   --------------  -------------
   DomainServices  2022-12-01
   ```

   Una instancia de Entra Domain Services se despliega **dentro de una subnet de una red virtual**, se factura por hora y expone **LDAP, Kerberos, NTLM y Group Policy** a las VMs de esa VNet. Entra ID por sí mismo no expone ninguno de esos.

### Preguntas de comprensión — Bloque 1

- **Q1.** Una aplicación de línea de negocio heredada autentica usuarios con Kerberos y lee su estructura de OUs por LDAP. El equipo quiere hacer lift-and-shift a VMs de Azure sin desplegar ni parchear domain controllers. ¿Cuál de las tres opciones de directorio —Entra ID, Entra Domain Services, AD DS sobre VMs IaaS— encaja, y qué descalifica a cada una de las otras dos?
- **Q2.** En el paso 1, `onPremisesSyncEnabled` era `null`. ¿Qué te diría `true` sobre dónde está *masterizado* ese objeto de usuario, y cuál es la consecuencia práctica para `az ad user update --display-name`?
- **Q3.** Se describe a Entra ID como "identidad como servicio". Nombrá dos protocolos que habla y dos protocolos que **no** habla.
- **Q4.** ¿Un dominio administrado de Microsoft Entra Domain Services es una réplica de tu forest de AD DS on-premises? Justificá en términos de la dirección de la sincronización.
- **Q5.** ¿Por qué el tenant contiene service principals además de usuarios? ¿Qué única propiedad de seguridad se pierde si un pipeline de automatización inicia sesión con las credenciales de un usuario humano?

---

## Bloque 2 — Métodos de autenticación: SSO, MFA y passwordless

**Concepto bajo evaluación:** la autenticación prueba *quién*; la fuerza de esa prueba es una decisión de política, y la política es legible por máquina.

### Pasos

1. Leé la **authentication methods policy** del tenant — el único objeto que gobierna qué métodos pueden registrar y usar los usuarios.

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

2. Inspeccioná la configuración de FIDO2 en detalle. Este es el método **passwordless resistente al phishing**.

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

   `isAttestationEnforced: true` significa que Entra ID verifica la atestación del fabricante del autenticador contra el FIDO Alliance Metadata Service — el tenant va a rechazar una llave sin atestación o emulada por software. `keyRestrictions.aaGuids` fijaría modelos de hardware específicos.

3. Habilitá FIDO2 solo para el grupo del laboratorio (mínimo radio de explosión). Graph exige el objeto de configuración **completo** en el `PATCH`:

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

   Un `PATCH` exitoso devuelve HTTP 204 sin cuerpo. Volvé a correr el paso 1 para confirmar `Fido2  enabled`.

4. Consultá **quién registró realmente qué**. El estado de registro, no el estado de la política, es lo que sobrevive a un incidente. (Este informe requiere Microsoft Entra ID P1 o P2.)

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

5. Observá el **SSO** empíricamente. Obtené un token para un recurso, después un segundo, y compará la cantidad de inicios de sesión. Desde un navegador con sesión iniciada en `portal.azure.com`, abrí `https://myapps.microsoft.com` — no aparece ningún pedido de credenciales. Desde la CLI, el equivalente es una segunda emisión silenciosa de token a partir del refresh token en caché:

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

   Dos access tokens, dos audiencias distintas, **una** autenticación. Eso es SSO: el primary refresh token se intercambia por access tokens por recurso sin volver a probar la identidad.

6. Clasificá los métodos que viste en el paso 1 en los tres factores de autenticación, y por separado en "passwordless / no passwordless" y "resistente al phishing / no resistente al phishing". Escribí tu tabla antes de leer las respuestas.

### Preguntas de comprensión — Bloque 2

- **Q6.** Un one-time passcode por SMS y una llave de seguridad FIDO2 satisfacen ambos "multifactor". Explicá el ataque concreto que derrota al primero y no a la segunda, y nombrá la propiedad que marca la diferencia.
- **Q7.** En el paso 3 pusiste `state: enabled` para FIDO2 pero acotaste `includeTargets` a un grupo. ¿Eso *obligó* a alguien a usar FIDO2? ¿Qué control de Azure sí lo haría?
- **Q8.** Un usuario reporta: "inicié sesión una vez esta mañana y pude abrir Teams, el portal de Azure y nuestra app SaaS de gastos todo el día sin otro prompt". ¿Es una mala configuración? Nombrá el token que lo hace posible y las dos categorías de control que pueden acortarlo.
- **Q9.** ¿Por qué un **Temporary Access Pass (TAP)** se categoriza como credencial de *onboarding* y no de régimen permanente? ¿Qué problema resuelve para un empleado recién ingresado que no tiene ningún método registrado?
- **Q10.** ¿"Contraseña + pregunta de seguridad" es autenticación multifactor? Justificá usando la taxonomía de los tres factores.
- **Q11.** Tu cuenta break-glass no tiene MFA registrado (paso 4, `isMfaRegistered: False`). Defendé o refutá esta configuración.

---

## Bloque 3 — Identidades externas: B2B y B2C

**Concepto bajo evaluación:** dos productos, dos direcciones de confianza, dos topologías de tenant.

### Pasos

1. Invitá a un **guest B2B**. Usá una dirección que controles en otro dominio.

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

2. Verificá cómo está representado el guest en **tu** directorio.

   ```bash
   az ad user list --filter "userType eq 'Guest'" \
     --query "[].{upn:userPrincipalName, mail:mail, type:userType, state:externalUserState}" -o table
   ```

   ```
   Upn                                                              Mail                             Type   State
   ---------------------------------------------------------------  -------------------------------  -----  -----------------
   partner.analyst_fabrikam.example#EXT#@contosolab.onmicrosoft.com  partner.analyst@fabrikam.example  Guest  PendingAcceptance
   ```

   Leé el UPN con atención: `#EXT#@yourtenant`. Hay un **objeto de usuario** en tu tenant, pero **no hay credencial** en tu tenant. La autenticación se delega al identity provider de Fabrikam; tu tenant solo autoriza.

3. Agregá el guest al grupo del laboratorio. De esto se trata B2B: las personas externas pasan a ser sujetos asignables de tu modelo de acceso normal.

   ```bash
   export GUEST_ID="9d2b6f14-77ac-4e39-b0c8-2a53e1f80b6d"
   az ad group member add --group "$GROUP_ID" --member-id "$GUEST_ID"
   az ad group member list --group "$GROUP_ID" --query "[].{name:displayName, type:userType}" -o table
   ```

4. Inspeccioná las **external collaboration settings** del tenant — las barandas sobre quién puede invitar a quién.

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

   `10dae51f-…` es la plantilla **Guest User** (lectura restringida del directorio). `2af84b1e-…` es *Restricted Guest* (sin lectura del directorio). `a0b1b346-…` es *User* — un guest con los mismos permisos de directorio que un member, lo que casi siempre está mal.

5. Contrastá con **B2C**. No hay nada que inspeccionar en tu workforce tenant, y esa es la lección:

   ```bash
   az rest --method GET --url "https://graph.microsoft.com/v1.0/organization" \
     --query "value[].{name:displayName, type:tenantType}" -o table
   ```

   ```
   Name         Type
   -----------  ------
   Contoso Lab  AAD
   ```

   Un tenant B2C reporta `tenantType: "AAD B2C"`, es un **tenant separado con su propio directorio, sus propios objetos de usuario y sus propios user flows de registro**, y se crea desde otra hoja del portal. Sus consumidores nunca aparecen en tu workforce tenant. (La oferta de generación actual de Microsoft para este escenario es **Microsoft Entra External ID for customers**; Azure AD B2C sigue soportado y es el que nombra la guía de estudio de AZ-900.)

### Preguntas de comprensión — Bloque 3

- **Q12.** El home tenant de un guest deshabilita su cuenta en su último día en Fabrikam. ¿Qué pasa la próxima vez que intente abrir tu dashboard compartido, y *por qué*? Rastreá la falla hasta el paso exacto del flujo.
- **Q13.** En el paso 2, el guest tiene un objeto de usuario en tu tenant pero ninguna contraseña ahí. ¿Qué tenant impone MFA en ese inicio de sesión — el de ellos, el tuyo o los dos? Explicá cómo cambian la respuesta los ajustes de "MFA trust".
- **Q14.** Tu empresa lanza una app pública de retail esperando 2 millones de compradores que se registran con Google, Facebook o una dirección de correo. ¿B2B o B2C? Dá dos razones estructurales, no una.
- **Q15.** ¿Por qué el licenciamiento de B2B/External ID se basa en **monthly active users (MAU)** y no en la cantidad de objetos guest? ¿Qué comportamiento operativo fomenta deliberadamente ese modelo de precios?
- **Q16.** En el paso 4, `allowInvitesFrom: "everyone"` es el valor por defecto. Describí el riesgo concreto en un tenant grande y el ajuste menos restrictivo que lo mitiga.

---

## Bloque 4 — Microsoft Entra Conditional Access

**Concepto bajo evaluación:** Conditional Access es un *motor de políticas if-then sobre señales de inicio de sesión*. Requiere Microsoft Entra ID P1 (las condiciones basadas en riesgo requieren P2).

> **Pará.** Confirmá que tu cuenta break-glass existe y que sabés su contraseña antes de seguir. Todas las políticas de abajo se crean en estado report-only. No cambies `state` a `enabled` en un tenant que no te podés dar el lujo de perder.

### Pasos

1. Listá las políticas ya presentes.

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" \
     --query "value[].{name:displayName, state:state, id:id}" -o table
   ```

   ```
   Name    State    Id
   ------  -------  ----
   ```

   Una lista vacía más un tenant funcionando normalmente significa que están activos los **security defaults**. Verificá:

   ```bash
   az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" \
     --query "{name:displayName, enabled:isEnabled}" -o json
   ```

   ```json
   { "name": "Security Defaults", "enabled": true }
   ```

   Security defaults y Conditional Access son **mutuamente excluyentes**: habilitar una política de CA requiere que los security defaults estén apagados.

2. Creá un grupo de exclusión break-glass y poné la cuenta de emergencia adentro. Este grupo lo referencia cada política que vayas a escribir alguna vez.

   ```bash
   az ad group create --display-name "sg-ca-breakglass-exclude" \
     --mail-nickname "sg-ca-breakglass-exclude" --query id -o tsv
   export BG_GROUP_ID="<paste-the-id>"
   ```

3. Creá la política canónica — **requerir MFA para administradores** — en estado report-only. `62e90394-69f5-4237-9190-012177145e10` es el template ID bien conocido e invariante entre tenants del rol **Global Administrator**.

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

4. Creá una segunda política, **condicionada por ubicación**, para ver cómo se componen las señales. Primero definí una named location:

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

   Notá la inversión: no podés expresar "bloquear si el país ∉ {AR,ES,US}" directamente. Incluís **All** las ubicaciones y **excluís** la permitida. Hacer esto al revés es la causa más común de caídas por Conditional Access.

5. Leé el efecto en los sign-in logs. Los resultados de report-only aparecen en una colección separada de los aplicados. (Los sign-in logs vía Graph requieren P1/P2.)

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

   Los valores de `conditionalAccessStatus` son `success`, `failure` y `notApplied`. Los resultados de report-only se transportan por política bajo `appliedConditionalAccessPolicies[].result`, con valores que incluyen `reportOnlySuccess`, `reportOnlyFailure`, `reportOnlyNotApplied` y `reportOnlyInterrupted`.

6. Quedate en report-only durante un ciclo de negocio completo (en el laboratorio, inspeccioná un puñado de inicios de sesión) **antes** de que se te ocurra cambiar `state` a `enabled`.

### Preguntas de comprensión — Bloque 4

- **Q17.** Nombrá las seis categorías de señal que Conditional Access puede evaluar y las dos categorías de decisión que puede devolver. ¿Dónde se ubica "requerir un dispositivo compliant", y qué otro servicio de Microsoft debe estar presente para que ese control signifique algo?
- **Q18.** En el paso 4 escribiste `includeLocations: ["All"]` con `excludeLocations: [permitted]`. Reescribí la intención en una oración y después explicá por qué la formulación ingenua ("incluir los países no confiables") es a la vez inmantenible e insegura.
- **Q19.** A Conditional Access se lo suele llamar "el motor de políticas de Zero Trust". Mapeá cada uno de los tres principios de Zero Trust a un elemento específico del JSON de política que publicaste en el paso 3.
- **Q20.** Security defaults y Conditional Access no pueden estar activos a la vez. Para cada uno, dá un escenario donde sea la elección correcta, y nombrá el nivel de licenciamiento que requiere cada uno.
- **Q21.** Una política está en `enabledForReportingButNotEnforced`. Un inicio de sesión desde Brasil produce `reportOnlyFailure` en la política de país. ¿El usuario fue bloqueado? ¿Qué habría producido `enabled`, y cuál es el valor operativo de la diferencia?
- **Q22.** Tu cuenta break-glass está excluida de todas las políticas de CA. Toda exclusión es un agujero. ¿Qué control compensatorio hace aceptable este agujero, y qué monitorearías?

---

## Bloque 5 — Azure RBAC: scope, definición, asignación

**Concepto bajo evaluación:** una role assignment de Azure es exactamente tres cosas — un **security principal**, una **role definition** y un **scope** — y se hereda hacia abajo.

### Pasos

1. Creá la jerarquía de scopes contra la que vas a asignar.

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

   Esa cadena **es** el scope. Truncala en cualquier límite `/` que termine un contenedor y tenés un scope más amplio. Los cuatro niveles son: management group → subscription → resource group → resource.

2. Leé una role definition integrada. Mirá el array `actions`, no el nombre.

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

3. Compará los tres roles fundamentales lado a lado. Las diferencias son dos cadenas.

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

   Contributor es Owner menos la capacidad de escribir autorización. Esa única exclusión es todo el límite de privilegio.

4. Fijate en la separación **control plane / data plane**. `Actions` gobierna la API de administración de ARM; `DataActions` gobierna los datos dentro del recurso.

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

   Un usuario con **Owner** sobre una storage account puede leer todas las propiedades de administración y puede otorgarse a sí mismo acceso a blobs — pero sin `DataActions` no puede, en ese instante, leer los bytes de un blob.

5. Asigná **Reader** al grupo del laboratorio a nivel de resource group.

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

6. Probá la **herencia**. Pedí las asignaciones en el scope de la *storage account*, con y sin las heredadas.

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

   No se asignó nada sobre la storage account, y sin embargo hay dos roles que aplican sobre ella. **El scope fluye hacia abajo y solo hacia abajo.**

7. Escribí un **custom role**. El requisito: reiniciar VMs y leer todo, pero nunca crear, borrar ni redimensionar nada.

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

   Las definiciones de custom role se guardan **a nivel de tenant**; `AssignableScopes` limita dónde se pueden *asignar*. El scope raíz `/` no está permitido en `AssignableScopes`.

8. Reproducí la misma asignación de forma declarativa, como lo harías en un pipeline. Guardalo como `role-assignment.bicep`:

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

   Volvé a correrlo. Sigue devolviendo `Succeeded` y no crea nada nuevo — eso es lo que te compra `guid(scope, principal, role)`.

9. Revisá si hay **deny assignments**, que se evalúan *antes* que las role assignments y no se pueden sobrescribir:

   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" \
     --query "value[].{name:properties.denyAssignmentName, notActions:properties.permissions[0].notActions}" -o table
   ```

   Un resultado vacío es lo esperado. Las deny assignments las producen construcciones administradas por Azure (Azure Managed Applications, Blueprints) para proteger recursos justamente de los subscription owners que los alojan.

### Preguntas de comprensión — Bloque 5

- **Q23.** Enunciá los tres componentes de una role assignment de Azure y, para la asignación creada en el paso 5, nombrá el valor concreto de cada uno.
- **Q24.** A un usuario se le otorga **Reader** en la subscription y **Contributor** en un resource group dentro de ella. ¿Cuáles son sus permisos efectivos en ese resource group, y en un resource group hermano? Enunciá la regla general que usa Azure RBAC para combinar asignaciones.
- **Q25.** En el paso 3, `Contributor.notActions` contiene `Microsoft.Authorization/*/Write`. ¿`NotActions` es una regla de denegación? Explicá la diferencia entre `NotActions` y una deny assignment, usando el orden de evaluación.
- **Q26.** Un usuario es **Owner** de una storage account y reporta "Access denied" al leer un blob desde Storage Explorer con sus credenciales de Entra. La asignación es correcta. Diagnosticalo y dá el rol exacto que lo arregla.
- **Q27.** ¿Por qué una definición de custom role prohíbe `/` en `AssignableScopes`? ¿Qué sería cierto de un rol que lo permitiera?
- **Q28.** En el Bicep del paso 8, ¿por qué el *nombre* del recurso es un `guid()` determinista y no algo legible como `'reader-for-platform-group'`? Predecí qué hace un segundo deployment bajo cada opción.
- **Q29.** Tenés que darle a una firma auditora visibilidad de solo lectura sobre 40 subscriptions durante un trimestre. Describí la asignación que harías — principal, rol, scope — y justificá el nivel de scope en una oración.

---

## Bloque 6 — Roles de Microsoft Entra vs. roles de Azure

**Concepto bajo evaluación:** dos sistemas de autorización distintos, dos planos distintos, una trampa de examen muy común.

### Pasos

1. Listá tus role assignments de **Azure** (plano ARM):

   ```bash
   az role assignment list --all --assignee "$(az ad signed-in-user show --query id -o tsv)" \
     --query "[].{role:roleDefinitionName, scope:scope}" -o table
   ```

   ```
   Role    Scope
   ------  ---------------------------------------------
   Owner   /subscriptions/2c9e8b74-...-a1f2d3c4b5e6
   ```

2. Listá tus asignaciones de directory roles de **Entra ID** (plano Graph) — una API completamente distinta:

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

   Dos listas, dos sistemas. Ninguno de los dos comandos puede ver las asignaciones del otro.

3. Probá el límite. Siendo **Owner** de una subscription, intentá leer un objeto de directorio para el que no tenés ningún directory role — o mejor, observá la asimetría documentada: un Global Administrator no tiene, por defecto, **ningún** acceso a las subscriptions de Azure. La salida de emergencia documentada:

   ```bash
   # Grants the calling Global Administrator User Access Administrator at root scope "/".
   az rest --method POST \
     --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
   ```

   HTTP 200 con cuerpo vacío. Ahora verificá qué apareció:

   ```bash
   az role assignment list --scope "/" \
     --query "[].{role:roleDefinitionName, principal:principalName, scope:scope}" -o table
   ```

   ```
   Role                        Principal                         Scope
   --------------------------  --------------------------------  -------
   User Access Administrator   admin@contosolab.onmicrosoft.com  /
   ```

   Esta es una de las operaciones de mayor privilegio en Azure. Queda registrada, no expira por su cuenta, y hay que quitarla de inmediato:

   ```bash
   az role assignment delete --assignee "$(az ad signed-in-user show --query id -o tsv)" \
     --role "User Access Administrator" --scope "/"
   ```

4. Notá dónde encaja **Privileged Identity Management (PIM)**: hace que ambos tipos de asignación de rol sean *eligible* en lugar de *active*, exigiendo activación con justificación, aprobación y límite de tiempo. PIM requiere Microsoft Entra ID P2 (o Entra ID Governance).

### Preguntas de comprensión — Bloque 6

- **Q30.** Completá la tabla de memoria y después verificá:

  | | Roles de Microsoft Entra | Roles de Azure (RBAC) |
  |---|---|---|
  | ¿Qué gobierna? | | |
  | Granularidad de scope | | |
  | Ejemplo de rol de alto privilegio | | |
  | API / plano | | |

- **Q31.** Un Global Administrator dice "soy dueño del tenant, así que puedo borrar cualquier VM". ¿Es cierto de fábrica? ¿Qué tiene que pasar primero, y qué rastro de auditoría deja?
- **Q32.** ¿Por qué la operación `elevateAccess` deliberadamente *no* es algo que se deja puesto? Nombrá el problema de privilegio permanente que crea y el principio de Zero Trust que viola.
- **Q33.** PIM convierte una asignación de **active** a **eligible**. Replanteá eso en términos de la ventana de oportunidad del atacante.

---

## Bloque 7 — Zero Trust y defensa en profundidad

**Concepto bajo evaluación:** son modelos, no productos. El ejercicio es el mapeo — de principio a control concreto.

### Pasos

1. Escribí los **tres principios de Zero Trust** y los **seis pilares** sobre los que se aplican, de memoria.

2. Tomá esta arquitectura de referencia y etiquetá cada capa de **defensa en profundidad** que ejercita:

   > Una app web pública corre sobre Azure App Service detrás de Azure Front Door con una política de WAF. La app autentica usuarios vía Entra ID con una política de Conditional Access que requiere MFA. Lee secretos de Azure Key Vault usando una **user-assigned managed identity**, a la que se le otorgó `Key Vault Secrets User`. Su Azure SQL Database es alcanzable solo a través de un private endpoint en una subnet protegida por un NSG; Transparent Data Encryption está activo. El almacenamiento está cifrado en reposo con una customer-managed key. Los logs de diagnóstico fluyen a un workspace de Log Analytics; los planes de Defender for Cloud están habilitados en App Service, SQL y Storage.

   Producí una tabla con una fila por capa — física, identidad y acceso, perímetro, red, cómputo, aplicación, datos — nombrando el control del párrafo que la ocupa. Marcá la capa que **no** tiene ningún control del párrafo y decí quién es su dueño.

3. Encontrá la violación de Zero Trust. Criticá esta propuesta de cambio de diseño:

   > "Para simplificar el pipeline, vamos a guardar la contraseña de admin de SQL en una variable del pipeline, permitir `0.0.0.0/0` en el firewall de SQL mientras dure el despliegue, y otorgarle al service principal del despliegue **Owner** en la subscription para que nunca falle por un permiso faltante."

   Para cada una de las tres cláusulas, nombrá el principio de Zero Trust violado y el control específico de Azure que lo arregla.

4. Verificá empíricamente la afirmación sobre managed identity — el caso "ninguna credencial en absoluto":

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

   No hay ningún secreto en ninguna parte de ese flujo — ninguna contraseña, ningún certificado, nada que rotar ni que filtrar. Esa es la capa de identidad de la defensa en profundidad haciendo su trabajo.

### Preguntas de comprensión — Bloque 7

- **Q34.** Enunciá los tres principios de Zero Trust textualmente y dá, para cada uno, un control que hayas configurado antes en este documento.
- **Q35.** "La defensa en profundidad se trata de tener un firewall *y* antivirus." Refutá esto en términos de lo que el modelo realmente asume sobre cada capa.
- **Q36.** En la arquitectura del paso 2, ¿qué capa de defensa en profundidad no tiene ningún control listado, y por qué eso es correcto y no una brecha?
- **Q37.** Zero Trust dice "asumí la brecha". Tomá la arquitectura del paso 2, asumí que la instancia de App Service está completamente comprometida, y enumerá qué puede alcanzar el atacante y qué no — y qué control específico frena cada cosa que no puede alcanzar.
- **Q38.** Explicá por qué una managed identity es un control más fuerte que "un service principal con un client secret guardado en Key Vault", aunque ambos mantengan el secreto fuera del control de código fuente.

---

## Bloque 8 — Microsoft Defender for Cloud

**Concepto bajo evaluación:** Defender for Cloud son dos productos en una sola hoja — **CSPM** (¿estás bien configurado?) y **CWPP** (¿te están atacando ahora mismo?).

### Pasos

1. Registrá el provider y leé el estado actual de los planes.

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

   `Free` acá significa **CSPM fundacional** — siempre activo, sin cargo: secure score, recomendaciones, inventario de activos. Cada nivel `Standard` es un plan pago de Defender que agrega protección de cargas de trabajo (detección de amenazas, alertas).

2. Leé el **secure score** — el único número que produce CSPM.

   ```bash
   az security secure-scores list \
     --query "[].{name:displayName, current:score.current, max:score.max, pct:score.percentage}" -o table
   ```

   ```
   Name    Current    Max    Pct
   ------  ---------  -----  -----
   ascScore      18.4     58   0.32
   ```

3. Descomponé el score en controles, para poder actuar sobre él en vez de admirarlo.

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

   Dos de los tres controles con más puntaje son controles de identidad. Eso no es casualidad — es la propia ponderación de Microsoft sobre dónde empiezan las brechas.

4. Habilitá un plan pago para ver el lado CWPP, y después apagalo enseguida. **Esto factura por recurso por hora.**

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

5. Leé el feed de recomendaciones — la materia prima detrás del score.

   ```bash
   az security assessment list \
     --query "[?properties.status.code=='Unhealthy'].{name:properties.displayName, severity:properties.metadata.severity}" \
     -o table 2>/dev/null | head -12
   ```

6. Notá la superficie de cumplimiento: Defender for Cloud mapea continuamente tu postura contra estándares de **regulatory compliance** (Microsoft Cloud Security Benchmark por defecto; se pueden agregar ISO 27001, PCI DSS, NIST SP 800-53 y otros). Ese mapeo es salida de CSPM, no un producto aparte.

### Preguntas de comprensión — Bloque 8

- **Q39.** Distinguí CSPM de CWPP en una oración cada uno, y ubicá el secure score, el just-in-time VM access y los dashboards de regulatory compliance del lado correcto.
- **Q40.** Tu secure score es 32 %. Un colega propone "lleguemos al 100 % este trimestre". Dá dos razones por las que ese es el objetivo equivocado y decí qué optimizarías en su lugar.
- **Q41.** En el paso 1 todos los planes dicen `Free`. ¿Entonces Defender for Cloud no está haciendo nada? Nombrá con precisión qué seguís teniendo y qué no.
- **Q42.** Defender for Cloud publicita cobertura multicloud. ¿Qué necesita de una cuenta de AWS o GCP para producir recomendaciones, y a cuál de las dos mitades (CSPM/CWPP) sirve primero esa conexión principalmente?
- **Q43.** ¿Por qué "Enable MFA" vale 10 puntos en el paso 3 mientras que "Enable encryption at rest" vale 4? Respondé en términos de frecuencia de ataque, no en términos de la opinión de Microsoft.

---

## Bloque 9 — Escenarios de diagnóstico consolidados

Para cada escenario, nombrá (a) el control que falla, (b) la consulta exacta de CLI o Graph que correrías primero, y (c) el arreglo. Escribí tu respuesta antes de abrir la sección de respuestas.

1. **S1.** Un desarrollador puede ver un Key Vault en el portal, abrir su hoja y leer sus access policies — pero todo intento de leer el valor de un secreto devuelve `Forbidden`. Tiene **Contributor** sobre el resource group.

2. **S2.** La cuenta guest de un contratista recién ingresado se creó hace tres semanas y muestra `externalUserState: PendingAcceptance`. Insiste en que hizo clic en el enlace de la invitación. Los sign-in logs para su dirección no muestran ninguna entrada en tu tenant.

3. **S3.** Después de habilitar una política de Conditional Access que requiere dispositivos compliant, un service principal de automatización que corre despliegues ARM nocturnos empezó a fallar con `AADSTS53003: Access has been blocked by Conditional Access policies`.

4. **S4.** Un ingeniero de soporte necesita reiniciar VMs de producción a las 02:00 durante incidentes. Hoy tiene **Contributor** permanente sobre la subscription de producción. Diseñá el reemplazo usando tres de los mecanismos de este documento.

5. **S5.** `az role assignment list --assignee <user> --scope <resource-group>` devuelve un array vacío, y sin embargo el usuario demostrablemente borra recursos en ese resource group.

6. **S6.** Tu tenant tiene security defaults habilitados. Cumplimiento exige "MFA para administradores, pero las cuentas de servicio que llaman desde el rango de IPs del datacenter están exentas". Explicá por qué la configuración actual no puede expresar esto y qué debe cambiar.

---

## Bloque 10 — Limpieza

Ejecutá esto en orden. Las role assignments deben irse antes que la role definition; el resource group antes que los objetos de grupo solo si querés un `az role assignment list` limpio.

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

El último comando no debe imprimir nada.

---

## Fuentes de referencia

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
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Servicios de directorio

**A1.** **Entra Domain Services** es lo que encaja. La aplicación necesita Kerberos, LDAP y un árbol de OUs; Entra Domain Services provee exactamente eso como servicio administrado — Microsoft parchea, respalda y da alta disponibilidad a los domain controllers, que vos nunca ves.
- **Entra ID** queda descalificado de plano: habla OAuth 2.0 / OpenID Connect / SAML / WS-Fed / SCIM. **No** tiene servicio de emisión de tickets Kerberos, **no** tiene endpoint LDAP y **no** tiene jerarquía de OUs. Un cliente Kerberos no tiene con qué hablar.
- **AD DS sobre VMs IaaS** técnicamente funcionaría, pero queda descalificado por el requisito explícito "sin desplegar ni parchear domain controllers" — serías dueño del ciclo de vida de los DCs, del parcheo, del backup, de la topología de replicación y del diseño de sitios.

**A2.** `onPremisesSyncEnabled: true` significa que el objeto está **masterizado on-premises** en AD DS y proyectado hacia Entra ID por Entra Connect Sync / Cloud Sync. La copia en la nube está aguas abajo. En la práctica: `az ad user update --display-name` o falla o se revierte silenciosamente en el siguiente ciclo de sincronización, porque el atributo on-premises es el autoritativo. El arreglo es cambiarlo en el AD on-premises y dejar que fluya hacia arriba. (El group writeback y el password writeback de Entra Connect son excepciones estrechas y configuradas explícitamente a este flujo unidireccional.)

**A3.** **Habla:** OAuth 2.0, OpenID Connect, SAML 2.0, WS-Federation, SCIM (aprovisionamiento). **No habla:** Kerberos, LDAP, NTLM, Group Policy — ni tiene concepto de unidades organizativas ni un modelo de trusts entre forests/dominios. Entra ID es plano: usuarios, grupos, service principals, sin árbol de OUs.

**A4.** No — no es una réplica de tu forest. La sincronización es **unidireccional**, desde **Entra ID → el dominio administrado**. Los objetos llegan a Entra ID ya sea como cuentas cloud-only o vía Entra Connect desde el AD DS on-premises; Entra Domain Services después los materializa en su propio dominio administrado. Los cambios hechos *dentro* del dominio administrado (nuevas OUs, usuarios nuevos que crees ahí) **no** vuelven a Entra ID, y no hay replicación de trust con tu forest on-premises salvo que configures explícitamente un resource forest trust unidireccional.

**A5.** Los service principals existen porque las aplicaciones también necesitan identidad, y la necesitan con semánticas de ciclo de vida y de credenciales distintas de las de los humanos. Si un pipeline inicia sesión como un humano, perdés **atribución y ciclo de vida independiente**: los audit logs muestran a la persona, no a la automatización, así que no podés distinguir un despliegue nocturno de una acción manual de esa persona; el pipeline se rompe el día que cambian su contraseña, se toman licencia con MFA obligatorio, o se van de la empresa; y el pipeline hereda todos los permisos que tiene ese humano en vez de solo lo que necesita. Sumale que no podés aplicar MFA ni Conditional Access diseñados para humanos a un proceso headless sin romperlo.

### Bloque 2 — Métodos de autenticación

**A6.** El ataque es el **phishing en tiempo real / adversary-in-the-middle (AiTM)**. Una página proxy renderiza un formulario de inicio de sesión convincente, retransmite la credencial al IdP real, le pide a la víctima el código SMS, lo retransmite también, y captura la cookie de sesión resultante. La víctima realmente recibe un código legítimo de Microsoft; nada parece mal. FIDO2 derrota esto porque el autenticador realiza un **desafío-respuesta criptográfico ligado al origen (RP ID)** — la clave privada nunca sale del hardware y el navegador no va a entregar una assertion a `contoso-login.attacker.example` para la credencial registrada en `login.microsoftonline.com`. La propiedad es el **origin binding / resistencia al phishing**; la propiedad secundaria es que no se transmite ningún secreto compartido en absoluto.

**A7.** No. Habilitar un método en la authentication methods policy lo vuelve **disponible** — los usuarios en alcance *pueden* registrarlo y usarlo. Nada lo exige. El control que *exige* autenticación fuerte es **Conditional Access**, específicamente un grant control que requiera una **authentication strength** (la fuerza integrada *Phishing-resistant MFA*, que admite FIDO2, Windows Hello for Business y autenticación basada en certificados, y rechaza SMS/voz/OTP). `isRegistrationRequired` en `includeTargets` empuja al registro pero no es un control de acceso.

**A8.** No es una mala configuración — es SSO funcionando como fue diseñado. El mecanismo es el **primary refresh token (PRT)** en un dispositivo joined/registered (o la cookie de sesión más el refresh token en un navegador). Se intercambia silenciosamente por **access tokens** por recurso, cada uno típicamente válido ~60–90 minutos; el usuario nunca se reautentica porque el PRT/refresh token sigue siendo válido. Dos categorías de control lo acortan: (1) **session controls de Conditional Access** — sign-in frequency, persistent browser session; y (2) **Continuous Access Evaluation (CAE)**, que permite al resource provider rechazar un access token a mitad de su vida ante un evento crítico (cuenta deshabilitada, reseteo de contraseña, cambio de ubicación de red, revocación disparada por un administrador) en lugar de esperar a que expire.

**A9.** Un TAP es un **passcode limitado en el tiempo y opcionalmente de un solo uso** emitido por un administrador. Es una credencial de onboarding porque un empleado nuevo enfrenta un problema de arranque: para registrar un método fuerte (llave FIDO2, Windows Hello, Authenticator) primero tiene que autenticarse, y no tiene con qué. Un TAP es la credencial de una sola vez, suficientemente fuerte, que lo hace pasar por esa puerta y directo a registrar un método real. Es deliberadamente inadecuado para el régimen permanente — expira (de minutos a horas), puede limitarse a un uso, y al ser una cadena compartible no tiene nada de la resistencia al phishing de FIDO2. También es el camino de recuperación correcto cuando alguien pierde su único dispositivo registrado.

**A10.** No. Ambos son **algo que sabés**. Multifactor requiere factores de **dos categorías diferentes** entre: algo que *sabés* (contraseña, PIN, respuesta de seguridad), algo que *tenés* (teléfono, llave FIDO2, certificado en un TPM), algo que *sos* (huella, cara). Dos factores de conocimiento fallan ante el mismo ataque — cualquier cosa que revele uno (phishing, filtración de base de datos, mirar por encima del hombro, ingeniería social) tiende a revelar el otro. Las preguntas de seguridad son además débiles porque las respuestas son frecuentemente públicas.

**A11.** **Defendible, pero solo con controles compensatorios.** El propósito de una cuenta break-glass es sobrevivir a la falla de los mismísimos sistemas que protegen a todos los demás — una caída del proveedor de MFA, una falla de federación, una política de Conditional Access que dejó afuera a todos los administradores, un certificado de federación vencido. Atarla a MFA reintroduce la dependencia de la que existe para escapar. Lo que la vuelve aceptable: una **contraseña larga y aleatoria** (guía de Microsoft: 16+ caracteres) repartida en sobres sellados en manos de personas distintas dentro de una caja fuerte física; **cloud-only** (`*.onmicrosoft.com`, nunca federada, nunca sincronizada); Global Administrator asignado permanentemente en lugar de eligible por PIM; **excluida de todas las políticas de CA**; y **con alerta en absolutamente cada inicio de sesión** vía una regla de Log Analytics / Sentinel que llame al equipo de seguridad. Al menos dos cuentas así, en dispositivos/caminos distintos. Si falta algo de eso, la configuración no es defendible — es simplemente una cuenta de administrador sin monitoreo y sin MFA. La guía actual de Microsoft también permite un método *resistente al phishing y no federado* (una llave FIDO2 en la caja fuerte) en una de las dos cuentas, lo cual es todavía más fuerte.

### Bloque 3 — Identidades externas

**A12.** Quedan bloqueados, y el bloqueo ocurre en el tenant de **Fabrikam**, no en el tuyo. Traza: el guest navega a tu app → el Entra ID de tu tenant ve el objeto de usuario `#EXT#` y determina el home tenant a partir del dominio → **redirige la autenticación al Entra ID de Fabrikam** → el tenant de Fabrikam encuentra la cuenta deshabilitada y se niega a emitir un token → sin token, ninguna assertion vuelve a tu tenant → tu tenant nunca llega al paso de autorización. El objeto guest sigue existiendo en tu directorio y sigue teniendo su membresía de grupo; simplemente es inutilizable porque nada puede autenticarlo. Esta es la propiedad de seguridad central de B2B — el offboarding en el partner revoca automáticamente el acceso en el tuyo — y también su punto ciego: los objetos guest obsoletos se acumulan, que es para lo que existen las **access reviews**.

**A13.** Por defecto, **el home tenant** realiza la autenticación y por lo tanto aplica su propio MFA. Tu tenant aplica **autorización** y puede *además* requerir MFA vía Conditional Access — en cuyo caso al guest se lo desafía de nuevo en tu tenant, un prompt duplicado que a los usuarios les resulta confuso. Los **cross-tenant access settings** resuelven esto: en tus inbound trust settings para Fabrikam podés habilitar *"Trust multifactor authentication from Microsoft Entra tenants"*, y entonces un claim de MFA del home tenant en el token entrante satisface tu requisito de CA sin un segundo desafío. El mismo mecanismo existe para los claims de *compliant device* y *hybrid joined device*. Confiar en eso es un juicio de valor: estás aceptando la postura de MFA de Fabrikam como equivalente a la tuya.

**A14.** **B2C** (o su sucesor, Microsoft Entra External ID for customers). Dos razones estructurales:
1. **Separación de tenants y modelo de objetos.** Los consumidores no deben convertirse en objetos del tenant que contiene a tus empleados, tus grupos, tus asignaciones de Azure RBAC y tus apps internas. B2C es un *tenant separado* con su propio directorio, así que un bug en un flujo de registro no puede exponer tu directorio corporativo. Los guests B2B, en cambio, se aprovisionan en tu workforce tenant — el lugar equivocado para dos millones de desconocidos.
2. **Modelo de identity provider y personalización.** B2C está construido para el **registro de autoservicio** contra identity providers sociales/locales (Google, Facebook, Apple, email+contraseña local) con **user flows** completamente personalizables y con branding, más políticas personalizadas (Identity Experience Framework), incluyendo perfilado progresivo y atributos personalizados. B2B asume que la persona externa **ya tiene una identidad organizacional** en una empresa partner a la que invitás por correo; no hay registro de autoservicio de consumidores, ni branding de la página de login del partner, ni un flujo con IdP social primero.

Una tercera razón que vale la pena decir: escala y precios. B2C/External ID está tarifado para volúmenes de consumo; un workforce tenant con dos millones de guests no es ni la forma ni la curva de costos previstas.

**A15.** Porque el **impulsor del costo es el tráfico de autenticación y emisión de tokens**, no el almacenamiento del directorio. Un objeto guest que nadie usa consume esencialmente nada; un guest que inicia sesión a diario consume infraestructura de autenticación, evaluación de Conditional Access, logging y detección de riesgo. El precio por MAU cobra por lo que realmente cuesta. El comportamiento que fomenta es **invitar libremente y dejar los guests aprovisionados** en vez de borrar y reinvitar para ahorrar plata — que es exactamente lo que querés, porque los ciclos de borrar/reinvitar rompen el acceso a mitad de proyecto y destruyen el rastro de auditoría. (Notá el incentivo que *no* crea: no fomenta limpiar guests obsoletos, que es una tarea de seguridad genuina — de ahí las access reviews, impulsadas por el riesgo y no por la factura. Los precios de External ID de Microsoft incluyen un nivel gratuito sustancial de MAU; consultá la página de precios actual para la cifra.)

**A16.** El riesgo: `allowInvitesFrom: "everyone"` permite que **cualquier usuario member — y, en la configuración por defecto, los propios guests — inviten a personas externas arbitrarias a tu directorio**, donde inmediatamente heredan lo que otorgue el rol Guest User (por defecto, lectura limitada del directorio: pueden enumerar algunos usuarios, grupos y registros de aplicaciones). En un tenant grande esto produce cientos de guests que nadie aprobó, sin registro de justificación de negocio, y una cadena de guest-invita-guest sin dueño. La mitigación menos restrictiva es `allowInvitesFrom: "adminsAndGuestInviters"` — los members pierden la capacidad de invitar, pero podés delegar el directory role **Guest Inviter** a los equipos específicos que lo necesitan, así la colaboración legítima no se centraliza en una cola de tickets. Combinalo con **cross-tenant access settings** (poné en allowlist los dominios de los partners con los que realmente trabajás) y **access reviews** sobre las cuentas guest. El más estricto `none` bloquea a todos salvo a los roles de administración y normalmente solo empuja a la gente al shadow IT.

### Bloque 4 — Conditional Access

**A17.** **Señales (condiciones):** membresía de usuario o grupo; ubicación IP / named location; dispositivo (plataforma, estado, filtro); aplicación o recurso al que se accede; **riesgo** en tiempo real y calculado (sign-in risk y user risk, que requieren Entra ID P2 / Identity Protection); tipo de aplicación cliente (navegador, app móvil/de escritorio, clientes de autenticación heredada como POP/IMAP/SMTP). **Decisiones:** **bloquear** el acceso, u **otorgar** acceso con requisitos. Los requisitos de otorgamiento incluyen: requerir MFA, requerir authentication strength, requerir que el dispositivo esté marcado como compliant, requerir dispositivo Entra hybrid joined, requerir app cliente aprobada, requerir app protection policy, requerir cambio de contraseña, requerir terms of use.

"Requerir un dispositivo compliant" es un **grant control**. Es irrelevante sin **Microsoft Intune** (o un MDM de terceros soportado a través de la integración de partner compliance): compliance es un booleano estampado en el objeto de dispositivo en Entra ID *por el MDM* después de evaluar una política de cumplimiento — cifrado activo, versión de SO en o por encima de un piso, sin jailbreak, antivirus sano. Sin MDM, ningún dispositivo queda marcado como compliant nunca, y habilitar el control deja afuera a todos.

**A18.** Intención: **"Bloquear todos los inicios de sesión que no se originen en Argentina, España o Estados Unidos".** La gramática de Conditional Access no tiene un operador "not in" para ubicaciones; la única forma de expresar el complemento es incluir-todo-menos-las-exclusiones. La formulación ingenua —enumerar los países no confiables en `includeLocations`— falla por dos motivos. **Inmantenible:** hay ~250 códigos de país/región, así que mantendrías una lista de ~247 entradas y la actualizarías cada vez que cambia la lista ISO. **Insegura:** es *default-allow*. Cualquier ubicación que olvides, cualquier IP que la base geográfica no pueda resolver a un país, cualquier región nueva — todo silenciosamente permitido. La forma include-All/exclude-permitida es *default-deny*: todo lo que no bendijiste explícitamente queda bloqueado, y el `includeUnknownCountriesAndRegions: false` en la named location significa que las IPs no resolubles caen fuera del conjunto permitido y por lo tanto quedan bloqueadas. Notá también la limitación honesta: las condiciones de país se apoyan en geolocalización por IP y se derrotan trivialmente con una VPN, así que este es un control grueso, no un control de autenticación.

**A19.**
- **Verificar explícitamente** → `conditions` más `grantControls.builtInControls: ["mfa"]`. El acceso no se otorga porque la solicitud traiga una contraseña válida; la política evalúa quién es el principal (`includeRoles`), a qué está llegando (`includeApplications`) y cómo se conecta (`clientAppTypes`), y después exige una prueba adicional e independiente.
- **Usar acceso con privilegio mínimo** → `includeRoles: ["62e90394-…"]`. La política apunta exactamente al rol Global Administrator y no a todos los usuarios: el requisito más fuerte se aplica al privilegio más alto, que es la expresión operativa de tratar al privilegio como algo acotado y justificado en vez de ambiental. (En un diseño completo esto se combina con PIM, así el rol es eligible en vez de active, y la política de CA se dispara en la activación.)
- **Asumir la brecha** → `clientAppTypes: ["all"]` e `includeApplications: ["All"]`. La política no asume que la credencial está intacta ni que el atacante va a llegar por la puerta de adelante; cubre todas las aplicaciones y todos los tipos de cliente, incluyendo protocolos de autenticación heredada que no pueden hacer MFA y por lo tanto quedan bloqueados de plano. La exclusión break-glass también pertenece acá: es un camino de recuperación diseñado sobre la premisa de que el propio plano de control va a fallar.

**A20.**
- **Security defaults** — correcto para una organización chica sin administrador de identidad dedicado, sin Entra ID P1 y sin necesidad de excepciones. Impone una línea base fija y no configurable: registro de MFA obligatorio para todos los usuarios, MFA obligatorio para administradores, MFA desafiado a los usuarios en inicios de sesión riesgosos, autenticación heredada bloqueada, y acciones privilegiadas en el portal de Azure protegidas. **Licencia: gratis** (incluido en Entra ID Free).
- **Conditional Access** — correcto en cuanto necesitás *cualquier* excepción o *cualquier* condición: exceptuar una cuenta de servicio desde un rango de IPs, requerir dispositivos compliant solo para las apps de finanzas, bloquear por país, requerir MFA resistente al phishing para administradores pero MFA estándar para el resto. **Licencia: Microsoft Entra ID P1** (incluida en Microsoft 365 E3/E5, EMS E3/E5); **P2** adicionalmente para condiciones basadas en riesgo (sign-in risk, user risk) vía Identity Protection.

La trampa: son mutuamente excluyentes, así que la migración es "apagar security defaults y encender un conjunto completo de políticas de CA" — y hay una ventana en el medio donde el tenant está desprotegido. Escribí y validá las políticas en report-only *primero*, después hacé el cambio.

**A21.** **El usuario no fue bloqueado.** El modo report-only evalúa la política contra el inicio de sesión real y registra el veredicto al que *habría* llegado, y después otorga o deniega basándose solo en las políticas que están realmente `enabled`. `reportOnlyFailure` significa "si esta política hubiera estado aplicada, este inicio de sesión habría sido bloqueado (o no habría satisfecho el grant control)". Con `state: "enabled"` el mismo inicio de sesión habría recibido `conditionalAccessStatus: failure` y el usuario habría visto `AADSTS53003 — Access has been blocked by Conditional Access policies`.

El valor operativo es que esta es la única forma de dimensionar el radio de explosión de una política de identidad antes de que te pueda hacer daño. Aprendés, a partir de tráfico real de producción durante un ciclo de negocio completo, exactamente qué usuarios, qué service principals, qué clientes móviles y qué ejecutivos viajando habría roto la política — incluidos los que nadie se acordó de mencionar. Toda caída por Conditional Access en el mundo real es una política que se salteó este paso.

**A22.** El control compensatorio es **la caja fuerte misma más el alertado**: una credencial larga y aleatoria físicamente repartida y sellada, cloud-only y no federada para que no dependa de ningún sistema externo, al menos dos cuentas de ese tipo en caminos independientes y — la parte que realmente cierra el agujero — una **regla de detección que se dispare ante cualquier autenticación de estas cuentas**, ruteada a un pager y no a una bandeja de entrada. Como estas cuentas no se usan prácticamente nunca, la tasa de falsos positivos es casi cero, lo que hace a la alerta inusualmente confiable: un inicio de sesión break-glass es o bien una emergencia genuina de la que ya estás al tanto, o bien un incidente.

Qué monitorear: todos los inicios de sesión (exitosos **y** fallidos), todo cambio de directory role que involucre a estas cuentas, cualquier cambio en la membresía del grupo de exclusión, y cualquier modificación o borrado de las propias políticas de CA. Además, revisá trimestralmente que las cuentas sigan funcionando — una credencial break-glass que expiró silenciosamente es peor que ninguna, porque estás confiando en ella.

### Bloque 5 — Azure RBAC

**A23.** **Security principal** — el grupo `sg-az900-platform-readers`, object ID `c4a2e77b-3f19-4a0d-9d6e-51bb8c2ff4a3`. **Role definition** — `Reader`, cuyo único permiso es `*/read`. **Scope** — `/subscriptions/${SUB_ID}/resourceGroups/rg-az900-identity-lab`. (Los security principals pueden ser usuarios, grupos, service principals o managed identities; los scopes pueden ser management group, subscription, resource group o resource.)

**A24.** En ese resource group: **Contributor** — administración completa de recursos, pero sin la capacidad de otorgar acceso, porque `Contributor.notActions` excluye `Microsoft.Authorization/*/Write`. En un resource group hermano: **solo Reader**, heredado de la asignación en la subscription; la asignación de Contributor está acotada a un resource group y no viaja de costado.

La regla general: **Azure RBAC es aditivo.** Los permisos efectivos son la **unión** de todas las role assignments aplicables en el scope solicitado y en todos los scopes ancestros. No hay precedencia entre role assignments, no hay "gana el más específico", y no hay forma de que una role assignment le reste a otra — `NotActions` solo resta dentro de su propia definición. La única excepción a la aditividad es una **deny assignment**, que se evalúa primero y le gana a todo.

**A25.** **`NotActions` no es una regla de denegación.** Es una resta *dentro de una role definition*: permisos efectivos de ese rol = `Actions` menos `NotActions`. Si otra role assignment otorga la misma operación, el usuario la tiene — que `Contributor.notActions` excluya `Microsoft.Authorization/*/Write` no hace nada para frenar a alguien que además es **User Access Administrator** en otro punto de la jerarquía.

Una **deny assignment** es un objeto separado que bloquea a un principal de una acción **sin importar ninguna role assignment**. El orden de evaluación es: **(1) deny assignments** — si alguna coincide, el acceso se deniega, punto; **(2) role assignments** — la unión aditiva descrita arriba. Así que `NotActions` moldea lo que un rol otorga; una deny assignment sobrescribe lo que otorgan todos los roles. Las deny assignments las crean construcciones administradas por Azure (Azure Managed Applications, Azure Blueprints) para que un publicador pueda proteger recursos del subscription owner que los aloja; escribirlas directamente no es una herramienta de propósito general.

**A26.** La separación **control plane / data plane**. **Owner** otorga `Actions: ["*"]` — toda operación de administración sobre la storage account, incluyendo leer sus propiedades, rotar sus claves y cambiar sus reglas de red. No otorga **ningún `DataActions`**, y leer los bytes de un blob con una identidad de Entra requiere `Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read`, que es un **DataAction**. De ahí: control total del contenedor, ningún acceso a su contenido.

El arreglo es asignar además un rol de plano de datos — **`Storage Blob Data Reader`** para solo lectura, o `Storage Blob Data Contributor` para lectura/escritura — a nivel de storage account, de contenedor, o (para un scope más fino) de prefijo de blob.

Lo instructivo es *por qué* existe este diseño: permite darle al equipo de plataforma control operativo de una storage account sin darle visión de los datos del cliente. También es la razón por la que "Owner sobre el recurso" no es un proxy seguro de "puede leer los datos" en una auditoría — y, a la inversa, por qué Owner no es realmente un límite: el Owner puede simplemente asignarse `Storage Blob Data Reader`, o leer las claves de la cuenta y saltarse por completo la autorización de Entra. Deshabilitar el acceso por shared key (`allowSharedKeyAccess: false`) es lo que hace que el rol de plano de datos sea la verdadera compuerta.

**A27.** Porque `/` es el **scope raíz (tenant)**, y un rol asignable ahí sería asignable sobre **todos los management groups y todas las subscriptions del tenant, incluidas subscriptions que todavía no existen**. Azure reserva deliberadamente ese alcance: la asignación en el scope raíz no es una operación ordinaria sino el resultado de `elevateAccess`, que está restringido a Global Administrators, se registra individualmente y se espera que se revierta de inmediato.

Un rol que permitiera `/` en `AssignableScopes` sería un **vector de escalada de privilegios de autoservicio, permanente y de alcance tenant-wide**: cualquiera con `Microsoft.Authorization/roleAssignments/write` en cualquier lado podría engancharlo en la cima de la jerarquía. Además rompería la propiedad de contención que hace útiles a los management groups — la garantía de que el radio de explosión de una asignación está acotado por un scope que alguien eligió explícitamente. El patrón previsto para un alcance amplio es listar el **root management group** (o el management group relevante) en `AssignableScopes`, que es amplio pero sigue siendo un objeto con un dueño, un rastro de auditoría y una superficie de políticas.

**A28.** Porque `Microsoft.Authorization/roleAssignments` usa el **nombre** del recurso como identificador único de la asignación, y debe ser un GUID — la plataforma no tiene otra clave para "¿es esta la misma asignación?". `guid(resourceGroup().id, principalId, readerRoleId)` es una **función pura de las tres cosas que definen la asignación**, así que las mismas entradas siempre producen el mismo nombre.

Segundo deployment, `guid()` determinista: ARM computa el nombre idéntico, encuentra la asignación existente sin cambios, y el deployment tiene éxito como no-op — **idempotente**, que es todo el requisito para un pipeline que corre en cada commit.

Segundo deployment, nombre literal legible: falla de inmediato, porque `'reader-for-platform-group'` no es un GUID y el resource provider rechaza el nombre de plano. Incluso si suministraras un GUID *válido* hardcodeado, habrías creado otro modo de falla — esa constante no se deriva del scope ni del principal, así que desplegar la misma plantilla en un segundo resource group o con un `principalId` distinto colisionaría en un nombre que se supone único por asignación, o significaría silenciosamente "la misma asignación" para dos cosas que no lo son. El determinismo tiene que venir de las entradas, no de una constante.

**A29.** **Principal:** un **grupo** (por ejemplo `sg-external-audit-2026q3`) que contenga a la gente de la firma como **guests B2B** — nunca asignaciones a usuarios individuales, así el onboarding y el offboarding es un cambio de membresía y el rastro de auditoría es coherente. **Rol:** **`Reader`** (`*/read` en el plano de control) — y notá explícitamente que esto no otorga acceso al plano de datos; si los auditores necesitan leer contenido de blobs o de Key Vault, eso es un rol de datos separado y deliberadamente acotado, no un ascenso a Contributor. **Scope:** el **management group** que contiene las 40 subscriptions — una sola asignación heredada por todas ellas.

Justificación: el scope de management group significa una asignación en vez de 40, cubre automáticamente las subscriptions que se agreguen al grupo durante el trimestre, y la revocación al final del trabajo es un solo borrado en vez de una checklist de 40 ítems que vas a equivocar.

Vale la pena agregar para un trabajo real, aunque exceda la pregunta estricta: hacé la asignación **PIM-eligible con fecha de expiración** el último día del trimestre para que se autorevoque, y programá una **access review** — "por un trimestre" es un requisito que la plataforma puede imponer, y si lo dejás librado a un recordatorio de calendario el acceso va a seguir vivo el año que viene.

### Bloque 6 — Roles de Entra vs. roles de Azure

**A30.**

| | Roles de Microsoft Entra | Roles de Azure (RBAC) |
|---|---|---|
| **¿Qué gobierna?** | Objetos de directorio y servicios de Microsoft 365 / Entra: usuarios, grupos, registros de aplicaciones, service principals, dispositivos, políticas de Conditional Access, dominios, licencias, administración de Exchange/SharePoint/Intune | **Recursos** de Azure administrados a través de Azure Resource Manager: VMs, storage accounts, VNets, Key Vaults, clústeres AKS — más, vía `DataActions`, los datos dentro de algunos de ellos |
| **Granularidad de scope** | Principalmente **tenant-wide**; un subconjunto de roles admite asignación por **administrative units** y **app-scoped** (un solo service principal / una sola aplicación) | **Cuatro niveles**: management group → subscription → resource group → resource, con herencia hacia abajo |
| **Ejemplo de rol de alto privilegio** | **Global Administrator** (también: Privileged Role Administrator, User Administrator, Application Administrator) | **Owner** (también: Contributor, User Access Administrator) |
| **API / plano** | **Microsoft Graph** — `graph.microsoft.com`, plano de directorio | **Azure Resource Manager** — `management.azure.com`, plano de control |

La trampa del examen es la última fila: son **sistemas de autorización independientes**. Ni `az role assignment list` ni `az rest` contra Graph pueden ver las asignaciones del otro; ser Owner de todas las subscriptions no otorga nada en el directorio, y ser Global Administrator no otorga nada sobre los recursos de Azure.

**A31.** **No es cierto de fábrica.** Un Global Administrator tiene poder de directorio — puede crear usuarios, resetear contraseñas, consentir aplicaciones, editar Conditional Access — pero por defecto tiene **cero** asignaciones de Azure RBAC y por lo tanto no puede ver, mucho menos borrar, ninguna VM.

Qué tiene que pasar primero: invoca **`elevateAccess`**, que le otorga a su propio principal **User Access Administrator en el scope raíz `/`**. Ese rol por sí mismo tampoco le permite borrar una VM — `User Access Administrator` es `*/read` más `Microsoft.Authorization/*` — pero le permite **asignarse Owner** en cualquier management group o subscription, y después borrar lo que se le antoje. Dos pasos, ambos deliberados.

Rastro de auditoría: la elevación escribe una entrada en el **directory audit log** de Entra ID y la posterior asignación de rol en el scope raíz aparece en el **Azure Activity Log**, junto con cada asignación que haga después. La asignación con scope `/` también es visible sin más para cualquiera que corra `az role assignment list --scope "/"`. Es una operación ruidosa por diseño — que es exactamente por qué la postura correcta es alertar sobre ella en vez de asumir que no va a pasar.

**A32.** Porque crea **privilegio permanente en el scope más amplio posible, en manos de un humano, indefinidamente** — la asignación no expira por su cuenta, y después de la alerta inicial nada vuelve a hacerla visible. Una sola sesión comprometida, token phisheado o notebook robada hereda entonces el control de todas las subscriptions del tenant, presentes y futuras, sin ningún paso de escalada adicional. El radio de explosión es todo el patrimonio y la ventana de exposición no tiene límite.

Viola **el acceso con privilegio mínimo** de la forma más directa — el scope raíz es por definición más de lo que cualquier tarea específica requiere, y "permanente" es más de lo que cualquier incidente requiere. También viola **asumir la brecha**: dejarlo puesto es apostar a que la cuenta del administrador nunca se va a comprometer, que es precisamente la suposición que Zero Trust te dice que no hagas. El patrón correcto es elevar → hacer la única cosa (normalmente: asignar un rol correctamente acotado al grupo correcto) → **revocar de inmediato**, y tratar cualquier asignación de larga duración con scope `/` como un incidente.

**A33.** Una asignación **active** significa que el privilegio está vivo 24/7: la ventana de oportunidad del atacante es **toda la vida de la asignación** — cada hora de cada día, esté la persona trabajando, durmiendo o de vacaciones. Una sesión robada en cualquier momento entrega el privilegio completo al instante.

Una asignación **eligible** significa que el privilegio está dormido hasta que el usuario lo **activa** — lo cual requiere reautenticación (típicamente MFA), una justificación escrita, opcionalmente la aprobación de otra persona, y que expira automáticamente tras un tiempo acotado (habitualmente 1–8 horas). La ventana del atacante se encoge de "siempre" a "solo durante los períodos de activación cortos y explícitamente solicitados", e incluso caer dentro de esa ventana es más difícil: el atacante también tiene que satisfacer el desafío de activación. El resto del tiempo, la cuenta comprometida simplemente no tiene el rol — no hay nada que robar.

El beneficio de segundo orden es la detección: como la activación es un evento discreto, justificado y registrado, "quién era Owner a las 03:14 del martes y por qué" se vuelve una pregunta respondible en vez de un encogimiento de hombros.

### Bloque 7 — Zero Trust y defensa en profundidad

**A34.** Los tres principios:

1. **Verificar explícitamente** — siempre autenticar y autorizar sobre todos los puntos de datos disponibles (identidad, ubicación, salud del dispositivo, servicio, carga de trabajo, clasificación de datos, anomalías). *Control de este documento:* la política de Conditional Access del Bloque 4 que requiere MFA para administradores, que evalúa usuario, rol, aplicación, tipo de cliente y ubicación en vez de aceptar la contraseña sola.
2. **Usar acceso con privilegio mínimo** — limitar con just-in-time y just-enough-access (JIT/JEA), políticas adaptativas basadas en riesgo y protección de datos. *Control de este documento:* el custom role **AZ900 Lab VM Restart Operator** del Bloque 5, que otorga exactamente `virtualMachines/read` y `virtualMachines/restart/action` en vez de Contributor; y la asignación de `Reader` a nivel de resource group en vez de a nivel de subscription.
3. **Asumir la brecha** — minimizar el radio de explosión, segmentar el acceso, verificar el cifrado extremo a extremo, usar analítica para ganar visibilidad e impulsar la detección de amenazas. *Control de este documento:* las asignaciones con scope de resource group que acotan la herencia, el monitoreo break-glass del Bloque 4, y el alertado de Defender for Cloud del Bloque 8. La managed identity del paso 4 también pertenece acá — no hay credencial que una brecha pueda exfiltrar.

**A35.** La refutación es que la oración describe **dos productos en dos capas**, mientras que la defensa en profundidad es una afirmación sobre **la falla asumida**. La premisa del modelo es que **toda capa va a ser vulnerada tarde o temprano**, así que cada capa existe para demorar al atacante, reducir lo que la brecha alcanza y generar una oportunidad de detección — no para ser la capa que finalmente funcione. Bajo esa premisa, la pregunta correcta nunca es "¿tengo firewall y antivirus?" sino "si se saltean el WAF, ¿qué alcanza el atacante después, y cuánto le cuesta esa capa siguiente?".

Tres consecuencias que la versión ingenua se pierde. **Las capas deben ser independientes:** un firewall y un antivirus que fallan ambos ante la misma credencial de administrador robada son una sola capa con dos sombreros. **Las capas son un conjunto definido, no una lista de compras:** física, identidad y acceso, perímetro, red, cómputo, aplicación, datos — una brecha en la capa de datos no se compensa con dos productos en el perímetro. **La capa más interna son los datos:** el cifrado en reposo, el cifrado en tránsito y la autorización de plano de datos importan precisamente porque el modelo asume que el atacante pasa la red, algo que el encuadre de firewall-y-antivirus trata como impensable.

**A36.**

| Capa | Control de la arquitectura |
|---|---|
| Física | **Ninguno listado** |
| Identidad y acceso | Autenticación con Entra ID, Conditional Access requiriendo MFA, user-assigned managed identity con `Key Vault Secrets User` |
| Perímetro | Azure Front Door con una política de WAF (también protección DDoS en el borde de la plataforma) |
| Red | Private endpoint para Azure SQL, NSG en la subnet |
| Cómputo | App Service como plataforma administrada (runtime parcheado, sin SO expuesto); Defender for App Service |
| Aplicación | Las reglas de capa de aplicación del WAF, más Defender for App Service; autorización a nivel de app dentro de la propia aplicación |
| Datos | Transparent Data Encryption en SQL, cifrado con customer-managed key en Storage, `Key Vault Secrets User` acotando quién lee qué secreto |

La capa vacía es la **física**, y es correcto y no una brecha porque es **responsabilidad de Microsoft bajo el modelo de responsabilidad compartida**. En un despliegue PaaS el cliente nunca toca el datacenter: el control de acceso físico, la biometría, las cámaras, la destrucción segura de medios y la resiliencia de las instalaciones las opera Azure y se evidencian mediante atestaciones de terceros (ISO 27001, SOC 1/2/3, PCI DSS), que consumís a través del Service Trust Portal en vez de implementarlas. Un control que no podés implementar y del que no sos responsable no es un agujero en tu diseño — pero sigue siendo una capa que tenés que poder *evidenciar* ante un auditor, por lo que "no aplica" es la formulación equivocada y "propiedad del proveedor, atestada" es la correcta.

**A37.**

**Alcanzable.** La memoria de proceso y el disco de la propia aplicación, incluyendo cualquier secreto cargado en ese momento. El **endpoint de tokens de la managed identity** en el instance metadata service — así que el atacante puede acuñar tokens como esa identidad y usar todo aquello para lo que esté autorizada: específicamente, **leer los secretos de Key Vault que cubre `Key Vault Secrets User`**. Con esos secretos, y desde dentro de la integración con la VNet del App Service, puede alcanzar la **base de datos SQL a través del private endpoint** y leer lo que el principal de base de datos de la app pueda leer. El egreso de red saliente, salvo que esté explícitamente restringido.

**Inalcanzable, y qué frena cada cosa:**
- **Escribir o borrar secretos de Key Vault, o leer certificados/claves** — `Key Vault Secrets User` es solo lectura sobre secretos; el RBAC de Key Vault acota el plano de datos por tipo de operación.
- **Otras subscriptions, otros resource groups, el plano de control de ARM en general** — las **asignaciones de Azure RBAC** de la managed identity la acotan; una asignación de `Key Vault Secrets User` sobre un vault no otorga nada en ningún otro lado. Este es el rédito del privilegio mínimo.
- **La base de datos SQL desde cualquier lugar que no sea esa subnet** — el **private endpoint** significa que SQL no tiene endpoint público que atacar; el **NSG** restringe desde qué subnet puede originarse el tráfico. Un atacante que exfiltre la cadena de conexión no puede usarla desde su propia máquina.
- **Leer los archivos de datos de SQL o los blobs de storage por debajo del servicio** — **TDE** y el cifrado con **customer-managed key** significan que los bytes en reposo no son utilizables sin el material de clave, que vive en Key Vault bajo autorización separada.
- **Los demás usuarios del tenant, o la escalada de privilegios vía identidad** — la carga de trabajo comprometida no tiene ningún directory role; **Conditional Access + MFA** protege el camino de inicio de sesión humano, que la identidad de carga de trabajo no puede recorrer.
- **Hacer todo esto en silencio** — los logs de diagnóstico de **Log Analytics** y los planes de **Defender for Cloud** sobre App Service, SQL y Storage generan la señal de detección: patrones anómalos de acceso a Key Vault, consultas SQL inusuales, egreso inesperado.

El resumen honesto: el radio de explosión es "los secretos de una app y los datos de una base de datos", no "la subscription". Esa distancia entre ambas cosas es lo que compró la defensa en profundidad, y la exposición remanente es la que te dice dónde invertir después — un acotamiento más estrecho de Key Vault, un principal de base de datos con menos derechos y restricción de egreso.

**A38.** Ambos mantienen el secreto fuera del control de código fuente, pero **una managed identity no tiene secreto en absoluto**, y esa diferencia se propaga:

- **Nada que filtrar.** Un client secret existe como una cadena; una cadena puede imprimirse en un log de depuración, volcarse en una excepción, copiarse en un ticket de soporte, quedar en caché en un artefacto de build, o ser leída del vault por cualquiera con permisos de secretos sobre el vault. La credencial de una managed identity la aprovisiona y rota Azure y nunca se expone a la carga de trabajo — la app recibe un **access token** de corta vida desde el endpoint de metadatos de la instancia, no una credencial de larga duración.
- **Nada que rotar, así que nada que expire.** Los client secrets tienen fecha de vencimiento, y la caída clásica de viernes a la noche es un secreto que nadie renovó. Los service principals basados en certificados simplemente mueven el problema al vencimiento del certificado. La rotación de una managed identity la maneja la plataforma.
- **El problema de arranque se resuelve, no se traslada.** "Secreto en Key Vault" sigue requiriendo que la app se autentique *ante Key Vault* — ¿con qué? O bien con otro secreto (tortugas hasta el fondo) o con una managed identity, en cuyo caso la managed identity era la solución real.
- **El ciclo de vida está ligado al recurso.** Borrás el App Service y una identidad system-assigned se borra con él. Un service principal huérfano con un secreto válido puede sobrevivir años a la carga de trabajo para la que se creó, que es así como se acumulan credenciales de alto privilegio obsoletas.
- **Radio de explosión ante el robo.** Robás un client secret y el atacante puede autenticarse como ese principal **desde cualquier lado, hasta que expire**. Robás un token de managed identity y es de corta vida, y obtenerlo requirió ejecución de código en el recurso en primer lugar — el atacante ya tenía que estar adentro.

La debilidad residual, dicha honestamente: un atacante con ejecución de código en el recurso *puede* acuñar tokens desde el endpoint de metadatos (ver A37), así que una managed identity no protege contra una carga de trabajo comprometida — protege contra el robo de credenciales, la proliferación de credenciales y el vencimiento de credenciales. Que es por lo que la asignación sobre ella igual tiene que ser de privilegio mínimo.

### Bloque 8 — Defender for Cloud

**A39.** **CSPM (Cloud Security Posture Management)** — evalúa continuamente la configuración contra un benchmark de seguridad y te dice dónde estás *mal configurado*, antes de que pase nada. **CWPP (Cloud Workload Protection Platform)** — detección y respuesta ante amenazas en tiempo de ejecución sobre las propias cargas de trabajo, que te dice que algo *está pasando ahora*.

Ubicación: **Secure score → CSPM** (es la medida agregada de la postura de configuración). **Dashboards de regulatory compliance → CSPM** (los mismos datos de postura mapeados sobre ISO 27001, PCI DSS, NIST SP 800-53). **Just-in-time VM access → CWPP** — lo entrega el plan pago **Defender for Servers** y actúa sobre la superficie de ataque viva, manteniendo cerrados los puertos de administración (RDP/SSH) y abriéndolos, por usuario y por IP de origen, solo durante una ventana de tiempo solicitada. La línea CSPM/CWPP no es "prevención vs. detección" sino "evaluación del estado vs. protección de cargas de trabajo en ejecución"; JIT es preventivo, y sigue siendo CWPP.

**A40.** Dos razones por las que 100 % es el objetivo equivocado:

1. **El score es un promedio ponderado sobre recomendaciones que eligió Microsoft, no una medida de tu riesgo.** Cuenta controles que pueden ser irrelevantes para tu patrimonio (recomendaciones para servicios que usás de forma trivial) y no puede ver controles que satisfacés por otros medios — un control compensatorio implementado fuera de Azure, un recurso que es deliberadamente público porque sirve un sitio web público, una subscription que es un sandbox por diseño. Perseguir el número recompensa suprimir o "arreglar" hallazgos que nunca importaron.
2. **El costo del último tramo no tiene techo y la reducción marginal de riesgo sí.** Los puntos porcentuales finales típicamente exigen habilitar planes pagos de Defender en todos los recursos, remediar cargas de trabajo heredadas que no se pueden cambiar sin un proyecto de migración, y cerrar hallazgos en sistemas programados para dar de baja. Mientras tanto el score se mueve cada vez que desplegás un recurso, así que "100 %" no es un estado que sostenés — es un estado que tocás e inmediatamente perdés, lo cual convierte un programa de seguridad en una cinta de correr.

Qué optimizar en su lugar: **los controles de mayor puntaje y mayor severidad que mapean a tu modelo de amenazas real, seguidos como tendencia y no como valor absoluto.** Concretamente — trabajá los controles del paso 3 de arriba hacia abajo por valor de puntos (están ponderados por puntos precisamente porque reflejan la frecuencia de las brechas), arreglá *todos* los recursos unhealthy dentro de un control ya que la remediación parcial de un control da crédito parcial, **exceptuá** formalmente los hallazgos que genuinamente no aplican para que el denominador refleje la realidad, y sostené la línea de que el score no debe *retroceder* release tras release. Una tendencia creciente con exenciones documentadas es una posición defendible ante un auditor; "llegamos al 100 % en marzo" no lo es.

**A41.** Está haciendo bastante — **el CSPM fundacional es gratis y está siempre activo** una vez registrados los resource providers. Seguís teniendo: **inventario de activos** en toda la subscription, **evaluaciones de seguridad continuas** contra el Microsoft Cloud Security Benchmark, el **secure score** y su desglose por control, **recomendaciones de seguridad** con pasos de remediación (muchas con un "Fix" de un clic), visibilidad de **regulatory compliance** contra el benchmark por defecto, y la capacidad de definir **exenciones** e imponer vía Azure Policy.

Lo que **no** tenés sin los planes pagos: **detección de amenazas y alertas de seguridad** sobre las cargas de trabajo — sin alerta de acceso anómalo a blobs en Storage, sin alerta de inyección SQL o de fuerza bruta en la base de datos, sin detección de malware/comportamiento ni integración con EDR en servidores, sin detección de amenazas en tiempo de ejecución en contenedores. También ausentes: **just-in-time VM access**, **adaptive application controls**, **file integrity monitoring**, **evaluación de vulnerabilidades y escaneo de secretos sin agente**, **análisis de rutas de ataque y el cloud security graph** (que requieren Defender CSPM, un plan pago distinto del CSPM fundacional).

La versión corta: lo gratis te dice **cómo estás configurado**; lo pago te dice **que te están atacando**. Ninguno sustituye al otro, y un tenant con buen secure score y sin CWPP es un edificio bien cerrado con llave y sin alarma.

**A42.** Necesita un **conector** — una identidad autorizada, de solo lectura por defecto, en la cuenta ajena. Para **AWS**, creás un conector de AWS que aprovisiona un **rol IAM** que Defender for Cloud asume entre cuentas (mediante plantillas de CloudFormation o Terraform que Microsoft provee); para **GCP**, un conector de GCP usando **workload identity federation** con una service account. En ambos casos al conector se le otorgan permisos para **leer la configuración** en toda la cuenta/proyecto (o en una organización de AWS / organización de GCP completa), y los recursos ajenos aparecen entonces en el inventario de Defender for Cloud como activos de primera clase.

Esa conexión sirve **primero a CSPM**, y necesariamente: leer la configuración alcanza para evaluar la postura, producir recomendaciones, contribuir al secure score y mapear los hallazgos a estándares de cumplimiento — todo lo cual empieza a funcionar en cuanto se autoriza el conector. **CWPP viene después y cuesta más**, porque proteger cargas de trabajo requiere llegar *adentro* de ellas: el plan Defender for Servers sobre una instancia EC2 o GCE necesita el agente de Azure Arc y el agente de Defender desplegados en cada máquina, Defender for Containers necesita agentes en el clúster EKS/GKE, y Defender for SQL necesita cobertura sobre el motor de base de datos. La configuración la podés leer desde el plano de control; el comportamiento en tiempo de ejecución hay que instrumentarlo.

**A43.** Porque los puntajes están ponderados por **con qué frecuencia la ausencia de cada control aparece efectivamente en una brecha real**, y los dos modos de falla no son ni remotamente igual de frecuentes.

**Los ataques a credenciales son el vector de acceso inicial dominante a escala de nube** — password spray, credential stuffing contra contraseñas reutilizadas, phishing y malware infostealer cosechando credenciales guardadas. Son baratos, automatizados, corren continuamente contra todos los tenants de internet, y no requieren ninguna proximidad a tu infraestructura. MFA es el único control que rompe la abrumadora mayoría de ellos, porque una contraseña válida deja de ser suficiente. La propia telemetría de Microsoft ha ubicado consistentemente la reducción del riesgo de compromiso de cuentas gracias a MFA en el rango de "más del 99 %". Un tenant sin MFA no está en riesgo teórico; lo están sondeando en este momento.

**El cifrado en reposo defiende contra un escenario mucho más raro**: el robo físico, o la disposición inadecuada, de los medios de almacenamiento en un datacenter de Azure — una instalación con control de acceso biométrico, vigilancia continua y destrucción de medios atestada. También importa para el cumplimiento y para la historia del control con customer-managed key. Pero **no hace nada** contra el atacante que llega con credenciales válidas, porque ese atacante lee los datos a través del servicio, que los descifra de forma transparente para él. El cifrado en reposo es lo mínimo indispensable y está mayormente activo por defecto; no es donde se ganan o se pierden las brechas.

De ahí la ponderación: 10 puntos para el control que frena el ataque que enfrentás cada hora, 4 para el control que frena el ataque que prácticamente nunca ocurre en un datacenter hiperescala. La lección general para leer el secure score — los valores de puntos son un **prior ponderado por frecuencia sobre el comportamiento del atacante**, que es por lo que trabajar la lista de arriba hacia abajo es mejor estrategia que trabajarla alfabéticamente o por facilidad de remediación.

### Bloque 9 — Escenarios de diagnóstico

**S1 — Key Vault: un Contributor ve el vault pero no puede leer secretos.**
- **(a) Control que falla:** la separación **control plane / data plane**, exactamente como en A26. `Contributor` otorga `Actions: *` menos las escrituras de autorización — administración completa del objeto vault — pero **ningún permiso de plano de datos** sobre secretos. Qué modelo de plano de datos aplica depende del vault: si usa **Azure RBAC para el plano de datos** (`enableRbacAuthorization: true`), el desarrollador necesita un rol de datos; si usa el modelo heredado de **access policy**, necesita una entrada de access policy.
- **(b) Primera consulta:**
  ```bash
  az keyvault show --name <vault> \
    --query "{rbac:properties.enableRbacAuthorization, policies:properties.accessPolicies[].objectId}" -o json
  az role assignment list --scope "<vault-resource-id>" --include-inherited \
    --query "[].{role:roleDefinitionName, principal:principalName}" -o table
  ```
- **(c) Arreglo:** si `enableRbacAuthorization: true`, asigná **`Key Vault Secrets User`** en el scope del vault (o del secreto individual). Si es `false`, agregá una access policy que otorgue `get`/`list` sobre secretos — pero el mejor arreglo es migrar el vault al modelo RBAC, para que el acceso al vault lo gobierne el mismo sistema, el mismo rastro de auditoría y las mismas herramientas de PIM/access reviews que todo lo demás. Notá el filo afilado que vale la pena contarle al estudiante: un Contributor **puede** otorgarse a sí mismo el rol de datos o cambiar la access policy, así que Contributor no es un límite de datos — es una demora y una entrada de auditoría.

**S2 — Guest trabado en `PendingAcceptance`, cero entradas en el sign-in log.**
- **(a) Control que falla:** la invitación nunca se **canjeó** — y cero inicios de sesión en *tu* tenant prueba que la falla ocurre antes de que se llegue siquiera a tu tenant. Las causas realistas, en orden: el correo de invitación quedó en cuarentena o nunca se entregó en el partner; el contratista canjeó estando con sesión iniciada en una cuenta *distinta*, así que el consentimiento quedó ligado en otro lado; el canje de la invitación está bloqueado por los **cross-tenant access settings** (tus settings salientes / los entrantes de ellos para B2B collaboration, o una allowlist de dominios que omite el suyo); o el enlace de canje expiró.
- **(b) Primera consulta:**
  ```bash
  az ad user show --id "<guest-upn-with-#EXT#>" \
    --query "{state:externalUserState, changed:externalUserStateChangeDateTime, mail:mail}" -o json
  # Redemption attempts land in the directory audit log, not the sign-in log:
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?\$filter=activityDisplayName eq 'Redeem external user invite'&\$top=10" \
    --query "value[].{when:activityDateTime, result:result, reason:resultReason, target:targetResources[0].userPrincipalName}" -o table
  ```
- **(c) Arreglo:** reemití la invitación con `sendInvitationMessage: true` **y** capturá `inviteRedeemUrl` de la respuesta, después mandale esa URL al contratista por un canal que vos controles (el correo es la parte frágil, no el mecanismo). Indicale que la abra en una **ventana de navegación privada** para que una sesión vieja no secuestre el canje. Si el audit log muestra que el canje fue rechazado, revisá los cross-tenant access settings de ambos lados y la política saliente del partner. No borres ni recrees el objeto guest como primera medida — eso descarta las membresías de grupo y las role assignments ya adjuntas.

**S3 — Service principal roto por una política de Conditional Access de dispositivo compliant.**
- **(a) Control que falla:** una política de Conditional Access con alcance `includeUsers: ["All"]` y un **grant control basado en dispositivo**. Un service principal **no tiene dispositivo** — no puede enrolarse en Intune, no puede marcarse como compliant, y no puede ser Entra hybrid joined — así que el grant control es insatisfacible y el inicio de sesión se rechaza con `AADSTS53003`. El error de fondo es conceptual: **los controles de dispositivo son un control de sesión humana/interactiva**, y aplicarlos a identidades de carga de trabajo es un error de categoría.
- **(b) Primera consulta:**
  ```bash
  # Which policies applied to that sign-in, and what did each conclude?
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=appId eq '<app-id>'&\$top=5" \
    --query "value[].{when:createdDateTime, err:status.errorCode, ca:conditionalAccessStatus, policies:appliedConditionalAccessPolicies[?result!='notApplied'].{name:displayName,result:result}}" -o json
  ```
  Para un service principal, revisá además la colección de inicios de sesión de identidades de carga de trabajo: `.../auditLogs/signIns?$filter=signInEventTypes/any(t: t eq 'servicePrincipal')`.
- **(c) Arreglo:** **excluí el service principal de la política dirigida a usuarios** — pero no te quedes ahí, porque una exclusión incondicional es un agujero. Reemplazá la cobertura con una **política de Conditional Access para identidades de carga de trabajo** (Microsoft Entra Workload ID Premium), que apunta a service principals y soporta las condiciones que *sí* tienen sentido para un llamador headless: **ubicación** (restringir a los rangos de IP del datacenter o de los agentes de build) y **riesgo** (Workload Identity Protection). Estructuralmente, el patrón correcto son dos políticas — una para humanos con controles de dispositivo y MFA, otra para identidades de carga de trabajo con controles de red y riesgo — no una política con una lista de exclusiones creciente. Mejor todavía, si el pipeline corre en Azure, reemplazá el secreto del service principal por una **managed identity** o **workload identity federation** para que no haya credencial que robar en primer lugar.

**S4 — Contributor permanente para reinicios de VM a las 02:00.**

El reemplazo usa tres mecanismos de este documento:

1. **Un custom role en lugar de Contributor.** El ingeniero necesita leer VMs y reiniciarlas, no crearlas, redimensionarlas, borrarlas ni reconfigurarlas. Asigná la definición **`AZ900 Lab VM Restart Operator`** del Bloque 5 — `virtualMachines/read`, `virtualMachines/restart/action`, `instanceView/read`, más las lecturas de alert rules y resource groups necesarias para navegar el portal. Compará el delta con honestidad: Contributor sobre una subscription de producción incluye borrar la base de datos, cambiar las reglas de red y desasociar los discos. Nada de eso hace falta para reiniciar una VM a las 02:00.
2. **PIM: eligible, no active.** Hacé la asignación **eligible** en vez de active, con activación que requiera MFA, una justificación escrita y una referencia a un ticket de incidente, acotada a un máximo de 4 horas y con expiración automática. A las 02:00 el ingeniero activa en menos de un minuto; en todas las demás horas del año la cuenta no tiene nada. Esto es A33 aplicado: la ventana del atacante colapsa de "siempre" a "el puñado de horas por trimestre durante un incidente genuino", y cada activación es una entrada de log discreta, atribuible y justificada.
3. **Conditional Access sobre la activación.** Requerí **MFA** — idealmente una **authentication strength** de MFA resistente al phishing — al activar el rol, para que una contraseña phisheada no pueda activarlo ni siquiera durante un incidente. Agregá cumplimiento de dispositivo si los ingenieros de guardia usan dispositivos administrados.

Dos detalles de apoyo que lo hacen funcionar en la práctica: asigná a un **grupo** (`sg-oncall-vm-operators`) hecho PIM-eligible, así la rotación de guardia es un cambio de membresía y no un cambio de rol; y acotá la asignación a los **resource groups que contienen las VMs de producción**, no a la subscription, para que la herencia no la extienda silenciosamente. Por último, alertá sobre las activaciones — una activación a las 02:00 sin un incidente correspondiente es la señal que querés.

**S5 — `az role assignment list` vacío, y sin embargo el usuario borra recursos.**
- **(a) Control que falla:** nada está fallando — **la consulta está mal.** `az role assignment list --assignee <user> --scope <rg>` muestra las asignaciones **en ese scope exacto** para ese principal directamente. Se pierde dos cosas a la vez: las asignaciones **heredadas de scopes ancestros** (la subscription o un management group por encima), y las asignaciones que se tienen **a través de la membresía de grupo** en vez de por el objeto de usuario.
- **(b) Primera consulta:**
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
- **(c) Arreglo:** no hay nada que remediar técnicamente — el hallazgo es que el permiso efectivo viene de **`Contributor` en el scope de la subscription vía membresía de grupo**. Si eso es correcto o no es una cuestión de diseño: si el usuario solo debería tener derechos en un resource group, sacalo del grupo amplio y asigná en el scope más estrecho. La lección duradera, y la que vale la pena llevarse al examen y a producción: **`--all --include-inherited --include-groups` es la única forma de ese comando cuyo resultado vacío significa algo.** Sin esas flags, "sin asignaciones" no es evidencia de ausencia de acceso — un error que ha producido certificados de buena salud falsos en access reviews reales.

**S6 — Security defaults no puede expresar "MFA para administradores, salvo cuentas de servicio desde el rango del datacenter".**
- **(a) Control que falla:** **security defaults es una línea base fija y no configurable.** Es deliberadamente todo-o-nada: registro de MFA para todos los usuarios, MFA para administradores, MFA en inicios de sesión riesgosos, autenticación heredada bloqueada, acciones privilegiadas del portal protegidas — con **ninguna condición, ninguna exclusión, ningún acotamiento y ninguna segmentación por aplicación**. El requisito contiene una *exención basada en una condición de red*, que es precisamente la clase de enunciado para la que security defaults no tiene gramática.
- **(b) Primera consulta:**
  ```bash
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" \
    --query "{name:displayName, enabled:isEnabled}" -o json
  ```
- **(c) Arreglo:** adquirí **Microsoft Entra ID P1** y después migrá. Hacelo en este orden, porque los dos son mutuamente excluyentes y el hueco entre ellos es una ventana de exposición:
  1. Escribí las políticas de reemplazo y poné todas en **`enabledForReportingButNotEnforced`**. Como mínimo: requerir MFA para roles de administrador; requerir MFA para todos los usuarios; **bloquear la autenticación heredada** (esta es la que la gente olvida, y security defaults la estaba proveyendo en silencio); y una named location para el rango de IPs del datacenter con las cuentas de servicio excluidas de la política de MFA solo cuando coincida la condición de ubicación.
  2. Creá el grupo de exclusión break-glass y verificá que esté referenciado por todas las políticas.
  3. Corré en report-only durante un ciclo de negocio completo y leé `appliedConditionalAccessPolicies[].result` en los sign-in logs — ahí es donde descubrís el cliente móvil, el director que viaja y la segunda cuenta de servicio que nadie mencionó.
  4. Apagá security defaults y encendé las políticas en la misma ventana de mantenimiento, en ese orden, con la credencial break-glass en la mano.

  Dos notas de diseño que vale la pena decir. Una exención por ubicación de red es una condición **débil** — los rangos de IP se pueden falsificar o alcanzar desde un host comprometido dentro del rango — así que tratala como un parche temporal; la respuesta más fuerte es reemplazar las cuentas de servicio por **managed identities o workload identity federation** (sin credencial que proteger, así que sin necesidad de exención de MFA) y gobernarlas con una **política de Conditional Access de identidad de carga de trabajo** en vez de excluirlas de una pensada para humanos. Y nunca construyas la exención como un agujero permanente: dale un dueño, un vencimiento y una access review.

</details>