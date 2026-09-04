# Tema 3.8 — Identificar servicios de otras categorías de servicios de AWS incluidas en el alcance

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02), versión 1.0
**Dominio 3:** Tecnología y servicios de la nube
**Enunciado de tarea 3.8** — peso en el examen ≈ 4,25 %
**Nivel:** Principal Platform Architect / Senior SRE

---

## 0. Alcance de este enunciado de tarea

El enunciado de tarea 3.8 es el cajón del "todo lo demás" del Dominio 3. Después de cómputo (3.3), base de datos (3.4), red (3.5), almacenamiento (3.6) y AI/ML + analítica (3.7), lo que queda son **siete categorías de servicios** que la guía del examen CLF-C02 enumera explícitamente:

| Categoría | Servicios dentro del alcance (apéndice CLF-C02) |
|---|---|
| Integración de aplicaciones | Amazon EventBridge, Amazon SNS, Amazon SQS, AWS Step Functions |
| Aplicaciones de negocio | Amazon Connect, Amazon SES |
| Interacción con el cliente | AWS Activate for Startups, AWS IQ, AWS Managed Services (AMS), AWS Support |
| Herramientas para desarrolladores | AWS AppConfig, AWS CLI, AWS Cloud9, AWS CloudShell, AWS CodeArtifact, AWS CodeBuild, AWS CodeCommit, AWS CodeDeploy, Amazon CodeGuru, AWS CodePipeline, AWS CodeStar, AWS X-Ray |
| Computación para el usuario final | Amazon AppStream 2.0, Amazon WorkSpaces, Amazon WorkSpaces Web (ahora con la marca *WorkSpaces Secure Browser*) |
| Web y móvil de front-end | AWS Amplify, AWS AppSync, AWS Device Farm |
| IoT | AWS IoT Core, AWS IoT Greengrass |

> **Contraste con la realidad de producción que el examen no imprime.** Tres servicios de la lista de Herramientas para desarrolladores están en postura de fin de vida: **AWS CodeStar** llegó al fin de su vida útil el 2024-07-31, y **AWS CodeCommit** y **AWS Cloud9** quedaron cerrados a nuevos clientes el 2024-07-25 (los clientes existentes conservan el acceso). Siguen siendo examinables porque la guía del examen está congelada en la versión 1.0, pero nunca debés proponerlos para una plataforma greenfield. Los sustitutos arquitectónicamente honestos son: CodeCommit → GitHub/GitLab/Bitbucket mediante una CodeStar Connection; Cloud9 → AWS CloudShell o un IDE local con el AWS Toolkit; CodeStar → CodePipeline + CloudFormation/CDK directamente.

---

## 1. Motivación: el problema arquitectónico que resuelven estas categorías

Tomemos un sistema de producción concreto — una flota de 40.000 sensores industriales que alimenta un producto SaaS de observabilidad:

```
[edge gateways] --MQTT/TLS--> [IoT Core] --rules--> [EventBridge bus]
                                                          |
                        +---------------------------------+-----------------+
                        |                 |                                 |
                  [SQS work queue]   [SNS fan-out]                   [Step Functions]
                        |                 |                                 |
                  [ECS consumers]   [ops paging + SES email]        [remediation saga]
                        |
                  [X-Ray traces] <---- [AppConfig feature flags]
                        |
                  [CodePipeline: CodeBuild -> CodeDeploy blue/green]
```

Cada caja fuera de cómputo/almacenamiento/base de datos/red pertenece al enunciado de tarea 3.8. Eso no es una coincidencia. **Las categorías de 3.8 son el tejido conectivo de un sistema distribuido**: cómo hablan los componentes sin conocerse entre sí (integración de aplicaciones), cómo llega el sistema a las personas (aplicaciones de negocio, computación para el usuario final, front-end), cómo llega al hardware físico (IoT), cómo el código pasa de un commit a producción de forma segura (herramientas para desarrolladores), y cómo conseguís ayuda cuando se rompe a las 03:00 (interacción con el cliente).

El modo de falla arquitectónico que estos servicios existen para prevenir es el **acoplamiento síncrono**. Si tu ingestor de telemetría llama al servicio de alertas por HTTP y el servicio de alertas está degradado, los hilos del ingestor se bloquean, la profundidad de su cola crece, el balanceador de carga empieza a fallar los health checks, y un subsistema no crítico tira abajo uno crítico. Las colas, los tópicos y los buses de eventos rompen esa cadena convirtiendo una *llamada* en un *mensaje durable*. La compensación que estás comprando es: **disponibilidad y escalado independiente a cambio de consistencia eventual, entrega duplicada y la carga operativa del manejo de dead-letter**. Esa compensación es la idea más examinable de todo este enunciado de tarea.

---

## 2. Integración de aplicaciones

### 2.1 Las tres primitivas y en qué se diferencian realmente

| Dimensión | Amazon SQS | Amazon SNS | Amazon EventBridge |
|---|---|---|---|
| Patrón | Cola punto a punto (pull) | Tópico pub/sub (push) | Bus de eventos + enrutador (push, basado en reglas) |
| Consumidores | Un grupo lógico de consumidores; el mensaje se borra tras procesarse | Muchos suscriptores, cada uno recibe una copia | Muchos targets, seleccionados por patrón de evento |
| Semántica de entrega | Al menos una vez (Standard); procesamiento exactamente una vez (FIFO) | Al menos una vez | Al menos una vez |
| Ordenamiento | Best-effort (Standard); estricto por `MessageGroupId` (FIFO) | Best-effort; estricto en tópicos FIFO | No garantizado |
| Retención de mensajes | 1 min – **14 días** (por defecto 4 días) | Ninguna — no es durable si no hay suscriptor | **Archive** (retención configurable) + **Replay** |
| Filtrado | Ninguno (filtra el consumidor) | Políticas de filtro por suscripción sobre atributos/cuerpo | Patrones de evento ricos basados en contenido (prefix, numeric, `anything-but`, `exists`) |
| Límite de payload | 256 KB (2 GB vía Extended Client Library + S3) | 256 KB | 256 KB |
| Backpressure | Nativo — el consumidor hace pull a su propio ritmo | Ninguno — el suscriptor debe absorber el push | Ninguno — el target debe absorber el push |
| Reintento / DLQ nativos | Redrive policy → DLQ tras `maxReceiveCount` | Política de reintento de entrega + DLQ por suscripción | Reintento hasta 24 h + DLQ por target |
| Entre cuentas / entre Regiones | Política de recurso | Política de recurso | Enrutamiento bus a bus, nativo entre Regiones |
| Ingreso de terceros / SaaS | No | No | **Sí** — partner event sources, API destinations |
| Latencia típica | ms (más el intervalo de polling) | ms | ~ms, cola de latencia más alta que SNS |
| Modelo de precio | Por solicitud (el batching de 10 lo amortiza) | Por publicación + por entrega | Por evento publicado en un bus personalizado (los eventos de servicios de AWS en el bus por defecto son gratis) |

**La regla de decisión que usa un arquitecto:**

- Necesitás **distribución durable de trabajo con backpressure** y una sola flota de workers → **SQS**.
- Necesitás **el mismo mensaje entregado a N subsistemas independientes**, baja latencia, push → **SNS**.
- Necesitás **enrutamiento por contenido, ingesta de eventos de servicios de AWS o SaaS, descubrimiento de esquemas, replay** → **EventBridge**.
- Necesitás **orquestación con estado, de larga duración, auditable, con reintentos y compensación** → **Step Functions** (un motor de workflows, no un bus de mensajes).

**El patrón canónico de producción no es "o uno u otro" — es el fan-out SNS → SQS.** Un tópico hace push a varias colas; cada servicio consumidor obtiene su propio búfer durable, su propio presupuesto de reintentos, su propia DLQ, y puede estar caído durante horas sin perder datos. EventBridge se ubica adelante cuando los eventos provienen de los propios servicios de AWS (un cambio de estado de EC2, una tarea de ECS deteniéndose, una etapa de CodePipeline fallando).

### 2.2 Los cuatro parámetros de SQS que causan la mayoría de los incidentes de producción

| Parámetro | Por defecto | Falla que causa cuando está mal |
|---|---|---|
| `VisibilityTimeout` | 30 s (máx. 12 h) | Más corto que el tiempo real de procesamiento → otro consumidor recibe el mismo mensaje → **efectos secundarios duplicados** y reprocesamiento infinito |
| `ReceiveMessageWaitTimeSeconds` | 0 (short polling) | El short polling muestrea un subconjunto de servidores → respuestas vacías, mayor costo, señales falsas de "la cola está vacía". Ponelo en **20** (long polling) |
| `maxReceiveCount` (redrive) | ninguno | Sin una DLQ, un mensaje envenenado se reintenta hasta que expire la retención, consumiendo toda la flota de consumidores |
| `MessageRetentionPeriod` | 4 días | Demasiado corto → pérdida silenciosa de datos durante una interrupción larga; demasiado largo → un backlog que nunca vas a poder drenar |

### 2.3 Infraestructura completa — CloudFormation (ingesta de eventos + fan-out + DLQ)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Topic 3.8 reference stack - EventBridge routing into an SNS fan-out with two
  independent SQS consumers, each with its own dead-letter queue and alarms.

Parameters:
  ProjectName:
    Type: String
    Default: fleet-telemetry
    AllowedPattern: '^[a-z0-9-]{3,32}$'
  AlertEmail:
    Type: String
    Description: Subscribed to the operational alarm topic.
    AllowedPattern: '^[^@]+@[^@]+\.[^@]+$'
  MessageRetentionDays:
    Type: Number
    Default: 14
    MinValue: 1
    MaxValue: 14

