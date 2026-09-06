# Tema 3.4 — Describir las herramientas de monitorización en Azure

**Certificación:** AZ-900 (Microsoft Azure Fundamentals) · Versión del examen 2026-07-20
**Dominio:** 3 — Describir la administración y el gobierno de Azure · **Peso en el examen:** 8,33 %
**Formato:** laboratorio guiado. Ejecutás cada paso numerado; cada bloque cierra con preguntas de comprensión. Las respuestas están plegadas al final.

---

## Alcance de este tema

El temario del examen para 3.4 cubre cuatro superficies. Este laboratorio las trata como un único sistema de telemetría en lugar de cuatro páginas de características, porque en producción están conectadas entre sí:

| Superficie | Qué responde | Origen de los datos |
|---|---|---|
| **Azure Advisor** | "¿Es mi configuración una buena idea?" | Análisis derivado de la configuración de recursos + telemetría de la plataforma |
| **Azure Service Health** | "¿El problema soy yo o es Microsoft?" | Eventos redactados por la plataforma, acotados a tus suscripciones |
| **Azure Monitor** | "¿Qué está haciendo mi sistema, ahora mismo e históricamente?" | Almacén de métricas + Logs (workspace de Log Analytics) |
| **Application Insights** | "¿Por qué es lenta *esta petición*?" | SDK de APM / instrumentación automática, almacenado **en un workspace de Log Analytics** |

El hecho arquitectónico más importante de este tema — y el que más se pasa por alto a nivel fundamentals — es que **Application Insights no es un producto aparte con una base de datos aparte**. Desde la retirada de los componentes clásicos (febrero de 2024), todo recurso de Application Insights es *basado en workspace*: escribe en un workspace de Log Analytics que te pertenece, y sus datos se consultan con el mismo motor KQL que todo lo demás. Azure Monitor es la plataforma; Log Analytics es su almacén de logs; Application Insights es una vista con forma de aplicación sobre ese almacén.

---

## Requisitos previos y advertencia de costo

```bash
# Required tooling
az version
# Expect Azure CLI >= 2.60; the labs use the application-insights extension.

az extension add --name application-insights --upgrade --only-show-errors
az extension add --name log-analytics       --upgrade --only-show-errors
```

> **Costo.** Todo lo de los Labs 1–3 y el Lab 8 es gratuito de leer. Los Labs 4, 5, 7 y 9 crean un workspace de Log Analytics y un componente de Application Insights. La ingesta se factura por GB; los volúmenes de acá son unos pocos MB, bien dentro de la asignación gratuita de 5 GB/mes que aplica por cuenta de facturación, pero **ejecutá igual la limpieza del Lab 10**. Las reglas de alerta (Lab 6) se facturan por serie temporal por mes; las reglas creadas acá cuestan centavos, no dólares, y se eliminan al final.
>
> Todos los precios citados son precios de lista indicativos (East US, pago por uso) y cambian. Verificalos en la Calculadora de precios de Azure antes de citárselos a nadie.

---

## Lab 0 — Arrancar un entorno descartable

**Paso 1.** Fijá tu shell a una sola suscripción para que nada se filtre a otra vecina.

```bash
az account set --subscription "<your-subscription-name-or-id>"
az account show --query "{name:name, id:id, tenant:tenantId, state:state}" -o table
```

Esperado:

```
Name                 Id                                    Tenant                                State
-------------------  ------------------------------------  ------------------------------------  --------
Visual Studio Enterprise  00000000-1111-2222-3333-444444444444  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  Enabled
```

**Paso 2.** Exportá las variables usadas a lo largo del laboratorio. Mantené esta shell abierta; cada lab posterior las reutiliza.

```bash
export SUB_ID=$(az account show --query id -o tsv)
export LOC=eastus
export RG=rg-az900-mon-lab
export LAW=law-az900-lab
export AI=appi-az900-lab
export AG=ag-az900-lab
```

**Paso 3.** Creá el grupo de recursos. `az group create` es idempotente — volver a ejecutarlo devuelve el grupo existente sin cambios.

```bash
az group create --name "$RG" --location "$LOC" --tags purpose=az900-lab ttl=1d -o table
```

```
Location    Name
----------  -----------------
eastus      rg-az900-mon-lab
```

**Paso 4.** Registrá los proveedores de recursos que necesitan los labs. El registro es por suscripción y tarda hasta un par de minutos; no hace nada si ya está registrado.

```bash
for ns in Microsoft.OperationalInsights Microsoft.Insights Microsoft.AlertsManagement Microsoft.ResourceHealth Microsoft.Advisor; do
  az provider register --namespace "$ns" --only-show-errors
done

az provider list --query "[?namespace=='Microsoft.Insights' || namespace=='Microsoft.OperationalInsights'].{ns:namespace, state:registrationState}" -o table
```

```
Ns                            State
----------------------------  ----------
Microsoft.Insights            Registered
Microsoft.OperationalInsights Registered
```

### Preguntas de comprensión — Lab 0

**Q1.** `Microsoft.Insights` y `Microsoft.OperationalInsights` son dos proveedores de recursos distintos. ¿Cuál es dueño del recurso *workspace* de Log Analytics, y cuál de los *diagnostic settings, reglas de alerta de métricas y action groups*? ¿Por qué existe esa división?

**Q2.** ¿Por qué el laboratorio registra `Microsoft.AlertsManagement` por separado de `Microsoft.Insights`, dado que las reglas de alerta viven bajo `Microsoft.Insights`?

---

## Lab 1 — Azure Advisor: el motor de recomendaciones

Advisor es una **capa de análisis de solo lectura**. No es dueño de telemetría propia: evalúa periódicamente la configuración y las métricas de uso de tus recursos contra un catálogo de reglas derivado del Microsoft Azure Well-Architected Framework, y materializa los resultados como objetos `Microsoft.Advisor/recommendations`. Las recomendaciones de costo típicamente se refrescan con una cadencia más lenta (hasta ~24 h) que las demás, porque dependen del historial agregado de utilización y no de una lectura de configuración.

**Paso 1.** Listá todas las recomendaciones de la suscripción, agrupadas por categoría.

```bash
az advisor recommendation list \
  --query "[].{category:category, impact:impact, resource:impactedValue, problem:shortDescription.problem}" \
  -o table | head -20
```

Salida representativa (recortada):

```
Category                Impact    Resource                 Problem
----------------------  --------  -----------------------  --------------------------------------------------
Cost                    Medium    vm-legacy-01             Right-size or shutdown underutilized virtual machines
HighAvailability        High      st0az900lab              Use Zone-redundant storage for higher availability
Security                High      kv-prod-01               Key vaults should have soft delete enabled
OperationalExcellence   Medium    rg-prod                  Create an Azure Service Health alert
Performance             Low       sqldb-orders             Improve performance with Accelerated Networking
```

**Paso 2.** Contá las recomendaciones por pilar. Esta es la forma que un equipo de plataforma efectivamente sigue en el tiempo.

```bash
az advisor recommendation list --query "[].category" -o tsv | sort | uniq -c | sort -rn
```

```
     14 Cost
      9 Security
      6 HighAvailability
      4 OperationalExcellence
      2 Performance
```

> **Trampa de nomenclatura.** El portal muestra cinco pilares llamados **Reliability, Security, Cost Optimization, Operational Excellence, Performance Efficiency**. La API sigue devolviendo el valor heredado `HighAvailability` donde el portal dice *Reliability*. Filtrá por el valor de la API en los scripts.

**Paso 3.** Filtrá a una sola categoría e inspeccioná una recomendación completa. Notá que `--category` acepta la ortografía de la API.

```bash
az advisor recommendation list --category Cost \
  --query "[0].{id:id, problem:shortDescription.problem, solution:shortDescription.solution, impact:impact, meta:extendedProperties}" \
  -o jsonc
```

```jsonc
{
  "id": "/subscriptions/0000.../resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm-legacy-01/providers/Microsoft.Advisor/recommendations/8a1b...",
  "impact": "Medium",
  "meta": {
    "MaxCpuP95": "3.42",
    "MaxMemoryP95": "18.7",
    "regionId": "eastus",
    "roleName": "vm-legacy-01",
    "savingsAmount": "83.22",
    "savingsCurrency": "USD",
    "targetSku": "Standard_B2s"
  },
  "problem": "Right-size or shutdown underutilized virtual machines",
  "solution": "We have observed low CPU and network usage over the last 7 days..."
}
```

Leé `extendedProperties` con atención: `MaxCpuP95: 3.42` es la *evidencia*. Advisor te está diciendo que el percentil 95 de CPU durante la ventana de observación fue 3,4 %. Una recomendación que no podés trazar hasta una evidencia es una recomendación que no podés defender en una revisión de cambios.

**Paso 4.** Inspeccioná la configuración de Advisor. Ahí es donde vive el umbral de CPU que impulsa el right-sizing, y donde podés excluir grupos de recursos ruidosos.

```bash
az advisor configuration list --query "[].{scope:id, lowCpu:properties.lowCpuThreshold, excluded:properties.exclude}" -o table
```

```
Scope                                                     LowCpu    Excluded
--------------------------------------------------------  --------  ----------
/subscriptions/0000.../providers/Microsoft.Advisor/config  5         False
```

**Paso 5.** Leé el Advisor score. El score no está expuesto por un verbo de primera clase de la CLI, así que llamá directamente a la superficie REST de ARM — una técnica que vale la pena interiorizar, porque funciona para toda API en Azure que esté en preview o sin CLI.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Advisor/advisorScore?api-version=2023-01-01" \
  --query "value[].{category:name, score:properties.lastRefreshedScore.score, consumed:properties.lastRefreshedScore.consumptionUnits}" \
  -o table
```

```
Category               Score    Consumed
---------------------  -------  ----------
Advisor                71.4     412.0
Cost                   64.2     118.0
Security               88.0     97.0
HighAvailability       59.7     84.0
OperationalExcellence  76.1     63.0
Performance            92.3     50.0
```

El Advisor score es un porcentaje **ponderado por consumo**: el score de cada categoría se pondera por el gasto de los recursos que evalúa, así que una VM de producción mal configurada mueve la aguja mucho más que un disco de desarrollo ocioso. Por eso una suscripción puede tener decenas de recomendaciones abiertas y aun así puntuar por encima de 90.

### Preguntas de comprensión — Lab 1

**Q3.** Advisor muestra una recomendación de *Security*. ¿Qué servicio la generó realmente, y qué implica eso sobre si Advisor es el sistema de registro para la postura de seguridad?

**Q4.** Una recomendación de costo reporta `savingsAmount: 83.22`. ¿Es una cifra mensual o anual por defecto, y por qué debés verificarlo antes de ponerla en un informe de ahorros?

**Q5.** Tu suscripción tiene 40 recomendaciones abiertas pero un Advisor score de 93. Explicá, mecánicamente, cómo ambas cosas son ciertas a la vez.

**Q6.** Redimensionás la VM del Paso 3 a las 14:00. A las 14:10 la recomendación sigue listada. ¿Es un bug? ¿Qué revisarías?

---

## Lab 2 — Service Health y Resource Health: ¿soy yo o es Microsoft?

Dos servicios distintos, frecuentemente confundidos:

- **Azure Status** (`status.azure.com`) — global, sin autenticación, para caídas tan grandes que son públicas. Nunca construyas automatización sobre él.
- **Azure Service Health** — autenticado y **personalizado**: solo muestra eventos que afectan a *regiones y servicios que realmente usás*. Cuatro clases de evento: **Service issues**, **Planned maintenance**, **Health advisories**, **Security advisories**.
- **Resource Health** — veredicto por recurso sobre *tu instancia específica*: `Available`, `Unavailable`, `Degraded`, `Unknown`. Derivado de señales de la plataforma más, para algunos tipos de recurso, comprobaciones de salud activas.

**Paso 1.** Consultá la salud de todos los recursos de la suscripción que reporten alguna.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" \
  --query "value[].{resource:id, status:properties.availabilityState, reason:properties.reasonType, since:properties.occuredTime}" \
  -o table | head
```

```
Resource                                            Status       Reason     Since
--------------------------------------------------  -----------  ---------  --------------------------
/subscriptions/.../virtualMachines/vm-legacy-01     Available    Unknown    2026-08-29T04:11:02Z
/subscriptions/.../vaults/kv-prod-01                Available    Unknown    2026-09-01T00:00:00Z
/subscriptions/.../virtualMachines/vm-batch-07      Unavailable  Customer   2026-09-04T22:40:18Z
```

**Paso 2.** Interpretá `reasonType`. Este campo es el sentido entero de Resource Health.

