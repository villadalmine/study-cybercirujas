# 4.1 — Comparar los modelos de precios de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02), v1.0
**Dominio 4:** Facturación, precios y soporte — **Tarea 4.1**, peso en el examen **4.0**
**Perfil de la audiencia:** Platform Architect / SRE. Este material asume que ya operás infraestructura y trata los precios como una *restricción de diseño de sistemas*, no como un tema contable.

> **Aviso sobre precios — leelo una vez, aplicalo en todo lo que sigue.**
> Toda cifra en dólares de este documento es un **precio de lista ilustrativo para `us-east-1` al momento de escribir**, usado para hacer concreta la aritmética. Los precios de AWS cambian y varían según la Región. La **fuente de verdad es la AWS Price List API**, y el §4 te muestra cómo consultarla. Lo que *sí* es estable — y lo que el examen realmente evalúa — es la **relación** entre los modelos: cuál carga riesgo de compromiso, cuál carga riesgo de disponibilidad, cuál no carga ninguno, y qué te cuesta cada uno en flexibilidad.

---

## 1. Motivación: el problema arquitectónico debajo de la lista de precios

### 1.1 El problema real no es el "costo", es un desajuste entre compromiso y elasticidad

Una plataforma en producción tiene una curva de carga. Esa curva se descompone en tres capas, y **cada capa tiene una opción de compra correcta distinta**:

```
capacity
   ▲
   │                          ╭──╮        ← LAYER 3: burst / batch / CI
   │                     ╭────╯  ╰──╮        interruptible, elastic, spiky
   │        ╭──╮    ╭────╯          ╰───╮
   │   ╭────╯  ╰────╯                   ╰─╮  ← LAYER 2: diurnal peak
   │───┴──────────────────────────────────┴─   predictable shape, not 24/7
   │████████████████████████████████████████  ← LAYER 1: steady-state floor
   │████████████████████████████████████████     runs 24/7/365
   └────────────────────────────────────────▶ time
```

El modo de falla no es "elegimos la opción cara". El modo de falla es **aplicar una sola opción de compra a toda la curva**:

| Antipatrón | Consecuencia |
|---|---|
| 100% On-Demand | Pagás un sobreprecio de ~40–70% sobre el piso de estado estacionario, para siempre. Es la factura cloud más común de una Serie B. |
| 100% Reserved / Savings Plans, dimensionado al pico | Pagás por el pico las 8.760 horas del año. La utilización cae al 40–60%; el descuento *efectivo* se vuelve negativo frente a On-Demand. |
| 100% Spot | La primera contracción de capacidad regional te tira abajo el control plane. Spot es un mercado de capacidad, no un cupón de descuento. |
| Compromiso dimensionado a la arquitectura de *hoy* | Comprás una RI x86 a 3 años, migrás a Graviton o a contenedores en el mes 8 y dejás el compromiso varado. |

**El enunciado arquitectónico de la tarea 4.1 es:** *descomponé la curva de carga y después emparejá cada capa con la opción de compra cuyo perfil de riesgo coincida con la tolerancia de esa capa.*

### 1.2 La filosofía de precios declarada por AWS (encuadre a nivel examen)

AWS reduce toda su historia de precios a tres principios. Conocelos casi textualmente:

1. **Pay-as-you-go** — sin capex inicial, sin contrato de largo plazo obligatorio, pagás solo por lo que consumís y dejás de pagar cuando dejás de usarlo.
2. **Save when you commit** — Savings Plans y Reserved Instances cambian flexibilidad por un descuento de hasta ~72%.
3. **Pay less by using more** — precios escalonados / por volumen (niveles de almacenamiento de S3, niveles de transferencia de datos de salida, agregación por consolidated billing).

### 1.3 Los tres factores fundamentales de costo

Sea cual sea el servicio, una factura de AWS está dominada por tres dimensiones. Hacele estas tres preguntas a cualquier arquitectura:

| Factor | Qué significa | La trampa |
|---|---|---|
| **Cómputo** | Se cobra por unidad de tiempo en que una instancia/función/tarea está *aprovisionada o corriendo*. | Tiempo, no utilización. Una `m6i.24xlarge` ociosa cuesta lo mismo que una saturada. |
| **Almacenamiento** | Se cobra por GB-mes, más *requests*, más *recuperación*, más *duración mínima*. | La gente compara solo la tarifa por GB-mes e ignora las otras tres. |
| **Transferencia de datos** | **La entrada hacia AWS es en general gratis. La salida a internet y el tráfico que cruza fronteras de AZ/Región no lo son.** | Es el ítem que nadie modeló, y está determinado por la arquitectura — no podés comprar un descuento para una topología mala. |

---

## 2. Las opciones de compra de cómputo: comparación técnica completa

### 2.1 Las seis opciones de un vistazo

| Opción | Compromiso | Descuento vs On-Demand | Garantía de capacidad | AWS puede interrumpirla | Flexibilidad |
|---|---|---|---|---|---|
| **On-Demand** | Ninguno | 0% (línea base) | No (best-effort) | No | Total |
| **Compute Savings Plans** | $/hr por 1 o 3 años | hasta ~66% | **No** | No | La más alta de todas las opciones con compromiso — cualquier Región, familia, tamaño, SO, tenancy; más Fargate y Lambda |
| **EC2 Instance Savings Plans** | $/hr por 1 o 3 años | hasta ~72% | **No** | No | Atado a una **familia de instancias en una Región**; flexible en tamaño, SO, tenancy, AZ |
| **Standard Reserved Instances** | Configuración de instancia por 1 o 3 años | hasta ~72% | **Sí, si es zonal** | No | La más baja — no se puede cambiar de familia; *sí* se pueden vender en el RI Marketplace |
| **Convertible Reserved Instances** | Configuración de instancia por 1 o 3 años | hasta ~66% | No (solo regional) | No | Se pueden intercambiar por otra familia/SO/tenancy de valor igual o mayor; no se pueden vender |
| **Spot Instances** | Ninguno | hasta **~90%** | No | **Sí — aviso de 2 minutos** | Total, pero debe tolerar interrupciones |

Más dos opciones de tenancy/aislamiento que **no** son descuentos:

| Opción | Qué comprás realmente | Por qué lo comprarías |
|---|---|---|
| **Dedicated Instance** | Instancias sobre hardware dedicado a tu cuenta. Se factura por instancia, **más un cargo por Región, por hora, de dedicated-instance** (≈$2/hr) cobrado una sola vez sin importar cuántas corras. | Requisito de cumplimiento de aislamiento físico. |
| **Dedicated Host** | Un **servidor físico** entero, facturado por host. Obtenés visibilidad de **sockets, cores físicos y host ID**, más afinidad de host. | **BYOL para licencias atadas a socket/core** (Windows Server, SQL Server, Oracle) y reglas regulatorias que exigen un host físico nombrable. |

> **Discriminador de examen:** si la pregunta menciona *"licencia de software existente por socket o por core"* o *"visibilidad del host físico"* → **Dedicated Host**. Si solo dice *"hardware no compartido con otros clientes"* → **Dedicated Instance**.

### 2.2 Savings Plans vs Reserved Instances — la decisión que realmente importa

| Dimensión | Savings Plans | Reserved Instances |
|---|---|---|
| Unidad de compromiso | **Dólares por hora** de gasto de cómputo | **Una configuración de instancia específica** (familia, tamaño, SO, tenancy, Región/AZ) |
| Cubre EC2 | Sí | Sí |
| Cubre Fargate | **Sí** (solo Compute SP) | No |
| Cubre Lambda | **Sí** (solo Compute SP — duración/GB-s y Provisioned Concurrency; **los cargos por request no están cubiertos**) | No |
| Cubre Dedicated Hosts | **No** — usá Dedicated Host Reservations | Las Dedicated Host Reservations son un producto aparte |
| Cubre Spot | **No** (Spot ya viene con descuento) | No |
| Flexibilidad de tamaño de instancia | Sí, inherente | Solo para RIs **Regionales**, Linux/UNIX, tenancy default, misma familia+generación |
| Flexibilidad de Región | **Compute SP: sí.** EC2 Instance SP: no | No |
| Flexibilidad de SO | Sí | No — una RI de Linux nunca cubre una instancia RHEL o Windows |
| Provee una **reserva de capacidad** | **Nunca** | **Solo las RIs zonales.** Las RIs regionales dan un descuento de facturación y flexibilidad de AZ, *no* capacidad |
| Se puede cancelar | **No** | **No** — pero las Standard RIs se pueden **vender en el RI Marketplace** |
| Se puede modificar/intercambiar | No (comprá un plan adicional) | Standard: modificar AZ/scope/tamaño. Convertible: **intercambiar** por valor igual o mayor |
| Se aplica automáticamente al uso que coincide | Sí | Sí |