Resources:

  # ------------------------------------------------------------------
  # Custom event bus. AWS-service events land on the default bus;
  # application events belong on a bus you own, so you can attach
  # an archive and a schema discoverer without touching the default bus.
  # ------------------------------------------------------------------
  TelemetryBus:
    Type: AWS::Events::EventBus
    Properties:
      Name: !Sub '${ProjectName}-bus'

  TelemetryArchive:
    Type: AWS::Events::Archive
    Properties:
      ArchiveName: !Sub '${ProjectName}-archive'
      SourceArn: !GetAtt TelemetryBus.Arn
      RetentionDays: 30
      Description: Enables replay of ingested events after a consumer bug fix.
      EventPattern:
        source:
          - com.example.fleet

  # ------------------------------------------------------------------
  # SNS fan-out topic. Standard (not FIFO) because the two consumers
  # are independent and neither requires cross-device ordering.
  # ------------------------------------------------------------------
  AlarmFanoutTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${ProjectName}-alarm-fanout'
      DisplayName: Fleet alarm fan-out
      KmsMasterKeyId: alias/aws/sns

  AlarmFanoutTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref AlarmFanoutTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: sns:Publish
            Resource: !Ref AlarmFanoutTopic
            Condition:
              ArnLike:
                aws:SourceArn: !Sub 'arn:${AWS::Partition}:events:${AWS::Region}:${AWS::AccountId}:rule/${ProjectName}-bus/*'
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId

  # ------------------------------------------------------------------
  # Consumer 1: persistence pipeline. Standard queue, long polling,
  # visibility timeout deliberately 6x the p99 processing time.
  # ------------------------------------------------------------------
  PersistenceDlq:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${ProjectName}-persistence-dlq'
      MessageRetentionPeriod: 1209600   # 14 days, always the max on a DLQ
      SqsManagedSseEnabled: true

  PersistenceQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${ProjectName}-persistence'
      VisibilityTimeout: 180
      ReceiveMessageWaitTimeSeconds: 20         # long polling
      MessageRetentionPeriod: !Ref MessageRetentionDays  # see Note below
      SqsManagedSseEnabled: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt PersistenceDlq.Arn
        maxReceiveCount: 5

  # ------------------------------------------------------------------
  # Consumer 2: remediation pipeline. FIFO, because remediation
  # commands for the SAME gateway must be applied in order.
  # ------------------------------------------------------------------
  RemediationDlq:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${ProjectName}-remediation-dlq.fifo'
      FifoQueue: true
      MessageRetentionPeriod: 1209600
      SqsManagedSseEnabled: true

  RemediationQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${ProjectName}-remediation.fifo'
      FifoQueue: true
      ContentBasedDeduplication: true
      DeduplicationScope: messageGroup
      FifoThroughputLimit: perMessageGroupId    # high-throughput FIFO mode
      VisibilityTimeout: 300
      ReceiveMessageWaitTimeSeconds: 20
      SqsManagedSseEnabled: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt RemediationDlq.Arn
        maxReceiveCount: 3

  QueuePolicies:
    Type: AWS::SQS::QueuePolicy
    Properties:
      Queues:
        - !Ref PersistenceQueue
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowSnsDelivery
            Effect: Allow
            Principal:
              Service: sns.amazonaws.com
            Action: sqs:SendMessage
            Resource: !GetAtt PersistenceQueue.Arn
            Condition:
              ArnEquals:
                aws:SourceArn: !Ref AlarmFanoutTopic

  PersistenceSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref AlarmFanoutTopic
      Protocol: sqs
      Endpoint: !GetAtt PersistenceQueue.Arn
      RawMessageDelivery: true          # deliver the payload, not the SNS envelope
      FilterPolicyScope: MessageBody
      FilterPolicy:
        severity:
          - critical
          - major

  # ------------------------------------------------------------------
  # EventBridge rule: content-based routing into the fan-out topic.
  # ------------------------------------------------------------------
  CriticalTelemetryRule:
    Type: AWS::Events::Rule
    Properties:
      Name: !Sub '${ProjectName}-critical-telemetry'
      EventBusName: !Ref TelemetryBus
      Description: Route degraded/failed gateway events to the fan-out topic.
      State: ENABLED
      EventPattern:
        source:
          - com.example.fleet
        detail-type:
          - GatewayHealthChanged
        detail:
          status:
            - DEGRADED
            - FAILED
          firmware:
            - prefix: '4.'
          errorCount:
            - numeric: ['>=', 10]
          region:
            - anything-but:
                - lab
      Targets:
        - Id: sns-fanout
          Arn: !Ref AlarmFanoutTopic
          InputTransformer:
            InputPathsMap:
              gw: $.detail.gatewayId
              st: $.detail.status
              ts: $.time
            InputTemplate: |
              {"severity":"critical","gatewayId":<gw>,"status":<st>,"observedAt":<ts>}
          RetryPolicy:
            MaximumRetryAttempts: 4
            MaximumEventAgeInSeconds: 3600
          DeadLetterConfig:
            Arn: !GetAtt EventBridgeDlq.Arn

  EventBridgeDlq:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub '${ProjectName}-eventbridge-dlq'
      MessageRetentionPeriod: 1209600
      SqsManagedSseEnabled: true

  # ------------------------------------------------------------------
  # Observability: the two alarms that actually page.
  # ------------------------------------------------------------------
  OpsTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${ProjectName}-ops'

  OpsEmailSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref OpsTopic
      Protocol: email
      Endpoint: !Ref AlertEmail

  DlqNotEmptyAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-persistence-dlq-not-empty'
      AlarmDescription: Any message in the DLQ is an unhandled defect.
      Namespace: AWS/SQS
      MetricName: ApproximateNumberOfMessagesVisible
      Dimensions:
        - Name: QueueName
          Value: !GetAtt PersistenceDlq.QueueName
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions:
        - !Ref OpsTopic

  MessageAgeAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-persistence-backlog-age'
      AlarmDescription: >
        Age of the oldest message is the only honest backpressure signal;
        queue depth alone hides a stalled consumer fleet.
      Namespace: AWS/SQS
      MetricName: ApproximateAgeOfOldestMessage
      Dimensions:
        - Name: QueueName
          Value: !GetAtt PersistenceQueue.QueueName
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 600
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions:
        - !Ref OpsTopic

Outputs:
  BusArn:
    Value: !GetAtt TelemetryBus.Arn
    Export:
      Name: !Sub '${ProjectName}-bus-arn'
  PersistenceQueueUrl:
    Value: !Ref PersistenceQueue
  RemediationQueueUrl:
    Value: !Ref RemediationQueue
  FanoutTopicArn:
    Value: !Ref AlarmFanoutTopic
```

> **Nota sobre `MessageRetentionPeriod`:** la propiedad se expresa en **segundos**, no en días. El parámetro de arriba se dejó intencionalmente como está para que veas la trampa — en un stack real calcularías `!Ref MessageRetentionDays` × 86400 con un `Fn::Transform`/macro, o simplemente pondrías `1209600` fijo. Una unidad mal leída acá fija silenciosamente la retención en 14 *segundos*, y los mensajes desaparecen antes de que ningún consumidor haga polling.

### 2.4 CLI: desplegar, publicar, observar, redrive

```console
$ aws cloudformation deploy \
    --template-file integration.yaml \
    --stack-name fleet-telemetry-integration \
    --parameter-overrides ProjectName=fleet-telemetry AlertEmail=sre@example.com \
    --capabilities CAPABILITY_IAM \
    --region us-east-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - fleet-telemetry-integration
```

Publicar un evento sintético en el bus personalizado:

```console
$ aws events put-events --entries '[
  {
    "EventBusName": "fleet-telemetry-bus",
    "Source": "com.example.fleet",
    "DetailType": "GatewayHealthChanged",
    "Detail": "{\"gatewayId\":\"gw-7f2a91\",\"status\":\"DEGRADED\",\"firmware\":\"4.2.1\",\"errorCount\":37,\"region\":\"eu-central\"}"
  }]'

{
    "FailedEntryCount": 0,
    "Entries": [
        {
            "EventId": "9c1f2b40-5a7e-4b62-9d31-6a0c8e4f1b77"
        }
    ]
}
```

`FailedEntryCount: 0` significa que EventBridge **aceptó** el evento. **No** significa que alguna regla lo haya matcheado. Esa distinción es el error número uno al depurar EventBridge.

Confirmar que el mensaje efectivamente llegó:

```console
$ QUEUE_URL=$(aws cloudformation describe-stacks \
    --stack-name fleet-telemetry-integration \
    --query "Stacks[0].Outputs[?OutputKey=='PersistenceQueueUrl'].OutputValue" \
    --output text)

$ aws sqs receive-message --queue-url "$QUEUE_URL" \
    --wait-time-seconds 20 --max-number-of-messages 10 \
    --attribute-names ApproximateReceiveCount SentTimestamp

{
    "Messages": [
        {
            "MessageId": "5b0e3a11-2d44-4a0d-8f19-90bb1c47a2e3",
            "ReceiptHandle": "AQEBwJnKyrHigUMZj6rYigCgxlaS3SLy0a...",
            "MD5OfBody": "3f2b1c9d4e7a8051b6c3d2e1f0a9b8c7",
            "Body": "{\"severity\":\"critical\",\"gatewayId\":\"gw-7f2a91\",\"status\":\"DEGRADED\",\"observedAt\":\"2026-09-04T11:42:07Z\"}",
            "Attributes": {
                "SentTimestamp": "1788521727413",
                "ApproximateReceiveCount": "1"
            }
        }
    ]
}
```

Inspeccionar la configuración efectiva de la cola — la forma más rápida de detectar un desajuste de visibility timeout:

```console
$ aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All \
    --query 'Attributes.{Visibility:VisibilityTimeout,Wait:ReceiveMessageWaitTimeSeconds,Retention:MessageRetentionPeriod,Redrive:RedrivePolicy,Visible:ApproximateNumberOfMessagesVisible,InFlight:ApproximateNumberOfMessagesNotVisible}'

{
    "Visibility": "180",
    "Wait": "20",
    "Retention": "1209600",
    "Redrive": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:111122223333:fleet-telemetry-persistence-dlq\",\"maxReceiveCount\":5}",
    "Visible": "0",
    "InFlight": "1"
}
```

Drenar una DLQ de vuelta hacia la cola de origen después de corregir el bug del consumidor (redrive administrado, sin script propio):

```console
$ aws sqs start-message-move-task \
    --source-arn arn:aws:sqs:us-east-1:111122223333:fleet-telemetry-persistence-dlq \
    --max-number-of-messages-per-second 50

{
    "TaskHandle": "eyJ0YXNrSWQiOiI4YzE0ZTQ3Mi1iM2E5LTQ4ZTAtOWY2NC0yZTVhN2M5MTBkMWEi..."
}

$ aws sqs list-message-move-tasks \
    --source-arn arn:aws:sqs:us-east-1:111122223333:fleet-telemetry-persistence-dlq

{
    "Results": [
        {
            "TaskHandle": "eyJ0YXNrSWQiOiI4YzE0ZTQ3Mi1iM2E5...",
            "Status": "COMPLETED",
            "SourceArn": "arn:aws:sqs:us-east-1:111122223333:fleet-telemetry-persistence-dlq",
            "DestinationArn": "arn:aws:sqs:us-east-1:111122223333:fleet-telemetry-persistence",
            "MaxNumberOfMessagesPerSecond": 50,
            "ApproximateNumberOfMessagesMoved": 412,
            "ApproximateNumberOfMessagesToMove": 412,
            "StartedTimestamp": 1788522010000
        }
    ]
}
```

Reproducir eventos archivados después de un defecto en el consumidor (EventBridge, no es posible con SNS):

```console
$ aws events start-replay \
    --replay-name post-fix-replay-2026-09-04 \
    --event-source-arn arn:aws:events:us-east-1:111122223333:archive/fleet-telemetry-archive \
    --event-start-time 2026-09-03T00:00:00Z \
    --event-end-time 2026-09-04T00:00:00Z \
    --destination '{"Arn":"arn:aws:events:us-east-1:111122223333:event-bus/fleet-telemetry-bus","FilterArns":["arn:aws:events:us-east-1:111122223333:rule/fleet-telemetry-bus/fleet-telemetry-critical-telemetry"]}'

