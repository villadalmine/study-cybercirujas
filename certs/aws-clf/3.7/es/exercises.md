# Tema 3.7 — Servicios de IA/ML y de analítica

## Ejercicios guiados — AWS Certified Cloud Practitioner (CLF-C02, v1.0)

> **Dominio 3, Tarea 3.7** — *Identificar los servicios de inteligencia artificial y machine learning (IA/ML) de AWS y los servicios de analítica.* Peso en el examen: **4,25%** (Dominio 3 = 34%, repartido entre ocho tareas).
>
> El examen te pide **identificar** el servicio correcto para una carga de trabajo descrita. No te pide entrenar un modelo ni ajustar un job de Spark. Pero la identificación aprendida de una presentación se evapora bajo la presión del examen, porque los distractores son los servicios *vecinos*: Kinesis Data Streams vs. Data Firehose, Athena vs. Redshift, Rekognition vs. Textract. Estos ejercicios te hacen tocar cada servicio desde la CLI para que la frontera entre vecinos sea algo que viste, no algo que memorizaste.

---

## Convenciones del laboratorio y requisitos previos

Necesitás:

| Requisito | Comprobación |
|---|---|
| Una cuenta de AWS propia o que estés autorizado a usar | — |
| AWS CLI **v2** instalada | `aws --version` → `aws-cli/2.x.x …` |
| Un principal de IAM con permisos tipo admin para el laboratorio | `aws sts get-caller-identity` |
| `jq` | `jq --version` |
| Región `us-east-1` (la mayor cobertura de servicios de IA/ML) | `aws configure get region` |

**Costo.** Todo lo que sigue está diseñado para ejecutarse por **bastante menos de US$1**, y la mayor parte dentro del Free Tier. Las dos líneas que pueden sorprenderte:

| Servicio | Qué pagás en este laboratorio | Orden de magnitud |
|---|---|---|
| Amazon Athena | Por **TB escaneado**, con un mínimo de 10 MB por consulta | ~$5.00 / TB → nuestras consultas cuestan fracciones de centavo |
| AWS Glue crawler | Por **DPU-hora**, por segundo, con un mínimo de 10 minutos | ~$0.44 / DPU-hora → ~$0.07 por ejecución del crawler |
| Amazon Data Firehose | Por **GB ingerido** | ~$0.029 / GB → efectivamente $0 para 30 registros |
| Comprehend / Translate / Polly / Rekognition / Textract / Transcribe | El Free Tier cubre este laboratorio con holgura | ~$0 |
| Amazon Bedrock | Por **token**, bajo demanda | < $0.01 por un prompt corto |
| Amazon S3 | Almacenamiento + solicitudes | < $0.01 |

**El Ejercicio 8 es el desmantelamiento. No lo saltees.** Un delivery stream de Firehose olvidado es inofensivo; un clúster de Redshift o un dominio de OpenSearch olvidados no lo son — que es exactamente la razón por la que este laboratorio nunca crea ninguno.

Prepará tu shell una sola vez:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="clf37-lab-${ACCOUNT_ID}"
export DB=clf37
echo "account=$ACCOUNT_ID bucket=$BUCKET region=$AWS_REGION"
```

---

## Ejercicio 0 — Preflight: identidad, región y una barrera de costo

Un arquitecto de producción nunca arranca un laboratorio sin una alarma de presupuesto. Vos tampoco.

1. **Confirmá quién sos y dónde estás.** La región importa más para IA/ML que para casi cualquier otra categoría: los servicios y los modelos no están disponibles en todas partes.

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDAEXAMPLEEXAMPLE1",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/lab-admin"
   }
   ```

2. **Creá el bucket del laboratorio.** S3 es el sustrato bajo todos los servicios de analítica y la mayoría de los de IA de este tema: el data lake, la ubicación de resultados de Athena, el destino de Firehose y la entrada para Rekognition, Textract y Transcribe.

   ```bash
   aws s3 mb "s3://${BUCKET}" --region "$AWS_REGION"
   ```

   ```
   make_bucket: clf37-lab-123456789012
   ```

3. **Creá un presupuesto mensual de $5 con una alerta por correo**, para que cualquier error en este laboratorio te llegue a vos antes que a tu tarjeta.

   ```bash
   cat > /tmp/budget.json <<'EOF'
   {
     "BudgetName": "clf37-lab-guardrail",
     "BudgetLimit": { "Amount": "5", "Unit": "USD" },
     "TimeUnit": "MONTHLY",
     "BudgetType": "COST"
   }
   EOF

   cat > /tmp/notify.json <<'EOF'
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
   EOF

   aws budgets create-budget \
     --account-id "$ACCOUNT_ID" \
     --budget file:///tmp/budget.json \
     --notifications-with-subscribers file:///tmp/notify.json
   ```

   Sin salida si tiene éxito. Verificá:

   ```bash
   aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
     --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount}' --output table
   ```

   ```
   ----------------------------------------
   |            DescribeBudgets           |
   +----------------------+---------------+
   |         Limit        |     Name      |
   +----------------------+---------------+
   |  5.0                 | clf37-lab-... |
   +----------------------+---------------+
   ```

**Comprobación de comprensión — Bloque 0**

- **Q0.1** AWS Budgets no es un servicio de analítica en el sentido de la guía del examen, y sin embargo aparece en casi todo laboratorio bien arquitecturado. ¿A qué categoría del Dominio 3 pertenece, y qué *pilar* de la gestión de costos implementa una alerta de presupuesto: visibilidad, control u optimización?
- **Q0.2** Ejecutaste `aws s3 mb` con `--region us-east-1`. ¿Por qué importa la región de este bucket para los pasos de Rekognition y Textract más adelante, pero *no* para el paso de Comprehend?
- **Q0.3** ¿Por qué S3 — un servicio de almacenamiento, cubierto en la tarea 3.6 — es el punto de partida correcto para un laboratorio de la tarea 3.7?

---

## Ejercicio 1 — El núcleo de analítica serverless: S3 + AWS Glue + Amazon Athena

Este es el patrón más relevante para el examen de todo el tema: **S3 es el data lake, Glue es el catálogo y el ETL, Athena es el motor de consultas SQL.** Aprendé este triángulo y la mitad de las preguntas de analítica se responden solas.

### 1a. Poné datos crudos en el lake

1. Generá un CSV pequeño de pedidos de e-commerce.

   ```bash
   cat > /tmp/orders.csv <<'EOF'
   order_id,order_ts,region,category,units,unit_price_usd
   1001,2026-09-01T09:14:02Z,us-east-1,laptops,2,1299.00
   1002,2026-09-01T09:41:55Z,eu-west-1,monitors,4,219.50
   1003,2026-09-01T10:02:11Z,us-east-1,keyboards,11,89.99
   1004,2026-09-02T11:20:00Z,ap-south-1,laptops,1,1499.00
   1005,2026-09-02T12:00:47Z,eu-west-1,laptops,3,1299.00
   1006,2026-09-02T14:33:20Z,us-east-1,monitors,7,219.50
   1007,2026-09-03T08:05:09Z,ap-south-1,keyboards,25,89.99
   1008,2026-09-03T16:44:31Z,us-east-1,laptops,5,1349.00
   EOF

   aws s3 cp /tmp/orders.csv "s3://${BUCKET}/raw/orders/orders.csv"
   ```

   ```
   upload: /tmp/orders.csv to s3://clf37-lab-123456789012/raw/orders/orders.csv
   ```

   > **Detalle de producción:** el objeto está bajo un **prefijo** `raw/orders/`, no en la raíz del bucket. Un crawler de Glue apunta a un prefijo y trata *todos los objetos bajo él* como una sola tabla. Un objeto dejado en la raíz obligaría al crawler a catalogar el bucket entero — incluidos tus archivos de resultados de Athena, que es una herida autoinfligida clásica.

2. **No se "ingirió" nada.** Confirmá que los datos simplemente están ahí, en almacenamiento de objetos: sin clúster, sin base de datos, sin paso de carga:

   ```bash
   aws s3 ls "s3://${BUCKET}/raw/orders/" --human-readable
   ```

   ```
   2026-09-04 12:01:33  512 Bytes orders.csv
   ```

### 1b. Catalogalo con AWS Glue

3. Creá la **base de datos** de Glue — un contenedor lógico de *metadatos* de tablas. No contiene datos.

   ```bash
   aws glue create-database --database-input "{\"Name\":\"${DB}\"}"
   aws glue get-database --name "$DB" --query 'Database.{Name:Name,Created:CreateTime}'
   ```

   ```json
   {
       "Name": "clf37",
       "Created": "2026-09-04T12:03:10-03:00"
   }
   ```

4. Creá el rol de IAM que asumirá el crawler. Fijate en los dos adjuntos: acá es donde fallan la mayoría de las primeras ejecuciones de un crawler.

   ```bash
   aws iam create-role --role-name AWSGlueServiceRole-clf37 \
     --assume-role-policy-document '{
       "Version":"2012-10-17",
       "Statement":[{"Effect":"Allow",
         "Principal":{"Service":"glue.amazonaws.com"},
         "Action":"sts:AssumeRole"}]}' \
     --query 'Role.Arn' --output text
   ```

   ```
   arn:aws:iam::123456789012:role/AWSGlueServiceRole-clf37
   ```

   ```bash
   aws iam attach-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

   aws iam put-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-name LabBucketRead \
     --policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{
         \"Effect\":\"Allow\",
         \"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
         \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}"
   ```

   > **¿Por qué la política inline?** La política administrada por AWS `AWSGlueServiceRole` otorga acceso a S3 **solo a los buckets cuyo nombre empieza con `aws-glue-`**. El nuestro no. Saltear este paso produce un crawler que se ejecuta, tiene éxito y crea cero tablas — una falla silenciosa que le costó una tarde a muchos ingenieros.

5. Creá e iniciá el crawler.

   ```bash
   aws glue create-crawler \
     --name clf37-orders-crawler \
     --role AWSGlueServiceRole-clf37 \
     --database-name "$DB" \
     --targets "{\"S3Targets\":[{\"Path\":\"s3://${BUCKET}/raw/orders/\"}]}"

   aws glue start-crawler --name clf37-orders-crawler
   ```

