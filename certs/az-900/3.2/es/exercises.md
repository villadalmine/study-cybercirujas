# AZ-900 — Tema 3.2: Funciones y herramientas de gobernanza y cumplimiento en Azure

## Ejercicios guiados (laboratorio de nivel productivo)

**Objetivo de examen (AZ-900, versión del temario 2026-07-20), peso 8.33%**
- Describir el propósito de las soluciones de gobernanza de Microsoft Purview
- Describir el propósito de Azure Policy
- Describir el propósito de los bloqueos de recursos

Fuente de referencia: <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>

---

## 0. Precondiciones del laboratorio y disciplina de costos

Estos ejercicios se ejecutan contra una suscripción real. Todo lo que hay en los ejercicios 1–7 usa recursos del plano de control gratuitos o casi gratuitos (bloqueos, definiciones de directiva, asignaciones, tareas de remediación y una cuenta de almacenamiento Standard_LRS). **El ejercicio 8 (Microsoft Purview) tiene un costo horario real y se presenta con una ruta alternativa de solo lectura y costo cero.**

**Herramientas necesarias**

```bash
az version
```

Salida esperada (las versiones variarán; `azure-cli` debe ser ≥ 2.61):

```json
{
  "azure-cli": "2.64.0",
  "azure-cli-core": "2.64.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {}
}
```

**Permisos necesarios.** Los bloqueos y las asignaciones de rol requieren `Microsoft.Authorization/locks/*` y `Microsoft.Authorization/roleAssignments/write`. El rol integrado **Contributor** excluye explícitamente ambos. Se necesita **Owner**, o bien **Contributor + User Access Administrator**, en el ámbito de la suscripción.

Referencia: <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles>

### Pasos

1. Inicie sesión y fije la suscripción de trabajo para que nada se filtre a una vecina.

```bash
az login --only-show-errors
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
```

2. Exporte los identificadores que va a reutilizar. Todo lo que sigue asume que estas variables existen en el shell.

```bash
export LOC="eastus"
export RG="rg-gov-lab"
export SUB=$(az account show --query id -o tsv)
export SCOPE_SUB="/subscriptions/${SUB}"
export SCOPE_RG="/subscriptions/${SUB}/resourceGroups/${RG}"
export SA="stgovlab$RANDOM"
echo "SUB=$SUB  SA=$SA"
```

3. Registre los proveedores de recursos de los que depende el laboratorio. `Microsoft.PolicyInsights` es obligatorio para las tareas de remediación y **no** está registrado por defecto en todas las suscripciones.

```bash
az provider register --namespace Microsoft.PolicyInsights
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.PolicyInsights --query registrationState -o tsv
```

Salida esperada (puede tardar 1–2 minutos en salir de `Registering`):

```
Registered
```

4. Cree el grupo de recursos del laboratorio con una etiqueta que más adelante propagará con una directiva `Modify`.

```bash
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags costCenter=CC-4711 env=lab owner=platform-team \
  --query "{name:name, location:location, tags:tags}" -o json
```

Salida esperada:

```json
{
  "location": "eastus",
  "name": "rg-gov-lab",
  "tags": {
    "costCenter": "CC-4711",
    "env": "lab",
    "owner": "platform-team"
  }
}
```

> **Compruebe su comprensión**
>
> **Q0.1** — Usted es **Contributor** de la suscripción. Intenta colocar un bloqueo `CanNotDelete` sobre un grupo de recursos y recibe `AuthorizationFailed`. ¿Qué acción de datos o permiso concreto falta, y qué dos roles integrados lo otorgan?
>
> **Q0.2** — ¿Por qué un laboratorio de gobernanza necesita `Microsoft.PolicyInsights` registrado, si la *evaluación* de directivas funciona sin él?
>
> **Q0.3** — Las etiquetas se tratan dentro de la gestión de costos (objetivo 3.1) y sin embargo aparecen en un laboratorio de gobernanza. Dé la razón de gobernanza por la que una etiqueta importa, distinta de la razón de facturación.

---

## 1. La jerarquía de ámbitos: dónde se engancha la gobernanza

Todo control de gobernanza en Azure — RBAC, Policy, bloqueos, deny assignments, presupuestos — se engancha a uno de cuatro ámbitos y fluye **hacia abajo** por herencia:

```
Management group  →  Subscription  →  Resource group  →  Resource
```

Entender la jerarquía es el prerrequisito de todos los demás ejercicios: una directiva asignada en un grupo de administración se evalúa contra todos los recursos de todas las suscripciones que cuelgan de él, y un bloqueo sobre un grupo de recursos protege a todos los recursos que contiene.

Referencia: <https://learn.microsoft.com/en-us/azure/governance/management-groups/overview>

### Pasos

1. Inspeccione la jerarquía de grupos de administración de su inquilino.

```bash
az account management-group list --query "[].{name:name, displayName:displayName}" -o table
```

Salida esperada en un inquilino que nunca usó grupos de administración:

```
Name                                  DisplayName
------------------------------------  ------------------
72f988bf-86f1-41af-91ab-2d7cd011db47  Tenant Root Group
```

2. Cree una jerarquía de dos niveles que refleje una landing zone real: un grupo "platform" de nivel superior con un hijo "sandbox".

```bash
az account management-group create --name "mg-contoso-platform" --display-name "Contoso Platform"
az account management-group create --name "mg-contoso-sandbox"  --display-name "Contoso Sandbox" \
  --parent "mg-contoso-platform"
```

3. Renderice el árbol resultante.

```bash
az account management-group show --name "mg-contoso-platform" --expand --recurse \
  --query "{mg:displayName, children:children[].{type:type, name:displayName}}" -o json
```

Salida esperada:

```json
{
  "children": [
    {
      "name": "Contoso Sandbox",
      "type": "Microsoft.Management/managementGroups"
    }
  ],
  "mg": "Contoso Platform"
}
```

4. Registre las cadenas de ámbito de los cuatro niveles. Estos son exactamente los valores de `--scope` que consumen Policy, RBAC y los bloqueos:

```bash
echo "MG   : /providers/Microsoft.Management/managementGroups/mg-contoso-platform"
echo "SUB  : ${SCOPE_SUB}"
echo "RG   : ${SCOPE_RG}"
echo "RES  : ${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}"
```

> **Compruebe su comprensión**
>
> **Q1.1** — Una suscripción puede tener exactamente un grupo de administración padre. ¿Cuántos grupos de administración puede tener un *grupo de administración* como padre, y cuál es la profundidad máxima de la jerarquía por debajo de la raíz?
>
> **Q1.2** — Se asigna una directiva en `mg-contoso-platform` y una directiva *distinta* en la suscripción que está dentro de `mg-contoso-sandbox`. Un recurso viola ambas. ¿Cuántos registros de incumplimiento genera, y una asignación anula a la otra?
>
> **Q1.3** — ¿Por qué un administrador global no ve por defecto el Tenant Root Group en el portal, y qué acción lo hace visible?

---

## 2. Bloqueos de recursos (resource locks) — protección frente a cambios accidentales

Un bloqueo de recursos es una guarda del plano de control que se aplica a **todos los principales**, sin importar su rol de RBAC. RBAC responde *"quién puede actuar"*; un bloqueo responde *"¿puede ocurrir esta acción en absoluto?"*.

Existen dos tipos de bloqueo:

| Tipo de bloqueo | Operación ARM bloqueada | Etiqueta en el portal | Uso típico |
|---|---|---|---|
| `CanNotDelete` | `DELETE` | **Delete** | Almacenes de datos de producción, red hub, jump hosts |
| `ReadOnly` | `DELETE`, `PUT`, `PATCH` y cualquier `POST` que mute estado | **Read-only** | Ventanas de congelación de cambios, retenciones por desmantelamiento, periodos de auditoría |

Referencia: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources>

### Pasos

1. Cree la cuenta de almacenamiento que hará de recurso protegido.

```bash
az storage account create \
  --name "$SA" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

Salida esperada:

```json
{
  "name": "stgovlab24817",
  "publicAccess": false
}
```

2. Aplique un bloqueo `CanNotDelete` **sobre el grupo de recursos**, para que la herencia sea visible.

```bash
az lock create \
  --name "lock-no-delete-rg" \
  --lock-type CanNotDelete \
  --resource-group "$RG" \
  --notes "Change freeze CHG0041299 — remove only via CAB approval"
```

3. Demuestre que la herencia alcanza al recurso hijo, aunque no se haya colocado ningún bloqueo sobre él.

```bash
az lock list --resource-group "$RG" --query "[].{name:name, level:level, scope:id}" -o table
```

Salida esperada:

```
Name               Level         Scope
-----------------  ------------  --------------------------------------------------------------
lock-no-delete-rg  CanNotDelete  /subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/Micro...
```

4. Intente el borrado que el bloqueo está diseñado para detener.

```bash
az storage account delete --name "$SA" --resource-group "$RG" --yes
```

Salida esperada (la petición nunca llega al proveedor de recursos — ARM la rechaza):

```
(ScopeLocked) The scope '/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/
Microsoft.Storage/storageAccounts/stgovlab24817' cannot perform delete operation
because following scope(s) are locked: '/subscriptions/xxxx/resourceGroups/rg-gov-lab'.
Please remove the lock and try again.
Code: ScopeLocked
```

5. Demuestre que `CanNotDelete` **no** bloquea la modificación. Cambie una propiedad de la cuenta "protegida":

```bash
az storage account update --name "$SA" --resource-group "$RG" \
  --tags env=lab purpose=lock-demo \
  --query "tags" -o json
