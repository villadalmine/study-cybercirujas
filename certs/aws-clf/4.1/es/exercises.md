# Ejercicios — 4.1 Comparar los modelos de precios de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 4:** Facturación, precios y soporte · **Peso del dominio en el examen:** 12% · **Este objetivo:** ~4%

**Lo que vas a poder hacer cuando termines:** derivar cualquier precio de AWS desde una fuente autoritativa legible por máquina en lugar de un blog; calcular el punto de equilibrio de un compromiso; explicar *por qué* una carga de trabajo pertenece a Spot, On-Demand, una Reserved Instance, un Savings Plan o un Dedicated Host; y separar las tres dimensiones de facturación — **cómputo, almacenamiento, transferencia de datos** — en las que se descompone toda factura de AWS.

---

## 0. Preparación y seguridad

> **Toda cifra en dólares impresa en este documento es una instantánea ilustrativa para `us-east-1`.** AWS cambia los precios, y los precios difieren por Región. El objetivo de estos ejercicios es que nunca confíes en un número memorizado — consultás la Price List API y leés el valor de hoy. Tus salidas *van a* diferir de las de ejemplo; eso es esperable y es parte de la lección.

**Costo de correr estos ejercicios:** la Price List API, las llamadas `describe-*`, Compute Optimizer y la AWS Pricing Calculator son **gratis**. Dos llamadas del Ejercicio 9 usan la **Cost Explorer API, que se factura a $0.01 por request** — un puñado de llamadas cuesta unos centavos. Nada acá lanza un recurso facturable. Sí vas a *crear* un AWS Budget (los primeros dos presupuestos por cuenta son gratis).

### Pasos

1. Verificá que tenés AWS CLI v2:

```bash
aws --version
```

```text
aws-cli/2.31.10 Python/3.13.4 linux/6.9.0 exe/x86_64.fedora.44
```

2. Verificá tu identidad y anotá tu ID de cuenta — lo vas a necesitar después:

```bash
aws sts get-caller-identity --output table
```

```text
------------------------------------------------------------------
|                        GetCallerIdentity                       |
+-------------+--------------------------------------------------+
|  Account    |  111122223333                                    |
|  Arn        |  arn:aws:iam::111122223333:user/pricing-lab      |
|  UserId     |  AIDAEXAMPLEUSERID                               |
+-------------+--------------------------------------------------+
```

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

3. Adjuntá esta política de **solo lectura** al principal que estés usando. Nada en ella puede crear, modificar ni eliminar un recurso facturable, excepto `budgets:*`, que está acotado a objetos de presupuesto:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PriceDiscovery",
      "Effect": "Allow",
      "Action": [
        "pricing:DescribeServices",
        "pricing:GetAttributeValues",
        "pricing:GetProducts",
        "pricing:ListPriceLists",
        "pricing:GetPriceListFileUrl",
        "savingsplans:DescribeSavingsPlansOfferings",
        "savingsplans:DescribeSavingsPlansOfferingRates",
        "savingsplans:DescribeSavingsPlans",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeReservedInstancesOfferings",
        "ec2:DescribeHostReservationOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:GetSpotPlacementScores",
        "compute-optimizer:GetEC2InstanceRecommendations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BillingRead",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetSavingsPlansPurchaseRecommendation",
        "ce:GetReservationPurchaseRecommendation",
        "ce:GetSavingsPlansUtilization",
        "ce:GetReservationCoverage",
        "freetier:GetFreeTierUsage",
        "budgets:ViewBudget",
        "budgets:DescribeBudgets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BudgetGuardrail",
      "Effect": "Allow",
      "Action": ["budgets:CreateBudget", "budgets:DeleteBudget", "budgets:ModifyBudget"],
      "Resource": "arn:aws:budgets::111122223333:budget/*"
    }
  ]
}
```

4. Instalá `jq` (la Price List API devuelve strings codificados en JSON dentro de JSON; acá `jq` no es opcional):

```bash
jq --version   # jq-1.7.1
```

5. Fijá las variables que se usan a lo largo de todo el documento:

```bash
export PRICING_REGION=us-east-1        # Price List API endpoint Region
export TARGET_REGION=us-east-1         # Region whose prices we are studying
export ITYPE=m6i.large
export HOURS_MONTH=730                 # AWS's own convention: 8760 / 12
export HOURS_YEAR=8760
```

> **Trampa del endpoint:** la Price List Query API y la Free Tier API solo se sirven desde un conjunto acotado de Regiones (`us-east-1`, `eu-central-1`, `ap-south-1` para pricing). `--region us-east-1` en un comando `pricing` selecciona *el endpoint*, **no** la Región cuyos precios obtenés. La Región que estás cotizando es un **filtro** (`regionCode` / `location`).

### Checkpoint 0

1. Corrés `aws pricing get-products --region eu-west-1 ...` y falla con un error de endpoint, y sin embargo `--region us-east-1` funciona y devuelve precios de Tokio. Explicá ambos hechos en una sola oración.
2. ¿En cuál de las tres dimensiones de facturación (cómputo, almacenamiento, transferencia de datos) te permite *incurrir* en un cargo la política IAM de arriba? Justificá.
3. ¿Por qué AWS usa 730 horas por mes en sus propias calculadoras en lugar de 720?

---

## Ejercicio 1 — Leer un precio desde la fuente de verdad

**Objetivo:** dejar de tratar "el precio de una m6i.large" como un número único y empezar a tratarlo como una *coordenada en un espacio de producto multidimensional*.

### Pasos

1. Confirmá qué servicios exponen una lista de precios, y por cuántos atributos se indexan los precios de EC2:

```bash
aws pricing describe-services --service-code AmazonEC2 \
  --region "$PRICING_REGION" \
  --query 'Services[0].AttributeNames' --output json | jq 'length, .[0:12]'
```

```json
64
[
  "volumeType", "maxIopsvolume", "instanceCapacity10xlarge", "locationType",
  "instanceFamily", "operatingSystem", "clockSpeed", "LeaseContractLength",
  "ecu", "networkPerformance", "instanceType", "tenancy"
]
```

2. Preguntá qué valores legales toma uno de esos atributos. Así es como descubrís el vocabulario que usa el propio AWS:

```bash
aws pricing get-attribute-values --service-code AmazonEC2 \
  --attribute-name tenancy --region "$PRICING_REGION" \
  --query 'AttributeValues[].Value' --output text
```

```text
Dedicated	Host	NA	Reserved	Shared
```

3. Ahora fijá **todas** las dimensiones hasta que quede exactamente un producto. Omitir cualquiera de ellas devuelve decenas de SKUs y es el error más común al scriptear contra esta API:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters \
    "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
    "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
    'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
    'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
    'Type=TERM_MATCH,Field=licenseModel,Value=No License required' \
    'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
  --output json > /tmp/m6i-large.json

jq '.PriceList | length' /tmp/m6i-large.json
```

```text
1
```

4. Extraé la tarifa On-Demand. Fijate en el `fromjson` — cada elemento de `PriceList` es un *string* que contiene JSON:

```bash
jq -r '.PriceList[] | fromjson
       | .terms.OnDemand[].priceDimensions[]
       | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"' /tmp/m6i-large.json
```

```text
0.0960000000	Hrs	$0.096 per On Demand Linux m6i.large Instance Hour
```

5. El *mismo* SKU también lleva todos los términos de compromiso. Listalos:

```bash
jq -r '.PriceList[] | fromjson | .terms.Reserved[]
       | [.termAttributes.LeaseContractLength,
          .termAttributes.OfferingClass,
          .termAttributes.PurchaseOption] | @tsv' /tmp/m6i-large.json | sort -u
```

```text
1yr	convertible	All Upfront
1yr	convertible	No Upfront
1yr	convertible	Partial Upfront
1yr	standard	All Upfront
1yr	standard	No Upfront
1yr	standard	Partial Upfront
3yr	convertible	All Upfront
3yr	convertible	No Upfront
3yr	convertible	Partial Upfront
3yr	standard	All Upfront
3yr	standard	No Upfront
3yr	standard	Partial Upfront
```

6. Normalizá el precio por capacidad, que es lo que realmente importa al comparar familias:

```bash
aws ec2 describe-instance-types --instance-types "$ITYPE" --region "$TARGET_REGION" \
  --query 'InstanceTypes[0].{vCPU:VCpuInfo.DefaultVCpus,MemGiB:MemoryInfo.SizeInMiB,Net:NetworkInfo.NetworkPerformance}' \
  --output table
```

```text
-------------------------------------------
|          DescribeInstanceTypes          |
+---------+-----------+-------------------+
| MemGiB  |    Net    |       vCPU        |
+---------+-----------+-------------------+
|  8192   | Up to 12.5 Gigabit|  2         |
+---------+-----------+-------------------+
```

`$0.096 / 2 vCPU = $0.048 per vCPU-hour`.

7. Repetí el paso 3 para una segunda Región y comparé la tarifa:

```bash
for r in us-east-1 eu-central-1 sa-east-1; do
  p=$(aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
      "Type=TERM_MATCH,Field=regionCode,Value=$r" \
      'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
      'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
      'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
      'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --query 'PriceList[0]' --output text \
    | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
  printf '%-14s %s USD/hr\n' "$r" "$p"
done
```

```text
us-east-1      0.0960000000 USD/hr
eu-central-1   0.1070000000 USD/hr
sa-east-1      0.1530000000 USD/hr
```

8. Para análisis offline o masivo, bajá la lista de precios completa como archivo en lugar de paginar la Query API:

```bash
ARN=$(aws pricing list-price-lists --service-code AmazonEC2 \
  --effective-date "$(date -u +%Y-%m-01T00:00:00Z)" \
  --currency-code USD --region-code "$TARGET_REGION" \
  --region "$PRICING_REGION" --query 'PriceLists[0].PriceListArn' --output text)

aws pricing get-price-list-file-url --price-list-arn "$ARN" \
  --file-format csv --region "$PRICING_REGION" --output text
```

```text
https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260901000000/us-east-1/index.csv
```

### Checkpoint 1

1. En el paso 3, ¿qué selecciona `capacitystatus=Used`, y qué otros dos valores existen? ¿Qué estarías cotizando si eligieras alguno de ellos?
2. ¿Por qué tenés que filtrar por `preInstalledSw` y `licenseModel` incluso para Linux puro? ¿Qué modelo de negocio codifican esos dos atributos?
3. El mismo tipo de instancia física cuesta 59% más en `sa-east-1` que en `us-east-1`. Nombrá dos razones estructurales por las que AWS fija precios distintos por Región, y enunciá la decisión arquitectónica que este hecho debería alimentar.
4. Un colega hardcodea `0.096` en un script de chargeback. Dá dos modos de falla distintos de ese script.
5. `m6i.large` tiene 2 vCPU a $0.096/hr. `m6i.xlarge` tiene 4 vCPU. Sin consultar, predecí su precio On-Demand y enunciá el principio de precios que te permite predecirlo. ¿Se sostiene el mismo principio entre *familias* (por ejemplo `m6i` vs `c6i`)?

---

## Ejercicio 2 — On-Demand vs Reserved Instances: el cálculo del punto de equilibrio

**Objetivo:** derivar, no memorizar, cuándo un compromiso se paga solo.

### Pasos

1. Llevá la tarifa On-Demand en vivo a una variable de shell:

```bash
OD=$(jq -r '.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD' /tmp/m6i-large.json)
echo "On-Demand: $OD"
```

```text
On-Demand: 0.0960000000
```

2. Extraé todos los términos **standard** de 1 año con sus componentes de pago inicial y por hora. Una Reserved Instance tiene *dos* dimensiones de precio — `Quantity` (el pago inicial, unidad `Quantity`) y `Hrs` (la tarifa recurrente):

```bash
jq -r '.PriceList[] | fromjson | .terms.Reserved[]
  | select(.termAttributes.LeaseContractLength=="1yr" and .termAttributes.OfferingClass=="standard")
  | . as $t | .priceDimensions[]
  | [$t.termAttributes.PurchaseOption, .unit, .pricePerUnit.USD] | @tsv' /tmp/m6i-large.json | sort
```

```text
All Upfront	Quantity	511.0000000000
All Upfront	Hrs	0.0000000000
No Upfront	Hrs	0.0605000000
No Upfront	Quantity	0.0000000000
Partial Upfront	Quantity	253.0000000000
Partial Upfront	Hrs	0.0289000000
```

3. Confirmá las mismas ofertas a través de la API de EC2, que es la que efectivamente llamarías para *comprar*:

```bash
aws ec2 describe-reserved-instances-offerings --region "$TARGET_REGION" \
  --instance-type "$ITYPE" --product-description "Linux/UNIX" \
  --offering-class standard --offering-type "No Upfront" \
  --instance-tenancy default --no-include-marketplace \
  --filters Name=duration,Values=31536000 Name=scope,Values=Region \
  --query 'ReservedInstancesOfferings[0].{Id:ReservedInstancesOfferingId,Fixed:FixedPrice,Hourly:RecurringCharges[0].Amount,Scope:Scope,Class:OfferingClass}' \
  --output table
```

```text
------------------------------------------------------------------------------
|                       DescribeReservedInstancesOfferings                    |
+---------+---------+--------------------------------------+--------+---------+
|  Class  | Fixed   |                 Id                   | Hourly | Scope   |
+---------+---------+--------------------------------------+--------+---------+
| standard|  0.0    | 4b2293b4-5813-4cc8-9ce3-1957dcEXAMPLE |  0.0605| Region  |
+---------+---------+--------------------------------------+--------+---------+
```

4. Calculá la **tarifa horaria efectiva** de cada opción de compra. La fórmula es todo el ejercicio:

```
effective_hourly = (upfront / hours_in_term) + recurring_hourly
```

```bash
python3 - <<'PY'
OD = 0.0960
H1, H3 = 8760, 26280
offers = [
    ("On-Demand",                    0.0,    OD,     H1),
    ("1yr std No Upfront",           0.0,    0.0605, H1),
    ("1yr std Partial Upfront",    253.0,    0.0289, H1),
    ("1yr std All Upfront",        511.0,    0.0000, H1),
    ("3yr std All Upfront",        997.0,    0.0000, H3),
    ("3yr convertible All Upfront",1180.0,   0.0000, H3),
]
print(f"{'Option':<30}{'Eff $/hr':>10}{'Disc':>8}{'$/month':>10}{'Break-even':>12}")
for name, up, hr, h in offers:
    eff = up / h + hr
    print(f"{name:<30}{eff:>10.4f}{1-eff/OD:>7.0%}{eff*730:>10.2f}{eff/OD:>11.0%}")
PY
```

```text
Option                          Eff $/hr    Disc   $/month  Break-even
On-Demand                         0.0960      0%     70.08        100%
1yr std No Upfront                0.0605     37%     44.17         63%
1yr std Partial Upfront           0.0578     40%     42.17         60%
1yr std All Upfront               0.0583     39%     42.58         61%
3yr std All Upfront               0.0379     60%     27.69         39%
3yr convertible All Upfront       0.0449     53%     32.78         47%
```

La última columna es la **utilización de equilibrio**: la fracción del término que la instancia debe correr efectivamente antes de que el compromiso le gane a pagar On-Demand.

5. Modelá una carga de trabajo que *no* está siempre encendida — una flota de CI que corre 10 h/día, 22 días/mes (≈ 30% de utilización):

```bash
python3 - <<'PY'
hours_used = 10*22*12          # 2640 h over one year
print(f"On-Demand   : ${hours_used*0.0960:>8.2f}")
print(f"1yr NU RI   : ${8760*0.0605:>8.2f}   (billed 8760 h regardless of use)")
print(f"1yr AU RI   : ${511.0:>8.2f}   (sunk on day 1)")
PY
```

```text
On-Demand   : $  253.44
1yr NU RI   : $  529.98   (billed 8760 h regardless of use)
1yr AU RI   : $  511.00   (sunk on day 1)
```

6. Verificá la **flexibilidad de tamaño de instancia**. Una RI *regional*, Linux, tenancy por defecto, standard, flota entre tamaños de su familia usando factores de normalización:

| Tamaño | nano | micro | small | medium | large | xlarge | 2xlarge | 4xlarge | 8xlarge | 12xlarge | 16xlarge | 24xlarge |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Factor | 0.25 | 0.5 | 1 | 2 | **4** | 8 | 16 | 32 | 64 | 96 | 128 | 192 |

Una RI de `m6i.xlarge` (factor 8) cubre por completo dos instancias `m6i.large` concurrentes (4 + 4 = 8).

### Checkpoint 2

1. Una RI No Upfront no tiene costo inicial. ¿Por qué su utilización de equilibrio sigue siendo 63% y no 0%? ¿Qué obligación firmaste realmente?
2. Ordená las tres opciones de pago por descuento y explicá el mecanismo que produce ese ordenamiento.
3. Tu flota de CI del paso 5 corre el 30% de las horas. ¿Qué modelo de precios debería usar, y qué modelo debería usar el *repositorio de artefactos de build* que está detrás?
4. Dá dos situaciones concretas en las que una RI **Convertible** vale su descuento más chico frente a una RI Standard. ¿Qué operación permite la Convertible que la Standard no, y qué operación permite la Standard que la Convertible no?
5. ¿Qué te compra `Scope: Region` y qué te cuesta, comparado con `Scope: Availability Zone`?
6. Tenés una RI regional Linux `m6i.2xlarge` y estás corriendo cuatro `m6i.large`. ¿Tu cobertura es completa? Mostrá la aritmética. Ahora la carga de trabajo se muda a `c6i.large` — ¿qué pasa con tu RI?
7. ¿Por qué la flexibilidad de tamaño de instancia *no* aplica a una RI de Windows ni a una RI zonal?

---

## Ejercicio 3 — Savings Plans: comprometerse con dinero, no con máquinas

**Objetivo:** internalizar la única diferencia estructural — una RI es un compromiso con una *forma de recurso*; un Savings Plan es un compromiso con un *dólar-por-hora de gasto*.

### Pasos

1. Listá las ofertas de Savings Plan disponibles para un compromiso de 1 año, No Upfront:

```bash
aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types Compute --durations 31536000 --payment-options "No Upfront" \
  --currencies USD \
  --query 'searchResults[0].{Offering:offeringId,Plan:planType,Secs:durationSeconds,Pay:paymentOption}' \
  --output table
```

```text
--------------------------------------------------------------------------
|                      DescribeSavingsPlansOfferings                     |
+-----------+--------------------------------------+------------+--------+
|   Pay     |               Offering               |    Plan    | Secs   |
+-----------+--------------------------------------+------------+--------+
| No Upfront|  87654321-abcd-4321-abcd-0123456789ab|  Compute   | 31536000|
+-----------+--------------------------------------+------------+--------+
```

```bash
OFFER=$(aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types Compute --durations 31536000 --payment-options "No Upfront" \
  --currencies USD --query 'searchResults[0].offeringId' --output text)
```

2. Obtené la **tarifa con descuento** que este plan aplica a nuestra instancia específica:

```bash
aws savingsplans describe-savings-plans-offering-rates --region "$PRICING_REGION" \
  --savings-plan-offering-ids "$OFFER" --service-codes AmazonEC2 \
  --filters name=instanceType,values="$ITYPE" name=region,values="$TARGET_REGION" \
           name=tenancy,values=shared name=productDescription,values="Linux/UNIX" \
  --query 'searchResults[0].{Rate:rate,Unit:unit,Usage:usageType,Op:operation}' \
  --output table
```

```text
-------------------------------------------------------------------
|              DescribeSavingsPlansOfferingRates                  |
+---------+--------------+-----------+--------------------------- +
|   Op    |    Rate      |   Unit    |          Usage             |
+---------+--------------+-----------+----------------------------+
| RunInstances|  0.0655  |   Hrs     |  BoxUsage:m6i.large        |
+---------+--------------+-----------+----------------------------+
```

3. Repetí para un **EC2 Instance Savings Plan**, que canjea flexibilidad por un descuento más profundo:

```bash
EC2SP=$(aws savingsplans describe-savings-plans-offerings --region "$PRICING_REGION" \
  --plan-types EC2Instance --durations 31536000 --payment-options "No Upfront" \
  --currencies USD --filters name=instanceFamily,values=m6i name=region,values="$TARGET_REGION" \
  --query 'searchResults[0].offeringId' --output text)

aws savingsplans describe-savings-plans-offering-rates --region "$PRICING_REGION" \
  --savings-plan-offering-ids "$EC2SP" --service-codes AmazonEC2 \
  --filters name=instanceType,values="$ITYPE" name=tenancy,values=shared \
  --query 'searchResults[0].rate' --output text
```

```text
0.0605
```

4. Construí la tabla comparativa completa para una instancia siempre encendida:

```bash
python3 - <<'PY'
OD = 0.0960
rows = [
  ("On-Demand",                 OD,     "any",              "none"),
  ("Compute SP 1yr NU",         0.0655, "any family/Region/OS/tenancy + Fargate + Lambda", "$/hr for 1yr"),
  ("EC2 Instance SP 1yr NU",    0.0605, "m6i family, us-east-1, any size/OS/AZ",           "$/hr for 1yr"),
  ("Standard RI 1yr NU",        0.0605, "m6i family, us-east-1, Linux, size-flexible",     "capacity+$ for 1yr"),
  ("Compute SP 3yr AU",         0.0410, "same as Compute SP",                              "$/hr for 3yr"),
  ("Spot",                      0.0350, "interruptible only",                              "none"),
]
for n, r, flex, commit in rows:
    print(f"{n:<24}{r:>8.4f}  {1-r/OD:>4.0%}  {commit:<20} {flex}")
PY
```

```text
On-Demand                 0.0960     0%  none                 any
Compute SP 1yr NU         0.0655    32%  $/hr for 1yr         any family/Region/OS/tenancy + Fargate + Lambda
EC2 Instance SP 1yr NU    0.0605    37%  $/hr for 1yr         m6i family, us-east-1, any size/OS/AZ
Standard RI 1yr NU        0.0605    37%  capacity+$ for 1yr   m6i family, us-east-1, Linux, size-flexible
Compute SP 3yr AU         0.0410    57%  $/hr for 3yr         same as Compute SP
Spot                      0.0350    64%  interruptible only   interruptible only
```

5. Entendé la **aritmética del compromiso**. No comprás "3 instancias"; comprás "$0.20/hora":

```bash
python3 - <<'PY'
commit   = 0.20          # $/hr you sign up for
sp_rate  = 0.0655        # discounted rate per instance-hour
od_rate  = 0.0960
covered  = commit / sp_rate
print(f"Commitment ${commit}/hr covers {covered:.2f} m6i.large-hours per hour")
for running in (2, 3, 4):
    used   = min(running * sp_rate, commit)
    unused = commit - used
    over   = max(0, running - commit/sp_rate) * od_rate
    print(f"  running {running}: SP charge ${commit:.4f} "
          f"(wasted ${unused:.4f}) + On-Demand overflow ${over:.4f} "
          f"= ${commit+over:.4f}/hr")
PY
```

```text
Commitment $0.2/hr covers 3.05 m6i.large-hours per hour
  running 2: SP charge $0.2000 (wasted $0.0690) + On-Demand overflow $0.0000 = $0.2000/hr
  running 3: SP charge $0.2000 (wasted $0.0035) + On-Demand overflow $0.0000 = $0.2000/hr
  running 4: SP charge $0.2000 (wasted $0.0000) + On-Demand overflow $0.0911 = $0.2911/hr
```

6. Inspeccioná los Savings Plans que ya tengas (devuelve una lista vacía si no hay ninguno):

```bash
aws savingsplans describe-savings-plans --region "$PRICING_REGION" \
  --query 'savingsPlans[].{Id:savingsPlanId,Type:savingsPlanType,Commit:commitment,State:state,End:end}' \
  --output table
```

### Checkpoint 3

1. Enunciá en una oración la diferencia entre a qué te compromete una RI y a qué te compromete un Savings Plan.
2. Un Compute Savings Plan da 32% de descuento y un EC2 Instance Savings Plan 37%, para la misma instancia. Nombrá tres cambios concretos en tu arquitectura que el plan Compute absorbería sin penalidad y el plan EC2 Instance no.
3. En el paso 5, con 4 instancias corriendo, ¿por qué el total es $0.2911/hr y no $0.2620/hr (4 × $0.0655)?
4. Tu compromiso es de $0.20/hr y corrés solo 2 instancias todo el mes. ¿Cuánto dinero se desperdicia por mes, y qué implica eso sobre cómo deberías *dimensionar* un compromiso?
5. ¿Qué servicios de cómputo además de EC2 cubre un Compute Savings Plan? ¿Qué modelo de precios usarías para un servicio basado en Fargate que corre continuamente?
6. Ni las RIs ni los Savings Plans reducen el *precio* de una instancia en ejecución en el sentido de la factura — se aplican como un descuento en el momento de facturar. ¿Qué consecuencia operativa se sigue para un equipo que compra una RI en la Cuenta A de una AWS Organization mientras la instancia corre en la Cuenta B?
7. Tu carga de trabajo es estable pero esperás migrar de x86 a Graviton (`m7g`) dentro de nueve meses. Compará una RI Standard de 3 años, un EC2 Instance Savings Plan de 3 años y un Compute Savings Plan de 3 años para este caso.

---

## Ejercicio 4 — Spot Instances: ponerle precio al riesgo de interrupción

### Pasos

1. Traé una semana de historial de precios Spot y observá lo estable que es el pricing Spot moderno:

```bash
aws ec2 describe-spot-price-history --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[?AvailabilityZone==`us-east-1a`].[Timestamp,SpotPrice]' \
  --output text | sort | head -5
```

```text
2026-08-28T00:12:41+00:00	0.034500
2026-08-29T13:04:07+00:00	0.035100
2026-08-31T06:41:22+00:00	0.034800
2026-09-02T09:55:13+00:00	0.036200
2026-09-03T18:20:04+00:00	0.035700
```

2. Calculá el descuento actual por Zona de Disponibilidad — los precios Spot son **por AZ**, y la dispersión suele ser mayor de lo que la gente espera:

```bash
aws ec2 describe-spot-price-history --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text \
| while read -r az price; do
    printf '%-14s %s  (%.0f%% off On-Demand)\n' "$az" "$price" \
      "$(python3 -c "print((1-$price/0.096)*100)")"
  done
```

```text
us-east-1a     0.035700  (63% off On-Demand)
us-east-1b     0.038900  (59% off On-Demand)
us-east-1c     0.034100  (64% off On-Demand)
us-east-1d     0.041200  (57% off On-Demand)
```

3. Preguntale a AWS qué tan probable es que haya capacidad disponible, antes de diseñar alrededor de eso:

```bash
aws ec2 get-spot-placement-scores --region "$TARGET_REGION" \
  --instance-types "$ITYPE" --target-capacity 20 --target-capacity-unit-type vcpu \
  --region-names us-east-1 us-west-2 eu-west-1 \
  --query 'SpotPlacementScores[].{Region:Region,Score:Score}' --output table
```

```text
------------------------
| GetSpotPlacementScores|
+-------------+--------+
|   Region    | Score  |
+-------------+--------+
|  us-west-2  |  10    |
|  us-east-1  |   8    |
|  eu-west-1  |   6    |
+-------------+--------+
```

4. Ponéle precio al *riesgo*, no solo a la tarifa. Un trabajo por lotes de 1.000 horas-instancia con una probabilidad de interrupción horaria del 5% y una pérdida de trabajo promedio de 12 minutos por interrupción:

```bash
python3 - <<'PY'
hours, od, spot, p_int, rework_h = 1000, 0.0960, 0.0357, 0.05, 0.20
wasted = hours * p_int * rework_h
eff_hours = hours + wasted
print(f"On-Demand           : ${hours*od:8.2f}")
print(f"Spot (naive)        : ${hours*spot:8.2f}")
print(f"Spot + {wasted:.0f} h rework : ${eff_hours*spot:8.2f}  "
      f"-> real saving {1-eff_hours*spot/(hours*od):.0%}")
PY
```

```text
On-Demand           : $   96.00
Spot (naive)        : $   35.70
Spot + 10 h rework  : $   36.06  -> real saving 62%
```

5. Ahora rehacé el cálculo con un trabajo que **no puede hacer checkpoint**, de modo que una interrupción pierde toda la ejecución hecha hasta ese momento (en promedio, 50% de un trabajo de 6 horas):

```bash
python3 - <<'PY'
job_h, od, spot, p_int_job = 6, 0.0960, 0.0357, 0.26   # ~26% chance over 6 h at 5%/h
expected_runs = 1/(1-p_int_job)
print(f"expected attempts: {expected_runs:.2f}")
print(f"Spot cost: ${expected_runs*job_h*spot + expected_runs*p_int_job*job_h*0.5*spot:8.2f}")
print(f"OD   cost: ${job_h*od:8.2f}")
PY
```

```text
expected attempts: 1.35
Spot cost: $    0.33
OD   cost: $    0.58
```

### Checkpoint 4

1. ¿Qué notificación envía AWS antes de reclamar una Spot Instance, cuánto aviso da, y qué señal más temprana existe?
2. Los precios Spot del paso 2 varían un 21% entre `us-east-1b` y `us-east-1c` en el mismo instante. ¿Qué representa físicamente esa dispersión, y qué te indica hacer con la configuración de tu Auto Scaling group?
3. Clasificá cada uno como apto o no apto para Spot, con una razón cada uno: (a) un ETL Spark nocturno con checkpointing a S3, (b) un gateway WebSocket con estado que mantiene sesiones de usuario, (c) un pool de agentes de build de Jenkins, (d) el nodo primario de un clúster PostgreSQL autoadministrado, (e) renderizado de imágenes disparado por CI.
4. En el paso 5, Spot gana igual incluso sin checkpointing. ¿Qué entrada tendría que cambiar para que ganara On-Demand, y qué te dice eso sobre *dónde* invertir esfuerzo de ingeniería?
5. ¿Puede aplicarse el descuento de un Savings Plan o de una Reserved Instance al uso de Spot? Explicá por qué la respuesta se sigue de lo que cada mecanismo realmente es.
6. Una Spot Instance es interrumpida. Nombrá los tres comportamientos de interrupción que AWS puede aplicar y cuál preserva los datos del volumen EBS raíz.

---

## Ejercicio 5 — Tenancy y licenciamiento: Shared, Dedicated Instance, Dedicated Host

### Pasos

1. Cotizá la misma instancia bajo las tres tenancies:

```bash
for t in Shared Dedicated; do
  p=$(aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$ITYPE" \
      "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
      'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
      "Type=TERM_MATCH,Field=tenancy,Value=$t" \
      'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
      'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --query 'PriceList[0]' --output text \
    | jq -r '.terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
  printf '%-12s %s USD/hr\n' "$t" "$p"
done
```

```text
Shared       0.0960000000 USD/hr
Dedicated    0.1056000000 USD/hr
```

2. Cotizá un **Dedicated Host**, que se factura por *host*, no por instancia:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters 'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
    "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=tenancy,Value=Host' \
    'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
    'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
  --query 'PriceList[0]' --output text \
  | jq -r '.product.attributes | {instanceFamily, physicalCores: .physicalCores, sockets: .physicalProcessor}'
```

3. Listá las ofertas de **reserva** de Dedicated Host — el mecanismo de compromiso que existe específicamente para la tenancy de host:

```bash
aws ec2 describe-host-reservation-offerings --region "$TARGET_REGION" \
  --filter Name=instance-family,Values=m6i \
  --query 'OfferingSet[?PaymentOption==`NoUpfront` && Duration==`31536000`].{Id:OfferingId,Hourly:HourlyPrice,Upfront:UpfrontPrice,Pay:PaymentOption}' \
  --output table
```

```text
--------------------------------------------------------------------
|                  DescribeHostReservationOfferings                |
+------------+--------------------------------------+-----+--------+
|  Hourly    |                  Id                  | Pay | Upfront|
+------------+--------------------------------------+-----+--------+
|  2.5220    | hro-03f707bf363b6b324                |NoUpfront| 0.00|
+------------+--------------------------------------+-----+--------+
```

4. Compará el costo total de 20 `m6i.large` en tenancy compartida contra un Dedicated Host que las contenga:

```bash
python3 - <<'PY'
shared_each, host_hourly, n = 0.0960, 2.5220, 20
print(f"20x shared      : ${shared_each*n*730:8.2f}/month")
print(f"1x ded. host    : ${host_hourly*730:8.2f}/month  (fixed, regardless of instances placed)")
print(f"break-even at   : {host_hourly/shared_each:.1f} instances")
PY
```

```text
20x shared      : $ 1401.60/month
1x ded. host    : $ 1841.06/month  (fixed, regardless of instances placed)
break-even at   : 26.3 instances
```

### Checkpoint 5

1. La tenancy Dedicated Instance cuesta 10% más que Shared para la misma instancia. ¿Qué estás comprando con ese 10%, y qué *no* estás comprando que sí te daría un Dedicated Host?
2. La facturación de un Dedicated Host es por hora-host y no cambia cuando arrancás o parás instancias en él. ¿Qué dimensión de precios se convirtió efectivamente en cuál otra, y qué le hace eso a tu estructura de incentivos?
3. Tu organización tiene una licencia de Oracle Database atada a sockets físicos de CPU. ¿Qué modelo de tenancy es obligatorio, y por qué la respuesta no es "Dedicated Instances"?
4. ¿Qué mecanismo de compromiso reduce el costo del uso de Dedicated Host — RIs Standard, RIs Convertible, Compute Savings Plans, u otra cosa?
5. Un requisito de cumplimiento dice "ninguna carga de trabajo de otro tenant puede correr en el mismo hardware". Un segundo requisito dice "debemos reportar al auditor el conteo de sockets y núcleos físicos". ¿Qué requisito fuerza qué elección?
6. Distinguí una **On-Demand Capacity Reservation** de una Reserved Instance zonal en términos de (a) qué garantiza y (b) cómo se factura.

---

## Ejercicio 6 — Precios por consumo: Lambda y las clases de almacenamiento de S3

**Objetivo:** ver que el pricing de serverless y de almacenamiento son las *mismas* tres dimensiones, expresadas en unidades distintas.

### Pasos

1. Traé los precios unitarios de Lambda desde la misma API:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSLambda \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=group,Value=AWS-Lambda-Requests' \
  --query 'PriceList[0]' --output text \
  | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"'
```

```text
0.0000002000	Requests	$0.20 per 1M requests
```

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSLambda \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=group,Value=AWS-Lambda-Duration' \
  --query 'PriceList[0]' --output text \
  | jq -r '.terms.OnDemand[].priceDimensions[] | "\(.pricePerUnit.USD)\t\(.unit)"'
```

```text
0.0000166667	Second   (per GB-second)
```

2. Calculá el costo mensual de una API real: 5 M de invocaciones, 512 MB de memoria, 300 ms de duración promedio:

```bash
python3 - <<'PY'
inv, mem_gb, dur_s = 5_000_000, 0.5, 0.300
REQ_PRICE, GBS_PRICE = 0.20/1_000_000, 0.0000166667
FREE_REQ, FREE_GBS = 1_000_000, 400_000        # always-free tier

gbs = inv * dur_s * mem_gb
req_cost = max(0, inv - FREE_REQ) * REQ_PRICE
gbs_cost = max(0, gbs - FREE_GBS) * GBS_PRICE
print(f"GB-seconds consumed : {gbs:,.0f}")
print(f"Request charge      : ${req_cost:7.2f}")
print(f"Duration charge     : ${gbs_cost:7.2f}")
print(f"TOTAL               : ${req_cost+gbs_cost:7.2f}/month")
PY
```

```text
GB-seconds consumed : 750,000
Request charge      : $   0.80
Duration charge     : $   5.83
TOTAL               : $   6.63/month
```

3. Encontrá el punto de cruce contra una instancia EC2 siempre encendida sirviendo la misma API:

```bash
python3 - <<'PY'
ec2_month = 0.0960*730           # one m6i.large On-Demand
REQ, GBS = 0.20/1e6, 0.0000166667
mem, dur = 0.5, 0.300
per_inv = REQ + dur*mem*GBS
print(f"m6i.large On-Demand   : ${ec2_month:6.2f}/month")
print(f"cost per invocation   : ${per_inv:.9f}")
print(f"crossover             : {ec2_month/per_inv:,.0f} invocations/month")
PY
```

```text
m6i.large On-Demand   : $ 70.08/month
cost per invocation   : $0.000002700
crossover             : 25,955,556 invocations/month
```

4. Ahora la dimensión de almacenamiento. Extraé los precios de las clases de almacenamiento de S3 para el primer tramo:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonS3 \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=productFamily,Value=Storage' \
  --output json \
| jq -r '.PriceList[] | fromjson
  | . as $p | .terms.OnDemand[].priceDimensions[]
  | select(.beginRange=="0")
  | "\($p.product.attributes.storageClass)\t\(.pricePerUnit.USD)\t\(.unit)"' | sort -u
```

```text
Archive	                0.0036000000	GB-Mo
Deep Archive	        0.0009900000	GB-Mo
General Purpose	        0.0230000000	GB-Mo
Infrequent Access	0.0125000000	GB-Mo
Non-Critical Data	0.0100000000	GB-Mo
```

5. Modelá 10 TB de datos bajo tres estrategias de ciclo de vida, incluyendo penalidades de recuperación y de duración mínima:

```bash
python3 - <<'PY'
TB = 10 * 1024                     # GB
plans = {
 "All S3 Standard":        (TB*0.023, 0),
 "Standard-IA (5% read/mo)": (TB*0.0125, TB*0.05*0.01),
 "Glacier Flexible (1% read/mo)": (TB*0.0036, TB*0.01*0.01),
 "Deep Archive (0.1% read/mo)": (TB*0.00099, TB*0.001*0.02),
}
for name,(store,retr) in plans.items():
    print(f"{name:<32} storage ${store:8.2f} + retrieval ${retr:6.2f} = ${store+retr:8.2f}/mo")
PY
```

```text
All S3 Standard                  storage $  235.52 + retrieval $  0.00 = $  235.52/mo
Standard-IA (5% read/mo)         storage $  128.00 + retrieval $  5.12 = $  133.12/mo
Glacier Flexible (1% read/mo)    storage $   36.86 + retrieval $  1.02 = $   37.88/mo
Deep Archive (0.1% read/mo)      storage $   10.14 + retrieval $  0.20 = $   10.34/mo
```

6. Agregá las restricciones ocultas que convierten una buena planilla en una mala factura — tamaño mínimo facturable de objeto y duración mínima de almacenamiento:

| Clase | Tamaño mín. facturable | Duración mín. de almacenamiento | Cargo de recuperación | Latencia de recuperación |
|---|---|---|---|---|
| S3 Standard | — | — | ninguno | ms |
| S3 Intelligent-Tiering | — | — | ninguno | ms (+ cargo de monitoreo por objeto) |
| S3 Standard-IA | 128 KB | 30 días | por GB | ms |
| S3 One Zone-IA | 128 KB | 30 días | por GB | ms (una sola AZ) |
| S3 Glacier Instant Retrieval | 128 KB | 90 días | por GB (más alto) | ms |
| S3 Glacier Flexible Retrieval | 40 KB | 90 días | por GB | minutos–horas |
| S3 Glacier Deep Archive | 40 KB | 180 días | por GB | horas |

```bash
python3 - <<'PY'
n, real_kb = 4_000_000, 20        # 4M objects of 20 KB each
real_gb    = n*real_kb/1024/1024
billed_gb  = n*128/1024/1024      # 128 KB minimum in Standard-IA
print(f"actual data : {real_gb:8.2f} GB -> ${real_gb*0.0125:6.2f}/mo at IA rate")
print(f"billed data : {billed_gb:8.2f} GB -> ${billed_gb*0.0125:6.2f}/mo  <-- what you pay")
print(f"S3 Standard : {real_gb:8.2f} GB -> ${real_gb*0.023:6.2f}/mo  <-- cheaper!")
PY
```

```text
actual data :    76.29 GB -> $  0.95/mo at IA rate
billed data :   488.28 GB -> $  6.10/mo  <-- what you pay
S3 Standard :    76.29 GB -> $  1.75/mo  <-- cheaper!
```

### Checkpoint 6

1. Lambda tiene dos dimensiones de precio. Nombralas y decí cuál cambia un desarrollador al ajustar la configuración de memoria — y por qué subir la memoria a veces *baja* la factura.
2. El punto de cruce del paso 3 es ~26 M de invocaciones/mes. Enumerá tres factores de costo que esta comparación ignora y que moverían el cruce a favor de Lambda.
3. En el paso 6, mover 4 M de objetos chicos a Standard-IA los hizo **3,5× más caros**. Explicá el mecanismo, y nombrá la funcionalidad de S3 diseñada para evitar exactamente este error de forma automática.
4. Aplicás una regla de ciclo de vida que lleva un objeto a Glacier Flexible Retrieval y lo borrás 20 días después. ¿Qué se te factura?
5. S3 One Zone-IA es 20% más barato que Standard-IA. ¿Qué propiedad de durabilidad estás vendiendo, y nombrá un conjunto de datos para el cual ese canje es correcto.
6. ¿Cuál de estos es un cargo de *almacenamiento* y cuál un cargo de *request*: `PutObject` de un archivo de 1 GB; mantener ese archivo durante un mes; `ListObjectsV2` sobre 10.000 claves?

---

## Ejercicio 7 — Transferencia de datos: la dimensión que nadie modela

### Pasos

1. Enumerá los SKUs de transferencia de datos de tu Región:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AWSDataTransfer \
  --filters "Type=TERM_MATCH,Field=fromLocation,Value=US East (N. Virginia)" \
    'Type=TERM_MATCH,Field=transferType,Value=AWS Outbound' \
  --output json \
| jq -r '.PriceList[] | fromjson | . as $p | .terms.OnDemand[].priceDimensions[]
  | "\(.beginRange)-\(.endRange) GB\t\(.pricePerUnit.USD)\t\($p.product.attributes.toLocation)"' \
  | sort -u | head
```

```text
0-10240 GB	0.0900000000	External
10240-51200 GB	0.0850000000	External
51200-153600 GB	0.0700000000	External
153600-Inf GB	0.0500000000	External
```

2. Internalizá el conjunto de reglas del que dependen tanto el examen como tu factura:

| Ruta | Cargo (típico) |
|---|---|
| Internet → AWS (datos de entrada) | **$0.00** |
| AWS → Internet (datos de salida) | Escalonado; **primeros 100 GB/mes gratis** en toda la cuenta |
| Entre AZs de la misma Región | Se cobra en **ambas direcciones** (~$0.01/GB por dirección) |
| Dentro de una misma AZ, vía IPv4 privada | **$0.00** |
| Dentro de una misma AZ, vía IP pública o Elastic IP | **Se cobra** |
| Entre Regiones | Se cobra, la tarifa depende del par |
| Origen en AWS → Amazon CloudFront | **$0.00** |
| CloudFront → Internet | Se cobra, pero más barato que el egreso directo; **capa gratuita de 1 TB/mes** |
| Vía VPC endpoint **Gateway** de S3/DynamoDB | **$0.00** por el endpoint |
| Vía VPC endpoint **Interface** (PrivateLink) | Cargo horario por ENI **+** por GB |

3. Cotizá los mismos 50 TB/mes de egreso de tres maneras:

```bash
python3 - <<'PY'
GB = 50*1024
def tiered(gb, tiers):
    free, cost, rem = 100, 0.0, gb
    rem -= min(rem, free)
    for size, rate in tiers:
        take = min(rem, size); cost += take*rate; rem -= take
        if rem <= 0: break
    return cost
ec2 = tiered(GB, [(10*1024,0.09),(40*1024,0.085),(100*1024,0.07),(1e9,0.05)])
cf  = tiered(GB, [(10*1024,0.085),(40*1024,0.080),(100*1024,0.060),(1e9,0.040)])
print(f"Direct from EC2/ALB : ${ec2:9,.2f}/month")
print(f"Behind CloudFront   : ${cf:9,.2f}/month  (origin fetch is free)")
print(f"Delta               : ${ec2-cf:9,.2f}/month")
PY
```

```text
Direct from EC2/ALB : $ 4,282.65/month
Behind CloudFront   : $ 4,024.00/month  (origin fetch is free)
Delta               : $   258.65/month
```

4. Cotizá un problema de "conversación" entre AZs — una malla de microservicios moviendo 8 TB/día entre AZs:

```bash
python3 - <<'PY'
gb_day, rate_each_way = 8*1024, 0.01
print(f"per month: {gb_day*30:,} GB x ${rate_each_way} x 2 directions = "
      f"${gb_day*30*rate_each_way*2:,.2f}")
PY
```

```text
per month: 245,760 GB x $0.01 x 2 directions = $4,915.20
```

5. Cotizá la ruta del NAT Gateway, un ítem invisible clásico — cargo horario **más** procesamiento por GB, *encima de* cualquier egreso:

```bash
aws pricing get-products --region "$PRICING_REGION" --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$TARGET_REGION" \
    'Type=TERM_MATCH,Field=productFamily,Value=NAT Gateway' \
  --output json \
| jq -r '.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[]
  | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"' | sort -u
```

```text
0.0450000000	GB	  $0.045 per GB Data Processed by NAT Gateways
0.0450000000	Hrs	  $0.045 per NAT Gateway Hour
```

### Checkpoint 7

1. Los datos de *entrada* desde internet son gratis mientras que los de *salida* son caros. ¿Qué comportamiento de negocio busca producir esa asimetría, y cuál es la implicancia arquitectónica para el diseño de un data lake?
2. Tu aplicación baja 30 TB/mes desde S3 hacia EC2 **en la misma Región**, a través de un NAT Gateway. Calculá el cargo de procesamiento del NAT y nombrá el único cambio gratuito que lo elimina por completo.
3. Dos instancias EC2 en la misma AZ se comunican. Dá una configuración en la que ese tráfico es gratis y una en la que se factura. ¿Cuál es la única diferencia?
4. El tráfico entre AZs se cobra en ambas direcciones. ¿Qué le hace eso al costo real de un despliegue multi-AZ "de alta disponibilidad", y cómo decidís que igual vale la pena?
5. ¿Por qué la transferencia origen→CloudFront es gratis? ¿Cuál es el incentivo de AWS?
6. Un arquitecto propone un despliegue multi-Región activo-activo por latencia. ¿Qué dimensión de precios va a dominar la factura incremental, y qué herramienta de AWS usarías *antes* de construirlo para cuantificarla?

---

## Ejercicio 8 — Free Tier y las barandas a su alrededor

### Pasos

1. Consultá tu consumo real de Free Tier. La API devuelve las **tres categorías que toma el examen**, etiquetadas:

```bash
aws freetier get-free-tier-usage --region us-east-1 \
  --query 'freeTierUsages[].{Svc:service,Type:freeTierType,Used:actualUsageAmount,Fcst:forecastedUsageAmount,Limit:limit,Unit:unit}' \
  --output table
```

```text
------------------------------------------------------------------------------------
|                               GetFreeTierUsage                                   |
+-------+---------------+--------+--------+---------+-----------------------------+
| Fcst  |    Limit      | Svc    | Unit   |  Used   |            Type             |
+-------+---------------+--------+--------+---------+-----------------------------+
| 750.0 |  750.0        | AmazonEC2| Hrs  |  612.0  |  12 Months Free             |
| 5.0   |  5.0          | AmazonS3| GB-Mo |   3.1   |  12 Months Free             |
| 1.2E6 |  1.0E6        | AWSLambda| Requests| 940000|  Always Free               |
| 25.0  |  25.0         | AmazonDynamoDB| GB-Mo| 11.4 |  Always Free               |
| 15.0  |  15.0         | AmazonInspector| Days| 9.0  |  Free Trial                |
+-------+---------------+--------+--------+---------+-----------------------------+
```

2. Filtrá solo lo que se pronostica que va a **exceder** su límite — el subconjunto accionable:

```bash
aws freetier get-free-tier-usage --region us-east-1 --output json \
| jq -r '.freeTierUsages[]
   | select(.forecastedUsageAmount > .limit)
   | "OVERRUN  \(.service)\t\(.forecastedUsageAmount) / \(.limit) \(.unit)\t[\(.freeTierType)]"'
```

```text
OVERRUN  AWSLambda	1200000 / 1000000 Requests	[Always Free]
```

3. Creá un **presupuesto de gasto cero** para que el primer centavo de cargo inesperado te notifique:

```bash
cat > /tmp/budget.json <<EOF
{
  "BudgetName": "clf-4-1-zero-spend",
  "BudgetLimit": { "Amount": "1", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostTypes": {
    "IncludeCredit": false,
    "IncludeRefund": false,
    "IncludeDiscount": true,
    "IncludeSubscription": true,
    "IncludeSupport": true,
    "IncludeTax": true,
    "IncludeUpfront": true,
    "IncludeRecurring": true,
    "IncludeOtherSubscription": true,
    "UseAmortized": false,
    "UseBlended": false
  }
}
EOF

cat > /tmp/notify.json <<'EOF'
[{
  "Notification": {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 0.01,
    "ThresholdType": "ABSOLUTE_VALUE"
  },
  "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "you@example.com" }]
}]
EOF

aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

4. Confirmá que existe:

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Spent:CalculatedSpend.ActualSpend.Amount}' \
  --output table
```

```text
-------------------------------------------------
|               DescribeBudgets                 |
+---------------------+---------+---------------+
|        Name         |  Limit  |     Spent     |
+---------------------+---------+---------------+
|  clf-4-1-zero-spend |  1      |  0.0000000000 |
+---------------------+---------+---------------+
```

> **Nota sobre planes de cuenta:** AWS revisó la oferta de Free Tier en 2025 — las cuentas más nuevas pueden estar inscriptas en un *Free Plan* basado en créditos (créditos de registro más créditos por actividad) en lugar del modelo clásico de 12 meses, mientras que las ofertas **Always Free** continúan para todos. `aws freetier get-account-plan-state` (versiones recientes de la CLI) informa en qué plan estás. El examen CLF-C02 sigue evaluando las tres categorías que la API etiqueta arriba. Confirmá en <https://aws.amazon.com/free/>.

### Checkpoint 8

1. Nombrá las tres categorías del Free Tier y dá un ejemplo de servicio de cada una a partir de tu propia salida.
2. `AmazonEC2 750 Hrs` está bajo "12 Months Free". ¿Qué pasa el día 366 si nada cambia, y qué significan realmente *750 horas* para alguien que corre dos instancias?
3. El presupuesto del paso 3 fija `IncludeCredit: false`. ¿Por qué es esa la configuración correcta para un presupuesto de baranda, y qué verías si fuera `true`?
4. ¿Por qué un Budget es una *alerta* y no un *tope*? ¿Qué tendrías que agregar para que algo realmente se detenga?
5. Se pronostica que tu cuota "Always Free" de Lambda se excederá en un 20%. ¿Cuál es la consecuencia real en dólares? Calculala.
6. ¿Cuál es gratis y cuál se factura: los primeros dos AWS Budgets, la consola de Cost Explorer, la API de Cost Explorer, la AWS Pricing Calculator?

---

## Ejercicio 9 — Dejá que tu propio uso elija el modelo

> **Estos dos comandos se facturan a $0.01 cada uno.**

### Pasos

1. Descomponé el gasto del mes pasado por tipo de compra — la consulta de facturación más informativa que existe:

```bash
aws ce get-cost-and-usage --region "$PRICING_REGION" \
  --time-period Start=$(date -u -d 'last month' +%Y-%m-01),End=$(date -u +%Y-%m-01) \
  --granularity MONTHLY --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=PURCHASE_TYPE \
  --query 'ResultsByTime[0].Groups[].{Type:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
  --output table
```

```text
-------------------------------------------------------
|                 GetCostAndUsage                     |
+---------------+-------------------------------------+
|     Cost      |               Type                  |
+---------------+-------------------------------------+
|  412.88       |  On Demand Instances                |
|  180.44       |  Savings Plan Covered Usage         |
|   96.10       |  Standard Reserved Instances        |
|   22.71       |  Spot Instances                     |
+---------------+-------------------------------------+
```

2. Preguntale a AWS qué compromiso justifica tu propio uso:

```bash
aws ce get-savings-plans-purchase-recommendation --region "$PRICING_REGION" \
  --savings-plans-type COMPUTE_SP --term-in-years ONE_YEAR \
  --payment-option NO_UPFRONT --lookback-period-in-days SIXTY_DAYS \
  --query 'SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary' \
  --output json
```

```json
{
  "EstimatedROI": "312.4",
  "CurrencyCode": "USD",
  "EstimatedTotalCost": "3420.55",
  "CurrentOnDemandSpend": "4980.10",
  "EstimatedSavingsAmount": "1559.55",
  "TotalRecommendationCount": "1",
  "DailyCommitmentToPurchase": "4.62",
  "HourlyCommitmentToPurchase": "0.1925",
  "EstimatedSavingsPercentage": "31.3",
  "EstimatedMonthlySavingsAmount": "129.96"
}
```

3. Verificá qué tan bien se están usando los compromisos existentes — un compromiso no usado es pérdida pura:

```bash
aws ce get-savings-plans-utilization --region "$PRICING_REGION" \
  --time-period Start=$(date -u -d 'last month' +%Y-%m-01),End=$(date -u +%Y-%m-01) \
  --granularity MONTHLY \
  --query 'Total.{Used:UtilizationPercentage,Unused:UnusedCommitment,Net:NetSavings}' \
  --output table
```

```text
------------------------------------------
|      GetSavingsPlansUtilization         |
+---------+-----------+-------------------+
|  Net    |  Unused   |       Used        |
+---------+-----------+-------------------+
| 118.72  |  6.41     |  96.4             |
+---------+-----------+-------------------+
```

4. Antes de comprometerte a *nada*, verificá si la instancia debería ser más chica (gratis):

```bash
aws compute-optimizer get-ec2-instance-recommendations --region "$TARGET_REGION" \
  --query 'instanceRecommendations[?finding==`OVER_PROVISIONED`].{Arn:instanceArn,Now:currentInstanceType,Rec:recommendationOptions[0].instanceType,Save:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
  --output table
```

```text
----------------------------------------------------------------------
|                 GetEC2InstanceRecommendations                      |
+---------------------------+-------------+-------------+------------+
|            Arn            |     Now     |     Rec     |    Save    |
+---------------------------+-------------+-------------+------------+
|  arn:aws:ec2:...:i-0abc12 |  m6i.2xlarge|  m6i.large  |   210.24   |
+---------------------------+-------------+-------------+------------+
```

### Checkpoint 9

1. El paso 1 muestra $412.88 de gasto On-Demand. ¿Es eso automáticamente desperdicio? ¿Qué pregunta adicional tenés que hacerte antes de recomendar un compromiso?
2. La utilización de Savings Plans es 96,4% con $6.41 sin usar. ¿Está bien? ¿Qué cifra de utilización te haría *reducir* el próximo compromiso, y por qué 100% tampoco es necesariamente el objetivo?
3. Compute Optimizer dice que una instancia está sobredimensionada y que podrías ahorrar $210/mes. Explicá por qué correr esto **antes** de comprar un Savings Plan no es opcional.
4. Ordená correctamente estas cuatro acciones para un programa de optimización de costos, y justificá el orden: comprar compromisos, dimensionar correctamente las instancias, eliminar recursos ociosos, mover cargas de trabajo elegibles a Spot.
5. La recomendación dice comprometerse a $0.1925/hora, no a $0.25, aunque el gasto On-Demand actual es mayor. ¿Qué conservadurismo está aplicando el algoritmo de AWS, y te comprometerías a *más* o a *menos* de lo que sugiere? Dá el razonamiento para cada dirección.

---

## Trabajo final — Construí la matriz de decisión

### Pasos

1. Modelá este sistema en la **AWS Pricing Calculator** en <https://calculator.aws/#/>, una estimación por componente:

| # | Componente | Forma |
|---|---|---|
| 1 | Capa de API pública | 3 × `m6i.large`, 24/7, horizonte de 3 años, no debe interrumpirse |
| 2 | ETL nocturno | 400 horas-instancia/mes, tolerante a fallos, hace checkpoints a S3 |
| 3 | Data warehouse analítico | Estable, pero el equipo podría migrarlo de EC2 a Fargate en 8 meses |
| 4 | Receptor de webhooks | 40 M de invocaciones/mes, 128 MB, 80 ms |
| 5 | Archivo de eventos crudos | 40 TB, se lee < 1 vez/año, la restauración puede tardar horas |
| 6 | Base de datos de cumplimiento | Oracle, licencia atada a sockets, el auditor exige reporte de núcleos físicos |
| 7 | Egreso hacia clientes | 25 TB/mes de assets estáticos |

2. Para cada componente, anotá: modelo de precios elegido, la *única* propiedad de la carga de trabajo que fuerza esa elección, y el costo mensual estimado.

3. Exportá la estimación (**Share** → enlace público, o **Export** → CSV) y reconciliá al menos dos ítems contra los valores de la Price List API que consultaste en los Ejercicios 1–7. Investigá cualquier diferencia mayor al 5%.

4. Escribí una justificación de tres oraciones para el compromiso más riesgoso de tu matriz, indicando explícitamente qué tendría que cambiar para que la decisión pase a ser incorrecta.

### Checkpoint — Trabajo final

1. Completá el modelo para cada uno de los siete componentes.
2. El componente 3 es de estado estable pero está migrando de EC2 a Fargate. ¿Qué único modelo de precios sobrevive esa migración con su descuento intacto? ¿Cuánto te habría costado un EC2 Instance Savings Plan de 3 años?
3. El componente 7 son 25 TB/mes de egreso. ¿Dónde cae en la tabla de precios escalonados, y cuál sería el primer cambio arquitectónico que propondrías?
4. ¿Qué dos componentes podrían compartir un mismo compromiso de Compute Savings Plan? ¿Cuál no podría participar en absoluto?
5. Enunciá en una oración la regla general que mapea el *perfil temporal* de una carga de trabajo a su modelo de precios.

---

## Limpieza

```bash
aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf-4-1-zero-spend
rm -f /tmp/m6i-large.json /tmp/budget.json /tmp/notify.json
```

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" --query 'length(Budgets)'
```

```text
0
```

Nada más creó un recurso facturable. Si querés conservar un artefacto, conservá el presupuesto — una alerta de gasto cero es el seguro más barato de AWS.

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Using the AWS Price List API — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html>
- Amazon EC2 Instance Purchasing Options — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html>
- Reserved Instances (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html>
- Savings Plans User Guide — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Spot Instances (EC2 User Guide) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>
- Dedicated Hosts — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html>
- Amazon S3 storage classes — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- AWS Lambda pricing — <https://aws.amazon.com/lambda/pricing/>
- Amazon EC2 On-Demand pricing (incl. data transfer) — <https://aws.amazon.com/ec2/pricing/on-demand/>
- AWS Cost Explorer — <https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html>
- AWS Budgets — <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
- AWS Free Tier — <https://aws.amazon.com/free/> · Free Tier API — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/checkfreetier.html>
- AWS Pricing Calculator — <https://calculator.aws/>
- AWS Compute Optimizer — <https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html>

---

<details>
<summary><strong>Respuestas</strong> — abrir solo después de intentar todos los checkpoints</summary>

### Checkpoint 0

1. `--region` en un comando `pricing` selecciona el **endpoint de la API**, y la Price List Query API solo se sirve desde unas pocas Regiones (`us-east-1`, `eu-central-1`, `ap-south-1`), así que `eu-west-1` no tiene endpoint con el cual hablar; la Región cuyos precios recuperás es un **filtro** (`regionCode` / `location`) dentro del request, y por eso un solo endpoint devuelve precios de todas las Regiones.
2. En ninguna de las tres, en la práctica. Toda acción es de solo lectura salvo `budgets:CreateBudget`, y los primeros dos presupuestos por cuenta no tienen cargo. Las únicas llamadas realmente medidas son las acciones `ce:Get*` de Cost Explorer, facturadas por request ($0.01) — un cargo por request de API, no un cargo de cómputo/almacenamiento/transferencia.
3. 730 = 8.760 ÷ 12, el mes promedio a lo largo de un año. Usar 720 (30 días) subestimaría sistemáticamente la factura de los meses de 31 días, y las comparaciones mensuales de una carga 24/7 tienen que ser consistentes, no exactas respecto del calendario.

### Checkpoint 1

1. `capacitystatus` distingue por qué está cobrando el SKU. `Used` = una instancia efectivamente en ejecución. `UnusedCapacityReservation` = una On-Demand Capacity Reservation que estás pagando sin nada corriendo dentro. `AllocatedCapacityReservation` = capacidad asignada a una reserva. Si filtraras por el valor equivocado, estarías cotizando capacidad *reservada pero ociosa*, no instancias en ejecución — un producto distinto con una tarifa distinta, que es exactamente cómo los scripts ingenuos devuelven números "sorprendentes".
2. `preInstalledSw` cubre software comercial incorporado en la AMI (SQL Server Standard/Enterprise/Web) cuya licencia se factura a través de la hora-instancia. `licenseModel` distingue `No License required` de `Bring your own license`. Juntos codifican el traslado del licenciamiento de software de AWS: el mismo hardware lleva varios precios según qué esté licenciado sobre él, así que dejarlos sin filtrar devuelve SKUs de SQL Server junto a los de Linux puro.
3. Impulsores estructurales: costo local de energía, terreno, construcción, mano de obra e impuestos; aranceles de importación y sobrecarga cambiaria/regulatoria; escala y madurez de la Región (una Región más nueva o más chica amortiza el costo fijo entre menos clientes); costos locales de red/tránsito. Implicancia arquitectónica: **la selección de Región es tanto una decisión de costo como una de latencia/cumplimiento** — si la residencia de datos y la latencia lo permiten, colocar cargas por lotes o no sensibles a la latencia en una Región más barata es una palanca legítima, pero hay que ponderarla contra los cargos de transferencia entre Regiones, que pueden borrar el ahorro de cómputo.
4. (a) AWS cambia el precio — históricamente casi siempre a la baja — y tu chargeback sobrefactura a los equipos internos para siempre, en silencio. (b) El script se reutiliza para otra Región, sistema operativo o tenancy donde $0.096 nunca fue la tarifa, produciendo números incorrectos sin ningún error. Un tercero: ignora silenciosamente cualquier cobertura de RI/SP, así que reporta precio de lista en lugar de lo que la empresa realmente pagó.
5. ~$0.192/hr — el doble. **Dentro de una familia y generación, el precio On-Demand escala linealmente con el tamaño** (esta linealidad es exactamente lo que hace funcionar los factores de normalización de las RI). **No** se sostiene entre familias: `c6i.large` y `m6i.large` tienen la misma cantidad de vCPU pero distinta relación memoria-a-vCPU y precios distintos, porque estás comprando una mezcla de recursos diferente, no más de la misma.

### Checkpoint 2

1. Porque una RI No Upfront es un **compromiso de facturación, no un descuento basado en uso**: durante las 8.760 horas del término AWS te factura $0.0605/hr haya o no una instancia corriendo. No evitaste el compromiso, solo cambiaste *cuándo* lo pagás. Equilibrio = tarifa horaria efectiva de la RI ÷ tarifa horaria On-Demand = 0.0605/0.096 = 63%.
2. All Upfront > Partial Upfront > No Upfront. El mecanismo es el **valor tiempo del dinero y el riesgo de contraparte**: pagarle a AWS todo el término por adelantado transfiere efectivo de inmediato y elimina cualquier riesgo de impago, así que AWS devuelve parte de ese valor como un descuento más profundo. Notá en los datos de ejemplo que Partial Upfront puede dar una tarifa efectiva *marginalmente* mejor que All Upfront; calculá siempre en lugar de asumir que el orden es estricto.
3. La flota de CI (~30% de utilización, builds interrumpibles) va en **Spot**, en un Auto Scaling group de instancias mixtas con On-Demand como respaldo. El repositorio de artefactos detrás está siempre encendido, tiene estado y es sensible a la latencia — eso va con un **compromiso** (Savings Plan o RI), y su almacenamiento en S3 con una política de ciclo de vida.
4. Convertible vale la pena cuando (a) esperás cambiar de **familia** de instancia durante el término — un refresco de generación de hardware, un pase de `m` a `c`/`r`, o una migración x86→Graviton — ya que las RIs Convertible pueden **intercambiarse** por una configuración distinta de igual o mayor valor; y (b) la forma de tu carga de trabajo es genuinamente incierta en un horizonte de 3 años y estás comprando opcionalidad. Standard permite algo que Convertible no: **vender la RI en el Reserved Instance Marketplace** para salir antes.
5. El alcance regional te compra **flexibilidad**: el descuento flota por todas las AZs de la Región y, para Linux/tenancy por defecto, entre tamaños de la familia. Te cuesta la **reserva de capacidad** — las RIs regionales no garantizan capacidad en ninguna AZ específica. El alcance zonal te da un lugar garantizado en una AZ pero fija el descuento ahí.
6. Completa. `m6i.2xlarge` = factor 16; cuatro `m6i.large` = 4 × 4 = 16. Cubierto exactamente. Si la carga de trabajo se muda a `c6i.large`, la RI **deja de aplicar por completo** — la flexibilidad de tamaño funciona dentro de una familia, nunca entre familias — y pagarías On-Demand pleno por la `c6i` mientras seguís pagando la RI de `m6i`. Este es precisamente el escenario que absorbe un Compute Savings Plan.
7. La flexibilidad de tamaño de instancia aplica solo a RIs Standard **regionales, Linux/UNIX, de tenancy por defecto**. Windows (y otros sistemas operativos con cargos de licencia por instancia como RHEL/SUSE) queda excluido porque el componente de licencia no escala linealmente con el tamaño de instancia, así que la normalización lo cotizaría mal. Las RIs zonales quedan excluidas porque su valor es una reserva de capacidad para una configuración *específica* en una AZ *específica* — hacerla flotar volvería la garantía sin sentido.

### Checkpoint 3

1. Una RI te compromete a una **configuración de recurso** (familia, Región, sistema operativo, tenancy, opcionalmente AZ) por un término; un Savings Plan te compromete a un **monto en dólares de gasto de cómputo por hora** por un término, y AWS aplica la tarifa con descuento a cualquier uso elegible que lo llene.
2. Absorbido por Compute pero no por el EC2 Instance SP: (a) cambiar de **familia** de instancia (`m6i` → `c7g`), (b) mover la carga de trabajo a una **Región distinta**, (c) replataformar de EC2 a **Fargate o Lambda**. También cambiar de **tenancy** y cambiar de sistema operativo. El plan EC2 Instance está atado a una familia en una Región.
3. El Savings Plan aplica la tarifa con descuento solo hasta el compromiso. $0.20/hr ÷ $0.0655 = 3,05 horas-instancia de cobertura; la 4ª instancia **no está cubierta en absoluto** y se factura a la tarifa On-Demand plena de $0.0960, no a la del SP. El uso no cubierto nunca recibe un descuento parcial — $0.20 + $0.0911 (la fracción no cubierta) = $0.2911.
4. La cobertura cuesta $0.1310/hr (2 × $0.0655) contra un compromiso de $0.20/hr → $0.069/hr desperdiciados → **$50.37/mes quemados a cambio de nada**. Implicancia: **dimensioná el compromiso según tu piso de uso (el valle), no según el promedio ni el pico.** El uso por encima del compromiso simplemente cae a On-Demand, que es una penalidad chica; un compromiso por encima del uso es pérdida total.
5. AWS Fargate y AWS Lambda (además de EC2 en todas las familias/Regiones/sistemas operativos/tenancies), y SageMaker está cubierto por su propio SageMaker Savings Plan aparte. Un servicio Fargate que corre continuamente debería usar un **Compute Savings Plan** — Fargate no tiene equivalente de RI.
6. Ambos se aplican como un **descuento en el momento de facturar** contra el uso coincidente, no como una propiedad de la instancia en sí. En una AWS Organization con facturación consolidada, los descuentos se comparten entre cuentas por defecto (compartición de RI / de Savings Plans a nivel del payer), así que la RI comprada en la Cuenta A *puede* descontar la instancia de la Cuenta B — pero solo si la compartición está habilitada para esas cuentas. Desactivar la compartición, o una discrepancia en la configuración de las cuentas vinculadas, deja el descuento varado en silencio.
7. **RI Standard de 3 años** — la peor: atada a `m6i`, y la única salida es venderla en el RI Marketplace. **EC2 Instance SP de 3 años** — también mala: atada a la familia `m6i` en una Región; el pase a Graviton la deja varada. **Compute SP de 3 años** — correcta: el uso de `m7g` consume el mismo compromiso automáticamente, ya que el plan está denominado en dólares y cubre todas las familias. El descuento nominal más profundo de las dos primeras no vale nada si el descuento deja de aplicar en el mes nueve.

### Checkpoint 4

1. Un **Spot Instance interruption notice**, entregado vía metadatos de instancia y EventBridge, que da un aviso de **dos minutos**. La señal más temprana es la **EC2 instance rebalance recommendation**, que llega antes del aviso de interrupción cuando la capacidad Spot está en riesgo elevado, dándote más tiempo para drenar conexiones o lanzar un reemplazo.
2. El precio Spot se fija por **tipo de instancia, por sistema operativo, por Zona de Disponibilidad**, y refleja el balance de oferta/demanda en tiempo real de *ese pool*. Una dispersión del 21% significa que los pools son independientes y están cargados de manera despareja. Consecuencia de configuración: usá un ASG con una **mixed instances policy** que abarque varios tipos de instancia **y todas las AZs**, con la estrategia de asignación `price-capacity-optimized` — nunca fijes una flota Spot a un solo tipo en una sola AZ.
3. (a) **Sí** — con checkpoints, reiniciable, sin usuarios esperando. (b) **No** — interrumpirlo tira sesiones en vivo; el estado está en memoria y no se puede reconstruir. (c) **Sí** — un build perdido se puede volver a correr y el costo de rehacerlo está acotado. (d) **No** — un nodo primario de base de datos que pierde su host es un incidente de disponibilidad de datos, no una molestia. (e) **Sí** — vergonzosamente paralelo, el trabajo por cuadro tiene checkpoints naturales.
4. Spot pierde cuando el costo esperado de rehacer el trabajo supera al descuento — es decir, cuando la probabilidad de interrupción es alta, el trabajo es largo, **y** el progreso no se puede guardar. Llevá `p_int_job` hacia 1, o alargá el trabajo, y el multiplicador de intentos esperados crece sin límite. La lección: **el esfuerzo de ingeniería puesto en checkpointing convierte una carga Spot riesgosa en una segura**, y esa inversión suele rendir mucho más que pasarse a On-Demand.
5. **No.** El pricing Spot ya es un descuento de mercado sobre capacidad no utilizada — los dos mecanismos son formas alternativas de comprar la *misma* capacidad, y apilarlos no se ofrece. Estructuralmente: las RIs y los Savings Plans son pagos por *compromiso/previsibilidad*, y Spot está cotizado precisamente por la *ausencia* de cualquier garantía. No queda nada por descontar.
6. **Terminate** (por defecto), **Stop** e **Hibernate**. Stop e Hibernate preservan ambos el volumen EBS raíz (hibernate además escribe la RAM en él); con Terminate, el volumen raíz se elimina salvo que `DeleteOnTermination` se haya fijado en `false`. Notá que con Stop/Hibernate seguís pagando el almacenamiento EBS mientras la instancia no está corriendo.

### Checkpoint 5

1. La tenancy Dedicated Instance compra **aislamiento físico respecto de otras cuentas de AWS** — tus instancias corren sobre hardware dedicado a tu cuenta. **No** compra visibilidad ni control sobre el host subyacente: sin reporte de sockets/núcleos, sin control sobre la colocación de instancias tras reinicios del host, y sin capacidad de satisfacer una licencia de software por socket o por núcleo. Los Dedicated Hosts proveen eso.
2. **El cómputo se convirtió de un costo variable en un costo fijo.** El host se factura por hora tenga cero instancias o su capacidad completa, así que el costo marginal de colocar una instancia más en un host ya pagado es cero. El incentivo se invierte: con tenancy compartida te premia apagar instancias; con un Dedicated Host te premia **empaquetarlo lo más densamente posible**, y un host subutilizado es desperdicio puro.
3. **Dedicated Hosts.** La licencia está atada a sockets/núcleos físicos, así que tenés que poder *ver y reportar* los conteos de sockets y núcleos del host y fijar instancias a un host específico — capacidades que solo exponen los Dedicated Hosts. Las Dedicated Instances dan aislamiento pero ninguna visibilidad ni afinidad a nivel de host, así que una licencia por socket no se puede atestiguar legalmente. Los Dedicated Hosts son además el vehículo para BYOL en Windows Server y SQL Server.
4. **Dedicated Host Reservations** — un mecanismo de compromiso distinto, con sus propios términos de 1 o 3 años y opciones No/Partial/All Upfront, comprado contra un host, no contra una instancia. Las RIs de EC2 y los Savings Plans cubren uso de instancias (incluyendo la tenancy Dedicated Instance); el uso de Dedicated Host se factura como host y se cubre con Host Reservations. Verificá las reglas de cobertura vigentes en el FAQ de Savings Plans antes de comprometer dinero.
5. El requisito de **aislamiento** lo satisfacen tanto las Dedicated Instances como los Dedicated Hosts. El requisito de **reporte de sockets/núcleos físicos** es el que fuerza **Dedicated Hosts** — es la única opción que expone esa información. Siempre que aparezcan ambos, el requisito de reporte/licenciamiento es el que decide.
6. (a) Una **On-Demand Capacity Reservation** garantiza capacidad en una AZ específica para una configuración de instancia específica, **sin compromiso de término** — podés crearla y cancelarla en cualquier momento. Una **RI zonal** garantiza capacidad *y* además conlleva un compromiso de facturación de 1 o 3 años. (b) Una Capacity Reservation se factura a la **tarifa On-Demand mientras exista**, ocupe o no una instancia (`capacitystatus=UnusedCapacityReservation` en el Ejercicio 1); una RI zonal se factura según su opción de compra. Las dos se componen: el descuento de un Savings Plan o de una RI regional puede aplicarse al uso que llena una Capacity Reservation, y esa es la forma estándar de obtener *ambas cosas*, capacidad garantizada y descuento.

### Checkpoint 6

1. **Requests** ($ por invocación) y **duración** ($ por GB-segundo, es decir memoria × tiempo). Ajustar la memoria cambia la dimensión de GB-segundos directamente — pero Lambda asigna CPU proporcionalmente a la memoria, así que duplicar la memoria puede más que reducir a la mitad el tiempo de ejecución en trabajo limitado por CPU, bajando el total de GB-segundos *y* la latencia. Por eso existe AWS Lambda Power Tuning: la configuración de memoria más barata frecuentemente no es la más chica.
2. (a) EC2 requiere **redundancia para la disponibilidad** — necesitarías al menos dos instancias en distintas AZs, duplicando el lado de EC2. (b) EC2 necesita un **balanceador de carga**, que tiene sus propios cargos horarios y por LCU. (c) EC2 acarrea **costo operativo** — parcheo, gestión de AMIs, configuración de escalado — que nunca aparece en la comparación de precios pero es plata real. Además: el tráfico con picos implica que la instancia EC2 debe dimensionarse para el pico y pagarse también en el valle, mientras que Lambda factura solo la ejecución real.
3. **S3 Standard-IA factura un mínimo de 128 KB por objeto.** Los objetos de 20 KB se facturan como 128 KB — una inflación de 6,4× que se come el descuento del 46% por GB. La funcionalidad diseñada para evitar esto es **S3 Intelligent-Tiering**, que mueve objetos entre capas de acceso automáticamente según los patrones de acceso observados, no cobra cargos de recuperación, y **no aplica tiering automático a objetos menores de 128 KB** (quedan en la capa de acceso frecuente con precios de Standard). La regla general: las clases IA y de archivo son para objetos *grandes y fríos*.
4. Pagás **30 días de almacenamiento en Glacier Flexible Retrieval** (el mínimo de 90 días se prorratea: se te cobra un cargo por eliminación temprana equivalente a los 70 días restantes) **más** el cargo de request de la transición de ciclo de vida **más** cualquier cargo de recuperación. Borrar antes no reembolsa la transición — y por eso las políticas de ciclo de vida deben modelarse contra tiempos de vida reales de los objetos, no aspiracionales.
5. Estás vendiendo **redundancia multi-AZ**: One Zone-IA almacena los datos en una sola Zona de Disponibilidad, así que la pérdida de esa AZ los destruye. Es correcto para datos **reproducibles** — copias secundarias de un backup on-premises, medios derivados/transcodificados, extractos analíticos cacheados, artefactos de CI — cualquier cosa que podrías regenerar en lugar de restaurar.
6. `PutObject` de un archivo de 1 GB → un cargo de **request** (los PUT se cotizan por cada 1.000, y una carga multiparte cuenta cada parte). Mantenerlo un mes → un cargo de **almacenamiento** (GB-mes). `ListObjectsV2` sobre 10.000 claves → un cargo de **request** (LIST se cotiza con la clase de requests PUT, el tramo más caro). Notá que leer ese 1 GB de vuelta hacia internet agrega un cargo de **transferencia de datos** — tres dimensiones, un solo objeto.

### Checkpoint 7

1. Hace que ingerir datos hacia AWS sea sin fricción y sacarlos, caro — la economía favorece mantener los datos, y el cómputo que los procesa, dentro de AWS. Implicancia arquitectónica para un data lake: **llevá el cómputo a los datos, no los datos al cómputo.** Hacé agregación, filtrado y conversión de formato (Athena, EMR, Glue) dentro de la Región y exportá solo resultados; nunca diseñes un pipeline cuyo estado estable sea exportar objetos crudos en bloque.
2. 30 TB = 30.720 GB × $0.045/GB = **$1.382,40/mes** solo en procesamiento de NAT (más ~$32,85/mes en cargos horarios del NAT), por tráfico que nunca sale de la Región. El arreglo gratuito es un **S3 Gateway VPC Endpoint**: enruta el tráfico de S3 por la ruta privada de la VPC, no cuesta nada ni por el endpoint ni por los datos, y saca el tráfico de S3 del NAT Gateway por completo. (Lo mismo aplica a DynamoDB.)
3. Gratis si se comunican por **direcciones IPv4 privadas** dentro de la misma AZ; facturado si el tráfico atraviesa una **dirección IPv4 pública, una Elastic IP, o un balanceador de carga/NAT en el camino**. La única diferencia es a qué dirección se envía el tráfico — los paquetes pueden tomar un camino parecido, pero AWS factura según el direccionamiento, y por eso usar un nombre DNS público para un servicio interno es un cargo recurrente silencioso.
4. Le agrega a la HA un costo real y proporcional al uso — en el ejemplo del paso 4, ~$4.915/mes puramente por cruzar límites de AZ. Decidís que vale la pena comparando ese número contra el **costo de la caída que previene**: tiempo de indisponibilidad esperado × ingresos o penalidad de SLA por hora. También lo reducís arquitectónicamente — enrutamiento/topología con conciencia de AZ para que un servicio prefiera réplicas en la misma AZ, dejando el tráfico entre AZs para replicación y failover en lugar de para cada request.
5. CloudFront cachea en el borde, así que los fetches gratuitos al origen le cuestan a AWS relativamente poco mientras la caché absorbe la mayoría de los requests; el incentivo de AWS es mover el egreso a una red que controla de punta a punta, más barata de servir para AWS y más pegajosa para el cliente. El resultado visible para el cliente es que CloudFront casi siempre es más barato que el egreso directo para contenido cacheable, además de ser más rápido.
6. **Transferencia de datos** — específicamente la transferencia entre Regiones para replicación (bases de datos, S3 CRR, sincronización de configuración/estado), que ocurre continuamente y es fácil de subestimar porque escala con el volumen de escrituras y no con el tráfico de usuarios. Cuantificala antes de construir con la **AWS Pricing Calculator**, modelando el volumen de replicación explícitamente como su propio ítem, y validá el supuesto después con Cost Explorer agrupado por usage type.

### Checkpoint 8

1. **Always Free** — sin vencimiento, por ejemplo 1 M de requests + 400.000 GB-segundos por mes de AWS Lambda, los 25 GB de DynamoDB. **12 Months Free** — desde la creación de la cuenta, por ejemplo 750 horas/mes de `t2.micro`/`t3.micro`, 5 GB de S3 Standard. **Free Trial** — una ventana fija y corta desde el primer uso de ese servicio específico, por ejemplo los 15 días de Amazon Inspector.
2. El día 366 la cuota desaparece y la misma instancia se factura a la tarifa On-Demand plena, **sin notificación y sin interrupción del servicio** — la primera señal es la factura, que es exactamente por lo que importa el presupuesto del paso 3. 750 horas ≈ una instancia corriendo continuamente durante un mes (730 h); **dos** instancias la consumen en unos 15 días, porque la cuota se mide en horas-instancia, no en instancias.
3. Un presupuesto de baranda debe alertar sobre **uso real**, y los créditos promocionales o de registro enmascaran el uso llevando a cero el monto cobrado — con `IncludeCredit: true` verías $0.00 mientras quemás el saldo de créditos, y después recibirías una factura real de golpe en el momento en que los créditos se acaben. Excluir los créditos hace que el presupuesto reporte lo que la cuenta está consumiendo realmente.
4. AWS Budgets es un mecanismo de **notificación y reporte**; observa costo y uso pero no tiene autoridad sobre los servicios que los generan. Para que algo se detenga tenés que agregar **Budget Actions**, que pueden aplicar una política IAM/SCP restrictiva, o parar instancias EC2/RDS, cuando se cruza un umbral — de forma automática o tras aprobación manual. Incluso entonces, "detener" es una acción explícita que configuraste, no un tope que AWS imponga en tu nombre.
5. 20% por encima de 1 M de requests = 200.000 requests extra × $0.20/1M = **$0.04**. El punto es la asimetría: el excedente de *requests* es trivial, mientras que un excedente equivalente del 20% sobre la cuota de 400.000 GB-segundos de duración (80.000 GB-s × $0.0000166667 ≈ $1,33) cuesta 33× más. Los excedentes del Free Tier conviene entenderlos por dimensión, no por porcentaje.
6. **Gratis:** los primeros dos AWS Budgets, la **consola** de Cost Explorer, y la AWS Pricing Calculator (que no necesita cuenta de AWS en absoluto). **Facturado:** la **API** de Cost Explorer, a $0.01 por request — que es por lo que hacer polling scripteado de `ce:GetCostAndUsage` en un loop es un costo autoinfligido genuino, aunque pequeño.

### Checkpoint 9

1. No. El gasto On-Demand es desperdicio solo si es **estable y predecible**. Antes de recomendar un compromiso tenés que preguntar: *¿cómo se ve el piso de uso horario en los últimos 60–90 días?* El gasto con picos, estacional, o que pertenece a una carga de trabajo agendada para dar de baja o replataformar, debería quedarse en On-Demand — comprometerlo convierte un costo variable en uno fijo exactamente en el peor momento.
2. 96,4% es saludable — los $6.41 sin usar son una pequeña prima de seguro contra caídas del uso. Reducirías el próximo compromiso cuando la utilización se ubique persistentemente **por debajo de ~95%**, porque la porción sin usar es plata por la que no recibiste nada. Pero 100% tampoco es el objetivo: significa que el compromiso está enteramente por debajo de tu piso de uso y casi con seguridad estás dejando descuento sobre la mesa — la respuesta correcta a una utilización sostenida del 100% es *aumentar* la cobertura, típicamente sumando un compromiso adicional en capas.
3. Porque un compromiso fija el **nivel de consumo de hoy durante uno a tres años**. Comprar un Savings Plan dimensionado sobre una flota sobredimensionada congela el desperdicio en el contrato: quedarías comprometido a pagar un gasto a escala `m6i.2xlarge`, y dimensionar bien después deja el compromiso varado y subutilizado. **Primero dimensioná bien, después comprometete sobre la base corregida.** Compute Optimizer es gratis, así que no hay razón para saltearlo.
4. (1) **Eliminar recursos ociosos** — nada es más barato que no correrlo. (2) **Dimensionar bien** lo que quede — establecer la línea base verdadera. (3) **Mover cargas elegibles a Spot** — esto las saca por completo de la base elegible para compromisos. (4) **Comprar compromisos** para el remanente estable. La regla: cada paso anterior cambia la línea base que mide el siguiente, y solo el último es contractualmente irreversible.
5. AWS recomienda un compromiso cercano al **piso de uso** observado, no al promedio, porque el uso no cubierto cae a On-Demand (una penalidad chica y recuperable) mientras que sobrecomprometerse es pérdida irrecuperable. Comprometete a **más** de lo recomendado solo si tenés conocimiento concreto del que el algoritmo carece — una migración que trae nuevas cargas estables, o un plan de crecimiento confirmado. Comprometete a **menos** si sabés algo que él no en la dirección contraria — un replataformado planificado, un contrato que termina, una salida de Región. En ausencia de ese conocimiento, tomá la recomendación y sumá compromisos adicionales en capas a medida que el uso se demuestre; **escalonar** compromisos chicos en el tiempo es estrictamente más seguro que uno grande.

### Trabajo final

1. Componente por componente:

| # | Componente | Modelo | Propiedad que lo fuerza |
|---|---|---|---|
| 1 | API pública, 3 × `m6i.large` 24/7 | **Savings Plan (Compute o EC2 Instance) 3 años**, o RI Standard | 100% de utilización sobre un horizonte largo y conocido — el equilibrio se supera muchas veces |
| 2 | ETL nocturno, 400 h/mes, con checkpoints | **Spot** (ASG de instancias mixtas, multi-AZ) | Tolerante a fallos y reiniciable; la interrupción solo cuesta rehacer trabajo |
| 3 | Warehouse migrando de EC2 → Fargate | **Compute Savings Plan** | Gasto estable, pero la *forma del recurso* va a cambiar |
| 4 | 40 M de invocaciones, 128 MB, 80 ms | **Lambda on-demand** (consumo); Compute SP si el piso es demostrable | Orientado a eventos, sub-segundo, sin línea base ociosa que pagar |
| 5 | Archivo de 40 TB, lectura < 1 vez/año, horas aceptables | **S3 Glacier Deep Archive** + política de ciclo de vida | Una latencia de recuperación de horas es aceptable, y el mínimo de 180 días está muy por debajo del período de retención |
| 6 | Oracle, licencia atada a sockets, reporte de núcleos | **Dedicated Host** (+ Dedicated Host Reservation) | Visibilidad de sockets/núcleos físicos y BYOL — nada más lo satisface |
| 7 | 25 TB/mes de egreso | **CloudFront** delante del origen | Contenido estático y cacheable; tarifa de egreso menor y fetch al origen gratis |

2. Solo un **Compute Savings Plan** sobrevive la migración de EC2 → Fargate con su descuento intacto, porque está denominado en dólares por hora y cubre por igual EC2, Fargate y Lambda. Un EC2 Instance Savings Plan de 3 años habría quedado atado a una familia de instancias en una Región: desde la fecha de migración en adelante pagarías el compromiso completo *y además* pagarías Fargate a tarifas on-demand — aproximadamente 28 meses de doble cargo.

3. 25 TB cae en el **tramo de 10–50 TB** (los primeros 100 GB son gratis, los primeros 10 TB a la tarifa más alta, el resto a la siguiente). El primer cambio arquitectónico es poner **CloudFront** delante: los fetches al origen pasan a ser gratis, la tarifa de egreso por GB es menor, aplica la capa gratuita de 1 TB/mes de CloudFront, y los aciertos de caché en el borde colapsan el tráfico al origen — con el beneficio adicional de menor latencia. Segundo cambio: verificar que los assets sean efectivamente cacheables (`Cache-Control` correcto), porque un CDN no cacheable es apenas un proxy más caro.

4. Los componentes **1 y 3** pueden compartir un mismo compromiso de Compute Savings Plan — ambos son cómputo EC2/Fargate estable, y el plan se aplica al uso que lo consuma; el componente 4 (Lambda) también podría sumarse si su piso es estable. El componente **6 no puede participar en absoluto**: el uso de Dedicated Host se factura como host y se cubre con Dedicated Host Reservations, no con Savings Plans. El componente 2 (Spot) y el componente 5 (S3) también quedan fuera del alcance de los compromisos de cómputo — Spot es un mecanismo de descuento aparte, y S3 es enteramente una dimensión de almacenamiento.

5. **Ajustá el compromiso a la forma de la curva de demanda: pagá On-Demand por lo impredecible, comprometete (RI o Savings Plan) por el piso que siempre está ahí, ofertá Spot por el trabajo que se puede interrumpir y reintentar, y pagá por consumo lo que no tiene piso alguno** — y después elegí *cuál* compromiso según cuánto es probable que cambie la forma del recurso antes de que termine el término.

</details>