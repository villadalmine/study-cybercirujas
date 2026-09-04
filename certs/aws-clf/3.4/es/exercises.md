# Tema 3.4 — Identificar los servicios de bases de datos de AWS
## Ejercicios guiados (nivel producción)

**Certificación:** AWS Certified Cloud Practitioner — CLF-C02 (v1.0)
**Dominio 3:** Tecnología y servicios de la nube · **Tarea 3.4:** Identificar los servicios de bases de datos de AWS
**Peso en el examen:** 4,25 %

---

### Lo que vas a poder hacer realmente al terminar

No "recitar que DynamoDB es NoSQL". Vas a poder pararte frente a un pizarrón y defender una elección: *por qué* una carga de trabajo pertenece a Aurora y no a RDS for PostgreSQL, *por qué* una lectura fuertemente consistente en DynamoDB cuesta el doble que una eventualmente consistente, *dónde* cae la línea de responsabilidad compartida cuando movés una base de datos de EC2 a RDS y de RDS a DynamoDB, y *qué* protege y qué no protege un failover de RDS Multi-AZ.

---

## ⚠️ Leé esto antes de teclear nada

Estos ejercicios crean recursos facturables. Los bloques están etiquetados:

| Etiqueta | Significado |
|---|---|
| 🟢 **GRATIS** | Llamadas de solo lectura a la API, o contenedores locales. Sin cargo. |
| 🟡 **BARATO** | Unos centavos a ~US$1 si lo desmontás el mismo día. |
| 🔴 **CARO** | Dólares por hora. De solo lectura por defecto; creá solo si es a propósito. |

Cada bloque de creación tiene su desmontaje correspondiente en el **Ejercicio 9**. Hacé el Ejercicio 9. Los snapshots huérfanos de RDS, las Elastic IP sin usar y los workgroups de Redshift ociosos son las tres maneras clásicas en que una cuenta de laboratorio te factura calladita durante un mes.

Los precios citados abajo son ilustrativos para `us-east-1` y cambian. Confirmá siempre en <https://aws.amazon.com/rds/pricing/> y <https://aws.amazon.com/dynamodb/pricing/>.

---

## Ejercicio 0 — Primero las barreras de protección 🟢 GRATIS

Una persona de ingeniería en producción define el radio de impacto antes de abrir la herramienta. Hacé lo mismo acá.

1. Confirmá que tu CLI es v2 y lo bastante reciente como para conocer las APIs de bases de datos más nuevas:

```bash
aws --version
```

Forma esperada:

```
aws-cli/2.17.42 Python/3.11.9 linux/6.8.0 exe/x86_64.x86_64
```

2. Confirmá *quién* sos y *dónde* estás. La región importa: la disponibilidad de servicios de bases de datos no es uniforme.

```bash
aws sts get-caller-identity
aws configure get region
```

```json
{
    "UserId": "AIDA...EXAMPLE",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/clf-lab"
}
```

```
us-east-1
```

3. Fijá la región para toda esta sesión para que ningún comando aterrice en silencio en otro lado:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
```

4. Creá una alarma de presupuesto firme antes de crear una sola base de datos. Reemplazá el e-mail:

```bash
cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "clf34-lab-guard",
  "BudgetLimit": { "Amount": "10", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

cat > /tmp/notify.json <<'JSON'
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 50,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [
      { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
    ]
  }
]
JSON

aws budgets create-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

Una llamada exitosa devuelve un cuerpo vacío (HTTP 200, sin salida). Verificá:

```bash
aws budgets describe-budgets \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
```

```
------------------------------
|      DescribeBudgets       |
+-----------------+----------+
|      Name       |  Limit   |
+-----------------+----------+
|  clf34-lab-guard|  10.0    |
+-----------------+----------+
```

5. Anotá la VPC por defecto y dos subredes en zonas de disponibilidad distintas — las vas a necesitar para RDS:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
echo "VPC: $VPC_ID"

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone}' --output table
```

```
--------------------------------------------
|              DescribeSubnets             |
+---------------+--------------------------+
|      AZ       |         Subnet           |
+---------------+--------------------------+
|  us-east-1a   |  subnet-0aa11bb22cc33dd44 |
|  us-east-1b   |  subnet-0ee55ff66gg77hh88 |
|  us-east-1c   |  subnet-0ii99jj00kk11ll22 |
+---------------+--------------------------+
```

> **Nota sobre `describe-budgets`:** AWS Budgets es un servicio global (de facturación). Si la llamada falla con `AccessDeniedException`, a tu principal de IAM le faltan permisos `budgets:*` — eso es un problema de IAM, no de región.

### ✅ Chequeo de comprensión — Bloque 0

**Q0.1** — Budgets y Cost Explorer son servicios de facturación con endpoint *global*, y sin embargo exportaste `AWS_REGION=us-east-1`. ¿Por qué sigue importando esa exportación de región para el resto del laboratorio?

**Q0.2** — Creaste un presupuesto con una notificación `ACTUAL > 50 %`. ¿Esa notificación impide que AWS te cobre más allá de US$10? ¿Cuál es el mecanismo real que provee un presupuesto, y qué necesitarías para *forzar* una detención?

**Q0.3** — ¿Por qué un DB subnet group de RDS exige subredes en **al menos dos** zonas de disponibilidad, incluso si pensás desplegar una instancia Single-AZ?

---

## Ejercicio 1 — Mapear la superficie relacional: lo que RDS ofrece realmente 🟢 GRATIS

Antes de aprovisionar nada, aprendé a leer el catálogo desde la API en vez de desde una diapositiva.

1. Listá todas las familias de motores que RDS puede administrar:

```bash
aws rds describe-db-engine-versions \
  --query 'DBEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u
```

```
aurora-mysql
aurora-postgresql
custom-oracle-ee
db2-ae
db2-se
mariadb
mysql
oracle-ee
oracle-se2
postgres
sqlserver-ee
sqlserver-ex
sqlserver-se
sqlserver-web
```

2. Separá las dos líneas de producto escondidas en esa lista. Todo lo que empieza con `aurora-` es **Amazon Aurora**; el resto es **Amazon RDS** ejecutando el motor comunitario o del proveedor. Contalos:

```bash
aws rds describe-db-engine-versions \
  --query 'DBEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u \
  | awk '/^aurora-/ {a++; next} /^custom-/ {c++; next} {r++} END {print "Aurora:",a," RDS Custom:",c," RDS standard:",r}'
```

```
Aurora: 2  RDS Custom: 1  RDS standard: 11
```

3. Encontrá la versión de MySQL por defecto más nueva — esto es lo que vas a aprovisionar:

```bash
aws rds describe-db-engine-versions --engine mysql \
  --query 'DBEngineVersions[?DBEngineVersionDescription!=null].EngineVersion' \
  --output text | tr '\t' '\n' | sort -V | tail -3
```

```
8.0.39
8.0.40
8.4.3
```

4. Preguntá qué clases de instancia son realmente ordenables para ese motor en tu región, y cuáles de ellas soportan Multi-AZ. Esta es la consulta que te salva de un `create-db-instance` fallido veinte minutos adentro de una ventana de cambios:

```bash
aws rds describe-orderable-db-instance-options \
  --engine mysql --engine-version 8.0.40 \
  --query 'OrderableDBInstanceOptions[?MultiAZCapable==`true`].DBInstanceClass' \
  --output text | tr '\t' '\n' | sort -u | head -8
```

```
db.m5.2xlarge
db.m5.large
db.m5.xlarge
db.m6g.large
db.r6g.large
db.t3.medium
db.t4g.micro
db.t4g.small
```

5. Ahora mirá la misma pregunta para un motor de proveedor con restricciones de licenciamiento:

```bash
aws rds describe-orderable-db-instance-options \
  --engine oracle-se2 \
  --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Class:DBInstanceClass,License:LicenseModel,MultiAZ:MultiAZCapable}' \
  --output table
```

```
--------------------------------------------------------------
|             DescribeOrderableDBInstanceOptions              |
+-------------+--------------+---------------------+----------+
|    Class    |    Engine    |       License       | MultiAZ  |
+-------------+--------------+---------------------+----------+
|  db.m5.large|  oracle-se2  |  license-included   |  True    |
+-------------+--------------+---------------------+----------+
```

6. Inspeccioná dónde se ubica la línea de responsabilidad. Preguntale a RDS qué *no* te va a dejar hacer — listá los parámetros que podés cambiar en un parameter group de MySQL 8.0:

```bash
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.0 \
  --query 'EngineDefaults.Parameters[?IsModifiable==`false`].ParameterName' \
  --output text | tr '\t' '\n' | head -10
```

```
allow-suspicious-udfs
auto_generate_certs
basedir
bind_address
character_sets_dir
datadir
default_authentication_plugin
innodb_data_home_dir
innodb_log_group_home_dir
lc_messages_dir
```

Cada uno de esos es una ruta del sistema de archivos o un switch a nivel de proceso. Eso es el modelo de responsabilidad compartida expresado como API: AWS es dueño del host, del sistema operativo y del directorio de datos; vos sos dueño del esquema, las consultas, los índices, los usuarios y los parámetros que les dan forma.

**Fuentes:**
- Amazon RDS User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html>
- Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>
- RDS Custom — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-custom.html>

### ✅ Chequeo de comprensión — Bloque 1

**Q1.1** — `custom-oracle-ee` apareció en la lista de motores. ¿Qué te da **RDS Custom** que no te da RDS estándar, y qué resignás a cambio?

**Q1.2** — El paso 6 mostró `datadir` y `innodb_data_home_dir` como no modificables. Traducí eso al lenguaje de la responsabilidad compartida: nombrá dos tareas que AWS realiza para una instancia RDS MySQL y que harías vos mismo si MySQL corriera en una instancia EC2.

**Q1.3** — La opción de Oracle reportó `license-included`. ¿Cuál es el modelo de licenciamiento alternativo en RDS, y en qué situación lo elegiría una empresa?

**Q1.4** — `db.t4g.micro` y `db.r6g.large` aparecen ambas como capaces de Multi-AZ. ¿Qué señalan las letras `t`, `m` y `r` sobre la familia de instancia, y cuál elegirías para una réplica de reportes hambrienta de memoria?

---

## Ejercicio 2 — Aprovisionar RDS Multi-AZ y leer su anatomía 🟡 BARATO

> **Costo:** una instancia MySQL Multi-AZ `db.t4g.micro` con 20 GiB gp3 cuesta aproximadamente **US$0,05–0,07/hora** más almacenamiento. Menos de US$1 si la desmontás el mismo día. La capa gratuita cubre únicamente `db.t4g.micro` en *Single-AZ* — Multi-AZ duplica el cargo de instancia.

1. Creá un DB subnet group que abarque dos AZ (sustituí los IDs de subred del Ejercicio 0):

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name clf34-subnets \
  --db-subnet-group-description "CLF-C02 task 3.4 lab" \
  --subnet-ids subnet-0aa11bb22cc33dd44 subnet-0ee55ff66gg77hh88 \
  --query 'DBSubnetGroup.{Name:DBSubnetGroupName,VPC:VpcId,AZs:Subnets[].SubnetAvailabilityZone.Name}'
```

```json
{
    "Name": "clf34-subnets",
    "VPC": "vpc-0abc123def4567890",
    "AZs": [ "us-east-1a", "us-east-1b" ]
}
```

2. Creá un security group que no otorgue **nada**. Una base de datos alcanzable desde internet es un hallazgo de auditoría, no un atajo de laboratorio:

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name clf34-db-sg \
  --description "CLF 3.4 lab - no ingress by design" \
  --vpc-id "$VPC_ID" --query GroupId --output text)
echo "SG: $SG_ID"
```

3. Aprovisioná la instancia. Leé cada flag antes de apretar Enter — cada uno es un concepto de examen:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-mysql \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version 8.0.40 \
  --allocated-storage 20 \
  --storage-type gp3 \
  --master-username admin \
  --manage-master-user-password \
  --db-subnet-group-name clf34-subnets \
  --vpc-security-group-ids "$SG_ID" \
  --multi-az \
  --no-publicly-accessible \
  --storage-encrypted \
  --backup-retention-period 7 \
  --preferred-backup-window 07:00-08:00 \
  --preferred-maintenance-window Sun:09:00-Sun:10:00 \
  --deletion-protection \
  --copy-tags-to-snapshot \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,Encrypted:StorageEncrypted}'
```

```json
{
    "Id": "clf34-mysql",
    "Status": "creating",
    "MultiAZ": true,
    "Encrypted": true
}
```

4. Esperá. La creación Multi-AZ lleva unos 10–15 minutos porque AWS construye dos instancias y las sincroniza:

