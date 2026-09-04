# Topic 4.3 — Identify AWS Technical Resources and AWS Support Options

## Guided Exercises (CLF-C02, Domain 4: Billing, Pricing, and Support — 4.0% exam weight)

---

### Before You Start

**What this lab costs:** nothing. Every API called here — AWS Support, AWS Health, AWS Trusted Advisor, Service Quotas, AWS Well-Architected Tool — is free of charge. The only thing that costs money in this domain is the **Support plan subscription itself**, and you will *not* be asked to buy one. Several exercises are designed to be run from a **Basic** or **Developer** account precisely so you can observe the failure mode.

**Environment:**

```bash
aws --version
# aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.rpm
```

**IAM permissions.** Attach the AWS managed policy `AWSSupportAccess` to your principal (it grants `support:*`), plus read access for the rest:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Topic43Lab",
      "Effect": "Allow",
      "Action": [
        "support:Describe*",
        "support:Create*",
        "support:Add*",
        "support:Resolve*",
        "trustedadvisor:List*",
        "trustedadvisor:Get*",
        "health:Describe*",
        "servicequotas:List*",
        "servicequotas:Get*",
        "servicequotas:RequestServiceQuotaIncrease",
        "wellarchitected:List*",
        "wellarchitected:Get*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Critical mechanical detail — the endpoint.** AWS Support and AWS Health expose **global endpoints homed in `us-east-1`** (`support.us-east-1.amazonaws.com`, `health.us-east-1.amazonaws.com`). If you run these commands with `--region eu-west-1` you will get an endpoint resolution or authorization error that looks like a permissions problem but is not. Pin the region explicitly in every Support/Health call.

---

## Exercise 1 — Fingerprint Your Account's Support Plan from the CLI

The console shows your plan on a page. The interesting question is how software discovers it, because that is what tells you which capabilities exist in this account.

### Steps

1. Confirm which identity you are operating as:

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "AIDA4XMPLQ7EXAMPLE3K",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/lab-operator"
}
```

2. Probe the AWS Support API with its cheapest read operation. `DescribeSeverityLevels` returns a static list and is the canonical entitlement probe:

```bash
aws support describe-severity-levels \
  --language en \
  --region us-east-1
```

3. **If the account has Business, Enterprise On-Ramp, or Enterprise Support**, you get the severity ladder:

```json
{
    "severityLevels": [
        { "code": "low",      "name": "General guidance" },
        { "code": "normal",   "name": "System impaired" },
        { "code": "high",     "name": "Production system impaired" },
        { "code": "urgent",   "name": "Production system down" },
        { "code": "critical", "name": "Business-critical system down" }
    ]
}
```

4. **If the account is on Basic or Developer**, the same call fails — and the exception name is the whole lesson:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeSeverityLevels operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

5. Wrap the probe in a reusable entitlement check:

```bash
if aws support describe-severity-levels --region us-east-1 >/dev/null 2>&1; then
  echo "Support API available -> Business / Enterprise On-Ramp / Enterprise"
else
  echo "Support API unavailable -> Basic or Developer"
fi
```

6. Enumerate the service/category taxonomy the Support console uses to route your case. This is what populates the two dropdowns when you file a ticket (Business+ only):

```bash
aws support describe-services \
  --language en \
  --region us-east-1 \
  --query 'services[?contains(name, `Elastic Compute Cloud`)]' \
  --output json
```

```json
[
    {
        "code": "amazon-elastic-compute-cloud-linux",
        "name": "Amazon Elastic Compute Cloud (Linux)",
        "categories": [
            { "code": "instance-issue",    "name": "Instance Issue" },
            { "code": "connectivity",      "name": "Connectivity" },
            { "code": "performance",       "name": "Performance" },
            { "code": "ami",               "name": "AMI" },
            { "code": "ebs",               "name": "EBS" }
        ]
    }
]
```

7. Count how many top-level services the API can route to:

```bash
aws support describe-services --language en --region us-east-1 \
  --query 'length(services)'
