# 1.3 — Comprender los beneficios y las estrategias de migración a la nube de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Dominio 1 — Conceptos de nube · Enunciado de tarea 1.3 · Peso en el examen: 6.0**

---

## 1. El problema en producción: una migración es una transición coordinada distribuida, no una copia

El modelo mental ingenuo de una migración es `rsync` más un cambio de DNS. El modelo que sobrevive al contacto con producción es este:

> Una migración es una **secuencia de transiciones coordinadas sobre un grafo de dependencias que no conocés del todo**, ejecutada dentro de una **ventana de cambio finita**, contra **datos que siguen cambiando mientras los copiás**, con una **vía de rollback que se degrada a cero en el momento en que el destino empieza a aceptar escrituras**.

Toda decisión difícil de este enunciado de tarea se desprende de cuatro restricciones físicas.

### 1.1 Gravedad de los datos — la copia no es instantánea

La replicación compite con la aplicación por el mismo enlace de salida. La condición de convergencia para cualquier herramienta de replicación continua (MGN, CDC de DMS, ejecuciones programadas de DataSync, búfer de carga de Storage Gateway) es:

```
sustained_replication_bandwidth  >  daily_change_rate / seconds_per_day
```

Concretamente, un parque de 40 TB con una tasa de cambio de 500 GB/día necesita:

```
(500 × 10^9 bytes × 8 bits) / 86400 s = 46.3 Mbps  ← steady-state floor
```

...*antes* de la sincronización inicial completa, *antes* de la sobrecarga de protocolo y *antes* del tráfico propio de la aplicación. Aprovisioná ≈2× el piso, o la replicación entra en el estado que AWS nombra literalmente: `NOT_CONVERGING`. La sincronización inicial de esos mismos 40 TB sobre un enlace de 1 Gbps al 80 % de goodput son 3,7 días de transferencia continua — por eso la pregunta "¿debería enviar medios físicos?" es aritmética, no preferencia (§6.4).

### 1.2 El grafo de dependencias no está documentado

La CMDB está mal. Siempre está mal. El trabajo por lotes de 12 años de antigüedad que resuelve una IP hardcodeada, el montaje NFS que nadie reclama, el servidor de licencias fijado a una dirección MAC — estos se descubren **observando el tráfico**, no leyendo una planilla. Esta es la razón entera por la que existe AWS Application Discovery Service y por la que su salida es un *grafo de conexiones de red* (§4.3), no un inventario.

### 1.3 La ventana de transición es un límite duro de SLO

No podés "volver a intentarlo la semana que viene". La ventana está acotada por el negocio, y dentro de ella tenés que: aquietar las escrituras, drenar las transacciones en vuelo, verificar que aterrizó el último delta, cambiar la resolución, validar y decidir go/no-go. Cada estrategia de la §3 es fundamentalmente una apuesta sobre **cuánto de esa ventana gastás** y **cuánto podés deshacer después**.

### 1.4 El rollback tiene fecha de vencimiento

Una vez que la base de datos de destino acepta una sola escritura que el origen no vio, "volver a on-prem" significa *perder esa escritura*, salvo que hayas construido replicación inversa. Las migraciones serias configuran **CDC bidireccional** (o al menos una tarea DMS inversa) *antes* de la transición, precisamente para que la decisión de rollback siga disponible durante 24–72 h. Este es el paso que más se saltea en los programas reales.

---

## 2. AWS Cloud Adoption Framework (CAF) — el modelo operativo alrededor de la tecnología

CAF es lo que el examen espera que nombres cuando la pregunta es "cómo se *prepara* una organización", en contraposición a "cómo se *mueve* una aplicación". Deliberadamente no es un framework tecnológico.

### 2.1 Las seis perspectivas

| Perspectiva | Es dueña de | Capacidades representativas | Lectura SRE/Plataforma |
|---|---|---|---|
| **Business** | Realización de valor | Gestión de estrategia, gestión de portafolio, gestión de producto, business insights | El caso de negocio; dónde están realmente el dinero y el riesgo |
| **People** | Cultura y habilidades | Evolución cultural, liderazgo transformacional, transformación de la fuerza laboral, capacitación | Quién opera la plataforma en el día 2; cambio del modelo de guardias |
| **Governance** | Riesgo y control | Gestión de programas/beneficios, gestión de riesgos, cloud financial management, curación de datos | FinOps, estrategia de etiquetado, chargeback, guardrails |
| **Platform** | Fundación tecnológica | Arquitectura de plataforma, arquitectura de datos, CI/CD, desarrollo de aplicaciones modernas | Landing zone, red, identidad, golden paths |
| **Security** | Confidencialidad/integridad/disponibilidad | IAM, detección de amenazas, gestión de vulnerabilidades, respuesta a incidentes, seguridad de aplicaciones | Guardrails, controles detectivos, break-glass |
| **Operations** | Entrega de servicio | Observabilidad, gestión de eventos/incidentes/problemas, disponibilidad y continuidad, rendimiento | SLOs, alertado, runbooks, error budgets |

Mnemotecnia: **B-P-G-P-S-O** → *"Business People Govern Platforms Securely, Operationally."*

### 2.2 Los cuatro dominios de transformación

**Technology** (migrar y modernizar) · **Process** (digitalizar y automatizar) · **Organization** (reorganizar los equipos alrededor de productos) · **Product** (nuevas líneas de ingresos).

El punto de examen que más se pasa por alto: CAF dice explícitamente que la tecnología por sí sola no entrega valor. Un rehost perfecto con el mismo proceso de comité de aprobación de cambios da costos de nube *más* el lead time viejo.

### 2.3 Las cuatro fases

| Fase | Pregunta que responde | Artefacto concreto |
|---|---|---|
| **Envision** | ¿Dónde crea la nube valor de negocio? | Oportunidades de transformación priorizadas y mapeadas a las perspectivas |
| **Align** | ¿Qué brechas y dependencias lo bloquean? | Análisis de brechas de capacidades, alineación de stakeholders, plan de acción CAF |
| **Launch** | ¿Funciona en producción, en pequeño? | Pilotos en producción — no pruebas de concepto en un laboratorio |
| **Scale** | ¿Podemos repetirlo a escala de portafolio? | Pilotos ampliados, valor sostenido, fábrica de migración |

### 2.4 El proceso de migración de tres fases (el submodelo del dominio tecnológico)

| Fase | Objetivo | Herramientas | Criterios de salida |
|---|---|---|---|
| **Assess** | Caso de negocio, preparación | Migration Evaluator, Migration Readiness Assessment (MRA), Cloud Value Framework | Caso de TCO firmado, modelo operativo objetivo acordado |
| **Mobilize** | Cerrar brechas, construir la fundación | Landing zone / Control Tower, Application Discovery Service, Migration Hub, mejora de habilidades | Landing zone en vivo, grafo de dependencias construido, plan de olas publicado, piloto migrado |
| **Migrate & Modernize** | Ejecutar a escala | MGN, DMS+SCT, DataSync, Snow Family, Refactor Spaces | Olas transicionadas, origen dado de baja, backlog de modernización abierto |

> **Trampa de examen:** el piloto pertenece a *Mobilize*, no a *Migrate*. Mobilize es donde se construye la fábrica de migración en sí.

---

## 3. Las 7 R — estrategias de migración con compensaciones reales

### 3.1 Definiciones

| R | Qué pasa realmente | Criterio binario que lo decide |
|---|---|---|
| **Retire** | Dar de baja. Apagarlo. | Nadie se autenticó en 90 días |
| **Retain** | Dejarlo donde está (por ahora) | Fijación regulatoria, dongle de hardware, EOL inminente, dependencia irresoluble |
| **Rehost** | Lift-and-shift: mismo SO, mismos binarios, nuevo hipervisor (EC2) | El origen es una VM/servidor físico con almacenamiento de bloques |
| **Relocate** | Mover el hipervisor, no el guest (parques basados en VMware → VMware en AWS) | Parque vSphere, herramientas tipo vMotion disponibles |
| **Repurchase** | Abandonar la app, comprar SaaS | Existe una función commodity como SaaS (CRM, correo, ITSM) |
| **Replatform** | Lift-and-*reshape*: mantener el código, cambiar un componente por uno gestionado | BD/cola/LB autogestionados con un equivalente gestionado |
| **Refactor / Re-architect** | Reescribir para arquitectura cloud-native | La arquitectura actual es la restricción sobre el negocio |

### 3.2 Matriz de compensaciones

| Estrategia | Esfuerzo de migración | Riesgo de transición | Tiempo hasta el valor | TCO continuo | Beneficio cloud-native | Facilidad de rollback | Factor típico de costo unitario |
|---|---|---|---|---|---|---|---|
| Retire | Muy bajo | Muy bajo | Inmediato | **Negativo (ahorro)** | n/a | n/a | Solo el trabajo de dar de baja |
| Retain | Ninguno | Ninguno | Ninguno | Sin cambios | Ninguno | n/a | Costo de DC continuado |
| Relocate | Bajo | Bajo | Días–semanas | Moderado | Muy bajo | Alta (vMotion de vuelta) | Licenciamiento por host |
| Rehost | Bajo | Bajo–medio | Semanas | Moderado (EC2 + EBS, el mismo desperdicio) | Bajo | Alta (origen mantenido caliente) | Deuda de right-sizing |
| Repurchase | Medio (datos + integración) | Medio | Semanas–meses | Suscripción predecible | Alto (problema de otro) | **Baja** (datos migrados fuera de tu modelo) | Licencia por asiento |
| Replatform | Medio | Medio | Semanas–meses | **Bueno** (operación gestionada absorbida) | Medio–alto | Media (necesita CDC inverso) | Dimensionamiento de la instancia del servicio gestionado |
| Refactor | **Muy alto** | Alto | Meses–trimestres | Mejor a largo plazo, peor a corto plazo | El más alto | **Muy baja** | Tiempo de ingeniería |

### 3.3 La economía de *no* refactorizar primero

El modo de falla de los programas ambiciosos es refactorizar durante la migración. Ahí quedan acoplados dos riesgos independientes: "¿funcionó la mudanza?" y "¿funcionó la reescritura?". Una transición fallida no se puede atribuir. La propia guía prescriptiva de AWS es contundente sobre la secuencia:

**Rehost/Replatform para salir del datacenter → estabilizar → refactorizar con la fecha límite del datacenter fuera del camino crítico.**

El contraargumento que sobrevive: refactorizar *primero* cuando la aplicación no puede correr en EC2 en absoluto (solo 32 bits, hardware exótico, SO no soportado), o cuando la carga de trabajo es tan explosiva que el lift-and-shift cuesta más que on-prem (rehostear 1:1 un parque aprovisionado para el pico reproduce el desperdicio del aprovisionamiento por pico en una factura medida).

### 3.4 Árbol de decisión

```
                          ┌─ Still used?  ── no ──▶ RETIRE
                          │
                          ├─ Must stay (regulatory / hardware / EOL soon)? ── yes ──▶ RETAIN
                          │
   Application ───────────┼─ Commodity function with a SaaS equivalent? ── yes ──▶ REPURCHASE
                          │
                          ├─ Whole vSphere estate, deadline-driven, no time? ── yes ──▶ RELOCATE
                          │
                          ├─ Architecture itself blocks the business
                          │  AND budget/time exist?                  ── yes ──▶ REFACTOR
                          │
                          ├─ Self-managed DB / queue / LB / web tier
                          │  with a managed equivalent?              ── yes ──▶ REPLATFORM
                          │
                          └─ Otherwise                                       ──▶ REHOST
```

### 3.5 Replatform: el movimiento de mayor rendimiento por unidad de riesgo

El conjunto canónico de replatform, y qué compra cada uno:

| Desde | Hacia | Carga operativa eliminada | Trabajo residual |
|---|---|---|---|
| MySQL/PostgreSQL autogestionado en EC2 | Amazon RDS / Aurora | Parcheo, backups, failover, actualizaciones de versión menor | Cadena de conexión, paridad de parameter group, sin acceso al SO |
| Flota de proxy inverso Apache/NGINX | ALB / NLB | Parcheo del LB, HA de la capa de LB | Semántica de health check, sesiones sticky |
| RabbitMQ / ActiveMQ autogestionado | Amazon MQ | Operación del broker, clustering | Paridad de versión de protocolo |
| Cron en un servidor mascota | EventBridge Scheduler + Lambda/ECS | El servidor mascota | Idempotencia, límites de timeout |
| Filer NFS | Amazon EFS / FSx | Hardware del filer, planificación de capacidad | Semántica POSIX, perfil de latencia |
| Kubernetes autogestionado | Amazon EKS | Operación del control plane, etcd | Recableado de CNI/CSI, IRSA |

