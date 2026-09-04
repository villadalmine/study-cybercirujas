# Tema 4.3 — Identificar recursos técnicos de AWS y opciones de AWS Support

## Ejercicios guiados (CLF-C02, Dominio 4: Facturación, precios y soporte — 4.0% del peso del examen)

---

### Antes de empezar

**Cuánto cuesta este laboratorio:** nada. Todas las API que se invocan acá — AWS Support, AWS Health, AWS Trusted Advisor, Service Quotas, AWS Well-Architected Tool — son gratuitas. Lo único que cuesta dinero en este dominio es la **suscripción al plan de Support en sí**, y no se te va a pedir que compres una. Varios ejercicios están diseñados para ejecutarse desde una cuenta **Basic** o **Developer** justamente para que observes el modo de falla.

**Entorno:**

```bash
aws --version
# aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.rpm
```

**Permisos de IAM.** Adjuntá la política administrada por AWS `AWSSupportAccess` a tu principal (otorga `support:*`), más acceso de lectura para el resto:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Topic43Lab",
      "Effect": "Allow",
      "Action": [
        "support:Describe*",
        "support:Create*",
        "support:Add*",
        "support:Resolve*",
        "trustedadvisor:List*",
        "trustedadvisor:Get*",
        "health:Describe*",
        "servicequotas:List*",
        "servicequotas:Get*",
        "servicequotas:RequestServiceQuotaIncrease",
        "wellarchitected:List*",
        "wellarchitected:Get*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Detalle mecánico crítico — el endpoint.** AWS Support y AWS Health exponen **endpoints globales alojados en `us-east-1`** (`support.us-east-1.amazonaws.com`, `health.us-east-1.amazonaws.com`). Si ejecutás estos comandos con `--region eu-west-1` vas a obtener un error de resolución de endpoint o de autorización que parece un problema de permisos pero no lo es. Fijá la región explícitamente en cada llamada a Support/Health.

---

## Ejercicio 1 — Identificar el plan de Support de tu cuenta desde la CLI

La consola muestra tu plan en una página. La pregunta interesante es cómo lo descubre el software, porque eso es lo que te dice qué capacidades existen en esta cuenta.

### Pasos

1. Confirmá con qué identidad estás operando:

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "AIDA4XMPLQ7EXAMPLE3K",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/lab-operator"
}
```

2. Sondeá la API de AWS Support con su operación de lectura más barata. `DescribeSeverityLevels` devuelve una lista estática y es la sonda canónica de derechos (entitlement):

```bash
aws support describe-severity-levels \
  --language en \
  --region us-east-1
```

3. **Si la cuenta tiene Business, Enterprise On-Ramp o Enterprise Support**, obtenés la escalera de severidades:

```json
{
    "severityLevels": [
        { "code": "low",      "name": "General guidance" },
        { "code": "normal",   "name": "System impaired" },
        { "code": "high",     "name": "Production system impaired" },
        { "code": "urgent",   "name": "Production system down" },
        { "code": "critical", "name": "Business-critical system down" }
    ]
}
```

4. **Si la cuenta está en Basic o Developer**, la misma llamada falla — y el nombre de la excepción es toda la lección:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

5. Envolvé la sonda en un chequeo de derechos reutilizable:

```bash
if aws support describe-severity-levels --region us-east-1 >/dev/null 2>&1; then
  echo "Support API available -> Business / Enterprise On-Ramp / Enterprise"
else
  echo "Support API unavailable -> Basic or Developer"
fi
```

6. Enumerá la taxonomía de servicios/categorías que usa la consola de Support para enrutar tu caso. Esto es lo que puebla los dos desplegables cuando abrís un ticket (solo Business+):

```bash
aws support describe-services \
  --language en \
  --region us-east-1 \
  --query 'services[?contains(name, `Elastic Compute Cloud`)]' \
  --output json
```

```json
[
    {
        "code": "amazon-elastic-compute-cloud-linux",
        "name": "Amazon Elastic Compute Cloud (Linux)",
        "categories": [
            { "code": "instance-issue",    "name": "Instance Issue" },
            { "code": "connectivity",      "name": "Connectivity" },
            { "code": "performance",       "name": "Performance" },
            { "code": "ami",               "name": "AMI" },
            { "code": "ebs",               "name": "EBS" }
        ]
    }
]
```

7. Contá a cuántos servicios de primer nivel puede enrutar la API:

```bash
aws support describe-services --language en --region us-east-1 \
  --query 'length(services)'
```

```
267
```

### Verificación de comprensión — Bloque 1

1. Se devolvió `SubscriptionRequiredException`. Nombrá los **dos** planes de Support que lo producen y explicá por qué un `AccessDeniedException` habría significado algo completamente distinto.
2. Estás en Support **Basic**. ¿Podés abrir **algún** caso con AWS? Si la respuesta es sí, ¿de qué tipo y a través de qué interfaz?
3. ¿Por qué `aws support describe-severity-levels --region sa-east-1` falla incluso en una cuenta Enterprise?
4. Un desarrollador adjunta `ReadOnlyAccess` a un rol y se sorprende de que `describe-cases` siga fallando en una cuenta con plan Business. ¿Cuál es la causa más probable y qué política administrada lo soluciona?
5. Tu cuenta acaba de pasar de Developer a Business. ¿Necesitás cambiar algo del código de tu herramienta de automatización de casos para que empiece a funcionar?

---

## Ejercicio 2 — Códigos de severidad, objetivos de tiempo de respuesta y construcción de casos

La severidad no es una sensación. Es un campo de la API con un objetivo contractual de tiempo de respuesta asociado, y elegirla mal es la forma más común en que los equipos desperdician su derecho de Support.

### Pasos

1. Armá la tabla de correspondencias que tenés que tener memorizada. La columna `code` es lo que acepta la API; la columna `name` es lo que muestra la consola:

| `severityCode` de la API | Nombre en la consola | Significado en términos de producción |
|---|---|---|
| `low` | General guidance | Una consulta. Nada está roto. |
| `normal` | System impaired | Funciones no críticas se comportan de forma anómala. |
| `high` | Production system impaired | Producción está degradada pero sirviendo. |
| `urgent` | Production system down | Producción no está disponible. |
| `critical` | Business-critical system down | Sistema crítico para el negocio no disponible; impacto material en ingresos o regulatorio. |

2. Superponé los **objetivos de tiempo de primera respuesta** por plan. Fijate qué celdas están vacías — una celda vacía significa que esa severidad no se puede seleccionar en ese plan:

| Severidad | Basic | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| `low` — General guidance | — | < 24 horas hábiles | < 24 h | < 24 h | < 24 h |
| `normal` — System impaired | — | < 12 horas hábiles | < 12 h | < 12 h | < 12 h |
| `high` — Production impaired | — | — | < 4 h | < 4 h | < 4 h |
| `urgent` — Production down | — | — | < 1 h | < 1 h | < 1 h |
| `critical` — Business-critical down | — | — | — | < 30 min | < 15 min |

En esta tabla se esconden dos hechos estructurales: **Developer tiene techo en `normal` y su reloj corre solo en horario laboral** (12x5, en inglés, por email a Cloud Support Associates), mientras que **Business y superiores son 24x7 con teléfono, chat y email a Cloud Support Engineers**. Basic no tiene fila de soporte técnico en absoluto.

3. Generá un esqueleto de caso **sin enviar nada**. `--generate-cli-skeleton` es una operación del lado del cliente — sin llamada a la API, sin caso, sin cargo:

```bash
aws support create-case --generate-cli-skeleton > case.json
cat case.json
```

```json
{
    "subject": "",
    "serviceCode": "",
    "severityCode": "",
    "categoryCode": "",
    "communicationBody": "",
    "ccEmailAddresses": [],
    "language": "",
    "issueType": "",
    "attachmentSetId": ""
}
```

4. Completalo como un ticket de producción bien formado. Fijate en `issueType` — acepta `technical` o `customer-service`, y ese campo es exactamente el límite del plan Basic:

```json
{
    "subject": "ALB 502s on prod-checkout after target group re-registration",
    "serviceCode": "elastic-load-balancing",
    "severityCode": "high",
    "categoryCode": "application-load-balancer",
    "communicationBody": "Since 2026-09-04T14:10Z, arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/prod-checkout/50dc6c495c0c9188 returns HTTP 502 for ~7% of requests. TargetGroup prod-checkout-tg reports 6/6 healthy. ELB access logs show target_status_code '-' with elb_status_code 502 and target_processing_time -1. Instances i-0abcd1234efgh5678 and i-09876fedcba54321 show no application-level errors. Request: confirm whether the LB nodes are terminating connections before the target responds, and identify the reset reason.",
    "ccEmailAddresses": ["sre-oncall@example.com"],
    "language": "en",
    "issueType": "technical"
}
```

5. Enviálo **solo si tenés un problema real y un plan Business+**. Si no, salteá este paso — un caso en vivo consume el tiempo de un ingeniero humano:

```bash
aws support create-case --cli-input-json file://case.json --region us-east-1
```

```json
{
    "caseId": "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8"
}
```

6. Enumerá e inspeccioná casos sin tocar la consola:

```bash
aws support describe-cases \
  --include-resolved-cases \
  --max-results 10 \
  --region us-east-1 \
  --query 'cases[].{Id:displayId,Sev:severityCode,Status:status,Subject:subject}' \
  --output table
