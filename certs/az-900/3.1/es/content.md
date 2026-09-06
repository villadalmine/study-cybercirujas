# 3.1 — Describir la gestión de costos en Azure

**Examen:** AZ-900 (Microsoft Azure Fundamentals), versión del temario 2026-07-20
**Dominio:** 3 — Describir la gestión y el gobierno de Azure
**Peso:** 8.33 %
**Nivel:** Platform Architect / SRE — profundidad de producción

---

## 1. El problema de producción: el costo es un lazo de control, no un informe

Todo equipo de SRE descubre tarde o temprano que el gasto en la nube se comporta exactamente igual que la latencia o la tasa de errores: es una **señal emitida por un sistema distribuido**, se desvía, tiene picos y nadie lo nota hasta que alguien de afuera del equipo se queja. La diferencia es que una regresión de p99 se ve en segundos, mientras que una regresión de costo se ve en **8 a 24 horas** — porque esa es la latencia del pipeline entre el momento en que un recurso emite un registro de uso y el momento en que ese registro aterriza en Microsoft Cost Management.

Esa latencia define toda la arquitectura del gobierno de costos en Azure. Concretamente:

```
resource emits usage  ──►  metering pipeline  ──►  Cost Management store  ──►  budget evaluation
      t=0                    t + minutes            t + 8..24 h                t + 8..24 h + eval
```

Un pool de GPU `Standard_ND96asr_v4` descontrolado que arrancó a las 02:00 no va a aparecer en una alerta de budget hasta la tarde siguiente. Para entonces ya quemó aproximadamente 12 horas × ~€25/h × 8 nodos ≈ **€2,400**. Ningún budget lo va a haber frenado, porque **los budgets en Azure no frenan nada**: emiten una notificación. Esta es la verdad de producción más importante de este objetivo, y también la pregunta de examen que más se falla.

### 1.1 Los tres modos de falla que este objetivo existe para prevenir

| Modo de falla | Síntoma en producción | Causa arquitectónica raíz | Mitigación cubierta acá |
|---|---|---|---|
| **Gasto no atribuible** | La factura es de €180k, finanzas pregunta qué producto la genera, nadie puede responder | Los tags *no* se heredan del resource group ni de la subscription por defecto; los registros de uso llevan solo los tags presentes en el momento de la emisión | Taxonomía de tags + Azure Policy `Modify` + **tag inheritance** de Cost Management |
| **Deriva silenciosa** | El gasto crece 4 %/mes sin que ningún deploy lo explique | Ningún budget basado en forecast, ninguna detección de anomalías, ningún export diario hacia un almacén consultable | Umbrales de budget con forecast + `scheduledActions` (InsightAlert) + exports FOCUS |
| **Decisión de compra equivocada** | Un equipo se compromete 3 años de Reserved Instances sobre una carga de trabajo que se refactoriza en 9 meses | Se usa la Pricing Calculator como si fuera un forecast; no hay vista de costo amortizado; no hay telemetría de utilización | Separación Pricing Calculator vs TCO vs Cost Management, vista amortizada, utilización de reservations |

### 1.2 Dónde se ubica el costo en la arquitectura de la plataforma

La gestión de costos es un **plano de recursos de extensión** superpuesto al plano de recursos de ARM. No vive dentro del data path de tu subscription; lee el stream de medición fuera de banda. Eso tiene dos consecuencias que un arquitecto debe internalizar:

1. **Cost Management se acota por la jerarquía de facturación, no solo por la jerarquía de ARM.** Algunos scopes (billing account, billing profile, invoice section) no existen en ARM en absoluto.
2. **Los datos de costo son historia inmutable.** No se puede re-etiquetar retroactivamente un registro de uso emitido el mes pasado etiquetando el recurso hoy — con una excepción estrecha y deliberadamente diseñada (tag inheritance, solo el mes de facturación actual).

---

## 2. La jerarquía de facturación: el sustrato al que todo lo demás se enlaza

Antes de que cualquier herramienta tenga sentido, hace falta el modelo de scopes. Las operaciones de Cost Management toman un **scope string**, y saber cuál pasar es el 80 % de la depuración de "por qué esta API devuelve 404".

```
Billing account  (EA enrollment | MCA billing account | MOSP)
└── Department / Billing profile          ← invoice is generated here (MCA)
    └── Enrollment account / Invoice section
        └── Subscription                   ← ARM root for most teams
            └── Management group (crosses subscriptions, ARM-only)
            └── Resource group
                └── Resource               ← emits usage records
```

### 2.1 Scope strings que vas a escribir de verdad

| Scope | Scope string | Cost analysis | Budgets | Exports | Notas |
|---|---|---|---|---|---|
| Subscription | `/subscriptions/{subId}` | ✅ | ✅ | ✅ | El scope de trabajo por defecto |
| Resource group | `/subscriptions/{subId}/resourceGroups/{rg}` | ✅ | ✅ | ✅ | La unidad más barata de asignación dura |
| Management group | `/providers/Microsoft.Management/managementGroups/{mgId}` | ✅ | ✅ | ✅ | Solo EA/MCA; no para MOSP |
| EA billing account | `/providers/Microsoft.Billing/billingAccounts/{enrollmentId}` | ✅ | ✅ | ✅ | Requiere enterprise admin |
| EA department | `/providers/Microsoft.Billing/billingAccounts/{id}/departments/{deptId}` | ✅ | ✅ | ✅ | |
| EA enrollment account | `/providers/Microsoft.Billing/billingAccounts/{id}/enrollmentAccounts/{eaId}` | ✅ | ✅ | ✅ | |
| MCA billing profile | `/providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{pId}` | ✅ | ✅ | ✅ | Frontera de facturación |
| MCA invoice section | `.../billingProfiles/{pId}/invoiceSections/{sId}` | ✅ | ✅ | ✅ | |

### 2.2 Tipos de acuerdo y qué cambia cada uno

| Acuerdo | Quién lo firma | Mecanismo de precio | Disponibilidad de Cost Management | Diferencia operativa clave |
|---|---|---|---|---|
| **Microsoft Customer Agreement (MCA)** | Directo con Microsoft, autoservicio o vía comercial | Negociado / de lista | Completa, incluidos los scopes de billing account | El default moderno; las invoice sections dan fronteras duras de chargeback |
| **Enterprise Agreement (EA)** | Organización grande, compromiso a 3 años | Compromiso monetario prepago + overage | Completa, scopes de department/enrollment | Legado pero está en todos lados; `enrollmentId` es la billing account |
| **Pay-as-you-go (MOSP)** | Tarjeta de crédito / factura | Precio de lista público | Solo scopes de subscription + RG; **sin vistas de costo a nivel management group** | Está bien para labs, rompe el chargeback a escala |
| **Cloud Solution Provider (CSP)** | A través de un partner | Fijado por el partner | Mediada por el partner; el cliente ve datos con la forma que le da el partner | Puede que no veas los precios de lista reales de Microsoft en absoluto |

> **Trampa de examen:** "¿Qué tipo de subscription se requiere para ver costos en el scope de management group?" → EA o MCA. Pay-as-you-go no puede.

---

## 3. Factores que afectan los costos en Azure

El examen pide *describirlos*. Un arquitecto tiene que *modelarlos*. Acá está el conjunto completo, ordenado por la frecuencia con la que cada uno hace explotar un presupuesto en el campo.

### 3.1 La lista canónica de factores

| # | Factor | Mecanismo | Magnitud típica de la sorpresa |
|---|---|---|---|
| 1 | **Tipo de recurso** | Cada tipo tiene sus propios meters (un `Microsoft.Compute/virtualMachines` factura vCPU-horas; un `Microsoft.CognitiveServices/accounts` factura tokens) | Estructural |
| 2 | **Consumo** | Medición por segundo / por hora / por GB / por operación | Estructural |
| 3 | **Mantenimiento y ciclo de vida** | Discos huérfanos, IPs públicas sin asociar, snapshots viejos, load balancers ociosos | **10–25 % de una subscription madura** |
| 4 | **Geografía (región)** | El mismo SKU difiere según la región: energía, inmuebles, impuestos locales, capacidad | 15–40 % entre, por ejemplo, `northeurope` y `brazilsouth` |
| 5 | **Tráfico de red** | Ingress gratis; egress medido por *bandwidth pricing zone*; inter-AZ e inter-región son meters separados | El ítem #1 que nunca se modela |
| 6 | **Tipo de subscription** | Free trial, Dev/Test, Sponsorship, CSP cambian el rate card efectivo | Hasta 100 % (financiado por créditos) |
| 7 | **Azure Marketplace** | Cargos de ISVs de terceros facturados a través de Azure pero **no cubiertos por commitments/créditos de Azure** | Silencioso — las RIs nunca aplican |
| 8 | **Tier de servicio / SKU** | Basic vs Standard vs Premium, LRS vs GRS vs RA-GZRS | 2–6× |
| 9 | **Modelo de compra** | PAYG vs Reservation vs Savings Plan vs Spot vs Hybrid Benefit | Hasta 90 % |
| 10 | **Plan de soporte** | Developer / Standard / Professional Direct / Unified — mensual fijo, meter separado | Fijo |

### 3.2 Egress de red: el factor que rompe toda estimación

El ingress hacia Azure es gratis. El egress no, y se mide sobre **tres ejes independientes** que la gente confunde:

| Patrón de tráfico | Familia de meters | ¿Se cobra? | Disparador arquitectónico habitual |
|---|---|---|---|
| Internet → Azure (ingress) | — | **Gratis** | — |
| Azure → Internet (egress) | Bandwidth, por pricing zone, escalonado | **Sí** (primeros 100 GB/mes gratis por billing account) | Servir media, pulls de imágenes de contenedor desde un registry público |
| VM ↔ VM, misma VNet, misma AZ | — | Gratis | — |
| VM ↔ VM, misma región, **distinta AZ** | Transferencia de datos inter-AZ | **Sí**, en ambas direcciones | Node pools de AKS zone-redundant charlando entre zonas |
| VM ↔ VM, distintas regiones | Egress inter-región | **Sí**, del lado origen | Georreplicación, sincronización de DR cross-region |
| VNet peering, misma región | Peering in/out | **Sí**, de ambos lados | Topologías hub-and-spoke |
| VNet peering, global (cross-region) | Global peering in/out, tarifa más alta | **Sí**, de ambos lados | Hub multirregión |
| A través de NAT Gateway | NAT por hora + por GB procesado, **encima del** egress | **Sí** | Clusters de AKS con egress controlado |
| A través de Azure Firewall | Firewall por hora + por GB procesado, **encima del** egress | **Sí** | Cualquier landing zone regulada |
| Private Endpoint | Endpoint por hora + por GB de entrada y salida | **Sí** | "Usamos Private Link para ahorrar plata" — no lo hace |

> **Antipatrón de producción:** un cluster de AKS zone-redundant con un service mesh charlatán y sin topology-aware routing paga transferencia inter-AZ sobre la mayoría del tráfico este-oeste. Habilitar `service.kubernetes.io/topology-mode` / topology-aware hints es una optimización de *costo* antes que de latencia.