{
    "ReplayArn": "arn:aws:events:us-east-1:111122223333:replay/post-fix-replay-2026-09-04",
    "State": "STARTING",
    "ReplayStartTime": "2026-09-03T00:00:00+00:00",
    "ReplayEndTime": "2026-09-04T00:00:00+00:00"
}
```

### 2.5 AWS Step Functions — dónde corresponde la orquestación

Las colas y los buses mueven mensajes; no recuerdan *en qué punto está un proceso de negocio*. Step Functions es una máquina de estados administrada con estado de ejecución durable, reintentos incorporados con backoff exponencial, bloques `Catch` para compensación (el patrón saga), y un historial de ejecución visual completo.

| Tipo de workflow | Duración | Historial de ejecución | Modelo de precio | Caso de uso |
|---|---|---|---|---|
| **Standard** | hasta 1 año | Durable, registrado por completo, ejecución exactamente una vez | Por transición de estado | Larga duración, auditable, pasos de aprobación humana, efectos secundarios no idempotentes |
| **Express** | hasta 5 min | Enviado a CloudWatch Logs, al menos una vez | Por ejecución + duración + memoria | Procesamiento de eventos de alto volumen, ingesta IoT, streaming |

```json
{
  "Comment": "Gateway remediation saga with compensation",
  "StartAt": "QuarantineGateway",
  "States": {
    "QuarantineGateway": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:iot:updateThingShadow",
      "Parameters": {
        "ThingName.$": "$.gatewayId",
        "Payload": { "state": { "desired": { "mode": "quarantine" } } }
      },
      "Retry": [
        {
          "ErrorEquals": ["States.TaskFailed", "ThrottlingException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 4,
          "BackoffRate": 2.0,
          "MaxDelaySeconds": 30,
          "JitterStrategy": "FULL"
        }
      ],
      "Catch": [
        { "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "NotifyOncall" }
      ],
      "Next": "AwaitHumanApproval"
    },
    "AwaitHumanApproval": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage.waitForTaskToken",
      "HeartbeatSeconds": 3600,
      "TimeoutSeconds": 86400,
      "Parameters": {
        "QueueUrl": "https://sqs.us-east-1.amazonaws.com/111122223333/approvals",
        "MessageBody": {
          "gatewayId.$": "$.gatewayId",
          "taskToken.$": "$$.Task.Token"
        }
      },
      "Catch": [
        { "ErrorEquals": ["States.Timeout"], "Next": "RollbackQuarantine" }
      ],
      "Next": "PushFirmware"
    },
    "PushFirmware": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:iot:createJob",
      "Parameters": {
        "JobId.$": "States.Format('fw-{}', $$.Execution.Name)",
        "Targets.$": "States.Array($.thingArn)",
        "Document": "{\"operation\":\"upgrade\",\"version\":\"4.3.0\"}"
      },
      "Catch": [
        { "ErrorEquals": ["States.ALL"], "Next": "RollbackQuarantine" }
      ],
      "End": true
    },
    "RollbackQuarantine": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:iot:updateThingShadow",
      "Parameters": {
        "ThingName.$": "$.gatewayId",
        "Payload": { "state": { "desired": { "mode": "normal" } } }
      },
      "Next": "NotifyOncall"
    },
    "NotifyOncall": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:us-east-1:111122223333:fleet-telemetry-ops",
        "Message.$": "States.JsonToString($)"
      },
      "End": true
    }
  }
}
```

---

## 3. Aplicaciones de negocio

### 3.1 Amazon SES — el plano de control de la entregabilidad

SES no es "un servidor SMTP en la nube". Es una **plataforma de envío con reputación administrada**, y cada decisión arquitectónica dentro de ella existe para proteger la reputación del pool de IPs compartido.

| Concepto | Mecánica | Por qué le importa a un SRE |
|---|---|---|
| Sandbox | Cuentas nuevas: máx. **200 mensajes / 24 h**, **1 msg/s**, los destinatarios deben ser identidades verificadas | Una prueba de carga desde una cuenta en sandbox falla con `MessageRejected: Email address is not verified` |
| Identidad verificada | Dominio (TXT/CNAME) o dirección de correo individual | La verificación de dominio te permite enviar desde cualquier local-part; la verificación por correo no escala |
| DKIM | Easy DKIM publica 3 CNAMEs; BYODKIM permite tu propia clave | El correo sin firmar es la ruta más rápida a la carpeta de spam |
| SPF / MAIL FROM personalizado | Subdominio MAIL FROM personalizado + MX + SPF TXT | Requerido para la **alineación SPF**, que DMARC necesita |
| DMARC | Tu propio TXT `_dmarc` con `p=quarantine`/`p=reject` | Sin alineación en SPF *o* DKIM, DMARC falla incluso con un DKIM válido |
| Configuration set | Paquete nombrado de destinos de eventos, pool de IPs, política TLS, overrides de supresión | Segrega la reputación transaccional de la de marketing |
| Destinos de eventos | CloudWatch, Firehose, SNS, EventBridge | La única forma de *medir* rebotes/quejas por campaña |
| Lista de supresión | A nivel de cuenta y global | Enviar a una dirección suprimida devuelve éxito pero nunca entrega |
| IPs dedicadas | Standard (el calentamiento lo hacés vos) o Managed (lo hace SES) | Aísla tu reputación de la de otros tenants; requiere volumen sostenido |
| Umbrales de reputación | Tasa de rebote: revisión al **5 %**, posible pausa al **10 %**. Tasa de quejas: revisión al **0,1 %**, posible pausa al **0,5 %** | Estos son los números que hacen que se pause una cuenta |

```yaml
  # SES identity with Easy DKIM, custom MAIL FROM, and a configuration set
  SendingIdentity:
    Type: AWS::SES::EmailIdentity
    Properties:
      EmailIdentity: mail.example.com
      DkimAttributes:
        SigningEnabled: true
      DkimSigningAttributes:
        NextSigningKeyLength: RSA_2048_BIT
      MailFromAttributes:
        MailFromDomain: bounce.mail.example.com
        BehaviorOnMxFailure: REJECT_MESSAGE
      FeedbackAttributes:
        EmailForwardingEnabled: false          # use event destinations instead
      ConfigurationSetAttributes:
        ConfigurationSetName: !Ref TransactionalConfigSet

  TransactionalConfigSet:
    Type: AWS::SES::ConfigurationSet
    Properties:
      Name: transactional
      DeliveryOptions:
        TlsPolicy: REQUIRE                     # refuse to fall back to cleartext
      ReputationOptions:
        ReputationMetricsEnabled: true
      SendingOptions:
        SendingEnabled: true
      SuppressionOptions:
        SuppressedReasons:
          - BOUNCE
          - COMPLAINT

  TransactionalEventDestination:
    Type: AWS::SES::ConfigurationSetEventDestination
    Properties:
      ConfigurationSetName: !Ref TransactionalConfigSet
      EventDestination:
        Name: bounce-complaint-stream
        Enabled: true
        MatchingEventTypes:
          - SEND
          - REJECT
          - BOUNCE
          - COMPLAINT
          - DELIVERY
          - DELIVERY_DELAY
          - RENDERING_FAILURE
        SnsDestination:
          TopicARN: !Ref OpsTopic
```

```console
$ aws sesv2 get-account --query '{Sandbox:ProductionAccessEnabled,SendQuota:SendQuota,Enforcement:EnforcementStatus}'
{
    "Sandbox": true,
    "SendQuota": {
        "Max24HourSend": 200.0,
        "MaxSendRate": 1.0,
        "SentLast24Hours": 14.0
    },
    "Enforcement": "HEALTHY"
}

$ aws sesv2 get-email-identity --email-identity mail.example.com \
    --query '{Verified:VerifiedForSendingStatus,Dkim:DkimAttributes.Status,MailFrom:MailFromAttributes.MailFromDomainStatus}'
{
    "Verified": true,
    "Dkim": "SUCCESS",
    "MailFrom": "SUCCESS"
}

$ aws sesv2 send-email \
    --from-email-address "alerts@mail.example.com" \
    --destination 'ToAddresses=sre@example.com' \
    --configuration-set-name transactional \
    --content '{"Simple":{"Subject":{"Data":"Gateway gw-7f2a91 DEGRADED"},"Body":{"Text":{"Data":"errorCount=37 firmware=4.2.1"}}}}'

{
    "MessageId": "0100019235ab7c4d-6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8-000000"
}
```

Firma de falla para memorizar:

```console
$ aws sesv2 send-email --from-email-address "alerts@notverified.example" ...

An error occurred (MessageRejected) when calling the SendEmail operation:
Email address is not verified. The following identities failed the check in
region US-EAST-1: alerts@notverified.example
```

Ese error significa **una de tres cosas**: la identidad no está verificada, la cuenta sigue en el sandbox y el *destinatario* no está verificado, o estás enviando en la Región equivocada — las identidades de SES son **regionales**, y verificar un dominio en `us-east-1` no hace nada en `eu-west-1`.

### 3.2 Amazon Connect

Amazon Connect es un **contact center en la nube**: omnicanal (voz, chat, tareas, correo), pago por uso por minuto/mensaje sin licencias por puesto, flujos de contacto construidos como una máquina de estados visual, e integraciones nativas con Lex (IVR conversacional), Lambda (consultas al CRM) y Contact Lens (transcripción en tiempo real, análisis de sentimiento y redacción para cumplimiento).

El hecho arquitectónicamente relevante para el examen: **Connect reemplaza el hardware de telefonía on-premises y las licencias por puesto**, escala elásticamente con el volumen de llamadas, e integra a través de las mismas primitivas de eventos/integración que ya tenés — Connect emite eventos de contacto a EventBridge y Kinesis, de modo que las rutas de escalamiento fluyen hacia la topología SNS/SQS de la §2.

---

## 4. Interacción con el cliente

Esta categoría trata sobre **cómo conseguís ayuda humana**, y la tabla de planes de Support es una de las tablas más confiablemente examinadas de toda la certificación.

| | **Basic** | **Developer** | **Business** | **Enterprise On-Ramp** | **Enterprise** |
|---|---|---|---|---|---|
| Costo | Gratis | Desde USD 29/mes o 3 % del gasto | Desde USD 100/mes, % escalonado del gasto | Desde USD 5.500/mes | Desde USD 15.000/mes |
| Canales | Documentación, foros, estado del servicio, soporte de cuenta/facturación | Correo (horario laboral) | Correo, chat y teléfono 24×7 | Correo, chat y teléfono 24×7 | Correo, chat y teléfono 24×7 |
| Quién responde | — | Cloud Support Associates | Cloud Support Engineers | Cloud Support Engineers | Cloud Support Engineers |
| Orientación general | — | < 24 horas hábiles | < 24 h | < 24 h | < 24 h |
| Sistema afectado | — | < 12 horas hábiles | < 12 h | < 12 h | < 12 h |
| **Sistema de producción afectado** | — | — | **< 4 h** | < 4 h | < 4 h |
| **Sistema de producción caído** | — | — | **< 1 h** | < 1 h | < 1 h |
| **Sistema crítico para el negocio caído** | — | — | — | **< 30 min** | **< 15 min** |
| Trusted Advisor | Solo checks básicos | Solo checks básicos | **Conjunto completo de checks** | Conjunto completo de checks | Conjunto completo de checks |
| AWS Support API | No | No | **Sí** | Sí | Sí |
| Soporte de software de terceros | No | No | Sí | Sí | Sí |
| Technical Account Manager | No | No | No | **Pool de TAMs** | **TAM designado** |
| Concierge / expertos en facturación | No | No | No | Sí | Sí |
| Orientación arquitectónica | — | General | Contextual | Revisión consultiva | Consultiva + revisiones Well-Architected |
| Detección y respuesta ante incidentes, cuenta regresiva/soporte para eventos | No | No | No | Limitado | Sí |

**Reglas de decisión que el examen evalúa:**
- "Necesitamos una *respuesta en menos de 15 minutos* para caídas críticas para el negocio" → **Enterprise**.
- "Necesitamos un Technical Account Manager *designado*" → **Enterprise** (On-Ramp da un *pool*).
- "Necesitamos el conjunto *completo* de checks de Trusted Advisor" → **Business** o superior.
- "Necesitamos abrir casos de soporte *programáticamente*" → **Business** o superior (Support API).
- "Necesitamos soporte telefónico 24×7 para producción" → **Business** o superior.

**Otros servicios de esta categoría:**

- **AWS Managed Services (AMS)** — AWS opera tu infraestructura por vos bajo un modelo operativo alineado con ITIL: parcheo, monitoreo, gestión de incidentes, backup, gestión de cambios mediante RFCs. Comprá esto cuando estás migrando un patrimonio empresarial grande y te falta dotación de operaciones, no cuando ya tenés un equipo de plataforma maduro.
- **AWS IQ** — un marketplace bajo demanda para contratar expertos externos certificados por AWS para proyectos pequeños y acotados, facturados a través de tu cuenta de AWS.
- **AWS Activate for Startups** — créditos, créditos para planes de soporte técnico y capacitación para startups elegibles.

```console
$ aws support describe-severity-levels --region us-east-1 --language en \
    --query 'severityLevels[].{code:code,name:name}' --output table
--------------------------------
|    DescribeSeverityLevels    |
+------------------+-----------+
|       code       |   name    |
+------------------+-----------+
|  low             |  General guidance          |
|  normal          |  System impaired           |
|  high            |  Production system impaired|
|  urgent          |  Production system down    |
|  critical        |  Business-critical system down |
+------------------+-----------+
```

En un plan Basic o Developer la misma llamada falla — una forma rápida y definitiva de confirmar el nivel de tu plan:

```console
$ aws support describe-severity-levels --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: AWS Premium Support Subscription is required
to use this service.
```

> **Nota sobre endpoints:** las APIs de AWS Support y Trusted Advisor son servicios globales con endpoints en `us-east-1`. Llamarlas con `--region eu-west-1` falla sin importar el plan.

---

## 5. Herramientas para desarrolladores

### 5.1 El pipeline como sistema

| Servicio | Rol en el pipeline | Restricción clave de producción |
|---|---|---|
| **CodePipeline** | Orquestador: etapas, acciones, transiciones, aprobaciones | Los artefactos fluyen por un bucket S3 de artefactos; cifralo y bloqueá su bucket policy |
| **CodeBuild** | Cómputo de build efímero; `buildspec.yml` | Sin estado entre builds — usá caching local o cache en S3 deliberadamente |
| **CodeDeploy** | Motor de despliegue para EC2/on-prem, Lambda, ECS | Ofrece estrategias in-place, blue/green, canary y lineal con rollback automático |
| **CodeArtifact** | Repositorio de paquetes administrado (npm, PyPI, Maven, NuGet, genérico, Swift, Ruby) | Hacé upstream a los registros públicos para que una caída pública no detenga tus builds |
| **CodeGuru** | Reviewer (recomendaciones de código), Profiler (rutas calientes en ejecución), Security | Profiler necesita un agente en la app en ejecución; Reviewer necesita asociación de repositorio |
| **X-Ray** | Trazado distribuido: segmentos, subsegmentos, mapa de servicios | El muestreo es *lossy por diseño* — no lo uses como log de facturación/auditoría |
| **AppConfig** | Configuración en tiempo de ejecución y feature flags con despliegue validado y monitoreado | Desacopla el cambio de configuración del despliegue; soporta rollback automático ante alarma |
| **CloudShell** | Shell en el navegador con tus credenciales de consola precargadas, 1 GB de home persistente por Región | Gratis; el almacenamiento persistente se borra tras 120 días de inactividad |
| **AWS CLI** | El cliente universal del plano de control | Solo v2 para trabajo nuevo; `--query` (JMESPath) es la diferencia entre un script y un pipeline |

### 5.2 `buildspec.yml` completo (CodeBuild)

```yaml
version: 0.2

