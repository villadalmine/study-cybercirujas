# Tema 3.5 — Identificar los servicios de red de AWS
## Ejercicios guiados (AWS Certified Cloud Practitioner, CLF-C02 v1.0)

**Peso en el examen dentro del Dominio 3:** 4,25 % del contenido puntuado total.
**Referencia:** [CLF-C02 Exam Guide](https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf)

---

## 0. Antes de empezar

### 0.1 Qué construye este laboratorio

Vas a construir a mano una VPC de dos capas y después recorrer hacia afuera cada capa del stack de red de AWS que nombra el examen: el plano de datos de la VPC (subnets, route tables, IGW, NAT), los dos firewalls (security groups y network ACLs), el acceso privado a servicios (VPC endpoints / PrivateLink), la familia del balanceo de carga (ALB / NLB / GWLB), DNS (Route 53), el borde global (CloudFront, Global Accelerator), la conectividad híbrida (Site-to-Site VPN, Direct Connect, Transit Gateway, peering) y las herramientas de diagnóstico (Flow Logs, Reachability Analyzer).

El examen CLF-C02 te pide *identificar* estos servicios — cuál resuelve qué problema. Este laboratorio te hace tocarlos, porque las preguntas de "identificar" son casi siempre preguntas de compromiso disfrazadas ("menor costo", "sin cambios de código", "IP estática", "enrutamiento de capa 7"), y los compromisos se fijan cuando viste a la API devolverlos.

### 0.2 Prerrequisitos

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

Fijá una región de trabajo y desactivá el pager para que la salida siga siendo procesable por scripts:

```bash
export AWS_REGION=us-east-1
export AWS_PAGER=""
```

También necesitás `dig` (`bind-utils` / `dnsutils`) y `curl`.

### 0.3 Registro de costos — leé esto antes de ejecutar nada

Casi todos los pasos de abajo son gratuitos. Los que no lo son están marcados con **`💲 BILLABLE`** y son opcionales. Los precios son precio de lista de `us-east-1` y cambian; la cifra autorizada está siempre en la página de precios del servicio.

| Recurso | Precio (us-east-1, lista) | Usado en |
|---|---|---|
| VPC, subnets, route tables, IGW, security groups, NACLs, conexión de peering | gratis | 1, 2, 4, 9 |
| Gateway VPC endpoint (S3 / DynamoDB) | gratis | 5 |
| Dirección IPv4 pública (incl. Elastic IP ociosa) | $0,005 / hora cada una | 3 |
| NAT Gateway | $0,045 / hora + $0,045 / GB procesado | 3 |
| Interface VPC endpoint (PrivateLink) | ~$0,01 / hora por AZ + $0,01 / GB | 5 |
| Application / Network Load Balancer | $0,0225 / hora + cargos por LCU | 6 |
| Zona alojada pública de Route 53 | $0,50 / mes + $0,40 / millón de consultas | 7 |
| VPC Flow Logs | ingesta de CloudWatch Logs (~$0,50 / GB) | 10 |
| Reachability Analyzer | $0,10 por análisis | 10 |