---

## 4. Assess y Mobilize: construir el plan de olas a partir de evidencia

### 4.1 Fijar la home region de Migration Hub (hacelo primero — es de una sola vía por cuenta)

```console
$ aws migrationhub-config create-home-region-control \
    --home-region eu-west-1 \
    --target Type=ACCOUNT,Id=123456789012
{
    "HomeRegionControl": {
        "ControlId": "hrc-0a4f27c9b1e6d3852",
        "HomeRegion": "eu-west-1",
        "Target": {
            "Type": "ACCOUNT",
            "Id": "123456789012"
        },
        "RequestedTime": "2026-09-03T09:14:07.412000+00:00"
    }
}

$ aws migrationhub-config get-home-region
{
    "HomeRegion": "eu-west-1"
}
```

> La home region es donde Migration Hub almacena los datos de descubrimiento y de seguimiento de la migración. Las migraciones en sí pueden apuntar a cualquier región; los *metadatos* quedan fijados. Elegirla mal significa un caso de soporte, no un flag de CLI.

### 4.2 Descubrimiento: sin agente vs con agente

| | **Agentless Collector** (OVA en vCenter) | **Discovery Agent** (instalado por host) |
|---|---|---|
| Despliegue | Un OVA por vCenter | Paquete en cada servidor Linux/Windows |
| Ve | Inventario de VMs, utilización de CPU/RAM/disco, throughput de red a nivel de VM | CPU/RAM/disco/red por proceso, **conexiones TCP con puertos y PIDs**, paquetes instalados |
| ¿Construye un grafo de dependencias? | **No** (solo utilización) | **Sí** — ese es el punto |
| También recolecta | Inventario de bases de datos (módulo DMS Fleet Advisor) | — |
| Costo de despliegue | Muy bajo | Alto (control de cambios × N hosts) |
| ¿Requiere acceso al SO guest? | No | Sí |
| Usar cuando | Dimensionamiento/TCO de un parque vSphere | Necesitás planificación de olas y análisis de radio de impacto |

**Patrón práctico:** sin agente en todas partes para el caso de negocio; agentes en el ~15 % de los hosts que son hubs de integración, servicios compartidos y cualquier cosa que no puedas explicar.

```console
$ aws discovery describe-agents --max-results 5 \
    --query 'agentsInfo[].[agentId,hostName,agentType,health,version]' --output text
o-0f1c2d3e4a5b6c7d8   ora-prd-01        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0a9b8c7d6e5f4a3b2   app-prd-04        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0c3d4e5f6a7b8c9d0   app-prd-05        AWS_LINUX_AGENT   HEALTHY     2.3.1214.0
o-0e5f6a7b8c9d0e1f2   win-batch-02      AWS_WINDOWS_AGENT  UNHEALTHY  2.3.1214.0
o-0b2c3d4e5f6a7b8c9   nfs-filer-01      AWS_LINUX_AGENT   SHUTDOWN    2.3.1214.0

$ aws discovery start-continuous-export
{
    "exportId": "export-0d8e7f6a5b4c3d2e1",
    "s3Bucket": "aws-application-discovery-service-a1b2c3d4",
    "schemaStorageConfig": {
        "databaseName": "application_discovery_service_database"
    },
    "startTime": "2026-09-03T09:31:44.008000+00:00",
    "dataSource": "AGENT"
}
```

### 4.3 Convertir datos de conexión en olas (Athena sobre el export de discovery)

La exportación continua deposita los datos de los agentes en S3 y registra tablas de Glue. El grafo de dependencias está a una consulta de distancia:

```sql
-- Cross-server TCP dependency edges observed in the last 14 days,
-- excluding ephemeral client ports and loopback.
WITH edges AS (
    SELECT
        src.host_name              AS source_host,
        dst.host_name              AS destination_host,
        o.destination_port         AS port,
        COUNT(*)                   AS observations
    FROM   outbound_connection_agent o
    JOIN   os_info_agent            src ON src.agent_id = o.agent_id
    JOIN   network_interface_agent  ni  ON ni.ip_address = o.destination_ip
    JOIN   os_info_agent            dst ON dst.agent_id = ni.agent_id
    WHERE  o.destination_ip NOT LIKE '127.%'
      AND  o.destination_port < 32768
      AND  from_iso8601_timestamp(o.agent_assigned_process_id) IS NOT NULL
    GROUP  BY 1, 2, 3
)
SELECT   source_host, destination_host, port, observations
FROM     edges
WHERE    source_host <> destination_host
ORDER BY observations DESC
LIMIT    200;
```

**Reglas de planificación de olas que salen de este grafo:**

1. Una **ola es una componente conexa** del grafo, no la lista de servidores de un equipo. Si A habla con B, A y B se mueven juntos o aceptás latencia entre datacenters durante el intervalo entre ambos.
2. **Los servicios compartidos se mueven primero** (DNS, LDAP/AD, NTP, servidores de licencias, monitoreo, repositorios de artefactos) — o cada ola posterior tiene una dependencia híbrida.
3. **Las aristas entre olas se vuelven riesgos explícitos** con una mitigación nombrada: enlace híbrido, proxy inverso temporal, o "aceptamos +8 ms de RTT durante 6 días".
4. **El tamaño de la ola está acotado por la capacidad de rollback**, no por la ambición. Si tu equipo puede validar 12 aplicaciones en una ventana de 6 horas, la ola es de 12 aplicaciones.

### 4.4 Migration Evaluator vs Migration Hub — la distinción que el examen evalúa

| Servicio | Responde | Salida | Costo |
|---|---|---|---|
| **Migration Evaluator** | *¿Deberíamos? ¿Cuánto va a costar?* | Caso de negocio direccional/detallado, proyecciones de EC2/RDS dimensionadas correctamente, comparación de TCO on-prem vs AWS, BYOL vs licencia incluida | Gratis (engagement conducido por AWS) |
| **AWS Application Discovery Service** | *¿Qué tenemos y cómo está cableado?* | Inventario de servidores, utilización, datos de dependencias de red | Gratis (se factura el almacenamiento de S3/Athena) |
| **AWS Migration Hub** | *¿Dónde está todo dentro del proceso?* | Panel único de estado de migración a través de MGN, DMS y herramientas de socios; agrupación de aplicaciones; Strategy Recommendations | Gratis (se facturan los servicios subyacentes) |

---

## 5. Infraestructura completa — entorno de staging de MGN (CloudFormation)

Esta es la fundación sobre la que aterriza cada ola de rehost. Es intencionalmente completa: VPC, subredes de staging, los security groups del plano de datos, endpoints de VPC para que el tráfico del plano de control evite internet, la plantilla de configuración de replicación que heredan los nuevos servidores de origen, y la plantilla de lanzamiento que gobierna las instancias de destino.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Rehost staging environment for AWS Application Migration Service (MGN).
  Creates the staging-area VPC, the replication-server subnets, the data-plane
  security groups (TCP 1500 from source servers), VPC endpoints that keep the
  MGN/EC2/S3 control plane off the public internet, and the replication +
  launch configuration templates inherited by every newly registered
  source server. Deploy ONCE per target region, BEFORE installing any agent.

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026
    Description: Value applied as the "migration-wave-project" tag on every resource.

  VpcCidr:
    Type: String
    Default: 10.60.0.0/16
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
    Description: CIDR of the staging VPC. MUST NOT overlap the on-premises estate.

  StagingSubnetCidrA:
    Type: String
    Default: 10.60.0.0/22

  StagingSubnetCidrB:
    Type: String
    Default: 10.60.4.0/22

  EgressSubnetCidrA:
    Type: String
    Default: 10.60.240.0/24

  OnPremisesCidr:
    Type: String
    Default: 172.20.0.0/14
    Description: >-
      Aggregate CIDR of the source servers. Only these addresses may open the
      TCP 1500 replication data plane. Reached over Direct Connect or VPN.

  ReplicationServerInstanceType:
    Type: String
    Default: t3.small
    AllowedValues: [t3.small, t3.medium, t3.large, m5.large, m5.xlarge]
    Description: >-
      One replication server serves up to 15 source-server disks. t3.small is
      the AWS default and is adequate below ~120 Mbps aggregate ingest.

  BandwidthThrottlingMbps:
    Type: Number
    Default: 0
    MinValue: 0
    MaxValue: 10000
    Description: >-
      Per-source-server ceiling in Mbps. 0 disables throttling. Set this
      deliberately: uncapped initial sync will saturate the Direct Connect VIF
      and page the network team.

  DefaultLargeStagingDiskType:
    Type: String
    Default: GP3
    AllowedValues: [GP2, GP3, ST1]
    Description: >-
      Volume type for staging disks larger than 500 GiB. ST1 is cheapest but
      throughput-optimised for sequential I/O; GP3 gives predictable IOPS for
      snapshot creation. Use ST1 only for cold, very large volumes.

  StagingVolumeKmsKeyArn:
    Type: String
    Default: ''
    Description: >-
      Optional customer-managed KMS key ARN for staging EBS volumes. Empty
      string uses the EBS default key.

Conditions:

  UseCustomKmsKey: !Not [!Equals [!Ref StagingVolumeKmsKeyArn, '']]
  ThrottleEnabled:  !Not [!Equals [!Ref BandwidthThrottlingMbps, 0]]

