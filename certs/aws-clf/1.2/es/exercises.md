# Tema 1.2 — Identificar los principios de diseño de la nube de AWS

## Ejercicios guiados (CLF-C02, Dominio 1, peso 6.0)

Estos ejercicios convierten las cuatro habilidades que la guía del examen nombra para la Declaración de tarea 1.2 — **diseñar para el fallo**, **desacoplar componentes frente a la arquitectura monolítica**, **implementar elasticidad** y **pensar en paralelo** — más el **AWS Well-Architected Framework** en cosas que podés observar desde una terminal. Cada principio de abajo se verifica contra una respuesta de la API, una actividad de escalado, una profundidad de cola o un cronómetro, no contra una diapositiva.

### Requisitos previos

| Requisito | Comprobación |
|---|---|
| AWS CLI v2 | `aws --version` → `aws-cli/2.x.x …` |
| Una cuenta en la que puedas crear y eliminar recursos | `aws sts get-caller-identity` |
| `jq` (opcional, varios pasos muestran una alternativa con `--query`) | `jq --version` |
| Una región con al menos 2 zonas de disponibilidad y una VPC predeterminada | El ejercicio 0 lo verifica |
| Permisos | `wellarchitected:*`, `ec2:*`, `autoscaling:*`, `sqs:*`, `s3:*`, `cloudformation:*`, `cloudwatch:*`, `fis:List*`, `servicequotas:Get*` |

### Límites de protección de costos

| Ejercicio | Recursos facturables | Orden de magnitud |
|---|---|---|
| 1, 8 — Well-Architected Tool | ninguno | **$0.00** (la herramienta es gratuita) |
| 2 — Service Quotas | ninguno | $0.00 |
| 3 — Grupo de Auto Scaling | 2–4 × `t3.micro` durante ~20 min, 2 alarmas de CloudWatch | < **$0.05** |
| 4 — SQS | ~50 solicitudes a la API | $0.00 (1 M de solicitudes/mes siempre gratis) |
| 5 — Paralelismo en S3 | ~600 PUT, ~600 MB almacenados durante minutos | < **$0.02** |
| 6 — CloudFormation | ninguno para los tipos de recursos nativos de AWS | $0.00 |
| 7 — FIS (listado de solo lectura) | ninguno | $0.00 |

> **Ejecutá el paso de desmontaje de cada ejercicio.** Un grupo de Auto Scaling olvidado con `MinSize=2` factura para siempre; la lista de verificación de desmontaje final es la red de seguridad.

---

## Ejercicio 0 — Comprobación del entorno y del radio de impacto

### Pasos

1. Confirmá en qué identidad y cuenta estás por gastar dinero:

   ```bash
   aws sts get-caller-identity
   ```

   ```json
   {
       "UserId": "AIDAEXAMPLEEXAMPLE",
       "Account": "123456789012",
       "Arn": "arn:aws:iam::123456789012:user/clf-student"
   }
   ```

2. Fijá una región para todo el laboratorio. Todos los comandos de abajo la heredan:

   ```bash
   export AWS_REGION=us-east-1
   export AWS_DEFAULT_REGION=$AWS_REGION
   aws configure get region
   ```

3. Enumerá las zonas de disponibilidad de esa región — el sustrato físico sobre el que se apoya el "diseñar para el fallo":

   ```bash
   aws ec2 describe-availability-zones \
     --query 'AvailabilityZones[].{AZ:ZoneName,Id:ZoneId,State:State}' \
     --output table
   ```

   ```
   ------------------------------------------
   |       DescribeAvailabilityZones        |
   +-------------+--------------+-----------+
   |     AZ      |     Id       |   State   |
   +-------------+--------------+-----------+
   |  us-east-1a |  use1-az4    |  available|
   |  us-east-1b |  use1-az6    |  available|
   |  us-east-1c |  use1-az1    |  available|
   |  us-east-1d |  use1-az2    |  available|
   |  us-east-1e |  use1-az3    |  available|
   |  us-east-1f |  use1-az5    |  available|
   +-------------+--------------+-----------+
   ```

4. Confirmá que existe una VPC predeterminada y capturá sus subredes, una por AZ:

   ```bash
   aws ec2 describe-subnets \
     --filters Name=default-for-az,Values=true \
     --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock}' \
     --output table
   ```

   Si esto devuelve una lista vacía, creá una con `aws ec2 create-default-vpc` o sustituí por tus propios IDs de subred en el ejercicio 3.

### Verificá tu comprensión

- **Q0.1** — La columna `AZ` (`us-east-1a`) y la columna `Id` (`use1-az4`) difieren. ¿Por qué AWS publica ambas, y cuál es estable entre dos cuentas de AWS distintas?
- **Q0.2** — Una carga de trabajo se ejecuta enteramente en `us-east-1a`. ¿Qué pilar de Well-Architected viola primero, y cuál de las cuatro habilidades de la Tarea 1.2 incumple?
- **Q0.3** — Las regiones y las zonas de disponibilidad son infraestructura, no principios de diseño. Explicá en una oración por qué la *existencia* de múltiples AZ no es por sí misma alta disponibilidad.

---

## Ejercicio 1 — Enumerar los seis pilares desde la fuente de verdad

El Well-Architected Framework no es solo prosa: la **AWS Well-Architected Tool** expone la misma lente como una API consultable. Leer los pilares desde la API es la diferencia entre memorizar una lista y saber de dónde viene la lista.

### Pasos

1. Listá las lentes disponibles para tu cuenta. `wellarchitected` es el alias de la lente del framework central:

   ```bash
   aws wellarchitected list-lenses \
     --query 'LensSummaries[].{Alias:LensAlias,Name:LensName,Type:LensType,Version:LensVersion}' \
     --output table
   ```

   ```
   ----------------------------------------------------------------------------------------
   |                                      ListLenses                                      |
   +-------------------+------------------------------------+---------------+-------------+
   |       Alias       |               Name                 |     Type      |  Version    |
   +-------------------+------------------------------------+---------------+-------------+
   |  wellarchitected  |  AWS Well-Architected Framework    |  AWS_OFFICIAL |  2026-xx-xx |
   |  serverless       |  Serverless Applications Lens      |  AWS_OFFICIAL |  2026-xx-xx |
   |  softwareasaservice| SaaS Lens                         |  AWS_OFFICIAL |  2026-xx-xx |
   +-------------------+------------------------------------+---------------+-------------+
   ```

   (Salida abreviada — el catálogo de lentes crece con el tiempo.)

2. Creá una carga de trabajo descartable. Este es el objeto al que se adjunta una revisión; no cuesta nada:

   ```bash
   WL_ID=$(aws wellarchitected create-workload \
     --workload-name "clf-1-2-lab" \
     --description "Sandbox workload used to enumerate WAF pillars and questions" \
     --environment PREPRODUCTION \
     --aws-regions "$AWS_REGION" \
     --lenses wellarchitected \
     --review-owner "student@example.com" \
     --client-request-token "clf-1-2-lab-0001" \
     --query WorkloadId --output text)

   echo "Workload: $WL_ID"
   ```

   ```
   Workload: 8f2a1c0b4d5e6f708192a3b4c5d6e7f8
   ```

   > `--client-request-token` es la clave de idempotencia. Volver a ejecutar el comando con el mismo token devuelve la misma carga de trabajo en lugar de crear una segunda — la expresión a nivel de API de "automatizar para facilitar la experimentación arquitectónica".

3. Preguntale a la API cuántos pilares tiene el framework, en vez de confiar en tu memoria:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'AnswerSummaries[].PillarId' --output text \
     | tr '\t' '\n' | sort -u
   ```

   ```
   costOptimization
   operationalExcellence
   performance
   reliability
   security
   sustainability
   ```

   Seis líneas, exactamente. Los IDs de cadena son un detalle de implementación de la API — **el examen evalúa los nombres de los pilares, no estos identificadores**: Excelencia operativa, Seguridad, Fiabilidad, Eficiencia del rendimiento, Optimización de costos, Sostenibilidad.

4. Contá las preguntas por pilar. Los números absolutos cambian entre versiones de la lente; la forma no:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'AnswerSummaries[].PillarId' --output text \
     | tr '\t' '\n' | sort | uniq -c | sort -rn
   ```