6. Consultá en bucle hasta que vuelva a `READY` (típicamente 60–120 s — el crawler tiene un arranque en frío).

   ```bash
   while true; do
     STATE=$(aws glue get-crawler --name clf37-orders-crawler --query 'Crawler.State' --output text)
     echo "$(date +%T) $STATE"
     [ "$STATE" = "READY" ] && break
     sleep 15
   done
   ```

   ```
   12:06:11 RUNNING
   12:06:26 RUNNING
   12:06:41 STOPPING
   12:06:56 READY
   ```

7. Inspeccioná lo que el crawler **infirió**. Leyó los objetos y derivó un esquema — vos nunca escribiste un `CREATE TABLE`.

   ```bash
   aws glue get-table --database-name "$DB" --name orders \
     --query 'Table.StorageDescriptor.Columns[].{Column:Name,Type:Type}' --output table
   ```

   ```
   ----------------------------------
   |            GetTable            |
   +-------------------+------------+
   |      Column       |    Type    |
   +-------------------+------------+
   |  order_id         |  bigint    |
   |  order_ts         |  string    |
   |  region           |  string    |
   |  category         |  string    |
   |  units            |  bigint    |
   |  unit_price_usd   |  double    |
   +-------------------+------------+
   ```

**Comprobación de comprensión — Bloque 1a/1b**

- **Q1.1** El Glue Data Catalog ahora contiene una tabla llamada `orders`. ¿Dónde viven físicamente las *filas* de esa tabla? ¿Qué destruiría `aws glue delete-table`?
- **Q1.2** El crawler tipó `order_ts` como `string`, no como `timestamp`. ¿Qué te dice eso sobre la *inferencia* de esquema frente a la *definición* de esquema, y cuál de las dos es "schema-on-read"?
- **Q1.3** Nombrá los dos roles distintos que juega AWS Glue en esta arquitectura. (Pista: uno de ellos ya lo usaste; el otro es a lo que se refiere el "ETL" del marketing de Glue.)
- **Q1.4** Un colega dice "tenemos que cargar el CSV en Glue antes de poder consultarlo". Corregí la afirmación en una oración.

### 1c. Consultalo con Athena

8. Ejecutá una consulta SQL contra S3. No hay clúster que arrancar ni endpoint al que conectarse.

   ```bash
   QID=$(aws athena start-query-execution \
     --work-group primary \
     --query-string "SELECT region, SUM(units * unit_price_usd) AS revenue_usd
                     FROM ${DB}.orders GROUP BY region ORDER BY revenue_usd DESC" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)
   echo "$QID"
   ```

   ```
   8f0c1a4e-2b77-4a51-9c3e-1de6a2c4b900
   ```

9. Consultá el estado hasta que termine y leé las **estadísticas**, no solo las filas. Las estadísticas son todo el modelo de precios.

   ```bash
   aws athena get-query-execution --query-execution-id "$QID" \
     --query 'QueryExecution.{State:Status.State,ScannedBytes:Statistics.DataScannedInBytes,Millis:Statistics.TotalExecutionTimeInMillis}'
   ```

   ```json
   {
       "State": "SUCCEEDED",
       "ScannedBytes": 512,
       "Millis": 1284
   }
   ```

10. Traé los resultados.

    ```bash
    aws athena get-query-results --query-execution-id "$QID" \
      --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
    ```

    ```
    region  revenue_usd
    us-east-1       12036.87
    eu-west-1       4775.00
    ap-south-1      3748.75
    ```

11. **Sentí el modelo de precios.** Athena factura por byte escaneado. Creá una copia columnar y comprimida de los mismos datos con CTAS (Create Table As Select) — esta es la optimización de costo con mayor apalancamiento de todo el servicio.

    ```bash
    QID2=$(aws athena start-query-execution \
      --work-group primary \
      --query-string "CREATE TABLE ${DB}.orders_parquet
                      WITH (format='PARQUET',
                            external_location='s3://${BUCKET}/curated/orders_parquet/')
                      AS SELECT * FROM ${DB}.orders" \
      --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
      --query QueryExecutionId --output text)

    sleep 20
    aws athena get-query-execution --query-execution-id "$QID2" \
      --query 'QueryExecution.Status.State' --output text
    ```

    ```
    SUCCEEDED
    ```

12. Consultá una columna de cada tabla y compará los bytes escaneados.

    ```bash
    for T in orders orders_parquet; do
      Q=$(aws athena start-query-execution --work-group primary \
        --query-string "SELECT SUM(units) FROM ${DB}.${T}" \
        --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
        --query QueryExecutionId --output text)
      sleep 8
      B=$(aws athena get-query-execution --query-execution-id "$Q" \
        --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)
      echo "${T}: ${B} bytes scanned"
    done
    ```

    ```
    orders: 512 bytes scanned
    orders_parquet: 74 bytes scanned
    ```

    > Con 512 bytes el ahorro es un error de redondeo. Con 5 TB de logs en CSV es la diferencia entre una consulta de $25 y una de $0.40, ejecutada cientos de veces por día. El examen no te va a pedir que calcules esto, pero *sí* te va a preguntar "¿cómo reducís el costo de Athena?" — y la respuesta es formato columnar, compresión y particionado.

**Comprobación de comprensión — Bloque 1c**

- **Q1.5** El precio de Athena se cotiza por terabyte escaneado. Nombrá tres formas de reducir ese número sin cambiar el SQL.
- **Q1.6** Nunca aprovisionaste una instancia, un nodo ni un clúster para Athena. ¿Qué lo convierte eso, en el vocabulario de modelos de servicio de la propia AWS, y cuál es la consecuencia operativa para un equipo sin ingenieros de datos?
- **Q1.7** Un equipo ejecuta la *misma* consulta de dashboard 400 veces por hora sobre 2 TB de datos, todo el día, todos los días. Athena ahora es la herramienta equivocada. ¿A qué servicio de analítica deberían moverse, y cuál es la diferencia económica fundamental entre ambos?
- **Q1.8** Athena necesitó un `--result-configuration OutputLocation`. ¿Adónde van los resultados de las consultas de Athena, y por qué eso es a veces una cuestión de gobernanza más que técnica?

---

## Ejercicio 2 — Ingesta de streaming: Amazon Data Firehose

La familia de streaming del examen es chica pero las distinciones son filosas. Firehose es el **fácil**: sin consumidores que escribir, sin shards que gestionar, entrega casi en tiempo real directo a un destino.

1. Creá el rol de entrega que Firehose asumirá para escribir en tu bucket.

   ```bash
   aws iam create-role --role-name FirehoseToS3-clf37 \
     --assume-role-policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{\"Effect\":\"Allow\",
         \"Principal\":{\"Service\":\"firehose.amazonaws.com\"},
         \"Action\":\"sts:AssumeRole\",
         \"Condition\":{\"StringEquals\":{\"sts:ExternalId\":\"${ACCOUNT_ID}\"}}}]}" \
     --query 'Role.Arn' --output text

   aws iam put-role-policy --role-name FirehoseToS3-clf37 \
     --policy-name WriteLabBucket \
     --policy-document "{
       \"Version\":\"2012-10-17\",
       \"Statement\":[{
         \"Effect\":\"Allow\",
         \"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",
                     \"s3:GetObject\",\"s3:ListBucket\",
                     \"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],
         \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}"

   sleep 10   # IAM is eventually consistent; Firehose creation fails if you race it
   ```

2. Creá el delivery stream con origen **DirectPut** y destino S3.

   ```bash
   cat > /tmp/fh.json <<EOF
   {
     "RoleARN": "arn:aws:iam::${ACCOUNT_ID}:role/FirehoseToS3-clf37",
     "BucketARN": "arn:aws:s3:::${BUCKET}",
     "Prefix": "stream/clicks/",
     "ErrorOutputPrefix": "stream/errors/",
     "BufferingHints": { "SizeInMBs": 1, "IntervalInSeconds": 60 },
     "CompressionFormat": "UNCOMPRESSED"
   }
   EOF

   aws firehose create-delivery-stream \
     --delivery-stream-name clf37-clicks \
     --delivery-stream-type DirectPut \
     --extended-s3-destination-configuration file:///tmp/fh.json \
     --query DeliveryStreamARN --output text
   ```

   ```
   arn:aws:firehose:us-east-1:123456789012:deliverystream/clf37-clicks
   ```

3. Esperá a `ACTIVE`.

   ```bash
   aws firehose describe-delivery-stream --delivery-stream-name clf37-clicks \
     --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text
   ```

   ```
   ACTIVE
   ```

4. Enviá 30 registros. Leé los dos detalles de producción del comentario antes de ejecutarlo.

   ```bash
   for i in $(seq 1 30); do
     line=$(printf '{"ts":"%s","user":"u%s","page":"/pricing","latency_ms":%s}' \
             "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((i % 5))" "$((150 + i * 7))")
     aws firehose put-record \
       --cli-binary-format raw-in-base64-out \
       --delivery-stream-name clf37-clicks \
       --record "$(jq -nc --arg d "$line" '{Data: ($d + "\n")}')" \
       --query RecordId --output text >/dev/null
   done
   echo "30 records sent"
   ```

   ```
   30 records sent
   ```

   > **Detalle 1 — `--cli-binary-format raw-in-base64-out`.** `Record.Data` es un *blob*. La AWS CLI v2 espera por defecto que los argumentos blob estén codificados en base64; este flag le indica que acepte texto crudo. Sin él obtenés `Invalid base64` o, peor, registros silenciosamente corruptos.
   >
   > **Detalle 2 — el `\n` agregado.** Firehose concatena los registros en un objeto byte a byte, **sin delimitador propio**. Si omitís el salto de línea, los 30 documentos JSON aterrizan como una sola línea imposible de parsear y Athena devuelve cero filas sobre un archivo visiblemente lleno de datos. Este es uno de los bugs de Firehose-a-Athena más comunes del mundo real.

5. Esperá a que se vacíe el búfer (60 s o 1 MB, lo que ocurra primero) y mirá lo que aterrizó.

   ```bash
   sleep 90
   aws s3 ls "s3://${BUCKET}/stream/clicks/" --recursive
   ```

   ```
   2026-09-04 12:22:41       2130 stream/clicks/2026/09/04/15/clf37-clicks-1-2026-09-04-15-21-08-9f0a...
   ```

