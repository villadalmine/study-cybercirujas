# Topic 3.8 — Guided Exercises
## Identify services from other in-scope AWS service categories
**Certification:** AWS Certified Cloud Practitioner (CLF-C02, exam guide v1.0) · **Domain 3:** Cloud Technology and Services · **Task 3.8 weight:** 4.25% of the exam

---

## What this task statement actually covers

Task 3.8 is the "everything else in scope" statement. The exam guide enumerates seven categories under it:

| Category | In-scope services you must recognise |
|---|---|
| Application integration | Amazon EventBridge, Amazon SNS, Amazon SQS |
| Business application services | Amazon Connect, Amazon SES |
| Customer engagement services | AWS Activate for Startups, AWS IQ, AWS Managed Services (AMS), AWS Support |
| Developer tools | AWS AppConfig, AWS CLI, AWS Cloud9, AWS CodeArtifact, AWS CodeBuild, AWS CodeCommit, AWS CodeDeploy, Amazon CodeGuru, AWS CodePipeline, AWS CodeStar, AWS X-Ray, AWS SDKs and tools |
| End-user computing | Amazon AppStream 2.0, Amazon WorkSpaces, Amazon WorkSpaces Web |
| Frontend web and mobile | AWS Amplify, Amazon API Gateway, AWS Device Farm, Amazon Pinpoint |
| IoT | AWS IoT Core, AWS IoT Greengrass |

The exam tests **identification and appropriate use**, not implementation. These exercises still make you *build* the integration primitives, because the fastest way to stop confusing SQS with SNS with EventBridge is to watch a message fail to arrive and fix it.

> **Instructor note on the frozen service list.** AWS closed **AWS CodeCommit**, **AWS Cloud9** and **AWS CodeStar** to new customers in July 2024 (CodeStar reached end of life on 2024-07-31); existing customers retain access. **Amazon WorkSpaces Web** has been renamed **Amazon WorkSpaces Secure Browser**. The CLF-C02 v1.0 exam guide still lists the old names, so you must recognise both the legacy name and what it did. Do not plan new production work on the closed services.

---

## Before you start

**Prerequisites**

- An AWS account you are authorised to use, with an IAM principal that can create SNS/SQS/EventBridge/IoT/SES resources.
- AWS CLI **v2** installed and configured (`aws --version` → `aws-cli/2.x.x`).
- `jq` installed. Several AWS APIs take *stringified JSON inside a JSON field*; `jq` is the only sane way to build that.
- Region pinned for every command in this document: **`us-east-1`**.

**Cost discipline**

| Exercise | Cost |
|---|---|
| 1, 2 (SNS, SQS, EventBridge) | Effectively free — well inside the perpetual free tier at this volume |
| 3 (AppConfig, read-only dev tool calls) | Free at this volume |
| 4 (EUC / frontend — `describe` calls only) | **Free, because you only describe.** Launching a WorkSpace, an AppStream fleet, or an Amazon Connect instance **bills immediately.** Do not launch them. |
| 5 (IoT Core) | Free tier covers this message volume |
| 6 (SES identity + Support API probe) | Free; sending is free tier up to 3,000 message-charges/month |

