# Tema 2.1 — Ejercicios guiados
## Describir los componentes arquitectónicos centrales de Azure
**Certificación:** AZ-900 (versión del examen 2026-07-20) · **Peso de este tema en el examen:** 9.62%

---

### De qué vas a construir un modelo mental

El enunciado de habilidad de AZ-900 cubre dos jerarquías ortogonales que quienes empiezan suelen fusionar en una sola, y esa fusión es la fuente más común de respuestas incorrectas en este tema:

| Jerarquía | Niveles | Propiedad de | Responde a la pregunta |
|---|---|---|---|
| **Física** | geografía → región (→ par de regiones) → zona de disponibilidad → datacenter | Microsoft, fija | *¿Dónde vive físicamente mi dato, y qué falla en conjunto?* |
| **Lógica (gestión)** | grupo de administración → suscripción → grupo de recursos → recurso | Vos, arbitraria | *¿Quién paga, quién gobierna, y qué se borra junto?* |

Se cruzan en exactamente un punto: un **recurso** tiene un `location` (física) *y* vive en un **grupo de recursos** (lógica). Nada más en una jerarquía condiciona a la otra — un grupo de recursos en `eastus` puede contener recursos en `japaneast`.

Todo lo que sigue se ejecuta contra el plano de control de Azure, **Azure Resource Manager (ARM)**, que es el punto de entrada único tanto para el portal como para la CLI, PowerShell, Terraform y la API REST.

**Aviso de costo y seguridad.** Los ejercicios 1–4 y 7 son de **solo lectura** y no cuestan nada. El ejercicio 5 crea dos cuentas StorageV2 vacías (las cuentas vacías no acumulan cargos significativos — la facturación es por GB almacenado y por transacción) y termina con un paso de limpieza. El ejercicio 6 es de solo lectura. No ejecutes nada de esto contra una suscripción de producción: usá una suscripción personal, de capa gratuita, o de sandbox.

**Referencia para todo el tema:**
- Guía de estudio: <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Regiones y geografías: <https://learn.microsoft.com/en-us/azure/reliability/regions-overview>
- Zonas de disponibilidad: <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Azure Resource Manager: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview>

---

## Ejercicio 0 — Preparación del entorno

Necesitás Azure CLI ≥ 2.60 y una suscripción en la que tengas al menos **Reader** (ejercicios 1–4, 6, 7) y **Contributor** sobre un grupo de recursos que puedas crear (ejercicio 5).

1. Verificá que la CLI esté instalada y sea suficientemente reciente. `az version` imprime la versión del núcleo más las extensiones instaladas:

   ```bash
   az version
   ```

   ```json
   {
     "azure-cli": "2.64.0",
     "azure-cli-core": "2.64.0",
     "azure-cli-telemetry": "1.1.0",
     "extensions": {}
   }
   ```

2. Autenticate. Esto abre un navegador; en una shell sin entorno gráfico usá `az login --use-device-code`:

   ```bash
   az login
   ```

3. Listá las suscripciones que puede ver tu identidad, y notá que cada una está ligada a exactamente un **tenant de Microsoft Entra ID** (`tenantId`):

   ```bash
   az account list --query "[].{Name:name, SubscriptionId:id, Tenant:tenantId, State:state, Default:isDefault}" -o table
   ```

   ```text
   Name                 SubscriptionId                        Tenant                                State    Default
   -------------------  ------------------------------------  ------------------------------------  -------  -------
   Visual Studio Ent.   00000000-1111-2222-3333-444444444444  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled  True
   Lab-Sandbox          55555555-6666-7777-8888-999999999999  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled  False
   ```

4. Fijá la suscripción en la que vas a trabajar por el resto de la sesión, y exportala como variable de shell — todo ID de recurso ARM que leas más adelante empieza con ella:

   ```bash
   az account set --subscription "Lab-Sandbox"
   export SUB_ID=$(az account show --query id -o tsv)
   echo "$SUB_ID"
   ```

   ```text
   55555555-6666-7777-8888-999999999999
   ```

5. Confirmá con qué **instancia de nube** de Azure está hablando la CLI. Este es el conjunto de endpoints, y es el mecanismo detrás de las "regiones soberanas":

   ```bash
   az cloud show --query "{Cloud:name, ARM:endpoints.resourceManager, Storage:suffixes.storageEndpoint}" -o yaml
   ```

   ```yaml
   ARM: https://management.azure.com/
   Cloud: AzureCloud
   Storage: core.windows.net
   ```

> **Verificá tu comprensión — Bloque 0**
>
> **Q0.1** Un colega dice "te di Reader sobre el tenant, deberías ver todas las suscripciones". ¿Por qué `az account list` todavía puede devolverle cero suscripciones?
> **Q0.2** `az account show` devuelve tanto un `id` como un `tenantId`. ¿Cuál de los dos es el límite de *facturación* y cuál el límite de *identidad*?
> **Q0.3** En el paso 5 el sufijo de storage es `core.windows.net`. ¿Cuál sería ese sufijo si hubieras ejecutado `az cloud set --name AzureUSGovernment`, y qué te dice esa diferencia sobre la conectividad entre nubes?

---

## Ejercicio 1 — Enumerar la huella física: geografías, regiones, pares de regiones

Una **región** es un conjunto de datacenters desplegados dentro de un perímetro definido por latencia y conectados por una red dedicada de baja latencia. Una **geografía** es un mercado discreto — típicamente un país o un grupo de países — que contiene dos o más regiones y preserva los límites de residencia de datos y cumplimiento. Las regiones son la unidad en la que desplegás; las geografías son la unidad que les importa a los auditores de cumplimiento.

1. Listá todas las ubicaciones visibles para tu suscripción. Notá que la cantidad de filas es muy superior al número de regiones "reales":

   ```bash
   az account list-locations --query "length(@)"
   ```

   ```text
   82
   ```

2. Dividí esa lista por `metadata.regionType`. Las ubicaciones `Physical` son regiones reales; las ubicaciones `Logical` son agregaciones como `global`, `asiapacific` o `europe` usadas por servicios no regionales (Entra ID, Azure DNS, Traffic Manager, Front Door):

   ```bash
   az account list-locations \
     --query "[].metadata.regionType" -o tsv | sort | uniq -c
   ```

   ```text
     8 Logical
    74 Physical
   ```

3. Mostrá las regiones físicas con su geografía, la ciudad del datacenter legible por humanos, y el nivel de recomendación de la propia Microsoft (`regionCategory`). Las regiones `Recommended` son las que Microsoft espera que use la mayoría de los clientes y donde primero aterrizan los servicios nuevos y las zonas de disponibilidad; las regiones `Other` son típicamente específicas de capacidad o de cumplimiento:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{Region:name, Geography:metadata.geography, City:metadata.physicalLocation, Tier:metadata.regionCategory}" \
     -o table | head -15
   ```

   ```text
   Region              Geography       City             Tier
   ------------------  --------------  ---------------  -----------
   eastus              United States   Virginia         Recommended
   eastus2             United States   Virginia         Recommended
   southcentralus      United States   Texas            Recommended
   westus2             United States   Washington       Recommended
   westus3             United States   Phoenix          Recommended
   northeurope         Europe          Ireland          Recommended
   westeurope          Europe          Netherlands      Recommended
   swedencentral       Europe          Gävle            Recommended
   uksouth             United Kingdom  London           Recommended
   brazilsouth         Brazil          Sao Paulo State  Recommended
   japaneast           Japan           Tokyo, Saitama   Recommended
   australiaeast       Australia       New South Wales  Recommended
   centralus           United States   Iowa             Recommended
   westus              United States   California       Other
   ```

4. Extraé los **pares de regiones**. Una región emparejada es una segunda región en la *misma geografía*, elegida por Microsoft (no la podés elegir vos), usada para replicación gestionada por la plataforma (storage GRS/GZRS), actualizaciones escalonadas de la plataforma — Microsoft nunca parchea ambas mitades de un par simultáneamente — y capacidad de recuperación priorizada durante una interrupción amplia:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && metadata.pairedRegion!=null].{Region:name, Geography:metadata.geography, Pair:metadata.pairedRegion[0].name}" \
     -o table | head -12
   ```

   ```text
   Region           Geography       Pair
   ---------------  --------------  ---------------
   eastus           United States   westus
   eastus2          United States   centralus
   southcentralus   United States   northcentralus
   westus2          United States   westcentralus
   northeurope      Europe          westeurope
   westeurope       Europe          northeurope
   uksouth          United Kingdom  ukwest
   japaneast        Japan           japanwest
   brazilsouth      Brazil          southcentralus
   australiaeast    Australia       australiasoutheast
   ```

