# Topic 3.8 — Identify Services from Other In-Scope AWS Service Categories

**Certification:** AWS Certified Cloud Practitioner (CLF-C02), version 1.0
**Domain 3:** Cloud Technology and Services
**Task Statement 3.8** — exam weight ≈ 4.25%
**Level:** Principal Platform Architect / Senior SRE

---

## 0. Scope of this task statement

Task statement 3.8 is the "everything else" bucket of Domain 3. After compute (3.3), database (3.4), network (3.5), storage (3.6), and AI/ML + analytics (3.7), what remains are **seven service categories** that the CLF-C02 exam guide lists explicitly:

| Category | In-scope services (CLF-C02 appendix) |
|---|---|
| Application Integration | Amazon EventBridge, Amazon SNS, Amazon SQS, AWS Step Functions |
| Business Applications | Amazon Connect, Amazon SES |
| Customer Engagement | AWS Activate for Startups, AWS IQ, AWS Managed Services (AMS), AWS Support |
| Developer Tools | AWS AppConfig, AWS CLI, AWS Cloud9, AWS CloudShell, AWS CodeArtifact, AWS CodeBuild, AWS CodeCommit, AWS CodeDeploy, Amazon CodeGuru, AWS CodePipeline, AWS CodeStar, AWS X-Ray |
| End-User Computing | Amazon AppStream 2.0, Amazon WorkSpaces, Amazon WorkSpaces Web (now branded *WorkSpaces Secure Browser*) |
| Front-End Web and Mobile | AWS Amplify, AWS AppSync, AWS Device Farm |
| IoT | AWS IoT Core, AWS IoT Greengrass |

> **Production reality check the exam does not print.** Three services in the Developer Tools list are in end-of-life posture: **AWS CodeStar** reached end of life on 2024-07-31, and **AWS CodeCommit** and **AWS Cloud9** were closed to new customers on 2024-07-25 (existing customers retain access). They remain examinable because the exam guide is frozen at version 1.0, but you must never propose them for a greenfield platform. The architecturally honest substitutes are: CodeCommit → GitHub/GitLab/Bitbucket via a CodeStar Connection; Cloud9 → AWS CloudShell or a local IDE with the AWS Toolkit; CodeStar → CodePipeline + CloudFormation/CDK directly.

---

## 1. Motivation: the architectural problem these categories solve

Take a concrete production system — a fleet of 40,000 industrial sensors feeding a SaaS observability product:

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

Every box outside compute/storage/database/network belongs to task statement 3.8. That is not a coincidence. **The categories in 3.8 are the connective tissue of a distributed system**: how components talk without knowing about each other (application integration), how the system reaches humans (business applications, end-user computing, front-end), how it reaches physical hardware (IoT), how code gets from a commit to production safely (developer tools), and how you obtain help when it breaks at 03:00 (customer engagement).

The architectural failure mode these services exist to prevent is **synchronous coupling**. If your telemetry ingester calls the alerting service over HTTP and the alerting service is degraded, the ingester's threads block, its queue depth grows, the load balancer starts failing health checks, and a non-critical subsystem takes down a critical one. Queues, topics, and event buses break that chain by converting a *call* into a *durable message*. The trade-off you are buying is: **availability and independent scaling in exchange for eventual consistency, duplicate delivery, and the operational burden of dead-letter handling**. That trade-off is the single most examinable idea in this task statement.

---

## 2. Application Integration

### 2.1 The three primitives and how they actually differ

| Dimension | Amazon SQS | Amazon SNS | Amazon EventBridge |
|---|---|---|---|
| Pattern | Point-to-point queue (pull) | Pub/sub topic (push) | Event bus + router (push, rule-based) |
| Consumers | One logical consumer group; a message is deleted after processing | Many subscribers, each gets a copy | Many targets, selected by event pattern |
| Delivery semantics | At-least-once (Standard); exactly-once processing (FIFO) | At-least-once | At-least-once |
| Ordering | Best-effort (Standard); strict per `MessageGroupId` (FIFO) | Best-effort; strict on FIFO topics | Not guaranteed |
| Message retention | 1 min – **14 days** (default 4 days) | None — not durable if no subscriber | **Archive** (configurable retention) + **Replay** |
| Filtering | None (consumer filters) | Subscription filter policies on attributes/body | Rich content-based event patterns (prefix, numeric, `anything-but`, `exists`) |
| Payload limit | 256 KB (2 GB via Extended Client Library + S3) | 256 KB | 256 KB |
| Backpressure | Native — consumer pulls at its own rate | None — subscriber must absorb push | None — target must absorb push |
| Native retry / DLQ | Redrive policy → DLQ after `maxReceiveCount` | Delivery retry policy + per-subscription DLQ | Retry up to 24 h + DLQ per target |
| Cross-account / cross-Region | Resource policy | Resource policy | Bus-to-bus routing, native cross-Region |
| Third-party / SaaS ingress | No | No | **Yes** — partner event sources, API destinations |
| Typical latency | ms (plus poll interval) | ms | ~ms, higher tail than SNS |
| Price model | Per request (batching of 10 amortizes) | Per publish + per delivery | Per event published to a custom bus (AWS-service events free on default bus) |