**Default del arquitecto:** para una plataforma moderna, con mucho contenedor y en evolución activa, los **Compute Savings Plans** son el default correcto para el piso de estado estacionario. Resignás ~6 puntos porcentuales de descuento frente a un EC2 Instance SP y ~6 frente a una Standard RI, y a cambio el compromiso sobrevive a una migración a Graviton, a la adopción de EKS, al agregado de una Región y a un movimiento de EC2 a Fargate. Esa opcionalidad vale muchísimo más que 6 puntos para cualquiera que alguna vez haya dejado varada una RI a 3 años.

**Comprá RIs zonales solo cuando necesitás la reserva de capacidad en sí** — un singleton atado a una licencia, un primario con estado que debe volver en una AZ específica después de una falla.

### 2.3 Opciones de pago (este es un eje separado — no lo confundas con el término)

Todo producto con compromiso tiene **término** (1 o 3 años) × **opción de pago** (All Upfront / Partial Upfront / No Upfront). Son ortogonales.

| Opción de pago | Flujo de caja | Descuento relativo |
|---|---|---|
| **All Upfront** | 100% pagado en la compra, $0 por hora | El mayor |
| **Partial Upfront** | ~50% en la compra + tarifa horaria reducida | Intermedio |
| **No Upfront** | $0 en la compra, tarifa horaria completa cada hora del término | El menor |

La diferencia entre All Upfront y No Upfront es típicamente de solo **2–4 puntos porcentuales**. Eso es un retorno anual implícito de un dígito bajo. A menos que tu organización tenga efectivo genuinamente ocioso, **No Upfront suele ser la elección racional** — te quedás con el capital y no perdés casi nada.

> **Mecánica crítica:** con **No Upfront**, igual se te factura el compromiso horario **cada hora del término, lo uses o no**. "No Upfront" significa que no hay *pago único*; no significa que no haya obligación.

### 2.4 La identidad de break-even que todo SRE debería memorizar

Un compromiso factura 24/7 durante todo el término. On-Demand factura solo las horas en ejecución. Entonces:

$$\text{break-even utilization} = \frac{\text{committed rate}}{\text{On-Demand rate}} = 1 - \text{discount}$$

| Descuento | Uptime mínimo para que gane el compromiso | Horas/mes (de 730) |
|---|---|---|
| 27% | 73% | 533 |
| 30% | 70% | 511 |
| 40% | 60% | 438 |
| 50% | 50% | 365 |
| 66% | 34% | 248 |
| 72% | 28% | 204 |

**Ejemplo resuelto.** `m6i.large` On-Demand = **$0.096/hr**. La tarifa de un Compute Savings Plan No Upfront a 1 año ≈ **$0.0673/hr** (30% de descuento).

```
Commitment cost per month  = 0.0673 × 730 = $49.13   (fixed, always)
On-Demand cost for H hours = 0.096  × H

Break-even: 0.096 × H = 49.13  →  H = 512 hours/month = 70% uptime
```

Así que una instancia de entorno de desarrollo que corre 10h × 5d = ~217 h/mes (**30% de uptime**) es **catastróficamente equivocada** para un SP a 1 año al 30% — pagarías $49.13 en lugar de $20.83. Pero la misma instancia bajo un **Compute SP a 3 años All Upfront al ~58%** llega al break-even con 42% de uptime — sigue estando mal. Los entornos de desarrollo van sobre **schedulers + On-Demand + Spot**, nunca sobre compromisos.

### 2.5 Flexibilidad de tamaño en Reserved Instances — la aritmética del factor de normalización

Una RI **Regional** para **Linux/UNIX con tenancy default** se aplica a lo largo de los tamaños *dentro de la misma familia y generación*, usando factores de normalización:

| Tamaño | Factor | Tamaño | Factor |
|---|---|---|---|
| nano | 0.25 | 4xlarge | 32 |
| micro | 0.5 | 8xlarge | 64 |
| small | 1 | 9xlarge | 72 |
| medium | 2 | 10xlarge | 80 |
| large | 4 | 12xlarge | 96 |
| xlarge | 8 | 16xlarge | 128 |
| 2xlarge | 16 | 24xlarge | 192 |
| 3xlarge | 24 | 32xlarge | 256 |

Una RI Regional para **`m6i.xlarge`** (factor 8) cubre completamente **cualquiera** de:

- 2 × `m6i.large` (4 + 4 = 8) ✅
- 1 × `m6i.2xlarge` al **50%** — la mitad restante se factura On-Demand ✅
- 8 × `m6i.small`… (no existe en esta familia, pero la aritmética se sostiene donde sí existe)
- 1 × `m5.xlarge` ❌ — **generación distinta, sin cobertura**
- 1 × `c6i.xlarge` ❌ — **familia distinta, sin cobertura**
- 1 × `m6i.xlarge` corriendo **RHEL** ❌ — **plataforma no coincide**

### 2.6 Orden de aplicación de descuentos (por qué tu factura se ve "mal")

Para una hora de uso dada, AWS aplica los descuentos en un orden fijo. Equivocarse acá causa horas de arqueología confundida sobre el CUR:

```
1. Zonal Reserved Instances        (matching AZ + config)
2. Regional Reserved Instances     (matching Region + config, with size flexibility)
3. EC2 Instance Savings Plans      (matching family + Region)
4. Compute Savings Plans           (any eligible EC2/Fargate/Lambda usage)
5. Remaining usage                 → billed at On-Demand rates
```

Dentro de los Savings Plans, AWS aplica el compromiso primero al uso con el **mayor porcentaje de descuento**, para maximizar tu ahorro automáticamente. No lo dirigís vos — y no podés hacerlo.

**Consecuencia:** si tenés RIs *y* Savings Plans para la misma flota, las RIs consumen el uso primero, lo que puede dejar varado al Savings Plan y llevar su utilización por debajo del 100%. No apiles compromisos sobre la misma carga de trabajo sin modelarlo.

### 2.7 Spot Instances: un mercado de capacidad, no un cupón

Spot te vende el **pool de capacidad no utilizada** de EC2 en una AZ dada para un tipo de instancia dado. AWS la reclama cuando la necesita de vuelta.

| Mecánica | Comportamiento |
|---|---|
| Precio | Fijado por oferta/demanda de largo plazo por tipo de instancia por AZ; cambia **gradualmente**, no por puja. Siempre pagás el precio Spot *actual*, nunca más que tu máximo. |
| Aviso de interrupción | **2 minutos**, entregado vía metadatos de instancia y un evento de EventBridge. |
| Aviso anticipado | **EC2 Instance Rebalance Recommendation** — se dispara *antes* del aviso de 2 minutos cuando la instancia está en riesgo elevado de interrupción. |
| Comportamiento ante interrupción | `terminate` (default), `stop` o `hibernate`. |
| Estrategia de asignación | **`price-capacity-optimized` es el default recomendado** — elige pools con la mayor profundidad de capacidad entre los más baratos. `capacity-optimized` maximiza la profundidad del pool; `lowest-price` maximiza la tasa de interrupción; `diversified` reparte entre pools. |

**La diversificación es el mecanismo de disponibilidad.** Una solicitud Spot fijada a un tipo de instancia en una AZ es un punto único de falla. Una solicitud que abarca 15 tipos en 3 AZs es estadísticamente robusta. Por eso existe la **selección de instancias basada en atributos** (§3.1) — describís *"≥4 vCPU, ≥8 GiB, generación actual"* y dejás que EC2 elija entre todos los pools que coincidan.

**Encaja en Spot:** capas web/API sin estado detrás de un ALB, runners de CI, batch/ETL, codificación de video, entrenamiento de ML con checkpointing, nodos worker de Kubernetes para pods tolerantes a interrupción.
**Nunca Spot:** control planes de Kubernetes, primarios con estado sin failover automatizado, singletons atados a licencias, cualquier cosa cuyo reinicio tarde más de 2 minutos y no pueda hacer checkpoint.

### 2.8 Productos de capacidad que no son descuentos

| Producto | Qué hace | Facturación |
|---|---|---|
| **On-Demand Capacity Reservation (ODCR)** | Reserva capacidad en una **AZ específica** sin compromiso de término; se crea y se cancela en cualquier momento. | Se factura a tarifas On-Demand **corras o no instancias en ella** — pero **las RIs y los Savings Plans sí se aplican** a las horas de ODCR. |
| **Capacity Blocks for ML** | Reservá capacidad de GPU/aceleradores para una **fecha futura y duración fija**. | Pagado por adelantado en la compra. |
| **Dedicated Host Reservation** | El producto con compromiso para Dedicated Hosts (los Savings Plans **no** se aplican). | 1 o 3 años, con opciones de pago upfront. |

