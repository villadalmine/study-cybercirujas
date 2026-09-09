# gcp-cdl · 6.1 — Ejercicios guiados

## Recognize how Google Cloud supports an organization's ability to control their cloud costs

> **Peso en el examen:** 5.0 · **Versión del examen:** 2026-08-12
> **Fuente del objetivo:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

El examen Cloud Digital Leader te pide que *reconozcas* los mecanismos. Este laboratorio te hace *operarlos*, porque las distinciones conceptuales que el examen evalúa — budget vs. quota, costo bruto vs. costo neto, label vs. tag, project vs. billing account — son exactamente las distinciones que dejan de ser ambiguas en el momento en que ejecutás el comando y leés la salida.

Cada bloque es un conjunto de pasos numerados seguido de preguntas de comprensión. Las respuestas están en la sección plegable del final. No las leas hasta haber escrito las tuyas.

---

## Prerrequisitos y advertencia de costo

| Requisito | Por qué |
|---|---|
| Una cuenta de Cloud Billing que administres (`roles/billing.admin`) | Los budgets, exports y comandos de jerarquía tienen alcance de billing account |
| Un nodo de organización, o al menos un proyecto independiente | Los ejercicios 1 y 7 necesitan una jerarquía; quienes usen un proyecto independiente omiten los pasos de folders |
| `gcloud` ≥ 470.0.0, `bq`, `terraform` ≥ 1.5 (opcional) | Algunos comandos viven en las superficies `beta`/`alpha` |
| Un dataset de BigQuery que puedas crear | Destino del billing export |

**Hay dinero real involucrado.** Los costos de almacenamiento y consulta del billing export en BigQuery son pequeños (centavos), pero el ejercicio 6 crea una VM. La sección de limpieza del final no es opcional. Nada en este laboratorio te compromete a un Committed Use Discount — leé las advertencias de cada paso antes de apretar enter.

Definí tus variables de trabajo una sola vez:

```bash
export BILLING_ACCOUNT_ID="012345-6789AB-CDEF01"   # gcloud billing accounts list
export PROJECT_ID="finops-lab-001"
export REGION="us-central1"
export ZONE="us-central1-a"
export DATASET="finops_billing"

# The BigQuery table suffix is the billing account ID with dashes turned into underscores
export BA_SUFFIX="${BILLING_ACCOUNT_ID//-/_}"      # 012345_6789AB_CDEF01
echo "$BA_SUFFIX"
```

---

## Ejercicio 1 — Dónde se atribuye el costo: la jerarquía de recursos y la billing account

La idea equivocada más común en este objetivo es que la cuenta de Cloud Billing es *parte de* la jerarquía de recursos. No lo es. La jerarquía (Organization → Folder → Project → recurso) es la estructura de **IAM y políticas**. La cuenta de Cloud Billing es un instrumento de pago separado y externo que se **adjunta** a los proyectos. El costo se mide contra el **project**, y sube por los folders solo porque las herramientas de reporte vuelven a unir el proyecto con su ruta en la jerarquía.

### Pasos

1. Listá las billing accounts que podés ver y fijate en la columna `OPEN`:

   ```bash
   gcloud billing accounts list
   ```

   ```
   ACCOUNT_ID            NAME                    OPEN  MASTER_ACCOUNT_ID
   012345-6789AB-CDEF01  Corp Billing - Prod     True
   0AB1CD-2E3F45-6789GH  Corp Billing - Sandbox  True  012345-6789AB-CDEF01
   ```

   La segunda fila tiene un `MASTER_ACCOUNT_ID`: es una **subaccount**, un contenedor de facturación cuyos cargos se consolidan en la cuenta padre. Los revendedores y las grandes empresas usan subaccounts para aislar la factura de una unidad de negocio sin dividir el contrato.

2. Imprimí la posición de tu proyecto en la jerarquía:

   ```bash
   gcloud projects describe "$PROJECT_ID"
   ```

   ```yaml
   createTime: '2026-09-09T12:04:11.402Z'
   lifecycleState: ACTIVE
   name: finops-lab-001
   parent:
     id: '482910375512'
     type: folder
   projectId: finops-lab-001
   projectNumber: '739104857260'
   ```

   Anotá el **project number** (`739104857260`). Los budgets filtran por `projects/<PROJECT_NUMBER>`, no por el project ID — una causa frecuente de un budget que silenciosamente no coincide con nada.

3. Imprimí el vínculo de facturación, que es una superficie de API *distinta* (`cloudbilling`, no `cloudresourcemanager`):

   ```bash
   gcloud billing projects describe "$PROJECT_ID"
   ```

   ```yaml
   billingAccountName: billingAccounts/012345-6789AB-CDEF01
   billingEnabled: true
   name: projects/finops-lab-001/billingInfo
   projectId: finops-lab-001
   ```

4. Listá todos los proyectos que actualmente cargan a la cuenta. En un entorno real esta es la primera línea de una revisión de costos — un proyecto inesperado acá es un centro de costo sin dueño:

   ```bash
   gcloud billing projects list --billing-account="$BILLING_ACCOUNT_ID" \
     --format="table(projectId, billingEnabled)"
   ```

   ```
   PROJECT_ID           BILLING_ENABLED
   finops-lab-001       True
   platform-prod-eu     True
   legacy-datalake-01   True
   ```

5. Recorré la ruta de folders hacia arriba para ver qué agregaría una consolidación de costos:

   ```bash
   gcloud resource-manager folders describe 482910375512 \
     --format="value(displayName, parent)"
   ```

   ```
   engineering	organizations/318472019283
   ```

6. **No ejecutes esto contra nada que te importe.** Leelo nada más. Así es como se desvincula un proyecto de la facturación — el "kill switch" que el ejercicio 4 automatiza:

   ```bash
   # gcloud billing projects unlink "$PROJECT_ID"
   ```

### Comprobación de comprensión

- **P1.** Un proyecto se mueve del folder `engineering` al folder `research`. Su billing account no cambia. ¿Los datos históricos de costo se mueven con él en los reportes de Cloud Billing?
- **P2.** ¿Puede un proyecto cargarse a dos cuentas de Cloud Billing simultáneamente? ¿Puede una cuenta de Cloud Billing pagar proyectos de dos organizaciones distintas?
- **P3.** Querés que la unidad de negocio Data Platform reciba su propia factura sin dejar de estar bajo el contrato corporativo y los descuentos negociados. ¿Qué construcción del paso 1 usás, y por qué no "una segunda billing account"?
- **P4.** El paso 2 devolvió `projectNumber: '739104857260'` y `projectId: finops-lab-001`. ¿Cuál va en el filtro de un budget, y cuál es el modo de fallo si usás el otro?

---

## Ejercicio 2 — Labels: la única dimensión que hace asignable el costo

La atribución de costos más allá de "por proyecto" existe solo si los recursos llevan labels, y las labels aparecen en los datos de facturación **desde el momento en que se aplican en adelante**. No hay backfill. Esta es la razón operativa por la que la gobernanza de labels es una decisión del primer día y no una tarea de limpieza.

### Pasos

1. Aplicá un conjunto de labels al proyecto mismo. Las labels de proyecto responden "quién es dueño de este proyecto":

   ```bash
   gcloud projects update "$PROJECT_ID" \
     --update-labels=cost-center=eng-platform,env=lab,owner=sre-team
   ```

   ```yaml
   labels:
     cost-center: eng-platform
     env: lab
     owner: sre-team
   name: finops-lab-001
   projectId: finops-lab-001
   ```

2. Creá una VM etiquetada. Las labels de recurso responden "qué workload dentro del proyecto":

   ```bash
   gcloud compute instances create finops-lab-vm \
     --project="$PROJECT_ID" \
     --zone="$ZONE" \
     --machine-type=e2-small \
     --image-family=debian-12 \
     --image-project=debian-cloud \
     --labels=cost-center=eng-platform,workload=demo-api,env=lab
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/finops-lab-001/zones/us-central1-a/instances/finops-lab-vm].
   NAME           ZONE           MACHINE_TYPE  INTERNAL_IP  EXTERNAL_IP    STATUS
   finops-lab-vm  us-central1-a  e2-small      10.128.0.12  34.72.118.204  RUNNING
   ```

