# AZ-900 — Tema 3.1: Describir la gestión de costos en Azure
## Ejercicios Guiados

> **Peso en el examen:** 8.33 % · **Versión del examen:** 2026-07-20
> **Habilidades oficiales evaluadas:** [Guía de estudio AZ-900](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
> — factores que afectan el costo · Pricing calculator vs. TCO Calculator · capacidades de Microsoft Cost Management · el propósito de las etiquetas

---

### Cómo usar este documento

Cada bloque es una secuencia de comandos que ejecutás de verdad, seguida de **preguntas de verificación**. Las respuestas están colapsadas al final. No las leas primero — el valor de este tema está en ver los medidores, no en memorizar una definición de "presupuesto".

**Advertencia de costo.** Los bloques 1–3 y 8 no cuestan **nada** (APIs públicas de precios, sin autenticación). Los bloques 4–7 crean recursos facturables. Si los destruís dentro de la hora el total son unos centavos, pero **el bloque 9 no es opcional** — una IPv4 pública Standard huérfana y un disco administrado de 30 GiB facturan calladamente ~$6/mes para siempre.

**Requisitos previos**

```bash
az version --query '"azure-cli"' -o tsv     # >= 2.60.0
jq --version                                 # jq-1.6 or later
curl --version | head -1
az login
az account show --query '{sub:id, name:name, tenant:tenantId}' -o yaml
```

Permisos requeridos: **Contributor** sobre una suscripción (para crear recursos y una asignación de directiva) más **Cost Management Reader** o superior sobre la suscripción/ámbito de facturación. Las suscripciones Free Trial y Azure for Students pueden leer Cost Analysis y crear presupuestos, pero no pueden crear *reservas* — el bloque 8 es de solo lectura por diseño, así que funciona con cualquier oferta.

Exportá los identificadores una vez; todos los bloques posteriores los reutilizan:

```bash
export SUB_ID=$(az account show --query id -o tsv)
export RG=rg-az900-cost-lab
export LOC=eastus
export ALERT_EMAIL="you@example.com"     # replace
echo "$SUB_ID / $RG / $LOC"
```

---

## Bloque 1 — Leé el precio *antes* de desplegar: la API de Precios Minoristas de Azure

La Pricing Calculator es una interfaz sobre el mismo catálogo que usa el motor de facturación. La forma legible por máquina de ese catálogo es la **Azure Retail Prices API** — anónima, sin autenticación, sin suscripción requerida. Aprender a consultarla es lo que separa "creo que una D2s v5 sale como diez centavos" de un número auditable.

1. Consultá el precio de consumo de un SKU de VM en una región:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "currencyCode='USD'" \
  --data-urlencode "\$filter=serviceName eq 'Virtual Machines' \
      and armRegionName eq 'eastus' \
      and armSkuName eq 'Standard_D2s_v5' \
      and priceType eq 'Consumption'" \
  | jq '{Count, Items: [.Items[] | {meterName, productName, retailPrice, unitOfMeasure, type}]}'
```

Salida ilustrativa (**los precios cambian — el tuyo va a diferir**):

```json
{
  "Count": 4,
  "Items": [
    { "meterName": "D2s v5",      "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.096,  "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5 Spot", "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.0106, "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5 Low Priority", "productName": "Virtual Machines Dv5 Series",
      "retailPrice": 0.0192, "unitOfMeasure": "1 Hour", "type": "Consumption" },
    { "meterName": "D2s v5",      "productName": "Virtual Machines Dv5 Series Windows",
      "retailPrice": 0.188,  "unitOfMeasure": "1 Hour", "type": "Consumption" }
  ]
}
```

2. Inspeccioná la forma completa de un solo ítem — estos nombres de campo son exactamente los que vas a ver después en Cost Analysis y en el CSV de uso:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and priceType eq 'Consumption' and contains(productName, 'Windows') eq false" \
  | jq '.Items[0]'
```

Campos clave: `meterId` (la primitiva de facturación), `meterName`, `productName`, `skuName`, `armSkuName`, `serviceFamily`, `unitOfMeasure`, `retailPrice`, `unitPrice`, `tierMinimumUnits`, `effectiveStartDate`, `type`, `reservationTerm`.

3. Convertí un medidor por hora a una cifra mensual del modo en que lo hace la Pricing Calculator — **730 horas** (365 × 24 ÷ 12):

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | select(.productName | test("Windows") | not)
           | "\(.productName): $\(.retailPrice)/h  →  $\(.retailPrice * 730 | .*100 | round / 100)/month"'
```

4. Ahora abrí la [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/), agregá **Virtual Machines**, elegí *East US / Linux / D2s v5 / Pay as you go / 730 horas*, y compará la cifra mensual con la que acabás de calcular.

> ⚠️ **Verificá tu comprensión**
>
> **Q1.** La consulta del paso 1 devolvió cuatro filas para un *único* `armSkuName`. ¿Cuáles son esas cuatro filas, y qué te dice eso sobre la relación entre "un tamaño de VM" y "un medidor de facturación"?
> **Q2.** `Standard_D2s_v5` Linux y `Standard_D2s_v5` Windows difieren en aproximadamente $0.092/hora. ¿Qué es ese delta, y qué programa de Azure te permite eliminarlo?
> **Q3.** La API no necesitó `az login`, ni suscripción, ni clave de API. ¿Qué te dice eso sobre *de quién* son esos precios, y en qué situación los números **no** coincidirían con tu factura?
> **Q4.** ¿Por qué 730 horas y no 720 (30 × 24)? ¿Qué error introduce 720 a lo largo de un año?

---

## Bloque 2 — Los factores que realmente mueven una factura de Azure

El examen te pide "describir factores que pueden afectar los costos". En lugar de recitarlos, medí tres de ellos.

### 2a. Región

5. Cotizá el mismo SKU en cinco regiones:

```bash
for R in eastus westeurope brazilsouth japaneast southafricanorth; do
  P=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
        --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq '$R' \
            and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
      | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first // "n/a"')
  printf '%-18s %s USD/hour\n' "$R" "$P"
done
```

Salida ilustrativa:

```
eastus             0.096 USD/hour
westeurope         0.1058 USD/hour
brazilsouth        0.1568 USD/hour
japaneast          0.128 USD/hour
southafricanorth   0.1244 USD/hour
```

### 2b. Ancho de banda y zonas de facturación

6. La transferencia de datos saliente se mide; la entrante no. Mirá la estructura de niveles:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "currencyCode='USD'" \
  --data-urlencode "\$filter=serviceName eq 'Bandwidth' and armRegionName eq 'eastus' \
      and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .tierMinimumUnits, .retailPrice, .unitOfMeasure] | @tsv' \
  | sort | head -20
```

Fijate en la columna `tierMinimumUnits`: un mismo medidor puede tener varias filas, cada una válida a partir de un volumen acumulado distinto. Eso es precio escalonado graduado — los primeros N GB a una tarifa, el bloque siguiente a una tarifa menor. Mirá [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) para la asignación gratuita vigente (una cantidad mensual de egreso a internet es gratis por cuenta de facturación) y el mapa de zonas.

### 2c. Modelo de consumo

7. Compará las tarifas de pay-as-you-go, spot y dev/test para el mismo silicio:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus'" \
  | jq -r '.Items[] | [.type, .meterName, .productName, .retailPrice, (.reservationTerm // "-")] | @tsv' \
  | column -t
```

Salida ilustrativa:

```
Consumption          D2s v5       Virtual Machines Dv5 Series          0.096    -
Consumption          D2s v5 Spot  Virtual Machines Dv5 Series          0.0106   -
DevTestConsumption   D2s v5       Virtual Machines Dv5 Series Windows  0.096    -
Reservation          D2s v5       Virtual Machines Dv5 Series          0.0605   1 Year
Reservation          D2s v5       Virtual Machines Dv5 Series          0.0389   3 Years
```

> ⚠️ **Verificá tu comprensión**
>
> **Q5.** Brazil South cuesta ~63 % más que East US por hardware idéntico. Nombrá tres factores de costo detrás de la variación regional de precios, y una razón *no económica* por la que desplegarías igual en la región cara.
> **Q6.** Una carga de trabajo sube 5 TB/mes a Azure Blob Storage y sirve 2 TB/mes a internet. ¿Qué dirección genera un medidor de Bandwidth, y por qué esa asimetría es un diseño comercial deliberado?
> **Q7.** Spot es ~89 % más barato. Enunciá el contrato que aceptás a cambio, las dos políticas de desalojo, y una clase de carga de trabajo para la que spot es inutilizable.
> **Q8.** `DevTestConsumption` muestra el producto *Windows* al mismo precio que el consumo Linux. ¿Qué se está descontando, y cuál es el requisito de elegibilidad?
> **Q9.** Enumerá cinco factores que afectan el costo de Azure y que **no** son visibles en absoluto en la Retail Prices API.

---

## Bloque 3 — Pricing Calculator vs. TCO Calculator

Estas dos herramientas se confunden constantemente en el examen porque ambas producen dinero como salida. Responden preguntas distintas.

8. Construí una estimación en la Pricing Calculator — [azure.microsoft.com/pricing/calculator](https://azure.microsoft.com/en-us/pricing/calculator/):
   1. Agregá **Virtual Machines** → East US, Linux, D2s v5, Pay as you go, 730 horas.
   2. Agregá **Managed Disks** → Standard SSD, E10 (128 GiB), 1 disco.
   3. Agregá **Bandwidth** → 500 GB salientes desde Zone 1.
   4. Poné **Support** → *Standard*.
   5. Cambiá la región de la VM a *Brazil South* y mirá cómo se mueve el total.
   6. Cambiá la VM a **reservada a 1 año** y después a **reservada a 3 años**.
   7. Hacé clic en **Export** (XLSX) y **Save**/**Share** de la estimación.

9. Fijate en las palancas que acabás de usar: región, SKU/nivel, cantidad/horas, licenciamiento (casilla de Azure Hybrid Benefit), compromiso de plazo, precio dev/test, nivel de soporte, moneda, y programas y ofertas.

10. La **TCO Calculator** responde otra pregunta: *¿deberíamos migrar siquiera?* Sus entradas son tu parque **on-premises** (servidores físicos/virtuales, CPU/RAM, motores de base de datos, TB de almacenamiento por tipo, ancho de banda de red) más perillas de supuestos — precio de la electricidad por kWh, costo de mano de obra de TI, ciclo de renovación de hardware, ratio de virtualización, costo de instalaciones del centro de datos. Su salida es una **comparación multianual on-prem vs. Azure**, que incluye categorías de costo que Azure nunca te factura (energía, refrigeración, espacio físico, depreciación de hardware, horas de personal).

    Microsoft ha ido integrando este análisis en **Azure Migrate → Business case**, que hace la misma aritmética impulsada por inventario *descubierto* en lugar de estimaciones tipeadas ([Business case calculations](https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation)). Verificá el punto de entrada vigente en [azure.microsoft.com/pricing/tco/calculator](https://azure.microsoft.com/en-us/pricing/tco/calculator/) — la distinción conceptual de abajo es lo que evalúa el examen, sin importar qué superficie la aloje.

| | Pricing Calculator | TCO Calculator / Business case |
|---|---|---|
| Pregunta que responde | "¿Cuánto va a costar *este diseño de Azure*?" | "¿Salir de nuestro centro de datos es más barato?" |
| Entrada | Servicios de Azure, SKUs, regiones, cantidades | Servidores on-prem, BDs, almacenamiento, red + supuestos de costo |
| Salida | Estimación de Azure detallada mensual/anual | Comparación de TCO multianual, on-prem vs Azure |
| Incluye energía/refrigeración/mano de obra/inmuebles | No | Sí (del lado on-prem) |
| Usuario típico | Arquitecto dimensionando una solución | CFO/patrocinador armando un caso de negocio de migración |
| Aplica descuentos | AHB, reservas, dev/test, ofertas | Los mismos, más ahorros operativos modelados |
| ¿Vinculante? | No — solo estimación | No — solo modelo |

> ⚠️ **Verificá tu comprensión**
>
> **Q10.** Tu director de finanzas pregunta: "¿Azure va a ser más barato que el alquiler del centro de datos que renovamos en marzo?" ¿Qué herramienta, y por qué la otra es estructuralmente incapaz de responderla?
> **Q11.** Una estimación de la Pricing Calculator decía $4,200/mes; la primera factura fue $5,600. Dá cuatro razones legítimas por las que puede aparecer esa brecha incluso cuando la estimación se construyó correctamente.
> **Q12.** ¿Qué categorías de costo cuenta la TCO Calculator del lado on-premises que nunca aparecen en ninguna factura de Azure? ¿Por qué incluirlas hace que Azure se vea mejor *y* a la vez hace la comparación más honesta?
> **Q13.** Ninguna de las dos calculadoras requiere una suscripción de Azure. ¿Qué implica eso sobre su relación con tus precios negociados reales (EA/MCA/CSP)?

---

## Bloque 4 — Desplegá una huella medida y predecí su costo permanente

Los datos de costo en el portal tienen un retraso de **8–24 horas**. En lugar de esperar, vas a desplegar, después *predecir* la factura desde el catálogo de precios, y reconciliar en el bloque 7.

11. Creá el grupo de recursos con etiquetas aplicadas al momento de la creación:

```bash
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags costcenter=cc-1024 env=lab owner=az900-student project=cost-mgmt \
  -o table
```

12. Desplegá una VM Linux chica con un SKU de disco elegido explícitamente (nunca aceptes el valor por defecto cuando estás estudiando costos):

```bash
az vm create \
  --resource-group "$RG" \
  --name vm-cost-lab \
  --image Ubuntu2404 \
  --size Standard_B2als_v2 \
  --storage-sku StandardSSD_LRS \
  --os-disk-size-gb 32 \
  --public-ip-sku Standard \
  --admin-username azureuser \
  --generate-ssh-keys \
  --tags costcenter=cc-1024 env=lab \
  -o table
```

13. Enumerá todo lo que se creó en tu nombre — este es el factor de costo más subestimado:

```bash
az resource list --resource-group "$RG" \
  --query "[].{name:name, type:type, tags:tags}" -o table
```

Esperado: un `Microsoft.Compute/virtualMachines`, un `Microsoft.Compute/disks`, un `Microsoft.Network/networkInterfaces`, un `Microsoft.Network/publicIPAddresses`, un `Microsoft.Network/networkSecurityGroups`, y un `Microsoft.Network/virtualNetworks`. Seis recursos de un solo comando; **tres** de ellos son facturables.

14. Desasigná la VM — la operación que la mayoría cree que es "apagarla":

```bash
az vm deallocate --resource-group "$RG" --name vm-cost-lab
az vm get-instance-view --resource-group "$RG" --name vm-cost-lab \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
```

```
VM deallocated
```

15. Ahora calculá lo que una VM *desasignada* sigue costando por mes, directo desde el catálogo:

```bash
# Managed disk: 32 GiB Standard SSD == the E4 tier, billed per disk per month
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Storage' and armRegionName eq '$LOC' \
      and skuName eq 'E4 LRS' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.productName, .meterName, .retailPrice, .unitOfMeasure] | @tsv'

# Standard static public IPv4
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Virtual Network' and armRegionName eq '$LOC' \
      and contains(meterName, 'Standard Static Public IP') and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .retailPrice, .unitOfMeasure] | @tsv'
```

Sumá el precio mensual del disco a (precio horario de la IP pública × 730). Esa cifra es tu **costo permanente**: lo que pagás por una máquina que no hace nada.

16. Contrastá con una VM que simplemente está *detenida* desde el sistema operativo invitado:

```bash
az vm start --resource-group "$RG" --name vm-cost-lab
# ssh in and run `sudo shutdown -h now`, or simulate the resulting state:
az vm get-instance-view -g "$RG" -n vm-cost-lab \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
az vm deallocate --resource-group "$RG" --name vm-cost-lab   # leave it deallocated
```

Un apagado iniciado desde el invitado deja la VM en **Stopped (not deallocated)** — la reserva de cómputo se sigue reteniendo y **se sigue facturando**. Solo **Stopped (deallocated)** libera el medidor de cómputo.

> ⚠️ **Verificá tu comprensión**
>
> **Q14.** Se crearon seis recursos; tres facturan. ¿Cuáles tres, y cuáles tres son gratis?
> **Q15.** Explicá la diferencia de facturación entre `Stopped` y `Stopped (deallocated)`, y dá el verbo exacto de la CLI que produce cada uno.
> **Q16.** Después de la desasignación, ¿qué medidores se detienen y cuáles continúan? Escribí la fórmula del costo permanente en términos de los dos precios que consultaste.
> **Q17.** Eliminar la *VM* con `az vm delete` deja atrás el disco, la NIC, la IP pública, el NSG y la VNet. ¿Cuál es el nombre de gobernanza para esos remanentes, y qué dos funciones de Azure los detectarían automáticamente?
> **Q18.** Redimensionás de `Standard_B2als_v2` a `Standard_D8s_v5` para una prueba de carga de dos horas y te olvidás de volver atrás. ¿Qué función de Cost Management detecta esto más rápido, y cuál es su latencia de detección?

---

## Bloque 5 — Etiquetas: el mecanismo que hace que los datos de costo *signifiquen* algo

Una etiqueta es un par nombre/valor adjunto a un recurso, grupo de recursos o suscripción. Las etiquetas no hacen nada técnicamente. Todo su propósito es proyectar una **dimensión de negocio** (centro de costos, entorno, dueño, aplicación, criticidad) sobre una factura que de otro modo está organizada según la taxonomía propia de Azure de medidores y servicios.

17. Leé las etiquetas actuales de tus recursos:

```bash
az resource list --resource-group "$RG" \
  --query "[].{name:name, type:type, costcenter:tags.costcenter, env:tags.env}" -o table
```

Fijate: la **VNet, la NIC, el NSG y la IP pública no tienen etiquetas**. Fueron creadas implícitamente por `az vm create`, y `--tags` se aplicó solo a la VM. Esta es la primera lección dura.

18. La segunda lección dura — **las etiquetas no se heredan**. El grupo de recursos lleva `owner` y `project`; los recursos no:

```bash
az group show --name "$RG" --query tags -o json
az resource show --resource-group "$RG" --name vm-cost-lab \
  --resource-type Microsoft.Compute/virtualMachines --query tags -o json
```

19. Agregá una etiqueta sin destruir las existentes. `az resource tag --tags` **reemplaza** todo el conjunto de etiquetas; `az tag update --operation Merge` no:

```bash
NIC_ID=$(az network nic list -g "$RG" --query "[0].id" -o tsv)

# Merge: keeps whatever is there, adds/overwrites the listed keys
az tag update --resource-id "$NIC_ID" --operation Merge \
  --tags costcenter=cc-1024 env=lab -o json --query properties.tags

# Inspect the three operations
az tag update --help | grep -A4 -- '--operation'
```

`Merge` agrega/actualiza las claves listadas · `Replace` descarta todo lo no listado · `Delete` elimina las claves listadas.

20. Rellená retroactivamente cada recurso sin etiquetar en el grupo:

```bash
for ID in $(az resource list -g "$RG" --query "[].id" -o tsv); do
  az tag update --resource-id "$ID" --operation Merge \
    --tags costcenter=cc-1024 env=lab owner=az900-student >/dev/null
  echo "tagged: ${ID##*/}"
done

az resource list -g "$RG" \
  --query "[].{name:name, cc:tags.costcenter, env:tags.env}" -o table
```

21. **Imponé** el etiquetado con Azure Policy en lugar de bucles de shell. Resolvé la definición integrada por nombre para mostrar — nunca escribas a mano el GUID sacado de un blog:

```bash
INHERIT_ID=$(az policy definition list \
  --query "[?displayName=='Inherit a tag from the resource group'].id | [0]" -o tsv)
REQUIRE_ID=$(az policy definition list \
  --query "[?displayName=='Require a tag on resources'].id | [0]" -o tsv)
echo "$INHERIT_ID"; echo "$REQUIRE_ID"
```

22. Asigná la directiva de herencia. Usa el efecto `modify`, así que necesita una identidad administrada con derechos de **Tag Contributor** (o Contributor) sobre el ámbito:

```bash
az policy assignment create \
  --name "inherit-costcenter" \
  --display-name "Inherit costcenter from resource group" \
  --policy "$INHERIT_ID" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --params '{"tagName":{"value":"costcenter"}}' \
  --mi-system-assigned \
  --location "$LOC" \
  --role "Tag Contributor" \
  --identity-scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  -o table
```

23. `modify` actúa en **creación/actualización**, no retroactivamente. Forzá los recursos existentes a cumplir con una tarea de remediación:

```bash
ASSIGN_ID=$(az policy assignment show --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" --query id -o tsv)

az policy remediation create \
  --name "rem-inherit-costcenter" \
  --policy-assignment "$ASSIGN_ID" \
  --resource-group "$RG" \
  -o table

az policy state list --resource-group "$RG" \
  --filter "PolicyAssignmentName eq 'inherit-costcenter'" \
  --query "[].{res:resourceId, state:complianceState}" -o table
```

La evaluación de directivas no es instantánea — un escaneo completo corre aproximadamente cada 24 horas, aunque la asignación dispara una evaluación dentro de ~30 minutos. Mirá [Azure Policy built-ins](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies).

24. Aprendé los límites duros antes de diseñar una taxonomía ([Tag resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources)):

| Restricción | Valor |
|---|---|
| Etiquetas por recurso / grupo de recursos / suscripción | 50 |
| Longitud del **nombre** de la etiqueta | 512 caracteres (128 para cuentas de almacenamiento) |
| Longitud del **valor** de la etiqueta | 256 caracteres |
| Caracteres prohibidos en nombres de etiquetas | `<` `>` `%` `&` `\` `?` `/` |
| Herencia desde el RG/suscripción | **Ninguna** por defecto |
| Soporte entre tipos de recursos | No universal — verificá [tag support per type](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support) |
| Sensibilidad a mayúsculas | Los nombres son insensibles a mayúsculas para *operaciones*, y preservan mayúsculas para *visualización*; los valores son sensibles a mayúsculas |

25. Aparte de la herencia de ARM, **Cost Management tiene su propia configuración de herencia de etiquetas** que estampa las etiquetas de la suscripción/grupo de recursos sobre los *registros de costo* de los recursos hijos, sin tocar los recursos en sí. Portal: **Cost Management → Configuration → Tag inheritance**. Mirá [Enable tag inheritance](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance) — incluido el detalle importante de qué etiqueta gana cuando un recurso y su RG definen la misma clave, y el hecho de que aplica al uso desde el mes en curso en adelante, no a datos históricos.

> ⚠️ **Verificá tu comprensión**
>
> **Q19.** ¿Por qué `az resource tag --tags env=prod` destruye tus otras etiquetas mientras que `az tag update --operation Merge --tags env=prod` no?
> **Q20.** Enunciá la diferencia entre la directiva de nivel ARM "Inherit a tag from the resource group" y la configuración "Tag inheritance" de Cost Management. ¿Cuál cambia el recurso, cuál cambia la *factura*, y cuándo elegirías deliberadamente la segunda?
> **Q21.** El efecto `modify` necesita una identidad administrada y una asignación de rol; los efectos `deny` y `audit` no. ¿Por qué?
> **Q22.** Un equipo etiqueta con `CostCenter=CC-1024`, otro con `costcenter=cc-1024`. ¿Qué mitades de esos dos pares colisionan y cuáles no, y cómo se ve la agrupación resultante en Cost Analysis?
> **Q23.** Tu CFO quiere "costo por aplicación" a través de 40 suscripciones. Explicá por qué las etiquetas por sí solas son insuficientes y nombrá los otros dos constructos de ámbito de Cost Management que combinarías con ellas.

---

## Bloque 6 — Presupuestos y alertas como código

Un presupuesto en Azure **no** detiene el gasto. Es un umbral que dispara notificaciones y, opcionalmente, activa un grupo de acciones — que es donde puede vivir la lógica de apagado automático.

26. Escribí un presupuesto completo y desplegable con ámbito de suscripción:

```bash
cat > budget-az900.json <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "budgetName":   { "type": "string",  "defaultValue": "bdg-az900-cost-lab" },
    "amount":       { "type": "int",     "defaultValue": 50,
                      "metadata": { "description": "Monthly budget in billing currency." } },
    "startDate":    { "type": "string",
                      "metadata": { "description": "MUST be the first day of a month, e.g. 2026-09-01T00:00:00Z" } },
    "endDate":      { "type": "string",  "defaultValue": "2027-09-01T00:00:00Z" },
    "alertEmails":  { "type": "array" },
    "targetResourceGroup": { "type": "string", "defaultValue": "rg-az900-cost-lab" }
  },
  "resources": [
    {
      "type": "Microsoft.Consumption/budgets",
      "apiVersion": "2021-10-01",
      "name": "[parameters('budgetName')]",
      "properties": {
        "category": "Cost",
        "amount": "[parameters('amount')]",
        "timeGrain": "Monthly",
        "timePeriod": {
          "startDate": "[parameters('startDate')]",
          "endDate": "[parameters('endDate')]"
        },
        "filter": {
          "and": [
            {
              "dimensions": {
                "name": "ResourceGroupName",
                "operator": "In",
                "values": [ "[parameters('targetResourceGroup')]" ]
              }
            },
            {
              "tags": {
                "name": "costcenter",
                "operator": "In",
                "values": [ "cc-1024" ]
              }
            }
          ]
        },
        "notifications": {
          "Actual_GreaterThan_50_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 50,
            "thresholdType": "Actual",
            "contactEmails": "[parameters('alertEmails')]",
            "contactRoles": [ "Owner" ],
            "locale": "en-us"
          },
          "Actual_GreaterThan_90_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 90,
            "thresholdType": "Actual",
            "contactEmails": "[parameters('alertEmails')]",
            "locale": "en-us"
          },
          "Forecasted_GreaterThan_100_Percent": {
            "enabled": true,
            "operator": "GreaterThan",
            "threshold": 100,
            "thresholdType": "Forecasted",
            "contactEmails": "[parameters('alertEmails')]",
            "locale": "en-us"
          }
        }
      }
    }
  ],
  "outputs": {
    "budgetId": {
      "type": "string",
      "value": "[subscriptionResourceId('Microsoft.Consumption/budgets', parameters('budgetName'))]"
    }
  }
}
JSON
```

27. Desplegalo. `startDate` debe ser el **primer día de un mes**:

```bash
START="$(date -u +%Y-%m-01T00:00:00Z)"

