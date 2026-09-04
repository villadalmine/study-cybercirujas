# AWS Certified Cloud Practitioner (CLF-C02) — Domain 2, Task Statement 2.4
## Identify components and resources for security — Guided Exercises

> **Exam weight context:** Domain 2 (Security and Compliance) is 30% of the exam; this task statement carries **7.5%** of the total scored content. Expect questions that ask you to *pick the right service for a stated security need*, and to distinguish services that look similar (GuardDuty vs. Inspector vs. Macie; KMS vs. CloudHSM vs. Secrets Manager; security group vs. NACL vs. WAF vs. Shield).

---

## 0. Before you start

### 0.1 What you will build

You will stand up a disposable VPC and then walk the AWS security stack layer by layer, touching the real APIs:

| Lab | Layer | Services exercised |
|---|---|---|
| 1 | Network / VPC | Security groups, network ACLs |
| 2 | Edge & application | AWS WAF, AWS Shield, AWS Firewall Manager, AWS Network Firewall |
| 3 | Detection & posture | Amazon GuardDuty, Amazon Inspector, Amazon Detective, AWS Security Hub, Amazon Macie |
| 4 | Data & secrets | AWS KMS, AWS CloudHSM, AWS Secrets Manager, AWS Certificate Manager |
| 5 | Governance & audit | AWS CloudTrail, AWS Config, IAM Access Analyzer, AWS Trusted Advisor, AWS Audit Manager |
| 6 | Information & compliance sources | AWS Artifact, Security Bulletins, Knowledge Center, AWS Marketplace, pen-test policy |

### 0.2 Cost warning — read this

Most steps are free or fractions of a cent, but three are not zero:

| Resource | Price model | What this lab costs you |
|---|---|---|
| GuardDuty detector | 30-day free trial per account/Region, then usage-based | $0 if your account has never enabled it |
| WAF web ACL | $5.00/web ACL/month + $1.00/rule/month, **prorated hourly** | ~$0.01–0.02 for one hour |
| KMS customer managed key | $1.00/key/month, prorated hourly; **minimum 7-day deletion window** | ~$0.25 (7 days of a key you scheduled for deletion) |
| Secrets Manager secret | $0.40/secret/month, prorated | ~$0.01, and it is deletable immediately with `--force-delete-without-recovery` |
| EC2 `t3.micro` (optional Lab 1b) | Free tier eligible, else ~$0.0104/h | ~$0.01 |

Everything else in this document is a read call, a `describe`, or a service that is free (IAM Access Analyzer external-access findings, CloudTrail Event history, VPC security constructs).

### 0.3 Environment check

```bash
aws --version
aws sts get-caller-identity
export AWS_REGION=us-east-1
export AWS_PAGER=""      # stop the CLI from opening less on every call
```

Expected:

```
aws-cli/2.17.42 Python/3.11.9 linux/6.5.0 exe/x86_64.fedora.40
```
```json
{
    "UserId": "AIDASAMPLEUSERID",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/lab-admin"
}
```

> Use a **sandbox account**, never a production one. Several steps enable account-wide services.

### 0.4 Create the sandbox VPC

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf-sec-lab}]' \
  --query 'Vpc.VpcId' --output text)

SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.42.1.0/24 \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=clf-sec-lab-public}]' \
  --query 'Subnet.SubnetId' --output text)

echo "VPC=$VPC_ID  SUBNET=$SUBNET_ID"
```

```
VPC=vpc-0f1e2d3c4b5a69788  SUBNET=subnet-0a9b8c7d6e5f40312
```

---

## Lab 1 — The two VPC firewalls: security groups and network ACLs

This is the single most tested distinction in 2.4. Both filter traffic; they differ in **statefulness**, **attachment point**, **rule semantics**, and **evaluation order**.

### 1.1 Inspect the default security group

1. Retrieve the default security group that AWS created with the VPC:

```bash
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=default \
  --query 'SecurityGroups[0].{Id:GroupId,In:IpPermissions,Out:IpPermissionsEgress}'
```

```json
{
    "Id": "sg-0a1b2c3d4e5f60718",
    "In": [
        {
            "IpProtocol": "-1",
            "IpRanges": [],
            "Ipv6Ranges": [],
            "PrefixListIds": [],
            "UserIdGroupPairs": [
                {
                    "GroupId": "sg-0a1b2c3d4e5f60718",
                    "UserId": "111122223333"
                }
            ]
        }
    ],
    "Out": [
        {
            "IpProtocol": "-1",
            "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ],
            "Ipv6Ranges": [],
            "PrefixListIds": [],
            "UserIdGroupPairs": []
        }
    ]
}
```

2. Note two structural facts you can read directly out of that JSON:
   - The inbound rule's source is **the security group itself** (`UserIdGroupPairs`), not a CIDR. Security groups can reference other security groups — a NACL cannot.
   - There is **no `RuleAction` field anywhere**. Every entry in `IpPermissions` is implicitly an *allow*.

3. Create a purpose-built security group and add two ingress rules:

```bash
WEB_SG=$(aws ec2 create-security-group \
  --group-name clf-sec-lab-web --description "Lab web tier" \
  --vpc-id "$VPC_ID" --query GroupId --output text)

MYIP=$(curl -s https://checkip.amazonaws.com)/32
echo "Your public IP: $MYIP"

aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description='public http'}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP,Description='admin ssh'}]"
```

```json
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0123456789abcdef0",
            "GroupId": "sg-0b2c3d4e5f6071829",
            "GroupOwnerId": "111122223333",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 80,
            "ToPort": 80,
            "CidrIpv4": "0.0.0.0/0",
            "Description": "public http"
        },
        {
            "SecurityGroupRuleId": "sgr-0123456789abcdef1",
            "GroupId": "sg-0b2c3d4e5f6071829",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "CidrIpv4": "203.0.113.24/32",
            "Description": "admin ssh"
        }
    ]
}
```

4. Try to write a *deny* rule. There is no such API call — confirm it by looking at what exists:

```bash
aws ec2 help | grep -iE 'security-group-(ingress|egress)'
```

```
       o authorize-security-group-egress
       o authorize-security-group-ingress
       o revoke-security-group-egress
       o revoke-security-group-ingress
```

`authorize` and `revoke` only. There is no `deny-security-group-ingress`.

5. Confirm the group has **no explicit egress rule of your making**, yet allows all outbound:

```bash
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values="$WEB_SG" \
  --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:CidrIpv4}' \
  --output table
```

```
------------------------------------------------------------
|                 DescribeSecurityGroupRules               |
+--------+---------+-------+-----------------+-------+-----+
|  Cidr           | Egress | From |  Proto   |  To        |
+-----------------+--------+------+----------+------------+
|  0.0.0.0/0      |  True  |  -1  |  -1      |  -1        |
|  0.0.0.0/0      |  False |  80  |  tcp     |  80        |
|  203.0.113.24/32|  False |  22  |  tcp     |  22        |
+-----------------+--------+------+----------+------------+
```

**Check your understanding — block 1.1**

- **Q1.** A colleague asks you to "block the IP `198.51.100.7` at the security group". Why can you not do it, and which VPC construct *can*?
- **Q2.** Your web instances must reach an RDS database. You write an inbound rule on the DB security group whose source is `sg-...web`. Explain what AWS actually evaluates at packet time — is it the instance's IP, or something else?
- **Q3.** The new security group has one egress rule you never created. Where did it come from, and what happens to that rule the moment you call `authorize-security-group-egress` once?

---

### 1.2 Inspect network ACLs

6. Look at the default NACL that AWS attached to the VPC:

```bash
aws ec2 describe-network-acls --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'NetworkAcls[0].{Id:NetworkAclId,Default:IsDefault,Entries:Entries}'
```

```json
{
    "Id": "acl-0c3d4e5f60718293a",
    "Default": true,
    "Entries": [
        { "CidrBlock": "0.0.0.0/0", "Egress": true,  "Protocol": "-1", "RuleAction": "allow", "RuleNumber": 100 },
        { "CidrBlock": "0.0.0.0/0", "Egress": true,  "Protocol": "-1", "RuleAction": "deny",  "RuleNumber": 32767 },
        { "CidrBlock": "0.0.0.0/0", "Egress": false, "Protocol": "-1", "RuleAction": "allow", "RuleNumber": 100 },
        { "CidrBlock": "0.0.0.0/0", "Egress": false, "Protocol": "-1", "RuleAction": "deny",  "RuleNumber": 32767 }
    ]
}
```

7. Now create a **custom** NACL and immediately dump it, before adding anything:

```bash
NACL_ID=$(aws ec2 create-network-acl --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=clf-sec-lab-nacl}]' \
  --query 'NetworkAcl.NetworkAclId' --output text)

