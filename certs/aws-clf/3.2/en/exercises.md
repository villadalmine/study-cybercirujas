# Topic 3.2 — Define the AWS Global Infrastructure

## Guided exercises — CLF-C02, Domain 3 (Cloud Technology and Services), weight 4.25%

> **How to use this document.** Every block is a sequence of numbered steps you actually run, followed by verification questions. Do not read the answers first: the questions are designed to be answerable *only* from the output you produced, because the whole point of this topic is that the AWS global infrastructure is a **queryable, versioned dataset**, not a list to memorise. Region counts, AZ counts and PoP counts change every quarter; the APIs do not.
>
> **Cost.** Every command in exercises 0–8, 10 and 11 is a read-only API call, a public HTTPS GET, or a free control-plane operation — $0.00. Exercise 9 creates a VPC and subnets, which are free of charge; the cleanup step is mandatory anyway. Two commands are shown but deliberately **not** executed because they are billable (Elastic IP allocation, NAT Gateway); they are marked `# DO NOT RUN`.
>
> **Non-goal.** This is not a networking course. We touch VPC only where it is the observable consequence of a global-infrastructure decision.

---

## Exercise 0 — Prepare and verify the toolchain

You need AWS CLI v2, `jq`, `curl`, `dig` and `awk`. An IAM principal with `ReadOnlyAccess` is enough for everything except exercise 9 (which needs `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:DeleteSubnet`, `ec2:DeleteVpc`) and exercise 3's optional opt-in step (`ec2:ModifyAvailabilityZoneGroup`).

1. Confirm the CLI major version. v1 paginates and formats differently and several commands below will behave oddly on it.

```bash
aws --version
```

```
aws-cli/2.28.11 Python/3.13.4 Linux/6.14.0 exe/x86_64.fedora.42
```

2. Confirm who you are and, critically, **which partition** your credentials live in. Read the ARN, not the account number.

```bash
aws sts get-caller-identity --output json
```

```json
{
    "UserId": "AIDA2EXAMPLEIDHERE",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/clf-lab"
}
```

3. Note the Region your CLI defaults to, and where that default came from. Precedence is: `--region` flag → `AWS_REGION` → `AWS_DEFAULT_REGION` → `region` in the active profile → EC2/ECS instance metadata. There is **no** global default; an unset Region is an error, not a fallback to `us-east-1`.

```bash
aws configure list
```

```
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                 clf-lab            manual    --profile
access_key     ****************MPLE shared-credentials-file
secret_key     ****************MPLE shared-credentials-file
    region                us-east-1      config-file    ~/.aws/config
```

4. Pin a Region for the rest of the lab so results are reproducible, and export it.

```bash
export AWS_REGION=us-east-1
export LAB_REGION=us-east-1
```

**Check your understanding**

- **Q0.1** — Your ARN begins `arn:aws:`. What are the other two publicly available values in that field, and what concrete operational consequence follows from a resource being in a different one?
- **Q0.2** — A teammate says "if you don't set a Region, the CLI just uses N. Virginia." Under what single, specific circumstance is that statement *effectively* true, and why is it still the wrong mental model?

---

## Exercise 1 — Enumerate the Regions, and separate "exists" from "enabled"

A **Region** is a named, physically separate geographic area containing a cluster of Availability Zones. It is the coarsest fault-isolation boundary AWS offers and the boundary at which your data sits still: AWS does not replicate customer data out of a Region unless you configure a service to do it.

1. Ask EC2 for the Regions your account can currently use.

```bash
aws ec2 describe-regions --query 'length(Regions)'
```

```
17
```

2. Now ask for *all* Regions in your partition, including the ones you have never turned on.

```bash
aws ec2 describe-regions --all-regions \
  --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
  --output table
```

```
-------------------------------------------
|             DescribeRegions             |
+------------------+----------------------+
|  af-south-1      |  not-opted-in        |
|  ap-east-1       |  not-opted-in        |
|  ap-northeast-1  |  opt-in-not-required |
|  ap-northeast-2  |  opt-in-not-required |
|  ap-northeast-3  |  opt-in-not-required |
|  ap-south-1      |  opt-in-not-required |
|  ap-south-2      |  not-opted-in        |
|  ap-southeast-1  |  opt-in-not-required |
|  ap-southeast-2  |  opt-in-not-required |
|  ap-southeast-3  |  not-opted-in        |
|  ca-central-1    |  opt-in-not-required |
|  eu-central-1    |  opt-in-not-required |
|  eu-central-2    |  not-opted-in        |
|  eu-north-1      |  opt-in-not-required |
|  eu-south-1      |  not-opted-in        |
|  eu-west-1       |  opt-in-not-required |
|  eu-west-2       |  opt-in-not-required |
|  eu-west-3       |  opt-in-not-required |
|  il-central-1    |  not-opted-in        |
|  sa-east-1       |  opt-in-not-required |
|  us-east-1       |  opt-in-not-required |
|  us-east-2       |  opt-in-not-required |
|  us-west-1       |  opt-in-not-required |
|  us-west-2       |  opt-in-not-required |
+------------------+----------------------+
```

*(Your list will be longer than this excerpt and will not match it exactly. That is the lesson.)*

3. Isolate the difference between the two numbers.

```bash
aws ec2 describe-regions --all-regions \
  --query "Regions[?OptInStatus=='not-opted-in'].RegionName" --output text | tr '\t' '\n'
```

4. Decode a Region code. It is `<geography>-<compass-or-qualifier>-<ordinal>`, where the ordinal is the **launch order within that geography**, not a rank, not a size, and not a preference.

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/global-infrastructure/regions/ap-northeast-3/longName \
  --query 'Parameter.Value' --output text
```

```
Asia Pacific (Osaka)
```

5. Ask the same question through the Account Management API, which is the org-aware path and the one that can *change* the answer.

```bash
aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
  --query 'length(Regions)'
```

```
17
```

```bash
# Enabling a Region is free and takes minutes to hours. It is also a governance
# decision — an enabled Region is a Region in which somebody can create resources.
# aws account enable-region --region-name ap-east-1
```

**Check your understanding**

- **Q1.1** — `describe-regions` returned fewer Regions than `describe-regions --all-regions`. Explain the difference in terms of what AWS built versus what your account has consented to, and name the two Regions that are permanently `opt-in-not-required` for structural reasons.
- **Q1.2** — Which Regions were `opt-in-not-required`, and what do they have in common historically? Why did AWS change the default for Regions launched after that point?
- **Q1.3** — `ap-northeast-3` is Osaka and `ap-northeast-1` is Tokyo. Does the ordinal `1` tell you anything about relative capacity, AZ count, or service coverage? What *does* it tell you?
- **Q1.4** — Your organisation's security team wants to guarantee no engineer can launch anything in Regions outside the EU. Name two mechanisms — one from this exercise, one from AWS Organizations — and explain which one is the actual control and which is merely a convenience.
- **Q1.5** — Neither command above will ever return `cn-north-1`. Why not, and what would it take for you to see it?

---

## Exercise 2 — Availability Zones: the name lies, the ID does not

An **Availability Zone** is one or more discrete data centres with redundant power, networking and connectivity, in separate facilities, far enough apart to survive a localised failure (AWS states all AZs in a Region are within 100 km / 60 miles of each other) and close enough that inter-AZ latency stays in the low single-digit millisecond range — which is what makes **synchronous** replication across AZs practical and synchronous replication across Regions impractical.

1. List the AZs in your Region with both their name and their ID.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,State,NetworkBorderGroup]' \
  --output table
```

```
------------------------------------------------------------------------------
|                         DescribeAvailabilityZones                          |
+-------------+------------+--------------------+-----------+----------------+
|  us-east-1a |  use1-az2  |  availability-zone |  available|  us-east-1     |
|  us-east-1b |  use1-az4  |  availability-zone |  available|  us-east-1     |
|  us-east-1c |  use1-az6  |  availability-zone |  available|  us-east-1     |
|  us-east-1d |  use1-az1  |  availability-zone |  available|  us-east-1     |
|  us-east-1e |  use1-az3  |  availability-zone |  available|  us-east-1     |
|  us-east-1f |  use1-az5  |  availability-zone |  available|  us-east-1     |
+-------------+------------+--------------------+-----------+----------------+
```

2. Look hard at the mapping. In the output above, `us-east-1a` is **`use1-az2`**, not `use1-az1`. Run the same command with a different AWS account's credentials if you have one; the `ZoneName` → `ZoneId` mapping will be different.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[].{name:ZoneName,id:ZoneId}' --output json | jq -c '.[]'
```

```
{"name":"us-east-1a","id":"use1-az2"}
{"name":"us-east-1b","id":"use1-az4"}
{"name":"us-east-1c","id":"use1-az6"}
```

3. Compare AZ counts across several Regions. Do not assume three.

```bash
for r in us-east-1 us-west-1 sa-east-1 eu-west-1 eu-central-1 ap-southeast-1; do
  n=$(aws ec2 describe-availability-zones --region "$r" \
        --filters Name=zone-type,Values=availability-zone \
        --query 'length(AvailabilityZones)' --output text)
  printf '%-16s %s AZs\n' "$r" "$n"
done
```

```
us-east-1        6 AZs
us-west-1        2 AZs
sa-east-1        3 AZs
eu-west-1        3 AZs
eu-central-1     3 AZs
ap-southeast-1   3 AZs
```

4. Check whether any AZ is currently reporting an issue. `Messages` is normally empty; it is populated during a zone impairment.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[?length(Messages) > `0`]' --output json
```

```json
[]
```

**Check your understanding**

- **Q2.1** — Account A launches into `us-east-1a` and account B launches into `us-east-1a`. Are they in the same physical zone? Justify with the field that settles it.
- **Q2.2** — Why did AWS randomise the name→ID mapping per account in the first place? What behaviour was it correcting?
- **Q2.3** — You are sharing subnets across accounts with AWS RAM, and you need the shared subnet in the same zone as the consumer's existing workload. Which identifier goes in the ticket, and which one is useless?
- **Q2.4** — `us-west-1` returned 2 AZs. Does that mean the Region physically has two data-centre clusters? What is the safe way to phrase what you actually learned?
- **Q2.5** — An RDS Multi-AZ deployment survives the loss of one AZ. A single EC2 instance in one AZ does not. Which half of that is AWS's responsibility under the shared responsibility model, and which is yours?
- **Q2.6** — Why is cross-AZ synchronous replication normal engineering practice while cross-Region synchronous replication is generally not? Answer in terms of a number you can compute from geography.

---

## Exercise 3 — The zone taxonomy: AZ, Local Zone, Wavelength Zone

Not every "zone" is an AZ. `zone-type` is the discriminator, and the `ParentZoneName` field is what tells you the thing is an *extension of* a Region rather than a Region of its own.

1. Enumerate every zone type visible to you across a Region that has all three.

```bash
aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,GroupName,ParentZoneName,OptInStatus]' \
  --output table
```