Set your working variables once:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCT=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCT"
```

Expected:

```
Account: 111122223333
```

Every ARN printed below uses `111122223333` as the placeholder account ID. Yours will differ.

---

# Exercise 1 — Application integration: SNS fan-out into SQS, with a dead-letter queue

**Scenario.** An order service publishes `OrderCreated`. Two independent teams — billing and analytics — must each receive *every* order, and neither may block the other. This is the canonical **fan-out** pattern: one SNS topic, N SQS queues.

### Steps

1. **Create the SNS topic.**

    ```bash
    export TOPIC_ARN=$(aws sns create-topic --name orders-events \
      --query TopicArn --output text)
    echo $TOPIC_ARN
    ```

    Expected:

    ```
    arn:aws:sns:us-east-1:111122223333:orders-events
    ```

2. **Create the two consumer queues and one shared dead-letter queue.**

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

    Expected:

    ```
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-billing
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-analytics
    https://sqs.us-east-1.amazonaws.com/111122223333/orders-dlq
    ```

3. **Resolve the queue ARNs.** The queue *URL* is the data-plane address; the *ARN* is what IAM and SNS reference. They are not interchangeable.

    ```bash
    for q in BILLING ANALYTICS DLQ; do
      url_var="${q}_URL"
      arn=$(aws sqs get-queue-attributes --queue-url "${!url_var}" \
        --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
      export "${q}_ARN=$arn"
      echo "$q -> $arn"
    done
    ```

    Expected:

    ```
    BILLING -> arn:aws:sqs:us-east-1:111122223333:orders-billing
    ANALYTICS -> arn:aws:sqs:us-east-1:111122223333:orders-analytics
    DLQ -> arn:aws:sqs:us-east-1:111122223333:orders-dlq
    ```

4. **Subscribe both queues to the topic**, with raw message delivery on so the consumer receives your JSON, not an SNS envelope wrapping it.

    ```bash
    for arn in "$BILLING_ARN" "$ANALYTICS_ARN"; do
      aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
        --notification-endpoint "$arn" \
        --attributes RawMessageDelivery=true \
        --query SubscriptionArn --output text
    done
    ```

    Expected (UUID suffix will differ):

    ```
    arn:aws:sns:us-east-1:111122223333:orders-events:9f2e1c04-7f2b-4b62-9a71-d1a3c05d5b60
    arn:aws:sns:us-east-1:111122223333:orders-events:2c8a6d13-0f45-4a8e-9c33-88b7d2e91f07
    ```

5. **Publish a test message and try to read it. This step is designed to fail.**

    ```bash
    aws sns publish --topic-arn "$TOPIC_ARN" \
      --message '{"orderId":"A-1001","amount":249.90,"currency":"USD"}' \
      --query MessageId --output text

    sleep 5
    aws sqs receive-message --queue-url "$BILLING_URL" --wait-time-seconds 10
    ```

    Expected:

    ```
    5f01e6b6-9f7c-5a51-9a26-2b6dfb1d1e8f
    ```

    …and then **nothing at all** from `receive-message`. Empty output, exit code 0.

> **Checkpoint 1A**
>
> **Q1.1** `sns publish` returned a MessageId and the subscription exists, yet the queue is empty. What is the missing piece, and why does subscribing not create it?
> **Q1.2** Which of the two identifiers — queue URL or queue ARN — did SNS need in step 4, and which one does your application code use to poll?
> **Q1.3** What does `RawMessageDelivery=true` change about the body the consumer sees?

6. **Write the SQS resource-based policy** that lets the SNS service principal deliver into the queue. Save as `sqs-policy.json`:

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

    The `aws:SourceArn` condition is not optional in production: without it, *any* SNS topic in *any* account could write into your queue (the classic confused-deputy exposure).

7. **Apply the policy.** The `Policy` queue attribute takes a **JSON document encoded as a string**, not a nested object. Build it with `jq` rather than by hand:

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

    Expected:

    ```
    policy applied: BILLING
    policy applied: ANALYTICS
    ```

8. **Attach the dead-letter queue** to `orders-billing` with a redrive policy — also a stringified JSON attribute.

    ```bash
    jq -n --arg arn "$DLQ_ARN" \
      '{RedrivePolicy: ({deadLetterTargetArn: $arn, maxReceiveCount: "3"} | tostring)}' \
      > /tmp/redrive.json
    aws sqs set-queue-attributes --queue-url "$BILLING_URL" --attributes file:///tmp/redrive.json

    aws sqs get-queue-attributes --queue-url "$BILLING_URL" \
      --attribute-names RedrivePolicy VisibilityTimeout --output json
    ```

    Expected:

    ```json
    {
        "Attributes": {
            "VisibilityTimeout": "60",
            "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:111122223333:orders-dlq\",\"maxReceiveCount\":\"3\"}"
        }
    }
    ```

9. **Republish and confirm true fan-out.**

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

    Expected:

    ```
    --- orders-billing
    {"orderId":"A-1002","amount":80.00,"currency":"USD"}
    --- orders-analytics
    {"orderId":"A-1002","amount":80.00,"currency":"USD"}
    ```

    One publish, two independent copies. Neither consumer can starve the other.

10. **Force a poison-pill message into the DLQ.** Receive without deleting, four times, letting the visibility timeout lapse each round.

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

    Expected (abridged):

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

11. **Read the operational signals** an SRE actually alarms on.

    ```bash
    aws sqs get-queue-attributes --queue-url "$BILLING_URL" \
      --attribute-names ApproximateNumberOfMessages \
                        ApproximateNumberOfMessagesNotVisible \
                        ApproximateNumberOfMessagesDelayed --output json
    ```

    Expected:

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
> **Q1.4** A message reached the DLQ after `maxReceiveCount` deliveries. What did the consumer fail to do that a healthy consumer does, and which SQS API call is it?
> **Q1.5** `ApproximateNumberOfMessagesNotVisible` is high and flat while `ApproximateNumberOfMessages` never drops. Name two distinct root causes.
> **Q1.6** Billing must process orders strictly in the sequence they were placed, per customer, and must never double-charge. Which queue type do you choose, what field enforces the per-customer ordering, and what is the throughput cost of that choice?
> **Q1.7** An order payload is 900 KB. Can SQS carry it? What is the standard pattern?
> **Q1.8** In one sentence each, state when you reach for **SQS** versus **SNS**.

---

# Exercise 2 — Application integration: EventBridge routing and content-based filtering

**Scenario.** Same order stream, but now routing must be decided by *content* — only high-value orders in EUR go to a fraud-review queue — and the producer must not know who the consumers are.

### Steps

1. **Create a custom event bus.** The default bus carries AWS service events; application events belong on their own bus.

    ```bash
    aws events create-event-bus --name acme-orders --query EventBusArn --output text
    ```

    Expected:

    ```
    arn:aws:events:us-east-1:111122223333:event-bus/acme-orders
    ```

2. **Create the target queue.**

    ```bash
    export FRAUD_URL=$(aws sqs create-queue --queue-name orders-fraud-review \
      --query QueueUrl --output text)
    export FRAUD_ARN=$(aws sqs get-queue-attributes --queue-url "$FRAUD_URL" \
      --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
    echo $FRAUD_ARN
    ```

    Expected:

    ```
    arn:aws:sqs:us-east-1:111122223333:orders-fraud-review
    ```

3. **Create a rule with a content-based event pattern.** Note the numeric matcher — this is what makes EventBridge a *router* rather than a topic.

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

    Expected:

    ```
    arn:aws:events:us-east-1:111122223333:rule/acme-orders/high-value-eur-orders
    ```

4. **Authorise EventBridge on the queue**, scoped to that exact rule ARN.

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

5. **Attach the target.**

    ```bash
    aws events put-targets --rule high-value-eur-orders --event-bus-name acme-orders \
      --targets "Id=fraud-queue,Arn=$FRAUD_ARN"
    ```

    Expected:

    ```json
    {
        "FailedEntryCount": 0,
        "FailedEntries": []
    }
    ```

6. **Publish three events: one match, two deliberate non-matches.**

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

    Expected:

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

7. **Verify only the matching event was routed.**

    ```bash
    aws sqs receive-message --queue-url "$FRAUD_URL" --wait-time-seconds 10 \
      --max-number-of-messages 10 --query 'Messages[].Body' --output text | jq -r '.detail.orderId'
    ```

    Expected:

    ```
    E-1
    ```

> **Checkpoint 2A**
>
> **Q2.1** All three events returned `FailedEntryCount: 0`, but only one was delivered. What does `FailedEntryCount: 0` actually guarantee — and what does it explicitly *not* guarantee?
> **Q2.2** Event `E-2` has `"amount": 50`. If the producer had sent `"amount": "50"` (a string) for an order of €5,000, would the `{"numeric": [">=", 1000]}` pattern match? Why does this matter operationally?
> **Q2.3** You need to prove whether a rule ever matched anything. Which CloudWatch metrics do you inspect, and what does each tell you?

8. **Diagnose from metrics, not from guesswork.**

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

    Expected (roughly; metrics lag a few minutes):

    ```
    --- MatchedEvents
    1.0
    --- Invocations
    1.0
    --- FailedInvocations
    
    ```

9. **Contrast with EventBridge Scheduler**, which is a different service from rate/cron *rules* and is the right answer for scheduled invocation at scale.

    ```bash
    aws scheduler list-schedules --query 'Schedules[].{Name:Name,State:State}' --output table
    ```

    Expected on a fresh account:

    ```
    -------------------
    |  ListSchedules  |
    -------------------
    ```

> **Checkpoint 2B**
>
> **Q2.4** `MatchedEvents` is 5 and `Invocations` is 0. Where is the fault? Now the reverse: `Invocations` is 5 and `FailedInvocations` is 5. Where is the fault?
> **Q2.5** Three requirements, three services. Match each to exactly one of SQS / SNS / EventBridge, and justify: (a) buffer a burst of 200,000 image-processing jobs so workers drain them at their own pace; (b) notify five unrelated subsystems plus an ops email whenever a deployment finishes; (c) run a different Lambda depending on whether an EC2 instance changed to `stopped` or `terminated`, with no producer changes.
> **Q2.6** An auditor asks you to replay every order event from last Tuesday into a new consumer. Which EventBridge feature makes that possible, and why can SNS not do it?

---

# Exercise 3 — Developer tools: AppConfig, build/deploy specifications, and X-Ray

**Scenario.** You are shipping a feature flag to a checkout service without a redeploy, and you need to be able to explain the CI/CD toolchain a Cloud Practitioner is expected to identify.

### Steps

1. **Create an AppConfig application, environment and feature-flag profile.**

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

    Expected (IDs are 7-character opaque strings):

    ```
    app=abc1234 env=def5678 profile=ghi9012
    ```

2. **Author the flag document and store it as a hosted configuration version.**

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

    Expected:

    ```json
    {
        "ApplicationId": "abc1234",
        "ConfigurationProfileId": "ghi9012",
        "VersionNumber": 1,
        "ContentType": "application/json"
    }
    ```

3. **Deploy the flag using a predefined canary strategy.**

    ```bash
    aws appconfig list-deployment-strategies \
      --query 'Items[?starts_with(Name, `AppConfig.`)].{Name:Name,Id:Id,Growth:GrowthType}' \
      --output table

    aws appconfig start-deployment --application-id "$APP_ID" \
      --environment-id "$ENV_ID" --deployment-strategy-id "AppConfig.Canary10Percent20Minutes" \
      --configuration-profile-id "$PROF_ID" --configuration-version 1 \
      --query '{Number:DeploymentNumber,State:State,PercentComplete:PercentageComplete}'
    ```

    Expected:

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

4. **Read the configuration back the way an application would** — via the `appconfigdata` data-plane API, which is session-based and returns a rotating token.

    ```bash
    TOKEN=$(aws appconfigdata start-configuration-session \
      --application-identifier "$APP_ID" \
      --environment-identifier "$ENV_ID" \
      --configuration-profile-identifier "$PROF_ID" \
      --query InitialConfigurationToken --output text)

    aws appconfigdata get-latest-configuration --configuration-token "$TOKEN" \
      /dev/stdout --query NextPollConfigurationToken --output text >/dev/null
    ```

    Expected (the flag document, printed to stdout):

    ```json
    {"express_checkout":{"enabled":true,"rollout_percentage":25}}
    ```

> **Checkpoint 3A**
>
> **Q3.1** What did AppConfig let you change that would otherwise have required a code deployment? Name the specific operational risk the canary strategy is mitigating.
> **Q3.2** AppConfig has a separate data-plane endpoint (`appconfigdata`) from its control plane (`appconfig`). Why would AWS split them?

5. **Read a complete CodeBuild build specification.** Save as `buildspec.yml` in a repository root — this is the file CodeBuild looks for by default.

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

6. **Read a complete CodeDeploy application specification** for a blue/green ECS deployment. Save as `appspec.yaml`.

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

7. **Inspect X-Ray sampling**, the control that decides how much tracing you pay for.

    ```bash
    aws xray get-sampling-rules \
      --query 'SamplingRuleRecords[].SamplingRule.{Name:RuleName,Rate:FixedRate,Reservoir:ReservoirSize,Priority:Priority}' \
      --output table
    ```

    Expected on a fresh account:

    ```
    ------------------------------------------------------
    |                  GetSamplingRules                  |
    +----------+--------+-----------+--------------------+
    |   Name   |  Rate  | Reservoir |     Priority       |
    +----------+--------+-----------+--------------------+
    |  Default |  0.05  |    1      |      10000         |
    +----------+--------+-----------+--------------------+
    ```

8. **Query the service graph** (empty unless you have an instrumented app, which is the expected result here).

    ```bash
    aws xray get-service-graph \
      --start-time "$(date -u -d '1 hour ago' +%s)" \
      --end-time "$(date -u +%s)" \
      --query 'Services[].{Name:Name,Type:Type}' --output table
    ```

> **Checkpoint 3B**
>
> **Q3.3** Match each developer-tool service to its one-line job: CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline, CodeGuru, X-Ray, Cloud9, CodeStar, AWS CLI, AWS SDKs.
> **Q3.4** The default X-Ray sampling rule reads "reservoir 1, rate 0.05". Translate that into plain English about how many requests get traced, and explain why AWS did not default to 100%.
> **Q3.5** A checkout request takes 4 seconds. CloudWatch shows the API Gateway latency is high but every downstream Lambda's `Duration` metric looks normal. Which service finds the culprit, and what is it that this service shows you that per-service metrics cannot?
> **Q3.6** Which two of the services in Q3.3 should you *not* select for a greenfield 2026 project, and what is the practical replacement for each?

---

# Exercise 4 — End-user computing and frontend/mobile services

**Scenario.** Three requests land in your inbox on the same morning. You must route each to the right service — and you must do it without launching anything billable.

### Steps

1. **Enumerate WorkSpaces bundles** (read-only, free — this does *not* create a desktop).

    ```bash
    aws workspaces describe-workspace-bundles --owner AMAZON \
      --query 'Bundles[?ComputeType.Name==`STANDARD`].{Id:BundleId,Name:Name,Compute:ComputeType.Name,RootGB:RootStorage.Capacity,UserGB:UserStorage.Capacity}' \
      --output table | head -15
    ```

    Expected (abridged; bundle IDs differ per Region):

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

2. **Confirm you have no running desktops** (this is the guard rail against surprise billing).

    ```bash
    aws workspaces describe-workspaces --query 'length(Workspaces)' --output text
    aws appstream describe-fleets --query 'length(Fleets)' --output text
    ```

    Expected:

    ```
    0
    0
    ```

3. **Confirm the Secure Browser (WorkSpaces Web) surface is empty.**

    ```bash
    aws workspaces-web list-portals --query 'portals[].{Arn:portalArn,Status:portalStatus}' --output table
    ```

    Expected:

    ```
    ---------------
    | ListPortals |
    ---------------
    ```

> **Checkpoint 4A**
>
> **Q4.1** Route each request to exactly one of **Amazon WorkSpaces**, **Amazon AppStream 2.0**, or **Amazon WorkSpaces Web / Secure Browser**, and state the deciding characteristic:
> (a) 400 contractors need read-only access to three internal web dashboards from their own unmanaged laptops, with nothing persisted on the endpoint.
> (b) 30 engineers need a persistent Windows desktop with their installed tools and files, available every morning exactly as they left it.
> (c) A university needs to stream one CAD application to 2,000 students during a 3-hour lab session, after which nothing is retained.
> **Q4.2** Which of the three bills you for a *persistent* resource even when the user is not logged in, and how do you control that cost?

4. **Create a minimal HTTP API in API Gateway** (free tier; no backend attached yet).

    ```bash
    export API_ID=$(aws apigatewayv2 create-api --name checkout-public \
      --protocol-type HTTP --query ApiId --output text)
    aws apigatewayv2 get-api --api-id "$API_ID" \
      --query '{Id:ApiId,Endpoint:ApiEndpoint,Protocol:ProtocolType}'
    ```

    Expected:

    ```json
    {
        "Id": "a1b2c3d4e5",
        "Endpoint": "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com",
        "Protocol": "HTTP"
    }
    ```

5. **Enumerate Device Farm resources.** Note the Region — the device fleet lives in `us-west-2`.

    ```bash
    aws devicefarm list-device-pools --arn "arn:aws:devicefarm:us-west-2::devicepool:public" \
      --region us-west-2 --query 'devicePools[].{Name:name,Type:type}' --output table 2>&1 | head -8
    ```

    Expected (either the public pool list, or an argument error if you have no project — both are informative):

    ```
    ---------------------------------------
    |           ListDevicePools           |
    +------------------------+------------+
    |  Top Devices           |  CURATED   |
    |  Android High Tier ... |  CURATED   |
    +------------------------+------------+
    ```

6. **Confirm Amplify and Pinpoint are reachable and empty.**

    ```bash
    aws amplify list-apps --query 'apps[].{Name:name,Platform:platform}' --output table
    aws pinpoint get-apps --query 'ApplicationsResponse.Item[].Name' --output text
    ```

> **Checkpoint 4B**
>
> **Q4.3** Match to Amplify / API Gateway / Device Farm / Pinpoint: (a) verify a checkout flow renders correctly on a physical Samsung Galaxy running Android 14; (b) host a React single-page app with Git-triggered builds and preview environments per pull request; (c) publish a versioned, throttled, authenticated REST front door for a set of Lambda functions; (d) send a segmented push-and-SMS re-engagement campaign to users who abandoned a cart.
> **Q4.4** Both Amazon Pinpoint and Amazon SES can send email. What is the actual dividing line between them?
> **Q4.5** API Gateway offers usage plans with API keys. Is that an authentication mechanism? Justify your answer.

---

# Exercise 5 — IoT services: AWS IoT Core and AWS IoT Greengrass

**Scenario.** A fleet of temperature sensors publishes telemetry over MQTT. Readings above 80 °C must be routed to an SQS queue for the on-call team. Devices at remote sites lose connectivity for hours at a time.

### Steps

1. **Register a thing and mint its X.509 identity.**

    ```bash
    aws iot create-thing --thing-name edge-sensor-01 \
      --query '{Name:thingName,Arn:thingArn}'

    aws iot create-keys-and-certificate --set-as-active \
      --certificate-pem-outfile /tmp/device.pem.crt \
      --public-key-outfile /tmp/public.pem.key \
      --private-key-outfile /tmp/private.pem.key \
      --query '{CertArn:certificateArn,CertId:certificateId}'
    ```

    Expected:

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

    Capture the ARN:

    ```bash
    export CERT_ARN=$(aws iot list-certificates --query 'certificates[0].certificateArn' --output text)
    ```

2. **Write a least-privilege IoT policy** using thing-scoped policy variables, so one policy safely serves the whole fleet. Save as `iot-policy.json`:

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

3. **Create and attach the policy, then bind the certificate to the thing.**

    ```bash
    sed -i "s/111122223333/$ACCT/g" iot-policy.json
    aws iot create-policy --policy-name edge-sensor-policy \
      --policy-document file://iot-policy.json --query policyArn --output text

    aws iot attach-policy --policy-name edge-sensor-policy --target "$CERT_ARN"
    aws iot attach-thing-principal --thing-name edge-sensor-01 --principal "$CERT_ARN"

    aws iot list-thing-principals --thing-name edge-sensor-01 --output text
    ```

    Expected:

    ```
    arn:aws:iot:us-east-1:111122223333:policy/edge-sensor-policy
    PRINCIPALS	arn:aws:iot:us-east-1:111122223333:cert/6f8c0a1e...
    ```

4. **Discover the account's data endpoint.** Always request the ATS variant.

    ```bash
    aws iot describe-endpoint --endpoint-type iot:Data-ATS
    aws iot describe-endpoint --endpoint-type iot:CredentialProvider
    ```

    Expected:

    ```json
    { "endpointAddress": "a3k7odshaiipe8-ats.iot.us-east-1.amazonaws.com" }
    { "endpointAddress": "c2v9ex4mple.credentials.iot.us-east-1.amazonaws.com" }
    ```

5. **Create the SQS target and an IAM role the rules engine can assume.**

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

    Expected:

    ```
    arn:aws:iam::111122223333:role/IoTRuleToSQS
    ```

6. **Create a topic rule with a SQL statement** — the rules engine filters and reshapes at ingest, before anything is billed downstream.

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

    Expected:

    ```
    SELECT temperature, topic(2) AS deviceId, timestamp() AS ts FROM 'sensors/+/telemetry' WHERE temperature > 80
    ```

7. **Publish two readings through the HTTPS data plane** (one below threshold, one above) and confirm only the hot one is routed.

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

    Expected:

    ```
    {"temperature":93.7,"deviceId":"edge-sensor-01","ts":1788547201234}
    ```

8. **Inspect the device shadow**, the mechanism that lets you address an offline device.

    ```bash
    aws iot-data update-thing-shadow --thing-name edge-sensor-01 \
      --cli-binary-format raw-in-base64-out \
      --payload '{"state":{"desired":{"sampling_interval_s":30}}}' /dev/stdout | jq .

    aws iot-data get-thing-shadow --thing-name edge-sensor-01 /dev/stdout | jq '.state'
    ```

    Expected:

    ```json
    {
      "desired": { "sampling_interval_s": 30 }
    }
    ```

9. **Check for any Greengrass core devices** (there will be none — Greengrass runs on hardware you own).

    ```bash
    aws greengrassv2 list-core-devices --query 'coreDevices[].{Name:coreDeviceThingName,Status:status}' --output table
    aws greengrassv2 list-components --scope AWS_TYPES \
      --query 'components[].componentName' --output text | tr '\t' '\n' | head -8
    ```

    Expected:

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
> **Q5.1** The IoT policy uses `${iot:Connection.Thing.ThingName}` instead of a hard-coded name. What does that buy you when the fleet grows to 50,000 devices, and what is the security property it enforces?
> **Q5.2** A device connects successfully but every `publish` is silently dropped, with no error surfaced to the device. Where do you look, and what is the most likely cause?
> **Q5.3** The topic rule filters `WHERE temperature > 80` at ingest instead of forwarding everything and filtering in a Lambda. State the two distinct benefits.
> **Q5.4** A remote pumping station loses its uplink for six hours daily. Local sensors must still trigger a local shutdown within 200 ms, and the buffered readings must sync when the link returns. Which service, and which three of its capabilities are you relying on?
> **Q5.5** In one line each: what is **AWS IoT Core** and what is **AWS IoT Greengrass**? Where does each one physically run?
> **Q5.6** Why does `describe-endpoint` require `--endpoint-type iot:Data-ATS`? What breaks if you use the legacy Verisign endpoint?

---

# Exercise 6 — Business applications and customer engagement

**Scenario.** You are standing up transactional email for the platform, and separately deciding which AWS Support plan the company needs.

### Steps

1. **Check the SES account posture first** — every new account is sandboxed, and this is the single most common SES support case.

    ```bash
    aws sesv2 get-account --query '{Production:ProductionAccessEnabled,Enforcement:EnforcementStatus,Quota:SendQuota}'
    ```

    Expected on an unreviewed account:

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

2. **Create and verify an email identity.** Use an address you control.

    ```bash
    aws sesv2 create-email-identity --email-identity "you@example.com" \
      --query '{Type:IdentityType,Verified:VerifiedForSendingStatus}'
    ```

    Expected:

    ```json
    { "Type": "EMAIL_ADDRESS", "Verified": false }
    ```

    AWS sends a confirmation link to that address. Click it, then:

    ```bash
    aws sesv2 get-email-identity --email-identity "you@example.com" \
      --query '{Verified:VerifiedForSendingStatus,DkimStatus:DkimAttributes.Status}'
    ```

    Expected after confirming:

    ```json
    { "Verified": true, "DkimStatus": "NOT_STARTED" }
    ```

3. **Contrast with a domain identity**, which is what production actually uses because it enables DKIM signing and lets you send from any address at the domain.

    ```bash
    aws sesv2 create-email-identity --email-identity "example.com" \
      --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT \
      --query 'DkimAttributes.Tokens' --output text
    ```

    Expected (three CNAME tokens you publish in DNS):

    ```
    7v3zqk4x2mhbn5r6t8y9uabcdefghijk  q2w3e4r5t6y7u8i9o0pasdfghjklzxcvb  m1n2b3v4c5x6z7l8k9j0hgfdsapoiuytr
    ```

4. **Create a configuration set wired to an event destination**, so bounces and complaints are machine-processable instead of discovered by a reputation drop.

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

    Expected:

    ```json
    {
        "Name": "transactional",
        "Suppression": { "SuppressedReasons": ["BOUNCE", "COMPLAINT"] }
    }
    ```

5. **Inspect the account-level suppression list.**

    ```bash
    aws sesv2 list-suppressed-destinations --query 'SuppressedDestinationSummaries[].{Email:EmailAddress,Reason:Reason}' --output table
    ```

> **Checkpoint 6A**
>
> **Q6.1** Your `get-account` output says `"ProductionAccessEnabled": false`. A colleague reports the app "can send to the team but not to customers." Explain precisely what is happening and what the two sandbox restrictions are.
> **Q6.2** Why is a *domain* identity with DKIM the production choice over a verified email address? Name what DKIM proves.
> **Q6.3** SES automatically suppresses hard bounces and complaints. What business risk is that protecting, and who ultimately bears the cost if you ignore it?
> **Q6.4** In one line each, distinguish **Amazon SES** from **Amazon Connect**. Which one is a contact centre, and what is its pricing model?

6. **Probe the AWS Support API.** This call is itself a diagnostic of your support plan.

    ```bash
    aws support describe-severity-levels --language en --region us-east-1
    ```

    On **Basic** or **Developer**, expected:

    ```
    An error occurred (SubscriptionRequiredException) when calling the DescribeSeverityLevels operation: AWS Premium Support Subscription is required to use this service.
    ```

    On **Business** or higher, expected:

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

7. **If — and only if — the previous call succeeded**, list Trusted Advisor checks:

    ```bash
    aws support describe-trusted-advisor-checks --language en --region us-east-1 \
      --query 'length(checks)' --output text
    ```

    Expected on Business+:

    ```
    115
    ```

> **Checkpoint 6B**
>
> **Q6.5** The Support API returned `SubscriptionRequiredException`. What does that single error tell you about the account, and why is `--region us-east-1` hard-coded in both commands?
> **Q6.6** Order the five support plans from least to most capable, and give the response-time commitment that first appears at each of the top three.
> **Q6.7** Which plan tier first grants (a) 24/7 phone and chat access to engineers, (b) the *full* set of Trusted Advisor checks plus programmatic access, (c) a designated Technical Account Manager?
> **Q6.8** Match to **AWS Managed Services (AMS)** / **AWS IQ** / **AWS Activate for Startups** / **AWS Support**: (a) an early-stage company wants promotional credits and technical resources; (b) a regulated enterprise wants AWS to run patching, backup, incident management and change control on its behalf; (c) a small team wants to hire a vetted, AWS-certified freelancer for a short engagement, billed through their AWS account; (d) an outage is in progress and you need to open a severity case.

---

# Exercise 7 — Capstone: category identification and triage

No new resources. This is the drill the exam actually measures.

### Steps

1. **Read each of the eight requirements below.** For each, write down (i) the exam-guide *category*, and (ii) the single best in-scope *service*.

    1. Decouple a monolith's checkout step so a downstream failure never loses an order and never blocks the web tier.
    2. Trigger a remediation function whenever any EC2 instance in the account transitions into `stopped`, with zero changes to the producer.
    3. Roll out a kill switch for a risky feature to 10% of traffic, without rebuilding or redeploying the container image.
    4. Give 2,000 seasonal call-centre agents a browser-based phone with call recording and analytics, billed per minute of usage.
    5. Give a designer a persistent Windows desktop with Adobe tooling, reachable from a tablet.
    6. Store the company's private npm packages so builds never depend on the public registry being reachable.
    7. Find which of eleven microservices is adding 3 seconds to a request, using a per-request end-to-end trace.
    8. Let a factory-floor gateway keep enforcing safety logic while the WAN link is down, then upload buffered data on reconnect.

2. **Now triage four failure reports.** For each, name the *most likely* root cause and the *first* command or metric you would check.

    1. An SNS subscription to an SQS queue is `Confirmed`, publishes return a MessageId, the queue never receives anything.
    2. `PutEvents` returns `FailedEntryCount: 0`, EventBridge `MatchedEvents` is 12, the target queue is empty.
    3. An IoT device shows as connected in the console, and no telemetry ever reaches the rule's target.
    4. SES `SendEmail` succeeds for internal addresses and returns `MessageRejected: Email address is not verified` for customers.

> **Checkpoint 7**
>
> **Q7.1** Give your eight category/service pairs from step 1.
> **Q7.2** Give your four root causes and first checks from step 2.
> **Q7.3** One sentence each, no hedging: when do you choose **SQS**, **SNS**, and **EventBridge**?
> **Q7.4** Which single service in task 3.8 is the one that customers see *externally* as your product's front door — and which is the one your *developers* see as the front door to AWS itself?

---

## Cleanup

Run this in full. Everything created above is either free or trivially cheap, but leaving IAM roles and IoT certificates behind is untidy and, in the IoT case, a live credential.

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

Queue deletion takes up to 60 seconds to propagate; a name cannot be reused for that period.

---

## Sources

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
<summary><strong>Answers</strong></summary>

### Exercise 1 — SNS fan-out into SQS

**Q1.1** The missing piece is the **SQS resource-based policy (queue access policy)** granting `sqs:SendMessage` to the `sns.amazonaws.com` service principal. Subscribing only registers the *intent* to deliver on the SNS side; it does not modify the queue's authorisation. SQS is the resource owner and evaluates its own policy on every `SendMessage`. Because SNS delivery failures are asynchronous, nothing surfaces in your `publish` call — the message ID you got back confirms only that SNS accepted the message. (Note: creating the subscription through the AWS console *does* offer to write the policy for you; the CLI does not, which is exactly why the gap is invisible in automation.)

**Q1.2** SNS needed the **queue ARN** — ARNs are the identity used across IAM, subscriptions, and cross-service references. Your consumer application polls the **queue URL**, which is the HTTPS data-plane endpoint passed to `ReceiveMessage`/`DeleteMessage`. Mixing them up is one of the most common SQS errors; the API rejects an ARN where a URL is expected.

**Q1.3** With raw message delivery **off** (the default), SNS wraps your payload in a JSON envelope containing `Type`, `MessageId`, `TopicArn`, `Message` (your payload as an escaped string), `Timestamp`, `SignatureVersion` and `Signature` — the consumer must parse twice. With `RawMessageDelivery=true`, the queue receives your payload byte-for-byte, and SNS message attributes become SQS message attributes. The trade-off: you lose the SNS metadata and signature, so if the consumer needs the topic ARN or wants to verify the signature, leave it off.

**Q1.4** The consumer never called **`DeleteMessage`**. SQS delivery is a lease, not a hand-off: `ReceiveMessage` makes the message invisible for the visibility timeout, and only an explicit `DeleteMessage` (using the receipt handle) removes it. If the consumer crashes, throws, or simply never deletes, the message reappears after the timeout, `ApproximateReceiveCount` increments, and once it exceeds `maxReceiveCount` the redrive policy moves it to the DLQ. That is the correct behaviour — the DLQ is quarantining a message that repeatedly fails to be processed.

**Q1.5** Two distinct causes, and they are diagnosed differently:
1. **Consumers are receiving but not deleting** (a code bug, an unhandled exception before the delete, or a crash loop). Messages cycle in and out of flight forever; `ApproximateReceiveCount` climbs and the DLQ fills.
2. **Processing takes longer than the visibility timeout.** The consumer is genuinely working, but the lease expires mid-work, the message is redelivered to a second consumer, and you get duplicate processing plus a queue that never drains. Fix by raising `VisibilityTimeout` above the p99 processing time, or by calling `ChangeMessageVisibility` to extend the lease as a heartbeat.

A third, rarer cause: `ApproximateNumberOfMessagesNotVisible` also counts messages in a DLQ redrive, and messages whose consumer holds the lease legitimately.

**Q1.6** Use a **FIFO queue** (`orders.fifo`). Ordering is enforced per **`MessageGroupId`** — set it to the customer ID, so each customer's orders are strictly ordered while different customers process in parallel. Exactly-once processing is provided by deduplication within a 5-minute window, keyed on `MessageDeduplicationId` (explicit) or a SHA-256 of the body (`ContentBasedDeduplication=true`). The cost: throughput is bounded — 300 transactions/second per API action without batching, 3,000/second with batching of 10 — versus a standard queue's effectively unlimited throughput. High-throughput mode for FIFO raises this substantially but the per-message-group serialisation remains. Also note the FIFO topic constraint: an SNS **FIFO topic can only deliver to SQS FIFO queues**.

**Q1.7** Not directly — the SQS maximum message size is **256 KB**. The standard pattern is the **claim-check**: store the 900 KB payload in **Amazon S3** and enqueue a small message containing the object key. The Amazon SQS Extended Client Library implements this transparently for payloads up to 2 GB.

**Q1.8** **SQS** when you need a durable buffer that decouples producer speed from consumer speed and each message must be processed by exactly one worker — work queues, load levelling, retry with a DLQ. **SNS** when one event must reach many independent subscribers immediately via push — fan-out, notifications, no persistence beyond the retry policy.

### Exercise 2 — EventBridge

**Q2.1** `FailedEntryCount: 0` guarantees only that **EventBridge accepted and durably ingested the event onto the bus**. It says nothing about whether any rule matched it, whether a target was invoked, or whether the target succeeded. This is the single most misread signal in EventBridge operations: successful ingestion and successful delivery are separate, independently observable outcomes.

**Q2.2** **No, it would not match.** EventBridge pattern matching is type-sensitive: the `numeric` matcher only applies to JSON numbers, and `"50"` is a string. Operationally this is severe — a schema drift in the producer (a serialiser that quotes numbers, a language whose big-decimal type stringifies) silently stops routing events with no error anywhere. `FailedEntryCount` stays 0, `MatchedEvents` quietly drops to 0, and nothing alarms unless you are watching `MatchedEvents` specifically. Guard it with an EventBridge **schema registry**, producer-side contract tests, and a CloudWatch alarm on `MatchedEvents` falling below an expected floor.

**Q2.3** In the `AWS/Events` namespace, dimensioned by `RuleName`:
- **`MatchedEvents`** — how many events the pattern matched. Zero means the pattern is wrong or the events are not arriving on that bus.
- **`Invocations`** (also `TriggeredRules`) — how many times a target was invoked.
- **`FailedInvocations`** — invocations EventBridge could not deliver even after retries; these are the ones bound for the target's dead-letter queue if you configured one.
- **`ThrottledRules`** and **`InvocationsSentToDlq`** round out the picture.

**Q2.4** `MatchedEvents` 5, `Invocations` 0 → the **rule matched but has no working target**: either no target is attached, or the rule is disabled after matching, or the target attachment itself failed. Check `aws events list-targets-by-rule`. `Invocations` 5, `FailedInvocations` 5 → the **target is refusing or failing**: almost always the missing or mis-scoped resource-based policy on the target (or, for a role-based target, an IAM role EventBridge cannot assume). Check the target's resource policy and the `aws:SourceArn` condition — a condition scoped to the wrong rule ARN fails exactly this way.

**Q2.5**
- (a) **SQS** — you need a durable buffer with backpressure; workers poll at their own rate and the queue absorbs the 200,000-job burst.
- (b) **SNS** — one publish, many push subscribers of heterogeneous protocols (Lambda, SQS, HTTPS, email) with no per-subscriber logic in the producer.
- (c) **EventBridge** — the events are AWS service events on the default bus (no producer to change), and the routing decision is content-based on the state field. This is precisely what SNS cannot do without subscriber-side filtering, and precisely what SQS cannot do at all.

**Q2.6** **EventBridge archives and replay.** An archive durably retains matched events for a configurable retention period, and `StartReplay` re-emits them to a chosen rule or bus over a specified time range. SNS cannot do this because SNS does not persist messages — it delivers with a retry policy and then drops. Message durability in an SNS architecture lives in the *subscribers* (typically SQS queues), not in the topic.

### Exercise 3 — Developer tools

**Q3.1** AppConfig let you change **runtime behaviour (a feature flag value)** without building an artifact, pushing an image, or restarting a process — configuration is externalised from code and fetched by the running application. The canary strategy (`AppConfig.Canary10Percent20Minutes`) mitigates the risk that the *configuration itself* is the outage: it exposes a small fraction of hosts first, bakes for a monitoring window, and — with CloudWatch alarms attached to the environment — **automatically rolls back** if an alarm fires. Bad config is one of the largest causes of production incidents precisely because it bypasses the deployment pipeline's safety net; AppConfig puts the net back.

**Q3.2** Because the two planes have opposite requirements. The **control plane** is low-volume, human/CI-driven, and creates state (`create-application`, `start-deployment`). The **data plane** is called by every running instance on every polling interval — high volume, latency-sensitive, and must stay available even when the control plane is degraded. Separating them lets AWS scale, throttle and isolate them independently; it is the same reason SQS has a control plane (`CreateQueue`) and a data plane (`SendMessage`), and why IoT Core has a distinct `iot:Data-ATS` endpoint.

**Q3.3**
- **AWS CodeCommit** — managed private Git repository hosting. *(Closed to new customers, July 2024.)*
- **AWS CodeArtifact** — managed artifact repository for package managers (npm, PyPI, Maven, NuGet); proxies and caches public registries.
- **AWS CodeBuild** — managed build/test compute; runs `buildspec.yml`, produces artifacts and test reports.
- **AWS CodeDeploy** — deployment orchestration onto EC2, on-premises, Lambda or ECS, with blue/green and canary strategies driven by `appspec.yaml`.
- **AWS CodePipeline** — the CI/CD orchestrator that chains source → build → test → deploy stages, invoking the services above.
- **Amazon CodeGuru** — ML-driven **code reviews** (CodeGuru Reviewer) and **runtime profiling** for CPU/latency hot spots (CodeGuru Profiler).
- **AWS X-Ray** — distributed tracing: end-to-end request traces and a service map across microservices.
- **AWS Cloud9** — browser-based cloud IDE. *(Closed to new customers, July 2024.)*
- **AWS CodeStar** — unified project templates wiring the above together. *(End of life 2024-07-31.)*
- **AWS CLI** — the command-line client for every AWS API, from a terminal or a script.
- **AWS SDKs** — language-native libraries (Python/boto3, JavaScript, Java, Go, .NET, Rust…) for calling AWS APIs from application code.

**Q3.4** "Reservoir 1, rate 0.05" means: **trace the first request each second unconditionally, then sample 5% of everything above that first request in that second.** The reservoir guarantees you always have *some* trace even on a near-idle service (where 5% of 2 requests would round to nothing); the percentage keeps cost bounded on a busy one. AWS does not default to 100% because tracing has three costs — per-trace storage charges, agent CPU and memory in your application, and network egress of segment documents — and because for statistical latency analysis a 5% sample is sufficient. When you need every trace (a low-volume, high-value flow like payment authorisation), create a higher-priority rule scoped to that service or URL path.

**Q3.5** **AWS X-Ray.** Per-service CloudWatch metrics show each component's *own* duration in isolation; they cannot show the time spent **between** components — connection establishment, DNS, queue wait, retries, cold starts, or a slow third-party HTTP call inside a segment. X-Ray stitches segments and subsegments from every hop into a single trace with a shared trace ID, so the 3-second gap appears as a visible span on the timeline attributable to a specific subsegment. The service map then shows it as an edge, not a node — which is exactly why per-service metrics looked "normal."

**Q3.6** **AWS Cloud9** and **AWS CodeStar** (and **AWS CodeCommit**, if you count three). Practical replacements: for Cloud9, a local IDE with the AWS Toolkit extension, or a browser IDE built on your own container; for CodeStar, wire CodePipeline/CodeBuild/CodeDeploy yourself via infrastructure-as-code (CloudFormation or CDK); for CodeCommit, GitHub, GitLab or Bitbucket — all of which CodePipeline supports as sources via CodeConnections. On the exam you still must recognise all three by name and function.

### Exercise 4 — End-user computing and frontend/mobile

**Q4.1**
- (a) **Amazon WorkSpaces Web / Secure Browser.** Deciding characteristic: the workload is *web only*, the sessions are *ephemeral*, and the endpoints are *unmanaged*. It streams a managed Chrome-based browser — no virtual desktop to provision, and nothing (cookies, downloads, history) survives the session on the endpoint.
- (b) **Amazon WorkSpaces.** Deciding characteristic: **persistence**. The user's applications, settings and files must survive logoff — that is a full Desktop-as-a-Service virtual desktop, not a streamed app.
- (c) **Amazon AppStream 2.0.** Deciding characteristic: **a single application, streamed at scale, non-persistent**. You publish the CAD app from an image, a fleet scales up for the lab, and nothing is retained afterwards (unless you explicitly enable home folders).

**Q4.2** **Amazon WorkSpaces**, because a WorkSpace is a provisioned, persistent virtual desktop that exists whether or not anyone is connected. You control the cost with the **billing mode**: *AlwaysOn* charges a flat monthly rate per WorkSpace (right for full-time users), while *AutoStop* charges a small fixed monthly fee for the storage plus an hourly rate only while the WorkSpace is running (right for part-time users), stopping it automatically after a configurable idle period. Choosing AlwaysOn for occasional users is the classic WorkSpaces overspend.

**Q4.3**
- (a) **AWS Device Farm** — testing on real, physical devices in the cloud, both automated test runs and interactive remote access.
- (b) **AWS Amplify** — hosting and CI/CD for frontend web apps, with Git-branch-based builds and pull-request preview environments.
- (c) **Amazon API Gateway** — the managed API front door: REST/HTTP/WebSocket APIs, stages and versions, throttling, authorisation, caching.
- (d) **Amazon Pinpoint** — multichannel outbound engagement: segments, campaigns and journeys across email, SMS, push and voice, with engagement analytics.

**Q4.4** **Amazon SES is the sending engine; Amazon Pinpoint is the marketing/engagement layer above it.** SES is a high-scale SMTP and API service for *transactional and bulk* email — receipts, password resets, notifications — where your application decides who gets what and when. Pinpoint owns the *audience*: user profiles, endpoints, segmentation, campaign scheduling, multi-step journeys, A/B tests and engagement analytics, and it spans SMS, push and voice as well as email. If the question is "how do I deliver this message," it is SES. If it is "who should receive this campaign, through which channel, and did it work," it is Pinpoint.

**Q4.5** **No — an API key in a usage plan is not authentication.** API keys identify a *caller for metering and throttling purposes* (request quotas, rate and burst limits per consumer), and they are transmitted by the client, so anyone who obtains one can present it. AWS documentation is explicit that API keys should not be used as the primary means of authorising access. Real authorisation on API Gateway comes from IAM (SigV4), a Lambda authorizer, a JWT authorizer, or an Amazon Cognito user pool authorizer — layered *with* the usage plan, not replaced by it.

### Exercise 5 — IoT

**Q5.1** The policy variable makes **one policy document serve the entire fleet**: at connection time IoT Core substitutes the connecting thing's name, so device 47,912 gets a policy scoped to its own client ID and its own topics without you authoring 50,000 documents or performing 50,000 policy attachments. The security property is **lateral-movement containment**: a device whose private key is extracted still cannot connect as another device (`iot:Connect` is scoped to `client/${...ThingName}`), cannot publish forged telemetry on a peer's topic, and cannot subscribe to a peer's command channel. Without the variable you either write per-device policies (unmanageable) or grant wildcard topic access (one compromised sensor owns the fleet).

**Q5.2** Look at **the IoT policy attached to the certificate** — an `iot:Publish` denial for the topic in question is by far the most likely cause. MQTT has no application-level error channel for an authorisation failure on QoS 0 publish, so the broker simply drops the message and the device sees nothing. Diagnose by enabling **AWS IoT logging to CloudWatch Logs** (`aws iot set-v2-logging-options --default-log-level DEBUG --role-arn ...`), which emits an explicit authorisation-failure event naming the topic and the policy evaluated. Common specific causes: the topic in the policy is `topic/sensors/...` but the device publishes to `sensors/.../telemetry` under a different thing name; or `topicfilter/` was used where `topic/` was required (they are distinct resource types — `topicfilter` for `Subscribe`, `topic` for `Publish` and `Receive`).

**Q5.3** Two benefits:
1. **Cost.** You are billed for AWS IoT Core messaging and rules-engine evaluation, but the *downstream* cost — Lambda invocations, SQS requests, storage — is incurred only for the ~0.1% of readings that are actually alerts. Forwarding 100% of telemetry into a Lambda to discard 99.9% of it multiplies the downstream bill by a thousand.
2. **Latency and blast radius.** Filtering happens in the managed rules engine at ingest, so an alert path has one fewer hop, and a bug or throttle in your Lambda cannot delay or drop alerts for readings it was never going to act on. It also keeps the alert queue's depth meaningful as an operational signal rather than a firehose.

**Q5.4** **AWS IoT Greengrass** (v2). The three capabilities you are relying on:
1. **Local compute and local message routing** — Greengrass components and the local publish/subscribe broker run the shutdown logic on the gateway itself, so the 200 ms decision never traverses the WAN.
2. **Offline operation with local device shadows** — devices keep interacting with a local shadow and the gateway keeps functioning with no cloud connectivity for the full six hours.
3. **Stream manager** — buffers telemetry to local disk with configurable retention and upload policies, then drains it to AWS IoT Core / Kinesis / S3 automatically when the link returns.

**Q5.5** **AWS IoT Core** is the managed cloud gateway for devices: it authenticates devices with X.509 certificates, brokers MQTT (and MQTT over WSS, HTTPS, LoRaWAN) at fleet scale, maintains device shadows, and routes messages to other AWS services through the rules engine. It **runs in the AWS Region**. **AWS IoT Greengrass** is an open-source edge runtime plus a cloud service for deploying and managing it: it **runs on your own hardware at the edge** (a gateway, an industrial PC, a vehicle) and brings local compute, local messaging, ML inference and offline buffering to devices that cannot depend on a constant cloud link.

**Q5.6** `iot:Data-ATS` returns the endpoint whose server certificate chains to an **Amazon Trust Services** root CA. The legacy endpoint chained to a Symantec/VeriSign root that browsers and OS trust stores have distrusted; devices whose trust store no longer contains that root fail the TLS handshake and cannot connect at all. ATS is the required choice for all new devices — the practical failure mode of getting this wrong is a fleet that provisions fine in the lab (where the old root is still cached) and cannot connect in the field.

### Exercise 6 — Business applications and customer engagement

**Q6.1** The account is in the **Amazon SES sandbox**, which every new account starts in. The two restrictions are:
1. **You may only send *to* verified identities.** Your teammates' addresses were verified during setup, so those sends succeed; an arbitrary customer address is unverified, so SES rejects the send with `MessageRejected: Email address is not verified`. (Sending *from* a verified identity is required in and out of the sandbox — the sandbox additionally constrains the recipient.)
2. **Hard quotas** — 200 messages per 24-hour period and a maximum send rate of 1 message per second.

The fix is to request production access (`aws sesv2 put-account-details` or the console's "Request production access"), describing your use case, your bounce/complaint handling, and how recipients opted in. AWS reviews it manually.

**Q6.2** A domain identity lets you send from **any address at the domain** (`noreply@`, `support@`, `billing@`) without verifying each one, and — critically — it is the only identity type that supports **DKIM signing**, because DKIM requires publishing public keys as DNS records under the domain you control. DKIM proves **that the message body and headers were not altered in transit and that the sending domain authorised the message**, via a cryptographic signature the receiver verifies against your published DNS key. Together with SPF (which authorises sending IPs) and a DMARC policy (which tells receivers what to do on failure), it is what keeps your mail out of spam folders and prevents third parties from spoofing your domain.

**Q6.3** It protects your **sender reputation**, which is the real asset. Mailbox providers track bounce and complaint rates per sending identity and per sending IP; sustained high rates get your mail throttled, foldered as spam, or blocked outright — and on shared SES IPs your behaviour degrades other tenants, which is why AWS enforces it rather than merely advising it. AWS will place an account **under review** and ultimately **pause sending** (`EnforcementStatus` moves from `HEALTHY` to `UNDER_REVIEW` to `SHUTDOWN`). The ultimate cost is borne by **your business**: password resets, receipts and security alerts stop reaching customers, and rebuilding a burned domain reputation takes weeks to months.

**Q6.4** **Amazon SES** is a bulk and transactional **email sending and receiving** service — an SMTP endpoint and API, priced per message. **Amazon Connect** is a fully managed, cloud-based **omnichannel contact centre** — inbound and outbound voice, chat, task routing, IVR flows built in a visual designer, agent workspace, and Contact Lens analytics. Connect is the contact centre, and its pricing model is **pay-per-use by the minute** of end-customer service usage (plus telephony charges), with no per-agent licences and no minimum commitment.

**Q6.5** `SubscriptionRequiredException` tells you the account is on **Basic or Developer support** — the AWS Support API (and therefore programmatic Trusted Advisor access) is available only on **Business, Enterprise On-Ramp and Enterprise**. `--region us-east-1` is hard-coded because the AWS Support API is a **global service with a single endpoint in `us-east-1`** (`support.us-east-1.amazonaws.com`); calling it from another Region fails to resolve. The same applies to Trusted Advisor's API surface.

**Q6.6** From least to most capable: **Basic → Developer → Business → Enterprise On-Ramp → Enterprise.** Response-time commitments that first appear at the top three:
- **Business** — *production system down* within **1 hour**; 24/7 access to Cloud Support Engineers by phone, chat and email.
- **Enterprise On-Ramp** — *business-critical system down* within **30 minutes**, a new severity level above Business's highest.
- **Enterprise** — *business-critical system down* within **15 minutes**, the fastest commitment AWS offers.

(For reference, Developer offers general guidance within 24 business hours and system-impaired within 12 business hours, business hours only, email only, one primary contact.)

**Q6.7**
- (a) **Business** — the first tier with 24/7 phone and chat access to Cloud Support Engineers, and unlimited contacts able to open cases.
- (b) **Business** — the first tier with the full set of Trusted Advisor checks across all five pillars plus programmatic access through the Support API. Basic and Developer receive only a limited subset (service quota and basic security checks).
- (c) **Enterprise** — the only tier with a **designated** Technical Account Manager. Enterprise On-Ramp provides a *pool* of TAMs, which is deliberately not the same commitment; both On-Ramp and Enterprise include Concierge support.

**Q6.8**
- (a) **AWS Activate for Startups** — promotional credits, technical support credits, training and go-to-market resources for eligible early-stage companies.
- (b) **AWS Managed Services (AMS)** — AWS operates your AWS infrastructure on your behalf: patching, backup, monitoring, incident and change management against an ITIL-aligned operating model. Note the distinction from Support: Support advises you, AMS *operates for you*.
- (c) **AWS IQ** — connects you with AWS-certified independent experts and firms for short, scoped engagements, contracted and billed through your AWS account.
- (d) **AWS Support** — the case-based channel to AWS Cloud Support Engineers, with a severity level matched to business impact.

### Exercise 7 — Capstone

**Q7.1**
1. **Application integration → Amazon SQS.** Durable buffer; the queue absorbs downstream failure without back-pressuring the web tier, and a DLQ quarantines poison messages.
2. **Application integration → Amazon EventBridge.** EC2 state-change events land on the default bus with no producer involvement, and the rule pattern selects `stopped` specifically.
3. **Developer tools → AWS AppConfig.** Externalised feature flags with validated, monitored, automatically-rolled-back deployments, decoupled from the artifact lifecycle.
4. **Business application services → Amazon Connect.** Omnichannel cloud contact centre with a browser-based agent workspace, call recording, and Contact Lens analytics; priced per minute.
5. **End-user computing → Amazon WorkSpaces.** Persistent DaaS virtual desktop with the user's installed applications and files, reachable from thin clients and tablets.
6. **Developer tools → AWS CodeArtifact.** Private package repository that also proxies and caches upstream public registries, so a public-registry outage cannot break your builds.
7. **Developer tools → AWS X-Ray.** End-to-end distributed traces and a service map, which is the only way to attribute latency to a specific hop across eleven services.
8. **IoT → AWS IoT Greengrass.** Local compute and local messaging at the edge, with stream manager buffering to disk and syncing on reconnect.

**Q7.2**
1. **Missing SQS queue access policy** granting `sqs:SendMessage` to the `sns.amazonaws.com` principal (or a policy whose `aws:SourceArn` condition does not match the topic). First check: `aws sqs get-queue-attributes --queue-url "$URL" --attribute-names Policy`. Cross-check the SNS side with `aws sns get-subscription-attributes` for delivery failures.
2. **The target is misconfigured or unauthorised** — the rule matched, so the pattern is right. Almost certainly the queue's resource policy is missing the `events.amazonaws.com` principal, or the `aws:SourceArn` names the wrong rule ARN, or no target is attached at all. First check: `aws events list-targets-by-rule --rule <name> --event-bus-name <bus>`, then the CloudWatch `AWS/Events` `FailedInvocations` metric for that rule.
3. **The IoT policy denies `iot:Publish`** on the topic the device is using (or the topic pattern in the rule's `FROM` clause does not match the topic being published to). Connection succeeded because `iot:Connect` is granted; publishes are dropped silently. First check: enable `aws iot set-v2-logging-options --default-log-level DEBUG --role-arn ...` and read the authorisation-failure events in CloudWatch Logs; then compare the policy resource ARNs against the actual topic and the rule's SQL `FROM 'sensors/+/telemetry'`.
4. **The account is in the SES sandbox.** Internal addresses were verified as identities and therefore accepted as recipients; customer addresses are not. First check: `aws sesv2 get-account --query ProductionAccessEnabled`. Remedy: request production access.

**Q7.3**
- **SQS** — when work must be durably buffered and processed by exactly one consumer, decoupling producer rate from consumer rate.
- **SNS** — when one event must be pushed immediately to many independent subscribers across heterogeneous protocols.
- **EventBridge** — when routing must be decided by event *content* across AWS services, SaaS partners and your own applications, with the producer knowing nothing about the consumers.

**Q7.4** Externally, **Amazon API Gateway** — it is the managed front door customers and partner systems call, where you enforce throttling, authorisation, versioning and caching. Internally, the **AWS CLI and the AWS SDKs** — every human and every program reaches AWS itself through them; every other console click and Terraform apply resolves to the same underlying API calls.

</details>