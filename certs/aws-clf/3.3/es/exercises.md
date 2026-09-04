# Tema 3.3 — Identificar los servicios de cómputo de AWS
## Ejercicios guiados · AWS Certified Cloud Practitioner (CLF-C02, v1.0)

**Dominio 3 — Tecnología y servicios en la nube · Enunciado de tarea 3.3 · Peso en el examen: 4.25%**

> Referencia de la guía del examen: <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>

El examen te pide *identificar* servicios de cómputo — pero identificar sin entender la mecánica es memorización que se evapora ante una pregunta reformulada. Estos ejercicios te hacen tocar el plano de control, leer las respuestas reales de la API y observar *por qué* cada servicio existe como producto distinto. Cada bloque termina con preguntas de control; la clave de respuestas está plegada al final.

---

## Antes de empezar

### Requisitos previos

| Requisito | Verificación |
|---|---|
| Cuenta de AWS con acceso por consola + programático | `aws sts get-caller-identity` |
| AWS CLI v2 (la v1 no tiene varios flags que se usan acá) | `aws --version` → `aws-cli/2.x.x` |
| `jq` (opcional, para legibilidad) | `jq --version` |
| Una región fijada para toda la sesión | `export AWS_REGION=us-east-1` |

### Barreras de costo — leé esto antes de ejecutar nada

La mayoría de los ejercicios de acá son **solo de lectura** (APIs describe, costo cero). Los bloques que crean recursos facturables están marcados con **💸 CREA RECURSOS FACTURABLES** y siempre terminan con un paso de desmontaje.

Las condiciones del Free Tier de AWS cambiaron con el tiempo (el tier heredado de 12 meses frente al plan basado en créditos para cuentas nuevas). **No supongas que algo es gratis** — verificá el tier actual de tu cuenta en <https://aws.amazon.com/free/> y en Billing → Free Tier.

Configurá primero una alarma de presupuesto:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "clf-33-compute-lab",
  "BudgetLimit": { "Amount": "5", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json
```

Etiquetá todo lo que crees con `Project=clf-33-lab` para que los greps del desmontaje sean confiables.

---

## Ejercicio 1 — Mapear el espacio de nombres de los tipos de instancia EC2

Amazon EC2 es la primitiva IaaS: alquilás una máquina virtual y sos dueño de todo lo que está por encima del hipervisor. El examen no te pide dimensionar instancias, pero *sí* te pide hacer coincidir la descripción de una carga de trabajo ("base de datos en memoria intensiva en memoria") con una familia. Ese mapeo es legible por máquina — nunca tenés que adivinar.

### Pasos

1. **Decodificá la convención de nombres sobre un tipo real.** Consultá la API por una instancia Graviton moderna:

   ```bash
   aws ec2 describe-instance-types \
     --instance-types m7gd.2xlarge \
     --query 'InstanceTypes[0].{
        Type:InstanceType,
        vCPU:VCpuInfo.DefaultVCpus,
        Cores:VCpuInfo.DefaultCores,
        ThreadsPerCore:VCpuInfo.DefaultThreadsPerCore,
        MemoryMiB:MemoryInfo.SizeInMiB,
        Arch:ProcessorInfo.SupportedArchitectures,
        Hypervisor:Hypervisor,
        InstanceStorage:InstanceStorageInfo.TotalSizeInGB,
        Network:NetworkInfo.NetworkPerformance}' \
     --output table
   ```

   Salida esperada (los valores son estables para este tipo):

   ```
   -------------------------------------------------
   |             DescribeInstanceTypes             |
   +------------------+----------------------------+
   |  Arch            |  arm64                     |
   |  Cores           |  8                         |
   |  Hypervisor      |  nitro                     |
   |  InstanceStorage |  475                       |
   |  MemoryMiB       |  32768                     |
   |  Network         |  Up to 15 Gigabit          |
   |  ThreadsPerCore  |  1                         |
   |  Type            |  m7gd.2xlarge              |
   |  vCPU            |  8                         |
   +------------------+----------------------------+
   ```

   Leé el nombre de izquierda a derecha: **`m`** = familia de propósito general · **`7`** = 7ª generación · **`g`** = procesador AWS Graviton · **`d`** = almacenamiento local NVMe (instance store) · **`2xlarge`** = tamaño. Referencia: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>

2. **Compará los cuatro arquetipos de carga de trabajo lado a lado.** Un representante por categoría de familia:

   ```bash
   aws ec2 describe-instance-types \
     --instance-types m7i.xlarge c7i.xlarge r7i.xlarge i4i.xlarge \
     --query 'sort_by(InstanceTypes, &InstanceType)[].{
        Type:InstanceType,
        vCPU:VCpuInfo.DefaultVCpus,
        MemGiB:MemoryInfo.SizeInMiB,
        LocalNVMeGB:InstanceStorageInfo.TotalSizeInGB}' \
     --output table
   ```

   ```
   ----------------------------------------------------------
   |                  DescribeInstanceTypes                 |
   +---------------+--------+-------------+-----------------+
   |     Type      | vCPU   |   MemGiB    |  LocalNVMeGB    |
   +---------------+--------+-------------+-----------------+
   |  c7i.xlarge   |  4     |  8192       |  None           |
   |  i4i.xlarge   |  4     |  32768      |  937            |
   |  m7i.xlarge   |  4     |  16384      |  None           |
   |  r7i.xlarge   |  4     |  32768      |  None           |
   +---------------+--------+-------------+-----------------+
   ```

   La misma cantidad de vCPU, cuatro relaciones memoria-a-vCPU distintas (2:1, 4:1, 8:1) y una con NVMe local. **La letra de la familia es una relación, no un grado de velocidad.**

3. **Filtrá por capacidad en vez de por nombre.** Así es como responderías realmente "¿qué tipos son ARM y burstable?":

   ```bash
   aws ec2 describe-instance-types \
     --filters Name=processor-info.supported-architecture,Values=arm64 \
               Name=burstable-performance-supported,Values=true \
     --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | sort
   ```

   ```
   t4g.2xlarge
   t4g.large
   t4g.medium
   t4g.micro
   t4g.nano
   t4g.small
   t4g.xlarge
   ```

4. **Confirmá que los tipos de instancia no están disponibles de manera uniforme.** La disponibilidad regional y por AZ difiere — esto es una restricción real de producción:

   ```bash
   aws ec2 describe-instance-type-offerings \
     --location-type availability-zone \
     --filters Name=instance-type,Values=c7g.large \
     --query 'InstanceTypeOfferings[].Location' --output text
   ```

   ```
   us-east-1a	us-east-1b	us-east-1c	us-east-1d	us-east-1f
   ```

   Fijate en la ausencia de `us-east-1e` — un hueco real en esa Región para varias familias modernas.

5. **Encontrá los tipos bare metal** y observá que existen:

   ```bash
   aws ec2 describe-instance-types \
     --filters Name=bare-metal,Values=true \
     --query 'length(InstanceTypes)'
   ```

### Control — Ejercicio 1

- **P1.1** En `c6gn.8xlarge`, ¿qué significa cada uno de `c`, `6`, `g`, `n` y `8xlarge`?
- **P1.2** Una carga de trabajo es una caché analítica en memoria que necesita 200 GiB de RAM pero muy poca CPU. ¿Qué categoría de familia elegís, y por qué una instancia optimizada para cómputo es la respuesta equivocada aunque la hagas suficientemente grande?
- **P1.3** `m7gd.2xlarge` reportó `ThreadsPerCore: 1` mientras que un tipo Intel equivalente reporta `2`. ¿Qué significa entonces "vCPU" en Graviton frente a Intel/AMD?
- **P1.4** Un estudiante afirma que "las instancias bare metal no son realmente EC2, son otro servicio". Corregilo.
- **P1.5** ¿Por qué la presencia de `d` en el nombre de la instancia cambia tu planificación de durabilidad?

---

## Ejercicio 2 — Lanzar una instancia e interrogarla desde adentro

**💸 CREA RECURSOS FACTURABLES** (una `t3.micro`, un security group, un par de claves). El desmontaje es el paso 9.

### Pasos

1. **Resolvé la AMI actual de Amazon Linux 2023 desde SSM Parameter Store** — nunca fijes un ID de AMI a mano: son específicos de la Región y rotan:

   ```bash
   AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)
   echo "$AMI_ID"
   ```

   ```
   ami-0abcdef1234567890
   ```

2. **Creá un security group sin reglas de entrada.** No vas a entrar por SSH — vas a usar SSM Session Manager, que no necesita ningún puerto abierto:

   ```bash
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
     --query 'Vpcs[0].VpcId' --output text)

   SG_ID=$(aws ec2 create-security-group \
     --group-name clf33-nosg --description "CLF 3.3 lab, egress only" \
     --vpc-id "$VPC_ID" --query GroupId --output text)
   echo "$SG_ID"
   ```

3. **Creá un instance profile que permita SSM.** (Si ya existe `AmazonSSMRoleForInstancesQuickSetup` o un rol similar, reutilizalo.)

   ```bash
   cat > /tmp/trust.json <<'JSON'
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
   JSON

   aws iam create-role --role-name clf33-ssm-role \
     --assume-role-policy-document file:///tmp/trust.json >/dev/null

   aws iam attach-role-policy --role-name clf33-ssm-role \
     --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

   aws iam create-instance-profile --instance-profile-name clf33-ssm-profile >/dev/null
   aws iam add-role-to-instance-profile \
     --instance-profile-name clf33-ssm-profile --role-name clf33-ssm-role
   ```

4. **Lanzá con user data e IMDSv2 obligatorio.** El user data es el hook de arranque — es lo que hace que una instancia sea reproducible en vez de construida a mano:

   ```bash
   cat > /tmp/userdata.sh <<'EOF'
   #!/bin/bash
   dnf install -y stress-ng >/dev/null 2>&1
   echo "bootstrapped at $(date -Is)" > /var/log/clf33-bootstrap.log
   EOF

   INSTANCE_ID=$(aws ec2 run-instances \
     --image-id "$AMI_ID" \
     --instance-type t3.micro \
     --security-group-ids "$SG_ID" \
     --iam-instance-profile Name=clf33-ssm-profile \
     --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
     --user-data file:///tmp/userdata.sh \
     --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clf33-lab},{Key=Project,Value=clf-33-lab}]' \
     --query 'Instances[0].InstanceId' --output text)

   aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
   echo "$INSTANCE_ID is running"
   ```

5. **Observá las transiciones de estado del ciclo de vida** — `pending` → `running` → (`stopping` → `stopped`) → `shutting-down` → `terminated`:

   ```bash
   aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
     --query 'Reservations[0].Instances[0].{
        State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,
        PrivateIp:PrivateIpAddress,Lifecycle:InstanceLifecycle,
        Hypervisor:Hypervisor,Launch:LaunchTime}' --output table
   ```

   ```
   ------------------------------------------------------
   |                  DescribeInstances                 |
   +-------------+--------------------------------------+
   |  AZ         |  us-east-1b                          |
   |  Hypervisor |  xen                                 |
   |  Launch     |  2026-09-04T13:41:08+00:00           |
   |  Lifecycle  |  None                                |
   |  PrivateIp  |  172.31.24.117                       |
   |  State      |  running                             |
   |  Type       |  t3.micro                            |
   +-------------+--------------------------------------+
   ```

   > `Hypervisor: xen` es una rareza de larga data en el reporte de la API para algunos tipos basados en Nitro; `describe-instance-types` es la fuente autoritativa y reporta `nitro` para `t3`. `Lifecycle: None` significa On-Demand — una instancia Spot reportaría `spot`.

6. **Abrí una shell sin SSH** (esperá ~60 s después de `running` para que el agente SSM se registre):

   ```bash
   aws ssm start-session --target "$INSTANCE_ID"
   ```

7. **Dentro de la instancia, consultá el Instance Metadata Service usando IMDSv2.** Como lanzaste con `HttpTokens=required`, la llamada no autenticada de IMDSv1 tiene que fallar:

   ```bash
   # This MUST fail — IMDSv1 is disabled
   curl -s --max-time 3 -o /dev/null -w '%{http_code}\n' \
     http://169.254.169.254/latest/meta-data/instance-id
   ```

   ```
   401
   ```

   Ahora el flujo IMDSv2 orientado a sesión:

   ```bash
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

   for k in instance-id instance-type placement/availability-zone \
            placement/region ami-id local-ipv4 services/partition; do
     printf '%-34s %s\n' "$k" \
       "$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/$k)"
   done
   ```

   ```
   instance-id                        i-0f3c9b1e2a7d45601
   instance-type                      t3.micro
   placement/availability-zone        us-east-1b
   placement/region                   us-east-1
   ami-id                             ami-0abcdef1234567890
   local-ipv4                         172.31.24.117
   services/partition                 aws
   ```

8. **Comprobá que el modelo de créditos de CPU burstable es real.** `t3` no es "un servidor chico" — es un servidor con un *presupuesto de CPU*:

   ```bash
   grep -c ^processor /proc/cpuinfo      # 2 vCPUs
   cat /var/log/clf33-bootstrap.log      # user data ran
   stress-ng --cpu 2 --timeout 120s --metrics-brief
   exit
   ```

   De vuelta en tu estación de trabajo, leé el saldo de créditos desde CloudWatch:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 --metric-name CPUCreditBalance \
     --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
     --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --period 300 --statistics Average \
     --query 'sort_by(Datapoints,&Timestamp)[].{T:Timestamp,Credits:Average}' \
     --output table
   ```

   Revisá también la especificación de créditos — `T3` usa por defecto el modo **unlimited**, `T2` el modo **standard**:

   ```bash
   aws ec2 describe-instance-credit-specifications --instance-ids "$INSTANCE_ID" \
     --query 'InstanceCreditSpecifications[0]' --output table
   ```

   ```
   ---------------------------------------------
   |  InstanceCreditSpecifications             |
   +----------------+--------------------------+
   |  CpuCredits    |  unlimited               |
   |  InstanceId    |  i-0f3c9b1e2a7d45601     |
   +----------------+--------------------------+
   ```

