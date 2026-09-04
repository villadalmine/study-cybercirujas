# AWS Certified Cloud Practitioner — CLF-C02
# Dominio 3: Tecnología y servicios de la nube
## Enunciado de tarea 3.1 — Definir métodos de despliegue y operación en la nube de AWS

**Peso en el examen: 4,25 %** · Versión 1.0 · Itinerario avanzado SRE / Platform Architect

---

### 0. Lo que la guía del examen pide realmente

La guía del examen publicada acota el 3.1 a tres habilidades. Todo lo que sigue está organizado en torno a ellas, pero escrito con la profundidad que necesita un equipo de plataforma, no con la de una tarjeta de repaso.

| Ítem de la guía | Traducción práctica |
|---|---|
| *Conocimiento de las distintas formas de aprovisionar y operar en la nube de AWS* | Consola vs CLI vs SDK vs IaC vs abstracción gestionada (Beanstalk/Copilot); imperativo vs declarativo; la capa de estrategia de despliegue por encima |
| *Conocimiento de las distintas formas de acceder a los servicios de AWS* | La API de AWS es el único plano de control real; SigV4, la cadena de resolución de credenciales, IAM Identity Center, CloudShell, Session Manager |
| *Habilidad para determinar modelos de despliegue (nube, híbrido, on-premises) y opciones de conectividad (VPN, Direct Connect, internet público)* | Outposts / Local Zones / Wavelength / Snow / EKS-ECS Anywhere; internet vs Site-to-Site VPN vs Direct Connect vs PrivateLink |

---

## 1. El problema de producción: tu plano de control es una API, y cada persona es un cliente de ella

Partamos de un fallo que se repite en toda organización que adopta AWS a base de clics.

Un equipo levanta una VPC, un Application Load Balancer, un Auto Scaling group y una instancia RDS desde la Management Console durante una prueba de concepto de dos semanas. Funciona. Nueve meses después se le pide al mismo equipo que levante una pila idéntica en `eu-west-1` por motivos de residencia de datos, y que produzca evidencia para un auditor de que ambos entornos son equivalentes.

No pueden. No porque a AWS le falte una funcionalidad, sino por la forma de lo que construyeron:

* **Sin fuente de verdad.** El estado deseado existe únicamente como estado real. No hay nada contra lo que hacer un diff, así que "idéntico" es indemostrable.
* **Sin frontera de radio de impacto.** Una sesión de consola con `PowerUserAccess` es una shell sobre toda la cuenta. No hay un paso de revisión entre la intención y la mutación.
* **Sin reproducibilidad.** El idle timeout del ALB es de 47 segundos porque alguien lo cambió durante un incidente en marzo. Nadie lo sabe. No será de 47 segundos en la nueva región.
* **Sin rollback.** "Deshacer" es una persona recordando qué clics hizo.
* **Trabajo manual indiferenciado.** Cada entorno cuesta las mismas horas humanas que el primero.

La idea arquitectónica que el examen está evaluando —disfrazada de lista de métodos de acceso— es esta:

> **La Consola, la CLI, los SDK y CloudFormation son cuatro clientes de una misma cosa: la API de servicio de AWS, autenticada con AWS Signature Version 4.** Se diferencian en *quién o qué guarda la intención*, y por tanto en revisabilidad, reproducibilidad y radio de impacto. No se diferencian en lo que es posible.

Todo lo de este enunciado de tarea se deriva de ahí. Elegir un método de acceso es elegir dónde vive tu intención.

---

## 2. Los cuatro planos de acceso

### 2.1 Una sola API por debajo

Cuando arrastras un deslizador en la Consola, tu navegador emite una petición HTTPS firmada a un endpoint regional del servicio — `https://ec2.eu-west-1.amazonaws.com` — con una cabecera `Authorization` producida por SigV4. La CLI hace lo mismo. Boto3 hace lo mismo. CloudFormation hace lo mismo, en tu nombre, desde infraestructura del lado de AWS.

Puedes ver su forma cruda:

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

De ahí se derivan de inmediato dos consecuencias operativas, y ambas aparecen como incidentes:

1. **SigV4 firma una marca de tiempo.** Una firma se rechaza si el reloj del cliente se desvía más de ~5 minutos. Este es el ticket de "el SDK está roto" más común en VMs de larga vida y dentro de contenedores en hosts sin NTP.
2. **Cada llamada es un evento discreto, autorizado y registrado.** CloudTrail registra la identidad, la IP de origen, los parámetros y el resultado — para los clics de consola exactamente igual que para las llamadas de la CLI. No existe un "modo consola" que escape del registro de auditoría. Por eso "no sabemos quién lo cambió" siempre es un problema de retención o de consulta, nunca de disponibilidad del dato.

### 2.2 Tabla de compromisos: los cuatro planos

