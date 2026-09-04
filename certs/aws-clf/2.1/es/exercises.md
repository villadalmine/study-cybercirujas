# Tema 2.1 — Ejercicios guiados: El modelo de responsabilidad compartida de AWS

> **Contexto del examen:** CLF-C02, Dominio 2 (Seguridad y cumplimiento), Enunciado de tarea 2.1. El Dominio 2 representa el **30%** del examen puntuado; este enunciado de tarea tiene un peso de **7.5**. Es uno de los pocos objetivos de CLF-C02 que casi nunca se pregunta como definición — se pregunta como un *juicio de valor*: "dado este escenario, ¿quién es responsable?"
>
> **Lo que vas a hacer realmente:** en lugar de memorizar el diagrama de la "hamburguesa" de AWS, vas a *derivar el límite a partir de la superficie de API* de una cuenta real, obtener la propia evidencia de auditoría de AWS y construir una matriz de responsabilidad que sobreviva al contacto con producción.

---

## Antes de empezar

### Requisitos previos

| Requisito | Comprobación | Notas |
|---|---|---|
| Cuenta de AWS en la que puedas experimentar | — | Usá una cuenta **sandbox / no productiva**. Varios pasos leen la postura de seguridad de toda la cuenta. |
| AWS CLI **v2** (≥ 2.15) | `aws --version` | Los comandos `aws artifact` del Ejercicio 2 no existen en la CLI v1 ni en las primeras compilaciones de la v2. |
| Un principal de IAM con acceso de lectura + escritura limitada en S3 | — | `ReadOnlyAccess` más `AmazonS3FullAccess` alcanza para todo lo que sigue. **No** uses el usuario root. |
| `jq` (opcional, pero se usa en las salidas) | `jq --version` | Todos los comandos tienen una alternativa con `--query`. |

### Costo y radio de impacto

Cada paso obligatorio de este documento es o bien de **solo lectura** o crea un **bucket S3 vacío** (S3 cobra por almacenamiento y solicitudes; un bucket vacío mantenido durante minutos cuesta efectivamente $0.00). El Ejercicio 5 tiene un bloque **opcional** que lanza una instancia EC2 `t3.micro` — está claramente marcado, y el desmantelamiento es obligatorio si lo ejecutás.

Nada de lo que hay acá habilita AWS Config, GuardDuty, Security Hub, Inspector ni Macie. Los vas a *consultar* para probar que están apagados — esa es la lección.

### Definí tus variables de trabajo

```bash
export AWS_PROFILE=clf-sandbox          # adjust to your profile
export AWS_REGION=us-east-1             # some steps are region-scoped; keep this consistent
export AWS_PAGER=""                     # stop the CLI from opening a pager on every call
```

---

## Ejercicio 0 — Establecé dónde estás parado

El modelo de responsabilidad compartida no es abstracto: es una afirmación sobre *una cuenta específica*, en *una región específica*, bajo *un acuerdo específico*. Empezá por fijar los tres.

### Pasos

1. Confirmá la identidad que está usando la CLI.

   ```bash
   aws sts get-caller-identity
   ```

   Salida esperada (abreviada):

   ```json
   {
       "UserId": "AIDAEXAMPLE5EXAMPLE7",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-lab"
   }
   ```

2. Guardá el ID de la cuenta — varios comandos posteriores lo necesitan.

   ```bash
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   echo "$ACCOUNT_ID"
   ```

3. Confirmá que **no** estás operando como root.

   ```bash
   aws sts get-caller-identity --query Arn --output text | grep -q ':root$' \
     && echo "ROOT — stop and switch to an IAM principal" \
     || echo "OK: IAM principal"
   ```

4. Listá las regiones que tu cuenta puede alcanzar, y contalas.

   ```bash
   aws ec2 describe-regions --query 'length(Regions)'
   aws ec2 describe-regions \
     --query 'Regions[?OptInStatus!=`opt-in-not-required`].[RegionName,OptInStatus]' \
     --output table
   ```

   Salida esperada (abreviada):

   ```
   17
   ------------------------------------------
   |             DescribeRegions            |
   +----------------+-----------------------+
   |  ap-east-1     |  not-opted-in         |
   |  me-south-1    |  not-opted-in         |
   |  af-south-1    |  not-opted-in         |
   +----------------+-----------------------+
   ```

### Verificación de comprensión — Bloque 0

- **P0.1** — AWS opera los centros de datos físicos en cada una de esas regiones. ¿Por qué el *conjunto de regiones en las que corren tus cargas de trabajo* cae igualmente del lado del cliente en la línea de responsabilidad?
- **P0.2** — Las regiones de adhesión (opt-in) están deshabilitadas por defecto en las cuentas nuevas. ¿Es "qué regiones están habilitadas" un control de seguridad y, de serlo, de quién?
- **P0.3** — El paso 3 verifica que no seas root. AWS crea el usuario root por vos y garantiza que no se pueda eliminar. ¿Quién es responsable de que root tenga (o no tenga) MFA?

---

## Ejercicio 1 — Derivá el límite a partir de la superficie de API

**La heurística:** *si una API de AWS te deja cambiarlo, está de tu lado de la línea; si ninguna API lo expone en absoluto, AWS lo posee de punta a punta.* El plano de control es una proyección bastante fiel del límite de responsabilidad. Vas a poner a prueba esa heurística — incluyendo dónde tiene fugas.

### Pasos

1. Pedí algo del lado del cliente de una instancia EC2. Esto funciona:

   ```bash
   aws ec2 describe-security-groups \
     --query 'SecurityGroups[].[GroupId,GroupName,Description]' \
     --output table
   ```

   Salida esperada (abreviada):

   ```
   ------------------------------------------------------------------
   |                     DescribeSecurityGroups                     |
   +--------------+----------+----------------------------------+
   |  sg-0a1b2c3d |  default |  default VPC security group      |
   +--------------+----------+----------------------------------+
   ```

2. Ahora pedí algo del lado de AWS. No existe tal API — tratá de encontrar una:

   ```bash
   aws ec2 help | grep -iE 'hypervisor|firmware|host-patch|datacenter' || echo "no such operation"
   ```

   Salida esperada:

   ```
   no such operation
   ```

   > `describe-hosts` existe, pero describe **Dedicated Hosts** — una construcción de facturación y tenencia — no el hipervisor. No hay operación, en ningún servicio de AWS, que devuelva el nivel de parche del hipervisor Nitro, la versión de firmware de la NIC del host, o el rack físico de tu instancia.

3. Encontrá el único lugar donde AWS filtra deliberadamente *un poco* de su lado: metadatos de instancia sobre la plataforma subyacente.

   ```bash
   aws ec2 describe-instance-types --instance-types t3.micro m7i.large \
     --query 'InstanceTypes[].[InstanceType,Hypervisor,BareMetal,NitroEnclavesSupport]' \
     --output table
   ```

   Salida esperada:

   ```
   -----------------------------------------------------------
   |                 DescribeInstanceTypes                   |
   +---------------+----------+-----------+------------------+
   |  t3.micro     |  nitro   |  False    |  unsupported     |
   |  m7i.large    |  nitro   |  False    |  supported       |
   +---------------+----------+-----------+------------------+
   ```

   Podés *observar* `Hypervisor: nitro`. No podés parchearlo, configurarlo ni auditarlo. La observabilidad no es responsabilidad.

4. Probá la heurística contra un servicio donde se sostiene limpiamente — la durabilidad de S3 frente al acceso a S3:

   ```bash
   # Access control: many APIs. Yours.
   aws s3api help | grep -cE '^\s+o (put|get|delete)-bucket-(policy|acl|encryption|versioning|logging)'

   # Durability / replication factor across AZs: zero APIs. AWS's.
   aws s3api help | grep -icE 'replication-factor|disk-array|erasure' || echo "no such operation"
   ```

### Verificación de comprensión — Bloque 1

- **P1.1** — Enunciá la heurística de la "superficie de API" en una oración, y después dá un ejemplo concreto de este ejercicio donde se sostiene.
- **P1.2** — `describe-instance-types` informa `Hypervisor: nitro`. Explicá por qué esto **no** convierte el parcheo del hipervisor en una responsabilidad compartida.
- **P1.3** — Nombrá un caso donde la heurística **tiene fugas**: existe una API de AWS, pero AWS — no vos — realiza el trabajo subyacente. (Pista: pensá en una actualización de motor de base de datos gestionada.)
- **P1.4** — S3 almacena tus objetos de forma redundante en al menos tres zonas de disponibilidad de una región, y publica un objetivo de diseño de durabilidad del 99.999999999%. No podés configurar eso. ¿A cuál de las tres categorías de control (heredado / compartido / específico del cliente) pertenece?

