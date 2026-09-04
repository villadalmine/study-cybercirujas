# AWS Certified Cloud Practitioner — CLF-C02
# Domain 3: Cloud Technology and Services
## Task Statement 3.1 — Define methods of deploying and operating in the AWS Cloud

**Exam weight: 4.25 %** · Version 1.0 · Advanced SRE / Platform Architect track

---

### 0. What the exam guide actually asks for

The published exam guide scopes 3.1 to three skills. Everything below is organised around them, but written at the depth a platform team needs, not at flashcard depth.

| Guide item | Practical translation |
|---|---|
| *Knowledge of different ways of provisioning and operating in the AWS Cloud* | Console vs CLI vs SDK vs IaC vs managed-abstraction (Beanstalk/Copilot); imperative vs declarative; the deployment strategy layer on top |
| *Knowledge of different ways to access AWS services* | The AWS API is the only real control plane; SigV4, the credential resolution chain, IAM Identity Center, CloudShell, Session Manager |
| *Skills in determining deployment models (cloud, hybrid, on-premises) and connectivity options (VPN, Direct Connect, public internet)* | Outposts / Local Zones / Wavelength / Snow / EKS-ECS Anywhere; internet vs Site-to-Site VPN vs Direct Connect vs PrivateLink |

---

## 1. The production problem: your control plane is an API, and every human is a client of it

Start from a failure that recurs in every organisation that adopts AWS by clicking.

A team stands up a VPC, an Application Load Balancer, an Auto Scaling group and an RDS instance through the Management Console during a two-week proof of concept. It works. Nine months later the same team is asked to bring up an identical stack in `eu-west-1` for data-residency reasons, and to produce evidence for an auditor that the two environments are equivalent.

They cannot. Not because AWS is missing a feature, but because of the shape of what they built:

* **No source of truth.** The desired state exists only as the actual state. There is nothing to diff against, so "identical" is unprovable.
* **No blast-radius boundary.** A console session with `PowerUserAccess` is a shell on the whole account. There is no review step between intention and mutation.
* **No reproducibility.** The ALB idle timeout is 47 seconds because someone changed it during an incident in March. Nobody knows that. It will not be 47 seconds in the new Region.
* **No rollback.** "Undo" is a person remembering what they clicked.
* **Undifferentiated toil.** Every environment costs the same human hours as the first.

The architectural insight the exam is testing — dressed up as a list of access methods — is this:

> **The Console, the CLI, the SDKs and CloudFormation are four clients of one thing: the AWS service API, authenticated with AWS Signature Version 4.** They differ in *who or what holds the intent*, and therefore in reviewability, reproducibility and blast radius. They do not differ in what is possible.

Everything in this task statement follows from that. Choosing an access method is choosing where your intent lives.

---

## 2. The four access planes

### 2.1 One API underneath

When you drag a slider in the Console, your browser issues a signed HTTPS request to a regional service endpoint — `https://ec2.eu-west-1.amazonaws.com` — carrying an `Authorization` header produced by SigV4. The CLI does the same. Boto3 does the same. CloudFormation does the same, on your behalf, from AWS-side infrastructure.

You can see the raw shape of it:

```
$ aws ec2 describe-vpcs --region eu-west-1 --debug 2>&1 | grep -E 'Making request|Authorization|x-amz-date' | head -4
2026-09-04 11:02:17,441 - MainThread - botocore.endpoint - DEBUG - Making request for OperationModel(name=DescribeVpcs) with params: {'url_path': '/', 'query_string': '', 'method': 'POST', ...}
2026-09-04 11:02:17,449 - MainThread - botocore.auth - DEBUG - CanonicalRequest:
POST
/
content-type;host;x-amz-date;x-amz-security-token
2026-09-04 11:02:17,451 - MainThread - botocore.auth - DEBUG - Signature:
AWS4-HMAC-SHA256 Credential=ASIAV3XKQ2H5EXAMPLE/20260904/eu-west-1/ec2/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=6f2a9c...
```

Two operational consequences follow immediately, and both show up as incidents:

1. **SigV4 signs a timestamp.** A signature is rejected if the client clock is more than ~5 minutes off. This is the single most common "the SDK is broken" ticket on long-lived VMs and inside containers on hosts with no NTP.
2. **Every call is a discrete, authorised, logged event.** CloudTrail records the identity, the source IP, the parameters and the result — for console clicks exactly as for CLI calls. There is no "console mode" that escapes the audit log. This is why "we don't know who changed it" is always a retention or query problem, never a data-availability problem.

### 2.2 Trade-off table: the four planes

| Dimension | Management Console | AWS CLI (v2) | SDK (Boto3, JS, Go, Java…) | IaC (CloudFormation / CDK / Terraform) |
|---|---|---|---|---|
| **Model** | Interactive, imperative | Scripted, imperative | Programmatic, imperative | **Declarative** (CDK: imperative *synthesis* of declarative output) |
| **Where intent lives** | In a person's head | In a shell script or runbook | In application code | **In version control** |
| **Reviewable before execution** | No | Weakly (script review) | Yes (code review) | Yes — plan / change set is reviewable **and machine-generated** |
| **Reproducible across accounts/Regions** | No | Partially (parameterised scripts) | Partially | Yes, by design |
| **Drift visible** | No | No | No | Yes (`detect-stack-drift`, `terraform plan`) |
| **Rollback** | Manual, from memory | Manual, inverse script | Manual | Automatic on failure (CFN), or by reverting the commit |
| **Blast radius** | Session-wide, whole account | Whole account, one command | Whole account | Bounded by the stack |
| **Discovery / learning value** | **Highest** — you see the shape of the service | Medium | Low | Low |
| **Break-glass suitability** | High (with MFA + CloudTrail) | High | Low | **Low — never the emergency path** |
| **Latency to first result** | Seconds | Seconds | Minutes | Minutes to hours (first authoring) |
| **Right for** | Exploration, one-off reads, incident forensics, service enablement | Automation glue, CI steps, bulk operations, diagnostics | Applications that call AWS as a dependency | **Everything that must exist tomorrow the same as today** |

**The production rule that this table implies:** the Console and the CLI are for *reading* and for *exceptions*; IaC is for *state*. A platform team that inverts this ends up with the nine-month problem in §1.

### 2.3 Credentials: the resolution chain, and why it bites

The CLI and every SDK resolve credentials through an ordered chain. Knowing the order is the difference between a 30-second diagnosis and an afternoon.

