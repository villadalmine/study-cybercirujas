# Tema 2.3 — Identificar las capacidades de gestión de accesos de AWS
## Ejercicios guiados (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

**Dominio 2: Seguridad y cumplimiento — 30 % del examen. Peso del enunciado de tarea 2.3: 7,5 %.**

> Guía del examen: [Guía del examen AWS Certified Cloud Practitioner (CLF-C02)](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

### Antes de empezar

**Requisitos del entorno**

| Requisito | Notas |
|---|---|
| Una **cuenta sandbox** de AWS dedicada | Nunca ejecutes esto contra una cuenta de producción. Vas a crear y borrar principals. |
| AWS CLI **v2** instalado | `aws --version` → `aws-cli/2.x.x Python/3.x.x linux/6.x source/x86_64` |
| Un principal administrativo desde el cual arrancar | Un rol `AdministratorAccess` alcanzado mediante IAM Identity Center es la forma correcta en producción; un usuario IAM administrador de larga duración es aceptable en una sandbox descartable. |
| Opcional: una organización sandbox de AWS Organizations | Solo el Ejercicio 7 la necesita. Está marcado como *opcional*. |

**Costo**

IAM, AWS Organizations, IAM Access Analyzer (hallazgos de acceso externo), los credential reports y Access Advisor son **gratuitos**. Los únicos recursos facturables de este material son la instancia EC2 opcional del Ejercicio 5 (`t3.micro`, borrala dentro de la hora) y el secreto opcional de Secrets Manager del Ejercicio 9 (≈ USD 0,40 por secreto-mes, prorrateado). Todo lo demás no cuesta nada.

**Convenciones**

A lo largo del material, `111122223333` es *tu* cuenta de laboratorio y `444455556666` es una segunda cuenta, la del "partner". Sustituí por tus propios IDs. Todos los ARNs, IDs de clave e IDs de principal de las salidas esperadas son ejemplos — los tuyos van a ser distintos. Los identificadores de muestra siguen la convención de la documentación de AWS (`AKIAIOSFODNN7EXAMPLE`, `AIDA…EXAMPLE`) y **no** son credenciales válidas.

Definí esto una vez en cada shell que uses:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LAB_BUCKET="teachplat-clf-lab-${ACCOUNT_ID}"
echo "$ACCOUNT_ID / $LAB_BUCKET"
```

---

## Ejercicio 1 — Las cuatro formas de entrar a AWS, y dónde viven realmente las credenciales

**Objetivo:** demostrarte a vos mismo que la Console, la CLI, los SDK y la IaC son cuatro *front ends sobre la misma API*, todos regulados por la misma decisión de autorización de IAM, y aprender la cadena de proveedores de credenciales que la CLI/SDK recorren antes de cada llamada.

### Bloque 1.1 — Una API, cuatro front ends

1. Iniciá sesión en la AWS Management Console y abrí **S3 → Create bucket**. **No** envíes el formulario todavía. Abrí las herramientas de desarrollo del navegador, pestaña **Network**, y filtrá por `Fetch/XHR`. Ahora enviá el formulario.
2. Observá la petición que dispara la Console. La Console es una aplicación JavaScript que llama al mismo endpoint público del servicio (`s3.amazonaws.com`) con una petición firmada con SigV4, idéntica a la que producirías desde la CLI. Borrá el bucket que acabás de crear.
3. Hacé la misma operación desde la CLI con el trazado a nivel de cable habilitado:

```bash
aws s3api create-bucket --bucket "$LAB_BUCKET" --region us-east-1 --debug 2>&1 \
  | grep -E "Making request|Signature|AWS4-HMAC-SHA256" | head -5
```

Salida esperada (abreviada):

```
2026-09-04 11:02:41,908 - MainThread - botocore.hooks - DEBUG - Event request-created.s3.CreateBucket
2026-09-04 11:02:41,910 - MainThread - botocore.auth - DEBUG - Calculating signature using v4 auth.
2026-09-04 11:02:41,911 - MainThread - botocore.auth - DEBUG - CanonicalRequest:
PUT
/
...
Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260904/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=...
```

4. Ahora lo mismo de forma declarativa. Escribí `bucket.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Topic 2.3 lab bucket, created via IaC to show the API is the same

Parameters:
  BucketName:
    Type: String
    Description: Globally unique bucket name

Resources:
  LabBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Ref BucketName
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      VersioningConfiguration:
        Status: Enabled

Outputs:
  BucketArn:
    Description: ARN of the lab bucket
    Value: !GetAtt LabBucket.Arn
```

```bash
aws cloudformation deploy \
  --stack-name clf-lab-bucket \
  --template-file bucket.yaml \
  --parameter-overrides BucketName="${LAB_BUCKET}-iac"
```

Salida esperada:

```
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-lab-bucket
```

5. Confirmá que CloudFormation actuó **como vos**, y no como algún súper-usuario de AWS, leyendo el registro de CloudTrail de la llamada:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateBucket \
  --max-results 2 \
  --query 'Events[].{User:Username,Time:EventTime,Src:EventSource}' \
  --output table
```

> **Q1.1** — La Console, la CLI, un SDK (`boto3`, `aws-sdk-js`) y CloudFormation crearon todos un bucket. Desde el punto de vista de IAM, ¿cuántos mecanismos de autorización *distintos* intervinieron?
>
> **Q1.2** — El paso 5 mostró un `Username` en CloudTrail para la llamada impulsada por CloudFormation. ¿Por qué CloudFormation no tiene permisos "propios" por defecto, y qué característica cambia eso?
>
> **Q1.3** — ¿Cuál de los cuatro métodos de acceso *no está disponible* para un rol de IAM, y por qué?

### Bloque 1.2 — La cadena de proveedores de credenciales

6. Inspeccioná de dónde está leyendo las credenciales la CLI en este momento:

```bash
aws configure list
```

Salida esperada:

```
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                <not set>             None    None
access_key     ****************MPLE shared-credentials-file
secret_key     ****************EKEY shared-credentials-file
    region                us-east-1      config-file    ~/.aws/config
```

Las columnas `Type`/`Location` son el punto de todo el ejercicio: te dicen *qué eslabón de la cadena de proveedores ganó*.

7. Sobrescribí con variables de entorno y volvé a ejecutar. Las variables de entorno están **por encima** del archivo de credenciales compartido en la precedencia:

```bash
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
aws configure list
```

Salida esperada — fijate que cambió la columna `Type`:

```
access_key     ****************MPLE              env
secret_key     ****************EKEY              env
```

8. Inspeccioná los archivos en sí. `~/.aws/credentials` guarda secretos; `~/.aws/config` guarda ajustes no secretos y el cableado de roles/SSO:

```bash
cat ~/.aws/config
```

```ini
[default]
region = us-east-1
output = json

[profile lab-audit]
role_arn = arn:aws:iam::111122223333:role/LabAuditRole
source_profile = default
role_session_name = clf-lab
duration_seconds = 3600
```

9. Verificá los permisos del archivo. Un archivo de credenciales legible por todo el mundo es un hallazgo en cualquier auditoría:

```bash
ls -l ~/.aws/credentials
```

Salida esperada: `-rw------- 1 you you 116 Sep  4 11:04 /home/you/.aws/credentials`. Si no es `600`, ejecutá `chmod 600 ~/.aws/credentials`.

> **Q1.4** — Ordená de *mayor* a *menor* precedencia en la cadena por defecto de AWS CLI v2 / SDK: archivo de credenciales compartido, instance profile de EC2 (IMDS), variables de entorno, `--profile` en la línea de comandos, credenciales de contenedor de ECS.
>
> **Q1.5** — En el paso 8, el perfil `lab-audit` no tiene ninguna access key. ¿De dónde salen sus credenciales en el momento de la llamada, y cuánto duran?
>
> **Q1.6** — Un compañero pega una access key en una variable de entorno de Lambda "para que la función pueda llegar a S3". Nombrá el mecanismo nativo de AWS que elimina la clave por completo, y enunciá las dos propiedades que lo hacen estrictamente más seguro.

*Fuentes:* [Ajustes de los archivos de configuración y credenciales](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) · [Proveedores de credenciales estandarizados](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) · [Firma de peticiones a la API de AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html)

---

## Ejercicio 2 — Root user: qué es, qué solo él puede hacer, cómo blindarlo

**Objetivo:** tratar al root user por lo que realmente es — una credencial break-glass que *no* es un principal de IAM y que no puede ser restringida por una política de IAM.

### Bloque 2.1 — Auditar el root user

1. Generá un credential report. Es un CSV **de toda la cuenta** que cubre cada usuario IAM *más* la cuenta root:

```bash
aws iam generate-credential-report
```

Salida esperada:

```json
{
    "State": "STARTED"
}
```

Volvé a ejecutar hasta obtener `"State": "COMPLETE"` (unos segundos).

2. Descargalo y decodificalo:

```bash
aws iam get-credential-report --query Content --output text | base64 --decode > credential-report.csv
head -2 credential-report.csv | cut -d, -f1-9
```

Salida esperada:

```
user,arn,user_creation_time,password_enabled,password_last_used,password_last_changed,password_next_rotation,mfa_active,access_key_1_active
<root_account>,arn:aws:iam::111122223333:root,2026-08-30T14:02:11+00:00,not_supported,2026-09-03T18:44:02+00:00,not_supported,not_supported,true,false
```

3. Leé los tres campos que importan para el root user:

```bash
grep '^<root_account>' credential-report.csv | awk -F, '{print "mfa_active="$8, "access_key_1_active="$9, "access_key_2_active="$14}'
```

El estado objetivo es `mfa_active=true access_key_1_active=false access_key_2_active=false`.

4. Confirmá lo mismo a través del resumen de la cuenta, que es lo que consultan la mayoría de los auditores:

```bash
aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent,Users:Users,MFADevices:MFADevices}'
```

Salida esperada (estado correcto):

```json
{
    "RootMFA": 1,
    "RootKeys": 0,
    "Users": 3,
    "MFADevices": 4
}
```

`RootMFA: 1` significa que el MFA de root está activo. `RootKeys: 0` significa que el root user **no tiene access keys** — la línea más importante de esta salida.

> **Q2.1** — `password_enabled` es `not_supported` para `<root_account>`. ¿Por qué IAM se niega a reportar un campo que obviamente existe?
>
> **Q2.2** — Tu `get-account-summary` devuelve `"AccountAccessKeysPresent": 1`. Explicá en una oración por qué esto es más grave que un usuario IAM con una clave activa, y enunciá la remediación.
>
> **Q2.3** — ¿Qué servicio de AWS consume el credential report para evaluar de forma *continua* que `root MFA enabled` se cumple, en lugar de hacerlo como una verificación manual puntual?

### Bloque 2.2 — Tareas que solo el root user puede hacer

5. Intentá una operación exclusiva de root con tu principal (administrativo, pero no root) — habilitar S3 MFA Delete:

```bash
aws s3api put-bucket-versioning \
  --bucket "$LAB_BUCKET" \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::${ACCOUNT_ID}:mfa/lab-token 123456"
```

Fallo esperado (incluso con `AdministratorAccess`):

```
An error occurred (AccessDenied) when calling the PutBucketVersioning operation: Access Denied
```

MFA Delete puede configurarse **únicamente** por el root user del dueño del bucket, con un dispositivo MFA de root. `AdministratorAccess` no ayuda. Esta es la demostración más limpia en AWS de que root ≠ admin.

6. Leé la lista canónica en lugar de memorizar folklore:

```bash
# Open in a browser:
# https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
```

Los miembros recurrentes de esa lista relevantes para el examen:

- Cambiar el nombre de la cuenta, el email de root o la contraseña de root
- Cambiar el plan de AWS Support
- **Cerrar la cuenta de AWS**
- Restaurar permisos de usuarios IAM cuando el último administrador dejó a todos afuera
- Habilitar **S3 MFA Delete** en un bucket
- Registrarse como vendedor en el Reserved Instance Marketplace
- Suscribirse a AWS GovCloud (US)
- Solicitar la eliminación del límite de envío del puerto 25 (SMTP) en EC2
- Ciertas acciones de facturación y de facturas fiscales en la consola de billing

7. Blindá el root user. Hacé esto en la Console como root, después cerrá sesión y no lo uses nunca más para trabajo rutinario:
   1. **Account → Security credentials → Multi-factor authentication → Assign MFA device.** Preferí una **llave de seguridad FIDO2** o un token TOTP de hardware por sobre un autenticador virtual en el teléfono. Podés registrar hasta **8 dispositivos MFA** por root user — registrá dos, y guardá el segundo en una ubicación física distinta.
   2. **Borrá todas las access keys de root.** Si `RootKeys` era `1` en el paso 4, esta es la corrección.
   3. Configurá el email de root como una **lista de distribución** monitoreada por más de una persona, no el buzón de un individuo.
   4. En un escenario con AWS Organizations, aplicá una SCP que deniegue todas las acciones al principal root de las cuentas miembro, y usá la **gestión centralizada de acceso root** para eliminar por completo las credenciales root de las cuentas miembro.

> **Q2.4** — El paso 5 falló con `AdministratorAccess` adjunto. Explicá la razón de fondo usando las palabras *principal* y *evaluación de políticas*.
>
> **Q2.5** — Sos el único administrador, borraste tu propia política de admin y quedaste afuera. ¿Cuál de las tareas "exclusivas de root" te salva, y qué implica esto respecto de borrar la contraseña de root?
>
> **Q2.6** — ¿Por qué una llave de seguridad FIDO2 es materialmente más fuerte que una app TOTP para el root user? Nombrá la clase de ataque que derrota.

*Fuentes:* [Tareas que requieren credenciales de root user](https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html) · [Obtener credential reports](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html) · [MFA en AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html) · [Gestión centralizada de acceso root](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html)

---

## Ejercicio 3 — Usuarios, grupos y políticas basadas en identidad (mínimo privilegio en la práctica)

**Objetivo:** construir la cadena clásica usuario → grupo → política, y después verificar que los permisos son *exactamente* los que pretendías y nada más.

### Bloque 3.1 — Construir la cadena

1. Definí primero una política de contraseñas de cuenta, para que cualquier usuario de consola que crees la herede:

```bash
aws iam update-account-password-policy \
  --minimum-password-length 14 \
  --require-uppercase-characters \
  --require-lowercase-characters \
  --require-numbers \
  --require-symbols \
  --allow-users-to-change-password \
  --password-reuse-prevention 24 \
  --max-password-age 365
```

Verificá:

```bash
aws iam get-account-password-policy --query PasswordPolicy
```

Salida esperada:

```json
{
    "MinimumPasswordLength": 14,
    "RequireSymbols": true,
    "RequireNumbers": true,
    "RequireUppercaseCharacters": true,
    "RequireLowercaseCharacters": true,
    "AllowUsersToChangePassword": true,
    "ExpirePasswords": true,
    "MaxPasswordAge": 365,
    "PasswordReusePrevention": 24
}
```

2. Creá un grupo. **Adjuntá las políticas a grupos, nunca a usuarios individuales** — un grupo es la única construcción de IAM cuya concesión de permisos sobrevive limpiamente a la rotación de personal:

```bash
aws iam create-group --group-name DataAnalysts
```

Salida esperada:

```json
{
    "Group": {
        "Path": "/",
        "GroupName": "DataAnalysts",
        "GroupId": "AGPAEXAMPLEGROUPID01",
        "Arn": "arn:aws:iam::111122223333:group/DataAnalysts",
        "CreateDate": "2026-09-04T11:15:33+00:00"
    }
}
```

3. Escribí una **customer managed policy** que sea genuinamente de mínimo privilegio — acotada a un bucket, un prefijo, solo lectura, y exigiendo TLS:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyTheReportsPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::teachplat-clf-lab-111122223333",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["reports/*", "reports/"]
        }
      }
    },
    {
      "Sid": "ReadObjectsUnderReports",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/*"
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
```

Guardala como `analyst-policy.json` (sustituyendo el nombre de tu bucket) y creala:

```bash
aws iam create-policy \
  --policy-name LabReportsReadOnly \
  --description "Read-only on the reports/ prefix of the CLF lab bucket" \
  --policy-document file://analyst-policy.json
```

Salida esperada:

```json
{
    "Policy": {
        "PolicyName": "LabReportsReadOnly",
        "PolicyId": "ANPAEXAMPLEPOLICYID1",
        "Arn": "arn:aws:iam::111122223333:policy/LabReportsReadOnly",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "IsAttachable": true,
        "CreateDate": "2026-09-04T11:18:02+00:00"
    }
}
```

4. Adjuntá la política al grupo, creá un usuario y metelo en el grupo:

```bash
aws iam attach-group-policy \
  --group-name DataAnalysts \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LabReportsReadOnly"

aws iam create-user --user-name lab-analyst --tags Key=Department,Value=Analytics Key=CostCenter,Value=CC-4471

aws iam add-user-to-group --user-name lab-analyst --group-name DataAnalysts
```

5. Confirmá que el usuario **no tiene políticas adjuntas directamente** ni **políticas inline** — todos los permisos llegan a través del grupo:

```bash
aws iam list-attached-user-policies --user-name lab-analyst
aws iam list-user-policies --user-name lab-analyst
aws iam list-groups-for-user --user-name lab-analyst --query 'Groups[].GroupName'
```

Salida esperada:

```json
{ "AttachedPolicies": [] }
{ "PolicyNames": [] }
[ "DataAnalysts" ]
```

> **Q3.1** — Un grupo tiene un `GroupId` y un ARN. ¿Puede nombrarse un grupo como `Principal` en una bucket policy de S3? Justificá tu respuesta.
>
> **Q3.2** — En la política de arriba, ¿por qué hay **dos** sentencias `Allow` separadas con valores de `Resource` distintos, en lugar de una sola sentencia listando ambas acciones contra `arn:aws:s3:::bucket/*`?
>
> **Q3.3** — La sentencia `DenyInsecureTransport` usa `aws:SecureTransport`. Nombrá el elemento de política en el que vive, y explicá por qué un `Deny` con condición es la construcción correcta acá en lugar de acotar el `Allow`.
>
> **Q3.4** — Distinguí *managed policy* (AWS managed vs customer managed) de *inline policy* en una oración cada una, y dá la razón operativa para preferir las managed.

### Bloque 3.2 — Verificar la concesión sin esperar a un incidente

6. Usá la **API del policy simulator** — evalúa el grafo real de políticas sin ejecutar ninguna acción:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names s3:GetObject s3:PutObject s3:DeleteBucket \
  --resource-arns "arn:aws:s3:::${LAB_BUCKET}/reports/q3.csv" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

Salida esperada:

```
------------------------------------
|    SimulatePrincipalPolicy       |
+-----------------+----------------+
|     Action      |    Decision    |
+-----------------+----------------+
|  s3:GetObject   |  allowed       |
|  s3:PutObject   |  implicitDeny  |
|  s3:DeleteBucket|  implicitDeny  |
+-----------------+----------------+
```

7. Ahora probalo en vivo. Creá access keys para el usuario *solo para este laboratorio*, y registrá un perfil con nombre:

```bash
aws iam create-access-key --user-name lab-analyst
```

```json
{
    "AccessKey": {
        "UserName": "lab-analyst",
        "AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
        "Status": "Active",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "CreateDate": "2026-09-04T11:22:47+00:00"
    }
}
```

```bash
aws configure set aws_access_key_id     AKIAIOSFODNN7EXAMPLE --profile analyst
aws configure set aws_secret_access_key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY --profile analyst
aws configure set region us-east-1 --profile analyst
```

8. Sembrá un objeto como admin, y después leelo como el analista:

```bash
echo "region,revenue
us-east-1,120000" > q3.csv
aws s3 cp q3.csv "s3://${LAB_BUCKET}/reports/q3.csv"

aws --profile analyst s3 cp "s3://${LAB_BUCKET}/reports/q3.csv" -
```

Salida esperada: el contenido del CSV se imprime en stdout.

9. Confirmá el límite de la concesión — tres denegaciones, cada una con una razón *distinta*:

```bash
aws --profile analyst s3 cp q3.csv "s3://${LAB_BUCKET}/reports/upload.csv"
aws --profile analyst s3 cp "s3://${LAB_BUCKET}/secrets/keys.txt" -
aws --profile analyst iam list-users
```

Salida esperada:

```
upload failed: ./q3.csv to s3://teachplat-clf-lab-111122223333/reports/upload.csv An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/upload.csv" because no identity-based policy allows the s3:PutObject action

fatal error: An error occurred (AccessDenied) when calling the GetObject operation: Access Denied

An error occurred (AccessDenied) when calling the ListUsers operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: iam:ListUsers on resource: arn:aws:iam::111122223333:user/ because no identity-based policy allows the iam:ListUsers action
```

Leé el final de cada mensaje. La frase **"because no identity-based policy allows"** es IAM diciéndote que esto fue un deny *implícito* — nada lo denegó, y nada lo permitió tampoco.

10. Revisá la antigüedad de la clave, porque la rotación es la otra mitad de la higiene de claves:

```bash
aws iam list-access-keys --user-name lab-analyst \
  --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status,Created:CreateDate}' --output table
aws iam get-access-key-last-used --access-key-id AKIAIOSFODNN7EXAMPLE \
  --query 'AccessKeyLastUsed.{When:LastUsedDate,Service:ServiceName,Region:Region}'
```

> **Q3.5** — El paso 6 devolvió `implicitDeny` para `s3:PutObject`, pero el Ejercicio 4 va a mostrar `explicitDeny`. ¿Cuál es la diferencia operativa, y cuál de los dos nunca puede ser sobrescrito agregando otro `Allow`?
>
> **Q3.6** — ¿Por qué `s3:GetObject` sobre `secrets/keys.txt` falló con un escueto `Access Denied` sin cláusula explicativa, mientras que `iam:ListUsers` produjo un mensaje detallado?
>
> **Q3.7** — Creaste una access key de larga duración en el paso 7. Enunciá la alternativa correcta en producción para (a) un analista humano y (b) una aplicación corriendo en EC2.
>
> **Q3.8** — `get-access-key-last-used` devuelve `LastUsedDate` ausente. Dá dos interpretaciones distintas de ese resultado y cómo las diferenciarías.

*Fuentes:* [Mejores prácticas de seguridad en IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html) · [Políticas basadas en identidad vs basadas en recursos](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html) · [Probar políticas con el IAM policy simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)

---

## Ejercicio 4 — Lógica de evaluación de políticas: el deny explícito siempre gana

**Objetivo:** internalizar la regla más evaluada del Dominio 2 haciéndola fallar delante tuyo.

### Bloque 4.1 — Superponer un Allow y un Deny sobre la misma acción

1. Adjuntá `AmazonS3FullAccess` — una AWS managed policy muy amplia — directamente a `lab-analyst`:

```bash
aws iam attach-user-policy \
  --user-name lab-analyst \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```

2. Confirmá que el analista ahora puede escribir:

```bash
aws --profile analyst s3 cp q3.csv "s3://${LAB_BUCKET}/reports/upload.csv"
```

Salida esperada: `upload: ./q3.csv to s3://teachplat-clf-lab-111122223333/reports/upload.csv`

3. Ahora agregá un `Deny` explícito y acotado como política **inline** sobre el mismo usuario. Guardala como `deny-delete.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NeverDeleteBucketsOrVersions",
      "Effect": "Deny",
      "Action": [
        "s3:DeleteBucket",
        "s3:DeleteObjectVersion",
        "s3:PutBucketPolicy"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name lab-analyst \
  --policy-name GuardrailNoDestructiveS3 \
  --policy-document file://deny-delete.json
```

4. Comprobá que el Deny le gana al Allow con forma de `*:*` que sigue adjunto:

```bash
aws --profile analyst s3api delete-bucket --bucket "$LAB_BUCKET"
```

Salida esperada:

```
An error occurred (AccessDenied) when calling the DeleteBucket operation: User: arn:aws:iam::111122223333:user/lab-analyst is not authorized to perform: s3:DeleteBucket on resource: "arn:aws:s3:::teachplat-clf-lab-111122223333" with an explicit deny in an identity-based policy
```

Compará el final de este mensaje con el del paso 9 del Ejercicio 3: **"with an explicit deny in an identity-based policy"** vs **"because no identity-based policy allows"**. AWS te nombra el resultado exacto de la evaluación.

5. Confirmá la misma conclusión con el simulador, que además te dice *qué sentencia* hizo match:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names s3:DeleteBucket s3:PutObject \
  --resource-arns "arn:aws:s3:::${LAB_BUCKET}" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,Matched:MatchedStatements[0].SourcePolicyId}' \
  --output table
```

Salida esperada:

```
------------------------------------------------------------------
|                    SimulatePrincipalPolicy                     |
+------------------+----------------+----------------------------+
|      Action      |    Decision    |          Matched           |
+------------------+----------------+----------------------------+
|  s3:DeleteBucket |  explicitDeny  |  GuardrailNoDestructiveS3  |
|  s3:PutObject    |  allowed       |  AmazonS3FullAccess        |
+------------------+----------------+----------------------------+
```

> **Q4.1** — Escribí el orden completo de evaluación que AWS aplica a una única petición de API, desde lo primero que se verifica hasta lo último, incluyendo SCPs, permissions boundaries, session policies, políticas basadas en identidad y basadas en recursos.
>
> **Q4.2** — `AmazonS3FullAccess` permite `s3:*` sobre `*`. Necesitás impedir permanentemente el borrado de buckets para 400 principals repartidos en 12 cuentas. ¿Qué construcción única logra eso con un solo documento de política, y en qué capa se evalúa?
>
> **Q4.3** — Un principal de la cuenta A hace una petición contra un bucket de la cuenta B. Enunciá la regla de cuántas sentencias `Allow` hacen falta y dónde deben vivir.
>
> **Q4.4** — Alguien propone "mejor sacamos `AmazonS3FullAccess` en vez de agregar el Deny". Dá un argumento de seguridad *a favor* del Deny y un argumento operativo *en contra* de confiar solo en él.

*Fuentes:* [Lógica de evaluación de políticas](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html) · [Acceso a recursos entre cuentas en IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies-cross-account-resource-access.html)

---

## Ejercicio 5 — Roles de IAM y credenciales temporales (AWS STS)

**Objetivo:** reemplazar una clave de larga duración por un rol, y *ver* la marca de expiración en las credenciales que recibís.

### Bloque 5.1 — Un rol que tu usuario IAM puede asumir

1. Escribí la **política de confianza** — el `AssumeRolePolicyDocument`. Es la respuesta del rol a "*quién* puede convertirse en mí", y es una política basada en recursos adjunta al propio rol. Guardala como `trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLabAnalystToAssumeWithMFA",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111122223333:user/lab-analyst"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "NumericLessThan": {
          "aws:MultiFactorAuthAge": "3600"
        }
      }
    }
  ]
}
```

Para un laboratorio sin dispositivo MFA en `lab-analyst`, quitá el bloque `Condition` — pero entendé que en producción es el punto central.

2. Creá el rol y dale un conjunto de permisos *distinto* del del usuario:

```bash
aws iam create-role \
  --role-name LabAuditRole \
  --description "Read-only audit role, assumed by analysts" \
  --assume-role-policy-document file://trust.json \
  --max-session-duration 3600
```

Salida esperada (abreviada):

```json
{
    "Role": {
        "RoleName": "LabAuditRole",
        "RoleId": "AROAEXAMPLEROLEID001",
        "Arn": "arn:aws:iam::111122223333:role/LabAuditRole",
        "CreateDate": "2026-09-04T11:41:09+00:00",
        "MaxSessionDuration": 3600
    }
}
```

```bash
aws iam attach-role-policy \
  --role-name LabAuditRole \
  --policy-arn arn:aws:iam::aws:policy/SecurityAudit
```

3. Otorgale a `lab-analyst` permiso para *llamar* a `sts:AssumeRole` sobre ese rol. **Ambos lados deben estar de acuerdo** — la política de confianza sola no alcanza para un principal que es usuario IAM. Guardala como `allow-assume.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumingTheAuditRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::111122223333:role/LabAuditRole"
    }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name lab-analyst \
  --policy-name AllowAssumeLabAuditRole \
  --policy-document file://allow-assume.json
```

4. Asumilo e inspeccioná las credenciales:

```bash
aws --profile analyst sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabAuditRole" \
  --role-session-name clf-lab-session
```

Salida esperada:

```json
{
    "Credentials": {
        "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "SessionToken": "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ...TRUNCATED",
        "Expiration": "2026-09-04T12:44:31+00:00"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "AROAEXAMPLEROLEID001:clf-lab-session",
        "Arn": "arn:aws:sts::111122223333:assumed-role/LabAuditRole/clf-lab-session"
    }
}
```

Tres cosas para notar: el access key ID empieza con **`ASIA`** (temporal) y no con `AKIA` (larga duración); hay un **`SessionToken`**; y hay una **`Expiration`** dura.

5. En lugar de exportar eso a mano, dejá que lo haga la CLI. Agregá el perfil a `~/.aws/config`:

```ini
[profile lab-audit]
role_arn = arn:aws:iam::111122223333:role/LabAuditRole
source_profile = analyst
role_session_name = clf-lab-session
duration_seconds = 3600
```

```bash
aws --profile lab-audit sts get-caller-identity
```

Salida esperada:

```json
{
    "UserId": "AROAEXAMPLEROLEID001:clf-lab-session",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/LabAuditRole/clf-lab-session"
}
```

6. Confirmá que la sesión lleva los permisos **del rol**, no los del usuario:

```bash
aws --profile lab-audit iam list-users --query 'Users[].UserName'     # SecurityAudit allows this
aws --profile analyst   iam list-users --query 'Users[].UserName'     # the user alone cannot
```

Salida esperada: el primero imprime un array JSON de nombres de usuario; el segundo falla con `AccessDenied … iam:ListUsers`.

> **Q5.1** — Nombrá las tres cosas que tiene un rol y que un usuario IAM no tiene, o tiene de otra manera: identificá la política de confianza, la vida útil de la credencial y el tipo de credencial.
>
> **Q5.2** — En el paso 3 tuviste que escribir una política sobre el *usuario* aunque el rol ya confiaba en ese usuario. ¿Este requisito simétrico se cumple siempre? Contrastá el caso de usuario IAM en la misma cuenta con la asunción por parte del servicio EC2.
>
> **Q5.3** — `MaxSessionDuration` es 3600 s. Un colega lo pone en 43200 s "para que nadie se vea interrumpido". Argumentá el caso de seguridad en contra, en términos de radio de impacto.
>
> **Q5.4** — ¿Contra qué protege `sts:ExternalId`, y en qué escenario específico es obligatorio?

### Bloque 5.2 — Roles para servicios: instance profiles de EC2 e IMDSv2 *(opcional, genera costo)*

7. Creá un rol que **EC2** — no un humano — pueda asumir. La política de confianza nombra un *service principal*:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role --role-name LabInstanceRole --assume-role-policy-document file://ec2-trust.json
aws iam attach-role-policy --role-name LabInstanceRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name LabInstanceProfile
aws iam add-role-to-instance-profile --instance-profile-name LabInstanceProfile --role-name LabInstanceRole
```

8. Lanzá una `t3.micro` con **IMDSv2 obligatorio** y el profile adjunto:

```bash
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro \
  --iam-instance-profile Name=LabInstanceProfile \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf-lab}]' \
  --query 'Instances[0].InstanceId' --output text
```

9. Conectate con Session Manager (sin clave SSH, sin puerto 22 abierto — en sí mismo una victoria de gestión de accesos) y leé el servicio de metadatos:

```bash
aws ssm start-session --target i-0abcd1234efgh5678
```

Dentro de la sesión:

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Salida esperada: `LabInstanceRole`

```bash
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/LabInstanceRole
```

Salida esperada:

```json
{
  "Code" : "Success",
  "LastUpdated" : "2026-09-04T11:52:14Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAIOSFODNN7EXAMPLE",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjE...TRUNCATED",
  "Expiration" : "2026-09-04T18:11:47Z"
}
```

10. Comprobá que IMDSv1 está bloqueado — esta es la mitigación para la clase de ataque SSRF-a-robo-de-credenciales:

```bash
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/ ; echo "exit=$?"
```

Salida esperada: un cuerpo vacío y `exit=0` con HTTP 401 (o un timeout), porque no se presentó ningún token.

11. **Terminá la instancia de inmediato** cuando termines:

```bash
aws ec2 terminate-instances --instance-ids i-0abcd1234efgh5678
```

> **Q5.5** — Las credenciales del paso 9 expiran en ~6 horas. ¿Quién las rota, y qué tiene que hacer la aplicación para seguir funcionando?
>
> **Q5.6** — Explicá `HttpPutResponseHopLimit=1` en términos de los contenedores que corren en ese host, y por qué `HttpTokens=required` es el ajuste que realmente importa contra SSRF.
>
> **Q5.7** — Un *instance profile* y un *rol* son objetos distintos. Describí la relación y la cardinalidad entre ellos.

*Fuentes:* [Roles de IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) · [API AssumeRole](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) · [Uso del instance metadata service versión 2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html) · [External ID para acceso de terceros](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html)

---

## Ejercicio 6 — Políticas basadas en recursos y acceso entre cuentas

**Objetivo:** ver el segundo tipo de política — la que se adjunta al *recurso* — y entender por qué el acceso entre cuentas necesita de ambos tipos.

### Bloque 6.1 — Una bucket policy

1. Confirmá que S3 Block Public Access está activo a nivel de cuenta *antes* de tocar ninguna bucket policy:

```bash
aws s3control get-public-access-block --account-id "$ACCOUNT_ID" \
  --query PublicAccessBlockConfiguration
```

Salida esperada:

```json
{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
}
```

Si algún valor es `false`, corregilo ahora:

```bash
aws s3control put-public-access-block --account-id "$ACCOUNT_ID" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

2. Escribí una bucket policy que le dé a un principal de una **cuenta distinta** acceso de lectura a un prefijo. Fijate en el elemento `Principal` — las políticas basadas en identidad nunca lo tienen; las basadas en recursos siempre. Guardala como `bucket-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPartnerAccountReadReports",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::444455556666:role/PartnerReaderRole"
      },
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/reports/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-exampleorgid"
        }
      }
    },
    {
      "Sid": "DenyUnencryptedTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::teachplat-clf-lab-111122223333",
        "arn:aws:s3:::teachplat-clf-lab-111122223333/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
```

```bash
aws s3api put-bucket-policy --bucket "$LAB_BUCKET" --policy file://bucket-policy.json
aws s3api get-bucket-policy --bucket "$LAB_BUCKET" --query Policy --output text | python3 -m json.tool
```

3. Intentá una política deliberadamente pública y mirá cómo Block Public Access la rechaza:

```bash
cat > public.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${LAB_BUCKET}/*"
  }]
}
EOF
aws s3api put-bucket-policy --bucket "$LAB_BUCKET" --policy file://public.json
```

Salida esperada:

```
An error occurred (AccessDenied) when calling the PutBucketPolicy operation: Access Denied
```

Esto es `BlockPublicPolicy=true` haciendo su trabajo — la política se rechaza en el momento de la escritura, no se aplica silenciosamente para después ser ignorada.

> **Q6.1** — Enumerá tres servicios de AWS además de S3 que soporten políticas basadas en recursos, y uno que ostensiblemente no lo haga (de modo que el acceso entre cuentas deba basarse en roles).
>
> **Q6.2** — Se agregó `aws:PrincipalOrgID` como condición. ¿Qué clase de error previene que nombrar solo el ID de cuenta no previene?
>
> **Q6.3** — Para que el partner de `444455556666` efectivamente lea el objeto, ¿qué debe existir *en su cuenta*? Nombrá el tipo de política y el principal al que se adjunta.
>
> **Q6.4** — Block Public Access existe en dos alcances. Nombrá ambos, y decí cuál de ellos no puede sobrescribir un equipo de aplicación.

*Fuentes:* [Bucket policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html) · [Bloquear el acceso público al almacenamiento de S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html) · [Claves de contexto de condición globales de AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html)

---

## Ejercicio 7 — Guardrails: SCPs y permissions boundaries

**Objetivo:** distinguir las dos construcciones que *limitan* el máximo de permisos de las que los *otorgan*. Esta distinción es un discriminador confiable en el examen.

### Bloque 7.1 — Permissions boundary (cualquier cuenta)

1. Una boundary es un documento de política común usado en una ranura especial. Guardala como `boundary.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BoundaryMaxScope",
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "cloudwatch:*",
        "logs:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BoundaryDenyPrivilegeEscalation",
      "Effect": "Deny",
      "Action": [
        "iam:CreateUser",
        "iam:CreateRole",
        "iam:AttachUserPolicy",
        "iam:AttachRolePolicy",
        "iam:PutUserPolicy",
        "iam:PutRolePolicy",
        "iam:DeleteUserPermissionsBoundary",
        "iam:DeleteRolePermissionsBoundary"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
aws iam create-policy --policy-name LabDeveloperBoundary --policy-document file://boundary.json
aws iam create-user --user-name lab-developer \
  --permissions-boundary "arn:aws:iam::${ACCOUNT_ID}:policy/LabDeveloperBoundary"
aws iam attach-user-policy --user-name lab-developer \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

2. `lab-developer` ahora tiene `AdministratorAccess` adjunto *y* una boundary. Simulá:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-developer" \
  --action-names s3:PutObject ec2:RunInstances iam:CreateUser \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

Salida esperada:

```
-------------------------------------
|     SimulatePrincipalPolicy       |
+-------------------+---------------+
|      Action       |   Decision    |
+-------------------+---------------+
|  s3:PutObject     |  allowed      |
|  ec2:RunInstances |  implicitDeny |
|  iam:CreateUser   |  explicitDeny |
+-------------------+---------------+
```

Leé esto con atención. `AdministratorAccess` permite las tres. `s3:PutObject` sobrevive porque la boundary también lo permite. `ec2:RunInstances` se deniega *implícitamente* — la boundary simplemente nunca menciona EC2. `iam:CreateUser` se deniega *explícitamente* por la segunda sentencia de la boundary.

3. Verificá que la boundary está realmente adjunta:

```bash
aws iam get-user --user-name lab-developer --query 'User.PermissionsBoundary'
```

Salida esperada:

```json
{
    "PermissionsBoundaryType": "Policy",
    "PermissionsBoundaryArn": "arn:aws:iam::111122223333:policy/LabDeveloperBoundary"
}
```

> **Q7.1** — Una permissions boundary contiene `"Effect": "Allow", "Action": "s3:*"`. ¿Eso le otorga al usuario acceso a S3? Explicá con precisión qué le hace una boundary al conjunto efectivo de permisos.
>
> **Q7.2** — La boundary deniega `iam:DeleteUserPermissionsBoundary`. ¿Qué ataque previene esa línea específica?
>
> **Q7.3** — ¿A qué tipos de principal se pueden adjuntar permissions boundaries? Nombrá aquel al que no se pueden adjuntar.

### Bloque 7.2 — Service control policies *(opcional — requiere una cuenta de gestión de Organizations)*

4. Confirmá que estás en la cuenta de gestión y que las SCPs están habilitadas:

```bash
aws organizations describe-organization \
  --query 'Organization.{Id:Id,Master:MasterAccountId,FeatureSet:FeatureSet}'
aws organizations list-roots --query 'Roots[].{Id:Id,Policies:PolicyTypes}'
```

Salida esperada:

```json
{ "Id": "o-exampleorgid", "Master": "111122223333", "FeatureSet": "ALL" }
```
```json
[ { "Id": "r-exam", "Policies": [ { "Type": "SERVICE_CONTROL_POLICY", "Status": "ENABLED" } ] } ]
```

`FeatureSet` debe ser `ALL`; la facturación consolidada por sí sola no soporta SCPs.

5. Creá una SCP de restricción de regiones — uno de los guardrails reales más comunes:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyOutsideApprovedRegions",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "cloudfront:*",
        "route53:*",
        "support:*",
        "budgets:*",
        "waf:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1", "eu-west-1"]
        }
      }
    }
  ]
}
```

```bash
aws organizations create-policy \
  --name DenyOutsideApprovedRegions \
  --description "Allow API calls only in us-east-1 and eu-west-1" \
  --type SERVICE_CONTROL_POLICY \
  --content file://scp-regions.json

aws organizations attach-policy --policy-id p-examplescpid --target-id ou-exam-sandboxou
```

6. Desde una cuenta **miembro** de esa OU, probá:

```bash
aws ec2 describe-instances --region ap-south-1
```

Salida esperada:

```
An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation: You are not authorized to perform this operation. ... with an explicit deny in a service control policy
```

7. Inspeccioná qué está efectivamente en vigor sobre una cuenta:

```bash
aws organizations list-policies-for-target --target-id 444455556666 --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].{Name:Name,Id:Id,AwsManaged:AwsManaged}' --output table
```

> **Q7.4** — Una SCP contiene `"Effect": "Allow", "Action": "*"` (el `FullAWSAccess` por defecto). Un usuario de la cuenta no tiene ninguna política de IAM. ¿Qué puede hacer, y por qué?
>
> **Q7.5** — Las SCPs no se aplican a un principal de la organización. ¿A cuál, y cuál es la consecuencia operativa para los procedimientos break-glass?
>
> **Q7.6** — Contrastá SCP y permissions boundary en tres ejes: dónde se adjunta, quién suele ser su dueño, y qué pasa cuando no existe ninguna de las dos.
>
> **Q7.7** — La SCP de arriba usa `NotAction` en lugar de `Action`. Explicá por qué hubo que excluir a los servicios globales, y qué se rompería si `iam:*` no estuviera en esa lista.

*Fuentes:* [Service control policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) · [Permissions boundaries para entidades de IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)

---

## Ejercicio 8 — Control de acceso basado en atributos (ABAC) con tags

**Objetivo:** escalar la autorización sin escribir una política nueva por equipo, usando tags tanto en el principal como en el recurso.

1. Etiquetá el principal:

```bash
aws iam tag-user --user-name lab-analyst --tags Key=Project,Value=apollo
aws iam list-user-tags --user-name lab-analyst --query 'Tags' --output table
```

2. Escribí una sola política ABAC que funcione para *todos* los proyectos, presentes y futuros. Guardala como `abac.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartStopOnlyMyProjectInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Project": "${aws:PrincipalTag/Project}"
        }
      }
    },
    {
      "Sid": "AllowDescribeForConsoleUsability",
      "Effect": "Allow",
      "Action": "ec2:Describe*",
      "Resource": "*"
    },
    {
      "Sid": "RequireProjectTagOnCreation",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "${aws:PrincipalTag/Project}"
        }
      }
    }
  ]
}
```

```bash
aws iam create-policy --policy-name AbacProjectInstanceControl --policy-document file://abac.json
aws iam attach-user-policy --user-name lab-analyst \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AbacProjectInstanceControl"
```

3. Simulá contra dos instancias con tags distintos. El simulador te permite suministrar el tag del recurso como entrada de contexto:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names ec2:StopInstances \
  --resource-arns "arn:aws:ec2:us-east-1:${ACCOUNT_ID}:instance/i-0apollo000000001" \
  --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyType=string,ContextKeyValues=apollo' \
  --query 'EvaluationResults[].EvalDecision' --output text
```

Salida esperada: `allowed`

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --action-names ec2:StopInstances \
  --resource-arns "arn:aws:ec2:us-east-1:${ACCOUNT_ID}:instance/i-0gemini00000001" \
  --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyType=string,ContextKeyValues=gemini' \
  --query 'EvaluationResults[].EvalDecision' --output text
```

Salida esperada: `implicitDeny`

> **Q8.1** — En una oración cada uno, contrastá RBAC y ABAC tal como AWS los implementa, y enunciá la propiedad de escalado específica que hace atractivo a ABAC con 200 equipos.
>
> **Q8.2** — `${aws:PrincipalTag/Project}` es una *variable* de política. ¿Qué pasa con la evaluación si el principal no tiene ningún tag `Project`?
>
> **Q8.3** — La tercera sentencia (`RequireProjectTagOnCreation`) existe por una razón de seguridad, no de comodidad. ¿Qué escalada bloquea?
>
> **Q8.4** — ¿De dónde salen los tags del principal cuando el principal es un usuario federado de IAM Identity Center en lugar de un usuario IAM?

*Fuentes:* [ABAC para AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html) · [Elementos de política de IAM: variables y tags](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html)

---

## Ejercicio 9 — Federación, IAM Identity Center y el fin de las claves de larga duración

**Objetivo:** entender el modelo de identidad que AWS realmente recomienda para humanos, y dónde corresponde guardar los secretos de máquina.

### Bloque 9.1 — Acceso humano vía IAM Identity Center

1. Verificá si Identity Center está habilitado en la organización:

```bash
aws sso-admin list-instances --query 'Instances[].{Arn:InstanceArn,Store:IdentityStoreId,Status:Status}'
```

Salida esperada cuando está habilitado:

```json
[
    {
        "Arn": "arn:aws:sso:::instance/ssoins-exampleinstanceid",
        "Store": "d-9067example",
        "Status": "ACTIVE"
    }
]
```

2. Inspeccioná los permission sets — la unidad de "qué podés hacer" de Identity Center, que se materializa como un rol de IAM en cada cuenta asignada:

```bash
INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
for ps in $(aws sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
  aws sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$ps" \
    --query 'PermissionSet.{Name:Name,Session:SessionDuration}' --output text
done
```

Salida esperada:

```
AdministratorAccess	PT1H
ReadOnlyAccess	PT8H
BillingViewer	PT2H
```

3. Configurá la CLI para usarlo. Este es el reemplazo moderno de `aws configure` con una access key:

```bash
aws configure sso
```

Prompts interactivos y forma esperada del resultado en `~/.aws/config`:

```ini
[sso-session teachplat]
sso_start_url = https://d-9067example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile prod-readonly]
sso_session = teachplat
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = eu-west-1
output = json
```

4. Iniciá sesión y confirmá que la identidad resultante es una **sesión de rol**, no un usuario:

```bash
aws sso login --sso-session teachplat
aws --profile prod-readonly sts get-caller-identity
```

Salida esperada:

```json
{
    "UserId": "AROAEXAMPLEROLEID9:alice@example.com",
    "Account": "444455556666",
    "Arn": "arn:aws:sts::444455556666:assumed-role/AWSReservedSSO_ReadOnlyAccess_a1b2c3d4e5f6/alice@example.com"
}
```

5. Confirmá que no se escribió ningún secreto en disco en forma de larga duración:

```bash
grep -c aws_secret_access_key ~/.aws/credentials 2>/dev/null || echo "no credentials file"
ls -l ~/.aws/sso/cache/
```

El directorio `sso/cache` contiene un token OIDC de vida corta, no una secret key de AWS.

> **Q9.1** — Un usuario de Identity Center inicia sesión con credenciales corporativas y llega a tres cuentas. ¿Cuántos usuarios IAM se crearon? Explicá qué existe realmente en cada cuenta.
>
> **Q9.2** — Identity Center soporta tres opciones de fuente de identidad. Nombralas, y decí cuál elegirías para una empresa que ya usa Microsoft Entra ID.
>
> **Q9.3** — Nombrá las tres propiedades del acceso vía Identity Center que un usuario IAM con una access key no puede igualar.

### Bloque 9.2 — Identidad de aplicación y de clientes, y secretos de máquina

6. Amazon **Cognito** es la respuesta para *los usuarios finales de tu aplicación* — no IAM. Esbozá la distinción con un user pool:

```bash
aws cognito-idp list-user-pools --max-results 10 --query 'UserPools[].{Name:Name,Id:Id}' --output table
```

7. Los secretos de máquina que genuinamente no pueden reemplazarse por un rol (una API key de un tercero, la contraseña de una base de datos) van en **Secrets Manager** o en Parameter Store, nunca en el código ni en variables de entorno:

```bash
aws secretsmanager create-secret \
  --name clf-lab/partner-api-key \
  --description "Third-party key, rotated every 30 days" \
  --secret-string '{"api_key":"EXAMPLEKEYVALUE"}'
```

Salida esperada:

```json
{
    "ARN": "arn:aws:secretsmanager:us-east-1:111122223333:secret:clf-lab/partner-api-key-AbCdEf",
    "Name": "clf-lab/partner-api-key",
    "VersionId": "EXAMPLE1-90ab-cdef-fedc-ba987EXAMPLE"
}
```

```bash
aws secretsmanager get-secret-value --secret-id clf-lab/partner-api-key --query SecretString --output text
```

Borralo enseguida para que deje de acumular costo:

```bash
aws secretsmanager delete-secret --secret-id clf-lab/partner-api-key --force-delete-without-recovery
```

> **Q9.4** — Ubicá cada caso en la caja correcta — usuarios IAM, IAM Identity Center, Amazon Cognito: (a) 40 000 clientes de una app móvil, (b) 300 empleados que necesitan acceso a la consola en 25 cuentas, (c) un trabajo batch heredado on-premises que no puede usar un rol.
>
> **Q9.5** — Tanto Secrets Manager como Systems Manager Parameter Store (SecureString) guardan secretos cifrados con KMS. Dá la única capacidad que Secrets Manager tiene y Parameter Store no, y la única razón por la que aun así podrías elegir Parameter Store.
>
> **Q9.6** — Un secreto en Secrets Manager está protegido por *dos* capas de política. Nombralas y explicá qué controla cada una.

*Fuentes:* [Qué es IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html) · [Proveedores de identidad y federación](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html) · [Qué es Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html) · [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)

---

## Ejercicio 10 — Ajustar los permismos a su medida con evidencia

**Objetivo:** cerrar el ciclo. El mínimo privilegio no se logra en tiempo de diseño; se *mide* y se ajusta después.

1. Preguntale a IAM qué usó realmente un principal, vía Access Advisor (datos de último acceso a servicios). Es una API asincrónica de dos llamadas:

```bash
JOB_ID=$(aws iam generate-service-last-accessed-details \
  --arn "arn:aws:iam::${ACCOUNT_ID}:user/lab-analyst" \
  --query JobId --output text)
echo "$JOB_ID"
sleep 5
aws iam get-service-last-accessed-details --job-id "$JOB_ID" \
  --query 'ServicesLastAccessed[?TotalAuthenticatedEntities>`0`].{Service:ServiceName,Last:LastAuthenticated,Calls:TotalAuthenticatedEntities}' \
  --output table
```

Salida esperada:

```
--------------------------------------------------------------------
|                 GetServiceLastAccessedDetails                    |
+---------------------+----------------------------+---------------+
|       Service       |            Last            |     Calls     |
+---------------------+----------------------------+---------------+
|  Amazon S3          |  2026-09-04T11:26:00+00:00 |  1            |
+---------------------+----------------------------+---------------+
```

`AmazonS3FullAccess` otorga `s3:*`; la evidencia muestra que solo se ejerció `s3:GetObject`. Esa brecha *es* el ticket de remediación.

2. Habilitá IAM Access Analyzer para encontrar recursos alcanzables desde fuera de tu zona de confianza:

```bash
aws accessanalyzer create-analyzer \
  --analyzer-name clf-lab-external \
  --type ACCOUNT

aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:us-east-1:${ACCOUNT_ID}:analyzer/clf-lab-external" \
  --query 'findings[].{Resource:resource,Type:resourceType,Principal:principal,Status:status}' \
  --output table
```

Salida esperada — aparece la bucket policy del Ejercicio 6:

```
------------------------------------------------------------------------------------------------
|                                         ListFindings                                         |
+------------------------------------------------+---------------+---------------------+------+
|                    Resource                    |     Type      |      Principal      |Status|
+------------------------------------------------+---------------+---------------------+------+
| arn:aws:s3:::teachplat-clf-lab-111122223333    | AWS::S3::Bucket| {"AWS":"444455556666"}|ACTIVE|
+------------------------------------------------+---------------+---------------------+------+
```

3. Validá una política *antes* de desplegarla — Access Analyzer incluye más de 100 verificaciones:

```bash
aws accessanalyzer validate-policy \
  --policy-document file://analyst-policy.json \
  --policy-type IDENTITY_POLICY \
  --query 'findings[].{Type:findingType,Issue:issueCode,Detail:findingDetails}' \
  --output table
```

Salida esperada con una política limpia: `{ "findings": [] }`. Introducí un error de tipeo (`"s3:GetObjectt"`) y volvé a ejecutar para ver:

```
ERROR  INVALID_ACTION  The action s3:GetObjectt does not exist.
```

4. Contrastá la cuenta entera contra una línea base publicada:

```bash
aws securityhub get-enabled-standards \
  --query 'StandardsSubscriptions[].StandardsArn' --output text
```

Los controles del CIS AWS Foundations Benchmark en Security Hub codifican exactamente lo que hiciste a mano en el Ejercicio 2: MFA de root, sin access keys de root, rotación de claves, política de contraseñas, MFA para usuarios de consola.

> **Q10.1** — Access Advisor mostró que solo se usó S3 en 90 días. Dá la remediación exacta, y una razón por la que *no* la automatizarías a ciegas.
>
> **Q10.2** — IAM Access Analyzer tiene un analizador de **acceso externo** y uno de **acceso no utilizado**. Emparejá cada uno con un escenario, y decí cuál es gratuito.
>
> **Q10.3** — El hallazgo del paso 2 es `ACTIVE`, no una falla de seguridad. Describí qué hacés con un hallazgo que representa un acceso intencional.
>
> **Q10.4** — ¿Dónde traza la línea el **modelo de responsabilidad compartida** para la gestión de accesos? Enunciá el lado de AWS y el del cliente, usando IAM específicamente.

*Fuentes:* [Refinar permisos usando información de último acceso](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html) · [Qué es IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html) · [Modelo de responsabilidad compartida](https://aws.amazon.com/compliance/shared-responsibility-model/)

---

## Limpieza

Ejecutá esto completo. Los objetos de IAM son gratuitos, pero también son superficie de ataque permanente.

```bash
# Detach and delete users
for U in lab-analyst lab-developer; do
  for P in $(aws iam list-attached-user-policies --user-name $U --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-user-policy --user-name $U --policy-arn $P
  done
  for P in $(aws iam list-user-policies --user-name $U --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-user-policy --user-name $U --policy-name $P
  done
  for G in $(aws iam list-groups-for-user --user-name $U --query 'Groups[].GroupName' --output text 2>/dev/null); do
    aws iam remove-user-from-group --user-name $U --group-name $G
  done
  for K in $(aws iam list-access-keys --user-name $U --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name $U --access-key-id $K
  done
  aws iam delete-user --user-name $U 2>/dev/null
done

# Group
aws iam detach-group-policy --group-name DataAnalysts \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LabReportsReadOnly" 2>/dev/null
aws iam delete-group --group-name DataAnalysts 2>/dev/null

# Roles and instance profile
aws iam detach-role-policy --role-name LabAuditRole --policy-arn arn:aws:iam::aws:policy/SecurityAudit 2>/dev/null
aws iam delete-role --role-name LabAuditRole 2>/dev/null
aws iam remove-role-from-instance-profile --instance-profile-name LabInstanceProfile --role-name LabInstanceRole 2>/dev/null
aws iam delete-instance-profile --instance-profile-name LabInstanceProfile 2>/dev/null
aws iam detach-role-policy --role-name LabInstanceRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name LabInstanceRole 2>/dev/null

# Customer managed policies
for N in LabReportsReadOnly LabDeveloperBoundary AbacProjectInstanceControl; do
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${N}" 2>/dev/null
done

# Buckets and stack
aws s3 rm "s3://${LAB_BUCKET}" --recursive 2>/dev/null
aws s3api delete-bucket --bucket "$LAB_BUCKET" 2>/dev/null
aws cloudformation delete-stack --stack-name clf-lab-bucket 2>/dev/null

# Access Analyzer (free, but tidy)
aws accessanalyzer delete-analyzer --analyzer-name clf-lab-external 2>/dev/null

echo "Cleanup pass complete. Verify:"
aws iam list-users --query 'Users[].UserName'
aws ec2 describe-instances --filters Name=tag:Name,Values=clf-lab Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId'
```

Los dos últimos comandos deben devolver una lista vacía (o solo tu propia identidad de admin). No los saltees — una `t3.micro` olvidada es la factura de laboratorio más común.

---

<details>
<summary><strong>Respuestas</strong> — intentá responder todas las preguntas antes de abrir</summary>

### Ejercicio 1 — Métodos de acceso y la cadena de credenciales

**A1.1** — **Uno.** La Console, la CLI, los SDK y CloudFormation son todos clientes de la misma API pública del servicio. Cada uno de ellos termina emitiendo una petición HTTPS firmada con SigV4 que IAM evalúa con una lógica de evaluación de políticas idéntica. No existe un permiso "solo para la consola" ni una forma de permitir una acción desde la CLI y denegarla desde la Console (podés *aproximarlo* con claves de condición como `aws:ViaAWSService` o `aws:CalledVia`, pero eso es una condición sobre la petición, no un mecanismo de autorización distinto). La consecuencia práctica: endurecer una política basada en identidad endurece las cuatro rutas a la vez y, a la inversa, restringir la interfaz de la Console no protege nada.

**A1.2** — Por defecto CloudFormation actúa **en nombre del principal que llama**, usando *tus* permisos para cada recurso que crea; por eso CloudTrail registra tu nombre de usuario. Esa es la razón por la que un stack que desplegás nunca puede crear algo que vos no podrías haber creado a mano. La característica que cambia esto es un **service role de CloudFormation** (`--role-arn`): el stack asume ese rol y opera con los permisos del rol, lo que permite que un operador de bajo privilegio despliegue un stack que necesita acciones de alto privilegio, sin otorgarle esas acciones al operador directamente. Los StackSets extienden la misma idea a través de varias cuentas.

**A1.3** — La **AWS Management Console** — no porque un rol no pueda usarse en la Console, sino porque un rol no tiene contraseña y no puede *iniciar sesión*. Un rol debe ser **asumido** por un principal ya autenticado (un usuario IAM, una identidad federada o un servicio de AWS). En la práctica cambiás de rol en la Console *después* de iniciar sesión, o caés directamente en uno mediante federación, donde el proveedor de identidad te autentica y STS emite la sesión de rol. La distinción que importa para el examen: **los roles no tienen credenciales de largo plazo de ningún tipo** — ni contraseña, ni access key.

**A1.4** — De mayor a menor:
1. Opciones de línea de comandos (`--profile`, `--region`)
2. Variables de entorno (`AWS_ACCESS_KEY_ID`, `AWS_SESSION_TOKEN`, …)
3. Configuración de assume-role / web-identity en el archivo de configuración compartido
4. Token de IAM Identity Center (SSO)
5. Archivo de credenciales compartido (`~/.aws/credentials`)
6. Archivo de configuración compartido (`~/.aws/config`)
7. Credenciales de contenedor de ECS (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`)
8. Instance profile de EC2 vía IMDS

El instance profile va **último** deliberadamente: es el recurso de última instancia, así que cualquier credencial configurada explícitamente le gana a la identidad ambiental de la máquina. Esta es también la causa más común de "funciona en mi laptop pero la instancia EC2 usa la identidad equivocada" — una variable de entorno vieja está tapando el rol de la instancia.

**A1.5** — El perfil resuelve `source_profile = default`, usa esas credenciales para llamar a `sts:AssumeRole` contra `LabAuditRole`, y recibe **credenciales temporales** (una access key `ASIA…`, un secreto y un session token) válidas por `duration_seconds` — 3600 s acá, con tope en el `MaxSessionDuration` del rol. La CLI las cachea en `~/.aws/cli/cache/` y las refresca automáticamente cuando expiran. Nunca se almacena ningún secreto propio del rol.

**A1.6** — Un **execution role de Lambda**. Dos propiedades lo hacen estrictamente más seguro: (1) las credenciales son **temporales y rotadas automáticamente** por el servicio Lambda — no hay nada durable que filtrar, y una credencial robada expira sola; (2) **no hay material secreto en reposo** — nada en el paquete de despliegue, el entorno, el repositorio ni el sistema de CI que se pueda commitear o loguear por accidente. Una tercera, muchas veces decisiva en auditorías: los permisos del rol son visibles y auditables en IAM, mientras que el alcance real de una clave pegada es invisible desde la función.

### Ejercicio 2 — Root user

**A2.1** — Porque el esquema del credential report está definido para **usuarios IAM**, y el root user no es un usuario IAM — es la cuenta misma, identificada por `arn:aws:iam::111122223333:root`. Los campos que describen estado específico de usuarios IAM (`password_enabled`, `password_last_changed`, `password_next_rotation`) no tienen sentido para root: root siempre tiene contraseña, esa contraseña no se rige por la política de contraseñas de la cuenta de IAM, y no se puede deshabilitar. IAM devuelve `not_supported` en lugar de un engañoso `true`/`false`. Notá el punto más profundo que esto revela: la política de contraseñas de cuenta que configuraste en el Ejercicio 3 **no** se aplica a root.

**A2.2** — Una access key de root es irrestringible. La clave de un usuario IAM está acotada por las políticas de ese usuario, cualquier permissions boundary y cualquier SCP, y podés revocarla o acotarla en segundos. Una clave de root **no** está sujeta a nada de eso — las SCPs no se aplican al root user de la cuenta de gestión, no se pueden adjuntar políticas de IAM a root, y no existe una ranura de boundary. Una clave de root filtrada es un compromiso total, inmediato e irrecuperable de la cuenta, incluida la capacidad de cerrarla. Remediación: iniciá sesión como root, andá a **Account → Security credentials → Access keys**, y **borrala**. No hay ninguna razón legítima para que exista — cada tarea exclusiva de root de la lista de A2.5 se realiza a través de la Console, no de la API.

**A2.3** — **AWS Security Hub** (mediante el CIS AWS Foundations Benchmark y los estándares AWS Foundational Security Best Practices), respaldado por reglas gestionadas de **AWS Config** como `root-account-mfa-enabled` e `iam-root-access-key-check`, que leen exactamente estos datos. Eso convierte una verificación manual trimestral en un control continuo con un hallazgo que podés derivar a un ticket. **AWS Trusted Advisor** también reporta el MFA de root en sus verificaciones de seguridad.

**A2.4** — `AdministratorAccess` le otorga al *principal de IAM* `arn:aws:iam::111122223333:user/you` un conjunto muy amplio de acciones, pero S3 MFA Delete no está condicionado a ninguna acción de IAM — el servicio S3 verifica si la petición fue firmada con las **credenciales root del dueño del bucket** llevando un código MFA de root, antes de que cualquier evaluación de políticas de IAM sea relevante. El principal de la petición es simplemente del *tipo* equivocado; ninguna política puede aportar lo que falta, porque la verificación no se basa en políticas. Esta es la prueba más limpia disponible de que root no es "el usuario admin con más permisos" sino un principal estructuralmente distinto.

**A2.5** — **"Restaurar permisos de usuarios IAM"** — el root user es el único principal que puede reasignar una política administrativa cuando el último administrador se la quitó a sí mismo. Por eso la contraseña de root **nunca** debe borrarse ni perderse: root es la única vía break-glass de la cuenta para salir de un bloqueo autoinfligido, y el proceso de recuperación de cuenta de AWS ante una credencial root perdida es lento, exige mucha verificación de identidad y depende de que el email y el teléfono de root sigan siendo alcanzables. Guardá la contraseña de root y un dispositivo MFA de respaldo en una caja fuerte física o en una bóveda de contraseñas offline con control de dos personas, y verificá que el email de root sea una lista de distribución monitoreada.

**A2.6** — Una llave de seguridad FIDO2/WebAuthn realiza **autenticación criptográfica ligada al origen**: la llave verifica el dominio que solicita la aserción y se niega a responder a cualquier cosa que no sea el origen real de inicio de sesión de AWS, y la respuesta no puede reproducirse. Por lo tanto derrota el **phishing y los ataques de adversario en el medio (AitM) por proxy** — la clase de ataque que TOTP no detiene, porque un código de seis dígitos tipeado en una página falsa convincente puede retransmitirse al sitio real dentro de su ventana de validez. TOTP igual protege contra un ataque de solo contraseña robada; simplemente no protege contra un atacante que está en el cable.

### Ejercicio 3 — Usuarios, grupos, políticas basadas en identidad

**A3.1** — **No.** Un grupo de IAM no puede ser `Principal` en una política basada en recursos. Un grupo es puramente una **comodidad de gestión de identidades** para adjuntar políticas a un conjunto de usuarios IAM; no es una identidad que pueda autenticarse ni a la que se le pueda otorgar acceso desde el lado del recurso. Tiene un ARN y un ID, pero AWS lo rechaza explícitamente en el elemento `Principal`. La construcción correcta cuando un recurso necesita dar acceso a "un conjunto de personas" es un **rol** que esas personas puedan asumir — el ARN del rol *sí* es un principal válido. Datos relacionados que vale conocer: los grupos no se pueden anidar, un usuario puede pertenecer a varios grupos, y un grupo no puede ser miembro de otro grupo.

**A3.2** — Porque las dos acciones operan sobre **tipos de recurso distintos**, y sus ARNs difieren en forma. `s3:ListBucket` es una operación *a nivel de bucket* — su recurso es `arn:aws:s3:::bucket`, sin `/*` al final. `s3:GetObject` es una operación *a nivel de objeto* — su recurso es `arn:aws:s3:::bucket/key`. Una única sentencia listando ambas acciones contra `bucket/*` no otorgaría silenciosamente nada para `ListBucket`, porque ese ARN nunca hace match con un recurso de tipo bucket. Este es el bug más común en políticas de S3, y se manifiesta como "puedo descargar un archivo si ya sé su nombre, pero `aws s3 ls` devuelve `AccessDenied`". Separar las sentencias también permite que la condición `s3:prefix` se aplique solo donde tiene sentido.

**A3.3** — La condición vive en el elemento **`Condition`** de la sentencia, con la clave de condición global de AWS `aws:SecureTransport`. Un `Deny` es correcto en lugar de un `Allow` acotado por dos razones. Primero, **completitud**: un `Deny` sobre `s3:*` cubre todas las acciones de S3, incluidas las otorgadas por *otras* políticas adjuntas ahora o en el futuro, mientras que acotar el `Allow` de esta política protege solo las acciones que este documento casualmente menciona. Segundo, **precedencia**: un `Deny` explícito no puede ser sobrescrito por ningún `Allow` posterior, así que sobrevive a que alguien adjunte `AmazonS3FullAccess` el trimestre que viene. Esta es la regla general de diseño — expresá los *invariantes* como denies condicionales, y las *concesiones* como allows acotados.

**A3.4** —
- **AWS managed policy**: creada y mantenida por AWS (`arn:aws:iam::aws:policy/…`), reutilizable, versionada por AWS y actualizada automáticamente cuando aparece una nueva acción de servicio. No podés editarla.
- **Customer managed policy**: creada por vos en tu cuenta (`arn:aws:iam::111122223333:policy/…`), adjuntable a muchos principals y versionada — hasta cinco versiones con rollback.
- **Inline policy**: embebida directamente en un único usuario, grupo o rol, con un ciclo de vida estrictamente uno a uno — borrás el principal y la política desaparece con él.

Preferí las managed por la razón operativa de que son **reutilizables, versionadas de forma independiente, auditables centralmente y con capacidad de rollback**: podés responder "¿quién tiene este permiso?" con una sola llamada a `list-entities-for-policy`, y podés revertir un cambio malo. Las inline fragmentan esa respuesta entre todos los principals y no admiten rollback. Las inline siguen siendo legítimamente útiles para un guardrail estrictamente uno a uno donde *querés* que la política sea imposible de reutilizar por accidente en otro lado.

**A3.5** — Un **deny implícito** es el resultado por defecto: ninguna sentencia permitió la acción, y ninguna la denegó tampoco. Es *permisivo por adición* — adjuntá cualquier política con un `Allow` que haga match y la acción queda permitida. Un **deny explícito** viene de una sentencia con `"Effect": "Deny"` que hizo match. Es **final**: ningún `Allow` en ninguna parte — basado en identidad, basado en recursos, política de sesión, lo que sea — puede sobrescribirlo. Solo quitar o acotar la sentencia que deniega cambia el resultado.

**A3.6** — El mensaje detallado "because no identity-based policy allows…" se produce cuando el servicio puede describir el fallo de forma segura. Para `s3:GetObject` sobre un objeto cuya existencia el llamante ni siquiera puede confirmar, S3 devuelve deliberadamente un **`Access Denied` escueto** para evitar filtrar información: una respuesta distinguible entre "no existe esa clave" y "denegado" le permitiría a un llamante no autorizado enumerar el contenido del bucket probando nombres de clave. Esto es ocultamiento de información intencional, y es también por eso que S3 devuelve `403` en lugar de `404` para objetos sobre los que no tenés `ListBucket`. En la práctica: cuando depurés denegaciones de S3, no esperes un mensaje útil — usá CloudTrail, que registra el contexto de autorización completo, o el policy simulator.

**A3.7** —
(a) **Un analista humano**: AWS IAM Identity Center con un permission set, autenticado contra el IdP corporativo, que produce credenciales de sesión de rol de vida corta vía `aws sso login`. No existe ninguna clave que filtrar ni rotar. Si Identity Center no está disponible, el respaldo es un usuario IAM con **asunción de rol forzada por MFA** — nunca una clave pelada.
(b) **Una aplicación en EC2**: un **rol de IAM adjunto vía instance profile**, con IMDSv2 obligatorio. El SDK obtiene y auto-refresca credenciales temporales sin ninguna configuración.

El principio general del documento de mejores prácticas de IAM: *exigí que las cargas de trabajo y los usuarios humanos usen credenciales temporales con un proveedor de identidad*; las access keys de larga duración son la excepción que requiere justificación, no el valor por defecto.

**A3.8** — Dos lecturas: (1) la clave se creó pero **nunca se usó** — genuinamente inactiva, y una fuerte candidata a ser borrada; o (2) la clave **sí** se usó, pero solo hace más de **400 días**, que es el horizonte de los datos de seguimiento — o el uso ocurrió antes de que la región/servicio empezara a reportar. Distinguilas comparando el `CreateDate` de la clave contra la ventana de seguimiento y consultando **CloudTrail** (o CloudTrail Lake / una tabla de Athena sobre un trail en S3) por `userIdentity.accessKeyId` que coincida con la clave. Si la retención de CloudTrail es más corta que la antigüedad de la clave, no podés demostrar el desuso solo con los logs — en ese caso el procedimiento seguro es **desactivar** la clave (`update-access-key --status Inactive`), esperar un ciclo de negocio completo, y borrarla solo si nada se rompió. La desactivación es instantáneamente reversible; el borrado no.

### Ejercicio 4 — Lógica de evaluación de políticas

**A4.1** — Para una única petición, AWS evalúa en este orden, y cualquier **`Deny` explícito** encontrado en cualquier punto termina la evaluación de inmediato con una denegación:
1. **Deny explícito** — verificado a través de todos los tipos de política aplicables; gana incondicionalmente.
2. **Service control policies (SCPs)** — para cuentas en una organización, la acción debe estar permitida por las SCPs de cada nodo desde la raíz hasta la cuenta. Una SCP no otorga nada; solo acota.
3. **Resource control policies (RCPs)** — límites a nivel de organización sobre lo que las políticas basadas en recursos pueden otorgar.
4. **Session policies** — si las credenciales vinieron de `AssumeRole` con un argumento `--policy`, la acción debe estar dentro de esa política.
5. **Permissions boundaries** — si el principal tiene una, la acción debe estar permitida por ella.
6. **Políticas basadas en identidad y basadas en recursos** — al menos una debe permitir explícitamente (`Allow`).
7. Si nada la permitió → **deny implícito** (el valor por defecto).

La forma comprimida para el examen: *deny explícito > allow explícito > deny implícito (por defecto)*, con SCPs, boundaries y session policies actuando como **filtros que solo pueden restar**.

**A4.2** — Una **service control policy** con un `Deny` explícito sobre `s3:DeleteBucket`, adjunta a la unidad organizativa que contiene esas 12 cuentas. Se evalúa en la **capa de la organización**, por encima e independientemente de toda política de IAM en cada cuenta miembro — de modo que ningún administrador de cuenta, por privilegiado que sea, puede volver a otorgar la acción. Un documento, una asignación, 400 principals cubiertos, y los principals nuevos cubiertos automáticamente en el momento en que se crean. (Una permissions boundary requeriría adjuntarse a cada uno de los 400 principals individualmente y no sobreviviría a que un administrador la desasocie.)

**A4.3** — El acceso entre cuentas requiere **dos** `Allow`: uno en una **política basada en identidad** sobre el principal de la cuenta A (permitiendo la acción sobre el recurso en B), y otro en la **política basada en recursos** del recurso en la cuenta B (nombrando al principal de A). Ninguno alcanza por sí solo — no hay confianza implícita entre cuentas. Esto contrasta con el caso de **misma cuenta**, donde un `Allow` en *cualquiera* de las dos — la política basada en identidad *o* la basada en recursos — es suficiente. La excepción que vale conocer: para los **roles de IAM**, la política de confianza del rol cumple el papel de la política de recurso, y el `sts:AssumeRole` entre cuentas sigue la misma regla de ambos lados.

**A4.4** — **A favor del Deny**: es *defensa en profundidad*. Los permisos derivan — alguien adjunta una managed policy amplia en una emergencia, una automatización otorga `s3:*`, un equipo nuevo copia una política vieja. Un `Deny` explícito sobre las acciones destructivas se mantiene sin importar qué adjunte nadie después, y no puede ser sobrescrito. Expresa el invariante "nunca borramos buckets" independientemente de quién tenga qué.

**En contra de confiar solo en él**: un `Deny` explícito es un *supresor de síntomas*, no una cura. `AmazonS3FullAccess` sigue adjunto, así que el principal conserva todos los demás permisos excesivos que el Deny no enumera — y el Deny solo lista las acciones que a alguien se le ocurrieron. Además vuelve difícil razonar sobre el conjunto efectivo de permisos: leer las políticas adjuntas ya no te dice qué puede hacer el principal. La postura correcta es **ambas** — acotar la concesión *y* mantener el guardrail — con el Deny en la capa organizativa (SCP) donde no puede desasociarse, no inline sobre un usuario donde sí.

### Ejercicio 6 — Políticas basadas en recursos

**A6.1** — Los servicios que soportan políticas basadas en recursos incluyen **Amazon S3** (bucket policies), **AWS KMS** (key policies — notablemente *obligatorias*, una clave de KMS siempre tiene una), **Amazon SQS** (queue policies), **Amazon SNS** (topic policies), **AWS Lambda** (políticas de recurso de función), **Amazon EventBridge** (políticas de event bus), **Secrets Manager**, **API Gateway**, **ECR**, **EFS**, y los propios **roles de IAM** (la política de confianza). Ostensiblemente **sin** una: **Amazon EC2** — no existe una "política de instancia", así que el acceso entre cuentas a EC2 debe otorgarse mediante un rol en la cuenta propietaria que el principal externo asume. **Amazon RDS** (el plano de control) y **DynamoDB** también son ejemplos citados habitualmente que dependen de políticas de identidad de IAM y roles en lugar de políticas de recurso.

**A6.2** — `aws:PrincipalOrgID` ata la concesión a la *pertenencia a tu organización* en lugar de a un ID de cuenta específico. Defiende contra el **problema de la cuenta obsoleta y de la transferencia de cuenta**: un ID de cuenta hardcodeado en una bucket policy sigue funcionando después de que esa cuenta abandona tu organización, se vende, o se da de baja y su ID se reutiliza en otro contexto de confianza. También elimina toda una clase de error de mantenimiento — ya no necesitás editar decenas de bucket policies cada vez que una cuenta entra o sale. Claves relacionadas con el mismo espíritu: `aws:PrincipalOrgPaths` (acotar a una OU específica) y `aws:SourceOrgID`.

**A6.3** — Una **política basada en identidad** adjunta a `PartnerReaderRole` en la cuenta `444455556666`, permitiendo `s3:GetObject` y `s3:ListBucket` sobre los mismos ARNs. Esta es la regla de ambos lados de A4.3: la bucket policy es la mitad del acuerdo que aporta el dueño del recurso, y la política de IAM del partner es la mitad del llamante. El administrador del partner controla su mitad — no podés otorgar permisos dentro de su cuenta desde tu bucket policy, solo permitirlos.

**A6.4** — Los dos alcances son (1) **el bucket** — `PublicAccessBlockConfiguration` sobre un bucket individual, y (2) **la cuenta** — vía la API de S3 Control (`s3control put-public-access-block`), que aplica a todos los buckets de la cuenta, presentes y futuros. El ajuste **a nivel de cuenta** es el que un equipo de aplicación no puede sobrescribir: tiene precedencia, así que ni siquiera el dueño de un bucket que ponga los flags a nivel de bucket en `false` puede hacerlo público. En una organización, una SCP que deniegue `s3:PutAccountPublicAccessBlock` y `s3:PutBucketPublicAccessBlock` fija eso de forma permanente. Notá además que estos cuatro ajustes están **activados por defecto en todos los buckets nuevos desde abril de 2023**.

### Ejercicio 7 — Guardrails

**A7.1** — **No, no otorga nada.** Una permissions boundary es un **techo, no una concesión**. Los permisos efectivos del principal son la **intersección** de (a) lo que permiten sus políticas basadas en identidad y (b) lo que permite la boundary — y un `Deny` explícito en cualquiera de las dos gana rotundamente igual. Con solo una boundary y ninguna política adjunta, el principal no puede hacer absolutamente nada. El modelo mental que sobrevive al examen: las políticas de identidad dicen *qué podés hacer*; la boundary dice *lo máximo que alguna vez podrías tener permitido hacer*.

**A7.2** — Previene la **escalada de privilegios por eliminación de la boundary**. Sin esa línea, un principal con `AdministratorAccess` *dentro* de la boundary podría llamar a `iam:DeleteUserPermissionsBoundary` sobre sí mismo, disolviendo el techo y convirtiéndose instantáneamente en un administrador real de la cuenta. El mismo razonamiento cubre `iam:PutUserPolicy`, `iam:AttachUserPolicy`, `iam:CreateUser` e `iam:CreateRole` en esa lista de Deny: cada uno es una vía para acuñar u otorgar privilegios que la boundary pretendía retener. La regla general de diseño para la administración delegada: **una boundary debe denegar las acciones de IAM que podrían modificar la boundary o crear un principal sin techo.** La alternativa segura cuando los desarrolladores necesitan legítimamente crear roles es exigir, mediante condición, que todo rol que creen lleve la misma boundary (clave de condición `iam:PermissionsBoundary`).

**A7.3** — Las permissions boundaries se adjuntan a **usuarios IAM** y **roles IAM**. **No** pueden adjuntarse a **grupos de IAM** — ni a una cuenta o unidad organizativa, que es tarea de la SCP. (Consistente con A3.1: un grupo no es una identidad, así que no tiene un techo de permisos propio; la boundary vive en los usuarios que lo integran.)

**A7.4** — No pueden hacer **nada**. Esta es la propiedad definitoria de una SCP: **nunca otorga permisos**, solo define el conjunto máximo de permisos que las políticas de IAM de la cuenta *tienen permitido* otorgar. `FullAWSAccess` simplemente se abstiene de restringir algo; la concesión efectiva debe seguir viniendo de una política de IAM basada en identidad (o de una política basada en recursos) dentro de la cuenta. El corolario que hace tropezar a la gente: adjuntar una SCP *permisiva* para arreglar un problema de acceso nunca funciona — la pieza faltante siempre es una política de IAM.

**A7.5** — Las SCPs no se aplican al **root user de la cuenta de gestión** — y más ampliamente, ninguna SCP restringe la cuenta de gestión en absoluto, sin importar qué principal de ella haga la llamada. La consecuencia operativa es doble. Primero, la cuenta de gestión es tu **vía break-glass**: si una SCP falla y deja a todas las cuentas de carga de trabajo sin algo crítico, la desasociás desde la cuenta de gestión, cosa que ninguna SCP puede impedir. Segundo, y más importante, la cuenta de gestión debe por lo tanto tratarse como el **objetivo de mayor valor de la organización** — no debería alojar cargas de trabajo, tener casi ningún principal, tener root con MFA por llaves de hardware y sin access keys, y estar monitoreada agresivamente. Todo lo demás en la organización está defendido por SCPs; la cuenta de gestión está defendida solo por su propia higiene. (Notá también que las SCPs no afectan a los service-linked roles.)

**A7.6** —

| Eje | Service control policy | Permissions boundary |
|---|---|---|
| **Se adjunta a** | Raíz de la organización, OU o cuenta miembro | Un usuario o rol IAM individual |
| **Dueño habitual** | El equipo central de seguridad / plataforma cloud, en la cuenta de gestión — fuera del alcance de los admins de cuenta | El administrador de la cuenta o delegado que crea el principal |
| **Cuando no existe** | Nada se restringe en la capa organizativa; deciden solo las políticas de IAM | No hay techo; deciden solo las políticas basadas en identidad del principal |

Ambas son **filtros, no concesiones**, y ambas solo pueden restar de lo que las políticas de IAM permiten. La división práctica del trabajo: las SCPs expresan **invariantes de toda la organización** ("nadie, en ningún lado, puede deshabilitar CloudTrail" / "solo estas regiones"); las boundaries expresan **límites de delegación** ("este equipo puede crear roles, pero nada más poderoso que esto").

**A7.7** — `NotAction` significa "todas las acciones *excepto* estas", así que el `Deny` se aplica a todos los servicios *distintos* de los listados. Los servicios listados son **globales**: IAM, Organizations, STS, CloudFront, Route 53, Support, Budgets y WAF tienen endpoints que resuelven a `us-east-1` (o son agnósticos de región), y sus llamadas a la API llevan valores de `aws:RequestedRegion` que una restricción de regiones ingenua rechazaría. Excluirlos evita que el guardrail rompa operaciones esenciales del plano de control.

Si `iam:*` **no** estuviera excluido, toda llamada a IAM hecha desde fuera de `us-east-1`/`eu-west-1` sería denegada — incluida `iam:CreateServiceLinkedRole`, que muchos servicios invocan implícitamente. Las operaciones de consola en regiones restringidas fallarían de formas confusas, la creación de service-linked roles se rompería en el primer uso de numerosos servicios y, en el peor caso, un administrador trabajando desde una región restringida podría quedarse afuera por completo de la gestión de IAM. La lección general: **las SCPs de restricción de regiones siempre deben exceptuar a los servicios globales**, y deberían probarse en una OU sandbox antes de adjuntarse en cualquier lugar cercano a producción.

### Ejercicio 8 — ABAC

**A8.1** — **RBAC** otorga permisos nombrando recursos (o patrones de ARN de recursos) explícitamente en políticas adjuntas a roles/grupos: una política por equipo, listando los recursos de ese equipo. **ABAC** otorga permisos **comparando atributos** — tags del principal contra tags del recurso — de modo que una sola política expresa la regla para todos.

La propiedad de escalado: con RBAC, agregar el equipo número 201 significa escribir y adjuntar una política número 201, y agregar un recurso implica editar una política. Con ABAC, **la cantidad de políticas se mantiene en una** — incorporás un equipo etiquetando sus principals y sus recursos, lo que es una acción de aprovisionamiento común y no un cambio de seguridad. Esto también te mantiene lejos de las cuotas de IAM sobre managed policies por principal y tamaño del documento de política, que RBAC alcanza primero en organizaciones grandes.

**A8.2** — La variable de política `${aws:PrincipalTag/Project}` **no tiene valor que resolver**, así que la condición no puede hacer match y la sentencia no aplica — el resultado es un **deny implícito**. *No* falla de forma abierta, y no hace match con "cualquier proyecto". Este es el modo de fallo correcto y seguro, pero hace que la usabilidad de ABAC dependa por completo de la **higiene de tags**: un principal sin tags pierde el acceso silenciosamente, y el mensaje de error no va a decir por qué. Por eso el ABAC en producción acompaña la política con enforcement — una SCP que exija `Project` al crear principals, o tags mapeados automáticamente desde atributos del IdP para que no puedan omitirse.

**A8.3** — Bloquea la **escalada de privilegios basada en tags mediante re-etiquetado**. Sin una restricción sobre `ec2:CreateTags`, un principal etiquetado `Project=apollo` podría simplemente reetiquetar una instancia de `gemini` como `Project=apollo` y después detenerla legítimamente — la regla ABAC otorgaría alegremente acceso a un recurso que el principal acaba de hacer "suyo". La condición `aws:RequestTag/Project` fuerza a que cualquier tag que el principal escriba coincida con su propio tag de proyecto, así que no puede acuñar acceso a recursos de otros. El mismo razonamiento exige proteger **`ec2:DeleteTags`** (quitar un tag también puede cambiar el resultado) — una versión de producción real de esta política incluiría un `Deny` sobre `ec2:DeleteTags` para la clave `Project` vía `aws:TagKeys`. **En cualquier diseño ABAC, las APIs de etiquetado son parte del perímetro de seguridad.**

**A8.4** — De los **session tags** de la sesión de rol. Cuando un usuario se federa a través de IAM Identity Center o de un IdP SAML/OIDC, los atributos del directorio (departamento, centro de costos, proyecto) se mapean a la llamada de assume-role — vía `sts:TagSession` y el atributo SAML `https://aws.amazon.com/SAML/Attributes/PrincipalTag:Project`, o en Identity Center mediante **attributes for access control**, configurados en la consola de Identity Center y tomados del almacén de identidades o del IdP externo. Esos pasan a ser `aws:PrincipalTag/*` durante la sesión. Esto es lo que hace a ABAC genuinamente potente: el atributo de autorización se mantiene en el directorio corporativo mediante procesos de RR. HH./IT, así que una persona que cambia de equipo cambia su acceso a AWS automáticamente en el siguiente inicio de sesión, sin ningún cambio en IAM.

### Ejercicio 9 — Federación, Identity Center, secretos

**A9.1** — **Cero usuarios IAM.** Lo que existe en cada una de las tres cuentas es un **rol** de IAM, aprovisionado y gestionado por IAM Identity Center, con un nombre de la forma `AWSReservedSSO_<PermissionSetName>_<hash>`. El usuario se autentica una vez contra la fuente de identidad; Identity Center luego lo federa a la cuenta seleccionada haciéndole asumir el rol correspondiente, y STS emite una sesión de vida corta. La identidad del usuario vive en exactamente un lugar — el almacén de identidades o el IdP externo — y desaprovisionarla ahí elimina el acceso a todas las cuentas de una sola vez. Compará esto con el modelo de usuarios IAM, donde dar de baja significa ir a cazar objetos de usuario en cada cuenta.

**A9.2** — Las tres fuentes de identidad son: (1) el **directorio integrado de Identity Center**, (2) **Active Directory** — ya sea AWS Managed Microsoft AD o un dominio on-premises alcanzado mediante AD Connector, y (3) un **proveedor de identidad externo** vía SAML 2.0/OIDC, con SCIM para el aprovisionamiento automático de usuarios y grupos.

Para una empresa que ya usa **Microsoft Entra ID**, elegí la opción de **proveedor de identidad externo**: conectá Entra ID como IdP SAML y habilitá el **aprovisionamiento SCIM** para que usuarios y grupos se sincronicen automáticamente. Esto mantiene un único directorio autoritativo, hereda las políticas de MFA y acceso condicional existentes de la organización, y hace que la baja en RR. HH. se propague a AWS sin un paso aparte.

**A9.3** — (1) **Las credenciales son temporales y expiran automáticamente** — la sesión termina en `SessionDuration`, así que no hay un secreto durable que robar, rotar o encontrar en el historial de Git. (2) **Ciclo de vida centralizado en todas las cuentas** — una asignación otorga o revoca acceso a muchas cuentas a la vez, y deshabilitar al usuario en el IdP es instantáneo y total; los usuarios IAM hay que crearlos, auditarlos y borrarlos cuenta por cuenta. (3) **Aplican los controles de autenticación del IdP corporativo** — MFA empresarial, acceso condicional, postura del dispositivo, revocación de sesión, y el proceso existente de alta/movimiento/baja, en ninguno de los cuales participa una access key de IAM. (Una cuarta, muchas veces decisiva en auditorías: el inicio de sesión es atribuible a un **humano con nombre** en el directorio, y los permission sets se gestionan como objetos reutilizables y versionados en lugar de copias de políticas por cuenta.)

**A9.4** —
- **(a) 40 000 clientes de una app móvil → Amazon Cognito.** Son los usuarios finales de *tu aplicación*, no gente que necesita acceso a la API de AWS. Un **user pool** de Cognito provee el directorio de registro/inicio de sesión, la UI alojada, federación social y empresarial, y MFA; un **identity pool** de Cognito puede además intercambiar un token verificado por credenciales temporales de AWS acotadas, cuando la app debe llegar directamente a servicios de AWS. Los usuarios IAM son categóricamente incorrectos acá — hay una cuota dura de usuarios IAM por cuenta (5.000), e IAM no es un sistema de identidad de clientes.
- **(b) 300 empleados, 25 cuentas → AWS IAM Identity Center.** Exactamente el problema para el que existe: una identidad, permission sets asignados a grupos, credenciales temporales, desaprovisionamiento central.
- **(c) Trabajo batch heredado on-premises → un usuario IAM con una access key**, como la excepción documentada — pero primero verificá si aplica **IAM Roles Anywhere**: permite que cargas de trabajo on-premises usen certificados X.509 de tu PKI para obtener credenciales temporales, eliminando la clave de larga duración. Si una clave estática es genuinamente inevitable, acotala a una política mínima, agregá claves de condición que restrinjan `aws:SourceIp` al rango de salida del centro de datos, monitoreá `get-access-key-last-used`, y rotala según un cronograma.

**A9.5** — La capacidad distintiva de Secrets Manager es la **rotación automática integrada**: invoca una función Lambda de rotación según un cronograma y, para destinos soportados (RDS, Aurora, Redshift, DocumentDB), trae lógica de rotación ya hecha que cambia la credencial tanto en el secreto como en la base de datos, con versiones escalonadas (`AWSCURRENT`/`AWSPENDING`) para no romper a los clientes en vuelo. Parameter Store no tiene motor de rotación. Secrets Manager también soporta **replicación entre regiones** de secretos y **políticas basadas en recursos** sobre el secreto.

Aun así podrías elegir **Parameter Store** porque los parámetros de nivel estándar son **gratuitos** (Secrets Manager cobra aproximadamente USD 0,40 por secreto por mes más los cargos de API), se integra naturalmente con datos de configuración que no son secretos, y es el hogar correcto para el gran volumen de ajustes que no rotan y conviven con un puñado de secretos verdaderos. Un patrón común en producción: Parameter Store para configuración y SecureStrings estáticas, Secrets Manager para todo lo que deba rotar.

**A9.6** — (1) La **política de IAM basada en identidad** sobre el principal que llama, que debe permitir `secretsmanager:GetSecretValue` sobre el ARN del secreto — esto controla *quién puede preguntar*. (2) La **política basada en recursos del propio secreto**, que controla *a quién le responde el secreto*, y es lo que habilita el acceso entre cuentas. En los hechos hay una tercera capa: la **key policy de KMS** de la clave gestionada por el cliente que cifra el secreto — el principal también necesita `kms:Decrypt`, así que una key policy de KMS puede denegar el acceso de forma independiente incluso cuando ambas políticas de Secrets Manager lo permiten. Esa capa de KMS es una causa frecuente y fácil de pasar por alto de "AccessDenied" en un secreto compartido entre cuentas que por lo demás está correcto.

### Ejercicio 10 — Ajuste a medida

**A10.1** — La remediación es **reemplazar `AmazonS3FullAccess` por una política acotada** que otorgue solo las acciones y recursos realmente ejercidos — acá, `s3:GetObject` (y `s3:ListBucket`) sobre el bucket y prefijo específicos — y eliminar por completo el resto de los permisos de servicios no usados. La característica de **generación de políticas** de IAM Access Analyzer puede redactar esa política directamente a partir del historial de CloudTrail, lo que es más rápido y menos propenso a errores que escribirla a mano.

No automatizarías esto a ciegas porque **la ausencia de uso no es ausencia de necesidad**. Un proceso de conciliación de cierre de trimestre, una exportación anual de cumplimiento, un runbook de recuperación ante desastres o una ruta de respuesta a incidentes que rara vez se dispara pueden legítimamente no aparecer en una ventana de 90 días. El horizonte de seguimiento de Access Advisor también es finito. El procedimiento seguro es el mismo que para las access keys: achicá la política, pero **escaloná el cambio** — anuncialo, aplicalo primero en una cuenta que no sea de producción, conservá la versión anterior de la política para un rollback de un clic (las customer managed policies guardan cinco versiones) y monitoreá CloudTrail por nuevos eventos `AccessDenied` atribuibles al cambio durante al menos un ciclo de negocio completo.

**A10.2** — El analizador de **acceso externo** responde *"¿hay algo en mi cuenta alcanzable por un principal fuera de mi zona de confianza?"* — usa razonamiento automatizado sobre políticas basadas en recursos (buckets de S3, claves de KMS, roles de IAM, funciones Lambda, colas de SQS, secretos de Secrets Manager y más) para encontrar accesos compartidos con otras cuentas, organizaciones o internet público. Escenario: una revisión trimestral que confirma que ningún bucket ni rol se volvió accesible externamente sin que nadie lo notara.

El analizador de **acceso no utilizado** responde *"¿qué permisos, roles, usuarios y access keys no se usaron?"* — impulsa la remediación hacia el mínimo privilegio. Escenario: la limpieza del Ejercicio 10, a escala, en toda una organización.

**El analizador de acceso externo es gratuito.** El de acceso no utilizado se cobra por rol IAM y usuario IAM analizado por mes. (La validación de políticas vía `validate-policy` y la generación de políticas también son gratuitas.)

**A10.3** — Lo **archivás**, idealmente creando una **regla de archivado** en lugar de descartar hallazgo por hallazgo. Una regla de archivado hace match por criterios — ARN del recurso, cuenta del principal, tipo de recurso, clave de condición — y archiva automáticamente los hallazgos actuales y futuros que encajen, de modo que el acceso compartido intencional deja de aparecer en la cola activa pero sigue visible en la lista de archivados para auditoría. El valor operativo es la relación señal-ruido: una vez que todo acceso externo *conocido* está archivado con una regla documentada, cualquier hallazgo `ACTIVE` **nuevo** es, por construcción, algo que nadie aprobó, lo que lo vuelve digno de alertar. Los hallazgos deberían archivarse con una justificación registrada (ticket, responsable, fecha de revisión), y las propias reglas de archivado revisarse periódicamente — una regla de archivado es una excepción permanente, y las excepciones permanentes se pudren.

**A10.4** — Bajo el modelo de responsabilidad compartida, la gestión de accesos cae del lado del cliente de la línea, con AWS responsable del mecanismo:

- **AWS** — "seguridad **de** la nube": AWS opera el propio servicio IAM, garantizando su disponibilidad, corrección y durabilidad; autentica y autoriza cada petición de API contra las políticas que vos configurás; protege la infraestructura subyacente, el plano de datos global de IAM, la verificación de firmas y la seguridad física de las instalaciones.
- **El cliente** — "seguridad **en** la nube": *todo lo relativo a la configuración*. Qué principals existen; qué otorgan las políticas; hacer cumplir el mínimo privilegio; habilitar y exigir MFA; proteger y no usar el root user; rotar o eliminar credenciales; elegir federación por sobre claves de larga duración; definir SCPs y boundaries; revisar los hallazgos de Access Analyzer y los datos de Access Advisor; y monitorear CloudTrail por uso indebido.

La versión filosa: **AWS garantiza que tus políticas se apliquen exactamente como están escritas. AWS no garantiza que estén escritas correctamente.** Una política excesivamente permisiva es enteramente una falla del cliente, y es la causa raíz más común en incidentes reales de seguridad en AWS. Notá además que esta división se corre según el modelo de servicio — para un servicio gestionado como Lambda o S3 la porción del cliente es menor (no hay sistema operativo que parchear) pero la responsabilidad de configuración de IAM es **idéntica en todos los servicios**, que es precisamente por qué la gestión de accesos es el control de mayor apalancamiento que posee un cliente.

</details>

---

## Lista consolidada de fuentes

- Guía del examen AWS Certified Cloud Practitioner (CLF-C02) — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Mejores prácticas de seguridad en IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Lógica de evaluación de políticas — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Tareas que requieren credenciales de root user — https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
- Gestión centralizada de acceso root — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html
- Obtener credential reports para tu cuenta de AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html
- Uso de MFA en AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html
- Roles de IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html
- Referencia de la API `AssumeRole` de AWS STS — https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
- Proveedores de identidad y federación — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html
- Permissions boundaries para entidades de IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Control de acceso basado en atributos (ABAC) para AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html
- Elementos de política de IAM: variables y tags — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html
- Claves de contexto de condición globales de AWS — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
- Políticas basadas en identidad y políticas basadas en recursos — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html
- Acceso a recursos entre cuentas en IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies-cross-account-resource-access.html
- Uso de bucket policies — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html
- Bloquear el acceso público a tu almacenamiento de Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- Configurar el instance metadata service (IMDSv2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- Qué es IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- Refinar permisos usando información de último acceso — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html
- Qué es AWS IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- Qué es Amazon Cognito — https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html
- Guía del usuario de AWS Secrets Manager — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- Ajustes de los archivos de configuración y credenciales (AWS CLI) — https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
- Proveedores de credenciales estandarizados (AWS SDKs) — https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
- Modelo de responsabilidad compartida — https://aws.amazon.com/compliance/shared-responsibility-model/