---

## Ejercicio 2 — "Seguridad **de** la nube": obtené la evidencia de AWS, no le creas de palabra

La mitad del modelo que le corresponde a AWS no es una promesa, es una afirmación *auditada*. La obligación del lado del cliente que se desprende de esto se enuncia mal con frecuencia en el examen: **no** sos responsable de auditar los centros de datos de AWS — *sí* sos responsable de **obtener y revisar** los informes de auditoría para tu propio programa de cumplimiento. AWS Artifact es el portal de autoservicio para exactamente eso.

### Pasos

1. Confirmá que tu CLI tiene la API de Artifact.

   ```bash
   aws artifact list-reports --max-results 5 --query 'reports[].[name,series,state]' --output table
   ```

   Salida esperada (abreviada — el catálogo cambia constantemente):

   ```
   ------------------------------------------------------------------------------
   |                                 ListReports                                |
   +----------------------------------------------+---------------+-------------+
   |  AWS SOC 2 Type II Report                    |  SOC 2        |  PUBLISHED  |
   |  AWS SOC 1 Type II Report                    |  SOC 1        |  PUBLISHED  |
   |  AWS ISO 27001:2022 Certification            |  ISO          |  PUBLISHED  |
   |  PCI DSS Attestation of Compliance (AOC)     |  PCI          |  PUBLISHED  |
   |  AWS FedRAMP ... Package                     |  FedRAMP      |  PUBLISHED  |
   +----------------------------------------------+---------------+-------------+
   ```

   > Si obtenés `Invalid choice: 'artifact'`, actualizá a una AWS CLI v2 actual. Si obtenés `AccessDeniedException`, a tu principal le falta `artifact:ListReports` — agregalo, o usá la consola en **AWS Artifact → Reports**.

2. Elegí un informe y leé sus metadatos sin descargarlo.

   ```bash
   REPORT_ID=$(aws artifact list-reports \
     --query "reports[?contains(name, 'SOC 2')] | [0].id" --output text)
   echo "$REPORT_ID"

   aws artifact get-report-metadata --report-id "$REPORT_ID" \
     --query 'reportDetails.{name:name,version:version,period:join(`" to "`,[periodStart,periodEnd]),acceptance:acceptanceType}'
   ```

   Salida esperada (abreviada):

   ```json
   {
       "name": "AWS SOC 2 Type II Report",
       "version": 1,
       "period": "2025-10-01T00:00:00Z to 2026-03-31T00:00:00Z",
       "acceptance": "EXPLICIT"
   }
   ```

3. Fijate en `acceptanceType: EXPLICIT`. Eso significa que el informe está bajo NDA y que tenés que aceptar los términos **antes** de poder recuperarlo. Obtené los términos:

   ```bash
   aws artifact get-term-for-report --report-id "$REPORT_ID" --report-version 1 \
     --query '{term:documentPresignedUrl, token:termToken}'
   ```

   Salida esperada (abreviada):

   ```json
   {
       "term": "https://artifact-terms-prod-us-east-1.s3.amazonaws.com/...&X-Amz-Signature=...",
       "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi..."
   }
   ```

4. **Leé el documento de términos** (abrí la URL prefirmada), y después canjeá el token por el informe en sí:

   ```bash
   TERM_TOKEN=$(aws artifact get-term-for-report --report-id "$REPORT_ID" \
     --report-version 1 --query termToken --output text)

   aws artifact get-report --report-id "$REPORT_ID" --report-version 1 \
     --term-token "$TERM_TOKEN" --query documentPresignedUrl --output text
   ```

   La URL devuelta es un enlace prefirmado de corta duración al PDF.

5. Ahora mirá la *otra* mitad de Artifact — los acuerdos que **vos** firmás:

   ```bash
   aws artifact list-customer-agreements \
     --query 'customerAgreements[].[name,state,agreementType]' --output table
   ```

   Salida esperada (abreviada):

   ```
   ---------------------------------------------------------------
   |                  ListCustomerAgreements                     |
   +----------------------------------+----------+---------------+
   |  AWS Customer Agreement          |  ACTIVE  |  DEFAULT      |
   +----------------------------------+----------+---------------+
   ```

   Los **Agreements** de Artifact (por ejemplo, el Anexo de Asociado Comercial de HIPAA) son cosas que acepta el *cliente*. Los **Reports** de Artifact son cosas que AWS le provee *al* cliente. Ambos viven en una sola consola; están en lados opuestos de la línea de responsabilidad.

### Verificación de comprensión — Bloque 2

- **P2.1** — Un regulador le pide a tu organización que demuestre que la seguridad física de la instalación que aloja tus datos fue evaluada de forma independiente. ¿Qué lado del modelo realiza la evaluación, y qué lado es responsable de producir la evidencia ante el regulador?
- **P2.2** — Tu CISO pregunta: "¿Podemos enviar a nuestros propios auditores a recorrer el centro de datos de AWS en `us-east-1`?" Respondé, y justificalo en términos del modelo.
- **P2.3** — Explicá la diferencia entre un **Report** de Artifact y un **Agreement** de Artifact, usando el informe SOC 2 y el BAA de HIPAA como ejemplos.
- **P2.4** — Un equipo ejecuta una carga de trabajo de pagos dentro del alcance de PCI-DSS sobre EC2. El AOC de PCI de AWS está disponible en Artifact. ¿Eso hace que la carga de trabajo sea conforme a PCI? Explicá usando el término **controles heredados**.
- **P2.5** — El paso 3 devolvió `acceptanceType: EXPLICIT` y un `termToken`. ¿Qué responsabilidad le impone ese mecanismo al cliente?

---

## Ejercicio 3 — "Seguridad **en** la nube": medí la postura de tu propia cuenta

AWS no va a arreglar nada de lo que sigue por vos. Provee el interruptor; dejarlo apagado es una decisión del cliente con consecuencias del cliente.

### Pasos

1. Verificá si el **usuario root** tiene MFA. Esta es la responsabilidad del cliente más evaluada de todo el dominio.

   ```bash
   aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,Users:Users,MFADevices:MFADevices,AccessKeysPerUserQuota:AccessKeysPerUserQuota}'
   ```

   Salida esperada:

   ```json
   {
       "RootMFA": 1,
       "Users": 3,
       "MFADevices": 2,
       "AccessKeysPerUserQuota": 2
   }
   ```

   `RootMFA: 0` significa que root no tiene MFA. Arreglá eso antes de continuar con cualquier otra cosa en tus propias cuentas.

2. Verificá la política de contraseñas de la cuenta:

   ```bash
   aws iam get-account-password-policy
   ```

   Salida esperada en una cuenta nueva:

   ```
   An error occurred (NoSuchEntity) when calling the GetAccountPasswordPolicy operation:
   Cannot find Password Policy for this AWS account.
   ```

   AWS **no** trae ninguna política de contraseñas por defecto. La ausencia es en sí misma el hallazgo.

3. Generá y leé el informe de credenciales de IAM — la lista autoritativa de quién puede autenticarse y qué tan viejas están sus claves.

   ```bash
   aws iam generate-credential-report
   sleep 5
   aws iam get-credential-report --query Content --output text | base64 -d > /tmp/creds.csv
   # macOS: base64 -D
   cut -d, -f1,4,8,9,14 /tmp/creds.csv | column -t -s,
   ```

   Salida esperada (abreviada):

   ```
   user            password_enabled  access_key_1_active  access_key_1_last_rotated  mfa_active
   <root_account>  not_supported     false                N/A                        true
   clf-lab         true              true                 2025-02-11T09:14:00+00:00  true
   ci-deployer     false             true                 2024-06-02T17:40:00+00:00  false
   ```

   `ci-deployer` tiene una clave de acceso de **más de un año** y sin MFA. AWS no la rotó, no la va a rotar, y no tiene ninguna obligación de hacerlo.

4. Buscá grupos de seguridad abiertos al mundo:

   ```bash
   aws ec2 describe-security-groups \
     --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
     --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId}' \
     --output table
   ```

   En una cuenta nueva esto suele estar vacío — el grupo de seguridad por defecto de la VPC solo permite tráfico entrante desde sí mismo. Cualquier cosa que *sí* aparezca fue creada por una persona o por un pipeline en tu cuenta.

5. Verificá el valor por defecto de cifrado de EBS a nivel de región:

   ```bash
   aws ec2 get-ebs-encryption-by-default
   ```

   Salida esperada:

   ```json
   {
       "EbsEncryptionByDefault": false
   }
   ```

   AWS provee el cifrado; está **apagado por defecto y se configura por región**. Encenderlo es una sola llamada a la API — y tenés que repetirlo en cada región que uses:

   ```bash
   # Optional, and safe: affects only volumes created after this point.
   aws ec2 enable-ebs-encryption-by-default
   ```