env:
  variables:
    DOCKER_BUILDKIT: "1"
    PYTHON_VERSION: "3.12"
  parameter-store:
    SONAR_TOKEN: /fleet-telemetry/build/sonar-token
  secrets-manager:
    CODEARTIFACT_DOMAIN_OWNER: fleet-telemetry/build:domainOwner
  exported-variables:
    - IMAGE_TAG
    - IMAGE_DIGEST

phases:

  install:
    runtime-versions:
      python: 3.12
      nodejs: 20
    commands:
      - echo "Build $CODEBUILD_BUILD_ID started at $(date -u +%FT%TZ)"
      - pip install --quiet --upgrade pip

  pre_build:
    commands:
      # Authenticate the package manager against CodeArtifact.
      - |
        aws codeartifact login --tool pip \
          --domain fleet --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" \
          --repository internal-pypi --region "$AWS_REGION"
      - pip install --quiet -r requirements.txt -r requirements-dev.txt
      # Authenticate Docker against ECR.
      - |
        aws ecr get-login-password --region "$AWS_REGION" \
          | docker login --username AWS --password-stdin \
            "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
      - IMAGE_TAG="${CODEBUILD_RESOLVED_SOURCE_VERSION:0:12}"
      - REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/fleet-telemetry"
      - echo "Resolved image tag ${IMAGE_TAG}"

  build:
    commands:
      - ruff check .
      - mypy --strict src/
      - pytest -q --junitxml=reports/junit.xml --cov=src --cov-report=xml:reports/coverage.xml
      - docker build --pull -t "${REPO_URI}:${IMAGE_TAG}" -t "${REPO_URI}:latest" .

  post_build:
    commands:
      # Never publish an image built from a failed test phase.
      - |
        if [ "${CODEBUILD_BUILD_SUCCEEDING}" != "1" ]; then
          echo "Build failed in an earlier phase; skipping push." >&2
          exit 1
        fi
      - docker push "${REPO_URI}:${IMAGE_TAG}"
      - docker push "${REPO_URI}:latest"
      - |
        IMAGE_DIGEST=$(aws ecr describe-images --repository-name fleet-telemetry \
          --image-ids imageTag="${IMAGE_TAG}" \
          --query 'imageDetails[0].imageDigest' --output text)
      - |
        printf '[{"name":"telemetry","imageUri":"%s@%s"}]\n' "$REPO_URI" "$IMAGE_DIGEST" \
          > imagedefinitions.json
      - sed -i "s|<IMAGE_URI>|${REPO_URI}@${IMAGE_DIGEST}|g" taskdef.json

reports:
  unit-tests:
    files:
      - 'reports/junit.xml'
    file-format: JUNITXML
  coverage:
    files:
      - 'reports/coverage.xml'
    file-format: COBERTUraXML

artifacts:
  files:
    - imagedefinitions.json
    - taskdef.json
    - appspec.yaml
  name: build-$(date +%Y%m%d)-$CODEBUILD_BUILD_NUMBER

cache:
  paths:
    - '/root/.cache/pip/**/*'
    - '/root/.npm/**/*'
```

> Los valores de `file-format` son insensibles a mayúsculas del lado del servicio pero convencionalmente van en mayúsculas (`COBERTURAXML`); el valor de arriba está escrito tal como lo acepta el servicio. Si CodeBuild reporta `Invalid report file-format`, esa cadena es lo primero que hay que revisar.

### 5.3 `appspec.yaml` completo — dos destinos de despliegue

**EC2 / on-premises (in-place o blue/green), con los cinco hooks de ciclo de vida:**

```yaml
version: 0.0
os: linux

files:
  - source: /app
    destination: /opt/fleet-telemetry
  - source: /systemd/fleet-telemetry.service
    destination: /etc/systemd/system

permissions:
  - object: /opt/fleet-telemetry
    owner: telemetry
    group: telemetry
    mode: 750
    type:
      - directory
      - file

hooks:
  ApplicationStop:
    - location: scripts/stop_service.sh
      timeout: 60
      runas: root
  BeforeInstall:
    - location: scripts/backup_current_release.sh
      timeout: 120
      runas: root
  AfterInstall:
    - location: scripts/render_config.sh
      timeout: 120
      runas: root
  ApplicationStart:
    - location: scripts/start_service.sh
      timeout: 120
      runas: root
  ValidateService:
    - location: scripts/health_check.sh
      timeout: 300
      runas: telemetry
```

**Amazon ECS blue/green con un listener de prueba:**

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: "<TASK_DEFINITION>"
        LoadBalancerInfo:
          ContainerName: "telemetry"
          ContainerPort: 8080
        PlatformVersion: "1.4.0"
        NetworkConfiguration:
          AwsvpcConfiguration:
            Subnets:
              - "subnet-0a1b2c3d4e5f60718"
              - "subnet-0f1e2d3c4b5a69807"
            SecurityGroups:
              - "sg-0123456789abcdef0"
            AssignPublicIp: "DISABLED"
Hooks:
  - BeforeInstall: "arn:aws:lambda:us-east-1:111122223333:function:predeploy-schema-guard"
  - AfterInstall: "arn:aws:lambda:us-east-1:111122223333:function:seed-cache"
  - AfterAllowTestTraffic: "arn:aws:lambda:us-east-1:111122223333:function:smoke-tests"
  - BeforeAllowTraffic: "arn:aws:lambda:us-east-1:111122223333:function:final-gate"
  - AfterAllowTraffic: "arn:aws:lambda:us-east-1:111122223333:function:post-cutover-verify"
```

**Compensaciones de las estrategias de despliegue:**

| Estrategia | Costo de capacidad extra | Tiempo de rollback | Radio de impacto de un build defectuoso | Impacto en las sesiones |
|---|---|---|---|---|
| In-place, todo a la vez | Ninguno | Redespliegue completo (minutos) | 100 % | Caída total durante el despliegue |
| In-place, de a uno | Ninguno | Redespliegue completo | Gradual | Capacidad reducida |
| In-place, de a mitades | Ninguno | Redespliegue completo | 50 % | 50 % de capacidad |
| Blue/green (canary 10 % / 5 min) | 2× durante el despliegue | **Segundos** — volver a mover el listener | 10 % durante la ventana del canary | Las conexiones existentes se drenan |
| Blue/green (lineal 10 % cada 3 min) | 2× durante el despliegue | Segundos | Sube de 10 → 100 % | Gradual |
| Blue/green (cambio todo a la vez) | 2× durante el despliegue | Segundos | 100 % en el cutover | Cutover instantáneo |

La razón por la que blue/green cuesta el doble de capacidad y aun así es lo predeterminado para cualquier cosa de cara al cliente: **el rollback es un cambio de regla del listener, no un redespliegue**. Eso convierte una recuperación de 15 minutos en una de 15 segundos.

### 5.4 AWS AppConfig — la configuración como despliegue monitoreado

La falla que AppConfig previene: un feature flag cambiado editando una variable de entorno, que requiere un despliegue completo, sin validación y sin rollback automático. AppConfig convierte la configuración en un **despliegue de primera clase** con validadores (JSON Schema o una Lambda) *antes* del rollout y monitores de alarmas CloudWatch que disparan **rollback automático** durante el rollout.

```yaml
  ConfigApplication:
    Type: AWS::AppConfig::Application
    Properties:
      Name: fleet-telemetry

  ProdEnvironment:
    Type: AWS::AppConfig::Environment
    Properties:
      ApplicationId: !Ref ConfigApplication
      Name: production
      Monitors:
        - AlarmArn: !GetAtt MessageAgeAlarm.Arn
          AlarmRoleArn: !GetAtt AppConfigMonitorRole.Arn

  FeatureFlagProfile:
    Type: AWS::AppConfig::ConfigurationProfile
    Properties:
      ApplicationId: !Ref ConfigApplication
      Name: ingestion-flags
      LocationUri: hosted
      Type: AWS.AppConfig.FeatureFlags
      Validators:
        - Type: JSON_SCHEMA
          Content: |
            {
              "$schema": "http://json-schema.org/draft-07/schema#",
              "type": "object",
              "required": ["flags", "values", "version"],
              "properties": {
                "version": { "type": "string" },
                "flags": { "type": "object" },
                "values": { "type": "object" }
              }
            }

  FlagVersion:
    Type: AWS::AppConfig::HostedConfigurationVersion
    Properties:
      ApplicationId: !Ref ConfigApplication
      ConfigurationProfileId: !Ref FeatureFlagProfile
      ContentType: application/json
      Content: |
        {
          "version": "1",
          "flags": {
            "batchIngest":  { "name": "batchIngest",
                              "attributes": { "batchSize": { "constraints": { "type": "number", "required": true } } } },
            "shadowCompare": { "name": "shadowCompare" }
          },
          "values": {
            "batchIngest":  { "enabled": true,  "batchSize": 250 },
            "shadowCompare": { "enabled": false }
          }
        }

  CanaryStrategy:
    Type: AWS::AppConfig::DeploymentStrategy
    Properties:
      Name: canary-10pct-20min
      DeploymentDurationInMinutes: 20
      GrowthType: EXPONENTIAL
      GrowthFactor: 10
      FinalBakeTimeInMinutes: 10
      ReplicateTo: NONE
```

```console
$ aws appconfig start-deployment \
    --application-id 4tv7ahz --environment-id 2b7xk1p \
    --deployment-strategy-id qpz9v3m \
    --configuration-profile-id 8fk2wn1 --configuration-version 3

{
    "DeploymentNumber": 12,
    "State": "DEPLOYING",
    "PercentageComplete": 0.0,
    "GrowthType": "EXPONENTIAL",
    "GrowthFactor": 10.0,
    "FinalBakeTimeInMinutes": 10
}

$ aws appconfig get-deployment --application-id 4tv7ahz \
    --environment-id 2b7xk1p --deployment-number 12 \
    --query '{State:State,Pct:PercentageComplete,Events:EventLog[0:3]}'

{
    "State": "ROLLED_BACK",
    "Pct": 30.0,
    "Events": [
        {
            "EventType": "ROLLBACK_COMPLETED",
            "TriggeredBy": "CLOUDWATCH_ALARM",
            "Description": "Deployment rolled back because alarm fleet-telemetry-persistence-backlog-age entered ALARM state.",
            "OccurredAt": "2026-09-04T12:11:44+00:00"
        },
        { "EventType": "ROLLBACK_STARTED", "TriggeredBy": "CLOUDWATCH_ALARM", "OccurredAt": "2026-09-04T12:10:02+00:00" },
        { "EventType": "PERCENTAGE_UPDATED", "TriggeredBy": "APPCONFIG", "OccurredAt": "2026-09-04T12:06:00+00:00" }
    ]
}
```

Ese `ROLLBACK_COMPLETED / TriggeredBy: CLOUDWATCH_ALARM` es toda la propuesta de valor: un flag defectuoso fue retirado automáticamente con un 30 % de exposición sin un humano en el bucle.

### 5.5 AWS X-Ray — muestreo, segmentos y el mapa de servicios

X-Ray construye un **mapa de servicios** a partir de segmentos (uno por servicio) y subsegmentos (uno por llamada aguas abajo), correlacionados por un trace ID propagado en el encabezado `X-Amzn-Trace-Id`. El SDK emite UDP al daemon de X-Ray en el **puerto 2000**; el daemon agrupa en lotes y llama a `PutTraceSegments`.

```json
{
  "version": 2,
  "rules": [
    {
      "description": "Always trace payment and remediation paths",
      "service_name": "*",
      "http_method": "*",
      "url_path": "/api/remediation/*",
      "fixed_target": 5,
      "rate": 1.0
    },
    {
      "description": "Never trace health checks - they dominate volume and teach nothing",
      "service_name": "*",
      "http_method": "GET",
      "url_path": "/healthz",
      "fixed_target": 0,
      "rate": 0.0
    }
  ],
  "default": {
    "fixed_target": 1,
    "rate": 0.05
  }
}
```

`fixed_target` es la cantidad de solicitudes por segundo muestreadas *antes* de que se aplique la tasa porcentual. La regla por defecto de arriba traza la primera 1 req/s más el 5 % del resto — que es por lo que **X-Ray es una herramienta de diagnóstico, no un log de auditoría**.