```bash
time aws rds wait db-instance-available --db-instance-identifier clf34-mysql
```

```
real    11m48.302s
```

5. Leé la anatomía de lo que construiste:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Port:Endpoint.Port,PrimaryAZ:AvailabilityZone,StandbyAZ:SecondaryAvailabilityZone,MultiAZ:MultiAZ,Class:DBInstanceClass,Backup:BackupRetentionPeriod,SecretArn:MasterUserSecret.SecretArn}' \
  --output json
```

```json
{
    "Endpoint": "clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Port": 3306,
    "PrimaryAZ": "us-east-1a",
    "StandbyAZ": "us-east-1b",
    "MultiAZ": true,
    "Class": "db.t4g.micro",
    "Backup": 7,
    "SecretArn": "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-1a2b3c4d-AbCdEf"
}
```

Fijate: **un endpoint, dos AZ**. El standby no tiene endpoint propio y no sirve tráfico. Fijate también que `--manage-master-user-password` produjo un ARN de Secrets Manager — la contraseña nunca se tecleó, nunca aterrizó en el historial de tu shell, y rota según una programación.

6. Observá el mecanismo de failover. Forzá uno y mirá cómo se intercambia la AZ:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].AvailabilityZone' --output text

aws rds reboot-db-instance \
  --db-instance-identifier clf34-mysql --force-failover \
  --query 'DBInstance.DBInstanceStatus' --output text

aws rds wait db-instance-available --db-instance-identifier clf34-mysql

aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].{AZ:AvailabilityZone,Standby:SecondaryAvailabilityZone}' --output json
```

```
us-east-1a
rebooting
```
```json
{
    "AZ": "us-east-1b",
    "Standby": "us-east-1a"
}
```

7. Confirmá que el nombre DNS del endpoint **no** cambió:

```bash
aws rds describe-db-instances --db-instance-identifier clf34-mysql \
  --query 'DBInstances[0].Endpoint.Address' --output text
```

```
clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com
```

Mismo nombre, AZ nueva, host subyacente nuevo. RDS reapuntó el CNAME de DNS. Las aplicaciones se reconectan; no se reconfiguran.

8. Confirmá que AWS registró el failover como un evento:

```bash
aws rds describe-events \
  --source-identifier clf34-mysql --source-type db-instance \
  --duration 30 --query 'Events[].{At:Date,Msg:Message}' --output table
```

```
--------------------------------------------------------------------------------------
|                                   DescribeEvents                                   |
+----------------------------+-------------------------------------------------------+
|             At             |                         Msg                           |
+----------------------------+-------------------------------------------------------+
|  2026-09-04T14:02:11.421Z  |  Multi-AZ instance failover started.                  |
|  2026-09-04T14:03:38.907Z  |  DB instance restarted                                |
|  2026-09-04T14:03:41.115Z  |  Multi-AZ instance failover completed                 |
+----------------------------+-------------------------------------------------------+
```

9. Agregá una **read replica** — un mecanismo completamente distinto, para un problema distinto:

```bash
aws rds create-db-instance-read-replica \
  --db-instance-identifier clf34-mysql-ro \
  --source-db-instance-identifier clf34-mysql \
  --db-instance-class db.t4g.micro \
  --no-publicly-accessible \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Source:ReadReplicaSourceDBInstanceIdentifier}'
```

```json
{
    "Id": "clf34-mysql-ro",
    "Status": "creating",
    "Source": "clf34-mysql"
}
```

10. Una vez disponible, compará los dos objetos lado a lado:

```bash
aws rds wait db-instance-available --db-instance-identifier clf34-mysql-ro

aws rds describe-db-instances \
  --query 'DBInstances[?starts_with(DBInstanceIdentifier,`clf34-mysql`)].{Id:DBInstanceIdentifier,Endpoint:Endpoint.Address,MultiAZ:MultiAZ,Replica:ReadReplicaSourceDBInstanceIdentifier}' \
  --output table
```

```
-------------------------------------------------------------------------------------------------------
|                                        DescribeDBInstances                                          |
+------------------------------------------------------------+-----------------+----------+-----------+
|                          Endpoint                           |       Id        | MultiAZ  | Replica   |
+------------------------------------------------------------+-----------------+----------+-----------+
|  clf34-mysql.cabcd1efghij.us-east-1.rds.amazonaws.com       |  clf34-mysql    |  True    |  None     |
|  clf34-mysql-ro.cabcd1efghij.us-east-1.rds.amazonaws.com    |  clf34-mysql-ro |  False   | clf34-mysql|
+------------------------------------------------------------+-----------------+----------+-----------+
|
```

**La distinción que evalúa el examen:** el standby es invisible y síncrono (alta disponibilidad). La read replica tiene su propio endpoint y es asíncrona (escalado de lecturas). Resuelven problemas distintos y podés, y con frecuencia deberías, correr los dos.

11. Inspeccioná la capa de backups. Los backups automatizados y los snapshots manuales no son el mismo objeto:

```bash
aws rds describe-db-instance-automated-backups \
  --db-instance-identifier clf34-mysql \
  --query 'DBInstanceAutomatedBackups[0].{Retention:BackupRetentionPeriod,EarliestRestore:RestoreWindow.EarliestTime,LatestRestore:RestoreWindow.LatestTime}'
```

```json
{
    "Retention": 7,
    "EarliestRestore": "2026-09-04T14:21:00+00:00",
    "LatestRestore": "2026-09-04T14:47:00+00:00"
}
```

12. Tomá un snapshot manual y notá que no tiene período de retención alguno:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier clf34-mysql \
  --db-snapshot-identifier clf34-mysql-manual-01 \
  --query 'DBSnapshot.{Id:DBSnapshotIdentifier,Type:SnapshotType,Status:Status}'
```

```json
{
    "Id": "clf34-mysql-manual-01",
    "Type": "manual",
    "Status": "creating"
}
```

**Fuentes:**
- Multi-AZ deployments — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html>
- Read replicas — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html>
- Automated backups & PITR — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html>
- Master user password management — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html>

### ✅ Chequeo de comprensión — Bloque 2

**Q2.1** — En el paso 5 el standby en `us-east-1b` no tenía endpoint. Tu CTO pregunta: "estamos pagando por dos instancias — ¿podemos mandar consultas de reportes al standby?". Respondé, y nombrá la funcionalidad correcta del servicio para ese requerimiento.

**Q2.2** — Después del failover forzado el nombre DNS del endpoint quedó igual. Explicá el mecanismo, y explicá por qué una aplicación con un TTL de caché DNS de JVM muy largo podría igualmente fallar durante minutos después de un failover exitoso.

**Q2.3** — Un despliegue Multi-AZ replica de forma **síncrona**; una read replica replica de forma **asíncrona**. Enunciá la consecuencia de cada uno para (a) la pérdida de datos ante una falla y (b) la latencia de consultas en el primario.

**Q2.4** — Configuraste `--backup-retention-period 7`. Alguien de desarrollo borra una tabla a las 14:32 y lo reporta a las 15:10. ¿Qué mecanismo de recuperación usás, cuál es la granularidad más fina a la que podés restaurar, y la restauración sobrescribe `clf34-mysql`?

**Q2.5** — Los backups automatizados se borran cuando borrás la instancia (salvo que los retengas); los snapshots manuales no. ¿Cuál de los dos es el riesgo de costo en una cuenta de laboratorio, y por qué?

**Q2.6** — Multi-AZ protege contra una falla de AZ. Nombrá dos modos de falla contra los que **no** protege, y la funcionalidad de AWS que atiende cada uno.

---

## Ejercicio 3 — Aurora: el mismo SQL, otra máquina por debajo 🟡 BARATO

> **Costo:** Aurora Serverless v2 con un mínimo de 0,5 ACU cuesta aproximadamente **US$0,06/hora** más almacenamiento y E/S. Desmontalo el mismo día.

Aurora **no** es "RDS con una instancia más grande". Reemplaza el motor de almacenamiento por una capa distribuida y estructurada como log, construida a propósito, y divide el modelo de objetos: un **cluster** es dueño del almacenamiento; las **instancias** son cómputo que se conecta a él.

1. Creá el cluster. Notá que no hay `--allocated-storage`: el almacenamiento de Aurora crece automáticamente en incrementos de 10 GiB hasta 128 TiB.

```bash
aws rds create-db-cluster \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --engine-version 16.4 \
  --master-username postgres \
  --manage-master-user-password \
  --db-subnet-group-name clf34-subnets \
  --vpc-security-group-ids "$SG_ID" \
  --storage-encrypted \
  --backup-retention-period 7 \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4 \
  --tags Key=Project,Value=clf34-lab \
  --query 'DBCluster.{Id:DBClusterIdentifier,Status:Status,Engine:Engine,Storage:StorageType}'
```

```json
{
    "Id": "clf34-aurora",
    "Status": "creating",
    "Engine": "aurora-postgresql",
    "Storage": "aurora"
}
```

2. Notá que el cluster por sí solo es inútil — tiene endpoints pero nada que los sirva. Conectale una instancia writer:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-aurora-1 \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --db-instance-class db.serverless \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Class:DBInstanceClass,Cluster:DBClusterIdentifier}'
```

```json
{
    "Id": "clf34-aurora-1",
    "Class": "db.serverless",
    "Cluster": "clf34-aurora"
}
```

3. Agregá un reader en una segunda AZ. En Aurora esto *no* es una copia de los datos — se conecta al **mismo** volumen de almacenamiento compartido:

```bash
aws rds create-db-instance \
  --db-instance-identifier clf34-aurora-2 \
  --db-cluster-identifier clf34-aurora \
  --engine aurora-postgresql \
  --db-instance-class db.serverless \
  --promotion-tier 1 \
  --query 'DBInstance.DBInstanceIdentifier' --output text
```

```
clf34-aurora-2
```

4. Esperá, y después leé el modelo de endpoints — este es el dato de Aurora más evaluable de todos:

```bash
aws rds wait db-instance-available --db-instance-identifier clf34-aurora-1
aws rds wait db-instance-available --db-instance-identifier clf34-aurora-2

aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint,Port:Port,Members:DBClusterMembers[].{Id:DBInstanceIdentifier,IsWriter:IsClusterWriter,Tier:PromotionTier}}' \
  --output json
```

```json
{
    "Writer": "clf34-aurora.cluster-cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Reader": "clf34-aurora.cluster-ro-cabcd1efghij.us-east-1.rds.amazonaws.com",
    "Port": 5432,
    "Members": [
        { "Id": "clf34-aurora-1", "IsWriter": true,  "Tier": 1 },
        { "Id": "clf34-aurora-2", "IsWriter": false, "Tier": 1 }
    ]
}
```

Existen tres clases de endpoint: **cluster** (siempre el writer), **reader** (round-robin de DNS entre los readers), e **instance** (un nodo específico — usalo solo para diagnóstico, nunca en la configuración de la aplicación).

5. Comprobá la afirmación del almacenamiento compartido. Pedí el tamaño del volumen de almacenamiento del cluster y comparalo con la suma del almacenamiento por instancia:

```bash
aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].{AllocatedStorage:AllocatedStorage,AZs:AvailabilityZones}' --output json
```

```json
{
    "AllocatedStorage": 1,
    "AZs": [ "us-east-1a", "us-east-1b", "us-east-1c" ]
}
```

El cluster lista tres AZ aunque solo pusiste instancias en dos. Aurora mantiene **seis copias de cada bloque de datos a través de tres AZ**, independientemente de cuántas instancias de cómputo tengas corriendo. La durabilidad del almacenamiento está desacoplada del cómputo.

6. Disparás un failover y lo cronometrás. Como el reader ya tiene el almacenamiento conectado, la promoción es una operación del plano de control, no una copia de datos:

```bash
date +%T
aws rds failover-db-cluster --db-cluster-identifier clf34-aurora \
  --target-db-instance-identifier clf34-aurora-2 \
  --query 'DBCluster.Status' --output text

aws rds wait db-cluster-available --db-cluster-identifier clf34-aurora
date +%T

aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text
```

```
14:58:02
failing-over
14:58:35
clf34-aurora-2
```

Aproximadamente **30 segundos**, contra los ~1–2 minutos típicos de un failover de instancia RDS Multi-AZ.

7. Observá la capacidad de Serverless v2. Las ACU escalan en incrementos de 0,5; cada ACU es ~2 GiB de memoria con CPU y red proporcionadas:

```bash
aws rds describe-db-clusters --db-cluster-identifier clf34-aurora \
  --query 'DBClusters[0].ServerlessV2ScalingConfiguration' --output json
```