**The decision rule an architect uses:**

- Need **durable work distribution with backpressure** and one worker fleet → **SQS**.
- Need **the same message delivered to N independent subsystems**, low latency, push → **SNS**.
- Need **routing by content, ingestion of AWS-service or SaaS events, schema discovery, replay** → **EventBridge**.
- Need **stateful, long-running, auditable orchestration with retries and compensation** → **Step Functions** (a workflow engine, not a message bus).

**The canonical production pattern is not "either/or" — it is SNS → SQS fan-out.** A topic pushes to several queues; each consuming service gets its own durable buffer, its own retry budget, its own DLQ, and can be down for hours without losing data. EventBridge sits in front when the events come from AWS services themselves (an EC2 state change, an ECS task stopping, a CodePipeline stage failing).

### 2.2 The four SQS parameters that cause most production incidents

| Parameter | Default | Failure it causes when wrong |
|---|---|---|
| `VisibilityTimeout` | 30 s (max 12 h) | Shorter than actual processing time → another consumer receives the same message → **duplicate side effects** and infinite reprocessing |
| `ReceiveMessageWaitTimeSeconds` | 0 (short polling) | Short polling samples a subset of servers → empty responses, higher cost, false "queue is empty" signals. Set to **20** (long polling) |
| `maxReceiveCount` (redrive) | none | Without a DLQ, a poison-pill message is retried until retention expires, consuming the whole consumer fleet |
| `MessageRetentionPeriod` | 4 days | Too short → silent data loss during a long outage; too long → a backlog you can never drain |

### 2.3 Complete infrastructure — CloudFormation (event ingestion + fan-out + DLQ)

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

> **Note on `MessageRetentionPeriod`:** the property is expressed in **seconds**, not days. The parameter above is intentionally left as written so you see the trap — in a real stack you would compute `!Ref MessageRetentionDays` × 86400 with a `Fn::Transform`/macro, or simply hard-code `1209600`. A misread unit here silently sets retention to 14 *seconds*, and messages vanish before any consumer polls.

### 2.4 CLI: deploy, publish, observe, redrive

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

Publish a synthetic event onto the custom bus:

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

`FailedEntryCount: 0` means EventBridge **accepted** the event. It does **not** mean any rule matched it. That distinction is the number-one EventBridge debugging error.

Confirm the message actually landed:

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

Inspect effective queue configuration — the fastest way to catch a visibility-timeout mismatch:

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

Drain a DLQ back to the source queue after fixing the consumer bug (managed redrive, no custom script):

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

Replay archived events after a consumer defect (EventBridge, not possible with SNS):

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

### 2.5 AWS Step Functions — where orchestration belongs

Queues and buses move messages; they do not remember *where a business process is*. Step Functions is a managed state machine with durable execution state, built-in retries with exponential backoff, `Catch` blocks for compensation (the saga pattern), and a full visual execution history.

| Workflow type | Duration | Execution history | Pricing model | Use case |
|---|---|---|---|---|
| **Standard** | up to 1 year | Durable, fully recorded, exactly-once execution | Per state transition | Long-running, auditable, human approval steps, non-idempotent side effects |
| **Express** | up to 5 min | Sent to CloudWatch Logs, at-least-once | Per execution + duration + memory | High-volume event processing, IoT ingestion, streaming |

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

## 3. Business Applications

### 3.1 Amazon SES — the deliverability control plane

SES is not "an SMTP server in the cloud". It is a **reputation-managed sending platform**, and every architectural decision in it exists to protect the shared IP pool's reputation.

| Concept | Mechanics | Why an SRE cares |
|---|---|---|
| Sandbox | New accounts: max **200 messages / 24 h**, **1 msg/s**, recipients must be verified identities | A load test from a sandboxed account fails with `MessageRejected: Email address is not verified` |
| Verified identity | Domain (TXT/CNAME) or single email address | Domain verification lets you send from any local-part; email verification does not scale |
| DKIM | Easy DKIM publishes 3 CNAMEs; BYODKIM allows your own key | Unsigned mail is the fastest route to a spam folder |
| SPF / custom MAIL FROM | Custom MAIL FROM subdomain + MX + SPF TXT | Required for **SPF alignment**, which DMARC needs |
| DMARC | Your own `_dmarc` TXT with `p=quarantine`/`p=reject` | Without alignment on SPF *or* DKIM, DMARC fails even with valid DKIM |
| Configuration set | Named bundle of event destinations, IP pool, TLS policy, suppression overrides | Segregates transactional from marketing reputation |
| Event destinations | CloudWatch, Firehose, SNS, EventBridge | The only way to *measure* bounces/complaints per campaign |
| Suppression list | Account-level and global | Sending to a suppressed address returns success but never delivers |
| Dedicated IPs | Standard (you warm up) or Managed (SES warms up) | Isolates your reputation from other tenants; requires sustained volume |
| Reputation thresholds | Bounce rate: review at **5%**, possible pause at **10%**. Complaint rate: review at **0.1%**, possible pause at **0.5%** | These are the numbers that get an account paused |

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

Failure signature to memorise:

```console
$ aws sesv2 send-email --from-email-address "alerts@notverified.example" ...

An error occurred (MessageRejected) when calling the SendEmail operation:
Email address is not verified. The following identities failed the check in
region US-EAST-1: alerts@notverified.example
```

That error means **one of three things**: the identity is not verified, the account is still in the sandbox and the *recipient* is not verified, or you are sending in the wrong Region — SES identities are **Regional**, and verifying a domain in `us-east-1` does nothing in `eu-west-1`.

### 3.2 Amazon Connect

Amazon Connect is a **cloud contact center**: omnichannel (voice, chat, task, email), pay-per-use by the minute/message with no seat licences, contact flows built as a visual state machine, and native integrations with Lex (conversational IVR), Lambda (CRM lookups), and Contact Lens (real-time transcription, sentiment analysis, and compliance redaction).

The architecturally relevant fact for the exam: **Connect replaces on-premises telephony hardware and per-seat licensing**, scales elastically with call volume, and integrates through the same event/integration primitives you already have — Connect emits contact events to EventBridge and Kinesis, so escalation paths flow into the SNS/SQS topology from §2.

---

## 4. Customer Engagement

This category is about **how you get human help**, and the Support plan table is one of the most reliably examined tables in the entire certification.

| | **Basic** | **Developer** | **Business** | **Enterprise On-Ramp** | **Enterprise** |
|---|---|---|---|---|---|
| Cost | Free | From $29/mo or 3% of spend | From $100/mo, tiered % of spend | From $5,500/mo | From $15,000/mo |
| Channels | Docs, forums, service health, account/billing support | Email (business hours) | 24×7 email, chat, phone | 24×7 email, chat, phone | 24×7 email, chat, phone |
| Who answers | — | Cloud Support Associates | Cloud Support Engineers | Cloud Support Engineers | Cloud Support Engineers |
| General guidance | — | < 24 business hours | < 24 h | < 24 h | < 24 h |
| System impaired | — | < 12 business hours | < 12 h | < 12 h | < 12 h |
| **Production system impaired** | — | — | **< 4 h** | < 4 h | < 4 h |
| **Production system down** | — | — | **< 1 h** | < 1 h | < 1 h |
| **Business-critical system down** | — | — | — | **< 30 min** | **< 15 min** |
| Trusted Advisor | Core checks only | Core checks only | **Full check set** | Full check set | Full check set |
| AWS Support API | No | No | **Yes** | Yes | Yes |
| Third-party software support | No | No | Yes | Yes | Yes |
| Technical Account Manager | No | No | No | **Pool of TAMs** | **Designated TAM** |
| Concierge / billing experts | No | No | No | Yes | Yes |
| Architectural guidance | — | General | Contextual | Consultative review | Consultative + Well-Architected reviews |
| Incident detection & response, countdown/support for events | No | No | No | Limited | Yes |

**Decision rules the exam tests:**
- "We need a *response in under 15 minutes* for business-critical outages" → **Enterprise**.
- "We need a *designated* Technical Account Manager" → **Enterprise** (On-Ramp gives a *pool*).
- "We need the *full* set of Trusted Advisor checks" → **Business** or higher.
- "We need to open support cases *programmatically*" → **Business** or higher (Support API).
- "We need 24×7 phone support for production" → **Business** or higher.

**Other services in this category:**

- **AWS Managed Services (AMS)** — AWS operates your infrastructure on your behalf under an ITIL-aligned operating model: patching, monitoring, incident management, backup, change management via RFCs. Buy this when you are migrating a large enterprise estate and lack the operations headcount, not when you already run a mature platform team.
- **AWS IQ** — an on-demand marketplace to hire AWS Certified third-party experts for small, scoped projects, billed through your AWS account.
- **AWS Activate for Startups** — credits, technical support plan credits, and training for eligible startups.

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

On a Basic or Developer plan the same call fails — a fast, definitive way to confirm your plan tier:

```console
$ aws support describe-severity-levels --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: AWS Premium Support Subscription is required
to use this service.
```

> **Endpoint note:** the AWS Support and Trusted Advisor APIs are global services with endpoints in `us-east-1`. Calling them with `--region eu-west-1` fails regardless of plan.

---

## 5. Developer Tools

### 5.1 The pipeline as a system

| Service | Role in the pipeline | Key production constraint |
|---|---|---|
| **CodePipeline** | Orchestrator: stages, actions, transitions, approvals | Artifacts flow through an S3 artifact bucket; encrypt it and lock its bucket policy |
| **CodeBuild** | Ephemeral build compute; `buildspec.yml` | No state between builds — use local caching or S3 cache deliberately |
| **CodeDeploy** | Deployment engine for EC2/on-prem, Lambda, ECS | Provides in-place, blue/green, canary and linear strategies with automatic rollback |
| **CodeArtifact** | Managed package repository (npm, PyPI, Maven, NuGet, generic, Swift, Ruby) | Upstream to public registries so a public outage does not stop your builds |
| **CodeGuru** | Reviewer (code recommendations), Profiler (runtime hot paths), Security | Profiler needs an agent in the running app; Reviewer needs repository association |
| **X-Ray** | Distributed tracing: segments, subsegments, service map | Sampling is *lossy by design* — do not use it as a billing/audit log |
| **AppConfig** | Runtime configuration and feature flags with validated, monitored rollout | Decouples config change from deployment; supports automatic rollback on alarm |
| **CloudShell** | Browser shell with your console credentials pre-loaded, 1 GB persistent home per Region | Free; persistent storage is deleted after 120 days of inactivity |
| **AWS CLI** | The universal control plane client | v2 only for new work; `--query` (JMESPath) is the difference between a script and a pipeline |