aws ec2 describe-network-acls --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Entries'
```

```json
[
    { "CidrBlock": "0.0.0.0/0", "Egress": true,  "Protocol": "-1", "RuleAction": "deny", "RuleNumber": 32767 },
    { "CidrBlock": "0.0.0.0/0", "Egress": false, "Protocol": "-1", "RuleAction": "deny", "RuleNumber": 32767 }
]
```

Compare against step 6. The difference — default NACL allows everything, custom NACL denies everything — is a classic exam trap.

8. Add an inbound allow for HTTP only, plus a deny that *precedes* it, to observe rule-number ordering:

```bash
aws ec2 create-network-acl-entry --network-acl-id "$NACL_ID" \
  --rule-number 90 --protocol tcp --port-range From=80,To=80 \
  --cidr-block 198.51.100.7/32 --rule-action deny --ingress

aws ec2 create-network-acl-entry --network-acl-id "$NACL_ID" \
  --rule-number 100 --protocol tcp --port-range From=80,To=80 \
  --cidr-block 0.0.0.0/0 --rule-action allow --ingress

aws ec2 describe-network-acls --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Entries[?Egress==`false`].[RuleNumber,RuleAction,Protocol,PortRange.From,CidrBlock]' \
  --output table
```

```
-------------------------------------------------------------
|                    DescribeNetworkAcls                    |
+------+---------+-----+------+---------------------+
|  90  |  deny   |  6  |  80  |  198.51.100.7/32    |
|  100 |  allow  |  6  |  80  |  0.0.0.0/0          |
| 32767|  deny   | -1  |  None|  0.0.0.0/0          |
+------+---------+-----+------+---------------------+
```

Protocol `6` is TCP (IANA number); the CLI accepts the name and stores the number.

**Check your understanding — block 1.2**

- **Q4.** Rewrite the two rules above with rule numbers `100` (deny 198.51.100.7) and `90` (allow 0.0.0.0/0). What does `198.51.100.7` experience now, and why?
- **Q5.** A custom NACL is associated with a subnet and you have added *only* the inbound HTTP allow from step 8. A user's browser sends `GET /` to your web server on port 80. The server processes it. Does the response reach the browser? Justify in terms of NACL rule direction.
- **Q6.** Fill in the table from memory, then verify against what you observed:

  | | Security group | Network ACL |
  |---|---|---|
  | Attaches to | ? | ? |
  | Stateful? | ? | ? |
  | Supports deny? | ? | ? |
  | Rule evaluation | ? | ? |
  | Can reference another SG as source | ? | ? |
  | Default (custom-created) posture | ? | ? |

---

### 1.3 (Optional, ~$0.01) Prove statefulness empirically

Only do this if you want the packet-level proof. It launches one `t3.micro`.

9. Make the subnet internet-facing:

```bash
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
```

10. Launch a web server with no SSH key (user data only):

```bash
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

cat > /tmp/userdata.sh <<'SH'
#!/bin/bash
dnf install -y nginx
echo "clf-sec-lab OK" > /usr/share/nginx/html/index.html
systemctl enable --now nginx
SH

INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" --security-group-ids "$WEB_SG" \
  --user-data file:///tmp/userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf-sec-lab-web}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

PUBIP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
curl -s --max-time 10 "http://$PUBIP/"
```

```
clf-sec-lab OK
```

The security group has **no outbound rule for the HTTP response** other than the catch-all — and even if you removed the catch-all, the response would still flow, because the group is stateful.

11. Swap the subnet onto your custom NACL (inbound HTTP allow only, no outbound rules) and retry:

```bash
ASSOC_ID=$(aws ec2 describe-network-acls \
  --filters Name=association.subnet-id,Values="$SUBNET_ID" \
  --query "NetworkAcls[?IsDefault==\`true\`].Associations[?SubnetId=='$SUBNET_ID'].NetworkAclAssociationId | [0][0]" \
  --output text)

NEW_ASSOC=$(aws ec2 replace-network-acl-association \
  --association-id "$ASSOC_ID" --network-acl-id "$NACL_ID" \
  --query NewAssociationId --output text)

curl -s --max-time 10 "http://$PUBIP/" ; echo "exit=$?"
```

```
exit=28
```

`curl` exit 28 is *operation timed out*. The request arrived; the reply was dropped.

12. Add the ephemeral-port egress rule and retry:

```bash
aws ec2 create-network-acl-entry --network-acl-id "$NACL_ID" \
  --rule-number 100 --protocol tcp --port-range From=1024,To=65535 \
  --cidr-block 0.0.0.0/0 --rule-action allow --egress

curl -s --max-time 10 "http://$PUBIP/" ; echo "exit=$?"
```

```
clf-sec-lab OK
exit=0
```

**Check your understanding — block 1.3**

- **Q7.** In step 11 the *inbound* NACL rule permitted the request and the security group permitted it too — so the packet reached nginx. Precisely which rule dropped the reply, and on which NACL direction?
- **Q8.** Why `1024–65535` and not, say, `80`? Which endpoint chooses the ephemeral port, and what would you have to widen it to for a Windows-based NAT client or an ELB in front?
- **Q9.** Both rule sets ultimately allowed the traffic. State the design principle that explains why a well-run production VPC still keeps NACLs coarse (broad subnet-level deny lists) and security groups fine (per-tier allow lists).

**Sources for Lab 1**
- Security groups: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Network ACLs and ephemeral ports: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- Comparison table: https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html

---

## Lab 2 — Edge and application layer: WAF, Shield, Firewall Manager, Network Firewall

Security groups and NACLs read IP headers and TCP/UDP ports. They cannot see a SQL injection string in a query parameter. That is layer 7 — AWS WAF.

### 2.1 AWS WAF

1. List the AWS-managed rule groups available to you at no per-rule-group licence charge:

```bash
aws wafv2 list-available-managed-rule-groups --scope REGIONAL \
  --query 'ManagedRuleGroups[?VendorName==`AWS`].Name' --output table
```

```
------------------------------------------------
|      ListAvailableManagedRuleGroups           |
+----------------------------------------------+
|  AWSManagedRulesCommonRuleSet                 |
|  AWSManagedRulesAdminProtectionRuleSet        |
|  AWSManagedRulesKnownBadInputsRuleSet         |
|  AWSManagedRulesSQLiRuleSet                   |
|  AWSManagedRulesLinuxRuleSet                  |
|  AWSManagedRulesUnixRuleSet                   |
|  AWSManagedRulesWindowsRuleSet                |
|  AWSManagedRulesPHPRuleSet                    |
|  AWSManagedRulesWordPressRuleSet              |
|  AWSManagedRulesAmazonIpReputationList        |
|  AWSManagedRulesAnonymousIpList               |
|  AWSManagedRulesBotControlRuleSet             |
|  AWSManagedRulesATPRuleSet                    |
|  AWSManagedRulesACFPRuleSet                   |
+----------------------------------------------+
```

2. Build a web ACL with one managed rule group plus a rate-based rule:

```bash
cat > /tmp/waf-rules.json <<'JSON'
[
  {
    "Name": "AWS-CommonRuleSet",
    "Priority": 0,
    "Statement": {
      "ManagedRuleGroupStatement": {
        "VendorName": "AWS",
        "Name": "AWSManagedRulesCommonRuleSet"
      }
    },
    "OverrideAction": { "None": {} },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "AWS-CommonRuleSet"
    }
  },
  {
    "Name": "RateLimitPerIP",
    "Priority": 1,
    "Statement": {
      "RateBasedStatement": {
        "Limit": 2000,
        "EvaluationWindowSec": 300,
        "AggregateKeyType": "IP"
      }
    },
    "Action": { "Block": {} },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "RateLimitPerIP"
    }
  }
]
JSON

aws wafv2 create-web-acl \
  --name clf-sec-lab-acl --scope REGIONAL \
  --default-action Allow={} \
  --rules file:///tmp/waf-rules.json \
  --visibility-config \
      SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=clfSecLabAcl
```

```json
{
    "Summary": {
        "Name": "clf-sec-lab-acl",
        "Id": "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
        "Description": "",
        "LockToken": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
        "ARN": "arn:aws:wafv2:us-east-1:111122223333:regional/webacl/clf-sec-lab-acl/a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
    }
}
```

3. Read the capacity consumption (WCU) and note the association list is empty:

```bash
aws wafv2 get-web-acl --name clf-sec-lab-acl --scope REGIONAL \
  --id a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d \
  --query 'WebACL.{Capacity:Capacity,Default:DefaultAction,Rules:Rules[].Name}'