| `reasonType` | Significado | Quién actúa |
|---|---|---|
| `Unplanned` | Falla de plataforma — caída de host, problema de fabric | Microsoft; vos hacés failover |
| `Planned` | Mantenimiento iniciado por la plataforma | Microsoft; vos planificás alrededor |
| `UserInitiated` / `Customer` | Vos lo detuviste, desasignaste o configuraste mal | Vos |
| `Unknown` | La plataforma perdió la señal; no es evidencia de falla | Investigá; no generes una guardia solo por esto |

`vm-batch-07` arriba está `Unavailable / Customer` — alguien la desasignó. Eso no es un incidente.

**Paso 3.** Listá los eventos de Service Health actualmente visibles para tu suscripción.

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ResourceHealth/events?api-version=2023-10-01-preview&\$filter=properties/status eq 'Active'" \
  --query "value[].{type:properties.eventType, level:properties.level, title:properties.title, impactStart:properties.impactStartTime}" \
  -o table
```

```
Type              Level       Title                                              ImpactStart
----------------  ----------  -------------------------------------------------  --------------------------
PlannedMaintenance  Warning   Planned maintenance - Azure SQL Database - East US  2026-09-11T02:00:00Z
HealthAdvisory      Warning   TLS 1.0/1.1 retirement for Azure Storage           2026-10-31T00:00:00Z
```

Un `value: []` vacío es un resultado sano y normal.

**Paso 4.** Creá la alerta que el pilar de *Operational Excellence* de Advisor recomienda una y otra vez. La mecánica importa: **una alerta de Service Health es una alerta de Activity Log**, no una alerta de métrica. Los eventos de Service Health se escriben en el Activity Log de la suscripción bajo la categoría `ServiceHealth`, y la regla de alerta es un filtro sobre ese flujo.

Primero un action group — el destino de notificación reutilizable que comparten todos los tipos de alerta:

```bash
az monitor action-group create \
  --name "$AG" \
  --resource-group "$RG" \
  --short-name az900lab \
  --action email oncall villadalmine@gmail.com \
  -o table
```

```
Enabled    GroupShortName    Location    Name           ResourceGroup
---------  ----------------  ----------  -------------  -----------------
True       az900lab          Global      ag-az900-lab   rg-az900-mon-lab
```

> `--short-name` está limitado a 12 caracteres; es lo que aparece como prefijo de remitente en SMS/email.

Ahora la regla:

```bash
export AG_ID=$(az monitor action-group show -g "$RG" -n "$AG" --query id -o tsv)

az monitor activity-log alert create \
  --name "alert-servicehealth-all" \
  --resource-group "$RG" \
  --scope "/subscriptions/$SUB_ID" \
  --condition category=ServiceHealth \
  --action-group "$AG_ID" \
  --description "All Service Health events for this subscription" \
  -o table
```

```
Enabled    Location    Name                      ResourceGroup
---------  ----------  ------------------------  -----------------
True       Global      alert-servicehealth-all   rg-az900-mon-lab
```

**Paso 5.** Verificá la regla emitida, y notá las dos restricciones duras de las alertas de Activity Log.

```bash
az monitor activity-log alert show -g "$RG" -n "alert-servicehealth-all" \
  --query "{scopes:scopes, location:location, conditions:condition.allOf[].{f:field, e:equals}}" -o jsonc
```

```jsonc
{
  "conditions": [ { "e": "ServiceHealth", "f": "category" } ],
  "location": "Global",
  "scopes": [ "/subscriptions/00000000-1111-2222-3333-444444444444" ]
}
```

El `location` de la regla es `Global` — las reglas de alerta de Activity Log no son recursos regionales, porque el propio Activity Log es un flujo con ámbito de suscripción e independiente de la región. Y el `scope` debe ser una suscripción, un grupo de recursos o un recurso **en esa suscripción**: una regla no puede abarcar varias suscripciones. Un tenant con 30 suscripciones necesita 30 reglas, que es exactamente el tipo de cosa que se despliega con una política `deployIfNotExists` en vez de a mano.

**Paso 6.** Refiná a la forma de producción — la mayoría de los equipos no quiere una guardia por cada aviso de salud.

```bash
az monitor activity-log alert update \
  --name "alert-servicehealth-all" \
  --resource-group "$RG" \
  --condition "category=ServiceHealth and properties.incidentType=Incident" \
  -o none
```

`incidentType=Incident` acota a incidencias de servicio en curso, excluyendo `Maintenance`, `Informational` (health advisories) y `Security`.

### Preguntas de comprensión — Lab 2

**Q7.** Una VM reporta `Unavailable` con `reasonType: Unplanned`, mientras que Service Health no muestra ningún evento activo para esa región. ¿Es contradictorio? Explicá.

**Q8.** ¿Por qué una alerta de Service Health se implementa como una alerta de Activity Log en lugar de como una alerta de métrica? ¿Qué propiedad de los datos subyacentes fuerza esa elección?

**Q9.** Tu equipo recibe una guardia a las 03:00 por un evento `PlannedMaintenance` anunciado con tres semanas de anticipación. ¿Qué campo único de la condición del Paso 6 arregla esto, y cuál es la contrapartida del arreglo?

**Q10.** Tenés que alertar sobre Service Health en 30 suscripciones. ¿Por qué no podés simplemente ampliar `--scope` al management group, y cuál es el remedio estándar?

---

## Lab 3 — Azure Monitor, parte 1: el pilar de métricas

Azure Monitor almacena dos formas de datos fundamentalmente distintas, y elegir mal es el error más caro en observabilidad de Azure.

| | **Métricas** | **Logs** |
|---|---|---|
| Almacén | Base de datos de series temporales construida a propósito | Workspace de Log Analytics (Kusto) |
| Forma | Numérica, esquema fijo, pre-agregada | Registros arbitrarios, esquema variable |
| Latencia | Baja (segundos a ~3 min) | Mayor (típicamente ~1–5 min de ingesta) |
| Granularidad | 1 minuto por defecto para métricas de plataforma | Por evento |
| Retención | 93 días para métricas de plataforma | Configurable, hasta 12 años en total |
| Consulta | Metrics Explorer / API de métricas | KQL |
| **Costo de plataforma** | **Gratis de recolectar y consultar** | **Facturado por GB ingerido + retenido** |
| Mejor para | Alertas, dashboards, "¿está arriba / qué tan rápido?" | Investigación, correlación, auditoría, "por qué" |

Las métricas de plataforma las emite el proveedor de recursos automáticamente. **No configurás nada y no se te factura por ellas.** Este es el nivel gratuito de la observabilidad en Azure y rutinariamente queda sin usar.

**Paso 1.** Descubrí qué emite un recurso, antes de asumirlo. Usá el grupo de recursos del action group como objetivo — o sustituilo por cualquier recurso que tengas.

```bash
# Use any existing resource; a storage account is a good example.
export TARGET=$(az storage account list --query "[0].id" -o tsv)
echo "$TARGET"

az monitor metrics list-definitions --resource "$TARGET" \
  --query "[].{metric:name.value, unit:unit, aggregations:supportedAggregationTypes, dims:join(',',metricAvailabilities[0].timeGrain && [''] || [''])}" \
  -o table | head -15
```

```
Metric                  Unit           Aggregations
----------------------  -------------  ----------------------------------------------
UsedCapacity            Bytes          Average
Transactions            Count          Total
Ingress                 Bytes          Total, Average
Egress                  Bytes          Total, Average
SuccessServerLatency    MilliSeconds   Average
SuccessE2ELatency       MilliSeconds   Average
Availability            Percent        Average
```

**Paso 2.** Leé valores reales. Notá el `--aggregation` y el `--interval` explícitos: elegir la agregación equivocada para una métrica produce silenciosamente un número sin sentido.

```bash
az monitor metrics list --resource "$TARGET" \
  --metric "Transactions" \
  --aggregation Total \
  --interval PT1H \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[0].data[].{time:timeStamp, total:total}" \
  -o table
```

```
Time                       Total
-------------------------  -------
2026-09-05T08:00:00+00:00  1420.0
2026-09-05T09:00:00+00:00  1588.0
2026-09-05T10:00:00+00:00  1201.0
2026-09-05T11:00:00+00:00  9930.0
2026-09-05T12:00:00+00:00  1355.0
2026-09-05T13:00:00+00:00  1290.0
```

**Paso 3.** Dividí por dimensión. Las dimensiones son la razón por la que las métricas siguen siendo baratas y a la vez diagnosticables: el pico de arriba es agregado, e inútil hasta que lo desarmás.

```bash
az monitor metrics list --resource "$TARGET" \
  --metric "Transactions" \
  --aggregation Total \
  --interval PT1H \
  --filter "ResponseType eq '*'" \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[].{responseType:metadatavalues[0].value, peak:max(data[].total)}" \
  -o table
```

```
ResponseType             Peak
-----------------------  ------
Success                  1402.0
ClientOtherError         8510.0
ServerTimeoutError       18.0
```

El pico de las 11:00 fue `ClientOtherError`, no carga. Esa distinción — obtenida gratis, en segundos, sin ingerir un solo byte de logs — es el argumento para recurrir primero a las métricas.

**Paso 4.** Entendé el límite de retención empíricamente. Pedí datos de más de 93 días de antigüedad:

```bash
az monitor metrics list --resource "$TARGET" --metric "Transactions" --aggregation Total \
  --interval P1D \
  --start-time "$(date -u -d '120 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "length(value[0].timeseries[0].data)"
```

Vas a obtener como mucho ~93 días de buckets sin importar la hora de inicio que hayas pedido. La retención de métricas de plataforma es fija y no configurable. Si necesitás una comparación interanual, tenés que **exportar las métricas a Logs mediante un diagnostic setting** — que es el Lab 4, y que ya no es gratis.

### Preguntas de comprensión — Lab 3

**Q11.** Necesitás alertar en menos de 60 segundos cuando la tasa de HTTP 5xx de una web app sube. ¿Métricas o Logs? Justificá con dos propiedades de la tabla comparativa.

**Q12.** Un colega consulta `SuccessE2ELatency` con `--aggregation Total`. ¿Por qué el resultado no tiene sentido, y qué computa en realidad?

**Q13.** Las métricas de plataforma son gratis. Nombrá las *dos* circunstancias distintas bajo las cuales recolectar datos de métricas genera igualmente una factura.

**Q14.** El cumplimiento normativo exige 400 días de historial de transacciones de la cuenta de almacenamiento. La retención de métricas de plataforma es de 93 días. Describí el mecanismo que satisface el requisito y nombrá el nuevo costo que introduce.

---

## Lab 4 — Azure Monitor, parte 2: Log Analytics y diagnostic settings

Las métricas de plataforma llegan automáticamente. **Los resource logs no.** Todo recurso de Azure puede emitir logs operativos detallados, pero se descartan a menos que un **diagnostic setting** sobre ese recurso los enrute a algún lado. Esta es la brecha más común en un entorno real: el rastro de auditoría que todos daban por existente nunca se activó.

**Paso 1.** Creá el workspace. `PerGB2018` es el tier de precios estándar de pago por uso.

```bash
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW" \
  --location "$LOC" \
  --sku PerGB2018 \
  --retention-time 30 \
  -o table
```

```
CreatedDate                    Location    Name          ProvisioningState    ResourceGroup      RetentionInDays
-----------------------------  ----------  ------------  -------------------  -----------------  ---------------
Fri, 05 Sep 2026 14:02:11 GMT  eastus      law-az900-lab  Succeeded            rg-az900-mon-lab   30
```

**Paso 2.** Capturá ambos identificadores. Son distintos y no son intercambiables.

```bash
export LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
export LAW_GUID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
echo "ARM resource ID : $LAW_ID"
echo "Workspace GUID  : $LAW_GUID"
```

```
ARM resource ID : /subscriptions/0000.../resourceGroups/rg-az900-mon-lab/providers/Microsoft.OperationalInsights/workspaces/law-az900-lab
Workspace GUID  : 7f3c9a10-2b44-4c7e-9e21-8d55a1f0c3b9
```

El **ARM ID** es el manejador del plano de control: lo usan los diagnostic settings, RBAC, las reglas de alerta. El **GUID customerId** es el manejador del plano de datos: lo usan la API de consulta y los agentes. Pasar uno donde se espera el otro es un desvío clásico de depuración de 30 minutos.

**Paso 3.** Enrutá el Activity Log de la suscripción al workspace. El Activity Log es el registro del *plano de control* — quién creó, modificó o eliminó qué — retenido 90 días gratis en su propio almacén. Exportarlo a un workspace te permite correlacionar un despliegue con una regresión de la aplicación, que es el broche del Lab 9.

```bash
az monitor diagnostic-settings subscription create \
  --name "diag-activitylog-to-law" \
  --location "$LOC" \
  --workspace "$LAW_ID" \
  --logs '[
    {"category":"Administrative","enabled":true},
    {"category":"ServiceHealth","enabled":true},
    {"category":"ResourceHealth","enabled":true},
    {"category":"Alert","enabled":true},
    {"category":"Policy","enabled":true},
    {"category":"Autoscale","enabled":true},
    {"category":"Security","enabled":true},
    {"category":"Recommendation","enabled":true}
  ]' -o none