9. **Desmontaje:**

   ```bash
   aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
   aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
   aws ec2 delete-security-group --group-id "$SG_ID"
   aws iam remove-role-from-instance-profile \
     --instance-profile-name clf33-ssm-profile --role-name clf33-ssm-role
   aws iam delete-instance-profile --instance-profile-name clf33-ssm-profile
   aws iam detach-role-policy --role-name clf33-ssm-role \
     --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
   aws iam delete-role --role-name clf33-ssm-role
   ```

### Control — Ejercicio 2

- **P2.1** Abriste una shell en una instancia cuyo security group tiene **cero** reglas de entrada. Explicá el mecanismo, y qué implica eso para el modelo de responsabilidad compartida.
- **P2.2** La llamada IMDSv1 devolvió `401` y la IMDSv2 tuvo éxito. ¿Contra qué clase de ataque defiende `HttpTokens=required` más `HttpPutResponseHopLimit=1`?
- **P2.3** Una instancia está `stopped` por una semana. ¿Cuáles de estos seguís pagando: vCPU/RAM, el volumen raíz EBS, la dirección IPv4 privada, una Elastic IP asociada?
- **P2.4** ¿Cuál es la diferencia entre una **AMI** y un **snapshot de EBS**, y cuál es la "golden image" en un pipeline de lanzamiento?
- **P2.5** Tu `t3.micro` está en modo `unlimited` y corre al 100% de CPU durante 10 horas. ¿Qué pasa con (a) el rendimiento y (b) la factura? ¿En qué se diferenciaría el modo `standard`?
- **P2.6** El user data corrió una sola vez en el primer arranque. Nombrá dos cosas que tenés que garantizar de un script de user data para que sea seguro en un Auto Scaling group.

---

## Ejercicio 3 — Opciones de compra: la misma instancia, cinco precios

Este es el bloque de mayor rendimiento para el examen. En CLF-C02, las preguntas de "cómputo" son con frecuencia preguntas de *modelo de precios* disfrazadas.

### Pasos

1. **Obtené el precio On-Demand real desde la Pricing API** (la Pricing API solo está expuesta en `us-east-1` y `ap-south-1`):

   ```bash
   aws pricing get-products --region us-east-1 \
     --service-code AmazonEC2 \
     --filters \
       'Type=TERM_MATCH,Field=instanceType,Value=m6i.large' \
       'Type=TERM_MATCH,Field=regionCode,Value=us-east-1' \
       'Type=TERM_MATCH,Field=operatingSystem,Value=Linux' \
       'Type=TERM_MATCH,Field=tenancy,Value=Shared' \
       'Type=TERM_MATCH,Field=preInstalledSw,Value=NA' \
       'Type=TERM_MATCH,Field=capacitystatus,Value=Used' \
     --max-results 1 --output json \
   | jq -r '.PriceList[0]' | jq -r '
       .terms.OnDemand | to_entries[0].value.priceDimensions
       | to_entries[0].value | "\(.pricePerUnit.USD) USD per \(.unit)"'
   ```

   ```
   0.0960000000 USD per Hrs
   ```

2. **Obtené el precio Spot para el mismo tipo en todas las AZ:**

   ```bash
   aws ec2 describe-spot-price-history \
     --instance-types m6i.large \
     --product-descriptions "Linux/UNIX" \
     --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --query 'sort_by(SpotPriceHistory,&AvailabilityZone)[].{AZ:AvailabilityZone,Price:SpotPrice}' \
     --output table
   ```

   ```
   ----------------------------------
   |    DescribeSpotPriceHistory    |
   +----------------+---------------+
   |       AZ       |    Price      |
   +----------------+---------------+
   |  us-east-1a    |  0.032100     |
   |  us-east-1b    |  0.029900     |
   |  us-east-1c    |  0.036500     |
   |  us-east-1d    |  0.030200     |
   +----------------+---------------+
   ```

   Calculá el descuento vos mismo: `0.0299 / 0.0960 ≈ 31%` del On-Demand — un ahorro de ~69% *en este momento, en esta AZ*. Los precios Spot se mueven con la oferta de capacidad sobrante.

3. **Preguntale a AWS dónde la capacidad Spot es realmente profunda.** El Spot placement score es una señal de 1 a 10, no un precio:

   ```bash
   aws ec2 get-spot-placement-scores \
     --instance-types m6i.large m6a.large m5.large \
     --target-capacity 500 \
     --target-capacity-unit-type units \
     --region-names us-east-1 us-west-2 eu-west-1 \
     --query 'SpotPlacementScores[].{Region:Region,Score:Score}' \
     --output table
   ```

   ```
   ------------------------------
   |  GetSpotPlacementScores    |
   +---------------+------------+
   |    Region     |   Score    |
   +---------------+------------+
   |  us-west-2    |  9         |
   |  us-east-1    |  7         |
   |  eu-west-1    |  6         |
   +---------------+------------+
   ```

4. **Inspeccioná el contrato de interrupción.** En una *instancia Spot en ejecución*, el aviso de dos minutos aparece como una ruta de metadatos que devuelve `404` hasta que la interrupción está programada:

   ```bash
   # run this ON a Spot instance
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/spot/instance-action
   ```

   ```
   404      # healthy — no interruption scheduled
   ```

   Cuando AWS reclama la capacidad pasa a `200` con un cuerpo como:

   ```json
   {"action": "terminate", "time": "2026-09-04T14:12:00Z"}
   ```

5. **Enumerá tu cobertura basada en compromisos** (vacía en una cuenta nueva — el punto es ver los dos servicios distintos):

   ```bash
   aws ec2 describe-reserved-instances \
     --query 'ReservedInstances[].{Type:InstanceType,Offering:OfferingClass,Scope:Scope,Count:InstanceCount,End:End}' \
     --output table

   aws savingsplans describe-savings-plans --region us-east-1 \
     --query 'savingsPlans[].{Type:savingsPlanType,Commit:commitment,Term:termDurationInSeconds,State:state}' \
     --output table
   ```

6. **Distinguí los modelos de tenencia:**

   ```bash
   aws ec2 describe-hosts --query 'Hosts[].{Id:HostId,Family:HostProperties.InstanceFamily,
     Sockets:HostProperties.Sockets,Cores:HostProperties.Cores,State:State}' --output table
   ```

   Un **Dedicated Host** expone sockets y núcleos físicos — esa visibilidad es exactamente lo que requiere el licenciamiento de software por socket / por núcleo (BYOL). Una **Dedicated Instance** te da aislamiento de hardware sin esa visibilidad.

7. **Armá vos mismo la tabla comparativa** antes de leer la clave de respuestas. Completá: *techo de descuento · compromiso · flexibilidad · riesgo de interrupción · carga de trabajo típica.*

Referencias:
<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html> ·
<https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html> ·
<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>

### Control — Ejercicio 3

- **P3.1** Un pipeline de transcodificación de video por lotes corre todas las noches, tiene checkpoints y puede reiniciar cualquier trabajo. ¿Qué opción de compra, y cuál es el único requisito arquitectónico que impone a la aplicación?
- **P3.2** Una empresa va a correr *algo* de cómputo estable durante tres años pero espera migrar de `m5` a `m7g` y de EC2 a Fargate a mitad de camino. ¿Standard RI, Convertible RI, EC2 Instance Savings Plan o Compute Savings Plan?
- **P3.3** ¿Qué te dice un Spot **placement score de 9**, y qué es lo que explícitamente *no* te dice?
- **P3.4** Un Savings Plan es un compromiso ¿con qué unidad — horas de instancia, o dólares por hora de uso? ¿Por qué esa distinción cambia la historia de la flexibilidad?
- **P3.5** Tu licencia de Oracle está atada a los sockets físicos de CPU. ¿Dedicated Instance o Dedicated Host? Justificá con lo que mostró el paso 6.
- **P3.6** Una On-Demand Capacity Reservation y una Reserved Instance se confunden con frecuencia. ¿Cuál garantiza *capacidad* y cuál garantiza *un precio*?

---

## Ejercicio 4 — Elasticidad: Auto Scaling y Elastic Load Balancing

**💸 CREA RECURSOS FACTURABLES** (un ALB, más 2 instancias). Un ALB tiene un cargo por hora sin free tier para la mayoría de las cuentas. El desmontaje es el paso 8; el tiempo total de ejecución debería quedar bastante por debajo de una hora.

Auto Scaling y ELB son dos mitades de una misma idea: **capacidad que sigue a la demanda, detrás de un endpoint estable.**

### Pasos