| Order | Source | Typical use |
|---|---|---|
| 1 | Explicit command-line options / constructor parameters | Tests, one-offs |
| 2 | Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) | CI runners |
| 3 | Assume-role / web-identity in `~/.aws/config` (`role_arn`, `source_profile`, `web_identity_token_file`) | Cross-account, IRSA on EKS |
| 4 | IAM Identity Center (`sso_session`) cached SSO token | **Human access — the correct default** |
| 5 | Shared credentials file `~/.aws/credentials` | Legacy long-lived keys |
| 6 | Container credential provider (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`) | ECS task roles |
| 7 | Instance Metadata Service (IMDSv2) | EC2 instance profiles |

```
$ cat ~/.aws/config
[sso-session corp]
sso_start_url = https://d-936711abcd.awsapps.com/start
sso_region = eu-west-1
sso_registration_scopes = sso:account:access

[profile platform-prod]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = PlatformEngineer
region = eu-west-1
output = json

$ aws sso login --sso-session corp
Attempting to automatically open the SSO authorization page in your default browser.
If the browser does not open or you wish to use a different device to authorize this request, open the following URL:

https://device.sso.eu-west-1.amazonaws.com/

Then enter the code:

QRTL-XKVN
Successfully logged into Start URL: https://d-936711abcd.awsapps.com/start

$ aws sts get-caller-identity --profile platform-prod
{
    "UserId": "AROAV3XKQ2H5JQZ4EXAMPLE:platform-eng",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PlatformEngineer_9c1f/platform-eng"
}
```

Note what that ARN proves: the human is holding **temporary credentials from an assumed role**, not an access key. There is no long-lived secret on the laptop to leak. This is the target state; IAM users with static access keys are the thing you are migrating away from.

On EC2, the equivalent is the instance profile, retrieved through IMDSv2 (token-first, which is what defeats the SSRF class of attack that plagued IMDSv1):

```
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/
plat-baseline-InstanceRole-1TFQ8K2M9XZ4A
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/plat-baseline-InstanceRole-1TFQ8K2M9XZ4A
{
  "Code" : "Success",
  "LastUpdated" : "2026-09-04T10:44:31Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAV3XKQ2H5RJQ7EXAMPLE",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEJr//////////wEaCWV1LXdlc3QtMSJHMEUCIQ...",
  "Expiration" : "2026-09-04T16:59:12Z"
}
```

**Exam-relevant framing:** *AWS CloudShell* is the fifth access path — a browser-based shell, pre-authenticated with your console session's identity, with the CLI, Python and Node preinstalled and ~1 GB of persistent `$HOME` storage per Region. It is free, and it is the correct answer to "run a CLI command without installing anything or minting a key."

---

## 3. Deployment models: cloud, hybrid, on-premises

### 3.1 The definitions the exam wants

| Model | Definition | AWS realisation |
|---|---|---|
| **Cloud / cloud-native** | All parts of the application are deployed in the cloud; the application was built for, or migrated to, cloud services | Everything in Regions and AZs |
| **Hybrid** | Cloud resources are connected to on-premises infrastructure; workload spans both | Direct Connect / VPN + Outposts, Storage Gateway, ECS/EKS Anywhere, DataSync |
| **On-premises / private cloud** | Resources deployed in your own data centre using virtualisation and resource-management tools; "on-premises" in AWS marketing usually means *AWS infrastructure in your data centre* | **AWS Outposts**, Snow Family, ECS Anywhere, EKS Anywhere |

### 3.2 The edge and hybrid portfolio, with the decision criteria that actually differentiate them

| Service | What it is | Latency / locality property | Control plane | Choose it when |
|---|---|---|---|---|
| **AWS Region + AZs** | The default | ≥ tens of ms from most metros | In Region | Default for everything |
| **AWS Local Zones** | Region extension in a metro | Single-digit ms to that metro | Parent Region | Media rendering, real-time gaming, EDA — latency-bound, no data-residency demand |
| **AWS Wavelength** | Compute inside a telco 5G network | Lowest latency to mobile devices | Parent Region | Mobile edge inference, AR/VR, connected vehicles |
| **AWS Outposts (rack, 42U)** | AWS-managed racks **in your data centre** | Zero WAN hop; data physically stays put | **In the parent Region**, over the *service link* | Data residency law, sub-ms to on-prem systems, licence-bound legacy neighbours |
| **AWS Outposts (servers, 1U/2U)** | Same idea, small form factor | As above | Parent Region | Retail store / branch / factory floor |
| **AWS Snowball Edge** | Ruggedised device for bulk transfer + edge compute | Offline | Ordered from Region | Petabyte migration where the WAN would take months; disconnected/tactical edge |
| **AWS Storage Gateway** | On-prem appliance presenting cloud storage as NFS/SMB/iSCSI/VTL | Cache-local reads | In Region | Backup target, file share with cloud tier, tape replacement |
| **ECS Anywhere / EKS Anywhere** | AWS container orchestration on your own hardware | Your hardware | ECS Anywhere: in Region. **EKS Anywhere: local, works disconnected** | Standardise container ops across cloud and floor |
| **VMware Cloud on AWS** | VMware SDDC on EC2 bare metal | In Region | VMware + AWS | Lift-and-shift of a vSphere estate without re-platforming *(commercial ownership moved to Broadcom in 2024 — verify current availability before designing around it)* |

**The Outposts fact that gets tested and misunderstood:** an Outpost is *not* a disconnected private cloud. It requires a reliable, encrypted network path — the **service link** — back to its parent Region, because its control plane lives there. Lose the link and existing EC2 instances on the rack keep running, but you cannot launch, terminate or modify. If you need a control plane that survives a severed WAN, that is **Snowball Edge** or **EKS Anywhere**, not Outposts.

The corollary matters for capacity planning: an Outpost's capacity is fixed at the size of the rack you ordered. Elasticity — the whole reason you came to the cloud — stops at your loading dock. Design Outposts workloads with an explicit overflow path into the parent Region.

---

## 4. Provisioning models: the abstraction ladder

There are five rungs. Every AWS deployment tool sits on one of them, and the exam distinguishes them by *how much you describe*.

| Rung | Model | AWS services | You describe | AWS decides |
|---|---|---|---|---|
| 0 | **Manual** | Management Console | Every click | Nothing |
| 1 | **Scripted / imperative** | AWS CLI, SDKs | Every API call, in order | Nothing |
| 2 | **Declarative IaC** | **CloudFormation**, Terraform | The desired end state, resource by resource | The order, the dependency graph, the rollback |
| 3 | **IaC with a programming language** | **AWS CDK**, AWS SAM | Constructs and intent; it *synthesises* CloudFormation | All of rung 2, plus sane defaults for the resources you did not mention |
| 4 | **Managed abstraction (PaaS)** | **Elastic Beanstalk**, AWS App Runner, AWS Copilot, AWS Amplify | "Here is my code" | The VPC, load balancer, Auto Scaling group, health checks, deployment strategy |

The ladder is not a maturity model — it is a control/effort trade. Rung 4 is right for a stateless web app owned by a two-person team; it is wrong for a regulated multi-account landing zone. Real platforms use several rungs at once: CloudFormation/CDK for the network and security substrate, Beanstalk or App Runner for the product teams' services on top.

### 4.1 The complete reference stack (CloudFormation, rung 2)

This is a full, deployable, syntactically valid template: VPC across two AZs, public and private subnets, IGW, NAT, an internet-facing ALB, a launch template with IMDSv2 enforced, an Auto Scaling group with target-tracking, and an instance role that enables Session Manager instead of SSH.

`infra/platform-baseline.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  CLF-C02 3.1 reference stack. Two-AZ VPC, ALB, Auto Scaling group on Amazon
  Linux 2023, IMDSv2 enforced, no inbound SSH (Session Manager only).
  Declarative provisioning: this file is the source of truth for the stack.

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label:
          default: Environment
        Parameters:
          - EnvironmentName
          - VpcCidr
      - Label:
          default: Compute
        Parameters:
          - InstanceType
          - MinSize
          - MaxSize
          - LatestAmiId

Parameters:
  EnvironmentName:
    Type: String
    Description: Logical environment; drives naming, sizing and retention.
    AllowedValues: [dev, stage, prod]
    Default: dev

  VpcCidr:
    Type: String
    Description: IPv4 CIDR for the VPC. Must not overlap the on-premises range.
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
    ConstraintDescription: Must be a valid IPv4 CIDR block, e.g. 10.42.0.0/16.

  InstanceType:
    Type: String
    Default: t3.small
    AllowedValues: [t3.micro, t3.small, t3.medium, m6i.large]

  MinSize:
    Type: Number
    Default: 2
    MinValue: 1
    MaxValue: 20

  MaxSize:
    Type: Number
    Default: 6
    MinValue: 1
    MaxValue: 40

  LatestAmiId:
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Description: >-
      Resolved at deploy time from the AWS-managed SSM Parameter Store public
      parameter. Never hard-code an AMI ID: it is Region-specific and it rots.
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64

Conditions:
  IsProd: !Equals [!Ref EnvironmentName, 'prod']

Mappings:
  SubnetLayout:
    PublicOne:
      CIDR: 10.42.0.0/20
    PublicTwo:
      CIDR: 10.42.16.0/20
    PrivateOne:
      CIDR: 10.42.32.0/20
    PrivateTwo:
      CIDR: 10.42.48.0/20

Resources:

  # ---------------------------------------------------------------- network
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-vpc'
        - Key: Environment
          Value: !Ref EnvironmentName

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-igw'

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  PublicSubnetOne:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !FindInMap [SubnetLayout, PublicOne, CIDR]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-public-a'

  PublicSubnetTwo:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !FindInMap [SubnetLayout, PublicTwo, CIDR]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-public-b'

  PrivateSubnetOne:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !FindInMap [SubnetLayout, PrivateOne, CIDR]
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-private-a'

  PrivateSubnetTwo:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !FindInMap [SubnetLayout, PrivateTwo, CIDR]
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-private-b'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-rtb-public'

  DefaultPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: InternetGatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetOneRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetOne
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetTwoRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetTwo
      RouteTableId: !Ref PublicRouteTable

  NatEip:
    Type: AWS::EC2::EIP
    DependsOn: InternetGatewayAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-nat-eip'

  NatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEip.AllocationId
      SubnetId: !Ref PublicSubnetOne
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-natgw'

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-rtb-private'

  DefaultPrivateRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway

  PrivateSubnetOneRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetOne
      RouteTableId: !Ref PrivateRouteTable

  PrivateSubnetTwoRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetTwo
      RouteTableId: !Ref PrivateRouteTable

  # -------------------------------------------------------- security groups
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Public ingress to the Application Load Balancer.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
          Description: HTTP from the internet (redirected to HTTPS at the edge).
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
          Description: Unrestricted egress; narrowed by the target SG below.
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-sg-alb'

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: >-
        Application instances. No inbound SSH: administrative access is via
        AWS Systems Manager Session Manager, which is outbound-only.
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: HTTPS egress for SSM, yum and the AWS APIs.
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-sg-app'

  AppIngressFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Application port, reachable only from the ALB.

  # ---------------------------------------------------------------- iam
  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-instance-role'

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  # ---------------------------------------------------------- load balancer
  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${AWS::StackName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      Subnets:
        - !Ref PublicSubnetOne
        - !Ref PublicSubnetTwo
      SecurityGroups:
        - !Ref AlbSecurityGroup
      LoadBalancerAttributes:
        - Key: idle_timeout.timeout_seconds
          Value: '60'
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: deletion_protection.enabled
          Value: !If [IsProd, 'true', 'false']

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${AWS::StackName}-tg'
      VpcId: !Ref Vpc
      Port: 8080
      Protocol: HTTP
      TargetType: instance
      HealthCheckEnabled: true
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        - Key: stickiness.enabled
          Value: 'false'

  HttpListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # --------------------------------------------------------------- compute
  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestAmiId
        InstanceType: !Ref InstanceType
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref AppSecurityGroup
        MetadataOptions:
          HttpTokens: required          # IMDSv2 only
          HttpPutResponseHopLimit: 1
          HttpEndpoint: enabled
        Monitoring:
          Enabled: true
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 20
              VolumeType: gp3
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${AWS::StackName}-app'
              - Key: Environment
                Value: !Ref EnvironmentName
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail
            dnf -y update
            dnf -y install python3 amazon-cloudwatch-agent
            cat >/opt/healthz.py <<'PY'
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class H(BaseHTTPRequestHandler):
                def do_GET(self):
                    body = b'ok\n' if self.path == '/healthz' else b'hello\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                def log_message(self, *a):
                    pass
            HTTPServer(('0.0.0.0', 8080), H).serve_forever()
            PY
            cat >/etc/systemd/system/healthz.service <<'UNIT'
            [Unit]
            Description=Reference app
            After=network-online.target
            [Service]
            ExecStart=/usr/bin/python3 /opt/healthz.py
            Restart=always
            [Install]
            WantedBy=multi-user.target
            UNIT
            systemctl daemon-reload
            systemctl enable --now healthz.service
            /opt/aws/bin/cfn-signal --exit-code $? \
              --stack ${AWS::StackName} \
              --resource AutoScalingGroup \
              --region ${AWS::Region}

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    CreationPolicy:
      ResourceSignal:
        Count: !Ref MinSize
        Timeout: PT10M
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref MinSize
        MaxBatchSize: 1
        PauseTime: PT5M
        WaitOnResourceSignals: true
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions
    Properties:
      AutoScalingGroupName: !Sub '${AWS::StackName}-asg'
      MinSize: !Ref MinSize
      MaxSize: !Ref MaxSize
      DesiredCapacity: !Ref MinSize
      VPCZoneIdentifier:
        - !Ref PrivateSubnetOne
        - !Ref PrivateSubnetTwo
      LaunchTemplate:
        LaunchTemplateId: !Ref LaunchTemplate
        Version: !GetAtt LaunchTemplate.LatestVersionNumber
      TargetGroupARNs:
        - !Ref TargetGroup
      HealthCheckType: ELB
      HealthCheckGracePeriod: 120
      MetricsCollection:
        - Granularity: 1Minute
      Tags:
        - Key: Environment
          Value: !Ref EnvironmentName
          PropagateAtLaunch: true

  ScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: 55.0
        DisableScaleIn: false
      EstimatedInstanceWarmup: 120

Outputs:
  VpcId:
    Description: VPC identifier, exported for peer stacks.
    Value: !Ref Vpc
    Export:
      Name: !Sub '${AWS::StackName}-VpcId'

  PrivateSubnetIds:
    Description: Comma-separated private subnet IDs.
    Value: !Join [',', [!Ref PrivateSubnetOne, !Ref PrivateSubnetTwo]]
    Export:
      Name: !Sub '${AWS::StackName}-PrivateSubnetIds'

  LoadBalancerDnsName:
    Description: Public entry point.
    Value: !GetAtt LoadBalancer.DNSName

  ServiceUrl:
    Description: Smoke-test target.
    Value: !Sub 'http://${LoadBalancer.DNSName}/healthz'
```

Deploy it, and observe that CloudFormation — not you — computes the dependency order:

```
$ aws cloudformation validate-template --template-body file://infra/platform-baseline.yaml
{
    "Parameters": [
        {"ParameterKey": "EnvironmentName", "DefaultValue": "dev", "NoEcho": false},
        {"ParameterKey": "VpcCidr", "DefaultValue": "10.42.0.0/16", "NoEcho": false},
        {"ParameterKey": "InstanceType", "DefaultValue": "t3.small", "NoEcho": false},
        {"ParameterKey": "MinSize", "DefaultValue": "2", "NoEcho": false},
        {"ParameterKey": "MaxSize", "DefaultValue": "6", "NoEcho": false},
        {"ParameterKey": "LatestAmiId", "DefaultValue": "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64", "NoEcho": false}
    ],
    "Description": "CLF-C02 3.1 reference stack. Two-AZ VPC, ALB, Auto Scaling group on Amazon Linux 2023, IMDSv2 enforced, no inbound SSH (Session Manager only).",
    "Capabilities": ["CAPABILITY_IAM"],
    "CapabilitiesReason": "The following resource(s) require capabilities: [AWS::IAM::Role]"
}

$ aws cloudformation deploy \
    --template-file infra/platform-baseline.yaml \
    --stack-name plat-dev \
    --parameter-overrides EnvironmentName=dev MinSize=2 MaxSize=6 \
    --capabilities CAPABILITY_IAM \
    --tags CostCenter=platform Owner=sre \
    --region eu-west-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - plat-dev

$ aws cloudformation describe-stacks --stack-name plat-dev \
    --query 'Stacks[0].Outputs' --output table
--------------------------------------------------------------------------------------
|                                   DescribeStacks                                   |
+--------------------+--------------------------------------------------------------+
|      OutputKey     |                         OutputValue                          |
+--------------------+--------------------------------------------------------------+
|  LoadBalancerDnsName|  plat-dev-alb-1043927611.eu-west-1.elb.amazonaws.com        |
|  PrivateSubnetIds  |  subnet-0a91f3c7d2b48e015,subnet-06c2e8ba71d94f3aa           |
|  ServiceUrl        |  http://plat-dev-alb-1043927611.eu-west-1.elb.amazonaws.com/healthz |
|  VpcId             |  vpc-0f4d9a1b7c3e82a6d                                       |
+--------------------+--------------------------------------------------------------+

$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
    http://plat-dev-alb-1043927611.eu-west-1.elb.amazonaws.com/healthz
200 0.041s
```

### 4.2 Change sets: the review step the Console does not give you

Never `deploy` blind against production. A change set is the plan:

```
$ aws cloudformation create-change-set \
    --stack-name plat-prod \
    --change-set-name bump-instance-type \
    --template-body file://infra/platform-baseline.yaml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=prod \
                 ParameterKey=InstanceType,ParameterValue=m6i.large \
                 ParameterKey=MinSize,ParameterValue=4 \
                 ParameterKey=MaxSize,ParameterValue=20 \
    --capabilities CAPABILITY_IAM
{
    "Id": "arn:aws:cloudformation:eu-west-1:123456789012:changeSet/bump-instance-type/8f31c0d2-1a44-4e7b-9c88-2b0f6e5d1a93",
    "StackId": "arn:aws:cloudformation:eu-west-1:123456789012:stack/plat-prod/1a9b7e40-8c33-11f0-b2ad-0efc1a7c9d11"
}

$ aws cloudformation describe-change-set \
    --stack-name plat-prod --change-set-name bump-instance-type \
    --query 'Changes[].ResourceChange.{Action:Action,Type:ResourceType,LogicalId:LogicalResourceId,Replacement:Replacement}' \
    --output table
------------------------------------------------------------------------------------
|                                DescribeChangeSet                                 |
+----------+---------------------+-----------------------------+-------------------+
|  Action  |      LogicalId      |            Type             |   Replacement     |
+----------+---------------------+-----------------------------+-------------------+
|  Modify  |  LaunchTemplate     |  AWS::EC2::LaunchTemplate   |  False            |
|  Modify  |  AutoScalingGroup   |  AWS::AutoScaling::AutoScalingGroup |  False    |
+----------+---------------------+-----------------------------+-------------------+
```

`Replacement: True` on a stateful resource — an RDS instance, an EBS volume — is the signal to stop and read. That column is why change sets exist.

### 4.3 Rung 3: the same stack in CDK

CDK is a *synthesiser*: it emits CloudFormation. The value is that the defaults are opinionated and correct, and the loops are real loops.

```python
# app.py — AWS CDK v2 (Python)
import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_elasticloadbalancingv2 as elbv2,
    aws_autoscaling as autoscaling,
)
from constructs import Construct


class PlatformBaseline(cdk.Stack):
    def __init__(self, scope: Construct, cid: str, *, env_name: str, **kw) -> None:
        super().__init__(scope, cid, **kw)

        vpc = ec2.Vpc(
            self, "Vpc",
            ip_addresses=ec2.IpAddresses.cidr("10.42.0.0/16"),
            max_azs=2,
            nat_gateways=1 if env_name != "prod" else 2,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=20),
                ec2.SubnetConfiguration(
                    name="private", subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS,
                    cidr_mask=20),
            ],
        )

        asg = autoscaling.AutoScalingGroup(
            self, "Asg",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS),
            instance_type=ec2.InstanceType("t3.small"),
            machine_image=ec2.MachineImage.latest_amazon_linux2023(),
            min_capacity=2,
            max_capacity=6,
            require_imdsv2=True,
            ssm_session_permissions=True,
        )
        asg.scale_on_cpu_utilization("CpuTarget", target_utilization_percent=55)

        alb = elbv2.ApplicationLoadBalancer(
            self, "Alb", vpc=vpc, internet_facing=True)
        listener = alb.add_listener("Http", port=80, open=True)
        listener.add_targets(
            "App",
            port=8080,
            targets=[asg],
            health_check=elbv2.HealthCheck(path="/healthz", healthy_threshold_count=2),
        )

        cdk.CfnOutput(self, "ServiceUrl", value=f"http://{alb.load_balancer_dns_name}/healthz")