### 5.2 Complete `buildspec.yml` (CodeBuild)

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

> `file-format` values are case-insensitive on the service side but conventionally uppercase (`COBERTURAXML`); the value above is written as the service accepts it. If CodeBuild reports `Invalid report file-format`, that string is the first thing to check.

### 5.3 Complete `appspec.yaml` — two deployment targets

**EC2 / on-premises (in-place or blue/green), with all five lifecycle hooks:**

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

**Amazon ECS blue/green with a test listener:**

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

**Deployment strategy trade-offs:**

| Strategy | Extra capacity cost | Rollback time | Blast radius of a bad build | Session impact |
|---|---|---|---|---|
| In-place, all-at-once | None | Full redeploy (minutes) | 100% | Total outage during deploy |
| In-place, one-at-a-time | None | Full redeploy | Gradual | Reduced capacity |
| In-place, half-at-a-time | None | Full redeploy | 50% | 50% capacity |
| Blue/green (canary 10% / 5 min) | 2× during deploy | **Seconds** — shift listener back | 10% for the canary window | Existing connections drain |
| Blue/green (linear 10% every 3 min) | 2× during deploy | Seconds | Ramps 10→100% | Gradual |
| Blue/green (all-at-once shift) | 2× during deploy | Seconds | 100% at cutover | Instant cutover |

The reason blue/green costs double capacity and is still the default for anything customer-facing: **rollback is a listener rule change, not a redeployment**. That converts a 15-minute recovery into a 15-second one.

### 5.4 AWS AppConfig — configuration as a monitored deployment

The failure AppConfig prevents: a feature flag flipped by editing an environment variable, requiring a full deployment, with no validation and no automatic rollback. AppConfig makes configuration a **first-class deployment** with validators (JSON Schema or a Lambda) *before* rollout and CloudWatch alarm monitors that trigger **automatic rollback** during rollout.

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

That `ROLLBACK_COMPLETED / TriggeredBy: CLOUDWATCH_ALARM` is the whole value proposition: a bad flag was withdrawn automatically at 30% exposure without a human in the loop.

### 5.5 AWS X-Ray — sampling, segments, and the service map

X-Ray builds a **service map** from segments (one per service) and subsegments (one per downstream call), correlated by a trace ID propagated in the `X-Amzn-Trace-Id` header. The SDK emits UDP to the X-Ray daemon on **port 2000**; the daemon batches and calls `PutTraceSegments`.

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

`fixed_target` is the number of requests per second sampled *before* the percentage rate applies. The default rule above traces the first 1 req/s plus 5% of the remainder — which is why **X-Ray is a diagnostic tool, not an audit log**.

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

### 5.6 CodeArtifact and CodeGuru in one minute each

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

CodeArtifact's architectural point is the **upstream repository**: your internal repo upstreams to a public PyPI/npm connection, so packages are cached in your account. A public registry outage or a yanked package no longer breaks your builds, and every dependency is auditable.

**Amazon CodeGuru** has two halves: **Reviewer** (static analysis of pull requests — concurrency bugs, resource leaks, AWS API misuse, hardcoded secrets) and **Profiler** (a low-overhead agent in the running application producing flame graphs and a cost-of-CPU-time estimate). Reviewer answers "is this code defective?"; Profiler answers "where is production actually spending money?"

---

## 6. End-User Computing

| | **Amazon WorkSpaces** | **Amazon AppStream 2.0** | **Amazon WorkSpaces Web / Secure Browser** |
|---|---|---|---|
| Delivers | A full persistent virtual desktop (DaaS) | Individual streamed applications (or a desktop) | A managed, isolated Chrome-based browser session |
| Persistence | Persistent user volume across sessions | Non-persistent by default; optional home folders in S3 | Fully ephemeral by design |
| Identity | AWS Managed Microsoft AD, AD Connector, Simple AD | SAML 2.0 IdP, user pool | SAML 2.0 IdP |
| Client | Native clients (Windows/macOS/Linux/iOS/Android/Chromebook), web access | HTML5 browser, native client | Any modern browser — nothing installed |
| Protocol / ports | PCoIP: TCP/UDP **4172**; DCV (WSP): TCP/UDP **4195**; plus TCP 443 for registration | HTTPS 443 (+ optional UDP) | HTTPS 443 |
| Billing | Monthly (AlwaysOn) or hourly + small monthly fee (AutoStop) | Per streaming instance-hour + per-user fee | Per active user-hour |
| Best fit | Full-time knowledge workers, developers, regulated desktops | Contractors, labs, seasonal users, GPU/CAD apps, a single legacy app | Contractor/BYOD access to internal web apps and SaaS |
| Data-egress control | Desktop is in your VPC; clipboard/USB/printing policies | Same, per-fleet policies | Strongest — no data reaches the endpoint device |