```
--------------------------------------------------------------------------------------------------------
|                                     DescribeAvailabilityZones                                        |
+----------------------+-----------------+------------------+--------------------+-----------+---------+
|  us-west-2a          |  usw2-az1       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2b          |  usw2-az2       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2c          |  usw2-az3       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2d          |  usw2-az4       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2-lax-1a    |  usw2-lax1-az1  |  local-zone       |  us-west-2-lax-1  |  us-west-2| not-opted-in        |
|  us-west-2-lax-1b    |  usw2-lax1-az2  |  local-zone       |  us-west-2-lax-1  |  us-west-2| not-opted-in        |
|  us-west-2-phx-1a    |  usw2-phx1-az1  |  local-zone       |  us-west-2-phx-1  |  us-west-2| not-opted-in        |
+----------------------+-----------------+------------------+--------------------+-----------+---------+
```

2. Count Local Zones without the noise.

```bash
aws ec2 describe-availability-zones --all-availability-zones --region us-west-2 \
  --filters Name=zone-type,Values=local-zone \
  --query 'length(AvailabilityZones)'
```

3. Probe for Wavelength Zones. An empty list is a valid and informative result — Wavelength coverage is narrow and changes with carrier agreements.

```bash
for r in us-east-1 us-west-2 eu-west-2 ap-northeast-1; do
  n=$(aws ec2 describe-availability-zones --region "$r" --all-availability-zones \
        --filters Name=zone-type,Values=wavelength-zone \
        --query 'length(AvailabilityZones)' --output text)
  printf '%-16s %s wavelength zones\n' "$r" "$n"
done
```

4. *(Optional, free.)* Opt into a Local Zone group. Enabling the group costs nothing; only resources you then launch there are billed. Do this only if you will run the cleanup in step 5.

```bash
aws ec2 modify-availability-zone-group \
  --region us-west-2 --group-name us-west-2-lax-1 --opt-in-status opted-in
```

```json
{ "Return": true }
```

```bash
aws ec2 describe-availability-zones --region us-west-2 \
  --filters Name=zone-name,Values=us-west-2-lax-1a \
  --query 'AvailabilityZones[].[ZoneName,OptInStatus,NetworkBorderGroup]' --output text
```

```
us-west-2-lax-1a	opted-in	us-west-2-lax-1
```

5. **Cleanup.** Opt back out.

```bash
aws ec2 modify-availability-zone-group \
  --region us-west-2 --group-name us-west-2-lax-1 --opt-in-status not-opted-in
```

6. Observe the fourth extension model, which has no zone entry at all until you own hardware:

```bash
aws outposts list-outposts --region "$LAB_REGION" --query 'Outposts' --output json
```

```json
[]
```

**Check your understanding**

- **Q3.1** — A Local Zone has a `ParentZoneName` and an AZ does not. What does that field actually buy you architecturally — what lives in the parent Region when you run a workload in `us-west-2-lax-1a`?
- **Q3.2** — Rank AZ, Local Zone, Wavelength Zone and Outpost by "how close to the end user" and state the one workload class that justifies each.
- **Q3.3** — Both `NetworkBorderGroup` and `GroupName` read `us-west-2-lax-1` for the LAX zones, while for a normal AZ both read `us-west-2`. What does `NetworkBorderGroup` control, and why can't you move an Elastic IP between border groups?
- **Q3.4** — An Outpost sits in your own building. Which of these still runs in the parent Region: the EC2 data plane, the EC2 control plane, the EBS volumes attached to Outpost instances, the CloudWatch metrics? What happens to each when your building loses its uplink to AWS?
- **Q3.5** — A customer says "we'll use a Local Zone for disaster recovery, since it's a separate location from the Region." Rebut this in one sentence using the fault-isolation boundary concept.

---

## Exercise 4 — The authoritative machine-readable map

AWS publishes the entire global-infrastructure catalogue as **public Systems Manager parameters**. This is the same data behind the marketing map, it is versioned, and reading it is free. This is how you answer "is service X in Region Y" in a script instead of in a browser tab.

1. Get the dataset version. Record it; it is the honest way to date any claim you make about Region counts.

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/global-infrastructure/version \
  --query 'Parameter.Value' --output text
```

```
1.0.0-20260901
```

2. List every Region AWS publishes, independent of your account's opt-in state.

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | tee /tmp/all-regions.txt | wc -l
```

3. Diff that against what your account can use. This is the "what am I not using, and why" audit.

```bash
aws ec2 describe-regions --query 'Regions[].RegionName' --output text \
  | tr '\t' '\n' | sort > /tmp/enabled-regions.txt
comm -23 /tmp/all-regions.txt /tmp/enabled-regions.txt
```

4. Pull the attributes of a single Region. These four are the raw inputs to a data-residency decision.

```bash
for attr in longName partition domain geolocationCountry geolocationRegion; do
  v=$(aws ssm get-parameter --region us-east-1 \
       --name "/aws/service/global-infrastructure/regions/sa-east-1/$attr" \
       --query 'Parameter.Value' --output text 2>/dev/null)
  printf '%-20s %s\n' "$attr" "$v"
done
```

```
longName             South America (Sao Paulo)
partition            aws
domain               amazonaws.com
geolocationCountry   BR
geolocationRegion    SA
```

5. Answer "which Regions offer this service" without guessing.

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/services/bedrock/regions \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
```

6. And the inverse — "what does this Region offer".

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions/sa-east-1/services \
  --query 'length(Parameters)'
```

```
243
```

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions/us-east-1/services \
  --query 'length(Parameters)'
```

```
298
```

7. Compute the gap for a real migration question: what is in `us-east-1` that is *not* in `sa-east-1`?

```bash
svc() { aws ssm get-parameters-by-path --region us-east-1 \
  --path "/aws/service/global-infrastructure/regions/$1/services" \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort; }
comm -23 <(svc us-east-1) <(svc sa-east-1) | head -20
```

**Check your understanding**

- **Q4.1** — Step 6 showed a meaningful difference in service count between two Regions. State the general rule for how AWS rolls out a new service across Regions, and name the Region that is almost always first.
- **Q4.2** — You designed an architecture in `us-east-1` using six services and now must redeploy it in `il-central-1` for a residency requirement. Write the exact one-line check you would run *before* estimating the work.
- **Q4.3** — `geolocationCountry` for `sa-east-1` is `BR`. Is that sufficient to satisfy a Brazilian data-residency obligation? What else must be true, and which AWS resources would still sit outside Brazil?
- **Q4.4** — Why does the `version` parameter matter more than the region count you derived from it?

---

## Exercise 5 — Measure the physics: Region choice is a latency decision

Light in single-mode fibre travels at roughly ⅔ c ≈ 200 km/ms. A round trip over a perfectly straight fibre therefore costs about **1 ms per 100 km of separation**. Real paths are 1.3–2× longer than great-circle distance and add switching and queueing delay. No amount of AWS engineering repeals this, which is why "put the Region near the users" is an architectural constraint and not a preference.

1. Measure the TCP handshake — one round trip — to several regional API endpoints. `time_connect - time_namelookup` is your RTT; TLS is charged separately so you can see it.

```bash
for r in us-east-1 us-west-2 eu-west-1 eu-central-1 sa-east-1 ap-southeast-1 ap-northeast-1; do
  best=99
  for i in 1 2 3; do
    read -r dns conn tls <<<"$(curl -s -o /dev/null --connect-timeout 5 \
      -w '%{time_namelookup} %{time_connect} %{time_appconnect}' \
      "https://dynamodb.${r}.amazonaws.com/")"
    best=$(awk -v a="$best" -v c="$conn" -v d="$dns" 'BEGIN{r=(c-d)*1000; print (r<a && r>0)?r:a}')
  done
  printf '%-16s rtt≈%6.1f ms\n' "$r" "$best"
done
```

```
us-east-1        rtt≈ 122.4 ms
us-west-2        rtt≈ 176.9 ms
eu-west-1        rtt≈ 205.1 ms
eu-central-1     rtt≈ 221.7 ms
sa-east-1        rtt≈  32.8 ms
ap-southeast-1   rtt≈ 331.5 ms
ap-northeast-1   rtt≈ 289.2 ms
```

*(Measured from Buenos Aires. Yours will differ; the shape is what matters.)*

2. Convert your best result back into a distance and sanity-check it against a map.

```bash
awk 'BEGIN{ rtt=32.8; printf "implied one-way path length ≈ %.0f km\n", (rtt/2)*200 }'
```

```
implied one-way path length ≈ 3280 km
```

3. Now measure what a chatty application pays. A 12-round-trip request sequence (TCP + TLS + auth + a few dependent queries) against the *second* best Region:

```bash
awk 'BEGIN{ near=32.8; far=122.4; n=12;
  printf "near: %6.0f ms   far: %6.0f ms   penalty: %.1fx\n", near*n, far*n, far/near }'
```

```
near:    394 ms   far:   1469 ms   penalty: 3.7x
```

4. Confirm the endpoint you hit is regional and not anycast, by resolving it and checking the IP is announced from that Region.

```bash
dig +short dynamodb.sa-east-1.amazonaws.com
```

```
52.94.5.44
```

**Check your understanding**

- **Q5.1** — Your measured RTT to the nearest Region implies a path length noticeably longer than the straight-line distance. Give two reasons that is expected and *not* a sign of a problem.
- **Q5.2** — Step 3 multiplied RTT by 12. Explain why moving a Region 4,000 km further away can degrade a page load by far more than the raw RTT delta, and name the design change that mitigates it without moving the Region.
- **Q5.3** — Which of these are improved by choosing a closer Region, and which are not: first-byte latency for a dynamic API call; download time for a 2 GB static video; database write latency; TLS handshake cost?
- **Q5.4** — You have users in São Paulo, Frankfurt and Singapore and a single relational database that must stay consistent. What does the physics in this exercise force you to decide, and what are the two legitimate answers?

---

## Exercise 6 — The edge network: PoPs, regional edge caches, and the address space

Edge locations are the third tier of the infrastructure, and there are far more of them than Regions. They serve CloudFront, Route 53, AWS Global Accelerator, AWS WAF and AWS Shield. They are **not** a place you deploy an application; they are a place AWS terminates connections on your behalf.

1. Fetch the exam guide itself — it is served through CloudFront — and read the edge headers.

```bash
curl -sI https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf \
  | grep -Ei 'x-amz-cf-pop|x-cache|via|age|x-amz-cf-id'
```

```
x-cache: Hit from cloudfront
via: 1.1 6f1c8a4e2b9d3f7a05c1e2d4b6a8c0f3.cloudfront.net (CloudFront)
x-amz-cf-pop: GRU1-C1
x-amz-cf-id: kQ8n2Z-vX1pR4tYbLmA0cJdWfHsE3iOu9Nx7gVqTlPzKrBySd6MwCg==
age: 8412
```

2. Decode `x-amz-cf-pop`. The first three characters are the **IATA airport code** of the metropolitan area; the digits distinguish multiple PoPs in that metro; the suffix marks the facility.

```bash
curl -sI https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf \
  | awk -F': ' '/x-amz-cf-pop/{print "IATA:", substr($2,1,3)}'