```

```json
{
    "Capacity": 702,
    "Default": { "Allow": {} },
    "Rules": [ "AWS-CommonRuleSet", "RateLimitPerIP" ]
}
```

4. Note what a web ACL can be attached to. `--scope REGIONAL` covers Application Load Balancer, API Gateway REST API, AppSync GraphQL API, Cognito user pool, App Runner, and Verified Access. `--scope CLOUDFRONT` covers CloudFront distributions and **must be created in `us-east-1`**:

```bash
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query 'WebACLs[].Name'
```

```json
[]
```

**Check your understanding — block 2.1**

- **Q10.** The web ACL's default action is `Allow` and it holds a `Block` rate rule. Restate that policy in one sentence as an ordered decision procedure.
- **Q11.** A security group cannot block an SQL injection payload and a WAF cannot block an SSH brute force on port 22. Explain both limitations in terms of the OSI layer each control inspects.
- **Q12.** Your web tier is an ALB *and* a CloudFront distribution in front of it. How many web ACLs do you need, in which Region(s), and why can one not cover both?

---

### 2.2 Shield, Firewall Manager, Network Firewall

5. Check your DDoS protection tier. Shield Standard is on for every AWS customer at no cost and cannot be turned off; Shield Advanced is a subscription:

```bash
aws shield get-subscription-state --region us-east-1
```

```json
{
    "SubscriptionState": "INACTIVE"
}
```

6. Confirm that the Advanced-only APIs refuse to answer without a subscription:

```bash
aws shield list-protections --region us-east-1
```

```
An error occurred (ResourceNotFoundException) when calling the ListProtections
operation: The subscription does not exist.
```

`INACTIVE` here means "Shield **Advanced** is not subscribed." Shield **Standard** is still protecting your ELB, CloudFront and Route 53 endpoints against common L3/L4 floods; it has no console toggle and no API because there is nothing to configure.

7. Check whether the account participates in centrally-managed policy enforcement:

```bash
aws fms get-admin-account --region us-east-1
```

```
An error occurred (ResourceNotFoundException) when calling the GetAdminAccount
operation: Resource not found.
```

AWS Firewall Manager requires **AWS Organizations**, a designated administrator account, and **AWS Config enabled in every member account/Region**. It does not filter packets itself — it *pushes and audits* WAF web ACLs, Shield Advanced protections, security group policies, Network Firewall policies and Route 53 Resolver DNS Firewall rules across the org.

8. Confirm no managed network firewall exists:

```bash
aws network-firewall list-firewalls --query 'Firewalls'
```

```json
[]
```

AWS Network Firewall is a **stateful, VPC-attached, managed IDS/IPS** with Suricata-compatible rules — deployed into dedicated firewall subnets and reached via route table entries. It is the layer between "NACL/security group" (per-subnet/per-ENI, no deep inspection) and "WAF" (HTTP only).

**Check your understanding — block 2.2**

- **Q13.** Order these four from cheapest/most-automatic to most-configurable and most-expensive: Shield Standard, Shield Advanced, AWS WAF, AWS Network Firewall. For each, state the *one* scenario keyword that should make you pick it on the exam.
- **Q14.** A 500-account organization needs "every internet-facing ALB must have the AWS Common Rule Set attached, and I want a report of the ones that do not." Which service enforces that, and what are its two hard prerequisites?
- **Q15.** Shield Advanced advertises "cost protection". What exactly is refunded, and why is that a meaningful benefit specific to a DDoS on an elastic architecture?

**Sources for Lab 2**
- AWS WAF: https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Shield: https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- AWS Firewall Manager prerequisites: https://docs.aws.amazon.com/waf/latest/developerguide/fms-prereq.html
- AWS Network Firewall: https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html

---

## Lab 3 — Detection and posture management

Four services here look alike on a slide and are completely different in practice. The discriminator is **what they read**.

### 3.1 Amazon GuardDuty — continuous threat detection

1. Enable a detector (30-day free trial in an account that has never had one):

```bash
DETECTOR_ID=$(aws guardduty create-detector --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --query DetectorId --output text)
echo "$DETECTOR_ID"
```

```
d4a1b2c3d4e5f60718293a4b5c6d7e8f
```

2. Look at what it is consuming. Notice you did not install anything:

```bash
aws guardduty get-detector --detector-id "$DETECTOR_ID" \
  --query '{Status:Status,DataSources:Features[].{Name:Name,Status:Status}}'
```

```json
{
    "Status": "ENABLED",
    "DataSources": [
        { "Name": "CLOUD_TRAIL",            "Status": "ENABLED" },
        { "Name": "DNS_LOGS",               "Status": "ENABLED" },
        { "Name": "FLOW_LOGS",              "Status": "ENABLED" },
        { "Name": "S3_DATA_EVENTS",         "Status": "ENABLED" },
        { "Name": "EKS_AUDIT_LOGS",         "Status": "ENABLED" },
        { "Name": "EBS_MALWARE_PROTECTION", "Status": "ENABLED" },
        { "Name": "RDS_LOGIN_EVENTS",       "Status": "ENABLED" },
        { "Name": "LAMBDA_NETWORK_LOGS",    "Status": "ENABLED" }
    ]
}
```

3. Generate sample findings and read one:

```bash
aws guardduty create-sample-findings --detector-id "$DETECTOR_ID" \
  --finding-types "UnauthorizedAccess:EC2/SSHBruteForce" \
                  "CryptoCurrency:EC2/BitcoinTool.B!DNS" \
                  "Policy:IAMUser/RootCredentialUsage"

sleep 10
FID=$(aws guardduty list-findings --detector-id "$DETECTOR_ID" \
  --query 'FindingIds[0]' --output text)

aws guardduty get-findings --detector-id "$DETECTOR_ID" --finding-ids "$FID" \
  --query 'Findings[0].{Title:Title,Type:Type,Severity:Severity,Resource:Resource.ResourceType,Action:Service.Action.ActionType}'
```

```json
{
    "Title": "[SAMPLE] 198.51.100.0 is performing SSH brute force attacks against i-99999999.",
    "Type": "UnauthorizedAccess:EC2/SSHBruteForce",
    "Severity": 2,
    "Resource": "Instance",
    "Action": "NETWORK_CONNECTION"
}
```

Severity scale: `1.0–3.9` Low, `4.0–6.9` Medium, `7.0–8.9` High, `9.0+` Critical.

**Check your understanding — block 3.1**

- **Q16.** You never enabled VPC Flow Logs, never created a CloudTrail trail, and never installed an agent — yet GuardDuty analyses all three streams. Explain the mechanism, and the billing consequence (do you pay for the flow logs GuardDuty reads?).
- **Q17.** A finding says `CryptoCurrency:EC2/BitcoinTool.B!DNS`. Which data source produced it, and what is GuardDuty actually asserting happened?

---

### 3.2 Inspector, Macie, Detective, Security Hub — read-only comparison

4. Check Amazon Inspector's state (do not enable it unless you accept the trial):

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
aws inspector2 batch-get-account-status --account-ids "$ACCT" \
  --query 'accounts[0].{Overall:state.status,Scans:resourceState}'
```

```json
{
    "Overall": { "status": "DISABLED" },
    "Scans": {
        "ec2":        { "status": "DISABLED" },
        "ecr":        { "status": "DISABLED" },
        "lambda":     { "status": "DISABLED" },
        "lambdaCode": { "status": "DISABLED" }
    }
}
```

Read the four scan targets carefully: **EC2 instances, ECR container images, Lambda functions, Lambda code**. Inspector matches installed packages against CVE feeds and produces a risk score. It scans *software*, not behaviour.

5. Check Amazon Macie:

```bash
aws macie2 get-macie-session
```

```
An error occurred (AccessDeniedException) when calling the GetMacieSession
operation: Macie is not enabled.
```

6. Check Amazon Detective:

```bash
aws detective list-graphs --query 'GraphList'
```

```json
[]
```

7. Check AWS Security Hub:

```bash
aws securityhub describe-hub
```

```
An error occurred (InvalidAccessException) when calling the DescribeHub
operation: Account 111122223333 is not subscribed to AWS Security Hub
```

8. Fill the discriminator table in as you go — this is the payload of the whole lab:

| Service | Reads | Produces | Typical exam keyword |
|---|---|---|---|
| GuardDuty | CloudTrail, VPC Flow Logs, DNS logs, S3 data events, EKS audit logs, RDS logins | Threat findings | "detect malicious *activity*", "compromised instance", "no agent" |
| Inspector | EC2 / ECR images / Lambda software inventory | CVE + risk-score findings | "vulnerability", "unpatched", "CVE", "container image scan" |
| Macie | S3 objects | Sensitive-data findings (PII, credentials) | "discover PII in S3", "classify sensitive data" |
| Detective | GuardDuty findings + CloudTrail + Flow Logs, as a behaviour graph | Investigation / root-cause graph | "investigate", "root cause", "how did this happen" |
| Security Hub | Findings from all of the above, in ASFF | Aggregated posture + standards scores | "single pane of glass", "CIS/PCI/NIST benchmark score" |

**Check your understanding — block 3.2**

- **Q18.** Match each request to exactly one service: (a) "Are any of our container images running a vulnerable `log4j`?" (b) "Is anyone exfiltrating data from that instance right now?" (c) "Does bucket `hr-exports` contain national ID numbers?" (d) "Show me every step the attacker took across accounts over the last 14 days." (e) "Give me one dashboard with our CIS benchmark score across 40 accounts."
- **Q19.** Detective is described as consuming GuardDuty findings. What does that imply about the order you enable the two services, and about the value of Detective in an account where GuardDuty has never run?
- **Q20.** Security Hub is called an aggregator. Name the standard finding format it normalises everything into, and explain why that format is what makes third-party AWS Marketplace security products pluggable.

**Sources for Lab 3**
- GuardDuty: https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- Inspector: https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Macie: https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Detective: https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- Security Hub & ASFF: https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html

---

## Lab 4 — Data protection: KMS, CloudHSM, Secrets Manager, ACM

### 4.1 AWS KMS

1. See the keys AWS already made for you:

```bash
aws kms list-aliases \
  --query 'Aliases[?starts_with(AliasName, `alias/aws/`)].AliasName' --output table
```

```
--------------------------------
|          ListAliases         |
+------------------------------+
|  alias/aws/ebs               |
|  alias/aws/rds               |
|  alias/aws/s3                |
|  alias/aws/secretsmanager    |
|  alias/aws/ssm               |
+------------------------------+
```

These are **AWS managed keys** — free, auto-rotated yearly, and you cannot edit their key policy or delete them.

2. Create a **customer managed key** and alias it ($1/month, prorated):

```bash
KEY_ID=$(aws kms create-key \
  --description "CLF 2.4 lab key" \
  --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
  --query 'KeyMetadata.KeyId' --output text)

aws kms create-alias --alias-name alias/clf-sec-lab --target-key-id "$KEY_ID"

aws kms describe-key --key-id alias/clf-sec-lab \
  --query 'KeyMetadata.{Id:KeyId,Manager:KeyManager,Origin:Origin,Spec:KeySpec,State:KeyState,Multi:MultiRegion}'
```

```json
{
    "Id": "3b2e1a0c-9d8f-4e7a-b6c5-d4e3f2a1b0c9",
    "Manager": "CUSTOMER",
    "Origin": "AWS_KMS",
    "Spec": "SYMMETRIC_DEFAULT",
    "State": "Enabled",
    "Multi": false
}
```

3. Encrypt and decrypt a small value. Watch the size limit:

```bash
printf 'lab-db-password' > /tmp/plain.txt
aws kms encrypt --key-id alias/clf-sec-lab --plaintext fileb:///tmp/plain.txt \
  --query CiphertextBlob --output text > /tmp/cipher.b64

wc -c /tmp/cipher.b64
base64 -d /tmp/cipher.b64 > /tmp/cipher.bin

aws kms decrypt --ciphertext-blob fileb:///tmp/cipher.bin \
  --query Plaintext --output text | base64 -d ; echo
```

```
248 /tmp/cipher.b64
lab-db-password
```

Note the decrypt call did **not** need `--key-id`: the key ARN is embedded in the ciphertext blob.

4. Hit the limit deliberately:

```bash
head -c 5000 /dev/urandom > /tmp/big.bin
aws kms encrypt --key-id alias/clf-sec-lab --plaintext fileb:///tmp/big.bin \
  --query CiphertextBlob --output text > /dev/null
```

```
An error occurred (ValidationException) when calling the Encrypt operation:
1 validation error detected: Value at 'plaintext' failed to satisfy constraint:
Member must have length less than or equal to 4096
```

5. That is why AWS services use **envelope encryption**. Watch it happen:

```bash
aws kms generate-data-key --key-id alias/clf-sec-lab --key-spec AES_256 \
  --query '{PlaintextKeyLen:Plaintext,WrappedKey:CiphertextBlob}' --output json \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);print("plaintext DEK bytes:",len(base64.b64decode(d["PlaintextKeyLen"])));print("wrapped DEK bytes:",len(base64.b64decode(d["WrappedKey"])))'
```

```
plaintext DEK bytes: 32
wrapped DEK bytes: 184
```

You encrypt your 5 GB object locally with the 32-byte data key, store the 184-byte wrapped key next to it, and discard the plaintext key from memory. The KMS key never touches your data.

6. Turn on automatic rotation:

```bash
aws kms enable-key-rotation --key-id alias/clf-sec-lab
aws kms get-key-rotation-status --key-id alias/clf-sec-lab
```

```json
{
    "KeyRotationEnabled": true,
    "KeyId": "arn:aws:kms:us-east-1:111122223333:key/3b2e1a0c-9d8f-4e7a-b6c5-d4e3f2a1b0c9",
    "RotationPeriodInDays": 365
}
```

7. Confirm that CloudHSM is a different, single-tenant world:

```bash
aws cloudhsmv2 describe-clusters --query 'Clusters[].{Id:ClusterId,State:State,Mode:Mode}'
```

```json
[]
```

**Check your understanding — block 4.1**

- **Q21.** In step 3, `decrypt` succeeded without you naming a key. What does that tell you about where authorization is enforced, and which two policy documents must both permit the call?
- **Q22.** A regulator requires that "no employee of the cloud provider can possibly access the key material, and we must control the HSM users ourselves." Which service, and name two operational burdens you inherit by choosing it.
- **Q23.** Envelope encryption: the KMS key rotated on schedule. Do you have to re-encrypt your 5 GB S3 objects? Explain in terms of what actually got rotated and what the object's stored ciphertext points at.

---

### 4.2 Secrets Manager, Parameter Store, ACM

8. Store a credential:

```bash
aws secretsmanager create-secret --name clf-sec-lab/db \
  --description "Lab DB credential" \
  --secret-string '{"username":"appuser","password":"REPLACE-ME-lab-only"}'
```

```json
{
    "ARN": "arn:aws:secretsmanager:us-east-1:111122223333:secret:clf-sec-lab/db-AbCdEf",
    "Name": "clf-sec-lab/db",
    "VersionId": "7c2f1a90-4b3d-4a1e-8f6c-2b9d0e5a7c31"
}
```

9. Read it back and inspect the metadata — especially rotation and which key encrypted it:

```bash
aws secretsmanager get-secret-value --secret-id clf-sec-lab/db \
  --query SecretString --output text

aws secretsmanager describe-secret --secret-id clf-sec-lab/db \
  --query '{Rotation:RotationEnabled,Kms:KmsKeyId,Stages:VersionIdsToStages}'
```

```json
{"username":"appuser","password":"REPLACE-ME-lab-only"}
```
```json
{
    "Rotation": null,
    "Kms": null,
    "Stages": {
        "7c2f1a90-4b3d-4a1e-8f6c-2b9d0e5a7c31": [ "AWSCURRENT" ]
    }
}
```

`Kms: null` means the AWS managed key `alias/aws/secretsmanager` was used. `AWSCURRENT` / `AWSPREVIOUS` / `AWSPENDING` are the staging labels rotation moves between.

10. Store the equivalent in Systems Manager Parameter Store and compare:

```bash
aws ssm put-parameter --name /clf-sec-lab/db-password \
  --type SecureString --value "REPLACE-ME-lab-only"

aws ssm get-parameter --name /clf-sec-lab/db-password --with-decryption \
  --query 'Parameter.{Type:Type,Value:Value,Version:Version}'
```

```json
{
    "Type": "SecureString",
    "Value": "REPLACE-ME-lab-only",
    "Version": 1
}
```

Both encrypt with KMS. Only Secrets Manager has **built-in scheduled rotation with a managed Lambda** and native integration with RDS/Redshift/DocumentDB credentials. Standard Parameter Store parameters are **free**.

11. Look at your TLS certificate inventory:

```bash
aws acm list-certificates \
  --query 'CertificateSummaryList[].{Domain:DomainName,Status:Status,Type:Type,InUse:InUseBy}' \
  --output table
```