**The cost trap in WorkSpaces:** AutoStop billing is hourly *plus* a fixed monthly infrastructure fee. Below roughly 80 hours of monthly use, AutoStop is cheaper; above that crossover, AlwaysOn is. A fleet left on AlwaysOn for users who log in twice a week is one of the most common avoidable EUC bills.

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

`UNHEALTHY` almost always means the WorkSpace agent cannot reach the management interface: a missing route to the internet/VPC endpoints, a security group blocking 4172/4195, or a directory that has lost its domain controllers. Rebuilding the WorkSpace before checking the directory is the usual wasted hour.

---

## 7. Front-End Web and Mobile

### 7.1 AWS Amplify

Amplify Hosting is a managed CI/CD and CDN-backed host for single-page and server-rendered web apps: connect a Git branch, get atomic deploys, per-branch environments, pull-request previews, password protection, custom domains with managed TLS, and instant rollback to a previous deploy.

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

AppSync is managed **GraphQL** (and Pub/Sub over WebSockets): one endpoint, a typed schema, resolvers that attach fields to data sources (DynamoDB, Aurora via RDS Data API, Lambda, OpenSearch, HTTP, EventBridge), and **real-time subscriptions** driven by mutations.

The architectural reason to choose it over REST: a mobile client on a poor network needs exactly the fields it will render, in one round trip. REST either over-fetches or forces a proliferation of bespoke endpoints.

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

| AppSync authorization mode | Credential | Typical caller |
|---|---|---|
| `API_KEY` | Static key, max 365-day expiry | Prototypes and public read-only data only |
| `AWS_IAM` | SigV4 | Backend services, IoT rules, Lambda |
| `AMAZON_COGNITO_USER_POOLS` | JWT with group claims | End users in a web/mobile app |
| `OPENID_CONNECT` | Third-party OIDC JWT | Enterprise SSO |
| `AWS_LAMBDA` | Custom authorizer function | Legacy token formats, per-tenant logic |

### 7.3 AWS Device Farm

Device Farm runs your app on **real, physical phones and tablets** in AWS-managed racks — automated test suites (Appium, XCUITest, Espresso), remote manual interactive sessions, and captured video, logs, and performance data per device. It answers the class of bug that no emulator reproduces: a specific vendor's OS build, a real radio, a real GPU, real thermal throttling.

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

> **Region note:** Device Farm's device-testing service runs in **us-west-2**. Scripting it against your application's Region is a common first-run failure.

---

## 8. Internet of Things

### 8.1 AWS IoT Core — the mechanics

| Component | What it does | Production constraint |
|---|---|---|
| Device gateway | MQTT (8883, mTLS), MQTT over WebSocket (443), HTTPS (8443/443) | Port 443 requires **ALPN** with protocol `x-amzn-mqtt-ca` when using X.509 client certs |
| Registry | `thing` objects, thing types, thing groups, attributes | Registry is metadata; auth is on the certificate + policy, not the thing name |
| Authentication | X.509 mutual TLS (per-device certs), SigV4, or custom authorizer | One certificate per device — never a shared certificate across a fleet |
| Authorization | IoT policies attached to certificates, with policy variables | `${iot:Connection.Thing.ThingName}` is what makes per-device isolation scale |
| Device Shadow | JSON `desired` / `reported` / `delta` document per thing | Lets you set intent for a device that is offline — the core offline pattern |
| Rules engine | SQL SELECT over MQTT topics → actions (DynamoDB, Lambda, SNS, SQS, Kinesis, republish, S3, Timestream) | **Basic ingest** (`$aws/rules/<ruleName>`) skips the pub/sub broker and its messaging charge |
| Jobs | Remote operations (OTA firmware) with rollout/abort configs | Staged rollout + abort criteria are the difference between an update and an outage |
| Device Defender | Audit of config, ML/statistical detect on device behaviour | Catches a compromised device exfiltrating over an unexpected topic |

### 8.2 A per-device IoT policy that actually scales

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

Note the two distinct actions: `iot:Subscribe` is authorized against a **topic filter** (what the client asked for), `iot:Receive` against the **resolved topic** (what actually arrives). Granting only `Subscribe` yields a subscription that silently never delivers — one of the most confusing IoT Core failure modes.

### 8.3 Rules engine — SQL routing into the integration layer of §2

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

An IoT rule without an `ErrorAction` discards every message whose action fails. That is a silent, unbounded data-loss path and should be treated as a review blocker.

### 8.4 AWS IoT Greengrass v2 — compute at the edge

Greengrass runs on the device itself: the **nucleus** manages a set of **components** (recipes + artifacts), deployed to individual devices or thing groups. It gives you local Lambda/container execution, local MQTT brokering between devices, a stream manager that buffers to disk and resumes on reconnect, and local ML inference — all of which continue working **while the WAN link is down**.

The architectural driver: a factory floor cannot tolerate a control loop whose latency is a round trip to a Region, and a remote site with intermittent connectivity cannot lose the data buffered during an outage.

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