```console
$ aws xray get-service-graph --start-time 2026-09-04T11:00:00Z --end-time 2026-09-04T12:00:00Z \
    --query 'Services[].{Name:Name,Type:Type,Ok:SummaryStatistics.OkCount,Fault:SummaryStatistics.FaultStatistics.TotalCount,P95:SummaryStatistics.TotalResponseTime}' \
    --output table

------------------------------------------------------------------------
|                            GetServiceGraph                           |
+----------------------+---------------+--------+---------+------------+
|         Name         |     Type      |   Ok   |  Fault  |    P95     |
+----------------------+---------------+--------+---------+------------+
|  telemetry-api       |  AWS::ECS     |  48213 |  0      |  0.041     |
|  fleet-telemetry     |  AWS::DynamoDB::Table | 47990 | 223 | 0.310  |
|  fleet-telemetry-persistence | AWS::SQS::Queue | 48210 | 3 | 0.012 |
+----------------------+---------------+--------+---------+------------+

$ aws xray get-trace-summaries --start-time 2026-09-04T11:40:00Z --end-time 2026-09-04T11:45:00Z \
    --filter-expression 'service("fleet-telemetry") { fault = true }' \
    --query 'TraceSummaries[0:2].{Id:Id,Dur:Duration,Http:Http.HttpStatus,Err:ErrorRootCauses[0].Services[0].EntityPath[0].Name}'

[
    {
        "Id": "1-68b95c3f-0a1b2c3d4e5f60718293a4b5",
        "Dur": 3.114,
        "Http": 502,
        "Err": "ProvisionedThroughputExceededException"
    },
    {
        "Id": "1-68b95c41-1b2c3d4e5f60718293a4b5c6",
        "Dur": 2.981,
        "Http": 502,
        "Err": "ProvisionedThroughputExceededException"
    }
]
```

### 5.6 CodeArtifact y CodeGuru en un minuto cada uno

```console
$ aws codeartifact login --tool pip --domain fleet \
    --domain-owner 111122223333 --repository internal-pypi --region us-east-1

Successfully configured pip to use AWS CodeArtifact repository
https://fleet-111122223333.d.codeartifact.us-east-1.amazonaws.com/pypi/internal-pypi/
Login expires in 12 hours at 2026-09-05 00:14:22

$ aws codeartifact list-packages --domain fleet --repository internal-pypi \
    --query 'packages[].{fmt:format,name:package}' --output table
--------------------------------
|         ListPackages         |
+--------+---------------------+
|  fmt   |        name         |
+--------+---------------------+
|  pypi  |  fleet-telemetry-sdk|
|  pypi  |  fleet-schemas      |
+--------+---------------------+
```

El punto arquitectónico de CodeArtifact es el **repositorio upstream**: tu repo interno hace upstream a una conexión pública de PyPI/npm, de modo que los paquetes quedan cacheados en tu cuenta. Una caída de un registro público o un paquete retirado ya no rompe tus builds, y toda dependencia es auditable.

**Amazon CodeGuru** tiene dos mitades: **Reviewer** (análisis estático de pull requests — bugs de concurrencia, fugas de recursos, mal uso de APIs de AWS, secretos hardcodeados) y **Profiler** (un agente de baja sobrecarga en la aplicación en ejecución que produce flame graphs y una estimación del costo del tiempo de CPU). Reviewer responde "¿este código es defectuoso?"; Profiler responde "¿dónde está gastando plata realmente producción?".

---

## 6. Computación para el usuario final

| | **Amazon WorkSpaces** | **Amazon AppStream 2.0** | **Amazon WorkSpaces Web / Secure Browser** |
|---|---|---|---|
| Entrega | Un escritorio virtual persistente completo (DaaS) | Aplicaciones individuales por streaming (o un escritorio) | Una sesión de navegador administrada y aislada basada en Chrome |
| Persistencia | Volumen de usuario persistente entre sesiones | No persistente por defecto; carpetas home opcionales en S3 | Totalmente efímera por diseño |
| Identidad | AWS Managed Microsoft AD, AD Connector, Simple AD | IdP SAML 2.0, user pool | IdP SAML 2.0 |
| Cliente | Clientes nativos (Windows/macOS/Linux/iOS/Android/Chromebook), acceso web | Navegador HTML5, cliente nativo | Cualquier navegador moderno — nada que instalar |
| Protocolo / puertos | PCoIP: TCP/UDP **4172**; DCV (WSP): TCP/UDP **4195**; más TCP 443 para el registro | HTTPS 443 (+ UDP opcional) | HTTPS 443 |
| Facturación | Mensual (AlwaysOn) o por hora + un pequeño cargo mensual (AutoStop) | Por hora de instancia de streaming + cargo por usuario | Por hora-usuario activo |
| Mejor encaje | Trabajadores del conocimiento a tiempo completo, desarrolladores, escritorios regulados | Contratistas, laboratorios, usuarios estacionales, apps GPU/CAD, una única app legacy | Acceso de contratistas/BYOD a apps web internas y SaaS |
| Control de egreso de datos | El escritorio está en tu VPC; políticas de portapapeles/USB/impresión | Igual, políticas por fleet | El más fuerte — ningún dato llega al dispositivo del endpoint |

**La trampa de costo en WorkSpaces:** la facturación AutoStop es por hora *más* un cargo fijo mensual de infraestructura. Por debajo de unas 80 horas de uso mensual, AutoStop es más barato; por encima de ese punto de cruce, lo es AlwaysOn. Una flota dejada en AlwaysOn para usuarios que se conectan dos veces por semana es una de las facturas de EUC evitables más comunes.

```yaml
  RegulatedDesktop:
    Type: AWS::WorkSpaces::Workspace
    Properties:
      BundleId: wsb-bh8rsxt14           # Region-specific; list before hardcoding
      DirectoryId: d-9067f2a1b3
      UserName: jdoe
      RootVolumeEncryptionEnabled: true
      UserVolumeEncryptionEnabled: true
      VolumeEncryptionKey: !Ref WorkspacesKmsKey
      WorkspaceProperties:
        ComputeTypeName: PERFORMANCE
        RunningMode: AUTO_STOP
        RunningModeAutoStopTimeoutInMinutes: 60
        RootVolumeSizeGib: 80
        UserVolumeSizeGib: 100

  StreamingFleet:
    Type: AWS::AppStream::Fleet
    Properties:
      Name: cad-contractors
      FleetType: ON_DEMAND              # cheaper idle; ~1-2 min start latency
      InstanceType: stream.graphics.g4dn.xlarge
      ComputeCapacity:
        DesiredInstances: 4
      MaxUserDurationInSeconds: 57600
      DisconnectTimeoutInSeconds: 900
      IdleDisconnectTimeoutInSeconds: 900
      EnableDefaultInternetAccess: false
      VpcConfig:
        SubnetIds:
          - subnet-0a1b2c3d4e5f60718
          - subnet-0f1e2d3c4b5a69807
        SecurityGroupIds:
          - sg-0123456789abcdef0
      StreamView: APP
```

```console
$ aws workspaces describe-workspaces --query \
    'Workspaces[].{User:UserName,State:State,Mode:WorkspaceProperties.RunningMode,IP:IpAddress}' \
    --output table
---------------------------------------------------------
|                  DescribeWorkspaces                   |
+---------+--------------+-------------+----------------+
|  User   |    State     |    Mode     |       IP       |
+---------+--------------+-------------+----------------+
|  jdoe   |  AVAILABLE   |  AUTO_STOP  |  10.42.3.117   |
|  asmith |  UNHEALTHY   |  ALWAYS_ON  |  10.42.3.204   |
+---------+--------------+-------------+----------------+

$ aws workspaces describe-workspaces-connection-status \
    --query 'WorkspacesConnectionStatus[].{Id:WorkspaceId,State:ConnectionState,Since:ConnectionStateCheckTimestamp}'
[
    {
        "Id": "ws-p9k2m4x7q",
        "State": "CONNECTED",
        "Since": "2026-09-04T12:31:05+00:00"
    },
    {
        "Id": "ws-t3n8b1v6z",
        "State": "DISCONNECTED",
        "Since": "2026-09-04T09:02:44+00:00"
    }
]
```

`UNHEALTHY` casi siempre significa que el agente del WorkSpace no puede alcanzar la interfaz de administración: una ruta faltante hacia internet/endpoints de VPC, un security group bloqueando 4172/4195, o un directorio que perdió sus controladores de dominio. Reconstruir el WorkSpace antes de revisar el directorio es la hora perdida habitual.

---

## 7. Web y móvil de front-end

### 7.1 AWS Amplify

Amplify Hosting es un host administrado con CI/CD y respaldado por CDN para aplicaciones web de página única y renderizadas en el servidor: conectás una rama de Git y obtenés despliegues atómicos, entornos por rama, previsualizaciones de pull requests, protección por contraseña, dominios personalizados con TLS administrado y rollback instantáneo a un despliegue anterior.

```yaml
version: 1
applications:
  - appRoot: web
    frontend:
      phases:
        preBuild:
          commands:
            - npm ci --prefer-offline --no-audit
        build:
          commands:
            - echo "VITE_APPSYNC_URL=$VITE_APPSYNC_URL" >> .env.production
            - echo "VITE_COMMIT=$AWS_COMMIT_ID" >> .env.production
            - npm run build
        postBuild:
          commands:
            - npm run test:ci
      artifacts:
        baseDirectory: dist
        files:
          - '**/*'
      cache:
        paths:
          - node_modules/**/*
          - .vite/**/*
    customHeaders:
      - pattern: '**'
        headers:
          - key: Strict-Transport-Security
            value: 'max-age=63072000; includeSubDomains; preload'
          - key: X-Content-Type-Options
            value: 'nosniff'
          - key: Content-Security-Policy
            value: "default-src 'self'; connect-src 'self' https://*.appsync-api.us-east-1.amazonaws.com wss://*.appsync-realtime-api.us-east-1.amazonaws.com; img-src 'self' data:"
          - key: Referrer-Policy
            value: 'strict-origin-when-cross-origin'
      - pattern: '/assets/**'
        headers:
          - key: Cache-Control
            value: 'public, max-age=31536000, immutable'
```

### 7.2 AWS AppSync

AppSync es **GraphQL** administrado (y Pub/Sub sobre WebSockets): un endpoint, un esquema tipado, resolvers que enganchan campos a fuentes de datos (DynamoDB, Aurora vía RDS Data API, Lambda, OpenSearch, HTTP, EventBridge), y **suscripciones en tiempo real** impulsadas por mutaciones.

La razón arquitectónica para elegirlo por sobre REST: un cliente móvil en una red pobre necesita exactamente los campos que va a renderizar, en un solo viaje de ida y vuelta. REST o bien trae de más, o bien fuerza una proliferación de endpoints a medida.

```graphql
schema {
  query: Query
  mutation: Mutation
  subscription: Subscription
}

type Gateway @aws_cognito_user_pools @aws_iam {
  gatewayId: ID!
  status: GatewayStatus!
  firmware: String!
  errorCount: Int!
  region: String!
  lastSeen: AWSDateTime!
  telemetry(limit: Int = 50, nextToken: String): TelemetryConnection
}

enum GatewayStatus { HEALTHY DEGRADED FAILED QUARANTINED }

type TelemetryPoint {
  ts: AWSDateTime!
  metric: String!
  value: Float!
}

type TelemetryConnection {
  items: [TelemetryPoint!]!
  nextToken: String
}

type Query {
  getGateway(gatewayId: ID!): Gateway
  listGatewaysByStatus(status: GatewayStatus!, limit: Int = 25, nextToken: String): GatewayConnection
}

type GatewayConnection {
  items: [Gateway!]!
  nextToken: String
}

type Mutation {
  # Only the ingestion role (IAM) may write; the UI reads via Cognito.
  reportHealth(gatewayId: ID!, status: GatewayStatus!, errorCount: Int!): Gateway
    @aws_iam
  quarantineGateway(gatewayId: ID!): Gateway
    @aws_cognito_user_pools(cognito_groups: ["fleet-operators"])
}

type Subscription {
  onHealthChanged(region: String): Gateway
    @aws_subscribe(mutations: ["reportHealth"])
    @aws_cognito_user_pools
}
```