6. Verificá la configuración de S3 Block Public Access **a nivel de cuenta**:

   ```bash
   aws s3control get-public-access-block --account-id "$ACCOUNT_ID"
   ```

   Salida esperada en la mayoría de las cuentas:

   ```
   An error occurred (NoSuchPublicAccessBlockConfiguration) when calling the
   GetPublicAccessBlock operation: The public access block configuration was not found
   ```

   El BPA a nivel de bucket está activado por defecto para los buckets nuevos (Ejercicio 4); la barrera de protección **a nivel de cuenta** no está configurada a menos que vos la configures.

### Verificación de comprensión — Bloque 3

- **P3.1** — El paso 2 muestra que AWS no aplica ninguna política de contraseñas por defecto. Argumentá *por qué* eso es coherente con el modelo de responsabilidad compartida en lugar de ser una falencia del mismo.
- **P3.2** — `ci-deployer` tiene una clave de acceso de 15 meses de antigüedad. Bajo el modelo, ¿quién es responsable si esa clave se filtra en un repositorio público de Git y se usa para exfiltrar datos? ¿Cambia la respuesta si la filtración ocurrió por un error en un servicio de AWS?
- **P3.3** — ¿Por qué `EbsEncryptionByDefault` es una configuración **por región**, y qué riesgo operativo genera eso para un cliente que cree que "activamos el cifrado"?
- **P3.4** — Clasificá cada uno de los siguientes como AWS, cliente o compartido: (a) la implementación de AES-256 que usa el cifrado de EBS; (b) la decisión de cifrar un volumen determinado; (c) la durabilidad del material de clave de KMS; (d) la política de clave de KMS.

---

## Ejercicio 4 — Controles heredados, compartidos y específicos del cliente, vistos en los valores por defecto de S3

AWS movió varios controles de "el cliente debe acordarse" a "seguro por defecto" — pero **los valores por defecto no son responsabilidades**. Un valor por defecto que podés apagar sigue siendo tuyo. Este ejercicio lo hace concreto.

### Pasos

1. Creá un bucket descartable.

   ```bash
   export BUCKET="clf-srm-${ACCOUNT_ID}-$RANDOM"

   if [ "$AWS_REGION" = "us-east-1" ]; then
     aws s3api create-bucket --bucket "$BUCKET"
   else
     aws s3api create-bucket --bucket "$BUCKET" \
       --create-bucket-configuration LocationConstraint="$AWS_REGION"
   fi
   echo "$BUCKET"
   ```

2. Inspeccioná los tres valores por defecto que AWS ahora aplica sin que se lo pidas.

   ```bash
   aws s3api get-public-access-block --bucket "$BUCKET"
   aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
   aws s3api get-bucket-encryption --bucket "$BUCKET"
   ```

   Salida esperada:

   ```json
   {
       "PublicAccessBlockConfiguration": {
           "BlockPublicAcls": true,
           "IgnorePublicAcls": true,
           "BlockPublicPolicy": true,
           "RestrictPublicBuckets": true
       }
   }
   ```
   ```json
   {
       "OwnershipControls": {
           "Rules": [
               { "ObjectOwnership": "BucketOwnerEnforced" }
           ]
       }
   }
   ```
   ```json
   {
       "ServerSideEncryptionConfiguration": {
           "Rules": [
               {
                   "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
                   "BucketKeyEnabled": false
               }
           ]
       }
   }
   ```

   Desde abril de 2023 todos los buckets nuevos tienen Block Public Access habilitado y las ACL deshabilitadas; desde enero de 2023 todos los objetos nuevos se cifran con SSE-S3 sin costo. **Estos son valores por defecto más seguros del lado del cliente de la línea, no una transferencia de responsabilidad.**

3. Comprobá que la barrera de protección es real. Intentá adjuntar una política de bucket legible por todo el mundo:

   ```bash
   cat > /tmp/public-policy.json <<EOF
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "PublicRead",
       "Effect": "Allow",
       "Principal": "*",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::${BUCKET}/*"
     }]
   }
   EOF

   aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/public-policy.json
   ```

   Salida esperada:

   ```
   An error occurred (AccessDenied) when calling the PutBucketPolicy operation:
   User: arn:aws:iam::123456789012:user/clf-lab is not authorized to perform:
   s3:PutBucketPolicy on resource: "arn:aws:s3:::clf-srm-123456789012-24815"
   because public policies are blocked by the BlockPublicPolicy block public access setting.
   ```

4. Ahora comprobá que la barrera de protección es *tuya para quitarla*. **No te saltees el paso 6.**

   ```bash
   aws s3api put-public-access-block --bucket "$BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

   aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/public-policy.json
   echo "exit=$?"
   ```

   Salida esperada:

   ```
   exit=0
   ```

   Dos llamadas a la API, sin advertencia, sin aprobación, sin intervención de AWS. El bucket ahora es público. AWS hizo exactamente lo que le pediste, y el resultado está enteramente de tu lado del modelo.

5. Observá cómo lo informa S3:

   ```bash
   aws s3api get-bucket-policy-status --bucket "$BUCKET"
   ```

   Salida esperada:

   ```json
   {
       "PolicyStatus": {
           "IsPublic": true
       }
   }
   ```

6. **Revertí de inmediato.**

   ```bash
   aws s3api delete-bucket-policy --bucket "$BUCKET"
   aws s3api put-public-access-block --bucket "$BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
   aws s3api get-public-access-block --bucket "$BUCKET" \
     --query 'PublicAccessBlockConfiguration.BlockPublicPolicy'
   ```

   Salida esperada:

   ```
   true
   ```

### Verificación de comprensión — Bloque 4

- **P4.1** — El bucket del paso 4 pasó a ser legible públicamente. Bajo el modelo de responsabilidad compartida, ¿de quién es la responsabilidad de (a) que S3 *haya servido* los objetos a solicitantes anónimos, y (b) que los objetos hayan quedado expuestos en primer lugar?
- **P4.2** — Los objetos estuvieron cifrados con SSE-S3 todo el tiempo. Explicá con precisión por qué ese cifrado **no** impidió la exposición, y qué clase de amenaza sí aborda SSE-S3.
- **P4.3** — Definí **control heredado**, **control compartido** y **control específico del cliente**, y ubicá cada uno de estos en la caja correcta: destrucción física de medios; gestión de parches; aprovisionamiento de usuarios de IAM; redundancia eléctrica del centro de datos; concientización y capacitación; seguridad de zona.
- **P4.4** — `BucketOwnerEnforced` deshabilita las ACL. ¿Por qué el hecho de que AWS cambie este valor por defecto *reduce el riesgo del cliente* sin *reducir su responsabilidad*?

---

## Ejercicio 5 — Gestión de parches: el control **compartido** canónico

El parcheo es el control compartido favorito del examen, porque la respuesta cambia según el servicio. AWS parchea la infraestructura; el cliente parchea el huésped. Dónde termina el "huésped" depende del nivel de abstracción.

### Pasos

1. Comprobá que AWS *publica* artefactos parcheados. Mirá el puntero de la AMI actual de Amazon Linux 2023 en SSM Parameter Store:

   ```bash
   aws ssm get-parameters-by-path \
     --path /aws/service/ami-amazon-linux-latest \
     --query "Parameters[?contains(Name,'al2023-ami-kernel-default-x86_64')].[Name,Value,LastModifiedDate]" \
     --output table
   ```

   Salida esperada (abreviada):

   ```
   -----------------------------------------------------------------------------------------
   |  /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 | ami-0abc... |
   |  2026-08-19T18:22:41.113000+00:00                                                     |
   -----------------------------------------------------------------------------------------
   ```

2. Comprobá que AWS también provee el *catálogo* de parches — todavía sin aplicar nada:

   ```bash
   aws ssm describe-available-patches \
     --filters Key=PRODUCT,Values=AmazonLinux2023 Key=SEVERITY,Values=Critical \
     --max-results 5 \
     --query 'Patches[].[Title,Severity,ReleaseDate]' --output table
   ```

   Salida esperada (abreviada):

   ```
   -----------------------------------------------------------------------
   |  ALAS2023-2026-1042 (openssl)          |  Critical |  2026-07-28...  |
   |  ALAS2023-2026-1019 (kernel)           |  Critical |  2026-07-11...  |
   -----------------------------------------------------------------------
   ```

