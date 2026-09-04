# AWS Certified Cloud Practitioner (CLF-C02) — Dominio 3, Enunciado de tarea 3.1

## Definir métodos de despliegue y operación en la nube de AWS

**Peso en el examen del dominio padre (Cloud Technology and Services): 34% — este enunciado de tarea se puntúa con 4.25 en la ponderación normalizada de la plataforma.**

**Fuente de registro:** [AWS Certified Cloud Practitioner (CLF-C02) Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf) — el enunciado de tarea 3.1 enumera tres áreas de conocimiento: *distintas formas de aprovisionar y operar* (acceso programático / API / SDK / CLI, la AWS Management Console, Infrastructure as Code), *distintos modelos de despliegue* (nube, híbrido, on-premises) y *opciones de conectividad* (VPN, AWS Direct Connect, internet público).

---

## Qué vas a construir realmente

Estos ejercicios no son una secuencia de clics. Vas a:

1. Demostrar que las cuatro interfaces de aprovisionamiento convergen en **una sola** cosa — la API HTTPS firmada — y observar esa convergencia en CloudTrail.
2. Leer una firma SigV4 real tal como viaja por la red y explicar cada uno de sus cinco componentes.
3. Aprovisionar un stack de forma declarativa con CloudFormation, y luego **cambiarlo** mediante un change set en vez de una actualización directa.
4. Romper el stack deliberadamente y diagnosticar el fallo desde `describe-stack-events` en lugar de la consola.
5. Introducir drift fuera de banda y detectarlo programáticamente.
6. Enumerar la huella real de edge/híbrida de una Región (Local Zones, Wavelength Zones, Outposts, ubicaciones de Direct Connect) con llamadas de API de solo lectura.
7. Construir una matriz de decisión de conectividad respaldada por los atributos que las APIs devuelven de verdad.

---

## Requisitos previos y controles de costo

**Leé este bloque antes de ejecutar nada.**

| Requisito | Comando de verificación | Notas |
|---|---|---|
| AWS CLI v2 | `aws --version` | v1 está fuera de soporte; `aws configure sso` se comporta distinto |
| Una cuenta de AWS con un principal equivalente a admin | `aws sts get-caller-identity` | Se prefiere ampliamente un rol de IAM Identity Center antes que claves de usuario IAM de larga duración |
| Python 3.9+ y `boto3` | `python3 -c "import boto3; print(boto3.__version__)"` | para el Ejercicio 2 |
| `jq` (opcional, pero asumido en las salidas) | `jq --version` | |

**Costo:** los ejercicios 1, 2, 6, 7 y 8 son **de solo lectura o de capa gratuita**. Los ejercicios 3–5 crean un bucket de S3, un parámetro de SSM Parameter Store (tier Standard — gratuito) y un stack de CloudFormation. CloudFormation en sí no cobra por tipos de recurso nativos de AWS; solo pagás por lo que crea. Gasto total esperado si completás la sección de limpieza: **menos de $0.01**. Nada de esto crea un NAT Gateway, una conexión Site-to-Site VPN ($0.05/hora), un puerto de Direct Connect ni un Outpost.

**Definí tu contexto de trabajo una sola vez:**

```bash
export AWS_PROFILE=clf-lab
export AWS_REGION=us-east-1
export LAB_PREFIX="clf31-$(date +%s | tail -c 6)"
echo "Lab prefix: ${LAB_PREFIX}"
```

```
Lab prefix: clf31-83291
```

> Cada recurso que creás lleva `${LAB_PREFIX}` en el nombre. La sección de limpieza borra exactamente ese conjunto.

---

## Ejercicio 1 — Las cuatro interfaces son una sola interfaz

**Objetivo:** demostrar que la Console, la CLI, un SDK y CloudFormation son todos *clientes* de la misma API HTTPS del servicio, y que CloudTrail registra la diferencia únicamente en los metadatos.

Este es el concepto que más carga estructural soporta en el enunciado de tarea 3.1. El examen pregunta "qué métodos pueden aprovisionar recursos"; producción pregunta "qué método dejó este recurso acá, y puedo reproducirlo".

### Pasos

1. Confirmá la versión de tu CLI y tu identidad. Fijate en la forma del ARN — un ARN `assumed-role` significa que estás con credenciales temporales; un ARN `iam-user` significa claves de larga duración.

   ```bash
   aws --version
   aws sts get-caller-identity
   ```

   ```
   aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.fedora.41
   ```
   ```json
   {
       "UserId": "AROA4EXAMPLEID:platform-eng",
       "Account": "111122223333",
       "Arn": "arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_PlatformEngineer_1a2b3c/platform-eng"
   }
   ```

2. Inspeccioná desde dónde se resuelve cada elemento de tu configuración. La columna `Location` es todo el punto — la CLI fusiona variables de entorno, el archivo de configuración compartido, el archivo de credenciales compartido y los flags de línea de comandos siguiendo un orden de precedencia definido.

   ```bash
   aws configure list
   ```

   ```
         Name                    Value             Type    Location
         ----                    -----             ----    --------
      profile                  clf-lab           manual    --profile
   access_key     ****************ABCD              sso
   secret_key     ****************wXyZ              sso
       region                 us-east-1              env    AWS_REGION
   ```

3. Creá un parámetro de SSM mediante la **CLI**:

   ```bash
   aws ssm put-parameter \
     --name "/${LAB_PREFIX}/origin/cli" \
     --value "created-by-cli" \
     --type String \
     --tier Standard
   ```

   ```json
   {
       "Version": 1,
       "Tier": "Standard"
   }
   ```

4. Creá un segundo parámetro mediante un **SDK** (boto3), para que el user agent sea distinto:

   ```bash
   python3 - <<'PY'
   import os, boto3
   ssm = boto3.client("ssm")
   r = ssm.put_parameter(
       Name=f"/{os.environ['LAB_PREFIX']}/origin/sdk",
       Value="created-by-sdk",
       Type="String",
       Tier="Standard",
   )
   print(r["Version"], r["Tier"])
   PY
   ```

   ```
   1 Standard
   ```

5. Creá un tercero mediante la **AWS Management Console**: navegá a *Systems Manager → Parameter Store → Create parameter*, nombralo `/${LAB_PREFIX}/origin/console`, tipo `String`, valor `created-by-console`.

6. Esperá ~10–15 minutos (el Event history de CloudTrail no es en tiempo real) y después leé la *procedencia* de los tres:

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutParameter \
     --max-results 10 \
     --query 'Events[].CloudTrailEvent' \
     --output text \
   | jq -r '[.eventTime, (.requestParameters.name), .userAgent] | @tsv'
   ```

   ```
   2026-09-04T14:22:31Z    /clf31-83291/origin/console    AWS Internal
   2026-09-04T14:19:04Z    /clf31-83291/origin/sdk        Boto3/1.34.98 md/Botocore#1.34.98 ua/2.0 os/linux#6.5.0 md/arch#x86_64 lang/python#3.12.4 cfg/retry-mode#legacy Botocore/1.34.98
   2026-09-04T14:18:47Z    /clf31-83291/origin/cli        aws-cli/2.17.42 md/awscrt#0.20.11 ua/2.0 os/linux#6.5.0 md/arch#x86_64 lang/python#3.11.9 cfg/retry-mode#standard
   ```

7. Compará los campos `eventName`, `eventSource` y `readOnly` en los tres registros:

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=PutParameter \
     --max-results 3 --query 'Events[].CloudTrailEvent' --output text \
   | jq -r '[.eventSource, .eventName, (.readOnly|tostring), .managementEvent|tostring] | @tsv'
   ```

   ```
   ssm.amazonaws.com    PutParameter    false    true
   ssm.amazonaws.com    PutParameter    false    true
   ssm.amazonaws.com    PutParameter    false    true
   ```

### Comprobación de comprensión — Bloque 1

- **Q1.1** — Tres interfaces distintas produjeron tres registros de CloudTrail con `eventSource` y `eventName` *idénticos*. ¿Qué te dice eso sobre la relación arquitectónica entre la Console, la CLI y el SDK?
- **Q1.2** — El evento originado en la Console muestra `userAgent: "AWS Internal"` en vez de una cadena de navegador. Explicá el mecanismo que produce esto, y por qué no aparece el user agent del propio navegador.
- **Q1.3** — Un colega argumenta que "la Console es un método de aprovisionamiento *distinto* de la API, así que necesita una estrategia de auditoría separada". Refutalo o respaldalo usando la salida del paso 7.
- **Q1.4** — ¿Qué campo único de un registro de CloudTrail usarías para construir una alerta de "alguien aprovisionó infraestructura de producción a mano en lugar de a través del pipeline"? Nombrá el campo y describí el predicado exacto.
- **Q1.5** — En el paso 2, `region` se resolvió desde `env`. Enumerá el orden de precedencia de configuración de la CLI de mayor a menor, e indicá dónde se ubica un flag `--region`.

---

## Ejercicio 2 — Acceso programático: la firma, el reintento, el paginador

**Objetivo:** abrir la caja negra del "acceso programático". No podés razonar sobre aprovisionamiento basado en API si tratás al SDK como magia.

### Pasos

1. Capturá la petición firmada en crudo que emite la CLI. `--debug` escribe la petición canónica, el string-to-sign y el header `Authorization` final a stderr.

   ```bash
   aws s3api list-buckets --debug 2>&1 \
     | grep -o "AWS4-HMAC-SHA256 Credential=[^,]*, SignedHeaders=[^,]*, Signature=[0-9a-f]\{16\}" \
     | head -1
   ```

   ```
   AWS4-HMAC-SHA256 Credential=ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=9f2a4c1b7e0d3a55
   ```

2. Extraé el credential scope por separado — los cuatro componentes separados por barras que van después del access key ID:

   ```bash
   aws s3api list-buckets --debug 2>&1 \
     | grep -oP 'Credential=\K[^,]*' | head -1
   ```

   ```
   ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request
   ```

3. Observá que un *servicio distinto* cambia el scope, lo que demuestra que la firma está atada al servicio y a la región:

   ```bash
   aws ssm describe-parameters --debug 2>&1 \
     | grep -oP 'Credential=\K[^,]*' | head -1
   ```

   ```
   ASIA4EXAMPLEKEYID/20260904/us-east-1/ssm/aws4_request
   ```

4. Configurá un comportamiento de reintento explícito. Agregá a `~/.aws/config` bajo tu perfil:

   ```ini
   [profile clf-lab]
   region     = us-east-1
   output     = json
   retry_mode = standard
   max_attempts = 5
   ```

   Después confirmá que el SDK lo reporta:

   ```bash
   aws ssm describe-parameters --debug 2>&1 | grep -i "retry" | head -3
   ```

   ```
   2026-09-04 14:31:02,118 - MainThread - botocore.retries.standard - DEBUG - Registering retry handler for operation DescribeParameters with mode standard
   2026-09-04 14:31:02,119 - MainThread - botocore.retries.standard - DEBUG - Max attempts: 5
   2026-09-04 14:31:02,556 - MainThread - botocore.retries.standard - DEBUG - Not retrying request (no retry policy matched)
   ```

5. Demostrá la paginación. Toda API List/Describe en AWS está paginada; el SDK te lo oculta solo si se lo pedís.

   ```bash
   python3 - <<'PY'
   import boto3
   ssm = boto3.client("ssm")

   # WRONG: single page, silently truncated at the service default
   raw = ssm.describe_parameters(MaxResults=10)
   print("single call  :", len(raw["Parameters"]), "next?", "NextToken" in raw)

   # RIGHT: paginator walks every page
   total = 0
   for page in ssm.get_paginator("describe_parameters").paginate(
           PaginationConfig={"PageSize": 10}):
       total += len(page["Parameters"])
   print("paginated    :", total)
   PY
   ```

   ```
   single call  : 10 next? True
   paginated    : 47
   ```

6. Comprobá que la CLI hace esto por vos salvo que lo sobrescribas:

   ```bash
   aws ssm describe-parameters --query 'length(Parameters)'
   aws ssm describe-parameters --max-items 10 --query 'length(Parameters)'
   ```

   ```
   47
   10
   ```

### Comprobación de comprensión — Bloque 2

