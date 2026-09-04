# AWS Certified Cloud Practitioner (CLF-C02) — Dominio 2, Task Statement 2.4
## Identificar componentes y recursos de seguridad — Ejercicios guiados

> **Contexto de peso en el examen:** el Dominio 2 (Seguridad y Cumplimiento) es el 30% del examen; este task statement aporta el **7,5%** del contenido puntuado total. Esperá preguntas que te pidan *elegir el servicio correcto para una necesidad de seguridad enunciada*, y distinguir servicios que se parecen entre sí (GuardDuty vs. Inspector vs. Macie; KMS vs. CloudHSM vs. Secrets Manager; security group vs. NACL vs. WAF vs. Shield).

---

## 0. Antes de empezar

### 0.1 Qué vas a construir

Vas a levantar una VPC descartable y después recorrer el stack de seguridad de AWS capa por capa, tocando las APIs reales:

| Laboratorio | Capa | Servicios ejercitados |
|---|---|---|
| 1 | Red / VPC | Security groups, network ACLs |
| 2 | Borde y aplicación | AWS WAF, AWS Shield, AWS Firewall Manager, AWS Network Firewall |
| 3 | Detección y postura | Amazon GuardDuty, Amazon Inspector, Amazon Detective, AWS Security Hub, Amazon Macie |
| 4 | Datos y secretos | AWS KMS, AWS CloudHSM, AWS Secrets Manager, AWS Certificate Manager |
| 5 | Gobernanza y auditoría | AWS CloudTrail, AWS Config, IAM Access Analyzer, AWS Trusted Advisor, AWS Audit Manager |
| 6 | Fuentes de información y cumplimiento | AWS Artifact, Security Bulletins, Knowledge Center, AWS Marketplace, política de pen-test |

### 0.2 Advertencia de costos — leé esto

La mayoría de los pasos son gratis o cuestan fracciones de centavo, pero tres no son cero:

| Recurso | Modelo de precio | Cuánto te cuesta este laboratorio |
|---|---|---|
| Detector de GuardDuty | Prueba gratuita de 30 días por cuenta/Región, después por uso | $0 si tu cuenta nunca lo habilitó |
| Web ACL de WAF | $5,00/web ACL/mes + $1,00/regla/mes, **prorrateado por hora** | ~$0,01–0,02 por una hora |
| Clave administrada por el cliente de KMS | $1,00/clave/mes, prorrateado; **ventana mínima de eliminación de 7 días** | ~$0,25 (7 días de una clave que programaste para eliminación) |
| Secreto de Secrets Manager | $0,40/secreto/mes, prorrateado | ~$0,01, y se puede borrar de inmediato con `--force-delete-without-recovery` |
| EC2 `t3.micro` (Lab 1b opcional) | Elegible para capa gratuita, si no ~$0,0104/h | ~$0,01 |

Todo lo demás en este documento es una llamada de lectura, un `describe`, o un servicio que es gratis (hallazgos de acceso externo de IAM Access Analyzer, Event history de CloudTrail, construcciones de seguridad de VPC).

### 0.3 Verificación del entorno

```bash
aws --version
aws sts get-caller-identity
export AWS_REGION=us-east-1
export AWS_PAGER=""      # stop the CLI from opening less on every call
```

Esperado:

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

> Usá una **cuenta sandbox**, nunca una de producción. Varios pasos habilitan servicios a nivel de toda la cuenta.

### 0.4 Crear la VPC sandbox

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

## Laboratorio 1 — Los dos firewalls de la VPC: security groups y network ACLs

Esta es la distinción más evaluada de todo el 2.4. Los dos filtran tráfico; difieren en **estado (statefulness)**, **punto de asociación**, **semántica de reglas** y **orden de evaluación**.

### 1.1 Inspeccionar el security group por defecto

1. Recuperá el security group por defecto que AWS creó junto con la VPC:

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

2. Fijate en dos hechos estructurales que podés leer directamente de ese JSON:
   - El origen de la regla de entrada es **el propio security group** (`UserIdGroupPairs`), no un CIDR. Los security groups pueden referenciar otros security groups — una NACL no.
   - **No hay ningún campo `RuleAction` en ninguna parte**. Toda entrada de `IpPermissions` es implícitamente un *allow*.

3. Creá un security group hecho a medida y agregale dos reglas de entrada:

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

4. Intentá escribir una regla de *deny*. No existe tal llamada de API — confirmalo mirando lo que sí existe:

```bash
aws ec2 help | grep -iE 'security-group-(ingress|egress)'
```

```
       o authorize-security-group-egress
       o authorize-security-group-ingress
       o revoke-security-group-egress
       o revoke-security-group-ingress
```

Solo `authorize` y `revoke`. No hay ningún `deny-security-group-ingress`.

5. Confirmá que el grupo **no tiene ninguna regla de salida creada por vos**, y sin embargo permite todo el tráfico saliente:

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

**Comprobá lo que entendiste — bloque 1.1**

- **Q1.** Un colega te pide que "bloquees la IP `198.51.100.7` en el security group". ¿Por qué no podés hacerlo, y qué construcción de la VPC *sí* puede?
- **Q2.** Tus instancias web tienen que llegar a una base de datos RDS. Escribís una regla de entrada en el security group de la DB cuyo origen es `sg-...web`. Explicá qué evalúa AWS realmente en el momento del paquete: ¿es la IP de la instancia, o alguna otra cosa?
- **Q3.** El security group nuevo tiene una regla de salida que vos nunca creaste. ¿De dónde salió, y qué le pasa a esa regla en el momento en que llamás a `authorize-security-group-egress` una vez?

---

### 1.2 Inspeccionar las network ACLs

6. Mirá la NACL por defecto que AWS asoció a la VPC:

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

7. Ahora creá una NACL **personalizada** y volcala inmediatamente, antes de agregarle nada:

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

Compará con el paso 6. La diferencia — la NACL por defecto permite todo, la NACL personalizada deniega todo — es una trampa clásica del examen.

8. Agregá un allow de entrada solo para HTTP, más un deny que lo *precede*, para observar el orden por número de regla:

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

El protocolo `6` es TCP (número IANA); la CLI acepta el nombre y almacena el número.

**Comprobá lo que entendiste — bloque 1.2**

- **Q4.** Reescribí las dos reglas de arriba con los números de regla `100` (deny 198.51.100.7) y `90` (allow 0.0.0.0/0). ¿Qué experimenta ahora `198.51.100.7`, y por qué?
- **Q5.** Una NACL personalizada está asociada a una subred y le agregaste *solamente* el allow de HTTP de entrada del paso 8. El navegador de un usuario manda `GET /` a tu servidor web en el puerto 80. El servidor lo procesa. ¿Llega la respuesta al navegador? Justificá en términos de la dirección de las reglas de la NACL.
- **Q6.** Completá la tabla de memoria, y después verificala contra lo que observaste:

  | | Security group | Network ACL |
  |---|---|---|
  | Se asocia a | ? | ? |
  | ¿Stateful? | ? | ? |
  | ¿Soporta deny? | ? | ? |
  | Evaluación de reglas | ? | ? |
  | Puede referenciar otro SG como origen | ? | ? |
  | Postura por defecto (creado a medida) | ? | ? |

---

### 1.3 (Opcional, ~$0,01) Demostrar empíricamente el statefulness