az monitor diagnostic-settings subscription list \
  --query "value[].{name:name, categories:join(',', properties.logs[?enabled].category)}" -o table
```

```
Name                        Categories
--------------------------  --------------------------------------------------------------------
diag-activitylog-to-law     Administrative,ServiceHealth,ResourceHealth,Alert,Policy,Autoscale,Security,Recommendation
```

**Paso 4.** Agregá un diagnostic setting con ámbito de recurso. Primero inspeccioná qué puede emitir el recurso — nunca adivines nombres de categorías, difieren por tipo de recurso:

```bash
az monitor diagnostic-settings categories list --resource "$TARGET/blobServices/default" \
  --query "value[].{category:name, type:properties.categoryType, group:properties.categoryGroups}" -o table
```

```
Category         Type      Group
---------------  --------  ------------------
StorageRead      Logs      allLogs, audit
StorageWrite     Logs      allLogs
StorageDelete    Logs      allLogs, audit
Transaction      Metrics
```

Después crealo:

```bash
az monitor diagnostic-settings create \
  --name "diag-blob-to-law" \
  --resource "$TARGET/blobServices/default" \
  --workspace "$LAW_ID" \
  --logs '[{"categoryGroup":"audit","enabled":true}]' \
  --metrics '[{"category":"Transaction","enabled":true}]' \
  -o none
```

Usar `categoryGroup: audit` en lugar de una lista explícita de categorías es la opción duradera: cuando Microsoft agregue una nueva categoría relevante para auditoría a ese tipo de recurso, el setting la toma sin necesidad de redesplegar.

**Paso 5.** Entendé el fan-out. Un diagnostic setting es un enrutador uno-a-muchos con cuatro tipos de destino:

| Destino | Propósito típico | Modelo de costo |
|---|---|---|
| **Workspace de Log Analytics** | Consultar, alertar, correlacionar | Por GB ingerido + retenido |
| **Cuenta de almacenamiento** | Archivo barato a largo plazo, cumplimiento | Tarifas de almacenamiento (muy barato) |
| **Event Hub** | Transmitir a SIEM / tercero / pipeline propio | Unidades de rendimiento de Event Hub |
| **Solución de partner** | Datadog, Elastic, Dynatrace, … | Facturación del partner |

Un recurso admite **hasta 5 diagnostic settings**, así que un patrón habitual en producción es un setting hacia un workspace con 30 días de retención para operaciones, más un segundo hacia una cuenta de almacenamiento para un archivo de cumplimiento de siete años a aproximadamente el 1 % del costo por GB.

**Paso 6.** Desplegá lo mismo de forma declarativa. Los clics en el portal no sobreviven a una auditoría; este Bicep es el artefacto que realmente versionás.

```bicep
// monitoring.bicep — workspace, Application Insights, action group, and a
// subscription-wide Service Health alert. Deploy at resource-group scope.
targetScope = 'resourceGroup'

@description('Deployment region for regional resources.')
param location string = resourceGroup().location

@description('Base name; all resources derive from it.')
param baseName string = 'az900lab'

@description('Interactive retention in days for the workspace (30–730).')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Email address that receives alert notifications.')
param alertEmail string