3. Mirá la línea base de parches por defecto — AWS la escribe, vos podés reemplazarla:

   ```bash
   aws ssm get-default-patch-baseline --operating-system AMAZON_LINUX_2023
   ```

   Salida esperada:

   ```json
   {
       "BaselineId": "pb-0c10e65780EXAMPLE",
       "OperatingSystem": "AMAZON_LINUX_2023"
   }
   ```

4. Ahora confirmá que no se está parcheando nada, porque **vos no lo programaste**:

   ```bash
   aws ssm describe-instance-patch-states --instance-ids i-000000000000EXAMPLE 2>/dev/null \
     || aws ssm describe-patch-baselines --query 'length(BaselineIdentities)'
   aws ssm describe-maintenance-windows --query 'WindowIdentities'
   ```

   Salida esperada en una cuenta nueva:

   ```
   16
   []
   ```

   Existen dieciséis líneas base gestionadas por AWS. Existen cero ventanas de mantenimiento. AWS construyó la herramienta y la dejó ociosa.

5. **Comparalo con una base de datos gestionada.** Acá la responsabilidad del cliente sobre el SO desaparece — y en su lugar aparece una responsabilidad de *programación*.

   ```bash
   aws rds describe-db-engine-versions --engine postgres \
     --query 'DBEngineVersions[].[EngineVersion,Status]' --output table | head -20
   ```

   Salida esperada (abreviada):

   ```
   ----------------------------------------
   |   14.12   |  deprecated              |
   |   15.7    |  available               |
   |   16.4    |  available               |
   |   17.2    |  available               |
   ----------------------------------------
   ```

   ```bash
   aws rds describe-pending-maintenance-actions
   aws rds describe-db-instances \
     --query 'DBInstances[].[DBInstanceIdentifier,EngineVersion,AutoMinorVersionUpgrade,BackupRetentionPeriod,StorageEncrypted,PubliclyAccessible]' \
     --output table
   ```

   Salida esperada sin instancias de RDS:

   ```json
   {
       "PendingMaintenanceActions": []
   }
   ```

   > En RDS no podés hacer SSH al host y nunca ves un CVE del kernel. Pero `Status: deprecated` es una señal dirigida al cliente: **AWS no va a reescribir silenciosamente tu versión mayor.** Quedarse en un motor obsoleto es una decisión del cliente con una fecha de vencimiento que le pertenece al cliente.

6. **Comparalo con una función serverless.** El mismo patrón, con un borde más filoso:

   ```bash
   aws lambda list-functions --query 'Functions[].[FunctionName,Runtime,PackageType]' --output table
   ```

   Salida esperada sin funciones:

   ```
   ----------------
   |ListFunctions |
   +--------------+
   ```

   AWS parchea el runtime de Lambda, el SO y el microVM de firecracker. **Deprecia** runtimes según un cronograma publicado; migrar tu código fuera de `python3.9` antes de esa fecha es cosa tuya. Y AWS nunca parchea una biblioteca vulnerable que vos empaquetaste en tu paquete de despliegue.

<details>
<summary><strong>Bloque pago opcional (≈ $0.01, terminá la instancia al finalizar): observá la deriva en una instancia real</strong></summary>

```bash
AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

INSTANCE=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --count 1 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf-srm-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "$INSTANCE"

# Wait ~3 minutes for the SSM Agent to register (requires an instance profile
# with AmazonSSMManagedInstanceCore; if absent, the instance will not appear).
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PlatformName,PlatformVersion,AgentVersion]' \
  --output table

# MANDATORY teardown
aws ec2 terminate-instances --instance-ids "$INSTANCE" \
  --query 'TerminatingInstances[].CurrentState.Name' --output text
```

La instancia se lanzó desde una AMI completamente parcheada. Desde el momento en que arranca, cada nuevo CVE es tuyo hasta que *vos* ejecutes una operación de parcheo. La AMI parcheada de AWS no sigue a la instancia en ejecución.

</details>

### Verificación de comprensión — Bloque 5

- **P5.1** — Para cada servicio, decí quién parchea el **sistema operativo huésped**: EC2, RDS, Lambda, Fargate, S3.
- **P5.2** — El paso 5 mostró PostgreSQL 14.12 como `deprecated`. Un cliente se queda en esa versión dos años más y sufre una brecha a través de un CVE conocido del motor. ¿De quién es la responsabilidad, y por qué "RDS es gestionado" no la transfiere?
- **P5.3** — Una función Lambda empaqueta una versión vulnerable de una biblioteca de análisis de JSON. AWS parchea el runtime `python3.13` semanalmente. ¿Se parchea la biblioteca vulnerable? Justificá.
- **P5.4** — Explicá por qué la gestión de parches se clasifica como un **control compartido** y no como un control de AWS o un control del cliente, y describí qué hace realmente cada lado.
- **P5.5** — El paso 4 encontró 16 líneas base de parches escritas por AWS y 0 ventanas de mantenimiento. ¿Qué demuestra ese par de números sobre cómo AWS cumple su mitad de un control compartido?

---

## Ejercicio 6 — El gradiente de abstracción: construí la matriz vos mismo

El modelo mental más útil para los escenarios del examen: **cuanto más gestionado es el servicio, menos parte de la pila es tuya — pero los datos y el acceso a ellos son siempre tuyos.**

### Pasos

1. Consultá la superficie configurable por el cliente en cada nivel de abstracción y contá las perillas.

   ```bash
   for svc in ec2 rds lambda s3api; do
     printf "%-8s %s operations\n" "$svc" "$(aws $svc help 2>/dev/null | grep -cE '^\s+o [a-z]')"
   done
   ```

   Salida esperada (ilustrativa — los conteos varían a medida que AWS publica APIs):

   ```
   ec2      620 operations
   rds      160 operations
   lambda   70 operations
   s3api    100 operations
   ```

2. Confirmá que la capa de *identidad y datos* está presente en cada nivel — este es el invariante.

   ```bash
   # Resource policies exist for all three abstraction levels:
   aws s3api  help | grep -c 'put-bucket-policy'
   aws lambda help | grep -c 'add-permission'
   aws kms    help | grep -c 'put-key-policy'
   ```

3. Confirmá que la capa de *host* desaparece a medida que sube la abstracción:

   ```bash
   aws ec2    help | grep -c 'get-console-output'    # 1 — you can see the guest console
   aws rds    help | grep -c 'get-console-output' || echo "0 — no host access on RDS"
   aws lambda help | grep -c 'get-console-output' || echo "0 — no host access on Lambda"
   ```

4. Completá esta matriz en papel antes de leer las respuestas. Usá **A** (AWS), **C** (Cliente), **S** (Compartido).

   | Control | EC2 | RDS | Lambda | S3 |
   |---|---|---|---|---|
   | Seguridad física de la instalación | | | | |
   | Parcheo del hipervisor / microVM | | | | |
   | Parcheo del SO huésped | | | | |
   | Actualización de versión menor del motor de base de datos | | n/a | n/a | n/a |
   | Código de aplicación / dependencias | | | | |
   | ACL de red y grupos de seguridad | | | | |
   | Cifrado en reposo — *disponibilidad de la función* | | | | |
   | Cifrado en reposo — *decisión de habilitarlo* | | | | |
   | Cifrado en tránsito — *aplicación efectiva* | | | | |
   | Identidades y políticas de IAM | | | | |
   | Clasificación de datos | | | | |
   | **Existencia** de copias de seguridad | | | | |
   | **Pruebas de restauración** de copias de seguridad | | | | |

### Verificación de comprensión — Bloque 6

- **P6.1** — Completá la matriz de arriba.
- **P6.2** — Dos filas de la matriz son `C` en **todas** las columnas. ¿Cuáles dos, y qué principio expresa eso?
- **P6.3** — RDS toma copias de seguridad automáticas cuando `BackupRetentionPeriod > 0`. Un cliente lo pone en `0` para ahorrar costos, y después pierde datos. ¿La pérdida es responsabilidad de AWS porque "RDS hace copias de seguridad"? Explicá la trampa.
- **P6.4** — Un equipo argumenta: "nos mudamos de EC2 a Fargate, así que la seguridad ahora es problema de AWS". Dá la corrección de dos oraciones que debería hacer un SRE.

---

## Ejercicio 7 — Los controles de detección son opcionales (opt-in), y eso es deliberado

AWS provee servicios de detección de clase mundial. No habilita **ninguno** de ellos por vos, y esto es consecuencia directa del modelo: AWS no inspecciona tus cargas de trabajo salvo que se lo pidas.

### Pasos