### 3.3 Modelos de compra de cómputo — la tabla real de trade-offs

| Modelo | Descuento vs PAYG | Compromiso | Flexibilidad | ¿Cancelable? | SLA | Cuándo lo elige un SRE |
|---|---|---|---|---|---|---|
| **Pay-as-you-go** | 0 % (línea base) | Ninguno | Total | n/a | Completo | Cargas de trabajo con picos, desconocidas o de vida corta |
| **Reserved Instance (1 año)** | hasta ~40 % | 1 año, serie de VM + región específicas | Flexibilidad de tamaño de instancia *dentro* de una serie/región | Reembolso de autoservicio, con tope (~$50k / 12 meses móviles) y puede tener un cargo por terminación anticipada | Completo | Línea base estable con un SKU conocido |
| **Reserved Instance (3 años)** | hasta ~72 % | 3 años | Igual | Igual | Completo | Bases de datos, domain controllers, cualquier cosa que sabés que va a sobrevivir al plazo |
| **Azure Savings Plan for compute** | hasta ~65 % | **Compromiso en $** por hora, 1 o 3 años | Aplica a través de series de VM, regiones **y** servicios elegibles (VMs, App Service, Container Instances, Dedicated Hosts, Functions Premium) | **No** — no es cancelable, ni reembolsable, ni intercambiable | Completo | La flota es estable en *gasto* pero rota en *SKU* |
| **Spot VMs** | hasta ~90 % | Ninguno | Desalojable con 30 s de aviso; política de desalojo por capacidad o por precio | n/a | **Sin SLA** | Batch, runners de CI, node pools de AKS sin estado con PDBs |
| **Azure Hybrid Benefit** | hasta ~40 % (Windows Server), se apila con RI para SQL hasta ~85 % | Requiere **Software Assurance** o licencias por suscripción | Bring-your-own-licence | n/a | Completo | Cualquier parque Windows/SQL con licencias existentes |
| **Subscription Dev/Test** | Tarifas con descuento, **sin cargo de licencia Windows/SQL** | Requiere suscripción a Visual Studio | Solo uso no productivo | n/a | **Sin SLA** | Toda landing zone no productiva |

**Regla de decisión que un arquitecto puede defender:**

```
baseline that never scales to zero, SKU is frozen        → 3-yr Reserved Instance
baseline that never scales to zero, SKU churns           → Savings Plan (commit to the P10 of hourly spend)
burst above baseline, interruption-tolerant              → Spot
burst above baseline, interruption-intolerant            → Pay-as-you-go
Windows / SQL anywhere in the above                      → stack Azure Hybrid Benefit
```

Comprometé el **P10 de tu gasto por hora de los últimos 90 días**, nunca la media. Un commitment es un piso, y el commitment no usado es 100 % desperdicio sin ningún valor de rescate.

### 3.4 Leer el rate card programáticamente — la Azure Retail Prices API

Es gratis, no requiere autenticación, y es la única forma honesta de construir un modelo de costos interno. También es cómo verificás que lo que te mostró la Pricing Calculator es el precio de lista real.

```bash
$ curl -sG "https://prices.azure.com/api/retail/prices" \
    --data-urlencode "currencyCode=EUR" \
    --data-urlencode "\$filter=serviceName eq 'Virtual Machines' \
       and armRegionName eq 'westeurope' \
       and armSkuName eq 'Standard_D4s_v5' \
       and priceType eq 'Consumption' \
       and contains(productName, 'Windows') eq false" \
  | jq -r '.Items[] | [.armSkuName,.meterName,.retailPrice,.unitOfMeasure,.armRegionName] | @tsv'
```

```
Standard_D4s_v5   D4s v5          0.2131000   1 Hour   westeurope
Standard_D4s_v5   D4s v5 Spot     0.0271000   1 Hour   westeurope
Standard_D4s_v5   D4s v5 Low Pri  0.0426000   1 Hour   westeurope
```

Los precios de reservation vienen de la misma API con un `priceType` distinto:

```bash
$ curl -sG "https://prices.azure.com/api/retail/prices" \
    --data-urlencode "currencyCode=EUR" \
    --data-urlencode "\$filter=armSkuName eq 'Standard_D4s_v5' \
       and armRegionName eq 'westeurope' and priceType eq 'Reservation'" \
  | jq -r '.Items[] | [.armSkuName,.reservationTerm,.retailPrice,.unitOfMeasure] | @tsv'
```

```
Standard_D4s_v5   1 Year    1119.36000   1 Hour
Standard_D4s_v5   3 Years   2154.24000   1 Hour
```

> **Leé esa salida con cuidado.** `unitOfMeasure` dice `1 Hour` pero el `retailPrice` de una reservation es el **precio total del plazo por adelantado**. Esta inconsistencia produjo más dashboards internos equivocados que cualquier otro campo de Azure. Calculá vos mismo la tarifa horaria efectiva: `2154.24 / (3 × 8760) = €0.0820/h`, es decir **61.5 % menos** que la tarifa PAYG de €0.2131.

---

## 4. Pricing Calculator vs TCO Calculator

Ambas son herramientas de **estimación previa al despliegue**. Ninguna lee un solo byte de tu telemetría real. Responden preguntas distintas, y el examen evalúa exactamente esa distinción.

| Dimensión | **Azure Pricing Calculator** | **Total Cost of Ownership (TCO) Calculator** |
|---|---|---|
| Pregunta que responde | "¿Cuánto va a costar por mes *este diseño de Azure*?" | "¿Cuánto *ahorro* al migrar de on-premises a Azure?" |
| Dirección | Prospectiva, solo Azure | Comparativa, on-prem **vs** Azure |
| Entradas | Servicios de Azure, SKUs, regiones, cantidades, horas, plazo, tier de soporte, moneda | Servidores (CPU/RAM/SO/virtualización), bases de datos, volumen y tipo de almacenamiento, ancho de banda saliente, más **supuestos de costo** |
| ¿Modela costos **no Azure**? | ❌ No | ✅ Sí — hardware, licencias de software, electricidad, refrigeración, inmuebles de datacenter, mano de obra de IT |
| ¿Modela descuentos? | ✅ Reservations, savings plans, Azure Hybrid Benefit, Dev/Test, % de descuento estilo EA/MCA, planes de soporte | ⚠️ Gruesos, guiados por supuestos |
| Granularidad | Por SKU, por meter | Por categoría de carga de trabajo |
| Salida | Estimación mensual + anual; **export a XLSX**; link de estimación compartible/guardable | Informe comparativo de TCO multianual (típicamente 3–5 años), descargable |
| ¿Usa tus datos de uso reales? | ❌ No | ❌ No |
| ¿Requiere una subscription de Azure? | ❌ No (solo iniciar sesión para guardar) | ❌ No |
| Consumidor típico | Platform engineer dimensionando una landing zone | CFO / caso de negocio de migración |
| Clase de exactitud | **Precio de lista exacto por SKU**, dependiente de los supuestos de uso | **Direccional**, dependiente del modelo |

### 4.1 La separación de tres herramientas que tenés que poder enunciar en una línea

```
Pricing Calculator  →  what a design WILL cost      (hypothetical, Azure only)
TCO Calculator      →  what migrating WOULD save    (hypothetical, on-prem vs Azure)
Cost Management     →  what you ARE spending        (actual, measured, historical + forecast)
```

> **Moneda e impuestos:** ambas calculadoras producen **estimaciones de precio de lista antes de impuestos** en la moneda seleccionada. No incluyen tu descuento EA/MCA negociado salvo que lo ingreses manualmente, y nunca incluyen impuestos. Cost Management muestra tanto `Cost` (moneda de facturación) como `CostUSD`.

> **Nota de estado (verificar antes de enseñar):** Microsoft retiró la página independiente de la TCO Calculator y ahora orienta los casos de negocio de migración hacia la funcionalidad **Azure Migrate business case**, que — a diferencia de la TCO Calculator — *sí* ingiere inventario y utilización on-premises descubiertos reales. La guía de estudio de AZ-900 todavía lista la TCO Calculator como ítem de examen, así que conocé la comparación de arriba para el examen y conocé el Azure Migrate business case para el trabajo. Revisá la URL de la guía de estudio en §10 para ver la redacción vigente antes de apoyarte en esto.

---

## 5. Microsoft Cost Management

Microsoft Cost Management (expuesto en el portal como **Cost Management + Billing**) es el plano de medición y control. Importan cinco capacidades.

### 5.1 Cost analysis — y la distinción actual/amortizado

`Cost analysis` es un motor de consultas sobre el almacén de uso con vistas: costo acumulado, costo diario, costo por servicio, costo por recurso, detalles de factura. La dimensión por la que agrupás es lo que determina si la respuesta es útil — agrupar por `ResourceGroupName` es el reflejo por defecto; agrupar por un **tag** `cost-center` es el que responde la pregunta de finanzas.

El control que más se malinterpreta es el selector de métrica:

| Métrica | La compra de reservation aparece como | El uso de VM cubierto por reservation aparece como | Cómo se ve el commitment no usado | Usala para responder |
|---|---|---|---|---|
| **Actual cost** | Una suma única en la fecha de compra | **€0.00** | Invisible (ya pagado) | "Conciliar contra la factura" |
| **Amortized cost** | Distribuido de forma pareja entre todos los días del plazo | La porción amortizada diaria, atribuida al recurso que consume | Una línea explícita `UnusedReservation` | "¿Cuánto cuesta realmente cada equipo?" |

Ambas vistas suman el mismo total **a lo largo del plazo completo de la reservation**, nunca sobre un solo mes. Un modelo de chargeback construido sobre Actual cost le va a facturar la reservation entera de 3 años a un equipo desafortunado en el mes uno.

```bash
$ az extension add --name costmanagement --upgrade
$ SUB=$(az account show --query id -o tsv)

$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="ServiceName" type="Dimension" \
    -o json | jq -r '.rows[] | @tsv' | sort -t$'\t' -k1 -rn | head -8
```

```
18422.71	Virtual Machines	EUR
 9310.05	Azure Kubernetes Service	EUR
 6188.40	Storage	EUR
 4402.19	Azure Database for PostgreSQL	EUR
 3971.66	Bandwidth	EUR
 2044.83	Azure Firewall	EUR
 1512.90	Log Analytics	EUR
  880.12	UnusedReservation	EUR
```

Esa última línea — `UnusedReservation` — es puro desperdicio, y **solo es visible en la vista amortizada**. €880 en un mes son €10.5k/año de commitment que compraste y nunca consumiste.

Agrupar por tag en lugar de por servicio:

```bash
$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe TheLastMonth \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="cost-center" type="TagKey" \
    -o table
```

```
Cost           CostCenter     Currency
-------------  -------------  ----------
24880.44       CC-4471        EUR
11209.68       CC-2210        EUR
 6640.02       CC-9003        EUR
 3402.11                      EUR      <-- untagged: your allocation gap
```