app = cdk.App()
for env_name in ("dev", "prod"):
    PlatformBaseline(app, f"plat-{env_name}", env_name=env_name)
app.synth()
```

```
$ cdk diff plat-prod
Stack plat-prod
Resources
[~] AWS::AutoScaling::AutoScalingGroup Asg AsgASG3D7A9E4B
 └─ [~] MaxSize
     ├─ [-] "6"
     └─ [+] "20"
[~] AWS::EC2::LaunchTemplate Asg/LaunchTemplate
 └─ [~] LaunchTemplateData
     └─ [~] .InstanceType:
         ├─ [-] t3.small
         └─ [+] m6i.large

✨  Number of stacks with differences: 1
```

Note the ~40 lines of CDK produce ~400 lines of CloudFormation. That leverage is the whole argument for rung 3 — and its whole risk: you must be able to read the synthesised template when it misbehaves (`cdk synth`).

### 4.4 Rung 4: Elastic Beanstalk, and why it still matters

Beanstalk is the exam's canonical PaaS. You upload code; it provisions the EC2 instances, the ALB, the Auto Scaling group, the security groups, CloudWatch alarms and a health dashboard — and you keep full access to those resources underneath. **You pay only for the underlying resources; Beanstalk itself is free.**

`.ebextensions/01-platform.config`:

```yaml
option_settings:
  aws:elasticbeanstalk:environment:
    EnvironmentType: LoadBalanced
    LoadBalancerType: application
    ServiceRole: aws-elasticbeanstalk-service-role

  aws:autoscaling:asg:
    MinSize: '2'
    MaxSize: '8'

  aws:autoscaling:launchconfiguration:
    InstanceType: t3.small
    IamInstanceProfile: aws-elasticbeanstalk-ec2-role
    DisableIMDSv1: 'true'
    RootVolumeType: gp3
    RootVolumeSize: '20'

  aws:autoscaling:trigger:
    MeasureName: CPUUtilization
    Statistic: Average
    Unit: Percent
    UpperThreshold: '65'
    LowerThreshold: '25'
    BreachDuration: '5'

  aws:elasticbeanstalk:command:
    DeploymentPolicy: Immutable
    Timeout: '900'

  aws:elasticbeanstalk:healthreporting:system:
    SystemType: enhanced

  aws:elasticbeanstalk:application:
    Application Healthcheck URL: /healthz

  aws:elasticbeanstalk:cloudwatch:logs:
    StreamLogs: true
    DeleteOnTerminate: false
    RetentionInDays: '30'

  aws:elbv2:listener:default:
    ListenerEnabled: 'true'
    Protocol: HTTP

  aws:elasticbeanstalk:managedactions:
    ManagedActionsEnabled: 'true'
    PreferredStartTime: 'Tue:03:00'

  aws:elasticbeanstalk:managedactions:platformupdate:
    UpdateLevel: minor
    InstanceRefreshEnabled: 'true'