```

Salida esperada — la escritura tiene éxito:

```json
{
  "env": "lab",
  "purpose": "lock-demo"
}
```

6. Escale a `ReadOnly` en el ámbito del recurso y observe la trampa clásica de producción: listar claves es una operación `POST` y por lo tanto queda bloqueada.

```bash
az lock delete --name "lock-no-delete-rg" --resource-group "$RG"

az lock create \
  --name "lock-readonly-sa" \
  --lock-type ReadOnly \
  --resource-group "$RG" \
  --resource-name "$SA" \
  --resource-type "Microsoft.Storage/storageAccounts" \
  --namespace "Microsoft.Storage"

az storage account keys list --account-name "$SA" --resource-group "$RG" -o table
```

Salida esperada:

```
(ScopeLocked) The scope '/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/
Microsoft.Storage/storageAccounts/stgovlab24817' cannot perform write operation
because following scope(s) are locked: '.../storageAccounts/stgovlab24817'.
```

7. Confirme que el bloqueo es únicamente una frontera del **plano de control**. Cree un contenedor usando una credencial de Entra ID (plano de datos) y note que el bloqueo le es irrelevante:

```bash
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}" \
  --only-show-errors

# wait ~30s for RBAC propagation
az storage container create --name "demo" --account-name "$SA" --auth-mode login
```

Salida esperada:

```json
{
  "created": true
}
```

8. Quite el bloqueo para que los ejercicios posteriores no queden bloqueados.

```bash
az lock delete --name "lock-readonly-sa" --resource-group "$RG" \
  --resource-name "$SA" --resource-type "Microsoft.Storage/storageAccounts" \
  --namespace "Microsoft.Storage"
```

> **Compruebe su comprensión**
>
> **Q2.1** — Un bloqueo `ReadOnly` está puesto sobre un grupo de recursos. Un colega informa que todavía puede borrar blobs de una cuenta de almacenamiento que está dentro. ¿Es un bug, una mala configuración o el comportamiento esperado? Justifique en términos de los planos de Azure.
>
> **Q2.2** — Un grupo de recursos tiene un bloqueo `CanNotDelete` en el ámbito del grupo y un bloqueo `ReadOnly` sobre una VM que está dentro. ¿Qué operaciones quedan bloqueadas en la VM, y cuáles quedan bloqueadas en los demás recursos del grupo?
>
> **Q2.3** — Su línea base de seguridad dice "nadie, ni siquiera el Owner de la suscripción, puede borrar el firewall del hub". ¿Un bloqueo de recursos satisface esto literalmente? Si no, ¿cuál es la garantía real que ofrece un bloqueo?
>
> **Q2.4** — Intenta `az group delete --name rg-gov-lab --yes` mientras un recurso anidado tiene un bloqueo y el grupo de recursos en sí no tiene ninguno. ¿Qué ocurre, y por qué la respuesta difiere de lo que sugeriría la jerarquía de ámbitos por sí sola?

---

## 3. Azure Policy — el efecto Audit y el ciclo de vida de evaluación

Azure Policy evalúa las **propiedades de los recursos** contra reglas de negocio, en el momento del despliegue y de forma continua después. Es el mecanismo que convierte un estándar escrito ("todo el almacenamiento debe denegar el acceso público a blobs") en un estado aplicado o medido.

Encuadre crítico para el examen y para producción:

| | Azure RBAC | Azure Policy |
|---|---|---|
| Postura por defecto | **Deny** para todo; las concesiones explícitas permiten | **Allow** para todo; las reglas explícitas deniegan/auditan |
| Sujeto de la decisión | El **principal** (usuario, grupo, SP, MI) | El **recurso** y sus propiedades |
| Pregunta que responde | "¿Esta identidad tiene permitido actuar?" | "¿El recurso resultante es aceptable?" |
| Cuándo se evalúa | En cada petición de ARM | En la petición de ARM **y** cada 24 h, de forma continua |

Referencia: <https://learn.microsoft.com/en-us/azure/governance/policy/overview>

### Pasos

1. Encuentre el alias que necesita. Una regla de directiva solo puede inspeccionar propiedades expuestas como **alias** por el proveedor de recursos — esta es, con diferencia, la razón más común de que una directiva escrita a mano nunca coincida con nada.

```bash
az provider show --namespace Microsoft.Storage \
  --expand "resourceTypes/aliases" \
  --query "resourceTypes[?resourceType=='storageAccounts'].aliases[].name" -o tsv \
  | grep -i publicaccess
```

Salida esperada:

```
Microsoft.Storage/storageAccounts/allowBlobPublicAccess
```

2. Escriba la regla. Guárdela como `rules-audit-public-blob.json`. Note la estructura mínima, sin `count`: `if` (condición) y `then` (efecto).

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.Storage/storageAccounts"
      },
      {
        "field": "Microsoft.Storage/storageAccounts/allowBlobPublicAccess",
        "notEquals": "false"
      }
    ]
  },
  "then": {
    "effect": "[parameters('effect')]"
  }
}
```

3. Parametrice el efecto para que la misma definición pueda desplegarse primero como `audit` y promoverse a `deny` después. Guárdelo como `params-effect.json`.

```json
{
  "effect": {
    "type": "String",
    "metadata": {
      "displayName": "Effect",
      "description": "Enable or disable the execution of the policy"
    },
    "allowedValues": [
      "Audit",
      "Deny",
      "Disabled"
    ],
    "defaultValue": "Audit"
  }
}
```

4. Cree la definición personalizada en el ámbito de la suscripción.

```bash
az policy definition create \
  --name "deny-storage-public-blob-access" \
  --display-name "Storage accounts must disable blob public access" \
  --description "Anonymous public read access to blobs and containers must be turned off." \
  --rules @rules-audit-public-blob.json \
  --params @params-effect.json \
  --mode Indexed \
  --metadata category=Storage version=1.0.0 \
  --subscription "$SUB" \
  --query "{name:name, mode:mode, type:policyType}" -o json
```

Salida esperada:

```json
{
  "mode": "Indexed",
  "name": "deny-storage-public-blob-access",
  "type": "Custom"
}
```

5. Asígnela en modo **audit** en el ámbito del grupo de recursos.

```bash
az policy assignment create \
  --name "audit-storage-public-blob" \
  --display-name "Audit: storage public blob access" \
  --policy "deny-storage-public-blob-access" \
  --scope "$SCOPE_RG" \
  --params '{"effect":{"value":"Audit"}}' \
  --query "{name:name, enforcementMode:enforcementMode, scope:scope}" -o json
```

Salida esperada:

```json
{
  "enforcementMode": "Default",
  "name": "audit-storage-public-blob",
  "scope": "/subscriptions/xxxx/resourceGroups/rg-gov-lab"
}
```

6. Cree un recurso deliberadamente no conforme.

```bash
az storage account create \
  --name "stbadpublic$RANDOM" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --allow-blob-public-access true \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

La creación **tiene éxito** — `Audit` nunca bloquea:

```json
{
  "name": "stbadpublic9042",
  "publicAccess": true
}
```

7. No espere 24 horas al ciclo estándar de cumplimiento. Dispare un escaneo de evaluación bajo demanda.

```bash
az policy state trigger-scan --resource-group "$RG"
```

El comando bloquea hasta que el escaneo termina (normalmente 1–4 minutos) y no devuelve nada si tiene éxito. Después, resuma:

```bash
az policy state summarize --resource-group "$RG" \
  --query "value[0].policyAssignments[].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" -o table
```

Salida esperada:

```
Assignment                                                                  NonCompliant
--------------------------------------------------------------------------  --------------
/subscriptions/xxxx/.../policyAssignments/audit-storage-public-blob                       1
```

8. Identifique exactamente qué recurso falló y por qué.

```bash
az policy state list --resource-group "$RG" \
  --filter "complianceState eq 'NonCompliant'" \
  --query "[].{resource:resourceId, state:complianceState, assignment:policyAssignmentName}" -o table
```

> **Compruebe su comprensión**
>
> **Q3.1** — Nombre los tres eventos que disparan una evaluación de directiva, e indique la latencia documentada de cada uno.
>
> **Q3.2** — Su directiva personalizada devuelve "0 recursos no conformes" pero usted sabe que 40 cuentas de almacenamiento violan la regla. La regla usa `"field": "properties.allowBlobPublicAccess"`. ¿Qué está mal, y cómo lo habría detectado antes de asignarla?
>
> **Q3.3** — ¿Por qué la definición usa `"mode": "Indexed"` en lugar de `"mode": "All"`? ¿Qué se rompería si usara `All` para esta regla concreta?
>
> **Q3.4** — Contraste el resultado de bloquear una cuenta de almacenamiento incorrecta con (a) una denegación de RBAC sobre `Microsoft.Storage/storageAccounts/write`, y (b) un efecto `Deny` de Azure Policy. ¿Cuál de las dos sigue permitiendo al equipo de plataforma desplegar almacenamiento conforme, y por qué importa eso?

---

## 4. Promover a `Deny`, y las dos válvulas de seguridad

Una asignación `Audit` mide. Una asignación `Deny` aplica — y puede romper pipelines existentes en el instante en que aterriza. Azure Policy ofrece dos mecanismos de seguridad para producción: **`enforcementMode: DoNotEnforce`** (evalúa e informa pero nunca bloquea, es decir, un what-if) y las **exenciones** (una excepción acotada, con caducidad y auditable, que *no* es lo mismo que excluir el ámbito).

Referencias:
- <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure>
- <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure>

### Pasos

1. Prepare el cambio de forma segura: cree la asignación `Deny` con la aplicación desactivada.

```bash
az policy assignment create \
  --name "deny-storage-public-blob" \
  --display-name "Deny: storage public blob access" \
  --policy "deny-storage-public-blob-access" \
  --scope "$SCOPE_RG" \
  --params '{"effect":{"value":"Deny"}}' \
  --enforcement-mode DoNotEnforce \
  --query "{name:name, enforcementMode:enforcementMode}" -o json