```

```
267
```

### Comprehension Check — Block 1

1. `SubscriptionRequiredException` was returned. Name the **two** Support plans that produce it, and explain why an `AccessDeniedException` would have meant something entirely different.
2. You are on **Basic** Support. Can you open **any** case at all with AWS? If yes, what kind, and through which interface?
3. Why does `aws support describe-severity-levels --region sa-east-1` fail even on an Enterprise account?
4. A developer attaches `ReadOnlyAccess` to a role and is surprised that `describe-cases` still fails on a Business-plan account. What is the most likely cause, and which managed policy fixes it?
5. Your account was just upgraded from Developer to Business. Do you need to change any code in your case-automation tooling for it to start working?

---

## Exercise 2 — Severity Codes, Response-Time Targets, and Case Construction

Severity is not a feeling. It is an API field with a contractual response-time target attached, and choosing it wrong is the single most common way teams waste their Support entitlement.

### Steps

1. Build the mapping table you must have memorized. The `code` column is what the API accepts; the `name` column is what the console displays:

| API `severityCode` | Console name | Meaning in production terms |
|---|---|---|
| `low` | General guidance | A question. Nothing is broken. |
| `normal` | System impaired | Non-critical functions behaving abnormally. |
| `high` | Production system impaired | Production is degraded but serving. |
| `urgent` | Production system down | Production is unavailable. |
| `critical` | Business-critical system down | Business-critical system unavailable; material revenue/regulatory impact. |

2. Overlay the **first-response time targets** per plan. Note which cells are empty — an empty cell means the severity cannot be selected at all on that plan:

| Severity | Basic | Developer | Business | Enterprise On-Ramp | Enterprise |
|---|---|---|---|---|---|
| `low` — General guidance | — | < 24 business hours | < 24 h | < 24 h | < 24 h |
| `normal` — System impaired | — | < 12 business hours | < 12 h | < 12 h | < 12 h |
| `high` — Production impaired | — | — | < 4 h | < 4 h | < 4 h |
| `urgent` — Production down | — | — | < 1 h | < 1 h | < 1 h |
| `critical` — Business-critical down | — | — | — | < 30 min | < 15 min |

Two structural facts hide in this table: **Developer caps at `normal` and its clock runs on business hours only** (12x5, English, email to Cloud Support Associates), while **Business and above are 24x7 with phone, chat, and email to Cloud Support Engineers**. Basic has no technical-support row at all.

3. Generate a case skeleton **without submitting anything**. `--generate-cli-skeleton` is a client-side operation — no API call, no case, no charge:

```bash
aws support create-case --generate-cli-skeleton > case.json
cat case.json
```

```json
{
    "subject": "",
    "serviceCode": "",
    "severityCode": "",
    "categoryCode": "",
    "communicationBody": "",
    "ccEmailAddresses": [],
    "language": "",
    "issueType": "",
    "attachmentSetId": ""
}
```

4. Fill it in as a well-formed production ticket. Notice `issueType` — it takes `technical` or `customer-service`, and that field is exactly the Basic-plan boundary:

```json
{
    "subject": "ALB 502s on prod-checkout after target group re-registration",
    "serviceCode": "elastic-load-balancing",
    "severityCode": "high",
    "categoryCode": "application-load-balancer",
    "communicationBody": "Since 2026-09-04T14:10Z, arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/prod-checkout/50dc6c495c0c9188 returns HTTP 502 for ~7% of requests. TargetGroup prod-checkout-tg reports 6/6 healthy. ELB access logs show target_status_code '-' with elb_status_code 502 and target_processing_time -1. Instances i-0abcd1234efgh5678 and i-09876fedcba54321 show no application-level errors. Request: confirm whether the LB nodes are terminating connections before the target responds, and identify the reset reason.",
    "ccEmailAddresses": ["sre-oncall@example.com"],
    "language": "en",
    "issueType": "technical"
}
```

5. Submit it **only if you have a real issue and a Business+ plan**. Otherwise skip this step — a live case consumes a human engineer's time:

```bash
aws support create-case --cli-input-json file://case.json --region us-east-1
```

```json
{
    "caseId": "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8"
}
```

6. Enumerate and inspect cases without touching the console:

```bash
aws support describe-cases \
  --include-resolved-cases \
  --max-results 10 \
  --region us-east-1 \
  --query 'cases[].{Id:displayId,Sev:severityCode,Status:status,Subject:subject}' \
  --output table
```

```
------------------------------------------------------------------------------
|                               DescribeCases                                |
+-------------+--------+---------------------+-------------------------------+
|     Id      |  Sev   |       Status        |            Subject            |
+-------------+--------+---------------------+-------------------------------+
|  9876543210 |  high  |  work-in-progress   |  ALB 502s on prod-checkout... |
|  9876543201 |  low   |  resolved           |  Clarify S3 Intelligent-Tie...|
+-------------+--------+---------------------+-------------------------------+
```

7. Read the conversation thread and reply programmatically:

```bash
aws support describe-communications \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --region us-east-1 \
  --query 'communications[].{When:timeCreated,From:submittedBy}' \
  --output table

aws support add-communication-to-case \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --communication-body "Attaching ELB access log sample for 14:10-14:25Z." \
  --region us-east-1
```

8. Close it when done — resolving frees the engineer and stops the follow-up cadence:

```bash
aws support resolve-case \
  --case-id "case-111122223333-muen-2026-a1b2c3d4e5f6g7h8" \
  --region us-east-1
```

```json
{
    "initialCaseStatus": "work-in-progress",
    "finalCaseStatus": "resolved"
}
```

### Comprehension Check — Block 2

6. A customer on **Developer** Support submits `--severity-code urgent`. What happens, and what is the highest severity they can actually select?
7. Your payment-authorization service is fully down at 03:00 on a Sunday. You are on **Business** Support. What is the highest severity available to you and what response-time target does it carry? Which plan would have given you a 15-minute target?
8. The response-time targets are for **first response**. Explain, in production terms, why "first response in under 1 hour" is *not* the same as "resolution in under 1 hour," and what that implies for your own incident runbook.
9. Which single field in the `create-case` skeleton determines whether a **Basic**-plan account is permitted to open the case, and what value must it hold?
10. Why is `--generate-cli-skeleton` safe to run on any account, at any hour, on any plan?

---

## Exercise 3 — AWS Trusted Advisor: The Automated Advisor

Trusted Advisor is the exam's canonical example of an **AWS technical resource that inspects your account** rather than one you read. It evaluates your live configuration against AWS best practices across six pillars.

### Steps

1. List every check the account can see, grouped by category:

```bash
aws support describe-trusted-advisor-checks \
  --language en \
  --region us-east-1 \
  --query 'checks[].category' \
  --output text | tr '\t' '\n' | sort | uniq -c | sort -rn
```

```
     49 cost_optimizing
     41 security
     38 fault_tolerance
     19 performance
     14 service_limits
      9 operational_excellence
```

Your counts will differ — AWS adds and retires checks continuously. What matters is the **six category names**, because those are the categories the exam names.

2. Isolate one check and capture its opaque `id`. Never hardcode a check ID you copied from a blog post; derive it:

```bash
CHECK_ID=$(aws support describe-trusted-advisor-checks \
  --language en --region us-east-1 \
  --query "checks[?name=='IAM Access Key Rotation'].id | [0]" \
  --output text)
echo "$CHECK_ID"
```

```
DqdJqYeRm5
```

3. Force a fresh evaluation. Checks are cached; a refresh is asynchronous and rate-limited per check:

```bash
aws support refresh-trusted-advisor-check --check-id "$CHECK_ID" --region us-east-1
```

```json
{
    "status": {
        "checkId": "DqdJqYeRm5",
        "status": "enqueued",
        "millisUntilNextRefreshable": 0
    }
}
```

4. Poll until the refresh lands, then read the verdict:

```bash
aws support describe-trusted-advisor-check-refresh-statuses \
  --check-ids "$CHECK_ID" --region us-east-1 \
  --query 'statuses[0].status'
```

```
"success"
```

```bash
aws support describe-trusted-advisor-check-result \
  --check-id "$CHECK_ID" --language en --region us-east-1 \
  --query 'result.{Status:status,Summary:resourcesSummary}'
