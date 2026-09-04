# 1.1 — Definir los beneficios de la nube de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · Dominio 1: Cloud Concepts (24% del examen) · Peso del objetivo en este curso: **6.0**

**Nivel de audiencia:** Platform Architect / SRE. Este objetivo se evalúa a nivel Practitioner, pero la *razón* por la que existe cada beneficio es un argumento de arquitectura. Abajo, cada afirmación que el examen quiere que reconozcas está respaldada por el mecanismo que la produce, el trade-off que impone, infraestructura desplegable que lo demuestra, y la CLI con la que lo probás en una cuenta real.

> **Sobre los números.** Las cantidades de Regions/AZs, los precios y los porcentajes de SLA cambian. Cada cifra de este documento está marcada con el comando o la URL que devuelve el valor autoritativo. Nunca memorices el número; memorizá la consulta.

---

## 1. El problema de producción que responde este objetivo

### 1.1 La trampa de la planificación de capacidad

Antes de la infraestructura elástica, la secuencia para un cambio de capacidad era:

```
demand forecast  →  budget approval  →  PO to vendor  →  lead time
   (± 60% error)      (2–8 weeks)        (1–2 weeks)     (6–16 weeks)
   →  rack / cable / burn-in  →  OS + config  →  in service
        (1–3 weeks)                (days)          T + 3 to 7 months
```

De ahí se siguen tres consecuencias estructurales, y son exactamente aquello a lo que responde la lista de "beneficios de AWS":

1. **El horizonte del pronóstico excede el horizonte de planificación del producto.** Tenés que comprometer capital contra una curva de demanda que solo vas a observar cuando el hardware ya se esté depreciando. El error es asimétrico: si subprovisionás perdés ingresos; si sobreprovisionás arrastrás capital ocioso durante 3–5 años.
2. **La unidad de compra es enorme respecto de la unidad de demanda.** Comprás un rack; la carga de trabajo necesita 0,4 de un servidor. La utilización en centros de datos empresariales tradicionales se reporta habitualmente en la banda del 10–20% para flotas x86 dimensionadas al pico.
3. **Los dominios de falla se heredan, no se eligen.** Un edificio, una alimentación eléctrica, un par de switches de core. El blast radius es una propiedad del contrato de alquiler, no de la arquitectura.

Una lectura desde SRE de las clásicas "seis ventajas del cloud computing" es que cada una convierte una decisión **fija, lenta y de grano grueso** en una **variable, rápida y de grano fino**.

### 1.2 Las seis ventajas, reformuladas como propiedades de ingeniería

| Formulación de AWS (redacción del examen) | Mecanismo que la produce | Propiedad de ingeniería | Métrica que realmente medirías |
|---|---|---|---|
| Cambiar gasto fijo por gasto variable | Facturación medida por segundo/por request; sin plazo mínimo | El costo es una *función de la carga*, no del pronóstico | $ / 1k requests; costo por unidad de trabajo de negocio |
| Beneficiarse de economías de escala masivas | Demanda agregada de millones de clientes; silicio propio (Nitro, Graviton); >100 reducciones de precio publicadas | El precio unitario baja sin que renegocies nada | Tendencia de $/vCPU-hora en el tiempo; % de cobertura de Savings Plans |
| Dejar de adivinar la capacidad | Auto Scaling, serverless, aprovisionamiento por API | La latencia de aprovisionamiento cae de meses a segundos | Time-to-capacity (p50/p99); % de headroom |
| Aumentar la velocidad y la agilidad | API self-service para cada tipo de recurso | El costo de un experimento ≈ 0; los experimentos fallidos son baratos | Lead time for change; entornos por ingeniero |
| Dejar de gastar dinero en operar y mantener centros de datos | Shared Responsibility Model — AWS es dueño de "security *of* the cloud" | El esfuerzo de ingeniería sube en la pila | % de horas-ingeniero en trabajo no diferenciador |
| Volverse global en minutos | 30+ Regions, 100+ AZs, 400+ PoPs de borde, todos direccionables por API | La geografía se vuelve un parámetro de despliegue | p99 RTT por población de usuarios; RTO/RPO por Region |

**Trampa del examen:** "economías de escala" se refiere a que el poder de compra *de AWS* baja *tu* precio. **No** es lo mismo que "elasticidad" (ajustar capacidad a la demanda) ni lo mismo que "agilidad" (velocidad de cambio). CLF-C02 distingue las tres explícitamente.

---

## 2. Infraestructura global: la jerarquía de dominios de falla

No podés razonar sobre alta disponibilidad sin el modelo físico de contención. AWS lo expone como una jerarquía estricta, y cada nivel es una frontera distinta de aislamiento de fallas.

| Nivel | Qué es físicamente | Garantía de aislamiento | Latencia entre pares | Costo de transferencia de datos (típico) | ¿Direccionable por API? |
|---|---|---|---|---|---|
| **Region** | Un clúster geográfico de AZs | Aislamiento total: redes eléctricas separadas, control planes separados, sin replicación automática de datos entre Regions | 10–250 ms inter-Region | Transferencia inter-Region, por GB, por par | Sí — `--region` en cada llamada |
| **Availability Zone (AZ)** | Uno *o más* centros de datos discretos, con energía, refrigeración y seguridad física propias | Falla independiente: la pérdida de una AZ no debería arrastrar a una AZ par | Típicamente **RTT de un solo dígito de ms** (a menudo < 1–2 ms); AZs separadas de forma significativa (decenas de km) | ~$0.01/GB **por dirección** para EC2 cross-AZ | Sí — `AvailabilityZone` / `AvailabilityZoneId` |
| **Local Zone** | Extensión de cómputo/almacenamiento de una Region ubicada en un área metropolitana | Adosada a una Region padre; no es un nivel de HA independiente | Un solo dígito de ms hacia los usuarios de esa metrópolis | Depende de la Region | Sí (opt-in) |
| **Wavelength Zone** | Infraestructura dentro de la red 5G de una telco | Igual — una extensión, no un nivel de HA | Ultrabaja hacia usuarios móviles | Depende de la Region | Sí (opt-in) |
| **Outpost** | Rack gestionado por AWS en *tus* instalaciones | Tu edificio es el dominio de falla | LAN local | N/A | Sí |
| **Edge location / PoP** | Puntos de presencia de CloudFront + Route 53 + Global Accelerator | Nivel de caché/anycast, no un nivel de HA de cómputo | 1–30 ms al usuario final | Precios de egress de CloudFront | Indirectamente |

### 2.1 El detalle de producción más importante de este objetivo: **nombre** de AZ vs **ID** de AZ

`us-east-1a` **no** es una ubicación física. AWS aleatoriza el mapeo de los *nombres* de AZ a AZs físicas **por cuenta de AWS**, específicamente para evitar que todos los clientes se concentren en "la primera". `us-east-1a` en la cuenta A y `us-east-1a` en la cuenta B son, con alta probabilidad, edificios distintos.

El identificador estable y físico es el **AZ ID**: `use1-az1`, `use1-az2`, `usw2-az3`, …

Esto importa en el momento en que hacés cualquiera de estas cosas:
- Correlacionar una caída multi-cuenta ("¿es la misma AZ?")
- Compartir subnets vía AWS RAM (el AZ ID de la subnet compartida es lo que ambas cuentas ven de forma consistente)
- Leer un evento de AWS Health, que reporta el AZ ID
- Colocar cargas sensibles a la latencia en la *misma* AZ física entre cuentas (cluster placement, rutas calientes de VPC peering entre cuentas)
- Ejecutar un zonal shift (la API toma un **ID** de AZ)

```bash
$ aws ec2 describe-availability-zones \
    --region us-east-1 \
    --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,State,NetworkBorderGroup]' \
    --output table
------------------------------------------------------------------------
|                       DescribeAvailabilityZones                       |
+--------------+-------------+---------------------+-----------+--------+
|  us-east-1a  |  use1-az6   |  availability-zone  |  available|us-east-1|
|  us-east-1b  |  use1-az1   |  availability-zone  |  available|us-east-1|
|  us-east-1c  |  use1-az2   |  availability-zone  |  available|us-east-1|
|  us-east-1d  |  use1-az4   |  availability-zone  |  available|us-east-1|
|  us-east-1e  |  use1-az3   |  availability-zone  |  available|us-east-1|
|  us-east-1f  |  use1-az5   |  availability-zone  |  available|us-east-1|
+--------------+-------------+---------------------+-----------+--------+
```

Leé esa tabla otra vez: en esta cuenta `us-east-1a` es físicamente `use1-az6`. Cualquier runbook que diga "sacar el tráfico de us-east-1a" es ambiguo entre cuentas. Los runbooks tienen que decir `use1-az6`.

Incluí Local Zones y Wavelength Zones en la enumeración (están ocultas por defecto):