6. Confirmá que el delimitado por saltos de línea funcionó.

   ```bash
   aws s3 cp "s3://${BUCKET}/$(aws s3api list-objects-v2 --bucket "$BUCKET" \
     --prefix stream/clicks/ --query 'Contents[0].Key' --output text)" - | head -3
   ```

   ```
   {"ts":"2026-09-04T15:21:03Z","user":"u1","page":"/pricing","latency_ms":157}
   {"ts":"2026-09-04T15:21:04Z","user":"u2","page":"/pricing","latency_ms":164}
   {"ts":"2026-09-04T15:21:05Z","user":"u3","page":"/pricing","latency_ms":171}
   ```

7. Consultá la salida del stream con Athena, cerrando el círculo con el Ejercicio 1. Esta vez definí la tabla a mano — schema-on-read, sin crawler.

   ```bash
   QID3=$(aws athena start-query-execution --work-group primary \
     --query-string "CREATE EXTERNAL TABLE IF NOT EXISTS ${DB}.clicks (
                       ts string, user string, page string, latency_ms int)
                     ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
                     LOCATION 's3://${BUCKET}/stream/clicks/'" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)

   sleep 10

   QID4=$(aws athena start-query-execution --work-group primary \
     --query-string "SELECT user, COUNT(*) n, AVG(latency_ms) avg_ms
                     FROM ${DB}.clicks GROUP BY user ORDER BY user" \
     --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/" \
     --query QueryExecutionId --output text)

   sleep 10
   aws athena get-query-results --query-execution-id "$QID4" \
     --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
   ```

   ```
   user    n       avg_ms
   u0      6       234.0
   u1      6       206.5
   u2      6       213.5
   u3      6       220.5
   u4      6       227.5
   ```

**Comprobación de comprensión — Bloque 2**

- **Q2.1** No escribiste **ninguna aplicación consumidora** y no gestionaste **ningún shard**. Enunciá la única oración que distingue Amazon Data Firehose de Amazon Kinesis Data Streams.
- **Q2.2** Los registros tardaron hasta 60 segundos en aparecer en S3. ¿Firehose es "tiempo real"? ¿Cuál es el término correcto, y qué parámetros de buffering lo controlan?
- **Q2.3** Una plataforma de trading necesita procesamiento personalizado sub-segundo de un feed de mercado, con capacidad de reproducir las últimas 24 horas de eventos y que tres aplicaciones independientes consuman el mismo stream. ¿Firehose o Data Streams? Justificá con dos propiedades.
- **Q2.4** El equipo ya opera Apache Kafka on-premises y quiere llevarlo a AWS con la mínima reescritura de aplicaciones. ¿Qué servicio, y por qué no es Kinesis?
- **Q2.5** Ahora quieren una agregación continua con ventana tumbling de 5 minutos sobre ese stream, escrita en SQL o Apache Flink, antes de que los datos aterricen en ningún lado. ¿Qué servicio?
- **Q2.6** Nombrá el miembro de la familia Kinesis diseñado para ingerir y procesar feeds de **video** de cámaras conectadas.

---

## Ejercicio 3 — Servicios de IA preentrenados: el nivel "no se requiere experiencia en ML"

El nivel de servicios de IA se define por una única propiedad: **enviás datos a una API y recibís una inferencia.** Sin datos de entrenamiento, sin modelo, sin conocimiento de ML. El examen evalúa si podés mapear una frase de negocio a la API correcta.

### 3a. Amazon Comprehend — NLP sobre texto

1. Sentimiento.

   ```bash
   aws comprehend detect-sentiment --language-code en \
     --text "The checkout page timed out three times and support never answered. Terrible."
   ```

   ```json
   {
       "Sentiment": "NEGATIVE",
       "SentimentScore": {
           "Positive": 0.0011,
           "Negative": 0.9942,
           "Neutral": 0.0044,
           "Mixed": 0.0003
       }
   }
   ```

2. Entidades.

   ```bash
   aws comprehend detect-entities --language-code en \
     --text "Ana Ruiz opened a support case with Contoso Ltd in Barcelona on 3 September 2026." \
     --query 'Entities[].{Text:Text,Type:Type,Score:Score}' --output table
   ```

   ```
   ------------------------------------------------------
   |                   DetectEntities                   |
   +---------------+--------------+---------------------+
   |     Score     |     Text     |        Type         |
   +---------------+--------------+---------------------+
   |  0.9994       |  Ana Ruiz    |  PERSON             |
   |  0.9971       |  Contoso Ltd |  ORGANIZATION       |
   |  0.9988       |  Barcelona   |  LOCATION           |
   |  0.9932       |  3 September 2026 | DATE           |
   +---------------+--------------+---------------------+
   ```

3. Detección de PII — la llamada con sabor a cumplimiento que aparece en las preguntas de gobernanza.

   ```bash
   aws comprehend detect-pii-entities --language-code en \
     --text "Contact me at ana.ruiz@example.com or on +34 600 123 456." \
     --query 'Entities[].Type' --output text
   ```

   ```
   EMAIL   PHONE
   ```

4. Identificación de idioma — fijate que acá **no** pasás un código de idioma.

   ```bash
   aws comprehend detect-dominant-language \
     --text "El pedido llegó roto y nadie contestó el correo." \
     --query 'Languages[0]'
   ```

   ```json
   {
       "LanguageCode": "es",
       "Score": 0.9989
   }
   ```

### 3b. Amazon Translate — traducción automática

5. ```bash
   aws translate translate-text \
     --source-language-code auto \
     --target-language-code en \
     --text "El pedido llegó roto y nadie contestó el correo." \
     --query '{Out:TranslatedText,Detected:SourceLanguageCode}'
   ```

   ```json
   {
       "Out": "The order arrived broken and no one answered the email.",
       "Detected": "es"
   }
   ```

   > `--source-language-code auto` hace que Translate invoque internamente la detección de idioma de Comprehend. Este es un patrón de composición real, no un truco: los servicios de IA están diseñados para encadenarse.

### 3c. Amazon Polly — texto a voz

6. ```bash
   aws polly synthesize-speech \
     --engine neural \
     --voice-id Joanna \
     --output-format mp3 \
     --text "Your order number 1008 has shipped and arrives on Friday." \
     /tmp/speech.mp3
   ```

   ```json
   {
       "ContentType": "audio/mpeg",
       "RequestCharacters": "57"
   }
   ```

7. Mirá qué voces existen — evidencia de que esto es un catálogo de modelos preentrenados, no algo que entrenás.

   ```bash
   aws polly describe-voices --language-code en-US \
     --query 'Voices[?SupportedEngines[?@==`neural`]].{Id:Id,Gender:Gender}' --output table
   ```

   ```
   ---------------------------
   |     DescribeVoices      |
   +----------+--------------+
   |  Gender  |      Id      |
   +----------+--------------+
   |  Female  |  Danielle    |
   |  Male    |  Gregory     |
   |  Female  |  Ivy         |
   |  Female  |  Joanna      |
   |  Female  |  Kendra      |
   |  Male    |  Matthew     |
   |  ...     |  ...         |
   +----------+--------------+
   ```

### 3d. Amazon Transcribe — voz a texto (cerrando el círculo con Polly)

8. Subí el audio que acaba de producir Polly y transcribilo de vuelta.

   ```bash
   aws s3 cp /tmp/speech.mp3 "s3://${BUCKET}/audio/speech.mp3"

   aws transcribe start-transcription-job \
     --transcription-job-name clf37-job-1 \
     --language-code en-US \
     --media "MediaFileUri=s3://${BUCKET}/audio/speech.mp3" \
     --output-bucket-name "$BUCKET" \
     --output-key "transcripts/" \
     --query 'TranscriptionJob.TranscriptionJobStatus' --output text
   ```

   ```
   IN_PROGRESS
   ```

9. Consultá el estado en bucle — Transcribe es **batch asincrónico**, a diferencia de todo lo demás en este ejercicio.

   ```bash
   while true; do
     S=$(aws transcribe get-transcription-job --transcription-job-name clf37-job-1 \
          --query 'TranscriptionJob.TranscriptionJobStatus' --output text)
     echo "$(date +%T) $S"
     [ "$S" != "IN_PROGRESS" ] && break
     sleep 15
   done

   aws s3 cp "s3://${BUCKET}/transcripts/clf37-job-1.json" - | jq -r '.results.transcripts[0].transcript'
   ```

   ```
   12:41:07 IN_PROGRESS
   12:41:22 IN_PROGRESS
   12:41:37 COMPLETED
   Your order number 1008 has shipped and arrives on Friday.
   ```

### 3e. Amazon Rekognition — visión por computadora

10. Subí cualquier fotografía propia (JPEG o PNG, de menos de 15 MB) y etiquetala.

    ```bash
    aws s3 cp ~/Pictures/photo.jpg "s3://${BUCKET}/images/photo.jpg"

    aws rekognition detect-labels \
      --image "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"images/photo.jpg\"}}" \
      --max-labels 8 \
      --query 'Labels[].{Label:Name,Confidence:Confidence}' --output table
    ```

    ```
    -------------------------------
    |         DetectLabels        |
    +-------------+---------------+
    | Confidence  |     Label     |
    +-------------+---------------+
    |  99.4       |  Person       |
    |  98.7       |  Clothing     |
    |  95.1       |  Outdoors     |
    |  91.6       |  City         |
    |  88.0       |  Building     |
    +-------------+---------------+
    ```

11. Moderación de contenido — el mismo servicio, otra API, otro problema de negocio.

    ```bash
    aws rekognition detect-moderation-labels \
      --image "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"images/photo.jpg\"}}" \
      --query 'ModerationLabels'
    ```

    ```json
    []
    ```

    > **Trampa de región:** el bucket de S3 debe estar en la **misma región** que el endpoint de Rekognition al que llamás. Un objeto en otra región devuelve `InvalidS3ObjectException`, cuyo mensaje no menciona las regiones en absoluto.

### 3f. Amazon Textract — texto y estructura de documentos

12. Subí cualquier factura escaneada, recibo o PDF de una página que tengas y extraé el texto.

    ```bash
    aws s3 cp ~/Documents/invoice.png "s3://${BUCKET}/docs/invoice.png"

    aws textract detect-document-text \
      --document "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"docs/invoice.png\"}}" \
      --query 'Blocks[?BlockType==`LINE`].Text' --output text | head -8
    ```

    ```
    ACME SUPPLIES S.L.
    Invoice #  INV-2026-0912
    Date 2026-09-01
    Bill To: Contoso Ltd
    Description  Qty  Unit  Amount
    Laptop stand  2  39.00  78.00
    Subtotal  78.00
    Total EUR  94.38
    ```