3. Encontrá todos los recursos sin labels del proyecto — la población que aparecerá como gasto no asignado. Cloud Asset Inventory hace esto sin tocar la API de cada servicio:

   ```bash
   gcloud asset search-all-resources \
     --scope="projects/$PROJECT_ID" \
     --query="NOT labels.cost-center:*" \
     --format="table(assetType, displayName, location)"
   ```

   ```
   ASSET_TYPE                              DISPLAY_NAME     LOCATION
   compute.googleapis.com/Disk             finops-lab-vm    us-central1-a
   compute.googleapis.com/Network          default          global
   compute.googleapis.com/Firewall         default-allow-ssh global
   ```

   Notá que el disco de arranque es un **recurso facturable separado** y no heredó las labels de la instancia. Los persistent disks se facturan de forma independiente de la VM y siguen facturando mientras la VM está detenida.

4. Corregí el disco:

   ```bash
   gcloud compute disks add-labels finops-lab-vm \
     --zone="$ZONE" \
     --labels=cost-center=eng-platform,workload=demo-api,env=lab
   ```

5. Leé el conjunto de restricciones que gobierna las claves de label — no es texto arbitrario:

   ```bash
   gcloud projects update "$PROJECT_ID" --update-labels=Cost_Center=X 2>&1 | head -3
   ```

   ```
   ERROR: (gcloud.projects.update) INVALID_ARGUMENT: Label keys must start with a lowercase letter
   and can only contain lowercase letters, numeric characters, underscores and dashes.
   ```

### Comprobación de comprensión

- **P5.** Tanto las labels como los tags adjuntan metadatos clave/valor a los recursos. ¿Cuál de los dos aparece como dimensión de asignación de costos en el billing export, y para qué sirve realmente el otro?
- **P6.** Aplicás `cost-center=eng-platform` a una VM que viene corriendo hace seis meses. ¿Qué muestra la factura de enero para esa VM bajo esa label?
- **P7.** En el paso 3 el disco de arranque no tenía labels aunque la VM sí. Da dos consecuencias de facturación que un reporte mensual revelaría.
- **P8.** Un equipo argumenta que la separación por proyecto hace innecesarias las labels: "un proyecto por equipo, listo". Enunciá el argumento técnico más fuerte contra depender solo de los límites de proyecto para la asignación.

---

## Ejercicio 3 — Billing export a BigQuery, y la trampa de bruto vs. neto

Los reportes de la Console son una vista. El registro autoritativo, unible y retenible es el export a BigQuery. Dos hechos dominan cada consulta que vayas a escribir alguna vez contra él: **los credits son un campo repetido, y sus montos son negativos**; y **el export no hace backfill**.

### Pasos

1. Creá el dataset destino. Ubicalo junto a tu región de reporte — consultar un dataset de facturación entre regiones es un costo recurrente y evitable:

   ```bash
   bq --location=US mk --dataset \
     --description="Cloud Billing export" \
     "${PROJECT_ID}:${DATASET}"
   ```

   ```
   Dataset 'finops-lab-001:finops_billing' successfully created.
   ```

2. Habilitá el export. Este paso es solo por Console para la configuración inicial:
   **Billing → Billing export → BigQuery export → Standard usage cost → Edit settings**, seleccioná el proyecto y el dataset, guardá. Repetí para **Detailed usage cost**.

3. Esperá. Las primeras filas suelen aparecer en unas pocas horas; un día completo de datos se asienta en aproximadamente 24 horas. Verificá que las tablas se materializaron:

   ```bash
   bq ls "${PROJECT_ID}:${DATASET}"
   ```

   ```
                   tableId                    Type    Labels   Time Partitioning
    ---------------------------------------- ------- -------- -------------------
     gcp_billing_export_v1_012345_6789AB_CDEF01           TABLE            DAY (field: _PARTITIONTIME)
     gcp_billing_export_resource_v1_012345_6789AB_CDEF01  TABLE            DAY (field: _PARTITIONTIME)
   ```

4. Ejecutá la consulta de costo neto. Este es el patrón SQL más importante de este objetivo:

   ```sql
   SELECT
     service.description AS service,
     ROUND(SUM(cost), 2) AS gross_cost,
     ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS credits,
     ROUND(SUM(cost)
           + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS net_cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
     AND cost_type = 'regular'
   GROUP BY service
   ORDER BY net_cost DESC
   LIMIT 10;
   ```

   ```
   +--------------------------+------------+----------+----------+
   | service                  | gross_cost | credits  | net_cost |
   +--------------------------+------------+----------+----------+
   | Compute Engine           |     412.88 |  -103.22 |   309.66 |
   | Cloud Storage            |      88.14 |    -4.40 |    83.74 |
   | Networking               |      61.07 |     0.00 |    61.07 |
   | BigQuery                 |      12.93 |   -12.93 |     0.00 |
   +--------------------------+------------+----------+----------+
   ```

   Acá BigQuery neta a cero porque los créditos de free tier lo cubrieron. Un reporte que mostrara solo `gross_cost` mandaría a alguien a optimizar un workload de consultas que no cuesta nada.

5. Separá el gasto asignado del no asignado. Prestá atención a cuál columna `labels` estás leyendo:

   ```sql
   SELECT
     project.id AS project_id,
     IFNULL((SELECT l.value FROM UNNEST(labels) AS l WHERE l.key = 'cost-center'),
            '(unallocated)') AS resource_cost_center,
     IFNULL((SELECT l.value FROM UNNEST(project.labels) AS l WHERE l.key = 'cost-center'),
            '(unallocated)') AS project_cost_center,
     ROUND(SUM(cost)
           + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)), 2) AS net_cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
   GROUP BY 1, 2, 3
   ORDER BY net_cost DESC;
   ```

   ```
   +------------------+----------------------+---------------------+----------+
   | project_id       | resource_cost_center | project_cost_center | net_cost |
   +------------------+----------------------+---------------------+----------+
   | platform-prod-eu | (unallocated)        | eng-platform        |    91.44 |
   | finops-lab-001   | eng-platform         | eng-platform        |     6.02 |
   +------------------+----------------------+---------------------+----------+
   ```

   Las `labels` de nivel superior son labels de **recurso**. `project.labels` son labels de proyecto. `system_labels` son las que aplica Google (especificación de máquina, nombre del cluster de GKE). Confundir las dos primeras produce un reporte de asignación que está silenciosamente mal.

6. Confirmá qué te da el export detallado que el estándar no puede:

   ```sql
   SELECT
     resource.name AS resource,
     sku.description AS sku,
     ROUND(SUM(cost), 4) AS cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_resource_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
     AND service.description = 'Compute Engine'
   GROUP BY 1, 2
   ORDER BY cost DESC
   LIMIT 5;
   ```

   ```
   +------------------------------------------------------+----------------------------------+--------+
   | resource                                             | sku                              | cost   |
   +------------------------------------------------------+----------------------------------+--------+
   | //compute.googleapis.com/.../instances/finops-lab-vm | E2 instance Core running in Am.. | 0.3110 |
   | //compute.googleapis.com/.../disks/finops-lab-vm     | Storage PD Capacity              | 0.0224 |
   +------------------------------------------------------+----------------------------------+--------+
   ```

### Comprobación de comprensión

- **P9.** ¿Por qué `credits` es un `ARRAY<STRUCT>` en lugar de una sola columna numérica, y qué significa un `amount` negativo?
- **P10.** Un CFO pide los últimos 18 meses de gasto por servicio. Habilitaste el export a BigQuery hace tres semanas. ¿Qué podés entregar y qué no se puede recuperar?
- **P11.** Filtrás `WHERE cost_type = 'regular'`. Nombrá los otros valores que toma esta columna y enunciá un escenario donde excluirlos hace que tu reporte esté mal.
- **P12.** Un reporte agrupa por las `labels` de nivel superior y muestra el 80% del gasto de Compute Engine como `(unallocated)`, mientras que todos los proyectos llevan `cost-center`. ¿Cuál es el bug?
- **P13.** Export estándar vs. detallado: enunciá el trade-off en una oración, incluyendo el costo del detallado.

---

## Ejercicio 4 — Budgets y alertas: un sistema de notificaciones, no un tope de gasto

Este es el punto conceptual de mayor rendimiento del objetivo. **Un budget no detiene nada.** Compara el gasto real (o pronosticado) contra un umbral y emite un mensaje. Detener el gasto requiere una acción separada y deliberada.