packages:
  yum:
    amazon-cloudwatch-agent: []

container_commands:
  01_migrate:
    command: "./manage.py migrate --noinput"
    leader_only: true
```

`leader_only: true` is the detail worth internalising: it makes exactly one instance in the group run the database migration, which is the difference between a deploy and a race condition.

---

## 5. Deployment strategies — the operating half of "deploying and operating"

Provisioning gets the resources there. *Deploying* is how new code replaces old code without an outage. Beanstalk and CodeDeploy both expose the same family of strategies; the exam tests the trade-offs.

| Strategy | Capacity during deploy | Extra cost | Downtime | Rollback speed | Mixed versions live? | Blast radius |
|---|---|---|---|---|---|---|
| **All at once** | Full fleet churns | None | **Yes** | Slow — redeploy the old version | No | 100 % |
| **Rolling** | Reduced (batch is out of service) | None | No | Slow — roll forward/back batch by batch | Yes | 1 batch |
| **Rolling with additional batch** | Full, maintained | One extra batch, temporarily | No | Slow | Yes | 1 batch |
| **Immutable** | Full + a parallel new group | **~2×, briefly** | No | **Fast — terminate the new ASG** | Briefly | New instances only |
| **Traffic splitting / canary** | Full + canary fleet | Extra canary fleet | No | **Fastest — shift weight to 0 %** | Yes, by design | Configurable % |
| **Blue/green (two environments)** | Two full environments | **2×** for the overlap | No | **Fastest — swap DNS / listener back** | No | 0 % if the swap is atomic |

**The SRE reading of that table:** the correct default for a production service is *immutable* or *blue/green*. Both replace instances rather than mutating them, which means the artefact that passed testing is byte-for-byte the artefact that serves traffic. In-place mutation ("rolling") drifts: a `dnf update` that succeeded in March and fails in September gives you a fleet where half the hosts are not what you think they are.

**The blue/green caveat that costs teams an outage:** if the swap is a DNS CNAME swap (which is what Beanstalk's `swap-environment-cnames` does), clients that cache DNS beyond the TTL keep hitting the old environment. Do not terminate blue immediately. If the swap is an ALB listener rule change (CodeDeploy blue/green for EC2/ECS), it is genuinely atomic at the connection level and the DNS problem disappears.

### 5.1 CodeDeploy: `appspec.yml` for EC2/on-premises

```yaml
version: 0.0
os: linux