```bash
$ aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
    --query 'AvailabilityZones[?ZoneType!=`availability-zone`].[ZoneName,ZoneId,ZoneType,ParentZoneName,OptInStatus]' \
    --output table
--------------------------------------------------------------------------------------------
|                                DescribeAvailabilityZones                                  |
+--------------------------+---------------+----------------+---------------+---------------+
|  us-west-2-lax-1a        |  usw2-lax1-az1|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-lax-1b        |  usw2-lax1-az2|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-phx-1a        |  usw2-phx1-az1|  local-zone    |  us-west-2    |  not-opted-in |
|  us-west-2-wl1-den-wlz-1 |  usw2-den-wlz1|  wavelength-zone| us-west-2    |  not-opted-in |
+--------------------------+---------------+----------------+---------------+---------------+
```

### 2.2 Enumerar la infraestructura global sin un permiso de EC2

La fuente canónica y con mínimas credenciales son los **parámetros públicos de SSM Parameter Store** bajo `/aws/service/global-infrastructure`. Esta es la versión legible por máquina de la página de marketing, y es contra la que deberías scriptear.

```bash
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'length(Parameters)' --output text
36

$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | head -12
af-south-1
ap-east-1
ap-northeast-1
ap-northeast-2
ap-northeast-3
ap-south-1
ap-south-2
ap-southeast-1
ap-southeast-2
ap-southeast-3
ap-southeast-4
ca-central-1

# Human-readable long name of a Region
$ aws ssm get-parameter \
    --name /aws/service/global-infrastructure/regions/eu-south-2/longName \
    --query 'Parameter.Value' --output text
Europe (Spain)

# Is a given service available in a given Region? (the "go global" feasibility check)
$ aws ssm get-parameters-by-path \
    --path /aws/service/global-infrastructure/regions/eu-south-2/services \
    --query 'Parameters[].Value' --output text | tr '\t' '\n' | grep -E '^(eks|lambda|rds|bedrock)$'
eks
lambda
rds
```

Esa última consulta es la forma real del concepto de examen "no todos los servicios están en todas las Regions". Un plan de despliegue multi-Region empieza exactamente con este diff:

```bash
$ svc() { aws ssm get-parameters-by-path --path "/aws/service/global-infrastructure/regions/$1/services" \
      --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort; }
$ comm -23 <(svc us-east-1) <(svc eu-south-2) | wc -l
94
```
94 servicios presentes en `us-east-1` y ausentes en `eu-south-2`. Ese número, no una diapositiva, es tu insumo para elegir Region.

### 2.3 Los instance types no están disponibles de manera uniforme *dentro* de una Region

Un hecho de producción más sutil, y causa frecuente de "el ASG solo escala en dos de mis tres AZs":

```bash
$ aws ec2 describe-instance-type-offerings \
    --location-type availability-zone-id \
    --filters Name=instance-type,Values=m7i.large \
    --region us-east-1 \
    --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' --output text
use1-az1        use1-az2        use1-az4        use1-az5        use1-az6
```
`use1-az3` no ofrece `m7i.large`. Si tu tercera subnet vive ahí, esa AZ nunca va a poder satisfacer un scale-out de ese tipo. Esta es la razón mecánica por la que los ASG de producción usan un `MixedInstancesPolicy` con varias familias — ver §5.

---

## 3. Alta disponibilidad: primero la aritmética, después la arquitectura

### 3.1 Tabla de presupuesto de disponibilidad

| Disponibilidad | Downtime / año | Downtime / mes de 30 días | Downtime / semana | Arquitectura típica |
|---|---|---|---|---|
| 99% ("dos nueves") | 3 d 15 h 36 m | 7 h 18 m | 1 h 41 m | Instancia única, best effort |
| 99.9% | 8 h 45 m | 43 m 12 s | 10 m 5 s | Una sola AZ, instancias redundantes |
| 99.95% | 4 h 22 m | 21 m 36 s | 5 m 2 s | Multi-AZ con failover manual |
| 99.99% | 52 m 34 s | 4 m 19 s | 1 m 0 s | Multi-AZ, failover automatizado, capa stateless |
| 99.999% | 5 m 15 s | 25.9 s | 6.0 s | Multi-Region activo/activo, basado en celdas |

### 3.2 Reglas de composición

**Serie (cadena de dependencias)** — todos los componentes deben funcionar:

$$A_{\text{sistema}} = \prod_{i=1}^{n} A_i$$

Cuatro componentes al 99.99% cada uno: `0.9999^4 = 0.99960` → **99.96%**, es decir 3,5 h/año. Agregar dependencias *cuesta* disponibilidad, siempre. Por eso "reducir la cantidad de cosas en el camino del request" es una acción de confiabilidad, no de rendimiento.

**Paralelo (redundante, independiente)** — alcanza con uno de *n*:

$$A_{\text{sistema}} = 1 - \prod_{i=1}^{n}(1 - A_i)$$

Dos AZs independientes al 99.9% cada una: `1 - 0.001^2 = 0.999999` → **99.9999%** *en teoría*.

**Por qué nunca obtenés ese número en la práctica:** la redundancia está acotada por la dependencia compartida menos independiente. El load balancer, el control plane regional, la base de datos compartida, el pipeline de despliegue compartido y la configuración compartida están todos *en serie* delante de tu cómputo *en paralelo*. El modelo real es:

$$A_{\text{real}} = A_{\text{compartido}} \times \left[1 - \prod (1 - A_{\text{zona}})\right]$$

Con un ALB al 99.99% delante de cómputo infinitamente redundante, tu techo es 99.99%. **La redundancia por debajo de un cuello de botella en serie no puede superar a ese cuello de botella.** Memorizá esa oración; es todo el pilar de confiabilidad en una línea.

### 3.3 Modelos de redundancia y su costo

| Modelo | Instancias para capacidad *C* en 3 AZs | ¿Sobrevive la pérdida de 1 AZ? | Utilización en régimen | Multiplicador de costo |
|---|---|---|---|---|
| **N** (sin redundancia) | C | No — brownout de capacidad | ~100% | 1.0× |
| **N+1** | C + 1 unidad | Sí, si 1 unidad ≥ la porción de 1 AZ | ~alta | ~1.1–1.3× |
| **2N** | 2C | Sí, completamente | 50% | 2.0× |
| **3 AZ, "perder una y seguir sirviendo"** | 1.5C (cada AZ tiene el 50% de C) | Sí, a capacidad plena | 67% | 1.5× |
| **2 AZ, "perder una y seguir sirviendo"** | 2C (cada AZ tiene el 100% de C) | Sí, a capacidad plena | 50% | 2.0× |

**Esta es la razón concreta por la que tres AZs es el default de producción y dos no.** Con dos AZs, sobrevivir a la pérdida de una a capacidad plena exige 100% de headroom. Con tres AZs exige 50%. El paso de 2→3 AZs corta a la mitad tu impuesto de redundancia. Las Regions de AWS vienen con un mínimo de tres AZs exactamente por esto.

### 3.4 SLAs publicados que deberías consultar, nunca recordar

| Servicio | Forma del compromiso | Dónde verificarlo |
|---|---|---|
| Amazon EC2 | Porcentajes mensuales de uptime a nivel Region y a nivel instancia, números distintos | `https://aws.amazon.com/compute/sla/` |
| Elastic Load Balancing | Porcentaje mensual de uptime | `https://aws.amazon.com/elasticloadbalancing/sla/` |
| Amazon S3 | Porcentaje mensual de uptime por storage class | `https://aws.amazon.com/s3/sla/` |
| Amazon RDS | Multi-AZ y Single-AZ difieren | `https://aws.amazon.com/rds/sla/` |
| Amazon DynamoDB | Standard y Global Tables difieren | `https://aws.amazon.com/dynamodb/sla/` |
| Amazon Route 53 | El compromiso publicado más alto del portfolio | `https://aws.amazon.com/route53/sla/` |

**Trampa de examen y de producción:** un SLA es un contrato de *crédito en la factura*, no una garantía de disponibilidad ni un objetivo de diseño. Tu objetivo de diseño debe ser más estricto que tu SLO, que a su vez debe ser más estricto que la promesa a tu cliente. El SLA de AWS te dice qué va a reembolsar AWS, no qué van a experimentar tus usuarios.

---

## 4. Elasticidad vs escalabilidad vs agilidad

Estas tres son respuestas de examen distintas y propiedades de ingeniería distintas.

| Término | Definición | Dirección | Escala de tiempo | Primitiva de AWS |
|---|---|---|---|---|
| **Escalabilidad** | El sistema puede manejar una carga mayor agregando recursos | Solo hacia arriba/afuera, normalmente planificado | De tiempo de diseño a horas | Instance types más grandes; sharding; read replicas |
| **Elasticidad** | La capacidad *sigue* automáticamente a la demanda, hacia arriba y hacia abajo | Bidireccional, automática | De segundos a minutos | Auto Scaling, concurrencia de Lambda, Aurora Serverless v2 |
| **Agilidad** | Tiempo y costo de hacer *cualquier* cambio, incluida una idea nueva | N/A | Minutos | La API misma; IaC; entornos efímeros |

**Vertical vs horizontal:**