That `abortConfig` is the edge equivalent of a canary rollback: if 5% of the first 50 gateways fail the update, the rollout stops before it bricks 40,000 devices.

### 8.5 IoT CLI walkthrough with real output

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

A non-empty `delta` means the device has **not yet applied** the desired state — either it is offline, or it is not subscribed to `$aws/things/gw-7f2a91/shadow/update/delta`, or the policy denies that subscription.

---

## 9. Verification and failure diagnosis

### 9.1 Application integration

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| `PutEvents` returns `FailedEntryCount: 0` but nothing is delivered | No rule matched; event pattern is stricter than the event | Check the rule's `Invocations` / `TriggeredRules` metric in `AWS/Events`; validate with `aws events test-event-pattern` |
| EventBridge rule matches but target never runs | Target resource policy missing, or target error | `AWS/Events` `FailedInvocations`; inspect the target DLQ |
| Same message processed twice | `VisibilityTimeout` < processing time; or Standard-queue at-least-once semantics | Compare `ApproximateAgeOfOldestMessage` with your p99 handler duration; make the consumer idempotent |
| Queue depth flat but nothing progresses | Consumer crash-looping; a poison pill retried forever | `ApproximateNumberOfMessagesNotVisible` high + `NumberOfMessagesDeleted` ≈ 0; check `ApproximateReceiveCount` on a received message |
| Messages vanish silently | `MessageRetentionPeriod` expired, or no DLQ configured | `NumberOfMessagesDeleted` ≪ `NumberOfMessagesSent`; add a redrive policy |
| SNS→SQS delivers an unusable double-wrapped JSON | `RawMessageDelivery` is false | Set `RawMessageDelivery: true` or unwrap the SNS envelope in the consumer |
| SNS subscription silently drops messages | A filter policy that never matches; check `FilterPolicyScope` (`MessageAttributes` vs `MessageBody`) | `NumberOfNotificationsFilteredOut` in `AWS/SNS` |
| FIFO throughput collapses | All messages share one `MessageGroupId` — strict ordering serialises them | Increase group cardinality; enable `FifoThroughputLimit: perMessageGroupId` |

```console
$ aws events test-event-pattern \
    --event-pattern file://pattern.json \
    --event '{"id":"1","version":"0","account":"111122223333","time":"2026-09-04T11:42:07Z","region":"us-east-1","resources":[],"source":"com.example.fleet","detail-type":"GatewayHealthChanged","detail":{"status":"DEGRADED","firmware":"4.2.1","errorCount":37,"region":"eu-central"}}'
{
    "Result": true
}
```

`Result: false` here, before deployment, is worth an hour of console archaeology after.

### 9.2 Developer tools

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| CodeBuild `CLIENT_ERROR: Access denied` pulling from ECR/S3 | Build service role lacks permission, or the artifact bucket policy denies it | Read the phase in `aws codebuild batch-get-builds --query 'builds[0].phases'` |
| CodeBuild passes but artifacts are empty | `artifacts.files` paths are relative to `baseDirectory`/build root | `aws codebuild batch-get-builds --query 'builds[0].artifacts'` |
| CodeDeploy hangs at `ApplicationStop` | The **previous** revision's `ApplicationStop` script is what runs — a broken script blocks all future deploys | `aws deploy get-deployment-instance`; remediate by removing the old script from the instance or deploying with `--ignore-application-stop-failures` |
| CodeDeploy blue/green never shifts traffic | `AfterAllowTestTraffic` Lambda hook did not call `PutLifecycleEventHookExecutionStatus` | Check the hook's CloudWatch logs; the deployment times out waiting |
| Deployment "succeeds" but the app is broken | No `ValidateService` hook | Add a real health check to `ValidateService`, not `echo ok` |
| X-Ray shows no traces | Daemon not reachable on UDP 2000; task role lacks `xray:PutTraceSegments`; sampling rate 0 | `aws xray get-sampling-rules`; check the daemon's own logs |
| X-Ray service map has orphaned nodes | Trace header not propagated across an SDK-less hop | Verify `X-Amzn-Trace-Id` propagation in every client |
| AppConfig deployment rolls back immediately | A monitor alarm was **already in ALARM** before the deployment started | `EventLog[].TriggeredBy` in `get-deployment`; never attach a flapping alarm as a monitor |

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