```
--------------------------------------------------------------
|                     ListCertificates                       |
+---------------+-----------+------------+-------------------+
|  Domain       |  Status   |  Type      |  InUse            |
+---------------+-----------+------------+-------------------+
|  (empty)                                                   |
+--------------------------------------------------------------
```

Key facts to memorise: **public certificates issued by ACM are free**, they **auto-renew** when DNS validation stays in place, and they are consumed by *integrated services* — ELB, CloudFront, API Gateway, App Runner — rather than installed by hand on an EC2 instance. A certificate for CloudFront must live in **`us-east-1`**.

**Check your understanding — block 4.2**

- **Q24.** You need a database password rotated every 30 days without writing rotation code, and the same secret read by an ECS task and a Lambda. Which of Secrets Manager / Parameter Store, and what is the cost trade you are accepting?
- **Q25.** An RDS instance in `eu-west-1` and a CloudFront distribution both need a certificate for `app.example.com`. How many ACM certificates, and in which Regions? Why?
- **Q26.** Name the AWS security service for each of these three sentences: (a) "encrypt this 200 GB EBS volume"; (b) "store the API token my app reads at boot"; (c) "terminate TLS on the load balancer".

**Sources for Lab 4**
- KMS concepts and envelope encryption: https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html
- CloudHSM: https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- Secrets Manager rotation: https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html
- ACM: https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html

---

## Lab 5 — Governance and audit: CloudTrail, Config, Access Analyzer, Trusted Advisor

### 5.1 CloudTrail — who did what

1. Query the free 90-day Event history for the KMS key you just created:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateKey \
  --max-results 3 \
  --query 'Events[].{Time:EventTime,User:Username,Event:EventName,Resource:Resources[0].ResourceName}' \
  --output table
```

```
------------------------------------------------------------------------------
|                               LookupEvents                                 |
+----------------------+-------------+-------------+-------------------------+
|  2026-09-04T14:12:07 |  lab-admin  |  CreateKey  |  3b2e1a0c-9d8f-4e7a-... |
+----------------------+-------------+-------------+-------------------------+
```

2. Check whether any *trail* exists — Event history is not the same thing:

```bash
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,Multi:IsMultiRegionTrail,S3:S3BucketName,Org:IsOrganizationTrail}'
```

```json
[]
```

Event history is retained 90 days, covers **management events only**, and is not queryable beyond that window. A **trail** delivers to S3 (and optionally CloudWatch Logs) for indefinite retention, can be multi-Region and organization-wide, and can capture **data events** (S3 object-level, Lambda invokes) at extra cost.

### 5.2 AWS Config — what the configuration is, and whether it complies

3. Confirm nothing is recording:

```bash
aws configservice describe-configuration-recorders
aws configservice describe-configuration-recorder-status
```

```json
{
    "ConfigurationRecorders": []
}
```
```json
{
    "ConfigurationRecordersStatus": []
}
```

Read the contrast out loud: CloudTrail records **API calls** (verbs); Config records **resource state over time** (nouns) and evaluates rules like `s3-bucket-public-read-prohibited` against it.

### 5.3 IAM Access Analyzer

4. Create an external-access analyzer (this class of findings is **free**):

```bash
AA_ARN=$(aws accessanalyzer create-analyzer \
  --analyzer-name clf-sec-lab-external --type ACCOUNT \
  --query arn --output text)

sleep 30
aws accessanalyzer list-findings-v2 --analyzer-arn "$AA_ARN" \
  --query 'findings[].{Resource:resource,Type:resourceType,Status:status}' --output table
```

```
------------------------------------------------------------------------
|                            ListFindingsV2                            |
+---------------------------------------+--------------------+---------+
|  arn:aws:s3:::my-public-assets         |  AWS::S3::Bucket   |  ACTIVE |
+---------------------------------------+--------------------+---------+
```

(An empty list is a perfectly good result — it means nothing in the account is shared outside your zone of trust.)

5. Use policy validation, which costs nothing and needs no analyzer:

```bash
cat > /tmp/bad-policy.json <<'JSON'
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["iam:PassRole", "s3:*"],
      "Resource": "*"
    }
  ]
}
JSON

aws accessanalyzer validate-policy \
  --policy-type IDENTITY_POLICY \
  --policy-document file:///tmp/bad-policy.json \
  --query 'findings[].{Type:findingType,Code:issueCode}' --output table
```

```
-------------------------------------------------------
|                   ValidatePolicy                    |
+-------------------+---------------------------------+
|  SECURITY_WARNING |  PASS_ROLE_WITH_STAR_IN_RESOURCE|
|  SUGGESTION       |  MISSING_VERSION                |
+-------------------+---------------------------------+
```

### 5.4 Trusted Advisor and Audit Manager

6. Ask for the security checks:

```bash
aws support describe-trusted-advisor-checks --language en \
  --query 'checks[?category==`security`].name' --output table
```

On Basic or Developer Support:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeTrustedAdvisorChecks operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

The **Support API** requires Business, Enterprise On-Ramp, or Enterprise Support. The Trusted Advisor *console* shows a core set of security and service-quota checks to every account; the **full check catalogue across all five pillars** — cost optimization, performance, security, fault tolerance, service limits, and operational excellence — requires those paid support tiers.

7. Check Audit Manager:

```bash
aws auditmanager get-settings --attribute ALL --query 'settings' 2>&1 | head -3
```

```
An error occurred (AccessDeniedException) when calling the GetSettings
operation: Please complete AWS Audit Manager setup from home page to enable
this action in this account.
```

Audit Manager continuously **collects evidence** and maps it to frameworks (SOC 2, PCI DSS, GDPR, HIPAA), turning an audit from a manual screenshot exercise into a generated assessment report.

**Check your understanding — block 5**

- **Q27.** An auditor asks two questions: "Was S3 bucket `hr-exports` ever public, and for how long?" and "Which principal made it public?" Assign each question to CloudTrail or AWS Config, and explain why the other one cannot answer it.
- **Q28.** Your CloudTrail Event history shows nothing from four months ago. Give the two-part reason and the one configuration change that would have prevented the gap.
- **Q29.** `validate-policy` flagged `PASS_ROLE_WITH_STAR_IN_RESOURCE` on a policy that is syntactically valid and would deploy fine. What class of tool is this, and where in a delivery pipeline does it belong?
- **Q30.** Distinguish, in one sentence each: IAM Access Analyzer *external access* findings, IAM Access Analyzer *unused access* findings, and Trusted Advisor security checks.

**Sources for Lab 5**
- CloudTrail Event history vs. trails: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html
- AWS Config: https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- IAM Access Analyzer: https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- Trusted Advisor: https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- Audit Manager: https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html

---

## Lab 6 — Where AWS security and compliance information lives

The exam guide lists this explicitly: *"Identify where AWS security information can be found"* and *"Identify where to find AWS compliance information."* These are recall questions; the point of this lab is to have actually opened each door once.

1. **AWS Artifact** — self-service download of AWS's audit artifacts (SOC 1/2/3, ISO 27001/27017/27018, PCI DSS AOC, FedRAMP) and legal agreements (BAA, NDA-covered reports).

```bash
aws artifact list-reports --query 'reports[0:5].{Name:name,Series:series,State:state}' --output table
```

```
---------------------------------------------------------------------------
|                              ListReports                                |
+------------------------------------------+-----------------+------------+
|  SOC 2 Type II Report                     |  SOC             |  PUBLISHED |
|  ISO 27001:2022 Certification             |  ISO             |  PUBLISHED |
|  PCI DSS v4.0 Attestation of Compliance   |  PCI             |  PUBLISHED |
+------------------------------------------+-----------------+------------+
```

Console: https://console.aws.amazon.com/artifact/

2. **AWS Security Bulletins** — CVE-style advisories for AWS services and AWS-maintained software, identified `AWS-YYYY-NNN`:

```bash
curl -s https://aws.amazon.com/security/security-bulletins/rss/feed/ \
  | grep -oP '(?<=<title>).*?(?=</title>)' | head -5