```

```
------------------------------------------------------------------------------
|                               DescribeCases                                |
+-------------+--------+---------------------+-------------------------------+
|     Id      |  Sev   |       Status        |            Subject            |
+-------------+--------+---------------------+-------------------------------+
|  9876543210 |  high  |  work-in-progress   |  ALB 502s on prod-checkout... |
|  9876543201 |  low   |  resolved           |  Clarify S3 Intelligent-Tie...|
+-------------+--------+---------------------+-------------------------------+
```

7. Leé el hilo de la conversación y respondé programáticamente:

```bash
aws support describe-communications \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --region us-east-1 \
  --query 'communications[].{When:timeCreated,From:submittedBy}' \
  --output table

aws support add-communication-to-case \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --communication-body "Attaching ELB access log sample for 14:10-14:25Z." \
  --region us-east-1
```

8. Cerralo cuando termines — resolver libera al ingeniero y detiene la cadencia de seguimiento:

```bash
aws support resolve-case \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --region us-east-1
```

```json
{
    "initialCaseStatus": "work-in-progress",
    "finalCaseStatus": "resolved"
}
```

### Verificación de comprensión — Bloque 2

6. Un cliente con Support **Developer** envía `--severity-code urgent`. ¿Qué pasa y cuál es la severidad más alta que realmente puede seleccionar?
7. Tu servicio de autorización de pagos está completamente caído a las 03:00 de un domingo. Estás en Support **Business**. ¿Cuál es la severidad más alta disponible y qué objetivo de tiempo de respuesta tiene? ¿Qué plan te habría dado un objetivo de 15 minutos?
8. Los objetivos de tiempo de respuesta son de **primera respuesta**. Explicá, en términos de producción, por qué "primera respuesta en menos de 1 hora" *no* es lo mismo que "resolución en menos de 1 hora", y qué implica eso para tu propio runbook de incidentes.
9. ¿Qué único campo del esqueleto de `create-case` determina si a una cuenta con plan **Basic** se le permite abrir el caso, y qué valor debe tener?
10. ¿Por qué es seguro ejecutar `--generate-cli-skeleton` en cualquier cuenta, a cualquier hora, en cualquier plan?

---

## Ejercicio 3 — AWS Trusted Advisor: el asesor automatizado

Trusted Advisor es el ejemplo canónico del examen de un **recurso técnico de AWS que inspecciona tu cuenta** en lugar de uno que leés. Evalúa tu configuración en vivo contra las mejores prácticas de AWS en seis pilares.

### Pasos

1. Listá todos los chequeos que la cuenta puede ver, agrupados por categoría:

```bash
aws support describe-trusted-advisor-checks \
  --language en \
  --region us-east-1 \
  --query 'checks[].category' \
  --output text | tr '\t' '\n' | sort | uniq -c | sort -rn
```

```
     49 cost_optimizing
     41 security
     38 fault_tolerance
     19 performance
     14 service_limits
      9 operational_excellence
```

Tus conteos van a diferir — AWS agrega y retira chequeos continuamente. Lo que importa son los **seis nombres de categoría**, porque esas son las categorías que nombra el examen.

2. Aislá un chequeo y capturá su `id` opaco. Nunca hardcodees un ID de chequeo que copiaste de un blog; derivalo:

```bash
CHECK_ID=$(aws support describe-trusted-advisor-checks \
  --language en --region us-east-1 \
  --query "checks[?name=='IAM Access Key Rotation'].id | [0]" \
  --output text)
echo "$CHECK_ID"
```

```
DqdJqYeRm5
```

3. Forzá una evaluación fresca. Los chequeos están cacheados; un refresh es asincrónico y está limitado por tasa para cada chequeo:

```bash
aws support refresh-trusted-advisor-check --check-id "$CHECK_ID" --region us-east-1
```

```json
{
    "status": {
        "checkId": "DqdJqYeRm5",
        "status": "enqueued",
        "millisUntilNextRefreshable": 0
    }
}
```

4. Sondeá hasta que el refresh aterrice, después leé el veredicto:

```bash
aws support describe-trusted-advisor-check-refresh-statuses \
  --check-ids "$CHECK_ID" --region us-east-1 \
  --query 'statuses[0].status'
```

```
"success"
```

```bash
aws support describe-trusted-advisor-check-result \
  --check-id "$CHECK_ID" --language en --region us-east-1 \
  --query 'result.{Status:status,Summary:resourcesSummary}'
```

```json
{
    "Status": "warning",
    "Summary": {
        "resourcesProcessed": 14,
        "resourcesFlagged": 3,
        "resourcesIgnored": 0,
        "resourcesSuppressed": 0
    }
}
```

El vocabulario de `status` es `ok` (verde), `warning` (amarillo), `error` (rojo) y `not_available`.

5. Obtené un resumen de toda la cuenta en una sola llamada — esta es la barra de resumen de la consola, en JSON:

```bash
aws support describe-trusted-advisor-check-summaries \
  --check-ids $(aws support describe-trusted-advisor-checks --language en \
      --region us-east-1 --query 'checks[?category==`service_limits`].id' \
      --output text | tr '\t' ' ') \
  --region us-east-1 \
  --query 'summaries[?status!=`ok`].{Check:checkId,Status:status,Flagged:resourcesSummary.resourcesFlagged}' \
  --output table