### Pasos

1. Creá un budget con cuatro reglas de umbral — tres sobre el gasto real, una sobre el pronóstico:

   ```bash
   gcloud billing budgets create \
     --billing-account="$BILLING_ACCOUNT_ID" \
     --display-name="platform-monthly-usd1000" \
     --budget-amount=1000USD \
     --calendar-period=month \
     --filter-projects="projects/739104857260" \
     --filter-labels="cost-center=eng-platform" \
     --filter-credit-types-treatment=include-all-credits \
     --threshold-rule=percent=0.5 \
     --threshold-rule=percent=0.9 \
     --threshold-rule=percent=1.0 \
     --threshold-rule=percent=1.0,basis=forecasted-spend
   ```

   ```
   Created budget [billingAccounts/012345-6789AB-CDEF01/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa].
   ```

2. Leelo de vuelta como lo ve la API. Esta es la forma canónica del recurso:

   ```bash
   gcloud billing budgets describe \
     "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" \
     --format=json
   ```

   ```json
   {
     "amount": {
       "specifiedAmount": { "currencyCode": "USD", "units": "1000" }
     },
     "budgetFilter": {
       "calendarPeriod": "MONTH",
       "creditTypesTreatment": "INCLUDE_ALL_CREDITS",
       "labels": { "cost-center": { "values": ["eng-platform"] } },
       "projects": ["projects/739104857260"]
     },
     "displayName": "platform-monthly-usd1000",
     "etag": "aa11bb22cc33",
     "name": "billingAccounts/012345-6789AB-CDEF01/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa",
     "thresholdRules": [
       { "thresholdPercent": 0.5 },
       { "thresholdPercent": 0.9 },
       { "thresholdPercent": 1.0 },
       { "thresholdPercent": 1.0, "spendBasis": "FORECASTED_SPEND" }
     ]
   }
   ```

   `spendBasis` está ausente en las primeras tres porque `CURRENT_SPEND` es el valor por defecto.

3. Declará el mismo budget como código. En cualquier organización con más de un puñado de proyectos, los budgets se aprovisionan con el mismo pipeline que aprovisiona el proyecto:

   ```hcl
   resource "google_pubsub_topic" "budget_alerts" {
     project = var.project_id
     name    = "billing-budget-alerts"
   }

   resource "google_billing_budget" "platform_monthly" {
     billing_account = var.billing_account_id
     display_name    = "platform-monthly-usd1000"

     budget_filter {
       projects               = ["projects/${var.project_number}"]
       calendar_period        = "MONTH"
       credit_types_treatment = "INCLUDE_ALL_CREDITS"
       labels = {
         cost-center = "eng-platform"
       }
     }

     amount {
       specified_amount {
         currency_code = "USD"
         units         = "1000"
       }
     }

     threshold_rules { threshold_percent = 0.5 }
     threshold_rules { threshold_percent = 0.9 }
     threshold_rules { threshold_percent = 1.0 }
     threshold_rules {
       threshold_percent = 1.0
       spend_basis       = "FORECASTED_SPEND"
     }

     all_updates_rule {
       pubsub_topic                   = google_pubsub_topic.budget_alerts.id
       schema_version                 = "1.0"
       disable_default_iam_recipients = true
     }
   }
   ```

4. Cableá las notificaciones programáticas. Creá el topic y otorgá permisos de publicación al service agent de Cloud Billing budgets (la Console lo hace por vos; la API no):

   ```bash
   gcloud pubsub topics create billing-budget-alerts --project="$PROJECT_ID"

   gcloud pubsub topics add-iam-policy-binding billing-budget-alerts \
     --project="$PROJECT_ID" \
     --member="serviceAccount:${BUDGETS_SERVICE_AGENT}" \
     --role="roles/pubsub.publisher"
   ```

   Adjuntalo al budget existente:

   ```bash
   gcloud billing budgets update \
     "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" \
     --all-updates-rule-pubsub-topic="projects/${PROJECT_ID}/topics/billing-budget-alerts" \
     --all-updates-rule-disable-default-iam-recipients
   ```

5. Inspeccioná el mensaje que va a recibir tu consumidor. Los mensajes se publican en **cada** refresco de datos, no solo al cruzar un umbral — el consumidor tiene que decidir:

   ```json
   {
     "budgetDisplayName": "platform-monthly-usd1000",
     "alertThresholdExceeded": 0.9,
     "costAmount": 913.44,
     "costIntervalStart": "2026-09-01T07:00:00Z",
     "budgetAmount": 1000.0,
     "budgetAmountType": "SPECIFIED_AMOUNT",
     "currencyCode": "USD"
   }
   ```

   Los atributos del mensaje llevan `billingAccountId`, `budgetId` y `schemaVersion`. Cuando no se cruzó ningún umbral, `alertThresholdExceeded` está ausente.

6. **Leé, entendé, y recién después decidí.** Este es el kill switch automatizado. Desvincula la billing account de un proyecto, lo que termina todos los recursos facturables que hay en él, incluidos los datos en discos no replicados:

   ```python
   # main.py — Cloud Functions (2nd gen), Pub/Sub trigger
   import base64
   import json
   import os

   from googleapiclient import discovery

   BILLING = discovery.build("cloudbilling", "v1", cache_discovery=False)
   TARGET = f"projects/{os.environ['TARGET_PROJECT_ID']}"


   def stop_billing(event, context):
       payload = json.loads(base64.b64decode(event["data"]).decode("utf-8"))

       if payload.get("costAmount", 0) <= payload.get("budgetAmount", 0):
           return f"under budget: {payload.get('costAmount')} <= {payload.get('budgetAmount')}"

       info = BILLING.projects().getBillingInfo(name=TARGET).execute()
       if not info.get("billingAccountName"):
           return "billing already disabled"

       BILLING.projects().updateBillingInfo(
           name=TARGET, body={"billingAccountName": ""}
       ).execute()
       return f"billing disabled for {TARGET}"
   ```

   ```txt
   # requirements.txt
   google-api-python-client==2.134.0
   ```

   La service account de la función necesita `roles/billing.projectManager` sobre el proyecto **y** `roles/billing.user` sobre la billing account. Desplegá esto solo contra un proyecto cuya destrucción sea aceptable — un sandbox, un entorno por PR, un laboratorio de estudiantes. Nunca contra producción.

### Comprobación de comprensión

- **P14.** Tu budget es de $1.000 con un umbral del 100%. El mes cierra en $4.300 y no existe automatización de alertas más allá del email. ¿Qué hizo el budget, y qué no hizo?
- **P15.** ¿Qué te dice un umbral `FORECASTED_SPEND` al 100% que un umbral `CURRENT_SPEND` al 100% no puede decirte, y cuándo es menos confiable el pronóstico?
- **P16.** `creditTypesTreatment` está en `INCLUDE_ALL_CREDITS`. Hay committed use discounts y un crédito promocional activos. ¿Contra qué cifra se evalúa el umbral, y cómo cambiaría `EXCLUDE_ALL_CREDITS` el momento en que se dispara la alerta?
- **P17.** En el paso 5 el mensaje de Pub/Sub llega sin campo `alertThresholdExceeded`. ¿Debería actuar el consumidor? ¿Por qué Google publica estos mensajes en absoluto?
- **P18.** Da dos razones por las que la función kill-switch del paso 6 es inadecuada para un proyecto de producción, y nombrá el control que usarías ahí en su lugar.
- **P19.** Un budget filtrado por `projects/finops-lab-001` (project **ID**, no número) nunca se dispara. Explicá.

---

## Ejercicio 5 — Quotas: el control que sí previene el gasto

Los budgets observan. Las quotas **rechazan**. Una quota es un techo duro, impuesto por el servicio y evaluado en la llamada a la API, así que una quota agotada devuelve un error en lugar de aprovisionar un recurso. Bajar una quota es la barrera de gasto más barata y confiable disponible, y está subutilizada porque la gente piensa en las quotas como algo de lo que solo se pide más.

### Pasos