5. Encontrá la excepción a la regla de "el par se queda dentro de la geografía", y después encontrá las regiones que **no tienen par en absoluto**:

   ```bash
   # the documented one-way exception
   az account list-locations \
     --query "[?name=='brazilsouth'].{Region:name, Geo:metadata.geography, Pair:metadata.pairedRegion[0].name}" -o table

   # regions with no pair — increasingly common for newer, single-region geographies
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && metadata.pairedRegion==null].{Region:name, Geo:metadata.geography, Tier:metadata.regionCategory}" \
     -o table
   ```

   ```text
   Region       Geo     Pair
   -----------  ------  --------------
   brazilsouth  Brazil  southcentralus

   Region           Geo      Tier
   ---------------  -------  -----------
   israelcentral    Israel   Recommended
   italynorth       Italy    Recommended
   polandcentral    Poland   Recommended
   qatarcentral     Qatar    Recommended
   ```

   `brazilsouth` se empareja *fuera* de su geografía con `southcentralus`, y la relación **no es simétrica**: `southcentralus` se empareja de vuelta con `northcentralus`, no con Brasil. Las regiones sin par de la segunda tabla son geografías nuevas de una sola región: la recomendación de Microsoft ahí son zonas de disponibilidad para resiliencia dentro de la región más una región secundaria explícita, elegida por el cliente, para DR — no hay un par gestionado por la plataforma al que recurrir.

6. Confirmá cómo se ve una ubicación *lógica*, y por qué un recurso `global` no tiene región desde la cual conmutar por error:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Logical'].{Name:name, Type:metadata.regionType, Geo:metadata.geographyGroup}" -o table
   ```

   ```text
   Name           Type     Geo
   -------------  -------  ------
   global         Logical
   asiapacific    Logical  Asia Pacific
   europe         Logical  Europe
   unitedstates   Logical  US
   ```

> **Verificá tu comprensión — Bloque 1**
>
> **Q1.1** Tenés que garantizar que los registros de clientes nunca salgan de la Unión Europea. ¿Alcanza con decir "solo desplegamos en `westeurope`"? ¿Qué le hace a esa garantía el mecanismo de pares de regiones si habilitás storage GRS?
> **Q1.2** ¿Por qué `brazilsouth → southcentralus` es un problema de residencia de datos que `northeurope → westeurope` no es?
> **Q1.3** Tu arquitectura asume "Azure siempre me da una región emparejada para DR". Nombrá dos regiones del paso 5 donde esa suposición es falsa, y decí qué tenés que hacer en su lugar.
> **Q1.4** Una región es `Other` en lugar de `Recommended`. Dá dos consecuencias operativas concretas de elegirla.
> **Q1.5** Entra ID reporta su ubicación como `global`. Explicá, en términos de la jerarquía física, por qué "¿en qué región está mi tenant de Entra?" es una pregunta mal formulada.

---

## Ejercicio 2 — Nubes soberanas: el límite de aislamiento más duro de Azure

Las **regiones soberanas** no son regiones dentro de la nube pública con reglas extra. Son *instancias físicas y lógicas separadas de Azure*, con sus propios endpoints de ARM, su propio Entra ID, su propia URL de portal, y su propio catálogo de servicios. Nada se federa entre ellas por defecto.

1. Listá las instancias de nube que conoce la CLI:

   ```bash
   az cloud list --query "[].{Cloud:name, ARM:endpoints.resourceManager, Portal:endpoints.portal, Active:isActive}" -o table
   ```

   ```text
   Cloud              ARM                                   Portal                             Active
   -----------------  ------------------------------------  ---------------------------------  ------
   AzureCloud         https://management.azure.com/         https://portal.azure.com           True
   AzureChinaCloud    https://management.chinacloudapi.cn/  https://portal.azure.cn            False
   AzureUSGovernment  https://management.usgovcloudapi.net/ https://portal.azure.us            False
   ```

2. Inspeccioná el conjunto completo de sufijos de una nube soberana sin cambiarte a ella:

   ```bash
   az cloud show --name AzureUSGovernment \
     --query "{ARM:endpoints.resourceManager, AAD:endpoints.activeDirectory, Storage:suffixes.storageEndpoint, SQL:suffixes.sqlServerHostname}" -o yaml
   ```

   ```yaml
   AAD: https://login.microsoftonline.us
   ARM: https://management.usgovcloudapi.net/
   SQL: .database.usgovcloudapi.net
   Storage: core.usgovcloudapi.net
   ```

3. Probá el aislamiento empíricamente. Con `AzureCloud` activa, pedí una región de US Government por nombre — ARM nunca oyó hablar de ella:

   ```bash
   az account list-locations --query "[?name=='usgovvirginia']" -o json
   ```

   ```json
   []
   ```

4. Fijate en los modelos operativos, que es lo que realmente pregunta el examen:
   - **Azure Government** (`usgovvirginia`, `usgovarizona`, …) — operada por Microsoft, personal estadounidense verificado, físicamente aislada, alineada con FedRAMP High / DoD IL5.
   - **Azure operada por 21Vianet** (China: `chinanorth3`, `chinaeast2`, …) — operada por **21Vianet, no por Microsoft**, para satisfacer la ley china. Microsoft licencia la tecnología; no opera los datacenters.

> **Verificá tu comprensión — Bloque 2**
>
> **Q2.1** ¿Podés crear un grupo de recursos en `usgovvirginia` desde una suscripción de la nube pública? Justificá con lo que observaste en el paso 3.
> **Q2.2** ¿Quién opera físicamente Azure en China, y por qué importa esa respuesta para un runbook de escalamiento de soporte?
> **Q2.3** Tu único tenant de Entra ID contiene todas las identidades corporativas. Un equipo pide "simplemente agregá la suscripción de Government a nuestro tenant". ¿Qué está mal en el pedido?
> **Q2.4** Una URL de blob hardcodeada en tu aplicación es `https://stprod.blob.core.windows.net/data`. ¿Qué se rompe si esa aplicación se redespliega en Azure Government, y qué valor de endpoint del paso 2 es la solución?

---

## Ejercicio 3 — Zonas de disponibilidad: números lógicos, datacenters físicos

Una **zona de disponibilidad** es uno o más datacenters dentro de una región con **energía, refrigeración y red independientes**, conectados a las otras zonas por una red privada de alto rendimiento y baja latencia (típicamente <2 ms de ida y vuelta). Una región habilitada para AZ tiene un **mínimo de tres** zonas. Las zonas protegen contra fallas a nivel *datacenter*; **no** protegen contra un evento que afecte a toda la región.

1. Determiná qué regiones tienen zonas. Las versiones recientes de la CLI exponen el mapeo directamente:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && availabilityZoneMappings!=null].{Region:name, Zones:length(availabilityZoneMappings)}" \
     -o table | head -10
   ```

   ```text
   Region          Zones
   --------------  -------
   eastus          3
   eastus2         3
   westus2         3
   westus3         3
   northeurope     3
   westeurope      3
   swedencentral   3
   uksouth         3
   japaneast       3
   australiaeast   3
   ```

2. Si tu versión de la CLI no expone ese campo, consultá ARM directamente. Esta es la fuente autoritativa y vale la pena conocerla porque revela algo que la tabla de arriba oculta:

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB_ID/locations?api-version=2022-12-01" \
     --query "value[?name=='eastus'].availabilityZoneMappings[]" -o json
   ```

   ```json
   [
     { "logicalZone": "1", "physicalZone": "eastus-az3" },
     { "logicalZone": "2", "physicalZone": "eastus-az1" },
     { "logicalZone": "3", "physicalZone": "eastus-az2" }
   ]
   ```

   **Este es el hecho más subenseñado sobre las zonas de disponibilidad.** Los números `1`, `2`, `3` que escribís en un despliegue son **etiquetas lógicas por suscripción**. Microsoft baraja el mapeo lógico→físico por suscripción para distribuir la carga de manera pareja en la región. La zona `1` en *tu* suscripción es muy probablemente un datacenter físico distinto de la zona `1` en la suscripción de tu colega.