```

```json
{
    "Status": "warning",
    "Summary": {
        "resourcesProcessed": 14,
        "resourcesFlagged": 3,
        "resourcesIgnored": 0,
        "resourcesSuppressed": 0
    }
}
```

The `status` vocabulary is `ok` (green), `warning` (yellow), `error` (red), and `not_available`.

5. Get a whole-account roll-up in one call — this is the console's summary bar, in JSON:

```bash
aws support describe-trusted-advisor-check-summaries \
  --check-ids $(aws support describe-trusted-advisor-checks --language en \
      --region us-east-1 --query 'checks[?category==`service_limits`].id' \
      --output text | tr '\t' ' ') \
  --region us-east-1 \
  --query 'summaries[?status!=`ok`].{Check:checkId,Status:status,Flagged:resourcesSummary.resourcesFlagged}' \
  --output table
```

6. Try the **newer, dedicated Trusted Advisor API** (distinct from the legacy `support` namespace), which speaks in recommendations rather than raw checks:

```bash
aws trustedadvisor list-recommendations \
  --region us-east-1 \
  --max-results 5 \
  --query 'recommendationSummaries[].{Name:name,Pillar:pillars[0],Status:status}' \
  --output table
```

7. Now the entitlement boundary. On a **Basic** or **Developer** account, steps 1–6 fail with `SubscriptionRequiredException` — *the API is Business+ only*. But open the console at `https://console.aws.amazon.com/trustedadvisor/` on the same Basic account and you will still see results: **all Service Quotas checks plus a core set of security checks**. The full six-category catalogue and all programmatic access require Business, Enterprise On-Ramp, or Enterprise.

### Comprehension Check — Block 3

11. Name the six Trusted Advisor check categories.
12. A Basic-plan customer says "Trusted Advisor is broken, the CLI returns an error, but my colleague sees checks in the console." Reconcile both observations in one sentence.
13. Which Trusted Advisor category would flag *"you are at 92% of your Running On-Demand Standard instances quota in us-east-1"*, and which would flag *"your RDS instance has no Multi-AZ standby"*?
14. `refresh-trusted-advisor-check` returned `millisUntilNextRefreshable: 254000`. What does that tell you, and what should your polling loop do?
15. **Trusted Advisor Priority** and a **designated Technical Account Manager** — which Support plan is required for each?

---

## Exercise 4 — AWS Health: Service Health vs. *Your* Health

Students conflate two different dashboards. They answer different questions and one of them is personalized to your account.

### Steps

1. Open the **public** view — AWS Health Dashboard *Service health*, at `https://health.aws.amazon.com/health/status`. No sign-in. It reports the general status of AWS services per Region. It answers: *"Is AWS having a problem?"*

2. Open the **personalized** view — AWS Health Dashboard *Your account health*, at `https://health.aws.amazon.com/health/home`, signed in. It answers a strictly narrower and far more useful question: *"Is AWS having a problem **that touches resources in my account**, and do I have scheduled changes coming?"* This view is available on **all Support plans, including Basic**.

3. Query it programmatically. The AWS Health API is **Business, Enterprise On-Ramp, and Enterprise only**, and it lives on the `us-east-1` global endpoint:

```bash
aws health describe-events \
  --region us-east-1 \
  --filter eventStatusCodes=open,upcoming \
  --query 'events[].{Service:service,Region:region,Type:eventTypeCategory,Code:eventTypeCode,Start:startTime}' \
  --output table
```

```
--------------------------------------------------------------------------------------------
|                                     DescribeEvents                                       |
+---------+-------------+------------------------+------------------------------+----------+
| Service |   Region    |         Type           |            Code              |  Start   |
+---------+-------------+------------------------+------------------------------+----------+
|  EC2    | us-east-1   | scheduledChange        | AWS_EC2_INSTANCE_RETIREMENT..| 2026-09..|
|  RDS    | eu-west-1   | accountNotification    | AWS_RDS_MAINTENANCE_SCHEDU...| 2026-09..|
+---------+-------------+------------------------+------------------------------+----------+
```

The `eventTypeCategory` vocabulary is the key concept: `issue` (AWS is degraded), `scheduledChange` (AWS will change something on a date), `accountNotification` (informational, account-specific), and `investigation`.

4. Pivot from *"an event exists"* to *"which of my resources are in it"* — this is the entire point of the personalized dashboard:

```bash
ARN=$(aws health describe-events --region us-east-1 \
  --filter eventTypeCategories=scheduledChange,eventStatusCodes=upcoming \
  --query 'events[0].arn' --output text)

aws health describe-affected-entities \
  --region us-east-1 \
  --filter "eventArns=$ARN" \
  --query 'entities[].{Resource:entityValue,Status:statusCode}' \
  --output table
```

```
-------------------------------------------
|         DescribeAffectedEntities        |
+-------------------------+---------------+
|        Resource         |    Status     |
+-------------------------+---------------+
|  i-0abcd1234efgh5678    |  IMPAIRED     |
|  i-09876fedcba54321     |  UNIMPAIRED   |
+-------------------------+---------------+
```

5. Get the human-readable narrative AWS publishes for that event:

```bash
aws health describe-event-details --region us-east-1 --event-arns "$ARN" \
  --query 'successfulSet[0].eventDescription.latestDescription' --output text
```

6. Roll up counts for a status page or a weekly review:

```bash
aws health describe-event-aggregates \
  --region us-east-1 \
  --aggregate-field eventTypeCategory \
  --filter eventStatusCodes=open \
  --output table
```

7. On **Basic** or **Developer**, every command in steps 3–6 fails:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeEvents operation: AWS Premium Support Subscription is required
to use this service.
```

…while the personalized **console** dashboard in step 2 keeps working. Same split as Trusted Advisor: console yes, API no.

### Comprehension Check — Block 4

16. A Region-wide S3 event is in progress. Which dashboard tells you *whether your buckets are affected*, and which tells you only *that AWS has an issue*?
17. Your EC2 instance is scheduled for retirement in nine days. Which `eventTypeCategory` carries that, and which dashboard surfaces it **without** a paid Support plan?
18. You want an EventBridge rule to page on-call whenever AWS publishes an `issue` event touching your account. Which Support plans make that possible, and why is the minimum plan the same one that unlocks the Health API?
19. Explain why `describe-events` with `--region eu-central-1` is the wrong call even for an Enterprise account with all its workloads in Frankfurt.

---

## Exercise 5 — Service Quotas: The Technical Resource That Replaced a Support Case

Historically, raising a limit meant filing a ticket. Service Quotas turned most of that into a self-service API — and it works on **every** Support plan, Basic included. This is a favorite exam distractor.

### Steps

1. Find the service code, then the quota code. Both are opaque strings and both must be looked up, never guessed:

```bash
aws service-quotas list-services --region us-east-1 \
  --query 'Services[?contains(ServiceName, `Elastic Compute`)]' --output table
