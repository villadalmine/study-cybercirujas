# AWS Certified Cloud Practitioner (CLF-C02)
## Dominio 1, Enunciado de tarea 1.4 — Comprender los conceptos de la economía del cloud
### Ejercicios guiados — profundidad de producción

> **Contexto del peso en el examen:** este enunciado de tarea aporta **6.0** de la puntuación del dominio. El examen evalúa el reconocimiento de los conceptos (costo fijo vs. variable, estructura de costos on-premises vs. cloud, estrategias de licenciamiento, right-sizing, automatización, servicios gestionados). Estos ejercicios te llevan más allá del reconocimiento, hasta la aritmética y las APIs que un SRE realmente usa, porque los conceptos solo se vuelven duraderos una vez que viste moverse los números.
> Fuente: [AWS Certified Cloud Practitioner Exam Guide (CLF-C02)](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

## Prerrequisitos

| Requisito | Notas |
|---|---|
| Cuenta de AWS con visibilidad de facturación | Un principal de IAM con acceso de lectura a `Billing`, `ce:*`, `pricing:*`, `compute-optimizer:*`, `budgets:*`. El **usuario root debe habilitar primero el acceso de IAM a Billing** (Account settings → IAM user and role access to Billing information), o toda llamada a Cost Explorer devuelve `AccessDeniedException` sin importar tu política de IAM. |
| AWS CLI v2 | `aws --version` → `aws-cli/2.x.x`. |
| `jq` | La Price List API devuelve documentos JSON *codificados como strings*; `jq` dos veces es el idiom. |
| Región | Usá `us-east-1` para todas las consultas de precios. La Price List API y la Cost Explorer API tienen **endpoints globales alojados en `us-east-1`** (más `ap-south-1`/`eu-central-1` para Pricing) — no son servicios por región. |

### Aviso de costo y seguridad

| Ejercicio | Recursos creados | Costo aproximado |
|---|---|---|
| 1, 2, 3, 5 | ninguno — modelado y llamadas de solo lectura a la API | **$0.00** (la Price List API es gratuita) |
| 4 | ninguno si ya tenés una instancia EC2 corriendo | $0.00–$0.10 |
| 6 | 1 × `t3.micro`, 1 rol de IAM, 2 schedules de EventBridge | < $0.05 si se limpia el mismo día |
| 7 | ninguno (modelado); el despliegue opcional de RDS es opt-in | $0.00 / ~$0.50 si desplegás |
| 8 | 1 budget, 1 anomaly monitor, ~10 llamadas a Cost Explorer | ~$0.10 (ver la nota sobre el precio de la API `ce`) |

**Toda cifra en dólares impresa en este documento es una instantánea ilustrativa del precio de lista de `us-east-1` al momento de escribirlo.** AWS cambia los precios. Se te está enseñando el *método*, no los números — y el Ejercicio 2 existe precisamente para que nunca más tengas que confiar en un número impreso en un documento de capacitación.

---

## Ejercicio 1 — Construir la línea base on-premises y separar costo fijo de variable

**Objetivo:** producir el número contra el que se mide todo business case de cloud, y descubrir experimentalmente por qué "el cloud es más barato por hora" es la afirmación equivocada.

### Escenario

Tu empresa opera una plataforma de aplicaciones interna en una instalación de colocation:

- 12 × servidores de doble socket, **32 vCPU / 256 GiB cada uno** → 384 vCPU, 3.072 GiB en total
- Precio de compra **$9.200 por servidor**, depreciado en línea recta a **5 años**
- 2 racks de colocation a **$900/rack/mes**
- Consumo promedio medido **450 W por servidor**; **PUE 1.6** de la instalación; electricidad **$0.12/kWh**
- Tránsito + cross-connects: **$1.200/mes**
- Contrato de soporte de hardware: **10% del costo de capital por año**
- Licenciamiento del hipervisor: **$600/mes**
- 0.5 FTE de tiempo de ingeniería de plataforma a **$120.000/año totalmente cargado**

Doce meses de datos de vCenter muestran un **22% de utilización promedio de CPU** y un **61% de pico**.

### Pasos

1. Calculá el cargo mensual de depreciación.

   ```
   depreciation = (12 × $9,200) / (5 × 12 months)
   ```

2. Calculá la energía mensual, recordando que el PUE multiplica la carga de IT para dar la carga de la instalación:

   ```
   IT load      = 12 × 450 W = 5.4 kW
   facility kWh = 5.4 kW × 730 h × 1.6 (PUE)
   energy cost  = facility kWh × $0.12
   ```

3. Construí la tabla completa de costos mensuales. Completá vos mismo la última columna — para cada línea, preguntate: *si la carga de la aplicación cayera a cero mañana, ¿cambiaría esta factura este mes?*

   | Línea | $/mes | ¿Fijo o variable? |
   |---|---:|---|
   | Depreciación | ? | |
   | Colocation | 1.800 | |
   | Energía + refrigeración | ? | |
   | Tránsito de red | 1.200 | |
   | Soporte de hardware | ? | |
   | Licenciamiento del hipervisor | 600 | |
   | Ingeniería de plataforma (0.5 FTE) | 5.000 | |
   | **Total** | **?** | |

4. Calculá dos cifras de economía unitaria:

   ```
   cost per PROVISIONED vCPU-month = total / 384
   cost per USED vCPU-month        = cost per provisioned vCPU / 0.22
   ```

5. Calculá el porcentaje de costo fijo: `líneas fijas ÷ total`.

### Preguntas de verificación

- **Q1.1** — ¿Cuál es el costo mensual total, y qué porcentaje de él es fijo?
- **Q1.2** — ¿Por qué el costo por vCPU *usada* es aproximadamente 4.5× el costo por vCPU *aprovisionada*, y de cuál de las "seis ventajas de la computación en la nube" de AWS es esa brecha evidencia directa?
- **Q1.3** — El CFO propone recortar costos apagando 3 de los 12 servidores durante la noche. Usando tu tabla, calculá el ahorro mensual real. ¿Qué te dice el resultado sobre la elasticidad de una estructura de costos on-premises?
- **Q1.4** — En términos contables, ¿qué líneas son **CapEx** y cuáles **OpEx**? ¿De cuál de las dos consiste, enteramente, una factura de AWS?
- **Q1.5** — El refresh de hardware vence en 14 meses y requiere una decisión fresca de $110.400 *tomada hoy*, basada en un pronóstico de demanda a 5 años. Nombrá la ventaja de AWS que elimina esta decisión, y explicá en una oración qué la reemplaza.

---

## Ejercicio 2 — Dejá de confiar en tablas de precios: consultá la AWS Price List API

**Objetivo:** recuperar precios reales y actuales de forma programática, y derivar el costo de una *licencia de software* a partir de la diferencia entre dos SKUs idénticos en hardware.

### Pasos

1. Confirmá que podés alcanzar el endpoint de Pricing y ver cómo AWS modela un producto:

   ```bash
   aws pricing describe-services \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --query 'Services[0].AttributeNames' \
     --output text | tr '\t' '\n' | head -20
   ```

   Esperado (abreviado):

   ```
   volumeType
   maxIopsvolume
   instancesku
   instanceFamily
   operatingSystem
   ...
   ```

   Cada uno de esos nombres de atributo es una dimensión filtrable. Un "precio" en AWS es la intersección de *todas* ellas — que es por lo que dos ingenieros cotizando "el precio de m5.large" pueden tener ambos razón y estar en desacuerdo.

2. Recuperá el precio On-Demand de `m5.large`, Linux, tenancy compartida, `us-east-1`:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[]
            | "\(.pricePerUnit.USD)  \(.unit)  \(.description)"'
   ```

   Salida esperada:

   ```
   0.0960000000  Hrs  $0.096 per On Demand Linux m5.large Instance Hour
   ```

   > **Por qué `capacitystatus=Used`.** Omitilo y también vas a matchear las SKUs `AllocatedCapacityReservation` y `UnusedCapacityReservation` — el precio de la capacidad *reservada pero ociosa*. Olvidar este filtro es la razón individual más común por la que una herramienta de costos hecha en casa reporta el triple del precio real.

3. Ahora cambiá exactamente una dimensión — el sistema operativo — y nada más:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=operatingSystem,Value=Windows" \
       "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
       "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
       "Type=TERM_MATCH,Field=licenseModel,Value=No License required" \
       "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[] | .pricePerUnit.USD'
   ```

   Salida esperada:

   ```
   0.1880000000
   ```

4. Calculá el delta y anualizalo para una flota de 50 instancias:

   ```
   licence premium/hour     = 0.188 − 0.096
   licence premium/instance/month = premium × 730
   fleet annual licence cost = premium × 730 × 12 × 50
   ```

5. Repetí el paso 2 para `m5.xlarge` y `m6g.xlarge` (Graviton, ARM64) y calculá la diferencia porcentual.

   ```
   m5.xlarge  → 0.1920000000
   m6g.xlarge → 0.1540000000
   ```

### Preguntas de verificación

- **Q2.1** — ¿Cuál es el costo por hora, mensual por instancia y anual de flota de la licencia de Windows en el paso 4? ¿Qué significa realmente aquí el valor `No License required` de `licenseModel`, dado que claramente *sí* estás pagando una licencia?
- **Q2.2** — La `m6g.xlarge` tiene la misma cantidad de vCPU y memoria que la `m5.xlarge` a un precio menor. Calculá el ahorro porcentual. Nombrá las dos precondiciones de ingeniería que deben cumplirse antes de poder capitalizarlo.
- **Q2.3** — Tu equipo de finanzas pide "una planilla con todos nuestros precios de EC2". ¿Por qué ese pedido está mal formulado? Referí al menos tres de las dimensiones de atributos del paso 1.
- **Q2.4** — ¿Cuál de estas es una cuestión de *pricing* y cuál de *cost*: la Price List API y Cost Explorer? Enunciá la diferencia en una oración.

---

## Ejercicio 3 — Matemática de los compromisos: derivar la utilización de break-even

**Objetivo:** reemplazar "las Reserved Instances ahorran hasta un 72%" por una fórmula que podés aplicar a cualquier workload en diez segundos.

### Pasos

1. Recuperá una oferta real de Reserved Instance en lugar de leer una página de marketing:

   ```bash
   aws ec2 describe-reserved-instances-offerings \
     --region us-east-1 \
     --instance-type m5.large \
     --product-description "Linux/UNIX" \
     --offering-class standard \
     --offering-type "No Upfront" \
     --instance-tenancy default \
     --filters Name=duration,Values=31536000 \
     --query 'ReservedInstancesOfferings[0].{Fixed:FixedPrice,Recurring:RecurringCharges[0].Amount,Duration:Duration,Class:OfferingClass}' \
     --output table
   ```

   Forma esperada:

   ```
   ------------------------------------------------------
   |          DescribeReservedInstancesOfferings        |
   +-----------+------------+------------+--------------+
   |  Class    |  Duration  |  Fixed     |  Recurring   |
   +-----------+------------+------------+--------------+
   |  standard |  31536000  |  0.0       |  0.06        |
   +-----------+------------+------------+--------------+
   ```

2. Recuperá las tarifas de Savings Plans para la misma instancia:

   ```bash
   aws savingsplans describe-savings-plans-offering-rates \
     --service-codes AmazonEC2 \
     --products EC2 \
     --filters \
       name=region,values=us-east-1 \
       name=instanceType,values=m5.large \
       name=tenancy,values=shared \
       name=productDescription,values=Linux/UNIX \
     --query 'searchResults[].{Rate:rate,Plan:savingsPlanOffering.planType,Pay:savingsPlanOffering.paymentOption,Secs:savingsPlanOffering.durationSeconds}' \
     --output table
   ```

3. Verificá el mercado Spot actual para la misma forma:

   ```bash
   aws ec2 describe-spot-price-history \
     --region us-east-1 \
     --instance-types m5.large \
     --product-descriptions "Linux/UNIX" \
     --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --query 'SpotPriceHistory[].{AZ:AvailabilityZone,Price:SpotPrice}' \
     --output table
   ```

   Ilustrativo:

   ```
   ---------------------------------
   |    DescribeSpotPriceHistory   |
   +--------------+----------------+
   |      AZ      |     Price      |
   +--------------+----------------+
   |  us-east-1a  |  0.035500      |
   |  us-east-1b  |  0.036100      |
   |  us-east-1d  |  0.034800      |
   +--------------+----------------+
   ```

4. Armá la tabla comparativa (instantánea ilustrativa — la tuya va a diferir):

   | Opción de compra | $/hr efectivo | Obligación | Costo de 1 año, 24×7 |
   |---|---:|---|---:|
   | On-Demand | 0.0960 | ninguna | $840.96 |
   | Standard RI, 1 año, No Upfront | 0.0600 | 8.760 h facturadas igual | $525.60 |
   | Standard RI, 3 años, All Upfront | 0.0385 | pagado el día 1 | $337.26/año |
   | Compute Savings Plan, 3 años, All Upfront | 0.0326 | $/hr de *gasto*, 3 años | $285.58/año |
   | EC2 Instance Savings Plan, 3 años, All Upfront | 0.0269 | $/hr, familia + región bloqueadas | $235.64/año |
   | Spot | ~0.0355 | interrumpible, aviso de 2 min | $310.98 (si nunca se interrumpe) |

5. Derivá el break-even. Un compromiso se factura por **cada hora de su plazo, la uses o no**; On-Demand se factura solo por las horas consumidas. Por lo tanto:

   ```
   break-even utilization = committed hourly rate ÷ On-Demand hourly rate
   ```

   Calculalo para cada fila comprometida, y después convertilo a horas por semana (`× 168`).

6. Aplicalo. Clasificá cada workload — ¿comprometer, o quedarse en On-Demand?

   | Workload | Horas de ejecución | Veredicto |
   |---|---|---|
   | API de producción, siempre encendida | 168 h/sem (100%) | ? |
   | Workstations de desarrollo, horario laboral | 60 h/sem (35.7%) | ? |
   | ETL batch nocturno, 3 h × 7 | 21 h/sem (12.5%) | ? |
   | Flota de builds de CI, a ráfagas, tolerante a fallos | ~40 h/sem, impredecible | ? |

### Preguntas de verificación

- **Q3.1** — Calculá la utilización de break-even para las cuatro opciones comprometidas del paso 4, en porcentaje y en horas por semana.
- **Q3.2** — Completá la tabla del paso 6 con una opción de compra recomendada y una justificación de una línea para cada una.
- **Q3.3** — Un compromiso de Savings Plan se expresa en **dólares por hora de gasto**, no en instancias. ¿Qué pasa en una hora en la que tu uso real cae *por debajo* del compromiso? ¿Y qué pasa con el uso *por encima* de él?
- **Q3.4** — Tu equipo planea migrar de `m5` a Graviton `m6g` en seis meses. Estás por comprar un **EC2 Instance Savings Plan** a 3 años para la familia `m5` en `us-east-1` porque es el descuento más profundo disponible. ¿Qué está mal con este plan, y qué instrumento de compromiso lo arregla a costa de unos pocos puntos de descuento?
- **Q3.5** — Ni los Savings Plans ni las Reserved Instances regionales garantizan que haya capacidad disponible cuando llames a `RunInstances`. ¿Qué dos mecanismos *sí* reservan capacidad, y cuál es la consecuencia de facturación de cada uno?
- **Q3.6** — Enunciá el orden correcto de las cuatro acciones de optimización de costos: *comprometer*, *right-size*, *eliminar desperdicio*, *modernizar a servicios gestionados*. Justificá la posición de *comprometer* en una oración.

---

## Ejercicio 4 — Right-sizing desde la evidencia, no desde la opinión

**Objetivo:** convertir telemetría de utilización en una decisión defendible de tipo de instancia, y aprender el modo de falla que hace del right-sizing ingenuo un generador de caídas.

### Pasos

1. Elegí una instancia en ejecución y capturá 14 días de CPU:

   ```bash
   INSTANCE_ID=i-0123456789abcdef0

   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --start-time "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 3600 \
     --statistics Average Maximum \
     --query 'sort_by(Datapoints,&Maximum)[-3:].{T:Timestamp,Avg:Average,Max:Maximum}' \
     --output table
   ```

2. Los promedios esconden picos y los máximos sobrerreaccionan a ellos. Obtené el p99, que es el estadístico contra el que realmente deberías dimensionar:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --start-time "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 86400 \
     --extended-statistics p99 \
     --query 'sort_by(Datapoints,&Timestamp)[].{Day:Timestamp,P99:ExtendedStatistics.p99}' \
     --output table
   ```

   Ilustrativo:

   ```
   -------------------------------------------------
   |             GetMetricStatistics                |
   +------------------------------+-----------------+
   |             Day              |      P99        |
   +------------------------------+-----------------+
   |  2026-08-20T00:00:00+00:00   |  9.8            |
   |  2026-08-21T00:00:00+00:00   |  11.2           |
   |  2026-08-22T00:00:00+00:00   |  10.4           |
   +------------------------------+-----------------+
   ```

3. Preguntale a AWS. Optá por Compute Optimizer (capa gratuita de recomendaciones, sin cargo) y leé su hallazgo:

   ```bash
   aws compute-optimizer update-enrollment-status --status Active

   aws compute-optimizer get-ec2-instance-recommendations \
     --filters name=Finding,values=Overprovisioned \
     --query 'instanceRecommendations[].{
        Name:instanceName,
        Current:currentInstanceType,
        Finding:finding,
        Recommended:recommendationOptions[0].instanceType,
        Risk:recommendationOptions[0].performanceRisk,
        MonthlySaving:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
     --output table
   ```

   Ilustrativo:

   ```
   ----------------------------------------------------------------------------------------
   |                        GetEC2InstanceRecommendations                                  |
   +-----------+-------------+----------------+----------------+-------+------------------+
   |   Name    |   Current   |    Finding     |  Recommended   | Risk  |  MonthlySaving   |
   +-----------+-------------+----------------+----------------+-------+------------------+
   |  app-01   | m5.4xlarge  | Overprovisioned|  m5.xlarge     |  1.0  |  420.48          |
   |  app-02   | m5.4xlarge  | Overprovisioned|  m5.xlarge     |  1.0  |  420.48          |
   +-----------+-------------+----------------+----------------+-------+------------------+
   ```

   > **Nota sobre la inscripción:** Compute Optimizer necesita al menos **30 horas** de datos de CloudWatch y puede tardar hasta 12 horas tras el opt-in en producir sus primeras recomendaciones. Un array vacío en una cuenta nueva es el resultado esperado, no un error.

4. Verificá vos mismo la aritmética contra los precios del Ejercicio 2:

   ```
   m5.4xlarge = $0.768/hr      m5.xlarge = $0.192/hr
   saving     = (0.768 − 0.192) × 730
   ```

5. Ahora encontrá la trampa. Consultá la métrica de memoria:

   ```bash
   aws cloudwatch list-metrics \
     --namespace AWS/EC2 \
     --dimensions Name=InstanceId,Value=$INSTANCE_ID \
     --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort
   ```

   Esperado:

   ```
   CPUUtilization
   DiskReadBytes
   DiskReadOps
   DiskWriteBytes
   DiskWriteOps
   NetworkIn
   NetworkOut
   NetworkPacketsIn
   NetworkPacketsOut
   ```

6. Verificá también el desperdicio que no requiere ninguna decisión de dimensionamiento — volúmenes EBS sin adjuntar y Elastic IPs ociosas:

   ```bash
   aws ec2 describe-volumes \
     --filters Name=status,Values=available \
     --query 'Volumes[].{Id:VolumeId,GiB:Size,Type:VolumeType,Created:CreateTime}' \
     --output table

   aws ec2 describe-addresses \
     --query 'Addresses[?AssociationId==`null`].{IP:PublicIp,Alloc:AllocationId}' \
     --output table
   ```

### Preguntas de verificación

- **Q4.1** — Confirmá la cifra de $420.48/mes del paso 4. Para una flota de 6 instancias idénticas, ¿cuál es el ahorro anual?
- **Q4.2** — La salida del paso 5 no contiene una métrica de memoria. ¿Por qué no, qué tenés que instalar para obtener una, y qué incidente de producción específico invita hacer right-sizing solo sobre CPU?
- **Q4.3** — `performanceRisk: 1.0` en una escala donde más bajo es más seguro. ¿Qué *no* sabe Compute Optimizer sobre tu workload que este número no puede capturar? Dá dos ejemplos.
- **Q4.4** — Estas 6 instancias ya están cubiertas por un EC2 Instance Savings Plan a 3 años dimensionado para la flota de `m5.4xlarge`. Les hacés right-sizing a `m5.xlarge`. ¿Cuánto ahorrás realmente este mes? Reformulá la regla que esto demuestra.
- **Q4.5** — Cada volumen EBS sin adjuntar del paso 6 es de 500 GiB `gp3`. A $0.08/GiB-mes, ¿cuánto cuesta uno por año? ¿Por qué esta categoría de desperdicio es estrictamente mejor de atacar que el right-sizing?
- **Q4.6** — Desde el 1 de febrero de 2024, toda dirección IPv4 pública se cobra a $0.005/hora **esté adjunta o no**. Calculá el costo mensual de una dirección, y de 40 olvidadas.

---

## Ejercicio 5 — Estrategias de licenciamiento: Included, BYOL, y dónde se esconde la plata

**Objetivo:** determinar, para un producto de software comercial dado, si AWS te está vendiendo la licencia o alquilándote el hardware para correr la tuya.

### Pasos

1. Establecé los dos modelos inspeccionando qué te vende AWS para RDS. Consultá la disponibilidad de motores:

   ```bash
   aws rds describe-orderable-db-instance-options \
     --engine oracle-ee \
     --db-instance-class db.m5.large \
     --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZCapable}' \
     --output table

   aws rds describe-orderable-db-instance-options \
     --engine sqlserver-se \
     --db-instance-class db.m5.large \
     --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZCapable}' \
     --output table
   ```

2. Compará las dos posturas de licenciamiento contra la documentación oficial:

   | Motor | License Included | Bring Your Own License |
   |---|---|---|
   | RDS for Oracle | sí (solo SE2) | **sí** — vos tenés la licencia de Oracle, AWS factura solo la infraestructura |
   | RDS for SQL Server | **sí — y solo esto** | no |
   | RDS for MySQL / PostgreSQL / MariaDB | n/a — open source | n/a |

   Fuentes: [RDS Oracle licensing](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Oracle.Concepts.licensing.html), [RDS for SQL Server](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_SQLServer.html)

3. Cuantificá el lado de EC2. Ya derivaste el sobreprecio de la licencia de Windows en el Ejercicio 2. Ahora poné precio a la alternativa BYOL — un Dedicated Host, que se factura por *host*, no por instancia:

   ```bash
   aws ec2 describe-host-reservation-offerings \
     --filter Name=instance-family,Values=m5 \
     --query 'OfferingSet[?PaymentOption==`NoUpfront` && Duration==`31536000`].{
        Family:InstanceFamily,Hourly:HourlyPrice,Upfront:UpfrontPrice,Payment:PaymentOption}' \
     --output table
   ```

4. Construí el modelo de decisión para **50 instancias Windows Server de `m5.large`**:

   ```
   Option A — License Included, shared tenancy:
     50 × $0.188/hr × 730

   Option B — BYOL on Dedicated Hosts:
     50 × $0.096/hr equivalent capacity  +  host charges  +  your existing licence cost
   ```

   Un Dedicated Host `m5` provee 96 vCPUs (48 núcleos físicos). Cincuenta `m5.large` necesitan 100 vCPU → **2 hosts**.

5. Llevá el registro de las titularidades para que BYOL no se convierta en un hallazgo de auditoría. Creá una configuración de License Manager con un límite duro:

   ```bash
   aws license-manager create-license-configuration \
     --name "windows-server-datacenter-cores" \
     --description "Windows Server DC core entitlements under Software Assurance" \
     --license-counting-type Core \
     --license-count 192 \
     --license-count-hard-limit \
     --license-rules "#minimumCores=4,#maximumCores=96"

   aws license-manager list-license-configurations \
     --query 'LicenseConfigurations[].{Name:Name,Type:LicenseCountingType,Limit:LicenseCount,Consumed:ConsumedLicenses}' \
     --output table
   ```

   Esperado:

   ```
   -------------------------------------------------------------------------
   |                     ListLicenseConfigurations                          |
   +--------------------------------------+-------+---------+--------------+
   |                 Name                 | Type  |  Limit  |  Consumed    |
   +--------------------------------------+-------+---------+--------------+
   |  windows-server-datacenter-cores     | Core  |  192    |  0           |
   +--------------------------------------+-------+---------+--------------+
   ```

### Preguntas de verificación

- **Q5.1** — Calculá la Opción A y la Opción B del paso 4, usando $4.608/hr como tarifa On-Demand ilustrativa del Dedicated Host `m5`. ¿A qué costo anual de tus propias licencias de Windows se igualan las dos opciones?
- **Q5.2** — Un equipo quiere migrar una base de datos SQL Server Enterprise Edition a RDS usando licencias que ya posee. Explicá con precisión por qué esto no es posible, y dá los dos servicios de AWS que *sí* soportan ese requisito.
- **Q5.3** — BYOL en tenancy compartida para productos de Microsoft comprados después del 1 de octubre de 2019 generalmente no está permitido bajo los términos de licenciamiento de Microsoft. ¿Cuál es la consecuencia del lado de AWS para tu arquitectura, y qué te cuesta en términos de economía del cloud? (Pensá en las dos cosas que la tenancy compartida te da y un Dedicated Host no.)
- **Q5.4** — `--license-count-hard-limit` hace que AWS *bloquee* lanzamientos de instancias que excederían el conteo de titularidades. Nombrá un escenario de producción donde este flag previene una violación de cumplimiento, y uno donde causa una caída.
- **Q5.5** — ¿Qué estrategia de licenciamiento tiene costo de licencia cero, exposición de auditoría cero y restricción de tenancy cero — y por qué no aparece en la tabla del paso 2?

---

## Ejercicio 6 — La automatización como control de costos: programar capacidad no productiva

**Objetivo:** implementar infraestructura como código que elimina costo sin eliminar capacidad, y medir por qué el ahorro realizado siempre es menor que el ahorro de cómputo.

### Pasos

1. Creá la plantilla. Guardala como `office-hours-scheduler.yaml`:

   ```yaml
   AWSTemplateFormatVersion: '2010-09-09'
   Description: >-
     Cost-avoidance scheduler for non-production EC2 instances. Stops the listed
     instances on weekday evenings and starts them on weekday mornings using
     EventBridge Scheduler universal targets. No Lambda function is required.

   Parameters:
     InstanceIds:
       Type: List<AWS::EC2::Instance::Id>
       Description: Non-production instances to place on an office-hours schedule.
     ScheduleTimezone:
       Type: String
       Default: America/Argentina/Buenos_Aires
       Description: IANA timezone name. Handles DST automatically.
     StartExpression:
       Type: String
       Default: cron(0 8 ? * MON-FRI *)
     StopExpression:
       Type: String
       Default: cron(0 20 ? * MON-FRI *)

   Resources:

     SchedulerRole:
       Type: AWS::IAM::Role
       Properties:
         Description: Assumed by EventBridge Scheduler to start and stop tagged instances.
         AssumeRolePolicyDocument:
           Version: '2012-10-17'
           Statement:
             - Effect: Allow
               Principal:
                 Service: scheduler.amazonaws.com
               Action: sts:AssumeRole
               Condition:
                 StringEquals:
                   aws:SourceAccount: !Ref 'AWS::AccountId'
         Policies:
           - PolicyName: StartStopScheduledInstances
             PolicyDocument:
               Version: '2012-10-17'
               Statement:
                 - Effect: Allow
                   Action:
                     - ec2:StartInstances
                     - ec2:StopInstances
                   Resource: !Sub 'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:instance/*'
                   Condition:
                     StringEquals:
                       'aws:ResourceTag/Schedule': office-hours

     StopSchedule:
       Type: AWS::Scheduler::Schedule
       Properties:
         Name: !Sub '${AWS::StackName}-stop'
         Description: Stop non-production instances at the end of the working day.
         State: ENABLED
         ScheduleExpression: !Ref StopExpression
         ScheduleExpressionTimezone: !Ref ScheduleTimezone
         FlexibleTimeWindow:
           Mode: 'OFF'
         Target:
           Arn: 'arn:aws:scheduler:::aws-sdk:ec2:stopInstances'
           RoleArn: !GetAtt SchedulerRole.Arn
           RetryPolicy:
             MaximumRetryAttempts: 3
             MaximumEventAgeInSeconds: 3600
           Input: !Sub
             - '{"InstanceIds": ["${Ids}"]}'
             - Ids: !Join ['","', !Ref InstanceIds]

     StartSchedule:
       Type: AWS::Scheduler::Schedule
       Properties:
         Name: !Sub '${AWS::StackName}-start'
         Description: Start non-production instances at the beginning of the working day.
         State: ENABLED
         ScheduleExpression: !Ref StartExpression
         ScheduleExpressionTimezone: !Ref ScheduleTimezone
         FlexibleTimeWindow:
           Mode: 'OFF'
         Target:
           Arn: 'arn:aws:scheduler:::aws-sdk:ec2:startInstances'
           RoleArn: !GetAtt SchedulerRole.Arn
           RetryPolicy:
             MaximumRetryAttempts: 3
             MaximumEventAgeInSeconds: 3600
           Input: !Sub
             - '{"InstanceIds": ["${Ids}"]}'
             - Ids: !Join ['","', !Ref InstanceIds]

   Outputs:
     StopScheduleArn:
       Description: ARN of the evening stop schedule.
       Value: !GetAtt StopSchedule.Arn
     StartScheduleArn:
       Description: ARN of the morning start schedule.
       Value: !GetAtt StartSchedule.Arn
     RunningHoursPerWeek:
       Description: Billable compute hours per instance per week under this schedule.
       Value: '60'
   ```

2. Etiquetá tus instancias objetivo para que la condición de IAM matchee. Las instancias sin etiquetar van a aparecer listadas en el input del schedule pero la llamada a la API va a ser denegada — deliberadamente:

   ```bash
   aws ec2 create-tags \
     --resources i-0123456789abcdef0 i-0fedcba9876543210 \
     --tags Key=Schedule,Value=office-hours Key=Environment,Value=nonprod
   ```

3. Desplegá. Usá un archivo de parámetros — un parámetro `List<...>` pasado inline mediante `--parameter-overrides` requiere comas escapadas con barra invertida y se parsea mal en silencio si te equivocás:

   ```bash
   cat > params.json <<'JSON'
   [
     {
       "ParameterKey": "InstanceIds",
       "ParameterValue": "i-0123456789abcdef0,i-0fedcba9876543210"
     }
   ]
   JSON

   aws cloudformation create-stack \
     --stack-name nonprod-office-hours \
     --template-body file://office-hours-scheduler.yaml \
     --parameters file://params.json \
     --capabilities CAPABILITY_IAM

   aws cloudformation wait stack-create-complete --stack-name nonprod-office-hours
   ```

4. Verificá:

   ```bash
   aws scheduler list-schedules \
     --query 'Schedules[?starts_with(Name, `nonprod-office-hours`)].{Name:Name,State:State,Target:Target.Arn}' \
     --output table

   aws scheduler get-schedule --name nonprod-office-hours-stop \
     --query '{Expr:ScheduleExpression,TZ:ScheduleExpressionTimezone,Input:Target.Input}'
   ```

   Esperado:

   ```json
   {
       "Expr": "cron(0 20 ? * MON-FRI *)",
       "TZ": "America/Argentina/Buenos_Aires",
       "Input": "{\"InstanceIds\": [\"i-0123456789abcdef0\",\"i-0fedcba9876543210\"]}"
   }
   ```

5. Modelá el ahorro para una flota de **10 × instancias de desarrollo `t3.large`**, cada una con un volumen raíz de **100 GiB `gp3`** y una dirección IPv4 pública auto-asignada.

   ```
   Prices: t3.large $0.0832/hr · gp3 $0.08/GiB-month · public IPv4 $0.005/hr

   BEFORE (24×7 = 730 h/month):
     compute = 10 × 0.0832 × 730
     storage = 10 × 100 × 0.08
     IPv4    = 10 × 0.005 × 730

   AFTER (60 h/week ≈ 260 h/month):
     compute = 10 × 0.0832 × 260
     storage = unchanged
     IPv4    = 10 × 0.005 × 260
   ```

6. Calculá tanto el **% de ahorro de cómputo** como el **% de ahorro de la factura total**, y notá la diferencia.

### Preguntas de verificación

- **Q6.1** — Calculá los totales antes y después del paso 5, y ambos porcentajes de ahorro.
- **Q6.2** — ¿Por qué el ahorro total es menor que el ahorro de cómputo? ¿Qué línea es responsable, y qué principio general sobre las instancias EC2 detenidas ilustra?
- **Q6.3** — En el paso 5 las instancias usan direcciones IPv4 públicas auto-asignadas, así que el cargo de IPv4 se detiene cuando la instancia se detiene. ¿Qué cambia si en su lugar adjuntás direcciones **Elastic IP**, y por qué?
- **Q6.4** — La etiqueta `Schedule=office-hours` aparece en *dos* lugares con dos trabajos distintos. Nombrá ambos, y explicá qué pasa si un ingeniero le quita la etiqueta a una instancia.
- **Q6.5** — ¿Qué concepto de costo de la guía del examen demuestra este ejercicio, y cómo interactúa con el concepto del Ejercicio 1?
- **Q6.6** — El universal target requiere una lista explícita de IDs de instancia horneada dentro del schedule. ¿Qué problema operativo crea eso a medida que la flota de desarrollo crece, y cuál es una alternativa impulsada por etiquetas?

---

## Ejercicio 7 — Servicios gestionados: poner precio al trabajo que dejás de hacer

**Objetivo:** comparar la operación de bases de datos autogestionada y gestionada sobre costo **totalmente cargado**, y ver por qué la línea más barata es la elección más cara.

### Pasos

1. Recuperá el precio gestionado:

   ```bash
   aws pricing get-products \
     --region us-east-1 \
     --service-code AmazonRDS \
     --filters \
       "Type=TERM_MATCH,Field=instanceType,Value=db.m5.large" \
       "Type=TERM_MATCH,Field=regionCode,Value=us-east-1" \
       "Type=TERM_MATCH,Field=databaseEngine,Value=MySQL" \
       "Type=TERM_MATCH,Field=deploymentOption,Value=Multi-AZ" \
     --output json \
   | jq -r '.PriceList[]' \
   | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)  \(.description)"'
   ```

   Esperado:

   ```
   0.3420000000  $0.342 per RDS db.m5.large Multi-AZ instance hour (or partial hour) running MySQL
   ```

2. Construí la **Opción A — MySQL autogestionado sobre EC2**, primario más una réplica configurada manualmente:

   | Línea | Cálculo | $/mes |
   |---|---|---:|
   | Cómputo EC2 | 2 × $0.096 × 730 | 140.16 |
   | EBS `gp3` | 1.000 GiB × $0.08 | 80.00 |
   | IOPS aprovisionadas por encima de las 3.000 gratis | 3.000 × $0.005 | 15.00 |
   | Backups a S3 Standard | 1.500 GiB × $0.023 | 34.50 |
   | **Subtotal de infraestructura** | | **269.66** |
   | Ingeniería: parcheo, verificación de backups, simulacros de failover, monitoreo de replicación | 6 h/mes × $85/h cargado | 510.00 |
   | **Total** | | **?** |

3. Construí la **Opción B — RDS MySQL Multi-AZ**:

   | Línea | Cálculo | $/mes |
   |---|---|---:|
   | Instancia de base de datos Multi-AZ | $0.342 × 730 | 249.66 |
   | Almacenamiento, Multi-AZ (facturado en ambas AZ) | 500 GiB × $0.23 | 115.00 |
   | Almacenamiento de backups automatizados ≤ 100% de lo aprovisionado | incluido | 0.00 |
   | **Subtotal de infraestructura** | | **364.66** |
   | Ingeniería: revisar Performance Insights, aprobar la ventana de mantenimiento | 1 h/mes × $85/h | 85.00 |
   | **Total** | | **?** |

4. Compará sobre dos ejes: solo infraestructura, y totalmente cargado.

5. Extendé el razonamiento a servicios gestionados con precio por consumo, donde la unidad de facturación no es en absoluto una hora-instancia:

   ```
   Aurora Serverless v2  $0.12 per ACU-hour        (capacity scales in 0.5-ACU steps)
   AWS Lambda            $0.20 per 1M requests + $0.0000166667 per GB-second
   AWS Fargate           $0.04048 per vCPU-hour + $0.004445 per GB-hour
   Amazon S3 Standard    $0.023 per GB-month
   ```

   Calculá cuánto cuesta una función Lambda facturada a 512 MB que se ejecuta 2.000.000 de veces por mes durante 300 ms:

   ```
   requests = (2,000,000 / 1,000,000) × 0.20
   GB-sec   = 2,000,000 × 0.300 s × 0.5 GB
   compute  = GB-sec × 0.0000166667
   ```

6. Compará eso contra la instancia siempre encendida más chica que podría hospedar la misma función: `t3.micro` a $0.0104/hr × 730.

### Preguntas de verificación

- **Q7.1** — Completá los totales de los pasos 2 y 3. Enunciá la diferencia porcentual solo sobre infraestructura, y sobre costo totalmente cargado. Explicá el cambio de signo.
- **Q7.2** — ¿Qué principio de diseño de Cost Optimization del Well-Architected mide este ejercicio? Enuncialo, y nombrá la categoría de trabajo por la que te dice que dejes de pagar.
- **Q7.3** — Calculá el costo de Lambda del paso 5 y el costo de `t3.micro` del paso 6. ¿Con qué cantidad mensual de invocaciones se igualan, manteniendo constantes los 300 ms y los 512 MB?
- **Q7.4** — La estimación de ingeniería de 6 h/mes de la Opción A excluye por completo una categoría de costo: el costo esperado de la caída que ocurre cuando un failover manual sale mal a las 03:00. ¿Por qué esa omisión sesga toda comparación entre autogestionado y gestionado en la misma dirección?
- **Q7.5** — Los servicios gestionados reducen el costo operativo pero te restringen. Nombrá dos capacidades concretas que resignás al pasar de MySQL-sobre-EC2 a RDS, y explicá por qué sigue siendo usualmente el trade correcto.
- **Q7.6** — Un Compute Savings Plan cubre uso de EC2, Fargate **y** Lambda. ¿Por qué eso cambia materialmente el cálculo de una migración de EC2 a serverless, comparado con un EC2 Instance Savings Plan?

---

## Ejercicio 8 — Gobernanza: atribuir, presupuestar y detectar

**Objetivo:** hacer del costo una propiedad consultable de tu arquitectura en lugar de una sorpresa mensual.

> **Meta-lección, y no es un chiste:** la API de Cost Explorer cuesta **$0.01 por request**. Un dashboard ingenuo que hace polling de `GetCostAndUsage` cada 60 segundos sobre 20 cuentas cuesta unos **$8.640/mes** para decirte cuánto estás gastando. Medir el costo no es gratis; presupuestá tu propia observabilidad.

### Pasos

1. Imponé un estándar de etiquetado en el punto de creación. Adjuntá esta política a tu rol de despliegue de CI/CD — un lanzamiento sin etiquetas es rechazado:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyRunInstancesWithoutCostAllocationTags",
         "Effect": "Deny",
         "Action": "ec2:RunInstances",
         "Resource": "arn:aws:ec2:*:*:instance/*",
         "Condition": {
           "Null": {
             "aws:RequestTag/CostCenter": "true"
           }
         }
       },
       {
         "Sid": "RequireKnownEnvironmentValues",
         "Effect": "Deny",
         "Action": "ec2:RunInstances",
         "Resource": "arn:aws:ec2:*:*:instance/*",
         "Condition": {
           "StringNotEquals": {
             "aws:RequestTag/Environment": ["prod", "staging", "dev", "sandbox"]
           }
         }
       }
     ]
   }
   ```