```javascript
// APPSYNC_JS resolver for Query.getGateway on a DynamoDB data source.
import { util } from '@aws-appsync/utils';

export function request(ctx) {
  return {
    operation: 'GetItem',
    key: util.dynamodb.toMapValues({ pk: `GW#${ctx.args.gatewayId}`, sk: 'META' }),
    consistentRead: false,
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  if (!ctx.result) {
    util.error(`Gateway ${ctx.args.gatewayId} not found`, 'NotFound');
  }
  return ctx.result;
}
```

| Modo de autorización de AppSync | Credencial | Llamante típico |
|---|---|---|
| `API_KEY` | Clave estática, expiración máx. 365 días | Solo prototipos y datos públicos de solo lectura |
| `AWS_IAM` | SigV4 | Servicios backend, reglas de IoT, Lambda |
| `AMAZON_COGNITO_USER_POOLS` | JWT con claims de grupo | Usuarios finales en una app web/móvil |
| `OPENID_CONNECT` | JWT OIDC de terceros | SSO empresarial |
| `AWS_LAMBDA` | Función autorizadora personalizada | Formatos de token legacy, lógica por tenant |

### 7.3 AWS Device Farm

Device Farm ejecuta tu app en **teléfonos y tablets físicos reales** en racks administrados por AWS — suites de pruebas automatizadas (Appium, XCUITest, Espresso), sesiones manuales interactivas remotas, y video, logs y datos de rendimiento capturados por dispositivo. Responde a la clase de bug que ningún emulador reproduce: una build de SO de un fabricante específico, una radio real, una GPU real, throttling térmico real.

```console
$ aws devicefarm create-upload --project-arn "$PROJECT_ARN" \
    --name fleet-app-4.3.0.apk --type ANDROID_APP --region us-west-2
{
    "upload": {
        "arn": "arn:aws:devicefarm:us-west-2:111122223333:upload:...",
        "name": "fleet-app-4.3.0.apk",
        "type": "ANDROID_APP",
        "status": "INITIALIZED",
        "url": "https://prod-us-west-2-uploads.s3.us-west-2.amazonaws.com/..."
    }
}

$ aws devicefarm schedule-run --project-arn "$PROJECT_ARN" \
    --app-arn "$UPLOAD_ARN" --device-pool-arn "$POOL_ARN" \
    --name "release-4.3.0-regression" \
    --test '{"type":"APPIUM_PYTHON","testPackageArn":"'"$TEST_ARN"'"}'
{
    "run": {
        "arn": "arn:aws:devicefarm:us-west-2:111122223333:run:...",
        "name": "release-4.3.0-regression",
        "status": "PENDING",
        "result": "PENDING",
        "totalJobs": 12
    }
}
```

> **Nota sobre la Región:** el servicio de pruebas en dispositivos de Device Farm corre en **us-west-2**. Programarlo contra la Región de tu aplicación es una falla común en la primera ejecución.

---

## 8. Internet de las cosas

### 8.1 AWS IoT Core — la mecánica

| Componente | Qué hace | Restricción de producción |
|---|---|---|
| Device gateway | MQTT (8883, mTLS), MQTT sobre WebSocket (443), HTTPS (8443/443) | El puerto 443 requiere **ALPN** con el protocolo `x-amzn-mqtt-ca` cuando se usan certificados de cliente X.509 |
| Registry | Objetos `thing`, thing types, thing groups, atributos | El registry es metadata; la autenticación está en el certificado + política, no en el nombre del thing |
| Autenticación | TLS mutuo X.509 (certificados por dispositivo), SigV4, o autorizador personalizado | Un certificado por dispositivo — nunca un certificado compartido en toda una flota |
| Autorización | Políticas de IoT adjuntas a certificados, con variables de política | `${iot:Connection.Thing.ThingName}` es lo que hace que el aislamiento por dispositivo escale |
| Device Shadow | Documento JSON `desired` / `reported` / `delta` por thing | Te permite fijar la intención para un dispositivo que está offline — el patrón offline central |
| Rules engine | SELECT SQL sobre tópicos MQTT → acciones (DynamoDB, Lambda, SNS, SQS, Kinesis, republish, S3, Timestream) | **Basic ingest** (`$aws/rules/<ruleName>`) salta el broker pub/sub y su cargo de mensajería |
| Jobs | Operaciones remotas (OTA de firmware) con configuraciones de rollout/abort | El rollout escalonado + criterios de aborto son la diferencia entre una actualización y una caída |
| Device Defender | Auditoría de configuración, detección ML/estadística sobre el comportamiento del dispositivo | Detecta un dispositivo comprometido exfiltrando por un tópico inesperado |

### 8.2 Una política de IoT por dispositivo que realmente escala

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ConnectAsOwnThingOnly",
      "Effect": "Allow",
      "Action": "iot:Connect",
      "Resource": "arn:aws:iot:us-east-1:111122223333:client/${iot:Connection.Thing.ThingName}",
      "Condition": {
        "Bool": { "iot:Connection.Thing.IsAttached": ["true"] }
      }
    },
    {
      "Sid": "PublishTelemetryAndBasicIngest",
      "Effect": "Allow",
      "Action": "iot:Publish",
      "Resource": [
        "arn:aws:iot:us-east-1:111122223333:topic/fleet/${iot:Connection.Thing.ThingName}/telemetry",
        "arn:aws:iot:us-east-1:111122223333:topic/$aws/rules/FleetTelemetryIngest",
        "arn:aws:iot:us-east-1:111122223333:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/update"
      ]
    },
    {
      "Sid": "SubscribeToOwnCommandsAndShadowDelta",
      "Effect": "Allow",
      "Action": "iot:Subscribe",
      "Resource": [
        "arn:aws:iot:us-east-1:111122223333:topicfilter/fleet/${iot:Connection.Thing.ThingName}/commands",
        "arn:aws:iot:us-east-1:111122223333:topicfilter/$aws/things/${iot:Connection.Thing.ThingName}/shadow/update/delta",
        "arn:aws:iot:us-east-1:111122223333:topicfilter/$aws/things/${iot:Connection.Thing.ThingName}/shadow/get/accepted"
      ]
    },
    {
      "Sid": "ReceiveOwnCommandsAndShadow",
      "Effect": "Allow",
      "Action": "iot:Receive",
      "Resource": [
        "arn:aws:iot:us-east-1:111122223333:topic/fleet/${iot:Connection.Thing.ThingName}/commands",
        "arn:aws:iot:us-east-1:111122223333:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/*"
      ]
    }
  ]
}
```

Notá las dos acciones distintas: `iot:Subscribe` se autoriza contra un **filtro de tópico** (lo que el cliente pidió), `iot:Receive` contra el **tópico resuelto** (lo que efectivamente llega). Otorgar solo `Subscribe` produce una suscripción que silenciosamente nunca entrega — uno de los modos de falla más confusos de IoT Core.

### 8.3 Rules engine — enrutamiento SQL hacia la capa de integración de la §2

```yaml
  TelemetryIngestRule:
    Type: AWS::IoT::TopicRule
    Properties:
      RuleName: FleetTelemetryIngest
      TopicRulePayload:
        RuleDisabled: false
        AwsIotSqlVersion: '2016-03-23'
        Sql: >-
          SELECT
            topic(2)                              AS gatewayId,
            status                                AS status,
            firmware                              AS firmware,
            errorCount                            AS errorCount,
            region                                AS region,
            timestamp()                           AS ingestedAt,
            clientid()                            AS clientId
          FROM 'fleet/+/telemetry'
          WHERE errorCount >= 10 OR status <> 'HEALTHY'
        Actions:
          - Lambda:
              FunctionArn: !GetAtt NormalizerFunction.Arn
          - Republish:
              RoleArn: !GetAtt IotRuleRole.Arn
              Topic: fleet/aggregated/degraded
              Qos: 1
        ErrorAction:
          Sqs:
            RoleArn: !GetAtt IotRuleRole.Arn
            QueueUrl: !Ref EventBridgeDlq
            UseBase64: false
```

Una regla de IoT sin `ErrorAction` descarta todo mensaje cuya acción falle. Esa es una ruta de pérdida de datos silenciosa e ilimitada, y debería tratarse como un bloqueante de revisión.

### 8.4 AWS IoT Greengrass v2 — cómputo en el borde

Greengrass corre en el propio dispositivo: el **nucleus** administra un conjunto de **componentes** (recipes + artifacts), desplegados a dispositivos individuales o a thing groups. Te da ejecución local de Lambda/contenedores, brokering MQTT local entre dispositivos, un stream manager que hace búfer a disco y reanuda al reconectar, e inferencia ML local — todo lo cual sigue funcionando **mientras el enlace WAN está caído**.

El impulsor arquitectónico: una planta de fábrica no puede tolerar un lazo de control cuya latencia sea un viaje de ida y vuelta a una Región, y un sitio remoto con conectividad intermitente no puede perder los datos almacenados en búfer durante una interrupción.

```yaml
---
RecipeFormatVersion: '2020-01-25'
ComponentName: com.example.EdgeAggregator
ComponentVersion: '1.4.0'
ComponentDescription: >-
  Aggregates local sensor readings, buffers them across WAN outages, and
  publishes a 60-second rollup to AWS IoT Core.
ComponentPublisher: Example Fleet Platform
ComponentConfiguration:
  DefaultConfiguration:
    windowSeconds: 60
    localBufferPath: /var/lib/greengrass/edge-agg/buffer
    maxBufferMB: 512
    publishTopic: 'fleet/{thingName}/telemetry'
    accessControl:
      aws.greengrass.ipc.mqttproxy:
        com.example.EdgeAggregator:mqttproxy:1:
          policyDescription: Publish rollups to IoT Core
          operations:
            - aws.greengrass#PublishToIoTCore
          resources:
            - 'fleet/*/telemetry'
        com.example.EdgeAggregator:mqttproxy:2:
          policyDescription: Receive local commands
          operations:
            - aws.greengrass#SubscribeToIoTCore
          resources:
            - 'fleet/*/commands'
ComponentDependencies:
  aws.greengrass.Nucleus:
    VersionRequirement: '>=2.12.0 <3.0.0'
    DependencyType: SOFT
  aws.greengrass.StreamManager:
    VersionRequirement: '>=2.1.0'
    DependencyType: HARD
Manifests:
  - Platform:
      os: linux
      architecture: aarch64
    Lifecycle:
      Install:
        RequiresPrivilege: true
        Script: |
          set -euo pipefail
          python3 -m venv {artifacts:decompressedPath}/edge-agg/.venv
          {artifacts:decompressedPath}/edge-agg/.venv/bin/pip install \
            --no-index --find-links {artifacts:decompressedPath}/edge-agg/wheels \
            -r {artifacts:decompressedPath}/edge-agg/requirements.txt
      Run:
        Script: |
          {artifacts:decompressedPath}/edge-agg/.venv/bin/python \
            {artifacts:decompressedPath}/edge-agg/main.py \
            --window {configuration:/windowSeconds} \
            --buffer {configuration:/localBufferPath} \
            --max-buffer-mb {configuration:/maxBufferMB}
        Timeout: 30
      Shutdown:
        Script: 'kill -TERM $PPID || true'
        Timeout: 20
    Artifacts:
      - URI: 's3://fleet-gg-artifacts/com.example.EdgeAggregator/1.4.0/edge-agg.zip'
        Unarchive: ZIP
        Permission:
          Read: OWNER
          Execute: OWNER
```

```json
{
  "targetArn": "arn:aws:iot:us-east-1:111122223333:thinggroup/eu-central-gateways",
  "deploymentName": "edge-agg-1.4.0-eu-central",
  "components": {
    "aws.greengrass.Nucleus":       { "componentVersion": "2.12.6" },
    "aws.greengrass.StreamManager": { "componentVersion": "2.1.13" },
    "aws.greengrass.LogManager":    { "componentVersion": "2.3.7" },
    "com.example.EdgeAggregator": {
      "componentVersion": "1.4.0",
      "configurationUpdate": {
        "merge": "{\"windowSeconds\":30,\"maxBufferMB\":1024}"
      }
    }
  },
  "deploymentPolicies": {
    "failureHandlingPolicy": "ROLLBACK",
    "componentUpdatePolicy": {
      "timeoutInSeconds": 60,
      "action": "NOTIFY_COMPONENTS"
    },
    "configurationValidationPolicy": { "timeoutInSeconds": 60 }
  },
  "iotJobConfiguration": {
    "jobExecutionsRolloutConfig": {
      "maximumPerMinute": 50,
      "exponentialRate": {
        "baseRatePerMinute": 5,
        "incrementFactor": 2.0,
        "rateIncreaseCriteria": { "numberOfSucceededThings": 100 }
      }
    },
    "abortConfig": {
      "criteriaList": [
        {
          "failureType": "FAILED",
          "action": "CANCEL",
          "thresholdPercentage": 5.0,
          "minNumberOfExecutedThings": 50
        }
      ]
    },
    "timeoutConfig": { "inProgressTimeoutInMinutes": 30 }
  }
}
```

Ese `abortConfig` es el equivalente en el borde de un rollback de canary: si el 5 % de los primeros 50 gateways falla la actualización, el rollout se detiene antes de dejar inservibles 40.000 dispositivos.

### 8.5 Recorrido de CLI de IoT con salida real