```

```
IATA: GRU
```

3. Prove the edge is chosen by *network* location, not by the Region of the content, by resolving a CloudFront hostname through two geographically different resolvers.

```bash
dig +short d1.awsstatic.com @1.1.1.1 | tail -2
dig +short d1.awsstatic.com @8.8.8.8 | tail -2
```

4. Download the authoritative IP ranges file — no credentials, no cost — and count the address space by service.

```bash
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json -o /tmp/ip-ranges.json
jq -r '.syncToken, .createDate' /tmp/ip-ranges.json
jq -r '[.prefixes[].service] | group_by(.) | map({s:.[0], n:length}) | sort_by(-.n)[:10][] | "\(.n)\t\(.s)"' /tmp/ip-ranges.json
```

```
1757001123
2026-09-04-14-32-03
2318	AMAZON
1204	EC2
 187	S3
  94	CLOUDFRONT
  61	CLOUDFRONT_ORIGIN_FACING
  38	ROUTE53_HEALTHCHECKS
  22	GLOBALACCELERATOR
  ...
```

5. Look at the `region` field for the two global services. This is where "global service" stops being marketing language.

```bash
jq -r '.prefixes[] | select(.service=="CLOUDFRONT" or .service=="GLOBALACCELERATOR")
       | "\(.service)\t\(.region)\t\(.network_border_group)"' /tmp/ip-ranges.json | sort -u | head -5
```

```
CLOUDFRONT	GLOBAL	GLOBAL
GLOBALACCELERATOR	GLOBAL	GLOBAL
```

6. Now find the prefixes whose `network_border_group` is a Local Zone — the address-space consequence of exercise 3.

```bash
jq -r '.prefixes[] | select(.network_border_group != .region)
       | "\(.region)\t\(.network_border_group)"' /tmp/ip-ranges.json | sort -u | head -8
```

```
us-east-1	us-east-1-atl-1
us-east-1	us-east-1-mia-1
us-west-2	us-west-2-den-1
us-west-2	us-west-2-lax-1
us-west-2	us-west-2-phx-1
```

7. Instead of parsing that file into security groups by hand, use the AWS-managed prefix lists — the maintained, referenceable form of the same data.

```bash
aws ec2 describe-managed-prefix-lists --region "$LAB_REGION" \
  --filters Name=owner-id,Values=AWS \
  --query 'PrefixLists[].[PrefixListName,PrefixListId,AddressFamily]' --output table
```

```
------------------------------------------------------------------------------------
|                          DescribeManagedPrefixLists                              |
+---------------------------------------------------+----------------+-------------+
|  com.amazonaws.global.cloudfront.origin-facing     |  pl-3b927c52   |  IPv4       |
|  com.amazonaws.global.groundstation                |  pl-34a6465d   |  IPv4       |
|  com.amazonaws.us-east-1.dynamodb                  |  pl-02cd2c6b   |  IPv4       |
|  com.amazonaws.us-east-1.s3                        |  pl-63a5400a   |  IPv4       |
|  com.amazonaws.us-east-1.vpc-lattice               |  pl-0e1a2b3c   |  IPv4       |
+---------------------------------------------------+----------------+-------------+
```

```bash
# DO NOT RUN — allocating a public IPv4 address is billed hourly whether or not it is attached.
# aws ec2 allocate-address --network-border-group us-west-2-lax-1
```

**Check your understanding**

- **Q6.1** — Your `x-amz-cf-pop` showed a metro near you, but the file itself is stored in an S3 bucket in a US Region. Describe the full path the bytes took on a cache **miss**, naming all three infrastructure tiers involved.
- **Q6.2** — `x-cache` read `Hit from cloudfront`. Which tier served it, and which tier would a `Miss` have consulted *before* reaching the origin? What is that middle tier called and what problem does it solve?
- **Q6.3** — Both CloudFront and Global Accelerator put your traffic onto the AWS backbone at the nearest edge. Give the two decisive differences that make one of them wrong for a UDP game server and the other wrong for a static website.
- **Q6.4** — Why is `com.amazonaws.global.cloudfront.origin-facing` a *smaller* set than `CLOUDFRONT`, and which one belongs in your origin's security group?
- **Q6.5** — Edge locations are far more numerous than Regions. Explain in one sentence why AWS can build hundreds of the former and only tens of the latter.
- **Q6.6** — A colleague proposes "deploy the application to edge locations to reduce latency." Correct the statement precisely: what *can* run at the edge, and what cannot?

---

## Exercise 7 — Global versus Regional: endpoints, ARNs, and the S3 namespace trap

"Global service" means the **control plane** has a single global namespace. It does not mean the service has no home. Almost every global service is anchored in a Region, and that anchoring shows up in your incident post-mortems.

1. Contrast a global endpoint with a regional one for the same service family.

```bash
dig +short iam.amazonaws.com
dig +short sts.amazonaws.com
dig +short sts.sa-east-1.amazonaws.com
```

2. Confirm where the IAM endpoint's addresses are announced, using the file from exercise 6.

```bash
IAM_IP=$(dig +short iam.amazonaws.com | head -1)
python3 - "$IAM_IP" <<'PY'
import ipaddress, json, sys
ip = ipaddress.ip_address(sys.argv[1])
for p in json.load(open('/tmp/ip-ranges.json'))['prefixes']:
    if ip in ipaddress.ip_network(p['ip_prefix']):
        print(p['ip_prefix'], p['region'], p['service'])
PY
```

```
52.46.128.0/19 us-east-1 AMAZON
```

3. Note that a global service call still requires a Region on the wire, and that CLI signing reflects it.

```bash
aws iam list-account-aliases --region sa-east-1 --debug 2>&1 \
  | grep -m1 -o 'AWS4-HMAC-SHA256 Credential=[^,]*'
```

```
AWS4-HMAC-SHA256 Credential=AKIA.../20260904/us-east-1/iam/aws4_request
```

4. Read ARNs as structured data. The `region` and `account` fields being empty is information.

```bash
cat <<'EOF' | column -t -s'|'
arn:aws:ec2:us-east-1:123456789012:instance/i-0abc123|regional + account-scoped
arn:aws:iam::123456789012:role/AppRole|global, account-scoped
arn:aws:s3:::my-bucket|global namespace, no account in ARN
arn:aws:s3:us-east-1:123456789012:accesspoint/ap1|regional S3 construct
arn:aws:cloudfront::123456789012:distribution/E2QEXAMPLE|global service, account-scoped
arn:aws-cn:s3:::my-bucket|different partition entirely
EOF
```

5. Demonstrate the S3 split personality: the **name** is global, the **data** is regional. Pick a unique bucket name.

```bash
B="clf32-lab-$(aws sts get-caller-identity --query Account --output text)-$$"
aws s3api create-bucket --bucket "$B" --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1
aws s3api get-bucket-location --bucket "$B" --query LocationConstraint --output text
```

```
eu-west-1
```

6. Now address that bucket through the *wrong* regional endpoint and read the error carefully.

```bash
aws s3api head-bucket --bucket "$B" --region us-east-1 2>&1 | head -3
```

```
An error occurred (301) when calling the HeadBucket operation: Moved Permanently
```

7. Create a bucket in `us-east-1` and observe the legacy quirk in the same field.

```bash
B2="clf32-lab2-$(aws sts get-caller-identity --query Account --output text)-$$"
aws s3api create-bucket --bucket "$B2" --region us-east-1
aws s3api get-bucket-location --bucket "$B2" --output json
```

```json
{ "LocationConstraint": null }
```

8. **Cleanup.**

```bash
aws s3api delete-bucket --bucket "$B" --region eu-west-1
aws s3api delete-bucket --bucket "$B2" --region us-east-1
```

**Check your understanding**

- **Q7.1** — `LocationConstraint` came back `null` for the `us-east-1` bucket. Is the bucket therefore "global"? Explain the actual reason for the null.
- **Q7.2** — Step 3 showed an IAM call made with `--region sa-east-1` being signed for `us-east-1`. What does this predict about the blast radius of a `us-east-1` control-plane event on IAM *writes* worldwide? On IAM *authorisation decisions* worldwide?
- **Q7.3** — AWS recommends regional STS endpoints over the global one. Give both reasons — one about latency, one about failure isolation.
- **Q7.4** — Classify each as global or regional, and state the boundary that makes it so: Route 53 hosted zones, Route 53 Resolver endpoints, CloudFront distributions, S3 bucket names, S3 objects, IAM users, EC2 key pairs, ACM certificates.
- **Q7.5** — Why must an ACM certificate used by a CloudFront distribution be requested in `us-east-1` specifically, and what does that tell you about where CloudFront's control plane lives?
- **Q7.6** — Two AWS customers cannot both own the bucket name `logs`. Two AWS customers *can* both own the EC2 instance name tag `web-01`. Explain the namespace difference in terms of what is addressable by URL.

---

## Exercise 8 — Capacity and hardware are per-AZ, not per-Region

"The Region has instance type X" is a claim that fails in production. Instance families are rolled out per-AZ, and an `InsufficientInstanceCapacity` error at 09:00 on a Monday is an AZ-level event.

1. Find which Regions offer a given instance type at all.

```bash
for r in us-east-1 us-west-2 sa-east-1 eu-central-1 ap-south-1; do
  n=$(aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
        --filters Name=instance-type,Values=c7g.large \
        --query 'length(InstanceTypeOfferings)' --output text)
  printf '%-16s c7g.large: %s\n' "$r" "$([ "$n" = 0 ] && echo NO || echo yes)"
done
```

2. Drill into a single Region and see which **AZ IDs** actually offer it.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=c7g.large \
  --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' --output text
```

```
use1-az1	use1-az2	use1-az4	use1-az6
```

3. Compare against a commodity type to see that the gap is type-specific, not zone-specific.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=m5.large \
  --query 'length(InstanceTypeOfferings)'
```

4. Compute the set difference for a scarce accelerated type — the exact query you run before promising an ML team a Region.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=p5.48xlarge \
  --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n'
```

5. Count how many distinct instance types exist in two Regions.

```bash
for r in us-east-1 sa-east-1; do
  n=$(aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
        --query 'length(InstanceTypeOfferings)' --output text)
  printf '%-16s %s instance types\n' "$r" "$n"
done
```

```
us-east-1        831 instance types
sa-east-1        412 instance types
```

**Check your understanding**

- **Q8.1** — Step 2 returned a subset of the Region's AZs. What does an Auto Scaling group spanning *all* AZs and requesting only `c7g.large` do when it tries to scale into an AZ that does not offer it?
- **Q8.2** — Why is `--location-type availability-zone-id` the correct flag here rather than `availability-zone`, given exercise 2?
- **Q8.3** — Offering ≠ availability. Which failure does this API *not* predict, and which two AWS features exist specifically to guarantee that other thing?
- **Q8.4** — `sa-east-1` has roughly half the instance types of `us-east-1`. Connect this to your answer in Q4.1 and state the general principle in one sentence.