La fila en blanco es la métrica que importa. **El gasto sin tags como porcentaje del total** es el KPI de madurez del gobierno de costos; una plataforma sana lo mantiene por debajo del 2 %.

### 5.2 Budgets — notificación, no aplicación

Un budget es un umbral monetario (o de cantidad de uso) acotado a un scope, con hasta **cinco reglas de notificación**. Cada regla tiene un `thresholdType`:

- `Actual` — se dispara cuando el gasto medido cruza el umbral. Siempre llega tarde por la ventana de latencia de datos.
- `Forecasted` — se dispara cuando la proyección de Azure para el período cruza el umbral. Esta es la que te da margen de anticipación, y es la que la mayoría de los equipos nunca configura.

Los budgets pueden filtrar por dimensiones (`ResourceGroupName`, `ResourceType`, `MeterCategory`, …) y por tags.

**Los budgets no limitan, no detienen, no desasignan ni bloquean nada.** Para obtener aplicación real, conectás los `contactGroups` del budget a un Action Group que dispare un runbook de Automation, una Logic App o una Function — §6.1 muestra el manifiesto completo.

### 5.3 Exports y la Cost Details API

Para cualquier cosa más allá de consultas ad-hoc en el portal necesitás los registros de uso crudos en tu propio almacén.

| Mecanismo | Forma | Cadencia | Mejor para |
|---|---|---|---|
| **Scheduled export** a una storage account | CSV/Parquet, opcionalmente particionado y comprimido con gzip | Diaria / semanal / mensual, o una sola vez | El data lake de FinOps. Esta es la respuesta de producción. |
| **FOCUS dataset export** | FinOps Open Cost & Usage Specification v1.x — nombres de columna neutrales respecto del proveedor | Igual | Unificación multi-nube; un esquema para Azure + AWS + GCP |
| **Cost Details API** (`generateCostDetailsReport`) | Job asíncrono → blob firmado con SAS | Bajo demanda | Backfill, conciliación |
| `az consumption usage list` | JSON paginado | Bajo demanda | Scopes chicos, chequeos rápidos. **No** lo uses para extracciones EA de un mes completo — va a paginar durante horas |
| **Conector de Power BI** de Cost Management | Modelo semántico | Refresco programado | Reportes ejecutivos |

Vale la pena destacar FOCUS: renombra las columnas específicas de Azure a un vocabulario compartido (`BilledCost`, `EffectiveCost`, `ChargePeriodStart`, `ResourceId`, `ServiceCategory`, `x_SkuMeterName`…). Si tu organización usa más de una nube, exportar FOCUS en lugar del esquema nativo de Azure es la diferencia entre un dashboard y tres.

### 5.4 Detección de anomalías y Advisor

- **Las alertas de anomalía de costo** (`Microsoft.CostManagement/scheduledActions`, `kind: InsightAlert`) corren un modelo no supervisado sobre el gasto diario de la subscription y envían un email cuando un día se desvía del patrón aprendido. Scope de subscription, sin configuración de sensibilidad — gratis, y vale la pena habilitarlas en toda subscription desde el día uno.
- **Azure Advisor → Cost** produce recomendaciones accionables: redimensionar o apagar VMs infrautilizadas, borrar IPs públicas sin asociar / discos ociosos, comprar reservations o savings plans según el uso observado, borrar load balancers ociosos y circuitos ExpressRoute. Las recomendaciones de reservation de Advisor se calculan a partir de tus **últimos 7/30/60 días reales** — es la única herramienta nativa de Microsoft en este objetivo que se guía por telemetría en lugar de supuestos.

### 5.5 RBAC de Cost Management

| Rol | Puede leer costos | Puede crear budgets/exports | Puede ver los recursos de ARM | Notas |
|---|---|---|---|---|
| **Cost Management Reader** | ✅ | ❌ | ❌ | Dáselo a finanzas. No filtra metadatos de recursos más allá de los nombres |
| **Cost Management Contributor** | ✅ | ✅ | ❌ | Dáselo a la identidad de la plataforma de FinOps |
| **Reader** | ✅ (hereda) | ❌ | ✅ | |
| **Contributor / Owner** | ✅ | ✅ | ✅ | |
| **Roles de billing account** (EA admin, MCA Billing profile owner/contributor/reader/invoice manager) | ✅ por encima de la subscription | ✅ | ❌ | Plano separado; el RBAC de ARM **no** los otorga |

Nunca hardcodees GUIDs de roles — resolvelos:

```bash
$ az role definition list --name "Cost Management Reader" --query "[].name" -o tsv
72fafb9e-0641-4937-9268-a91bfd8191a3

$ az role definition list --name "Tag Contributor" --query "[].name" -o tsv
4a9ae827-6dc8-4573-8ac7-8239d42aa03f
```

> **Nota sobre multi-nube:** el conector de AWS de Cost Management fue retirado. La unificación multi-nube ahora se hace exportando **FOCUS** desde cada proveedor hacia un lake compartido, no con un conector dentro del portal.

---

## 6. Tags: el propósito, y la mecánica que nadie lee

Un tag es un par de strings `name: value` adjunto a una subscription, un resource group o un recurso. Su **propósito** son las operaciones guiadas por metadatos: asignación de costos y chargeback, propiedad y enrutamiento de guardias, clasificación de entornos, targeting de automatización (anillos de parcheo, agendas de apagado), clasificación de seguridad/cumplimiento, y ciclo de vida (fechas de expiración para infraestructura efímera).

### 6.1 Límites duros y comportamientos que causan caídas del tipo *costo*

| Propiedad | Valor / comportamiento | Consecuencia |
|---|---|---|
| Tags por recurso / RG / subscription | **50** | Un esquema de un tag por microservicio choca contra el muro |
| Longitud del **nombre** del tag | 512 caracteres (**128** para storage accounts) | |
| Longitud del **valor** del tag | 256 caracteres | Los patrones de JSON-en-un-tag se truncan en silencio |
| Caracteres prohibidos en nombres | `< > % & \ ? /` | Un `Modify` de Policy con un nombre inválido falla en la remediación, no en la asignación |
| Sensibilidad a mayúsculas | Los nombres son **insensibles** a mayúsculas para la búsqueda, y **preservan** las mayúsculas al escribir. Los valores son **sensibles** a mayúsculas | `Prod` y `prod` son dos filas en cost analysis |
| Herencia | **Ninguna.** Los recursos **no** heredan tags del RG ni de la subscription | La causa #1 del balde de recursos sin tags |
| Recursos clásicos (ASM) | No soportan tags en absoluto | |
| Recursos fuera de un resource group | No pueden ser etiquetados | |
| Aparición en los datos de costo | Solo los recursos que **emiten registros de uso** llevan tags al costo. Los tags de un resource group no aparecen en los registros de uso de los recursos hijos | Etiquetar el RG "para costos" no hace nada por defecto |
| Retroactividad | Etiquetar un recurso hoy **no** re-etiqueta los registros de uso de ayer | El backfill es imposible por la vía del plano de recursos |

### 6.2 La única escotilla de escape retroactiva: tag inheritance de Cost Management

Cost Management tiene una configuración por scope (**Cost Management → Settings → Manage tag inheritance**, EA y MCA) que copia los tags de nivel subscription y resource group sobre los **registros de uso** de los recursos hijos durante la ingesta. Dos propiedades la hacen estratégicamente importante:

1. Se aplica **retroactivamente hasta el comienzo del mes de facturación actual** al habilitarse.
2. Es configurable para que gane el **tag del recurso** por sobre el tag heredado, o para que gane el heredado.

**No** modifica los recursos en sí — solo los registros de costo. Combinala con Azure Policy: Policy arregla el plano de recursos hacia adelante, tag inheritance arregla el plano de costos de inmediato.

### 6.3 Los tres efectos de Azure Policy para tags, y cuándo corresponde cada uno

| Efecto | Ejemplo de policy integrada | Comportamiento | Recursos existentes | Usalo cuando |
|---|---|---|---|---|
| `Deny` | *Require a tag on resources* | Bloquea la creación/actualización sin el tag | Marcados como no conformes, sin tocar | Landing zone greenfield, día 0 |
| `Modify` | *Inherit a tag from the resource group* | Agrega/reemplaza el tag; soporta **remediation tasks** sobre recursos existentes | **Pueden arreglarse** vía remediación | Parque brownfield — este es el que querés |
| `Append` | *Inherit a tag from the resource group if missing* | Agrega el tag solo al crear/actualizar; **sin remediación** | Sin tocar | Legado; preferí `Modify` |
| `Audit` | *Require a tag and its value on resources* (variante de auditoría) | Solo reporta | Reportados | Fase de medición, antes de aplicar |

Resolvé los IDs de las definiciones integradas en lugar de confiar en un GUID copiado:

```bash
$ az policy definition list --query \
  "[?policyType=='BuiltIn' && contains(displayName,'tag')].{name:name, display:displayName, effect:policyRule.then.effect}" \
  -o table | head -12
```

```
Name                                  Display                                             Effect
------------------------------------  --------------------------------------------------  ------------------
871b6d14-10aa-478d-b590-94f262ecfa99  Require a tag on resources                          deny
1e30110a-5ceb-460c-a204-c1c3969c6d62  Require a tag and its value on resources            deny
96670d01-0a4d-4649-9c89-2d3abc0a5025  Require a tag on resource groups                    deny
cd3aa116-8754-49c9-a813-ad46512ece54  Inherit a tag from the resource group               modify
40df99da-1232-49b1-a39a-6da8d878f469  Inherit a tag from the subscription                 modify
4f9dc7db-30c1-420c-b61a-e1d640128d26  Add or replace a tag on resources                   modify
```

### 6.4 Una taxonomía de tags que sobrevive a una auditoría

```
cost-center      required   ^CC-[0-9]{4}$              → chargeback key, matches the finance ledger
owner            required   ^[a-z0-9._%-]+@corp\.tld$  → a group mailbox, never a person
env              required   prod | staging | dev | sandbox
service          required   ^[a-z][a-z0-9-]{2,31}$     → matches the service catalogue ID
data-class       required   public | internal | confidential | restricted
managed-by       required   terraform | bicep | portal | manual
expires-on       optional   ^\d{4}-\d{2}-\d{2}$        → sandbox reaper reads this
```

Reglas que la hacen funcionar: **menos de 8 tags obligatorios** (la gente derrota las listas largas), **claves en kebab-case minúscula** (los valores son sensibles a mayúsculas; que las claves sean consistentes evita columnas duplicadas), **valores enumerados forzados por policy** (el texto libre destruye el agrupamiento), y **`owner` siempre es un grupo**.

---

## 7. Manifiestos de infraestructura completos

### 7.1 Bicep — el stack completo de gobierno de costos en el scope de subscription

`cost-governance.bicep`:

```bicep
// ---------------------------------------------------------------------------
// Cost governance baseline for one subscription:
//   action group -> budget (actual + forecast) -> anomaly alert
//   storage account -> daily FOCUS export
//   policy assignments -> deny untagged, inherit cost-center from RG
// Deploy:  az deployment sub create -l westeurope -f cost-governance.bicep -p @cost-governance.params.json
// ---------------------------------------------------------------------------
targetScope = 'subscription'

@description('Environment discriminator used in every resource name.')
@allowed(['prod', 'staging', 'dev'])
param env string = 'prod'

@description('Location for the regional resources created by this template.')
param location string = 'westeurope'

@description('Monthly budget ceiling in the billing currency of the subscription.')
@minValue(1)
param monthlyBudgetAmount int = 25000

@description('First day of the month the budget starts, UTC, format yyyy-MM-dd. Must be the 1st.')
param budgetStartDate string

@description('Budget end date, UTC, format yyyy-MM-dd. Max 10 years out.')
param budgetEndDate string

@description('Mailbox that receives every cost notification. Use a group, never a person.')
param finopsDistributionList string

@description('Cost centres accepted by the tag policy.')
param allowedCostCentres array = [
  'CC-4471'
  'CC-2210'
  'CC-9003'
]

var suffix          = '${env}-${location}'
var rgName          = 'rg-finops-${suffix}'
var storageName     = take(replace('stfinops${env}${uniqueString(subscription().id)}', '-', ''), 24)
var exportContainer = 'costexports'

// Built-in role and policy definition IDs. Resolve with:
//   az role definition list --name "Tag Contributor" --query [].name -o tsv
//   az policy definition list --query "[?displayName=='Inherit a tag from the resource group'].name" -o tsv
var tagContributorRoleId       = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var policyInheritTagFromRgId   = 'cd3aa116-8754-49c9-a813-ad46512ece54'
var policyRequireTagOnResource = '871b6d14-10aa-478d-b590-94f262ecfa99'

// ---------------------------------------------------------------------------
// 1. Container resource group for the FinOps plumbing
// ---------------------------------------------------------------------------
resource finopsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name:     rgName
  location: location
  tags: {
    'cost-center': 'CC-9003'
    owner:         finopsDistributionList
    env:           env
    service:       'finops-platform'
    'data-class':  'internal'
    'managed-by':  'bicep'
  }
}

// ---------------------------------------------------------------------------
// 2. Storage account that receives the cost exports
// ---------------------------------------------------------------------------
module exportStorage 'modules/export-storage.bicep' = {
  name:  'deploy-export-storage'
  scope: finopsRg
  params: {
    storageAccountName: storageName
    location:           location
    containerName:      exportContainer
    tagSet: {
      'cost-center': 'CC-9003'
      owner:         finopsDistributionList
      env:           env
      service:       'finops-platform'
      'data-class':  'confidential'
      'managed-by':  'bicep'
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Action group. Budgets can only notify; enforcement lives behind this.
// ---------------------------------------------------------------------------
module costActionGroup 'modules/action-group.bicep' = {
  name:  'deploy-cost-action-group'
  scope: finopsRg
  params: {
    actionGroupName: 'ag-cost-${suffix}'
    shortName:       'costalert'
    emailAddress:    finopsDistributionList
  }
}

// ---------------------------------------------------------------------------
// 4. Budget. Five notification rules is the hard maximum.
//    thresholdType Forecasted is what gives you lead time; Actual is history.
// ---------------------------------------------------------------------------
resource subscriptionBudget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: 'bd-${suffix}-monthly'
  properties: {
    category:  'Cost'
    amount:    monthlyBudgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '${budgetStartDate}T00:00:00Z'
      endDate:   '${budgetEndDate}T00:00:00Z'
    }
    notifications: {
      Forecast_GreaterThan_100_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     100
        thresholdType: 'Forecasted'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Forecast_GreaterThan_120_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     120
        thresholdType: 'Forecasted'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Actual_GreaterThan_50_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     50
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        locale:        'en-us'
      }
      Actual_GreaterThan_80_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     80
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
      Actual_GreaterThan_100_Percent: {
        enabled:       true
        operator:      'GreaterThan'
        threshold:     100
        thresholdType: 'Actual'
        contactEmails: [ finopsDistributionList ]
        contactRoles:  [ 'Owner' ]
        contactGroups: [ costActionGroup.outputs.actionGroupId ]
        locale:        'en-us'
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 5. Daily FOCUS 1.0 export into the storage account.
//    FocusCost gives vendor-neutral column names; use it if you touch >1 cloud.
// ---------------------------------------------------------------------------
resource focusExport 'Microsoft.CostManagement/exports@2023-08-01' = {
  name: 'ex-${suffix}-focus-daily'
  properties: {
    format:                'Csv'
    partitionData:         true
    compressionMode:       'gzip'
    dataOverwriteBehavior: 'OverwritePreviousReport'
    schedule: {
      status:     'Active'
      recurrence: 'Daily'
      recurrencePeriod: {
        from: '${budgetStartDate}T02:00:00Z'
        to:   '${budgetEndDate}T02:00:00Z'
      }
    }
    deliveryInfo: {
      destination: {
        resourceId:     exportStorage.outputs.storageAccountId
        container:      exportContainer
        rootFolderPath: 'focus/${env}'
      }
    }
    definition: {
      type:      'FocusCost'
      timeframe: 'MonthToDate'
      dataSet: {
        granularity: 'Daily'
        configuration: {
          dataVersion: '1.0'
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 6. Cost anomaly alert. Unsupervised, free, subscription scope only.
// ---------------------------------------------------------------------------
resource anomalyAlert 'Microsoft.CostManagement/scheduledActions@2023-08-01' = {
  name: 'sa-${suffix}-anomaly'
  kind: 'InsightAlert'
  properties: {
    displayName: 'Daily cost anomaly - ${env}'
    status:      'Enabled'
    viewId:      '/providers/Microsoft.CostManagement/views/ms:DailyAnomalyByResourceGroup'
    notification: {
      to:      [ finopsDistributionList ]
      subject: '[${toUpper(env)}] Azure cost anomaly detected'
    }
    schedule: {
      frequency:  'Daily'
      startDate:  '${budgetStartDate}T06:00:00Z'
      endDate:    '${budgetEndDate}T06:00:00Z'
    }
  }
}

// ---------------------------------------------------------------------------
// 7. Deny resources created without a cost-center tag.
//    Deny does NOT fix what already exists - see the Modify assignment below.
// ---------------------------------------------------------------------------
resource denyUntagged 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'pa-require-cost-center'
  properties: {
    displayName:        'Require cost-center tag on all resources'
    description:        'Blocks creation of resources without a cost-center tag. Cost allocation depends on it.'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyRequireTagOnResource)
    enforcementMode:    'Default'
    parameters: {
      tagName: {
        value: 'cost-center'
      }
    }
    nonComplianceMessages: [
      {
        message: 'Every resource must carry a cost-center tag matching CC-nnnn. See the platform tagging standard.'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 8. Modify assignment: inherit cost-center from the resource group.
//    Modify needs a managed identity AND a role assignment, or remediation
//    fails with "The client ... does not have authorization to perform action".
// ---------------------------------------------------------------------------
resource inheritCostCenter 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name:     'pa-inherit-cost-center'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName:        'Inherit cost-center tag from the resource group'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyInheritTagFromRgId)
    enforcementMode:    'Default'
    parameters: {
      tagName: {
        value: 'cost-center'
      }
    }
  }
}

resource inheritTagRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, 'pa-inherit-cost-center', tagContributorRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleId)
    principalId:      inheritCostCenter.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

output budgetId          string = subscriptionBudget.id
output exportId          string = focusExport.id
output actionGroupId     string = costActionGroup.outputs.actionGroupId
output remediationTarget string = inheritCostCenter.id
output storageAccountId  string = exportStorage.outputs.storageAccountId
```

`modules/export-storage.bicep`:

```bicep
@description('Globally unique storage account name, 3-24 lowercase alphanumeric characters.')
@minLength(3)
@maxLength(24)
param storageAccountName string

param location string
param containerName string
param tagSet object

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name:     storageAccountName
  location: location
  tags:     tagSet
  sku: {
    // LRS is deliberate: cost exports are reproducible from the Cost Details API.
    // Paying for GRS on regenerable data is exactly the waste this stack exists to find.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier:                   'Cool'
    minimumTlsVersion:            'TLS1_2'
    allowBlobPublicAccess:        false
    allowSharedKeyAccess:         true   // Cost Management exports require key-based write
    supportsHttpsTrafficOnly:     true
    publicNetworkAccess:          'Enabled'
    networkAcls: {
      bypass:        'AzureServices'   // the export service writes through the trusted-services path
      defaultAction: 'Deny'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name:   'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days:    30
    }
  }
}

resource exportsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name:   containerName
  properties: {
    publicAccess: 'None'
  }
}

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name:   'default'
  properties: {
    policy: {
      rules: [
        {
          name:    'archive-then-expire-cost-exports'
          enabled: true
          type:    'Lifecycle'
          definition: {
            filters: {
              blobTypes:   [ 'blockBlob' ]
              prefixMatch: [ '${containerName}/focus' ]
            }
            actions: {
              baseBlob: {
                tierToCool:    { daysAfterModificationGreaterThan: 30 }
                tierToArchive: { daysAfterModificationGreaterThan: 120 }
                delete:        { daysAfterModificationGreaterThan: 1095 }
              }
            }
          }
        }
      ]
    }
  }
}

output storageAccountId   string = storage.id
output storageAccountName string = storage.name
```

`modules/action-group.bicep`:

```bicep
@description('Action group resource name.')
param actionGroupName string

@description('1-12 character short name used as the SMS/email prefix.')
@maxLength(12)
param shortName string

param emailAddress string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name:     actionGroupName
  location: 'Global'   // action groups are always Global
  properties: {
    groupShortName: shortName
    enabled:        true
    emailReceivers: [
      {
        name:                 'finops-dl'
        emailAddress:         emailAddress
        useCommonAlertSchema: true
      }
    ]
    // Enforcement hook. A budget notification alone changes nothing;
    // this webhook is where a Logic App / Function deallocates the offender.
    azureFunctionReceivers: []
    webhookReceivers:       []
    logicAppReceivers:      []
  }
}

output actionGroupId string = actionGroup.id
```

`cost-governance.params.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "env":                     { "value": "prod" },
    "location":                { "value": "westeurope" },
    "monthlyBudgetAmount":     { "value": 25000 },
    "budgetStartDate":         { "value": "2026-09-01" },
    "budgetEndDate":           { "value": "2029-09-01" },
    "finopsDistributionList":  { "value": "finops-platform@corp.tld" },
    "allowedCostCentres":      { "value": ["CC-4471", "CC-2210", "CC-9003"] }
  }
}
```

### 7.2 Azure Policy personalizada — forzar la *forma* del valor de cost-center

La integrada `Require a tag on resources` solo verifica la presencia. Los valores de texto libre destruyen el agrupamiento en cost analysis, así que forzá la enumeración.

`policy-cost-center-allowed-values.json`:

```json
{
  "properties": {
    "displayName": "Require a cost-center tag with an approved value",
    "policyType": "Custom",
    "mode": "Indexed",
    "description": "Denies creation or update of any indexed resource whose cost-center tag is absent or is not one of the approved cost centres. Free-text cost centres fragment the cost-allocation report and cannot be reconciled against the finance ledger.",
    "metadata": {
      "version": "1.2.0",
      "category": "Tags",
      "source": "platform-team"
    },
    "parameters": {
      "allowedCostCentres": {
        "type": "Array",
        "metadata": {
          "displayName": "Allowed cost centres",
          "description": "Exact list of cost-centre codes accepted by finance."
        }
      },
      "effect": {
        "type": "String",
        "defaultValue": "Deny",
        "allowedValues": ["Audit", "Deny", "Disabled"],
        "metadata": {
          "displayName": "Effect",
          "description": "Start at Audit, measure the non-compliance count, then flip to Deny."
        }
      },
      "exemptResourceTypes": {
        "type": "Array",
        "defaultValue": [
          "Microsoft.Resources/deploymentScripts",
          "Microsoft.Insights/actionGroups"
        ],
        "metadata": {
          "displayName": "Exempt resource types",
          "description": "Types that are created implicitly by other services and cannot be tagged at create time."
        }
      }
    },
    "policyRule": {
      "if": {
        "allOf": [
          {
            "field": "type",
            "notIn": "[parameters('exemptResourceTypes')]"
          },
          {
            "anyOf": [
              {
                "field": "tags['cost-center']",
                "exists": "false"
              },
              {
                "field": "tags['cost-center']",
                "notIn": "[parameters('allowedCostCentres')]"
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

Prestá atención a `"mode": "Indexed"` — restringe la evaluación a los tipos de recurso que soportan tags y location, que es exactamente lo que querés para una policy de tags. `"mode": "All"` también evaluaría resource groups y subscriptions y generaría ruido que no podés remediar.

### 7.3 Terraform — el mismo stack

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

locals {
  env      = "prod"
  location = "westeurope"

  # Applied to every resource this module creates. default_tags does not exist
  # in azurerm the way it does in the AWS provider, so merge it explicitly.
  common_tags = {
    "cost-center" = "CC-9003"
    "owner"       = "finops-platform@corp.tld"
    "env"         = local.env
    "service"     = "finops-platform"
    "data-class"  = "internal"
    "managed-by"  = "terraform"
  }
}

resource "azurerm_resource_group" "finops" {
  name     = "rg-finops-${local.env}-${local.location}"
  location = local.location
  tags     = local.common_tags
}

resource "azurerm_monitor_action_group" "cost" {
  name                = "ag-cost-${local.env}-${local.location}"
  resource_group_name = azurerm_resource_group.finops.name
  short_name          = "costalert"
  tags                = local.common_tags

  email_receiver {
    name                    = "finops-dl"
    email_address           = "finops-platform@corp.tld"
    use_common_alert_schema = true
  }
}

resource "azurerm_storage_account" "exports" {
  name                            = "stfinops${local.env}${substr(sha1(data.azurerm_subscription.current.id), 0, 8)}"
  resource_group_name             = azurerm_resource_group.finops.name
  location                        = azurerm_resource_group.finops.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Cool"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = merge(local.common_tags, { "data-class" = "confidential" })

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "exports" {
  name                  = "costexports"
  storage_account_id    = azurerm_storage_account.exports.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Budget. Notifications only - nothing here stops a single VM from running.
# ---------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "bd-${local.env}-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = 25000
  time_grain      = "Monthly"

  time_period {
    # Must be the first day of a month, UTC, and no more than three months in the past.
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2029-09-01T00:00:00Z"
  }

  # Scope the budget to the workload resource groups so the platform's own
  # FinOps overhead does not consume the product team's allowance.
  filter {
    dimension {
      name = "ResourceGroupName"
      values = [
        "rg-platform-prod-weu",
        "rg-data-prod-weu",
        "rg-aks-prod-weu",
      ]
    }
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
    contact_roles  = ["Owner"]
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = ["finops-platform@corp.tld"]
    contact_groups = [azurerm_monitor_action_group.cost.id]
    contact_roles  = ["Owner"]
  }
}

# ---------------------------------------------------------------------------
# Daily cost export
# ---------------------------------------------------------------------------
resource "azurerm_subscription_cost_management_export" "daily" {
  name                         = "ex-${local.env}-daily"
  subscription_id              = data.azurerm_subscription.current.id
  recurrence_type              = "Daily"
  recurrence_period_start_date = "2026-09-01T02:00:00Z"
  recurrence_period_end_date   = "2029-09-01T02:00:00Z"
  active                       = true

  export_data_storage_location {
    container_id     = azurerm_storage_container.exports.resource_manager_id
    root_folder_path = "azure/${local.env}"
  }

  export_data_options {
    type       = "Usage"
    time_frame = "MonthToDate"
  }
}

# ---------------------------------------------------------------------------
# Tag policy: audit first, deny second. Never ship Deny on day one.
# ---------------------------------------------------------------------------
resource "azurerm_policy_definition" "cost_center_allowed" {
  name         = "require-cost-center-allowed-values"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require a cost-center tag with an approved value"

  metadata = jsonencode({
    version  = "1.2.0"
    category = "Tags"
  })

  parameters = jsonencode({
    allowedCostCentres = {
      type     = "Array"
      metadata = { displayName = "Allowed cost centres" }
    }
    effect = {
      type          = "String"
      defaultValue  = "Audit"
      allowedValues = ["Audit", "Deny", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      anyOf = [
        { field = "tags['cost-center']", exists = "false" },
        { field = "tags['cost-center']", notIn = "[parameters('allowedCostCentres')]" }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "cost_center_allowed" {
  name                 = "pa-cost-center-allowed"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_definition.cost_center_allowed.id
  display_name         = "Require an approved cost-center tag"
  enforce              = true

  parameters = jsonencode({
    allowedCostCentres = { value = ["CC-4471", "CC-2210", "CC-9003"] }
    effect             = { value = "Audit" }
  })

  non_compliance_message {
    content = "Every resource must carry cost-center = one of CC-4471, CC-2210, CC-9003."
  }
}

# ---------------------------------------------------------------------------
# Modify assignment needs an identity, a location, and a role assignment.
# Omit any of the three and remediation fails with an authorization error.
# ---------------------------------------------------------------------------
resource "azurerm_subscription_policy_assignment" "inherit_cost_center" {
  name                 = "pa-inherit-cost-center"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/cd3aa116-8754-49c9-a813-ad46512ece54"
  display_name         = "Inherit cost-center from the resource group"
  location             = local.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    tagName = { value = "cost-center" }
  })
}

resource "azurerm_role_assignment" "inherit_cost_center_tagger" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Tag Contributor"
  principal_id         = azurerm_subscription_policy_assignment.inherit_cost_center.identity[0].principal_id
}

output "budget_id"        { value = azurerm_consumption_budget_subscription.monthly.id }
output "export_id"        { value = azurerm_subscription_cost_management_export.daily.id }
output "policy_to_remediate" { value = azurerm_subscription_policy_assignment.inherit_cost_center.id }
```

### 7.4 Kubernetes — asignar el costo de AKS a los namespaces

Un cluster de AKS llega a Cost Analysis como un puñado de líneas enormes (`Virtual Machines`, `Managed Disks`, `Load Balancer`, `Bandwidth`) **sin visibilidad de qué namespace las causó**. Dos formas de arreglarlo.

**Opción A — el add-on de cost analysis de AKS** (gestionado por Microsoft, basado en OpenCost, requiere tier de cluster Standard o Premium):

```bash
$ az aks update \
    --resource-group rg-aks-prod-weu \
    --name aks-prod-weu \
    --tier standard \
    --enable-cost-analysis
```

```
 \ Running ..
{
  "metricsProfile": {
    "costAnalysis": {
      "enabled": true
    }
  },
  "name": "aks-prod-weu",
  "provisioningState": "Succeeded",
  "sku": {
    "name": "Base",
    "tier": "Standard"
  }
}
```

```bash
$ az aks show -g rg-aks-prod-weu -n aks-prod-weu \
    --query "{tier:sku.tier, costAnalysis:metricsProfile.costAnalysis.enabled}" -o table
```

```
Tier      CostAnalysis
--------  --------------
Standard  True
```

Después de esto, Cost Analysis gana las dimensiones `Kubernetes Namespace`, `Kubernetes Cluster`, `Kubernetes Controller` y `Kubernetes Label` para ese cluster. Los datos empiezan a fluir solo hacia adelante — esperá hasta 24 h antes de que aparezcan las primeras filas a nivel de namespace.

**Opción B — OpenCost autoalojado** (portable entre nubes, y la base sobre la que está construido el add-on):

`opencost.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: opencost
  labels:
    cost-center: CC-9003
    env: prod
    service: finops-platform
    # AKS cost analysis reads namespace labels; keep them identical to the
    # Azure tag taxonomy so a single grouping key works on both sides.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: opencost
  namespace: opencost
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: opencost
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - nodes
      - pods
      - services
      - resourcequotas
      - replicationcontrollers
      - limitranges
      - persistentvolumeclaims
      - persistentvolumes
      - namespaces
      - endpoints
      - events
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "deployments", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: opencost
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: opencost
subjects:
  - kind: ServiceAccount
    name: opencost
    namespace: opencost
---
apiVersion: v1
kind: Secret
metadata:
  name: azure-service-principal
  namespace: opencost
type: Opaque
stringData:
  # Read-only principal used to pull the Azure rate card. Grant it
  # Cost Management Reader at the subscription scope and nothing else.
  service-key.json: |
    {
      "subscriptionId": "REPLACE_WITH_SUBSCRIPTION_ID",
      "serviceKey": {
        "appId": "REPLACE_WITH_APP_ID",
        "displayName": "sp-opencost-ratecard",
        "password": "REPLACE_VIA_EXTERNAL_SECRETS",
        "tenant": "REPLACE_WITH_TENANT_ID"
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opencost
  namespace: opencost
  labels:
    app.kubernetes.io/name: opencost
    app.kubernetes.io/component: cost-model
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: opencost
  template:
    metadata:
      labels:
        app.kubernetes.io/name: opencost
        app.kubernetes.io/component: cost-model
    spec:
      serviceAccountName: opencost
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: opencost
          image: ghcr.io/opencost/opencost:1.114.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 9003
            - name: metrics
              containerPort: 9090
          env:
            - name: PROMETHEUS_SERVER_ENDPOINT
              value: "http://prometheus-server.monitoring.svc.cluster.local:80"
            - name: CLOUD_PROVIDER_API_KEY
              value: "azure"
            - name: CLUSTER_ID
              value: "aks-prod-weu"
            - name: AZURE_OFFER_DURABLE_ID
              value: "MS-AZR-0003p"
            - name: AZURE_BILLING_ACCOUNT
              valueFrom:
                secretKeyRef:
                  name: azure-service-principal
                  key: service-key.json
                  optional: true
            - name: LOG_LEVEL
              value: "info"
          volumeMounts:
            - name: azure-key
              mountPath: /var/secrets
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 999m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9003
            initialDelaySeconds: 30
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9003
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: azure-key
          secret:
            secretName: azure-service-principal
---
apiVersion: v1
kind: Service
metadata:
  name: opencost
  namespace: opencost
  labels:
    app.kubernetes.io/name: opencost
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: opencost
  ports:
    - name: http
      port: 9003
      targetPort: 9003
    - name: metrics
      port: 9090
      targetPort: 9090
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: opencost
  namespace: opencost
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: opencost
  endpoints:
    - port: metrics
      interval: 60s
      scrapeTimeout: 30s
      honorLabels: true
```

