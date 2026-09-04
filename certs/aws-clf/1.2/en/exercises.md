# Topic 1.2 — Identify design principles of the AWS Cloud

## Guided exercises (CLF-C02, Domain 1, weight 6.0)

These exercises turn the four skills the exam guide names for Task Statement 1.2 — **design for failure**, **decoupling components versus monolithic architecture**, **implement elasticity**, and **think parallel** — plus the **AWS Well-Architected Framework** into things you can observe from a terminal. Every principle below is verified against an API response, a scaling activity, a queue depth, or a stopwatch, not against a slide.

### Prerequisites

| Requirement | Check |
|---|---|
| AWS CLI v2 | `aws --version` → `aws-cli/2.x.x …` |
| An account you may create and delete resources in | `aws sts get-caller-identity` |
| `jq` (optional, several steps show a `--query` alternative) | `jq --version` |
| A region with at least 2 Availability Zones and a default VPC | Exercise 0 verifies this |
| Permissions | `wellarchitected:*`, `ec2:*`, `autoscaling:*`, `sqs:*`, `s3:*`, `cloudformation:*`, `cloudwatch:*`, `fis:List*`, `servicequotas:Get*` |

### Cost guardrails

| Exercise | Billable resources | Order of magnitude |
|---|---|---|
| 1, 8 — Well-Architected Tool | none | **$0.00** (the tool is free of charge) |
| 2 — Service Quotas | none | $0.00 |
| 3 — Auto Scaling group | 2–4 × `t3.micro` for ~20 min, 2 CloudWatch alarms | < **$0.05** |
| 4 — SQS | ~50 API requests | $0.00 (1 M requests/month always free) |
| 5 — S3 parallelism | ~600 PUTs, ~600 MB stored for minutes | < **$0.02** |
| 6 — CloudFormation | none for AWS-native resource types | $0.00 |
| 7 — FIS (read-only listing) | none | $0.00 |

> **Run the teardown step of every exercise.** A forgotten Auto Scaling group with `MinSize=2` bills forever; the final teardown checklist is the safety net.

---

## Exercise 0 — Environment and blast-radius check

### Steps

1. Confirm which identity and account you are about to spend money in:

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDAEXAMPLEEXAMPLE",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-student"
   }
   ```

2. Pin a region for the whole lab. Every command below inherits it:

   ```bash
   export AWS_REGION=us-east-1
   export AWS_DEFAULT_REGION=$AWS_REGION
   aws configure get region
   ```

3. Enumerate the Availability Zones in that region — the physical substrate that "design for failure" rests on:

   ```bash
   aws ec2 describe-availability-zones \
     --query 'AvailabilityZones[].{AZ:ZoneName,Id:ZoneId,State:State}' \
     --output table
   ```

   ```
   ------------------------------------------
   |       DescribeAvailabilityZones        |
   +-------------+--------------+-----------+
   |     AZ      |     Id       |   State   |
   +-------------+--------------+-----------+
   |  us-east-1a |  use1-az4    |  available|
   |  us-east-1b |  use1-az6    |  available|
   |  us-east-1c |  use1-az1    |  available|
   |  us-east-1d |  use1-az2    |  available|
   |  us-east-1e |  use1-az3    |  available|
   |  us-east-1f |  use1-az5    |  available|
   +-------------+--------------+-----------+
   ```

4. Confirm a default VPC exists and capture its subnets, one per AZ:

   ```bash
   aws ec2 describe-subnets \
     --filters Name=default-for-az,Values=true \
     --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock}' \
     --output table
   ```

   If this returns an empty list, create one with `aws ec2 create-default-vpc` or substitute your own subnet IDs in Exercise 3.

### Check your understanding

- **Q0.1** — The `AZ` column (`us-east-1a`) and the `Id` column (`use1-az4`) differ. Why does AWS publish both, and which one is stable across two different AWS accounts?
- **Q0.2** — A workload runs entirely in `us-east-1a`. Which Well-Architected pillar does that violate first, and which of the four Task 1.2 skills does it fail?
- **Q0.3** — Regions and Availability Zones are infrastructure, not design principles. Explain in one sentence why the *existence* of multiple AZs is not by itself high availability.

---

## Exercise 1 — Enumerate the six pillars from the source of truth

The Well-Architected Framework is not only prose: the **AWS Well-Architected Tool** exposes the same lens as a queryable API. Reading the pillars out of the API is the difference between memorising a list and knowing where the list comes from.

### Steps

1. List the lenses available to your account. `wellarchitected` is the alias of the core framework lens:

   ```bash
   aws wellarchitected list-lenses \
     --query 'LensSummaries[].{Alias:LensAlias,Name:LensName,Type:LensType,Version:LensVersion}' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------------
   |                                      ListLenses                                      |
   +-------------------+------------------------------------+---------------+-------------+
   |       Alias       |               Name                 |     Type      |  Version    |
   +-------------------+------------------------------------+---------------+-------------+
   |  wellarchitected  |  AWS Well-Architected Framework    |  AWS_OFFICIAL |  2026-xx-xx |
   |  serverless       |  Serverless Applications Lens      |  AWS_OFFICIAL |  2026-xx-xx |
   |  softwareasaservice| SaaS Lens                         |  AWS_OFFICIAL |  2026-xx-xx |
   +-------------------+------------------------------------+---------------+-------------+
   ```

   (Output abridged — the catalogue of lenses grows over time.)

2. Create a throwaway workload. This is the object a review attaches to; it costs nothing:

   ```bash
   WL_ID=$(aws wellarchitected create-workload \
     --workload-name "clf-1-2-lab" \
     --description "Sandbox workload used to enumerate WAF pillars and questions" \
     --environment PREPRODUCTION \
     --aws-regions "$AWS_REGION" \
     --lenses wellarchitected \
     --review-owner "student@example.com" \
     --client-request-token "clf-1-2-lab-0001" \
     --query WorkloadId --output text)

   echo "Workload: $WL_ID"
   ```

   ```
   Workload: 8f2a1c0b4d5e6f708192a3b4c5d6e7f8
   ```

   > `--client-request-token` is the idempotency key. Re-running the command with the same token returns the same workload instead of creating a second one — the API-level expression of "automate to make architectural experimentation easier."

3. Ask the API how many pillars the framework has, rather than trusting your memory:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'AnswerSummaries[].PillarId' --output text \
     | tr '\t' '\n' | sort -u
   ```

   ```
   costOptimization
   operationalExcellence
   performance
   reliability
   security
   sustainability
   ```

   Six lines, exactly. The string IDs are an API implementation detail — **the exam tests the pillar names, not these identifiers**: Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability.

4. Count the questions per pillar. The absolute numbers shift between lens versions; the shape does not:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'AnswerSummaries[].PillarId' --output text \
     | tr '\t' '\n' | sort | uniq -c | sort -rn
   ```

5. Read the Reliability pillar's questions — this is where "design for failure" lives, stated as questions an architect must answer:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --pillar-id reliability \
     --query 'AnswerSummaries[].QuestionTitle' --output text \
     | tr '\t' '\n' | nl
   ```

   ```
        1  How do you manage service quotas and constraints?
        2  How do you plan your network topology?
        3  How do you design your workload service architecture?
        4  How do you design interactions in a distributed system to prevent failures?
        5  How do you design interactions in a distributed system to mitigate or withstand failures?
        6  How do you monitor workload resources?
        7  How do you design your workload to adapt to changes in demand?
        8  How do you implement change?
        9  How do you back up data?
       10  How do you use fault isolation to protect your workload?
       11  How do you design your workload to withstand component failures?
       12  How do you test reliability?
       13  How do you plan for disaster recovery (DR)?
   ```