| | Vertical (scale up) | Horizontal (scale out) |
|---|---|---|
| Mecanismo | Instance type más grande | Más instancias |
| Downtime | Suele requerir stop/start | Ninguno |
| Techo | La instancia más grande de la familia | Prácticamente ilimitado (acotado por cuotas) |
| Dominio de falla | Sin cambios — sigue siendo un nodo | Mejora con la dispersión |
| Encaja en | Monolitos stateful, primarias RDBMS | Capas stateless, workers, web |
| Granularidad de costo | Gruesa (saltos de 2×) | Fina (1 unidad) |

### 4.1 El presupuesto de latencia de la elasticidad — la tabla que decide tu arquitectura

La elasticidad solo sirve si la capacidad llega **antes** de que la curva de demanda se coma tu headroom. Medilo:

| Mecanismo | Tiempo hasta capacidad usable (típico) | Unidad de escalado | Notas |
|---|---|---|---|
| Lambda, concurrencia caliente | ~milisegundos | 1 request | Elasticidad por request; el límite teórico |
| Lambda, cold start | ~100 ms – 2 s (según runtime y VPC) | 1 execution env | SnapStart / provisioned concurrency lo reducen |
| Tarea de Fargate | ~30–60 s | 1 tarea | Sin gestión de nodos |
| EC2 desde ASG, warm pool `Stopped` | ~20–45 s | 1 instancia | Bootstrap ya hecho |
| EC2 desde ASG, AMI horneada | ~90–180 s | 1 instancia | La AMI contiene la aplicación |
| EC2 desde ASG, configuración en boot (cloud-init baja artefactos) | ~3–8 min | 1 instancia | El antipatrón habitual |
| Nodo de EKS vía Karpenter | ~40–90 s | 1 nodo | Después, + arranque del pod |
| Cambio de ACU en Aurora Serverless v2 | segundos | 0.5 ACU | In-place, sin failover |
| DynamoDB on-demand | inmediato, con rampa adaptativa | 1 request | Picos súbitos >2× pueden throttlear hasta que se adapta |

**La regla de diseño:** sea *T* el time-to-capacity y *D* el tiempo que tarda la demanda en consumir tu headroom. Si `T > D`, el autoscaling no te puede salvar — necesitás headroom preaprovisionado, un warm pool, una primitiva a nivel request (Lambda/Fargate), o una cola que absorba la ráfaga. El autoscaling no es un sustituto del headroom; es un mecanismo para *recuperar* headroom durante el valle.

### 4.2 Selección de política de escalado

| Tipo de política | Señal | Mejor para | Modo de falla |
|---|---|---|---|
| **Target tracking** | Mantener una métrica en un setpoint (`ASGAverageCPUUtilization`, `ALBRequestCountPerTarget`) | El 90% de las cargas; opción por defecto | Métrica equivocada → oscilación; la CPU es mal proxy en apps I/O-bound |
| **Step scaling** | Magnitud de la violación de la alarma → ajustes discretos | Escalones de carga conocidos y cuantizados | Carga de tuneo; lenta ante rampas suaves |
| **Simple scaling** | Una alarma → un ajuste + cooldown | Legado; evitar | El cooldown bloquea nuevas acciones durante un pico real |
| **Scheduled** | Reloj de pared | Patrones determinísticos (apertura de mercado, ventana de batch) | Rotura silenciosa cuando el patrón cambia |
| **Predictive** | Pronóstico ML sobre ≥24 h de historia, aprovisiona *por adelantado* | Tráfico cíclico diario/semanal con arranques lentos | Falla del pronóstico en días anómalos; combinar con target tracking |

Combinación de producción: **predictive scaling para el ciclo conocido + target tracking para el residuo**, con `ALBRequestCountPerTarget` (una señal de demanda) en lugar de CPU (una señal de síntoma).

---

## 5. Infraestructura de referencia — prueba por construcción

La siguiente plantilla de CloudFormation es completa y desplegable. Construye la topología que *es* la respuesta a este objetivo: tres AZs, egress por AZ, un ALB que abarca las tres, un ASG que diversifica entre instance types y opciones de compra, y comportamiento de salud consciente del zonal shift.

### 5.1 `clf-1-1-multi-az.yaml`

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  CLF-C02 objective 1.1 reference topology. Demonstrates "go global in minutes",
  elasticity and multi-AZ high availability as deployable infrastructure:
  3 AZs, per-AZ NAT egress, ALB across all zones, ASG with a mixed instances
  policy and AZ-impairment handling.

Parameters:
  ProjectName:
    Type: String
    Default: clf-benefits
    Description: Prefix applied to every resource name tag.

  VpcCidr:
    Type: String
    Default: 10.42.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/(1[6-9]|2[0-4])$'
    Description: IPv4 CIDR for the VPC. Must be /16 to /24.

  LatestAmiId:
    # Public SSM parameter: always resolves to the current AL2023 x86_64 AMI in
    # THIS Region. This is what makes the template Region-portable with no
    # AMI mappings - the "go global in minutes" property, mechanically.
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

  AsgMinSize:
    Type: Number
    Default: 3
    MinValue: 3
    Description: >-
      Minimum 3 so every AZ holds at least one instance at rest. An ASG whose
      minimum is below the AZ count cannot be zone-balanced.

  AsgMaxSize:
    Type: Number
    Default: 12

  RequestsPerTargetTarget:
    Type: Number
    Default: 800
    Description: Target-tracking setpoint, requests per target per minute.

  PerAzNatGateway:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']
    Description: >-
      true  = one NAT Gateway per AZ. AZ-independent egress, ~3x NAT hourly cost,
              no cross-AZ NAT data charges.
      false = a single NAT Gateway in AZ A. Cheaper, but an AZ A failure removes
              egress for ALL private subnets. Never 'false' in production.

Conditions:
  MultiAzNat: !Equals [!Ref PerAzNatGateway, 'true']