az deployment sub create \
  --name dep-budget-az900 \
  --location "$LOC" \
  --template-file budget-az900.json \
  --parameters startDate="$START" alertEmails="[\"$ALERT_EMAIL\"]" \
               targetResourceGroup="$RG" amount=50 \
  --query "properties.{state:provisioningState, budget:outputs.budgetId.value}" -o yaml
```

28. Verificá, y leé de vuelta el conjunto de notificaciones:

```bash
az consumption budget list -o table

az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/bdg-az900-cost-lab?api-version=2021-10-01" \
  | jq '.properties | {amount, timeGrain, currentSpend, forecastSpend,
                        notifications: (.notifications | keys)}'
```

Salida ilustrativa:

```json
{
  "amount": 50,
  "timeGrain": "Monthly",
  "currentSpend":  { "amount": 0.41, "unit": "USD" },
  "forecastSpend": { "amount": 3.87, "unit": "USD" },
  "notifications": [
    "Actual_GreaterThan_50_Percent",
    "Actual_GreaterThan_90_Percent",
    "Forecasted_GreaterThan_100_Percent"
  ]
}
```

29. Mapeá las familias de alertas que puede levantar Cost Management ([Cost alerts](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/cost-mgt-alerts-monitor-usage-spending)):

| Tipo de alerta | Disparador | Disponible en |
|---|---|---|
| **Alerta de presupuesto** | El gasto real o pronosticado cruza un umbral porcentual | Cualquier ámbito con Cost Management |
| **Alerta de crédito** | El Azure Prepayment (compromiso monetario) cae al 90 % / 100 % consumido | Solo EA, automática |
| **Alerta de cuota de gasto de departamento** | El gasto del departamento alcanza un % de su cuota | Solo EA |
| **Alerta de anomalía** | El uso diario se desvía del patrón aprendido | Ámbito de suscripción, programada, activada por defecto |
| **Alerta programada** | Vista de costos enviada por correo con cierta cadencia | Cualquier ámbito, definida por el usuario |

30. Conectá un presupuesto a un **grupo de acciones** para que pueda *hacer* algo en lugar de solo mandar correo. Agregá `contactGroups` a una notificación con el ID de recurso del grupo de acciones; ese grupo de acciones puede invocar una Logic App, un runbook de Automation, o un webhook que desasigne VMs de no producción.

> ⚠️ **Verificá tu comprensión**
>
> **Q24.** Se supera un presupuesto de $50/mes el día 12. ¿Qué le hace Azure a tus recursos en ejecución? Justificá el diseño.
> **Q25.** Distinguí un umbral **Actual** de un umbral **Forecasted**. ¿Cuál te da tiempo para reaccionar, y cuál es su modo de fallo en una suscripción de solo tres días de antigüedad?
> **Q26.** El `filter` de la plantilla acota el presupuesto a un grupo de recursos **y** a un valor de etiqueta. Si un recurso de ese RG no tiene la etiqueta `costcenter=cc-1024`, ¿su gasto cuenta contra el presupuesto? ¿Qué implica eso sobre ordenar el bloque 5 antes del bloque 6?
> **Q27.** ¿Cuáles de los cinco tipos de alerta del paso 29 requieren un Enterprise Agreement, y por qué no pueden existir en una suscripción de pago por uso?
> **Q28.** Querés que una violación de presupuesto desasigne automáticamente todas las VMs con `env=lab`. Nombrá la cadena de componentes, y enunciá la única garantía que este diseño no puede dar.

---

## Bloque 7 — Cost Analysis: ámbitos, dimensiones, actual vs. amortizado

31. Instalá la extensión y confirmá tu ámbito:

```bash
az extension add --name costmanagement --upgrade
az extension show --name costmanagement --query version -o tsv
```

32. Consultá el costo del mes hasta la fecha agrupado por grupo de recursos:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" \
  --dataset-granularity None \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="ResourceGroupName" type="Dimension" \
  -o json | jq -r '.rows[] | @tsv'
```