---

## Exercise 9 — Build a three-AZ footprint pinned to AZ IDs

This is where the theory becomes an artefact. VPCs and subnets are free; you will delete them.

1. Create the VPC.

```bash
VPC_ID=$(aws ec2 create-vpc --region "$LAB_REGION" --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf32-lab}]' \
  --query 'Vpc.VpcId' --output text)
echo "$VPC_ID"
```

```
vpc-0ab12cd34ef567890
```

2. Take the first three AZ **IDs**, sorted deterministically, and create one subnet per zone. Note `--availability-zone-id`, not `--availability-zone`.

```bash
i=0
for ZID in $(aws ec2 describe-availability-zones --region "$LAB_REGION" \
      --filters Name=zone-type,Values=availability-zone Name=state,Values=available \
      --query 'AvailabilityZones[].ZoneId' --output text | tr '\t' '\n' | sort | head -3); do
  i=$((i+1))
  SID=$(aws ec2 create-subnet --region "$LAB_REGION" --vpc-id "$VPC_ID" \
        --cidr-block "10.42.$i.0/24" --availability-zone-id "$ZID" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=clf32-$ZID}]" \
        --query 'Subnet.SubnetId' --output text)
  printf '%-12s -> %s (10.42.%s.0/24)\n' "$ZID" "$SID" "$i"
done
```

```
use1-az1     -> subnet-0f1e2d3c4b5a69780 (10.42.1.0/24)
use1-az2     -> subnet-0a9b8c7d6e5f43210 (10.42.2.0/24)
use1-az3     -> subnet-01234abcd5678ef90 (10.42.3.0/24)
```

3. Verify, showing both identifiers side by side. This table is the thing you paste into a design review.

```bash
aws ec2 describe-subnets --region "$LAB_REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'sort_by(Subnets,&AvailabilityZoneId)[].[SubnetId,AvailabilityZone,AvailabilityZoneId,CidrBlock,AvailableIpAddressCount]' \
  --output table
```

```
--------------------------------------------------------------------------------------------------
|                                        DescribeSubnets                                         |
+--------------------------+--------------+------------+----------------+-----------------------+
|  subnet-0f1e2d3c4b5a69780|  us-east-1d  |  use1-az1  |  10.42.1.0/24  |  251                  |
|  subnet-0a9b8c7d6e5f43210|  us-east-1a  |  use1-az2  |  10.42.2.0/24  |  251                  |
|  subnet-01234abcd5678ef90|  us-east-1e  |  use1-az3  |  10.42.3.0/24  |  251                  |
+--------------------------+--------------+------------+----------------+-----------------------+
```

4. Read the `AvailableIpAddressCount`. A /24 has 256 addresses; you got 251.

```bash
# DO NOT RUN — a NAT Gateway is billed per hour plus per GB from the moment it exists,
# and the "one per AZ for real HA" rule multiplies that by three.
# aws ec2 create-nat-gateway --subnet-id <subnet> --allocation-id <eipalloc-...>
```

5. **Cleanup — run this.**

```bash
for S in $(aws ec2 describe-subnets --region "$LAB_REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --region "$LAB_REGION" --subnet-id "$S" && echo "deleted $S"
done
aws ec2 delete-vpc --region "$LAB_REGION" --vpc-id "$VPC_ID" && echo "deleted $VPC_ID"
```

**Check your understanding**

- **Q9.1** — Each /24 reports 251 usable addresses instead of 254. Which five addresses did AWS reserve, and what is each for?
- **Q9.2** — A subnet spans exactly one AZ and a VPC spans all AZs in one Region. Restate both facts as fault-isolation statements: what does the loss of one AZ do to the subnet, to the VPC, to the route tables?
- **Q9.3** — Your Terraform module hard-codes `us-east-1a`, `us-east-1b`, `us-east-1c`. Two accounts deploy it. Describe the specific way this fails, and rewrite the selection rule in one sentence.
- **Q9.4** — The NAT Gateway comment says "one per AZ for real HA." Explain what breaks if you deploy a single NAT Gateway and route all three subnets through it, and identify the *two* separate costs that decision incurs.
- **Q9.5** — You now have three subnets and zero instances. Are you highly available? State precisely what the three-AZ footprint gives you and what it does not.

---

## Exercise 10 — Region selection as a scored decision, not a habit

The exam asks "which Region should the company use." The production answer weighs four factors: **compliance and data residency**, **proximity to users**, **service and feature availability**, and **cost**. Only the first is ever a hard gate.

1. Price the same instance in several Regions. The Pricing API is itself only available in a few Regions, which is a small joke the platform plays on you.

```bash
price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
              "Type=TERM_MATCH,Field=regionCode,Value=$1" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
              "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
              "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --max-results 1 --output json \
  | jq -r '.PriceList[] | fromjson | .terms.OnDemand
           | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD'
}
for r in us-east-1 us-east-2 eu-west-1 eu-central-1 ap-southeast-1 sa-east-1; do
  printf '%-16s $%s /hr\n' "$r" "$(price "$r")"
done
```

```
us-east-1        $0.0960000000 /hr
us-east-2        $0.0960000000 /hr
eu-west-1        $0.1070000000 /hr
eu-central-1     $0.1150000000 /hr
ap-southeast-1   $0.1180000000 /hr
sa-east-1        $0.1530000000 /hr
```

*(Illustrative. Re-run it; the ordering is the durable lesson, the digits are not.)*

2. Express the spread as a multiple, because that is how it lands on an annual bill.

```bash
awk 'BEGIN{ lo=0.096; hi=0.153; printf "spread: %.0f%%   annual delta on 100 instances: $%.0f\n",
  (hi/lo-1)*100, (hi-lo)*24*365*100 }'
```

```
spread: 59%   annual delta on 100 instances: $49932
```

3. Build the decision table for a concrete scenario. **Scenario:** a Brazilian fintech, all users in Brazil, regulator requires customer records stored in Brazil, workload needs Amazon Aurora and AWS Lambda, cost-sensitive.

```bash
for r in sa-east-1 us-east-1; do
  cc=$(aws ssm get-parameter --region us-east-1 \
        --name "/aws/service/global-infrastructure/regions/$r/geolocationCountry" \
        --query 'Parameter.Value' --output text)
  for s in rds lambda; do
    ok=$(aws ssm get-parameters-by-path --region us-east-1 \
          --path "/aws/service/global-infrastructure/regions/$r/services" \
          --query "length(Parameters[?Value=='$s'])" --output text)
    printf '%-12s country=%s  %-8s %s\n' "$r" "$cc" "$s" "$([ "$ok" = 1 ] && echo present || echo ABSENT)"
  done
done
```

4. Fill in the matrix by hand from your own measurements. Weight the columns before you look at the scores.

| Factor | Gate or score? | `sa-east-1` | `us-east-1` |
|---|---|---|---|
| Data residency (BR) | **gate** | pass | **fail** |
| RTT from São Paulo | score | ~10 ms | ~120 ms |
| Aurora + Lambda present | **gate** | pass | pass |
| m5.large on-demand | score | $0.153 | $0.096 |
| Instance type breadth | score | ~412 | ~831 |

**Check your understanding**

- **Q10.1** — In the matrix, one Region is 59% cheaper and has twice the instance types. Why is the decision nevertheless not close? Name the property of a "gate" factor that makes score factors irrelevant.
- **Q10.2** — Regions differ in price by up to ~60% for identical hardware. Give the two structural reasons AWS prices Regions differently.
- **Q10.3** — The fintech later wants a disaster-recovery Region. Which of the four factors changes weight, and which Region would you shortlist? Justify using `geolocationCountry` and the AZ/Region isolation boundary.
- **Q10.4** — A team proposes running everything in `us-east-1` "because it's cheapest and has every service." Give three distinct risks of that default, one from each of: latency, compliance, and blast radius.
- **Q10.5** — Which of the four factors can change *after* you deploy, forcing a re-evaluation? Give a concrete example of each that can.

---

## Exercise 11 — Extending the boundary: Outposts, Local Zones, Wavelength, Dedicated Local Zones

The last piece of the topic is the set of answers to "I need AWS, but not in an AWS Region." Each is an *extension of* a parent Region — the control plane stays in the Region in every case.

1. Confirm your account has no Outposts and inspect the API surface that would describe one.

```bash
aws outposts list-sites --region "$LAB_REGION" --output json
aws outposts list-outposts --region "$LAB_REGION" --output json
```

```json
{ "Sites": [] }
{ "Outposts": [] }
```

2. List the Outpost hardware catalogue — form factors are the concrete difference between "a server in a rack you own" and "a rack AWS delivers".

```bash
aws outposts list-catalog-items --region "$LAB_REGION" \
  --query 'CatalogItems[].[CatalogItemId,ItemStatus,SupportedStorage[0]]' --output table 2>/dev/null | head -12
```

3. Map the four extension models onto the two questions that actually select between them. Complete this table from what you observed in exercise 3:

| Model | Where the hardware sits | Who operates it | Latency target | Control plane |
|---|---|---|---|---|
| Availability Zone | AWS data centre in the Region | AWS | ~1 ms intra-Region | in-Region |
| Local Zone | AWS facility in a metro | AWS | single-digit ms to metro | parent Region |
| Wavelength Zone | inside a telco's 5G network | AWS + carrier | ~10 ms to mobile device | parent Region |
| Outpost | **your** building | AWS (remotely) | LAN-local | parent Region |

4. Reason about the failure mode that distinguishes Outposts. Answer before reading the answers section: with the uplink severed, which of the following still work on an Outpost — running EC2 instances, launching a *new* EC2 instance, reading a local EBS volume, the AWS Console view of the Outpost, CloudWatch alarms?

**Check your understanding**

- **Q11.1** — A hospital must keep patient imaging on-premises for legal reasons but wants the AWS API surface. Which model, and what exactly does "the control plane stays in the Region" cost them during a WAN outage?
- **Q11.2** — A live-video company needs sub-10 ms encoding for viewers in Los Angeles. Local Zone or Wavelength Zone? What single fact about the *end users* decides it?
- **Q11.3** — Explain why none of these four models is a disaster-recovery strategy for the parent Region.
- **Q11.4** — What is a Dedicated Local Zone, and which requirement does it satisfy that a standard Local Zone does not?
- **Q11.5** — All four models keep the control plane in the parent Region. State the single design principle this reveals about how AWS extends its infrastructure.

---

## Consolidated mental model