Consultar la asignación:

```bash
$ kubectl -n opencost port-forward svc/opencost 9003:9003 >/dev/null 2>&1 &
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace&accumulate=true" \
  | jq -r '.data[0] | to_entries[] | [.key, (.value.totalCost|tostring)] | @tsv' \
  | sort -k2 -rn | head
```

```
checkout-api	318.4471
search-index	204.9930
kube-system	 88.1204
ingress-nginx	 61.7710
monitoring	 55.3392
opencost	  1.9084
```

---

## 8. Referencia de CLI — comandos y salida real

### 8.1 Bootstrap y scope

```bash
$ az login --tenant corp.onmicrosoft.com --only-show-errors >/dev/null
$ az account set --subscription "platform-prod-weu"
$ SUB=$(az account show --query id -o tsv)
$ echo "$SUB"
7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10

$ az account show -o table
```

```
Name                 CloudName    SubscriptionId                        TenantId                              State    IsDefault
-------------------  -----------  ------------------------------------  ------------------------------------  -------  -----------
platform-prod-weu    AzureCloud   7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10  3a1b7e05-9c44-4f2e-8a7d-6b1c0e4f8d33  Enabled  True
```

### 8.2 Desplegar el stack de gobierno

```bash
$ az deployment sub create \
    --name cost-governance-$(git rev-parse --short HEAD) \
    --location westeurope \
    --template-file cost-governance.bicep \
    --parameters @cost-governance.params.json \
    --query "properties.{state:provisioningState, outputs:outputs}" -o json
```

```json
{
  "state": "Succeeded",
  "outputs": {
    "actionGroupId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../resourceGroups/rg-finops-prod-westeurope/providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope"
    },
    "budgetId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.Consumption/budgets/bd-prod-westeurope-monthly"
    },
    "exportId": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.CostManagement/exports/ex-prod-westeurope-focus-daily"
    },
    "remediationTarget": {
      "type": "String",
      "value": "/subscriptions/7f2b9a4c-.../providers/Microsoft.Authorization/policyAssignments/pa-inherit-cost-center"
    }
  }
}
```

Siempre corré `what-if` primero en un despliegue con scope de subscription:

```bash
$ az deployment sub what-if \
    --location westeurope \
    --template-file cost-governance.bicep \
    --parameters @cost-governance.params.json \
    --result-format FullResourcePayloads | head -20
```

```
Note: The result may contain false positive predictions (noise).

Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify
  = NoChange

The deployment will update the following scope:

Scope: /subscriptions/7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10

  = Microsoft.Resources/resourceGroups/rg-finops-prod-westeurope

  ~ Microsoft.Consumption/budgets/bd-prod-westeurope-monthly
    ~ properties.amount: 22000 => 25000

  + Microsoft.CostManagement/scheduledActions/sa-prod-westeurope-anomaly
```

### 8.3 Budgets

```bash
$ az consumption budget list --query "[].{name:name, amount:amount, spent:currentSpend.amount, currency:currentSpend.unit, grain:timeGrain}" -o table
```

```
Name                        Amount    Spent      Currency    Grain
--------------------------  --------  ---------  ----------  -------
bd-prod-westeurope-monthly  25000     18442.71   EUR         Monthly
bd-data-platform-monthly    8000       6905.33   EUR         Monthly
```

El comando `az consumption budget create` no puede adjuntar action groups. Cuando necesitás uno fuera de IaC, hacé PUT del recurso directamente:

```bash
$ cat > /tmp/budget.json <<'JSON'
{
  "properties": {
    "category": "Cost",
    "amount": 25000,
    "timeGrain": "Monthly",
    "timePeriod": {
      "startDate": "2026-09-01T00:00:00Z",
      "endDate":   "2029-09-01T00:00:00Z"
    },
    "filter": {
      "and": [
        { "dimensions": { "name": "ResourceGroupName", "operator": "In",
                          "values": ["rg-aks-prod-weu", "rg-data-prod-weu"] } },
        { "tags":       { "name": "env", "operator": "In", "values": ["prod"] } }
      ]
    },
    "notifications": {
      "Forecast_GreaterThan_100_Percent": {
        "enabled": true, "operator": "GreaterThan", "threshold": 100,
        "thresholdType": "Forecasted",
        "contactEmails": ["finops-platform@corp.tld"],
        "contactGroups": ["/subscriptions/7f2b9a4c-1de8-4d6b-b0a1-3c8e5f9d2a10/resourceGroups/rg-finops-prod-westeurope/providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope"],
        "locale": "en-us"
      }
    }
  }
}
JSON

$ az rest --method put \
    --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Consumption/budgets/bd-prod-westeurope-monthly?api-version=2023-05-01" \
    --body @/tmp/budget.json \
    --query "{name:name, amount:properties.amount, spent:properties.currentSpend.amount}" -o json
```

```json
{
  "amount": 25000.0,
  "name": "bd-prod-westeurope-monthly",
  "spent": 18442.71
}
```

### 8.4 Consultar el gasto

Tendencia diaria del mes actual:

```bash
$ az costmanagement query \
    --type ActualCost \
    --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate \
    --dataset-granularity Daily \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    -o json | jq -r '.rows[] | "\(.[1])  \(.[0]|tostring|.[0:8])  \(.[2])"'
```

```
20260901  4321.09   EUR
20260902  4488.77   EUR
20260903  4402.13   EUR
20260904  5230.72   EUR      <-- +18.8 % day over day
```

Los diez recursos más caros del mes pasado:

```bash
$ az costmanagement query \
    --type AmortizedCost \
    --scope "/subscriptions/$SUB" \
    --timeframe TheLastMonth \
    --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="ResourceId" type="Dimension" \
    -o json | jq -r '.rows | sort_by(-.[0])[:10][] | "\(.[0]|floor)\t\(.[1]|split("/")|last)"'
```

```
6114	aks-prod-weu-agentpool-gpu
3902	pgflex-orders-prod
2880	afw-hub-weu
1744	law-platform-prod
1502	aks-prod-weu-agentpool-sys
 988	st-media-prod-weu
 771	lbi-ingress-prod
 640	vgw-hub-expressroute
 512	kv-platform-prod
 480	acr-platform-prod
```

Registros de uso crudos de un día:

```bash
$ az consumption usage list \
    --start-date 2026-09-04 --end-date 2026-09-04 \
    --query "[?pretaxCost > \`50\`].{meter:meterDetails.meterName, cat:meterDetails.meterCategory, qty:usageQuantity, cost:pretaxCost, res:instanceName}" \
    -o table | head
```

```
Meter                Cat                          Qty      Cost     Res
-------------------  ---------------------------  -------  -------  --------------------------
NC24ads A100 v4      Virtual Machines             192.0    719.04   aks-prod-weu-gpu-vmss_3
Data Transfer Out    Bandwidth                    2210.4   184.33   afw-hub-weu
P30 Disks            Storage                      24.0     102.72   pgflex-orders-prod-data
Data Ingestion       Azure Monitor                418.9     91.87   law-platform-prod
Standard Data Proc   Azure Firewall               1180.2    88.51   afw-hub-weu
```

### 8.5 Operaciones con tags

```bash
$ RID=$(az aks show -g rg-aks-prod-weu -n aks-prod-weu --query id -o tsv)

$ az tag update --resource-id "$RID" --operation Merge \
    --tags cost-center=CC-4471 owner=sre-platform@corp.tld env=prod \
           service=container-platform data-class=internal managed-by=terraform \
    --query "properties.tags" -o json
```

```json
{
  "cost-center": "CC-4471",
  "data-class": "internal",
  "env": "prod",
  "managed-by": "terraform",
  "owner": "sre-platform@corp.tld",
  "service": "container-platform"
}
```

`Merge` agrega/actualiza y deja los demás en paz. `Replace` borra todo lo que no esté listado. `Delete` elimina los pares listados. Usar `Replace` en un script masivo es la forma en que los parques pierden todo su conjunto de tags en un solo comando.

Encontrá la brecha de asignación con Azure Resource Graph:

```bash
$ az extension add --name resource-graph --upgrade
$ az graph query -q "
Resources
| extend cc = tostring(tags['cost-center'])
| summarize total = count(), untagged = countif(isempty(cc)) by type
| extend pct = round(100.0 * untagged / total, 1)
| where untagged > 0
| order by untagged desc
| project type, total, untagged, pct
" --first 10 -o table
```

```
Type                                          Total    Untagged    Pct
--------------------------------------------  -------  ----------  -----
microsoft.compute/disks                       412      389         94.4
microsoft.network/networkinterfaces           188       88         46.8
microsoft.network/publicipaddresses            64       41         64.1
microsoft.compute/snapshots                    97       97        100.0
microsoft.insights/components                  22        9         40.9
```

`microsoft.compute/disks` con 94 % sin tags es la firma clásica: los managed disks son creados *por* el resource provider de VMs y no heredan nada.

> **Gotcha:** Azure Resource Graph es **sensible a mayúsculas en las claves de tags** aunque la API de tags de ARM sea insensible en la búsqueda. `tags['cost-center']` y `tags['Cost-Center']` son propiedades distintas en ARG. Normalizá en la consulta:
> ```kusto
> | extend cc = tostring(bag_pack_columns(tags)['cost-center'])
> ```
> o la versión pragmática: `| extend cc = coalesce(tostring(tags['cost-center']), tostring(tags['Cost-Center']), tostring(tags['costCenter']))`. Después arreglá el origen y forzá minúsculas por policy.

### 8.6 Cumplimiento de policies y remediación

```bash
$ az policy state summarize --query \
  "value[0].policyAssignments[].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" \
  -o table 2>/dev/null | sed 's#/subscriptions/[^/]*/providers/Microsoft.Authorization/policyAssignments/##'
```

```
Assignment                  NonCompliant
--------------------------  --------------
pa-cost-center-allowed      1046
pa-inherit-cost-center       389
```

Remediar la asignación `Modify` sobre el parque existente:

```bash
$ az policy remediation create \
    --name rem-inherit-cost-center-$(date -u +%Y%m%dT%H%M%SZ) \
    --policy-assignment pa-inherit-cost-center \
    --resource-discovery-mode ExistingNonCompliant \
    --query "{name:name, state:provisioningState, mode:resourceDiscoveryMode}" -o table
```