- **Q2.1** — Nombrá los cinco componentes del scope `Credential=` del paso 2 e indicá a qué ata la firma cada uno.
- **Q2.2** — El access key ID empieza con `ASIA` y no con `AKIA`, y `x-amz-security-token` aparece en `SignedHeaders`. ¿Qué demuestra este par de hechos sobre las credenciales en uso, y por qué es el estado que querés en producción?
- **Q2.3** — En el paso 3 el scope cambió de `.../s3/aws4_request` a `.../ssm/aws4_request`. Si un atacante capturara la petición de S3 completa, ¿podría reproducir la firma contra SSM? ¿Contra S3 en `eu-west-1`? ¿Contra S3 en `us-east-1` mañana? Justificá cada respuesta.
- **Q2.4** — `retry_mode` acepta `legacy`, `standard` y `adaptive`. ¿Cuál agrega limitación de tasa del lado del cliente, y por qué es el default *equivocado* para una flota de miles de clientes golpeando una API con throttling?
- **Q2.5** — En el paso 5, la llamada sin paginar devolvió 10 elementos y estableció `NextToken`. Describí la clase de bug de producción que esto genera en un script de inventario de recursos, y por qué es particularmente peligroso en un script de *borrado* o de *cumplimiento*.
- **Q2.6** — Dado que la CLI pagina automáticamente, ¿qué hace `--max-items 10` de distinto respecto de `MaxResults=10` en la API cruda?

---

## Ejercicio 3 — Infrastructure as Code: aprovisionamiento declarativo con CloudFormation

**Objetivo:** reemplazar el aprovisionamiento imperativo por un estado deseado declarado, y entender qué garantiza el servicio en tu nombre (orden de dependencias, rollback, idempotencia, línea base de drift).

### Pasos

1. Escribí la plantilla. Guardala como `clf31-stack.yaml`:

   ```yaml
   AWSTemplateFormatVersion: '2010-09-09'
   Description: >-
     CLF-C02 Task 3.1 lab. Declarative provisioning of a versioned, encrypted
     artifact bucket plus its Parameter Store pointer. Demonstrates parameters,
     conditions, intrinsic functions, deletion policies, exports and tagging.

   Metadata:
     AWS::CloudFormation::Interface:
       ParameterGroups:
         - Label:
             default: Deployment context
           Parameters:
             - EnvironmentName
             - BucketNameSuffix

   Parameters:
     EnvironmentName:
       Type: String
       Default: dev
       AllowedValues: [dev, stg, prod]
       Description: Deployment environment. Drives version retention.
     BucketNameSuffix:
       Type: String
       MinLength: 3
       MaxLength: 24
       AllowedPattern: '^[a-z0-9][a-z0-9-]*[a-z0-9]$'
       ConstraintDescription: >-
         Must be 3-24 lowercase alphanumeric characters or hyphens, and must not
         start or end with a hyphen.
       Description: Lowercase suffix appended to the generated bucket name.

   Conditions:
     IsProduction: !Equals [!Ref EnvironmentName, 'prod']

   Resources:
     ArtifactBucket:
       Type: AWS::S3::Bucket
       DeletionPolicy: Delete
       UpdateReplacePolicy: Retain
       Properties:
         BucketName: !Sub '${AWS::AccountId}-${AWS::Region}-${BucketNameSuffix}'
         VersioningConfiguration:
           Status: Enabled
         BucketEncryption:
           ServerSideEncryptionConfiguration:
             - ServerSideEncryptionByDefault:
                 SSEAlgorithm: AES256
               BucketKeyEnabled: true
         PublicAccessBlockConfiguration:
           BlockPublicAcls: true
           BlockPublicPolicy: true
           IgnorePublicAcls: true
           RestrictPublicBuckets: true
         LifecycleConfiguration:
           Rules:
             - Id: expire-noncurrent-versions
               Status: Enabled
               NoncurrentVersionExpiration:
                 NoncurrentDays: !If [IsProduction, 365, 7]
         Tags:
           - Key: Environment
             Value: !Ref EnvironmentName
           - Key: ManagedBy
             Value: CloudFormation
           - Key: ExamObjective
             Value: CLF-C02-3.1

     ArtifactBucketPointer:
       Type: AWS::SSM::Parameter
       Properties:
         Name: !Sub '/${EnvironmentName}/${AWS::StackName}/artifact-bucket'
         Type: String
         Value: !Ref ArtifactBucket
         Description: Physical name of the artifact bucket owned by this stack.

   Outputs:
     ArtifactBucketName:
       Description: Physical name of the artifact bucket.
       Value: !Ref ArtifactBucket
       Export:
         Name: !Sub '${AWS::StackName}-ArtifactBucketName'
     ArtifactBucketArn:
       Description: ARN of the artifact bucket.
       Value: !GetAtt ArtifactBucket.Arn
     RetentionDays:
       Description: Effective non-current version retention, in days.
       Value: !If [IsProduction, '365', '7']
   ```

2. Validá la plantilla **antes** de gastar una llamada de API en una operación de stack. `validate-template` es una verificación de sintaxis y de funciones intrínsecas, no semántica:

   ```bash
   aws cloudformation validate-template --template-body file://clf31-stack.yaml
   ```

   ```json
   {
       "Parameters": [
           {
               "ParameterKey": "BucketNameSuffix",
               "NoEcho": false,
               "Description": "Lowercase suffix appended to the generated bucket name."
           },
           {
               "ParameterKey": "EnvironmentName",
               "DefaultValue": "dev",
               "NoEcho": false,
               "Description": "Deployment environment. Drives version retention."
           }
       ],
       "Description": "CLF-C02 Task 3.1 lab. Declarative provisioning of a versioned, encrypted artifact bucket plus its Parameter Store pointer. Demonstrates parameters, conditions, intrinsic functions, deletion policies, exports and tagging.",
       "Capabilities": []
   }
   ```

3. Demostrá que las restricciones de parámetros se aplican **del lado del servicio, antes del cliente**, antes de tocar ningún recurso. Violá `AllowedPattern` deliberadamente:

   ```bash
   aws cloudformation create-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue=Bad_Suffix_
   ```

   ```
   An error occurred (ValidationError) when calling the CreateStack operation:
   Parameter 'BucketNameSuffix' must match pattern ^[a-z0-9][a-z0-9-]*[a-z0-9]$
   ```

4. Creá el stack de verdad:

   ```bash
   aws cloudformation create-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue="${LAB_PREFIX}-art" \
                  ParameterKey=EnvironmentName,ParameterValue=dev \
     --tags Key=Owner,Value=platform-eng \
     --on-failure ROLLBACK
   ```

   ```json
   {
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-8a3d-11f1-9e4c-0e5a1b7c9d21"
   }
   ```

5. Bloqueá hasta que el stack se estabilice. El waiter consulta `DescribeStacks` y sale con código distinto de cero ante un estado de fallo terminal — esto es lo que debería llamar un pipeline, nunca `sleep`:

   ```bash
   time aws cloudformation wait stack-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts"
   echo "exit=$?"
   ```

   ```
   real    0m34.812s
   user    0m1.204s
   sys     0m0.163s
   exit=0
   ```

6. Leé el log de eventos ordenado. Esto es el grafo de dependencias, ya resuelto:

   ```bash
   aws cloudformation describe-stack-events \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'reverse(StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus])' \
     --output table
   ```

   ```
   ------------------------------------------------------------------------------
   |                            DescribeStackEvents                             |
   +----------------------------+------------------------+----------------------+
   |  2026-09-04T14:41:02.114Z  |  clf31-83291-artifacts |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:06.881Z  |  ArtifactBucket        |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:29.402Z  |  ArtifactBucket        |  CREATE_COMPLETE     |
   |  2026-09-04T14:41:31.775Z  |  ArtifactBucketPointer |  CREATE_IN_PROGRESS  |
   |  2026-09-04T14:41:33.918Z  |  ArtifactBucketPointer |  CREATE_COMPLETE     |
   |  2026-09-04T14:41:35.220Z  |  clf31-83291-artifacts |  CREATE_COMPLETE     |
   +----------------------------+------------------------+----------------------+
   ```

7. Leé los outputs, y después demostrá la idempotencia reenviando la plantilla idéntica:

   ```bash
   aws cloudformation describe-stacks \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].Outputs' --output table

   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true
   ```

   ```
   ---------------------------------------------------------------------------------------------------------------------
   |                                                  DescribeStacks                                                   |
   +---------------------+-----------------------------------------------+-------------------------------------------+
   |  ArtifactBucketArn  |  arn:aws:s3:::111122223333-us-east-1-clf31-83291-art  | ARN of the artifact bucket.        |
   |  ArtifactBucketName |  111122223333-us-east-1-clf31-83291-art       | Physical name of the artifact bucket.     |
   |  RetentionDays      |  7                                            | Effective non-current version retention.  |
   +---------------------+-----------------------------------------------+-------------------------------------------+
   ```
   ```
   An error occurred (ValidationError) when calling the UpdateStack operation: No updates are to be performed.
   ```

8. Confirmá que el parámetro puntero lo creó el stack, no vos:

   ```bash
   aws ssm get-parameter \
     --name "/dev/${LAB_PREFIX}-artifacts/artifact-bucket" \
     --query 'Parameter.Value' --output text
   ```

   ```
   111122223333-us-east-1-clf31-83291-art
   ```

### Comprobación de comprensión — Bloque 3

- **Q3.1** — En el paso 6 el bucket llegó a `CREATE_COMPLETE` *antes* de que el parámetro SSM siquiera empezara, y nunca declaraste un `DependsOn`. ¿Qué elemento de la plantilla produjo ese orden, y qué pasaría con el orden si reemplazaras `Value: !Ref ArtifactBucket` por una cadena fija?
- **Q3.2** — El paso 7 devolvió `ValidationError: No updates are to be performed`. ¿Es esto un fallo? Explicá qué demuestra sobre el modelo de ejecución de CloudFormation y cómo un pipeline de CI debe manejar esta condición de salida específica.
- **Q3.3** — El bucket lleva `DeletionPolicy: Delete` y `UpdateReplacePolicy: Retain`. Describí una secuencia concreta de eventos donde esta asimetría te salva de una pérdida de datos, y una segunda secuencia donde deja silenciosamente un recurso huérfano y facturable.
- **Q3.4** — El paso 3 fue rechazado en menos de un segundo sin ningún evento de stack. ¿En qué capa se aplicó el `AllowedPattern`, y por qué esa capa importa más que una verificación equivalente en tu linter de CI?
- **Q3.5** — `RetentionDays` es un Output calculado con `!If [IsProduction, '365', '7']`, duplicando la lógica que ya está dentro de la regla de lifecycle. Nombrá el modo de fallo que crea esta duplicación, y proponé un cambio en la plantilla que lo elimine.
- **Q3.6** — Explicá por qué hacer `Export` de `ArtifactBucketName` hace que este stack sea *más difícil* de borrar, y qué error verías si otro stack lo importara.
- **Q3.7** — `validate-template` tuvo éxito sobre una plantilla que igual podría fallar en el momento del despliegue. Dá dos clases distintas de error que `validate-template` estructuralmente no puede detectar.

---

## Ejercicio 4 — Operar IaC: change sets y drift

**Objetivo:** la mitad de "operar" del enunciado de tarea 3.1. Aprovisionar es un acto puntual; operar es todo lo que viene después. Los change sets responden *qué va a hacer esto*; la detección de drift responde *¿sigue siendo la realidad lo que declaré?*

### Pasos

1. Modificá la plantilla — agregá una segunda regla de lifecycle que aborte cargas multipart estancadas. Insertá en `LifecycleConfiguration.Rules`:

   ```yaml
             - Id: abort-incomplete-multipart
               Status: Enabled
               AbortIncompleteMultipartUpload:
                 DaysAfterInitiation: 7
   ```

2. Creá un change set en lugar de actualizar directamente. Todavía no se muta nada:

   ```bash
   aws cloudformation create-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --change-set-name "add-mpu-abort" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait change-set-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort"
   ```

   ```json
   {
       "Id": "arn:aws:cloudformation:us-east-1:111122223333:changeSet/add-mpu-abort/1d0f7a3c-...",
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-..."
   }
   ```

3. Leé el plan. `Replacement` es el campo que decide si esto es un cambio de configuración o una reconstrucción:

   ```bash
   aws cloudformation describe-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort" \
     --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement,join(`,`,Scope)]' \
     --output table
   ```

   ```
   -------------------------------------------------------------------------------
   |                             DescribeChangeSet                               |
   +----------+------------------+---------------------+-------------+-----------+
   |  Modify  |  ArtifactBucket  |  AWS::S3::Bucket    |  False      | Properties|
   +----------+------------------+---------------------+-------------+-----------+
   ```