| Construct | Count (order of magnitude) | Isolation boundary? | You deploy into it? | Fails independently of… |
|---|---|---|---|---|
| Partition | 3 public | **strongest** — separate IAM, separate accounts, separate ARNs | yes, with separate credentials | everything in other partitions |
| Region | tens | **yes** — the primary fault boundary | yes | other Regions |
| Availability Zone | 3–6 per Region | **yes** — power, cooling, network, flooding | yes | other AZs in the Region |
| Local Zone / Wavelength Zone | tens–hundreds | no — extension of parent Region | yes | not from the parent Region |
| Outpost | per customer | no — extension of parent Region | yes | not from the parent Region |
| Edge location / PoP | hundreds | no — stateless, cache only | **no** | individually irrelevant |
| Regional edge cache | ~a dozen | no | **no** | individually irrelevant |

Three sentences worth carrying into the exam and into a design review:

1. **A Region is the unit of data residency and the unit of disaster recovery; an AZ is the unit of high availability.** Confusing these produces architectures that are highly available against a failure that will not happen and defenceless against the one that will.
2. **Everything that says "global" has a home Region.** Find it before you write the runbook.
3. **Never memorise the numbers.** `describe-regions`, `describe-availability-zones`, the `/aws/service/global-infrastructure/` parameter tree and `ip-ranges.json` are the source of truth, they are free, and they are current.

---

## Sources

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Amazon EC2 User Guide, *Regions and Zones* — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- AWS RAM User Guide, *Availability Zone IDs* — https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
- Systems Manager, *Public parameters — global infrastructure* — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- AWS Account Management, *Enabling and disabling Regions* — https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html
- *AWS IP address ranges* — https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html
- Amazon CloudFront, *How CloudFront delivers content* (edge locations and regional edge caches) — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/HowCloudFrontWorks.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 Developer Guide — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
- AWS General Reference, *Service endpoints and quotas* — https://docs.aws.amazon.com/general/latest/gr/rande.html
- AWS General Reference, *ARNs and namespaces* — https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html
- AWS Local Zones User Guide — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength Developer Guide — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Outposts User Guide — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- Whitepaper, *AWS Fault Isolation Boundaries* — https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/abstract-and-introduction.html
- API Reference, `DescribeInstanceTypeOfferings` — https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstanceTypeOfferings.html
- AWS Price List API, `GetProducts` — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html

---

<details>
<summary><strong>Answers</strong> — open only after completing the exercises</summary>

### Exercise 0

**A0.1** — The other two publicly available partitions are `aws-cn` (China: `cn-north-1` Beijing, operated by Sinnet, and `cn-northwest-1` Ningxia, operated by NWCD) and `aws-us-gov` (`us-gov-west-1`, `us-gov-east-1`). There are also non-public partitions for US intelligence customers (`aws-iso`, `aws-iso-b`) that ordinary accounts cannot reach.

The operational consequence: a partition is a completely separate copy of AWS. Separate account root, separate IAM principals, separate credentials, separate service endpoints (`amazonaws.com.cn` instead of `amazonaws.com`), separate console URL, and no cross-partition IAM trust. You cannot assume a role across partitions, you cannot replicate an S3 bucket across partitions with S3 Replication, and an ARN from one partition is meaningless in another. In practice a China deployment is a second company's worth of operational work, and it additionally requires a Chinese entity and an ICP licence. This is why partition is the *first* field of every ARN — it is the outermost boundary.

**A0.2** — It is effectively true only when the environment has a Region configured somewhere in the precedence chain and that Region happens to be `us-east-1` — most commonly because `~/.aws/config` was written by `aws configure` with the default accepted, or because a legacy tool set `AWS_DEFAULT_REGION=us-east-1`.

It is still the wrong model because with *nothing* set, the CLI fails with `You must specify a region`, and SDKs raise a configuration error rather than silently choosing. The mental model matters because the "silently defaults to N. Virginia" belief is exactly how resources get created in the wrong Region — and in a data-residency context, a resource in the wrong Region is a compliance incident, not a typo. Always pin the Region explicitly in automation.

### Exercise 1

**A1.1** — `describe-regions` returns the Regions **enabled for your account**; `--all-regions` returns every Region in your partition regardless of enablement. AWS builds Regions; your account must consent to the ones introduced after the opt-in policy began (roughly, Regions launched from 2019 onward), because enabling a Region has billing, governance and legal implications the account owner should choose deliberately.

The two Regions that are structurally always enabled in the commercial partition are `us-east-1` (it hosts the global control planes — IAM, Route 53, CloudFront, Organizations, billing) and `us-west-2` (the second Region AWS treats as always-on for service dependencies). More generally, every Region that existed before the opt-in mechanism is `opt-in-not-required`.

**A1.2** — The `opt-in-not-required` Regions are the older ones — the set AWS had launched before it introduced per-Region enablement. AWS changed the default because a Region silently available to every account is a governance hole: an engineer could create resources in a jurisdiction the company never approved, spend would appear in a Region nobody monitors, and security tooling (GuardDuty, CloudTrail, Config) is configured per-Region and would not be watching. Making new Regions opt-out-by-default inverts that: a Region is dark until someone decides otherwise, which is the correct default for both cost and compliance.

**A1.3** — The ordinal tells you the **launch order within that geographic grouping** and nothing else. `ap-northeast-1` (Tokyo) launched before `ap-northeast-3` (Osaka); that is the entire content of the number. It does not encode capacity, AZ count, service coverage, price, or preference. Osaka in fact began life as a restricted "Local Region" with limited access and became a standard Region later — the code never changed to reflect that. Related trap: `us-east-1` and `us-east-2` are both "US East" but are separate Regions with independent failure domains; the shared prefix means geography, not correlation of availability.

**A1.4** — The two mechanisms:

1. **Region opt-out** (`aws account disable-region` / the Account settings page). Disable every Region outside the EU. This is the one from the exercise.
2. **An SCP in AWS Organizations** using the `aws:RequestedRegion` condition key to `Deny` all actions when the requested Region is not in an allow-list.

The SCP is the actual control: it is centrally administered, cannot be removed by a member-account administrator, applies to every principal in every account under the OU, and can carve out the global services (IAM, Route 53, CloudFront, Organizations, Support) that must still be callable via `us-east-1`. Region disablement is a convenience and a good defence-in-depth layer, but it is an account-level setting that a sufficiently privileged principal in that account can reverse, and it cannot express exceptions. Use both; rely on the SCP.

**A1.5** — `cn-north-1` is in the `aws-cn` partition, and every AWS API call is scoped to the partition of the credentials making it. Your `arn:aws:` credentials cannot enumerate, describe, or reach anything in `aws-cn`. To see it you would need a separate AWS (China) account, obtained through Sinnet or NWCD, with a Chinese business entity and an ICP filing — and separate access keys, a separate console at `amazonaws.cn`, and separate tooling configuration.

### Exercise 2

**A2.1** — Almost certainly **no**. `ZoneName` (`us-east-1a`) is mapped to a physical zone **independently for each AWS account**; `ZoneId` (`use1-az2`) is the stable, account-independent identifier of the physical zone. Two accounts are in the same physical zone only if their `ZoneId` values match. In the sample output, `us-east-1a` was `use1-az2` — an account where `us-east-1a` maps to `use1-az1` would be in a different building despite the identical name.

**A2.2** — Before the randomisation, every account's `us-east-1a` was the *same* physical zone, and human beings pick the first item in a list. The result was that "a" zones were systematically oversubscribed and "e"/"f" zones underused across the entire customer base, which is bad for AWS's capacity planning and bad for customers who all crowded into the same failure domain. Randomising the mapping per account distributes load evenly by construction and removes the illusion that `-1a` is somehow the primary or preferred zone. It is worth noticing that the fix was to make the *name* meaningless rather than to educate users — a good example of designing around human behaviour instead of against it.

**A2.3** — The **AZ ID** (`use1-az2`) goes in the ticket. The AZ name is useless across an account boundary, because it means something different on each side. This is not a corner case: it is precisely why the `ZoneId` field exists, and why `create-subnet` accepts `--availability-zone-id`. When you share a subnet via AWS RAM, the consumer account sees the subnet's own AZ name rendered in *their* mapping, so coordinating on names produces silent cross-AZ traffic — you pay for the data transfer and you get the latency, and nothing errors to tell you.

**A2.4** — No. All you learned is that **your account is currently offered two AZs in `us-west-1`**. AWS does not guarantee that every account sees every AZ in a Region; older, capacity-constrained Regions in particular are exposed selectively. The safe phrasing is: *"as of this call, this account can use N AZs in this Region."* The design rule that follows is more important than the count: never hard-code an AZ count, always derive it, and treat "at least three" as a property to verify per Region rather than assume. AWS's own stated design principle is that Regions launched since ~2018 have at least three AZs.

**A2.5** — AWS is responsible for the AZs *existing and being genuinely independent* — separate power feeds, separate cooling, separate network paths, physically separate facilities, and low-latency private links between them. That is "of the cloud."

**You** are responsible for using more than one. Choosing Multi-AZ RDS, spreading an Auto Scaling group across three subnets in three AZs, putting an ALB in multiple AZs — those are customer decisions. AWS will happily let you build a single-AZ architecture and will not make it survive an AZ loss. This is the cleanest illustration of the shared responsibility model in the whole infrastructure domain: AWS provides the fault isolation, you choose whether to consume it.

**A2.6** — Because of the distance. AZs in a Region are within ~100 km of each other, so the round-trip is on the order of 1 ms (single-digit ms worst case). A synchronous write that waits for a second copy therefore costs ~1 ms extra — acceptable for a database commit.

Regions are typically thousands of kilometres apart. `us-east-1` to `eu-west-1` is ~5,800 km great-circle, so the *floor* on round-trip is about 58 ms and the real figure is 70–80 ms. A synchronous commit paying 80 ms caps you at roughly 12 sequential writes per second per transaction chain — commercially useless. Hence: **synchronous within a Region (Multi-AZ), asynchronous across Regions (read replicas, Aurora Global Database, S3 CRR)** — and asynchronous means a non-zero RPO, which is a business decision to be made explicitly.

### Exercise 3

**A3.1** — `ParentZoneName` means the Local Zone is not an independent Region but a satellite of one. Architecturally: the VPC is the *parent Region's* VPC, extended by a subnet in the Local Zone. The **control plane is entirely in the parent Region** — the EC2 API you call is `ec2.us-west-2.amazonaws.com`, IAM authorisation happens as normal, CloudWatch metrics land in `us-west-2`, and the vast majority of AWS services (S3, DynamoDB, RDS beyond the supported set, Lambda, most managed services) exist only in the parent Region. What runs in the Local Zone is a deliberately small subset — EC2, EBS, ALB, and a few others — for the latency-sensitive tier. Your data-plane traffic from the Local Zone to any unsupported service traverses the link back to the parent Region, so the design pattern is: latency-critical front-end in the Local Zone, everything else in the Region.

**A3.2** — Closest to furthest:

1. **Outpost** — physically in your own building. Justified by data that legally or contractually cannot leave your premises, or by a workload with a hard LAN-latency requirement to on-premises equipment (factory floor control, hospital imaging modality, trading co-location).
2. **Wavelength Zone** — inside a mobile carrier's network, so traffic from a 5G device never leaves the carrier to reach you. Justified by mobile-device workloads needing ~10 ms: AR/VR on phones, connected-vehicle telemetry, real-time mobile video analytics.
3. **Local Zone** — an AWS facility inside a large metro that has no Region. Justified by latency-sensitive applications for users in that metro: real-time gaming, live video production, remote desktop/VDI, media rendering.
4. **Availability Zone** — an AWS data centre inside the Region. Justified by everything else, which is the overwhelming majority of workloads.

The discipline is to start at (4) and only move outward when a measured requirement forces it, because each step outward costs service availability, operational complexity and money.

**A3.3** — `NetworkBorderGroup` is the **boundary within which a public IP address is advertised to the internet**. AWS announces a given prefix from one specific set of locations; an address in the `us-west-2-lax-1` border group is announced from Los Angeles, and an address in the `us-west-2` border group is announced from Oregon.

You cannot move an Elastic IP between border groups because the address literally belongs to a prefix that is BGP-announced from a different place. Moving it would mean withdrawing and re-announcing a route, which is not an account-level operation. The practical consequence: when you allocate an EIP for a Local Zone instance you must pass `--network-border-group us-west-2-lax-1`, and an EIP you already hold in the parent Region cannot be attached to a Local Zone instance. Getting this wrong produces a confusing `InvalidParameterCombination` at exactly the wrong moment during a deployment.

**A3.4** — With the uplink severed:

- **EC2 data plane (already-running instances)** — keeps running. Instances continue executing, serving local traffic, and talking to each other over the local network.
- **EC2 control plane (launching a *new* instance)** — **fails**. The control plane is in the parent Region; with no path to it you cannot launch, stop, terminate or modify instances. This is the single most important fact about Outposts.
- **EBS volumes attached to Outpost instances** — keep working for reads and writes; the storage is local to the Outpost. You cannot create, snapshot or modify volumes, because that is control-plane work.
- **CloudWatch metrics** — stop arriving in the Region. Metrics are buffered locally for a limited window and delivered when connectivity returns; alarms depending on them go to `INSUFFICIENT_DATA`.
- **Console view of the Outpost** — shows the last known state, and mutating actions fail.

The design implication: an Outpost is not an autonomous cloud. Anything that must survive a WAN partition has to already be running and must not depend on scaling, on the Region's managed services, or on Region-side authentication for its data path.

**A3.5** — A Local Zone is an *extension of* its parent Region, sharing that Region's control plane — so a parent-Region control-plane failure takes the Local Zone with it, which means it is not an independent fault domain and therefore not a DR target. (For DR you need another **Region**.)

### Exercise 4

**A4.1** — New services launch in a small number of Regions and expand over months to years, driven by demand, capacity, hardware dependency and local regulation. `us-east-1` (N. Virginia) is almost always in the first wave, frequently alone or paired with `us-west-2`; it is the largest Region and the default target for new-service launches. The corollary is that **service coverage is Region-specific and is a first-class input to Region selection** — a Region that is cheaper and closer is worthless if it lacks a service your architecture requires. The gap widens for anything hardware-dependent (accelerated compute, specialised instance families) and for anything new.

**A4.2** —

```bash
for s in ec2 lambda rds dynamodb sqs cloudfront; do
  n=$(aws ssm get-parameters-by-path --region us-east-1 \
        --path /aws/service/global-infrastructure/regions/il-central-1/services \
        --query "length(Parameters[?Value=='$s'])" --output text)
  printf '%-14s %s\n' "$s" "$([ "$n" = 1 ] && echo present || echo MISSING)"
done
```

Two caveats worth stating in the design review: service *presence* does not imply feature parity (a service can exist in a Region without its newest features, instance classes or engine versions), and it does not imply quota parity (default service quotas are lower in smaller Regions and take time to raise). Check the specific feature and file quota increases early.

**A4.3** — No, it is necessary but not sufficient. `geolocationCountry=BR` tells you where the Region's infrastructure physically sits; it says nothing about what *you* do with the data. To actually satisfy residency you must additionally ensure: no cross-Region replication or backup to another Region; no CloudWatch/CloudTrail/Config aggregation into an out-of-country Region; no cross-Region service dependency in the data path; and appropriate handling of anything you deliberately export.

Resources that would still sit outside Brazil regardless: **IAM** (global, control plane in `us-east-1`) — user names, role names, policy documents; **Route 53** hosted zones and record data; **CloudFront** distribution configuration and, more importantly, **cached objects at edge locations worldwide** — which is a genuine residency problem if you put regulated content behind CloudFront without geo-restriction; **AWS Organizations** and consolidated billing data; and **support case content** you type into a ticket. Metadata like resource names and tags is frequently overlooked and is often in scope for a regulator.

**A4.4** — Because the version is what makes the count a *citable fact* rather than a recollection. "AWS has N Regions" is false within a quarter; "AWS published N Regions in global-infrastructure dataset `1.0.0-20260901`" stays true forever. In a design document, an audit artefact, or study material, the timestamped version turns a decaying claim into a reproducible one — anyone can re-run the query, get a different number, and see exactly why it differs.

### Exercise 5

**A5.1** — Two structural reasons, both expected:

1. **Fibre does not go straight.** Terrestrial routes follow rights of way — railways, highways, existing conduit — and submarine cables follow surveyed seabed paths around continental shelves and trenches. A 1.3–2× multiplier over great-circle distance is normal.
2. **Routing is commercial, not geometric.** Your ISP hands traffic to AWS at a peering point, and the nearest peering point may be a long way from the shortest path — Latin American traffic historically transits Miami even between two South American endpoints. Add per-hop serialisation, queueing and switching delay at every router.

Neither is a fault. The lesson is that you must **measure** RTT rather than compute it from a map.

**A5.2** — Because latency is paid **per round trip**, and a real request is a chain of dependent round trips: DNS, TCP handshake (1 RTT), TLS handshake (1–2 RTT), the HTTP request itself, then a sequence of dependent back-end calls — an auth check, a session lookup, three database queries where each depends on the previous. Ten to twenty round trips is unremarkable. Multiply an 90 ms RTT delta by 12 and you have added roughly a full second before any work happens.

The mitigation that does not require moving the Region is **reducing the number of round trips**: batch dependent queries, parallelise independent ones, cache at the edge with CloudFront, terminate TLS at the edge (Global Accelerator or CloudFront) so the expensive handshake happens near the user and the long haul runs over an already-established connection on the AWS backbone, use HTTP/2 or HTTP/3 with connection reuse, and enable TLS 1.3 to save a handshake round trip. Chattiness, not distance, is usually the bigger lever.

**A5.3** —

- **First-byte latency for a dynamic API call** — improved. This is round-trip-bound and is the classic case for Region proximity.
- **Download time for a 2 GB static file** — barely improved by Region choice, and this is the counter-intuitive one. Bulk transfer is throughput-bound, not latency-bound. The correct fix is CloudFront, which serves the object from an edge location metres away in network terms regardless of which Region the origin sits in. (Latency does affect TCP ramp-up, so it is not literally zero, but choosing a Region is the wrong lever.)
- **Database write latency** — improved *if* the client is near the database. Note this is a different question from replica lag, which is bounded by the distance between Regions, not by your distance to either.
- **TLS handshake cost** — improved, and disproportionately: TLS 1.2 costs two additional round trips on top of TCP's one, so a 90 ms RTT delta becomes ~270 ms on connection setup alone.

**A5.4** — Physics forces you to decide **where the single consistency point lives**, because you cannot have synchronous consistency and low write latency for users on three continents simultaneously. The two legitimate answers:

1. **One writer Region, read replicas everywhere.** Pick the Region nearest the largest or most latency-sensitive user population, accept that users elsewhere pay the long RTT on writes, and serve reads locally (Aurora Global Database, DynamoDB Global Tables in single-writer mode, RDS cross-Region read replicas). Writes are slow for two of the three populations; reads are fast for all. This is the right answer for most systems.
2. **Partition the data by region of ownership.** A São Paulo customer's records live and are written in `sa-east-1`; a Frankfurt customer's in `eu-central-1`. Every user gets fast local writes; the cost is that cross-partition queries are hard and global aggregate views must be built asynchronously. This is the right answer when the data model genuinely partitions by user — and it has the pleasant side effect of solving data residency at the same time.

The answer that is **not** legitimate is multi-Region synchronous multi-writer with strong consistency. Anyone offering it is hiding a conflict-resolution policy, an eventual-consistency window, or both.

### Exercise 6

**A6.1** — On a cache miss the bytes travel through all three tiers:

1. The user's request resolves via DNS to the **edge location (PoP)** nearest them in network terms — `GRU1-C1`, São Paulo. TCP and TLS terminate here.
2. The PoP does not have the object, so it asks its **regional edge cache** — a larger, fewer-in-number mid-tier cache. Still a miss.
3. The regional edge cache fetches from the **origin** — the S3 bucket in its Region — travelling over the **AWS backbone**, not the public internet.
4. The object flows back down, being stored at the regional edge cache and at the PoP on the way, and is delivered to the user.

Every subsequent user in São Paulo gets a hit at step 1. The three tiers are: edge location, regional edge cache, Region.

**A6.2** — The **edge location (PoP)** served it. On a miss, CloudFront would have consulted the **regional edge cache** before going to the origin.

Regional edge caches exist because there are hundreds of PoPs, each with limited storage, each independently evicting. Without a mid-tier, a moderately popular object gets evicted from every PoP and every miss becomes an origin fetch — so the origin sees hundreds of requests for the same object and long-tail content is never effectively cached anywhere. The regional edge cache is bigger and sits behind many PoPs, so it absorbs those misses: origin load drops sharply and long-tail hit rates improve. Note that regional edge caches are bypassed for dynamic content (`PUT`/`POST`/`PATCH`/`DELETE`), for proxy methods, and for content configured with Origin Shield, which is a related but distinct feature you enable explicitly.

**A6.3** — Two decisive differences:

1. **Protocol.** CloudFront is an HTTP/HTTPS CDN — it understands requests, caches responses, and does nothing for other protocols. Global Accelerator operates at the network/transport layer and forwards **TCP and UDP on any port**, with no caching and no protocol awareness. A UDP game server cannot use CloudFront at all.
2. **Addressing.** Global Accelerator gives you **two static anycast IP addresses** that never change and can be allowlisted in a firewall or hard-coded in a client. CloudFront gives you a DNS name whose addresses change constantly. For a static website, the static-IP property is worthless and the caching is the entire value; for a game client or an IoT fleet that cannot do DNS reliably, static IPs are the point.

Third difference worth knowing: Global Accelerator does fast failover between regional endpoints on health-check failure and can weight traffic across Regions, so it doubles as a multi-Region traffic manager with sub-minute failover — much faster than DNS-based failover, which is bounded by TTL and resolver behaviour.

