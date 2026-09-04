# Tema 1.3 — Ejercicios guiados: beneficios de la migración a la nube de AWS y estrategias para llevarla a cabo

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · Dominio 1, Enunciado de tarea 1.3 · Peso en el examen 6.0

---

## Antes de empezar

### Requisitos previos

| Requisito | Comando de verificación | Resultado esperado |
|---|---|---|
| AWS CLI v2 | `aws --version` | `aws-cli/2.x.x Python/3.x ...` |
| Credenciales | `aws sts get-caller-identity` | JSON con `Account`, `Arn` |
| `jq` | `jq --version` | `jq-1.6` o posterior |
| Python 3 | `python3 --version` | `Python 3.9+` |

```bash
aws --version
aws sts get-caller-identity
```

Salida esperada:

```json
{
    "UserId": "AIDAEXAMPLEUSERID",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/migration-architect"
}
```

### Barrera de costos — leé esto

Estos ejercicios están estructurados de modo que **el camino por defecto es gratuito**. Todo lo que
aprovisiona infraestructura facturable está marcado como **`[BILLABLE]`** y es opcional. Dos técnicas
te mantienen a salvo:

```bash
# 1. Generate the request body without sending it — costs nothing, validates your parameter shape
aws snowball create-job --generate-cli-skeleton input > /tmp/skeleton.json

# 2. Ask the API to validate without executing, where the operation supports it
aws migrationhub notify-application-state \
    --application-id d-application-0a1b2c3d4e5f6g7h8 \
    --status IN_PROGRESS \
    --dry-run
```

> **Nunca ejecutes `aws snowball create-job` como práctica real.** No es una operación de sandbox:
> crea un pedido físico de aprovisionamiento y AWS envía un dispositivo a la dirección que registraste.

### Directorio de trabajo

```bash
mkdir -p ~/labs/clf-1.3/{inventory,dms,datasync,caf}
cd ~/labs/clf-1.3
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Region: $AWS_REGION  Account: $ACCOUNT_ID"
```

---

## Ejercicio 1 — Establecer la región de origen de Migration Hub e importar un inventario

AWS Migration Hub es el panel único de control de un programa de migración. Antes de poder almacenar
cualquier dato de descubrimiento, hay que fijar una **región de origen** (home region): una decisión
única por cuenta que determina dónde viven los datos de descubrimiento y de seguimiento.

### Pasos

**1.** Verificá si ya existe una región de origen:

```bash
aws migrationhub-config describe-home-region-controls --region us-west-2
```

Salida esperada cuando no hay ninguna configurada:

```json
{
    "HomeRegionControls": []
}
```

**2.** Configurá la región de origen. Notá que la llamada al plano de control se hace contra
`us-west-2` sin importar qué región de origen elijas:

```bash
aws migrationhub-config create-home-region-control \
    --home-region us-east-1 \
    --target Type=ACCOUNT,Id=${ACCOUNT_ID} \
    --region us-west-2
```

Salida esperada:

```json
{
    "HomeRegionControl": {
        "ControlId": "hrc-a1b2c3d4e5f6g7h8",
        "HomeRegion": "us-east-1",
        "Target": {
            "Type": "ACCOUNT",
            "Id": "123456789012"
        },
        "RequestedTime": "2026-09-03T10:14:22.318000-03:00"
    }
}
```

**3.** Construí un archivo de inventario sin agentes. En un proyecto real este CSV viene de una CMDB
existente, de una exportación de RVTools o del Agentless Collector de AWS Application Discovery.
Creá `inventory/wave-0.csv`:

```csv
ExternalId,HostName,IPAddress,OS.Name,OS.Version,CPU.NumberOfCores,RAM.TotalSizeInMB,DISK.NumberOfDisks,ApplicationName
srv-001,web-prod-01,10.20.1.11,Ubuntu,20.04,4,16384,2,storefront
srv-002,web-prod-02,10.20.1.12,Ubuntu,20.04,4,16384,2,storefront
srv-003,ora-prod-01,10.20.2.20,Oracle Linux,7.9,16,131072,6,billing
srv-004,sql-prod-01,10.20.2.30,Microsoft Windows Server,2012 R2,8,65536,4,crm
srv-005,jump-01,10.20.9.5,CentOS,6.10,2,4096,1,legacy-tools
srv-006,fileshare-01,10.20.3.15,Microsoft Windows Server,2019,4,32768,3,shared-storage
```

**4.** Subilo y generá una URL prefirmada que la tarea de importación pueda leer:

```bash
BUCKET="acme-migration-inventory-${ACCOUNT_ID}"
aws s3 mb "s3://${BUCKET}" --region ${AWS_REGION}
aws s3 cp inventory/wave-0.csv "s3://${BUCKET}/wave-0.csv"

IMPORT_URL=$(aws s3 presign "s3://${BUCKET}/wave-0.csv" --expires-in 3600)
echo "$IMPORT_URL"
```

**5.** Iniciá la tarea de importación y consultá su estado:

```bash
aws discovery start-import-task \
    --name "wave-0-inventory" \
    --import-url "$IMPORT_URL" \
    --region ${AWS_REGION}
```

Salida esperada:

```json
{
    "task": {
        "importTaskId": "import-task-0f1e2d3c4b5a69788",
        "clientRequestToken": "b9e6f4d1-3c27-4b5e-9a01-7d8c2e5f4a6b",
        "name": "wave-0-inventory",
        "importUrl": "https://acme-migration-inventory-123456789012.s3.amazonaws.com/wave-0.csv?...",
        "status": "IMPORT_IN_PROGRESS",
        "importRequestTime": "2026-09-03T10:22:05.441000-03:00",
        "importedRecordCount": 0,
        "importFailedRecordCount": 0
    }
}
```

```bash
aws discovery describe-import-tasks --region ${AWS_REGION} \
    --query 'tasks[0].{Status:status,OK:importedRecordCount,Failed:importFailedRecordCount}'
```

Salida esperada después de un minuto o dos:

```json
{
    "Status": "IMPORT_COMPLETE",
    "OK": 6,
    "Failed": 0
}
```

**6.** Consultá los elementos de configuración descubiertos:

```bash
aws discovery list-configurations \
    --configuration-type SERVER \
    --region ${AWS_REGION} \
    --query 'configurations[].{Host:"server.hostName",OS:"server.osName",Cores:"server.cpuType"}' \
    --output table
```

**7.** Filtrá el parque de fin de vida útil: los servidores con más probabilidad de convertirse en
candidatos a **retire** o **replatform**:

```bash
aws discovery list-configurations \
    --configuration-type SERVER \
    --region ${AWS_REGION} \
    --filters '[{"name":"server.osName","values":["CentOS","Windows Server 2012"],"condition":"CONTAINS"}]' \
    --query 'configurations[]."server.hostName"'
```

Salida esperada:

```json
[
    "jump-01",
    "sql-prod-01"
]
```