Resources:

  # ---------------------------------------------------------------- networking
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # Fn::GetAZs returns the AZ NAMES available to THIS account in THIS Region,
  # in an account-specific order. The physical placement is therefore
  # account-specific: see the AZ name vs AZ ID discussion. The Outputs section
  # below emits the resolved AZ IDs so the deployment is auditable.
  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-a'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-b'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PublicSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [2, !GetAZs '']
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-c'
        - Key: kubernetes.io/role/elb
          Value: '1'

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-a'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-b'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PrivateSubnetC:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      AvailabilityZone: !Select [2, !GetAZs '']
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 6, 8]]
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-c'
        - Key: kubernetes.io/role/internal-elb
          Value: '1'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-public'

  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetAAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetA
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetBAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetB
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetCAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnetC
      RouteTableId: !Ref PublicRouteTable

  # ------------------------------------------------------------ per-AZ egress
  NatEipA:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-a'

  NatEipB:
    Type: AWS::EC2::EIP
    Condition: MultiAzNat
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-b'

  NatEipC:
    Type: AWS::EC2::EIP
    Condition: MultiAzNat
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-eip-c'

  NatGatewayA:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEipA.AllocationId
      SubnetId: !Ref PublicSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-a'

  NatGatewayB:
    Type: AWS::EC2::NatGateway
    Condition: MultiAzNat
    Properties:
      AllocationId: !GetAtt NatEipB.AllocationId
      SubnetId: !Ref PublicSubnetB
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-b'

  NatGatewayC:
    Type: AWS::EC2::NatGateway
    Condition: MultiAzNat
    Properties:
      AllocationId: !GetAtt NatEipC.AllocationId
      SubnetId: !Ref PublicSubnetC
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-nat-c'

  PrivateRouteTableA:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-a'

  PrivateRouteTableB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-b'

  PrivateRouteTableC:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rtb-private-c'

  PrivateDefaultRouteA:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableA
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGatewayA

  PrivateDefaultRouteB:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableB
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !If [MultiAzNat, !Ref NatGatewayB, !Ref NatGatewayA]

  PrivateDefaultRouteC:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTableC
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !If [MultiAzNat, !Ref NatGatewayC, !Ref NatGatewayA]

  PrivateSubnetAAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTableA

  PrivateSubnetBAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTableB

  PrivateSubnetCAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetC
      RouteTableId: !Ref PrivateRouteTableC

  # ------------------------------------------------------------ security groups
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress from the internet to the ALB
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
          Description: HTTP from anywhere (demo only; terminate TLS in production)
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-sg-alb'

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress from the ALB only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          SourceSecurityGroupId: !Ref AlbSecurityGroup
          Description: Application port, ALB only
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-sg-app'

  # ------------------------------------------------------------- load balancer
  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${ProjectName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      SecurityGroups:
        - !Ref AlbSecurityGroup
      # An ALB REQUIRES subnets in at least two AZs. Three is the production
      # default: it is what makes "lose one AZ and keep full capacity" cost
      # 1.5x instead of 2x.
      Subnets:
        - !Ref PublicSubnetA
        - !Ref PublicSubnetB
        - !Ref PublicSubnetC
      LoadBalancerAttributes:
        - Key: idle_timeout.timeout_seconds
          Value: '60'
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: deletion_protection.enabled
          Value: 'false'
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-alb'

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${ProjectName}-tg'
      VpcId: !Ref Vpc
      Protocol: HTTP
      Port: 8080
      TargetType: instance
      HealthCheckEnabled: true
      HealthCheckProtocol: HTTP
      HealthCheckPath: /healthz
      HealthCheckIntervalSeconds: 10
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        # ALB cross-zone load balancing is ON by default and free within a
        # Region. Turning it off makes traffic distribution proportional to the
        # ALB nodes per AZ, not to targets per AZ - a classic imbalance bug.
        - Key: load_balancing.cross_zone.enabled
          Value: 'true'
        - Key: load_balancing.algorithm.type
          Value: least_outstanding_requests
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-tg'

  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Protocol: HTTP
      Port: 80
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------ compute fleet
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
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-instance-role'

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${ProjectName}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestAmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref AppSecurityGroup
        MetadataOptions:
          HttpTokens: required          # IMDSv2 only
          HttpPutResponseHopLimit: 1
        Monitoring:
          Enabled: true                 # 1-minute metrics: required for fast scaling
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
                Value: !Sub '${ProjectName}-app'
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail
            dnf -y install python3
            AZ=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
                 'http://169.254.169.254/latest/api/token' \
                 -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" \
                 http://169.254.169.254/latest/meta-data/placement/availability-zone)
            AZID=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
                 'http://169.254.169.254/latest/api/token' \
                 -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" \
                 http://169.254.169.254/latest/meta-data/placement/availability-zone-id)
            mkdir -p /srv/app
            printf 'OK\n' > /srv/app/healthz
            printf 'zone=%s zone_id=%s\n' "$AZ" "$AZID" > /srv/app/index.html
            cat >/etc/systemd/system/app.service <<'UNIT'
            [Unit]
            Description=CLF 1.1 demo app
            After=network-online.target
            [Service]
            WorkingDirectory=/srv/app
            ExecStart=/usr/bin/python3 -m http.server 8080
            Restart=always
            [Install]
            WantedBy=multi-user.target
            UNIT
            systemctl daemon-reload
            systemctl enable --now app.service

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${ProjectName}-asg'
      MinSize: !Ref AsgMinSize
      MaxSize: !Ref AsgMaxSize
      DesiredCapacity: !Ref AsgMinSize
      VPCZoneIdentifier:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
        - !Ref PrivateSubnetC
      TargetGroupARNs:
        - !Ref TargetGroup
      HealthCheckType: ELB
      HealthCheckGracePeriod: 120
      # Capacity diversification: this is the practical answer to
      # InsufficientInstanceCapacity in a single type/AZ combination.
      # NOTE: every override MUST match the AMI architecture. LatestAmiId is
      # x86_64, so all overrides are x86_64. Mixing in Graviton (m7g/m6g) here
      # would launch instances that never boot.
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: 3
          OnDemandPercentageAboveBaseCapacity: 25
          OnDemandAllocationStrategy: prioritized
          SpotAllocationStrategy: price-capacity-optimized
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            - InstanceType: m7i.large
            - InstanceType: m6i.large
            - InstanceType: m5.large
            - InstanceType: m5a.large
            - InstanceType: m5n.large
      # Keep capacity evenly spread; do not sacrifice balance for convenience.
      AvailabilityZoneDistribution:
        CapacityDistributionStrategy: balanced-best-effort
      # When an AZ is impaired, do NOT replace instances there (that would burn
      # capacity trying to launch into a broken zone). Requires a recent ASG API.
      AvailabilityZoneImpairmentPolicy:
        ZonalShiftEnabled: true
        ImpairedZoneHealthCheckBehavior: IgnoreUnhealthy
      MetricsCollection:
        - Granularity: 1Minute
          Metrics:
            - GroupInServiceInstances
            - GroupDesiredCapacity
            - GroupPendingInstances
            - GroupTerminatingInstances
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-app'
          PropagateAtLaunch: true
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref AsgMinSize
        MaxBatchSize: 1
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - AZRebalance

  # Demand-proportional signal. CPU is a symptom; request rate is the cause.
  RequestScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        TargetValue: !Ref RequestsPerTargetTarget
        PredefinedMetricSpecification:
          PredefinedMetricType: ALBRequestCountPerTarget
          # ResourceLabel format: <alb-full-name>/<tg-full-name>
          ResourceLabel: !Join
            - '/'
            - - !GetAtt Alb.LoadBalancerFullName
              - !GetAtt TargetGroup.TargetGroupFullName

  # Second-line guard for CPU-bound regressions.
  CpuScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 120
      TargetTrackingConfiguration:
        TargetValue: 60
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization

  # ----------------------------------------------------------------- observability
  UnhealthyHostsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-unhealthy-hosts'
      AlarmDescription: Any unhealthy target for 2 consecutive minutes.
      Namespace: AWS/ApplicationELB
      MetricName: UnHealthyHostCount
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      Dimensions:
        - Name: LoadBalancer
          Value: !GetAtt Alb.LoadBalancerFullName
        - Name: TargetGroup
          Value: !GetAtt TargetGroup.TargetGroupFullName

  Elb5xxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-elb-5xx'
      AlarmDescription: >-
        ALB-generated 5xx. This is the stop condition for the AZ fault
        injection experiment: if the multi-AZ claim is false, this fires.
      Namespace: AWS/ApplicationELB
      MetricName: HTTPCode_ELB_5XX_Count
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 10
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      Dimensions:
        - Name: LoadBalancer
          Value: !GetAtt Alb.LoadBalancerFullName

Outputs:
  AlbDnsName:
    Description: Public endpoint
    Value: !Sub 'http://${Alb.DNSName}'

  ZoneAName:
    Description: AZ name used for subnet A (account-specific label)
    Value: !GetAtt PrivateSubnetA.AvailabilityZone

  ZoneAId:
    Description: >-
      PHYSICAL AZ identifier for subnet A. Use THIS value in runbooks,
      zonal shifts and cross-account correlation - never the AZ name.
    Value: !GetAtt PrivateSubnetA.AvailabilityZoneId

  ZoneBId:
    Value: !GetAtt PrivateSubnetB.AvailabilityZoneId

  ZoneCId:
    Value: !GetAtt PrivateSubnetC.AvailabilityZoneId

  AutoScalingGroupName:
    Value: !Ref AutoScalingGroup

  Elb5xxAlarmArn:
    Description: Stop condition ARN for the FIS experiment
    Value: !GetAtt Elb5xxAlarm.Arn
```

### 5.2 Warm pool — el acelerador de la elasticidad, y su restricción

Un warm pool reduce el time-to-capacity de minutos a decenas de segundos, pre-bootstrapeando instancias y dejándolas detenidas. **Los warm pools no soportan Spot Instances**, así que este recurso pertenece a un ASG solo On-Demand, no al grupo con `MixedInstancesPolicy` de arriba.

```yaml
  # Attach to an On-Demand-only ASG. Not compatible with Spot in the
  # mixed instances policy.
  WarmPool:
    Type: AWS::AutoScaling::WarmPool
    Properties:
      AutoScalingGroupName: !Ref OnDemandAutoScalingGroup
      PoolState: Stopped        # Stopped = cheapest (EBS only, no compute charge)
                                # Running = fastest, full instance charge
                                # Hibernated = fast + warm page cache, EBS charge
      MinSize: 3
      MaxGroupPreparedCapacity: 12
      InstanceReusePolicy:
        ReuseOnScaleIn: true    # returning scaled-in instances to the pool
                                # avoids paying the bootstrap cost twice
```

| Estado del pool | Costo mientras está ocioso | Tiempo hasta in-service | Usar cuando |
|---|---|---|---|
| `Stopped` | Solo almacenamiento EBS | ~20–45 s | Default; el bootstrap es la parte lenta |
| `Hibernated` | Almacenamiento EBS (incl. imagen de RAM) | ~15–30 s | Cachés grandes en memoria / calentamiento de JIT |
| `Running` | Precio completo de la instancia | ~5–15 s | Duplicación de demanda en menos de un minuto, alto ingreso por segundo |

### 5.3 Equivalente en Terraform de la lógica de selección de AZ

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region"       { type = string, default = "us-east-1" }
variable "vpc_cidr"     { type = string, default = "10.42.0.0/16" }
variable "instance_type" { type = string, default = "m7i.large" }

# Only AZs that are BOTH available AND actually offer the instance type we
# intend to launch. Filtering on availability alone is the bug that produces
# a permanently unbalanced ASG.
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]   # excludes Local/Wavelength zones
  }
}

data "aws_ec2_instance_type_offerings" "usable" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  filter {
    name   = "location"
    values = data.aws_availability_zones.available.names
  }
  location_type = "availability-zone"
}

locals {
  usable_azs = sort(data.aws_ec2_instance_type_offerings.usable.locations)
  azs        = slice(local.usable_azs, 0, min(3, length(local.usable_azs)))
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "clf-benefits-vpc" }
}

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value + 3)

  tags = {
    Name = "clf-benefits-private-${each.key}"
    # Record the PHYSICAL zone as a tag so an audit does not have to
    # re-resolve the account-specific name mapping.
    AvailabilityZoneId = data.aws_availability_zones.available.zone_ids[
      index(data.aws_availability_zones.available.names, each.key)
    ]
  }
}

output "az_name_to_id" {
  description = "The account-specific mapping. Put this in the runbook."
  value = zipmap(
    data.aws_availability_zones.available.names,
    data.aws_availability_zones.available.zone_ids,
  )
}

output "selected_azs" {
  value = local.azs
}
```

### 5.4 La misma propiedad en Kubernetes (EKS) — la dispersión entre AZs no es automática

Correr sobre EKS no te da redundancia entre AZs gratis. El scheduler va a colocar felizmente todas las réplicas en un nodo de una sola AZ. Tenés que declarar la restricción:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 6
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      # Hard requirement: replicas differ by at most 1 across AZs. If the
      # constraint cannot be met, the pod stays Pending rather than silently
      # collapsing the failure domain.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout
          matchLabelKeys:
            - pod-template-hash          # spread per-revision, not across revisions
        # Soft requirement: also spread across nodes within a zone, so a single
        # node loss is not a zone-sized event.
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: checkout
      containers:
        - name: checkout
          image: public.ecr.aws/nginx/nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { memory: 512Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 80 }
            periodSeconds: 5
---
# A PDB caps voluntary disruption. Without it, a node drain during an AZ event
# can remove the surviving capacity you were counting on.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: shop
spec:
  minAvailable: 4          # 6 replicas, 3 AZs -> lose one AZ (2 pods) and still serve
  selector:
    matchLabels:
      app: checkout
```

---

## 6. Economías de escala, hechas medibles

### 6.1 Opciones de compra — la tabla real de trade-offs

| Opción | Descuento vs On-Demand (orden de magnitud) | Compromiso | Flexibilidad | Riesgo de interrupción | Encaja en |
|---|---|---|---|---|---|
| **On-Demand** | línea base | ninguno | total | ninguno | Carga con picos, impredecible, de vida corta, dev |
| **Spot** | hasta ~90% | ninguno | cualquier tipo/AZ | Sí — aviso de interrupción de **2 minutos** | Stateless, tolerante a fallas, batch, CI, big data |
| **Compute Savings Plan** | hasta ~66% | 1 o 3 años, $/hr | Cualquier familia de instancias, tamaño, Region, SO, tenancy; también Fargate y Lambda | ninguno | Vehículo de compromiso por defecto |
| **EC2 Instance Savings Plan** | hasta ~72% | 1 o 3 años, $/hr | Atado a familia + Region; flexible en tamaño/SO/AZ | ninguno | Elección de familia estable |
| **Standard Reserved Instance** | hasta ~72% | 1 o 3 años, con forma de capacidad | Flexible en tamaño dentro de familia/Region | ninguno | Legado; los Savings Plans generalmente lo reemplazan |
| **Convertible RI** | hasta ~66% | 1 o 3 años | Intercambiable por otras familias | ninguno | Familia de largo plazo incierta |
| **On-Demand Capacity Reservation** | ninguno (pagás por *reservar* capacidad) | ninguno (o con un instrumento de descuento) | Zonal | ninguno | Capacidad garantizada en una AZ específica |
| **Dedicated Host** | varía | opcional | A nivel host | ninguno | Licenciamiento BYOL atado a sockets/cores |

**La estratificación que realmente corre una cuenta madura:** los Savings Plans cubren el *piso siempre encendido*; On-Demand cubre la *banda variable predecible*; Spot cubre el *excedente interrumpible*. Objetivos de 70–80% de cobertura de Savings Plan sobre el piso son comunes; comprometerse al 100% elimina el valor de opción que hizo atractiva a la nube en primer lugar.

**El contrato real de Spot:** recibís un aviso de interrupción de 2 minutos vía instance metadata y EventBridge. Manejalo o perdés el trabajo en vuelo:

```bash
$ TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      -w '%{http_code}\n' -o /dev/null \
      http://169.254.169.254/latest/meta-data/spot/instance-action
404          # 404 = no interruption pending. 200 = you have ~120 seconds.
```

### 6.2 Consultar precios reales en vez de citar una diapositiva

La Price List API es la fuente autoritativa. Ojo: se sirve solo desde unas pocas Regions (`us-east-1`, `ap-south-1`, `eu-central-1`), sin importar qué Region estés cotizando.

```bash
$ aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
        'Type=TERM_MATCH,Field=instanceType,Value=m7i.large' \
        'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
        'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
        'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
        'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
        'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
    --output json \
  | jq -r '.PriceList[] | fromjson
           | .terms.OnDemand[].priceDimensions[]
           | "\(.pricePerUnit.USD) USD per \(.unit) - \(.description)"'
0.1008000000 USD per Hrs - $0.1008 per On Demand Linux m7i.large Instance Hour
```

Compará la misma forma sobre Graviton para ver el argumento de precio/rendimiento como número, no como afirmación:

```bash
$ for t in m7i.large m7g.large; do
    p=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
        --filters "Type=TERM_MATCH,Field=instanceType,Value=$t" \
                  'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
                  'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
                  'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
                  'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
                  'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
        --output json | jq -r '.PriceList[0] | fromjson
                               | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
    printf '%-12s %s USD/hr\n' "$t" "$p"
  done
m7i.large    0.1008000000 USD/hr
m7g.large    0.0816000000 USD/hr
```

El descuento actual de Spot, en vivo:

```bash
$ aws ec2 describe-spot-price-history \
    --instance-types m7i.large \
    --product-descriptions "Linux/UNIX" \
    --region us-east-1 \
    --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(SpotPriceHistory,&AvailabilityZone)[].[AvailabilityZone,SpotPrice]' \
    --output table
--------------------------------
|  DescribeSpotPriceHistory    |
+---------------+--------------+
|  us-east-1a   |  0.036200    |
|  us-east-1b   |  0.034900    |
|  us-east-1c   |  0.041100    |
|  us-east-1d   |  0.033700    |
|  us-east-1f   |  0.038400    |
+---------------+--------------+
```

Notá que el precio *varía por AZ* — la capacidad es un recurso zonal, y su precio también. `price-capacity-optimized` en el ASG usa exactamente esta señal.

### 6.3 El costo que sorprende a la gente: transferencia de datos entre AZs

La redundancia de tres AZs no es gratis en la capa de red. El tráfico de EC2 que cruza fronteras de AZ dentro de la misma Region se factura **por dirección** (aproximadamente $0.01/GB en cada sentido; verificalo en la página de precios). El tráfico dentro de una misma AZ sobre IPv4 privada es gratis.

Una malla de microservicios habladora repartida en 3 AZs manda ~2/3 de su tráfico interno cruzando una frontera de zona por construcción. Encontralo:

```bash
# Cost Explorer: the usage type for cross-AZ traffic is *-DataTransfer-Regional-Bytes
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --metrics UnblendedCost UsageQuantity \
    --filter '{"Dimensions":{"Key":"USAGE_TYPE_GROUP","Values":["EC2: Data Transfer - Region to Region"]}}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json | jq -r '.ResultsByTime[].Groups[]
        | "\(.Keys[0])  \(.Metrics.UsageQuantity.Amount|tonumber|floor) GB  $\(.Metrics.UnblendedCost.Amount)"'
USE1-DataTransfer-Regional-Bytes  41822 GB  $836.44
```

Los VPC Flow Logs v5 llevan un campo `az-id`; así es como atribuís los bytes a un *par* de zonas y encontrás el servicio culpable. El trade-off es explícito y hay que tomarlo conscientemente:

| Elección | Disponibilidad | $ cross-AZ | Cuándo |
|---|---|---|---|
| Servicio disperso + llamadores dispersos, ruteo aleatorio | La mejor | El más alto | Default; ese dinero compra independencia entre AZs |
| Afinidad zonal (el llamador prefiere un target en la misma AZ, con fallback cross-AZ) | Buena, si el fallback es real | Bajo | Tráfico este-oeste de alto volumen; requiere que el fallback esté *probado* |
| Fijar a una sola AZ | Pobre | Cero | Nunca para caminos de request en producción |

**Advertencia sobre la afinidad zonal:** convierte silenciosamente tu despliegue multi-AZ en tres despliegues de una sola AZ *si el camino de fallback no está probado*. Verificá el fallback con inyección de fallas (§8), no con una revisión de diseño.

---

## 7. "Volverse global en minutos" — la propiedad de despliegue

La afirmación es que la geografía es un parámetro. Demostralo:

```bash
$ TAG=clf-benefits
$ for R in us-east-1 eu-west-1 ap-southeast-2; do
    aws cloudformation deploy \
      --region "$R" \
      --stack-name "$TAG" \
      --template-file clf-1-1-multi-az.yaml \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides ProjectName="$TAG" VpcCidr=10.42.0.0/16 &
  done; wait

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - clf-benefits
```

Tres continentes, una plantilla, sin mapeo de AMIs — porque `LatestAmiId` se resuelve por Region desde un parámetro público de SSM y `Fn::GetAZs` se resuelve por Region/cuenta.

```bash
$ for R in us-east-1 eu-west-1 ap-southeast-2; do
    printf '%-16s ' "$R"
    aws cloudformation describe-stacks --region "$R" --stack-name clf-benefits \
      --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text
  done
us-east-1        http://clf-benefits-alb-1043928471.us-east-1.elb.amazonaws.com
eu-west-1        http://clf-benefits-alb-0418772315.eu-west-1.elb.amazonaws.com
ap-southeast-2   http://clf-benefits-alb-1877340296.ap-southeast-2.elb.amazonaws.com
```

### 7.1 Qué compra realmente lo "global", según el mecanismo

| Mecanismo | Qué reduce | Tiempo de failover | Data plane | Usar cuando |
|---|---|---|---|---|
| **CloudFront** | Latencia para contenido cacheable; RTT del handshake TLS en el borde | N/A (grupos de origin failover: segundos) | PoPs de borde anycast | Assets estáticos, aceleración de API, absorción de DDoS en el borde |
| **Route 53 latency routing** | Latencia, dirigiendo el DNS a la Region sana más cercana | Acotado por el TTL de DNS: **60 s + caché del cliente** | Resuelto por el cliente | Multi-Region activo/activo con clientes tolerantes |
| **Route 53 failover routing** | Exposición a una caída regional | Acotado por el TTL de DNS | Resuelto por el cliente | DR activo/pasivo |
| **Global Accelerator** | Latencia *y* failover, vía IPs estáticas anycast sobre el backbone de AWS | **Segundos**, sin dependencia de DNS | Red global de AWS | Protocolos no-HTTP, clientes sticky, clientes hostiles al caché DNS |
| **Aurora Global Database** | RPO para datos entre Regions | RPO típicamente ~1 s; RTO típicamente < 1 min en failover gestionado | Replicación en la capa de almacenamiento | DR regional para datos relacionales |
| **DynamoDB Global Tables** | RPO/RTO para datos clave-valor | Multi-activo; replicación típicamente sub-segundo | Multi-Region multi-activo | Cargas de escritura en cualquier lado |
| **S3 Cross-Region Replication** | Durabilidad/localidad de objetos entre Regions | Asíncrona; S3 RTC ofrece un SLA de replicación | Copia de objetos | Cumplimiento, DR, localidad de datos |

**La trampa del DNS, dicha sin vueltas:** el failover por health check de Route 53 está acotado por abajo por el caché DNS del cliente, y una fracción significativa de clientes ignora los TTLs. Si tu RTO se mide en segundos y no en minutos, necesitás Global Accelerator (anycast, sin re-resolución de DNS) — no un TTL más corto.

RTTs ilustrativos (medí los tuyos; estos son la forma, no el valor):

| Camino | RTT típico |
|---|---|
| Misma AZ, IP privada | < 1 ms |
| Cross-AZ, misma Region | ~0.5–2 ms |
| us-east-1 ↔ us-west-2 | ~60–75 ms |
| us-east-1 ↔ eu-west-1 | ~70–90 ms |
| us-east-1 ↔ ap-southeast-2 | ~200–240 ms |
| Usuario final ↔ PoP de CloudFront más cercano | ~5–30 ms |

**Consecuencia para la arquitectura:** las escrituras síncronas entre Regions no son viables en caminos de request interactivos — a 80 ms de RTT, un two-phase commit cuesta 160 ms *antes* de hacer trabajo alguno. Por eso RDS Multi-AZ es síncrono (un solo dígito de ms) y Aurora Global Database es asíncrono. La física de la tabla de latencias *es* la razón por la cual la Region es la frontera de aislamiento y la AZ es la frontera de redundancia.

---

## 8. Verificación y diagnóstico de fallas

Todo lo de arriba es una afirmación hasta que lo verificás en la cuenta. Esta sección es el runbook.

### 8.1 Escalera de verificación

**Paso 1 — Confirmar la dispersión física (no las etiquetas).**

```bash
$ aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=clf-benefits-private-*" \
    --query 'sort_by(Subnets,&AvailabilityZoneId)[].[SubnetId,AvailabilityZone,AvailabilityZoneId,CidrBlock,AvailableIpAddressCount]' \
    --output table
------------------------------------------------------------------------------------------
|                                    DescribeSubnets                                      |
+---------------------+--------------+------------+------------------+------------------+
|  subnet-0a3f81c22e  |  us-east-1b  |  use1-az1  |  10.42.4.0/24    |  251             |
|  subnet-07b9d4e610  |  us-east-1c  |  use1-az2  |  10.42.5.0/24    |  251             |
|  subnet-0c1e77a934  |  us-east-1a  |  use1-az6  |  10.42.3.0/24    |  251             |
+---------------------+--------------+------------+------------------+------------------+
```
**Criterio de aprobación:** tres valores *distintos* de `AvailabilityZoneId`. Los *nombres* de AZ distintos no prueban nada por sí solos — pero los IDs distintos sí, y acá son `use1-az1/az2/az6`.

**Paso 2 — Confirmar que el ALB efectivamente las abarca.**

```bash
$ aws elbv2 describe-load-balancers --names clf-benefits-alb \
    --query 'LoadBalancers[0].AvailabilityZones[].[ZoneName,SubnetId]' --output table
-----------------------------------------
|        DescribeLoadBalancers          |
+--------------+------------------------+
|  us-east-1a  |  subnet-0d2c99f781     |
|  us-east-1b  |  subnet-0b8e13a746     |
|  us-east-1c  |  subnet-06fa2e5c30     |
+-----------------------------------------
```

**Paso 3 — Confirmar que la capacidad está balanceada *y sana* por zona.** Desbalanceado-pero-InService es el asesino silencioso: la consola muestra verde mientras una AZ carga el 60% del tráfico.

```bash
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names clf-benefits-asg \
    --query 'AutoScalingGroups[0].Instances[].[AvailabilityZone,InstanceId,LifecycleState,HealthStatus,InstanceType]' \
    --output text | sort | awk '{print} {c[$1]++} END {print "---"; for (z in c) printf "%s: %d\n", z, c[z]}'
us-east-1a      i-0a4c81de2f31b9077     InService       Healthy m7i.large
us-east-1a      i-0f1b6d0c93aa5e412     InService       Healthy m5.large
us-east-1b      i-02d7e94a1c8f3b650     InService       Healthy m7i.large
us-east-1b      i-0be3517fa2069cd84     InService       Healthy m6i.large
us-east-1c      i-064a2fbb7e91d3c05     InService       Healthy m7i.large
us-east-1c      i-09e8c31d05b7fa246     InService       Healthy m5a.large
---
us-east-1a: 2
us-east-1b: 2
us-east-1c: 2
```

**Paso 4 — Confirmar la salud de los targets por zona en el load balancer.**

```bash
$ TG=$(aws elbv2 describe-target-groups --names clf-benefits-tg \
       --query 'TargetGroups[0].TargetGroupArn' --output text)
$ aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State,TargetHealth.Reason]' \
    --output table