6. Do the same for Sustainability, the pillar added most recently and the one candidates most often forget:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --pillar-id sustainability \
     --query 'AnswerSummaries[].QuestionTitle' --output text \
     | tr '\t' '\n' | nl
   ```

7. Keep `$WL_ID` for Exercise 8, or delete it now and recreate it later:

   ```bash
   # Teardown (optional here — Exercise 8 reuses the workload)
   aws wellarchitected delete-workload \
     --workload-id "$WL_ID" \
     --client-request-token "clf-1-2-del-0001"
   ```

### Check your understanding

- **Q1.1** — Name the six pillars in the order AWS documents them, and give the one-line concern of each.
- **Q1.2** — Reliability question 7 is *"How do you design your workload to adapt to changes in demand?"* — the same topic as elasticity, which sounds like Performance Efficiency and like Cost Optimization. Why does the same capability appear under three pillars, and what does that tell you about how the framework is meant to be used?
- **Q1.3** — Step 2 created a workload but you never described a single resource. What does that reveal about what the Well-Architected Tool actually measures?
- **Q1.4** — Which pillar owns *"How do you use fault isolation to protect your workload?"*, and which Task 1.2 skill does fault isolation implement?
- **Q1.5** — Your account may show lenses beyond `wellarchitected`. What is a *lens*, and why is it not a seventh pillar?

---

## Exercise 2 — The six general design principles, and one you can measure

Above the pillars, the framework states six **general design principles**. Five of them are cultural; one of them — *stop guessing your capacity needs* — has a hard, queryable boundary in AWS: **service quotas**. The cloud removes your *physical* capacity guess and replaces it with an *account* limit you can see and raise.

### Steps

1. Write down the six general design principles from the framework before running anything (answer key at the end):

   ```
   1. Stop guessing your capacity needs
   2. Test systems at production scale
   3. Automate to make architectural experimentation easier
   4. Allow for evolutionary architectures
   5. Drive architectures using data
   6. Improve through game days
   ```

2. Query the concrete ceiling behind principle 1 — the account's On-Demand Standard instance vCPU quota:

   ```bash
   aws service-quotas get-service-quota \
     --service-code ec2 \
     --quota-code L-1216C47A \
     --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable,Unit:Unit}' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------------------------------------
   |                                        GetServiceQuota                                          |
   +------------+-------------------------------------------------------------+----------+----------+
   | Adjustable |                            Name                             |   Unit   |  Value   |
   +------------+-------------------------------------------------------------+----------+----------+
   |  True      |  Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) …    |  None    |  5.0     |
   +------------+-------------------------------------------------------------+----------+----------+
   ```

   A brand-new account typically shows a small value (often `5.0` vCPUs). **Adjustable: True** is the point: the ceiling is an account attribute, not a purchase order.

3. Look at the surrounding quota surface for one service to see how much of "capacity" is now a data-plane question:

   ```bash
   aws service-quotas list-service-quotas --service-code ec2 \
     --query 'Quotas[?Adjustable==`true`].QuotaName' --output text \
     | tr '\t' '\n' | head -20
   ```

4. Compare with a service that has effectively no capacity ceiling to plan against:

   ```bash
   aws service-quotas list-service-quotas --service-code sqs \
     --query 'Quotas[].{Name:QuotaName,Value:Value,Adjustable:Adjustable}' \
     --output table
   ```

5. Fill in this mapping table in your notes. Each general principle must be paired with the AWS capability that makes it *possible* — not merely desirable:

   | General design principle | Capability that makes it possible | Verified in exercise |
   |---|---|---|
   | Stop guessing your capacity needs | | |
   | Test systems at production scale | | |
   | Automate to make architectural experimentation easier | | |
   | Allow for evolutionary architectures | | |
   | Drive architectures using data | | |
   | Improve through game days | | |

### Check your understanding

- **Q2.1** — "Stop guessing your capacity needs" is often summarised as *"the cloud is infinite."* Using the output of step 2, state precisely why that summary is wrong and what the correct statement is.
- **Q2.2** — On-premises, "test systems at production scale" is usually refused on cost grounds. What specific property of cloud billing removes that objection, and what would you do immediately after the test?
- **Q2.3** — Principles 3 and 4 ("automate to make experimentation easier" and "allow for evolutionary architectures") are causally linked. Which one enables the other, and why is the reverse order impossible?
- **Q2.4** — Which of the six general principles is *not* about architecture at all, but about organisational practice? Which pillar reinforces it most directly?

---

## Exercise 3 — Design for failure and implement elasticity in one Auto Scaling group

An Auto Scaling group is the smallest artefact that demonstrates three exam skills at once: **design for failure** (it replaces dead instances), **implement elasticity** (it changes capacity with demand), and **drive architectures using data** (target tracking creates the CloudWatch alarms that decide).

> **Cost**: 2–4 `t3.micro` instances for the duration of the exercise. Do not walk away before step 10.

### Steps

1. Resolve the current Amazon Linux 2023 AMI for your region from the SSM public parameter — never hard-code an AMI ID, it is region-specific and changes with every patch:

   ```bash
   AMI=$(aws ssm get-parameters \
     --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameters[0].Value' --output text)
   echo "$AMI"
   ```

   ```
   ami-0abcdef1234567890
   ```

2. Collect the default subnets as a comma-separated list — one per AZ, which is what makes the group multi-AZ:

   ```bash
   SUBNETS=$(aws ec2 describe-subnets \
     --filters Name=default-for-az,Values=true \
     --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
   echo "$SUBNETS"
   ```

   ```
   subnet-0aa1,subnet-0bb2,subnet-0cc3,subnet-0dd4,subnet-0ee5,subnet-0ff6
   ```

3. Create a launch template — the immutable, versioned description of *what* to launch. This separation of "what to run" from "how many to run" is the mechanical core of elasticity:

   ```bash
   aws ec2 create-launch-template \
     --launch-template-name clf-1-2-lt \
     --version-description v1 \
     --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\"}" \
     --query 'LaunchTemplate.{Name:LaunchTemplateName,Id:LaunchTemplateId,Version:LatestVersionNumber}' \
     --output table
   ```

   If `t3.micro` is unavailable in your region, substitute `t2.micro`.

4. Create the Auto Scaling group across every AZ:

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf-1-2-asg \
     --launch-template LaunchTemplateName=clf-1-2-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --health-check-type EC2 --health-check-grace-period 60 \
     --vpc-zone-identifier "$SUBNETS"
   ```

   No output means success.

5. Wait ~60 seconds, then observe where capacity landed:

   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names clf-1-2-asg \
     --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,State:LifecycleState,Health:HealthStatus}' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                    DescribeAutoScalingGroups                      |
   +--------------+-----------------------+-----------+----------------+
   |      AZ      |         Id            |  Health   |     State      |
   +--------------+-----------------------+-----------+----------------+
   |  us-east-1a  |  i-0123456789abcdef0  |  Healthy  |  InService     |
   |  us-east-1d  |  i-0fedcba9876543210  |  Healthy  |  InService     |
   +--------------+-----------------------+-----------+----------------+
   ```

   Two instances, two different AZs. You never asked for that placement — you asked for `--desired-capacity 2` across six subnets.

6. **Design for failure — break it on purpose.** Terminate one instance behind the group's back, the way a hardware fault would:

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names clf-1-2-asg \
     --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
   echo "Killing $VICTIM"
   aws ec2 terminate-instances --instance-ids "$VICTIM" \
     --query 'TerminatingInstances[].{Id:InstanceId,From:PreviousState.Name,To:CurrentState.Name}' \
     --output table
   ```

7. Poll the group until it heals, then read *why* it acted:

   ```bash
   for i in $(seq 1 12); do
     aws autoscaling describe-auto-scaling-groups \
       --auto-scaling-group-names clf-1-2-asg \
       --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,HealthStatus]' \
       --output text
     echo "---"; sleep 20
   done
   ```

   ```
   i-0fedcba9876543210	InService	Healthy
   ---
   i-0fedcba9876543210	InService	Healthy
   i-0aabbccddeeff0011	Pending	Healthy
   ---
   i-0fedcba9876543210	InService	Healthy
   i-0aabbccddeeff0011	InService	Healthy
   ---
   ```

8. Read the audit trail — Auto Scaling records the cause of every capacity change:

   ```bash
   aws autoscaling describe-scaling-activities \
     --auto-scaling-group-name clf-1-2-asg \
     --max-items 4 \
     --query 'Activities[].{Status:StatusCode,Description:Description,Cause:Cause}' \
     --output json
   ```

   ```json
   [
     {
       "Status": "Successful",
       "Description": "Launching a new EC2 instance: i-0aabbccddeeff0011",
       "Cause": "At 2026-09-03T14:22:31Z an instance was taken out of service in response to a system health-check failure."
     },
     {
       "Status": "Successful",
       "Description": "Terminating EC2 instance: i-0123456789abcdef0",
       "Cause": "At 2026-09-03T14:21:58Z an instance was taken out of service in response to a system health-check failure."
     }
   ]
   ```

   (Timestamps and IDs will differ; the `Cause` wording is representative.)

9. **Implement elasticity — two ways.** First manually, then by data. Manual:

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-1-2-asg --desired-capacity 4
   ```

   Then replace the human with a metric. A **target tracking** policy states an *outcome* ("keep average CPU at 50%"), not a procedure:

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf-1-2-asg \
     --policy-name cpu-target-50 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageCPUUtilization"},
       "TargetValue": 50.0
     }' \
     --query '{Arn:PolicyARN,Alarms:Alarms[].AlarmName}' --output json
   ```

   ```json
   {
     "Arn": "arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:...:policyName/cpu-target-50",
     "Alarms": [
       {"AlarmName": "TargetTracking-clf-1-2-asg-AlarmHigh-1a2b3c4d-..."},
       {"AlarmName": "TargetTracking-clf-1-2-asg-AlarmLow-5e6f7a8b-..."}
     ]
   }
   ```

10. Inspect the alarms the policy created for you — this is "drive architectures using data" made concrete:

    ```bash
    aws cloudwatch describe-alarms \
      --alarm-name-prefix "TargetTracking-clf-1-2-asg" \
      --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Stat:Statistic,Threshold:Threshold,Op:ComparisonOperator,Periods:EvaluationPeriods}' \
      --output table
    ```

11. **Teardown — do not skip:**

    ```bash
    aws autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name clf-1-2-asg --force-delete
    sleep 60
    aws ec2 delete-launch-template --launch-template-name clf-1-2-lt
    aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names clf-1-2-asg \
      --query 'AutoScalingGroups' --output text   # expect empty
    ```

### Check your understanding

- **Q3.1** — Step 5 produced instances in two different AZs without you specifying AZs. Which design principle does that placement implement, and what property of the group's configuration caused it?
- **Q3.2** — In step 6 you terminated the instance yourself, yet step 8's `Cause` speaks of a health-check failure. What does the Auto Scaling group actually react to, and why does that distinction matter for "design for failure"?
- **Q3.3** — The group has `MinSize=2`. Explain the cost consequence and the availability consequence of setting `MinSize=1` instead, and state which pillar each consequence belongs to.
- **Q3.4** — Step 9 offers manual `set-desired-capacity` and a target tracking policy. Both change capacity. Which one is *elasticity* under the exam's definition, and why is the other one not?
- **Q3.5** — The target tracking policy created **two** alarms, high and low. Why would a policy that only scales out be an anti-pattern, and which pillar objects loudest?
- **Q3.6** — Scaling is bounded by `MaxSize=4`. Connect this to the service quota you read in Exercise 2 — what are the two independent ceilings on how far this workload can scale?

---

## Exercise 4 — Decoupling: prove the queue absorbs the failure

Monolithic coupling means "the caller waits for the callee, and dies with it." A queue converts a synchronous dependency into an asynchronous one, so a dead consumer becomes a *backlog* rather than an *outage*. This exercise makes the failure and the backlog visible in numbers.

### Steps

1. Create the work queue and its dead-letter queue:

   ```bash
   QURL=$(aws sqs create-queue --queue-name clf-1-2-orders \
     --attributes VisibilityTimeout=30,MessageRetentionPeriod=345600 \
     --query QueueUrl --output text)

   DLQ_URL=$(aws sqs create-queue --queue-name clf-1-2-orders-dlq \
     --query QueueUrl --output text)

   echo "main: $QURL"; echo "dlq : $DLQ_URL"
   ```

   `MessageRetentionPeriod=345600` is 4 days — the SQS default. The maximum is `1209600` (14 days).

2. Wire the DLQ to the main queue with a redrive policy. Three failed receives and the message is quarantined instead of poisoning the consumer forever:

   ```bash
   DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
     --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

   cat > /tmp/redrive.json <<EOF
   {"RedrivePolicy":"{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"}
   EOF

   aws sqs set-queue-attributes --queue-url "$QURL" --attributes file:///tmp/redrive.json
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names RedrivePolicy VisibilityTimeout MessageRetentionPeriod \
     --query Attributes --output json
   ```

   ```json
   {
     "VisibilityTimeout": "30",
     "MessageRetentionPeriod": "345600",
     "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:123456789012:clf-1-2-orders-dlq\",\"maxReceiveCount\":\"3\"}"
   }
   ```

3. **Simulate the consumer being completely down** — do not start one. Produce ten orders anyway:

   ```bash
   for i in $(seq 1 10); do
     aws sqs send-message --queue-url "$QURL" \
       --message-body "{\"order\":$i,\"sku\":\"SKU-$((RANDOM % 100))\"}" \
       --query MessageId --output text
   done
   ```

   ```
   4a7d3f21-...-9b0c
   9c1e8b40-...-2d17
   … (10 IDs)
   ```

   Every producer call succeeded while the downstream tier did not exist. **That is decoupling, measured.**

4. Read the backlog:

   ```bash
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages \
                       ApproximateNumberOfMessagesNotVisible \
                       ApproximateNumberOfMessagesDelayed \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "10",
     "ApproximateNumberOfMessagesNotVisible": "0",
     "ApproximateNumberOfMessagesDelayed": "0"
   }
   ```

5. **Bring the consumer back.** Long-poll for a batch:

   ```bash
   aws sqs receive-message --queue-url "$QURL" \
     --max-number-of-messages 5 --wait-time-seconds 10 \
     --query 'Messages[].{Body:Body,Handle:ReceiptHandle}' --output json > /tmp/batch.json
   jq -r '.[].Body' /tmp/batch.json
   ```

   ```
   {"order":1,"sku":"SKU-42"}
   {"order":3,"sku":"SKU-7"}
   {"order":2,"sku":"SKU-88"}
   …
   ```

   Note the order is not strictly 1,2,3 — a standard queue guarantees best-effort ordering, not FIFO.

6. Immediately re-read the counters while the visibility timeout is still running:

   ```bash
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "5",
     "ApproximateNumberOfMessagesNotVisible": "5"
   }
   ```

   Five in flight, five waiting. Nothing was lost, and nothing was handed to a second consumer.

7. **Simulate the consumer crashing mid-processing** — do *not* delete the messages. Wait out the visibility timeout and look again:

   ```bash
   sleep 35
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "10",
     "ApproximateNumberOfMessagesNotVisible": "0"
   }
   ```

   All ten are back. The crash cost latency, not data.

8. Now behave like a healthy consumer — acknowledge one message explicitly:

   ```bash
   HANDLE=$(aws sqs receive-message --queue-url "$QURL" \
     --max-number-of-messages 1 --wait-time-seconds 5 \
     --query 'Messages[0].ReceiptHandle' --output text)

   aws sqs delete-message --queue-url "$QURL" --receipt-handle "$HANDLE"
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages --query Attributes --output json
   ```

   ```json
   { "ApproximateNumberOfMessages": "9" }
   ```

9. **Teardown:**

   ```bash
   aws sqs delete-queue --queue-url "$QURL"
   aws sqs delete-queue --queue-url "$DLQ_URL"
   ```

   Queue names are reserved for ~60 seconds after deletion.

### Check your understanding

- **Q4.1** — In step 3 the producer succeeded ten times with zero consumers running. State, in the vocabulary of Task 1.2, what property of the architecture made that possible and what would have happened in a monolithic, synchronous design.
- **Q4.2** — Distinguish `ApproximateNumberOfMessages` from `ApproximateNumberOfMessagesNotVisible`. Which one would you graph as the primary scaling signal for the consumer fleet, and why?
- **Q4.3** — Step 7 recovered all ten messages after a simulated crash. Which two queue attributes together produced that outcome, and what is the failure mode if the visibility timeout is set *shorter* than the consumer's processing time?
- **Q4.4** — `maxReceiveCount: 3` sends a message to the DLQ after three receives. Which Well-Architected pillar most directly motivates a DLQ, and what specific failure does it contain?
- **Q4.5** — Decoupling with a queue introduces eventual consistency and out-of-order delivery (visible in step 5). Name one workload where that trade-off is unacceptable, and what you would change.
- **Q4.6** — The queue never "went down" during this exercise and you never patched, sized or scaled it. Which cloud characteristic from Domain 1 does that illustrate?

---

## Exercise 5 — Think parallel, and measure it

"Think parallel" is the least intuitive of the four skills because on a single server it is usually false economy. On AWS, the storage and network layers are horizontally scalable, so throughput is a function of *concurrency*, not of the machine. Prove it with a stopwatch.

### Steps

1. Create a lab bucket (bucket names are globally unique):

   ```bash
   BUCKET="clf-1-2-lab-$(aws sts get-caller-identity --query Account --output text)-$RANDOM"

   if [ "$AWS_REGION" = "us-east-1" ]; then
     aws s3api create-bucket --bucket "$BUCKET"
   else
     aws s3api create-bucket --bucket "$BUCKET" \
       --create-bucket-configuration "LocationConstraint=$AWS_REGION"
   fi
   echo "$BUCKET"
   ```

2. Generate 200 small objects — the many-small-files workload, where concurrency dominates:

   ```bash
   mkdir -p /tmp/clf-parallel && cd /tmp/clf-parallel
   for i in $(seq 1 200); do head -c 1048576 /dev/urandom > "part-$i.bin"; done
   du -sh /tmp/clf-parallel
   ```

   ```
   200M	/tmp/clf-parallel
   ```

3. Record the CLI's current concurrency setting (the default is `10`):

   ```bash
   aws configure get default.s3.max_concurrent_requests || echo "unset (default: 10)"
   ```

4. **Serial baseline** — force one request at a time:

   ```bash
   aws configure set default.s3.max_concurrent_requests 1
   time aws s3 sync /tmp/clf-parallel "s3://$BUCKET/serial/" --only-show-errors
   ```

   ```
   real	3m41.208s
   user	0m52.114s
   sys	0m9.633s
   ```

5. **Parallel run** — same bytes, same network, twenty in flight:

   ```bash
   aws configure set default.s3.max_concurrent_requests 20
   time aws s3 sync /tmp/clf-parallel "s3://$BUCKET/parallel/" --only-show-errors
   ```

   ```
   real	0m24.867s
   user	1m03.771s
   sys	0m12.480s
   ```

   Absolute numbers depend entirely on your uplink; the **ratio** is the lesson. Note `user` time barely changed — you did not buy more CPU, you stopped idling on round-trips.

6. Now the single-large-object case, where the parallelism happens *inside* one upload via multipart:

   ```bash
   head -c 209715200 /dev/urandom > /tmp/big.bin   # 200 MB

   aws configure set default.s3.multipart_threshold 8MB
   aws configure set default.s3.multipart_chunksize 8MB
   time aws s3 cp /tmp/big.bin "s3://$BUCKET/big-8mb.bin" --only-show-errors

   aws configure set default.s3.multipart_chunksize 64MB
   time aws s3 cp /tmp/big.bin "s3://$BUCKET/big-64mb.bin" --only-show-errors
   ```

   With `max_concurrent_requests=20`, an 8 MB chunk size yields 25 parts uploaded in parallel; a 64 MB chunk size yields 4. Expect the smaller chunk size to finish faster on a fat link — and to issue more requests.

7. Verify both objects are byte-identical despite different upload strategies:

   ```bash
   aws s3api head-object --bucket "$BUCKET" --key big-8mb.bin  --query 'ContentLength'
   aws s3api head-object --bucket "$BUCKET" --key big-64mb.bin --query 'ContentLength'
   aws s3api head-object --bucket "$BUCKET" --key big-8mb.bin  --query 'ETag'
   aws s3api head-object --bucket "$BUCKET" --key big-64mb.bin --query 'ETag'
   ```

   ```
   209715200
   209715200
   "9a7f...-25"
   "1c3e...-4"
   ```

   Same length, different ETags — and the trailing `-25` / `-4` is the part count. A multipart ETag is **not** the MD5 of the object.

8. **Teardown and restore your CLI defaults:**

   ```bash
   aws s3 rm "s3://$BUCKET" --recursive
   aws s3api delete-bucket --bucket "$BUCKET"
   aws configure set default.s3.max_concurrent_requests 10
   aws configure set default.s3.multipart_threshold 8MB
   aws configure set default.s3.multipart_chunksize 8MB
   rm -rf /tmp/clf-parallel /tmp/big.bin
   ```

### Check your understanding

- **Q5.1** — Steps 4 and 5 moved identical bytes over an identical link with very different wall-clock times. What resource was the serial run actually waiting on, and why does the cloud reward concurrency more than an on-premises NAS typically does?
- **Q5.2** — `user` CPU time rose slightly while `real` time collapsed. What does that tell you about whether "think parallel" is a CPU optimisation?
- **Q5.3** — Smaller `multipart_chunksize` means more parts and usually faster uploads, yet AWS bills per request. Name the pillar on each side of that trade-off and state how you would decide.
- **Q5.4** — Give two AWS services other than S3 whose entire value proposition is "think parallel", and say what unit each of them parallelises.
- **Q5.5** — A team reports "S3 is slow." They upload one 5 GB file with a single-threaded custom client. Without buying anything, name two changes that increase throughput and explain which design principle each applies.

---

## Exercise 6 — Automate experimentation, allow evolutionary architectures

Principles 3 and 4 are one capability seen twice: if the architecture is a text file, changing it is a diff, and reverting it is a diff. Infrastructure as code is what turns "evolutionary architecture" from an aspiration into a `git revert`.

### Steps

1. Write the version-1 template:

   ```bash
   cat > /tmp/clf-1-2.yaml <<'EOF'
   AWSTemplateFormatVersion: '2010-09-09'
   Description: CLF-C02 Topic 1.2 - evolutionary architecture demonstration

   Parameters:
     RetentionSeconds:
       Type: Number
       Default: 345600
       MinValue: 60
       MaxValue: 1209600
       Description: SQS message retention period, in seconds

   Resources:
     WorkQueue:
       Type: AWS::SQS::Queue
       Properties:
         QueueName: clf-1-2-cfn-queue
         MessageRetentionPeriod: !Ref RetentionSeconds
         VisibilityTimeout: 30

   Outputs:
     QueueUrl:
       Description: URL of the work queue
       Value: !Ref WorkQueue
     QueueArn:
       Description: ARN of the work queue
       Value: !GetAtt WorkQueue.Arn
   EOF
   ```

2. Validate before deploying — the cheapest possible failure:

   ```bash
   aws cloudformation validate-template --template-body file:///tmp/clf-1-2.yaml \
     --query '{Description:Description,Params:Parameters[].ParameterKey}' --output json
   ```

   ```json
   {
     "Description": "CLF-C02 Topic 1.2 - evolutionary architecture demonstration",
     "Params": ["RetentionSeconds"]
   }
   ```

3. Deploy version 1:

   ```bash
   aws cloudformation deploy --stack-name clf-1-2-cfn --template-file /tmp/clf-1-2.yaml
   aws cloudformation describe-stacks --stack-name clf-1-2-cfn \
     --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs[].{K:OutputKey,V:OutputValue}}' \
     --output json
   ```

   ```json
   {
     "Status": "CREATE_COMPLETE",
     "Outputs": [
       {"K": "QueueUrl", "V": "https://sqs.us-east-1.amazonaws.com/123456789012/clf-1-2-cfn-queue"},
       {"K": "QueueArn", "V": "arn:aws:sqs:us-east-1:123456789012:clf-1-2-cfn-queue"}
     ]
   }
   ```

4. **Propose an evolution without committing to it.** A change set is the architectural equivalent of a code review:

   ```bash
   aws cloudformation deploy --stack-name clf-1-2-cfn \
     --template-file /tmp/clf-1-2.yaml \
     --parameter-overrides RetentionSeconds=1209600 \
     --no-execute-changeset
   ```

   The CLI prints the command to inspect the pending change; run it, or list change sets directly:

   ```bash
   CS=$(aws cloudformation list-change-sets --stack-name clf-1-2-cfn \
     --query 'Summaries[0].ChangeSetName' --output text)

   aws cloudformation describe-change-set --stack-name clf-1-2-cfn --change-set-name "$CS" \
     --query 'Changes[].ResourceChange.{Action:Action,Res:LogicalResourceId,Replacement:Replacement,Props:Details[].Target.Name}' \
     --output json
   ```

   ```json
   [
     {
       "Action": "Modify",
       "Res": "WorkQueue",
       "Replacement": "False",
       "Props": ["MessageRetentionPeriod"]
     }
   ]
   ```

   `"Replacement": "False"` is the risk assessment: this change updates in place and will not destroy the queue.

5. Execute the change set:

   ```bash
   aws cloudformation execute-change-set --stack-name clf-1-2-cfn --change-set-name "$CS"
   aws cloudformation wait stack-update-complete --stack-name clf-1-2-cfn
   aws sqs get-queue-attributes \
     --queue-url "https://sqs.$AWS_REGION.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/clf-1-2-cfn-queue" \
     --attribute-names MessageRetentionPeriod --query Attributes --output json
   ```

   ```json
   { "MessageRetentionPeriod": "1209600" }
   ```

6. **Introduce drift** the way a hurried on-call engineer would — by hand, out of band:

   ```bash
   QUEUE_URL="https://sqs.$AWS_REGION.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/clf-1-2-cfn-queue"
   aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes VisibilityTimeout=120
   ```

7. Detect it:

   ```bash
   DID=$(aws cloudformation detect-stack-drift --stack-name clf-1-2-cfn \
     --query StackDriftDetectionId --output text)
   sleep 15
   aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DID" \
     --query '{Status:DetectionStatus,Drift:StackDriftStatus,Drifted:DriftedStackResourceCount}' \
     --output json
   ```

   ```json
   {
     "Status": "DETECTION_COMPLETE",
     "Drift": "DRIFTED",
     "Drifted": 1
   }
   ```

8. See exactly which property drifted:

   ```bash
   aws cloudformation describe-stack-resource-drifts --stack-name clf-1-2-cfn \
     --query 'StackResourceDrifts[].{Res:LogicalResourceId,Status:StackResourceDriftStatus,Diffs:PropertyDifferences[].{Path:PropertyPath,Expected:ExpectedValue,Actual:ActualValue}}' \
     --output json
   ```

   ```json
   [
     {
       "Res": "WorkQueue",
       "Status": "MODIFIED",
       "Diffs": [
         {"Path": "/VisibilityTimeout", "Expected": "30", "Actual": "120"}
       ]
     }
   ]
   ```

9. **Teardown — one command deletes the whole architecture:**

   ```bash
   aws cloudformation delete-stack --stack-name clf-1-2-cfn
   aws cloudformation wait stack-delete-complete --stack-name clf-1-2-cfn
   rm -f /tmp/clf-1-2.yaml
   ```

### Check your understanding

- **Q6.1** — Step 4 produced a plan without changing anything. Which general design principle does the *change set* mechanism serve, and what class of production incident does it prevent?
- **Q6.2** — `"Replacement": "False"` was the most important field in that output. Explain what `"True"` would have meant for a stateful resource, and why an architect must read it before executing.
- **Q6.3** — Step 6 was a legitimate emergency fix that worked. Why is it nonetheless a defect, and which pillar names the practice that step 6 breaks?
- **Q6.4** — Step 9 destroyed the environment in one command. Connect this to "test systems at production scale": what does cheap, complete teardown make affordable that a data centre does not?
- **Q6.5** — The template is a file. Name three things you can now do to your architecture that were impossible when it lived only in the console.

---

## Exercise 7 — Improve through game days: the fault catalogue and the blast radius

The sixth general principle asks you to *practise* failure rather than discuss it. AWS Fault Injection Service (FIS) turns that into a controlled, bounded experiment. This exercise is entirely read-only — you will inspect the catalogue of faults and design the guardrails, without incurring FIS charges.

### Steps

1. List the faults AWS can inject on your behalf:

   ```bash
   aws fis list-actions --query 'actions[].id' --output text | tr '\t' '\n' | sort
   ```

   ```
   aws:ec2:reboot-instances
   aws:ec2:stop-instances
   aws:ec2:terminate-instances
   aws:ecs:stop-task
   aws:eks:pod-cpu-stress
   aws:eks:pod-delete
   aws:eks:pod-network-latency
   aws:fis:inject-api-internal-error
   aws:fis:wait
   aws:network:disrupt-connectivity
   aws:rds:failover-db-cluster
   aws:rds:reboot-db-instances
   aws:ssm:send-command
   ...
   ```

   (Abridged — the catalogue grows.)

2. Read the full description and parameters of one action:

   ```bash
   aws fis get-action --id aws:ec2:stop-instances \
     --query 'action.{Id:id,Description:description,Params:keys(parameters),Targets:keys(targets)}' \
     --output json
   ```

   ```json
   {
     "Id": "aws:ec2:stop-instances",
     "Description": "Stop the specified Amazon EC2 instances.",
     "Params": ["startInstancesAfterDuration"],
     "Targets": ["Instances"]
   }
   ```

3. Find the actions that would let you rehearse the *exact* failure you healed by hand in Exercise 3:

   ```bash
   aws fis list-actions --query 'actions[?starts_with(id, `aws:ec2:`)].{Id:id,Desc:description}' \
     --output table
   ```

4. Find the actions that simulate an **Availability Zone** or connectivity loss — the failure mode Exercise 0 argued about:

   ```bash
   aws fis list-actions \
     --query 'actions[?contains(id, `network`) || contains(id, `disrupt`)].{Id:id,Desc:description}' \
     --output table
   ```

5. On paper, specify a game day for the Exercise 3 Auto Scaling group. A valid FIS experiment template needs all four:

   | Element | Your answer |
   |---|---|
   | **Action** (what breaks) | |
   | **Target** (blast radius — which resources, selected how) | |
   | **Stop condition** (the CloudWatch alarm that aborts the experiment) | |
   | **Hypothesis** (the falsifiable statement you are testing) | |

6. Confirm the account has no experiments running or templates left behind:

   ```bash
   aws fis list-experiment-templates --query 'experimentTemplates[].{Id:id,Desc:description}' --output table
   aws fis list-experiments --query 'experiments[].{Id:id,State:state.status}' --output table
   ```

No teardown is required — every command above is read-only.

### Check your understanding

- **Q7.1** — An FIS experiment template requires a **stop condition**. What is the engineering purpose of mandating one, and what would the experiment become without it?
- **Q7.2** — Write a falsifiable hypothesis for the Exercise 3 group in the form *"When X, we expect Y within Z."* Explain why "we expect the system to be fine" is not a hypothesis.
- **Q7.3** — Game days are listed as a *general design principle*, but the practice is owned primarily by one pillar and validates another. Name both and justify the split.
- **Q7.4** — Your manager objects: "we already know a stopped instance gets replaced — we saw it in Exercise 3." Give the strongest argument for running the game day anyway.
- **Q7.5** — The FIS catalogue includes `aws:fis:inject-api-internal-error`. What class of failure does that rehearse that stopping an instance cannot, and which Reliability question from Exercise 1 does it exercise?

---

## Exercise 8 — Close the loop: a Well-Architected review with a risk count

Exercise 1 read the framework. This one *uses* it: answer questions, watch a risk profile appear, generate an improvement plan, and freeze a milestone so the next review has a baseline to compare against.

### Steps

1. Recreate the workload if you deleted it:

   ```bash
   WL_ID=$(aws wellarchitected create-workload \
     --workload-name "clf-1-2-review" \
     --description "Auto Scaling group + SQS pipeline from exercises 3 and 4" \
     --environment PREPRODUCTION \
     --aws-regions "$AWS_REGION" \
     --lenses wellarchitected \
     --review-owner "student@example.com" \
     --client-request-token "clf-1-2-review-0001" \
     --query WorkloadId --output text)
   echo "$WL_ID"
   ```

2. Look at the risk profile of a review in which **nothing has been answered yet**:

   ```bash
   aws wellarchitected get-lens-review \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'LensReview.PillarReviewSummaries[].{Pillar:PillarName,Risks:RiskCounts}' \
     --output json
   ```

   ```json
   [
     {"Pillar": "Operational Excellence", "Risks": {"UNANSWERED": 11, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     {"Pillar": "Security",               "Risks": {"UNANSWERED": 11, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     {"Pillar": "Reliability",            "Risks": {"UNANSWERED": 13, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     ...
   ]
   ```

   (Counts vary by lens version.) Everything is `UNANSWERED` — the tool asserts nothing about a workload you have not described.

3. Pick the reliability question about withstanding component failures and read its choices:

   ```bash
   QID=$(aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected --pillar-id reliability \
     --query 'AnswerSummaries[?contains(QuestionTitle, `withstand component failures`)].QuestionId | [0]' \
     --output text)
   echo "$QID"

   aws wellarchitected get-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected --question-id "$QID" \
     --query 'Answer.Choices[].{Id:ChoiceId,Title:Title}' --output table
   ```

4. Answer it honestly for the architecture you actually built in Exercises 3 and 4:

   ```bash
   CHOICE=$(aws wellarchitected get-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected --question-id "$QID" \
     --query 'Answer.Choices[0].ChoiceId' --output text)

   aws wellarchitected update-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --question-id "$QID" \
     --selected-choices "$CHOICE" \
     --notes "Multi-AZ ASG with EC2 health checks; SQS decouples the consumer tier; no DR plan yet." \
     --query 'Answer.{Q:QuestionTitle,Risk:Risk,Selected:SelectedChoices}' --output json
   ```

   ```json
   {
     "Q": "How do you design your workload to withstand component failures?",
     "Risk": "MEDIUM",
     "Selected": ["rel_withstand_component_failures_..."]
   }
   ```

   Selecting *some* best practices but not all yields `MEDIUM`; selecting none yields `HIGH`.

5. Mark a question genuinely out of scope, which is different from leaving it unanswered:

   ```bash
   QID2=$(aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected --pillar-id reliability \
     --query 'AnswerSummaries[?contains(QuestionTitle, `disaster recovery`)].QuestionId | [0]' \
     --output text)

   aws wellarchitected update-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --question-id "$QID2" --is-applicable \
     --notes "Sandbox workload; no DR obligation." \
     --query 'Answer.{Q:QuestionTitle,Risk:Risk}' --output json
   ```

   To mark it not applicable, use `--no-is-applicable`.

6. Generate the improvement plan — the output that makes the tool actionable:

   ```bash
   aws wellarchitected list-lens-review-improvements \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'ImprovementSummaries[?Risk!=`NONE`].{Pillar:PillarId,Question:QuestionTitle,Risk:Risk,Plan:ImprovementPlanUrl}' \
     --output json | head -40
   ```

7. Freeze a milestone. A review with no baseline cannot show improvement:

   ```bash
   aws wellarchitected create-milestone \
     --workload-id "$WL_ID" \
     --milestone-name "baseline-before-remediation" \
     --client-request-token "clf-1-2-ms-0001" \
     --query '{Milestone:MilestoneNumber}' --output json

   aws wellarchitected list-milestones --workload-id "$WL_ID" \
     --query 'MilestoneSummaries[].{N:MilestoneNumber,Name:MilestoneName,When:RecordedAt}' \
     --output table
   ```

8. Re-read the pillar risk counts and compare against step 2:

   ```bash
   aws wellarchitected get-lens-review \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'LensReview.PillarReviewSummaries[?PillarName==`Reliability`].RiskCounts' \
     --output json
   ```

9. **Teardown:**

   ```bash
   aws wellarchitected delete-workload \
     --workload-id "$WL_ID" \
     --client-request-token "clf-1-2-review-del-0001"

   aws wellarchitected list-workloads \
     --query 'WorkloadSummaries[].WorkloadName' --output text
   ```

### Check your understanding

- **Q8.1** — At step 2 every question was `UNANSWERED` and no pillar showed `HIGH`. Is an unanswered review therefore low risk? Explain what `UNANSWERED` actually encodes.
- **Q8.2** — Distinguish `NOT_APPLICABLE` from `UNANSWERED`, and give a legitimate business reason to mark a question not applicable.
- **Q8.3** — What is a *milestone* for, and which general design principle does it serve? Answer without using the word "audit."
- **Q8.4** — The Well-Architected Tool is free and produces no infrastructure. State three concrete benefits it delivers that justify running a review — this is a directly examinable list.
- **Q8.5** — A review returns four `HIGH` risks in Security and one in Cost Optimization. In what order do you address them, and what does the framework say about treating all pillars as equally weighted?

---

## Exercise 9 — Scenario drill

The exam presents design principles as scenarios, not definitions. For each row, name **(a)** the primary Well-Architected pillar and **(b)** the Task 1.2 skill or general design principle it demonstrates.

### Steps

1. Copy the table into your notes and fill both columns before checking the answers.

   | # | Scenario | Pillar | Principle / skill |
   |---|---|---|---|
   | 1 | A checkout service writes orders to a queue; the fulfilment fleet reads from it. Fulfilment is redeployed for 20 minutes; checkout keeps taking orders. | | |
   | 2 | An analytics job is split into 500 chunks processed simultaneously, finishing in 4 minutes instead of 12 hours. | | |
   | 3 | A fleet of 6 web servers is spread across 3 Availability Zones behind a load balancer. | | |
   | 4 | Nightly at 21:00 the fleet drops from 20 instances to 4; at 07:00 it returns to 20. | | |
   | 5 | Before every release, the team runs a rehearsal that stops a random instance in production during business hours. | | |
   | 6 | The entire environment is defined in a template stored in Git; the staging environment is created and destroyed daily. | | |
   | 7 | Instance type selection is changed from `m5.4xlarge` to `m6g.xlarge` after reading two weeks of CloudWatch utilisation data. | | |
   | 8 | Access keys are replaced by IAM roles, and every API call is recorded in CloudTrail. | | |
   | 9 | Batch jobs are moved to a region with a lower carbon footprint and scheduled to run off-peak. | | |
   | 10 | Runbooks are converted into Systems Manager documents so remediation is executed identically by anyone. | | |
   | 11 | The team stops buying 3 years of hardware upfront and instead adds capacity weekly based on observed traffic. | | |
   | 12 | A load test is run against a full-size copy of production, then the copy is deleted the same afternoon. | | |

2. Now do the harder version — for rows 1, 3, 4 and 7, name a **second** pillar that also has a claim on the scenario, and state the trade-off between the two.

### Check your understanding

- **Q9.1** — Rows 3 and 4 both change the number of instances. What distinguishes *high availability* from *elasticity*, given that the mechanism (an Auto Scaling group) may be identical?
- **Q9.2** — Row 11 is the canonical statement of one general design principle. Name it, and name the capital-expenditure concept it replaces.
- **Q9.3** — Which row is the strongest example of "design for failure", and which is the strongest example of "think parallel"? Defend both choices against the runner-up.
- **Q9.4** — Row 9 belongs to the newest pillar. Give one additional architectural change that serves the same pillar without reducing capacity.

---

## Teardown checklist

Run this before you close the terminal. Every command should report nothing.

```bash
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?starts_with(AutoScalingGroupName, `clf-1-2`)].AutoScalingGroupName' --output text
aws ec2 describe-launch-templates \
  --query 'LaunchTemplates[?starts_with(LaunchTemplateName, `clf-1-2`)].LaunchTemplateName' --output text
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws sqs list-queues --queue-name-prefix clf-1-2 --query 'QueueUrls' --output text
aws s3 ls | grep clf-1-2 || echo "no lab buckets"
aws cloudformation describe-stacks \
  --query 'Stacks[?starts_with(StackName, `clf-1-2`)].StackName' --output text
aws wellarchitected list-workloads \
  --query 'WorkloadSummaries[?starts_with(WorkloadName, `clf-1-2`)].WorkloadName' --output text
aws cloudwatch describe-alarms \
  --alarm-name-prefix TargetTracking-clf-1-2 --query 'MetricAlarms[].AlarmName' --output text
```

---

<details>
<summary><b>Answers</b> — expand only after attempting every block</summary>

### Exercise 0

**Q0.1** — `us-east-1a` is an *AZ name*, and AWS maps AZ names to physical data centres **independently per account** so that customer workloads spread evenly instead of everyone crowding into "a". `use1-az4` is the *AZ ID*, which refers to the same physical location in every account. The **AZ ID is the stable one**; two accounts comparing `us-east-1a` may be discussing different buildings, which is why cross-account resource sharing (for example, subnets shared through AWS RAM) is expressed in AZ IDs.

**Q0.2** — It violates **Reliability** first. It fails the *design for failure* skill: a single AZ is a single fault domain, so any event affecting that AZ takes the entire workload down. There is a secondary Performance Efficiency concern (no capacity headroom elsewhere), but Reliability is the primary.

**Q0.3** — Multiple AZs are *available* fault domains, but availability comes from a workload actually being distributed across them with health checking and automatic replacement — infrastructure is a precondition, architecture is the cause.

### Exercise 1

**Q1.1** —
1. **Operational Excellence** — running and monitoring systems to deliver business value, and continually improving processes and procedures.
2. **Security** — protecting data, systems and assets; identity, detection, protection of data in transit and at rest, incident response.
3. **Reliability** — a workload performing its intended function correctly and consistently, and recovering from failure.
4. **Performance Efficiency** — using computing resources efficiently and keeping that efficiency as demand and technologies change.
5. **Cost Optimization** — delivering business value at the lowest price point.
6. **Sustainability** — minimising the environmental impact of running cloud workloads.

**Q1.2** — The pillars are **lenses on the same architecture, not partitions of it**. Elasticity is a reliability property (absorb demand spikes without failing), a performance property (right-size to load) and a cost property (do not pay for idle capacity). The framework is used by asking all six sets of questions about *the same* design and then making the trade-offs explicit — not by assigning each component to one pillar.

**Q1.3** — The Well-Architected Tool measures **your answers about the workload**, not the workload itself. It does not scan your account. A review is a structured self-assessment; its output is only as truthful as the answers you give — which is precisely why it is free and why it is worthless if answered aspirationally.

**Q1.4** — **Reliability**. Fault isolation implements **design for failure**: bulkheads, cell-based architecture, multi-AZ and multi-Region boundaries all limit how far a single failure can propagate.

**Q1.5** — A **lens** is an additional set of questions and best practices for a specific technology domain or industry (Serverless, SaaS, Machine Learning, Financial Services). It is applied *on top of* the six pillars and asks domain-specific questions within them. The pillar count is fixed at six; lenses are extensions, not pillars.

### Exercise 2

**Q2.1** — Capacity is not infinite; it is **elastic within an account quota, and the quota is adjustable on request rather than by procurement**. The correct statement is: you no longer have to guess capacity *at purchase time*, because you can acquire and release it in minutes — but you must still know and manage your service quotas, which is exactly why Reliability question 1 is *"How do you manage service quotas and constraints?"*.

**Q2.2** — **Pay-as-you-go with per-second or per-hour granularity and no upfront commitment**: a full-scale production clone costs the price of the hours it runs, not the price of a second data centre. Immediately after the test you **delete the environment**, which is what makes the cost proportional to the test rather than to the year.

**Q2.3** — **Automation enables evolution.** If changing the architecture requires a manual, error-prone, days-long procedure, the rational response is to freeze the design — the cost of change exceeds the value of improvement. Only when a change is cheap, repeatable and reversible does allowing the architecture to evolve become a safe default. The reverse is impossible: wanting an evolutionary architecture does not make manual change safe.

**Q2.4** — **"Improve through game days."** It prescribes a team practice — rehearsing failure — rather than an architectural property. **Operational Excellence** reinforces it most directly (learn from all operational events and failures), while what it *validates* is Reliability.

### Exercise 3

**Q3.1** — **Design for failure**, via fault isolation across Availability Zones. The cause is `--vpc-zone-identifier` listing subnets in multiple AZs: Auto Scaling balances capacity across the AZs it is given. Had you passed a single subnet, the same `--desired-capacity 2` would have produced two instances in one fault domain.

**Q3.2** — The group reacts to **health check results**, not to who caused them. A terminated instance stops passing EC2 status checks, and the group's contract is "keep `DesiredCapacity` healthy instances in service." That indifference to *cause* is the whole point of design for failure: the remediation is identical whether the trigger was a hardware fault, an AZ event, a kernel panic, or a person with a keyboard — so the recovery path is exercised constantly rather than being an untested emergency procedure.

**Q3.3** — With `MinSize=1` you pay for one instance instead of two — a **Cost Optimization** gain. But you also have no surviving capacity during the ~60–120 seconds it takes to detect failure and launch a replacement, so a single instance failure is a full outage — a **Reliability** loss. `MinSize=2` across two AZs buys continuous service through a single-instance or single-AZ failure. This is the canonical pillar trade-off: neither answer is "correct" without a stated availability requirement.

**Q3.4** — The **target tracking policy** is elasticity: capacity is acquired and released **automatically, in response to observed demand**. `set-desired-capacity` is manual provisioning that happens to be fast — it still depends on a human predicting or noticing demand, which is the guessing the cloud is supposed to eliminate. Speed of provisioning is not elasticity; *automatic* provisioning is.

**Q3.5** — Scaling out without scaling in means capacity ratchets upward and never returns, so you pay peak price permanently — the classic "cloud costs more than the data centre" failure. **Cost Optimization** objects loudest; **Sustainability** objects too, since idle instances consume energy for no delivered value.

**Q3.6** — Two independent ceilings: **(1)** the group's own `MaxSize=4`, a deliberate, self-imposed blast-radius and budget limit; **(2)** the **account service quota** for running On-Demand instance vCPUs, an external limit enforced by AWS. Raising `MaxSize` above what the quota permits produces failed launch activities, not more capacity — which is why quota management is a Reliability question, not a billing footnote.

### Exercise 4

**Q4.1** — The producer and consumer are **decoupled** by an intermediary that owns durability. The producer's availability no longer depends on the consumer's availability. In a monolithic, synchronous design the checkout call would have blocked on the fulfilment tier and then failed — the consumer's outage would have propagated to the customer as a failed purchase, converting a partial failure into a total one.

**Q4.2** — `ApproximateNumberOfMessages` is the **visible backlog**: messages available for retrieval. `ApproximateNumberOfMessagesNotVisible` is **in flight**: received by a consumer but not yet deleted, hidden for the visibility timeout. Scale the consumer fleet on the **visible backlog** (or on message age) — it measures unmet demand. In-flight count measures work already being done, so scaling on it creates a feedback loop that scales up in proportion to your own consumers.

**Q4.3** — **Explicit deletion as the acknowledgement** (a message is only removed when the consumer calls `DeleteMessage`) plus the **visibility timeout** (an un-acknowledged message reappears automatically). If the visibility timeout is shorter than processing time, the message becomes visible again while the first consumer is still working on it, a second consumer picks it up, and the message is processed **twice** — the classic duplicate-processing bug. The fix is to size the timeout above the p99 processing time, extend it in-flight (`ChangeMessageVisibility`), and make the consumer idempotent.

**Q4.4** — **Reliability**. A DLQ contains the *poison message*: a payload that will fail every time it is processed. Without a DLQ that one message is redelivered forever, consuming the consumer's capacity indefinitely and blocking healthy work — a single bad record becomes a fleet-wide outage. The DLQ bounds the failure to three attempts and quarantines it for offline inspection. (Operational Excellence has a secondary claim: the DLQ is also the diagnostic record.)

**Q4.5** — Any workload requiring **strict ordering or exactly-once semantics** — a financial ledger where debit-then-credit must not invert, or an inventory decrement that must not double-apply. The change: use an **SQS FIFO queue** (ordering and deduplication within a message group) and accept its lower throughput, or keep the standard queue and make consumers idempotent with a deduplication key.

**Q4.6** — **Elasticity together with the managed-service / shared-responsibility model**: SQS scales, patches and replicates itself, so the capacity and availability of the decoupling layer are AWS's responsibility rather than a component you must design for failure yourself. Note this is not free of design work — you still chose retention, visibility timeout and the redrive policy.

### Exercise 5

**Q5.1** — The serial run waited on **network round-trip latency**, not bandwidth: each request had to complete before the next began, so throughput was capped at (object size ÷ round-trip time), leaving the link mostly idle. S3 is a massively distributed service whose per-prefix request rate is far above what one connection can generate, so concurrent requests are served by different backend capacity. A traditional NAS typically has a single head node and a fixed spindle count, so concurrency competes for the same bottleneck instead of recruiting more of it.

**Q5.2** — "Think parallel" here is a **latency-hiding / concurrency optimisation, not a CPU optimisation**. The client was blocked, not busy. Nearly the same CPU work was done in one-ninth the wall-clock time because the waiting was overlapped. This is why parallelism on AWS often pays even on a small client instance.

**Q5.3** — **Performance Efficiency** favours smaller chunks (more parallelism, lower wall-clock time); **Cost Optimization** favours larger chunks (fewer PUT requests, lower request charges — and fewer retry costs on a lossy link). Decide by *what the latency is worth*: for an interactive or deadline-bound transfer, buy the speed; for an unattended nightly bulk load where wall-clock time is free, take the cheaper request count. Also weigh reliability — smaller parts mean a failed part costs less to retry.

**Q5.4** — Any two of: **AWS Lambda** (parallelises *invocations* — one concurrent execution per event); **Amazon EMR / Apache Spark** (parallelises *data partitions* across a cluster); **AWS Batch** (parallelises *jobs* in an array); **Amazon Kinesis Data Streams** (parallelises *shards*, one consumer per shard); **Amazon Athena** (parallelises *query splits* over objects in S3); **Amazon SQS with a consumer fleet** (parallelises *messages*).

**Q5.5** — **(1)** Use a multipart, multi-threaded upload — split the 5 GB object into parts and upload them concurrently, which is *think parallel* applied inside a single object. **(2)** Raise client concurrency (`max_concurrent_requests`) and/or move the client closer to the bucket's region, and use S3 Transfer Acceleration or a Multi-Region setup for distant clients — *drive architectures using data*, since the correct value comes from measuring, exactly as in steps 4–5. Both are configuration changes; neither buys hardware, which is the point.

### Exercise 6

**Q6.1** — It serves **"automate to make architectural experimentation easier"** (and directly supports "allow for evolutionary architectures"). It prevents the class of incident where an apparently innocuous template edit silently **replaces** a resource — a new queue, a new database, a new endpoint — destroying data or breaking every consumer that held the old identifier. The change set makes the blast radius reviewable *before* it is real.

**Q6.2** — `"Replacement": "True"` means CloudFormation will **create a new physical resource and delete the old one** to satisfy the change, because the modified property is immutable. For a stateful resource — an RDS instance, an EBS volume, a queue with a backlog — that means data loss and a changed identifier (endpoint, ARN, URL) that every dependent must be updated to use. An architect reads this field because the template diff looks identical in both cases; only the change set distinguishes "edit" from "rebuild."

**Q6.3** — The fix worked but the **template no longer describes reality**. The next `deploy` will silently revert the emergency change and re-break production; the environment can no longer be recreated identically; and the reason for the change exists only in one person's memory. This breaks **Operational Excellence** — perform operations as code, and make frequent, small, reversible changes. The correct sequence is: change it by hand if the outage demands it, then immediately backport it to the template and redeploy.

**Q6.4** — Cheap, complete teardown makes **full-scale, disposable environments affordable**: you can stand up a production-sized copy, run a real load test against real capacity, and delete it the same afternoon, paying only for those hours. In a data centre the test environment is a permanent capital asset, so it is inevitably built smaller than production — and a load test against a smaller environment does not answer the question you asked.

**Q6.5** — Any three of: **version it** (`git log` on your architecture, with authorship and rationale); **review it** (a pull request on infrastructure, before it exists); **revert it** (redeploy the previous commit); **replicate it** (identical stacks in another region or account); **test it** (`validate-template`, linting, policy-as-code in CI); **audit drift** against it (Exercise 6, step 7); **parameterise it** (one template, many environments).

### Exercise 7

**Q7.1** — A stop condition is the **automatic abort**: a CloudWatch alarm that halts the experiment and rolls back the injected fault the moment the blast radius exceeds what you agreed to. Its purpose is to make the difference between an *experiment* and an *outage* a property of the system rather than of the engineer's reaction time. Without it, an FIS run is simply a self-inflicted incident with no bound on duration or scope.

**Q7.2** — For example: *"When one instance in `clf-1-2-asg` is stopped, the group returns to two healthy `InService` instances within 5 minutes, and no client request fails."* "We expect the system to be fine" is not a hypothesis because it names no **trigger**, no **measurable outcome** and no **time bound** — so no result can falsify it, and the game day cannot teach you anything.

**Q7.3** — The practice is owned by **Operational Excellence** — game days are an operational routine, and their real output is learning, updated runbooks and better-rehearsed responders. What they *validate* is **Reliability** — whether the recovery mechanisms actually work under the conditions claimed. The split matters because a game day that produces a green result but no learning has only done half its job.

**Q7.4** — Exercise 3 tested the *mechanism* in isolation, under ideal conditions, with no load, no dependencies and an engineer watching. A game day tests the **whole socio-technical system**: does the alarm fire, does it page the right person, is the runbook current, does the replacement instance pass the *application's* health check and not just EC2's, does the load balancer drain connections, does the on-call engineer know what "healthy" looks like? Nearly every real incident is a failure of one of those, not of the documented mechanism.

**Q7.5** — It rehearses **dependency and control-plane failure** — an AWS API returning errors to *your* code — rather than the loss of a compute node. Stopping an instance tests whether you can lose capacity; injecting API errors tests whether your retry logic, exponential backoff, timeouts, circuit breakers and graceful degradation are correct. That exercises **"How do you design interactions in a distributed system to mitigate or withstand failures?"** (and its prevention counterpart).

### Exercise 8

**Q8.1** — No. `UNANSWERED` means **"unknown"**, not "acceptable." It is the tool refusing to make a claim you have not made, and an honest review treats unanswered questions as unassessed risk. The distinction matters because a screenshot of a review with zero HIGH risks is meaningless unless the answered count is also shown.

**Q8.2** — `UNANSWERED` means *you have not assessed this yet* — it is a gap in the review. `NOT_APPLICABLE` means *you have assessed it and the question does not apply to this workload*, with a recorded reason. A legitimate example: a workload with no persistent data of its own — a stateless image-resizing service reading and writing another team's bucket — can reasonably mark backup questions not applicable, because it owns nothing to back up. `NOT_APPLICABLE` requires a justification note; without one it is `UNANSWERED` wearing a disguise.

**Q8.3** — A milestone is an **immutable snapshot of the review at a point in time**. It exists so that the next review has a baseline to compare against — you can show that fourteen HIGH risks became three, and connect that to specific work. It serves **"drive architectures using data"**: it converts architectural quality from an opinion into a measured trend over time.

**Q8.4** — Three examples: **(1)** it applies a consistent, AWS-authored set of questions so review quality does not depend on which architect happens to be in the room; **(2)** it produces a **prioritised improvement plan** with links to specific best-practice guidance, turning the review into a backlog rather than a document; **(3)** it **quantifies risk per pillar** and, via milestones, tracks it over time, making architectural debt visible to people who do not read architecture diagrams. It is also **free**, and it can be run at any lifecycle stage — before build, before launch, and periodically in production.

**Q8.5** — Address the **Security** HIGHs first. The framework treats the pillars as trade-offs to be balanced deliberately rather than as an equal-weight scoring rubric — but security risks are generally not tradeable in the way that cost, performance and even some reliability risks are: a cost overrun is recoverable, a data breach is not. The honest general answer is that priority follows **business impact and risk tolerance**, and that trade-offs must be **explicit and recorded** (the `--notes` field exists for exactly this) rather than implied by a number.

### Exercise 9

**Step 1 — the table:**

| # | Pillar | Principle / skill |
|---|---|---|
| 1 | Reliability | **Decoupling components** (versus monolithic) — the producer survives the consumer's absence |
| 2 | Performance Efficiency | **Think parallel** |
| 3 | Reliability | **Design for failure** — multi-AZ fault isolation, high availability |
| 4 | Cost Optimization | **Implement elasticity** — scale to demand, pay for what you use |
| 5 | Operational Excellence | **Improve through game days** |
| 6 | Operational Excellence | **Automate to make experimentation easier** / allow evolutionary architectures (operations as code) |
| 7 | Performance Efficiency | **Drive architectures using data** (right-sizing) |
| 8 | Security | Least privilege with temporary credentials; traceability |
| 9 | Sustainability | Minimise environmental impact — region and scheduling choice |
| 10 | Operational Excellence | Perform operations as code — automate to make change repeatable |
| 11 | Cost Optimization | **Stop guessing your capacity needs** |
| 12 | Reliability | **Test systems at production scale** |

**Step 2 — second pillars and trade-offs:**

- **Row 1** — also **Performance Efficiency**: the queue lets each tier scale independently at its own rate. Trade-off: the decoupling buys resilience and independent scaling at the price of **eventual consistency and possible out-of-order or duplicate delivery**, which pushes idempotency work onto the consumer.
- **Row 3** — also **Cost Optimization**: six instances across three AZs cost roughly three times two instances in one AZ. Trade-off: **availability is bought with redundant, partly idle capacity**; the correct spend follows from a stated availability target, not from instinct.
- **Row 4** — also **Reliability**: scaling in reduces the surviving capacity buffer, so an unexpected 03:00 traffic spike or an AZ event now hits a much smaller fleet. Trade-off: **cost savings against headroom**; the mitigation is a floor (`MinSize`) sized for the failure you must survive, not for the demand you expect. **Sustainability** has a third claim.
- **Row 7** — also **Cost Optimization** and **Sustainability**: right-sizing to a smaller, more efficient instance family cuts spend and energy simultaneously. Trade-off: less headroom for spikes and a possible architecture change (`m6g` is Graviton/arm64, so the workload must be rebuilt for that architecture) — a migration cost paid once against a recurring saving.

**Q9.1** — **High availability** is redundancy across fault domains so that *failure* does not cause an outage — the instance count is sized for survival, and it does not vary with traffic. **Elasticity** is varying capacity so that *demand* is met without over-provisioning — the count tracks load. Row 3 changes nothing when traffic changes; row 4 changes nothing when an instance dies. The same Auto Scaling group implements both because `MinSize` encodes the availability requirement while `DesiredCapacity` tracks the demand — which is exactly why confusing them leads to `MinSize=1` fleets that scale beautifully and fail completely.

**Q9.2** — **"Stop guessing your capacity needs."** It replaces **capital expenditure (CapEx)** — buying peak-sized hardware years in advance and amortising it — with **operational expenditure (OpEx)**, paying for consumed capacity as demand reveals itself. The eliminated failure modes are the two symmetric guesses: over-provisioning (idle capital) and under-provisioning (lost business).

**Q9.3** — **Design for failure: row 3.** The architecture assumes components will die and spreads them across independent fault domains *before* anything fails, which is the definition of the principle. The runner-up is row 5 (game days), but that *verifies* design for failure rather than being it — you cannot rehearse a recovery that was never designed. **Think parallel: row 2.** Splitting one job into 500 simultaneous chunks is the principle in its purest form. The runner-up is row 4, but scaling a fleet to match demand is elasticity: the instances are handling *different* requests, not cooperating on one job. Parallelism decomposes a single unit of work; elasticity sizes capacity for many.

**Q9.4** — Any of: adopt **managed and serverless services** so utilisation is pooled across customers instead of sitting idle in your account; move to **more energy-efficient instance types** such as Graviton; apply **S3 lifecycle policies** to move cold data to colder storage classes and delete what has no owner; **right-size** over-provisioned instances (row 7 again, from the sustainability angle); reduce data transferred by compressing payloads and caching at the edge with CloudFront. Each reduces the resources provisioned per unit of work delivered, which is the Sustainability pillar's actual measure.

</details>

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- General design principles — https://docs.aws.amazon.com/wellarchitected/latest/framework/general-design-principles.html
- Operational Excellence pillar — https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html
- Security pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- Reliability pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Performance Efficiency pillar — https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Cost Optimization pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Sustainability pillar — https://docs.aws.amazon.com/wellarchitected/latest/sustainability-pillar/sustainability-pillar.html
- AWS Well-Architected Tool User Guide — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS CLI reference, `wellarchitected` — https://docs.aws.amazon.com/cli/latest/reference/wellarchitected/
- Regions and Availability Zones (EC2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Target tracking scaling policies — https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Amazon SQS Developer Guide — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
- SQS visibility timeout — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- SQS dead-letter queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- Best practices design patterns: optimizing Amazon S3 performance — https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html
- AWS CLI S3 configuration — https://docs.aws.amazon.com/cli/latest/topic/s3-config.html
- AWS CloudFormation User Guide — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Detecting unmanaged configuration changes (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- AWS Fault Injection Service User Guide — https://docs.aws.amazon.com/fis/latest/userguide/what-is.html
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- Amazon CloudWatch User Guide — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html