1. **Creá un launch template** — el reemplazo moderno y versionado de las launch configurations:

   ```bash
   AMI_ID=$(aws ssm get-parameter \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameter.Value' --output text)
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
   SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
     --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')

   ALB_SG=$(aws ec2 create-security-group --group-name clf33-alb-sg \
     --description "ALB ingress 80" --vpc-id $VPC_ID --query GroupId --output text)
   aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
     --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

   APP_SG=$(aws ec2 create-security-group --group-name clf33-app-sg \
     --description "from ALB only" --vpc-id $VPC_ID --query GroupId --output text)
   aws ec2 authorize-security-group-ingress --group-id $APP_SG \
     --protocol tcp --port 80 --source-group $ALB_SG >/dev/null

   USERDATA=$(base64 -w0 <<'EOF'
   #!/bin/bash
   dnf install -y nginx
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
   AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
   echo "served by $ID in $AZ" > /usr/share/nginx/html/index.html
   systemctl enable --now nginx
   EOF
   )

   aws ec2 create-launch-template \
     --launch-template-name clf33-lt \
     --launch-template-data "{
       \"ImageId\":\"$AMI_ID\",
       \"InstanceType\":\"t3.micro\",
       \"SecurityGroupIds\":[\"$APP_SG\"],
       \"UserData\":\"$USERDATA\",
       \"MetadataOptions\":{\"HttpTokens\":\"required\"},
       \"TagSpecifications\":[{\"ResourceType\":\"instance\",
         \"Tags\":[{\"Key\":\"Project\",\"Value\":\"clf-33-lab\"}]}]
     }" --query 'LaunchTemplate.{Name:LaunchTemplateName,Version:LatestVersionNumber}' --output table
   ```

2. **Creá el Application Load Balancer y el target group:**

   ```bash
   ALB_ARN=$(aws elbv2 create-load-balancer --name clf33-alb --type application \
     --scheme internet-facing --security-groups $ALB_SG \
     --subnets $(echo $SUBNETS | tr ',' ' ') \
     --query 'LoadBalancers[0].LoadBalancerArn' --output text)

   TG_ARN=$(aws elbv2 create-target-group --name clf33-tg \
     --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance \
     --health-check-path / --health-check-interval-seconds 15 \
     --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
     --query 'TargetGroups[0].TargetGroupArn' --output text)

   aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
     --protocol HTTP --port 80 \
     --default-actions Type=forward,TargetGroupArn=$TG_ARN >/dev/null
   ```

3. **Creá el Auto Scaling group conectado al target group:**

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf33-asg \
     --launch-template LaunchTemplateName=clf33-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --vpc-zone-identifier "$SUBNETS" \
     --target-group-arns "$TG_ARN" \
     --health-check-type ELB --health-check-grace-period 90 \
     --tags "Key=Project,Value=clf-33-lab,PropagateAtLaunch=true"
   ```

4. **Asociá una política de escalado de seguimiento de destino (target tracking).** Este es el tipo de política que el examen espera que reconozcas como "mantener la métrica X en el valor Y":

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf33-asg \
     --policy-name cpu-at-50 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "PredefinedMetricSpecification": {"PredefinedMetricType":"ASGAverageCPUUtilization"},
       "TargetValue": 50.0
     }' --query 'PolicyARN' --output text
   ```

5. **Miralo converger:**

   ```bash
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf33-asg \
     --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,
        Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,
        Lifecycle:LifecycleState,Health:HealthStatus}}' --output json
   ```

   ```json
   {
     "Min": 2, "Max": 4, "Desired": 2,
     "Instances": [
       {"Id":"i-01a2b3c4d5e6f7080","AZ":"us-east-1a","Lifecycle":"InService","Health":"Healthy"},
       {"Id":"i-090807060504030a2","AZ":"us-east-1b","Lifecycle":"InService","Health":"Healthy"}
     ]
   }
   ```

6. **Verificá que el load balancer distribuye entre AZ:**

   ```bash
   DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
     --query 'LoadBalancers[0].DNSName' --output text)
   for i in $(seq 1 8); do curl -s "http://$DNS/"; done
   ```

   ```
   served by i-01a2b3c4d5e6f7080 in us-east-1a
   served by i-090807060504030a2 in us-east-1b
   served by i-01a2b3c4d5e6f7080 in us-east-1a
   served by i-090807060504030a2 in us-east-1b
   ...
   ```