-------------------------------------------------------------------------
|                         DescribeTargetHealth                           |
+-----------------------+--------------+----------+---------------------+
|  i-0a4c81de2f31b9077  |  us-east-1a  |  healthy |  None               |
|  i-0f1b6d0c93aa5e412  |  us-east-1a  |  healthy |  None               |
|  i-02d7e94a1c8f3b650  |  us-east-1b  |  healthy |  None               |
|  i-0be3517fa2069cd84  |  us-east-1b  |  healthy |  None               |
|  i-064a2fbb7e91d3c05  |  us-east-1c  |  healthy |  None               |
|  i-09e8c31d05b7fa246  |  us-east-1c  |  healthy |  None               |
+-----------------------+--------------+----------+---------------------+
```

**Paso 5 — Confirmar que el endpoint responde desde las tres zonas.**

```bash
$ URL=$(aws cloudformation describe-stacks --stack-name clf-benefits \
        --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text)
$ for i in $(seq 1 30); do curl -s "$URL/index.html"; done | sort | uniq -c
     10 zone=us-east-1a zone_id=use1-az6
     10 zone=us-east-1b zone_id=use1-az1
     10 zone=us-east-1c zone_id=use1-az2
```
Distribución pareja entre tres zonas *físicas*. **Esa es la afirmación multi-AZ, verificada.**

### 8.2 Probalo rompiéndolo — AWS Fault Injection Service

Una revisión de diseño no prueba la independencia entre AZs. Una falla controlada sí.

```yaml
  FisRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: fis.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: fis-network-disruption
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - ec2:DescribeSubnets
                  - ec2:DescribeVpcs
                  - ec2:DescribeRouteTables
                  - ec2:DescribeNetworkAcls
                  - ec2:CreateNetworkAcl
                  - ec2:CreateNetworkAclEntry
                  - ec2:CreateTags
                  - ec2:DeleteNetworkAcl
                  - ec2:ReplaceNetworkAclAssociation
                Resource: '*'
              - Effect: Allow
                Action: cloudwatch:DescribeAlarms
                Resource: '*'

  AzDisruptionExperiment:
    Type: AWS::FIS::ExperimentTemplate
    Properties:
      Description: >-
        Sever connectivity for one AZ's private subnet and assert that the ALB
        continues to serve from the surviving two zones with zero ELB 5xx.
      RoleArn: !GetAtt FisRole.Arn
      StopConditions:
        # If the multi-AZ claim is FALSE, this alarm fires and the experiment
        # halts automatically. The stop condition IS the hypothesis.
        - Source: aws:cloudwatch:alarm
          Value: !GetAtt Elb5xxAlarm.Arn
      Targets:
        TargetSubnet:
          ResourceType: aws:ec2:subnet
          SelectionMode: ALL
          ResourceArns:
            - !Sub 'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:subnet/${PrivateSubnetC}'
      Actions:
        DisruptZone:
          ActionId: 'aws:network:disrupt-connectivity'
          Description: Block all traffic in the target subnet for 10 minutes
          Parameters:
            scope: all
            duration: PT10M
          Targets:
            Subnets: TargetSubnet
      Tags:
        Name: clf-1-1-az-disruption
        Hypothesis: 'Losing one AZ produces zero customer-visible errors'