```

6. Probá la **API dedicada y más nueva de Trusted Advisor** (distinta del namespace heredado `support`), que habla en recomendaciones en vez de chequeos crudos:

```bash
aws trustedadvisor list-recommendations \
  --region us-east-1 \
  --max-results 5 \
  --query 'recommendationSummaries[].{Name:name,Pillar:pillars[0],Status:status}' \
  --output table
```

7. Ahora el límite de derechos. En una cuenta **Basic** o **Developer**, los pasos 1–6 fallan con `SubscriptionRequiredException` — *la API es solo Business+*. Pero abrí la consola en `https://console.aws.amazon.com/trustedadvisor/` en esa misma cuenta Basic y vas a seguir viendo resultados: **todos los chequeos de Service Quotas más un conjunto básico de chequeos de seguridad**. El catálogo completo de seis categorías y todo el acceso programático requieren Business, Enterprise On-Ramp o Enterprise.

### Verificación de comprensión — Bloque 3

11. Nombrá las seis categorías de chequeos de Trusted Advisor.
12. Un cliente con plan Basic dice "Trusted Advisor está roto, la CLI devuelve un error, pero mi colega ve chequeos en la consola". Reconciliá ambas observaciones en una sola oración.
13. ¿Qué categoría de Trusted Advisor marcaría *"estás al 92% de tu cuota de instancias Running On-Demand Standard en us-east-1"*, y cuál marcaría *"tu instancia RDS no tiene standby Multi-AZ"*?
14. `refresh-trusted-advisor-check` devolvió `millisUntilNextRefreshable: 254000`. ¿Qué te dice eso y qué debería hacer tu bucle de sondeo?
15. **Trusted Advisor Priority** y un **Technical Account Manager designado** — ¿qué plan de Support se requiere para cada uno?

---

## Ejercicio 4 — AWS Health: salud del servicio vs. *tu* salud

Los estudiantes confunden dos dashboards distintos. Responden preguntas diferentes y uno de ellos está personalizado a tu cuenta.

### Pasos

1. Abrí la vista **pública** — AWS Health Dashboard *Service health*, en `https://health.aws.amazon.com/health/status`. Sin iniciar sesión. Reporta el estado general de los servicios de AWS por Región. Responde: *"¿AWS está teniendo un problema?"*

2. Abrí la vista **personalizada** — AWS Health Dashboard *Your account health*, en `https://health.aws.amazon.com/health/home`, con sesión iniciada. Responde una pregunta estrictamente más acotada y mucho más útil: *"¿AWS está teniendo un problema **que toca recursos de mi cuenta**, y tengo cambios programados por venir?"* Esta vista está disponible en **todos los planes de Support, incluido Basic**.

3. Consultala programáticamente. La API de AWS Health es **solo Business, Enterprise On-Ramp y Enterprise**, y vive en el endpoint global `us-east-1`:

```bash
aws health describe-events \
  --region us-east-1 \
  --filter eventStatusCodes=open,upcoming \
  --query 'events[].{Service:service,Region:region,Type:eventTypeCategory,Code:eventTypeCode,Start:startTime}' \
  --output table
```

```
--------------------------------------------------------------------------------------------
|                                     DescribeEvents                                       |
+---------+-------------+------------------------+------------------------------+----------+
| Service |   Region    |         Type           |            Code              |  Start   |
+---------+-------------+------------------------+------------------------------+----------+
|  EC2    | us-east-1   | scheduledChange        | AWS_EC2_INSTANCE_RETIREMENT..| 2026-09..|
|  RDS    | eu-west-1   | accountNotification    | AWS_RDS_MAINTENANCE_SCHEDU...| 2026-09..|
+---------+-------------+------------------------+------------------------------+----------+
```

El vocabulario de `eventTypeCategory` es el concepto clave: `issue` (AWS está degradado), `scheduledChange` (AWS va a cambiar algo en una fecha), `accountNotification` (informativo, específico de la cuenta) e `investigation`.

4. Pasá de *"existe un evento"* a *"cuáles de mis recursos están dentro"* — este es todo el sentido del dashboard personalizado:

```bash
ARN=$(aws health describe-events --region us-east-1 \
  --filter eventTypeCategories=scheduledChange,eventStatusCodes=upcoming \
  --query 'events[0].arn' --output text)

aws health describe-affected-entities \
  --region us-east-1 \
  --filter "eventArns=$ARN" \
  --query 'entities[].{Resource:entityValue,Status:statusCode}' \
  --output table
```

```
-------------------------------------------
|         DescribeAffectedEntities        |
+-------------------------+---------------+
|        Resource         |    Status     |
+-------------------------+---------------+
|  i-0abcd1234efgh5678    |  IMPAIRED     |
|  i-09876fedcba54321     |  UNIMPAIRED   |
+-------------------------+---------------+
```

5. Obtené la narrativa legible por humanos que AWS publica para ese evento:

```bash
aws health describe-event-details --region us-east-1 --event-arns "$ARN" \
  --query 'successfulSet[0].eventDescription.latestDescription' --output text
```

6. Agregá conteos para una página de estado o una revisión semanal:

```bash
aws health describe-event-aggregates \
  --region us-east-1 \
  --aggregate-field eventTypeCategory \
  --filter eventStatusCodes=open \
  --output table
```

7. En **Basic** o **Developer**, todos los comandos de los pasos 3–6 fallan:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeEvents operation: AWS Premium Support Subscription is required
to use this service.
```

…mientras que el dashboard personalizado de la **consola** del paso 2 sigue funcionando. La misma división que con Trusted Advisor: consola sí, API no.

### Verificación de comprensión — Bloque 4

16. Hay un evento de S3 en curso a nivel de toda una Región. ¿Qué dashboard te dice *si tus buckets están afectados* y cuál te dice solamente *que AWS tiene un problema*?
17. Tu instancia EC2 está programada para retirarse en nueve días. ¿Qué `eventTypeCategory` transporta eso y qué dashboard lo expone **sin** un plan de Support pago?
18. Querés una regla de EventBridge que llame al on-call cada vez que AWS publique un evento `issue` que toque tu cuenta. ¿Qué planes de Support lo hacen posible y por qué el plan mínimo es el mismo que desbloquea la API de Health?
19. Explicá por qué `describe-events` con `--region eu-central-1` es la llamada equivocada incluso para una cuenta Enterprise con todas sus cargas de trabajo en Frankfurt.

---

## Ejercicio 5 — Service Quotas: el recurso técnico que reemplazó a un caso de Support

Históricamente, subir un límite significaba abrir un ticket. Service Quotas convirtió la mayor parte de eso en una API de autoservicio — y funciona en **todos** los planes de Support, Basic incluido. Este es un distractor favorito del examen.

### Pasos

1. Encontrá el código de servicio y después el código de cuota. Ambos son cadenas opacas y ambos hay que buscarlos, nunca adivinarlos:

```bash
aws service-quotas list-services --region us-east-1 \
  --query 'Services[?contains(ServiceName, `Elastic Compute`)]' --output table