7. **Comprobá la auto-reparación.** Terminá una instancia y mirá cómo el ASG la reemplaza:

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names clf33-asg \
     --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
   aws ec2 terminate-instances --instance-ids $VICTIM >/dev/null
   sleep 90
   aws autoscaling describe-scaling-activities --auto-scaling-group-name clf33-asg \
     --max-items 3 --query 'Activities[].{Status:StatusCode,Cause:Description}' --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                    DescribeScalingActivities                      |
   +-------------+-----------------------------------------------------+
   |  Successful |  Launching a new EC2 instance: i-0aa11bb22cc33dd44   |
   |  Successful |  Terminating EC2 instance: i-01a2b3c4d5e6f7080      |
   +-------------+-----------------------------------------------------+
   ```

8. **Desmontaje (hacelo enseguida):**

   ```bash
   aws autoscaling delete-auto-scaling-group --auto-scaling-group-name clf33-asg --force-delete
   sleep 60
   aws elbv2 delete-listener --listener-arn \
     $(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text)
   aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
   sleep 30
   aws elbv2 delete-target-group --target-group-arn $TG_ARN
   aws ec2 delete-launch-template --launch-template-name clf33-lt
   aws ec2 delete-security-group --group-id $APP_SG
   aws ec2 delete-security-group --group-id $ALB_SG
   ```

Referencias: <https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html> · <https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html>

### Control — Ejercicio 4

- **P4.1** Nombrá los cuatro beneficios del AWS Well-Architected que entregó el ASG en este ejercicio, e identificá cuál demostró específicamente el paso 7.
- **P4.2** Configuraste `--health-check-type ELB` en lugar del `EC2` por defecto. ¿Qué falla se le escapa al chequeo de salud `EC2`?
- **P4.3** Asociá cada uno a su capa OSI y su uso principal: Application Load Balancer, Network Load Balancer, Gateway Load Balancer.
- **P4.4** Distinguí **Amazon EC2 Auto Scaling** de **AWS Auto Scaling** / Application Auto Scaling. Dá un recurso no-EC2 que escale este último.
- **P4.5** Nombrá los cuatro tipos de política de EC2 Auto Scaling y dá un escenario de una línea para cada uno.
- **P4.6** ¿Es lo mismo el escalado horizontal que el vertical? ¿Cuál realizó este ejercicio, y cuál requiere un reinicio?

---

## Ejercicio 5 — Contenedores: ECR, ECS, Fargate, EKS

**💸 CREA RECURSOS FACTURABLES** (un repositorio ECR, una tarea Fargate de corta duración). El desmontaje es el paso 8.

La distinción del examen es: **ECS/EKS = orquestador** (qué corre dónde), **Fargate/EC2 = tipo de lanzamiento** (en la máquina de quién corre), **ECR = registro** (dónde vive la imagen). Son tres ejes ortogonales y las preguntas los confunden habitualmente.

### Pasos

1. **Creá un repositorio ECR privado con escaneo al hacer push:**

   ```bash
   aws ecr create-repository --repository-name clf33/hello \
     --image-scanning-configuration scanOnPush=true \
     --image-tag-mutability IMMUTABLE \
     --query 'repository.{Uri:repositoryUri,Tag:imageTagMutability}' --output table
   ```

   ```
   ---------------------------------------------------------------------------
   |                            CreateRepository                             |
   +-----------+-------------------------------------------------------------+
   |  Tag      |  IMMUTABLE                                                  |
   |  Uri      |  111122223333.dkr.ecr.us-east-1.amazonaws.com/clf33/hello   |
   +-----------+-------------------------------------------------------------+
   ```

2. **Autenticá Docker contra ECR.** Notá que la credencial es un token de vida corta derivado de tu identidad IAM, no una contraseña almacenada:

   ```bash
   REPO_URI=$(aws ecr describe-repositories --repository-names clf33/hello \
     --query 'repositories[0].repositoryUri' --output text)

   aws ecr get-login-password --region "$AWS_REGION" \
     | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
   ```

   ```
   Login Succeeded
   ```

3. **Construí y subí una imagen mínima:**

   ```bash
   mkdir -p /tmp/clf33 && cd /tmp/clf33
   cat > Dockerfile <<'EOF'
   FROM public.ecr.aws/amazonlinux/amazonlinux:2023
   CMD ["/bin/sh","-c","echo hello from $(uname -m) on Fargate; sleep 20"]
   EOF

   docker build -t "$REPO_URI:1.0.0" .
   docker push "$REPO_URI:1.0.0"

   aws ecr describe-images --repository-name clf33/hello \
     --query 'imageDetails[].{Tags:imageTags,SizeMB:imageSizeInBytes,Pushed:imagePushedAt}' \
     --output table
   ```

4. **Creá un cluster de ECS.** Con Fargate, esto es una agrupación puramente lógica — no se crea ninguna instancia:

   ```bash
   aws ecs create-cluster --cluster-name clf33-cluster \
     --capacity-providers FARGATE FARGATE_SPOT \
     --query 'cluster.{Name:clusterName,Status:status,Instances:registeredContainerInstancesCount}' \
     --output table
   ```

   ```
   ------------------------------------------
   |              CreateCluster             |
   +-------------+--------------------------+
   |  Instances  |  0                       |
   |  Name       |  clf33-cluster           |
   |  Status     |  ACTIVE                  |
   +-------------+--------------------------+
   ```

   **`registeredContainerInstancesCount: 0` es la esencia de Fargate.** Con el tipo de lanzamiento EC2 este número sería la cantidad de instancias que parcheás, escalás y pagás por hora.

5. **Registrá una task definition** — la unidad declarativa que ECS agenda:

   ```bash
   aws iam create-role --role-name clf33-ecs-exec \
     --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
   aws iam attach-role-policy --role-name clf33-ecs-exec \
     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
   EXEC_ARN=$(aws iam get-role --role-name clf33-ecs-exec --query 'Role.Arn' --output text)

   aws logs create-log-group --log-group-name /ecs/clf33 2>/dev/null

   cat > /tmp/td.json <<JSON
   {
     "family": "clf33-hello",
     "networkMode": "awsvpc",
     "requiresCompatibilities": ["FARGATE"],
     "cpu": "256",
     "memory": "512",
     "runtimePlatform": { "cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX" },
     "executionRoleArn": "$EXEC_ARN",
     "containerDefinitions": [
       {
         "name": "hello",
         "image": "$REPO_URI:1.0.0",
         "essential": true,
         "logConfiguration": {
           "logDriver": "awslogs",
           "options": {
             "awslogs-group": "/ecs/clf33",
             "awslogs-region": "$AWS_REGION",
             "awslogs-stream-prefix": "hello"
           }
         }
       }
     ]
   }
   JSON

   aws ecs register-task-definition --cli-input-json file:///tmp/td.json \
     --query 'taskDefinition.{Family:family,Rev:revision,Cpu:cpu,Mem:memory}' --output table
   ```

   ```
   -------------------------------------
   |      RegisterTaskDefinition       |
   +----------+------------------------+
   |  Cpu     |  256                   |
   |  Family  |  clf33-hello           |
   |  Mem     |  512                   |
   |  Rev     |  1                     |
   +----------+------------------------+
   ```

   `cpu: 256` es 0,25 vCPU. Fargate acepta solo una grilla discreta de pares CPU/memoria — probá `"cpu":"256","memory":"8192"` y la API lo rechaza. Grilla: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html>

6. **Ejecutá la tarea en Fargate:**

   ```bash
   VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
   SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[0].SubnetId' --output text)
   TASK_SG=$(aws ec2 create-security-group --group-name clf33-task-sg \
     --description "egress only" --vpc-id $VPC_ID --query GroupId --output text)

   TASK_ARN=$(aws ecs run-task --cluster clf33-cluster \
     --task-definition clf33-hello \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
     --query 'tasks[0].taskArn' --output text)

   aws ecs wait tasks-stopped --cluster clf33-cluster --tasks "$TASK_ARN"

   aws ecs describe-tasks --cluster clf33-cluster --tasks "$TASK_ARN" \
     --query 'tasks[0].{LastStatus:lastStatus,StopCode:stopCode,
        Cpu:cpu,Memory:memory,Platform:platformVersion,
        Exit:containers[0].exitCode}' --output table
   ```

   ```
   -------------------------------------
   |           DescribeTasks           |
   +--------------+--------------------+
   |  Cpu         |  256               |
   |  Exit        |  0                 |
   |  LastStatus  |  STOPPED           |
   |  Memory      |  512               |
   |  Platform    |  1.4.0             |
   |  StopCode    |  EssentialContainerExited |
   +--------------+--------------------+
   ```

   ```bash
   aws logs tail /ecs/clf33 --since 10m
   ```

   ```
   2026-09-04T14:22:11 hello/hello/8f2c... hello from x86_64 on Fargate
   ```

7. **Compará los orquestadores sin desplegar EKS** (un plano de control de EKS factura por hora desde su creación — no crees uno para este laboratorio). Inspeccioná lo que ofrece AWS:

   ```bash
   aws eks describe-addon-versions \
     --query 'addons[0:5].{Addon:addonName,Type:type}' --output table

   aws eks list-clusters --query 'clusters' --output text   # expect empty
   ```

   ```
   ----------------------------------------------
   |          DescribeAddonVersions             |
   +--------------------------+-----------------+
   |          Addon           |      Type       |
   +--------------------------+-----------------+
   |  vpc-cni                 |  networking     |
   |  coredns                 |  networking     |
   |  kube-proxy              |  networking     |
   |  aws-ebs-csi-driver      |  storage        |
   |  aws-efs-csi-driver      |  storage        |
   +--------------------------+-----------------+
   ```

   Esos nombres de add-ons son componentes de Kubernetes upstream. **Esa es la señal identificatoria**: EKS corre Kubernetes upstream y conforme; ECS corre un planificador propietario de AWS sin API de Kubernetes.

8. **Desmontaje:**

   ```bash
   aws ecs delete-cluster --cluster clf33-cluster >/dev/null
   aws ecr delete-repository --repository-name clf33/hello --force >/dev/null
   aws logs delete-log-group --log-group-name /ecs/clf33
   aws ec2 delete-security-group --group-id $TASK_SG
   aws iam detach-role-policy --role-name clf33-ecs-exec \
     --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
   aws iam delete-role --role-name clf33-ecs-exec
   aws ecs deregister-task-definition --task-definition clf33-hello:1 >/dev/null
   ```

Referencias: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html> · <https://docs.aws.amazon.com/AmazonECS/latest/userguide/what-is-fargate.html> · <https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html> · <https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html>

### Control — Ejercicio 5

- **P5.1** El cluster reportó `registeredContainerInstancesCount: 0` y sin embargo un contenedor corrió. ¿Dónde corrió, y quién parchea ese sistema operativo?
- **P5.2** Completá la grilla — para cada celda, quién es responsable del parcheo del SO, del escalado de capacidad y cuál es la unidad de facturación:

  | | ECS | EKS |
  |---|---|---|
  | **Tipo de lanzamiento EC2** | ? | ? |
  | **Tipo de lanzamiento Fargate** | ? | ? |

- **P5.3** Una empresa ya corre Kubernetes on-premises con Helm charts y operadores propios, y quiere la mínima reescritura al mudarse a AWS. ¿ECS o EKS? ¿Cuál es el trade-off de costo de esa elección?
- **P5.4** Amazon ECR se describe como "un registro de contenedores". ¿Cuáles otros dos servicios de cómputo de AWS de este ejercicio lo *consumen*, y nombrá un lugar fuera de AWS donde podría correr la misma imagen.
- **P5.5** Configuraste `imageTagMutability: IMMUTABLE`. ¿Por qué importa eso para la reproducibilidad, y qué se rompe si un equipo usa `:latest`?
- **P5.6** Nombrá los dos capacity providers que asociaste en el paso 4 y la diferencia operativa entre ellos.

---

## Ejercicio 6 — Serverless: AWS Lambda

**💸 Costo despreciable** (un puñado de invocaciones). El desmontaje es el paso 7.

Lambda es el punto donde dejás de aprovisionar capacidad por completo. El examen quiere que reconozcas sus rasgos identificatorios: **dirigido por eventos, sin gestión de servidores, granularidad de facturación por debajo del segundo, techo duro de ejecución.**

### Pasos

1. **Creá el rol de ejecución:**

   ```bash
   aws iam create-role --role-name clf33-lambda-role \
     --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
   aws iam attach-role-policy --role-name clf33-lambda-role \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
   LAMBDA_ROLE=$(aws iam get-role --role-name clf33-lambda-role --query 'Role.Arn' --output text)
   sleep 10   # IAM is eventually consistent
   ```

2. **Escribí una función que reporte su propio entorno de ejecución:**

   ```bash
   mkdir -p /tmp/clf33-fn && cd /tmp/clf33-fn
   cat > lambda_function.py <<'PY'
   import json, os, time, multiprocessing

   COLD = True

   def lambda_handler(event, context):
       global COLD
       was_cold, COLD = COLD, False
       burn = int(event.get("burn_ms", 0))
       t0 = time.time()
       while (time.time() - t0) * 1000 < burn:
           pass
       return {
           "cold_start": was_cold,
           "memory_limit_mb": context.memory_limit_in_mb,
           "vcpus_visible": multiprocessing.cpu_count(),
           "remaining_ms": context.get_remaining_time_in_millis(),
           "region": os.environ["AWS_REGION"],
           "runtime": os.environ["AWS_EXECUTION_ENV"],
           "log_stream": context.log_stream_name,
       }
   PY
   zip -q function.zip lambda_function.py
   ```

3. **Desplegala con 128 MB:**

   ```bash
   aws lambda create-function --function-name clf33-introspect \
     --runtime python3.12 --handler lambda_function.lambda_handler \
     --role "$LAMBDA_ROLE" --zip-file fileb://function.zip \
     --memory-size 128 --timeout 30 --architectures arm64 \
     --query '{Name:FunctionName,Mem:MemorySize,Timeout:Timeout,Arch:Architectures,State:State}' \
     --output table
   ```

   ```
   -----------------------------------------
   |             CreateFunction            |
   +-----------+---------------------------+
   |  Arch     |  arm64                    |
   |  Mem      |  128                      |
   |  Name     |  clf33-introspect         |
   |  State    |  Pending                  |
   |  Timeout  |  30                       |
   +-----------+---------------------------+
   ```

4. **Invocá dos veces y observá la distinción frío/caliente:**

   ```bash
   aws lambda wait function-active-v2 --function-name clf33-introspect

   for i in 1 2; do
     aws lambda invoke --function-name clf33-introspect \
       --payload '{"burn_ms":0}' --cli-binary-format raw-in-base64-out \
       --log-type Tail --query 'LogResult' --output text /tmp/out.json | base64 -d | grep REPORT
     cat /tmp/out.json | jq -c '{cold_start,memory_limit_mb,vcpus_visible}'
   done
   ```

   ```
   REPORT RequestId: 3f0e... Duration: 1.42 ms  Billed Duration: 2 ms  Memory Size: 128 MB  Max Memory Used: 39 MB  Init Duration: 118.44 ms
   {"cold_start":true,"memory_limit_mb":128,"vcpus_visible":2}
   REPORT RequestId: a91c... Duration: 0.98 ms  Billed Duration: 1 ms  Memory Size: 128 MB  Max Memory Used: 39 MB
   {"cold_start":false,"memory_limit_mb":128,"vcpus_visible":2}
   ```

   La segunda invocación **no tiene `Init Duration`** — el entorno de ejecución se reutilizó. Ese es el fenómeno del cold start, empíricamente.

5. **Demostrá que la memoria es la perilla de la CPU.** En Lambda, la CPU se asigna proporcionalmente a la memoria — no podés comprarlas por separado:

   ```bash
   for MEM in 128 512 1769 3008; do
     aws lambda update-function-configuration --function-name clf33-introspect \
       --memory-size $MEM >/dev/null
     aws lambda wait function-updated-v2 --function-name clf33-introspect
     printf "MEM=%-5s " "$MEM"
     aws lambda invoke --function-name clf33-introspect \
       --payload '{"burn_ms":2000}' --cli-binary-format raw-in-base64-out \
       --log-type Tail --query 'LogResult' --output text /dev/null \
       | base64 -d | grep -o 'Billed Duration: [0-9]* ms'
   done
   ```

   ```
   MEM=128   Billed Duration: 2001 ms
   MEM=512   Billed Duration: 2001 ms
   MEM=1769  Billed Duration: 2001 ms
   MEM=3008  Billed Duration: 2001 ms
   ```

   Un busy-loop medido por reloj de pared es independiente de la memoria por diseño. Ahora reemplazá el payload por trabajo real (`burn_ms` → un hash intensivo en CPU) y las duraciones divergen fuertemente. En **1.769 MB la función obtiene exactamente una vCPU completa**; por debajo obtiene una fracción con reparto de tiempo. Referencia: <https://docs.aws.amazon.com/lambda/latest/dg/configuration-function-common.html>

6. **Chocá contra los límites a propósito.** Cada rechazo enseña un límite que aparece en el examen:

   ```bash
   # a) memory ceiling
   aws lambda update-function-configuration --function-name clf33-introspect --memory-size 10241
   # b) timeout ceiling
   aws lambda update-function-configuration --function-name clf33-introspect --timeout 901
   ```

   ```
   An error occurred (InvalidParameterValueException) when calling the
   UpdateFunctionConfiguration operation: 'memorySize' failed to satisfy constraint:
   Member must have value less than or equal to 10240

   An error occurred (InvalidParameterValueException) when calling the
   UpdateFunctionConfiguration operation: 'timeout' failed to satisfy constraint:
   Member must have value less than or equal to 900
   ```

   Y revisá el techo de concurrencia de la cuenta:

   ```bash
   aws lambda get-account-settings \
     --query 'AccountLimit.{ConcurrentExecutions:ConcurrentExecutions,
       CodeSizeZipped:CodeSizeZipped,CodeSizeUnzipped:CodeSizeUnzipped,
       TotalCodeSizeMB:TotalCodeSize}' --output table
   ```

   ```
   ------------------------------------------------
   |             GetAccountSettings               |
   +------------------------+---------------------+
   |  CodeSizeUnzipped      |  262144000          |
   |  CodeSizeZipped        |  52428800           |
   |  ConcurrentExecutions  |  1000               |
   |  TotalCodeSizeMB       |  80530636800        |
   +------------------------+---------------------+
   ```

7. **Desmontaje:**

   ```bash
   aws lambda delete-function --function-name clf33-introspect
   aws logs delete-log-group --log-group-name /aws/lambda/clf33-introspect 2>/dev/null
   aws iam detach-role-policy --role-name clf33-lambda-role \
     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
   aws iam delete-role --role-name clf33-lambda-role
   ```

### Control — Ejercicio 6

- **P6.1** A partir de los mensajes de error del paso 6, indicá la memoria máxima de Lambda, el timeout máximo y el límite de concurrencia por Región por defecto.
- **P6.2** Un trabajo lleva 40 minutos de CPU continua. Explicá por qué Lambda es arquitectónicamente inadecuado para eso y nombrá dos servicios de cómputo de AWS que encajen.
- **P6.3** La primera invocación mostró `Init Duration: 118 ms`, la segunda ninguna. Nombrá el fenómeno y una funcionalidad de AWS que lo mitigue.
- **P6.4** En Lambda configurás memoria pero nunca CPU. ¿Por qué? ¿Cuál es la significancia de la cifra de 1.769 MB?
- **P6.5** Lambda factura por GB-segundo con granularidad de 1 ms; EC2 factura por segundo con un mínimo de 60 segundos. Para una carga que recibe 40 solicitudes por día, de 200 ms cada una, ¿cuál es más barato y aproximadamente en qué orden de magnitud?
- **P6.6** "Serverless significa que no hay servidores." Corregí esta afirmación con precisión.

---

## Ejercicio 7 — El nivel de abstracción gestionada

**Solo de lectura — no se crean recursos facturables.**

Entre "alquilar una VM" y "entregarle una función a AWS" hay una banda de servicios que cambian control por simplicidad operativa. El examen evalúa si podés elegir el *nivel de abstracción correcto* para un equipo descripto.

### Pasos

1. **AWS Elastic Beanstalk — PaaS sobre EC2 que todavía podés ver.** Listá los runtimes que gestiona por vos:

   ```bash
   aws elasticbeanstalk list-available-solution-stacks \
     --query 'SolutionStacks[?contains(@,`Python`) || contains(@,`Docker`)]' \
     --output text | tr '\t' '\n' | head -8
   ```

   ```
   64bit Amazon Linux 2023 v4.x.x running Python 3.12
   64bit Amazon Linux 2023 v4.x.x running Python 3.11
   64bit Amazon Linux 2023 v4.x.x running Docker
   ...
   ```

   Beanstalk aprovisiona EC2, un ASG, un ELB y alarmas de CloudWatch *por* vos, pero los deja en tu cuenta, visibles y ajustables. **El servicio en sí no tiene cargo — pagás por los recursos que crea.**

2. **Amazon Lightsail — precios de VPS empaquetados.** Compará el modelo mental con EC2 puro:

   ```bash
   aws lightsail get-bundles --region us-east-1 \
     --query 'bundles[?isActive][].{Id:bundleId,USDmo:price,vCPU:cpuCount,
        RamGB:ramSizeInGb,DiskGB:diskSizeInGb,TransferGB:transferPerMonthInGb}' \
     --output table | head -14
   ```

   ```
   --------------------------------------------------------------------------
   |                              GetBundles                                |
   +---------------+--------+--------+---------+----------+-----------------+
   |      Id       | USDmo  | vCPU   | RamGB   | DiskGB   |  TransferGB     |
   +---------------+--------+--------+---------+----------+-----------------+
   |  nano_3_0     |  5.0   |  2     |  0.5    |  20      |  1024           |
   |  micro_3_0    |  7.0   |  2     |  1.0    |  40      |  2048           |
   |  small_3_0    |  12.0  |  2     |  2.0    |  60      |  3072           |
   +---------------+--------+--------+---------+----------+-----------------+
   ```

   **Un único número mensual fijo** que ya incluye cómputo, SSD, una IP estática y transferencia de datos. Esa previsibilidad *es* el producto.

3. **AWS Batch — planificación de lotes gestionada.** Inspeccioná el modelo de tres objetos:

   ```bash
   aws batch describe-compute-environments --query 'computeEnvironments' --output text
   aws batch describe-job-queues            --query 'jobQueues' --output text
   aws batch describe-job-definitions --status ACTIVE --query 'jobDefinitions[].jobDefinitionName' --output text
   ```

   Todo vacío en una cuenta nueva. Leé el modelo en vez de construirlo: un **compute environment** (EC2 On-Demand, EC2 Spot o Fargate) provee capacidad; una **job queue** contiene el trabajo con una prioridad; una **job definition** es la plantilla de contenedor + recursos. Batch escala el entorno desde cero hasta la profundidad de la cola y de vuelta a cero. Referencia: <https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html>

4. **AWS App Runner — de código fuente o contenedor a una URL HTTPS:**

   ```bash
   aws apprunner list-services --region us-east-1 \
     --query 'ServiceSummaryList[].{Name:ServiceName,Status:Status,Url:ServiceUrl}' --output table
   ```

   App Runner toma una imagen de ECR o un repositorio de GitHub y devuelve un endpoint HTTPS balanceado, con autoescalado y terminación TLS. No configurás ninguna VPC, ni ALB, ni ASG, ni cluster.

5. **Cómputo en el borde e híbrido — dónde está físicamente el cómputo.** Consultá los puntos de extensión:

   ```bash
   # Local Zones and Wavelength Zones surfaced as special AZ types
   aws ec2 describe-availability-zones --all-availability-zones \
     --query 'AvailabilityZones[?ZoneType!=`availability-zone`].{
        Name:ZoneName,Type:ZoneType,Group:GroupName,Parent:ParentZoneName,
        Opt:OptInStatus}' --output table | head -20
   ```

   ```
   ---------------------------------------------------------------------------------
   |                          DescribeAvailabilityZones                            |
   +-------------------+-------------------+-------------+-----------+-------------+
   |       Name        |       Type        |    Group    |  Parent   |     Opt     |
   +-------------------+-------------------+-------------+-----------+-------------+
   |  us-east-1-atl-1a |  local-zone       |  us-east-1-atl-1 | us-east-1e | not-opted-in |
   |  us-east-1-bos-1a |  local-zone       |  us-east-1-bos-1 | us-east-1a | not-opted-in |
   |  us-east-1-wl1-atl-wlz-1 | wavelength-zone | us-east-1-wl1-atl-1 | us-east-1a | not-opted-in |
   ...
   ```

   ```bash
   aws outposts list-outposts --query 'Outposts[].{Id:OutpostId,Site:SiteId,AZ:AvailabilityZone}' --output table
   ```

   ```
   An error occurred (AccessDeniedException) ... or an empty list — you have no Outposts.
   ```

   Los tres, con precisión:

   | Servicio | Dónde está el hardware | Escenario identificatorio |
   |---|---|---|
   | **AWS Outposts** | Tu propio data center / colo, racks propiedad de AWS | Residencia de datos o latencia de un dígito de ms hacia sistemas on-prem; las mismas APIs |
   | **AWS Local Zones** | Instalación metropolitana de AWS cerca de un centro poblacional | Aplicaciones sensibles a la latencia (medios, gaming, EDA) en una ciudad sin Región |
   | **AWS Wavelength** | Dentro de la red 5G de un operador de telecomunicaciones | Tráfico de dispositivos móviles que no debe atravesar internet |

6. **Cómputo en la familia Snow** — cómputo que viaja:

   ```bash
   aws snowball describe-addresses --query 'Addresses' --output text
   aws snowball list-jobs --query 'JobListEntries[].{Id:JobId,Type:JobType,State:JobState}' --output table
   ```

   Snowball Edge Compute Optimized corre instancias compatibles con EC2 y funciones Lambda **desconectado** — en un barco, en un yacimiento de perforación, en un hospital de campaña.

Referencias: <https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html> · <https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html> · <https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html> · <https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html> · <https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html> · <https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html>

### Control — Ejercicio 7

- **P7.1** Elastic Beanstalk y App Runner ambos "despliegan tu app sin gestionar servidores". Dá la pregunta distintiva más filosa que harías para elegir entre ellos.
- **P7.2** Una startup de tres personas quiere un sitio WordPress por un predecible USD 10/mes sin experiencia en AWS. ¿Lightsail, EC2 o Elastic Beanstalk? ¿A qué renuncian?
- **P7.3** Nombrá los tres objetos centrales de AWS Batch y explicá qué significa "escala a cero" para la factura.
- **P7.4** Un hospital debe mantener el cómputo de procesamiento de pacientes físicamente dentro de su propio edificio pero quiere las APIs de EC2 y EBS. ¿Qué servicio, y por qué una Local Zone es la respuesta equivocada?
- **P7.5** En el paso 5, ¿por qué toda Local Zone apareció como `not-opted-in`, y qué implica eso sobre la colocación de recursos por defecto?
- **P7.6** Ordená estos cinco por control *decreciente* del cliente sobre el SO: Lambda, EC2, Fargate, Lightsail, Elastic Beanstalk.

---

## Ejercicio 8 — Síntesis: la decisión de selección

**Ejercicio de papel — sin comandos.** Esta es la forma de la pregunta de examen.

### Pasos

1. **Reconstruí el árbol de decisión de memoria**, después contrastalo con tus notas. Empezá por: *¿Es dirigido por eventos y de menos de 15 minutos?*

2. **Mapeá cada escenario a exactamente un servicio y un modo de compra/lanzamiento.** Escribí tu respuesta antes de abrir la clave.

   | # | Escenario |
   |---|---|
   | **S1** | Generación de miniaturas disparada por cada carga a S3; a ráfagas, ~300 ms por imagen, miles por hora |
   | **S2** | Un ERP de Windows Server de 15 años con licencia por núcleo físico, corriendo 24×7 por al menos 3 años |
   | **S3** | Pipeline de genómica: 4.000 trabajos independientes, 20 min cada uno, con checkpoints, debe terminar el lunes, el costo es la prioridad |
   | **S4** | Plataforma Kubernetes on-premises existente con Helm y CRDs propios, migrando a AWS con reescritura mínima |
   | **S5** | Una app Java Spring Boot; un equipo de dos desarrolladores que quiere despliegues por git push y ningún trabajo de infraestructura, pero necesita entrar por SSH a los servidores cuando algo se rompe |
   | **S6** | Un microservicio empaquetado como imagen de contenedor; sin experiencia en Kubernetes en el equipo; debe correr 24×7 detrás de un ALB sin gestión de instancias |
   | **S7** | Una carga de inferencia para vehículos autónomos que requiere menos de 10 ms de latencia hacia dispositivos en una red 5G de un operador |
   | **S8** | Una base de datos de grafos en memoria que necesita 1 TiB de RAM, carga estable, compromiso de 1 año aceptable, dispuestos a quedarse en una sola familia de instancias |
   | **S9** | Un sitio de marketing con un presupuesto fijo y predecible de USD 5/mes y sin requisito de elasticidad |
   | **S10** | Entrenamiento nocturno de ML en GPUs, 6 horas, reiniciable, y el equipo quiere encolado de trabajos en vez de gestión de clusters |

3. **Para cada uno de S1–S10, indicá también la línea de responsabilidad compartida**: nombrá la capa más alta que gestiona AWS.

4. **Autoevaluá los antipatrones.** Para cada emparejamiento de abajo, nombrá la restricción descalificante:
   - Lambda para S3
   - EC2 On-Demand para S8
   - Fargate para S2
   - Spot para una base de datos de producción con estado

### Control — Ejercicio 8

- **P8.1** Dá tu servicio + modo para cada uno de S1–S10.
- **P8.2** Respondé los cuatro antipatrones del paso 4.
- **P8.3** Enunciá la regla de una sola oración que usarías el día del examen para separar EC2 / contenedores / serverless cuando la pregunta no te da ninguna otra señal.

---

## Verificación de limpieza completa

Ejecutá esto antes de cerrar el laboratorio. Todo lo que aparezca acá te sigue facturando.

```bash
echo "== EC2 =="
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name}' --output table