```

Salida esperada:

```json
{
  "enforcementMode": "DoNotEnforce",
  "name": "deny-storage-public-blob"
}
```

2. Confirme el comportamiento what-if: el despliegue sigue teniendo éxito, pero la asignación registra la violación que se habría producido.

```bash
az storage account create --name "stwhatif$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access true \
  --query name -o tsv
```

3. Active la aplicación.

```bash
az policy assignment update \
  --name "deny-storage-public-blob" \
  --scope "$SCOPE_RG" \
  --enforcement-mode Default \
  --query enforcementMode -o tsv
```

Salida esperada:

```
Default
```

4. Intente el mismo despliegue no conforme. Deje pasar ~30 minutos tras un cambio de asignación para la propagación completa; las asignaciones nuevas suelen ser efectivas en 5–15 minutos en el ámbito de grupo de recursos.

```bash
az storage account create --name "stblocked$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access true
```

Salida esperada — ARM rechaza la petición antes de que el proveedor de recursos siquiera la vea:

```
(RequestDisallowedByPolicy) Resource 'stblocked5518' was disallowed by policy.
Policy identifiers: '[{"policyAssignment":{"name":"Deny: storage public blob access",
"id":"/subscriptions/xxxx/resourceGroups/rg-gov-lab/providers/Microsoft.Authorization/
policyAssignments/deny-storage-public-blob"},"policyDefinition":{"name":"Storage accounts
must disable blob public access","id":"/subscriptions/xxxx/providers/Microsoft.Authorization/
policyDefinitions/deny-storage-public-blob-access"}}]'
Code: RequestDisallowedByPolicy
```

5. Verifique que la ruta *conforme* no se ve afectada — esta es la propiedad que distingue a Policy de una denegación de RBAC a lo bruto.

```bash
az storage account create --name "stgood$RANDOM" --resource-group "$RG" \
  --location "$LOC" --sku Standard_LRS --allow-blob-public-access false \
  --query "{name:name, publicAccess:allowBlobPublicAccess}" -o json
```

6. Una carga de trabajo heredada de documentos públicos necesita realmente acceso anónimo durante 90 días. Conceda una **exención**, no una exclusión.

```bash
export TARGET_SA=$(az storage account list -g "$RG" \
  --query "[?allowBlobPublicAccess].name | [0]" -o tsv)

az policy exemption create \
  --name "exempt-legacy-public-docs" \
  --display-name "Legacy public docs site — CAB CHG0041377" \
  --policy-assignment "$(az policy assignment show --name 'deny-storage-public-blob' --scope "$SCOPE_RG" --query id -o tsv)" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${TARGET_SA}" \
  --exemption-category Waiver \
  --description "Anonymous read required by legacy CMS; migration tracked in PLAT-2291" \
  --expires-on "2026-12-05T00:00:00Z" \
  --query "{name:name, category:exemptionCategory, expires:expiresOn}" -o json
```

Salida esperada:

```json
{
  "category": "Waiver",
  "expires": "2026-12-05T00:00:00+00:00",
  "name": "exempt-legacy-public-docs"
}
```

7. Vuelva a escanear y confirme que el recurso ahora informa `Exempt`, ni `Compliant` ni `NonCompliant`.

```bash
az policy state trigger-scan --resource-group "$RG"
az policy state list --resource-group "$RG" \
  --query "[?policyAssignmentName=='deny-storage-public-blob'].{res:resourceId, state:complianceState}" -o table
```

> **Compruebe su comprensión**
>
> **Q4.1** — Distinga entre `exclusion` (`notScopes` en la asignación), `exemption` y `enforcementMode: DoNotEnforce`. ¿Cuál preserva un rastro de auditoría de la excepción, y cuál es invisible en el panel de cumplimiento?
>
> **Q4.2** — ¿Cuál es la diferencia entre las categorías de exención `Waiver` y `Mitigated`? Dé un escenario para cada una.
>
> **Q4.3** — Se asigna una directiva `Deny` en el ámbito de un grupo de administración. 6.000 cuentas de almacenamiento ya la violan. ¿Qué les ocurre a esas 6.000 cuentas en el momento de la asignación?
>
> **Q4.4** — Ordene estos efectos por precedencia de evaluación y explique por qué el orden importa: `Deny`, `Disabled`, `Audit`, `Modify`, `DeployIfNotExists`.

---

## 5. Iniciativas (policy sets) y el panel de cumplimiento

Una directiva individual es una regla. Una **iniciativa** (policy set definition) es un marco de control: un grupo con nombre de definiciones que se asigna y se reporta como una sola unidad. Todos los marcos regulatorios que Microsoft entrega — ISO 27001, NIST SP 800-53 Rev. 5, PCI DSS, el Microsoft cloud security benchmark — se entregan como iniciativas integradas.

Referencia: <https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure>

### Pasos

1. Descubra las definiciones integradas que va a componer. Derive los GUID en lugar de copiarlos a mano desde un post de blog.

```bash
az policy definition list \
  --query "[?displayName=='Allowed locations' || displayName=='Require a tag on resources'].{display:displayName, name:name}" -o table
```

Salida esperada:

```
Display                        Name
-----------------------------  ------------------------------------
Allowed locations              e56962a6-4747-49cd-b67b-bf8b01975c4c
Require a tag on resources     871b6d14-10aa-478d-b590-94f262ecfa99
```

2. Escriba la iniciativa. Guárdela como `initiative-baseline.json`. Note cómo los parámetros de cada directiva miembro se vuelven a exponer a nivel de iniciativa para que la asignación configure todo el conjunto de una sola vez.

```json
[
  {
    "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c",
    "policyDefinitionReferenceId": "allowedLocations",
    "parameters": {
      "listOfAllowedLocations": {
        "value": "[parameters('allowedLocations')]"
      }
    }
  },
  {
    "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99",
    "policyDefinitionReferenceId": "requireCostCenterTag",
    "parameters": {
      "tagName": {
        "value": "costCenter"
      }
    }
  }
]
```

3. Escriba los parámetros de la iniciativa. Guárdelos como `initiative-params.json`.

```json
{
  "allowedLocations": {
    "type": "Array",
    "metadata": {
      "displayName": "Allowed locations",
      "description": "Regions approved by the data residency standard",
      "strongType": "location"
    },
    "defaultValue": [
      "eastus",
      "westeurope"
    ]
  }
}
```

4. Cree y asigne la iniciativa.

```bash
az policy set-definition create \
  --name "contoso-landing-zone-baseline" \
  --display-name "Contoso landing zone baseline" \
  --description "Minimum governance controls for every subscription" \
  --definitions @initiative-baseline.json \
  --params @initiative-params.json \
  --metadata category="Contoso Baseline" version=1.0.0 \
  --subscription "$SUB" \
  --query "{name:name, members:length(policyDefinitions)}" -o json
```

Salida esperada:

```json
{
  "members": 2,
  "name": "contoso-landing-zone-baseline"
}
```

```bash
az policy assignment create \
  --name "assign-lz-baseline" \
  --display-name "Contoso landing zone baseline" \
  --policy-set-definition "contoso-landing-zone-baseline" \
  --scope "$SCOPE_RG" \
  --params '{"allowedLocations":{"value":["eastus"]}}' \
  --query name -o tsv
```

5. Lea el cumplimiento como un porcentaje, tal como lo haría un auditor.

```bash
az policy state trigger-scan --resource-group "$RG"

az policy state summarize --resource-group "$RG" \
  --query "value[0].results.{nonCompliantResources:nonCompliantResources, nonCompliantPolicies:nonCompliantPolicies}" -o json