> Si esto devuelve `400 BadRequest` quejándose de la columna de agregación, tu ámbito es un ámbito EA heredado: reemplazá `"name":"Cost"` por `"name":"PreTaxCost"`. Los ámbitos MCA/PAYG usan `Cost`/`CostUSD`; los ámbitos EA usan `PreTaxCost`. Esta sola diferencia rompe más automatización de costos que ningún otro detalle.

33. Agrupá por **etiqueta** en lugar de por la taxonomía propia de Azure — esta es la recompensa del bloque 5:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" \
  --dataset-granularity None \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="costcenter" type="TagKey" \
  -o json | jq -r '.columns[].name as $c | .rows[] | @tsv'
```

34. Desglosá el RG del laboratorio por medidor, diariamente:

```bash
az costmanagement query \
  --type ActualCost \
  --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --dataset-granularity Daily \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  --dataset-grouping name="Meter" type="Dimension" \
  -o json | jq -r '.rows[] | @tsv' | sort -k2
```

Salida ilustrativa (`cost  date  meter  currency`):

```
0.0043  20260905  E4 LRS Disk                  USD
0.0201  20260905  Standard Static Public IP    USD
0.0089  20260905  B2als v2                     USD
```

Reconciliá esto contra el costo permanente que predijiste en el paso 15.

35. Compará **ActualCost** con **AmortizedCost** — idénticos para vos hoy, radicalmente distintos en una organización que tiene reservas:

```bash
for T in ActualCost AmortizedCost; do
  echo "== $T"
  az costmanagement query --type "$T" --timeframe MonthToDate \
    --scope "/subscriptions/$SUB_ID" --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    -o json | jq -r '.rows[][0]'