4. Ahora creá un **segundo change set, peligroso**, para ver cómo se ve un reemplazo. Cambiá solo el valor del parámetro:

   ```bash
   aws cloudformation create-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --change-set-name "rename-bucket" \
     --use-previous-template \
     --parameters ParameterKey=BucketNameSuffix,ParameterValue="${LAB_PREFIX}-new" \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait change-set-create-complete \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket"

   aws cloudformation describe-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket" \
     --query 'Changes[].ResourceChange.[Action,LogicalResourceId,Replacement,join(`,`,Details[].Target.RequiresRecreation)]' \
     --output table
   ```

   ```
   ------------------------------------------------------------------------
   |                          DescribeChangeSet                           |
   +----------+------------------------+------------+--------------------+
   |  Modify  |  ArtifactBucket        |  True      |  Always            |
   |  Modify  |  ArtifactBucketPointer |  False     |  Never             |
   +----------+------------------------+------------+--------------------+
   ```

5. **Descartá** el change set peligroso y ejecutá solo el seguro:

   ```bash
   aws cloudformation delete-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "rename-bucket"

   aws cloudformation execute-change-set \
     --stack-name "${LAB_PREFIX}-artifacts" --change-set-name "add-mpu-abort"

   aws cloudformation wait stack-update-complete --stack-name "${LAB_PREFIX}-artifacts"
   echo "exit=$?"
   ```

   ```
   exit=0
   ```

6. Ahora introducí **drift** — mutá el recurso fuera de CloudFormation, exactamente como haría un ingeniero de guardia a las 3 de la mañana:

   ```bash
   BUCKET=$(aws cloudformation describe-stacks \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' --output text)

   aws s3api put-bucket-tagging --bucket "${BUCKET}" --tagging \
     'TagSet=[{Key=Environment,Value=dev},{Key=ManagedBy,Value=human-at-3am},{Key=ExamObjective,Value=CLF-C02-3.1}]'
   ```

7. Detectá el drift. Notá que la detección es **asincrónica** — obtenés un token, no un resultado:

   ```bash
   DID=$(aws cloudformation detect-stack-drift \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query StackDriftDetectionId --output text)

   until [ "$(aws cloudformation describe-stack-drift-detection-status \
           --stack-drift-detection-id "$DID" \
           --query DetectionStatus --output text)" != "DETECTION_IN_PROGRESS" ]; do
     sleep 3
   done

   aws cloudformation describe-stack-drift-detection-status \
     --stack-drift-detection-id "$DID"
   ```

   ```json
   {
       "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/clf31-83291-artifacts/6f1c2e80-...",
       "StackDriftDetectionId": "b4e9f012-8a41-11f1-a7d2-0e5a1b7c9d21",
       "StackDriftStatus": "DRIFTED",
       "DetectionStatus": "DETECTION_COMPLETE",
       "DriftedStackResourceCount": 1,
       "Timestamp": "2026-09-04T15:03:44.117Z"
   }
   ```

8. Obtené el diff a nivel de propiedad:

   ```bash
   aws cloudformation describe-stack-resource-drifts \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --stack-resource-drift-status-filters MODIFIED \
     --query 'StackResourceDrifts[].PropertyDifferences[].[PropertyPath,ExpectedValue,ActualValue,DifferenceType]' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------------------
   |                        DescribeStackResourceDrifts                            |
   +-------------------+------------------+-------------------+------------------+
   |  /Tags/1/Value    |  CloudFormation  |  human-at-3am     |  NOT_EQUAL       |
   +-------------------+------------------+-------------------+------------------+
   ```

9. Remediá reafirmando el estado declarado:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" --use-previous-template \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true
   ```

   ```
   An error occurred (ValidationError) when calling the UpdateStack operation: No updates are to be performed.
   ```

### Comprobación de comprensión — Bloque 4

- **Q4.1** — En el paso 4, cambiar `BucketNameSuffix` produjo `Replacement: True` con `RequiresRecreation: Always` en el bucket, pero `Replacement: False` en el parámetro SSM que lo *referencia*. Explicá ambos resultados.
- **Q4.2** — ¿Qué le habría hecho ejecutar el change set `rename-bucket` a los datos del bucket original, dado el par `DeletionPolicy`/`UpdateReplacePolicy` del Ejercicio 3? Trazalo con precisión.
- **Q4.3** — El paso 9 se negó a remediar el drift con `No updates are to be performed`. Explicá por qué CloudFormation considera que el stack ya está al día pese a `StackDriftStatus: DRIFTED`, y dá dos estrategias de remediación que funcionen.
- **Q4.4** — La detección de drift reportó `DriftedStackResourceCount: 1`. Cambiaste una etiqueta en un bucket. ¿Qué *no* mira CloudFormation al calcular el drift, y nombrá una categoría de cambio fuera de banda que igual reportará como `IN_SYNC`.
- **Q4.5** — ¿Por qué `detect-stack-drift` es asincrónico y basado en token en vez de devolver la respuesta en línea? ¿Qué implica eso para ejecutarlo sobre un stack de 400 recursos dentro de un pipeline?
- **Q4.6** — Tu organización exige "nada de `update-stack` directo en producción; solo change sets". Nombrá los dos riesgos concretos que elimina esta política, usando evidencia de los pasos 3 y 4.

---

## Ejercicio 5 — Modos de fallo y diagnóstico

**Objetivo:** un ingeniero que solo sabe leer stacks en verde no puede operar. Vas a romper un stack deliberadamente y diagnosticarlo desde la API.

### Pasos

1. Agregá un recurso deliberadamente inválido a `clf31-stack.yaml`. Los nombres de bucket de S3 no pueden contener guiones bajos:

   ```yaml
     BrokenBucket:
       Type: AWS::S3::Bucket
       Properties:
         BucketName: !Sub '${AWS::StackName}_invalid_name'
   ```

2. Intentá la actualización y dejá que falle:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation wait stack-update-complete --stack-name "${LAB_PREFIX}-artifacts"
   echo "waiter exit=$?"
   ```

   ```
   Waiter StackUpdateComplete failed: Waiter encountered a terminal failure state:
   For expression "Stacks[].StackStatus" we matched expected path: "UPDATE_ROLLBACK_COMPLETE" at least once
   waiter exit=255
   ```

3. Encontrá el *primer* fallo — no el último. El último evento es casi siempre un síntoma en cascada:

   ```bash
   aws cloudformation describe-stack-events \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatusReason])' \
     --output text | head -1
   ```

   ```
   2026-09-04T15:19:08.442Z	BrokenBucket	Resource handler returned message: "Bucket name should not contain '_'" (RequestToken: 3c9f..., HandlerErrorCode: InvalidRequest)
   ```

4. Confirmá que el stack volvió a un estado *funcional*, y que tus recursos buenos sobrevivieron:

   ```bash
   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].[StackStatus,StackStatusReason]' --output text

   aws cloudformation list-stack-resources --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'StackResourceSummaries[].[LogicalResourceId,ResourceStatus]' --output table
   ```

   ```
   UPDATE_ROLLBACK_COMPLETE	The following resource(s) failed to create: [BrokenBucket]. Rollback requested by user.
   ```
   ```
   --------------------------------------------------------
   |                 ListStackResources                   |
   +--------------------------+---------------------------+
   |  ArtifactBucket          |  UPDATE_COMPLETE          |
   |  ArtifactBucketPointer   |  UPDATE_COMPLETE          |
   +--------------------------+---------------------------+
   ```

5. Repetí el fallo con el rollback deshabilitado, para que el recurso fallido quede disponible para inspección:

   ```bash
   aws cloudformation update-stack \
     --stack-name "${LAB_PREFIX}-artifacts" \
     --template-body file://clf31-stack.yaml \
     --disable-rollback \
     --parameters ParameterKey=BucketNameSuffix,UsePreviousValue=true \
                  ParameterKey=EnvironmentName,UsePreviousValue=true

   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].StackStatus' --output text
   ```

   ```
   UPDATE_FAILED
   ```

6. Recuperate de `UPDATE_FAILED` y devolvé el stack a un estado estable:

   ```bash
   aws cloudformation rollback-stack --stack-name "${LAB_PREFIX}-artifacts"
   aws cloudformation wait stack-rollback-complete --stack-name "${LAB_PREFIX}-artifacts"
   aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
     --query 'Stacks[0].StackStatus' --output text
   ```

   ```
   UPDATE_ROLLBACK_COMPLETE
   ```

7. Eliminá el bloque `BrokenBucket` de la plantilla antes de continuar.

### Comprobación de comprensión — Bloque 5

- **Q5.1** — El waiter del paso 2 salió con `255`, no con `0` ni con `1`. ¿Por qué un pipeline que ejecuta `aws cloudformation update-stack` *sin* un waiter parece tener éxito incluso cuando el despliegue falla?
- **Q5.2** — El paso 3 ordenó los eventos y tomó el **primer** fallo. Explicá, en términos de cómo CloudFormation propaga los fallos, por qué el último evento `*_FAILED` cronológicamente suele ser inútil para el diagnóstico.
- **Q5.3** — Contrastá `ROLLBACK_COMPLETE` (de un `create-stack` fallido) con `UPDATE_ROLLBACK_COMPLETE` (de un `update-stack` fallido). Uno de estos dos estados no puede actualizarse — ¿cuál, y cuál es la única operación legal sobre él?
- **Q5.4** — Dá un escenario concreto donde `--disable-rollback` es la elección correcta en producción, y uno donde es un error grave.
- **Q5.5** — En el paso 4, `ArtifactBucket` muestra `UPDATE_COMPLETE` después de una actualización *fallida*. ¿Qué garantía provee CloudFormation sobre el estado de los recursos no tocados durante un rollback, y cuál es la excepción bien conocida (pista: pensá en un recurso cuyo propio rollback falla)?
- **Q5.6** — Tu stack quedó atascado en `UPDATE_ROLLBACK_FAILED`. Nombrá la operación de API específica diseñada para este estado y el flag que acepta para saltear recursos que no se pueden revertir.

---

## Ejercicio 6 — Modelos de despliegue: nube, híbrido, on-premises

**Objetivo:** mapear los tres modelos de despliegue nombrados en la guía del examen a los servicios concretos de AWS que implementan cada uno, y después verificar la huella de edge de una Región con llamadas de solo lectura.

### Pasos

1. Enumerá todos los tipos de zona en una Región. `availability-zone` es la clásica dentro de la Región; cualquier otra cosa es una construcción de edge/híbrida:

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones \
     --region us-east-1 \
     --query "AvailabilityZones[].[ZoneName,ZoneType,ParentZoneName,OptInStatus]" \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------
   |                          DescribeAvailabilityZones                             |
   +-------------------+---------------------+---------------+--------------------+
   |  us-east-1a       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1b       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1c       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1d       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1e       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1f       |  availability-zone   |  None         |  opt-in-not-required|
   |  us-east-1-atl-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-bos-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-chi-2a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-dfw-2a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-mia-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-nyc-1a |  local-zone          |  us-east-1    |  not-opted-in      |
   |  us-east-1-wl1-atl-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   |  us-east-1-wl1-bos-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   |  us-east-1-wl1-nyc-wlz-1 |  wavelength-zone |  us-east-1 |  not-opted-in      |
   +-------------------+---------------------+---------------+--------------------+
   ```

2. Contá cada tipo, para que la proporción quede explícita:

   ```bash
   aws ec2 describe-availability-zones --all-availability-zones --region us-east-1 \
     --query "AvailabilityZones[].ZoneType" --output text | tr '\t' '\n' | sort | uniq -c
   ```

   ```
        6 availability-zone
        6 local-zone
        3 wavelength-zone
   ```

3. Comprobá si hay algún Outpost registrado en esta cuenta (un Outpost es hardware on-premises corriendo el plano de control de AWS):

   ```bash
   aws outposts list-outposts --region us-east-1
   ```

   ```json
   {
       "Outposts": []
   }
   ```

4. Inspeccioná los servicios de movimiento de datos on-premises que hacen real un modelo híbrido. `describe-locations` es gratuito y muestra dónde podrías hacer un cross-connect físico:

   ```bash
   aws datasync list-locations --region us-east-1 --query 'Locations[].LocationUri'
   aws storagegateway list-gateways --region us-east-1 --query 'Gateways[].[GatewayName,GatewayType,GatewayOperationalState]' --output table
   ```

   ```json
   []
   ```
   ```
   ---------------------------------------------
   |               ListGateways                |
   +-------------------------------------------+
   ```

5. Construí vos mismo el mapa modelo↔servicio antes de leer las respuestas. Completá esta tabla:

   | Modelo de despliegue | Dónde corre la carga de trabajo | Dónde corre el plano de control de AWS | Servicios representativos |
   |---|---|---|---|
   | Nube (cloud-native) | ? | ? | ? |
   | Híbrido | ? | ? | ? |
   | On-premises (nube privada) | ? | ? | ? |

### Comprobación de comprensión — Bloque 6

- **Q6.1** — Una Local Zone y una Wavelength Zone aparecen ambas en `describe-availability-zones` con `ParentZoneName: us-east-1`. ¿Qué significa esa relación de padre a nivel operativo, y cuál es el diferenciador primario entre los dos tipos de zona en términos de *de quién viene el tráfico*?
- **Q6.2** — Toda entrada que no es `availability-zone` muestra `OptInStatus: not-opted-in`. ¿Qué cambia realmente al hacer opt-in, y por qué AWS lo hizo opt-in en lugar de activado por defecto?
- **Q6.3** — Un regulador exige que un conjunto de datos específico nunca salga físicamente de tu datacenter de Frankfurt, pero el equipo quiere usar la misma API de EC2, las mismas políticas de IAM y las mismas plantillas de CloudFormation que el resto del parque. ¿Qué modelo de despliegue y qué servicio específico satisface esto? ¿Qué es lo único que aún tenés que aprovisionar vos?
- **Q6.4** — Clasificá cada uno de los siguientes como nube, híbrido u on-premises, y justificá: (a) un appliance de Storage Gateway File Gateway en una sucursal cacheando hacia S3; (b) un cluster de EKS con todos los nodos en `us-east-1`; (c) EKS Anywhere sobre tu propio vSphere; (d) una aplicación en EC2 en `us-east-1` leyendo una base de datos vía Direct Connect desde tu propio datacenter.
- **Q6.5** — ¿Por qué un Outpost sigue requiriendo un enlace de red confiable de vuelta a su Región padre, y qué se degrada específicamente si ese enlace se corta durante seis horas?

---

## Ejercicio 7 — Conectividad: internet público, VPN, Direct Connect

**Objetivo:** la tercera área de conocimiento del enunciado de tarea 3.1. Construir la matriz de decisión con datos que las APIs devuelven de verdad, no con páginas de marketing.

### Pasos

1. Listá las ubicaciones de Direct Connect — son las instalaciones físicas de colocación donde es posible un cross-connect:

   ```bash
   aws directconnect describe-locations --region us-east-1 \
     --query 'locations[0:6].[locationCode,locationName,availablePortSpeeds[*]|join(`,`,@)]' \
     --output table
   ```

   ```
   -----------------------------------------------------------------------------------------------
   |                                     DescribeLocations                                       |
   +--------------+--------------------------------------------------+-------------------------+
   |  EqDC2       |  Equinix DC2/DC11, Ashburn, VA                    |  1Gbps,10Gbps,100Gbps   |
   |  CSDC1       |  CoreSite DC1, Washington, DC                     |  1Gbps,10Gbps           |
   |  EqNY5       |  Equinix NY5, Secaucus, NJ                        |  1Gbps,10Gbps,100Gbps   |
   |  DA1         |  Digital Realty ATL, Atlanta, GA                  |  1Gbps,10Gbps           |
   |  TerreNAP    |  TierPoint Miami, Miami, FL                       |  1Gbps,10Gbps           |
   |  EqCH2       |  Equinix CH2, Chicago, IL                         |  1Gbps,10Gbps,100Gbps   |
   +--------------+--------------------------------------------------+-------------------------+
   ```

2. Confirmá que no tenés infraestructura preexistente de Direct Connect ni de VPN (todo de solo lectura, todo gratis):

   ```bash
   aws directconnect describe-connections --query 'connections[].[connectionId,connectionState,bandwidth]' --output table
   aws directconnect describe-virtual-interfaces --query 'virtualInterfaces[].[virtualInterfaceId,virtualInterfaceType,virtualInterfaceState]' --output table
   aws ec2 describe-vpn-connections --query 'VpnConnections[].[VpnConnectionId,State,Type]' --output table
   aws ec2 describe-vpn-gateways --query 'VpnGateways[].[VpnGatewayId,State,AmazonSideAsn]' --output table
   ```

   ```
   ------------------
   |DescribeConnections|
   +----------------+
   ```

3. Creá un **Customer Gateway** — la representación del lado de AWS de *tu* router on-premises. Este recurso es gratuito; la conexión VPN que lo consumiría no lo es, así que paramos acá:

   ```bash
   aws ec2 create-customer-gateway \
     --type ipsec.1 \
     --bgp-asn 65001 \
     --ip-address 203.0.113.12 \
     --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=${LAB_PREFIX}-cgw}]" \
     --query 'CustomerGateway.[CustomerGatewayId,Type,BgpAsn,IpAddress,State]' --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                      CreateCustomerGateway                        |
   +---------------------+----------+---------+----------------+-------+
   |  cgw-0a1b2c3d4e5f6a7b8 | ipsec.1 |  65001 |  203.0.113.12  | available |
   +---------------------+----------+---------+----------------+-------+
   ```

4. Observá lo que el CGW **no** contiene — ni claves de cifrado, ni endpoints de túnel, ni rutas. Eso se materializa solo cuando se crea una conexión VPN:

   ```bash
   aws ec2 describe-customer-gateways \
     --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" \
     --query 'CustomerGateways[0]'
   ```

   ```json
   {
       "BgpAsn": "65001",
       "CustomerGatewayId": "cgw-0a1b2c3d4e5f6a7b8",
       "IpAddress": "203.0.113.12",
       "State": "available",
       "Type": "ipsec.1",
       "Tags": [
           { "Key": "Name", "Value": "clf31-83291-cgw" }
       ]
   }
   ```

5. Medí el camino por *internet público* para comparar. Un endpoint regional de S3 es un proxy razonable para la latencia originada en internet y su varianza:

   ```bash
   for i in 1 2 3 4 5; do
     curl -o /dev/null -s -w "attempt %{http_code}  dns=%{time_namelookup}s  tls=%{time_appconnect}s  total=%{time_total}s\n" \
       https://s3.us-east-1.amazonaws.com/
   done
   ```

   ```
   attempt 307  dns=0.021s  tls=0.118s  total=0.142s
   attempt 307  dns=0.001s  tls=0.094s  total=0.109s
   attempt 307  dns=0.001s  tls=0.221s  total=0.243s
   attempt 307  dns=0.001s  tls=0.097s  total=0.112s
   attempt 307  dns=0.001s  tls=0.089s  total=0.104s
   ```

6. Completá esta matriz con lo que observaste y con la documentación citada:

   | Atributo | Internet público | Site-to-Site VPN | Direct Connect |
   |---|---|---|---|
   | Transporte subyacente | ? | ? | ? |
   | Cifrado en tránsito | ? | ? | ? |
   | Consistencia de la latencia | ? | ? | ? |
   | Tiempo de aprovisionamiento | ? | ? | ? |
   | Techo típico de ancho de banda por enlace | ? | ? | ? |
   | Modelo de costo | ? | ? | ? |
   | Dominio de fallo / patrón de HA | ? | ? | ? |

7. Limpiá el Customer Gateway:

   ```bash
   CGW=$(aws ec2 describe-customer-gateways \
     --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" "Name=state,Values=available" \
     --query 'CustomerGateways[0].CustomerGatewayId' --output text)
   aws ec2 delete-customer-gateway --customer-gateway-id "$CGW"
   ```

### Comprobación de comprensión — Bloque 7

- **Q7.1** — En el paso 5, `time_total` varió entre 0.104 s y 0.243 s — una dispersión de 2.3× sobre cinco peticiones idénticas en un enlace ocioso. ¿Qué propiedad específica del internet público produce esa dispersión, y cuál de las tres opciones de conectividad se compra específicamente para eliminarla?
- **Q7.2** — El Customer Gateway del paso 4 no tiene ningún material de cifrado. ¿De dónde vienen las claves precompartidas de IPsec y las dos direcciones IP externas de los túneles, y cuántos túneles provee por defecto una única conexión AWS Site-to-Site VPN?
- **Q7.3** — Aprovisionaste un único Direct Connect de 10 Gbps en `EqDC2`. Tu revisión de arquitectura lo rechaza. ¿Cuál es el dominio de fallo que preocupa a ese revisor, y cuál es el cambio mínimo que lo aborda manteniendo el mismo ancho de banda total?
- **Q7.4** — A Direct Connect se lo describe frecuentemente como "privado". ¿Está una conexión de Direct Connect *cifrada* por defecto? ¿Cuál es el remedio estándar, y qué te cuesta arquitectónicamente?
- **Q7.5** — Un equipo necesita mover 40 TB de un datacenter a S3 en una semana, y tiene un enlace de internet de 200 Mbps sin Direct Connect. Calculá el tiempo bruto de transferencia al 100% de utilización, y después nombrá el servicio de AWS diseñado exactamente para esta situación y el modelo al que pertenece.
- **Q7.6** — Ordená internet público, VPN y Direct Connect por *tiempo hasta el primer paquete* (qué tan rápido podés pasar de cero a un enlace funcionando). Explicá por qué este ranking suele ser el factor decisivo en una migración, y cómo se combinan comúnmente las dos opciones más lentas durante el intervalo.

---

## Ejercicio 8 — Elegir la abstracción de operación

**Objetivo:** "métodos de operación" no es solo IaC. Es la elección de cuánto del stack aceptás correr vos mismo. El enunciado de tarea 3.1 espera que ubiques los servicios de despliegue gestionados sobre ese espectro.

### Pasos

1. Enumerá las plataformas de Elastic Beanstalk disponibles — cada una es un paquete completamente gestionado de aprovisionamiento + operación:

   ```bash
   aws elasticbeanstalk list-platform-versions \
     --filters 'Type=PlatformStatus,Operator==,Values=Ready' \
     --query 'PlatformSummaryList[0:8].[PlatformBranchName,PlatformVersion,OperatingSystemName]' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------
   |                        ListPlatformVersions                              |
   +----------------------------------+-----------+---------------------------+
   |  Python 3.12 running on 64bit AL2023 |  4.3.1 |  Amazon Linux             |
   |  Docker running on 64bit AL2023      |  4.3.1 |  Amazon Linux             |
   |  Corretto 21 running on 64bit AL2023 |  4.3.1 |  Amazon Linux             |
   |  Node.js 20 running on 64bit AL2023  |  6.4.2 |  Amazon Linux             |
   |  .NET 8 running on 64bit AL2023      |  3.1.4 |  Amazon Linux             |
   |  PHP 8.3 running on 64bit AL2023     |  4.3.1 |  Amazon Linux             |
   |  Go 1 running on 64bit AL2023        |  4.3.1 |  Amazon Linux             |
   |  Ruby 3.3 running on 64bit AL2023    |  4.3.1 |  Amazon Linux             |
   +----------------------------------+-----------+---------------------------+
   ```

2. Notá que Beanstalk es en sí mismo un cliente de CloudFormation — inspeccioná qué crearía. Listá los tipos de recurso que gestiona para una capa web con balanceo de carga:

   ```bash
   aws elasticbeanstalk describe-configuration-options \
     --solution-stack-name "64bit Amazon Linux 2023 v4.3.1 running Python 3.12" \
     --query 'Options[?Namespace==`aws:autoscaling:asg`].[Name,DefaultValue]' \
     --output table
   ```

   ```
   -------------------------------------------------
   |         DescribeConfigurationOptions          |
   +-------------------------+---------------------+
   |  Availability Zones     |  Any                |
   |  Cooldown               |  360                |
   |  Custom Availability Zones |  None            |
   |  MaxSize                |  4                  |
   |  MinSize                |  1                  |
   +-------------------------+---------------------+
   ```

3. Confirmá que Systems Manager es el plano de *operación* una vez que los recursos existen — listá lo que ofrece sin lanzar nada:

   ```bash
   aws ssm describe-instance-information \
     --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' --output table

   aws ssm list-documents \
     --filters "Key=Owner,Values=Amazon" "Key=DocumentType,Values=Command" \
     --query 'DocumentIdentifiers[?starts_with(Name, `AWS-Run`)].Name' --output text | tr '\t' '\n' | head -6
   ```

   ```
   -----------------------------
   |DescribeInstanceInformation|
   +---------------------------+
   ```
   ```
   AWS-RunPatchBaseline
   AWS-RunPatchBaselineAssociation
   AWS-RunPatchBaselineWithHooks
   AWS-RunPowerShellScript
   AWS-RunRemoteScript
   AWS-RunShellScript
   ```

4. Ubicá cada uno de estos sobre el espectro de abstracción, desde "operás todo" hasta "no operás nada":

   `EC2 with a shell script` · `EC2 + Systems Manager` · `CloudFormation` · `Elastic Beanstalk` · `ECS on EC2` · `ECS on Fargate` · `Lambda`

### Comprobación de comprensión — Bloque 8

- **Q8.1** — Elastic Beanstalk aprovisiona tu entorno *generando un stack de CloudFormation*. Dado eso, ¿qué agrega Beanstalk que CloudFormation puro no da, y qué te quita?
- **Q8.2** — Ordená los siete elementos del paso 4 por responsabilidad operativa decreciente de tu lado. Para cada par adyacente, nombrá la responsabilidad específica que se transfiere a AWS en ese paso.
- **Q8.3** — `AWS-RunShellScript` te permite ejecutar comandos arbitrarios en una instancia sin puerto SSH, sin bastión y sin par de claves. Nombrá los tres componentes que lo hacen posible y explicá por qué esto es una mejora del *método de operación* y no una simple comodidad.
- **Q8.4** — Un equipo propone ejecutar `AWS-RunShellScript` sobre toda la flota para aplicar un cambio de configuración. Vos objetás. Enunciá la objeción en términos de los conceptos del Ejercicio 4, y nombrá el mecanismo correcto.
- **Q8.5** — El `MaxSize` por defecto de Beanstalk es 4 y el `MinSize` es 1. ¿Qué significa, en términos de responsabilidad compartida, que AWS haya elegido esos valores por defecto por vos — y cuál es el riesgo de aceptar los defaults de un servicio gestionado en producción?

---

## Limpieza

Ejecutá esto en orden. Verificá cada paso; no des nada por sentado.

```bash
# 1. Empty the versioned bucket (a versioned bucket cannot be deleted while objects
#    or delete markers remain, and CloudFormation will not empty it for you).
BUCKET=$(aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' --output text)
aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$BUCKET" --query '{Objects: [].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null || echo "bucket already empty"

# 2. Delete the stack (removes bucket + SSM pointer).
aws cloudformation delete-stack --stack-name "${LAB_PREFIX}-artifacts"
aws cloudformation wait stack-delete-complete --stack-name "${LAB_PREFIX}-artifacts"
echo "stack delete exit=$?"

# 3. Delete the three hand-made SSM parameters from Exercise 1.
aws ssm delete-parameters --names \
  "/${LAB_PREFIX}/origin/cli" "/${LAB_PREFIX}/origin/sdk" "/${LAB_PREFIX}/origin/console"

# 4. Confirm nothing is left.
aws cloudformation describe-stacks --stack-name "${LAB_PREFIX}-artifacts" 2>&1 | tail -1
aws ssm get-parameters-by-path --path "/${LAB_PREFIX}" --recursive --query 'length(Parameters)'
aws ec2 describe-customer-gateways \
  --filters "Name=tag:Name,Values=${LAB_PREFIX}-cgw" "Name=state,Values=available" \
  --query 'length(CustomerGateways)'
```

```
stack delete exit=0
An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id clf31-83291-artifacts does not exist
0
0
```

> Nota: un Customer Gateway borrado sigue siendo visible con `State: deleted` durante un tiempo. Filtrar por `state=available` es lo que hace significativa la verificación del paso 4.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Las cuatro interfaces son una sola interfaz

**A1.1** — No hay distinción arquitectónica. La Console, la CLI y todos los SDK son clientes HTTPS de la misma API pública del servicio; ninguno tiene un canal privado. La Console es una aplicación web que llama a `ssm:PutParameter` en tu nombre; la CLI es `botocore` envolviendo la misma llamada; boto3 es ese mismo `botocore`. Como la API del servicio es el único punto de entrada, `eventSource` y `eventName` son necesariamente idénticos. La consecuencia práctica es que **todo** modelo de permisos, cuota, throttle y hook de auditoría aplica de manera uniforme — un `Deny` de IAM sobre `ssm:PutParameter` bloquea la Console exactamente igual que bloquea a un script, porque no hay otra cosa que bloquear.

**A1.2** — Tu navegador no habla con `ssm.amazonaws.com`. Habla con la capa web de la propia Console, que después asume/usa las credenciales de tu sesión y emite la llamada de API firmada con SigV4 desde infraestructura gestionada por AWS. CloudTrail registra el user agent del proceso que realmente hizo la llamada firmada, que es ese backend de la Console — de ahí `AWS Internal` (registros más viejos pueden mostrar `console.amazonaws.com` o `signin.amazonaws.com` para eventos relacionados). El user agent de tu navegador nunca llega al servicio de SSM, así que no puede aparecer.

**A1.3** — Refutalo. El paso 7 muestra `eventSource`, `eventName`, `readOnly` y `managementEvent` idénticos para los tres. Una estrategia de auditoría basada en CloudTrail que cubra la API cubre la Console por construcción, porque la Console *es* un cliente de la API. Lo único que difiere son los metadatos (`userAgent`, `sessionContext`), que es exactamente lo que usarías para *distinguir* el origen — no una razón para construir un segundo pipeline de auditoría. El modelo mental del colega llevaría al error inverso peligroso: creer que bloquear el acceso a la Console bloquea la acción.

**A1.4** — `userAgent`. El predicado es aproximadamente: alertar cuando `eventName` sea una acción mutante de producción **Y** `userAgent` **no** coincida con la firma de tu automatización — es decir, no sea ni `cloudformation.amazonaws.com` (el cambio vino por IaC) ni la cadena de user-agent configurada de tu pipeline. Un cambio hecho a mano en la Console aparece como `AWS Internal`; la laptop de un ingeniero aparece como `aws-cli/...`. Endurecelo combinándolo con `sessionContext.sessionIssuer.userName` para que un rol de pipeline comprometido no pueda simplemente falsificar la cadena. Notá que `userAgent` lo suministra el cliente y por lo tanto es orientativo — tratalo como una señal de drift, no como un control de seguridad.

**A1.5** — De mayor a menor: (1) flags de línea de comandos como `--region` / `--profile`; (2) variables de entorno (`AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, …); (3) el archivo de credenciales de la CLI `~/.aws/credentials`; (4) el archivo de configuración de la CLI `~/.aws/config`; (5) credenciales de contenedor (rol de tarea de ECS/EKS); (6) metadatos de instancia (IMDS / perfil de instancia EC2). Un flag `--region` está en lo más alto y sobrescribe todo lo demás, que es por qué `aws configure list` mostró `Type: env` — no se pasó ningún flag, así que ganó la variable de entorno.

### Bloque 2 — Acceso programático

**A2.1** — `ASIA4EXAMPLEKEYID/20260904/us-east-1/s3/aws4_request`:
1. **Access key ID** — identifica al principal cuyo secreto derivó la clave de firma.
2. **Fecha (`YYYYMMDD`, UTC)** — ata la firma a un único día UTC; combinado con el header obligatorio `x-amz-date` y la tolerancia de desvío de reloj del servicio de ±5 minutos, esto acota el replay.
3. **Región** — la ata a `us-east-1`.
4. **Servicio** — la ata a `s3`.
5. **`aws4_request`** — una cadena terminadora fija que identifica la versión del esquema de firma SigV4.
La clave de firma se deriva mediante HMAC encadenado sobre exactamente estos componentes, así que una firma es inutilizable fuera de su scope.

**A2.2** — `ASIA` es el prefijo de una access key temporal de STS, y `x-amz-security-token` transporta el token de sesión que la acompaña; una clave permanente de usuario IAM sería `AKIA` sin token de sesión. Juntos demuestran que quien llama está sobre **credenciales de corta duración, con rotación automática** — de IAM Identity Center, de un rol asumido, o de un perfil de instancia/tarea. Este es el estado objetivo en producción porque el radio de impacto de una filtración queda acotado por la duración de la sesión (típicamente 1–12 horas) en lugar de ser indefinido, y no hay ningún secreto estático que guardar, rotar o commitear por accidente.

**A2.3** — Los tres replays fallan.
- *Contra SSM*: no. El servicio está dentro del credential scope; la clave de firma derivada para `s3` no puede validar una petición a `ssm`.
- *Contra S3 en `eu-west-1`*: no. La Región está dentro del scope.
- *Contra S3 en `us-east-1` mañana*: no, por dos motivos independientes — la fecha está dentro del scope, y `x-amz-date` debe estar dentro de la ventana de desvío de reloj del servicio (unos 5 minutos), así que la petición se rechaza por expirada mucho antes de que cambie el día.
Notá que dentro del scope y dentro de la ventana de desvío, una petición capturada *sí* es reproducible textualmente — que es precisamente por qué todo el intercambio va sobre TLS y por qué las credenciales son de corta duración.

**A2.4** — `adaptive`. Agrega un limitador de tasa del lado del cliente que aprende de las respuestas de throttling y ralentiza el cliente de forma preventiva. Es el default equivocado a escala de flota porque cada cliente aprende *independientemente* de sus propias observaciones, sin coordinación: una API compartida con throttling recibe N limitadores descoordinados que pueden converger mal, y el backoff de un cliente crea margen que otro cliente consume inmediatamente. `adaptive` está diseñado para un número pequeño de clientes de alto volumen que dominan una cuota, no para una flota amplia. `standard` — backoff exponencial acotado con jitter y un tope fijo de intentos — es el default correcto para una flota.

**A2.5** — Produce **truncamiento silencioso**: el script devuelve un resultado sintácticamente válido y con apariencia plausible que simplemente está incompleto, sin error, sin advertencia y sin código de salida distinto de cero. En un script de inventario o de cumplimiento esto significa "revisé todo y no encontré violaciones" cuando revisaste la primera página. En un script de borrado es peor en la dirección opuesta — borrás solo la primera página y reportás éxito, dejando huérfanos facturables; o, si el script se reejecuta hasta converger, obtenés un bucle infinito. La patología es que la corrección se degrada exactamente cuando el entorno crece más allá del tamaño de página, así que funciona perfecto en dev y falla en producción.

**A2.6** — `MaxResults` es un **tamaño de página del lado del servidor**: le dice al servicio cuántos elementos poner en una respuesta, y el servicio devuelve un `NextToken` para el resto. `--max-items` es un **tope total del lado del cliente**: la CLI sigue paginando internamente pero deja de entregarte elementos una vez alcanzado el total, y emite un `NextToken` en su salida para que puedas retomar. Se pueden combinar — `--page-size` mapea al `MaxResults` del lado del servidor, `--max-items` acota el agregado. Usar `--max-items` no reduce el número de llamadas de API por elemento recuperado; `--page-size` sí.

### Bloque 3 — Infrastructure as Code

**A3.1** — `!Ref ArtifactBucket` dentro de `ArtifactBucketPointer` crea una **dependencia implícita**. CloudFormation construye un grafo acíclico dirigido a partir de cada referencia de función intrínseca (`Ref`, `GetAtt`, `Sub` con un token de recurso, `DependsOn`) y ordena la creación topológicamente; no puede resolver `!Ref ArtifactBucket` a un nombre físico de bucket hasta que el bucket exista, así que el parámetro necesariamente espera. Reemplazarlo por una cadena fija cortaría la arista, los dos recursos pasarían a ser nodos independientes, y CloudFormation los crearía **en paralelo** — que es precisamente cómo terminás con una entrada de Parameter Store apuntando a un nombre de bucket que todavía no existe, o que un rollback fallido nunca creó.

**A3.2** — No es un fallo — es la prueba de la **idempotencia**. CloudFormation compara la plantilla enviada más los parámetros resueltos contra la plantilla actual del stack; una entrada idéntica significa que el estado deseado ya está satisfecho, así que no hay nada que hacer. La trampa es que la CLI señaliza esto con un código de salida distinto de cero y un `ValidationError`, indistinguible a nivel de shell de un error genuino. Un pipeline de CI debe tratarlo como caso especial: capturar stderr, y si coincide con `No updates are to be performed`, tratar el paso como exitoso y saltear el waiter (no hay ningún evento de stack que esperar). Usar `aws cloudformation deploy` en lugar de `create-stack`/`update-stack` maneja esto de forma nativa — sale con 0 en un no-op — que es la mejor respuesta.

**A3.3** — *Te salva*: alguien envía un cambio a `BucketNameSuffix`. `UpdateReplacePolicy: Retain` significa que CloudFormation crea el nuevo bucket, actualiza el stack para que apunte a él, y **deja el bucket viejo y todos sus objetos en su lugar**. Tus datos sobreviven a un renombrado accidental.
*Te cuesta*: ese mismo evento deja un bucket que ningún stack posee, que ninguna plantilla describe, que la detección de drift nunca va a mirar, y que seguís pagando — invisible hasta que alguien audite S3 a mano. La asimetría es un intercambio deliberado de *costo y prolijidad* por *seguridad de los datos*; es el default correcto para recursos con estado, pero te obliga a correr un barrido de detección de huérfanos (por ejemplo con Config, o un inventario basado en etiquetas) como control compensatorio.

**A3.4** — En la **capa del servicio de CloudFormation**, antes de que se abriera la transacción del stack — de ahí el sub-segundo, sin `StackId`, sin eventos. Esto importa más que un linter de CI porque no se puede eludir: aplica igual a un despliegue desde la Console, a una llamada manual de CLI, a un rollout de StackSet y a una herramienta de terceros, mientras que una verificación de CI protege exactamente un camino de código y cualquier ingeniero con el permiso de IAM adecuado puede darle la vuelta. Las restricciones pertenecen al artefacto, no al pipeline que casualmente lo transporta.

**A3.5** — El modo de fallo es la **divergencia entre el comportamiento declarado y el comportamiento reportado**. Alguien edita la regla de lifecycle a `!If [IsProduction, 730, 7]` y se olvida del Output; el stack ahora retiene versiones durante 730 días mientras cada dashboard, runbook y stack aguas abajo que lea `RetentionDays` reporta 365. Nada falla, nada driftea — la *descripción* del sistema silenciosamente se vuelve una mentira.
Solución: introducir un bloque `Mappings` indexado por entorno, referenciarlo una vez desde cada lugar, y dejar que tanto el recurso como el Output se resuelvan desde la misma fuente:
```yaml
Mappings:
  RetentionByEnv:
    dev:  { NoncurrentDays: 7 }
    stg:  { NoncurrentDays: 30 }
    prod: { NoncurrentDays: 365 }
```
y después `NoncurrentDays: !FindInMap [RetentionByEnv, !Ref EnvironmentName, NoncurrentDays]` en ambos lugares. El literal ahora se enuncia una sola vez.

**A3.6** — Un `Export` publica un valor en el espacio de nombres de exports de la Región, a nivel de toda la cuenta. CloudFormation se niega a borrar un stack, o a modificar un output exportado, mientras **cualquier** otro stack mantenga un `Fn::ImportValue` vivo sobre él — esto es un bloqueo de dependencia duro, no una advertencia. Intentar el borrado produce:
```
An error occurred (ValidationError) when calling the DeleteStack operation:
Export clf31-83291-artifacts-ArtifactBucketName cannot be deleted as it is in use by consumer-stack
```
Tenés que borrar o actualizar primero el consumidor. Por eso las referencias entre stacks a escala se construyen a menudo sobre búsquedas en SSM Parameter Store — dan la misma indirección sin el bloqueo de borrado, a costa de perder la seguridad que ese bloqueo provee.

**A3.7** — Dos clases distintas:
1. **Errores semánticos / de propiedades de recurso.** `validate-template` verifica que el YAML/JSON esté bien formado, la estructura de la plantilla y la sintaxis de las funciones intrínsecas. No evalúa los esquemas de propiedades de los recursos — el `BrokenBucket` del Ejercicio 5, con un guion bajo en el nombre del bucket, valida limpiamente y falla recién cuando el resource handler de S3 lo rechaza en el momento de la creación.
2. **Errores de runtime y de entorno.** Permisos de IAM insuficientes para el rol que despliega, un nombre de bucket de S3 ya tomado globalmente, una cuota de servicio agotada, un tipo de instancia no disponible en la AZ elegida, un `!GetAtt` sobre un atributo que el recurso no expone en esa Región. Nada de esto es conocible solo a partir de la plantilla.
(Usá `cfn-lint` para cerrar la mayor parte de la brecha 1, y un change set más una cuenta que no sea de producción para cerrar la brecha 2.)

### Bloque 4 — Change sets y drift

**A4.1** — `BucketName` es una **propiedad inmutable, de solo creación**: la API de S3 no ofrece renombrado. El esquema de recurso de CloudFormation la marca como `createOnlyProperty`, así que cualquier cambio sobre ella se mapea a `RequiresRecreation: Always` — borrar y recrear, expuesto como `Replacement: True`.
El parámetro SSM muestra `Replacement: False` porque todas sus propias propiedades son mutables. *Sí* se ve afectado — su `Value` va a cambiar al nuevo nombre de bucket — pero cambiar el valor de un parámetro SSM es un `PutParameter` in situ. CloudFormation propaga correctamente el cambio de *valor* a través del grafo de dependencias sin propagar el *reemplazo*.

**A4.2** — Con precisión: CloudFormation crearía el bucket **nuevo** `...-clf31-83291-new`, actualizaría `ArtifactBucketPointer` para referenciarlo, y después evaluaría la disposición del bucket viejo. Como el reemplazo se rige por `UpdateReplacePolicy` — que es `Retain` — el bucket viejo `...-clf31-83291-art` **no se borra**. Sus objetos y versiones quedan intactos y se siguen facturando. `DeletionPolicy: Delete` es irrelevante acá; solo aplica cuando se borra el *stack*, no cuando se reemplaza un recurso. Resultado neto: sin pérdida de datos, un bucket huérfano facturable fuera de la gestión de IaC, y cualquier consumidor que todavía tenga el nombre viejo leyendo silenciosamente un bucket obsoleto. Si `UpdateReplacePolicy` hubiera sido `Delete` (o hubiera estado ausente — el default es seguir a `DeletionPolicy`, efectivamente `Delete`), el mismo change set habría destruido los datos.

**A4.3** — El motor de actualización de CloudFormation compara la **plantilla + parámetros enviados** contra la **plantilla + parámetros almacenados**. No compara contra el recurso vivo. Ambas plantillas son idénticas, así que el diff está vacío y no hay nada que enviar — el estado de drift lo calcula un servicio separado y no alimenta el camino de actualización. Dos remediaciones que funcionan:
1. **Forzar una actualización no-op-más-uno**: cambiá algo trivial y reversible en la plantilla (por ejemplo, tocá el `Description`, o agregá y después quitá una clave de metadatos). CloudFormation entonces reenvía el estado deseado completo para el recurso, sobrescribiendo la etiqueta hecha fuera de banda.
2. **Import / re-baseline**: para divergencias mayores o más riesgosas, sacá el recurso del stack con `DeletionPolicy: Retain` y reimportalo mediante `create-change-set --change-set-type IMPORT`, reestableciendo la línea base explícitamente.
La tercera opción, más brutal — borrar y recrear el stack — es correcta solo para recursos sin estado. A más largo plazo, prevení la clase entera con una stack policy más una SCP que deniegue la mutación directa de recursos gestionados por CloudFormation.

**A4.4** — La detección de drift compara únicamente las propiedades **explícitamente declaradas en tu plantilla** (más un conjunto definido de atributos de recurso) para **tipos de recurso que soportan detección de drift**. No evalúa: propiedades que dejaste al default del servicio; tipos de recurso sin soporte de drift; los *contenidos* de los recursos (objetos en el bucket, filas en una tabla); y nada que esté fuera del stack. Un falso negativo `IN_SYNC` concreto: borrar la configuración de lifecycle del bucket se detecta (la declaraste), pero adjuntar una **bucket policy** que otorgue lectura pública se reporta como `IN_SYNC`, porque tu plantilla nunca declaró `BucketPolicy` — CloudFormation no tiene ninguna expectativa contra la cual comparar. Esta es la limitación más importante que hay que interiorizar: la detección de drift te dice "lo que declaré sigue coincidiendo", nunca "no cambió nada".

**A4.5** — La detección hace una llamada de API `Describe`/`Get` en vivo por recurso contra cada servicio propietario, sujeta a la latencia y al throttling de ese servicio. En un stack grande eso son minutos de fan-out, muy por encima de cualquier timeout de petición sincrónica, así que la API devuelve un `StackDriftDetectionId` inmediatamente y vos consultás `describe-stack-drift-detection-status`. Para un stack de 400 recursos esto implica: (a) presupuestar minutos, no segundos, y nunca `sleep`-y-a-ver-qué-pasa — consultá `DetectionStatus`; (b) esperar `DETECTION_FAILED` en recursos individuales cuyo servicio te aplica throttling, y manejar resultados parciales; (c) no lo pongas en el camino crítico de cada despliegue — corrélo de forma programada (o vía reglas de AWS Config, que hacen esto de manera continua) y condicioná sobre el reporte, no sobre una verificación sincrónica.

**A4.6** — Dos riesgos, ambos visibles arriba:
1. **Reemplazo no revisado de recursos con estado.** El paso 4 mostró que un cambio de una sola palabra en un parámetro produjo `Replacement: True` sobre el bucket. Un `update-stack` directo habría ejecutado eso inmediatamente, con el paso destructivo visible solo en retrospectiva en el log de eventos. El change set convirtió una acción irreversible en un artefacto revisable.
2. **Radio de impacto no acotado por un diff no intencionado.** Un change set enumera *todos* los recursos afectados — el paso 4 reveló que el parámetro SSM también estaba dentro del alcance, algo que el autor de un cambio de una línea en un parámetro no necesariamente habría predicho. Las actualizaciones directas no te dan esa enumeración por adelantado.
La política convierte el despliegue de un acto imperativo en un plan revisado — la misma razón por la que existe `terraform plan`.

### Bloque 5 — Modos de fallo y diagnóstico

**A5.1** — Porque `update-stack` es **asincrónico**. Valida la petición, abre la transacción del stack, devuelve un `StackId` y sale con **0** — el despliegue fue *aceptado*, no *completado*. Todo el trabajo real, y por lo tanto todo el fallo posible, ocurre después. Un pipeline que se detiene en `update-stack` reporta verde para un despliegue que hizo rollback minutos más tarde. El waiter es lo que convierte la aceptación asincrónica en un pasa/falla sincrónico: consulta `DescribeStacks` y sale con código distinto de cero (255 para un estado de fallo terminal, 255 en timeout) cuando el stack aterriza en cualquier lugar que no sea el estado de éxito esperado. **`update-stack` sin waiter no es un paso de despliegue; es un paso de envío.**

**A5.2** — La propagación de fallos de CloudFormation es de fan-out. Un recurso falla; CloudFormation cancela todos los hermanos en vuelo, los marca con razones genéricas como `Resource creation cancelled`, y después hace rollback de cada recurso completado, generando un evento `*_FAILED` o `DELETE_*` por cada uno. Todo eso es cronológicamente *posterior* al fallo real. Así que el último evento `*_FAILED` es casi siempre un artefacto de cancelación o un paso de rollback con una razón del tipo `Resource creation cancelled` — cierta, y completamente ininformativa. El **primer** fallo por marca de tiempo lleva el `ResourceStatusReason` real del resource handler, que es la única línea que te dice qué está mal. De ahí `reverse(StackEvents[...])` y `head -1`: `describe-stack-events` devuelve del más nuevo al más viejo, así que invertir da del más viejo al más nuevo, y la primera coincidencia es la causa raíz.

**A5.3** — `ROLLBACK_COMPLETE` se alcanza cuando un stack falla durante su **creación inicial**. Nunca se creó nada con éxito, así que no hay ningún estado bueno previo al que actualizar — el stack es una cáscara que solo contiene su propia identidad. **No puede actualizarse**; la única operación legal es `delete-stack`, tras lo cual arreglás la plantilla y lo creás de nuevo. (Esto es lo que automatiza `--on-failure DELETE`.)
`UPDATE_ROLLBACK_COMPLETE` sigue a una **actualización** fallida de un stack ya sano. El stack fue devuelto con éxito a su última plantilla conocida como buena, así que es un stack plenamente operativo y puede actualizarse normalmente.
La distinción relevante para el examen: `ROLLBACK_COMPLETE` es un callejón sin salida; `UPDATE_ROLLBACK_COMPLETE` es un stack sano.

**A5.4** — *Correcto*: un recurso falla por una razón que el `ResourceStatusReason` no explica — una instancia EC2 cuyo bootstrap con `cfn-init` falla, una tarea de ECS que entra en crash-loop, una Lambda cuyo custom resource nunca señaliza. El rollback borraría justo aquello que necesitás inspeccionar (la instancia, sus logs, su estado), destruyendo la evidencia. `--disable-rollback` preserva los restos para un post-mortem, en una cuenta que no sea de producción.
*Error*: en un pipeline automatizado de producción. Deja el stack en `UPDATE_FAILED` — un estado no terminal y no operativo donde la infraestructura desplegada es una mezcla a medio aplicar de lo viejo y lo nuevo. El stack no puede actualizarse hasta que alguien llame manualmente a `rollback-stack` o a `continue-update-rollback`. Convertiste un fallo automático y acotado en una caída que requiere intervención humana, en el peor momento posible.

**A5.5** — La garantía de CloudFormation es **transaccional a nivel de stack**: una actualización o se aplica completa, o el stack se devuelve a su última plantilla conocida como buena, dejando intactos los recursos que no necesitó tocar. `ArtifactBucket` muestra `UPDATE_COMPLETE` porque su actualización (exitosa) se aplicó, y el rollback no encontró nada que revertir para él.
La excepción bien conocida es **`UPDATE_ROLLBACK_FAILED`**: si el rollback *en sí* no puede completarse — la versión anterior de un recurso ya no se puede recrear, un cambio fuera de banda dejó el estado viejo inalcanzable, se revocó un permiso de IAM en pleno vuelo — el stack queda varado en un estado genuinamente inconsistente que CloudFormation no puede reparar por su cuenta. La garantía transaccional se sostiene solo hasta donde el camino de rollback sea ejecutable.

**A5.6** — `aws cloudformation continue-update-rollback --stack-name <name>`. Acepta `--resources-to-skip` (una lista de IDs lógicos de recurso, o `NestedStackName.LogicalId` para stacks anidados) para saltear recursos cuyo rollback sigue fallando. Dos advertencias: saltear un recurso hace que la plantilla almacenada del stack **diverja a sabiendas** de la realidad para ese recurso — después tenés que importarlo o repararlo; y la operación requiere que el stack esté en `UPDATE_ROLLBACK_FAILED`, así que diagnosticá la causa subyacente (normalmente un permiso revocado o un borrado fuera de banda) antes de recurrir a `--resources-to-skip`.

### Bloque 6 — Modelos de despliegue

**A6.1** — `ParentZoneName` significa que la zona es una **extensión del plano de control y de la red de la Región padre**, no una Región independiente: la direccionás con la misma cuenta, el mismo IAM, la misma VPC (mediante una subnet ubicada en esa zona) y los mismos endpoints de API. No hay una Región separada a la que hacer opt-in, ni credenciales separadas, ni semántica de transferencia de datos entre Regiones para el enlace con el padre.
El diferenciador es **de quién llega el tráfico**:
- Una **Local Zone** está en un área metropolitana y se alcanza por **internet público o Direct Connect**. Sirve a cargas de trabajo sensibles a la latencia para usuarios y sistemas on-premises de esa metrópolis — gaming en tiempo real, renderizado de medios, inferencia de ML cerca de una oficina.
- Una **Wavelength Zone** está embebida **dentro de la red 5G de un operador de telecomunicaciones**. El tráfico de un dispositivo móvil la alcanza sin salir nunca de la red del operador ni atravesar internet. Sirve a cargas de trabajo de mobile-edge — vehículos conectados, AR/VR en handsets, IoT industrial sobre 5G.
Mismo patrón arquitectónico (una extensión de la Región), distinta última milla.

**A6.2** — Hacer opt-in hace que la zona sea **utilizable por tu cuenta**: pasa a ser seleccionable al crear una subnet, y su menú (deliberadamente más acotado) de tipos de instancia y servicios queda disponible. AWS lo hizo opt-in por varias razones: estas zonas ofrecen un *subconjunto* de los servicios y familias de instancias de la Región, así que incluirlas silenciosamente permitiría que `Availability Zones: Any` colocara cargas de trabajo en un lugar con capacidades distintas; el precio difiere del de la Región padre; y los supuestos de radio de impacto y cumplimiento construidos sobre "mi Región tiene 6 AZ" cambiarían sin que lo notes. El opt-in convierte la huella ampliada en una decisión arquitectónica explícita en vez de una sorpresa. Notá que el mismo mecanismo de opt-in rige para *Regiones* más nuevas (por ejemplo, `af-south-1`), por la misma razón.

**A6.3** — **Modelo de despliegue on-premises, vía AWS Outposts** — racks (o servidores de 1U/2U) físicos diseñados y gestionados por AWS, instalados en *tu* datacenter, corriendo las mismas APIs de EC2, EBS, S3 on Outposts, ECS/EKS y VPC, gestionados a través de la misma Console, CLI, IAM y CloudFormation. Los datos de un Outpost se quedan en el Outpost. AWS entrega, instala, monitorea, parchea y da servicio al hardware.
Lo que todavía tenés que aprovisionar vos: la **instalación y su service link**. Concretamente — espacio de piso, energía (alimentaciones redundantes que cumplan los requisitos publicados), refrigeración, seguridad física, y la red: enlaces ascendentes a tu red local más un **service link** confiable y redundante de vuelta a la Región padre. AWS opera el rack; vos operás la sala y las cañerías.

**A6.4** —
(a) **Híbrido.** El appliance corre sobre tu infraestructura y presenta una interfaz NFS/SMB local a clientes on-premises, mientras los datos autoritativos viven en S3. Ambas mitades son estructurales y están acopladas de forma continua.
(b) **Nube.** Plano de control y plano de datos están enteramente en la Región. Nada corre sobre tu hardware.
(c) **On-premises.** EKS Anywhere corre el cluster de Kubernetes completo sobre tu propia infraestructura vSphere, sobre tu hardware, bajo tu operación. Puede estar aislado (air-gapped). A diferencia de un Outpost, AWS no posee ni opera el hardware y el plano de control de AWS no se extiende hasta ahí — es software *distribuido* por AWS, no una huella *gestionada* por AWS.
(d) **Híbrido.** La capa de cómputo es cloud-native, la capa de datos es on-premises, y la arquitectura depende de ambas más del enlace privado entre ellas. Esta es la forma híbrida más común en el mundo real durante una migración.

**A6.5** — Un Outpost corre el *plano de datos* localmente, pero su **plano de control vive en la Región padre**. Cada llamada de API mutante — `RunInstances`, `CreateVolume`, `AuthorizeSecurityGroupIngress` — se hace contra un endpoint regional, se autentica con IAM regional, y se despacha al rack por el service link. Ese enlace también es cómo AWS monitorea la salud del hardware, entrega parches y firmware, y cómo las métricas y logs llegan a CloudWatch.
Durante una caída de seis horas: **las instancias ya en ejecución siguen corriendo** y el tráfico local de la VPC sigue fluyendo — las cargas de trabajo existentes no se detienen. Lo que se degrada es todo lo que requiere el plano de control: no podés lanzar, terminar, redimensionar ni reconfigurar instancias; no podés crear volúmenes ni modificar security groups; Auto Scaling no puede reemplazar una instancia caída; las métricas de CloudWatch y los eventos de CloudTrail se acumulan en buffer o se pierden; AWS pierde la telemetría del hardware. En efecto el Outpost se convierte en una instantánea congelada e ingobernable de sí mismo — sobrevive, pero no puede sanar ni cambiar. Por eso rutas de service link redundantes y diversas son un requisito de diseño, no una optimización.

### Bloque 7 — Conectividad

**A7.1** — **Retardo de encolado variable a través de redes intermedias no controladas.** Tus paquetes atraviesan una serie de sistemas autónomos de terceros cuyo enrutamiento, congestión y ocupación de buffers ni observás ni influenciás; un transitorio en cualquier salto agrega retardo de encolado, y BGP puede reenrutarte por un camino distinto entre peticiones. El resultado es **jitter** alto — un p99 inestable incluso cuando la media está bien — y ninguna garantía contractual de latencia.
**AWS Direct Connect** se compra específicamente para eliminar esto: un circuito físico dedicado desde tu router hasta un router de AWS en una ubicación de Direct Connect, sorteando internet público por completo, con latencia consistente, ancho de banda predecible y un camino definido. Comprás Direct Connect por la *varianza*, no por la *media* — esa es la distinción que evalúa el examen. (Una Site-to-Site VPN mejora la confidencialidad y te da direccionamiento privado, pero viaja por el mismo internet público y por lo tanto hereda el mismo jitter.)

**A7.2** — Ambos los genera AWS cuando creás la **conexión VPN** (`ec2 create-vpn-connection`), que vincula un Customer Gateway a un Virtual Private Gateway o a un Transit Gateway. El Customer Gateway por sí solo es metadata inerte — la IP pública de tu router, su ASN de BGP y el protocolo del túnel — que es exactamente por qué crearlo es gratuito e instantáneo. Solo la conexión VPN asigna infraestructura real.
Una única conexión AWS Site-to-Site VPN provee **dos túneles por defecto**, terminando en dos endpoints independientes del lado de AWS en dos Availability Zones distintas, cada uno con su propia IP externa y su propia clave precompartida (o certificado). Ambos están activos; AWS puede dar de baja uno por mantenimiento en cualquier momento. La configuración completa — incluidas las PSK y una plantilla de configuración específica del fabricante — la recuperás con `describe-vpn-connections`, cuyo campo `CustomerGatewayConfiguration` la devuelve como XML. **Tenés que configurar ambos túneles en tu router**; una configuración de un solo túnel es un punto único de fallo autoinfligido y anula el SLA de la conexión.

**A7.3** — Al revisor le preocupa que una única conexión concentre **cuatro** puntos únicos de fallo independientes: el dispositivo de AWS que termina tu circuito, el cross-connect y el patch panel dentro de `EqDC2`, la instalación de colocación en sí (energía, refrigeración, supresión de incendios), y tu propio router y su enlace ascendente. Cualquiera de esos te deja completamente fuera de línea. Un circuito único además no tiene ventana de mantenimiento — el mantenimiento del dispositivo de AWS es una caída.
Cambio mínimo para el mismo ancho de banda total: **dos conexiones de 10 Gbps terminando en dos ubicaciones de Direct Connect *distintas*** (por ejemplo, `EqDC2` y `CSDC1`), cada una en un dispositivo de AWS separado, idealmente en routers de cliente separados y con fibra de rutas diversas. Este es el patrón de *máxima resiliencia* de AWS; dos conexiones en la *misma* ubicación sobre dispositivos distintos es el patrón menor de "alta resiliencia", que elimina el SPOF del dispositivo pero no el de la instalación. La práctica estándar agrega una Site-to-Site VPN como camino terciario de respaldo barato por internet, aceptando rendimiento degradado durante un fallo total de Direct Connect. Y después probá el failover — un camino de respaldo no probado es una hipótesis, no un control.

**A7.4** — **No.** Direct Connect es *privado* en el sentido de ser un circuito dedicado de capa 2 que no atraviesa internet público — pero el tráfico sobre él **no está cifrado** por AWS. Cualquiera con acceso físico o lógico al camino (el proveedor de colocación, un operador comprometido, alguien interno en cualquier punto del cross-connect) ve texto plano. "Privado" y "cifrado" son propiedades ortogonales, y confundirlas es un hallazgo clásico de auditoría.
Los remedios estándar son **MACsec** (IEEE 802.1AE, cifrado de capa 2 disponible en conexiones dedicadas soportadas en ubicaciones y velocidades de puerto específicas) o ejecutar una **VPN IPsec sobre la virtual interface pública de Direct Connect**, o usar AWS Direct Connect con una **Site-to-Site VPN sobre una Transit VIF**.
El costo arquitectónico: IPsec sobre DX agrega sobrecarga de cifrado/descifrado y una reducción del MTU del túnel, limita el throughput a lo que la terminación de VPN pueda sostener (un único túnel de Site-to-Site VPN tope bastante por debajo de 10 Gbps — necesitás ECMP sobre múltiples túneles o un Transit Gateway para escalar más allá), y agrega un segundo dominio de fallo y un segundo conjunto de claves que operar. Estás cambiando throughput bruto y simplicidad por confidencialidad, lo cual suele ser el trueque correcto pero nunca es gratis.

**A7.5** — 40 TB a 200 Mbps, con una utilización teóricamente perfecta del 100%:
`40 TB = 40 × 8 = 320 Tbit = 320.000.000 Mbit`; `320.000.000 / 200 = 1.600.000 s ≈ 444 horas ≈ 18,5 días`.
Eso ya excede el plazo de una semana por 2,6×, y asume que el enlace está saturado al 100% durante todo el período — es decir, nada de tráfico de negocio, y sin ineficiencia de TCP, retransmisiones ni sobrecarga de protocolo. Realistamente, con una utilización sostenible del 50%, esto es **más de un mes**.
El servicio es **AWS Snowball Edge** (la familia AWS Snow). AWS te envía un appliance físico ruggedizado y cifrado; copiás los datos localmente a velocidad de LAN y lo devolvés para su ingesta en S3. El ciclo completo suele ser de menos de una semana incluyendo el transporte. Pertenece al modelo de despliegue **híbrido** — hardware físico operando en tu instalación como puente deliberado hacia la nube — y es la respuesta canónica a "la red es el cuello de botella". La regla general que busca el examen: pasados unos 10 TB sobre un enlace restringido, calculá el tiempo de transferencia antes de asumir que la red es la respuesta. (Para transferencia continua e incremental sobre un enlace adecuado, la respuesta sería en cambio AWS DataSync.)

**A7.6** — Del más rápido al más lento por **tiempo hasta el primer paquete**:
1. **Internet público** — minutos. Ya existe; solo necesitás un internet gateway y una ruta. Cero adquisición.
2. **Site-to-Site VPN** — minutos a horas. Enteramente definido por software del lado de AWS: creás el Customer Gateway y la conexión VPN vía API, descargás la configuración y la aplicás a tu router. La única barrera es la ventana de cambios de tu propio equipo de redes.
3. **Direct Connect** — **semanas a meses**. Requiere aprovisionamiento físico: una LOA-CFA de AWS, un cross-connect pedido e instalado por el proveedor de colocación, posiblemente un circuito nuevo de un operador para llegar a la instalación, contratos, y trabajo físico de personas en un edificio.
Este ranking decide con frecuencia las migraciones porque los plazos de negocio no esperan a un cross-connect. Por eso el patrón estándar es **arrancar con una Site-to-Site VPN desde el día uno** — está disponible de inmediato, te da direccionamiento privado y cifrado, y permite que empiece la migración — mientras el pedido de Direct Connect avanza en paralelo. Cuando el circuito llega, lo conectás y trasladás el tráfico, y después **conservás la VPN como camino de respaldo cifrado** en lugar de darla de baja. Obtenés progreso inmediato, y la arquitectura final es más resiliente que cualquiera de las dos opciones por separado.

### Bloque 8 — Abstracciones de operación

**A8.1** — **Agrega**: una plataforma de aplicación completa y opinada a partir de un único artefacto. Le entregás un bundle de código; él selecciona y aprovisiona la flota de EC2, el Auto Scaling group, el balanceador de carga, los security groups y las alarmas de CloudWatch, instala y configura el runtime del lenguaje, y — crucialmente — te da operaciones de **ciclo de vida de la aplicación** de las que CloudFormation no tiene concepto: revisiones versionadas de la aplicación, políticas de despliegue rolling e inmutable, blue/green mediante intercambio de URL de entorno, rollback a una versión anterior con un comando, y reporte de salud que entiende tu aplicación y no solo la instancia. También parchea la plataforma gestionada por vos.
**Quita**: control y transparencia. El stack de CloudFormation generado es de Beanstalk, no tuyo — editarlo directamente te pone en conflicto con el servicio. Estás limitado a las platform branches soportadas y a los puntos de extensión que Beanstalk expone (`.ebextensions`, hooks de `.platform`, namespaces de opciones de configuración); cualquier cosa fuera de eso es incómoda o imposible. Y heredás la cadencia de actualización y el calendario de deprecación de una plataforma gestionada.
La forma general: Beanstalk cambia *expresividad* por *tiempo hasta tener la aplicación corriendo*, y CloudFormation es la escotilla de escape que hay debajo cuando ese trueque deja de convenir.

**A8.2** — Responsabilidad operativa decreciente, con la responsabilidad que se transfiere en cada paso:

1. **EC2 with a shell script** — sos dueño de todo: aprovisionamiento, configuración, parcheo, escalado, recuperación, y la corrección del script.
   ↓ *se transfiere: acceso remoto, orquestación de parches, inventario y cumplimiento de configuración* (y dejás de mantener bastiones y claves SSH)
2. **EC2 + Systems Manager** — AWS provee las herramientas de operación; vos seguís siendo dueño de lo que hacen y del propio sistema operativo.
   ↓ *se transfiere: la reproducibilidad del aprovisionamiento — orden de dependencias, rollback, línea base de drift, idempotencia*
3. **CloudFormation** — la infraestructura está declarada y es reproducible; vos seguís siendo dueño del SO, el runtime y el ciclo de vida de la aplicación.
   ↓ *se transfiere: la capa de plataforma — instalación del runtime, cableado del balanceador de carga y del Auto Scaling, estrategia de despliegue de la aplicación y rollback*
4. **Elastic Beanstalk** — AWS corre la plataforma de aplicación; vos seguís siendo dueño de las instancias EC2 subyacentes (están en tu cuenta, y todavía podés hacerles SSH).
   ↓ *se transfiere: la orquestación de contenedores — scheduling, placement, reemplazo basado en salud, service discovery*
5. **ECS on EC2** — AWS agenda los contenedores; vos seguís siendo dueño, parcheando y escalando las instancias de contenedor EC2.
   ↓ *se transfiere: la capa de host por completo — no hay instancias que parchear, dimensionar, escalar ni asegurar*
6. **ECS on Fargate** — sos dueño de la imagen del contenedor y de su dimensionamiento de recursos; no hay host en tu cuenta.
   ↓ *se transfiere: el runtime del contenedor, la gestión de capacidad y el costo en reposo — escalado a cero, facturación por invocación*
7. **Lambda** — solo sos dueño del código de tu función y de su configuración.

Dos salvedades que vale la pena enunciar: esto es un espectro de *responsabilidad*, no un ranking de *calidad* — Lambda no es "mejor" que EC2, es un trueque distinto de control por carga operativa. Y el trueque es real en ambas direcciones: cada paso hacia abajo cede una superficie de control que quizás necesites más adelante, y volver hacia arriba es caro.

**A8.3** — Tres componentes:
1. El **SSM Agent** instalado en la instancia (preinstalado en Amazon Linux 2023, en Ubuntu reciente y en las AMIs de Windows).
2. Un **instance profile de IAM** que otorgue a la instancia permiso para hablar con Systems Manager — típicamente la política gestionada `AmazonSSMManagedInstanceCore`.
3. **Salida de red hacia los endpoints del servicio de SSM** — vía un camino de internet/NAT, o, mejor, endpoints de interfaz de VPC (`ssm`, `ssmmessages`, `ec2messages`) para que el tráfico nunca salga de la red de AWS.
El agente hace **polling saliente** hacia el servicio y ejecuta lo que se le entrega; el servicio nunca inicia una conexión entrante.
Esto es una mejora de *método de operación*, no una comodidad, porque elimina de una vez toda una clase de superficie de ataque y de carga operativa: **ningún puerto 22/3389 entrante en ningún security group**, ningún host bastión que correr y parchear, ningún par de claves SSH que distribuir, rotar, revocar o perder, y ningún sistema de control de acceso separado. La autorización pasa a ser **IAM** — las mismas políticas, las mismas condiciones, los mismos principales que todo lo demás en la cuenta — y cada comando se autentica, se autoriza contra IAM, se registra en CloudTrail, y opcionalmente se graba tecla por tecla en S3 o CloudWatch Logs. Convierte el acceso remoto de un dominio de seguridad paralelo en una llamada normal de API de AWS. Eso es un cambio estructural en el modelo de seguridad, no una UX más linda.

**A8.4** — La objeción es el **drift**. Un barrido con `Run Command` muta instancias fuera de banda, exactamente como el cambio manual de etiqueta del paso 6 del Ejercicio 4. El cambio es invisible para el estado deseado declarado; sobrevive hasta el próximo reemplazo de instancia y después desaparece silenciosamente, así que una instancia escalada o autorreparada arranca *sin* él. Ahora tenés una flota que es no uniforme de una manera que ninguna plantilla describe y que ningún diff va a mostrar — y, según A4.4, la detección de drift no necesariamente lo va a atrapar, ya que solo compara propiedades que declaraste. Esto es el fallo del "human-at-3am" institucionalizado como procedimiento.
El mecanismo correcto, en orden ascendente de rigor:
- **State Manager** (Systems Manager) — asociar un documento con un conjunto de destinos y dejar que SSM lo *reaplique continuamente* según una programación. El cambio pasa a estar declarado y a ser autorreparable en vez de ser de una sola vez.
- **Una nueva AMI, construida con EC2 Image Builder**, desplegada actualizando el launch template a través de CloudFormation — infraestructura inmutable, donde el cambio de configuración viene horneado y el reemplazo es el mecanismo de despliegue.
El principio general: `Run Command` es para **investigación y remediación puntual**, no para **configuración**. Si querés que siga siendo cierto mañana, tiene que estar declarado en algún lado.

**A8.5** — En términos de responsabilidad compartida, aceptar los defaults de un servicio gestionado significa que AWS tomó una **decisión de capacidad y disponibilidad en tu nombre** — y esa decisión cae de lleno de *tu* lado de la línea. AWS opera el Auto Scaling group correctamente; si `MinSize: 1` / `MaxSize: 4` se ajusta o no a tu tráfico es enteramente responsabilidad tuya. El servicio va a hacer fielmente exactamente lo que dicen esos números, incluido fallar.
Concretamente, `MinSize: 1` significa **cero redundancia**: una sola instancia, en una sola AZ, cuya pérdida es una caída total hasta que se lance un reemplazo y pase los health checks — minutos de indisponibilidad para un servicio que quizás creías altamente disponible porque "está en AWS y tiene un ELB". Y `MaxSize: 4` es un techo duro: tu tráfico puede crecer más allá de eso y el entorno simplemente se va a saturar y degradar, sin ningún error que diga "chocaste con tu propio límite".
El riesgo general: los defaults de un servicio gestionado se eligen para ser **baratos, seguros y presentables en una demo para el usuario nuevo mediano** — nunca para ajustarse a tu objetivo de disponibilidad, a tu perfil de tráfico o a tu presupuesto. La abstracción mueve el *trabajo*, no la *responsabilidad*. Cada default que elige un servicio gestionado sigue siendo una decisión que te pertenece; producción significa revisar cada uno deliberadamente, como mínimo `MinSize ≥ 2` a través de al menos dos Availability Zones, con `MaxSize` derivado del pico medido más margen.

</details>

---

## Fuentes

Todos los ejercicios son originales. Verificá el comportamiento y la superficie de API actual contra la documentación oficial:

- **Guía del examen (alcance autoritativo para la tarea 3.1):** https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS CLI v2 User Guide — https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html
- Precedencia de configuración y credenciales — https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html
- Firma de peticiones a la API de AWS (SigV4) — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
- Referencia de SDKs y herramientas de AWS — comportamiento de reintentos — https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html
- Paginadores de Boto3 — https://boto3.amazonaws.com/v1/documentation/api/latest/guide/paginators.html
- AWS CloudFormation User Guide — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Actualizar stacks usando change sets — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html
- Detectar cambios de configuración no gestionados (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- Atributo `DeletionPolicy` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html
- Atributo `UpdateReplacePolicy` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatereplacepolicy.html
- Resolución de problemas de CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/troubleshooting.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Direct Connect User Guide — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- AWS Site-to-Site VPN User Guide — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- Opciones de conectividad de Amazon VPC (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-vpc-connectivity-options/welcome.html
- AWS DataSync — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- AWS Storage Gateway — https://docs.aws.amazon.com/storagegateway/latest/vgw/WhatIsStorageGateway.html
- AWS Snowball Edge — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- AWS Elastic Beanstalk Developer Guide — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- AWS Systems Manager Session Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- AWS Systems Manager State Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-state.html
- AWS Cloud Development Kit (CDK) v2 — https://docs.aws.amazon.com/cdk/v2/guide/home.html