Hacé esto solo si querés la prueba a nivel de paquete. Lanza una `t3.micro`.

9. Hacé que la subred mire a internet:

```bash
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
```

10. Lanzá un servidor web sin clave SSH (solo user data):

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

El security group **no tiene ninguna regla de salida para la respuesta HTTP** más allá del catch-all — y aunque quitaras el catch-all, la respuesta igual fluiría, porque el grupo es stateful.

11. Pasá la subred a tu NACL personalizada (solo allow de HTTP de entrada, sin reglas de salida) y reintentá:

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

El código de salida 28 de `curl` es *operation timed out*. La petición llegó; la respuesta se descartó.

12. Agregá la regla de salida para puertos efímeros y reintentá:

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

**Comprobá lo que entendiste — bloque 1.3**

- **Q7.** En el paso 11 la regla de *entrada* de la NACL permitió la petición y el security group también la permitió — así que el paquete llegó a nginx. ¿Qué regla exactamente descartó la respuesta, y en qué dirección de la NACL?
- **Q8.** ¿Por qué `1024–65535` y no, digamos, `80`? ¿Qué extremo elige el puerto efímero, y a cuánto tendrías que ampliarlo para un cliente NAT basado en Windows o un ELB por delante?
- **Q9.** Los dos conjuntos de reglas terminaron permitiendo el tráfico. Enunciá el principio de diseño que explica por qué una VPC de producción bien administrada igual mantiene las NACLs gruesas (listas de deny amplias a nivel de subred) y los security groups finos (listas de allow por capa).

**Fuentes del Laboratorio 1**
- Security groups: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Network ACLs y puertos efímeros: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- Tabla comparativa: https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html

---

## Laboratorio 2 — Capa de borde y aplicación: WAF, Shield, Firewall Manager, Network Firewall

Los security groups y las NACLs leen cabeceras IP y puertos TCP/UDP. No pueden ver una cadena de inyección SQL en un parámetro de consulta. Eso es capa 7 — AWS WAF.

### 2.1 AWS WAF

1. Listá los grupos de reglas administrados por AWS disponibles para vos sin cargo de licencia por grupo de reglas:

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

2. Construí una web ACL con un grupo de reglas administrado más una regla basada en tasa:

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

3. Leé el consumo de capacidad (WCU) y notá que la lista de asociaciones está vacía:

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

4. Fijate a qué se puede asociar una web ACL. `--scope REGIONAL` cubre Application Load Balancer, API REST de API Gateway, API GraphQL de AppSync, user pool de Cognito, App Runner y Verified Access. `--scope CLOUDFRONT` cubre distribuciones de CloudFront y **debe crearse en `us-east-1`**:

```bash
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query 'WebACLs[].Name'
```

```json
[]
```

**Comprobá lo que entendiste — bloque 2.1**

- **Q10.** La acción por defecto de la web ACL es `Allow` y contiene una regla de tasa con `Block`. Reformulá esa política en una sola oración como un procedimiento de decisión ordenado.
- **Q11.** Un security group no puede bloquear un payload de inyección SQL y un WAF no puede bloquear un ataque de fuerza bruta SSH en el puerto 22. Explicá ambas limitaciones en términos de la capa OSI que inspecciona cada control.
- **Q12.** Tu capa web es un ALB *y* una distribución de CloudFront por delante. ¿Cuántas web ACLs necesitás, en qué Región(es), y por qué una no puede cubrir las dos?

---

### 2.2 Shield, Firewall Manager, Network Firewall

5. Verificá tu nivel de protección DDoS. Shield Standard está activo para todo cliente de AWS sin costo y no se puede apagar; Shield Advanced es una suscripción:

```bash
aws shield get-subscription-state --region us-east-1
```

```json
{
    "SubscriptionState": "INACTIVE"
}
```

6. Confirmá que las APIs exclusivas de Advanced se niegan a responder sin suscripción:

```bash
aws shield list-protections --region us-east-1
```

```
An error occurred (ResourceNotFoundException) when calling the ListProtections
operation: The subscription does not exist.
```

`INACTIVE` acá significa "Shield **Advanced** no está suscrito". Shield **Standard** sigue protegiendo tus endpoints de ELB, CloudFront y Route 53 contra inundaciones L3/L4 comunes; no tiene interruptor en la consola ni API porque no hay nada que configurar.

7. Verificá si la cuenta participa en la aplicación centralizada de políticas:

```bash
aws fms get-admin-account --region us-east-1
```

```
An error occurred (ResourceNotFoundException) when calling the GetAdminAccount
operation: Resource not found.
```

AWS Firewall Manager requiere **AWS Organizations**, una cuenta administradora designada y **AWS Config habilitado en cada cuenta/Región miembro**. No filtra paquetes por sí mismo: *empuja y audita* web ACLs de WAF, protecciones de Shield Advanced, políticas de security groups, políticas de Network Firewall y reglas de DNS Firewall de Route 53 Resolver a lo largo de la organización.

8. Confirmá que no existe ningún network firewall administrado:

```bash
aws network-firewall list-firewalls --query 'Firewalls'
```

```json
[]
```

AWS Network Firewall es un **IDS/IPS administrado, stateful, asociado a la VPC** con reglas compatibles con Suricata — desplegado en subredes de firewall dedicadas y alcanzado mediante entradas de tabla de rutas. Es la capa entre "NACL/security group" (por subred/por ENI, sin inspección profunda) y "WAF" (solo HTTP).

**Comprobá lo que entendiste — bloque 2.2**

- **Q13.** Ordená estos cuatro de más barato/más automático a más configurable y más caro: Shield Standard, Shield Advanced, AWS WAF, AWS Network Firewall. Para cada uno, indicá la *única* palabra clave del escenario que debería hacerte elegirlo en el examen.
- **Q14.** Una organización de 500 cuentas necesita "que todo ALB expuesto a internet tenga el AWS Common Rule Set asociado, y quiero un informe de los que no lo tienen". ¿Qué servicio lo impone, y cuáles son sus dos prerrequisitos duros?
- **Q15.** Shield Advanced publicita "protección de costos". ¿Qué se reembolsa exactamente, y por qué es un beneficio significativo específicamente en una arquitectura elástica bajo DDoS?

**Fuentes del Laboratorio 2**
- AWS WAF: https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Shield: https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- Prerrequisitos de AWS Firewall Manager: https://docs.aws.amazon.com/waf/latest/developerguide/fms-prereq.html
- AWS Network Firewall: https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html

---

## Laboratorio 3 — Detección y gestión de la postura

Cuatro servicios que en una diapositiva parecen iguales y en la práctica son completamente distintos. El discriminador es **qué leen**.

### 3.1 Amazon GuardDuty — detección continua de amenazas

1. Habilitá un detector (prueba gratuita de 30 días en una cuenta que nunca tuvo uno):

```bash
DETECTOR_ID=$(aws guardduty create-detector --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --query DetectorId --output text)
echo "$DETECTOR_ID"
```

```
d4a1b2c3d4e5f60718293a4b5c6d7e8f
```

2. Mirá qué está consumiendo. Fijate que no instalaste nada:

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

3. Generá hallazgos de muestra y leé uno:

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

Escala de severidad: `1.0–3.9` Baja, `4.0–6.9` Media, `7.0–8.9` Alta, `9.0+` Crítica.

**Comprobá lo que entendiste — bloque 3.1**