files:
  - source: /app
    destination: /opt/reference-app
  - source: /config/reference-app.service
    destination: /etc/systemd/system

permissions:
  - object: /opt/reference-app
    owner: appuser
    group: appuser
    mode: '750'
    type:
      - directory
      - file

hooks:
  ApplicationStop:
    - location: scripts/stop_server.sh
      timeout: 60
      runas: root
  BeforeInstall:
    - location: scripts/install_dependencies.sh
      timeout: 300
      runas: root
  AfterInstall:
    - location: scripts/set_permissions.sh
      timeout: 60
      runas: root
  ApplicationStart:
    - location: scripts/start_server.sh
      timeout: 120
      runas: root
  ValidateService:
    - location: scripts/healthcheck.sh
      timeout: 120
      runas: appuser
```

`scripts/healthcheck.sh` — the hook that makes automatic rollback possible. If it exits non-zero, CodeDeploy fails the instance, and with a rollback configuration it reverts the whole deployment group:

```bash
#!/usr/bin/env bash
set -euo pipefail
for attempt in {1..20}; do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/healthz | grep -q '^ok$'; then
    echo "healthy after ${attempt} attempt(s)"
    exit 0
  fi
  sleep 3
done
echo "service did not become healthy within 60s" >&2
exit 1
```

### 5.2 CodeDeploy for Lambda: canary as a config string

```yaml
version: 0.0
Resources:
  - PaymentsFunction:
      Type: AWS::Lambda::Function
      Properties:
        Name: payments-api
        Alias: live
        CurrentVersion: 41
        TargetVersion: 42
Hooks:
  - BeforeAllowTraffic: preflight-checks
  - AfterAllowTraffic: post-deploy-smoke
```

```
$ aws deploy create-deployment \
    --application-name payments \
    --deployment-group-name payments-prod \
    --deployment-config-name CodeDeployDefault.LambdaCanary10Percent5Minutes \
    --revision '{"revisionType":"AppSpecContent","appSpecContent":{"content":"'"$(sed 's/"/\\"/g;:a;N;$!ba;s/\n/\\n/g' appspec.yaml)"'"}}'
{
    "deploymentId": "d-9K2LQ4XZ7"
}

$ aws deploy get-deployment --deployment-id d-9K2LQ4XZ7 \
    --query 'deploymentInfo.{Status:status,Config:deploymentConfigName,Rollback:rollbackInfo}'
{
    "Status": "InProgress",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Rollback": {}
}
```

`LambdaCanary10Percent5Minutes` means: 10 % of invocations hit version 42 for five minutes, then 100 % shifts. If a CloudWatch alarm in the deployment group breaches during that window, CodeDeploy shifts the alias back to version 41 automatically. That is the entire mechanism of a safe deploy, expressed as one string.

---

## 6. Connectivity options: public internet, VPN, Direct Connect, PrivateLink

### 6.1 The comparison the exam is built around

| | **Public internet** | **AWS Site-to-Site VPN** | **AWS Client VPN** | **AWS Direct Connect (DX)** | **AWS PrivateLink / VPC endpoints** |
|---|---|---|---|---|---|
| **What connects** | Anything ↔ public AWS endpoints | Your data centre ↔ VPC/TGW | Individual user device ↔ VPC | Your data centre ↔ AWS, over private fibre | VPC ↔ an AWS service or a partner service, privately |
| **Transport** | Internet | IPsec **over the internet** | OpenVPN-based TLS over internet | **Dedicated physical circuit** via a DX location | AWS backbone, via an ENI in your subnet |
| **Encryption in transit** | TLS, application's responsibility | **IPsec, built in** | TLS, built in | **None by default** — add MACsec or IPsec over it | TLS to the service endpoint |
| **Bandwidth** | Whatever your ISP gives you | ~1.25 Gbps **per tunnel**; scale with multiple VPNs + ECMP on Transit Gateway | Per-user | Dedicated: 1 / 10 / 100 Gbps. Hosted: 50 Mbps – 25 Gbps | Bounded by the endpoint's throughput, scales automatically |
| **Latency profile** | Variable, best-effort | Variable (rides the internet) + crypto overhead | Variable | **Consistent** — the real selling point | In-Region, very low |
| **Provisioning time** | Immediate | **Minutes** | Minutes | **Weeks to months** (cross-connect, LOA-CFA, partner) |Minutes |
| **Cost shape** | Data transfer out only | Low hourly + data transfer out | Endpoint-hour + connection-hour | Port-hour + **reduced data-transfer-out rate** | Endpoint-hour per AZ + data processed (gateway endpoints for S3/DynamoDB are **free**) |
| **SLA** | None | 99.95 % (tunnel) | — | 99.9 % single connection; **99.99 % with two connections at separate locations/devices** | — |
| **Traffic leaves the internet?** | No | No (encrypted, but internet-routed) | No | **Yes** | **Yes** |
| **Choose when** | Public web, dev, low sensitivity | You need private connectivity *today*, or as DX backup | Remote workforce access to VPC resources | Sustained high volume, consistent latency, egress cost reduction, regulatory | Keep service traffic off the IGW/NAT entirely |

### 6.2 The two facts that turn into wrong answers

**Direct Connect is not encrypted.** It is private — traffic does not traverse the public internet — but "private" is not "confidential." If your compliance regime requires encryption in transit, you layer something on: MACsec (available on dedicated 10 Gbps and 100 Gbps connections) or an IPsec Site-to-Site VPN running over a public VIF. Exam questions that pair "Direct Connect" with "must be encrypted" are testing exactly this.

**A single Direct Connect connection is a single point of failure with a months-long repair time.** The standard, and the exam-correct, answer for resilience is: **Site-to-Site VPN as the backup path for Direct Connect**. It costs cents per hour, provisions in minutes, and BGP will prefer the DX route while it is up and fail over to the VPN when it is not. The higher-cost alternative is a second DX connection at a different DX location.

### 6.3 The three Direct Connect virtual interfaces

| VIF type | Terminates on | Reaches | Use |
|---|---|---|---|
| **Private VIF** | Virtual Private Gateway, or a Direct Connect Gateway | **Private IPs in your VPC** | The normal case: on-prem servers talking to EC2/RDS |
| **Public VIF** | AWS public endpoints | **Public AWS services** (S3, DynamoDB, public API endpoints) over the DX circuit, using public IPs; AWS advertises all its public prefixes over BGP | Bulk S3 ingest without going over the internet; carrying an IPsec VPN |
| **Transit VIF** | Direct Connect Gateway → **AWS Transit Gateway** | Many VPCs, many Regions, through one hub | Multi-VPC / multi-account landing zones |

### 6.4 Provisioning connectivity from the CLI

```
$ aws ec2 create-customer-gateway \
    --type ipsec.1 \
    --public-ip 203.0.113.44 \
    --bgp-asn 65010 \
    --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=dc-madrid}]'
{
    "CustomerGateway": {
        "BgpAsn": "65010",
        "CustomerGatewayId": "cgw-0be7d1c4a92f5e380",
        "IpAddress": "203.0.113.44",
        "State": "available",
        "Type": "ipsec.1"
    }
}