13. Pedí estructura, no solo caracteres — esta es la línea entre Textract y el OCR común.

    ```bash
    aws textract analyze-document \
      --document "{\"S3Object\":{\"Bucket\":\"${BUCKET}\",\"Name\":\"docs/invoice.png\"}}" \
      --feature-types '["FORMS","TABLES"]' \
      --query 'Blocks[].BlockType' --output text | tr '\t' '\n' | sort | uniq -c
    ```

    ```
        14 CELL
         1 PAGE
        22 LINE
         9 KEY_VALUE_SET
         2 TABLE
        61 WORD
    ```

**Comprobación de comprensión — Bloque 3**

- **Q3.1** Para cada uno de los seis servicios anteriores, escribí la frase disparadora de negocio de una línea que usaría una pregunta de examen. (por ej. "…quiere saber si los clientes están enojados" → ?)
- **Q3.2** Rekognition devolvió `Person` con 99,4% y `Building` con 88,0%. ¿Qué es ese número, y qué decisión de diseño le impone a la aplicación que consume la API?
- **Q3.3** Transcribe devolvió `IN_PROGRESS` y necesitó polling; Comprehend devolvió una respuesta de inmediato. ¿Qué diferencia arquitectónica refleja eso, y qué implica sobre cómo invocás a cada uno desde una función Lambda?
- **Q3.4** Un hospital quiere extraer diagnósticos y nombres de medicamentos de notas clínicas y, por separado, extraer campos de formularios escaneados de reclamos de seguros. Dos servicios distintos — nombrá ambos, y nombrá sus variantes especializadas en salud.
- **Q3.5** Distinguí, en una oración cada uno: **Amazon Textract**, **Amazon Rekognition** (API `detect-text`) y **Amazon Comprehend**. Los tres "leen texto". ¿Para qué sirve realmente cada uno?
- **Q3.6** Ninguno de estos servicios te exigió aportar datos de entrenamiento. ¿Qué compensación aceptaste a cambio, y a qué servicio te moverías si un modelo preentrenado no es lo bastante preciso para tu dominio?

---

## Ejercicio 4 — IA generativa: Amazon Bedrock (y dónde encaja Amazon Q)

Bedrock es la capa de acceso administrado a **modelos fundacionales** — Anthropic, Amazon, Meta, Mistral, Cohere, AI21, Stability y otros — detrás de una API, un límite de IAM y una factura.

1. Mirá el catálogo. Esta llamada no necesita concesión de acceso a modelos.

   ```bash
   aws bedrock list-foundation-models \
     --query 'modelSummaries[].{Provider:providerName,Model:modelId}' --output table | head -20
   ```

   ```
   ------------------------------------------------------------
   |                  ListFoundationModels                    |
   +-------------------------------+--------------------------+
   |            Model              |        Provider          |
   +-------------------------------+--------------------------+
   |  amazon.titan-embed-text-v2:0 |  Amazon                  |
   |  amazon.nova-lite-v1:0        |  Amazon                  |
   |  amazon.nova-pro-v1:0         |  Amazon                  |
   |  anthropic.claude-opus-5      |  Anthropic               |
   |  cohere.embed-english-v3      |  Cohere                  |
   |  meta.llama3-1-70b-instruct-v1:0 | Meta                  |
   |  mistral.mistral-large-2407-v1:0 | Mistral AI            |
   |  stability.sd3-5-large-v1:0   |  Stability AI            |
   +-------------------------------+--------------------------+
   ```

   > **Múltiples proveedores detrás de una sola API es el punto de Bedrock**, y es exactamente lo que quiere decir una pregunta de examen con "acceder a modelos fundacionales de Amazon y de empresas líderes en IA a través de una única API".

2. Contá cuántos proveedores ofrece tu región. Este es el argumento de "elección de modelo", verificado en vez de creído.

   ```bash
   aws bedrock list-foundation-models --query 'modelSummaries[].providerName' --output text \
     | tr '\t' '\n' | sort -u
   ```

3. Listá los **perfiles de inferencia** entre regiones. Varios modelos actuales se invocan mediante un ID de perfil (con prefijo geográfico, por ej. `us.`) en vez del ID de modelo desnudo — el perfil enruta tu solicitud entre regiones para conseguir capacidad.

   ```bash
   aws bedrock list-inference-profiles \
     --query 'inferenceProfileSummaries[].{Id:inferenceProfileId,Name:inferenceProfileName}' \
     --output table | head -12
   ```

4. **Concedé acceso a los modelos.** En una cuenta nueva, la invocación falla hasta que solicitás acceso a un modelo en la consola de Bedrock (*Model access* → *Modify model access*). Este es un paso solo-consola por diseño: implica la aceptación del EULA del proveedor. Intentar invocar sin él:

   ```
   An error occurred (AccessDeniedException) when calling the Converse operation:
   You don't have access to the model with the specified model ID.
   ```

5. Una vez concedido el acceso, invocá un modelo con la API **Converse** — el punto de entrada agnóstico al modelo.

   ```bash
   aws bedrock-runtime converse \
     --model-id "anthropic.claude-opus-5" \
     --messages '[{"role":"user","content":[{"text":"In one sentence: what does Amazon Athena charge for?"}]}]' \
     --inference-config '{"maxTokens":200,"temperature":0.2}' \
     --query '{Text:output.message.content[0].text,In:usage.inputTokens,Out:usage.outputTokens}'
   ```

   ```json
   {
       "Text": "Amazon Athena charges per terabyte of data scanned by each query, with a 10 MB minimum per query.",
       "In": 24,
       "Out": 23
   }
   ```

   > `usage.inputTokens` / `usage.outputTokens` **es la factura**. El precio bajo demanda de Bedrock es por token, por modelo. Si una pregunta menciona en cambio un throughput alto y predecible, la respuesta es **Provisioned Throughput**.

6. Cambiá el ID de modelo y volvé a ejecutar el comando idéntico. No cambia nada más — esa portabilidad es la propuesta de valor central de Bedrock.

   ```bash
   aws bedrock-runtime converse \
     --model-id "amazon.nova-lite-v1:0" \
     --messages '[{"role":"user","content":[{"text":"In one sentence: what does Amazon Athena charge for?"}]}]' \
     --inference-config '{"maxTokens":200}' \
     --query 'output.message.content[0].text' --output text
   ```

**Comprobación de comprensión — Bloque 4**

- **Q4.1** Bedrock se describe como "serverless". Dado que un modelo fundacional es uno de los artefactos más grandes de la computación, ¿qué es exactamente lo serverless de él, y qué *no* estás gestionando?
- **Q4.2** Tu empresa quiere un chatbot fundamentado en sus propios 40.000 PDF internos. Nombrá la capacidad de Bedrock que hace esto sin reentrenar un modelo, y nombrá el servicio *separado y totalmente administrado* de la guía del examen que hace búsqueda documental empresarial con el mismo objetivo.
- **Q4.3** Distinguí **Amazon Q Developer** de **Amazon Q Business** en una línea cada uno.
- **Q4.4** Un cliente regulado pregunta si sus prompts se usan para entrenar los modelos fundacionales subyacentes. ¿Cuál es la respuesta correcta para Bedrock, y sobre qué propiedad de seguridad del servicio se apoya?
- **Q4.5** Ordená estos tres según "cuánto trabajo de ML hago yo mismo", de menor a mayor: Amazon Rekognition, Amazon Bedrock, Amazon SageMaker AI.

---

## Ejercicio 5 — Amazon SageMaker AI: el nivel construilo-vos-mismo

SageMaker es el **único** servicio de este tema donde *vos* aportás los datos, elegís un algoritmo, entrenás y desplegás. Todo lo que creés acá cuesta dinero por hora-instancia, así que este ejercicio es deliberadamente de solo lectura.

1. Confirmá que no hay nada corriendo (y aprendé los verbos de la CLI que muestran dónde se esconde el costo).

   ```bash
   aws sagemaker list-domains --query 'Domains[].{Name:DomainName,Status:Status}' --output table
   aws sagemaker list-notebook-instances --query 'NotebookInstances[].{Name:NotebookInstanceName,Status:NotebookInstanceStatus,Type:InstanceType}' --output table
   aws sagemaker list-endpoints --query 'Endpoints[].{Name:EndpointName,Status:EndpointStatus}' --output table
   aws sagemaker list-training-jobs --max-results 5 --query 'TrainingJobSummaries[].{Name:TrainingJobName,Status:TrainingJobStatus}' --output table
   ```

   ```
   -------------------
   |   ListDomains   |
   +-----------------+
   |      None       |
   +-----------------+
   ```

   > **El endpoint es el caro.** Un endpoint de inferencia en tiempo real de SageMaker es una instancia aprovisionada que factura 24/7, la llame alguien o no. Que `list-endpoints` devuelva vacío es una auditoría de costos, no una formalidad. Si una pregunta describe "tráfico de inferencia esporádico e impredecible y no queremos pagar mientras está ocioso", la respuesta es **Serverless Inference** o **Asynchronous Inference**, no un endpoint en tiempo real.

2. Mapeá el ciclo de vida a la superficie de la API. Ejecutá cada uno y leé el verbo, no la salida (vacía):

   ```bash
   aws sagemaker list-labeling-jobs   --max-results 3 --query 'LabelingJobSummaryList[].LabelingJobName'   # label
   aws sagemaker list-processing-jobs --max-results 3 --query 'ProcessingJobSummaries[].ProcessingJobName' # prepare
   aws sagemaker list-training-jobs   --max-results 3 --query 'TrainingJobSummaries[].TrainingJobName'     # train
   aws sagemaker list-models          --max-results 3 --query 'Models[].ModelName'                         # package
   aws sagemaker list-endpoints       --max-results 3 --query 'Endpoints[].EndpointName'                   # deploy
   ```

   ```
   []
   []
   []
   []
   []
   ```

   Esos cinco verbos *son* el ciclo de vida de ML: **etiquetar → preparar → entrenar → empaquetar → desplegar**, y SageMaker tiene una capacidad administrada para cada uno — Ground Truth, Data Wrangler / Processing, Training Jobs, Model Registry, Endpoints.