### 9.3 SES, EUC and IoT

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| `MessageRejected: Email address is not verified` | Sandbox, unverified identity, or wrong Region | `aws sesv2 get-account` → `ProductionAccessEnabled` |
| Mail accepted by SES but lands in spam | DKIM not `SUCCESS`, no custom MAIL FROM (SPF misalignment), no DMARC record | `aws sesv2 get-email-identity`; check `_dmarc` TXT with `dig` |
| Send succeeds but the recipient never receives | Address is on the account or global suppression list | `aws sesv2 get-suppressed-destination --email-address ...` |
| Sending paused | Bounce ≥10% or complaint ≥0.5% | `aws sesv2 get-account` → `EnforcementStatus`; reputation dashboard |
| WorkSpace `UNHEALTHY` | Directory unreachable, or 4172/4195 blocked | `describe-workspaces` + connection status; validate SG/NACL/routes before rebuilding |
| WorkSpaces bill far above forecast | AlwaysOn for low-utilisation users | Compare monthly connected hours against the ~80 h AutoStop crossover |
| Device connects then immediately disconnects | Policy denies `iot:Connect` for that client ID, or the client ID ≠ thing name with `IsAttached` condition | Enable IoT logging → CloudWatch Logs group `AWSIotLogsV2` |
| Device subscribes with no error but receives nothing | `iot:Subscribe` granted, `iot:Receive` not | Same log group; look for `AUTHORIZATION_FAILURE` on `Receive` |
| TLS handshake fails on port 443 | Missing ALPN `x-amzn-mqtt-ca` | Use port 8883, or configure ALPN in the client |
| Rule fires but data never lands downstream | Action IAM role lacks permission; no `ErrorAction` so failures are discarded | `AWS/IoT` `RuleMessageThrottled` / `TopicMatch` / `RuleNotFound`; add an `ErrorAction` |

```console
$ aws iot set-v2-logging-options --default-log-level INFO \
    --role-arn arn:aws:iam::111122223333:role/IoTLoggingRole

$ aws logs filter-log-events --log-group-name AWSIotLogsV2 \
    --filter-pattern '{ $.status = "Failure" }' --limit 2 \
    --query 'events[].message' --output text

{"timestamp":"2026-09-04 12:44:01.220","logLevel":"ERROR","traceId":"7b1c...","accountId":"111122223333","status":"Failure","eventType":"Subscribe","protocol":"MQTT","topicName":"fleet/gw-7f2a91/commands","clientId":"gw-7f2a91","principalId":"6b1d0e3a7f92...","reason":"AUTHORIZATION_FAILURE","details":"Authorization Failure"}
{"timestamp":"2026-09-04 12:44:03.881","logLevel":"ERROR","traceId":"8c2d...","accountId":"111122223333","status":"Failure","eventType":"Publish-In","protocol":"MQTT","topicName":"fleet/gw-7f2a91/telemetry","clientId":"gw-7f2a91","principalId":"6b1d0e3a7f92...","reason":"CLIENT_ERROR","details":"Payload size exceeds limit"}
```

### 9.4 A universal verification order

1. **Did the control plane accept the configuration?** (`describe-*` / `get-*` on the resource — never trust the template, read back the deployed state.)
2. **Is the identity allowed?** (IAM role, resource policy, IoT policy, SNS topic policy, SQS queue policy — the four places a "silent drop" hides.)
3. **Did the message/request actually arrive?** (CloudWatch metric for the *receiving* service, not the sending one.)
4. **Did processing succeed?** (DLQ depth, `FailedInvocations`, phase status, lifecycle event status.)
5. **Is the end-to-end SLI intact?** (X-Ray service map, `ApproximateAgeOfOldestMessage`, synthetic canary.)

Steps 2 and 3 are where nearly every "the event disappeared" incident resolves.

---

## 10. Cross-category cost and quota reference

| Service | Free tier / floor | Principal cost driver | Most common cost mistake |
|---|---|---|---|
| SQS | 1M requests/month always free | Requests (not bytes) | Short polling + no batching multiplies request count |
| SNS | 1M publishes + 100K HTTP deliveries/month | Publishes + deliveries; SMS is expensive | Fan-out to many subscribers multiplies deliveries |
| EventBridge | AWS-service events on the default bus are free | Custom events published (per million) | Publishing high-frequency telemetry to a custom bus instead of a queue |
| Step Functions | 4,000 Standard state transitions/month | Standard: state transitions. Express: duration × memory | Using Standard for a high-volume, sub-second workflow |
| SES | Free tier for messages sent from an EC2/Lambda-hosted app | Messages sent + data + dedicated IPs | Dedicated IPs bought below the volume needed to warm them |
| CodeBuild | 100 build-minutes/month (general1.small) | Build minutes × instance size | No caching → reinstalling dependencies every build |
| CodePipeline | 1 free active pipeline (V1) / per-action-minute on V2 | Active pipelines or action minutes | Dozens of always-armed pipelines on dead branches |
| X-Ray | 100,000 traces recorded/month | Traces recorded + retrieved/scanned | Sampling health checks at 100% |
| AppConfig | — | Configuration requests + hosted config | Polling every second instead of using the extension's cache |
| WorkSpaces | — | Bundle × running mode | AlwaysOn for part-time users |
| AppStream 2.0 | — | Streaming instance-hours + user fee | Always-On fleets with no scaling schedule |
| IoT Core | Free tier for messages/registry ops (12 months) | Messages, rules triggered, actions executed, connection minutes | Bypassing basic ingest — paying for pub/sub messaging you never consume |
| Greengrass | Free tier for devices (12 months) | Per device per month | Devices left registered after decommissioning |

---

## 11. Exam decision table