Resources:

  # ------------------------------------------------------------------ network

  StagingVpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-vpc'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-igw'

  IgwAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref StagingVpc
      InternetGatewayId: !Ref InternetGateway

  EgressSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref EgressSubnetCidrA
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-egress-a'

  StagingSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref StagingSubnetCidrA
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-a'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  StagingSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref StagingVpc
      CidrBlock: !Ref StagingSubnetCidrB
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-staging-b'

  NatEip:
    Type: AWS::EC2::EIP
    DependsOn: IgwAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-nat-eip'

  NatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEip.AllocationId
      SubnetId: !Ref EgressSubnetA
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-nat'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref StagingVpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-rt-egress'

  DefaultPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: IgwAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  EgressSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref EgressSubnetA
      RouteTableId: !Ref PublicRouteTable

  StagingRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref StagingVpc
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-rt-staging'

  StagingDefaultRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref StagingRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway

  StagingSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref StagingSubnetA
      RouteTableId: !Ref StagingRouteTable

  StagingSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref StagingSubnetB
      RouteTableId: !Ref StagingRouteTable

  # ------------------------------------------------------------ VPC endpoints
  # Keeps agent -> service control-plane traffic inside the AWS network when
  # DataPlaneRouting is PRIVATE_IP. The S3 gateway endpoint is mandatory in
  # practice: the replication server downloads its software from S3.

  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: HTTPS from the staging VPC to interface VPC endpoints
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref VpcCidr
          Description: HTTPS from staging subnets
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: !Ref OnPremisesCidr
          Description: HTTPS from source servers over DX/VPN
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 0.0.0.0/0
          Description: Unrestricted egress
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-vpce-sg'

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref StagingRouteTable

  MgnInterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.mgn'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds:
        - !Ref StagingSubnetA
        - !Ref StagingSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup

  Ec2InterfaceEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref StagingVpc
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2'
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds:
        - !Ref StagingSubnetA
        - !Ref StagingSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup

  # ----------------------------------------------------------- security groups
  # MGN data plane:
  #   source server  --TCP 1500-->  replication server   (block-level replica)
  #   replication srv --TCP 443-->  mgn + s3 endpoints   (control plane)

  ReplicationServerSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: >-
        MGN replication servers. Ingress TCP 1500 from source servers only.
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 1500
          ToPort: 1500
          CidrIp: !Ref OnPremisesCidr
          Description: AWS Replication Agent block-level data plane
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: MGN and S3 control plane
        - IpProtocol: tcp
          FromPort: 1500
          ToPort: 1500
          CidrIp: !Ref VpcCidr
          Description: Replication server to replication server
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-replication-sg'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # Self-referencing rule added separately: a security group cannot reference
  # itself inside its own SecurityGroupIngress block.
  ReplicationServerSelfIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref ReplicationServerSecurityGroup
      IpProtocol: tcp
      FromPort: 1500
      ToPort: 1500
      SourceSecurityGroupId: !Ref ReplicationServerSecurityGroup
      Description: Replication server mesh

  TestInstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: >-
        Launched test instances. Deliberately isolated from production:
        no ingress from on-premises, egress restricted to HTTPS.
      VpcId: !Ref StagingVpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: !Ref VpcCidr
          Description: SSH from within the staging VPC only
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: SSM / package repos
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-mgn-test-sg'

  # ------------------------------------------------------------------ IAM
  # Credentials used by the AWS Replication Agent installer on source servers.
  # Scope: agent registration only. Rotate after each wave; never reuse across
  # accounts. Prefer IAM Roles Anywhere or SSM hybrid activations where the
  # source estate supports it.

  ReplicationAgentInstallUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Sub '${ProjectTag}-mgn-agent-installer'
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AWSApplicationMigrationAgentPolicy
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  LaunchInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-mgn-launched-instance-role'
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

  LaunchInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${ProjectTag}-mgn-launched-instance-profile'
      Roles:
        - !Ref LaunchInstanceRole

  # ------------------------------------------------- MGN replication template
  # Inherited by EVERY source server registered in this region after the
  # template exists. Changing it does not retroactively change already
  # registered servers - those keep their own replication settings.

  ReplicationConfigurationTemplate:
    Type: AWS::MGN::ReplicationConfigurationTemplate
    Properties:
      AssociateDefaultSecurityGroup: false
      BandwidthThrottling: !Ref BandwidthThrottlingMbps
      CreatePublicIP: false
      DataPlaneRouting: PRIVATE_IP
      DefaultLargeStagingDiskType: !Ref DefaultLargeStagingDiskType
      EbsEncryption: !If [UseCustomKmsKey, CUSTOM, DEFAULT]
      EbsEncryptionKeyArn: !If
        - UseCustomKmsKey
        - !Ref StagingVolumeKmsKeyArn
        - !Ref AWS::NoValue
      ReplicationServerInstanceType: !Ref ReplicationServerInstanceType
      ReplicationServersSecurityGroupsIDs:
        - !Ref ReplicationServerSecurityGroup
      StagingAreaSubnetId: !Ref StagingSubnetA
      StagingAreaTags:
        Name: !Sub '${ProjectTag}-mgn-staging-resource'
        migration-wave-project: !Ref ProjectTag
        cost-center: platform-migration
      UseDedicatedReplicationServer: false
      Tags:
        migration-wave-project: !Ref ProjectTag

  # ------------------------------------------------------ MGN launch template
  # Governs what the TEST and CUTOVER instances look like.

  LaunchConfigurationTemplate:
    Type: AWS::MGN::LaunchConfigurationTemplate
    Properties:
      AssociatePublicIpAddress: false
      BootMode: LEGACY_BIOS
      CopyPrivateIp: false
      CopyTags: true
      EnableMapAutoTagging: true
      MapAutoTaggingMpeID: MPE-1234567890
      LaunchDisposition: STOPPED
      TargetInstanceTypeRightSizingMethod: BASIC
      Licensing:
        OsByol: false
      SmallVolumeMaxSize: 500
      SmallVolumeConf:
        VolumeType: gp3
        Iops: 3000
        Throughput: 125
      LargeVolumeConf:
        VolumeType: gp3
        Iops: 6000
        Throughput: 250
      PostLaunchActions:
        Deployment: TEST_AND_CUTOVER
        S3LogBucket: !Sub 'aws-mgn-postlaunch-logs-${AWS::AccountId}-${AWS::Region}'
        S3OutputKeyPrefix: !Sub '${ProjectTag}/post-launch/'
        SsmDocuments:
          - ActionName: install-cloudwatch-agent
            SsmDocumentName: AWSMigration-InstallCloudWatchAgent
            TimeoutSeconds: 900
            MustSucceedForCutover: false
          - ActionName: validate-disk-space
            SsmDocumentName: AWSMigration-ValidateDiskSpace
            TimeoutSeconds: 300
            MustSucceedForCutover: true
      Tags:
        migration-wave-project: !Ref ProjectTag

Outputs:

  StagingVpcId:
    Description: Staging VPC ID
    Value: !Ref StagingVpc
    Export:
      Name: !Sub '${AWS::StackName}-StagingVpcId'

  StagingSubnetAId:
    Description: Subnet the MGN replication servers launch into
    Value: !Ref StagingSubnetA
    Export:
      Name: !Sub '${AWS::StackName}-StagingSubnetAId'

  ReplicationSecurityGroupId:
    Description: Security group attached to MGN replication servers
    Value: !Ref ReplicationServerSecurityGroup
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationSecurityGroupId'

  AgentInstallUserName:
    Description: >-
      IAM user whose access keys the AWS Replication Agent installer consumes.
      Create the keys out of band; never place them in the template.
    Value: !Ref ReplicationAgentInstallUser

  ReplicationTemplateId:
    Description: MGN replication configuration template ID
    Value: !Ref ReplicationConfigurationTemplate
```

### 5.1 Desplegar e instalar agentes

```console
$ aws cloudformation deploy \
    --template-file mgn-staging.yaml \
    --stack-name dc-exit-2026-mgn-staging \
    --parameter-overrides \
        ProjectTag=dc-exit-2026 \
        OnPremisesCidr=172.20.0.0/14 \
        BandwidthThrottlingMbps=400 \
    --capabilities CAPABILITY_NAMED_IAM \
    --region eu-west-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - dc-exit-2026-mgn-staging

$ aws cloudformation describe-stacks \
    --stack-name dc-exit-2026-mgn-staging \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
AgentInstallUserName          dc-exit-2026-mgn-agent-installer
ReplicationSecurityGroupId    sg-0f3a91c7d5e42b806
ReplicationTemplateId         mgn-replication-template-0c9d8e7f6a5b4c3d2
StagingSubnetAId              subnet-0a7b6c5d4e3f2a1b0
StagingVpcId                  vpc-093f2a71c8b6d5e40
```

En un servidor de origen (Linux):

```console
[root@ora-prd-01 ~]# wget -O ./aws-replication-installer-init \
      https://aws-application-migration-service-eu-west-1.s3.eu-west-1.amazonaws.com/latest/linux/aws-replication-installer-init
[root@ora-prd-01 ~]# chmod +x ./aws-replication-installer-init
[root@ora-prd-01 ~]# ./aws-replication-installer-init \
      --region eu-west-1 \
      --aws-access-key-id AKIAIOSFODNN7EXAMPLE \
      --aws-secret-access-key <redacted> \
      --no-prompt
The installation of the AWS Replication Agent has started.
Identifying volumes for replication.
Identified volume for replication: /dev/sda of size 100 GiB
Identified volume for replication: /dev/sdb of size 2000 GiB
All volumes for replication were successfully identified.
Downloading the AWS Replication Agent onto the source server... Finished.
Installing the AWS Replication Agent onto the source server... Finished.
Syncing the source server with the AWS Application Migration Service Console...
Finished.
The following is the source server ID: s-0b4c8e2f9a1d73650.
You now have 1 active source server out of your 10000 licenses.
Learn more about using the AWS Application Migration Service Console
in the following URL:
https://eu-west-1.console.aws.amazon.com/mgn/home?region=eu-west-1#/sourceServers
```

> **Notá los dos volúmenes identificados.** MGN replica *dispositivos de bloque completos*. Un `/dev/sdb` de 2 TiB usado al 4 % igual transfiere 2 TiB de bloques en la sincronización inicial, salvo que el sistema de archivos soporte la detección de regiones dispersas del agente. Reducí o excluí los volúmenes gordos *antes* de la ola, no durante.

---

## 6. Servicios de movimiento de datos: elegir el caño correcto

### 6.1 Matriz de comparación

| Servicio | Mueve | Protocolo en el origen | ¿Continuo? | Techo | Mejor para | No para |
|---|---|---|---|---|---|---|
| **AWS Application Migration Service (MGN)** | Servidores enteros (nivel de bloque) | Agente → TCP 1500 | Sí (CDC a nivel de bloque) | Limitado por el enlace | Rehost de VMs/servidores físicos | Bases de datos que pensás replatformar |
| **AWS DMS** | Filas de bases de datos | Protocolo nativo de la BD | Sí (CDC) | Limitado por instancia + enlace | Migración de BD homogénea y heterogénea con downtime casi nulo | Archivos no estructurados a granel |
| **AWS DataSync** | Archivos y objetos | NFS, SMB, HDFS, objetos compatibles con S3 | Programado, incremental | ~10 Gbps por tarea | Sincronización repetida de conjuntos de archivos, NAS on-prem → EFS/FSx/S3 | Dispositivos de bloque en vivo |
| **AWS Transfer Family** | Archivos empujados *por socios* | SFTP / FTPS / FTP / AS2 | Bajo demanda | Por conexión | Reemplazar un parque de transferencia de archivos gestionada | Migración interna a granel |
| **AWS Storage Gateway** | Acceso híbrido, no una mudanza de una sola vez | NFS/SMB (File GW), iSCSI (Volume GW), iSCSI VTL (Tape GW) | Cacheo y carga continuos | Limitado por enlace + caché | Mantener el acceso on-prem mientras los datos viven en AWS; reemplazo de cintas | Cualquier cosa donde querés que el origen desaparezca mañana |
| **AWS Snow Family** | Volumen offline | Endpoint local compatible con S3 / NFS | No | Envío físico | Escala de petabytes, enlaces finos/ausentes, sitios desconectados/edge | Cualquier cosa por debajo de unos pocos TB con un buen enlace |

### 6.2 Variantes de Storage Gateway

| Variante | Protocolo on-prem | Respaldado por | La caché local guarda | Uso canónico |
|---|---|---|---|---|
| **S3 File Gateway** | NFS v3/v4.1, SMB v2/v3 | Objetos S3 (1 archivo = 1 objeto) | Archivos usados recientemente | Migrar un NAS manteniendo la interfaz de archivos |
| **FSx File Gateway** | SMB | Amazon FSx for Windows File Server | Archivos usados recientemente | Acceso desde sucursales a un recurso compartido Windows central |
| **Volume Gateway — cached** | iSCSI | S3, con snapshots de EBS | Bloques calientes | Datos primarios en AWS, lecturas locales de baja latencia |
| **Volume Gateway — stored** | iSCSI | El disco local es el primario; backup asíncrono a S3 | El dataset completo local | Mantener todos los datos localmente, obtener DR fuera del sitio |
| **Tape Gateway (VTL)** | iSCSI VTL | S3 → S3 Glacier Flexible/Deep Archive | Cintas virtuales escritas recientemente | Retirar una biblioteca de cintas física sin cambiar el software de backup |

### 6.3 Snow Family

| Dispositivo | Capacidad utilizable (orden de magnitud) | Cómputo | Rol típico |
|---|---|---|---|
| **Snowcone / Snowcone SSD** | ~8 TB HDD / ~14 TB SSD | Pequeño (compatible con EC2) | Edge/rugerizado, espacio restringido, se puede enviar o usar DataSync |
| **Snowball Edge Storage Optimized** | Decenas de TB hasta ~210 TB | Sí | Transferencia de datos a granel, el caballo de batalla |
| **Snowball Edge Compute Optimized** | Decenas de TB | Mayor, GPU opcional | Cómputo edge desconectado + inferencia de ML |
| **Snowmobile** | Contenedor de envío de escala exabyte | n/a | Histórico: evacuación de datacenter a escala de 100 PB |

> **Advertencia de vigencia:** AWS redujo la línea Snow durante 2024–2025 — Snowmobile ya no se ofrece y las opciones de dispositivos individuales cambiaron. La guía del examen CLF-C02 todavía referencia la familia de forma genérica, así que conocé los *conceptos*. Antes de tomar una decisión de diseño real, confirmá la disponibilidad actual de dispositivos en el FAQ de Snow Family (ver Referencias).

### 6.4 El cálculo de enviar-o-transmitir

Tiempo de transferencia para una copia completa al 80 % de goodput:

```
days = (TB × 8 × 10^12 bits) / (link_bps × 0.8) / 86400
```

| Dataset | 100 Mbps | 500 Mbps | 1 Gbps | 10 Gbps |
|---|---|---|---|---|
| 10 TB | 11.6 d | 2.3 d | 1.2 d | 2.8 h |
| 50 TB | 57.9 d | 11.6 d | 5.8 d | 13.9 h |
| 100 TB | 115.7 d | 23.1 d | **11.6 d** | 1.2 d |
| 500 TB | 578.7 d | 115.7 d | 57.9 d | **5.8 d** |
| 1 PB | — | 231.5 d | 115.7 d | 11.6 d |

**Regla práctica, y de dónde sale:** si la copia por cable supera aproximadamente una semana, pedí dispositivos Snow. Un viaje de ida y vuelta de Snowball es ~1 semana de envío sin importar el tamaño, así que domina por debajo de ese umbral y gana por encima. Efectos de segundo orden que te empujan a Snow antes: el enlace se comparte con producción, la WAN se factura por GB, o el sitio de origen está famélico de ancho de banda por construcción (barco, plataforma petrolera, planta remota).

**Efecto de segundo orden que te empuja en la dirección contraria:** Snow te da una copia *en un punto en el tiempo*. Todo lo escrito durante el envío igual hay que ponerlo al día por cable. Snow casi siempre es la *semilla*, con DataSync o CDC de DMS haciendo el delta.

### 6.5 Ciclo de vida de un trabajo Snowball

```console
$ aws snowball create-job \
    --job-type IMPORT \
    --snowball-type EDGE_S \
    --shipping-option SECOND_DAY \
    --address-id ADID-0f2e1d3c4b5a69780 \
    --role-arn arn:aws:iam::123456789012:role/SnowballImportRole \
    --kms-key-arn arn:aws:kms:eu-west-1:123456789012:key/8f1c2b3a-4d5e-6f70-8192-a3b4c5d6e7f8 \
    --description 'dc-exit-2026 archive tier seed' \
    --resources '{
        "S3Resources": [
            {
                "BucketArn": "arn:aws:s3:::dc-exit-2026-archive-eu-west-1",
                "KeyRange": {"BeginMarker": "", "EndMarker": ""}
            }
        ]
    }'
{
    "JobId": "JID-0d7c6b5a4e3f21908"
}