3. **No crees un dominio ni un endpoint para este laboratorio.** Si querés explorar la consola, usá el catálogo *JumpStart* de SageMaker Studio en modo solo lectura y cerralo sin desplegar nada.

**Comprobación de comprensión — Bloque 5**

- **Q5.1** Un minorista quiere predecir qué clientes se van a dar de baja el próximo trimestre, usando siete años de su propio historial de transacciones. ¿Rekognition, Bedrock o SageMaker AI? ¿Por qué los otros dos no pueden hacerlo?
- **Q5.2** ¿Para qué sirve Amazon SageMaker Ground Truth, y qué paso poco glamoroso y caro del ciclo de vida de ML resuelve?
- **Q5.3** Un equipo tiene un modelo de SageMaker entrenado y tráfico muy variable — cientos de solicitudes en algunos minutos, cero durante horas. Nombrá la opción de inferencia que evita pagar por capacidad ociosa.
- **Q5.4** Explicá, en términos de costo, por qué `aws sagemaker list-endpoints` es el primer comando a ejecutar cuando investigás una factura de ML inesperada.
- **Q5.5** Un flujo de trabajo necesita que una persona revise las predicciones de baja confianza antes de actuar sobre ellas. ¿Qué servicio provee ese bucle de revisión humana?

---

## Ejercicio 6 — Warehouse, búsqueda, BI y gobernanza: el resto de la familia de analítica

Estos servicios son la mitad cara del tema. Los vas a **identificar** desde la CLI sin aprovisionar ninguno.

1. Confirmá que no hay nada corriendo y aprendé el comando "¿me está costando plata?" de cada servicio.

   ```bash
   aws redshift describe-clusters            --query 'Clusters[].{Id:ClusterIdentifier,Status:ClusterStatus,Node:NodeType}' --output table
   aws redshift-serverless list-workgroups   --query 'workgroups[].{Name:workgroupName,Status:status}' --output table
   aws emr list-clusters --active            --query 'Clusters[].{Name:Name,State:Status.State}' --output table
   aws opensearch list-domain-names          --query 'DomainNames[].DomainName' --output table
   aws kafka list-clusters-v2                --query 'ClusterInfoList[].{Name:ClusterName,State:State}' --output table
   ```

   ```
   ------------------
   | DescribeClusters|
   +----------------+
   |      None      |
   +----------------+
   ...
   ```

2. Revisá la capa de gobernanza sobre el data lake que construiste en el Ejercicio 1.

   ```bash
   aws lakeformation get-data-lake-settings \
     --query 'DataLakeSettings.DataLakeAdmins[].DataLakePrincipalIdentifier' --output text
   ```

   ```
   arn:aws:iam::123456789012:user/lab-admin
   ```

   > Lake Formation se sitúa **por encima** del Glue Data Catalog y agrega permisos de grano fino — a nivel de tabla, columna, fila y celda — aplicados en Athena, Redshift Spectrum, EMR y QuickSight. Sin él, tu única palanca es la política de bucket de S3, que es todo-o-nada por prefijo.

3. Revisá la capa de BI.

   ```bash
   aws quicksight describe-account-subscription --aws-account-id "$ACCOUNT_ID" \
     --query 'AccountInfo.{Edition:Edition,Status:AccountSubscriptionStatus}' 2>&1 | head -3
   ```

   Si QuickSight nunca se habilitó:

   ```
   An error occurred (ResourceNotFoundException) when calling the
   DescribeAccountSubscription operation: Account not found.
   ```

   Ese error es el resultado esperado y correcto — QuickSight requiere una suscripción explícita por cuenta y tiene su propio precio por usuario. **No te suscribas para este laboratorio.**

4. Revisá los datos de terceros.

   ```bash
   aws dataexchange list-data-sets --max-results 3 \
     --query 'DataSets[].{Name:Name,Origin:Origin}' --output table
   ```

   ```
   ---------------
   | ListDataSets|
   +-------------+
   |    None     |
   +-------------+
   ```

   AWS Data Exchange es la forma de **suscribirse a** conjuntos de datos de terceros (meteorológicos, financieros, demográficos) y hacer que se entreguen en tu propio S3 — la respuesta cada vez que una pregunta dice "necesitamos datos externos que no producimos nosotros".

**Comprobación de comprensión — Bloque 6**

- **Q6.1** Emparejá cada carga de trabajo con exactamente un servicio — Athena, Redshift, EMR, OpenSearch Service, QuickSight, Lake Formation, Data Exchange, Glue:
   a. Data warehouse a escala de petabytes con joins complejos, alimentando los dashboards diarios de un equipo de BI
   b. SQL ad-hoc sobre 400 GB de logs JSON en S3, consultado dos veces por semana
   c. Búsqueda de texto completo y analítica de logs con un dashboard interactivo sobre logs de aplicación
   d. Apache Spark y Hadoop administrados para los jobs de PySpark existentes de un equipo de ciencia de datos
   e. Dashboards de negocio interactivos y embebibles para 300 usuarios no técnicos
   f. Control de acceso a nivel de columna para que los analistas vean los pedidos pero no los números de tarjeta de crédito
   g. Catálogo central de metadatos más un job ETL serverless que convierte CSV a Parquet
   h. Suscribirse a un conjunto de datos demográficos licenciado de un tercero
- **Q6.2** Athena y Redshift ambos "ejecutan SQL". Dá los dos discriminadores decisivos sobre los que va a girar una pregunta de examen.
- **Q6.3** OpenSearch Dashboards y QuickSight ambos "muestran dashboards". ¿Sobre qué datos se apoya cada uno, y cuál es la herramienta de BI de propósito general?
- **Q6.4** Glue y EMR ambos "hacen ETL". ¿Cuál es serverless, cuál te da control a nivel de clúster, y cuál elegiría un equipo con código Hadoop/Spark existente?
- **Q6.5** Ya tenés un Glue Data Catalog. ¿Qué te aporta agregar Lake Formation que Glue por sí solo no da?

---

## Ejercicio 7 — Simulacro de examen: escenario → servicio

Respondé cada uno por escrito antes de abrir las respuestas. Apuntá al nombre del servicio más una razón de cinco palabras.

1. Un call center quiere transcripciones de cada llamada grabada y después quiere saber qué llamadas fueron enojadas.
2. Una empresa de medios debe autogenerar subtítulos en español, francés y japonés para video en inglés.
3. Un banco debe detectar registros de cuentas online probablemente fraudulentos, usando sus propias etiquetas históricas de fraude, sin contratar un equipo de ML.
4. Un minorista quiere recomendaciones del tipo "quienes compraron esto también compraron…" en sus páginas de producto.
5. Una empresa quiere que sus empleados hagan preguntas en lenguaje natural y obtengan respuestas provenientes de SharePoint, Confluence y S3.
6. Una telco quiere un bot automatizado de voz y chat que entienda intención y slots ("agendar un técnico para el martes").
7. Una firma de logística quiere extraer ítems de línea de 200.000 conocimientos de embarque escaneados.
8. Un equipo de seguridad quiere detectar si los avatares subidos por usuarios contienen imágenes inapropiadas.
9. Un producto SaaS quiere agregar un botón "resumir este hilo de tickets" usando un modelo de lenguaje grande, con posibilidad de elegir entre proveedores de modelos.
10. Un estudio de videojuegos transmite 500.000 eventos de telemetría por segundo y necesita tres aplicaciones consumidoras independientes más 24 horas de replay.
11. El mismo estudio quiere que esos eventos simplemente aterricen en S3, comprimidos, sin escribir código.
12. Un equipo de finanzas quiere un dashboard de ingresos diarios por región, construido por un analista, actualizado automáticamente, visto por 200 personas.
13. Un ingeniero de datos necesita convertir 8 TB diarios de CSV a Parquet particionado, de forma programada.
14. Un equipo de investigación quiere ejecutar sus jobs existentes de Apache Spark y Hive en clústeres administrados con Spot Instances.
15. Un oficial de cumplimiento exige que los analistas que consultan el data lake nunca vean la columna `ssn`.

---

## Ejercicio 8 — Desmantelamiento y verificación de costos

Hacé esto ahora, en este orden. Las dependencias importan: las tablas de Athena referencian objetos de S3, y el crawler referencia la base de datos.

1. Eliminá las tablas y la base de datos de Athena/Glue.

   ```bash
   for T in orders orders_parquet clicks; do
     aws glue delete-table --database-name "$DB" --name "$T" 2>/dev/null
   done
   aws glue delete-crawler --name clf37-orders-crawler
   aws glue delete-database --name "$DB"
   ```

2. Eliminá el delivery stream de Firehose.

   ```bash
   aws firehose delete-delivery-stream --delivery-stream-name clf37-clicks
   aws firehose list-delivery-streams --query 'DeliveryStreamNames'
   ```

   ```json
   []
   ```

3. Eliminá el registro del job de Transcribe.

   ```bash
   aws transcribe delete-transcription-job --transcription-job-name clf37-job-1
   ```

4. Vaciá y eliminá el bucket. **Mirá antes de borrar** — esto es irreversible.

   ```bash
   aws s3 ls "s3://${BUCKET}" --recursive --summarize | tail -3
   aws s3 rb "s3://${BUCKET}" --force
   ```

   ```
   Total Objects: 14
      Total Size: 5.1 KiB
   remove_bucket: clf37-lab-123456789012
   ```

5. Eliminá los roles de IAM.

   ```bash
   aws iam delete-role-policy --role-name AWSGlueServiceRole-clf37 --policy-name LabBucketRead
   aws iam detach-role-policy --role-name AWSGlueServiceRole-clf37 \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
   aws iam delete-role --role-name AWSGlueServiceRole-clf37

   aws iam delete-role-policy --role-name FirehoseToS3-clf37 --policy-name WriteLabBucket
   aws iam delete-role --role-name FirehoseToS3-clf37
   ```