3. Ejecutá la misma consulta contra una segunda suscripción y compará, si tenés una:

   ```bash
   for s in $(az account list --query "[].id" -o tsv); do
     echo "--- $s"
     az rest --method get \
       --url "https://management.azure.com/subscriptions/$s/locations?api-version=2022-12-01" \
       --query "value[?name=='eastus'].availabilityZoneMappings[].{L:logicalZone,P:physicalZone}" -o tsv
   done
   ```

   ```text
   --- 00000000-1111-2222-3333-444444444444
   1	eastus-az1
   2	eastus-az2
   3	eastus-az3
   --- 55555555-6666-7777-8888-999999999999
   1	eastus-az3
   2	eastus-az1
   3	eastus-az2
   ```

4. Verificá si un SKU de VM específico se ofrece efectivamente en cada zona de una región. El soporte de zonas es por región **y** por SKU — que una región tenga zonas no significa que todo SKU esté en todas las zonas:

   ```bash
   az vm list-skus --location eastus --size Standard_D4s_v5 --resource-type virtualMachines \
     --query "[].{SKU:name, Zones:locationInfo[0].zones}" -o json
   ```

   ```json
   [
     {
       "SKU": "Standard_D4s_v5",
       "Zones": ["1", "2", "3"]
     }
   ]
   ```

5. Clasificá los tres patrones de despliegue. Esta taxonomía es el objetivo del examen:

   | Patrón | Vos especificás | Falla de una zona | Ejemplo |
   |---|---|---|---|
   | **Zonal** | Una zona explícita (`--zone 2`) | Esa instancia desaparece; tenés que haber construido vos mismo la redundancia entre zonas | VM, disco administrado, IP pública zonal |
   | **Redundante por zonas** | Nada — la plataforma lo distribuye | El servicio sigue funcionando, de forma transparente | Storage ZRS, SQL DB redundante por zonas, Standard Load Balancer |
   | **Regional (no zonal)** | Nada, ninguna garantía de zona | Indefinido — puede sobrevivir o no | Storage LRS, servicios de capa Basic |

6. Verificá la clasificación en los SKU de replicación de storage disponibles en una región con AZ versus una región sin AZ:

   ```bash
   az storage account list-skus --query "[].name" -o tsv 2>/dev/null || \
   echo "Standard_LRS Standard_ZRS Standard_GRS Standard_GZRS Standard_RAGRS Premium_LRS Premium_ZRS"
   ```

   ```text
   Standard_LRS Standard_ZRS Standard_GRS Standard_GZRS Standard_RAGRS Premium_LRS Premium_ZRS
   ```

   Mapeo a la jerarquía: `LRS` = tres copias en **un datacenter** (zona). `ZRS` = tres copias distribuidas en **tres zonas**, misma región. `GRS` = LRS localmente + copia asincrónica en la **región emparejada**. `GZRS` = ZRS localmente + copia asincrónica en la región emparejada. Cada escalón que subís te compra un nivel más de la jerarquía física.

> **Verificá tu comprensión — Bloque 3**
>
> **Q3.1** Vos y un compañero de equipo despliegan una VM cada uno en la "zona 1" de `eastus`, desde suscripciones distintas, y lo llaman un par de alta disponibilidad. Usando la salida del paso 3, explicá qué está mal — y qué está accidentalmente *bien* — en esa configuración.
> **Q3.2** Una VM única está fijada a `--zone 1`. ¿Es redundante por zonas? ¿Cuál es el cambio mínimo que hace que la *carga de trabajo* sea redundante por zonas?
> **Q3.3** Ordená `Standard_LRS`, `Standard_ZRS` y `Standard_GRS` según la falla más grande que sobreviven, y nombrá el dominio de falla en el que se detiene cada uno.
> **Q3.4** `az account list-locations` muestra zonas para una región, pero `az vm list-skus` devuelve `"Zones": []` para el SKU que querés. ¿Cuál es la conclusión correcta, y cuáles son tus dos opciones?
> **Q3.5** Una inundación deja fuera de servicio toda la región `westeurope`. ¿Cuáles de los siguientes sobreviven: una cuenta de storage ZRS en `westeurope`; una cuenta de storage GRS en `westeurope`; un conjunto zonal de VMs distribuido en las zonas 1, 2, 3 de `westeurope`?

---

## Ejercicio 4 — La jerarquía de gestión: grupo de administración → suscripción → grupo de recursos → recurso

Esta es la jerarquía **lógica**. Su propósito no es la resiliencia — es gobernanza, facturación y control de acceso. Las asignaciones de directivas y RBAC **heredan hacia abajo** y solo hacia abajo.

1. Leé la cima del árbol. Cada tenant de Entra ID tiene exactamente un grupo de administración raíz, cuyo ID es igual al ID del tenant y cuyo nombre para mostrar por defecto es *Tenant Root Group*:

   ```bash
   az account management-group list --query "[].{Name:displayName, Id:name, Type:type}" -o table
   ```

   ```text
   Name              Id                                    Type
   ----------------  ------------------------------------  --------------------------------------------
   Tenant Root Group  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Microsoft.Management/managementGroups
   ```

   Si esto devuelve un error de autorización, no te otorgaron acceso en el ámbito raíz. Eso es normal y por diseño — el acceso a la raíz requiere una elevación explícita por parte de un Administrador Global. En ese caso tratá los pasos 2–4 como de solo lectura y pasá al paso 5.

2. Construí un pequeño árbol de gobernanza. Los grupos de administración son gratuitos y no tienen región:

   ```bash
   TENANT_ID=$(az account show --query tenantId -o tsv)

   az account management-group create --name "mg-contoso"  --display-name "Contoso"
   az account management-group create --name "mg-prod"     --display-name "Production"  --parent "mg-contoso"
   az account management-group create --name "mg-nonprod"  --display-name "Non-Production" --parent "mg-contoso"
   ```

3. Mostrá el árbol, expandido y recursivo:

   ```bash
   az account management-group show --name "mg-contoso" --expand --recurse \
     --query "{Name:displayName, Children:children[].{Name:displayName, Type:type, Id:name}}" -o yaml
   ```

   ```yaml
   Children:
   - Id: mg-nonprod
     Name: Non-Production
     Type: Microsoft.Management/managementGroups
   - Id: mg-prod
     Name: Production
     Type: Microsoft.Management/managementGroups
   Name: Contoso
   ```

4. Asociá una suscripción a un grupo de administración. Una suscripción tiene **exactamente un** grupo de administración padre en todo momento; re-emparentarla es un movimiento, no una adición:

   ```bash
   az account management-group subscription add --name "mg-nonprod" --subscription "$SUB_ID"

   az account management-group show --name "mg-nonprod" --expand \
     --query "children[?type=='/subscriptions'].{Name:displayName, Id:name}" -o table
   ```

   ```text
   Name         Id
   -----------  ------------------------------------
   Lab-Sandbox  55555555-6666-7777-8888-999999999999
   ```

5. Ahora bajá hasta el fondo del árbol y leé los **IDs de recurso ARM** reales en cada ámbito. Memorizá estas cuatro formas — el examen evalúa razonamiento sobre ámbitos, y toda herramienta de Azure habla esta cadena:

   ```bash
   echo "MG   : /providers/Microsoft.Management/managementGroups/mg-prod"
   echo "SUB  : /subscriptions/$SUB_ID"
   echo "RG   : /subscriptions/$SUB_ID/resourceGroups/rg-az900-lab"
   echo "RES  : /subscriptions/$SUB_ID/resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stexample001"
   ```

   Cada segmento adicional es un nivel más abajo en la jerarquía lógica. Nada en estas cadenas codifica una región — la jerarquía física aparece únicamente en la **propiedad** `location` de un recurso, nunca en su ID.

6. Observá que una suscripción es también un **límite de escala**, no solo de facturación. Las cuotas se aplican por suscripción y por región:

   ```bash
   az vm list-usage --location eastus \
     --query "[?contains(localName,'Total Regional vCPUs') || contains(localName,'Standard DSv5 Family')].{Quota:localName, Used:currentValue, Limit:limit}" \
     -o table
   ```

   ```text
   Quota                             Used    Limit
   --------------------------------  ------  -------
   Total Regional vCPUs              8       50
   Standard DSv5 Family vCPUs        4       20
   ```

7. Limpiá los grupos de administración si los creaste (primero las hojas; un grupo de administración con hijos no puede eliminarse):

   ```bash
   az account management-group subscription remove --name "mg-nonprod" --subscription "$SUB_ID"
   az account management-group delete --name "mg-nonprod"
   az account management-group delete --name "mg-prod"
   az account management-group delete --name "mg-contoso"
   ```

