# Tema 1.1 — Definir los beneficios de la nube de AWS
## Ejercicios guiados (CLF-C02, Dominio 1 — peso 6.0)

---

### Qué vas a hacer realmente

El examen te pide *definir* los beneficios. Las definiciones memorizadas de una diapositiva se evaporan bajo presión. En estos ejercicios vas a **medir** cada beneficio con la AWS CLI, para que "elasticidad", "economías de escala" y "alta disponibilidad" dejen de ser vocabulario y se conviertan en números que leíste personalmente en una terminal.

Cada una de las seis ventajas clásicas de la computación en la nube está mapeada a un laboratorio:

| Ventaja (whitepaper AWS Overview) | Ejercicio |
|---|---|
| Volverse global en minutos | 1, 7 |
| Beneficiarse de economías de escala masivas | 3, 4 |
| Cambiar gastos de capital por gastos variables | 3, 8 |
| Dejar de adivinar la capacidad (elasticidad) | 6 |
| Aumentar la velocidad y la agilidad | 5 |
| Dejar de gastar dinero operando y manteniendo centros de datos | 2, 8 |

Fuente: <https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html>
Guía del examen: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>

---

### Requisitos previos

- **AWS CLI v2** (`aws --version` debe reportar `aws-cli/2.x`). La v1 no tiene `elbv2 wait` ni varios comportamientos de `--query` que se usan acá.
- **`jq`** para parsear la Price List API (devuelve JSON *dentro* de strings JSON).
- Una cuenta de AWS donde puedas crear y destruir recursos, con un principal de IAM autorizado a llamar:
  `ec2:Describe*`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:*LaunchTemplate*`, `ssm:GetParameter*`, `pricing:*`, `savingsplans:Describe*`, `autoscaling:*`, `elasticloadbalancing:*`, `cloudformation:*`, `s3:*`, `budgets:*`, `ce:GetCostAndUsage`, `compute-optimizer:GetEnrollmentStatus`, `iam:CreateServiceLinkedRole`.
- Un shell donde puedas mantener variables de entorno entre ejercicios (una sola sesión de terminal, de principio a fin).

### Costo y seguridad

| Ejercicio | Recursos facturables | Costo aproximado si se destruye dentro de 1 hora |
|---|---|---|
| 0 | AWS Budgets (los primeros dos presupuestos son gratuitos) | $0.00 |
| 1, 2 | Llamadas Describe/SSM | $0.00 |
| 3, 4 | APIs de Price List + Savings Plans | $0.00 |
| 5, 6 | 2–4 × `t3.micro`, 1 × Application Load Balancer | ≈ $0.05 |
| 7 | solo `curl` | $0.00 |
| 8 | 1 × solicitud a la API de Cost Explorer ($0.01), 1 × bucket de S3 (vacío) | ≈ $0.01 |

> **Precaución con la Free Tier.** AWS cambió la Free Tier en julio de 2025: las cuentas creadas a partir del 2025-07-15 obtienen un plan gratuito basado en créditos en lugar de las asignaciones clásicas de 12 meses. No asumas que tu cuenta tiene "750 horas gratis de `t3.micro`". Verificá en <https://aws.amazon.com/free/> y tratá el presupuesto del Ejercicio 0 como obligatorio, no opcional.

> **Todo ejercicio que crea algo se destruye en el Ejercicio 9.** No pares antes de llegar ahí.

---

## Ejercicio 0 — Establecer la identidad y una barrera de contención de costos

**Beneficio bajo prueba:** el modelo de costo variable solo es una ventaja si podés *ver* la variable. Primero, instalá el medidor.

### Pasos

1. Confirmá con qué principal y en qué cuenta estás operando. Nunca corras un laboratorio sin esto.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDA************EXAMPLE",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-lab"
   }
   ```

2. Fijá el ID de cuenta y una Región de trabajo en variables de shell. Todos los ejercicios posteriores las reutilizan.

   ```bash
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export AWS_REGION=us-east-1
   export AWS_DEFAULT_REGION=$AWS_REGION
   echo "account=$ACCOUNT_ID region=$AWS_REGION"
   ```

3. Escribí una definición de presupuesto mensual de costos. Reemplazá la dirección de correo por la tuya.

   ```bash
   cat > /tmp/budget.json <<'JSON'
   {
     "BudgetName": "clf-lab-guardrail",
     "BudgetLimit": { "Amount": "5", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST"
   }
   JSON

   cat > /tmp/budget-notify.json <<'JSON'
   [
     {
       "Notification": {
         "NotificationType": "ACTUAL",
         "ComparisonOperator": "GREATER_THAN",
         "Threshold": 80,
         "ThresholdType": "PERCENTAGE"
       },
       "Subscribers": [
         { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
       ]
     }
   ]
   JSON
   ```

4. Creá el presupuesto.

   ```bash
   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file:///tmp/budget.json \
     --notifications-with-subscribers file:///tmp/budget-notify.json
   ```

   Una llamada exitosa devuelve un cuerpo de respuesta vacío (HTTP 200, sin salida). Verificá:

   ```bash
   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].[BudgetName,BudgetLimit.Amount,TimeUnit]' --output table
   ```

   ```text
   -------------------------------------------
   |             DescribeBudgets             |
   +---------------------+-------+-----------+
   |  clf-lab-guardrail  |  5.0  |  MONTHLY  |
   +---------------------+-------+-----------+
   ```

Referencia: <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>

### Comprobá tu comprensión — Bloque 0

- **Q0.1** — Configuraste un presupuesto de $5. A las 03:00 un script automatizado lanza 40 instancias `m5.24xlarge`. ¿AWS las detiene cuando se excede el presupuesto? Justificá.
- **Q0.2** — En términos on-premises, ¿cuál es el control equivalente a un AWS Budget, y por qué es estructuralmente más débil como mecanismo *preventivo* ahí?
- **Q0.3** — `sts get-caller-identity` devolvió un ARN terminado en `:user/clf-lab`. Nombrá una razón por la que un equipo de plataforma en producción consideraría ese ARN en sí mismo un hallazgo.

---

## Ejercicio 1 — Inventariar la infraestructura global ("volverse global en minutos")

**Beneficio bajo prueba:** alcance global. Vas a enumerar la huella de AWS desde la API en lugar de confiar en una página de marketing.

### Pasos

1. Listá todas las Regiones, incluidas las que tu cuenta no tiene habilitadas.

   ```bash
   aws ec2 describe-regions --all-regions \
     --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
     --output table
   ```

   ```text
   ------------------------------------------------
   |                DescribeRegions               |
   +---------------------+------------------------+
   |  af-south-1         |  not-opted-in          |
   |  ap-east-1          |  not-opted-in          |
   |  ap-northeast-1     |  opt-in-not-required   |
   |  ap-south-1         |  opt-in-not-required   |
   |  ...                |  ...                   |
   |  us-east-1          |  opt-in-not-required   |
   |  us-west-2          |  opt-in-not-required   |
   +---------------------+------------------------+
   ```

2. Contalas y compará con la cifra de "Regiones comerciales" que publica AWS.

   ```bash
   aws ec2 describe-regions --all-regions --query 'length(Regions)'
   aws ec2 describe-regions --query 'length(Regions)'   # only the ones you can use today
   ```

   ```text
   38
   20
   ```

   > El número exacto se mueve cada pocos meses. Nunca lo memorices para el examen; memorizá la *jerarquía*. Cifra pública: <https://aws.amazon.com/about-aws/global-infrastructure/>

3. Bajá un nivel: Zonas de Disponibilidad dentro de una Región.

   ```bash
   aws ec2 describe-availability-zones --region us-east-1 \
     --query 'AvailabilityZones[].{Name:ZoneName,Id:ZoneId,State:State}' \
     --output table
   ```

   ```text
   ---------------------------------------------------
   |            DescribeAvailabilityZones            |
   +--------------+---------------+------------------+
   |      Id      |     Name      |      State       |
   +--------------+---------------+------------------+
   |  use1-az6    |  us-east-1a   |  available       |
   |  use1-az1    |  us-east-1b   |  available       |
   |  use1-az2    |  us-east-1c   |  available       |
   |  use1-az4    |  us-east-1d   |  available       |
   |  use1-az3    |  us-east-1e   |  available       |
   |  use1-az5    |  us-east-1f   |  available       |
   +--------------+---------------+------------------+
   ```

   Mirá con atención ese mapeo: `us-east-1a` es `use1-az6`, no `use1-az1`. **El sufijo de letra se aleatoriza por cuenta de AWS.** Tu salida va a mostrar un emparejamiento distinto.

4. Consultá la misma infraestructura a través de los parámetros públicos de Systems Manager — un catálogo legible por máquina que AWS publica en todas las cuentas, sin cargo.

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/global-infrastructure/regions \
     --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -5
   ```

   ```text
   af-south-1
   ap-east-1
   ap-northeast-1
   ap-northeast-2
   ap-northeast-3
   ```

5. Preguntá qué Regiones ofrecen un servicio dado — la pregunta real detrás de "¿puedo volverme global con *esta* arquitectura en minutos?"

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/global-infrastructure/services/bedrock/regions \
     --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
   ```

   ```text
   ap-northeast-1
   ap-south-1
   ap-southeast-2
   eu-central-1
   ...
   us-east-1
   us-west-2
   ```

6. Encontrá la infraestructura que *no* es una Región ni una AZ — Local Zones y Wavelength Zones.

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-west-2 \
     --filters Name=zone-type,Values=local-zone \
     --query 'AvailabilityZones[].[ZoneName,ZoneId,GroupName]' --output table
   ```

   ```text
   ------------------------------------------------------------
   |                 DescribeAvailabilityZones                |
   +--------------------+------------------+------------------+
   |  us-west-2-lax-1a  |  usw2-lax1-az1   |  us-west-2-lax-1 |
   |  us-west-2-lax-1b  |  usw2-lax1-az2   |  us-west-2-lax-1 |
   +--------------------+------------------+------------------+
   ```

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-east-1 \
     --filters Name=zone-type,Values=wavelength-zone \
     --query 'length(AvailabilityZones)'
   ```

Referencias: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html> · <https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html> · <https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html>

### Comprobá tu comprensión — Bloque 1

- **Q1.1** — Definí, en una oración cada uno y sin superposición: Región, Zona de Disponibilidad, Local Zone, Edge Location (Punto de Presencia).
- **Q1.2** — ¿Por qué AWS aleatoriza el mapeo entre `us-east-1a` y `use1-azN` por cuenta? ¿Qué falla concreta causaría un mapeo fijo?
- **Q1.3** — Dos cuentas de AWS en la misma organización quieren ubicar recursos en la *misma* AZ *física* para tráfico entre cuentas de baja latencia. ¿Qué identificador deben intercambiar y cuál deben ignorar?
- **Q1.4** — El Paso 2 mostró 38 Regiones en total pero solo 20 utilizables. ¿Qué debe hacer un administrador para usar las otras, y cuál es la razón de negocio por la que AWS las hace opt-in?
- **Q1.5** — Un juego móvil sensible a la latencia necesita menos de 10 ms para usuarios en Los Ángeles. ¿Cuál de los cuatro constructos de infraestructura de Q1.1 es la respuesta correcta, y por qué "una Edge Location en LA" es incorrecta para el cómputo del juego?

---

## Ejercicio 2 — Leer la frontera del modelo de responsabilidad compartida

**Beneficio bajo prueba:** "dejar de gastar dinero operando y manteniendo centros de datos". El ahorro no es solo dinero; es un conjunto de tareas que desaparecen de tu backlog. Vas a ubicar la línea.

### Pasos

1. Preguntale a AWS qué opera en tu nombre para una base de datos administrada, sin crear ninguna. Inspeccioná la *forma* de la superficie de control:

   ```bash
   aws rds describe-db-engine-versions --engine postgres \
     --query 'DBEngineVersions[-1].[Engine,EngineVersion,SupportsReadReplica,ValidUpgradeTarget[0].EngineVersion]' \
     --output table
   ```

   ```text
   ------------------------------------------------
   |          DescribeDBEngineVersions            |
   +-----------+--------+---------+---------------+
   |  postgres |  17.4  |  True   |  17.5         |
   +-----------+--------+---------+---------------+
   ```

   Fijate en lo que está *ausente* de toda la API de RDS: no hay ninguna llamada para parchear el SO invitado, reemplazar un disco fallado ni recablear un rack. Esas tareas no están delegadas — directamente no están expuestas.

2. Contrastá con EC2, donde el SO es tuyo:

   ```bash
   aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text
   ```

   ```text
   ami-0abcdef1234567890
   ```

   Ese ID de AMI cambia cuando AWS publica una nueva build — pero *aplicarlo* a tu flota en ejecución es tarea tuya.

3. Enumerá una tarea indiferenciada concreta del lado de AWS que ya no realizás: la planificación de capacidad de hardware por familia de instancias.

   ```bash
   aws ec2 describe-instance-type-offerings --location-type availability-zone \
     --filters Name=instance-type,Values=m5.large \
     --region us-east-1 \
     --query 'InstanceTypeOfferings[].Location' --output text
   ```

   ```text
   us-east-1a	us-east-1b	us-east-1c	us-east-1d	us-east-1f
   ```

   Leelo así: cinco clústeres de centro de datos distintos ya tienen capacidad `m5.large` que vos no compraste, ni instalaste en rack, ni alimentaste, ni refrigeraste.

Referencia: <https://aws.amazon.com/compliance/shared-responsibility-model/>

### Comprobá tu comprensión — Bloque 2

- **Q2.1** — Enunciá el modelo de responsabilidad compartida en sus dos mitades canónicas, y luego clasificá cada uno de estos casos: (a) cifrar un objeto de S3; (b) destruir un SSD fallado; (c) parchear el kernel de Linux en una instancia EC2; (d) parchear el kernel de Linux bajo una instancia RDS; (e) configurar un security group.
- **Q2.2** — El Paso 3 mostró `m5.large` ofrecido en 5 de las 6 AZs de `us-east-1`. ¿Qué supuesto operativo *no* deberías extraer de esa salida al diseñar un despliegue multi-AZ?
- **Q2.3** — Un CFO pregunta: "Igual pagamos personal. ¿Dónde está el ahorro de no operar un centro de datos?" Dá tres líneas de costo que genuinamente desaparecen y una que no.

---

## Ejercicio 3 — Ponerle precio a un servidor: CapEx → OpEx, y economías de escala

**Beneficio bajo prueba:** cambiar gastos de capital por gastos variables, y economías de escala masivas. Vas a extraer precios publicados reales desde la Price List Query API.

> La Price List API tiene endpoints solo en `us-east-1`, `eu-central-1` y `ap-south-1`. Pasá siempre `--region us-east-1` sin importar qué Región estés cotizando.

### Pasos

1. Obtené el precio On-Demand por hora de una `m5.large`, Linux, tenencia compartida, en N. Virginia.

   ```bash
   price_of () {
     local itype="$1" location="$2"
     aws pricing get-products \
       --region us-east-1 \
       --service-code AmazonEC2 \
       --filters \
         "Type=TERM_MATCH,Field=instanceType,Value=${itype}" \
         "Type=TERM_MATCH,Field=location,Value=${location}" \
         "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
         "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
         "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
         "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
         "Type=TERM_MATCH,Field=marketoption,Value=OnDemand" \
       --max-results 1 --output json \
     | jq -r '.PriceList[] | fromjson
              | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
   }

   price_of m5.large "US East (N. Virginia)"
   ```

   ```text
   0.0960000000
   ```

2. Convertí eso en el número que entiende el departamento de finanzas, y compará con una compra de capital a tres años.

   ```bash
   HOURLY=$(price_of m5.large "US East (N. Virginia)")
   python3 - <<PY
   h = float("$HOURLY")
   print(f"hourly        : \${h:.4f}")
   print(f"monthly (730h): \${h*730:,.2f}")
   print(f"3-year 24x7   : \${h*24*365*3:,.2f}")
   print(f"3-year, 8h/day weekdays only: \${h*8*260*3:,.2f}")
   PY
   ```

   ```text
   hourly        : $0.0960
   monthly (730h): $70.08
   3-year 24x7   : $2,523.31
   3-year, 8h/day weekdays only: $599.04
   ```

   Las dos últimas líneas son todo el argumento CapEx→OpEx en forma numérica: capacidad idéntica, **4.2× de diferencia en gasto**, decidida puramente por *cuándo dejás de pagar*. Un servidor comprado no se puede des-comprar el viernes a la tarde.

3. Ahora medí las economías de escala geográficamente. Cotizá la misma instancia en cuatro Regiones.

   ```bash
   for loc in "US East (N. Virginia)" "EU (Ireland)" "Asia Pacific (Sydney)" "South America (Sao Paulo)"; do
     printf '%-28s %s\n' "$loc" "$(price_of m5.large "$loc")"
   done
   ```

   ```text
   US East (N. Virginia)        0.0960000000
   EU (Ireland)                 0.1070000000
   Asia Pacific (Sydney)        0.1200000000
   South America (Sao Paulo)    0.1530000000
   ```

   *(Tus cifras van a diferir; AWS cambia precios y estos son ilustrativos.)*

4. Confirmá los strings de `location` válidos si un filtro no devuelve nada:

   ```bash
   aws pricing get-attribute-values --region us-east-1 \
     --service-code AmazonEC2 --attribute-name location \
     --query 'AttributeValues[].Value' --output text | tr '\t' '\n' | grep -i "frankfurt\|sao"
   ```

Referencias: <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html> · <https://aws.amazon.com/ec2/pricing/on-demand/>

### Comprobá tu comprensión — Bloque 3

- **Q3.1** — Explicá la diferencia entre gasto de capital y gasto operativo, e identificá cuál de los dos es realmente una ejecución de EC2 On-Demand durante 3 años.
- **Q3.2** — El Paso 2 produjo $2,523 (24×7) frente a $599 (horario laboral). ¿Qué característica de la nube hace alcanzable el segundo número, y qué trabajo *arquitectónico* se requiere para realizarlo efectivamente?
- **Q3.3** — São Paulo cuesta ~59 % más que N. Virginia para el mismo tipo de instancia. Dá dos razones estructurales. ¿Contradice esto las "economías de escala"?
- **Q3.4** — Definí "economías de escala" tal como AWS usa el término, y explicá la dirección del bucle de retroalimentación entre la cantidad de clientes de AWS y tu factura.
- **Q3.5** — ¿Por qué la Price List API requiere `capacitystatus=Used` y `preInstalledSw=NA` en el conjunto de filtros? ¿Qué pasaría sin ellos?

---

## Ejercicio 4 — Cuantificar la curva de descuento por compromiso

**Beneficio bajo prueba:** economías de escala trasladadas a vos como modelos de precio. Vas a leer el descuento real por comprometerte a gastar.

### Pasos

1. Encontrá una oferta de Compute Savings Plan: 1 año, No Upfront.

   ```bash
   aws savingsplans describe-savings-plans-offerings \
     --region us-east-1 \
     --plan-types Compute \
     --durations 31536000 \
     --payment-options "No Upfront" \
     --query 'searchResults[0].[offeringId,planType,durationSeconds,paymentOption]' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------
   |                       DescribeSavingsPlansOfferings                      |
   +----------------------------------------+----------+------------+--------+
   |  87654321-4321-4321-4321-210987654321  |  Compute |  31536000  | No Upfront |
   +----------------------------------------+----------+------------+--------+
   ```

2. Capturá el ID de la oferta y leé la tarifa efectiva para `m5.large`.

   ```bash
   SP_OFFER=$(aws savingsplans describe-savings-plans-offerings \
     --region us-east-1 --plan-types Compute --durations 31536000 \
     --payment-options "No Upfront" \
     --query 'searchResults[0].offeringId' --output text)

   aws savingsplans describe-savings-plans-offering-rates \
     --region us-east-1 \
     --savings-plan-offering-ids "$SP_OFFER" \
     --service-codes AmazonEC2 \
     --filters name=region,values=us-east-1 \
               name=instanceType,values=m5.large \
               name=tenancy,values=shared \
               name=productDescription,values="Linux/UNIX" \
     --query 'searchResults[0].[rate,unit,usageType]' --output table
   ```

   ```text
   -----------------------------------------------
   |     DescribeSavingsPlansOfferingRates       |
   +----------+--------+-------------------------+
   |  0.0679  |  Hrs   |  BoxUsage:m5.large      |
   +----------+--------+-------------------------+
   ```

   > Si el resultado sale vacío, relajá los filtros de a uno (`productDescription` primero) — los valores aceptados varían según el service code.

3. Calculá el descuento que acabás de descubrir.

   ```bash
   python3 - <<'PY'
   od, sp = 0.096, 0.0679
   print(f"on-demand : ${od:.4f}/h  -> ${od*730:,.2f}/mo")
   print(f"1yr NoUp  : ${sp:.4f}/h  -> ${sp*730:,.2f}/mo")
   print(f"discount  : {(1-sp/od)*100:.1f}%")
   print(f"break-even utilisation: {sp/od*100:.1f}% of the hours")
   PY
   ```

   ```text
   on-demand : $0.0960/h  -> $70.08/mo
   1yr NoUp  : $0.0679/h  -> $49.57/mo
   discount  : 29.3%
   break-even utilisation: 70.7% of the hours
   ```

   Esa última línea es la regla de decisión: el compromiso solo conviene si vas a consumir genuinamente más del ~71 % de las horas comprometidas.

Referencia: <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>

### Comprobá tu comprensión — Bloque 4

- **Q4.1** — Un Savings Plan es un compromiso de gasto, expresado en $/hora. ¿A qué *no* te estás comprometiendo, y por qué importa esa distinción frente a una Standard Reserved Instance?
- **Q4.2** — El punto de equilibrio fue ~71 % de utilización. Una carga de trabajo corre 8 h/día, 5 días/semana. Calculá su utilización y decí si un Compute Savings Plan de 1 año se justifica.
- **Q4.3** — ¿Un descuento por compromiso es un ejemplo de "cambiar CapEx por gasto variable", o revierte parcialmente ese beneficio? Argumentá ambos lados en dos oraciones.
- **Q4.4** — Ordená estas cuatro opciones de compra de EC2 por descuento típico, y nombrá la que AWS puede reclamar con un aviso de 2 minutos: On-Demand, Spot, Savings Plans, Dedicated Host On-Demand.

---

## Ejercicio 5 — Medir la agilidad: tiempo de aprovisionamiento

**Beneficio bajo prueba:** velocidad y agilidad. Vas a cronometrar la creación de infraestructura y compararla con un ciclo de adquisición de hardware.

### Pasos

1. Escribí una plantilla mínima de CloudFormation.

   ```bash
   cat > /tmp/agility.yaml <<'YAML'
   AWSTemplateFormatVersion: '2010-09-09'
   Description: CLF 1.1 - agility measurement stack

   Resources:
     LabBucket:
       Type: AWS::S3::Bucket
       Properties:
         BucketEncryption:
           ServerSideEncryptionConfiguration:
             - ServerSideEncryptionByDefault:
                 SSEAlgorithm: AES256
         PublicAccessBlockConfiguration:
           BlockPublicAcls: true
           BlockPublicPolicy: true
           IgnorePublicAcls: true
           RestrictPublicBuckets: true
         VersioningConfiguration:
           Status: Enabled

   Outputs:
     BucketName:
       Description: Name of the provisioned bucket
       Value: !Ref LabBucket
   YAML
   ```

2. Validá antes de desplegar — es gratis, y detecta errores de sintaxis sin consumir una operación de stack.

   ```bash
   aws cloudformation validate-template --template-body file:///tmp/agility.yaml \
     --query '[Description,Parameters]' --output json
   ```

   ```json
   [
       "CLF 1.1 - agility measurement stack",
       []
   ]
   ```

3. Desplegá y cronometralo de punta a punta.

   ```bash
   START=$(date -u +%s)
   aws cloudformation create-stack \
     --stack-name clf-agility \
     --template-body file:///tmp/agility.yaml \
     --query 'StackId' --output text

   aws cloudformation wait stack-create-complete --stack-name clf-agility
   END=$(date -u +%s)
   echo "provisioned in $((END-START)) seconds"
   ```

   ```text
   arn:aws:cloudformation:us-east-1:123456789012:stack/clf-agility/0f2c...
   provisioned in 24 seconds
   ```

4. Leé el rastro de auditoría — cada transición de estado tiene marca de tiempo.

   ```bash
   aws cloudformation describe-stack-events --stack-name clf-agility \
     --query 'reverse(StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus])' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------
   |                          DescribeStackEvents                            |
   +-------------------------------+----------------+------------------------+
   |  2026-09-03T14:02:11.482000Z  |  clf-agility   |  CREATE_IN_PROGRESS    |
   |  2026-09-03T14:02:14.117000Z  |  LabBucket     |  CREATE_IN_PROGRESS    |
   |  2026-09-03T14:02:33.905000Z  |  LabBucket     |  CREATE_COMPLETE       |
   |  2026-09-03T14:02:35.220000Z  |  clf-agility   |  CREATE_COMPLETE       |
   +-------------------------------+----------------+------------------------+
   ```

5. Leé el valor de salida que exportó el stack.

   ```bash
   aws cloudformation describe-stacks --stack-name clf-agility \
     --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text
   ```

   ```text
   clf-agility-labbucket-1a2b3c4d5e6f
   ```

Referencia: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html>

### Comprobá tu comprensión — Bloque 5

- **Q5.1** — Aprovisionaste un almacén de objetos cifrado, versionado y privado en ~24 segundos. Escribí la lista de tareas equivalente on-premises y estimá su plazo de entrega. ¿Qué única línea domina?
- **Q5.2** — La "agilidad" en el sentido del examen no es solo velocidad. Nombrá el segundo componente y explicá por qué una *destrucción rápida* es tanto un beneficio de negocio como una construcción rápida.
- **Q5.3** — Distinguí "agilidad" de "elasticidad". Dá un ejemplo de un sistema que es elástico pero no ágil.
- **Q5.4** — ¿Por qué el Paso 2 (`validate-template`) no requirió que existiera ningún recurso de AWS? ¿Qué clase de error sigue sin poder detectar?

---

## Ejercicio 6 — Alta disponibilidad: sobrevivir a la pérdida de una Zona de Disponibilidad

**Beneficio bajo prueba:** alta disponibilidad y aislamiento de fallas. Vas a construir una flota en dos AZs detrás de un balanceador de carga, después destruir la mitad y mirar cómo AWS la reconstruye.

> Este bloque crea recursos facturables. El Ejercicio 9 los elimina.

### Pasos

1. Resolvé la VPC por defecto y dos subredes en AZs **diferentes**.

   ```bash
   export VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
     --query 'Vpcs[0].VpcId' --output text)

   read -r SUBNET_A AZ_A <<<"$(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
     --query 'Subnets[0].[SubnetId,AvailabilityZone]' --output text)"
   read -r SUBNET_B AZ_B <<<"$(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
     --query 'Subnets[1].[SubnetId,AvailabilityZone]' --output text)"

   export SUBNET_A SUBNET_B AZ_A AZ_B
   echo "vpc=$VPC_ID  A=$SUBNET_A($AZ_A)  B=$SUBNET_B($AZ_B)"
   ```

   ```text
   vpc=vpc-0a1b2c3d  A=subnet-0aaa111(us-east-1a)  B=subnet-0bbb222(us-east-1b)
   ```

2. Creá un security group que permita HTTP solo desde tu propia dirección pública.

   ```bash
   export MY_IP=$(curl -s https://checkip.amazonaws.com)/32
   export SG_ID=$(aws ec2 create-security-group \
     --group-name clf-ha-sg --description "CLF 1.1 HA lab" \
     --vpc-id "$VPC_ID" --query 'GroupId' --output text)

   aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
     --protocol tcp --port 80 --cidr "$MY_IP" >/dev/null
   echo "sg=$SG_ID open to $MY_IP"
   ```

3. Construí un user data que haga que cada instancia anuncie en qué AZ está.

   ```bash
   cat > /tmp/user-data.sh <<'SH'
   #!/bin/bash
   dnf install -y httpd >/dev/null 2>&1
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/placement/availability-zone)
   ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/instance-id)
   echo "instance=${ID} az=${AZ}" > /var/www/html/index.html
   systemctl enable --now httpd
   SH
   export UD=$(base64 -w0 /tmp/user-data.sh)
   ```

   Notá el flujo de token de dos pasos de IMDSv2 — el acceso a metadatos orientado a sesión es el predeterminado actual y la única forma que deberías escribir.

4. Creá un launch template.

   ```bash
   export AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)

   aws ec2 create-launch-template \
     --launch-template-name clf-ha-lt \
     --launch-template-data "$(cat <<JSON
   {
     "ImageId": "$AMI_ID",
     "InstanceType": "t3.micro",
     "SecurityGroupIds": ["$SG_ID"],
     "UserData": "$UD",
     "CreditSpecification": { "CpuCredits": "standard" },
     "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled" },
     "TagSpecifications": [
       { "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "clf-ha" }] }
     ]
   }
   JSON
   )" --query 'LaunchTemplate.[LaunchTemplateName,LatestVersionNumber]' --output text
   ```

   ```text
   clf-ha-lt	1
   ```

5. Creá el target group y un Application Load Balancer con acceso a internet que abarque ambas AZs.

   ```bash
   export TG_ARN=$(aws elbv2 create-target-group \
     --name clf-ha-tg --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
     --target-type instance --health-check-path / \
     --health-check-interval-seconds 15 --healthy-threshold-count 2 \
     --unhealthy-threshold-count 2 \
     --query 'TargetGroups[0].TargetGroupArn' --output text)

   export ALB_ARN=$(aws elbv2 create-load-balancer \
     --name clf-ha-alb --type application --scheme internet-facing \
     --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$SG_ID" \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)

   export LISTENER_ARN=$(aws elbv2 create-listener \
     --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
     --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
     --query 'Listeners[0].ListenerArn' --output text)

   export ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
     --query 'LoadBalancers[0].DNSName' --output text)
   echo "http://$ALB_DNS"
   ```

6. Creá el Auto Scaling group abarcando ambas AZs, con health checks de ELB.

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf-ha-asg \
     --launch-template LaunchTemplateName=clf-ha-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
     --target-group-arns "$TG_ARN" \
     --health-check-type ELB --health-check-grace-period 180 \
     --default-instance-warmup 120

   aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
   ```

7. Esperá ~3 minutos, después confirmá que ambos targets están sanos y en AZs diferentes.

   ```bash
   aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
     --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State]' \
     --output table
   ```

   ```text
   -------------------------------------------------------------
   |                   DescribeTargetHealth                    |
   +-----------------------+---------------+-------------------+
   |  i-0aaa111222333444a  |  us-east-1a   |  healthy          |
   |  i-0bbb555666777888b  |  us-east-1b   |  healthy          |
   +-----------------------+---------------+-------------------+
   ```

8. Comprobá que el tráfico se distribuye entre zonas.

   ```bash
   for i in $(seq 1 8); do curl -s "http://$ALB_DNS/"; done | sort | uniq -c
   ```

   ```text
         4 instance=i-0aaa111222333444a az=us-east-1a
         4 instance=i-0bbb555666777888b az=us-east-1b
   ```

9. **Simulá la pérdida de una Zona de Disponibilidad.** Terminá la instancia en `$AZ_A` sin reducir la capacidad deseada.

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-instances \
     --query "AutoScalingInstances[?AutoScalingGroupName=='clf-ha-asg' && AvailabilityZone=='$AZ_A'].InstanceId | [0]" \
     --output text)
   echo "terminating $VICTIM in $AZ_A"

   aws autoscaling terminate-instance-in-auto-scaling-group \
     --instance-id "$VICTIM" --no-should-decrement-desired-capacity \
     --query 'Activity.[StatusCode,Cause]' --output text
   ```

10. Seguí sirviendo tráfico mientras se construye el reemplazo. Ejecutá esto inmediatamente:

    ```bash
    for i in $(seq 1 20); do
      printf '%s ' "$(date +%T)"; curl -s --max-time 3 "http://$ALB_DNS/" || echo "FAILED"
      sleep 5
    done
    ```

    ```text
    14:31:02 instance=i-0bbb555666777888b az=us-east-1b
    14:31:07 instance=i-0bbb555666777888b az=us-east-1b
    ...
    14:33:12 instance=i-0ccc999000111222c az=us-east-1a
    ```

    Cero solicitudes fallidas: la AZ sobreviviente absorbió el 100 % del tráfico mientras se construía una nueva instancia en la que falló.

11. Leé el registro de autorreparación.

    ```bash
    aws autoscaling describe-scaling-activities \
      --auto-scaling-group-name clf-ha-asg --max-items 4 \
      --query 'Activities[].[StartTime,StatusCode,Description]' --output table
    ```

    ```text
    -----------------------------------------------------------------------------------------
    |                              DescribeScalingActivities                                |
    +----------------------------+------------+---------------------------------------------+
    |  2026-09-03T14:31:44+00:00 |  Successful|  Launching a new EC2 instance: i-0ccc999...  |
    |  2026-09-03T14:31:05+00:00 |  Successful|  Terminating EC2 instance: i-0aaa111...      |
    +----------------------------+------------+---------------------------------------------+
    ```

Referencias: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html> · <https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html> · <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html>

### Comprobá tu comprensión — Bloque 6

- **Q6.1** — Definí alta disponibilidad y tolerancia a fallas, y decí cuál de las dos demostró este laboratorio. Justificá con una observación del Paso 10.
- **Q6.2** — Asumí que un despliegue en una sola AZ logra 99.9 % de disponibilidad y que las fallas de AZ son independientes. Calculá la disponibilidad teórica del diseño de dos AZs. Después dá dos razones por las que el número real es menor.
- **Q6.3** — En el Paso 6 el tipo de health check se fijó en `ELB` en lugar del predeterminado `EC2`. Describí una falla que los health checks `EC2` no detectan y los `ELB` sí.
- **Q6.4** — ¿Por qué `--min-size` debe ser 2 y no 1 para que este diseño sobreviva genuinamente a la pérdida de una AZ sin caída de capacidad?
- **Q6.5** — El launch template fijó `HttpTokens: required` y `CpuCredits: standard`. Explicá cada elección en una oración.

---

## Ejercicio 7 — Elasticidad: dejar de adivinar la capacidad

**Beneficio bajo prueba:** elasticidad. Vas a adjuntar una política de target tracking, generar carga y mirar cómo la capacidad sigue a la demanda sin intervención humana.

### Pasos

1. Adjuntá una política de escalado por seguimiento de objetivo al 40 % de CPU promedio.

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf-ha-asg \
     --policy-name cpu-target-40 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "TargetValue": 40.0,
       "PredefinedMetricSpecification": {
         "PredefinedMetricType": "ASGAverageCPUUtilization"
       },
       "DisableScaleIn": false
     }' \
     --query '[PolicyARN,Alarms[].AlarmName]' --output json
   ```

   ```json
   [
       "arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:...:policyName/cpu-target-40",
       [
           "TargetTracking-clf-ha-asg-AlarmHigh-0f6b...",
           "TargetTracking-clf-ha-asg-AlarmLow-3d21..."
       ]
   ]
   ```

   Notá lo que AWS creó por vos: **dos alarmas de CloudWatch que nunca escribiste.** Eso es el beneficio de los servicios administrados en miniatura.

2. Inspeccioná una de esas alarmas para ver el bucle de control que AWS sintetizó.

   ```bash
   aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-clf-ha-asg-AlarmHigh" \
     --query 'MetricAlarms[0].[MetricName,Statistic,Threshold,ComparisonOperator,EvaluationPeriods,Period]' \
     --output table
   ```

   ```text
   ---------------------------------------------------------------------------------
   |                                DescribeAlarms                                 |
   +---------------+---------+------+----------------------------+-----+-----------+
   |  CPUUtilization| Average |  40.0| GreaterThanThreshold       |  3  |  60       |
   +---------------+---------+------+----------------------------+-----+-----------+
   ```

3. Registrá la capacidad inicial.

   ```bash
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf-ha-asg \
     --query 'AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity,length(Instances)]' \
     --output text
   ```

   ```text
   2	4	2	2
   ```

4. Generá carga de CPU en cada instancia en ejecución vía SSM Run Command. *(Saltá a la alternativa manual del Paso 5 si tus instancias no tienen un instance profile de SSM.)*

   ```bash
   IDS=$(aws autoscaling describe-auto-scaling-instances \
     --query "AutoScalingInstances[?AutoScalingGroupName=='clf-ha-asg'].InstanceId" \
     --output text)

   aws ssm send-command --instance-ids $IDS \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["for i in $(seq 1 $(nproc)); do timeout 600 sh -c \"while :; do :; done\" & done; exit 0"]' \
     --query 'Command.CommandId' --output text
   ```

5. **Alternativa manual** — forzá el cambio de capacidad directamente y observá la mecánica, que es la parte que importa para CLF-C02:

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-ha-asg --desired-capacity 4 --honor-cooldown
   ```

6. Sondeá la capacidad cada 30 s durante 6 minutos.

   ```bash
   for i in $(seq 1 12); do
     printf '%s ' "$(date +%T)"
     aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf-ha-asg \
       --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' \
       --output text
     sleep 30
   done
   ```

   ```text
   14:45:03 4	2
   14:45:34 4	2
   14:46:05 4	3
   14:46:36 4	4
   ...
   ```

7. Escalá hacia adentro y observá la *asimetría*.

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-ha-asg --desired-capacity 2
   sleep 60
   aws autoscaling describe-scaling-activities --auto-scaling-group-name clf-ha-asg \
     --max-items 6 --query 'Activities[].[StatusCode,Description]' --output text
   ```

   ```text
   Successful	Terminating EC2 instance: i-0ddd...
   Successful	Terminating EC2 instance: i-0ccc...
   Successful	Launching a new EC2 instance: i-0ddd...
   Successful	Launching a new EC2 instance: i-0ccc...
   ```

8. Confirmá que la política sigue armada y que actuaría ante carga real.

   ```bash
   aws autoscaling describe-policies --auto-scaling-group-name clf-ha-asg \
     --query 'ScalingPolicies[].[PolicyName,PolicyType,TargetTrackingConfiguration.TargetValue,Enabled]' \
     --output table
   ```

Referencias: <https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html> · <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>

### Comprobá tu comprensión — Bloque 7

- **Q7.1** — Definí elasticidad y escalabilidad, y explicá por qué "podemos agregar servidores" es escalabilidad pero no elasticidad.
- **Q7.2** — El target tracking escaló *hacia afuera* con una alarma de 3 minutos, pero el grupo tiene un warm-up de 120 s. Explicá qué problema previene el warm-up.
- **Q7.3** — Las instancias son `t3.micro` con `CpuCredits: standard`. Explicá con precisión por qué el target tracking basado en CPU sobre instancias burstable es una trampa en producción, y nombrá una métrica predefinida mejor para una capa web detrás de un ALB.
- **Q7.4** — "Dejar de adivinar la capacidad" — describí los dos modos de falla simétricos de adivinar la capacidad on-premises, y dá el nombre financiero de cada uno.
- **Q7.5** — ¿Por qué escalar *hacia adentro* es generalmente más peligroso que escalar *hacia afuera*, y qué dos funcionalidades del ASG existen para hacerlo más seguro?

---

## Ejercicio 8 — Medir la huella global desde donde estás

**Beneficio bajo prueba:** alcance global. Vas a medir la distancia de red real hasta las Regiones de AWS.

### Pasos

1. Medí el tiempo de conexión TCP a un conjunto de endpoints regionales de servicio, tomando el mejor de tres muestras.

   ```bash
   for r in us-east-1 us-west-2 eu-west-1 eu-central-1 sa-east-1 ap-northeast-1 ap-southeast-2; do
     best=9
     for n in 1 2 3; do
       t=$(curl -s -o /dev/null --max-time 5 -w '%{time_connect}' "https://ec2.${r}.amazonaws.com" 2>/dev/null) || t=9
       awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t
     done
     printf '%-16s %6.0f ms\n' "$r" "$(awk -v x="$best" 'BEGIN{print x*1000}')"
   done
   ```

   ```text
   us-east-1           118 ms
   us-west-2           176 ms
   eu-west-1            32 ms
   eu-central-1         24 ms
   sa-east-1           212 ms
   ap-northeast-1      241 ms
   ap-southeast-2      298 ms
   ```

   *(Los valores dependen enteramente de dónde estés. Leé la forma, no los números.)*

2. Compará contra un endpoint anycast entregado desde el borde — el mismo contenido servido desde el Punto de Presencia más cercano en lugar de desde una Región.

   ```bash
   for n in 1 2 3; do
     curl -s -o /dev/null -w 'cloudfront connect: %{time_connect}s  ttfb: %{time_starttransfer}s\n' \
       https://d1.awsstatic.com/webteam/architecture-center/AWS-Architecture_Icon.png
   done
   ```

   ```text
   cloudfront connect: 0.009s  ttfb: 0.031s
   cloudfront connect: 0.008s  ttfb: 0.022s
   cloudfront connect: 0.008s  ttfb: 0.021s
   ```

3. Confirmá que lo sirvió el borde, y desde qué POP.

   ```bash
   curl -sI https://d1.awsstatic.com/webteam/architecture-center/AWS-Architecture_Icon.png \
     | grep -iE 'x-cache|x-amz-cf-pop|via'
   ```

   ```text
   via: 1.1 8f3a2b1c4d5e6f7a8b9c0d1e2f3a4b5c.cloudfront.net (CloudFront)
   x-amz-cf-pop: MAD53-P2
   x-cache: Hit from cloudfront
   ```

4. Convertí la medición en una decisión de diseño.

   ```bash
   python3 - <<'PY'
   # Round-trips matter more than bandwidth for chatty protocols.
   for name, rtt in [("nearest Region", 0.024), ("distant Region", 0.241), ("edge PoP", 0.008)]:
       for rts in (1, 5, 10):
           print(f"{name:16s} {rts:2d} round-trips -> {rtt*rts*1000:6.0f} ms")
       print()
   PY
   ```

   ```text
   nearest Region    1 round-trips ->     24 ms
   nearest Region    5 round-trips ->    120 ms
   nearest Region   10 round-trips ->    240 ms

   distant Region    1 round-trips ->    241 ms
   distant Region    5 round-trips ->   1205 ms
   distant Region   10 round-trips ->   2410 ms
   ...
   ```

Referencia: <https://aws.amazon.com/cloudfront/features/> · <https://aws.amazon.com/about-aws/global-infrastructure/regions_az/>

### Comprobá tu comprensión — Bloque 8

- **Q8.1** — ¿Por qué "desplegá en la Región más cercana a tus usuarios" es un beneficio que el hosting on-premises rara vez puede igualar, en términos de *costo* más que técnicos?
- **Q8.2** — El PoP de borde respondió en ~8 ms y una Región en ~24 ms. ¿Por qué no podés simplemente "correr la aplicación en el borde" para todas las cargas de trabajo? Nombrá qué alojan y qué no alojan las edge locations.
- **Q8.3** — El Paso 4 muestra la latencia multiplicada por los round-trips. ¿Cuál es la lección arquitectónica para un servicio ubicado en una Región lejana, y qué beneficio de la nube de AWS te permite arreglarlo en minutos?
- **Q8.4** — Tus usuarios están en Madrid y Sídney. Esbozá, en tres líneas, los constructos de AWS que dan buena latencia a ambos, y decí qué problema nuevo introdujiste.

---

## Ejercicio 9 — Cerrar el bucle: ver el gasto variable que generaste

**Beneficio bajo prueba:** el bucle de retroalimentación de OpEx. El consumo que podés medir es consumo que podés optimizar — el mecanismo no tiene equivalente on-premises.

> El Paso 2 llama a la API de Cost Explorer, facturada a **$0.01 por solicitud**. Llamala una sola vez.

### Pasos

1. Verificá tu inscripción en el servicio gratuito de right-sizing.

   ```bash
   aws compute-optimizer get-enrollment-status --region "$AWS_REGION" \
     --query '[status,memberAccountsEnrolled]' --output text
   ```

   ```text
   Inactive	False
   ```

2. Extraé el último mes de gasto agrupado por servicio.

   ```bash
   aws ce get-cost-and-usage --region us-east-1 \
     --time-period Start=$(date -u -d '30 days ago' +%F),End=$(date -u +%F) \
     --granularity MONTHLY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
     --output text | sort -k2 -gr | head -10
   ```

   ```text
   EC2 - Other	0.0412000000
   Amazon Elastic Compute Cloud - Compute	0.0312000000
   Amazon Elastic Load Balancing	0.0169000000
   AWS Cost Explorer	0.0100000000
   Amazon Simple Storage Service	0.0000004000
   ```

   > Los datos de costo tienen un retraso de hasta 24 horas. Si los cargos del laboratorio no aparecen, es lo esperado — volvé a ejecutarlo mañana.

3. Leé el estado actual de la barrera de contención que construiste en el Ejercicio 0.

   ```bash
   aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name clf-lab-guardrail \
     --query 'Budget.[BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text
   ```

   ```text
   5.0	0.09
   ```

4. Nombrá el número. Todo el despliegue multi-AZ, balanceado, autorreparable y con escalado automático que construiste y destruiste costó menos de diez centavos, y no requirió ninguna aprobación de compras.

Referencias: <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html> · <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>

### Comprobá tu comprensión — Bloque 9

- **Q9.1** — La línea "EC2 - Other" es mayor que el propio cómputo de EC2. Nombrá dos cargos que típicamente caen ahí, y decí cuál de ellos incurrió el laboratorio.
- **Q9.2** — La propia solicitud a Cost Explorer aparece en la factura. ¿Qué principio de diseño se está ilustrando, y nombrá otra API de AWS que se facture por llamada?
- **Q9.3** — Explicá cómo la capacidad de *ver* el consumo por servicio, por hora y por tag cambia la conversación de ingeniería frente a una línea anual de depreciación de centro de datos.

---

## Ejercicio 10 — Destrucción (obligatoria)

### Pasos

1. Eliminá el Auto Scaling group; `--force-delete` termina sus instancias.

   ```bash
   aws autoscaling delete-auto-scaling-group \
     --auto-scaling-group-name clf-ha-asg --force-delete
   ```

2. Eliminá los recursos de balanceo de carga en orden de dependencia.

   ```bash
   aws elbv2 delete-listener      --listener-arn "$LISTENER_ARN"
   aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
   aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
   aws elbv2 delete-target-group  --target-group-arn "$TG_ARN"
   ```

3. Eliminá el launch template.

   ```bash
   aws ec2 delete-launch-template --launch-template-name clf-ha-lt \
     --query 'LaunchTemplate.LaunchTemplateName' --output text
   ```

4. Eliminá el security group. Va a fallar mientras haya ENIs que aún lo referencien — reintentá hasta que tenga éxito.

   ```bash
   for i in $(seq 1 12); do
     if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
       echo "sg deleted"; break
     fi
     echo "waiting for ENI release..."; sleep 20
   done
   ```

5. Vaciá y eliminá el stack de CloudFormation. El versionado está activado, así que hay que borrar todas las versiones.

   ```bash
   BUCKET=$(aws cloudformation describe-stacks --stack-name clf-agility \
     --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)

   aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
     --bucket "$BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
     --output json)" 2>/dev/null || true

   aws cloudformation delete-stack --stack-name clf-agility
   aws cloudformation wait stack-delete-complete --stack-name clf-agility
   ```

6. **Verificá que no sobrevivió nada.** Nunca confíes en un comando de borrado; verificá la ausencia.

   ```bash
   echo "--- running instances tagged clf-ha ---"
   aws ec2 describe-instances \
     --filters Name=tag:Name,Values=clf-ha \
               Name=instance-state-name,Values=pending,running,stopping,stopped \
     --query 'length(Reservations[].Instances[])'

   echo "--- load balancers ---"
   aws elbv2 describe-load-balancers --query "length(LoadBalancers[?LoadBalancerName=='clf-ha-alb'])"

   echo "--- auto scaling groups ---"
   aws autoscaling describe-auto-scaling-groups \
     --query "length(AutoScalingGroups[?AutoScalingGroupName=='clf-ha-asg'])"

   echo "--- stacks ---"
   aws cloudformation describe-stacks --stack-name clf-agility 2>&1 | grep -c "does not exist"
   ```

   ```text
   --- running instances tagged clf-ha ---
   0
   --- load balancers ---
   0
   --- auto scaling groups ---
   0
   --- stacks ---
   1
   ```

7. Opcionalmente eliminá el presupuesto (dejalo si vas a seguir estudiando).

   ```bash
   aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf-lab-guardrail
   ```

### Comprobá tu comprensión — Bloque 10

- **Q10.1** — El Paso 4 necesitó un bucle de reintentos para el security group. Explicá la dependencia subyacente y qué enseña sobre eliminar recursos de nube en general.
- **Q10.2** — ¿Cuál de los recursos que creaste en este laboratorio te habría seguido facturando indefinidamente si te hubieras ido después del Ejercicio 7? Ordenalos por costo horario.
- **Q10.3** — El Paso 6 verifica la eliminación en lugar de asumirla. Nombrá el mecanismo nativo de AWS que habría convertido toda esta destrucción en un solo comando, y por qué no aplicaba al stack ALB/ASG tal como fue construido.

---

## Respuestas

<details>
<summary><strong>Clic para expandir — clave de respuestas completa con razonamiento</strong></summary>

### Bloque 0

**A0.1 — No.** AWS Budgets es un servicio de **monitoreo y notificación**, no un tope de gasto. Exceder un umbral de presupuesto envía una notificación por SNS/correo; no limita ni termina nada. Para detener realmente el gasto necesitás **budget actions** (una configuración separada que puede aplicar una política de IAM restrictiva, detener instancias EC2/RDS o adjuntar una SCP), o controles preventivos como Service Control Policies y claves de condición de IAM que limiten los tipos de instancia. Este es el malentendido más común del examen: *los budgets alertan, las SCPs previenen.*

**A0.2** — El equivalente on-premises es el proceso de aprobación de órdenes de compra de capital. Es un control *preventivo* por accidente de latencia: no podés gastar sin una firma, y el hardware tarda semanas en llegar. Pero es estructuralmente más débil como control de *gestión* porque opera solo en el momento de la adquisición — una vez que el hardware existe, el uso incremental es invisible y gratis en el margen, así que nadie lo mide. La nube invierte esto: la adquisición es instantánea (por lo que los controles preventivos deben ser explícitos) pero el consumo se mide continuamente (por lo que los controles detectivos se vuelven genuinamente útiles).

**A0.3** — El ARN corresponde a un **usuario de IAM** — una credencial estática de larga duración. Un equipo de plataforma en producción lo marcaría porque implica claves de acceso que no rotan automáticamente. La guía actual es acceso federado vía IAM Identity Center o un rol asumido (`arn:aws:sts::...:assumed-role/...`), que emite credenciales de corta duración. Esto es material del Dominio 2, pero aparece acá porque la identidad es el sustrato sobre el que descansa cualquier otro beneficio.

---

### Bloque 1

**A1.1**
- **Región** — un área geográfica nombrada y físicamente separada (por ejemplo `eu-west-1`) que contiene múltiples Zonas de Disponibilidad; es la unidad primaria de residencia de datos y alcance de servicios. Los datos no salen de una Región a menos que los muevas explícitamente.
- **Zona de Disponibilidad** — uno o más centros de datos discretos dentro de una Región, con alimentación, refrigeración y seguridad física independientes, conectados a las otras AZs por enlaces privados de alto ancho de banda y baja latencia (típicamente de un solo dígito de milisegundos). Es la unidad de **aislamiento de fallas**.
- **Local Zone** — una extensión de una Región ubicada en un área metropolitana, que ofrece un *subconjunto* de servicios con latencia de un solo dígito de milisegundos hacia esa metrópolis. Es una unidad de **proximidad para el cómputo**.
- **Edge Location / Punto de Presencia** — un sitio de CloudFront/Route 53/Global Accelerator usado para cachear contenido y terminar conexiones cerca de los usuarios. Es una unidad de **proximidad para la entrega**, no de cómputo general.

**A1.2** — Si `us-east-1a` significara la misma zona física en cada cuenta, entonces cada cliente que use "a" por defecto concentraría carga, y el hot-spotting derrotaría todo el sentido de la distribución zonal. Aleatorizar por cuenta balancea estadísticamente el uso entre las zonas físicas. La falla concreta: sin aleatorización, la AZ física más ocupada de `us-east-1` cargaría con una proporción desmedida de toda la capacidad de los clientes, y una falla ahí tendría un radio de impacto desproporcionado.

**A1.3** — Deben intercambiar el **AZ ID** (`use1-az2`), que es consistente en todas las cuentas. Deben ignorar el **nombre de AZ** (`us-east-1c`), que tiene alcance de cuenta y por lo tanto carece de sentido como coordenada compartida. Esto importa en la práctica para los cargos de transferencia de datos entre AZs y para servicios compartidos vía AWS RAM.

**A1.4** — Un administrador habilita una Región opt-in a nivel de cuenta/organización (configuración de la cuenta, o `account enable-region`). AWS hace que las Regiones nuevas sean opt-in para que: (a) las cuentas no queden implícitamente expuestas a jurisdicciones que no evaluaron por cumplimiento/residencia de datos; (b) el radio de impacto de IAM y STS se mantenga menor por defecto; (c) las credenciales emitidas por el endpoint global de STS no sean automáticamente válidas en Regiones que el cliente nunca consideró. Es una postura segura por defecto.

**A1.5** — Una **Local Zone** (por ejemplo `us-west-2-lax-1a`) es la respuesta correcta: corre EC2, EBS y otros servicios del plano de cómputo dentro de un solo dígito de milisegundos de Los Ángeles. Una Edge Location es incorrecta para el *servidor del juego* porque las Edge Locations alojan entrega de contenido y funciones de borde — caché, terminación TLS, cómputo liviano — no cargas de trabajo de juego con estado y de propósito general. (Para un punto de entrada *sin estado* crítico en latencia, AWS Global Accelerator sobre la red de borde complementaría, no reemplazaría, a la Local Zone.)

---

### Bloque 2

**A2.1** — AWS es responsable de la **seguridad *de* la nube** (hardware, la infraestructura global, la capa de virtualización, las instalaciones físicas y la pila de software de los servicios administrados). El cliente es responsable de la **seguridad *en* la nube** (datos, identidad y acceso, configuración del SO y de la red donde esté expuesta, decisiones de cifrado, código de aplicación).
- (a) cifrar un objeto de S3 → **cliente** (AWS provee el mecanismo; elegirlo y configurarlo es tuyo)
- (b) destruir un SSD fallado → **AWS**
- (c) parchear el kernel de Linux en EC2 → **cliente**
- (d) parchear el kernel de Linux bajo RDS → **AWS**
- (e) configurar un security group → **cliente**

El par (c)/(d) es todo el punto: la *misma tarea* cambia de dueño según el modelo de servicio. Subir la escalera de abstracción (EC2 → RDS → Aurora Serverless → Lambda) transfiere responsabilidad a AWS.

**A2.2** — No asumas que la oferta es *duradera* ni *ilimitada*. `describe-instance-type-offerings` te dice que un tipo de instancia está **ofrecido** en una AZ; no dice nada sobre la capacidad disponible en este momento, y la capacidad On-Demand no está garantizada sin una Capacity Reservation. Tampoco asumas que el `us-east-1a` de tu cuenta es la misma zona física que el de otra cuenta — ver A1.3. Los diseños de producción usan Capacity Reservations, múltiples tipos de instancia en una política de instancias mixtas, o flexibilidad de tipos de instancia en el ASG, en vez de apostar a un único tipo.

**A2.3** — Desaparecen genuinamente: (1) la compra de hardware de capital y su ciclo de renovación de 3–5 años; (2) los costos de instalación — espacio de piso, energía, refrigeración, seguridad física, el generador diésel, la UPS; (3) la mano de obra de operaciones de bajo nivel: rackear, cablear, RMA de discos fallados, firmware, previsión de capacidad para adquisición de hardware.
**No** desaparece: el personal de ingeniería. El trabajo se desplaza hacia arriba — de reemplazar discos a diseñar para la falla, de planificar capacidad a optimizar costos, de parchear hipervisores a gestionar IAM. La dotación suele quedar plana; lo que cambia es qué hace esa gente. Presentar la nube como una reducción de personal es la forma clásica en que estos casos de negocio fracasan después de la migración.

---

### Bloque 3

**A3.1** — **CapEx** es una compra anticipada de un activo, depreciada a lo largo de su vida útil, que requiere aprobación antes de que el valor esté probado, y que queda hundida una vez gastada. **OpEx** es un costo operativo recurrente incurrido a medida que se consume, imputado al período y detenible.
Una ejecución de EC2 On-Demand durante 3 años es **OpEx** en términos contables — pero *económicamente* es lo peor de los dos mundos: pagás la prima de flexibilidad del On-Demand mientras exhibís el patrón de consumo de un activo comprado. Esa brecha es precisamente el arbitraje que existen para cerrar los Savings Plans y las Reserved Instances (Ejercicio 4).

**A3.2** — La **elasticidad** hace alcanzable el número de $599: la capacidad puede reducirse a cero fuera del horario laboral. El trabajo arquitectónico requerido es real, y es la parte que se saltea todo caso de negocio ingenuo: la carga de trabajo debe ser **sin estado o con estado externo** (estado en RDS/DynamoDB/S3, no en discos de instancia), el arranque debe estar automatizado (sin paso de configuración manual), el apagado debe ser seguro (drenaje de conexiones, sin trabajos en vuelo) y algo debe programarlo (una regla de EventBridge, una acción programada del ASG o una solución tipo Instance Scheduler). La elasticidad es una *capacidad de la plataforma*; realizar el ahorro es una *propiedad de tu arquitectura*.

**A3.3** — Dos razones estructurales: (1) **costos de insumos locales** — electricidad, terreno, construcción, personal, impuestos y aranceles de importación difieren dramáticamente por país, y Brasil en particular carga con una alta tributación a la importación de hardware; (2) **escala de la Región** — N. Virginia es la Región más antigua y grande de AWS, con seis AZs y un volumen agregado enorme, así que sus costos fijos se amortizan sobre mucho más uso que los de una Región más chica.
**No** contradice las economías de escala — las *demuestra*. Economías de escala significa que el costo unitario baja cuando sube el volumen; el diferencial de precio entre la Región más grande y una más chica es esa relación hecha visible. El beneficio no es "el mismo precio en todos lados", es "precios que caen con el tiempo a medida que crece el volumen, sin que renegocies nada".

**A3.4** — Economías de escala: como AWS agrega la demanda de millones de clientes, compra hardware, energía y ancho de banda a volúmenes que ningún cliente individual podría alcanzar, y amortiza costos fijos de ingeniería sobre una base enorme. El bucle de retroalimentación corre así: **más clientes → mayor volumen agregado → menor costo unitario para AWS → AWS baja precios → más clientes.** AWS ha reducido precios públicamente más de cien veces. El beneficio para vos es *pasivo*: tu factura baja sin ninguna acción de tu parte, lo que es imposible con hardware propio, donde el costo unitario queda fijo en el momento de la compra y solo sube a medida que el activo envejece.

**A3.5** — Sin esos filtros la consulta coincide con múltiples SKUs que no son comparables:
- `capacitystatus` distingue el uso ordinario (`Used`) de los SKUs de Capacity Reservation (`AllocatedCapacityReservation`, `UnusedCapacityReservation`), que tienen filas de precio distintas para el mismo tipo de instancia.
- `preInstalledSw=NA` excluye SKUs empaquetados con software licenciado (por ejemplo SQL Server), que cuestan varias veces más.
Sin ellos, `get-products` devuelve varias filas de precio y `--max-results 1` elegiría silenciosamente una arbitraria — obtendrías *un* número, confiadamente equivocado. Esta es una lección general sobre la Price List API: es un catálogo de productos, y filtros subespecificados devuelven el producto equivocado, no un error.

---

### Bloque 4

**A4.1** — Un Savings Plan te compromete a un **monto en dólares de gasto de cómputo por hora** durante 1 o 3 años. **No** te estás comprometiendo a un tipo de instancia, tamaño, familia (para el Compute SP), Región, sistema operativo, tenencia, ni siquiera al servicio — un Compute Savings Plan cubre EC2, Fargate y Lambda.
Una **Standard Reserved Instance** está ligada a la familia de instancia y a la Región (y opcionalmente a la AZ), así que cambiar tu arquitectura deja varado el compromiso. Esto importa porque el compromiso flexible preserva la mayor parte del beneficio de agilidad mientras captura la mayor parte del descuento — es un compromiso diseñado deliberadamente entre ambos, mientras que una Standard RI entrega la agilidad casi por completo.

**A4.2** — 8 h × 5 d = 40 h/semana sobre 168 → **23.8 % de utilización**. Eso está muy por debajo del punto de equilibrio de ~71 %, así que un Compute Savings Plan de 1 año para esta carga de trabajo **no se justifica**; pagarías aproximadamente tres veces el cómputo que consumís. La estrategia correcta es elasticidad (escalar a cero fuera de horario) más, si la carga tolera interrupciones, capacidad Spot. Los Savings Plans son para la *línea de base* — el piso de consumo siempre encendido — no para los picos. En una cuenta madura dimensionás el compromiso a la base 24×7 y dejás que On-Demand/Spot absorban todo lo que esté por encima.

**A4.3** — *Lo revierte parcialmente:* recreaste una obligación fija e ineludible por 1–3 años — económicamente un arrendamiento, y si tu uso se derrumba seguís pagando, que es exactamente la rigidez que imponía el CapEx.
*Lo preserva:* el compromiso es a una tasa en dólares, no a un activo físico — puede aplicarse a cualquier familia de instancia, Región o servicio de cómputo, nunca se vuelve hardware obsoleto, puede venderse en el Reserved Instance Marketplace (para Standard RIs), y puede dimensionarse solo a la porción de demanda sobre la que estás genuinamente seguro mientras el resto volátil sigue plenamente elástico. El beneficio no se elimina; se *tarifa*, y vos elegís cuánto de él revendés a cambio de un descuento.

**A4.4** — Descuento típico, de menor a mayor: **Dedicated Host On-Demand** (una prima *por encima* del On-Demand compartido — pagás un servidor físico entero) → **On-Demand** (línea de base, 0 %) → **Savings Plans / Reserved Instances** (hasta ~72 % para 3 años all-upfront) → **Spot** (hasta ~90 %).
**Spot** es la que AWS reclama, con un **aviso de interrupción de 2 minutos** entregado vía metadatos de la instancia y un evento de EventBridge. Es imbatible para trabajo tolerante a fallas, con checkpoints y sin estado (batch, CI, renderizado, big data) y queda descalificada para cualquier cosa que no pueda sobrevivir a una terminación abrupta.

---

### Bloque 5

**A5.1** — Equivalente on-premises: especificar la capacidad de almacenamiento → obtener aprobación de presupuesto → emitir la orden de compra → esperar la entrega del proveedor → rackear y cablear → instalar y configurar el SO de almacenamiento → configurar RAID/erasure coding → configurar cifrado en reposo y gestión de claves → configurar snapshots/versionado → configurar control de acceso → entregar al equipo solicitante. Plazo realista: **4 a 16 semanas**.
La línea dominante es la **adquisición** — aprobación de presupuesto más entrega del proveedor — que se mide en semanas y es casi enteramente *espera*, no trabajo. Por eso la "agilidad" es un beneficio de negocio más que técnico: el cuello de botella que se elimina nunca fue la ingeniería, fue la latencia organizacional asociada a gastar capital.

**A5.2** — El segundo componente es **la capacidad de experimentar barato y revertir decisiones.** La destrucción rápida importa porque colapsa el costo de equivocarse. Cuando aprovisionar lleva 12 semanas y cuesta $40,000, cada propuesta debe defenderse por adelantado, así que solo se financian ideas seguras y la arquitectura se calcifica alrededor de la primera conjetura. Cuando lleva 24 segundos y cuesta $0.09, probás la idea en lugar de discutirla, y la borrás sin ceremonia cuando fracasa. La agilidad es *que fracasar se vuelva barato*, y eso cambia qué decisiones se toman, no solo con qué rapidez.

**A5.3** — La **agilidad** es la velocidad a la que podés crear, cambiar y descartar infraestructura y entregar nuevas capacidades. La **elasticidad** es el ajuste automático de la capacidad aprovisionada a la demanda actual, en ambas direcciones.
Un sistema **elástico pero no ágil**: un mainframe o un gran clúster de virtualización on-premises con asignación dinámica de recursos. Reasigna CPU y memoria a las cargas automáticamente a medida que la demanda cambia (elástico dentro de su envolvente fija), pero agregar un servicio nuevo, un entorno nuevo o una geografía nueva sigue requiriendo una compra de hardware y semanas de control de cambios (no ágil). También existe el converso — una VM escalada manualmente pero aprovisionada al instante es ágil pero no elástica.

**A5.4** — `validate-template` es una comprobación **sintáctica y estructural**: parsea el JSON/YAML, verifica la anatomía de la plantilla (`Resources`, `Parameters`, uso de funciones intrínsecas) y devuelve los parámetros y capacidades declarados. No crea nada, así que no necesita que exista ningún recurso.
Sigue sin detectar: valores de propiedad inválidos para un tipo de recurso específico, referencias a recursos que no existen fuera de la plantilla, fallas de permisos de IAM, agotamiento de cuotas de servicio, colisiones de nombres (un nombre de bucket de S3 ya tomado globalmente) y cualquier error lógico de tu arquitectura. Eso solo aparece durante la operación real del stack — que es por lo que existen los **change sets** como paso intermedio entre validación y ejecución.

---

### Bloque 6

**A6.1** — **Alta disponibilidad** significa que el sistema minimiza el tiempo de inactividad y se recupera automáticamente de fallas de componentes, aceptando una degradación breve o una interrupción corta. **Tolerancia a fallas** significa que el sistema sigue operando *sin* pérdida de servicio y *sin* pérdida de capacidad cuando falla un componente — lo que requiere redundancia suficiente para que la falla sea invisible.
Este laboratorio demostró **alta disponibilidad**. Evidencia del Paso 10: cero solicitudes fallaron (bien), pero durante aproximadamente dos minutos la flota corrió sobre una **única** instancia en una AZ — la capacidad quedó a la mitad y el sistema se quedó sin redundancia. Un diseño tolerante a fallas habría mantenido la capacidad completa durante la falla, lo que acá significaría `min-size 4` entre dos AZs, de modo que perder una AZ aún deje las dos instancias necesarias para servir el pico (el patrón "N+1 por AZ" o "50 % de holgura"). La tolerancia a fallas cuesta aproximadamente el doble; la alta disponibilidad es el valor por defecto pragmático.

**A6.2** — Con AZs independientes al 99.9 % cada una, la probabilidad de que *ambas* fallen simultáneamente es 0.001 × 0.001 = 10⁻⁶, así que la disponibilidad teórica es **99.9999 %** (≈ 32 segundos de inactividad al año).
La disponibilidad real es menor porque:
1. **Las fallas no son independientes.** Planos de control regionales compartidos, una configuración o despliegue de código defectuoso empujado a ambas AZs, un error de DNS, un certificado vencido o un pico de tráfico correlacionado tumban ambas a la vez. La falla correlacionada es el término dominante en la práctica.
2. **El sistema compuesto tiene más componentes que las AZs.** El ALB, el health check del target group, el plano de control del ASG, tu aplicación y la base de datos tienen cada uno su propia disponibilidad, y las disponibilidades se multiplican en serie. Un ALB al 99.99 % delante de una capa de cómputo al 99.9999 % da como mucho 99.99 %.
La lección de ingeniería: más allá de dos AZs, agregar redundancia deja de ayudar y el factor limitante pasa a ser la gestión de cambios y el control del radio de impacto.

**A6.3** — Con `--health-check-type EC2`, el ASG considera sana a una instancia mientras pasen las **comprobaciones de estado de la instancia EC2** — el hipervisor la ve corriendo y la red alcanzable. Por lo tanto se pierde toda falla a **nivel de aplicación**: httpd se cayó, la aplicación entró en deadlock, el disco se llenó y el proceso no puede escribir, la app devuelve HTTP 500 a cada solicitud. La instancia sigue "sana" y el ALB mantiene un target roto en rotación (o, peor con solo checks `EC2`, el ASG nunca lo reemplaza).
Los health checks `ELB` delegan el juicio a la sonda HTTP del balanceador contra tu endpoint real, así que una aplicación que deja de servir se marca como no sana, se saca de rotación *y* el ASG la reemplaza. **Usá siempre health checks `ELB` para cualquier cosa detrás de un balanceador de carga** — y hacé que la ruta del health check sea una comprobación real de readiness, no un archivo estático que responde incluso cuando la app está muerta.

**A6.4** — Con `--min-size 1`, el *contrato* del ASG es "al menos una instancia". Tras la pérdida de una AZ quedaría satisfecho con la única instancia sobreviviente y no tendría obligación de mantener dos. Más importante aún, `desired-capacity` puede derivar hacia abajo hasta 1 por scale-in, punto en el cual todo el servicio queda en una sola AZ y una falla de AZ es una **caída total**, no una degradación. `--min-size 2` combinado con un `--vpc-zone-identifier` multi-AZ hace que el comportamiento de balanceo entre AZs del ASG mantenga una instancia en cada zona, de modo que ninguna falla de una sola AZ pueda llevar el servicio a cero. La regla general: **el tamaño mínimo debe ser al menos la cantidad de AZs contra cuya pérdida te estás protegiendo, multiplicada por la capacidad por AZ que necesitás.**

**A6.5**
- **`HttpTokens: required`** impone **IMDSv2**, el servicio de metadatos de instancia orientado a sesión. Requiere un `PUT` para obtener un token antes de cualquier lectura de metadatos, lo que derrota estructuralmente los ataques de server-side request forgery — una vulnerabilidad SSRF en tu aplicación no puede usarse para leer las credenciales de la instancia, porque el atacante no puede emitir el `PUT` con el encabezado requerido a través de un bug ingenuo de reenvío de solicitudes. No hay razón para correr IMDSv1 en trabajo nuevo.
- **`CpuCredits: standard`** pone las instancias burstable `t3` en modo standard en vez de modo unlimited. En modo `unlimited`, una instancia que agota sus créditos de CPU sigue corriendo a velocidad plena y **te factura un recargo** por créditos excedentes — una fuga de costos silenciosa durante exactamente el pico de carga que genera este laboratorio. El modo `standard` limita en lugar de facturar, lo que para un laboratorio es el trade correcto. (En producción la elección depende de la carga: `unlimited` suele ser lo correcto para servicios de cara al usuario con picos, donde la limitación es peor que una factura chica, y esta decisión debería ser explícita en vez de heredada del valor por defecto.)

---

### Bloque 7

**A7.1** — La **escalabilidad** es la capacidad de un sistema de manejar mayor carga agregando recursos — verticalmente (una instancia más grande) u horizontalmente (más instancias). Es una propiedad de la arquitectura y no dice nada sobre *cuándo* ni *por quién* se agregan los recursos.
La **elasticidad** es la capacidad de agregar *y quitar* esos recursos **automática y rápidamente, en respuesta a la demanda real**, de modo que la capacidad aprovisionada siga a la capacidad consumida a lo largo del tiempo.
"Podemos agregar servidores" es escalabilidad: establece que la arquitectura *puede* crecer. No es elasticidad porque le faltan las tres propiedades definitorias — automática, bidireccional y disparada por demanda. La parte bidireccional es donde está el dinero: un sistema que solo escala hacia afuera es apenas una forma más lenta de sobreaprovisionar.

**A7.2** — El **warm-up** (`--default-instance-warmup`) le indica al ASG que excluya las instancias recién lanzadas de la métrica agregada del grupo hasta que hayan estado corriendo ese período, y que todavía no las cuente como capacidad aportada.
Sin él, una instancia arrancando reporta o bien ninguna métrica de CPU o bien una no representativa (cerca de 0 % mientras instala paquetes, o cerca de 100 % durante el arranque). El promedio de CPU del grupo queda por lo tanto distorsionado inmediatamente después de un scale-out, lo que causa la patología clásica: la política ve un promedio todavía alto, lanza *más* instancias, ve caer el promedio cuando todas terminan de arrancar, y luego escala hacia adentro agresivamente — **oscilación**, también llamada thrashing o flapping. El warm-up amortigua el bucle de control ignorando el transitorio. Notá que `--estimated-instance-warmup` en la *política* es la forma obsoleta; `--default-instance-warmup` en el *grupo* es la actual y aplica uniformemente a todas las políticas y actividades de ciclo de vida.

**A7.3** — Las instancias burstable desacoplan la utilización de CPU observada del rendimiento disponible. Una `t3.micro` en modo `standard` gana créditos de CPU a una tasa fija y solo puede sostener una línea de base (~10 % de una vCPU) una vez agotados los créditos. Cuando los créditos se acaban, la instancia queda **limitada a la línea de base** — y una instancia limitada se queda clavada en "100 % de utilización de CPU" mientras hace casi nada. El target tracking sobre `ASGAverageCPUUtilization` escala entonces hacia afuera basándose en una métrica que ya no significa "ocupado", y cada instancia de reemplazo arranca con su propio saldo de créditos y repite el ciclo. En modo `unlimited` el modo de falla es financiero en su lugar: la flota nunca parece saturada y acumula silenciosamente cargos por créditos excedentes.
Mejor métrica para una capa web detrás de un ALB: **`ALBRequestCountPerTarget`** — mide el trabajo real que llega por instancia, es independiente de las rarezas de contabilidad de CPU a nivel de instancia, y mapea directamente a un modelo de capacidad sobre el que podés razonar ("cada instancia maneja N solicitudes/segundo"). Para trabajadores dirigidos por cola, el equivalente es una métrica personalizada de backlog por instancia (`ApproximateNumberOfMessagesVisible` ÷ instancias en servicio).

**A7.4** — Los dos modos de falla simétricos:
1. **Sobreaprovisionamiento** — comprar para el pico. El nombre financiero es **capital desperdiciado / baja utilización de activos**; la utilización típica on-premises es del 10–20 %, lo que significa que el 80–90 % de la compra es depreciación ociosa. Es caro pero invisible, y por eso persiste.
2. **Subaprovisionamiento** — comprar para el promedio. El nombre financiero es **costo de oportunidad**, materializado como ingresos perdidos, SLAs incumplidos y pérdida de clientes durante los picos que no lograste servir.
La trampa es que ambos son consecuencias del mismo acto: tomar una decisión de capacidad *por adelantado* con información incompleta, y después no poder revisarla durante años. La elasticidad no te hace mejor pronosticando; elimina el requisito de pronosticar.

**A7.5** — Escalar **hacia adentro** es más peligroso porque es **destructivo y asimétrico en consecuencias**. Un scale-out equivocado cuesta dinero por unos minutos; un scale-in equivocado termina instancias que estaban sirviendo tráfico, descarta solicitudes en vuelo, tira estado local y cachés (causando un pico de latencia por arranque en frío mientras las instancias restantes absorben la carga), y puede encadenarse — la flota reducida se sobrecarga, sus health checks fallan y el grupo pierde más capacidad.
Dos funcionalidades del ASG que lo hacen más seguro:
1. **Drenaje de conexiones / retraso de desregistro** en el target group, combinado con **lifecycle hooks** (`autoscaling:EC2_INSTANCE_TERMINATING`), que mantienen la instancia en estado `Terminating:Wait` para que las solicitudes en vuelo terminen y corra la limpieza antes de la terminación.
2. **Períodos de cooldown y protección contra scale-in** — los cooldowns evitan acciones sucesivas de scale-in antes de que el efecto de la anterior sea medible, y la protección de instancias contra scale-in (o `DisableScaleIn: true` en la política de target tracking, delegando el scale-in a una política separada y más conservadora) protege instancias específicas o todo el grupo de la remoción automática.

---

### Bloque 8

**A8.1** — On-premises, servir a usuarios en una nueva geografía significa **adquirir una presencia física ahí**: alquilar espacio de colocation, enviar e instalar hardware, gestionar conectividad y energía locales, cumplir requisitos regulatorios locales y contratar o dotar de soporte presencial. Eso es un compromiso de capital de decenas a cientos de miles de dólares por sitio, más un plazo de varios meses, incurrido *antes* de que sepas si el mercado vale la pena. La economía te fuerza a concentrarte en una o dos ubicaciones y aceptar mala latencia en todo el resto.
En AWS la misma expansión es un despliegue en otra Región: sin capital, sin plazo de entrega, y **el costo escala con el uso desde cero**. Podés servir a Sídney mal-y-barato hoy, descubrir la demanda y desplegar localmente mañana — y apagarlo el mes que viene si te equivocaste. El beneficio no es que AWS esté más cerca de tus usuarios; es que **probar si la cercanía vale la pena no cuesta nada.**

**A8.2** — Las edge locations están optimizadas para **entrega de contenido y terminación de conexiones**, no para cómputo general. Alojan: almacenamiento de caché y terminación TLS de CloudFront, resolución DNS de Route 53, ingreso anycast de AWS Global Accelerator, inspección de AWS WAF y Shield, y cómputo de borde acotado (CloudFront Functions — submilisegundo, JavaScript, solo manipulación de encabezados/URL; Lambda@Edge — más grande, con límites reales de tiempo de ejecución, memoria y tamaño de paquete).
**No** alojan: tu base de datos, estado persistente, procesos de larga duración, contenedores arbitrarios, ni nada que requiera conectividad a VPC. Hay cientos de PoPs precisamente *porque* son chicos y sin estado — replicar el catálogo completo de servicios y las garantías de durabilidad de una Región en cada metrópolis no es económica ni físicamente posible. Así que el patrón es: terminar y cachear en el borde, computar y persistir en una Región.

**A8.3** — La lección es que **la latencia se multiplica con la locuacidad**, y el arreglo es diseño de protocolo, no ancho de banda. Un diseño que hace 10 round-trips secuenciales para renderizar una página es imperceptible a 8 ms (80 ms) e inusable a 241 ms (2.4 segundos) — mismo código, mismo ancho de banda, distinta geografía. Las mitigaciones son agrupar solicitudes, eliminar dependencias secuenciales, cachear en el borde y mover la conversación locuaz al lado del servidor para que solo un round-trip cruce el océano.
El beneficio que te deja arreglarlo en minutos es el **alcance global combinado con agilidad**: desplegás una segunda Región, o ponés una distribución de CloudFront delante, sin comprar nada. On-premises, esa misma constatación iniciaría un ciclo de adquisición.

**A8.4** — Tres líneas:
1. Desplegar el stack en **`eu-west-1`/`eu-south-2`** y **`ap-southeast-2`** (multi-AZ dentro de cada una, como en el Ejercicio 6).
2. Poner **enrutamiento por latencia de Route 53** o **enrutamiento por geolocalización** — o **Global Accelerator** para ingreso anycast TCP/UDP — delante, para que cada usuario llegue automáticamente a la Región más cercana, con health checks para failover.
3. Servir contenido estático y cacheable a través de **CloudFront**, para que la mayoría de las solicitudes nunca cruce un océano.
El problema nuevo es el **estado**. Ahora tenés dos Regiones activas y debés decidir cómo se replican los datos: un almacén distribuido globalmente (DynamoDB global tables, Aurora Global Database, S3 Cross-Region Replication), y con eso el modelo de consistencia — conflictos last-writer-wins, retraso de replicación y cuál Región es autoritativa durante una partición. También duplicaste la superficie operativa: dos despliegues, dos conjuntos de alarmas, dos dominios de falla y una pregunta de cumplimiento sobre qué datos de usuario pueden legalmente cruzar qué frontera. El alcance global se *aprovisiona* en minutos; la **consistencia** global es una decisión arquitectónica permanente.

---

### Bloque 9

**A9.1** — "EC2 - Other" es un balde de facturación para cargos adyacentes a EC2 que no son horas de instancia. Típicamente contiene: **volúmenes y snapshots de EBS**, **transferencia de datos** (notablemente entre AZs y procesamiento de NAT Gateway), **direcciones IP elásticas** no asociadas a una instancia en ejecución, y **cargos horarios de NAT Gateway**.
Este laboratorio incurrió principalmente en **volúmenes raíz de EBS** — cada instancia que lanzó el ASG llevaba un volumen raíz gp3 de 8 GiB facturado por GiB-mes mientras existiera — más una pequeña cantidad de **transferencia de datos entre AZs**, ya que el ALB en una AZ reenvía algunas solicitudes a targets en la otra. Ambos son cargos que la gente olvida al estimar "el costo de una instancia EC2", y EBS en particular sigue facturando después de que la instancia se detiene.

**A9.2** — El principio es que **el sistema de medición es en sí mismo un servicio medido** — AWS aplica su propio modelo de consumo de forma consistente en vez de eximir a su plano de gestión. En la práctica significa que las herramientas de costos deben usarse deliberadamente: un dashboard que sondea `GetCostAndUsage` cada minuto genera una factura real, y esto pasa de verdad. Las solicitudes a Cost Explorer cuestan $0.01 cada una; usá Cost and Usage Reports (entregados a S3) para análisis de alta frecuencia.
Otras APIs facturadas por llamada incluyen las evaluaciones de reglas y los elementos de configuración de **AWS Config**, los **data events** y **Insights** de **CloudTrail**, las solicitudes a la API de **KMS** (incluida cada desencriptación) y `GetSecretValue` de **Secrets Manager**. La de KMS es la sorpresa clásica: una aplicación que desencripta un secreto en cada solicitud genera un cargo de KMS por solicitud.

**A9.3** — Cambia la conversación de un **argumento de asignación** a una **medición**. Con una línea anual de depreciación de centro de datos, el costo es un único número opaco repartido entre equipos por porcentajes negociados, así que los ingenieros no pueden ver el costo de sus propias decisiones y no tienen bucle de retroalimentación; la optimización es un ejercicio financiero anual desconectado de las personas que podrían actuar sobre él.
Con visibilidad por servicio, por hora y por tag, el costo se vuelve una **métrica de ingeniería como la latencia o la tasa de error**. Un equipo puede ver que un patrón de consultas particular sumó $400/mes, o que un NAT Gateway está costando más que la carga de trabajo detrás de él, y puede actuar dentro de un sprint en vez de un ciclo presupuestario. Este es el fundamento de FinOps y del pilar de **Optimización de Costos** del Well-Architected: la señal de gasto es lo suficientemente granular y rápida como para cerrar el bucle con la persona que escribió el código. Ese bucle de retroalimentación, no el precio unitario, es el beneficio financiero duradero de la nube.

---

### Bloque 10

**A10.1** — Un security group no se puede eliminar mientras alguna **interfaz de red elástica** siga referenciándolo. Cuando eliminás un ASG o un balanceador de carga, la API devuelve éxito ni bien la *eliminación fue iniciada* — las instancias subyacentes todavía se están terminando y las ENIs del ALB todavía existen, a veces durante varios minutos después de que el recurso desaparece de la consola.
La lección general: **la eliminación de recursos de nube es asincrónica y ordenada por dependencias.** Una respuesta exitosa de la API significa "aceptado", no "completado". Una destrucción correcta requiere entonces esperar el estado terminal (`aws ... wait ...`), eliminar en orden inverso de dependencias y reintentar las eliminaciones dependientes en vez de tratar la primera falla como fatal. Esto es exactamente por lo que existe la infraestructura declarativa como código — CloudFormation y Terraform construyen el grafo de dependencias y lo recorren al revés por vos, que es por lo que la destrucción del stack del Ejercicio 5 fue un solo comando y esta fueron seis.

**A10.2** — Ordenados por costo horario aproximado, de mayor a menor:
1. **Application Load Balancer** — ~$0.0225/hora más cargos de LCU, facturado continuamente **haya o no tráfico**. Este es el recurso olvidado clásico: parece ocioso y cuesta ~$16/mes sin hacer nada.
2. **Instancias EC2** — 2–4 × `t3.micro` a ~$0.0104/hora cada una, o sea $0.021–$0.042/hora.
3. **Volúmenes raíz de EBS** — ~8 GiB gp3 por instancia, aproximadamente $0.0009/hora cada uno. Chico, pero notá que estos **sobreviven a la terminación de la instancia si `DeleteOnTermination` es false**, y los volúmenes huérfanos son la fuente más común de desperdicio acumulado en cuentas reales.
4. **Bucket de S3** — vacío, así que efectivamente $0.00.
5. **Auto Scaling group, launch template, target group, security group, presupuesto** — $0.00; son objetos del plano de control, no recursos facturables. (Los presupuestos más allá de los primeros dos cuestan $0.02/día.)
Total si se abandona: aproximadamente **$0.06/hora ≈ $43/mes** por un laboratorio que no sirvió a ningún usuario.

**A10.3** — El mecanismo es **CloudFormation** (o CDK/Terraform): `delete-stack` elimina todos los recursos del stack en el orden de dependencias correcto, en un solo comando, sin posibilidad de dejar huérfano algo que olvidaste listar.
No aplicaba al stack ALB/ASG porque ese stack fue construido **imperativamente**, recurso por recurso mediante llamadas individuales a la CLI. Nada registró las relaciones entre el security group, el launch template, el target group, el balanceador de carga, el listener y el Auto Scaling group, así que la destrucción tuvo que reconstruir ese grafo de dependencias a mano — que es precisamente donde quedan recursos huérfanos en cuentas reales. El ejercicio se construyó imperativamente a propósito, para que cada llamada a la API y su costo fueran visibles; **la infraestructura de producción no debería serlo.** La regla: si un recurso es facturable y de larga vida, pertenece a un stack, porque el valor de la infraestructura como código se muestra tanto al momento de eliminar como al de crear.

</details>

---

## Referencias

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Six Advantages of Cloud Computing — <https://docs.aws.amazon.com/whitepapers/latest/aws-overview/six-advantages-of-cloud-computing.html>
- AWS Global Infrastructure — <https://aws.amazon.com/about-aws/global-infrastructure/>
- Regions and Availability Zones (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html>
- Availability Zone IDs — <https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html>
- Public parameters for global infrastructure — <https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- Price List Query API (`GetProducts`) — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html>
- Savings Plans User Guide — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Target tracking scaling policies — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html>
- Auto Scaling health checks — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html>
- Burstable performance instances — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>
- Application Load Balancer — <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html>
- Instance Metadata Service v2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- AWS CloudFormation User Guide — <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html>
- Managing costs with AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
- Cost Explorer `GetCostAndUsage` — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html>
- AWS Compute Optimizer — <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>
- Well-Architected Framework, Reliability Pillar — <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html>
- Amazon CloudFront features (edge network) — <https://aws.amazon.com/cloudfront/features/>
- AWS Free Tier — <https://aws.amazon.com/free/>