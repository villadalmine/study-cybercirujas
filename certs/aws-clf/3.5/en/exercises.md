# Topic 3.5 — Identify AWS Network Services
## Guided Exercises (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

**Exam weight in Domain 3:** 4.25 % of the total scored content.
**Reference:** [CLF-C02 Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

## 0. Before you start

### 0.1 What this lab builds

You will hand-build a two-tier VPC, then walk outward through every layer of the AWS network stack the exam names: the VPC data plane (subnets, route tables, IGW, NAT), the two firewalls (security groups and network ACLs), private service access (VPC endpoints / PrivateLink), the load balancing family (ALB / NLB / GWLB), DNS (Route 53), the global edge (CloudFront, Global Accelerator), hybrid connectivity (Site-to-Site VPN, Direct Connect, Transit Gateway, peering), and the diagnostic tooling (Flow Logs, Reachability Analyzer).

The CLF-C02 exam asks you to *identify* these services — which one solves which problem. This lab makes you touch them, because "identify" questions are almost always disguised trade-off questions ("lowest cost", "no code change", "static IP", "layer 7 routing"), and trade-offs stick when you have seen the API return them.

### 0.2 Prerequisites

```bash
aws --version
# aws-cli/2.17.42 Python/3.11.9 linux/6.8.0 exe/x86_64.rpm

aws sts get-caller-identity
```

```json
{
    "UserId": "AIDASAMPLEUSERID0000",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333/clf-lab"
}
```

Set a working region and disable the pager so output stays scriptable:

```bash
export AWS_REGION=us-east-1
export AWS_PAGER=""
```

You also need `dig` (`bind-utils` / `dnsutils`) and `curl`.

### 0.3 Cost ledger — read this before you run anything

Almost every step below is free. The ones that are not are marked **`💲 BILLABLE`** and are optional. Prices are `us-east-1` list price and change; the authoritative figure is always on the service's pricing page.

| Resource | Price (us-east-1, list) | Used in |
|---|---|---|
| VPC, subnets, route tables, IGW, security groups, NACLs, peering connection | free | 1, 2, 4, 9 |
| Gateway VPC endpoint (S3 / DynamoDB) | free | 5 |
| Public IPv4 address (incl. idle Elastic IP) | $0.005 / hour each | 3 |
| NAT Gateway | $0.045 / hour + $0.045 / GB processed | 3 |
| Interface VPC endpoint (PrivateLink) | ~$0.01 / hour per AZ + $0.01 / GB | 5 |
| Application / Network Load Balancer | $0.0225 / hour + LCU charges | 6 |
| Route 53 public hosted zone | $0.50 / month + $0.40 / million queries | 7 |
| VPC Flow Logs | CloudWatch Logs ingestion (~$0.50 / GB) | 10 |
| Reachability Analyzer | $0.10 per analysis | 10 |

Sources: [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/), [ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/), [Route 53 pricing](https://aws.amazon.com/route53/pricing/).

Section 11 is a full teardown. Run it.

---

## Exercise 1 — The VPC and its address space

A VPC is a logically isolated, software-defined network scoped to **one Region**, spanning **all Availability Zones** in that Region. A subnet is scoped to **exactly one AZ**. That asymmetry is the single most tested fact about VPC topology.

### Steps

1. Look at what AWS already gave you. Every Region ships with a default VPC:

```bash
aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Tenancy:InstanceTenancy,State:State}' \
  --output table
```

```
-------------------------------------------------------------
|                       DescribeVpcs                        |
+---------------+-----------------+----------+--------------+
|     Cidr      |     State       | Tenancy  |    VpcId     |
+---------------+-----------------+----------+--------------+
|  172.31.0.0/16|  available      |  default |  vpc-0d8e... |
+---------------+-----------------+----------+--------------+
```

2. Create your own VPC with a deliberately chosen, non-overlapping RFC 1918 range:

```bash
export VPC=$(aws ec2 create-vpc \
  --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf35-lab}]' \
  --query 'Vpc.VpcId' --output text)
echo "$VPC"
```

```
vpc-0a1b2c3d4e5f67890
```

3. Prove the CIDR size boundaries. The allowed prefix length for a VPC is `/16` (65 536 addresses) through `/28` (16 addresses). Try to break it:

```bash
aws ec2 create-vpc --cidr-block 10.43.0.0/8
```

```
An error occurred (InvalidVpc.Range) when calling the CreateVpc operation:
The CIDR '10.43.0.0/8' is invalid.
```

4. Turn on DNS hostnames (DNS resolution is on by default; hostnames are not, outside the default VPC):

```bash
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames

aws ec2 describe-vpc-attribute --vpc-id "$VPC" --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value'
```

```
true
```

5. Create four subnets — a public and a private tier across two AZs. Multi-AZ is not decoration: it is the *only* way a VPC-based workload survives an AZ failure.

```bash
export PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.42.0.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=clf35-public-a}]' \
  --query 'Subnet.SubnetId' --output text)

export PUB_B=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.42.1.0/24 \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=clf35-public-b}]' \
  --query 'Subnet.SubnetId' --output text)

export PRIV_A=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.42.10.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=clf35-private-a}]' \
  --query 'Subnet.SubnetId' --output text)

export PRIV_B=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.42.11.0/24 \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=clf35-private-b}]' \
  --query 'Subnet.SubnetId' --output text)

printf 'pub-a=%s pub-b=%s priv-a=%s priv-b=%s\n' "$PUB_A" "$PUB_B" "$PRIV_A" "$PRIV_B"
```

6. Count the usable addresses. A `/24` has 256 addresses — but AWS does not give you 256:

```bash
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'sort_by(Subnets,&CidrBlock)[].{Name:Tags[?Key==`Name`]|[0].Value,Cidr:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount}' \
  --output table
```

```
--------------------------------------------------------------------
|                          DescribeSubnets                         |
+--------------+---------------+-------+---------------------------+
|      AZ      |     Cidr      | Free  |           Name            |
+--------------+---------------+-------+---------------------------+
|  us-east-1a  |  10.42.0.0/24 |  251  |  clf35-public-a           |
|  us-east-1b  |  10.42.1.0/24 |  251  |  clf35-public-b           |
|  us-east-1a  |  10.42.10.0/24|  251  |  clf35-private-a          |
|  us-east-1b  |  10.42.11.0/24|  251  |  clf35-private-b          |
+--------------+---------------+-------+---------------------------+
```

AWS reserves **five** addresses in every subnet: the network address (`.0`), the VPC router (`.1`), the Amazon-provided DNS resolver (`.2`, which is also reachable at the VPC CIDR base + 2 and at the link-local `169.254.169.253`), a `.3` held for future use, and the broadcast address (`.255`) — broadcast is not supported in a VPC at all. See [Subnet CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html).

> **Verification questions**
> **Q1.** A VPC lives in one Region and spans all its AZs. What is the scope of a subnet, and why does that make "one subnet per tier" an anti-pattern?
> **Q2.** You size a subnet as `/28`. How many IP addresses can your instances actually use, and why is the answer not 16?
> **Q3.** Your on-premises data centre already uses `10.0.0.0/16`. Why does choosing `10.0.0.0/16` for your VPC create a problem you cannot fix later without rebuilding?
> **Q4.** What is the smallest and largest CIDR prefix AWS accepts for a VPC?

---

## Exercise 2 — Internet Gateway and route tables: what actually makes a subnet "public"

There is no `public: true` flag on a subnet. A subnet is public if and only if its associated route table has a route to an Internet Gateway.

### Steps

1. Inspect the **main route table** AWS created with the VPC. Every subnet you do not explicitly associate falls back to this one:

```bash
aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values=$VPC Name=association.main,Values=true \
  --query 'RouteTables[].{Rtb:RouteTableId,Routes:Routes[].{Dest:DestinationCidrBlock,Target:GatewayId,State:State}}'
```

```json
[
    {
        "Rtb": "rtb-05f9c1a2b3d4e5f60",
        "Routes": [
            {
                "Dest": "10.42.0.0/16",
                "Target": "local",
                "State": "active"
            }
        ]
    }
]
```

That `local` route is implicit, cannot be deleted, and cannot be overridden. It is why every subnet in a VPC can reach every other subnet in the same VPC by default, regardless of AZ.

2. Create and attach an Internet Gateway. An IGW is a horizontally scaled, redundant, **Region-level** VPC component — it has no bandwidth constraint and no availability risk you can influence:

```bash
export IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=clf35-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
echo "$IGW"
```

```
igw-0c7d8e9f0a1b2c3d4
```

3. Build the public route table and point the default route at the IGW:

```bash
export RTB_PUB=$(aws ec2 create-route-table --vpc-id "$VPC" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=clf35-rtb-public}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "$RTB_PUB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"
```

```json
{ "Return": true }
```

4. Associate it with both public subnets, and turn on auto-assign public IPv4:

```bash
for S in "$PUB_A" "$PUB_B"; do
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$S" \
    --query 'AssociationId' --output text
  aws ec2 modify-subnet-attribute --subnet-id "$S" --map-public-ip-on-launch
done
```

```
rtbassoc-0aa11bb22cc33dd44
rtbassoc-0ee55ff66aa77bb88
```

5. Create a private route table with **no** `0.0.0.0/0` route and attach it to the private subnets:

```bash
export RTB_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=clf35-rtb-private}]' \
  --query 'RouteTable.RouteTableId' --output text)

for S in "$PRIV_A" "$PRIV_B"; do
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$S" \
    --query 'AssociationId' --output text
done
```

6. Read the final routing picture:

```bash
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Main:Associations[0].Main,Subnets:Associations[].SubnetId,Routes:Routes[].[DestinationCidrBlock,GatewayId]}' \
  --output json
```

```json
[
  {
    "Name": null, "Main": true, "Subnets": [null],
    "Routes": [["10.42.0.0/16", "local"]]
  },
  {
    "Name": "clf35-rtb-public", "Main": false,
    "Subnets": ["subnet-0aaa...", "subnet-0bbb..."],
    "Routes": [["10.42.0.0/16", "local"], ["0.0.0.0/0", "igw-0c7d8e9f0a1b2c3d4"]]
  },
  {
    "Name": "clf35-rtb-private", "Main": false,
    "Subnets": ["subnet-0ccc...", "subnet-0ddd..."],
    "Routes": [["10.42.0.0/16", "local"]]
  }
]
```

> **Verification questions**
> **Q5.** Name the two conditions that must both be true for an EC2 instance to be reachable from the internet over IPv4, beyond firewall rules.
> **Q6.** You delete the `0.0.0.0/0 → igw-...` route from `clf35-rtb-public`. Can instances in `clf35-public-a` still reach instances in `clf35-private-b`? Why?
> **Q7.** A colleague launches an instance in a brand-new subnet and forgets to associate a route table. Which routing applies, and what does that mean for internet access in this VPC?
> **Q8.** Why is an Internet Gateway not a single point of failure you need to design around, unlike a NAT Gateway?

---

## Exercise 3 — Egress without ingress: NAT Gateway, NAT instance, egress-only IGW

Private subnets frequently need *outbound* internet (OS patches, `pip install`, calling a third-party API) while remaining unreachable from outside. Three mechanisms exist, and the exam distinguishes them by IP version and by managed-vs-self-managed.

### Steps

1. Look at the current public IPv4 pricing reality first. Since 2024, **every** public IPv4 address is billed, attached or not:

```bash
aws ec2 describe-addresses --query 'Addresses[].{Ip:PublicIp,Assoc:AssociationId,Alloc:AllocationId}' --output table
```

```
-----------------------------------------------------
|                 DescribeAddresses                 |
+----------------+-------------+--------------------+
|     Alloc      |   Assoc     |         Ip         |
+----------------+-------------+--------------------+
+----------------+-------------+--------------------+
```

2. **`💲 BILLABLE`** — Allocate an Elastic IP and create a NAT Gateway in a **public** subnet. A NAT Gateway is AZ-scoped: it is a resource *inside one AZ*, and it dies with that AZ.

```bash
export EIP=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=clf35-nat-eip}]' \
  --query 'AllocationId' --output text)

export NAT=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_A" --allocation-id "$EIP" --connectivity-type public \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=clf35-nat-a}]' \
  --query 'NatGateway.NatGatewayId' --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"
aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT" \
  --query 'NatGateways[].{Id:NatGatewayId,State:State,Subnet:SubnetId,Az:NatGatewayAddresses[0].PublicIp}' --output table
```

```
-----------------------------------------------------------------------------
|                            DescribeNatGateways                            |
+-----------------+----------------------+------------+--------------------+
|       Az        |         Id           |   State    |       Subnet       |
+-----------------+----------------------+------------+--------------------+
|  54.210.11.203  |  nat-06f1a2b3c4d5e6f |  available |  subnet-0aaa...    |
+-----------------+----------------------+------------+--------------------+
```

Note the subnet: the NAT Gateway sits in `clf35-public-a`, not in the private subnet it serves. Placing it in a private subnet is the classic misconfiguration — it needs its own IGW route to work.

3. Point the private route table at it:

```bash
aws ec2 create-route --route-table-id "$RTB_PRIV" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"
```

```json
{ "Return": true }
```

4. Add IPv6 to the VPC and observe the different egress primitive. IPv6 addresses in AWS are **all globally routable** — there is no "private IPv6" — so the NAT concept does not apply; you use an **egress-only Internet Gateway** instead:

```bash
aws ec2 associate-vpc-cidr-block --vpc-id "$VPC" --amazon-provided-ipv6-cidr-block \
  --query 'Ipv6CidrBlockAssociation.{Cidr:Ipv6CidrBlock,State:Ipv6CidrBlockState.State}'

export EIGW=$(aws ec2 create-egress-only-internet-gateway --vpc-id "$VPC" \
  --query 'EgressOnlyInternetGateway.EgressOnlyInternetGatewayId' --output text)
echo "$EIGW"
```

```
eigw-0b3c4d5e6f7a8b9c0
```

An egress-only IGW is free, stateful, and horizontally scaled like a regular IGW — it simply refuses to forward inbound-initiated traffic.

5. Delete the NAT Gateway now if you created it; it bills per hour whether idle or not:

```bash
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT"
aws ec2 release-address --allocation-id "$EIP"
```

Reference: [NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html).

> **Verification questions**
> **Q9.** In which subnet must a public NAT Gateway be created, and which route table must be modified to make it useful?
> **Q10.** Give two operational reasons to choose a NAT Gateway over a self-managed NAT instance on EC2, and the one reason a team might still pick the NAT instance.
> **Q11.** Your architecture needs outbound-only internet for IPv6-addressed workloads. Which component do you use, and why is a NAT Gateway the wrong answer?
> **Q12.** A single NAT Gateway serves private subnets in `us-east-1a` and `us-east-1b`. Describe both the availability problem and the cost problem this creates.

---

## Exercise 4 — The two firewalls: security groups vs. network ACLs

This is the highest-yield comparison in Topic 3.5. Both filter traffic; they differ in attachment point, statefulness, rule semantics, and evaluation order.

### Steps

1. Look at the default security group AWS created with the VPC:

```bash
export SG_DEF=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$VPC Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 describe-security-groups --group-ids "$SG_DEF" \
  --query 'SecurityGroups[0].{In:IpPermissions,Out:IpPermissionsEgress}'
```

```json
{
    "In": [
        {
            "IpProtocol": "-1",
            "IpRanges": [],
            "UserIdGroupPairs": [
                { "GroupId": "sg-0f1e2d3c4b5a69780", "UserId": "111122223333" }
            ]
        }
    ],
    "Out": [
        { "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }] }
    ]
}
```

Read that carefully: the default SG allows inbound **from itself** (members can talk to members) and outbound to everywhere.

2. Create a purpose-built web security group. A brand-new SG has **zero inbound rules** and allow-all outbound:

```bash
export SG_WEB=$(aws ec2 create-security-group \
  --group-name clf35-web --description "Public web tier" --vpc-id "$VPC" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description="public HTTPS"}]' \
  --query 'SecurityGroupRules[].{Rule:SecurityGroupRuleId,Port:FromPort,Cidr:CidrIpv4}' --output table
```

```
------------------------------------------------------------
|            AuthorizeSecurityGroupIngress                 |
+-------------+--------+----------------------------------+
|    Cidr     |  Port  |               Rule               |
+-------------+--------+----------------------------------+
|  0.0.0.0/0  |  443   |  sgr-0a1b2c3d4e5f60718           |
+-------------+--------+----------------------------------+
```

3. Prove that a security group cannot express "deny". Try it:

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" \
  --protocol tcp --port 22 --cidr 203.0.113.7/32 --rule-action deny
```

```
Unknown options: --rule-action, deny
```

There is no such parameter. **Security groups are allow-only**; the absence of a matching allow rule *is* the deny.

4. Build the app tier and reference the web SG **as a source** — the idiom that makes VPC security composable, because it survives autoscaling and IP churn:

```bash
export SG_APP=$(aws ec2 create-security-group \
  --group-name clf35-app --description "Private app tier" --vpc-id "$VPC" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$SG_WEB,Description='from web tier only'}]" \
  --query 'SecurityGroupRules[].{Rule:SecurityGroupRuleId,Src:ReferencedGroupInfo.GroupId}' --output table
```

```
--------------------------------------------------------
|          AuthorizeSecurityGroupIngress               |
+----------------------------+-------------------------+
|            Rule            |          Src            |
+----------------------------+-------------------------+
|  sgr-09f8e7d6c5b4a3210      |  sg-0a1b2c3d4e5f60718  |
+----------------------------+-------------------------+
```

5. Now the other firewall. Inspect the default network ACL:

```bash
aws ec2 describe-network-acls --filters Name=vpc-id,Values=$VPC \
  --query 'NetworkAcls[].{Acl:NetworkAclId,Default:IsDefault,Entries:Entries[].{N:RuleNumber,Proto:Protocol,Action:RuleAction,Cidr:CidrBlock,Egress:Egress}}'
```

```json
[
  {
    "Acl": "acl-0d4e5f6a7b8c9d0e1",
    "Default": true,
    "Entries": [
      { "N": 100,   "Proto": "-1", "Action": "allow", "Cidr": "0.0.0.0/0", "Egress": false },
      { "N": 32767, "Proto": "-1", "Action": "deny",  "Cidr": "0.0.0.0/0", "Egress": false },
      { "N": 100,   "Proto": "-1", "Action": "allow", "Cidr": "0.0.0.0/0", "Egress": true },
      { "N": 32767, "Proto": "-1", "Action": "deny",  "Cidr": "0.0.0.0/0", "Egress": true }
    ]
  }
]
```

Rule `32767` is the immutable catch-all deny. The default NACL ships with a permissive `100 allow` in front of it, so it is effectively transparent.

6. Create a **custom** NACL and read its empty state — this is where teams get surprised:

```bash
export ACL=$(aws ec2 create-network-acl --vpc-id "$VPC" \
  --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=clf35-acl}]' \
  --query 'NetworkAcl.NetworkAclId' --output text)