> **Verificá tu comprensión — Bloque 4**
>
> **Q4.1** Asignás una Azure Policy que deniega la creación de recursos fuera de `europe` en `mg-contoso`. ¿Cuáles de los siguientes se ven afectados: `mg-prod`, `Lab-Sandbox`, un grupo de recursos dentro de `Lab-Sandbox`, una suscripción *distinta* emparentada directamente bajo el MG raíz?
> **Q4.2** ¿Puede una suscripción pertenecer tanto a `mg-prod` como a `mg-nonprod` para que apliquen las directivas de dos equipos? ¿Cuál es el mecanismo real para lograr gobernanza superpuesta?
> **Q4.3** De las cuatro formas de ID del paso 5, ¿cómo distinguís de un vistazo un ID de ámbito de suscripción de uno de ámbito de grupo de recursos?
> **Q4.4** Un desarrollador choca contra un muro de cuota de vCPU en `eastus`. Propone "crear otro grupo de recursos". ¿Por qué eso no ayuda, y cuáles son las dos cosas que sí funcionarían?
> **Q4.5** ¿Por qué la limpieza del paso 7 tuvo que quitar la suscripción y eliminar `mg-nonprod` antes que `mg-contoso`?

---

## Ejercicio 5 — Los grupos de recursos como límite de ciclo de vida y de radio de impacto

Un **grupo de recursos** es un contenedor lógico. Sus propiedades definitorias: un recurso pertenece a exactamente un RG; los grupos de recursos no se pueden anidar; eliminar un RG elimina todo lo que contiene; y el `location` propio del RG almacena solo los **metadatos** del grupo, no los datos de sus miembros.

1. Creá un grupo de recursos y etiquetalo. La creación es gratuita:

   ```bash
   export RG=rg-az900-lab

   az group create --name "$RG" --location eastus \
     --tags owner=student topic=az900-2.1 lifecycle=ephemeral \
     --query "{Name:name, Location:location, State:properties.provisioningState, Id:id}" -o yaml
   ```

   ```yaml
   Id: /subscriptions/55555555-6666-7777-8888-999999999999/resourceGroups/rg-az900-lab
   Location: eastus
   Name: rg-az900-lab
   State: Succeeded
   ```

2. Escribí una plantilla de despliegue que deliberadamente ubique dos recursos **en regiones distintas dentro de un mismo grupo de recursos**, usando dos estrategias de replicación distintas. Guardala como `main.bicep`:

   ```bicep
   targetScope = 'resourceGroup'

   @description('Region for the zone-redundant account. Must be an availability-zone-enabled region.')
   param primaryLocation string = 'eastus'

   @description('Region for the second account, deliberately different from the resource group location.')
   param secondaryLocation string = 'westus3'

   @description('Replication SKU for the primary account.')
   @allowed([
     'Standard_LRS'
     'Standard_ZRS'
     'Standard_GRS'
     'Standard_GZRS'
   ])
   param primarySku string = 'Standard_ZRS'

   var suffix = uniqueString(resourceGroup().id)

   resource zoneRedundant 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: 'stzr${suffix}'
     location: primaryLocation
     sku: {
       name: primarySku
     }
     kind: 'StorageV2'
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       publicNetworkAccess: 'Disabled'
     }
     tags: {
       topic: 'az900-2.1'
       pattern: 'zone-redundant'
     }
   }

   resource remoteRegion 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: 'stfar${suffix}'
     location: secondaryLocation
     sku: {
       name: 'Standard_LRS'
     }
     kind: 'StorageV2'
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       publicNetworkAccess: 'Disabled'
     }
     tags: {
       topic: 'az900-2.1'
       pattern: 'single-zone-remote-region'
     }
   }

   output resourceGroupLocation string = resourceGroup().location
   output zoneRedundantId string = zoneRedundant.id
   output zoneRedundantLocation string = zoneRedundant.location
   output remoteRegionId string = remoteRegion.id
   output remoteRegionLocation string = remoteRegion.location
   ```

   Si preferís no instalar Bicep, la plantilla ARM JSON equivalente es totalmente intercambiable — guardala como `main.json` y pasala al mismo comando:

   ```json
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {
       "primaryLocation":   { "type": "string", "defaultValue": "eastus" },
       "secondaryLocation": { "type": "string", "defaultValue": "westus3" },
       "primarySku": {
         "type": "string",
         "defaultValue": "Standard_ZRS",
         "allowedValues": ["Standard_LRS", "Standard_ZRS", "Standard_GRS", "Standard_GZRS"]
       }
     },
     "variables": {
       "suffix": "[uniqueString(resourceGroup().id)]"
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[concat('stzr', variables('suffix'))]",
         "location": "[parameters('primaryLocation')]",
         "sku": { "name": "[parameters('primarySku')]" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "publicNetworkAccess": "Disabled"
         },
         "tags": { "topic": "az900-2.1", "pattern": "zone-redundant" }
       },
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[concat('stfar', variables('suffix'))]",
         "location": "[parameters('secondaryLocation')]",
         "sku": { "name": "Standard_LRS" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "publicNetworkAccess": "Disabled"
         },
         "tags": { "topic": "az900-2.1", "pattern": "single-zone-remote-region" }
       }
     ],
     "outputs": {
       "resourceGroupLocation": { "type": "string", "value": "[resourceGroup().location]" },
       "zoneRedundantId":       { "type": "string", "value": "[resourceId('Microsoft.Storage/storageAccounts', concat('stzr', variables('suffix')))]" },
       "remoteRegionId":        { "type": "string", "value": "[resourceId('Microsoft.Storage/storageAccounts', concat('stfar', variables('suffix')))]" }
     }
   }
   ```

3. Previsualizá el despliegue antes de confirmarlo. `what-if` invoca el motor de predicción de ARM y no cambia nada:

   ```bash
   az deployment group what-if --resource-group "$RG" --template-file main.bicep
   ```

   ```text
   Resource and property changes are indicated with these symbols:
     + Create

   The deployment will update the following scope:

   Scope: /subscriptions/5555.../resourceGroups/rg-az900-lab

     + Microsoft.Storage/storageAccounts/stzrhq4k2mnp7xw3d [2023-05-01]
         kind:              "StorageV2"
         location:          "eastus"
         sku.name:          "Standard_ZRS"

     + Microsoft.Storage/storageAccounts/stfarhq4k2mnp7xw3d [2023-05-01]
         kind:              "StorageV2"
         location:          "westus3"
         sku.name:          "Standard_LRS"

   Resource changes: 2 to create.
   ```

4. Desplegá, después leé las salidas:

   ```bash
   az deployment group create --resource-group "$RG" --name dep-2-1 --template-file main.bicep \
     --query "properties.outputs.{RGLocation:resourceGroupLocation.value, ZR:zoneRedundantLocation.value, Remote:remoteRegionLocation.value}" -o yaml
   ```

   ```yaml
   RGLocation: eastus
   Remote: westus3
   ZR: eastus
   ```

5. Confirmá el desacoplamiento directamente — un grupo de recursos, dos regiones:

   ```bash
   az resource list --resource-group "$RG" \
     --query "[].{Name:name, Type:type, Location:location, SKU:sku.name}" -o table
   ```

   ```text
   Name                 Type                                 Location    SKU
   -------------------  -----------------------------------  ----------  -------------
   stzrhq4k2mnp7xw3d    Microsoft.Storage/storageAccounts     eastus      Standard_ZRS
   stfarhq4k2mnp7xw3d   Microsoft.Storage/storageAccounts     westus3     Standard_LRS
   ```

6. Demostrá el grupo de recursos como límite de **protección**. Aplicá un bloqueo `CanNotDelete` en el ámbito del RG; los bloqueos heredan a todos los hijos:

   ```bash
   az lock create --name "no-delete-lab" --resource-group "$RG" --lock-type CanNotDelete
   az lock list --resource-group "$RG" --query "[].{Name:name, Level:level, Scope:id}" -o table
   ```

   ```text
   Name           Level         Scope
   -------------  ------------  ------------------------------------------------------------
   no-delete-lab  CanNotDelete  /subscriptions/5555.../resourceGroups/rg-az900-lab/providers/Microsoft.Authorization/locks/no-delete-lab
   ```