1. Comprobá que nada está vigilando.

   ```bash
   echo -n "GuardDuty detectors: ";   aws guardduty list-detectors --query 'length(DetectorIds)'
   echo -n "Config recorders:    ";   aws configservice describe-configuration-recorders --query 'length(ConfigurationRecorders)'
   echo -n "Security Hub:        ";   aws securityhub describe-hub 2>&1 | head -1
   echo -n "Access Analyzer:     ";   aws accessanalyzer list-analyzers --query 'length(analyzers)'
   ```

   Salida esperada en una cuenta nueva:

   ```
   GuardDuty detectors: 0
   Config recorders:    0
   Security Hub:        An error occurred (InvalidAccessException) when calling the DescribeHub operation: Account 123456789012 is not subscribed to AWS Security Hub
   Access Analyzer:     0
   ```

2. Ahora confirmá lo único que AWS **sí** enciende por vos, en cada cuenta, sin cargo:

   ```bash
   aws cloudtrail describe-trails --query 'trailList[].[Name,IsMultiRegionTrail,S3BucketName]' --output table
   aws cloudtrail lookup-events --max-results 3 \
     --query 'Events[].[EventTime,EventName,Username]' --output table
   ```

   Salida esperada:

   ```
   ---------------------------------------
   |           DescribeTrails            |
   +-------------------------------------+
   ```
   ```
   ------------------------------------------------------------------
   |                         LookupEvents                           |
   +---------------------------+--------------------+---------------+
   |  2026-09-03T14:02:11+00:00|  PutBucketPolicy   |  clf-lab      |
   |  2026-09-03T14:01:47+00:00|  PutPublicAccessBlock | clf-lab    |
   |  2026-09-03T13:58:02+00:00|  CreateBucket      |  clf-lab      |
   +---------------------------+--------------------+---------------+
   ```

   **No existe ningún trail, y sin embargo los eventos están ahí.** El **Event history** de CloudTrail está activado por defecto, es gratuito y retiene 90 días de eventos de administración por región. La retención más allá de 90 días, la agregación multirregión, los eventos de datos y la validación de integridad de los archivos de log requieren todos un trail creado por *vos*.

   > Fijate que tu propio error del paso 4 del Ejercicio 4 está en esa lista. La atribución de las acciones del cliente es un control que provee AWS; *revisarla* no lo es.

3. Verificá las comprobaciones de seguridad gratuitas de Trusted Advisor (disponibles en todos los planes de soporte):

   ```bash
   aws support describe-trusted-advisor-checks --language en \
     --query "checks[?category=='security'].[name]" --output table 2>&1 | head -12
   ```

   Salida esperada con soporte Basic/Developer:

   ```
   An error occurred (SubscriptionRequiredException) when calling the
   DescribeTrustedAdvisorChecks operation: AWS Premium Support Subscription is required
   ```

   La **API** requiere soporte Business/Enterprise; las comprobaciones de seguridad principales siguen siendo visibles en la consola con cualquier plan. Este es un límite de plan de soporte, no un límite de responsabilidad — vale la pena saberlo para el Dominio 4.

### Verificación de comprensión — Bloque 7

- **P7.1** — El Event history de CloudTrail funcionó con configuración cero; GuardDuty devolvió cero detectores. Conciliá estos dos hechos con el modelo de responsabilidad compartida.
- **P7.2** — Nombrá los tres límites del Event history de CloudTrail que un cliente debe superar creando un trail.
- **P7.3** — Un atacante usa credenciales robadas para llamar a `GetObject` sobre 4 TB de tus datos durante seis horas. GuardDuty nunca estuvo habilitado. ¿Estaba AWS obligada a notarlo? ¿Estaba AWS obligada a *registrarlo*?
- **P7.4** — ¿Por qué es coherente con el modelo — y no una deficiencia — que AWS no escanee por defecto el contenido de tus buckets S3 o volúmenes EBS?

---

## Ejercicio 8 — El borde contractual: acuerdos, uso aceptable y pruebas de penetración

Algunas responsabilidades no se expresan en ninguna API. Están en el acuerdo que aceptaste en el Ejercicio 2.

### Pasos

1. Releé aquello por lo que estás obligado:

   ```bash
   aws artifact list-customer-agreements \
     --query 'customerAgreements[].[name,agreementType,state,effectiveStart]' --output table
   ```

2. Abrí los dos documentos rectores y hojealos (sin CLI — estas son las fuentes):

   - AWS Customer Agreement — <https://aws.amazon.com/agreement/>
   - AWS Acceptable Use Policy — <https://aws.amazon.com/aup/>
   - AWS Customer Support Policy for Penetration Testing — <https://aws.amazon.com/security/penetration-testing/>

3. Respondé, a partir de la política de pruebas de penetración y sin adivinar: ¿qué actividades puede realizar un cliente contra **sus propios** recursos sin aprobación previa de AWS, y cuáles están **prohibidas de plano**?