2. Activá las etiquetas para facturación. **Una etiqueta no aparece en Cost Explorer hasta que se activa como cost allocation tag, y la activación no es retroactiva** — los datos anteriores a la activación quedan sin etiquetar para siempre:

   ```bash
   aws ce list-cost-allocation-tags --status Inactive \
     --query 'CostAllocationTags[].{Key:TagKey,Type:Type,Status:Status}' --output table

   aws ce update-cost-allocation-tags-status \
     --cost-allocation-tags-status \
        TagKey=CostCenter,Status=Active \
        TagKey=Environment,Status=Active
   ```

3. Consultá el gasto del mes pasado, agrupado por servicio:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --output json \
   | jq -r '.ResultsByTime[0].Groups[]
            | [.Keys[0], (.Metrics.UnblendedCost.Amount|tonumber|.*100|round/100)]
            | @tsv' \
   | sort -k2 -gr | head -10
   ```

   Ilustrativo:

   ```
   Amazon Elastic Compute Cloud - Compute	3184.22
   Amazon Relational Database Service	1102.87
   Amazon Simple Storage Service	 412.55
   AmazonCloudWatch	 188.03
   EC2 - Other	 176.41
   ```

4. Volvé a consultar agrupando por tu etiqueta, y notá qué cae dentro de `No CostCenter$`:

   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=2026-08-01,End=2026-09-01 \
     --granularity MONTHLY \
     --metrics UnblendedCost \
     --group-by Type=TAG,Key=CostCenter \
     --output table
   ```