1. Leé tus quotas regionales de Compute Engine y el consumo actual:

   ```bash
   gcloud compute regions describe "$REGION" \
     --project="$PROJECT_ID" \
     --flatten="quotas[]" \
     --format="table(quotas.metric, quotas.usage, quotas.limit)"
   ```

   ```
   METRIC                    USAGE  LIMIT
   CPUS                      2.0    24.0
   DISKS_TOTAL_GB            10.0   4096.0
   IN_USE_ADDRESSES          1.0    8.0
   INSTANCES                 1.0    24.0
   SSD_TOTAL_GB              0.0    500.0
   PREEMPTIBLE_CPUS          0.0    24.0
   ```

2. Leé lo mismo a través de la Cloud Quotas API, que es la superficie agnóstica al servicio:

   ```bash
   gcloud beta quotas info list \
     --service=compute.googleapis.com \
     --project="$PROJECT_ID" \
     --format="table(quotaId, metric, isPrecise)" | head -8
   ```

   ```
   QUOTA_ID                       METRIC                                 IS_PRECISE
   CPUS-per-project-region        compute.googleapis.com/cpus            True
   INSTANCES-per-project-region   compute.googleapis.com/instances       True
   read-requests-per-minute       compute.googleapis.com/read_requests   False
   ```

   `isPrecise: True` marca una quota de **allocation** (un conteo de cosas que existen). `False` marca una quota de **rate** (llamadas por unidad de tiempo). Fallan de manera distinta: las quotas de allocation bloquean la creación; las de rate devuelven `429 RESOURCE_EXHAUSTED` y están pensadas para reintentarse con backoff.

3. Bajá una quota de allocation por debajo de lo que podría consumir una automatización desbocada:

   ```bash
   gcloud beta quotas preferences create cpus-cap-us-central1 \
     --service=compute.googleapis.com \
     --quota-id=CPUS-per-project-region \
     --preferred-value=8 \
     --dimensions=region="$REGION" \
     --project="$PROJECT_ID" \
     --email="platform-oncall@example.com" \
     --justification="Cap lab spend at 8 vCPU in us-central1"
   ```

   ```
   Created quota preference [projects/739104857260/locations/global/quotaPreferences/cpus-cap-us-central1].
   ```

4. Comprobá que el techo se aplica. Pedí más vCPU de las que quedan:

   ```bash
   gcloud compute instances create quota-probe \
     --project="$PROJECT_ID" --zone="$ZONE" --machine-type=n2-standard-16
   ```

   ```
   ERROR: (gcloud.compute.instances.create) Could not fetch resource:
    - Quota 'CPUS' exceeded.  Limit: 8.0 in region us-central1.
   ```

   No se creó ninguna instancia. No se incurrió en ningún cargo. Comparalo con el budget del ejercicio 4, que habría mandado un email después del hecho.

5. Poné la barrera complementaria a nivel de billing account — la que impide que un proyecto *nuevo* llegue a cobrarte:

   ```bash
   gcloud beta billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
     --format="table(bindings.role, bindings.members)"
   ```

   ```
   ROLE                          MEMBERS
   roles/billing.admin           ['user:finops-lead@example.com']
   roles/billing.user            ['group:platform-eng@example.com']
   roles/billing.viewer          ['group:all-engineers@example.com']
   ```

   Solo `roles/billing.user` (más `roles/billing.projectManager` sobre el proyecto) puede vincular un proyecto a esta cuenta. Quitar ese binding a un grupo amplio es un control de gasto en sí mismo.

### Comprobación de comprensión

- **P20.** Enunciá la diferencia entre un budget y una quota en términos de *cuándo* actúa cada uno respecto del gasto.
- **P21.** Se agotan una quota de allocation y una de rate. Describí el síntoma distinto que ve una aplicación en cada caso, y la remediación distinta.
- **P22.** Un equipo pide un aumento de quota de CPU a 500 en tres regiones "por las dudas". Da el argumento de gobernanza de costos para otorgar solo lo que el workload actual necesita.
- **P23.** Las quotas son por proyecto y por región. ¿Qué implica eso para una organización que quiere un único techo de cómputo a nivel de toda la organización?

---

## Ejercicio 6 — Modelos de precios y Active Assist: pagar menos por lo mismo

El control de costos no es solo "usar menos". Google Cloud reduce el precio unitario mediante mecanismos que son automáticos (sustained use discounts), contractuales (committed use discounts) u oportunistas (Spot). Los recommenders de Active Assist muestran dónde aplica cada uno.

### Pasos