```

Ejecutalo y observá:

```bash
$ EXP_ID=$(aws fis list-experiment-templates \
    --query "experimentTemplates[?tags.Name=='clf-1-1-az-disruption'].id" --output text)
$ aws fis start-experiment --experiment-template-id "$EXP_ID" \
    --query 'experiment.{Id:id,State:state.status}' --output json
{
    "Id": "EXPzT7pB4Qm9YkR2",
    "State": "initiating"
}

$ aws fis get-experiment --id EXPzT7pB4Qm9YkR2 \
    --query 'experiment.{State:state.status,Reason:state.reason}' --output json
{
    "State": "running",
    "Reason": "Experiment is running."
}

# The observable: traffic redistributes to the two surviving zones.
$ for i in $(seq 1 30); do curl -s --max-time 3 "$URL/index.html"; done | sort | uniq -c
     15 zone=us-east-1a zone_id=use1-az6
     15 zone=us-east-1b zone_id=use1-az1
```

**Criterio de aprobación:** cero respuestas distintas de 200, y la zona degradada sale de la rotación. Si ves `503 Service Temporarily Unavailable`, la afirmación multi-AZ era falsa y te enteraste en una ventana controlada en lugar de a las 03:00.

### 8.3 La mitigación del operador: zonal shift

El zonal shift saca el tráfico *fuera* de una AZ física en segundos, sin un despliegue y sin un cambio de DNS.

```bash
$ ALB_ARN=$(aws elbv2 describe-load-balancers --names clf-benefits-alb \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text)