```

```
AWS Security Bulletins
AWS-2026-011: Issue with AWS Client VPN
AWS-2026-010: CVE-2026-21538 (Node.js)
AWS-2026-009: Amazon EKS privilege escalation
AWS-2026-008: CVE-2026-4577 (PHP-CGI)
```

3. Open each of these once and note what kind of answer each gives:

| Resource | URL | Answers |
|---|---|---|
| AWS Security Center | https://aws.amazon.com/security/ | Overview, shared responsibility, current posture |
| Security Bulletins | https://aws.amazon.com/security/security-bulletins/ | "Am I affected by CVE-X?" |
| AWS Security Blog | https://aws.amazon.com/blogs/security/ | Patterns, how-tos, launches |
| AWS Knowledge Center | https://repost.aws/knowledge-center | "How do I fix this specific error?" |
| AWS re:Post | https://repost.aws/ | Community + AWS-moderated Q&A |
| AWS Compliance Programs | https://aws.amazon.com/compliance/programs/ | Which certifications AWS holds |
| AWS Artifact | https://console.aws.amazon.com/artifact/ | The actual report PDF, under NDA |
| Well-Architected Security Pillar | https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html | Design guidance |
| Penetration Testing Policy | https://aws.amazon.com/security/penetration-testing/ | What you may test without asking |
| Report abuse | `abuse@amazonaws.com` | AWS resources attacking you |

4. **AWS Marketplace** — third-party security products. Browse the Security category and note the delivery models (AMI, SaaS subscription, container, professional services) and that charges land on your existing AWS bill:

```bash
aws marketplace-catalog list-entities --catalog AWSMarketplace \
  --entity-type AmiProduct --max-results 3 \
  --query 'EntitySummaryList[].{Name:Name,Id:EntityId}' --output table
```

Console: https://aws.amazon.com/marketplace/ → *Categories → Infrastructure Software → Security*.

5. **Penetration testing.** Read https://aws.amazon.com/security/penetration-testing/ and note the eight service categories you may test **without prior approval**, and the categories of *simulated event* (DDoS simulation, phishing simulation, malware testing) that still require the Simulated Events form.

**Check your understanding — block 6**

- **Q31.** A prospective customer's procurement team demands "your SOC 2 Type II report." You do not have one for your own SaaS yet, but you run entirely on AWS. Where do you get AWS's, what constrains how you share it, and what does it *not* cover?
- **Q32.** Distinguish AWS Artifact from AWS Audit Manager in one sentence each. Which one is about AWS's compliance and which about yours?
- **Q33.** Your security team wants to run a credentialed vulnerability scan against your own EC2 instances and an authenticated fuzz against your own API Gateway. Do you need approval? What if they also want to run a 20 Gbps traffic-generation test against your ALB?
- **Q34.** A new CVE lands for OpenSSL. Name the AWS-native service that tells you which of *your* EC2 instances and container images are affected, and the AWS resource that tells you whether *AWS-managed services* are affected.

---

## Lab 7 — Teardown

Run this in order. Several deletes fail if dependencies remain.

```bash
# Optional Lab 1b
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" 2>/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null

# WAF (needs the current lock token)
WACL_ID=$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='clf-sec-lab-acl'].Id | [0]" --output text)
LOCK=$(aws wafv2 get-web-acl --name clf-sec-lab-acl --scope REGIONAL --id "$WACL_ID" --query LockToken --output text)
aws wafv2 delete-web-acl --name clf-sec-lab-acl --scope REGIONAL --id "$WACL_ID" --lock-token "$LOCK"

# GuardDuty
aws guardduty delete-detector --detector-id "$DETECTOR_ID"

# Access Analyzer
aws accessanalyzer delete-analyzer --analyzer-name clf-sec-lab-external

# Secrets / parameters
aws secretsmanager delete-secret --secret-id clf-sec-lab/db --force-delete-without-recovery
aws ssm delete-parameter --name /clf-sec-lab/db-password

# KMS: alias first, then schedule the key (7-day minimum window)
aws kms delete-alias --alias-name alias/clf-sec-lab
aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7

# Network
aws ec2 replace-network-acl-association --association-id "$NEW_ASSOC" \
  --network-acl-id "$(aws ec2 describe-network-acls --filters Name=vpc-id,Values=$VPC_ID Name=default,Values=true --query 'NetworkAcls[0].NetworkAclId' --output text)" 2>/dev/null