done
```

36. Entendé la **jerarquía de ámbitos** — dónde apuntás Cost Management determina tanto qué ves como quién tiene permitido verlo ([Understand and work with scopes](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes)):

```
Billing account (EA enrollment / MCA billing account)
└── Department (EA)  |  Billing profile (MCA)
    └── Enrollment account (EA)  |  Invoice section (MCA)
        └── Management group
            └── Subscription
                └── Resource group
                    └── Resource
```

Los ámbitos de facturación se rigen por roles de facturación; los ámbitos de ARM (management group → recurso) se rigen por roles de RBAC — **Cost Management Reader** y **Cost Management Contributor**. Las dos jerarquías son separadas, y por eso un Owner de suscripción puede estar ciego al costo a nivel de la inscripción.

37. Configurá una **exportación** recurrente — el único mecanismo correcto para datos grandes o históricos, ya que la API de consultas tiene límite de tasa y trunca:

```bash
SA="stcost$RANDOM$RANDOM"
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
SA_ID=$(az storage account show -g "$RG" -n "$SA" --query id -o tsv)
az storage container create --account-name "$SA" --name costexports --auth-mode login -o none

az costmanagement export create \
  --name "exp-mtd-daily" \
  --type ActualCost \
  --scope "/subscriptions/$SUB_ID" \
  --storage-account-id "$SA_ID" \
  --storage-container "costexports" \
  --storage-directory "az900-lab" \
  --timeframe MonthToDate \
  --recurrence Daily \
  --recurrence-period from="$(date -u +%Y-%m-%dT00:00:00Z)" to="2027-01-01T00:00:00Z" \
  --schedule-status Active \
  -o table

az costmanagement export list --scope "/subscriptions/$SUB_ID" -o table
```

38. Por último, mirá el consejo gratuito que ya te está esperando:

```bash
az advisor recommendation list --category Cost \
  --query "[].{impact:impact, problem:shortDescription.problem, res:impactedValue}" -o table
```

> ⚠️ **Verificá tu comprensión**
>
> **Q29.** Explicá **ActualCost** vs **AmortizedCost** usando una reserva de 3 años de $10,000 comprada el 4 de marzo. ¿Qué muestra cada vista para marzo, y sobre cuál debería hacérsele el cargo a un equipo?
> **Q30.** Los datos de costo tienen un retraso de 8–24 horas y no muestran impuestos. Dá dos consecuencias operativas del retraso y una consecuencia de reconciliación de la falta de impuestos.
> **Q31.** Un **Owner** de suscripción abre Cost Management y ve su suscripción pero no el total de la inscripción. Explicalo usando el modelo de dos jerarquías.
> **Q32.** ¿Cuándo tenés que usar una **exportación** en lugar de la API de consultas, y por qué una exportación diaria a Blob Storage es el patrón estándar para pipelines de FinOps?
> **Q33.** Microsoft Cost Management no cuesta nada para el uso de Azure. ¿Por qué Microsoft puede permitírselo, y cuál es el argumento estratégico para hacer gratuita la visibilidad de costos?

---

## Bloque 8 — Reservas y planes de ahorro: análisis de punto de equilibrio de solo lectura

**No compres nada.** Las reservas son compromisos reales. Este bloque es aritmética sobre datos públicos.

39. Traé los tres tipos de precio para un SKU:

```bash
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "api-version=2023-01-01-preview" \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and contains(productName, 'Windows') eq false" \
  | jq -r '.Items[] | [.type, (.reservationTerm // "-"), .meterName, .retailPrice, .unitOfMeasure] | @tsv' \
  | column -t
