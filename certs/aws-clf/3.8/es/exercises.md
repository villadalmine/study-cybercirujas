# Tema 3.8 — Ejercicios guiados
## Identificar servicios de otras categorías de servicios de AWS incluidas en el alcance
**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, guía de examen v1.0) · **Dominio 3:** Cloud Technology and Services · **Peso de la tarea 3.8:** 4,25 % del examen

---

## Qué cubre realmente esta task statement

La tarea 3.8 es la task statement de "todo lo demás dentro del alcance". La guía de examen enumera siete categorías bajo ella:

| Categoría | Servicios dentro del alcance que debe reconocer |
|---|---|
| Integración de aplicaciones | Amazon EventBridge, Amazon SNS, Amazon SQS |
| Servicios de aplicaciones de negocio | Amazon Connect, Amazon SES |
| Servicios de relación con el cliente | AWS Activate for Startups, AWS IQ, AWS Managed Services (AMS), AWS Support |
| Herramientas para desarrolladores | AWS AppConfig, AWS CLI, AWS Cloud9, AWS CodeArtifact, AWS CodeBuild, AWS CodeCommit, AWS CodeDeploy, Amazon CodeGuru, AWS CodePipeline, AWS CodeStar, AWS X-Ray, AWS SDKs and tools |
| Computación para el usuario final | Amazon AppStream 2.0, Amazon WorkSpaces, Amazon WorkSpaces Web |
| Frontend web y móvil | AWS Amplify, Amazon API Gateway, AWS Device Farm, Amazon Pinpoint |
| IoT | AWS IoT Core, AWS IoT Greengrass |

El examen evalúa la **identificación y el uso apropiado**, no la implementación. Aun así, estos ejercicios lo hacen *construir* las primitivas de integración, porque la forma más rápida de dejar de confundir SQS con SNS y con EventBridge es ver cómo un mensaje no llega y arreglarlo.

> **Nota del instructor sobre la lista congelada de servicios.** AWS cerró **AWS CodeCommit**, **AWS Cloud9** y **AWS CodeStar** a nuevos clientes en julio de 2024 (CodeStar llegó a su fin de vida el 2024-07-31); los clientes existentes conservan el acceso. **Amazon WorkSpaces Web** pasó a llamarse **Amazon WorkSpaces Secure Browser**. La guía de examen CLF-C02 v1.0 todavía lista los nombres antiguos, así que debe reconocer tanto el nombre heredado como lo que hacía. No planifique trabajo nuevo de producción sobre los servicios cerrados.

---

## Antes de empezar

**Requisitos previos**

- Una cuenta de AWS que esté autorizado a usar, con un principal de IAM que pueda crear recursos de SNS/SQS/EventBridge/IoT/SES.
- AWS CLI **v2** instalado y configurado (`aws --version` → `aws-cli/2.x.x`).
- `jq` instalado. Varias APIs de AWS reciben *JSON serializado como string dentro de un campo JSON*; `jq` es la única forma sensata de construir eso.
- Región fijada para todos los comandos de este documento: **`us-east-1`**.

**Disciplina de costos**

| Ejercicio | Costo |
|---|---|
| 1, 2 (SNS, SQS, EventBridge) | Prácticamente gratis — muy dentro del free tier perpetuo con este volumen |
| 3 (AppConfig, llamadas de solo lectura a herramientas de desarrollo) | Gratis con este volumen |
| 4 (EUC / frontend — solo llamadas `describe`) | **Gratis, porque solo hace describe.** Lanzar un WorkSpace, una flota de AppStream o una instancia de Amazon Connect **factura de inmediato.** No los lance. |
| 5 (IoT Core) | El free tier cubre este volumen de mensajes |
| 6 (identidad de SES + sondeo de la API de Support) | Gratis; el envío es free tier hasta 3.000 cargos por mensaje al mes |