- **Q16.** Nunca habilitaste VPC Flow Logs, nunca creaste un trail de CloudTrail y nunca instalaste un agente — y sin embargo GuardDuty analiza los tres flujos. Explicá el mecanismo, y la consecuencia de facturación (¿pagás por los flow logs que GuardDuty lee?).
- **Q17.** Un hallazgo dice `CryptoCurrency:EC2/BitcoinTool.B!DNS`. ¿Qué fuente de datos lo produjo, y qué está afirmando GuardDuty que ocurrió realmente?

---

### 3.2 Inspector, Macie, Detective, Security Hub — comparación de solo lectura

4. Verificá el estado de Amazon Inspector (no lo habilites salvo que aceptes la prueba):

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

Leé con atención los cuatro objetivos de escaneo: **instancias EC2, imágenes de contenedor de ECR, funciones Lambda, código de Lambda**. Inspector coteja los paquetes instalados contra feeds de CVE y produce un puntaje de riesgo. Escanea *software*, no comportamiento.

5. Verificá Amazon Macie:

```bash
aws macie2 get-macie-session
```

```
An error occurred (AccessDeniedException) when calling the GetMacieSession
operation: Macie is not enabled.
```

6. Verificá Amazon Detective:

```bash
aws detective list-graphs --query 'GraphList'
```

```json
[]
```

7. Verificá AWS Security Hub:

```bash
aws securityhub describe-hub
```

```
An error occurred (InvalidAccessException) when calling the DescribeHub
operation: Account 111122223333 is not subscribed to AWS Security Hub
```

8. Completá la tabla discriminadora sobre la marcha — esta es la carga útil de todo el laboratorio:

| Servicio | Lee | Produce | Palabra clave típica del examen |
|---|---|---|---|
| GuardDuty | CloudTrail, VPC Flow Logs, logs DNS, eventos de datos de S3, logs de auditoría de EKS, logins de RDS | Hallazgos de amenaza | "detectar *actividad* maliciosa", "instancia comprometida", "sin agente" |
| Inspector | Inventario de software de EC2 / imágenes de ECR / Lambda | Hallazgos de CVE + puntaje de riesgo | "vulnerabilidad", "sin parchear", "CVE", "escaneo de imagen de contenedor" |
| Macie | Objetos de S3 | Hallazgos de datos sensibles (PII, credenciales) | "descubrir PII en S3", "clasificar datos sensibles" |
| Detective | Hallazgos de GuardDuty + CloudTrail + Flow Logs, como grafo de comportamiento | Grafo de investigación / causa raíz | "investigar", "causa raíz", "cómo pasó esto" |
| Security Hub | Hallazgos de todo lo anterior, en ASFF | Postura agregada + puntajes de estándares | "panel único", "puntaje de benchmark CIS/PCI/NIST" |

**Comprobá lo que entendiste — bloque 3.2**

- **Q18.** Emparejá cada pedido con exactamente un servicio: (a) "¿Alguna de nuestras imágenes de contenedor corre un `log4j` vulnerable?" (b) "¿Alguien está exfiltrando datos de esa instancia ahora mismo?" (c) "¿El bucket `hr-exports` contiene números de documento nacional?" (d) "Mostrame cada paso que dio el atacante entre cuentas en los últimos 14 días." (e) "Dame un solo tablero con nuestro puntaje de benchmark CIS en 40 cuentas."
- **Q19.** Se describe a Detective como consumidor de hallazgos de GuardDuty. ¿Qué implica eso sobre el orden en que habilitás los dos servicios, y sobre el valor de Detective en una cuenta donde GuardDuty nunca corrió?
- **Q20.** A Security Hub se lo llama agregador. Nombrá el formato estándar de hallazgos al que normaliza todo, y explicá por qué ese formato es lo que hace enchufables a los productos de seguridad de terceros del AWS Marketplace.

**Fuentes del Laboratorio 3**
- GuardDuty: https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- Inspector: https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Macie: https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Detective: https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- Security Hub y ASFF: https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html

---

## Laboratorio 4 — Protección de datos: KMS, CloudHSM, Secrets Manager, ACM

### 4.1 AWS KMS

1. Mirá las claves que AWS ya creó para vos:

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

Estas son **claves administradas por AWS** — gratuitas, rotadas automáticamente cada año, y no podés editar su política de clave ni eliminarlas.

2. Creá una **clave administrada por el cliente** y ponele un alias ($1/mes, prorrateado):

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

3. Cifrá y descifrá un valor chico. Mirá el límite de tamaño:

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

Notá que la llamada de descifrado **no** necesitó `--key-id`: el ARN de la clave está embebido en el blob de texto cifrado.

4. Chocá contra el límite a propósito:

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

5. Por eso los servicios de AWS usan **cifrado de sobre (envelope encryption)**. Miralo ocurrir:

```bash
aws kms generate-data-key --key-id alias/clf-sec-lab --key-spec AES_256 \
  --query '{PlaintextKeyLen:Plaintext,WrappedKey:CiphertextBlob}' --output json \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);print("plaintext DEK bytes:",len(base64.b64decode(d["PlaintextKeyLen"])));print("wrapped DEK bytes:",len(base64.b64decode(d["WrappedKey"])))'
```

```
plaintext DEK bytes: 32
wrapped DEK bytes: 184
```

Cifrás localmente tu objeto de 5 GB con la clave de datos de 32 bytes, guardás la clave envuelta de 184 bytes al lado, y descartás la clave en claro de la memoria. La clave de KMS nunca toca tus datos.

6. Activá la rotación automática:

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

7. Confirmá que CloudHSM es un mundo distinto, de un solo inquilino:

```bash
aws cloudhsmv2 describe-clusters --query 'Clusters[].{Id:ClusterId,State:State,Mode:Mode}'
```

```json
[]
```

**Comprobá lo que entendiste — bloque 4.1**

- **Q21.** En el paso 3, `decrypt` funcionó sin que nombraras ninguna clave. ¿Qué te dice eso sobre dónde se impone la autorización, y qué dos documentos de política deben permitir ambos la llamada?
- **Q22.** Un regulador exige que "ningún empleado del proveedor de nube pueda acceder al material de clave, y nosotros debemos controlar los usuarios del HSM". ¿Qué servicio, y qué dos cargas operativas heredás al elegirlo?
- **Q23.** Cifrado de sobre: la clave de KMS rotó según lo programado. ¿Tenés que volver a cifrar tus objetos de 5 GB en S3? Explicá en términos de qué rotó realmente y a qué apunta el texto cifrado almacenado del objeto.

---

### 4.2 Secrets Manager, Parameter Store, ACM

8. Guardá una credencial:

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

9. Leela de vuelta e inspeccioná los metadatos — sobre todo la rotación y qué clave la cifró:

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

`Kms: null` significa que se usó la clave administrada por AWS `alias/aws/secretsmanager`. `AWSCURRENT` / `AWSPREVIOUS` / `AWSPENDING` son las etiquetas de estado (staging labels) entre las que se mueve la rotación.

10. Guardá el equivalente en Systems Manager Parameter Store y compará:

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

Los dos cifran con KMS. Solo Secrets Manager tiene **rotación programada incorporada con una Lambda administrada** e integración nativa con credenciales de RDS/Redshift/DocumentDB. Los parámetros Standard de Parameter Store son **gratis**.

11. Mirá tu inventario de certificados TLS:

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