var workspaceName    = 'law-${baseName}'
var appInsightsName  = 'appi-${baseName}'
var actionGroupName  = 'ag-${baseName}'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Workspace-based Application Insights: telemetry lands in the workspace above.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: 90
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  properties: {
    groupShortName: 'az900lab'
    enabled: true
    emailReceivers: [
      {
        name: 'oncall'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Activity Log alert: fires on live Service Health incidents only.
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-servicehealth-incidents'
  location: 'Global'
  properties: {
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          field: 'properties.incidentType'
          equals: 'Incident'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Live Azure Service Health incidents affecting this subscription.'
  }
}

output workspaceResourceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output actionGroupId string = actionGroup.id
```

Validalo sin desplegar (`what-if` muestra el delta exacto que ARM aplicaría):

```bash
az deployment group what-if \
  --resource-group "$RG" \
  --template-file monitoring.bicep \
  --parameters alertEmail=villadalmine@gmail.com
```

```
Resource and property changes are indicated with these symbols:
  + Create
  ~ Modify
  = Nochange

The deployment will update the following scope:

Scope: /subscriptions/0000.../resourceGroups/rg-az900-mon-lab

  = Microsoft.OperationalInsights/workspaces/law-az900lab
  + Microsoft.Insights/components/appi-az900lab
  + Microsoft.Insights/activityLogAlerts/alert-servicehealth-incidents
```

### Preguntas de comprensión — Lab 4

**Q15.** Un recurso *no* tiene diagnostic setting. ¿Cuáles de los siguientes siguen estando disponibles: métricas de plataforma, resource logs, entradas del Activity Log por operaciones sobre él? Explicá cada uno.

**Q16.** Distinguí el **Activity Log** de los **resource logs** en una oración cada uno, y después indicá cuál registra "se emitió un `DELETE` contra este key vault" frente a "se leyó un secreto de este key vault".

**Q17.** En el Bicep, `actionGroup.location` es `'Global'` mientras que `workspace.location` es una región. ¿Por qué?

**Q18.** Un equipo necesita logs consultables durante 30 días y retenidos 7 años para los auditores. Describí el diseño de dos destinos y explicá por qué cuesta muchísimo menos que 7 años de retención en el workspace.

**Q19.** El Bicep establece `WorkspaceResourceId` en el componente de Application Insights. ¿Qué faltaría si se omitiera esa propiedad, y por qué omitirla ya no es posible?

---

## Lab 5 — KQL: consultar el almacén de logs

KQL es un lenguaje de consulta de solo lectura y encauzado. Los datos fluyen de izquierda a derecha a través de `|`; cada operador toma una entrada tabular y devuelve una salida tabular. No hay `UPDATE`, no hay `DELETE`, y no hay forma de mutar los datos ingeridos desde una consulta.

**Paso 1.** Confirmá que el workspace tiene datos. Los workspaces recién creados están vacíos los primeros minutos; `Heartbeat` y `Usage` aparecen primero.

```bash
az monitor log-analytics query \
  --workspace "$LAW_GUID" \
  --analytics-query "union withsource=TableName * | summarize Records=count(), Latest=max(TimeGenerated) by TableName | sort by Records desc" \
  -o table
```

```
TableName        Records    Latest
---------------  ---------  --------------------------
AzureActivity    1284       2026-09-05T14:41:12.33Z
Usage            96         2026-09-05T14:00:00.00Z
Operation        12         2026-09-05T14:05:44.10Z
StorageBlobLogs  431        2026-09-05T14:40:57.88Z
```

> `union *` es un escaneo completo del workspace. Está bien en un workspace de laboratorio vacío y es temerario en uno de producción con terabytes. Preferí la forma de solo metadatos para descubrimiento: `search * | distinct $table` no es mejor — usá la hoja **Tables** del workspace o la tabla `Usage` en su lugar.

**Paso 2.** Los cinco operadores que cubren la mayor parte del trabajo real.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated > ago(24h)
| where CategoryValue == "Administrative"
| where ActivityStatusValue == "Success"
| summarize Operations = count() by Caller, OperationNameValue
| top 5 by Operations desc
' -o table
```

```
Caller                       OperationNameValue                                        Operations
---------------------------  --------------------------------------------------------  ----------
villadalmine@gmail.com       Microsoft.Insights/diagnosticSettings/write               6
villadalmine@gmail.com       Microsoft.OperationalInsights/workspaces/write            3
7c1f...@tenant (SPN)         Microsoft.Compute/virtualMachines/write                   2
```

Leé el pipeline como un embudo: `where` sobre `TimeGenerated` **primero**, siempre. Log Analytics particiona por tiempo de ingesta; un filtro de tiempo al inicio permite al motor saltearse particiones enteras, y es la diferencia entre una consulta de 200 ms y una de 40 segundos.

**Paso 3.** Agrupá en buckets temporales y renderizá — la forma detrás de cada gráfico del portal.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated > ago(24h)
| summarize Events = count() by bin(TimeGenerated, 1h), CategoryValue
| order by TimeGenerated asc
' -o table | head
```

```
TimeGenerated               CategoryValue   Events
--------------------------  --------------  ------
2026-09-05T09:00:00Z        Administrative  14
2026-09-05T09:00:00Z        Policy          122
2026-09-05T10:00:00Z        Administrative  3
2026-09-05T10:00:00Z        Policy          118
```

`bin(TimeGenerated, 1h)` redondea cada marca de tiempo hacia abajo a la hora — así es como convertís un flujo de eventos en una serie temporal. Agregar `| render timechart` no tiene efecto en la CLI, pero controla la visualización en el portal y en los workbooks.

**Paso 4.** Medí tu propia ingesta. Esta consulta es la que hay que guardar: es la diferencia entre una factura predecible y una sorpresa.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
Usage
| where TimeGenerated > ago(7d)
| where IsBillable == true
| summarize BillableGB = round(sum(Quantity) / 1000, 3) by DataType
| order by BillableGB desc
' -o table
```

```
DataType          BillableGB
----------------  ----------
AzureActivity     0.041
StorageBlobLogs   0.012
AppRequests       0.004
```

**Paso 5.** Entendé los planes de tabla — la palanca de costo que la mayoría de los equipos nunca acciona.

| Plan | Retención interactiva | Capacidad de consulta | Precio indicativo de ingesta | Usar para |
|---|---|---|---|---|
| **Analytics** | 30 días incluidos, hasta 730 | KQL completo, alertas, todas las funciones | ~$2,76/GB | Datos que consultás y sobre los que alertás |
| **Basic** | 30 días | KQL restringido (tabla única, sin joins/alertas), **facturado por consulta** | ~$0,65/GB | Logs verbosos de alto volumen, forense ocasional |
| **Auxiliary** | 30 días | Muy restringido, facturado por consulta | ~$0,15/GB | Datos masivos, rara vez leídos, con forma de cumplimiento |

Más allá de la retención interactiva, los datos pasan a **retención a largo plazo** (hasta 12 años en total) a aproximadamente $0,026/GB/mes, pero ya no son directamente consultables — tenés que ejecutar un **search job** o **restaurarlos**, cada uno facturado por separado.

```bash
# Inspect the plan and retention of a table
az monitor log-analytics workspace table show \
  -g "$RG" --workspace-name "$LAW" -n StorageBlobLogs \
  --query "{plan:plan, interactive:retentionInDays, total:totalRetentionInDays}" -o jsonc
```

```jsonc
{
  "interactive": 30,
  "plan": "Analytics",
  "total": 30
}
```

```bash
# Move a chatty table to Basic and keep 1 year of long-term retention
az monitor log-analytics workspace table update \
  -g "$RG" --workspace-name "$LAW" -n StorageBlobLogs \
  --plan Basic --total-retention-time 365 -o none
```

### Preguntas de comprensión — Lab 5

**Q20.** ¿Por qué importa, mecánicamente, poner `| where TimeGenerated > ago(24h)` *arriba de todo* en una consulta? ¿Qué puede saltearse el motor?

**Q21.** Movés una tabla al plan **Basic** y tu regla de alerta de log sobre ella deja de funcionar. ¿Es un bug? ¿Qué regla violaste?

**Q22.** Una tabla acumula 500 GB/mes, nunca se consulta, y debe conservarse 1 año para los auditores. Compará el plan Analytics con retención de 365 días contra Basic/Auxiliary más retención a largo plazo, y nombrá el costo operativo de la opción más barata.

**Q23.** `Usage | where IsBillable == true` — nombrá dos categorías de datos que aterrizan en un workspace y **no** son facturables.

---

## Lab 6 — Alertas: reglas, action groups y la máquina de estados

Las alertas de Azure Monitor tienen tres partes componibles, y mantenerlas separadas es lo que hace que el sistema sea mantenible:

1. **Regla de alerta** — *qué* detectar (una condición sobre métricas, logs, el Activity Log o resource health).
2. **Action group** — *a quién/qué* notificar. Reutilizable entre cientos de reglas.
3. **Alert processing rule** — *cuándo suprimir o redirigir*, por ejemplo durante una ventana de mantenimiento. Se aplica por encima, sin editar ninguna regla.

**Paso 1.** Inspeccioná el action group del Lab 2 y agregá un webhook usando el **common alert schema** — la carga útil normalizada que hace que un único manejador aguas abajo funcione para todos los tipos de alerta.

```bash
az monitor action-group update \
  --name "$AG" --resource-group "$RG" \
  --add-action webhook chatops "https://example.invalid/hooks/az900" useCommonAlertSchema=true \
  -o none

az monitor action-group show -g "$RG" -n "$AG" \
  --query "{email:emailReceivers[].name, webhook:webhookReceivers[].{n:name, schema:useCommonAlertSchema}}" -o jsonc
```

```jsonc
{
  "email": [ "oncall" ],
  "webhook": [ { "n": "chatops", "schema": true } ]
}
```

Sin `useCommonAlertSchema=true`, una alerta de métrica, una de log y una de Activity Log hacen POST cada una con una forma JSON *distinta*, y tu manejador necesita tres parsers.

**Paso 2.** Creá una alerta de métrica con umbral estático.

```bash
az monitor metrics alert create \
  --name "alert-blob-availability" \
  --resource-group "$RG" \
  --scopes "$TARGET" \
  --condition "avg Availability < 99" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 2 \
  --description "Storage availability below 99% over 5 minutes" \
  --action "$AG_ID" \
  -o table
```

```
Enabled    Location    Name                       ResourceGroup      Severity
---------  ----------  -------------------------  -----------------  ----------
True       global      alert-blob-availability    rg-az900-mon-lab   2
```

Dos parámetros hacen el trabajo real y se confunden constantemente:

- **`--window-size` (granularidad de agregación)** — cuánta historia mira cada evaluación. `5m` significa "promediar los últimos 5 minutos".
- **`--evaluation-frequency`** — cada cuánto se ejecuta esa evaluación. `1m` significa cada minuto, sobre una ventana deslizante de 5 minutos.

Una ventana de 5 minutos con frecuencia de 1 minuto suaviza el ruido de una sola muestra y aun así detecta dentro de aproximadamente un minuto una violación sostenida. Una ventana de 1 minuto con frecuencia de 1 minuto te va a generar guardia con cada parpadeo transitorio.

**Paso 3.** La severidad es un contrato, no un adorno.

| Severidad | Etiqueta | Convención |
|---|---|---|
| Sev 0 | Critical | Despertar a una persona ahora |
| Sev 1 | Error | Guardia en horario laboral |
| Sev 2 | Warning | Ticket |
| Sev 3 | Informational | Solo dashboard |
| Sev 4 | Verbose | Registrar, nunca notificar |

**Paso 4.** Creá una regla de umbral dinámico. En lugar de un número fijo, la plataforma aprende el patrón histórico de la métrica — incluida la estacionalidad diaria y semanal — y alerta ante la desviación.

```bash
az monitor metrics alert create \
  --name "alert-blob-transactions-dynamic" \
  --resource-group "$RG" \
  --scopes "$TARGET" \
  --condition "total Transactions > dynamic medium 4 of 5 since $(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --window-size 5m \
  --evaluation-frequency 5m \
  --severity 3 \
  --action "$AG_ID" \
  -o none
```

Decodificá la condición: sensibilidad `medium`, y disparar solo cuando el umbral se viole en **4 de los últimos 5** períodos de evaluación. Esa cláusula `4 of 5` es el supresor de ruido — es lo que impide que una única muestra anómala le genere guardia a nadie. Los umbrales dinámicos necesitan aproximadamente **3 días de historia** antes de que el modelo sea utilizable; habilitar uno sobre un recurso creado hace una hora no produce nada útil.

**Paso 5.** Entendé la naturaleza con estado. Las alertas de métrica son **con estado**: la regla transiciona `Resolved → Fired` al violarse y vuelve a `Resolved` cuando la condición se despeja, y **no** vuelve a notificar en cada evaluación mientras está disparada. Inspeccioná las instancias de alerta resultantes:

```bash
az monitor activity-log alert list -g "$RG" -o table
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
  --query "value[].{name:name, sev:properties.essentials.severity, state:properties.essentials.alertState, mon:properties.essentials.monitorCondition, fired:properties.essentials.startDateTime}" \
  -o table
```

```
Name                                  Sev     State        Mon       Fired
------------------------------------  ------  -----------  --------  --------------------------
alert-blob-availability               Sev2    New          Fired     2026-09-05T14:22:00Z
```

Notá los dos campos de estado independientes, que la gente confunde constantemente:

- **`monitorCondition`** — `Fired` / `Resolved`. Propiedad de la plataforma: *¿la condición es verdadera?*
- **`alertState`** — `New` / `Acknowledged` / `Closed`. Propiedad de las personas: *¿alguien se ocupó?*

Una alerta puede estar `Resolved` y aun así `New` (se autorreparó, nadie miró). Puede estar `Fired` y `Closed` (alguien la triageó como esperada). Tu proceso de guardia debe decidir qué campo maneja la cola.

**Paso 6.** Creá una alert processing rule para suprimir notificaciones durante una ventana de mantenimiento — la forma correcta de silenciar alertas, en contraste con deshabilitar reglas y olvidarse de volver a habilitarlas.

```bash
az monitor alert-processing-rule create \
  --name "apr-maintenance-window" \
  --resource-group "$RG" \
  --rule-type RemoveAllActionGroups \
  --scopes "/subscriptions/$SUB_ID/resourceGroups/$RG" \
  --description "Suppress notifications during the weekly patch window" \
  --schedule-recurrence-type Weekly \
  --schedule-recurrence Saturday \
  --schedule-start-time "02:00:00" \
  --schedule-end-time "04:00:00" \
  --schedule-time-zone "UTC" \
  --enabled true \
  -o table
```

```
Enabled    Location    Name                     ResourceGroup
---------  ----------  -----------------------  -----------------
True       Global      apr-maintenance-window   rg-az900-mon-lab
```

Las alertas siguen **disparándose y quedando registradas** — conservás el historial — pero no se invoca ningún action group durante la ventana. Deshabilitar las reglas, en cambio, habría destruido el registro y creado un riesgo permanente de dejarlas apagadas.

### Preguntas de comprensión — Lab 6

**Q24.** Distinguí `--window-size` de `--evaluation-frequency`. Dá un síntoma concreto de establecer `--window-size 1m` en una métrica con picos.

**Q25.** Una alerta muestra `monitorCondition: Resolved` y `alertState: New`. ¿Qué pasó, y qué te dice eso sobre tu proceso de guardia?

**Q26.** ¿Por qué `useCommonAlertSchema=true` es casi obligatorio en cuanto tenés más de un *tipo* de alerta apuntando al mismo webhook?

**Q27.** Una alerta de umbral dinámico sobre un recurso recién creado se dispara constantemente durante dos días y después se calma. Explicá el mecanismo, e indicá la historia mínima que necesita el modelo.

**Q28.** Compará *deshabilitar una regla de alerta* contra *una alert processing rule* para una ventana de mantenimiento planificado. Nombrá una cosa que perdés con el primer enfoque y un riesgo operativo que crea.

---

## Lab 7 — Application Insights: la vista a nivel de aplicación

Application Insights es el APM de Azure Monitor. Responde preguntas que la plataforma no puede: *cuál* llamada a dependencia es lenta, *cuál* excepción se correlaciona con la tasa de errores, *qué camino* siguió esta petición a través de cinco servicios.

**Paso 1.** Creá un componente basado en workspace.

```bash
az monitor app-insights component create \
  --app "$AI" \
  --location "$LOC" \
  --resource-group "$RG" \
  --workspace "$LAW_ID" \
  --application-type web \
  --kind web \
  -o table
```

```
AppId                                 ApplicationType    Location    Name            ResourceGroup      RetentionInDays
------------------------------------  -----------------  ----------  --------------  -----------------  ---------------
c41a9e77-58f2-4a1d-9d0f-2b6b1e3f77aa  web                eastus      appi-az900-lab  rg-az900-mon-lab   90
```

**Paso 2.** Obtené la connection string. Prestá atención a lo que *no* debés usar.

```bash
az monitor app-insights component show --app "$AI" -g "$RG" \
  --query "{connectionString:connectionString, workspace:WorkspaceResourceId}" -o jsonc
```

```jsonc
{
  "connectionString": "InstrumentationKey=8e2f...;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/;LiveEndpoint=https://eastus.livediagnostics.monitor.azure.com/;ApplicationId=c41a9e77-58f2-4a1d-9d0f-2b6b1e3f77aa",
  "workspace": "/subscriptions/0000.../workspaces/law-az900-lab"
}
```

**Usá la connection string, nunca la instrumentation key sola.** La clave por sí sola no lleva información de endpoints, así que no puede funcionar en nubes soberanas, no puede enrutar por endpoints de ingesta regionales, y no puede alcanzar Live Metrics. La ingesta solo con instrumentation key está obsoleta.

**Paso 3.** Conectala a una aplicación. Para un Azure App Service, la instrumentación automática no requiere cambios de código:

```bash
export CONN=$(az monitor app-insights component show --app "$AI" -g "$RG" --query connectionString -o tsv)

# Against a real App Service:
az webapp config appsettings set \
  --name "<your-webapp>" --resource-group "<its-rg>" \
  --settings \
    APPLICATIONINSIGHTS_CONNECTION_STRING="$CONN" \
    ApplicationInsightsAgent_EXTENSION_VERSION="~3" \
    XDT_MicrosoftApplicationInsights_Mode="recommended" \
  -o none
```

**Paso 4.** Aprendé el esquema de telemetría. Como el componente es basado en workspace, los datos están en el workspace bajo nombres de tabla `App*`; la hoja de consultas de Application Insights muestra los alias heredados en camelCase para las mismas filas.

| Tabla del workspace | Alias de App Insights | Contiene |
|---|---|---|
| `AppRequests` | `requests` | Peticiones entrantes: nombre, duración, resultCode, success |
| `AppDependencies` | `dependencies` | Llamadas salientes: SQL, HTTP, colas — destino, duración, éxito |
| `AppExceptions` | `exceptions` | Excepciones no controladas y registradas, con stack traces |
| `AppTraces` | `traces` | Líneas de log de la aplicación (ILogger, consola) |
| `AppPageViews` | `pageViews` | Cargas de página en el navegador |
| `AppAvailabilityResults` | `availabilityResults` | Resultados de pruebas sintéticas de disponibilidad |
| `AppMetrics` | `customMetrics` | Telemetría numérica personalizada |
| `AppPerformanceCounters` | `performanceCounters` | Contadores de CPU/memoria del host |

**Paso 5.** Consultala. Dos caminos — el plano de datos de App Insights (usa el **App ID**) y el workspace (usa el **GUID del workspace**):

```bash
# Via the Application Insights API — legacy schema names
az monitor app-insights query --app "$AI" -g "$RG" --analytics-query '
requests
| where timestamp > ago(24h)
| summarize Calls = count(), P95 = percentile(duration, 95), Failures = countif(success == false) by name
| top 10 by Calls desc
' -o table
```

```
name                       Calls   P95      Failures
-------------------------  ------  -------  --------
GET /api/orders            18422   412.3    37
POST /api/checkout         3120    1980.7   211
GET /health                86400   4.1      0
```

```bash
# Via the workspace — App* schema, and joinable with everything else in it
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated > ago(24h)
| summarize Calls = count(), P95 = percentile(DurationMs, 95) by Name
| top 10 by Calls desc
' -o table
```

La segunda forma es la razón por la que importan los componentes basados en workspace: `AppRequests` está en la misma base de datos que `AzureActivity`, `AzureDiagnostics` y los datos `Perf` de tus VMs, así que una sola consulta puede unir síntomas de aplicación con causas de infraestructura. Los componentes clásicos no podían hacer esto.

**Paso 6.** Entendé el sampling, porque cambia tus números en silencio. Para controlar el costo, el SDK puede conservar solo una fracción de la telemetría. El **adaptive sampling** (el predeterminado de ASP.NET Core) varía la tasa con la carga. Cada registro conservado lleva `itemCount` = cuántos elementos originales representa.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated > ago(24h)
| summarize Retained = count(), EstimatedTrue = sum(ItemCount), SamplingRate = round(100.0 * count() / sum(ItemCount), 1)
' -o table
```

```
Retained    EstimatedTrue    SamplingRate
----------  ---------------  ------------
21014       84056            25.0
```

Solo se conservó el 25 % de las peticiones. Por lo tanto:

- `count()` **subreporta por 4×**. Usá `sum(ItemCount)` para los conteos.
- `percentile(DurationMs, 95)` sigue siendo ampliamente válido — el sampling es *por operación*, así que las distribuciones de latencia se preservan.
- Una excepción rara específica puede simplemente no estar. El sampling es la primera hipótesis correcta cuando no encontrás una traza que sabés que ocurrió.

**Paso 7.** Trazado distribuido. Application Insights cose una cadena de llamadas usando W3C Trace Context: cada elemento de telemetría lleva `OperationId` (la traza completa) y `ParentId` (el llamador inmediato).

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
let slow =
    AppRequests
    | where TimeGenerated > ago(1h) and Name == "POST /api/checkout"
    | top 1 by DurationMs desc
    | project OperationId, RequestDuration = DurationMs;
slow
| join kind=inner (
    AppDependencies
    | where TimeGenerated > ago(1h)
    | project OperationId, Target, DependencyName = Name, DependencyType, DurationMs, Success
  ) on OperationId
| project Target, DependencyType, DependencyName, DurationMs, Success, RequestDuration
| order by DurationMs desc
' -o table
```

```
Target              DependencyType  DependencyName              DurationMs  Success  RequestDuration
------------------  --------------  --------------------------  ----------  -------  ---------------
sqldb-orders        SQL             SELECT dbo.OrderLines        4180.2      True     4890.6
api-payments        HTTP            POST /v2/authorize           412.8       True     4890.6
st0az900lab.blob    Azure blob      PUT /receipts/9931.pdf       88.1        True     4890.6
```

La petición de 4,89 s pasó 4,18 s en una sola sentencia SQL. Esa es la respuesta, y ninguna métrica de plataforma podría haberla producido.

**Paso 8.** Live Metrics. Un canal separado y de baja latencia: la telemetría se transmite al portal casi en tiempo real y **no se persiste** — así que no cuenta para la facturación de ingesta y no aparece en ninguna tabla. Es la herramienta correcta mientras mirás el despliegue de una versión, y la equivocada para cualquier cosa que necesites mirar mañana.

### Preguntas de comprensión — Lab 7

**Q29.** ¿Dónde almacena físicamente sus datos un componente de Application Insights basado en workspace, y qué capacidad habilita eso que los componentes clásicos no tenían?

**Q30.** El adaptive sampling está al 25 %. ¿Cuáles de estos quedan distorsionados y cuáles no: `count()` de peticiones, `sum(ItemCount)`, el p95 de `DurationMs`, la presencia de una excepción rara específica? Justificá cada uno.

**Q31.** ¿Por qué debés configurar la connection string en lugar de la instrumentation key sola? Dá dos fallas concretas que causa la clave sola.

**Q32.** `OperationId` y `ParentId` — ¿qué identifica cada uno, y cuál te permite reconstruir el *ordenamiento* de una cadena de llamadas?

**Q33.** Mirás un despliegue en Live Metrics y ves un pico de 5xx. Diez minutos después querés reexaminar ese pico exacto. ¿Qué podés hacer, y qué no?

---

## Lab 8 — Elegir la herramienta correcta: ejercicio de decisión

Sin comandos nuevos. Para cada escenario, nombrá la herramienta, el tipo de dato (métrica / log / evento / recomendación), y justificalo en una línea. Escribí tus respuestas antes de abrir la sección plegable.

| # | Escenario |
|---|---|
| **S1** | El equipo de finanzas quiere saber qué VMs están sobredimensionadas. |
| **S2** | Generar guardia en menos de 2 minutos cuando la CPU de una VM supera el 90 % durante 5 minutos. |
| **S3** | Determinar quién eliminó un key vault de producción, y cuándo. |
| **S4** | Determinar qué IP de cliente leyó un blob específico a las 03:14. |
| **S5** | El servicio Azure SQL está degradado en East US y necesitás notificar al canal de guardia. |
| **S6** | Una petición de checkout tardó 9 segundos; encontrá qué llamada aguas abajo la causó. |
| **S7** | Una sola VM está `Unavailable` mientras el resto de la región está bien. |
| **S8** | Demostrar para una auditoría que nadie accedió a un contenedor de almacenamiento en los últimos 5 años. |
| **S9** | Observar las tasas de error segundo a segundo durante un despliegue canary. |
| **S10** | La factura mensual de Azure Monitor se triplicó y nadie sabe por qué. |

### Preguntas de comprensión — Lab 8

**Q34.** Respondé S1–S10.

**Q35.** Enunciá la regla general de decisión que codifica este ejercicio, con la forma "usá métricas cuando…, usá logs cuando…".

---

## Lab 9 — Broche: correlacionar una regresión de la aplicación con un cambio de la plataforma

Este es el ejercicio que solo funciona porque Application Insights y el Activity Log viven en el mismo workspace.

**Escenario.** Aproximadamente a las 11:00 UTC, la latencia p95 de `POST /api/checkout` se triplicó. Nadie admite haber desplegado nada.

**Paso 1.** Establecé el síntoma y su inicio exacto.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppRequests
| where TimeGenerated between (ago(6h) .. now())
| where Name == "POST /api/checkout"
| summarize P95 = percentile(DurationMs, 95), Calls = sum(ItemCount) by bin(TimeGenerated, 15m)
| order by TimeGenerated asc
' -o table
```

```
TimeGenerated          P95      Calls
---------------------  -------  -----
2026-09-05T10:15:00Z   611.4    780
2026-09-05T10:30:00Z   598.2    802
2026-09-05T10:45:00Z   624.9    791
2026-09-05T11:00:00Z   1902.7   776
2026-09-05T11:15:00Z   2044.1   769
```

El volumen de llamadas está plano. Esto no es un problema de carga — el sistema se puso más lento con tráfico constante, lo que apunta a un cambio, no a la capacidad.

**Paso 2.** Localizalo en una capa: tiempo de petición contra tiempo de dependencia.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AppDependencies
| where TimeGenerated between (ago(6h) .. now())
| summarize P95 = percentile(DurationMs, 95) by bin(TimeGenerated, 15m), DependencyType, Target
| where P95 > 200
| order by TimeGenerated asc, P95 desc
' -o table | head
```

```
TimeGenerated          DependencyType  Target        P95
---------------------  --------------  ------------  ------
2026-09-05T10:45:00Z   SQL             sqldb-orders  340.1
2026-09-05T11:00:00Z   SQL             sqldb-orders  1710.5
2026-09-05T11:15:00Z   SQL             sqldb-orders  1854.9
```

La regresión está en la dependencia SQL, no en el código de la aplicación.

**Paso 3.** Correlacioná contra cambios del plano de control — el paso que cierra el caso.

```bash
az monitor log-analytics query --workspace "$LAW_GUID" --analytics-query '
AzureActivity
| where TimeGenerated between (datetime_add("minute", -60, todatetime("2026-09-05T11:00:00Z")) .. todatetime("2026-09-05T11:15:00Z"))
| where CategoryValue == "Administrative" and ActivityStatusValue == "Success"
| project TimeGenerated, Caller, OperationNameValue, _ResourceId
| order by TimeGenerated asc
' -o table
```

```
TimeGenerated          Caller                  OperationNameValue                                 _ResourceId
---------------------  ----------------------  -------------------------------------------------  --------------------------------
2026-09-05T10:58:41Z   svc-deploy@tenant       Microsoft.Sql/servers/databases/write              /.../databases/sqldb-orders
```

Un service principal reescaló la base de datos dos minutos antes de la regresión. El p95 se triplicó porque cambió el tier de servicio.

**Paso 4.** Confirmá con una métrica de plataforma — la corroboración independiente y gratuita.

```bash
export SQLDB=$(az sql db list --ids $(az sql server list --query "[0].id" -o tsv) --query "[?name=='sqldb-orders'].id" -o tsv 2>/dev/null)

az monitor metrics list --resource "$SQLDB" \
  --metric "dtu_consumption_percent" --aggregation Maximum --interval PT15M \
  --start-time "$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[0].timeseries[0].data[].{t:timeStamp, max:maximum}" -o table | tail -6
```

```
T                          Max
-------------------------  -----
2026-09-05T10:30:00+00:00  41.2
2026-09-05T10:45:00+00:00  44.8
2026-09-05T11:00:00+00:00  99.6
2026-09-05T11:15:00+00:00  100.0
```

Tres fuentes independientes — trazas de la aplicación, auditoría del plano de control, métrica de plataforma — convergen en una causa. Esa triangulación es el método de trabajo que este tema existe para enseñar.

**Paso 5.** Codificá el hallazgo para que la próxima ocurrencia se detecte sola.

```bash
cat > /tmp/query-latency.kql <<'EOF'
AppRequests
| where Name == "POST /api/checkout"
| summarize P95 = percentile(DurationMs, 95) by bin(TimeGenerated, 5m)
| where P95 > 1500
EOF

az monitor scheduled-query create \
  --name "alert-checkout-p95" \
  --resource-group "$RG" \
  --scopes "$LAW_ID" \
  --condition "count 'placeholder' > 0" \
  --condition-query placeholder="$(cat /tmp/query-latency.kql)" \
  --window-size 15m \
  --evaluation-frequency 5m \
  --severity 2 \
  --action-groups "$AG_ID" \
  --description "Checkout p95 above 1.5s" \
  -o table
```

```
Enabled    Location    Name                 ResourceGroup      Severity
---------  ----------  -------------------  -----------------  ----------
True       eastus      alert-checkout-p95   rg-az900-mon-lab   2
```

A diferencia de una alerta de métrica, una **log search alert** tiene ámbito de *workspace*, ejecuta KQL arbitrario, y se factura por regla por mes. Es estrictamente más potente y estrictamente más lenta y más cara — por eso la regla práctica es: alertá sobre métricas cuando una métrica alcance, y recurrí a alertas de log solo cuando la condición no pueda expresarse como una.

### Preguntas de comprensión — Lab 9

**Q36.** En el Paso 1, el volumen de llamadas estaba plano mientras el p95 se triplicaba. ¿Por qué esa única observación elimina toda una clase de hipótesis?

**Q37.** El Paso 3 requirió que el Activity Log estuviera en el workspace. ¿Qué se configuró en el Lab 4 para hacerlo posible, y cómo habría sido la investigación sin eso?

**Q38.** El Paso 4 usó una métrica de plataforma para confirmar lo que las trazas ya sugerían. ¿Por qué vale la pena esa corroboración extra, si no produjo ninguna conclusión nueva?

**Q39.** El Paso 5 usó una log search alert. ¿Bajo qué condición habría sido mejor una alerta de métrica, y qué habrías perdido?

---

## Lab 10 — Limpieza

**Paso 1.** Eliminá el diagnostic setting con ámbito de suscripción — **no** está en el grupo de recursos y sobrevive a su eliminación.

```bash
az monitor diagnostic-settings subscription delete \
  --name "diag-activitylog-to-law" --yes -o none

az monitor diagnostic-settings subscription list --query "length(value)"
```

```
0
```

**Paso 2.** Eliminá el diagnostic setting con ámbito de recurso, por la misma razón: es hijo de la cuenta de almacenamiento, que vive en otro lado.

```bash
az monitor diagnostic-settings delete \
  --name "diag-blob-to-law" \
  --resource "$TARGET/blobServices/default" -o none
```

**Paso 3.** Eliminá el grupo de recursos. Esto quita el workspace, el componente de Application Insights, el action group, las reglas de alerta y la processing rule.

```bash
az group delete --name "$RG" --yes --no-wait
```

**Paso 4.** Verificá que no quedó nada huérfano.

```bash
az monitor activity-log alert list --query "[].name" -o tsv
az monitor alert-processing-rule list --query "[].name" -o tsv
az group exists --name "$RG"
```

> **Nota sobre la eliminación del workspace.** Un workspace de Log Analytics eliminado entra en un **estado de soft-delete durante 14 días** y su nombre queda reservado. Recrear un workspace con el mismo nombre dentro de esa ventana *recupera* el anterior, datos incluidos, en lugar de crear uno vacío. Para liberar el nombre de inmediato, usá `az monitor log-analytics workspace delete --force`.

### Preguntas de comprensión — Lab 10

**Q40.** ¿Por qué los dos diagnostic settings necesitan eliminación explícita si `az group delete` quita todo lo del grupo?

**Q41.** Eliminás `law-az900-lab` y lo recreás con el mismo nombre dos días después, esperando un workspace vacío. ¿Qué ocurre en realidad, y cómo conseguís el comportamiento que querías?

---

## Resumen orientado al examen

- **Advisor** = recomendaciones a lo largo de cinco pilares (Reliability, Security, Cost, Operational Excellence, Performance). De solo lectura, derivadas, con score ponderado por consumo. El contenido de seguridad se origina en Microsoft Defender for Cloud.
- **Service Health** = eventos de plataforma personalizados para *tus* servicios y regiones; cuatro clases (service issues, planned maintenance, health advisories, security advisories). **Resource Health** = el veredicto sobre *tu instancia*. Las alertas sobre ambos son **alertas de Activity Log**.
- **Azure Monitor** = el paraguas. Las **métricas** son numéricas, casi en tiempo real, retención de 93 días, gratis. Los **logs** viven en un **workspace de Log Analytics**, se consultan con **KQL**, y se facturan por GB ingerido y retenido.
- Los **diagnostic settings** son lo que enciende los resource logs; sin uno no se recolecta nada. Hasta 5 por recurso, con fan-out a workspace / storage / Event Hub / partner.
- **Alertas** = regla + action group (+ processing rule opcional). Las alertas de métrica son rápidas y baratas; las log search alerts son potentes y más lentas.
- **Application Insights** = APM, siempre basado en workspace, almacenando en un workspace de Log Analytics. Trazado distribuido vía `OperationId`. El sampling implica `sum(ItemCount)`, no `count()`.

---

## Fuentes

- Guía de estudio AZ-900 (lista oficial de habilidades medidas) — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Descripción general de Azure Monitor — <https://learn.microsoft.com/en-us/azure/azure-monitor/overview>
- Azure Monitor Logs / planes de tabla y retención — <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure>
- Diagnostic settings — <https://learn.microsoft.com/en-us/azure/azure-monitor/platform/diagnostic-settings>
- Descripción general de las alertas de Azure Monitor — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview>
- Umbrales dinámicos — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds>
- Alert processing rules — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-processing-rules>
- Common alert schema — <https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-common-schema>
- Descripción general de Application Insights — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview>
- Application Insights basado en workspace — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/create-workspace-resource>
- Sampling en Application Insights — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/sampling>
- Referencia de tablas de Application Insights — <https://learn.microsoft.com/en-us/azure/azure-monitor/app/convert-classic-resource>
- Descripción general de Azure Advisor — <https://learn.microsoft.com/en-us/azure/advisor/advisor-overview>
- Advisor score — <https://learn.microsoft.com/en-us/azure/advisor/azure-advisor-score>
- Descripción general de Azure Service Health — <https://learn.microsoft.com/en-us/azure/service-health/overview>
- Descripción general de Resource Health — <https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview>
- Activity log de Azure — <https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log>
- Referencia rápida de KQL — <https://learn.microsoft.com/en-us/azure/data-explorer/kql-quick-reference>
- Costo y uso de Azure Monitor — <https://learn.microsoft.com/en-us/azure/azure-monitor/cost-usage>

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** `Microsoft.OperationalInsights` es dueño del workspace de Log Analytics (`workspaces`, tablas, búsquedas guardadas, exportación de datos). `Microsoft.Insights` es dueño de los diagnostic settings, las reglas de alerta de métricas, las alertas de activity log, los action groups, los componentes de Application Insights, las configuraciones de autoscale y las data collection rules. La división refleja historia y estratificación: `OperationalInsights` es el *almacén* de logs (originalmente OMS/Operations Management Suite), mientras que `Insights` es el *plano de control de monitorización* que decide qué se recolecta, evalúa y notifica. El almacén es uno de varios destinos posibles — el enrutador es deliberadamente un proveedor separado de aquello hacia lo que enruta.

**Q2.** Las *reglas* de alerta son definiciones y viven bajo `Microsoft.Insights`. Las *instancias* de alerta — los objetos disparados con severidad, `monitorCondition` y `alertState`, más las alert processing rules y los smart groups — viven bajo `Microsoft.AlertsManagement`. Es la misma separación regla/instancia que se ve por todo Azure: `Microsoft.Insights` dice "vigilá X", `Microsoft.AlertsManagement` guarda "X ocurrió, acá está su ciclo de vida". Consultar alertas disparadas golpea al segundo proveedor, así que debe registrarse por separado.

**Q3.** Microsoft Defender for Cloud genera las recomendaciones de seguridad; Advisor las expone como una agregación de conveniencia. Advisor **no** es, por lo tanto, el sistema de registro para la postura de seguridad — es un espejo de solo lectura. Consecuencias: el detalle completo (rutas de ataque, mapeo de cumplimiento normativo, desglose del secure score, automatización de remediación) existe solo en Defender for Cloud; y si Defender for Cloud no está habilitado en una suscripción, el pilar Security de Advisor va a estar escaso o vacío, lo que es fácil de malinterpretar como "estamos seguros".

**Q4.** `savingsAmount` en `extendedProperties` es típicamente una proyección **anualizada** para las recomendaciones de right-sizing de VMs, pero la unidad no está garantizada como uniforme entre tipos de recomendación, y el portal puede mostrar mensual o anual según la vista y el selector de moneda. Debés revisar las propiedades acompañantes (`savingsCurrency`, y la semántica documentada del tipo de recomendación) antes de agregar. Sumar una mezcla de cifras mensuales y anuales en un único número de "ahorros proyectados" es un error de reporte genuinamente común, y se desvía por 12×.

**Q5.** El Advisor score está **ponderado por consumo**, no es un conteo. El score de cada categoría pondera cada recurso evaluado por su gasto (el campo `consumptionUnits` de la salida del Paso 5). Cuarenta recomendaciones repartidas entre recursos baratos, ociosos y no productivos contribuyen casi nada al denominador ponderado, mientras que un puñado de recursos de producción caros y correctamente configurados lo dominan. Un score alto con muchas recomendaciones abiertas significa "las cosas que cuestan dinero están bien configuradas"; no es una afirmación de que existan pocos problemas.

**Q6.** No es un bug — es lo esperado. Las recomendaciones de Advisor se materializan mediante una evaluación periódica, no se computan al leer. Las recomendaciones de costo en particular dependen de una ventana de utilización móvil (comúnmente 7 días) y pueden tardar hasta ~24 horas en refrescarse después de un cambio; incluso tras el refresco, el historial de utilización que justificó la recomendación no desaparece al instante. Qué revisar: la marca de tiempo de `lastUpdated`/refresco de la recomendación, disparar un refresco manual desde la hoja del portal de Advisor, y confirmar en el Activity Log que el redimensionamiento efectivamente se completó. Si persiste después de un ciclo completo de refresco, entonces investigá.

**Q7.** No es contradictorio, y este es el caso normal. Service Health reporta eventos con impacto **amplio y multi-cliente** — un incidente a nivel de región o de servicio. Resource Health reporta **tu única instancia**. Una indisponibilidad `Unplanned` sin evento de Service Health casi siempre significa una **falla localizada**: el host físico que ejecuta tu VM falló, o un único nodo de fabric se degradó. Microsoft no levanta un evento de Service Health por la falla de un host, porque afecta solo a los clientes de ese host. La lectura correcta es "la plataforma rompió *mi* instancia, y se espera que se autorrepare mediante service healing / redeploy" — que es precisamente la falla que los availability sets, las zonas de disponibilidad y los diseños multi-instancia existen para absorber.

**Q8.** Los eventos de Service Health son **registros discretos, irregulares y portadores de texto**, no series temporales numéricas. No tienen valor que agregar, no tienen intervalo de muestreo fijo, y llevan propiedades estructuradas (`incidentType`, `impactedServices`, `communication`) que la gramática de condición de una alerta de métrica (agregación + operador + umbral) no puede expresar. El Activity Log es el flujo de eventos de Azure para exactamente esta forma de datos, y Service Health escribe en él bajo la categoría `ServiceHealth`. Las alertas de Activity Log son un *filtro sobre un flujo de eventos*; las alertas de métrica son un *umbral sobre una serie temporal*. La forma de los datos fuerza la elección.

**Q9.** `properties.incidentType`, fijado en `Incident`, acota la regla a incidencias de servicio en curso y excluye `Maintenance`, `Informational` y `Security`. La contrapartida: dejás de recibir por completo, a través de esa regla, las notificaciones de mantenimiento planificado y los avisos de seguridad. El mantenimiento planificado sí requiere acción genuinamente (drenar un nodo, reprogramar una ventana batch, parchear antes de una fecha de retirada de TLS) — así que el diseño de producción correcto son *dos* reglas con distintos action groups y severidades: incidencias → action group de guardia en Sev 1; mantenimiento y avisos → action group de email/ticket en Sev 3. Sacar el ruido del camino de guardia está bien; eliminarlo no.

**Q10.** El `scopes` de una alerta de Activity Log debe ser una suscripción, un grupo de recursos o un recurso — el Activity Log es un **flujo por suscripción**, y no existe un Activity Log a nivel de tenant o de management group que filtrar. Así que una regla no puede cubrir 30 suscripciones. El remedio estándar es **Azure Policy con efecto `deployIfNotExists` asignada al management group**, que despliega una regla de alerta idéntica (más su action group) en cada suscripción dentro del ámbito y remedia automáticamente las recién creadas. Las alternativas — Bicep/Terraform en un pipeline iterando sobre suscripciones — funcionan pero se desvían a medida que se agregan suscripciones; el enfoque de política se autorrepara.

**Q11.** **Métricas.** Dos propiedades de la tabla lo deciden: (1) **latencia** — las métricas aterrizan en el almacén de series temporales en segundos a ~3 minutos, mientras que la ingesta de logs suma minutos encima, así que un objetivo de detección de 60 segundos no es alcanzable de forma confiable vía Logs; (2) **costo** — las métricas de plataforma como `Http5xx` se recolectan y se alerta sobre ellas gratis, mientras que la misma alerta vía Logs requiere habilitar un diagnostic setting, pagar por GB de ingesta, y pagar por regla de log search alert. Las alertas de métrica además se evalúan por un camino dedicado casi en tiempo real, en lugar de por ejecución programada de KQL.

**Q12.** `SuccessE2ELatency` es una **duración en milisegundos por operación**. `Total` suma esas duraciones a lo largo de cada operación del intervalo, produciendo "el número agregado de milisegundos que todas las peticiones pasaron colectivamente" — un número que crece con el tráfico y que no dice nada sobre qué tan lento fue nada. Con latencia constante se duplica cuando el tráfico se duplica. Las agregaciones significativas para una métrica de latencia son `Average`, `Minimum` y `Maximum`; los `supportedAggregationTypes` de la definición de la métrica listan solo `Average` exactamente por esta razón, y Azure no te va a impedir pedir una sin sentido.

**Q13.** (1) **Métricas personalizadas.** Las métricas que emitís vos — vía la API de custom metrics de Azure Monitor, los `customMetrics` de Application Insights, o el Azure Monitor Agent desde un SO invitado — se facturan por serie temporal / por combinación métrica-dimensión. Solo las métricas *de plataforma* emitidas por el proveedor de recursos son gratis. (2) **Enrutar métricas a Logs.** Un diagnostic setting con una sección `metrics` (como en el Paso 4 del Lab 4) copia los datos de métricas al workspace de Log Analytics, donde se facturan como ingesta de logs ordinaria por GB. Un tercer caso relacionado que vale conocer: las **reglas de alerta de métrica** se facturan por serie temporal monitorizada por mes, así que alertar sobre una métrica gratuita no es en sí gratis — y dividir una alerta por una dimensión de alta cardinalidad multiplica ese cargo.

**Q14.** Agregá un **diagnostic setting** sobre la cuenta de almacenamiento con la categoría de métrica `Transaction` habilitada, apuntando o bien a un workspace de Log Analytics (consultable vía KQL, retención configurable hasta 730 días interactivos y 12 años en total) o a una cuenta de almacenamiento (lo más barato, pero no directamente consultable). El nuevo costo es **ingesta por GB más retención por GB-mes** — los datos de métricas que eran gratis en el almacén de métricas pasan a ser facturables en el momento en que se copian a Logs. Para un requisito de pura retención con acceso infrecuente, enrutar a una cuenta de almacenamiento (o a una tabla del workspace en el plan Auxiliary con retención a largo plazo) es dramáticamente más barato que la retención en plan Analytics; la contrapartida es que releerlos requiere un search job o una herramienta externa en lugar de una consulta interactiva.

**Q15.** **Métricas de plataforma: disponibles.** Emitidas automáticamente por el proveedor de recursos al almacén de métricas; sin configuración, sin costo, ~93 días. **Resource logs: NO disponibles, e irrecuperablemente así.** Sin un diagnostic setting el recurso los emite y la plataforma los descarta — no hay buffer, no hay habilitación retroactiva, y no hay forma de recuperar los datos de ayer activándolo hoy. **Entradas del Activity Log: disponibles.** El Activity Log registra las operaciones del plano de control (crear/actualizar/eliminar) a nivel de suscripción, independientemente de cualquier setting por recurso, y se retiene 90 días gratis. La consecuencia práctica es la más importante de todo este tema: después de un incidente siempre podés ver *que el recurso fue cambiado* y *cómo se desempeñó numéricamente*, pero solo podés ver *qué hizo internamente* si alguien activó los resource logs de antemano.

**Q16.** **Activity Log** — el registro con ámbito de suscripción de las operaciones del **plano de control**: quién llamó a qué API de ARM contra qué recurso, cuándo, con qué resultado. **Resource logs** — registros del **plano de datos** emitidos por el recurso sobre sus propias operaciones internas, disponibles solo mediante un diagnostic setting. Por lo tanto: "se emitió un `DELETE` contra este key vault" es el **Activity Log** (una operación de ARM sobre el recurso); "se leyó un secreto de este key vault" es un **resource log** (categoría `AuditEvent` → `KeyVaultAuditLogs`), porque leer un secreto es una llamada del plano de datos que nunca toca ARM.

**Q17.** Los action groups son recursos **globales**: contienen configuración de notificación (direcciones de email, URLs de webhook, números de SMS) sin plano de datos regional ni estado ligado a una región, y deben ser alcanzables desde reglas de alerta en cualquier región — incluidas las alertas de Activity Log, que son ellas mismas globales porque el Activity Log es un flujo de suscripción independiente de la región. El workspace de Log Analytics, en cambio, es un verdadero **almacén de datos regional**: contiene físicamente los datos de logs ingeridos, así que tiene una región por razones de latencia, residencia de datos y soberanía. La regla generaliza — los recursos que almacenan datos son regionales, los recursos que solo contienen configuración usada entre regiones son globales.

**Q18.** Dos diagnostic settings sobre el mismo recurso (se permiten hasta 5): setting A → **workspace de Log Analytics** con 30 días de retención, para consultas operativas, alertas y correlación; setting B → **cuenta de almacenamiento** con una política de inmutabilidad y una regla de lifecycle management que va moviendo los blobs a Cool y luego a Archive, para la obligación de auditoría de 7 años. Es mucho más barato porque la retención en workspace se factura a aproximadamente $0,13/GB/mes contra el almacenamiento de blobs en tier Archive a una pequeña fracción de centavo por GB/mes — dos o tres órdenes de magnitud de diferencia — y porque no estás pagando tarifas de *ingesta* del plan Analytics por datos que nunca se van a consultar interactivamente. La contrapartida es real: la copia archivada no es consultable con KQL, así que responder la pregunta de un auditor significa un search job, una restauración, o una herramienta externa. Ese es el trade correcto cuando el número esperado de lecturas en siete años es aproximadamente cero.

**Q19.** Sin `WorkspaceResourceId` el componente sería un recurso de Application Insights **clásico** con su propio almacenamiento aislado. Lo que perderías: joins de KQL entre la telemetría de la aplicación y cualquier otro dato del workspace (`AzureActivity`, `AzureDiagnostics`, `Perf`, `Heartbeat`) — es decir, exactamente el broche del Lab 9; retención y configuración de planes de tabla unificadas; RBAC a nivel de workspace y claves administradas por el cliente; Private Link; y precios de commitment tier. Omitirlo ya no es posible porque Application Insights clásico fue **retirado en febrero de 2024** — no se pueden crear componentes clásicos nuevos, y la API de ARM exige el vínculo al workspace.

**Q20.** Log Analytics almacena los datos en **particiones/extents basados en tiempo** ordenados por tiempo de ingesta, con metadatos de marca de tiempo mín./máx. por extent. Un `where TimeGenerated > ago(24h)` al inicio permite al planificador de consultas aplicar **eliminación de particiones**: los extents enteros fuera de la ventana nunca se abren, ni se descomprimen, ni se escanean. Puesto *después* de un `summarize` o un `join`, el filtro ya no puede podar particiones — el motor debe materializar la tabla completa y después descartar filas, así que lee terabytes para devolver kilobytes. En un workspace grande esto es la diferencia entre una consulta de menos de un segundo y un timeout, y es el hábito de KQL de mayor apalancamiento.

**Q21.** No es un bug — es una restricción documentada del plan. El plan de tabla **Basic** admite solo un subconjunto restringido de KQL (consultas de tabla única, un conjunto limitado de operadores, sin `join` entre tablas) y explícitamente **no admite reglas de alerta**. Además factura por consulta en lugar de incluir el costo de consulta en la ingesta. La regla violada: *el plan de tabla debe coincidir con cómo se usan los datos*. Basic es para datos de alto volumen que ingerís para búsqueda forense ocasional; todo aquello sobre lo que alertás, hacés join o consultás rutinariamente pertenece a Analytics. Elegí el plan por el patrón de acceso, no solo por el volumen de ingesta.

**Q22.** **Analytics con retención de 365 días:** ~$2,76/GB de ingesta (≈$1.380/mes por 500 GB) más la retención más allá de los 30 días incluidos a ~$0,13/GB/mes, componiéndose a medida que el corpus crece hacia 6 TB — varios miles de dólares al mes en régimen estacionario. **Basic o Auxiliary más retención a largo plazo:** ingesta a ~$0,65/GB (Basic) o ~$0,15/GB (Auxiliary), con los datos más allá de la retención interactiva conservados a tarifas de largo plazo cercanas a $0,026/GB/mes — cómodamente un orden de magnitud más barato en total. El costo operativo de la opción barata: los datos **no son consultables interactivamente**. Recuperarlos requiere un **search job** o una **restauración**, cada uno facturado por separado, cada uno tardando de minutos a horas, y ninguno utilizable dentro de una regla de alerta ni durante un incidente en vivo. Estás cambiando latencia en tiempo de incidente por costo permanente — el trade correcto para datos que genuinamente nunca se leen, y el equivocado la primera vez que la pregunta de un auditor se convierte en una pregunta en tiempo de caída.

**Q23.** (1) **Datos del tier de ingesta básico para ciertos tipos de datos.** Algunos datos se ingieren gratis por diseño — históricamente los primeros ~5 GB/mes por cuenta de facturación, y tablas específicas como `Usage`, `AzureActivity`, `Heartbeat` y `Operation` no se facturan por ingesta. (2) **Tablas de metadatos y de plataforma** — `Usage` y `Operation` en sí mismas, más la ingesta gratuita del Activity Log, llevan `IsBillable == false`. También vale saber: los **conectores de datos gratuitos de Microsoft Sentinel** y algunos datos de Defender for Cloud ingieren gratis en un workspace habilitado. El punto general es que `IsBillable` es una bandera por registro mantenida por la plataforma, así que `Usage | where IsBillable == true` es la única fuente confiable de lo que realmente estás pagando — no lo calcules a partir de conteos crudos de registros.

**Q24.** **`--window-size`** (granularidad de agregación) es *cuánta historia examina cada evaluación* — con `5m`, cada evaluación promedia los últimos 5 minutos. **`--evaluation-frequency`** es *cada cuánto se ejecuta esa evaluación* — con `1m`, una vez por minuto sobre una ventana deslizante. Son independientes; `5m`/`1m` es una condición suavizada comprobada con frecuencia. Síntoma de `--window-size 1m` en una métrica con picos: **flapping de alertas** — una única muestra anómala de un minuto (una pausa de recolección de basura, un reinicio por despliegue, un batch reintentado) viola el umbral, la regla se dispara, el minuto siguiente es normal, la regla se resuelve, y la guardia recibe un par disparado-luego-resuelto cada pocos minutos. La alerta se vuelve ruido, y las alertas ruidosas se silencian, que es como un incidente real pasa inadvertido.

**Q25.** `monitorCondition: Resolved` significa que la plataforma observó que la condición se volvió verdadera y luego falsa de nuevo — el problema ocurrió y se autorreparó. `alertState: New` significa que **ninguna persona la reconoció ni la cerró**. Entonces: algo se rompió, se recuperó solo, y nadie miró. Lo que esto te dice sobre tu proceso de guardia depende de la frecuencia. Una instancia está bien. Un patrón recurrente de alertas `Resolved`/`New` es señal de que o bien (a) el umbral está demasiado ajustado y genera ruido que se despeja solo y que la gente aprendió a ignorar, o (b) una falla intermitente genuina se autorrepara repetidamente y enmascara un componente que se degrada. Ambas necesitan acción, y ambas son invisibles si tu cola filtra solo por `monitorCondition`. Seguí el conteo de `Resolved`+`New` como métrica de salud del *propio sistema de alertas*.

**Q26.** Sin eso, cada tipo de alerta hace POST de una carga útil JSON estructuralmente distinta: una alerta de métrica anida sus datos bajo una forma, una log search alert bajo otra, una alerta de Activity Log bajo una tercera, y la detección inteligente de Application Insights bajo una cuarta — con nombres de campo distintos para los mismos conceptos (ID de recurso, severidad, hora de disparo, descripción de la condición). Un único receptor de webhook necesitaría un discriminador y un parser por tipo, y se rompería en silencio cada vez que Microsoft versionara una carga útil. El **common alert schema** los normaliza a todos en un único sobre con un bloque `essentials` compartido (alertRule, severity, signalType, monitorCondition, firedDateTime, alertTargetIDs) más un `alertContext` específico del tipo. Un manejador, un parser, y los tipos de alerta nuevos funcionan desde el día uno sin cambiar código.

**Q27.** Los umbrales dinámicos entrenan un modelo sobre el **comportamiento histórico** de la métrica, aprendiendo su nivel base, su varianza y su estacionalidad diaria/semanal. Un recurso recién creado no tiene historia, así que el modelo no tiene con qué distinguir "normal" de "anómalo" y trata la variación ordinaria como desviación — de ahí el disparo constante. A medida que se acumulan datos el modelo converge y el ruido se detiene. El mínimo es aproximadamente **3 días de historia y unas 30 muestras** antes de que el umbral sea significativo; una semana completa es mejor, porque es lo que captura la estacionalidad entre días de semana y fin de semana. Implicancia operativa: nunca habilites umbrales dinámicos como parte del despliegue inicial de un recurso — desplegá el recurso, esperá el período de entrenamiento, y después habilitalos, o vas a entrenar a tu equipo para ignorar la alerta antes de que llegue a funcionar.

**Q28.** **Deshabilitar la regla** detiene la evaluación por completo — no se dispara ninguna alerta, y **no se registra historia**. Perdés el registro de lo que pasó durante la ventana de mantenimiento, que es justo cuando es más probable que las cosas se rompan; si el parche causó una regresión, no tenés telemetría de cuándo la condición se volvió verdadera por primera vez. El riesgo operativo: **la regla se queda deshabilitada**. Alguien la deshabilita a las 02:00 del sábado, la ventana se extiende, nadie la vuelve a habilitar, y la alerta queda silenciosamente apagada durante semanas — un modo de falla con una larga historia de provocar caídas no detectadas. **Una alert processing rule** suprime solo la *acción* (`RemoveAllActionGroups`): las alertas siguen evaluándose, siguen disparándose, siguen apareciendo en la lista de alertas con marcas de tiempo completas, pero no se le avisa a nadie. Tiene una programación declarativa con hora de fin, así que expira sola y no puede olvidarse. Suprimí notificaciones, nunca detección.

**Q29.** Almacena sus datos en el **workspace de Log Analytics** referenciado por `WorkspaceResourceId`, en tablas llamadas `AppRequests`, `AppDependencies`, `AppExceptions`, `AppTraces`, etc. (los nombres `requests`/`dependencies` de la hoja de consultas de App Insights son alias sobre las mismas filas). La capacidad que esto habilita y que los componentes clásicos no tenían: **joins de KQL entre fuentes** — una única consulta puede correlacionar telemetría de aplicación con `AzureActivity`, `AzureDiagnostics`, contadores `Perf` de VMs o datos de Sentinel, que es exactamente lo que hace posible el broche del Lab 9. Los componentes clásicos tenían un almacén separado y aislado; correlacionar una regresión de latencia con un cambio del plano de control significaba exportar ambos y unirlos a mano. Beneficios secundarios: retención y configuración de planes de tabla unificadas, RBAC a nivel de workspace, claves administradas por el cliente, Private Link, y precios de commitment tier sobre toda la telemetría.

**Q30.** **`count()` de peticiones — distorsionado.** Cuenta solo los registros *conservados*, subreportando el volumen real aproximadamente 4× a una tasa del 25 %. **`sum(ItemCount)` — correcto.** Cada registro conservado lleva `ItemCount` = el número de elementos originales que representa, así que sumarlo reconstruye el conteo real; por eso toda agregación de tipo conteo sobre telemetría muestreada debe usar `sum(ItemCount)` en lugar de `count()`. **p95 de `DurationMs` — esencialmente válido.** El sampling en Application Insights es *por operación* y efectivamente aleatorio respecto de la latencia: conserva o descarta junta toda la telemetría de una operación, sin preferir las rápidas ni las lentas. El conjunto conservado es por lo tanto una muestra representativa de la distribución de latencia, y los percentiles se sostienen bien — aunque la confianza en la cola extrema (p99,9) se degrada a medida que el conteo conservado se achica. **Presencia de una excepción rara específica — poco confiable.** Un evento raro tiene ~25 % de probabilidad de sobrevivir al sampling. Su ausencia no es evidencia de que no ocurrió, y por eso "el sampling la descartó" debería ser tu primera hipótesis cuando no encontrás una traza que sabés que sucedió — y por eso la telemetría crítica debe excluirse explícitamente del sampling, no esperarse con optimismo.

**Q31.** La connection string lleva la instrumentation key **más los endpoints**: `IngestionEndpoint`, `LiveEndpoint`, y el `ApplicationId`. Una instrumentation key sola implica los *endpoints predeterminados de la nube pública global*. Dos fallas concretas: (1) **Nubes soberanas y regionales** — en Azure Government, Azure China, o cualquier despliegue que se espere que use un endpoint de ingesta regional, el endpoint predeterminado es incorrecto o inalcanzable, así que la telemetría se descarta en silencio sin que aparezca ningún error en la aplicación; (2) **Live Metrics no funciona** — el stream en vivo usa un `LiveEndpoint` separado que una clave sola no puede aportar, así que la vista en tiempo real queda vacía. Una tercera falla, cada vez más relevante: el enrutamiento por Private Link / endpoint regional no puede expresarse en absoluto con una clave. La ingesta solo con instrumentation key está obsoleta; tratá la connection string como la única configuración soportada.

**Q32.** **`OperationId`** identifica la **traza distribuida completa** — una transacción lógica de extremo a extremo. Cada elemento de telemetría producido en cualquier punto de la cadena de llamadas, a través de cada servicio y proceso, comparte el mismo `OperationId`; filtrar por él recupera la traza completa. **`ParentId`** identifica el **llamador inmediato** — el span específico que invocó a este. Es `ParentId` el que te permite reconstruir el **ordenamiento y el anidamiento**: `OperationId` te da una bolsa desordenada de spans que pertenecen a la misma transacción, mientras que las aristas `ParentId → Id` forman el árbol que muestra qué llamó a qué, en qué secuencia, y qué llamada está anidada dentro de cuál. Ambos se propagan a través de fronteras de proceso mediante la cabecera `traceparent` del W3C Trace Context.

**Q33.** **No podés reexaminarlo en Live Metrics.** Live Metrics es un canal de streaming, no persistido: la telemetría se muestrea y se empuja directamente a la sesión del portal conectada, nunca se escribe en el workspace. No se almacena nada, que es también por lo que no incurre en costo de ingesta y tiene ~1 segundo de latencia. **Lo que sí podés hacer:** consultar la telemetría *persistida* para el mismo rango de tiempo — `AppRequests | where TimeGenerated between (...) | where Success == false` — porque el pipeline de telemetría regular (muestreada) estuvo grabando todo el tiempo, independientemente de si alguien miraba Live Metrics. La distinción a interiorizar: Live Metrics es un instrumento, no una grabadora. Usalo para mirar un despliegue en el momento; usá Logs para reconstruirlo después. Si un pico importa, capturá la marca de tiempo mientras estás mirando, porque esa marca de tiempo es lo único que Live Metrics deja atrás.

**Q34.** Respuestas de los escenarios:

- **S1** — **Azure Advisor**, pilar Cost (*recomendación*). Advisor ya computa el right-sizing a partir del P95 de CPU/memoria sobre una ventana móvil y reporta una cifra de ahorro con su evidencia; construir esto a mano desde métricas duplica trabajo que Microsoft hace gratis.
- **S2** — **Alerta de métrica de Azure Monitor** sobre `Percentage CPU` (*métrica*), `--window-size 5m --evaluation-frequency 1m`, conectada a un action group de guardia. Métricas por latencia y costo: la métrica de plataforma es gratis y se evalúa casi en tiempo real, algo que un camino basado en logs no puede igualar.
- **S3** — **Activity Log** (*evento*), consultado directamente o vía `AzureActivity` en el workspace. Eliminar un key vault es una operación de ARM del plano de control, registrada con `Caller` y marca de tiempo independientemente de cualquier diagnostic setting.
- **S4** — **Resource logs** (*log*): la categoría `StorageRead` de la cuenta de almacenamiento → `StorageBlobLogs`, habilitada por un diagnostic setting. Leer un blob es una operación del plano de datos y nunca aparece en el Activity Log. Críticamente, esto solo funciona si el setting existía *antes* de las 03:14.
- **S5** — **Alerta de Service Health**, es decir, una **alerta de Activity Log** con `category = ServiceHealth` y `properties.incidentType = Incident` (*evento*), apuntando a un action group con un webhook al canal. No una alerta de métrica — los datos son un evento discreto portador de texto, no una serie temporal.
- **S6** — Trazado distribuido de **Application Insights** (*log*): tomá el `OperationId` de la petición y hacé join de `AppDependencies` sobre él, ordenando por `DurationMs`, exactamente como en el Paso 7 del Lab 7. Ninguna métrica de plataforma puede atribuir latencia a una llamada aguas abajo específica.
- **S7** — **Resource Health** (*evento*), leyendo `availabilityState` y especialmente `reasonType` para separar una falla de plataforma (`Unplanned`) de una acción propia (`UserInitiated`). Service Health no mostraría nada — la falla de un solo host no es un incidente multi-cliente.
- **S8** — **Diagnostic setting → cuenta de almacenamiento** con una política de inmutabilidad y tiering de ciclo de vida hacia Archive (*log*, archivado). Cinco años de retención en workspace costarían órdenes de magnitud más por datos que no se van a leer prácticamente nunca; la contrapartida es que responderle al auditor requiere un search job o herramientas externas en lugar de una consulta en vivo.
- **S9** — **Live Metrics** (*transmitido, no persistido*). Latencia por debajo del segundo y sin costo de ingesta, que es lo que exige "segundo a segundo durante un canary". Notá el techo: no se almacena nada, así que capturá marcas de tiempo mientras mirás y reconstruí después desde `AppRequests`.
- **S10** — **Tabla `Usage` en el workspace** (*log*): `Usage | where IsBillable == true | summarize sum(Quantity) by DataType, bin(TimeGenerated, 1d)`. Esto atribuye el aumento a una tabla específica y a un día específico, que es lo que convierte "la factura se triplicó" en "alguien habilitó `allLogs` en un recurso charlatán el día 12".

**Q35.** **Usá métricas cuando la pregunta es "cuánto / qué tan rápido / está arriba", la respuesta es numérica, y la necesitás rápido o barato** — alertas, dashboards, tendencias de capacidad, triage de primera respuesta. Las métricas son pre-agregadas, de baja latencia, de esquema fijo y gratuitas para los datos de plataforma, pero no pueden decirte *cuál* petición, *cuál* llamador, ni *por qué*. **Usá logs cuando la pregunta es "qué pasó exactamente, a qué entidad, en qué orden, y por qué"** — investigación, correlación, auditoría, forense. Los logs llevan estructura arbitraria y contexto completo y pueden unirse entre fuentes, pero cuestan por GB y llegan minutos después. La regla operativa práctica que se sigue: **detectá con métricas, diagnosticá en logs.** Alertá sobre la señal barata y rápida, y después pivoteá a la cara y rica una vez que ya hay una persona mirando. Invertir esto — construir el sistema de alertas sobre consultas de log porque los logs son más expresivos — es el error de diseño más común y más caro de Azure Monitor.

**Q36.** Volumen de llamadas plano con p95 triplicado **elimina toda hipótesis impulsada por carga y capacidad**: picos de tráfico, un evento viral, tormentas de reintentos, una avalancha de vecino ruidoso en tu propio tráfico, autoscale rezagado respecto de la demanda. Todas esas necesariamente aparecen como volumen de peticiones incrementado. Si el sistema se puso más lento haciendo la misma cantidad de trabajo, el *trabajo en sí* se volvió más caro — lo que apunta a un cambio: un despliegue, un cambio de configuración o de SKU, un cambio de esquema o de índice, una dependencia degradándose, o un recurso siendo limitado. Esta única observación recorta el espacio de hipótesis aproximadamente a la mitad antes de cualquier consulta adicional, y por eso establecer la relación volumen/latencia es el primer paso correcto en cualquier investigación de latencia y no una idea tardía.

**Q37.** El Paso 3 del Lab 4 creó un **diagnostic setting con ámbito de suscripción** que exporta las categorías `Administrative` (y otras) del Activity Log al workspace de Log Analytics, que es lo que puebla la tabla `AzureActivity`. Sin eso, el Activity Log sigue existiendo en su propio almacén de 90 días y la misma información es recuperable — vía `az monitor activity-log list`, la hoja del portal, o la API del Activity Log. Pero sería un paso **separado, manual y no unible**: exportarías o mirarías a ojo una lista filtrada por tiempo, leerías marcas de tiempo a mano, y las correlacionarías mentalmente contra los resultados de KQL de los Pasos 1–2. Con la exportación en su lugar, la telemetría de la aplicación y la auditoría del plano de control están en una sola base de datos, así que la correlación es una única consulta que puede guardarse, usarse para alertar y ponerse en un workbook. La diferencia no es el acceso a los datos — es si la correlación es un artefacto repetible o una persona haciendo aritmética de marcas de tiempo durante un incidente.

**Q38.** Porque la evidencia de las trazas y la evidencia de auditoría son ambas **circunstanciales respecto del mecanismo**. `AppDependencies` prueba que las llamadas SQL se pusieron más lentas; `AzureActivity` prueba que alguien escribió sobre el recurso de base de datos. Ninguna prueba que la escritura *causó* la lentitud — la operación podría haber sido una actualización de etiquetas sin relación, y la ralentización de SQL podría haber tenido una causa coincidente. Que `dtu_consumption_percent` pase de ~44 % a 100 % exactamente en la transición es **evidencia independiente, redactada por la plataforma, del mecanismo**: la base de datos está ahora saturada de recursos, que es lo que produce una reducción de tier y lo que una actualización de etiquetas no produce. Tres fuentes de procedencia distinta — el propio SDK de la aplicación, el rastro de auditoría de ARM, y las métricas del proveedor de recursos — convergiendo en una explicación es una afirmación materialmente más fuerte que dos cualesquiera de ellas. Importa porque la salida de esta investigación es una solicitud de cambio contra el sistema de otra persona, y "creemos que el reescalado lo hizo" se discute mientras que "el techo de DTU se alcanzó dos minutos después del reescalado documentado" no.

**Q39.** Una **alerta de métrica** habría sido mejor si la condición fuera expresable sobre una única métrica de plataforma en un único recurso — por ejemplo, alertar sobre el `HttpResponseTime` promedio del App Service o sobre el `dtu_consumption_percent` de la base de datos SQL. Sería **más rápida** (evaluación casi en tiempo real en lugar de una ejecución programada de KQL con frecuencia de 5 minutos, así que detección en ~1–2 minutos en vez de 5–10), **más barata** (facturada por serie temporal en lugar de por regla por mes, sin costo de consulta), y operativamente más simple. Lo que perderías: la **precisión de la condición**. La alerta de métrica no puede expresar "p95 de `DurationMs` para la operación específica llamada `POST /api/checkout`" — eso requiere filtrar telemetría por nombre de operación y computar un percentil, que es una consulta KQL, no una agregación de métrica. Terminarías alertando sobre la latencia promedio de *todos* los endpoints, donde un camino de checkout lento queda diluido por un endpoint `/health` rápido y de alto volumen y puede que nunca cruce el umbral. La regla general se sostiene — preferí las alertas de métrica y recurrí a las log search alerts solo cuando la condición genuinamente no pueda expresarse como una — y este es un caso donde genuinamente no puede.

**Q40.** Porque un diagnostic setting **no es hijo del workspace, ni miembro del grupo de recursos que eliminaste** — es un recurso hijo del objeto *monitorizado*. El setting con ámbito de suscripción (`diag-activitylog-to-law`) es hijo de la **suscripción**, que obviamente sobrevive a cualquier grupo de recursos. El setting con ámbito de recurso (`diag-blob-to-law`) es hijo de la **cuenta de almacenamiento**, que vive en un grupo de recursos distinto. `az group delete` elimina solo los recursos contenidos en ese grupo; ambos settings lo sobreviven, apuntando ahora a un workspace de destino que ya no existe. La consecuencia práctica es una clase de huérfano que se acumula calladamente en suscripciones reales: settings que referencian workspaces o Event Hubs eliminados, fallando silenciosamente al entregar, ensuciando la hoja de Diagnostic settings del recurso, y ocasionalmente bloqueando la eliminación del propio recurso monitorizado. Eliminá el enrutador antes de eliminar el destino.

**Q41.** Recuperás el **workspace viejo, con sus datos**. Los workspaces de Log Analytics eliminados entran en un **estado de soft-delete durante 14 días** durante el cual el nombre queda reservado en la suscripción; crear un workspace con el mismo nombre, grupo de recursos y suscripción dentro de esa ventana realiza una **recuperación**, restaurando el workspace anterior incluidos sus datos ingeridos, la configuración de tablas y los ajustes de retención — no uno nuevo y vacío. Para obtener un workspace genuinamente vacío tenés dos opciones: eliminar con **`az monitor log-analytics workspace delete --force`**, que realiza una eliminación permanente (hard delete) y libera el nombre de inmediato; o simplemente elegir otro nombre. El comportamiento existe como red de seguridad contra la eliminación accidental de un almacén de observabilidad, y vale conocerlo antes de un simulacro de respuesta a incidentes: recuperar un workspace eliminado por error está a un `create` de distancia, y solo dentro de esos 14 días.

</details>