5. Creá un budget basado en pronóstico. Los budgets son la única barrera casi gratuita: **los primeros dos budgets por cuenta son gratis; cada budget adicional cuesta $0.02/día.**

   ```bash
   cat > budget.json <<'JSON'
   {
     "BudgetName": "monthly-account-ceiling",
     "BudgetLimit": { "Amount": "5000", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST",
     "CostTypes": {
       "IncludeTax": true,
       "IncludeSubscription": true,
       "IncludeRefund": false,
       "IncludeCredit": false,
       "UseAmortized": false,
       "UseBlended": false
     }
   }
   JSON

   cat > notifications.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "FORECASTED",
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
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 100,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "finops@example.com" }
       ]
     }
   ]
   JSON

   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file://budget.json \
     --notifications-with-subscribers file://notifications.json

   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount,Forecast:CalculatedSpend.ForecastedSpend.Amount}' \
     --output table
   ```

6. Agregá detección de anomalías, que no necesita umbral porque aprende tu línea base:

   ```bash
   aws ce create-anomaly-monitor \
     --anomaly-monitor '{
       "MonitorName": "all-services-monitor",
       "MonitorType": "DIMENSIONAL",
       "MonitorDimension": "SERVICE"
     }'
   ```

7. Pedile a Cost Explorer su propia vista de right-sizing y reconciliala contra Compute Optimizer del Ejercicio 4:

   ```bash
   aws ce get-rightsizing-recommendation \
     --service AmazonEC2 \
     --configuration 'RecommendationTarget=SAME_INSTANCE_FAMILY,BenefitsConsidered=true' \
     --query 'Summary.{Total:TotalRecommendationCount,Savings:EstimatedTotalMonthlySavingsAmount}' \
     --output table
   ```