aws ec2 delete-network-acl --network-acl-id "$NACL_ID"
aws ec2 delete-security-group --group-id "$WEB_SG"
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null
aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID"
```

Confirm the KMS key is the only lingering charge:

```bash
aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.{State:KeyState,DeletionDate:DeletionDate}'
```

```json
{
    "State": "PendingDeletion",
    "DeletionDate": "2026-09-11T14:12:07+00:00"
}
```

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Lab 1 — Security groups and NACLs

**Q1.** You cannot, because VPC security groups support **allow rules only**. There is no deny primitive (`authorize` / `revoke` are the only verbs — `revoke` removes an allow, it does not create a deny). Whatever you do not explicitly allow is implicitly denied, but you cannot carve an exception *out of* a broader allow. The construct that can express deny is the **network ACL**, which has an explicit `RuleAction: deny` and evaluates rules in ascending rule-number order, so a low-numbered deny shadows a higher-numbered allow. Practically, blocking a single hostile IP belongs on the NACL (subnet-wide) or, for HTTP, on an AWS WAF IP-set block rule.

**Q2.** AWS does not resolve the referenced group to a fixed IP list. At packet time, the rule means "the traffic's source ENI is a member of security group `sg-...web`". Membership is evaluated dynamically, so when Auto Scaling replaces a web instance with a new private IP, the DB rule keeps working with no change. This is the single strongest argument for SG-referencing over CIDR rules in an elastic architecture — and it is why NACLs, which only understand CIDRs, are the wrong place for tier-to-tier rules.

**Q3.** AWS attaches a default egress rule of `IpProtocol: -1` to `0.0.0.0/0` to every newly created security group — all outbound traffic permitted. The moment you call `authorize-security-group-egress` yourself, that default rule is still there; it is not removed automatically. To get restrictive egress you must **explicitly revoke** the `0.0.0.0/0` all-protocol rule with `revoke-security-group-egress` after adding your own. Forgetting this is the commonest reason a "locked down" security group still allows full outbound.

**Q4.** With deny at 100 and allow at 90, `198.51.100.7` is **allowed**. NACL evaluation walks rules in ascending numeric order and stops at the first match. Rule 90 (`allow 0.0.0.0/0:80`) matches `198.51.100.7` first, so the packet is permitted and rule 100 is never reached. Deny rules must always be numbered **lower** than the broader allow they are carving out of. This is why the conventional numbering scheme leaves gaps (10, 20, 30…) — you need room to insert a deny above an existing allow.

**Q5.** No, the response does not reach the browser. NACLs are **stateless**: the inbound and outbound rule sets are evaluated independently, and a permitted inbound flow creates no state entry authorising its own reply. The reply is a *new outbound evaluation* — source port 80, destination the client's ephemeral port — and the custom NACL's only outbound entry is rule 32767 `deny all`. The reply is dropped at the subnet boundary. The connection appears to hang and times out (exactly the `curl` exit 28 in step 11).

**Q6.**

| | Security group | Network ACL |
|---|---|---|
| Attaches to | ENI (instance / ALB node / RDS endpoint) | Subnet |
| Stateful? | **Yes** — return traffic is automatically allowed | **No** — inbound and outbound evaluated independently |
| Supports deny? | No, allow-only | Yes, `allow` and `deny` |
| Rule evaluation | All rules evaluated; if any allows, permit | First match wins, ascending rule number, then implicit `*` deny |
| Can reference another SG as source | Yes (and prefix lists) | No — CIDR blocks only |
| Default (custom-created) posture | All inbound denied, all outbound allowed | All traffic denied in **both** directions until you add rules |

Two extras worth knowing: an ENI can carry multiple security groups (rules are unioned), whereas a subnet has exactly one NACL; and the *default* NACL AWS creates with a VPC allows everything, unlike a NACL you create yourself.

**Q7.** The **outbound (egress) implicit deny — rule 32767 — on the custom NACL** dropped the reply. Trace it: inbound NACL rule 100 allowed TCP/80 → security group inbound allowed TCP/80 → nginx answered → security group egress permitted the reply statefully (and by its catch-all) → outbound NACL evaluation found no matching allow → rule 32767 `deny` fired.

**Q8.** The **client** picks the ephemeral source port when it opens the connection; the server's reply is addressed *to* that port, so the NACL egress rule must cover the whole plausible range rather than port 80. Ranges differ by stack: modern Linux kernels use `32768–60999`, Windows Server 2008+ uses `49152–65535`, an Elastic Load Balancer uses `1024–65535`, and a NAT gateway uses `1024–65535`. Because a subnet's NACL sees traffic from all of these, `1024–65535` is the safe superset — and the fact that you are forced to open 64,000 ports outbound is precisely why NACLs are a blunt instrument compared to a stateful security group.

**Q9.** **Defence in depth with the control at the right granularity.** The security group is the per-workload, identity-aware, stateful control: it can say "only the web tier may reach the DB on 3306" without knowing an IP, and it needs no ephemeral-port bookkeeping. The NACL is the coarse, subnet-wide backstop: it is the only place that can express deny, it applies even if someone misconfigures a security group, and it is the right place for CIDR-level blocks (a known-hostile netblock, or "this data subnet never talks to the internet"). Trying to express fine-grained tier rules in NACLs runs you into the 20-rule soft limit (40 hard), the stateless ephemeral-port problem, and the loss of SG-referencing.

---

### Lab 2 — WAF, Shield, Firewall Manager, Network Firewall

**Q10.** For each incoming request: evaluate rules in priority order (0 first); if the Common Rule Set matches a malicious pattern, apply the rule group's action and stop; else if this source IP has sent more than 2,000 requests in the trailing 5-minute window, block and stop; else fall through to the default action and allow the request.

**Q11.** A security group inspects **layer 3/4** only — IP addresses, protocol, port numbers. An SQL injection arrives as a perfectly legitimate TCP/443 connection from an arbitrary IP; the malicious content is in the HTTP body or query string, which the security group never parses. AWS WAF inspects **layer 7** — it parses the HTTP request (URI, headers, body, cookies, query args) and can match on content. Conversely, WAF only attaches to HTTP(S)-terminating resources (CloudFront, ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access), so an SSH brute force on TCP/22 to an EC2 instance never passes through it — that is security-group and GuardDuty territory.

**Q12.** **Two web ACLs.** WAF scope is not just a label — a `REGIONAL` web ACL and a `CLOUDFRONT` web ACL are distinct resource types with distinct ARNs, and a single web ACL can only be associated with resources of its own scope. The ALB needs a `REGIONAL` web ACL in the ALB's Region; the CloudFront distribution needs a `CLOUDFRONT`-scope web ACL created in **`us-east-1`**, because CloudFront is a global service whose control plane lives there. (In practice you would put the real rules on the CloudFront ACL and use the ALB ACL to enforce that requests actually came through CloudFront.)

**Q13.**

| Rank | Service | Cost / effort | Exam keyword |
|---|---|---|---|
| 1 | **Shield Standard** | Free, automatic, no configuration | "no additional cost", "automatically protects against common L3/L4 DDoS" |
| 2 | **AWS WAF** | ~$5/ACL + $1/rule + $0.60/M requests | "SQL injection", "XSS", "rate limit by IP", "block by country", "OWASP" |
| 3 | **AWS Network Firewall** | Endpoint-hour + GB processed | "IDS/IPS for the whole VPC", "Suricata rules", "egress filtering by domain" |
| 4 | **Shield Advanced** | $3,000/month per organization, 1-year commitment | "24×7 Shield Response Team", "DDoS cost protection", "large-scale/sophisticated DDoS" |

**Q14.** **AWS Firewall Manager.** Its two hard prerequisites: (1) the account must be part of an **AWS Organizations** organization with all features enabled, and a Firewall Manager **administrator account** must be designated by the management account; (2) **AWS Config must be enabled** in every member account and Region in scope, because Firewall Manager uses Config to discover resources and evaluate compliance. A Firewall Manager policy both auto-remediates (attaches the web ACL to newly created ALBs) and reports non-compliant resources.

**Q15.** Shield Advanced **cost protection** refunds the scaling charges you incur *because of* a covered DDoS attack — the extra EC2/ELB/CloudFront/Route 53/Global Accelerator usage the attack drove, granted as service credits after a claim. This matters specifically on elastic architectures because the attack's damage is not downtime, it is the bill: Auto Scaling and CloudFront do their job, absorb 40 Gbps of garbage, and hand you an enormous data-transfer and instance-hour invoice. Without cost protection, "the architecture survived" and "the attack was expensive" are the same event.

---

### Lab 3 — Detection and posture

**Q16.** GuardDuty consumes those log streams through **an internal, service-to-service path**, not by reading logs from your account. It does not require you to enable VPC Flow Logs, create a CloudTrail trail, or install an agent, and the data it ingests does not appear in — or bill against — your own CloudWatch Logs, S3, or Flow Log costs. You pay only GuardDuty's own per-event / per-GB-analysed price. That "agentless, zero-prerequisite" property is exactly what exam questions test: if a scenario says "without deploying software or enabling additional logging," the answer is GuardDuty.

**Q17.** The `!DNS` suffix identifies **DNS logs** as the data source (specifically, queries resolved by the Amazon-provided VPC DNS resolver — this finding type only fires if your instances use the default resolver). GuardDuty is asserting that an EC2 instance in your account issued DNS queries for a domain associated with a cryptocurrency mining pool — the behavioural signature of an instance that has been compromised and enrolled in cryptomining. It is an *activity* finding, not a vulnerability: GuardDuty is not saying the instance is unpatched, it is saying the instance is currently misbehaving.

**Q18.** (a) **Amazon Inspector** — CVE matching against container image contents in ECR. (b) **Amazon GuardDuty** — real-time behavioural threat detection from network and DNS telemetry. (c) **Amazon Macie** — sensitive-data discovery and classification in S3. (d) **Amazon Detective** — the behaviour graph that links findings, API calls and network flows into an investigation timeline. (e) **AWS Security Hub** — cross-account aggregation and automated security-standard scoring.

**Q19.** Detective's value is derived: it ingests GuardDuty findings as investigation entry points, alongside CloudTrail management events and VPC Flow Logs, and stitches them into a behaviour graph. So **GuardDuty must be enabled first** — in fact, an account must have had GuardDuty enabled for at least 48 hours before Detective can be enabled. In an account where GuardDuty never ran there are no findings to pivot from, and Detective has nothing to investigate; you would be paying for a graph with no starting point. The clean mental model: **GuardDuty tells you *that* something happened; Detective helps you work out *how*.**

**Q20.** The **AWS Security Finding Format (ASFF)** — a defined JSON schema covering severity, resource, compliance status, remediation, and workflow state. Because Security Hub ingests and emits ASFF, any third-party product from AWS Marketplace (a Palo Alto, CrowdStrike, Tenable, Qualys integration) can publish findings into the same pane of glass as GuardDuty and Inspector, and any downstream automation — an EventBridge rule, a ticketing integration, a Lambda auto-remediation — can be written once against one schema instead of once per vendor. Normalisation is the product.

---

### Lab 4 — Data protection

**Q21.** The key ARN is embedded in the ciphertext blob, so KMS knows which key to use without being told. Authorization is enforced **entirely on the server side, at KMS**, and requires **both**: (1) the **IAM policy** attached to your principal must allow `kms:Decrypt`, and (2) the **KMS key policy** on that key must allow your principal (directly, or by delegating to IAM with a `Principal: {"AWS": "arn:aws:iam::111122223333:root"}` statement plus `kms:ViaService`/grants). This dual control is why a KMS key is a genuine second line of defence: an over-permissive IAM policy alone does not grant access to the data, and deleting a key policy statement locks out even an account administrator.

**Q22.** **AWS CloudHSM.** It is single-tenant, FIPS 140-validated Level 3 hardware where you — not AWS — create and manage the HSM users (CO, CU, AU) and the key material; AWS operates the hardware but has no cryptographic access. The burdens you inherit: (1) **you own key durability and availability** — if you lose your crypto-officer credentials or destroy your cluster's last HSM without a backup, the keys and everything encrypted with them are unrecoverable, and you must design a multi-AZ cluster and quorum/backup strategy yourself; (2) **you own the client integration** — applications must use PKCS#11, JCE, OpenSSL Dynamic Engine or KSP/CNG libraries rather than getting transparent encryption from S3/EBS/RDS, and you pay per HSM-hour whether or not you use it. Choose it only when a regulation demands it; otherwise KMS (optionally backed by a CloudHSM custom key store) is the right default.

**Q23.** **No re-encryption is needed.** Automatic rotation creates new **backing key material** for the same logical KMS key; the key ID and ARN never change. Your S3 object's stored ciphertext is encrypted under an unchanged **data key**, and the *wrapped* data key stored beside it records which backing key encrypted it. KMS retains every prior backing key version indefinitely for decryption, so old wrapped keys keep unwrapping. Rotation only affects new encryption operations. The corollary that catches people: rotation does *not* reduce the blast radius of an already-leaked plaintext data key, and it does not re-encrypt anything — if you need genuine re-encryption you must call `ReEncrypt` or rewrite the objects yourself.

**Q24.** **AWS Secrets Manager.** It is the only one of the two with built-in scheduled rotation driven by an AWS-provided Lambda rotation function, including ready-made templates for RDS/Aurora/Redshift/DocumentDB that coordinate the password change on both the secret and the database. Both services encrypt with KMS and both are readable from ECS and Lambda via IAM. The trade you accept is cost: Secrets Manager is **$0.40 per secret per month plus $0.05 per 10,000 API calls**, whereas SSM Parameter Store **Standard** parameters are free (Advanced parameters are $0.05/parameter/month). If you were rotating manually anyway, Parameter Store `SecureString` is the cheaper correct answer — the rotation requirement is what forces Secrets Manager.

**Q25.** **Two certificates.** ACM certificates are Regional resources and cannot be used across Regions. The one consumed by **CloudFront must be requested in `us-east-1`**, because CloudFront's control plane is there — this is true no matter where your origin lives. The RDS case is a trick: RDS uses **AWS-managed RDS CA certificates** for its TLS endpoint, not ACM public certificates, so in practice you would issue the ACM certificate for the load balancer or CloudFront in front of the application, not for RDS itself. The general rule to carry into the exam: *one ACM certificate per Region where a resource terminates TLS, and CloudFront always means `us-east-1`.*

**Q26.** (a) **AWS KMS** — EBS volume encryption uses a KMS key (`alias/aws/ebs` by default, or your own customer managed key) with envelope encryption; the volume data is encrypted with a data key, transparently, by the EBS service. (b) **AWS Secrets Manager** (or SSM Parameter Store `SecureString` if no rotation is needed) — an application-read credential. (c) **AWS Certificate Manager** — a free, auto-renewing public certificate associated with the Application Load Balancer's HTTPS listener.

---

### Lab 5 — Governance and audit

**Q27.** "Was it ever public, and for how long?" → **AWS Config.** Config records a timestamped **configuration item** every time a resource's state changes and keeps a configuration timeline, so you can see the bucket's policy at any point and the interval during which the public statement existed; a Config rule such as `s3-bucket-public-read-prohibited` would also have flagged it as NON_COMPLIANT for that interval. CloudTrail cannot answer it directly because CloudTrail records events, not state — you would have to reconstruct the state by replaying every `PutBucketPolicy`/`PutBucketAcl` call and reasoning about the resulting policy, which is not what it is for.

"Which principal made it public?" → **AWS CloudTrail.** The `PutBucketPolicy` event carries `userIdentity` (the IAM principal, assumed role, session name), `sourceIPAddress`, `userAgent`, and the request parameters. Config records *that* the configuration changed and can even name the related CloudTrail event ID, but the identity, source IP and API context live in CloudTrail.

The one-line version: **CloudTrail = who did what (verbs, identity). Config = what the state was and whether it complied (nouns, timeline).** In a real investigation you use both, and Config's configuration item conveniently links to the CloudTrail event that caused it.

**Q28.** Two-part reason: (1) **CloudTrail Event history retains only 90 days**, and (2) it covers **management events only** — data events (S3 object-level GET/PUT, Lambda invokes) never appear there at all. The configuration change that prevents the gap is to **create a trail** — ideally a multi-Region, organization-wide trail delivering to an S3 bucket (with log file validation enabled, and ideally in a separate log-archive account with Object Lock). Retention is then bounded only by your S3 lifecycle policy, and you can additionally select data event types. Note that a trail is not retroactive: creating one today does nothing about the missing four months, which is why "enable a trail on day one" is a standard landing-zone control.

**Q29.** It is a **static policy analysis / linting tool** — automated reasoning over the policy document, producing validation, security-warning, error and suggestion findings without deploying anything or observing any traffic. It belongs **shift-left, in CI**: run `aws accessanalyzer validate-policy` (and `check-no-new-access` / `check-access-not-granted` for custom policy checks) against IAM policies in your Terraform/CloudFormation on every pull request, and fail the build on `ERROR` and `SECURITY_WARNING`. Catching `PASS_ROLE_WITH_STAR_IN_RESOURCE` at review time costs a comment; catching it after deployment costs an incident, because `iam:PassRole` on `*` is a textbook privilege-escalation path.

**Q30.**
- **IAM Access Analyzer external access findings:** identifies resources (S3 buckets, IAM roles, KMS keys, Lambda functions, SQS queues, Secrets Manager secrets…) whose resource-based policy grants access to a principal **outside your defined zone of trust** (account or organization). Uses provable, automated reasoning; this finding class is **free**.
- **IAM Access Analyzer unused access findings:** identifies IAM users, roles, access keys, passwords and **permissions that have not been used** within a configurable tracking period, so you can right-size toward least privilege. This is a **paid** analyzer type, priced per IAM role/user analysed.
- **Trusted Advisor security checks:** a fixed catalogue of **best-practice checks** across your account — public S3 buckets, security groups open to `0.0.0.0/0` on sensitive ports, MFA missing on the root user, exposed access keys, IAM use, expiring ACM certificates. Core checks are available to all accounts; the full multi-pillar catalogue and the Support API require Business, Enterprise On-Ramp, or Enterprise Support.

---

### Lab 6 — Information and compliance sources

**Q31.** You download AWS's SOC 2 Type II report from **AWS Artifact**, in the AWS Management Console, at no charge — you accept the terms and it downloads as a PDF. The constraint is that it is provided under a **confidentiality agreement (NDA)** accepted as part of the download; you may share it with your customer's auditors under that agreement, but you may not publish it. Critically, it covers **only AWS's side of the shared responsibility model** — the security *of* the cloud: AWS's data centres, hardware, hypervisor, managed-service control planes. It says nothing about your application code, your IAM policies, your S3 bucket policies, or your patching. For your own SOC 2 you need your own audit, in which AWS's report is inherited evidence for the infrastructure controls, not a substitute.

**Q32.** **AWS Artifact** is the self-service portal where you download **AWS's own** third-party audit reports and certifications (SOC, ISO, PCI, FedRAMP) and accept legal agreements such as the HIPAA BAA — it is about *AWS's* compliance. **AWS Audit Manager** continuously collects evidence from **your** AWS usage (CloudTrail events, Config rule evaluations, Security Hub findings, resource snapshots) and maps it to prebuilt or custom frameworks so you can produce an assessment report for **your** auditor — it is about *your* compliance. Mnemonic: *Artifact downloads AWS's paperwork; Audit Manager builds yours.*

**Q33.** **No prior approval is needed** for the first two. AWS permits customer security testing without approval against eight service categories, which include **EC2 instances, NAT gateways and load balancers**, **RDS**, **CloudFront**, **Aurora**, **API Gateway**, **Lambda and Lambda@Edge**, **Lightsail resources**, and **Elastic Beanstalk environments** — against your own resources, within the AWS Customer Support Policy for Penetration Testing.

The 20 Gbps traffic-generation test is different: it is a **simulated DDoS / network stress test**, which is a prohibited activity unless authorised in advance. You must submit the **Simulated Events form** and get approval, and stress tests above defined thresholds (AWS documents a volume threshold above which pre-approval is mandatory) generally must be run through an **APN-approved testing partner**. The same pre-approval path covers phishing simulations, malware testing and red-team exercises. Also prohibited outright without approval: DNS zone walking, port/protocol/request flooding, and any testing against resources you do not own.

**Q34.** For **your** resources: **Amazon Inspector** — it maintains a continuously updated software inventory of your EC2 instances (via the SSM agent), ECR container images and Lambda functions, matches it against CVE feeds, and produces findings with a risk score and the affected package/version, so a new OpenSSL CVE surfaces automatically without you scheduling a scan. For **AWS-managed services**: the **AWS Security Bulletins** page (https://aws.amazon.com/security/security-bulletins/), where AWS publishes `AWS-YYYY-NNN` advisories stating which AWS services are affected and what, if anything, customers must do. The pairing is the point — Inspector cannot see inside a managed service, and a security bulletin cannot tell you about your own unpatched instance.

</details>

---

## Official sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- Amazon VPC security (security groups, NACLs) — https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html
- AWS WAF, Shield and Firewall Manager Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/what-is-aws-waf.html
- AWS Network Firewall Developer Guide — https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- Amazon GuardDuty User Guide — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- Amazon Inspector User Guide — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie User Guide — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective User Guide — https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- AWS Security Hub User Guide — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS KMS Developer Guide — https://docs.aws.amazon.com/kms/latest/developerguide/overview.html
- AWS CloudHSM User Guide — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- AWS Certificate Manager User Guide — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- AWS Config Developer Guide — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Audit Manager User Guide — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- AWS Security Bulletins — https://aws.amazon.com/security/security-bulletins/
- AWS Knowledge Center / re:Post — https://repost.aws/knowledge-center
- AWS Customer Support Policy for Penetration Testing — https://aws.amazon.com/security/penetration-testing/
- AWS Marketplace (Security category) — https://aws.amazon.com/marketplace/
- AWS Well-Architected Framework, Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html