```

```
--------------------------------------------------------------
|                        ListServices                        |
+--------------+---------------------------------------------+
| ServiceCode  |                ServiceName                  |
+--------------+---------------------------------------------+
|  ec2         |  Amazon Elastic Compute Cloud (Amazon EC2)  |
+--------------+---------------------------------------------+
```

2. Locate the quota that actually gates your scale-out. Note it is measured in **vCPUs**, not instances — a classic production trap:

```bash
aws service-quotas list-service-quotas \
  --service-code ec2 --region us-east-1 \
  --query "Quotas[?contains(QuotaName, 'On-Demand Standard')].{Code:QuotaCode,Name:QuotaName,Value:Value,Unit:Unit,Adjustable:Adjustable}" \
  --output json
```

```json
[
    {
        "Code": "L-1216C47A",
        "Name": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
        "Value": 64.0,
        "Unit": "None",
        "Adjustable": true
    }
]
```

3. Compare the **applied** value against the AWS **default**. They differ whenever someone has already raised it:

```bash
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region us-east-1 \
  --query 'Quota.{Applied:Value,Adjustable:Adjustable,Global:GlobalQuota}'

aws service-quotas get-aws-default-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region us-east-1 \
  --query 'Quota.Value'
```

```json
{ "Applied": 64.0, "Adjustable": true, "Global": false }
```
```
5.0
```

4. Request an increase. No Support plan required, no console:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 256 \
  --region us-east-1
```

```json
{
    "RequestedQuota": {
        "Id": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6",
        "ServiceCode": "ec2",
        "QuotaCode": "L-1216C47A",
        "DesiredValue": 256.0,
        "Status": "PENDING",
        "Created": "2026-09-04T15:22:41.310000-03:00",
        "Requester": "{\"accountId\":\"111122223333\"}"
    }
}
```

5. Track it. `CASE_OPENED` means Service Quotas escalated your request into an actual Support case on your behalf:

```bash
aws service-quotas list-requested-service-quota-change-history \
  --service-code ec2 --region us-east-1 \
  --query 'RequestedQuotas[].{Quota:QuotaName,Want:DesiredValue,Status:Status}' \
  --output table
```

```
---------------------------------------------------------------------------
|             ListRequestedServiceQuotaChangeHistory                      |
+----------------------------------------+---------+----------------------+
|                 Quota                  |  Want   |       Status         |
+----------------------------------------+---------+----------------------+
|  Running On-Demand Standard instances  |  256.0  |  CASE_OPENED         |
+----------------------------------------+---------+----------------------+
```

6. Wire proactive alerting instead of discovering the ceiling during a traffic spike. Service Quotas publishes utilization to CloudWatch under `AWS/Usage`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name ec2-standard-vcpu-at-80pct \
  --namespace AWS/Usage \
  --metric-name ResourceCount \
  --dimensions Name=Service,Value=EC2 Name=Resource,Value=vCPU \
               Name=Type,Value=Resource Name=Class,Value=Standard/OnDemand \
  --statistic Maximum --period 300 --evaluation-periods 1 \
  --threshold 51 --comparison-operator GreaterThanOrEqualToThreshold \
  --region us-east-1
```

7. Cross-check the same ground truth from the other direction — Trusted Advisor's `service_limits` category (Business+) reports the same headroom:

```bash
aws support describe-trusted-advisor-check-result \
  --check-id eW7HH0l7J9 --language en --region us-east-1 \
  --query 'result.flaggedResources[?metadata[3]!=null].metadata' --output json
```

### Comprehension Check — Block 5

20. Your account is on **Basic** Support and you need the EC2 vCPU quota raised. Is this possible? Through which mechanism, and does it require buying a plan?
21. `Adjustable: false` came back for a quota. What are your options?
22. `Value` reads `64.0` but `get-aws-default-service-quota` reads `5.0`. What does that tell you about the account's history?
23. A request sat at `PENDING` and then moved to `CASE_OPENED`. What actually happened behind the scenes, and where can you now read the human correspondence?
24. Trusted Advisor's `service_limits` check and the Service Quotas console both report EC2 headroom. Which one can *change* the value, and which is only an observer?

---

## Exercise 6 — Self-Service Technical Resources: Documentation, Guidance, and Tooling

These are free, unlimited, and available on every plan. The exam expects you to route a question to the *right* one.

### Steps

1. Walk the catalogue and record what each is **for**, not just what it is called:

| Resource | URL | The question it answers |
|---|---|---|
| AWS Documentation | `https://docs.aws.amazon.com/` | "What are this API's parameters, limits, and exact behavior?" |
| AWS Whitepapers & Guides | `https://aws.amazon.com/whitepapers/` | "What is AWS's formal position on security, DR, or migration?" |
| AWS Architecture Center | `https://aws.amazon.com/architecture/` | "What is a reference architecture for this pattern?" |
| AWS Well-Architected Framework | `https://aws.amazon.com/architecture/well-architected/` | "What are the six pillars, and does my workload honor them?" |
| AWS Prescriptive Guidance | `https://aws.amazon.com/prescriptive-guidance/` | "Give me a step-by-step, opinionated migration/modernization plan." |
| AWS Solutions Library | `https://aws.amazon.com/solutions/` | "Is there a vetted, deployable CloudFormation stack for this?" |
| AWS re:Post | `https://repost.aws/` | "Has another customer (or an AWS expert) solved this?" — community Q&A, replaced the AWS Forums |
| AWS Knowledge Center | `https://repost.aws/knowledge-center/` | "What is the canonical answer to this frequently-asked support question?" |
| AWS Blogs | `https://aws.amazon.com/blogs/` | "How do I use a feature announced last month?" |
| AWS Skill Builder | `https://skillbuilder.aws/` | "Where do I train and take practice exams?" |
| AWS Marketplace | `https://aws.amazon.com/marketplace/` | "Can I buy and deploy third-party software with AWS billing?" |
| AWS Pricing Calculator | `https://calculator.aws/` | "What will this architecture cost before I build it?" |