```json
{
    "MinCapacity": 0.5,
    "MaxCapacity": 4.0
}
```

**Fuentes:**
- Aurora overview — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html>
- Aurora endpoints — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html>
- Aurora Serverless v2 — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html>
- Aurora Global Database — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html>

### ✅ Chequeo de comprensión — Bloque 3

**Q3.1** — Creaste un cluster con dos instancias pero `AllocatedStorage` reportó un único número chico y tres AZ. Explicá la arquitectura de almacenamiento de Aurora en una oración, y decí cuántas copias de cada bloque existen y a través de cuántas AZ.

**Q3.2** — Un standby de RDS Multi-AZ no puede servir lecturas; una réplica de Aurora sí. ¿Por qué eso es arquitectónicamente posible en Aurora y no en RDS?

**Q3.3** — El failover de Aurora tardó ~30 s contra ~60–120 s de RDS Multi-AZ. Dá la razón arquitectónica, no solo el número.

**Q3.4** — Nombrá los tres tipos de endpoint de Aurora e indicá cuál debería usar normalmente el connection string de una aplicación para (a) escrituras y (b) lecturas de reportes.

**Q3.5** — Un cliente corre una base de datos de desarrollo que se usa dos horas por día. Compará **Aurora Serverless v2** contra una instancia Aurora aprovisionada `db.r6g.large` para esta carga de trabajo, en costo y en comportamiento de arranque en frío.

**Q3.6** — Una cadena minorista global necesita latencia de lectura por debajo del segundo en Europa y las Américas, con un RPO entre regiones documentado. ¿Qué funcionalidad de Aurora aplica, y qué replica?

---

## Ejercicio 4 — DynamoDB: pagás por la forma, no por servidores 🟡 BARATO

> **Costo:** el modo on-demand con un puñado de ítems cuesta fracciones de centavo. Efectivamente gratis a escala de laboratorio.

1. Creá una tabla con una **clave primaria compuesta** — partition key más sort key. Esta es una decisión de modelado, y en DynamoDB es casi irreversible:

```bash
aws dynamodb create-table \
  --table-name clf34-orders \
  --attribute-definitions \
      AttributeName=customerId,AttributeType=S \
      AttributeName=orderTs,AttributeType=S \
  --key-schema \
      AttributeName=customerId,KeyType=HASH \
      AttributeName=orderTs,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --sse-specification Enabled=true \
  --tags Key=Project,Value=clf34-lab \
  --query 'TableDescription.{Name:TableName,Status:TableStatus,Billing:BillingModeSummary.BillingMode}'
```

```json
{
    "Name": "clf34-orders",
    "Status": "CREATING",
    "Billing": "PAY_PER_REQUEST"
}
```

2. Anotá el tiempo de creación y contrastalo con el Ejercicio 2:

```bash
time aws dynamodb wait table-exists --table-name clf34-orders
```

```
real    0m10.412s
```

Once minutos para una instancia RDS Multi-AZ; diez segundos para una tabla DynamoDB. No elegiste clase de instancia, ni tamaño de almacenamiento, ni AZ, ni VPC — porque no hay instancia. La replicación Multi-AZ a través de tres AZ no es una opción que habilitás; es el comportamiento por defecto y el único.

3. Escribí tres ítems. DynamoDB es sin esquema más allá de los atributos de clave — el ítem 3 lleva un campo que los otros no tienen:

```bash
aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#1001"},
  "orderTs":    {"S": "2026-09-01T10:15:00Z"},
  "total":      {"N": "149.90"},
  "status":     {"S": "SHIPPED"}
}'

aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#1001"},
  "orderTs":    {"S": "2026-09-03T18:40:00Z"},
  "total":      {"N": "22.50"},
  "status":     {"S": "PENDING"}
}'

aws dynamodb put-item --table-name clf34-orders --item '{
  "customerId": {"S": "CUST#2002"},
  "orderTs":    {"S": "2026-09-02T09:00:00Z"},
  "total":      {"N": "980.00"},
  "status":     {"S": "PENDING"},
  "giftWrap":   {"BOOL": true}
}'
```

(Las llamadas exitosas a `put-item` no devuelven salida.)

4. **Query** — el patrón de acceso eficiente. Lee solo la partición que nombrás:

```bash
aws dynamodb query --table-name clf34-orders \
  --key-condition-expression "customerId = :c" \
  --expression-attribute-values '{":c": {"S": "CUST#1001"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 2,
    "RCU": 0.5
}
```

5. **Scan** — el patrón que no sobrevive en producción. Lee cada ítem de la tabla y después filtra:

```bash
aws dynamodb scan --table-name clf34-orders \
  --filter-expression "#s = :st" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":st": {"S": "PENDING"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 3,
    "RCU": 0.5
}
```

`Scanned: 3` contra `Count: 2` es la señal. Con tres ítems es invisible; con treinta millones de ítems acabás de leer y pagar la tabla entera para devolver dos filas. **Se te factura por `ScannedCount`, no por `Count`.**

6. Medí el precio de la consistencia directamente. Ejecutá el mismo `get-item` dos veces, cambiando solo el flag de consistencia:

```bash
aws dynamodb get-item --table-name clf34-orders \
  --key '{"customerId":{"S":"CUST#1001"},"orderTs":{"S":"2026-09-01T10:15:00Z"}}' \
  --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity.CapacityUnits'

aws dynamodb get-item --table-name clf34-orders \
  --key '{"customerId":{"S":"CUST#1001"},"orderTs":{"S":"2026-09-01T10:15:00Z"}}' \
  --consistent-read \
  --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity.CapacityUnits'
```

```
0.5
1.0
```

Exactamente el doble. Una lectura eventualmente consistente cuesta 0,5 RCU por 4 KB; una lectura fuertemente consistente cuesta 1 RCU. Ese número es la consecuencia directa de facturación de que DynamoDB replique de forma síncrona a tres AZ y te deje elegir si esperás al quórum.

7. Agregá un **Global Secondary Index** para soportar un patrón de consulta que la clave base no puede servir — "todos los pedidos por status":

```bash
aws dynamodb update-table --table-name clf34-orders \
  --attribute-definitions AttributeName=status,AttributeType=S AttributeName=orderTs,AttributeType=S \
  --global-secondary-index-updates '[{
    "Create": {
      "IndexName": "status-orderTs-index",
      "KeySchema": [
        {"AttributeName": "status", "KeyType": "HASH"},
        {"AttributeName": "orderTs", "KeyType": "RANGE"}
      ],
      "Projection": {"ProjectionType": "ALL"}
    }
  }]' \
  --query 'TableDescription.GlobalSecondaryIndexes[0].{Index:IndexName,Status:IndexStatus}'
```

```json
{
    "Index": "status-orderTs-index",
    "Status": "CREATING"
}
```

8. Una vez `ACTIVE`, ejecutá la consulta que el scan no podía hacer eficientemente:

```bash
aws dynamodb query --table-name clf34-orders \
  --index-name status-orderTs-index \
  --key-condition-expression "#s = :st" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":st": {"S": "PENDING"}}' \
  --return-consumed-capacity TOTAL \
  --query '{Count:Count,Scanned:ScannedCount,RCU:ConsumedCapacity.CapacityUnits}'
```

```json
{
    "Count": 2,
    "Scanned": 2,
    "RCU": 0.5
}
```

Ahora `Scanned` es igual a `Count`. El patrón de acceso determina el índice; el índice no rescata a un mal patrón de acceso.

9. Habilitá las dos funcionalidades de protección de datos que deberías tratar como valores por defecto:

```bash
aws dynamodb update-continuous-backups --table-name clf34-orders \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text

aws dynamodb update-time-to-live --table-name clf34-orders \
  --time-to-live-specification "Enabled=true, AttributeName=expiresAt" \
  --query 'TimeToLiveSpecification' --output json
```

```
ENABLED
```
```json
{
    "Enabled": true,
    "AttributeName": "expiresAt"
}
```

PITR te da restauración a nivel de segundo sobre una ventana de 35 días. TTL borra los ítems vencidos con **costo cero de escritura** — la política de retención de datos más barata que vende AWS.

10. Inspeccioná qué le hizo el modo on-demand a los campos de capacidad:

```bash
aws dynamodb describe-table --table-name clf34-orders \
  --query 'Table.{Billing:BillingModeSummary.BillingMode,RCU:ProvisionedThroughput.ReadCapacityUnits,WCU:ProvisionedThroughput.WriteCapacityUnits,Size:TableSizeBytes,Items:ItemCount}'
```

```json
{
    "Billing": "PAY_PER_REQUEST",
    "RCU": 0,
    "WCU": 0,
    "Size": 0,
    "Items": 0
}
```

> `TableSizeBytes` e `ItemCount` se actualizan en un ciclo de aproximadamente seis horas. El cero acá es un retraso esperado de metadatos, no datos faltantes — el `scan` ya devolvió tus tres ítems.

**Fuentes:**
- DynamoDB developer guide — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html>
- Read consistency — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html>
- Global secondary indexes — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html>
- Time to Live — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html>
- DAX — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DAX.html>
- Global tables — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html>

### ✅ Chequeo de comprensión — Bloque 4

**Q4.1** — La tabla estuvo `ACTIVE` en diez segundos y nunca elegiste una AZ, una VPC ni una clase de instancia. ¿Qué te dice eso sobre la posición de DynamoDB en el espectro administrado↔serverless respecto de RDS, y qué desaparece de tu responsabilidad operativa?

**Q4.2** — En el paso 5, `ScannedCount` (3) superó a `Count` (2). ¿Por cuál de los dos números se te factura, y cuál es la consecuencia en producción con 30 millones de ítems?

**Q4.3** — El paso 6 midió 0,5 RCU contra 1,0 RCU. Explicá *por qué* la consistencia fuerte cuesta el doble, en términos de qué hace DynamoDB con las tres réplicas.

**Q4.4** — Un GSI tiene su propia partition key y su propia capacidad. Nombrá una cosa que un GSI puede hacer y un Local Secondary Index no, y una restricción que tiene un LSI y un GSI no.

**Q4.5** — Las lecturas de DynamoDB ya están en milisegundos de un solo dígito. ¿Cuándo tiene sentido agregar **DAX**, y qué latencia apunta a lograr?

**Q4.6** — Distinguí las **global tables de DynamoDB** de **Aurora Global Database** en cuanto a topología de escritura.

**Q4.7** — Para DynamoDB existen tanto PITR como los backups on-demand. ¿Cuál satisface "restaurar a cualquier segundo de los últimos 35 días", y cuál satisface "conservar una copia de esta tabla por siete años para la auditoría"?

---

## Ejercicio 5 — Caché: ElastiCache, MemoryDB y el patrón que importa 🟢 GRATIS

Vamos a demostrar el patrón **cache-aside** localmente con Redis en un contenedor — semántica idéntica a ElastiCache, costo cero — e inspeccionar la superficie de AWS en solo lectura.

1. Inspeccioná lo que ElastiCache ofrece hoy:

```bash
aws elasticache describe-cache-engine-versions \
  --query 'CacheEngineVersions[].Engine' --output text | tr '\t' '\n' | sort -u
```

```
memcached
redis
valkey
```

2. Mirá una diferencia concreta en la superficie de funcionalidades de los motores:

```bash
aws elasticache describe-cache-engine-versions --engine memcached \
  --query 'CacheEngineVersions[-1].{Engine:Engine,Version:EngineVersion,ParamFamily:CacheParameterGroupFamily}' --output json

aws elasticache describe-cache-engine-versions --engine valkey \
  --query 'CacheEngineVersions[-1].{Engine:Engine,Version:EngineVersion,ParamFamily:CacheParameterGroupFamily}' --output json
```

```json
{ "Engine": "memcached", "Version": "1.6.22", "ParamFamily": "memcached1.6" }
```
```json
{ "Engine": "valkey", "Version": "8.0", "ParamFamily": "valkey8" }
```

3. Corré Redis localmente para demostrar cache-aside:

```bash
docker run -d --name clf34-cache -p 6379:6379 redis:7-alpine
docker exec -it clf34-cache redis-cli PING
```

```
PONG
```

4. Simulá un **fallo de caché** (miss) seguido de una lectura a la base de datos y un llenado de caché, con un TTL:

```bash
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli SETEX "order:CUST#1001:2026-09-01" 300 '{"total":149.90,"status":"SHIPPED"}'
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli TTL "order:CUST#1001:2026-09-01"
```

```

OK
{"total":149.90,"status":"SHIPPED"}
297
```

El primer `GET` devolvió vacío — un miss. Tu aplicación entonces leería la fuente de verdad (RDS o DynamoDB), escribiría el resultado en la caché con un TTL, y lo devolvería. Cada petición posterior durante 300 segundos se sirve desde memoria sin tocar la base de datos.