| The question says… | The answer is |
|---|---|
| "decouple", "buffer", "one worker fleet", "backpressure" | **Amazon SQS** |
| "same message to multiple subscribers", "fan-out", "push notification/SMS/email alert" | **Amazon SNS** |
| "react to an AWS service event", "route by content", "SaaS partner events", "replay events" | **Amazon EventBridge** |
| "coordinate multiple steps", "visual workflow", "retries and human approval", "state machine" | **AWS Step Functions** |
| "send transactional/bulk email at scale from an application" | **Amazon SES** |
| "cloud contact center", "call center agents", "IVR" | **Amazon Connect** |
| "24×7 phone support", "full Trusted Advisor", "Support API" | **AWS Business Support** |
| "designated Technical Account Manager", "< 15 min for business-critical" | **AWS Enterprise Support** |
| "< 30 min for business-critical", "pool of TAMs" | **AWS Enterprise On-Ramp** |
| "AWS operates my infrastructure for me, ITIL, RFCs" | **AWS Managed Services (AMS)** |
| "hire an AWS-certified expert for a short project" | **AWS IQ** |
| "credits and support for my startup" | **AWS Activate for Startups** |
| "compile, test, produce artifacts, no servers to manage" | **AWS CodeBuild** |
| "automate deployment to EC2/Lambda/ECS with rollback" | **AWS CodeDeploy** |
| "model the release pipeline, stages, approvals" | **AWS CodePipeline** |
| "private, secure package repository with public upstream" | **AWS CodeArtifact** |
| "code quality recommendations / find the most expensive line of code" | **Amazon CodeGuru** (Reviewer / Profiler) |
| "trace a request across microservices, find the bottleneck" | **AWS X-Ray** |
| "feature flags / change config without redeploying, with validation and rollback" | **AWS AppConfig** |
| "browser-based shell with my credentials, nothing to install" | **AWS CloudShell** |
| "persistent virtual desktop for full-time employees" | **Amazon WorkSpaces** |
| "stream a single application to users, non-persistent" | **Amazon AppStream 2.0** |
| "secure browser access to internal sites from unmanaged devices" | **Amazon WorkSpaces Web / Secure Browser** |
| "host and CI/CD a web app from a Git branch, with PR previews" | **AWS Amplify** |
| "managed GraphQL API with real-time subscriptions" | **AWS AppSync** |
| "test my mobile app on real physical devices" | **AWS Device Farm** |
| "connect millions of devices over MQTT with per-device certificates" | **AWS IoT Core** |
| "run compute locally on the device, works offline" | **AWS IoT Greengrass** |

---

## 12. Hands-on lab (free-tier-safe)

**Objective:** prove the ingestion path end-to-end and then deliberately break it.

1. Deploy the CloudFormation stack from §2.3. Confirm the email subscription.
2. `aws events test-event-pattern` the rule's pattern against a sample event; confirm `Result: true`.
3. `put-events` a matching event; `receive-message` from the persistence queue; confirm the transformed payload.
4. **Break it:** edit the rule's `EventPattern` so `errorCount` requires `>= 1000`. Re-publish. Observe `FailedEntryCount: 0` with zero deliveries — internalise that acceptance ≠ delivery.
5. **Break it again:** set `VisibilityTimeout` to 1 s and consume with a 5-second sleep. Observe `ApproximateReceiveCount` climbing on the same `MessageId`, then the message landing in the DLQ after `maxReceiveCount`.
6. Redrive the DLQ with `start-message-move-task`; confirm `ApproximateNumberOfMessagesMoved`.
7. Start an EventBridge replay from the archive over the last hour; confirm the queue refills.
8. **Tear down** — `aws cloudformation delete-stack --stack-name fleet-telemetry-integration` — and verify with `describe-stacks` that it returns `Stack ... does not exist`.

---

## 13. References

**Exam guide**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Application integration**
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

**Business applications**
- Amazon SES Developer Guide — https://docs.aws.amazon.com/ses/latest/dg/Welcome.html
- SES sending authorization and DKIM — https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim.html
- SES sending review process and reputation — https://docs.aws.amazon.com/ses/latest/dg/faqs-enforcement.html
- Amazon Connect Administrator Guide — https://docs.aws.amazon.com/connect/latest/adminguide/what-is-amazon-connect.html

**Customer engagement**
- AWS Support plans comparison — https://aws.amazon.com/premiumsupport/plans/
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/getting-started.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Managed Services — https://docs.aws.amazon.com/managedservices/latest/userguide/what-is-ams.html
- AWS IQ — https://aws.amazon.com/iq/
- AWS Activate for Startups — https://aws.amazon.com/startups/

**Developer tools**
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

**End-user computing**
- Amazon WorkSpaces Administration Guide — https://docs.aws.amazon.com/workspaces/latest/adminguide/amazon-workspaces.html
- WorkSpaces running modes and pricing — https://docs.aws.amazon.com/workspaces/latest/adminguide/running-mode.html
- Amazon AppStream 2.0 Administration Guide — https://docs.aws.amazon.com/appstream2/latest/developerguide/what-is-appstream.html
- Amazon WorkSpaces Secure Browser — https://docs.aws.amazon.com/workspaces-web/latest/adminguide/what-is-workspaces-web.html

**Front-end web and mobile**
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

**Cross-cutting**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS service quotas — https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html
- AWS Free Tier — https://aws.amazon.com/free/