# Tema 2.2 — Ejercicios guiados
## Comprender los conceptos de seguridad, gobernanza y cumplimiento de AWS Cloud
**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 2: Seguridad y cumplimiento** · **Enunciado de tarea 2.2** · **Peso del dominio: 30 % (este enunciado de tarea ≈ 7,5 %)**

---

## Cómo usar este material

Cada ejercicio es un bloque de pasos numerados que ejecutás vos mismo, seguido de preguntas de verificación. No leas las respuestas hasta haber corrido el bloque y mirado la salida real — el examen evalúa si sabés **qué servicio produce qué evidencia**, y esa distinción solo se vuelve obvia cuando viste el JSON.

### Requisitos previos

| Requisito | Comprobación |
|---|---|
| Cuenta de AWS que tengas permiso de modificar (sandbox, **no** producción) | — |
| Principal de IAM con permisos administrativos | `aws sts get-caller-identity` |
| AWS CLI v2 (≥ 2.15) | `aws --version` |
| `jq`, `openssl`, `base64` | `jq --version` |
| Una cuenta de gestión de AWS Organizations **solo para el Ejercicio 2, Bloque C** (opcional) | `aws organizations describe-organization` |

### Aviso de costo y seguridad

La mayor parte de este material corre dentro de la Capa Gratuita de AWS o cuesta centavos. Tres servicios **no** son gratuitos y están marcados explícitamente:

- **AWS Config** — se cobra por elemento de configuración registrado y por evaluación de regla.
- **AWS Security Hub** — se cobra por hallazgo ingerido y por comprobación de cumplimiento.
- **Amazon GuardDuty / Inspector / Macie** — gratis los primeros 30 días por cuenta, después se factura.

El Ejercicio 9 desmonta todo. **Ejecutalo.** Dejar un grabador de Config corriendo en una cuenta olvidada es la forma más común de que un laboratorio produzca una factura sorpresa.

A lo largo del texto, `111122223333` es el ID de cuenta de marcador de posición y `eu-west-1` la Región de marcador de posición. Sustituilos por los tuyos.

---

## Ejercicio 0 — Establecer la línea base de identidad y Región

Cada control de gobernanza que vas a construir se evalúa contra **quién** hizo la llamada y **dónde** se hizo. Fijá ambos antes de tocar cualquier otra cosa.

### Pasos

1. Confirmá la versión de la CLI. Varios comandos de abajo (`aws artifact`, `aws account list-regions`) no existen en la CLI v1.

   ```bash
   aws --version
   ```

   ```
   aws-cli/2.19.4 Python/3.12.6 Linux/6.11.0 exe/x86_64.fedora.41
   ```