5. Demostrá por qué el TTL es una decisión de corrección, no una perilla de ajuste. Actualizá la "base de datos" pero no la caché:

```bash
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
# ...meanwhile the order ships and the DB row changes to DELIVERED...
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
```

```
{"total":149.90,"status":"SHIPPED"}
{"total":149.90,"status":"SHIPPED"}
```

La caché ahora está sirviendo una respuesta obsoleta, y va a seguir haciéndolo hasta que expire el TTL o la aplicación invalide la clave al escribir. Esa ventana es el precio de la caché, y es la razón por la que una caché no sirve como sistema de registro.

6. Comprobá que una caché no es almacenamiento durable:

```bash
docker restart clf34-cache
sleep 3
docker exec clf34-cache redis-cli GET "order:CUST#1001:2026-09-01"
docker exec clf34-cache redis-cli DBSIZE
```

```

(integer) 0
```

Todo desapareció. **Este es el único hecho que separa a ElastiCache de MemoryDB.** MemoryDB persiste cada escritura en un log transaccional Multi-AZ antes de confirmarla, lo que la convierte en una base de datos primaria durable con velocidad en memoria — y le pone precio en consecuencia.

7. Limpiá el contenedor:

```bash
docker rm -f clf34-cache
```

**Fuentes:**
- ElastiCache — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html>
- Caching strategies — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Strategies.html>
- Amazon MemoryDB — <https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html>

### ✅ Chequeo de comprensión — Bloque 5

**Q5.1** — El paso 6 vació la caché al reiniciar. Enunciá en una línea la diferencia entre **ElastiCache** y **MemoryDB**, y dá una carga de trabajo para cada uno.

**Q5.2** — Contrastá **Memcached** y **Redis/Valkey** en ElastiCache en: estructuras de datos, replicación y multihilo. ¿Cuál elegirías para una tabla de posiciones (leaderboard), y por qué?

**Q5.3** — En el paso 5 la caché sirvió datos obsoletos. Nombrá la estrategia de caché que usaste, nombrá una estrategia alternativa, y enunciá la contrapartida entre ambas.

**Q5.4** — Tu primario de RDS está al 95 % de CPU sirviendo la misma consulta de catálogo de productos miles de veces por segundo. Compará agregar una **read replica** contra agregar **ElastiCache**. ¿Cuál ataca la causa raíz, y qué te da la otra?

**Q5.5** — ¿ElastiCache es un servicio de base de datos en la guía del examen CLF-C02, o un servicio de caché? ¿Por qué importa la distinción cuando una pregunta pide "el sistema de registro"?

---

## Ejercicio 6 — Motores construidos a propósito: hacé coincidir el modelo de datos, no la marca 🟢 GRATIS

La postura de AWS es que el modelo relacional es una opción entre muchas, y que elegir el modelo de datos equivocado cuesta más que elegir el tamaño de instancia equivocado. Este bloque es de solo lectura.

1. Confirmá que cada motor construido a propósito existe y es alcanzable en tu región:

```bash
aws neptune describe-db-engine-versions \
  --query 'DBEngineVersions[-1].{Engine:Engine,Version:EngineVersion}' --output json

aws docdb describe-db-engine-versions \
  --query 'DBEngineVersions[-1].{Engine:Engine,Version:EngineVersion}' --output json

aws keyspaces list-keyspaces \
  --query 'keyspaces[].keyspaceName' --output text

aws timestream-write describe-endpoints \
  --query 'Endpoints[0].Address' --output text
```

```json
{ "Engine": "neptune", "Version": "1.3.4.0" }
```
```json
{ "Engine": "docdb", "Version": "5.0.0" }
```
```
system  system_schema  system_multiregion_info
```
```
ingest-cell1.timestream.us-east-1.amazonaws.com
```

Notá que `keyspaces` ya devolvió keyspaces de sistema sin que crearas nada: Amazon Keyspaces es serverless, sin cluster que aprovisionar.

2. Observá el parecido de familia. Neptune y DocumentDB exponen la *misma* forma de plano de control que Aurora — clusters, instancias, endpoints de cluster — porque están construidos sobre la misma capa de almacenamiento distribuido:

```bash
aws docdb describe-orderable-db-instance-options --engine docdb \
  --query 'OrderableDBInstanceOptions[0].{Engine:Engine,Class:DBInstanceClass,Storage:StorageType}' --output json
```

```json
{ "Engine": "docdb", "Class": "db.r6g.large", "Storage": "aurora" }
```

`"Storage": "aurora"` en una instancia de DocumentDB es la arquitectura filtrándose a través de la API.

3. Revisá la superficie de Redshift sin aprovisionar nada:

```bash
aws redshift describe-cluster-versions \
  --query 'ClusterVersions[-1].{Version:ClusterVersion,Description:Description}' --output json

aws redshift-serverless list-workgroups \
  --query 'workgroups[].{Name:workgroupName,Status:status,RPU:baseCapacity}' --output table
```

```json
{ "Version": "1.0", "Description": "Cluster version 1.0" }
```
```
-----------------------------------------
|            ListWorkgroups             |
+------+----------+---------------------+
| Name | Status   |        RPU          |
+------+----------+---------------------+
+------+----------+---------------------+
```

Vacío, como se esperaba — no aprovisionaste nada.

> 🔴 **No crees un workgroup de Redshift Serverless a la ligera.** La capacidad base mínima es de 8 RPU a aproximadamente US$0,375/RPU-hora ≈ **US$3/hora**. Un fin de semana de olvido cuesta unos US$150. Redshift es un data warehouse dimensionado para escaneos de terabytes; no tiene un nivel "micro".

4. Inspeccioná la cadena de herramientas de migración:

```bash
aws dms describe-endpoint-types \
  --query 'SupportedEndpointTypes[].EngineName' --output text | tr '\t' '\n' | sort -u | head -14
```

```
aurora
aurora-postgresql
azuredb
db2
docdb
dynamodb
kafka
kinesis
mariadb
mongodb
mysql
opensearch
oracle
postgres
```

Notá `dynamodb`, `kinesis` y `opensearch` en esa lista: DMS mueve datos entre familias de motores *distintas*, no meramente entre dos copias del mismo.

5. Construí la tabla de decisión vos mismo. Completá la columna del medio antes de leer las respuestas:

| Descripción de la carga de trabajo | Servicio | Por qué |
|---|---|---|
| Sistema de ingreso de pedidos, transacciones ACID, joins, aplicación PostgreSQL existente | ? | |
| Lo mismo, pero necesita 5× el throughput y un SLO de failover de 30 s | ? | |
| Estado de carrito de compras y de sesión, milisegundos de un solo dígito, picos impredecibles | ? | |
| Dashboards de BI escaneando 4 TB de ventas históricas | ? | |
| Detección de fraude: "¿qué cuentas están a 3 saltos de este dispositivo?" | ? | |
| Flota IoT: 200 000 sensores escribiendo métricas cada 10 s, consultadas por rango de tiempo | ? | |
| Lift-and-shift de una aplicación MongoDB 5.0 autoalojada | ? | |
| Lift-and-shift de una aplicación Apache Cassandra autoalojada | ? | |
| Almacén compatible con Redis que es el **sistema de registro**, no debe perder escrituras | ? | |
| Caché de páginas de producto delante de una instancia RDS sobrecargada | ? | |
| Base de datos Oracle que necesita acceso a nivel de sistema operativo para un agente del proveedor | ? | |
| SQL ad-hoc sobre logs comprimidos que ya están en Amazon S3 | ? | |

**Fuentes:**
- Amazon Neptune — <https://docs.aws.amazon.com/neptune/latest/userguide/intro.html>
- Amazon DocumentDB — <https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html>
- Amazon Keyspaces — <https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html>
- Amazon Timestream — <https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html>
- Amazon Redshift — <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- Redshift Serverless — <https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html>
- AWS DMS — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>

### ✅ Chequeo de comprensión — Bloque 6

**Q6.1** — DocumentDB reportó `"StorageType": "aurora"`. ¿Qué revela eso, y qué implica sobre las características de disponibilidad de DocumentDB?

**Q6.2** — Neptune soporta tres lenguajes de consulta. Nombralos, y dá la pregunta de grafo que una base de datos relacional responde mal.

**Q6.3** — RDS/Aurora son OLTP; Redshift es OLAP. Dá la razón de disposición del almacenamiento (una palabra cada uno) y explicá por qué eso hace que cada uno sea malo para el trabajo del otro.

**Q6.4** — Amazon Athena también ejecuta SQL. ¿Por qué Athena **no** es un servicio de base de datos, y cuándo lo elegirías por sobre cargar los datos en Redshift?

**Q6.5** — Keyspaces devolvió keyspaces de sistema de inmediato sin nada aprovisionado. ¿Qué propiedad operativa demuestra eso, y qué otro servicio de base de datos de este tema la comparte?

**Q6.6** — Amazon QLDB aparece en material de estudio más viejo de CLF-C02. ¿Para qué servía, y cuál es su estado actual? ¿Qué deberías hacer si lo ves en una pregunta de práctica?

---

## Ejercicio 7 — Migración: DMS, SCT y las dos direcciones de "mover" 🟢 GRATIS

1. Mirá lo que te costaría una instancia de replicación en términos de dimensionamiento:

```bash
aws dms describe-orderable-replication-instances \
  --query 'OrderableReplicationInstances[?contains(ReplicationInstanceClass,`t3`)].{Class:ReplicationInstanceClass,MinStorage:MinAllocatedStorageGB,MaxStorage:MaxAllocatedStorageGB,AZ:AvailabilityZone}' \
  --output table
```

```
------------------------------------------------------------------------
|                 DescribeOrderableReplicationInstances                |
+------------+-------------+--------------+---------------------------+
|   Class    | MaxStorage  |  MinStorage  |            AZ             |
+------------+-------------+--------------+---------------------------+
|  dms.t3.micro  |  6000   |      5       |  us-east-1a               |
|  dms.t3.small  |  6000   |      5       |  us-east-1a               |
|  dms.t3.medium |  6000   |      5       |  us-east-1a               |
|  dms.t3.large  |  6000   |      5       |  us-east-1a               |
+------------+-------------+--------------+---------------------------+
```

2. Clasificá las dos formas de migración. Ejecutá esto contra la lista de tipos de endpoint del Ejercicio 6 y razoná sobre los pares:

```bash
aws dms describe-endpoint-types \
  --query 'SupportedEndpointTypes[?EngineName==`oracle` || EngineName==`postgres`].{Engine:EngineName,Type:EndpointType,SupportsCDC:SupportsCDC}' \
  --output table
```

```
--------------------------------------------------
|             DescribeEndpointTypes              |
+-----------+---------------+--------------------+
|  Engine   |     Type      |    SupportsCDC     |
+-----------+---------------+--------------------+
|  oracle   |  source       |  True              |
|  oracle   |  target       |  True              |
|  postgres |  source       |  True              |
|  postgres |  target       |  True              |
+-----------+---------------+--------------------+
```

`SupportsCDC: true` es lo que hace posible un cambio de sistema (**cutover**) con **casi cero tiempo de inactividad**: DMS realiza una carga completa mientras el origen permanece en línea, luego aplica el flujo de cambios capturado durante esa carga hasta que el retraso llega casi a cero, y recién entonces hacés el cutover.

3. Razoná sobre las dos clases de migración:

- **Homogénea** — Oracle → Oracle, MySQL → RDS MySQL. El esquema ya es compatible. **DMS solo** hace el trabajo.
- **Heterogénea** — Oracle → Aurora PostgreSQL, SQL Server → MySQL. Los tipos de datos, los procedimientos almacenados y PL/SQL no se traducen. Necesitás **AWS SCT (Schema Conversion Tool)** para convertir el esquema y los objetos de código *primero*, y después DMS para mover las filas. SCT también produce un informe de evaluación que lista lo que no pudo convertir automáticamente.

4. Notá la restricción de orden que les cuesta el cronograma a los proyectos: **SCT antes que DMS, siempre.** DMS mueve datos hacia un esquema destino; si el esquema no existe, o existe con tipos incompatibles, la carga falla o trunca en silencio.

**Fuentes:**
- AWS DMS — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- AWS SCT — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- DMS CDC — <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Task.CDC.html>

### ✅ Chequeo de comprensión — Bloque 7

**Q7.1** — Definí migración homogénea contra heterogénea, y enunciá cuál requiere SCT.

