# Tema 4.2 — Recursos para facturación, presupuesto y gestión de costos
## Ejercicios guiados (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

> **Peso en el examen del Dominio 4 (Billing, Pricing, and Support): 12%. Peso de la tarea 4.2: 4.0.**
> Referencia: [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

### Cómo usar este laboratorio

Estos ejercicios se ejecutan contra una **cuenta de AWS real**. La mayoría de los pasos son de solo lectura y gratuitos; los que crean recursos están marcados. Un puñado de llamadas a la API son facturables — están señalizadas en línea con 💲 y se indica el precio exacto. Todo lo que se crea se destruye en el Ejercicio 11.

Hay dos hechos estructurales que tenés que interiorizar antes de escribir nada, porque provocan más laboratorios fallidos que cualquier otro detalle:

1. **La facturación es un servicio global anclado a `us-east-1`.** Los endpoints de `ce` (Cost Explorer), `budgets`, `cur`, `bcm-data-exports`, `organizations`, `freetier`, `billingconductor` y `support` viven en `us-east-1` (y en `us-gov-west-1` / `cn-northwest-1` para esas particiones). El namespace `AWS/Billing` de CloudWatch solo publica métricas en `us-east-1`. Si ejecutás estos comandos con `--region eu-west-1` vas a obtener `EndpointConnectionError` o un conjunto de resultados vacío, no un mensaje útil.
2. **Los datos de facturación solo son visibles desde la management account, y solo si el acceso IAM a billing está activado.** En una AWS Organization, las member accounts ven su propio uso, pero la factura pertenece a la management account (payer). Y hasta un principal IAM con `AdministratorAccess` completo queda bloqueado de las páginas de billing hasta que se habilita *Activate IAM Access* en **Account Settings → IAM user and role access to Billing information**. Ese interruptor es a nivel de cuenta, exclusivo del usuario root y, en la práctica, de una sola dirección.

Fuentes de este laboratorio:
- [AWS Billing and Cost Management User Guide](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html)
- [AWS Cost Management API Reference](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html)
- [AWS CLI v2 Command Reference](https://awscli.amazonaws.com/v2/documentation/api/latest/index.html)

---

## Ejercicio 0 — Establecer el plano de control

**Objetivo:** confirmar quién sos, dónde están los endpoints de facturación y si tenés permiso para leer datos de costos.

1. Confirmá la versión de la CLI. Todo lo que sigue asume **AWS CLI v2**; la v1 carece por completo de `bcm-data-exports` y `freetier`.

   ```bash
   aws --version
   ```

   ```
   aws-cli/2.31.6 Python/3.13.7 Linux/6.11.0 exe/x86_64.fedora.44
   ```

2. Identificá el principal que hace la llamada y la cuenta a la que pertenece.

   ```bash
   aws sts get-caller-identity --output table
   ```

   ```
   -------------------------------------------------------------------------------
   |                              GetCallerIdentity                              |
   +-------------+---------------------------------------------------------------+
   |  Account    |  123456789012                                                 |
   |  Arn        |  arn:aws:sts::123456789012:assumed-role/FinOpsReadOnly/dalmine|
   |  UserId     |  AROAEXAMPLEID:dalmine                                         |
   +-------------+---------------------------------------------------------------+
   ```

3. Determiná si esta cuenta es standalone o parte de una Organization. Esta única llamada decide si el resto del laboratorio trata sobre *tu* factura o sobre la factura *de todos*.

   ```bash
   aws organizations describe-organization --region us-east-1
   ```

   ```json
   {
       "Organization": {
           "Id": "o-a1b2c3d4e5",
           "Arn": "arn:aws:organizations::123456789012:organization/o-a1b2c3d4e5",
           "FeatureSet": "ALL",
           "MasterAccountArn": "arn:aws:organizations::123456789012:account/o-a1b2c3d4e5/123456789012",
           "MasterAccountId": "123456789012",
           "MasterAccountEmail": "payer@example.com"
       }
   }
   ```

   Si la cuenta es standalone obtenés `AWSOrganizationsNotInUseException` — ese es un resultado válido, no un error en tu configuración. Notá que la API sigue diciendo `MasterAccountId`; la consola y la documentación lo renombraron a **management account** en 2021, pero el formato de cable quedó congelado por compatibilidad hacia atrás.

4. Inspeccioná los permisos IAM que tu principal realmente necesita. Las acciones de billing migraron de los namespaces gruesos y heredados `aws-portal:*` y `purchase-orders:ViewPurchaseOrders` a servicios de grano fino en julio de 2023. Hoy, una política FinOps mínima de solo lectura se ve así — guardala como `finops-readonly.json` para referencia:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "ReadCostAndUsage",
         "Effect": "Allow",
         "Action": [
           "ce:Get*",
           "ce:List*",
           "ce:Describe*",
           "budgets:ViewBudget",
           "budgets:DescribeBudget*",
           "cur:DescribeReportDefinitions",
           "bcm-data-exports:GetExport",
           "bcm-data-exports:ListExports",
           "freetier:GetFreeTierUsage",
           "billing:Get*",
           "billing:List*",
           "payments:List*",
           "tax:List*",
           "invoicing:List*",
           "invoicing:Get*",
           "compute-optimizer:Get*",
           "organizations:DescribeOrganization",
           "organizations:ListAccounts"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

   Notá que cada acción acá lleva `Resource: "*"`. Las APIs de Cost Management casi no tienen alcance por recurso: no podés escribir una política IAM que diga "este rol puede leer la factura únicamente de la cuenta `dev`". El aislamiento por cuenta se logra mediante *límites de cuenta*, no mediante ARNs de recurso en IAM.

5. Verificá que Cost Explorer esté habilitado. La primera vez que alguien abre Cost Explorer, AWS empieza a preparar el conjunto de datos; puede tardar hasta **24 horas** antes de que la API devuelva datos, y rellena hacia atrás los **12 meses** previos.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-01,End=2026-09-04 \
     --granularity DAILY \
     --metrics "UnblendedCost" \
     --output json
   ```

   Si Cost Explorer nunca fue habilitado, obtenés:

   ```
   An error occurred (DataUnavailableException) when calling the GetCostAndUsage operation:
   Data is not available. Please enable Cost Explorer in the Billing console.
   ```

### ✅ Comprobá lo aprendido — Bloque 0

- **0.1** Un rol IAM en la management account tiene `AdministratorAccess` adjunto, pero las llamadas a `ce:GetCostAndUsage` devuelven `AccessDeniedException`. IAM no muestra ningún Deny explícito y no aplica ninguna SCP. ¿Qué único ajuste a nivel de cuenta es casi seguramente la causa?
- **0.2** ¿Por qué falla `aws ce get-cost-and-usage --region eu-west-1` aunque todos tus recursos estén en `eu-west-1`?
- **0.3** El administrador de una member account quiere ver la factura consolidada de toda la Organization. ¿Puede IAM otorgar esto? Explicalo en una oración.
- **0.4** Acabás de habilitar Cost Explorer por primera vez en una cuenta de dos años de antigüedad. ¿Hasta qué punto en el pasado llegarán los datos históricos, y cuándo aparecerán?

---

## Ejercicio 1 — Cost Explorer: la herramienta de análisis

**Objetivo:** responder "¿a dónde se fue el dinero?" con la herramienta diseñada para el análisis interactivo, filtrado y agrupado, sobre los últimos 12–38 meses.

💲 **Cada petición a la API de Cost Explorer cuesta USD 0.01**, incluida cada página paginada. La consola es gratuita. Esta es la sorpresa más común en un proyecto de automatización FinOps: un script ingenuo que pagina datos diarios a nivel de recurso puede generar miles de peticiones facturables.

1. Obtené el gasto del mes pasado desglosado por servicio, unblended.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=DIMENSION,Key=SERVICE
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   {
                       "Keys": ["Amazon Elastic Compute Cloud - Compute"],
                       "Metrics": { "UnblendedCost": { "Amount": "1412.8300000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["Amazon Relational Database Service"],
                       "Metrics": { "UnblendedCost": { "Amount": "603.1900000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["Amazon Simple Storage Service"],
                       "Metrics": { "UnblendedCost": { "Amount": "88.4200000", "Unit": "USD" } }
                   },
                   {
                       "Keys": ["AWS Cost Explorer"],
                       "Metrics": { "UnblendedCost": { "Amount": "0.4700000", "Unit": "USD" } }
                   }
               ],
               "Estimated": false
           }
       ],
       "DimensionValueAttributes": []
   }
   ```

   Hay dos detalles que vale la pena leer con atención. `"Total": {}` está **vacío siempre que agrupás** — los totales se mudan a los grupos y tenés que sumarlos vos mismo. `"Estimated": false` significa que el período de facturación está cerrado y finalizado; una consulta del mes en curso devuelve `true` y los números todavía pueden moverse.

2. Compará las cuatro métricas de costo sobre el mismo período. Este es el ejercicio que enseña el vocabulario que evalúa el examen.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "BlendedCost" "UnblendedCost" "AmortizedCost" "NetAmortizedCost" \
     --query 'ResultsByTime[0].Total'
   ```

   ```json
   {
       "BlendedCost":      { "Amount": "2104.9100000", "Unit": "USD" },
       "UnblendedCost":    { "Amount": "2104.9100000", "Unit": "USD" },
       "AmortizedCost":    { "Amount": "2338.7700000", "Unit": "USD" },
       "NetAmortizedCost": { "Amount": "2201.4400000", "Unit": "USD" }
   }
   ```

   - **UnblendedCost** — el cargo en base caja tal como aparece en la factura de esa cuenta, el día en que se incurrió. Una Reserved Instance All Upfront muestra la tarifa completa en el mes uno y USD 0.00 después.
   - **BlendedCost** — la tarifa promedio a lo largo de una Organization. Si la cuenta A posee una Reserved Instance y el uso de la cuenta B consume el descuento, el blended cost reparte la tarifa reducida entre ambas. Es un artefacto contable para chargeback interno y es idéntico al unblended en una cuenta standalone sin reservas.
   - **AmortizedCost** — los compromisos upfront (cuotas de RI/Savings Plans) repartidos de forma pareja a lo largo del plazo. Esta es la métrica que hay que usar cuando querés saber "cuánto costó *realmente* operar este mes", porque elimina el pico de un prepago anual.
   - **NetAmortizedCost** — amortizado, después de aplicar descuentos y créditos. "Net" siempre significa *después de créditos/descuentos* en el vocabulario de facturación de AWS.

3. Cambiá la granularidad a `HOURLY` — disponible solo para los últimos 14 días, y solo si la granularidad horaria está habilitada en las preferencias de Cost Management (tiene su propio cargo).

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-03T00:00:00Z,End=2026-09-04T00:00:00Z \
     --granularity HOURLY \
     --metrics "UnblendedCost" \
     --query 'length(ResultsByTime)'
   ```

   ```
   24
   ```

4. Enumerá las dimensiones por las que tenés permitido filtrar y agrupar. Hay un límite duro de **dos** cláusulas `--group-by` por petición.

   ```bash
   aws ce get-dimension-values \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --dimension PURCHASE_TYPE \
     --context COST_AND_USAGE \
     --query 'DimensionValues[].Value'
   ```

   ```json
   [
       "On Demand Instances",
       "Savings Plans",
       "Standard Reserved Instances",
       "Spot Instances"
   ]
   ```

5. Producí un pronóstico. El forecast de Cost Explorer es un modelo de machine learning sobre tu propia historia, expresado con un intervalo de confianza. `Start` debe ser **hoy o posterior**.

   ```bash
   aws ce get-cost-forecast \
     --region us-east-1 \
     --time-period Start=2026-09-04,End=2026-10-01 \
     --metric UNBLENDED_COST \
     --granularity MONTHLY \
     --prediction-interval-level 80
   ```

   ```json
   {
       "Total": { "Amount": "1902.4400000", "Unit": "USD" },
       "ForecastResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-09-04", "End": "2026-10-01" },
               "MeanValue": "1902.4400000",
               "PredictionIntervalLowerBound": "1744.1000000",
               "PredictionIntervalUpperBound": "2060.7800000"
           }
       ]
   }
   ```

   Un forecast requiere aproximadamente **dos meses consecutivos** de historia; una cuenta nueva devuelve `DataUnavailableException`. El forecast cubre únicamente el período *restante* — no incluye lo que ya gastaste este mes.

### ✅ Comprobá lo aprendido — Bloque 1

- **1.1** Tu consulta agrupada por `SERVICE` devuelve `"Total": {}`. ¿Es un bug? ¿Qué debe hacer tu código?
- **1.2** En enero tu equipo pagó USD 12 000 All Upfront por un Compute Savings Plan de 1 año. En marzo, ¿qué métrica muestra ~USD 1 000 por ese compromiso y cuál muestra USD 0.00?
- **1.3** Una cuenta standalone sin reservas reporta `BlendedCost == UnblendedCost`. ¿Por qué eso es esperable y no sospechoso?
- **1.4** Una función Lambda llama a `GetCostAndUsage` con granularidad `DAILY` agrupada por `RESOURCE_ID`, paginando 40 páginas, una vez por hora. Estimá el cargo mensual de la API de Cost Explorer.
- **1.5** Aparece `"Estimated": true` en el resultado de tu mes en curso. ¿Qué significa para un informe que estás por enviar a Finanzas?

---

## Ejercicio 2 — Cost allocation tags: hacer legible la factura

**Objetivo:** convertir una factura sin etiquetar, con forma de servicios, en una factura con la forma de tu organización.

Un tag en un recurso es invisible para la facturación hasta que se lo **activa como cost allocation tag** en la payer account. La activación no es retroactiva por defecto y tarda hasta **24 horas** en aparecer en Cost Explorer.

1. Listá las claves de tags que AWS vio en tus recursos y su estado de activación actual.

   ```bash
   aws ce list-cost-allocation-tags --region us-east-1 --max-results 20
   ```

   ```json
   {
       "CostAllocationTags": [
           { "TagKey": "Environment", "Type": "UserDefined", "Status": "Active",   "LastUpdatedDate": "2026-06-02", "LastUsedDate": "2026-09-03" },
           { "TagKey": "Team",        "Type": "UserDefined", "Status": "Inactive", "LastUpdatedDate": "2026-08-28" },
           { "TagKey": "aws:createdBy", "Type": "AWSGenerated", "Status": "Active", "LastUpdatedDate": "2026-01-15" }
       ]
   }
   ```

   Las claves `UserDefined` son tuyas y aparecen en la factura con el prefijo `user:`. Las claves `AWSGenerated` las crea AWS (`aws:createdBy`, `aws:cloudformation:stack-name`, …), llevan el prefijo `aws:` y no las podés crear ni borrar — solo activar.

2. Activá la clave `Team`. ⚠️ **Paso mutante, solo payer account.**

   ```bash
   aws ce update-cost-allocation-tags-status \
     --region us-east-1 \
     --cost-allocation-tags-status TagKey=Team,Status=Active
   ```

   ```json
   { "Errors": [] }
   ```

   Un array `Errors` vacío es éxito. No hay otra salida.

3. Backfill. Desde 2024 podés aplicar retroactivamente un tag activado a datos históricos, hasta 12 meses hacia atrás, empezando desde el primer día de un mes.

   ```bash
   aws ce start-cost-allocation-tag-backfill \
     --region us-east-1 \
     --backfill-from 2026-06-01T00:00:00Z
   ```

   ```json
   {
       "BackfillRequest": {
           "BackfillFrom": "2026-06-01T00:00:00Z",
           "RequestedAt": "2026-09-04T14:22:07Z",
           "BackfillStatus": "REQUESTED"
       }
   }
   ```

   Solo **un backfill cada 24 horas** por payer account. Consultá el progreso con `aws ce list-cost-allocation-tag-backfill-history --region us-east-1`.

4. Consultá el costo agrupado por el tag. Notá que la sintaxis de la clave de grupo difiere de la de una dimensión.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=TAG,Key=Team
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Team$"],          "Metrics": { "UnblendedCost": { "Amount": "731.0200000", "Unit": "USD" } } },
                   { "Keys": ["Team$platform"],  "Metrics": { "UnblendedCost": { "Amount": "902.5500000", "Unit": "USD" } } },
                   { "Keys": ["Team$data"],      "Metrics": { "UnblendedCost": { "Amount": "471.3400000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ]
   }
   ```

   `Team$` con un valor vacío después del `$` es **gasto sin etiquetar** — el 35% de la factura en este ejemplo. Ese número es el verdadero resultado de este ejercicio: es tu brecha de cobertura de tagging, y es la razón por la que fracasan los programas de showback.

5. Algunos costos nunca pueden llevar un tag de recurso — cargos de soporte, impuestos, parte de la transferencia de datos y los propios cargos de la API de Cost Explorer. Confirmalo filtrando por un tipo de registro que no tiene recurso detrás.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Tax","Support"]}}' \
     --group-by Type=DIMENSION,Key=RECORD_TYPE
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Support"], "Metrics": { "UnblendedCost": { "Amount": "210.4900000", "Unit": "USD" } } },
                   { "Keys": ["Tax"],     "Metrics": { "UnblendedCost": { "Amount": "441.9800000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ]
   }
   ```

### ✅ Comprobá lo aprendido — Bloque 2

- **2.1** Etiquetaste 400 instancias EC2 con `Team=platform` el lunes y el tag no aparece en Cost Explorer el martes a la mañana. Nombrá las dos razones independientes por las que esto puede pasar.
- **2.2** ¿Qué representa la clave de grupo `Team$` (nada después del signo dólar), y por qué su magnitud es el número más importante de la página?
- **2.3** ¿Por qué no se puede borrar la clave de tag `aws:cloudformation:stack-name`?
- **2.4** Los cargos de soporte y los impuestos aparecen en la factura pero nunca bajo un tag de equipo. ¿Qué herramienta de este tema puede, aun así, asignarlos a un equipo?

---

## Ejercicio 3 — Cost Categories: reglas de asignación por encima de los tags

**Objetivo:** agrupar el gasto por reglas — cuenta, tag, servicio, región — en dimensiones de negocio, incluido un mecanismo para repartir costos compartidos que los tags no pueden expresar.

⚠️ **Paso mutante.** Las Cost Categories son gratuitas.

1. Escribí el conjunto de reglas. Las reglas se evalúan **en orden**; gana la primera coincidencia.

   ```bash
   cat > cc-rules.json <<'JSON'
   [
     {
       "Value": "platform",
       "Type": "REGULAR",
       "Rule": {
         "Tags": { "Key": "Team", "Values": ["platform"], "MatchOptions": ["EQUALS"] }
       }
     },
     {
       "Value": "data",
       "Type": "REGULAR",
       "Rule": {
         "Or": [
           { "Tags": { "Key": "Team", "Values": ["data"], "MatchOptions": ["EQUALS"] } },
           { "Dimensions": { "Key": "LINKED_ACCOUNT", "Values": ["222222222222"], "MatchOptions": ["EQUALS"] } }
         ]
       }
     },
     {
       "Value": "shared-platform",
       "Type": "REGULAR",
       "Rule": {
         "Dimensions": { "Key": "SERVICE", "Values": ["Amazon Elastic Container Service for Kubernetes"], "MatchOptions": ["EQUALS"] }
       }
     }
   ]
   JSON
   ```

2. Agregá una **split charge rule** — la funcionalidad que no tiene equivalente en el tagging. Toma el costo de un bucket compartido y lo distribuye entre buckets destino en proporción a su propio gasto.

   ```bash
   cat > cc-split.json <<'JSON'
   [
     {
       "Source": "shared-platform",
       "Targets": ["platform", "data"],
       "Method": "PROPORTIONAL"
     }
   ]
   JSON
   ```

   `Method` acepta `PROPORTIONAL` (ponderado por el costo de cada destino), `FIXED` (con porcentajes explícitos en `Parameters`) o `EVEN`.

3. Creá la definición.

   ```bash
   aws ce create-cost-category-definition \
     --region us-east-1 \
     --name Team \
     --rule-version CostCategoryExpression.v1 \
     --rules file://cc-rules.json \
     --split-charge-rules file://cc-split.json \
     --default-value Unallocated
   ```

   ```json
   {
       "CostCategoryArn": "arn:aws:ce::123456789012:costcategory/a1b2c3d4-5e6f-7890-abcd-ef1234567890",
       "EffectiveStart": "2026-09-01T00:00:00Z"
   }
   ```

   `EffectiveStart` es el **primer día del mes en curso** — una Cost Category aplica desde el inicio del mes en que la creás, nunca desde hoy. La aplicación retroactiva (hasta 12 meses) se solicita por separado.

4. Consultá por la nueva categoría.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-09-01,End=2026-09-04 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=COST_CATEGORY,Key=Team
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-09-01", "End": "2026-09-04" },
               "Total": {},
               "Groups": [
                   { "Keys": ["Team$platform"],    "Metrics": { "UnblendedCost": { "Amount": "142.7700000", "Unit": "USD" } } },
                   { "Keys": ["Team$data"],        "Metrics": { "UnblendedCost": { "Amount": "88.0400000", "Unit": "USD" } } },
                   { "Keys": ["Team$Unallocated"], "Metrics": { "UnblendedCost": { "Amount": "19.6100000", "Unit": "USD" } } }
               ],
               "Estimated": true
           }
       ]
   }
   ```

   Notá que `shared-platform` ya no aparece como grupo propio — la split charge rule lo redistribuyó en `platform` y `data` en proporción a su gasto.

### ✅ Comprobá lo aprendido — Bloque 3

- **3.1** Un recurso lleva `Team=data` **y** corre en la linked account `222222222222`, que la regla 2 también matchea. No se rompe nada. Ahora imaginate un recurso que matchea tanto la regla 1 como la regla 2 — ¿qué valor gana, y por qué?
- **3.2** Creás una Cost Category el 20 de septiembre. ¿Desde qué fecha aplica?
- **3.3** Dá un problema de asignación que una Cost Category resuelve y que los cost allocation tags estructuralmente no pueden.
- **3.4** ¿Para qué sirve `--default-value`, y qué aprenderías observándolo a lo largo de tres meses?

---

## Ejercicio 4 — AWS Budgets: la herramienta de aplicación

**Objetivo:** pasar de *observar* el costo a *que te avisen* sobre él — y luego a *actuar* sobre él.

Cost Explorer responde "qué pasó". Budgets responde "avisame cuando se cruce un umbral, incluido un umbral que todavía no crucé".

💲 Los primeros **dos budgets por cuenta son gratuitos**; cada budget adicional cuesta **USD 0.02 por día** (≈ USD 0.60/mes).

1. Definí el budget. Este está acotado a un tag, incluye soporte e impuestos y deliberadamente **excluye créditos y reembolsos**, para que los créditos promocionales no enmascaren el consumo real.

   ```bash
   cat > budget.json <<'JSON'
   {
     "BudgetName": "prod-monthly-cost",
     "BudgetLimit": { "Amount": "2000", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST",
     "CostFilters": {
       "TagKeyValue": ["user:Environment$prod"]
     },
     "CostTypes": {
       "IncludeTax": true,
       "IncludeSubscription": true,
       "UseBlended": false,
       "IncludeRefund": false,
       "IncludeCredit": false,
       "IncludeUpfront": true,
       "IncludeRecurring": true,
       "IncludeOtherSubscription": true,
       "IncludeSupport": true,
       "IncludeDiscount": true,
       "UseAmortized": false
     }
   }
   JSON
   ```

   La sintaxis del filtro por tag es `user:<Key>$<Value>` — tanto el prefijo `user:` como el separador `$` son obligatorios y son una fuente frecuente de budgets silenciosamente vacíos.

2. Definí las notificaciones. Adjuntá **dos** umbrales de tipos distintos.

   ```bash
   cat > notifications.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 80,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "finops@example.com" }
       ]
     },
     {
       "Notification": {
         "NotificationType": "FORECASTED",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 100,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "SNS", "Address": "arn:aws:sns:us-east-1:123456789012:finops-alerts" }
       ]
     }
   ]
   JSON
   ```

   `ACTUAL` se dispara con dinero ya gastado. `FORECASTED` se dispara con la propia proyección de Budgets del gasto a fin de mes — es la única alerta que puede advertirte **antes** del sobregasto, y requiere ~5 semanas de historia para poder producir un forecast.

3. Si usás el subscriber SNS, la política del topic debe permitir que el service principal de Budgets publique. Sin esto el budget se crea correctamente y después nunca notifica, en silencio.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowBudgetsPublish",
         "Effect": "Allow",
         "Principal": { "Service": "budgets.amazonaws.com" },
         "Action": "SNS:Publish",
         "Resource": "arn:aws:sns:us-east-1:123456789012:finops-alerts",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:budgets::123456789012:budget/*" }
         }
       }
     ]
   }
   ```