7. Intentá eliminar un recurso *hijo* y leé el error exacto. Notá que es el bloqueo de **ámbito RG** el que detiene una operación de **ámbito de recurso**:

   ```bash
   ZR_NAME=$(az storage account list -g "$RG" --query "[?starts_with(name,'stzr')].name | [0]" -o tsv)
   az storage account delete --name "$ZR_NAME" --resource-group "$RG" --yes
   ```

   ```text
   (ScopeLocked) The scope '/subscriptions/5555.../resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stzrhq4k2mnp7xw3d'
   cannot perform delete operation because following scope(s) are locked: '/subscriptions/5555.../resourceGroups/rg-az900-lab'.
   Please remove the lock and try again.
   Code: ScopeLocked
   ```

8. Mové un recurso a un segundo grupo de recursos. Esto prueba que el RG es una *etiqueta*, no un contenedor físico — los datos de la cuenta de storage nunca se mueven y su región no cambia:

   ```bash
   az group create --name "rg-az900-lab-b" --location westeurope -o none
   az lock delete --name "no-delete-lab" --resource-group "$RG"

   REMOTE_ID=$(az storage account list -g "$RG" --query "[?starts_with(name,'stfar')].id | [0]" -o tsv)
   az resource move --destination-group "rg-az900-lab-b" --ids "$REMOTE_ID"

   az resource list --resource-group "rg-az900-lab-b" \
     --query "[].{Name:name, Location:location, RG:resourceGroup}" -o table
   ```

   ```text
   Name                 Location    RG
   -------------------  ----------  --------------
   stfarhq4k2mnp7xw3d   westus3     rg-az900-lab-b
   ```

   El recurso ahora está en un grupo de recursos cuyos metadatos viven en `westeurope`, mientras que la cuenta de storage en sí sigue estando en `westus3`. Su ID de ARM cambió; sus datos no se movieron ni un solo byte.

9. **Limpieza.** Eliminar el grupo de recursos elimina todo lo que contiene — este es el radio de impacto que diseñaste:

   ```bash
   az group delete --name "$RG" --yes --no-wait
   az group delete --name "rg-az900-lab-b" --yes --no-wait
   az group list --query "[?starts_with(name,'rg-az900-lab')].{Name:name, State:properties.provisioningState}" -o table
   ```

   ```text
   Name             State
   ---------------  ----------
   rg-az900-lab     Deleting
   rg-az900-lab-b   Deleting
   ```

> **Verificá tu comprensión — Bloque 5**
>
> **Q5.1** En el paso 4 el grupo de recursos está en `eastus` y una cuenta de storage está en `westus3`. Si toda la región `eastus` queda fuera de servicio, ¿están disponibles los *datos* de la cuenta de storage en `westus3`? ¿Es *administrable* a través de ARM?
> **Q5.2** El bloqueo del paso 6 se puso sobre el grupo de recursos, pero el error del paso 7 se lanzó para una operación sobre una cuenta de storage. ¿Qué propiedad de la jerarquía lógica explica esto?
> **Q5.3** Después del movimiento del paso 8, dos cosas del recurso cambiaron y una cosa importante no. Nombrá las tres.
> **Q5.4** Un equipo pide "un grupo de recursos por entorno, anidado bajo un grupo de recursos por unidad de negocio". ¿Qué está técnicamente mal en el pedido, y qué construcción provee realmente el anidamiento que quieren?
> **Q5.5** ¿Por qué `az group delete` no requiere confirmación del *contenido*, y qué regla de diseño impone eso sobre cómo agrupás recursos en primer lugar?

---

## Ejercicio 6 — Diagnosticar fallas de ubicación en ambas jerarquías

La mayoría de los tickets reales de "Azure está roto" sobre este tema son uno de cuatro errores del plano de control, cada uno rastreable a un nivel específico de una de las dos jerarquías.

1. **Proveedor de recursos no registrado** — a la suscripción nunca se le informó sobre un espacio de nombres de servicio. Síntoma: `MissingSubscriptionRegistration`:

   ```bash
   az provider list --query "[?registrationState=='NotRegistered'].namespace" -o tsv | head -5
   az provider show --namespace Microsoft.ContainerService --query "{NS:namespace, State:registrationState}" -o yaml
   ```

   ```yaml
   NS: Microsoft.ContainerService
   State: NotRegistered
   ```

   ```bash
   az provider register --namespace Microsoft.ContainerService --wait
   az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv
   ```

   ```text
   Registered
   ```

   El registro es **por suscripción**, no por grupo de recursos ni por región.

2. **Tipo de recurso no ofrecido en la región** — síntoma: `LocationNotAvailableForResourceType`. Consultá la propia lista de regiones del proveedor antes de desplegar:

   ```bash
   az provider show --namespace Microsoft.Storage \
     --query "resourceTypes[?resourceType=='storageAccounts'].locations[]" -o tsv | head -6
   ```

   ```text
   East US
   East US 2
   West US 3
   North Europe
   West Europe
   Japan East
   ```

3. **SKU restringido para tu suscripción** — síntoma: `SkuNotAvailable`. El SKU existe en la región pero tu suscripción no tiene derecho a él, o está restringido por capacidad en zonas específicas:

   ```bash
   az vm list-skus --location eastus --resource-type virtualMachines \
     --query "[?restrictions[0]].{SKU:name, Reason:restrictions[0].reasonCode, Type:restrictions[0].type, Zones:restrictions[0].restrictionInfo.zones}" \
     -o table | head -6
   ```

   ```text
   SKU                 Reason                        Type      Zones
   ------------------  ----------------------------  --------  -------
   Standard_M128ms     NotAvailableForSubscription   Location
   Standard_NC24ads_A100_v4  NotAvailableForSubscription  Zone   ['1', '2']
   Standard_HB120rs_v3 NotAvailableForSubscription   Location
   ```

   Leé `type` con atención: `Location` significa que el SKU no está disponible para vos en toda la región; `Zone` significa que está disponible pero solo en las zonas que **no** figuran bajo `restrictionInfo.zones`.

4. **Capacidad zonal agotada** — síntoma: `ZonalAllocationFailed` en el momento del despliegue, no en el de la validación. Este no se puede consultar por adelantado; la capacidad es una condición de tiempo de ejecución. Las mitigaciones, en orden de preferencia: reintentar en una zona lógica distinta, relajar la familia de SKU, o quitar la fijación de zona y dejar que la plataforma ubique la instancia a nivel regional.

5. Confirmá la cuota a nivel de suscripción antes de culpar a la capacidad — el agotamiento de cuota produce `QuotaExceeded`, que es un problema de *suscripción*, mientras que `ZonalAllocationFailed` es un problema de *datacenter*:

   ```bash
   az vm list-usage --location eastus --query "[?currentValue >= limit].{Quota:localName, Used:currentValue, Limit:limit}" -o table
   ```

   ```text
   Quota                       Used    Limit
   --------------------------  ------  -------
   Standard NCADSA100v4 Family 0       0
   ```

   Un límite de `0` significa que la familia nunca fue aprobada para esta suscripción — ninguna cantidad de reintentos va a ayudar; requiere una solicitud de aumento de cuota.

> **Verificá tu comprensión — Bloque 6**
>
> **Q6.1** Para cada uno de `MissingSubscriptionRegistration`, `LocationNotAvailableForResourceType`, `SkuNotAvailable` y `ZonalAllocationFailed`, nombrá la jerarquía (física o lógica) y el nivel exacto en el que vive el problema.
> **Q6.2** Registrás `Microsoft.ContainerService` en la suscripción A. ¿La suscripción B, en el mismo tenant y bajo el mismo grupo de administración, lo tiene ahora registrado? ¿Por qué sí o por qué no?
> **Q6.3** Un despliegue que venía funcionando a diario durante un año de repente falla con `ZonalAllocationFailed`. Nada cambió en tu plantilla. ¿Qué cambió, y cuál de las cuatro mitigaciones del paso 4 es la más rápida?
> **Q6.4** En el paso 3, `Standard_NC24ads_A100_v4` muestra `type: Zone` con `zones: ['1','2']`. ¿En qué zona lógica podés desplegarlo, y por qué esa respuesta solo es válida para *tu* suscripción?

---

## Ejercicio 7 — Integrador: razonamiento sobre ámbitos a partir de un ID de ARM crudo (sin despliegue)

Leé con atención la siguiente descripción de estado. Respondé solo a partir de las cadenas de ID y los metadatos.