6. Verificá el gasto. Los datos de costos tienen un retraso de hasta 24 horas, así que ejecutá esto mañana.

   ```bash
   aws ce get-cost-and-usage \
     --time-period "Start=$(date -u -d '3 days ago' +%F),End=$(date -u +%F)" \
     --granularity DAILY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE \
     --query 'ResultsByTime[-1].Groups[?Metrics.UnblendedCost.Amount!=`0`].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}' \
     --output table
   ```

   ```
   -------------------------------------------------
   |               GetCostAndUsage                 |
   +----------------------------+------------------+
   |          Service           |       USD        |
   +----------------------------+------------------+
   |  AWS Glue                  |  0.0733          |
   |  Amazon Athena             |  0.0000148       |
   |  Amazon Kinesis Firehose   |  0.0000001       |
   |  Amazon Simple Storage...  |  0.0000021       |
   +----------------------------+------------------+
   ```

   > Cada solicitud a la API `GetCostAndUsage` cuesta $0.01 — más que la mayor parte del laboratorio. Cost Explorer factura por *preguntar sobre* tu factura, lo cual es una pieza de trivia favorita de AWS.

7. Opcionalmente, eliminá el presupuesto:

   ```bash
   aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name clf37-lab-guardrail
   ```

**Comprobación de comprensión — Bloque 8**

- **Q8.1** AWS Glue dominó la factura con $0.073 mientras que Athena costó fracciones de centavo. Explicá ambos, en términos de la dimensión de precio de cada servicio.
- **Q8.2** Eliminaste las tablas de Glue pero los objetos de S3 sobrevivieron hasta el paso 4. ¿Qué prueba eso sobre la relación entre el Data Catalog y los datos?
- **Q8.3** ¿Qué recurso de todo este laboratorio habría sido el más caro de olvidar, y por qué se decidió deliberadamente no crearlo nunca?

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, v1.0 — Dominio 3, Tarea 3.7 y el apéndice de servicios dentro del alcance: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon Athena — What is Athena: <https://docs.aws.amazon.com/athena/latest/ug/what-is.html>
- AWS Glue — What is AWS Glue: <https://docs.aws.amazon.com/glue/latest/dg/what-is-glue.html>
- Amazon Data Firehose — What is Amazon Data Firehose: <https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html>
- Amazon Kinesis Data Streams — Introducción de la Developer Guide: <https://docs.aws.amazon.com/streams/latest/dev/introduction.html>
- Amazon Managed Streaming for Apache Kafka: <https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html>
- Amazon Redshift — Management Guide: <https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>
- Amazon EMR — What is Amazon EMR: <https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-what-is-emr.html>
- Amazon OpenSearch Service: <https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html>
- Amazon QuickSight — User Guide: <https://docs.aws.amazon.com/quicksight/latest/user/welcome.html>
- AWS Lake Formation: <https://docs.aws.amazon.com/lake-formation/latest/dg/what-is-lake-formation.html>
- AWS Data Exchange: <https://docs.aws.amazon.com/data-exchange/latest/userguide/what-is.html>
- Amazon Comprehend: <https://docs.aws.amazon.com/comprehend/latest/dg/what-is.html>
- Amazon Translate: <https://docs.aws.amazon.com/translate/latest/dg/what-is.html>
- Amazon Polly: <https://docs.aws.amazon.com/polly/latest/dg/what-is.html>
- Amazon Transcribe: <https://docs.aws.amazon.com/transcribe/latest/dg/what-is.html>
- Amazon Rekognition: <https://docs.aws.amazon.com/rekognition/latest/dg/what-is.html>
- Amazon Textract: <https://docs.aws.amazon.com/textract/latest/dg/what-is.html>
- Amazon Lex V2: <https://docs.aws.amazon.com/lexv2/latest/dg/what-is.html>
- Amazon Kendra: <https://docs.aws.amazon.com/kendra/latest/dg/what-is-kendra.html>
- Amazon Personalize: <https://docs.aws.amazon.com/personalize/latest/dg/what-is-personalize.html>
- Amazon Fraud Detector: <https://docs.aws.amazon.com/frauddetector/latest/ug/what-is-frauddetector.html>
- Amazon Augmented AI (A2I): <https://docs.aws.amazon.com/sagemaker/latest/dg/a2i-use-augmented-ai-a2i-human-review-loops.html>
- Amazon SageMaker AI: <https://docs.aws.amazon.com/sagemaker/latest/dg/whatis.html>
- Amazon Bedrock: <https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html>
- Amazon Q Business: <https://docs.aws.amazon.com/amazonq/latest/qbusiness-ug/what-is.html>
- Precios de Athena (modelo de costo): <https://aws.amazon.com/athena/pricing/> · Precios de Glue: <https://aws.amazon.com/glue/pricing/> · Precios de Firehose: <https://aws.amazon.com/firehose/pricing/>

---

<details>
<summary><strong>Respuestas</strong> — abrí solo después de intentar cada bloque</summary>

### Bloque 0 — Preflight

**Q0.1** AWS Budgets pertenece a la categoría de **economía de la nube / facturación y gestión de costos** (territorio de la tarea 3.8 y del Dominio 4, no de 3.7). Una **alerta** de presupuesto implementa **visibilidad** — te avisa que el gasto cruzó un umbral. No detiene nada. El control sería una SCP o una cuota dura; la optimización sería el right-sizing, los Savings Plans o, en este tema, convertir CSV a Parquet. La distinción importa en el examen: "avisame cuando supere $X" es Budgets; "impedime lanzar X" son las Service Control Policies o IAM.

**Q0.2** Rekognition y Textract leen la imagen desde S3 a través de una referencia `S3Object`, y ambos requieren que el objeto esté en la **misma región que el endpoint de la API** al que llamás — un objeto en otra región falla con `InvalidS3ObjectException`. Comprehend, en las llamadas que usamos, toma el texto **inline en el cuerpo de la solicitud** (`--text`), así que S3 no interviene en absoluto y la región del bucket es irrelevante. El principio general: cuando un servicio de IA extrae datos de S3 en vez de recibirlos en el payload, colocá el bucket en la misma región.

**Q0.3** Porque en AWS, S3 **es** el data lake. Todos los servicios de analítica de este tema o bien leen de S3 (Athena, Redshift Spectrum, EMR, Glue, QuickSight vía ingesta a SPICE), escriben en él (Firehose, Glue ETL, salida de Transcribe) o lo catalogan (Glue Data Catalog, Lake Formation). El desacople entre almacenamiento y cómputo — almacenamiento de objetos durable, barato y de alcance regional que muchos motores independientes consultan — es la premisa arquitectónica de toda la categoría.

---

### Bloque 1a/1b — S3 y Glue

**Q1.1** Las filas viven **en S3**, en `s3://<bucket>/raw/orders/orders.csv`, exactamente donde las pusiste. La tabla de Glue es puro **metadato**: un nombre, una lista de columnas con tipos, un formato de serialización y un puntero de ubicación. `aws glue delete-table` destruye solo esos metadatos — el CSV queda intacto y cualquier otro motor (EMR, Redshift Spectrum, un job de Spark, `aws s3 cp`) todavía puede leerlo. Esta es la propiedad definitoria de un data lake frente a una base de datos.

**Q1.2** Muestra que el crawler **infirió** el esquema muestreando los datos, y la inferencia es heurística: `2026-09-01T09:14:02Z` es un timestamp ISO-8601 válido, pero el crawler vio una cadena entrecomillada en un CSV y la tipó conservadoramente como `string`. Un esquema **definido** es el que escribís vos (como hicimos con `CREATE EXTERNAL TABLE` en el Ejercicio 2), donde vos afirmás el tipo. Ambos son **schema-on-read**: el esquema se aplica en tiempo de consulta por el motor, y el archivo subyacente nunca cambia. Schema-on-write es el modelo del warehouse — Redshift valida y reescribe los datos en el momento de la carga, así que una fila mala se rechaza en la ingesta, no se descubre en la consulta.

**Q1.3** (a) El **AWS Glue Data Catalog** — un repositorio de metadatos central y persistente (bases de datos, tablas, esquemas, particiones) compartido por Athena, EMR, Redshift Spectrum y otros. (b) **Glue ETL** — jobs serverless de Apache Spark que extraen, transforman y cargan datos, más los crawlers que pueblan el catálogo. Un tercer miembro visible en el examen: **AWS Glue DataBrew**, una herramienta visual y sin código de preparación de datos para analistas.

**Q1.4** "No se carga nada en Glue — el crawler solo registró el esquema del archivo en el Data Catalog; el CSV se queda en S3 y Athena lo lee ahí en tiempo de consulta."

---

### Bloque 1c — Athena

**Q1.5** (a) Almacenar los datos en un **formato columnar** — Parquet u ORC — para que una consulta que toca dos columnas lea solo esas columnas. (b) **Comprimirlos** (Snappy, GZIP): menos bytes en disco, menos bytes escaneados. (c) **Particionarlos** por una columna que aparezca en tus cláusulas `WHERE` (fecha, región), para que Athena pode prefijos enteros sin abrirlos. Extra: **bucketing**, y simplemente evitar `SELECT *`.

**Q1.6** Lo convierte en **serverless**. La consecuencia operativa es que un equipo sin ingenieros de datos puede consultar terabytes en S3 desde el primer día — no hay clúster que dimensionar, parchear, escalar, respaldar ni dejar prendido toda la noche — y el costo cae a cero cuando nadie consulta. La contrapartida es que no podés ajustar el motor, y el costo por consulta crece linealmente con los datos escaneados en vez de amortizarse sobre un clúster propio.

**Q1.7** Mudarse a **Amazon Redshift** (o Redshift Serverless). La diferencia económica: Athena cobra **por consulta, por byte escaneado** — genial para consultas infrecuentes e impredecibles, castigador para las repetitivas de alto volumen. Redshift cobra por **capacidad aprovisionada a lo largo del tiempo** (horas-nodo u horas-RPU), que es un costo fijo que amortizás entre consultas ilimitadas, y agrega almacenamiento columnar, claves de ordenamiento/distribución, caché de resultados y vistas materializadas que hacen las consultas repetidas de dashboard dramáticamente más rápidas. 400 escaneos idénticos de 2 TB/hora en Athena costarían aproximadamente $4.000/hora; un clúster de Redshift sirviendo ese patrón cuesta unos pocos dólares por hora.