$ aws arc-zonal-shift list-managed-resources \
    --query "items[?name=='clf-benefits-alb'].[arn,appliedWeights]" --output json
[
    [
        "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/clf-benefits-alb/1a2b3c4d5e6f7890",
        {}
    ]
]

# NOTE: --away-from takes the AZ *ID*, not the AZ name. This is why §2.1 matters.
$ aws arc-zonal-shift start-zonal-shift \
    --resource-identifier "$ALB_ARN" \
    --away-from use1-az2 \
    --expires-in 6h \
    --comment "INC-4471: elevated p99 and connection resets isolated to use1-az2"
{
    "zonalShiftId": "9f13c0b8-7a44-4d2e-9c31-5b0e21a7d6f2",
    "resourceIdentifier": "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/clf-benefits-alb/1a2b3c4d5e6f7890",
    "awayFrom": "use1-az2",
    "expiryTime": "2026-09-03T20:11:47+00:00",
    "startTime": "2026-09-03T14:11:47+00:00",
    "status": "ACTIVE",
    "comment": "INC-4471: elevated p99 and connection resets isolated to use1-az2"
}

$ aws arc-zonal-shift cancel-zonal-shift --zonal-shift-id 9f13c0b8-7a44-4d2e-9c31-5b0e21a7d6f2
```

**La precondición que nadie chequea hasta que es tarde:** un zonal shift solo funciona si las zonas sobrevivientes tienen capacidad para absorber la carga desplazada. Con tres AZs al 100% de utilización, sacar el tráfico de una pone el 150% de la demanda de capacidad sobre las dos restantes. **El headroom pre-escalado es lo que hace del zonal shift una mitigación y no una manera de convertir una caída parcial en una total.**

### 8.4 Referencia de firmas de falla

| Síntoma | Causa raíz | Comando de diagnóstico | Remediación |
|---|---|---|---|
| `InsufficientInstanceCapacity` al lanzar | AWS no tiene capacidad para *ese tipo* en *esa AZ* en este momento. **No** es un problema de cuota. | `aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg> --max-items 5` | Agregar instance types a los overrides de `MixedInstancesPolicy`; agregar AZs; usar ODCR o Capacity Blocks para capacidad garantizada |
| `VcpuLimitExceeded` / `InstanceLimitExceeded` | Tu **service quota**, no la capacidad de AWS | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` | Pedir un aumento; las cuotas son por Region |
| El ASG solo lanza en 2 de 3 AZs | La AZ de la tercera subnet no ofrece ninguno de los instance types de los overrides | `aws ec2 describe-instance-type-offerings --location-type availability-zone-id --filters Name=location,Values=use1-az3` | Cambiar la AZ o ampliar la lista de tipos |
| Las instancias arrancan pero nunca pasan a `InService` | El grace period del health check es más corto que boot+bootstrap; o la app no está en el puerto del health check | `aws elbv2 describe-target-health --target-group-arn <tg>` → mirar `TargetHealth.Reason` | Subir `HealthCheckGracePeriod`; verificar que el SG permita ALB→puerto de la app |
| `Target.FailedHealthChecks` | La app devuelve un estado que no matchea, ruta equivocada, o está bindeada a `127.0.0.1` | Desde la instancia: `curl -sv localhost:8080/healthz` vía SSM Session Manager | Corregir dirección de bind / ruta / `Matcher.HttpCode` |
| `Elb.InternalError` en target health | Problema del lado del ALB; frecuentemente una subnet con muy pocas IPs libres | `aws ec2 describe-subnets --query 'Subnets[].[SubnetId,AvailableIpAddressCount]'` | El ALB necesita ≥8 IPs libres por subnet para escalar; usar /27 o mayor, /24 recomendado |
| Tráfico fuertemente sesgado hacia una AZ | Cross-zone load balancing deshabilitado en el target group; o cantidades desbalanceadas de targets | `aws elbv2 describe-target-group-attributes --target-group-arn <tg>` | Poner `load_balancing.cross_zone.enabled=true`; rebalancear el ASG |
| **Todos** los targets unhealthy → los usuarios igual reciben respuestas | ALB **fail-open**: cuando todos los targets de todas las AZs están unhealthy, el ALB rutea a todos los targets en vez de no servir nada | `HealthyHostCount` = 0 mientras `RequestCount` > 0 | No confiar en eso — tratá `HealthyHostCount == 0` como una alarma que amerita page |
| Las instancias de una AZ pierden el egress a internet | Un solo NAT Gateway; su AZ falló | `aws ec2 describe-route-tables --query 'RouteTables[].Routes[?NatGatewayId!=null]'` | `PerAzNatGateway=true` — un NAT por AZ, tabla de rutas privada por AZ |
| Pico repentino de costo de transferencia cross-AZ | Nuevo servicio hablador desplegado sin afinidad zonal; o una librería cliente que ignora las pistas de AZ | Cost Explorer sobre `*-DataTransfer-Regional-Bytes`; VPC Flow Logs agrupados por `az-id` | Evaluar afinidad zonal **con un fallback cross-AZ probado** |
| CloudFormation `CREATE_FAILED: The number of AZs is less than requested` | La Region tiene menos AZs usables que el índice de `Fn::Select` de la plantilla | `aws ec2 describe-availability-zones --region <r> --query 'length(AvailabilityZones)'` | Parametrizar la cantidad de AZs; no hardcodear tres |
| Las instancias Spot rotan constantemente | Mala diversificación de instance types; la estrategia de asignación es `lowest-price` | `aws ec2 describe-spot-price-history`; log de actividad del ASG | Cambiar a `price-capacity-optimized`; agregar 6–10 combinaciones tipo/AZ |
| La instancia se lanza pero falla de inmediato, sin salida de consola | Desajuste de arquitectura: un tipo `arm64` como override contra una AMI `x86_64` | Comparar `aws ec2 describe-images --image-ids <ami> --query 'Images[0].Architecture'` con la lista de overrides | Mantener una sola arquitectura por launch template, o usar `LaunchTemplateSpecification` por override |

### 8.5 Chequeo de cuotas — porque "capacidad ilimitada" es una afirmación de marketing

La elasticidad está acotada por *tus* cuotas mucho antes de estar acotada por la capacidad de AWS.

```bash
$ aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable,Unit:Unit}' --output json
{
    "Name": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
    "Value": 640.0,
    "Adjustable": true,
    "Unit": "None"
}
```
Eso son **640 vCPUs**, no 640 instancias — así que una flota de `m7i.large` (2 vCPU) tope en 320 instancias. Un `MaxSize` por encima de la cuota es una falla de escalado esperando un pico de tráfico.