**Q7.2** — `SupportsCDC: true`. Explicá en dos oraciones cómo CDC habilita un cutover con casi cero tiempo de inactividad, y qué debe tener habilitado la base de datos origen para que funcione.

**Q7.3** — Un equipo ejecuta DMS para mover 4 TB desde un Oracle on-premises hacia Aurora PostgreSQL sin correr SCT primero. Predecí el modo de falla.

**Q7.4** — DMS lista `kinesis` y `opensearch` como tipos de endpoint. ¿Qué te dice eso sobre el alcance de DMS más allá de la "migración de bases de datos"?

---

## Ejercicio 8 — El ejercicio con forma de examen: responsabilidad compartida a través de tres niveles 🟢 GRATIS

Para cada fila, marcá **C** (cliente) o **A** (AWS). Completá las tres columnas antes de verificar.

| Tarea | MySQL en EC2 | RDS MySQL | DynamoDB |
|---|---|---|---|
| Parchear el sistema operativo invitado | ? | ? | ? |
| Parchear el binario del motor MySQL | ? | ? | ? |
| Configurar los backups automatizados | ? | ? | ? |
| Diseñar el esquema / modelo de claves | ? | ? | ? |
| Aprovisionar hardware de reemplazo ante falla del host | ? | ? | ? |
| Cifrar los datos en reposo (activar la funcionalidad) | ? | ? | ? |
| Administrar el *servicio* de cifrado (KMS) | ? | ? | ? |
| Optimizar consultas e índices | ? | ? | ? |
| Elegir el tamaño de instancia | ? | ? | ? |
| Configurar el control de acceso de red | ? | ? | ? |
| Escalar la capacidad de almacenamiento | ? | ? | ? |
| Seguridad física del centro de datos | ? | ? | ? |

**Fuente:** <https://aws.amazon.com/compliance/shared-responsibility-model/>

### ✅ Chequeo de comprensión — Bloque 8

**Q8.1** — Una fila difiere entre las tres columnas. ¿Cuál, y por qué es la ilustración más clara del espectro de servicios administrados?

**Q8.2** — "Cifrar los datos en reposo" es responsabilidad del cliente en las tres columnas aunque AWS realice el cifrado. Explicá la distinción que traza acá el modelo de responsabilidad compartida.

**Q8.3** — "Diseñar el esquema" es del cliente en las tres columnas. Nombrá el principio general que explica por qué ningún servicio de base de datos de AWS va a tomar jamás esa fila.

---

## Ejercicio 9 — Desmontaje y verificación de costos 🟢 GRATIS (y obligatorio)

Ejecutá esto incluso si creés que no creaste nada. Sobre todo entonces.

1. Borrá primero la read replica (una réplica bloquea la eliminación de su origen):

```bash
aws rds delete-db-instance --db-instance-identifier clf34-mysql-ro \
  --skip-final-snapshot --query 'DBInstance.DBInstanceStatus' --output text
aws rds wait db-instance-deleted --db-instance-identifier clf34-mysql-ro
```

```
deleting
```

2. La protección contra eliminación está haciendo su trabajo — tenés que deshabilitarla explícitamente:

```bash
aws rds modify-db-instance --db-instance-identifier clf34-mysql \
  --no-deletion-protection --apply-immediately \
  --query 'DBInstance.PendingModifiedValues' --output json

aws rds delete-db-instance --db-instance-identifier clf34-mysql \
  --skip-final-snapshot --delete-automated-backups \
  --query 'DBInstance.DBInstanceStatus' --output text
aws rds wait db-instance-deleted --db-instance-identifier clf34-mysql
```

3. Borrá las instancias de Aurora *antes* que el cluster — un cluster con miembros no se puede borrar:

```bash
for i in clf34-aurora-1 clf34-aurora-2; do
  aws rds delete-db-instance --db-instance-identifier "$i" --skip-final-snapshot
done
for i in clf34-aurora-1 clf34-aurora-2; do
  aws rds wait db-instance-deleted --db-instance-identifier "$i"
done

aws rds delete-db-cluster --db-cluster-identifier clf34-aurora \
  --skip-final-snapshot --query 'DBCluster.Status' --output text
```

4. **Borrá el snapshot manual.** Este es el que la gente olvida — sobrevive a la eliminación de la instancia para siempre y factura para siempre:

```bash
aws rds delete-db-snapshot --db-snapshot-identifier clf34-mysql-manual-01 \
  --query 'DBSnapshot.Status' --output text
```

5. Borrá DynamoDB, el subnet group y el security group:

```bash
aws dynamodb delete-table --table-name clf34-orders \
  --query 'TableDescription.TableStatus' --output text
aws dynamodb wait table-not-exists --table-name clf34-orders

aws rds delete-db-subnet-group --db-subnet-group-name clf34-subnets
aws ec2 delete-security-group --group-id "$SG_ID"
```

6. **Verificá, no supongas.** Barré todos los servicios de bases de datos en busca de sobrevivientes:

```bash
echo "--- RDS instances ---"
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text
echo "--- RDS clusters ---"
aws rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text
echo "--- Manual snapshots ---"
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
echo "--- Cluster snapshots ---"
aws rds describe-db-cluster-snapshots --snapshot-type manual \
  --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier' --output text
echo "--- DynamoDB tables ---"
aws dynamodb list-tables --query 'TableNames' --output text
echo "--- ElastiCache ---"
aws elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text
echo "--- Redshift Serverless ---"
aws redshift-serverless list-workgroups --query 'workgroups[].workgroupName' --output text
```

Una cuenta limpia imprime seis líneas en blanco:

```
--- RDS instances ---

--- RDS clusters ---

--- Manual snapshots ---

--- Cluster snapshots ---

--- DynamoDB tables ---

--- ElastiCache ---

--- Redshift Serverless ---

```

7. Confirmá contra la factura 24 horas después. Los datos de costos tienen retraso; un chequeo el mismo día no prueba nada:

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-09-04,End=2026-09-06 \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?contains(Keys[0],`Relational`) || contains(Keys[0],`DynamoDB`)].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}' \
  --output table