### Preguntas de verificación

- **Q8.1** — El paso 2 advierte que la activación de cost allocation tags no es retroactiva. ¿Cuál es la consecuencia operativa si activás `CostCenter` en septiembre para recursos etiquetados desde marzo?
- **Q8.2** — El budget del paso 5 usa una notificación `FORECASTED` y una `ACTUAL`. ¿Qué te da cada una, y por qué un budget con solo notificaciones `ACTUAL` es casi inútil?
- **Q8.3** — Una notificación de budget no detiene nada. Nombrá el mecanismo que convierte un budget en un control de cumplimiento, y dá una razón para tener cuidado con él en una cuenta de producción.
- **Q8.4** — `BenefitsConsidered=true` en el paso 7 cambia los ahorros reportados. ¿Qué contempla, y cómo se relaciona con Q4.4?
- **Q8.5** — `UseAmortized` vs `UseBlended` vs costo unblended. Un equipo compró en enero una RI All Upfront a 3 años de $12.000. ¿Bajo cuál de las tres muestra enero $12.000, y cuál es la correcta para juzgar la eficiencia mensual de un equipo?
- **Q8.6** — La política de IAM del paso 1 deniega `RunInstances` sin etiquetas. Listá dos formas en que el costo todavía puede entrar a la cuenta completamente sin etiquetar a pesar de esta política.

---

## Capstone — la única diapositiva

Combiná los Ejercicios 1, 3, 4, 6 y 7 en el business case de migración para la plataforma del Ejercicio 1. Completá cada celda con tu propio trabajo.

| | On-premises (hoy) | Lift-and-shift, On-Demand | Cloud optimizado |
|---|---:|---:|---:|
| Cómputo | | | |
| Almacenamiento | | | |
| Red / transferencia de datos de salida (2 TB/mes) | | | |
| Licenciamiento | | | |
| Instalaciones, energía, soporte de hardware | | 0 | 0 |
| Mano de obra de operaciones | | | |
| **Total mensual** | | | |
| Porción fija del costo | | | |
| Costo por vCPU *usada*-mes | | | |

Supuestos para la columna del medio: right-size 1:1 a las formas de VM existentes → 37 × `m5.2xlarge` a $0.384/hr, 200 GiB `gp3` cada una, todo On-Demand, 24×7.

Supuestos para la columna derecha: dimensionar al pico medido + 25% de headroom; 60% de la flota en un Compute Savings Plan a 3 años con 66% de descuento; el 40% restante On-Demand y corriendo ~30% de las horas; el mismo almacenamiento; 2 TB/mes de egress ($0.09/GB después de los primeros 100 GB gratis); AWS Business Support.

### Preguntas de verificación

- **QC.1** — Completá las tres columnas. ¿Qué única columna prueba que "mudarse al cloud" y "ahorrar plata" son eventos independientes?
- **QC.2** — La columna de lift-and-shift queda solo marginalmente por debajo de la columna on-premises. ¿Cuáles son las dos razones estructurales, y qué le dirías a un ejecutivo que concluye de esto que la migración no vale la pena?
- **QC.3** — Listá las cuatro palancas que separan la columna del medio de la de la derecha, y atribuí cada una a su concepto del enunciado de tarea 1.4.
- **QC.4** — Recitá las seis ventajas de la computación en la nube y mapeá cada fila de tu capstone a una de ellas.
- **QC.5** — Nombrá la única línea de costo que la migración **no** elimina y que puede aumentar, y explicá por qué es la línea que más a menudo hunde un business case de migración.

---

## Limpieza

Ejecutá esto cuando termines, o los ejercicios dejan de ser gratuitos.

```bash
# Exercise 6
aws cloudformation delete-stack --stack-name nonprod-office-hours
aws cloudformation wait stack-delete-complete --stack-name nonprod-office-hours

# Exercise 5
aws license-manager delete-license-configuration \
  --license-configuration-arn "$(aws license-manager list-license-configurations \
      --query 'LicenseConfigurations[?Name==`windows-server-datacenter-cores`].LicenseConfigurationArn' \
      --output text)"

# Exercise 8
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name monthly-account-ceiling
aws ce delete-anomaly-monitor --monitor-arn "$(aws ce get-anomaly-monitors \
    --query 'AnomalyMonitors[?MonitorName==`all-services-monitor`].MonitorArn' --output text)"

# Verify nothing is left running
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Launched:LaunchTime}' \
  --output table
```

La inscripción en Compute Optimizer (`update-enrollment-status --status Active`) no genera cargo por las recomendaciones estándar y puede dejarse activa. Solo las **enhanced infrastructure metrics** son facturables.

---

<details>
<summary><strong>Respuestas</strong> — trabajá los ejercicios antes de abrir</summary>

### Ejercicio 1

**Q1.1**

```
Depreciation      = (12 × 9,200) / 60          = $1,840.00
Colocation        = 2 × 900                    = $1,800.00
Power + cooling   = 5.4 kW × 730 h × 1.6 × 0.12 = $  756.86  ( 6,307.2 kWh )
Network transit                                 = $1,200.00
Hardware support  = (110,400 × 0.10) / 12      = $  920.00
Hypervisor licensing                            = $  600.00
Platform engineering = 120,000 × 0.5 / 12      = $5,000.00
                                        TOTAL  = $12,116.86  ≈ $12,117/month
Annual = $145,402
```

Solo la **energía y la refrigeración** varía con la carga, y solo parcialmente — los servidores en reposo consumen aproximadamente el 40–60% del consumo pico, así que la porción verdaderamente variable es todavía menor. Fijo = 12.117 − 757 = $11.360 = **93.8%**. Número redondo para recordar: **~94% de una factura on-premises es fija.**

**Q1.2**

```
per provisioned vCPU = 12,116.86 / 384 = $31.55
per used vCPU        = 31.55 / 0.22    = $143.43   (4.55×)
```

Compraste 384 vCPU y estás usando 84.5 de ellas. Las otras 299.5 están siendo depreciadas, alimentadas, refrigeradas, aseguradas, parcheadas y soportadas a precio completo para no hacer nada. La brecha de 4.55× es el costo de *aprovisionar para un pronóstico* en lugar de *pagar por consumo*. Es evidencia directa de **"Stop guessing capacity"** — y, como esa capacidad ociosa se compró con un cheque a cinco años, también de **"Trade capital expense for variable expense"**.

**Q1.3**

Apagar 3 de 12 servidores ahorra solo la electricidad: `3 × 0.45 kW × 730 h × 1.6 × 0.12 = $189.22`, y solo por las horas en que están apagados. Solo de noche, eso es aproximadamente **$60–90/mes contra una factura de $12.117 — alrededor del 0.6%.** Los servidores igual se deprecian, igual ocupan unidades de rack que pagás, igual cargan contratos de soporte y licencias de hipervisor.

La lección: **on-premises, reducir el uso no reduce el costo.** La capacidad se compra por adelantado y en unidades indivisibles. La elasticidad no es una funcionalidad que puedas agregarle a una estructura de costos que es 94% fija — solo la obtenés cambiando el modelo de propiedad.

**Q1.4**

- **CapEx:** la compra de servidores por $110.400 (que aparece como depreciación en el estado de resultados, pero el efectivo salió del negocio el día uno).
- **OpEx:** colocation, energía, tránsito, contrato de soporte, licenciamiento del hipervisor, salarios.

Una factura de AWS es **100% OpEx**. No hay compra de capital, ni cronograma de depreciación, ni activo en el balance, ni disposición. Ese es el contenido contable de la frase "trade capital expense for variable expense" — y es por lo que el gasto en cloud necesita una gobernanza financiera distinta a la de una compra de hardware: nadie lo aprueba una sola vez, así que debe gobernarse continuamente (Ejercicio 8).

**Q1.5**