**A6.4** — `CLOUDFRONT` is the full set of prefixes CloudFront uses, including those that only ever face **users**. `CLOUDFRONT_ORIGIN_FACING` is the subset from which CloudFront actually initiates connections **to your origin**. Only the latter belongs in your origin's security group: allowing the full set needlessly widens the ingress, and allowing neither means you have exposed your origin to the whole internet, letting attackers bypass CloudFront (and therefore bypass your WAF, your caching and your Shield protection).

The better answer in practice is not to parse the JSON at all but to reference the AWS-managed prefix list `com.amazonaws.global.cloudfront.origin-facing` directly in the security group rule — AWS maintains it, it updates automatically, and it does not consume rule entries the way an expanded CIDR list does.

**A6.5** — Because they are fundamentally different objects. A Region is a cluster of multiple large data centres with independent power substations, independent cooling, redundant long-haul fibre, and stateful, durable customer data — a multi-year, capital-intensive construction project subject to local regulation, power availability and land acquisition. An edge location is a cache: a rack or small cage in an existing colocation facility, stateless, holding no durable customer data, and losable without consequence beyond a cache miss. You can put one in a carrier hotel in any large city in weeks. Statelessness is what makes the scale possible.

**A6.6** — What *can* run at the edge: caching and content delivery (CloudFront), DNS resolution (Route 53), TLS termination, DDoS absorption and WAF inspection (Shield, AWS WAF), anycast ingress onto the backbone (Global Accelerator), and **small, short-lived, stateless compute** — CloudFront Functions (sub-millisecond, JavaScript, header and URL manipulation only) and Lambda@Edge (larger, runs at regional edge caches rather than PoPs, still constrained).

What cannot: your application. There are no EC2 instances, no containers, no databases, no persistent storage and no VPC at an edge location. You cannot deploy a service there. The correct rephrasing of the colleague's proposal is: *"use CloudFront to serve cacheable content from the edge and to terminate connections near users, and consider a Local Zone if we need actual compute closer to a specific metro."*

### Exercise 7

**A7.1** — No, the bucket is not global. `LocationConstraint` is `null` for `us-east-1` for a purely **historical** reason: `us-east-1` was the original and for a time the only S3 Region, and the `LocationConstraint` element was added later to name the others. The empty/`null` value was left to mean "the original Region" so that existing clients kept working. You will also encounter the legacy value `EU`, which means `eu-west-1` and predates the modern Region codes.

The bucket's data is stored in `us-east-1`, replicated across AZs within that Region, and does not leave it unless you configure replication. The null is a compatibility artefact, not a statement about scope — and it is a real source of bugs in code that does `if location is None: raise`.

**A7.2** — IAM's control plane is in `us-east-1`; the signing scope proves the call went there regardless of the `--region` flag.

- **IAM writes worldwide** — a `us-east-1` control-plane event blocks them everywhere. You cannot create a role, attach a policy, rotate an access key or create a user in any Region while IAM's control plane is impaired, because there is only one.
- **IAM authorisation decisions worldwide** — largely unaffected. IAM's *data plane* — the evaluation of policies when a request arrives — is replicated into every Region and is designed for extremely high availability and static stability. Your running application keeps authenticating and authorising during an IAM control-plane event.

This distinction, control plane versus data plane, is the single most useful lens for reasoning about AWS blast radius. The design rule that follows: **do not make your recovery path depend on a control plane.** A runbook whose first step is "create an IAM role" fails exactly when you need it. Pre-provision the roles, pre-provision the capacity, and keep failover to data-plane operations — this is what AWS calls static stability.

**A7.3** — Both reasons are real:

1. **Latency.** The global endpoint `sts.amazonaws.com` resolves to `us-east-1`. An application in `ap-southeast-1` calling it pays a ~200 ms round trip to fetch credentials — on every credential refresh, and on the cold path of every Lambda invocation that assumes a role. The regional endpoint is a few milliseconds away.
2. **Failure isolation.** Calling a `us-east-1` endpoint from a workload in `ap-southeast-1` creates a hard dependency on a Region your workload otherwise has nothing to do with. A `us-east-1` event then takes down an application running 15,000 km away, for no architectural reason. Regional STS endpoints keep the dependency graph inside the Region.

There is a third, quieter reason: regional endpoints scale independently, so you are not sharing a throttling ceiling with the entire world.

**A7.4** —

| Resource | Scope | Boundary that makes it so |
|---|---|---|
| Route 53 hosted zones | **Global** | DNS is inherently global; served by anycast name servers worldwide, control plane in `us-east-1` |
| Route 53 Resolver endpoints | **Regional** | They are ENIs in a VPC subnet — they have IP addresses in a specific AZ |
| CloudFront distributions | **Global** | Config replicated to every PoP; control plane and ARNs anchored in `us-east-1` |
| S3 bucket names | **Global** (per partition) | The name is part of a DNS hostname, and DNS names must be unique |
| S3 objects | **Regional** | Bytes live in one Region, replicated across its AZs |
| IAM users, roles, policies | **Global** | One identity store per account, control plane in `us-east-1` |
| EC2 key pairs | **Regional** | Stored per-Region; the same key material imported into two Regions is two independent resources |
| ACM certificates | **Regional**, with a special case | Bound to the Region where issued; a cert for CloudFront **must** be in `us-east-1` |

**A7.5** — Because CloudFront's control plane lives in `us-east-1`, and CloudFront needs to read the certificate to distribute it to every edge location worldwide. The requirement is a direct, visible leak of where CloudFront is anchored — the same reason CloudFront ARNs carry an empty region field but are managed through `us-east-1`, the same reason CloudFront's CloudWatch metrics appear in `us-east-1`, and the same reason WAF Web ACLs scoped to CloudFront must be created with `--scope CLOUDFRONT --region us-east-1`.

The practical consequence for a team otherwise entirely in `eu-central-1`: you still need an `us-east-1` footprint, `us-east-1` must be enabled, and your IaC needs a second provider alias. Plan for it rather than discovering it during a deploy.

**A7.6** — Because an S3 bucket name is **part of a DNS hostname**: `my-bucket.s3.us-east-1.amazonaws.com`. DNS names must be globally unique, so the bucket namespace must be globally unique — across every account and every Region in the partition. This is why bucket names are effectively first-come-first-served and why the good short ones were gone a decade ago, and it is why bucket names must be DNS-compliant (lowercase, no underscores, 3–63 characters).

An EC2 `Name` tag is not addressable by URL. It is an arbitrary key-value pair on a resource that is actually identified by an opaque, AWS-generated `i-0abc...` ID, unique only within a Region. Nobody resolves it, so nobody needs it to be unique. General rule: **anything that appears in a hostname needs a global namespace; anything identified by an opaque ID does not.**

### Exercise 8

**A8.1** — The scale-out attempt into that AZ fails with `Unsupported` (or `InsufficientInstanceCapacity`, depending on the exact cause). The Auto Scaling group retries, may enter a backoff, and — critically — your effective capacity ceiling is lower than you designed for while your monitoring shows an ASG that "exists in three AZs."

The fixes, in order of preference: (a) select AZs by intersecting the offering sets for every instance type you intend to use; (b) use a **mixed instances policy** with several compatible types so the ASG can substitute; (c) use an **Attribute-Based Instance Type Selection** policy, which expresses requirements as vCPU/memory/architecture and lets EC2 pick whatever is available. Option (c) is the modern answer and is markedly more robust to exactly this class of failure.

**A8.2** — Because `availability-zone` returns names (`us-east-1a`), which are mapped per account and therefore not comparable to anything outside your account and not stable as documentation. `availability-zone-id` returns `use1-az2`, which identifies the physical zone unambiguously. If you are recording "c7g is offered in these zones" in a design document, a wiki page, or a Terraform variable shared across accounts, the name is actively misleading — a second account reading `us-east-1a` will resolve it to a different physical zone. Every artefact that crosses an account boundary must use AZ IDs.

**A8.3** — It does not predict **capacity at launch time**. "Offered" means the hardware family is deployed in that zone and the API will accept the request; it says nothing about whether a free instance slot exists at 09:00 on the Monday of your product launch. `InsufficientInstanceCapacity` is a real, ordinary error against a perfectly valid offering.

The two features that guarantee capacity are **On-Demand Capacity Reservations** (reserve capacity for a specific instance type in a specific AZ, billed whether or not you use it) and **Capacity Blocks for ML** (reserve accelerated-compute capacity for a defined future window). Note that a *Reserved Instance* or *Savings Plan* is a **billing** construct, not a capacity guarantee — the exception being a zonal RI, which does carry a capacity reservation. That distinction is exam-relevant and frequently misunderstood in production too.

**A8.4** — Same principle as A4.1: **Regions are not uniform, and the larger, older Regions get more of everything first.** `us-east-1` receives new instance families, new services and new features earliest and in the greatest variety; smaller Regions get a subset, later. The design consequence is that "it works in `us-east-1`" is not evidence that it works anywhere else — instance type availability, service availability, feature availability and default quotas must each be verified per Region before you commit to a deployment target.

### Exercise 9

**A9.1** — In every AWS subnet, five addresses are reserved and unusable, for a `10.42.1.0/24`:

- `10.42.1.0` — the network address.
- `10.42.1.1` — the VPC router (implicit router / default gateway).
- `10.42.1.2` — the **Amazon-provided DNS server**. It is always the VPC CIDR base + 2, and it is also reachable at the link-local `169.254.169.253`. This is the address the Route 53 Resolver answers on.
- `10.42.1.3` — reserved by AWS for future use.
- `10.42.1.255` — the broadcast address. AWS does not support broadcast in a VPC, but the address is reserved anyway.

256 − 5 = 251. This matters at the small end: a `/28` (the smallest AWS permits) has 16 addresses and yields only 11 usable, which is a genuine constraint when a service like an ALB or a NAT gateway also consumes addresses in the subnet.

**A9.2** —

- **Subnet:** a subnet lives in exactly one AZ. Lose the AZ and every resource in that subnet is gone — instances unreachable, ENIs dead, anything single-homed there is down.
- **VPC:** a VPC spans every AZ in its Region and is unaffected as a construct. It survives the loss of one AZ entirely; it is a Region-scoped logical object, not a thing that runs in a data centre.
- **Route tables:** Region-scoped, replicated, and unaffected. Routes pointing *into* the failed AZ become black holes for traffic destined there — most visibly a private subnet routing through a NAT gateway in the failed AZ, which loses egress even though the subnet itself is healthy. That is exactly why the NAT-per-AZ rule exists.

Summary: **the AZ is the failure domain; the VPC is the Region-wide container that survives it.** Availability comes from having resources in more than one subnet in more than one AZ, plus a load balancer or DNS layer that stops sending traffic to the dead one.