4. Creá el budget. ⚠️ **Paso mutante.**

   ```bash
   aws budgets create-budget \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget file://budget.json \
     --notifications-with-subscribers file://notifications.json
   ```

   El éxito es un **cuerpo de respuesta vacío**. Verificá explícitamente:

   ```bash
   aws budgets describe-budget \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget-name prod-monthly-cost \
     --query 'Budget.{Name:BudgetName,Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount,Forecast:CalculatedSpend.ForecastedSpend.Amount}'
   ```

   ```json
   {
       "Name": "prod-monthly-cost",
       "Limit": "2000",
       "Actual": "1487.2200000",
       "Forecast": "2140.0500000"
   }
   ```

   El actual está por debajo del límite; el forecast por encima. La notificación `FORECASTED` ya se disparó — este es exactamente el escenario para el que existe el segundo umbral.

5. Enumerá los tipos de budget disponibles. Solo `COST` y `USAGE` se usan habitualmente, pero el examen espera que sepas que existen los de reservas.

   | `BudgetType` | Sigue | Umbral típico |
   |---|---|---|
   | `COST` | Dinero | "alertar al 80% de USD 2 000/mes" |
   | `USAGE` | Unidades de uso (GB, horas, requests) | "alertar a 100 TB de egress" |
   | `RI_UTILIZATION` | % de horas de RI compradas realmente usadas | alertar **por debajo** del 90% |
   | `RI_COVERAGE` | % del uso elegible cubierto por RIs | alertar **por debajo** del 70% |
   | `SAVINGS_PLANS_UTILIZATION` | % del compromiso de SP consumido | alertar **por debajo** del 95% |
   | `SAVINGS_PLANS_COVERAGE` | % del gasto elegible sobre SPs | alertar **por debajo** del 80% |

   Los budgets de utilización y cobertura usan `LESS_THAN` — estás alertando sobre *desperdicio*, no sobre sobregasto.

6. Adjuntá una **budget action**, el paso que convierte un budget de una notificación en un control. Las acciones pueden aplicar una política IAM, aplicar una SCP o detener instancias EC2/RDS.

   ```bash
   aws budgets create-budget-action \
     --region us-east-1 \
     --account-id 123456789012 \
     --budget-name prod-monthly-cost \
     --notification-type ACTUAL \
     --action-type APPLY_IAM_POLICY \
     --action-threshold ActionThresholdValue=100,ActionThresholdType=PERCENTAGE \
     --definition '{"IamActionDefinition":{"PolicyArn":"arn:aws:iam::123456789012:policy/DenyExpensiveLaunches","Roles":["DeveloperRole"]}}' \
     --execution-role-arn arn:aws:iam::123456789012:role/BudgetsActionExecutionRole \
     --approval-model MANUAL \
     --subscribers SubscriptionType=EMAIL,Address=finops@example.com
   ```

   ```json
   { "ActionId": "e3f4a1b2-9c8d-4e7f-a6b5-c4d3e2f1a0b9" }
   ```

   `--approval-model MANUAL` requiere que una persona confirme antes de aplicar la política; `AUTOMATIC` la aplica sin supervisión. En producción, empezá con `MANUAL` — una acción automática `APPLY_SCP` que se dispara mal puede denegar una OU entera a las 03:00.

### ✅ Comprobá lo aprendido — Bloque 4

- **4.1** El gasto actual es USD 1 487 contra un límite de USD 2 000 y no llegó ninguna alerta de tu umbral `ACTUAL` del 80%... solo que debería haber llegado. Recalculá: ¿se disparó? Ahora explicá qué aporta un umbral `FORECASTED` que `ACTUAL` no puede.
- **4.2** Se creó un budget con `"CostFilters": {"TagKeyValue": ["Environment$prod"]}` y siempre reporta USD 0.00. ¿Qué está mal?
- **4.3** Para un budget `RI_UTILIZATION`, ¿alertarías con `GREATER_THAN` o `LESS_THAN`? ¿Por qué?
- **4.4** Creaste un budget con un subscriber SNS. El budget muestra el umbral superado pero no se publicó ningún mensaje. Nombrá la causa más probable.
- **4.5** Tu cuenta tiene 6 budgets. ¿Cuál es el cargo mensual?
- **4.6** Enunciá la diferencia fundamental de propósito entre AWS Budgets y AWS Cost Explorer, en una oración cada uno.

---

## Ejercicio 5 — AWS Cost Anomaly Detection: el umbral que no tenés que fijar

**Objetivo:** detectar patrones de gasto inusuales sin saber de antemano qué es "inusual".

Budgets te exige nombrar un número. Anomaly Detection aprende tu línea base con machine learning y alerta ante la desviación — la herramienta correcta para "un ingeniero dejó una `p5.48xlarge` corriendo el fin de semana", algo que ningún budget mensual estático detectaría hasta que el mes ya estuviera perdido.

**Cost Anomaly Detection es gratuito.**

1. Creá un monitor. Un monitor `DIMENSIONAL` con dimensión `SERVICE` vigila cada servicio de AWS de forma independiente — el default recomendado.

   ```bash
   aws ce create-anomaly-monitor \
     --region us-east-1 \
     --anomaly-monitor '{
       "MonitorName": "all-services",
       "MonitorType": "DIMENSIONAL",
       "MonitorDimension": "SERVICE"
     }'
   ```

   ```json
   { "MonitorArn": "arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002" }
   ```

   Tipos de monitor: `DIMENSIONAL` (servicio), `LINKED_ACCOUNT`, `COST_CATEGORY`, `CUSTOM` (una expresión arbitraria sobre tags/cuentas).

2. Creá una suscripción con una **threshold expression**, para que no te llamen por una anomalía de USD 3.

   ```bash
   aws ce create-anomaly-subscription \
     --region us-east-1 \
     --anomaly-subscription '{
       "SubscriptionName": "finops-daily",
       "MonitorArnList": ["arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002"],
       "Subscribers": [{ "Type": "EMAIL", "Address": "finops@example.com" }],
       "Frequency": "DAILY",
       "ThresholdExpression": {
         "Dimensions": {
           "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
           "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
           "Values": ["100"]
         }
       }
     }'
   ```

   ```json
   { "SubscriptionArn": "arn:aws:ce::123456789012:anomalysubscription/3a9c0d51-77ee-4c8b-a1f0-9b2e6d4c8811" }
   ```

   `Frequency` es `IMMEDIATE`, `DAILY` o `WEEKLY`. **`IMMEDIATE` requiere un subscriber SNS** — no puede enviar correos individuales. El campo plano `Threshold` está deprecado; `ThresholdExpression` lo reemplaza y además soporta `ANOMALY_TOTAL_IMPACT_PERCENTAGE`.

3. Recuperá las anomalías detectadas.

   ```bash
   aws ce get-anomalies \
     --region us-east-1 \
     --date-interval StartDate=2026-08-01,EndDate=2026-09-04 \
     --total-impact NumericOperator=GREATER_THAN,StartValue=50
   ```

   ```json
   {
       "Anomalies": [
           {
               "AnomalyId": "0a1b2c3d-4e5f-6789-abcd-ef0123456789",
               "AnomalyStartDate": "2026-08-23",
               "AnomalyEndDate": "2026-08-25",
               "DimensionValue": "Amazon SageMaker",
               "RootCauses": [
                   {
                       "Service": "Amazon SageMaker",
                       "Region": "us-west-2",
                       "UsageType": "USW2-ML-p5-48xlarge-Hrs",
                       "LinkedAccount": "333333333333",
                       "LinkedAccountName": "ml-research"
                   }
               ],
               "AnomalyScore": { "MaxScore": 0.94, "CurrentScore": 0.11 },
               "Impact": {
                   "MaxImpact": 1284.6,
                   "TotalImpact": 2103.77,
                   "TotalActualSpend": 2380.11,
                   "TotalExpectedSpend": 276.34,
                   "TotalImpactPercentage": 761.3
               },
               "Feedback": "NO"
           }
       ]
   }
   ```

   Leé el bloque `Impact`: esperado USD 276, real USD 2 380, así que **TotalImpact es la diferencia**, USD 2 104 — la porción anómala, no el gasto total. `RootCauses` da la cuenta, la región y el usage type, lo que alcanza para identificar la carga de trabajo culpable sin abrir Cost Explorer.

4. Dá feedback. Esto no es cosmético — reentrena el modelo para tu cuenta.

   ```bash
   aws ce provide-anomaly-feedback \
     --region us-east-1 \
     --anomaly-id 0a1b2c3d-4e5f-6789-abcd-ef0123456789 \
     --feedback YES
   ```

   ```json
   { "AnomalyId": "0a1b2c3d-4e5f-6789-abcd-ef0123456789" }
   ```

   `YES` = fue una anomalía genuina. `NO` = falso positivo, dejá de alertar sobre este patrón. `PLANNED_ACTIVITY` = esperado, por ejemplo un batch programado o un lanzamiento.

### ✅ Comprobá lo aprendido — Bloque 5

- **5.1** Enunciá en una oración la diferencia entre lo que dispara una alerta de AWS Budgets y lo que dispara una alerta de Cost Anomaly Detection.
- **5.2** Una anomalía muestra `TotalActualSpend: 2380.11` y `TotalImpact: 2103.77`. ¿Por qué son números distintos, y cuál reportás como "el costo del incidente"?
- **5.3** Configurás `"Frequency": "IMMEDIATE"` con un subscriber EMAIL y la API lo rechaza. ¿Por qué?
- **5.4** Marketing corre una campaña anual que triplica el costo de CloudFront cada Black Friday. ¿Qué deberías enviar vía `provide-anomaly-feedback`, y cuál es el efecto?
- **5.5** ¿Cuánto cuesta Cost Anomaly Detection?

---

## Ejercicio 6 — Cost and Usage Report / Data Exports: la fuente de verdad

**Objetivo:** obtener el conjunto de datos de facturación completo, a nivel de línea de detalle, horario y por recurso — el único artefacto que reconcilia byte a byte con la factura.

Cost Explorer es una *vista* agregada, redondeada y limitada por API. El **AWS Cost and Usage Report (CUR)** es el libro mayor crudo: una fila por línea de detalle por hora, con hasta cientos de columnas, entregado en tu bucket de S3. Es lo que cargás en Athena, Redshift, QuickSight o una plataforma FinOps de terceros.

La interfaz moderna es **AWS Data Exports** con el esquema **CUR 2.0**; la API `cur` heredada sigue describiendo reportes creados a la vieja usanza.

1. Inspeccioná las definiciones CUR heredadas.

   ```bash
   aws cur describe-report-definitions \
     --region us-east-1 \
     --query 'ReportDefinitions[].{Name:ReportName,Bucket:S3Bucket,Format:Format,Compression:Compression,Granularity:TimeUnit,Resources:AdditionalSchemaElements}'
   ```

   ```json
   [
       {
           "Name": "legacy-hourly-cur",
           "Bucket": "acme-billing-legacy",
           "Format": "Parquet",
           "Compression": "Parquet",
           "Granularity": "HOURLY",
           "Resources": ["RESOURCES"]
       }
   ]
   ```

2. Preparó la política del bucket S3. El export falla al momento de crearse si no está.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "EnableAWSDataExportsGetBucketAcl",
         "Effect": "Allow",
         "Principal": { "Service": "billingreports.amazonaws.com" },
         "Action": ["s3:GetBucketAcl", "s3:GetBucketPolicy"],
         "Resource": "arn:aws:s3:::acme-cur-exports",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:cur:us-east-1:123456789012:definition/*" }
         }
       },
       {
         "Sid": "EnableAWSDataExportsPutObject",
         "Effect": "Allow",
         "Principal": { "Service": "billingreports.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::acme-cur-exports/*",
         "Condition": {
           "StringEquals": { "aws:SourceAccount": "123456789012" },
           "ArnLike": { "aws:SourceArn": "arn:aws:cur:us-east-1:123456789012:definition/*" }
         }
       }
     ]
   }
   ```

3. Definí un export CUR 2.0. El `QueryStatement` es SQL real contra una tabla virtual — seleccionás solo las columnas que necesitás en lugar de aceptar las ~300.

   ```bash
   cat > export.json <<'JSON'
   {
     "Name": "cur2-hourly-parquet",
     "Description": "Hourly CUR 2.0 with resource IDs and tags, for Athena",
     "DataQuery": {
       "QueryStatement": "SELECT bill_billing_period_start_date, bill_payer_account_id, line_item_usage_account_id, line_item_usage_start_date, line_item_product_code, line_item_line_item_type, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, pricing_term, product_region_code, resource_tags FROM COST_AND_USAGE_REPORT",
       "TableConfigurations": {
         "COST_AND_USAGE_REPORT": {
           "TIME_GRANULARITY": "HOURLY",
           "INCLUDE_RESOURCES": "TRUE",
           "INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY": "FALSE",
           "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "FALSE"
         }
       }
     },
     "DestinationConfigurations": {
       "S3Destination": {
         "S3Bucket": "acme-cur-exports",
         "S3Prefix": "cur2",
         "S3Region": "us-east-1",
         "S3OutputConfigurations": {
           "OutputType": "CUSTOM",
           "Format": "PARQUET",
           "Compression": "PARQUET",
           "Overwrite": "OVERWRITE_REPORT"
         }
       }
     },
     "RefreshCadence": { "Frequency": "SYNCHRONOUS" }
   }
   JSON
   ```

   ⚠️ **Paso mutante** — crea un export recurrente. No hay cargo por el export en sí; pagás **almacenamiento S3, peticiones y cualquier escaneo de Athena**.

   ```bash
   aws bcm-data-exports create-export --region us-east-1 --export file://export.json
   ```

   ```json
   { "ExportArn": "arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c" }
   ```

4. Entendé `Overwrite`. `OVERWRITE_REPORT` reemplaza los archivos del mes en cada refresco — una única copia autoritativa, el almacenamiento más barato y lo que querés para una tabla de Athena. `CREATE_NEW_REPORT` conserva cada versión, lo cual es necesario si tenés que probar cómo se veían los números en un día dado, y crece sin límite.

5. Verificá el estado de entrega.

   ```bash
   aws bcm-data-exports get-export \
     --region us-east-1 \
     --export-arn arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c \
     --query 'ExportStatus'
   ```

   ```json
   {
       "CreatedAt": "2026-09-04T15:03:44.812000+00:00",
       "LastRefreshedAt": "2026-09-04T15:11:02.006000+00:00",
       "LastUpdatedAt": "2026-09-04T15:03:44.812000+00:00",
       "StatusCode": "HEALTHY"
   }
   ```

   La primera entrega tarda hasta **24 horas**. A partir de ahí el reporte se refresca hasta **tres veces por día**, y AWS puede reexpresar datos previos a medida que los cargos se finalizan — por eso todo consumidor de CUR debe ser idempotente sobre `(bill_billing_period_start_date, identity_line_item_id)`.

6. Consultalo con Athena, una vez que exista una tabla de Glue sobre el prefijo:

   ```sql
   SELECT line_item_usage_account_id,
          line_item_product_code,
          SUM(line_item_unblended_cost) AS cost
   FROM   cur2_hourly_parquet
   WHERE  bill_billing_period_start_date = DATE '2026-08-01'
     AND  line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
   GROUP  BY 1, 2
   ORDER  BY cost DESC
   LIMIT  10;
   ```

   El filtro por `line_item_line_item_type` es el detalle que separa una consulta CUR correcta de una equivocada. Sin él contás doble: las filas `SavingsPlanCoveredUsage` llevan USD 0.00 de costo unblended mientras que la fila `SavingsPlanRecurringFee` correspondiente lleva el dinero, y las filas `Credit`, `Refund`, `Tax` y `RIFee` viven todas en la misma tabla.

### ✅ Comprobá lo aprendido — Bloque 6

- **6.1** Dá dos capacidades que tiene el CUR y Cost Explorer no.
- **6.2** ¿Dónde se entrega el CUR, y qué cobra AWS por el reporte en sí?
- **6.3** Tu `SUM(line_item_unblended_cost)` en Athena sobre un mes entero es 30% más alto que la factura. Nombrá la causa más probable.
- **6.4** ¿Cuándo elegirías `CREATE_NEW_REPORT` en lugar de `OVERWRITE_REPORT`?
- **6.5** Tu job de ETL corre a las 02:00 y trata al CUR como inmutable. ¿Por qué esa suposición es errónea?

---

## Ejercicio 7 — Consolidated billing y AWS Organizations

**Objetivo:** entender por qué mover 40 cuentas bajo un único payer reduce la factura sin cambiar un solo recurso.

1. Listá las cuentas que comparten la factura.

   ```bash
   aws organizations list-accounts \
     --region us-east-1 \
     --query 'Accounts[].{Id:Id,Name:Name,Status:Status}' \
     --output table
   ```

   ```
   ----------------------------------------------
   |                ListAccounts                |
   +----------------+---------------+-----------+
   |       Id       |     Name      |  Status   |
   +----------------+---------------+-----------+
   |  123456789012  |  payer        |  ACTIVE   |
   |  222222222222  |  data-prod    |  ACTIVE   |
   |  333333333333  |  ml-research  |  ACTIVE   |
   |  444444444444  |  sandbox      |  ACTIVE   |
   +----------------+---------------+-----------+
   ```

2. Desglosá la factura por cuenta. Esto es showback: una factura, atribución por cuenta.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT
   ```

   ```json
   {
       "ResultsByTime": [
           {
               "TimePeriod": { "Start": "2026-08-01", "End": "2026-09-01" },
               "Total": {},
               "Groups": [
                   { "Keys": ["123456789012"], "Metrics": { "UnblendedCost": { "Amount": "402.1100000", "Unit": "USD" } } },
                   { "Keys": ["222222222222"], "Metrics": { "UnblendedCost": { "Amount": "1188.9000000", "Unit": "USD" } } },
                   { "Keys": ["333333333333"], "Metrics": { "UnblendedCost": { "Amount": "2380.1100000", "Unit": "USD" } } },
                   { "Keys": ["444444444444"], "Metrics": { "UnblendedCost": { "Amount": "133.7900000", "Unit": "USD" } } }
               ],
               "Estimated": false
           }
       ],
       "DimensionValueAttributes": [
           { "Value": "222222222222", "Attributes": { "description": "data-prod" } }
       ]
   }
   ```

   El consolidated billing entrega tres cosas, y el examen evalúa las tres:

   - **Una sola factura.** Un único invoice y método de pago para todas las cuentas.
   - **Agregación de precios por volumen/tramos.** S3, la transferencia de datos y otros servicios por tramos suman el uso **de toda la Organization** antes de aplicar el tramo. Cuatro cuentas usando 30 TB de S3 cada una se facturan como 120 TB, alcanzando un tramo más barato que ninguna alcanzaría por su cuenta.
   - **Compartición de Reserved Instances y Savings Plans.** Una RI o un compromiso de SP sin usar en una cuenta se aplica automáticamente al uso coincidente en cualquier otra cuenta de la Organization.

3. Inspeccioná y controlá la compartición de descuentos. Está **activada por defecto** para todas las cuentas.

   ```bash
   aws ce get-cost-and-usage \
     --region us-east-1 \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --filter '{"Dimensions":{"Key":"PURCHASE_TYPE","Values":["Savings Plans"]}}' \
     --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
     --query 'ResultsByTime[0].Groups'
   ```

   Para excluir una cuenta de la compartición — el tratamiento estándar para una cuenta `sandbox` que no querés que absorba silenciosamente los descuentos comprometidos de producción — desactivala en **Billing → Preferences → Billing preferences → Reserved Instances and Savings Plans discount sharing**, por cuenta, desde el payer.

4. Confirmá el feature set. El `FeatureSet` del Ejercicio 0 importa acá:

   - `CONSOLIDATED_BILLING` — solo agregación de facturación. Sin SCPs, sin funciones de gobernanza.
   - `ALL` — consolidated billing **más** Service Control Policies, tag policies, administración delegada y la capacidad de que las Budget Actions apliquen una SCP.

   Toda Organization nueva se crea con `ALL`; el modo solo-facturación existe por legado y puede actualizarse pero nunca degradarse.

### ✅ Comprobá lo aprendido — Bloque 7

- **7.1** Cuatro cuentas almacenan 30 TB cada una en S3 Standard. Explicá, sin números, por qué la factura consolidada es menor que cuatro facturas separadas.
- **7.2** La cuenta A compró una Standard Reserved Instance que ahora apenas usa. La cuenta B corre instancias On-Demand coincidentes. ¿Qué pasa bajo consolidated billing, y qué cambiarías si A debe conservar el beneficio en exclusiva?
- **7.3** El administrador de una member account ejecuta `aws ce get-cost-and-usage`. ¿De quién ve los costos?
- **7.4** Tu Organization tiene `FeatureSet: CONSOLIDATED_BILLING`. ¿Podés configurar una Budget Action de tipo `APPLY_SCP`?
- **7.5** ¿Qué métrica — blended o unblended — es la elección natural para chargeback interno entre cuentas que comparten reservas, y por qué?

---

## Ejercicio 8 — Estimar antes de gastar: Pricing Calculator y la Pricing API

**Objetivo:** todas las herramientas hasta acá son retrospectivas. Esta es la única que funciona antes de que exista un recurso.

1. Abrí la [AWS Pricing Calculator](https://calculator.aws/) — **no requiere cuenta de AWS, es gratuita y pública**. Armá una arquitectura aproximada: 3 × `m6i.large` Linux On-Demand en `us-east-1`, 500 GB de EBS `gp3`, 2 TB mensuales de transferencia de datos de salida. Exportá la estimación como enlace compartible y como CSV. Desde 2025 la Calculator también está embebida en la consola de Billing, donde puede sembrar la estimación a partir de tu **uso histórico real** en lugar de entradas en blanco.

2. Obtené los mismos números de forma programática. La **AWS Price List Query API** es gratuita y sirve la lista de precios pública. Está disponible solo en `us-east-1`, `eu-central-1` y `ap-south-1`.

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
       "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --max-items 1 \
     --output text | python3 -c "import sys,json; d=json.loads(sys.stdin.read().split('\t')[-1] if False else sys.stdin.read()); print(d)" 2>/dev/null || \
   aws pricing get-products \
     --region us-east-1 --service-code AmazonEC2 \
     --filters "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
               "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
               "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
               "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
               "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
               "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --max-items 1 --query 'PriceList[0]' --output text | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
   ```

   ```
   0.0960000000
   ```

   Los seis filtros son obligatorios en la práctica. Si sacás `capacitystatus` también matcheás SKUs de Capacity Reservation; si sacás `preInstalledSw` matcheás las variantes con SQL Server incluido — ambas devuelven un precio distinto y más alto, sin error.

3. Descubrí los atributos filtrables de un servicio antes de adivinarlos.

   ```bash
   aws pricing describe-services \
     --region us-east-1 \
     --service-code AmazonRDS \
     --query 'Services[0].AttributeNames' \
     --output text | tr '\t' '\n' | head -12
   ```

   ```
   deploymentOption
   engineCode
   instanceType
   licenseModel
   location
   locationType
   databaseEngine
   databaseEdition
   storageType
   volumeType
   usagetype
   operation
   ```

4. Notá lo que la Calculator no puede saber: tu utilización real, tu cobertura de Savings Plans, tu tarifa del Enterprise Discount Program, o el costo del patrón de tráfico que todavía no mediste. Produce un **límite superior a precio de lista para una configuración declarada** — invaluable para comparar arquitecturas, poco confiable como presupuesto.

### ✅ Comprobá lo aprendido — Bloque 8

- **8.1** Nombrá la única herramienta de facturación/costos de este tema que funciona sin cuenta de AWS y antes de que exista ningún recurso.
- **8.2** Tu consulta a la Pricing API para `m6i.large` devuelve USD 0.212/hora en lugar de USD 0.096. ¿Qué filtro es más probable que hayas omitido?
- **8.3** La Pricing Calculator dice USD 4 100/mes; la primera factura real es USD 3 050. Dá dos razones estructurales por las que la estimación salió alta.
- **8.4** ¿Cuánto cuesta la Price List Query API?

---

## Ejercicio 9 — Recomendaciones de optimización: Compute Optimizer, rightsizing de Cost Explorer, Trusted Advisor

**Objetivo:** conseguir que AWS te diga dónde está el desperdicio.

1. **AWS Compute Optimizer** — gratuito, y disponible para toda cuenta sin importar el plan de soporte. Analiza métricas de CloudWatch con una ventana de 14 días hacia atrás (más larga con las métricas mejoradas de pago) para EC2, Auto Scaling groups, EBS, Lambda, ECS on Fargate, RDS y licencias de software comercial.

   ```bash
   aws compute-optimizer get-enrollment-status --region us-east-1
   ```

   ```json
   { "status": "Active", "memberAccountsEnrolled": true, "lastUpdatedTimestamp": "2026-08-14T09:31:20+00:00" }
   ```

   ```bash
   aws compute-optimizer get-ec2-instance-recommendations \
     --region us-east-1 \
     --filters name=Finding,values=Overprovisioned \
     --max-results 2 \
     --query 'instanceRecommendations[].{Instance:instanceName,Type:currentInstanceType,Finding:finding,Recommended:recommendationOptions[0].instanceType,Savings:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}'
   ```

   ```json
   [
       { "Instance": "api-worker-03", "Type": "m5.4xlarge", "Finding": "OVER_PROVISIONED", "Recommended": "m6i.xlarge", "Savings": 412.55 },
       { "Instance": "batch-runner-01", "Type": "r5.2xlarge", "Finding": "OVER_PROVISIONED", "Recommended": "r6i.large", "Savings": 288.10 }
   ]
   ```

   Los findings son `UNDER_PROVISIONED`, `OVER_PROVISIONED`, `OPTIMIZED` o `NOT_OPTIMIZED`. Compute Optimizer ve CPU, red y disco por defecto; **la memoria es invisible** salvo que el agente de CloudWatch la publique, y por eso un veredicto de "over-provisioned" sobre una JVM limitada por memoria debe verificarse antes de actuar.

2. **Rightsizing de Cost Explorer** — la misma idea, expuesta con contexto en dólares dentro de Cost Explorer.

   ```bash
   aws ce get-rightsizing-recommendation \
     --region us-east-1 \
     --service AmazonEC2 \
     --configuration '{"RecommendationTarget":"CROSS_INSTANCE_FAMILY","BenefitsConsidered":true}' \
     --query 'Summary'
   ```

   ```json
   {
       "TotalRecommendationCount": "37",
       "EstimatedTotalMonthlySavingsAmount": "3104.88",
       "EstimatedTotalMonthlySavingsPercentage": "18.4",
       "SavingsCurrencyCode": "USD"
   }
   ```

   `BenefitsConsidered: true` tiene en cuenta la cobertura de RI/SP — sin eso, la herramienta recomienda achicar instancias cuyo costo ya está cubierto por un compromiso, produciendo ahorros que no se van a materializar.

3. **Recomendaciones de compra de Savings Plans.**

   ```bash
   aws ce get-savings-plans-purchase-recommendation \
     --region us-east-1 \
     --savings-plans-type COMPUTE_SP \
     --term-in-years ONE_YEAR \
     --payment-option NO_UPFRONT \
     --lookback-period-in-days SIXTY_DAYS \
     --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary'
   ```

   ```json
   {
       "EstimatedROI": "21.7",
       "CurrencyCode": "USD",
       "EstimatedTotalCost": "18422.40",
       "CurrentOnDemandSpend": "23516.88",
       "EstimatedSavingsAmount": "5094.48",
       "TotalRecommendationCount": "1",
       "DailyCommitmentToPurchase": "50.47",
       "EstimatedMonthlySavingsAmount": "424.54",
       "EstimatedSavingsPercentage": "21.66",
       "EstimatedUtilization": "99.4"
   }
   ```

4. **AWS Trusted Advisor** — cinco pilares: cost optimization, performance, security, fault tolerance, service limits (y operational excellence). El **conjunto completo de checks de cost optimization requiere soporte Business, Enterprise On-Ramp o Enterprise**; los planes Basic y Developer reciben solo un conjunto núcleo limitado. El endpoint de la API es `us-east-1` y la API misma es solo Business+.

   ```bash
   aws support describe-trusted-advisor-checks \
     --region us-east-1 \
     --language en \
     --query "checks[?category=='cost_optimizing'].name"
   ```

   ```json
   [
       "Low Utilization Amazon EC2 Instances",
       "Idle Load Balancers",
       "Underutilized Amazon EBS Volumes",
       "Unassociated Elastic IP Addresses",
       "Amazon RDS Idle DB Instances",
       "Amazon Route 53 Latency Resource Record Sets",
       "Savings Plan Recommendations",
       "Amazon EC2 Reserved Instance Lease Expiration"
   ]
   ```

   En un plan Basic/Developer la misma llamada falla:

   ```
   An error occurred (SubscriptionRequiredException) when calling the DescribeTrustedAdvisorChecks operation:
   AWS Premium Support Subscription is required to use this service.
   ```

   Ese error es en sí mismo la respuesta del examen: el conjunto completo de checks de Trusted Advisor está condicionado por el plan de soporte, mientras que los datos de rightsizing de Compute Optimizer no lo están.

### ✅ Comprobá lo aprendido — Bloque 9

- **9.1** Dos servicios de AWS en este ejercicio producen consejos de rightsizing de EC2. ¿Cuál es gratuito para toda cuenta, y cuál está condicionado por el plan de soporte?
- **9.2** Compute Optimizer etiqueta un servicio Java como `OVER_PROVISIONED` en base a un 6% de CPU. ¿Por qué no deberías actuar sobre esto de inmediato?
- **9.3** ¿De qué te protege `BenefitsConsidered: true` en `get-rightsizing-recommendation`?
- **9.4** Nombrá las cinco categorías de checks de Trusted Advisor, e indicá qué planes de soporte desbloquean el conjunto completo.
- **9.5** Una recomendación reporta `EstimatedUtilization: 99.4`. ¿Qué se está prediciendo, y por qué un valor bajo vuelve peligrosa a la recomendación?

---

## Ejercicio 10 — Alertas de último recurso: alarmas de facturación en CloudWatch y uso del Free Tier

**Objetivo:** los dos mecanismos que existen específicamente para la cuenta que no tiene equipo de FinOps.

1. Habilitá las alertas de facturación. En la **management account**, consola → Billing → **Billing preferences** → **Alert preferences** → tildá *Receive AWS Free Tier alerts* y *Receive CloudWatch billing alerts*. Hasta que esto no esté tildado, el namespace `AWS/Billing` está vacío y tu alarma queda permanentemente en `INSUFFICIENT_DATA`.

2. Confirmá que la métrica se está publicando. **Solo `us-east-1`** — la métrica no existe en ninguna otra región, sin importar dónde corran tus recursos.

   ```bash
   aws cloudwatch get-metric-statistics \
     --region us-east-1 \
     --namespace AWS/Billing \
     --metric-name EstimatedCharges \
     --dimensions Name=Currency,Value=USD \
     --start-time 2026-09-03T00:00:00Z \
     --end-time 2026-09-04T00:00:00Z \
     --period 21600 \
     --statistics Maximum \
     --query 'Datapoints | sort_by(@, &Timestamp)[-1]'
   ```

   ```json
   {
       "Timestamp": "2026-09-03T18:00:00+00:00",
       "Maximum": 487.22,
       "Unit": "None"
   }
   ```

   `EstimatedCharges` es un valor **acumulado del mes a la fecha** que se reinicia a ~0 el día 1 de cada mes. Se publica aproximadamente cada 6 horas. Por eso la alarma de abajo usa `Maximum` sobre un período de `21600` segundos: el `Average` sobre un contador que crece monótonamente no significa nada.

3. Creá la alarma. ⚠️ **Paso mutante.**

   ```bash
   aws cloudwatch put-metric-alarm \
     --region us-east-1 \
     --alarm-name billing-mtd-over-500-usd \
     --alarm-description "Month-to-date estimated charges exceeded USD 500" \
     --namespace AWS/Billing \
     --metric-name EstimatedCharges \
     --dimensions Name=Currency,Value=USD \
     --statistic Maximum \
     --period 21600 \
     --evaluation-periods 1 \
     --threshold 500 \
     --comparison-operator GreaterThanThreshold \
     --treat-missing-data notBreaching \
     --alarm-actions arn:aws:sns:us-east-1:123456789012:finops-alerts
   ```

   ```bash
   aws cloudwatch describe-alarms \
     --region us-east-1 \
     --alarm-names billing-mtd-over-500-usd \
     --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}'
   ```

   ```json
   {
       "State": "ALARM",
       "Reason": "Threshold Crossed: 1 datapoint [487.22 (03/09/26 18:00:00)] was not less than or equal to the threshold (500.0)."
   }
   ```

   Comparada con AWS Budgets, una alarma de facturación de CloudWatch es estrictamente más débil: no puede filtrar por tag, servicio, cuenta ni Cost Category, no tiene forecast, y no tiene acciones más allá de publicar en SNS. Existe porque es anterior a Budgets y porque se enchufa a la infraestructura de alarmas de CloudWatch que quizás ya operás. **Para un despliegue nuevo, usá Budgets.**

4. Verificá el consumo del Free Tier contra los límites, que es el modo de falla específico de las cuentas nuevas.

   ```bash
   aws freetier get-free-tier-usage \
     --region us-east-1 \
     --query 'freeTierUsages[?forecastedUsageAmount > limit].{Service:service,Usage:usageType,Actual:actualUsageAmount,Forecast:forecastedUsageAmount,Limit:limit,Unit:unit}' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------------
   |                                      GetFreeTierUsage                                       |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   |      Service      |  Actual  | Forecast  |          Usage            |  Limit  |    Unit    |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   |  Amazon S3        |  14.2    |  21.8     |  TimedStorage-ByteHrs     |  5.0    |  GB-Month  |
   |  AWS Lambda       |  612000  |  980000   |  Global-Request           |  1000000|  Request   |
   +-------------------+----------+-----------+---------------------------+---------+------------+
   ```

   Los tres sabores de Free Tier que el examen distingue: **Always Free** (p. ej. 1M de requests de Lambda al mes, para siempre), **12 Months Free** (p. ej. 750 horas de EC2 `t2.micro`/`t3.micro` por mes durante el primer año) y **Trials** (de corto plazo, específicos por servicio, que empiezan cuando activás el servicio).

### ✅ Comprobá lo aprendido — Bloque 10

- **10.1** Tu alarma de facturación de CloudWatch lleva una semana en `INSUFFICIENT_DATA`. Dá las dos causas más probables.
- **10.2** ¿Por qué `Maximum` es la estadística correcta para `EstimatedCharges`, y por qué el valor se desploma el día 1 de cada mes?
- **10.3** Enumerá tres capacidades que AWS Budgets tiene y una alarma de facturación de CloudWatch no.
- **10.4** Nombrá las tres categorías de oferta del AWS Free Tier y dá un ejemplo de cada una.

---

## Ejercicio 11 — Chargeback para revendedores: AWS Billing Conductor, y después la limpieza

**Objetivo:** ver la única herramienta que cambia lo que la factura *dice*, y después eliminar todo lo que este laboratorio creó.

1. **AWS Billing Conductor** produce una vista de facturación **pro forma**: una segunda representación paralela de los costos de tu Organization con tus propios markups, descuentos y líneas de detalle personalizadas aplicadas. No cambia lo que AWS te cobra — la factura real queda intacta — cambia lo que ven tus unidades de negocio internas o tus clientes finales de ISV. Billing Conductor se cobra **por cuenta de billing group por mes**.

   ```bash
   aws billingconductor list-billing-groups \
     --region us-east-1 \
     --query 'BillingGroups[].{Name:Name,Arn:Arn,Size:Size,Status:Status}'
   ```

   ```json
   [
       {
           "Name": "customer-acme",
           "Arn": "arn:aws:billingconductor::123456789012:billinggroup/555555555555",
           "Size": 3,
           "Status": "ACTIVE"
       }
   ]
   ```

2. Una pricing rule aplica un markup o un descuento a la vista pro forma de un billing group.

   ```bash
   aws billingconductor create-pricing-rule \
     --region us-east-1 \
     --name managed-services-markup \
     --description "10% managed services fee on all AWS charges" \
     --scope GLOBAL \
     --type MARKUP \
     --modifier-percentage 10 \
     --billing-entity AWS
   ```

   ```json
   { "Arn": "arn:aws:billingconductor::123456789012:pricingrule/2c8b1a45" }
   ```

   Contrastá las herramientas una última vez: las Cost Categories **agrupan** la factura real; Billing Conductor **reescribe** una factura paralela.

3. **Limpieza.** Ejecutá esto en orden. Todo lo de abajo es un borrado — leé cada objetivo antes de ejecutar.

   ```bash
   # Budget action, then budget
   aws budgets delete-budget-action --region us-east-1 \
     --account-id 123456789012 --budget-name prod-monthly-cost \
     --action-id e3f4a1b2-9c8d-4e7f-a6b5-c4d3e2f1a0b9

   aws budgets delete-budget --region us-east-1 \
     --account-id 123456789012 --budget-name prod-monthly-cost

   # Anomaly subscription must be deleted before its monitor
   aws ce delete-anomaly-subscription --region us-east-1 \
     --subscription-arn arn:aws:ce::123456789012:anomalysubscription/3a9c0d51-77ee-4c8b-a1f0-9b2e6d4c8811

   aws ce delete-anomaly-monitor --region us-east-1 \
     --monitor-arn arn:aws:ce::123456789012:anomalymonitor/7c1f9a2e-4b3d-11f1-9d2a-0242ac120002

   # Cost Category
   aws ce delete-cost-category-definition --region us-east-1 \
     --cost-category-arn arn:aws:ce::123456789012:costcategory/a1b2c3d4-5e6f-7890-abcd-ef1234567890

   # Data export (S3 objects survive and must be removed separately)
   aws bcm-data-exports delete-export --region us-east-1 \
     --export-arn arn:aws:bcm-data-exports:us-east-1:123456789012:export/cur2-hourly-parquet-9f8e7d6c

   # CloudWatch alarm
   aws cloudwatch delete-alarms --region us-east-1 \
     --alarm-names billing-mtd-over-500-usd

   # Billing Conductor pricing rule
   aws billingconductor delete-pricing-rule --region us-east-1 \
     --arn arn:aws:billingconductor::123456789012:pricingrule/2c8b1a45
   ```

   Borrar el export detiene las entregas futuras; los archivos Parquet ya escritos en S3 permanecen y siguen generando cargos de almacenamiento hasta que vacíes el prefijo.

4. Verificá que no sobreviva nada.

   ```bash
   aws budgets describe-budgets --region us-east-1 --account-id 123456789012 --query 'length(Budgets || `[]`)'
   aws ce get-anomaly-monitors --region us-east-1 --query 'length(AnomalyMonitors)'
   aws bcm-data-exports list-exports --region us-east-1 --query 'length(Exports)'
   aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix billing- --query 'length(MetricAlarms)'
   ```

   ```
   0
   0
   0
   0
   ```

### ✅ Comprobá lo aprendido — Bloque 11

- **11.1** ¿Un markup de Billing Conductor cambia el monto que AWS te cobra? ¿Qué cambia?
- **11.2** Distinguí Cost Categories de Billing Conductor en una oración.
- **11.3** Borraste el data export. ¿Por qué podría no bajar tu factura de S3?
- **11.4** ¿Por qué hay que borrar la *subscription* de anomalías antes que el *monitor*?

---

## Referencia consolidada: qué herramienta responde qué pregunta

| Pregunta | Herramienta | Latencia | Costo |
|---|---|---|---|
| ¿Cuánto va a costar esta arquitectura antes de construirla? | **AWS Pricing Calculator** / Price List API | instantáneo | gratis, sin necesidad de cuenta |
| ¿A dónde se fue la plata del mes pasado? | **AWS Cost Explorer** | hasta 24 h | consola gratis; API USD 0.01/petición |
| Dame cada línea de detalle, por hora, con IDs de recurso | **CUR 2.0 / AWS Data Exports** | hasta 24 h la primera entrega | gratis; pagás S3 + Athena |
| Avisame cuando cruce un número que yo elegí | **AWS Budgets** | ~8–12 h de evaluación | 2 gratis, después USD 0.02/día |
| Avisame sobre gasto que no podría haber previsto | **AWS Cost Anomaly Detection** | ~24 h después del evento | gratis |
| Alertame sobre el total de cargos del mes a la fecha, de forma simple | **CloudWatch billing alarm** (`AWS/Billing`) | período de métrica ~6 h | precio estándar de alarma de CloudWatch |
| ¿Estoy por exceder el Free Tier? | **Free Tier usage alerts** / API `freetier` | diaria | gratis |
| ¿Qué recursos están sobredimensionados? | **AWS Compute Optimizer** | ventana de 14 días | gratis (métricas mejoradas, pagas) |
| ¿Qué recursos están ociosos o son un desperdicio? | **AWS Trusted Advisor** | continua | los checks completos requieren Business+ |
| ¿Debería comprar un Savings Plan, y de cuánto? | **Recomendaciones de SP de Cost Explorer** | ventana de 7/30/60 días | USD 0.01/petición |
| Darle a la factura la forma de equipo/producto/entorno | **Cost allocation tags + Cost Categories** | 24 h de activación | gratis |
| Una factura, descuentos compartidos, tramos por volumen | **Consolidated billing de AWS Organizations** | inmediato | gratis |
| Facturar a mis unidades de negocio con un markup | **AWS Billing Conductor** | mensual | por cuenta de billing group |

---

## Fuentes oficiales

- CLF-C02 Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Billing and Cost Management User Guide — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html
- Analyzing your costs with AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- Managing your costs with AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Configuring AWS Budget actions — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
- Detecting unusual spend with AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Data Exports and the CUR 2.0 table — https://docs.aws.amazon.com/cur/latest/userguide/what-is-data-exports.html
- CUR data dictionary (`line_item_line_item_type`) — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- Using cost allocation tags — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Cost allocation tag backfill — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/custom-tags.html
- AWS Cost Categories, including split charge rules — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- Consolidated billing for AWS Organizations — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html
- Turning off Reserved Instance and Savings Plans discount sharing — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ri-turn-off.html
- Creating a CloudWatch billing alarm — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
- AWS Free Tier and usage alerts — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/tracking-free-tier-usage.html
- AWS Pricing Calculator — https://docs.aws.amazon.com/pricing-calculator/latest/userguide/what-is-pricing-calculator.html
- AWS Price List Query API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- AWS Compute Optimizer User Guide — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Billing Conductor User Guide — https://docs.aws.amazon.com/billingconductor/latest/userguide/what-is-billingconductor.html
- Fine-grained billing IAM actions migration — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/migrate-granularaccess-whatis.html
- AWS Cost Management pricing — https://aws.amazon.com/aws-cost-management/pricing/

---

<details>
<summary><strong>📝 Respuestas — clic para expandir</strong></summary>

### Bloque 0 — Plano de control

**0.1** *IAM user and role access to Billing information* no está activado en **Account Settings**. Este es un interruptor a nivel de cuenta, separado de IAM, que solo el usuario root puede accionar. Hasta que esté encendido, ningún principal IAM — incluido uno con `AdministratorAccess` — puede llegar a los datos de Billing and Cost Management. Es la causa más común de "AccessDenied con una política de admin adjunta".

**0.2** Cost Explorer es un servicio global cuyo endpoint de API vive solo en `us-east-1`. La ubicación de tus *recursos* es irrelevante para la ubicación del *endpoint de facturación*; la facturación se agrega globalmente en la payer account y se sirve desde una única región. Lo mismo aplica a `budgets`, `cur`, `bcm-data-exports`, `organizations`, `freetier`, `billingconductor` y `support`.

**0.3** No. Los datos de consolidated billing pertenecen a la management account, e IAM en una member account no puede otorgar acceso a los datos de facturación de otra cuenta. Al administrador de la member account hay que darle un principal *en la management account* (típicamente vía un rol cross-account asumido desde su proveedor de identidad), o el payer debe publicarle los datos, por ejemplo mediante un CUR compartido en S3.

**0.4** Cost Explorer rellena hacia atrás los **12 meses** previos de historia, y los datos quedan disponibles dentro de las **24 horas** de haberlo habilitado por primera vez. A partir de ese punto AWS retiene hasta 38 meses de historia (13 meses en la consola por defecto, extensible).

---

### Bloque 1 — Cost Explorer

**1.1** No es un bug. Cuando proporcionás cualquier `--group-by`, Cost Explorer mueve todos los valores al array `Groups` y deja `Total` vacío por diseño. Tu código debe iterar `Groups[].Metrics.<Metric>.Amount` y sumarlos por su cuenta. Código que lea `ResultsByTime[0].Total.UnblendedCost.Amount` sin condiciones va a lanzar un `KeyError` en el momento en que alguien agregue una agrupación.

**1.2** **AmortizedCost** muestra ~USD 1 000 en marzo (12 000 ÷ 12 meses). **UnblendedCost** muestra USD 0.00 en marzo, porque los USD 12 000 completos aparecieron como costo unblended en enero, cuando el pago se cobró efectivamente. Esta es la distinción entre base caja y base devengado, y es la razón por la que una comparación unblended mes a mes que atraviesa la compra de un compromiso resulta engañosa.

**1.3** El blended cost es la *tarifa promedio a lo largo de una Organization que comparte descuentos de reservas y Savings Plans*. Sin una Organization sobre la cual promediar y sin reservas para compartir, no hay nada que mezclar — el promedio de una sola tarifa es esa tarifa. La igualdad es el resultado esperado, no evidencia de un problema.

**1.4** 40 páginas × 24 ejecuciones/día × ~30 días = 28 800 peticiones × USD 0.01 = **USD 288/mes** solo en cargos de la API de Cost Explorer. Este es el clásico gol en contra de FinOps: una herramienta de monitoreo de costos que se convierte en una línea del top 10. La arquitectura correcta para datos diarios a nivel de recurso es un export CUR a S3 consultado con Athena, no la API de Cost Explorer.

**1.5** El período de facturación todavía está abierto. AWS no finalizó los cargos: sigue llegando uso, no se aplicaron créditos ni reembolsos, no se computaron impuestos, y la asignación de Savings Plans/RI todavía puede moverse. Los números marcados como estimados **van** a cambiar. Enviálos claramente rotulados como estimación, o esperá a que el período cierre y `Estimated` pase a `false`.

---

### Bloque 2 — Cost allocation tags

**2.1** (a) La clave del tag nunca fue **activada como cost allocation tag** en la payer account — etiquetar un recurso no tiene efecto de facturación por sí solo. (b) Incluso después de activarla, la propagación hacia Cost Explorer tarda hasta **24 horas**, y solo se etiqueta el uso incurrido *después* de la activación, salvo que pidas un backfill. Una tercera causa, menos común: el tag se aplicó en una member account, pero la activación debe ocurrir en la management account.

**2.2** `Team$` con valor vacío es **gasto sin etiquetar** — todo el costo que no lleva un tag `Team`, incluidos recursos que alguien olvidó etiquetar y tipos de costo que directamente no se pueden etiquetar. Es el número más importante porque acota la credibilidad del informe entero: si el 35% de la factura está sin asignar, la cifra de chargeback de ningún equipo puede confiarse mejor que ±35%, y la acción correcta a continuación es una política de enforcement de tagging, no un dashboard más lindo.

**2.3** Los tags con prefijo `aws:` son **generados por AWS**. AWS los crea y los mantiene (acá, CloudFormation estampa cada recurso que aprovisiona con el nombre de su stack). Podés activarlos o desactivarlos para cost allocation, pero no podés crear, modificar ni borrar la clave en sí. El prefijo reservado `aws:` se aplica en todas las APIs de tagging de AWS.

**2.4** **AWS Cost Categories**, específicamente las **split charge rules**. Una split charge rule toma el costo de un bucket compartido o no etiquetable (soporte, plano de control compartido de EKS, un NAT Gateway) y lo redistribuye entre categorías destino de forma `PROPORTIONAL`, `EVEN` o con un porcentaje `FIXED` — que es precisamente el problema de asignación que los tags no pueden expresar, ya que no hay recurso al cual etiquetar.

---

### Bloque 3 — Cost Categories

**3.1** **Gana la regla 1** — `platform`. Las reglas de Cost Category se evalúan **de arriba hacia abajo y la primera coincidencia asigna el valor**; la evaluación se detiene ahí. Por lo tanto, el orden de las reglas es semánticamente significativo, y una regla amplia de tipo catch-all ubicada temprano se traga silenciosamente todo lo que está debajo. Ordená las reglas de la más específica a la más general.

**3.2** Desde el **1 de septiembre** — el primer día del mes en el que se creó. `EffectiveStart` siempre está alineado al mes; una Cost Category nunca entra en vigencia a mitad de mes. Para cubrir meses anteriores tenés que solicitar la aplicación retroactiva (backfill), disponible por hasta 12 meses.

**3.3** **Repartir costos compartidos.** Un NAT Gateway, un plano de control de EKS, un cargo de soporte enterprise o una plataforma de observabilidad compartida sirven a varios equipos; hay un solo recurso (o ningún recurso) y por lo tanto, como mucho, un solo valor de tag. Una split charge rule distribuye ese costo único entre múltiples categorías de forma proporcional. Secundariamente: una Cost Category puede clasificar por cuenta, servicio o región — dimensiones donde no existe tag alguno que aplicar.

**3.4** `--default-value` es el balde para el costo que no matchea **ninguna regla** — acá, `Unallocated`. Observarlo a lo largo de tres meses te dice si tu modelo de asignación está convergiendo o pudriéndose: un `Unallocated` que se achica significa que las cargas nuevas se etiquetan y clasifican al lanzarse; uno que crece significa que los equipos despliegan más rápido de lo que se mantiene el conjunto de reglas, y tus números de chargeback están perdiendo cobertura en silencio.

---

### Bloque 4 — AWS Budgets

**4.1** Sí, se disparó: 1 487 / 2 000 = 74,4%... lo cual está **por debajo** del 80%, así que **no** se disparó. Releé los números — el actual está al 74% del límite, por debajo del umbral `ACTUAL`. El umbral `FORECASTED`, en cambio, proyecta USD 2 140 (107% del límite) y **sí** se disparó. Ese es exactamente el valor que aporta: `ACTUAL` solo puede contarte sobre plata que ya se fue, así que en el mejor caso te avisa cuando el sobregasto está parcialmente consumado. `FORECASTED` te avisa mientras todavía queda un mes para cambiar el resultado. Todo budget de costos en producción debería llevar ambos.

**4.2** Falta el prefijo `user:`. El valor correcto del filtro es `"user:Environment$prod"`. Sin el prefijo, el filtro no matchea nada y el budget reporta silenciosamente USD 0.00 — sin error, sin advertencia. (Secundariamente, `Environment` debe estar activado como cost allocation tag para que el filtro matchee algo, incluso con la sintaxis correcta.)

**4.3** **`LESS_THAN`.** Un budget de utilización sigue el porcentaje de horas de reserva compradas que efectivamente se consumen. Una utilización alta es buena; querés que te alerten cuando *cae*, porque las horas de reserva sin usar son plata ya gastada en capacidad que nadie está corriendo. La misma lógica aplica a `RI_COVERAGE`, `SAVINGS_PLANS_UTILIZATION` y `SAVINGS_PLANS_COVERAGE` — los cuatro alertan hacia abajo.

**4.4** La **política de acceso del topic SNS no permite que el service principal `budgets.amazonaws.com` haga `SNS:Publish`**. Budgets no asume un rol para las notificaciones; publica como service principal, así que el permiso debe otorgarse en la política de recurso del topic. La creación del budget tiene éxito igual, así que la falla es invisible hasta que la alerta con la que contabas nunca llega. (Un segundo candidato: el topic está cifrado con una CMK de KMS cuya key policy no le otorga `kms:GenerateDataKey` al principal de Budgets.)

**4.5** Los primeros dos budgets son gratuitos, quedando cuatro facturables: 4 × USD 0.02/día × ~30 días = **≈ USD 2.40/mes**.

**4.6** **Cost Explorer** es una herramienta de *análisis*: responde "¿a dónde se fue la plata?" de forma retrospectiva, con filtrado, agrupación y pronóstico, y requiere que una persona vaya a mirar. **AWS Budgets** es una herramienta de *monitoreo y aplicación*: vigila un umbral que declaraste y empuja una notificación — o ejecuta una acción, como aplicar una política IAM o una SCP — cuando el gasto real o pronosticado lo cruza, sin que nadie esté mirando.

---

### Bloque 5 — Cost Anomaly Detection

**5.1** Una alerta de **Budgets** se dispara cuando el gasto cruza un umbral **que definiste de antemano**. Una alerta de **Cost Anomaly Detection** se dispara cuando el gasto se desvía de una línea base que **el machine learning derivó de tu propia historia**, sin ningún umbral declarado — que es la única manera de atrapar eventos de costo que no anticipaste.

**5.2** `TotalActualSpend` (USD 2 380) es todo lo que ese servicio costó durante la ventana de la anomalía, incluida la porción que hubieras gastado de todos modos. `TotalImpact` (USD 2 104) es `TotalActualSpend − TotalExpectedSpend` — el **exceso atribuible a la anomalía**. Reportá `TotalImpact` como el costo del incidente; reportar el gasto real exagera el daño por el monto del uso legítimo de línea base.

**5.3** La frecuencia `IMMEDIATE` requiere un **subscriber SNS**. La entrega instantánea por anomalía solo está implementada sobre SNS; el tipo de subscriber EMAIL se soporta únicamente para los digests `DAILY` y `WEEKLY`. Enrutá a través de SNS (que después puede abanicar hacia email, Lambda, Chatbot/Slack o PagerDuty) si necesitás notificación inmediata.

**5.4** Enviá **`PLANNED_ACTIVITY`**. Esto le dice al modelo que el pico fue actividad de negocio esperada, y no una anomalía genuina ni un error de detección, de modo que el patrón se incorpora a la línea base y no genera una alerta nueva el noviembre siguiente. Enviar `NO` (falso positivo) es la señal equivocada — le enseña al modelo a descartar los picos de CloudFront en general, incluido el no planificado del que sí querés enterarte.

**5.5** **Nada.** AWS Cost Anomaly Detection es gratuito, incluidos monitores, suscripciones y notificaciones. No hay razón para no habilitar un monitor `DIMENSIONAL`/`SERVICE` en cada payer account desde el día uno.

---

### Bloque 6 — CUR / Data Exports

**6.1** Dos cualesquiera de: **granularidad horaria (y a nivel de recurso) para historia arbitraria**, mientras que los datos horarios de Cost Explorer están limitados a 14 días; **todas las columnas de facturación** (~300 campos — términos de precio, ARNs de reservas, detalles de descuentos, split cost allocation data) frente a las dimensiones fijas de Cost Explorer; **SQL arbitrario** vía Athena/Redshift en lugar de dos cláusulas group-by por petición; **sin cargo por petición** por los datos en sí; **reconciliación byte a byte con la factura**, que las cifras agregadas de Cost Explorer no pueden proveer.

**6.2** Se entrega a un **bucket de S3 tuyo**, en la cuenta y el prefijo que especifiques. **AWS no cobra nada por producir o entregar el reporte** — pagás únicamente el almacenamiento y las peticiones de S3, más el procesamiento de Athena/Redshift/QuickSight que le montes encima.

**6.3** **Doble conteo causado por un `line_item_line_item_type` sin filtrar.** El CUR contiene muchos tipos de fila en la misma tabla: las filas `SavingsPlanCoveredUsage` muestran el uso cubierto (a USD 0.00 unblended) mientras que las filas `SavingsPlanRecurringFee` llevan la plata real; `DiscountedUsage` se aparea con `RIFee`; y `Tax`, `Credit`, `Refund` y `EdpDiscount` coexisten todas. Sumar cada fila sin filtrar por line item type infla el total. (Una segunda causa, menos común: el prefijo de S3 contiene versiones de reporte superpuestas porque se usó `CREATE_NEW_REPORT` y la tabla de Glue matchea ambas.)

**6.4** Cuando necesitás un **rastro de auditoría inmutable** — probar qué decían los datos de facturación en un día dado, para una auditoría financiera, una disputa con un cliente o una reconciliación contra un mes reexpresado. `CREATE_NEW_REPORT` preserva cada versión entregada en lugar de sobrescribir; el costo es un crecimiento ilimitado de S3 y una tabla de Glue que debe apuntar a una única versión y no al prefijo entero.

**6.5** El CUR **no es inmutable**. AWS lo refresca hasta **tres veces por día** y reexpresa datos previos a medida que los cargos se finalizan (créditos aplicados, asignación de RI/SP recalculada, impuestos computados, reembolsos registrados). Un job que asume que el archivo de ayer es definitivo va a producir números que en silencio no coinciden con la factura. El patrón correcto es recargar el período de facturación abierto completo en cada ejecución y deduplicar por `(bill_billing_period_start_date, identity_line_item_id, identity_time_interval)`.

---

### Bloque 7 — Consolidated billing

**7.1** Porque el precio por tramos/volumen se aplica sobre el **uso agregado de toda la Organization**, no por cuenta. Cuatro facturas separadas arrancan cada una en el tramo más alto (más caro) y nunca acumulan suficiente uso para alcanzar los tramos más baratos. Una factura consolidada suma el uso primero, así que el total combinado alcanza un tramo de precio menor y parte del almacenamiento se factura a la tarifa con descuento. La misma agregación aplica a la transferencia de datos.

**7.2** Bajo consolidated billing, la **compartición de descuentos de RI y Savings Plans está habilitada por defecto**, así que la Reserved Instance sin usar de la cuenta A se aplica automáticamente al uso On-Demand coincidente de la cuenta B — el beneficio sigue al uso, no a la compra. Para mantener el beneficio exclusivo de A, el payer debe **desactivar la compartición de descuentos para las otras cuentas** (o para todas menos A) en Billing → Preferences. Alternativamente, una RI *regional size-flexible* podría convertirse en una RI *zonal*, que no flota, pero el control soportado es la preferencia de compartición.

**7.3** **Solo los costos de su propia cuenta.** Cost Explorer en una member account está acotado a esa cuenta. La dimensión `LINKED_ACCOUNT` y la vista completa de la Organization están disponibles solo en la management account (o en una cuenta designada como delegated administrator para billing).

**7.4** **No.** Las Service Control Policies son una funcionalidad de `FeatureSet: ALL`. Con solo `CONSOLIDATED_BILLING` no hay SCPs para aplicar, así que no se puede configurar una budget action `APPLY_SCP`. Habría que habilitar primero todas las funciones en la Organization — lo cual requiere que cada member account acepte el cambio y no se puede deshacer.

**7.5** **Blended cost**, en el caso acotado del chargeback interno entre cuentas que comparten reservas. El unblended cost acreditaría todo el descuento a la cuenta que casualmente compró la RI y cobraría a las cuentas consumidoras una tarifa artificialmente distorsionada; el blended reparte la tarifa promediada entre todas las cuentas que consumen el mismo tipo de instancia, que es la asignación interna más justa. Para cualquier cosa de cara a la factura — reconciliación, cuentas por pagar, pronosticar la factura real — usá **unblended** (caja) o **amortized** (devengado). Notá que la mayoría de las prácticas FinOps maduras hoy prefieren amortized por sobre blended, porque el blended es un promedio que no reconcilia con nada.

---

### Bloque 8 — Estimación

**8.1** La **AWS Pricing Calculator** (`calculator.aws`). Es una herramienta web pública que no requiere cuenta de AWS, ni credenciales, ni recursos desplegados — la única herramienta de estimación previa al despliegue en este tema. (La Price List Query API también es gratuita, pero sí requiere credenciales.)

**8.2** Lo más probable es **`operatingSystem`** — matcheaste una SKU de Windows o RHEL en lugar de Linux. Las otras omisiones de alta probabilidad son **`preInstalledSw`** (matcheando la SKU con SQL Server incluido) y **`tenancy`** (matcheando Dedicated en lugar de Shared). Las tres devuelven un precio legítimo y más alto sin error, porque preguntaste algo válido sobre un producto distinto.

**8.3** Dos cualesquiera de: la estimación usa **precios públicos de lista (On-Demand)** mientras que la factura real se beneficia de Savings Plans, Reserved Instances, una tarifa del Enterprise Discount Program o créditos; la estimación asume **100% de utilización durante el período declarado** mientras que las instancias reales se detienen, se escalan hacia abajo fuera de horario o nunca alcanzan el tamaño supuesto; no se modelaron las asignaciones del **Free Tier**; los volúmenes de tráfico/almacenamiento ingresados fueron conjeturas conservadoras que la realidad no alcanzó.

**8.4** **Nada.** La AWS Price List Query API es gratuita. Sirve la lista de precios pública, así que no expone información específica de la cuenta ni tiene cargo por petición — a diferencia de la API de Cost Explorer, a USD 0.01 por petición, que sirve tus datos privados de uso.

---

### Bloque 9 — Recomendaciones de optimización

**9.1** **AWS Compute Optimizer** es gratuito y está disponible para toda cuenta sin importar el plan de soporte (solo la función opcional de métricas mejoradas / ventana extendida es paga). El conjunto completo de checks de cost optimization de **AWS Trusted Advisor** requiere soporte **Business, Enterprise On-Ramp o Enterprise**; los planes Basic y Developer obtienen solo un conjunto núcleo limitado, y la propia API `support` devuelve `SubscriptionRequiredException` por debajo de Business.

**9.2** Porque **Compute Optimizer no ve la memoria por defecto**. Su análisis de EC2 se construye sobre las métricas de CloudWatch que EC2 publica nativamente — CPU, red, disco — y la utilización de memoria requiere que el agente de CloudWatch esté instalado y publicando. Una JVM con un heap grande puede estar al 6% de CPU consumiendo el 90% de la RAM; achicarla solo con evidencia de CPU provoca OOM kills en producción. Verificá la memoria (y cualquier SLO de burst/latencia) antes de actuar sobre un finding `OVER_PROVISIONED`.

**9.3** Te protege de recomendar reducciones de tamaño cuyos ahorros no se van a materializar. Con `BenefitsConsidered: true`, el análisis tiene en cuenta la cobertura existente de Reserved Instances y Savings Plans. Una instancia ya cubierta por un compromiso no te cuesta nada extra al margen — achicarla no reduce la factura, solo deja el compromiso subutilizado, y podés terminar pagando la reserva sin usar *más* la misma carga de trabajo. Con `false` obtenés un número de ahorro que asume que todo es On-Demand.

**9.4** **Cost optimization, performance, security, fault tolerance y service limits** (AWS también expone una categoría de *operational excellence*). El conjunto completo de checks se desbloquea con los planes de soporte **Business, Enterprise On-Ramp y Enterprise**. Basic y Developer reciben solo un conjunto limitado de checks núcleo (principalmente service limits y unos pocos de seguridad).

**9.5** `EstimatedUtilization` predice **qué porcentaje del compromiso de Savings Plan recomendado consumiría efectivamente tu uso** — 99,4% significa que casi nada del compromiso horario se desperdiciaría. Un valor bajo es peligroso porque un Savings Plan te factura la tarifa horaria comprometida **la uses o no**: al 60% de utilización pagás por el 40% de nada, y el "ahorro" puede fácilmente convertirse en una pérdida neta frente a On-Demand. Las recomendaciones se construyen a partir de una ventana de 7/30/60 días, así que cualquier cambio de arquitectura planificado (una migración a Fargate, un desmantelamiento estilo datacenter) invalida la proyección.

---

### Bloque 10 — Alarmas de facturación y Free Tier

**10.1** (a) **"Receive CloudWatch billing alerts" no está habilitado** en las Billing preferences de la management account, así que el namespace `AWS/Billing` nunca se puebla. (b) La alarma se **creó en una región distinta de `us-east-1`**, donde la métrica `EstimatedCharges` no existe. Una tercera posibilidad: la alarma se creó en una *member account* — la métrica se publica solo en la payer account.

**10.2** `EstimatedCharges` es un **contador acumulado del mes a la fecha**, publicado aproximadamente cada 6 horas y creciendo monótonamente a lo largo del mes. `Maximum` devuelve el valor más reciente y más alto del período de evaluación, que es la cifra verdadera del mes a la fecha; `Average` devolvería un punto medio sin sentido de un contador creciente y `Sum` multiplicaría el total por la cantidad de datapoints. El valor se desploma el día 1 porque comienza un nuevo período de facturación y el contador se reinicia cerca de cero.

**10.3** Tres cualesquiera de: **filtrado por servicio, linked account, tag, Cost Category o región** (la alarma solo puede ver el total de la cuenta, opcionalmente por servicio); **alertas basadas en forecast** (notificaciones `FORECASTED`); **budget actions** que aplican una política IAM o una SCP o detienen instancias EC2/RDS; **tipos de budget de usage, RI-utilization, RI-coverage y Savings Plans** en vez de solo costo; **múltiples umbrales con distintos subscribers en un mismo budget**; **períodos diarios, mensuales, trimestrales y anuales**.

**10.4** **Always Free** — nunca vence, p. ej. 1 millón de requests de AWS Lambda por mes, o 25 GB de almacenamiento en DynamoDB. **12 Months Free** — disponible durante el primer año tras la creación de la cuenta, p. ej. 750 horas/mes de EC2 `t2.micro`/`t3.micro`, o 5 GB de S3 Standard. **Trials** — de corto plazo, específicos por servicio, que empiezan cuando activás el servicio por primera vez, p. ej. una prueba de 30 días de Amazon Inspector o 750 horas de notebooks de Amazon SageMaker Studio durante 2 meses.

---

### Bloque 11 — Billing Conductor y limpieza

**11.1** **No.** AWS te cobra exactamente lo mismo; la factura real no se ve afectada. Billing Conductor produce una vista de facturación **pro forma** — una representación paralela del mismo uso subyacente con tus markups, descuentos y líneas de detalle personalizadas aplicadas — usada para facturar a unidades de negocio internas o a clientes finales. Su propio costo es un cargo mensual por cuenta de billing group, que *sí* aparece en tu factura real.

**11.2** **Las Cost Categories agrupan la factura real** en dimensiones de negocio sin cambiar ningún monto; **Billing Conductor genera una segunda factura modificada** con montos distintos (markups, descuentos, líneas de detalle personalizadas) para chargeback o reventa, dejando la factura real de AWS intacta.

**11.3** Borrar el export solo **detiene las entregas futuras**. Cada archivo Parquet ya escrito en el prefijo de S3 permanece y sigue acumulando cargos de almacenamiento — potencialmente durante años, ya que un CUR horario a nivel de recurso crece rápido. Tenés que vaciar el prefijo por separado (o adjuntar una regla de ciclo de vida) para dejar de pagarlo.

**11.4** Porque una **subscription de anomalías referencia a su monitor por ARN**. Borrar un monitor que todavía tiene suscripciones adjuntas falla con un error de dependencia — el mismo orden de integridad referencial que aplica a los topics SNS con suscripciones o a los roles IAM con políticas adjuntas. Borrá primero el objeto dependiente y después el objeto del que depende.

</details>