$ aws snowball describe-job --job-id JID-0d7c6b5a4e3f21908 \
    --query 'JobMetadata.{state:JobState,type:SnowballType,created:CreationDate,tracking:ShippingDetails.OutboundShipment.TrackingNumber}'
{
    "state": "InTransitToCustomer",
    "type": "EDGE_S",
    "created": "2026-09-03T10:22:51.883000+00:00",
    "tracking": "1Z999AA10123456784"
}
```

Al llegar, desbloqueá el dispositivo y usá el endpoint local compatible con S3:

```console
$ snowballEdge unlock-device \
    --endpoint https://10.14.7.31 \
    --manifest-file JID-0d7c6b5a4e3f21908_manifest.bin \
    --unlock-code a1b2c-3d4e5-f6a7b-8c9d0-e1f2a
Unlock device returned: Device Unlocking

$ snowballEdge describe-device --endpoint https://10.14.7.31 \
    --manifest-file JID-0d7c6b5a4e3f21908_manifest.bin \
    --unlock-code a1b2c-3d4e5-f6a7b-8c9d0-e1f2a
{
  "DeviceId" : "JID-0d7c6b5a4e3f21908",
  "UnlockStatus" : { "State" : "UNLOCKED" },
  "ActiveNetworkInterface" : { "IpAddress" : "10.14.7.31" },
  "PhysicalNetworkInterfaces" : [ {
    "PhysicalNetworkInterfaceId" : "s.ni-8a1b2c3d4e5f60718",
    "PhysicalConnectorType" : "QSFP",
    "IpAddressAssignment" : "STATIC",
    "IpAddress" : "10.14.7.31",
    "Netmask" : "255.255.255.0",
    "DefaultGateway" : "10.14.7.1",
    "MacAddress" : "00:1e:67:aa:bb:cc"
  } ]
}

$ aws s3 cp /srv/archive/2019/ s3://dc-exit-2026-archive-eu-west-1/2019/ \
    --recursive \
    --endpoint http://10.14.7.31:8080 \
    --profile snowballEdge