| Dimensión | Management Console | AWS CLI (v2) | SDK (Boto3, JS, Go, Java…) | IaC (CloudFormation / CDK / Terraform) |
|---|---|---|---|---|
| **Modelo** | Interactivo, imperativo | Programado en scripts, imperativo | Programático, imperativo | **Declarativo** (CDK: *síntesis* imperativa de salida declarativa) |
| **Dónde vive la intención** | En la cabeza de una persona | En un script de shell o un runbook | En el código de la aplicación | **En el control de versiones** |
| **Revisable antes de ejecutar** | No | Débilmente (revisión del script) | Sí (revisión de código) | Sí — el plan / change set es revisable **y generado por máquina** |
| **Reproducible entre cuentas/regiones** | No | Parcialmente (scripts parametrizados) | Parcialmente | Sí, por diseño |
| **Drift visible** | No | No | No | Sí (`detect-stack-drift`, `terraform plan`) |
| **Rollback** | Manual, de memoria | Manual, script inverso | Manual | Automático ante fallo (CFN), o revirtiendo el commit |
| **Radio de impacto** | Toda la sesión, cuenta entera | Cuenta entera, un comando | Cuenta entera | Acotado por la stack |
| **Valor de descubrimiento / aprendizaje** | **El más alto** — ves la forma del servicio | Medio | Bajo | Bajo |
| **Aptitud como break-glass** | Alta (con MFA + CloudTrail) | Alta | Baja | **Baja — nunca es la vía de emergencia** |
| **Latencia hasta el primer resultado** | Segundos | Segundos | Minutos | De minutos a horas (primera escritura) |
| **Adecuado para** | Exploración, lecturas puntuales, forense de incidentes, habilitación de servicios | Pegamento de automatización, pasos de CI, operaciones masivas, diagnóstico | Aplicaciones que llaman a AWS como dependencia | **Todo lo que mañana deba existir igual que hoy** |

**La regla de producción que implica esta tabla:** la Consola y la CLI son para *leer* y para *excepciones*; IaC es para el *estado*. Un equipo de plataforma que invierta esto acaba con el problema de los nueve meses del §1.

### 2.3 Credenciales: la cadena de resolución, y por qué muerde

La CLI y todos los SDK resuelven credenciales mediante una cadena ordenada. Conocer el orden es la diferencia entre un diagnóstico de 30 segundos y una tarde entera.