```text
Tenant:            aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  ("Contoso")
Management groups: Tenant Root Group
                     └── mg-contoso
                           ├── mg-prod      [Policy: deny locations outside {westeurope, northeurope}]
                           └── mg-nonprod

Subscriptions:     sub-prod    (11111111-...)  parent = mg-prod
                   sub-sandbox (22222222-...)  parent = mg-nonprod

Resources:
  R1  /subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Storage/storageAccounts/stpay001
      location = westeurope     sku = Standard_GZRS
  R2  /subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Compute/virtualMachines/vm-api-01
      location = westeurope     zones = ["1"]
  R3  /subscriptions/22222222-.../resourceGroups/rg-scratch/providers/Microsoft.Storage/storageAccounts/stscratch9
      location = eastus         sku = Standard_LRS

  rg-payments  location = northeurope
  rg-scratch   location = eastus
```

> **Verificá tu comprensión — Bloque 7**
>
> **Q7.1** ¿Qué recursos gobierna la directiva de `mg-prod`? Indicá explícitamente si R3 se ve afectado y por qué.
> **Q7.2** `rg-payments` tiene `location = northeurope` pero sus dos recursos están en `westeurope`. ¿Es esto una violación de la directiva? ¿Qué se almacena exactamente en `northeurope`?
> **Q7.3** Un operador ejecuta `az group delete --name rg-payments`. Listá cada recurso destruido, e indicá si la eliminación cruza un límite de suscripción.
> **Q7.4** La zona de disponibilidad 1 en `westeurope` sufre una pérdida total de energía. ¿Cuál es el estado de R1 y el de R2?
> **Q7.5** Se pierde toda la región `westeurope`. R1 es `Standard_GZRS`. ¿Dónde está la copia sobreviviente, quién decide esa ubicación, y cuál es el modelo de acceso a ella hasta que Microsoft inicie una conmutación por error?
> **Q7.6** Finanzas pregunta: "Dividí la factura entre el equipo de pagos y el equipo de sandbox". ¿Qué nivel de la jerarquía lógica ya hace esto, y qué usarías si ambos equipos compartieran una única suscripción?
> **Q7.7** Escribí el ID de ARM del contenedor de blobs `invoices` dentro de `stpay001`. ¿Qué te dice el segmento de ruta adicional sobre cómo ARM modela los recursos hijos?

---

<details>
<summary><strong>Respuestas</strong> — clic para expandir</summary>

### Bloque 0

**A0.1** Porque "el tenant" es un límite de **identidad** (Entra ID), no un ámbito de autorización para recursos de Azure. Los roles de Azure RBAC se asignan en el ámbito de grupo de administración, suscripción, grupo de recursos o recurso — el directorio de Entra en sí no es ninguno de esos. Ser miembro del tenant, o incluso Administrador Global en él, no otorga ningún permiso sobre recursos de Azure hasta que se asigne un rol RBAC en un ámbito de Azure o hasta que un Administrador Global eleve explícitamente el acceso al grupo de administración raíz.

**A0.2** `id` (el ID de suscripción) es el límite de **facturación** — todo recurso bajo él se consolida en una factura y un conjunto de cuotas. `tenantId` es el límite de **identidad** — el directorio de Entra ID que autentica a las entidades de seguridad. Muchas suscripciones pueden confiar en un tenant; una suscripción confía en exactamente un tenant a la vez.

**A0.3** Sería `core.usgovcloudapi.net`. La diferencia significa que Azure Government es una *instancia de nube separada*, no una región de la nube pública: endpoint de ARM separado, Entra ID separado, espacio de nombres DNS separado. No hay conectividad implícita, ni identidad compartida, ni gestión de recursos entre nubes — una integración entre ellas es una integración de internet corriente entre dos nubes independientes.

### Bloque 1

**A1.1** No, por sí solo no alcanza. `westeurope` (Países Bajos) mantiene los datos *primarios* en la UE, pero GRS/RA-GRS/GZRS replican asincrónicamente a la **región emparejada**, que vos no elegís. Para `westeurope` el par es `northeurope` (Irlanda) — todavía en la UE, así que este caso particular está bien. El punto es que la garantía viene de *verificar el par*, no de elegir la primaria. Usá LRS/ZRS si necesitás eliminar por completo la replicación entre regiones, o verificá que el par esté dentro de tu geografía de cumplimiento antes de habilitar GRS.

**A1.2** Los pares de regiones normalmente están dentro de la misma **geografía**, así que la región emparejada satisface el mismo régimen de residencia de datos. `brazilsouth` es la excepción documentada: se empareja con `southcentralus` (Texas), que es una geografía distinta y una jurisdicción legal distinta. Habilitar GRS en `brazilsouth` mueve, por lo tanto, una réplica de datos brasileños a los Estados Unidos. `northeurope → westeurope` se queda dentro de la geografía Europa, así que no ocurre ningún cambio jurisdiccional. Notá además que el emparejamiento de Brasil es unidireccional: `southcentralus` se empareja de vuelta con `northcentralus`, no con Brasil.

**A1.3** De la salida del paso 5: `israelcentral`, `italynorth`, `polandcentral`, `qatarcentral` (dos cualesquiera). Son geografías de una sola región sin par asignado por la plataforma. En su lugar tenés que (a) usar **zonas de disponibilidad** para resiliencia a nivel de datacenter dentro de la región, y (b) elegir y configurar explícitamente tu propia región secundaria para DR usando herramientas gestionadas por el cliente — Azure Site Recovery, replicación de objetos, replicación a nivel de aplicación — aceptando que la secundaria puede estar en una geografía distinta y que Microsoft no da ninguna garantía de priorización de recuperación ahí.

**A1.4** Dos de: los servicios nuevos de Azure llegan más tarde o nunca; puede que no haya zonas de disponibilidad, con lo cual los SKU redundantes por zonas (ZRS, SQL redundante por zonas, VMs zonales) no están disponibles; la capacidad para SKU grandes o especializados (GPU, HPC, alta memoria) es más escasa, lo que eleva la tasa de `SkuNotAvailable` y de fallas de asignación; se ofrecen menos familias de SKU en general; y puede no ser un destino de par válido para la garantía de residencia que necesitás.

**A1.5** Porque Entra ID es un servicio **no regional** (`global`). No tiene una región única — Microsoft lo opera como un servicio distribuido globalmente en varias geografías y gestiona su propia replicación y conmutación por error. La jerarquía física (geografía → región → zona → datacenter) simplemente no le aplica, y por eso tampoco podés "conmutar Entra ID por error" ni fijarlo a una región con fines de residencia.

### Bloque 2

**A2.1** No. `az account list-locations` en `AzureCloud` devuelve un array vacío para `usgovvirginia` — la instancia de ARM de la nube pública no tiene conocimiento alguno de las regiones de Government. Están servidas por un endpoint de ARM completamente distinto (`management.usgovcloudapi.net`) respaldado por un proveedor de identidad distinto. Crear un recurso ahí requiere una suscripción de Government, un tenant de Entra de Government, y `az cloud set --name AzureUSGovernment`.

**A2.2** **21Vianet** (Beijing 21Vianet Broad Band Data Center Co., Ltd.), no Microsoft, opera Azure en China. Microsoft les licencia la tecnología. Para un runbook esto significa que los tickets de soporte, los SLA, las comunicaciones de incidentes y la facturación pasan todos por los canales de 21Vianet; el soporte global de Microsoft no puede ver ni actuar sobre esos recursos, y los ingenieros de Microsoft no tienen acceso operativo a los datacenters.

**A2.3** Una suscripción confía en exactamente un tenant de Entra, y Azure Government tiene su **propia instancia separada** de Entra ID, con sus propios IDs de tenant y su propio endpoint de login (`login.microsoftonline.us`). Una suscripción de Government no puede asociarse a un tenant de la nube pública. Lograr una experiencia de identidad unificada requiere un segundo directorio en Government más un mecanismo explícito de sincronización o federación entre ambos — es un proyecto de integración entre nubes, no un interruptor de configuración.

**A2.4** Falla la resolución DNS: `core.windows.net` no existe en el espacio de nombres de la nube de Government, así que la aplicación no puede alcanzar su cuenta de storage. La solución es el sufijo `Storage` del paso 2 — `core.usgovcloudapi.net` — y la práctica de ingeniería correcta es nunca hardcodear el sufijo sino leerlo de los metadatos del entorno de nube en tiempo de ejecución (la CLI, todos los SDK y el servicio de metadatos de instancia lo exponen).

### Bloque 3