upload: ../../srv/archive/2019/q1/ledger-000001.parquet to s3://dc-exit-2026-archive-eu-west-1/2019/q1/ledger-000001.parquet
upload: ../../srv/archive/2019/q1/ledger-000002.parquet to s3://dc-exit-2026-archive-eu-west-1/2019/q1/ledger-000002.parquet
...
Completed 41.8 TiB/41.8 TiB (612.4 MiB/s) with 0 file(s) remaining
```

---

## 7. Migración de bases de datos: DMS + SCT, stack completo

### 7.1 Homogénea vs heterogénea

| | Homogénea (Oracle → Oracle en RDS, MySQL → Aurora MySQL) | Heterogénea (Oracle → Aurora PostgreSQL, SQL Server → Aurora MySQL) |
|---|---|---|
| Conversión de esquema | No hace falta | **AWS SCT / DMS Schema Conversion** requerido |
| Código de la aplicación | Normalmente sin cambios | Procedimientos almacenados, SQL embebido, driver y dialecto cambian todos |
| Riesgo | Bajo | Alto — esto es un refactor disfrazado |
| Rol de DMS | Carga completa + CDC | Carga completa + CDC, *después* de la conversión del esquema |
| Duración típica | Semanas | Meses |
| Ahorro de licencias | Parcial | **Total** — el driver de negocio habitual |

**División del trabajo, con precisión:** SCT convierte **esquemas y objetos de código** (tablas, vistas, procedimientos, funciones, triggers), y produce un informe de evaluación que lista lo que no pudo convertir y el esfuerzo manual estimado. DMS mueve **datos**. DMS *no* migra por sí solo índices secundarios, secuencias, procedimientos, triggers ni claves foráneas — crea un esquema de destino mínimo, suficiente para aterrizar las filas. Suponer lo contrario es la sorpresa más común con DMS.

### 7.2 Prerrequisitos en el origen para CDC (los que realmente muerden)

| Motor de origen | Configuración requerida | Síntoma si falta |
|---|---|---|
| Oracle | `ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;` más `ALL COLUMNS` por tabla; modo ARCHIVELOG; acceso a LogMiner o Binary Reader | La carga completa tiene éxito, el CDC arranca, y luego las actualizaciones se aplican silenciosamente a las filas equivocadas o la tarea falla con `ORA-01291` |
| MySQL / MariaDB | `binlog_format=ROW`, `binlog_row_image=FULL`, `binlog_checksum=NONE` (versiones viejas), retención ≥ 24 h | El CDC no arranca, o aplica cambios a nivel de sentencia de forma no determinista |
| PostgreSQL | `wal_level=logical`, `max_replication_slots` ≥ tareas+1, `max_wal_senders` ≥ tareas+1, `pglogical` o el plugin nativo | La tarea no puede crear un slot de replicación; o un *slot obsoleto fija el WAL y llena el disco del origen* |
| SQL Server | Modelo de recuperación full o bulk-logged; CDC o MS-REPLICATION habilitado | El CDC no puede leer el log de transacciones |
| **Todos** | **Cada tabla replicada necesita una clave primaria o un índice único** | Las actualizaciones/borrados durante el CDC se convierten en escaneos de tabla completa o fallan directamente |

> La fila de PostgreSQL es un incidente de producción esperando ocurrir: una tarea DMS abandonada deja atrás un slot de replicación, el origen deja de reciclar el WAL, y la base de datos *de origen* — la que todavía atiende clientes — se queda sin disco. Siempre hacé `aws dms delete-replication-task` y después verificá que `pg_replication_slots` esté vacío.

### 7.3 Stack CloudFormation completo de DMS

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Heterogeneous database migration: Oracle 19c on-premises -> Aurora
  PostgreSQL, using AWS DMS with full-load + CDC and inline data validation.
  Assumes the schema has ALREADY been converted with AWS SCT / DMS Schema
  Conversion and applied to the target - DMS moves rows, not DDL.
  Assumes the account-level roles dms-vpc-role and dms-cloudwatch-logs-role
  exist (created once per account by the DMS console or the CLI).

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026

  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC hosting the replication instance and the Aurora cluster.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: >-
      At least two subnets in different AZs. Multi-AZ replication instances
      require this; single-AZ still requires a subnet group of two.

  OnPremOracleHost:
    Type: String
    Default: ora-prd-01.corp.internal
    Description: Resolvable over Direct Connect / VPN from the replication instance.

  OnPremOraclePort:
    Type: Number
    Default: 1521

  OnPremOracleServiceName:
    Type: String
    Default: ERPPRD

  OracleSecretArn:
    Type: String
    Description: >-
      Secrets Manager secret holding {"username":"...","password":"..."} for
      the Oracle CDC user. DMS reads it directly - no plaintext in the stack.

  AuroraSecretArn:
    Type: String
    Description: Secrets Manager secret for the Aurora PostgreSQL target user.

  AuroraWriterEndpoint:
    Type: String
    Description: Aurora PostgreSQL cluster WRITER endpoint (not the reader).

  AuroraDatabaseName:
    Type: String
    Default: erpprd

  ReplicationInstanceClass:
    Type: String
    Default: dms.c5.2xlarge
    AllowedValues:
      - dms.t3.medium
      - dms.t3.large
      - dms.c5.large
      - dms.c5.xlarge
      - dms.c5.2xlarge
      - dms.r5.2xlarge
    Description: >-
      c5 for CPU-bound transformation-heavy loads; r5 when CDC changes must be
      cached in memory to avoid spilling to disk (watch CDCChangesDiskTarget).
      t3 only for proofs of concept - burst credits exhaust mid-full-load.

  ReplicationInstanceStorageGiB:
    Type: Number
    Default: 200
    MinValue: 50
    MaxValue: 6144
    Description: >-
      Holds task logs and cached CDC changes that spill from memory. Undersizing
      this stalls CDC when the target cannot keep up with the source.

  MultiAz:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']

  EnableValidation:
    Type: String
    Default: 'true'
    AllowedValues: ['true', 'false']
    Description: >-
      Row-by-row comparison of source and target after load. Roughly doubles
      the load on both sides. Leave enabled for the rehearsal; consider
      disabling for the final cutover run if the rehearsal was clean.

Conditions:
  IsMultiAz: !Equals [!Ref MultiAz, 'true']

Resources:

  # -------------------------------------------------------------- networking

  DmsSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: DMS replication instance - egress to source and target only
      VpcId: !Ref VpcId
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: !Ref OnPremOraclePort
          ToPort: !Ref OnPremOraclePort
          CidrIp: 172.20.0.0/14
          Description: Oracle TNS listener on premises
        - IpProtocol: tcp
          FromPort: 5432
          ToPort: 5432
          CidrIp: 10.60.0.0/16
          Description: Aurora PostgreSQL target
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Secrets Manager, CloudWatch Logs, KMS
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-dms-sg'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # --------------------------------------------------- replication instance

  ReplicationSubnetGroup:
    Type: AWS::DMS::ReplicationSubnetGroup
    Properties:
      ReplicationSubnetGroupIdentifier: !Sub '${ProjectTag}-dms-subnet-group'
      ReplicationSubnetGroupDescription: Private subnets for the DMS replication instance
      SubnetIds: !Ref PrivateSubnetIds
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  ReplicationInstance:
    Type: AWS::DMS::ReplicationInstance
    Properties:
      ReplicationInstanceIdentifier: !Sub '${ProjectTag}-erp-ri'
      ReplicationInstanceClass: !Ref ReplicationInstanceClass
      AllocatedStorage: !Ref ReplicationInstanceStorageGiB
      MultiAZ: !If [IsMultiAz, true, false]
      PubliclyAccessible: false
      AutoMinorVersionUpgrade: true
      PreferredMaintenanceWindow: sun:02:00-sun:03:00
      ReplicationSubnetGroupIdentifier: !Ref ReplicationSubnetGroup
      VpcSecurityGroupIds:
        - !Ref DmsSecurityGroup
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-erp-ri'
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # ------------------------------------------------------------- endpoints

  OracleSourceEndpoint:
    Type: AWS::DMS::Endpoint
    Properties:
      EndpointIdentifier: !Sub '${ProjectTag}-erp-oracle-source'
      EndpointType: source
      EngineName: oracle
      ServerName: !Ref OnPremOracleHost
      Port: !Ref OnPremOraclePort
      DatabaseName: !Ref OnPremOracleServiceName
      SslMode: require
      # Credentials resolved at runtime from Secrets Manager.
      OracleSettings:
        SecretsManagerSecretId: !Ref OracleSecretArn
        SecretsManagerAccessRoleArn: !GetAtt DmsSecretsAccessRole.Arn
      ExtraConnectionAttributes: >-
        useLogminerReader=N;useBfile=Y;
        addSupplementalLogging=N;
        archivedLogDestId=1;
        numberDataTypeScale=-2;
        failTasksOnLobTruncation=true
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  AuroraTargetEndpoint:
    Type: AWS::DMS::Endpoint
    Properties:
      EndpointIdentifier: !Sub '${ProjectTag}-erp-aurora-target'
      EndpointType: target
      EngineName: aurora-postgresql
      ServerName: !Ref AuroraWriterEndpoint
      Port: 5432
      DatabaseName: !Ref AuroraDatabaseName
      SslMode: require
      PostgreSqlSettings:
        SecretsManagerSecretId: !Ref AuroraSecretArn
        SecretsManagerAccessRoleArn: !GetAtt DmsSecretsAccessRole.Arn
      ExtraConnectionAttributes: >-
        executeTimeout=180;
        maxFileSize=32768;
        heartbeatEnable=true;
        heartbeatFrequency=5
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  DmsSecretsAccessRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-dms-secrets-access'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: !Sub 'dms.${AWS::Region}.amazonaws.com'
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: read-migration-secrets
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - secretsmanager:GetSecretValue
                  - secretsmanager:DescribeSecret
                Resource:
                  - !Ref OracleSecretArn
                  - !Ref AuroraSecretArn

  # ---------------------------------------------------------------- task

  ErpReplicationTask:
    Type: AWS::DMS::ReplicationTask
    Properties:
      ReplicationTaskIdentifier: !Sub '${ProjectTag}-erp-fullload-cdc'
      MigrationType: full-load-and-cdc
      ReplicationInstanceArn: !Ref ReplicationInstance
      SourceEndpointArn: !Ref OracleSourceEndpoint
      TargetEndpointArn: !Ref AuroraTargetEndpoint

      # ---- selection and transformation rules -------------------------------
      # Oracle stores identifiers upper-case; PostgreSQL folds to lower-case.
      # Without the rename rules every object arrives quoted and upper-cased,
      # and the application's unquoted lower-case SQL cannot see it. This is
      # the single most common heterogeneous-migration failure.
      TableMappings: |
        {
          "rules": [
            {
              "rule-type": "selection",
              "rule-id": "1",
              "rule-name": "include-erp-core",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%"
              },
              "rule-action": "include",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "2",
              "rule-name": "exclude-audit-and-temp",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "AUD$%"
              },
              "rule-action": "exclude",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "3",
              "rule-name": "exclude-interim-tables",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%_TMP"
              },
              "rule-action": "exclude",
              "filters": []
            },
            {
              "rule-type": "selection",
              "rule-id": "4",
              "rule-name": "archive-recent-only",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "GL_JOURNAL_ARCHIVE"
              },
              "rule-action": "include",
              "filters": [
                {
                  "filter-type": "source",
                  "column-name": "POSTING_DATE",
                  "filter-conditions": [
                    {
                      "filter-operator": "gte",
                      "value": "2019-01-01"
                    }
                  ]
                }
              ]
            },
            {
              "rule-type": "transformation",
              "rule-id": "5",
              "rule-name": "schema-to-lower",
              "rule-target": "schema",
              "object-locator": { "schema-name": "ERP" },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "6",
              "rule-name": "table-to-lower",
              "rule-target": "table",
              "object-locator": { "schema-name": "ERP", "table-name": "%" },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "7",
              "rule-name": "column-to-lower",
              "rule-target": "column",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%",
                "column-name": "%"
              },
              "rule-action": "convert-lowercase",
              "value": null,
              "old-value": null
            },
            {
              "rule-type": "transformation",
              "rule-id": "8",
              "rule-name": "drop-oracle-rowid-shadow",
              "rule-target": "column",
              "object-locator": {
                "schema-name": "ERP",
                "table-name": "%",
                "column-name": "ORA_ROWSCN"
              },
              "rule-action": "remove-column"
            }
          ]
        }

      # ---- task settings ----------------------------------------------------
      ReplicationTaskSettings: !Sub |
        {
          "TargetMetadata": {
            "TargetSchema": "",
            "SupportLobs": true,
            "FullLobMode": false,
            "LobChunkSize": 64,
            "LimitedSizeLobMode": true,
            "LobMaxSize": 65536,
            "InlineLobMaxSize": 0,
            "LoadMaxFileSize": 0,
            "ParallelLoadThreads": 8,
            "ParallelLoadBufferSize": 500,
            "ParallelApplyThreads": 8,
            "ParallelApplyBufferSize": 500,
            "ParallelApplyQueuesPerThread": 4,
            "BatchApplyEnabled": true,
            "TaskRecoveryTableEnabled": false
          },
          "FullLoadSettings": {
            "TargetTablePrepMode": "TRUNCATE_BEFORE_LOAD",
            "CreatePkAfterFullLoad": false,
            "StopTaskCachedChangesApplied": false,
            "StopTaskCachedChangesNotApplied": false,
            "MaxFullLoadSubTasks": 8,
            "TransactionConsistencyTimeout": 600,
            "CommitRate": 10000
          },
          "Logging": {
            "EnableLogging": true,
            "LogComponents": [
              { "Id": "SOURCE_UNLOAD",  "Severity": "LOGGER_SEVERITY_DEFAULT" },
              { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEBUG"   },
              { "Id": "TARGET_LOAD",    "Severity": "LOGGER_SEVERITY_DEFAULT" },
              { "Id": "TARGET_APPLY",   "Severity": "LOGGER_SEVERITY_DEBUG"   },
              { "Id": "TASK_MANAGER",   "Severity": "LOGGER_SEVERITY_DEFAULT" }
            ]
          },
          "ControlTablesSettings": {
            "ControlSchema": "dms_control",
            "HistoryTimeslotInMinutes": 5,
            "HistoryTableEnabled": true,
            "SuspendedTablesTableEnabled": true,
            "StatusTableEnabled": true
          },
          "ErrorBehavior": {
            "DataErrorPolicy": "LOG_ERROR",
            "DataTruncationErrorPolicy": "STOP_TASK",
            "DataErrorEscalationPolicy": "SUSPEND_TABLE",
            "DataErrorEscalationCount": 50,
            "TableErrorPolicy": "SUSPEND_TABLE",
            "TableErrorEscalationPolicy": "STOP_TASK",
            "TableErrorEscalationCount": 3,
            "RecoverableErrorCount": -1,
            "RecoverableErrorInterval": 5,
            "RecoverableErrorThrottling": true,
            "RecoverableErrorThrottlingMax": 1800,
            "ApplyErrorDeletePolicy": "IGNORE_RECORD",
            "ApplyErrorInsertPolicy": "LOG_ERROR",
            "ApplyErrorUpdatePolicy": "LOG_ERROR",
            "ApplyErrorEscalationPolicy": "LOG_ERROR",
            "ApplyErrorEscalationCount": 0,
            "FullLoadIgnoreConflicts": true
          },
          "ValidationSettings": {
            "EnableValidation": ${EnableValidation},
            "ValidationMode": "ROW_LEVEL",
            "ThreadCount": 5,
            "PartitionSize": 10000,
            "FailureMaxCount": 10000,
            "RecordFailureDelayInMinutes": 5,
            "RecordSuspendDelayInMinutes": 30,
            "HandleCollationDiff": true,
            "ValidationPartialLobSize": 0,
            "SkipLobColumns": false,
            "TableFailureMaxCount": 1000,
            "ValidationOnly": false
          },
          "ChangeProcessingTuning": {
            "BatchApplyPreserveTransaction": true,
            "BatchApplyTimeoutMin": 1,
            "BatchApplyTimeoutMax": 30,
            "BatchApplyMemoryLimit": 500,
            "BatchSplitSize": 0,
            "MinTransactionSize": 1000,
            "CommitTimeout": 1,
            "MemoryLimitTotal": 1024,
            "MemoryKeepTime": 60,
            "StatementCacheSize": 50
          },
          "ChangeProcessingDdlHandlingPolicy": {
            "HandleSourceTableDropped": true,
            "HandleSourceTableTruncated": true,
            "HandleSourceTableAltered": true
          },
          "StreamBufferSettings": {
            "StreamBufferCount": 3,
            "StreamBufferSizeInMB": 8,
            "CtrlStreamBufferSizeInMB": 5
          }
        }

      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  # ------------------------------------------------------------ observability

  CdcTargetLatencyAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-cdc-target-latency'
      AlarmDescription: >-
        CDCLatencyTarget is the delta between a change being read from the
        source log and committed on the target. Sustained growth means the
        target cannot keep up - the cutover window will not close.
      Namespace: AWS/DMS
      MetricName: CDCLatencyTarget
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
        - Name: ReplicationTaskIdentifier
          Value: !Sub '${ProjectTag}-erp-fullload-cdc'
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 300
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching

  CdcSourceLatencyAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-cdc-source-latency'
      AlarmDescription: >-
        CDCLatencySource growing while CDCLatencyTarget is flat points at the
        SOURCE side - log mining throughput, archive log destination, or
        network - not at the target.
      Namespace: AWS/DMS
      MetricName: CDCLatencySource
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
        - Name: ReplicationTaskIdentifier
          Value: !Sub '${ProjectTag}-erp-fullload-cdc'
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 5
      Threshold: 300
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching

  ReplicationInstanceStorageAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-erp-ri-free-storage'
      AlarmDescription: >-
        Replication-instance storage holds spilled CDC changes and task logs.
        Exhaustion stops the task with no clean resume point.
      Namespace: AWS/DMS
      MetricName: FreeStorageSpace
      Dimensions:
        - Name: ReplicationInstanceIdentifier
          Value: !Sub '${ProjectTag}-erp-ri'
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 2
      Threshold: 21474836480   # 20 GiB
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching

Outputs:

  ReplicationInstanceArn:
    Value: !Ref ReplicationInstance
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationInstanceArn'

  ReplicationTaskArn:
    Value: !Ref ErpReplicationTask
    Export:
      Name: !Sub '${AWS::StackName}-ReplicationTaskArn'

  SourceEndpointArn:
    Value: !Ref OracleSourceEndpoint

  TargetEndpointArn:
    Value: !Ref AuroraTargetEndpoint
```

### 7.4 Comandos operativos de DMS

```console
$ TASK_ARN=$(aws cloudformation describe-stacks \
    --stack-name dc-exit-2026-dms-erp \
    --query 'Stacks[0].Outputs[?OutputKey==`ReplicationTaskArn`].OutputValue' \
    --output text)

$ aws dms test-connection \
    --replication-instance-arn "$RI_ARN" \
    --endpoint-arn "$SRC_ARN"
{
    "Connection": {
        "ReplicationInstanceArn": "arn:aws:dms:eu-west-1:123456789012:rep:VZ7XK4M2QJ5NRWBTLC3HYP6ADQ",
        "EndpointArn": "arn:aws:dms:eu-west-1:123456789012:endpoint:H3TQK9WXLZ2VN8MYRBC5PDAF7U",
        "Status": "testing",
        "EndpointIdentifier": "dc-exit-2026-erp-oracle-source",
        "ReplicationInstanceIdentifier": "dc-exit-2026-erp-ri"
    }
}

$ aws dms describe-connections \
    --filters Name=endpoint-arn,Values="$SRC_ARN" \
    --query 'Connections[0].[Status,LastFailureMessage]' --output text
successful     None

$ aws dms start-replication-task \
    --replication-task-arn "$TASK_ARN" \
    --start-replication-task-type start-replication
{
    "ReplicationTask": {
        "ReplicationTaskIdentifier": "dc-exit-2026-erp-fullload-cdc",
        "MigrationType": "full-load-and-cdc",
        "Status": "starting",
        "ReplicationTaskCreationDate": "2026-09-03T11:02:18.400000+00:00",
        "ReplicationTaskStartDate": "2026-09-03T11:47:03.918000+00:00"
    }
}
```