| Orden | Origen | Uso típico |
|---|---|---|
| 1 | Opciones explícitas de línea de comandos / parámetros del constructor | Pruebas, casos puntuales |
| 2 | Variables de entorno (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) | Runners de CI |
| 3 | Assume-role / web-identity en `~/.aws/config` (`role_arn`, `source_profile`, `web_identity_token_file`) | Cross-account, IRSA en EKS |
| 4 | Token SSO cacheado de IAM Identity Center (`sso_session`) | **Acceso humano — el valor por defecto correcto** |
| 5 | Fichero de credenciales compartido `~/.aws/credentials` | Claves de larga vida heredadas |
| 6 | Proveedor de credenciales de contenedor (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`) | Roles de tarea de ECS |
| 7 | Instance Metadata Service (IMDSv2) | Instance profiles de EC2 |

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

Fíjate en lo que demuestra ese ARN: la persona está usando **credenciales temporales de un rol asumido**, no una access key. No hay ningún secreto de larga vida en el portátil que pueda filtrarse. Ese es el estado objetivo; los usuarios de IAM con access keys estáticas son justo aquello de lo que estás migrando.

En EC2, el equivalente es el instance profile, obtenido mediante IMDSv2 (primero el token, que es lo que derrota a la clase de ataques SSRF que asolaba a IMDSv1):

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

**Encuadre relevante para el examen:** *AWS CloudShell* es la quinta vía de acceso — una shell en el navegador, preautenticada con la identidad de tu sesión de consola, con la CLI, Python y Node preinstalados y ~1 GB de almacenamiento persistente en `$HOME` por región. Es gratuita, y es la respuesta correcta a "ejecutar un comando de la CLI sin instalar nada ni emitir una clave".

---

## 3. Modelos de despliegue: nube, híbrido, on-premises

### 3.1 Las definiciones que quiere el examen

| Modelo | Definición | Realización en AWS |
|---|---|---|
| **Nube / cloud-native** | Todas las partes de la aplicación se despliegan en la nube; la aplicación fue construida para servicios de nube, o migrada a ellos | Todo en regiones y AZ |
| **Híbrido** | Los recursos de nube están conectados a la infraestructura on-premises; la carga de trabajo abarca ambas | Direct Connect / VPN + Outposts, Storage Gateway, ECS/EKS Anywhere, DataSync |
| **On-premises / nube privada** | Recursos desplegados en tu propio centro de datos usando virtualización y herramientas de gestión de recursos; "on-premises" en el marketing de AWS suele significar *infraestructura de AWS en tu centro de datos* | **AWS Outposts**, familia Snow, ECS Anywhere, EKS Anywhere |

### 3.2 El portafolio de edge e híbrido, con los criterios de decisión que de verdad los diferencian

| Servicio | Qué es | Propiedad de latencia / localidad | Plano de control | Elígelo cuando |
|---|---|---|---|---|
| **Región AWS + AZ** | Lo predeterminado | ≥ decenas de ms desde la mayoría de las metrópolis | En la región | Predeterminado para todo |
| **AWS Local Zones** | Extensión de la región en un área metropolitana | Milisegundos de un dígito hacia esa metrópoli | Región padre | Renderizado multimedia, gaming en tiempo real, EDA — limitado por latencia, sin exigencia de residencia de datos |
| **AWS Wavelength** | Cómputo dentro de la red 5G de un operador | La latencia más baja hacia dispositivos móviles | Región padre | Inferencia en el edge móvil, AR/VR, vehículos conectados |
| **AWS Outposts (rack, 42U)** | Racks gestionados por AWS **en tu centro de datos** | Cero salto WAN; los datos se quedan físicamente donde están | **En la región padre**, a través del *service link* | Ley de residencia de datos, latencia submilisegundo hacia sistemas on-prem, vecinos legacy atados a licencias |
| **AWS Outposts (servidores, 1U/2U)** | La misma idea, formato pequeño | Igual que arriba | Región padre | Tienda minorista / sucursal / planta de fábrica |
| **AWS Snowball Edge** | Dispositivo ruggerizado para transferencia masiva + cómputo en el edge | Offline | Se pide desde la región | Migración de petabytes donde la WAN tardaría meses; edge desconectado/táctico |
| **AWS Storage Gateway** | Appliance on-prem que presenta el almacenamiento en la nube como NFS/SMB/iSCSI/VTL | Lecturas desde caché local | En la región | Destino de backup, recurso compartido de ficheros con capa en la nube, sustitución de cinta |
| **ECS Anywhere / EKS Anywhere** | Orquestación de contenedores de AWS sobre tu propio hardware | Tu hardware | ECS Anywhere: en la región. **EKS Anywhere: local, funciona desconectado** | Estandarizar la operación de contenedores entre la nube y la planta |
| **VMware Cloud on AWS** | SDDC de VMware sobre EC2 bare metal | En la región | VMware + AWS | Lift-and-shift de un parque vSphere sin replataformar *(la propiedad comercial pasó a Broadcom en 2024 — verifica la disponibilidad actual antes de diseñar sobre ello)* |

**El dato de Outposts que se examina y se malinterpreta:** un Outpost *no* es una nube privada desconectada. Requiere una ruta de red fiable y cifrada — el **service link** — de vuelta a su región padre, porque su plano de control vive allí. Si pierdes el enlace, las instancias EC2 existentes en el rack siguen funcionando, pero no puedes lanzar, terminar ni modificar. Si necesitas un plano de control que sobreviva a una WAN cortada, eso es **Snowball Edge** o **EKS Anywhere**, no Outposts.

El corolario importa para la planificación de capacidad: la capacidad de un Outpost está fijada al tamaño del rack que pediste. La elasticidad —la razón entera por la que viniste a la nube— se detiene en tu muelle de carga. Diseña las cargas de trabajo de Outposts con una vía de desbordamiento explícita hacia la región padre.

---

## 4. Modelos de aprovisionamiento: la escalera de abstracción

Hay cinco peldaños. Toda herramienta de despliegue de AWS se sitúa en uno de ellos, y el examen los distingue por *cuánto describes tú*.

| Peldaño | Modelo | Servicios de AWS | Tú describes | AWS decide |
|---|---|---|---|---|
| 0 | **Manual** | Management Console | Cada clic | Nada |
| 1 | **Scripts / imperativo** | AWS CLI, SDK | Cada llamada a la API, en orden | Nada |
| 2 | **IaC declarativa** | **CloudFormation**, Terraform | El estado final deseado, recurso a recurso | El orden, el grafo de dependencias, el rollback |
| 3 | **IaC con un lenguaje de programación** | **AWS CDK**, AWS SAM | Constructs e intención; *sintetiza* CloudFormation | Todo lo del peldaño 2, más valores por defecto sensatos para los recursos que no mencionaste |
| 4 | **Abstracción gestionada (PaaS)** | **Elastic Beanstalk**, AWS App Runner, AWS Copilot, AWS Amplify | "Aquí está mi código" | La VPC, el balanceador de carga, el Auto Scaling group, los health checks, la estrategia de despliegue |

La escalera no es un modelo de madurez — es un compromiso entre control y esfuerzo. El peldaño 4 es adecuado para una aplicación web sin estado propiedad de un equipo de dos personas; es inadecuado para una landing zone multicuenta regulada. Las plataformas reales usan varios peldaños a la vez: CloudFormation/CDK para el sustrato de red y seguridad, Beanstalk o App Runner para los servicios de los equipos de producto por encima.

### 4.1 La pila de referencia completa (CloudFormation, peldaño 2)

Esta es una plantilla completa, desplegable y sintácticamente válida: VPC en dos AZ, subredes públicas y privadas, IGW, NAT, un ALB de cara a internet, un launch template con IMDSv2 forzado, un Auto Scaling group con target-tracking, y un rol de instancia que habilita Session Manager en lugar de SSH.

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

Despliégala y observa que es CloudFormation —no tú— quien calcula el orden de dependencias:

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

### 4.2 Change sets: el paso de revisión que la Consola no te da

Nunca ejecutes `deploy` a ciegas contra producción. Un change set es el plan:

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

`Replacement: True` sobre un recurso con estado —una instancia RDS, un volumen EBS— es la señal para detenerse y leer. Esa columna es la razón de ser de los change sets.

### 4.3 Peldaño 3: la misma pila en CDK

CDK es un *sintetizador*: emite CloudFormation. Su valor está en que los valores por defecto son opinados y correctos, y en que los bucles son bucles de verdad.

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

Fíjate en que ~40 líneas de CDK producen ~400 líneas de CloudFormation. Ese apalancamiento es todo el argumento a favor del peldaño 3 — y también todo su riesgo: tienes que ser capaz de leer la plantilla sintetizada cuando se comporte mal (`cdk synth`).

### 4.4 Peldaño 4: Elastic Beanstalk, y por qué sigue importando

Beanstalk es el PaaS canónico del examen. Subes código; él aprovisiona las instancias EC2, el ALB, el Auto Scaling group, los security groups, las alarmas de CloudWatch y un panel de salud — y tú conservas acceso completo a esos recursos subyacentes. **Solo pagas por los recursos subyacentes; Beanstalk en sí es gratuito.**

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

`leader_only: true` es el detalle que conviene interiorizar: hace que exactamente una instancia del grupo ejecute la migración de la base de datos, que es la diferencia entre un despliegue y una condición de carrera.

---

## 5. Estrategias de despliegue — la mitad operativa de "desplegar y operar"

El aprovisionamiento pone los recursos ahí. *Desplegar* es cómo el código nuevo reemplaza al viejo sin caída de servicio. Beanstalk y CodeDeploy exponen la misma familia de estrategias; el examen evalúa los compromisos.

| Estrategia | Capacidad durante el despliegue | Coste extra | Caída de servicio | Velocidad de rollback | ¿Versiones mezcladas en producción? | Radio de impacto |
|---|---|---|---|---|---|---|
| **All at once** | Toda la flota rota | Ninguno | **Sí** | Lenta — redesplegar la versión anterior | No | 100 % |
| **Rolling** | Reducida (el lote queda fuera de servicio) | Ninguno | No | Lenta — avanzar/retroceder lote a lote | Sí | 1 lote |
| **Rolling with additional batch** | Completa, mantenida | Un lote extra, temporalmente | No | Lenta | Sí | 1 lote |
| **Immutable** | Completa + un grupo nuevo en paralelo | **~2×, brevemente** | No | **Rápida — terminar el ASG nuevo** | Brevemente | Solo las instancias nuevas |
| **Traffic splitting / canary** | Completa + flota canary | Flota canary extra | No | **La más rápida — desplazar el peso a 0 %** | Sí, por diseño | % configurable |
| **Blue/green (dos entornos)** | Dos entornos completos | **2×** durante el solape | No | **La más rápida — revertir el swap de DNS / listener** | No | 0 % si el swap es atómico |

**La lectura SRE de esa tabla:** el valor por defecto correcto para un servicio en producción es *immutable* o *blue/green*. Ambos reemplazan instancias en lugar de mutarlas, lo que significa que el artefacto que pasó las pruebas es byte a byte el artefacto que sirve tráfico. La mutación in situ ("rolling") deriva: un `dnf update` que funcionó en marzo y falla en septiembre te deja una flota donde la mitad de los hosts no son lo que crees.

**La salvedad de blue/green que le cuesta una caída a los equipos:** si el swap es un intercambio de CNAME de DNS (que es lo que hace `swap-environment-cnames` de Beanstalk), los clientes que cachean DNS más allá del TTL siguen llegando al entorno viejo. No termines el entorno azul de inmediato. Si el swap es un cambio de regla de listener del ALB (blue/green de CodeDeploy para EC2/ECS), es genuinamente atómico a nivel de conexión y el problema del DNS desaparece.

### 5.1 CodeDeploy: `appspec.yml` para EC2/on-premises

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

`scripts/healthcheck.sh` — el hook que hace posible el rollback automático. Si termina con estado distinto de cero, CodeDeploy da la instancia por fallida y, con una configuración de rollback, revierte todo el deployment group:

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

### 5.2 CodeDeploy para Lambda: canary como una cadena de configuración

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

`LambdaCanary10Percent5Minutes` significa: el 10 % de las invocaciones va a la versión 42 durante cinco minutos, y después se desplaza el 100 %. Si una alarma de CloudWatch del deployment group se dispara durante esa ventana, CodeDeploy devuelve el alias a la versión 41 automáticamente. Ese es el mecanismo completo de un despliegue seguro, expresado como una sola cadena.

---

## 6. Opciones de conectividad: internet público, VPN, Direct Connect, PrivateLink

### 6.1 La comparación sobre la que se construye el examen

| | **Internet público** | **AWS Site-to-Site VPN** | **AWS Client VPN** | **AWS Direct Connect (DX)** | **AWS PrivateLink / endpoints de VPC** |
|---|---|---|---|---|---|
| **Qué conecta** | Cualquier cosa ↔ endpoints públicos de AWS | Tu centro de datos ↔ VPC/TGW | Dispositivo de un usuario individual ↔ VPC | Tu centro de datos ↔ AWS, sobre fibra privada | VPC ↔ un servicio de AWS o de un partner, de forma privada |
| **Transporte** | Internet | IPsec **sobre internet** | TLS basado en OpenVPN sobre internet | **Circuito físico dedicado** vía una ubicación DX | Backbone de AWS, mediante una ENI en tu subred |
| **Cifrado en tránsito** | TLS, responsabilidad de la aplicación | **IPsec, incorporado** | TLS, incorporado | **Ninguno por defecto** — añade MACsec o IPsec por encima | TLS hacia el endpoint del servicio |
| **Ancho de banda** | Lo que te dé tu ISP | ~1,25 Gbps **por túnel**; escala con múltiples VPN + ECMP en Transit Gateway | Por usuario | Dedicado: 1 / 10 / 100 Gbps. Hosted: 50 Mbps – 25 Gbps | Limitado por el rendimiento del endpoint, escala automáticamente |
| **Perfil de latencia** | Variable, best-effort | Variable (va por internet) + sobrecarga criptográfica | Variable | **Consistente** — el verdadero argumento de venta | Dentro de la región, muy baja |
| **Tiempo de aprovisionamiento** | Inmediato | **Minutos** | Minutos | **Semanas a meses** (cross-connect, LOA-CFA, partner) |Minutos |
| **Forma del coste** | Solo transferencia de datos de salida | Bajo coste por hora + transferencia de salida | Hora de endpoint + hora de conexión | Hora de puerto + **tarifa reducida de transferencia de salida** | Hora de endpoint por AZ + datos procesados (los gateway endpoints para S3/DynamoDB son **gratuitos**) |
| **SLA** | Ninguno | 99,95 % (túnel) | — | 99,9 % con una conexión; **99,99 % con dos conexiones en ubicaciones/dispositivos distintos** | — |
| **¿El tráfico sale de internet?** | No | No (cifrado, pero enrutado por internet) | No | **Sí** | **Sí** |
| **Elígelo cuando** | Web pública, desarrollo, baja sensibilidad | Necesitas conectividad privada *hoy*, o como respaldo de DX | Acceso de personal remoto a recursos de la VPC | Volumen alto sostenido, latencia consistente, reducción del coste de egreso, regulación | Sacar el tráfico de servicio del IGW/NAT por completo |

### 6.2 Los dos hechos que se convierten en respuestas erróneas

**Direct Connect no está cifrado.** Es privado —el tráfico no atraviesa internet público— pero "privado" no es "confidencial". Si tu régimen de cumplimiento exige cifrado en tránsito, añades una capa: MACsec (disponible en conexiones dedicadas de 10 Gbps y 100 Gbps) o una Site-to-Site VPN IPsec corriendo sobre una VIF pública. Las preguntas de examen que emparejan "Direct Connect" con "debe estar cifrado" evalúan exactamente esto.

**Una única conexión Direct Connect es un punto único de fallo con un tiempo de reparación de meses.** La respuesta estándar, y correcta en el examen, para la resiliencia es: **Site-to-Site VPN como ruta de respaldo de Direct Connect**. Cuesta céntimos por hora, se aprovisiona en minutos, y BGP preferirá la ruta de DX mientras esté activa y hará failover a la VPN cuando no lo esté. La alternativa de mayor coste es una segunda conexión DX en una ubicación DX distinta.

### 6.3 Las tres interfaces virtuales de Direct Connect

| Tipo de VIF | Termina en | Alcanza | Uso |
|---|---|---|---|
| **Private VIF** | Virtual Private Gateway, o un Direct Connect Gateway | **IPs privadas de tu VPC** | El caso normal: servidores on-prem hablando con EC2/RDS |
| **Public VIF** | Endpoints públicos de AWS | **Servicios públicos de AWS** (S3, DynamoDB, endpoints públicos de API) sobre el circuito DX, usando IPs públicas; AWS anuncia todos sus prefijos públicos por BGP | Ingesta masiva a S3 sin pasar por internet; transportar una VPN IPsec |
| **Transit VIF** | Direct Connect Gateway → **AWS Transit Gateway** | Muchas VPC, muchas regiones, a través de un único hub | Landing zones multi-VPC / multicuenta |

### 6.4 Aprovisionar conectividad desde la CLI

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

Que ambos túneles estén DOWN justo después de crearlos es normal — el lado del cliente aún no está configurado. Descarga la configuración específica del fabricante y entrégasela al equipo de redes:

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

Después de configurar el peer:

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

Direct Connect, inspeccionado:

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

Dos conexiones, dos ubicaciones distintas (`EqDC2` e `Interxion-MAD1`) — eso es lo que compra el SLA del 99,99 %. Dos conexiones a la *misma* ubicación solo compran redundancia de dispositivo.

### 6.5 PrivateLink: sacar internet del camino por completo

Los gateway endpoints (S3, DynamoDB) son entradas de tabla de rutas y no cuestan nada. Los interface endpoints son ENI en tus subredes, tarificados por hora y AZ más datos procesados. Añadir el trío de SSM es lo que permite gestionar instancias privadas **sin ninguna NAT gateway**:

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

## 7. Operar: acceso administrativo sin bastión ni par de claves

La respuesta moderna a "cómo consigo una shell en esa instancia" es **AWS Systems Manager Session Manager**. No necesita regla de entrada en el security group, ni IP pública, ni clave SSH, ni host bastión, porque el agente de SSM abre una conexión *saliente*. Cada sesión está autorizada por IAM y registrada en CloudWatch Logs o S3.

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

Operaciones sobre toda la flota sin ninguna shell — este es el patrón que escala:

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

Capacidades relacionadas de Systems Manager que el examen espera que sepas ubicar: **Patch Manager** (parcheo programado del SO con informes de cumplimiento), **State Manager** (aplicación continua de la configuración), **Parameter Store** (configuración y secretos, capa estándar gratuita), **Automation** (runbooks), **Fleet Manager** (administración de flota desde el navegador).

---

## 8. Verificación y diagnóstico de fallos

### 8.1 Escalera de verificación — ejecuta esto en orden después de cada despliegue

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

El drift es la comprobación que distingue una práctica de IaC real de una decorativa. `IN_SYNC` con `Drifted: 0` es la afirmación "la plantilla sigue siendo la verdad". Cuando no lo es:

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

Ahí está — el idle timeout de 47 segundos del §1, encontrado por una llamada gratuita a la API en lugar de por una caída.

### 8.2 Catálogo de fallos

| Síntoma | Causa más probable | Diagnóstico | Solución |
|---|---|---|---|
| `An error occurred (RequestTimeTooSkewed)` | Reloj del cliente desviado > ~5 min; SigV4 firma una marca de tiempo | `date -u`, `chronyc tracking` | Habilitar NTP / el Amazon Time Sync Service (`169.254.169.123`) |
| `InvalidClientTokenId` | La access key no existe, o partición equivocada (`aws-cn`, `aws-us-gov`) | `aws sts get-caller-identity` | Corregir el perfil / la clave |
| `ExpiredToken` / `The security token included in the request is expired` | Sesión de SSO o STS caducada | `aws sts get-caller-identity` | `aws sso login --sso-session corp` |
| `AccessDenied` en una operación de *stack* pero no en la API directamente | Es el **rol de la stack** (`--role-arn`), no tu identidad, lo que usa CloudFormation | Leer el `ResourceStatusReason` de los `StackEvents` | Otorgar permisos al service role, o quitar `--role-arn` |
| `Requires capabilities: [CAPABILITY_IAM]` | La plantilla crea recursos IAM | — | Añadir `--capabilities CAPABILITY_IAM` (o `CAPABILITY_NAMED_IAM` para roles con nombre) |
| Stack atascada en `ROLLBACK_COMPLETE`, actualizaciones rechazadas | Falló una *creación*; este estado solo permite borrar | `describe-stack-events` buscando el primer `CREATE_FAILED` | Borrar y recrear. Para depurar la próxima vez: `--disable-rollback` o `--on-failure DO_NOTHING` |
| `CREATE_FAILED … WaitCondition timed out. Received 0 conditions when expecting 2` | `cfn-signal` nunca se ejecutó — el UserData falló | `aws ssm start-session` → `sudo cat /var/log/cloud-init-output.log` | Arreglar el UserData; añadir `set -x`; revisar el egreso para la instalación de paquetes |
| Targets `unhealthy`, `Health checks failed with these codes: [404]` | Ruta del health check incorrecta, o app en otro puerto | `describe-target-health`; curl desde la instancia | Alinear `HealthCheckPath` / `Port` |
| Targets `unused`, `Target is in an Availability Zone that is not enabled for the load balancer` | Subredes del ASG en una AZ que el ALB no cubre | Comparar `VPCZoneIdentifier` del ASG con `Subnets` del ALB | Añadir la AZ al ALB |
| La instancia no aparece en `describe-instance-information` (Session Manager falla) | Falta `AmazonSSMManagedInstanceCore`, no hay egreso por 443, o no hay interface endpoints de SSM en una subred privada | `sudo systemctl status amazon-ssm-agent`; `sudo cat /var/log/amazon/ssm/amazon-ssm-agent.log` | Adjuntar la política gestionada; añadir los endpoints `ssm`, `ssmmessages`, `ec2messages` |
| Túnel VPN `DOWN`, `IPSEC IS DOWN`, la fase 1 nunca completa | Desajuste de versión de IKE / grupo DH / PSK; UDP 500 y 4500 bloqueados en el firewall del cliente | `describe-vpn-connections … VgwTelemetry`; logs del peer | Reaplicar literalmente la configuración de dispositivo generada |
| Túnel VPN `UP` pero `AcceptedRouteCount: 0` | Sesión BGP levantada, sin prefijos anunciados; o **VPN solo estática sin tráfico interesante** | `show bgp summary` en el peer | Anunciar prefijos; para VPN estáticas, generar tráfico o habilitar keepalives DPD |
| Interfaz virtual de DX `down`, BGP en `idle` | Desajuste de etiqueta VLAN 802.1Q, IPs de peer erróneas, ASN incorrecto, o el cross-connect no está parcheado | `describe-virtual-interfaces`; pedir al colo una lectura de nivel óptico | Corregir VLAN/ASN; escalar el cross-connect |
| El tráfico funciona sobre DX con paquetes pequeños, se cuelga en transferencias grandes | **Desajuste de MTU** — jumbo frames (9001 en private VIF, 8500 vía Transit Gateway) no consistentes de extremo a extremo | `ping -M do -s 8972 <target>` | Uniformizar la MTU, o aplicar clamping de MSS |
| Despliegue `Immutable` de Beanstalk falla: *"Failed to create the temporary Auto Scaling group"* | Límite de instancias EC2 o capacidad de EIP/subred — immutable necesita una **segunda flota completa** | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | Subir la cuota, o usar `RollingWithAdditionalBatch` |
| Swap blue/green hecho, el entorno viejo sigue recibiendo tráfico | Caché de TTL de DNS en el lado del cliente | `dig +short <cname>` desde un cliente | Esperar a que expire el TTL antes de terminar el azul; preferir swaps basados en listener |

### 8.3 Leer los eventos de la stack — el primer fallo es el único que importa

```
$ aws cloudformation describe-stack-events --stack-name plat-dev \
    --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceStatusReason])' \
    --output text