echo "== Load balancers =="
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text

echo "== Auto Scaling groups =="
aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].AutoScalingGroupName' --output text

echo "== ECS clusters =="
aws ecs list-clusters --query 'clusterArns' --output text

echo "== EKS clusters =="
aws eks list-clusters --query 'clusters' --output text

echo "== Lambda functions =="
aws lambda list-functions --query 'Functions[].FunctionName' --output text

echo "== ECR repositories =="
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text

echo "== Unattached EBS volumes =="
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{Id:VolumeId,GiB:Size}' --output table

echo "== Unassociated Elastic IPs (billable!) =="
aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].PublicIp' --output text
```

---

<details>
<summary><b>📋 Clave de respuestas — clic para desplegar</b></summary>

### Ejercicio 1 — Espacio de nombres de tipos de instancia

**R1.1** `c` = familia optimizada para cómputo (alta relación vCPU-a-memoria, ~2 GiB por vCPU) · `6` = 6ª generación · `g` = procesador AWS Graviton (ARM64) · `n` = variante optimizada para red y EBS con ancho de banda sustancialmente mayor · `8xlarge` = el tamaño, 32 vCPUs. Se lee como: *familia + generación + atributos de procesador/capacidad + tamaño*. (<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>)

**R1.2** Optimizada para memoria — la familia **R**, o **X**/High Memory para huellas extremas. Optimizada para cómputo es incorrecto porque la letra de la familia codifica una *relación*, no un nivel de calidad: para llegar a 200 GiB de RAM en `c7i` tenés que escalar hasta aproximadamente `c7i.24xlarge` (96 vCPUs, 192 GiB), comprando ~90 vCPUs que nunca vas a usar. `r7i.8xlarge` entrega 256 GiB con 32 vCPUs a un costo mucho menor. **Dimensionar correctamente significa igualar la relación, no maximizar una dimensión.**

**R1.3** En Graviton, `ThreadsPerCore: 1` — una vCPU es un **núcleo físico**; no hay SMT. En Intel/AMD con `ThreadsPerCore: 2`, una vCPU es un **hyperthread**, es decir la mitad de un núcleo físico. Consecuencia: una instancia Graviton de 8 vCPU tiene 8 núcleos reales mientras que una Intel de 8 vCPU tiene 4 — los conteos de vCPU no son directamente comparables entre arquitecturas, y por eso los benchmarks de Graviton suelen superar a sus pares de vCPU nominal.

**R1.4** Incorrecto — los tipos bare metal (`*.metal`, p. ej. `m7i.metal-24xl`) son instancias EC2 comunes lanzadas con la misma API `RunInstances`, las mismas AMIs, volúmenes EBS, security groups, VPC e IAM. La diferencia es que tu SO corre directamente sobre el hardware sin hipervisor, que es lo que requieren las cargas de virtualización anidada y el software dependiente de características de hardware o sensible al licenciamiento. Mismo servicio, mismo modelo de responsabilidad compartida.

**R1.5** `d` significa **almacenamiento local NVMe (instance store)**: físicamente adosado al host, muy rápido y **efímero**. Sus datos se pierden al detener, hibernar, terminar o ante una falla de hardware del host — solo sobrevive a un reinicio del SO invitado. Por lo tanto es válido para cachés, espacio de trabajo temporal, tablas temporales y datos de shuffle, y nunca para algo que deba ser durable. El estado durable va en EBS (replicado en la AZ) o en S3 (11 nueves).

---

### Ejercicio 2 — Introspección de la instancia

**R2.1** SSM Session Manager trabaja **hacia afuera**: el agente SSM de la instancia abre una conexión HTTPS hacia los endpoints de Systems Manager, y tu sesión se tuneliza de vuelta por ahí. No hace falta ningún puerto de entrada, ni par de claves, ni host bastión — por eso la instancia tenía cero reglas de entrada. Responsabilidad compartida: AWS opera el plano de control de Session Manager y el túnel; **vos** seguís siendo responsable del rol IAM que define quién puede conectarse, de la presencia del agente y del registro de sesiones en S3/CloudWatch. Reducir la superficie de ataque de "SSH abierto al mundo" a "túnel saliente autorizado por IAM" es una decisión del lado del cliente.

**R2.2** **Robo de credenciales basado en SSRF.** Si a una aplicación de la instancia se la puede engañar para que consulte una URL provista por un atacante, el `GET` plano de IMDSv1 devolvería las credenciales IAM temporales del instance profile. IMDSv2 exige primero un `PUT` para obtener un token de sesión — una forma de solicitud que la mayoría de los vectores SSRF no puede producir — y `HttpPutResponseHopLimit=1` fija el TTL IP del paquete de respuesta en 1, de modo que el token no puede reenviarse fuera de la instancia (por ejemplo, fuera de un contenedor con su propio namespace de red, o a través de un proxy inverso mal configurado). (<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>)

**R2.3**

| Recurso | ¿Se factura mientras está detenida? |
|---|---|
| vCPU / RAM (horas de instancia) | **No** |
| Volumen raíz EBS | **Sí** — GiB-mes aprovisionados, sin importar el estado de la instancia |
| Dirección IPv4 privada | **No** (se retiene, sin cargo) |
| Elastic IP | **Sí** — AWS cobra por las direcciones IPv4 públicas, y una EIP no asociada a una instancia *en ejecución* se factura desde hace tiempo |

La factura sorpresa clásica es una flota de instancias detenidas con volúmenes gp3 grandes y EIPs huérfanas.

**R2.4** Un **snapshot de EBS** es una copia de respaldo puntual, incremental y a nivel de bloques de un único volumen, almacenada sobre almacenamiento respaldado por S3. Una **AMI** es una plantilla de lanzamiento para una máquina completa: *referencia* uno o más snapshots y agrega los metadatos que EC2 necesita para arrancar — mapeo del dispositivo raíz, tipo de virtualización, arquitectura, kernel, soporte ENA/SR-IOV y permisos de lanzamiento. Podés restaurar un volumen desde un snapshot; solo podés lanzar una instancia desde una AMI. La **AMI es la golden image** — el artefacto que tu pipeline (EC2 Image Builder, Packer) produce, versiona y entrega a los launch templates.

**R2.5** (a) Rendimiento: 100% de CPU sostenido en ambas vCPU durante las 10 horas completas — el modo `unlimited` nunca limita. (b) Factura: el saldo de créditos se agota en los primeros minutos, y luego cada hora-CPU consumida por encima de la línea base (10% por vCPU para `t3.micro`) se cobra como **créditos excedentes** a una tarifa publicada por vCPU-hora, encima del precio horario de la instancia. A lo largo de 10 horas esto puede superar el costo de una `m6i` del mismo tamaño — el antipatrón de correr una carga de CPU sostenida sobre una familia burstable. En modo `standard` la instancia en cambio sería **limitada a su línea base del 10%** una vez que los créditos llegan a cero: sin cargo sorpresa, pero con un colapso de rendimiento severo y a menudo invisible. Ningún modo es "seguro" para carga sostenida; la corrección correcta es una familia no burstable.

**R2.6** (1) **Idempotencia** — el ASG puede lanzar la instancia en cualquier momento; el script debe producir el mismo resultado sea la AMI fresca o parcialmente horneada. (2) **No interactividad y comportamiento fail-fast** — corre como root sin TTY, así que cualquier prompt cuelga el arranque; además debe señalizar la falla (o la instancia debe fallar su chequeo de salud del ELB) en vez de levantar a medio configurar y quedar marcada como `InService`. Además: no debe embeber secretos (usar Secrets Manager / Parameter Store vía el instance profile) y debe ser corto, porque corre en **cada** evento de scale-out y extiende directamente el tiempo hasta quedar sano.

---

### Ejercicio 3 — Opciones de compra

**R3.1** **Spot Instances** — hasta ~90% de descuento sobre On-Demand, y la propia descripción de la carga (nocturna, con checkpoints, reiniciable) coincide exactamente con el modelo. El requisito arquitectónico: la aplicación debe ser **tolerante a interrupciones** — debe manejar el aviso de terminación de 2 minutos desde `/latest/meta-data/spot/instance-action` (e idealmente la recomendación previa de rebalanceo de instancias EC2) haciendo checkpoint y drenando, y debe poder retomar en otro lado sin perder trabajo. Todo estado en el instance store local debe tratarse como descartable.

**R3.2** **Compute Savings Plan.** Es un compromiso con un monto en dólares por hora de uso de cómputo y se aplica automáticamente entre familias de instancia, tamaños, SO, tenencia, **Región**, y entre EC2, Fargate **y** Lambda. Cada cambio mencionado — `m5`→`m7g`, EC2→Fargate — queda absorbido sin intercambio, sin recompra y sin hueco de cobertura. Una Standard RI queda atada a familia/Región (el descuento más alto, la menor flexibilidad); una Convertible RI permite intercambios pero es un proceso manual y engorroso; un EC2 Instance Savings Plan queda atado a familia de instancia + Región y **no** cubre uso de Fargate ni de Lambda.

**R3.3** Un puntaje de **9** significa que AWS predice una alta probabilidad de que una solicitud Spot *de ese tamaño específico, para esos tipos de instancia específicos, en esa Región/AZ, ahora mismo* pueda satisfacerse sin interrupción inmediata. Explícitamente **no** te dice: el precio, que la capacidad esté reservada para vos, ni que el puntaje siga vigente dentro de una hora. Es un pronóstico de disponibilidad de capacidad, no una garantía ni una señal de precio — y solo tiene sentido en relación con la capacidad objetivo que suministraste.

**R3.4** Un Savings Plan te compromete a **gastar un monto fijo en dólares por hora en cómputo** (p. ej. "USD 10/hora por 3 años"), no a una instancia particular. El uso hasta esa tasa en dólares se factura a la tarifa con descuento; el uso más allá cae a On-Demand. Como la unidad es dinero y no un SKU de hora-instancia, el descuento sigue a tu carga de trabajo adonde vaya — precisamente por eso los Compute Savings Plans sobreviven a una re-arquitectura y las Reserved Instances (que atan un descuento a una configuración de instancia descripta) no.

**R3.5** **Dedicated Host.** El paso 6 mostró que `describe-hosts` expone `Sockets` y `Cores` — visibilidad del servidor *físico*. Las licencias por socket y por núcleo (Oracle, Microsoft SQL Server, Windows Server BYOL) requieren conocer y controlar la topología física y mantener las instancias afinadas al mismo host. Una Dedicated *Instance* garantiza que las instancias de ninguna otra cuenta de AWS compartan tu hardware, pero no te da visibilidad de sockets/núcleos ni afinidad de host, así que no puede satisfacer la auditoría de licencias.

**R3.6** Una **On-Demand Capacity Reservation** garantiza **capacidad** — reserva capacidad física en una AZ específica para un tipo de instancia específico, y pagás la tarifa On-Demand corras o no instancias en ella. No tiene compromiso de plazo ni descuento. Una **Reserved Instance** o un **Savings Plan** garantizan un **precio** — un descuento en la facturación a cambio de un compromiso de 1 o 3 años — sin garantía de capacidad (la RI *zonal* es la excepción: esa sí conlleva una reserva de capacidad). Los dos son complementarios y se combinan a menudo para capacidad de recuperación ante desastres.

---

### Ejercicio 4 — Elasticidad

**R4.1** **Disponibilidad** (instancias distribuidas en múltiples AZ), **elasticidad/optimización de costos** (la capacidad sigue a la demanda en vez de aprovisionarse para el pico), **tolerancia a fallos / auto-reparación** (las instancias no sanas se reemplazan automáticamente) y **desacople de los clientes respecto de las instancias** (el nombre DNS del ALB es estable mientras las instancias van y vienen). El paso 7 demostró la tercera: terminar una instancia produjo un lanzamiento de reemplazo automático sin intervención humana.

**R4.2** El chequeo de salud `EC2` solo le pregunta al hipervisor si la instancia está *corriendo* y pasando los status checks de EC2. No puede ver que nginx se cayó, que la app devuelve HTTP 500, que un deadlock congeló el bucle de solicitudes, o que se llenó un disco. El chequeo `ELB` usa la sonda a nivel de aplicación del target group (`GET /` acá), así que una falla a nivel de proceso en una VM perfectamente sana se detecta y la instancia se reemplaza. Por eso `health-check-type ELB` más una ruta de chequeo significativa es el estándar de producción — y por eso `--health-check-grace-period` debe superar el tiempo de arranque, o las instancias mueren a mitad del boot en un bucle.

**R4.3**

| Load balancer | Capa | Uso principal |
|---|---|---|
| **Application Load Balancer (ALB)** | Capa 7 (HTTP/HTTPS) | Enrutamiento basado en contenido por host/ruta/encabezado/query, HTTP/2 y gRPC, WebSockets, destinos nativos de EC2 / IP / Lambda / contenedores, terminación TLS, integración con WAF |
| **Network Load Balancer (NLB)** | Capa 4 (TCP/UDP/TLS) | Throughput extremo y latencia ultrabaja, millones de solicitudes por segundo, IP estática por AZ y soporte de Elastic IP, preservación de la IP de origen, protocolos no HTTP |
| **Gateway Load Balancer (GWLB)** | Gateway de capa 3 + capa 4 | Insertar de forma transparente appliances virtuales de terceros (firewalls, IDS/IPS, inspección profunda de paquetes) en el camino del tráfico usando encapsulación GENEVE |

(El Classic Load Balancer es la opción de generación anterior, retenida para cargas de la era EC2-Classic.)

**R4.4** **Amazon EC2 Auto Scaling** escala una sola cosa: la cantidad de instancias EC2 en un Auto Scaling group. **AWS Auto Scaling / Application Auto Scaling** es el servicio más amplio que aplica políticas de escalado a *otros* tipos de recursos. Ejemplos no-EC2: el desired count de un servicio ECS, la capacidad de lectura/escritura de una tabla DynamoDB, la cantidad de Aurora Replicas, la concurrencia aprovisionada de Lambda, las variantes de endpoint de SageMaker, la capacidad de un Spot Fleet. Señal de examen: si la pregunta escala "instancias", es EC2 Auto Scaling; si escala el throughput de una base de datos o el conteo de tareas de un servicio de contenedores, es Application Auto Scaling.

**R4.5**
1. **Target tracking** — "mantener la CPU promedio en 50%". La opción por defecto; nombrás una métrica y un objetivo y AWS calcula la aritmética. (Usada en el paso 4.)
2. **Step scaling** — "agregar 2 instancias si CPU > 60%, agregar 4 más si CPU > 85%". Respuesta graduada atada a la magnitud del incumplimiento de la alarma de CloudWatch.
3. **Simple scaling** — "agregar 1 instancia cuando salta la alarma", y luego esperar un cooldown antes de volver a actuar. La opción heredada; superada por step scaling en casi todos los casos.
4. **Scheduled scaling** — "escalar a 20 instancias a las 08:00 los días hábiles". Para demanda que conocés de antemano por el reloj (apertura de mercado, horario laboral, una ventana batch programada).
   (**Predictive scaling** es un quinto mecanismo: usa machine learning sobre datos históricos de CloudWatch para aprovisionar *por adelantado* de la demanda pronosticada, y típicamente se combina con target tracking como red de seguridad.)

**R4.6** No. El **escalado horizontal** (scaling out/in) cambia el *número* de instancias; el **escalado vertical** (scaling up/down) cambia el *tamaño* de una instancia. Este ejercicio realizó escalado horizontal. El escalado vertical en EC2 requiere un ciclo stop → `modify-instance-attribute --instance-type` → start, lo que implica tiempo de inactividad y un punto único de falla que el escalado horizontal evita — la razón por la que las arquitecturas cloud-native prefieren escalar hacia afuera.

---

### Ejercicio 5 — Contenedores

**R5.1** Corrió en **AWS Fargate** — capacidad de cómputo gestionada por AWS que nunca ves como una instancia en tu cuenta. **AWS parchea** el sistema operativo del host subyacente, el runtime de contenedores y el agente de Fargate; vos seguís siendo responsable de lo que está *adentro* de tu imagen: los paquetes de SO de la imagen base, tu runtime, tus bibliotecas y tu código. Fargate sube el límite del SO en el modelo de responsabilidad compartida, pero no el límite de la imagen.

**R5.2**

| | **ECS** | **EKS** |
|---|---|---|
| **Tipo de lanzamiento EC2** | Vos parcheás el SO de la container instance, vos escalás el ASG, pagás por **hora-instancia EC2** (se llene de tareas o no). El plano de control de ECS es gratis. | Vos parcheás el SO del nodo worker (o usás managed node groups / Karpenter para ayudarte), vos escalás los nodos, pagás por **hora-instancia EC2** *más* el **cargo horario del plano de control de EKS por cluster**. |
| **Tipo de lanzamiento Fargate** | AWS parchea el host; la capacidad aparece por tarea; pagás por **vCPU-segundo y GB-segundo de la tarea**. No hay capacidad ociosa que pagar. | AWS parchea el host; los pods aterrizan sobre capacidad Fargate; pagás por **vCPU/GB del pod** *más* el **cargo horario del plano de control de EKS**. |

El invariante: **la columna del orquestador decide contra qué API escribís; la fila del tipo de lanzamiento decide quién es dueño del sistema operativo y en qué unidad se te factura.**

**R5.3** **Amazon EKS** — corre Kubernetes upstream, conforme a la CNCF, así que los Helm charts, las custom resource definitions, los operadores y los flujos con `kubectl` existentes se transfieren esencialmente sin cambios, y los mismos manifiestos siguen corriendo on-premises. El trade-off es costo y complejidad: EKS cobra una tarifa de plano de control por cluster y por hora (el plano de control de ECS es gratis), y heredás toda la superficie operativa de Kubernetes — actualizaciones de versión, ciclo de vida de add-ons, plomería de CNI y de IAM-a-service-account. ECS es más barato y más simple pero es una API exclusiva de AWS, así que la migración sería una reescritura.

**R5.4** **Amazon ECS** y **Amazon EKS** ambos traen imágenes desde ECR (como también lo hacen **AWS Lambda** para funciones basadas en imágenes de contenedor, **AWS App Runner** y **AWS Batch**). Como ECR almacena imágenes OCI estándar, la mismísima imagen corre en cualquier runtime compatible con OCI — la laptop de un desarrollador con Docker o Podman, un cluster Kubernetes on-premises, u otra nube. **La portabilidad es una propiedad del formato de imagen, no de ECR.**

**R5.5** Los tags inmutables significan que `clf33/hello:1.0.0` nunca puede sobrescribirse para apuntar a bytes distintos. Un despliegue que referencia ese tag es por lo tanto **exactamente reproducible** — rollback, auditoría y forense de incidentes funcionan, y el resultado de un escaneo de vulnerabilidades queda atado al artefacto que escaneó. Con `:latest`, el tag es un puntero móvil: dos instancias lanzadas con una hora de diferencia pueden correr código distinto, un rollback puede "volver atrás" hacia algo nuevo, y un evento de scale-out del ASG introduce silenciosamente una versión no probada en una flota en ejecución. Usá tags inmutables y versionados semánticamente (o digests de contenido) en todo lo que llegue a producción.

**R5.6** **FARGATE** y **FARGATE_SPOT**. `FARGATE` es capacidad serverless bajo demanda sin interrupciones. `FARGATE_SPOT` corre sobre la capacidad sobrante de AWS con un descuento sustancial pero **puede ser reclamada con un aviso SIGTERM de 2 minutos** — apropiado para tareas tolerantes a fallos, sin estado o dirigidas por colas, e inapropiado para cualquier cosa que no pueda morir en pleno vuelo. Una estrategia de capacity providers puede mezclarlos (p. ej. una base de `FARGATE` para el piso siempre encendido más `FARGATE_SPOT` para el remanente elástico).

---

### Ejercicio 6 — Lambda

**R6.1** Memoria máxima **10.240 MB (10 GB)**, timeout máximo **900 segundos (15 minutos)**, concurrencia de cuenta por defecto **1.000 ejecuciones concurrentes por Región** (ajustable mediante solicitud de cuota). La salida también dio los límites del paquete de despliegue: **50 MB comprimido** en carga directa / **250 MB descomprimido** (las imágenes de contenedor llegan a 10 GB). (<https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html>)

**R6.2** El techo duro de 15 minutos de ejecución de Lambda hace imposible una corrida continua de 40 minutos — la invocación se termina a los 900 s sin importar el progreso, y no hay mecanismo de extensión. Opciones que encajan: **AWS Batch** (encolado de trabajos gestionado sobre EC2/Spot/Fargate, construido a propósito para lotes de larga duración), **tareas de Amazon ECS/Fargate** (una tarea no tiene límite de tiempo de ejecución), o **EC2** puro (Spot si el trabajo tiene checkpoints). Una alternativa menos buena pero común es descomponer el trabajo en pasos Lambda de menos de 15 minutos orquestados por **AWS Step Functions** — válida solo si el trabajo es genuinamente particionable.

**R6.3** **Cold start.** El `Init Duration` es Lambda creando un nuevo entorno de ejecución: descargando el código, arrancando el runtime y ejecutando la inicialización a nivel de módulo antes de que corra el handler. Mitigaciones: **Provisioned Concurrency** (mantiene una cantidad determinada de entornos inicializados y calientes, eliminando los cold starts para esa capacidad, con un cargo por los entornos reservados), y **Lambda SnapStart** (toma un snapshot del entorno inicializado y restaura desde él — disponible para los runtimes de Java, Python y .NET). Mitigaciones arquitectónicas: paquetes de despliegue más chicos, mover trabajo pesado fuera de la fase de inicialización, y evitar Lambdas sensibles al cold start en caminos sincrónicos de cara al usuario.

**R6.4** La memoria es la **única** perilla de recursos que Lambda expone; la CPU, el ancho de banda de red y la E/S de disco se asignan **proporcionalmente** a la memoria configurada. No podés comprar CPU de forma independiente. **1.769 MB es el punto en el que una función recibe una vCPU completa**; por debajo la función obtiene una porción proporcional de tiempo de un núcleo, por encima se asignan vCPUs adicionales (hasta 6 vCPUs con 10.240 MB). Esto produce el resultado contraintuitivo pero observado con frecuencia de que subir la memoria *baja* el costo total para funciones intensivas en CPU: la función termina proporcionalmente más rápido, y el precio es en GB-segundos, así que un aumento de memoria de 2× que reduce la duración a la mitad es neutro en costo — y cualquier cosa mejor que eso es ahorro. Notá que *no* ayuda con trabajo limitado por reloj de pared como el busy loop del paso 5, ni con esperas limitadas por E/S.

**R6.5** **Lambda, por aproximadamente tres o cuatro órdenes de magnitud.** Lambda: 40 × 200 ms = 8 segundos de ejecución por día ≈ 240 s/mes, facturados como GB-segundos más 1.200 solicitudes — efectivamente centavos o menos, y cubierto por el free tier perpetuo de Lambda (1M de solicitudes y 400.000 GB-segundos por mes). EC2: hasta la instancia más chica corre 730 horas/mes sin importar los 240 segundos de trabajo real, a varios dólares por mes más el volumen EBS. **Cuando la utilización es un error de redondeo, la facturación por solicitud gana abrumadoramente; el cruce llega cuando la carga se acerca a la utilización continua**, donde EC2 o Fargate con un Savings Plan pasa a ser más barato.

**R6.6** Hay servidores — AWS los posee, los aprovisiona, los parchea, los escala y los asegura, y vos ni los ves ni los gestionás. "Serverless" es una afirmación sobre el **modelo operativo y de facturación**, no sobre la física. Sus propiedades definitorias son: sin aprovisionamiento ni gestión de servidores, escalado automático desde cero hasta el pico dirigido por eventos, pagar solo por lo que consumís sin cargo por capacidad ociosa, y disponibilidad y tolerancia a fallos incorporadas.

---

### Ejercicio 7 — Abstracciones gestionadas

**R7.1** *"¿Necesitás ver, iniciar sesión o ajustar las instancias EC2, la VPC y el load balancer subyacentes?"* Si la respuesta es **sí** → **Elastic Beanstalk**: aprovisiona recursos estándar de EC2, ASG, ELB y CloudWatch **dentro de tu cuenta**, donde podés entrar por SSH, modificar la configuración vía `.ebextensions` y tomar el control de cualquier componente. Si es **no** → **App Runner**: oculta toda la infraestructura por completo, exponiendo solo una configuración de servicio y una URL HTTPS, con escalado automático casi hasta cero y sin VPC que diseñar. Discriminador secundario: App Runner está orientado a contenedores/código fuente y tiene forma de solicitud web; Beanstalk soporta un conjunto más amplio de plataformas, incluidos entornos worker que consumen SQS.

**R7.2** **Amazon Lightsail.** Está diseñado exactamente para esto: un precio mensual fijo por paquete que cubre cómputo, SSD, IP estática y una generosa cuota de transferencia de datos, una consola simplificada y blueprints de WordPress de un clic. A qué renuncian: control fino (tipos de instancia limitados, funcionalidades de VPC restringidas — Lightsail vive en una VPC separada que debe emparejarse para alcanzar una VPC estándar), la amplitud completa de integraciones de AWS, y la elasticidad — Lightsail no autoescala, así que un pico de tráfico significa un redimensionamiento manual o una caída. Sin embargo, la salida de emergencia es real: una instancia Lightsail puede exportarse a una AMI de EC2 cuando la carga la supera.

**R7.3** (1) **Compute environment** — el pool que provee capacidad, respaldado por EC2 On-Demand, EC2 Spot o Fargate, con un rango mínimo/máximo de vCPU. (2) **Job queue** — un área de espera ordenada y priorizada para los trabajos enviados, vinculada a uno o más compute environments. (3) **Job definition** — la plantilla reutilizable que describe la imagen de contenedor, vCPU/memoria, rol IAM, estrategia de reintentos y entorno. "Escala a cero" significa que cuando la cola está vacía, Batch termina las instancias del compute environment y **el cargo de cómputo va a cero**; pagás solo por los minutos durante los cuales los trabajos están efectivamente corriendo. Combinado con un compute environment Spot, esta es la forma más barata de correr grandes cargas de lotes intermitentes en AWS.

**R7.4** **AWS Outposts.** Coloca racks propiedad de AWS y gestionados por AWS físicamente dentro del propio data center del cliente, corriendo las mismas APIs de EC2, EBS, ECS, EKS y S3 on Outposts que una Región, conectados de vuelta a una Región padre. Es la única opción que satisface "cómputo físicamente dentro de nuestro edificio". Una **Local Zone** es la respuesta equivocada porque una Local Zone es infraestructura propiedad de AWS en una **instalación metropolitana de AWS** — cerca del hospital, quizás en la misma ciudad, pero no en el predio del hospital. Las Local Zones resuelven *latencia*; Outposts resuelve *ubicación física y residencia de datos*.

**R7.5** Las Local Zones, las Wavelength Zones y la mayoría de las Regiones que no son la de origen son **opt-in**: tenés que habilitar explícitamente un grupo de zonas antes de poder lanzar recursos ahí. Es un valor por defecto de seguridad deliberado — impide que un ASG, un Spot fleet o una automatización mal configurada coloquen silenciosamente cargas (y sus datos) en una geografía que nunca pretendiste, lo que importa tanto por costo como por cumplimiento de residencia de datos. La colocación por defecto se mantiene dentro de las Availability Zones estándar de la Región que seleccionaste.

**R7.6** De mayor control → menor control:
1. **EC2** — root completo sobre el SO; elegís la AMI, la parcheás y configurás todo.
2. **Lightsail** — una VM real con acceso root, pero una configuración restringida y preempaquetada y networking limitado.
3. **Elastic Beanstalk** — AWS aprovisiona y gestiona la plataforma, pero las instancias EC2 son tuyas para inspeccionar, acceder por SSH y personalizar.
4. **Fargate** — sos dueño de la imagen de contenedor (sus paquetes y runtime); no tenés ningún acceso al SO del host.
5. **Lambda** — solo aportás una función (o una imagen); AWS es dueño de todo el entorno de ejecución y de su ciclo de vida.

*(App Runner se ubica entre Fargate y Lambda: aportás un contenedor o código fuente, y AWS gestiona el build, el host, el escalado, el balanceo de carga y el TLS.)*

---

### Ejercicio 8 — Síntesis

**R8.1**

| # | Servicio + modo | Razonamiento | Capa más alta que gestiona AWS |
|---|---|---|---|
| **S1** | **AWS Lambda**, event source mapping desde S3 | Dirigido por eventos, de corta duración, a ráfagas y con picos, ocioso la mayor parte del tiempo — el perfil serverless canónico. La facturación por solicitud hace que el ocio sea gratis. | El runtime y todo lo que está debajo |
| **S2** | **EC2 sobre un Dedicated Host**, **Standard RI** a 3 años o EC2 Instance Savings Plan | El licenciamiento por núcleo físico necesita visibilidad de sockets/núcleos y afinidad de host (solo los Dedicated Hosts la proveen); un ERP Windows heredado necesita control total del SO; 24×7 por 3+ años justifica el descuento por compromiso más profundo. | Solo hardware/hipervisor |
| **S3** | **AWS Batch** con un compute environment de **EC2 Spot** | Miles de trabajos independientes, con checkpoints y reiniciables, con el costo como prioridad y una fecha límite — Batch se encarga del encolado y del escalado a cero, Spot aporta ~70–90% de ahorro, y la reiniciabilidad satisface el contrato de interrupción de Spot. | SO y orquestación (Batch gestiona las instancias) |
| **S4** | **Amazon EKS** (managed node groups o Fargate) | La conformidad con Kubernetes upstream es el requisito; los Helm charts y las CRDs se transfieren sin cambios. | Plano de control de Kubernetes (+ SO del host si es sobre Fargate) |
| **S5** | **AWS Elastic Beanstalk** | Despliegues por git push y cero trabajo de infraestructura, **pero** la necesidad explícita de entrar por SSH a los servidores descarta Fargate/App Runner/Lambda. Beanstalk deja instancias EC2 reales en la cuenta. | Plataforma/runtime; las instancias siguen siendo visibles para el cliente |
| **S6** | **Amazon ECS sobre AWS Fargate**, detrás de un ALB | Contenerizado, sin habilidades de Kubernetes (así que ECS antes que EKS, y sin cargo de plano de control de EKS), cero gestión de instancias (así que Fargate antes que el tipo de lanzamiento EC2), 24×7 con un load balancer. | SO del host y por debajo |
| **S7** | **AWS Wavelength** | Menos de 10 ms hacia dispositivos en una red 5G de operador requiere cómputo dentro de la red del operador para que el tráfico nunca atraviese internet público. Una Local Zone no está lo bastante cerca; una Región está demasiado lejos. | Hardware/hipervisor (semántica de EC2 en el borde) |
| **S8** | **EC2 optimizada para memoria** (`r`/`x`/High Memory) con un **EC2 Instance Savings Plan** de 1 año | 1 TiB de RAM exige una familia optimizada para memoria; la carga estable 24×7 más la disposición a quedarse en una familia hacen del EC2 Instance Savings Plan el ajuste de mayor descuento (un Compute SP cambiaría algo de descuento por una flexibilidad que dijeron no necesitar). | Solo hardware/hipervisor |
| **S9** | **Amazon Lightsail** | El precio mensual fijo y predecible está enunciado como el requisito; no hace falta elasticidad; la transferencia incluida evita sorpresas en la factura. | Hardware/hipervisor, con un plano de gestión simplificado |
| **S10** | **AWS Batch** con un compute environment de **EC2 Spot** habilitado para GPU | "Encolado de trabajos en vez de gestión de clusters" es la señal explícita de Batch; reiniciable + nocturno + 6 horas es un perfil Spot de manual; las instancias GPU (familias `p`/`g`) aportan los aceleradores. | SO y orquestación |

**R8.2**
- **Lambda para S3** — los trabajos de 20 minutos exceden el techo duro de **900 segundos** de Lambda. Descalificado por duración de ejecución.
- **EC2 On-Demand para S8** — no está *mal*, solo es derrochador: una carga estable 24×7 con un compromiso de 1 año aceptado deja aproximadamente entre 40 y 72% sobre la mesa al no tomar un Savings Plan o una RI. Descalificado por optimización de costos.
- **Fargate para S2** — Fargate no da acceso al host, ni visibilidad de sockets/núcleos, ni afinidad de host, así que el licenciamiento BYOL por núcleo físico no puede satisfacerse; además no corre un ERP de Windows de 15 años que espera control total del SO. Descalificado por licenciamiento y control del SO.
- **Spot para una base de datos de producción con estado** — la capacidad Spot puede ser reclamada con solo un aviso de 2 minutos en cualquier momento. Una base de datos primaria con estado no puede tolerar una terminación arbitraria sin arriesgar pérdida de datos o un incidente de disponibilidad. Descalificado por tolerancia a interrupciones.

**R8.3** **Preguntá quién debe ser dueño del sistema operativo, y cuánto dura una única unidad de trabajo.** Si necesitás control del SO (licenciamiento, módulos de kernel, software heredado, hardware especializado) → **EC2**. Si la app ya está contenerizada y querés portabilidad y planificación sin ser dueño de instancias → **ECS/EKS sobre Fargate**. Si el trabajo es dirigido por eventos, sin estado, y se completa en menos de 15 minutos → **Lambda**. Después superponé el modelo de costos: estable y predecible → Savings Plan o RI; interrumpible → Spot; con picos e impredecible → On-Demand o serverless por solicitud.

</details>

---

## Fuentes oficiales

- **Guía del examen CLF-C02** — <https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf>
- Amazon EC2 User Guide — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html>
- Nomenclatura de tipos de instancia EC2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-names.html>
- Opciones de compra de instancias EC2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html>
- Spot Instances — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html>
- Servicio de metadatos de instancia (IMDSv2) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- Instancias de rendimiento burstable — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>
- AWS Savings Plans — <https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html>
- Amazon EC2 Auto Scaling — <https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html>
- Elastic Load Balancing — <https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html>
- Amazon ECS — <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html>
- AWS Fargate — <https://docs.aws.amazon.com/AmazonECS/latest/userguide/what-is-fargate.html>
- Amazon EKS — <https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html>
- Amazon ECR — <https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html>
- AWS Lambda — <https://docs.aws.amazon.com/lambda/latest/dg/welcome.html>
- Cuotas de Lambda — <https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html>
- AWS Batch — <https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html>
- AWS Elastic Beanstalk — <https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html>
- Amazon Lightsail — <https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html>
- AWS App Runner — <https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html>
- AWS Outposts — <https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html>
- AWS Local Zones — <https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html>
- AWS Wavelength — <https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html>