```

```
--------------------------------------------------------------
|                        ListServices                        |
+--------------+---------------------------------------------+
| ServiceCode  |                ServiceName                  |
+--------------+---------------------------------------------+
|  ec2         |  Amazon Elastic Compute Cloud (Amazon EC2)  |
+--------------+---------------------------------------------+
```

2. Localizá la cuota que realmente limita tu escalado horizontal. Notá que se mide en **vCPUs**, no en instancias — una trampa clásica de producción:

```bash
aws service-quotas list-service-quotas \
  --service-code ec2 --region us-east-1 \
  --query "Quotas[?contains(QuotaName, 'On-Demand Standard')].{Code:QuotaCode,Name:QuotaName,Value:Value,Unit:Unit,Adjustable:Adjustable}" \
  --output json
```

```json
[
    {
        "Code": "L-1216C47A",
        "Name": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
        "Value": 64.0,
        "Unit": "None",
        "Adjustable": true
    }
]
```

3. Compará el valor **aplicado** contra el **default** de AWS. Difieren siempre que alguien ya lo haya subido:

```bash
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region us-east-1 \
  --query 'Quota.{Applied:Value,Adjustable:Adjustable,Global:GlobalQuota}'

aws service-quotas get-aws-default-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region us-east-1 \
  --query 'Quota.Value'
```

```json
{ "Applied": 64.0, "Adjustable": true, "Global": false }
```
```
5.0
```

4. Solicitá un aumento. Sin plan de Support requerido, sin consola:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 256 \
  --region us-east-1
```

```json
{
    "RequestedQuota": {
        "Id": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6",
        "ServiceCode": "ec2",
        "QuotaCode": "L-1216C47A",
        "DesiredValue": 256.0,
        "Status": "PENDING",
        "Created": "2026-09-04T15:22:41.310000-03:00",
        "Requester": "{\"accountId\":\"111122223333\"}"
    }
}
```

5. Seguí su rastro. `CASE_OPENED` significa que Service Quotas escaló tu solicitud a un caso de Support real en tu nombre:

```bash
aws service-quotas list-requested-service-quota-change-history \
  --service-code ec2 --region us-east-1 \
  --query 'RequestedQuotas[].{Quota:QuotaName,Want:DesiredValue,Status:Status}' \
  --output table
```

```
---------------------------------------------------------------------------
|             ListRequestedServiceQuotaChangeHistory                      |
+----------------------------------------+---------+----------------------+
|                 Quota                  |  Want   |       Status         |
+----------------------------------------+---------+----------------------+
|  Running On-Demand Standard instances  |  256.0  |  CASE_OPENED         |
+----------------------------------------+---------+----------------------+
```

6. Configurá alertas proactivas en vez de descubrir el techo durante un pico de tráfico. Service Quotas publica la utilización en CloudWatch bajo `AWS/Usage`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name ec2-standard-vcpu-at-80pct \
  --namespace AWS/Usage \
  --metric-name ResourceCount \
  --dimensions Name=Service,Value=EC2 Name=Resource,Value=vCPU \
               Name=Type,Value=Resource Name=Class,Value=Standard/OnDemand \
  --statistic Maximum --period 300 --evaluation-periods 1 \
  --threshold 51 --comparison-operator GreaterThanOrEqualToThreshold \
  --region us-east-1
```

7. Contrastá la misma verdad de campo desde la otra dirección — la categoría `service_limits` de Trusted Advisor (Business+) reporta el mismo margen disponible:

```bash
aws support describe-trusted-advisor-check-result \
  --check-id eW7HH0l7J9 --language en --region us-east-1 \
  --query 'result.flaggedResources[?metadata[3]!=null].metadata' --output json
```

### Verificación de comprensión — Bloque 5

20. Tu cuenta está en Support **Basic** y necesitás que suban la cuota de vCPU de EC2. ¿Es posible? ¿A través de qué mecanismo, y requiere comprar un plan?
21. Volvió `Adjustable: false` para una cuota. ¿Cuáles son tus opciones?
22. `Value` marca `64.0` pero `get-aws-default-service-quota` marca `5.0`. ¿Qué te dice eso sobre la historia de la cuenta?
23. Una solicitud estuvo en `PENDING` y después pasó a `CASE_OPENED`. ¿Qué pasó realmente detrás de escena y dónde podés leer ahora la correspondencia humana?
24. El chequeo `service_limits` de Trusted Advisor y la consola de Service Quotas reportan ambos el margen de EC2. ¿Cuál puede *cambiar* el valor y cuál es solo un observador?

---

## Ejercicio 6 — Recursos técnicos de autoservicio: documentación, guías y herramientas

Estos son gratuitos, ilimitados y están disponibles en todos los planes. El examen espera que enrutes una pregunta al recurso *correcto*.

### Pasos

1. Recorré el catálogo y registrá para qué sirve cada uno, no solo cómo se llama:

| Recurso | URL | La pregunta que responde |
|---|---|---|
| AWS Documentation | `https://docs.aws.amazon.com/` | "¿Cuáles son los parámetros, límites y comportamiento exacto de esta API?" |
| AWS Whitepapers & Guides | `https://aws.amazon.com/whitepapers/` | "¿Cuál es la posición formal de AWS sobre seguridad, DR o migración?" |
| AWS Architecture Center | `https://aws.amazon.com/architecture/` | "¿Cuál es una arquitectura de referencia para este patrón?" |
| AWS Well-Architected Framework | `https://aws.amazon.com/architecture/well-architected/` | "¿Cuáles son los seis pilares y mi carga de trabajo los respeta?" |
| AWS Prescriptive Guidance | `https://aws.amazon.com/prescriptive-guidance/` | "Dame un plan de migración/modernización paso a paso y con opinión." |
| AWS Solutions Library | `https://aws.amazon.com/solutions/` | "¿Existe un stack de CloudFormation validado y desplegable para esto?" |
| AWS re:Post | `https://repost.aws/` | "¿Otro cliente (o un experto de AWS) ya resolvió esto?" — Q&A comunitario, reemplazó a los AWS Forums |
| AWS Knowledge Center | `https://repost.aws/knowledge-center/` | "¿Cuál es la respuesta canónica a esta pregunta de soporte frecuente?" |
| AWS Blogs | `https://aws.amazon.com/blogs/` | "¿Cómo uso una funcionalidad anunciada el mes pasado?" |
| AWS Skill Builder | `https://skillbuilder.aws/` | "¿Dónde me capacito y hago exámenes de práctica?" |
| AWS Marketplace | `https://aws.amazon.com/marketplace/` | "¿Puedo comprar y desplegar software de terceros facturado por AWS?" |
| AWS Pricing Calculator | `https://calculator.aws/` | "¿Cuánto va a costar esta arquitectura antes de construirla?" |

2. Ejecutá la Well-Architected Tool desde la CLI — es un servicio de AWS real y gratuito, no un PDF:

```bash
aws wellarchitected list-lenses --region us-east-1 \
  --query 'LensSummaries[].{Alias:LensAlias,Name:LensName}' --output table
```

```
----------------------------------------------------------------------
|                            ListLenses                              |
+---------------------------------+----------------------------------+
|              Alias              |              Name                |
+---------------------------------+----------------------------------+
|  wellarchitected                |  AWS Well-Architected Framework  |
|  serverless                     |  Serverless Lens                 |
|  softwareasaservice             |  SaaS Lens                       |
|  foundationaltechnicalreview    |  FTR Lens                        |
+---------------------------------+----------------------------------+
```

3. Definí una carga de trabajo y adjuntale el lens del framework:

```bash
aws wellarchitected create-workload \
  --workload-name prod-checkout \
  --description "Customer-facing checkout API" \
  --environment PRODUCTION \
  --aws-regions us-east-1 \
  --lenses wellarchitected \
  --review-owner "sre-oncall@example.com" \
  --region us-east-1
```

```json
{
    "WorkloadId": "9a1b2c3d4e5f60718293a4b5c6d7e8f9",
    "WorkloadArn": "arn:aws:wellarchitected:us-east-1:111122223333:workload/9a1b2c3d4e5f60718293a4b5c6d7e8f9"
}
```

4. Traé las preguntas de la revisión y el perfil de riesgo actual:

```bash
aws wellarchitected list-lens-review-improvements \
  --workload-id 9a1b2c3d4e5f60718293a4b5c6d7e8f9 \
  --lens-alias wellarchitected --region us-east-1 \
  --query 'ImprovementSummaries[].{Pillar:PillarId,Question:QuestionTitle,Risk:Risk}' \
  --output table
```

```
-----------------------------------------------------------------------------
|                     ListLensReviewImprovements                            |
+---------------+--------------------------------------------+--------------+
|    Pillar     |                 Question                   |     Risk     |
+---------------+--------------------------------------------+--------------+
|  reliability  |  How do you back up data?                  |  HIGH        |
|  security     |  How do you manage identities for people?  |  MEDIUM      |
|  operational- |  How do you reduce defects and improve...  |  MEDIUM      |
+---------------+--------------------------------------------+--------------+
```

5. Limpiá para no dejar una revisión obsoleta atrás:

```bash
aws wellarchitected delete-workload \
  --workload-id 9a1b2c3d4e5f60718293a4b5c6d7e8f9 \
  --client-request-token "$(uuidgen)" --region us-east-1
```

### Verificación de comprensión — Bloque 6

25. Un ingeniero junior pregunta *"¿qué hace el flag `--dry-run` en `RunInstances`?"*. Enrutalo a exactamente un recurso y justificalo en una oración.
26. Tu CTO pide la postura oficial de AWS sobre los límites de la responsabilidad compartida para una auditoría de cumplimiento. ¿Qué recurso, y por qué no re:Post?
27. Distinguí **AWS re:Post** del **AWS Knowledge Center** y de un **caso de Support**. ¿Cuál es el orden de escalado entre los tres?
28. La Well-Architected Tool devolvió `Risk: HIGH` para "How do you back up data?". ¿Es una factura, una advertencia o una acción de cumplimiento forzoso? ¿Qué le hace realmente la herramienta a tu infraestructura?
29. Necesitás un despliegue de CloudFormation listo para producción y validado por AWS para un patrón de logging centralizado. ¿Architecture Center o Solutions Library — cuál, y cuál es la diferencia?

---

## Ejercicio 7 — Personas y socios: cuando el software no es la respuesta

Algunos problemas no los responde una API. El examen evalúa si sabés qué organización humana es dueña de qué problema.

### Pasos

1. Estudiá el catálogo humano/organizacional:

| Recurso | Qué es | Disponibilidad |
|---|---|---|
| **AWS Support Engineers** (Cloud Support Associates / Engineers) | Resolución técnica reactiva vía casos | Developer (Associates, horario laboral) / Business+ (Engineers, 24x7) |
| **Technical Account Manager (TAM)** | Defensor nombrado y proactivo: guía de arquitectura, revisiones operativas, planificación de lanzamientos, escalado | **Pool de TAMs** en Enterprise On-Ramp; **TAM designado** en Enterprise |
| **AWS Concierge Support Team** | Expertos en facturación y cuentas; análisis no técnico de cuenta/facturación | Enterprise On-Ramp y Enterprise |
| **AWS Professional Services (ProServe)** | Equipo global de consultoría pago, por proyecto, que construye *con* vos | Cualquier cliente; contratación y costo aparte |
| **AWS Partner Network (APN)** | Firmas de terceros: **Consulting Partners** (servicios/implementación) y **Technology Partners** (software/ISVs) | Cualquier cliente |
| **AWS Managed Services (AMS)** | AWS opera tu infraestructura por vos — parcheo, monitoreo, gestión de incidentes, control de cambios | Suscripción paga; requiere Enterprise Support |
| **AWS IQ** | Marketplace de contrataciones cortas y a demanda con freelancers/firmas certificados por AWS | Cualquier cliente (expertos radicados en EE.UU.) |
| **AWS Activate** | Programa para startups: créditos, guía técnica, capacitación | Startups elegibles |
| **AWS Solutions Architects (SAs)** | Arquitectos de preventa/diseño asignados por tu equipo de cuenta | Depende del equipo de cuenta |
| **AWS Trust & Safety / Abuse team** | Maneja abusos *originados desde* o *dirigidos a* recursos de AWS | Cualquier cliente, cualquier plan |
| **AWS Countdown** (antes Infrastructure Event Management) | Planificación guiada + soporte en tiempo real para un evento de alto tráfico o migración específica | Incluido con Enterprise; cargo adicional en Business |
| **AWS Incident Detection and Response (IDR)** | Monitoreo proactivo con un SLA de participación de 5 minutos sobre tus cargas críticas | Enterprise Support (complemento pago) |
| **AWS Trusted Advisor Priority** | Hallazgos de Trusted Advisor curados y priorizados por el TAM, empujados hacia vos | Enterprise |

2. Reportá abuso. Notá que esto no necesita **ningún** plan de Support y es una vía distinta de un caso técnico:

```
Console:  https://support.aws.amazon.com/#/contacts/report-abuse
Email:    abuse@amazonaws.com
API:      issueType = "customer-service", serviceCode = "customer-account"
```

3. Modelá tu propia escalera de escalado para un incidente real. Escribila para `prod-checkout` en un plan Enterprise:

```
T+0    Detect          CloudWatch alarm -> PagerDuty -> on-call
T+2m   Triage          AWS Health Dashboard (your account health) — is this AWS or us?
T+5m   If AWS-side     aws support create-case --severity-code critical   (< 15 min target)
T+5m   In parallel     Notify TAM directly (Slack/phone) — TAM does not replace the case,
                       the TAM escalates and coordinates the case
T+15m  AWS engaged     Cloud Support Engineer on bridge; TAM owns internal escalation
T+1h   If quota-bound  Service Quotas increase request (self-service, not a case)
T+24h  Post-incident   TAM-led operations review; Trusted Advisor Priority follow-ups
```