Progreso:

```console
$ aws dms describe-replication-tasks \
    --filters Name=replication-task-arn,Values="$TASK_ARN" \
    --query 'ReplicationTasks[0].{status:Status,pct:ReplicationTaskStats.FullLoadProgressPercent,loaded:ReplicationTaskStats.TablesLoaded,loading:ReplicationTaskStats.TablesLoading,queued:ReplicationTaskStats.TablesQueued,errored:ReplicationTaskStats.TablesErrored}'
{
    "status": "running",
    "pct": 87,
    "loaded": 812,
    "loading": 8,
    "queued": 114,
    "errored": 2
}
```

Dos tablas dieron error. Encontralas:

```console
$ aws dms describe-table-statistics \
    --replication-task-arn "$TASK_ARN" \
    --filters Name=table-state,Values="Table error" \
    --query 'TableStatistics[].[SchemaName,TableName,TableState,FullLoadErrorRows,FullLoadCondtnlChkFailedRows,ValidationState]' \
    --output text
erp     gl_journal_line     Table error     0      148213    Not enabled
erp     doc_attachment      Table error     37     0         Not enabled

$ aws logs filter-log-events \
    --log-group-name dms-tasks-dc-exit-2026-erp-ri \
    --log-stream-names dms-task-VZ7XK4M2QJ5NRWBTLC3HYP6ADQ \
    --filter-pattern 'doc_attachment' \
    --query 'events[0:3].message' --output text
2026-09-03T13:11:04 [TARGET_APPLY  ]E: RetCode: SQL_ERROR SqlState: 22001 NativeError: 1 Message: ERROR: value too long for type character varying(4000); Error while executing the query [1022502] (ar_odbc_stmt.c:2736)
2026-09-03T13:11:04 [TARGET_APPLY  ]E: Failed to load table 'erp'.'doc_attachment' [1022502] (streamcomponent.c:1969)
2026-09-03T13:11:04 [TASK_MANAGER  ]W: Table 'erp'.'doc_attachment' (subtask 5 thread 3) is suspended (replicationtask.c:2617)
```

Diagnóstico: `LobMaxSize: 65536` con `LimitedSizeLobMode: true` trunca los LOB que superan los 64 KB, y la columna de destino no puede contener el valor. O aumentás `LobMaxSize`, o pasás esa tabla a `FullLobMode` en una **tarea separada** (el modo LOB completo es lento — nunca lo mezcles con la tarea principal), o ampliás la columna de destino a `text`.

Resultados de validación una vez terminada la carga:

```console
$ aws dms describe-table-statistics \
    --replication-task-arn "$TASK_ARN" \
    --query 'TableStatistics[?ValidationFailedRecords>`0`].[SchemaName,TableName,FullLoadRows,ValidationPendingRecords,ValidationFailedRecords,ValidationSuspendedRecords,ValidationState]' \
    --output text
erp     fx_rate_daily     1204877     0     41     0     Mismatched records

$ aws dms describe-replication-task-assessment-results \
    --replication-task-arn "$TASK_ARN" \
    --query 'ReplicationTaskAssessmentResults[0].[AssessmentStatus,AssessmentResultsFile]' --output text
"No issues found"    dc-exit-2026-erp-fullload-cdc-2026-09-03-11-02
```

> 41 discrepancias en `fx_rate_daily` sobre una columna Oracle `NUMBER` es el artefacto clásico de `numberDataTypeScale`: un `NUMBER` de Oracle con precisión no especificada se mapea a un tipo de PostgreSQL que redondea. Esto es un **defecto de corrección de datos**, no un bug de DMS — el atributo de conexión extra `numberDataTypeScale=-2` del endpoint de arriba lo mapea a `varchar` para preservación exacta, lo que después requiere un cast explícito en la aplicación. Es una compensación real, y hay que decidirla antes de la transición, no descubrirla después.

---

## 8. Ejecución de MGN: prueba, transición, verificación

### 8.1 Salud de la replicación a lo largo de la ola

```console
$ aws mgn describe-source-servers --region eu-west-1 \
    --filters isArchived=false \
    --query 'items[].[sourceProperties.identificationHints.hostname,
                      sourceServerID,
                      lifeCycle.state,
                      dataReplicationInfo.dataReplicationState,
                      dataReplicationInfo.lagDuration,
                      dataReplicationInfo.etaDateTime]' \
    --output text | column -t
app-prd-04   s-0a1b2c3d4e5f60718  READY_FOR_CUTOVER  CONTINUOUS   PT0S       None
app-prd-05   s-0b2c3d4e5f6a71829  READY_FOR_CUTOVER  CONTINUOUS   PT0S       None
app-prd-06   s-0c3d4e5f6a7b8293a  READY_FOR_TEST     CONTINUOUS   PT4M12S    None
ora-prd-01   s-0d4e5f6a7b8c93a4b  NOT_READY          INITIAL_SYNC PT0S       2026-09-05T02:41:00Z
win-batch-02 s-0e5f6a7b8c9da4b5c  NOT_READY          STALLED      PT9H17M    None
```

`win-batch-02` está estancado con 9 h de retraso. Obtené la razón:

```console
$ aws mgn describe-source-servers \
    --filters sourceServerIDs=s-0e5f6a7b8c9da4b5c \
    --query 'items[0].dataReplicationInfo.{state:dataReplicationState,
                                           err:dataReplicationError,
                                           init:dataReplicationInitiation.steps[-3:],
                                           disks:replicatedDisks}'
{
    "state": "STALLED",
    "err": {
        "error": "FAILED_TO_CONNECT_AGENT_TO_REPLICATION_SERVER",
        "rawError": "Agent could not establish a connection to the replication server on TCP 1500"
    },
    "init": [
        {
            "name": "LAUNCH_REPLICATION_SERVER",
            "status": "SUCCEEDED"
        },
        {
            "name": "BOOT_REPLICATION_SERVER",
            "status": "SUCCEEDED"
        },
        {
            "name": "AUTHENTICATE_WITH_SERVICE",
            "status": "FAILED"
        }
    ],
    "disks": [
        {
            "deviceName": "/dev/sda1",
            "totalStorageBytes": 107374182400,
            "replicatedStorageBytes": 107374182400,
            "backloggedStorageBytes": 0,
            "rescannedStorageBytes": 0
        },
        {
            "deviceName": "/dev/sdb",
            "totalStorageBytes": 2147483648000,
            "replicatedStorageBytes": 1683219644416,
            "backloggedStorageBytes": 41231548416,
            "rescannedStorageBytes": 0
        }
    ]
}
```

### 8.2 Lanzamiento de prueba — obligatorio antes de la transición

```console
$ aws mgn start-test --source-server-ids s-0a1b2c3d4e5f60718 s-0b2c3d4e5f6a71829
{
    "job": {
        "jobID": "mgnjob-0f1e2d3c4b5a69788",
        "arn": "arn:aws:mgn:eu-west-1:123456789012:job/mgnjob-0f1e2d3c4b5a69788",
        "type": "LAUNCH",
        "initiatedBy": "START_TEST",
        "status": "PENDING",
        "creationDateTime": "2026-09-03T14:02:11Z",
        "participatingServers": [
            { "sourceServerID": "s-0a1b2c3d4e5f60718", "launchStatus": "PENDING" },
            { "sourceServerID": "s-0b2c3d4e5f6a71829", "launchStatus": "PENDING" }
        ]
    }
}

$ aws mgn describe-jobs --filters jobIDs=mgnjob-0f1e2d3c4b5a69788 \
    --query 'items[0].{status:status,servers:participatingServers[].{s:sourceServerID,st:launchStatus,i:launchedEc2InstanceID}}'
{
    "status": "COMPLETED",
    "servers": [
        { "s": "s-0a1b2c3d4e5f60718", "st": "LAUNCHED", "i": "i-04c8f2a71b6d3e590" },
        { "s": "s-0b2c3d4e5f6a71829", "st": "LAUNCHED", "i": "i-0b7e3d9a24c15f806" }
    ]
}
```

**Validaciones de prueba no negociables** antes de marcar la prueba como exitosa:

| Chequeo | Comando / método | Condición de aprobación |
|---|---|---|
| La instancia arranca hasta el SO | `aws ec2 get-console-output --instance-id i-04c8f2a71b6d3e590 --latest --output text` | Prompt de login / `Reached target Multi-User System` |
| Todos los discos montados | `df -h` adentro vía SSM | Cada punto de montaje del origen presente con el tamaño correcto |
| La aplicación arranca | Específico del servicio | Endpoint de salud 200 |
| Licencias válidas | Herramienta del proveedor | Nuevo ID de instancia / MAC aceptados |
| Dependencias salientes alcanzables | `ss -tnp`, `curl` dirigido | Ninguna conexión a IPs on-prem que van a quedar bloqueadas por firewall |
| Sin IPs de origen hardcodeadas | `grep -rn '172\.20\.' /etc /opt` | Vacío, o cada coincidencia está entendida |
| Sincronización horaria | `chronyc sources` / `w32tm /query /status` | Sincronizado con Amazon Time Sync (169.254.169.123) |

```console
$ aws mgn finalize-cutover --source-server-id s-0a1b2c3d4e5f60718
# (run only AFTER the real cutover, not after a test)
```

### 8.3 Runbook de la transición

```
T-14d   Wave scoped. Dependency edges resolved or explicitly accepted.
T-7d    Test launch executed and validated for every server in the wave.
T-72h   DNS TTL for every affected record lowered to 60 s. VERIFY with dig
        from an external resolver, not from the authoritative server.
T-48h   Reverse replication path confirmed (DMS reverse task created and
        tested; MGN source servers left intact, NOT decommissioned).
T-24h   Change freeze on source. Replication lag confirmed at PT0S.
        Go/no-go with named decision owner.
T-0     1. Stop the application on the source. Confirm zero writes:
           Oracle : SELECT COUNT(*) FROM v$transaction;      -- must be 0
           MySQL  : SHOW PROCESSLIST;                        -- no writers
           Postgres: SELECT * FROM pg_stat_activity
                     WHERE state='active' AND query NOT LIKE '%pg_stat%';
        2. Wait for lag to reach zero on every replication stream.
        3. aws mgn start-cutover --source-server-ids <ids>
        4. Wait for launchStatus LAUNCHED on all participating servers.
        5. Run the smoke suite against the target directly (bypass DNS,
           use /etc/hosts or the instance IP).
        6. Flip DNS / Route 53 weighted record to the target.
        7. Watch error rate and latency for the full observation window.
T+2h    Go/no-go on rollback. After this point rollback means data loss.
T+24h   aws mgn finalize-cutover  (releases staging resources)
        DMS task stopped and DELETED - verify the replication slot is gone.
T+7d    Source servers powered off but NOT wiped.
T+30d   Source decommissioned. Datacenter asset record updated.
```

Verificación de retraso cero, la compuerta del paso 2:

```console
$ aws mgn describe-source-servers --filters sourceServerIDs=s-0a1b2c3d4e5f60718 \
    --query 'items[0].dataReplicationInfo.{lag:lagDuration,state:dataReplicationState,snap:lastSnapshotDateTime}'
{
    "lag": "PT0S",
    "state": "CONTINUOUS",
    "snap": "2026-09-03T22:58:04Z"
}

$ aws dms describe-replication-tasks --filters Name=replication-task-arn,Values="$TASK_ARN" \
    --query 'ReplicationTasks[0].{status:Status,stopReason:StopReason}'
{
    "status": "running",
    "stopReason": null
}

$ aws cloudwatch get-metric-statistics \
    --namespace AWS/DMS --metric-name CDCLatencyTarget \
    --dimensions Name=ReplicationInstanceIdentifier,Value=dc-exit-2026-erp-ri \
                 Name=ReplicationTaskIdentifier,Value=dc-exit-2026-erp-fullload-cdc \
    --start-time 2026-09-03T22:45:00Z --end-time 2026-09-03T23:00:00Z \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
2026-09-03T22:45:00+00:00   4.0
2026-09-03T22:50:00+00:00   2.0
2026-09-03T22:55:00+00:00   0.0
```