aws ec2 describe-network-acls --network-acl-ids "$ACL" \
  --query 'NetworkAcls[0].Entries[].{N:RuleNumber,Action:RuleAction,Egress:Egress}' --output table
```

```
------------------------------------------
|          DescribeNetworkAcls           |
+---------+----------+-------------------+
| Action  | Egress   |         N         |
+---------+----------+-------------------+
|  deny   |  False   |  32767            |
|  deny   |  True    |  32767            |
+---------+----------+-------------------+
```

A custom NACL **denies everything in both directions** until you write rules.

7. Write a working inbound/outbound pair for HTTPS. Because a NACL is **stateless**, you must allow the return traffic explicitly — and return traffic goes to an **ephemeral port**, not back to 443:

```bash
aws ec2 create-network-acl-entry --network-acl-id "$ACL" --rule-number 100 \
  --protocol 6 --port-range From=443,To=443 --cidr-block 0.0.0.0/0 --rule-action allow --ingress

aws ec2 create-network-acl-entry --network-acl-id "$ACL" --rule-number 100 \
  --protocol 6 --port-range From=1024,To=65535 --cidr-block 0.0.0.0/0 --rule-action allow --egress

aws ec2 describe-network-acls --network-acl-ids "$ACL" \
  --query 'NetworkAcls[0].Entries[?RuleNumber!=`32767`].{N:RuleNumber,Ports:PortRange,Action:RuleAction,Egress:Egress}'