2. Run the Well-Architected Tool from the CLI — it is a real, free AWS service, not a PDF:

```bash
aws wellarchitected list-lenses --region us-east-1 \
  --query 'LensSummaries[].{Alias:LensAlias,Name:LensName}' --output table
```

```
----------------------------------------------------------------------
|                            ListLenses                              |
+---------------------------------+----------------------------------+
|              Alias              |              Name                |
+---------------------------------+----------------------------------+
|  wellarchitected                |  AWS Well-Architected Framework  |
|  serverless                     |  Serverless Lens                 |
|  softwareasaservice             |  SaaS Lens                       |
|  foundationaltechnicalreview    |  FTR Lens                        |
+---------------------------------+----------------------------------+
```

3. Define a workload and attach the framework lens:

```bash
aws wellarchitected create-workload \
  --workload-name prod-checkout \
  --description "Customer-facing checkout API" \
  --environment PRODUCTION \
  --aws-regions us-east-1 \
  --lenses wellarchitected \
  --review-owner "sre-oncall@example.com" \
  --region us-east-1
```

```json
{
    "WorkloadId": "9a1b2c3d4e5f60718293a4b5c6d7e8f9",
    "WorkloadArn": "arn:aws:wellarchitected:us-east-1:111122223333:workload/9a1b2c3d4e5f60718293a4b5c6d7e8f9"
}
```

4. Pull the review questions and the current risk profile:

```bash
aws wellarchitected list-lens-review-improvements \
  --workload-id 9a1b2c3d4e5f60718293a4b5c6d7e8f9 \
  --lens-alias wellarchitected --region us-east-1 \
  --query 'ImprovementSummaries[].{Pillar:PillarId,Question:QuestionTitle,Risk:Risk}' \
  --output table
```

```
-----------------------------------------------------------------------------
|                     ListLensReviewImprovements                            |
+---------------+--------------------------------------------+--------------+
|    Pillar     |                 Question                   |     Risk     |
+---------------+--------------------------------------------+--------------+
|  reliability  |  How do you back up data?                  |  HIGH        |
|  security     |  How do you manage identities for people?  |  MEDIUM      |
|  operational- |  How do you reduce defects and improve...  |  MEDIUM      |
+---------------+--------------------------------------------+--------------+
```

5. Clean up so you do not leave a stale review behind:

```bash
aws wellarchitected delete-workload \
  --workload-id 9a1b2c3d4e5f60718293a4b5c6d7e8f9 \
  --client-request-token "$(uuidgen)" --region us-east-1
```

### Comprehension Check — Block 6

25. A junior engineer asks *"what does the `--dry-run` flag do on `RunInstances`?"* Route them to exactly one resource and justify it in a sentence.
26. Your CTO asks for AWS's official stance on shared-responsibility boundaries for a compliance audit. Which resource, and why not re:Post?
27. Distinguish **AWS re:Post** from the **AWS Knowledge Center** and from a **Support case**. What is the escalation order among the three?
28. The Well-Architected Tool returned `Risk: HIGH` for "How do you back up data?". Is this a bill, a warning, or an enforcement action? What does the tool actually do to your infrastructure?
29. You need a production-ready, AWS-vetted CloudFormation deployment for a centralized-logging pattern. Architecture Center or Solutions Library — which one, and what is the difference?

---

## Exercise 7 — People and Partners: When Software Is Not the Answer

Some problems are not answered by an API. The exam tests whether you know which human organization owns which problem.

### Steps

1. Study the human/organizational catalogue:

| Resource | What it is | Availability |
|---|---|---|
| **AWS Support Engineers** (Cloud Support Associates / Engineers) | Reactive technical troubleshooting via cases | Developer (Associates, business hours) / Business+ (Engineers, 24x7) |
| **Technical Account Manager (TAM)** | Proactive, named advocate: architecture guidance, operational reviews, launch planning, escalation | **Pool of TAMs** on Enterprise On-Ramp; **designated TAM** on Enterprise |
| **AWS Concierge Support Team** | Billing and account experts; non-technical account/billing analysis | Enterprise On-Ramp and Enterprise |
| **AWS Professional Services (ProServe)** | Paid, project-based global consulting team that builds *with* you | Any customer; separate engagement and cost |
| **AWS Partner Network (APN)** | Third-party firms: **Consulting Partners** (services/implementation) and **Technology Partners** (software/ISVs) | Any customer |
| **AWS Managed Services (AMS)** | AWS operates your infrastructure for you — patching, monitoring, incident management, change control | Paid subscription; requires Enterprise Support |
| **AWS IQ** | Marketplace for short-term, on-demand engagements with AWS Certified freelancers/firms | Any customer (US-based experts) |
| **AWS Activate** | Startup program: credits, technical guidance, training | Eligible startups |
| **AWS Solutions Architects (SAs)** | Pre-sales/design architects assigned via your account team | Account-team dependent |
| **AWS Trust & Safety / Abuse team** | Handles abuse *originating from* or *targeting* AWS resources | Any customer, any plan |
| **AWS Countdown** (formerly Infrastructure Event Management) | Guided planning + real-time support for a specific high-traffic event or migration | Included with Enterprise; add-on fee for Business |
| **AWS Incident Detection and Response (IDR)** | Proactive monitoring with a 5-minute engagement SLA on your critical workloads | Enterprise Support (paid add-on) |
| **AWS Trusted Advisor Priority** | TAM-curated, prioritized Trusted Advisor findings pushed to you | Enterprise |

2. Report abuse. Note this needs **no** Support plan and is a distinct path from a technical case:

```
Console:  https://support.aws.amazon.com/#/contacts/report-abuse
Email:    abuse@amazonaws.com
API:      issueType = "customer-service", serviceCode = "customer-account"
```

3. Model your own escalation ladder for a real incident. Write it out for `prod-checkout` on an Enterprise plan:

```
T+0    Detect          CloudWatch alarm -> PagerDuty -> on-call
T+2m   Triage          AWS Health Dashboard (your account health) — is this AWS or us?
T+5m   If AWS-side     aws support create-case --severity-code critical   (< 15 min target)
T+5m   In parallel     Notify TAM directly (Slack/phone) — TAM does not replace the case,
                       the TAM escalates and coordinates the case
T+15m  AWS engaged     Cloud Support Engineer on bridge; TAM owns internal escalation
T+1h   If quota-bound  Service Quotas increase request (self-service, not a case)
T+24h  Post-incident   TAM-led operations review; Trusted Advisor Priority follow-ups
```

4. Practice routing. For each scenario, name the **single best** resource:

   a. "We need someone to physically re-platform 400 on-prem VMs to AWS over nine months, with contractual delivery milestones."
   b. "An EC2 instance in someone else's account is port-scanning our VPC."
   c. "We want AWS to run patching, backups, and change management on our accounts so our team can stop."
   d. "I need forty hours of help from a certified expert to fix our CI/CD pipeline, starting next week, without a procurement cycle."
   e. "Our invoice shows a Savings Plan allocation we do not understand, and we are on Enterprise Support."
   f. "We are launching a Super Bowl ad and expect 60x traffic for four hours on one date."
   g. "We are a seed-stage startup and need AWS credits plus architecture guidance."
   h. "We want to buy a third-party WAF and have it billed on our AWS invoice."

### Comprehension Check — Block 7

30. Distinguish a **TAM** from a **Cloud Support Engineer** in terms of *reactive vs. proactive* and *named vs. pooled*.
31. Which two Support plans include the **Concierge Support Team**, and what class of question do they own?
32. **AWS Professional Services** vs. an **APN Consulting Partner** — both do implementation work. What is the actual difference, and what do they share?
33. **AWS Managed Services (AMS)** vs. **AWS Support** — one of these operates your infrastructure. Which, and what Support plan does it presuppose?
34. Your account has no paid Support plan and you are being SSH-brute-forced from an EC2 IP. Can you report it? Through what path?
35. A customer on **Business** Support wants guided support for a one-day 60x traffic event. What is the offering called, and what is the cost implication versus Enterprise?

---

## Exercise 8 — Synthesis Drill: Route Each Signal

Run through this without looking anything up. Each line has exactly one best answer.

### Steps

1. For each situation, name **(a)** the resource or option and **(b)** the minimum Support plan required:

| # | Situation |
|---|---|
| 1 | Check whether AWS is having a Region-wide problem, from a laptop with no AWS credentials |
| 2 | Discover that a scheduled EC2 retirement will hit two of *your* instances |
| 3 | Get a first response in under 15 minutes for a revenue-stopping outage |
| 4 | Get a first response in under 30 minutes for a revenue-stopping outage |
| 5 | Automate case creation from your incident-management platform |
| 6 | Raise the S3 bucket-count quota on a free-tier account |
| 7 | Find unattached EBS volumes wasting money, account-wide, automatically |
| 8 | Ask a general "how does S3 versioning work?" question with a $29/month budget |
| 9 | Get a named human who knows your architecture and joins your quarterly reviews |
| 10 | Hire a certified expert for a two-week engagement without an RFP |
| 11 | Read AWS's formal, citable guidance on the shared responsibility model |
| 12 | Buy commercial software and have it appear on your AWS bill |
| 13 | Report that an AWS-hosted host is attacking you |
| 14 | Have AWS proactively monitor a critical workload and engage within 5 minutes |
| 15 | Score a workload against the six pillars and get a ranked risk list |

2. Verify your answers against the key below, then re-derive any you missed **from the entitlement boundary** rather than from memory — nearly every one of these is decided by one of three lines: *Basic vs. paid*, *Developer vs. Business*, or *Business vs. Enterprise*.

### Comprehension Check — Block 8

36. State the three entitlement boundaries in step 2 as one sentence each, naming what crosses at each line.
37. Two capabilities in this topic are available on **every** plan including Basic, yet students routinely assume they are paid. Name both.
38. Two capabilities are **console-visible on Basic but API-locked to Business+**. Name both and explain why AWS draws the line there.

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Compare AWS Support Plans — https://aws.amazon.com/premiumsupport/plans/
- AWS Support User Guide — https://docs.aws.amazon.com/awssupport/latest/user/
- AWS Support API Reference — https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Health User Guide — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- AWS Health Dashboard (Service health) — https://health.aws.amazon.com/health/status
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- AWS Well-Architected Tool User Guide — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS re:Post — https://repost.aws/ · Knowledge Center — https://repost.aws/knowledge-center/
- AWS Whitepapers & Guides — https://aws.amazon.com/whitepapers/
- AWS Architecture Center — https://aws.amazon.com/architecture/
- AWS Prescriptive Guidance — https://aws.amazon.com/prescriptive-guidance/
- AWS Solutions Library — https://aws.amazon.com/solutions/
- AWS Professional Services — https://aws.amazon.com/professional-services/
- AWS Managed Services — https://aws.amazon.com/managed-services/
- AWS Partner Network — https://aws.amazon.com/partners/
- AWS Marketplace — https://aws.amazon.com/marketplace/
- AWS IQ — https://aws.amazon.com/iq/ · AWS Activate — https://aws.amazon.com/activate/
- Report AWS abuse — https://support.aws.amazon.com/#/contacts/report-abuse
- AWS CLI Command Reference (`support`) — https://docs.aws.amazon.com/cli/latest/reference/support/

> Support-plan pricing and feature matrices change. Treat the plan comparison page as the authority at exam time; the response-time targets in this material reflect the published matrix as of 2026-09.

---

<details>
<summary><strong>Answer Key — click to expand</strong></summary>

### Block 1 — Support plan fingerprinting