```console
$ aws iot describe-endpoint --endpoint-type iot:Data-ATS
{
    "endpointAddress": "a3k7x9pq2m1nzv-ats.iot.us-east-1.amazonaws.com"
}

$ aws iot create-thing --thing-name gw-7f2a91 --thing-type-name industrial-gateway \
    --attribute-payload '{"attributes":{"site":"eu-central-3","firmware":"4.2.1"}}'
{
    "thingName": "gw-7f2a91",
    "thingArn": "arn:aws:iot:us-east-1:111122223333:thing/gw-7f2a91",
    "thingId": "5c8b1f30-9a2e-4d71-b6c0-3e8f1a90d2b4"
}

$ aws iot create-keys-and-certificate --set-as-active \
    --certificate-pem-outfile gw-7f2a91.cert.pem \
    --public-key-outfile gw-7f2a91.public.key \
    --private-key-outfile gw-7f2a91.private.key \
    --query 'certificateArn' --output text
arn:aws:iot:us-east-1:111122223333:cert/6b1d0e3a7f92c48d15ae0b7c3d92f8140a5e6c7b8d9e0f1a2b3c4d5e6f708192

$ aws iot attach-policy --policy-name FleetDevicePolicy \
    --target arn:aws:iot:us-east-1:111122223333:cert/6b1d0e3a7f92...

$ aws iot attach-thing-principal --thing-name gw-7f2a91 \
    --principal arn:aws:iot:us-east-1:111122223333:cert/6b1d0e3a7f92...

$ mosquitto_pub --cafile AmazonRootCA1.pem \
    --cert gw-7f2a91.cert.pem --key gw-7f2a91.private.key \
    -h a3k7x9pq2m1nzv-ats.iot.us-east-1.amazonaws.com -p 8883 \
    -i gw-7f2a91 \
    -t 'fleet/gw-7f2a91/telemetry' \
    -m '{"status":"DEGRADED","firmware":"4.2.1","errorCount":37,"region":"eu-central"}' \
    -q 1 -d

Client gw-7f2a91 sending CONNECT
Client gw-7f2a91 received CONNACK (0)
Client gw-7f2a91 sending PUBLISH (d0, q1, r0, m1, 'fleet/gw-7f2a91/telemetry', ... (94 bytes))
Client gw-7f2a91 received PUBACK (Mid: 1, RC:0)
Client gw-7f2a91 sending DISCONNECT

$ aws iot-data get-thing-shadow --thing-name gw-7f2a91 /dev/stdout | jq .
{
  "state": {
    "desired":  { "mode": "normal", "sampleIntervalMs": 1000 },
    "reported": { "mode": "quarantine", "sampleIntervalMs": 1000, "firmware": "4.2.1" },
    "delta":    { "mode": "normal" }
  },
  "metadata": {
    "desired":  { "mode": { "timestamp": 1788523311 } },
    "reported": { "mode": { "timestamp": 1788522904 } }
  },
  "version": 47,
  "timestamp": 1788523402
}
```

Un `delta` no vacío significa que el dispositivo **todavía no aplicó** el estado deseado — o está offline, o no está suscrito a `$aws/things/gw-7f2a91/shadow/update/delta`, o la política deniega esa suscripción.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Integración de aplicaciones

| Síntoma | Causa probable | Diagnóstico |
|---|---|---|
| `PutEvents` devuelve `FailedEntryCount: 0` pero no se entrega nada | Ninguna regla matcheó; el patrón de evento es más estricto que el evento | Revisá las métricas `Invocations` / `TriggeredRules` de la regla en `AWS/Events`; validá con `aws events test-event-pattern` |
| La regla de EventBridge matchea pero el target nunca se ejecuta | Falta la política de recurso del target, o error del target | `FailedInvocations` en `AWS/Events`; inspeccioná la DLQ del target |
| El mismo mensaje se procesa dos veces | `VisibilityTimeout` < tiempo de procesamiento; o semántica al-menos-una-vez de la cola Standard | Compará `ApproximateAgeOfOldestMessage` con la duración p99 de tu handler; hacé el consumidor idempotente |
| La profundidad de la cola está plana pero nada avanza | El consumidor está en crash-loop; un mensaje envenenado reintentado eternamente | `ApproximateNumberOfMessagesNotVisible` alto + `NumberOfMessagesDeleted` ≈ 0; revisá `ApproximateReceiveCount` en un mensaje recibido |
| Los mensajes desaparecen silenciosamente | Expiró `MessageRetentionPeriod`, o no hay DLQ configurada | `NumberOfMessagesDeleted` ≪ `NumberOfMessagesSent`; agregá una redrive policy |
| SNS→SQS entrega un JSON doblemente envuelto e inutilizable | `RawMessageDelivery` está en false | Poné `RawMessageDelivery: true` o desenvolvé el sobre de SNS en el consumidor |
| La suscripción SNS descarta mensajes silenciosamente | Una política de filtro que nunca matchea; revisá `FilterPolicyScope` (`MessageAttributes` vs `MessageBody`) | `NumberOfNotificationsFilteredOut` en `AWS/SNS` |
| El throughput FIFO colapsa | Todos los mensajes comparten un mismo `MessageGroupId` — el ordenamiento estricto los serializa | Aumentá la cardinalidad de grupos; habilitá `FifoThroughputLimit: perMessageGroupId` |

```console
$ aws events test-event-pattern \
    --event-pattern file://pattern.json \
    --event '{"id":"1","version":"0","account":"111122223333","time":"2026-09-04T11:42:07Z","region":"us-east-1","resources":[],"source":"com.example.fleet","detail-type":"GatewayHealthChanged","detail":{"status":"DEGRADED","firmware":"4.2.1","errorCount":37,"region":"eu-central"}}'
{
    "Result": true
}
```

Un `Result: false` acá, antes del despliegue, vale una hora de arqueología en la consola después.

### 9.2 Herramientas para desarrolladores

| Síntoma | Causa probable | Diagnóstico |
|---|---|---|
| CodeBuild `CLIENT_ERROR: Access denied` al traer desde ECR/S3 | Al rol de servicio del build le faltan permisos, o la bucket policy de artefactos lo deniega | Leé la fase en `aws codebuild batch-get-builds --query 'builds[0].phases'` |
| CodeBuild pasa pero los artefactos están vacíos | Las rutas de `artifacts.files` son relativas a `baseDirectory`/raíz del build | `aws codebuild batch-get-builds --query 'builds[0].artifacts'` |
| CodeDeploy se cuelga en `ApplicationStop` | Lo que se ejecuta es el script `ApplicationStop` de la revisión **anterior** — un script roto bloquea todos los despliegues futuros | `aws deploy get-deployment-instance`; remediá quitando el script viejo de la instancia o desplegando con `--ignore-application-stop-failures` |
| CodeDeploy blue/green nunca mueve el tráfico | El hook Lambda `AfterAllowTestTraffic` no llamó a `PutLifecycleEventHookExecutionStatus` | Revisá los logs de CloudWatch del hook; el despliegue expira esperando |
| El despliegue "tiene éxito" pero la app está rota | No hay hook `ValidateService` | Agregá un health check real a `ValidateService`, no un `echo ok` |
| X-Ray no muestra trazas | El daemon no es alcanzable en UDP 2000; al rol de la tarea le falta `xray:PutTraceSegments`; tasa de muestreo en 0 | `aws xray get-sampling-rules`; revisá los logs del propio daemon |
| El mapa de servicios de X-Ray tiene nodos huérfanos | El encabezado de traza no se propagó a través de un salto sin SDK | Verificá la propagación de `X-Amzn-Trace-Id` en cada cliente |
| El despliegue de AppConfig hace rollback de inmediato | Una alarma monitor **ya estaba en ALARM** antes de que empezara el despliegue | `EventLog[].TriggeredBy` en `get-deployment`; nunca adjuntes una alarma inestable como monitor |

```console
$ aws codebuild batch-get-builds --ids fleet-telemetry-build:8c14e472-b3a9-48e0-9f64-2e5a7c910d1a \
    --query 'builds[0].phases[?phaseStatus!=`SUCCEEDED`].{Phase:phaseType,Status:phaseStatus,Ctx:contexts[0].message,Sec:durationInSeconds}'

[
    {
        "Phase": "BUILD",
        "Status": "FAILED",
        "Ctx": "Command did not exit successfully pytest -q --junitxml=reports/junit.xml exit status 1",
        "Sec": 74
    },
    {
        "Phase": "COMPLETED",
        "Status": null,
        "Ctx": null,
        "Sec": null
    }
]

$ aws deploy get-deployment --deployment-id d-A1B2C3D4E \
    --query 'deploymentInfo.{Status:status,Err:errorInformation,Rollback:rollbackInfo}'
{
    "Status": "Failed",
    "Err": {
        "code": "HEALTH_CONSTRAINTS",
        "message": "The deployment failed because too many individual instances failed deployment, too few healthy instances are available for deployment, or some instances in your deployment group are experiencing problems."
    },
    "Rollback": {
        "rollbackDeploymentId": "d-F5G6H7I8J",
        "rollbackTriggeringDeploymentId": "d-A1B2C3D4E",
        "rollbackMessage": "Rollback successful."
    }
}
```

### 9.3 SES, EUC e IoT

| Síntoma | Causa probable | Diagnóstico |
|---|---|---|
| `MessageRejected: Email address is not verified` | Sandbox, identidad no verificada, o Región equivocada | `aws sesv2 get-account` → `ProductionAccessEnabled` |
| SES acepta el correo pero cae en spam | DKIM no está en `SUCCESS`, sin MAIL FROM personalizado (desalineación SPF), sin registro DMARC | `aws sesv2 get-email-identity`; revisá el TXT `_dmarc` con `dig` |
| El envío tiene éxito pero el destinatario nunca lo recibe | La dirección está en la lista de supresión de la cuenta o global | `aws sesv2 get-suppressed-destination --email-address ...` |
| Envío pausado | Rebote ≥10 % o quejas ≥0,5 % | `aws sesv2 get-account` → `EnforcementStatus`; panel de reputación |
| WorkSpace `UNHEALTHY` | Directorio inalcanzable, o 4172/4195 bloqueados | `describe-workspaces` + estado de conexión; validá SG/NACL/rutas antes de reconstruir |
| Factura de WorkSpaces muy por encima de lo previsto | AlwaysOn para usuarios de baja utilización | Compará las horas conectadas mensuales contra el punto de cruce de ~80 h de AutoStop |
| El dispositivo se conecta y se desconecta de inmediato | La política deniega `iot:Connect` para ese client ID, o el client ID ≠ nombre del thing con la condición `IsAttached` | Habilitá el logging de IoT → grupo de CloudWatch Logs `AWSIotLogsV2` |
| El dispositivo se suscribe sin error pero no recibe nada | `iot:Subscribe` otorgado, `iot:Receive` no | Mismo grupo de logs; buscá `AUTHORIZATION_FAILURE` en `Receive` |
| El handshake TLS falla en el puerto 443 | Falta ALPN `x-amzn-mqtt-ca` | Usá el puerto 8883, o configurá ALPN en el cliente |
| La regla dispara pero los datos nunca llegan aguas abajo | Al rol IAM de la acción le faltan permisos; sin `ErrorAction`, las fallas se descartan | `RuleMessageThrottled` / `TopicMatch` / `RuleNotFound` en `AWS/IoT`; agregá un `ErrorAction` |

```console
$ aws iot set-v2-logging-options --default-log-level INFO \
    --role-arn arn:aws:iam::111122223333:role/IoTLoggingRole

$ aws logs filter-log-events --log-group-name AWSIotLogsV2 \
    --filter-pattern '{ $.status = "Failure" }' --limit 2 \
    --query 'events[].message' --output text

{"timestamp":"2026-09-04 12:44:01.220","logLevel":"ERROR","traceId":"7b1c...","accountId":"111122223333","status":"Failure","eventType":"Subscribe","protocol":"MQTT","topicName":"fleet/gw-7f2a91/commands","clientId":"gw-7f2a91","principalId":"6b1d0e3a7f92...","reason":"AUTHORIZATION_FAILURE","details":"Authorization Failure"}
{"timestamp":"2026-09-04 12:44:03.881","logLevel":"ERROR","traceId":"8c2d...","accountId":"111122223333","status":"Failure","eventType":"Publish-In","protocol":"MQTT","topicName":"fleet/gw-7f2a91/telemetry","clientId":"gw-7f2a91","principalId":"6b1d0e3a7f92...","reason":"CLIENT_ERROR","details":"Payload size exceeds limit"}
```

### 9.4 Un orden universal de verificación