**A9.3** — It fails silently and asymmetrically. Because `us-east-1a` maps to a different physical zone in each account, the two deployments land on different hardware. Symptoms: a workload split across two accounts (say, a shared-services VPC and a workload VPC connected by RAM or peering) that believes it is co-located but is actually crossing AZs — you pay cross-AZ data transfer in both directions, you add ~1 ms to every hop, and neither the console nor any error message tells you. Worse, an AZ impairment affects the two accounts differently, so your "identical" environments do not fail identically, and your DR test in one account proves nothing about the other.

The rewritten rule: **select zones by `ZoneId`, derived at deploy time from `describe-availability-zones` and sorted deterministically — never hard-code `ZoneName`.**

**A9.4** — With a single NAT Gateway in AZ-1 serving all three private subnets, the loss of AZ-1 removes outbound internet access for all three AZs, including the two that are perfectly healthy. Your surviving instances can no longer reach S3 over the internet path, pull container images, call external APIs, or fetch OS updates — a single-AZ failure has become a Region-wide outage of your egress path. This is the single most common way a "multi-AZ" architecture turns out not to be.

The two costs of doing it correctly (one NAT Gateway per AZ, each private subnet routing to the one in its own AZ):

1. **The NAT Gateway hourly charge, multiplied by three** — you pay per gateway-hour for each.
2. **The per-GB data processing charge**, which you pay on top of the hourly rate for every gigabyte through each gateway.

There is also a cost to doing it *incorrectly* that is easy to miss: routing AZ-2's traffic to a NAT Gateway in AZ-1 incurs cross-AZ data transfer charges on top of the NAT processing charge, so the single-gateway "saving" is partly illusory even before the availability problem. A VPC gateway endpoint for S3 and DynamoDB is free and removes a large share of NAT traffic entirely — usually the first optimisation to make.

**A9.5** — You have three subnets in three distinct failure domains and **zero availability**, because you have nothing running. The three-AZ footprint is a **precondition** for high availability, not high availability itself.

What it gives you: the address space and placement structure to distribute resources across independent failure domains, and the ability to do so without redesigning the network later.

What it does not give you: any running capacity; any load balancer distributing traffic; any health checking; any automatic replacement of failed instances; any data replication; any capacity headroom to absorb the load of a lost AZ (the "N+1" question — if each of three AZs runs at 50% and you lose one, the remaining two need to absorb 150% of their current load, which they cannot). Real HA requires the footprint **plus** redundant running capacity, **plus** an ALB or Route 53 health-checking layer that stops sending traffic to the failed zone, **plus** enough spare capacity in the survivors — and ideally static stability, meaning the survivors are already provisioned rather than needing a control-plane call to scale up at the worst possible moment.

### Exercise 10

**A10.1** — Because a **gate** is a binary pass/fail that is evaluated *before* scoring, and any candidate that fails a gate is removed from the comparison entirely. `us-east-1` fails the data-residency gate, so its price and instance breadth are never weighed — you cannot buy your way out of a regulatory requirement with a 59% discount, and the fintech's regulator will not accept "it was cheaper" as a mitigation.

This is the general shape of Region selection: **compliance and data residency are gates; latency, cost and service breadth are scores.** Service availability is usually a gate too, though sometimes a soft one (you can substitute a service or self-host it, at a cost that becomes a score). Running the gates first also saves work, because it usually reduces the candidate list to one or two.

**A10.2** — Two structural drivers:

1. **Local input costs.** Electricity is the dominant operating cost of a data centre, and industrial power prices vary by a factor of three or more between, say, Virginia and São Paulo. Add land, construction, cooling requirements driven by climate, labour, long-haul network transit — which is far more expensive in South America and Australia than in Northern Virginia — and taxes and import duties on hardware, which are substantial in Brazil in particular.
2. **Scale and utilisation.** `us-east-1` is by a wide margin the largest Region. Enormous scale means better hardware purchasing, higher fleet utilisation, and fixed costs amortised over vastly more customers. A small Region carries the same baseline of redundant power, staff and network over a fraction of the revenue.

Practical consequences: always price in the target Region rather than assuming, and remember that data transfer pricing varies by Region too — cross-Region egress from `sa-east-1` is markedly more expensive than from `us-east-1`, which can dominate the bill for a data-heavy workload.

**A10.3** — **Latency drops in weight** — a DR Region is not serving users during normal operation, so a few tens of milliseconds is irrelevant — while **compliance stays an absolute gate** and **service availability rises**, because the DR Region must support every service the primary uses or the failover does not work.

The shortlist problem is that Brazil has one AWS Region. So either:

- **Stay in `sa-east-1` and rely on multi-AZ.** `sa-east-1` has three AZs, which are genuinely independent failure domains (separate power, cooling, network, flooding). This protects against every failure short of a whole-Region event. It satisfies residency perfectly. It is what most Brazilian regulated workloads actually do.
- **Add a second Region and get legal sign-off first.** If the regulator permits encrypted backups outside Brazil under specified conditions, a second Region gives true Region-level DR. Candidates would be evaluated by `geolocationCountry` against whatever the regulator allows.

The honest framing for the design review: an AZ is the isolation boundary for infrastructure failure; only a Region is the isolation boundary for a Region-wide event. If residency forbids a second Region, you must state explicitly that whole-Region loss is an accepted risk — and get that acceptance signed rather than leaving it implicit.

**A10.4** — One from each category:

- **Latency.** Users outside the eastern US pay 100–300 ms on every round trip, which compounds across a chatty request chain into seconds of added page load. For a Brazilian, European or Asian user base this is the difference between a usable product and an unusable one.
- **Compliance.** Data is in the United States, which puts it in scope for US legal process and out of compliance with GDPR data-transfer requirements, Brazilian LGPD residency expectations, and most sectoral regulations elsewhere — often without anyone having made a decision, because "the default Region" is not a decision.
- **Blast radius.** `us-east-1` hosts the global control planes for IAM, Route 53, CloudFront, Organizations and billing, and it is the largest and busiest Region. Historically, the AWS events with the widest customer impact have originated there, and workloads in `us-east-1` are affected both by the local event *and* by the global control-plane dependency. Being in `us-east-1` maximally correlates your availability with everyone else's — including your third-party SaaS dependencies, which are disproportionately there too, so your degradation arrives from several directions at once.

**A10.5** — All four can change, and each has a realistic trigger:

- **Compliance** — a new law (GDPR, LGPD, a sectoral banking rule), a new customer contract with a residency clause, or entry into a new market. This is the most common forced migration and the most expensive, because it is a gate: failing it means moving, not optimising.
- **Latency / user proximity** — your user base shifts, or AWS launches a new Region or Local Zone closer to it. A Region opening in a country where you have significant users is a real reason to re-evaluate.
- **Service availability** — a service you now depend on arrives in a Region that previously lacked it, unblocking a cheaper or closer option; or you adopt a new service that is not yet in your current Region, which is the more common and more annoying direction.
- **Cost** — AWS changes prices (typically downward, and unevenly across Regions), or your workload profile changes such that a different cost component dominates — a workload that becomes egress-heavy is affected by data-transfer pricing differences that were negligible when it was compute-heavy.

The discipline: record the four factors and their values *at decision time* in an architecture decision record, along with the dataset version from exercise 4, so a future engineer can tell whether the reasoning still holds or merely still exists.

### Exercise 11

**A11.1** — **AWS Outposts**, in the rack or server form factor depending on scale.

"The control plane stays in the Region" costs them, during a WAN outage: the inability to launch, stop, terminate or modify any instance; the inability to create, resize or snapshot EBS volumes; the loss of CloudWatch metric delivery and therefore of alarms; a console that shows stale state and rejects mutating actions; and — the one that hurts most — **no scaling**. If load rises during the outage, nothing scales out.

What keeps working: running instances, local EBS I/O, local networking on the Outpost, and any local service instance already running. The design rules that follow are the same ones you would apply to any partition-tolerant system: **pre-provision capacity for peak, not for average** (static stability); avoid designs that need a control-plane call in the critical path; keep the local data path free of Region-side dependencies; and test the partitioned mode deliberately, because it is the mode your compliance case actually depends on.

**A11.2** — **Local Zone**, and the deciding fact is **how the end users connect**. A Local Zone serves anyone in the Los Angeles metro reachable over the ordinary internet — any ISP, any device, fixed or mobile. A Wavelength Zone sits *inside a specific mobile carrier's 5G network* and delivers its latency benefit only to devices attached to that carrier's 5G radio network; a user on Wi-Fi, on a fixed line, or on a different carrier gets no benefit and may be worse off.

So: general audience in a metro → Local Zone. Devices on one carrier's 5G, where the traffic never needs to leave that carrier → Wavelength Zone. For a live-video company serving viewers generally, Wavelength would be a narrow and fragile bet on carrier attachment.

**A11.3** — Because every one of them is an **extension of a parent Region and shares that Region's control plane**. A Region-wide control-plane event impairs the Local Zone, the Wavelength Zone and the Outpost along with the Region itself — you lose the ability to launch, modify or recover resources in the extension exactly when you need to. Beyond the control plane, they are dependent on the Region for most services: the extensions run a small subset (EC2, EBS, a handful of others), so almost any real application in one of them calls back into the parent Region for S3, DynamoDB, RDS, Lambda, Secrets Manager or authentication, and those calls fail with the Region.

They are also not built for it: a Local Zone is typically a single facility with no AZ-level redundancy of its own, so it is a *less* resilient location than the Region, not a more resilient one. **The only DR target for a Region is another Region.**

**A11.4** — A **Dedicated Local Zone** is a Local Zone built for a single customer or a defined community (typically a government or a regulated industry body), placed in a location that customer specifies, with infrastructure physically and logically dedicated to them rather than shared with the general AWS customer base. It can carry additional controls: restricted physical access, personnel screening requirements, customer-defined operational procedures, and hard guarantees about what runs on the hardware.

What it satisfies that a standard Local Zone does not: requirements about **who else's workloads share the infrastructure** and **who may physically or logically access it**. A standard Local Zone is multi-tenant AWS infrastructure in a metro — the data residency is right, but a national-security or sovereign-cloud requirement may forbid shared tenancy or require locally vetted staff. A Dedicated Local Zone addresses tenancy and operational sovereignty; a standard one addresses only latency and geography. (This is a distinct concept from the AWS European Sovereign Cloud, which is a separate, independently operated Region-scale build rather than a Region extension.)

**A11.5** — **AWS extends its infrastructure by pushing the data plane outward while keeping the control plane in the Region.** The Region is the durable, redundant, multi-AZ core where state, orchestration and the API surface live; everything outside — AZ extensions, Local Zones, Wavelength Zones, Outposts, edge locations — is a projection of that core toward the user, carrying compute or cache but never the authority.

This single principle predicts almost everything in this topic: why an Outpost cannot launch instances during a WAN outage; why a Local Zone is not a DR target; why an edge location has no VPC and no database; why an ACM certificate for CloudFront must live in `us-east-1`; why an IAM call made with `--region sa-east-1` is signed for `us-east-1`. Learn the principle and you can derive the rest instead of memorising it.

</details>