La ventaja es **"Stop guessing capacity."** Lo que reemplaza al pronóstico a cinco años es una decisión de aprovisionamiento *diaria* que es reversible en minutos. El contenido económico es que el costo de equivocarse colapsa: adivinar mal on-premises significa o bien 14 meses de capacidad insuficiente o $110.400 de activos ociosos, mientras que adivinar mal en AWS significa una instancia sobredimensionada hasta la próxima revisión de right-sizing (Ejercicio 4).

---

### Ejercicio 2

**Q2.1**

```
premium/hour            = 0.188 − 0.096            = $0.092
premium/instance/month  = 0.092 × 730              = $67.16
fleet annual (50)       = 0.092 × 730 × 12 × 50    = $40,296
```

`licenseModel: No License required` significa que **vos** no estás obligado a aportar una licencia — AWS ya la compró y la incrustó en la tarifa horaria. Es el modelo "License Included". El valor describe tu obligación, no la ausencia de un costo; el costo son los $40.296 que acabás de calcular. Este es el atributo más malinterpretado de la Price List API.

**Q2.2**

```
(0.192 − 0.154) / 0.192 = 19.8% ≈ 20%
```

Precondiciones:
1. **Todo tu stack de runtime debe tener builds ARM64 (`aarch64`)** — imagen base, runtime del lenguaje, cada extensión nativa, cada agente, cada sidecar. Un único binario solo-x86 en el árbol de dependencias bloquea la migración.
2. **Tu pipeline de build y despliegue debe producir artefactos ARM64**, en la práctica imágenes de contenedor multiarquitectura, y tu CI debe tener runners ARM64 o emulación.

El precio es un hecho; el ahorro es un proyecto de ingeniería. Esa distinción es la economía del cloud entera.

**Q2.3**

No existe tal cosa como "nuestro precio de EC2" para un tipo de instancia. Un precio es la intersección de al menos: `instanceType`, `regionCode`, `operatingSystem`, `tenancy` (Shared / Dedicated / Host), `preInstalledSw` (NA / SQL Std / SQL Ent / SQL Web), `capacitystatus` (Used / UnusedCapacityReservation / AllocatedCapacityReservation), `licenseModel`, y el **término** (On-Demand vs. cada permutación de Reserved por clase, duración y opción de pago). Un solo tipo de instancia en una sola región tiene cientos de precios legítimos. El entregable correcto para finanzas no es una lista de precios sino **un informe de costo real de Cost Explorer o del Cost and Usage Report** (Q2.4).

**Q2.4**

- **Price List API = pricing.** Lo que un recurso *costaría*. Prospectivo, hipotético, idéntico para cada cliente, gratuito de consultar.
- **Cost Explorer = cost.** Lo que *realmente gastaste*. Retrospectivo, específico de la cuenta, incluye tus descuentos, créditos, cobertura de RI/SP, impuestos y reembolsos.

En una oración: **el pricing es un catálogo público; el cost es tu factura.** Planificás con el primero y gobernás con el segundo, y confundirlos es cómo se escribe un business case contra el precio de lista para una flota que está 80% cubierta por Savings Plans.

---

### Ejercicio 3

**Q3.1**

`break-even utilization = committed rate ÷ On-Demand rate`, y `hours/week = utilization × 168`.

| Opción | Tarifa | Break-even | h/semana |
|---|---:|---:|---:|
| Std RI, 1 año, No Upfront | 0.0600 | 0.0600/0.096 = **62.5%** | 105 |
| Std RI, 3 años, All Upfront | 0.0385 | **40.1%** | 67 |
| Compute SP, 3 años, All Upfront | 0.0326 | **34.0%** | 57 |
| EC2 Instance SP, 3 años, All Upfront | 0.0269 | **28.0%** | 47 |

Notá la dirección: **un descuento más profundo baja el break-even.** Un compromiso a 3 años no es "más riesgoso" en términos de utilización — tolera *más* ociosidad antes de perder plata. El riesgo en un compromiso a 3 años es arquitectónico (¿vas a seguir corriendo esta forma en 2029?), no de utilización.

**Q3.2**

| Workload | Horas | Recomendación |
|---|---|---|
| API de producción, 168 h/sem | 100% | **Savings Plan a 3 años.** Muy por encima de todos los break-even; la única pregunta es Compute SP vs. EC2 Instance SP, es decir flexibilidad vs. ~6 puntos de descuento. |
| Workstations de desarrollo, 60 h/sem | 35.7% | **Compute SP a 3 años (break-even de 57 h/sem) — marginalmente.** Pero aplicá primero el Ejercicio 6: la programación cambia el número contra el que se mide el compromiso. No te comprometas a capacidad que estás por eliminar con scheduling. Una RI a 1 año con break-even de 105 h/sem **perdería plata**. |
| ETL nocturno, 21 h/sem | 12.5% | **On-Demand, o Spot si tiene checkpoints.** Por debajo de todos los break-even. Mejor aún, este es un workload de Lambda/Fargate/Batch — pagás por segundo, no por hora. |
| Flota de builds de CI, a ráfagas | ~24% | **Spot**, vía EC2 Auto Scaling o Fargate Spot. Los builds son idempotentes y re-ejecutables, que es exactamente el perfil de workload para el que Spot fue diseñado — hasta 90% de descuento a cambio de un aviso de interrupción de 2 minutos. |

**Q3.3**

- **Por debajo del compromiso:** la porción no usada de esa hora se **pierde**. Los compromisos de Savings Plans no se acumulan, no se guardan ni se trasladan. Una hora en la que te comprometés a $10/hr y usás $6/hr cuesta $10.
- **Por encima del compromiso:** el exceso se factura a **tarifas On-Demand estándar**. No hay penalidad ni tope — el sobre-compromiso es el error caro, el sub-compromiso simplemente deja descuento sobre la mesa.

Esta asimetría es por lo que la práctica estándar es **comprometerse al valle, no al promedio**: cubrí la línea base que está demostrablemente siempre corriendo, y dejá que el pico flote en On-Demand o pase a Spot.

**Q3.4**

Un **EC2 Instance Savings Plan está bloqueado a una familia de instancias en una región** (`m5` en `us-east-1`). Migrar a `m6g` mueve tu uso fuera del alcance del compromiso: pagarías el precio On-Demand completo por la flota Graviton **y** seguirías pagando el compromiso de `m5` durante los 2.5 años restantes sin uso al que aplicarlo. Estarías pagando dos veces, y el "ahorro" de Graviton quedaría completamente varado.

La solución es un **Compute Savings Plan**. Se aplica automáticamente a través de familia de instancia, tamaño, región, SO, tenancy — y además cubre **Fargate y Lambda**. Descuenta unos pocos puntos porcentuales menos (hasta 66% vs. hasta 72%) y esa diferencia es la prima que pagás por la opcionalidad. Cuando la arquitectura está en movimiento, comprá el Compute SP. Bloqueate a un EC2 Instance SP solo para una flota de la que estés seguro que no va a cambiar de forma durante todo el plazo.

**Q3.5**

Ni los Savings Plans ni las RIs **regionales** reservan capacidad — son constructos puramente de facturación. Los dos que sí reservan capacidad:

1. **Zonal Reserved Instances** — alcanzadas a una Availability Zone específica, proveyendo una reserva de capacidad en esa AZ. Trade-off: sin flexibilidad de AZ, y sin flexibilidad de tamaño de instancia dentro de la familia.
2. **On-Demand Capacity Reservations (ODCR)** — reservan capacidad en una AZ sin compromiso de plazo, creadas y canceladas en cualquier momento. **Consecuencia de facturación: pagás la tarifa On-Demand por la capacidad reservada desde el momento en que se crea, esté o no ocupada por una instancia.** Una ODCR puede *combinarse* con un Savings Plan o una RI regional para que la capacidad reservada se facture a la tarifa descontada.

La distinción importa durante un evento a gran escala — un failover regional, un scale-out de Black Friday — cuando la capacidad On-Demand para un tipo de instancia popular en una AZ popular puede genuinamente agotarse, y un Savings Plan no te va a ayudar.

**Q3.6**

1. **Eliminar desperdicio** — volúmenes sin adjuntar, load balancers ociosos, NAT gateways olvidados, snapshots huérfanos, Elastic IPs sin asociar. Riesgo cero, efecto inmediato, y hacerlo no cuesta nada.
2. **Right-size** — hacer coincidir la forma de la instancia con la demanda medida.
3. **Modernizar a servicios gestionados / serverless** — sacar la instancia de la ecuación por completo donde no está agregando valor.
4. **Comprometer** — comprar Savings Plans o RIs contra la flota que sobrevive a los pasos 1–3.

Comprometer va último porque **un compromiso congela tu arquitectura actual dentro de tu factura por uno a tres años.** Si te comprometés primero, prepagaste tu desperdicio con descuento, y cada optimización posterior deja varada parte del compromiso (Q4.4). La regla de una línea: **optimizá la arquitectura, después comprometete a lo que queda.**

---

### Ejercicio 4

**Q4.1**

```
(0.768 − 0.192) × 730 = 0.576 × 730 = $420.48 / instance / month
6 instances:  $2,522.88 / month  →  $30,274.56 / year
```

**Q4.2**

Las métricas de EC2 se recolectan desde el **hipervisor**, que ve CPU, I/O de disco y red de la instancia pero no tiene visibilidad dentro del sistema operativo huésped. La utilización de memoria, el espacio libre del filesystem, la actividad de swap y los datos por proceso son hechos a nivel del huésped. Para recolectarlos tenés que instalar el **agente de CloudWatch** dentro de la instancia y publicar métricas personalizadas (`mem_used_percent`, `disk_used_percent`).

El incidente que esto invita: una JVM, una caché en memoria, un nodo de Elasticsearch o una base de datos van a mostrar **5% de CPU y 90% de memoria**. Hacerle right-sizing de `m5.4xlarge` (64 GiB) a `m5.xlarge` (16 GiB) solo con evidencia de CPU recorta la memoria en un 75% y el proceso hace OOM en el próximo pico de tráfico — típicamente en producción, típicamente después de que el cambio fue declarado un éxito. **La CPU es la métrica que podés ver; la memoria es usualmente la métrica que limita.** Instalá el agente antes de hacerle right-sizing a workloads con estado.

**Q4.3**

Compute Optimizer ve métricas de recursos. No puede ver:

1. **Headroom mantenido deliberadamente para un evento futuro conocido** — un batch de cierre de trimestre, una ventana de inscripción anual, una campaña de marketing, un standby de disaster recovery dimensionado para absorber el tráfico de otra región. Para un motor de métricas, un warm standby es 100% desperdicio.
2. **Restricciones de licenciamiento o soporte atadas a la forma** — una licencia de proveedor cotizada por núcleo físico, una aplicación certificada solo sobre una familia de instancias específica, un workload que requiere un piso específico de ancho de banda de red o EBS que el tipo recomendado no alcanza con el mismo perfil de rendimiento.

También invisible: comportamiento de ráfaga más fino que el período de la métrica (un pico de CPU de 20 segundos es invisible con granularidad de 5 minutos), y cualquier dependencia de NVMe local presente en el tipo actual y ausente en la recomendación. Tratá la salida de Compute Optimizer como una **lista priorizada de hipótesis para testear**, nunca como un cambio para aplicar automáticamente.

**Q4.4**

**No ahorrás prácticamente nada este mes.** El Savings Plan es un compromiso de gastar una cantidad fija de dólares por hora durante tres años. Reducir el uso por debajo de ese compromiso no reduce el pago — el compromiso no usado se pierde hora a hora (Q3.3). Hiciste las instancias más chicas y la factura quedó igual.

Si es un SP de **Compute**, el compromiso liberado al menos va a derivar a cubrir otro uso elegible en otro lado de la cuenta (otras regiones, otras familias, Fargate, Lambda) — recuperás valor solo en la medida en que ese uso exista. Si es un **EC2 Instance** SP bloqueado a `m5` en `us-east-1`, solo puede reaplicarse a otro uso de `m5` en esa región.

La regla, reformulada: **hacé right-size antes de comprometerte. Un compromiso comprado sobre una flota no optimizada bloquea tu desperdicio con descuento.** Este es el error de secuenciación más común y más caro en la gestión de costos de cloud.

**Q4.5**

```
500 GiB × $0.08/GiB-month = $40.00/month = $480.00/year, per volume
```

Esta categoría es estrictamente mejor de atacar porque es **desperdicio puro con riesgo de rendimiento cero**. Un volumen sin adjuntar no sirve a ningún workload, no tiene dueño monitoreándolo, y borrarlo (después de un snapshot, si la procedencia no está clara) no puede causar una caída. El right-sizing siempre carga una hipótesis de rendimiento que podría ser errónea; borrar un volumen `available` no carga ninguna. Agotá siempre la categoría de riesgo cero antes de gastar criterio de ingeniería en la riesgosa — por eso "eliminar desperdicio" precede a "right-size" en Q3.6.

**Q4.6**