1. **¿El plano de control aceptó la configuración?** (`describe-*` / `get-*` sobre el recurso — nunca confíes en la plantilla, leé de vuelta el estado desplegado.)
2. **¿La identidad tiene permiso?** (Rol IAM, política de recurso, política de IoT, política de tópico SNS, política de cola SQS — los cuatro lugares donde se esconde un "descarte silencioso".)
3. **¿El mensaje/solicitud realmente llegó?** (Métrica de CloudWatch del servicio *receptor*, no del emisor.)
4. **¿El procesamiento tuvo éxito?** (Profundidad de la DLQ, `FailedInvocations`, estado de la fase, estado del evento de ciclo de vida.)
5. **¿El SLI de extremo a extremo está intacto?** (Mapa de servicios de X-Ray, `ApproximateAgeOfOldestMessage`, canary sintético.)

Los pasos 2 y 3 son donde se resuelve casi todo incidente de "el evento desapareció".

---

## 10. Referencia de costos y cuotas entre categorías

| Servicio | Capa gratuita / piso | Principal impulsor del costo | Error de costo más común |
|---|---|---|---|
| SQS | 1M de solicitudes/mes siempre gratis | Solicitudes (no bytes) | Short polling + sin batching multiplica la cantidad de solicitudes |
| SNS | 1M de publicaciones + 100K entregas HTTP/mes | Publicaciones + entregas; el SMS es caro | El fan-out a muchos suscriptores multiplica las entregas |
| EventBridge | Los eventos de servicios de AWS en el bus por defecto son gratis | Eventos personalizados publicados (por millón) | Publicar telemetría de alta frecuencia a un bus personalizado en lugar de a una cola |
| Step Functions | 4.000 transiciones de estado Standard/mes | Standard: transiciones de estado. Express: duración × memoria | Usar Standard para un workflow de alto volumen y sub-segundo |
| SES | Capa gratuita para mensajes enviados desde una app alojada en EC2/Lambda | Mensajes enviados + datos + IPs dedicadas | IPs dedicadas compradas por debajo del volumen necesario para calentarlas |
| CodeBuild | 100 minutos de build/mes (general1.small) | Minutos de build × tamaño de instancia | Sin caching → reinstalar dependencias en cada build |
| CodePipeline | 1 pipeline activo gratis (V1) / por minuto de acción en V2 | Pipelines activos o minutos de acción | Docenas de pipelines siempre armados sobre ramas muertas |
| X-Ray | 100.000 trazas registradas/mes | Trazas registradas + recuperadas/escaneadas | Muestrear health checks al 100 % |
| AppConfig | — | Solicitudes de configuración + configuración alojada | Hacer polling cada segundo en lugar de usar la cache de la extensión |
| WorkSpaces | — | Bundle × modo de ejecución | AlwaysOn para usuarios de tiempo parcial |
| AppStream 2.0 | — | Horas de instancia de streaming + cargo por usuario | Fleets Always-On sin cronograma de escalado |
| IoT Core | Capa gratuita para mensajes/operaciones de registry (12 meses) | Mensajes, reglas disparadas, acciones ejecutadas, minutos de conexión | Saltarse basic ingest — pagar mensajería pub/sub que nunca consumís |
| Greengrass | Capa gratuita para dispositivos (12 meses) | Por dispositivo por mes | Dispositivos que quedan registrados después de darlos de baja |

---

## 11. Tabla de decisión para el examen

| Si la pregunta dice… | La respuesta es |
|---|---|
| "desacoplar", "amortiguar", "una sola flota de workers", "backpressure" | **Amazon SQS** |
| "el mismo mensaje a múltiples suscriptores", "fan-out", "notificación push/SMS/alerta por correo" | **Amazon SNS** |
| "reaccionar a un evento de un servicio de AWS", "enrutar por contenido", "eventos de partners SaaS", "reproducir eventos" | **Amazon EventBridge** |
| "coordinar múltiples pasos", "workflow visual", "reintentos y aprobación humana", "máquina de estados" | **AWS Step Functions** |
| "enviar correo transaccional/masivo a escala desde una aplicación" | **Amazon SES** |
| "contact center en la nube", "agentes de call center", "IVR" | **Amazon Connect** |
| "soporte telefónico 24×7", "Trusted Advisor completo", "Support API" | **AWS Business Support** |
| "Technical Account Manager designado", "< 15 min para crítico para el negocio" | **AWS Enterprise Support** |
| "< 30 min para crítico para el negocio", "pool de TAMs" | **AWS Enterprise On-Ramp** |
| "AWS opera mi infraestructura por mí, ITIL, RFCs" | **AWS Managed Services (AMS)** |
| "contratar un experto certificado por AWS para un proyecto corto" | **AWS IQ** |
| "créditos y soporte para mi startup" | **AWS Activate for Startups** |
| "compilar, testear, producir artefactos, sin servidores que administrar" | **AWS CodeBuild** |
| "automatizar el despliegue a EC2/Lambda/ECS con rollback" | **AWS CodeDeploy** |
| "modelar el pipeline de release, etapas, aprobaciones" | **AWS CodePipeline** |
| "repositorio de paquetes privado y seguro con upstream público" | **AWS CodeArtifact** |
| "recomendaciones de calidad de código / encontrar la línea de código más cara" | **Amazon CodeGuru** (Reviewer / Profiler) |
| "trazar una solicitud a través de microservicios, encontrar el cuello de botella" | **AWS X-Ray** |
| "feature flags / cambiar la configuración sin redesplegar, con validación y rollback" | **AWS AppConfig** |
| "shell en el navegador con mis credenciales, nada que instalar" | **AWS CloudShell** |
| "escritorio virtual persistente para empleados de tiempo completo" | **Amazon WorkSpaces** |
| "transmitir una sola aplicación a los usuarios, no persistente" | **Amazon AppStream 2.0** |
| "acceso seguro por navegador a sitios internos desde dispositivos no administrados" | **Amazon WorkSpaces Web / Secure Browser** |
| "alojar y hacer CI/CD de una app web desde una rama de Git, con previsualizaciones de PR" | **AWS Amplify** |
| "API GraphQL administrada con suscripciones en tiempo real" | **AWS AppSync** |
| "probar mi app móvil en dispositivos físicos reales" | **AWS Device Farm** |
| "conectar millones de dispositivos por MQTT con certificados por dispositivo" | **AWS IoT Core** |
| "ejecutar cómputo localmente en el dispositivo, funciona offline" | **AWS IoT Greengrass** |

---

## 12. Laboratorio práctico (seguro para la capa gratuita)

**Objetivo:** probar la ruta de ingesta de extremo a extremo y después romperla deliberadamente.

1. Desplegá el stack de CloudFormation de la §2.3. Confirmá la suscripción por correo.
2. Pasá el patrón de la regla por `aws events test-event-pattern` contra un evento de muestra; confirmá `Result: true`.
3. Hacé `put-events` de un evento que matchee; hacé `receive-message` desde la cola de persistencia; confirmá el payload transformado.
4. **Rompelo:** editá el `EventPattern` de la regla para que `errorCount` requiera `>= 1000`. Volvé a publicar. Observá `FailedEntryCount: 0` con cero entregas — internalizá que aceptación ≠ entrega.
5. **Rompelo otra vez:** poné `VisibilityTimeout` en 1 s y consumí con un sleep de 5 segundos. Observá `ApproximateReceiveCount` subiendo sobre el mismo `MessageId`, y después el mensaje cayendo en la DLQ tras `maxReceiveCount`.
6. Hacé redrive de la DLQ con `start-message-move-task`; confirmá `ApproximateNumberOfMessagesMoved`.
7. Iniciá un replay de EventBridge desde el archive sobre la última hora; confirmá que la cola se vuelve a llenar.
8. **Desmontá todo** — `aws cloudformation delete-stack --stack-name fleet-telemetry-integration` — y verificá con `describe-stacks` que devuelve `Stack ... does not exist`.

---

## 13. Referencias

**Guía del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Integración de aplicaciones**
- Amazon SQS Developer Guide — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
- SQS visibility timeout — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- SQS dead-letter queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- SQS FIFO queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html
- Amazon SNS Developer Guide — https://docs.aws.amazon.com/sns/latest/dg/welcome.html
- SNS message filtering — https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html
- Amazon EventBridge User Guide — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html
- EventBridge event patterns — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html
- EventBridge archive and replay — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-archive.html
- AWS Step Functions Developer Guide — https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html

**Aplicaciones de negocio**
- Amazon SES Developer Guide — https://docs.aws.amazon.com/ses/latest/dg/Welcome.html
- SES sending authorization and DKIM — https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim.html
- SES sending review process and reputation — https://docs.aws.amazon.com/ses/latest/dg/faqs-enforcement.html
- Amazon Connect Administrator Guide — https://docs.aws.amazon.com/connect/latest/adminguide/what-is-amazon-connect.html

**Interacción con el cliente**
- AWS Support plans comparison — https://aws.amazon.com/premiumsupport/plans/
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/getting-started.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Managed Services — https://docs.aws.amazon.com/managedservices/latest/userguide/what-is-ams.html
- AWS IQ — https://aws.amazon.com/iq/
- AWS Activate for Startups — https://aws.amazon.com/startups/

**Herramientas para desarrolladores**
- AWS CodePipeline User Guide — https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html
- AWS CodeBuild buildspec reference — https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html
- AWS CodeDeploy AppSpec reference — https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file.html
- CodeDeploy deployment configurations — https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-configurations.html
- AWS CodeArtifact User Guide — https://docs.aws.amazon.com/codeartifact/latest/ug/welcome.html
- Amazon CodeGuru Reviewer — https://docs.aws.amazon.com/codeguru/latest/reviewer-ug/welcome.html
- Amazon CodeGuru Profiler — https://docs.aws.amazon.com/codeguru/latest/profiler-ug/what-is-codeguru-profiler.html
- AWS X-Ray Developer Guide — https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html
- X-Ray sampling rules — https://docs.aws.amazon.com/xray/latest/devguide/xray-console-sampling.html
- AWS AppConfig User Guide — https://docs.aws.amazon.com/appconfig/latest/userguide/what-is-appconfig.html
- AWS CloudShell User Guide — https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html
- AWS CLI v2 User Guide — https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html
- AWS CodeCommit availability change — https://docs.aws.amazon.com/codecommit/latest/userguide/welcome.html
- AWS Cloud9 availability change — https://docs.aws.amazon.com/cloud9/latest/user-guide/welcome.html

**Computación para el usuario final**
- Amazon WorkSpaces Administration Guide — https://docs.aws.amazon.com/workspaces/latest/adminguide/amazon-workspaces.html
- WorkSpaces running modes and pricing — https://docs.aws.amazon.com/workspaces/latest/adminguide/running-mode.html
- Amazon AppStream 2.0 Administration Guide — https://docs.aws.amazon.com/appstream2/latest/developerguide/what-is-appstream.html
- Amazon WorkSpaces Secure Browser — https://docs.aws.amazon.com/workspaces-web/latest/adminguide/what-is-workspaces-web.html

**Web y móvil de front-end**
- AWS Amplify Hosting User Guide — https://docs.aws.amazon.com/amplify/latest/userguide/welcome.html
- Amplify build settings (`amplify.yml`) — https://docs.aws.amazon.com/amplify/latest/userguide/build-settings.html
- AWS AppSync Developer Guide — https://docs.aws.amazon.com/appsync/latest/devguide/what-is-appsync.html
- AppSync authorization modes — https://docs.aws.amazon.com/appsync/latest/devguide/security-authz.html
- AWS Device Farm Developer Guide — https://docs.aws.amazon.com/devicefarm/latest/developerguide/welcome.html

**IoT**
- AWS IoT Core Developer Guide — https://docs.aws.amazon.com/iot/latest/developerguide/what-is-aws-iot.html
- IoT Core policy variables — https://docs.aws.amazon.com/iot/latest/developerguide/thing-policy-variables.html
- IoT Core rules engine and SQL reference — https://docs.aws.amazon.com/iot/latest/developerguide/iot-sql-reference.html
- IoT Device Shadow service — https://docs.aws.amazon.com/iot/latest/developerguide/iot-device-shadows.html
- IoT basic ingest — https://docs.aws.amazon.com/iot/latest/developerguide/iot-basic-ingest.html
- AWS IoT Greengrass Version 2 Developer Guide — https://docs.aws.amazon.com/greengrass/v2/developerguide/what-is-iot-greengrass.html
- Greengrass component recipe reference — https://docs.aws.amazon.com/greengrass/v2/developerguide/component-recipe-reference.html

**Transversales**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS service quotas — https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html
- AWS Free Tier — https://aws.amazon.com/free/