```

```json
[
  { "N": 100, "Ports": { "From": 443,  "To": 443   }, "Action": "allow", "Egress": false },
  { "N": 100, "Ports": { "From": 1024, "To": 65535 }, "Action": "allow", "Egress": true  }
]
```

The equivalent security group needs **one** rule (inbound 443) because it is stateful: the response to an allowed inbound flow is allowed out automatically, regardless of egress rules.

8. Demonstrate ordered evaluation — a lower rule number wins, and a deny placed in front is never reached by a later allow:

```bash
aws ec2 create-network-acl-entry --network-acl-id "$ACL" --rule-number 50 \
  --protocol 6 --port-range From=443,To=443 --cidr-block 198.51.100.0/24 \
  --rule-action deny --ingress
```

Rule 50 blocks `198.51.100.0/24` even though rule 100 allows `0.0.0.0/0`, because NACL evaluation stops at the first match in ascending rule-number order. A security group has no order at all — **all** rules are evaluated and any match allows.

References: [Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html), [Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html).

> **Verification questions**
> **Q13.** Fill in the comparison from what you observed: attachment point, stateful/stateless, allow-and-deny or allow-only, evaluation order, default posture for a *newly created* one.
> **Q14.** An engineer adds an inbound-443 rule to a security group and asks which outbound rule to add for the HTTP responses. What do you tell them, and why?
> **Q15.** The same engineer does the same on a custom NACL. Why is the answer different, and which port range does the outbound rule need?
> **Q16.** You must block a single abusive IP address, `203.0.113.9`, from reaching an entire subnet. Which of the two mechanisms can do it, and why can't the other?
> **Q17.** Why is `SG_APP` referencing `SG_WEB` by group ID more robust than allowing the web tier's subnet CIDR?

---

## Exercise 5 — Reaching AWS services privately: VPC endpoints and PrivateLink

By default, calling `s3.amazonaws.com` from a private subnet goes out over the internet path (via NAT). VPC endpoints keep that traffic on the AWS network. There are two kinds and they are billed very differently — a favourite exam distinction.

### Steps

1. Create a **Gateway endpoint** for S3. It is free, and it works by injecting a route into route tables:

```bash
export VPCE_S3=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC" \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids "$RTB_PRIV" \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=clf35-s3-gw}]' \
  --query 'VpcEndpoint.VpcEndpointId' --output text)
echo "$VPCE_S3"
```

```
vpce-0f1a2b3c4d5e6f708
```

2. Look at what it did to the private route table:

```bash
aws ec2 describe-route-tables --route-table-ids "$RTB_PRIV" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Prefix:DestinationPrefixListId,Target:GatewayId,State:State}'
```

```json
[
  { "Dest": "10.42.0.0/16", "Target": "local", "State": "active" },
  { "Prefix": "pl-63a5400a", "Target": "vpce-0f1a2b3c4d5e6f708", "State": "active" }
]
```

The destination is not a CIDR — it is a **managed prefix list**, an AWS-maintained set of the service's public IP ranges. Resolve it:

```bash
aws ec2 describe-prefix-lists --prefix-list-ids pl-63a5400a \
  --query 'PrefixLists[0].{Name:PrefixListName,Ranges:Cidrs|length(@)}'
```

```json
{ "Name": "com.amazonaws.us-east-1.s3", "Ranges": 42 }
```

3. Confirm the scope of Gateway endpoints. Only two services support them:

```bash
aws ec2 describe-vpc-endpoint-services \
  --filters Name=service-type,Values=Gateway \
  --query 'ServiceDetails[].ServiceName' --output text