```

Salida esperada:

```json
{
  "nonCompliantPolicies": 1,
  "nonCompliantResources": 3
}
```

6. Consulte los mismos datos a escala de flota con Azure Resource Graph — el único enfoque viable más allá de unos pocos cientos de recursos.

```bash
az graph query -q "policyresources
| where type == 'microsoft.policyinsights/policystates'
| where properties.complianceState == 'NonCompliant'
| summarize count() by tostring(properties.policyDefinitionName)
| order by count_ desc" --first 10 -o table
```

> **Compruebe su comprensión**
>
> **Q5.1** — ¿Por qué un marco regulatorio como ISO 27001 se entrega como *iniciativa* y no como una única definición de directiva?
>
> **Q5.2** — El panel de Regulatory Compliance de Microsoft Defender for Cloud muestra "NIST SP 800-53 Rev. 5 — 64% compliant". ¿Qué componente de Azure produjo realmente ese número?
>
> **Q5.3** — Un control de una iniciativa regulatoria está marcado con efecto `Manual` y estado `Unknown`. ¿Qué significa eso, y quién es responsable de cambiarlo?
>
> **Q5.4** — Su iniciativa informa 100% de cumplimiento. Nombre dos razones distintas por las que esto puede seguir sin significar "cumplimos con el estándar".

---

## 6. Efecto `Modify`, identidad administrada y remediación

`Audit` y `Deny` se ocupan de los recursos *nuevos*. Llevar el **patrimonio existente** a la conformidad requiere un efecto que cambie recursos — `Modify` (mutación de propiedades/etiquetas) o `DeployIfNotExists` (desplegar una plantilla ARM cuando falta un recurso relacionado) — más una **identidad administrada** que Policy usa para actuar, y una **tarea de remediación** que barre los recursos existentes.

Referencia: <https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources>

### Pasos

1. Escriba una regla `Modify` que herede la etiqueta `costCenter` del grupo de recursos. Guárdela como `rules-inherit-tag.json`.

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.Storage/storageAccounts"
      },
      {
        "field": "tags['costCenter']",
        "exists": "false"
      },
      {
        "value": "[resourceGroup().tags['costCenter']]",
        "notEquals": ""
      }
    ]
  },
  "then": {
    "effect": "modify",
    "details": {
      "roleDefinitionIds": [
        "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
      ],
      "conflictEffect": "audit",
      "operations": [
        {
          "operation": "addOrReplace",
          "field": "tags['costCenter']",
          "value": "[resourceGroup().tags['costCenter']]"
        }
      ]
    }
  }
}
```

> `b24988ac-6180-42a0-ab88-20f7382dd24c` es el rol integrado **Contributor**. `roleDefinitionIds` declara el permiso mínimo que necesita la identidad de remediación; Policy se niega a asignar una identidad más amplia que la que usted solicita aquí.

2. Cree la definición.

```bash
az policy definition create \
  --name "inherit-costcenter-tag" \
  --display-name "Inherit costCenter tag from the resource group" \
  --rules @rules-inherit-tag.json \
  --mode Indexed \
  --metadata category=Tags version=1.0.0 \
  --subscription "$SUB" \
  --query name -o tsv
```

3. Asígnela **con una identidad administrada asignada por el sistema**. `--mi-system-assigned` requiere `--location`, porque una identidad administrada es un objeto regional.

```bash
az policy assignment create \
  --name "assign-inherit-costcenter" \
  --display-name "Inherit costCenter tag" \
  --policy "inherit-costcenter-tag" \
  --scope "$SCOPE_RG" \
  --mi-system-assigned \
  --location "$LOC" \
  --identity-scope "$SCOPE_RG" \
  --role "Contributor" \
  --query "{name:name, principalId:identity.principalId, type:identity.type}" -o json
```

Salida esperada:

```json
{
  "name": "assign-inherit-costcenter",
  "principalId": "3f7c1c2e-9d40-4c31-8f2b-6a1e8c9d0b55",
  "type": "SystemAssigned"
}
```

4. Confirme la asignación de rol que Policy creó en su nombre.

```bash
az role assignment list --scope "$SCOPE_RG" \
  --query "[?principalId=='3f7c1c2e-9d40-4c31-8f2b-6a1e8c9d0b55'].{role:roleDefinitionName, scope:scope}" -o table
```

5. Evalúe y luego remedie las cuentas de almacenamiento **preexistentes** sin etiqueta.

```bash
az policy state trigger-scan --resource-group "$RG"

az policy remediation create \
  --name "remediate-costcenter-$(date +%s)" \
  --resource-group "$RG" \
  --policy-assignment "assign-inherit-costcenter" \
  --resource-discovery-mode ExistingNonCompliant \
  --query "{name:name, state:provisioningState}" -o json
```

Salida esperada:

```json
{
  "name": "remediate-costcenter-1780012345",
  "state": "Accepted"
}
```

6. Observe cómo se vacía la tarea y verifique que el patrimonio cambió.

```bash
az policy remediation list --resource-group "$RG" \
  --query "[].{name:name, state:provisioningState, deployed:deploymentStatus.successfulDeployments}" -o table

az storage account list -g "$RG" --query "[].{name:name, costCenter:tags.costCenter}" -o table
```

Salida esperada:

```
Name              CostCenter
----------------  ------------
stgovlab24817     CC-4711
stbadpublic9042   CC-4711
stgood7731        CC-4711
```

> **Compruebe su comprensión**
>
> **Q6.1** — ¿Por qué una asignación `Modify` o `DeployIfNotExists` debe llevar una identidad administrada, mientras que `Audit` y `Deny` no deben llevarla?
>
> **Q6.2** — ¿Cuál es la diferencia funcional entre `Modify` y `DeployIfNotExists`? Dé un requisito que solo cada uno pueda satisfacer.
>
> **Q6.3** — Asignó una directiva `DeployIfNotExists` la semana pasada. Diez recursos creados desde entonces son conformes, pero 900 más antiguos siguen sin serlo. Explique con precisión por qué, y la única acción que lo soluciona.
>
> **Q6.4** — En la regla de arriba se establece `conflictEffect: audit`. ¿A qué conflicto se refiere, y qué habría hecho `conflictEffect: deny` en su lugar?

---

## 7. Deny assignments — deployment stacks y la retirada de Azure Blueprints

Azure Blueprints (Preview) está **obsoleto**; Microsoft dirige a los clientes hacia **Template Specs** más **Deployment Stacks**. Esto importa para el examen porque material antiguo de AZ-900 todavía nombra a Blueprints, e importa en producción porque los deployment stacks introducen **deny assignments** — una guarda más fuerte que un bloqueo de recursos, ya que una deny assignment no puede ser simplemente borrada por un Owner que actúe sobre el recurso.

Referencias:
- <https://learn.microsoft.com/en-us/azure/governance/blueprints/overview>
- <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks>
- <https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments>

### Pasos

1. Escriba una plantilla Bicep mínima. Guárdela como `stack-storage.bicep`.

```bicep
param location string = resourceGroup().location
param storageAccountName string

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

output storageId string = sa.id
```

2. Despliéguela como un stack gestionado con deny settings.

```bash
export STACK_SA="ststack$RANDOM"

az stack group create \
  --name "stack-platform-baseline" \
  --resource-group "$RG" \
  --template-file stack-storage.bicep \
  --parameters storageAccountName="$STACK_SA" \
  --deny-settings-mode denyWriteAndDelete \
  --action-on-unmanage detachAll \
  --yes \
  --query "{name:name, mode:denySettings.mode, state:provisioningState}" -o json
```

Salida esperada:

```json
{
  "mode": "denyWriteAndDelete",
  "name": "stack-platform-baseline",
  "state": "succeeded"
}
```

3. Intente un cambio fuera de banda — la deriva que un bloqueo también detendría, pero observe la clase de error distinta.

```bash
az storage account update --name "$STACK_SA" --resource-group "$RG" --tags drift=yes
```

Salida esperada:

```
(RequestDisallowedByAzure) Resource '.../storageAccounts/ststack1902' was disallowed
by a deny assignment created by deployment stack 'stack-platform-baseline'.
Code: RequestDisallowedByAzure
```

4. Compare los tres mecanismos de protección que ya ha ejercitado.

```bash
az lock list --resource-group "$RG" -o table
az role assignment list --scope "$SCOPE_RG" --include-inherited --query "[].roleDefinitionName" -o tsv | sort -u
```

5. Desmonte el stack, desasociando el recurso en lugar de borrarlo.

```bash
az stack group delete --name "stack-platform-baseline" --resource-group "$RG" \
  --action-on-unmanage detachAll --yes
```

> **Compruebe su comprensión**
>
> **Q7.1** — Complete la tabla de decisión: para cada uno de *resource lock*, *deny assignment* y *Azure Policy Deny*, indique (a) qué protege, (b) si un Owner de la suscripción puede saltárselo directamente, (c) si se evalúa sobre recursos *existentes*.
>
> **Q7.2** — Una pregunta de examen escrita contra un temario más antiguo pregunta qué servicio permite "empaquetar plantillas ARM, asignaciones de RBAC y asignaciones de directiva en una definición de entorno repetible y versionada". ¿Cuál es la respuesta histórica, cuál es su estado actual, y qué lo reemplaza?
>
> **Q7.3** — Su elección de `--action-on-unmanage` es `deleteAll` en lugar de `detachAll`. Describa el radio de impacto de ejecutar `az stack group delete` sobre un stack de producción.

---

## 8. Microsoft Purview — gobernanza de datos y cartera de cumplimiento

Microsoft Purview es el paraguas de dos familias distintas que el examen trata como un solo objetivo:

**A. Gobernanza de datos (el antiguo Azure Purview)** — sabe *dónde están sus datos, qué contienen y hacia dónde fluyen*, en Azure, on-premises, AWS/GCP y SaaS:

| Componente | Propósito |
|---|---|
| **Data Map** | El grafo escaneado y refrescado continuamente de activos de datos, clasificaciones y linaje |
| **Data Catalog / Unified Catalog** | Búsqueda con glosario de negocio sobre el mapa; la superficie de "encontrar datos confiables" |
| **Data Estate Insights / Health** | Informes ejecutivos sobre cobertura, clasificación y administración (stewardship) |
| **Data Sharing** | Compartición in-place entre organizaciones sin copiar |
| **Data Policy** | Directivas de acceso para orígenes registrados, escritas de forma centralizada |

**B. Soluciones de riesgo y cumplimiento** — Compliance Manager, Information Protection (etiquetas de confidencialidad), Data Loss Prevention, Insider Risk Management, Data Lifecycle Management, eDiscovery, Audit, Communication Compliance.

Referencias:
- <https://learn.microsoft.com/en-us/purview/purview>
- <https://learn.microsoft.com/en-us/purview/compliance-manager>
- <https://learn.microsoft.com/en-us/azure/compliance/>

> **ADVERTENCIA DE COSTO.** Una cuenta de Purview factura por un Data Map siempre encendido (unidades de capacidad elástica, facturadas por hora) más el escaneo por vCore-hora. La Ruta A de abajo aprovisiona infraestructura real y **debe borrarse inmediatamente después**. La Ruta B es gratuita y cubre todo lo que el objetivo de AZ-900 realmente exige. Elija una.

### Ruta A — Aprovisionar y escanear (facturable)

1. Añada la extensión de CLI y aprovisione la cuenta.

```bash
az extension add --name purview --upgrade
az provider register --namespace Microsoft.Purview

az purview account create \
  --name "pvw-gov-lab-$RANDOM" \
  --resource-group "$RG" \
  --location "$LOC" \
  --query "{name:name, endpoint:properties.endpoints.catalog, state:properties.provisioningState}" -o json
```

Salida esperada:

```json
{
  "endpoint": "https://pvw-gov-lab-3312.purview.azure.com/catalog",
  "name": "pvw-gov-lab-3312",
  "state": "Succeeded"
}
```