1. Consultá el precio público de un SKU directamente desde la Cloud Catalog API. El service ID de Compute Engine es `6F81-5844-456A`:

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=200" \
   | jq -r '.skus[]
       | select(.description | test("N2 Instance Core running in Americas"))
       | {sku: .description,
          usage: .category.usageType,
          unit: .pricingInfo[0].pricingExpression.usageUnitDescription,
          nanos: .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos}'
   ```

   ```json
   {
     "sku": "N2 Instance Core running in Americas",
     "usage": "OnDemand",
     "unit": "hour",
     "nanos": 31611000
   }
   {
     "sku": "Spot Preemptible N2 Instance Core running in Americas",
     "usage": "Preemptible",
     "unit": "hour",
     "nanos": 7653000
   }
   ```

   Los `nanos` son milmillonésimas de una unidad de moneda: 31.611.000 nanos = $0,031611 por vCPU-hora bajo demanda, contra $0,007653 en Spot. Esa proporción — aproximadamente un 75–80% de descuento — es la razón por la que los workloads batch y tolerantes a fallos pertenecen a Spot.

2. Pedí recomendaciones de recursos ociosos. Se generan a partir de la utilización observada en una ventana móvil:

   ```bash
   gcloud recommender recommendations list \
     --project="$PROJECT_ID" \
     --location="$ZONE" \
     --recommender=google.compute.instance.IdleResourceRecommender \
     --format="table(name.basename(), primaryImpact.costProjection.cost.units, description)"
   ```

   ```
   NAME                                  UNITS  DESCRIPTION
   0f2a1c88-6d3e-4a1b-9e70-31c0a2f4bb19  -24    Save cost by stopping idle VM 'legacy-jenkins'.
   ```

   La convención de signo importa: `costProjection.cost.units = -24` significa **$24/mes ahorrados**, no $24 gastados. Los valores positivos indican una recomendación que aumenta el costo (un rightsizing que escala *hacia arriba* por confiabilidad).

3. Pedí rightsizing de tipo de máquina en el mismo alcance:

   ```bash
   gcloud recommender recommendations list \
     --project="$PROJECT_ID" --location="$ZONE" \
     --recommender=google.compute.instance.MachineTypeRecommender \
     --format="value(description)"
   ```

   ```
   Save cost by changing machine type from n2-standard-8 to n2-standard-2.
   ```

4. Pedí recomendaciones de commitment. **Leerlas no cuesta nada; actuar sobre una crea un contrato vinculante de 1 o 3 años.** No compres en este laboratorio:

   ```bash
   gcloud recommender recommendations list \
     --billing-account="$BILLING_ACCOUNT_ID" \
     --location=global \
     --recommender=google.cloudbilling.commitment.SpendBasedCommitmentRecommender \
     --format="table(name.basename(), primaryImpact.costProjection.cost.units, stateInfo.state)"
   ```

   ```
   NAME                                  UNITS  STATE
   c41b7e02-9a55-4d31-8f6c-2ad9e7c81d40  -1180  ACTIVE
   ```

5. Compará los tres mecanismos de reducción de precio sobre el recurso que ya tenés. Sin comando — razoná desde la tabla:

   | Mecanismo | Cómo lo obtenés | Compromiso | Descuento típico | Riesgo |
   |---|---|---|---|---|
   | Sustained use discount | Automático, por familia de máquina elegible, a medida que se acumula el uso mensual | Ninguno | Hasta ~30% en familias elegibles | Ninguno; la elegibilidad varía por familia |
   | Committed use discount | Comprado por 1 o 3 años, basado en recursos o en gasto | Vinculante | ~20–70% según el plazo | Pagás el compromiso lo uses o no |
   | Spot VMs | Solicitar `--provisioning-model=SPOT` | Ninguno | Hasta ~91% | Preemption con 30 s de aviso; no apto para trabajo con estado o crítico en latencia |

6. Estimá antes de construir. La [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) produce una estimación compartible; la Catalog API del paso 1 es lo que usás cuando la estimación tiene que generarla un pipeline y no una persona.

### Comprobación de comprensión

- **P24.** Los sustained use discounts y los committed use discounts bajan ambos el precio de Compute Engine. Enunciá la regla de decisión para elegir entre ellos para un workload dado.
- **P25.** Un equipo se compromete a 3 años de 100 vCPU y luego migra el workload a GKE Autopilot a los 8 meses. ¿Qué pasa con el cargo del commitment?
- **P26.** El paso 2 devolvió `units: -24`. Interpretá el signo, y explicá por qué un recommender emitiría alguna vez un valor positivo.
- **P27.** Las Spot VMs son ~80–90% más baratas. Nombrá dos características de un workload que hacen de Spot una elección correcta, y una que la hace incorrecta.

---

## Ejercicio 7 — Barreras de gobernanza: separación de funciones y organization policy

Un control de costos que depende de que la gente se acuerde no es un control. Dos mecanismos estructurales hacen que el comportamiento deseado sea el predeterminado: los **roles de IAM de billing** que separan quién gasta de quién paga, y la **organization policy** que restringe qué se puede crear.

### Pasos

1. Examiná el conjunto de roles de billing y qué puede hacer realmente cada uno:

   ```bash
   gcloud iam roles describe roles/billing.costsManager \
     --format="value(description, includedPermissions)" | tr ',' '\n' | head -12
   ```

   ```
   Manage budgets and view/export cost information of billing accounts.
   billing.accounts.get
   billing.accounts.getSpendingInformation
   billing.budgets.create
   billing.budgets.delete
   billing.budgets.get
   billing.budgets.list
   billing.budgets.update
   ```

   | Rol | Otorga |
   |---|---|
   | `roles/billing.creator` (nivel org) | Crear nuevas billing accounts |
   | `roles/billing.admin` | Control total: budgets, exports, IAM, vincular/desvincular proyectos |
   | `roles/billing.user` | Vincular un proyecto a esta billing account — el rol "puede gastar mi plata" |
   | `roles/billing.projectManager` (nivel proyecto) | Vincular/desvincular la facturación de ese proyecto |
   | `roles/billing.costsManager` | Budgets, vistas de costo y exports; **no** precios ni transacciones |
   | `roles/billing.viewer` | Solo lectura de datos de costo |

   El hecho estructural importante: `roles/owner` sobre un proyecto **no** incluye el derecho de vincular ese proyecto a una billing account. Esa división es deliberada, y es lo que permite a un equipo de plataforma delegar la propiedad de un proyecto sin delegar el gasto.

2. Aplicá una restricción de ubicación. La elección de región es una palanca de precio — el mismo SKU difiere materialmente entre regiones — y una política de ubicaciones también sirve para la residencia de datos:

   ```yaml
   # policy-locations.yaml
   name: projects/finops-lab-001/policies/gcp.resourceLocations
   spec:
     rules:
       - values:
           allowedValues:
             - in:us-central1-locations
             - in:europe-west1-locations
   ```

   ```bash
   gcloud org-policies set-policy policy-locations.yaml
   ```

   ```
   Created policy [projects/finops-lab-001/policies/gcp.resourceLocations].
   ```

3. Verificá que muerde:

   ```bash
   gcloud compute instances create wrong-region-vm \
     --project="$PROJECT_ID" --zone=asia-south1-a --machine-type=e2-small \
     --image-family=debian-12 --image-project=debian-cloud
   ```

   ```
   ERROR: (gcloud.compute.instances.create) Could not fetch resource:
    - Constraint constraints/gcp.resourceLocations violated for projects/finops-lab-001.
      asia-south1-a violates constraint constraints/gcp.resourceLocations
   ```

4. Restringí los tamaños de máquina con una custom constraint — el análogo directo de un techo de gasto expresado como política. Las custom constraints se definen en el nodo de organización:

   ```yaml
   # constraint-machine-types.yaml
   name: organizations/318472019283/customConstraints/custom.allowedMachineTypes
   resourceTypes:
     - compute.googleapis.com/Instance
   methodTypes:
     - CREATE
     - UPDATE
   condition: "resource.machineType.contains('/machineTypes/e2-') || resource.machineType.contains('/machineTypes/n2-standard-2') || resource.machineType.contains('/machineTypes/n2-standard-4')"
   actionType: ALLOW
   displayName: Allow only small e2 and n2-standard-2/4 machine types
   description: Prevents accidental provisioning of large, expensive machine types.
   ```

   ```bash
   gcloud org-policies set-custom-constraint constraint-machine-types.yaml
   ```

   ```yaml
   # policy-machine-types.yaml
   name: projects/finops-lab-001/policies/custom.allowedMachineTypes
   spec:
     rules:
       - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy policy-machine-types.yaml
   ```

5. Inspeccioná la política efectiva sobre el proyecto, incluyendo todo lo heredado de folders y de la organización:

   ```bash
   gcloud org-policies describe gcp.resourceLocations \
     --project="$PROJECT_ID" --effective
   ```

   ```yaml
   name: projects/739104857260/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:us-central1-locations
         - in:europe-west1-locations
   ```

### Comprobación de comprensión

- **P28.** Un desarrollador tiene `roles/owner` sobre un proyecto nuevo y no puede habilitar una API porque el proyecto no tiene billing account. ¿Qué rol falta, sobre qué recurso — y por qué esta separación es valiosa y no simplemente molesta?
- **P29.** Una organization policy define `gcp.resourceLocations` en el nodo de organización. Un folder por debajo define una lista más amplia. ¿Cuál es la política efectiva por defecto para un proyecto de ese folder, y qué tendría que cambiar para que gane la lista del folder?
- **P30.** Compará la custom constraint del paso 4 con la quota del ejercicio 5 como formas de prevenir una VM cara. Da un escenario para cada una donde el otro mecanismo habría fallado.
- **P31.** ¿Por qué `roles/billing.viewer` sobre un grupo amplio de ingeniería es una medida de control de costos y no solo una medida de transparencia?

---

## Ejercicio 8 — Diagnóstico: investigar una anomalía de costo de punta a punta

Una alerta de budget te dice que el gasto está alto. No te dice qué, dónde ni quién. Este es el runbook que convierte una alerta en un arreglo. Trabajalo en orden; cada paso reduce el espacio de búsqueda en un orden de magnitud.

### Pasos

1. **¿Qué SKU cambió?** Compará ayer contra el promedio diario de la semana previa, por SKU:

   ```sql
   WITH daily AS (
     SELECT
       DATE(usage_start_time) AS day,
       sku.description AS sku,
       SUM(cost)
         + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0)) AS net_cost
     FROM `finops-lab-001.finops_billing.gcp_billing_export_v1_012345_6789AB_CDEF01`
     WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY)
       AND cost_type = 'regular'
     GROUP BY day, sku
   ),
   agg AS (
     SELECT
       sku,
       SUM(IF(day = CURRENT_DATE() - 1, net_cost, 0)) AS yesterday,
       AVG(IF(day BETWEEN CURRENT_DATE() - 8 AND CURRENT_DATE() - 2, net_cost, NULL)) AS baseline
     FROM daily
     GROUP BY sku
   )
   SELECT
     sku,
     ROUND(yesterday, 2) AS yesterday,
     ROUND(baseline, 2) AS baseline,
     ROUND(SAFE_DIVIDE(yesterday - baseline, baseline) * 100, 1) AS delta_pct
   FROM agg
   WHERE yesterday > 5
   ORDER BY (yesterday - baseline) DESC
   LIMIT 10;
   ```

   ```
   +-------------------------------------------+-----------+----------+-----------+
   | sku                                       | yesterday | baseline | delta_pct |
   +-------------------------------------------+-----------+----------+-----------+
   | Network Inter Region Egress from Americas |    418.22 |     6.11 |    6743.9 |
   | N2 Instance Core running in Americas      |     52.40 |    49.90 |       5.0 |
   +-------------------------------------------+-----------+----------+-----------+
   ```

   Egress, no cómputo. El cómputo es ruido.

2. **¿Qué recurso?** Solo el export detallado puede responder esto:

   ```sql
   SELECT
     project.id AS project_id,
     resource.name AS resource,
     ROUND(SUM(cost), 2) AS cost
   FROM `finops-lab-001.finops_billing.gcp_billing_export_resource_v1_012345_6789AB_CDEF01`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
     AND sku.description LIKE '%Egress%'
   GROUP BY 1, 2
   ORDER BY cost DESC
   LIMIT 5;
   ```

   ```
   +------------------+---------------------------------------------------------+--------+
   | project_id       | resource                                                | cost   |
   +------------------+---------------------------------------------------------+--------+
   | legacy-datalake-01 | //storage.googleapis.com/projects/_/buckets/dl-archive | 411.90 |
   +------------------+---------------------------------------------------------+--------+
   ```

3. **¿Qué es ese recurso, y dónde está?** Las lecturas entre regiones son la causa clásica:

   ```bash
   gcloud asset search-all-resources \
     --scope="projects/legacy-datalake-01" \
     --query="name:dl-archive" \
     --format="table(displayName, assetType, location, labels)"
   ```

   ```
   DISPLAY_NAME  ASSET_TYPE                          LOCATION      LABELS
   dl-archive    storage.googleapis.com/Bucket       europe-west1  {'env': 'prod'}
   ```

   Un bucket en `europe-west1` leído desde un job en `us-central1`. El cómputo no se volvió más caro; el que se encareció fue el *camino de los datos*.

4. **¿Quién lo cambió, y cuándo?** Los audit logs de Admin Activity están habilitados por defecto y son gratuitos:

   ```bash
   gcloud logging read \
     'logName:"cloudaudit.googleapis.com%2Factivity"
      AND resource.type="gcs_bucket"
      AND protoPayload.resourceName:"dl-archive"' \
     --project=legacy-datalake-01 \
     --freshness=7d \
     --limit=5 \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName)"
   ```

   ```
   TIMESTAMP                       PRINCIPAL_EMAIL                        METHOD_NAME
   2026-09-07T21:14:02.118Z        etl-runner@legacy-datalake-01.iam...   storage.buckets.update
   2026-09-07T21:13:47.902Z        maria.ortiz@example.com                storage.buckets.setIamPolicy
   ```

5. **Cerrá el ciclo.** Toda investigación de una anomalía debería terminar agregando el control que la habría detectado antes. Acá: un budget por proyecto sobre `legacy-datalake-01` con un umbral `FORECASTED_SPEND` al 100%, y un requisito de label `cost-center` impuesto como custom constraint para que el próximo bucket así sea asignable desde el día uno.

6. Confirmá que no se pasó nada por alto silenciosamente volviendo a correr el paso 1 con una ventana de 2 días después del arreglo.

### Comprobación de comprensión

- **P32.** El paso 1 filtra `WHERE yesterday > 5`. ¿Qué clase de anomalía oculta ese filtro, y cuándo importaría?
- **P33.** El paso 2 requirió el export detallado. Describí exactamente hasta dónde podrías haber llegado solo con el export estándar, y dónde te habrías trabado.
- **P34.** El SKU de cómputo se movió 5% mientras que el de egress se movió 6.700%. Explicá en términos de costo por qué el perfil de *cómputo* del workload quedó casi sin cambios y la factura igual se cuadruplicó.
- **P35.** Ordená estos cuatro controles según qué tan temprano habría interceptado cada uno este incidente: alerta de budget, organization policy sobre ubicaciones de recursos, quota, revisión de anomalías de costo. Justificá el primer puesto.

---

## Limpieza

Ejecutá todo. Dejar este laboratorio en pie cuesta plata cada hora.

```bash
gcloud compute instances delete finops-lab-vm --zone="$ZONE" --project="$PROJECT_ID" --quiet
gcloud compute disks list --project="$PROJECT_ID" --format="value(name,zone)"   # verify no orphan disks