Fuentes: [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/), [ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/), [Route 53 pricing](https://aws.amazon.com/route53/pricing/).

La sección 11 es un desmantelamiento completo. Ejecutala.

---

## Ejercicio 1 — La VPC y su espacio de direcciones

Una VPC es una red lógicamente aislada, definida por software, con alcance de **una Región**, que abarca **todas las Availability Zones** de esa Región. Una subnet tiene alcance de **exactamente una AZ**. Esa asimetría es el dato sobre topología de VPC que más se evalúa.

### Pasos

1. Mirá lo que AWS ya te dio. Toda Región viene con una VPC por defecto:

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

2. Creá tu propia VPC con un rango RFC 1918 elegido deliberadamente y sin solapamientos:

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

3. Comprobá los límites de tamaño del CIDR. La longitud de prefijo permitida para una VPC va de `/16` (65 536 direcciones) a `/28` (16 direcciones). Intentá romperlo:

```bash
aws ec2 create-vpc --cidr-block 10.43.0.0/8
```

```
An error occurred (InvalidVpc.Range) when calling the CreateVpc operation:
The CIDR '10.43.0.0/8' is invalid.
```

4. Activá los nombres de host DNS (la resolución DNS está activada por defecto; los nombres de host no lo están, fuera de la VPC por defecto):

```bash
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames

aws ec2 describe-vpc-attribute --vpc-id "$VPC" --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value'
```

```
true
```

5. Creá cuatro subnets — una capa pública y una privada repartidas en dos AZ. Multi-AZ no es decoración: es la *única* forma de que una carga de trabajo basada en VPC sobreviva a la falla de una AZ.

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

6. Contá las direcciones utilizables. Un `/24` tiene 256 direcciones — pero AWS no te da 256:

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

AWS reserva **cinco** direcciones en cada subnet: la dirección de red (`.0`), el router de la VPC (`.1`), el resolver DNS provisto por Amazon (`.2`, que también es alcanzable en la base del CIDR de la VPC + 2 y en la dirección link-local `169.254.169.253`), una `.3` reservada para uso futuro, y la dirección de broadcast (`.255`) — el broadcast directamente no está soportado en una VPC. Ver [Subnet CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html).

> **Preguntas de verificación**
> **Q1.** Una VPC vive en una Región y abarca todas sus AZ. ¿Cuál es el alcance de una subnet, y por qué eso convierte a "una subnet por capa" en un antipatrón?
> **Q2.** Dimensionás una subnet como `/28`. ¿Cuántas direcciones IP pueden usar realmente tus instancias, y por qué la respuesta no es 16?
> **Q3.** Tu centro de datos on-premises ya usa `10.0.0.0/16`. ¿Por qué elegir `10.0.0.0/16` para tu VPC genera un problema que después no podés arreglar sin reconstruirla?
> **Q4.** ¿Cuál es el prefijo CIDR más pequeño y el más grande que AWS acepta para una VPC?

---

## Ejercicio 2 — Internet Gateway y route tables: qué hace realmente que una subnet sea "pública"

No existe una bandera `public: true` en una subnet. Una subnet es pública si y solo si su route table asociada tiene una ruta hacia un Internet Gateway.

### Pasos

1. Inspeccioná la **route table principal** que AWS creó junto con la VPC. Toda subnet que no asocies explícitamente cae en esta:

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

Esa ruta `local` es implícita, no se puede borrar y no se puede sobrescribir. Es la razón por la que toda subnet de una VPC puede alcanzar a cualquier otra subnet de la misma VPC por defecto, sin importar la AZ.

2. Creá y adjuntá un Internet Gateway. Un IGW es un componente de VPC **a nivel de Región**, escalado horizontalmente y redundante — no tiene restricción de ancho de banda ni riesgo de disponibilidad sobre el que puedas influir:

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

3. Construí la route table pública y apuntá la ruta por defecto al IGW:

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

4. Asociala con ambas subnets públicas y activá la asignación automática de IPv4 pública:

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

5. Creá una route table privada **sin** ruta `0.0.0.0/0` y adjuntala a las subnets privadas:

```bash
export RTB_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=clf35-rtb-private}]' \
  --query 'RouteTable.RouteTableId' --output text)

for S in "$PRIV_A" "$PRIV_B"; do
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$S" \
    --query 'AssociationId' --output text
done
```

6. Leé el panorama final de enrutamiento:

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

> **Preguntas de verificación**
> **Q5.** Nombrá las dos condiciones que deben cumplirse simultáneamente para que una instancia EC2 sea alcanzable desde internet por IPv4, más allá de las reglas de firewall.
> **Q6.** Borrás la ruta `0.0.0.0/0 → igw-...` de `clf35-rtb-public`. ¿Las instancias en `clf35-public-a` siguen pudiendo alcanzar a las instancias en `clf35-private-b`? ¿Por qué?
> **Q7.** Un colega lanza una instancia en una subnet recién creada y se olvida de asociar una route table. ¿Qué enrutamiento se aplica, y qué significa eso para el acceso a internet en esta VPC?
> **Q8.** ¿Por qué un Internet Gateway no es un punto único de falla que tengas que contemplar en el diseño, a diferencia de un NAT Gateway?

---

## Ejercicio 3 — Salida sin entrada: NAT Gateway, instancia NAT, IGW de solo salida

Las subnets privadas suelen necesitar internet *saliente* (parches del SO, `pip install`, llamar a una API de terceros) manteniéndose inalcanzables desde afuera. Existen tres mecanismos, y el examen los distingue por versión de IP y por gestionado-vs-autogestionado.

### Pasos

1. Mirá primero la realidad actual del precio de IPv4 pública. Desde 2024, **toda** dirección IPv4 pública se factura, esté adjunta o no:

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

2. **`💲 BILLABLE`** — Reservá una Elastic IP y creá un NAT Gateway en una subnet **pública**. Un NAT Gateway tiene alcance de AZ: es un recurso *dentro de una AZ*, y muere con esa AZ.

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

Fijate en la subnet: el NAT Gateway está en `clf35-public-a`, no en la subnet privada a la que sirve. Ponerlo en una subnet privada es el error de configuración clásico — necesita su propia ruta al IGW para funcionar.

3. Apuntá la route table privada hacia él:

```bash
aws ec2 create-route --route-table-id "$RTB_PRIV" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"
```

```json
{ "Return": true }
```

4. Agregá IPv6 a la VPC y observá la primitiva de salida distinta. En AWS las direcciones IPv6 son **todas enrutables globalmente** — no existe la "IPv6 privada" — así que el concepto de NAT no aplica; en su lugar usás un **egress-only Internet Gateway**:

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

Un egress-only IGW es gratuito, stateful y escalado horizontalmente como un IGW normal — simplemente se niega a reenviar tráfico iniciado desde afuera.

5. Borrá el NAT Gateway ahora si lo creaste; factura por hora esté ocioso o no:

```bash
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT"
aws ec2 release-address --allocation-id "$EIP"
```

Referencia: [NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html).

> **Preguntas de verificación**
> **Q9.** ¿En qué subnet debe crearse un NAT Gateway público, y qué route table hay que modificar para que sirva de algo?
> **Q10.** Dá dos razones operativas para elegir un NAT Gateway por sobre una instancia NAT autogestionada en EC2, y la única razón por la que un equipo todavía podría elegir la instancia NAT.
> **Q11.** Tu arquitectura necesita internet solo de salida para cargas de trabajo con direccionamiento IPv6. ¿Qué componente usás, y por qué un NAT Gateway es la respuesta equivocada?
> **Q12.** Un único NAT Gateway sirve a subnets privadas en `us-east-1a` y `us-east-1b`. Describí tanto el problema de disponibilidad como el de costo que esto genera.

---

## Ejercicio 4 — Los dos firewalls: security groups vs. network ACLs

Esta es la comparación de mayor rendimiento del Tema 3.5. Ambos filtran tráfico; difieren en punto de conexión, gestión de estado, semántica de reglas y orden de evaluación.

### Pasos

1. Mirá el security group por defecto que AWS creó junto con la VPC:

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

Leé eso con atención: el SG por defecto permite entrada **desde sí mismo** (los miembros pueden hablar con los miembros) y salida hacia todas partes.

2. Creá un security group web hecho a medida. Un SG recién creado tiene **cero reglas de entrada** y salida permitida a todo:

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

3. Comprobá que un security group no puede expresar "deny". Probalo:

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" \
  --protocol tcp --port 22 --cidr 203.0.113.7/32 --rule-action deny
```

```
Unknown options: --rule-action, deny
```

No existe tal parámetro. **Los security groups son solo de permitir**; la ausencia de una regla de permiso coincidente *es* la denegación.

4. Construí la capa de aplicación y referenciá el SG web **como origen** — el modismo que hace componible la seguridad en VPC, porque sobrevive al autoescalado y a la rotación de IPs:

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

5. Ahora el otro firewall. Inspeccioná la network ACL por defecto:

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

La regla `32767` es la denegación general inmutable. La NACL por defecto viene con un `100 allow` permisivo delante de ella, así que es efectivamente transparente.

6. Creá una NACL **personalizada** y leé su estado vacío — acá es donde los equipos se llevan una sorpresa:

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

Una NACL personalizada **deniega todo en ambas direcciones** hasta que escribas reglas.

7. Escribí un par entrada/salida funcional para HTTPS. Como una NACL es **stateless**, tenés que permitir explícitamente el tráfico de retorno — y ese tráfico va a un **puerto efímero**, no de vuelta al 443:

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

El security group equivalente necesita **una** sola regla (entrada 443) porque es stateful: la respuesta a un flujo entrante permitido sale automáticamente, sin importar las reglas de salida.

8. Demostrá la evaluación ordenada — gana el número de regla más bajo, y una denegación puesta adelante nunca es alcanzada por un permiso posterior:

```bash
aws ec2 create-network-acl-entry --network-acl-id "$ACL" --rule-number 50 \
  --protocol 6 --port-range From=443,To=443 --cidr-block 198.51.100.0/24 \
  --rule-action deny --ingress
```

La regla 50 bloquea `198.51.100.0/24` aunque la regla 100 permita `0.0.0.0/0`, porque la evaluación de una NACL se detiene en la primera coincidencia en orden ascendente de número de regla. Un security group no tiene orden alguno — se evalúan **todas** las reglas y cualquier coincidencia permite.

Referencias: [Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html), [Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html).

> **Preguntas de verificación**
> **Q13.** Completá la comparación a partir de lo que observaste: punto de conexión, stateful/stateless, permitir-y-denegar o solo-permitir, orden de evaluación, postura por defecto de uno *recién creado*.
> **Q14.** Un ingeniero agrega una regla de entrada 443 a un security group y pregunta qué regla de salida agregar para las respuestas HTTP. ¿Qué le decís, y por qué?
> **Q15.** El mismo ingeniero hace lo mismo en una NACL personalizada. ¿Por qué la respuesta es distinta, y qué rango de puertos necesita la regla de salida?
> **Q16.** Tenés que bloquear una única dirección IP abusiva, `203.0.113.9`, para que no alcance a toda una subnet. ¿Cuál de los dos mecanismos puede hacerlo, y por qué el otro no?
> **Q17.** ¿Por qué que `SG_APP` referencie a `SG_WEB` por ID de grupo es más robusto que permitir el CIDR de la subnet de la capa web?

---

## Ejercicio 5 — Alcanzar servicios de AWS de forma privada: VPC endpoints y PrivateLink

Por defecto, llamar a `s3.amazonaws.com` desde una subnet privada sale por el camino de internet (vía NAT). Los VPC endpoints mantienen ese tráfico dentro de la red de AWS. Hay dos tipos y se facturan de forma muy distinta — una distinción favorita del examen.

### Pasos

1. Creá un **Gateway endpoint** para S3. Es gratuito, y funciona inyectando una ruta en las route tables:

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

2. Mirá qué le hizo a la route table privada:

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

El destino no es un CIDR — es una **prefix list gestionada**, un conjunto mantenido por AWS de los rangos de IP públicas del servicio. Resolvela:

```bash
aws ec2 describe-prefix-lists --prefix-list-ids pl-63a5400a \
  --query 'PrefixLists[0].{Name:PrefixListName,Ranges:Cidrs|length(@)}'
```

```json
{ "Name": "com.amazonaws.us-east-1.s3", "Ranges": 42 }
```

3. Confirmá el alcance de los Gateway endpoints. Solo dos servicios los soportan:

```bash
aws ec2 describe-vpc-endpoint-services \
  --filters Name=service-type,Values=Gateway \
  --query 'ServiceDetails[].ServiceName' --output text
```

```
com.amazonaws.us-east-1.dynamodb    com.amazonaws.us-east-1.s3
```

**S3 y DynamoDB. Esa es la lista completa.** Todo lo demás usa un Interface endpoint.

4. Examiná cómo se ve un **Interface endpoint** (AWS PrivateLink) antes de crear uno:

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

El mecanismo es distinto: un Interface endpoint coloca una **elastic network interface con una IP privada en cada subnet que selecciones**, y cuando se pasa `--private-dns-enabled`, una zona alojada privada de Route 53 sobrescribe `ssm.us-east-1.amazonaws.com` dentro de tu VPC para que los SDK sin modificar resuelvan a esa IP privada. Sin cambios en las route tables, sin cambios en la aplicación.

5. **`💲 BILLABLE`** — Opcional. Crealo y leé las IPs privadas asignadas, después borralo:

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

Referencia: [What is AWS PrivateLink?](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html)

> **Preguntas de verificación**
> **Q18.** ¿Qué dos servicios de AWS soportan Gateway endpoints, y cuánto cuesta un Gateway endpoint?
> **Q19.** Describí la diferencia de mecanismo: ¿qué modifica un Gateway endpoint, y qué crea un Interface endpoint?
> **Q20.** Una carga de trabajo en subnet privada llama a S3 con 100 TB/mes a través de un NAT Gateway. ¿Qué endpoint elimina la mayor parte de esa factura, y qué línea de costo desaparece?
> **Q21.** Tu equipo de seguridad exige que el tráfico hacia AWS Systems Manager nunca atraviese la internet pública, y prohíbe cambios en el código de la aplicación. ¿Qué desplegás y qué bandera hace verdadera la parte de "sin cambios de código"?

---

## Ejercicio 6 — Elastic Load Balancing: tres balanceadores de carga, tres capas

ELB distribuye el tráfico entrante entre targets en múltiples AZ y es la puerta de entrada estándar para una carga de trabajo de alta disponibilidad. CLF-C02 espera que elijas el *tipo* correcto.

### Pasos

1. Listá los tipos que tu cuenta puede crear:

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

2. Creá un target group — gratis — y observá que lo que separa a los tipos es el *vocabulario de protocolos*:

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

Un health check HTTP que verifica un código de estado solo tiene sentido en capa 7 — este target group únicamente puede adjuntarse a un ALB.

3. Probá lo mismo con un protocolo TCP y una ruta HTTP, para ver cómo se hace cumplir el límite de capa:

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

4. **`💲 BILLABLE`** — Opcional. Creá un ALB sobre ambas subnets públicas y notá que se direcciona por DNS, nunca por IP:

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

Las direcciones IP del ALB no son tuyas y cambian con el tiempo — que es exactamente el motivo por el que siempre publicás el nombre DNS (y por el que un NLB es la respuesta cuando un cliente exige una IP fija).

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <arn-from-above>
```

### La tabla de decisión que tenés que poder reproducir

| | Application LB | Network LB | Gateway LB |
|---|---|---|---|
| Capa OSI | 7 (HTTP/HTTPS/gRPC) | 4 (TCP/UDP/TLS) | 3 gateway + 4 |
| Enruta según | host, path, header, método, query, IP de origen | protocolo/puerto, hash de flujo | todo el tráfico, de forma transparente |
| IP estática | no (solo nombre DNS) | sí — una Elastic IP por AZ | vía endpoint |
| Preserva la IP del cliente | vía `X-Forwarded-For` | sí, de forma nativa | sí |
| Throughput extremo / baja latencia | bueno | el mejor; millones de req/s | n/a |
| WebSocket / HTTP/2 | sí | pass-through | pass-through |
| Uso típico | microservicios, contenedores, enrutamiento por path | gaming, IoT, TLS pass-through, IP estáticas en listas blancas | appliances de firewall / IDS de terceros en línea (GENEVE, puerto 6081) |

Referencia: [What is Elastic Load Balancing?](https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html)

> **Preguntas de verificación**
> **Q22.** El firewall corporativo de un cliente solo permite tráfico saliente hacia direcciones IP explícitamente incluidas en una lista blanca. ¿Qué balanceador de carga ponés delante del servicio, y por qué un ALB no sirve?
> **Q23.** `/api/*` debe ir a una flota y `/static/*` a otra, con un único nombre de host. ¿Qué balanceador de carga, y en qué capa OSI ocurre esa decisión?
> **Q24.** Un equipo de seguridad exige que todo el tráfico de la VPC pase por un appliance virtual de firewall de terceros antes de llegar a la carga de trabajo. ¿Qué tipo de ELB está diseñado para esto?
> **Q25.** ¿Por qué un ELB requiere fundamentalmente targets en al menos dos Availability Zones para cumplir con el valor que promete?

---

## Ejercicio 7 — Route 53: DNS como plano de control de enrutamiento y salud

Route 53 es un servicio **global** (sin selector de Región) que hace tres trabajos: registro de dominios, DNS autoritativo y verificación de salud. Sus políticas de enrutamiento son lo que convierte al DNS en una herramienta de disponibilidad.

### Pasos

1. Confirmá la naturaleza global de la API — el endpoint no es regional:

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

2. Observá el comportamiento real de Route 53 sin pagar por una zona. Consultá la delegación NS de un dominio alojado por AWS y mirá la respuesta:

```bash
dig +short NS amazon.com
```

```
ns1.p31.dynect.net.
pdns6.ultradns.co.uk.
...
```

Ahora consultá un nombre que sabés que sirve la infraestructura de AWS e inspeccioná el tipo de registro:

```bash
dig +noall +answer d1.awsstatic.com
```

```
d1.awsstatic.com.	60	IN	CNAME	d1.awsstatic.com.cdn.cloudfront.net.
d1.awsstatic.com.cdn.cloudfront.net. 60 IN A	18.160.10.44
d1.awsstatic.com.cdn.cloudfront.net. 60 IN A	18.160.10.72
```

Múltiples registros A con un TTL corto: distribución a nivel DNS entre edge locations.

3. **`💲 BILLABLE ($0,50/mes)`** — Opcional. Creá una zona alojada privada y un registro, para ver la forma de la API:

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

4. Aprendé el conjunto de políticas de enrutamiento — el examen evalúa el mapeo de requisito de negocio a política:

| Política | Selecciona un registro por | Uso canónico |
|---|---|---|
| Simple | un registro, sin lógica | endpoint único |
| Weighted | pesos asignados | blue/green, canary, división A/B |
| Latency-based | menor latencia medida hacia la Región | apps globales que optimizan velocidad |
| Failover | health check sobre el primario | DR activo/pasivo |
| Geolocation | país/continente del usuario | localización de contenido, licenciamiento, cumplimiento |
| Geoproximity | distancia ± un sesgo que definís | mover tráfico entre Regiones gradualmente |
| Multivalue answer | hasta 8 registros sanos, devueltos al azar | distribución barata con conciencia de salud, no un balanceador de carga |
| IP-based | CIDR del cliente | enrutamiento según el ISP |

Referencia: [Choosing a routing policy](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html)

5. Entendé el **registro alias**, que es específico de Route 53 y aparece constantemente en las respuestas del examen:

Un alias es un registro A/AAAA que apunta a un recurso de AWS (ELB, distribución de CloudFront, endpoint de sitio web de S3, API Gateway, otro registro de Route 53) en lugar de a una IP o a un nombre. Importan dos propiedades: las consultas DNS contra registros alias hacia targets de AWS son **gratuitas**, y a diferencia de un CNAME un alias **puede existir en el ápice de la zona** (`example.com`, no solo `www.example.com`). Un CNAME en el ápice es ilegal en DNS; por eso "apuntá `example.com` a mi balanceador de carga" tiene exactamente una respuesta correcta.

> **Preguntas de verificación**
> **Q26.** Tenés que enviar el 5 % del tráfico de producción a un stack nuevo y el 95 % al viejo. ¿Qué política de enrutamiento?
> **Q27.** `example.com` (el ápice, sin `www`) debe resolver a un Application Load Balancer. ¿Qué tipo de registro creás, y por qué acá falla un CNAME?
> **Q28.** Un stack en espera en otra Región solo debería recibir tráfico si el primario deja de responder. ¿Qué política, y qué característica de Route 53 hace observable ese "deja de responder"?
> **Q29.** A los usuarios en Alemania hay que servirlos desde `eu-central-1` por motivos de residencia de datos — no porque sea más rápido. ¿Geolocation o latency-based? Justificá.

---

## Ejercicio 8 — El borde global: CloudFront y Global Accelerator

Ambos ponen la red de borde de AWS delante de tu carga de trabajo. Resuelven problemas distintos, y el examen los empareja con precisión para ver si sabés cuál es cuál.

### Pasos

1. Descargá la propia guía del examen y leé las cabeceras de respuesta — se sirve a través de CloudFront:

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

`x-cache: Hit from cloudfront` significa que el objeto se sirvió desde la **edge location** sin tocar el origen. `x-amz-cf-pop` nombra ese punto de presencia — el tuyo será distinto según la geografía. Ejecutalo dos veces; mirá cómo crece `age` y `x-cache` sigue siendo un hit.

2. Contrastá con una petición solo al origen para ver qué te compra el caché:

```bash
curl -sS -o /dev/null -w 'dns=%{time_namelookup}s connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
  https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
```

```
dns=0.021s connect=0.038s ttfb=0.061s total=0.312s
```

3. Inspeccioná el plano de control de Global Accelerator. Notá la Región fija en el comando — una pista fuerte sobre cómo está arquitecturado el servicio:

```bash
aws globalaccelerator list-accelerators --region us-west-2 \
  --query 'Accelerators[].{Name:Name,Ips:IpSets[0].IpAddresses,Dns:DnsName,Status:Status}'
```

```json
[]
```

La API de Global Accelerator solo está disponible en `us-west-2`, porque el recurso es global, no regional — el mismo patrón que Route 53, CloudFront, IAM y WAF (alcance global).

4. Aprendé la distinción:

| | Amazon CloudFront | AWS Global Accelerator |
|---|---|---|
| Trabajo principal | **cachear** y entregar contenido en el borde | **enrutar** TCP/UDP por el backbone de AWS hacia el endpoint óptimo |
| Protocolos | HTTP/HTTPS (+ WebSocket) | TCP y UDP, cualquier protocolo de aplicación |
| Cachea contenido | sí | no |
| Dirección de cara al cliente | nombre DNS de la distribución (`d111.cloudfront.net`) | **dos IP anycast estáticas** |
| Velocidad de failover | basado en DNS / grupo de orígenes | menos de un minuto, sin dependencia de DNS |
| Encaje típico | activos estáticos, video, aceleración de sitio completo, web protegida contra DDoS | gaming, VoIP, IoT, MQTT, APIs no-HTTP, "necesito IP estáticas y failover regional instantáneo" |

Ambos incluyen **AWS Shield Standard** sin costo adicional — por eso "protección contra DDoS sin cargo adicional" apunta a los servicios de borde.

Referencias: [What is Amazon CloudFront?](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html), [What is AWS Global Accelerator?](https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html)

> **Preguntas de verificación**
> **Q30.** ¿Qué prueba `x-cache: Hit from cloudfront` acerca de dónde vino la respuesta, y qué ahorró?
> **Q31.** Un juego multijugador basado en UDP necesita la menor latencia posible y dos IP estáticas que su hardware cliente tiene hardcodeadas. ¿CloudFront o Global Accelerator? Dá las dos razones.
> **Q32.** Una edge location y una Región son ambas "infraestructura de AWS". Decí para qué sirve cada una, en una oración cada una.
> **Q33.** Nombrá el servicio de protección contra DDoS incluido sin cargo adicional con CloudFront y Route 53.

---

## Ejercicio 9 — Conectar redes: peering, Transit Gateway, VPN, Direct Connect

### Pasos

1. Creá una segunda VPC que **se solape** con la primera, e intentá hacer peering. La lección es esta falla:

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

2. Hacelo correctamente con un rango sin solapamiento — el peering en sí es gratuito:

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

3. Agregá las rutas — el peering **no** crea rutas por vos, en ninguna de las dos VPC:

```bash
aws ec2 create-route --route-table-id "$RTB_PRIV" \
  --destination-cidr-block 10.43.0.0/16 --vpc-peering-connection-id "$PCX"
```

```json
{ "Return": true }
```

El peering es **no transitivo**: si A hace peering con B y B con C, A no puede alcanzar a C. Con *n* VPC, una malla completa necesita *n(n−1)/2* conexiones — 45 para 10 VPC. Ese número es todo el argumento de negocio de Transit Gateway.

4. Confirmá las API de conectividad híbrida sin aprovisionarlas. Usá `--dry-run` para ejercitar la llamada y los permisos gratis:

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

5. Verificá si existe algún circuito de Direct Connect (no va a haber — una conexión DX es una interconexión física encargada a través de un partner o de AWS, aprovisionada en semanas, no en segundos):

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

### El conjunto de decisión híbrida

| Servicio | Qué es | Aprovisionamiento | Ancho de banda | Cifrado | Se elige cuando |
|---|---|---|---|---|---|
| **VPC Peering** | enlace privado 1:1 entre dos VPC | minutos | nativo de la VPC | interno de AWS | pocas VPC, sin necesidad de transitividad |
| **Transit Gateway** | router regional hub-and-spoke para VPC, VPN y DX | minutos | muy alto | interno de AWS | muchas VPC / cuentas; se requiere enrutamiento transitivo |
| **Site-to-Site VPN** | túneles IPsec sobre la internet pública (2 túneles por redundancia) | minutos | ~1,25 Gbps por túnel | **sí, IPsec** | rápido de levantar, cifrado, sensible al costo; respaldo de DX |
| **Direct Connect** | circuito físico privado dedicado hacia una ubicación de AWS | **semanas** | 1/10/100 Gbps dedicado; 50 Mbps–10 Gbps hosted | **no por defecto** (agregar VPN o MACsec) | latencia baja y consistente, alto throughput sostenido, menor costo de transferencia de datos |
| **Client VPN** | endpoint OpenVPN gestionado para usuarios individuales | minutos | por conexión | sí | fuerza de trabajo remota que necesita llegar a la VPC |

Referencias: [VPC peering](https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html), [Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html), [Site-to-Site VPN](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html), [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html).

> **Preguntas de verificación**
> **Q34.** Dos requisitos aterrizan en tu escritorio: (a) el enlace tiene que estar operativo esta tarde, (b) el tráfico debe ir cifrado en tránsito. ¿VPN o Direct Connect?
> **Q35.** Una carga de trabajo financiera necesita latencia consistente y predecible y mueve 30 TB/día hacia AWS. ¿Qué conexión, y cuál es la única desventaja que tenés que plantear en la misma oración?
> **Q36.** Tenés 40 VPC en 12 cuentas que necesitan alcanzarse entre sí. ¿Por qué el peering en malla completa es la arquitectura equivocada, y qué lo reemplaza?
> **Q37.** El peering está `active` pero las instancias siguen sin poder alcanzar la VPC pareja. Nombrá las dos cosas que el peering *no* hace automáticamente.
> **Q38.** ¿Por qué "Direct Connect es más seguro porque va cifrado" es una afirmación incorrecta, y cuál es la afirmación correcta sobre la seguridad de DX?

---

## Ejercicio 10 — Diagnosticar la red

### Pasos

1. **`💲 BILLABLE (centavos)`** — Habilitá VPC Flow Logs hacia CloudWatch Logs. Los flow logs registran **metadatos sobre flujos IP — nunca la carga útil del paquete**:

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

2. Leé el formato de registro para saber qué puede y qué no puede responder una entrada de flow log:

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

Un registro de flujo publicado se ve así:

```
2 111122223333 eni-0a1b2c3d 10.42.10.55 52.94.236.248 49820 443 6 12 3721 1757000000 1757000060 ACCEPT OK
2 111122223333 eni-0a1b2c3d 198.51.100.9 10.42.0.31 40122 22 6 1 40 1757000000 1757000060 REJECT OK
```

`ACCEPT` / `REJECT` es el campo que te dice que un security group o una NACL descartó el flujo. Los destinos son CloudWatch Logs, Amazon S3 o Amazon Data Firehose.

3. **`💲 $0,10 por análisis`** — Opcional. Reachability Analyzer responde "¿puede A alcanzar a B?" **analizando estáticamente tu configuración** — no envía ningún paquete, así que el destino ni siquiera necesita estar en ejecución:

```bash
aws ec2 create-network-insights-path \
  --source "$IGW" --destination "$PRIV_A" --protocol tcp --destination-port 443 \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
```

Una vez analizado, un resultado de inalcanzable nombra el componente bloqueante exacto (`ANALYSIS_FINDING: SECURITY_GROUP` / `NETWORK_ACL` / `NO_ROUTE`) — mucho más rápido que leer reglas a mano.

4. Verificá la identidad de salida desde cualquier instancia que puedas lanzar — este endpoint devuelve la IP pública que ve AWS:

```bash
curl -s https://checkip.amazonaws.com
```

```
203.0.113.42
```

Desde una instancia en subnet privada detrás de un NAT Gateway, esto devuelve la **Elastic IP del NAT Gateway**, no la dirección privada de la instancia. Ese único comando distingue "el NAT funciona" de "el NAT está mal enrutado".

Referencias: [VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html), [Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html).

> **Preguntas de verificación**
> **Q39.** Un flow log muestra `REJECT` para TCP 443 entrante. ¿Qué dos componentes de la VPC podrían ser responsables, y qué *no* contiene el flow log que quizás esperabas?
> **Q40.** Nombrá los tres destinos soportados para VPC Flow Logs.
> **Q41.** ¿Por qué Reachability Analyzer puede diagnosticar un problema de conectividad de una instancia que está detenida?
> **Q42.** Desde una instancia en subnet privada, `curl https://checkip.amazonaws.com` devuelve `54.210.11.203`. ¿Qué te dice eso sobre el camino de salida?

---

## 11. Desmantelamiento

Ejecutá esto en orden; las dependencias importan.

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

Verificá que no sobrevive nada:

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
<summary><strong>Respuestas</strong> — clic para desplegar</summary>

### Ejercicio 1 — VPC y espacio de direcciones

**Q1.** Una subnet vive en **exactamente una Availability Zone** y no puede abarcar varias AZ. Como la VPC abarca todas las AZ pero cada subnet no, poner una capa en una sola subnet ata esa capa a una sola AZ — una falla de AZ tira abajo toda la capa. Necesitás al menos una subnet por capa *por AZ*, que es la razón por la que toda arquitectura de referencia muestra public-a/public-b y private-a/private-b.

**Q2.** **11 direcciones utilizables**, no 16. AWS reserva cinco direcciones en cada subnet sin importar el tamaño: la dirección de red, el router de la VPC (`.1`), el resolver DNS de Amazon (`.2`), una dirección reservada para uso futuro (`.3`) y la dirección de broadcast — el broadcast directamente no está soportado en una VPC. `/28` es la subnet más pequeña permitida justamente porque, si no, la reserva se consumiría todo.

**Q3.** Los rangos CIDR solapados hacen imposible el enrutamiento privado. No podés hacer VPC peering, no podés adjuntar ambas a la misma tabla de rutas de un Transit Gateway, y no podés levantar una Site-to-Site VPN hacia ese centro de datos, porque el router no puede decidir si `10.0.x.x` significa "local" o "remoto" — y la ruta `local` siempre gana. El CIDR primario de una VPC no se puede cambiar después de creada (solo podés *agregar* CIDR secundarios), así que la solución es reconstruir la VPC. Elegí los rangos a partir de un plan de IPAM documentado y a nivel de toda la organización antes de crear nada.

**Q4.** El más pequeño: **`/28`** (16 direcciones, 11 utilizables). El más grande: **`/16`** (65 536 direcciones). Cualquier cosa fuera de ese rango se rechaza con `InvalidVpc.Range`.

### Ejercicio 2 — IGW y route tables

**Q5.** (1) La route table asociada a la subnet debe contener una ruta para `0.0.0.0/0` (o el destino específico) que apunte a un **Internet Gateway adjunto**; (2) la instancia debe tener una **dirección IPv4 pública** — una IP pública autoasignada o una Elastic IP. Ninguna de las dos alcanza por sí sola. No existe un atributo de "subnet pública"; la publicidad es enteramente una propiedad de la route table.

**Q6.** **Sí.** La alcanzabilidad interna la provee la ruta implícita `local` que cubre el CIDR de la VPC (`10.42.0.0/16 → local`), que se crea automáticamente, no se puede borrar y no se puede sobrescribir. Funciona entre AZ y entre subnets. Borrar la ruta al IGW elimina únicamente la alcanzabilidad a internet. (Los security groups y las NACLs igual tienen que permitir el tráfico.)

**Q7.** Se aplica la **route table principal** — toda subnet sin asociación explícita cae en ella. En esta VPC la route table principal solo tiene la ruta `local`, así que la nueva subnet es efectivamente privada: sin internet ni de entrada ni de salida. Este es el valor por defecto seguro, y es la razón por la que dejar deliberadamente la route table principal sin ruta al IGW es un buen hábito — una asociación olvidada falla en cerrado y no en abierto.

**Q8.** Un Internet Gateway es un componente de VPC **a nivel de Región, escalado horizontalmente y redundante**, sin tope de ancho de banda ni afinidad de AZ — no hay nada que hacer altamente disponible. Un NAT Gateway se aprovisiona **en una subnet específica, en una AZ específica**; si esa AZ falla, las subnets privadas enrutadas a través de él pierden la salida. La alta disponibilidad exige entonces un NAT Gateway por AZ, cada uno referenciado por la route table privada propia de esa AZ.

### Ejercicio 3 — NAT y salida exclusiva

**Q9.** El NAT Gateway debe crearse en una subnet **pública** — una cuya route table tenga una ruta al IGW, porque el propio NAT Gateway necesita alcanzabilidad a internet. La route table que modificás es la de la subnet **privada**, agregando `0.0.0.0/0 → nat-...`. Poner el NAT Gateway en la subnet privada es la configuración rota clásica.

**Q10.** A favor del NAT Gateway: es **totalmente gestionado** (sin parches, sin SO, sin instancia que monitorear) y **escala automáticamente** hasta 100 Gbps sin ajuste de throughput; además es redundante dentro de su AZ. En contra: **costo** — un cargo por hora más el procesamiento por GB. Una instancia NAT puede salir más barata para cargas de trabajo diminutas o intermitentes y puede hacer cosas que un NAT Gateway no (redirección de puertos, actuar como bastión, filtrado a medida), al precio de que vos te hacés cargo de su disponibilidad, su techo de throughput y sus parches. (Una instancia NAT también requiere desactivar las verificaciones de origen/destino.)

**Q11.** Un **egress-only Internet Gateway**. El NAT existe para multiplexar muchas direcciones IPv4 privadas detrás de una pública; en AWS las direcciones IPv6 son todas enrutables globalmente, así que no hay nada que traducir. El egress-only IGW aporta la propiedad que falta — *salida exclusiva con estado* — permitiendo los flujos iniciados hacia afuera y sus respuestas mientras rechaza las conexiones iniciadas desde afuera. Es gratuito.

**Q12.** **Disponibilidad:** si falla la AZ del NAT Gateway, las subnets privadas de la *otra* AZ también pierden la salida a internet, porque su ruta apunta hacia la AZ caída — una falla de una AZ se convierte en una caída de dos AZ. **Costo:** el tráfico desde las subnets privadas de `us-east-1b` cruza un límite de AZ para llegar al NAT Gateway y vuelve a cruzarlo, incurriendo en **cargos de transferencia de datos entre AZ en ambas direcciones** además de la tarifa de procesamiento del NAT. La solución para ambos: un NAT Gateway por AZ, con route tables privadas por AZ.

### Ejercicio 4 — Security groups vs. NACLs

**Q13.**

| | Security group | Network ACL |
|---|---|---|
| Se adjunta a | la **ENI / instancia** (nivel de recurso) | la **subnet** (todos los recursos en ella) |
| Estado | **stateful** — el tráfico de retorno se permite automáticamente | **stateless** — el tráfico de retorno necesita su propia regla |
| Acciones de regla | **solo allow** | **allow y deny** |
| Evaluación | **todas las reglas**, cualquier coincidencia permite; sin orden | **ordenada por número de regla**, gana la primera coincidencia y se detiene |
| Valor por defecto al crearse | **sin reglas de entrada**, salida permitida a todo → no entra nada | **deniega todo** en ambas direcciones (solo la regla 32767) |
| Asociación | muchos SG por ENI | exactamente una NACL por subnet (una NACL puede cubrir muchas subnets) |

Fijate en la trampa: la NACL *por defecto* que viene con una VPC permite todo (regla 100 allow antes de la 32767 deny); una NACL *personalizada recién creada* deniega todo.

**Q14.** **No hace falta ninguna regla de salida.** Los security groups son stateful: como el flujo entrante en el 443 fue permitido, su respuesta sale automáticamente sin importar las reglas de egreso. Además, la regla de salida por defecto que permite todo sigue vigente. Agregar una regla de egreso equivalente es inofensivo pero delata un malentendido.

**Q15.** Una NACL es **stateless** — cada dirección se evalúa de forma independiente, así que la respuesta a una conexión entrante en el 443 es un flujo *separado, saliente* que hay que permitir explícitamente. Su puerto de destino es el **puerto efímero** del cliente, no el 443, así que la regla de salida debe permitir **TCP 1024–65535**. (El rango exacto varía según el SO del cliente — Linux normalmente 32768–60999, Windows 49152–65535, los NAT Gateway y ELB 1024–65535 — por eso 1024–65535 es el superconjunto seguro.)

**Q16.** Solo la **network ACL**, porque es la única de las dos que soporta reglas de **deny**. Agregás una entrada `deny` para `203.0.113.9/32` con un número de regla menor que cualquier regla de permiso que de otro modo coincidiría. Un security group no puede expresar esto: es solo de permitir, y como permite `0.0.0.0/0` en ese puerto, no hay forma de recortar una dirección. (En capa 7, AWS WAF delante de un ALB o de CloudFront es la otra respuesta correcta.)

**Q17.** Porque la regla expresa **identidad, no ubicación**. Las instancias detrás de un Auto Scaling group reciben IP privadas nuevas constantemente, pueden aterrizar en subnets nuevas, y el CIDR de su subnet puede contener después recursos que *no* son la capa web. Una referencia a un grupo significa "cualquier ENI que sea miembro de `SG_WEB`, esté donde esté" — no necesita actualización cuando la flota escala, es autodocumentada, y no puede otorgar acceso por accidente a una instancia no relacionada que casualmente comparta la subnet.

### Ejercicio 5 — VPC endpoints y PrivateLink

**Q18.** **Amazon S3 y Amazon DynamoDB** — esa es la lista completa. Los Gateway endpoints son **gratuitos**: sin cargo por hora ni cargo de procesamiento por GB.

**Q19.** Un **Gateway endpoint** modifica **route tables**: agrega una ruta cuyo destino es una **prefix list** gestionada por AWS (los rangos de IP públicas del servicio) y cuyo target es el endpoint. No se crea nada dentro de tus subnets. Un **Interface endpoint** crea una **elastic network interface con una dirección IP privada en cada subnet que selecciones** y — con DNS privado habilitado — una zona alojada privada de Route 53 que sobrescribe el nombre DNS público del servicio dentro de tu VPC. Las route tables quedan intactas.

**Q20.** Un **Gateway endpoint para S3**. Saca el tráfico de S3 del camino del NAT Gateway por completo, así que desaparecen tanto el **cargo de procesamiento de datos por GB del NAT Gateway** como la transferencia de datos a internet asociada, y el endpoint en sí es gratuito. Con 100 TB/mes, solo el procesamiento del NAT ronda los 100 000 GB × $0,045 ≈ $4 500/mes, eliminados.

**Q21.** Un **Interface VPC endpoint (AWS PrivateLink)** para `com.amazonaws.<region>.ssm` (en la práctica también `ssmmessages` y `ec2messages`). La bandera que hace verdadero el "sin cambios de código" es **`--private-dns-enabled`**: hace que `ssm.us-east-1.amazonaws.com` resuelva a la IP privada del endpoint dentro de la VPC, de modo que los SDK y las CLI sin modificar usan el camino privado sin ninguna sobreescritura de endpoint.

### Ejercicio 6 — Elastic Load Balancing

**Q22.** Un **Network Load Balancer**. Un NLB permite asignar una **Elastic IP estática por Availability Zone**, dándole al cliente un conjunto estable de direcciones para su lista blanca. Un ALB expone solo un nombre DNS; sus direcciones IP subyacentes las gestiona AWS y cambian a medida que escala, así que ponerlas en una lista blanca se rompería sin aviso.

**Q23.** Un **Application Load Balancer**, decidiendo en **capa 7 (aplicación)**. El enrutamiento por path requiere inspeccionar la línea de petición HTTP, que solo es visible una vez que la conexión se termina y se parsea como HTTP. Un NLB opera en capa 4 y nunca ve la ruta de la URL.

**Q24.** Un **Gateway Load Balancer**. Provee un único punto de entrada y de salida para el tráfico hacia una flota de appliances virtuales de terceros (firewalls, IDS/IPS, inspección profunda de paquetes), distribuyendo los flujos hacia ellos de forma transparente mediante el **protocolo GENEVE en el puerto 6081** y preservando el paquete original — los appliances ven el tráfico sin alterar.

**Q25.** Porque el valor que entrega un ELB es **disponibilidad más escala**, y una AZ es el límite de aislamiento de fallas de AWS. Tener los targets en una sola AZ significa que una falla de AZ elimina todos los targets a la vez; el balanceador de carga seguiría sano y no tendría nada sano a lo que enrutar. Los health checks le permiten dejar de mandar tráfico a un target caído, pero solo los targets en varias AZ le permiten sobrevivir a una *zona* caída.

### Ejercicio 7 — Route 53

**Q26.** **Weighted routing**, con pesos 5 y 95. Es el mecanismo estándar para releases canary, cortes blue/green y pruebas A/B, y la división se ajusta editando los pesos — sin cambios de infraestructura.

**Q27.** Un **registro alias** (tipo A, con el ALB como target del alias). Un CNAME es ilegal en el ápice de la zona: DNS prohíbe que un CNAME coexista con los registros SOA y NS que deben existir en el ápice. El registro alias es específico de Route 53, se devuelve a los clientes como un registro A, resuelve automáticamente a las direcciones actuales del ALB, y las consultas contra él hacia targets de AWS son **gratuitas**.

**Q28.** **Failover routing** (primario/secundario), y la característica que detecta la caída es un **health check de Route 53**. Route 53 sondea el endpoint primario desde múltiples ubicaciones globales; cuando el health check falla, el registro primario se retira de las respuestas y se devuelve el secundario. Como el secundario solo se usa ante una falla, este es el patrón de DR activo/pasivo.

**Q29.** **Geolocation routing.** El requisito es legal — *dónde está el usuario* — no de rendimiento. El enrutamiento por latencia manda al usuario a la Región que mida más rápido, que cualquier día podría ser `us-east-1`, violando el requisito de residencia. Geolocation enruta según el país/continente de origen de la consulta, que es exactamente la condición planteada. (Usá latency-based solo cuando el objetivo sea "lo más rápido posible".)

### Ejercicio 8 — Servicios de borde

**Q30.** Prueba que el objeto se sirvió desde una **edge location (punto de presencia) de CloudFront** cercana al cliente, desde su caché, **sin ninguna petición al origen**. Ahorró la ida y vuelta de latencia hacia la Región de origen y el cómputo y el costo de transferencia de datos de salida del origen para esa petición. `x-amz-cf-pop` nombra la edge location específica; `age` es cuánto tiempo lleva el objeto cacheado ahí.

**Q31.** **AWS Global Accelerator.** Dos razones: (1) CloudFront maneja **HTTP/HTTPS**, mientras que el juego habla **UDP** — Global Accelerator soporta TCP y UDP arbitrarios; (2) Global Accelerator provee **dos direcciones IP anycast estáticas** que los clientes pueden hardcodear, mientras que CloudFront solo da un nombre DNS. Además enruta por el backbone de AWS desde el edge más cercano y hace failover entre Regiones en segundos sin esperar TTL de DNS.

**Q32.** Una **edge location** es un punto de presencia global que termina las conexiones de los usuarios cerca del usuario y cachea o acelera contenido (CloudFront, Global Accelerator, Route 53, Shield/WAF). Una **Región** es un clúster físico de Availability Zones donde tus cargas de trabajo, tus datos y la mayoría de los servicios de AWS realmente se ejecutan. Edge = entrega y punto de entrada; Región = donde viven la aplicación y los datos.

**Q33.** **AWS Shield Standard**, que se habilita automáticamente para todos los clientes de AWS sin cargo adicional y defiende contra los ataques DDoS comunes de capa de red y de transporte (capa 3/4). (AWS Shield Advanced es el nivel pago, que agrega protección en capas superiores, acceso 24×7 a un equipo de respuesta y protección de costos.)

### Ejercicio 9 — Conectar redes

**Q34.** **AWS Site-to-Site VPN.** Se aprovisiona en minutos sobre la conexión a internet existente, y está **cifrada con IPsec por diseño** — ambos requisitos se satisfacen de forma nativa. Direct Connect no satisface ninguno: tarda semanas en aprovisionarse (es un circuito físico) y **no está cifrado por defecto**.

**Q35.** **AWS Direct Connect**, porque es un circuito privado dedicado que entrega **latencia consistente y predecible** y alto throughput sostenido, con tarifas de transferencia de datos por GB más bajas que la salida por internet a ese volumen. La desventaja a plantear en la misma frase: **tarda semanas o meses en aprovisionarse** (y una sola conexión es un punto único de falla — la resiliencia exige un segundo circuito, idealmente en una segunda ubicación, o una Site-to-Site VPN como respaldo). Agregá cifrado por separado si hace falta.

**Q36.** El peering es **no transitivo** y estrictamente 1:1, así que una malla completa necesita *n(n−1)/2* conexiones — 780 conexiones de peering para 40 VPC, cada una necesitando entradas de route table en ambos lados. Eso es operativamente inmanejable y choca contra los límites. El reemplazo es **AWS Transit Gateway**: cada VPC se adjunta una vez a un hub regional que hace enrutamiento transitivo, reduciendo 780 conexiones a 40 attachments, con route tables centralizadas para segmentación. También termina attachments de VPN y de Direct Connect en el mismo hub.

**Q37.** El peering **no** crea entradas de route table — tenés que agregar una ruta al CIDR de la pareja en *cada* route table de *ambos* lados que necesite el camino. Y **no** modifica los security groups ni las NACLs — el tráfico de la VPC pareja debe permitirse explícitamente (podés referenciar el ID de un security group de la VPC pareja en la misma Región). Un tercer detalle traicionero: la resolución DNS de los nombres de host privados de la pareja está desactivada hasta que la habilites en la conexión de peering.

**Q38.** El tráfico de Direct Connect **no está cifrado por defecto** — es un circuito privado y dedicado de capa 2/3, pero los datos que van por él viajan en claro. La afirmación correcta es que **no atraviesa la internet pública**, lo que da latencia predecible, ancho de banda consistente y una superficie de exposición reducida. Si se requiere cifrado — y para datos regulados normalmente se requiere — corrés una **VPN IPsec sobre la VIF pública de Direct Connect**, o usás **MACsec** en las conexiones dedicadas que lo soportan.

### Ejercicio 10 — Diagnósticos

**Q39.** Podría haberlo descartado un **security group** o una **network ACL** (o, específicamente en el caso de las NACLs, una regla de *salida* faltante para el tráfico de retorno, que aparece como un REJECT en el flujo de respuesta). El flow log **no** contiene la carga útil del paquete ni ningún contenido de capa de aplicación — registra únicamente metadatos del flujo IP (interfaz, dirección y puerto de origen/destino, protocolo, cuentas de paquetes y de bytes, ventana temporal, ACCEPT/REJECT). Tampoco puede decirte *cuál* de los dos mecanismos rechazó el flujo; para eso está Reachability Analyzer.

**Q40.** **Amazon CloudWatch Logs**, **Amazon S3** y **Amazon Data Firehose**.

**Q41.** Porque Reachability Analyzer hace **análisis estático de configuración**, no sondeo en vivo. Razona sobre las route tables, los security groups, las network ACLs, los gateways, los endpoints y la configuración de peering para determinar si un camino *podría* existir, y **no envía ningún paquete**. Eso significa que funciona sobre instancias detenidas y sobre infraestructura recién construida, y cuando un camino está bloqueado nombra el componente exacto responsable.

**Q42.** Te dice que el tráfico saliente a internet de la instancia está pasando por **source-NAT a través del NAT Gateway**, cuya Elastic IP es `54.210.11.203` — es decir, la ruta `0.0.0.0/0 → nat-...` de la route table privada está vigente y funcionando, y la instancia no tiene IP pública propia. También confirma que el NAT Gateway está en una subnet con una ruta al IGW funcionando, dado que la petición llegó a internet.

</details>