**Q1.8** Athena escribe el conjunto de resultados de cada consulta — más metadatos y un manifiesto — como objetos en la ubicación de S3 que vos especificás. Es una cuestión de gobernanza porque esos objetos de resultado **contienen la salida de la consulta**: si la tabla de origen tiene PII, el bucket de resultados ahora también tiene PII, bajo un prefijo que nadie piensa en revisar. Las ubicaciones de resultados necesitan el mismo cifrado, política de bucket, reglas de ciclo de vida y registro de accesos que los datos de origen. (Los workgroups existen en parte para imponer una ubicación de resultados y un cifrado de forma centralizada, para que los usuarios no puedan elegir la suya.)

---

### Bloque 2 — Streaming

**Q2.1** **Amazon Data Firehose entrega datos de streaming a un destino por vos, sin código de consumidor y sin gestión de shards; Amazon Kinesis Data Streams te da un stream durable y reproducible que tus propias aplicaciones leen a su propio ritmo.** Firehose es entrega-como-servicio; Data Streams es un stream que te pertenece.

**Q2.2** Es **casi en tiempo real**, no tiempo real. La latencia está gobernada por los **buffering hints** — `SizeInMBs` e `IntervalInSeconds` — y Firehose descarga cuando se alcanza *cualquiera* de los dos umbrales. Configuramos 1 MB / 60 s, así que 30 registros diminutos esperaron el minuto completo. Kinesis Data Streams, en cambio, deja los registros disponibles para los consumidores en milisegundos.

**Q2.3** **Kinesis Data Streams.** Dos propiedades: (a) **retención y replay** — los registros se retienen (24 horas por defecto, extensible hasta 365 días) y un consumidor puede releer desde cualquier punto, cosa que Firehose no puede hacer porque no tiene stream visible al consumidor; (b) **múltiples consumidores independientes** — varias aplicaciones pueden leer el mismo stream con sus propios offsets, cada una con su propio checkpoint, y con enhanced fan-out cada una obtiene throughput dedicado. Firehose tiene exactamente un destino y ningún offset de consumidor. El procesamiento personalizado sub-segundo también descarta a Firehose por latencia sola.

**Q2.4** **Amazon MSK** (Managed Streaming for Apache Kafka). Ejecuta Apache Kafka open source de verdad, así que los productores, consumidores, conectores de Kafka Connect y librerías cliente existentes funcionan sin cambios. Kinesis es otra API con otra semántica (shards, no particiones; otro SDK) — migrar a ella es una reescritura de la aplicación, que es exactamente lo que el requisito excluye. MSK también es la respuesta correcta a cualquier pregunta que contenga "open source", "evitar el vendor lock-in" o "Kafka existente".

**Q2.5** **Amazon Managed Service for Apache Flink** (el servicio antes llamado Amazon Kinesis Data Analytics). Realiza procesamiento continuo, con estado y por ventanas sobre un stream — agregaciones, joins, detección de anomalías — antes de que los datos lleguen a un destino.

**Q2.6** **Amazon Kinesis Video Streams.**

---

### Bloque 3 — Servicios de IA preentrenados

**Q3.1**
| Servicio | Frase disparadora del examen |
|---|---|
| **Amazon Comprehend** | "…quiere saber si los clientes están enojados" / "extraer entidades, frases clave, temas o PII de texto" |
| **Amazon Translate** | "…localizar contenido a 12 idiomas" / "traducir mensajes de clientes en tiempo real" |
| **Amazon Polly** | "…convertir artículos en audio" / "darle al IVR una voz de sonido natural" |
| **Amazon Transcribe** | "…convertir llamadas o reuniones grabadas en texto buscable" / "generar subtítulos" |
| **Amazon Rekognition** | "…identificar objetos, caras o contenido inseguro en imágenes y video" |
| **Amazon Textract** | "…extraer texto, campos de formulario y tablas de documentos escaneados" |

**Q3.2** Es un **puntaje de confianza** — la probabilidad estimada por el modelo de que la etiqueta sea correcta — no una garantía. Te obliga a elegir un **umbral de confianza** y decidir qué pasa por debajo de él: rechazar, ignorar o derivar a una persona. Esa última opción es exactamente para lo que existe **Amazon Augmented AI (A2I)**. Cualquier aplicación que trate una etiqueta del 88% como un hecho aceptó silenciosamente una tasa de error del 12%.

**Q3.3** Transcribe es **batch asincrónico**: iniciás un job, el servicio procesa un archivo multimedia que puede durar horas, y consultás el estado o recibís un evento cuando termina. Las APIs `detect-*` de Comprehend son **sincrónicas**: entra la solicitud, sale la inferencia, en una sola llamada. Desde Lambda, la llamada sincrónica es una llamada común del SDK dentro del handler; la asincrónica **no** debe esperarse con `sleep` — una Lambda bloqueada 15 minutos en un bucle de polling quema costo de duración y puede alcanzar el timeout. El patrón correcto es iniciar-el-job-y-retornar, y luego hacer que la finalización dispare una segunda Lambda vía EventBridge o un evento de S3 sobre la ubicación de salida. (Comprehend también tiene APIs batch asincrónicas — `start-sentiment-detection-job` — para grandes conjuntos de documentos.)

**Q3.4** Notas clínicas → **Amazon Comprehend Medical** (extrae entidades médicas, medicación, dosis, PHI, y las codifica a ICD-10-CM / RxNorm). Formularios escaneados de reclamos de seguros → **Amazon Textract**, y su capacidad orientada a salud **Amazon Textract Analyze Health** / las funcionalidades de análisis de documentos médicos. La regla general: **texto** no estructurado **que ya tenés** → Comprehend; **píxeles de un documento** → Textract.

**Q3.5**
- **Amazon Textract** — extrae texto *y estructura* (campos de formulario clave–valor, tablas, celdas) de documentos escaneados y PDF. Entiende que "Total EUR" y "94.38" son un par.
- **Amazon Rekognition `detect-text`** — encuentra texto que aparece *en una escena*: un cartel de calle, el número de una camiseta, una patente, un subtítulo quemado en un cuadro de video. Sin estructura documental, sin formularios.
- **Amazon Comprehend** — no lee imágenes en absoluto. Toma texto que ya es digital y te dice qué *significa*: sentimiento, entidades, frases clave, idioma, PII, temas.

**Q3.6** Aceptaste un **modelo de propósito general que no controlás** — entrenado con datos de otro, ajustado para el caso promedio, sin visibilidad ni influencia sobre su comportamiento en tu dominio específico (jerga médica, un acento inusual, los números de parte de tu producto). Si no es lo bastante preciso, el camino de escalamiento es: **la personalización dentro del servicio, donde existe** (clasificación personalizada y reconocimiento de entidades personalizado de Comprehend, Rekognition Custom Labels, vocabulario personalizado y modelos de lenguaje de Transcribe, Active Custom Translation de Translate) → y si eso sigue siendo insuficiente, **Amazon SageMaker AI**, donde entrenás tu propio modelo con tus propios datos.

---

### Bloque 4 — Bedrock y Amazon Q

**Q4.1** Serverless acá significa que aprovisionás, parcheás, escalás y pagás por **ninguna infraestructura de inferencia**. No estás gestionando instancias con GPU, pesos de modelos, imágenes de contenedor, grupos de autoescalado ni software de servidor de modelos; el modelo se invoca a través de una API HTTPS y se factura por token. Lo que *no* queda abstraído es la elección del modelo, el diseño del prompt y — para throughput alto y sostenido — la decisión de comprar Provisioned Throughput en vez de bajo demanda.

**Q4.2** **Knowledge Bases for Amazon Bedrock**, que implementa **Retrieval Augmented Generation (RAG)**: los documentos se trocean, se convierten en embeddings en un almacén vectorial, y los pasajes relevantes se recuperan e inyectan en el prompt en tiempo de consulta — el modelo fundacional en sí nunca se reentrena. El servicio separado y totalmente administrado es **Amazon Kendra**, un servicio de búsqueda empresarial inteligente con conectores a SharePoint, Confluence, S3, Salesforce y otros, que devuelve respuestas rankeadas a preguntas en lenguaje natural. Heurística de examen: "búsqueda entre repositorios empresariales" → Kendra; "un asistente generativo fundamentado en mis documentos" → Bedrock Knowledge Bases o Amazon Q Business.

**Q4.3**
- **Amazon Q Developer** — un asistente de IA generativa para el desarrollo de software y para operar AWS: sugerencias de código en el IDE, transformación y actualización de código, y respuestas a preguntas sobre tu cuenta y recursos de AWS.
- **Amazon Q Business** — un asistente de IA generativa para empleados, conectado al contenido empresarial (documentos, wikis, ticketing, chat), que responde preguntas y ejecuta acciones respetando los permisos existentes de cada usuario.

**Q4.4** No — tus prompts y completions **no** se usan para entrenar los modelos fundacionales subyacentes, y no se comparten con los proveedores de modelos. Se apoya en las garantías de tenencia y manejo de datos de Bedrock: tus datos permanecen dentro del límite de tu cuenta de AWS y de la región, aplica cifrado en tránsito y en reposo, podés mantener el tráfico sobre **AWS PrivateLink** para que nunca atraviese internet público, y para los modelos personalizados la copia ajustada es privada tuya. Esta es la respuesta estándar a "¿podemos usar IA generativa con datos regulados?".

**Q4.5** De menor a mayor trabajo de ML:
1. **Amazon Rekognition** — llamás a una API, obtenés una etiqueta. Sin datos, sin modelo, sin prompt.
2. **Amazon Bedrock** — elegís un modelo y escribís un prompt; opcionalmente agregás RAG o fine-tuning. Sin infraestructura de entrenamiento.
3. **Amazon SageMaker AI** — aportás datos, hacés ingeniería de features, elegís un algoritmo, entrenás, evaluás, desplegás y monitoreás.

---

### Bloque 5 — SageMaker AI

**Q5.1** **Amazon SageMaker AI.** Predecir la baja de clientes sobre siete años de historial de transacciones *propietario* es un problema de aprendizaje supervisado sobre datos que solo tiene este minorista, con una variable objetivo (se dio de baja / no se dio de baja) que solo ellos pueden etiquetar. Rekognition no puede hacerlo porque es una API fija de visión por computadora — modalidad totalmente equivocada, y no personalizable a datos tabulares de negocio. Bedrock no puede hacerlo bien porque los modelos fundacionales están entrenados con corpus generales y no tienen conocimiento de los clientes de este minorista; podrías darle unos pocos ejemplos en el prompt, pero no vas a obtener una probabilidad calibrada por cliente aprendida de millones de filas históricas. SageMaker es el único nivel donde "entrená con mis datos" es el producto.