```

```
com.amazonaws.us-east-1.dynamodb    com.amazonaws.us-east-1.s3
```

**S3 and DynamoDB. That is the complete list.** Everything else uses an Interface endpoint.

4. Examine what an **Interface endpoint** (AWS PrivateLink) looks like before creating one:

```bash
aws ec2 describe-vpc-endpoint-services \
  --service-names com.amazonaws.${AWS_REGION}.ssm \
  --query 'ServiceDetails[].{Name:ServiceName,Types:ServiceType[].ServiceType,PrivateDns:PrivateDnsName,AZs:AvailabilityZones}'
```

```json
[
  {
    "Name": "com.amazonaws.us-east-1.ssm",
    "Types": ["Interface"],
    "PrivateDns": "ssm.us-east-1.amazonaws.com",
    "AZs": ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
]
```

The mechanism is different: an Interface endpoint places an **elastic network interface with a private IP in each subnet you select**, and when `--private-dns-enabled` is set, a Route 53 private hosted zone overrides `ssm.us-east-1.amazonaws.com` inside your VPC so unmodified SDKs resolve to that private IP. No route table changes, no application changes.

5. **`💲 BILLABLE`** — Optional. Create it and read the assigned private IPs, then delete:

```bash
export VPCE_SSM=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC" --vpc-endpoint-type Interface \
  --service-name com.amazonaws.${AWS_REGION}.ssm \
  --subnet-ids "$PRIV_A" "$PRIV_B" \
  --security-group-ids "$SG_APP" --private-dns-enabled \
  --query 'VpcEndpoint.VpcEndpointId' --output text)

aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE_SSM" \
  --query 'VpcEndpoints[0].{State:State,ENIs:NetworkInterfaceIds,DNS:DnsEntries[].DnsName}'
```

```json
{
  "State": "available",
  "ENIs": ["eni-0a1b2c3d4e5f60718", "eni-08f7e6d5c4b3a2019"],
  "DNS": [
    "vpce-0abc...-x1y2z3.ssm.us-east-1.vpce.amazonaws.com",
    "ssm.us-east-1.amazonaws.com"
  ]
}
```

```bash
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_SSM"
```

Reference: [What is AWS PrivateLink?](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html)

> **Verification questions**
> **Q18.** Which two AWS services support Gateway endpoints, and what does a Gateway endpoint cost?
> **Q19.** Describe the mechanism difference: what does a Gateway endpoint modify, and what does an Interface endpoint create?
> **Q20.** A private-subnet workload calls S3 100 TB/month through a NAT Gateway. Which endpoint eliminates most of that bill, and which cost line disappears?
> **Q21.** Your security team requires that traffic to AWS Systems Manager never traverse the public internet, and forbids application code changes. What do you deploy and which flag makes the "no code change" part true?

---

## Exercise 6 — Elastic Load Balancing: three load balancers, three layers

ELB distributes incoming traffic across targets in multiple AZs and is the standard front door for a highly available workload. CLF-C02 expects you to pick the right *type*.

### Steps

1. List the types your account can create:

```bash
aws elbv2 describe-account-limits \
  --query 'Limits[?contains(Name,`load-balancers`)].{Limit:Name,Max:Max}' --output table
```

```
--------------------------------------------------------------
|                   DescribeAccountLimits                    |
+------------------------------------------------+-----------+
|                     Limit                      |    Max    |
+------------------------------------------------+-----------+
|  application-load-balancers                    |  50       |
|  network-load-balancers                        |  50       |
|  gateway-load-balancers                        |  100      |
+------------------------------------------------+-----------+
```

2. Create a target group — free — and observe that the *protocol vocabulary* is what separates the types:

```bash
aws elbv2 create-target-group \
  --name clf35-tg-http --protocol HTTP --port 8080 --vpc-id "$VPC" \
  --target-type ip --health-check-protocol HTTP --health-check-path /healthz \
  --query 'TargetGroups[0].{Arn:TargetGroupArn,Proto:Protocol,HC:HealthCheckPath,Matcher:Matcher.HttpCode}'
```

```json
{
  "Arn": "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/clf35-tg-http/6d0a1b2c3d4e5f60",
  "Proto": "HTTP",
  "HC": "/healthz",
  "Matcher": { "HttpCode": "200" }
}
```

An HTTP health check that asserts a status code is only meaningful at layer 7 — this target group can only be attached to an ALB.

3. Try the same with a TCP protocol and an HTTP path, to see the layer boundary enforced:

```bash
aws elbv2 create-target-group \
  --name clf35-tg-bad --protocol TCP --port 8080 --vpc-id "$VPC" \
  --target-type ip --health-check-protocol HTTP --health-check-path /healthz \
  --matcher HttpCode=200
```

```
An error occurred (ValidationError) when calling the CreateTargetGroup operation:
Custom health check matchers are not supported for health check protocol 'HTTP' with target group protocol 'TCP'
```

4. **`💲 BILLABLE`** — Optional. Create an ALB across both public subnets and note that it is DNS-addressed, never IP-addressed:

```bash
aws elbv2 create-load-balancer --name clf35-alb --type application --scheme internet-facing \
  --subnets "$PUB_A" "$PUB_B" --security-groups "$SG_WEB" \
  --query 'LoadBalancers[0].{Dns:DNSName,Type:Type,Scheme:Scheme,Zones:AvailabilityZones[].ZoneName}'
```

```json
{
  "Dns": "clf35-alb-1234567890.us-east-1.elb.amazonaws.com",
  "Type": "application",
  "Scheme": "internet-facing",
  "Zones": ["us-east-1a", "us-east-1b"]
}
```

The ALB's IP addresses are not yours and change over time — which is exactly why you always publish the DNS name (and why an NLB is the answer when a client demands a fixed IP).

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <arn-from-above>
```

### The decision table you must be able to reproduce

| | Application LB | Network LB | Gateway LB |
|---|---|---|---|
| OSI layer | 7 (HTTP/HTTPS/gRPC) | 4 (TCP/UDP/TLS) | 3 gateway + 4 |
| Routes on | host, path, header, method, query, source IP | protocol/port, flow hash | all traffic, transparently |
| Static IP | no (DNS name only) | yes — one Elastic IP per AZ | via endpoint |
| Preserves client IP | via `X-Forwarded-For` | yes, natively | yes |
| Extreme throughput / low latency | good | best; millions of req/s | n/a |
| WebSocket / HTTP/2 | yes | pass-through | pass-through |
| Typical use | microservices, containers, path-based routing | gaming, IoT, TLS pass-through, whitelisted static IPs | inline third-party firewalls / IDS appliances (GENEVE, port 6081) |

Reference: [What is Elastic Load Balancing?](https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html)

> **Verification questions**
> **Q22.** A client's corporate firewall only permits outbound traffic to explicitly whitelisted IP addresses. Which load balancer do you place in front of the service, and why is an ALB unsuitable?
> **Q23.** `/api/*` must go to one fleet and `/static/*` to another, with a single hostname. Which load balancer, and at which OSI layer does that decision happen?
> **Q24.** A security team requires all VPC traffic to pass through a third-party virtual firewall appliance before reaching the workload. Which ELB type is designed for this?
> **Q25.** Why does an ELB fundamentally require targets in at least two Availability Zones to deliver on its stated value?

---

## Exercise 7 — Route 53: DNS as a routing and health control plane

Route 53 is a **global** service (no Region selector) doing three jobs: domain registration, authoritative DNS, and health checking. Its routing policies are what turn DNS into an availability tool.

### Steps

1. Confirm the global nature of the API — the endpoint is not regional:

```bash
aws route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Id:Id,Private:Config.PrivateZone,Records:ResourceRecordSetCount}' --output table
```

```
------------------------------------------------------------------
|                       ListHostedZones                          |
+------------------+------------------------+---------+----------+
|        Id        |         Name           | Private | Records  |
+------------------+------------------------+---------+----------+
+------------------+------------------------+---------+----------+
```

2. Observe real Route 53 behaviour without paying for a zone. Query the NS delegation for an AWS-hosted domain and look at the answer:

```bash
dig +short NS amazon.com
```

```
ns1.p31.dynect.net.
pdns6.ultradns.co.uk.
...
```

Now query a name you know is served by AWS infrastructure and inspect the record type:

```bash
dig +noall +answer d1.awsstatic.com
```

```
d1.awsstatic.com.	60	IN	CNAME	d1.awsstatic.com.cdn.cloudfront.net.
d1.awsstatic.com.cdn.cloudfront.net. 60 IN A	18.160.10.44
d1.awsstatic.com.cdn.cloudfront.net. 60 IN A	18.160.10.72
```

Multiple A records with a short TTL: DNS-level distribution across edge locations.

3. **`💲 BILLABLE ($0.50/month)`** — Optional. Create a private hosted zone and a record, to see the API shape:

```bash
aws route53 create-hosted-zone --name internal.clf35.lab \
  --caller-reference "clf35-$(date +%s)" \
  --vpc VPCRegion=${AWS_REGION},VPCId=$VPC \
  --hosted-zone-config Comment="lab",PrivateZone=true \
  --query '{Id:HostedZone.Id,Name:HostedZone.Name}'
```

```json
{ "Id": "/hostedzone/Z0123456789ABCDEFGHIJ", "Name": "internal.clf35.lab." }
```

```bash
aws route53 delete-hosted-zone --id Z0123456789ABCDEFGHIJ
```

4. Learn the routing policy set — the exam tests the mapping from business requirement to policy:

| Policy | Selects a record by | Canonical use |
|---|---|---|
| Simple | one record, no logic | single endpoint |
| Weighted | assigned weights | blue/green, canary, A/B split |
| Latency-based | lowest measured latency to the Region | global apps optimising speed |
| Failover | health check on the primary | active/passive DR |
| Geolocation | user's country/continent | content localisation, licensing, compliance |
| Geoproximity | distance ± a bias you set | shifting traffic between Regions gradually |
| Multivalue answer | up to 8 healthy records, returned at random | cheap health-aware distribution, not a load balancer |
| IP-based | client CIDR | ISP-aware routing |

Reference: [Choosing a routing policy](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html)

5. Understand the **alias record**, which is Route 53-specific and appears constantly in exam answers:

An alias is an A/AAAA record that points at an AWS resource (ELB, CloudFront distribution, S3 website endpoint, API Gateway, another Route 53 record) rather than an IP or a name. Two properties matter: DNS queries against alias records for AWS targets are **free**, and unlike a CNAME an alias **can exist at the zone apex** (`example.com`, not just `www.example.com`). A CNAME at the apex is illegal in DNS; this is why "point `example.com` at my load balancer" has exactly one correct answer.

> **Verification questions**
> **Q26.** You must send 5 % of production traffic to a new stack and 95 % to the old one. Which routing policy?
> **Q27.** `example.com` (the apex, no `www`) must resolve to an Application Load Balancer. Which record type do you create, and why does a CNAME fail here?
> **Q28.** A standby stack in another Region should only receive traffic if the primary stops responding. Which policy, and which Route 53 feature makes "stops responding" observable?
> **Q29.** Users in Germany must be served from `eu-central-1` for data-residency reasons — not because it's faster. Geolocation or latency-based routing? Justify.

---

## Exercise 8 — The global edge: CloudFront and Global Accelerator

Both put AWS's edge network in front of your workload. They solve different problems, and the exam pairs them precisely to see whether you know which.

### Steps

1. Fetch the exam guide itself and read the response headers — it is served through CloudFront:

```bash
curl -sSI https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf \
  | grep -Ei '^(HTTP|x-cache|via|x-amz-cf-pop|age|content-type)'
```

```
HTTP/2 200
content-type: application/pdf
via: 1.1 8a2c9f01b3d4e5f60718293a4b5c6d7e.cloudfront.net (CloudFront)
x-cache: Hit from cloudfront
x-amz-cf-pop: EZE50-C1
age: 8123
```

`x-cache: Hit from cloudfront` means the object was served from the **edge location** without touching the origin. `x-amz-cf-pop` names that point of presence — yours will differ by geography. Run it twice; watch `age` grow and `x-cache` stay a hit.

2. Contrast with an origin-only request to see what caching buys:

```bash
curl -sS -o /dev/null -w 'dns=%{time_namelookup}s connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
  https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
```

```
dns=0.021s connect=0.038s ttfb=0.061s total=0.312s
```

3. Inspect the Global Accelerator control plane. Note the hard-coded Region — a strong hint about how the service is architected:

```bash
aws globalaccelerator list-accelerators --region us-west-2 \
  --query 'Accelerators[].{Name:Name,Ips:IpSets[0].IpAddresses,Dns:DnsName,Status:Status}'
```

```json
[]
```

The Global Accelerator API is only available in `us-west-2`, because the resource is global, not regional — the same pattern as Route 53, CloudFront, IAM and WAF (global scope).

4. Learn the distinction:

| | Amazon CloudFront | AWS Global Accelerator |
|---|---|---|
| Primary job | **cache** and deliver content at the edge | **route** TCP/UDP over the AWS backbone to the optimal endpoint |
| Protocols | HTTP/HTTPS (+ WebSocket) | TCP and UDP, any application protocol |
| Caches content | yes | no |
| Client-facing address | distribution DNS name (`d111.cloudfront.net`) | **two static anycast IPs** |
| Failover speed | DNS/origin-group based | sub-minute, no DNS dependency |
| Typical fit | static assets, video, whole-site acceleration, DDoS-fronted web | gaming, VoIP, IoT, MQTT, non-HTTP APIs, "I need static IPs and instant regional failover" |

Both include **AWS Shield Standard** at no extra cost — this is why "protect against DDoS at no additional charge" points at the edge services.

References: [What is Amazon CloudFront?](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html), [What is AWS Global Accelerator?](https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html)

> **Verification questions**
> **Q30.** What does `x-cache: Hit from cloudfront` prove about where the response came from, and what did it save?
> **Q31.** A UDP-based multiplayer game needs the lowest possible latency and two static IPs its client hardcodes. CloudFront or Global Accelerator? Give both reasons.
> **Q32.** An edge location and a Region are both "AWS infrastructure." State what each one is for, in one sentence each.
> **Q33.** Name the DDoS protection service included at no additional charge with CloudFront and Route 53.

---

## Exercise 9 — Connecting networks: peering, Transit Gateway, VPN, Direct Connect

### Steps

1. Create a second VPC that **overlaps** the first, and try to peer them. This failure is the lesson:

```bash
export VPC2_BAD=$(aws ec2 create-vpc --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf35-overlap}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 create-vpc-peering-connection --vpc-id "$VPC" --peer-vpc-id "$VPC2_BAD"
```

```
An error occurred (InvalidVpcPeeringConnection.MalformedRequest) when calling the
CreateVpcPeeringConnection operation: VPC peering connection cannot be created
between VPCs with overlapping CIDR blocks.
```

```bash
aws ec2 delete-vpc --vpc-id "$VPC2_BAD"
```

2. Do it correctly with a non-overlapping range — peering itself is free:

```bash
export VPC2=$(aws ec2 create-vpc --cidr-block 10.43.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf35-peer}]' \
  --query 'Vpc.VpcId' --output text)

export PCX=$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC" --peer-vpc-id "$VPC2" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" \
  --query 'VpcPeeringConnection.Status'
```

```json
{ "Code": "active", "Message": "Active" }
```

3. Add the routes — peering does **not** create routes for you, in either VPC:

```bash
aws ec2 create-route --route-table-id "$RTB_PRIV" \
  --destination-cidr-block 10.43.0.0/16 --vpc-peering-connection-id "$PCX"
```

```json
{ "Return": true }
```

Peering is **non-transitive**: if A peers with B and B peers with C, A cannot reach C. With *n* VPCs, full mesh needs *n(n−1)/2* connections — 45 for 10 VPCs. That number is the entire business case for Transit Gateway.

4. Confirm the hybrid-connectivity APIs without provisioning them. Use `--dry-run` to exercise the call and permissions for free:

```bash
aws ec2 create-vpn-gateway --type ipsec.1 --dry-run
```

```
An error occurred (DryRunOperation) when calling the CreateVpnGateway operation:
Request would have succeeded, but DryRun flag is set.
```

```bash
aws ec2 create-transit-gateway --description "clf35 hub" --dry-run
```

```
An error occurred (DryRunOperation) when calling the CreateTransitGateway operation:
Request would have succeeded, but DryRun flag is set.
```

5. Check whether any Direct Connect circuit exists (there won't be — a DX connection is a physical cross-connect ordered through a partner or AWS, provisioned in weeks, not seconds):

```bash
aws directconnect describe-connections --query 'connections[].{Id:connectionId,Bw:bandwidth,Loc:location,State:connectionState}'
aws directconnect describe-locations --query 'locations[0:3].{Code:locationCode,Name:locationName}' --output table
```

```json
[]
```
```
---------------------------------------------------------------
|                     DescribeLocations                       |
+-----------+-------------------------------------------------+
|   Code    |                      Name                       |
+-----------+-------------------------------------------------+
|  EqDC2    |  Equinix DC2 - Ashburn, VA                      |
|  CS32A    |  CoreSite VA1 - Reston, VA                      |
|  TR2      |  Telx/Digital Realty ATL1 - Atlanta, GA         |
+-----------+-------------------------------------------------+
```

### The hybrid decision set

| Service | What it is | Provisioning | Bandwidth | Encryption | Chosen when |
|---|---|---|---|---|---|
| **VPC Peering** | 1:1 private link between two VPCs | minutes | VPC-native | AWS-internal | a few VPCs, no transitivity needed |
| **Transit Gateway** | regional hub-and-spoke router for VPCs, VPNs and DX | minutes | very high | AWS-internal | many VPCs / accounts; transitive routing required |
| **Site-to-Site VPN** | IPsec tunnels over the public internet (2 tunnels for redundancy) | minutes | ~1.25 Gbps per tunnel | **yes, IPsec** | fast to stand up, encrypted, cost-sensitive; DX backup |
| **Direct Connect** | dedicated private physical circuit into an AWS location | **weeks** | 1/10/100 Gbps dedicated; 50 Mbps–10 Gbps hosted | **no by default** (add VPN or MACsec) | consistent low latency, high sustained throughput, reduced data-transfer cost |
| **Client VPN** | managed OpenVPN endpoint for individual users | minutes | per-connection | yes | remote workforce reaching the VPC |

References: [VPC peering](https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html), [Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html), [Site-to-Site VPN](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html), [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html).

> **Verification questions**
> **Q34.** Two requirements land on your desk: (a) the link must be live this afternoon, (b) traffic must be encrypted in transit. VPN or Direct Connect?
> **Q35.** A finance workload needs consistent, predictable latency and moves 30 TB/day to AWS. Which connection, and what is the one drawback you must raise in the same sentence?
> **Q36.** You have 40 VPCs across 12 accounts that all need to reach each other. Why is full-mesh peering the wrong architecture, and what replaces it?
> **Q37.** Peering is `active` but instances still cannot reach the peer VPC. Name the two things peering does *not* do automatically.
> **Q38.** Why is "Direct Connect is more secure because it's encrypted" a wrong statement, and what is the correct security claim for DX?

---

## Exercise 10 — Diagnosing the network

### Steps

1. **`💲 BILLABLE (cents)`** — Enable VPC Flow Logs to CloudWatch Logs. Flow logs record **metadata about IP flows — never the packet payload**:

```bash
aws logs create-log-group --log-group-name /clf35/flowlogs

cat > /tmp/flowlogs-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "vpc-flow-logs.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

export ROLE_ARN=$(aws iam create-role --role-name clf35-flowlogs \
  --assume-role-policy-document file:///tmp/flowlogs-trust.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy --role-name clf35-flowlogs \
  --policy-arn arn:aws:iam::aws:policy/service-role/VPCFlowLogsPolicy

export FL=$(aws ec2 create-flow-logs --resource-type VPC --resource-ids "$VPC" \
  --traffic-type ALL --log-destination-type cloud-watch-logs \
  --log-group-name /clf35/flowlogs --deliver-logs-permission-arn "$ROLE_ARN" \
  --query 'FlowLogIds[0]' --output text)
echo "$FL"
```

```
fl-0a9b8c7d6e5f40312
```

2. Read the record format so you know what a flow log entry can and cannot answer:

```bash
aws ec2 describe-flow-logs --flow-log-ids "$FL" \
  --query 'FlowLogs[0].{Status:FlowLogStatus,Type:TrafficType,Dest:LogDestinationType,Format:LogFormat}'
```

```json
{
  "Status": "ACTIVE",
  "Type": "ALL",
  "Dest": "cloud-watch-logs",
  "Format": "${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end} ${action} ${log-status}"
}
```

A published flow record looks like:

```
2 111122223333 eni-0a1b2c3d 10.42.10.55 52.94.236.248 49820 443 6 12 3721 1757000000 1757000060 ACCEPT OK
2 111122223333 eni-0a1b2c3d 198.51.100.9 10.42.0.31 40122 22 6 1 40 1757000000 1757000060 REJECT OK
```

`ACCEPT` / `REJECT` is the field that tells you a security group or NACL dropped the flow. Destinations are CloudWatch Logs, Amazon S3, or Amazon Data Firehose.

3. **`💲 $0.10 per analysis`** — Optional. Reachability Analyzer answers "can A reach B?" by **statically analysing your configuration** — it sends no packets, so the target need not even be running:

```bash
aws ec2 create-network-insights-path \
  --source "$IGW" --destination "$PRIV_A" --protocol tcp --destination-port 443 \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
```

Once analysed, an unreachable result names the exact blocking component (`ANALYSIS_FINDING: SECURITY_GROUP` / `NETWORK_ACL` / `NO_ROUTE`) — far faster than reading rules by hand.

4. Sanity-check egress identity from any instance you might launch — this endpoint returns the public IP AWS sees:

```bash
curl -s https://checkip.amazonaws.com
```

```
203.0.113.42
```

From a private-subnet instance behind a NAT Gateway, this returns the **NAT Gateway's Elastic IP**, not the instance's private address. That single command distinguishes "NAT is working" from "NAT is misrouted."

References: [VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html), [Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html).

> **Verification questions**
> **Q39.** A flow log shows `REJECT` for inbound TCP 443. Which two VPC components could be responsible, and what does the flow log *not* contain that you might have hoped for?
> **Q40.** Name the three supported destinations for VPC Flow Logs.
> **Q41.** Why can Reachability Analyzer diagnose a connectivity problem for an instance that is stopped?
> **Q42.** From a private-subnet instance, `curl https://checkip.amazonaws.com` returns `54.210.11.203`. What does that tell you about the egress path?

---

## 11. Teardown

Run this in order; dependencies matter.

```bash
# Flow logs and IAM
aws ec2 delete-flow-logs --flow-log-ids "$FL"
aws logs delete-log-group --log-group-name /clf35/flowlogs
aws iam detach-role-policy --role-name clf35-flowlogs \
  --policy-arn arn:aws:iam::aws:policy/service-role/VPCFlowLogsPolicy
aws iam delete-role --role-name clf35-flowlogs

# Endpoints
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_S3"

# Peering + second VPC
aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX"
aws ec2 delete-vpc --vpc-id "$VPC2"

# NAT / EIP (if still present)
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC \
  --query 'NatGateways[?State==`available`].NatGatewayId' --output text
aws ec2 describe-addresses --query 'Addresses[?!not_null(AssociationId)].AllocationId' --output text

# Target groups
aws elbv2 describe-target-groups --names clf35-tg-http \
  --query 'TargetGroups[0].TargetGroupArn' --output text \
  | xargs -r aws elbv2 delete-target-group --target-group-arn

# Gateways, ACL, SGs, subnets, VPC
aws ec2 delete-egress-only-internet-gateway --egress-only-internet-gateway-id "$EIGW"
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
aws ec2 delete-network-acl --network-acl-id "$ACL"
aws ec2 delete-security-group --group-id "$SG_APP"
aws ec2 delete-security-group --group-id "$SG_WEB"
for S in "$PUB_A" "$PUB_B" "$PRIV_A" "$PRIV_B"; do aws ec2 delete-subnet --subnet-id "$S"; done
aws ec2 delete-route-table --route-table-id "$RTB_PUB"
aws ec2 delete-route-table --route-table-id "$RTB_PRIV"
aws ec2 delete-vpc --vpc-id "$VPC"
```

Verify nothing survives:

```bash
aws ec2 describe-vpcs --filters Name=tag:Name,Values=clf35-* --query 'Vpcs[].VpcId'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
```

```json
[]
[]
```

---

<details>
<summary><strong>Answers</strong> — click to expand</summary>

### Exercise 1 — VPC and address space

**Q1.** A subnet lives in **exactly one Availability Zone** and cannot span AZs. Since the VPC spans all AZs but each subnet does not, putting a tier in a single subnet pins that tier to a single AZ — an AZ failure takes the whole tier down. You need at least one subnet per tier *per AZ*, which is why every reference architecture shows public-a/public-b and private-a/private-b.

**Q2.** **11 usable addresses**, not 16. AWS reserves five addresses in every subnet regardless of size: the network address, the VPC router (`.1`), the Amazon DNS resolver (`.2`), one address held for future use (`.3`), and the broadcast address — broadcast is not supported in a VPC at all. `/28` is the smallest allowed subnet precisely because the reservation would otherwise consume everything.

**Q3.** Overlapping CIDR ranges make private routing impossible. You cannot VPC-peer, cannot attach both to the same Transit Gateway route table, and cannot run a Site-to-Site VPN to that data centre, because the router cannot decide whether `10.0.x.x` means "local" or "remote" — and the `local` route always wins. A VPC's primary CIDR cannot be changed after creation (you can only *add* secondary CIDRs), so the fix is rebuilding the VPC. Choose ranges from a documented, organisation-wide IPAM plan before you create anything.

**Q4.** Smallest: **`/28`** (16 addresses, 11 usable). Largest: **`/16`** (65 536 addresses). Anything outside that range is rejected with `InvalidVpc.Range`.

### Exercise 2 — IGW and route tables

**Q5.** (1) The subnet's associated route table must contain a route for `0.0.0.0/0` (or the specific destination) targeting an **attached Internet Gateway**; (2) the instance must have a **public IPv4 address** — an auto-assigned public IP or an Elastic IP. Neither alone is sufficient. There is no "public subnet" attribute; publicness is entirely a property of the route table.

**Q6.** **Yes.** Internal reachability is provided by the implicit `local` route covering the VPC CIDR (`10.42.0.0/16 → local`), which is created automatically, cannot be deleted, and cannot be overridden. It works across AZs and across subnets. Deleting the IGW route removes internet reachability only. (Security groups and NACLs still have to permit the traffic.)

**Q7.** The **main route table** applies — every subnet with no explicit association falls back to it. In this VPC the main route table has only the `local` route, so the new subnet is effectively private: no internet in or out. This is the safe default, and it is why deliberately leaving the main route table free of an IGW route is a good habit — a forgotten association fails closed rather than open.

**Q8.** An Internet Gateway is a **Region-level, horizontally scaled, redundant** VPC component with no bandwidth cap and no AZ affinity — there is nothing to make highly available. A NAT Gateway is provisioned **in a specific subnet, in a specific AZ**; if that AZ fails, private subnets routed through it lose egress. High availability therefore requires one NAT Gateway per AZ, each referenced by that AZ's own private route table.

### Exercise 3 — NAT and egress-only

**Q9.** The NAT Gateway must be created in a **public** subnet — one whose route table has a route to the IGW, because the NAT Gateway itself needs internet reachability. The route table you modify is the **private** subnet's, adding `0.0.0.0/0 → nat-...`. Putting the NAT Gateway in the private subnet is the classic broken configuration.

**Q10.** For NAT Gateway: it is **fully managed** (no patching, no OS, no instance to monitor) and it **scales automatically** up to 100 Gbps with no throughput tuning; it is also AZ-redundant within its AZ. Against it: **cost** — an hourly charge plus per-GB processing. A NAT instance can be cheaper for tiny or intermittent workloads and can do things a NAT Gateway cannot (port forwarding, acting as a bastion, custom filtering), at the price of you owning its availability, its throughput ceiling, and its patching. (A NAT instance also requires disabling source/destination checks.)

**Q11.** An **egress-only Internet Gateway**. NAT exists to multiplex many private IPv4 addresses behind one public one; IPv6 addresses in AWS are all globally routable, so there is nothing to translate. The egress-only IGW provides the missing property — *stateful outbound-only* — by allowing outbound-initiated flows and their responses while refusing inbound-initiated connections. It is free.

**Q12.** **Availability:** if the NAT Gateway's AZ fails, private subnets in the *other* AZ lose internet egress too, because their route points into the failed AZ — an AZ failure becomes a two-AZ outage. **Cost:** traffic from the `us-east-1b` private subnets crosses an AZ boundary to reach the NAT Gateway and crosses back, incurring **cross-AZ data transfer charges in both directions** on top of the NAT processing fee. The fix for both: one NAT Gateway per AZ, with per-AZ private route tables.

### Exercise 4 — Security groups vs. NACLs

**Q13.**

| | Security group | Network ACL |
|---|---|---|
| Attaches to | the **ENI / instance** (resource level) | the **subnet** (all resources in it) |
| State | **stateful** — return traffic auto-allowed | **stateless** — return traffic needs its own rule |
| Rule actions | **allow only** | **allow and deny** |
| Evaluation | **all rules**, any match allows; no order | **ordered by rule number**, first match wins, stops |
| Default on creation | **no inbound rules**, allow-all outbound → nothing gets in | **denies everything** both directions (only rule 32767) |
| Association | many SGs per ENI | exactly one NACL per subnet (a NACL may cover many subnets) |

Note the trap: the *default* NACL that ships with a VPC allows everything (rule 100 allow before 32767 deny); a *newly created custom* NACL denies everything.

**Q14.** **No outbound rule is needed.** Security groups are stateful: because the inbound flow on 443 was allowed, its response is automatically permitted out irrespective of egress rules. The default allow-all egress rule is also still in place. Adding a matching egress rule is harmless but reveals a misunderstanding.

**Q15.** A NACL is **stateless** — every direction is evaluated independently, so the response to an inbound 443 connection is a *separate, outbound* flow that must be explicitly allowed. Its destination port is the client's **ephemeral port**, not 443, so the outbound rule must allow **TCP 1024–65535**. (The precise range varies by client OS — Linux typically 32768–60999, Windows 49152–65535, NAT Gateways and ELB 1024–65535 — so 1024–65535 is the safe superset.)

**Q16.** Only the **network ACL**, because it is the only one of the two that supports **deny** rules. You add a `deny` entry for `203.0.113.9/32` with a rule number lower than any allow rule that would otherwise match. A security group cannot express this: it is allow-only, and since it allows `0.0.0.0/0` on the port, there is no way to carve out one address. (At layer 7, AWS WAF in front of an ALB or CloudFront is the other correct answer.)

**Q17.** Because the rule expresses **identity, not location**. Instances behind an Auto Scaling group get new private IPs constantly, may land in new subnets, and their subnet CIDR may later contain resources that are *not* the web tier. A group reference means "any ENI that is a member of `SG_WEB`, wherever it is" — it needs no update when the fleet scales, is self-documenting, and cannot accidentally grant access to an unrelated instance that happens to share the subnet.

### Exercise 5 — VPC endpoints and PrivateLink

**Q18.** **Amazon S3 and Amazon DynamoDB** — that is the entire list. Gateway endpoints are **free**: no hourly charge and no per-GB processing charge.

**Q19.** A **Gateway endpoint** modifies **route tables**: it adds a route whose destination is an AWS-managed **prefix list** (the service's public IP ranges) and whose target is the endpoint. Nothing is created inside your subnets. An **Interface endpoint** creates an **elastic network interface with a private IP address in each subnet you select**, and — with private DNS enabled — a Route 53 private hosted zone that overrides the service's public DNS name inside your VPC. Route tables are untouched.

**Q20.** A **Gateway endpoint for S3**. It removes the S3 traffic from the NAT Gateway path entirely, so both the **NAT Gateway per-GB data processing charge** and the associated internet data transfer disappear, and the endpoint itself is free. At 100 TB/month the NAT processing alone is roughly 100 000 GB × $0.045 ≈ $4 500/month, eliminated.

**Q21.** An **Interface VPC endpoint (AWS PrivateLink)** for `com.amazonaws.<region>.ssm` (in practice also `ssmmessages` and `ec2messages`). The flag that makes "no code change" true is **`--private-dns-enabled`**: it makes `ssm.us-east-1.amazonaws.com` resolve to the endpoint's private IP inside the VPC, so unmodified SDKs and CLIs use the private path without any endpoint override.

### Exercise 6 — Elastic Load Balancing

**Q22.** A **Network Load Balancer**. An NLB supports assigning a **static Elastic IP per Availability Zone**, giving the client a stable set of addresses to whitelist. An ALB exposes only a DNS name; its underlying IP addresses are managed by AWS and change as it scales, so whitelisting them would break without warning.

**Q23.** An **Application Load Balancer**, deciding at **layer 7 (application)**. Path-based routing requires inspecting the HTTP request line, which is only visible once the connection is terminated and parsed as HTTP. An NLB operates at layer 4 and never sees the URL path.

**Q24.** A **Gateway Load Balancer**. It provides a single entry and exit point for traffic to a fleet of third-party virtual appliances (firewalls, IDS/IPS, deep packet inspection), distributing flows to them transparently using the **GENEVE protocol on port 6081** while preserving the original packet — the appliances see the traffic unchanged.

**Q25.** Because the value ELB delivers is **availability plus scale**, and an AZ is AWS's fault-isolation boundary. Targets in a single AZ mean an AZ failure takes out every target simultaneously; the load balancer would still be healthy and would have nothing healthy to route to. Health checks let it stop sending traffic to a failed target, but only cross-AZ targets let it survive a failed *zone*.

### Exercise 7 — Route 53

**Q26.** **Weighted routing**, with weights 5 and 95. It is the standard mechanism for canary releases, blue/green cutovers and A/B tests, and the split is adjusted by editing the weights — no infrastructure change.

**Q27.** An **alias record** (type A, alias target = the ALB). A CNAME is illegal at the zone apex: DNS forbids a CNAME coexisting with the SOA and NS records that must exist at the apex. The alias record is Route 53-specific, is returned as an A record to clients, resolves to the ALB's current addresses automatically, and queries against it for AWS targets are **free**.

**Q28.** **Failover routing** (primary/secondary), and the feature that detects the outage is a **Route 53 health check**. Route 53 probes the primary endpoint from multiple global locations; when the health check fails, the primary record is withdrawn from responses and the secondary is returned. Because the secondary is only used on failure, this is the active/passive DR pattern.

**Q29.** **Geolocation routing.** The requirement is legal — *where the user is* — not performance. Latency-based routing sends a user to whichever Region measures fastest, which on any given day might be `us-east-1`, violating the residency requirement. Geolocation routes on the query's origin country/continent, which is exactly the stated condition. (Use latency-based only when the goal is "as fast as possible.")

### Exercise 8 — Edge services

**Q30.** It proves the object was served from a **CloudFront edge location (point of presence)** near the client, out of its cache, **without a request to the origin**. It saved the round-trip latency to the origin Region and the origin's compute and data-transfer-out cost for that request. `x-amz-cf-pop` names the specific edge location; `age` is how long the object has been cached there.

**Q31.** **AWS Global Accelerator.** Two reasons: (1) CloudFront handles **HTTP/HTTPS**, while the game speaks **UDP** — Global Accelerator supports arbitrary TCP and UDP; (2) Global Accelerator provides **two static anycast IP addresses** that clients can hardcode, whereas CloudFront gives only a DNS name. It also routes over the AWS backbone from the nearest edge and fails over between Regions in seconds without waiting for DNS TTLs.

**Q32.** An **edge location** is a global point of presence that terminates user connections close to the user and caches or accelerates content (CloudFront, Global Accelerator, Route 53, Shield/WAF). A **Region** is a physical cluster of Availability Zones where your workloads, data and most AWS services actually run. Edge = delivery and entry point; Region = where the application and data live.

**Q33.** **AWS Shield Standard**, which is automatically enabled for all AWS customers at no additional charge and defends against common network and transport layer (layer 3/4) DDoS attacks. (AWS Shield Advanced is the paid tier, adding higher-layer protection, 24×7 response team access and cost protection.)

### Exercise 9 — Connecting networks

**Q34.** **AWS Site-to-Site VPN.** It provisions in minutes over the existing internet connection, and it is **IPsec-encrypted by design** — both requirements are satisfied natively. Direct Connect satisfies neither: it takes weeks to provision (it is a physical circuit) and is **not encrypted by default**.

**Q35.** **AWS Direct Connect**, because it is a dedicated private circuit delivering **consistent, predictable latency** and high sustained throughput, with lower per-GB data transfer rates than internet egress at that volume. The drawback to raise in the same breath: **it takes weeks to months to provision** (and a single connection is a single point of failure — resilience needs a second circuit, ideally at a second location, or a Site-to-Site VPN as backup). Add encryption separately if required.

**Q36.** Peering is **non-transitive** and strictly 1:1, so full mesh needs *n(n−1)/2* connections — 780 peering connections for 40 VPCs, each needing route table entries on both sides. That is operationally unmanageable and hits limits. The replacement is **AWS Transit Gateway**: each VPC attaches once to a regional hub that performs transitive routing, reducing 780 connections to 40 attachments, with centralised route tables for segmentation. It also terminates VPN and Direct Connect attachments in the same hub.

**Q37.** Peering does **not** create route table entries — you must add a route to the peer's CIDR in *every* route table on *both* sides that needs the path. And it does **not** modify security groups or NACLs — the peer VPC's traffic must be explicitly permitted (you can reference a peer VPC's security group ID in the same Region). A third gotcha: DNS resolution of the peer's private hostnames is off until you enable it on the peering connection.

**Q38.** Direct Connect traffic is **not encrypted by default** — it is a private, dedicated Layer 2/3 circuit, but the data on it is in the clear. The correct claim is that it **does not traverse the public internet**, which gives predictable latency, consistent bandwidth and a reduced exposure surface. If encryption is required — and for regulated data it usually is — you run an **IPsec VPN over the Direct Connect public VIF**, or use **MACsec** on supported dedicated connections.

### Exercise 10 — Diagnostics

**Q39.** Either a **security group** or a **network ACL** could have dropped it (or, for NACLs specifically, a missing *outbound* rule for the return traffic, which surfaces as a REJECT on the response flow). The flow log does **not** contain packet payload or any application-layer content — it records only IP flow metadata (interface, source/destination address and port, protocol, packet and byte counts, time window, ACCEPT/REJECT). It also cannot tell you *which* of the two mechanisms rejected the flow; that is what Reachability Analyzer is for.

**Q40.** **Amazon CloudWatch Logs**, **Amazon S3**, and **Amazon Data Firehose**.

**Q41.** Because Reachability Analyzer performs **static configuration analysis**, not live probing. It reasons over the route tables, security groups, network ACLs, gateways, endpoints and peering configuration to determine whether a path *could* exist, and **sends no packets**. That means it works on stopped instances and on newly built infrastructure, and when a path is blocked it names the exact component responsible.

**Q42.** It tells you the instance's outbound internet traffic is being **source-NATed through the NAT Gateway**, whose Elastic IP is `54.210.11.203` — i.e. the private route table's `0.0.0.0/0 → nat-...` route is in effect and working, and the instance has no public IP of its own. It also confirms the NAT Gateway sits in a subnet with a working IGW route, since the request reached the internet at all.

</details>