> **Discriminador de examen:** *"necesito un descuento"* → Savings Plan / RI. *"necesito estar seguro de que la capacidad va a estar"* → RI zonal u ODCR. *"necesito las dos cosas"* → RI zonal, u ODCR + Savings Plan.

---

## 3. Manifiestos de infraestructura completos

### 3.1 CloudFormation — Auto Scaling group con una política mixta de opciones de compra

Esta es la implementación canónica del §1.1: una base On-Demand (cubierta por un Savings Plan) más Spot por encima, con selección de instancias basada en atributos para diversidad de pools y Capacity Rebalancing habilitado.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Mixed purchase-option ASG. On-Demand base capacity carries the steady-state
  floor (covered by a Compute Savings Plan); Spot carries all burst above it.
  Attribute-based instance selection maximises the number of Spot pools.

Parameters:
  VpcSubnets:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Private subnets, at least three distinct Availability Zones.
  InstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup::Id
  TargetGroupArn:
    Type: String
    Description: ALB target group the ASG registers into.
  AmiId:
    Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  OnDemandBase:
    Type: Number
    Default: 4
    Description: Instances always launched On-Demand. Size this to the 24/7 floor.
  OnDemandPercentAboveBase:
    Type: Number
    Default: 20
    Description: Percentage of capacity above the base that is On-Demand.

Resources:

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

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-lt'
      LaunchTemplateData:
        ImageId: !Ref AmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref InstanceSecurityGroup
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 2
        Monitoring:
          Enabled: true
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 30
              # gp3 decouples IOPS from capacity: 3000 IOPS and 125 MB/s are
              # included at no extra charge, unlike gp2 where IOPS scale with GB.
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${AWS::StackName}-node'
              # Cost allocation tags must be activated in Billing before they
              # appear in Cost Explorer or the CUR.
              - Key: cost-center
                Value: platform-core
              - Key: environment
                Value: production
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail
            dnf -y install amazon-cloudwatch-agent
            # Poll IMDSv2 for the Spot interruption notice and drain gracefully.
            cat >/usr/local/bin/spot-watch.sh <<'EOF'
            #!/bin/bash
            while true; do
              TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
              CODE=$(curl -s -o /dev/null -w '%{http_code}' \
                -H "X-aws-ec2-metadata-token: $TOKEN" \
                http://169.254.169.254/latest/meta-data/spot/instance-action)
              if [ "$CODE" = "200" ]; then
                logger -t spot-watch "interruption notice received; draining"
                systemctl stop app.service
                exit 0
              fi
              sleep 5
            done
            EOF
            chmod +x /usr/local/bin/spot-watch.sh
            nohup /usr/local/bin/spot-watch.sh &

  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${AWS::StackName}-asg'
      MinSize: 4
      MaxSize: 60
      DesiredCapacity: 6
      VPCZoneIdentifier: !Ref VpcSubnets
      TargetGroupARNs:
        - !Ref TargetGroupArn
      HealthCheckType: ELB
      HealthCheckGracePeriod: 180
      # Proactively replace Spot instances that receive a rebalance
      # recommendation, before the 2-minute termination notice fires.
      CapacityRebalance: true
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: !Ref OnDemandBase
          OnDemandPercentageAboveBaseCapacity: !Ref OnDemandPercentAboveBase
          OnDemandAllocationStrategy: lowest-price
          # price-capacity-optimized: cheapest pools among those with the
          # deepest available capacity. Lowest interruption rate per dollar.
          SpotAllocationStrategy: price-capacity-optimized
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            # Attribute-based selection: describe the shape, let EC2 enumerate
            # every matching pool. This is the single biggest lever on Spot
            # interruption rate.
            - InstanceRequirements:
                VCpuCount:
                  Min: 4
                  Max: 8
                MemoryMiB:
                  Min: 8192
                  Max: 32768
                CpuManufacturers:
                  - intel
                  - amd
                InstanceGenerations:
                  - current
                BurstablePerformance: excluded
                BareMetal: excluded
                AcceleratorCount:
                  Max: 0
                # Reject any pool priced more than 25% above the cheapest
                # instance type that satisfies the requirements above.
                SpotMaxPricePercentageOverLowestPrice: 125
      Tags:
        - Key: cost-center
          Value: platform-core
          PropagateAtLaunch: true
        - Key: environment
          Value: production
          PropagateAtLaunch: true

  TargetTrackingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ASGAverageCPUUtilization
        TargetValue: 65.0
        DisableScaleIn: false

Outputs:
  AutoScalingGroupName:
    Value: !Ref AutoScalingGroup
  LaunchTemplateId:
    Value: !Ref LaunchTemplate
```

### 3.2 Karpenter — la política de opciones de compra de Kubernetes como configuración declarativa

En EKS, Karpenter expresa el mismo esquema de capas, con la capacidad añadida de *consolidar* nodos cuando los pods se drenan — convirtiendo automáticamente la capacidad no utilizada de vuelta en ahorro On-Demand.

```yaml
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: KarpenterNodeRole-prod
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required
    httpPutResponseHopLimit: 1
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  tags:
    cost-center: platform-core
    environment: production
    managed-by: karpenter
---
# LAYER 1+2 — On-Demand. Higher weight => Karpenter prefers this pool first.
# Sized to the steady-state floor and covered by a Compute Savings Plan.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: on-demand-baseline
spec:
  weight: 50
  template:
    metadata:
      labels:
        workload-class: baseline
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]          # Graviton: better price/performance
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
      terminationGracePeriod: 1h
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "10%"
      - nodes: "0"
        schedule: "0 13 * * mon-fri"   # freeze disruption during peak
        duration: 6h
  limits:
    cpu: "400"
    memory: 1600Gi