$ aws ec2 create-vpn-connection \
    --type ipsec.1 \
    --customer-gateway-id cgw-0be7d1c4a92f5e380 \
    --transit-gateway-id tgw-0d4a19f6b2c73e850 \
    --options '{"StaticRoutesOnly":false,"EnableAcceleration":false,"TunnelOptions":[{"TunnelInsideCidr":"169.254.10.0/30"},{"TunnelInsideCidr":"169.254.11.0/30"}]}' \
    --query 'VpnConnection.{Id:VpnConnectionId,State:State}'
{
    "Id": "vpn-0c8f2a5b91d47e6a3",
    "State": "pending"
}

$ aws ec2 describe-vpn-connections --vpn-connection-ids vpn-0c8f2a5b91d47e6a3 \
    --query 'VpnConnections[0].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount,Msg:StatusMessage}' \
    --output table
------------------------------------------------------------------------------
|                          DescribeVpnConnections                            |
+------------------+--------+-----------------------------------+-----------+
|     Outside      | Routes |               Msg                 |  Status   |
+------------------+--------+-----------------------------------+-----------+
|  52.16.203.77    |  0     |  IPSEC IS DOWN                    |  DOWN     |
|  34.243.11.204   |  0     |  IPSEC IS DOWN                    |  DOWN     |
+------------------+--------+-----------------------------------+-----------+
```

Both tunnels DOWN immediately after creation is normal — the customer side has not been configured. Download the vendor-specific configuration and hand it to the network team:

```
$ aws ec2 get-vpn-connection-device-types \
    --query 'VpnConnectionDeviceTypes[?Vendor==`Juniper`].[VpnConnectionDeviceTypeId,Platform,Software]' \
    --output text
0e08bd7d	SRX Series Services Gateways	JunOS 12.1+
5fb8ab34	J-Series Services Router	JunOS 9.5+

$ aws ec2 get-vpn-connection-device-sample-configuration \
    --vpn-connection-id vpn-0c8f2a5b91d47e6a3 \
    --vpn-connection-device-type-id 0e08bd7d \
    --internet-key-exchange-version ikev2 \
    --output text > /tmp/vpn-juniper.conf
$ wc -l /tmp/vpn-juniper.conf
412 /tmp/vpn-juniper.conf
```

After the peer is configured:

```
$ aws ec2 describe-vpn-connections --vpn-connection-ids vpn-0c8f2a5b91d47e6a3 \
    --query 'VpnConnections[0].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount}' \
    --output table
------------------------------------------------
|             DescribeVpnConnections           |
+------------------+--------+------------------+
|     Outside      | Routes |     Status       |
+------------------+--------+------------------+
|  52.16.203.77    |  7     |  UP              |
|  34.243.11.204   |  7     |  UP              |
+------------------+--------+------------------+
```

Direct Connect, inspected:

```
$ aws directconnect describe-connections --output table \
    --query 'connections[].{Id:connectionId,Name:connectionName,Bw:bandwidth,State:connectionState,Loc:location,Macsec:macSecCapable}'
------------------------------------------------------------------------------------------
|                                  DescribeConnections                                   |
+---------------+-------------------+--------+------------+-----------------+-----------+
|      Bw       |        Id         | Macsec |   Name     |      Loc        |   State   |
+---------------+-------------------+--------+------------+-----------------+-----------+
|  10Gbps       |  dxcon-fh4k92lz   |  True  |  mad-dx-1  |  EqDC2          |  available|
|  10Gbps       |  dxcon-fg7p31qa   |  True  |  mad-dx-2  |  Interxion-MAD1 |  available|
+---------------+-------------------+--------+------------+-----------------+-----------+

$ aws directconnect describe-virtual-interfaces \
    --query 'virtualInterfaces[].{Name:virtualInterfaceName,Type:virtualInterfaceType,Vlan:vlan,State:virtualInterfaceState,BGP:bgpPeers[0].bgpPeerState,Status:bgpPeers[0].bgpStatus}' \
    --output table
-------------------------------------------------------------------------------------
|                          DescribeVirtualInterfaces                                |
+-----------+-----------------+---------+-------------+------------+---------------+
|    BGP    |      Name       | Status  |    State    |    Type    |     Vlan      |
+-----------+-----------------+---------+-------------+------------+---------------+
|  available|  prod-transit   |  up     |  available  |  transit   |  101          |
|  available|  prod-public    |  up     |  available  |  public    |  102          |
+-----------+-----------------+---------+-------------+------------+---------------+
```

Two connections, two distinct locations (`EqDC2` and `Interxion-MAD1`) — that is what buys the 99.99 % SLA. Two connections into the *same* location buys device redundancy only.

### 6.5 PrivateLink: taking the internet out of the path entirely

Gateway endpoints (S3, DynamoDB) are route-table entries and cost nothing. Interface endpoints are ENIs in your subnets, priced per AZ-hour plus data processed. Adding the SSM trio is what lets private instances be managed with **no NAT gateway at all**:

```yaml
  SsmEndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress to the Systems Manager interface endpoints.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          SourceSecurityGroupId: !Ref AppSecurityGroup
          Description: HTTPS from application instances only.

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTable

  SsmInterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssm'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnetOne, !Ref PrivateSubnetTwo]
      SecurityGroupIds: [!Ref SsmEndpointSecurityGroup]

  SsmMessagesInterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssmmessages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnetOne, !Ref PrivateSubnetTwo]
      SecurityGroupIds: [!Ref SsmEndpointSecurityGroup]

  Ec2MessagesInterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2messages'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnetOne, !Ref PrivateSubnetTwo]
      SecurityGroupIds: [!Ref SsmEndpointSecurityGroup]
```

---

## 7. Operating: administrative access without a bastion or a key pair

The modern answer to "how do I get a shell on that instance" is **AWS Systems Manager Session Manager**. It needs no inbound security group rule, no public IP, no SSH key and no bastion host, because the SSM Agent opens an *outbound* connection. Every session is authorised by IAM and logged to CloudWatch Logs or S3.

```
$ aws ssm describe-instance-information \
    --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' \
    --output table
-------------------------------------------------------------------------
|                     DescribeInstanceInformation                       |
+-----------+-----------------------+------------+----------------------+
|   Agent   |          Id           |    Ping    |      Platform        |
+-----------+-----------------------+------------+----------------------+
|  3.3.1611.0|  i-0af31c8d29e4b7f60 |  Online    |  Amazon Linux        |
|  3.3.1611.0|  i-04b9e7f13a8c26d5b |  Online    |  Amazon Linux        |
+-----------+-----------------------+------------+----------------------+