2. Resolvé la identidad que llama. Este es el principal al que se atribuirá cada evento de CloudTrail en este laboratorio.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDASAMPLEUSERID123456",
       "Account": "111122223333",
       "Arn": "arn:aws:iam::111122223333:user/lab-admin"
   }
   ```

3. Exportá los valores que vas a reutilizar. El `LAB_SUFFIX` mantiene los nombres de bucket de S3 globalmente únicos.

   ```bash
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export AWS_REGION=eu-west-1
   export LAB_SUFFIX="${AWS_ACCOUNT_ID}-clf22"
   export EVIDENCE_BUCKET="clf-lab-evidence-${LAB_SUFFIX}"
   export TRAIL_BUCKET="clf-lab-trail-${LAB_SUFFIX}"
   echo "$AWS_ACCOUNT_ID / $AWS_REGION / $EVIDENCE_BUCKET"
   ```

   ```
   111122223333 / eu-west-1 / clf-lab-evidence-111122223333-clf22
   ```

4. Listá las Regiones que esta cuenta puede usar actualmente. Fijate en los dos estados de opt-in distintos.

   ```bash
   aws account list-regions \
     --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
     --query 'Regions[].[RegionName,RegionOptStatus]' \
     --output table
   ```

   ```
   -------------------------------------------
   |               ListRegions               |
   +------------------+----------------------+
   |  eu-central-1    |  ENABLED_BY_DEFAULT  |
   |  eu-north-1      |  ENABLED_BY_DEFAULT  |
   |  eu-west-1       |  ENABLED_BY_DEFAULT  |
   |  eu-west-2       |  ENABLED_BY_DEFAULT  |
   |  eu-west-3       |  ENABLED_BY_DEFAULT  |
   |  sa-east-1       |  ENABLED_BY_DEFAULT  |
   |  us-east-1       |  ENABLED_BY_DEFAULT  |
   |  us-east-2       |  ENABLED_BY_DEFAULT  |
   |  us-west-1       |  ENABLED_BY_DEFAULT  |
   |  us-west-2       |  ENABLED_BY_DEFAULT  |
   +------------------+----------------------+
   ```

5. Ahora listá las Regiones que existen pero **no** están habilitadas.

   ```bash
   aws account list-regions \
     --region-opt-status-contains DISABLED \
     --query 'Regions[].RegionName' --output text
   ```

   ```
   af-south-1  ap-east-1  ap-south-2  ap-southeast-3  ap-southeast-4  ca-west-1
   eu-central-2  eu-south-1  eu-south-2  il-central-1  me-central-1  me-south-1
   ```

### Preguntas de verificación — Bloque 0

- **Q0.1** — Dos Regiones de tu cuenta reportan `ENABLED_BY_DEFAULT` y una docena reportan `DISABLED`. ¿Cuál es el significado de seguridad de que una Región opt-in esté deshabilitada, y por qué se considera un control de *gobernanza* y no un mero ajuste de disponibilidad?
- **Q0.2** — El `Arn` que devuelve `get-caller-identity` es un usuario de IAM. Bajo el modelo de responsabilidad compartida de AWS, ¿quién es responsable de rotar la clave de acceso de ese usuario, y quién es responsable de parchear el servicio STS que respondió la llamada?
- **Q0.3** — Ejecutaste `aws account list-regions` sin especificar `--region`. ¿A qué Región fue realmente la solicitud, y por qué importa eso cuando después escribís una política que restringe Regiones?

---

## Ejercicio 1 — Obtener evidencia de cumplimiento con AWS Artifact

**AWS Artifact es la respuesta a "¿de dónde saco los informes de auditoría de AWS?"** — SOC 1/2/3, ISO 27001, AOC de PCI DSS, paquetes de FedRAMP, y los acuerdos (BAA, DPA de GDPR) que aceptás en nombre de tu organización. Es un *portal de autoservicio para las propias atestaciones de terceros de AWS*. No te dice nada sobre el cumplimiento de tu carga de trabajo; te dice sobre el cumplimiento de la infraestructura que está debajo.

### Pasos

1. Listá los informes disponibles para tu cuenta. Esta es una API **de solo lectura y sin costo**.

   ```bash
   aws artifact list-reports --max-results 10 \
     --query 'reports[].[name,series,state,periodStart,periodEnd]' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------------------------------
   |                                              ListReports                                               |
   +-------------------------------------+---------+------------+---------------------+---------------------+
   |  AWS SOC 2 Type II Report           |  SOC    | PUBLISHED  | 2025-04-01T00:00:00Z| 2026-03-31T00:00:00Z|
   |  AWS SOC 3 Report                   |  SOC    | PUBLISHED  | 2025-04-01T00:00:00Z| 2026-03-31T00:00:00Z|
   |  ISO 27001:2022 Certification       |  ISO    | PUBLISHED  | 2025-01-01T00:00:00Z| 2027-12-31T00:00:00Z|
   |  PCI DSS v4.0 Attestation of Compl. |  PCI    | PUBLISHED  | 2025-10-01T00:00:00Z| 2026-09-30T00:00:00Z|
   |  AWS CSA STAR Level 2 Certification |  CSA    | PUBLISHED  | 2025-06-15T00:00:00Z| 2026-06-14T00:00:00Z|
   +-------------------------------------+---------+------------+---------------------+---------------------+
   ```

2. Capturá el identificador de uno de los informes para poder descargarlo.

   ```bash
   export REPORT_ID=$(aws artifact list-reports \
     --query "reports[?series=='SOC'] | [0].id" --output text)
   export REPORT_VERSION=$(aws artifact list-reports \
     --query "reports[?series=='SOC'] | [0].version" --output text)
   echo "$REPORT_ID v$REPORT_VERSION"
   ```

   ```
   report-bqRoZ7QhTVaXXXXX v3
   ```

3. Inspeccioná los metadatos **antes** de descargar. Fijate en `acceptanceType` — este es el campo que te dice que el informe está bajo NDA.

   ```bash
   aws artifact get-report-metadata \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION"
   ```

   ```json
   {
       "reportDetails": {
           "id": "report-bqRoZ7QhTVaXXXXX",
           "name": "AWS SOC 2 Type II Report",
           "description": "Report on the AWS System and the Suitability of the Design and Operating Effectiveness of Controls",
           "periodStart": "2025-04-01T00:00:00+00:00",
           "periodEnd": "2026-03-31T00:00:00+00:00",
           "createdAt": "2026-05-15T14:02:11+00:00",
           "series": "SOC",
           "category": "Certifications And Attestations",
           "companyName": "Amazon Web Services, Inc.",
           "productName": "AWS",
           "termArn": "arn:aws:artifact:::term/term-4wRoZ7QhTVaXXXXX",
           "version": 3,
           "acceptanceType": "EXPLICIT",
           "state": "PUBLISHED",
           "arn": "arn:aws:artifact:::report/report-bqRoZ7QhTVaXXXXX"
       }
   }
   ```

4. Como `acceptanceType` es `EXPLICIT`, primero tenés que obtener y aceptar el término del NDA. Esto devuelve un **token de término**, que es la prueba legible por máquina de la aceptación.

   ```bash
   aws artifact get-term-for-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --query 'termToken' --output text
   ```

   ```
   eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.SAMPLE-TERM-TOKEN-VALUE.4nQxYw
   ```

5. Canjeá el token de término por una URL de descarga prefirmada. La URL es de vida corta.

   ```bash
   export TERM_TOKEN=$(aws artifact get-term-for-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --query 'termToken' --output text)

   aws artifact get-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --term-token "$TERM_TOKEN" \
     --query 'documentPresignedUrl' --output text | cut -c1-90
   ```

   ```
   https://artifact-reports-prod-eu-west-1.s3.eu-west-1.amazonaws.com/report-bqRoZ7QhT
   ```

6. Confirmá que la CLI **no** te va a entregar el documento sin el token de término — este es el punto de aplicación del NDA.

   ```bash
   aws artifact get-report \
     --report-id "$REPORT_ID" --report-version "$REPORT_VERSION" \
     --term-token "invalid-token"
   ```

   ```
   An error occurred (ValidationException) when calling the GetReport operation:
   The provided term token is not valid for this report version.
   ```

### Preguntas de verificación — Bloque 1

- **Q1.1** — Tu auditor pide evidencia de que el cifrado del bucket de S3 que contiene registros de clientes se aplicó de forma continua durante los últimos 12 meses. ¿Puede AWS Artifact aportar eso? Si no, ¿qué servicio de AWS sí puede, y por qué la distinción es una frontera de responsabilidad compartida?
- **Q1.2** — El informe SOC 2 Type II tiene `acceptanceType: EXPLICIT` mientras que el informe SOC 3 no. ¿Cuál es la diferencia práctica entre esos dos documentos, y cuál podés publicar en el sitio web de tu empresa?
- **Q1.3** — Un colega propone programar una descarga nocturna de todos los informes de Artifact hacia un bucket de S3 público "para que el equipo siempre los tenga". Identificá la violación de cumplimiento.
- **Q1.4** — Además de informes, AWS Artifact aloja *acuerdos*. Nombrá el acuerdo que necesitarías aceptar antes de procesar datos sanitarios de EE. UU. en AWS, e indicá si aceptarlo hace que tu carga de trabajo cumpla con HIPAA.

---

## Ejercicio 2 — Residencia de datos, alcance de Región y transferencia entre Regiones

El examen sondea repetidamente un hecho: **AWS nunca saca tus datos de la Región donde los pusiste, salvo que vos lo configures.** Este bloque lo demuestra empíricamente, y después construye la barrera de protección que lo mantiene cierto.

### Bloque A — Demostrar que el almacenamiento está acotado a la Región

1. Creá un bucket en la Región que elegiste y cerralo de inmediato.

   ```bash
   aws s3api create-bucket \
     --bucket "$EVIDENCE_BUCKET" \
     --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION"
   ```

   ```json
   {
       "Location": "http://clf-lab-evidence-111122223333-clf22.s3.amazonaws.com/"
   }
   ```

   ```bash
   aws s3api put-public-access-block \
     --bucket "$EVIDENCE_BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
   ```

2. Preguntale a AWS dónde viven físicamente los datos.

   ```bash
   aws s3api get-bucket-location --bucket "$EVIDENCE_BUCKET"
   ```

   ```json
   {
       "LocationConstraint": "eu-west-1"
   }
   ```

3. Preguntá si hay algo configurado para copiar esos datos a otro lado. El **error es la evidencia**.

   ```bash
   aws s3api get-bucket-replication --bucket "$EVIDENCE_BUCKET"
   ```

   ```
   An error occurred (ReplicationConfigurationNotFoundError) when calling the
   GetBucketReplication operation: The replication configuration was not found
   ```

4. Confirmá que el bucket es invisible desde el endpoint de otra Región solo en el sentido de *direccionamiento*, no de almacenamiento — los datos en sí nunca salieron de `eu-west-1`.

   ```bash
   aws s3api head-bucket --bucket "$EVIDENCE_BUCKET" --region us-east-1 ; echo "exit=$?"
   ```

   ```
   exit=0
   ```

   (La solicitud se redirige a la Región de origen del bucket. El plano de control es medio global; el **plano de datos no lo es**.)

### Preguntas de verificación — Bloque 2A

- **Q2.1** — El paso 4 tuvo éxito al direccionarse a través de `us-east-1`. Explicá, con precisión, por qué esto **no** significa que los datos del objeto se transfirieron a Estados Unidos.
- **Q2.2** — ¿Qué única funcionalidad de AWS S3 haría que bytes de este bucket se escribieran en otra Región, y qué implica el hecho de que deba configurarse explícitamente para una evaluación de residencia de datos bajo GDPR?
- **Q2.3** — Falla una zona de disponibilidad en `eu-west-1`. ¿Pierde S3 tu objeto? ¿Qué mecanismo de durabilidad responde esto, y es responsabilidad del cliente o de AWS?

### Bloque B — Construir la barrera de residencia de datos (redacción de política, sin necesidad de Organizations)

Podés escribir y validar esta política sin una organización. Aplicarla es el Bloque C.

5. Escribí una Service Control Policy que deniegue toda llamada a API hecha fuera de una lista de Regiones aprobadas.

   ```bash
   cat > /tmp/scp-region-lock.json <<'JSON'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyAllOutsideApprovedRegions",
         "Effect": "Deny",
         "NotAction": [
           "a4b:*",
           "acm:*",
           "artifact:*",
           "aws-marketplace:*",
           "aws-portal:*",
           "budgets:*",
           "ce:*",
           "chime:*",
           "cloudfront:*",
           "config:*",
           "cur:*",
           "globalaccelerator:*",
           "health:*",
           "iam:*",
           "importexport:*",
           "kms:*",
           "organizations:*",
           "pricing:*",
           "route53:*",
           "route53domains:*",
           "s3:GetAccountPublicAccessBlock",
           "s3:ListAllMyBuckets",
           "s3:PutAccountPublicAccessBlock",
           "shield:*",
           "sts:*",
           "support:*",
           "trustedadvisor:*",
           "waf-regional:*",
           "waf:*",
           "wafv2:*"
         ],
         "Resource": "*",
         "Condition": {
           "StringNotEquals": {
             "aws:RequestedRegion": [
               "eu-west-1",
               "eu-central-1"
             ]
           },
           "ArnNotLike": {
             "aws:PrincipalARN": [
               "arn:aws:iam::*:role/OrgBreakGlassAdmin"
             ]
           }
         }
       }
     ]
   }
   JSON
   ```

6. Validá que el JSON esté sintácticamente bien formado antes de que AWS lo vea siquiera.

   ```bash
   jq -e 'type == "object" and .Version == "2012-10-17"' /tmp/scp-region-lock.json >/dev/null \
     && echo "policy document: valid JSON, correct policy language version"
   ```

   ```
   policy document: valid JSON, correct policy language version
   ```

7. Medí la política contra el límite de tamaño de una SCP (5120 bytes). Esta es una restricción operativa real — las SCP de bloqueo de Región crecen hasta que ya no entran.

   ```bash
   jq -c . /tmp/scp-region-lock.json | wc -c
   ```

   ```
   831
   ```

### Preguntas de verificación — Bloque 2B

- **Q2.4** — La declaración usa `NotAction` con una larga lista de servicios permitidos en lugar de `Action: "*"`. ¿Qué se rompe si sacás `iam:*` y `sts:*` de esa lista?
- **Q2.5** — `cloudfront`, `route53` e `iam` son servicios "globales". ¿En qué Región registra el plano de control de AWS sus llamadas a API, y qué significa eso para la clave de condición `aws:RequestedRegion`?
- **Q2.6** — Esta SCP tiene `"Effect": "Deny"`. Si una política de IAM adjunta a un usuario permite explícitamente `ec2:RunInstances` en `us-east-1`, ¿puede ese usuario lanzar la instancia? Indicá la regla de evaluación que aplicaste.
- **Q2.7** — ¿Esta SCP restringe acciones tomadas por la **cuenta de gestión** de la organización? ¿Cuál es la consecuencia operativa de esa respuesta?

### Bloque C — Aplicar la barrera *(opcional; requiere una cuenta de gestión de AWS Organizations en modo de todas las características)*

> **Advertencia:** una SCP de bloqueo de Región con alcance incorrecto puede dejar afuera a tus propios operadores de una cuenta. Probala en una OU de sandbox dedicada, nunca en la raíz.

8. Confirmá que estás en la cuenta de gestión y que las SCP están habilitadas.

   ```bash
   aws organizations describe-organization \
     --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
   ```

   ```
   o-a1b2c3d4e5  111122223333  ALL
   ```

   ```bash
   aws organizations list-roots \
     --query 'Roots[].PolicyTypes[?Type==`SERVICE_CONTROL_POLICY`].Status' --output text
   ```

   ```
   ENABLED
   ```

9. Creá la política.

   ```bash
   aws organizations create-policy \
     --name "clf-lab-region-lock" \
     --description "Data residency guardrail: EU Regions only" \
     --type SERVICE_CONTROL_POLICY \
     --content file:///tmp/scp-region-lock.json \
     --query 'Policy.PolicySummary.[Id,Name,Type]' --output text
   ```

   ```
   p-x9y8z7w6  clf-lab-region-lock  SERVICE_CONTROL_POLICY
   ```

10. Adjuntala **solo a una OU de sandbox**.

    ```bash
    export OU_ID=ou-a1b2-sandbox01     # replace with your sandbox OU
    aws organizations attach-policy --policy-id p-x9y8z7w6 --target-id "$OU_ID"
    ```

11. Desde una cuenta miembro dentro de esa OU, comprobá que la barrera se dispara.

    ```bash
    aws ec2 describe-vpcs --region us-east-1
    ```

    ```
    An error occurred (UnauthorizedOperation) when calling the DescribeVpcs operation:
    You are not authorized to perform this operation. User:
    arn:aws:iam::444455556666:user/dev-alice is not authorized to perform:
    ec2:DescribeVpcs with an explicit deny in a service control policy
    ```

### Preguntas de verificación — Bloque 2C

- **Q2.8** — La cadena de error contiene la frase `explicit deny in a service control policy`. ¿Por qué este detalle de diagnóstico es operativamente valioso, y a qué servicio consultarías para ver *quién más* viene chocando contra esta denegación?
- **Q2.9** — Las SCP se describen como "barreras de protección, no permisos". Reformulá eso como una afirmación técnica precisa sobre qué le hace una SCP a los permisos efectivos de un principal de IAM.

---

## Ejercicio 3 — Cifrado en reposo: cifrado de sobre con KMS y SSE-KMS en S3

La mecánica más evaluada de este enunciado de tarea. Vas a hacer cifrado de sobre **a mano** para que la abstracción deje de ser un diagrama.

### Bloque A — La clave de KMS y su política

1. Creá una clave administrada por el cliente (CMK). Notá que el material de clave nunca sale de KMS.

   ```bash
   aws kms create-key \
     --description "CLF-C02 lab CMK for S3 SSE-KMS" \
     --key-usage ENCRYPT_DECRYPT \
     --key-spec SYMMETRIC_DEFAULT \
     --origin AWS_KMS \
     --tags TagKey=Purpose,TagValue=clf-c02-lab
   ```

   ```json
   {
       "KeyMetadata": {
           "AWSAccountId": "111122223333",
           "KeyId": "1234abcd-12ab-34cd-56ef-1234567890ab",
           "Arn": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
           "CreationDate": "2026-09-03T10:14:22.881000+00:00",
           "Enabled": true,
           "Description": "CLF-C02 lab CMK for S3 SSE-KMS",
           "KeyUsage": "ENCRYPT_DECRYPT",
           "KeyState": "Enabled",
           "Origin": "AWS_KMS",
           "KeyManager": "CUSTOMER",
           "CustomerMasterKeySpec": "SYMMETRIC_DEFAULT",
           "KeySpec": "SYMMETRIC_DEFAULT",
           "EncryptionAlgorithms": [
               "SYMMETRIC_DEFAULT"
           ],
           "MultiRegion": false
       }
   }
   ```

2. Dale un alias usable por humanos y habilitá la rotación anual automática.

   ```bash
   export KEY_ID=1234abcd-12ab-34cd-56ef-1234567890ab
   aws kms create-alias --alias-name alias/clf-lab-s3 --target-key-id "$KEY_ID"
   aws kms enable-key-rotation --key-id "$KEY_ID" --rotation-period-in-days 365
   aws kms get-key-rotation-status --key-id "$KEY_ID"
   ```

   ```json
   {
       "KeyRotationEnabled": true,
       "KeyId": "1234abcd-12ab-34cd-56ef-1234567890ab",
       "NextRotationDate": "2027-09-03T10:14:22.881000+00:00",
       "RotationPeriodInDays": 365
   }
   ```

3. Leé la política de clave por defecto. Este es el objeto más importante de KMS y el que más comúnmente se malinterpreta.

   ```bash
   aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
     --output text --query Policy | jq .
   ```

   ```json
   {
     "Version": "2012-10-17",
     "Id": "key-default-1",
     "Statement": [
       {
         "Sid": "Enable IAM User Permissions",
         "Effect": "Allow",
         "Principal": {
           "AWS": "arn:aws:iam::111122223333:root"
         },
         "Action": "kms:*",
         "Resource": "*"
       }
     ]
   }
   ```

### Preguntas de verificación — Bloque 3A

- **Q3.1** — La política de clave por defecto concede `kms:*` a `arn:aws:iam::111122223333:root`. ¿Significa esto que solo el usuario raíz puede usar la clave? Explicá qué denota realmente ese principal en una política de clave de KMS.
- **Q3.2** — Compará una *clave administrada por el cliente* (`KeyManager: CUSTOMER`) con una *clave administrada por AWS* (`aws/s3`). Nombrá dos capacidades que ganás con la primera y un costo en el que incurrís.
- **Q3.3** — La rotación está habilitada con un período de 365 días. Después de que ocurra la rotación, ¿puede KMS todavía descifrar un objeto cifrado el mes pasado? ¿Qué retiene KMS para que eso sea cierto?

### Bloque B — Cifrado de sobre, hecho manualmente

4. Pedile a KMS una clave de datos. Obtenés **la misma clave dos veces**: una en texto plano, otra envuelta por la CMK.

   ```bash
   aws kms generate-data-key --key-id alias/clf-lab-s3 --key-spec AES_256 \
     > /tmp/datakey.json
   jq '{KeyId, PlaintextLen: (.Plaintext|length), CiphertextLen: (.CiphertextBlob|length)}' /tmp/datakey.json
   ```

   ```json
   {
     "KeyId": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
     "PlaintextLen": 44,
     "CiphertextLen": 240
   }
   ```

5. Usá la clave de datos en texto plano para cifrar un archivo local con AES-256 — este es el paso que KMS nunca hace por vos sobre datos masivos.

   ```bash
   echo "patient_id,diagnosis_code
   4471,E11.9
   4472,I10" > /tmp/records.csv

   jq -r .Plaintext /tmp/datakey.json | base64 -d > /tmp/dk.bin
   openssl enc -aes-256-cbc -pbkdf2 -in /tmp/records.csv -out /tmp/records.csv.enc \
     -pass file:/tmp/dk.bin
   ls -l /tmp/records.csv /tmp/records.csv.enc
   ```

   ```
   -rw-r--r--. 1 user user  46 Sep  3 10:22 /tmp/records.csv
   -rw-r--r--. 1 user user  64 Sep  3 10:22 /tmp/records.csv.enc
   ```

6. **Destruí la clave de datos en texto plano.** Guardá solo la copia envuelta. Este es el punto entero del patrón.

   ```bash
   shred -u /tmp/dk.bin
   jq -r .CiphertextBlob /tmp/datakey.json > /tmp/wrapped-dk.b64
   ls /tmp/dk.bin 2>&1
   ```

   ```
   ls: cannot access '/tmp/dk.bin': No such file or directory
   ```

7. Recuperá la clave de datos pidiéndole a KMS que la desenvuelva. Observá que **no** pasaste un ID de clave — la identidad de la CMK está embebida en el blob de texto cifrado.

   ```bash
   aws kms decrypt \
     --ciphertext-blob "fileb://<(base64 -d /tmp/wrapped-dk.b64)" \
     --query Plaintext --output text 2>/dev/null \
   || { base64 -d /tmp/wrapped-dk.b64 > /tmp/wrapped-dk.bin
        aws kms decrypt --ciphertext-blob fileb:///tmp/wrapped-dk.bin \
          --query '[KeyId,EncryptionAlgorithm]' --output text ; }
   ```

   ```
   arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab   SYMMETRIC_DEFAULT
   ```

8. Completá el viaje de ida y vuelta: desenvolvé, descifrá, compará.

   ```bash
   aws kms decrypt --ciphertext-blob fileb:///tmp/wrapped-dk.bin \
     --query Plaintext --output text | base64 -d > /tmp/dk.bin
   openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/records.csv.enc \
     -pass file:/tmp/dk.bin | diff - /tmp/records.csv && echo "ROUND TRIP OK"
   shred -u /tmp/dk.bin
   ```

   ```
   ROUND TRIP OK
   ```

### Preguntas de verificación — Bloque 3B

- **Q3.4** — Cifraste un archivo de 46 bytes. Supongamos que hubiera sido de 400 GB. ¿Cuántos bytes habrían cruzado la red hacia la API de KMS, y por qué es ese el argumento arquitectónico del cifrado de sobre?
- **Q3.5** — En el paso 7 llamaste a `kms:Decrypt` sin nombrar una clave. ¿Qué implica esto sobre la estructura de un blob de texto cifrado de KMS, y qué propiedad de seguridad te da al auditar qué clave protegió qué objeto?
- **Q3.6** — Si un atacante roba `/tmp/records.csv.enc` **y** `/tmp/wrapped-dk.b64` de tu laptop, ¿qué necesita todavía para leer los datos? ¿Qué control de AWS decide si lo consigue?

### Bloque C — Dejá que S3 lo haga por vos (SSE-KMS + S3 Bucket Keys)

9. Adjuntá la CMK como cifrado por defecto del bucket, y habilitá S3 Bucket Keys.

   ```bash
   aws s3api put-bucket-encryption \
     --bucket "$EVIDENCE_BUCKET" \
     --server-side-encryption-configuration "$(cat <<JSON
   {
     "Rules": [
       {
         "ApplyServerSideEncryptionByDefault": {
           "SSEAlgorithm": "aws:kms",
           "KMSMasterKeyID": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:alias/clf-lab-s3"
         },
         "BucketKeyEnabled": true
       }
     ]
   }
   JSON
   )"
   ```

10. Leé de vuelta la configuración.

    ```bash
    aws s3api get-bucket-encryption --bucket "$EVIDENCE_BUCKET" | jq .
    ```

    ```json
    {
      "ServerSideEncryptionConfiguration": {
        "Rules": [
          {
            "ApplyServerSideEncryptionByDefault": {
              "SSEAlgorithm": "aws:kms",
              "KMSMasterKeyID": "arn:aws:kms:eu-west-1:111122223333:alias/clf-lab-s3"
            },
            "BucketKeyEnabled": true
          }
        ]
      }
    }
    ```

11. Subí el archivo en **texto plano** y dejá que S3 lo cifre del lado del servidor.

    ```bash
    aws s3api put-object \
      --bucket "$EVIDENCE_BUCKET" --key records.csv \
      --body /tmp/records.csv \
      --query '[ServerSideEncryption,SSEKMSKeyId,BucketKeyEnabled]' --output text
    ```

    ```
    aws:kms   arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab   True
    ```

12. Verificá sobre el objeto mismo — esta es la evidencia que pide un auditor.

    ```bash
    aws s3api head-object --bucket "$EVIDENCE_BUCKET" --key records.csv \
      | jq '{ServerSideEncryption, SSEKMSKeyId, BucketKeyEnabled, ContentLength}'
    ```

    ```json
    {
      "ServerSideEncryption": "aws:kms",
      "SSEKMSKeyId": "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
      "BucketKeyEnabled": true,
      "ContentLength": 46
    }
    ```

13. Comprobá que el cifrado es transparente para quien llama con autorización.

    ```bash
    aws s3 cp "s3://${EVIDENCE_BUCKET}/records.csv" - 
    ```

    ```
    patient_id,diagnosis_code
    4471,E11.9
    4472,I10
    ```

### Preguntas de verificación — Bloque 3C

- **Q3.7** — El paso 13 devolvió texto plano sin ningún flag de descifrado. ¿Qué dos permisos necesitó tu principal para que ese único comando funcionara, y en qué dos documentos de política distintos viven?
- **Q3.8** — `BucketKeyEnabled: true` reduce los cargos de solicitudes de KMS hasta en un 99 %. Describí el mecanismo que logra esa reducción.
- **Q3.9** — Tu CISO pregunta: "¿Los datos están cifrados en reposo?" y después "¿Puedo probar que el personal de AWS no los puede leer?". Respondé ambas, e identificá cuál afirmación descansa en evidencia de AWS Artifact y no en tu propia configuración.
- **Q3.10** — Contrastá SSE-S3 (`AES256`), SSE-KMS (`aws:kms`) y DSSE-KMS. ¿Cuándo te forzaría el requisito de un regulador a abandonar SSE-S3?

---

## Ejercicio 4 — Cifrado en tránsito: aplicación de TLS, ACM y CloudHSM

El cifrado en reposo protege el disco. El cifrado en tránsito protege el cable. **El examen espera que sepas que ninguno de los dos está activo por defecto en todos los caminos, y que la encriptación en tránsito se aplica con política, no con esperanza.**

### Pasos

1. Observá que, por defecto, S3 acepta una solicitud HTTP en texto plano. Forzá la CLI hacia un endpoint HTTP.

   ```bash
   aws s3api head-object \
     --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --endpoint-url "http://s3.${AWS_REGION}.amazonaws.com" \
     --query 'ServerSideEncryption' --output text
   ```

   ```
   aws:kms
   ```

   El objeto está cifrado en reposo, y tus credenciales acaban de atravesar un canal sin cifrar para preguntar por él.

2. Escribí una política de bucket que deniegue el acceso sin TLS **y** deniegue versiones obsoletas de TLS.

   ```bash
   cat > /tmp/bucket-transit-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DenyUnencryptedTransport",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
           "arn:aws:s3:::${EVIDENCE_BUCKET}",
           "arn:aws:s3:::${EVIDENCE_BUCKET}/*"
         ],
         "Condition": {
           "Bool": {
             "aws:SecureTransport": "false"
           }
         }
       },
       {
         "Sid": "DenyOutdatedTlsVersions",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
           "arn:aws:s3:::${EVIDENCE_BUCKET}",
           "arn:aws:s3:::${EVIDENCE_BUCKET}/*"
         ],
         "Condition": {
           "NumericLessThan": {
             "s3:TlsVersion": "1.2"
           }
         }
       },
       {
         "Sid": "DenyUnencryptedObjectUploads",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${EVIDENCE_BUCKET}/*",
         "Condition": {
           "StringNotEquals": {
             "s3:x-amz-server-side-encryption": "aws:kms"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy \
     --bucket "$EVIDENCE_BUCKET" \
     --policy file:///tmp/bucket-transit-policy.json
   ```

3. Volvé a ejecutar la solicitud en texto plano. Ahora tiene que fallar.

   ```bash
   aws s3api head-object \
     --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --endpoint-url "http://s3.${AWS_REGION}.amazonaws.com"
   ```

   ```
   An error occurred (403) when calling the HeadObject operation: Forbidden
   ```

4. Confirmá que el camino HTTPS sigue funcionando.

   ```bash
   aws s3api head-object --bucket "$EVIDENCE_BUCKET" --key records.csv \
     --query 'ContentLength' --output text
   ```

   ```
   46
   ```

5. Inspeccioná la negociación TLS real con el endpoint de S3. Leé el protocolo, el cifrado y la cadena de certificados.

   ```bash
   openssl s_client -connect "s3.${AWS_REGION}.amazonaws.com:443" \
     -servername "s3.${AWS_REGION}.amazonaws.com" </dev/null 2>/dev/null \
     | grep -E 'Protocol|Cipher|subject=|issuer='
   ```

   ```
   subject=CN=s3.eu-west-1.amazonaws.com
   issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M03
   Protocol  : TLSv1.3
   Cipher    : TLS_AES_128_GCM_SHA256
   ```

6. Listá los certificados que AWS Certificate Manager administra para vos. ACM es la forma en que *tus* endpoints obtienen certificados TLS gratuitos con renovación automática.

   ```bash
   aws acm list-certificates \
     --query 'CertificateSummaryList[].[DomainName,Status,Type,NotAfter]' --output table
   ```

   ```
   -------------------------------------------------------------------------
   |                           ListCertificates                            |
   +-------------------+-----------+------------------+--------------------+
   |  study.example.io |  ISSUED   |  AMAZON_ISSUED   | 2027-04-11T12:00:00|
   +-------------------+-----------+------------------+--------------------+
   ```

   (Una lista vacía es un resultado válido si nunca pediste uno.)

7. Confirmá que no existe ningún clúster de CloudHSM — y entendé qué significa su ausencia.

   ```bash
   aws cloudhsmv2 describe-clusters --query 'Clusters[].[ClusterId,State,HsmType]' --output text
   ```

   ```
   (empty output — no clusters)
   ```

### Preguntas de verificación — Bloque 4

- **Q4.1** — En el paso 1 el objeto estaba cifrado en reposo y sin embargo la solicitud fue insegura. Escribí, en una oración cada uno, contra qué protege el "cifrado en reposo" y contra qué el "cifrado en tránsito", y nombrá el ataque específico al que quedó expuesto el paso 1.
- **Q4.2** — La declaración `DenyUnencryptedTransport` usa `"Principal": "*"` con `Effect: Deny`. ¿Por qué un principal comodín es seguro — de hecho, necesario — acá, mientras que sería peligroso en una declaración `Allow`?
- **Q4.3** — El paso 5 muestra `Amazon RSA 2048 M03` como emisor. ¿Quién es responsable de renovar ese certificado: vos o AWS? Ahora respondé la misma pregunta para el certificado del paso 6.
- **Q4.4** — El regulador de tu organización exige que el material de clave se almacene en un **HSM de un solo inquilino, validado FIPS 140-3 Nivel 3, que controlás en exclusiva y al que AWS no puede acceder**. ¿Qué servicio satisface esto, y qué responsabilidad operativa te transfiere elegirlo?
- **Q4.5** — Ordená estos tres para un equipo que quiere TLS en un endpoint web público con cero trabajo de renovación: ACM, CloudHSM, KMS. Justificá por qué los otros dos son la respuesta equivocada.

---

## Ejercicio 5 — Auditar el plano de control con AWS CloudTrail

**CloudTrail responde "quién hizo qué, cuándo y desde dónde".** Es la columna vertebral probatoria de toda auditoría de AWS. Este bloque construye un trail con validación criptográfica de archivos de registro y después demuestra la evidencia de manipulación.

### Pasos

1. Creá un bucket dedicado para los registros y aplicá la política de servicio de CloudTrail.

   ```bash
   aws s3api create-bucket --bucket "$TRAIL_BUCKET" --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null

   aws s3api put-public-access-block --bucket "$TRAIL_BUCKET" \
     --public-access-block-configuration \
     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

   cat > /tmp/trail-bucket-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AWSCloudTrailAclCheck",
         "Effect": "Allow",
         "Principal": { "Service": "cloudtrail.amazonaws.com" },
         "Action": "s3:GetBucketAcl",
         "Resource": "arn:aws:s3:::${TRAIL_BUCKET}",
         "Condition": {
           "StringEquals": {
             "aws:SourceArn": "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail"
           }
         }
       },
       {
         "Sid": "AWSCloudTrailWrite",
         "Effect": "Allow",
         "Principal": { "Service": "cloudtrail.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${TRAIL_BUCKET}/AWSLogs/${AWS_ACCOUNT_ID}/*",
         "Condition": {
           "StringEquals": {
             "s3:x-amz-acl": "bucket-owner-full-control",
             "aws:SourceArn": "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" \
     --policy file:///tmp/trail-bucket-policy.json
   ```

2. Creá un trail multi-Región con **validación de archivos de registro habilitada**. Ambos flags importan para una auditoría.

   ```bash
   aws cloudtrail create-trail \
     --name clf-lab-trail \
     --s3-bucket-name "$TRAIL_BUCKET" \
     --is-multi-region-trail \
     --include-global-service-events \
     --enable-log-file-validation \
     --query '[Name,IsMultiRegionTrail,LogFileValidationEnabled,TrailARN]' --output text
   ```

   ```
   clf-lab-trail   True    True    arn:aws:cloudtrail:eu-west-1:111122223333:trail/clf-lab-trail
   ```

3. Iniciá el registro. **Un trail creado no es un trail que registra.**

   ```bash
   aws cloudtrail start-logging --name clf-lab-trail
   aws cloudtrail get-trail-status --name clf-lab-trail \
     --query '[IsLogging,LatestDeliveryTime]' --output text
   ```

   ```
   True    None
   ```

4. Agregá un selector de **eventos de datos** para el bucket de evidencia. Los eventos de gestión están activos por defecto; las lecturas y escrituras a nivel de objeto no.

   ```bash
   aws cloudtrail put-event-selectors \
     --trail-name clf-lab-trail \
     --advanced-event-selectors "$(cat <<JSON
   [
     {
       "Name": "Management events",
       "FieldSelectors": [
         { "Field": "eventCategory", "Equals": ["Management"] }
       ]
     },
     {
       "Name": "S3 object-level events on the evidence bucket",
       "FieldSelectors": [
         { "Field": "eventCategory", "Equals": ["Data"] },
         { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
         { "Field": "resources.ARN", "StartsWith": ["arn:aws:s3:::${EVIDENCE_BUCKET}/"] }
       ]
     }
   ]
   JSON
   )" --query 'AdvancedEventSelectors[].Name' --output text
   ```

   ```
   Management events       S3 object-level events on the evidence bucket
   ```

5. Generá una acción auditable y después encontrala. **Esperá de 5 a 15 minutos** — el historial de eventos de CloudTrail es casi en tiempo real, no en tiempo real.

   ```bash
   aws s3api put-bucket-tagging --bucket "$EVIDENCE_BUCKET" \
     --tagging 'TagSet=[{Key=DataClassification,Value=Confidential}]'

   sleep 600

   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketTagging \
     --max-results 1 \
     --query 'Events[0].[EventTime,Username,EventName,Resources[0].ResourceName]' \
     --output text
   ```

   ```
   2026-09-03T10:41:07+00:00  lab-admin  PutBucketTagging  clf-lab-evidence-111122223333-clf22
   ```

6. Leé el registro completo del evento. Cada campo de acá es una pregunta que hará un auditor.

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketTagging \
     --max-results 1 --query 'Events[0].CloudTrailEvent' --output text \
     | jq '{eventTime, eventSource, eventName, awsRegion, sourceIPAddress,
            userAgent, userIdentity: .userIdentity.arn, errorCode, readOnly, managementEvent}'
   ```

   ```json
   {
     "eventTime": "2026-09-03T10:41:07Z",
     "eventSource": "s3.amazonaws.com",
     "eventName": "PutBucketTagging",
     "awsRegion": "eu-west-1",
     "sourceIPAddress": "203.0.113.47",
     "userAgent": "aws-cli/2.19.4 md/awscrt#0.23.4 ua/2.0 os/linux#6.11.0",
     "userIdentity": "arn:aws:iam::111122223333:user/lab-admin",
     "errorCode": null,
     "readOnly": false,
     "managementEvent": true
   }
   ```

7. Verificá la integridad de los archivos de registro entregados. Este es el control de evidencia de manipulación.

   ```bash
   aws cloudtrail validate-logs \
     --trail-arn "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail" \
     --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
   ```

   ```
   Validating log files for trail arn:aws:cloudtrail:eu-west-1:111122223333:trail/clf-lab-trail
   between 2026-09-03T08:00:00Z and 2026-09-03T11:00:00Z

   Results requested for 2026-09-03T08:00:00Z to 2026-09-03T11:00:00Z
   Results found for 2026-09-03T08:42:11Z to 2026-09-03T10:55:03Z:

   2/2 digest files valid
   5/5 log files valid
   ```

8. Simulá una manipulación y volvé a validar. **Hacé esto solo en el bucket del laboratorio.**

   ```bash
   OBJ=$(aws s3api list-objects-v2 --bucket "$TRAIL_BUCKET" \
     --prefix "AWSLogs/${AWS_ACCOUNT_ID}/CloudTrail/" \
     --query 'Contents[0].Key' --output text)
   echo "tampering with: $OBJ"
   printf 'corrupted' | aws s3 cp - "s3://${TRAIL_BUCKET}/${OBJ}"

   aws cloudtrail validate-logs \
     --trail-arn "arn:aws:cloudtrail:${AWS_REGION}:${AWS_ACCOUNT_ID}:trail/clf-lab-trail" \
     --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" 2>&1 | tail -6
   ```

   ```
   Results found for 2026-09-03T08:42:11Z to 2026-09-03T10:55:03Z:

   2/2 digest files valid
   4/5 log files valid
   Log file  s3://clf-lab-trail-111122223333-clf22/AWSLogs/111122223333/CloudTrail/eu-west-1/2026/09/03/111122223333_CloudTrail_eu-west-1_20260903T0845Z_a1B2c3D4.json.gz
   INVALID: hash value doesn't match
   ```

### Preguntas de verificación — Bloque 5

- **Q5.1** — El paso 3 era necesario aunque el paso 2 ya había creado el trail. Describí un fallo de auditoría realista causado por saltearlo, y nombrá la llamada a API que lo habría detectado.
- **Q5.2** — Los eventos de gestión se registran por defecto; el selector de eventos de datos del paso 4 hubo que agregarlo explícitamente. Dá las dos razones — una financiera, otra sobre volumen — por las que AWS hizo que ese fuera el comportamiento por defecto.
- **Q5.3** — En el paso 8 el archivo de registro falló la validación pero los archivos de resumen (digest) siguieron válidos. Explicá la estructura de cadena de custodia que hace esto posible, e indicá claramente si la validación de archivos de registro *impide* la manipulación o la *detecta*.
- **Q5.4** — CloudTrail registra `sourceIPAddress` y `userAgent`. ¿Qué pregunta específica de cumplimiento responde cada campo, y con qué servicio combinarías CloudTrail para detectar que un conjunto de estos eventos constituye un ataque y no trabajo rutinario?
- **Q5.5** — Distinguí CloudTrail de Amazon CloudWatch en una oración cada uno. Después ubicá estos cuatro ítems en la columna correcta: una llamada a API que eliminó un grupo de seguridad; utilización de CPU al 94 %; la salida de un `print()` de una función Lambda; la identidad que deshabilitó una clave de KMS.

---

## Ejercicio 6 — Cumplimiento continuo con AWS Config

**CloudTrail te dice qué pasó. AWS Config te dice cómo luce el recurso ahora, cómo lucía antes, y si eso viola una regla.** Este es el servicio que responde "probá que el bucket estuvo cifrado durante 12 meses".

> **Costo:** AWS Config factura por elemento de configuración registrado y por evaluación de regla. Este bloque registra un alcance de recursos acotado. El Ejercicio 9 detiene el grabador.

### Pasos

1. Creá el rol vinculado a servicio que Config necesita.

   ```bash
   aws iam create-service-linked-role --aws-service-name config.amazonaws.com \
     --query 'Role.Arn' --output text 2>/dev/null \
     || aws iam get-role --role-name AWSServiceRoleForConfig --query 'Role.Arn' --output text
   ```

   ```
   arn:aws:iam::111122223333:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig
   ```

2. Creá el bucket del canal de entrega y su política.

   ```bash
   export CONFIG_BUCKET="clf-lab-config-${LAB_SUFFIX}"
   aws s3api create-bucket --bucket "$CONFIG_BUCKET" --region "$AWS_REGION" \
     --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null

   cat > /tmp/config-bucket-policy.json <<JSON
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AWSConfigBucketPermissionsCheck",
         "Effect": "Allow",
         "Principal": { "Service": "config.amazonaws.com" },
         "Action": ["s3:GetBucketAcl", "s3:ListBucket"],
         "Resource": "arn:aws:s3:::${CONFIG_BUCKET}",
         "Condition": { "StringEquals": { "aws:SourceAccount": "${AWS_ACCOUNT_ID}" } }
       },
       {
         "Sid": "AWSConfigBucketDelivery",
         "Effect": "Allow",
         "Principal": { "Service": "config.amazonaws.com" },
         "Action": "s3:PutObject",
         "Resource": "arn:aws:s3:::${CONFIG_BUCKET}/AWSLogs/${AWS_ACCOUNT_ID}/Config/*",
         "Condition": {
           "StringEquals": {
             "s3:x-amz-acl": "bucket-owner-full-control",
             "aws:SourceAccount": "${AWS_ACCOUNT_ID}"
           }
         }
       }
     ]
   }
   JSON

   aws s3api put-bucket-policy --bucket "$CONFIG_BUCKET" --policy file:///tmp/config-bucket-policy.json
   ```

3. Configurá el grabador con un alcance de recursos **acotado** para controlar el costo.

   ```bash
   aws configservice put-configuration-recorder \
     --configuration-recorder "name=clf-lab-recorder,roleARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig" \
     --recording-group "allSupported=false,includeGlobalResourceTypes=false,resourceTypes=AWS::S3::Bucket,AWS::KMS::Key,AWS::CloudTrail::Trail"

   aws configservice put-delivery-channel \
     --delivery-channel "name=clf-lab-channel,s3BucketName=${CONFIG_BUCKET}"

   aws configservice start-configuration-recorder --configuration-recorder-name clf-lab-recorder
   aws configservice describe-configuration-recorder-status \
     --query 'ConfigurationRecordersStatus[0].[name,recording,lastStatus]' --output text
   ```

   ```
   clf-lab-recorder   True   SUCCESS
   ```

4. Desplegá una **regla administrada por AWS** que comprueba continuamente el cifrado por defecto de S3.

   ```bash
   aws configservice put-config-rule --config-rule "$(cat <<'JSON'
   {
     "ConfigRuleName": "clf-lab-s3-sse-enabled",
     "Description": "Checks that S3 buckets have default server-side encryption enabled",
     "Scope": { "ComplianceResourceTypes": ["AWS::S3::Bucket"] },
     "Source": {
       "Owner": "AWS",
       "SourceIdentifier": "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
     }
   }
   JSON
   )"
   ```

5. Agregá una segunda regla que aplique el control de tránsito que construiste en el Ejercicio 4.

   ```bash
   aws configservice put-config-rule --config-rule "$(cat <<'JSON'
   {
     "ConfigRuleName": "clf-lab-s3-ssl-requests-only",
     "Description": "Checks that S3 bucket policies deny requests over plain HTTP",
     "Scope": { "ComplianceResourceTypes": ["AWS::S3::Bucket"] },
     "Source": {
       "Owner": "AWS",
       "SourceIdentifier": "S3_BUCKET_SSL_REQUESTS_ONLY"
     }
   }
   JSON
   )"
   ```

6. Forzá la evaluación y esperá los resultados.

   ```bash
   aws configservice start-config-rules-evaluation \
     --config-rule-names clf-lab-s3-sse-enabled clf-lab-s3-ssl-requests-only
   sleep 120
   ```

7. Leé el veredicto de cumplimiento por recurso.

   ```bash
   aws configservice get-compliance-details-by-config-rule \
     --config-rule-name clf-lab-s3-ssl-requests-only \
     --query 'EvaluationResults[].[EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,ComplianceType]' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                 GetComplianceDetailsByConfigRule                  |
   +-------------------------------------------------+-----------------+
   |  clf-lab-config-111122223333-clf22               |  NON_COMPLIANT  |
   |  clf-lab-evidence-111122223333-clf22             |  COMPLIANT      |
   |  clf-lab-trail-111122223333-clf22                |  NON_COMPLIANT  |
   +-------------------------------------------------+-----------------+
   ```

8. Obtené el resumen a nivel de cuenta — el número que va a un panel de gobernanza.

   ```bash
   aws configservice get-compliance-summary-by-config-rule
   ```

   ```json
   {
       "ComplianceSummary": {
           "CompliantResourceCount": {
               "CappedCount": 1,
               "CapExceeded": false
           },
           "NonCompliantResourceCount": {
               "CappedCount": 1,
               "CapExceeded": false
           },
           "ComplianceSummaryTimestamp": "2026-09-03T11:12:44.187000+00:00"
       }
   }
   ```

9. Consultá el **historial de configuración** — esto es lo que Artifact no te puede dar.

   ```bash
   aws configservice get-resource-config-history \
     --resource-type AWS::S3::Bucket \
     --resource-id "$EVIDENCE_BUCKET" \
     --limit 3 \
     --query 'configurationItems[].[configurationItemCaptureTime,configurationItemStatus,resourceId]' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------
   |                             GetResourceConfigHistory                                  |
   +--------------------------------------+-------------+----------------------------------+
   |  2026-09-03T10:41:19.402000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   |  2026-09-03T10:28:55.771000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   |  2026-09-03T10:22:03.118000+00:00    |  OK         |  clf-lab-evidence-...-clf22      |
   +--------------------------------------+-------------+----------------------------------+
   ```

10. Remediá el hallazgo del paso 7 aplicando la política de tránsito al bucket del trail, y después reevaluá.

    ```bash
    sed "s/${EVIDENCE_BUCKET}/${TRAIL_BUCKET}/g" /tmp/bucket-transit-policy.json \
      | jq 'del(.Statement[] | select(.Sid == "DenyUnencryptedObjectUploads"))' \
      > /tmp/trail-transit.json

    aws s3api get-bucket-policy --bucket "$TRAIL_BUCKET" --query Policy --output text \
      | jq --slurpfile add /tmp/trail-transit.json \
        '.Statement += $add[0].Statement' > /tmp/trail-merged.json

    aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy file:///tmp/trail-merged.json
    aws configservice start-config-rules-evaluation --config-rule-names clf-lab-s3-ssl-requests-only
    sleep 120
    aws configservice get-compliance-details-by-config-rule \
      --config-rule-name clf-lab-s3-ssl-requests-only \
      --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId==`'"$TRAIL_BUCKET"'`].ComplianceType' \
      --output text
    ```

    ```
    COMPLIANT
    ```

### Preguntas de verificación — Bloque 6

- **Q6.1** — El paso 9 devolvió una línea de tiempo de instantáneas de configuración. Indicá la pregunta de auditoría que esto responde y que ni CloudTrail ni AWS Artifact pueden responder por sí solos.
- **Q6.2** — La regla del paso 4 tiene `"Owner": "AWS"`. ¿Cuál es el valor alternativo de owner, qué te obligaría a construir, y por qué los objetivos del examen enfatizan el camino de las reglas administradas?
- **Q6.3** — Config reportó el bucket del *trail* como `NON_COMPLIANT` para `S3_BUCKET_SSL_REQUESTS_ONLY` mientras que el bucket de *evidencia* estaba conforme. ¿Qué te dice esto sobre cómo evalúa la regla, y qué era realmente distinto entre los dos buckets?
- **Q6.4** — Definí un **conformance pack** y explicá por qué una organización que mapea a PCI DSS desplegaría uno en lugar de 60 llamadas individuales a `put-config-rule`.
- **Q6.5** — Tenés que ubicar estos tres servicios correctamente. Para cada uno de los siguientes, nombrá el *único* servicio que es la respuesta principal: (a) "mostrame todos los cambios hechos a este grupo de seguridad durante seis meses"; (b) "mostrame quién lo eliminó y desde qué IP"; (c) "mostrame el certificado ISO 27001 de AWS".

---

## Ejercicio 7 — Servicios de detección de amenazas y postura de seguridad

Cuatro servicios, cuatro entradas distintas, cuatro salidas distintas. **El examen evalúa el mapeo, no la configuración.** Este bloque hace que cada uno produzca un artefacto real para que el mapeo se fije.

> **Costo:** GuardDuty, Inspector y Macie son gratis por 30 días por cuenta, después se facturan. Security Hub factura desde la primera comprobación. El Ejercicio 9 los deshabilita a todos.

### Bloque A — Amazon GuardDuty: detección continua de amenazas a partir de telemetría

1. Habilitá un detector. Fijate en las entradas que consume GuardDuty — nunca lo apuntás a un bucket de registros.

   ```bash
   aws guardduty create-detector --enable \
     --finding-publishing-frequency FIFTEEN_MINUTES \
     --query 'DetectorId' --output text
   ```

   ```
   d4c3b2a1e5f6789012345678abcdef01
   ```

   ```bash
   export DETECTOR_ID=d4c3b2a1e5f6789012345678abcdef01
   aws guardduty get-detector --detector-id "$DETECTOR_ID" \
     --query '[Status,ServiceRole,FindingPublishingFrequency]' --output text
   ```

   ```
   ENABLED  arn:aws:iam::111122223333:role/aws-service-role/guardduty.amazonaws.com/AWSServiceRoleForAmazonGuardDuty  FIFTEEN_MINUTES
   ```

2. Generá hallazgos de muestra para poder inspeccionar el esquema de hallazgos sin estar bajo ataque.

   ```bash
   aws guardduty create-sample-findings --detector-id "$DETECTOR_ID" \
     --finding-types "UnauthorizedAccess:EC2/SSHBruteForce" \
                     "CryptoCurrency:EC2/BitcoinTool.B!DNS" \
                     "Policy:IAMUser/RootCredentialUsage"
   sleep 20
   ```

3. Listá y leé un hallazgo.

   ```bash
   aws guardduty list-findings --detector-id "$DETECTOR_ID" --max-results 3 \
     --query 'FindingIds' --output text | tr '\t' '\n'
   ```

   ```
   1ac4d8e2f9b7a3c5d1e0f2a4b6c8d0e2
   2bd5e9f3a0c8b4d6e2f1a3b5c7d9e1f3
   3ce6f0a4b1d9c5e7f3a2b4c6d8e0f2a4
   ```

   ```bash
   aws guardduty get-findings --detector-id "$DETECTOR_ID" \
     --finding-ids 1ac4d8e2f9b7a3c5d1e0f2a4b6c8d0e2 \
     --query 'Findings[0].[Type,Severity,Title,Service.ResourceRole,Service.DetectorId]' --output text
   ```

   ```
   UnauthorizedAccess:EC2/SSHBruteForce   2   [SAMPLE] 198.51.100.0 is performing SSH brute force attacks against i-99999999   TARGET   d4c3b2a1e5f6789012345678abcdef01
   ```

4. Confirmá qué fuentes de datos están alimentando al detector.

   ```bash
   aws guardduty list-detector-features --detector-id "$DETECTOR_ID" 2>/dev/null \
     || aws guardduty get-detector --detector-id "$DETECTOR_ID" --query 'Features[].[Name,Status]' --output table
   ```

   ```
   -----------------------------------------------
   |                 GetDetector                 |
   +----------------------------+----------------+
   |  CLOUD_TRAIL               |  ENABLED       |
   |  DNS_LOGS                  |  ENABLED       |
   |  FLOW_LOGS                 |  ENABLED       |
   |  S3_DATA_EVENTS            |  ENABLED       |
   |  EKS_AUDIT_LOGS            |  DISABLED      |
   |  EBS_MALWARE_PROTECTION    |  DISABLED      |
   |  RDS_LOGIN_EVENTS          |  DISABLED      |
   +----------------------------+----------------+
   ```

### Preguntas de verificación — Bloque 7A

- **Q7.1** — La fuente de datos `CLOUD_TRAIL` está `ENABLED` aunque nunca le diste acceso a GuardDuty al bucket del trail del Ejercicio 5. Explicá cómo lee GuardDuty esa telemetría y qué consecuencia práctica tiene esto para el costo y para la posibilidad de que un atacante lo deje ciego.
- **Q7.2** — El tipo de hallazgo `Policy:IAMUser/RootCredentialUsage` es de severidad baja, pero muchas organizaciones lo tratan como un evento que despierta a la guardia. ¿Por qué?
- **Q7.3** — Un colega pregunta si GuardDuty va a encontrar la biblioteca `log4j` sin parchear en una instancia EC2. Respondé, y nombrá el servicio que sí lo hará.

### Bloque B — Amazon Inspector, Amazon Macie, AWS Security Hub, Amazon Detective

5. Habilitá Amazon Inspector para los tipos de recursos que escanea.

   ```bash
   aws inspector2 enable --resource-types EC2 ECR LAMBDA \
     --query 'accounts[].[accountId,state.status]' --output text
   ```

   ```
   111122223333   ENABLING
   ```

   ```bash
   sleep 30
   aws inspector2 batch-get-account-status \
     --query 'accounts[0].resourceState.[ec2.status,ecr.status,lambda.status]' --output text
   ```

   ```
   ENABLED  ENABLED  ENABLED
   ```

6. Consultá la cobertura de Inspector. Sin instancias corriendo, la cantidad de hallazgos es cero — y eso en sí mismo es informativo.

   ```bash
   aws inspector2 list-coverage --query 'coveredResources[].[resourceType,scanStatus.statusCode]' --output text
   aws inspector2 list-findings --max-results 5 --query 'findings[].[severity,type,title]' --output text
   ```

   ```
   (no output — no scannable resources in this account)
   ```

7. Habilitá Amazon Macie e inspeccioná qué clasifica.

   ```bash
   aws macie2 enable-macie --status ENABLED --finding-publishing-frequency FIFTEEN_MINUTES
   aws macie2 get-macie-session --query '[status,serviceRole,createdAt]' --output text
   ```

   ```
   ENABLED  arn:aws:iam::111122223333:role/aws-service-role/macie.amazonaws.com/AWSServiceRoleForAmazonMacie  2026-09-03T11:31:02.554000+00:00
   ```

   ```bash
   aws macie2 list-managed-data-identifiers \
     --query 'items[?category==`PERSONAL_INFORMATION`].id' --output text | tr '\t' '\n' | head -8
   ```

   ```
   ADDRESS
   DRIVERS_LICENSE_ID_US
   NATIONAL_IDENTIFICATION_NUMBER_ES
   PASSPORT_NUMBER_US
   PHONE_NUMBER_US
   USA_SOCIAL_SECURITY_NUMBER
   USA_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER
   DATE_OF_BIRTH
   ```

8. Habilitá AWS Security Hub con los estándares por defecto. Esta es la capa de agregación.

   ```bash
   aws securityhub enable-security-hub --enable-default-standards \
     --tags Purpose=clf-c02-lab
   sleep 60
   aws securityhub get-enabled-standards \
     --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' --output text
   ```

   ```
   arn:aws:securityhub:eu-west-1::standards/aws-foundational-security-best-practices/v/1.0.0   READY
   arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0                          READY
   ```

9. Confirmá que Security Hub está ingiriendo de los otros servicios. **La columna del nombre de producto es toda la lección.**

   ```bash
   sleep 300
   aws securityhub get-findings --max-results 50 \
     --query 'Findings[].ProductName' --output text | tr '\t' '\n' | sort | uniq -c | sort -rn
   ```

   ```
        31 Security Hub
         3 GuardDuty
         1 Inspector
   ```

10. Leé un hallazgo en **ASFF** (AWS Security Finding Format) — la normalización que hace posible la agregación.

    ```bash
    aws securityhub get-findings --max-results 1 \
      --filters '{"ProductName":[{"Value":"GuardDuty","Comparison":"EQUALS"}]}' \
      --query 'Findings[0].[ProductName,Title,Severity.Label,Compliance.Status,Workflow.Status,RecordState]' \
      --output text
    ```

    ```
    GuardDuty   [SAMPLE] 198.51.100.0 is performing SSH brute force attacks against i-99999999   LOW   None   NEW   ACTIVE
    ```

11. Mirá un hallazgo de comprobación de control para ver el encuadre de cumplimiento.

    ```bash
    aws securityhub get-findings --max-results 1 \
      --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}]}' \
      --query 'Findings[0].[Title,Severity.Label,Compliance.Status,Compliance.RelatedRequirements]' \
      --output text
    ```

    ```
    S3.8 S3 Block Public Access setting should be enabled at the bucket level   HIGH   FAILED   ['CIS AWS Foundations Benchmark v1.2.0/2.1.5', 'PCI DSS v3.2.1/1.2.1']
    ```

12. Notá que Amazon Detective, si estuviera habilitado, construiría un grafo de comportamiento a partir de la misma telemetría — para **investigación**, no para detección.

    ```bash
    aws detective list-graphs --query 'GraphList[].[Arn,CreatedTime]' --output text
    ```

    ```
    (empty — no behavior graph in this account)
    ```

### Preguntas de verificación — Bloque 7B

- **Q7.4** — Completá este mapeo con exactamente un servicio por fila, e indicá qué *ingiere* cada uno:

  | Pregunta | Servicio | Ingiere |
  |---|---|---|
  | ¿Hay un CVE en los paquetes del SO de mi flota EC2 o en mis imágenes de contenedor? | | |
  | ¿Hay información de identificación personal alojada en mis buckets de S3? | | |
  | ¿Hay una credencial comprometida exfiltrando datos ahora mismo? | | |
  | ¿Dónde aparecen todos los hallazgos anteriores en una sola pantalla, puntuados contra CIS y PCI? | | |
  | ¿Qué otros recursos tocó este rol comprometido en los últimos 90 días? | | |

- **Q7.5** — El paso 9 muestra el propio nombre de producto de Security Hub con 31 hallazgos junto a 3 de GuardDuty. ¿Qué genera esos 31, y por qué importa esa distinción cuando alguien afirma que "Security Hub es un servicio de detección"?
- **Q7.6** — El hallazgo del paso 11 lista tanto `CIS AWS Foundations Benchmark v1.2.0/2.1.5` como `PCI DSS v3.2.1/1.2.1`. Explicá el valor de gobernanza de que una comprobación técnica mapee a múltiples marcos.
- **Q7.7** — Los identificadores de datos administrados de Macie incluyen `NATIONAL_IDENTIFICATION_NUMBER_ES`. Conectá esto con el Ejercicio 2: ¿cómo se combinan Macie y una barrera de residencia de datos en una única narrativa de control para GDPR?
- **Q7.8** — Se dispara un hallazgo de criptominería en una instancia EC2. Ordená estos cuatro servicios según cuándo abrirías cada uno durante el incidente: GuardDuty, Detective, Security Hub, CloudTrail. Justificá el orden.

---

## Ejercicio 8 — Gobernanza a escala: Organizations, Control Tower, Audit Manager, License Manager, Trusted Advisor

El bloque final es mayormente de solo lectura y conceptual, porque estos servicios o requieren una organización o un plan de soporte pago. **El examen evalúa qué herramienta resuelve qué problema de gobernanza.**

### Pasos

1. Determiná si esta cuenta está en una organización y cuál es su postura.

   ```bash
   aws organizations describe-organization \
     --query 'Organization.[Id,FeatureSet,MasterAccountEmail]' --output text 2>&1
   ```

   ```
   o-a1b2c3d4e5   ALL   billing@example.com
   ```

   o, para una cuenta independiente:

   ```
   An error occurred (AWSOrganizationsNotInUseException) when calling the
   DescribeOrganization operation: Your account is not a member of an organization.
   ```

2. Si está en una organización, enumerá los tipos de política disponibles en la raíz.

   ```bash
   aws organizations list-roots --query 'Roots[0].PolicyTypes' --output table
   ```

   ```
   -------------------------------------------------
   |                   ListRoots                   |
   +--------------------------------+--------------+
   |              Type              |    Status    |
   +--------------------------------+--------------+
   |  SERVICE_CONTROL_POLICY        |  ENABLED     |
   |  TAG_POLICY                    |  ENABLED     |
   |  BACKUP_POLICY                 |  NOT_ENABLED |
   |  AISERVICES_OPT_OUT_POLICY     |  NOT_ENABLED |
   +--------------------------------+--------------+
   ```

3. Comprobá si AWS Control Tower estableció una landing zone.

   ```bash
   aws controltower list-landing-zones --query 'landingZones[].arn' --output text
   ```

   ```
   arn:aws:controltower:eu-west-1:111122223333:landingzone/1A2B3C4D5E6F7G8H
   ```

   o, si nunca se configuró:

   ```
   (empty output)
   ```

4. Comprobá AWS Audit Manager. Mirá los *frameworks*, que son los mapeos de control preconstruidos.

   ```bash
   aws auditmanager get-account-status --query 'status' --output text 2>&1
   ```

   ```
   INACTIVE
   ```

   ```bash
   aws auditmanager list-assessment-frameworks --framework-type Standard \
     --query 'frameworkMetadataList[].[name,controlsCount]' --output table 2>/dev/null | head -12
   ```

   ```
   -------------------------------------------------------------
   |               ListAssessmentFrameworks                    |
   +--------------------------------------------+--------------+
   |  AWS Audit Manager Sample Framework         |  8           |
   |  CIS AWS Foundations Benchmark v1.4.0 L1    |  43          |
   |  GDPR 2016/679                              |  134         |
   |  HIPAA Security Rule 2003                   |  60          |
   |  ISO/IEC 27001:2013 Annex A                 |  114         |
   |  PCI DSS V3.2.1                             |  128         |
   |  SOC 2                                      |  61          |
   +--------------------------------------------+--------------+
   ```

5. Consultá AWS Trusted Advisor. **Esto requiere un plan de soporte Business, Enterprise On-Ramp o Enterprise** para la API y el conjunto completo de comprobaciones.

   ```bash
   aws support describe-trusted-advisor-checks --language en \
     --query 'checks[?category==`security`].[name]' --output text --region us-east-1
   ```

   ```
   Security Groups - Specific Ports Unrestricted
   Security Groups - Unrestricted Access
   IAM Use
   MFA on Root Account
   Amazon S3 Bucket Permissions
   Amazon RDS Security Group Access Risk
   AWS CloudTrail Logging
   Exposed Access Keys
   ELB Listener Security
   ```

   En soporte Basic o Developer:

   ```
   An error occurred (SubscriptionRequiredException) when calling the
   DescribeTrustedAdvisorChecks operation: AWS Premium Support Subscription is required
   to use this service.
   ```

6. Comprobá AWS License Manager en busca de licencias rastreadas — el servicio de gobernanza para el cumplimiento de BYOL.

   ```bash
   aws license-manager list-license-configurations \
     --query 'LicenseConfigurations[].[Name,LicenseCountingType,LicenseCount,ConsumedLicenses]' --output table
   ```

   ```
   (empty — no license configurations defined)
   ```

7. Construí la matriz de decisión vos mismo antes de leer las respuestas. Completá la columna del medio.

   | Problema de gobernanza | Servicio | Por qué no los vecinos |
   |---|---|---|
   | Facturación centralizada multicuenta y una jerarquía de barreras con SCP | | |
   | Levantar una landing zone multicuenta conforme en una tarde, con barreras preconfiguradas | | |
   | Recolectar evidencia continuamente y mapearla a controles SOC 2, lista para un auditor | | |
   | Probar que no estoy sobredesplegando mi derecho BYOL de Oracle de 50 núcleos | | |
   | Obtener comprobaciones proactivas de buenas prácticas sobre costo, rendimiento, seguridad, tolerancia a fallos y límites de servicio | | |
   | Obtener la propia Atestación de Cumplimiento de PCI DSS de AWS | | |

### Preguntas de verificación — Bloque 8

- **Q8.1** — Control Tower y Organizations se confunden con frecuencia. Indicá la relación entre ellos con precisión, y después respondé: ¿podés usar Control Tower sin Organizations?
- **Q8.2** — Audit Manager ofrece un framework "GDPR 2016/679" con 134 controles. ¿Desplegar ese framework hace que tu carga de trabajo cumpla con GDPR? ¿Qué produce en realidad, y quién sigue siendo responsable?
- **Q8.3** — Trusted Advisor tiene cinco categorías de comprobación. Nombralas, e identificá qué única categoría está disponible completa en el plan de soporte Basic frente a cuáles están restringidas.
- **Q8.4** — Una `TAG_POLICY` está `ENABLED` en la raíz en el paso 2. Dá un uso concreto de cumplimiento para las políticas de etiquetas que una SCP no puede lograr.
- **Q8.5** — Tu organización debe reportar un presunto abuso de recursos de AWS — una instancia EC2 en la cuenta de otra persona está escaneando puertos en la tuya. ¿Qué canal de AWS usás, y es una responsabilidad del cliente o de AWS bajo el modelo de responsabilidad compartida?
- **Q8.6** — Ubicá cada uno de los siguientes del lado correcto de la línea de responsabilidad compartida: parcheo del hipervisor, parcheo del SO invitado, destrucción física de discos dados de baja, configuración de la política de bucket de S3, configuración de la política de clave de KMS, la durabilidad de la capa de almacenamiento de S3, aplicación de MFA a usuarios de IAM, protección DDoS del borde de la red global de AWS.

---

## Ejercicio 9 — Limpieza

Ejecutá esto completo. Config, Security Hub, GuardDuty, Inspector y Macie siguen facturando hasta que se deshabiliten.

```bash
# --- Detection and posture services -----------------------------------------
aws securityhub disable-security-hub
aws guardduty delete-detector --detector-id "$DETECTOR_ID"
aws inspector2 disable --resource-types EC2 ECR LAMBDA
aws macie2 disable-macie

# --- AWS Config --------------------------------------------------------------
aws configservice delete-config-rule --config-rule-name clf-lab-s3-sse-enabled
aws configservice delete-config-rule --config-rule-name clf-lab-s3-ssl-requests-only
aws configservice stop-configuration-recorder --configuration-recorder-name clf-lab-recorder
aws configservice delete-delivery-channel --delivery-channel-name clf-lab-channel
aws configservice delete-configuration-recorder --configuration-recorder-name clf-lab-recorder

# --- CloudTrail --------------------------------------------------------------
aws cloudtrail stop-logging --name clf-lab-trail
aws cloudtrail delete-trail --name clf-lab-trail

# --- Organizations SCP (only if Block 2C was run) ---------------------------
# aws organizations detach-policy --policy-id p-x9y8z7w6 --target-id "$OU_ID"
# aws organizations delete-policy --policy-id p-x9y8z7w6

# --- S3 buckets --------------------------------------------------------------
for B in "$EVIDENCE_BUCKET" "$TRAIL_BUCKET" "$CONFIG_BUCKET"; do
  aws s3 rm "s3://${B}" --recursive >/dev/null 2>&1
  aws s3api delete-bucket --bucket "$B" 2>/dev/null && echo "deleted bucket ${B}"
done

# --- KMS: schedule deletion (7-30 day mandatory waiting period) --------------
aws kms delete-alias --alias-name alias/clf-lab-s3
aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 \
  --query '[KeyId,KeyState,DeletionDate]' --output text

# --- Local artifacts ---------------------------------------------------------
rm -f /tmp/records.csv /tmp/records.csv.enc /tmp/datakey.json /tmp/wrapped-dk.* \
      /tmp/scp-region-lock.json /tmp/bucket-transit-policy.json \
      /tmp/trail-bucket-policy.json /tmp/config-bucket-policy.json \
      /tmp/trail-transit.json /tmp/trail-merged.json
```

```
1234abcd-12ab-34cd-56ef-1234567890ab   PendingDeletion   2026-09-10T11:58:01.223000+00:00
```

Confirmá que no queda nada registrando:

```bash
aws configservice describe-configuration-recorders --query 'ConfigurationRecorders' --output text
aws cloudtrail describe-trails --query 'trailList[?Name==`clf-lab-trail`]' --output text
aws guardduty list-detectors --query 'DetectorIds' --output text
```

```
(three empty lines — nothing left running)
```

### Pregunta de verificación — Bloque 9

- **Q9.1** — `schedule-key-deletion` impone un período de espera mínimo de 7 días y el estado de la clave pasa a `PendingDeletion`. ¿Por qué AWS se niega a eliminar una clave de KMS de inmediato, y cuál es la consecuencia operativa de eliminar una clave que todavía protege datos?

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar todas las respuestas con explicaciones</strong></summary>

### Bloque 0

**A0.1** — Las Regiones introducidas después del 20 de marzo de 2019 son **opt-in**: deshabilitadas por defecto, y no se puede hacer ninguna llamada a API de ningún tipo en ellas hasta que la cuenta habilite explícitamente la Región. Una Región deshabilitada es, por lo tanto, una frontera *dura* de residencia de datos — no se puede crear ningún recurso ahí, y no se pueden almacenar datos ahí, sin importar lo que digan las políticas de IAM. Es un control de gobernanza porque restringe el radio de impacto de la cuenta y su huella geográfica a nivel de cuenta, por encima de IAM. Habilitar una Región opt-in es un acto deliberado y auditado (`account:EnableRegion`), y por eso una SCP que lo deniegue es una barrera común en una landing zone. Es una defensa tanto contra la proliferación de recursos por parte de un atacante (instancias de minería en `ap-east-1` donde nadie está mirando CloudWatch) como contra violaciones accidentales de residencia.

**A0.2** — Rotar la clave de acceso es responsabilidad **del cliente**: las credenciales, las identidades y su ciclo de vida son gestionadas por el cliente bajo "seguridad *en* la nube". Parchear, escalar y asegurar el propio servicio STS es responsabilidad **de AWS** bajo "seguridad *de* la nube". La línea divisoria acá es exacta: AWS garantiza que STS responde correctamente y que está disponible; vos garantizás que la credencial que se le presenta debería seguir existiendo.

**A0.3** — Fue a `us-east-1` (o a la Región que tenga por defecto tu perfil de la CLI; el endpoint global de la API de Account está anclado en `us-east-1`). Esto importa porque los servicios globales y cuasi-globales registran su actividad de API en `us-east-1`, así que una denegación ingenua con `aws:RequestedRegion` que solo liste `eu-west-1` va a romper IAM, Route 53, CloudFront, Organizations y STS en toda la cuenta. Precisamente por eso la SCP del Ejercicio 2 usa `NotAction` para excluirlos.

### Bloque 1

**A1.1** — **No.** AWS Artifact contiene los propios informes de auditoría de terceros de AWS sobre la infraestructura de AWS; no dice nada sobre tu bucket. El servicio que responde esto es **AWS Config**, cuyo historial de configuración e historial de evaluación de reglas registran cómo lucía cada recurso en cada punto del tiempo y si satisfacía `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED`. Esta es la frontera de responsabilidad compartida hecha literal: Artifact es evidencia de *seguridad de la nube*; Config es evidencia de *seguridad en la nube*. **AWS Audit Manager** se apoya sobre Config y empaqueta esa evidencia contra un marco con nombre.

**A1.2** — SOC 2 Type II es un informe detallado que describe el entorno de control de AWS, las pruebas del auditor y los resultados; es confidencial y se libera bajo NDA, que es lo que impone `acceptanceType: EXPLICIT`. **SOC 3** es el resumen público de uso general de la misma auditoría, no lleva NDA, y es el que podés publicar, compartir con prospectos o poner en tu sitio web. Entregarle a un prospecto el informe SOC 2 Type II incumple el NDA que aceptaste para descargarlo.

**A1.3** — Dos violaciones. Primero, el informe SOC 2 está bajo NDA — el token de término que canjeás en el paso 4 es tu aceptación de un acuerdo de confidencialidad, y republicar el documento lo incumple. Segundo, un bucket de S3 *público* lo pone a disposición de cualquiera en internet, lo que es divulgación no autorizada de material de auditoría confidencial de un tercero. El patrón correcto es dejar los informes en Artifact (ahí siempre están actualizados y las versiones superadas se retiran) y conceder `artifact:GetReport` a quienes los necesiten; si tenés que cachearlos, guardalos en un bucket privado, cifrado, con registro de accesos y un período de retención documentado.

**A1.4** — El **Business Associate Addendum (BAA) de AWS**, aceptado a través de AWS Artifact Agreements. Aceptarlo **no** hace que tu carga de trabajo cumpla con HIPAA. Establece las obligaciones contractuales de AWS como Business Associate y define los servicios elegibles para HIPAA que podés usar para PHI. El cumplimiento de la carga de trabajo sigue siendo enteramente tuyo: usar solo servicios elegibles para HIPAA, cifrar la PHI en reposo y en tránsito, controlar el acceso, registrar y retener rastros de auditoría. AWS nunca es "HIPAA compliant en tu nombre"; es un sustrato conforme sobre el que podés construir un sistema conforme.

### Bloque 2A

**A2.1** — Los nombres de bucket de S3 son globalmente únicos y la API de S3 acepta una solicitud dirigida a cualquier endpoint regional, respondiendo con un HTTP 307 Temporary Redirect (o enrutándola de forma transparente) hacia la Región de origen del bucket. Lo que viajó a `us-east-1` fueron los *metadatos de la solicitud*; los bytes del objeto se leyeron desde — y solo estuvieron almacenados en — `eu-west-1`. El plano de control es alcanzable globalmente; el plano de datos está atado a la Región. Si la solicitud hubiera devuelto contenido del objeto, ese contenido se habría servido *desde* `eu-west-1` a través de la redirección.

**A2.2** — **S3 Replication** (Cross-Region Replication, CRR), y en menor medida operaciones de copia explícitas, Multi-Region Access Points con replicación, o claves KMS multi-Región usadas para copias entre Regiones. El hecho de que la replicación deba configurarse explícitamente — y que `get-bucket-replication` devuelva `ReplicationConfigurationNotFoundError` cuando no lo está — es una afirmación positiva y auditable para una evaluación bajo los artículos 44–50 del GDPR: demuestra que no existe ningún mecanismo de transferencia a un tercer país. Combinalo con una SCP que deniegue `s3:PutBucketReplication` fuera de destinos aprobados y tenés un control preventivo, no solo una observación.

**A2.3** — **No.** S3 Standard almacena objetos de forma redundante en un mínimo de tres zonas de disponibilidad dentro de la Región, diseñado para una durabilidad del 99,999999999 % (once nueves). Esta es responsabilidad **de AWS** — la durabilidad de la infraestructura de almacenamiento es "seguridad de la nube". Notá la frontera: AWS garantiza que el objeto sobrevive a fallos de hardware y de AZ; AWS **no** te protege de *tu propia* eliminación. Eso es tuyo, y los controles son el versionado, MFA Delete, Object Lock y la política de ciclo de vida/respaldo.

### Bloque 2B

**A2.4** — Se rompen dos cosas. Sacar `sts:*` rompe la asunción de roles: `sts:AssumeRole` se evalúa en la Región que sirve el endpoint de STS, y si tus operadores asumen roles a través del endpoint global de STS en `us-east-1`, la denegación se dispara y **nadie puede autenticarse**. Sacar `iam:*` rompe toda la gestión de identidades, porque IAM es un servicio global cuyas llamadas se registran contra `us-east-1`; ya no podrías crear, modificar ni siquiera leer roles y políticas. Juntas producen el clásico auto-bloqueo: una SCP de bloqueo de Región aplicada a la raíz que deja la organización ingobernable.

**A2.5** — Se registran contra **`us-east-1`** (`N. Virginia`), que es donde residen los planos de control de IAM, Route 53, CloudFront, Organizations, WAF Classic, Shield y Support. En consecuencia, `aws:RequestedRegion` para esas llamadas se evalúa como `us-east-1`, así que cualquier denegación que no liste `us-east-1` — o que no exima esos servicios vía `NotAction` — los va a bloquear. Este es el defecto más común en las SCP de bloqueo de Región escritas a mano.

**A2.6** — **No, la instancia no puede lanzarse.** La evaluación de políticas de IAM es: un `Deny` explícito en *cualquier* política aplicable siempre gana, y las SCP son políticas aplicables para las cuentas miembro. El orden completo es (1) denegación explícita en cualquier lado → denegado; (2) si no, la solicitud debe estar permitida por una SCP *y* por una política de identidad o de recurso; (3) si no, denegación implícita. Una SCP solo puede restar; nunca concede. Así que el `Allow` de la política de identidad es irrelevante una vez que el `Deny` de la SCP coincide.

**A2.7** — **No.** Las SCP nunca se aplican a la **cuenta de gestión** de la organización, ni siquiera cuando la cuenta de gestión está dentro de una OU que tiene la política adjunta. Operativamente, esto significa que la cuenta de gestión es una excepción permanente a cada barrera que construyas — que es exactamente por qué AWS recomienda no correr cargas de trabajo en ella, limitar su uso a la administración de la organización y la facturación, restringir estrictamente quién puede acceder a ella y aplicarle MFA. Cualquier control del que dependas para cumplimiento debe verificarse como *no* dependiente de la cuenta de gestión para su aplicación.

### Bloque 2C

**A2.8** — La frase distingue una denegación de SCP de una carencia de permisos de IAM. Un operador que ve `explicit deny in a service control policy` sabe de inmediato que la solución no es "agregarle una política a mi usuario" — ningún permiso basado en identidad puede anularla — sino "la Región o acción de destino está fuera de la política organizacional; escalar al equipo de gobernanza de la nube". Sin esa cadena, el mismo `UnauthorizedOperation` los mandaría a una cacería infructuosa de depuración de IAM. Para ver quién más está chocando contra ella, consultá **AWS CloudTrail**: las llamadas denegadas se registran con `errorCode: AccessDenied` / `UnauthorizedOperation` y la `userIdentity` completa, así que `lookup-events` o una consulta de CloudWatch Logs Insights sobre el trail muestra el patrón de quién está intentando trabajar fuera del límite — que a menudo revela una necesidad de negocio legítima o una credencial comprometida.

**A2.9** — Una SCP define los **permisos máximos disponibles** para los principales de las cuentas afectadas. Los permisos efectivos de un principal son la *intersección* de lo que sus políticas basadas en identidad (y en recursos) permiten con lo que el límite de la SCP permite. Una SCP por sí sola no concede nada: un principal con una SCP que permite todo y sin política de IAM no puede hacer nada. El modelo mental es un techo, no un piso.

### Bloque 3A

**A3.1** — No. En una política de clave de KMS, `arn:aws:iam::111122223333:root` **no** significa el usuario raíz específicamente; significa "esta cuenta de AWS", y delega la autorización de la clave al sistema de IAM de la cuenta. En la práctica: cualquier principal de la cuenta `111122223333` cuya *política de IAM* le conceda `kms:Decrypt` sobre este ARN de clave puede descifrar con ella. Esta es la fuente del error conceptual más común sobre KMS. Notá la asimetría: sin esa declaración, las políticas de IAM no tienen ningún efecto sobre la clave — la política de clave es la raíz de confianza, y una clave con una política de clave vacía es inutilizable por cualquiera y queda efectivamente inservible.

**A3.2** — Con una **clave administrada por el cliente** ganás: (1) control total de la política de clave y de las concesiones (grants), incluido el acceso entre cuentas; (2) control sobre el calendario de rotación, la habilitación/deshabilitación y la eliminación; y además visibilidad específica de la clave en CloudTrail, alias, etiquetado y material de clave importado. El costo es **$1/mes por clave** más cargos de API por solicitud — una clave administrada por AWS (`aws/s3`) no tiene cargo mensual por clave. La regla de decisión práctica: usá una CMK cuando necesites compartir entre cuentas, una política de clave auditable, revocación independiente ("triturado criptográfico" deshabilitando la clave), o un requisito de cumplimiento de demostrar control del cliente sobre el material de clave.

**A3.3** — **Sí.** La rotación automática de KMS crea *material de clave de respaldo nuevo* mientras retiene todas las claves de respaldo anteriores durante toda la vida de la CMK. El ID y el ARN de la clave no cambian, así que las aplicaciones no necesitan actualización. Cada blob de texto cifrado registra qué clave de respaldo lo cifró, y KMS selecciona la correcta al descifrar. La rotación solo afecta a las operaciones de cifrado *nuevas*. Esta es también la razón por la que eliminar una CMK es destructivo de una forma que la rotación no lo es: la rotación preserva todas las claves de respaldo; la eliminación las destruye todas.

### Bloque 3B

**A3.4** — Solo la **clave de datos** cruzó la red: una clave AES-256 de 32 bytes que sale como ~44 caracteres en base64 y un blob envuelto de ~240 bytes que vuelve — del orden de unos pocos cientos de bytes, sin importar si la carga útil es de 46 bytes o de 400 GB. La API `Encrypt` de KMS está limitada a **4 KB** de texto plano precisamente porque no es un camino de datos masivos. El cifrado de sobre resuelve tres problemas a la vez: elimina el límite de tamaño, elimina los viajes de red y la latencia proporcionales al volumen de datos, y elimina el costo por byte de solicitudes a KMS. La operación cara, auditada y respaldada por hardware ocurre una vez por clave de datos; la operación barata, local y de alto rendimiento ocurre sobre los datos masivos.

**A3.5** — Un blob de texto cifrado de KMS es autodescriptivo: embebe el **ARN de la clave** (y la versión específica de la clave de respaldo), el algoritmo de cifrado y cualquier contexto de cifrado, junto al material de clave envuelto. Por eso `Decrypt` no necesita `--key-id`. La propiedad de auditoría que se sigue es fuerte: dado solo una clave de datos envuelta almacenada, podés determinar exactamente qué CMK la protege, y cada llamada a `Decrypt` se registra en CloudTrail contra ese ARN de clave — así que obtenés un registro completo y no repudiable de quién desenvolvió qué clave y cuándo. (Especificar `--key-id` al descifrar sigue siendo buena práctica para claves simétricas: hace que KMS *verifique* la clave esperada en lugar de confiar en el blob, derrotando toda una clase de ataque de diputado confundido.)

**A3.6** — Todavía necesitan la **clave de datos en texto plano**, que no existe en ningún disco — hay que obtenerla llamando a `kms:Decrypt` sobre el blob envuelto. El control que decide si la consiguen es la combinación de la **política de clave de KMS y la política de IAM** del principal como el que puedan autenticarse (más cualquier grant, y las SCP por encima). Si el atacante no tiene credenciales de AWS válidas con `kms:Decrypt` sobre esa clave, los archivos son criptográficamente inertes. Y como cada intento es una llamada a la API de KMS registrada, un intento fallido es un evento detectable — este es el argumento práctico a favor del cifrado de sobre frente a una frase de paso derivada localmente: la decisión de autorización está centralizada, es revocable y está auditada.

### Bloque 3C

**A3.7** — `s3:GetObject` sobre `arn:aws:s3:::<bucket>/records.csv`, y `kms:Decrypt` sobre el ARN de la CMK. Viven en dos documentos distintos: el permiso de S3 viene de tu **política de identidad de IAM** (o de la política del bucket), mientras que el permiso de KMS debe satisfacerse mediante la **política de clave de KMS** — ya sea directamente, o por la declaración `root` de la política de clave que delega en IAM más una concesión de IAM correspondiente. Por eso "tengo acceso total a S3 pero me da `AccessDenied` en un objeto cifrado con KMS" es un caso de soporte tan frecuente: el permiso sobre el bucket es necesario pero no suficiente. También es una *funcionalidad* — te permite usar la política de clave como una segunda puerta de autorización independiente sobre datos sensibles.

**A3.8** — Sin un Bucket Key, S3 llama a `kms:GenerateDataKey` (escritura) o a `kms:Decrypt` (lectura) **una vez por operación de objeto**. Con `BucketKeyEnabled: true`, S3 le pide a KMS una vez una clave de vida corta a nivel de bucket, y después usa esa clave de bucket localmente para derivar claves de datos por objeto durante una ventana limitada en el tiempo. El volumen de solicitudes a KMS colapsa de una llamada por objeto a un puñado de llamadas por bucket por intervalo — hasta un 99 % de reducción en los cargos de API de KMS, con una caída correspondiente en la latencia y en la presión sobre la cuota de tasa de solicitudes de KMS. El compromiso a entender: CloudTrail entonces registra las llamadas a KMS a nivel de clave de bucket en lugar de una línea por objeto, así que se reduce la granularidad de auditoría de KMS por objeto.

**A3.9** — "¿Los datos están cifrados en reposo?" — **Sí, demostrablemente, por tu propia configuración**: `head-object` devuelve `ServerSideEncryption: aws:kms` con un ARN de clave específico, y la regla `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED` de AWS Config lo atesta continuamente. Esa afirmación descansa en evidencia que generás vos. "¿Puedo probar que el personal de AWS no los puede leer?" — esto descansa en un **tipo distinto de evidencia**: el propio entorno de control de AWS, la investigación de antecedentes del personal, el acceso de mínimo privilegio de los operadores y la separación de funciones, auditados por terceros y publicados como informes SOC 2 / ISO 27001 en **AWS Artifact**. No podés probarlo desde la CLI. La respuesta arquitectónica honesta es que los HSM validados FIPS de KMS implican que ningún empleado de AWS tiene acceso en texto plano a tu material de clave, y esa afirmación se valida mediante las atestaciones, no mediante tu configuración. Si el regulador no acepta una atestación de un tercero, la respuesta es **AWS CloudHSM** o material de clave custodiado externamente.

**A3.10** — **SSE-S3 (`AES256`)** usa claves que AWS gestiona por completo; no podés verlas, ni controlar el acceso a ellas de forma independiente, ni auditar su uso por solicitud, ni revocarlas — es gratis y de esfuerzo cero. **SSE-KMS (`aws:kms`)** usa una clave de KMS que controlás vos, lo que te da una política de clave independiente, entradas en CloudTrail por solicitud para cada cifrado/descifrado, rotación controlable, y la capacidad de revocar de un golpe el acceso a todos los datos protegidos por esa clave. **DSSE-KMS** aplica dos capas independientes de cifrado AES-256-GCM al mismo objeto, para regímenes (notablemente ciertas clasificaciones de seguridad nacional y defensa de EE. UU.) que exigen dos capas de cifrado validado FIPS. Un regulador te fuerza a abandonar SSE-S3 en el momento en que el requisito incluye alguno de estos: control demostrable del cliente sobre las claves, auditoría criptográfica de acceso por objeto, separación de funciones entre el administrador de almacenamiento y el administrador de claves, o una política de rotación de claves definida — ninguno de los cuales SSE-S3 puede evidenciar.

### Bloque 4

**A4.1** — El **cifrado en reposo** protege contra un adversario que obtiene los bytes persistidos — un disco robado, una unidad dada de baja y rescatada de la basura, un respaldo mal desechado, o acceso no autorizado a la capa de almacenamiento. El **cifrado en tránsito** protege contra un adversario posicionado en el camino de red — capaz de observar o modificar el tráfico entre el cliente y el servicio. El paso 1 quedó expuesto a un ataque de **hombre en el medio / interceptación pasiva**: el encabezado `Authorization` de SigV4 de AWS, el token de sesión, el nombre del bucket y la clave del objeto, y los metadatos de la respuesta, todos atravesaron la red en texto claro. Aunque las firmas SigV4 no son directamente reproducibles para solicitudes arbitrarias, exponerlas junto con los tokens de sesión en una red no confiable es un evento de divulgación de credenciales.

**A4.2** — Con `Effect: Deny`, un `Principal` comodín significa "denegar a *todos* los que cumplan estas condiciones" — que es exactamente la intención de un control de tránsito. Cualquier cosa más estrecha deja un agujero: una lista específica de principales permitiría que cualquier identidad no listada, incluido un futuro rol entre cuentas o una solicitud anónima, llegara al bucket por HTTP. En una declaración `Allow`, `"Principal": "*"` significa "conceder a todo el mundo en internet, sin autenticación" — la desconfiguración canónica que provoca filtraciones de datos en S3. La asimetría es todo el punto: los comodines en una denegación son conservadores; los comodines en un permiso son catastróficos.

**A4.3** — El certificado del paso 5 está en el **endpoint del servicio S3 de AWS**, así que lo renueva **AWS** — eso es seguridad *de* la nube, y es invisible para vos. El certificado de ACM del paso 6 se emitió para *tu* dominio y *tu* endpoint. Igual lo renueva AWS automáticamente siempre que se cumplan dos responsabilidades del cliente: que el certificado siga **asociado a un servicio integrado** (CloudFront, ALB/NLB, API Gateway) y que el registro de validación de dominio siga en su lugar (el CNAME para la validación por DNS debe permanecer en tu hosted zone). Si borrás el CNAME de validación o desasociás el certificado, la renovación falla y el vencimiento es tuyo. Entonces: AWS ejecuta la renovación, vos mantenés las precondiciones para que ocurra.

**A4.4** — **AWS CloudHSM.** Te da HSM dedicados de un solo inquilino en tu VPC, validados según FIPS 140-3 Nivel 3, donde vos — no AWS — sos el oficial de criptografía. AWS gestiona el hardware, el aprovisionamiento y la salud del clúster, pero **no tiene acceso al material de clave**. La responsabilidad que se te transfiere es sustancial y a menudo se subestima: vos generás y gestionás todos los usuarios y credenciales, sos el único responsable del **respaldo y la recuperación del material de clave**, gestionás el dimensionamiento del clúster y la alta disponibilidad entre AZ, y manejás la integración con la aplicación a través de PKCS#11/JCE/CNG en lugar de una API simple de AWS. Crucialmente, **si perdés tus credenciales de CloudHSM o todas las copias del clúster, AWS no puede recuperar tus claves y los datos quedan permanentemente irrecuperables.** Ese riesgo es el precio del control exclusivo.

**A4.5** — **ACM** es la respuesta. Aprovisiona certificados TLS públicos sin cargo, los despliega en CloudFront/ALB/NLB/API Gateway, y los renueva automáticamente — cero trabajo de renovación es su objetivo de diseño explícito. **KMS** es incorrecto porque gestiona claves de cifrado para datos, no certificados X.509 para endpoints TLS; no tiene ningún rol en un handshake TLS con un navegador. **CloudHSM** es incorrecto porque es un dispositivo de *almacenamiento* de claves, no una autoridad de certificación ni un gestor del ciclo de vida de certificados — te obligaría a construir vos mismo toda la cadena de emisión, despliegue y renovación, y cuesta cientos de dólares al mes para resolver un problema que ACM resuelve gratis. (El rol legítimo de CloudHSM acá sería como HSM de respaldo para **AWS Private CA** cuando necesitás controlar la clave raíz de la CA — un requisito distinto.)

### Bloque 5

**A5.1** — Un trail creado pero nunca iniciado no produce **ningún registro** mientras aparece correctamente configurado en la lista de trails de la consola. El fallo realista: ocurre un incidente seis meses después, el equipo de seguridad va a reconstruir las acciones del atacante, y encuentra un prefijo de S3 vacío — todo el registro probatorio de ese período no existe y no puede recrearse. Los auditores tratan esto como un fallo de control para todo el período, no solo hacia adelante. La llamada a API que lo detecta es **`aws cloudtrail get-trail-status`**, cuyo campo `IsLogging` es la señal autoritativa; `LatestDeliveryTime` y `LatestDeliveryError` confirman que la entrega está funcionando de verdad. En la práctica también lo monitoreás con la regla de AWS Config `cloudtrail-enabled` / `multi-region-cloudtrail-enabled` y el control CIS de Security Hub, de modo que un trail detenido levanta un hallazgo en lugar de esperar a ser descubierto.

**A5.2** — **Financiera:** los eventos de gestión para la primera copia de un trail se entregan gratis, mientras que los eventos de datos se cobran por evento registrado. Un bucket de S3 o una tabla de DynamoDB con mucho tráfico generan millones de eventos de datos por día, así que hacerlos opt-in evita una factura enorme y sorpresiva. **Volumen:** los eventos de gestión describen operaciones del plano de control — crear, modificar, eliminar recursos — que son relativamente raras y casi siempre relevantes para la seguridad. Los eventos de datos describen lecturas y escrituras individuales de objetos, que son el tráfico operativo normal de la aplicación; registrarlos todos enterraría la señal relevante para la seguridad bajo órdenes de magnitud más de ruido rutinario, y desbordaría el análisis posterior. La práctica correcta es exactamente lo que hace el paso 4: habilitar eventos de datos de forma acotada, sobre los recursos sensibles específicos donde el acceso a nivel de objeto es en sí mismo lo que necesitás auditar.

**A5.3** — La validación de archivos de registro de CloudTrail funciona en dos capas. Cada archivo de registro entregado se hashea (SHA-256). Cada hora, CloudTrail escribe un **archivo de resumen (digest)** que contiene los hashes de todos los archivos de registro entregados en ese período, más el hash del archivo de resumen *anterior*, y firma el resumen con una clave privada en poder de AWS (RSA con SHA-256). Esto produce una cadena de hashes: los resúmenes están encadenados entre sí, y los archivos de registro están anclados a los resúmenes. Modificar un archivo de registro cambia su hash, así que ya no coincide con el valor registrado en el resumen firmado — que es exactamente el resultado `INVALID: hash value doesn't match` que viste, mientras la cadena de resúmenes en sí quedó intacta y verificable. Eliminar un archivo de registro produciría un error de archivo faltante contra el resumen; manipular un resumen rompe su firma y la cadena hacia el siguiente resumen. **La validación detecta la manipulación; no la impide.** La prevención es un conjunto separado de controles: S3 Object Lock en modo compliance, SSE-KMS con una política de clave restrictiva, MFA Delete, una política de bucket que deniegue `s3:DeleteObject`, y entregar el trail a una cuenta dedicada de archivo de registros a la que los administradores de la aplicación no puedan llegar.

**A5.4** — **`sourceIPAddress`** responde *desde dónde* — ¿se hizo esta acción desde la red corporativa, desde un bastión conocido, desde un país inesperado, o desde un nodo de salida de Tor? Es el campo que sustenta las afirmaciones de cumplimiento geográfico y de límite de red, y es central para detectar el uso de credenciales robadas. **`userAgent`** responde *por qué medio* — la consola, una versión específica del SDK de AWS, la CLI, o una herramienta no reconocida; un cambio repentino de user agent para una cuenta de servicio es un indicador clásico de compromiso. Ninguno de los dos campos, por sí solo, distingue un ataque del trabajo rutinario; CloudTrail es un **registro**, no un **detector**. Combinalo con **Amazon GuardDuty**, que consume directamente el flujo de eventos de gestión de CloudTrail y aplica inteligencia de amenazas, detección de anomalías y aprendizaje automático para levantar hallazgos como `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` o `Discovery:IAMUser/AnomalousBehavior`. **Amazon Detective** después reconstruye el grafo de comportamiento circundante para la investigación.

**A5.5** — **CloudTrail** registra *actividad de API*: quién llamó a qué API, cuándo, desde dónde, con qué parámetros y si tuvo éxito. **CloudWatch** registra *telemetría operativa*: métricas, registros y eventos que describen cómo están rindiendo los recursos y las aplicaciones y qué emitieron.

| Ítem | Servicio |
|---|---|
| Una llamada a API que eliminó un grupo de seguridad | **CloudTrail** |
| Utilización de CPU al 94 % | **CloudWatch** (métricas) |
| La salida de un `print()` de una función Lambda | **CloudWatch** (Logs) |
| La identidad que deshabilitó una clave de KMS | **CloudTrail** |

La heurística confiable: si la pregunta empieza con **"quién"**, es CloudTrail. Si empieza con **"cuánto", "qué tan rápido" o "qué dijo"**, es CloudWatch.

### Bloque 6

**A6.1** — Responde **"¿cuál era la configuración de este recurso en el momento T, y cómo cambió a lo largo del tiempo?"** — el estado en un punto del tiempo y la línea de tiempo completa de mutaciones del recurso en sí. CloudTrail registra que ocurrió una llamada `PutBucketEncryption` pero no te da el *estado del recurso* resultante, y reconstruir el estado reproduciendo cada llamada a API es impracticable e incompleto. AWS Artifact no dice nada sobre tus recursos en absoluto. Config produce la línea de tiempo de elementos de configuración, las relaciones entre recursos y — con reglas — el veredicto de cumplimiento en cada punto. Esta es precisamente la evidencia que un auditor pide para una afirmación de "aplicado de forma continua durante 12 meses", y es por eso que Config sustenta a AWS Audit Manager.

**A6.2** — La alternativa es **`"Owner": "CUSTOMER_LAMBDA"`** (o `CUSTOM_POLICY` para reglas basadas en Guard). Una regla Lambda personalizada requiere que escribas, despliegues, permisiones, monitorees, versiones y mantengas una función Lambda que recibe elementos de configuración y devuelve evaluaciones `COMPLIANT` / `NON_COMPLIANT` / `NOT_APPLICABLE` — ingeniería real con sus propios modos de fallo. Las reglas administradas por AWS vienen preconstruidas, mantenidas y actualizadas por AWS, requieren solo un nombre de regla y un alcance, y cubren varios cientos de comprobaciones comunes. Los objetivos del examen las enfatizan porque un Cloud Practitioner debería reconocer que la gran mayoría de las comprobaciones de cumplimiento son una decisión de *configuración*, no un proyecto de *desarrollo* — el instinto correcto es buscar primero una regla administrada o un conformance pack, y escribir lógica personalizada solo para controles específicos de la organización que AWS no podría anticipar.

**A6.3** — `S3_BUCKET_SSL_REQUESTS_ONLY` inspecciona la **política del bucket** y busca una declaración que deniegue solicitudes donde `aws:SecureTransport` sea `false`. El bucket de evidencia tenía exactamente esa declaración, agregada en el Ejercicio 4; los buckets del trail y de Config tenían políticas de bucket que concedían acceso de escritura a CloudTrail y a Config pero ninguna denegación de tránsito, así que fallaron. La lección general es importante: una regla de Config evalúa una **propiedad específica y declarada** de un recurso, no una noción vaga de "¿es seguro?". Leé la lógica documentada de la regla administrada antes de confiar en un veredicto `COMPLIANT` — la regla prueba lo que dice que prueba y nada más. También es un recordatorio de que los buckets de registros son almacenes de datos de producción sujetos a los mismos controles que cualquier otro bucket, y que se olvidan rutinariamente.

**A6.4** — Un **conformance pack** es una colección desplegable de reglas de AWS Config y acciones de remediación, empaquetadas como una única plantilla YAML, que puede desplegarse en una cuenta o en toda una organización de AWS en una sola operación. AWS publica paquetes de muestra mapeados a PCI DSS, HIPAA, CIS, NIST 800-53, ISO 27001 y otros. Las razones para preferir uno sobre 60 llamadas individuales a la API son: es un único artefacto versionado bajo control de código fuente; se despliega atómicamente y puede revertirse atómicamente; reporta una única puntuación de cumplimiento agregada para el marco; puede desplegarse en toda la organización desde la cuenta de gestión o desde la cuenta de administrador delegado en lugar de cuenta por cuenta; y lleva el mapeo del marco como metadatos, así que la evidencia ya viene etiquetada con el control que satisface cuando el auditor pregunta.

**A6.5** — (a) **AWS Config** — historial de configuración y línea de tiempo de cambios de un recurso. (b) **AWS CloudTrail** — la identidad, la marca de tiempo y la IP de origen de la llamada a API. (c) **AWS Artifact** — las propias certificaciones y atestaciones de terceros de AWS.

### Bloque 7A

**A7.1** — GuardDuty consume el flujo de eventos de gestión de CloudTrail, los VPC Flow Logs y los registros de consultas DNS de Route 53 Resolver **directamente de los productores del servicio, fuera de banda**. No lee tus buckets de registros de S3, y no requiere que tengas un trail, un flow log ni el registro de consultas habilitado en absoluto. De ahí se siguen dos consecuencias. **Costo:** no te cobran dos veces — el propio precio de GuardDuty cubre el análisis, y no pagás cargos de CloudTrail/VPC Flow Logs/registro de Route 53 por la copia de datos de GuardDuty. **Seguridad:** un atacante que borre tu trail de CloudTrail, vacíe tu bucket de registros o deshabilite los flow logs **no deja ciego a GuardDuty** — y de hecho el acto de detener un trail genera un hallazgo propio de GuardDuty (`Stealth:IAMUser/CloudTrailLoggingDisabled`). La ingesta fuera de banda es un diseño anti-manipulación deliberado.

**A7.2** — Porque el usuario raíz tiene poder irrestricto e irrestringible sobre la cuenta: puede cerrar la cuenta, cambiar el contacto y el email raíz de la cuenta, modificar la facturación, sacar la cuenta de una organización y — crucialmente — **no está limitado por SCP, límites de permisos ni políticas de IAM**. Cada control de gobernanza que construiste asume que root no se está usando. Las cuentas bien administradas guardan las credenciales raíz con MFA por hardware en un proceso de emergencia invocado quizá una vez al año, así que *cualquier* uso de una credencial raíz es o bien un evento raro, preanunciado y auditado, o bien un compromiso activo. La severidad en GuardDuty refleja la confianza y el impacto técnico de la señal, no la política de tu organización — que es exactamente por qué los equipos enrutan este hallazgo a un canal de alta prioridad vía EventBridge sin importar su etiqueta. La misma lógica subyace al control del benchmark CIS y a la comprobación "MFA on Root Account" de Trusted Advisor.

**A7.3** — **No.** GuardDuty es un servicio de detección de amenazas *conductual*: analiza telemetría de red, DNS y API para detectar actividad que indique compromiso o reconocimiento. No inspecciona el software instalado en una instancia. El servicio que encuentra `log4j` es **Amazon Inspector**, que realiza escaneo continuo de vulnerabilidades —sin agente o basado en SSM— de instancias EC2, imágenes de contenedor en ECR, y funciones y capas de Lambda, cotejando los paquetes instalados contra bases de datos de CVE. La distinción limpia: **Inspector encuentra la ventana sin trabar antes de que alguien entre por ella; GuardDuty nota a alguien entrando por ella.**

### Bloque 7B

**A7.4** —

| Pregunta | Servicio | Ingiere |
|---|---|---|
| ¿Hay un CVE en los paquetes del SO de mi flota EC2 o en mis imágenes de contenedor? | **Amazon Inspector** | Inventario de software desde el agente de SSM / escaneo sin agente de instantáneas EBS, capas de imágenes de ECR, paquetes y capas de funciones Lambda — cotejados contra fuentes de CVE |
| ¿Hay información de identificación personal alojada en mis buckets de S3? | **Amazon Macie** | Contenido de objetos de S3, muestreado y clasificado con identificadores de datos administrados y personalizados, más el inventario de buckets de S3 y su postura de acceso público |
| ¿Hay una credencial comprometida exfiltrando datos ahora mismo? | **Amazon GuardDuty** | Eventos de gestión y de datos de S3 de CloudTrail, VPC Flow Logs, registros de consultas DNS de Route 53 Resolver (opcionalmente registros de auditoría de EKS, eventos de inicio de sesión de RDS, volúmenes EBS para malware) |
| ¿Dónde aparecen todos los anteriores en una sola pantalla, puntuados contra CIS y PCI? | **AWS Security Hub** | Hallazgos en ASFF de GuardDuty, Inspector, Macie, IAM Access Analyzer, Firewall Manager, Config, Systems Manager Patch Manager y productos de socios — además de sus propias comprobaciones de control |
| ¿Qué otros recursos tocó este rol comprometido en los últimos 90 días? | **Amazon Detective** | La misma telemetría que GuardDuty (CloudTrail, VPC Flow Logs, hallazgos de GuardDuty, registros de auditoría de EKS), preprocesada en un **grafo de comportamiento** enlazado con hasta un año de historia |

**A7.5** — Los 31 hallazgos con `ProductName: Security Hub` los generan las **propias comprobaciones de controles de seguridad** de Security Hub — las evaluaciones automatizadas detrás de los estándares habilitados (AWS Foundational Security Best Practices, benchmark CIS, PCI DSS), que se ejecutan contra las configuraciones de tus recursos en gran medida sobre AWS Config. Los 3 hallazgos de GuardDuty se *ingieren* de otro servicio. La distinción importa porque parte en dos el rol de Security Hub: es un **servicio de gestión de postura / puntuación de cumplimiento** por derecho propio (comprobar la configuración contra benchmarks — ¿está trabada la puerta?), **y** es la **capa de agregación y normalización** de hallazgos de detección producidos en otro lado (¿hay alguien en la puerta?). Llamarlo servicio de detección confunde ambas cosas y lleva a los equipos a creer que habilitar Security Hub les da detección de amenazas — no se la da; eso todavía requiere GuardDuty. La afirmación precisa es que Security Hub *comprueba la postura y agrega hallazgos*; no analiza telemetría de amenazas.

**A7.6** — Los marcos de cumplimiento se solapan mucho a nivel de control técnico: "no expongas el almacenamiento públicamente" aparece en CIS, PCI DSS, las salvaguardas de HIPAA, el Anexo A de ISO 27001 y NIST 800-53 bajo cinco identificadores distintos. Mapear una comprobación automatizada a todos ellos significa que (1) **implementás y monitoreás una vez** en lugar de mantener conjuntos de controles paralelos por marco; (2) una única remediación mejora tu postura contra todos los marcos simultáneamente, lo cual se ve en las puntuaciones; (3) cuando un auditor pide evidencia de PCI DSS 1.2.1, podés producir el historial de hallazgos del control S3.8 directamente en lugar de armarlo a mano; y (4) agregar un marco nuevo se vuelve mayormente un ejercicio de mapeo sobre controles que ya ejecutás, no un programa de ingeniería nuevo. Esta tabla de correspondencias es precisamente el valor que AWS Audit Manager empaqueta y automatiza.

**A7.7** — Macie responde **"¿qué datos personales tengo realmente, y dónde?"** — el artículo 30 del GDPR exige registros de las actividades de tratamiento, y no podés producirlos si no sabés qué buckets contienen `NATIONAL_IDENTIFICATION_NUMBER_ES` o `DATE_OF_BIRTH`. La barrera de residencia del Ejercicio 2 responde **"¿y se queda dentro del EEE?"** — el Capítulo V rige las transferencias a terceros países. Juntos forman una narrativa de control completa y evidenciada: Macie aporta el *descubrimiento y la clasificación* (sabemos exactamente qué objetos contienen datos personales, de forma continua, no a partir de una planilla desactualizada); la SCP más la ausencia de configuración de replicación aporta la *aplicación preventiva de la residencia* (no existe mecanismo para moverlos, y cualquier intento se deniega y se registra); Config aporta la *verificación continua* del cifrado y los controles de acceso de esos buckets; y CloudTrail aporta el *registro de accesos* de cada objeto. Cada pieza es débil por sí sola — saber dónde están los datos sin controlar adónde van, o controlar la residencia sin saber qué tenés, ambas fallan una auditoría.

**A7.8** — **GuardDuty → Security Hub → Detective → CloudTrail.**
1. **GuardDuty** levantó el hallazgo; lo abrís primero para leer el tipo específico de hallazgo, la severidad, la instancia afectada, la IP remota y el contexto de inteligencia de amenazas que lo disparó.
2. **Security Hub** inmediatamente después, para ver si esta instancia o cuenta tiene hallazgos *relacionados* — un CVE sin parchear de Inspector, una comprobación de control fallida por un grupo de seguridad demasiado permisivo, un bucket de S3 público — que en conjunto sugieren el vector de acceso inicial y el radio de impacto. Este es el paso de correlación que convierte una alerta en un panorama.
3. **Detective**, para pivotear hacia el grafo de comportamiento: qué hizo el rol de IAM de esta instancia antes y después del hallazgo, qué otros recursos tocó, qué llamadas a API fueron inusuales para este principal, y hasta cuándo se remonta en realidad el comportamiento anómalo. Detective responde preguntas de alcance que un solo hallazgo no puede.
4. **CloudTrail** al final, para la verdad forense de base — los registros de eventos exactos, sin agregar y firmados, con los parámetros completos de la solicitud, necesarios para el informe del incidente, para la notificación legal o regulatoria, y para todo lo que la vista resumida de Detective no resuelva.

El principio: pasar de **alerta** (algo está mal) a **correlación** (qué más está mal cerca) a **investigación** (hasta dónde llega) a **evidencia** (qué pasó exactamente, de forma defendible).

### Bloque 8

**A8.1** — **AWS Organizations** es el servicio multicuenta fundacional: crea la organización, la jerarquía de OU y la facturación consolidada, y es donde se adjuntan las SCP, las políticas de etiquetas y las políticas de respaldo. **AWS Control Tower** es una capa de orquestación *por encima de* Organizations: monta una landing zone prescriptiva y bien arquitecturada — una estructura multicuenta con una OU de Seguridad y una OU de Sandbox, cuentas de archivo de registros y de auditoría, AWS IAM Identity Center para acceso federado, CloudTrail y Config centralizados, y un catálogo curado de **controles** (antes "guardrails", implementados como SCP para los controles preventivos y como reglas de Config para los detectivos) — y aporta Account Factory para el aprovisionamiento gobernado de cuentas. **No, no podés usar Control Tower sin Organizations**: Control Tower requiere una organización y crea una si no existe ninguna. La relación es la de motor y chasis — Organizations aporta el mecanismo, Control Tower aporta el ensamblado opinado, automatizado y con detección continua de desvío.

**A8.2** — **No.** Desplegar el framework no hace que nada cumpla. Lo que produce es **recolección de evidencia automatizada y continua**: Audit Manager mapea cada uno de esos 134 controles a fuentes de evidencia — evaluaciones de reglas de AWS Config, hallazgos de Security Hub, eventos de CloudTrail y resultados de llamadas a la API de AWS — y recolecta, marca temporalmente y organiza continuamente esa evidencia en un **informe de evaluación** que se le puede entregar a un auditor. Reemplaza el ejercicio manual trimestral de juntar capturas de pantalla. Lo que explícitamente **no** hace es afirmar cumplimiento ni emitir un juicio: los mapeos de control del framework son una sugerencia de AWS, no una certificación; muchos controles requieren evidencia manual que subís vos; y **vos seguís siendo plenamente responsable** del cumplimiento de tu carga de trabajo, de validar que la evidencia recolectada efectivamente satisface a tu auditor, y de los controles que el framework no cubre. Solo un auditor externo acreditado puede atestar el cumplimiento.

**A8.3** — Las cinco categorías son **Optimización de costos, Rendimiento, Seguridad, Tolerancia a fallos y Límites de servicio** (Service Quotas). En los planes de soporte **Basic y Developer** obtenés la categoría completa de **Límites de servicio** más un conjunto pequeño de comprobaciones de seguridad centrales — históricamente: Security Groups – Specific Ports Unrestricted, IAM Use, MFA on Root Account, Amazon S3 Bucket Permissions, Amazon EBS Public Snapshots, Amazon RDS Public Snapshots. El conjunto completo de comprobaciones en las cinco categorías, junto con la **API** de Trusted Advisor (`aws support describe-trusted-advisor-checks`), la actualización programática y la integración de notificaciones, requiere soporte **Business, Enterprise On-Ramp o Enterprise**. El encuadre relevante para el examen: Trusted Advisor es el asesor proactivo de buenas prácticas a lo largo de los pilares del Well-Architected, y su profundidad es función de tu plan de soporte.

**A8.4** — Las políticas de etiquetas **estandarizan las etiquetas en sí** — definen qué claves de etiqueta se permiten, la capitalización exacta de esas claves y el conjunto de valores permitidos, y reportan los recursos no conformes en toda la organización. Una SCP no puede hacer esto: una SCP puede denegar una llamada `RunInstances` que carezca de una etiqueta `CostCenter` (vía la clave de condición `aws:RequestTag`), pero no puede exigir que la clave se escriba `CostCenter` y no `costcenter` o `Cost_Center`, no puede restringir el *valor* a un vocabulario controlado a escala, ni puede reportar el desvío de recursos etiquetados antes de que la política existiera. El uso concreto de cumplimiento es la **clasificación de datos**: una política de etiquetas que exija `DataClassification` ∈ {`Public`, `Internal`, `Confidential`, `Restricted`} en cada recurso, con reporte de cumplimiento en toda la organización, es lo que hace que los controles guiados por clasificación — políticas de respaldo, requisitos de cifrado, revisiones de acceso, asignación de costos por carga de trabajo regulada — sean realmente exigibles. Sin estandarización de claves, cada consulta posterior se pierde silenciosamente los recursos mal escritos.

**A8.5** — Usá el canal de **AWS Trust & Safety / reporte de abuso**: el formulario "Report Amazon AWS abuse" en AWS Support, o el correo a `abuse@amazonaws.com`, incluyendo marcas temporales en UTC, tus registros, IP y puertos de origen y destino. Bajo el modelo de responsabilidad compartida esta es una obligación **compartida** con un reparto claro: **vos** sos responsable de detectar la actividad contra tus recursos (el hallazgo `Recon:EC2/Portscan` de GuardDuty, VPC Flow Logs, ACL de red y grupos de seguridad para bloquearla) y de reportarla con evidencia; **AWS** es responsable de actuar sobre el reporte contra la cuenta infractora bajo la Política de Uso Aceptable de AWS y de proteger la infraestructura compartida. Notá el caso espejo: si el abuso se origina en *tu* cuenta, AWS te va a contactar y la remediación es enteramente tu responsabilidad.

**A8.6** —

| Ítem | Responsabilidad |
|---|---|
| Parcheo del hipervisor | **AWS** — seguridad *de* la nube |
| Parcheo del SO invitado (EC2) | **Cliente** — seguridad *en* la nube |
| Destrucción física de discos dados de baja | **AWS** — eliminación de medios en el centro de datos, evidenciada en los informes de Artifact |
| Configuración de la política de bucket de S3 | **Cliente** |
| Configuración de la política de clave de KMS | **Cliente** (AWS opera y asegura el servicio KMS y sus HSM) |
| Durabilidad de la capa de almacenamiento de S3 | **AWS** (el cliente decide sobre versionado, Object Lock, replicación y respaldo) |
| Aplicación de MFA a usuarios de IAM | **Cliente** |
| Protección DDoS del borde de la red global de AWS | **AWS** — AWS Shield Standard, incluido sin costo (la protección a nivel de aplicación vía Shield Advanced y AWS WAF es configuración del cliente) |

El patrón recurrente: AWS es dueño de la **infraestructura y de la seguridad del propio servicio**; el cliente es dueño de la **configuración, la identidad y los datos**. Para los servicios administrados la parte del cliente se achica — con S3 o DynamoDB nunca parcheás un SO — pero nunca desaparece, porque el control de acceso y la clasificación de datos siempre son tuyos.

### Bloque 9

**A9.1** — Porque la eliminación de una clave de KMS es **irreversible e irrecuperable**, y destruye no una clave sino todas las claves de respaldo creadas alguna vez por la rotación. Cada texto cifrado que esa clave protege — cada objeto de S3, volumen de EBS, instantánea de RDS, secreto de Secrets Manager, y cada clave de datos envuelta que esté en la base de datos de alguna aplicación — se vuelve permanentemente indescifrable. No hay escotilla de escape de AWS: ni ticket de soporte, ni respaldo, ni recuperación. El período de espera obligatorio (de 7 a 30 días, 30 por defecto) existe para hacer este error sobrevivible. Durante la ventana la clave entra en estado `PendingDeletion`, todas las operaciones criptográficas con ella **fallan inmediatamente** — así que cualquier carga de trabajo que todavía dependa de ella se rompe de forma ruidosa y visible en lugar de seguir funcionando en silencio hasta la fecha de eliminación — y `cancel-key-deletion` la restaura por completo en cualquier momento antes del plazo. La práctica operativa correcta antes de programar la eliminación es revisar **CloudTrail** en busca de llamadas recientes de `Decrypt`, `GenerateDataKey` y `Encrypt` contra la clave (Amazon EventBridge y las alarmas de CloudWatch sobre el uso de KMS hacen esto rutinario), y preferir **deshabilitar** la clave primero: deshabilitar es totalmente reversible y produce el mismo comportamiento de fallo ruidoso, lo que la convierte en la forma segura de probar si algo todavía necesita la clave.

</details>

---

## Fuentes

Todo el material de arriba es original. Los comportamientos de los servicios de AWS, las formas de las API, la semántica de las políticas y las fronteras de responsabilidad descritas están documentados en las siguientes fuentes oficiales.

**Alcance del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Responsabilidad compartida y evidencia de cumplimiento**
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Artifact agreements (BAA and others) — https://docs.aws.amazon.com/artifact/latest/ug/managingagreements.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/

**Regiones, residencia y barreras organizacionales**
- Managing AWS Regions (opt-in Regions) — https://docs.aws.amazon.com/general/latest/gr/rande-manage.html
- Service control policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- `aws:RequestedRegion` global condition key — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-requestedregion
- IAM policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- AWS Control Tower — https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html

**Cifrado**
- AWS KMS concepts, including envelope encryption — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- Rotating AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- Deleting AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html
- S3 server-side encryption — https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html
- S3 Bucket Keys — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- Enforcing encryption in transit with `aws:SecureTransport` — https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- AWS Certificate Manager — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS CloudHSM — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html

**Auditoría, configuración y gobernanza**
- AWS CloudTrail — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- CloudTrail log file integrity validation — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- CloudTrail data events — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-data-events-with-cloudtrail.html
- AWS Config — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Config managed rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- AWS Config conformance packs — https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html
- AWS Audit Manager — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- AWS License Manager — https://docs.aws.amazon.com/license-manager/latest/userguide/license-manager.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Detección de amenazas y gestión de postura**
- Amazon GuardDuty — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- GuardDuty finding types — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html
- AWS Security Hub — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Security Finding Format (ASFF) — https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html
- Amazon Inspector — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective — https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- Reporting AWS abuse — https://support.aws.amazon.com/#/contacts/report-abuse