4. Practicá el enrutamiento. Para cada escenario, nombrá el **único mejor** recurso:

   a. "Necesitamos que alguien re-plataforme físicamente 400 VMs on-prem hacia AWS en nueve meses, con hitos de entrega contractuales."
   b. "Una instancia EC2 en la cuenta de otro está escaneando puertos de nuestra VPC."
   c. "Queremos que AWS haga el parcheo, los backups y la gestión de cambios en nuestras cuentas para que nuestro equipo deje de hacerlo."
   d. "Necesito cuarenta horas de ayuda de un experto certificado para arreglar nuestro pipeline de CI/CD, empezando la semana que viene, sin ciclo de compras."
   e. "Nuestra factura muestra una asignación de Savings Plan que no entendemos, y estamos en Enterprise Support."
   f. "Vamos a lanzar un aviso en el Super Bowl y esperamos 60x de tráfico durante cuatro horas en una sola fecha."
   g. "Somos una startup en etapa seed y necesitamos créditos de AWS más guía de arquitectura."
   h. "Queremos comprar un WAF de terceros y que se facture en nuestra factura de AWS."

### Verificación de comprensión — Bloque 7

30. Distinguí un **TAM** de un **Cloud Support Engineer** en términos de *reactivo vs. proactivo* y *nombrado vs. de pool*.
31. ¿Qué dos planes de Support incluyen al **Concierge Support Team**, y de qué clase de preguntas son dueños?
32. **AWS Professional Services** vs. un **APN Consulting Partner** — ambos hacen trabajo de implementación. ¿Cuál es la diferencia real y qué comparten?
33. **AWS Managed Services (AMS)** vs. **AWS Support** — uno de estos opera tu infraestructura. ¿Cuál, y qué plan de Support presupone?
34. Tu cuenta no tiene plan de Support pago y estás recibiendo un ataque de fuerza bruta SSH desde una IP de EC2. ¿Podés reportarlo? ¿Por qué vía?
35. Un cliente en Support **Business** quiere soporte guiado para un evento de tráfico 60x de un día. ¿Cómo se llama la oferta y cuál es la implicancia de costo frente a Enterprise?

---

## Ejercicio 8 — Ejercicio de síntesis: enrutá cada señal

Recorré esto sin consultar nada. Cada línea tiene exactamente una mejor respuesta.

### Pasos

1. Para cada situación, nombrá **(a)** el recurso u opción y **(b)** el plan de Support mínimo requerido:

| # | Situación |
|---|---|
| 1 | Verificar si AWS tiene un problema a nivel de Región, desde una laptop sin credenciales de AWS |
| 2 | Descubrir que un retiro programado de EC2 va a impactar dos de *tus* instancias |
| 3 | Obtener una primera respuesta en menos de 15 minutos para una caída que corta ingresos |
| 4 | Obtener una primera respuesta en menos de 30 minutos para una caída que corta ingresos |
| 5 | Automatizar la creación de casos desde tu plataforma de gestión de incidentes |
| 6 | Subir la cuota de cantidad de buckets de S3 en una cuenta de capa gratuita |
| 7 | Encontrar volúmenes EBS sin adjuntar que desperdician dinero, en toda la cuenta, automáticamente |
| 8 | Hacer una consulta general "¿cómo funciona el versionado de S3?" con un presupuesto de $29/mes |
| 9 | Tener un humano nombrado que conozca tu arquitectura y participe de tus revisiones trimestrales |
| 10 | Contratar un experto certificado para un trabajo de dos semanas sin una licitación |
| 11 | Leer la guía formal y citable de AWS sobre el modelo de responsabilidad compartida |
| 12 | Comprar software comercial y que aparezca en tu factura de AWS |
| 13 | Reportar que un host alojado en AWS te está atacando |
| 14 | Que AWS monitoree proactivamente una carga crítica y se involucre en 5 minutos |
| 15 | Puntuar una carga de trabajo contra los seis pilares y obtener una lista de riesgos ordenada |

2. Verificá tus respuestas contra la clave de abajo, después re-derivá las que fallaste **desde el límite de derechos** en vez de desde la memoria — casi todas se deciden por una de tres líneas: *Basic vs. pago*, *Developer vs. Business*, o *Business vs. Enterprise*.

### Verificación de comprensión — Bloque 8

36. Enunciá los tres límites de derechos del paso 2 como una oración cada uno, nombrando qué cruza en cada línea.
37. Dos capacidades de este tema están disponibles en **todos** los planes, incluido Basic, y aun así los estudiantes suelen suponer que son pagas. Nombrá las dos.
38. Dos capacidades son **visibles en la consola en Basic pero bloqueadas por API a Business+**. Nombralas y explicá por qué AWS traza la línea ahí.

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Compare AWS Support Plans — https://aws.amazon.com/premiumsupport/plans/
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/
- AWS Support API Reference — https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Health User Guide — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- AWS Health Dashboard (Service health) — https://health.aws.amazon.com/health/status
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- AWS Well-Architected Tool User Guide — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS re:Post — https://repost.aws/ · Knowledge Center — https://repost.aws/knowledge-center/
- AWS Whitepapers & Guides — https://aws.amazon.com/whitepapers/
- AWS Architecture Center — https://aws.amazon.com/architecture/
- AWS Prescriptive Guidance — https://aws.amazon.com/prescriptive-guidance/
- AWS Solutions Library — https://aws.amazon.com/solutions/
- AWS Professional Services — https://aws.amazon.com/professional-services/
- AWS Managed Services — https://aws.amazon.com/managed-services/
- AWS Partner Network — https://aws.amazon.com/partners/
- AWS Marketplace — https://aws.amazon.com/marketplace/
- AWS IQ — https://aws.amazon.com/iq/ · AWS Activate — https://aws.amazon.com/activate/
- Report AWS abuse — https://support.aws.amazon.com/#/contacts/report-abuse
- AWS CLI Command Reference (`support`) — https://docs.aws.amazon.com/cli/latest/reference/support/

> Los precios y las matrices de funcionalidades de los planes de Support cambian. Tratá la página de comparación de planes como la autoridad al momento del examen; los objetivos de tiempo de respuesta de este material reflejan la matriz publicada a 2026-09.

---

<details>
<summary><strong>Clave de respuestas — hacé clic para expandir</strong></summary>

### Bloque 1 — Identificación del plan de Support

**1.** `SubscriptionRequiredException` lo devuelven **Basic** y **Developer**. Es un error de *derechos*: el llamante está autenticado y autorizado en IAM, pero la cuenta no compró la funcionalidad. `AccessDeniedException` sería un error de *autorización* — la cuenta tiene la funcionalidad, pero este principal no tiene el permiso de IAM. La remediación es completamente distinta: comprar un plan vs. arreglar una política.

**2.** Sí. Basic incluye acceso 24x7 al **servicio al cliente** para consultas de **cuenta y facturación**, más reportes de abuso. Lo que Basic excluye son los casos de soporte **técnico**. Se abren a través de la consola del Support Center; la **API** de Support no está disponible en Basic sin importar el tipo de caso.