$ aws ssm start-session --target i-0af31c8d29e4b7f60

Starting session with SessionId: platform-eng-0d7a41f92bc3e5a68
sh-5.2$ systemctl is-active healthz
active
sh-5.2$ curl -s localhost:8080/healthz
ok
sh-5.2$ exit
Exiting session with sessionId: platform-eng-0d7a41f92bc3e5a68.
```

Fleet-wide operations without a shell at all — this is the pattern that scales:

```
$ aws ssm send-command \
    --document-name AWS-RunShellScript \
    --targets 'Key=tag:Environment,Values=prod' \
    --parameters 'commands=["systemctl is-active healthz","rpm -q openssl"]' \
    --comment "openssl inventory sweep" \
    --query 'Command.CommandId' --output text
b19f27c4-0a53-4d6e-9f21-7c8e4a10d3b2

$ aws ssm list-command-invocations \
    --command-id b19f27c4-0a53-4d6e-9f21-7c8e4a10d3b2 --details \
    --query 'CommandInvocations[].{Id:InstanceId,Status:Status,Out:CommandPlugins[0].Output}' \
    --output text
i-0af31c8d29e4b7f60	Success	active
openssl-3.2.2-1.amzn2023.0.1.x86_64
i-04b9e7f13a8c26d5b	Success	active
openssl-3.2.2-1.amzn2023.0.1.x86_64
```

Related Systems Manager capabilities the exam expects you to place: **Patch Manager** (scheduled OS patching with compliance reporting), **State Manager** (continuous configuration enforcement), **Parameter Store** (configuration and secrets, free standard tier), **Automation** (runbooks), **Fleet Manager** (browser-based fleet administration).

---

## 8. Verification and failure diagnosis

### 8.1 Verification ladder — run these in order after any deploy

```bash
#!/usr/bin/env bash
# verify.sh — post-deploy verification, cheapest checks first.
set -euo pipefail
STACK="${1:?usage: verify.sh <stack-name>}"
REGION="${AWS_REGION:-eu-west-1}"

echo "== 1. identity =="
aws sts get-caller-identity --output text --query 'Arn'

echo "== 2. stack status =="
aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text

echo "== 3. drift =="
DRIFT_ID=$(aws cloudformation detect-stack-drift --stack-name "$STACK" \
  --region "$REGION" --query StackDriftDetectionId --output text)
until [ "$(aws cloudformation describe-stack-drift-detection-status \
        --stack-drift-detection-id "$DRIFT_ID" --region "$REGION" \
        --query DetectionStatus --output text)" != "DETECTION_IN_PROGRESS" ]; do
  sleep 5
done
aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id "$DRIFT_ID" --region "$REGION" \
  --query '{Status:StackDriftStatus,Drifted:DriftedStackResourceCount}'

echo "== 4. target health =="
TG=$(aws elbv2 describe-target-groups --names "${STACK}-tg" --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" --region "$REGION" \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table

echo "== 5. end-to-end =="
URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" --output text)
curl -fsS -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' "$URL"
```

```
$ ./verify.sh plat-dev
== 1. identity ==
arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PlatformEngineer_9c1f/platform-eng
== 2. stack status ==
CREATE_COMPLETE
== 3. drift ==
{
    "Status": "IN_SYNC",
    "Drifted": 0
}
== 4. target health ==
---------------------------------------------------------------
|                    DescribeTargetHealth                     |
+-----------------------+----------+--------------------------+
|          Id           |  Reason  |          State           |
+-----------------------+----------+--------------------------+
|  i-0af31c8d29e4b7f60  |  None    |  healthy                 |
|  i-04b9e7f13a8c26d5b  |  None    |  healthy                 |
+-----------------------+----------+--------------------------+
== 5. end-to-end ==
HTTP 200 in 0.038s
```

Drift is the check that distinguishes a real IaC practice from a decorative one. `IN_SYNC` with `Drifted: 0` is the statement "the template is still the truth." When it is not:

```
$ aws cloudformation describe-stack-resource-drifts --stack-name plat-dev \
    --stack-resource-drift-status-filters MODIFIED \
    --query 'StackResourceDrifts[].{Id:LogicalResourceId,Prop:PropertyDifferences[0].PropertyPath,Expected:PropertyDifferences[0].ExpectedValue,Actual:PropertyDifferences[0].ActualValue}' \
    --output table
------------------------------------------------------------------------------------
|                          DescribeStackResourceDrifts                             |
+-----------+------------+-------------------------------------------+------------+
|  Actual   |  Expected  |                   Prop                    |     Id     |
+-----------+------------+-------------------------------------------+------------+
|  47       |  60        |  /LoadBalancerAttributes/0/Value          | LoadBalancer|
+-----------+------------+-------------------------------------------+------------+
```

There it is — the 47-second idle timeout from §1, found by a free API call instead of by an outage.

### 8.2 Failure catalogue

| Symptom | Most likely cause | Diagnostic | Fix |
|---|---|---|---|
| `An error occurred (RequestTimeTooSkewed)` | Client clock > ~5 min off; SigV4 signs a timestamp | `date -u`, `chronyc tracking` | Enable NTP / the Amazon Time Sync Service (`169.254.169.123`) |
| `InvalidClientTokenId` | Access key does not exist, or wrong partition (`aws-cn`, `aws-us-gov`) | `aws sts get-caller-identity` | Fix profile / key |
| `ExpiredToken` / `The security token included in the request is expired` | SSO or STS session lapsed | `aws sts get-caller-identity` | `aws sso login --sso-session corp` |
| `AccessDenied` on a *stack* operation but not on the API directly | The **stack role** (`--role-arn`), not your identity, is what CloudFormation uses | Read the `StackEvents` `ResourceStatusReason` | Grant the service role, or drop `--role-arn` |
| `Requires capabilities: [CAPABILITY_IAM]` | Template creates IAM resources | — | Add `--capabilities CAPABILITY_IAM` (or `CAPABILITY_NAMED_IAM` for named roles) |
| Stack stuck in `ROLLBACK_COMPLETE`, updates rejected | A *create* failed; this state permits only delete | `describe-stack-events` for the first `CREATE_FAILED` | Delete and recreate. To debug next time: `--disable-rollback` or `--on-failure DO_NOTHING` |
| `CREATE_FAILED … WaitCondition timed out. Received 0 conditions when expecting 2` | `cfn-signal` never ran — UserData crashed | `aws ssm start-session` → `sudo cat /var/log/cloud-init-output.log` | Fix UserData; add `set -x`; check egress for package installs |
| Targets `unhealthy`, `Health checks failed with these codes: [404]` | Health-check path wrong, or app on a different port | `describe-target-health`; curl from the instance | Align `HealthCheckPath` / `Port` |
| Targets `unused`, `Target is in an Availability Zone that is not enabled for the load balancer` | ASG subnets in an AZ the ALB does not cover | Compare ASG `VPCZoneIdentifier` with ALB `Subnets` | Add the AZ to the ALB |
| Instance not in `describe-instance-information` (Session Manager fails) | Missing `AmazonSSMManagedInstanceCore`, no 443 egress, or no SSM interface endpoints in a private subnet | `sudo systemctl status amazon-ssm-agent`; `sudo cat /var/log/amazon/ssm/amazon-ssm-agent.log` | Attach the managed policy; add the `ssm`, `ssmmessages`, `ec2messages` endpoints |
| VPN tunnel `DOWN`, `IPSEC IS DOWN`, Phase 1 never completes | IKE version / DH group / PSK mismatch; UDP 500 & 4500 blocked at the customer firewall | `describe-vpn-connections … VgwTelemetry`; peer logs | Re-apply the generated device config verbatim |
| VPN tunnel `UP` but `AcceptedRouteCount: 0` | BGP session up, no prefixes advertised; or **static-only VPN with no interesting traffic** | Peer `show bgp summary` | Advertise prefixes; for static VPNs generate traffic or enable DPD keepalives |
| DX virtual interface `down`, BGP `idle` | 802.1Q VLAN tag mismatch, wrong peer IPs, wrong ASN, or the cross-connect is not patched | `describe-virtual-interfaces`; ask the colo for a light-level reading | Correct VLAN/ASN; escalate the cross-connect |
| Traffic works over DX for small packets, hangs for large transfers | **MTU mismatch** — jumbo frames (9001 on private VIF, 8500 via Transit Gateway) not consistent end to end | `ping -M do -s 8972 <target>` | Make MTU uniform, or clamp MSS |
| Beanstalk `Immutable` deploy fails: *"Failed to create the temporary Auto Scaling group"* | EC2 instance limit or EIP/subnet capacity — immutable needs a **second full fleet** | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | Raise the quota, or use `RollingWithAdditionalBatch` |
| Blue/green swap done, old environment still receiving traffic | DNS TTL caching on the client side | `dig +short <cname>` from a client | Wait out the TTL before terminating blue; prefer listener-based swaps |

### 8.3 Reading stack events — the first failure is the only one that matters

```
$ aws cloudformation describe-stack-events --stack-name plat-dev \
    --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatusReason])' \
    --output text