5. Leé las preguntas del pilar de Fiabilidad — acá es donde vive "diseñar para el fallo", planteado como preguntas que un arquitecto debe responder:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --pillar-id reliability \
     --query 'AnswerSummaries[].QuestionTitle' --output text \
     | tr '\t' '\n' | nl
   ```

   ```
        1  How do you manage service quotas and constraints?
        2  How do you plan your network topology?
        3  How do you design your workload service architecture?
        4  How do you design interactions in a distributed system to prevent failures?
        5  How do you design interactions in a distributed system to mitigate or withstand failures?
        6  How do you monitor workload resources?
        7  How do you design your workload to adapt to changes in demand?
        8  How do you implement change?
        9  How do you back up data?
       10  How do you use fault isolation to protect your workload?
       11  How do you design your workload to withstand component failures?
       12  How do you test reliability?
       13  How do you plan for disaster recovery (DR)?
   ```

6. Hacé lo mismo con Sostenibilidad, el pilar añadido más recientemente y el que los candidatos más suelen olvidar:

   ```bash
   aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --pillar-id sustainability \
     --query 'AnswerSummaries[].QuestionTitle' --output text \
     | tr '\t' '\n' | nl
   ```

7. Conservá `$WL_ID` para el ejercicio 8, o eliminalo ahora y volvé a crearlo más tarde:

   ```bash
   # Teardown (optional here — Exercise 8 reuses the workload)
   aws wellarchitected delete-workload \
     --workload-id "$WL_ID" \
     --client-request-token "clf-1-2-del-0001"
   ```

### Verificá tu comprensión

- **Q1.1** — Nombrá los seis pilares en el orden en que AWS los documenta, y dá la preocupación de cada uno en una línea.
- **Q1.2** — La pregunta 7 de Fiabilidad es *"How do you design your workload to adapt to changes in demand?"* — el mismo tema que la elasticidad, que suena a Eficiencia del rendimiento y también a Optimización de costos. ¿Por qué aparece la misma capacidad bajo tres pilares, y qué te dice eso sobre cómo debe usarse el framework?
- **Q1.3** — El paso 2 creó una carga de trabajo pero nunca describiste ni un solo recurso. ¿Qué revela eso sobre lo que la Well-Architected Tool realmente mide?
- **Q1.4** — ¿Qué pilar es dueño de *"How do you use fault isolation to protect your workload?"*, y qué habilidad de la Tarea 1.2 implementa el aislamiento de fallos?
- **Q1.5** — Tu cuenta puede mostrar lentes más allá de `wellarchitected`. ¿Qué es una *lente*, y por qué no es un séptimo pilar?

---

## Ejercicio 2 — Los seis principios generales de diseño, y uno que podés medir

Por encima de los pilares, el framework enuncia seis **principios generales de diseño**. Cinco de ellos son culturales; uno de ellos — *dejá de adivinar tus necesidades de capacidad* — tiene un límite duro y consultable en AWS: **las cuotas de servicio**. La nube elimina tu conjetura de capacidad *física* y la reemplaza por un límite de *cuenta* que podés ver y elevar.

### Pasos

1. Anotá los seis principios generales de diseño del framework antes de ejecutar nada (la clave de respuestas está al final):

   ```
   1. Stop guessing your capacity needs
   2. Test systems at production scale
   3. Automate to make architectural experimentation easier
   4. Allow for evolutionary architectures
   5. Drive architectures using data
   6. Improve through game days
   ```

2. Consultá el techo concreto detrás del principio 1 — la cuota de vCPU de instancias Standard bajo demanda de la cuenta:

   ```bash
   aws service-quotas get-service-quota \
     --service-code ec2 \
     --quota-code L-1216C47A \
     --query 'Quota.{Name:QuotaName,Value:Value,Adjustable:Adjustable,Unit:Unit}' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------------------------------------
   |                                        GetServiceQuota                                          |
   +------------+-------------------------------------------------------------+----------+----------+
   | Adjustable |                            Name                             |   Unit   |  Value   |
   +------------+-------------------------------------------------------------+----------+----------+
   |  True      |  Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) …    |  None    |  5.0     |
   +------------+-------------------------------------------------------------+----------+----------+
   ```

   Una cuenta recién creada suele mostrar un valor pequeño (a menudo `5.0` vCPU). **Adjustable: True** es el punto: el techo es un atributo de la cuenta, no una orden de compra.

3. Mirá la superficie de cuotas circundante de un servicio para ver cuánto de la "capacidad" es ahora una cuestión del plano de datos:

   ```bash
   aws service-quotas list-service-quotas --service-code ec2 \
     --query 'Quotas[?Adjustable==`true`].QuotaName' --output text \
     | tr '\t' '\n' | head -20
   ```

4. Comparalo con un servicio que efectivamente no tiene techo de capacidad contra el cual planificar:

   ```bash
   aws service-quotas list-service-quotas --service-code sqs \
     --query 'Quotas[].{Name:QuotaName,Value:Value,Adjustable:Adjustable}' \
     --output table
   ```

5. Completá esta tabla de correspondencias en tus notas. Cada principio general debe emparejarse con la capacidad de AWS que lo hace *posible* — no meramente deseable:

   | Principio general de diseño | Capacidad que lo hace posible | Verificado en el ejercicio |
   |---|---|---|
   | Stop guessing your capacity needs | | |
   | Test systems at production scale | | |
   | Automate to make architectural experimentation easier | | |
   | Allow for evolutionary architectures | | |
   | Drive architectures using data | | |
   | Improve through game days | | |

### Verificá tu comprensión

- **Q2.1** — "Stop guessing your capacity needs" se resume a menudo como *"la nube es infinita"*. Usando la salida del paso 2, indicá con precisión por qué ese resumen es incorrecto y cuál es el enunciado correcto.
- **Q2.2** — En las instalaciones propias, "test systems at production scale" suele rechazarse por motivos de costo. ¿Qué propiedad específica de la facturación en la nube elimina esa objeción, y qué harías inmediatamente después de la prueba?
- **Q2.3** — Los principios 3 y 4 ("automate to make experimentation easier" y "allow for evolutionary architectures") están vinculados causalmente. ¿Cuál habilita al otro, y por qué el orden inverso es imposible?
- **Q2.4** — ¿Cuál de los seis principios generales *no* trata de arquitectura en absoluto, sino de práctica organizacional? ¿Qué pilar lo refuerza más directamente?

---

## Ejercicio 3 — Diseñar para el fallo e implementar elasticidad en un solo grupo de Auto Scaling

Un grupo de Auto Scaling es el artefacto más pequeño que demuestra tres habilidades del examen a la vez: **diseñar para el fallo** (reemplaza instancias muertas), **implementar elasticidad** (cambia la capacidad con la demanda) y **guiar las arquitecturas con datos** (el seguimiento de objetivos crea las alarmas de CloudWatch que deciden).

> **Costo**: 2–4 instancias `t3.micro` durante la duración del ejercicio. No te vayas antes del paso 10.

### Pasos

1. Resolvé la AMI actual de Amazon Linux 2023 para tu región desde el parámetro público de SSM — nunca codifiques a mano un ID de AMI, es específico de la región y cambia con cada parche:

   ```bash
   AMI=$(aws ssm get-parameters \
     --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query 'Parameters[0].Value' --output text)
   echo "$AMI"
   ```

   ```
   ami-0abcdef1234567890
   ```

2. Recolectá las subredes predeterminadas como una lista separada por comas — una por AZ, que es lo que hace al grupo multi-AZ:

   ```bash
   SUBNETS=$(aws ec2 describe-subnets \
     --filters Name=default-for-az,Values=true \
     --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
   echo "$SUBNETS"
   ```

   ```
   subnet-0aa1,subnet-0bb2,subnet-0cc3,subnet-0dd4,subnet-0ee5,subnet-0ff6
   ```

3. Creá una plantilla de lanzamiento — la descripción inmutable y versionada de *qué* lanzar. Esta separación entre "qué ejecutar" y "cuántos ejecutar" es el núcleo mecánico de la elasticidad:

   ```bash
   aws ec2 create-launch-template \
     --launch-template-name clf-1-2-lt \
     --version-description v1 \
     --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\"}" \
     --query 'LaunchTemplate.{Name:LaunchTemplateName,Id:LaunchTemplateId,Version:LatestVersionNumber}' \
     --output table
   ```

   Si `t3.micro` no está disponible en tu región, sustituí por `t2.micro`.

4. Creá el grupo de Auto Scaling a través de todas las AZ:

   ```bash
   aws autoscaling create-auto-scaling-group \
     --auto-scaling-group-name clf-1-2-asg \
     --launch-template LaunchTemplateName=clf-1-2-lt,Version='$Latest' \
     --min-size 2 --max-size 4 --desired-capacity 2 \
     --health-check-type EC2 --health-check-grace-period 60 \
     --vpc-zone-identifier "$SUBNETS"
   ```

   Sin salida significa éxito.

5. Esperá ~60 segundos, después observá dónde aterrizó la capacidad:

   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names clf-1-2-asg \
     --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,State:LifecycleState,Health:HealthStatus}' \
     --output table
   ```

   ```
   ---------------------------------------------------------------------
   |                    DescribeAutoScalingGroups                      |
   +--------------+-----------------------+-----------+----------------+
   |      AZ      |         Id            |  Health   |     State      |
   +--------------+-----------------------+-----------+----------------+
   |  us-east-1a  |  i-0123456789abcdef0  |  Healthy  |  InService     |
   |  us-east-1d  |  i-0fedcba9876543210  |  Healthy  |  InService     |
   +--------------+-----------------------+-----------+----------------+
   ```

   Dos instancias, dos AZ diferentes. Nunca pediste esa ubicación — pediste `--desired-capacity 2` a través de seis subredes.

6. **Diseñar para el fallo — rompelo a propósito.** Terminá una instancia a espaldas del grupo, del modo en que lo haría una falla de hardware:

   ```bash
   VICTIM=$(aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names clf-1-2-asg \
     --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
   echo "Killing $VICTIM"
   aws ec2 terminate-instances --instance-ids "$VICTIM" \
     --query 'TerminatingInstances[].{Id:InstanceId,From:PreviousState.Name,To:CurrentState.Name}' \
     --output table
   ```

7. Sondeá el grupo hasta que se recupere, después leé *por qué* actuó:

   ```bash
   for i in $(seq 1 12); do
     aws autoscaling describe-auto-scaling-groups \
       --auto-scaling-group-names clf-1-2-asg \
       --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,HealthStatus]' \
       --output text
     echo "---"; sleep 20
   done
   ```

   ```
   i-0fedcba9876543210	InService	Healthy
   ---
   i-0fedcba9876543210	InService	Healthy
   i-0aabbccddeeff0011	Pending	Healthy
   ---
   i-0fedcba9876543210	InService	Healthy
   i-0aabbccddeeff0011	InService	Healthy
   ---
   ```

8. Leé el rastro de auditoría — Auto Scaling registra la causa de cada cambio de capacidad:

   ```bash
   aws autoscaling describe-scaling-activities \
     --auto-scaling-group-name clf-1-2-asg \
     --max-items 4 \
     --query 'Activities[].{Status:StatusCode,Description:Description,Cause:Cause}' \
     --output json
   ```

   ```json
   [
     {
       "Status": "Successful",
       "Description": "Launching a new EC2 instance: i-0aabbccddeeff0011",
       "Cause": "At 2026-09-03T14:22:31Z an instance was taken out of service in response to a system health-check failure."
     },
     {
       "Status": "Successful",
       "Description": "Terminating EC2 instance: i-0123456789abcdef0",
       "Cause": "At 2026-09-03T14:21:58Z an instance was taken out of service in response to a system health-check failure."
     }
   ]
   ```

   (Las marcas de tiempo y los IDs van a diferir; la redacción de `Cause` es representativa.)

9. **Implementar elasticidad — de dos maneras.** Primero manualmente, después por datos. Manual:

   ```bash
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name clf-1-2-asg --desired-capacity 4
   ```

   Después reemplazá al humano por una métrica. Una política de **seguimiento de objetivos** (target tracking) enuncia un *resultado* ("mantené la CPU promedio al 50%"), no un procedimiento:

   ```bash
   aws autoscaling put-scaling-policy \
     --auto-scaling-group-name clf-1-2-asg \
     --policy-name cpu-target-50 \
     --policy-type TargetTrackingScaling \
     --target-tracking-configuration '{
       "PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageCPUUtilization"},
       "TargetValue": 50.0
     }' \
     --query '{Arn:PolicyARN,Alarms:Alarms[].AlarmName}' --output json
   ```

   ```json
   {
     "Arn": "arn:aws:autoscaling:us-east-1:123456789012:scalingPolicy:...:policyName/cpu-target-50",
     "Alarms": [
       {"AlarmName": "TargetTracking-clf-1-2-asg-AlarmHigh-1a2b3c4d-..."},
       {"AlarmName": "TargetTracking-clf-1-2-asg-AlarmLow-5e6f7a8b-..."}
     ]
   }
   ```

10. Inspeccioná las alarmas que la política creó por vos — esto es "guiar las arquitecturas con datos" hecho concreto:

    ```bash
    aws cloudwatch describe-alarms \
      --alarm-name-prefix "TargetTracking-clf-1-2-asg" \
      --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Stat:Statistic,Threshold:Threshold,Op:ComparisonOperator,Periods:EvaluationPeriods}' \
      --output table
    ```

11. **Desmontaje — no lo saltees:**

    ```bash
    aws autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name clf-1-2-asg --force-delete
    sleep 60
    aws ec2 delete-launch-template --launch-template-name clf-1-2-lt
    aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names clf-1-2-asg \
      --query 'AutoScalingGroups' --output text   # expect empty
    ```

### Verificá tu comprensión

- **Q3.1** — El paso 5 produjo instancias en dos AZ diferentes sin que vos especificaras AZ. ¿Qué principio de diseño implementa esa ubicación, y qué propiedad de la configuración del grupo la causó?
- **Q3.2** — En el paso 6 terminaste la instancia vos mismo, y sin embargo el `Cause` del paso 8 habla de un fallo de comprobación de estado. ¿A qué reacciona realmente el grupo de Auto Scaling, y por qué importa esa distinción para "diseñar para el fallo"?
- **Q3.3** — El grupo tiene `MinSize=2`. Explicá la consecuencia de costo y la consecuencia de disponibilidad de fijar `MinSize=1` en su lugar, e indicá a qué pilar pertenece cada consecuencia.
- **Q3.4** — El paso 9 ofrece `set-desired-capacity` manual y una política de seguimiento de objetivos. Ambas cambian la capacidad. ¿Cuál es *elasticidad* según la definición del examen, y por qué la otra no lo es?
- **Q3.5** — La política de seguimiento de objetivos creó **dos** alarmas, alta y baja. ¿Por qué una política que solo escala hacia afuera sería un antipatrón, y qué pilar objeta más fuerte?
- **Q3.6** — El escalado está acotado por `MaxSize=4`. Conectá esto con la cuota de servicio que leíste en el ejercicio 2 — ¿cuáles son los dos techos independientes sobre hasta dónde puede escalar esta carga de trabajo?

---

## Ejercicio 4 — Desacoplamiento: probar que la cola absorbe el fallo

El acoplamiento monolítico significa "el llamador espera al llamado, y muere con él". Una cola convierte una dependencia sincrónica en una asincrónica, de modo que un consumidor muerto se vuelve un *backlog* en lugar de una *caída*. Este ejercicio hace visible el fallo y el backlog en números.

### Pasos

1. Creá la cola de trabajo y su cola de mensajes fallidos (dead-letter queue):

   ```bash
   QURL=$(aws sqs create-queue --queue-name clf-1-2-orders \
     --attributes VisibilityTimeout=30,MessageRetentionPeriod=345600 \
     --query QueueUrl --output text)

   DLQ_URL=$(aws sqs create-queue --queue-name clf-1-2-orders-dlq \
     --query QueueUrl --output text)

   echo "main: $QURL"; echo "dlq : $DLQ_URL"
   ```

   `MessageRetentionPeriod=345600` son 4 días — el valor predeterminado de SQS. El máximo es `1209600` (14 días).

2. Conectá la DLQ a la cola principal con una política de redrive. Tres recepciones fallidas y el mensaje queda en cuarentena en lugar de envenenar al consumidor para siempre:

   ```bash
   DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
     --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

   cat > /tmp/redrive.json <<EOF
   {"RedrivePolicy":"{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"}
   EOF

   aws sqs set-queue-attributes --queue-url "$QURL" --attributes file:///tmp/redrive.json
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names RedrivePolicy VisibilityTimeout MessageRetentionPeriod \
     --query Attributes --output json
   ```

   ```json
   {
     "VisibilityTimeout": "30",
     "MessageRetentionPeriod": "345600",
     "RedrivePolicy": "{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:123456789012:clf-1-2-orders-dlq\",\"maxReceiveCount\":\"3\"}"
   }
   ```

3. **Simulá que el consumidor está completamente caído** — no inicies ninguno. Producí diez órdenes de todos modos:

   ```bash
   for i in $(seq 1 10); do
     aws sqs send-message --queue-url "$QURL" \
       --message-body "{\"order\":$i,\"sku\":\"SKU-$((RANDOM % 100))\"}" \
       --query MessageId --output text
   done
   ```

   ```
   4a7d3f21-...-9b0c
   9c1e8b40-...-2d17
   … (10 IDs)
   ```

   Cada llamada del productor tuvo éxito mientras la capa aguas abajo no existía. **Eso es desacoplamiento, medido.**

4. Leé el backlog:

   ```bash
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages \
                       ApproximateNumberOfMessagesNotVisible \
                       ApproximateNumberOfMessagesDelayed \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "10",
     "ApproximateNumberOfMessagesNotVisible": "0",
     "ApproximateNumberOfMessagesDelayed": "0"
   }
   ```

5. **Traé de vuelta al consumidor.** Hacé long polling por un lote:

   ```bash
   aws sqs receive-message --queue-url "$QURL" \
     --max-number-of-messages 5 --wait-time-seconds 10 \
     --query 'Messages[].{Body:Body,Handle:ReceiptHandle}' --output json > /tmp/batch.json
   jq -r '.[].Body' /tmp/batch.json
   ```

   ```
   {"order":1,"sku":"SKU-42"}
   {"order":3,"sku":"SKU-7"}
   {"order":2,"sku":"SKU-88"}
   …
   ```

   Notá que el orden no es estrictamente 1,2,3 — una cola estándar garantiza un ordenamiento de mejor esfuerzo, no FIFO.

6. Releé inmediatamente los contadores mientras el tiempo de espera de visibilidad todavía está corriendo:

   ```bash
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "5",
     "ApproximateNumberOfMessagesNotVisible": "5"
   }
   ```

   Cinco en vuelo, cinco esperando. Nada se perdió, y nada se le entregó a un segundo consumidor.

7. **Simulá que el consumidor se cae a mitad del procesamiento** — *no* elimines los mensajes. Esperá a que expire el tiempo de espera de visibilidad y mirá de nuevo:

   ```bash
   sleep 35
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
     --query Attributes --output json
   ```

   ```json
   {
     "ApproximateNumberOfMessages": "10",
     "ApproximateNumberOfMessagesNotVisible": "0"
   }
   ```

   Los diez están de vuelta. La caída costó latencia, no datos.

8. Ahora comportate como un consumidor sano — reconocé un mensaje explícitamente:

   ```bash
   HANDLE=$(aws sqs receive-message --queue-url "$QURL" \
     --max-number-of-messages 1 --wait-time-seconds 5 \
     --query 'Messages[0].ReceiptHandle' --output text)

   aws sqs delete-message --queue-url "$QURL" --receipt-handle "$HANDLE"
   aws sqs get-queue-attributes --queue-url "$QURL" \
     --attribute-names ApproximateNumberOfMessages --query Attributes --output json
   ```

   ```json
   { "ApproximateNumberOfMessages": "9" }
   ```

9. **Desmontaje:**

   ```bash
   aws sqs delete-queue --queue-url "$QURL"
   aws sqs delete-queue --queue-url "$DLQ_URL"
   ```

   Los nombres de cola quedan reservados durante ~60 segundos después de la eliminación.

### Verificá tu comprensión

- **Q4.1** — En el paso 3 el productor tuvo éxito diez veces sin ningún consumidor en ejecución. Indicá, en el vocabulario de la Tarea 1.2, qué propiedad de la arquitectura lo hizo posible y qué habría pasado en un diseño monolítico y sincrónico.
- **Q4.2** — Distinguí `ApproximateNumberOfMessages` de `ApproximateNumberOfMessagesNotVisible`. ¿Cuál graficarías como señal principal de escalado para la flota de consumidores, y por qué?
- **Q4.3** — El paso 7 recuperó los diez mensajes después de una caída simulada. ¿Qué dos atributos de la cola produjeron juntos ese resultado, y cuál es el modo de fallo si el tiempo de espera de visibilidad se fija *más corto* que el tiempo de procesamiento del consumidor?
- **Q4.4** — `maxReceiveCount: 3` envía un mensaje a la DLQ después de tres recepciones. ¿Qué pilar de Well-Architected motiva más directamente una DLQ, y qué fallo específico contiene?
- **Q4.5** — El desacoplamiento con una cola introduce consistencia eventual y entrega fuera de orden (visible en el paso 5). Nombrá una carga de trabajo donde esa concesión sea inaceptable, y qué cambiarías.
- **Q4.6** — La cola nunca "se cayó" durante este ejercicio y nunca la parcheaste, dimensionaste ni escalaste. ¿Qué característica de la nube del Dominio 1 ilustra eso?

---

## Ejercicio 5 — Pensar en paralelo, y medirlo

"Pensar en paralelo" es la menos intuitiva de las cuatro habilidades porque en un único servidor suele ser una falsa economía. En AWS, las capas de almacenamiento y red son horizontalmente escalables, así que el rendimiento es función de la *concurrencia*, no de la máquina. Probalo con un cronómetro.

### Pasos

1. Creá un bucket de laboratorio (los nombres de bucket son globalmente únicos):

   ```bash
   BUCKET="clf-1-2-lab-$(aws sts get-caller-identity --query Account --output text)-$RANDOM"

   if [ "$AWS_REGION" = "us-east-1" ]; then
     aws s3api create-bucket --bucket "$BUCKET"
   else
     aws s3api create-bucket --bucket "$BUCKET" \
       --create-bucket-configuration "LocationConstraint=$AWS_REGION"
   fi
   echo "$BUCKET"
   ```

2. Generá 200 objetos pequeños — la carga de trabajo de muchos archivos chicos, donde domina la concurrencia:

   ```bash
   mkdir -p /tmp/clf-parallel && cd /tmp/clf-parallel
   for i in $(seq 1 200); do head -c 1048576 /dev/urandom > "part-$i.bin"; done
   du -sh /tmp/clf-parallel
   ```

   ```
   200M	/tmp/clf-parallel
   ```

3. Registrá la configuración actual de concurrencia de la CLI (el valor predeterminado es `10`):

   ```bash
   aws configure get default.s3.max_concurrent_requests || echo "unset (default: 10)"
   ```

4. **Línea base en serie** — forzá una solicitud a la vez:

   ```bash
   aws configure set default.s3.max_concurrent_requests 1
   time aws s3 sync /tmp/clf-parallel "s3://$BUCKET/serial/" --only-show-errors
   ```

   ```
   real	3m41.208s
   user	0m52.114s
   sys	0m9.633s
   ```

5. **Ejecución en paralelo** — los mismos bytes, la misma red, veinte en vuelo:

   ```bash
   aws configure set default.s3.max_concurrent_requests 20
   time aws s3 sync /tmp/clf-parallel "s3://$BUCKET/parallel/" --only-show-errors
   ```

   ```
   real	0m24.867s
   user	1m03.771s
   sys	0m12.480s
   ```

   Los números absolutos dependen enteramente de tu enlace de subida; la **proporción** es la lección. Notá que el tiempo `user` apenas cambió — no compraste más CPU, dejaste de estar ocioso esperando idas y vueltas.

6. Ahora el caso de un único objeto grande, donde el paralelismo ocurre *dentro* de una sola carga vía multipart:

   ```bash
   head -c 209715200 /dev/urandom > /tmp/big.bin   # 200 MB

   aws configure set default.s3.multipart_threshold 8MB
   aws configure set default.s3.multipart_chunksize 8MB
   time aws s3 cp /tmp/big.bin "s3://$BUCKET/big-8mb.bin" --only-show-errors

   aws configure set default.s3.multipart_chunksize 64MB
   time aws s3 cp /tmp/big.bin "s3://$BUCKET/big-64mb.bin" --only-show-errors
   ```

   Con `max_concurrent_requests=20`, un tamaño de fragmento de 8 MB produce 25 partes cargadas en paralelo; un tamaño de fragmento de 64 MB produce 4. Esperá que el tamaño de fragmento más chico termine más rápido en un enlace ancho — y que emita más solicitudes.

7. Verificá que ambos objetos son idénticos byte a byte pese a las diferentes estrategias de carga:

   ```bash
   aws s3api head-object --bucket "$BUCKET" --key big-8mb.bin  --query 'ContentLength'
   aws s3api head-object --bucket "$BUCKET" --key big-64mb.bin --query 'ContentLength'
   aws s3api head-object --bucket "$BUCKET" --key big-8mb.bin  --query 'ETag'
   aws s3api head-object --bucket "$BUCKET" --key big-64mb.bin --query 'ETag'
   ```

   ```
   209715200
   209715200
   "9a7f...-25"
   "1c3e...-4"
   ```

   Misma longitud, ETags diferentes — y el `-25` / `-4` final es el conteo de partes. Un ETag multipart **no** es el MD5 del objeto.

8. **Desmontaje y restauración de los valores predeterminados de tu CLI:**

   ```bash
   aws s3 rm "s3://$BUCKET" --recursive
   aws s3api delete-bucket --bucket "$BUCKET"
   aws configure set default.s3.max_concurrent_requests 10
   aws configure set default.s3.multipart_threshold 8MB
   aws configure set default.s3.multipart_chunksize 8MB
   rm -rf /tmp/clf-parallel /tmp/big.bin
   ```

### Verificá tu comprensión

- **Q5.1** — Los pasos 4 y 5 movieron bytes idénticos por un enlace idéntico con tiempos de reloj muy diferentes. ¿En qué recurso estaba realmente esperando la ejecución en serie, y por qué la nube recompensa la concurrencia más de lo que suele hacerlo un NAS en las instalaciones propias?
- **Q5.2** — El tiempo de CPU `user` subió levemente mientras el tiempo `real` se desplomó. ¿Qué te dice eso sobre si "pensar en paralelo" es una optimización de CPU?
- **Q5.3** — Un `multipart_chunksize` más chico significa más partes y cargas normalmente más rápidas, pero AWS factura por solicitud. Nombrá el pilar de cada lado de esa concesión y explicá cómo decidirías.
- **Q5.4** — Dá dos servicios de AWS distintos de S3 cuya propuesta de valor entera sea "pensar en paralelo", y decí qué unidad paraleliza cada uno.
- **Q5.5** — Un equipo informa que "S3 es lento". Cargan un único archivo de 5 GB con un cliente propio de un solo hilo. Sin comprar nada, nombrá dos cambios que aumenten el rendimiento y explicá qué principio de diseño aplica cada uno.

---

## Ejercicio 6 — Automatizar la experimentación, permitir arquitecturas evolutivas

Los principios 3 y 4 son una misma capacidad vista dos veces: si la arquitectura es un archivo de texto, cambiarla es un diff, y revertirla es un diff. La infraestructura como código es lo que convierte la "arquitectura evolutiva" de una aspiración en un `git revert`.

### Pasos

1. Escribí la plantilla de la versión 1:

   ```bash
   cat > /tmp/clf-1-2.yaml <<'EOF'
   AWSTemplateFormatVersion: '2010-09-09'
   Description: CLF-C02 Topic 1.2 - evolutionary architecture demonstration

   Parameters:
     RetentionSeconds:
       Type: Number
       Default: 345600
       MinValue: 60
       MaxValue: 1209600
       Description: SQS message retention period, in seconds

   Resources:
     WorkQueue:
       Type: AWS::SQS::Queue
       Properties:
         QueueName: clf-1-2-cfn-queue
         MessageRetentionPeriod: !Ref RetentionSeconds
         VisibilityTimeout: 30

   Outputs:
     QueueUrl:
       Description: URL of the work queue
       Value: !Ref WorkQueue
     QueueArn:
       Description: ARN of the work queue
       Value: !GetAtt WorkQueue.Arn
   EOF
   ```

2. Validá antes de desplegar — el fallo más barato posible:

   ```bash
   aws cloudformation validate-template --template-body file:///tmp/clf-1-2.yaml \
     --query '{Description:Description,Params:Parameters[].ParameterKey}' --output json
   ```

   ```json
   {
     "Description": "CLF-C02 Topic 1.2 - evolutionary architecture demonstration",
     "Params": ["RetentionSeconds"]
   }
   ```

3. Desplegá la versión 1:

   ```bash
   aws cloudformation deploy --stack-name clf-1-2-cfn --template-file /tmp/clf-1-2.yaml
   aws cloudformation describe-stacks --stack-name clf-1-2-cfn \
     --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs[].{K:OutputKey,V:OutputValue}}' \
     --output json
   ```

   ```json
   {
     "Status": "CREATE_COMPLETE",
     "Outputs": [
       {"K": "QueueUrl", "V": "https://sqs.us-east-1.amazonaws.com/123456789012/clf-1-2-cfn-queue"},
       {"K": "QueueArn", "V": "arn:aws:sqs:us-east-1:123456789012:clf-1-2-cfn-queue"}
     ]
   }
   ```

4. **Proponé una evolución sin comprometerte con ella.** Un conjunto de cambios (change set) es el equivalente arquitectónico de una revisión de código:

   ```bash
   aws cloudformation deploy --stack-name clf-1-2-cfn \
     --template-file /tmp/clf-1-2.yaml \
     --parameter-overrides RetentionSeconds=1209600 \
     --no-execute-changeset
   ```

   La CLI imprime el comando para inspeccionar el cambio pendiente; ejecutalo, o listá los conjuntos de cambios directamente:

   ```bash
   CS=$(aws cloudformation list-change-sets --stack-name clf-1-2-cfn \
     --query 'Summaries[0].ChangeSetName' --output text)

   aws cloudformation describe-change-set --stack-name clf-1-2-cfn --change-set-name "$CS" \
     --query 'Changes[].ResourceChange.{Action:Action,Res:LogicalResourceId,Replacement:Replacement,Props:Details[].Target.Name}' \
     --output json
   ```

   ```json
   [
     {
       "Action": "Modify",
       "Res": "WorkQueue",
       "Replacement": "False",
       "Props": ["MessageRetentionPeriod"]
     }
   ]
   ```

   `"Replacement": "False"` es la evaluación de riesgo: este cambio actualiza en el lugar y no va a destruir la cola.

5. Ejecutá el conjunto de cambios:

   ```bash
   aws cloudformation execute-change-set --stack-name clf-1-2-cfn --change-set-name "$CS"
   aws cloudformation wait stack-update-complete --stack-name clf-1-2-cfn
   aws sqs get-queue-attributes \
     --queue-url "https://sqs.$AWS_REGION.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/clf-1-2-cfn-queue" \
     --attribute-names MessageRetentionPeriod --query Attributes --output json
   ```

   ```json
   { "MessageRetentionPeriod": "1209600" }
   ```

6. **Introducí una desviación (drift)** como lo haría un ingeniero de guardia apurado — a mano, fuera de banda:

   ```bash
   QUEUE_URL="https://sqs.$AWS_REGION.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/clf-1-2-cfn-queue"
   aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes VisibilityTimeout=120
   ```

7. Detectala:

   ```bash
   DID=$(aws cloudformation detect-stack-drift --stack-name clf-1-2-cfn \
     --query StackDriftDetectionId --output text)
   sleep 15
   aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DID" \
     --query '{Status:DetectionStatus,Drift:StackDriftStatus,Drifted:DriftedStackResourceCount}' \
     --output json
   ```

   ```json
   {
     "Status": "DETECTION_COMPLETE",
     "Drift": "DRIFTED",
     "Drifted": 1
   }
   ```

8. Mirá exactamente qué propiedad se desvió:

   ```bash
   aws cloudformation describe-stack-resource-drifts --stack-name clf-1-2-cfn \
     --query 'StackResourceDrifts[].{Res:LogicalResourceId,Status:StackResourceDriftStatus,Diffs:PropertyDifferences[].{Path:PropertyPath,Expected:ExpectedValue,Actual:ActualValue}}' \
     --output json
   ```

   ```json
   [
     {
       "Res": "WorkQueue",
       "Status": "MODIFIED",
       "Diffs": [
         {"Path": "/VisibilityTimeout", "Expected": "30", "Actual": "120"}
       ]
     }
   ]
   ```

9. **Desmontaje — un solo comando elimina toda la arquitectura:**

   ```bash
   aws cloudformation delete-stack --stack-name clf-1-2-cfn
   aws cloudformation wait stack-delete-complete --stack-name clf-1-2-cfn
   rm -f /tmp/clf-1-2.yaml
   ```

### Verificá tu comprensión

- **Q6.1** — El paso 4 produjo un plan sin cambiar nada. ¿A qué principio general de diseño sirve el mecanismo del *change set*, y qué clase de incidente de producción previene?
- **Q6.2** — `"Replacement": "False"` fue el campo más importante de esa salida. Explicá qué habría significado `"True"` para un recurso con estado, y por qué un arquitecto debe leerlo antes de ejecutar.
- **Q6.3** — El paso 6 fue un arreglo de emergencia legítimo que funcionó. ¿Por qué es no obstante un defecto, y qué pilar nombra la práctica que el paso 6 rompe?
- **Q6.4** — El paso 9 destruyó el entorno con un solo comando. Conectá esto con "test systems at production scale": ¿qué hace asequible un desmontaje barato y completo que un centro de datos no?
- **Q6.5** — La plantilla es un archivo. Nombrá tres cosas que ahora podés hacerle a tu arquitectura que eran imposibles cuando vivía solo en la consola.

---

## Ejercicio 7 — Mejorar mediante game days: el catálogo de fallos y el radio de impacto

El sexto principio general te pide *practicar* el fallo en vez de discutirlo. AWS Fault Injection Service (FIS) convierte eso en un experimento controlado y acotado. Este ejercicio es enteramente de solo lectura — vas a inspeccionar el catálogo de fallos y a diseñar los límites de protección, sin incurrir en cargos de FIS.

### Pasos

1. Listá los fallos que AWS puede inyectar por vos:

   ```bash
   aws fis list-actions --query 'actions[].id' --output text | tr '\t' '\n' | sort
   ```

   ```
   aws:ec2:reboot-instances
   aws:ec2:stop-instances
   aws:ec2:terminate-instances
   aws:ecs:stop-task
   aws:eks:pod-cpu-stress
   aws:eks:pod-delete
   aws:eks:pod-network-latency
   aws:fis:inject-api-internal-error
   aws:fis:wait
   aws:network:disrupt-connectivity
   aws:rds:failover-db-cluster
   aws:rds:reboot-db-instances
   aws:ssm:send-command
   ...
   ```

   (Abreviado — el catálogo crece.)

2. Leé la descripción completa y los parámetros de una acción:

   ```bash
   aws fis get-action --id aws:ec2:stop-instances \
     --query 'action.{Id:id,Description:description,Params:keys(parameters),Targets:keys(targets)}' \
     --output json
   ```

   ```json
   {
     "Id": "aws:ec2:stop-instances",
     "Description": "Stop the specified Amazon EC2 instances.",
     "Params": ["startInstancesAfterDuration"],
     "Targets": ["Instances"]
   }
   ```

3. Encontrá las acciones que te permitirían ensayar el *mismo* fallo que reparaste a mano en el ejercicio 3:

   ```bash
   aws fis list-actions --query 'actions[?starts_with(id, `aws:ec2:`)].{Id:id,Desc:description}' \
     --output table
   ```

4. Encontrá las acciones que simulan la pérdida de una **zona de disponibilidad** o de conectividad — el modo de fallo que el ejercicio 0 discutía:

   ```bash
   aws fis list-actions \
     --query 'actions[?contains(id, `network`) || contains(id, `disrupt`)].{Id:id,Desc:description}' \
     --output table
   ```

5. En papel, especificá un game day para el grupo de Auto Scaling del ejercicio 3. Una plantilla de experimento FIS válida necesita los cuatro:

   | Elemento | Tu respuesta |
   |---|---|
   | **Acción** (qué se rompe) | |
   | **Objetivo** (radio de impacto — qué recursos, seleccionados cómo) | |
   | **Condición de parada** (la alarma de CloudWatch que aborta el experimento) | |
   | **Hipótesis** (el enunciado falsable que estás probando) | |

6. Confirmá que la cuenta no tiene experimentos en ejecución ni plantillas olvidadas:

   ```bash
   aws fis list-experiment-templates --query 'experimentTemplates[].{Id:id,Desc:description}' --output table
   aws fis list-experiments --query 'experiments[].{Id:id,State:state.status}' --output table
   ```

No se requiere desmontaje — todos los comandos de arriba son de solo lectura.

### Verificá tu comprensión

- **Q7.1** — Una plantilla de experimento FIS requiere una **condición de parada**. ¿Cuál es el propósito de ingeniería de exigir una, y en qué se convertiría el experimento sin ella?
- **Q7.2** — Escribí una hipótesis falsable para el grupo del ejercicio 3 en la forma *"Cuando X, esperamos Y dentro de Z"*. Explicá por qué "esperamos que el sistema esté bien" no es una hipótesis.
- **Q7.3** — Los game days figuran como un *principio general de diseño*, pero la práctica es propiedad principalmente de un pilar y valida otro. Nombrá ambos y justificá la división.
- **Q7.4** — Tu gerente objeta: "ya sabemos que una instancia detenida se reemplaza — lo vimos en el ejercicio 3". Dá el argumento más fuerte para ejecutar el game day igual.
- **Q7.5** — El catálogo de FIS incluye `aws:fis:inject-api-internal-error`. ¿Qué clase de fallo ensaya eso que detener una instancia no puede, y qué pregunta de Fiabilidad del ejercicio 1 ejercita?

---

## Ejercicio 8 — Cerrar el ciclo: una revisión Well-Architected con un conteo de riesgos

El ejercicio 1 leyó el framework. Este lo *usa*: respondé preguntas, mirá aparecer un perfil de riesgo, generá un plan de mejora y congelá un hito para que la próxima revisión tenga una línea base con la cual comparar.

### Pasos

1. Volvé a crear la carga de trabajo si la eliminaste:

   ```bash
   WL_ID=$(aws wellarchitected create-workload \
     --workload-name "clf-1-2-review" \
     --description "Auto Scaling group + SQS pipeline from exercises 3 and 4" \
     --environment PREPRODUCTION \
     --aws-regions "$AWS_REGION" \
     --lenses wellarchitected \
     --review-owner "student@example.com" \
     --client-request-token "clf-1-2-review-0001" \
     --query WorkloadId --output text)
   echo "$WL_ID"
   ```

2. Mirá el perfil de riesgo de una revisión en la que **todavía no se respondió nada**:

   ```bash
   aws wellarchitected get-lens-review \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'LensReview.PillarReviewSummaries[].{Pillar:PillarName,Risks:RiskCounts}' \
     --output json
   ```

   ```json
   [
     {"Pillar": "Operational Excellence", "Risks": {"UNANSWERED": 11, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     {"Pillar": "Security",               "Risks": {"UNANSWERED": 11, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     {"Pillar": "Reliability",            "Risks": {"UNANSWERED": 13, "HIGH": 0, "MEDIUM": 0, "NONE": 0, "NOT_APPLICABLE": 0}},
     ...
   ]
   ```

   (Los conteos varían según la versión de la lente.) Todo está `UNANSWERED` — la herramienta no afirma nada sobre una carga de trabajo que no describiste.

3. Elegí la pregunta de fiabilidad sobre resistir fallos de componentes y leé sus opciones:

   ```bash
   QID=$(aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected --pillar-id reliability \
     --query 'AnswerSummaries[?contains(QuestionTitle, `withstand component failures`)].QuestionId | [0]' \
     --output text)
   echo "$QID"

   aws wellarchitected get-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected --question-id "$QID" \
     --query 'Answer.Choices[].{Id:ChoiceId,Title:Title}' --output table
   ```

4. Respondela honestamente para la arquitectura que realmente construiste en los ejercicios 3 y 4:

   ```bash
   CHOICE=$(aws wellarchitected get-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected --question-id "$QID" \
     --query 'Answer.Choices[0].ChoiceId' --output text)

   aws wellarchitected update-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --question-id "$QID" \
     --selected-choices "$CHOICE" \
     --notes "Multi-AZ ASG with EC2 health checks; SQS decouples the consumer tier; no DR plan yet." \
     --query 'Answer.{Q:QuestionTitle,Risk:Risk,Selected:SelectedChoices}' --output json
   ```

   ```json
   {
     "Q": "How do you design your workload to withstand component failures?",
     "Risk": "MEDIUM",
     "Selected": ["rel_withstand_component_failures_..."]
   }
   ```

   Seleccionar *algunas* buenas prácticas pero no todas da `MEDIUM`; no seleccionar ninguna da `HIGH`.

5. Marcá una pregunta como genuinamente fuera de alcance, que es distinto de dejarla sin responder:

   ```bash
   QID2=$(aws wellarchitected list-answers \
     --workload-id "$WL_ID" --lens-alias wellarchitected --pillar-id reliability \
     --query 'AnswerSummaries[?contains(QuestionTitle, `disaster recovery`)].QuestionId | [0]' \
     --output text)

   aws wellarchitected update-answer \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --question-id "$QID2" --is-applicable \
     --notes "Sandbox workload; no DR obligation." \
     --query 'Answer.{Q:QuestionTitle,Risk:Risk}' --output json
   ```

   Para marcarla como no aplicable, usá `--no-is-applicable`.

6. Generá el plan de mejora — la salida que hace accionable a la herramienta:

   ```bash
   aws wellarchitected list-lens-review-improvements \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'ImprovementSummaries[?Risk!=`NONE`].{Pillar:PillarId,Question:QuestionTitle,Risk:Risk,Plan:ImprovementPlanUrl}' \
     --output json | head -40
   ```

7. Congelá un hito. Una revisión sin línea base no puede mostrar mejora:

   ```bash
   aws wellarchitected create-milestone \
     --workload-id "$WL_ID" \
     --milestone-name "baseline-before-remediation" \
     --client-request-token "clf-1-2-ms-0001" \
     --query '{Milestone:MilestoneNumber}' --output json

   aws wellarchitected list-milestones --workload-id "$WL_ID" \
     --query 'MilestoneSummaries[].{N:MilestoneNumber,Name:MilestoneName,When:RecordedAt}' \
     --output table
   ```

8. Releé los conteos de riesgo por pilar y comparalos con el paso 2:

   ```bash
   aws wellarchitected get-lens-review \
     --workload-id "$WL_ID" --lens-alias wellarchitected \
     --query 'LensReview.PillarReviewSummaries[?PillarName==`Reliability`].RiskCounts' \
     --output json
   ```

9. **Desmontaje:**

   ```bash
   aws wellarchitected delete-workload \
     --workload-id "$WL_ID" \
     --client-request-token "clf-1-2-review-del-0001"

   aws wellarchitected list-workloads \
     --query 'WorkloadSummaries[].WorkloadName' --output text
   ```

### Verificá tu comprensión

- **Q8.1** — En el paso 2 todas las preguntas estaban `UNANSWERED` y ningún pilar mostraba `HIGH`. ¿Es entonces una revisión sin responder de bajo riesgo? Explicá qué codifica realmente `UNANSWERED`.
- **Q8.2** — Distinguí `NOT_APPLICABLE` de `UNANSWERED`, y dá una razón de negocio legítima para marcar una pregunta como no aplicable.
- **Q8.3** — ¿Para qué sirve un *hito*, y a qué principio general de diseño sirve? Respondé sin usar la palabra "auditoría".
- **Q8.4** — La Well-Architected Tool es gratuita y no produce infraestructura. Indicá tres beneficios concretos que entrega y que justifican ejecutar una revisión — esta es una lista directamente examinable.
- **Q8.5** — Una revisión devuelve cuatro riesgos `HIGH` en Seguridad y uno en Optimización de costos. ¿En qué orden los abordás, y qué dice el framework sobre tratar todos los pilares como igualmente ponderados?

---

## Ejercicio 9 — Ejercitación con escenarios

El examen presenta los principios de diseño como escenarios, no como definiciones. Para cada fila, nombrá **(a)** el pilar principal de Well-Architected y **(b)** la habilidad de la Tarea 1.2 o el principio general de diseño que demuestra.

### Pasos

1. Copiá la tabla a tus notas y completá ambas columnas antes de ver las respuestas.

   | # | Escenario | Pilar | Principio / habilidad |
   |---|---|---|---|
   | 1 | Un servicio de checkout escribe órdenes en una cola; la flota de fulfillment lee de ella. Fulfillment se redespliega durante 20 minutos; checkout sigue tomando órdenes. | | |
   | 2 | Un trabajo de analítica se divide en 500 fragmentos procesados simultáneamente, terminando en 4 minutos en vez de 12 horas. | | |
   | 3 | Una flota de 6 servidores web está repartida en 3 zonas de disponibilidad detrás de un balanceador de carga. | | |
   | 4 | Todas las noches a las 21:00 la flota baja de 20 instancias a 4; a las 07:00 vuelve a 20. | | |
   | 5 | Antes de cada versión, el equipo ejecuta un ensayo que detiene una instancia al azar en producción durante el horario laboral. | | |
   | 6 | Todo el entorno está definido en una plantilla guardada en Git; el entorno de staging se crea y se destruye a diario. | | |
   | 7 | La selección de tipo de instancia se cambia de `m5.4xlarge` a `m6g.xlarge` después de leer dos semanas de datos de utilización de CloudWatch. | | |
   | 8 | Las claves de acceso se reemplazan por roles de IAM, y cada llamada a la API se registra en CloudTrail. | | |
   | 9 | Los trabajos por lotes se mueven a una región con menor huella de carbono y se programan para ejecutarse fuera de las horas pico. | | |
   | 10 | Los runbooks se convierten en documentos de Systems Manager para que la remediación la ejecute cualquiera de forma idéntica. | | |
   | 11 | El equipo deja de comprar 3 años de hardware por adelantado y en su lugar agrega capacidad semanalmente según el tráfico observado. | | |
   | 12 | Se ejecuta una prueba de carga contra una copia de tamaño completo de producción, y luego la copia se elimina esa misma tarde. | | |

2. Ahora hacé la versión difícil — para las filas 1, 3, 4 y 7, nombrá un **segundo** pilar que también tenga un reclamo sobre el escenario, e indicá la concesión entre ambos.

### Verificá tu comprensión

- **Q9.1** — Las filas 3 y 4 cambian ambas la cantidad de instancias. ¿Qué distingue la *alta disponibilidad* de la *elasticidad*, dado que el mecanismo (un grupo de Auto Scaling) puede ser idéntico?
- **Q9.2** — La fila 11 es el enunciado canónico de un principio general de diseño. Nombralo, y nombrá el concepto de gasto de capital que reemplaza.
- **Q9.3** — ¿Qué fila es el ejemplo más fuerte de "diseñar para el fallo", y cuál el más fuerte de "pensar en paralelo"? Defendé ambas elecciones frente a la segunda opción.
- **Q9.4** — La fila 9 pertenece al pilar más nuevo. Dá un cambio arquitectónico adicional que sirva al mismo pilar sin reducir la capacidad.

---

## Lista de verificación de desmontaje

Ejecutá esto antes de cerrar la terminal. Cada comando debería no informar nada.

```bash
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?starts_with(AutoScalingGroupName, `clf-1-2`)].AutoScalingGroupName' --output text
aws ec2 describe-launch-templates \
  --query 'LaunchTemplates[?starts_with(LaunchTemplateName, `clf-1-2`)].LaunchTemplateName' --output text
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws sqs list-queues --queue-name-prefix clf-1-2 --query 'QueueUrls' --output text
aws s3 ls | grep clf-1-2 || echo "no lab buckets"
aws cloudformation describe-stacks \
  --query 'Stacks[?starts_with(StackName, `clf-1-2`)].StackName' --output text
aws wellarchitected list-workloads \
  --query 'WorkloadSummaries[?starts_with(WorkloadName, `clf-1-2`)].WorkloadName' --output text
aws cloudwatch describe-alarms \
  --alarm-name-prefix TargetTracking-clf-1-2 --query 'MetricAlarms[].AlarmName' --output text
```

---

<details>
<summary><b>Respuestas</b> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 0

**Q0.1** — `us-east-1a` es un *nombre de AZ*, y AWS mapea los nombres de AZ a centros de datos físicos **de forma independiente por cuenta** para que las cargas de trabajo de los clientes se repartan de manera pareja en vez de que todos se amontonen en la "a". `use1-az4` es el *ID de AZ*, que se refiere a la misma ubicación física en todas las cuentas. El **ID de AZ es el estable**; dos cuentas que comparen `us-east-1a` pueden estar hablando de edificios distintos, y por eso el uso compartido de recursos entre cuentas (por ejemplo, subredes compartidas mediante AWS RAM) se expresa en IDs de AZ.

**Q0.2** — Viola primero la **Fiabilidad**. Incumple la habilidad de *diseñar para el fallo*: una única AZ es un único dominio de fallo, así que cualquier evento que afecte a esa AZ tira abajo la carga de trabajo entera. Hay una preocupación secundaria de Eficiencia del rendimiento (sin margen de capacidad en otro lado), pero Fiabilidad es la principal.

**Q0.3** — Múltiples AZ son dominios de fallo *disponibles*, pero la disponibilidad proviene de que una carga de trabajo esté efectivamente distribuida entre ellas con comprobación de estado y reemplazo automático — la infraestructura es una precondición, la arquitectura es la causa.

### Ejercicio 1

**Q1.1** —
1. **Excelencia operativa** — ejecutar y monitorear sistemas para entregar valor de negocio, y mejorar continuamente los procesos y procedimientos.
2. **Seguridad** — proteger datos, sistemas y activos; identidad, detección, protección de los datos en tránsito y en reposo, respuesta a incidentes.
3. **Fiabilidad** — que una carga de trabajo cumpla su función prevista de forma correcta y consistente, y se recupere de los fallos.
4. **Eficiencia del rendimiento** — usar los recursos de cómputo de forma eficiente y mantener esa eficiencia a medida que cambian la demanda y las tecnologías.
5. **Optimización de costos** — entregar valor de negocio al precio más bajo.
6. **Sostenibilidad** — minimizar el impacto ambiental de ejecutar cargas de trabajo en la nube.

**Q1.2** — Los pilares son **lentes sobre la misma arquitectura, no particiones de ella**. La elasticidad es una propiedad de fiabilidad (absorber picos de demanda sin fallar), una propiedad de rendimiento (dimensionar según la carga) y una propiedad de costo (no pagar por capacidad ociosa). El framework se usa haciendo los seis conjuntos de preguntas sobre *el mismo* diseño y luego haciendo explícitas las concesiones — no asignando cada componente a un pilar.

**Q1.3** — La Well-Architected Tool mide **tus respuestas sobre la carga de trabajo**, no la carga de trabajo en sí. No escanea tu cuenta. Una revisión es una autoevaluación estructurada; su salida es tan veraz como las respuestas que des — que es precisamente por lo que es gratuita y por lo que no vale nada si se responde de forma aspiracional.

**Q1.4** — **Fiabilidad**. El aislamiento de fallos implementa **diseñar para el fallo**: los mamparos (bulkheads), la arquitectura basada en celdas, y los límites multi-AZ y multi-región limitan todos hasta dónde puede propagarse un único fallo.

**Q1.5** — Una **lente** es un conjunto adicional de preguntas y buenas prácticas para un dominio tecnológico o industria específicos (Serverless, SaaS, Machine Learning, Servicios financieros). Se aplica *por encima* de los seis pilares y hace preguntas específicas del dominio dentro de ellos. El conteo de pilares está fijado en seis; las lentes son extensiones, no pilares.

### Ejercicio 2

**Q2.1** — La capacidad no es infinita; es **elástica dentro de una cuota de cuenta, y la cuota es ajustable a pedido en vez de por adquisición**. El enunciado correcto es: ya no tenés que adivinar la capacidad *en el momento de la compra*, porque podés adquirirla y liberarla en minutos — pero seguís teniendo que conocer y gestionar tus cuotas de servicio, que es exactamente por lo que la pregunta 1 de Fiabilidad es *"How do you manage service quotas and constraints?"*.

**Q2.2** — **Pago por uso con granularidad por segundo o por hora y sin compromiso inicial**: un clon de producción a escala completa cuesta el precio de las horas que se ejecuta, no el precio de un segundo centro de datos. Inmediatamente después de la prueba **eliminás el entorno**, que es lo que hace que el costo sea proporcional a la prueba y no al año.

**Q2.3** — **La automatización habilita la evolución.** Si cambiar la arquitectura requiere un procedimiento manual, propenso a errores y de días de duración, la respuesta racional es congelar el diseño — el costo del cambio supera el valor de la mejora. Solo cuando un cambio es barato, repetible y reversible se vuelve seguro por defecto permitir que la arquitectura evolucione. El orden inverso es imposible: querer una arquitectura evolutiva no hace seguro el cambio manual.

**Q2.4** — **"Improve through game days."** Prescribe una práctica de equipo — ensayar el fallo — en vez de una propiedad arquitectónica. La **Excelencia operativa** la refuerza más directamente (aprender de todos los eventos operativos y fallos), mientras que lo que *valida* es la Fiabilidad.

### Ejercicio 3

**Q3.1** — **Diseñar para el fallo**, mediante aislamiento de fallos entre zonas de disponibilidad. La causa es que `--vpc-zone-identifier` lista subredes en múltiples AZ: Auto Scaling equilibra la capacidad entre las AZ que se le dan. Si hubieras pasado una única subred, el mismo `--desired-capacity 2` habría producido dos instancias en un solo dominio de fallo.

**Q3.2** — El grupo reacciona a los **resultados de las comprobaciones de estado**, no a quién las causó. Una instancia terminada deja de pasar las comprobaciones de estado de EC2, y el contrato del grupo es "mantener `DesiredCapacity` instancias sanas en servicio". Esa indiferencia a la *causa* es el sentido entero de diseñar para el fallo: la remediación es idéntica ya sea que el disparador haya sido un fallo de hardware, un evento de AZ, un kernel panic o una persona con un teclado — así que la ruta de recuperación se ejercita constantemente en vez de ser un procedimiento de emergencia sin probar.

**Q3.3** — Con `MinSize=1` pagás por una instancia en vez de dos — una ganancia de **Optimización de costos**. Pero tampoco te queda capacidad sobreviviente durante los ~60–120 segundos que lleva detectar el fallo y lanzar un reemplazo, así que el fallo de una sola instancia es una caída total — una pérdida de **Fiabilidad**. `MinSize=2` a través de dos AZ compra servicio continuo ante el fallo de una instancia o de una AZ. Esta es la concesión canónica entre pilares: ninguna respuesta es "correcta" sin un requisito de disponibilidad declarado.

**Q3.4** — La **política de seguimiento de objetivos** es elasticidad: la capacidad se adquiere y se libera **automáticamente, en respuesta a la demanda observada**. `set-desired-capacity` es aprovisionamiento manual que resulta ser rápido — sigue dependiendo de que un humano prediga o note la demanda, que es justamente la adivinanza que la nube debería eliminar. La velocidad de aprovisionamiento no es elasticidad; el aprovisionamiento *automático* sí.

**Q3.5** — Escalar hacia afuera sin escalar hacia adentro significa que la capacidad sube como un trinquete y nunca vuelve, así que pagás el precio pico de forma permanente — el clásico fallo de "la nube cuesta más que el centro de datos". La **Optimización de costos** objeta más fuerte; la **Sostenibilidad** también objeta, ya que las instancias ociosas consumen energía sin entregar valor.

**Q3.6** — Dos techos independientes: **(1)** el propio `MaxSize=4` del grupo, un límite deliberado y autoimpuesto de radio de impacto y de presupuesto; **(2)** la **cuota de servicio de la cuenta** para vCPU de instancias bajo demanda en ejecución, un límite externo aplicado por AWS. Elevar `MaxSize` por encima de lo que permite la cuota produce actividades de lanzamiento fallidas, no más capacidad — que es por lo que la gestión de cuotas es una pregunta de Fiabilidad, no una nota al pie de facturación.

### Ejercicio 4

**Q4.1** — El productor y el consumidor están **desacoplados** por un intermediario que es dueño de la durabilidad. La disponibilidad del productor ya no depende de la disponibilidad del consumidor. En un diseño monolítico y sincrónico la llamada de checkout se habría bloqueado esperando la capa de fulfillment y luego habría fallado — la caída del consumidor se habría propagado al cliente como una compra fallida, convirtiendo un fallo parcial en uno total.

**Q4.2** — `ApproximateNumberOfMessages` es el **backlog visible**: mensajes disponibles para recuperación. `ApproximateNumberOfMessagesNotVisible` es lo que está **en vuelo**: recibido por un consumidor pero todavía no eliminado, oculto durante el tiempo de espera de visibilidad. Escalá la flota de consumidores según el **backlog visible** (o según la antigüedad del mensaje) — mide demanda insatisfecha. El conteo en vuelo mide trabajo que ya se está haciendo, así que escalar según él crea un bucle de retroalimentación que escala hacia arriba en proporción a tus propios consumidores.

**Q4.3** — **La eliminación explícita como reconocimiento** (un mensaje solo se quita cuando el consumidor llama a `DeleteMessage`) más el **tiempo de espera de visibilidad** (un mensaje no reconocido reaparece automáticamente). Si el tiempo de espera de visibilidad es más corto que el tiempo de procesamiento, el mensaje se vuelve visible de nuevo mientras el primer consumidor todavía está trabajando en él, un segundo consumidor lo toma, y el mensaje se procesa **dos veces** — el clásico error de procesamiento duplicado. La solución es dimensionar el tiempo de espera por encima del tiempo de procesamiento p99, extenderlo en vuelo (`ChangeMessageVisibility`) y hacer al consumidor idempotente.

**Q4.4** — **Fiabilidad**. Una DLQ contiene el *mensaje envenenado*: una carga útil que va a fallar cada vez que se procese. Sin una DLQ ese único mensaje se reentrega para siempre, consumiendo indefinidamente la capacidad del consumidor y bloqueando el trabajo sano — un solo registro malo se convierte en una caída de toda la flota. La DLQ acota el fallo a tres intentos y lo pone en cuarentena para inspección offline. (La Excelencia operativa tiene un reclamo secundario: la DLQ también es el registro de diagnóstico.)

**Q4.5** — Cualquier carga de trabajo que requiera **orden estricto o semántica exactamente-una-vez** — un libro contable financiero donde débito-luego-crédito no debe invertirse, o un decremento de inventario que no debe aplicarse dos veces. El cambio: usar una **cola FIFO de SQS** (ordenamiento y deduplicación dentro de un grupo de mensajes) y aceptar su menor rendimiento, o quedarse con la cola estándar y hacer a los consumidores idempotentes con una clave de deduplicación.

**Q4.6** — **La elasticidad junto con el modelo de servicio gestionado / responsabilidad compartida**: SQS se escala, se parchea y se replica solo, así que la capacidad y la disponibilidad de la capa de desacoplamiento son responsabilidad de AWS y no un componente para el que tengas que diseñar para el fallo vos mismo. Notá que esto no está libre de trabajo de diseño — igual elegiste la retención, el tiempo de espera de visibilidad y la política de redrive.

### Ejercicio 5

**Q5.1** — La ejecución en serie esperaba a la **latencia de ida y vuelta de la red**, no al ancho de banda: cada solicitud tenía que completarse antes de que empezara la siguiente, así que el rendimiento estaba limitado a (tamaño del objeto ÷ tiempo de ida y vuelta), dejando el enlace mayormente ocioso. S3 es un servicio masivamente distribuido cuya tasa de solicitudes por prefijo está muy por encima de lo que una sola conexión puede generar, así que las solicitudes concurrentes son atendidas por capacidad de backend distinta. Un NAS tradicional suele tener un único nodo cabecera y una cantidad fija de discos, así que la concurrencia compite por el mismo cuello de botella en vez de reclutar más.

**Q5.2** — "Pensar en paralelo" acá es una **optimización de ocultamiento de latencia / concurrencia, no una optimización de CPU**. El cliente estaba bloqueado, no ocupado. Se hizo casi el mismo trabajo de CPU en una novena parte del tiempo de reloj porque la espera se solapó. Por esto el paralelismo en AWS suele rendir incluso en una instancia cliente pequeña.

**Q5.3** — La **Eficiencia del rendimiento** favorece fragmentos más chicos (más paralelismo, menor tiempo de reloj); la **Optimización de costos** favorece fragmentos más grandes (menos solicitudes PUT, menores cargos por solicitud — y menores costos de reintento en un enlace con pérdidas). Decidí según *cuánto vale la latencia*: para una transferencia interactiva o con fecha límite, comprá la velocidad; para una carga masiva nocturna desatendida donde el tiempo de reloj es gratis, tomá el conteo de solicitudes más barato. Sopesá también la fiabilidad — partes más chicas significan que una parte fallida cuesta menos reintentarla.

**Q5.4** — Dos cualesquiera de: **AWS Lambda** (paraleliza *invocaciones* — una ejecución concurrente por evento); **Amazon EMR / Apache Spark** (paraleliza *particiones de datos* a través de un clúster); **AWS Batch** (paraleliza *trabajos* en un arreglo); **Amazon Kinesis Data Streams** (paraleliza *shards*, un consumidor por shard); **Amazon Athena** (paraleliza *divisiones de consulta* sobre objetos en S3); **Amazon SQS con una flota de consumidores** (paraleliza *mensajes*).

**Q5.5** — **(1)** Usar una carga multipart y multihilo — dividir el objeto de 5 GB en partes y cargarlas concurrentemente, que es *pensar en paralelo* aplicado dentro de un único objeto. **(2)** Elevar la concurrencia del cliente (`max_concurrent_requests`) y/o mover el cliente más cerca de la región del bucket, y usar S3 Transfer Acceleration o una configuración multi-región para clientes distantes — *guiar las arquitecturas con datos*, ya que el valor correcto surge de medir, exactamente como en los pasos 4–5. Ambos son cambios de configuración; ninguno compra hardware, que es el punto.

### Ejercicio 6

**Q6.1** — Sirve a **"automate to make architectural experimentation easier"** (y respalda directamente a "allow for evolutionary architectures"). Previene la clase de incidente en la que una edición de plantilla aparentemente inocua **reemplaza** silenciosamente un recurso — una cola nueva, una base de datos nueva, un endpoint nuevo — destruyendo datos o rompiendo a todos los consumidores que tenían el identificador viejo. El change set hace revisable el radio de impacto *antes* de que sea real.

**Q6.2** — `"Replacement": "True"` significa que CloudFormation va a **crear un recurso físico nuevo y eliminar el viejo** para satisfacer el cambio, porque la propiedad modificada es inmutable. Para un recurso con estado — una instancia de RDS, un volumen de EBS, una cola con backlog — eso significa pérdida de datos y un identificador cambiado (endpoint, ARN, URL) que todo dependiente debe actualizar para usar. Un arquitecto lee este campo porque el diff de la plantilla se ve idéntico en ambos casos; solo el change set distingue "editar" de "reconstruir".

**Q6.3** — El arreglo funcionó, pero la **plantilla ya no describe la realidad**. El próximo `deploy` va a revertir silenciosamente el cambio de emergencia y a volver a romper producción; el entorno ya no puede recrearse de forma idéntica; y la razón del cambio existe solo en la memoria de una persona. Esto rompe la **Excelencia operativa** — realizar las operaciones como código, y hacer cambios frecuentes, pequeños y reversibles. La secuencia correcta es: cambialo a mano si la caída lo exige, después portalo inmediatamente a la plantilla y redesplegá.

**Q6.4** — El desmontaje barato y completo hace asequibles los **entornos desechables a escala completa**: podés levantar una copia del tamaño de producción, ejecutar una prueba de carga real contra capacidad real, y eliminarla esa misma tarde, pagando solo por esas horas. En un centro de datos el entorno de pruebas es un activo de capital permanente, así que inevitablemente se construye más chico que producción — y una prueba de carga contra un entorno más chico no responde la pregunta que hiciste.

**Q6.5** — Tres cualesquiera de: **versionarla** (`git log` sobre tu arquitectura, con autoría y justificación); **revisarla** (un pull request sobre la infraestructura, antes de que exista); **revertirla** (redesplegar el commit anterior); **replicarla** (stacks idénticos en otra región o cuenta); **probarla** (`validate-template`, linting, políticas como código en CI); **auditar la desviación** contra ella (ejercicio 6, paso 7); **parametrizarla** (una plantilla, muchos entornos).

### Ejercicio 7

**Q7.1** — Una condición de parada es el **aborto automático**: una alarma de CloudWatch que detiene el experimento y revierte el fallo inyectado en el momento en que el radio de impacto excede lo que acordaste. Su propósito es hacer que la diferencia entre un *experimento* y una *caída* sea una propiedad del sistema y no del tiempo de reacción del ingeniero. Sin ella, una ejecución de FIS es simplemente un incidente autoinfligido sin límite de duración ni de alcance.

**Q7.2** — Por ejemplo: *"Cuando se detiene una instancia en `clf-1-2-asg`, el grupo vuelve a dos instancias sanas `InService` dentro de 5 minutos, y no falla ninguna solicitud de cliente."* "Esperamos que el sistema esté bien" no es una hipótesis porque no nombra ningún **disparador**, ningún **resultado medible** ni ningún **límite de tiempo** — así que ningún resultado puede falsarla, y el game day no puede enseñarte nada.

**Q7.3** — La práctica es propiedad de la **Excelencia operativa** — los game days son una rutina operativa, y su producto real es aprendizaje, runbooks actualizados y responsables mejor ensayados. Lo que *validan* es la **Fiabilidad** — si los mecanismos de recuperación efectivamente funcionan bajo las condiciones afirmadas. La división importa porque un game day que produce un resultado verde pero ningún aprendizaje hizo solo la mitad de su trabajo.

**Q7.4** — El ejercicio 3 probó el *mecanismo* de forma aislada, en condiciones ideales, sin carga, sin dependencias y con un ingeniero mirando. Un game day prueba el **sistema sociotécnico completo**: ¿se dispara la alarma?, ¿avisa a la persona correcta?, ¿está actualizado el runbook?, ¿la instancia de reemplazo pasa la comprobación de estado de *la aplicación* y no solo la de EC2?, ¿el balanceador de carga drena las conexiones?, ¿el ingeniero de guardia sabe cómo se ve "sano"? Casi todo incidente real es un fallo de una de esas cosas, no del mecanismo documentado.

**Q7.5** — Ensaya el **fallo de dependencias y del plano de control** — una API de AWS devolviéndole errores a *tu* código — en vez de la pérdida de un nodo de cómputo. Detener una instancia prueba si podés perder capacidad; inyectar errores de API prueba si tu lógica de reintentos, retroceso exponencial, tiempos de espera, interruptores de circuito y degradación elegante son correctos. Eso ejercita **"How do you design interactions in a distributed system to mitigate or withstand failures?"** (y su contraparte de prevención).

### Ejercicio 8

**Q8.1** — No. `UNANSWERED` significa **"desconocido"**, no "aceptable". Es la herramienta negándose a hacer una afirmación que vos no hiciste, y una revisión honesta trata las preguntas sin responder como riesgo no evaluado. La distinción importa porque una captura de pantalla de una revisión con cero riesgos HIGH no significa nada a menos que también se muestre el conteo de respondidas.

**Q8.2** — `UNANSWERED` significa *todavía no evaluaste esto* — es un hueco en la revisión. `NOT_APPLICABLE` significa *lo evaluaste y la pregunta no aplica a esta carga de trabajo*, con una razón registrada. Un ejemplo legítimo: una carga de trabajo sin datos persistentes propios — un servicio sin estado de redimensionamiento de imágenes que lee y escribe en el bucket de otro equipo — puede razonablemente marcar las preguntas de respaldo como no aplicables, porque no es dueña de nada que respaldar. `NOT_APPLICABLE` requiere una nota justificativa; sin ella es `UNANSWERED` disfrazado.

**Q8.3** — Un hito es una **instantánea inmutable de la revisión en un momento dado**. Existe para que la próxima revisión tenga una línea base con la cual compararse — podés mostrar que catorce riesgos HIGH pasaron a tres, y conectar eso con trabajo específico. Sirve a **"drive architectures using data"**: convierte la calidad arquitectónica de una opinión en una tendencia medida a lo largo del tiempo.

**Q8.4** — Tres ejemplos: **(1)** aplica un conjunto consistente de preguntas escritas por AWS, de modo que la calidad de la revisión no dependa de qué arquitecto haya estado en la sala; **(2)** produce un **plan de mejora priorizado** con enlaces a orientación específica de buenas prácticas, convirtiendo la revisión en un backlog en vez de un documento; **(3)** **cuantifica el riesgo por pilar** y, mediante hitos, lo sigue a lo largo del tiempo, haciendo visible la deuda arquitectónica para gente que no lee diagramas de arquitectura. Además es **gratuita**, y puede ejecutarse en cualquier etapa del ciclo de vida — antes de construir, antes de lanzar, y periódicamente en producción.

**Q8.5** — Abordá primero los `HIGH` de **Seguridad**. El framework trata a los pilares como concesiones a equilibrar deliberadamente y no como una rúbrica de puntuación de peso igual — pero los riesgos de seguridad generalmente no son negociables del modo en que sí lo son los de costo, rendimiento e incluso algunos de fiabilidad: un sobrecosto es recuperable, una filtración de datos no. La respuesta general honesta es que la prioridad sigue al **impacto de negocio y a la tolerancia al riesgo**, y que las concesiones deben ser **explícitas y estar registradas** (el campo `--notes` existe exactamente para esto) en vez de estar implícitas en un número.

### Ejercicio 9

**Paso 1 — la tabla:**

| # | Pilar | Principio / habilidad |
|---|---|---|
| 1 | Fiabilidad | **Desacoplar componentes** (frente a monolítico) — el productor sobrevive a la ausencia del consumidor |
| 2 | Eficiencia del rendimiento | **Pensar en paralelo** |
| 3 | Fiabilidad | **Diseñar para el fallo** — aislamiento de fallos multi-AZ, alta disponibilidad |
| 4 | Optimización de costos | **Implementar elasticidad** — escalar según la demanda, pagar por lo que se usa |
| 5 | Excelencia operativa | **Mejorar mediante game days** |
| 6 | Excelencia operativa | **Automatizar para facilitar la experimentación** / permitir arquitecturas evolutivas (operaciones como código) |
| 7 | Eficiencia del rendimiento | **Guiar las arquitecturas con datos** (dimensionamiento correcto) |
| 8 | Seguridad | Mínimo privilegio con credenciales temporales; trazabilidad |
| 9 | Sostenibilidad | Minimizar el impacto ambiental — elección de región y de programación horaria |
| 10 | Excelencia operativa | Realizar las operaciones como código — automatizar para hacer el cambio repetible |
| 11 | Optimización de costos | **Dejar de adivinar tus necesidades de capacidad** |
| 12 | Fiabilidad | **Probar los sistemas a escala de producción** |

**Paso 2 — segundos pilares y concesiones:**

- **Fila 1** — también **Eficiencia del rendimiento**: la cola permite que cada capa escale independientemente a su propio ritmo. Concesión: el desacoplamiento compra resiliencia y escalado independiente al precio de la **consistencia eventual y la posible entrega fuera de orden o duplicada**, lo que empuja el trabajo de idempotencia hacia el consumidor.
- **Fila 3** — también **Optimización de costos**: seis instancias en tres AZ cuestan aproximadamente el triple que dos instancias en una sola AZ. Concesión: **la disponibilidad se compra con capacidad redundante y parcialmente ociosa**; el gasto correcto se deriva de un objetivo de disponibilidad declarado, no del instinto.
- **Fila 4** — también **Fiabilidad**: escalar hacia adentro reduce el colchón de capacidad sobreviviente, así que un pico de tráfico inesperado a las 03:00 o un evento de AZ ahora golpea a una flota mucho más chica. Concesión: **ahorro de costos contra margen**; la mitigación es un piso (`MinSize`) dimensionado para el fallo que debés sobrevivir, no para la demanda que esperás. La **Sostenibilidad** tiene un tercer reclamo.
- **Fila 7** — también **Optimización de costos** y **Sostenibilidad**: dimensionar correctamente hacia una familia de instancias más chica y eficiente recorta gasto y energía simultáneamente. Concesión: menos margen para picos y un posible cambio de arquitectura (`m6g` es Graviton/arm64, así que la carga de trabajo debe recompilarse para esa arquitectura) — un costo de migración pagado una vez contra un ahorro recurrente.

**Q9.1** — La **alta disponibilidad** es redundancia entre dominios de fallo para que el *fallo* no cause una caída — la cantidad de instancias se dimensiona para sobrevivir, y no varía con el tráfico. La **elasticidad** es variar la capacidad para que la *demanda* se satisfaga sin sobreaprovisionar — la cantidad sigue a la carga. La fila 3 no cambia nada cuando cambia el tráfico; la fila 4 no cambia nada cuando muere una instancia. El mismo grupo de Auto Scaling implementa ambas porque `MinSize` codifica el requisito de disponibilidad mientras que `DesiredCapacity` sigue a la demanda — que es exactamente por lo que confundirlas lleva a flotas con `MinSize=1` que escalan hermosamente y fallan por completo.

**Q9.2** — **"Stop guessing your capacity needs."** Reemplaza el **gasto de capital (CapEx)** — comprar hardware dimensionado para el pico con años de anticipación y amortizarlo — por **gasto operativo (OpEx)**, pagando por la capacidad consumida a medida que la demanda se revela. Los modos de fallo eliminados son las dos conjeturas simétricas: sobreaprovisionar (capital ocioso) y subaprovisionar (negocio perdido).

**Q9.3** — **Diseñar para el fallo: fila 3.** La arquitectura asume que los componentes van a morir y los reparte entre dominios de fallo independientes *antes* de que algo falle, que es la definición del principio. La segunda opción es la fila 5 (game days), pero eso *verifica* el diseñar para el fallo en vez de serlo — no podés ensayar una recuperación que nunca se diseñó. **Pensar en paralelo: fila 2.** Dividir un trabajo en 500 fragmentos simultáneos es el principio en su forma más pura. La segunda opción es la fila 4, pero escalar una flota para igualar la demanda es elasticidad: las instancias están atendiendo solicitudes *diferentes*, no cooperando en un solo trabajo. El paralelismo descompone una única unidad de trabajo; la elasticidad dimensiona la capacidad para muchas.

**Q9.4** — Cualquiera de: adoptar **servicios gestionados y serverless** para que la utilización se agrupe entre clientes en vez de quedar ociosa en tu cuenta; migrar a **tipos de instancia más eficientes en energía** como Graviton; aplicar **políticas de ciclo de vida de S3** para mover datos fríos a clases de almacenamiento más frías y eliminar lo que no tiene dueño; **dimensionar correctamente** instancias sobreaprovisionadas (la fila 7 otra vez, desde el ángulo de la sostenibilidad); reducir los datos transferidos comprimiendo las cargas útiles y usando caché en el borde con CloudFront. Cada uno reduce los recursos aprovisionados por unidad de trabajo entregado, que es la medida real del pilar de Sostenibilidad.

</details>

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- General design principles — https://docs.aws.amazon.com/wellarchitected/latest/framework/general-design-principles.html
- Operational Excellence pillar — https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html
- Security pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- Reliability pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- Performance Efficiency pillar — https://docs.aws.amazon.com/wellarchitected/latest/performance-efficiency-pillar/welcome.html
- Cost Optimization pillar — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Sustainability pillar — https://docs.aws.amazon.com/wellarchitected/latest/sustainability-pillar/sustainability-pillar.html
- AWS Well-Architected Tool User Guide — https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
- AWS CLI reference, `wellarchitected` — https://docs.aws.amazon.com/cli/latest/reference/wellarchitected/
- Regions and Availability Zones (EC2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Target tracking scaling policies — https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Amazon SQS Developer Guide — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
- SQS visibility timeout — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- SQS dead-letter queues — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- Best practices design patterns: optimizing Amazon S3 performance — https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html
- AWS CLI S3 configuration — https://docs.aws.amazon.com/cli/latest/topic/s3-config.html
- AWS CloudFormation User Guide — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html
- Detecting unmanaged configuration changes (drift) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- AWS Fault Injection Service User Guide — https://docs.aws.amazon.com/fis/latest/userguide/what-is.html
- Service Quotas User Guide — https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
- Amazon CloudWatch User Guide — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html