**3.** AWS Support es un **servicio global con su endpoint en `us-east-1`** (`support.us-east-1.amazonaws.com`). No existe un endpoint de Support en `sa-east-1`, así que la solicitud falla en la resolución del endpoint o en la firma — no por derechos ni por permisos.

**4.** Históricamente `ReadOnlyAccess` no confiere las acciones `support:*` necesarias para la API de Support. Adjuntá la política administrada por AWS **`AWSSupportAccess`**. (Confirmá que la falla sea `AccessDeniedException` y no `SubscriptionRequiredException` — esa distinción te dice cuál de los dos arreglos aplica.)

**5.** No. La superficie de la API es idéntica; solo cambió el derecho. Las mismas llamadas `create-case` / `describe-cases` que devolvían `SubscriptionRequiredException` ahora funcionan. Business además desbloquea las severidades `high` y `urgent` para el argumento `--severity-code`.

---

### Bloque 2 — Severidad y construcción de casos

**6.** Developer solo soporta `low` (General guidance) y `normal` (System impaired). Pasar `urgent` se rechaza — la API de Support no está disponible en Developer en absoluto, y en la consola las severidades más altas no son seleccionables. La más alta disponible es **`normal` / System impaired, < 12 horas hábiles**.

**7.** En Business el techo es **`urgent` / Production system down, con un objetivo de primera respuesta < 1 hora** — 24x7, así que el domingo a las 03:00 está totalmente cubierto. Un objetivo de **< 15 minutos** requiere **Enterprise Support** y la severidad `critical` / Business-critical system down. Enterprise On-Ramp daría **< 30 minutos**.

**8.** El objetivo es cuándo un Cloud Support Engineer **responde por primera vez**, no cuándo se arregla el problema. El tiempo de resolución no tiene cota y depende de la causa. Operativamente esto significa que AWS Support es un flujo de trabajo *paralelo*, nunca tu mitigación primaria: tu runbook igual tiene que contener pasos de failover, rollback y desvío de tráfico que ejecutás vos mientras el caso está abierto.

**9.** **`issueType`**. Las cuentas con plan Basic solo pueden abrir casos con `issueType: "customer-service"` (cuenta y facturación). `issueType: "technical"` requiere Developer o superior — y por API, Business o superior.

**10.** `--generate-cli-skeleton` se evalúa **enteramente del lado del cliente** por la AWS CLI a partir de su modelo de servicio embebido. Emite una plantilla JSON y **no hace ninguna llamada a la API**, así que no puede fallar por derechos, no puede crear un caso y no consume tiempo de ningún ingeniero.

---

### Bloque 3 — Trusted Advisor

**11.** **Cost Optimization, Performance, Security, Fault Tolerance, Service Limits (Service Quotas) y Operational Excellence.**

**12.** Ambas cosas son ciertas: en Basic/Developer la **consola** de Trusted Advisor muestra todos los chequeos de Service Quotas más un conjunto básico de chequeos de seguridad, mientras que el **acceso programático a través de las API de Support y de Trusted Advisor — y el catálogo completo de seis categorías — requieren Business, Enterprise On-Ramp o Enterprise.**

**13.** El hallazgo de margen de cuota es **Service Limits**. La falta de standby Multi-AZ en RDS es **Fault Tolerance**.

**14.** `millisUntilNextRefreshable: 254000` significa que ese chequeo está **limitado por tasa durante otros ~254 segundos** y una solicitud de refresh ahora es un no-op. Tu bucle de sondeo debería leer este campo y esperar al menos esa duración en vez de martillar la API — y debería sondear `describe-trusted-advisor-check-refresh-statuses` (buscando `success`), no el endpoint de resultados, para saber cuándo aterrizó el refresh.

**15.** **Trusted Advisor Priority: solo Enterprise Support.** **TAM designado (nombrado): Enterprise Support.** Enterprise On-Ramp provee un *pool* de TAMs, no uno designado.

---

### Bloque 4 — AWS Health

**16.** El **AWS Health Dashboard — Your account health** (personalizado, con sesión iniciada) te dice si *tus* buckets están afectados, porque correlaciona el evento contra los recursos de tu cuenta. El **AWS Health Dashboard — Service health** (público, sin iniciar sesión) solo reporta que AWS tiene un problema en una Región.

**17.** `eventTypeCategory` = **`scheduledChange`**. Aparece en la vista de consola personalizada **Your account health**, que está disponible en **todos los planes de Support, incluido Basic**. (La API `describe-events` que te dejaría automatizar sobre eso, no.)

**18.** **Business, Enterprise On-Ramp o Enterprise.** La integración de EventBridge para eventos de AWS Health se apoya en el mismo derecho de la API de AWS Health — el acceso programático a los datos personalizados de salud es una funcionalidad de plan pago, así que la automatización y la API se desbloquean juntas en Business.

**19.** AWS Health es un **servicio global con su endpoint en `us-east-1`**. La `region` que le pasás a la CLI selecciona el *endpoint*, no el *alcance de los resultados*: `describe-events --region us-east-1` devuelve eventos de **todas** las Regiones, filtrados con `--filter regions=eu-central-1` si querés acotarlos. Llamar con `--region eu-central-1` apunta a un endpoint de Health que no existe.

---

### Bloque 5 — Service Quotas

**20.** Sí, y sin comprar nada. **Service Quotas** (consola o `request-service-quota-increase`) está disponible en **todos** los planes de Support, Basic incluido. Un aumento de cuota no es una funcionalidad del plan de Support.

**21.** `Adjustable: false` significa que AWS no lo va a subir a través de Service Quotas — es un límite arquitectónico duro. Opciones: rediseñar alrededor de él (fragmentar entre cuentas o Regiones), o, para los pocos casos donde existe una excepción, abrir un caso de Support para preguntar — pero esperá que la respuesta sea no. No construyas un diseño que dependa de que una cuota no ajustable se mueva.

**22.** El valor aplicado (64) está muy por encima del default de AWS (5), así que **alguien ya solicitó y recibió un aumento en esta cuenta**. `list-requested-service-quota-change-history` va a mostrar esa solicitud y quién la hizo. Esto es exactamente por qué comparás aplicado vs. default antes de suponer que conocés tu techo.

**23.** Service Quotas evaluó la solicitud y no pudo aprobarla automáticamente, así que **abrió un caso de AWS Support en tu nombre** y se lo entregó a un humano para revisión. La correspondencia la leés en la **consola del Support Center** (o vía `aws support describe-communications` si estás en Business+) — Service Quotas en sí solo muestra la transición de estado.

**24.** **Service Quotas** puede cambiar el valor — es dueño del flujo de solicitud de aumento. **El chequeo Service Limits de Trusted Advisor es de solo lectura**: observa y advierte (típicamente al 80% de utilización) pero no puede subir nada. Trusted Advisor te dice *que* estás cerca; Service Quotas es donde *actuás*.

---

### Bloque 6 — Recursos de autoservicio

**25.** **AWS Documentation** (`docs.aws.amazon.com`). Es la referencia autoritativa, versionada y por parámetro del comportamiento de la API. Nada más en el catálogo es normativo sobre la semántica de un flag puntual.