2026-09-04T09:12:41.883000+00:00	AutoScalingGroup	Received 0 SUCCESS signal(s) out of 2. Unable to satisfy 100 percent MinSuccessfulInstancesPercent requirement
2026-09-04T09:12:44.117000+00:00	plat-dev	The following resource(s) failed to create: [AutoScalingGroup].
```

CloudFormation reports the *cascade*; `reverse()` puts the root cause first. Then go to the instance, not to the template:

```
$ aws ssm start-session --target i-0d18e4a7fb932c065
sh-5.2$ sudo tail -20 /var/log/cloud-init-output.log
+ dnf -y install python3 amazon-cloudwatch-agent
Amazon Linux 2023 repository            0.0  B/s |   0  B     00:30
Errors during downloading metadata for repository 'amazonlinux':
  - Curl error (28): Timeout was reached for https://cdn.amazonlinux.com/al2023/core/mirrors/latest/x86_64/mirror.list
Error: Failed to download metadata for repo 'amazonlinux'
```

That is not a CloudFormation problem, an ASG problem or a health-check problem. It is a **route table** problem: the private subnets have no path to the NAT gateway. The signal chain — `CREATE_FAILED` → no `cfn-signal` → `dnf` timeout → missing default route — is the diagnostic discipline this task statement is really about.

---

## 9. Exam traps: the distinctions that decide questions

| If the question says… | The answer is… | Because |
|---|---|---|
| "Repeatable, version-controlled infrastructure" | **AWS CloudFormation** | Declarative IaC is the defining phrase |
| "Define infrastructure using a familiar programming language" | **AWS CDK** | The language is the discriminator |
| "Upload code, AWS handles capacity, load balancing, scaling and health monitoring; I keep control of the resources" | **AWS Elastic Beanstalk** | The classic PaaS description; **Beanstalk itself is free** |
| "Deploy a containerised web app with the least operational overhead, no orchestration to manage" | **AWS App Runner** | Beyond Beanstalk on the abstraction ladder |
| "Run AWS infrastructure and services **in my own data centre**" | **AWS Outposts** | The only "AWS hardware on-prem" answer |
| "Single-digit millisecond latency to end users in a specific metro area" | **AWS Local Zones** | Metro, not carrier |
| "Lowest latency to **mobile 5G** devices" | **AWS Wavelength** | Carrier network |
| "Move petabytes where the network would take too long" | **AWS Snowball Edge** | Offline bulk transfer |
| "Private, dedicated, consistent-throughput link to AWS" | **AWS Direct Connect** | Physical circuit |
| "Private connectivity to AWS, **encrypted**, and I need it this week" | **AWS Site-to-Site VPN** | DX has lead time and no encryption |
| "Ensure high availability for our Direct Connect link at the lowest cost" | **Add a Site-to-Site VPN as backup** | A second DX is the expensive option |
| "Individual remote employees need to reach VPC resources" | **AWS Client VPN** | Client, not site-to-site |
| "Reach S3 without traversing the internet, at no extra cost" | **Gateway VPC endpoint** | Interface endpoints cost per hour; gateway endpoints (S3/DynamoDB) are free |
| "Administer EC2 instances without opening port 22 or running a bastion" | **Systems Manager Session Manager** | Outbound-only agent, IAM-authorised, logged |
| "Run CLI commands from a browser with no local install" | **AWS CloudShell** | Pre-authenticated browser shell |
| "Who changed this resource, and when?" | **AWS CloudTrail** | API activity, including Console clicks |
| "Deploy with the ability to roll back instantly, at the cost of running two environments" | **Blue/green** | The cost/rollback trade in the strategy table |

---

## 10. Referencias

**Exam guide (authoritative scope for this task statement)**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner certification page — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Access methods and the AWS API**
- AWS Management Console — https://docs.aws.amazon.com/awsconsolehelpdocs/latest/gsg/getting-started.html
- AWS CLI v2 User Guide — https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html
- AWS SDKs and Tools Reference Guide (credential provider chain) — https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
- Signature Version 4 signing process — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
- AWS CloudShell User Guide — https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html
- AWS IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- Instance metadata and IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html

**Infrastructure as Code and deployment**
- AWS CloudFormation User Guide — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- CloudFormation template anatomy — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-anatomy.html
- CloudFormation change sets — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html
- Detecting unmanaged configuration changes (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- AWS CDK Developer Guide — https://docs.aws.amazon.com/cdk/v2/guide/home.html
- AWS SAM Developer Guide — https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html
- AWS Elastic Beanstalk Developer Guide — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- Elastic Beanstalk deployment policies and settings — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/using-features.deploy-existing-version.html
- Elastic Beanstalk configuration options reference — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/command-options-general.html
- AWS App Runner Developer Guide — https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html
- AWS CodeDeploy User Guide — https://docs.aws.amazon.com/codedeploy/latest/userguide/welcome.html
- CodeDeploy AppSpec file reference — https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file.html
- CodeDeploy deployment configurations — https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-configurations.html
- Blue/Green Deployments on AWS (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/blue-green-deployments/welcome.html

**Deployment models: hybrid and edge**
- AWS Outposts User Guide — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength Developer Guide — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Snowball Edge Developer Guide — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- AWS Storage Gateway User Guide — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- Amazon ECS Anywhere — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-anywhere.html
- Amazon EKS Anywhere — https://anywhere.eks.amazonaws.com/docs/
- Hybrid cloud on AWS — https://aws.amazon.com/hybrid/

**Connectivity**
- AWS Site-to-Site VPN User Guide — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- AWS Client VPN Administrator Guide — https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html
- AWS Direct Connect User Guide — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- Direct Connect resiliency recommendations — https://docs.aws.amazon.com/directconnect/latest/UserGuide/reliability_pillar.html
- Direct Connect virtual interfaces — https://docs.aws.amazon.com/directconnect/latest/UserGuide/WorkingWithVirtualInterfaces.html
- MACsec on Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/MACsec.html
- AWS Transit Gateway — https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html
- AWS PrivateLink concepts — https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-share-your-services.html
- Gateway VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- Amazon VPC-to-Amazon VPC connectivity options (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-vpc-connectivity-options/welcome.html

**Operations**
- AWS Systems Manager User Guide — https://docs.aws.amazon.com/systems-manager/latest/userguide/what-is-systems-manager.html
- Session Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- Systems Manager Patch Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Amazon Time Sync Service — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
- AWS Well-Architected Framework — Operational Excellence Pillar — https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html