**Q5.2** **SageMaker Ground Truth** construye **conjuntos de datos de entrenamiento etiquetados** — orquesta anotadores humanos (tu propia fuerza de trabajo, un proveedor o Amazon Mechanical Turk) y usa aprendizaje activo para autoetiquetar los ejemplos fáciles, de modo que las personas solo vean los difíciles. Aborda el **etiquetado de datos**, que suele ser el paso más caro, más lento y menos glamoroso de cualquier proyecto de ML supervisado, y el que más se subestima en los planes de proyecto.

**Q5.3** **SageMaker Serverless Inference.** Aprovisiona y escala cómputo bajo demanda y escala a cero entre solicitudes, así que pagás solo por la duración de la inferencia y no por un endpoint siempre encendido. (Para payloads grandes o inferencia de larga duración con tolerancia a la demora, **Asynchronous Inference** es la respuesta hermana; para el scoring offline de un conjunto de datos completo, **Batch Transform**.)

**Q5.4** Porque un **endpoint de inferencia en tiempo real es una instancia aprovisionada que factura de forma continua**, las 24 horas del día, sin importar si se solicita una sola predicción. Los jobs de entrenamiento están acotados — empiezan, terminan, dejan de facturar. Las instancias de notebook también facturan mientras están corriendo, pero suelen ser visibles para su dueño. Un endpoint olvidado de una prueba de concepto de hace seis meses es el costo silencioso clásico de ML, y por eso `list-endpoints` es el primer lugar donde mirar.

**Q5.5** **Amazon Augmented AI (A2I)** — integra flujos de revisión humana en las predicciones de ML, derivando los resultados de baja confianza (de Rekognition, Textract o tu propio modelo de SageMaker) a revisores humanos antes de actuar sobre ellos.

---

### Bloque 6 — Warehouse, búsqueda, BI, gobernanza

**Q6.1**
a. **Amazon Redshift** — data warehouse a escala de petabytes, joins complejos, carga de trabajo de BI.
b. **Amazon Athena** — SQL ad-hoc e infrecuente directamente sobre S3; nada corriendo entre consultas.
c. **Amazon OpenSearch Service** — búsqueda de texto completo y analítica de logs, con OpenSearch Dashboards.
d. **Amazon EMR** — clústeres administrados de Hadoop/Spark para jobs de PySpark existentes.
e. **Amazon QuickSight** — BI serverless y embebible para usuarios no técnicos, con precio por usuario.
f. **AWS Lake Formation** — permisos de grano fino (a nivel de columna) sobre el data lake.
g. **AWS Glue** — el Data Catalog más el ETL serverless de Spark.
h. **AWS Data Exchange** — suscribirse a conjuntos de datos licenciados de terceros.

**Q6.2** (a) **Dónde viven los datos y quién es dueño del cómputo**: Athena consulta los datos *en el lugar*, en S3, sin infraestructura; Redshift carga los datos en un warehouse *aprovisionado* (o capacidad de Redshift Serverless) que vos dimensionás y pagás a lo largo del tiempo. (b) **Patrón de consulta y precios**: Athena es pago por consulta, ideal para análisis ad-hoc e infrecuentes; Redshift es pago por capacidad, ideal para cargas analíticas sostenidas, repetitivas y de alta concurrencia con joins complejos. Redshift además hace schema-on-write con claves de ordenamiento/distribución; Athena es schema-on-read. (Redshift Spectrum difumina la línea al permitir que Redshift consulte S3 directamente — eso es una respuesta de "tenemos ambos", no un discriminador.)

**Q6.3** **OpenSearch Dashboards** se apoya sobre datos indexados en un **dominio de OpenSearch** — logs, métricas, documentos, trazas — y es el front end operativo de búsqueda/observabilidad. **Amazon QuickSight** es la herramienta de **inteligencia de negocios de propósito general**: se conecta a Redshift, Athena, RDS, S3, fuentes SaaS y más, tiene SPICE para agregación rápida en memoria, precio por usuario, embebido e ML Insights. "Ingenieros investigando logs" → OpenSearch Dashboards. "El dashboard mensual del departamento de finanzas" → QuickSight.

**Q6.4** **AWS Glue es serverless** — enviás un job, AWS ejecuta Spark, pagás por DPU-segundo, y no hay clúster que configurar. **Amazon EMR te da control a nivel de clúster** — tipos de instancia, cantidad de nodos, Spot Instances, acciones de bootstrap, y la elección de frameworks (Spark, Hive, Presto, HBase, Flink) con versiones específicas. Un equipo con código Hadoop/Spark existente, librerías propias o necesidad de ajustar el clúster elige **EMR**; un equipo que solo quiere que un job de ETL corra elige **Glue**.

**Q6.5** **Control de acceso de grano fino, administrado centralmente.** El catálogo de Glue les dice a los motores *dónde están los datos y qué forma tienen*, pero el permiso lo aplican IAM y las políticas de bucket de S3 — en la práctica, todo-o-nada por prefijo. Lake Formation agrega **permisos a nivel de tabla, columna, fila y celda**, otorgados a principals de IAM en un solo lugar y aplicados de forma consistente en Athena, Redshift Spectrum, EMR, Glue y QuickSight. También agrega control de acceso basado en etiquetas (LF-Tags) y auditoría centralizada del acceso a los datos. En resumen: Glue = catálogo; Lake Formation = catálogo **más gobernanza**.

---

### Bloque 7 — Simulacro de escenarios

1. **Amazon Transcribe** y luego **Amazon Comprehend** — voz a texto, y después sentimiento sobre el texto. (Amazon Connect Contact Lens empaqueta ambos para call centers.)
2. **Amazon Transcribe** (generar la transcripción/subtítulos en inglés) y luego **Amazon Translate** (localizarlos). Transcribe solo te da subtítulos únicamente en el idioma hablado.
3. **Amazon Fraud Detector** — hecho a propósito, entrenado con *tus* datos históricos de fraude, sin necesidad de experiencia en ML. No SageMaker (eso requiere un equipo de ML); no Comprehend (modalidad equivocada).
4. **Amazon Personalize** — recomendaciones personalizadas en tiempo real a partir de tus datos de interacción, usando la misma tecnología que Amazon.com.
5. **Amazon Kendra** (búsqueda empresarial inteligente con esos conectores) o **Amazon Q Business** si se busca un asistente generativo conversacional. Ambas son aceptables; Kendra es la respuesta clásica de examen para "búsqueda entre repositorios", Q Business para "asistente".
6. **Amazon Lex** — interfaces conversacionales con reconocimiento de intención y slots, para voz y texto; es el motor detrás de Alexa. Combinalo con Polly para la salida de voz.
7. **Amazon Textract** — extracción de formularios y tablas de documentos escaneados a escala (APIs batch asincrónicas para documentos de varias páginas).
8. **Amazon Rekognition** — `DetectModerationLabels` para contenido de imagen inapropiado.
9. **Amazon Bedrock** — resumen mediante un modelo fundacional, con elección de proveedores detrás de una sola API.
10. **Amazon Kinesis Data Streams** — throughput alto, múltiples consumidores independientes, retención configurable para replay.
11. **Amazon Data Firehose** — entrega a S3 sin escribir código, con compresión y conversión de formato incorporadas.
12. **Amazon QuickSight** — BI serverless, construido por un analista, actualización programada, precio por usuario adecuado para 200 espectadores (precio de reader).
13. **AWS Glue** — ETL serverless con Spark, con disparadores programados o por eventos, escribiendo Parquet particionado. (EMR es defendible si necesitan control del clúster, pero "de forma programada, convirtiendo formatos" es el trabajo central de Glue.)
14. **Amazon EMR** — clústeres administrados que ejecutan su Spark y Hive existentes, con soporte de Spot Instances en los nodos de tarea.
15. **AWS Lake Formation** — permisos a nivel de columna que niegan el acceso a `ssn` mientras permiten el resto de la tabla.

---

### Bloque 8 — Desmantelamiento y costo

**Q8.1** **Glue** factura por **DPU-hora con un mínimo de 10 minutos por ejecución de crawler**, y por segundo a partir de ahí. Nuestro crawler trabajó bastante menos de un minuto de trabajo útil pero se le facturó el piso de 10 minutos a aproximadamente $0.44/DPU-hora → ≈$0.073. **Athena** factura por **byte escaneado** a ~$5/TB con un mínimo de 10 MB por consulta; un puñado de consultas sobre un archivo de 512 bytes redondea a esencialmente nada. La lección se generaliza: en la analítica serverless, el impulsor del costo es la dimensión que el servicio realmente mide — tiempo para Glue, bytes para Athena, GB ingeridos para Firehose, tokens para Bedrock, horas-instancia para Redshift/EMR/OpenSearch/endpoints de SageMaker.

**Q8.2** Prueba que están **completamente desacoplados**. El Data Catalog contiene metadatos; S3 contiene datos. Borrar una tabla elimina la capacidad de consultarla *con ese nombre en Athena*, y no elimina nada más — podrías haber vuelto a ejecutar el crawler y recrear la tabla idéntica en dos minutos. A la inversa, borrar los objetos de S3 dejando la tabla en su lugar te da una tabla consultable que devuelve cero filas. Hay que limpiar ambas mitades, y solo el borrado en S3 es genuinamente destructivo.

**Q8.3** Un **endpoint de inferencia en tiempo real de SageMaker**, o igualmente un **clúster aprovisionado de Amazon Redshift** o un **dominio de Amazon OpenSearch Service** — los tres son instancias aprovisionadas siempre encendidas que facturan por hora indefinidamente, estén ociosas o no, y pueden llegar a cientos o miles de dólares al mes. El laboratorio usó deliberadamente solo servicios serverless y de pago por solicitud (S3, Glue, Athena, Firehose, las APIs de los servicios de IA, Bedrock bajo demanda) precisamente para que olvidarse de un paso del desmantelamiento cueste centavos y no un alquiler. Esa asimetría — *los servicios de pago por uso fallan barato, los servicios aprovisionados fallan caro* — vale la pena llevársela a cualquier cuenta real de AWS.

</details>