Defina sus variables de trabajo una sola vez:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCT=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCT"
```

Salida esperada:

```
Account: 111122223333
```

Todos los ARN impresos abajo usan `111122223333` como ID de cuenta de ejemplo. El suyo será distinto.

---

# Ejercicio 1 — Integración de aplicaciones: fan-out de SNS hacia SQS, con una dead-letter queue

**Escenario.** Un servicio de pedidos publica `OrderCreated`. Dos equipos independientes —facturación y analítica— deben recibir *cada* pedido, y ninguno puede bloquear al otro. Este es el patrón canónico de **fan-out**: un topic de SNS, N colas de SQS.

### Pasos

1. **Cree el topic de SNS.**

    ```bash
    export TOPIC_ARN=$(aws sns create-topic --name orders-events \
      --query TopicArn --output text)
    echo $TOPIC_ARN
    ```

    Salida esperada:

    ```
    arn:aws:sns:us-east-1:111122223333:orders-events
    ```

2. **Cree las dos colas consumidoras y una dead-letter queue compartida.**

    ```bash
    export BILLING_URL=$(aws sqs create-queue --queue-name orders-billing \
      --attributes VisibilityTimeout=60,MessageRetentionPeriod=345600 \
      --query QueueUrl --output text)
    export ANALYTICS_URL=$(aws sqs create-queue --queue-name orders-analytics \
      --query QueueUrl --output text)
    export DLQ_URL=$(aws sqs create-queue --queue-name orders-dlq \
      --query QueueUrl --output text)
    printf '%s\n%s\n%s\n' "$BILLING_URL" "$ANALYTICS_URL" "$DLQ_URL"
    ```

    Salida esperada:

    ```
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-billing
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-analytics
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-dlq
    ```

3. **Resuelva los ARN de las colas.** La *URL* de la cola es la dirección del data plane; el *ARN* es lo que referencian IAM y SNS. No son intercambiables.

    ```bash
    for q in BILLING ANALYTICS DLQ; do
      url_var="${q}_URL"
      arn=$(aws sqs get-queue-attributes --queue-url "${!url_var}" \
        --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
      export "${q}_ARN=$arn"
      echo "$q -> $arn"
    done
    ```

    Salida esperada:

    ```
    BILLING -> arn:aws:sqs:us-east-1:111122223333:orders-billing
    ANALYTICS -> arn:aws:sqs:us-east-1:111122223333:orders-analytics
    DLQ -> arn:aws:sqs:us-east-1:111122223333:orders-dlq
    ```

4. **Suscriba ambas colas al topic**, con raw message delivery activado para que el consumidor reciba su JSON y no un envelope de SNS envolviéndolo.

    ```bash
    for arn in "$BILLING_ARN" "$ANALYTICS_ARN"; do
      aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
        --notification-endpoint "$arn" \
        --attributes RawMessageDelivery=true \
        --query SubscriptionArn --output text
    done
    ```

    Salida esperada (el sufijo UUID será distinto):

    ```
    arn:aws:sns:us-east-1:111122223333:orders-events:9f2e1c04-7f2b-4b62-9a71-d1a3c05d5b60
    arn:aws:sns:us-east-1:111122223333:orders-events:2c8a6d13-0f45-4a8e-9c33-88b7d2e91f07
    ```

5. **Publique un mensaje de prueba e intente leerlo. Este paso está diseñado para fallar.**

    ```bash
    aws sns publish --topic-arn "$TOPIC_ARN" \
      --message '{"orderId":"A-1001","amount":249.90,"currency":"USD"}' \
      --query MessageId --output text

    sleep 5
    aws sqs receive-message --queue-url "$BILLING_URL" --wait-time-seconds 10
    ```

    Salida esperada:

    ```
    5f01e6b6-9f7c-5a51-9a26-2b6dfb1d1e8f
    ```

    …y luego **nada en absoluto** de `receive-message`. Salida vacía, código de salida 0.

> **Checkpoint 1A**
>
> **Q1.1** `sns publish` devolvió un MessageId y la suscripción existe, pero la cola está vacía. ¿Cuál es la pieza que falta, y por qué suscribirse no la crea?
> **Q1.2** ¿Cuál de los dos identificadores —la URL de la cola o el ARN de la cola— necesitó SNS en el paso 4, y cuál usa el código de su aplicación para hacer polling?
> **Q1.3** ¿Qué cambia `RawMessageDelivery=true` respecto del body que ve el consumidor?

6. **Escriba la política basada en recursos de SQS** que permite al service principal de SNS entregar en la cola. Guárdela como `sqs-policy.json`:

    ```json
    {
      "Version": "2012-10-17",
      "Id": "orders-fanout-policy",
      "Statement": [
        {
          "Sid": "AllowSNSTopicToSendMessage",
          "Effect": "Allow",
          "Principal": { "Service": "sns.amazonaws.com" },
          "Action": "sqs:SendMessage",
          "Resource": "arn:aws:sqs:us-east-1:111122223333:orders-billing",
          "Condition": {
            "ArnEquals": {
              "aws:SourceArn": "arn:aws:sns:us-east-1:111122223333:orders-events"
            }
          }
        }
      ]
    }
    ```

    La condición `aws:SourceArn` no es opcional en producción: sin ella, *cualquier* topic de SNS en *cualquier* cuenta podría escribir en su cola (la clásica exposición de confused deputy).

7. **Aplique la política.** El atributo de cola `Policy` recibe un **documento JSON codificado como string**, no un objeto anidado. Constrúyalo con `jq` en vez de a mano:

    ```bash
    for q in BILLING ANALYTICS; do
      url_var="${q}_URL"; arn_var="${q}_ARN"
      jq -n --arg qarn "${!arn_var}" --arg tarn "$TOPIC_ARN" '
        {Policy: ({
          Version: "2012-10-17",
          Statement: [{
            Sid: "AllowSNSTopicToSendMessage",
            Effect: "Allow",
            Principal: {Service: "sns.amazonaws.com"},
            Action: "sqs:SendMessage",
            Resource: $qarn,
            Condition: {ArnEquals: {"aws:SourceArn": $tarn}}
          }]
        } | tostring)}' > /tmp/attrs-$q.json
      aws sqs set-queue-attributes --queue-url "${!url_var}" \
        --attributes file:///tmp/attrs-$q.json
      echo "policy applied: $q"
    done
    ```

    Salida esperada:

    ```
    policy applied: BILLING
    policy applied: ANALYTICS
    ```

8. **Adjunte la dead-letter queue** a `orders-billing` con una redrive policy — también un atributo JSON serializado como string.

    ```bash
    jq -n --arg arn "$DLQ_ARN" \
      '{RedrivePolicy: ({deadLetterTargetArn: $arn, maxReceiveCount: "3"} | tostring)}' \
      > /tmp/redrive.json
    aws sqs set-queue-attributes --queue-url "$BILLING_URL" --attributes file:///tmp/redrive.json

    aws sqs get-queue-attributes --queue-url "$BILLING_URL" \
      --attribute-names RedrivePolicy VisibilityTimeout --output json
    ```

    Salida esperada:

    ```json
    {
        "Attributes": {
            "VisibilityTimeout": "60",
            "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:111122223333:orders-dlq\",\"maxReceiveCount\":\"3\"}"
        }
    }
    ```

9. **Vuelva a publicar y confirme el fan-out real.**

    ```bash
    aws sns publish --topic-arn "$TOPIC_ARN" \
      --message '{"orderId":"A-1002","amount":80.00,"currency":"USD"}' \
      --query MessageId --output text

    for url in "$BILLING_URL" "$ANALYTICS_URL"; do
      echo "--- $(basename $url)"
      aws sqs receive-message --queue-url "$url" --wait-time-seconds 10 \
        --max-number-of-messages 10 --query 'Messages[].Body' --output text
    done
    ```

    Salida esperada:

    ```
    --- orders-billing
    {"orderId":"A-1002","amount":80.00,"currency":"USD"}
    --- orders-analytics
    {"orderId":"A-1002","amount":80.00,"currency":"USD"}
    ```

    Una publicación, dos copias independientes. Ningún consumidor puede dejar sin mensajes al otro.

10. **Fuerce un mensaje envenenado (poison pill) hacia la DLQ.** Reciba sin borrar, cuatro veces, dejando que expire el visibility timeout en cada ronda.

    ```bash
    aws sqs send-message --queue-url "$BILLING_URL" \
      --message-body '{"orderId":"BAD","amount":"not-a-number"}' \
      --query MessageId --output text

    aws sqs set-queue-attributes --queue-url "$BILLING_URL" \
      --attributes VisibilityTimeout=1

    for i in 1 2 3 4; do
      echo "receive attempt $i"
      aws sqs receive-message --queue-url "$BILLING_URL" --wait-time-seconds 2 \
        --attribute-names ApproximateReceiveCount \
        --query 'Messages[].[Attributes.ApproximateReceiveCount,Body]' --output text
      sleep 3
    done

    echo "--- DLQ contents"
    aws sqs receive-message --queue-url "$DLQ_URL" --wait-time-seconds 10 \
      --query 'Messages[].Body' --output text
    ```

    Salida esperada (abreviada):

    ```
    receive attempt 1
    1	{"orderId":"BAD","amount":"not-a-number"}
    receive attempt 2
    2	{"orderId":"BAD","amount":"not-a-number"}
    receive attempt 3
    3	{"orderId":"BAD","amount":"not-a-number"}
    receive attempt 4
    --- DLQ contents
    {"orderId":"BAD","amount":"not-a-number"}
    ```

11. **Lea las señales operativas** sobre las que un SRE realmente alarma.

    ```bash
    aws sqs get-queue-attributes --queue-url "$BILLING_URL" \
      --attribute-names ApproximateNumberOfMessages \
                        ApproximateNumberOfMessagesNotVisible \
                        ApproximateNumberOfMessagesDelayed --output json
    ```

    Salida esperada:

    ```json
    {
        "Attributes": {
            "ApproximateNumberOfMessages": "0",
            "ApproximateNumberOfMessagesNotVisible": "0",
            "ApproximateNumberOfMessagesDelayed": "0"
        }
    }
    ```

> **Checkpoint 1B**
>
> **Q1.4** Un mensaje llegó a la DLQ tras `maxReceiveCount` entregas. ¿Qué no hizo el consumidor que sí hace un consumidor sano, y qué llamada de la API de SQS es?
> **Q1.5** `ApproximateNumberOfMessagesNotVisible` está alto y plano mientras `ApproximateNumberOfMessages` nunca baja. Nombre dos causas raíz distintas.
> **Q1.6** Facturación debe procesar los pedidos estrictamente en la secuencia en que se hicieron, por cliente, y nunca puede cobrar dos veces. ¿Qué tipo de cola elige, qué campo impone el ordenamiento por cliente, y cuál es el costo en throughput de esa elección?
> **Q1.7** Un payload de pedido pesa 900 KB. ¿Puede SQS transportarlo? ¿Cuál es el patrón estándar?
> **Q1.8** En una oración cada uno, indique cuándo recurre a **SQS** frente a **SNS**.

---

# Ejercicio 2 — Integración de aplicaciones: enrutamiento y filtrado por contenido con EventBridge

**Escenario.** El mismo flujo de pedidos, pero ahora el enrutamiento debe decidirse por *contenido* —solo los pedidos de alto valor en EUR van a una cola de revisión de fraude— y el productor no debe saber quiénes son los consumidores.

### Pasos

1. **Cree un event bus personalizado.** El bus por defecto transporta eventos de servicios de AWS; los eventos de aplicación pertenecen a su propio bus.

    ```bash
    aws events create-event-bus --name acme-orders --query EventBusArn --output text
    ```

    Salida esperada:

    ```
    arn:aws:events:us-east-1:111122223333:event-bus/acme-orders
    ```

2. **Cree la cola de destino.**

    ```bash
    export FRAUD_URL=$(aws sqs create-queue --queue-name orders-fraud-review \
      --query QueueUrl --output text)
    export FRAUD_ARN=$(aws sqs get-queue-attributes --queue-url "$FRAUD_URL" \
      --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
    echo $FRAUD_ARN
    ```

    Salida esperada:

    ```
    arn:aws:sqs:us-east-1:111122223333:orders-fraud-review
    ```

3. **Cree una regla con un event pattern basado en contenido.** Fíjese en el matcher numérico — es lo que hace de EventBridge un *router* y no un topic.

    ```bash
    cat > /tmp/pattern.json <<'EOF'
    {
      "source": ["com.acme.orders"],
      "detail-type": ["OrderCreated"],
      "detail": {
        "currency": ["EUR"],
        "amount": [{ "numeric": [">=", 1000] }]
      }
    }
    EOF

    aws events put-rule --name high-value-eur-orders \
      --event-bus-name acme-orders \
      --event-pattern file:///tmp/pattern.json \
      --state ENABLED --query RuleArn --output text
    ```

    Salida esperada:

    ```
    arn:aws:events:us-east-1:111122223333:rule/acme-orders/high-value-eur-orders
    ```

4. **Autorice a EventBridge en la cola**, acotado a ese ARN de regla exacto.

    ```bash
    export RULE_ARN=arn:aws:events:us-east-1:$ACCT:rule/acme-orders/high-value-eur-orders

    jq -n --arg qarn "$FRAUD_ARN" --arg rarn "$RULE_ARN" '
      {Policy: ({
        Version: "2012-10-17",
        Statement: [{
          Sid: "AllowEventBridgeRule",
          Effect: "Allow",
          Principal: {Service: "events.amazonaws.com"},
          Action: "sqs:SendMessage",
          Resource: $qarn,
          Condition: {ArnEquals: {"aws:SourceArn": $rarn}}
        }]
      } | tostring)}' > /tmp/fraud-attrs.json

    aws sqs set-queue-attributes --queue-url "$FRAUD_URL" --attributes file:///tmp/fraud-attrs.json
    ```

5. **Adjunte el target.**

    ```bash
    aws events put-targets --rule high-value-eur-orders --event-bus-name acme-orders \
      --targets "Id=fraud-queue,Arn=$FRAUD_ARN"
    ```

    Salida esperada:

    ```json
    {
        "FailedEntryCount": 0,
        "FailedEntries": []
    }
    ```

6. **Publique tres eventos: uno que coincide y dos que deliberadamente no coinciden.**

    ```bash
    cat > /tmp/events.json <<EOF
    [
      {"EventBusName":"acme-orders","Source":"com.acme.orders","DetailType":"OrderCreated",
       "Detail":"{\"orderId\":\"E-1\",\"amount\":2500,\"currency\":\"EUR\"}"},
      {"EventBusName":"acme-orders","Source":"com.acme.orders","DetailType":"OrderCreated",
       "Detail":"{\"orderId\":\"E-2\",\"amount\":50,\"currency\":\"EUR\"}"},
      {"EventBusName":"acme-orders","Source":"com.acme.orders","DetailType":"OrderCreated",
       "Detail":"{\"orderId\":\"E-3\",\"amount\":9999,\"currency\":\"USD\"}"}
    ]
    EOF

    aws events put-events --entries file:///tmp/events.json
    ```

    Salida esperada:

    ```json
    {
        "FailedEntryCount": 0,
        "Entries": [
            { "EventId": "7bf73129-1428-4cd3-a780-95db273d1602" },
            { "EventId": "d2b1a6e0-3f1e-4a2b-9f77-2f1cb0e4c9a1" },
            { "EventId": "1a4c8f52-77c9-4e51-8f0b-b7de1f0a2e33" }
        ]
    }
    ```

7. **Verifique que solo se enrutó el evento coincidente.**

    ```bash
    aws sqs receive-message --queue-url "$FRAUD_URL" --wait-time-seconds 10 \
      --max-number-of-messages 10 --query 'Messages[].Body' --output text | jq -r '.detail.orderId'
    ```

    Salida esperada:

    ```
    E-1
    ```

> **Checkpoint 2A**
>
> **Q2.1** Los tres eventos devolvieron `FailedEntryCount: 0`, pero solo uno se entregó. ¿Qué garantiza realmente `FailedEntryCount: 0` — y qué es lo que explícitamente *no* garantiza?
> **Q2.2** El evento `E-2` tiene `"amount": 50`. Si el productor hubiera enviado `"amount": "50"` (un string) para un pedido de 5.000 €, ¿coincidiría el pattern `{"numeric": [">=", 1000]}`? ¿Por qué importa esto operativamente?
> **Q2.3** Necesita demostrar si una regla llegó a coincidir alguna vez. ¿Qué métricas de CloudWatch inspecciona, y qué le dice cada una?

8. **Diagnostique con métricas, no con conjeturas.**

    ```bash
    START=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    for m in MatchedEvents Invocations FailedInvocations; do
      echo "--- $m"
      aws cloudwatch get-metric-statistics --namespace AWS/Events --metric-name $m \
        --dimensions Name=RuleName,Value=high-value-eur-orders \
        --start-time "$START" --end-time "$END" --period 300 --statistics Sum \
        --query 'Datapoints[].Sum' --output text
    done
    ```

    Salida esperada (aproximada; las métricas se retrasan unos minutos):

    ```
    --- MatchedEvents
    1.0
    --- Invocations
    1.0
    --- FailedInvocations
    
    ```

9. **Contraste con EventBridge Scheduler**, que es un servicio distinto de las *reglas* rate/cron y es la respuesta correcta para invocación programada a escala.

    ```bash
    aws scheduler list-schedules --query 'Schedules[].{Name:Name,State:State}' --output table
    ```

    Salida esperada en una cuenta nueva:

    ```
    -------------------
    |  ListSchedules  |
    -------------------
    ```

> **Checkpoint 2B**
>
> **Q2.4** `MatchedEvents` es 5 e `Invocations` es 0. ¿Dónde está la falla? Ahora al revés: `Invocations` es 5 y `FailedInvocations` es 5. ¿Dónde está la falla?
> **Q2.5** Tres requisitos, tres servicios. Asocie cada uno a exactamente uno de SQS / SNS / EventBridge, y justifique: (a) amortiguar una ráfaga de 200.000 trabajos de procesamiento de imágenes para que los workers los drenen a su propio ritmo; (b) notificar a cinco subsistemas no relacionados más un correo de operaciones cada vez que termina un deployment; (c) ejecutar una Lambda distinta según si una instancia EC2 pasó a `stopped` o a `terminated`, sin cambios en el productor.
> **Q2.6** Un auditor le pide reproducir todos los eventos de pedidos del martes pasado hacia un consumidor nuevo. ¿Qué característica de EventBridge lo hace posible, y por qué SNS no puede hacerlo?

---

# Ejercicio 3 — Herramientas para desarrolladores: AppConfig, especificaciones de build/deploy y X-Ray

**Escenario.** Va a lanzar un feature flag a un servicio de checkout sin redesplegar, y necesita poder explicar la cadena de herramientas de CI/CD que se espera que un Cloud Practitioner identifique.

### Pasos

1. **Cree una aplicación, un entorno y un perfil de feature flags en AppConfig.**

    ```bash
    export APP_ID=$(aws appconfig create-application --name checkout-service \
      --query Id --output text)
    export ENV_ID=$(aws appconfig create-environment --application-id "$APP_ID" \
      --name prod --query Id --output text)
    export PROF_ID=$(aws appconfig create-configuration-profile \
      --application-id "$APP_ID" --name feature-flags \
      --location-uri hosted --type "AWS.AppConfig.FeatureFlags" \
      --query Id --output text)
    printf 'app=%s env=%s profile=%s\n' "$APP_ID" "$ENV_ID" "$PROF_ID"
    ```

    Salida esperada (los IDs son strings opacos de 7 caracteres):

    ```
    app=abc1234 env=def5678 profile=ghi9012
    ```

2. **Escriba el documento de flags y guárdelo como una hosted configuration version.**

    ```bash
    cat > /tmp/flags.json <<'EOF'
    {
      "flags": {
        "express_checkout": {
          "name": "express_checkout",
          "attributes": {
            "rollout_percentage": { "constraints": { "type": "number", "required": true } }
          }
        }
      },
      "values": {
        "express_checkout": { "enabled": true, "rollout_percentage": 25 }
      },
      "version": "1"
    }
    EOF

    aws appconfig create-hosted-configuration-version \
      --application-id "$APP_ID" --configuration-profile-id "$PROF_ID" \
      --content-type "application/json" --content fileb:///tmp/flags.json \
      /tmp/version-out.json
    cat /tmp/version-out.json | head -5
    ```

    Salida esperada:

    ```json
    {
        "ApplicationId": "abc1234",
        "ConfigurationProfileId": "ghi9012",
        "VersionNumber": 1,
        "ContentType": "application/json"
    }
    ```

3. **Despliegue el flag con una estrategia canary predefinida.**

    ```bash
    aws appconfig list-deployment-strategies \
      --query 'Items[?starts_with(Name, `AppConfig.`)].{Name:Name,Id:Id,Growth:GrowthType}' \
      --output table

    aws appconfig start-deployment --application-id "$APP_ID" \
      --environment-id "$ENV_ID" --deployment-strategy-id "AppConfig.Canary10Percent20Minutes" \
      --configuration-profile-id "$PROF_ID" --configuration-version 1 \
      --query '{Number:DeploymentNumber,State:State,PercentComplete:PercentageComplete}'
    ```

    Salida esperada:

    ```
    ----------------------------------------------------------------------------
    |                        ListDeploymentStrategies                          |
    +--------------------+---------------------------------------+-------------+
    |  AppConfig.AllAtOnce                       | ...             | EXPONENTIAL |
    |  AppConfig.Linear50PercentEvery30Seconds   | ...             | LINEAR      |
    |  AppConfig.Canary10Percent20Minutes        | ...             | EXPONENTIAL |
    +--------------------+---------------------------------------+-------------+
    {
        "Number": 1,
        "State": "DEPLOYING",
        "PercentComplete": 0.0
    }
    ```

4. **Lea la configuración de vuelta como lo haría una aplicación** — mediante la API de data plane `appconfigdata`, que está basada en sesiones y devuelve un token rotativo.

    ```bash
    TOKEN=$(aws appconfigdata start-configuration-session \
      --application-identifier "$APP_ID" \
      --environment-identifier "$ENV_ID" \
      --configuration-profile-identifier "$PROF_ID" \
      --query InitialConfigurationToken --output text)

    aws appconfigdata get-latest-configuration --configuration-token "$TOKEN" \
      /dev/stdout --query NextPollConfigurationToken --output text >/dev/null
    ```

    Salida esperada (el documento de flags, impreso en stdout):

    ```json
    {"express_checkout":{"enabled":true,"rollout_percentage":25}}
    ```

> **Checkpoint 3A**
>
> **Q3.1** ¿Qué le permitió cambiar AppConfig que de otro modo habría exigido un despliegue de código? Nombre el riesgo operativo específico que mitiga la estrategia canary.
> **Q3.2** AppConfig tiene un endpoint de data plane separado (`appconfigdata`) de su control plane (`appconfig`). ¿Por qué los separaría AWS?

5. **Lea una especificación de build de CodeBuild completa.** Guárdela como `buildspec.yml` en la raíz de un repositorio — es el archivo que CodeBuild busca por defecto.

    ```yaml
    version: 0.2

    env:
      variables:
        NODE_ENV: production
      parameter-store:
        NPM_TOKEN: /checkout/npm/token
      secrets-manager:
        SONAR_TOKEN: prod/sonar:token

    phases:
      install:
        runtime-versions:
          nodejs: 20
        commands:
          - aws codeartifact login --tool npm --domain acme --domain-owner "$ACCT" --repository internal
      pre_build:
        commands:
          - npm ci --no-audit
      build:
        commands:
          - npm run build
          - npm test -- --ci --reporters=default --reporters=jest-junit
      post_build:
        commands:
          - echo "Built from commit $CODEBUILD_RESOLVED_SOURCE_VERSION"

    reports:
      unit-tests:
        files:
          - "junit.xml"
        base-directory: reports
        file-format: JUNITXML

    artifacts:
      base-directory: dist
      files:
        - "**/*"

    cache:
      paths:
        - "node_modules/**/*"
    ```

6. **Lea una especificación de aplicación de CodeDeploy completa** para un despliegue blue/green en ECS. Guárdela como `appspec.yaml`.

    ```yaml
    version: 0.0
    Resources:
      - TargetService:
          Type: AWS::ECS::Service
          Properties:
            TaskDefinition: "arn:aws:ecs:us-east-1:111122223333:task-definition/checkout:42"
            LoadBalancerInfo:
              ContainerName: "checkout"
              ContainerPort: 8080
            PlatformVersion: "1.4.0"
    Hooks:
      - BeforeInstall: "arn:aws:lambda:us-east-1:111122223333:function:predeploy-guard"
      - AfterAllowTestTraffic: "arn:aws:lambda:us-east-1:111122223333:function:smoke-tests"
      - BeforeAllowTraffic: "arn:aws:lambda:us-east-1:111122223333:function:canary-check"
    ```

7. **Inspeccione el sampling de X-Ray**, el control que decide cuánto tracing paga.

    ```bash
    aws xray get-sampling-rules \
      --query 'SamplingRuleRecords[].SamplingRule.{Name:RuleName,Rate:FixedRate,Reservoir:ReservoirSize,Priority:Priority}' \
      --output table
    ```

    Salida esperada en una cuenta nueva:

    ```
    ------------------------------------------------------
    |                  GetSamplingRules                  |
    +----------+--------+-----------+--------------------+
    |   Name   |  Rate  | Reservoir |     Priority       |
    +----------+--------+-----------+--------------------+
    |  Default |  0.05  |    1      |      10000         |
    +----------+--------+-----------+--------------------+
    ```

8. **Consulte el service graph** (vacío salvo que tenga una aplicación instrumentada, que es el resultado esperado aquí).

    ```bash
    aws xray get-service-graph \
      --start-time "$(date -u -d '1 hour ago' +%s)" \
      --end-time "$(date -u +%s)" \
      --query 'Services[].{Name:Name,Type:Type}' --output table
    ```

> **Checkpoint 3B**
>
> **Q3.3** Asocie cada servicio de herramientas para desarrolladores con su función en una línea: CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline, CodeGuru, X-Ray, Cloud9, CodeStar, AWS CLI, AWS SDKs.
> **Q3.4** La regla de sampling por defecto de X-Ray dice "reservoir 1, rate 0.05". Tradúzcalo a lenguaje llano sobre cuántas solicitudes se trazan, y explique por qué AWS no usó 100 % por defecto.
> **Q3.5** Una solicitud de checkout tarda 4 segundos. CloudWatch muestra que la latencia de API Gateway es alta pero la métrica `Duration` de cada Lambda downstream se ve normal. ¿Qué servicio encuentra al culpable, y qué le muestra ese servicio que las métricas por servicio no pueden?
> **Q3.6** ¿Cuáles dos de los servicios de Q3.3 *no* debería elegir para un proyecto greenfield en 2026, y cuál es el reemplazo práctico de cada uno?

---

# Ejercicio 4 — Computación para el usuario final y servicios frontend/móviles

**Escenario.** Tres pedidos llegan a su bandeja de entrada la misma mañana. Debe derivar cada uno al servicio correcto — y debe hacerlo sin lanzar nada facturable.

### Pasos

1. **Enumere los bundles de WorkSpaces** (solo lectura, gratis — esto *no* crea un escritorio).

    ```bash
    aws workspaces describe-workspace-bundles --owner AMAZON \
      --query 'Bundles[?ComputeType.Name==`STANDARD`].{Id:BundleId,Name:Name,Compute:ComputeType.Name,RootGB:RootStorage.Capacity,UserGB:UserStorage.Capacity}' \
      --output table | head -15
    ```

    Salida esperada (abreviada; los IDs de bundle difieren por Región):

    ```
    -------------------------------------------------------------------------------
    |                          DescribeWorkspaceBundles                           |
    +----------+---------------------------+-----------+----------+---------------+
    |    Id    |           Name            |  Compute  |  RootGB  |    UserGB     |
    +----------+---------------------------+-----------+----------+---------------+
    |  wsb-... |  Standard with Windows 10 |  STANDARD |  80      |  50           |
    |  wsb-... |  Standard with Amazon Linux 2 | STANDARD | 80     |  50           |
    +----------+---------------------------+-----------+----------+---------------+
    ```

2. **Confirme que no tiene escritorios en ejecución** (esta es la barrera contra facturas sorpresa).

    ```bash
    aws workspaces describe-workspaces --query 'length(Workspaces)' --output text
    aws appstream describe-fleets --query 'length(Fleets)' --output text
    ```

    Salida esperada:

    ```
    0
    0
    ```

3. **Confirme que la superficie de Secure Browser (WorkSpaces Web) está vacía.**

    ```bash
    aws workspaces-web list-portals --query 'portals[].{Arn:portalArn,Status:portalStatus}' --output table
    ```

    Salida esperada:

    ```
    ---------------
    | ListPortals |
    ---------------
    ```

> **Checkpoint 4A**
>
> **Q4.1** Derive cada pedido a exactamente uno de **Amazon WorkSpaces**, **Amazon AppStream 2.0** o **Amazon WorkSpaces Web / Secure Browser**, e indique la característica decisiva:
> (a) 400 contratistas necesitan acceso de solo lectura a tres dashboards web internos desde sus propias laptops no administradas, sin que nada quede persistido en el endpoint.
> (b) 30 ingenieros necesitan un escritorio Windows persistente con sus herramientas y archivos instalados, disponible cada mañana exactamente como lo dejaron.
> (c) Una universidad necesita transmitir una única aplicación CAD a 2.000 estudiantes durante una sesión de laboratorio de 3 horas, después de la cual no se retiene nada.
> **Q4.2** ¿Cuál de los tres le factura un recurso *persistente* incluso cuando el usuario no está conectado, y cómo controla ese costo?

4. **Cree una HTTP API mínima en API Gateway** (free tier; todavía sin backend adjunto).

    ```bash
    export API_ID=$(aws apigatewayv2 create-api --name checkout-public \
      --protocol-type HTTP --query ApiId --output text)
    aws apigatewayv2 get-api --api-id "$API_ID" \
      --query '{Id:ApiId,Endpoint:ApiEndpoint,Protocol:ProtocolType}'
    ```

    Salida esperada:

    ```json
    {
        "Id": "a1b2c3d4e5",
        "Endpoint": "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com",
        "Protocol": "HTTP"
    }
    ```

5. **Enumere los recursos de Device Farm.** Fíjese en la Región — la flota de dispositivos vive en `us-west-2`.

    ```bash
    aws devicefarm list-device-pools --arn "arn:aws:devicefarm:us-west-2::devicepool:public" \
      --region us-west-2 --query 'devicePools[].{Name:name,Type:type}' --output table 2>&1 | head -8
    ```

    Salida esperada (o bien el listado del pool público, o bien un error de argumento si no tiene ningún proyecto — ambos son informativos):

    ```
    ---------------------------------------
    |           ListDevicePools           |
    +------------------------+------------+
    |  Top Devices           |  CURATED   |
    |  Android High Tier ... |  CURATED   |
    +------------------------+------------+
    ```

6. **Confirme que Amplify y Pinpoint están accesibles y vacíos.**

    ```bash
    aws amplify list-apps --query 'apps[].{Name:name,Platform:platform}' --output table
    aws pinpoint get-apps --query 'ApplicationsResponse.Item[].Name' --output text
    ```

> **Checkpoint 4B**
>
> **Q4.3** Asocie con Amplify / API Gateway / Device Farm / Pinpoint: (a) verificar que un flujo de checkout se renderiza correctamente en un Samsung Galaxy físico con Android 14; (b) alojar una single-page app en React con builds disparados por Git y entornos de vista previa por pull request; (c) publicar una puerta de entrada REST versionada, con throttling y autenticada para un conjunto de funciones Lambda; (d) enviar una campaña de reenganche segmentada por push y SMS a usuarios que abandonaron un carrito.
> **Q4.4** Tanto Amazon Pinpoint como Amazon SES pueden enviar correo. ¿Cuál es la línea divisoria real entre ambos?
> **Q4.5** API Gateway ofrece usage plans con API keys. ¿Es eso un mecanismo de autenticación? Justifique su respuesta.

---

# Ejercicio 5 — Servicios de IoT: AWS IoT Core y AWS IoT Greengrass

**Escenario.** Una flota de sensores de temperatura publica telemetría por MQTT. Las lecturas por encima de 80 °C deben enrutarse a una cola de SQS para el equipo de guardia. Los dispositivos en sitios remotos pierden conectividad durante horas seguidas.

### Pasos

1. **Registre un thing y genere su identidad X.509.**

    ```bash
    aws iot create-thing --thing-name edge-sensor-01 \
      --query '{Name:thingName,Arn:thingArn}'

    aws iot create-keys-and-certificate --set-as-active \
      --certificate-pem-outfile /tmp/device.pem.crt \
      --public-key-outfile /tmp/public.pem.key \
      --private-key-outfile /tmp/private.pem.key \
      --query '{CertArn:certificateArn,CertId:certificateId}'
    ```

    Salida esperada:

    ```json
    {
        "Name": "edge-sensor-01",
        "Arn": "arn:aws:iot:us-east-1:111122223333:thing/edge-sensor-01"
    }
    {
        "CertArn": "arn:aws:iot:us-east-1:111122223333:cert/6f8c0a1e2b3d4f5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c",
        "CertId": "6f8c0a1e2b3d4f5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c"
    }
    ```

    Capture el ARN:

    ```bash
    export CERT_ARN=$(aws iot list-certificates --query 'certificates[0].certificateArn' --output text)
    ```

2. **Escriba una política de IoT de mínimo privilegio** usando variables de política acotadas al thing, para que una sola política sirva de forma segura a toda la flota. Guárdela como `iot-policy.json`:

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "ConnectAsOwnThingOnly",
          "Effect": "Allow",
          "Action": "iot:Connect",
          "Resource": "arn:aws:iot:us-east-1:111122223333:client/${iot:Connection.Thing.ThingName}"
        },
        {
          "Sid": "PublishOwnTelemetry",
          "Effect": "Allow",
          "Action": ["iot:Publish"],
          "Resource": "arn:aws:iot:us-east-1:111122223333:topic/sensors/${iot:Connection.Thing.ThingName}/telemetry"
        },
        {
          "Sid": "ReceiveOwnCommands",
          "Effect": "Allow",
          "Action": ["iot:Subscribe"],
          "Resource": "arn:aws:iot:us-east-1:111122223333:topicfilter/sensors/${iot:Connection.Thing.ThingName}/commands"
        },
        {
          "Sid": "ReceiveMessagesOnSubscribedTopics",
          "Effect": "Allow",
          "Action": ["iot:Receive"],
          "Resource": "arn:aws:iot:us-east-1:111122223333:topic/sensors/${iot:Connection.Thing.ThingName}/commands"
        }
      ]
    }
    ```

3. **Cree y adjunte la política, luego vincule el certificado al thing.**

    ```bash
    sed -i "s/111122223333/$ACCT/g" iot-policy.json
    aws iot create-policy --policy-name edge-sensor-policy \
      --policy-document file://iot-policy.json --query policyArn --output text

    aws iot attach-policy --policy-name edge-sensor-policy --target "$CERT_ARN"
    aws iot attach-thing-principal --thing-name edge-sensor-01 --principal "$CERT_ARN"

    aws iot list-thing-principals --thing-name edge-sensor-01 --output text
    ```

    Salida esperada:

    ```
    arn:aws:iot:us-east-1:111122223333:policy/edge-sensor-policy
    PRINCIPALS	arn:aws:iot:us-east-1:111122223333:cert/6f8c0a1e...
    ```

4. **Descubra el endpoint de datos de la cuenta.** Solicite siempre la variante ATS.

    ```bash
    aws iot describe-endpoint --endpoint-type iot:Data-ATS
    aws iot describe-endpoint --endpoint-type iot:CredentialProvider
    ```

    Salida esperada:

    ```json
    { "endpointAddress": "a3k7odshaiipe8-ats.iot.us-east-1.amazonaws.com" }
    { "endpointAddress": "c2v9ex4mple.credentials.iot.us-east-1.amazonaws.com" }
    ```

5. **Cree el destino SQS y un rol de IAM que el rules engine pueda asumir.**

    ```bash
    export ALERT_URL=$(aws sqs create-queue --queue-name iot-heat-alerts --query QueueUrl --output text)
    export ALERT_ARN=$(aws sqs get-queue-attributes --queue-url "$ALERT_URL" \
      --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

    cat > /tmp/iot-trust.json <<'EOF'
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "iot.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }
    EOF

    export ROLE_ARN=$(aws iam create-role --role-name IoTRuleToSQS \
      --assume-role-policy-document file:///tmp/iot-trust.json \
      --query Role.Arn --output text)

    jq -n --arg q "$ALERT_ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"sqs:SendMessage",Resource:$q}]}' \
      > /tmp/iot-send.json
    aws iam put-role-policy --role-name IoTRuleToSQS --policy-name SendToAlertQueue \
      --policy-document file:///tmp/iot-send.json
    echo "$ROLE_ARN"
    ```

    Salida esperada:

    ```
    arn:aws:iam::111122223333:role/IoTRuleToSQS
    ```

6. **Cree una topic rule con una sentencia SQL** — el rules engine filtra y remodela en la ingesta, antes de que se facture nada aguas abajo.

    ```bash
    jq -n --arg url "$ALERT_URL" --arg role "$ROLE_ARN" '
    {
      sql: "SELECT temperature, topic(2) AS deviceId, timestamp() AS ts FROM '\''sensors/+/telemetry'\'' WHERE temperature > 80",
      awsIotSqlVersion: "2016-03-23",
      ruleDisabled: false,
      actions: [{ sqs: { queueUrl: $url, roleArn: $role, useBase64: false } }]
    }' > /tmp/rule.json

    aws iot create-topic-rule --rule-name heat_alert --topic-rule-payload file:///tmp/rule.json
    aws iot get-topic-rule --rule-name heat_alert --query 'rule.sql' --output text
    ```

    Salida esperada:

    ```
    SELECT temperature, topic(2) AS deviceId, timestamp() AS ts FROM 'sensors/+/telemetry' WHERE temperature > 80
    ```

7. **Publique dos lecturas a través del data plane HTTPS** (una por debajo del umbral y otra por encima) y confirme que solo se enruta la caliente.

    ```bash
    ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)

    aws iot-data publish --endpoint-url "https://$ENDPOINT" \
      --topic "sensors/edge-sensor-01/telemetry" \
      --cli-binary-format raw-in-base64-out --payload '{"temperature":21.4}'

    aws iot-data publish --endpoint-url "https://$ENDPOINT" \
      --topic "sensors/edge-sensor-01/telemetry" \
      --cli-binary-format raw-in-base64-out --payload '{"temperature":93.7}'

    sleep 5
    aws sqs receive-message --queue-url "$ALERT_URL" --wait-time-seconds 10 \
      --query 'Messages[].Body' --output text
    ```

    Salida esperada:

    ```
    {"temperature":93.7,"deviceId":"edge-sensor-01","ts":1788547201234}
    ```

8. **Inspeccione el device shadow**, el mecanismo que le permite dirigirse a un dispositivo offline.

    ```bash
    aws iot-data update-thing-shadow --thing-name edge-sensor-01 \
      --cli-binary-format raw-in-base64-out \
      --payload '{"state":{"desired":{"sampling_interval_s":30}}}' /dev/stdout | jq .

    aws iot-data get-thing-shadow --thing-name edge-sensor-01 /dev/stdout | jq '.state'
    ```

    Salida esperada:

    ```json
    {
      "desired": { "sampling_interval_s": 30 }
    }
    ```

9. **Compruebe si hay dispositivos core de Greengrass** (no habrá ninguno — Greengrass corre en hardware suyo).

    ```bash
    aws greengrassv2 list-core-devices --query 'coreDevices[].{Name:coreDeviceThingName,Status:status}' --output table
    aws greengrassv2 list-components --scope AWS_TYPES \
      --query 'components[].componentName' --output text | tr '\t' '\n' | head -8
    ```

    Salida esperada:

    ```
    -----------------
    |ListCoreDevices|
    -----------------
    aws.greengrass.Nucleus
    aws.greengrass.Cli
    aws.greengrass.StreamManager
    aws.greengrass.LocalDebugConsole
    ...
    ```

> **Checkpoint 5**
>
> **Q5.1** La política de IoT usa `${iot:Connection.Thing.ThingName}` en lugar de un nombre fijo. ¿Qué le aporta eso cuando la flota crece a 50.000 dispositivos, y cuál es la propiedad de seguridad que impone?
> **Q5.2** Un dispositivo se conecta correctamente pero todos los `publish` se descartan silenciosamente, sin ningún error visible para el dispositivo. ¿Dónde mira, y cuál es la causa más probable?
> **Q5.3** La topic rule filtra `WHERE temperature > 80` en la ingesta en vez de reenviar todo y filtrar en una Lambda. Indique los dos beneficios distintos.
> **Q5.4** Una estación de bombeo remota pierde su enlace ascendente seis horas al día. Los sensores locales deben seguir disparando una parada local en menos de 200 ms, y las lecturas almacenadas deben sincronizarse cuando vuelva el enlace. ¿Qué servicio, y en cuáles tres de sus capacidades se apoya?
> **Q5.5** En una línea cada uno: ¿qué es **AWS IoT Core** y qué es **AWS IoT Greengrass**? ¿Dónde se ejecuta físicamente cada uno?
> **Q5.6** ¿Por qué `describe-endpoint` requiere `--endpoint-type iot:Data-ATS`? ¿Qué se rompe si usa el endpoint heredado de Verisign?

---

# Ejercicio 6 — Aplicaciones de negocio y relación con el cliente

**Escenario.** Está poniendo en marcha el correo transaccional de la plataforma y, por separado, decidiendo qué plan de AWS Support necesita la empresa.

### Pasos

1. **Revise primero la postura de la cuenta en SES** — toda cuenta nueva está en sandbox, y este es el caso de soporte de SES más común de todos.

    ```bash
    aws sesv2 get-account --query '{Production:ProductionAccessEnabled,Enforcement:EnforcementStatus,Quota:SendQuota}'
    ```

    Salida esperada en una cuenta sin revisión:

    ```json
    {
        "Production": false,
        "Enforcement": "HEALTHY",
        "Quota": {
            "Max24HourSend": 200.0,
            "MaxSendRate": 1.0,
            "SentLast24Hours": 0.0
        }
    }
    ```

2. **Cree y verifique una identidad de correo.** Use una dirección que controle.

    ```bash
    aws sesv2 create-email-identity --email-identity "you@example.com" \
      --query '{Type:IdentityType,Verified:VerifiedForSendingStatus}'
    ```

    Salida esperada:

    ```json
    { "Type": "EMAIL_ADDRESS", "Verified": false }
    ```

    AWS envía un enlace de confirmación a esa dirección. Haga clic en él y luego:

    ```bash
    aws sesv2 get-email-identity --email-identity "you@example.com" \
      --query '{Verified:VerifiedForSendingStatus,DkimStatus:DkimAttributes.Status}'
    ```

    Salida esperada tras confirmar:

    ```json
    { "Verified": true, "DkimStatus": "NOT_STARTED" }
    ```

3. **Contraste con una identidad de dominio**, que es lo que se usa realmente en producción porque habilita la firma DKIM y le permite enviar desde cualquier dirección del dominio.

    ```bash
    aws sesv2 create-email-identity --email-identity "example.com" \
      --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT \
      --query 'DkimAttributes.Tokens' --output text
    ```

    Salida esperada (tres tokens CNAME que publica en DNS):

    ```
    7v3zqk4x2mhbn5r6t8y9uabcdefghijk  q2w3e4r5t6y7u8i9o0pasdfghjklzxcvb  m1n2b3v4c5x6z7l8k9j0hgfdsapoiuytr
    ```

4. **Cree un configuration set conectado a un event destination**, para que los bounces y las quejas sean procesables por máquina en lugar de descubrirse por una caída de reputación.

    ```bash
    aws sesv2 create-configuration-set --configuration-set-name transactional \
      --reputation-options ReputationMetricsEnabled=true \
      --suppression-options SuppressedReasons=BOUNCE,COMPLAINT

    aws sesv2 create-configuration-set-event-destination \
      --configuration-set-name transactional \
      --event-destination-name to-eventbridge \
      --event-destination '{"Enabled":true,"MatchingEventTypes":["BOUNCE","COMPLAINT","REJECT","DELIVERY_DELAY"],"EventBridgeDestination":{"EventBusArn":"arn:aws:events:us-east-1:'"$ACCT"':event-bus/default"}}'

    aws sesv2 get-configuration-set --configuration-set-name transactional \
      --query '{Name:ConfigurationSetName,Suppression:SuppressionOptions}'
    ```

    Salida esperada:

    ```json
    {
        "Name": "transactional",
        "Suppression": { "SuppressedReasons": ["BOUNCE", "COMPLAINT"] }
    }
    ```

5. **Inspeccione la lista de supresión a nivel de cuenta.**

    ```bash
    aws sesv2 list-suppressed-destinations --query 'SuppressedDestinationSummaries[].{Email:EmailAddress,Reason:Reason}' --output table
    ```

> **Checkpoint 6A**
>
> **Q6.1** La salida de `get-account` dice `"ProductionAccessEnabled": false`. Un colega reporta que la aplicación "puede enviar al equipo pero no a los clientes". Explique con precisión qué está ocurriendo y cuáles son las dos restricciones del sandbox.
> **Q6.2** ¿Por qué una identidad de *dominio* con DKIM es la elección de producción frente a una dirección de correo verificada? Nombre qué demuestra DKIM.
> **Q6.3** SES suprime automáticamente los hard bounces y las quejas. ¿Qué riesgo de negocio está protegiendo eso, y quién asume finalmente el costo si lo ignora?
> **Q6.4** En una línea cada uno, distinga **Amazon SES** de **Amazon Connect**. ¿Cuál es un contact center, y cuál es su modelo de precios?

6. **Sondee la API de AWS Support.** Esta llamada es en sí misma un diagnóstico de su plan de soporte.

    ```bash
    aws support describe-severity-levels --language en --region us-east-1
    ```

    En **Basic** o **Developer**, salida esperada:

    ```
    An error occurred (SubscriptionRequiredException) when calling the DescribeSeverityLevels operation: AWS Premium Support Subscription is required to use this service.
    ```

    En **Business** o superior, salida esperada:

    ```json
    {
        "severityLevels": [
            { "code": "low", "name": "General guidance" },
            { "code": "normal", "name": "System impaired" },
            { "code": "high", "name": "Production system impaired" },
            { "code": "urgent", "name": "Production system down" },
            { "code": "critical", "name": "Business-critical system down" }
        ]
    }
    ```

7. **Si —y solo si— la llamada anterior tuvo éxito**, liste las comprobaciones de Trusted Advisor:

    ```bash
    aws support describe-trusted-advisor-checks --language en --region us-east-1 \
      --query 'length(checks)' --output text
    ```

    Salida esperada en Business+:

    ```
    115
    ```

> **Checkpoint 6B**
>
> **Q6.5** La API de Support devolvió `SubscriptionRequiredException`. ¿Qué le dice ese único error sobre la cuenta, y por qué `--region us-east-1` está fijado en ambos comandos?
> **Q6.6** Ordene los cinco planes de soporte de menor a mayor capacidad, y dé el compromiso de tiempo de respuesta que aparece por primera vez en cada uno de los tres superiores.
> **Q6.7** ¿Qué nivel de plan otorga por primera vez (a) acceso telefónico y por chat 24/7 a ingenieros, (b) el conjunto *completo* de comprobaciones de Trusted Advisor más acceso programático, (c) un Technical Account Manager designado?
> **Q6.8** Asocie con **AWS Managed Services (AMS)** / **AWS IQ** / **AWS Activate for Startups** / **AWS Support**: (a) una empresa en etapa temprana quiere créditos promocionales y recursos técnicos; (b) una empresa regulada quiere que AWS se encargue del parcheo, los backups, la gestión de incidentes y el control de cambios en su nombre; (c) un equipo pequeño quiere contratar a un freelancer certificado en AWS y verificado para un trabajo corto, facturado a través de su cuenta de AWS; (d) hay una interrupción en curso y necesita abrir un caso con nivel de severidad.

---

# Ejercicio 7 — Capstone: identificación de categorías y triage

Sin recursos nuevos. Este es el ejercicio que el examen realmente mide.

### Pasos

1. **Lea cada uno de los ocho requisitos siguientes.** Para cada uno, anote (i) la *categoría* de la guía de examen y (ii) el único mejor *servicio* dentro del alcance.

    1. Desacoplar el paso de checkout de un monolito para que un fallo aguas abajo nunca pierda un pedido ni bloquee la capa web.
    2. Disparar una función de remediación cada vez que cualquier instancia EC2 de la cuenta pase a `stopped`, sin ningún cambio en el productor.
    3. Desplegar un kill switch para una funcionalidad riesgosa al 10 % del tráfico, sin reconstruir ni redesplegar la imagen del contenedor.
    4. Dar a 2.000 agentes estacionales de call center un teléfono en el navegador con grabación de llamadas y analítica, facturado por minuto de uso.
    5. Dar a un diseñador un escritorio Windows persistente con herramientas de Adobe, accesible desde una tablet.
    6. Almacenar los paquetes npm privados de la empresa para que los builds nunca dependan de que el registro público esté accesible.
    7. Encontrar cuál de once microservicios está agregando 3 segundos a una solicitud, usando un trace end-to-end por solicitud.
    8. Permitir que un gateway de planta de fábrica siga aplicando lógica de seguridad mientras el enlace WAN está caído, y luego suba los datos almacenados al reconectarse.

2. **Ahora haga triage de cuatro reportes de fallo.** Para cada uno, nombre la causa raíz *más probable* y el *primer* comando o métrica que revisaría.

    1. Una suscripción de SNS a una cola de SQS está `Confirmed`, las publicaciones devuelven un MessageId, y la cola nunca recibe nada.
    2. `PutEvents` devuelve `FailedEntryCount: 0`, `MatchedEvents` de EventBridge es 12, y la cola de destino está vacía.
    3. Un dispositivo IoT aparece como conectado en la consola, y ninguna telemetría llega jamás al target de la regla.
    4. `SendEmail` de SES tiene éxito para direcciones internas y devuelve `MessageRejected: Email address is not verified` para clientes.

> **Checkpoint 7**
>
> **Q7.1** Dé sus ocho pares categoría/servicio del paso 1.
> **Q7.2** Dé sus cuatro causas raíz y primeras comprobaciones del paso 2.
> **Q7.3** Una oración cada uno, sin rodeos: ¿cuándo elige **SQS**, **SNS** y **EventBridge**?
> **Q7.4** ¿Qué único servicio de la tarea 3.8 es el que los clientes ven *externamente* como la puerta de entrada de su producto — y cuál es el que sus *desarrolladores* ven como la puerta de entrada a AWS mismo?

---

## Limpieza

Ejecute esto completo. Todo lo creado arriba es gratis o trivialmente barato, pero dejar roles de IAM y certificados de IoT atrás es desprolijo y, en el caso de IoT, es una credencial viva.

```bash
# --- Application integration
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query 'Subscriptions[].SubscriptionArn' --output text | tr '\t' '\n' | \
  while read s; do [ "$s" != "PendingConfirmation" ] && aws sns unsubscribe --subscription-arn "$s"; done
aws sns delete-topic --topic-arn "$TOPIC_ARN"

for u in "$BILLING_URL" "$ANALYTICS_URL" "$DLQ_URL" "$FRAUD_URL" "$ALERT_URL"; do
  aws sqs delete-queue --queue-url "$u"
done

aws events remove-targets --rule high-value-eur-orders --event-bus-name acme-orders --ids fraud-queue
aws events delete-rule --name high-value-eur-orders --event-bus-name acme-orders
aws events delete-event-bus --name acme-orders

# --- Developer tools
aws appconfig delete-application --application-id "$APP_ID" 2>/dev/null || \
  echo "Delete environment/profile first if the application still has children"
aws apigatewayv2 delete-api --api-id "$API_ID"

# --- IoT (order matters: detach before delete)
aws iot delete-topic-rule --rule-name heat_alert
aws iot detach-thing-principal --thing-name edge-sensor-01 --principal "$CERT_ARN"
aws iot detach-policy --policy-name edge-sensor-policy --target "$CERT_ARN"
aws iot delete-policy --policy-name edge-sensor-policy
CERT_ID=$(basename "$CERT_ARN")
aws iot update-certificate --certificate-id "$CERT_ID" --new-status INACTIVE
aws iot delete-certificate --certificate-id "$CERT_ID"
aws iot delete-thing --thing-name edge-sensor-01
rm -f /tmp/device.pem.crt /tmp/private.pem.key /tmp/public.pem.key

aws iam delete-role-policy --role-name IoTRuleToSQS --policy-name SendToAlertQueue
aws iam delete-role --role-name IoTRuleToSQS

# --- SES (identities cost nothing; delete only if you do not want them)
# aws sesv2 delete-configuration-set --configuration-set-name transactional
# aws sesv2 delete-email-identity --email-identity "you@example.com"

# --- Final sweep
aws sqs list-queues --query 'QueueUrls' --output text
aws sns list-topics --query 'Topics[].TopicArn' --output text
```

El borrado de una cola tarda hasta 60 segundos en propagarse; durante ese período no se puede reutilizar el nombre.

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Amazon SQS Developer Guide — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
- Amazon SQS dead-letter queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- Amazon SQS FIFO queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html
- Amazon SNS Developer Guide — https://docs.aws.amazon.com/sns/latest/dg/welcome.html
- Amazon SNS fanout to SQS — https://docs.aws.amazon.com/sns/latest/dg/sns-sqs-as-subscriber.html
- Amazon EventBridge User Guide — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html
- EventBridge event patterns — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html
- EventBridge archive and replay — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-archive.html
- Amazon EventBridge Scheduler — https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
- AWS AppConfig User Guide — https://docs.aws.amazon.com/appconfig/latest/userguide/what-is-appconfig.html
- AWS CodeBuild buildspec reference — https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html
- AWS CodeDeploy AppSpec file reference — https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file.html
- AWS CodeArtifact User Guide — https://docs.aws.amazon.com/codeartifact/latest/ug/welcome.html
- AWS CodePipeline User Guide — https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html
- AWS X-Ray Developer Guide — https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html
- AWS X-Ray sampling rules — https://docs.aws.amazon.com/xray/latest/devguide/xray-console-sampling.html
- Amazon WorkSpaces Administration Guide — https://docs.aws.amazon.com/workspaces/latest/adminguide/amazon-workspaces.html
- Amazon AppStream 2.0 Developer Guide — https://docs.aws.amazon.com/appstream2/latest/developerguide/what-is-appstream.html
- Amazon WorkSpaces Secure Browser — https://docs.aws.amazon.com/workspaces-web/latest/adminguide/what-is-workspaces-web.html
- AWS Amplify User Guide — https://docs.aws.amazon.com/amplify/latest/userguide/welcome.html
- Amazon API Gateway Developer Guide — https://docs.aws.amazon.com/apigateway/latest/developerguide/welcome.html
- AWS Device Farm Developer Guide — https://docs.aws.amazon.com/devicefarm/latest/developerguide/welcome.html
- Amazon Pinpoint User Guide — https://docs.aws.amazon.com/pinpoint/latest/userguide/welcome.html
- AWS IoT Core Developer Guide — https://docs.aws.amazon.com/iot/latest/developerguide/what-is-aws-iot.html
- AWS IoT Core policy variables — https://docs.aws.amazon.com/iot/latest/developerguide/thing-policy-variables.html
- AWS IoT rules engine SQL reference — https://docs.aws.amazon.com/iot/latest/developerguide/iot-sql-reference.html
- AWS IoT Greengrass V2 Developer Guide — https://docs.aws.amazon.com/greengrass/v2/developerguide/what-is-iot-greengrass.html
- Amazon SES Developer Guide — https://docs.aws.amazon.com/ses/latest/dg/Welcome.html
- Amazon SES sandbox — https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html
- Amazon Connect Administrator Guide — https://docs.aws.amazon.com/connect/latest/adminguide/what-is-amazon-connect.html
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/getting-started.html
- AWS Support plan comparison — https://aws.amazon.com/premiumsupport/plans/
- AWS Managed Services User Guide — https://docs.aws.amazon.com/managedservices/latest/userguide/what-is-ams.html
- AWS Activate for Startups — https://aws.amazon.com/activate/
- AWS IQ — https://aws.amazon.com/iq/

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Fan-out de SNS hacia SQS

**Q1.1** La pieza que falta es la **política basada en recursos de SQS (queue access policy)** que otorga `sqs:SendMessage` al service principal `sns.amazonaws.com`. Suscribirse solo registra la *intención* de entregar del lado de SNS; no modifica la autorización de la cola. SQS es el propietario del recurso y evalúa su propia política en cada `SendMessage`. Como los fallos de entrega de SNS son asíncronos, nada aflora en su llamada a `publish` — el message ID que recibió confirma únicamente que SNS aceptó el mensaje. (Nota: crear la suscripción desde la consola de AWS *sí* ofrece escribir la política por usted; la CLI no, que es exactamente por qué el hueco es invisible en automatización.)

**Q1.2** SNS necesitó el **ARN de la cola** — los ARN son la identidad que se usa en IAM, en suscripciones y en referencias entre servicios. Su aplicación consumidora hace polling sobre la **URL de la cola**, que es el endpoint HTTPS del data plane que se pasa a `ReceiveMessage`/`DeleteMessage`. Confundirlos es uno de los errores más comunes de SQS; la API rechaza un ARN donde se espera una URL.

**Q1.3** Con raw message delivery **desactivado** (el valor por defecto), SNS envuelve su payload en un envelope JSON que contiene `Type`, `MessageId`, `TopicArn`, `Message` (su payload como string escapado), `Timestamp`, `SignatureVersion` y `Signature` — el consumidor debe parsear dos veces. Con `RawMessageDelivery=true`, la cola recibe su payload byte a byte, y los message attributes de SNS se convierten en message attributes de SQS. La contrapartida: pierde los metadatos y la firma de SNS, así que si el consumidor necesita el ARN del topic o quiere verificar la firma, déjelo desactivado.

**Q1.4** El consumidor nunca llamó a **`DeleteMessage`**. La entrega en SQS es un arrendamiento (lease), no un traspaso: `ReceiveMessage` hace invisible el mensaje durante el visibility timeout, y solo un `DeleteMessage` explícito (usando el receipt handle) lo elimina. Si el consumidor se cae, lanza una excepción o simplemente nunca borra, el mensaje reaparece al vencer el timeout, `ApproximateReceiveCount` se incrementa, y en cuanto supera `maxReceiveCount` la redrive policy lo mueve a la DLQ. Ese es el comportamiento correcto — la DLQ está poniendo en cuarentena un mensaje que falla repetidamente al ser procesado.

**Q1.5** Dos causas distintas, y se diagnostican de forma diferente:
1. **Los consumidores reciben pero no borran** (un bug de código, una excepción no manejada antes del delete, o un crash loop). Los mensajes entran y salen de vuelo para siempre; `ApproximateReceiveCount` sube y la DLQ se llena.
2. **El procesamiento tarda más que el visibility timeout.** El consumidor está trabajando de verdad, pero el lease expira a mitad del trabajo, el mensaje se reentrega a un segundo consumidor, y usted obtiene procesamiento duplicado más una cola que nunca se drena. Se arregla subiendo `VisibilityTimeout` por encima del p99 del tiempo de procesamiento, o llamando a `ChangeMessageVisibility` para extender el lease como heartbeat.

Una tercera causa, más rara: `ApproximateNumberOfMessagesNotVisible` también cuenta mensajes en un redrive de DLQ, y mensajes cuyo consumidor mantiene el lease legítimamente.

**Q1.6** Use una **cola FIFO** (`orders.fifo`). El ordenamiento se impone por **`MessageGroupId`** — asígnele el ID de cliente, de modo que los pedidos de cada cliente queden estrictamente ordenados mientras distintos clientes se procesan en paralelo. El procesamiento exactly-once lo aporta la deduplicación dentro de una ventana de 5 minutos, con clave en `MessageDeduplicationId` (explícito) o en un SHA-256 del body (`ContentBasedDeduplication=true`). El costo: el throughput queda acotado — 300 transacciones por segundo por acción de API sin batching, 3.000 por segundo con batches de 10 — frente al throughput prácticamente ilimitado de una cola estándar. El modo de alto throughput para FIFO eleva esto sustancialmente, pero la serialización por message group permanece. Note además la restricción de los topics FIFO: un **topic FIFO de SNS solo puede entregar a colas FIFO de SQS**.

**Q1.7** Directamente no — el tamaño máximo de mensaje de SQS es **256 KB**. El patrón estándar es el **claim-check**: almacenar el payload de 900 KB en **Amazon S3** y encolar un mensaje pequeño que contiene la clave del objeto. La Amazon SQS Extended Client Library implementa esto de forma transparente para payloads de hasta 2 GB.

**Q1.8** **SQS** cuando necesita un buffer durable que desacople la velocidad del productor de la del consumidor y cada mensaje debe ser procesado por exactamente un worker — colas de trabajo, nivelación de carga, reintentos con DLQ. **SNS** cuando un evento debe llegar de inmediato a muchos suscriptores independientes por push — fan-out, notificaciones, sin persistencia más allá de la política de reintentos.

### Ejercicio 2 — EventBridge

**Q2.1** `FailedEntryCount: 0` garantiza únicamente que **EventBridge aceptó e ingirió de forma durable el evento en el bus**. No dice nada sobre si alguna regla lo hizo coincidir, si se invocó algún target, o si el target tuvo éxito. Esta es la señal peor interpretada de la operación de EventBridge: ingestión exitosa y entrega exitosa son resultados separados y observables de forma independiente.

**Q2.2** **No, no coincidiría.** El matching de patterns de EventBridge es sensible al tipo: el matcher `numeric` solo se aplica a números JSON, y `"50"` es un string. Operativamente esto es grave — una deriva de esquema en el productor (un serializador que entrecomilla números, un lenguaje cuyo tipo big-decimal serializa como string) detiene silenciosamente el enrutamiento de eventos sin error en ninguna parte. `FailedEntryCount` sigue en 0, `MatchedEvents` cae calladamente a 0, y nada alarma salvo que esté observando `MatchedEvents` específicamente. Protéjase con un **schema registry** de EventBridge, contract tests del lado del productor, y una alarma de CloudWatch sobre `MatchedEvents` cayendo por debajo de un piso esperado.

**Q2.3** En el namespace `AWS/Events`, dimensionadas por `RuleName`:
- **`MatchedEvents`** — cuántos eventos coincidieron con el pattern. Cero significa que el pattern es incorrecto o que los eventos no están llegando a ese bus.
- **`Invocations`** (también `TriggeredRules`) — cuántas veces se invocó un target.
- **`FailedInvocations`** — invocaciones que EventBridge no pudo entregar ni siquiera tras los reintentos; son las que van a la dead-letter queue del target si configuró una.
- **`ThrottledRules`** e **`InvocationsSentToDlq`** completan el cuadro.

**Q2.4** `MatchedEvents` 5, `Invocations` 0 → la **regla coincidió pero no tiene un target funcional**: o no hay target adjunto, o la regla se deshabilitó después de coincidir, o el propio adjunto del target falló. Revise `aws events list-targets-by-rule`. `Invocations` 5, `FailedInvocations` 5 → el **target está rechazando o fallando**: casi siempre la política basada en recursos del target ausente o mal acotada (o, para un target basado en rol, un rol de IAM que EventBridge no puede asumir). Revise la política de recursos del target y la condición `aws:SourceArn` — una condición acotada al ARN de regla equivocado falla exactamente así.

**Q2.5**
- (a) **SQS** — necesita un buffer durable con backpressure; los workers hacen polling a su propio ritmo y la cola absorbe la ráfaga de 200.000 trabajos.
- (b) **SNS** — una publicación, muchos suscriptores push de protocolos heterogéneos (Lambda, SQS, HTTPS, email) sin lógica por suscriptor en el productor.
- (c) **EventBridge** — los eventos son eventos de servicios de AWS en el bus por defecto (no hay productor que cambiar), y la decisión de enrutamiento se basa en el contenido del campo de estado. Esto es precisamente lo que SNS no puede hacer sin filtrado del lado del suscriptor, y precisamente lo que SQS no puede hacer en absoluto.

**Q2.6** **Los archives y el replay de EventBridge.** Un archive retiene de forma durable los eventos que coincidieron durante un período de retención configurable, y `StartReplay` los reemite hacia una regla o bus elegidos, en un rango temporal especificado. SNS no puede hacer esto porque SNS no persiste mensajes — entrega con una política de reintentos y luego los descarta. La durabilidad de los mensajes en una arquitectura con SNS vive en los *suscriptores* (típicamente colas de SQS), no en el topic.

### Ejercicio 3 — Herramientas para desarrolladores

**Q3.1** AppConfig le permitió cambiar el **comportamiento en tiempo de ejecución (el valor de un feature flag)** sin construir un artefacto, publicar una imagen ni reiniciar un proceso — la configuración queda externalizada del código y la obtiene la aplicación en ejecución. La estrategia canary (`AppConfig.Canary10Percent20Minutes`) mitiga el riesgo de que la *configuración misma* sea la caída: expone primero una fracción pequeña de hosts, la deja reposar durante una ventana de monitoreo y —con alarmas de CloudWatch asociadas al entorno— **hace rollback automáticamente** si se dispara una alarma. La configuración defectuosa es una de las mayores causas de incidentes en producción precisamente porque esquiva la red de seguridad del pipeline de despliegue; AppConfig vuelve a poner esa red.

**Q3.2** Porque los dos planos tienen requisitos opuestos. El **control plane** es de bajo volumen, impulsado por humanos/CI, y crea estado (`create-application`, `start-deployment`). El **data plane** lo llaman todas las instancias en ejecución en cada intervalo de polling — alto volumen, sensible a la latencia, y debe seguir disponible incluso cuando el control plane está degradado. Separarlos permite a AWS escalarlos, limitarlos y aislarlos de forma independiente; es la misma razón por la que SQS tiene un control plane (`CreateQueue`) y un data plane (`SendMessage`), y por la que IoT Core tiene un endpoint `iot:Data-ATS` diferenciado.

**Q3.3**
- **AWS CodeCommit** — hosting gestionado de repositorios Git privados. *(Cerrado a nuevos clientes, julio de 2024.)*
- **AWS CodeArtifact** — repositorio gestionado de artefactos para gestores de paquetes (npm, PyPI, Maven, NuGet); hace de proxy y caché de los registros públicos.
- **AWS CodeBuild** — cómputo gestionado de build/test; ejecuta `buildspec.yml`, produce artefactos y reportes de pruebas.
- **AWS CodeDeploy** — orquestación de despliegues sobre EC2, on-premises, Lambda o ECS, con estrategias blue/green y canary dirigidas por `appspec.yaml`.
- **AWS CodePipeline** — el orquestador de CI/CD que encadena las etapas source → build → test → deploy, invocando los servicios anteriores.
- **Amazon CodeGuru** — **revisiones de código** guiadas por ML (CodeGuru Reviewer) y **profiling en ejecución** para puntos calientes de CPU/latencia (CodeGuru Profiler).
- **AWS X-Ray** — tracing distribuido: traces end-to-end de las solicitudes y un mapa de servicios entre microservicios.
- **AWS Cloud9** — IDE en la nube basado en navegador. *(Cerrado a nuevos clientes, julio de 2024.)*
- **AWS CodeStar** — plantillas de proyecto unificadas que conectan todo lo anterior. *(Fin de vida 2024-07-31.)*
- **AWS CLI** — el cliente de línea de comandos para todas las APIs de AWS, desde una terminal o un script.
- **AWS SDKs** — bibliotecas nativas por lenguaje (Python/boto3, JavaScript, Java, Go, .NET, Rust…) para llamar a las APIs de AWS desde el código de la aplicación.

**Q3.4** "Reservoir 1, rate 0.05" significa: **trazar la primera solicitud de cada segundo incondicionalmente, y luego muestrear el 5 % de todo lo que exceda esa primera solicitud en ese segundo.** El reservoir garantiza que siempre tenga *algún* trace incluso en un servicio casi inactivo (donde el 5 % de 2 solicitudes redondearía a nada); el porcentaje mantiene acotado el costo en uno con mucha carga. AWS no usa 100 % por defecto porque el tracing tiene tres costos —cargos de almacenamiento por trace, CPU y memoria del agente dentro de su aplicación, y egress de red de los documentos de segmento— y porque para un análisis estadístico de latencia una muestra del 5 % es suficiente. Cuando necesita todos los traces (un flujo de bajo volumen y alto valor como la autorización de pagos), cree una regla de mayor prioridad acotada a ese servicio o a esa ruta de URL.

**Q3.5** **AWS X-Ray.** Las métricas de CloudWatch por servicio muestran la duración *propia* de cada componente aisladamente; no pueden mostrar el tiempo transcurrido **entre** componentes — establecimiento de conexión, DNS, espera en cola, reintentos, cold starts, o una llamada HTTP lenta a un tercero dentro de un segmento. X-Ray cose los segmentos y subsegmentos de cada salto en un único trace con un trace ID compartido, así que la brecha de 3 segundos aparece como un span visible en la línea de tiempo atribuible a un subsegmento específico. El mapa de servicios luego lo muestra como una arista, no como un nodo — que es exactamente por qué las métricas por servicio se veían "normales".

**Q3.6** **AWS Cloud9** y **AWS CodeStar** (y **AWS CodeCommit**, si cuenta tres). Reemplazos prácticos: para Cloud9, un IDE local con la extensión AWS Toolkit, o un IDE en navegador construido sobre su propio contenedor; para CodeStar, cablear CodePipeline/CodeBuild/CodeDeploy usted mismo con infraestructura como código (CloudFormation o CDK); para CodeCommit, GitHub, GitLab o Bitbucket — todos los cuales CodePipeline soporta como fuentes vía CodeConnections. En el examen igual debe reconocer los tres por nombre y función.

### Ejercicio 4 — Computación para el usuario final y frontend/móvil

**Q4.1**
- (a) **Amazon WorkSpaces Web / Secure Browser.** Característica decisiva: la carga de trabajo es *solo web*, las sesiones son *efímeras* y los endpoints *no están administrados*. Transmite un navegador gestionado basado en Chrome — no hay escritorio virtual que aprovisionar, y nada (cookies, descargas, historial) sobrevive a la sesión en el endpoint.
- (b) **Amazon WorkSpaces.** Característica decisiva: **persistencia**. Las aplicaciones, la configuración y los archivos del usuario deben sobrevivir al cierre de sesión — eso es un escritorio virtual Desktop-as-a-Service completo, no una aplicación transmitida.
- (c) **Amazon AppStream 2.0.** Característica decisiva: **una única aplicación, transmitida a escala y no persistente**. Publica la aplicación CAD desde una imagen, una flota escala para el laboratorio y no se retiene nada después (salvo que habilite explícitamente carpetas home).

**Q4.2** **Amazon WorkSpaces**, porque un WorkSpace es un escritorio virtual aprovisionado y persistente que existe esté o no alguien conectado. El costo se controla con el **modo de facturación**: *AlwaysOn* cobra una tarifa mensual fija por WorkSpace (adecuada para usuarios de tiempo completo), mientras que *AutoStop* cobra una pequeña tarifa mensual fija por el almacenamiento más una tarifa por hora solo mientras el WorkSpace está en ejecución (adecuada para usuarios de tiempo parcial), deteniéndolo automáticamente tras un período de inactividad configurable. Elegir AlwaysOn para usuarios ocasionales es el sobrecosto clásico de WorkSpaces.

**Q4.3**
- (a) **AWS Device Farm** — pruebas en dispositivos físicos reales en la nube, tanto ejecuciones automatizadas como acceso remoto interactivo.
- (b) **AWS Amplify** — hosting y CI/CD para aplicaciones web frontend, con builds basados en ramas de Git y entornos de vista previa por pull request.
- (c) **Amazon API Gateway** — la puerta de entrada gestionada para APIs: APIs REST/HTTP/WebSocket, stages y versiones, throttling, autorización, caché.
- (d) **Amazon Pinpoint** — engagement saliente multicanal: segmentos, campañas y journeys por email, SMS, push y voz, con analítica de interacción.

**Q4.4** **Amazon SES es el motor de envío; Amazon Pinpoint es la capa de marketing/engagement por encima de él.** SES es un servicio SMTP y de API de alta escala para correo *transaccional y masivo* —recibos, restablecimientos de contraseña, notificaciones— donde su aplicación decide quién recibe qué y cuándo. Pinpoint es dueño de la *audiencia*: perfiles de usuario, endpoints, segmentación, programación de campañas, journeys de varios pasos, pruebas A/B y analítica de interacción, y abarca SMS, push y voz además de email. Si la pregunta es "cómo entrego este mensaje", es SES. Si es "quién debería recibir esta campaña, por qué canal, y funcionó", es Pinpoint.

**Q4.5** **No — una API key en un usage plan no es autenticación.** Las API keys identifican a un *llamante con fines de medición y throttling* (cuotas de solicitudes, límites de tasa y de ráfaga por consumidor), y las transmite el cliente, así que cualquiera que obtenga una puede presentarla. La documentación de AWS es explícita en que las API keys no deben usarse como medio principal para autorizar el acceso. La autorización real en API Gateway proviene de IAM (SigV4), un Lambda authorizer, un JWT authorizer o un authorizer de user pool de Amazon Cognito — combinados *con* el usage plan, no reemplazados por él.

### Ejercicio 5 — IoT

**Q5.1** La variable de política hace que **un solo documento de política sirva a toda la flota**: en el momento de la conexión, IoT Core sustituye el nombre del thing que se conecta, de modo que el dispositivo 47.912 obtiene una política acotada a su propio client ID y a sus propios topics sin que usted escriba 50.000 documentos ni realice 50.000 attachments de política. La propiedad de seguridad es la **contención del movimiento lateral**: un dispositivo cuya clave privada sea extraída aún no puede conectarse como otro dispositivo (`iot:Connect` está acotado a `client/${...ThingName}`), no puede publicar telemetría falsificada en el topic de un par, ni suscribirse al canal de comandos de un par. Sin la variable, o bien escribe políticas por dispositivo (inmanejable) o bien otorga acceso con comodín a los topics (un sensor comprometido se adueña de la flota).

**Q5.2** Mire **la política de IoT adjunta al certificado** — una denegación de `iot:Publish` para el topic en cuestión es, de lejos, la causa más probable. MQTT no tiene un canal de error a nivel de aplicación para un fallo de autorización en un publish con QoS 0, así que el broker simplemente descarta el mensaje y el dispositivo no ve nada. Diagnostique habilitando el **logging de AWS IoT hacia CloudWatch Logs** (`aws iot set-v2-logging-options --default-log-level DEBUG --role-arn ...`), que emite un evento explícito de fallo de autorización nombrando el topic y la política evaluada. Causas específicas comunes: el topic en la política es `topic/sensors/...` pero el dispositivo publica en `sensors/.../telemetry` con otro nombre de thing; o se usó `topicfilter/` donde correspondía `topic/` (son tipos de recurso distintos — `topicfilter` para `Subscribe`, `topic` para `Publish` y `Receive`).

**Q5.3** Dos beneficios:
1. **Costo.** Se le factura la mensajería de AWS IoT Core y la evaluación del rules engine, pero el costo *aguas abajo* —invocaciones de Lambda, solicitudes de SQS, almacenamiento— se incurre solo por el ~0,1 % de las lecturas que son realmente alertas. Reenviar el 100 % de la telemetría a una Lambda para descartar el 99,9 % multiplica por mil la factura downstream.
2. **Latencia y radio de impacto.** El filtrado ocurre en el rules engine gestionado durante la ingesta, así que la ruta de alerta tiene un salto menos, y un bug o un throttle en su Lambda no puede demorar ni descartar alertas por lecturas sobre las que nunca iba a actuar. También mantiene la profundidad de la cola de alertas como una señal operativa significativa en vez de una manguera de datos.

**Q5.4** **AWS IoT Greengrass** (v2). Las tres capacidades en las que se apoya:
1. **Cómputo local y enrutamiento local de mensajes** — los componentes de Greengrass y el broker local de publish/subscribe ejecutan la lógica de parada en el propio gateway, así que la decisión de 200 ms nunca atraviesa la WAN.
2. **Operación offline con device shadows locales** — los dispositivos siguen interactuando con un shadow local y el gateway sigue funcionando sin conectividad a la nube durante las seis horas completas.
3. **Stream manager** — almacena la telemetría en disco local con políticas de retención y subida configurables, y luego la drena hacia AWS IoT Core / Kinesis / S3 automáticamente cuando vuelve el enlace.

**Q5.5** **AWS IoT Core** es el gateway gestionado en la nube para dispositivos: autentica dispositivos con certificados X.509, hace de broker MQTT (y MQTT sobre WSS, HTTPS, LoRaWAN) a escala de flota, mantiene device shadows y enruta mensajes hacia otros servicios de AWS mediante el rules engine. **Se ejecuta en la Región de AWS.** **AWS IoT Greengrass** es un runtime de borde de código abierto más un servicio en la nube para desplegarlo y gestionarlo: **se ejecuta en su propio hardware en el borde** (un gateway, una PC industrial, un vehículo) y aporta cómputo local, mensajería local, inferencia de ML y buffering offline a dispositivos que no pueden depender de un enlace constante a la nube.

**Q5.6** `iot:Data-ATS` devuelve el endpoint cuyo certificado de servidor encadena a una CA raíz de **Amazon Trust Services**. El endpoint heredado encadenaba a una raíz Symantec/VeriSign en la que los navegadores y los almacenes de confianza de los sistemas operativos dejaron de confiar; los dispositivos cuyo almacén de confianza ya no contiene esa raíz fallan el handshake TLS y no pueden conectarse en absoluto. ATS es la elección obligatoria para todos los dispositivos nuevos — el modo de fallo práctico de equivocarse aquí es una flota que se aprovisiona bien en el laboratorio (donde la raíz vieja sigue cacheada) y no puede conectarse en el campo.

### Ejercicio 6 — Aplicaciones de negocio y relación con el cliente

**Q6.1** La cuenta está en el **sandbox de Amazon SES**, donde toda cuenta nueva comienza. Las dos restricciones son:
1. **Solo puede enviar *a* identidades verificadas.** Las direcciones de sus compañeros se verificaron durante la configuración, así que esos envíos tienen éxito; una dirección arbitraria de cliente no está verificada, así que SES rechaza el envío con `MessageRejected: Email address is not verified`. (Enviar *desde* una identidad verificada es obligatorio dentro y fuera del sandbox — el sandbox además restringe al destinatario.)
2. **Cuotas duras** — 200 mensajes por período de 24 horas y una tasa máxima de envío de 1 mensaje por segundo.

La solución es solicitar acceso de producción (`aws sesv2 put-account-details` o la opción "Request production access" de la consola), describiendo su caso de uso, su manejo de bounces/quejas y cómo dieron su consentimiento los destinatarios. AWS lo revisa manualmente.

**Q6.2** Una identidad de dominio le permite enviar desde **cualquier dirección del dominio** (`noreply@`, `support@`, `billing@`) sin verificar cada una y —de forma crítica— es el único tipo de identidad que soporta **firma DKIM**, porque DKIM requiere publicar claves públicas como registros DNS bajo el dominio que usted controla. DKIM demuestra **que el cuerpo y las cabeceras del mensaje no fueron alterados en tránsito y que el dominio remitente autorizó el mensaje**, mediante una firma criptográfica que el receptor verifica contra su clave publicada en DNS. Junto con SPF (que autoriza las IP de envío) y una política DMARC (que indica a los receptores qué hacer ante un fallo), es lo que mantiene su correo fuera de las carpetas de spam e impide que terceros suplanten su dominio.

**Q6.3** Protege su **reputación como remitente**, que es el activo real. Los proveedores de buzones rastrean las tasas de bounce y de quejas por identidad de envío y por IP de envío; tasas altas sostenidas hacen que su correo sea limitado, enviado a spam o bloqueado directamente — y en IP compartidas de SES su comportamiento degrada al resto de los inquilinos, que es por qué AWS lo impone en lugar de solo recomendarlo. AWS pondrá la cuenta **bajo revisión** y finalmente **pausará el envío** (`EnforcementStatus` pasa de `HEALTHY` a `UNDER_REVIEW` y a `SHUTDOWN`). El costo final lo asume **su negocio**: los restablecimientos de contraseña, los recibos y las alertas de seguridad dejan de llegar a los clientes, y reconstruir la reputación quemada de un dominio lleva de semanas a meses.

**Q6.4** **Amazon SES** es un servicio de **envío y recepción de correo electrónico** masivo y transaccional — un endpoint SMTP y una API, con precio por mensaje. **Amazon Connect** es un **contact center omnicanal** totalmente gestionado y basado en la nube — voz entrante y saliente, chat, enrutamiento de tareas, flujos IVR construidos en un diseñador visual, espacio de trabajo del agente y analítica con Contact Lens. Connect es el contact center, y su modelo de precios es **pago por uso por minuto** de servicio al cliente final (más los cargos de telefonía), sin licencias por agente y sin compromiso mínimo.

**Q6.5** `SubscriptionRequiredException` le dice que la cuenta está en soporte **Basic o Developer** — la API de AWS Support (y por lo tanto el acceso programático a Trusted Advisor) solo está disponible en **Business, Enterprise On-Ramp y Enterprise**. `--region us-east-1` está fijado porque la API de AWS Support es un **servicio global con un único endpoint en `us-east-1`** (`support.us-east-1.amazonaws.com`); llamarla desde otra Región no resuelve. Lo mismo aplica a la superficie de API de Trusted Advisor.

**Q6.6** De menor a mayor capacidad: **Basic → Developer → Business → Enterprise On-Ramp → Enterprise.** Compromisos de tiempo de respuesta que aparecen por primera vez en los tres superiores:
- **Business** — *sistema de producción caído* en **1 hora**; acceso 24/7 a Cloud Support Engineers por teléfono, chat y correo.
- **Enterprise On-Ramp** — *sistema crítico para el negocio caído* en **30 minutos**, un nivel de severidad nuevo por encima del más alto de Business.
- **Enterprise** — *sistema crítico para el negocio caído* en **15 minutos**, el compromiso más rápido que ofrece AWS.

(Como referencia, Developer ofrece orientación general en 24 horas hábiles y sistema degradado en 12 horas hábiles, solo en horario laboral, solo por correo, con un único contacto principal.)

**Q6.7**
- (a) **Business** — el primer nivel con acceso 24/7 por teléfono y chat a Cloud Support Engineers, y contactos ilimitados con capacidad de abrir casos.
- (b) **Business** — el primer nivel con el conjunto completo de comprobaciones de Trusted Advisor en los cinco pilares más acceso programático a través de la API de Support. Basic y Developer reciben solo un subconjunto limitado (cuotas de servicio y comprobaciones básicas de seguridad).
- (c) **Enterprise** — el único nivel con un Technical Account Manager **designado**. Enterprise On-Ramp provee un *pool* de TAM, que deliberadamente no es el mismo compromiso; tanto On-Ramp como Enterprise incluyen soporte Concierge.

**Q6.8**
- (a) **AWS Activate for Startups** — créditos promocionales, créditos de soporte técnico, capacitación y recursos de go-to-market para empresas en etapa temprana elegibles.
- (b) **AWS Managed Services (AMS)** — AWS opera su infraestructura de AWS en su nombre: parcheo, backup, monitoreo, gestión de incidentes y de cambios sobre un modelo operativo alineado con ITIL. Note la distinción con Support: Support lo asesora, AMS *opera por usted*.
- (c) **AWS IQ** — lo conecta con expertos independientes y firmas certificados por AWS para trabajos cortos y acotados, contratados y facturados a través de su cuenta de AWS.
- (d) **AWS Support** — el canal basado en casos hacia los Cloud Support Engineers de AWS, con un nivel de severidad acorde al impacto en el negocio.

### Ejercicio 7 — Capstone

**Q7.1**
1. **Integración de aplicaciones → Amazon SQS.** Buffer durable; la cola absorbe el fallo aguas abajo sin generar contrapresión sobre la capa web, y una DLQ pone en cuarentena los mensajes envenenados.
2. **Integración de aplicaciones → Amazon EventBridge.** Los eventos de cambio de estado de EC2 llegan al bus por defecto sin participación del productor, y el pattern de la regla selecciona `stopped` específicamente.
3. **Herramientas para desarrolladores → AWS AppConfig.** Feature flags externalizados con despliegues validados, monitoreados y con rollback automático, desacoplados del ciclo de vida del artefacto.
4. **Servicios de aplicaciones de negocio → Amazon Connect.** Contact center omnicanal en la nube con un espacio de trabajo del agente basado en navegador, grabación de llamadas y analítica con Contact Lens; con precio por minuto.
5. **Computación para el usuario final → Amazon WorkSpaces.** Escritorio virtual DaaS persistente con las aplicaciones y archivos instalados del usuario, accesible desde thin clients y tablets.
6. **Herramientas para desarrolladores → AWS CodeArtifact.** Repositorio privado de paquetes que además hace de proxy y caché de registros públicos upstream, de modo que una caída del registro público no puede romper sus builds.
7. **Herramientas para desarrolladores → AWS X-Ray.** Traces distribuidos end-to-end y un mapa de servicios, que es la única forma de atribuir latencia a un salto específico entre once servicios.
8. **IoT → AWS IoT Greengrass.** Cómputo local y mensajería local en el borde, con stream manager almacenando en disco y sincronizando al reconectar.

**Q7.2**
1. **Falta la queue access policy de SQS** que otorgue `sqs:SendMessage` al principal `sns.amazonaws.com` (o una política cuya condición `aws:SourceArn` no coincide con el topic). Primera comprobación: `aws sqs get-queue-attributes --queue-url "$URL" --attribute-names Policy`. Verifique del lado de SNS con `aws sns get-subscription-attributes` los fallos de entrega.
2. **El target está mal configurado o no autorizado** — la regla coincidió, así que el pattern es correcto. Casi con certeza a la política de recursos de la cola le falta el principal `events.amazonaws.com`, o el `aws:SourceArn` nombra el ARN de regla equivocado, o no hay ningún target adjunto. Primera comprobación: `aws events list-targets-by-rule --rule <name> --event-bus-name <bus>`, y luego la métrica `FailedInvocations` de `AWS/Events` en CloudWatch para esa regla.
3. **La política de IoT deniega `iot:Publish`** en el topic que el dispositivo está usando (o el patrón de topic en la cláusula `FROM` de la regla no coincide con el topic al que se publica). La conexión tuvo éxito porque `iot:Connect` está concedido; los publishes se descartan silenciosamente. Primera comprobación: habilitar `aws iot set-v2-logging-options --default-log-level DEBUG --role-arn ...` y leer los eventos de fallo de autorización en CloudWatch Logs; luego comparar los ARN de recurso de la política contra el topic real y el `FROM 'sensors/+/telemetry'` del SQL de la regla.
4. **La cuenta está en el sandbox de SES.** Las direcciones internas fueron verificadas como identidades y por lo tanto aceptadas como destinatarias; las direcciones de clientes no. Primera comprobación: `aws sesv2 get-account --query ProductionAccessEnabled`. Remedio: solicitar acceso de producción.

**Q7.3**
- **SQS** — cuando el trabajo debe amortiguarse de forma durable y ser procesado por exactamente un consumidor, desacoplando la tasa del productor de la del consumidor.
- **SNS** — cuando un evento debe empujarse de inmediato a muchos suscriptores independientes a través de protocolos heterogéneos.
- **EventBridge** — cuando el enrutamiento debe decidirse por el *contenido* del evento entre servicios de AWS, socios SaaS y sus propias aplicaciones, con el productor sin saber nada de los consumidores.

**Q7.4** Externamente, **Amazon API Gateway** — es la puerta de entrada gestionada que llaman los clientes y los sistemas socios, donde se imponen throttling, autorización, versionado y caché. Internamente, la **AWS CLI y los AWS SDKs** — cada persona y cada programa llega a AWS mismo a través de ellos; cada clic en la consola y cada terraform apply resuelven a esas mismas llamadas de API subyacentes.

</details>