2026-09-04T09:12:41.883000+00:00	AutoScalingGroup	Received 0 SUCCESS signal(s) out of 2. Unable to satisfy 100 percent MinSuccessfulInstancesPercent requirement
2026-09-04T09:12:44.117000+00:00	plat-dev	The following resource(s) failed to create: [AutoScalingGroup].
```

CloudFormation informa de la *cascada*; `reverse()` pone la causa raíz primero. Después ve a la instancia, no a la plantilla:

```
$ aws ssm start-session --target i-0d18e4a7fb932c065
sh-5.2$ sudo tail -20 /var/log/cloud-init-output.log
+ dnf -y install python3 amazon-cloudwatch-agent
Amazon Linux 2023 repository            0.0  B/s |   0  B     00:30
Errors during downloading metadata for repository 'amazonlinux':
  - Curl error (28): Timeout was reached for https://cdn.amazonlinux.com/al2023/core/mirrors/latest/x86_64/mirror.list
Error: Failed to download metadata for repo 'amazonlinux'
```

Eso no es un problema de CloudFormation, ni del ASG, ni del health check. Es un problema de **tabla de rutas**: las subredes privadas no tienen camino hacia la NAT gateway. La cadena de señales —`CREATE_FAILED` → no hay `cfn-signal` → timeout de `dnf` → ruta por defecto ausente— es la disciplina de diagnóstico de la que trata realmente este enunciado de tarea.

---

## 9. Trampas del examen: las distinciones que deciden preguntas

| Si la pregunta dice… | La respuesta es… | Porque |
|---|---|---|
| "Infraestructura repetible y versionada" | **AWS CloudFormation** | La IaC declarativa es la frase que lo define |
| "Definir infraestructura usando un lenguaje de programación conocido" | **AWS CDK** | El lenguaje es el discriminador |
| "Subir código; AWS se encarga de la capacidad, el balanceo, el escalado y la monitorización de salud; yo mantengo el control de los recursos" | **AWS Elastic Beanstalk** | La descripción clásica de un PaaS; **Beanstalk en sí es gratuito** |
| "Desplegar una app web en contenedor con la mínima carga operativa, sin orquestación que gestionar" | **AWS App Runner** | Un paso más allá de Beanstalk en la escalera de abstracción |
| "Ejecutar infraestructura y servicios de AWS **en mi propio centro de datos**" | **AWS Outposts** | La única respuesta de "hardware de AWS on-prem" |
| "Latencia de milisegundos de un dígito hacia usuarios finales en un área metropolitana concreta" | **AWS Local Zones** | Metropolitano, no de operador |
| "La menor latencia hacia dispositivos **móviles 5G**" | **AWS Wavelength** | Red del operador |
| "Mover petabytes donde la red tardaría demasiado" | **AWS Snowball Edge** | Transferencia masiva offline |
| "Enlace privado, dedicado y de rendimiento consistente hacia AWS" | **AWS Direct Connect** | Circuito físico |
| "Conectividad privada a AWS, **cifrada**, y la necesito esta semana" | **AWS Site-to-Site VPN** | DX tiene plazo de entrega y no cifra |
| "Garantizar alta disponibilidad para nuestro enlace Direct Connect al menor coste" | **Añadir una Site-to-Site VPN como respaldo** | Un segundo DX es la opción cara |
| "Empleados remotos individuales necesitan llegar a recursos de la VPC" | **AWS Client VPN** | Cliente, no site-to-site |
| "Llegar a S3 sin atravesar internet, sin coste adicional" | **Gateway VPC endpoint** | Los interface endpoints cuestan por hora; los gateway endpoints (S3/DynamoDB) son gratuitos |
| "Administrar instancias EC2 sin abrir el puerto 22 ni mantener un bastión" | **Systems Manager Session Manager** | Agente solo saliente, autorizado por IAM, registrado |
| "Ejecutar comandos de la CLI desde un navegador sin instalar nada localmente" | **AWS CloudShell** | Shell preautenticada en el navegador |
| "¿Quién cambió este recurso, y cuándo?" | **AWS CloudTrail** | Actividad de la API, incluidos los clics de la Consola |
| "Desplegar con la capacidad de revertir al instante, a cambio de mantener dos entornos" | **Blue/green** | El compromiso coste/rollback de la tabla de estrategias |

---

## 10. Referencias

**Guía del examen (alcance autoritativo para este enunciado de tarea)**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Página de la certificación AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Métodos de acceso y la API de AWS**
- AWS Management Console — https://docs.aws.amazon.com/awsconsolehelpdocs/latest/gsg/getting-started.html
- Guía del usuario de AWS CLI v2 — https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html
- Guía de referencia de SDK y herramientas de AWS (cadena de proveedores de credenciales) — https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
- Proceso de firma Signature Version 4 — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
- Guía del usuario de AWS CloudShell — https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html
- AWS IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- Metadatos de instancia e IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html

**Infraestructura como código y despliegue**
- Guía del usuario de AWS CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Anatomía de una plantilla de CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-anatomy.html
- Change sets de CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html
- Detección de cambios de configuración no gestionados (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- Guía para desarrolladores de AWS CDK — https://docs.aws.amazon.com/cdk/v2/guide/home.html
- Guía para desarrolladores de AWS SAM — https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html
- Guía para desarrolladores de AWS Elastic Beanstalk — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- Políticas y ajustes de despliegue de Elastic Beanstalk — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/using-features.deploy-existing-version.html
- Referencia de opciones de configuración de Elastic Beanstalk — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/command-options-general.html
- Guía para desarrolladores de AWS App Runner — https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html
- Guía del usuario de AWS CodeDeploy — https://docs.aws.amazon.com/codedeploy/latest/userguide/welcome.html
- Referencia del fichero AppSpec de CodeDeploy — https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file.html
- Configuraciones de despliegue de CodeDeploy — https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-configurations.html
- Blue/Green Deployments on AWS (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/blue-green-deployments/welcome.html

**Modelos de despliegue: híbrido y edge**
- Guía del usuario de AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- Guía para desarrolladores de AWS Wavelength — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- Guía para desarrolladores de AWS Snowball Edge — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- Guía del usuario de AWS Storage Gateway — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- Amazon ECS Anywhere — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-anywhere.html
- Amazon EKS Anywhere — https://anywhere.eks.amazonaws.com/docs/
- Nube híbrida en AWS — https://aws.amazon.com/hybrid/

**Conectividad**
- Guía del usuario de AWS Site-to-Site VPN — https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
- Guía del administrador de AWS Client VPN — https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html
- Guía del usuario de AWS Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
- Recomendaciones de resiliencia de Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/reliability_pillar.html
- Interfaces virtuales de Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/WorkingWithVirtualInterfaces.html
- MACsec en Direct Connect — https://docs.aws.amazon.com/directconnect/latest/UserGuide/MACsec.html
- AWS Transit Gateway — https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html
- Conceptos de AWS PrivateLink — https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-share-your-services.html
- Gateway VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- Opciones de conectividad entre Amazon VPC (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-vpc-connectivity-options/welcome.html

**Operaciones**
- Guía del usuario de AWS Systems Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/what-is-systems-manager.html
- Session Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- Patch Manager de Systems Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager.html
- Guía del usuario de AWS CloudTrail — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Amazon Time Sync Service — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
- AWS Well-Architected Framework — Pilar de Excelencia Operativa — https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html