Datos clave para memorizar: **los certificados públicos emitidos por ACM son gratuitos**, se **renuevan automáticamente** mientras la validación por DNS siga en su lugar, y los consumen *servicios integrados* — ELB, CloudFront, API Gateway, App Runner — en vez de instalarse a mano en una instancia EC2. Un certificado para CloudFront tiene que vivir en **`us-east-1`**.

**Comprobá lo que entendiste — bloque 4.2**

- **Q24.** Necesitás una contraseña de base de datos rotada cada 30 días sin escribir código de rotación, y que el mismo secreto lo lean una tarea de ECS y una Lambda. ¿Secrets Manager o Parameter Store, y qué compensación de costo estás aceptando?
- **Q25.** Una instancia RDS en `eu-west-1` y una distribución de CloudFront necesitan ambas un certificado para `app.example.com`. ¿Cuántos certificados de ACM, y en qué Regiones? ¿Por qué?
- **Q26.** Nombrá el servicio de seguridad de AWS para cada una de estas tres oraciones: (a) "cifrá este volumen EBS de 200 GB"; (b) "almacená el token de API que mi app lee al arrancar"; (c) "terminá TLS en el balanceador de carga".

**Fuentes del Laboratorio 4**
- Conceptos de KMS y cifrado de sobre: https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html
- CloudHSM: https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- Rotación en Secrets Manager: https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html
- ACM: https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html

---

## Laboratorio 5 — Gobernanza y auditoría: CloudTrail, Config, Access Analyzer, Trusted Advisor

### 5.1 CloudTrail — quién hizo qué

1. Consultá el Event history gratuito de 90 días para la clave de KMS que acabás de crear:

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

2. Verificá si existe algún *trail* — el Event history no es lo mismo:

```bash
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,Multi:IsMultiRegionTrail,S3:S3BucketName,Org:IsOrganizationTrail}'
```

```json
[]
```

El Event history se retiene 90 días, cubre **solo eventos de administración**, y no se puede consultar más allá de esa ventana. Un **trail** entrega a S3 (y opcionalmente a CloudWatch Logs) para retención indefinida, puede ser multi-Región y a nivel de organización, y puede capturar **eventos de datos** (nivel de objeto en S3, invocaciones de Lambda) con costo adicional.

### 5.2 AWS Config — cuál es la configuración, y si cumple

3. Confirmá que no hay nada grabando:

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

Leé el contraste en voz alta: CloudTrail registra **llamadas de API** (verbos); Config registra **el estado de los recursos a lo largo del tiempo** (sustantivos) y evalúa reglas como `s3-bucket-public-read-prohibited` contra ese estado.

### 5.3 IAM Access Analyzer

4. Creá un analizador de acceso externo (esta clase de hallazgos es **gratis**):

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

(Una lista vacía es un resultado perfectamente bueno — significa que nada en la cuenta está compartido fuera de tu zona de confianza.)

5. Usá la validación de políticas, que no cuesta nada y no necesita analizador:

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

### 5.4 Trusted Advisor y Audit Manager

6. Pedí las verificaciones de seguridad:

```bash
aws support describe-trusted-advisor-checks --language en \
  --query 'checks[?category==`security`].name' --output table
```

En Support Basic o Developer:

```
An error occurred (SubscriptionRequiredException) when calling the
DescribeTrustedAdvisorChecks operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

La **API de Support** requiere soporte Business, Enterprise On-Ramp o Enterprise. La *consola* de Trusted Advisor muestra un conjunto básico de verificaciones de seguridad y cuotas de servicio a toda cuenta; el **catálogo completo de verificaciones en los cinco pilares** — optimización de costos, rendimiento, seguridad, tolerancia a fallos, límites de servicio y excelencia operativa — requiere esos niveles de soporte pagos.

7. Verificá Audit Manager:

```bash
aws auditmanager get-settings --attribute ALL --query 'settings' 2>&1 | head -3
```

```
An error occurred (AccessDeniedException) when calling the GetSettings
operation: Please complete AWS Audit Manager setup from home page to enable
this action in this account.
```

Audit Manager **recolecta evidencia** de forma continua y la mapea a marcos (SOC 2, PCI DSS, GDPR, HIPAA), convirtiendo una auditoría de un ejercicio manual de capturas de pantalla en un informe de evaluación generado.

**Comprobá lo que entendiste — bloque 5**

- **Q27.** Un auditor hace dos preguntas: "¿El bucket de S3 `hr-exports` estuvo público alguna vez, y por cuánto tiempo?" y "¿Qué principal lo hizo público?". Asigná cada pregunta a CloudTrail o AWS Config, y explicá por qué el otro no puede responderla.
- **Q28.** Tu Event history de CloudTrail no muestra nada de hace cuatro meses. Dá la razón en dos partes y el único cambio de configuración que habría evitado el hueco.
- **Q29.** `validate-policy` marcó `PASS_ROLE_WITH_STAR_IN_RESOURCE` en una política sintácticamente válida que se desplegaría sin problemas. ¿Qué clase de herramienta es esta, y en qué punto de un pipeline de entrega corresponde?
- **Q30.** Distinguí, en una oración cada uno: hallazgos de *acceso externo* de IAM Access Analyzer, hallazgos de *acceso no utilizado* de IAM Access Analyzer, y verificaciones de seguridad de Trusted Advisor.

**Fuentes del Laboratorio 5**
- Event history de CloudTrail vs. trails: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html
- AWS Config: https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- IAM Access Analyzer: https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- Trusted Advisor: https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- Audit Manager: https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html

---

## Laboratorio 6 — Dónde vive la información de seguridad y cumplimiento de AWS

La guía del examen lo lista explícitamente: *"Identificar dónde se puede encontrar la información de seguridad de AWS"* e *"Identificar dónde encontrar la información de cumplimiento de AWS"*. Son preguntas de memoria; el punto de este laboratorio es haber abierto cada puerta al menos una vez.

1. **AWS Artifact** — descarga autogestionada de los artefactos de auditoría de AWS (SOC 1/2/3, ISO 27001/27017/27018, AOC de PCI DSS, FedRAMP) y acuerdos legales (BAA, informes bajo NDA).

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

Consola: https://console.aws.amazon.com/artifact/

2. **AWS Security Bulletins** — avisos estilo CVE para servicios de AWS y software mantenido por AWS, identificados como `AWS-YYYY-NNN`:

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

3. Abrí cada uno de estos una vez y anotá qué tipo de respuesta te da cada uno:

| Recurso | URL | Responde |
|---|---|---|
| AWS Security Center | https://aws.amazon.com/security/ | Panorama general, responsabilidad compartida, postura actual |
| Security Bulletins | https://aws.amazon.com/security/security-bulletins/ | "¿Me afecta la CVE-X?" |
| AWS Security Blog | https://aws.amazon.com/blogs/security/ | Patrones, cómo hacerlo, lanzamientos |
| AWS Knowledge Center | https://repost.aws/knowledge-center | "¿Cómo arreglo este error específico?" |
| AWS re:Post | https://repost.aws/ | Preguntas y respuestas de la comunidad, moderadas por AWS |
| AWS Compliance Programs | https://aws.amazon.com/compliance/programs/ | Qué certificaciones tiene AWS |
| AWS Artifact | https://console.aws.amazon.com/artifact/ | El PDF del informe real, bajo NDA |
| Well-Architected Security Pillar | https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html | Guía de diseño |
| Penetration Testing Policy | https://aws.amazon.com/security/penetration-testing/ | Qué podés probar sin pedir permiso |
| Reportar abuso | `abuse@amazonaws.com` | Recursos de AWS que te están atacando |

4. **AWS Marketplace** — productos de seguridad de terceros. Navegá la categoría Security y fijate en los modelos de entrega (AMI, suscripción SaaS, contenedor, servicios profesionales) y en que los cargos caen en tu factura de AWS existente:

```bash
aws marketplace-catalog list-entities --catalog AWSMarketplace \
  --entity-type AmiProduct --max-results 3 \
  --query 'EntitySummaryList[].{Name:Name,Id:EntityId}' --output table