```
Name                                        State       Mode
------------------------------------------  ----------  ----------------------
rem-inherit-cost-center-20260905T081200Z    Accepted    ExistingNonCompliant
```

```bash
$ az policy remediation show \
    --name rem-inherit-cost-center-20260905T081200Z \
    --query "{state:provisioningState, total:deploymentSummary.totalDeployments, ok:deploymentSummary.successfulDeployments, failed:deploymentSummary.failedDeployments}" -o table
```

```
State      Total    Ok    Failed
---------  -------  ----  --------
Succeeded  389      386   3
```

```bash
$ az policy remediation deployment list \
    --name rem-inherit-cost-center-20260905T081200Z \
    --query "[?status!='Succeeded'].{res:remediatedResourceId, status:status, err:error.message}" -o json
```

```json
[
  {
    "err": "The resource type 'Microsoft.ClassicCompute/domainNames' does not support tags.",
    "res": "/subscriptions/7f2b.../providers/Microsoft.ClassicCompute/domainNames/legacy-app-01",
    "status": "Failed"
  }
]
```

### 8.7 Exports y Advisor

```bash
$ az costmanagement export list --scope "/subscriptions/$SUB" \
    --query "[].{name:name, type:definition.type, recurrence:schedule.recurrence, status:schedule.status, lastRun:runHistory.value[0].status}" -o table
```

```
Name                          Type        Recurrence    Status    LastRun
----------------------------  ----------  ------------  --------  ---------
ex-prod-westeurope-focus-dai  FocusCost   Daily         Active    Completed
```

```bash
$ az costmanagement export run \
    --scope "/subscriptions/$SUB" \
    --name ex-prod-westeurope-focus-daily
$ az storage blob list \
    --account-name stfinopsprod3f9a2c41 --container-name costexports \
    --prefix "focus/prod/" --auth-mode login \
    --query "[].{blob:name, mb:properties.contentLength, modified:properties.lastModified}" -o table | tail -3
```

```
Blob                                                              Mb        Modified
----------------------------------------------------------------  --------  -------------------------
focus/prod/20260901-20260930/part_0_0001.csv.gz                   18874368  2026-09-05T02:14:33+00:00
focus/prod/20260901-20260930/part_0_0002.csv.gz                   19011584  2026-09-05T02:14:41+00:00
focus/prod/20260901-20260930/manifest.json                            2841  2026-09-05T02:14:45+00:00
```

```bash
$ az advisor recommendation list --category Cost \
    --query "[].{impact:impact, problem:shortDescription.problem, res:impactedValue, savings:extendedProperties.annualSavingsAmount}" \
    -o table | head
```

```
Impact    Problem                                         Res                       Savings
--------  ----------------------------------------------  ------------------------  ---------
High      Right-size or shutdown underutilized VMs        vm-legacy-etl-01          3204.00
High      Buy a savings plan for compute and save         subscription              8811.40
Medium    Delete unattached public IP addresses           pip-orphan-weu-07          43.80
Medium    Delete or reconfigure idle load balancers       lb-legacy-internal          217.20
Low       Use lifecycle management on storage accounts    st-media-prod-weu          188.64
```

### 8.8 Un informe diario de FinOps como CI

`.github/workflows/finops-daily.yml`:

```yaml
name: finops-daily-report

on:
  schedule:
    # 07:00 UTC - after the overnight Cost Management refresh has landed.
    # Never schedule earlier: the previous day's data is not complete yet.
    - cron: "0 7 * * *"
  workflow_dispatch:

permissions:
  id-token: write      # OIDC federation to Azure, no stored secrets
  contents: read
  issues: write

env:
  AZURE_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  UNTAGGED_THRESHOLD_PCT: "2.0"

jobs:
  report:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id:       ${{ vars.AZURE_CLIENT_ID }}
          tenant-id:       ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Install Azure CLI extensions
        run: |
          az extension add --name costmanagement --upgrade --only-show-errors
          az extension add --name resource-graph --upgrade --only-show-errors

      - name: Month-to-date spend by cost centre
        id: spend
        run: |
          set -euo pipefail
          az costmanagement query \
            --type AmortizedCost \
            --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
            --timeframe MonthToDate \
            --dataset-granularity None \
            --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
            --dataset-grouping name="cost-center" type="TagKey" \
            -o json > mtd.json
          jq -r '.rows[] | "| \(.[1] // "**UNTAGGED**") | \(.[0] | floor) \(.[2]) |"' mtd.json > table.md
          total=$(jq '[.rows[][0]] | add' mtd.json)
          untag=$(jq '[.rows[] | select((.[1] // "") == "")][0][0] // 0' mtd.json)
          pct=$(python3 -c "print(f'{100*${untag}/${total}:.2f}')")
          echo "pct=${pct}" >> "$GITHUB_OUTPUT"
          echo "total=${total}"  >> "$GITHUB_OUTPUT"

      - name: Fail if the untagged share exceeds the allocation SLO
        run: |
          pct="${{ steps.spend.outputs.pct }}"
          echo "Untagged share: ${pct}% (SLO: <= ${UNTAGGED_THRESHOLD_PCT}%)"
          awk -v a="$pct" -v b="$UNTAGGED_THRESHOLD_PCT" \
            'BEGIN { if (a+0 > b+0) { print "ALLOCATION SLO BREACHED"; exit 1 } }'

      - name: Orphaned resources sweep
        if: always()
        run: |
          az graph query -q "
            Resources
            | where type =~ 'microsoft.compute/disks' and properties.diskState == 'Unattached'
               or type =~ 'microsoft.network/publicipaddresses' and isnull(properties.ipConfiguration)
            | project name, type, resourceGroup, location, tags
            | order by type asc
          " --first 200 -o table | tee orphans.txt

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: finops-daily
          path: |
            mtd.json
            table.md
            orphans.txt
          retention-days: 90
```

---

## 9. Verificación y diagnóstico de fallas

### 9.1 La escalera de verificación

Corré esto en orden. Cada peldaño asume que el anterior pasó.

```bash
# 1. Can I read cost at all at this scope?
$ az costmanagement query --type ActualCost --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --query "rows[0]" -o tsv
18442.71	EUR

# 2. Does the budget exist and is it tracking?
$ az consumption budget show --budget-name bd-prod-westeurope-monthly \
    --query "{amount:amount, spent:currentSpend.amount, notifications:length(keys(notifications))}" -o json
{ "amount": 25000.0, "notifications": 5, "spent": 18442.71 }

# 3. Are the notifications actually wired to an action group?
$ az consumption budget show --budget-name bd-prod-westeurope-monthly \
    --query "notifications.*.contactGroups[]" -o tsv | sort -u
/subscriptions/7f2b.../providers/Microsoft.Insights/actionGroups/ag-cost-prod-westeurope

# 4. Does the action group deliver? (sends a real test notification)
$ az monitor action-group test-notifications create \
    --action-group-name ag-cost-prod-westeurope \
    --resource-group rg-finops-prod-westeurope \
    --alert-type budget \
    --email name=finops-dl email-address=finops-platform@corp.tld use-common-alert-schema=true \
    --query "{state:actionDetails[0].status, detail:actionDetails[0].detail}" -o table
State      Detail
---------  --------
Completed

# 5. Is the export producing bytes today?
$ az costmanagement export show --scope "/subscriptions/$SUB" \
    --name ex-prod-westeurope-focus-daily \
    --query "{status:schedule.status, lastRunStatus:runHistory.value[0].status, lastRunEnd:runHistory.value[0].processingEndTime}" -o json
{ "lastRunEnd": "2026-09-05T02:14:45Z", "lastRunStatus": "Completed", "status": "Active" }

# 6. Is the allocation gap inside SLO?
$ az costmanagement query --type AmortizedCost --scope "/subscriptions/$SUB" \
    --timeframe MonthToDate --dataset-granularity None \
    --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
    --dataset-grouping name="cost-center" type="TagKey" -o json \
  | jq -r '[.rows[]] as $r | ([$r[][0]]|add) as $t
           | ([$r[] | select((.[1]//"")=="")][0][0] // 0) as $u
           | "untagged: \($u|floor) of \($t|floor) = \((100*$u/$t)|.*100|round/100)%"'
untagged: 340 of 22186 = 1.53%
```

### 9.2 Catálogo de fallas