**1.** `SubscriptionRequiredException` is returned by **Basic** and **Developer**. It is an *entitlement* error: the caller is authenticated and authorized in IAM, but the account has not purchased the feature. `AccessDeniedException` would be an *authorization* error — the account has the feature, but this principal lacks the IAM permission. The remediation is completely different: buy a plan vs. fix a policy.

**2.** Yes. Basic includes 24x7 access to **customer service** for **account and billing** questions, plus abuse reports. What Basic excludes is **technical** support cases. You file them through the Support Center console; the Support **API** is unavailable on Basic regardless of case type.

**3.** AWS Support is a **global service with its endpoint in `us-east-1`** (`support.us-east-1.amazonaws.com`). There is no `sa-east-1` Support endpoint, so the request fails at endpoint resolution or signing — not on entitlement or permissions.

**4.** `ReadOnlyAccess` historically does not confer the `support:*` actions needed for the Support API. Attach the AWS managed policy **`AWSSupportAccess`**. (Confirm the failure is `AccessDeniedException`, not `SubscriptionRequiredException` — that distinction tells you which of the two fixes applies.)

**5.** No. The API surface is identical; only the entitlement changed. The same `create-case` / `describe-cases` calls that returned `SubscriptionRequiredException` now succeed. Business additionally unlocks severities `high` and `urgent` for the `--severity-code` argument.

---

### Block 2 — Severity and case construction

**6.** Developer supports only `low` (General guidance) and `normal` (System impaired). Passing `urgent` is rejected — the Support API is unavailable on Developer entirely, and in the console the higher severities are not selectable. The highest available is **`normal` / System impaired, < 12 business hours**.

**7.** On Business the ceiling is **`urgent` / Production system down, with a < 1 hour** first-response target — 24x7, so Sunday 03:00 is fully covered. A **< 15 minute** target requires **Enterprise Support** and the `critical` / Business-critical system down severity. Enterprise On-Ramp would give **< 30 minutes**.

**8.** The target is when a Cloud Support Engineer **first responds**, not when the problem is fixed. Resolution time is unbounded and depends on the cause. Operationally this means AWS Support is a *parallel* workstream, never your primary mitigation: your runbook must still contain failover, rollback, and traffic-shifting steps that you execute yourself while the case is open.

**9.** **`issueType`**. Basic-plan accounts may only open cases with `issueType: "customer-service"` (account and billing). `issueType: "technical"` requires Developer or above — and via the API, Business or above.

**10.** `--generate-cli-skeleton` is evaluated **entirely client-side** by the AWS CLI from its bundled service model. It emits a JSON template and makes **no API call**, so it cannot fail on entitlement, cannot create a case, and consumes no engineer's time.

---

### Block 3 — Trusted Advisor

**11.** **Cost Optimization, Performance, Security, Fault Tolerance, Service Limits (Service Quotas), and Operational Excellence.**

**12.** Both are true: on Basic/Developer the Trusted Advisor **console** shows all Service Quotas checks plus a core set of security checks, while **programmatic access through the Support and Trusted Advisor APIs — and the full six-category catalogue — require Business, Enterprise On-Ramp, or Enterprise.**

**13.** The quota-headroom finding is **Service Limits**. The missing RDS Multi-AZ standby is **Fault Tolerance**.

**14.** `millisUntilNextRefreshable: 254000` means that check is **rate-limited for another ~254 seconds** and a refresh request now is a no-op. Your polling loop should read this field and back off for at least that duration rather than hammering the API — and it should poll `describe-trusted-advisor-check-refresh-statuses` (looking for `success`), not the result endpoint, to learn when the refresh landed.

**15.** **Trusted Advisor Priority: Enterprise Support only.** **Designated (named) TAM: Enterprise Support.** Enterprise On-Ramp provides a *pool* of TAMs, not a designated one.

---

### Block 4 — AWS Health

**16.** The **AWS Health Dashboard — Your account health** (personalized, signed in) tells you whether *your* buckets are affected, because it correlates the event against resources in your account. The **AWS Health Dashboard — Service health** (public, no sign-in) only reports that AWS has an issue in a Region.

**17.** `eventTypeCategory` = **`scheduledChange`**. It appears in the personalized **Your account health** console view, which is available on **all Support plans including Basic**. (The `describe-events` API that would let you automate on it is not.)

**18.** **Business, Enterprise On-Ramp, or Enterprise.** EventBridge integration for AWS Health events is backed by the same AWS Health API entitlement — programmatic access to personalized health data is a paid-plan feature, so the automation and the API unlock together at Business.

**19.** AWS Health is a **global service with its endpoint in `us-east-1`**. The `region` you pass to the CLI selects the *endpoint*, not the *scope of results*: `describe-events --region us-east-1` returns events for **all** Regions, filtered by `--filter regions=eu-central-1` if you want to narrow them. Calling `--region eu-central-1` targets a non-existent Health endpoint.

---

### Block 5 — Service Quotas

**20.** Yes, and without buying anything. **Service Quotas** (console or `request-service-quota-increase`) is available on **every** Support plan, Basic included. A quota increase is not a Support-plan feature.

**21.** `Adjustable: false` means AWS will not raise it through Service Quotas — it is a hard architectural limit. Options: re-architect around it (shard across accounts or Regions), or, for the few cases where an exception exists, open a Support case to ask — but expect the answer to be no. Do not build a design that depends on a non-adjustable quota moving.

**22.** The applied value (64) is far above the AWS default (5), so **someone already requested and received an increase on this account**. `list-requested-service-quota-change-history` will show that request and who made it. This is exactly why you compare applied vs. default before assuming you know your ceiling.

**23.** Service Quotas evaluated the request and could not auto-approve it, so it **opened an AWS Support case on your behalf** and handed it to a human for review. You read the correspondence in the **Support Center console** (or via `aws support describe-communications` if you are on Business+) — Service Quotas itself only shows the status transition.

**24.** **Service Quotas** can change the value — it owns the increase request workflow. **Trusted Advisor's Service Limits check is read-only**: it observes and warns (typically at 80% utilization) but cannot raise anything. Trusted Advisor tells you *that* you are close; Service Quotas is where you *act*.

---

### Block 6 — Self-service resources