```

Consola: https://aws.amazon.com/marketplace/ → *Categories → Infrastructure Software → Security*.

5. **Pruebas de penetración.** Leé https://aws.amazon.com/security/penetration-testing/ y anotá las ocho categorías de servicios que podés probar **sin aprobación previa**, y las categorías de *evento simulado* (simulación de DDoS, simulación de phishing, pruebas de malware) que sí requieren el formulario de Simulated Events.

**Comprobá lo que entendiste — bloque 6**

- **Q31.** El equipo de compras de un cliente potencial exige "su informe SOC 2 Type II". Todavía no tenés uno para tu propio SaaS, pero corrés enteramente sobre AWS. ¿De dónde sacás el de AWS, qué limita cómo lo compartís, y qué es lo que *no* cubre?
- **Q32.** Distinguí AWS Artifact de AWS Audit Manager en una oración cada uno. ¿Cuál trata del cumplimiento de AWS y cuál del tuyo?
- **Q33.** Tu equipo de seguridad quiere correr un escaneo de vulnerabilidades con credenciales contra tus propias instancias EC2 y un fuzz autenticado contra tu propio API Gateway. ¿Necesitás aprobación? ¿Y si además quieren correr una prueba de generación de tráfico de 20 Gbps contra tu ALB?
- **Q34.** Sale una CVE nueva para OpenSSL. Nombrá el servicio nativo de AWS que te dice cuáles de *tus* instancias EC2 e imágenes de contenedor están afectadas, y el recurso de AWS que te dice si los *servicios administrados por AWS* están afectados.

---

## Laboratorio 7 — Desmontaje

Ejecutá esto en orden. Varios borrados fallan si quedan dependencias.

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

Confirmá que la clave de KMS es el único cargo remanente:

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
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Laboratorio 1 — Security groups y NACLs

**Q1.** No podés, porque los security groups de VPC soportan **solo reglas de allow**. No hay primitiva de deny (`authorize` / `revoke` son los únicos verbos — `revoke` quita un allow, no crea un deny). Todo lo que no permitas explícitamente queda implícitamente denegado, pero no podés recortar una excepción *dentro de* un allow más amplio. La construcción que sí puede expresar deny es la **network ACL**, que tiene un `RuleAction: deny` explícito y evalúa las reglas en orden ascendente de número, de modo que un deny con número bajo eclipsa a un allow con número más alto. En la práctica, bloquear una sola IP hostil corresponde a la NACL (a nivel de subred) o, para HTTP, a una regla de bloqueo por IP set en AWS WAF.

**Q2.** AWS no resuelve el grupo referenciado a una lista fija de IPs. En el momento del paquete, la regla significa "la ENI de origen del tráfico es miembro del security group `sg-...web`". La pertenencia se evalúa dinámicamente, así que cuando Auto Scaling reemplaza una instancia web por otra con una IP privada nueva, la regla de la DB sigue funcionando sin cambios. Este es el argumento más fuerte a favor de referenciar SGs en vez de reglas por CIDR en una arquitectura elástica — y es por eso que las NACLs, que solo entienden CIDRs, son el lugar equivocado para reglas entre capas.

**Q3.** AWS asocia una regla de salida por defecto de `IpProtocol: -1` hacia `0.0.0.0/0` a todo security group recién creado — todo el tráfico saliente permitido. En el momento en que llamás vos mismo a `authorize-security-group-egress`, esa regla por defecto sigue ahí; no se elimina automáticamente. Para lograr una salida restrictiva tenés que **revocar explícitamente** la regla de todos los protocolos hacia `0.0.0.0/0` con `revoke-security-group-egress` después de agregar la tuya. Olvidarse de esto es la razón más común por la que un security group "cerrado" igual permite salida total.

**Q4.** Con el deny en 100 y el allow en 90, `198.51.100.7` queda **permitida**. La evaluación de la NACL recorre las reglas en orden numérico ascendente y se detiene en la primera coincidencia. La regla 90 (`allow 0.0.0.0/0:80`) coincide con `198.51.100.7` primero, así que el paquete se permite y nunca se llega a la regla 100. Las reglas de deny siempre deben numerarse **más bajo** que el allow más amplio del que están recortando una excepción. Por eso el esquema convencional de numeración deja huecos (10, 20, 30…) — necesitás lugar para insertar un deny por encima de un allow existente.

**Q5.** No, la respuesta no llega al navegador. Las NACLs son **stateless**: los conjuntos de reglas de entrada y de salida se evalúan de manera independiente, y un flujo de entrada permitido no crea ninguna entrada de estado que autorice su propia respuesta. La respuesta es una *nueva evaluación de salida* — puerto de origen 80, destino el puerto efímero del cliente — y la única entrada de salida de la NACL personalizada es la regla 32767 `deny all`. La respuesta se descarta en el borde de la subred. La conexión parece colgarse y expira (exactamente el `curl` con salida 28 del paso 11).

**Q6.**

| | Security group | Network ACL |
|---|---|---|
| Se asocia a | ENI (instancia / nodo del ALB / endpoint de RDS) | Subred |
| ¿Stateful? | **Sí** — el tráfico de retorno se permite automáticamente | **No** — entrada y salida se evalúan de forma independiente |
| ¿Soporta deny? | No, solo allow | Sí, `allow` y `deny` |
| Evaluación de reglas | Se evalúan todas las reglas; si alguna permite, se permite | Gana la primera coincidencia, en orden ascendente de número de regla, y después el deny implícito `*` |
| Puede referenciar otro SG como origen | Sí (y prefix lists) | No — solo bloques CIDR |
| Postura por defecto (creado a medida) | Toda la entrada denegada, toda la salida permitida | Todo el tráfico denegado en **ambas** direcciones hasta que agregues reglas |

Dos extras que vale la pena saber: una ENI puede llevar varios security groups (las reglas se unen), mientras que una subred tiene exactamente una NACL; y la NACL *por defecto* que AWS crea con una VPC permite todo, a diferencia de una NACL que creás vos.

**Q7.** El **deny implícito de salida (egress) — regla 32767 — en la NACL personalizada** descartó la respuesta. Seguí la traza: la regla 100 de entrada de la NACL permitió TCP/80 → la entrada del security group permitió TCP/80 → nginx respondió → la salida del security group permitió la respuesta de forma stateful (y por su catch-all) → la evaluación de salida de la NACL no encontró ningún allow coincidente → se disparó el `deny` de la regla 32767.

**Q8.** El **cliente** elige el puerto efímero de origen cuando abre la conexión; la respuesta del servidor va dirigida *a* ese puerto, así que la regla de salida de la NACL tiene que cubrir todo el rango plausible en vez del puerto 80. Los rangos difieren según el stack: los kernels modernos de Linux usan `32768–60999`, Windows Server 2008+ usa `49152–65535`, un Elastic Load Balancer usa `1024–65535`, y un NAT gateway usa `1024–65535`. Como la NACL de una subred ve tráfico de todos ellos, `1024–65535` es el superconjunto seguro — y el hecho de que estés obligado a abrir 64.000 puertos de salida es precisamente por qué las NACLs son un instrumento tosco comparadas con un security group stateful.

**Q9.** **Defensa en profundidad con el control en la granularidad correcta.** El security group es el control por carga de trabajo, consciente de la identidad y stateful: puede decir "solo la capa web puede llegar a la DB en 3306" sin conocer ninguna IP, y no necesita contabilidad de puertos efímeros. La NACL es el respaldo grueso a nivel de subred: es el único lugar que puede expresar deny, se aplica incluso si alguien configura mal un security group, y es el lugar correcto para bloqueos a nivel de CIDR (un bloque de red hostil conocido, o "esta subred de datos nunca habla con internet"). Intentar expresar reglas finas entre capas en las NACLs te lleva contra el límite blando de 20 reglas (40 duro), el problema stateless de los puertos efímeros, y la pérdida de la referencia entre SGs.

---

### Laboratorio 2 — WAF, Shield, Firewall Manager, Network Firewall

**Q10.** Para cada petición entrante: evaluar las reglas en orden de prioridad (primero la 0); si el Common Rule Set coincide con un patrón malicioso, aplicar la acción del grupo de reglas y detenerse; si no, si esta IP de origen envió más de 2.000 peticiones en la ventana móvil de 5 minutos, bloquear y detenerse; si no, caer a la acción por defecto y permitir la petición.

**Q11.** Un security group inspecciona **solo capa 3/4** — direcciones IP, protocolo, números de puerto. Una inyección SQL llega como una conexión TCP/443 perfectamente legítima desde una IP arbitraria; el contenido malicioso está en el cuerpo HTTP o en la cadena de consulta, que el security group nunca parsea. AWS WAF inspecciona **capa 7** — parsea la petición HTTP (URI, cabeceras, cuerpo, cookies, argumentos de consulta) y puede coincidir por contenido. A la inversa, WAF solo se asocia a recursos que terminan HTTP(S) (CloudFront, ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access), así que una fuerza bruta SSH sobre TCP/22 a una instancia EC2 nunca pasa por él — eso es terreno del security group y de GuardDuty.

**Q12.** **Dos web ACLs.** El scope de WAF no es solo una etiqueta — una web ACL `REGIONAL` y una `CLOUDFRONT` son tipos de recurso distintos con ARNs distintos, y una sola web ACL solo puede asociarse a recursos de su propio scope. El ALB necesita una web ACL `REGIONAL` en la Región del ALB; la distribución de CloudFront necesita una web ACL de scope `CLOUDFRONT` creada en **`us-east-1`**, porque CloudFront es un servicio global cuyo plano de control vive ahí. (En la práctica pondrías las reglas reales en la ACL de CloudFront y usarías la ACL del ALB para forzar que las peticiones efectivamente hayan venido a través de CloudFront.)

**Q13.**

| Puesto | Servicio | Costo / esfuerzo | Palabra clave del examen |
|---|---|---|---|
| 1 | **Shield Standard** | Gratis, automático, sin configuración | "sin costo adicional", "protege automáticamente contra DDoS L3/L4 comunes" |
| 2 | **AWS WAF** | ~$5/ACL + $1/regla + $0,60/M peticiones | "inyección SQL", "XSS", "límite de tasa por IP", "bloquear por país", "OWASP" |
| 3 | **AWS Network Firewall** | Hora de endpoint + GB procesados | "IDS/IPS para toda la VPC", "reglas Suricata", "filtrado de salida por dominio" |
| 4 | **Shield Advanced** | $3.000/mes por organización, compromiso de 1 año | "Shield Response Team 24×7", "protección de costos ante DDoS", "DDoS a gran escala/sofisticado" |

**Q14.** **AWS Firewall Manager.** Sus dos prerrequisitos duros: (1) la cuenta debe formar parte de una organización de **AWS Organizations** con todas las funciones habilitadas, y la cuenta de administración debe designar una **cuenta administradora** de Firewall Manager; (2) **AWS Config debe estar habilitado** en cada cuenta y Región miembro dentro del alcance, porque Firewall Manager usa Config para descubrir recursos y evaluar el cumplimiento. Una política de Firewall Manager auto-remedia (asocia la web ACL a los ALBs recién creados) y además reporta los recursos no conformes.

**Q15.** La **protección de costos** de Shield Advanced reembolsa los cargos de escalado en que incurriste *a causa de* un ataque DDoS cubierto — el uso extra de EC2/ELB/CloudFront/Route 53/Global Accelerator que provocó el ataque, otorgado como créditos de servicio tras un reclamo. Esto importa específicamente en arquitecturas elásticas porque el daño del ataque no es la caída, es la factura: Auto Scaling y CloudFront hacen su trabajo, absorben 40 Gbps de basura, y te entregan una factura enorme de transferencia de datos y horas de instancia. Sin protección de costos, "la arquitectura sobrevivió" y "el ataque salió carísimo" son el mismo evento.

---

### Laboratorio 3 — Detección y postura

**Q16.** GuardDuty consume esos flujos de logs a través de **una vía interna, de servicio a servicio**, no leyendo logs de tu cuenta. No requiere que habilites VPC Flow Logs, ni que crees un trail de CloudTrail, ni que instales un agente, y los datos que ingiere no aparecen en — ni facturan contra — tus propios costos de CloudWatch Logs, S3 o Flow Logs. Solo pagás el precio propio de GuardDuty por evento / por GB analizado. Esa propiedad de "sin agente, sin prerrequisitos" es exactamente lo que evalúan las preguntas del examen: si un escenario dice "sin desplegar software ni habilitar registros adicionales", la respuesta es GuardDuty.

**Q17.** El sufijo `!DNS` identifica a los **logs DNS** como fuente de datos (específicamente, consultas resueltas por el resolvedor DNS de la VPC provisto por Amazon — este tipo de hallazgo solo se dispara si tus instancias usan el resolvedor por defecto). GuardDuty está afirmando que una instancia EC2 de tu cuenta emitió consultas DNS para un dominio asociado a un pool de minería de criptomonedas — la firma conductual de una instancia comprometida y enrolada en criptominería. Es un hallazgo de *actividad*, no de vulnerabilidad: GuardDuty no está diciendo que la instancia esté sin parchear, está diciendo que la instancia se está comportando mal ahora.

**Q18.** (a) **Amazon Inspector** — coincidencia de CVEs contra el contenido de imágenes de contenedor en ECR. (b) **Amazon GuardDuty** — detección conductual de amenazas en tiempo real a partir de telemetría de red y DNS. (c) **Amazon Macie** — descubrimiento y clasificación de datos sensibles en S3. (d) **Amazon Detective** — el grafo de comportamiento que enlaza hallazgos, llamadas de API y flujos de red en una línea de tiempo de investigación. (e) **AWS Security Hub** — agregación entre cuentas y puntuación automatizada de estándares de seguridad.

**Q19.** El valor de Detective es derivado: ingiere hallazgos de GuardDuty como puntos de entrada de investigación, junto con eventos de administración de CloudTrail y VPC Flow Logs, y los hilvana en un grafo de comportamiento. Así que **GuardDuty tiene que habilitarse primero** — de hecho, una cuenta debe haber tenido GuardDuty habilitado por al menos 48 horas antes de poder habilitar Detective. En una cuenta donde GuardDuty nunca corrió no hay hallazgos desde los cuales pivotar, y Detective no tiene nada que investigar; estarías pagando por un grafo sin punto de partida. El modelo mental limpio: **GuardDuty te dice *que* algo pasó; Detective te ayuda a descifrar *cómo*.**

**Q20.** El **AWS Security Finding Format (ASFF)** — un esquema JSON definido que cubre severidad, recurso, estado de cumplimiento, remediación y estado del flujo de trabajo. Como Security Hub ingiere y emite ASFF, cualquier producto de terceros del AWS Marketplace (una integración de Palo Alto, CrowdStrike, Tenable, Qualys) puede publicar hallazgos en el mismo panel único que GuardDuty e Inspector, y cualquier automatización aguas abajo — una regla de EventBridge, una integración con ticketing, una auto-remediación con Lambda — puede escribirse una vez contra un esquema en lugar de una vez por proveedor. La normalización es el producto.

---

### Laboratorio 4 — Protección de datos

**Q21.** El ARN de la clave está embebido en el blob de texto cifrado, así que KMS sabe qué clave usar sin que se lo digan. La autorización se impone **enteramente del lado del servidor, en KMS**, y requiere **las dos cosas**: (1) la **política de IAM** asociada a tu principal debe permitir `kms:Decrypt`, y (2) la **política de clave de KMS** sobre esa clave debe permitir a tu principal (directamente, o delegando en IAM con una sentencia `Principal: {"AWS": "arn:aws:iam::111122223333:root"}` más `kms:ViaService`/grants). Este control dual es por lo que una clave de KMS es una segunda línea de defensa genuina: una política de IAM demasiado permisiva por sí sola no otorga acceso a los datos, y borrar una sentencia de la política de clave deja afuera incluso a un administrador de la cuenta.

**Q22.** **AWS CloudHSM.** Es hardware de un solo inquilino, validado FIPS 140 Nivel 3, donde vos — no AWS — creás y administrás los usuarios del HSM (CO, CU, AU) y el material de clave; AWS opera el hardware pero no tiene acceso criptográfico. Las cargas que heredás: (1) **sos dueño de la durabilidad y disponibilidad de las claves** — si perdés tus credenciales de crypto officer o destruís el último HSM de tu clúster sin backup, las claves y todo lo cifrado con ellas son irrecuperables, y tenés que diseñar vos mismo un clúster multi-AZ y una estrategia de quórum/backup; (2) **sos dueño de la integración con el cliente** — las aplicaciones deben usar PKCS#11, JCE, OpenSSL Dynamic Engine o bibliotecas KSP/CNG en vez de recibir cifrado transparente de S3/EBS/RDS, y pagás por hora de HSM lo uses o no. Elegilo solo cuando una regulación lo exija; si no, KMS (opcionalmente respaldado por un custom key store de CloudHSM) es el valor por defecto correcto.

**Q23.** **No hace falta volver a cifrar nada.** La rotación automática crea **material de clave de respaldo** nuevo para la misma clave lógica de KMS; el ID y el ARN de la clave nunca cambian. El texto cifrado almacenado de tu objeto de S3 está cifrado bajo una **clave de datos** que no cambió, y la clave de datos *envuelta* guardada al lado registra qué clave de respaldo la cifró. KMS retiene indefinidamente cada versión anterior de la clave de respaldo para descifrado, así que las claves envueltas viejas se siguen desenvolviendo. La rotación solo afecta las operaciones de cifrado nuevas. El corolario que hace tropezar a la gente: la rotación *no* reduce el radio de impacto de una clave de datos en claro ya filtrada, y no vuelve a cifrar nada — si necesitás un recifrado genuino tenés que llamar a `ReEncrypt` o reescribir los objetos vos mismo.

**Q24.** **AWS Secrets Manager.** Es el único de los dos con rotación programada incorporada, manejada por una función Lambda de rotación provista por AWS, incluyendo plantillas listas para RDS/Aurora/Redshift/DocumentDB que coordinan el cambio de contraseña tanto en el secreto como en la base de datos. Los dos servicios cifran con KMS y los dos son legibles desde ECS y Lambda vía IAM. La compensación que aceptás es el costo: Secrets Manager cuesta **$0,40 por secreto por mes más $0,05 por cada 10.000 llamadas de API**, mientras que los parámetros **Standard** de SSM Parameter Store son gratis (los parámetros Advanced cuestan $0,05/parámetro/mes). Si de todos modos ibas a rotar manualmente, `SecureString` de Parameter Store es la respuesta correcta más barata — el requisito de rotación es lo que fuerza a Secrets Manager.

**Q25.** **Dos certificados.** Los certificados de ACM son recursos regionales y no pueden usarse entre Regiones. El que consume **CloudFront debe solicitarse en `us-east-1`**, porque el plano de control de CloudFront está ahí — esto es cierto sin importar dónde viva tu origen. El caso de RDS es una trampa: RDS usa **certificados de CA de RDS administrados por AWS** para su endpoint TLS, no certificados públicos de ACM, así que en la práctica emitirías el certificado de ACM para el balanceador de carga o CloudFront delante de la aplicación, no para RDS en sí. La regla general para llevar al examen: *un certificado de ACM por Región donde un recurso termina TLS, y CloudFront siempre significa `us-east-1`.*

**Q26.** (a) **AWS KMS** — el cifrado de volúmenes EBS usa una clave de KMS (`alias/aws/ebs` por defecto, o tu propia clave administrada por el cliente) con cifrado de sobre; los datos del volumen los cifra el servicio de EBS con una clave de datos, de forma transparente. (b) **AWS Secrets Manager** (o `SecureString` de SSM Parameter Store si no hace falta rotación) — una credencial leída por la aplicación. (c) **AWS Certificate Manager** — un certificado público gratuito y de renovación automática asociado al listener HTTPS del Application Load Balancer.

---

### Laboratorio 5 — Gobernanza y auditoría

**Q27.** "¿Estuvo público alguna vez, y por cuánto tiempo?" → **AWS Config.** Config registra un **configuration item** con marca de tiempo cada vez que cambia el estado de un recurso y mantiene una línea de tiempo de configuración, así que podés ver la política del bucket en cualquier momento y el intervalo durante el cual existió la sentencia pública; una regla de Config como `s3-bucket-public-read-prohibited` también lo habría marcado como NON_COMPLIANT durante ese intervalo. CloudTrail no puede responderlo directamente porque CloudTrail registra eventos, no estado — tendrías que reconstruir el estado reproduciendo cada llamada `PutBucketPolicy`/`PutBucketAcl` y razonando sobre la política resultante, que no es para lo que sirve.

"¿Qué principal lo hizo público?" → **AWS CloudTrail.** El evento `PutBucketPolicy` lleva `userIdentity` (el principal de IAM, el rol asumido, el nombre de sesión), `sourceIPAddress`, `userAgent` y los parámetros de la petición. Config registra *que* la configuración cambió e incluso puede nombrar el ID del evento de CloudTrail relacionado, pero la identidad, la IP de origen y el contexto de la API viven en CloudTrail.

La versión de una línea: **CloudTrail = quién hizo qué (verbos, identidad). Config = cuál era el estado y si cumplía (sustantivos, línea de tiempo).** En una investigación real usás los dos, y el configuration item de Config convenientemente enlaza al evento de CloudTrail que lo causó.

**Q28.** Razón en dos partes: (1) **el Event history de CloudTrail retiene solo 90 días**, y (2) cubre **solo eventos de administración** — los eventos de datos (GET/PUT a nivel de objeto en S3, invocaciones de Lambda) nunca aparecen ahí. El cambio de configuración que evita el hueco es **crear un trail** — idealmente uno multi-Región y a nivel de organización que entregue a un bucket de S3 (con validación de archivos de log habilitada, e idealmente en una cuenta separada de archivo de logs con Object Lock). La retención queda entonces acotada solo por tu política de ciclo de vida de S3, y además podés seleccionar tipos de eventos de datos. Notá que un trail no es retroactivo: crear uno hoy no hace nada por los cuatro meses faltantes, y por eso "habilitar un trail el día uno" es un control estándar de landing zone.

**Q29.** Es una **herramienta de análisis estático / linting de políticas** — razonamiento automatizado sobre el documento de política, que produce hallazgos de validación, advertencias de seguridad, errores y sugerencias sin desplegar nada ni observar tráfico alguno. Corresponde **shift-left, en CI**: correr `aws accessanalyzer validate-policy` (y `check-no-new-access` / `check-access-not-granted` para verificaciones de política personalizadas) contra las políticas de IAM en tu Terraform/CloudFormation en cada pull request, y hacer fallar el build ante `ERROR` y `SECURITY_WARNING`. Detectar `PASS_ROLE_WITH_STAR_IN_RESOURCE` en la revisión cuesta un comentario; detectarlo después del despliegue cuesta un incidente, porque `iam:PassRole` sobre `*` es un camino de escalada de privilegios de manual.

**Q30.**
- **Hallazgos de acceso externo de IAM Access Analyzer:** identifican recursos (buckets de S3, roles de IAM, claves de KMS, funciones Lambda, colas SQS, secretos de Secrets Manager…) cuya política basada en recursos otorga acceso a un principal **fuera de tu zona de confianza definida** (cuenta u organización). Usa razonamiento automatizado demostrable; esta clase de hallazgos es **gratis**.
- **Hallazgos de acceso no utilizado de IAM Access Analyzer:** identifican usuarios de IAM, roles, claves de acceso, contraseñas y **permisos que no se usaron** dentro de un período de seguimiento configurable, para que puedas ajustar hacia el mínimo privilegio. Es un tipo de analizador **pago**, tarifado por rol/usuario de IAM analizado.
- **Verificaciones de seguridad de Trusted Advisor:** un catálogo fijo de **verificaciones de buenas prácticas** sobre tu cuenta — buckets de S3 públicos, security groups abiertos a `0.0.0.0/0` en puertos sensibles, falta de MFA en el usuario root, claves de acceso expuestas, uso de IAM, certificados de ACM por vencer. Las verificaciones básicas están disponibles para todas las cuentas; el catálogo completo multipilar y la API de Support requieren soporte Business, Enterprise On-Ramp o Enterprise.

---

### Laboratorio 6 — Fuentes de información y cumplimiento

**Q31.** Descargás el informe SOC 2 Type II de AWS desde **AWS Artifact**, en la AWS Management Console, sin cargo — aceptás los términos y se descarga como PDF. La restricción es que se provee bajo un **acuerdo de confidencialidad (NDA)** aceptado como parte de la descarga; podés compartirlo con los auditores de tu cliente bajo ese acuerdo, pero no podés publicarlo. Crucialmente, cubre **solo el lado de AWS del modelo de responsabilidad compartida** — la seguridad *de* la nube: los centros de datos de AWS, el hardware, el hipervisor, los planos de control de los servicios administrados. No dice nada sobre el código de tu aplicación, tus políticas de IAM, tus políticas de bucket de S3 ni tu parcheo. Para tu propio SOC 2 necesitás tu propia auditoría, en la cual el informe de AWS es evidencia heredada para los controles de infraestructura, no un sustituto.

**Q32.** **AWS Artifact** es el portal autogestionado donde descargás los informes de auditoría y certificaciones de terceros **de AWS** (SOC, ISO, PCI, FedRAMP) y aceptás acuerdos legales como el BAA de HIPAA — se trata del cumplimiento *de AWS*. **AWS Audit Manager** recolecta de forma continua evidencia de **tu** uso de AWS (eventos de CloudTrail, evaluaciones de reglas de Config, hallazgos de Security Hub, snapshots de recursos) y la mapea a marcos preconstruidos o personalizados para que puedas producir un informe de evaluación para **tu** auditor — se trata de *tu* cumplimiento. Regla mnemotécnica: *Artifact descarga los papeles de AWS; Audit Manager construye los tuyos.*

**Q33.** **No hace falta aprobación previa** para los dos primeros. AWS permite pruebas de seguridad del cliente sin aprobación contra ocho categorías de servicios, que incluyen **instancias EC2, NAT gateways y balanceadores de carga**, **RDS**, **CloudFront**, **Aurora**, **API Gateway**, **Lambda y Lambda@Edge**, **recursos de Lightsail** y **entornos de Elastic Beanstalk** — contra tus propios recursos, dentro de la AWS Customer Support Policy for Penetration Testing.

La prueba de generación de tráfico de 20 Gbps es distinta: es una **prueba simulada de DDoS / estrés de red**, que es una actividad prohibida salvo que se autorice por adelantado. Tenés que enviar el **formulario de Simulated Events** y obtener aprobación, y las pruebas de estrés por encima de umbrales definidos (AWS documenta un umbral de volumen a partir del cual la preaprobación es obligatoria) generalmente deben correrse a través de un socio de pruebas aprobado por APN. La misma vía de preaprobación cubre simulaciones de phishing, pruebas de malware y ejercicios de red team. También están prohibidos de plano sin aprobación: el recorrido de zonas DNS (DNS zone walking), la inundación de puertos/protocolos/peticiones, y cualquier prueba contra recursos que no te pertenezcan.

**Q34.** Para **tus** recursos: **Amazon Inspector** — mantiene un inventario de software continuamente actualizado de tus instancias EC2 (vía el agente de SSM), imágenes de contenedor de ECR y funciones Lambda, lo coteja contra feeds de CVE, y produce hallazgos con un puntaje de riesgo y el paquete/versión afectado, de modo que una CVE nueva de OpenSSL aparece automáticamente sin que programes un escaneo. Para los **servicios administrados por AWS**: la página de **AWS Security Bulletins** (https://aws.amazon.com/security/security-bulletins/), donde AWS publica avisos `AWS-YYYY-NNN` indicando qué servicios de AWS están afectados y qué deben hacer los clientes, si es que algo. El emparejamiento es el punto — Inspector no puede ver dentro de un servicio administrado, y un boletín de seguridad no puede contarte sobre tu propia instancia sin parchear.

</details>

---

## Fuentes oficiales

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- Seguridad de Amazon VPC (security groups, NACLs) — https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html
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
- AWS Marketplace (categoría Security) — https://aws.amazon.com/marketplace/
- AWS Well-Architected Framework, Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html