**A3.1** Qué está mal: los números de zona son **etiquetas lógicas por suscripción**, y el paso 3 muestra que las dos suscripciones mapean el `1` a zonas físicas distintas (`eastus-az1` vs `eastus-az3`). Por lo tanto "ambas en la zona 1" **no** significa "ambas en el mismo datacenter", así que cualquier razonamiento basado en la co-ubicación — como suponer baja latencia intra-zona entre ellas — es inválido. Qué está accidentalmente bien: precisamente porque los mapeos difieren, las dos VMs terminan en zonas físicas *distintas*, así que sí tienen aislamiento real de fallas a nivel de zona. La configuración es accidentalmente resiliente y deliberadamente irrazonada, que es el peor tipo de arquitectura — el mapeo es de Microsoft y puede cambiarlo.

**A3.2** No. Una VM única fijada a una zona es **zonal**, no redundante por zonas: si esa zona falla, la VM desaparece. El cambio mínimo es desplegar **al menos dos instancias más en las otras dos zonas lógicas** y ponerlas detrás de un Standard Load Balancer redundante por zonas (con la capa de datos en ZRS o en una base de datos redundante por zonas). La redundancia es una propiedad del conjunto desplegado, nunca de una instancia zonal única.

**A3.3** Orden ascendente de falla sobrevivida:
1. `Standard_LRS` — tres copias dentro de un **único datacenter/zona**. Sobrevive fallas de disco, rack y nodo. Se detiene en el límite de la zona.
2. `Standard_ZRS` — tres copias distribuidas en **tres zonas de disponibilidad** de una región. Sobrevive la pérdida de un datacenter/zona completo. Se detiene en el límite de la región.
3. `Standard_GRS` — LRS localmente más una copia asincrónica en la **región emparejada**. Sobrevive la pérdida de la región entera. Se detiene en el límite de la geografía (y, como es LRS en cada extremo, *no* sobrevive una falla de zona sin una conmutación regional completa — para eso está GZRS).

**A3.4** La conclusión correcta es que **el soporte de zonas es por SKU, no solo por región**: esta región tiene zonas, pero este SKU en particular no se ofrece de forma zonal ahí (algo frecuente en familias especializadas de GPU/HPC/alta memoria). Tus dos opciones: (a) elegir otra familia de SKU que sí liste zonas en esa región, o (b) elegir otra región donde el SKU se ofrezca de forma zonal. Una tercera, que no es solución, es desplegarlo a nivel regional sin fijación de zona — pero eso no te compra ninguna resiliencia de zona y tenés que decirlo explícitamente en lugar de pretender lo contrario.

**A3.5** No sobreviven ni el primero ni el tercero; solo la cuenta GRS.
- ZRS en `westeurope` — **perdida**. ZRS protege contra falla de zona *dentro* de una región; la pérdida de la región entera se lleva las tres zonas.
- GRS en `westeurope` — **sobrevive**, como réplica asincrónica en la región emparejada `northeurope`. Notá que "sobrevive" significa que el dato existe ahí; no es legible hasta que Microsoft inicie una conmutación por error, salvo que el SKU sea RA-GRS.
- Conjunto de VMs en las zonas 1/2/3 de `westeurope` — **perdido**. La distribución zonal es resiliencia solo dentro de la región.

### Bloque 4

**A4.1** Afectados: `mg-prod` (grupo de administración hijo), `Lab-Sandbox` (está emparentado bajo `mg-nonprod`, que es hijo de `mg-contoso`), y el grupo de recursos dentro de `Lab-Sandbox` — más todos los recursos que contiene. Las asignaciones de directivas y RBAC heredan **hacia abajo por todo el subárbol**. No afectada: la suscripción emparentada directamente bajo el grupo de administración raíz, porque es hermana de `mg-contoso`, no descendiente. La herencia fluye solo hacia abajo, nunca de costado ni hacia arriba.

**A4.2** No. Una suscripción tiene **exactamente un** grupo de administración padre. Para obtener gobernanza superpuesta asignás directivas en **distintos niveles de la misma rama** — por ejemplo una directiva base en `mg-contoso` que heredan todos los descendientes, más una directiva más estricta en `mg-prod`. Los efectos se componen a lo largo de la cadena de ancestros: un `Deny` en cualquier nivel de la cadena gana.

**A4.3** Contá los segmentos. Un ID de ámbito de suscripción es exactamente `/subscriptions/{guid}` y ahí termina. Un ID de ámbito de grupo de recursos agrega `/resourceGroups/{name}`. Un ID de ámbito de recurso agrega `/providers/{namespace}/{type}/{name}` encima de eso. La presencia del segmento `/providers/` es el marcador confiable de que estás en ámbito de recurso y no en un ámbito contenedor. Los IDs de grupo de administración se distinguen porque **no** tienen segmento `/subscriptions/` en absoluto — empiezan con `/providers/Microsoft.Management/managementGroups/`.

**A4.4** No ayuda porque las cuotas se aplican **por suscripción y por región**, y un grupo de recursos es una etiqueta de metadatos sin cuota propia — cada grupo de recursos de la suscripción consume del mismo pool de vCPU. Las dos cosas que sí funcionan: (a) solicitar un aumento de cuota para esa familia/región en esa suscripción, o (b) desplegar en una **suscripción distinta**, o en una **región distinta** dentro de la misma suscripción, ya que cada combinación tiene un pool de cuota independiente.

**A4.5** Porque un grupo de administración no puede eliminarse mientras todavía tenga hijos — y tanto las suscripciones como los grupos de administración hijos cuentan como hijos. `mg-nonprod` contenía la suscripción, así que la suscripción tuvo que desasociarse primero; `mg-contoso` contenía a `mg-prod` y `mg-nonprod`, así que ambos tuvieron que irse primero. La eliminación procede desde las hojas hacia arriba en el árbol. (Esto es también lo opuesto a la eliminación de grupos de recursos, que cascadea — las dos jerarquías tienen semánticas de destrucción deliberadamente distintas.)

### Bloque 5

**A5.1** Los **datos** en `westus3` no se ven afectados — los bytes de la cuenta de storage viven en `westus3` y no tienen dependencia de `eastus`. La ubicación del grupo de recursos solo determina dónde ARM almacena los **metadatos** de ese grupo. La administrabilidad es la respuesta más sutil: el plano de control de ARM es un servicio distribuido globalmente con su propia redundancia, y los metadatos de un grupo de recursos se replican más allá de su ubicación declarada, así que las operaciones de gestión generalmente continúan. La regla de diseño que busca el examen: **la ubicación del grupo de recursos afecta al almacenamiento de metadatos y de metadatos de despliegue, nunca a dónde se ejecutan los recursos ni a dónde viven sus datos.**

**A5.2** **La herencia.** Los bloqueos, igual que las asignaciones de roles RBAC y las asignaciones de Azure Policy, aplican en su ámbito *y en todos los ámbitos descendientes*. Un bloqueo `CanNotDelete` en el ámbito de grupo de recursos bloquea por lo tanto las operaciones de eliminación sobre todos los recursos de ese grupo. Es la misma herencia unidireccional hacia abajo vista en el ámbito de grupo de administración en el ejercicio 4; el grupo de recursos es simplemente el nivel contenedor más bajo en el que podés aplicarla.

**A5.3** Cambiaron: (1) su **ID de recurso ARM**, ya que el ID incorpora el nombre del grupo de recursos — toda referencia, asignación RBAC con ámbito en la ruta vieja, script y automatización que use el ID viejo ahora apunta a nada; (2) su **contexto de gobernanza** — ahora hereda las etiquetas, bloqueos, directivas y RBAC de `rg-az900-lab-b`. Sin cambiar: su **ubicación física** — sigue siendo `westus3`. No se movió ni un byte de datos, y los endpoints de la cuenta son idénticos. Ese es justamente el punto: el grupo de recursos es una etiqueta de la jerarquía lógica sin incidencia alguna sobre la física.

**A5.4** Los grupos de recursos **no se pueden anidar** — no hay relación padre-hijo entre ellos, y un recurso pertenece a exactamente uno. La construcción que provee la jerarquía que quieren es el **grupo de administración**, que sí anida (hasta seis niveles por debajo de la raíz, sin contar la raíz ni el nivel de suscripción) y bajo el cual se emparentan las suscripciones. La forma idiomática es: grupo de administración por unidad de negocio → grupo de administración hijo o suscripción por entorno → grupos de recursos por ciclo de vida de aplicación dentro de él.