| Síntoma | Causa raíz más probable | Diagnóstico | Solución |
|---|---|---|---|
| Cost analysis muestra **€0.00** para una subscription que claramente tiene recursos | El uso todavía no fue ingerido (subscription nueva < 24 h), o estás mirando una subscription **Free Trial / patrocinada** donde los cargos se absorben con créditos | `az consumption usage list --start-date <yesterday> --end-date <yesterday> --query "length(@)"` | Esperá 24 h; verificá `az account show --query "state"` y el ID de la oferta |
| `(NotFound) The specified scope was not found` desde una llamada de Cost Management | Scope string equivocado — con más frecuencia `resourcegroups` vs `resourceGroups`, o un scope de management group sobre una subscription Pay-as-you-go | Imprimí el scope; comparalo contra §2.1 | Corregí las mayúsculas; actualizá el acuerdo si se requiere scope de MG |
| `(AuthorizationFailed)` en `az costmanagement query` pero el portal funciona | La identidad tiene `Reader` de ARM pero la consulta está en un scope de **facturación**, que el RBAC de ARM no cubre | `az role assignment list --assignee <id> --all -o table` | Otorgá el rol de facturación EA/MCA en **Cost Management + Billing**, no en IAM |
| El budget existe, el gasto pasó el 100 %, **no llegó ningún email** | (a) `enabled: false` en la notificación; (b) el tenant del destinatario lo filtra; (c) el gasto cruzó *antes* del último refresco de datos, así que la evaluación no corrió; (d) el `filter` del budget excluye los resource groups que realmente gastaron | Pasos 2–4 de §9.1 | Enviá una notificación de prueba; ampliá o quitá el filtro; agregá una regla `Forecasted` para tener anticipación |
| El budget se disparó pero **no se apagó nada** | Funciona según diseño. Los budgets nunca aplican nada | — | Conectá el action group a una Logic App / runbook de Automation / Function que desasigne o aplique un lock `ReadOnly` |
| Se compró una reservation, pero la VM sigue mostrando el costo completo | Estás en **Actual cost**, no en Amortized; o el **scope** de la reservation es otra subscription; o el SKU/región de la VM no coincide con la reservation | Cambiá la métrica a Amortized; `az reservations reservation-order list` y revisá `appliedScopes` | Cambiá el scope de la reservation a `Shared` o a la subscription correcta |
| Un cargo grande aparece una vez y nunca más | Una compra de **reservation o de Marketplace** en la vista Actual cost | Agrupá por `PublisherType` / `ChargeType` | Usá la vista Amortized para la asignación; Actual solo para conciliar facturas |
| El gasto sin tags se dispara después de un deploy | Un tipo de recurso que el RP crea implícitamente (discos, NICs, IPs públicas, el node resource group en AKS) | La consulta de ARG en §8.5 | Agregá una policy `Modify` por tipo huérfano; para AKS configurá los tags del node resource group vía `--node-resource-group-tags` / `nodeResourceGroupProfile` |
| Etiquetaste el recurso, pero el costo del mes pasado sigue sin asignar | Los tags aplican a los registros de uso **desde el momento del etiquetado en adelante**. La historia es inmutable | Compará `Cost analysis` agrupado por el tag entre dos meses | Habilitá **tag inheritance** en la configuración de Cost Management — cubre retroactivamente solo el mes de facturación actual. Los meses previos están perdidos |
| Dos filas `prod` y `Prod` en cost analysis | Los **valores** de los tags son sensibles a mayúsculas | `az graph query -q "Resources \| distinct tostring(tags['env'])"` | Normalizá con una policy `Modify` usando `addOrReplace`; forzá una policy de valores permitidos enumerados |
| La asignación de policy `Modify` figura como conforme pero los tags nunca aparecen | Falta la managed identity, falta `location` en la asignación, falta el role assignment, o nunca creaste una **remediation task** (`Modify` arregla recursos nuevos/actualizados; los existentes necesitan remediación) | `az policy assignment show --name pa-inherit-cost-center --query "{id:identity.principalId, loc:location}"` | Agregá `identity`, `location`, el role assignment `Tag Contributor`, y después `az policy remediation create` |
| La remediación reporta `Failed` en algunos recursos | El tipo de recurso no soporta tags (clásico/ASM), o está bloqueado | `az policy remediation deployment list ... --query "[?status!='Succeeded']"` | Exceptuá el tipo en la policy; quitá temporalmente el lock `CanNotDelete`/`ReadOnly` |
| El contenedor de blobs del export está vacío | Storage con `networkAcls.defaultAction = Deny` sin `bypass: AzureServices`; o el acceso con shared key deshabilitado; o la ventana de agenda del export (`recurrencePeriod.from/to`) expiró | `az costmanagement export show --query "runHistory.value[0]"` | Poné `bypass: AzureServices`, `allowSharedKeyAccess: true`, extendé el período de recurrencia |
| Los números del export de costo ≠ la factura | Comparás **Amortized** contra una factura (las facturas son Actual), o comparás pre-impuestos contra post-impuestos, o columna de moneda equivocada (`Cost` vs `CostUSD`) | Volvé a correrlo con `--type ActualCost`; revisá `BillingCurrency` | Conciliá Actual↔factura; usá Amortized solo para chargeback interno |
| Las dimensiones de namespace de AKS nunca aparecen en Cost Analysis | El cluster está en el tier **Free**; el add-on requiere Standard o Premium | `az aks show --query "{tier:sku.tier, ca:metricsProfile.costAnalysis.enabled}"` | `az aks update --tier standard --enable-cost-analysis`, después esperá hasta 24 h |
| El forecast en Cost Analysis se ve absurdo | El modelo de forecast necesita historia; una subscription nueva o una compra puntual de reservation lo sesgan mucho | Mirá la serie diaria en §8.4 | Ignorá los forecasts durante los primeros ~30 días; excluí `ChargeType = Purchase` de la vista |
| `az consumption usage list` se cuelga o da timeout | Pagina todos los registros de uso en el scope EA; un enrollment grande son millones de filas | — | Usá `az costmanagement query` con agregación, o un export programado |

### 9.3 Hacer que un budget realmente aplique algo

Como esta es la brecha en la que todo el mundo cae, el camino de aplicación completo:

```
Budget (Actual > 100%)
  └─► contactGroups → Action Group
        └─► webhook / Azure Function / Logic App / Automation runbook
              ├─ tag the offending RG  lifecycle=frozen
              ├─ apply a ReadOnly management lock
              ├─ deallocate VMs where env != prod
              └─ scale AKS node pools to their minimum
```

Reglas de seguridad razonables para esa automatización: **nunca** actuar sobre `env=prod` sin un humano en el lazo; actuar solo sobre recursos que lleven `env in (dev, sandbox)`; hacer que la acción sea **reversible** (desasignar, no borrar; lock `ReadOnly`, no `CanNotDelete`); y emitir un evento de auditoría para que el ingeniero de guardia sepa por qué un cluster de dev desapareció a las 03:00.

---

## 10. Compresión enfocada en el examen

Afirmaciones que deberías poder producir textualmente:

- **El ingress es gratis; el egress se cobra.** El ingress hacia un datacenter de Azure no cuesta nada.
- **Los budgets notifican, no detienen el gasto.** La aplicación requiere automatización detrás de un action group.
- **Los tags no se heredan.** Un recurso no obtiene automáticamente los tags de su resource group. Azure Policy arregla eso.
- **La Pricing Calculator estima un diseño futuro de Azure; la TCO Calculator compara on-premises contra Azure a lo largo de varios años, incluyendo costos no-Azure como energía, refrigeración, inmuebles y mano de obra. Ninguna usa tu uso real. Cost Management reporta el gasto real.**
- **Reservations = 1 o 3 años sobre un tipo de recurso/región específicos, hasta ~72 % de descuento. Savings plans = 1 o 3 años sobre un monto en dólares por hora, más flexible, hasta ~65 % de descuento, no cancelable. Spot = hasta ~90 % de descuento, desalojable, sin SLA. Azure Hybrid Benefit = reutilizar licencias existentes de Windows Server / SQL Server con Software Assurance.**
- **Un scope de costo a nivel management group requiere un acuerdo EA o MCA.** Pay-as-you-go no puede.
- **Cost Management Reader** es el rol de mínimo privilegio para alguien que debe ver costos y nada más.
- **La categoría Cost de Azure Advisor** es donde viven las recomendaciones de right-sizing, recursos ociosos y compra de reservations.
- **La región afecta el precio** para el mismo SKU.
- **Los cargos de Marketplace / ISVs de terceros no están cubiertos por las reservations de Azure ni por los créditos de Azure.**

Distractores que aparecen repetidamente:

| Afirmación | Veredicto |
|---|---|
| "Un budget puede apagar recursos automáticamente cuando se excede." | **Falso** — solo notifica |
| "Los tags aplicados a un resource group son heredados por sus recursos." | **Falso** |
| "Los datos transferidos hacia Azure se cobran." | **Falso** — el ingress es gratis |
| "La TCO Calculator muestra tu gasto actual en Azure." | **Falso** — es una comparación hipotética on-prem vs Azure |
| "Las Reserved Instances requieren un pago por adelantado." | **Falso** — hay pago mensual disponible al mismo precio total |
| "Las Spot VMs tienen SLA." | **Falso** |
| "Necesitás una subscription para usar la Pricing Calculator." | **Falso** |
| "Azure Hybrid Benefit funciona sin Software Assurance." | **Falso** |
| "Cost Management puede mostrar el costo agrupado por tag." | **Verdadero** — y ese es el punto de etiquetar |

---

## Referencias

**Certificación y examen**
- Guía de estudio de AZ-900 (lista autoritativa de objetivos): https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Página del examen Azure Fundamentals: https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Cost Management**
- Hub de documentación de Microsoft Cost Management: https://learn.microsoft.com/en-us/azure/cost-management-billing/
- Entender los datos de Cost Management (latencia, cadencia de refresco, cobertura de datasets): https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data
- Quickstart — explorar y analizar costos con Cost analysis: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/quick-acm-cost-analysis
- Entender y trabajar con scopes: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes
- Asignar acceso a los datos de Cost Management: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/assign-access-acm-data
- Crear y administrar budgets: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
- Gestionar costos con automatización (action groups, runbooks, Logic Apps): https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/manage-automation
- Crear y administrar datos exportados: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports
- Datos de costo y uso FOCUS en Cost Management: https://learn.microsoft.com/en-us/azure/cost-management-billing/dataset-schema/schema-index
- Identificar anomalías y cambios inesperados en el costo: https://learn.microsoft.com/en-us/azure/cost-management-billing/understand/analyze-unexpected-charges
- Agrupar y asignar costos usando tag inheritance: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/enable-tag-inheritance
- Crear y administrar reglas de asignación de costos de Azure: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/allocate-costs

**Precios, estimación y modelos de compra**
- Azure Pricing Calculator: https://azure.microsoft.com/en-us/pricing/calculator/
- Azure Total Cost of Ownership (TCO) Calculator: https://azure.microsoft.com/en-us/pricing/tco/calculator/
- Construir un caso de negocio con Azure Migrate: https://learn.microsoft.com/en-us/azure/migrate/concepts-business-case-calculation
- Azure Retail Prices API: https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
- Precios de ancho de banda (egress, inter-región, inter-AZ): https://azure.microsoft.com/en-us/pricing/details/bandwidth/
- Qué son las Azure Reservations: https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations
- Qué es Azure savings plans for compute: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview
- Decidir entre un savings plan y una reservation: https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/decide-between-savings-plan-reservation
- Usar Azure Spot Virtual Machines: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms
- Azure Hybrid Benefit: https://learn.microsoft.com/en-us/azure/cost-management-billing/scope-level/overview-azure-hybrid-benefit-scope
- Precios de Azure Dev/Test: https://azure.microsoft.com/en-us/pricing/dev-test/

**Tags y policy**
- Usar tags para organizar tus recursos de Azure y la jerarquía de administración: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
- Soporte de tags para recursos de Azure (límites por tipo): https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-support
- Asignar policies para el cumplimiento de tags: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-policies
- Efecto `Modify` de Azure Policy: https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify
- Remediar recursos no conformes: https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources
- Definir tu estrategia de nomenclatura y etiquetado (Cloud Adoption Framework): https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming-and-tagging-decision-guide

**Optimización y Kubernetes**
- Recomendaciones de costo de Azure Advisor: https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
- Azure Well-Architected Framework — pilar de Cost Optimization: https://learn.microsoft.com/en-us/azure/well-architected/cost-optimization/
- Add-on de cost analysis de AKS: https://learn.microsoft.com/en-us/azure/aks/cost-analysis
- Optimizar costos en Azure Kubernetes Service: https://learn.microsoft.com/en-us/azure/aks/best-practices-cost
- OpenCost (CNCF): https://www.opencost.io/docs/
- FinOps Open Cost and Usage Specification (FOCUS): https://focus.finops.org/

**Referencias de API y herramientas**
- Referencia de la CLI `az costmanagement`: https://learn.microsoft.com/en-us/cli/azure/costmanagement
- Referencia de la CLI `az consumption budget`: https://learn.microsoft.com/en-us/cli/azure/consumption/budget
- Referencia de la CLI `az tag`: https://learn.microsoft.com/en-us/cli/azure/tag
- Referencia ARM/Bicep de `Microsoft.Consumption/budgets`: https://learn.microsoft.com/en-us/azure/templates/microsoft.consumption/budgets
- Referencia ARM/Bicep de `Microsoft.CostManagement/exports`: https://learn.microsoft.com/en-us/azure/templates/microsoft.costmanagement/exports
- Referencia del lenguaje de consulta de Azure Resource Graph: https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language
- Terraform `azurerm_consumption_budget_subscription`: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_subscription