```
1 address  = 0.005 × 730       = $3.65 / month  = $43.80 / year
40 addresses = 3.65 × 40       = $146.00 / month = $1,752.00 / year
```

Este cargo, introducido el 1 de febrero de 2024, aplica a **toda** dirección IPv4 pública en la cuenta: adjunta a instancias en ejecución, adjunta a NAT gateways y load balancers, y Elastic IPs ociosas. Convirtió una línea que antes era gratuita-cuando-adjunta en un costo de toda la flota, y es una fuente común del crecimiento de la línea "EC2 - Other" sin ningún cambio de instancias. Es también el argumento financiero más fuerte a favor de IPv6 y de poner workloads en subredes privadas detrás de una ruta de egreso compartida.

Referencia: [New AWS public IPv4 address charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)

---

### Ejercicio 5

**Q5.1**

```
Option A — License Included, shared tenancy:
  50 × 0.188 × 730                       = $6,862.00 / month

Option B — BYOL on Dedicated Hosts:
  2 hosts × $4.608/hr × 730              = $6,727.68 / month
  plus your own Windows Server licences  = $L
                                   total = $6,727.68 + L
```

Break-even: `6,862.00 − 6,727.68 = $134.32/mes`, es decir **$1.611,84/año**. Si tus titularidades existentes de Windows Server Datacenter para esos 2 hosts (96 núcleos físicos) cuestan menos de aproximadamente $134/mes de mantener, BYOL gana en el papel; por encima de eso, gana License Included.

En la práctica esto está lo bastante ajustado como para que lo decidan los factores *no relacionados con el precio*: BYOL fuerza tenancy de Dedicated Host, lo que significa que gestionás vos mismo la capacidad y el placement del host, perdés la capacidad de lanzar cualquier tamaño de instancia bajo demanda, y tenés que demostrar cumplimiento de titularidades en una auditoría. License Included no tiene ninguna de esas obligaciones. **La razón para elegir BYOL casi nunca son los $134 — es que las licencias ya son costo hundido y no pueden revenderse.** Ese es un argumento de recuperación de CapEx, no de economía del cloud.

**Q5.2**

**RDS for SQL Server es solo License Included.** AWS discontinuó BYOL para RDS SQL Server; no existe configuración en la que aportes tu propia licencia de SQL Server a una instancia RDS. El costo de la licencia está incrustado en la tarifa horaria de RDS y no podés restarlo.

Los dos servicios de AWS que sí soportan BYOL para SQL Server:

1. **Amazon EC2 con Dedicated Hosts** (o Dedicated Instances), donde instalás y licenciás SQL Server vos mismo, con seguimiento en **AWS License Manager**.
2. **Amazon RDS Custom for SQL Server**, que te da acceso a nivel de SO y de base de datos sobre una instancia gestionada por RDS y soporta modelos de bring-your-own-media/licencia.

**Q5.3**

El cambio de octubre de 2019 de Microsoft a sus términos de Outsourcing significa que las licencias compradas después del 2019-10-01 sin derechos de hosting dedicado no pueden desplegarse sobre infraestructura de tenancy compartida en AWS. Arquitectónicamente, quedás forzado a **Dedicated Hosts o Dedicated Instances**.

El costo en economía del cloud es que resignás las dos propiedades que hacen al cómputo cloud económicamente distinto de un rack de servidores:

1. **Elasticidad granular.** Ahora comprás capacidad en unidades de un *host físico completo*, no de una instancia. Escalar de 50 a 51 instancias puede requerir un segundo host — volviste al problema del Ejercicio 1 de comprar capacidad en unidades indivisibles y sobredimensionadas.
2. **Facturación por segundo sobre un pool compartido.** Un Dedicated Host factura de forma continua tanto si corre una instancia como cuarenta; el riesgo de utilización vuelve a caer sobre vos.

En otras palabras, BYOL sobre tenancy dedicada reimporta parcialmente la estructura de costos on-premises — fija, en bloques grandes, sensible a la utilización — dentro de AWS. Ese es el precio real de la licencia, y no aparece en ninguna lista de precios.

**Q5.4**

- **Previene una violación:** un Auto Scaling group con un `MaxSize` mal configurado escala una flota de Windows de 40 a 400 instancias durante un pico de tráfico. Sin el límite duro desplegaste 360 instancias sin licencia y creaste una exposición de auditoría de siete cifras descubierta meses después. Con él, los lanzamientos se rechazan y recibís una alerta.
- **Causa una caída:** ese mismo Auto Scaling group escala legítimamente durante un pico genuino, alcanza el techo de titularidades, y `RunInstances` es denegado. La capacidad no llega, el servicio se degrada, y el modo de falla parece un problema de capacidad en lugar de uno de licenciamiento — lo que lo hace lento de diagnosticar a las 03:00.

La mitigación es correr License Manager en modo de **límite blando** con una alarma de CloudWatch sobre `ConsumedLicenses` acercándose a la titularidad, para que te avisen con margen para comprar licencias en lugar de bloquearte en el límite. Reservá el límite duro para entornos donde una violación de cumplimiento genuinamente cuesta más que una caída.

**Q5.5**

**El software open source** — MySQL, PostgreSQL, MariaDB, Linux, Aurora compatible con PostgreSQL. Costo de licencia cero, ninguna titularidad que rastrear, ninguna restricción de tenancy, y Compute Optimizer/Graviton/Spot siguen todos disponibles porque nada está atado a un conteo de núcleos físicos.

No aparece en la tabla porque **no hay decisión de licenciamiento que tomar** — que es precisamente el punto. En la tabla del paso 2, las filas de MySQL/PostgreSQL/MariaDB dicen "n/a". Cada hora gastada en el análisis de Opción A/Opción B de Q5.1, cada restricción de Dedicated Host de Q5.3, y cada trade-off de riesgo de auditoría de Q5.4 es un costo que la fila de open source simplemente no incurre. Cuando el motor de un workload es genuinamente negociable, **la elección del motor es una palanca de costo mayor que cualquier decisión de opción de compra del Ejercicio 3** — y a diferencia de un Savings Plan, compone porque además elimina las restricciones sobre todas las demás palancas.

---

### Ejercicio 6

**Q6.1**

```
BEFORE (730 h/month)
  compute = 10 × 0.0832 × 730  = $607.36
  storage = 10 × 100 × 0.08    = $ 80.00
  IPv4    = 10 × 0.005 × 730   = $ 36.50
  TOTAL                        = $723.86

AFTER (60 h/week ≈ 260 h/month)
  compute = 10 × 0.0832 × 260  = $216.32
  storage = 10 × 100 × 0.08    = $ 80.00   (unchanged)
  IPv4    = 10 × 0.005 × 260   = $ 13.00
  TOTAL                        = $309.32

compute saving = (607.36 − 216.32) / 607.36 = 64.4%
total   saving = (723.86 − 309.32) / 723.86 = 57.3%
```

Chequeo de sanidad sobre las horas: 60 horas de ejecución de 168 en una semana es 35.7%, así que evitás el 64.3% de las horas de cómputo. El porcentaje de cómputo coincide exactamente con el schedule, como debe ser.

**Q6.2**

**El almacenamiento EBS es el responsable.** El principio general: **una instancia EC2 detenida deja de acumular cargos de cómputo inmediatamente, pero sus volúmenes EBS se siguen facturando por completo.** El almacenamiento es capacidad aprovisionada, no capacidad consumida — los bloques siguen asignados a vos, siguen siendo durables, siguen replicados dentro de la AZ, esté o no corriendo algo encima de ellos.

El principio se generaliza más allá de EBS. Toda arquitectura tiene un **piso fijo** — almacenamiento, snapshots, NAT gateways ($0.045/hr cada uno, ~$32.85/mes, fluya o no un byte), horas de load balancer, hosted zones de Route 53, claves de KMS, compromisos reservados. El scheduling y el autoscaling atacan la capa *variable* por encima de ese piso. Así que el ahorro combinado siempre es estrictamente menor que el ahorro de cómputo, y a medida que optimizás cómputo el piso fijo crece como porcentaje de la factura hasta que *él* se convierte en lo que vale la pena atacar. Acá, el almacenamiento pasó del 11% de la factura al 26%.

Este es el Ejercicio 1 en miniatura y al revés: convertiste una estructura de costos mayormente fija en mayormente variable, y lo que sigue siendo fijo es ahora el problema visible.

**Q6.3**

Una **Elastic IP permanece asociada a la instancia mientras está detenida** — esa es la razón entera para usar una, ya que la dirección debe sobrevivir al ciclo de stop/start. Como la dirección está asignada a vos de forma continua, se **factura continuamente a $0.005/hora**, 730 h/mes, sin importar el estado de la instancia. Además, una EIP no asociada a una instancia *en ejecución* históricamente ha cargado un cargo por dirección ociosa.

Recalculá:
```
IPv4 with EIPs = 10 × 0.005 × 730 = $36.50   (unchanged from BEFORE)
AFTER total    = 216.32 + 80.00 + 36.50 = $332.82
total saving   = (723.86 − 332.82) / 723.86 = 54.0%   (down from 57.3%)
```

Aproximadamente $23,50/mes, o $282/año, es el precio de un direccionamiento estable sin DNS sobre una flota que está apagada dos tercios del tiempo. El arreglo arquitectónico es dejar de necesitar una dirección pública estable: poné las instancias en subredes privadas y alcanzalas a través de **Systems Manager Session Manager**, que no necesita IP pública, ni EIP, ni bastion host, ni regla de entrada en el security group. Eso elimina una línea de costo y una superficie de ataque en el mismo cambio.

**Q6.4**

1. **En el bloque `Condition` de la política de IAM** (`aws:ResourceTag/Schedule`), donde *autoriza* la acción. Este es el límite de seguridad — es lo que impide que el rol del scheduler pueda detener producción.
2. **Como marcador operativo de intención**, indicándoles a los humanos y a cualquier herramienta impulsada por etiquetas qué instancias están bajo el régimen de horario de oficina.

Si un ingeniero le quita la etiqueta a una instancia, el ID de la instancia sigue presente en el payload `Input` del schedule, así que EventBridge Scheduler igual llama a `StopInstances` para ella — pero IAM **deniega** la llamada. Como `StopInstances` es una API por lotes, la denegación hace fallar el request para la instancia afectada; según cómo se evalúe el lote, podés obtener una falla parcial o total de esa invocación.

La parte operativamente importante: **esta falla es silenciosa por defecto.** El schedule dispara, el target da error, la política de reintentos agota tres intentos, y nadie se entera. Adjuntá siempre una **dead-letter queue** de EventBridge Scheduler (`Target.DeadLetterConfig`) y alarmá sobre su profundidad, o tu control de costos deja de funcionar en silencio y lo descubrís en la factura del mes siguiente.

**Q6.5**

**La automatización (infraestructura como código)**, listada explícitamente en el enunciado de tarea 1.4. La plantilla está versionada, es revisable, reproducible entre cuentas, y borrar el stack elimina el control limpiamente — nada de lo cual es cierto de un job programado que alguien configuró en la consola.

La interacción con el Ejercicio 1 es el sentido entero del par. On-premises, esta automatización no habría ahorrado prácticamente nada (Q1.3: ~0.6%), porque apagar un servidor no lo des-compra. En AWS el cambio operativo idéntico rinde **57%**, porque la estructura de costos es variable. **La automatización no es lo que ahorra la plata — es lo que convierte una estructura de costos variable en un ahorro realizado.** La elasticidad es la precondición; la automatización es el mecanismo. Ninguna funciona sin la otra: elasticidad sin automatización solo significa que nadie se acuerda de apagar las cosas.

**Q6.6**

El problema: **la lista de instancias es estática y vive dentro del schedule.** Cada nueva instancia de desarrollo requiere una actualización de CloudFormation para quedar cubierta, y cada instancia terminada deja un ID obsoleto en el payload que va a hacer errar la llamada a la API. En una flota con cualquier rotación, la cobertura decae en silencio — las instancias nuevas quedan corriendo 24×7 por defecto, que es exactamente la población más propensa a ser olvidada. El control parece sano mientras cubre una fracción decreciente de la flota.

Alternativas impulsadas por etiquetas, en orden creciente de capacidad:

- **Systems Manager Automation** con un runbook `AWS-StopEC2Instance` impulsado por un **Resource Group** construido a partir de una consulta de etiquetas, invocado por EventBridge Scheduler. La membresía se evalúa en tiempo de ejecución, así que las nuevas instancias etiquetadas quedan cubiertas automáticamente.
- **Una pequeña función Lambda** que llame a `DescribeInstances` con `Filters=[{Name:'tag:Schedule',Values:['office-hours']}]` y pase el resultado a `StopInstances`, paginando correctamente. Más código, control total, fácil de agregar overrides por instancia (`Schedule=always-on`).
- **La solución AWS Instance Scheduler**, una solución de CloudFormation mantenida que soporta múltiples schedules con nombre, operación entre cuentas y entre regiones, y overrides por instancia vía valores de etiqueta.

Elijas la que elijas, la regla de diseño es la misma: **el control debe descubrir sus objetivos a partir de etiquetas en tiempo de ejecución, no de una lista capturada en tiempo de despliegue.** Un control de costos que requiere que un humano se acuerde de extenderlo es un control de costos que va a estar equivocado dentro de un trimestre.

---

### Ejercicio 7

**Q7.1**

```
Option A — self-managed MySQL on EC2
  infrastructure                     = $  269.66
  engineering  6 h × $85             = $  510.00
  TOTAL                              = $  779.66

Option B — RDS MySQL Multi-AZ
  infrastructure                     = $  364.66
  engineering  1 h × $85             = $   85.00
  TOTAL                              = $  449.66

Infrastructure only: RDS is 35.2% MORE expensive  (364.66 / 269.66 = 1.352)
Fully loaded:        RDS is 42.3% LESS expensive  (330.00 / 779.66)
                     annual difference = $3,960
```

El cambio de signo viene del hecho de que la factura de AWS contiene solo una de las dos categorías de costo. La infraestructura está medida, itemizada, y aterriza en Cost Explorer; **el tiempo de ingeniería es plata real que nunca aparece en la factura.** Comparar la línea de RDS contra la línea de EC2 compara dos tercios de una opción contra un tercio de la otra. El precio del servicio gestionado incluye trabajo que la opción autogestionada meramente reubica en una línea de nómina — donde es invisible para la revisión de costos, y donde compite con el trabajo de producto.

Notá también lo que las 5 horas/mes de tiempo de ingeniería recuperado *valen* en lugar de lo que *cuestan*: esas horas van a trabajo de producto, así que la cifra real es más alta que $510.

**Q7.2**

**"Stop spending money on undifferentiated heavy lifting"** — uno de los cinco principios de diseño del pilar de Cost Optimization del AWS Well-Architected Framework.

La categoría es **el trabajo operativo que es necesario pero por el que ningún cliente te va a pagar más**: parcheo del SO y de la base de datos, scripting de backups y — la parte que todos olvidan — la *verificación de restauración* de backups, monitoreo de lag de replicación, runbooks y simulacros de failover, upgrades de versión menor, gestión del crecimiento del almacenamiento, recolección de métricas a nivel de host. Toda organización que corre MySQL hace esto de forma idéntica. Nada de eso diferencia tu producto. El enunciado de tarea 1.4 lista servicios gestionados (RDS, ECS, EKS, DynamoDB) precisamente porque elegirlos es una decisión de costo, no meramente operativa.

Referencia: [Cost Optimization pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)

**Q7.3**

```
Lambda
  requests = (2,000,000 / 1,000,000) × 0.20              = $ 0.40
  GB-sec   = 2,000,000 × 0.300 × 0.5                     = 300,000 GB-s
  compute  = 300,000 × 0.0000166667                      = $ 5.00
  TOTAL                                                  = $ 5.40 / month

t3.micro always-on
  0.0104 × 730                                           = $ 7.59 / month
```

Break-even, despejando las invocaciones `n` a 300 ms / 512 MB:

```
cost(n) = n × (0.20/1e6)  +  n × 0.15 GB-s × 0.0000166667
        = n × (0.0000002 + 0.0000025)
        = n × 0.0000027
7.59 = n × 0.0000027  →  n ≈ 2,811,000 invocations / month
```

Así que **alrededor de 2,8 millones de invocaciones por mes**, aproximadamente 1,08 por segundo sostenidas. Por debajo de eso, Lambda es más barato; por encima, la instancia lo es.

Tres salvedades que importan más que la aritmética. Primero, la comparación no es equivalente: los $7,59 te compran una instancia en una AZ sin redundancia, sin autoscaling, sin parcheo y sin capacidad para una ráfaga, mientras que los $5,40 te compran concurrencia gestionada entre AZs. Hacer el lado de EC2 genuinamente equivalente a producción significa al menos dos instancias detrás de un load balancer (sumá ~$16–22/mes por un ALB), lo que empuja el break-even mucho más arriba. Segundo, la capa gratuita de AWS para Lambda (1M de requests y 400.000 GB-segundos por mes) es perpetua, no de 12 meses. Tercero, los Compute Savings Plans cubren Lambda (Q7.6), así que la tarifa descontada de Lambda mueve el cruce todavía más lejos.

**Q7.4**

Porque **el costo omitido es real, grande, y cae enteramente de un lado de la comparación.** Expresado correctamente es `probabilidad de falla × costo de la falla`: un failover manual de MySQL realizado bajo presión por quien esté de guardia, a las 03:00, contra un runbook ejercitado por última vez en un simulacro hace unos meses. El costo de un solo evento de esos — horas de caída, pérdida potencial de datos entre la última transacción replicada y la falla, créditos a clientes, la revisión del incidente, el día siguiente del ingeniero — rutinariamente excede la diferencia *anual entera* entre las dos opciones.

El sesgo es direccional y consistente: **el costo de la opción autogestionada está sistemáticamente subestimado**, porque su riesgo se soporta como un evento catastrófico ocasional en lugar de como una línea mensual recurrente, y los modelos de costo se construyen a partir de líneas recurrentes. Mientras tanto, la mitigación de ese riesgo por parte de la opción gestionada *sí* está en la factura — la prima de Multi-AZ dentro de la tarifa de $0.342/hr es literalmente el precio del failover automático con un RTO típico de un minuto o dos.

La forma honesta de modelarlo: asignale a la opción autogestionada una línea explícita de pérdida esperada (probabilidad × costo) y dejá que la gente discuta sobre la probabilidad. Una discusión sobre un número es progreso; una línea omitida no lo es.

**Q7.5**

Dos capacidades concretas que resignás:

1. **Acceso al sistema operativo y de superusuario.** Sin `SSH` al host, sin privilegio `SUPER`, sin acceso al filesystem. No podés instalar un plugin o UDF arbitrario, correr un agente personalizado, ajustar un parámetro del kernel, o usar una herramienta de backup que requiera una copia cruda del directorio de datos. Solo son ajustables los parámetros que AWS expone en un DB parameter group.
2. **Control de la versión y del momento del mantenimiento.** RDS impone ventanas de mantenimiento y eventualmente fuerza upgrades de versión menor y migraciones de versión mayor de fin de vida según el calendario de AWS. No podés fijar una versión indefinidamente, ni correr una versión que AWS no ofrezca.

Sigue siendo usualmente correcto porque las capacidades resignadas son las que **la mayoría de los equipos nunca ejercita realmente**, mientras que las adquiridas — backups automatizados con recuperación point-in-time al segundo, Multi-AZ de un solo checkbox con failover automático, parcheo gestionado, réplicas de lectura creadas en minutos, Performance Insights, cifrado en reposo — son las que todo equipo necesita y pocos construyen bien. Cambiás control raramente usado por confiabilidad entregada continuamente. Cuando un workload genuinamente necesita el control resignado, **RDS Custom** existe como camino intermedio, y autogestionar sobre EC2 sigue siendo legítimo — solo tiene que justificarse contra el número totalmente cargado de Q7.1, no contra la línea de infraestructura.

**Q7.6**

Porque un **Compute Savings Plan sigue al workload a través de los servicios de cómputo**, mientras que un EC2 Instance Savings Plan no.

Con un Compute SP, migrar un servicio de EC2 a Fargate o Lambda mantiene el compromiso productivo — el descuento simplemente se reaplica al nuevo uso. La modernización y el compromiso dejan de estar en tensión, así que un compromiso a 3 años no se convierte en un argumento de 3 años contra rearquitecturar.

Con un **EC2 Instance Savings Plan**, esa misma migración deja varado el compromiso: el uso de EC2 para el que fue comprado desaparece, el nuevo uso de Fargate/Lambda es inelegible, y pagás tanto el compromiso huérfano como la factura serverless sin descuento hasta que expira el plazo. El compromiso se convierte en un desincentivo financiero para mejorar la arquitectura — que es exactamente el resultado que Q3.6 ordena los pasos para evitar.

La regla general que esto establece: **comprá el compromiso más estrecho cuyo alcance estés seguro que va a sobrevivir a su plazo.** Donde la arquitectura es estable, los ~6 puntos extra de descuento del EC2 Instance SP son plata gratis. Donde está en movimiento — que es la mayoría de los lugares — la flexibilidad del Compute SP vale más que el descuento que resignás por ella.

---

### Ejercicio 8

**Q8.1**

**Todo el gasto anterior a la fecha de activación queda permanentemente sin atribuir.** La activación de cost allocation tags aplica a los datos de facturación generados desde ese punto en adelante; no re-etiqueta retroactivamente los ítems históricos. Tus costos de marzo a agosto van a aparecer bajo `No CostCenter$` en cada informe, para siempre, y ningún caso de soporte puede regenerarlos.

Consecuencias: ninguna comparación año contra año por centro de costo para ese período, ningún showback/chargeback para los primeros seis meses, y — lo más dañino — no podés establecer la *línea base* contra la que se mide el trabajo de optimización de este año. También significa que el primer informe honesto basado en etiquetas llega seis meses más tarde de lo que todos esperan.

La regla práctica: **activá las cost allocation tags el día uno de la vida de una cuenta**, antes de desplegar cualquier workload, y tratá las claves de etiqueta estándar como parte de la definición de la landing zone. No cuesta nada activar una etiqueta que todavía no se usa.

**Q8.2**

- **`FORECASTED > 80%`** dispara cuando la proyección de AWS de tu gasto de fin de mes cruza el umbral. Es la alerta **accionable**: llega mientras todavía quedan días en el mes para encontrar la causa y detenerla.
- **`ACTUAL > 100%`** dispara cuando la plata ya se gastó. Es un **registro**, no una advertencia.

Un budget con solo notificaciones `ACTUAL` es casi inútil porque, para cuando dispara, cada dólar que debía proteger ya se fue. Te dice qué pasó, que es lo que Cost Explorer te habría dicho de todas formas. Peor, los datos de costo tienen un retraso de hasta 24 horas, así que una alerta `ACTUAL 100%` puede llegar un día *después* del sobrecosto.

Mantené ambas — el pronóstico para actuar, el real como red de contención para cuando el pronóstico se equivoque (es poco confiable en cuentas de menos de unos pocos meses, y no anticipa un cambio escalonado). Agregá umbrales `ACTUAL` intermedios en 50% y 80% para cuentas donde una anomalía rápida importa más que un pronóstico suave.

**Q8.3**

**AWS Budgets Actions.** Una budget action puede, al superarse el umbral, aplicar automáticamente una política de IAM o una Service Control Policy restrictiva, detener instancias EC2 o RDS específicas, o adjuntar una política de deny a roles determinados — ya sea automáticamente o tras un paso de aprobación.

Razones para tener cuidado en producción:
- La obvia: una SCP que deniegue `ec2:RunInstances` va a impedir que Auto Scaling reemplace una instancia insana, así que una barrera de costos se convierte en un incidente de disponibilidad durante exactamente el pico de tráfico que disparó el sobrecosto.
- La sutil: **los datos de facturación tienen un retraso de hasta 24 horas**, así que una acción puede dispararse sobre información obsoleta — o tarde, después del gasto que importaba, o contra un pico que ya fue remediado.

El patrón seguro es budget actions en modo **con aprobación requerida** en producción y en modo **automático** solo en cuentas de sandbox y de capacitación, donde bloquear lanzamientos es exactamente el comportamiento deseado y ningún cliente se ve afectado. Las cuentas de sandbox son donde las budget actions genuinamente brillan.

**Q8.4**

`BenefitsConsidered=true` le indica a Cost Explorer que calcule los ahorros de la recomendación **netos de la cobertura de Reserved Instances y Savings Plans ya aplicada al recurso**, en lugar de contra el precio de lista On-Demand.

La relación con Q4.4 es directa: es el mismo hecho, expuesto por la herramienta. Con `false`, una `m5.4xlarge` cubierta por un SP a 3 años se reporta como ahorrando los $420.48/mes completos, lo cual es ficción — el compromiso se sigue debiendo. Con `true`, el ahorro reportado colapsa a lo que el compromiso pueda genuinamente redesplegarse, que para un EC2 Instance SP bloqueado puede ser casi cero.

Guía práctica: **usá `BenefitsConsidered=true` para cualquier cuenta con cobertura de compromisos significativa**, o vas a construir un plan de ahorros (del tipo documento) a partir de números que no pueden realizarse, y después vas a tener que explicarle a finanzas por qué la reducción proyectada nunca apareció en la factura.

**Q8.5**

- **Costo unblended** — el cargo tal como impactó realmente en la factura, el día que impactó. **Enero muestra los $12.000 completos**; febrero y marzo muestran $0 por esa RI.
- **Costo amortizado** — los cargos por adelantado repartidos uniformemente a lo largo del plazo del compromiso. `12,000 / 36 = $333.33` aparece en cada uno de los 36 meses.
- **Costo blended** — relevante solo en AWS Organizations: promedia el beneficio de RI/SP entre todas las cuentas miembro para que cada cuenta vea la misma tarifa efectiva, sin importar qué cuenta técnicamente poseía la reserva. Útil para equidad de showback en una familia de facturación consolidada, engañoso para cualquier otra cosa.

Para juzgar la eficiencia mensual de un equipo, usá **costo amortizado**. El unblended hace que enero parezca una catástrofe y febrero un triunfo, cuando nada cambió en el comportamiento del equipo — mide el *timing de los pagos*, no el *consumo de recursos*. El amortizado mide lo que el equipo realmente usó cada mes, que es lo único sobre lo que pueden actuar. Usá el unblended para flujo de caja y conciliación de facturas, donde el timing es el punto.

**Q8.6**

Dos de varias formas:

1. **Recursos no creados por `RunInstances`.** La política cubre exactamente una acción de API sobre un tipo de recurso. Un bucket de S3, un NAT gateway, un Load Balancer, una instancia RDS, una tabla de DynamoDB, una función Lambda, un log group de CloudWatch con retención infinita, un plano de control de EKS — ninguno de estos es `ec2:RunInstances`, y todos ellos cuestan plata. La gobernanza de costos mediante políticas de IAM por acción es un juego de topos; la forma duradera es una **tag policy de AWS Organizations** más SCPs aplicadas a nivel de OU.
2. **Recursos creados indirectamente por servicios de AWS en tu nombre.** Un Auto Scaling group lanza instancias usando su propio service-linked role y una launch template — si la launch template no lleva `TagSpecifications` para `CostCenter`, cada instancia escalada queda sin etiquetar, y es la flota escalada la que constituye el pico que más querés atribuir. Lo mismo aplica a los managed node groups de EKS, Spot Fleet, clusters de EMR, y cualquier cosa creada por CloudFormation sin propagación de `--tags`.

También vale nombrar: **los cargos que no tienen ningún recurso que etiquetar** — transferencia de datos entre AZs, horas de IPv4 pública, procesamiento de datos de NAT gateway, requests a la API de KMS, cargos de soporte, y las llamadas a la API de Cost Explorer de este ejercicio. Una fracción material de una factura madura de AWS aterriza en "EC2 - Other" y es inetiquetable por construcción. La atribución perfecta no es alcanzable; **85–90% de cobertura etiquetada con un remanente conocido y explicado** es el objetivo realista, y el remanente debería asignarse por una regla documentada en lugar de dejarse a la discusión.

---

### Capstone

**QC.1**

```
ON-PREMISES (from Exercise 1)
  Compute (depreciation + support + hypervisor)  1,840 + 920 + 600 = $ 3,360.00
  Storage                                        (included in servers) 0.00
  Network / transit                                                 $ 1,200.00
  Licensing (hypervisor, counted above)                                  0.00
  Facilities: colocation + power/cooling         1,800 + 757       = $ 2,556.86
  Operations labour                                                 $ 5,000.00
  TOTAL                                                             = $12,116.86
  Fixed share                                                       = 93.8%
  Cost per used vCPU-month (384 × 22% = 84.5)                       = $  143.43

LIFT-AND-SHIFT, ON-DEMAND, 24×7
  Compute   37 × 0.384 × 730                                        = $10,371.84
  Storage   37 × 200 GiB × 0.08 = 7,400 GiB                         = $   592.00
  Egress    (2,048 − 100) × 0.09                                    = $   175.32
  Licensing (Linux / open source)                                   = $     0.00
  Facilities                                                        = $     0.00
  Operations labour  (still patching 37 guest OSes; ~0.4 FTE)       = $ 4,000.00
  TOTAL                                                             = $15,139.16
  Fixed share (commitments: none; but 24×7 On-Demand is fixed in practice) ≈ 0% contractually
  Cost per used vCPU-month (296 provisioned × 22% = 65.1)           = $   232.55

OPTIMIZED CLOUD
  Sizing: peak 61% × 384 = 234 vCPU, + 25% headroom = 293 vCPU → 37 × m5.2xlarge
  Compute — baseline 22 instances, 3-yr Compute SP @ 66% off:
            22 × 0.1306 × 730                                       = $ 2,097.44
  Compute — burst 15 instances, On-Demand, ~30% of hours (219 h):
            15 × 0.384 × 219                                        = $ 1,261.44
  Storage   7,400 GiB × 0.08                                        = $   592.00
  Egress    (2,048 − 100) × 0.09                                    = $   175.32
  Licensing                                                         = $     0.00
  Facilities                                                        = $     0.00
  Operations labour (managed services + IaC; ~0.15 FTE)             = $ 1,500.00
  Subtotal before support                                           = $ 5,626.20
  Business Support (10% of first $10k of usage, ~$4,126 usage)      = $   412.62
  TOTAL                                                             = $ 6,038.82
  Fixed share (SP commitment 2,097 + storage 592 = 2,689 / 6,039)   = 44.5%
  Cost per used vCPU-month (293 provisioned, now ~60% utilized)     = $    34.35

  vs on-premises:  50.2% reduction    ($6,078/month, $72,936/year)
```

**La columna del medio es la prueba.** Un lift-and-shift puro queda *por encima* de la línea base on-premises — $15.139 contra $12.117, un **aumento del 25%**. Migrar a AWS y reducir costos son dos proyectos separados que casualmente comparten un cronograma. Este no es un resultado forzado; es el desenlace más común de una migración sin optimizar, y es por lo que tantos programas de cloud reportan un aumento de costo en el primer año.

**QC.2**

Dos razones estructurales:

1. **Trasplantaste el problema de utilización.** La flota on-premises corría al 22% de CPU. Dimensionar 1:1 a las formas de VM existentes reproduce ese 22% exactamente — ahora estás alquilando capacidad ociosa por hora en lugar de poseerla, y alquilar capacidad ociosa es *más* caro que poseerla, porque la tarifa horaria incluye el margen de AWS, sus instalaciones, su personal de operaciones y el valor de opción de una elasticidad que no estás usando. Los $143.43/vCPU-usada del Ejercicio 1 se vuelven $232.55.
2. **Pagaste por elasticidad y no la usaste.** El precio On-Demand es la tarifa más cara que ofrece AWS, y toda su propuesta de valor es el derecho a dejar de pagar en cualquier momento. Correr On-Demand 24×7 durante tres años es comprar una póliza de seguro que nunca reclamás. También rechazaste todos los descuentos por compromiso (Ejercicio 3) — hasta un 66–72% dejado sobre la mesa.

Qué decirle al ejecutivo: **esta columna no es un hallazgo sobre el cloud, es un hallazgo sobre el plan.** Es el costo correcto y esperado del *primer* hito de una migración, no del estado final, y existe porque mover y optimizar al mismo tiempo es cómo fracasan las migraciones. La columna de la derecha es el destino y está 50% por debajo de la línea base; la columna del medio es una escala intermedia. El riesgo genuino a señalar es organizacional más que técnico: muchas migraciones se detienen en la columna del medio, declaran el fin, y el trabajo de optimización nunca se financia. Financiá la fase de optimización explícitamente en el mismo business case, con las cuatro palancas de abajo como entregables nombrados y los números de QC.1 como sus objetivos.

**QC.3**

| Palanca | Efecto | Concepto del enunciado de tarea 1.4 |
|---|---|---|
| Dimensionar al pico medido + headroom en lugar de a las formas de VM legadas | Elimina el 78% de capacidad ociosa trasplantada | **Right-sizing** |
| Correr solo el 60% de la flota de forma continua; el resto a ráfagas ~30% de las horas | Convierte capacidad fija en consumo | **Costo fijo vs. variable** (y la elasticidad que lo hace posible) |
| Compute Savings Plan a 3 años sobre la línea base probada | 66% de descuento sobre la porción siempre encendida | **Estructura de costos del cloud** — el modelo de consumo, aplicado solo después de las dos primeras palancas (Q3.6) |
| Servicios gestionados + scheduling por IaC reducen ops de 0.5 FTE a ~0.15 FTE | $3.500/mes, la mayor reducción de una sola línea | **Servicios gestionados de AWS** y **automatización (IaC)** |

Vale nombrarlo explícitamente: **la línea de mano de obra es el mayor ahorro individual de todo el modelo** — $5.000 → $1.500, mayor que toda la factura de almacenamiento y egress combinadas. Es también la línea más frecuentemente omitida de los business cases de migración, porque no está en ninguna factura de AWS (Q7.1). La economía del cloud no es principalmente sobre el precio del cómputo.

**QC.4**

1. **Trade capital expense for variable expense** — las filas de Cómputo e Instalaciones. $110.400 de hardware que se deprecia y un cheque a cinco años se vuelven una tarifa horaria que se detiene cuando la instancia se detiene.
2. **Benefit from massive economies of scale** — el precio efectivo por vCPU. El poder de compra agregado de AWS entre millones de clientes es por lo que $0.384/hr por 8 vCPU le gana a lo que podés lograr comprando 12 servidores.
3. **Stop guessing capacity** — el cambio de dimensionamiento de 384 vCPU aprovisionadas a 293, y la flota de ráfaga. La decisión del refresh de hardware a 14 meses (Q1.5) desaparece por completo.
4. **Increase speed and agility** — no es una fila, y ese es el punto: es el valor de los 0.35 FTE liberados de parchear hacia trabajo de producto, más la capacidad de probar una nueva familia de instancias en una tarde en lugar de en un ciclo de compras.
5. **Stop spending money running and maintaining data centres** — la fila de Instalaciones yendo a cero: $2.556,86/mes de colocation, energía y refrigeración, más el contrato de soporte de hardware de $920, eliminados de plano.
6. **Go global in minutes** — no visible en un modelo de una sola región, pero es el valor de opción que el capstone no pone en precio. Servir a un segundo continente significa seleccionar una región, no firmar un contrato de colocation en otro país.

Referencia: [Six advantages of cloud computing](https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html)

**QC.5**

**La mano de obra de operaciones** — y en una migración mal llevada *sube*, no baja.

El mecanismo: durante un período, estás operando ambos parques. El equipo ahora opera la plataforma legada *y* una nueva, en un nuevo modelo operativo, con nuevo tooling, nuevo IAM, nueva red, nuevo monitoreo, y un nuevo conjunto de modos de falla que nadie vio antes. Mientras tanto las habilidades requeridas cambiaron — la gente que era experta en la plataforma vieja es novata en la nueva, y el aprendizaje ocurre sobre el camino crítico. En la columna optimizada del capstone la línea solo cae a $1.500 *porque* la arquitectura optimizada usa servicios gestionados e IaC. Un lift-and-shift a 37 instancias EC2 autogestionadas (columna del medio) apenas la mueve: seguís parcheando 37 sistemas operativos huéspedes, solo cambiaste dónde corren.

Por qué hunde business cases: es la línea **más grande** del modelo (Ejercicio 1: $5.000 de $12.117, 41%), la **más incierta**, y la **única que AWS no factura** — así que es simultáneamente el número más consecuente y el más fácil de suponer inexistente. Un business case que proyecta la línea de mano de obra a cero el día de la migración no es optimista, es aritméticamente erróneo, y cuando el ahorro proyectado no se materializa la causa está casi siempre acá y no en las líneas de infraestructura que todos pasaron su tiempo modelando.

La disciplina: modelá la línea de mano de obra explícitamente, en tres fases — *durante* la migración (más alta, doble operación), *después* del lift-and-shift (aproximadamente plana), *después* de la modernización (materialmente más baja) — y hacé de la tercera fase un entregable financiado en lugar de un supuesto. Esa es la versión honesta de la diapositiva, y es la versión que sobrevive al contacto con el segundo año.

</details>

---

## Fuentes

Todas las URLs verificadas al momento de escribir.

- [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)
- [Six Advantages of Cloud Computing — Overview of Amazon Web Services](https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html)
- [AWS Well-Architected Framework — Cost Optimization Pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)
- [AWS Price List API — `GetProducts`](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html)
- [AWS Pricing Calculator](https://calculator.aws/)
- [Amazon EC2 Reserved Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html)
- [AWS Savings Plans User Guide](https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html)
- [Amazon EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html)
- [AWS Compute Optimizer](https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html)
- [Amazon RDS for Oracle licensing options](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Oracle.Concepts.licensing.html)
- [Amazon RDS for Microsoft SQL Server](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_SQLServer.html)
- [AWS License Manager](https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html)
- [Amazon EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html)
- [Managing your costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [AWS Cost Anomaly Detection](https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html)
- [Using cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html)
- [AWS Cost and Usage Reports](https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html)
- [New — AWS public IPv4 address charge and Public IP Insights](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)
- [AWS Cost Management pricing](https://aws.amazon.com/aws-cost-management/pricing/)
- [AWS Migration Evaluator](https://aws.amazon.com/migration-evaluator/)