gcloud billing budgets delete \
  "billingAccounts/${BILLING_ACCOUNT_ID}/budgets/8f3c9a71-2b4d-4e0a-9c11-77f2b0d4e5aa" --quiet

gcloud pubsub topics delete billing-budget-alerts --project="$PROJECT_ID" --quiet

gcloud org-policies delete gcp.resourceLocations --project="$PROJECT_ID" --quiet
gcloud org-policies delete custom.allowedMachineTypes --project="$PROJECT_ID" --quiet

gcloud beta quotas preferences delete cpus-cap-us-central1 \
  --project="$PROJECT_ID" --quiet   # optional: the lowered quota is harmless to keep

# Disable the export in the Console (Billing → Billing export) BEFORE dropping the dataset,
# or the export will recreate the tables.
bq rm -r -f -d "${PROJECT_ID}:${DATASET}"
```

Confirmá que el proyecto está tranquilo:

```bash
gcloud asset search-all-resources --scope="projects/$PROJECT_ID" \
  --asset-types="compute.googleapis.com/Instance,compute.googleapis.com/Disk" \
  --format="value(name)"
```

Una salida vacía significa que no queda nada facturable en Compute Engine.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Jerarquía de recursos y vínculo de facturación

**R1.** Sí, en la práctica. El costo se mide contra el **project**, y los reportes resuelven la ruta jerárquica del proyecto en el momento de la consulta. Movés el proyecto y toda la historia lo sigue a las consolidaciones del nuevo folder — lo cual es a la vez conveniente y un riesgo de reporte, porque una comparación mes contra mes a nivel de folder puede moverse sin que haya cambiado el gasto real. El costo se registra por proyecto; el folder es un lente, no un libro contable.

**R2.** No a lo primero: un proyecto tiene exactamente una cuenta de Cloud Billing a la vez (o ninguna, en cuyo caso los servicios facturables se detienen). Sí a lo segundo: una billing account está fuera de la jerarquía de recursos y puede pagar proyectos de cualquier organización, o proyectos sin organización alguna. Por eso la billing account no es un límite de seguridad y no debe tratarse como tal.

**R3.** Una **billing subaccount** (la fila con `MASTER_ACCOUNT_ID` en el paso 1). Produce una factura separada para la unidad de negocio mientras los cargos se consolidan en la cuenta padre, así que la organización conserva intactos su contrato, sus precios negociados y sus committed use discounts. Una billing account genuinamente separada fragmentaría todo eso: contrato separado, pool de descuentos separado, cobertura de commitments separada.

**R4.** El **project number** (`739104857260`). `budgetFilter.projects` espera `projects/<PROJECT_NUMBER>`. Pasar el project ID produce un filtro que no coincide con ningún registro de uso, así que el budget se queda en $0,00 para siempre y nunca alerta. Es un fallo silencioso — el budget existe, parece configurado, y da cero cobertura.

### Ejercicio 2 — Labels

**R5.** Las **labels** son la dimensión de asignación de costos: fluyen al billing export y son agrupables en los reportes. Los **tags** (tags de resource manager) son para **políticas** — se heredan por la jerarquía, los pares clave/valor son recursos controlados por IAM, y los consumen las condiciones de IAM y la organization policy. Los tags sí aparecen en el export detallado, pero su propósito es el control de acceso condicional, no el chargeback. Regla práctica: las labels responden *quién paga*, los tags responden *qué está permitido*.

**R6.** Nada bajo esa label. Las labels **no son retroactivas**. La label aparece en los registros de facturación solo para el uso medido después de haberla aplicado, así que enero muestra el costo de esa VM como no asignado. Seis meses de gasto son irrecuperables a efectos de asignación — solo podés estimarlos a posteriori.

**R7.** (1) El costo del disco aparece como no asignado, así que el gasto reportado de `eng-platform` subestima su consumo real — un reporte de chargeback que está mal en una dirección de la que nadie se queja. (2) Cuando la VM se borra o se detiene, el disco sigue facturando; como no lleva label de dueño, nada lo vincula a un equipo y sobrevive a todas las revisiones de limpieza. Los discos huérfanos sin labels son una de las fuentes más duraderas de desperdicio persistente.

**R8.** Los proyectos son un eje de asignación **grueso e inestable**. Un solo proyecto suele alojar varios workloads (una API, un job batch, una copia de staging), así que los totales por proyecto no pueden responder "cuánto cuesta el servicio de checkout". Los proyectos además se crean y se borran por razones ajenas a la propiedad — por entorno, por PR, por migración — lo que rompe las series de tiempo. Las labels te dan una dimensión de asignación ortogonal a la jerarquía y que puede aplicarse de forma consistente en todos los proyectos que toca un equipo.

### Ejercicio 3 — Export a BigQuery

**R9.** Una sola línea de uso puede recibir **varios credits distintos a la vez** — un sustained use discount, un committed use discount, un crédito promocional, un crédito de free tier — cada uno con su propio `name`, `id`, `type` y `full_name`. Aplanarlos en un solo número destruiría la capacidad de responder "cuánto ahorraron realmente nuestros CUDs". El `amount` es negativo porque se aplica de forma aditiva a `cost`: neto = `cost + SUM(credits.amount)`. Restar en lugar de sumar es el bug más común en el SQL de facturación escrito a mano.

**R10.** Podés entregar tres semanas. El billing export **no hace backfill** — empieza a transmitir desde el momento en que se habilita. Para el período anterior podés recurrir a la Cost table y a los Reports de la Console (que retienen la historia de forma independiente) y a las facturas/CSV descargados, pero no podés llevar a BigQuery las filas granulares, unibles y anotadas con labels de esa ventana. Precisamente por eso "habilitar el billing export" es una tarea del día uno en una landing zone, antes de que haya algo sobre lo cual reportar.

**R11.** También `tax`, `adjustment` y `rounding_error`. Excluirlos hace que el reporte esté mal cada vez que estés reconciliando contra la **factura** real: una nota de crédito o un reembolso por acuerdo de nivel de servicio llega como una fila `adjustment`, y el impuesto es una línea real de la cuenta. Usá `cost_type = 'regular'` para el análisis de uso orientado a ingeniería; sacá el filtro cuando el número tenga que coincidir con finanzas.

**R12.** Están agrupando por la columna `labels` equivocada. Las `labels` de nivel superior son labels de **recurso**; las labels de proyecto viven en `project.labels`. Que todos los proyectos lleven `cost-center` no dice nada sobre si las VMs, discos y buckets individuales la llevan. El arreglo es leer `project.labels`, o — mejor — hacer `COALESCE` de la label de recurso sobre la label de proyecto para que un recurso herede el centro de costo de su proyecto cuando no tiene el suyo.

**R13.** El export estándar da granularidad de servicio/SKU/proyecto/label a bajo volumen; el detallado agrega el campo `resource` (VM, disco, bucket individuales) al precio de muchísimas más filas — a menudo un orden de magnitud — y del costo proporcionalmente mayor de almacenamiento y consulta en BigQuery. Habilitá el detallado cuando necesites atribución por recurso o drill-down de anomalías (el ejercicio 8 es imposible sin él), y controlá el costo con partition pruning y tablas agregadas programadas.

### Ejercicio 4 — Budgets

**R14.** Envió notificaciones: email a los destinatarios por defecto (Billing Account Administrators y Users) en cada cruce de umbral, más cualquier mensaje de Pub/Sub. **No** limitó, bloqueó, topeó ni detuvo una sola llamada a la API. Los budgets son un control de observabilidad. El gasto siguió hasta $4.300 exactamente igual que si no hubiera habido budget configurado. Este es el hecho de mayor rendimiento del objetivo.

**R15.** `FORECASTED_SPEND` proyecta el gasto de fin de período a partir del ritmo actual y se dispara **antes** de que la plata se haya ido, que es lo único que deja tiempo de reaccionar. `CURRENT_SPEND` al 100% es una notificación post mortem. El pronóstico es menos confiable al principio del período (pocos puntos de datos, así que un pico aislado se extrapola desmesuradamente) y para workloads genuinamente ráfagos o estacionales — un job batch que corre el día 28 hace que los días 1–5 pronostiquen bajo y el día 28 pronostique catastróficamente alto.

**R16.** Con `INCLUDE_ALL_CREDITS` el umbral se evalúa contra el costo **neto** — lo que realmente debés después de los CUDs y los créditos promocionales. Con `EXCLUDE_ALL_CREDITS` se evalúa contra el costo **bruto** a precio de lista, así que la alerta se dispara **antes** (el bruto siempre es ≥ el neto). Ninguno es universalmente correcto: el neto coincide con la factura y es el correcto para finanzas; el bruto sigue el consumo con independencia de un crédito promocional que algún día va a expirar, que es la mejor señal de alerta temprana para un trial o un proyecto financiado con créditos.

**R17.** En general no — debería tratar la ausencia de `alertThresholdExceeded` como "no se cruzó ningún umbral" y no hacer nada. Google publica en cada refresco de datos (aproximadamente cada pocas horas por budget) para que los consumidores reciban un **latido regular** que lleva el `costAmount` y el `budgetAmount` actuales. Eso te permite construir dashboards y detectar un pipeline mudo, en vez de enterarte de que algo anda mal solo cuando una alerta que quizás nunca llegue no aparece. Notá el corolario: la función kill-switch del paso 6 tiene que reverificar los números por sí misma, porque se invoca en cada refresco, no solo en el incumplimiento.

**R18.** (1) Desvincular la facturación **termina todos los recursos facturables del proyecto** — las VMs se detienen, las instancias de Cloud SQL se detienen, y los datos en recursos sin durabilidad independiente se pierden. No es una limitación, es una demolición. (2) Se dispara con datos de budget que van horas detrás del uso real, así que actúa tarde y de forma impredecible, y el disparador es una cifra de costo que puede moverse por razones ajenas a un incidente real (un crédito que expira, un cambio de precios, un registro de uso que llega tarde). Para producción, usá **quotas** para topear lo que se puede aprovisionar, organization policy para restringir lo que se puede crear, y alertas de budget para despertar a una persona que decida.

**R19.** `budgetFilter.projects` acepta solo el nombre de recurso construido a partir del **project number**. `projects/finops-lab-001` no coincide con nada, así que el gasto medido del budget es permanentemente $0,00 y nunca se cruza ningún umbral. La API acepta la cadena sin error, que es lo que la vuelve peligrosa — la mala configuración es invisible hasta que notás un budget que nunca alertó.

### Ejercicio 5 — Quotas

**R20.** Una quota actúa **antes** del gasto, en el momento de la llamada a la API, negándose a crear el recurso. Un budget actúa **después** del gasto, describiendo lo que ya pasó. La quota es preventiva y la impone el servicio; el budget es detectivo y lo impone quien lee el email.

**R21.** Una quota de **allocation** agotada devuelve un fallo de creación (`Quota 'CPUS' exceeded. Limit: 8.0 in region us-central1`) — el recurso no existe y reintentar no cambia nada hasta que liberes capacidad o subas el límite. Una quota de **rate** agotada devuelve `429 RESOURCE_EXHAUSTED` en llamadas individuales — la remediación correcta es backoff exponencial con jitter en el cliente, y recién después un aumento de quota. Tratar un 429 de quota de rate como un problema de capacidad lleva a subir un límite que nunca fue la restricción; tratar un fallo de allocation como transitorio lleva a un bucle de reintentos que nunca tiene éxito.

**R22.** La quota solicitada es un **techo del radio de daño de un error**. Un límite de 500 vCPU en tres regiones significa que un autoscaler desbocado, un bucle de Terraform malo o una service account comprometida pueden aprovisionar 1.500 vCPUs antes de que algo lo detenga — un compromiso mensual de cinco cifras creado por accidente. Subir la quota más adelante no cuesta nada, es bajo demanda y con rastro de auditoría; es el control reversible más barato disponible. Otorgá la necesidad actual más un margen razonable, y revisala cuando lo pidan.

**R23.** No hay un único techo de cómputo a nivel de organización para configurar — las quotas se aplican por proyecto y por región, así que el máximo efectivo de la organización es la **suma** de la quota de cada proyecto en cada región, que crece silenciosamente cada vez que se crea un proyecto. El control a nivel de organización, entonces, tiene que venir de otro lado: una fábrica de proyectos que aprovisione cada proyecto nuevo con quotas deliberadamente bajas, organization policy que restrinja tipos de máquina y ubicaciones, y IAM de billing que limite quién puede siquiera vincular un proyecto nuevo a la billing account.

### Ejercicio 6 — Modelos de precios

**R24.** Decidí según la **previsibilidad de la línea de base**. Los sustained use discounts son automáticos, no requieren compromiso y premian lo que sea que estés corriendo, así que son la opción por defecto correcta para workloads variables. Los committed use discounts valen la pena solo para la porción de capacidad que estés seguro de consumir durante todo el plazo de 1 o 3 años — comprometete al valle de tu curva de uso, no al pico, y dejá que el SUD/on-demand cubra la capa variable de arriba. Comprometete al promedio y vas a pagar capacidad que no usás en cada mes tranquilo.

**R25.** El cargo del commitment continúa por los 28 meses restantes de todos modos. Los CUDs se facturan por el plazo completo exista o no uso que los consuma; no son cancelables ni reembolsables a pedido. Según el tipo de commitment y los términos vigentes del programa puede haber opciones para cambiar la región o la familia de máquinas, o para transferir la cobertura dentro de la billing account, pero la obligación de base se mantiene. Este es todo el riesgo del mecanismo y la razón por la que las compras de CUD corresponden a una decisión conjunta de finanzas e ingeniería y no a un ingeniero solo.

**R26.** Negativo significa **ahorro**: `-24` son $24/mes que dejarías de gastar si aplicás la recomendación. Un recommender emite un valor **positivo** cuando la acción correcta aumenta el costo — una recomendación de rightsizing que escala una máquina *hacia arriba* porque está limitada por CPU, por ejemplo. Active Assist optimiza para el ajuste correcto del recurso, no para el gasto mínimo, así que el código que asume que toda recomendación ahorra plata va a reportar disparates.

**R27.** Correcto para Spot: (1) el trabajo es **interrumpible y reanudable** — renderizado batch, runners de CI, workers de cola sin estado, procesamiento de datos tolerante a fallos; (2) no tiene un **plazo de finalización ajustado**, así que la preemption solo demora en vez de fallar. Incorrecto para Spot: cualquier **ruta de servicio con estado o crítica en latencia** — una base de datos primaria, una API sincrónica de cara al usuario sin capacidad on-demand redundante — porque las instancias Spot pueden reclamarse con unos 30 segundos de aviso, y la capacidad puede no estar disponible en absoluto.

### Ejercicio 7 — Gobernanza

**R28.** Necesitan `roles/billing.user` sobre la **billing account** (o un binding de `roles/billing.projectManager` sobre el proyecto combinado con alguien que tenga `billing.user`). La separación es valiosa porque la propiedad de un proyecto y la autoridad para gastar son preocupaciones genuinamente distintas: permite que un equipo de plataforma reparta propiedad total de proyectos — desplegar lo que sea, gestionar IAM, correr el workload — mientras mantiene la decisión de *qué proyectos pueden cobrarle a la empresa* en un grupo chico y auditable. Sin eso, cualquiera que pueda crear un proyecto puede crear gasto ilimitado.

**R29.** Por defecto la política de la organización se hereda y la lista del folder se **intersecta** con ella, no la sustituye — para `gcp.resourceLocations`, los valores que el padre no permite no pueden ser re-permitidos por un hijo. Solo las ubicaciones presentes en **ambas** listas son utilizables. Para que la lista más amplia del folder tenga efecto, la política del folder tendría que definir `inheritFromParent: false` y ser aplicada por un principal con derechos de administrador de organization policy en ese nivel. Confirmá siempre con `--effective` en vez de leer la política que definiste.

**R30.** La **quota** fallaría donde la constraint tiene éxito: la quota cuenta vCPUs, así que 8 instancias `n2-standard-1` separadas pasan un tope de 8 vCPU mientras que una `n2-standard-8` no — pero una sola máquina cara de la clase `m2-ultramem-208` en un proyecto con una quota de CPU generosa también pasa, y la constraint de tipo de máquina la bloquea de plano sin importar la cantidad. La **custom constraint** fallaría donde la quota tiene éxito: la constraint permite `e2-*` sin límite, así que un autoscaler desbocado creando 400 instancias `e2-standard-4` permitidas pasa sin problema, mientras que la quota lo frena en seco en el techo de vCPU. Una acota el precio unitario, la otra acota la cantidad total — necesitás ambas.

**R31.** Porque los datos de costo que nadie puede ver no pueden influir en las decisiones de nadie. Los equipos que eligen el tipo de máquina, la región, la política de retención y el patrón de consulta son los únicos que pueden cambiar la factura, y no van a optimizar un número que tienen que pedir por ticket para poder leer. Un `roles/billing.viewer` amplio es la intervención más barata posible: no cuesta nada, no expone ninguna capacidad de gastar, y convierte al costo de un reporte de finanzas en una señal de ingeniería. Es el núcleo operativo de FinOps.

### Ejercicio 8 — Diagnóstico de anomalías

**R32.** Oculta la **cola larga**: cientos de SKUs chicos, cada uno por debajo de $5/día, que juntos representan un total grande y creciente, y cualquier SKU nuevo cuyo primer día es chico pero cuya trayectoria es empinada. Eso importa cuando la anomalía no es un pico único sino una deriva amplia — un cambio en toda la flota que agrega $2/día a cada uno de 300 recursos no muestra nada por encima del filtro y $600/día en la factura. Corré la consulta una segunda vez ordenada por `delta_pct` sin piso, o agregá a nivel de servicio, para ver esa clase.

**R33.** Con el export estándar podrías llegar al paso 1 completo (el SKU de egress es el valor atípico) e identificar el **proyecto** (`legacy-datalake-01`) y el conjunto de labels adjunto, porque las columnas de proyecto y labels existen en el export estándar. Te trabarías al identificar **qué bucket** — `resource.name` existe solo en el export detallado. A partir de ahí quedarías reducido a enumerar buckets candidatos a mano, cruzar métricas de Cloud Monitoring por bucket, o esperar a que el export detallado acumule datos que antes no recolectabas.

**R34.** La forma del cómputo del workload no cambió — las mismas VMs corrieron las mismas horas, de ahí el 5% de ruido. Lo que cambió fue **dónde vivían los datos respecto del cómputo**. Leer los mismos bytes desde un bucket en la misma región suele ser gratis o casi gratis; leerlos entre regiones o hacia internet se factura por gigabyte a tarifas que empequeñecen las vCPU-horas que hacen la lectura. La gravedad de los datos es una dimensión de costo de primer nivel: el precio de un byte depende del camino que recorre, y un cambio de una línea en la ubicación de un bucket puede multiplicar una factura sin tocar una sola línea del código de la aplicación.

**R35.** De más temprano a más tarde: (1) **organization policy** sobre ubicaciones de recursos — habría rehusado crear el bucket en `europe-west1` desde el vamos, así que el camino entre regiones nunca podría haber existido; (2) **quota** — topea el aprovisionamiento, pero ninguna quota gobierna los bytes de egress, así que es en gran medida irrelevante para este incidente puntual; (3) **alerta de budget** — se dispara horas después del gasto, una vez que los datos se refrescan; (4) **revisión de anomalías de costo** — un proceso humano programado, días después. La organization policy se lleva el primer puesto porque es la única de las cuatro que es **preventiva y no reactiva**: convierte el error de un incidente caro en un mensaje de error en el momento de la creación, que es el lugar más barato posible para atraparlo.

</details>

---

## Fuentes

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Cloud Billing concepts — https://cloud.google.com/billing/docs/concepts
- Billing access control (IAM roles) — https://cloud.google.com/billing/docs/how-to/billing-access
- Create, edit and manage budgets — https://cloud.google.com/billing/docs/how-to/budgets
- Programmatic budget notifications — https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
- Automated cost-control responses — https://cloud.google.com/billing/docs/how-to/notify
- Export Cloud Billing data to BigQuery — https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Standard usage cost data schema — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/standard-usage
- Detailed usage cost data schema — https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage
- Example billing export queries — https://cloud.google.com/billing/docs/how-to/bq-examples
- Creating and managing labels — https://cloud.google.com/resource-manager/docs/creating-managing-labels
- Tags overview — https://cloud.google.com/resource-manager/docs/tags/tags-overview
- Quotas overview — https://cloud.google.com/docs/quotas/overview
- View and manage quotas — https://cloud.google.com/docs/quotas/view-manage
- Sustained use discounts — https://cloud.google.com/compute/docs/sustained-use-discounts
- Committed use discounts — https://cloud.google.com/docs/cuds
- Spot VMs — https://cloud.google.com/compute/docs/instances/spot
- Recommenders (Active Assist) — https://cloud.google.com/recommender/docs/recommenders
- Cloud Catalog / pricing API — https://cloud.google.com/billing/docs/how-to/get-pricing-information-api
- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator
- Organization policy overview — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints
- Cloud Asset Inventory search — https://cloud.google.com/asset-inventory/docs/searching-resources
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit