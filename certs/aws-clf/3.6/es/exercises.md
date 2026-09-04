# Tema 3.6 — Identificar los servicios de almacenamiento de AWS

## Ejercicios guiados · AWS Certified Cloud Practitioner (CLF-C02 v1.0)

**Dominio 3: Tecnología y servicios en la nube — peso en el examen de este enunciado de tarea: 4,25 %**

---

## 0. Antes de empezar

### 0.1 Qué hace y qué no hace este laboratorio

En el nivel Cloud Practitioner el verbo del enunciado de tarea es **«identificar»**: dada la descripción de una carga de trabajo, nombrar el servicio de almacenamiento que encaja y justificarlo. Estos ejercicios te llevan hasta ahí haciéndote *tocar* los servicios, porque las fronteras que el examen evalúa —alcance de AZ, clase de durabilidad, protocolo de acceso, latencia de recuperación, dimensión de facturación— son exactamente las fronteras con las que te topás cuando aprovisionás de verdad.

Vas a construir un patrimonio de almacenamiento pequeño pero real: un bucket de S3 con versionado y política de ciclo de vida, un volumen de EBS y una instantánea restaurada en una zona de disponibilidad distinta, un sistema de archivos de EFS y un plan de AWS Backup. Después vas a ejecutar diagnósticos sobre todo ello.

### 0.2 Requisitos previos

| Requisito | Comprobación |
|---|---|
| Cuenta de AWS con permisos de administrador o equivalentes | `aws sts get-caller-identity` |
| AWS CLI v2 instalada | `aws --version` → `aws-cli/2.x.x ...` |
| Una región predeterminada configurada | `aws configure get region` |
| `jq` instalado (se usa para una salida legible) | `jq --version` |

```console
$ aws --version
aws-cli/2.17.42 Python/3.11.9 Linux/6.8.0-40-generic exe/x86_64.ubuntu.24

$ aws sts get-caller-identity
{
    "UserId": "AIDA2EXAMPLEUSERID4Q",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/lab-practitioner"
}
```

### 0.3 Advertencia de costes

La mayor parte de este laboratorio queda dentro o cerca de la capa gratuita de AWS, pero **no todo**. Precio de lista aproximado si completás todos los pasos opcionales y limpiás el mismo día (us-east-1):

| Recurso | Coste aproximado |
|---|---|
| Objetos de S3 (unos pocos MB) | < $0.01 |
| EBS `gp3` de 8 GiB durante 2 horas | ~$0.001 |
| Instantánea de EBS (unos pocos MB, incremental) | < $0.01 |
| Sistema de archivos EFS, pocos MB, 2 horas | < $0.01 |
| Instancia EC2 `t3.micro` opcional, 2 horas | ~$0.02 |
| Copia de seguridad bajo demanda del volumen de EBS con AWS Backup | ~$0.01 |

**La sección 10 es la sección de limpieza. Ejecutala.** El almacenamiento es la familia de servicios que sigue facturando después de que dejás de prestarle atención — y eso, en sí mismo, es un dato relevante para el examen.

> Los precios citados a lo largo del documento son precios de lista de US East (N. Virginia) en el momento de escribir esto y se usan para enseñar economía *relativa*, no para memorizarse. Verificá siempre contra <https://aws.amazon.com/s3/pricing/> y <https://aws.amazon.com/ebs/pricing/>.

### 0.4 Variables de shell usadas en todo el laboratorio

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LAB=clf36-${ACCOUNT_ID}
export BUCKET=${LAB}-archive
echo "Region=${AWS_REGION}  Account=${ACCOUNT_ID}  Bucket=${BUCKET}"
```

```console
Region=us-east-1  Account=123456789012  Bucket=clf36-123456789012-archive
```

Los nombres de bucket de S3 están en un **único espacio de nombres global compartido por todas las cuentas de AWS del planeta**, y por eso arriba se incorpora el ID de cuenta. Esto no es una regla general de nomenclatura de AWS — es específica de S3 y un detalle preferido del examen.

---

## Ejercicio 1 — Las tres familias de almacenamiento

Todo lo que hay en este enunciado de tarea se resuelve en uno de tres modelos de acceso. Entendé bien esto y aproximadamente la mitad de las preguntas del examen en este dominio se responden solas.

### Pasos

1. Leé la tabla de abajo y, para cada servicio, escribí *a mano* a qué familia pertenece antes de continuar.

| Familia | Cómo la ve el cliente | Unidad escrita | Servicios de AWS |
|---|---|---|---|
| **Bloque** | Un disco crudo, sin formatear, que tenés que particionar y formatear | Bloques de tamaño fijo (LBA) | Amazon **EBS**, **instance store** de EC2 |
| **Archivo** | Un árbol POSIX/SMB montado con directorios y permisos | Archivos, actualizaciones por rango de bytes | Amazon **EFS**, Amazon **FSx** (Windows File Server, Lustre, NetApp ONTAP, OpenZFS) |
| **Objeto** | Un espacio de nombres plano de objetos inmutables direccionados por clave, sobre HTTPS | Objetos completos + metadatos | Amazon **S3**, clases de almacenamiento **S3 Glacier** |

2. Interiorizá la consecuencia mecánica de cada modelo:

   - **Bloque**: el *sistema operativo* es dueño del sistema de archivos. AWS te entrega un disco virtual; el kernel invitado decide si es `ext4`, `xfs` o NTFS. Un único dispositivo de bloques normalmente puede estar conectado a exactamente una instancia a la vez, porque dos kernels escribiendo el mismo superbloque con cachés de página independientes lo corrompen.
   - **Archivo**: el *servidor de archivos* es dueño del sistema de archivos y arbitra el acceso concurrente mediante un protocolo de red (NFSv4.1 para EFS, SMB para FSx for Windows). Muchos clientes lo montan simultáneamente y el bloqueo se gestiona por ellos.
   - **Objeto**: no hay sistema de archivos ni escritura parcial. `PutObject` reemplaza el objeto entero; no hay `seek()` ni modificación de bytes in situ. Las «carpetas» que ves en la consola son una representación del lado de la consola de los caracteres `/` en la clave.

3. Confirmá empíricamente la afirmación sobre el modelo de objetos — las claves de S3 son solo cadenas:

```bash
aws s3api create-bucket --bucket "${BUCKET}" --region "${AWS_REGION}"
echo "hello" > /tmp/f.txt
aws s3api put-object --bucket "${BUCKET}" --key "a/b/c/d/e.txt" --body /tmp/f.txt >/dev/null
aws s3api list-objects-v2 --bucket "${BUCKET}" --query 'Contents[].Key' --output table
```

```console
{
    "Location": "/clf36-123456789012-archive"
}
-------------------------
|     ListObjectsV2     |
+-----------------------+
|  a/b/c/d/e.txt        |
+-----------------------+
```

> **Trampa de región.** `us-east-1` es la única región donde `create-bucket` no lleva restricción de ubicación. En cualquier otra:
> ```bash
> aws s3api create-bucket --bucket "${BUCKET}" --region eu-west-1 \
>   --create-bucket-configuration LocationConstraint=eu-west-1
> ```
> Omitirla devuelve `IllegalLocationConstraintException`.

4. Fijate en que nunca se creó ningún directorio `a/`, `a/b/` ni `a/b/c/`. Borrá el objeto y listá de nuevo — las «carpetas» desaparecen con él, porque nunca existieron.

```bash
aws s3api delete-object --bucket "${BUCKET}" --key "a/b/c/d/e.txt"
aws s3api list-objects-v2 --bucket "${BUCKET}" --query 'KeyCount'
```

```console
0
```

### Comprobación de comprensión

**Q1.** Una aplicación de un proveedor requiere un disco local que pueda formatear como `xfs` y sobre el que realiza actualizaciones aleatorias in situ de 4 KiB a un archivo de base de datos de 200 GiB. ¿Qué familia y qué servicio de AWS?

**Q2.** ¿Por qué no podés «añadir una línea» a un objeto existente de S3 como lo harías con un archivo en EFS? ¿Qué operación tendrías que realizar en su lugar?

**Q3.** En S3, ¿son `a/b/c.txt` y `a/b/` dos entidades almacenadas distintas? Justificá a partir de la salida anterior.

**Q4.** Un equipo de finanzas quiere que 40 escritorios Windows abran la misma carpeta `\\share\budget\` concurrentemente, conservando los permisos de Active Directory. ¿Qué familia y qué servicio concreto de AWS?

---

## Ejercicio 2 — Amazon S3: durabilidad, la frontera de la AZ y valores por defecto seguros

### Pasos

1. Inspeccioná la postura de seguridad por defecto del bucket. Desde abril de 2023, los buckets nuevos se crean con S3 Block Public Access totalmente habilitado y las ACL deshabilitadas.

```bash
aws s3api get-public-access-block --bucket "${BUCKET}" | jq
aws s3api get-bucket-ownership-controls --bucket "${BUCKET}" | jq -c '.OwnershipControls.Rules'
```

```console
{
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }
}
[{"ObjectOwnership":"BucketOwnerEnforced"}]
```

Leé esos cuatro indicadores con precisión — son dos trabajos diferentes:

| Indicador | Qué bloquea |
|---|---|
| `BlockPublicAcls` | Que se establezcan *nuevas* ACL públicas (rechazo en el momento del PUT) |
| `IgnorePublicAcls` | Que se respeten las ACL públicas *existentes* (se ignoran en el momento de la evaluación) |
| `BlockPublicPolicy` | *Nuevas* políticas de bucket que concedan acceso público |
| `RestrictPublicBuckets` | Políticas públicas *existentes*, salvo para entidades principales autenticadas de la misma cuenta |

`BucketOwnerEnforced` deshabilita las ACL por completo: todos los objetos pertenecen al propietario del bucket y el acceso se decide únicamente por políticas de IAM, políticas de bucket y Access Points. Esta es la postura moderna y recomendada.

2. Confirmá que el bucket es regional, no global, y que S3 replica dentro de la región.

```bash
aws s3api get-bucket-location --bucket "${BUCKET}"
```

```console
{
    "LocationConstraint": null
}
```

`null` significa `us-east-1` — un artefacto heredado de que S3 es anterior a la API de restricción de región.

3. Habilitá el versionado y observá que sobrescribir un objeto no destruye los bytes anteriores.

```bash
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

printf 'v1 payroll data\n' > /tmp/payroll.csv
aws s3api put-object --bucket "${BUCKET}" --key payroll.csv --body /tmp/payroll.csv \
  --query VersionId --output text

printf 'v2 payroll data CORRUPTED\n' > /tmp/payroll.csv
aws s3api put-object --bucket "${BUCKET}" --key payroll.csv --body /tmp/payroll.csv \
  --query VersionId --output text
```

```console
3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr8X8gdRQBpUMLUo
QUpfdndhfg8oVpFAMkVX4EK.oJgAKKq0Hk9y3ID.Ml.h5xAlVhAqCPWRb1Rc6zwK
```

4. Listá todas las versiones, incluida la eclipsada:

```bash
aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
  --query 'Versions[].{Key:Key,VersionId:VersionId,IsLatest:IsLatest,Size:Size}' \
  --output table
```

```console
------------------------------------------------------------------------------------
|                                ListObjectVersions                                |
+----------+--------+--------+-------------------------------------------------------+
| IsLatest |  Key   | Size   |                     VersionId                         |
+----------+--------+--------+-------------------------------------------------------+
|  True    | payroll.csv | 26 | QUpfdndhfg8oVpFAMkVX4EK.oJgAKKq0Hk9y3ID.Ml.h5xAlVh... |
|  False   | payroll.csv | 16 | 3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr... |
+----------+--------+--------+-------------------------------------------------------+
```

5. Borrá el objeto *sin* un ID de versión e inspeccioná qué pasó realmente:

```bash
aws s3api delete-object --bucket "${BUCKET}" --key payroll.csv
aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
  --query 'DeleteMarkers[].{VersionId:VersionId,IsLatest:IsLatest}' --output json
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/out.csv
```

```console
[
    {
        "VersionId": "1kbZQ8mDe6.gFqOZ7yTZ9pWdJ4gZ2wQx",
        "IsLatest": true
    }
]

An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist.
```

Los bytes siguen ahí. Un **marcador de borrado** (delete marker) —una versión de cero bytes que se convierte en la versión actual— es lo que hace que `GetObject` devuelva `NoSuchKey`. Este es el mecanismo detrás de «el versionado protege contra el borrado accidental».

6. Recuperá eliminando el marcador de borrado:

```bash
DM=$(aws s3api list-object-versions --bucket "${BUCKET}" --prefix payroll.csv \
     --query 'DeleteMarkers[0].VersionId' --output text)
aws s3api delete-object --bucket "${BUCKET}" --key payroll.csv --version-id "${DM}"
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/out.csv >/dev/null && cat /tmp/out.csv
```

```console
v2 payroll data CORRUPTED
```

7. Forzá TLS con una política de bucket. Guardala como `/tmp/tls-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::REPLACE_BUCKET",
        "arn:aws:s3:::REPLACE_BUCKET/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
```

```bash
sed -i "s/REPLACE_BUCKET/${BUCKET}/g" /tmp/tls-policy.json
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy file:///tmp/tls-policy.json
aws s3api get-bucket-policy-status --bucket "${BUCKET}"
```

```console
{
    "PolicyStatus": {
        "IsPublic": false
    }
}
```

Fijate en ambas formas de ARN en `Resource`. `arn:aws:s3:::bucket` es el bucket en sí (objetivo de `s3:ListBucket`, `s3:GetBucketLocation`); `arn:aws:s3:::bucket/*` son los objetos que contiene (objetivo de `s3:GetObject`, `s3:PutObject`). Confundir ambos es la causa más común, con diferencia, de una política que «se ve bien» y deniega todo.

### Comprobación de comprensión

**Q5.** S3 Standard está diseñado para una durabilidad del 99,999999999 %. ¿En cuántas zonas de disponibilidad almacena cada objeto, y qué dos clases de almacenamiento rompen esa regla?

**Q6.** Habilitás el versionado y luego decidís que ya no lo querés. ¿Cuáles son tus dos opciones, y cuál *no* está disponible?

**Q7.** Después del paso 5, el objeto era invisible para `GetObject` pero te seguían facturando. ¿Por qué?

**Q8.** Distinguí *durabilidad* de *disponibilidad* para S3 Standard. Dá el objetivo numérico de diseño de cada una.

**Q9.** Un compañero dice «nuestro bucket es seguro, Block Public Access está activado, así que no necesitamos una política de bucket». Nombrá una vía de acceso que Block Public Access **no** restringe.

---

## Ejercicio 3 — Clases de almacenamiento de S3 y economía del ciclo de vida

Este ejercicio es donde el examen se gana el sueldo. Las clases difieren en cuatro ejes: **coste por GB-mes, tarifa de recuperación, latencia de recuperación y duración mínima facturable.**

### Pasos

1. Estudiá la tabla de clases. Los números en negrita son los que deciden las respuestas del examen.

| Clase de almacenamiento | AZ | Latencia de recuperación | Duración mín. de almacenamiento | Objeto mín. facturable | ~$/GB-mes | Tarifa de recuperación |
|---|---|---|---|---|---|---|
| S3 Standard | ≥ 3 | ms | ninguna | ninguno | 0.023 | ninguna |
| S3 Intelligent-Tiering | ≥ 3 | ms (niveles frecuente/infrecuente) | ninguna | ninguno | 0.023 → 0.0036 | **ninguna** (+ tarifa de monitorización) |
| S3 Standard-IA | ≥ 3 | ms | **30 días** | **128 KB** | 0.0125 | $0.01/GB |
| S3 One Zone-IA | **1** | ms | **30 días** | **128 KB** | 0.01 | $0.01/GB |
| S3 Express One Zone | **1** (una sola AZ, la zona de disponibilidad que elijas) | ms de un solo dígito | 1 hora | 512 KB | 0.16 | ninguna |
| S3 Glacier Instant Retrieval | ≥ 3 | **ms** | **90 días** | 128 KB | 0.004 | $0.03/GB |
| S3 Glacier Flexible Retrieval | ≥ 3 | **1–5 min (Expedited) / 3–5 h (Standard) / 5–12 h (Bulk, gratis)** | **90 días** | — | 0.0036 | escalonada |
| S3 Glacier Deep Archive | ≥ 3 | **12 h (Standard) / 48 h (Bulk)** | **180 días** | — | 0.00099 | escalonada |

2. Escribí un objeto y confirmá su clase:

```bash
head -c 200000 /dev/urandom > /tmp/blob.bin
aws s3api put-object --bucket "${BUCKET}" --key "logs/2026/app.log" --body /tmp/blob.bin >/dev/null
aws s3api head-object --bucket "${BUCKET}" --key "logs/2026/app.log" \
  --query '{Class:StorageClass,Size:ContentLength}'
```

```console
{
    "Class": null,
    "Size": 200000
}
```

`null` no es un error: S3 omite `StorageClass` de la respuesta cuando el objeto está en `STANDARD`, porque Standard es el valor por defecto.

3. Cambiá la clase in situ con una copia sobre la misma clave y volvé a comprobar:

```bash
aws s3api copy-object --bucket "${BUCKET}" --key "logs/2026/app.log" \
  --copy-source "${BUCKET}/logs/2026/app.log" \
  --storage-class STANDARD_IA --metadata-directive COPY >/dev/null
aws s3api head-object --bucket "${BUCKET}" --key "logs/2026/app.log" --query StorageClass
```

```console
"STANDARD_IA"
```

4. Aplicá una configuración de ciclo de vida. Guardala como `/tmp/lifecycle.json`:

```json
{
  "Rules": [
    {
      "ID": "log-archive-cascade",
      "Filter": { "Prefix": "logs/" },
      "Status": "Enabled",
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER_IR" },
        { "Days": 180, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 2555 },
      "NoncurrentVersionTransitions": [
        { "NoncurrentDays": 30, "StorageClass": "GLACIER" }
      ],
      "NoncurrentVersionExpiration": { "NoncurrentDays": 365 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration file:///tmp/lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --query 'Rules[0].{ID:ID,Transitions:Transitions[].Days}'
```

```console
{
    "ID": "log-archive-cascade",
    "Transitions": [
        30,
        90,
        180
    ]
}
```

En esa única regla viven cuatro mecanismos distintos, y el examen los trata como conceptos separados:

- `Transitions` — mueve la versión **actual** entre clases.
- `Expiration` — borra la versión actual (en un bucket versionado, esto *añade un marcador de borrado*; no libera almacenamiento).
- `NoncurrentVersion*` — las reglas que realmente recuperan espacio en un bucket versionado.
- `AbortIncompleteMultipartUpload` — borra partes multiparte huérfanas. Esas partes se facturan, son invisibles para `ListObjectsV2` y son una fuga de coste silenciosa clásica. **Todo bucket de producción debería tener esta regla.**

5. Encontrá la fuga vos mismo:

```bash
aws s3api list-multipart-uploads --bucket "${BUCKET}" --query 'Uploads' --output json
```

```console
null
```

Limpio acá — pero en un bucket alimentado por un cargador inestable esta lista crece sin aparecer nunca en el listado de objetos.

6. Hacé la aritmética a la que sirven las reglas de ciclo de vida. Para **1 TB** de logs conservados durante un año:

| Escenario | Mensual | Anual |
|---|---|---|
| Los 12 meses en S3 Standard | $23.55 | **$282.62** |
| Standard 1 mes → Standard-IA 2 meses → Glacier IR 3 meses → Deep Archive 6 meses | varía | **≈ $46** |

*(1 TB = 1024 GiB; Standard a $0.023/GB-mes, Standard-IA $0.0125, Glacier IR $0.004, Deep Archive $0.00099, excluidos los cargos por solicitudes de transición.)*

Aproximadamente una reducción de **6×** — y todo el coste de esa reducción es latencia de recuperación que decidiste que podés tolerar.

### Comprobación de comprensión

**Q10.** Tenés 10 millones de imágenes en miniatura de **40 KB** de media cada una, a las que se accede unas pocas veces al año. Un colega propone una regla de ciclo de vida hacia S3 Standard-IA para ahorrar dinero. Calculá por qué esto empeora la factura y enunciá la alternativa correcta.

**Q11.** Unos datos regulatorios deben conservarse 7 años y recuperarse en menos de 12 horas si un auditor los pide. ¿Qué clase de almacenamiento y por qué Glacier Flexible Retrieval no es la respuesta correcta más barata?

**Q12.** Un objeto pasa a S3 Standard-IA el día 1 y se borra el día 10. ¿Cuántos días de almacenamiento en Standard-IA se te facturan?

**Q13.** ¿Qué distingue **S3 Glacier Instant Retrieval** de **S3 Standard-IA**? Nombrá el eje en el que hacen el intercambio.

**Q14.** Un conjunto de datos tiene un acceso completamente impredecible — algunos objetos están calientes, la mayoría fríos, y cambia mes a mes. ¿Qué clase y cuál es su cargo distintivo?

**Q15.** En un bucket versionado, una regla de ciclo de vida `Expiration` se dispara sobre 500 GB de objetos. Tu factura de almacenamiento no baja. Explicá por qué y nombrá la regla que te falta.

---

## Ejercicio 4 — Amazon EBS: almacenamiento de bloques y la frontera de la zona de disponibilidad

### Pasos

1. Determiná tus AZ y creá un volumen `gp3`:

```bash
AZ_A=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
AZ_B=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)
echo "AZ_A=${AZ_A}  AZ_B=${AZ_B}"

VOL_ID=$(aws ec2 create-volume \
  --availability-zone "${AZ_A}" \
  --size 8 \
  --volume-type gp3 \
  --iops 3000 \
  --throughput 125 \
  --encrypted \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB}-data}]" \
  --query VolumeId --output text)
echo "VOL_ID=${VOL_ID}"
```

```console
AZ_A=us-east-1a  AZ_B=us-east-1b
VOL_ID=vol-0a1b2c3d4e5f67890
```

2. Inspeccioná lo que obtuviste:

```bash
aws ec2 describe-volumes --volume-ids "${VOL_ID}" \
  --query 'Volumes[0].{AZ:AvailabilityZone,Type:VolumeType,Size:Size,Iops:Iops,Throughput:Throughput,Enc:Encrypted,State:State,Attached:Attachments}' | jq
```

```console
{
  "AZ": "us-east-1a",
  "Type": "gp3",
  "Size": 8,
  "Iops": 3000,
  "Throughput": 125,
  "Enc": true,
  "State": "available",
  "Attached": []
}
```

El campo `AvailabilityZone` es toda la lección. **Un volumen de EBS vive en exactamente una AZ y solo puede conectarse a una instancia de esa misma AZ.** Se replica *dentro* de esa AZ para durabilidad, pero un fallo de la AZ se lleva el volumen con él.

3. Aprendé los tipos de volumen. `gp3` desacopla las IOPS y el rendimiento de la capacidad — ese es su cambio estrella respecto a `gp2`.

| Tipo | Medio | IOPS máx. | Rendimiento máx. | Dimensionamiento | Uso típico |
|---|---|---|---|---|---|
| `gp3` | SSD | 16.000 | 1.000 MiB/s | 1 GiB–16 TiB, IOPS/rendimiento configurados de forma independiente | Propósito general por defecto; volúmenes de arranque |
| `gp2` | SSD | 16.000 | 250 MiB/s | 3 IOPS por GiB, ráfaga hasta 3.000 por debajo de 1 TiB | Generación anterior |
| `io2` / `io2` Block Express | SSD | 64.000 / **256.000** | 1.000 / **4.000** MiB/s | hasta 64 TiB (Block Express) | Bases de datos críticas en latencia; **durabilidad del 99,999 %** |
| `st1` | HDD | 500 | 500 MiB/s | 125 GiB–16 TiB | Grandes barridos secuenciales: procesamiento de logs, data warehouse |
| `sc1` | HDD | 250 | 250 MiB/s | 125 GiB–16 TiB | Los datos más fríos que aun así necesitan un sistema de archivos; el $/GB de bloques más bajo |

**Los volúmenes HDD (`st1`, `sc1`) no pueden ser volúmenes de arranque.** Son dispositivos de rendimiento; las lecturas pequeñas aleatorias en ellos son patológicamente lentas.

4. Tomá una instantánea y observá cómo se completa:

```bash
SNAP_ID=$(aws ec2 create-snapshot --volume-id "${VOL_ID}" \
  --description "${LAB} baseline" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${LAB}-snap}]" \
  --query SnapshotId --output text)

aws ec2 wait snapshot-completed --snapshot-ids "${SNAP_ID}"
aws ec2 describe-snapshots --snapshot-ids "${SNAP_ID}" \
  --query 'Snapshots[0].{Id:SnapshotId,State:State,Progress:Progress,VolumeSize:VolumeSize,Enc:Encrypted}'
```

```console
{
    "Id": "snap-0f9e8d7c6b5a43210",
    "State": "completed",
    "Progress": "100%",
    "VolumeSize": 8,
    "Enc": true
}
```

Dos mecánicas detrás de esa instantánea que el examen sondea:

- **Las instantáneas se almacenan en Amazon S3** (en un bucket gestionado por AWS que no podés navegar) y por tanto son **regionales**, no zonales. Eso es lo que les permite cruzar la frontera de la AZ.
- **Las instantáneas son incrementales.** Solo se almacenan los bloques modificados desde la instantánea anterior del mismo volumen. Borrar una instantánea más antigua nunca invalida una más nueva — AWS reapunta las referencias de bloques para que la instantánea más nueva siga siendo completamente restaurable.

5. Cruzá la frontera de la AZ — restaurá en la *otra* AZ:

```bash
VOL_B=$(aws ec2 create-volume \
  --availability-zone "${AZ_B}" \
  --snapshot-id "${SNAP_ID}" \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${LAB}-restored}]" \
  --query VolumeId --output text)

aws ec2 describe-volumes --volume-ids "${VOL_ID}" "${VOL_B}" \
  --query 'Volumes[].{Vol:VolumeId,AZ:AvailabilityZone,Snap:SnapshotId}' --output table
```

```console
--------------------------------------------------------------------------
|                             DescribeVolumes                            |
+------------------+-----------------------+---------------------------+
|        AZ        |         Snap          |            Vol            |
+------------------+-----------------------+---------------------------+
|  us-east-1a      |                       |  vol-0a1b2c3d4e5f67890    |
|  us-east-1b      |  snap-0f9e8d7c6b5a... |  vol-0b2c3d4e5f6a78901    |
+------------------+-----------------------+---------------------------+
```

**Instantánea → restauración es la única forma soportada de mover un volumen de EBS entre AZ.** Copiá primero la instantánea a otra región (`aws ec2 copy-snapshot`) y se convierte también en la forma de moverlo entre regiones.

6. Comprobá que la regla de conexión falla entre AZ. Si tenés una instancia corriendo en `AZ_A`, intentá conectar el volumen de `AZ_B`:

```bash
aws ec2 attach-volume --volume-id "${VOL_B}" --instance-id i-0123456789abcdef0 --device /dev/sdf
```

```console
An error occurred (InvalidVolume.ZoneMismatch) when calling the AttachVolume operation:
The volume 'vol-0b2c3d4e5f6a78901' is not in the same availability zone as instance 'i-0123456789abcdef0'
```

### Comprobación de comprensión

**Q16.** Tu servidor de aplicaciones en `us-east-1a` falla. Lanzás un reemplazo en `us-east-1b` e intentás conectar el volumen de datos original de 500 GiB. ¿Qué pasa y cuál es el procedimiento correcto?

**Q17.** Tomás instantáneas diarias de un volumen de 1 TiB que cambia 2 GiB por día. Después de 30 días, ¿aproximadamente cuánto almacenamiento de instantáneas estás pagando y por qué no son 30 TiB?

**Q18.** Borrás la instantánea n.º 1 de 30. ¿Sigue siendo restaurable la n.º 30? Explicá el mecanismo.

**Q19.** Una carga de trabajo necesita 400 MiB/s de rendimiento *secuencial* sobre 4 TiB de datos y nunca hace E/S aleatoria. El coste importa. ¿Qué tipo de volumen de EBS y por qué no `gp3`?

**Q20.** Nombrá la única característica de EBS que permite conectar un solo volumen a varias instancias EC2 simultáneamente, los tipos de volumen que la soportan y el requisito que impone al sistema operativo invitado.

---

## Ejercicio 5 — Instance store: el volumen que no es un servicio que aprovisionás

### Pasos

1. Consultá qué familias de instancias vienen con NVMe local:

```bash
aws ec2 describe-instance-types \
  --filters "Name=instance-storage-supported,Values=true" \
  --query 'InstanceTypes[?starts_with(InstanceType, `i4i.`) || starts_with(InstanceType, `m6gd.`)].{Type:InstanceType,GB:InstanceStorageInfo.TotalSizeInGB,Disks:InstanceStorageInfo.Disks[0].Type}' \
  --output table | head -20
```

```console
------------------------------------------------
|            DescribeInstanceTypes             |
+--------------+----------+--------------------+
|    Disks     |    GB    |       Type         |
+--------------+----------+--------------------+
|  ssd         |  937     |  i4i.large         |
|  ssd         |  1875    |  i4i.xlarge        |
|  ssd         |  3750    |  i4i.2xlarge       |
|  ssd         |  237     |  m6gd.large        |
|  ssd         |  474     |  m6gd.xlarge       |
+--------------+----------+--------------------+
```

2. Fijate en la ausencia de cualquier API `create-instance-store-volume`. No existe. El instance store está **físicamente conectado al servidor anfitrión** y se entrega como un atributo del tipo de instancia — lo tenés porque elegiste `i4i.large`, no porque lo pidieras.

3. Memorizá la tabla de ciclo de vida, que es exactamente lo que se evalúa:

| Evento | Volumen de EBS | Instance store |
|---|---|---|
| Reinicio de la instancia | Los datos sobreviven | **Los datos sobreviven** |
| Detención / arranque de la instancia | Los datos sobreviven | **Datos perdidos** |
| Hibernación de la instancia | Los datos sobreviven | **Datos perdidos** |
| Terminación de la instancia | Sobrevive si `DeleteOnTermination=false` | **Datos perdidos** |
| Fallo del host subyacente | Los datos sobreviven (replicados dentro de la AZ) | **Datos perdidos** |
| ¿Instantánea posible? | Sí (`create-snapshot`) | **No** |
| ¿Se factura por separado? | Sí, por GB-mes | **No** — incluido en el precio de la instancia |

4. Comprobá el indicador `DeleteOnTermination` en el volumen raíz de una instancia existente — el ajuste que destruye silenciosamente datos que la gente suponía duraderos:

```bash
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].{Dev:DeviceName,Vol:Ebs.VolumeId,DoT:Ebs.DeleteOnTermination}' \
  --output table
```

```console
-----------------------------------------------------------
|                    DescribeInstances                    |
+-------+------------+--------------------------------+
|  DoT  |    Dev     |              Vol               |
+-------+------------+--------------------------------+
|  True |  /dev/xvda |  vol-0aa11bb22cc33dd44         |
|  False|  /dev/sdf  |  vol-0a1b2c3d4e5f67890         |
+-------+------------+--------------------------------+
```

El valor por defecto es `true` para el volumen raíz y `false` para los volúmenes conectados posteriormente.

### Comprobación de comprensión

**Q21.** Un ingeniero guarda un archivo de persistencia de Redis en instance store para obtener las máximas IOPS y luego detiene la instancia durante la noche para ahorrar dinero. ¿Cuál es el estado del archivo a la mañana siguiente y por qué?

**Q22.** ¿Cómo hacés una copia de seguridad de un volumen de instance store con una instantánea puntual en el tiempo?

**Q23.** Dá el único perfil de carga de trabajo para el que el instance store es la elección *correcta* en producción, y enunciá la precondición arquitectónica.

---

## Ejercicio 6 — Sistemas de archivos compartidos: Amazon EFS y Amazon FSx

### Pasos

1. Creá un sistema de archivos EFS con rendimiento Elastic y niveles de ciclo de vida:

```bash
FS_ID=$(aws efs create-file-system \
  --creation-token "${LAB}-efs" \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value="${LAB}-efs" \
  --query FileSystemId --output text)

aws efs wait file-system-available --file-system-id "${FS_ID}" 2>/dev/null || sleep 15
aws efs describe-file-systems --file-system-id "${FS_ID}" \
  --query 'FileSystems[0].{Id:FileSystemId,State:LifeCycleState,Mode:PerformanceMode,Tput:ThroughputMode,Size:SizeInBytes.Value,Enc:Encrypted}'
```

```console
{
    "Id": "fs-0123456789abcdef0",
    "State": "available",
    "Mode": "generalPurpose",
    "Tput": "elastic",
    "Size": 6144,
    "Enc": true
}
```

`SizeInBytes` es 6144 en un sistema de archivos vacío — sobrecarga de metadatos de EFS. Fijate en que no hay ningún parámetro de capacidad en ese comando: **EFS es elástico, crece y se reduce automáticamente, y se te factura por lo que realmente almacenás.** Este es el contraste más agudo con EBS y FSx, donde aprovisionás un tamaño por adelantado.

2. Creá destinos de montaje — uno por AZ. Aquí es donde la naturaleza multi-AZ de EFS se vuelve concreta:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
             --query 'Subnets[0:2].SubnetId' --output text); do
  aws efs create-mount-target --file-system-id "${FS_ID}" --subnet-id "${SUB}" \
    --query '{MT:MountTargetId,AZ:AvailabilityZoneName,IP:IpAddress}'
done
```

```console
{
    "MT": "fsmt-0aaa11bb22cc33dd4",
    "AZ": "us-east-1a",
    "IP": "172.31.16.204"
}
{
    "MT": "fsmt-0bbb22cc33dd44ee5",
    "AZ": "us-east-1b",
    "IP": "172.31.32.117"
}
```

Cada destino de montaje es una **interfaz de red elástica con una IP privada dentro de una subred**. Un cliente en `us-east-1a` monta a través del destino de montaje de `us-east-1a`. Contrastá con EBS: el sistema de archivos en sí abarca varias AZ; solo el punto de entrada de red es zonal.

3. Añadí una política de ciclo de vida para que los archivos fríos bajen de nivel automáticamente:

```bash
aws efs put-lifecycle-configuration --file-system-id "${FS_ID}" \
  --lifecycle-policies \
    '[{"TransitionToIA":"AFTER_30_DAYS"},
      {"TransitionToArchive":"AFTER_90_DAYS"},
      {"TransitionToPrimaryStorageClass":"AFTER_1_ACCESS"}]' \
  --query 'LifecyclePolicies'
```

```console
[
    {
        "TransitionToIA": "AFTER_30_DAYS"
    },
    {
        "TransitionToArchive": "AFTER_90_DAYS"
    },
    {
        "TransitionToPrimaryStorageClass": "AFTER_1_ACCESS"
    }
]
```

EFS Standard cuesta aproximadamente **$0.30/GB-mes** — más de 10× S3 Standard. EFS Infrequent Access baja a unos **$0.016** y EFS Archive a unos **$0.008**. Los niveles no son higiene opcional en EFS; son la diferencia entre una factura viable y una absurda.

4. Montalo (requiere una instancia EC2 en la VPC con el grupo de seguridad permitiendo **TCP 2049** desde el cliente):

```bash
sudo dnf install -y amazon-efs-utils     # Amazon Linux 2023
sudo mkdir -p /mnt/efs
sudo mount -t efs -o tls fs-0123456789abcdef0:/ /mnt/efs
df -hT /mnt/efs
```

```console
Filesystem     Type  Size  Used Avail Use% Mounted on
127.0.0.1:/    nfs4  8.0E     0  8.0E   0% /mnt/efs
```

`8.0E` (8 exabytes) es EFS informando de un máximo nominal, no de un tamaño aprovisionado. El origen del montaje muestra `127.0.0.1` porque `-o tls` enruta a través del proceso `stunnel` local que `efs-utils` arranca para el cifrado en tránsito.

Sin `efs-utils`, el equivalente NFS crudo es:

```bash
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  fs-0123456789abcdef0.efs.us-east-1.amazonaws.com:/ /mnt/efs
```

5. Mapeá la familia FSx, que es la rama «la respuesta no es EFS» del árbol de decisión:

| Servicio | Protocolo | SO cliente | Caso de uso característico |
|---|---|---|---|
| **Amazon EFS** | NFS v4.1 | **Solo Linux** | Directorios personales compartidos, activos de CMS, volúmenes persistentes de contenedores |
| **FSx for Windows File Server** | **SMB** | Windows (también Linux/macOS) | Cargas de trabajo Windows que necesitan identidad de **Active Directory**, ACL de NTFS, espacios de nombres DFS |
| **FSx for Lustre** | Lustre (POSIX) | Linux | HPC, entrenamiento de ML, genómica; **se vincula a un bucket de S3** y presenta los objetos como archivos con latencia inferior al milisegundo |
| **FSx for NetApp ONTAP** | **NFS + SMB + iSCSI** simultáneamente | Mixto | Migración lift-and-shift de NetApp on-premises; acceso multiprotocolo a un mismo conjunto de datos; instantáneas/SnapMirror |
| **FSx for OpenZFS** | NFS (v3/v4/v4.1/v4.2) | Linux | Migración de ZFS o cargas NAS Linux generales que necesitan instantáneas y compresión de ZFS |

Los discriminadores del examen, en orden de frecuencia con la que aparecen: **«Windows / Active Directory / SMB» → FSx for Windows File Server. «HPC / machine learning / cómputo de alto rendimiento sobre datos de S3» → FSx for Lustre. «Sistema de archivos compartido Linux» → EFS.**

### Comprobación de comprensión

**Q24.** Una aplicación Windows necesita una unidad compartida con permisos NTFS integrados con Active Directory. ¿Por qué EFS es incorrecto y qué es lo correcto?

**Q25.** Creaste un destino de montaje de EFS en `us-east-1a`. Una instancia en `us-east-1b` se queda colgada en `mount` y acaba agotando el tiempo de espera. Dá las dos causas más probables y la solución de cada una.

**Q26.** EFS Standard cuesta 10× el precio por GB de S3 Standard. Nombrá una carga de trabajo donde pagar ese sobreprecio es, aun así, la decisión arquitectónica correcta.

**Q27.** Un pipeline de genómica tiene 300 TB de datos de referencia en S3 y necesita presentarlos a un clúster de cómputo de 500 nodos como un sistema de archivos POSIX con latencia inferior al milisegundo. ¿Qué servicio?

**Q28.** ¿Qué único servicio de almacenamiento de AWS puede presentar el *mismo* conjunto de datos sobre NFS, SMB e iSCSI simultáneamente?

---

## Ejercicio 7 — Híbrido y migración: Storage Gateway, DataSync, familia Snow

No vas a aprovisionar estos — necesitan hardware on-premises o un envío físico. En su lugar vas a construir el árbol de decisión, que es lo que evalúa el examen.

### Pasos

1. Mapeá los cuatro tipos de Storage Gateway. Cada uno de ellos es un **dispositivo virtual (o dispositivo físico) que corre en tu centro de datos** y que presenta un protocolo local y almacena en AWS.

| Tipo de gateway | Protocolo local que presenta | Almacén de AWS de respaldo | Sustituye a |
|---|---|---|---|
| **S3 File Gateway** | NFS / SMB | Objetos en **S3** (1 archivo = 1 objeto) | NAS on-premises, con los datos aterrizando como objetos S3 nativos |
| **FSx File Gateway** | SMB | **FSx for Windows File Server** | Caché local de baja latencia delante de un recurso compartido de FSx |
| **Volume Gateway — Cached** | bloque **iSCSI** | S3, con una caché local de los bloques calientes | SAN donde el conjunto de datos principal vive en AWS |
| **Volume Gateway — Stored** | bloque **iSCSI** | Copia completa on-premises, respaldada asíncronamente en **instantáneas de EBS** | SAN donde el conjunto de datos principal permanece on-premises |
| **Tape Gateway (VTL)** | **VTL iSCSI** | S3 + **S3 Glacier / Deep Archive** | Biblioteca física de cintas y custodia de cintas fuera de sitio |

La distinción Cached-vs-Stored es una pregunta de examen fiable: **Cached = datos principales en AWS, caché caliente local. Stored = datos principales locales, copia de seguridad en AWS.** «Acceso de baja latencia a *todo* mi conjunto de datos» ⇒ Stored. «Mi conjunto de datos es más grande que mi centro de datos» ⇒ Cached.

2. Mapeá los servicios de transferencia frente a la restricción que realmente decide entre ellos: **ancho de banda del enlace y volumen de datos**.

| Servicio | Mecanismo | Cuándo gana |
|---|---|---|
| **AWS DataSync** | Transferencia basada en agente **por red** (internet o Direct Connect), NFS/SMB/HDFS/objetos → S3, EFS, FSx | Ancho de banda adecuado; recurrente o puntual; necesita validación, programación y sincronización incremental |
| **AWS Snowball Edge** | **Dispositivo físico reforzado enviado a tu domicilio**, ~80 TB de almacenamiento utilizable (Storage Optimized), más cómputo a bordo | Decenas a cientos de TB con ancho de banda insuficiente, o un emplazamiento en el borde sin conectividad |
| **AWS Snowcone** | El dispositivo más pequeño, 8 TB HDD / 14 TB SSD, ~2,1 kg | Ubicaciones de borde con espacio limitado, drones, vehículos, transferencias pequeñas |
| **AWS Transfer Family** | Endpoint gestionado de **SFTP / FTPS / FTP / AS2** delante de S3 o EFS | Socios que deben seguir usando un cliente SFTP |
| **S3 Transfer Acceleration** | Las cargas entran por la **ubicación de borde de CloudFront** más cercana y luego viajan por la red troncal de AWS | Cargas de larga distancia a una región lejana |

3. Hacé el cálculo que produce la respuesta «Snowball». Tiempo para transferir *D* terabytes por un enlace de *B* Mbps con un 80 % de utilización:

```
hours = (D × 8 × 1,000,000) / (B × 0.8 × 3600)
```

Para **100 TB por un enlace de 500 Mbps**:

```console
$ python3 -c "D=100; B=500; print(f'{(D*8*1e6)/(B*0.8*3600)/24:.1f} days')"
23.1 days
```

23 días saturando tu enlace de internet de producción. Un viaje de ida y vuelta de un Snowball Edge es aproximadamente una semana y no toca tu ancho de banda. **Este es el razonamiento que busca el examen — no las especificaciones del dispositivo.**

4. Tomá nota de la retirada: **AWS Snowmobile (el contenedor de transporte de 100 PB) ha sido discontinuado** y ya no se puede pedir. Material de estudio antiguo y algunos bancos de preguntas todavía lo mencionan; la guía de examen actual limita la familia Snow a Snowcone y Snowball Edge. Las migraciones extremadamente grandes se manejan ahora con varios dispositivos Snowball Edge en paralelo.

5. Habilitá S3 Transfer Acceleration en tu bucket de laboratorio y observá el endpoint alternativo:

```bash
aws s3api put-bucket-accelerate-configuration --bucket "${BUCKET}" \
  --accelerate-configuration Status=Enabled
aws s3api get-bucket-accelerate-configuration --bucket "${BUCKET}"
echo "Accelerated endpoint: ${BUCKET}.s3-accelerate.amazonaws.com"
```

```console
{
    "Status": "Enabled"
}
Accelerated endpoint: clf36-123456789012-archive.s3-accelerate.amazonaws.com
```

Deshabilitalo inmediatamente después de observarlo — las transferencias aceleradas llevan un recargo por GB:

```bash
aws s3api put-bucket-accelerate-configuration --bucket "${BUCKET}" \
  --accelerate-configuration Status=Suspended
```

### Comprobación de comprensión

**Q29.** Una empresa de medios tiene 400 TB de metraje de archivo on-premises y un enlace de internet de 200 Mbps que además transporta tráfico de producción. Necesitan tenerlo en S3 Glacier en un mes. ¿Qué servicio, y mostrá el razonamiento?

**Q30.** Un hospital debe retirar su biblioteca física de cintas, pero su software de backup solo habla con unidades de cinta sobre iSCSI. ¿Qué servicio y qué modo?

**Q31.** Distinguí Volume Gateway Cached de Volume Gateway Stored en una frase cada uno.

**Q32.** Una sucursal necesita seguir escribiendo en un recurso compartido NFS local, pero los archivos deben acabar como objetos de S3 que una función Lambda pueda procesar. ¿Qué servicio?

**Q33.** Un equipo sincroniza 2 TB cada noche desde un NAS on-premises hacia EFS por un enlace Direct Connect de 10 Gbps, y necesita verificación de integridad y programación. ¿Snowball o DataSync? ¿Por qué?

---

## Ejercicio 8 — AWS Backup e inmutabilidad

### Pasos

1. Inspeccioná el almacén de copias de seguridad por defecto y creá uno dedicado:

```bash
aws backup create-backup-vault --backup-vault-name "${LAB}-vault" \
  --backup-vault-tags Purpose=clf36-lab \
  --query '{Name:BackupVaultName,Arn:BackupVaultArn}'
```

```console
{
    "Name": "clf36-123456789012-vault",
    "Arn": "arn:aws:backup:us-east-1:123456789012:backup-vault:clf36-123456789012-vault"
}
```

2. Creá un plan de copias de seguridad. Guardalo como `/tmp/plan.json`:

```json
{
  "BackupPlanName": "clf36-daily-plan",
  "Rules": [
    {
      "RuleName": "DailyRetain35",
      "TargetBackupVaultName": "REPLACE_VAULT",
      "ScheduleExpression": "cron(0 5 ? * * *)",
      "StartWindowMinutes": 60,
      "CompletionWindowMinutes": 180,
      "Lifecycle": {
        "MoveToColdStorageAfterDays": 30,
        "DeleteAfterDays": 365
      },
      "RecoveryPointTags": { "Tier": "daily" }
    }
  ]
}
```

```bash
sed -i "s/REPLACE_VAULT/${LAB}-vault/" /tmp/plan.json
PLAN_ID=$(aws backup create-backup-plan --backup-plan file:///tmp/plan.json \
  --query BackupPlanId --output text)
echo "PLAN_ID=${PLAN_ID}"
```

```console
PLAN_ID=8f4a2c1e-5b6d-4a3f-9e2c-7d1b0a9f8e7c
```

> AWS Backup valida que `DeleteAfterDays ≥ MoveToColdStorageAfterDays + 90`. Poner `DeleteAfterDays: 100` con almacenamiento en frío en el día 30 devuelve `InvalidParameterValueException` — esto refleja la duración mínima de 90 días de los niveles Glacier subyacentes.

3. Seleccioná recursos **por etiqueta**, no por ID. Este es el punto de diseño de AWS Backup: la política se adhiere a una etiqueta, así que un recurso creado el mes que viene queda protegido en el momento en que se etiqueta.

```bash
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/service-role/AWSBackupDefaultServiceRole"

aws backup create-backup-selection --backup-plan-id "${PLAN_ID}" \
  --backup-selection "{
    \"SelectionName\": \"tagged-backup-daily\",
    \"IamRoleArn\": \"${ROLE_ARN}\",
    \"ListOfTags\": [
      {\"ConditionType\": \"STRINGEQUALS\", \"ConditionKey\": \"Backup\", \"ConditionValue\": \"daily\"}
    ]
  }" --query SelectionId --output text
```

```console
c3f9a1b7-2d84-4e60-9a1f-6b52c8d0e3a4
```

4. Etiquetá el volumen de EBS del ejercicio 4 y tomá una copia de seguridad bajo demanda:

```bash
aws ec2 create-tags --resources "${VOL_ID}" --tags Key=Backup,Value=daily

JOB_ID=$(aws backup start-backup-job \
  --backup-vault-name "${LAB}-vault" \
  --resource-arn "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:volume/${VOL_ID}" \
  --iam-role-arn "${ROLE_ARN}" \
  --query BackupJobId --output text)

sleep 60
aws backup describe-backup-job --backup-job-id "${JOB_ID}" \
  --query '{State:State,Pct:PercentDone,Bytes:BackupSizeInBytes,RP:RecoveryPointArn}'
```

```console
{
    "State": "COMPLETED",
    "Pct": "100.0",
    "Bytes": 8589934592,
    "RP": "arn:aws:ec2:us-east-1::snapshot/snap-01a2b3c4d5e6f7890"
}
```

Mirá con atención ese `RecoveryPointArn`: es una **instantánea de EBS**. AWS Backup no inventó un nuevo mecanismo de almacenamiento; orquestó el nativo del servicio y le aplicó encima una política, un calendario de retención y un rastro de auditoría. Su valor es la *centralización y la gobernanza* a través de EBS, EFS, RDS, DynamoDB, FSx, Storage Gateway, S3, Aurora, Neptune, DocumentDB y VMware on-premises — una política, una consola, un informe de cumplimiento.

5. Entendé **Vault Lock** sin activarlo:

```bash
# DO NOT RUN in compliance mode on a real account.
# aws backup put-backup-vault-lock-configuration \
#   --backup-vault-name "${LAB}-vault" \
#   --min-retention-days 7 --max-retention-days 365 --changeable-for-days 3
```

Vault Lock impone **WORM** (write-once, read-many) sobre los puntos de recuperación. En *modo compliance*, una vez que transcurre el periodo de gracia `changeable-for-days` (mínimo 3 días), **el bloqueo no puede ser eliminado por nadie — ni por el usuario raíz de la cuenta, ni por el soporte de AWS**. Las copias de seguridad no pueden borrarse antes de que expire su retención. Este es el control principal contra ransomware y amenazas internas dentro de la historia del backup, y su equivalente en S3 es **S3 Object Lock** (que igualmente ofrece modo governance —eludible con un permiso IAM específico— y modo compliance, que no lo es).

### Comprobación de comprensión

**Q34.** El punto de recuperación de AWS Backup para un volumen de EBS resultó ser una instantánea de EBS. Entonces, ¿qué añade realmente AWS Backup?

**Q35.** Un atacante obtiene credenciales de administrador e intenta borrar todas las copias de seguridad antes de cifrar producción. ¿Qué dos características detienen esto, una para copias de seguridad y otra para S3?

**Q36.** ¿Por qué rechazó AWS un plan con `MoveToColdStorageAfterDays: 30` y `DeleteAfterDays: 100`?

**Q37.** Tu selección de copia de seguridad coincide con la etiqueta `Backup=daily`. Un colega lanza una nueva instancia de RDS el mes que viene y la etiqueta. ¿Qué pasa y por qué es este el punto de diseño?

---

## Ejercicio 9 — Diagnósticos

Tres fallos con los que realmente te vas a encontrar, cada uno con su ruta de investigación.

### 9.1 `AccessDenied` en `GetObject`

Pasos:

1. Reproducí con una solicitud sin firmar:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://${BUCKET}.s3.amazonaws.com/payroll.csv"
```

```console
403
```

2. Recorré la cadena de evaluación en orden. Una solicitud a S3 se permite solo si **todas** las capas la permiten, y un `Deny` explícito en cualquier punto gana de forma rotunda:

```bash
echo "--- 1. Block Public Access (account level) ---"
aws s3control get-public-access-block --account-id "${ACCOUNT_ID}" 2>/dev/null | jq -c '.PublicAccessBlockConfiguration' || echo "not configured at account level"

echo "--- 2. Block Public Access (bucket level) ---"
aws s3api get-public-access-block --bucket "${BUCKET}" | jq -c '.PublicAccessBlockConfiguration'

echo "--- 3. Bucket policy ---"
aws s3api get-bucket-policy --bucket "${BUCKET}" --query Policy --output text | jq -c '.Statement[].Effect'

echo "--- 4. Object ownership / ACL state ---"
aws s3api get-bucket-ownership-controls --bucket "${BUCKET}" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text

echo "--- 5. Default encryption ---"
aws s3api get-bucket-encryption --bucket "${BUCKET}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' | jq -c
```

```console
--- 1. Block Public Access (account level) ---
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
--- 2. Block Public Access (bucket level) ---
{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}
--- 3. Bucket policy ---
"Deny"
--- 4. Object ownership / ACL state ---
BucketOwnerEnforced
--- 5. Default encryption ---
{"SSEAlgorithm":"AES256"}
```

El 403 aquí es *comportamiento correcto*, producido por cuatro controles independientes. La habilidad de diagnóstico está en saber que hay cuatro sitios donde mirar, en ese orden.

3. Verificá que tu propia identidad autenticada sigue funcionando:

```bash
aws s3api get-object --bucket "${BUCKET}" --key payroll.csv /tmp/ok.csv --query 'ContentLength'
```

```console
26
```

### 9.2 Crecimiento silencioso del coste de S3

Pasos:

1. Leé las métricas diarias gratuitas de almacenamiento desde CloudWatch. Fijate en la dimensión `StorageType` obligatoria:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value="${BUCKET}" Name=StorageType,Value=StandardStorage \
  --start-time "$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 86400 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[].{T:Timestamp,Bytes:Average}' --output table
```

```console
--------------------------------------------------
|              GetMetricStatistics               |
+------------+-----------------------------------+
|   Bytes    |               T                   |
+------------+-----------------------------------+
|  200042.0  |  2026-09-02T00:00:00+00:00        |
|  200068.0  |  2026-09-03T00:00:00+00:00        |
+------------+-----------------------------------+
```

`BucketSizeBytes` y `NumberOfObjects` son gratuitas y se reportan una vez al día. Las métricas por solicitud son una opción de pago.

2. Enumerá los tres depósitos de almacenamiento que `ListObjectsV2` no te muestra:

```bash
echo "== Non-current versions =="
aws s3api list-object-versions --bucket "${BUCKET}" \
  --query 'length(Versions[?IsLatest==`false`])'

echo "== Delete markers (zero bytes, but they hide live data) =="
aws s3api list-object-versions --bucket "${BUCKET}" --query 'length(DeleteMarkers)'

echo "== Orphaned multipart parts =="
aws s3api list-multipart-uploads --bucket "${BUCKET}" --query 'length(Uploads)'
```

```console
== Non-current versions ==
1
== Delete markers (zero bytes, but they hide live data) ==
0
== Orphaned multipart parts ==
1
```

3. Desglosá el tamaño por clase de almacenamiento para todo el bucket:

```bash
aws s3 ls "s3://${BUCKET}" --recursive --summarize --human-readable | tail -3
aws s3api list-objects-v2 --bucket "${BUCKET}" \
  --query 'Contents[].{Key:Key,Class:StorageClass}' --output table
```

```console
Total Objects: 2
   Total Size: 195.4 KiB
-----------------------------------------------
|               ListObjectsV2                 |
+---------------+-----------------------------+
|     Class     |            Key              |
+---------------+-----------------------------+
|  STANDARD_IA  |  logs/2026/app.log          |
|  None         |  payroll.csv                |
+---------------+-----------------------------+
```

**`aws s3 ls --summarize` cuenta solo las versiones actuales.** En un bucket versionado, el número que imprime puede ser una fracción pequeña de lo que se te factura. Para una vista real de toda la cuenta, usá **S3 Storage Lens** (panel gratuito con 28 métricas por defecto, incluidos los bytes de versiones no actuales y los bytes de multiparte incompletas) o **S3 Inventory** para un manifiesto CSV/Parquet programado.

### 9.3 Investigación de rendimiento de EBS

Pasos:

1. Comprobá si hay limitación (throttling) a nivel de volumen. `BurstBalance` existe solo en `gp2`, `st1`, `sc1` — en `gp3` no hay nada que agotar, lo cual es una de sus principales ventajas operativas:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EBS --metric-name BurstBalance \
  --dimensions Name=VolumeId,Value="${VOL_ID}" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Minimum \
  --query 'length(Datapoints)'
```

```console
0
```

Cero puntos de datos en un volumen `gp3` — esperado, y en sí mismo información de diagnóstico.

2. Comprobá `VolumeQueueLength`, la señal de saturación de EBS más útil que existe. Es el recuento de solicitudes de E/S esperando a ser atendidas. Mantenerse por encima de ~1 por cada 1.000 IOPS aprovisionadas significa que el cuello de botella es el dispositivo, no la aplicación:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EBS --metric-name VolumeQueueLength \
  --dimensions Name=VolumeId,Value="${VOL_ID}" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Average --query 'Datapoints[].Average'
```

3. Comprobá los límites de EBS **a nivel de instancia**, que son independientes de los del volumen y pueden ser más bajos. En instancias Nitro las métricas son `EBSIOBalance%` y `EBSByteBalance%` en el espacio de nombres `AWS/EC2`. Un volumen aprovisionado con 16.000 IOPS conectado a una instancia cuyo ancho de banda de EBS tope en 8.000 nunca superará las 8.000 — y las métricas propias del volumen no mostrarán limitación alguna. **El tipo de instancia es la mitad del rendimiento de EBS.**

4. En la instancia misma, confirmá desde el lado del invitado:

```bash
lsblk
sudo iostat -xz 5 3
```

```console
NAME          MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1       259:0    0    8G  0 disk
└─nvme0n1p1   259:1    0    8G  0 part /
nvme1n1       259:2    0    8G  0 disk /data

Device   r/s     w/s     rkB/s   wkB/s  await  %util
nvme1n1  0.00  2998.40    0.00 11993.60  21.34  99.80
```

`%util` al 99,8 con `w/s` clavado en ~3.000 —exactamente la línea base aprovisionada— es la firma de un volumen en su límite de IOPS. Con `gp3` la solución es una única llamada a la API, sin redimensionar y sin tiempo de inactividad:

```bash
aws ec2 modify-volume --volume-id "${VOL_ID}" --iops 8000 --throughput 500 \
  --query 'VolumeModification.{State:ModificationState,TargetIops:TargetIops}'
```

```console
{
    "State": "modifying",
    "TargetIops": 8000
}
```

### Comprobación de comprensión

**Q38.** `aws s3 ls --summarize` informa de 40 GB. Tu factura muestra 900 GB de S3 Standard. Nombrá tres lugares donde podrían estar los 860 GB que faltan, y el comando que revela cada uno.

**Q39.** Un volumen `gp3` no muestra ninguna métrica `BurstBalance`. ¿Está roto el volumen?

**Q40.** `VolumeQueueLength` está plana cerca de cero y `VolumeReadOps` está muy por debajo de las IOPS aprovisionadas, pero la base de datos va lenta y el `%util` en el invitado es del 100 %. ¿Dónde mirás a continuación?

**Q41.** Ordená los cuatro controles que comprobás al diagnosticar un `AccessDenied` de S3 y enunciá la regla que hace que el orden importe.

---

## Ejercicio 10 — Limpieza

Ejecutá esto. El almacenamiento factura en silencio.

### Pasos

1. Vaciá y borrá el bucket versionado. `aws s3 rb --force` **no elimina las versiones no actuales ni los marcadores de borrado** — un bucket versionado debe purgarse versión a versión:

```bash
aws s3api delete-objects --bucket "${BUCKET}" --delete "$(
  aws s3api list-object-versions --bucket "${BUCKET}" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null

aws s3api delete-objects --bucket "${BUCKET}" --delete "$(
  aws s3api list-object-versions --bucket "${BUCKET}" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null

for U in $(aws s3api list-multipart-uploads --bucket "${BUCKET}" \
           --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null); do :; done

aws s3api delete-bucket --bucket "${BUCKET}" && echo "bucket deleted"
```

```console
bucket deleted
```

2. Eliminá los recursos de EBS:

```bash
aws ec2 delete-volume --volume-id "${VOL_ID}"
aws ec2 delete-volume --volume-id "${VOL_B}"
aws ec2 delete-snapshot --snapshot-id "${SNAP_ID}"
```

3. Eliminá EFS — primero los destinos de montaje, o el borrado será rechazado:

```bash
for MT in $(aws efs describe-mount-targets --file-system-id "${FS_ID}" \
            --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id "${MT}"
done
sleep 60
aws efs delete-file-system --file-system-id "${FS_ID}" && echo "efs deleted"
```

```console
efs deleted
```

4. Eliminá los objetos de AWS Backup. Los puntos de recuperación deben irse antes que el almacén:

```bash
for RP in $(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "${LAB}-vault" \
            --query 'RecoveryPoints[].RecoveryPointArn' --output text); do
  aws backup delete-recovery-point --backup-vault-name "${LAB}-vault" --recovery-point-arn "${RP}"
done

SEL=$(aws backup list-backup-selections --backup-plan-id "${PLAN_ID}" \
      --query 'BackupSelectionsList[0].SelectionId' --output text)
aws backup delete-backup-selection --backup-plan-id "${PLAN_ID}" --selection-id "${SEL}"
aws backup delete-backup-plan --backup-plan-id "${PLAN_ID}" >/dev/null
aws backup delete-backup-vault --backup-vault-name "${LAB}-vault" && echo "vault deleted"
```

5. Verificá que no sobrevivió nada:

```bash
aws ec2 describe-volumes --filters "Name=tag:Name,Values=${LAB}-*" --query 'length(Volumes)'
aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Name,Values=${LAB}-*" --query 'length(Snapshots)'
aws s3api list-buckets --query "length(Buckets[?Name=='${BUCKET}'])"
```

```console
0
0
0
```

### Comprobación de comprensión

**Q42.** ¿Por qué `aws s3 rb --force` no consiguió borrar el bucket versionado, y qué te dice eso sobre cómo contabiliza S3 las versiones?

**Q43.** Borrar el sistema de archivos EFS falló hasta que se eliminaron los destinos de montaje. ¿Qué revela ese orden sobre qué *es* un destino de montaje?

---

## Síntesis final — la tabla de identificación

Aprendete esto de memoria. Responde directamente al enunciado de tarea.

| Requisito en el enunciado de la pregunta | Servicio |
|---|---|
| Almacenamiento de objetos, API HTTP, alojamiento de sitios web estáticos, lago de datos | **Amazon S3** |
| Archivo, recuperación en horas, menor coste por GB | **S3 Glacier Flexible Retrieval / Deep Archive** |
| Archivo con recuperación en milisegundos | **S3 Glacier Instant Retrieval** |
| Patrones de acceso impredecibles y cambiantes, optimización automática | **S3 Intelligent-Tiering** |
| Volumen de bloques persistente para una instancia EC2 | **Amazon EBS** |
| Espacio temporal de trabajo, caché, búfer; IOPS máximas; pérdida de datos aceptable | **EC2 instance store** |
| Sistema de archivos Linux compartido, NFS, capacidad elástica, multi-AZ | **Amazon EFS** |
| Sistema de archivos Windows compartido, SMB, Active Directory | **FSx for Windows File Server** |
| Sistema de archivos para HPC / ML vinculado a S3 | **FSx for Lustre** |
| Multiprotocolo (NFS+SMB+iSCSI); migración de NetApp | **FSx for NetApp ONTAP** |
| Instantáneas ZFS / migración de NAS Linux | **FSx for OpenZFS** |
| Dispositivo on-premises que hace de puente con el almacenamiento de AWS | **AWS Storage Gateway** |
| Sustituir una biblioteca física de cintas | **Storage Gateway — Tape Gateway** |
| Migración de petabytes, ancho de banda insuficiente, envío físico | **AWS Snowball Edge** |
| Transferencia/sincronización por red a S3, EFS, FSx con validación | **AWS DataSync** |
| SFTP/FTPS gestionado delante de S3 o EFS | **AWS Transfer Family** |
| Copias de seguridad centralizadas y dirigidas por políticas en muchos servicios | **AWS Backup** |
| Copias de seguridad inmutables e imborrables (WORM) | **Backup Vault Lock** / **S3 Object Lock** |

---

<details>
<summary><strong>Respuestas</strong> — desplegá solo después de intentar todas las preguntas</summary>

### Ejercicio 1 — Las tres familias de almacenamiento

**A1.** **Almacenamiento de bloques → Amazon EBS**, concretamente un volumen `gp3` o `io2`. Dos requisitos lo fuerzan: la aplicación debe *formatear* el dispositivo ella misma (así que necesita un dispositivo de bloques crudo, no el espacio de nombres de un servidor de archivos), y realiza *actualizaciones aleatorias in situ* sobre un archivo grande. El almacenamiento de objetos no puede hacer escrituras parciales en absoluto; un sistema de archivos en red añadiría latencia de protocolo a cada actualización de 4 KiB. Si la carga de trabajo exigiera además latencia inferior al milisegundo con IOPS muy altas, `io2` Block Express es la escalada.

**A2.** Porque los objetos de S3 son **inmutables**. No hay `append`, ni `seek`, ni escritura por rango de bytes en el modelo de datos de S3 — solo `PutObject`, que reemplaza el objeto entero y crea una nueva versión (o sobrescribe, si el versionado está desactivado). Para «añadir», tenés que hacer `GetObject` del objeto completo, concatenar localmente y volver a hacer `PutObject`. Por eso las cargas de trabajo con muchas anexiones (logs, bases de datos, archivos WAL) pertenecen a EBS o EFS, y solo aterrizan en S3 una vez sellados. Es también por lo que los archivos de log particionados y rotados son el patrón estándar de logging en S3.

**A3.** No — hay exactamente **una** entidad almacenada, el objeto con clave `a/b/c/d/e.txt`. La prueba está en el paso 4: borrar ese único objeto dejó `KeyCount` en 0, y no quedó ningún `a/`, `a/b/` ni `a/b/c/`. El espacio de nombres de S3 es plano; los caracteres `/` son bytes corrientes dentro de la cadena de la clave. La consola dibuja un árbol de directorios agrupando por un delimitador (`ListObjectsV2 --delimiter /` devuelve `CommonPrefixes`), lo cual es presentación, no almacenamiento.

**A4.** **Almacenamiento de archivos → Amazon FSx for Windows File Server.** Los discriminadores son *Windows*, *acceso concurrente al mismo árbol* y *permisos de Active Directory*. EFS es solo NFS y no puede servir ACL de NTFS ni identidad de AD. EBS queda descartado porque un volumen de bloques no puede compartirse en lectura-escritura entre 40 clientes.

### Ejercicio 2 — Amazon S3

**A5.** S3 Standard almacena cada objeto de forma redundante en un **mínimo de tres zonas de disponibilidad** dentro de la región. Las dos clases que rompen esto son **S3 One Zone-IA** y **S3 Express One Zone**, que almacenan los datos en una **única AZ**. Ambas siguen teniendo 11 nueves de *durabilidad de diseño frente a fallos de dispositivo*, pero ninguna sobrevive a la destrucción de su AZ — por eso One Zone-IA solo es apropiada para datos recreables (miniaturas derivadas, copias secundarias de datos cuyo original está en otro sitio).

**A6.** Las dos opciones son **Suspended** y **Enabled**. No hay forma de volver al estado original *sin versionar* — esa es la opción que no está disponible. Una vez habilitado el versionado, el bucket es permanentemente consciente de versiones. Suspenderlo hace que S3 deje de asignar nuevos IDs de versión (los objetos nuevos reciben el ID de versión `null`), pero todas las versiones ya creadas siguen almacenadas y facturándose. Si de verdad necesitás un bucket sin versionar, creá uno nuevo y copiá.

**A7.** Porque el marcador de borrado solo *eclipsa* el objeto; no elimina ningún dato. Todas las versiones anteriores —la v1 de 16 bytes y la v2 de 26 bytes— permanecieron íntegramente almacenadas y facturadas, más el propio marcador de borrado como una versión adicional (insignificante). `GetObject` devolvió `NoSuchKey` porque resuelve a la versión actual, y la versión actual era el marcador de borrado. Este es exactamente el mecanismo detrás de la clásica factura desbocada de S3: un script de «limpieza» que borra millones de objetos en un bucket versionado, libera cero bytes y añade millones de marcadores de borrado.

**A8.**
- **Durabilidad** = la probabilidad de que los bytes almacenados no se pierdan. S3 Standard está *diseñado para* **99,999999999 %** (11 nueves) a lo largo de un año. Esto trata sobre la pérdida de datos.
- **Disponibilidad** = la probabilidad de que puedas alcanzar los datos con éxito ahora mismo. S3 Standard está *diseñado para* un **99,99 %** de disponibilidad, respaldado por un SLA de disponibilidad del **99,9 %** (el número del SLA es deliberadamente inferior al objetivo de diseño).

Son independientes: una interrupción de la API de S3 en toda una región deja los datos indisponibles mientras siguen siendo perfectamente duraderos. El examen ofrece con frecuencia 99,99 % como distractor de durabilidad.

**A9.** Block Public Access, como dice su nombre, restringe el acceso **público** — concesiones anónimas o con `Principal: "*"`. **No** restringe:
- entidades principales de IAM de tu propia cuenta con permisos `s3:*`;
- acceso entre cuentas concedido mediante una política de bucket a un ARN de cuenta o rol *específico* (esto no es «público»);
- URL prefirmadas, que llevan la firma de una entidad principal autorizada y funcionan independientemente de BPA;
- acceso mediante un S3 Access Point o una política de endpoint de VPC que conceda permiso a una entidad principal nombrada.

Así que BPA previene la legibilidad mundial accidental; no es un sistema de control de acceso. Seguís necesitando IAM de mínimo privilegio y políticas de bucket.

### Ejercicio 3 — Clases de almacenamiento y ciclo de vida

**A10.** S3 Standard-IA tiene un **tamaño mínimo facturable de objeto de 128 KB**. Cada miniatura de 40 KB se facturaría como 128 KB — una inflación de 3,2× de los bytes facturados. Además hay una **duración mínima de almacenamiento de 30 días** y una **tarifa de recuperación de $0.01/GB**.

Aritmética mensual aproximada para 10 M × 40 KB (≈ 400 GB reales):
- S3 Standard: 400 GB × $0.023 ≈ **$9.20**
- S3 Standard-IA: facturado como 10 M × 128 KB ≈ 1.280 GB × $0.0125 ≈ **$16.00**, más tarifas de recuperación, más el cargo por solicitud de transición por objeto (~$0.01 por 1.000 = **$100 de una sola vez** para 10 M de objetos).

La «optimización» casi duplica la factura recurrente y añade un cargo de transición de $100. **La alternativa correcta es S3 Intelligent-Tiering**, que **no tiene penalización por tamaño mínimo de objeto**, ni tarifa de recuperación, ni duración mínima — los objetos por debajo de 128 KB simplemente se quedan en el nivel Frequent Access y nunca se les cobra la tarifa de monitorización. Intelligent-Tiering es el valor por defecto seguro siempre que los tamaños de objeto sean pequeños o el acceso sea desconocido.

**A11.** **S3 Glacier Deep Archive.** Su recuperación Standard es **en menos de 12 horas**, lo que cumple exactamente el requisito, a aproximadamente **$0.00099/GB-mes** — el precio de almacenamiento más bajo de AWS. Glacier Flexible Retrieval es la respuesta *incorrecta* precisamente porque es **~3,6× más caro** ($0.0036/GB-mes) y estás pagando ese sobreprecio por una velocidad de recuperación (3–5 h Standard, 1–5 min Expedited) que el requisito de 12 horas no necesita. El razonamiento correcto es: elegí la clase *más lenta* que aun así cumpla el SLA declarado. La duración mínima de 180 días de Deep Archive es irrelevante frente a una retención de 7 años.

**A12.** **30 días.** S3 Standard-IA tiene una duración mínima de almacenamiento de 30 días. Borrar (o volver a hacer una transición) antes de eso te factura el periodo completo de 30 días de todos modos. La misma trampa a los 90 días tanto para Glacier Instant Retrieval como para Glacier Flexible Retrieval, y a los 180 días para Deep Archive. Por eso las reglas de ciclo de vida que mueven objetos por varias clases demasiado rápido pueden costar *más* que dejarlos en Standard.

**A13.** Son **iguales en latencia y durabilidad** — ambas ofrecen recuperación en milisegundos, ambas replican en ≥ 3 AZ, ambas tienen un tamaño mínimo facturable de 128 KB. Difieren en el **compromiso entre coste de almacenamiento y de recuperación**:

| | $/GB-mes de almacenamiento | $/GB de recuperación | Duración mín. |
|---|---|---|---|
| Standard-IA | 0.0125 | 0.01 | 30 días |
| Glacier Instant Retrieval | **0.004** | **0.03** | **90 días** |

Glacier IR es ~3× más barato de *almacenar* y ~3× más caro de *recuperar*. El punto de equilibrio es la frecuencia de acceso: Glacier IR gana cuando los objetos se leen aproximadamente **una vez por trimestre o menos**; Standard-IA gana cuando se leen aproximadamente cada mes. El eje es la **frecuencia de acceso**, no la latencia.

**A14.** **S3 Intelligent-Tiering.** Su cargo distintivo es una pequeña **tarifa de monitorización y automatización por objeto** (~$0.0025 por 1.000 objetos al mes) — es la única clase que cobra por la *observación* en lugar de solo por almacenamiento y solicitudes. A cambio, S3 mueve los objetos entre los niveles Frequent, Infrequent, Archive Instant Access y (opcionalmente) Archive/Deep Archive Access automáticamente, **sin tarifas de recuperación y sin duración mínima**. Como la tarifa de monitorización es por objeto, resulta antieconómica para buckets con cantidades enormes de objetos diminutos; AWS la exime para objetos menores de 128 KB, que se quedan en Frequent Access.

**A15.** En un bucket versionado, `Expiration` sobre una versión *actual* no borra datos — **añade un marcador de borrado** y convierte la versión que era actual en una versión no actual. Los 500 GB siguen almacenados y facturados; simplemente son invisibles para `ListObjectsV2` y `GetObject`. Te falta **`NoncurrentVersionExpiration`** (con `NoncurrentDays`), que es la regla que realmente recupera el espacio. Una regla de ciclo de vida completa para un bucket versionado necesita `Expiration`, `NoncurrentVersionExpiration`, `ExpiredObjectDeleteMarker: true` (para barrer los marcadores de borrado cuyas versiones ya no existen) y `AbortIncompleteMultipartUpload`.

### Ejercicio 4 — Amazon EBS

**A16.** La conexión falla con **`InvalidVolume.ZoneMismatch`**, exactamente como se demostró en el paso 6. Un volumen de EBS está ligado a una única zona de disponibilidad durante toda su vida y nunca puede conectarse cruzando esa frontera. El procedimiento correcto:

1. `aws ec2 create-snapshot --volume-id vol-xxx` (la instantánea se almacena en S3 y es **regional**);
2. `aws ec2 wait snapshot-completed`;
3. `aws ec2 create-volume --snapshot-id snap-xxx --availability-zone us-east-1b`;
4. `aws ec2 attach-volume` a la nueva instancia;
5. montar dentro del invitado.

Entre regiones es el mismo flujo insertando `aws ec2 copy-snapshot` entre los pasos 2 y 3. La lección arquitectónica: si este tiempo de recuperación es inaceptable, los datos no deberían haber estado en un volumen de EBS de una sola AZ — usá EFS, una instancia de RDS Multi-AZ o S3.

**A17.** Aproximadamente **1 TiB + (29 × 2 GiB) ≈ 1.058 GiB**, no 30 TiB. La primera instantánea captura todos los bloques asignados; cada instantánea posterior almacena **solo los bloques modificados desde la instantánea anterior** del mismo volumen, con los bloques sin cambios almacenados como referencias. El almacenamiento de instantáneas se factura sobre los bloques *únicos* retenidos en todo el conjunto de instantáneas. Dos matices que conviene conocer: las instantáneas de EBS están comprimidas, así que la cifra real suele ser menor, y solo se capturan los bloques *escritos*, así que un volumen de 1 TiB recién formateado que contenga 100 GiB de datos produce una instantánea muy inferior a 1 TiB.

**A18.** **Sí, completamente restaurable.** Cuando borrás una instantánea, AWS elimina solo los bloques referenciados *exclusivamente* por ella; cualquier bloque que siga necesitando una instantánea posterior se retiene y se reasigna a la siguiente instantánea de la cadena. Las instantáneas no son una cadena diferencial que se rompe si quitás un eslabón — la estructura incremental es un detalle de implementación invisible para la restauración. Toda instantánea se comporta como una imagen completa e independiente de un punto en el tiempo. Esto es precisamente lo que hace seguras las políticas de retención rotativa (conservar 7 diarias, 4 semanales, 12 mensuales).

**A19.** **`st1` (Throughput Optimized HDD).** Entrega hasta 500 MiB/s, cómodamente por encima de los 400 MiB/s requeridos, con acceso puramente secuencial, a aproximadamente **$0.045/GB-mes** — algo más de la mitad del precio de `gp3`. `gp3` es la elección equivocada por coste: 4 TiB de `gp3` a ~$0.08/GB-mes son unos $327/mes frente a unos $184 de `st1`, y estarías pagando por una capacidad de acceso aleatorio SSD que la carga de trabajo nunca usa. Las salvedades a enunciar: `st1` no puede ser volumen de arranque, su rendimiento se desploma bajo E/S aleatoria y usa un modelo de ráfaga basado en créditos, de modo que la línea base sostenida escala con el tamaño del volumen (4 TiB es lo bastante grande aquí). Si el rendimiento tuviera que superar los 500 MiB/s, `st1` quedaría fuera y `gp3` (hasta 1.000 MiB/s) volvería a entrar.

**A20.** **EBS Multi-Attach.** Soportado solo en **`io1` e `io2`** (incluido `io2` Block Express), hasta **16 instancias basadas en Nitro en la misma zona de disponibilidad**. El requisito crítico: **el SO invitado debe usar un sistema de archivos consciente del clúster** — GFS2, OCFS2, o una aplicación clusterizada sobre dispositivo crudo como Oracle RAC. Montar `ext4` o `xfs` desde dos instancias simultáneamente **corromperá el sistema de archivos**, porque cada kernel cachea los metadatos de forma independiente y ninguno es consciente de las escrituras del otro. Multi-Attach proporciona acceso de bloques compartido; **no** proporciona el bloqueo distribuido que el acceso compartido requiere. Cuando alguien pide «almacenamiento compartido» sin un sistema de archivos de clúster, la respuesta correcta es EFS o FSx, no Multi-Attach.

### Ejercicio 5 — Instance store

**A21.** **El archivo desapareció.** Los datos del instance store sobreviven a un *reinicio* pero no a un *stop/start*, porque detener la instancia la libera de su host físico; al arrancar se coloca en un host distinto con discos físicos distintos. No hay migración ni aviso. Además, el ahorro de coste era en parte ilusorio: la capacidad de instance store va incluida en el precio por hora de la instancia y no se factura por separado, así que detenerla solo ahorró el cargo de cómputo. El patrón correcto es EBS para cualquier cosa que deba sobrevivir a una detención, reservando el instance store para datos reconstruibles desde otra fuente.

**A22.** **No podés.** No existe API de instantáneas para instance store — `create-snapshot` acepta solo un ID de volumen de EBS. El instance store es NVMe local efímero sin ninguna capa de durabilidad gestionada por AWS. Tus opciones son todas a nivel de aplicación: replicar a otro nodo, escribir a un volumen de EBS, sincronizar a S3, o usar un servicio (AWS Backup, la propia replicación de una base de datos) que opere sobre datos que ya están en almacenamiento duradero. Si la pregunta insinúa «tomar una instantánea del instance store», la respuesta que se evalúa es que eso es imposible por diseño.

**A23.** El perfil correcto son **datos temporales de altas IOPS y baja latencia que sean reconstruibles**: espacio de búfer/temporal y tablas de trabajo de bases de datos, nodos de datos de Elasticsearch/OpenSearch con réplicas, desbordamiento de cachés en memoria, espacio de shuffle de MapReduce/Spark y espacio temporal de transcodificación de vídeo. La **precondición arquitectónica es que la durabilidad la proporcione la capa superior** — replicación entre nodos, una copia duradera en S3 o EBS, o la capacidad de reconstruir los datos desde el origen. El instance store es una elección legítima y a menudo correcta en producción; el error es usarlo *sin* esa precondición.

### Ejercicio 6 — EFS y FSx

**A24.** EFS es incorrecto por dos motivos independientes: habla **solo NFS v4.1** (Windows no tiene un cliente NFS soportado en producción para este patrón), y usa propiedad **POSIX** —UID/GID— así que no puede expresar ACL de NTFS ni mapear identidades de Active Directory. El servicio correcto es **Amazon FSx for Windows File Server**: SMB nativo, semántica NTFS, unión nativa a AD (AWS Managed Microsoft AD o tu AD autogestionado), instantáneas (shadow copies) de Windows y espacios de nombres DFS. Regla práctica: **NFS/Linux → EFS; SMB/Windows/AD → FSx for Windows File Server.**

**A25.** Dos causas probables:

1. **No hay destino de montaje en la AZ del cliente.** Un cliente de EFS debe alcanzar un destino de montaje, y un destino de montaje es una ENI en una subred concreta. Con solo un destino de montaje en `us-east-1a`, el cliente de `us-east-1b` no tiene endpoint que alcanzar (o se enruta entre AZ, incurriendo en cargos, si el enrutamiento siquiera lo permite). *Solución:* `aws efs create-mount-target` en una subred de `us-east-1b` — la mejor práctica es un destino de montaje por cada AZ que tenga clientes.
2. **El grupo de seguridad bloquea el TCP 2049.** El grupo de seguridad del destino de montaje debe permitir NFS entrante (2049) desde el grupo de seguridad o el CIDR del cliente. *Solución:* añadir esa regla de entrada. Un `mount` que se cuelga y luego agota el tiempo de espera —en lugar de fallar de inmediato— es la firma clásica de un paquete descartado (en vez de rechazado), es decir, un problema de grupo de seguridad o NACL.

Una tercera causa, menos común: la resolución DNS de `fs-xxx.efs.<region>.amazonaws.com` falla porque la VPC tiene `enableDnsHostnames`/`enableDnsSupport` deshabilitados.

**A26.** Cualquier carga de trabajo donde **varios nodos de cómputo deban leer y escribir el mismo árbol POSIX concurrentemente, con consistencia inmediata**. Ejemplos concretos: una flota de WordPress o Drupal detrás de un balanceador de carga compartiendo `wp-content/uploads`; una granja de runners de Jenkins o GitLab compartiendo un espacio de trabajo; volúmenes persistentes de contenedores que deben sobrevivir a la reprogramación de un pod a otro nodo u otra AZ; un pipeline científico donde la etapa 2 lee archivos que la etapa 1 todavía está produciendo.

S3 no puede sustituirlo porque no ofrece semántica POSIX, ni bloqueo de archivos, ni escrituras parciales — habría que reescribir la aplicación. EBS no puede sustituirlo porque un volumen se conecta a una instancia en una AZ. El sobreprecio compra el espacio de nombres compartido, multi-AZ y compatible con POSIX, y los niveles EFS Infrequent Access y Archive (unos $0.016 y $0.008/GB-mes) recuperan la mayor parte del coste para la mayoría fría de los datos.

**A27.** **Amazon FSx for Lustre**, con una **asociación de repositorio de datos de S3**. Lustre es un sistema de archivos paralelo construido específicamente para HPC: presenta los objetos del bucket de S3 vinculado como archivos en un espacio de nombres POSIX, carga de forma diferida el contenido de los objetos en el primer acceso, entrega latencia inferior al milisegundo y cientos de GB/s de rendimiento agregado escalando con la capacidad aprovisionada, y puede escribir los resultados de vuelta a S3. EFS es la respuesta equivocada a esta escala — su latencia y su rendimiento por cliente no están diseñados para un clúster de cómputo paralelo de 500 nodos. Las palabras clave del examen son **HPC, entrenamiento de machine learning, genómica, análisis sísmico, sub-milisegundo, «vinculado a S3»**.

**A28.** **Amazon FSx for NetApp ONTAP.** Expone un mismo conjunto de datos sobre **NFS (v3/v4.x), SMB e iSCSI** simultáneamente, con el conjunto completo de características de ONTAP — instantáneas, replicación SnapMirror, FlexClone, deduplicación, compresión y niveles automáticos de bloques fríos hacia almacenamiento de capacidad. Es la respuesta estándar para el lift-and-shift de un parque NetApp on-premises y para entornos mixtos Linux/Windows que deben compartir los mismos archivos. Ningún otro servicio de almacenamiento de AWS ofrece los tres protocolos sobre un mismo conjunto de datos.

### Ejercicio 7 — Híbrido y migración

**A29.** **AWS Snowball Edge** (varios dispositivos en paralelo), y luego una regla de ciclo de vida o una importación directa que deposite los datos en S3 Glacier.

El razonamiento es la aritmética. Suponiendo que los 200 Mbps completos estuvieran disponibles con un 80 % de eficiencia:

```
hours = (400 × 8 × 1e6) / (200 × 0.8 × 3600) = 5,556 h ≈ 231 days
```

Más de siete meses frente a un plazo de un mes — y eso asumiendo el enlace entero, que además transporta tráfico de producción, así que la cifra realista es mucho peor. Snowball Edge Storage Optimized alberga unos 80 TB utilizables, así que ~5–6 dispositivos pedidos en paralelo, cada uno con un viaje de ida y vuelta de aproximadamente una semana, completan la migración dentro del plazo consumiendo **cero** ancho de banda de internet. Snowmobile no es una opción — ha sido discontinuado. Los datos aterrizan en S3, y una regla de ciclo de vida (o la configuración de importación) los mueve a Glacier Flexible Retrieval o Deep Archive según el SLA de recuperación.

**A30.** **AWS Storage Gateway en modo Tape Gateway (VTL).** Presenta una **biblioteca virtual de cintas sobre iSCSI** —unidades de cinta virtuales y un cambiador de medios— que el software de backup existente (Veeam, Veritas NetBackup, Commvault, Backup Exec, Dell NetWorker) reconoce como hardware físico de cintas, habitualmente sin cambios en la aplicación. Las cintas virtuales se almacenan en S3; expulsar una cinta al estante virtual la archiva en **S3 Glacier Flexible Retrieval o Deep Archive**. Esta es la respuesta canónica a «retirar la biblioteca de cintas sin reemplazar el software de backup».

**A31.**
- **Volume Gateway — Cached:** el **conjunto de datos principal vive en S3**; solo los bloques de acceso frecuente se cachean en disco local. Usalo cuando tu conjunto de datos supere la capacidad local y quieras que AWS sea el sistema de referencia.
- **Volume Gateway — Stored:** el **conjunto de datos principal vive on-premises** con acceso local de baja latencia a *todo* él; el gateway replica asíncronamente copias puntuales en el tiempo hacia AWS como **instantáneas de EBS** para backup y DR. Usalo cuando cada byte deba ser rápido localmente y AWS sea el destino de la copia de seguridad.

Mnemotecnia: *Cached = capacidad en la nube. Stored = capacidad en el suelo.*

**A32.** **AWS Storage Gateway — S3 File Gateway.** Presenta localmente un recurso compartido **NFS o SMB** en el que la sucursal escribe sin cambios, y guarda cada archivo como un **objeto S3 nativo** en tu bucket, un archivo a un objeto, con la ruta del directorio convirtiéndose en el prefijo de la clave. Como los objetos son objetos S3 nativos (no un formato de backup opaco), las notificaciones de eventos de S3 pueden disparar una función Lambda con `s3:ObjectCreated:*` exactamente igual que si el archivo se hubiera subido por la API. DataSync también movería los datos, pero es un servicio de transferencia programada, no un recurso compartido montado de forma continua — no le da a la sucursal un punto de montaje NFS local en vivo.

**A33.** **AWS DataSync**, sin ambigüedad. El ancho de banda es de sobra: 2 TB por 10 Gbps con una eficiencia realista está muy por debajo de una hora, así que el razonamiento del envío físico que justifica Snowball nunca aplica. Además, este es un trabajo **nocturno recurrente**, y los dispositivos Snow son envíos puntuales. DataSync proporciona exactamente las características solicitadas: **verificación de integridad** integrada (sumas de comprobación durante la transferencia y verificación posterior opcional), **programación**, transferencia incremental solo de los datos cambiados, limitación de ancho de banda y soporte nativo de **EFS como destino** (Snowball importa a S3). La regla de decisión: *Snowball es para cuando el ancho de banda es la restricción. DataSync es para cuando no lo es.*

### Ejercicio 8 — AWS Backup

**A34.** AWS Backup orquesta los mecanismos nativos de cada servicio en lugar de reemplazarlos, y lo que añade es **gobernanza**:

- **Una política a través de muchos servicios** — EBS, EFS, RDS, Aurora, DynamoDB, FSx, Storage Gateway, S3, DocumentDB, Neptune, Redshift, VMware on-premises — en lugar de un programador por servicio, una Lambda o un cron para cada uno.
- **Selección de recursos dinámica y basada en etiquetas**, de modo que la protección sigue a una etiqueta y no a una lista de recursos mantenida a mano.
- **Gestión de ciclo de vida** — transición automática de los puntos de recuperación a almacenamiento en frío y su expiración — como política, no como scripting.
- **Copia entre regiones y entre cuentas** para DR y para aislar las copias de seguridad de una cuenta de producción comprometida.
- Inmutabilidad con **Vault Lock (WORM)**.
- **Backup Audit Manager** — informes de cumplimiento continuos frente a controles como «todo volumen etiquetado `prod` tiene una copia de seguridad de menos de 24 horas».
- Un **único flujo de restauración**, rastro de auditoría y conjunto de notificaciones de CloudWatch/EventBridge.

Formulación concisa: AWS Backup no inventa la copia de seguridad; hace que la copia de seguridad sea *gobernada, uniforme y demostrable*.

**A35.**
1. **AWS Backup Vault Lock en modo compliance.** Una vez transcurrido el periodo de gracia `changeable-for-days` (mínimo 3 días), el bloqueo es irreversible: los puntos de recuperación no pueden borrarse antes de que expire su retención y la retención no puede acortarse — **por nadie**, incluidos el usuario raíz de la cuenta y el soporte de AWS. Ni siquiera unas credenciales de administrador válidas pueden destruir las copias de seguridad.
2. **S3 Object Lock en modo compliance** (que requiere versionado del bucket). Las versiones de objeto quedan protegidas con WORM durante su periodo de retención; ninguna entidad principal puede borrarlas o sobrescribirlas, y el periodo de retención no puede acortarse.

El principio compartido es que ambos eliminan la capacidad destructiva del plano de control de IAM por completo, de modo que poseer credenciales no basta para destruir los datos. Complementos que vale la pena nombrar: **copia de seguridad entre cuentas** hacia una cuenta aislada, y **MFA Delete** en S3 (que exige credenciales MFA del usuario raíz para borrar una versión). Notá que el modo *governance* en ambos servicios es eludible por una entidad principal que posea un permiso específico — protege contra el accidente, no contra un atacante decidido con derechos de administrador.

**A36.** AWS Backup impone **`DeleteAfterDays` ≥ `MoveToColdStorageAfterDays` + 90**. Con almacenamiento en frío en el día 30, el `DeleteAfterDays` mínimo legal es **120**; 100 se rechaza con `InvalidParameterValueException`. La regla existe porque el almacenamiento en frío se apoya en los niveles Glacier, que llevan una **duración mínima de almacenamiento de 90 días** — borrar antes incurriría en un cargo por borrado anticipado por un almacenamiento que nunca usaste. AWS impone la restricción en el momento de crear el plan en lugar de sorprenderte en la factura. Es el mismo mínimo de 90 días del ejercicio 3, aflorando en otro servicio.

**A37.** La nueva instancia de RDS queda **protegida automáticamente** en la siguiente ejecución programada del plan, sin ningún cambio en la configuración de copias de seguridad. Las selecciones de copia de seguridad se evalúan dinámicamente en el momento del trabajo frente a las etiquetas actuales de los recursos, no se resuelven una sola vez en una lista estática.

Este es el punto de diseño porque, de lo contrario, la cobertura de copias de seguridad se degrada exactamente como siempre lo ha hecho: alguien aprovisiona un recurso, se olvida de registrarlo en el sistema de backup, y el hueco se descubre durante una restauración. Ligar la política a una etiqueta invierte el valor por defecto —un recurso está protegido salvo que alguien quite activamente la etiqueta— y hace que la cobertura sea auditable como una única pregunta («¿está etiquetado todo recurso de producción?») en lugar de una reconciliación de inventario recurso por recurso. Backup Audit Manager puede entonces imponer esa pregunta como control continuo.

### Ejercicio 9 — Diagnósticos

**A38.** Los 860 GB están en almacenamiento que `ListObjectsV2` (y por tanto `aws s3 ls`) no enumera:

1. **Versiones de objeto no actuales** — cada sobrescritura en un bucket versionado retiene los bytes anteriores.
   `aws s3api list-object-versions --bucket B --query 'length(Versions[?IsLatest==`false`])'`
   Para el total de bytes: `aws s3api list-object-versions --bucket B --query 'sum(Versions[?IsLatest==\`false\`].Size)'`
2. **Cargas multiparte incompletas** — las partes de subidas fallidas o abandonadas se facturan indefinidamente y nunca aparecen en ningún listado de objetos.
   `aws s3api list-multipart-uploads --bucket B`, y después `aws s3api list-parts --bucket B --key K --upload-id U` para los tamaños.
3. **Marcadores de borrado y las versiones que eclipsan** — objetos «borrados» en un bucket versionado.
   `aws s3api list-object-versions --bucket B --query 'length(DeleteMarkers)'`

La herramienta para toda la cuenta y para los tres a la vez es **S3 Storage Lens**, cuyo panel gratuito por defecto informa de los bytes de versiones no actuales y de los bytes de cargas multiparte incompletas por bucket; **S3 Inventory** produce los mismos datos como un manifiesto CSV/Parquet programado para buckets grandes donde la API `list-object-versions` sería demasiado lenta. Las soluciones son las reglas de ciclo de vida del ejercicio 3: `NoncurrentVersionExpiration`, `AbortIncompleteMultipartUpload` y `ExpiredObjectDeleteMarker`.

**A39.** **No — ese es el comportamiento correcto y esperado.** `BurstBalance` se publica solo para los tipos de volumen con un modelo de ráfaga basado en créditos: `gp2`, `st1` y `sc1`. `gp3` **no tiene mecanismo de ráfaga alguno**; entrega sus IOPS y rendimiento aprovisionados (3.000 IOPS y 125 MiB/s de línea base, configurables de forma independiente hasta 16.000 IOPS y 1.000 MiB/s) de manera continua y determinista. La ausencia de la métrica es una señal positiva: el volumen no puede sufrir el precipicio de agotamiento de créditos donde un volumen `gp2` va rápido durante horas y luego cae abruptamente a su línea base. Esta previsibilidad, más un coste por GB aproximadamente un 20 % menor, es la razón por la que `gp3` es la recomendación por defecto frente a `gp2`.

**A40.** El volumen no es el cuello de botella, así que mirá **por encima y al lado de él**:

1. **Límites de EBS a nivel de instancia.** Cada tipo de instancia EC2 tiene su propio techo de ancho de banda e IOPS de EBS, independiente del del volumen. Comprobá `EBSIOBalance%` y `EBSByteBalance%` en el espacio de nombres `AWS/EC2` en instancias Nitro — un valor tendiendo a 0 % significa que es la *instancia* la que está limitando. Un volumen de 16.000 IOPS en una instancia topada en 6.000 nunca superará las 6.000, y las métricas de volumen de `AWS/EBS` no mostrarán limitación alguna. *Solución:* pasar a un tipo de instancia mayor o EBS-optimized.
2. **Tamaño de E/S, no número de E/S.** EBS mide las IOPS en unidades de 256 KiB para volúmenes SSD; una carga que emite solicitudes de 1 MiB consume 4 IOPS por solicitud. `VolumeReadOps` bajo con `%util` saturado y `VolumeReadBytes` alto significa que estás alcanzando el techo de **rendimiento**, no el de IOPS. Comprobá `VolumeReadBytes`/`VolumeWriteBytes` frente a los MiB/s aprovisionados y `--throughput` en un `gp3`.
3. **Latencia, no saturación.** Calculá la latencia media como `VolumeTotalReadTime / VolumeReadOps`. Latencia alta por operación con una cola corta apunta al patrón de acceso de la carga de trabajo —E/S síncrona, de un solo hilo y con muchos fsync, por ejemplo— más que a la capacidad del dispositivo. El `await` frente a `svctm` de `iostat -xz`, y un `%util` llegando al 100 % con una profundidad de cola de 1, cuentan la misma historia.
4. **No es almacenamiento en absoluto.** Un `%util` del 100 % en NVMe es una señal notoriamente poco fiable (mide el tiempo con al menos una solicitud pendiente, que se satura en dispositivos paralelos mucho antes que la capacidad). Confirmá con la profundidad de cola de `iostat` y la latencia a nivel de aplicación antes de concluir que es el disco. El robo de CPU (steal), la presión de memoria que provoca swap, o la latencia de red hacia una dependencia se presentan todos como «la base de datos va lenta».

**A41.** El orden es:

1. **Block Public Access** — nivel de cuenta, luego nivel de bucket. Los ajustes a nivel de cuenta prevalecen y no pueden relajarse por bucket.
2. **Política de bucket** — un `Deny` explícito aquí (como la condición `aws:SecureTransport` del ejercicio 2) termina la evaluación de inmediato.
3. **Política de identidad de IAM** de la entidad principal que llama (más cualquier **SCP** de AWS Organizations, y cualquier **límite de permisos** o **política de sesión**).
4. **Propiedad de objetos / ACL** — relevante solo si `ObjectOwnership` no es `BucketOwnerEnforced`; cuando lo es, las ACL están deshabilitadas y esta capa no existe.

Después, y solo una vez concedido el acceso: **política de clave de KMS** si el objeto está cifrado con SSE-KMS (una causa común de `AccessDenied` en `GetObject` donde todas las políticas de S3 son correctas pero al llamante le falta `kms:Decrypt`), y **política de endpoint de VPC** si la solicitud atraviesa un endpoint de puerta de enlace o de interfaz.

La regla que hace que el orden importe es la lógica de evaluación de IAM: **un `Deny` explícito en cualquier política prevalece sobre todo `Allow`, y el acceso requiere un `Allow` explícito sin ningún `Deny` coincidente.** Comprobar desde la denegación más externa y amplia hacia adentro encuentra la causa más rápido — y explica por qué añadir permisos frecuentemente no arregla un 403: el problema es un `Deny` en algún sitio, no un `Allow` que falta. La herramienta sistemática para esto es el **IAM Policy Simulator** o `aws iam simulate-principal-policy`, que evalúa la cadena completa y nombra la declaración decisiva.

### Ejercicio 10 — Limpieza

**A42.** `aws s3 rb --force` ejecuta `aws s3 rm --recursive` por debajo, que usa `ListObjectsV2` y `DeleteObject` **sin IDs de versión**. En un bucket versionado, un `DeleteObject` sin versión no elimina nada — añade un **marcador de borrado**. Así que el comando «borra» diligentemente todos los objetos actuales, crea un marcador de borrado para cada uno, no elimina nada, y luego falla al borrar el bucket porque S3 se niega a borrar un bucket que todavía contiene versiones (`BucketNotEmpty`).

Lo que esto revela: **S3 contabiliza el almacenamiento a nivel de versión, no de clave.** Una clave es meramente un índice hacia una pila de versiones; `List`/`Get`/`Delete` sin ID de versión operan sobre la cima de esa pila, mientras que la facturación opera sobre toda la pila. Vaciar un bucket versionado requiere enumerar con `list-object-versions` y borrar cada par `(Key, VersionId)` explícitamente, incluidos los marcadores de borrado — que es exactamente lo que hace el script de limpieza. La misma asimetría es la causa raíz de A7, A15 y A38.

**A43.** Un **destino de montaje es una interfaz de red elástica (ENI) con una dirección IP privada dentro de una de tus subredes** — es un recurso en *tu* VPC, no meramente una propiedad del sistema de archivos. Borrar el sistema de archivos mientras existe una ENI dejaría huérfana una interfaz de red que ocupa una IP en tu subred y, potencialmente, una sesión NFS activa, así que EFS impone el orden de dependencia: primero los destinos de montaje, después el sistema de archivos.

El punto arquitectónico detrás del mensaje de error: el sistema de archivos en sí es una construcción regional y multi-AZ, pero **el acceso a él es siempre zonal**, mediado por una ENI por AZ sujeta a los grupos de seguridad, tablas de rutas y NACL de tu VPC. Por eso el tráfico NFS hacia EFS se controla con grupos de seguridad en el puerto 2049 como cualquier otro tráfico de VPC, por eso la falta de un destino de montaje en una AZ hace que el sistema de archivos sea inalcanzable desde esa AZ (A25), y por eso el acceso a EFS nunca sale de tu VPC.

</details>

---

## Fuentes oficiales

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon S3 — Using Amazon S3 storage classes — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- Amazon S3 — Managing the lifecycle of objects — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html>
- Amazon S3 — Lifecycle transition general considerations — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html>
- Amazon S3 — Blocking public access to your Amazon S3 storage — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html>
- Amazon S3 — Using S3 Object Lock — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html>
- Amazon S3 — Assessing storage activity with S3 Storage Lens — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage_lens.html>
- Amazon EBS — Amazon EBS volume types — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html>
- Amazon EBS — Amazon EBS snapshots — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-snapshots.html>
- Amazon EBS — Attach a volume to multiple instances with Multi-Attach — <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html>
- Amazon EC2 — Instance store temporary block storage — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html>
- Amazon EFS — Amazon EFS performance — <https://docs.aws.amazon.com/efs/latest/ug/performance.html>
- Amazon EFS — Managing storage with lifecycle policies — <https://docs.aws.amazon.com/efs/latest/ug/lifecycle-management-efs.html>
- Amazon FSx — What is Amazon FSx? — <https://docs.aws.amazon.com/fsx/>
- AWS Storage Gateway — What is AWS Storage Gateway? — <https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html>
- AWS Snow Family — What is the AWS Snow Family? — <https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html>
- AWS DataSync — What is AWS DataSync? — <https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html>
- AWS Backup — What is AWS Backup? — <https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html>
- AWS Backup — AWS Backup Vault Lock — <https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html>
- Amazon CloudWatch — Amazon EBS CloudWatch metrics — <https://docs.aws.amazon.com/ebs/latest/userguide/using_cloudwatch_ebs.html>
- Amazon S3 pricing — <https://aws.amazon.com/s3/pricing/>
- Amazon EBS pricing — <https://aws.amazon.com/ebs/pricing/>