---

## 9. DataSync: stack completo de migración de la capa de archivos

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  On-premises NFS filer -> Amazon S3 migration with AWS DataSync.
  Includes the location pair, the task with explicit transfer semantics, a
  nightly schedule for the incremental delta, CloudWatch logging, and an alarm
  on execution failure. The DataSync agent VM must already be deployed on
  premises and activated - the agent ARN is a parameter, not a resource,
  because activation requires network access to the appliance.

Parameters:

  ProjectTag:
    Type: String
    Default: dc-exit-2026

  AgentArn:
    Type: String
    Description: >-
      ARN of the activated DataSync agent, e.g.
      arn:aws:datasync:eu-west-1:123456789012:agent/agent-0a1b2c3d4e5f60718

  NfsServerHostname:
    Type: String
    Default: nfs-filer-01.corp.internal
    Description: Must be resolvable and reachable FROM THE AGENT, not from AWS.

  NfsSubdirectory:
    Type: String
    Default: /export/finance-archive
    Description: Must be an exported path with the agent's IP permitted in /etc/exports.

  DestinationBucketName:
    Type: String
    Default: dc-exit-2026-finance-archive-eu-west-1

  DestinationPrefix:
    Type: String
    Default: /finance-archive

  BytesPerSecondLimit:
    Type: Number
    Default: -1
    Description: >-
      Bandwidth ceiling in bytes/s. -1 means unlimited, which will saturate the
      WAN link. 125000000 = 1 Gbps. Set this to protect production traffic.

Resources:

  ArchiveBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref DestinationBucketName
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: archive-cold-objects
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
              - StorageClass: DEEP_ARCHIVE
                TransitionInDays: 365
            NoncurrentVersionExpiration:
              NoncurrentDays: 90
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  DataSyncS3AccessRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectTag}-datasync-s3-access'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: datasync.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
      Policies:
        - PolicyName: datasync-bucket-access
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - s3:GetBucketLocation
                  - s3:ListBucket
                  - s3:ListBucketMultipartUploads
                  - s3:HeadBucket
                Resource: !GetAtt ArchiveBucket.Arn
              - Effect: Allow
                Action:
                  - s3:AbortMultipartUpload
                  - s3:DeleteObject
                  - s3:GetObject
                  - s3:GetObjectTagging
                  - s3:GetObjectVersion
                  - s3:ListMultipartUploadParts
                  - s3:PutObject
                  - s3:PutObjectTagging
                Resource: !Sub '${ArchiveBucket.Arn}/*'

  DataSyncLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/datasync/${ProjectTag}-finance-archive'
      RetentionInDays: 90

  DataSyncLogResourcePolicy:
    Type: AWS::Logs::ResourcePolicy
    Properties:
      PolicyName: !Sub '${ProjectTag}-datasync-logs'
      PolicyDocument: !Sub |
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "DataSyncLogsToCloudWatch",
              "Effect": "Allow",
              "Principal": { "Service": "datasync.amazonaws.com" },
              "Action": ["logs:PutLogEvents", "logs:CreateLogStream"],
              "Resource": "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/datasync/*:*"
            }
          ]
        }

  NfsSourceLocation:
    Type: AWS::DataSync::LocationNFS
    Properties:
      ServerHostname: !Ref NfsServerHostname
      Subdirectory: !Ref NfsSubdirectory
      OnPremConfig:
        AgentArns:
          - !Ref AgentArn
      MountOptions:
        Version: NFS4_1
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-nfs-source'

  S3DestinationLocation:
    Type: AWS::DataSync::LocationS3
    Properties:
      S3BucketArn: !GetAtt ArchiveBucket.Arn
      Subdirectory: !Ref DestinationPrefix
      S3StorageClass: STANDARD
      S3Config:
        BucketAccessRoleArn: !GetAtt DataSyncS3AccessRole.Arn
      Tags:
        - Key: Name
          Value: !Sub '${ProjectTag}-s3-destination'

  ArchiveSyncTask:
    Type: AWS::DataSync::Task
    Properties:
      Name: !Sub '${ProjectTag}-finance-archive-sync'
      SourceLocationArn: !Ref NfsSourceLocation
      DestinationLocationArn: !Ref S3DestinationLocation
      CloudWatchLogGroupArn: !GetAtt DataSyncLogGroup.Arn
      Schedule:
        # 01:00 UTC nightly - the incremental delta, not the seed.
        ScheduleExpression: 'cron(0 1 * * ? *)'
      Options:
        # TransferMode CHANGED compares metadata and moves only differences.
        # ALL re-reads everything - correct only for the first run or after a
        # suspected corruption event.
        TransferMode: CHANGED
        # POINT_IN_TIME_CONSISTENT verifies the whole dataset at the end.
        # ONLY_FILES_TRANSFERRED is far cheaper and sufficient for incrementals.
        VerifyMode: POINT_IN_TIME_CONSISTENT
        OverwriteMode: ALWAYS
        # PRESERVE keeps files in S3 that were deleted on the source. Set to
        # REMOVE only when S3 must be an exact mirror - it deletes data.
        PreserveDeletedFiles: PRESERVE
        PreserveDevices: NONE
        PosixPermissions: PRESERVE
        Uid: INT_VALUE
        Gid: INT_VALUE
        # Atime BEST_EFFORT requires Mtime PRESERVE - the API rejects any
        # other combination.
        Atime: BEST_EFFORT
        Mtime: PRESERVE
        ObjectTags: PRESERVE
        BytesPerSecond: !Ref BytesPerSecondLimit
        TaskQueueing: ENABLED
        LogLevel: TRANSFER
      Excludes:
        - FilterType: SIMPLE_PATTERN
          Value: '/*/.snapshot/*|/*/lost+found/*|*.tmp'
      Tags:
        - Key: migration-wave-project
          Value: !Ref ProjectTag

  TaskFailureAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectTag}-datasync-files-failed'
      AlarmDescription: DataSync reported files it could not transfer or verify.
      Namespace: AWS/DataSync
      MetricName: FilesFailedToTransfer
      Dimensions:
        - Name: TaskId
          Value: !GetAtt ArchiveSyncTask.TaskArn
      Statistic: Sum
      Period: 3600
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  TaskArn:
    Value: !Ref ArchiveSyncTask
  SourceLocationArn:
    Value: !Ref NfsSourceLocation
  DestinationLocationArn:
    Value: !Ref S3DestinationLocation
```

```console
$ aws datasync start-task-execution \
    --task-arn arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312
{
    "TaskExecutionArn": "arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281"
}

$ aws datasync describe-task-execution \
    --task-execution-arn arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281
{
    "TaskExecutionArn": "arn:aws:datasync:eu-west-1:123456789012:task/task-0a9b8c7d6e5f40312/execution/exec-0f8e7d6c5b4a39281",
    "Status": "SUCCESS",
    "Options": {
        "VerifyMode": "POINT_IN_TIME_CONSISTENT",
        "OverwriteMode": "ALWAYS",
        "Atime": "BEST_EFFORT",
        "Mtime": "PRESERVE",
        "Uid": "INT_VALUE",
        "Gid": "INT_VALUE",
        "PreserveDeletedFiles": "PRESERVE",
        "PreserveDevices": "NONE",
        "PosixPermissions": "PRESERVE",
        "BytesPerSecond": -1,
        "TaskQueueing": "ENABLED",
        "LogLevel": "TRANSFER",
        "TransferMode": "CHANGED",
        "ObjectTags": "PRESERVE"
    },
    "StartTime": "2026-09-03T01:00:03.117000+00:00",
    "EstimatedFilesToTransfer": 1842991,
    "EstimatedBytesToTransfer": 4193847610368,
    "FilesTransferred": 1842991,
    "BytesWritten": 4193847610368,
    "BytesTransferred": 3114208477184,
    "Result": {
        "PrepareDuration": 412883,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 34718402,
        "TransferDuration": 31904118,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 2401401,
        "VerifyStatus": "SUCCESS"
    }
}
```

> `BytesTransferred` (3,11 TB) < `BytesWritten` (4,19 TB) es la compresión en vuelo de DataSync haciendo su trabajo — 26 % ahorrado en el cable. Esta es la métrica para citar cuando el equipo de redes pregunta qué está transportando el enlace.

---

## 10. Verificación y diagnóstico de fallas

### 10.1 Catálogo de fallas de MGN

| `dataReplicationError.error` | Causa real | Diagnóstico | Solución |
|---|---|---|---|
| `AGENT_NOT_SEEN` | Servicio del agente detenido, host apagado, o salida por 443 bloqueada | `systemctl status aws-replication-agent`; `curl -v https://mgn.<region>.amazonaws.com` desde el origen | Reiniciar el agente; abrir la salida 443 hacia el endpoint de MGN |
| `FAILED_TO_CONNECT_AGENT_TO_REPLICATION_SERVER` | TCP 1500 bloqueado por firewall/NACL/SG entre el CIDR de origen y la subred de staging | `nc -vz <replication-server-private-ip> 1500` desde el host de origen | Corregir la regla de ingreso del SG, la NACL y la ACL de salida on-prem — las tres |
| `FAILED_TO_LAUNCH_REPLICATION_SERVER` | Tipo de instancia no disponible en la AZ, cuota de EC2 agotada, subred sin IPs | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`; verificar IPs libres en la subred | Subir la cuota, cambiar el tipo de instancia, ampliar la subred |
| `FAILED_TO_CREATE_STAGING_DISKS` | Cuota de volúmenes EBS, o la política de la clave KMS deniega al rol vinculado al servicio de MGN | Eventos `CreateVolume` en CloudTrail con `AccessDenied` | Otorgar `kms:CreateGrant`/`Decrypt` a `AWSServiceRoleForApplicationMigrationService` |
| `FAILED_TO_AUTHENTICATE_WITH_SERVICE` | Credenciales del agente revocadas/rotadas, o desfasaje de reloj > 5 min | Verificar el estado de la clave del usuario IAM; `timedatectl` en el origen | Reinstalar el agente con claves nuevas; corregir NTP |
| `NOT_CONVERGING` | La tasa de cambio diaria supera el ancho de banda de replicación disponible (§1.1) | Comparar la tendencia de `backloggedStorageBytes` durante 24 h — si crece, nunca vas a converger | Subir el ancho de banda, quitar el límite, sembrar con Snow, o excluir el volumen que rota |
| `UNSTABLE_NETWORK` | Pérdida de paquetes / agujero negro de MTU en la ruta DX o VPN | `mtr --tcp --port 1500 <replication-server-ip>`; probar PMTUD con `ping -M do -s 1472` | Fijar el MSS en el túnel; corregir el desajuste de MTU |
| `SNAPSHOTS_FAILURE` | Cuota de snapshots de EBS, o denegación de KMS al copiar el snapshot | `CreateSnapshot` en CloudTrail | Subir la cuota de snapshots concurrentes |

### 10.2 Catálogo de fallas de DMS

| Síntoma | Causa probable | Verificación | Solución |
|---|---|---|---|
| Estado de la tarea `failed` de inmediato | Conectividad del endpoint | `aws dms test-connection` y luego `describe-connections` → `LastFailureMessage` | Salida del SG, firewall on-prem, resolución DNS desde la instancia de replicación |
| El CDC nunca arranca después de la carga completa | Falta el logging suplementario / configuración de binlog (§7.2) | Log de la tarea `SOURCE_CAPTURE` en DEBUG | Habilitarlo en el origen; **la tarea debe reiniciarse desde cero** |
| `CDCLatencySource` subiendo, el destino plano | Throughput de log mining del origen o destino de los archive logs | CloudWatch `CDCLatencySource` vs `CDCLatencyTarget` | Cambiar Oracle a Binary Reader; mover los archive logs a almacenamiento más rápido |
| `CDCLatencyTarget` subiendo, el origen plano | El destino no puede aplicar lo suficientemente rápido | `CDCChangesDiskTarget` > 0 significa que el búfer de memoria desbordó a disco | Habilitar `BatchApplyEnabled`, subir `ParallelApplyThreads`, escalar el destino |
| Tabla suspendida a mitad de la carga | Un error de datos cruzó `DataErrorEscalationCount` | `describe-table-statistics` → `TableState` = `Table error` | Leer el log `TARGET_APPLY`; normalmente truncamiento de LOB o desajuste de tipo |
| Discrepancias de validación en numéricos | Pérdida de precisión en `NUMBER` de Oracle | `ValidationFailedRecords` > 0 en tablas cargadas de numéricos | Atributo de endpoint `numberDataTypeScale`; decidir la política de precisión |
| El disco del origen se llena | Slot de replicación PostgreSQL huérfano / archive logs de Oracle no purgados | `SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots;` | Eliminar la tarea muerta, después `pg_drop_replication_slot()` |
| Faltan filas silenciosamente después de la transición | La tabla no tenía clave primaria; las actualizaciones de CDC no se pudieron aplicar | Comparar `COUNT(*)` y un checksum por tabla | Agregar PKs *antes* de migrar; volver a correr la carga completa para las tablas afectadas |

### 10.3 Verificación independiente — nunca confíes en una sola señal

El éxito reportado por la herramienta es necesario, no suficiente. Verificá sobre tres ejes independientes:

```console
# 1. Row counts, source vs target - computed independently of DMS
$ psql -h erp-aurora.cluster-abc123.eu-west-1.rds.amazonaws.com -U migrator -d erpprd -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables
    WHERE schemaname='erp' ORDER BY relname" > /tmp/target_counts.txt