**26.** **AWS Whitepapers & Guides** — específicamente el contenido del *Shared Responsibility Model*. Es la posición formal, citable y versionada de AWS, que un auditor va a aceptar. **re:Post es Q&A comunitario**: útil, muchas veces acertado, pero las respuestas individuales no son la posición oficial de AWS y no son citables en un paquete de cumplimiento.

**27.** **re:Post** es el foro comunitario de Q&A donde cualquiera (y también expertos de AWS) puede responder. **Knowledge Center** es una biblioteca curada de respuestas canónicas escritas por AWS a las preguntas de soporte más frecuentes — está alojada bajo re:Post pero es editorial, no comunitaria. Un **caso de Support** es un compromiso privado y específico de tu cuenta con un ingeniero de AWS que puede ver tus recursos. Orden de escalado: **Documentation/Knowledge Center → re:Post → caso de Support**. Recurrí al caso solo cuando la pregunta depende del estado de *tu* cuenta.

**28.** Es una **advertencia** — puramente consultiva. La Well-Architected Tool **no hace ningún cambio en tu infraestructura**. Es un cuestionario estructurado: respondés preguntas por pilar y produce un plan de mejoras ordenado por riesgo con enlaces a guías. No tiene efecto mutante sobre ningún recurso y no cuesta nada.

**29.** **AWS Solutions Library.** Publica implementaciones validadas y desplegables (CloudFormation/CDK) que podés lanzar directamente. El **Architecture Center** publica arquitecturas de referencia, diagramas y patrones de diseño — guías desde las cuales construir, no artefactos para desplegar.

---

### Bloque 7 — Personas y socios

**30.** Un **Cloud Support Engineer** es **reactivo y de pool**: quien esté de turno toma tu caso, lo resuelve y sigue — no arrastra contexto entre casos. Un **TAM** es **proactivo y (en Enterprise) nombrado**: un defensor designado que conoce tu arquitectura, la revisa con cadencia, planifica lanzamientos con vos, impulsa el escalado interno durante incidentes y expone los hallazgos de Trusted Advisor Priority. El TAM no reemplaza al caso — el TAM hace que el caso avance.

**31.** **Enterprise On-Ramp** y **Enterprise**. El equipo Concierge es dueño de las preguntas de **facturación y cuenta** — análisis de facturas, métodos de pago, estructura de cuentas, consultas sobre asignación de Savings Plans y Reserved Instances — es decir, la mitad no técnica.

**32.** **AWS Professional Services** es la organización de consultoría global propia de AWS; un **APN Consulting Partner** es una firma de terceros validada por AWS. Ambos son **compromisos pagos, por proyecto**, contratados por separado de tu plan de Support, y ambos hacen trabajo de implementación. La diferencia es *con quién contratás* — directamente con AWS vs. con una empresa independiente — lo que afecta la relación comercial, la presencia local y la profundidad del acceso interno a AWS.

**33.** **AWS Managed Services (AMS)** opera tu infraestructura: parcheo, monitoreo, gestión de incidentes, backup y control de cambios, ejecutados por AWS sobre tus cuentas. **AWS Support** asesora y diagnostica pero nunca opera. AMS es una suscripción paga aparte y **presupone Enterprise Support**.

**34.** Sí. El reporte de abuso está disponible en **todos los planes, incluido Basic**, vía `https://support.aws.amazon.com/#/contacts/report-abuse`, `abuse@amazonaws.com` o un caso `customer-service`. Lo maneja AWS Trust & Safety, que es una vía separada del soporte técnico y no está condicionada a un plan pago.

**35.** **AWS Countdown** (antes Infrastructure Event Management, IEM) — planificación guiada más participación en tiempo real alrededor de un evento programado específico. En **Business** está disponible por un **cargo adicional**; en **Enterprise** viene **incluido**.

**Ejercicio de enrutamiento (paso 4):** (a) AWS Professional Services o un APN Consulting Partner — entrega larga, contractual, basada en hitos. (b) Equipo de AWS Trust & Safety / Abuse. (c) AWS Managed Services (AMS). (d) AWS IQ — expertos certificados a corto plazo y a demanda, sin ciclo de compras. (e) AWS Concierge Support Team. (f) AWS Countdown. (g) AWS Activate. (h) AWS Marketplace.

---

### Bloque 8 — Ejercicio de síntesis

| # | (a) Recurso | (b) Plan mínimo |
|---|---|---|
| 1 | AWS Health Dashboard — **Service health** (público) | Ninguno — no hace falta cuenta |
| 2 | AWS Health Dashboard — **Your account health** (consola) | **Basic** |
| 3 | Caso de Support, severidad `critical` | **Enterprise** (< 15 min) |
| 4 | Caso de Support, severidad `critical` | **Enterprise On-Ramp** (< 30 min) |
| 5 | **AWS Support API** (`support:CreateCase`) | **Business** |
| 6 | Solicitud de aumento en **Service Quotas** | **Basic** |
| 7 | **AWS Trusted Advisor**, categoría Cost Optimization | **Business** para el catálogo/API completos; Basic solo ve los chequeos de cuotas + seguridad básica |
| 8 | Caso de Support, severidad `low` | **Developer** ($29/mes o 3% del consumo, lo que sea mayor) |
| 9 | **Technical Account Manager designado** | **Enterprise** |
| 10 | **AWS IQ** | Ninguno |
| 11 | **AWS Whitepapers & Guides** | Ninguno |
| 12 | **AWS Marketplace** | Ninguno |
| 13 | **Equipo de AWS Trust & Safety / Abuse** | Ninguno (Basic) |
| 14 | **AWS Incident Detection and Response (IDR)** | **Enterprise** (complemento pago) |
| 15 | **AWS Well-Architected Tool** | Ninguno |

**36.** **Basic → Developer:** los casos de soporte técnico se vuelven posibles del todo (horario laboral, severidades `low`/`normal`, email a Cloud Support Associates). **Developer → Business:** acceso 24x7 a Cloud Support Engineers por teléfono/chat/email, las severidades `high` y `urgent`, el **catálogo completo de Trusted Advisor** y **todo el acceso programático** — API de Support, API de Health, API de Trusted Advisor, AWS Support App en Slack. **Business → Enterprise On-Ramp/Enterprise:** la severidad `critical` con objetivo de 30/15 minutos, TAMs (de pool/designado), el equipo Concierge, Trusted Advisor Priority (Enterprise) y la elegibilidad para AMS e IDR.

**37.** **(i) Las solicitudes de aumento de Service Quotas** y **(ii) el AWS Health Dashboard personalizado (Your account health)**. De ambas se suele suponer que necesitan un plan pago; ninguna lo necesita. Menciones honoríficas con la misma propiedad: el reporte de abuso, la Well-Architected Tool, re:Post y toda la documentación.

**38.** **Trusted Advisor** y **AWS Health** son ambos visibles en la consola (en forma reducida o completa) en Basic pero bloqueados por API a Business+. AWS traza la línea ahí porque la vista de **consola** es un dashboard de autoservicio que un humano lee de vez en cuando, mientras que la **API** es sobre lo que construís automatización, monitoreo e integraciones — esa capacidad de integración operativa es lo que venden los niveles pagos, junto con los compromisos de tiempo de respuesta.

</details>