---
# LAYER 3 — Spot. Lower weight => used only after the baseline pool is full.
# Deliberately wide requirements: more pools => fewer interruptions.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-burst
spec:
  weight: 10
  template:
    metadata:
      labels:
        workload-class: interruptible
    spec:
      taints:
        - key: capacity-type
          value: spot
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16", "32"]
        - key: karpenter.k8s.aws/instance-hypervisor
          operator: In
          values: ["nitro"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 168h
      terminationGracePeriod: 5m
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "20%"
  limits:
    cpu: "2000"
    memory: 8000Gi
---
# Interruptible workloads opt in with a toleration; everything else stays
# on the baseline pool by default. Fail-safe: forget the toleration and you
# land on On-Demand, not on Spot.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-transcoder
  namespace: media
spec:
  replicas: 24
  selector:
    matchLabels:
      app: image-transcoder
  template:
    metadata:
      labels:
        app: image-transcoder
    spec:
      terminationGracePeriodSeconds: 100   # < the 120 s Spot notice
      tolerations:
        - key: capacity-type
          operator: Equal
          value: spot
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: image-transcoder
      containers:
        - name: transcoder
          image: 111122223333.dkr.ecr.us-east-1.amazonaws.com/transcoder:1.14.2
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              memory: 2Gi
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "/app/drain.sh && sleep 20"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: image-transcoder
  namespace: media
spec:
  minAvailable: 60%
  selector:
    matchLabels:
      app: image-transcoder
```

### 3.3 Terraform — barandas de FinOps (budgets, detección de anomalías, CUR)

Compromisos sin observabilidad es como descubrís una RI varada once meses tarde.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"   # Billing/CE/Budgets APIs are us-east-1 global endpoints
}

variable "finops_email" {
  type    = string
  default = "finops@example.com"
}

variable "monthly_budget_usd" {
  type    = number
  default = 42000
}

# ---------------------------------------------------------------------------
# 1. Cost budget with forecast + actual alerts.
#    Forecast alerts fire early enough to act; actual alerts fire too late.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "platform_monthly" {
  name         = "platform-core-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    # Amortized spreads upfront RI/SP fees across the term instead of
    # spiking the purchase month. Always use this for commitment tracking.
    use_amortized              = true
    use_blended                = false
  }

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:cost-center$platform-core"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 2. Savings Plans utilization budget.
#    Utilization below 100% means you are paying for commitment you do not use.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "sp_utilization" {
  name         = "savings-plans-utilization-floor"
  budget_type  = "SAVINGS_PLANS_UTILIZATION"
  limit_amount = "99"
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "LESS_THAN"
    threshold                  = 99
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 3. RI utilization budget — same logic, for the RI portfolio.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "ri_utilization" {
  name         = "reserved-instance-utilization-floor"
  budget_type  = "RI_UTILIZATION"
  limit_amount = "95"
  limit_unit   = "PERCENTAGE"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "LESS_THAN"
    threshold                  = 95
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.finops_email]
  }
}

# ---------------------------------------------------------------------------
# 4. Cost Anomaly Detection — ML baseline per service, no threshold to tune.
# ---------------------------------------------------------------------------
resource "aws_ce_anomaly_monitor" "by_service" {
  name              = "anomaly-monitor-by-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "daily_digest" {
  name      = "anomaly-subscription-daily"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.by_service.arn]

  subscriber {
    type    = "EMAIL"
    address = var.finops_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["250"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Cost and Usage Report — the only dataset with per-resource, per-hour
#    unblended, amortized and effective-cost columns. Cost Explorer is a UI;
#    the CUR is the ledger.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cur" {
  bucket = "cur-111122223333-us-east-1"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cur" {
  bucket                  = aws_s3_bucket.cur.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cur_bucket" {
  statement {
    sid    = "AllowBillingReportsWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl", "s3:GetBucketPolicy", "s3:PutObject"]
    resources = [aws_s3_bucket.cur.arn, "${aws_s3_bucket.cur.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "cur" {
  bucket = aws_s3_bucket.cur.id
  policy = data.aws_iam_policy_document.cur_bucket.json
}

resource "aws_cur_report_definition" "hourly" {
  report_name                = "platform-cur-hourly"
  time_unit                  = "HOURLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES", "SPLIT_COST_ALLOCATION_DATA"]
  s3_bucket                  = aws_s3_bucket.cur.id
  s3_prefix                  = "cur"
  s3_region                  = "us-east-1"
  additional_artifacts       = ["ATHENA"]
  report_versioning          = "OVERWRITE_REPORT"
  refresh_closed_reports     = true

  depends_on = [aws_s3_bucket_policy.cur]
}
```

---

## 4. CLI: conseguir números reales en lugar de adivinar

### 4.1 Consultar la Price List API para la línea base On-Demand

La Price List Query API está disponible solo desde `us-east-1`, `ap-south-1` y `eu-central-1`, pero devuelve precios de **todas** las Regiones vía el filtro `regionCode`.

```console
$ aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
        'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
        'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
        'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
        'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
        'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
        'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
    --output json \
  | jq -r '.PriceList[] | fromjson
           | .terms.OnDemand[].priceDimensions[]
           | "\(.pricePerUnit.USD)\t\(.unit)\t\(.description)"'
0.0960000000	Hrs	$0.096 per On Demand Linux m6i.large Instance Hour
```

> **`capacitystatus=Used` importa.** Sin eso también coincidís con SKUs de `UnusedCapacityReservation` y `AllocatedCapacityReservation` y obtenés tres filas con significados distintos.

Comparar la misma instancia entre Regiones — la palanca de costo arquitectónica más común, y una que la gente olvida que existe:

```console
$ for R in us-east-1 us-west-2 eu-west-1 ap-southeast-1 sa-east-1; do
    P=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters "Type=TERM_MATCH,Field=instanceType,Value=m6i.large" \
                "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
                "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
                "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
                "Type=TERM_MATCH,Field=regionCode,Value=${R}" \
      --output json \
      | jq -r '.PriceList[0] | fromjson
               | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD')
    printf '%-16s %s\n' "$R" "$P"
  done
us-east-1        0.0960000000
us-west-2        0.0960000000
eu-west-1        0.1070000000
ap-southeast-1   0.1160000000
sa-east-1        0.1530000000
```

`sa-east-1` es **59% más caro** que `us-east-1` por hardware idéntico. Ninguna opción de compra recupera eso; solo la topología.

### 4.2 Comparar tarifas con compromiso para la misma instancia

```console
$ aws savingsplans describe-savings-plans-offering-rates \
    --region us-east-1 \
    --service-codes AmazonEC2 \
    --products EC2 \
    --savings-plan-types Compute EC2Instance \
    --savings-plan-payment-options "No Upfront" "All Upfront" \
    --filters name=instanceType,values=m6i.large \
              name=region,values=us-east-1 \
              name=tenancy,values=shared \
              name=productDescription,values=Linux/UNIX \
    --output json \
  | jq -r '.searchResults[]
           | [ .savingsPlanOffering.planType,
               .savingsPlanOffering.durationSeconds/31536000,
               .savingsPlanOffering.paymentOption,
               .rate ] | @tsv' | sort
Compute      1   All Upfront   0.0648000000
Compute      1   No Upfront    0.0673000000
Compute      3   All Upfront   0.0402000000
Compute      3   No Upfront    0.0433000000
EC2Instance  1   All Upfront   0.0590000000
EC2Instance  1   No Upfront    0.0614000000
EC2Instance  3   All Upfront   0.0334000000
EC2Instance  3   No Upfront    0.0353000000
```

Leyendo esta tabla como arquitecto:

| Tarifa | vs On-Demand ($0.096) | Uptime de break-even | Veredicto |
|---|---|---|---|
| Compute 1 año No Upfront `0.0673` | −29.9% | 70% | Default seguro. Sobrevive cambios de Región/familia/Fargate/Lambda. |
| EC2Instance 1 año No Upfront `0.0614` | −36.0% | 64% | +6 pts, pero atado a `m6i` en `us-east-1`. |
| Compute 3 años No Upfront `0.0433` | −54.9% | 45% | Fuerte, pero tres años es más de lo que vive la mayoría de las arquitecturas. |
| EC2Instance 3 años All Upfront `0.0334` | −65.2% | 35% | Descuento máximo, lock-in máximo. Solo para una flota realmente congelada. |

La diferencia entre All Upfront y No Upfront en el plan Compute a 1 año es `0.0673 → 0.0648` = **3.7%**. Ese es el precio de tu capital por un año.

### 4.3 ¿Qué recomienda Cost Explorer?

```console
$ aws ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP \
    --term-in-years ONE_YEAR \
    --payment-option NO_UPFRONT \
    --lookback-period-in-days SIXTY_DAYS \
    --account-scope PAYER \
    --output json | jq '.SavingsPlansPurchaseRecommendation
        | {Summary: .SavingsPlansPurchaseRecommendationSummary}'
{
  "Summary": {
    "EstimatedROI": "42.7",
    "CurrencyCode": "USD",
    "EstimatedTotalCost": "231045.60",
    "CurrentOnDemandSpend": "329932.80",
    "EstimatedSavingsAmount": "98887.20",
    "TotalRecommendationCount": "1",
    "DailyCommitmentToPurchase": "633.00",
    "HourlyCommitmentToPurchase": "26.38",
    "EstimatedSavingsPercentage": "29.97",
    "EstimatedMonthlySavingsAmount": "8240.60",
    "EstimatedOnDemandCostWithCurrentCommitment": "329932.80"
  }
}
```

> **No compres este número a ciegas.** Cost Explorer recomienda contra tu uso *histórico* durante la ventana de lookback. No sabe nada de la migración a Graviton del roadmap del próximo trimestre, de la Región que estás por desmantelar, ni de la consolidación de EKS que va a recortar el conteo de nodos en un 30%. **Una práctica común es comprometerse a ~70–80% de la recomendación** y ampliar después; siempre podés comprar otro Savings Plan, pero nunca podés cancelar uno.

### 4.4 Verificar lo que ya tenés

```console
$ aws savingsplans describe-savings-plans \
    --states active \
    --output table \
    --query 'savingsPlans[].[savingsPlanType,paymentOption,commitment,
                             ec2InstanceFamily,region,start,end]'
------------------------------------------------------------------------------------------------------
|                                        DescribeSavingsPlans                                        |
+-------------+-------------+---------+---------+-------------+------------------------+-------------+
|  Compute    |  No Upfront |  18.00  |  None   |  None       |  2026-02-01T00:00:00Z  | 2027-02-01T00:00:00Z |
|  EC2Instance|  All Upfront|   6.50  |  m6i    |  us-east-1  |  2025-11-15T00:00:00Z  | 2026-11-15T00:00:00Z |
+-------------+-------------+---------+---------+-------------+------------------------+-------------+
```

```console
$ aws ec2 describe-reserved-instances \
    --filters Name=state,Values=active \
    --query 'ReservedInstances[].[ReservedInstancesId,InstanceType,Scope,
             AvailabilityZone,ProductDescription,InstanceCount,OfferingClass,End]' \
    --output table
--------------------------------------------------------------------------------------------------------------
|                                          DescribeReservedInstances                                         |
+--------------------------------------+--------------+----------+-------------+--------------+----+--------+
|  aaaaaaaa-1111-2222-3333-444444444444 | m6i.xlarge   | Region   | None        | Linux/UNIX   | 8  | standard | 2027-03-01T00:00:00Z |
|  bbbbbbbb-5555-6666-7777-888888888888 | r6i.2xlarge  | Availability Zone | us-east-1b | Linux/UNIX | 2 | standard | 2026-10-12T00:00:00Z |
|  cccccccc-9999-aaaa-bbbb-cccccccccccc | m5.large     | Region   | None        | Red Hat Enterprise Linux | 4 | convertible | 2026-09-30T00:00:00Z |
+--------------------------------------+--------------+----------+-------------+--------------+----+--------+
```

Tres cosas que un arquitecto lee de esa tabla de inmediato:
- La fila 1 es **Regional + Linux + standard** → flexible en tamaño a lo largo de toda la familia `m6i`, 8 × factor-8 = **64 unidades normalizadas**.
- La fila 2 es **zonal en `us-east-1b`** → carga una reserva de capacidad, pero cero flexibilidad de AZ o de tamaño. Si esas instancias se mueven a `1c`, la cobertura cae a **0%**.
- La fila 3 es **RHEL** → nunca va a cubrir una instancia Amazon Linux, y vence en 26 días.

### 4.5 Spot: medí el mercado antes de diseñar para él

```console
$ aws ec2 describe-spot-price-history \
    --instance-types m6i.large m6a.large m5.large c6i.large r6i.large \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(SpotPriceHistory,&SpotPrice)[].[InstanceType,AvailabilityZone,SpotPrice]' \
    --output table
------------------------------------------
|         DescribeSpotPriceHistory        |
+--------------+---------------+----------+
|  m6a.large   |  us-east-1d   |  0.0289  |
|  m5.large    |  us-east-1c   |  0.0312  |
|  m6i.large   |  us-east-1b   |  0.0341  |
|  c6i.large   |  us-east-1a   |  0.0358  |
|  m6i.large   |  us-east-1a   |  0.0373  |
|  r6i.large   |  us-east-1f   |  0.0489  |
+--------------+---------------+----------+
```

`m6i.large` en Spot a `$0.0341` está **64% por debajo de On-Demand** y todavía **por debajo de la mejor tarifa con compromiso a 1 año** — sin compromiso alguno, al precio de la interrumpibilidad.

Antes de planificar una flota Spot grande, preguntale a EC2 si la capacidad existe:

```console
$ aws ec2 get-spot-placement-scores \
    --instance-requirements-with-metadata '{
      "ArchitectureTypes": ["x86_64", "arm64"],
      "VirtualizationTypes": ["hvm"],
      "InstanceRequirements": {
        "VCpuCount": {"Min": 4, "Max": 16},
        "MemoryMiB": {"Min": 8192, "Max": 65536},
        "InstanceGenerations": ["current"],
        "BurstablePerformance": "excluded",
        "BareMetal": "excluded"
      }
    }' \
    --target-capacity 500 \
    --target-capacity-unit-type units \
    --single-availability-zone \
    --region-names us-east-1 us-west-2 eu-west-1 \
    --output table
--------------------------------------
|      GetSpotPlacementScores        |
+---------------------+-------+------+
|  us-east-1a         |   9   |      |
|  us-west-2b         |   9   |      |
|  us-west-2c         |   8   |      |
|  eu-west-1a         |   7   |      |
|  us-east-1e         |   4   |      |
+---------------------+-------+------+
```

El puntaje va de **1 a 10**; es una *probabilidad relativa de cumplimiento sin interrupción*, no una garantía y no una señal de precio. Cualquier valor ≤5 para un objetivo de 500 unidades significa: ampliá los requisitos o achicá el objetivo.

### 4.6 Rightsizing — el descuento que obtenés antes de comprar cualquier descuento

**Nunca te comprometas con una flota que no dimensionaste bien.** Un Savings Plan sobre una flota sobreaprovisionada fija el desperdicio por un año.

```console
$ aws compute-optimizer get-ec2-instance-recommendations \
    --filters name=Finding,values=Overprovisioned \
    --output json \
  | jq -r '.instanceRecommendations[]
      | [ .instanceName,
          .currentInstanceType,
          .finding,
          (.utilizationMetrics[] | select(.name=="CPU") | .value | floor),
          .recommendationOptions[0].instanceType,
          .recommendationOptions[0].estimatedMonthlySavings.value ] | @tsv' \
  | column -t -N NAME,CURRENT,FINDING,CPU_MAX,RECOMMENDED,SAVINGS_USD
NAME              CURRENT       FINDING          CPU_MAX  RECOMMENDED   SAVINGS_USD
api-prod-07       m6i.4xlarge   Overprovisioned  11       m6i.xlarge    418.32
api-prod-08       m6i.4xlarge   Overprovisioned  9        m6i.xlarge    418.32
worker-batch-02   r6i.8xlarge   Overprovisioned  17       r6i.2xlarge   1102.94
etl-staging-01    c6i.2xlarge   Overprovisioned  4        c6i.large     186.15
```

Eso es **$2.125/mes** recuperados antes de comprar un solo compromiso — y es un descuento mayor que la diferencia entre dos opciones de compra cualesquiera del §4.2.

### 4.7 Comprar un Savings Plan

```console
$ OFFERING_ID=$(aws savingsplans describe-savings-plans-offerings \
    --plan-types Compute \
    --durations 31536000 \
    --payment-options "No Upfront" \
    --currencies USD \
    --query 'searchResults[0].offeringId' --output text)

$ echo "$OFFERING_ID"
b1a2c3d4-5e6f-7890-abcd-ef1234567890

$ aws savingsplans create-savings-plan \
    --savings-plan-offering-id "$OFFERING_ID" \
    --commitment "20.00" \
    --client-token "sp-2026-09-04-platform-core-01" \
    --tags Key=cost-center,Value=platform-core Key=purchased-by,Value=platform-team
{
    "savingsPlanId": "sp-0f1e2d3c4b5a69788"
}
```

> **Esto es irreversible.** `--commitment "20.00"` te obliga a **$20/hora × 8.760 horas = $175.200** durante el término. No hay cancelación, no hay reembolso y no hay marketplace de Savings Plans. El `--client-token` es tu guarda de idempotencia — reutilizá el mismo token si la llamada da timeout, para que un reintento no compre un segundo plan.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El modelo de salud de cuatro métricas

La salud de un compromiso son **dos métricas independientes**, y confundirlas es el error de análisis de FinOps más común:

| Métrica | Pregunta que responde | Arreglo cuando está baja |
|---|---|---|
| **Utilización** | Del compromiso que compré, ¿cuánto consumí realmente? | Te **sobre-comprometiste**, o la carga de trabajo se movió. |
| **Cobertura** | De mi uso elegible, ¿cuánto quedó cubierto por un compromiso? | Te **sub-comprometiste**. Comprá más. |

Los cuatro cuadrantes:

| | Cobertura alta | Cobertura baja |
|---|---|---|
| **Utilización alta** | ✅ Sano y optimizado | ⚠️ Sub-comprometido — plata sobre la mesa, pero sin desperdicio |
| **Utilización baja** | ⚠️ Raro; suele ser un desajuste (§5.3) | 🔴 Ambos mal — normalmente un compromiso varado después de una migración |

### 5.2 Diagnosticar baja utilización de Savings Plan

```console
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --output json | jq '.Total'
{
  "Utilization": {
    "TotalCommitment": "13392.00",
    "UsedCommitment": "10981.44",
    "UnusedCommitment": "2410.56",
    "UtilizationPercentage": "82.00"
  },
  "Savings": {
    "NetSavings": "2274.14",
    "OnDemandCostEquivalent": "15666.14"
  },
  "AmortizedCommitment": {
    "AmortizedRecurringCommitment": "13392.00",
    "AmortizedUpfrontCommitment": "0",
    "TotalAmortizedCommitment": "13392.00"
  }
}
```

**$2.410,56 de desperdicio puro en un mes.** Ahora encontrá en qué horas:

```console
$ aws ce get-savings-plans-utilization \
    --time-period Start=2026-08-24,End=2026-08-31 \
    --granularity DAILY --output json \
  | jq -r '.SavingsPlansUtilizationsByTime[]
      | [ .TimePeriod.Start,
          .Utilization.UtilizationPercentage,
          .Utilization.UnusedCommitment ] | @tsv' \
  | column -t -N DATE,UTIL_PCT,UNUSED_USD
DATE        UTIL_PCT  UNUSED_USD
2026-08-24  99.10     4.32
2026-08-25  98.70     6.24
2026-08-26  99.40     2.88
2026-08-27  61.20     186.05
2026-08-28  58.90     197.09
2026-08-29  41.30     281.57
2026-08-30  39.80     288.77
2026-08-31  40.10     287.33
```

El precipicio es el **2026-08-27**. Correlacionalo contra lo que cambió:

```console
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-24,End=2026-09-01 \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=PURCHASE_TYPE \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
    --output json \
  | jq -r '.ResultsByTime[]
      | .TimePeriod.Start as $d
      | .Groups[] | [$d, .Keys[0], .Metrics.UnblendedCost.Amount] | @tsv' \
  | column -t -N DATE,PURCHASE_TYPE,USD
DATE        PURCHASE_TYPE           USD
2026-08-26  On Demand Instances     121.44
2026-08-26  Savings Plan Covered    438.10
2026-08-26  Spot Instances           31.02
2026-08-30  On Demand Instances      18.90
2026-08-30  Savings Plan Covered    173.31
2026-08-30  Spot Instances          277.60
```

**Causa raíz encontrada:** el 2026-08-27 alguien subió el porcentaje de Spot en el ASG. El uso de Spot **no es elegible para cobertura de Savings Plan**, así que la carga de trabajo migró afuera del compromiso. El gasto total bajó, pero ahora $288/día de compromiso se evaporan sin usar.

**Catálogo completo de causas de baja utilización de SP:**

| Causa | Señal | Remediación |
|---|---|---|
| Corrimiento de On-Demand → Spot | El desglose de `PURCHASE_TYPE` se da vuelta (arriba) | Reducí la proporción de Spot de vuelta hacia el piso del compromiso, o dejá que el plan se agote |
| Migración a Graviton / rightsizing | Caen las unidades normalizadas totales; cambian las familias de instancias | Esperable. Modelá la reducción *antes* de la migración, no después |
| La carga de trabajo se movió a otra Región | La dimensión de Región cambia | Solo es fatal para un **EC2 Instance SP** — un Compute SP la sigue |
| Se compró una RI para la misma flota | La utilización de RI sube mientras la de SP baja | §2.6 — las RIs se aplican primero. Dejá de apilar |
| Compartición de consolidated billing deshabilitada | Utilización baja en el payer, cobertura baja en los miembros | Habilitá el compartir RI/SP en la cuenta de gestión |
| Sobrecompra genuina | La utilización nunca fue 100%, ni siquiera el día uno | Nada que hacer. Dejá que el término venza; no lo repitas |

### 5.3 Diagnosticar una RI al 0% de utilización

```console
$ aws ce get-reservation-utilization \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY \
    --group-by Type=DIMENSION,Key=SUBSCRIPTION_ID \
    --output json \
  | jq -r '.UtilizationsByTime[].Groups[]
      | [ .Attributes.subscriptionId,
          .Attributes.instanceType,
          .Attributes.availabilityZone // "regional",
          .Attributes.platform,
          .Utilization.UtilizationPercentage,
          .Utilization.UnusedHours ] | @tsv' \
  | column -t -N SUB_ID,TYPE,AZ,PLATFORM,UTIL_PCT,UNUSED_HRS
SUB_ID     TYPE          AZ           PLATFORM                  UTIL_PCT  UNUSED_HRS
884471023  m6i.xlarge    regional     Linux/UNIX                100.00    0.0
884471088  r6i.2xlarge   us-east-1b   Linux/UNIX                 0.00     1488.0
884471142  m5.large      regional     Red Hat Enterprise Linux   0.00     2976.0
```

Una RI en exactamente **0.00%** nunca es un problema de capacidad — siempre es un **desajuste de atributos**. Recorré esta checklist en orden; el primer desajuste que encuentres es la respuesta:

| # | Atributo | Cómo verificarlo | Nota |
|---|---|---|---|
| 1 | **Availability Zone** | La AZ de la RI zonal vs dónde corren realmente las instancias | La causa #1. Las RIs zonales **no** tienen flexibilidad de AZ |
| 2 | **Plataforma / SO** | `Linux/UNIX` vs `Red Hat Enterprise Linux` vs `Windows` vs `SUSE` | Una RI de Linux nunca cubre RHEL, y viceversa |
| 3 | **Familia de instancias** | `m6i` vs `c6i` | Las Standard RIs no pueden cambiar de familia. Las Convertible se pueden *intercambiar*, no aplicar automáticamente |
| 4 | **Generación** | `m5` vs `m6i` | La flexibilidad de tamaño **no** cruza generaciones |
| 5 | **Tenancy** | `default` vs `dedicated` vs `host` | Debe coincidir exactamente |
| 6 | **Scope** | Las RIs zonales no tienen ninguna flexibilidad de tamaño | Convertilas a Regional si no necesitás la garantía de capacidad |
| 7 | **Compartición de cuentas** | ¿Está habilitado el compartir RI en la Organization? | Desactivado por default en algunas configuraciones |

Confirmá la hipótesis de la AZ directamente:

```console
$ aws ec2 describe-instances \
    --filters Name=instance-type,Values=r6i.2xlarge \
              Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,Platform]' \
    --output text
i-0a1b2c3d4e5f60718   us-east-1c   None
i-0a1b2c3d4e5f60719   us-east-1c   None
```

La RI está acotada a `us-east-1b`; las instancias corren en `us-east-1c`. **Arreglo:** modificá el scope de la RI a Regional (gratis, y gana flexibilidad de tamaño + AZ, al costo de la reserva de capacidad):

```console
$ aws ec2 modify-reserved-instances \
    --reserved-instances-ids bbbbbbbb-5555-6666-7777-888888888888 \
    --target-configurations Scope=Region,InstanceCount=2,InstanceType=r6i.2xlarge
{
    "ReservedInstancesModificationId": "rimod-0123456789abcdef0"
}

$ aws ec2 describe-reserved-instances-modifications \
    --reserved-instances-modification-ids rimod-0123456789abcdef0 \
    --query 'ReservedInstancesModifications[0].Status' --output text
processing
```

### 5.4 Blended vs Unblended vs Amortized — leer el libro mayor correctamente

Todo análisis del CUR depende de elegir la columna de costo correcta. Elegí mal y tu conclusión es incorrecta.

| Columna | Definición | Usala para |
|---|---|---|
| **Unblended cost** | Lo que se cobró, a esa cuenta, en el momento en que ocurrió. Los pagos upfront aterrizan como un pico en el mes de compra. | Conciliar contra la factura |
| **Blended cost** | Uso costeado a la tarifa *promedio* de toda la Organization para ese tipo de uso. | Casi nada. Es un artefacto a nivel Organization y miente sobre la economía de una cuenta individual |
| **Amortized cost** | Los cargos upfront de RI/SP repartidos parejo entre todas las horas del término. | **Showback/chargeback, unit economics, análisis de tendencia** — este es el default que debería usar un arquitecto |
| **Net amortized cost** | Amortizado, menos descuentos de tarifas privadas/EDP. | Acuerdos empresariales |
| **`SavingsPlanEffectiveCost` / `ReservationEffectiveCost`** | El costo por línea de ítem después del descuento del compromiso. | Costo unitario por recurso de una instancia cubierta |

Consulta de cobertura contra el CUR en Athena:

```sql
-- Purchase-option mix and effective hourly rate, by instance family.
-- Amortized effective cost, so a purchase month does not distort the result.
SELECT
    product_instance_type_family                      AS family,
    line_item_usage_account_id                        AS account,
    SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
             THEN line_item_usage_amount ELSE 0 END)  AS sp_hours,
    SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage'
             THEN line_item_usage_amount ELSE 0 END)  AS ri_hours,
    SUM(CASE WHEN line_item_line_item_type = 'Usage'
              AND line_item_usage_type LIKE '%SpotUsage%'
             THEN line_item_usage_amount ELSE 0 END)  AS spot_hours,
    SUM(CASE WHEN line_item_line_item_type = 'Usage'
              AND line_item_usage_type NOT LIKE '%SpotUsage%'
             THEN line_item_usage_amount ELSE 0 END)  AS ondemand_hours,
    ROUND(
        SUM(COALESCE(savings_plan_savings_plan_effective_cost, 0)
          + COALESCE(reservation_effective_cost, 0)
          + CASE WHEN line_item_line_item_type = 'Usage'
                 THEN line_item_unblended_cost ELSE 0 END)
      / NULLIF(SUM(line_item_usage_amount), 0), 5)    AS effective_hourly_usd
FROM   cur.platform_cur_hourly
WHERE  line_item_product_code   = 'AmazonEC2'
  AND  line_item_usage_start_date >= TIMESTAMP '2026-08-01 00:00:00'
  AND  line_item_usage_start_date <  TIMESTAMP '2026-09-01 00:00:00'
  AND  product_instance_type_family IS NOT NULL
GROUP  BY 1, 2
ORDER  BY effective_hourly_usd DESC;
```

```
 family | account      | sp_hours | ri_hours | spot_hours | ondemand_hours | effective_hourly_usd
--------+--------------+----------+----------+------------+----------------+----------------------
 r6i    | 111122223333 |   1204.0 |      0.0 |        0.0 |         2882.0 |              0.42117
 m6i    | 111122223333 |  38410.0 |   5952.0 |    11208.0 |          944.0 |              0.05918
 c6i    | 444455556666 |   9120.0 |      0.0 |    24660.0 |           88.0 |              0.03104
```

La fila 1 es el hallazgo: `r6i` está **70% On-Demand**. La fila 3 es el modelo funcionando — `c6i` se ubica en una tarifa horaria efectiva de **$0,031** porque la mayor parte corre en Spot.

### 5.5 Los costos que ninguna opción de compra puede arreglar

Los Savings Plans y las RIs cubren **cómputo**. No cubren EBS, S3, transferencia de datos, NAT Gateways, balanceadores de carga ni software de Marketplace. Estos son problemas de arquitectura.

| Costo | Tarifa típica | Por qué sorprende a la gente | Arreglo |
|---|---|---|---|
| **NAT Gateway** | ~$0.045/hr **+ ~$0.045/GB procesado** | El cargo de procesamiento por GB aplica **incluso al tráfico hacia S3 en la misma Región** | **Los gateway VPC endpoints para S3 y DynamoDB son gratis.** Agregalos. Después, interface endpoints para los servicios habladores |
| **Tráfico cross-AZ** | ~$0.01/GB **de salida + $0.01/GB de entrada** = **$0.02/GB ida y vuelta** | Una service mesh sin conciencia de topología rocía cada request entre 3 AZs | Enrutamiento consciente de la topología; réplicas de lectura locales a la AZ |
| **Transferencia de datos de salida a internet** | Los primeros 100 GB/mes gratis, después ~$0.09/GB escalonando hacia abajo | Los productos con mucho egreso descubren esto a escala, no en el lanzamiento | CloudFront (menor tarifa por GB, y **los fetch al origen desde orígenes AWS son gratis**) |
| **Volúmenes EBS sin adjuntar** | gp3 ~$0.08/GB-mes | Sobreviven a la terminación de la instancia cuando `DeleteOnTermination: false` | Política de ciclo de vida + una regla de Trusted Advisor / Config |
| **Elastic IPs sin asociar** | Cargo por hora cuando no están adjuntas a una instancia en ejecución | La trampa clásica del "paré la instancia para ahorrar plata" | Liberalas |
| **Balanceadores de carga ociosos** | Cargo por hora + LCU | Quedan atrás de stacks eliminados | Recolección dirigida por tags |
| **Monitoreo de S3 Intelligent-Tiering** | ~$0.0025 por cada 1.000 objetos/mes | Con 500M de objetos chicos eso son **$1.250/mes solo en monitoreo**, posiblemente superando el ahorro de almacenamiento | No uses Intelligent-Tiering para grandes cantidades de objetos chicos |
| **Borrado temprano / duración mínima en S3** | Standard-IA y One Zone-IA: 30 días. Glacier IR y Flexible: 90. Deep Archive: 180 | Borrar un objeto de Deep Archive el día 10 igual factura 180 días | Modelá la vida útil del objeto *antes* de escribir la regla de ciclo de vida |
| **Requests de transición de ciclo de vida en S3** | Cargo por cada 1.000 objetos en cada transición | Transicionar 100M de objetos chicos puede costar más que el almacenamiento ahorrado | Transicioná por umbral de tamaño, no ciegamente por edad |

Auditá las tres victorias más baratas en una sola pasada:

```console
$ aws ec2 describe-volumes --filters Name=status,Values=available \
    --query 'sort_by(Volumes,&Size)[].[VolumeId,Size,VolumeType,CreateTime]' \
    --output table
--------------------------------------------------------------------
|                          DescribeVolumes                         |
+------------------------+------+-------+---------------------------+
|  vol-0aa11bb22cc33dd44 |  100 |  gp3  |  2025-11-02T09:14:11+00:00 |
|  vol-0ee55ff66aa77bb88 |  500 |  gp2  |  2026-01-19T22:03:47+00:00 |
|  vol-0cc99dd88ee77ff66 | 2000 |  io1  |  2024-07-30T13:55:02+00:00 |
+------------------------+------+-------+---------------------------+

$ aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
    --output text
52.204.11.87    eipalloc-0123456789abcdef0
34.229.44.190   eipalloc-0abcdef1234567890

$ aws ec2 describe-vpc-endpoints \
    --filters Name=vpc-id,Values=vpc-0abc123def456789a \
    --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output text
com.amazonaws.us-east-1.ssm        Interface   available
com.amazonaws.us-east-1.ec2messages Interface  available
# No com.amazonaws.us-east-1.s3 gateway endpoint => every byte to S3 is
# paying NAT Gateway data-processing charges for nothing.
```

---

## 6. Modelos de precios de almacenamiento, serverless y bases de datos

### 6.1 Clases de almacenamiento de S3 — cuatro dimensiones de facturación, no una

| Clase | Almacenamiento $/GB-mes | Duración mínima | Tamaño mínimo facturable | Cargo de recuperación | Tiempo de recuperación | Punto de diseño |
|---|---|---|---|---|---|---|
| **S3 Standard** | ~0.023 | ninguna | ninguno | ninguno | ms | Acceso activo, impredecible |
| **S3 Intelligent-Tiering** | Tarifa Standard bajando hasta tarifas de archivo, **+ ~$0.0025 por 1.000 objetos/mes de monitoreo** | ninguna | 128 KB para auto-tiering | **ninguno** | ms (los niveles de archivo, más lentos) | Patrones de acceso desconocidos o cambiantes |
| **S3 Standard-IA** | ~0.0125 | **30 días** | **128 KB** | por GB | ms | Poco frecuente conocido, necesita acceso instantáneo |
| **S3 One Zone-IA** | ~0.010 | **30 días** | **128 KB** | por GB | ms | Datos recreables; **una sola AZ — postura de durabilidad menor** |
| **S3 Glacier Instant Retrieval** | ~0.004 | **90 días** | **128 KB** | por GB (más alto) | ms | Archivos que igual deben ser instantáneos |
| **S3 Glacier Flexible Retrieval** | ~0.0036 | **90 días** | 40 KB | por GB, según nivel de velocidad | minutos–12 h | Backups, cumplimiento |
| **S3 Glacier Deep Archive** | ~0.00099 | **180 días** | 40 KB | por GB (el más bajo) | **12–48 h** | Retención regulatoria que esperás no tener que leer nunca |

**La trampa que tienden tanto el examen como la realidad:** Standard-IA es 46% más barato por GB-mes que Standard, pero agrega un cargo de **recuperación** por GB. El break-even es aproximadamente *"leer menos de una o dos veces al mes"*. Datos leídos semanalmente cuestan **más** en Standard-IA que en Standard.

### 6.2 Tipos de volumen EBS

| Tipo | $/GB-mes | Modelo de rendimiento | Nota |
|---|---|---|---|
| **gp3** | ~0.080 | **3.000 IOPS + 125 MB/s incluidos**, aprovisionados independientemente del tamaño | ~20% más barato que gp2 y más rápido en tamaños chicos. **gp2 → gp3 es una ganancia gratis, en línea y casi universal** |
| **gp2** | ~0.100 | 3 IOPS/GB, con burst | Legado. Migrá |
| **io2 Block Express** | ~0.125 + por IOPS | IOPS aprovisionados, la mayor durabilidad | Solo cuando genuinamente necesitás >16k IOPS o durabilidad de 99,999% |
| **st1** | ~0.045 | HDD optimizado para throughput | Escaneos secuenciales grandes, logs |
| **sc1** | ~0.015 | HDD frío | Secuencial de acceso raro |
| **Snapshots** | ~0.05 (estándar) / ~0.0125 (nivel de archivo) | Incrementales | El nivel de archivo tiene un **mínimo de 90 días** y un cargo de restauración |

### 6.3 Modelos serverless y de consumo

| Servicio | Dimensiones de facturación | Cobertura por compromiso |
|---|---|---|
| **AWS Lambda** | Requests + **duración × memoria (GB-segundos)**, facturado por milisegundo. La asignación de memoria también escala la CPU — una función más grande puede ser *más barata* si termina proporcionalmente más rápido. **arm64/Graviton es ~20% más barato por GB-segundo que x86.** | **Los Compute Savings Plans cubren la duración y la Provisioned Concurrency**; los cargos por request no están cubiertos |
| **AWS Fargate** | vCPU-horas + GB-horas de memoria, por segundo con un mínimo de 1 minuto. **Fargate Spot** ofrece un descuento profundo con aviso de interrupción de 2 minutos | El Compute SP cubre Fargate **on-demand**; **no** cubre Fargate Spot |
| **Amazon DynamoDB** | **On-demand:** por unidad de request de lectura/escritura, cero planificación de capacidad. **Provisioned:** por RCU/WCU-hora, con auto-scaling, y con **reserved capacity** disponible para un descuento adicional | La reserved capacity es específica de DynamoDB; los Savings Plans no aplican |
| **Amazon S3** | Almacenamiento + requests + recuperación + transferencia | No aplica |

**DynamoDB es la ilustración más clara de todo el dominio:** el modo on-demand es el modelo pay-as-you-go (con picos, impredecible, sin planificación); provisioned + reserved capacity es el modelo save-when-you-commit (estable, predecible). Misma tabla, mismos datos, misma elección que EC2 On-Demand vs Savings Plans.

### 6.4 El AWS Free Tier

Clásicamente, tres categorías — conocelas para el examen:

| Tipo | Significado | Ejemplos |
|---|---|---|
| **12-month free** | Gratis por 12 meses desde la creación de la cuenta | 750 horas/mes de una `t2.micro`/`t3.micro`, 30 GB de EBS, 5 GB de S3 Standard |
| **Always free** | Sin vencimiento, dentro de los límites mensuales | Lambda 1M de requests + 400.000 GB-segundos/mes, DynamoDB 25 GB, 25 GB de asignaciones tipo CloudWatch/SNS |
| **Trials** | Gratis por un período corto después de activar un servicio específico | Ventanas cortas de evaluación en servicios individuales |

> **Nota de actualidad:** AWS reestructuró en 2025 el onboarding de free tier para cuentas nuevas hacia un modelo basado en créditos. Las tres categorías de arriba son contra las que están escritas las preguntas del examen CLF-C02; para cuentas reales, confirmá los términos vigentes en la página del free tier antes de presupuestar.

### 6.5 Planes de soporte — un modelo de precios expresado como porcentaje del gasto

La tarea 4.3 se ocupa del soporte en profundidad, pero la *estructura de precios* pertenece acá porque es el único lugar donde tu factura escala con tu factura:

| Plan | Modelo de costo |
|---|---|
| **Basic** | Gratis |
| **Developer** | El mayor entre un mínimo mensual chico (~$29) **o ~3% del uso mensual de AWS** |
| **Business** | El mayor entre ~$100/mes **o un porcentaje escalonado del uso** (~10% / 7% / 5% / 3% por banda de gasto) |
| **Enterprise On-Ramp** | El mayor entre ~$5.500/mes **o un porcentaje escalonado** |
| **Enterprise** | El mayor entre ~$15.000/mes **o un porcentaje escalonado** |

Cada dólar que quitás con rightsizing y compromisos también reduce la tarifa de soporte — el ahorro se compone.

---

## 7. Juntando todo: el procedimiento de decisión

```
For each workload:

  1. RIGHTSIZE FIRST.
     Compute Optimizer / CloudWatch. Never commit to waste.

  2. Can it survive a 2-minute termination notice?
       YES → Spot (diversified pools, price-capacity-optimized,
                   capacity rebalancing). Up to ~90% off, zero commitment.
       NO  → continue.

  3. What is its monthly uptime?
       < (1 - available discount)  → On-Demand + a scheduler. Do not commit.
       ≥ (1 - available discount)  → continue.

  4. Does it need a guaranteed slot in a specific AZ?
       YES → zonal Reserved Instance, or ODCR + a Savings Plan.
       NO  → continue.

  5. Is the fleet architecture frozen for the term?
       YES, and it's one family in one Region → EC2 Instance Savings Plan.
       NO, it will evolve                     → Compute Savings Plan.
                                                (the correct default)

  6. Is there a socket-/core-bound BYOL licence, or a physical-host
     compliance requirement?
       YES → Dedicated Host (+ Dedicated Host Reservation).
       Hardware isolation only, no licence → Dedicated Instance.

  7. Commit to ~70-80% of the Cost Explorer recommendation, never 100%.
     You can always buy more. You can never cancel.

  8. Instrument: SP/RI utilization budgets, coverage dashboards,
     anomaly detection, hourly CUR with RESOURCES.
```

### 7.1 Trampas del examen, condensadas

| Afirmación | Verdad |
|---|---|
| "Las Reserved Instances garantizan capacidad." | **Solo las RIs zonales.** Las RIs regionales dan un descuento y flexibilidad de AZ, no capacidad. |
| "Los Savings Plans reservan capacidad." | **Nunca.** Usá una RI zonal o un ODCR. |
| "Podés cancelar un Savings Plan." | No. Las Standard RIs se pueden **vender en el RI Marketplace**; los Savings Plans y las Convertible RIs no se pueden vender. |
| "Spot es simplemente un On-Demand más barato." | Spot es **reclamable con 2 minutos de aviso**. Es un contrato de disponibilidad distinto. |
| "Las Convertible RIs dan el mayor descuento." | Las **Standard** RIs descuentan más; las Convertible cambian ~6 puntos por la capacidad de intercambio. |
| "Los Savings Plans cubren todo el cómputo." | No Spot, no Dedicated Hosts, no los cargos por *request* de Lambda, no el software de Marketplace. |
| "Las Dedicated Instances me permiten usar mi licencia basada en sockets." | Necesitás un **Dedicated Host** para visibilidad de socket/core y BYOL. |
| "La transferencia de datos hacia AWS cuesta plata." | La entrada desde internet es en general **gratis**. La salida, el cross-AZ y el cross-Región no lo son. |
| "No Upfront significa que no hay obligación." | Significa que no hay pago único. Se te factura por hora durante **todo el término** sin importar el uso. |
| "Glacier Deep Archive siempre es lo más barato." | No para datos que podrías borrar temprano — **180 días de duración mínima de facturación**, más 12–48 h de recuperación. |
| "Parar una instancia EC2 detiene todos sus cargos." | Los **volúmenes EBS y cualquier Elastic IP siguen facturando**. |

---

## Referencias

**Examen y certificación**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Fundamentos de precios**
- How AWS Pricing Works (whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/how-aws-pricing-works/welcome.html
- AWS Pricing — https://aws.amazon.com/pricing/
- AWS Pricing Calculator — https://calculator.aws/
- AWS Free Tier — https://aws.amazon.com/free/
- AWS Price List API — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html

**Opciones de compra de EC2**
- Instance purchasing options — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html
- Amazon EC2 pricing — https://aws.amazon.com/ec2/pricing/
- Reserved Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
- Reserved Instance size flexibility — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/apply_ri.html
- Selling on the Reserved Instance Marketplace — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ri-market-general.html
- Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruptions — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html
- Spot placement score — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html
- Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Dedicated Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-instance.html
- On-Demand Capacity Reservations — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html

**Savings Plans**
- Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- Savings Plans pricing — https://aws.amazon.com/savingsplans/pricing/
- How Savings Plans apply to usage — https://docs.aws.amazon.com/savingsplans/latest/userguide/sp-applying.html
- Savings Plans compared with Reserved Instances — https://docs.aws.amazon.com/savingsplans/latest/userguide/sp-overview.html

**Almacenamiento y transferencia de datos**
- Amazon S3 pricing — https://aws.amazon.com/s3/pricing/
- Using Amazon S3 storage classes — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
- Amazon EBS pricing — https://aws.amazon.com/ebs/pricing/
- Overview of data transfer costs for common architectures — https://aws.amazon.com/blogs/architecture/overview-of-data-transfer-costs-for-common-architectures/
- VPC endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html
- NAT gateway pricing — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html#nat-gateway-pricing

**Serverless y bases de datos**
- AWS Lambda pricing — https://aws.amazon.com/lambda/pricing/
- AWS Fargate pricing — https://aws.amazon.com/fargate/pricing/
- Amazon DynamoDB read/write capacity modes — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadWriteCapacityMode.html

**Herramientas de gestión de costos**
- AWS Cost Explorer — https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
- AWS Budgets — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- AWS Cost and Usage Reports — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- CUR data dictionary — https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html
- AWS Cost Anomaly Detection — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Support Plans pricing — https://aws.amazon.com/premiumsupport/pricing/

**Infraestructura como código**
- `AWS::AutoScaling::AutoScalingGroup` MixedInstancesPolicy — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-autoscaling-autoscalinggroup-mixedinstancespolicy.html
- Attribute-based instance type selection — https://docs.aws.amazon.com/autoscaling/ec2/userguide/create-mixed-instances-group-attribute-based-instance-type-selection.html
- Capacity Rebalancing in Auto Scaling — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html
- Karpenter NodePool API — https://karpenter.sh/docs/concepts/nodepools/
- Karpenter EC2NodeClass API — https://karpenter.sh/docs/concepts/nodeclasses/