**25.** **AWS Documentation** (`docs.aws.amazon.com`). It is the authoritative, versioned, per-parameter reference for API behavior. Nothing else in the catalogue is normative about a single flag's semantics.

**26.** **AWS Whitepapers & Guides** — specifically the *Shared Responsibility Model* content. It is AWS's formal, citable, versioned position, which an auditor will accept. **re:Post is community Q&A**: useful, often accurate, but individual answers are not AWS's official position and are not citable in a compliance package.

**27.** **re:Post** is the community Q&A forum where anyone (and AWS experts) can answer. **Knowledge Center** is a curated library of canonical AWS-authored answers to the most frequent support questions — it is hosted under re:Post but is editorial, not community. A **Support case** is a private, account-specific engagement with an AWS engineer who can see your resources. Escalation order: **Documentation/Knowledge Center → re:Post → Support case**. Reach for the case only when the question depends on *your* account's state.

**28.** It is a **warning** — advisory only. The Well-Architected Tool **makes no changes to your infrastructure**. It is a structured questionnaire: you answer questions per pillar, and it produces a risk-ranked improvement plan with links to guidance. It has no mutating effect on any resource and costs nothing.

**29.** **AWS Solutions Library.** It publishes vetted, deployable implementations (CloudFormation/CDK) you can launch directly. The **Architecture Center** publishes reference architectures, diagrams, and design patterns — guidance to build from, not artifacts to deploy.

---

### Block 7 — People and partners

**30.** A **Cloud Support Engineer** is **reactive and pooled**: whoever is on rotation picks up your case, resolves it, and moves on — they do not carry context between cases. A **TAM** is **proactive and (on Enterprise) named**: a designated advocate who knows your architecture, reviews it on a cadence, plans launches with you, drives internal escalation during incidents, and surfaces Trusted Advisor Priority findings. The TAM does not replace the case — the TAM makes the case move.

**31.** **Enterprise On-Ramp** and **Enterprise**. The Concierge team owns **billing and account** questions — invoice analysis, payment methods, account structure, Savings Plan and Reserved Instance allocation questions — i.e. the non-technical half.

**32.** **AWS Professional Services** is AWS's own global consulting organization; an **APN Consulting Partner** is a third-party firm validated by AWS. Both are **paid, project-based engagements** contracted separately from your Support plan, and both do implementation work. The difference is *who you contract with* — AWS directly vs. an independent company — which affects the commercial relationship, local presence, and depth of AWS-internal access.

**33.** **AWS Managed Services (AMS)** operates your infrastructure: patching, monitoring, incident management, backup, and change control, executed by AWS on your accounts. **AWS Support** advises and troubleshoots but never operates. AMS is a separate paid subscription and **presupposes Enterprise Support**.

**34.** Yes. Abuse reporting is available on **every plan including Basic**, via `https://support.aws.amazon.com/#/contacts/report-abuse`, `abuse@amazonaws.com`, or a `customer-service` case. It is handled by AWS Trust & Safety, which is a separate path from technical support and is not gated on a paid plan.

**35.** **AWS Countdown** (formerly Infrastructure Event Management, IEM) — guided planning plus real-time engagement around a specific scheduled event. On **Business** it is available for an **additional fee**; on **Enterprise** it is **included**.

**Routing drill (step 4):** (a) AWS Professional Services or an APN Consulting Partner — long, contractual, milestone-based delivery. (b) AWS Trust & Safety / Abuse team. (c) AWS Managed Services (AMS). (d) AWS IQ — short-term, on-demand certified experts, no procurement cycle. (e) AWS Concierge Support Team. (f) AWS Countdown. (g) AWS Activate. (h) AWS Marketplace.

---

### Block 8 — Synthesis drill

| # | (a) Resource | (b) Minimum plan |
|---|---|---|
| 1 | AWS Health Dashboard — **Service health** (public) | None — no account needed |
| 2 | AWS Health Dashboard — **Your account health** (console) | **Basic** |
| 3 | Support case, `critical` severity | **Enterprise** (< 15 min) |
| 4 | Support case, `critical` severity | **Enterprise On-Ramp** (< 30 min) |
| 5 | **AWS Support API** (`support:CreateCase`) | **Business** |
| 6 | **Service Quotas** increase request | **Basic** |
| 7 | **AWS Trusted Advisor**, Cost Optimization category | **Business** for the full catalogue/API; Basic sees only quota + core security checks |
| 8 | Support case, `low` severity | **Developer** ($29/mo or 3% of usage, whichever is greater) |
| 9 | **Designated Technical Account Manager** | **Enterprise** |
| 10 | **AWS IQ** | None |
| 11 | **AWS Whitepapers & Guides** | None |
| 12 | **AWS Marketplace** | None |
| 13 | **AWS Trust & Safety / Abuse team** | None (Basic) |
| 14 | **AWS Incident Detection and Response (IDR)** | **Enterprise** (paid add-on) |
| 15 | **AWS Well-Architected Tool** | None |

**36.** **Basic → Developer:** technical support cases become possible at all (business hours, severities `low`/`normal`, email to Cloud Support Associates). **Developer → Business:** 24x7 access to Cloud Support Engineers by phone/chat/email, the `high` and `urgent` severities, the **full Trusted Advisor catalogue**, and **all programmatic access** — Support API, Health API, Trusted Advisor API, AWS Support App in Slack. **Business → Enterprise On-Ramp/Enterprise:** the `critical` severity with a 30/15-minute target, TAMs (pooled/designated), the Concierge team, Trusted Advisor Priority (Enterprise), and eligibility for AMS and IDR.

**37.** **(i) Service Quotas increase requests** and **(ii) the personalized AWS Health Dashboard (Your account health)**. Both are frequently assumed to need a paid plan; neither does. Honorable mentions with the same property: abuse reporting, the Well-Architected Tool, re:Post, and all documentation.

**38.** **Trusted Advisor** and **AWS Health** are both console-visible (in reduced or full form) on Basic but API-locked to Business+. AWS draws the line there because the **console** view is a self-service dashboard a human reads occasionally, while the **API** is what you build automation, monitoring, and integrations on — that operational-integration capability is what the paid tiers sell, alongside the response-time commitments.

</details>