$ sqlplus -s migrator/@ERPPRD <<'SQL' > /tmp/source_counts.txt
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT LOWER(table_name)||'|'||num_rows FROM all_tables
 WHERE owner='ERP' ORDER BY table_name;
SQL

$ diff <(sort /tmp/source_counts.txt) <(sort /tmp/target_counts.txt) | head
< gl_journal_line|41827311
> gl_journal_line|41827248

# 2. Content checksum on a business-critical table (not just the count)
$ psql -Atc "SELECT md5(string_agg(t::text, '|' ORDER BY id))
             FROM (SELECT id, amount, currency FROM erp.fx_rate_daily
                   WHERE rate_date >= '2026-01-01') t"
b7c1e94a2f60d5138ae2c93704f6a1d8

# 3. Application-level: run the reconciliation report the business already trusts
$ curl -s https://erp-target.internal/api/v1/reports/trial-balance?period=2026-08 \
    | jq -r '.total_debit, .total_credit, .variance'
884_192_337.44
884_192_337.44
0.00
```

> El faltante de 63 filas en `gl_journal_line` está dentro del ruido de `num_rows` de Oracle (una *estimación estadística*, no un conteo) — que es exactamente por qué el eje 1 por sí solo no prueba nada. `COUNT(*)` de los dos lados, o el checksum, es la señal real. Todo plan de verificación de migración debería declarar cuáles de sus chequeos son exactos y cuáles son estimaciones.

### 10.4 Verificación de costos después de la migración

Los presupuestos de migración fracasan por recursos de staging que nadie eliminó:

```console
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --filter '{"Tags":{"Key":"migration-wave-project","Values":["dc-exit-2026"]}}' \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output text
AWS Database Migration Service        3184.77
Amazon Elastic Block Store            9412.03
Amazon Elastic Compute Cloud - Compute 6620.18
Amazon Simple Storage Service          741.92
AWS DataSync                           118.40

$ aws ec2 describe-volumes \
    --filters Name=status,Values=available Name=tag:migration-wave-project,Values=dc-exit-2026 \
    --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' --output text | wc -l
187
```

187 volúmenes de staging sin adjuntar — el residuo de transiciones completadas donde nunca se ejecutó `finalize-cutover`. `aws mgn finalize-cutover` es lo que los libera.

---

## 11. Los beneficios, y cómo medirlos

La guía del examen pide que *comprendas los beneficios*. Nombrarlos no alcanza a este nivel — cada uno mapea a una cantidad medible.

### 11.1 Pilares del AWS Cloud Value Framework

| Pilar | Afirmación | Métrica que lo prueba | Falla común para materializarlo |
|---|---|---|---|
| **Cost savings** | Menor TCO | $/carga de trabajo/mes vs el costo on-prem totalmente cargado (amortización de hardware, espacio de DC, energía, refrigeración, red, personal) | Rehostear VMs dimensionadas para el pico 1:1 — sin right-sizing, sin scheduling, sin Savings Plans |
| **Staff productivity** | Los ingenieros hacen menos trabajo pesado indiferenciado | Horas/mes en parcheo, backups, planificación de capacidad, RMA de hardware | Mantener todo autogestionado en EC2 |
| **Operational resilience** | Menos caídas y más cortas | Disponibilidad, MTTR, horas de downtime no planificado, RTO/RPO realmente probados | Despliegue en una sola AZ porque el origen tenía un solo datacenter |
| **Business agility** | Entrega más rápida | Lead time para el cambio, frecuencia de despliegue, tiempo para aprovisionar un entorno | El mismo comité de aprobación de cambios, ahora sobre AWS |
| **Sustainability** | Menor carbono por unidad de trabajo | Customer Carbon Footprint Tool; energía por transacción de la carga de trabajo | Nunca medido, entonces nunca mejorado |

### 11.2 Los cuatro beneficios nombrados por el enunciado de tarea de CLF-C02

| Beneficio | Mecanismo | Ejemplo concreto |
|---|---|---|
| **Riesgo de negocio reducido** | Resiliencia multi-AZ/multi-Región; DR probado; parcheo gestionado; herencia de cumplimiento de AWS | El RPO baja de "la cinta de ayer" a segundos con CDC entre regiones |
| **Mejor desempeño ESG** | Mayor utilización, hardware y refrigeración más eficientes, compromisos de energía renovable | Retirar 4 racks al 12 % de utilización promedio elimina todo su consumo, no el 12 % de él |
| **Ingresos aumentados** | Nueva capacidad, experimentación más rápida, alcance global en minutos | Lanzar en una geografía nueva = una Región nueva, no un contrato nuevo de datacenter |
| **Mayor eficiencia operativa** | Automatización, servicios gestionados, elasticidad | Entornos aprovisionados por CloudFormation en minutos en lugar de una compra de 6 semanas |

### 11.3 El Migration Acceleration Program (MAP)

MAP es el programa financiado de AWS, de tres fases (Assess → Mobilize → Migrate & Modernize), que envuelve herramientas, servicios de socios y créditos de AWS alrededor de una migración. El hecho relevante para el examen es el mapeo: **las fases de MAP *son* las tres fases de migración de la §2.4**, y el etiquetado de MAP (`map-migrated`) es lo que atribuye los recursos migrados a efectos de los créditos — que es para lo que existen las propiedades `EnableMapAutoTagging` / `MapAutoTaggingMpeID` en la plantilla de lanzamiento de MGN (§5).

---

## 12. Destilado enfocado en el examen

| Si la pregunta menciona… | La respuesta es |
|---|---|
| Mover un servidor tal cual, con cambios mínimos | **Rehost** (AWS Application Migration Service / MGN) |
| Mover VMs de VMware a nivel de hipervisor | **Relocate** |
| Pasar a una base de datos gestionada, sin reescribir código | **Replatform** |
| Abandonar la app, comprar una suscripción | **Repurchase** |
| Romper un monolito en microservicios | **Refactor / Re-architect** |
| Nadie lo usa | **Retire** |
| Todavía no se puede mover — regulación, dependencia | **Retain** |
| Convertir un esquema Oracle a PostgreSQL | **AWS SCT** / DMS Schema Conversion |
| Mover las filas con downtime mínimo | **AWS DMS** (carga completa + CDC) |
| Entender qué servidores hablan con cuáles | **AWS Application Discovery Service** |
| Seguir el progreso de la migración en un solo lugar | **AWS Migration Hub** |
| Construir el caso de negocio / TCO | **Migration Evaluator** |
| 500 TB, conectividad mala | **AWS Snow Family** |
| Transferencia recurrente NFS/SMB → S3/EFS/FSx | **AWS DataSync** |
| Socios suben archivos por SFTP | **AWS Transfer Family** |
| Mantener el acceso a archivos/cintas on-prem, almacenar en AWS | **AWS Storage Gateway** |
| Preparación organizacional, seis perspectivas | **AWS Cloud Adoption Framework (CAF)** |
| Programa de migración financiado con créditos | **Migration Acceleration Program (MAP)** |
| Seis pilares, mejores prácticas a nivel de diseño | **AWS Well-Architected Framework** (no CAF) |

**La distinción que más se pasa por alto:** CAF trata sobre preparación **organizacional** (business, people, governance, platform, security, operations). Well-Architected trata sobre el diseño de la **carga de trabajo** (excelencia operativa, seguridad, fiabilidad, eficiencia del rendimiento, optimización de costos, sostenibilidad). Una pregunta sobre *alineación ejecutiva y habilidades* es CAF; una pregunta sobre *cómo diseñar esta carga de trabajo* es Well-Architected.

---

## Referencias

**Exam**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

**Frameworks and strategy**
- AWS Cloud Adoption Framework (overview whitepaper) — https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
- AWS Well-Architected Framework — https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
- AWS Prescriptive Guidance — Migration strategies — https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-migration-strategies/welcome.html
- AWS Prescriptive Guidance — Large migration guide — https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/welcome.html
- "Seven strategies to accelerate your application migration to AWS" (AWS Enterprise Strategy Blog) — https://aws.amazon.com/blogs/enterprise-strategy/new-possibilities-seven-strategies-to-accelerate-your-application-migration-to-aws/
- AWS Cloud Migration — https://aws.amazon.com/cloud-migration/
- AWS Migration Acceleration Program (MAP) — https://aws.amazon.com/migration-acceleration-program/

**Assess and track**
- AWS Migration Hub User Guide — https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html
- AWS Application Discovery Service User Guide — https://docs.aws.amazon.com/application-discovery/latest/userguide/what-is-appdiscovery.html
- Data Exploration in Amazon Athena (discovery export schema) — https://docs.aws.amazon.com/application-discovery/latest/userguide/explore-data.html
- Migration Evaluator — https://aws.amazon.com/migration-evaluator/
- AWS Migration Hub Refactor Spaces — https://docs.aws.amazon.com/migrationhub-refactor-spaces/latest/userguide/what-is-mhub-refactor-spaces.html

**Server migration (rehost)**
- AWS Application Migration Service User Guide — https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
- MGN network requirements — https://docs.aws.amazon.com/mgn/latest/ug/Network-Requirements.html
- MGN troubleshooting — https://docs.aws.amazon.com/mgn/latest/ug/troubleshooting-summary.html
- AWS CLI reference — `mgn` — https://docs.aws.amazon.com/cli/latest/reference/mgn/
- CloudFormation `AWS::MGN::ReplicationConfigurationTemplate` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-mgn-replicationconfigurationtemplate.html
- CloudFormation `AWS::MGN::LaunchConfigurationTemplate` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-mgn-launchconfigurationtemplate.html

**Database migration**
- AWS Database Migration Service User Guide — https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
- DMS task settings reference — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.html
- DMS table mapping with JSON — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html
- DMS monitoring and CloudWatch metrics — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Monitoring.html
- DMS data validation — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Validating.html
- DMS Fleet Advisor — https://docs.aws.amazon.com/dms/latest/userguide/CHAP_FleetAdvisor.html
- AWS Schema Conversion Tool User Guide — https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html
- CloudFormation `AWS::DMS::ReplicationTask` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dms-replicationtask.html

**Data transfer**
- AWS DataSync User Guide — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- CloudFormation `AWS::DataSync::Task` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-datasync-task.html
- AWS Snowball Edge Developer Guide — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
- AWS Snow Family (product page and FAQ — check current device availability here) — https://aws.amazon.com/snow/
- AWS Storage Gateway User Guide — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- AWS Transfer Family User Guide — https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html

**Cost and sustainability**
- AWS Cost Explorer API — `get-cost-and-usage` — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html
- AWS Customer Carbon Footprint Tool — https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/what-is-ccft.html