```bash
# Track headroom as a first-class metric: CloudWatch usage metrics vs the quota.
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Usage \
    --metric-name ResourceCount \
    --dimensions Name=Service,Value=EC2 Name=Type,Value=Resource \
                 Name=Resource,Value=vCPU Name=Class,Value=Standard/OnDemand \
    --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text
188.0
```
188 de 640 vCPUs en uso — 29% de la cuota. Alarmá al 70%, no al 100%.

### 8.6 Verificar la decisión de selección de Region

La elección de Region es la pregunta de "beneficios" del examen disfrazada: **latencia, cumplimiento/residencia de datos, disponibilidad de servicios y costo** — en ese orden de prioridad para la mayoría de las cargas.

```bash
$ for R in us-east-1 us-west-2 eu-west-1 sa-east-1; do
    printf '%-14s ' "$R"
    curl -s -o /dev/null -w '%{time_connect}\n' "https://ec2.${R}.amazonaws.com" 
  done
us-east-1      0.021483
us-west-2      0.071204
eu-west-1      0.089771
sa-east-1      0.148392

# Cost differential for the identical shape, same command as 6.2
$ for R in us-east-1 sa-east-1; do
    printf '%-12s ' "$R"
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters 'Type=TERM_MATCH,Field=instanceType,Value=m7i.large' \
                "Type=TERM_MATCH,Field=regionCode,Value=$R" \
                'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
                'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
                'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
                'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
      --output json | jq -r '.PriceList[0] | fromjson
                             | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD'
  done
us-east-1    0.1008000000
sa-east-1    0.1710000000
```
La misma instancia, ~70% más cara en São Paulo. Si tus usuarios están en Brasil, la ganancia de latencia normalmente lo justifica; si no lo están, esto es una fuga pura de costo. **El precio varía por Region; eso es un insumo del análisis de beneficios, no una nota al pie.**

---

## 9. On-premises vs AWS — la comparación honesta

| Dimensión | Centro de datos tradicional | Nube de AWS | Dónde AWS *no* es automáticamente mejor |
|---|---|---|---|
| Modelo de capital | CapEx, depreciación a 3–5 años | OpEx, medición por segundo | Cargas estables, planas y plenamente utilizadas con un horizonte de 5+ años pueden ser más baratas on-prem |
| Tiempo hasta capacidad | Semanas a meses | Segundos a minutos | Hardware especializado con lead times largos en AWS o disponibilidad regional limitada |
| Utilización | Típicamente 10–20% (dimensionado al pico) | Sigue la demanda | Solo si realmente implementás autoscaling y rightsizing |
| Dominios de falla | Heredados de las instalaciones | Elegidos: AZ, Region, celda | Tenés que *diseñar* para ellos; un lift-and-shift de una sola instancia es menos confiable que no haber cambiado nada |
| Trabajo no diferenciador | Energía, refrigeración, racking, RMA de hardware, firmware | Responsabilidad de AWS | Aparece trabajo no diferenciador nuevo: IAM, tagging, gobernanza de costos, gestión de cuotas |
| Previsibilidad del costo | Alta (fija) | Variable — requiere gobernanza activa | El gasto cloud descontrolado es un modo de falla real; Budgets/Anomaly Detection son obligatorios, no opcionales |
| Cumplimiento | Vos atestiguás todo | Heredás las certificaciones de AWS para los controles de infraestructura | Seguís siendo dueño de todo lo que está por encima de la línea del hipervisor |
| Techo de escala | Tu orden de compra | Cuota + capacidad de AWS | No es infinito; ver §8.5 |
| Costo de egress | Tránsito a tarifa plana | Por GB, y suma | Los negocios con mucho egress de datos deben modelarlo explícitamente |

**La línea de Shared Responsibility es lo que "dejar de mantener centros de datos" significa realmente:** AWS es responsable de la seguridad **de** la nube (hardware, instalaciones, la capa de virtualización, las entrañas de los servicios gestionados); vos sos responsable de la seguridad **en** la nube (tus datos, IAM, parcheo del SO en EC2, configuración de red, decisiones de cifrado). La frontera se mueve con el modelo de servicio — para Lambda y S3 AWS es dueño de mucha más pila que para EC2. Ese desplazamiento es precisamente el beneficio de "subir en la cadena de valor".

**Beneficios de migración que el examen nombra:** las 7 R — Rehost, Replatform, Repurchase, Refactor, Retire, Retain, Relocate — y las perspectivas del AWS Cloud Adoption Framework (CAF): Business, People, Governance, Platform, Security, Operations. CLF-C02 espera que reconozcas estos términos, no que los apliques.

---

## 10. Destilado para el examen

**Reconocé estos mapeos al instante:**

| Frase del escenario en una pregunta | Concepto correcto |
|---|---|
| "Pagar solo por lo que usás, sin hardware por adelantado" | Cambiar gasto fijo por gasto variable |
| "El poder de compra de AWS nos da precios más bajos de los que conseguiríamos" | Economías de escala |
| "Agregar y quitar capacidad automáticamente cuando cambia el tráfico" | Elasticidad |
| "Manejar más carga agregando recursos" | Escalabilidad |
| "Desplegar en un país nuevo en minutos" | Alcance global / volverse global en minutos |
| "Seguir funcionando cuando falla un centro de datos" | Alta disponibilidad (Multi-AZ) |
| "Recuperarse en otra geografía tras un desastre regional" | Recuperación ante desastres (Multi-Region) |
| "Probar una idea esta tarde y borrarla mañana" | Agilidad |
| "Dejar de rackear servidores y parchear firmware" | Dejar de gastar dinero operando centros de datos |
| "Reducir el tiempo que lleva conseguir recursos nuevos" | Agilidad / velocidad |

**Hechos de frontera que más se pasan por alto:**
- Una AZ es **uno o más** centros de datos discretos — no exactamente uno.
- Los datos **no** se replican automáticamente entre Regions; tenés que configurarlo.
- Los **nombres** de AZ están aleatorizados por cuenta; los **IDs** de AZ son físicos.
- **Cada Region tiene un mínimo de tres AZs.**
- **No todos los servicios están disponibles en todas las Regions.**
- Elasticidad ≠ escalabilidad ≠ agilidad ≠ economías de escala — cuatro respuestas distintas.
- Un SLA es un contrato de crédito de servicio, no un objetivo de diseño.
- Las edge locations sirven a CloudFront/Route 53/Global Accelerator; **no** son un sustituto de AZ para HA de cómputo.
- La capacidad no es infinita: las **service quotas** la acotan, y las cuotas son por Region.

---

## 11. Referencias

**Certificación y examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Propuesta de valor de la nube y adopción**
- Overview of Amazon Web Services (AWS Whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/aws-overview/introduction.html
- AWS Cloud Adoption Framework (AWS CAF) — https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
- How AWS Pricing Works — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

**Infraestructura global**
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Regions, Availability Zones, Local Zones (EC2 User Guide) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- AZ IDs for your resources — https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
- Global infrastructure public parameters in Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html

**Confiabilidad, HA y elasticidad**
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Target tracking scaling policies — https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Predictive scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-predictive-scaling.html
- Warm pools for Amazon EC2 Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-warm-pools.html
- Auto Scaling groups with multiple instance types and purchase options — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html
- Application Load Balancer — https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
- Cross-zone load balancing — https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/how-elastic-load-balancing-works.html
- Amazon Application Recovery Controller — zonal shift — https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-shift.html
- Zonal shift in Amazon EC2 Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-zonal-shift.html
- AWS Fault Injection Service — https://docs.aws.amazon.com/fis/latest/userguide/what-is.html

**Costo y economías de escala**
- Amazon EC2 On-Demand pricing — https://aws.amazon.com/ec2/pricing/on-demand/
- Compute Savings Plans pricing — https://aws.amazon.com/savingsplans/compute-pricing/
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruption notices — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html
- AWS Cost Explorer — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/ce-what-is.html
- Amazon VPC pricing (data transfer) — https://aws.amazon.com/vpc/pricing/
- NAT Gateway pricing and design — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html

**Niveles de servicio y cuotas**
- AWS Compute SLA (EC2, ECS, EKS, Fargate, Lambda) — https://aws.amazon.com/compute/sla/
- Elastic Load Balancing SLA — https://aws.amazon.com/elasticloadbalancing/sla/
- All AWS Service Level Agreements — https://aws.amazon.com/legal/service-level-agreements/
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- Troubleshoot instance launch issues (InsufficientInstanceCapacity) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/troubleshooting-launch.html

**Entrega global**
- Amazon CloudFront Developer Guide — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
- AWS Global Accelerator — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 routing policies — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html
- Aurora Global Database — https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html
- DynamoDB Global Tables — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html

**Infraestructura como código y Kubernetes**
- AWS CloudFormation template reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-reference.html
- `Fn::Cidr` intrinsic function — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-cidr.html
- Terraform AWS provider — `aws_availability_zones` — https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones
- Kubernetes Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes Pod Disruption Budgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/