**A5.5** Porque el grupo de recursos **es** la unidad de ciclo de vida: el contrato de ARM es que todo lo que está en un grupo comparte destino, así que eliminar el grupo es una operación única, intencional, de todo o nada. La regla de diseño que esto impone: **agrupá los recursos por lo que borrarías junto**, no por lo que tienen en común conceptualmente. Una base de datos compartida ubicada en el mismo grupo de recursos que una aplicación de prueba efímera será destruida cuando esa aplicación se desmantele. Cuando no podés reestructurar, los bloqueos `CanNotDelete` son el control compensatorio.

### Bloque 6

**A6.1**
- `MissingSubscriptionRegistration` — **lógica**, nivel de **suscripción**. El espacio de nombres del proveedor de recursos no está registrado en esa suscripción.
- `LocationNotAvailableForResourceType` — **física**, nivel de **región**. El servicio no se ofrece en esa región en absoluto.
- `SkuNotAvailable` — la intersección: el SKU existe en la región (física) pero tu **suscripción** (lógica) no tiene derecho a él, o está restringido a un subconjunto de zonas (física).
- `ZonalAllocationFailed` — **física**, nivel de **zona de disponibilidad / datacenter**. La capacidad real en esa zona específica está agotada en este momento.

**A6.2** No. El registro de proveedores de recursos es una configuración **por suscripción**, almacenada en el objeto de suscripción. No se hereda de un grupo de administración ni se comparte entre suscripciones de un tenant. La suscripción B tiene que ejecutar su propio `az provider register`. (Azure registra automáticamente muchos proveedores en el primer uso a través del portal, y por eso esta falla aparece tan a menudo solo en despliegues automatizados o de CI.)

**A6.3** Lo que cambió es la **capacidad de Microsoft en esa zona física** — la demanda de otros clientes, o hardware retirado por mantenimiento. Nada cambió de tu lado; la asignación es una condición de tiempo de ejecución evaluada en el momento del despliegue y no se puede consultar por adelantado. La mitigación más rápida es **reintentar en una zona lógica distinta** (`--zone 2` o `3`) — es un cambio de una sola bandera y preserva tu postura de resiliencia zonal. Si eso también falla, relajá la familia de SKU, y como último recurso quitá la fijación de zona y aceptá la ubicación regional, documentando la pérdida de garantías zonales.

**A6.4** La zona **3**. `restrictionInfo.zones` lista las zonas donde el SKU está **restringido**, así que el resto no restringido de `{1,2,3}` es el conjunto desplegable. La respuesta es específica de la suscripción por dos razones: la restricción en sí tiene ámbito en tu suscripción (`reasonCode: NotAvailableForSubscription`), y — más fundamentalmente — los números de zona lógica se mapean a zonas físicas por suscripción, así que "zona 3" acá nombra un datacenter físico que otra suscripción alcanza con un número distinto.

### Bloque 7

**A7.1** `mg-prod` gobierna `sub-prod` y todo lo que está debajo: `rg-payments`, R1 y R2. **R3 no se ve afectado**, porque vive en `sub-sandbox`, que está emparentada bajo `mg-nonprod` — un **hermano** de `mg-prod`, no un descendiente. La herencia fluye estrictamente hacia abajo por la cadena de ancestros; una directiva en `mg-prod` nunca alcanza a `mg-nonprod`. Por eso R3 puede estar en `eastus` a pesar de la regla "solo UE".

**A7.2** No es una violación. El `location` del grupo de recursos almacena solo los **metadatos** de ese grupo — su registro en ARM y su historial de despliegues. La directiva `deny locations outside {westeurope, northeurope}` se cumple con las ubicaciones de ambos recursos (`westeurope`), y `northeurope` sería un valor permitido de todos modos. Ningún dato de cliente de R1 o R2 reside en `northeurope` por virtud de la ubicación del grupo; los blobs de la cuenta de storage están en `westeurope`, y el cómputo y los discos administrados de la VM están en `westeurope`.

**A7.3** Destruidos: **R1** (`stpay001`) y **R2** (`vm-api-01`), más todos los recursos hijos creados implícitamente para ellos — la NIC de la VM, sus discos administrados de sistema operativo y de datos, cualquier IP pública zonal, y todos los contenedores de blobs y sus contenidos en `stpay001`. Eliminar un grupo de recursos cascadea a todo su contenido incondicionalmente. **No** cruza un límite de suscripción: un grupo de recursos pertenece a exactamente una suscripción, así que `sub-sandbox`, `rg-scratch` y R3 quedan intactos.

**A7.4** **R1 sobrevive.** Es `Standard_GZRS`, cuyo componente local es ZRS — tres copias distribuidas en las tres zonas de `westeurope` — así que la pérdida de una zona es transparente y la cuenta permanece en línea y escribible. **R2 está caída.** Es una VM zonal fijada a `zones: ["1"]` sin pares en las otras zonas, así que su cómputo y sus discos administrados locales a la zona desaparecen hasta que la zona se restablezca. R2 es un ejemplo de manual de despliegue de zona única confundido con uno resiliente.

**A7.5** La copia sobreviviente está en `northeurope`, la **región emparejada** de `westeurope`. **Microsoft decide esa ubicación**, no vos — los pares los fija la plataforma y no se pueden elegir ni cambiar. Hasta la conmutación por error, la copia secundaria **no es accesible**: la replicación de `Standard_GZRS` es asincrónica y el endpoint secundario no es legible. De ahí se siguen dos consecuencias. Primero, se requiere una **conmutación por error de cuenta** iniciada por el cliente o por Microsoft para promoverla, y como la replicación es asincrónica, se pierde toda escritura que no se hubiera replicado al momento de la interrupción (la brecha es medible mediante el *last sync time* de la cuenta). Segundo, si necesitabas acceso de lectura a la secundaria sin conmutación, el SKU correcto habría sido `Standard_RA-GZRS`.

**A7.6** La **suscripción** es el límite de facturación y ya divide los costos de los dos equipos: `sub-prod` y `sub-sandbox` producen consolidaciones de costo separadas, y cada una lleva sus propias cuotas. Si ambos equipos compartieran una sola suscripción, el mecanismo serían las **etiquetas de recursos** (por ejemplo `costCenter=payments`) combinadas con la agrupación y los presupuestos de Cost Management, reforzadas opcionalmente por una Azure Policy que exija la etiqueta en el momento de la creación. Los grupos de recursos también sirven como dimensión gruesa de agrupación en Cost Management, pero las etiquetas son la respuesta duradera porque sobreviven al movimiento de un recurso entre grupos.

**A7.7**

```text
/subscriptions/11111111-.../resourceGroups/rg-payments/providers/Microsoft.Storage/storageAccounts/stpay001/blobServices/default/containers/invoices
```

Los segmentos adicionales `blobServices/default/containers/invoices` muestran que ARM modela los **recursos hijos como una extensión de la ruta del ID del padre**, no como objetos independientes. De ahí se siguen tres consecuencias: el ámbito del hijo está estrictamente anidado dentro del del padre, así que el RBAC y los bloqueos asignados a `stpay001` heredan al contenedor; el hijo no puede existir sin el padre y se destruye con él; y el hijo no tiene un `location` independiente — está físicamente donde esté `stpay001` (`westeurope`). El segmento `default` es un sub-recurso singleton, un patrón que ARM usa cada vez que un padre tiene exactamente una instancia de una capa de servicio.

</details>

---

## Fuentes

- Guía de estudio AZ-900 — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Descripción general de regiones y geografías de Azure — <https://learn.microsoft.com/en-us/azure/reliability/regions-overview>
- Pares de regiones de Azure y regiones sin par — <https://learn.microsoft.com/en-us/azure/reliability/regions-paired>
- Descripción general de zonas de disponibilidad — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Soporte de zonas de disponibilidad por región — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support>
- Descripción general de Azure Resource Manager — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview>
- Administrar grupos de recursos con la CLI de Azure — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli>
- Mover recursos a un nuevo grupo de recursos o suscripción — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-resource-group-and-subscription>
- Bloquear recursos para prevenir cambios — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources>
- Descripción general de los grupos de administración — <https://learn.microsoft.com/en-us/azure/governance/management-groups/overview>
- Límites de suscripción y de servicio de Azure — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits>
- Redundancia de Azure Storage — <https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy>
- Subscriptions – List Locations (REST) — <https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/list-locations>
- Documentación de Azure Government — <https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-welcome>
- Azure operada por 21Vianet — <https://learn.microsoft.com/en-us/azure/china/>