2. En el portal de Microsoft Purview (<https://purview.microsoft.com>), abra **Data Map → Data sources → Register**, elija **Azure Blob Storage** y seleccione la cuenta `$SA` creada en el ejercicio 2. El registro solo anota el origen; no lee ningún dato.

3. Sobre el origen registrado elija **New scan**, autentíquese con la **identidad administrada** de la cuenta de Purview, y establezca el conjunto de reglas de escaneo en **AzureStorage (system default)**. Antes de ejecutarlo, conceda acceso de lectura a la identidad:

```bash
export PVW_MI=$(az purview account show --name "<your-purview-account>" -g "$RG" \
  --query identity.principalId -o tsv)

az role assignment create \
  --assignee "$PVW_MI" \
  --role "Storage Blob Data Reader" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}"
```

4. Ejecute el escaneo y luego abra **Data Catalog → Browse assets**. Inspeccione la pestaña **Schema** de un activo descubierto y observe cualquier clasificación aplicada (por ejemplo `Credit Card Number`, `EU National Identification Number`) — estas provienen de tipos de información confidencial integrados, detectados por patrón y suma de verificación, no por el nombre del archivo.

5. **Borre la cuenta de inmediato** — el Data Map factura mientras exista.

```bash
az purview account delete --name "<your-purview-account>" -g "$RG" --yes
```

### Ruta B — Rastro de evidencia de cumplimiento sin costo

1. Abra el **Service Trust Portal** en <https://servicetrust.microsoft.com>. Vaya a **Reports → Audit reports** y localice el informe **SOC 2 Type II** vigente para Azure. Note que la descarga exige iniciar sesión y aceptar un NDA.

2. Abra **Microsoft Purview Compliance Manager** (<https://purview.microsoft.com> → **Compliance Manager**, o el recorrido directo de Learn en <https://learn.microsoft.com/en-us/purview/compliance-manager-setup>). Registre la **puntuación de cumplimiento** de su inquilino, luego abra una acción de mejora e identifique:
   - sus **puntos obtenidos / posibles**,
   - si es **gestionada por Microsoft** o **gestionada por el cliente**,
   - su **evaluación** y **familia de controles**.

3. Abra el índice de documentación de cumplimiento de Azure en <https://learn.microsoft.com/en-us/azure/compliance/>. Localice una oferta relevante para una carga de trabajo regulada (por ejemplo ISO/IEC 27001, HIPAA HITRUST, FedRAMP High, o una oferta regional como GDPR) y anote la declaración de alcance — qué servicios de Azure están dentro del alcance de esa atestación.

4. Enlace las dos mitades del objetivo: en Azure Policy, liste las iniciativas integradas que implementan esos mismos marcos.

```bash
az policy set-definition list \
  --query "[?policyType=='BuiltIn' && contains(displayName, 'ISO')].{display:displayName, name:name}" -o table
```

Salida esperada (abreviada):

```
Display                                                          Name
---------------------------------------------------------------  ------------------------------------
ISO 27001:2013                                                   89c6cddc-1c73-4ac1-b19c-54d1a15a42f2
```

> **Compruebe su comprensión**
>
> **Q8.1** — Un regulador pregunta: "¿Sabe usted si hay números de identificación nacional de clientes almacenados fuera de la UE?" ¿Qué capacidad de Microsoft Purview responde eso, y qué efecto de Azure Policy *impediría* que la situación se repita?
>
> **Q8.2** — Distinga el **Trust Center**, el **Service Trust Portal** y **Compliance Manager**. ¿Cuál produce una *puntuación*, cuál produce *informes de auditoría de terceros*, y cuál es material de *marketing/visión general*?
>
> **Q8.3** — Compliance Manager muestra una acción de mejora que vale 27 puntos y está marcada como "Microsoft-managed". ¿Puede aumentar su puntuación trabajando en ella? ¿Qué revela eso sobre el modelo de responsabilidad compartida?
>
> **Q8.4** — Microsoft Purview escanea un SQL Server on-premises y un bucket S3 de AWS. ¿Qué le dice esto sobre el alcance del producto frente al alcance de Azure Policy?
>
> **Q8.5** — ¿Por qué Microsoft Purview puede clasificar datos que Azure Policy es estructuralmente incapaz de ver? Responda en términos de plano de control frente a plano de datos.

---

## 9. Ejercicio de decisión — del requisito a la herramienta

Aquí no hay comandos. Para cada requisito, nombre la **única** herramienta correcta y, en una frase, por qué las vecinas cercanas son incorrectas. Esta es exactamente la discriminación que evalúa AZ-900.

1. "La VM de finanzas no debe ser borrada por nadie, incluidos los administradores, durante la congelación de cierre trimestral."
2. "Toda VM desplegada en cualquier punto del inquilino debe estar en `westeurope` o `northeurope`."
3. "Necesitamos saber cuáles de nuestros 40 almacenes de datos contienen números de pasaporte, incluidos dos recursos compartidos de archivos on-premises."
4. "Los auditores quieren nuestra carta de atestación SOC 2 Type II vigente para Azure."
5. "Mostrar una puntuación porcentual de nuestro avance frente a ISO 27001, con acciones recomendadas y carga de evidencias."
6. "A toda cuenta de almacenamiento a la que le falte la etiqueta `costCenter` se le debe añadir automáticamente, incluidas las 900 que ya existen."
7. "Nadie del grupo de contratistas puede crear recursos en la suscripción de producción."
8. "Un recurso no debe modificarse fuera de banda después de que el equipo de plataforma lo despliegue desde el control de código fuente."
9. "Informar — no bloquear — cuántas VM carecen de Azure Backup, antes de hacerlo obligatorio el trimestre que viene."
10. "Agrupar cuarenta reglas de seguridad separadas en un único conjunto de controles auditable asignado por suscripción."

> **Compruebe su comprensión**
>
> **Q9.1** — Responda las diez.
>
> **Q9.2** — Los ítems 1, 7 y 8 "impiden que alguien haga algo". Indique el mecanismo que usa cada uno y la única propiedad que los hace no intercambiables.

---

## 10. Limpieza

Los bloqueos y las deny assignments impedirán el borrado, así que salen primero.

```bash
# 1. Remove any remaining locks
for L in $(az lock list --resource-group "$RG" --query "[].name" -o tsv); do
  az lock delete --name "$L" --resource-group "$RG"
done

# 2. Remove exemptions, then assignments, then definitions (dependency order)
az policy exemption delete --name "exempt-legacy-public-docs" \
  --scope "${SCOPE_RG}/providers/Microsoft.Storage/storageAccounts/${TARGET_SA}" 2>/dev/null

for A in audit-storage-public-blob deny-storage-public-blob assign-lz-baseline assign-inherit-costcenter; do
  az policy assignment delete --name "$A" --scope "$SCOPE_RG" 2>/dev/null
done

az policy set-definition delete --name "contoso-landing-zone-baseline" --subscription "$SUB"
az policy definition delete --name "deny-storage-public-blob-access" --subscription "$SUB"
az policy definition delete --name "inherit-costcenter-tag" --subscription "$SUB"

# 3. Resource group
az group delete --name "$RG" --yes --no-wait

# 4. Management groups (children first)
az account management-group delete --name "mg-contoso-sandbox"
az account management-group delete --name "mg-contoso-platform"
```

Confirme que no sobrevive nada:

```bash
az policy assignment list --scope "$SCOPE_SUB" --query "[?contains(name,'storage') || contains(name,'baseline')].name" -o tsv
az lock list --query "[].{name:name, scope:id}" -o table
```

---

<details>
<summary><strong>Respuestas</strong> — expandir solo después de intentar cada bloque</summary>

### Ejercicio 0

**A0.1** — El permiso que falta es `Microsoft.Authorization/locks/*` (en concreto `.../locks/write` para la creación y `.../locks/delete` para la eliminación). Contributor concede casi todas las acciones sobre recursos, pero lleva una entrada explícita en `NotActions` para `Microsoft.Authorization/*/Write` y `Microsoft.Authorization/*/Delete`, lo que excluye los bloqueos y las asignaciones de rol. Los dos roles integrados que sí lo conceden son **Owner** y **User Access Administrator**. Esto es deliberado: si Contributor pudiera quitar bloqueos, un bloqueo sería solo una sugerencia para el rol que más probablemente borre algo por accidente.

**A0.2** — La evaluación la realiza el motor de Policy en cualquier caso. `Microsoft.PolicyInsights` es el proveedor de recursos dueño de las **tareas de remediación** (`Microsoft.PolicyInsights/remediations`) y de las API de **policy states / policy events** que usan `az policy state list|summarize|trigger-scan` y el panel de cumplimiento. Sin él registrado, la remediación de recursos existentes con `DeployIfNotExists` y `Modify` falla, y los escaneos bajo demanda devuelven errores de proveedor no registrado.

**A0.3** — La facturación es la razón de gestión de costos. La razón de gobernanza es que una etiqueta es una **propiedad direccionable por directiva**: Azure Policy puede exigirla (`Require a tag on resources`), heredarla (`Modify`), denegar recursos que no la tengan, y Resource Graph puede consultar el patrimonio por ella. Una etiqueta convierte un hecho organizativo (propiedad, clasificación de datos, entorno, alcance regulatorio) en metadatos exigibles por máquina. Por eso las directivas de etiquetas están en casi toda línea base de landing zone, con independencia del chargeback.

---

### Ejercicio 1

**A1.1** — Un grupo de administración tiene exactamente **un** padre (la jerarquía es un árbol, no un grafo). Por debajo del grupo de administración raíz, Azure admite **seis niveles** de grupos de administración anidados — el nivel raíz no cuenta para esos seis, y el nivel de suscripción tampoco se cuenta. Cada grupo de administración puede tener muchos hijos; un directorio admite hasta 10.000 grupos de administración.

**A1.2** — Genera **dos** registros de incumplimiento separados — uno por asignación. Las asignaciones de directiva son **acumulativas y nunca se anulan entre sí**. No hay una resolución de "gana la más específica" como en otros sistemas: si cualquier asignación aplicable tiene un efecto `Deny`, la petición se deniega. Por eso un `Deny` en el ámbito de grupo de administración no puede relajarse con una asignación en un ámbito hijo; solo una exclusión (`notScopes`) o una exención sobre la asignación *padre* puede recortar al hijo.

**A1.3** — El Tenant Root Group requiere **acceso elevado**: un administrador global debe activar *Access management for Azure resources* en las propiedades de Microsoft Entra ID, lo que le concede el rol **User Access Administrator** en el ámbito raíz (`/`). Los roles de Entra ID y los roles de Azure RBAC son sistemas separados; ser administrador global no confiere por defecto ningún permiso sobre recursos de Azure. La elevación debe retirarse después de hacer la asignación necesaria en el ámbito raíz.

---

### Ejercicio 2

**A2.1** — **Comportamiento esperado, no un bug.** Los bloqueos de recursos los aplica **Azure Resource Manager** y por lo tanto solo afectan al **plano de control** (`management.azure.com`) — crear, actualizar y borrar *recursos*. Borrar un blob es una operación del **plano de datos** contra `<account>.blob.core.windows.net`, que nunca atraviesa ARM y se autoriza mediante acciones de datos de RBAC o una SAS/clave. Proteger el contenido de los blobs exige controles del plano de datos: directivas de inmutabilidad / retenciones legales, soft delete, versionado y RBAC de plano de datos restringido.

**A2.2** — Los bloqueos se **heredan hacia abajo, y gana el bloqueo más restrictivo de la cadena de herencia**. Sobre la VM aplican ambos, así que la protección efectiva es `ReadOnly`: el borrado está bloqueado *y* toda escritura está bloqueada (sin redimensionar, sin cambiar etiquetas, sin start/stop — las operaciones `POST` que mutan estado también quedan bloqueadas, así que ni siquiera puede reiniciarla). Sobre los demás recursos del grupo solo aplica `CanNotDelete`: pueden modificarse libremente pero no borrarse. Note además que un ámbito hijo no puede *aflojar* un bloqueo heredado.

**A2.3** — **No, no literalmente.** Un bloqueo no es una frontera de autorización — cualquiera que tenga `Microsoft.Authorization/locks/delete` (Owner, User Access Administrator) puede quitar el bloqueo y luego borrar. Lo que un bloqueo realmente garantiza es que la acción destructiva pasa a ser **dos pasos deliberados en lugar de uno**: elimina el borrado accidental, el dedo gordo en la CLI y los borrados en cascada de plantillas/pipelines, y produce una entrada distinta en el registro de actividad (`Microsoft.Authorization/locks/delete`) sobre la que se puede alertar. Para una garantía que sobreviva a un Owner, necesita una **deny assignment** (ejercicio 7) o quitar el propio rol Owner.

**A2.4** — El borrado **falla**. ARM debe borrar todos los recursos del grupo para borrar el grupo; el hijo bloqueado no se puede borrar, así que la operación entera se rechaza con `ScopeLocked`. Vale la pena interiorizar la asimetría: los bloqueos se heredan *hacia abajo* para proteger, pero el borrado se evalúa *hacia arriba* — un bloqueo en cualquier punto del subárbol bloquea el borrado del padre. Puede producirse igualmente un borrado parcial de los recursos no bloqueados antes del fallo, razón por la cual conviene revisar el inventario de bloqueos antes de desmontar cualquier grupo.

---

### Ejercicio 3

**A3.1** — (1) **Se crea o actualiza un recurso** vía ARM — se evalúa de forma síncrona, en la ruta de la petición, antes de llamar al proveedor de recursos; `Deny`, `Modify`, `Append` y `Audit` actúan aquí. (2) **Se asigna, actualiza o elimina una directiva o iniciativa** — el ámbito afectado se evalúa, generalmente efectivo en unos **30 minutos**. (3) **El ciclo estándar de evaluación de cumplimiento**, que se ejecuta aproximadamente **cada 24 horas**. Además existen los escaneos bajo demanda (`az policy state trigger-scan`) y las reevaluaciones disparadas por el proveedor de recursos. `DeployIfNotExists` y `AuditIfNotExists` se evalúan *después* de que el proveedor de recursos devuelva éxito, no en la ruta de la petición.

**A3.2** — La condición usa una ruta JSON en crudo, no un **alias**. Azure Policy solo puede evaluar propiedades que el proveedor de recursos expone como alias, con la forma `Microsoft.Storage/storageAccounts/allowBlobPublicAccess`. Un `field` que no coincide con ningún alias nunca evalúa a verdadero de forma silenciosa, produciendo una asignación permanentemente "conforme" — el modo de fallo más peligroso al escribir directivas, porque parece éxito. Se detecta antes de asignar listando los alias (`az provider show --namespace <ns> --expand "resourceTypes/aliases"`) y probando contra un recurso conocidamente incorrecto en modo `DoNotEnforce`.

**A3.3** — `Indexed` le dice a Policy que evalúe solo los tipos de recurso que **admiten etiquetas y ubicación** — en la práctica, recursos individuales y no grupos de recursos, suscripciones ni recursos de extensión/hijos. Las cuentas de almacenamiento son recursos indexados, así que `Indexed` es lo correcto y evita generar resultados `NonCompliant` espurios para grupos de recursos y suscripciones que obviamente no tienen la propiedad `allowBlobPublicAccess`. Use `mode: All` cuando la directiva deba evaluar los propios grupos de recursos o suscripciones (por ejemplo "los grupos de recursos deben tener una etiqueta costCenter"), o modos de proveedor como `Microsoft.Kubernetes.Data` para el control de admisión de AKS.

**A3.4** — (a) Una denegación de RBAC sobre `Microsoft.Storage/storageAccounts/write` impide al **principal** crear *cualquier* cuenta de almacenamiento, conforme o no. Es gruesa, está acotada a la identidad y obliga a un proceso de excepción para trabajo legítimo. (b) Un `Deny` de Azure Policy bloquea solo la **forma no conforme** — el mismo ingeniero puede desplegar inmediatamente una cuenta de almacenamiento con `allowBlobPublicAccess: false` y tener éxito. Este es el punto central de diseño: Policy restringe *qué* puede existir sin restringir *quién* puede construir. Escala a plataformas de autoservicio; la denegación por RBAC no.

---

### Ejercicio 4

**A4.1** —
- **Exclusión (`notScopes`)**: el ámbito se retira por completo del alcance de la asignación. Sin evaluación, sin registro de cumplimiento, sin caducidad, sin campo de justificación. Efectivamente invisible en el panel de cumplimiento — los recursos sencillamente no aparecen.
- **Exención**: el recurso *sí* está en el ámbito, se evalúa y se informa con estado de cumplimiento **`Exempt`**. Lleva una categoría (`Waiver`/`Mitigated`), una descripción y un `expiresOn` opcional. Esta es la excepción auditable.
- **`enforcementMode: DoNotEnforce`**: aplica a la asignación entera. Los efectos no se aplican (no se deniega ni se modifica nada), pero la evaluación y el reporte de cumplimiento continúan. Es un modo what-if / de preparación, no una excepción.

La exención preserva el rastro de auditoría; la exclusión es la que desaparece del panel.

**A4.2** — **`Waiver`** = el riesgo se acepta a sabiendas, y el recurso *no* se lleva a la conformidad por otros medios (por ejemplo: un CMS heredado realmente requiere lectura anónima de blobs hasta que se migre; se sigue como deuda técnica con fecha de caducidad). **`Mitigated`** = el objetivo se cumple mediante un control alternativo, de modo que la comprobación propia de la directiva no es significativa aquí (por ejemplo: una VM carece de la extensión de protección de endpoints requerida porque es una imagen de appliance endurecida con protección provista por el fabricante, o una IP pública está exenta porque está detrás de un Azure Firewall que aplica la misma regla).

**A4.3** — **No les ocurre nada.** Un efecto `Deny` solo se evalúa en la ruta de la petición de ARM; no puede borrar ni cambiar retroactivamente recursos existentes. Las 6.000 se evaluarán en el siguiente ciclo de cumplimiento y se informarán como `NonCompliant`, y quedarán bloqueadas ante cualquier *actualización* futura que las mantenga no conformes, pero siguen ejecutándose sin tocarse. Remediar recursos existentes requiere `Modify`/`DeployIfNotExists` más una tarea de remediación, o una campaña fuera de banda.

**A4.4** — Orden de evaluación: **`Disabled` → `Append`/`Modify` → `Deny` → `Audit` → `AuditIfNotExists`/`DeployIfNotExists`**.
Importa porque (1) `Disabled` cortocircuita todo, que es la forma de matar al instante una directiva que está fallando sin borrar la asignación; (2) `Modify`/`Append` se ejecutan *antes* que `Deny`, así que una directiva que añade una etiqueta obligatoria puede satisfacer a una segunda directiva que deniega recursos sin esa etiqueta — el orden determina si las dos componen o entran en conflicto; (3) `Audit` se ejecuta después de `Deny`, así que una petición denegada no genera registro de auditoría de un recurso que nunca se creó; (4) los efectos `*IfNotExists` se ejecutan solo después de que el proveedor de recursos devuelva éxito, porque inspeccionan recursos *relacionados* que no pueden existir hasta que exista el padre.

---

### Ejercicio 5

**A5.1** — Un estándar regulatorio son decenas o cientos de controles técnicos discretos, cada uno mapeado a un tipo de recurso y una propiedad distintos. Una iniciativa es la unidad de **asignación, parametrización y reporte**: permite asignar 200 definiciones de una vez, parametrizarlas de forma consistente (regiones permitidas, días de retención de logs, etiquetas obligatorias) y reportar una única cifra agregada de cumplimiento por marco y por ámbito. También da a cada miembro un `policyDefinitionReferenceId`, que es como un ID de control (p. ej. `AC-2`) queda ligado a la comprobación técnica y como las exenciones pueden apuntar a un solo control sin desactivar el conjunto.

**A5.2** — **Azure Policy.** El panel de Regulatory Compliance de Defender for Cloud es una capa de presentación sobre **iniciativas de directiva** integradas — el estado de cumplimiento de cada control es el estado agregado de cumplimiento de directivas de sus definiciones miembro, tomado de la API `policyStates` de Policy Insights. Los mismos datos son accesibles vía `az policy state summarize` y Azure Resource Graph. Defender for Cloud añade la agrupación por familia de controles, los metadatos del marco y la experiencia de recomendaciones; no realiza la evaluación.

**A5.3** — El efecto **`Manual`** existe para controles que no pueden evaluarse inspeccionando propiedades de recursos — controles de proceso, documentación y físicos/organizativos ("existe un programa de concienciación en seguridad", "se realizan verificaciones de antecedentes"). Su estado de cumplimiento por defecto es **`Unknown`**, y una persona con el permiso adecuado (`Microsoft.PolicyInsights/policyStates/write`, vía un rol como Resource Policy Contributor) debe **atestar** el estado como `Compliant` o `NonCompliant`, opcionalmente con evidencia. Es el mecanismo que permite que un único panel cubra controles técnicos y procedimentales, y es responsabilidad del cliente, nunca de Microsoft.

**A5.4** — Dos de muchas razones válidas: (1) **Brecha de cobertura** — la iniciativa solo mide lo que comprueban sus definiciones miembro, y no todo control de un estándar tiene una comprobación automatizable; los controles `Manual` y los gestionados por Microsoft pueden quedar intactos. (2) **Brecha de ámbito** — el cumplimiento se informa para el ámbito que cubre la asignación; las suscripciones, grupos de administración o tipos de recurso fuera de ese ámbito no aportan nada, así que un 100% puede significar "el 100% del 3% que asignamos". Otras: los recursos exentos informan `Exempt` en lugar de `NonCompliant` y pueden quedar fuera del denominador según la vista; una definición que usa un alias inválido pasa en silencio (véase A3.2); y las asignaciones con `enforcementMode: DoNotEnforce` informan estado sin haber aplicado nunca nada.

---

### Ejercicio 6

**A6.1** — `Modify` y `DeployIfNotExists` **cambian recursos** — realizan escrituras o despliegues de plantillas en nombre del cliente. Por lo tanto, Azure Policy necesita un principal de seguridad con permiso para hacerlo, que es la identidad administrada de la asignación (asignada por el sistema o por el usuario), a la que se conceden exactamente los roles declarados en `roleDefinitionIds` de la definición. `Audit` y `Deny` solo leen la petición entrante o el estado del recurso existente y producen un veredicto; no realizan escrituras, así que una identidad sería privilegio innecesario. Azure Policy lo hace cumplir: asignar una directiva `Modify`/`DeployIfNotExists` sin identidad falla, y asignar una directiva `Audit` con identidad se rechaza como inválida.

**A6.2** — `Modify` **muta propiedades o etiquetas del recurso que se está evaluando**, en la ruta de la petición (operaciones add/addOrReplace/remove sobre alias y etiquetas). `DeployIfNotExists` **despliega una plantilla ARM que crea o configura un recurso *relacionado*** cuando falta un objeto acompañante requerido, y se ejecuta *después* de que el proveedor de recursos tenga éxito. Solo `Modify` puede añadir una etiqueta `costCenter` a la propia cuenta de almacenamiento a medida que se crea. Solo `DeployIfNotExists` puede crear la configuración de diagnóstico que envía los logs de esa cuenta a un workspace de Log Analytics, o instalar una extensión de VM — esos son recursos separados que `Modify` no puede tocar.

**A6.3** — `DeployIfNotExists` (igual que `Deny` y `Modify`) se evalúa en la **ruta de la petición** para recursos nuevos y actualizados. Los 900 recursos más antiguos se crearon antes de que existiera la asignación, así que nunca se disparó ningún despliegue para ellos; el ciclo periódico de evaluación los informa correctamente como `NonCompliant`, pero nada actúa sobre ellos. La solución es crear una **tarea de remediación** contra la asignación (`az policy remediation create --resource-discovery-mode ExistingNonCompliant`), que enumera los recursos no conformes y ejecuta el despliegue embebido para cada uno, usando la identidad administrada de la asignación.

**A6.4** — `conflictEffect` gobierna qué ocurre cuando **dos directivas `Modify` escribirían valores conflictivos en el mismo campo** del mismo recurso — por ejemplo, una directiva que hereda `costCenter` del grupo de recursos y otra que fuerza un valor fijo. Con `conflictEffect: audit`, la operación no se aplica y el recurso simplemente se marca como no conforme, de modo que un conflicto de directivas degrada a un problema de reporte. Con `conflictEffect: deny`, *la propia petición del recurso se bloquea* — un error al escribir la directiva se convierte en una caída para todos los despliegues del ámbito. `audit` es el valor por defecto seguro para un despliegue progresivo; `deny` solo es apropiado cuando un valor ambiguo es peor que un despliegue fallido.

---

### Ejercicio 7

**A7.1** —

| | Resource lock | Deny assignment | Azure Policy `Deny` |
|---|---|---|---|
| **Qué protege** | Un recurso / RG / suscripción concreto, frente a `DELETE` (y escrituras, si es `ReadOnly`) | Un conjunto concreto de recursos y acciones, frente a un conjunto de principales, con independencia de sus roles de RBAC | La *forma* de cualquier recurso que coincida con la regla, en cualquier ámbito de la asignación |
| **¿Puede un Owner saltárselo directamente?** | **Sí** — un Owner puede borrar el bloqueo y luego actuar (dos pasos, ambos registrados) | **No** — una deny assignment tiene precedencia sobre toda asignación de rol, incluido Owner; solo puede quitarse borrando/actualizando el objeto que la creó (el deployment stack, o el sistema en el caso de las deny assignments de aplicaciones administradas) | **No** — Owner no tiene bypass; solo una exención, una exclusión o desasignar la directiva cambian el resultado |
| **¿Aplica a recursos existentes?** | Sí, de inmediato, para operaciones futuras sobre ellos | Sí, para operaciones futuras sobre los recursos gestionados | Se evalúa para el reporte de cumplimiento, pero el efecto `Deny` en sí solo bloquea peticiones *nuevas o de actualización*; nunca toca recursos en reposo |

**A7.2** — La respuesta histórica es **Azure Blueprints**. Su estado actual es **obsoleto** — la vista previa no llegará a GA, y Microsoft ha anunciado su retirada (11 de julio de 2026), dirigiendo a los clientes a la ruta de reemplazo. El reemplazo es **Template Specs** (artefactos ARM/Bicep versionados y controlados por RBAC, almacenados en Azure) combinados con **Deployment Stacks** (gestión del ciclo de vida de un conjunto de recursos más deny settings que reproducen el comportamiento de bloqueo de los blueprints), con la directiva y el RBAC entregados mediante los mecanismos normales de Azure Policy y asignación de roles — típicamente orquestados como infraestructura como código en un acelerador de landing zone. Si un ítem de examen todavía lista Blueprints como opción para esta descripción, sigue siendo la respuesta prevista para ese ítem.

**A7.3** — Con `--action-on-unmanage deleteAll`, borrar el stack **borra todos los recursos que el stack gestiona, y los grupos de recursos que creó**, no solo el objeto stack. En un stack de producción esto es un desmantelamiento completo de la huella gestionada en un único comando — almacenes de datos incluidos, sujeto únicamente a los bloqueos o deny assignments que sigan en pie. `detachAll` (la postura segura por defecto) elimina el stack y sus deny assignments dejando todos los recursos funcionando; `deleteResources` borra los recursos gestionados pero preserva los grupos de recursos. Como la definición del stack lleva esta configuración, el radio de impacto se decide en tiempo de despliegue por quien escribió el pipeline, no en tiempo de borrado por quien ejecuta el comando — que es precisamente por qué pertenece a la revisión de código.

---

### Ejercicio 8

**A8.1** — Lo responde **Microsoft Purview**: el **Data Map** escanea orígenes registrados en Azure, on-premises y otras nubes, aplica **clasificaciones** a partir de tipos de información confidencial integrados (números de identificación nacional/regional entre ellos), y la superficie de **Data Catalog / Data Estate Insights** permite filtrar activos por clasificación y por la región del origen. La reincidencia se previene del lado de Azure con un efecto **`Deny`** de Azure Policy sobre ubicaciones permitidas (el integrado `Allowed locations`, opcionalmente acotado a los tipos de recurso de servicios de datos) asignado en el ámbito de grupo de administración — más, para los recursos existentes, una remediación `DeployIfNotExists`/`Modify` o una campaña de migración, ya que `Deny` no mueve nada que ya exista.

**A8.2** —
- **Trust Center** (<https://www.microsoft.com/trust-center>) — el sitio público de nivel general que describe el enfoque de Microsoft sobre seguridad, privacidad, cumplimiento y transparencia. Sin puntuación, sin descargas bajo NDA; es la puerta de entrada.
- **Service Trust Portal** (<https://servicetrust.microsoft.com>) — el repositorio autenticado de **informes de auditoría y certificaciones de terceros**: SOC 1/2/3, ISO 27001/27018, paquetes FedRAMP, resúmenes de pruebas de penetración y recursos de protección de datos. Aquí es donde se satisface la solicitud de evidencia de un auditor.
- **Compliance Manager** (en el portal de Microsoft Purview) — la **herramienta de evaluación de riesgo que produce una puntuación de cumplimiento**, descompone los marcos en acciones de mejora repartidas entre controles gestionados por Microsoft y gestionados por el cliente, y hace seguimiento de la evidencia y la asignación de esas acciones.

**A8.3** — **No.** Los controles gestionados por Microsoft los implementa y audita Microsoft; sus puntos ya están acreditados en su puntuación y usted no puede actuar sobre ellos. Solo puede subir su puntuación completando acciones de mejora **gestionadas por el cliente** (y compartidas). Este es el modelo de responsabilidad compartida hecho número: una parte de su postura de cumplimiento se hereda del proveedor de nube — seguridad física, parcheo del hipervisor, operaciones del centro de datos — y otra parte es irreductiblemente suya: configuración de identidad, clasificación de datos, revisiones de acceso, gestión de claves de cifrado, directiva de retención. El valor de Compliance Manager es precisamente que hace explícita esa frontera en lugar de darla por supuesta.

**A8.4** — Muestra que **Microsoft Purview es un producto del patrimonio de datos, no un producto de recursos de Azure**. Su alcance es allí donde vivan los datos de la organización — Azure, AWS, GCP, SQL Server y recursos compartidos de archivos on-premises (mediante un self-hosted integration runtime), Power BI y Microsoft 365 — porque la pregunta de gobernanza ("dónde están nuestros datos sensibles, quién es su dueño, hacia dónde fluyen") no respeta fronteras de nube. Azure Policy, en cambio, evalúa **recursos de Azure Resource Manager** y solo esos; lo más cerca que llega de salir de Azure es vía **Azure Arc**, que proyecta servidores y clústeres de Kubernetes fuera de Azure dentro de ARM para que la directiva pueda entonces evaluarlos como recursos de Azure.

**A8.5** — Azure Policy opera en el **plano de control**: ve la representación ARM de un recurso — su tipo, ubicación, SKU, etiquetas y propiedades de configuración. Puede determinar que una cuenta de almacenamiento existe, está en `eastus` y permite acceso público a blobs. Estructuralmente no puede ver **qué hay dentro** de esa cuenta, porque el contenido de los blobs nunca atraviesa ARM. Microsoft Purview opera en el **plano de datos**: se autentica contra el origen (identidad administrada, service principal o clave), lee esquemas y muestras de contenido, y hace coincidencia de patrones contra los tipos de información confidencial. Los dos son complementarios y no se solapan — Policy gobierna el contenedor, Purview gobierna el contenido — y ninguno sustituye al otro.

---

### Ejercicio 9

**A9.1** —

1. **Resource lock** (`CanNotDelete`). Policy no puede proteger un recurso existente frente al borrado; quitar el RBAC también bloquearía la gestión legítima de la VM. (Note la salvedad de A2.3 sobre "incluidos los administradores".)
2. **Azure Policy** — el integrado `Allowed locations`, efecto `Deny`, asignado en el **grupo de administración** que cubre el inquilino. No un bloqueo (los bloqueos no evalúan la ubicación), no RBAC (es un requisito agnóstico a la identidad).
3. **Microsoft Purview** — escaneo con Data Map y clasificación, incluidos orígenes on-premises mediante un self-hosted integration runtime. Azure Policy no puede ver el contenido del plano de datos.
4. **Service Trust Portal.** Compliance Manager hace seguimiento de *sus* acciones y puntuación; no aloja las cartas de atestación de Microsoft. El Trust Center es material general.
5. **Microsoft Purview Compliance Manager.** Es el único de estos que produce una puntuación con acciones de mejora y carga de evidencias.
6. **Azure Policy** con el efecto **`Modify`**, una identidad administrada y una **tarea de remediación** con `--resource-discovery-mode ExistingNonCompliant` para las 900 cuentas existentes. `Deny` no arreglaría nada que ya exista.
7. **Azure RBAC** (no conceder o retirar el rol que otorga `write` en ese ámbito; opcionalmente una **deny assignment**). Es un requisito acotado a la identidad — "nadie del grupo X" — que es exactamente lo que Policy no puede expresar y para lo que existe RBAC.
8. **Deployment stack con `denySettingsMode: denyWriteAndDelete`** (que crea una deny assignment). Un bloqueo `ReadOnly` es el vecino cercano, pero un Owner puede quitarlo y no está ligado al ciclo de vida del despliegue.
9. **Azure Policy** con el efecto **`AuditIfNotExists`** (o una definición `Audit`/`DeployIfNotExists` asignada con `enforcementMode: DoNotEnforce`). El requisito es explícitamente "informar, no bloquear".
10. **Iniciativa de Azure Policy** (policy set definition), asignada por suscripción — idealmente heredada de un grupo de administración.

**A9.2** —
- **Ítem 1 — resource lock.** Lo aplica ARM contra un *ámbito*, afecta a **todos los principales** por igual, bloquea un verbo ARM concreto (`DELETE`), y es **removible por cualquiera que tenga `Microsoft.Authorization/locks/delete`**.
- **Ítem 7 — RBAC.** Lo aplica la capa de autorización contra un **principal**, es deny por defecto con concesiones explícitas, y es el único de los tres que puede expresar "estas personas, no aquellas".
- **Ítem 8 — deny assignment.** La aplica la capa de autorización, **anula toda asignación de rol incluido Owner**, está acotada a los recursos que gestiona un deployment stack, y solo es removible a través del objeto que la creó.

No son intercambiables porque cada uno responde una pregunta distinta: el bloqueo responde *"¿puede este verbo ejecutarse contra este recurso, en absoluto?"*, RBAC responde *"¿esta identidad tiene permiso?"*, y la deny assignment responde *"¿está este recurso bajo control gestionado de ciclo de vida que ningún rol puede anular?"*. Azure Policy — el cuarto mecanismo — responde una pregunta que ninguno de ellos toca: *"¿es aceptable la configuración del recurso resultante?"*.

</details>