4. Confirmá la postura de propiedad de los datos declarada en el acuerdo y en las preguntas frecuentes sobre privacidad de datos (<https://aws.amazon.com/compliance/data-privacy-faq/>): AWS no accede al contenido del cliente salvo lo requerido para prestar los servicios o para cumplir con la ley, y el cliente conserva la propiedad y el control.

5. Probá la consecuencia práctica de "los datos son tuyos" — la eliminación es definitiva:

   ```bash
   # Versioning is OFF by default. Confirm on your scratch bucket:
   aws s3api get-bucket-versioning --bucket "$BUCKET"
   ```

   Salida esperada:

   ```json
   {}
   ```

   Un objeto vacío significa que el versionado nunca se habilitó. Eliminá un objeto en ese bucket y **ningún proceso de AWS, caso de soporte ni copia de seguridad lo va a traer de vuelta.** Habilitar el versionado y MFA Delete es un control del cliente:

   ```bash
   aws s3api put-bucket-versioning --bucket "$BUCKET" \
     --versioning-configuration Status=Enabled
   aws s3api get-bucket-versioning --bucket "$BUCKET"
   ```

   ```json
   {
       "Status": "Enabled"
   }
   ```

### Verificación de comprensión — Bloque 8

- **P8.1** — Bajo el AWS Customer Agreement y las preguntas frecuentes sobre privacidad de datos, ¿quién es dueño del contenido del cliente, y qué implica esa propiedad respecto de la eliminación?
- **P8.2** — Tu equipo de seguridad quiere ejecutar un escaneo de puertos y una simulación de credential stuffing contra tus propias instancias EC2, y una prueba de DDoS volumétrico contra tu propio ALB para validar Shield. ¿Cuáles de estas están permitidas, cuáles requieren aprobación y cuáles están prohibidas?
- **P8.3** — Un desarrollador ejecuta un contenedor de criptominería en Fargate dentro de tu cuenta. AWS suspende la cuenta. ¿Qué documento rige ese desenlace, y de qué lado del modelo está la infracción?
- **P8.4** — El versionado de S3 está apagado por defecto y la durabilidad de 11 nueves está activa por defecto. Explicá, en términos de responsabilidad, por qué la durabilidad no protege contra `aws s3 rm`.

---

## Ejercicio 9 — Trabajo final: triaje de incidentes

Para cada escenario, escribí (a) la parte responsable, (b) el control *específico* que falló, y (c) el control nativo de AWS que lo hubiera prevenido o detectado. Usá solamente lo que ejercitaste arriba.

### Pasos

1. **Escenario A** — Se descubre que un bucket S3 que contiene PII de clientes está indexado por un motor de búsqueda. CloudTrail muestra `PutPublicAccessBlock` seguido de `PutBucketPolicy`, ambos por un rol de IAM asociado a un pipeline de CI, hace 40 días.

2. **Escenario B** — Una instancia EC2 con Amazon Linux 2023, lanzada hace 14 meses desde una AMI vigente en ese momento, es comprometida a través de un CVE de OpenSSH sin parchear publicado hace 9 meses. La instancia tenía `AmazonSSMManagedInstanceCore` adjunto, pero no existía ninguna ventana de mantenimiento.

3. **Escenario C** — Se divulga una vulnerabilidad del hipervisor Nitro. AWS publica un boletín de seguridad declarando que todas las flotas fueron remediadas antes de la divulgación, sin acción requerida del cliente y sin reinicios de instancias.

4. **Escenario D** — Una instancia RDS PostgreSQL es eliminada por un ingeniero que usa un rol con `rds:DeleteDBInstance`. `SkipFinalSnapshot` estaba en `true` y `DeletionProtection` en `false`. La retención de copias de seguridad era de 7 días; las copias automáticas se eliminaron junto con la instancia.

5. **Escenario E** — Una función Lambda que procesa pagos registra el PAN completo de la tarjeta en CloudWatch Logs. El grupo de logs no tiene política de retención y no está cifrado con una clave KMS gestionada por el cliente.

6. **Escenario F** — Una zona de disponibilidad completa se queda sin energía. Una instancia RDS de una sola AZ queda indisponible durante 4 horas. Una instancia Multi-AZ en la misma cuenta conmuta por error en 90 segundos.

### Verificación de comprensión — Bloque 9

- **P9.1** — Completá la tabla de triaje para los escenarios A–F.
- **P9.2** — ¿Qué único escenario es responsabilidad **inequívoca de AWS**, y qué evidencia del escenario te lo indica?
- **P9.3** — El Escenario F contiene tanto una responsabilidad de AWS como una del cliente. Separalas con precisión.
- **P9.4** — Formulá una regla de una sola oración que pudieras aplicar a cualquier pregunta de escenario no vista de CLF-C02 sobre responsabilidad.

---

## Desmantelamiento

```bash
# Remove the scratch bucket (versioning is now on, so purge versions first)
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/vers.json 2>/dev/null
[ -s /tmp/vers.json ] && aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/vers.json

aws s3api delete-bucket --bucket "$BUCKET"
aws s3api head-bucket --bucket "$BUCKET" 2>&1 | head -1

# If you ran the optional EC2 block, confirm the instance is gone:
aws ec2 describe-instances --filters Name=tag:Name,Values=clf-srm-lab \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table

rm -f /tmp/public-policy.json /tmp/creds.csv /tmp/vers.json
```

Salida esperada:

```
An error occurred (404) when calling the HeadBucket operation: Not Found
```

> **Dejá `enable-ebs-encryption-by-default` y el MFA de root activados.** No cuestan nada y son el valor por defecto correcto.

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar todas las respuestas (Bloques 0–9)</strong></summary>

### Bloque 0

**R0.1** — AWS es responsable de la seguridad *de* cada región por igual, pero **cuáles** regiones alojan tus datos es una elección del cliente con consecuencias legales y contractuales (residencia de datos, transferencias bajo GDPR, regulación sectorial, latencia). AWS nunca va a mover tus datos entre regiones por su cuenta; la selección de región es un control configurado por el cliente que AWS deliberadamente no toma por vos.

**R0.2** — Sí, y es del cliente. Las regiones opt-in deshabilitadas reducen la superficie de ataque: una credencial robada no puede levantar recursos en una región que nunca habilitaste y nunca monitoreás. AWS las entrega deshabilitadas como valor por defecto más seguro, pero habilitarlas/deshabilitarlas (vía AWS Organizations o la configuración de la cuenta) es una acción del cliente.

**R0.3** — Enteramente del cliente. AWS crea y protege la *infraestructura de autenticación* (el servicio de IAM/inicio de sesión, su disponibilidad, su criptografía). Que el usuario root tenga MFA, cuál es su contraseña y si tiene claves de acceso son controles específicos del cliente. Este es el hallazgo individual más común en auditorías reales de cuentas y una respuesta recurrente en CLF-C02.

---

### Bloque 1

**R1.1** — *Si una API de AWS te deja cambiarlo, es tu responsabilidad; si ninguna API lo expone, AWS lo posee de punta a punta.* Ejemplo: `put-bucket-policy` existe, así que quién puede leer tu bucket es tuyo; ninguna API expone el factor de replicación entre AZ de S3, así que la durabilidad es de AWS.

**R1.2** — La responsabilidad sigue al **control**, no a la visibilidad. `Hypervisor: nitro` es un atributo de solo lectura que describe la plataforma que estás comprando. No hay ninguna operación para inspeccionar su nivel de parche, cambiar su configuración o programar su mantenimiento. No podés ser responsable de un sistema sobre el que no podés actuar — y AWS acepta esa responsabilidad contractualmente y la demuestra a través de las auditorías en Artifact.

**R1.3** — Las actualizaciones de versión del motor en RDS. `modify-db-instance --engine-version` y `AutoMinorVersionUpgrade` son APIs de cara al cliente, pero AWS realiza la actualización sobre hosts que vos nunca tocás. El cliente es dueño de la **decisión y el momento**; AWS es dueña de la **ejecución**. El mismo patrón se da con `apply-pending-maintenance-action`. La heurística te dice dónde está la decisión, no siempre dónde ocurre el trabajo.

**R1.4** — **Control heredado.** El cliente hereda íntegramente de AWS la durabilidad de S3 y su redundancia multi-AZ, sin superficie de configuración y sin obligación del cliente más allá de elegir S3.

---

### Bloque 2

**R2.1** — AWS contrata a los auditores independientes y se somete a la evaluación (seguridad *de* la nube). El **cliente** es responsable de obtener el informe resultante desde AWS Artifact y presentarlo ante su regulador como parte de *su propio* paquete de evidencia de cumplimiento. AWS no habla con tu regulador en tu nombre.

**R2.2** — No. AWS no permite auditorías de sus centros de datos por parte de los clientes — no sería escalable y sería en sí mismo un riesgo de seguridad (miles de clientes recorriendo instalaciones). El modelo resuelve esto sustituyendo la inspección directa por **atestación de terceros**: AWS es auditada una vez por auditores acreditados, y cada cliente hereda el resultado vía Artifact bajo NDA. Este es el mecanismo que hace verificable la "seguridad de la nube" sin que sea individualmente auditable.

**R2.3** — Un **Report** (SOC 2) fluye *de AWS hacia vos*: es la evidencia de AWS de que cumplió su mitad. Un **Agreement** (BAA de HIPAA) fluye *de vos hacia AWS*: es un contrato que aceptás y que cambia tus obligaciones y habilita cargas de trabajo reguladas. Los reports se descargan; los agreements se aceptan.

**R2.4** — No. El AOC cubre únicamente la infraestructura de AWS. El cliente **hereda** los controles físicos, ambientales y de infraestructura y **no** necesita volver a auditarlos — ese es el valor de los controles heredados, y realmente reduce el alcance de la auditoría. Pero el cliente igual debe implementar y evidenciar todo lo que está por encima de la línea: segmentación de red, gestión de claves, cifrado de datos de titulares de tarjeta, control de acceso, registro y gestión de vulnerabilidades. El cumplimiento se hereda *en parte*, nunca *en su totalidad*.

**R2.5** — Impone que el cliente acepte explícitamente los términos de confidencialidad (NDA) antes de recibir la evidencia de auditoría de AWS. Proteger ese documento una vez que lo tenés — no redistribuirlo, almacenarlo de forma adecuada — es una responsabilidad del cliente que empieza en el momento en que se canjea el token.

---

### Bloque 3

**R3.1** — La complejidad, rotación y reutilización de contraseñas son decisiones de política impulsadas por el régimen regulatorio propio del cliente, su apetito de riesgo y su plantilla. Un valor por defecto impuesto por AWS sería incorrecto para muchos clientes y generaría una falsa sensación de seguridad en el resto. De forma coherente con el modelo, AWS provee la *capacidad* (`update-account-password-policy`) con total fidelidad y deja la *política* a la parte que conoce los requisitos. Notá que AWS sí impone un mínimo no negociable sobre las contraseñas de root y de IAM — el piso es de AWS, la política es tuya.

**R3.2** — Del cliente, en ambas mitades de la pregunta. El ciclo de vida de las credenciales — creación, rotación, alcance, revocación — es un control específico del cliente; AWS provee IAM Access Analyzer, informes de credenciales y marcas de último uso para hacerlo manejable. Si la filtración fuera causada por un **defecto en un servicio de AWS** (por ejemplo, un servicio que registra el material de tu clave en texto plano), eso sería una falla de la seguridad *de* la nube y responsabilidad de AWS — pero una clave subida a Git por una persona desarrolladora no es eso.

**R3.3** — EBS es un servicio regional y el indicador de cifrado por defecto es una propiedad del servicio EC2 en una única región. Es una trampa operativa común y seria: un equipo lo habilita en `us-east-1`, un grupo de escalado automático o un pipeline de DR crea volúmenes en `eu-west-1`, y esos quedan sin cifrar. La mitigación también es un control del cliente — aplicalo con una SCP o una regla de AWS Config en todas las regiones, en lugar de confiar en un interruptor por región.

**R3.4** — (a) **AWS** — la implementación criptográfica y su corrección son de AWS, validadas bajo FIPS 140-3 para los HSM de KMS. (b) **Cliente** — habilitar el cifrado en un volumen es una decisión del cliente. (c) **AWS** — la durabilidad y la protección física del material de clave de KMS en la flota de HSM se heredan. (d) **Cliente** — quién puede hacer `Decrypt` con la clave lo escribís vos en la política de clave.

---

### Bloque 4

**R4.1** — (a) **Responsabilidad de AWS servirlos, y AWS la cumplió correctamente** — S3 ejecutó una instrucción del cliente explícita, autenticada y autorizada. Servir esos objetos *era* el comportamiento correcto. (b) **Enteramente del cliente.** La exposición se originó en dos llamadas a la API deliberadas del cliente. La formulación del examen para esto es: *la mala configuración de un recurso controlado por el cliente nunca es responsabilidad de AWS.*

**R4.2** — SSE-S3 protege los datos **en reposo sobre los medios de almacenamiento de AWS**: defiende contra el compromiso físico de los medios y contra un atacante que lea los discos subyacentes. S3 lo aplica y lo quita de forma transparente para cualquier solicitante que pase la autorización. Una política de bucket pública otorga esa autorización a `Principal: "*"`, así que S3 descifra y sirve alegremente. El cifrado en reposo es ortogonal al control de acceso — confundirlos es un distractor clásico del examen.

**R4.3** —
- **Controles heredados** — controlados y operados íntegramente por AWS; el cliente recibe el beneficio sin configuración ni obligación. → *destrucción física de medios, redundancia eléctrica del centro de datos, seguridad de zona.*
- **Controles compartidos** — el control aplica tanto a la capa de infraestructura como a la capa del cliente, y cada lado ejecuta su propia instancia de él. → *gestión de parches, gestión de configuración, concientización y capacitación.*
- **Controles específicos del cliente** — no tienen contraparte en AWS; existen solo por lo que el cliente construyó. → *aprovisionamiento de usuarios de IAM* (y, por ejemplo, protección de servicios y comunicaciones, seguridad de zona dentro de la propia aplicación del cliente).

*Nota:* "concientización y capacitación" es compartido porque AWS capacita a sus empleados y vos tenés que capacitar a los tuyos; "seguridad de zona" aparece en ambos lados de la tabla publicada por AWS por la misma razón.

**R4.4** — Reduce el riesgo porque las ACL son un mecanismo heredado, por objeto y fácil de malinterpretar, y eliminarlas quita toda una clase de exposición accidental. No reduce la responsabilidad porque el cliente puede volver a habilitar las ACL con una sola llamada a la API (`put-bucket-ownership-controls`), y porque las políticas de bucket — un vector de exposición mucho más potente — siguen enteramente bajo control del cliente. **Un valor por defecto más seguro angosta los modos de falla; no mueve la línea.**

---

### Bloque 5

**R5.1** —
| Servicio | SO huésped parcheado por |
|---|---|
| EC2 | **Cliente** (AWS provee AMIs parcheadas y el herramental de SSM Patch Manager) |
| RDS | **AWS** (el cliente programa/aprueba el mantenimiento y es dueño de la elección de versión del motor) |
| Lambda | **AWS** (el cliente es dueño del código de la función, las dependencias y la migración fuera de runtimes obsoletos) |
| Fargate | **AWS** (el cliente es dueño del contenido de la imagen del contenedor, incluidos sus paquetes de SO) |
| S3 | **AWS** — no hay SO huésped; el concepto no existe para el cliente |

**R5.2** — Del **cliente**. "Gestionado" significa que AWS realiza la mecánica de la actualización, no que AWS decida cuándo tu base de datos de producción cambia de versión mayor — hacerlo unilateralmente rompería aplicaciones. AWS cumple su mitad publicando el ciclo de vida de las versiones, marcando versiones como `deprecated`, enviando avisos de obsolescencia por correo y, con el tiempo, forzando la actualización en una fecha límite publicada. Ignorar una obsolescencia publicada es una decisión de riesgo del cliente.

**R5.3** — No. AWS parchea el runtime gestionado — el intérprete de Python, los paquetes de SO del entorno de ejecución, el microVM. Cualquier cosa que vos envíes dentro de tu paquete de despliegue o de una layer es **tu código** en lo que respecta al modelo. Por eso el escaneo de dependencias (Amazon Inspector para Lambda, o tu propio SCA en CI) es un control del cliente.

**R5.4** — Porque el *mismo control nominal* debe implementarse de forma independiente en dos capas a las que ninguna de las partes puede llegar. AWS parchea el hipervisor, el firmware del host, el SO del host, los dispositivos de red y el sustrato de los servicios gestionados — de forma invisible, según su propio cronograma. El cliente parchea los SO huéspedes, las imágenes de contenedor, los runtimes de aplicación y las bibliotecas. Ninguno puede hacer la mitad del otro, y una falla en cualquiera de las dos capas compromete la carga de trabajo. Esa estructura de dos capas es exactamente lo que significa "control compartido" — no es "nos repartimos el trabajo de una misma tarea".

**R5.5** — Muestra que la mitad de AWS en un control compartido se cumple **entregando capacidad completa y lista para usar** — catálogos de parches, metadatos de severidad, líneas base curadas, un agente, un orquestador — y deteniéndose después en el punto donde una acción afectaría cargas de trabajo del cliente. AWS construye la máquina; apretar el botón es un acto del cliente con un radio de impacto del cliente.

---

### Bloque 6

**R6.1** —

| Control | EC2 | RDS | Lambda | S3 |
|---|---|---|---|---|
| Seguridad física de la instalación | A | A | A | A |
| Parcheo del hipervisor / microVM | A | A | A | A |
| Parcheo del SO huésped | **C** | A | A | A |
| Actualización de versión menor del motor de BD | — | **S** | — | — |
| Código de aplicación / dependencias | C | C | **C** | C¹ |
| ACL de red y grupos de seguridad | C | C | C² | C³ |
| Cifrado en reposo — disponibilidad de la función | A | A | A | A |
| Cifrado en reposo — decisión de habilitarlo | C | C | C⁴ | C⁴ |
| Cifrado en tránsito — aplicación efectiva | C | C | C | C |
| Identidades y políticas de IAM | C | C | C | C |
| Clasificación de datos | C | C | C | C |
| Existencia de copias de seguridad | C | **S** | C⁵ | C |
| Pruebas de restauración de copias de seguridad | C | C | C | C |

¹ la aplicación que escribe en S3. ² configuración de VPC si la función está adjunta a una VPC; de lo contrario, política de IAM/de recurso. ³ política de bucket, política de endpoint de VPC, Access Points. ⁴ SSE-S3 / el cifrado de variables de entorno de Lambda están activados por defecto, pero elegir SSE-KMS con una clave gestionada por el cliente y su política es cosa tuya. ⁵ AWS retiene las versiones de la función; tu fuente de verdad es tu repositorio.

**R6.2** — **Clasificación de datos** e **Identidades y políticas de IAM** (las pruebas de restauración de copias de seguridad también son `C` en todas las columnas). El principio: *el cliente siempre es dueño de sus datos y siempre es dueño de quién puede alcanzarlos, en cada nivel de abstracción, por más gestionado que sea el servicio.* Este es el invariante al que recurrir para cualquier escenario no visto.

**R6.3** — No — esta es la trampa. RDS provee la *capacidad* de copias de seguridad automáticas y habilita un período de retención por defecto, pero la retención es un parámetro configurado por el cliente con `0` como valor legítimo que significa "deshabilitado". Elegir `0` es una decisión explícita del cliente de aceptar el riesgo, exactamente igual que deshabilitar Block Public Access en el Ejercicio 4. AWS operó el servicio correctamente al respetar la configuración.

**R6.4** — "Fargate elimina nuestra responsabilidad de parchear el SO del host y el runtime de contenedores — eso genuinamente pasó a AWS. No elimina nada respecto del contenido de nuestra imagen de contenedor, nuestros roles de tarea de IAM, nuestros grupos de seguridad, nuestro manejo de secretos o nuestros datos — y ahí es donde ocurren realmente las brechas."

---

### Bloque 7

**R7.1** — El historial de eventos de administración de CloudTrail es parte de que AWS provea una **plataforma responsable y atribuible**: AWS registra lo que se le hizo a *su* plano de control, en cada cuenta, de forma incondicional y gratuita. GuardDuty analiza el *contenido y el comportamiento* de las cargas de trabajo del cliente — inspeccionando tus consultas DNS, logs de flujo de VPC y patrones de API. AWS no va a realizar ese análisis sin consentimiento, porque es inspección de datos del cliente. La línea es: *AWS siempre registra su propio plano de control; AWS nunca inspecciona tu carga de trabajo sin invitación.*

**R7.2** — (1) **Retención** — el Event history guarda 90 días; un trail que entrega a S3 guarda datos indefinidamente. (2) **Alcance** — el Event history cubre solo eventos de administración, por región; un trail puede capturar **eventos de datos** (a nivel de objeto en S3, invocaciones de Lambda) y agregar multirregión y a nivel de organización. (3) **Integridad y uso posterior** — solo un trail brinda validación de integridad de los archivos de log (archivos digest), entrega a S3/CloudWatch Logs, cifrado SSE-KMS y entrada legible por máquina para Security Hub, Athena o un SIEM.

**R7.3** — AWS **no estaba obligada a notarlo**: detectar patrones de acceso anómalos en tu cuenta es precisamente lo que hace GuardDuty, y vos no lo habilitaste. AWS **sí estaba obligada a registrarlo** — cada `GetObject` es un evento de datos, lo que significa que se captura solo si configuraste un trail con eventos de datos de S3; la actividad de API de *administración* de esas credenciales sí aparecería en el Event history. La conclusión incómoda y relevante para el examen: con la configuración por defecto, las lecturas a nivel de objeto pueden no ser recuperables en absoluto, y esa brecha es del cliente.

**R7.4** — Porque la postura contractual y de privacidad de AWS — declarada en el Customer Agreement y en las preguntas frecuentes sobre privacidad de datos — es que no accede al contenido del cliente salvo lo necesario para prestar el servicio o para cumplir con la ley. La inspección automática de contenido violaría ese compromiso y sería inaceptable para clientes regulados. La detección opt-in (GuardDuty, Macie, Inspector) es el modelo funcionando correctamente: la capacidad se ofrece, el consentimiento se requiere, y la responsabilidad de consentir es tuya.

---

### Bloque 8

**R8.1** — El **cliente** es dueño de su contenido y controla dónde se almacena, cómo se protege y quién puede acceder a él. AWS actúa como procesador de ese contenido siguiendo las instrucciones del cliente. La implicancia para la eliminación es contundente: un borrado emitido por un principal autorizado del cliente es una instrucción que AWS ejecuta, y AWS no mantiene ninguna copia oculta desde la cual restaurar. La protección contra la eliminación accidental o maliciosa — versionado, MFA Delete, Object Lock, AWS Backup, copias entre cuentas/entre regiones, `DeletionProtection` — es un conjunto de controles del cliente que deben habilitarse *antes* del incidente.

**R8.2** — El escaneo de puertos y la simulación de credential stuffing contra tus propias instancias EC2 caen dentro de la lista de **servicios permitidos** y **no requieren aprobación previa**, siempre que se mantengan dentro de tus propios recursos y dentro de los límites de la política. Cualquier **simulación de denegación de servicio o DDoS, incluida una prueba volumétrica contra tu propio ALB, está prohibida sin autorización previa explícita** a través del proceso de eventos simulados de AWS — porque el tráfico atraviesa infraestructura compartida de AWS y afecta a otros inquilinos. La regla rectora: *la política protege el sustrato compartido, no solamente a vos.*

**R8.3** — La **AWS Acceptable Use Policy**, incorporada al AWS Customer Agreement. La infracción está enteramente del lado del **cliente**: sos responsable de lo que corre en tu cuenta, incluido lo que ejecute una persona desarrolladora comprometida o descuidada. La acción de aplicación de AWS es un remedio contractual, no una falla de seguridad de parte de AWS — y notá que la falla habilitante subyacente (IAM demasiado permisivo, ningún hallazgo de CryptoCurrency de GuardDuty habilitado) también es del lado del cliente.

**R8.4** — La durabilidad responde a "¿va a perder AWS tu objeto?" — la cifra de 11 nueves describe la resistencia a **fallas de hardware e instalaciones**, y es un control heredado. `aws s3 rm` no es una falla; es una **instrucción autenticada y autorizada** que S3 ejecuta fielmente en todas sus réplicas a la vez. Una durabilidad alta hace que la eliminación de tus datos por parte de AWS sea esencialmente imposible, mientras que hace que *tu* eliminación de tus datos sea instantánea y permanente. Protegerse contra lo segundo es un control del cliente (versionado + MFA Delete, u Object Lock en modo compliance).

---

### Bloque 9

**R9.1** —

| # | Responsable | Control que falló | Prevención / detección |
|---|---|---|---|
| **A** | **Cliente** | S3 Block Public Access deshabilitado y política de bucket pública aplicada por un rol de CI con permisos excesivos; ninguna revisión de CloudTrail durante 40 días | BPA a nivel de cuenta (`s3control put-public-access-block`); SCP que deniegue `s3:PutBucketPolicy` con principals públicos; rol de CI con mínimo privilegio; IAM Access Analyzer; regla de AWS Config `s3-bucket-public-read-prohibited`; GuardDuty `Policy:S3/BucketAnonymousAccessGranted` |
| **B** | **Cliente** | Parcheo del SO huésped — la AMI estaba vigente al lanzarla y derivó durante 14 meses; SSM estaba disponible pero no existía ningún cronograma de parcheo | SSM Patch Manager con una ventana de mantenimiento y la línea base provista por AWS; pipeline inmutable de re-horneado de AMI dorada; Amazon Inspector para detección de CVE |
| **C** | **AWS** | Nada del lado del cliente; AWS remedió su propia capa | Ninguna requerida — este es un **control heredado** funcionando según diseño |
| **D** | **Cliente** | Protección contra eliminación desactivada, snapshot final omitido, y ninguna copia de seguridad fuera del ciclo de vida de la instancia | `DeletionProtection=true`; `SkipFinalSnapshot=false`; bóveda de AWS Backup (ciclo de vida independiente, cuenta separada) con Vault Lock; IAM/SCP restringiendo `rds:DeleteDBInstance` |
| **E** | **Cliente** | Código de aplicación (clasificación y manejo de datos) más la configuración de logs; ambos por encima de la línea en todos los niveles de abstracción | Revisión de código / SAST; política de retención de CloudWatch Logs y SSE-KMS con una CMK; Amazon Macie o una capa de depuración de logs; control del alcance de PCI-DSS |
| **F** | **Ambos — ver R9.3** | Arquitectura de una sola AZ elegida por el cliente | Despliegue Multi-AZ; la segunda instancia del escenario es la prueba de que funciona |

**R9.2** — **Escenario C.** Tres señales: la falla está en una capa sin ninguna API para el cliente (el hipervisor), la remediación ocurrió sin acción del cliente, y la declaración pública de AWS es el mecanismo de evidencia en el que se apoya el modelo para la seguridad *de* la nube. Notá la ausencia de reinicios — eso es la actualización en vivo de Nitro, enteramente dentro de la mitad de AWS.

**R9.3** — **La mitad de AWS:** la AZ se quedó sin energía, y AWS es responsable de la alimentación eléctrica, la refrigeración y la resiliencia física del centro de datos; AWS también cumplió con su compromiso de Multi-AZ al conmutar la segunda instancia en 90 segundos sin intervención del cliente. **La mitad del cliente:** AWS publica un SLA y un diseño de disponibilidad en el que *una sola AZ puede fallar*, y provee Multi-AZ como mitigación. Elegir una sola AZ para una carga de trabajo que no tolera 4 horas de caída es una decisión de arquitectura del cliente. AWS es responsable de la **resiliencia de la infraestructura**; el cliente es responsable de la **resiliencia de la arquitectura construida sobre ella**.

**R9.4** — *Si la falla está en algo que podrías haber configurado, desplegado, cifrado, parcheado, permisionado, eliminado o arquitecturado de otra manera a través de una API de AWS, es tuya; si está en la instalación física, el hipervisor, el tejido de red o el sustrato de servicios gestionados al que no podés llegar, es de AWS — y tus datos y quién puede acceder a ellos son tuyos en absolutamente todos los casos.*

</details>

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- What is AWS Artifact — <https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html>
- Blocking public access to your Amazon S3 storage — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html>
- Controlling ownership of objects and disabling ACLs — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html>
- Setting default server-side encryption behavior for S3 buckets — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html>
- Using versioning in S3 buckets — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html>
- AWS Systems Manager Patch Manager — <https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager.html>
- Amazon EBS encryption (encryption by default) — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption.html>
- Amazon RDS maintenance and engine version lifecycle — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.Maintenance.html>
- AWS Lambda runtimes and runtime deprecation — <https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html>
- Getting credential reports for your AWS account — <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html>
- Working with CloudTrail Event history — <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/view-cloudtrail-events.html>
- Amazon GuardDuty — <https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html>
- AWS Customer Agreement — <https://aws.amazon.com/agreement/>
- AWS Acceptable Use Policy — <https://aws.amazon.com/aup/>
- AWS Customer Support Policy for Penetration Testing — <https://aws.amazon.com/security/penetration-testing/>
- AWS Data Privacy FAQ — <https://aws.amazon.com/compliance/data-privacy-faq/>