> Fuente: [Application Discovery Service — plantilla de archivo de
> importación](https://docs.aws.amazon.com/application-discovery/latest/userguide/discovery-import.html) ·
> [Región de origen de Migration
> Hub](https://docs.aws.amazon.com/migrationhub/latest/ug/home-region.html)

### Comprobación de comprensión

**Q1.** La llamada al plano de control de la región de origen en el paso 2 se envió a `us-west-2`,
pero la región de origen seleccionada fue `us-east-1`. ¿Qué gobierna realmente la región de origen y
por qué la guía del examen trata al *descubrimiento* como una fase distinta de la *migración*?

**Q2.** Configuraste la región de origen en `us-east-1` para la cuenta `123456789012`, y entonces un
colega argumenta que las cargas de trabajo en realidad deberían aterrizar en `eu-west-1` y te pide
que la cambies. ¿Cuál es la restricción operativa y, ¿impide migrar servidores hacia `eu-west-1`?

**Q3.** El paso 3 importó datos desde un CSV en lugar de instalar un agente en cada servidor.
Nombrá un dato concreto para la toma de decisiones que la importación por CSV no puede darte y que un
agente de descubrimiento instalado sí, y explicá cuál de las 7 R es la más difícil de elegir sin él.

**Q4.** `jump-01` corre CentOS 6.10 y `sql-prod-01` corre Windows Server 2012 R2. Ambos están más allá
del fin de soporte del fabricante. ¿A qué categoría de beneficio de migración de CLF-C02 sirve más
directamente retirar o replatformar estos dos servidores?

---

## Ejercicio 2 — Aplicar las 7 R al parque descubierto

La guía del examen espera que identifiques estrategias de migración. El conjunto estándar de la
industria son las **7 R**: rehost, replatform, repurchase, refactor/re-architect, relocate, retain,
retire.

### Pasos

**1.** Escribí la tabla de decisión. Creá `inventory/seven-rs.md`:

```markdown
| R | Also called | What changes | Typical AWS tooling | Effort | Cloud-native benefit |
|---|---|---|---|---|---|
| Rehost | Lift and shift | Nothing above the hypervisor | AWS Application Migration Service (MGN) | Lowest | Lowest |
| Relocate | Hypervisor-level lift | Nothing; the VM moves as-is | VMware Cloud on AWS / VMware Cloud Foundation on AWS | Very low | Very low |
| Replatform | Lift, tinker and shift | Managed service swap, no code rewrite | RDS, Amazon MQ, Amazon EKS, Elastic Beanstalk | Low–medium | Medium |
| Repurchase | Drop and shop | Licence model — buy SaaS instead | AWS Marketplace, third-party SaaS | Medium | Varies |
| Refactor | Re-architect | Application code and architecture | Lambda, DynamoDB, ECS/EKS, EventBridge | Highest | Highest |
| Retain | Revisit | Nothing; stays on premises | Direct Connect / hybrid networking | None | None |
| Retire | Decommission | Turned off | — | None | Immediate cost reduction |
```

**2.** Puntuá el parque con un script determinista. Creá `inventory/classify.py`:

```python
#!/usr/bin/env python3
"""Assign a candidate R to each discovered server. Advisory only: the output is
an input to a human wave-planning workshop, never a final decision."""
import csv
import sys

EOL_OS = ("CentOS", "2012")

def classify(row):
    os_name = f'{row["OS.Name"]} {row["OS.Version"]}'
    app = row["ApplicationName"]

    if app == "legacy-tools":
        return "retire", "No business owner; superseded by SSM Session Manager"
    if "Oracle" in os_name and app == "billing":
        return "replatform", "Database tier is a candidate for RDS or Aurora"
    if any(marker in os_name for marker in EOL_OS):
        return "replatform", "OS past vendor end-of-support; do not rehost the debt"
    if app == "shared-storage":
        return "replatform", "File share maps to Amazon FSx or EFS"
    return "rehost", "Stateless tier; lowest-risk path, refactor after landing"

def main(path):
    with open(path, newline="") as handle:
        rows = list(csv.DictReader(handle))
    print(f'{"Host":<16}{"App":<18}{"Strategy":<14}Rationale')
    print("-" * 92)
    for row in rows:
        strategy, why = classify(row)
        print(f'{row["HostName"]:<16}{row["ApplicationName"]:<18}{strategy:<14}{why}')

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "inventory/wave-0.csv")
```

**3.** Ejecutalo:

```bash
python3 inventory/classify.py inventory/wave-0.csv
```

Salida esperada:

```
Host            App               Strategy      Rationale
--------------------------------------------------------------------------------------------
web-prod-01     storefront        rehost        Stateless tier; lowest-risk path, refactor after landing
web-prod-02     storefront        rehost        Stateless tier; lowest-risk path, refactor after landing
ora-prod-01     billing           replatform    Database tier is a candidate for RDS or Aurora
sql-prod-01     crm               replatform    OS past vendor end-of-support; do not rehost the debt
jump-01         legacy-tools      retire        No business owner; superseded by SSM Session Manager
fileshare-01    shared-storage    replatform    File share maps to Amazon FSx or EFS
```

**4.** Agrupá los servidores en una aplicación de Migration Hub para poder seguir el progreso por
capacidad de negocio en lugar de por servidor:

```bash
aws discovery create-application \
    --name "storefront" \
    --description "Public e-commerce front end - wave 1" \
    --region ${AWS_REGION}
```

Salida esperada:

```json
{
    "configurationId": "d-application-0a1b2c3d4e5f6g7h8"
}
```

**5.** Registrá la decisión de oleada como etiquetas sobre los elementos de configuración, para que la
clasificación sobreviva fuera de la planilla:

```bash
aws discovery create-tags \
    --configuration-ids d-server-01j5k7m9n0p2q4r6 \
    --tags key=migration-strategy,value=rehost key=migration-wave,value=1 \
    --region ${AWS_REGION}
```

> Fuente: [AWS Prescriptive Guidance — estrategias de
> migración](https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html) ·
> [Migración a la nube de AWS](https://aws.amazon.com/cloud-migration/)

### Comprobación de comprensión

**Q5.** `sql-prod-01` se clasificó como `replatform` porque Windows Server 2012 R2 está fuera de
soporte. Argumentá el caso contrario: ¿en qué circunstancias **rehost** es la decisión correcta para
ese mismo servidor, y qué te cuesta esa elección más adelante?

**Q6.** Un stakeholder dice: "vamos a refactorizar todo a serverless, es la R de mayor valor". Da las
dos objeciones técnicas más fuertes contra refactorizar primero en un parque de 500 servidores con un
contrato de alquiler de datacenter que vence en nueve meses.

**Q7.** El script nunca emite `repurchase` ni `relocate`. ¿Qué tipo de señal de inventario haría falta
agregar para detectar un candidato a `repurchase`, y qué hecho de infraestructura haría de `relocate`
la elección natural?

**Q8.** `retire` no produce ingresos para AWS y no requiere ingeniería. ¿Por qué es típicamente la
estrategia de mayor retorno sobre el esfuerzo del portafolio, y qué tienen que probar los datos de
descubrimiento antes de que puedas actuar sobre ella?

---

## Ejercicio 3 — Elegir entre transferencia de datos en línea y fuera de línea

Este es el juicio cuantitativo más examinado del Tema 1.3: dado un volumen de datos y un enlace de
red, ¿lo mandás por el cable o enviás un dispositivo?

### Pasos

**1.** Construí la calculadora. Creá `inventory/transfer.py`:

```python
#!/usr/bin/env python3
"""Wire-time estimator for bulk data migration.

Reports elapsed transfer time and whether the working set converges: if the
dataset grows faster than the link drains it, no amount of waiting finishes
the job.
"""

SECONDS_PER_DAY = 86_400
BITS_PER_BYTE = 8
BYTES_PER_TB = 10**12


def transfer_days(terabytes, link_gbps, utilisation=0.7):
    """Elapsed days to move `terabytes` over `link_gbps` at `utilisation`."""
    bits = terabytes * BYTES_PER_TB * BITS_PER_BYTE
    effective_bps = link_gbps * 10**9 * utilisation
    return bits / effective_bps / SECONDS_PER_DAY


def converges(terabytes, link_gbps, daily_change_pct, utilisation=0.7):
    """True if the link drains data faster than the source generates it."""
    days = transfer_days(terabytes, link_gbps, utilisation)
    drained_per_day = terabytes / days
    generated_per_day = terabytes * (daily_change_pct / 100)
    return generated_per_day < drained_per_day


SCENARIOS = [
    ("Archive tier",   300, 1.0,  2.0),
    ("Analytics lake",  20, 10.0, 5.0),
    ("VM images",      120, 0.5,  0.5),
]

print(f'{"Scenario":<18}{"TB":>6}{"Gbps":>7}{"Days":>9}{"Converges":>12}  Recommendation')
print("-" * 86)
for name, tb, gbps, change in SCENARIOS:
    days = transfer_days(tb, gbps)
    ok = converges(tb, gbps, change)
    if not ok:
        rec = "OFFLINE - dataset outruns the link"
    elif days > 7:
        rec = "OFFLINE - Snow Family, then DataSync delta"
    else:
        rec = "ONLINE - DataSync over the existing link"
    print(f'{name:<18}{tb:>6}{gbps:>7.1f}{days:>9.1f}{str(ok):>12}  {rec}')
```

**2.** Ejecutalo:

```bash
python3 inventory/transfer.py
```

Salida esperada:

```
Scenario              TB   Gbps     Days   Converges  Recommendation
--------------------------------------------------------------------------------------
Archive tier         300    1.0     39.7       False  OFFLINE - dataset outruns the link
Analytics lake        20   10.0      0.3        True  ONLINE - DataSync over the existing link
VM images            120    0.5     31.8        True  OFFLINE - Snow Family, then DataSync delta
```

**3.** Dimensioná el envío fuera de línea para el archivo de 300 TB. Snowball Edge Storage Optimized
presenta 80 TB de capacidad utilizable:

```bash
python3 -c "
import math
data_tb, usable_tb = 300, 80
print(f'Devices required: {math.ceil(data_tb / usable_tb)}')
print(f'Headroom on last device: {math.ceil(data_tb/usable_tb)*usable_tb - data_tb} TB')
"
```

Salida esperada:

```
Devices required: 4
Headroom on last device: 20 TB
```

**4.** Modelá la solicitud del trabajo sin enviarla:

```bash
aws snowball create-job --generate-cli-skeleton input | jq 'keys'
```

Salida esperada:

```json
[
  "AddressId",
  "Description",
  "DeviceConfiguration",
  "ForwardingAddressId",
  "ImpactLevel",
  "JobType",
  "KmsKeyARN",
  "LongTermPricingId",
  "Notification",
  "OnDeviceServiceConfiguration",
  "PickupDetails",
  "RemoteManagement",
  "Resources",
  "RoleARN",
  "ShippingOption",
  "SnowballCapacityPreference",
  "SnowballType",
  "TaxDocuments"
]
```

**5.** Completá el esqueleto para ver la forma de un trabajo de importación productivo. Creá
`inventory/job.json`:

```json
{
  "JobType": "IMPORT",
  "Description": "Wave 0 archive tier - 300TB cold storage import",
  "AddressId": "ADID1234ab12-3eec-4eb3-9be6-9374c10eb51b",
  "KmsKeyARN": "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab",
  "RoleARN": "arn:aws:iam::123456789012:role/SnowballImportRole",
  "SnowballType": "EDGE_S",
  "SnowballCapacityPreference": "T80",
  "ShippingOption": "SECOND_DAY",
  "Resources": {
    "S3Resources": [
      {
        "BucketArn": "arn:aws:s3:::acme-archive-migration",
        "KeyRange": {
          "BeginMarker": "archive/2019/",
          "EndMarker": "archive/2022/"
        }
      }
    ]
  },
  "Notification": {
    "SnsTopicARN": "arn:aws:sns:us-east-1:123456789012:migration-alerts",
    "JobStatesToNotify": ["InTransitToCustomer", "WithCustomer", "InTransitToAWS", "Complete"],
    "NotifyAll": false
  }
}
```

**6.** Validá el documento localmente sin llamar a la API:

```bash
jq empty inventory/job.json && echo "JSON is well-formed"
jq -r '.Resources.S3Resources[0].BucketArn' inventory/job.json
```

Salida esperada:

```
JSON is well-formed
arn:aws:s3:::acme-archive-migration
```

**7. `[BILLABLE, DO NOT RUN IN PRACTICE]`** Solo como referencia, las operaciones que envían y hacen
seguimiento de un trabajo real:

```bash
# Register the ship-to address
aws snowball create-address --address \
    "Name=Acme DC Ops,Company=Acme Corp,Street1=1 Industrial Way,City=Newark,\
StateOrProvince=NJ,Country=US,PostalCode=07102,PhoneNumber=+15550100"

# Submit the job from the document above
aws snowball create-job --cli-input-json file://inventory/job.json

# Track it through the physical lifecycle
aws snowball describe-job --job-id JID123e4567-e89b-12d3-a456-426655440000 \
    --query 'JobMetadata.{State:JobState,Type:SnowballType,Shipping:ShippingDetails.ShippingOption}'
```

Salida esperada de `describe-job` mientras el dispositivo está en el sitio:

```json
{
    "State": "WithCustomer",
    "Type": "EDGE_S",
    "Shipping": "SECOND_DAY"
}
```

**8.** Entendé el flujo de trabajo en el dispositivo. Una vez que el dispositivo llega, se desbloquea
con un manifiesto y un código de desbloqueo que se obtienen por separado —una división deliberada de
dos factores, de modo que poseer el hardware por sí solo no otorga nada:

```bash
aws snowball get-job-manifest --job-id JID123e4567-e89b-12d3-a456-426655440000
aws snowball get-job-unlock-code --job-id JID123e4567-e89b-12d3-a456-426655440000

snowballEdge unlock-device --endpoint https://192.0.2.10 \
    --manifest-file /secure/JID123e4567.manifest.bin \
    --unlock-code 12345-abcde-01234-ABCDE-01234

aws s3 cp /mnt/archive/ s3://acme-archive-migration/ \
    --recursive --endpoint http://192.0.2.10:8080
```

> Fuente: [Guía del desarrollador de AWS Snowball
> Edge](https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html) ·
> [AWS DataSync](https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html)
>
> La línea de dispositivos de la familia Snow cambia con el tiempo: AWS retiró Snowmobile en 2024.
> Confirmá siempre los dispositivos y capacidades actualmente disponibles para pedido en
> <https://aws.amazon.com/snow/> antes de comprometer un plan.

### Comprobación de comprensión

**Q9.** El escenario del archivo reportó `Converges: False`. Explicá en una oración qué significa eso
físicamente, y por qué vuelve irrelevante el número de "cuántos días".

**Q10.** El escenario de imágenes de VM converge, pero aun así lleva 31,8 días. La regla práctica de
AWS es ir por fuera de línea cuando una transferencia de red superaría aproximadamente una semana.
¿Cuáles son los dos costos ocultos de la transferencia en línea de 31 días que la cifra de tiempo
transcurrido por sí sola oculta?

**Q11.** El paso 8 obtuvo el manifiesto y el código de desbloqueo con dos llamadas de API separadas.
¿Por qué está dividido así, y qué ataque derrota que el cifrado de disco completo por sí solo no?

**Q12.** Después de ingerir cuatro dispositivos Snowball en S3, el sistema de archivos de origen
estuvo activo tres semanas más. ¿Qué servicio y qué modo usás para reconciliar, y por qué una segunda
ronda de Snowball es la respuesta incorrecta?

**Q13.** Un colega propone AWS Storage Gateway en lugar de Snowball para el archivo de 300 TB. ¿Bajo
qué patrón de acceso esa es realmente la mejor respuesta, y qué cambia respecto del estado final de la
migración?

---

## Ejercicio 4 — Rehost con AWS Application Migration Service (MGN)

MGN es el servicio principal recomendado por AWS para lift-and-shift. Realiza replicación continua a
nivel de bloque desde un servidor de origen hacia un área de staging de bajo costo en tu VPC, de modo
que el cutover es un arranque desde un volumen ya sincronizado en lugar de una copia.

### Pasos

**1.** Inicializá el servicio en la región de destino. Esto es idempotente y crea los roles vinculados
al servicio de IAM requeridos y la plantilla de replicación:

```bash
aws mgn initialize-service --region ${AWS_REGION}
```

Salida esperada:

```json
{}
```

**2.** Inspeccioná la plantilla de configuración de replicación por defecto: esto es lo que hereda cada
servidor de origen recién registrado:

```bash
aws mgn describe-replication-configuration-templates --region ${AWS_REGION} \
    --query 'items[0].{Template:replicationConfigurationTemplateID,Subnet:stagingAreaSubnetId,Instance:replicationServerInstanceType,Routing:dataPlaneRouting,Encryption:ebsEncryption}'
```

Salida esperada:

```json
{
    "Template": "rct-01234567890abcdef",
    "Subnet": "subnet-0a1b2c3d4e5f67890",
    "Instance": "t3.small",
    "Routing": "PRIVATE_IP",
    "Encryption": "DEFAULT"
}
```

**3.** Endurecé la plantilla antes de que se conecte ningún agente. El tráfico de replicación debería
atravesar rutas privadas, los discos deberían estar cifrados y el ancho de banda debería limitarse para
que la replicación no ahogue al tráfico productivo en un enlace WAN compartido:

```bash
aws mgn update-replication-configuration-template \
    --replication-configuration-template-id rct-01234567890abcdef \
    --staging-area-subnet-id subnet-0a1b2c3d4e5f67890 \
    --replication-server-instance-type t3.small \
    --use-dedicated-replication-server \
    --default-large-staging-disk-type GP3 \
    --ebs-encryption DEFAULT \
    --data-plane-routing PRIVATE_IP \
    --no-create-public-ip \
    --bandwidth-throttling 500 \
    --associate-default-security-group \
    --staging-area-tags Project=wave-1,CostCentre=migration \
    --region ${AWS_REGION}
```

**4.** Entendé la instalación del agente del lado del origen. En cada servidor de origen Linux:

```bash
wget -O ./aws-replication-installer-init.py \
    https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py

sudo python3 ./aws-replication-installer-init.py \
    --region us-east-1 \
    --no-prompt
```

Salida esperada (abreviada):

```
The installation of the AWS Replication Agent has started.
Identifying volumes for replication.
Identified volume for replication: /dev/nvme0n1 of size 100 GiB
All volumes for replication were successfully identified.
Downloading the AWS Replication Agent onto the source server... Finished.
Installing the AWS Replication Agent onto the source server... Finished.
Syncing the source server with the AWS Application Migration Service Console... Finished.
The AWS Replication Agent was successfully installed.
```

**5.** Observá cómo converge la replicación:

```bash
aws mgn describe-source-servers --filters isArchived=false --region ${AWS_REGION} \
    --query 'items[].{Server:sourceProperties.identificationHints.hostname,
                      ID:sourceServerID,
                      Replication:dataReplicationInfo.dataReplicationState,
                      Lag:dataReplicationInfo.lagDuration,
                      Lifecycle:lifeCycle.state}' \
    --output table
```

Salida esperada durante la sincronización inicial:

```
--------------------------------------------------------------------------------------
|                              DescribeSourceServers                                 |
+-------------+----------------------+---------------+---------+--------------------+
|     ID      |        Server        |  Replication  |   Lag   |     Lifecycle      |
+-------------+----------------------+---------------+---------+--------------------+
|  s-1122...  |  web-prod-01         |  INITIAL_SYNC |  PT4H12M|  NOT_READY         |
|  s-3344...  |  web-prod-02         |  INITIAL_SYNC |  PT3H55M|  NOT_READY         |
+-------------+----------------------+---------------+---------+--------------------+
```

Y una vez saludable:

```
+-------------+----------------------+---------------+---------+--------------------+
|  s-1122...  |  web-prod-01         |  CONTINUOUS   |  PT0S   |  READY_FOR_TEST    |
|  s-3344...  |  web-prod-02         |  CONTINUOUS   |  PT0S   |  READY_FOR_TEST    |
+-------------+----------------------+---------------+---------+--------------------+
```

**6.** Definí la configuración de lanzamiento: cómo se construye la instancia EC2 de destino en el
cutover:

```bash
aws mgn update-launch-configuration \
    --source-server-id s-1122334455667788 \
    --launch-disposition STARTED \
    --target-instance-type-right-sizing-method BASIC \
    --copy-private-ip \
    --copy-tags \
    --boot-mode LEGACY_BIOS \
    --region ${AWS_REGION}
```

Salida esperada (abreviada):

```json
{
    "sourceServerID": "s-1122334455667788",
    "name": "web-prod-01",
    "ec2LaunchTemplateID": "lt-0abc123def4567890",
    "launchDisposition": "STARTED",
    "targetInstanceTypeRightSizingMethod": "BASIC",
    "copyPrivateIp": true,
    "copyTags": true,
    "bootMode": "LEGACY_BIOS"
}
```

**7. `[BILLABLE]`** Lanzá una instancia de **prueba**. Este es el ensayo: no toca el servidor de origen
y la replicación continúa todo el tiempo:

```bash
aws mgn start-test --source-server-ids s-1122334455667788 --region ${AWS_REGION}
```

Salida esperada (abreviada):

```json
{
    "job": {
        "jobID": "mgnjob-0a1b2c3d4e5f6g7h8",
        "type": "LAUNCH",
        "initiatedBy": "START_TEST",
        "status": "PENDING",
        "creationDateTime": "2026-09-03T14:02:11Z",
        "participatingServers": [
            {
                "sourceServerID": "s-1122334455667788",
                "launchStatus": "PENDING"
            }
        ]
    }
}
```

**8.** Seguí el log del trabajo:

```bash
aws mgn describe-job-log-items --job-id mgnjob-0a1b2c3d4e5f6g7h8 --region ${AWS_REGION} \
    --query 'items[].{Time:logDateTime,Event:event}' --output table
```

Salida esperada:

```
------------------------------------------------------------
|                   DescribeJobLogItems                    |
+--------------------------+-------------------------------+
|           Time           |             Event             |
+--------------------------+-------------------------------+
|  2026-09-03T14:02:11Z    |  JOB_START                    |
|  2026-09-03T14:02:34Z    |  SNAPSHOT_START               |
|  2026-09-03T14:06:50Z    |  SNAPSHOT_END                 |
|  2026-09-03T14:07:02Z    |  USING_PREVIOUS_SNAPSHOT      |
|  2026-09-03T14:09:41Z    |  LAUNCH_START                 |
|  2026-09-03T14:12:18Z    |  JOB_END                      |
+--------------------------+-------------------------------+
```

**9. `[BILLABLE]`** Después de validar la instancia de prueba, marcá la prueba como completa, y luego
hacé el cutover y finalizá. `finalize-cutover` es el paso irreversible: termina los recursos de
replicación y detiene la facturación del área de staging.

```bash
aws mgn start-cutover --source-server-ids s-1122334455667788 --region ${AWS_REGION}
aws mgn finalize-cutover --source-server-id s-1122334455667788 --region ${AWS_REGION}
```

**10. Desmontaje.** Si lanzaste algo facturable, desconectá los servidores de origen para detener los
cargos de replicación:

```bash
aws mgn disconnect-from-service --source-server-id s-1122334455667788 --region ${AWS_REGION}
aws mgn delete-source-server --source-server-id s-1122334455667788 --region ${AWS_REGION}
aws ec2 describe-instances --region ${AWS_REGION} \
    --filters "Name=tag:AWSApplicationMigrationServiceManaged,Values=*" \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}' --output table
```

> Fuente: [Guía del usuario de AWS Application Migration
> Service](https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html) ·
> [Referencia de la CLI `aws mgn`](https://docs.aws.amazon.com/cli/latest/reference/mgn/)

### Comprobación de comprensión

**Q14.** MGN replica de forma continua hacia un área de staging en lugar de tomar una imagen puntual.
Enunciá las dos métricas de negocio a las que apunta este diseño, y cuál de ellas mejora en órdenes de
magnitud frente a un enfoque de snapshot y copia.

**Q15.** El paso 7 lanzó una instancia de **prueba** mientras la replicación seguía corriendo. ¿Por qué
la capacidad de probar repetidamente, sin perturbar el origen, es el argumento que más directamente
sostiene el beneficio de migración de "riesgo de negocio reducido" de la guía del examen?

**Q16.** Se configuró `--target-instance-type-right-sizing-method BASIC`. ¿Qué hace el
dimensionamiento correcto en el lanzamiento, y por qué es un *beneficio de migración* y no meramente
una comodidad de configuración?

**Q17.** `finalize-cutover` se describe como irreversible. ¿Qué destruye exactamente, y cuál es la
consecuencia operativa de ejecutarlo antes de que el equipo de la aplicación haya dado su aprobación?

**Q18.** Un equipo hace rehost de 200 servidores con MGN y reporta la migración como un éxito, pero el
gasto mensual coincide casi exactamente con el del viejo datacenter. Explicá por qué este es el
resultado esperado de un rehost puro, y nombrá la fase donde los ahorros se realizan efectivamente.

---

## Ejercicio 5 — Replatformar una base de datos con AWS DMS

`ora-prod-01` se clasificó como **replatform**: el esquema de facturación se mueve de Oracle
autogestionado a Amazon RDS/Aurora PostgreSQL. Esa es una migración *heterogénea*: conversión de
esquema más movimiento de datos.

### Pasos

**1.** Entendé la división del trabajo:

| Aspecto | Herramienta | Qué produce |
|---|---|---|
| Esquema, procedimientos almacenados, tipos | AWS Schema Conversion Tool (SCT) / DMS Schema Conversion | DDL convertido + un informe de evaluación de lo que no se pudo convertir |
| Filas, más cambios en curso | AWS DMS | Carga completa y captura de datos de cambio (CDC) |
| Corrección a posteriori | Validación de datos de DMS | Comparación fila a fila de origen y destino |

**2. `[BILLABLE]`** Creá una instancia de replicación privada. Notá `--no-publicly-accessible`: la
instancia de replicación vive en tu VPC y alcanza al origen por Direct Connect o VPN.

```bash
aws dms create-replication-subnet-group \
    --replication-subnet-group-identifier dms-private-subnets \
    --replication-subnet-group-description "Private subnets for wave-1 DMS" \
    --subnet-ids subnet-0a1b2c3d4e5f67890 subnet-0f9e8d7c6b5a43210 \
    --region ${AWS_REGION}

aws dms create-replication-instance \
    --replication-instance-identifier dms-wave1 \
    --replication-instance-class dms.c5.large \
    --allocated-storage 100 \
    --engine-version 3.5.2 \
    --no-publicly-accessible \
    --multi-az \
    --replication-subnet-group-identifier dms-private-subnets \
    --vpc-security-group-ids sg-0123456789abcdef0 \
    --tags Key=migration-wave,Value=1 \
    --region ${AWS_REGION}
```

Salida esperada (abreviada):

```json
{
    "ReplicationInstance": {
        "ReplicationInstanceIdentifier": "dms-wave1",
        "ReplicationInstanceClass": "dms.c5.large",
        "ReplicationInstanceStatus": "creating",
        "AllocatedStorage": 100,
        "MultiAZ": true,
        "EngineVersion": "3.5.2",
        "PubliclyAccessible": false,
        "ReplicationInstanceArn": "arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    }
}
```

**3.** Creá los endpoints. Las credenciales vienen de Secrets Manager, nunca como `--password` en la
línea de comandos, que termina en el historial del shell y en los logs de solicitudes de CloudTrail:

```bash
aws dms create-endpoint \
    --endpoint-identifier src-oracle-billing \
    --endpoint-type source \
    --engine-name oracle \
    --oracle-settings '{
        "SecretsManagerAccessRoleArn": "arn:aws:iam::123456789012:role/DmsSecretsAccess",
        "SecretsManagerSecretId": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dms/oracle/billing-AbCdEf"
    }' \
    --ssl-mode require \
    --region ${AWS_REGION}

aws dms create-endpoint \
    --endpoint-identifier tgt-aurora-billing \
    --endpoint-type target \
    --engine-name aurora-postgresql \
    --postgre-sql-settings '{
        "SecretsManagerAccessRoleArn": "arn:aws:iam::123456789012:role/DmsSecretsAccess",
        "SecretsManagerSecretId": "arn:aws:secretsmanager:us-east-1:123456789012:secret:dms/aurora/billing-GhIjKl"
    }' \
    --ssl-mode verify-full \
    --region ${AWS_REGION}
```

**4.** Probá la conectividad *antes* de construir una tarea. Este es el paso que más comúnmente se
saltea, y es donde afloran los errores de firewall y de grupos de seguridad:

```bash
aws dms test-connection \
    --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ \
    --endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:SRCORACLEBILLING1234567890 \
    --region ${AWS_REGION}

aws dms describe-connections --region ${AWS_REGION} \
    --query 'Connections[].{Endpoint:EndpointIdentifier,Status:Status,Error:LastFailureMessage}' \
    --output table
```

Salida esperada en caso de éxito:

```
------------------------------------------------------------------
|                       DescribeConnections                      |
+------------------------+-------------+-------------------------+
|        Endpoint        |   Status    |          Error          |
+------------------------+-------------+-------------------------+
|  src-oracle-billing    |  successful |  None                   |
|  tgt-aurora-billing    |  successful |  None                   |
+------------------------+-------------+-------------------------+
```

**5.** Escribí los mapeos de tablas. Creá `dms/table-mappings.json`:

```json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "include-billing-schema",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%"
      },
      "rule-action": "include",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "2",
      "rule-name": "exclude-audit-history",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "AUDIT_%"
      },
      "rule-action": "exclude",
      "filters": []
    },
    {
      "rule-type": "selection",
      "rule-id": "3",
      "rule-name": "recent-invoices-only",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "INVOICE"
      },
      "rule-action": "include",
      "filters": [
        {
          "filter-type": "source",
          "column-name": "CREATED_AT",
          "filter-conditions": [
            {
              "filter-operator": "gte",
              "value": "2023-01-01"
            }
          ]
        }
      ]
    },
    {
      "rule-type": "transformation",
      "rule-id": "4",
      "rule-name": "schema-lowercase",
      "rule-target": "schema",
      "object-locator": {
        "schema-name": "BILLING"
      },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "5",
      "rule-name": "table-lowercase",
      "rule-target": "table",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%"
      },
      "rule-action": "convert-lowercase"
    },
    {
      "rule-type": "transformation",
      "rule-id": "6",
      "rule-name": "column-lowercase",
      "rule-target": "column",
      "object-locator": {
        "schema-name": "BILLING",
        "table-name": "%",
        "column-name": "%"
      },
      "rule-action": "convert-lowercase"
    }
  ]
}
```

**6.** Escribí la configuración de la tarea. Creá `dms/task-settings.json`:

```json
{
  "TargetMetadata": {
    "SupportLobs": true,
    "FullLobMode": false,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32,
    "BatchApplyEnabled": true,
    "ParallelLoadThreads": 0,
    "TargetSchema": ""
  },
  "FullLoadSettings": {
    "TargetTablePrepMode": "DO_NOTHING",
    "MaxFullLoadSubTasks": 8,
    "CommitRate": 10000,
    "TransactionConsistencyTimeout": 600,
    "StopTaskCachedChangesApplied": false,
    "StopTaskCachedChangesNotApplied": false
  },
  "Logging": {
    "EnableLogging": true,
    "LogComponents": [
      { "Id": "SOURCE_UNLOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_LOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "VALIDATOR_EXT", "Severity": "LOGGER_SEVERITY_DEFAULT" }
    ]
  },
  "ValidationSettings": {
    "EnableValidation": true,
    "ValidationMode": "ROW_LEVEL",
    "ThreadCount": 5,
    "PartitionSize": 10000,
    "FailureMaxCount": 10000,
    "TableFailureMaxCount": 1000,
    "HandleCollisionLimit": 3,
    "RecordFailureDelayInMinutes": 5,
    "RecordSuspendDelayInMinutes": 30,
    "ValidationOnly": false,
    "SkipLobColumns": false
  },
  "ErrorBehavior": {
    "DataErrorPolicy": "LOG_ERROR",
    "TableErrorPolicy": "SUSPEND_TABLE",
    "ApplyErrorDeletePolicy": "LOG_ERROR",
    "ApplyErrorInsertPolicy": "LOG_ERROR",
    "ApplyErrorUpdatePolicy": "LOG_ERROR",
    "FullLoadIgnoreConflicts": true
  },
  "ControlTablesSettings": {
    "ControlSchema": "dms_control",
    "HistoryTimeslotInMinutes": 5,
    "StatusTableEnabled": true,
    "SuspendedTablesTableEnabled": true,
    "HistoryTableEnabled": true
  }
}
```

**7.** Validá ambos documentos antes de entregárselos a la API:

```bash
jq empty dms/table-mappings.json && jq empty dms/task-settings.json && echo "Both documents parse"
jq -r '.rules[] | "\(.["rule-id"])  \(.["rule-type"])  \(.["rule-name"])"' dms/table-mappings.json
```

Salida esperada:

```
Both documents parse
1  selection  include-billing-schema
2  selection  exclude-audit-history
3  selection  recent-invoices-only
4  transformation  schema-lowercase
5  transformation  table-lowercase
6  transformation  column-lowercase
```

**8. `[BILLABLE]`** Creá la tarea. `full-load-and-cdc` es lo que hace posible un cutover con tiempo de
inactividad casi nulo: la copia masiva corre mientras el origen sigue vivo, y luego CDC mantiene el
destino actualizado hasta que elegís el momento de conmutar:

```bash
aws dms create-replication-task \
    --replication-task-identifier billing-oracle-to-aurora \
    --source-endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:SRCORACLEBILLING1234567890 \
    --target-endpoint-arn arn:aws:dms:us-east-1:123456789012:endpoint:TGTAURORABILLING0987654321 \
    --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ \
    --migration-type full-load-and-cdc \
    --table-mappings file://dms/table-mappings.json \
    --replication-task-settings file://dms/task-settings.json \
    --region ${AWS_REGION}
```

**9.** Ejecutá la evaluación previa a la migración *antes* de iniciar la tarea. Informa las
construcciones del origen que DMS no puede transportar: tipos de datos no soportados, tablas sin clave
primaria (que rompen silenciosamente las actualizaciones y borrados de CDC) y LOB que exceden el
límite que configuraste:

```bash
aws dms start-replication-task-assessment-run \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --service-access-role-arn arn:aws:iam::123456789012:role/DmsAssessmentRole \
    --result-location-bucket acme-dms-assessments \
    --result-location-folder billing/wave-1 \
    --assessment-run-name billing-preflight-01 \
    --include-only '["unsupported-data-types-in-source","table-with-no-primary-key-or-unique-index","large-lob-handling"]' \
    --region ${AWS_REGION}
```

Salida esperada (abreviada):

```json
{
    "ReplicationTaskAssessmentRun": {
        "ReplicationTaskAssessmentRunArn": "arn:aws:dms:us-east-1:123456789012:assessment-run:ABC123",
        "AssessmentRunName": "billing-preflight-01",
        "Status": "running",
        "ResultLocationBucket": "acme-dms-assessments",
        "ResultLocationFolder": "billing/wave-1"
    }
}
```

**10. `[BILLABLE]`** Iniciá la tarea y observala:

```bash
aws dms start-replication-task \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --start-replication-task-type start-replication \
    --region ${AWS_REGION}

aws dms describe-table-statistics \
    --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 \
    --region ${AWS_REGION} \
    --query 'TableStatistics[].{Table:TableName,State:TableState,Rows:FullLoadRows,
                                Inserts:Inserts,Updates:Updates,Deletes:Deletes,
                                Validation:ValidationState,Pending:ValidationPendingRecords}' \
    --output table
```

Salida esperada a mitad de la migración:

```
-------------------------------------------------------------------------------------------------------
|                                       DescribeTableStatistics                                       |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
|   Table    |         State         |   Rows   | Inserts | Updates | Deletes | Validation  | Pending |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
|  invoice   |  Table completed      |  8412677 |   1204  |    318  |     11  |  Validated  |    0    |
|  customer  |  Table completed      |   201455 |     47  |     92  |      0  |  Validated  |    0    |
|  payment   |  Table is being loaded|  3110982 |      0  |      0  |      0  |  Pending    |  114203 |
|  ledger    |  Table completed      |  5602311 |    880  |    404  |      3  |  Mismatched |     19  |
+------------+-----------------------+----------+---------+---------+---------+-------------+---------+
```

**11. Desmontaje `[IMPORTANT]`** — una instancia de replicación en ejecución factura por hora, haya o
no una tarea activa:

```bash
aws dms stop-replication-task --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 --region ${AWS_REGION}
aws dms delete-replication-task --replication-task-arn arn:aws:dms:us-east-1:123456789012:task:BILLINGORACLETOAURORA123 --region ${AWS_REGION}
aws dms delete-replication-instance --replication-instance-arn arn:aws:dms:us-east-1:123456789012:rep:ABCDEFGHIJKLMNOPQRSTUVWXYZ --region ${AWS_REGION}
aws dms describe-replication-instances --region ${AWS_REGION} --query 'ReplicationInstances[].ReplicationInstanceIdentifier'
```

> Fuente: [Guía del usuario de AWS
> DMS](https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html) ·
> [Mapeo de
> tablas](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html) ·
> [Evaluaciones previas a la
> migración](https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.AssessmentReport.html)

### Comprobación de comprensión

**Q19.** La tarea usa `full-load-and-cdc`. Describí la secuencia de cutover que esto habilita, e
identificá con precisión qué intervalo constituye el tiempo de inactividad real de la aplicación.

**Q20.** `ledger` muestra `Validation: Mismatched` con 19 registros, mientras que todas las filas se
cargaron correctamente. Explicá por qué "la carga completa terminó" y "los datos son correctos" son
afirmaciones distintas, y qué mecanismo específico de DMS produjo ese veredicto.

**Q21.** La evaluación previa a la migración incluye
`table-with-no-primary-key-or-unique-index`. ¿Qué se rompe específicamente durante CDC en una tabla
así, y por qué la falla aparece solo *después* de que la carga completa se ve perfecta?

**Q22.** Oracle → Aurora PostgreSQL es heterogéneo. Nombrá la herramienta que se ocupa de la conversión
de esquema, e indicá qué **no** migra DMS y esta herramienta debe atender.

**Q23.** Un stakeholder pregunta por qué esto cuenta como *replatform* y no como *rehost* o
*refactor*. Da el discriminador de una oración para cada uno de los tres.

---

## Ejercicio 6 — Mapear el parque sobre el AWS Cloud Adoption Framework (CAF)

La guía del examen nombra explícitamente al AWS CAF. CAF organiza el trabajo de preparación
*organizacional* que las herramientas no pueden hacer: seis perspectivas, cada una a cargo de un grupo
distinto de partes interesadas.

### Pasos

**1.** Registrá las seis perspectivas. Creá `caf/perspectives.yaml`:

```yaml
# AWS Cloud Adoption Framework - six perspectives
# Business capability perspectives: Business, People, Governance
# Technical capability perspectives: Platform, Security, Operations
perspectives:
  - name: Business
    owners: [CEO, CFO, COO, CIO]
    question: "Does the cloud investment produce a business outcome we can name?"
    capabilities:
      - strategy-management
      - portfolio-management
      - innovation-management
      - product-management
      - data-monetisation

  - name: People
    owners: [CIO, COO, CTO, HR-leaders]
    question: "Do we have the skills, roles and culture to operate what we build?"
    capabilities:
      - culture-evolution
      - transformational-leadership
      - cloud-fluency
      - workforce-transformation
      - organisation-design

  - name: Governance
    owners: [CIO, CTO, CFO, CDO]
    question: "Can we measure, control and justify the spend and the risk?"
    capabilities:
      - programme-and-project-management
      - benefits-management
      - risk-management
      - cloud-financial-management
      - data-governance

  - name: Platform
    owners: [CTO, technology-leaders, architects, engineers]
    question: "Is there a repeatable landing zone to migrate into?"
    capabilities:
      - platform-architecture
      - data-architecture
      - platform-engineering
      - data-engineering
      - provisioning-and-orchestration
      - modern-application-development

  - name: Security
    owners: [CISO, CCO, security-architects, security-engineers]
    question: "Is the target at least as defensible as the source?"
    capabilities:
      - security-governance
      - security-assurance
      - identity-and-access-management
      - threat-detection
      - vulnerability-management
      - infrastructure-protection
      - data-protection
      - application-security
      - incident-response

  - name: Operations
    owners: [infrastructure-and-operations-leaders, SREs, service-managers]
    question: "Can we run it on day two, at the agreed service level?"
    capabilities:
      - observability
      - event-management
      - incident-and-problem-management
      - change-and-release-management
      - performance-and-capacity-management
      - configuration-management
      - patch-management
      - availability-and-continuity-management
      - application-management
```

**2.** Validalo y contá las capacidades por perspectiva:

```bash
python3 -c "
import yaml, sys
doc = yaml.safe_load(open('caf/perspectives.yaml'))
total = 0
for p in doc['perspectives']:
    n = len(p['capabilities'])
    total += n
    print(f\"{p['name']:<12}{n:>3} capabilities   owners: {', '.join(p['owners'][:3])}\")
print(f\"{'TOTAL':<12}{total:>3}\")
"
```

Salida esperada:

```
Business      5 capabilities   owners: CEO, CFO, COO
People        5 capabilities   owners: CIO, COO, CTO
Governance    5 capabilities   owners: CIO, CTO, CFO
Platform      6 capabilities   owners: CTO, technology-leaders, architects
Security      9 capabilities   owners: CISO, CCO, security-architects
Operations    9 capabilities   owners: infrastructure-and-operations-leaders, SREs, service-managers
TOTAL        39
```

**3.** Mapeá cada bloqueante de una evaluación real de preparación para la migración (MRA) sobre una
perspectiva. Creá `caf/blockers.csv`:

```csv
Blocker,Perspective,Capability,Owner,BlocksWave
"No tagging standard; cannot attribute spend to a team",Governance,cloud-financial-management,FinOps lead,1
"No one on staff has operated Aurora PostgreSQL",People,workforce-transformation,Platform manager,1
"Security has not approved a baseline AMI",Security,infrastructure-protection,CISO delegate,1
"No landing zone; accounts created ad hoc",Platform,platform-architecture,Cloud architect,1
"On-call runbooks reference physical console access",Operations,incident-and-problem-management,SRE lead,2
"Migration ROI never agreed with the CFO",Business,benefits-management,Programme director,1
```

**4.** Informá la preparación por perspectiva:

```bash
python3 -c "
import csv, collections
rows = list(csv.DictReader(open('caf/blockers.csv')))
by = collections.Counter(r['Perspective'] for r in rows)
wave1 = sum(1 for r in rows if r['BlocksWave'] == '1')
for perspective, count in sorted(by.items(), key=lambda kv: -kv[1]):
    print(f'{perspective:<14}{count} open blocker(s)')
print(f'\nWave-1 gating blockers: {wave1} of {len(rows)}')
"
```

Salida esperada:

```
Business      1 open blocker(s)
Governance    1 open blocker(s)
Operations    1 open blocker(s)
People        1 open blocker(s)
Platform      1 open blocker(s)
Security      1 open blocker(s)

Wave-1 gating blockers: 5 of 6
```

**5.** Situá al CAF dentro del recorrido de migración de tres fases usado por el AWS Migration
Acceleration Program (MAP):

```markdown
| Phase | Question answered | Representative outputs |
|---|---|---|
| Assess | Is there a business case, and are we ready? | Migration Readiness Assessment, TCO model from Migration Evaluator, CAF gap analysis |
| Mobilize | Have we closed the gaps and proved the pattern? | Landing zone, security baseline, operating model, skills plan, migration of a pilot application |
| Migrate and Modernize | Can we execute at scale and then improve? | Wave plan executed with MGN/DMS/DataSync, tracked in Migration Hub, followed by modernisation |
```

> Fuente: [Descripción general del AWS Cloud Adoption
> Framework](https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html) ·
> [AWS Migration Acceleration
> Program](https://aws.amazon.com/migration-acceleration-program/)

### Comprobación de comprensión

**Q24.** Cinco de los seis bloqueantes condicionan la oleada 1, y solo uno de esos cinco se resuelve
escribiendo código. ¿Qué te dice esa proporción sobre por qué las migraciones se atrasan, y qué
perspectivas del CAF dominan el camino crítico?

**Q25.** "Nadie en el equipo ha operado Aurora PostgreSQL" está archivado bajo **People**, no bajo
**Platform**. Justificá esa ubicación y describí qué sale mal si se trata como un problema de
Platform.

**Q26.** Un programa saltea Mobilize y va directo de Assess a migrar 50 servidores. Nombrá los dos
modos de falla más probables, mapeando cada uno a la perspectiva del CAF que lo habría detectado.

**Q27.** CAF divide sus seis perspectivas en capacidades de negocio y capacidades técnicas. ¿Cuáles
tres son cuáles, y por qué le importa la distinción a la guía del examen para un *cloud practitioner*
y no para un ingeniero?

---

## Ejercicio 7 — Cuantificar los beneficios después de la migración

La guía del examen enumera los beneficios de la migración en términos de negocio. Este ejercicio los
convierte en cosas que realmente podés medir en una cuenta de AWS.

### Pasos

**1.** Mapeá cada beneficio a un indicador medible. Creá `caf/benefits.md`:

```markdown
| Benefit (CLF-C02) | Measurable proxy | Where the number comes from |
|---|---|---|
| Reduced business risk | Recovery Time Objective, patch latency, % of estate on supported OS | AWS Backup / Elastic Disaster Recovery drill results, Systems Manager Patch Manager compliance |
| Improved ESG performance | Estimated carbon emissions of the workload | AWS Customer Carbon Footprint Tool |
| Increased revenue | Time from idea to production; new regions served | Deployment frequency; latency per geography |
| Increased operational efficiency | Cost per transaction; toil hours per month | Cost Explorer grouped by tag; incident volume in CloudWatch/Systems Manager OpsCenter |
```

**2.** Hacé cumplir el etiquetado que vuelve medible todo lo demás. Sin una política de etiquetas,
"costo por aplicación" es incontestable:

```bash
aws organizations describe-organization --query 'Organization.Id' --output text

cat > caf/tag-policy.json <<'EOF'
{
  "tags": {
    "migration-wave": {
      "tag_key": { "@@assign": "migration-wave" },
      "tag_value": { "@@assign": ["0", "1", "2", "3"] },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db", "s3:bucket"] }
    },
    "application": {
      "tag_key": { "@@assign": "application" },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db"] }
    },
    "migration-strategy": {
      "tag_key": { "@@assign": "migration-strategy" },
      "tag_value": { "@@assign": ["rehost", "relocate", "replatform", "repurchase", "refactor", "retain", "retire"] }
    }
  }
}
EOF

jq empty caf/tag-policy.json && echo "Tag policy is well-formed"
```

**3.** Activá las etiquetas como claves de asignación de costos para que aparezcan en Cost Explorer:

```bash
aws ce update-cost-allocation-tags-status \
    --cost-allocation-tags-status \
        TagKey=migration-wave,Status=Active \
        TagKey=application,Status=Active \
        TagKey=migration-strategy,Status=Active \
    --region us-east-1
```

Salida esperada cuando todas tienen éxito:

```json
{
    "Errors": []
}
```

**4.** Traé el gasto real agrupado por oleada de migración:

```bash
aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=TAG,Key=migration-wave \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[].{Wave:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
    --output table
```

Salida esperada:

```
------------------------------------------
|           GetCostAndUsage              |
+----------------------+------------------+
|         Wave         |      Cost        |
+----------------------+------------------+
|  migration-wave$1    |  18422.7710      |
|  migration-wave$2    |   4108.3355      |
|  migration-wave$     |   2951.0042      |
+----------------------+------------------+
```

**5.** Interpretá el balde sin etiquetar: `migration-wave$` con valor vacío es gasto que no podés
atribuir, y es lo primero que va a cuestionar un CFO:

```bash
aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --filter '{"Tags":{"Key":"migration-wave","MatchOptions":["ABSENT"]}}' \
    --group-by Type=DIMENSION,Key=SERVICE \
    --region us-east-1 \
    --query 'ResultsByTime[0].Groups[].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
    --output table
```

**6.** Comparalo contra la línea base previa a la migración. Creá `caf/tco.py`:

```python
#!/usr/bin/env python3
"""Compare on-premises total cost of ownership against realised AWS spend.

The on-premises figure must include the costs a datacentre bill hides:
hardware refresh amortisation, facilities, and the staff hours spent racking
and patching rather than shipping product.
"""

ON_PREM_MONTHLY = {
    "hardware amortisation (3yr refresh)": 41_000,
    "datacentre space and power":          12_500,
    "network and circuits":                 6_200,
    "software licences (OS, hypervisor)":  14_800,
    "infrastructure staff (loaded)":       28_000,
    "DR site (idle, standby)":             19_400,
}

AWS_MONTHLY = {
    "compute (EC2, right-sized)":          22_480,
    "storage (EBS, S3)":                    5_910,
    "database (Aurora)",                    # placeholder replaced below
}

AWS_MONTHLY = {
    "compute (EC2, right-sized)":          22_480,
    "storage (EBS, S3)":                    5_910,
    "database (Aurora)":                    8_140,
    "data transfer":                        1_070,
    "support and tooling":                  3_300,
    "cloud platform staff (loaded)":       18_000,
    "DR (Elastic Disaster Recovery, pilot light)": 2_600,
}

def report(title, items):
    print(f"\n{title}")
    print("-" * 56)
    for label, amount in items.items():
        print(f"  {label:<44}{amount:>9,}")
    total = sum(items.values())
    print(f"  {'TOTAL':<44}{total:>9,}")
    return total

before = report("On-premises, monthly (USD)", ON_PREM_MONTHLY)
after = report("AWS, monthly (USD)", AWS_MONTHLY)

delta = before - after
print(f"\nMonthly delta: {delta:,}  ({delta / before * 100:.1f}% reduction)")
print(f"Annualised:    {delta * 12:,}")
print("\nNot captured above, and usually larger: the DR site is now 2,600/month")
print("instead of 19,400 for idle standby hardware, and capacity changes take")
print("minutes instead of a procurement cycle.")
```

**7.** Ejecutalo:

```bash
python3 caf/tco.py
```

Salida esperada:

```
On-premises, monthly (USD)
--------------------------------------------------------
  hardware amortisation (3yr refresh)            41,000
  datacentre space and power                     12,500
  network and circuits                            6,200
  software licences (OS, hypervisor)             14,800
  infrastructure staff (loaded)                  28,000
  DR site (idle, standby)                        19,400
  TOTAL                                         121,900

AWS, monthly (USD)
--------------------------------------------------------
  compute (EC2, right-sized)                     22,480
  storage (EBS, S3)                               5,910
  database (Aurora)                               8,140
  data transfer                                   1,070
  support and tooling                             3,300
  cloud platform staff (loaded)                  18,000
  DR (Elastic Disaster Recovery, pilot light)     2,600
  TOTAL                                          61,500

Monthly delta: 60,400  (49.5% reduction)
Annualised:    724,800

Not captured above, and usually larger: the DR site is now 2,600/month
instead of 19,400 for idle standby hardware, and capacity changes take
minutes instead of a procurement cycle.
```

**8.** Registrá el progreso del programa en Migration Hub para que la afirmación sobre los beneficios
quede anclada al trabajo efectivamente completado:

```bash
aws migrationhub notify-application-state \
    --application-id d-application-0a1b2c3d4e5f6g7h8 \
    --status COMPLETED \
    --region ${AWS_REGION}

aws migrationhub list-application-states --region ${AWS_REGION} \
    --query 'ApplicationStateList[].{App:ApplicationId,Status:ApplicationStatus,Updated:LastUpdatedTime}' \
    --output table
```

> Fuente: [AWS Migration
> Evaluator](https://aws.amazon.com/migration-evaluator/) ·
> [Cost Explorer
> `GetCostAndUsage`](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html) ·
> [Customer Carbon Footprint
> Tool](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html)

### Comprobación de comprensión

**Q28.** El paso 6 lista "DR site (idle, standby)" en 19.400 on-premises contra 2.600 en AWS. ¿Qué
propiedad arquitectónica de la nube produce ese cambio específico de rubro, y a qué categoría de
beneficio de CLF-C02 pertenece?

**Q29.** "cloud platform staff (loaded)" es 18.000 contra 28.000 on-premises: una reducción, pero no
una eliminación. Explicá por qué una migración que proyecta el costo de personal en cero no es creíble,
y hacia qué se redirige realmente el tiempo del personal.

**Q30.** Cost Explorer reportó 2.951 USD de gasto sin etiquetar. Nombrá dos consecuencias para el
programa de migración, más allá del inconveniente contable.

**Q31.** Un equipo afirma "migramos, así que mejoramos nuestro desempeño ESG". ¿Qué les exigirías que
produzcan antes de aprobar esa afirmación, y qué propiedad de la infraestructura de AWS está haciendo
el trabajo real?

**Q32.** Argumentá el caso de que "mayor eficiencia operativa" y "mayores ingresos" —dos categorías de
beneficio separadas en la guía del examen— son con frecuencia el *mismo* cambio subyacente observado
desde asientos distintos.

---

## Ejercicio 8 — Armar el plan de oleadas

Todo lo anterior converge en un artefacto: un plan de oleadas que un equipo de entrega pueda ejecutar.

### Pasos

**1.** Construí el plan. Creá `inventory/wave-plan.md`:

```markdown
# Wave plan - Acme datacentre exit

## Wave 0 - Proof (weeks 1-3)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| jump-01 | legacy-tools | retire | - | None | Restore from final backup, 90-day retention |

Exit criteria: landing zone live, tag policy enforced, CAF Governance and Platform blockers closed.

## Wave 1 - Stateless tier (weeks 4-7)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| web-prod-01 | storefront | rehost | MGN | Low - behind ALB, drain and shift | Re-point DNS to on-prem VIP; source untouched |
| web-prod-02 | storefront | rehost | MGN | Low | As above |

Exit criteria: two successful MGN test launches per server, load test at 1.5x peak, runbook rehearsed.

## Wave 2 - Data tier (weeks 8-14)
| Server | App | R | Tool | Cutover risk | Rollback |
|---|---|---|---|---|---|
| ora-prod-01 | billing | replatform | SCT + DMS full-load-and-cdc | High - schema conversion, app connection strings | Reverse CDC task Aurora -> Oracle, pre-built and tested |
| sql-prod-01 | crm | replatform | MGN then in-place upgrade, or RDS SQL Server | Medium - EOL OS | MGN source retained 14 days post-cutover |

Exit criteria: DMS validation reports zero mismatched rows for 72 consecutive hours; reverse
replication task proven by an actual rollback drill, not by inspection.

## Wave 3 - Bulk data (parallel with waves 1-2)
| Dataset | Size | Method | Notes |
|---|---|---|---|
| Archive tier | 300 TB | 4x Snowball Edge Storage Optimized | Offline; dataset outruns the 1 Gbps link |
| Fileshare | 8 TB | DataSync over Direct Connect | Then FSx for Windows File Server; keeps ACLs |

Exit criteria: DataSync delta run after Snowball ingest reports zero differences.

## Retained
| Server | Reason | Review date |
|---|---|---|
| (none in this estate) | - | - |
```

**2.** Verificá la coherencia del plan contra la salida de la clasificación: cada servidor descubierto
debe aparecer exactamente una vez, o algo se descartó silenciosamente:

```bash
comm -3 \
  <(python3 inventory/classify.py inventory/wave-0.csv | tail -n +3 | awk '{print $1}' | sort) \
  <(grep -oE '^\| [a-z0-9-]+ \|' inventory/wave-plan.md | tr -d '| ' | sort -u)
```

Salida esperada cuando el plan está completo:

```
(no output)
```

**3.** Confirmá la posición de rollback para el ítem de mayor riesgo. Para un replatform con DMS, el
rollback es una *tarea inversa preconstruida*, no una esperanza:

```bash
aws dms describe-replication-tasks --region ${AWS_REGION} \
    --query 'ReplicationTasks[].{Task:ReplicationTaskIdentifier,Type:MigrationType,Status:Status}' \
    --output table
```

Salida esperada cuando existen ambas direcciones:

```
--------------------------------------------------------------------
|                     DescribeReplicationTasks                     |
+------------------------------+---------------------+-------------+
|             Task             |        Type         |   Status    |
+------------------------------+---------------------+-------------+
|  billing-oracle-to-aurora    |  full-load-and-cdc  |  running    |
|  billing-aurora-to-oracle    |  cdc                |  stopped    |
+------------------------------+---------------------+-------------+
```

### Comprobación de comprensión

**Q33.** La oleada 0 no migra nada: retira un servidor. Defendé eso como la primera oleada correcta y
no como tiempo desperdiciado.

**Q34.** La oleada 3 corre en paralelo con las oleadas 1 y 2, mientras que las oleadas 1 y 2 son
estrictamente secuenciales. ¿Qué propiedad del trabajo vuelve paralelizable el movimiento masivo de
datos y no el cutover de aplicaciones?

**Q35.** El criterio de salida de la oleada 2 es "la tarea de replicación inversa probada por un
simulacro real de rollback, no por inspección". ¿Por qué una ruta de rollback no probada es
indistinguible de no tener ninguna, y qué beneficio de CLF-C02 protege el simulacro?

**Q36.** `sql-prod-01` tiene dos enfoques candidatos listados (`MGN then in-place upgrade` o `RDS SQL
Server`). Nombrá el único insumo de decisión que resuelve la elección con mayor limpieza.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Región de origen de Migration Hub e importación de inventario

**A1.** La región de origen es donde Migration Hub y Application Discovery Service **almacenan** los
datos de descubrimiento y de seguimiento de la migración: el inventario, las agrupaciones de
aplicaciones y los registros de progreso. Está deliberadamente desacoplada de las regiones hacia las
que migrás: el plano de control para configurarla vive en `us-west-2`, los datos viven en la región de
origen que elegiste, y las cargas de trabajo pueden aterrizar en cualquier lado. La guía del examen
separa descubrimiento de migración porque responden preguntas distintas. El descubrimiento responde
"qué tenemos, qué tamaño tiene, qué habla con qué", y esa respuesta es la que determina la estrategia.
La migración es ejecución. Un programa que empieza a ejecutar antes de tener datos de descubrimiento
está eligiendo estrategias a partir de una planilla que alguien mantuvo a mano, que es la fuente única
más común de sorpresas de alcance a mitad de la migración.

**A2.** La región de origen es una **configuración única por cuenta** y no puede cambiarse una vez que
se recolectaron datos: necesitarías una cuenta nueva, o trabajar con AWS Support. Es una decisión de
residencia y durabilidad de datos, no de ubicación de cargas de trabajo. **No** restringe los destinos
de migración: podés hacer seguimiento de una migración en una región de origen `us-east-1` mientras
cada servidor aterriza en `eu-west-1`. La única consideración real es regulatoria: si los metadatos del
inventario (nombres de host, direcciones IP, nombres de aplicación) están sujetos por sí mismos a un
requisito de residencia, elegí una región de origen que cumpla antes de importar nada.

**A3.** El CSV te da **configuración estática**: núcleos, RAM, cantidad de discos, sistema operativo.
Un agente de descubrimiento instalado te da **series temporales de utilización y conexiones de red**:
consumo real de CPU y memoria durante semanas, y flujos TCP que muestran qué servidores hablan con
cuáles y en qué puertos.

La estrategia más difícil de elegir sin eso es **retire**, seguida de cerca por las decisiones de
dimensionamiento correcto dentro de **rehost**. Sin datos de utilización no podés probar que un
servidor está ocioso, así que nadie te va a dejar apagarlo; sin datos de dependencias de red no podés
probar que nada depende de él, así que no podés agrupar servidores en un límite de aplicación movible.
El inventario estático te dice que un servidor tiene 16 núcleos; solo los datos del agente te dicen que
promedió 3% de CPU durante seis meses y no recibe conexiones entrantes.

**A4.** **Riesgo de negocio reducido.** Los sistemas operativos sin soporte dejan de recibir parches de
seguridad, lo que es una exposición de vulnerabilidad ilimitada y creciente, y típicamente no pueden
quedar cubiertos por una atestación de cumplimiento. Notá que también es una victoria secundaria en
costos —los contratos de soporte extendido para software EOL son caros— pero el encuadre primario en la
guía del examen es la reducción de riesgo.

---

### Ejercicio 2 — Aplicar las 7 R

**A5.** **Rehost es correcto para `sql-prod-01` cuando la restricción es un plazo duro.** Si el
contrato del datacenter vence en 90 días, el movimiento correcto es levantar el servidor tal cual,
salir de las instalaciones y luego remediar el sistema operativo en AWS, donde tenés snapshots,
rollback fácil y ningún ciclo de compras. El rehost desacopla "salir del edificio" de "arreglar la
deuda".

El costo es real y debería enunciarse explícitamente: importaste un sistema operativo sin parches y sin
soporte a tu cuenta de AWS, donde ahora corre junto a cargas de trabajo que sí cumplen. Tenés que
agendar la remediación como trabajo programado con un responsable y una fecha, y mientras tanto debe
estar acotado: grupos de seguridad estrictos, sin exposición pública, monitoreo reforzado. Un rehost
que silenciosamente se vuelve permanente es la forma en que las organizaciones terminan con Windows
Server 2012 en un "parque cloud moderno" tres años después.

**A6.** Dos objeciones:

1. **Refactor está acotado por la capacidad de los equipos de aplicación, no por la capacidad de
   infraestructura.** Hacer rehost de 500 servidores es un pipeline repetible que ejecuta un equipo de
   migración. Refactorizar 500 aplicaciones requiere 500 conjuntos de desarrolladores que entiendan la
   lógica de negocio, y esa gente ya está completamente comprometida con sus propias hojas de ruta. El
   cronograma de migración pasa a ser la suma de la disponibilidad de cada equipo de producto, algo que
   ningún programa de migración controla.
2. **Pone la salida del datacenter en el camino crítico de reescrituras de aplicaciones.** El contrato
   es un plazo externo duro. Refactorizar tiene una duración genuinamente impredecible, porque recién
   descubrís la complejidad real una vez que estás dentro del código. Acoplar un plazo fijo a una
   actividad ilimitada es el modo de falla. La respuesta estándar es **migrar primero, modernizar
   después**: salí de las instalaciones con rehost/replatform, y después refactorizá selectivamente
   donde haya un caso de negocio.

**A7.** Para **repurchase**, la señal faltante es la **identidad del software**: el nombre y el
fabricante de la aplicación instalada, no solo el sistema operativo. Si el descubrimiento reporta un
Exchange, GitLab, Jira autogestionado o un CRM comercial, la pregunta pasa a ser "¿por qué estamos
operando esto?" en lugar de "¿dónde deberíamos ejecutarlo?". Los agentes de descubrimiento y las
exportaciones de CMDB traen inventario de software instalado; el CSV reducido de acá no.

Para **relocate**, el hecho de infraestructura decisivo es que el parque corre sobre **VMware
vSphere**, y que la prioridad es mover cientos o miles de VM rápido sin cambiarlas. Relocate mueve las
cargas de trabajo a nivel del hipervisor hacia un entorno VMware sobre infraestructura de AWS, de modo
que el sistema operativo invitado, las herramientas y los runbooks operativos quedan sin cambios. Es la
vía de salida más rápida y la de menor beneficio nativo de nube: apropiada como paso intermedio, no
como estado final.

**A8.** Retire tiene el mayor retorno sobre el esfuerzo porque el ahorro es **inmediato, permanente y
el 100% del costo de ese servidor**: sin ingeniería de migración, sin riesgo de cutover, sin gasto de
ejecución residual. Cualquier otra R te deja pagando algo. Los parques empresariales típicos cargan
entre 10% y 20% de servidores zombis, así que retire por sí solo suele financiar una porción
significativa del programa.

El descubrimiento debe probar dos cosas antes de que puedas actuar: **ninguna utilización
significativa** en un período representativo (que cubra las ventanas de proceso batch de cierre de mes
y de trimestre, razón por la cual una muestra de dos semanas no alcanza), y **ninguna dependencia de
red entrante** desde sistemas que se quedan. La segunda es la que agarra desprevenida a la gente: un
servidor ocioso puede seguir siendo aquello a lo que se conecta un único trabajo nocturno a las 3 de la
mañana del último día del mes.

---

### Ejercicio 3 — Transferencia en línea versus fuera de línea

**A9.** `Converges: False` significa que los datos de origen se están creando más rápido de lo que el
enlace puede drenarlos. Con 300 TB y 2% de cambio diario, el origen genera 6 TB por día mientras el
enlace mueve aproximadamente 7,6 TB por día, y ese margen se derrumba en cuanto el enlace se comparte,
se limita o se interrumpe. La cifra de "39,7 días" es irrelevante porque supone un conjunto de datos
estático: en la realidad nunca alcanzás un estado sincronizado, lo perseguís asintóticamente. Por eso
la verificación de convergencia debe venir antes que la de duración.

**A10.** Dos costos ocultos:

1. **Estás manteniendo un enlace WAN al 70% de utilización durante un mes.** Ese enlace también lleva
   tráfico productivo: replicación, backups, sesiones de usuarios, VPN. Un mes de transferencia masiva
   sostenida degrada todo lo demás que pasa por ahí, y los incidentes resultantes se le cargan a la
   migración.
2. **Estás manteniendo abierta una ventana de 31 días durante la cual cualquier interrupción reinicia
   o extiende el trabajo.** Mantenimiento del circuito, un agente de transferencia caído, un cambio de
   firewall: cada uno es un reinicio parcial. El riesgo se acumula con el tiempo transcurrido, y 31
   días de exposición son materialmente distintos de los dos o tres días que lleva el envío de un
   dispositivo.

Hay además un tercero directo: 31 días de atención de un ingeniero monitoreando una transferencia son
gasto salarial real que nunca aparece en el costo de red.

**A11.** El manifiesto es un archivo cifrado que contiene las claves necesarias para descifrar los
datos del dispositivo; el código de desbloqueo es la frase de paso que descifra el manifiesto. Se
obtienen mediante dos llamadas de API separadas y están pensados para viajar por dos canales
diferentes: el manifiesto por una vía, el código por otra (comúnmente leído en voz alta o enviado a un
destinatario distinto).

El ataque que esto derrota es la **intercepción física en tránsito**. El cifrado de disco completo
protege contra alguien que roba el dispositivo y lee los platos, pero no hace nada si la credencial
necesaria para desbloquearlo viaja con el dispositivo o está disponible para quien lo reciba. Dividir
la credencial significa que comprometer el envío no alcanza: un atacante necesita el hardware *y* el
manifiesto *y* el código de desbloqueo, obtenidos por tres canales distintos. Es autenticación de dos
factores aplicada a un objeto físico.

**A12.** Usá **AWS DataSync** en modo incremental (`TransferMode=CHANGED`), apuntado al mismo destino
S3 donde aterrizaron los datos de Snowball. DataSync compara los metadatos de origen y destino y
transfiere solo lo que difiere, así que después de la siembra masiva estás moviendo tres semanas de
deltas —probablemente pocos terabytes de un dígito— que la red maneja con facilidad.

Una segunda ronda de Snowball está mal por tres razones: el viaje de ida y vuelta agrega otra semana o
dos de latencia durante las cuales se acumula *más* delta; el dispositivo llevaría mayormente datos sin
cambios, porque las herramientas de copia de Snowball no tienen una manera eficiente de diferenciar
contra lo que ya está en S3; y se vuelve a incurrir en todo el ciclo de envío, manipulación y borrado
seguro para mover una fracción de la capacidad de un dispositivo. El patrón canónico es **Snowball para
la siembra masiva, DataSync para los deltas y la reconciliación final**: fuera de línea para el
volumen, en línea para la actualidad.

**A13.** Storage Gateway es la mejor respuesta cuando el requisito es **acceso híbrido continuo, no un
traslado único**: cuando las aplicaciones on-premises deben seguir leyendo y escribiendo esos datos con
baja latencia mientras la copia autoritativa vive en S3. File Gateway presenta un montaje NFS o SMB
respaldado por objetos de S3, cacheando localmente el conjunto de trabajo.

Lo que cambia respecto del estado final es fundamental: Snowball es una **migración** —los datos se
mueven a AWS y el origen se desmantela—. Storage Gateway es una **arquitectura**: un componente híbrido
permanente que ahora operás, monitoreás, parcheás y pagás indefinidamente. Si el objetivo es salir del
datacenter, Storage Gateway te deja con algo todavía adentro del datacenter. Es la respuesta correcta
para "necesitamos almacenamiento respaldado por la nube con acceso local", y la respuesta incorrecta
para "necesitamos estos datos fuera del edificio".

---

### Ejercicio 4 — Rehost con MGN

**A14.** Las dos métricas son **Recovery Point Objective (RPO)** —cuántos datos podés perder— y
**Recovery Time Objective (RTO)** —cuánto tarda la conmutación—. La replicación continua a nivel de
bloque mantiene el RPO en el rango de sub-segundos a segundos, porque el destino siempre está al día.

La mejora de órdenes de magnitud está en el **RTO**. Con snapshot y copia, el tiempo de cutover es
proporcional al volumen de datos: un servidor de 2 TB significa horas de copiado con la aplicación
caída. Con MGN los datos ya están en el destino, así que el cutover es "tomar un snapshot consistente
final y arrancar una instancia": minutos, y crucialmente *independiente del tamaño del servidor*.
Quitar el término del volumen de datos de la ecuación del tiempo de inactividad es lo que hace viable
hacer rehost de cientos de servidores según un cronograma.

**A15.** Porque convierte un plan no probado en un **procedimiento ensayado y evidenciado**. El
lanzamiento de prueba arranca una instancia real desde datos replicados reales en la VPC de destino
real, así que descubrís la entrada DNS faltante, la IP hardcodeada, el servidor de licencias que no
responde y el hueco en el grupo de seguridad *antes* de la ventana de mantenimiento y no durante. El
servidor de origen nunca se toca y la replicación nunca se pausa, así que una prueba fallida no cuesta
más que las horas de instancia.

Esa es la definición de riesgo de negocio reducido: la migración deja de ser un evento de un solo tiro
donde fallar significa una caída, y se vuelve un procedimiento ejecutado por enésima vez la noche del
cutover, con todas las sorpresas descubiertas previamente ya corregidas. Podés correr la prueba el
martes, arreglar lo que se rompió, correrla de nuevo el jueves y hacer el cutover el sábado habiendo
visto el resultado dos veces.

**A16.** El dimensionamiento correcto selecciona el tipo de instancia EC2 de destino a partir de la
**especificación real y la utilización observada del servidor de origen**, en lugar de replicar su
configuración nominal. El método `BASIC` mapea la CPU y la RAM del origen al tipo de instancia más
chico que las satisfaga, en lugar de aprovisionar un equivalente al hardware que se compró
sobredimensionado en 2019 para sobrevivir un ciclo de renovación de tres años.

Es un beneficio genuino de migración y no un simple ajuste porque **on-premises no podías actuar sobre
ese conocimiento**. Comprabas un servidor físico dimensionado para el pico más margen más crecimiento, y
pagabas esa capacidad 24/7 durante toda su vida, se usara o no. En AWS la capacidad es una elección por
hora que podés revisar. El dimensionamiento correcto en el lanzamiento es el momento en que el parque
deja de arrastrar años de sobreaprovisionamiento acumulado, y es de donde viene la mayor parte del
beneficio real de costo de un rehost, ya que el rehost en sí no cambia nada más.

**A17.** `finalize-cutover` **termina los recursos de replicación**: los servidores de replicación en
el área de staging, los volúmenes EBS de staging que contienen los datos replicados y la relación de
replicación en curso. El servidor de origen pasa al estado de ciclo de vida `CUTOVER` y deja de
replicar.

Si lo ejecutás antes de la aprobación, destruiste tu rollback. Hasta la finalización, el rollback es
trivial: el servidor de origen sigue vivo y sigue sincronizado, así que reapuntás el tráfico de vuelta
y no perdés nada. Después de la finalización, el estado replicado ya no existe; recuperarlo significa
reinstalar el agente y hacer una sincronización inicial nueva, lo que para un servidor grande son horas
o días. Además, todo lo que la aplicación escribió en AWS desde el cutover ahora diverge del origen,
así que "volver atrás" también se vuelve un problema de reconciliación de datos y no un cambio de
tráfico. Por eso la finalización es un paso deliberado, separado y explícitamente aprobado, y no parte
del cutover.

**A18.** El rehost puro cambia **dónde** corre una carga de trabajo, no **cuánto** consume. La misma
instancia sobredimensionada corre el mismo código 24/7, y convertiste un activo de capital que se
deprecia en un gasto operativo a un costo mensual aproximadamente comparable, a veces mayor, porque el
hardware on-premises que ya lleva tres años de una amortización a cinco años se ve muy barato en base
mensual. Es un resultado real y bien documentado, no una falla de ejecución.

Los ahorros se realizan en la **fase de optimización / modernización posterior al aterrizaje**:
dimensionamiento correcto contra datos observados de CloudWatch, apagar entornos no productivos fuera
del horario laboral, Savings Plans o Reserved Instances para la línea base de estado estable, Graviton
donde la carga lo soporte, mover datos fríos a niveles de ciclo de vida de S3 y replatformar la capa de
base de datos a un servicio administrado que elimine licenciamiento y administración. El rehost te
compra *la posibilidad* de hacer todo eso; no hace nada de eso. El error es tratar el cutover como el
fin del programa en lugar del punto a partir del cual la optimización se vuelve posible.

---

### Ejercicio 5 — Replatform con DMS

**A19.** La secuencia es: (1) la carga completa copia las filas existentes mientras la base de datos de
origen sigue viva y sirviendo tráfico; (2) CDC captura cada cambio hecho durante y después de la carga
completa desde el log de transacciones del origen y lo aplica al destino, de modo que el destino
converge al origen y luego lo sigue con un retraso pequeño; (3) monitoreás hasta que el retraso sea
consistentemente cercano a cero; (4) en el momento elegido detenés la aplicación, esperás a que las
últimas transacciones drenen por CDC, verificás que el retraso sea cero, reapuntás la cadena de
conexión de la aplicación al destino y la arrancás.

**El tiempo de inactividad es solo el paso 4**: desde que detenés la aplicación hasta que la arrancás
contra el nuevo endpoint. Eso son minutos, y es independiente del tamaño de la base de datos. Sin CDC,
el tiempo de inactividad sería toda la duración de la carga completa, porque habría que congelar la
base de datos durante toda la copia; para una base de datos de varios terabytes, eso son horas o días.
Eliminar el término del volumen de datos del tiempo de inactividad es todo el punto.

**A20.** "La carga completa terminó" significa que cada fila fue **leída del origen y escrita en el
destino**. No dice nada sobre si los valores son equivalentes después de cruzar un límite de motor. La
migración heterogénea pasa los datos por conversión de tipos, y ahí es donde vive la corrupción
silenciosa: un `NUMBER` de Oracle con una precisión que PostgreSQL no puede representar de forma
idéntica, marcas de tiempo que pierden precisión de sub-segundo o contexto de zona horaria, semánticas
de relleno de `CHAR` que difieren, LOB truncados en el `LobMaxSize` configurado de 32 KB, conversión de
juego de caracteres que estropea texto no ASCII.

El mecanismo es la **validación de datos de DMS** (`EnableValidation: true`,
`ValidationMode: ROW_LEVEL`). Corre como una pasada separada, releyendo filas de forma independiente
desde origen y destino y comparándolas valor por valor. `Mismatched` significa que encontró 19 filas
donde el valor del destino no es equivalente al del origen. Esas filas se cargaron "exitosamente": DMS
escribió lo que la conversión produjo. Solo la validación detecta la diferencia entre "escrito" y
"correcto", que es exactamente por qué la opción debería estar activa en toda migración heterogénea y
por qué los criterios de cutover se escriben contra el estado de validación y no contra el estado de
carga.

**A21.** CDC aplica los cambios al destino localizando la fila afectada. Sin clave primaria ni índice
único, DMS **no tiene manera de identificar unívocamente qué fila del destino corresponde a un cambio
del origen**. Por lo tanto, las operaciones `UPDATE` y `DELETE` no pueden aplicarse de forma confiable:
según la configuración, DMS puede fallar la operación, aplicarla a todas las filas coincidentes o no
aplicarla a ninguna. Las inserciones funcionan bien, porque no necesitan localizar nada.

La falla aparece solo después de que la carga completa se ve perfecta porque **la carga completa es
solo inserciones**. Lee cada fila del origen y la inserta en el destino; no se requiere identidad de
fila. La tabla, entonces, reporta una carga completa y exitosa con el conteo de filas correcto. El
problema aflora cuando CDC empieza a aplicar el flujo de cambios en curso, y peor, puede aflorar *en
silencio*, con los conteos de filas todavía coincidiendo mientras filas individuales se desincronizan.
Precisamente para eso existe la evaluación previa a la migración: es una verificación estática sobre
los metadatos del origen que no cuesta nada y detecta el problema antes de que hayas construido un plan
de cutover alrededor de una tabla que no puede replicarse.

**A22.** La herramienta es la **AWS Schema Conversion Tool (SCT)**, o su equivalente integrado **DMS
Schema Conversion**.

DMS migra **datos**: filas, y cambios en curso sobre filas. **No** migra objetos de esquema ni código:
definiciones de tablas e índices, restricciones, secuencias, vistas, procedimientos almacenados,
funciones, paquetes, disparadores, tipos personalizados ni características específicas del motor, como
los paquetes PL/SQL de Oracle y las llamadas `DBMS_*`. SCT convierte lo que puede automáticamente y
produce un **informe de evaluación** que enumera lo que no pudo, con una estimación de esfuerzo por
ítem. Ese informe es el insumo honesto para la decisión de replatform versus refactor: si SCT reporta
5% de intervención manual, el proyecto es rutinario; si reporta 40%, el "replatform" es en realidad una
reescritura disfrazada de replatform, y debería dimensionarse y dotarse de personal como tal.

**A23.**
- **Rehost**: no cambia nada por encima del hipervisor: los mismos binarios de Oracle corren en una
  instancia EC2 en lugar de hardware físico.
- **Replatform**: la *plataforma subyacente* a la aplicación cambia a un servicio administrado, pero el
  código propio de la aplicación no necesita reescribirse: Oracle pasa a ser Aurora PostgreSQL, así que
  dejás de administrar un motor de base de datos, pero la aplicación de facturación sigue emitiendo SQL
  contra una base de datos relacional. (Cambian las cadenas de conexión y las consultas específicas del
  dialecto; la lógica de negocio no.)
- **Refactor**: la *arquitectura de la aplicación* cambia: el servicio de facturación se descompone en
  funciones orientadas a eventos que escriben en DynamoDB, que es un modelo de datos distinto y exige
  reescribir la aplicación.

El discriminador de una línea: rehost cambia el **hardware**, replatform cambia la **plataforma**,
refactor cambia la **aplicación**.

---

### Ejercicio 6 — AWS CAF

**A24.** Te dice que las migraciones se atrasan por **preparación organizacional, no por tecnología**.
Cinco de los seis bloqueantes de la oleada 1 son decisiones, aprobaciones, acuerdos y habilidades:
cosas que requieren una persona con autoridad para comprometerse, y que ninguna cantidad de capacidad
de ingeniería acelera. El camino crítico está dominado por **Governance, People, Security y Business**;
solo el bloqueante de la landing zone es de Platform, y es el único que un equipo de ingeniería puede
simplemente ir y construir.

La consecuencia práctica es de planificación: estos bloqueantes deben trabajarse en la fase Mobilize,
en paralelo y por delante de la preparación técnica, porque tienen tiempos de espera largos medidos en
ciclos de comité y no en sprints. Un programa de migración que dote únicamente de ingenieros va a
quedar bloqueado y no va a poder desbloquearse solo.

**A25.** Es un bloqueante de **People** porque la brecha es de *capacidad humana*, y el remedio es
capacitación, contratación o un acuerdo con un partner: una acción sobre la fuerza de trabajo con un
tiempo de espera de semanas a meses. El trabajo de Platform es hacer que Aurora esté disponible y bien
arquitecturada; eso se puede hacer en una tarde con Terraform y no crea una sola persona que sepa qué
hacer cuando Aurora hace failover a las 2 de la mañana.

Tratarlo como un problema de Platform produce una falla específica y común: el equipo de plataforma
aprovisiona Aurora, declara entregada la capacidad y la migración avanza. La brecha operativa aflora en
el **día dos**, durante el primer incidente, cuando nadie de guardia entiende el retraso de réplica, el
comportamiento del failover o cómo leer los performance insights que lo explicarían. Migraste
exitosamente a un servicio que no podés operar, lo cual es peor que no haber migrado: el sistema viejo
por lo menos lo entendía la gente responsable de él. El encuadre de la guía del examen de la migración
como un cambio organizacional, no solo técnico, es exactamente este punto.

**A26.** Dos modos de falla probables:

1. **Cuentas inconsistentes y sin gobierno, y ninguna línea base de seguridad**: los servidores
   aterrizan en cuentas armadas a mano con redes e IAM ad hoc, y el parque se vuelve ingobernable e
   inauditable a escala. Arreglarlo retroactivamente sobre 50 servidores cuesta múltiplos de hacerlo
   una sola vez, al principio. Lo hubieran detectado **Platform** (landing zone) y **Security** (línea
   base, guardrails, modelo de IAM).
2. **Nadie puede operar el resultado**: sin observabilidad, sin runbooks escritos para la nube, con una
   rotación de guardia que todavía asume acceso a la consola física. El primer incidente después de la
   migración se maneja mal y a la vista de todos. Lo hubieran detectado **Operations** (observabilidad,
   gestión de incidentes y problemas) y **People** (habilidades y preparación de roles).

El patrón general: Mobilize existe para construir y probar el patrón **una vez**, sobre un piloto, de
modo que las 50 migraciones siguientes sean repeticiones de algo que se sabe que funciona en lugar de
50 primeros intentos independientes.

**A27.** **Capacidades de negocio: Business, People, Governance.** **Capacidades técnicas: Platform,
Security, Operations.**

La distinción le importa a un cloud practitioner porque el examen de practitioner no evalúa si podés
construir la cosa: evalúa si entendés que **la adopción de la nube es una transformación organizacional
con un componente técnico, no un proyecto técnico con efectos secundarios organizacionales**. Un
practitioner es típicamente la persona en un puesto de ventas, finanzas, gestión de proyectos,
cumplimiento o liderazgo que debe involucrarse con un programa de nube. Su contribución está del lado
de las capacidades de negocio: acordar el caso de negocio, financiarlo, gobernar el gasto, gestionar el
riesgo y preparar a la fuerza de trabajo. La división del CAF vuelve explícito que tres de las seis
perspectivas pertenecen a personas que nunca van a tocar la consola, y que un programa que descuide
esas tres va a fracasar sin importar cuán buena sea su ingeniería.

---

### Ejercicio 7 — Cuantificar beneficios

**A28.** La propiedad es la **elasticidad**, específicamente la capacidad de aprovisionar capacidad en
el momento de la necesidad en lugar de poseerla de antemano. Un sitio de DR on-premises requiere un
segundo conjunto de hardware físico dimensionado para la carga productiva completa, ocioso y
depreciándose, porque no podés conjurar servidores durante un desastre. Una arquitectura pilot light en
AWS mantiene solo los datos replicándose y el plano de control mínimo corriendo, y después aprovisiona
capacidad completa desde el pool compartido de AWS durante un evento real de failover.

La categoría de beneficio es **riesgo de negocio reducido**, y vale la pena notar la dirección de la
mejora: no solo estás pagando menos por la misma postura de DR, típicamente obtenés una *mejor*. El
hardware de standby ocioso rara vez se ejercita, así que su disponibilidad se asume en lugar de
conocerse; el DR en la nube se puede probar a demanda al costo de unas pocas horas de instancia, lo que
significa que efectivamente se prueba. Más barato *y* con más probabilidad de funcionar es inusual, y
es por eso que el DR es uno de los casos de negocio más confiables de una migración.

**A29.** Porque el trabajo no desaparece: **cambia de forma**. Nadie rackea servidores, reemplaza
discos fallados, gestiona licenciamiento de hipervisor ni planifica una renovación de hardware. Pero
alguien ahora tiene que hacerse cargo de infraestructura como código, de IAM y el modelo de permisos,
del gobierno de costos, del pipeline de CI/CD, de la observabilidad, del parcheo vía Systems Manager y
de la gestión de cuentas y guardrails. La nube no elimina las operaciones; eleva el nivel de
abstracción en el que ocurren.

Un caso de negocio que proyecta el costo de personal en cero no es creíble y va a ser rechazado por
cualquiera que haya operado infraestructura, y con razón, porque usualmente indica que el plan no tiene
ningún modelo operativo de día dos. La afirmación honesta es que la misma dotación produce más: el
tiempo antes gastado en trabajo pesado indiferenciado se redirige a la automatización y a trabajo
específico del negocio. Esa redirección es el valor real, y pertenece a **mayor eficiencia operativa**,
fluyendo a veces hacia **mayores ingresos** cuando la capacidad liberada va a trabajo de producto.

**A30.** Dos consecuencias:

1. **El caso de negocio se vuelve inverificable.** No podés reportar costo por aplicación ni costo por
   oleada sobre gasto que no podés atribuir, así que no podés demostrar que una migración dada entregó
   su ahorro proyectado. La credibilidad del programa ante el CFO descansa exactamente en ese número, y
   "aproximadamente el 5% no está atribuido" es donde la conversación se traba.
2. **La optimización se queda sin dueño.** Los recursos sin etiquetar no tienen equipo responsable, así
   que nadie se hace cargo de dimensionarlos, programarlos o borrarlos. El gasto no atribuido se vuelve
   confiablemente gasto *permanente*: volúmenes huérfanos, instancias de prueba olvidadas, entornos de
   staging que quedaron corriendo después de un cutover. Además, con frecuencia indica
   aprovisionamiento ocurriendo fuera del pipeline autorizado, lo cual es una señal de gobierno y de
   seguridad tanto como de costo.

**A31.** Exigí la salida de la **Customer Carbon Footprint Tool** para la cuenta durante un período
comparable, junto con una estimación documentada de la huella on-premises retirada. Sin un antes y
después en las mismas unidades, la afirmación es una aseveración.

La propiedad que hace el trabajo es la **eficiencia de utilización a escala**. Un datacenter empresarial
típico corre servidores a baja utilización promedio con una relación de eficiencia en el uso de la
energía (PUE) pobre, porque la capacidad se aprovisiona para el pico y la refrigeración se dimensiona
para una sala medio vacía. AWS corre a una utilización mucho más alta sobre hardware agrupado en
instalaciones construidas a propósito, y respalda el consumo con compra de energía renovable. Así que
la reducción es real, pero está condicionada a que efectivamente dimensiones correctamente. Hacer
rehost de una flota sobredimensionada sin cambios traslada la misma ineficiencia a una instalación más
eficiente: obtenés el beneficio de PUE y de renovables, pero no el de utilización. La versión honesta
de la afirmación es específica sobre cuál de esos te ganaste.

**A32.** Son el mismo cambio medido en dos puntos de la misma cadena causal. Considerá un proceso de
release que llevaba seis semanas on-premises porque requería un comité de aprobación de cambios, una
construcción manual del entorno y una ventana de caída programada, y que ahora lleva dos días porque
los entornos se aprovisionan por pipeline y se despliegan blue/green.

Desde el **asiento de operaciones**, eso es eficiencia: menos horas de ingeniero por release, menos
trabajo penoso, sin ventanas de fin de semana, menor tasa de fallas por cambio. Desde el **asiento de
producto**, el cambio idéntico es ingresos: una funcionalidad llega a los clientes cinco semanas y
media antes, los experimentos se pueden correr y descartar barato, y la organización puede responder a
un competidor en un trimestre en lugar de en un año. La guía del examen los separa porque distintas
partes interesadas se persuaden con distintos encuadres —el COO financia eficiencia, el CEO financia
crecimiento— pero para un practitioner la idea útil es que **el tiempo de ciclo es la variable
subyacente compartida**, y la mayoría de los beneficios de la nube son aguas abajo de reducirlo. La
eficiencia es lo que ahorrás; los ingresos son lo que hacés con el tiempo ahorrado.

---

### Ejercicio 8 — El plan de oleadas

**A33.** Porque el propósito real de la oleada 0 es **probar la maquinaria, no mover carga**. Retirar
un servidor de bajo riesgo sin dueño de negocio ejercita el proceso completo de punta a punta —los
datos de descubrimiento son correctos, la vía de aprobación del desmantelamiento funciona, la política
de backup y retención es real, el plan de comunicación llega a la gente indicada, el rollback está
definido— mientras el radio de impacto de un error es cercano a cero.

También adelanta los bloqueantes del CAF: los criterios de salida de la oleada 0 exigen la landing
zone, la política de etiquetas y el cierre de los ítems de Governance y Platform. Esos son los ítems
organizacionales de tiempo de espera largo, y ponerlos detrás de una oleada técnicamente trivial a
propósito significa que se trabajan durante las semanas 1 a 3 en lugar de descubrirse como bloqueantes
en la semana 4. Y el retiro entrega un ahorro inmediato y permanente sin costo continuo, así que el
programa anota una victoria real antes de tomar su primer riesgo real. Una primera oleada técnicamente
ambiciosa es una primera oleada que descubre problemas de proceso y problemas técnicos
simultáneamente, sin manera de distinguirlos.

**A34.** El movimiento masivo de datos es paralelizable porque es **aditivo e idempotente**: copiar
300 TB de archivo a S3 no cambia el origen, no interrumpe ninguna aplicación en ejecución y puede
reejecutarse o reanudarse sin consecuencias. Nada depende de que termine hasta que se migre la
aplicación que lo lee, así que puede ocupar todo el calendario sin bloquear nada.

El cutover de aplicaciones es secuencial porque es una **transición de estado con dependencias y riesgo
compartido**. El cutover de base de datos de la oleada 2 depende de que los servidores de aplicación de
la oleada 1 estén estables en AWS y alcanzables desde la nueva capa de datos; hacer el cutover de la
base de datos mientras la capa de aplicación está a mitad de migración significa que una falla podría
originarse en cualquiera de las dos, y no podés decir cuál. Los cutovers también compiten por los
mismos recursos escasos: la ventana de mantenimiento, el equipo de guardia, los dueños de la aplicación
que deben validar y la capacidad de rollback. Dos cutovers simultáneos significan un único incidente
con dos causas posibles y un equipo dividido entre ambas. La secuenciación es lo que preserva la
capacidad de atribuir una falla y hacer rollback limpiamente.

**A35.** Porque una ruta de rollback es una **afirmación sobre el comportamiento bajo falla**, y la
única evidencia de tal afirmación es haber observado ese comportamiento. La replicación inversa de DMS
tiene muchos modos de falla silenciosos: la tarea inversa puede carecer de permisos, el destino Oracle
puede rechazar tipos originados en PostgreSQL, las secuencias y columnas de identidad pueden estar
desincronizadas, la tarea inversa puede no haberse iniciado nunca y por lo tanto no tener posición de
inicio de CDC, la conectividad puede haberse cerrado después del cutover hacia adelante. Cada una de
esas es invisible hasta que lo intentás, y te enterás en el peor momento posible: en medio del
incidente, bajo presión de tiempo, con el negocio esperando.

Un rollback no probado es peor que no tener rollback, porque cambia la decisión que tomás. Creyendo que
podés volver atrás, aceptás un cutover más riesgoso; al descubrir que no podés, quedás pasado el punto
de no retorno y sin plan. El simulacro protege el **riesgo de negocio reducido**, y específicamente
convierte el riesgo de desconocido en conocido, que es el único tipo que realmente podés gestionar.

**A36.** La **posición de licenciamiento y soporte**: concretamente, si la organización ya posee
licencias de SQL Server con Software Assurance activo, y si la aplicación depende de características
del motor que RDS no expone.

Ese único insumo resuelve la elección limpiamente. Licencias propias con derechos de movilidad, o una
aplicación que necesite acceso al sistema de archivos, trabajos de SQL Agent con dependencias a nivel
del sistema operativo, servidores vinculados, ensamblados CLR o un nivel de parche específico hacen
correcto **MGN más una actualización in situ**: mantenés la inversión en licencias y el control
completo del motor, al costo de seguir administrando la base de datos. Sin derechos existentes, o con
preferencia por dejar de administrarla, lo correcto es **RDS SQL Server**: precio con licencia
incluida, backups automatizados, parcheo y Multi-AZ, al costo de perder el acceso a nivel del sistema
operativo.

Todo lo demás que suele citarse —costo, esfuerzo, "modernización"— está aguas abajo de ese hecho y no
discrimina por sí solo.

</details>

---

## Referencias

Todas las URLs verificadas contra la documentación oficial de AWS.

- **Guía del examen CLF-C02** — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- **AWS Cloud Adoption Framework** — <https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html>
- **Estrategias de migración (las 7 R)** — <https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html>
- **AWS Migration Acceleration Program** — <https://aws.amazon.com/migration-acceleration-program/>
- **AWS Migration Hub** — <https://docs.aws.amazon.com/migrationhub/latest/ug/whatis-migrationhub.html>
- **Región de origen de Migration Hub** — <https://docs.aws.amazon.com/migrationhub/latest/ug/home-region.html>
- **AWS Application Discovery Service** — <https://docs.aws.amazon.com/application-discovery/latest/userguide/what-is-appdiscovery.html>
- **Plantilla de importación de Application Discovery** — <https://docs.aws.amazon.com/application-discovery/latest/userguide/discovery-import.html>
- **AWS Application Migration Service (MGN)** — <https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html>
- **Referencia de la CLI `aws mgn`** — <https://docs.aws.amazon.com/cli/latest/reference/mgn/>
- **AWS Database Migration Service** — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- **Mapeo de tablas de DMS** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html>
- **Configuración de tareas de DMS** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.html>
- **Evaluaciones previas a la migración de DMS** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.AssessmentReport.html>
- **Validación de datos de DMS** — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html>
- **AWS Schema Conversion Tool** — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- **Guía del desarrollador de AWS Snowball Edge** — <https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html>
- **AWS Snow Family** — <https://aws.amazon.com/snow/>
- **AWS DataSync** — <https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html>
- **AWS Storage Gateway** — <https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html>
- **AWS Transfer Family** — <https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html>
- **AWS Migration Evaluator** — <https://aws.amazon.com/migration-evaluator/>
- **Cost Explorer `GetCostAndUsage`** — <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html>
- **Customer Carbon Footprint Tool** — <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ccft-overview.html>
- **Políticas de etiquetas de AWS Organizations** — <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html>