```

```
------------------------------------------------------------
|                    GetCostAndUsage                       |
+--------------------------------------+-------------------+
|               Service                |       Cost        |
+--------------------------------------+-------------------+
|  Amazon Relational Database Service   |  0.7412031000    |
|  Amazon DynamoDB                      |  0.0000041200    |
+--------------------------------------+-------------------+
```

> `get-cost-and-usage` en sí cuesta US$0,01 por petición paginada. No lo pongas en un bucle.

### ✅ Chequeo de comprensión — Bloque 9

**Q9.1** — El paso 2 exigió deshabilitar la protección contra eliminación antes de borrar. ¿Es la protección contra eliminación un control de seguridad o un control operativo? ¿Contra qué no protege?

**Q9.2** — Pasaste `--skip-final-snapshot`. ¿Cuál es la alternativa, y en qué entorno omitir el snapshot final sería un evento capaz de generar un currículum nuevo?

**Q9.3** — Los backups automatizados se eliminaron con `--delete-automated-backups`, pero el snapshot manual necesitó su propia llamada de borrado. Enunciá en una oración la regla de retención de cada uno.

**Q9.4** — El desmontaje de Aurora requirió borrar las instancias antes que el cluster; RDS no tuvo ese paso. ¿Qué hecho arquitectónico del Ejercicio 3 refleja ese orden?

---

## Ejercicio 10 — Ejercicio de escenarios cronometrado (10 minutos, a libro cerrado) 🟢 GRATIS

Respondé cada uno con un servicio y una cláusula de justificación. Cronometrate — CLF-C02 te da aproximadamente 1 minuto y 45 segundos por pregunta.

1. Un hospital debe consultar "todos los pacientes atendidos por cualquier médico que haya trabajado en la Clínica X entre 2019 y 2021, dentro de dos grados de separación".
2. La base de datos PostgreSQL de un producto SaaS sirve 40 000 lecturas/s y 2 000 escrituras/s y necesita un failover por debajo de 60 s entre AZ, con cambios mínimos en la aplicación.
3. Un juego móvil almacena el estado por jugador, tiene un pico de lanzamiento impredecible de 0 a 1 M de peticiones/s, y el equipo no tiene DBAs.
4. Finanzas necesita ejecutar consultas de tendencia a 90 días sobre 8 TB de historial de transacciones sin ralentizar el sistema transaccional.
5. Una firma regulada debe migrar 12 TB de SQL Server on-premises a Aurora PostgreSQL con menos de 15 minutos de inactividad.
6. Una aplicación necesita un almacén compatible con Redis donde perder una escritura es inaceptable — es el sistema de registro, no una caché.
7. Un parque eólico ingiere 50 000 mediciones de turbina por segundo, consultadas casi exclusivamente como "salida promedio por turbina por hora, últimos 30 días".
8. Un equipo quiere ejecutar cargas de trabajo MongoDB sin operar replica sets, sharding ni backups.
9. Una aplicación Oracle heredada requiere un agente a nivel de sistema operativo instalado en el host de la base de datos, y el proveedor no certifica ninguna otra cosa.
10. Diez TB de logs comprimidos de CloudTrail están en S3. Seguridad quiere SQL ad-hoc sobre ellos aproximadamente dos veces por mes.

---

<details>
<summary><strong>📖 Respuestas — clic para expandir</strong></summary>

## Bloque 0 — Barreras de protección

**A0.1** — Cada llamada de *recurso* en este laboratorio (RDS, DynamoDB, ElastiCache, Neptune) es regional. Las bases de datos, los subnet groups, los security groups y los snapshots existen en exactamente una región, y una región sin definir significa que la CLI cae en lo que sea que haya en tu perfil — una manera clásica de dejar corriendo una instancia Multi-AZ facturable en una región que no volvés a mirar nunca más. Que los endpoints de facturación sean globales no cambia eso; es precisamente por lo cual el barrido del Ejercicio 9 debe correrse por región.

**A0.2** — No. AWS Budgets es un mecanismo de **notificación e informe**, no un tope de gasto; AWS nunca deja de servir tus recursos porque se excedió un presupuesto. Para forzar una detención necesitás **AWS Budgets Actions**, que se puede configurar para aplicar una política IAM restrictiva, adjuntar una SCP, o detener instancias EC2/RDS cuando se supera un umbral — e incluso eso es una acción que configurás, no un límite duro nativo. Los únicos límites verdaderamente duros en AWS son las cuotas de servicio y los límites de permisos de IAM.

**A0.3** — Un DB subnet group es una *propiedad de la configuración de despliegue*, no de la topología actual. RDS exige al menos dos AZ para que puedas convertir después una instancia Single-AZ a Multi-AZ, y para que RDS pueda ubicar una instancia de reemplazo en una AZ distinta durante una falla de host o una operación de mantenimiento. Exigirlo por adelantado evita descubrir en plena caída que el standby no tiene a dónde ir.

---

## Bloque 1 — La superficie relacional

**A1.1** — **RDS Custom** te da acceso a nivel de sistema operativo y de base de datos: podés hacer SSH al host, instalar agentes de proveedores, aplicar parches personalizados y configurar ajustes que RDS estándar bloquea. Existe para aplicaciones heredadas de Oracle y SQL Server con requisitos de agentes de terceros. Lo que resignás es el contrato de automatización: como podés modificar el host, la automatización de AWS puede quedar incapaz de reparar la instancia o de hacer failover, y el soporte de un entorno roto por el cliente recae en vos. Es el escalón intermedio deliberado entre alojado en EC2 y RDS completamente administrado.

**A1.2** — Dos de: parcheo del sistema operativo invitado; parcheo de versión menor del motor de base de datos; ejecución y retención de backups automatizados; detección y reemplazo de fallas de hardware del host; aprovisionamiento de almacenamiento, RAID y escalado automático; configuración de la replicación síncrona Multi-AZ; administración del sistema de archivos subyacente. En EC2 cada una de esas es tuya, incluyendo escribir y probar el cron job de backup y ser quien recibe la llamada cuando dejó de funcionar en silencio.

**A1.3** — La alternativa es **BYOL (Bring Your Own License)**. Una empresa elige BYOL cuando ya posee licencias perpetuas de Oracle o SQL Server con soporte activo — pagarle a AWS una segunda vez por la licencia incluida en la tarifa por hora sería gasto duplicado. Se elige license-included cuando no hay licencia existente, cuando la carga de trabajo es de corta duración, o cuando el cliente quiere evitar por completo las auditorías de cumplimiento de licencias.

**A1.4** — `t` = propósito general con ráfagas (créditos de CPU, barata, inadecuada para carga sostenida); `m` = propósito general con relación CPU-memoria balanceada; `r` = optimizada para memoria, aproximadamente el doble de RAM por vCPU que una `m`. Para una réplica de reportes hambrienta de memoria elegí **`db.r6g.large`** — las consultas de reportes construyen grandes buffers de ordenamiento y de hash-join, y que el conjunto de trabajo viva en RAM es lo que mantiene la consulta fuera del disco. Elegir `t4g` ahí produce una réplica que es rápida durante diez minutos y después se estrangula cuando se le agotan los créditos de CPU.

---

## Bloque 2 — RDS Multi-AZ

**A2.1** — No. El standby de Multi-AZ no es legible ni conectable; existe puramente como destino de replicación síncrona para alta disponibilidad. Pagarlo te compra durabilidad y failover automático, no capacidad. La funcionalidad correcta para lecturas de reportes es una **read replica**, que tiene su propio endpoint y sirve tráfico de lectura. (Notá la excepción que vale la pena conocer: la opción de despliegue **Multi-AZ DB cluster** — tres instancias, un writer y dos standby *legibles* — sí sirve lecturas desde sus standbys. Los despliegues estándar de *instancia* Multi-AZ, que es lo que construiste, no.)

**A2.2** — RDS publica el endpoint de la instancia como un **CNAME** de DNS que apunta a la dirección del primario actual. En el failover el plano de control reapunta ese CNAME al standby promovido; el nombre que tiene tu aplicación nunca cambia, así que no hace falta ninguna configuración ni redespliegue. El modo de falla de la JVM: `networkaddress.cache.ttl` de la JVM históricamente cachea las resoluciones DNS exitosas **para siempre** cuando hay un security manager instalado. Una aplicación que resolvió el endpoint al arrancar sigue martillando la dirección IP del primario muerto mucho después de que AWS haya completado un failover sano. El arreglo es fijar el TTL de DNS de la JVM en 5–10 segundos — una responsabilidad del lado de la aplicación que AWS no puede arreglar por vos, y un patrón de incidente de producción real.

**A2.3** — **(a) Pérdida de datos.** La replicación síncrona significa que la escritura se confirma al cliente solo después de ser durable *tanto* en el primario como en el standby, así que una falla de AZ no pierde nada — el RPO es efectivamente cero. La replicación asíncrona confirma solo en el primario y envía los cambios después, así que una falla del primario puede perder lo que todavía no se había aplicado — el RPO es distinto de cero e igual al retraso de replicación en el momento de la falla. **(b) Latencia.** La replicación síncrona pone el ida y vuelta de red entre AZ dentro de cada commit, así que la latencia de escritura del primario es mayor — este es el costo real de Multi-AZ y la razón por la que no es gratis en términos de rendimiento. La replicación asíncrona no agrega esencialmente nada a la ruta de escritura del primario, que es exactamente por lo cual puede usarse entre regiones, donde un ida y vuelta síncrono sería intolerable.

**A2.4** — Usá **point-in-time recovery (PITR)** desde los backups automatizados. La granularidad es de **un segundo**, dentro de la ventana de retención (7 días acá, configurable de 1 a 35). Fundamentalmente, PITR **no sobrescribe el origen** — restaura a una **nueva instancia de base de datos** con un identificador nuevo y un endpoint nuevo. El procedimiento de recuperación es entonces: restaurar a una instancia nueva a las 14:31:59, extraer la tabla borrada y cargarla de vuelta en producción. Esto es una funcionalidad, no una limitación: significa que el intento de recuperación no puede empeorar el incidente, y es por lo cual "restaurar" y "revertir" no son sinónimos en RDS.

**A2.5** — Los **snapshots manuales** son el riesgo de costo. Los backups automatizados se rigen por el período de retención y se borran cuando se borra la instancia (salvo que se los retenga explícitamente), así que se autolimpian. Un snapshot manual no tiene período de retención alguno — persiste hasta que un humano lo borre, sobrevive a la eliminación de su instancia de origen, y sigue facturando su almacenamiento indefinidamente. En una cuenta de laboratorio así es como terminás pagando por una base de datos que borraste hace ocho meses.

**A2.6** — Dos de:
- **Falla de región completa** → read replica entre regiones, o **Aurora Global Database**, o replicación de backups automatizados entre regiones.
- **Corrupción lógica / `DROP` accidental** → PITR o snapshots. Multi-AZ replica el `DROP` al standby *de forma síncrona y fiel*; el standby es una copia perfecta de tu error.
- **Agotamiento de la capacidad de lectura** → read replicas. Multi-AZ agrega cero capacidad de lectura.
- **Eliminación accidental de la instancia** → protección contra eliminación más snapshots finales.

---

## Bloque 3 — Aurora

**A3.1** — Aurora separa el cómputo del almacenamiento: el cluster es dueño de un volumen de almacenamiento distribuido, autorreparable y de crecimiento automático que todas las instancias comparten, así que `AllocatedStorage` describe un volumen que crece bajo demanda en vez de un disco que dimensionaste. Aurora mantiene **seis copias de cada bloque de datos a través de tres zonas de disponibilidad** (dos por AZ). Tolera la pérdida de una AZ entera más una copia adicional sin perder disponibilidad de escritura, y la pérdida de una AZ entera más una copia más sin perder disponibilidad de lectura.

**A3.2** — En RDS, el standby es una *instancia separada con su propia copia independiente de los datos*, mantenida al día por replicación síncrona a nivel de bloque; dejarla servir lecturas significaría servir desde una réplica cuyas garantías de consistencia RDS no expone, y consumiría el margen de E/S que la propia replicación necesita. En Aurora, la réplica no es una copia en absoluto — se conecta al *mismo* volumen de almacenamiento compartido que el writer. No hay nada que sincronizar, así que un reader es simplemente otro nodo de cómputo leyendo las mismas páginas, y servir lecturas desde él es arquitectónicamente gratis.

**A3.3** — Porque el failover de Aurora es una **promoción**, no una **transferencia de propiedad de datos**. La réplica ya tiene el volumen de almacenamiento conectado y su caché de buffers parcialmente tibia, así que hacer failover significa actualizar el endpoint del cluster y dejar que el nodo promovido tome propiedad de escritura de un volumen que ya estaba leyendo. RDS Multi-AZ debe detectar la falla del primario, confirmar que el standby aplicó todos los bloques replicados, promoverlo y reapuntar el DNS — con una caché fría en la instancia recién promovida. Aurora además desacopla la caché de buffers del proceso de base de datos en el writer, así que un reinicio no fuerza una reconstrucción completa de la caché.

**A3.4** — **Endpoint de cluster** (`...cluster-...`) — siempre resuelve al writer actual, sigue el failover automáticamente. **Endpoint de reader** (`...cluster-ro-...`) — round-robin de DNS entre todos los readers disponibles. **Endpoint de instancia** — un nodo específico, usado para diagnóstico o para fijar una única carga de trabajo; nunca para la configuración general de la aplicación, porque esa instancia puede ser degradada, promovida o eliminada. (a) Escrituras → endpoint de cluster. (b) Lecturas de reportes → endpoint de reader.

**A3.5** — **Aurora Serverless v2** gana claramente en costo para una base de datos de 2 horas por día: pagás por ACU-segundo, así que una carga de trabajo ociosa 22 horas al día cuesta una fracción de una instancia aprovisionada facturada las 24. En versiones recientes del motor la capacidad mínima se puede fijar en **0 ACU**, pausando la base de datos por completo cuando está ociosa. La contrapartida es la latencia de arranque en frío: reanudar desde cero agrega una demora en la primera conexión (típicamente de unos segundos a decenas de segundos), lo cual está bien para desarrollo e inaceptable para una ruta sensible a la latencia de cara al usuario. Una `db.r6g.large` aprovisionada cuesta lo mismo se use o no, pero está siempre tibia y tiene rendimiento completamente predecible. Base de datos de desarrollo → Serverless v2. Carga de producción estable 24/7 con capacidad conocida → aprovisionada suele ser más barata por unidad de trabajo.

**A3.6** — **Aurora Global Database.** Replica la *capa de almacenamiento* desde una región primaria hacia hasta cinco regiones secundarias usando infraestructura dedicada en vez de la replicación propia del motor de base de datos, logrando un retraso de replicación entre regiones típicamente por debajo de un segundo y un RPO documentado de ~1 segundo con un RTO por debajo de un minuto para el failover planificado administrado. Las regiones secundarias son de solo lectura (con la excepción del write-forwarding, donde está soportado) y pueden promoverse a primaria para recuperación ante desastres. Notá el contraste con las global tables de DynamoDB en **A4.6**.

---

## Bloque 4 — DynamoDB

**A4.1** — DynamoDB es **serverless**, no meramente administrado. RDS todavía expone la abstracción del servidor — elegís una clase de instancia, una AZ, una VPC, un tamaño de almacenamiento, una ventana de mantenimiento, y esperás once minutos a que se aprovisione hardware. DynamoDB expone solamente la *tabla*. Lo que desaparece de tu responsabilidad: dimensionamiento de instancias, ubicación en AZ, diseño de VPC y subredes, aprovisionamiento y crecimiento del almacenamiento, parcheo y actualizaciones de versión del motor, configuración de replicación y planificación de failover. La replicación Multi-AZ a través de tres AZ no es una funcionalidad que habilitás y pagás aparte — es el único modo que tiene DynamoDB. Lo que sigue siendo tuyo es exactamente lo que también seguía siendo tuyo en RDS: el modelo de datos, los patrones de acceso, y el modo de capacidad/costo.

**A4.2** — Se te factura por **`ScannedCount`** — los ítems que DynamoDB leyó del almacenamiento — no por `Count`, los ítems que sobrevivieron a tu filtro. El filtro se aplica *después* de la lectura y después de la medición. Con 30 millones de ítems, un `scan` con un filtro que devuelve dos filas igualmente lee y factura los 30 millones: potencialmente miles de RCU, varios segundos a minutos de latencia a través de llamadas paginadas, y, en modo aprovisionado, estrangulamiento de todas las demás consultas de la tabla mientras corre. Por eso "agregá un `scan`" es el cambio de una línea más caro en una base de código DynamoDB, y por eso los patrones de acceso deben diseñarse antes de elegir el esquema de claves.

**A4.3** — DynamoDB replica de forma síncrona cada escritura a tres zonas de disponibilidad. Una lectura **eventualmente consistente** se sirve desde *una* cualquiera de esas tres réplicas — que puede no tener todavía la escritura más reciente — costando una lectura de réplica: **0,5 RCU por 4 KB**. Una lectura **fuertemente consistente** debe garantizar que devuelve la última escritura confirmada, así que se sirve desde la réplica líder con una vista de quórum confirmada, costando **1 RCU por 4 KB**. Estás pagando por la coordinación, y el esquema de precios hace que la contrapartida del teorema CAP sea literalmente visible en la factura. (Notá que una lectura fuertemente consistente además no está disponible si la AZ del líder está afectada, mientras que una lectura eventualmente consistente sigue funcionando — la mitad de disponibilidad de la misma contrapartida.)

**A4.4** — Un **GSI** puede usar una *partition key completamente distinta* de la de la tabla base, que es lo que permitió que el paso 8 consultara por `status` cuando la tabla está particionada por `customerId`; un LSI debe reutilizar la partition key de la tabla base y solo puede variar la sort key. Restricciones que tiene un **LSI** y un GSI no: debe crearse en el momento de creación de la tabla y nunca puede agregarse después; comparte la capacidad aprovisionada de la tabla base en vez de tener la propia; soporta lecturas fuertemente consistentes (un GSI es solo eventualmente consistente); y la colección de ítems para una única partition key queda limitada a 10 GB cuando existe un LSI. En la práctica, preferí los GSI — la propiedad de "hay que decidir al crear, para siempre" de los LSI es un pasivo de diseño serio.

**A4.5** — **DAX** es una caché en memoria completamente administrada, compatible con la API de DynamoDB y de escritura directa (write-through), que lleva las lecturas de **milisegundos** de un solo dígito a **microsegundos** de un solo dígito — aproximadamente una mejora de 10×. Tiene sentido cuando (a) la carga de trabajo es intensiva en lecturas con un conjunto de claves calientes leído repetidamente, (b) la aplicación es genuinamente sensible a la latencia a escala de microsegundos, como pujas en tiempo real o estado de juego de alta frecuencia, o (c) el costo de lectura de esas lecturas calientes repetidas supera el costo del cluster DAX. Su ventaja decisiva sobre ElastiCache delante de DynamoDB es que es compatible con la API: cambiás el cliente, no la lógica de la aplicación, y no implementás cache-aside a mano. Su costo es que las lecturas de DAX son eventualmente consistentes — una lectura fuertemente consistente elude la caché por completo.

**A4.6** — Las **global tables de DynamoDB** son **multi-región, activo-activo**: cada región réplica acepta escrituras, y los conflictos se resuelven con "gana el último que escribe". **Aurora Global Database** es de **un solo writer**: exactamente una región acepta escrituras, y las demás son réplicas de solo lectura que deben ser promovidas para tomar el control. Esa distinción es toda la respuesta a "¿puede mi aplicación escribir desde ambas regiones simultáneamente?" — DynamoDB sí, Aurora no (salvo write-forwarding, que igualmente enruta la escritura al único primario).

**A4.7** — **PITR** satisface "restaurar a cualquier segundo de los últimos 35 días": es un backup continuo con granularidad de segundo y una ventana máxima fija de 35 días, y siempre restaura a una tabla *nueva*. Los **backups on-demand** satisfacen la retención de siete años para auditoría: son snapshots completos que persisten hasta ser borrados explícitamente, no tienen límite de retención, y pueden administrarse bajo AWS Backup con una política de ciclo de vida. Usar PITR para retención de largo plazo es imposible (la ventana está limitada); usar backups on-demand para recuperación puntual de incidentes es impreciso (solo podés restaurar a los momentos en los que casualmente tomaste un backup).

---

## Bloque 5 — Caché

**A5.1** — **ElastiCache es una caché; MemoryDB es una base de datos durable.** ElastiCache almacena datos en memoria por velocidad y puede perderlos ante una falla o un reinicio — siempre debe ubicarse delante de un sistema de registro. MemoryDB persiste cada escritura en un log transaccional Multi-AZ antes de confirmarla, dando lecturas en microsegundos, escrituras en milisegundos de un solo dígito, y **durabilidad**, así que puede *ser* el sistema de registro. Cargas de trabajo: ElastiCache → almacén de sesiones respaldado por una base de datos, caché de catálogo de productos, contadores de limitación de tasa, caché de consultas de base de datos. MemoryDB → un microservicio cuyo almacén de datos primario es compatible con Redis y donde perder una escritura es una falla de corrección, como un servicio de estado de pedidos o un libro contable en tiempo real.

**A5.2** — **Estructuras de datos:** Memcached almacena únicamente blobs opacos de clave/valor; Redis/Valkey proveen sorted sets, hashes, listas, streams, hyperloglogs, índices geoespaciales y scripting Lua. **Replicación:** Memcached no tiene ninguna — sin réplicas, sin failover, sin snapshots; Redis/Valkey soportan replicación, Multi-AZ con failover automático, y backup/restauración. **Multihilo:** Memcached es multihilo y puede usar todos los núcleos de un nodo grande; la ejecución de comandos del núcleo de Redis es de un solo hilo (Valkey 8 agrega E/S multihilo significativa). Para una **tabla de posiciones**, elegí **Redis/Valkey**: el sorted set (`ZADD`/`ZRANGE`/`ZREVRANK`) es una estructura ordenada construida a propósito que te da el top-N y el puesto de un jugador en O(log n). En Memcached tendrías que traer toda la tabla de posiciones y ordenarla en la aplicación en cada petición.

**A5.3** — Usaste **cache-aside** (también llamado carga perezosa): la aplicación consulta la caché y, ante un miss, lee la base de datos y llena la caché. Su virtud es que solo se cachean los datos efectivamente pedidos, así que la caché se mantiene chica; su falla es precisamente lo que mostró el paso 5 — la caché puede servir datos obsoletos hasta que expire el TTL, y cada miss paga una penalidad de consulta a la caché encima de la lectura a la base de datos. La alternativa es **write-through**: cada escritura a la base de datos también actualiza la caché, así que la caché nunca queda obsoleta. Su contrapartida es que la latencia de escritura aumenta y la caché se llena de datos que quizá nunca se lean, desperdiciando memoria. La respuesta pragmática en producción suele ser ambas — write-through por corrección en las entidades calientes, más un TTL como red de contención para cualquier invalidación que se te haya pasado.

**A5.4** — Una **read replica** agrega capacidad de lectura pero igual ejecuta la consulta, parseando SQL, planificando, escaneando y haciendo joins, cada vez. **ElastiCache** elimina la consulta por completo: el resultado se sirve desde memoria en microsegundos y la base de datos nunca ve la petición. Para "la misma consulta miles de veces por segundo", ElastiCache ataca la causa raíz — estás pagando por calcular repetidamente una respuesta idéntica. La read replica te da algo que ElastiCache no puede: capacidad para lecturas *diversas* que no son cacheables, y un standby promovible para recuperación ante desastres. En producción con frecuencia desplegás ambos, pero para este síntoma la caché es la primera jugada correcta, y suele ser bastante más barata que una segunda instancia `r6g`.

**A5.5** — En la guía del examen CLF-C02, ElastiCache está agrupado bajo servicios de bases de datos (está en la lista de servicios dentro de alcance bajo Database), pero arquitectónicamente es un servicio de **caché** y nunca un sistema de registro. La distinción importa porque las preguntas de examen frecuentemente incluyen ElastiCache como distractor plausible cuando el requerimiento es almacenamiento durable. La regla: si la pregunta dice "no debe perder datos", "sistema de registro", "durable" o "fuente de verdad", ElastiCache está mal — la respuesta es RDS, Aurora, DynamoDB, o, si debe ser compatible con Redis, **MemoryDB**.

---

## Bloque 6 — Motores construidos a propósito

**A6.1** — Revela que DocumentDB está construido sobre la **misma capa de almacenamiento distribuido que Aurora** — la separación cómputo/almacenamiento, el modelo de objetos de cluster más instancias, los endpoints de cluster y de reader. La implicancia es que DocumentDB hereda las características de disponibilidad de Aurora: seis copias de los datos a través de tres AZ, almacenamiento que crece automáticamente, failover rápido por promoción en vez de transferencia de datos, y hasta quince read replicas compartiendo un volumen. Esto también es por lo cual DocumentDB es *compatible con MongoDB* y no *MongoDB*: implementa el protocolo de cable y la API de MongoDB sobre almacenamiento Aurora; no es el motor de MongoDB.

**A6.2** — **Gremlin** (Apache TinkerPop), **openCypher** y **SPARQL** (para RDF). La pregunta que una base de datos relacional responde mal es la travesía de profundidad variable: *"encontrá todo lo conectado a este nodo dentro de N saltos"*. En SQL cada salto es otro self-join, así que una consulta de 5 saltos significa cinco joins cuyo costo se multiplica con el factor de ramificación; el planificador de consultas no puede ayudar porque la profundidad puede depender de los datos o ser ilimitada. Una base de datos de grafos almacena la adyacencia directamente, así que atravesar un salto es una desreferencia de puntero y el costo escala con el *subgrafo efectivamente visitado*, no con el tamaño de las tablas. Las redes de fraude, las recomendaciones sociales y los grafos de conocimiento son los casos canónicos.

**A6.3** — RDS/Aurora son orientados a **filas**; Redshift es **columnar**. El almacenamiento por filas mantiene todos los atributos de un registro físicamente juntos, lo que hace que "leer, actualizar o insertar este pedido" sea una única E/S eficiente — ideal para OLTP, pésimo para analítica porque calcular `AVG(amount)` sobre mil millones de filas arrastra desde el disco cada columna sin usar. El almacenamiento columnar mantiene juntos todos los valores de una columna, así que escanear una columna de mil millones de filas lee solo esa columna, y como los valores adyacentes comparten tipo y dominio comprimen extremadamente bien — ideal para OLAP. Es pésimo para OLTP porque actualizar una sola fila implica tocar el bloque de almacenamiento de cada columna, e insertar una fila es el peor caso de patrón de escritura. Redshift agrava esto con procesamiento masivamente paralelo entre nodos y claves de distribución y ordenamiento, que optimizan para escaneos grandes, no para búsquedas puntuales.

**A6.4** — **Athena es un motor de consultas, no una base de datos**: no almacena nada, no es dueño de nada, y no administra ningún ciclo de vida de datos. Lee datos que ya viven en Amazon S3 a través de un esquema definido en el AWS Glue Data Catalog, y factura por terabyte escaneado sin ningún cluster que aprovisionar. Elegí Athena por sobre Redshift cuando las consultas son **infrecuentes y ad hoc**, cuando los datos ya están en S3 y no querés un pipeline de ETL, y cuando de otro modo pagarías por un cluster ocioso entre consultas. Elegí Redshift cuando las consultas son **frecuentes, complejas y sensibles a la latencia**, cuando necesitás rendimiento consistente para dashboards de BI que se refrescan todo el día, o cuando los joins entre tablas de hechos y dimensiones grandes se benefician de las claves de distribución y ordenamiento. La economía se invierte alrededor de la frecuencia de uso: Athena es barata cuando está ociosa y cara por consulta; Redshift es al revés.

**A6.5** — Demuestra que **Amazon Keyspaces es serverless**: no hay cluster, ni cantidad de nodos, ni clase de instancia, ni capacidad que planificar — creás un keyspace y una tabla y empezás a emitir CQL, con el servicio escalando las tablas hacia arriba y hacia abajo automáticamente. **DynamoDB** comparte esta propiedad, igual que **Aurora Serverless v2** (parcialmente — todavía definís los límites de ACU), **Redshift Serverless**, **Timestream** y **Athena**. Notá el paralelo: Keyspaces es a Cassandra lo que DocumentDB es a MongoDB — una API compatible sobre infraestructura administrada por AWS en vez del motor original. La consecuencia práctica es que no administrás nodos, pero tampoco podés asumir que esté presente cada funcionalidad o extensión del proyecto original.

**A6.6** — **Amazon QLDB (Quantum Ledger Database)** era una base de datos de libro contable completamente administrada con un journal inmutable, de solo anexado y criptográficamente verificable — cada cambio se registraba de forma permanente con una cadena de hashes SHA-256, así que podías probarle a un auditor que la historia no había sido alterada. Los casos de uso típicos eran libros contables financieros, procedencia en cadenas de suministro y rastros de auditoría regulatoria. **Su estado actual: retirado.** AWS anunció la obsolescencia en 2024 y terminó el soporte el **31 de julio de 2025**; la ruta de migración recomendada fue Amazon Aurora PostgreSQL, cuyos patrones de libro contable verificable cubren los mismos requerimientos. **Si ves QLDB en una pregunta de práctica**, tratalo como material escrito contra una guía de examen más vieja. Sabé qué hacía — el concepto de un libro contable inmutable y criptográficamente verificable sigue valiendo la pena entenderlo, y "rastro de auditoría inmutable y criptográficamente verificable" es una frase de requerimiento reconocible — pero no lo esperes como respuesta correcta en un examen actual, y no lo propongas en un diseño real. Verificá siempre el apéndice de servicios dentro de alcance de la guía de examen vigente en <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>.

**Tabla de decisión (paso 5):**

| Carga de trabajo | Servicio | Por qué |
|---|---|---|
| Ingreso de pedidos, ACID, joins, aplicación PostgreSQL existente | **Amazon RDS for PostgreSQL** | OLTP relacional con una dependencia de motor existente; RDS es la ruta administrada con menos cambios |
| Lo mismo, 5× de throughput, SLO de failover de 30 s | **Amazon Aurora PostgreSQL** | Compatible a nivel de protocolo, así que la aplicación no cambia; ~5× MySQL / ~3× PostgreSQL de throughput, ~30 s de failover, 15 readers sobre almacenamiento compartido |
| Estado de carrito/sesión, milisegundos de un solo dígito, con picos | **Amazon DynamoDB** | Patrón de acceso clave-valor, el modo on-demand absorbe los picos sin planificación de capacidad |
| BI sobre 4 TB de historial | **Amazon Redshift** | Data warehouse columnar MPP construido a propósito para escaneos analíticos grandes |
| Fraude: relaciones cuenta/dispositivo a 3 saltos | **Amazon Neptune** | Travesía de grafo; la misma consulta en SQL es una cadena ilimitada de self-joins |
| 200 000 sensores, consultas por rango de tiempo | **Amazon Timestream** | Series temporales construidas a propósito: almacenamiento particionado por tiempo, escalonamiento automático memoria→magnético, interpolación incorporada y funciones de ventana temporal |
| Lift-and-shift de MongoDB 5.0 | **Amazon DocumentDB** | Compatibilidad con la API de MongoDB sobre almacenamiento Aurora; sin replica sets ni sharding que operar |
| Lift-and-shift de Cassandra | **Amazon Keyspaces** | Compatibilidad con CQL, serverless, sin anillo ni administración de nodos |
| **Sistema de registro** compatible con Redis | **Amazon MemoryDB** | Log de transacciones Multi-AZ durable; ElastiCache correría el riesgo de perder escrituras confirmadas |
| Caché delante de una instancia RDS caliente | **Amazon ElastiCache** | Elimina por completo la consulta repetida en vez de reejecutarla en una réplica |
| Oracle que necesita acceso de agente a nivel de sistema operativo | **Amazon RDS Custom for Oracle** | La única opción administrada que otorga acceso al host; RDS estándar lo prohíbe |
| SQL ad-hoc sobre logs en S3, dos veces por mes | **Amazon Athena** | Serverless, pago por TB escaneado, sin cluster ocioso entre las dos consultas mensuales — y no es una base de datos en absoluto |

---

## Bloque 7 — Migración

**A7.1** — Una migración **homogénea** mueve entre motores iguales o compatibles (Oracle → Oracle, MySQL → RDS MySQL, PostgreSQL → Aurora PostgreSQL): el esquema, los tipos de datos y el código procedural ya son compatibles, así que **DMS solo** alcanza. Una migración **heterogénea** mueve entre familias de motores distintas (Oracle → Aurora PostgreSQL, SQL Server → MySQL): los tipos de datos, las secuencias, los procedimientos almacenados, los triggers y los dialectos SQL propietarios no se traducen, así que necesitás **AWS SCT** para convertir primero el esquema y los objetos de código, y después DMS para mover las filas. **SCT es necesario solo para las migraciones heterogéneas.**

**A7.2** — CDC (change data capture) lee el log de transacciones de la base de datos origen para capturar cada cambio hecho *mientras corre la carga completa*, y después aplica ese backlog al destino hasta que el retraso de replicación se acerca a cero. Como el origen sigue en línea y escribible todo el tiempo, la interrupción se reduce al momento en que detenés la aplicación, dejás drenar las últimas transacciones y reapuntás el connection string — minutos en vez de los días que llevaría una copia offline de 4 TB. Para que funcione, el origen debe tener el registro de transacciones habilitado y retenido en la forma que DMS requiere: supplemental logging más modo ARCHIVELOG en Oracle, `binlog_format=ROW` con retención de binlog adecuada en MySQL, replicación lógica (`wal_level=logical`) en PostgreSQL, y el equivalente con CDC habilitado en SQL Server.

**A7.3** — DMS es un servicio de movimiento de datos; no convierte esquemas. Sin un esquema destino convertido, o bien las tablas destino no existen y la tarea falla de inmediato en la fase de carga completa, o bien el mapeo básico de tipos del propio DMS crea aproximaciones que tienen éxito estructuralmente mientras corrompen la semántica en silencio — precisión de `NUMBER` perdida, manejo de zona horaria de `DATE` cambiado, `CLOB`/`BLOB` truncados, semántica de bytes contra caracteres de `VARCHAR2` desajustada. Peor todavía, nada del PL/SQL de Oracle — paquetes, procedimientos almacenados, triggers, secuencias — se migra en absoluto, porque DMS mueve filas, no código. El equipo descubre esto en el cutover, cuando la aplicación arranca y toda llamada a procedimiento almacenado falla. Orden correcto: **informe de evaluación de SCT → conversión de esquema con SCT → remediación manual de lo que SCT marcó → carga completa de DMS + CDC → validación → cutover.**

**A7.4** — DMS es un servicio de **replicación e integración de datos** de propósito general, no meramente una herramienta de migración de una sola vez. Endpoints como `kinesis`, `kafka`, `opensearch`, `s3` y `redshift` significan que DMS puede transmitir cambios de forma continua desde una base de datos transaccional hacia un destino de analítica o búsqueda — por ejemplo, replicando una tabla de pedidos de RDS PostgreSQL hacia OpenSearch para búsqueda de texto completo, o hacia Kinesis para alimentar un pipeline en tiempo real, todo vía CDC continuo en vez de un lote nocturno. El caso de uso de migración es el titular; la integración continua basada en CDC es para lo que muchos equipos realmente lo mantienen corriendo.

---

## Bloque 8 — Responsabilidad compartida

| Tarea | MySQL en EC2 | RDS MySQL | DynamoDB |
|---|---|---|---|
| Parchear el sistema operativo invitado | **C** | **A** | **A** |
| Parchear el binario del motor MySQL | **C** | **A** (el cliente elige la ventana/versión) | **A** (n/a — no hay motor que parchear) |
| Configurar los backups automatizados | **C** | **C** (configura; AWS ejecuta) | **C** (habilita PITR; AWS ejecuta) |
| Diseñar el esquema / modelo de claves | **C** | **C** | **C** |
| Aprovisionar hardware de reemplazo ante falla del host | **A** (hardware) / **C** (recuperación) | **A** | **A** |
| Cifrar los datos en reposo (activar la funcionalidad) | **C** | **C** | **C** (activado por defecto) |
| Administrar el *servicio* de cifrado (KMS) | **A** | **A** | **A** |
| Optimizar consultas e índices | **C** | **C** | **C** |
| Elegir el tamaño de instancia | **C** | **C** | **A** (no existen instancias) |
| Configurar el control de acceso de red | **C** | **C** | **C** (políticas de IAM / VPC endpoints) |
| Escalar la capacidad de almacenamiento | **C** | **C** (o habilitar el autoescalado de almacenamiento) | **A** |
| Seguridad física del centro de datos | **A** | **A** | **A** |

**A8.1** — **"Elegir el tamaño de instancia".** Es del cliente en EC2, del cliente en RDS, y de AWS en DynamoDB — porque en DynamoDB *no hay instancia que dimensionar*. Esa única fila es la expresión más clara de la progresión administrado→serverless: EC2 te da una máquina que tenés que operar por completo; RDS opera la máquina pero igual te hace especificarla; DynamoDB elimina la máquina de tu modelo mental por completo. Notá que "parchear el sistema operativo invitado" también difiere en *tipo* (C, después A, después no aplicable), pero la fila de dimensionamiento de instancia es la más nítida porque la misma responsabilidad se transfiere genuinamente en vez de meramente automatizarse.

**A8.2** — El modelo distingue la **seguridad *de* la nube** de la **seguridad *en* la nube**. AWS es responsable de la infraestructura de cifrado: operar KMS, proteger el material de claves en HSM, asegurar que la implementación criptográfica sea correcta, y asegurar físicamente los medios. El cliente es responsable de la *decisión de configuración*: si el cifrado está habilitado siquiera, qué clave se usa (administrada por AWS contra administrada por el cliente), a quién se le otorga `kms:Decrypt` en la política de claves, y si la clave se rota. AWS con todo gusto va a correr una instancia RDS sin cifrar para vos — habilitar el cifrado es una elección que solo vos podés hacer, y en RDS debe hacerse **en el momento de la creación** de la instancia, que es precisamente por lo cual aparece en la llamada `create-db-instance` del Ejercicio 2 y no en un `modify` posterior.

**A8.3** — El principio es que **AWS es responsable del servicio; el cliente es responsable de cómo se usa el servicio.** Un esquema codifica significado de negocio — qué es un pedido, qué campos importan, qué patrones de acceso va a emitir la aplicación — y ese conocimiento existe solamente del lado del cliente de la línea. Ninguna cantidad de automatización cambia esto, que es por lo cual es responsabilidad del cliente en EC2, en RDS y en DynamoDB por igual, y por lo cual es también la fila donde se cometen los errores más caros. Una partition key de DynamoDB mal elegida o un índice faltante cuesta más en producción que cualquier error de dimensionamiento de instancia, y es lo único que ningún servicio administrado te va a arreglar jamás.

---

## Bloque 10 — Ejercicio de escenarios

1. **Amazon Neptune** — la travesía de relaciones de profundidad variable ("dentro de dos grados") es la consulta de grafo por definición; en SQL es una cadena ilimitada de self-joins.
2. **Amazon Aurora PostgreSQL** — la compatibilidad de protocolo con PostgreSQL significa cambios mínimos en la aplicación; Aurora aporta el margen de throughput, hasta 15 readers sobre almacenamiento compartido, y ~30 s de failover.
3. **Amazon DynamoDB** (capacidad on-demand) — acceso clave-valor por ID de jugador, on-demand absorbe un pico de lanzamiento de 0→1 M peticiones/s sin planificación de capacidad, y no hay base de datos que administrar.
4. **Amazon Redshift** — 8 TB de análisis de tendencias históricas es OLAP de manual; correrlo en la base de datos transaccional es lo que "sin ralentizar el sistema transaccional" está descartando. (Redshift Serverless si la carga de consultas es intermitente.)
5. **AWS SCT + AWS DMS con CDC** — heterogénea (SQL Server → PostgreSQL), así que SCT convierte primero el esquema y el código; la carga completa de DMS más CDC mantiene el origen en línea y comprime la interrupción a la ventana de cutover.
6. **Amazon MemoryDB** — compatible con Redis *y* durable. ElastiCache es la respuesta trampa: satisfaría "compatible con Redis" y fallaría en "perder una escritura es inaceptable".
7. **Amazon Timestream** — series temporales de alta ingesta con consultas de agregación por ventana temporal; particionamiento temporal construido a propósito, escalonamiento automático de memoria a almacén magnético, y funciones nativas de series temporales.
8. **Amazon DocumentDB** — compatibilidad con la API de MongoDB con replica sets, sharding, parcheo y backups manejados por AWS.
9. **Amazon RDS Custom for Oracle** — la única opción administrada que otorga acceso al host a nivel de sistema operativo para el agente del proveedor. (Oracle autoadministrado en EC2 también funciona técnicamente, pero RDS Custom es la respuesta correcta porque conserva los backups y la automatización administrados.)
10. **Amazon Athena** — dos veces por mes sobre datos que ya están en S3. Aprovisionar un cluster de Redshift que queda ocioso 29 días al mes es la forma económica equivocada; Athena factura por TB escaneado sin nada corriendo en el medio.

</details>

---

## Ficha de repaso para el día del examen

- **RDS** = relacional administrado, 8 familias de motores. **Multi-AZ = disponibilidad** (síncrono, standby invisible, sin lecturas). **Read replica = escalado** (asíncrona, endpoint propio, legible).
- **Aurora** = compatible con MySQL/PostgreSQL, almacenamiento distribuido compartido, **6 copias / 3 AZ**, 15 readers, ~30 s de failover, tres tipos de endpoint. **Serverless v2** para carga con picos o intermitente. **Global Database** = entre regiones, un solo writer.
- **DynamoDB** = clave-valor/documental serverless, milisegundos de un solo dígito, on-demand o aprovisionado. **`scan` factura por `ScannedCount`.** Consistencia fuerte = 2× las RCU. **DAX** para microsegundos. **Global tables = activo-activo.**
- **ElastiCache** = caché, volátil, Valkey/Redis/Memcached. **MemoryDB** = base de datos primaria durable compatible con Redis.
- **Construidos a propósito:** Neptune (grafos) · DocumentDB (documental, compatible con MongoDB) · Keyspaces (columna ancha, compatible con Cassandra) · Timestream (series temporales) · Redshift (data warehouse columnar, OLAP).
- **Migración:** homogénea → DMS. Heterogénea → **SCT y después DMS**. CDC → casi cero tiempo de inactividad.
- **Trampas:** S3 es almacenamiento de objetos, no una base de datos. Athena es un motor de consultas, no una base de datos. ElastiCache nunca es el sistema de registro. QLDB está retirado (fin de soporte el 31 de julio de 2025).
- **Constante en todos los servicios:** el diseño del esquema y de los patrones de acceso siempre es tuyo.

---

### Fuentes de referencia

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon RDS User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html>
- Amazon Aurora User Guide — <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html>
- Amazon DynamoDB Developer Guide — <https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html>
- Amazon ElastiCache User Guide — <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.html>
- Amazon MemoryDB Developer Guide — <https://docs.aws.amazon.com/memorydb/latest/devguide/what-is-memorydb.html>
- Amazon DocumentDB Developer Guide — <https://docs.aws.amazon.com/documentdb/latest/developerguide/what-is.html>
- Amazon Neptune User Guide — <https://docs.aws.amazon.com/neptune/latest/userguide/intro.html>
- Amazon Keyspaces Developer Guide — <https://docs.aws.amazon.com/keyspaces/latest/devguide/what-is-keyspaces.html>
- Amazon Timestream Developer Guide — <https://docs.aws.amazon.com/timestream/latest/developerguide/what-is-timestream.html>
- Amazon Redshift Management Guide — <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- AWS Database Migration Service User Guide — <https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>
- AWS Schema Conversion Tool User Guide — <https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html>
- AWS Shared Responsibility Model — <https://aws.amazon.com/compliance/shared-responsibility-model/>