```

40. Calculá el descuento y la utilización de punto de equilibrio:

```bash
PAYG=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and meterName eq 'D2s v5' and priceType eq 'Consumption'" \
  | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first')

RI3=$(curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armSkuName eq 'Standard_D2s_v5' and armRegionName eq 'eastus' \
      and priceType eq 'Reservation' and reservationTerm eq '3 Years'" \
  | jq -r '[.Items[] | select(.productName | test("Windows") | not) | .retailPrice] | first')

echo "PAYG hourly : $PAYG"
echo "3-yr hourly : $RI3"
python3 - <<EOF
payg=$PAYG; ri=$RI3
print(f"discount        : {(1-ri/payg)*100:.1f}%")
print(f"break-even util : {(ri/payg)*100:.1f}% of the hours in the term")
print(f"3-yr PAYG cost  : \${payg*730*36:,.0f}")
print(f"3-yr RI cost    : \${ri*730*36:,.0f}")
EOF
```

41. Leé a qué te ata realmente cada instrumento de compromiso:

| Instrumento | Te comprometés a | Flexibilidad | Mejor para |
|---|---|---|---|
| **Reserva** (1 o 3 años) | Una *serie* de VM específica, región, cantidad | Flexibilidad de tamaño de instancia dentro de una serie; aplican políticas de intercambio/reembolso | Forma estable, predecible, sin cambios |
| **Savings plan for compute** (1 o 3 años) | Un **$/hora** fijo a través de servicios de cómputo | Aplica a VMs, App Service, Container Instances, entre regiones y series | Gasto estable, forma cambiante |
| **Azure Hybrid Benefit** | Poseer licencias de Windows Server / SQL Server con Software Assurance | Acumulable con reservas | Parque de licencias existente |
| **Spot** | Nada | Desalojable en cualquier momento con 30 s de aviso | Batch interrumpible con puntos de control |
| **Precio Dev/Test** | Oferta de suscripción elegible | Solo no producción, sin SLA sobre los términos del descuento | Dev, test, QA |

Referencias: [Reservations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations) · [Savings plan for compute](https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview) · [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing)

> ⚠️ **Verificá tu comprensión**
>
> **Q34.** Tu punto de equilibrio dio alrededor del 40 %. Enunciá claramente qué significa ese porcentaje y qué pasa si tu utilización real es del 30 %.
> **Q35.** ¿Cuándo es un **savings plan** el instrumento correcto aunque su descuento nominal sea menor que el de una reserva?
> **Q36.** Las reservas y Azure Hybrid Benefit se acumulan. ¿Qué componente de costo aborda cada uno, y por qué pueden combinarse sin contar dos veces?
> **Q37.** Un equipo compra una reserva a 3 años para `Standard_D8s_v5` en East US y seis meses después re-arquitecta hacia AKS con `Standard_E16ds_v5` en West Europe. ¿Cuáles son sus opciones, y cuál es la lección de fondo sobre horizonte de compromiso vs. estabilidad de la arquitectura?

---

## Bloque 9 — Desmantelamiento, y los recursos que lo sobreviven

Eliminar un grupo de recursos es necesario pero **no suficiente**. Los objetos con ámbito de suscripción viven fuera de él.

42. Eliminá el grupo de recursos:

```bash
az group delete --name "$RG" --yes --no-wait
az group wait --name "$RG" --deleted --timeout 1800
az group exists --name "$RG"      # -> false
```

43. Quitá el presupuesto con ámbito de suscripción — la eliminación del RG **no** lo tocó:

```bash
az consumption budget list -o table
az rest --method delete \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/bdg-az900-cost-lab?api-version=2021-10-01"
az consumption budget list -o table
```

44. Quitá la asignación de directiva y su asignación de rol. Eliminar la asignación deja huérfana la concesión de rol de la identidad administrada, lo cual es un hallazgo de seguridad real (aunque menor):

```bash
PRINCIPAL=$(az policy assignment show --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --query identity.principalId -o tsv 2>/dev/null || true)

az policy assignment delete --name inherit-costcenter \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" 2>/dev/null || true

# Sweep any role assignment left behind by a deleted identity
az role assignment list --all --query "[?principalName==null].{role:roleDefinitionName, scope:scope, id:id}" -o table
```

45. Barré toda la suscripción en busca de huérfanos — que esto sea un hábito, no un paso de laboratorio:

```bash
echo "== Unattached managed disks"
az disk list --query "[?diskState=='Unattached'].{name:name, rg:resourceGroup, gb:diskSizeGb, sku:sku.name}" -o table

echo "== Unassociated public IPs"
az network public-ip list --query "[?ipConfiguration==null].{name:name, rg:resourceGroup, sku:sku.name, alloc:publicIPAllocationMethod}" -o table

echo "== Unattached NICs"
az network nic list --query "[?virtualMachine==null].{name:name, rg:resourceGroup}" -o table

echo "== Empty resource groups"
for G in $(az group list --query "[].name" -o tsv); do
  [ "$(az resource list -g "$G" --query "length(@)" -o tsv)" = "0" ] && echo "empty: $G"
done
```

46. Confirmá que el gasto quedó cerrado (dejá pasar 24 h para que aterricen los últimos registros):

```bash
az costmanagement query --type ActualCost --timeframe MonthToDate \
  --scope "/subscriptions/$SUB_ID" --dataset-granularity Daily \
  --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
  -o json | jq -r '.rows[] | @tsv'
```

> ⚠️ **Verificá tu comprensión**
>
> **Q38.** ¿Cuáles de los objetos que creaste sobreviven a `az group delete`, y cuál es la regla general que predice esto?
> **Q39.** Los últimos registros de costo de un recurso eliminado pueden aparecer hasta 24 horas *después* de la eliminación. ¿Por qué, y qué significa eso para quien verifica que un incidente de costos terminó?
> **Q40.** Convertí el paso 45 en una directiva: nombrá los servicios de Azure que combinarías para detectar y remediar discos e IPs públicas huérfanos de forma continua, sin que un humano corra un bucle de shell.

---

<details>
<summary><strong>📘 Respuestas — expandí solo después de completar los bloques</strong></summary>

### Bloque 1

**A1.** Las cuatro filas son cuatro **medidores**: Linux pay-as-you-go, Spot, Low Priority y Windows. Un *tamaño* de VM (`armSkuName`) es una forma de hardware; un *medidor* (`meterId` / `meterName`) es una primitiva de facturación. Un tamaño mapea a muchos medidores, porque el precio depende del tamaño **más** el licenciamiento del SO **más** el modelo de consumo. Tu factura es una lista de medidores y cantidades, nunca una lista de "tamaños de VM" — que es exactamente por qué `Meter` es la dimensión útil más granular en Cost Analysis, y por qué la misma VM puede aparecer en múltiples ítems de línea.

**A2.** El delta es la **licencia de Windows Server** incluida en la tarifa de pago por uso (la porción de cómputo es idéntica; solo difiere la licencia). **Azure Hybrid Benefit** la elimina: si poseés licencias de Windows Server con Software Assurance activo (o una licencia por suscripción), podés aplicarlas a VMs de Azure y pagar solo el cómputo a tarifa Linux. El mismo mecanismo existe para SQL Server, y se acumula con las reservas porque aborda un componente de costo distinto.

**A3.** Estos son **precios minoristas / de lista** — públicos, no negociados, por moneda y región. **No** van a coincidir con tu factura cuando: estás bajo un acuerdo EA/MCA/CSP con descuentos negociados; tenés reservas o un savings plan; aplica Azure Hybrid Benefit; usás ofertas dev/test o créditos de patrocinio; las asignaciones de nivel gratuito absorben el uso; o aplican impuestos/conversión de moneda. Los precios minoristas son el *límite superior* correcto y la base correcta para comparar SKUs y regiones — nunca el pronóstico correcto de una factura empresarial.

**A4.** 730 = 365 × 24 ÷ 12 — el *promedio* de horas en un mes. Usar 720 subestima en 10 horas/mes, es decir **120 horas/año ≈ 1.4 %** del cómputo anual. Con un gasto de cómputo de $500k/año eso es un error de pronóstico de $7,000, y siempre yerra en dirección optimista. Notá que Azure factura horas transcurridas reales (prorrateadas, y por segundo en varios servicios); 730 es una constante de *planificación*, no una regla de facturación.

### Bloque 2

**A5.** La variación regional de precios se debe a (1) **costos locales de energía y suelo** — la energía es el mayor gasto operativo de un centro de datos; (2) **regímenes de importación de hardware, impuestos y aranceles** más costos locales de mano de obra y cumplimiento; (3) **madurez, escala y utilización de capacidad del centro de datos** — las regiones más nuevas y chicas amortizan costos fijos sobre menos demanda; y (4) precios competitivos/de mercado locales. Aun así pagarías el sobreprecio por **residencia y soberanía de datos**: si la regulación exige que los datos del cliente permanezcan en Brasil, o si la latencia del usuario final demanda presencia local, la elección de región es una decisión de cumplimiento/arquitectura que el costo no puede anular.

**A6.** Solo los **2 TB salientes** generan un medidor de Bandwidth. El tráfico entrante (ingreso) hacia Azure es gratis. La asimetría es un diseño comercial deliberado: el ingreso gratis elimina la fricción de *meter los datos*, mientras que el egreso medido le pone precio a *sacarlos* — baja la barrera de adopción y sube el costo de irse. Por eso la arquitectura consciente del costo mantiene el tráfico conversacional dentro de una región, usa Private Link y service endpoints para evitar rutas por internet, y pone una CDN delante del contenido público de alto volumen para que la mayor parte del egreso facture a tarifas de CDN desde caché en vez de desde el origen. (Notá que una asignación mensual gratuita cubre el primer tramo de egreso a internet, y cambios regulatorios hicieron que el egreso sea gratis cuando un cliente sale por completo de un proveedor de nube — verificá los términos vigentes en lugar de suponer.)

**A7.** Aceptás que Azure puede **desalojar** la VM en cualquier momento con unos 30 segundos de aviso cuando necesite recuperar la capacidad, o cuando se supere tu tope de precio. **No hay SLA.** Las dos políticas de desalojo son **Deallocate** (la VM queda detenida-desasignada; los discos persisten y siguen facturando; podés reiniciarla después) y **Delete** (la VM y sus discos se eliminan). Spot es inutilizable para cualquier cosa con estado y siempre encendida: bases de datos, controladores de dominio, cualquier capa detrás de un SLA, y cualquier trabajo largo de una sola pasada que no pueda hacer puntos de control. Es ideal para agentes de CI/CD, renderizado por lotes y entrenamiento de ML con puntos de control.

**A8.** `DevTestConsumption` descuenta la **licencia de software**, no el cómputo — por eso el producto Windows aparece a la tarifa de consumo de Linux. El requisito es la **oferta de suscripción**: Enterprise Dev/Test o Pay-As-You-Go Dev/Test, disponible para suscriptores de Visual Studio, y contractualmente restringida a cargas de trabajo de **no producción**. Correr producción en una suscripción dev/test es una violación de licenciamiento, no una optimización ingeniosa.

**A9.** No visible en la Retail Prices API: (1) tus **descuentos negociados EA/MCA/CSP**; (2) las **reservas y savings plans que ya tenés**, y cómo se aplican; (3) la elegibilidad de **Azure Hybrid Benefit** según las licencias que poseés; (4) las **asignaciones de nivel gratuito** y los créditos consumidos; (5) el **nivel del plan de soporte** (Developer / Standard / Professional Direct) — una línea mensual fija en la factura; (6) los **cargos de terceros de Azure Marketplace**, que siguen los términos propios del editor; (7) los **impuestos**; (8) la **conversión de moneda** a la fecha de la factura; y (9) el más grande — **cuánto vas a consumir realmente**.

### Bloque 3

**A10.** La **TCO Calculator** (o el Business case de Azure Migrate). La Pricing Calculator es estructuralmente incapaz de responderla porque solo modela el lado Azure del balance: no tiene entradas para electricidad, refrigeración, espacio físico, depreciación de hardware, licenciamiento de hipervisor, ni horas de personal del centro de datos. Sin una línea base on-premises no hay nada contra qué comparar, así que la Pricing Calculator puede decirte cuánto va a costar Azure pero nunca si eso es *más barato*.

**A11.** Brechas legítimas: (1) **consumo estimado vs. real** — la estimación asumió 730 horas y el autoescalado corrió más; (2) **recursos que nadie estimó** — discos creados implícitamente, IPs públicas, balanceadores de carga, backups, ingesta de logs, instantáneas; (3) **transferencia de datos** — el egreso y el tráfico entre zonas/regiones están crónicamente submodelados; (4) **impuestos, conversión de moneda y el plan de soporte**, ninguno de los cuales la calculadora incluye por defecto; (5) **ítems de Marketplace** facturados por terceros; y (6) **prorrateo de mes parcial y niveles no lineales** donde la estimación supuso una tarifa plana.

**A12.** Energía, refrigeración, seguridad física, espacio físico e instalaciones, compra y depreciación de hardware, ciclos de renovación de hardware, licenciamiento de hipervisor y SO, equipamiento de red, infraestructura de backup, y **mano de obra de TI** para montar en rack, parchear y reemplazar hardware fallado. Incluirlos hace que Azure se vea mejor porque esos costos son reales pero *invisibles* — están en presupuestos de instalaciones y de personal, no en la línea de TI. Aun así, incluirlos es más honesto: una comparación que pone la factura de Azure frente a solo la factura de hardware on-prem está comparando un costo total contra uno parcial.

**A13.** Ambas son **herramientas de marketing/planificación construidas sobre el catálogo minorista público**, completamente desconectadas de tu cuenta. No pueden ver tu acuerdo, tus compromisos existentes, tus créditos ni tu historial de consumo. Tratá su salida como un *límite superior a precio de lista* que hay que ajustar hacia abajo según tu tarifa negociada, y después validar contra datos reales de Cost Management una vez que haya algo corriendo. Nunca le entregues a finanzas una exportación cruda de la calculadora como pronóstico.

### Bloque 4

**A14.** **Facturados:** la máquina virtual (medidor de cómputo, solo mientras corre), el disco administrado del SO (por disco por mes, sin importar el estado de la VM), y la dirección IPv4 pública Standard (por hora, sin importar el estado de la VM). **Gratis:** la red virtual, la interfaz de red y el grupo de seguridad de red. Lo instructivo es que un solo `az vm create` aprovisiona silenciosamente dos recursos — el disco y la IP pública — cuyos medidores son **independientes de si la VM está corriendo**.

**A15.** `Stopped` (iniciado desde el invitado, p. ej. `shutdown -h now` dentro del SO, o `az vm stop`) deja la VM en **Stopped (not deallocated)**: la capacidad de cómputo sigue reservada para vos en un host, y **te siguen facturando la tarifa completa de cómputo**. `Stopped (deallocated)` — producido por `az vm deallocate` — libera la asignación del host y detiene el medidor de cómputo. Esta es la idea equivocada más cara en operaciones de Azure: una flota "apagada para el fin de semana" desde adentro del invitado cuesta exactamente lo mismo que una flota dejada corriendo.

**A16.** **Se detiene:** el medidor de cómputo (horas de `B2als v2`). **Continúa:** el medidor del disco administrado (facturado por nivel aprovisionado, no por bytes consumidos — un Standard SSD de 32 GiB factura como nivel E4 tenga 1 GiB o 31), el medidor de la IPv4 pública estática, más cualquier disco de datos adjunto, instantáneas o almacenamiento de bóveda de backup. Fórmula del costo permanente:

```
monthly_standing = disk_price_per_month + (public_ip_price_per_hour × 730)
```

La lección: la desasignación es un ahorro parcial, no un cero. Para llegar a cero hay que eliminar.

**A17.** Son **recursos huérfanos** (o recursos "zombi"/"varados") — la fuente más común de desperdicio no rastreado en la nube. Dos funciones los detectan: **Azure Advisor**, cuya categoría Cost expone discos no adjuntos, IPs públicas ociosas, balanceadores de carga ociosos y VMs subutilizadas; y **Azure Policy** con efectos `audit`/`deny`/`deployIfNotExists` para marcarlos o bloquearlos. Un **presupuesto con grupo de acciones** basado en etiquetas es la tercera línea de defensa, y las **alertas de anomalía** de Cost Management son la cuarta.

**A18.** Las **alertas de anomalía**, que corren en una evaluación diaria programada contra el patrón de uso aprendido de la suscripción — así que la detección típicamente aterriza en aproximadamente un día, acotada por la latencia de 8–24 horas de los datos de costo. Un umbral *pronosticado* de un presupuesto también puede atraparlo, pero solo una vez que la proyección cruce el límite, lo que para un cambio escalonado chico puede llevar varios días. Ninguna es en tiempo real; si necesitás tiempo real, el control tiene que ser preventivo (Azure Policy denegando SKUs sobredimensionados) en vez de detectivo.

### Bloque 5

**A19.** Apuntan a semánticas de API distintas. `az resource tag --tags ...` emite un **PATCH/PUT del recurso con la colección de etiquetas suministrada como el conjunto completo** — todo lo no listado desaparece. `az tag update --operation Merge` llama a la **API de Tags** dedicada con una operación de fusión explícita, así que las claves listadas se agregan o sobrescriben y las no listadas quedan intactas. En automatización, usá siempre `Merge` salvo que específicamente pretendas reiniciar el conjunto de etiquetas; `Replace` en un pipeline de CI es cómo una organización entera pierde sus etiquetas `costcenter` en una sola corrida.

**A20.** La directiva integrada de **Azure Policy** ("Inherit a tag from the resource group") usa el efecto `modify` para **escribir la etiqueta sobre el recurso mismo** — cambian los metadatos de ARM, la etiqueta se vuelve visible para `az resource show`, para condiciones de RBAC, para la automatización y para toda herramienta aguas abajo. La configuración de **herencia de etiquetas de Cost Management** no toca los recursos en absoluto; estampa las etiquetas de la suscripción/grupo de recursos sobre los **registros de costo** durante la ingesta, así que la agrupación y los filtros de presupuesto las ven. Elegirías la segunda cuando querés asignación de costos *sin* mutar recursos — por ejemplo cuando un tipo de recurso no soporta etiquetas, cuando un equipo es dueño de los recursos y vos solo sos dueño del ámbito de facturación, o cuando no tenés (o no querés) los permisos de escritura y la identidad administrada que `modify` requiere. Sus límites importan: aplica desde el mes en curso hacia adelante, no retroactivamente, y una etiqueta en el recurso mismo tiene precedencia sobre la heredada.

**A21.** `audit` y `deny` son **solo de evaluación** — inspeccionan la carga útil de la solicitud y o bien registran el incumplimiento o rechazan la escritura. No cambian nada, así que no necesitan permisos. `modify` (como `deployIfNotExists`) **muta recursos en tu nombre**: Azure Policy tiene que autenticarse como algo y escribir en ARM. Ese algo es la **identidad administrada** de la asignación, que por lo tanto necesita un rol con derechos de escritura de etiquetas (Tag Contributor, o Contributor) en el ámbito de la asignación. Esto también es por qué las asignaciones `modify` requieren un `--location` — la identidad administrada es un objeto regional.

**A22.** Los **nombres** de etiqueta son insensibles a mayúsculas para las operaciones, así que `CostCenter` y `costcenter` son la **misma clave** — la segunda escritura actualiza la primera en vez de crear una hermana, y la capitalización almacenada es la que se escribió más recientemente. Los **valores** de etiqueta son **sensibles** a mayúsculas, así que `CC-1024` y `cc-1024` son **dos valores distintos**. En Cost Analysis, agrupar por `costcenter` produce entonces dos cubetas separadas con el mismo dinero repartido entre ellas — el síntoma clásico del etiquetado sin gobernanza. El arreglo es preventivo: imponé una directiva de valores permitidos sobre el valor, no solo una directiva de clave requerida.

**A23.** Las etiquetas por sí solas son insuficientes porque son **por recurso, opcionales, no heredadas, no impuestas por defecto, y no soportadas en algunos tipos de recursos** — así que una vista basada en etiquetas omite silenciosamente todo lo que nunca se etiquetó, y no hay forma de distinguir "gasto de $0" de "sin etiquetar". Combinalas con (1) **grupos de administración**, que te dan una jerarquía imponible por encima de las suscripciones donde una sola asignación de Azure Policy gobierna todo lo que está debajo, y (2) **límites de suscripción y grupo de recursos** usados deliberadamente como unidades de asignación — una suscripción por aplicación o por entorno hace que la asignación sea estructural en vez de basada en convención. Agregá la **herencia de etiquetas** de Cost Management para que las etiquetas de RG/suscripción lleguen a los registros de costo, y el residual sin etiquetar se reduce a casi cero.

### Bloque 6

**A24.** **Nada.** Un presupuesto es puramente un **disparador de notificaciones y automatización** — Azure sigue corriendo tus cargas de trabajo y sigue cobrando. El diseño es deliberado: un corte duro automático del gasto sería una interrupción automática de producción, y el radio de impacto de "el umbral de finanzas borró nuestra plataforma de pagos" excede ampliamente el radio de impacto de un sobregasto. La imposición, cuando la querés, es opcional y explícita: notificación de presupuesto → grupo de acciones → Logic App / runbook de Automation que vos escribiste y cuyas consecuencias aceptaste.

**A25.** Un umbral **Actual** se dispara sobre costo ya incurrido — preciso, pero por definición después del hecho. Un umbral **Forecasted** se dispara cuando la proyección de Azure del gasto de fin de período cruza el límite — este es el que te da tiempo para reaccionar, a veces días. Su modo de fallo en una suscripción de tres días es que el pronóstico se construye a partir de un historial muy corto: un pico puntual (una prueba de carga, una migración inicial de datos) se extrapola a todo el mes y produce una falsa alarma, mientras que a la inversa una suscripción sin historial puede no pronosticar en absoluto. La precisión del pronóstico mejora con el historial de uso; tratá con sospecha las alertas de pronóstico tempranas.

**A26.** **No** — un recurso sin etiquetar en ese RG **no** cuenta. El bloque `and` exige *ambas* condiciones: la dimensión de grupo de recursos **y** la etiqueta `costcenter=cc-1024`. Cualquier cosa sin etiquetar, o etiquetada con otro valor, es invisible para este presupuesto y su gasto queda sin monitorear. Precisamente por eso el bloque 5 va antes del bloque 6: **la gobernanza de etiquetas es un prerrequisito para la gobernanza de costos**, no un extra paralelo. Un presupuesto filtrado por etiquetas que nadie impone es un presupuesto que subreporta silenciosamente, lo cual es peor que no tener presupuesto porque fabrica confianza falsa.

**A27.** Las **alertas de crédito** y las **alertas de cuota de gasto de departamento** requieren un Enterprise Agreement. No pueden existir en pago por uso porque los constructos que monitorean no existen ahí: una alerta de crédito rastrea el consumo de un **Azure Prepayment** (compromiso monetario negociado en el EA), y una cuota de gasto de departamento rastrea un **departamento**, un objeto organizacional exclusivo de EA entre la inscripción y sus cuentas. El pago por uso no tiene saldo prepago que consumir ni jerarquía de departamentos. Las alertas de presupuesto, de anomalía y programadas funcionan en cualquier oferta.

**A28.** La cadena: **Presupuesto** (con un filtro de etiqueta/RG) → notificación con `contactGroups` apuntando a un **Action Group** → el grupo de acciones invoca una **Logic App**, un **runbook de Azure Automation**, o un **webhook/Azure Function** → ese código se autentica con una identidad administrada que tiene Virtual Machine Contributor → enumera las VMs donde `tags.env == 'lab'` → llama a deallocate. La garantía que **no** puede dar es la *oportunidad temporal*: toda la cadena está impulsada por datos de costo con 8–24 horas de retraso, así que para cuando el presupuesto se dispara, ya ocurrió hasta un día de sobregasto y no se puede deshacer. La automatización disparada por presupuesto es limitación de daños, no prevención — la prevención es Azure Policy denegando el SKU caro en primer lugar.

### Bloque 7

**A29.** **ActualCost** muestra el efectivo tal como se cobró: los **$10,000 completos el 4 de marzo**, y después $0 de cargo por reserva durante los 35 meses restantes — la factura de marzo se ve catastrófica y la de abril imposiblemente barata. **AmortizedCost** distribuye la compra uniformemente a lo largo del plazo de 36 meses (~$278/mes) y **atribuye cada porción a los recursos que efectivamente consumieron la reserva**, así que una VM cubierta por la reserva muestra su parte amortizada en lugar de $0. El chargeback debería usar **AmortizedCost**: es la única vista donde el costo reportado de un equipo refleja su consumo y no el accidente de en qué mes se destrabó el papeleo de compras. Usá ActualCost para flujo de caja y reconciliación de facturas, AmortizedCost para showback/chargeback y economía unitaria.

**A30.** El **retraso de 8–24 horas** significa que (1) no podés usar Cost Management como control en tiempo real — cualquier gasto descontrolado ya corrió hasta un día antes de que pueda dispararse una alerta, así que los controles preventivos (Policy, cuotas, restricciones de SKU) llevan la carga real; y (2) "el costo de hoy" siempre está incompleto, así que los tableros que comparan un hoy parcial contra un ayer completo fabrican una tendencia descendente fantasma — compará siempre días completos. La **falta de impuestos** significa que las cifras de Cost Management nunca van a igualar exactamente el total de la factura: la reconciliación debe hacerse contra el subtotal antes de impuestos, y cualquier conciliación automática de facturas que espere igualdad exacta va a fallar todos los meses.

**A31.** Porque los **ámbitos de facturación y los ámbitos de ARM son dos jerarquías separadas con sistemas de autorización separados**. Owner de suscripción es un rol de **RBAC** sobre un ámbito de ARM — otorga derechos plenos sobre esa suscripción y todo lo que está debajo, y nada por encima. La inscripción/cuenta de facturación, el departamento y la cuenta de inscripción (EA) o el perfil de facturación y la sección de factura (MCA) son **ámbitos de facturación**, gobernados por **roles de facturación** (Enterprise Administrator, Billing Account Owner, etc.) asignados en el portal de facturación. Ser Owner de cada suscripción de una inscripción sigue sin convertirte en Enterprise Administrator. También existe un interruptor de directiva a nivel EA que puede ocultar los cargos a los usuarios con ámbito de suscripción por completo, así que un Owner puede ni siquiera ver sus propias tarifas.

**A32.** Usá una **exportación** cuando el volumen de datos o el rango temporal exceden lo que puede devolver una consulta interactiva: reconciliación histórica completa, todos los recursos con granularidad diaria, análisis multimensual, o cualquier cosa que alimente un sistema aguas abajo. La API de consultas tiene límite de tasa, está acotada por latencia y trunca resultados grandes — está hecha para tableros, no para pipelines. Una **exportación diaria a Blob Storage** es el patrón estándar de FinOps porque es basada en push (sin sondeo, sin límites de tasa), deposita archivos fechados inmutables que hacen el pipeline idempotente y reproducible, cuesta casi nada en almacenamiento, y Blob es directamente consumible por Synapse, Databricks, Fabric, Power BI, o cualquier cargador de almacén de datos. Para inscripciones muy grandes, la Cost Details API con generación asincrónica de reportes cumple el mismo rol.

**A33.** Microsoft puede permitírselo porque el cómputo y el almacenamiento detrás de Cost Management son triviales frente al consumo sobre el que reporta, y es una **función de retención**: los clientes que no pueden ver sus costos reciben facturas sorpresa, y las facturas sorpresa impulsan migraciones hacia afuera. Estratégicamente, la visibilidad de costos gratuita (1) elimina la excusa para no optimizar, lo que paradójicamente aumenta el gasto a largo plazo porque los clientes confían lo suficiente en la plataforma como para poner más encima; (2) alimenta recomendaciones de Advisor que orientan a los clientes hacia **reservas y savings plans** — compromisos que fijan ingresos plurianuales; y (3) neutraliza a los proveedores externos de gestión de costos como diferenciador. Cobrar por la factura sería, dicho llanamente, una mala imagen.

### Bloque 8

**A34.** Una **utilización de punto de equilibrio de ~40 %** significa que la reserva cuesta lo mismo que el pago por uso si la capacidad reservada efectivamente se usa alrededor del 40 % de las horas del plazo; por encima de eso ahorrás, por debajo perdés. Con **30 % de utilización real estás pagando de más** — prepagaste capacidad que no estás consumiendo, y te hubiera salido más barato bajo demanda. Por eso las decisiones de reserva deben guiarse por utilización histórica medida (los reportes de utilización de reservas de Cost Management y las recomendaciones de reservas de Advisor, que analizan los últimos 7/30/60 días), nunca por la intención de "probablemente lo dejemos corriendo".

**A35.** Un **savings plan** gana cuando tu **gasto es estable pero su forma no**. Una reserva fija una serie de VM específica en una región específica, así que re-arquitecturar, migrar de región, o pasar de VMs a App Service o Container Instances la deja varada. Un savings plan compromete un **$/hora fijo de cómputo** y se aplica automáticamente entre servicios de cómputo, series y regiones elegibles — mantenés el descuento a lo largo de la refactorización. Elegí el descuento más profundo de la reserva solo cuando la forma de la carga de trabajo esté genuinamente congelada durante el plazo; elegí el savings plan cuando tenés confianza en el *monto* pero no en la *forma*.

**A36.** Abordan componentes distintos de la misma factura. Una **reserva** descuenta la porción de **infraestructura/cómputo** — el costo de las horas de hardware. **Azure Hybrid Benefit** elimina la porción de **licencia de Windows Server (o SQL Server)**, porque vos aportás la licencia desde tu propio derecho de Software Assurance. Dado que una tarifa Windows de pago por uso es literalmente cómputo + licencia, descontar una y eliminar la otra no puede contar dos veces. En la práctica reservás el cómputo y aplicás AHB encima, y por eso las VMs Windows reservadas con AHB se cotizan a la tarifa reservada de *Linux*.

**A37.** Opciones, aproximadamente en orden de preferencia: (1) la **flexibilidad de tamaño de instancia** aplica automáticamente el beneficio de la reserva a otros tamaños de la misma serie en la misma región — útil si se quedaban en Dsv5; (2) **intercambiar** la reserva por otra distinta (ámbito, región, serie, plazo) — la política de intercambio de Microsoft para reservas de cómputo se fue restringiendo con el tiempo, así que verificá los términos vigentes antes de contar con ella; (3) **canjear una reserva por un savings plan**, que es la salida de emergencia diseñada exactamente para este escenario; (4) **reembolso/cancelación**, sujeto a una comisión por terminación anticipada y a un tope anual por perfil de facturación; (5) **re-acotar** la reserva de una sola suscripción a compartida, para que cualquier otra carga de trabajo de la inscripción pueda absorber el beneficio. La lección: **hacé coincidir el horizonte del compromiso con el horizonte de estabilidad de la arquitectura.** Un compromiso a tres años sobre una plataforma que estás re-arquitecturando activamente es una apuesta contra tu propia hoja de ruta — preferí plazos de un año, o un savings plan, siempre que la forma del parque esté en movimiento.

### Bloque 9

**A38.** Sobreviven a `az group delete`: el **presupuesto con ámbito de suscripción** (`Microsoft.Consumption/budgets` en ámbito de suscripción), cualquier **asignación de directiva** en ámbito de suscripción o grupo de administración, las **asignaciones de rol**, las **reservas y savings plans**, los **planes de soporte**, los **grupos de administración**, y cualquier recurso que se haya creado en un grupo de recursos *distinto* (una bóveda de Recovery Services que guarda los backups de esta VM, un workspace de Log Analytics que recibe sus diagnósticos, una instantánea tomada en otro RG). La regla general: **eliminar un contenedor elimina solo lo que está adentro.** Todo lo que tenga un ámbito *por encima* del grupo de recursos, o cuyo hogar sea un grupo de recursos *distinto*, queda intacto — así que el desmantelamiento debe guiarse por ámbito, no por ubicación.

**A39.** Los registros de uso los genera el pipeline de medición, se agregan, se tarifan, y recién después afloran en Cost Management — un proceso que corre con un retraso de aproximadamente 8–24 horas, y la tarifación de algunos servicios (y los cargos de Marketplace) aterriza todavía más tarde. Las últimas horas que vivió un recurso se reportan por lo tanto *después* de que el recurso ya no existe. Para quien verifica que un incidente de costos terminó, esto significa que **una lectura de $0 hoy no es prueba**: tenés que volver a chequear las cifras diarias completas al menos 24–48 horas después de la eliminación, y confirmar en la factura siguiente. También significa que un post-mortem escrito el mismo día va a subestimar sistemáticamente el costo total del incidente.

**A40.** Una versión continua del paso 45: **Azure Policy** en ámbito de grupo de administración con un efecto `audit` (o `deny`) sobre discos no adjuntos e IPs públicas no asociadas, dándote una vista de cumplimiento persistente en vez de un script puntual; las recomendaciones Cost de **Azure Advisor** como el detector gestionado de recursos ociosos y subutilizados; **Azure Resource Graph** como motor de consultas (una sola consulta KQL sobre todas las suscripciones, de la cual el bucle del paso 45 es una imitación lenta); **Azure Automation** o una **Azure Function** con temporizador para actuar sobre los resultados, autenticada con una identidad administrada; **alertas / grupos de acciones de Azure Monitor** para notificar a los dueños — enrutadas por la etiqueta `owner`, que es por qué la taxonomía de etiquetas del bloque 5 es estructural acá; y **bloqueos de recursos** más un período de gracia para que la remediación nunca borre algo que un humano está a mitad de construir. Detectá ampliamente, notificá primero, eliminá solo después de una ventana de antigüedad.

</details>

---

## Fuentes

- [AZ-900 study guide — skills measured](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
- [What is Microsoft Cost Management and Billing?](https://learn.microsoft.com/en-us/azure/cost-management-billing/cost-management-billing-overview)
- [Understand and work with Cost Management scopes](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes)
- [Understand cost management data (latency, actual vs amortized)](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data)
- [Tutorial: create and manage budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Use cost alerts to monitor usage and spending](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/cost-mgt-alerts-monitor-usage-spending)
- [Create and manage exported data](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports)
- [Azure Retail Prices REST API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Use tags to organize your Azure resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources)
- [Tag support for Azure resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support)
- [Group and allocate costs using tag inheritance](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance)
- [Azure Policy built-in policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies)
- [Save money with Azure Reservations](https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations)
- [Azure savings plan for compute](https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview)
- [Azure Hybrid Benefit](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing)
- [Azure Spot Virtual Machines](https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms)
- [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/) · [TCO Calculator](https://azure.microsoft.com/en-us/pricing/tco/calculator/) · [Azure Migrate business case](https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation)
- [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) · [Managed Disks pricing](https://azure.microsoft.com/en-us/pricing/details/managed-disks/)