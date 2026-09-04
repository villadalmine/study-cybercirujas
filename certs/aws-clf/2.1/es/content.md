# 2.1 — Comprender el Modelo de Responsabilidad Compartida de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · **Dominio 2 — Seguridad y Cumplimiento** · **Peso del tema: 7.5**

**Cobertura del task statement (guía del examen CLF-C02):** reconocer los componentes del modelo de responsabilidad compartida; describir las responsabilidades del cliente y cómo se *desplazan* según el servicio consumido (EC2 vs. RDS vs. Lambda); describir las responsabilidades de AWS; describir los controles compartidos.

---

## 1. Motivación: el problema arquitectónico que este modelo existe para resolver

### 1.1 La falla que no tiene dueño

Tomá una topología real de producción: un ALB expuesto a internet, un Auto Scaling group de instancias `m6i.large` corriendo Amazon Linux 2023, un cluster Aurora PostgreSQL y un bucket S3 con exportaciones de clientes. Ahora enumerá todo lo que hay que parchear, configurar, monitorear, cifrar, respaldar y auditar para que ese stack sea *seguro*:

| Capa | Artefacto de ejemplo | ¿Quién arregla un CVE acá? |
|---|---|---|
| Energía del datacenter / acceso físico | UPS, esclusa biométrica | AWS |
| Firmware del servidor / BMC | Firmware de la tarjeta Nitro | AWS |
| Hypervisor / Nitro hypervisor | Bug de clase VM escape | AWS |
| Kernel del SO invitado | `CVE-2024-XXXX` en `kernel-6.1` | **Vos** |
| Runtime de lenguaje en la instancia | OpenSSL, glibc, JVM | **Vos** |
| Dependencias de la aplicación | `log4j`, `requests`, `openssl-sys` | **Vos** |
| Capa de almacenamiento de Aurora | Bug de replicación entre las 6 copias | AWS |
| Binario del motor PostgreSQL | Parche de versión menor del motor | AWS (aplicado en **tu** ventana de mantenimiento) |
| Esquema de base de datos, roles, equivalente a `pg_hba` | `GRANT ALL TO PUBLIC` | **Vos** |
| Durabilidad de S3 | Falla de disco, bit rot | AWS |
| Bucket policy de S3 / Block Public Access | `GetObject` público hacia `*` | **Vos** |
| Trust policy del rol IAM | `sts:AssumeRole` desde `"AWS": "*"` | **Vos** |

Cada fila de arriba es un incidente plausible. Solo algunas te llaman *a vos* al pager. El modelo de responsabilidad compartida es la **función de frontera contractual y operativa** que te dice, antes del incidente, qué pager suena y qué evidencia tenés permitido recolectar.

Una reformulación a nivel SRE:

> El modelo de responsabilidad compartida no es un póster de seguridad. Es una **partición del plano de control**. AWS es dueño de todo lo que está debajo de su superficie de API publicada; vos sos dueño de cada transición de estado que puedas expresar *a través* de esa API. Donde la API expone una perilla, la perilla es tuya — incluido su valor por defecto.

### 1.2 Por qué "el default es tuyo" es la mitad cara

La clase dominante de brecha en la nube no es un escape del hypervisor. Es una mala configuración del lado del cliente, alcanzable a través de una API de AWS perfectamente sana:

- Un rol IAM asociado a una instancia EC2 con `s3:*` sobre `*`, más una aplicación vulnerable a SSRF → exfiltración de credenciales por Instance Metadata Service v1 → lectura masiva de objetos. Todos los componentes de AWS se comportaron según especificación.
- Una bucket policy con `"Principal": "*"` sobre un bucket exceptuado de Block Public Access.
- Un security group abierto a `0.0.0.0/0:22` "temporalmente" durante un incidente y nunca cerrado.
- Una función Lambda con una dependencia vendorizada de hace tres años. AWS parcheó el SO del runtime y el intérprete de Python; nadie parcheó tu `site-packages`.

Ninguna de estas es una falla de AWS y — críticamente — **AWS no te va a frenar**. La API acepta la llamada, CloudTrail la registra y el recurso entra en un estado inseguro. Tu trabajo como arquitecto de plataforma es convertir el modelo de prosa en **código aplicado y verificable**: SCPs que hagan el estado malo irrepresentable, reglas de Config que detecten la deriva, y Security Hub/Inspector para cerrar el ciclo.

### 1.3 La asimetría de la evidencia

Hay una segunda consecuencia, menos obvia. Responsabilidad y *verificabilidad* no son lo mismo:

| | Tu mitad | La mitad de AWS |
|---|---|---|
| ¿Podés observarlo directamente? | Sí — CloudTrail, Config, VPC Flow Logs, CloudWatch, Inspector | **No** — no podés auditar una Región |
| Mecanismo de verificación | Telemetría continua, consultas puntuales | **Atestación de terceros** (SOC 1/2/3, ISO 27001/27017/27018, PCI DSS AOC, FedRAMP) obtenida desde **AWS Artifact** |
| Latencia de detección de fallas | Segundos a minutos | Cadencia de reportes (típicamente anual/semestral) + **AWS Health** para eventos operativos |
| Actor de remediación | Vos (SSM, IaC, pipeline) | SRE de AWS, opaco para vos |

Por esto existe AWS Artifact y por esto es examinable: del lado de la línea que corresponde a AWS, **auditar se reemplaza por consumir atestación**. Tu auditor no inspecciona un datacenter de AWS; tu auditor lee el reporte SOC 2 Type II que descargaste y lo deja *fuera* de tu evaluación. Eso se llama **herencia de controles** (control inheritance).

---

## 2. El modelo formal

### 2.1 Las dos mitades

```
                    ┌──────────────────────────────────────────────────┐
                    │  CUSTOMER DATA                                   │
                    ├──────────────────────────────────────────────────┤
  SECURITY  ★IN★    │  PLATFORM, APPLICATIONS, IAM                     │
  THE CLOUD         ├──────────────────────────────────────────────────┤
  (CUSTOMER)        │  OS, NETWORK & FIREWALL CONFIGURATION            │
                    ├───────────────┬───────────────┬──────────────────┤
                    │ CLIENT-SIDE   │ SERVER-SIDE   │ NETWORKING       │
                    │ ENCRYPTION &  │ ENCRYPTION    │ TRAFFIC          │
                    │ DATA          │ (FILE SYSTEM  │ PROTECTION       │
                    │ INTEGRITY     │  AND/OR DATA) │ (ENCRYPTION,     │
                    │ AUTHENTICATION│               │  INTEGRITY,      │
                    │               │               │  IDENTITY)       │
╔═══════════════════╪═══════════════╧═══════════════╧══════════════════╡
║                   │  SOFTWARE                                        │
║  SECURITY ★OF★    ├──────────┬──────────┬──────────┬─────────────────┤
║  THE CLOUD        │ COMPUTE  │ STORAGE  │ DATABASE │ NETWORKING      │
║  (AWS)            ├──────────┴──────────┴──────────┴─────────────────┤
║                   │  HARDWARE / AWS GLOBAL INFRASTRUCTURE            │
║                   ├──────────────┬─────────────────┬─────────────────┤
║                   │   REGIONS    │ AVAILABILITY    │ EDGE LOCATIONS  │
║                   │              │ ZONES           │                 │
╚═══════════════════╧══════════════╧═════════════════╧═════════════════╡
```

**AWS — "Seguridad *de* la nube":** la infraestructura global (Regiones, Zonas de Disponibilidad, Edge Locations), las instalaciones físicas y sus controles ambientales, el hardware y firmware del host, el Nitro hypervisor y las tarjetas Nitro, el tejido de red físico, el proceso de decomisionado y destrucción de medios (NIST 800-88), y el software de los servicios administrados (el plano de control de S3, la capa de almacenamiento de Aurora, el entorno de ejecución de Lambda, el plano de control de EKS).

**Cliente — "Seguridad *en* la nube":** tus datos y su clasificación; gestión de identidad y acceso (usuarios IAM, roles, políticas, federación, MFA, custodia de la cuenta root); sistemas operativos invitados y su parcheo; código de aplicación y dependencias; configuración de red (diseño de VPC, subnets, tablas de ruteo, security groups, NACLs, reglas de Network Firewall); decisiones de cifrado (qué datos, qué clave, client- o server-side); y la arquitectura de resiliencia que construís sobre las primitivas de AZ que AWS provee.

### 2.2 Las tres clases de control (frecuentemente examinadas)

| Clase de control | Definición | Ejemplos concretos | Quién actúa |
|---|---|---|---|
| **Controles heredados** | Controles que el cliente hereda completamente de AWS; el cliente no hace nada y los reclama en una auditoría vía Artifact | Controles físicos y ambientales: acceso al datacenter, supresión de incendios, redundancia eléctrica, destrucción de medios | Solo AWS |
| **Controles compartidos** | El control aplica *tanto* a la infraestructura como a las capas del cliente; **mismo objetivo de control, distinta implementación, dos ejecuciones separadas** | **Gestión de parches** (AWS parchea host/hypervisor/software de servicios administrados; vos parcheás el SO invitado y las apps) · **Gestión de configuración** (AWS configura los dispositivos de infraestructura; vos configurás tu SO, bases de datos, apps) · **Concientización y capacitación** (AWS capacita al personal de AWS; vos capacitás al tuyo) | Ambos, de forma independiente |
| **Controles específicos del cliente** | Controles enteramente del lado del cliente, impulsados por la clasificación de datos y el alcance regulatorio de la carga de trabajo | Seguridad por zonas / segmentación de zonas de datos, autorización a nivel de aplicación, tokenización, enrutar PII de clientes a Regiones específicas por residencia de datos | Solo el cliente |

> **Trampa de examen:** "control compartido" **no** significa "AWS y el cliente colaboran en una única instancia del control". Significa que el objetivo del control existe de ambos lados y cada parte ejecuta su propia copia. Que AWS parchee el Nitro hypervisor no hace nada por tu `openssl` sin parchear.

### 2.3 Lo que *nunca* se comparte

Dos ítems son permanente y exclusivamente propiedad del cliente, sin importar el servicio:

1. **Tus datos.** AWS no los clasifica, no decide su retención, y no decide quién puede leerlos.
2. **La identidad.** Las credenciales del usuario root, la custodia del dispositivo MFA, el diseño de los principals IAM, y cada `Allow` que escribís.

Y uno es permanentemente de AWS: **la capa física**. No podés inspeccionarla, y ningún modelo de servicio la transfiere jamás — con la única excepción documentada que se discute en §4.7 (Outposts, donde la seguridad del *sitio* vuelve a vos mientras el *hardware* sigue siendo de AWS).

---

## 3. El gradiente de abstracción: la responsabilidad se desplaza con el servicio

Este es el concepto de mayor rendimiento del tema. La guía CLF-C02 menciona explícitamente "cómo las responsabilidades del cliente pueden desplazarse según el servicio utilizado (por ejemplo, con RDS, Lambda, EC2)".

La propia taxonomía de seguridad de AWS divide los servicios en tres familias:

| Familia | Definición | Ejemplos | Vos gestionás | AWS gestiona |
|---|---|---|---|---|
| **Servicios de infraestructura** (IaaS) | Obtenés primitivas crudas de cómputo/almacenamiento/red y control total del SO | EC2, EBS, VPC, Auto Scaling, Elastic Load Balancing (el plano de datos que configurás) | SO invitado, parcheo, agentes, reglas de firewall, cifrado de EBS/instance store, IAM, aplicación | Hypervisor, host, red física, medios de almacenamiento, instalación |
| **Servicios de contenedor** (tipo PaaS; *no* Docker) | Una plataforma administrada corre un motor conocido; nunca iniciás sesión en el SO | RDS, Aurora, ElastiCache, EMR, Elastic Beanstalk, OpenSearch Service | Configuración del motor (parameter/option groups), usuarios y esquemas, ubicación de red, *elección* de cifrado, política de retención de backups, upgrades de versión mayor | SO, binarios del motor, parcheo menor, replicación, host, instalación |
| **Servicios abstraídos** (serverless / totalmente administrados) | Interactuás solo con un endpoint de API del servicio; no existe el concepto de host | S3, DynamoDB, SQS, SNS, Lambda, Athena, Glue, Kinesis | Datos, políticas IAM/de recurso, selección de clave de cifrado, tu código y sus dependencias | Todo lo que está debajo de la API: SO, runtime, escalado, durabilidad, ubicación multi-AZ |

### 3.1 Matriz de responsabilidad entre modelos de cómputo

| Responsabilidad | EC2 | ECS on EC2 | ECS/EKS on Fargate | EKS (plano de control) | Lambda | RDS/Aurora | S3 |
|---|---|---|---|---|---|---|---|
| Físico / instalación | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| Hypervisor / Nitro | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| Kernel del SO host | AWS | AWS | AWS | AWS | AWS | AWS | AWS |
| **Parcheo del SO invitado / AMI del nodo** | **Vos** | **Vos** | AWS (platform version) | n/a (plano de control) | AWS | AWS (en tu ventana) | AWS |
| **Reinicio / drenaje del nodo para aplicar el parche** | **Vos** | **Vos** | **Vos** (redesplegar task) | AWS | AWS | **Vos** (elección de ventana) | AWS |
| Runtime de contenedores (`containerd`) | **Vos** | **Vos** | AWS | n/a | AWS | n/a | n/a |
| Plano de control de Kubernetes (`etcd`, apiserver) | n/a | n/a | n/a | AWS | n/a | n/a | n/a |
| **Disparo del upgrade de versión de Kubernetes** | n/a | n/a | n/a | **Vos** | n/a | n/a | n/a |
| Contenido de la imagen de contenedor / CVEs de la imagen base | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | n/a | n/a |
| Código de aplicación | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | n/a | n/a |
| Dependencias de aplicación | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | n/a | n/a |
| Runtime de lenguaje / intérprete | **Vos** | **Vos** | **Vos** | **Vos** | AWS | n/a | n/a |
| **Migración por deprecación del runtime** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** (versión mayor) | n/a |
| Segmentación de red (SG/NACL/NetworkPolicy) | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** (config de VPC) | **Vos** | **Vos** (policy/VPCE) |
| IAM / política de recurso | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** |
| RBAC / admission de Kubernetes | n/a | n/a | n/a | **Vos** | n/a | n/a | n/a |
| Cifrado en reposo — *habilitación* | **Vos** | **Vos** | **Vos** | **Vos** (secrets) | AWS por defecto + **vos** (CMK) | **Vos** (en la creación) | AWS por defecto + **vos** (CMK) |
| Cifrado en tránsito — *aplicación* | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** (`rds.force_ssl`) | **Vos** (`aws:SecureTransport`) |
| Durabilidad de los bytes almacenados | AWS (EBS) | AWS | AWS | AWS | AWS | AWS | AWS |
| **Política de backup / point-in-time recovery** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** (retención) | **Vos** (versionado) |
| Topología Multi-AZ / multi-Región | **Vos** | **Vos** | **Vos** | AWS (CP) / **vos** (nodos) | AWS | **Vos** (flag Multi-AZ) | AWS (dentro de la Región) |

Leé esta matriz como una **derivada**: a medida que te movés a la derecha, tu superficie se achica pero nunca llega a cero. No existe servicio de AWS en el que no tengas ninguna responsabilidad, porque los dos ítems permanentes del cliente — **datos** e **identidad** — están presentes en cada columna.

### 3.2 Análisis de trade-offs: qué comprás al moverte a la derecha

| Dimensión | EC2 (IaaS) | RDS (plataforma administrada) | Lambda / S3 (abstraídos) |
|---|---|---|---|
| Carga operativa | La más alta: pipeline de AMIs, ventanas de parcheo, agentes, gestión de configuración | Media: estrategia de versiones, parameter groups, pruebas de failover | La más baja: IAM + código |
| Control / flexibilidad | Total: cualquier kernel, cualquier daemon, cualquier tuning | Acotado: solo los parámetros expuestos; sin `sudo`, sin acceso al SO | Mínimo: solo runtime y límites |
| Radio de impacto de *tu* error | La instancia entera y todo lo que pueda alcanzar | Contenido y conectividad de la base de datos | Acotado a la función/bucket + su rol |
| Radio de impacto del error *de AWS* | A nivel host/AZ, mitigado por tu ASG | A nivel AZ, mitigado por Multi-AZ | Absorbido internamente por AWS |
| Evidencia de cumplimiento que debés producir | Hardening del SO (CIS), reportes de cumplimiento de parches, escaneos de vulnerabilidades, AV/EDR si se requiere | Configuración del motor, cifrado, logs de acceso, evidencia de backups | Revisión de políticas IAM, key policy, logs de acceso |
| Tiempo hasta remediar un CVE crítico | Horas–días (reconstruir la AMI, rotar el ASG) | Minutos–horas (AWS publica el parche; vos elegís la ventana) | El lado de AWS es invisible; **tu dependencia** sigue siendo horas–días |
| Modelo de costos | Capacidad reservada; pagás por lo ocioso | Instance-hours + almacenamiento | Por request/por GB; casi cero en ocio |
| **Portabilidad / lock-in** | La mayor portabilidad | Media (compatible con el motor) | La menor portabilidad |
| Dónde se concentra el riesgo residual | Deriva del SO invitado | Deuda de upgrades de versión (mayores en EOL) | **Cadena de suministro de dependencias** |

**Criterio del arquitecto:** moverse a la derecha no reduce el riesgo total; lo **reubica**. Los equipos que migran de EC2 a Lambda y después nunca escanean dependencias cambiaron un riesgo bien entendido y con herramientas (parcheo de SO, que Patch Manager e Inspector resuelven) por uno pobremente instrumentado (CVEs de paquetes transitivos). Instrumentá la mitad nueva antes de desmantelar la vieja.

---

## 4. Análisis profundo de fronteras, servicio por servicio

### 4.1 EC2 — el caso de referencia para IaaS

La línea se ubica en la **interfaz de hardware virtual**. AWS entrega una máquina virtual booteada con CPU virtual, memoria, NICs y dispositivos de bloque, más el servicio de metadatos en `169.254.169.254`. Todo desde el boot loader hacia arriba es tuyo.

Las instancias modernas de AWS corren sobre el **Nitro System**: tarjetas de hardware dedicadas descargan red, EBS y almacenamiento, y el Nitro Security Chip blinda el firmware. La propiedad de diseño documentada por AWS es que **no hay acceso interactivo de operadores a los hosts Nitro** — un control clave que *heredás* y referenciás en auditorías, y que solo podés verificar mediante atestación, nunca directamente.

Tus responsabilidades innegociables en EC2:

- Parcheo del SO invitado (ver §6.2 — Patch Manager).
- **Aplicación obligatoria de IMDSv2** (`HttpTokens: required`). El simple GET de IMDSv1 es el pivote en la cadena SSRF→robo de credenciales. Esto es 100% de tu lado de la línea; AWS provee la capacidad, vos tenés que exigirla.
- Cifrado de EBS. Habilitá el **cifrado de EBS por defecto a nivel de cuenta** por Región — está apagado salvo que lo prendas.
- Security groups y NACLs.
- Agentes: SSM Agent (incluido en Amazon Linux y en AMIs recientes de Ubuntu, pero el **rol IAM es tuyo**), CloudWatch Agent, EDR.
- **AMIs de terceros y de la comunidad**: validar una AMI del Marketplace o pública es enteramente tuyo. AWS no audita el contenido de una AMI comunitaria.

### 4.2 ECS / EKS / Fargate — tres líneas distintas en una misma familia de productos

- **ECS on EC2 / EKS autogestionado o con managed node groups:** los nodos son instancias EC2. Sos dueño de la AMI, del kernel, de `containerd` y del ciclo de vida del nodo. Los managed node groups de EKS automatizan el reemplazo rotativo, pero **vos tenés que iniciarlo**.
- **Fargate:** AWS es dueño del host y del runtime. La sutileza que atrapa a los SREs: una **actualización de platform version de Fargate no parchea retroactivamente una task en ejecución**. Las tasks existentes conservan la platform version con la que se lanzaron. Tenés que forzar un nuevo deployment para tomar la plataforma parcheada. AWS parcheó; vos tenés que redesplegar. Eso es un control compartido en su forma más pura.
- **Plano de control de EKS:** AWS corre y parchea `kube-apiserver`, `etcd`, el scheduler y el controller manager a través de múltiples AZs. Vos sos dueño del **RBAC de Kubernetes**, Pod Security Admission, admission webhooks, `NetworkPolicy`, cifrado de secrets (cifrado de sobre con KMS para los secrets de `etcd`), diseño de roles IRSA/Pod Identity y — críticamente — **disparar el upgrade de versión menor de Kubernetes** antes de que tu versión salga del soporte estándar.

### 4.3 RDS / Aurora — la frontera de la plataforma administrada

AWS te da: gestión del SO, instalación de los binarios del motor, parcheo de versiones **menores**, mecánica de backups automatizados, automatización de failover Multi-AZ, y la capa de almacenamiento distribuido de Aurora (seis copias en tres AZs).

Vos conservás, y comúnmente se te escapa:

| Ítem | Realidad |
|---|---|
| Cifrado en reposo | **Debe elegirse en la creación del cluster/instancia.** No podés activarlo en una instancia existente sin cifrar — restaurás un snapshot en una nueva instancia cifrada. |
| Cifrado en tránsito | No se aplica por defecto en la mayoría de los motores. Configurás `rds.force_ssl=1` (PostgreSQL) / `require_secure_transport=ON` (MySQL) en un **parameter group personalizado** — el parameter group por defecto no es editable. |
| Ventana de mantenimiento | AWS *tiene* el parche; **vos** decidís cuándo aterriza. Diferirlo indefinidamente es tu riesgo. |
| Auto-upgrade de versión menor | Un flag (`AutoMinorVersionUpgrade`) que configurás. |
| **Upgrade de versión mayor** | Enteramente tuyo. Que un motor llegue al fin del soporte estándar y pase a soporte extendido pago es una falla del cliente, no de AWS. |
| Usuarios de base de datos, roles, `GRANT`s | Tuyos. AWS crea solo el usuario maestro que nombrás. |
| Exposición de red | `PubliclyAccessible`, subnet group, security groups — todo tuyo. |
| Retención de backups y ventana de PITR | Tuyas. Retención `0` deshabilita los backups automáticos. |
| Protección contra borrado | Tuya. |

### 4.4 Lambda — abstraído, pero no libre de responsabilidad

AWS es dueño de: la microVM Firecracker, el host, el SO del entorno de ejecución, el **runtime administrado** (intérprete/JVM), el escalado y la ubicación multi-AZ.

Vos sos dueño de:

- **Tu código y cada dependencia que empaquetás.** AWS parchea Python 3.12; AWS no parchea tu `urllib3` vendorizado. Amazon Inspector soporta escaneo de código y paquetes de Lambda precisamente porque esta brecha es real.
- **Deprecación del runtime.** Cuando un runtime llega al fin de soporte, la migración es tu trabajo.
- El **rol de ejecución** — el control de Lambda del que más se abusa. `AdministratorAccess` en una función es un crítico del lado del cliente.
- Adjuntar la VPC, subnets y security groups cuando la función necesita acceso privado.
- Secretos en variables de entorno: Lambda las cifra en reposo con una clave KMS, pero poner una credencial en texto plano donde cualquiera que llame a `lambda:GetFunctionConfiguration` pueda leerla es tuyo.
- Límites de concurrencia (un control de DoS/costo), timeouts y destinos de dead-letter/on-failure.

### 4.5 S3 — dónde cambiaron los defaults, y por qué sigue importando

AWS provee 99,999999999% (11 nueves) de durabilidad de diseño, replicación automática en ≥3 AZs de la Región y, desde enero de 2023, **cifrado SSE-S3 aplicado por defecto a todos los objetos nuevos**. Desde abril de 2023, los buckets nuevos tienen **S3 Block Public Access habilitado** y **ACLs deshabilitadas** (Object Ownership = *Bucket owner enforced*) por defecto.

Vos seguís siendo dueño de:

- **Apagar esos defaults.** Son valores por defecto, no barandas. La baranda es un SCP (§6.4).
- Bucket policies y access points.
- **Versionado, MFA Delete, Object Lock** — porque durabilidad no es lo mismo que *deshacer un borrado*. AWS va a almacenar fiel y durablemente el resultado de tu `DeleteObject`. La protección contra tu propio borrado es un control del cliente.
- Elegir SSE-KMS con una clave gestionada por el cliente cuando necesitás control de acceso a nivel de key policy y visibilidad en CloudTrail del uso de la clave.
- Exigir TLS (`aws:SecureTransport`) y restringir el camino de red (VPC endpoints, `aws:SourceVpce`).
- Políticas de ciclo de vida y replicación cross-Region para tu RTO/RPO — no los de AWS.

### 4.6 KMS — material de clave vs. key policy

AWS opera HSMs validados FIPS, garantiza que el material de clave en texto plano de las claves KMS administradas por AWS y gestionadas por el cliente nunca sale del límite del HSM sin cifrar, y se ocupa de la durabilidad y la disponibilidad multi-AZ de los HSMs.

Vos sos dueño de: **la key policy** (el único documento de autorización obligatorio para una clave KMS — una política IAM por sí sola no puede otorgar acceso salvo que la key policy delegue en IAM), los grants, los alias, la configuración de rotación, la programación del borrado (el período de espera de 7–30 días es tu última línea de defensa) y la topología de claves multi-Región.

### 4.7 Outposts, Local Zones, Wavelength — la frontera se mueve

**AWS Outposts** es el único lugar donde la capa física vuelve parcialmente a vos:

| Ítem | Dueño |
|---|---|
| Hardware del rack, firmware, break/fix, capacidad | AWS (técnicos de AWS visitan tu sitio) |
| **Seguridad física del sitio, control de acceso al rack** | **Vos** |
| Energía, refrigeración, espacio de piso | **Vos** |
| Conectividad de red hacia la Región padre (service link) | **Vos** (el circuito) / AWS (el túnel) |
| Datos en el Outpost | **Vos** |
| Cifrado: la Nitro Security Key | **Vos** debés conservarla; quitarla deja los datos locales ilegibles |

Para **Local Zones** y **Wavelength Zones**, AWS sigue siendo responsable de la seguridad física aunque el equipamiento esté en una instalación de colocation o de un operador de telecomunicaciones.

---

## 5. Responsabilidad compartida para resiliencia y disponibilidad

AWS publica un modelo paralelo para resiliencia. Es examinable de forma encubierta: preguntas formuladas como "la aplicación se cayó cuando falló una AZ — ¿quién es responsable?".

| Aspecto | Responsabilidad de AWS | Responsabilidad del cliente |
|---|---|---|
| Independencia de AZ (energía, refrigeración, red, llanura de inundación) | **AWS** | — |
| Disponibilidad de Regiones y AZs | **AWS** | — |
| Redundancia interna de servicios administrados (S3, DynamoDB, Lambda, almacenamiento de Aurora) | **AWS** | — |
| **Desplegar en ≥2 AZs** | Provee la primitiva | **Vos** debés diseñar para eso |
| DR multi-Región | Provee las primitivas (Route 53, Global Tables, CRR) | **Vos** diseñás el RTO/RPO |
| Health checks y configuración de failover | — | **Vos** |
| Backups y *pruebas* de restauración | Corre la maquinaria de backup que habilitás | **Vos** habilitás, retenés **y probás la restauración** |
| Capacidad / cuotas de servicio | Publica las cuotas | **Vos** monitoreás y pedís los aumentos |
| Degradación elegante, reintentos, backoff exponencial, idempotencia | — | **Vos** |

Dos verdades duras para arquitectos:

1. **Un SLA es un instrumento de facturación, no una garantía de disponibilidad.** El Amazon Compute SLA ofrece 99,99% de uptime mensual a *nivel Región* (multi-AZ) pero solo 99,5% a *nivel instancia*; el SLA de S3 Standard es 99,9%. Incumplirlo da **créditos de servicio**, escalonados por severidad. Un crédito del 100% sobre una factura mensual de $4.000 no compensa una caída que genera pérdida de ingresos. La disponibilidad la diseñás vos; el SLA solamente le pone precio al incumplimiento de AWS.
2. **Un despliegue en una sola AZ que muere junto con su AZ es una falla del cliente**, aunque la falla de la AZ haya sido de AWS. AWS cumplió su obligación al ofrecer tres o más AZs independientes; vos elegiste no usarlas.

---

## 6. Codificar la frontera como infraestructura

La prosa no aplica nada. Abajo hay artefactos completos y desplegables que implementan la mitad del cliente.

### 6.1 Plano de datos endurecido — S3 + KMS (`shared-responsibility-data-plane.yaml`)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Customer-side controls for the "security IN the cloud" half of the shared
  responsibility model: customer managed KMS key, encrypted and versioned data
  bucket with Object Lock, dedicated server access log bucket, and a resource
  policy enforcing TLS and the intended KMS key.

Parameters:
  DataClassification:
    Type: String
    Default: confidential
    AllowedValues: [public, internal, confidential, restricted]
    Description: Drives retention and is stamped on every resource as a tag.
  RetentionDays:
    Type: Number
    Default: 30
    MinValue: 1
    MaxValue: 3650
    Description: Default Object Lock retention in GOVERNANCE mode.
  LogRetentionDays:
    Type: Number
    Default: 400
    MinValue: 1
    MaxValue: 3650
  AllowedVpcEndpointId:
    Type: String
    Default: ''
    Description: >
      Optional VPC endpoint id (vpce-xxxx). When provided, all access to the
      data bucket is restricted to that endpoint.

Conditions:
  RestrictToVpce: !Not [!Equals [!Ref AllowedVpcEndpointId, '']]

Resources:

  ##########################################################################
  # Customer managed key. AWS owns the HSM; the key POLICY below is ours.
  ##########################################################################
  DataKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${AWS::StackName} ${DataClassification} data at rest'
      Enabled: true
      EnableKeyRotation: true
      KeySpec: SYMMETRIC_DEFAULT
      KeyUsage: ENCRYPT_DECRYPT
      MultiRegion: false
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: data-key-policy
        Statement:
          - Sid: EnableIAMPolicyDelegation
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowS3ServiceUseWithinThisAccount
            Effect: Allow
            Principal:
              Service: s3.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey
              - kms:DescribeKey
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId
                'kms:ViaService': !Sub 's3.${AWS::Region}.amazonaws.com'
          - Sid: DenyKeyDeletionOutsideBreakGlass
            Effect: Deny
            Principal: '*'
            Action:
              - kms:ScheduleKeyDeletion
              - kms:DisableKey
            Resource: '*'
            Condition:
              StringNotLike:
                'aws:PrincipalArn': !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/BreakGlassAdmin'
      Tags:
        - Key: DataClassification
          Value: !Ref DataClassification
        - Key: ResponsibilityBoundary
          Value: customer

  DataKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${AWS::StackName}-data'
      TargetKeyId: !Ref DataKey

  ##########################################################################
  # Server access log bucket. Must exist before the data bucket references it.
  ##########################################################################
  AccessLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${AWS::StackName}-access-logs-${AWS::AccountId}-${AWS::Region}'
      # S3 server access logging cannot write to an SSE-KMS bucket; SSE-S3 only.
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: expire-access-logs
            Status: Enabled
            ExpirationInDays: !Ref LogRetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
          - Id: abort-incomplete-mpu
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: ResponsibilityBoundary
          Value: customer

  AccessLogBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref AccessLogBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowS3ServerAccessLogging
            Effect: Allow
            Principal:
              Service: logging.s3.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${AccessLogBucket.Arn}/s3-access/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt AccessLogBucket.Arn
              - !Sub '${AccessLogBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  ##########################################################################
  # Data bucket.
  ##########################################################################
  DataBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    DependsOn: AccessLogBucketPolicy
    Properties:
      BucketName: !Sub '${AWS::StackName}-data-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt DataKey.Arn
            # S3 Bucket Keys cut KMS API calls (and cost) by ~99%.
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      # Object Lock requires versioning to be enabled at creation time.
      VersioningConfiguration:
        Status: Enabled
      ObjectLockEnabled: true
      ObjectLockConfiguration:
        ObjectLockEnabled: Enabled
        Rule:
          DefaultRetention:
            Mode: GOVERNANCE
            Days: !Ref RetentionDays
      LoggingConfiguration:
        DestinationBucketName: !Ref AccessLogBucket
        LogFilePrefix: 's3-access/'
      LifecycleConfiguration:
        Rules:
          - Id: transition-cold
            Status: Enabled
            Transitions:
              - StorageClass: INTELLIGENT_TIERING
                TransitionInDays: 30
            NoncurrentVersionTransitions:
              - StorageClass: GLACIER_IR
                TransitionInDays: 30
          - Id: abort-incomplete-mpu
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: DataClassification
          Value: !Ref DataClassification
        - Key: ResponsibilityBoundary
          Value: customer

  DataBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref DataBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyOutdatedTLS
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              NumericLessThan:
                's3:TlsVersion': '1.2'
          # NOTE: we deny only an EXPLICIT WRONG key, never a MISSING header.
          # Bucket default encryption is applied AFTER policy evaluation, so a
          # StringNotEquals on s3:x-amz-server-side-encryption would reject
          # perfectly valid header-less PUTs. See the diagnostics section.
          - Sid: DenyWrongKmsKey
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEqualsIfExists:
                's3:x-amz-server-side-encryption-aws-kms-key-id': !GetAtt DataKey.Arn
              'Null':
                's3:x-amz-server-side-encryption-aws-kms-key-id': 'false'
          - !If
            - RestrictToVpce
            - Sid: RestrictToNamedVpcEndpoint
              Effect: Deny
              Principal: '*'
              Action: 's3:*'
              Resource:
                - !GetAtt DataBucket.Arn
                - !Sub '${DataBucket.Arn}/*'
              Condition:
                StringNotEquals:
                  'aws:SourceVpce': !Ref AllowedVpcEndpointId
                ArnNotLike:
                  'aws:PrincipalArn': !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/BreakGlassAdmin'
            - !Ref AWS::NoValue

Outputs:
  DataBucketName:
    Description: Bucket holding customer data (customer responsibility).
    Value: !Ref DataBucket
    Export:
      Name: !Sub '${AWS::StackName}-DataBucketName'
  DataBucketArn:
    Value: !GetAtt DataBucket.Arn
  AccessLogBucketName:
    Value: !Ref AccessLogBucket
  DataKeyArn:
    Description: CMK ARN. AWS operates the HSM; we own this key policy.
    Value: !GetAtt DataKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-DataKeyArn'
  DataKeyAliasName:
    Value: !Ref DataKeyAlias
```

### 6.2 El control compartido hecho concreto — Patch Manager (`shared-responsibility-patching.yaml`)

La gestión de parches es *el* control compartido canónico. AWS parchea el hypervisor; esta plantilla parchea tu mitad, con un cronograma y con reporte de cumplimiento.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Customer half of the "patch management" shared control: a custom patch
  baseline, a patch group, a maintenance window that runs AWS-RunPatchBaseline,
  an instance profile with the SSM managed policy, and Config rules that prove
  the control is working.

Parameters:
  PatchGroupName:
    Type: String
    Default: prod-linux
  ApproveAfterDays:
    Type: Number
    Default: 7
    MinValue: 0
    MaxValue: 100
    Description: Soak period before an approved patch is installed.
  MaintenanceCron:
    Type: String
    Default: 'cron(0 3 ? * SUN *)'
    Description: UTC schedule for the patching window.
  MaintenanceDurationHours:
    Type: Number
    Default: 4
  MaintenanceCutoffHours:
    Type: Number
    Default: 1
  MaxConcurrency:
    Type: String
    Default: '20%'
  MaxErrors:
    Type: String
    Default: '5%'
  RebootOption:
    Type: String
    Default: RebootIfNeeded
    AllowedValues: [RebootIfNeeded, NoReboot]

Resources:

  ##########################################################################
  # Where patch logs land. Retained as audit evidence for the shared control.
  ##########################################################################
  PatchLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${AWS::StackName}-patch-logs-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: retain-patch-evidence
            Status: Enabled
            ExpirationInDays: 400

  ##########################################################################
  # Custom patch baseline. The DEFAULT AWS baseline auto-approves security
  # updates with 0 days soak; production usually wants a soak period.
  ##########################################################################
  LinuxPatchBaseline:
    Type: AWS::SSM::PatchBaseline
    Properties:
      Name: !Sub '${AWS::StackName}-al2023-baseline'
      Description: Amazon Linux 2023 security + bugfix baseline with soak period.
      OperatingSystem: AMAZON_LINUX_2023
      ApprovedPatchesComplianceLevel: CRITICAL
      ApprovedPatchesEnableNonSecurity: false
      RejectedPatchesAction: BLOCK
      RejectedPatches:
        # Example: a kernel build known to break a vendor driver. Documented,
        # time-boxed exceptions only - this is technical debt with a CVE.
        - 'kernel-6.1.72-96.166.amzn2023'
      ApprovalRules:
        PatchRules:
          - ComplianceLevel: CRITICAL
            ApproveAfterDays: 0
            EnableNonSecurity: false
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Security']
                - Key: SEVERITY
                  Values: ['Critical']
          - ComplianceLevel: HIGH
            ApproveAfterDays: !Ref ApproveAfterDays
            EnableNonSecurity: false
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Security']
                - Key: SEVERITY
                  Values: ['Important', 'Medium']
          - ComplianceLevel: MEDIUM
            ApproveAfterDays: 30
            EnableNonSecurity: true
            PatchFilterGroup:
              PatchFilters:
                - Key: CLASSIFICATION
                  Values: ['Bugfix']
      PatchGroups:
        - !Ref PatchGroupName
      Tags:
        - Key: ResponsibilityBoundary
          Value: customer-shared-control

  ##########################################################################
  # Instance profile: without this role, SSM cannot reach the instance and
  # your half of the patch control silently does not run.
  ##########################################################################
  ManagedInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${AWS::StackName}-managed-instance'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore'
      Policies:
        - PolicyName: patch-log-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 's3:PutObject'
                  - 's3:PutObjectAcl'
                Resource: !Sub '${PatchLogBucket.Arn}/*'
              - Effect: Allow
                Action: 's3:GetEncryptionConfiguration'
                Resource: !GetAtt PatchLogBucket.Arn

  ManagedInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${AWS::StackName}-managed-instance'
      Roles:
        - !Ref ManagedInstanceRole

  ##########################################################################
  # Maintenance window.
  ##########################################################################
  MaintenanceWindowRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${AWS::StackName}-maintenance-window'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ssm.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole'

  PatchWindow:
    Type: AWS::SSM::MaintenanceWindow
    Properties:
      Name: !Sub '${AWS::StackName}-patch-window'
      Description: Weekly guest OS patching - customer side of the shared control.
      Schedule: !Ref MaintenanceCron
      ScheduleTimezone: 'UTC'
      Duration: !Ref MaintenanceDurationHours
      Cutoff: !Ref MaintenanceCutoffHours
      AllowUnassociatedTargets: false

  PatchWindowTarget:
    Type: AWS::SSM::MaintenanceWindowTarget
    Properties:
      Name: !Sub '${AWS::StackName}-patch-target'
      WindowId: !Ref PatchWindow
      ResourceType: INSTANCE
      Targets:
        - Key: 'tag:Patch Group'
          Values:
            - !Ref PatchGroupName

  PatchWindowTask:
    Type: AWS::SSM::MaintenanceWindowTask
    Properties:
      Name: !Sub '${AWS::StackName}-run-patch-baseline'
      WindowId: !Ref PatchWindow
      TaskType: RUN_COMMAND
      TaskArn: 'AWS-RunPatchBaseline'
      Priority: 1
      ServiceRoleArn: !GetAtt MaintenanceWindowRole.Arn
      MaxConcurrency: !Ref MaxConcurrency
      MaxErrors: !Ref MaxErrors
      CutoffBehavior: CANCEL_TASK
      Targets:
        - Key: WindowTargetIds
          Values:
            - !Ref PatchWindowTarget
      TaskInvocationParameters:
        MaintenanceWindowRunCommandParameters:
          Comment: 'Weekly AL2023 patching'
          TimeoutSeconds: 3600
          OutputS3BucketName: !Ref PatchLogBucket
          OutputS3KeyPrefix: 'patch-runs/'
          Parameters:
            Operation:
              - Install
            RebootOption:
              - !Ref RebootOption

  ##########################################################################
  # Proof that the control ran. These Config rules require an active
  # configuration recorder + delivery channel in this Region.
  ##########################################################################
  RuleInstancesManagedBySsm:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-instance-managed-by-ssm
      Description: EC2 instances must be managed by Systems Manager.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
          - 'AWS::SSM::ManagedInstanceInventory'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_INSTANCE_MANAGED_BY_SSM

  RulePatchCompliance:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-managedinstance-patch-compliance-status-check
      Description: Managed instances must report COMPLIANT patch status.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::SSM::PatchCompliance'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_MANAGEDINSTANCE_PATCH_COMPLIANCE_STATUS_CHECK

  RuleImdsV2:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: ec2-imdsv2-check
      Description: Instances must require IMDSv2 tokens.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
      Source:
        Owner: AWS
        SourceIdentifier: EC2_IMDSV2_CHECK

  RuleEncryptedVolumes:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: encrypted-volumes
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Volume'
      Source:
        Owner: AWS
        SourceIdentifier: ENCRYPTED_VOLUMES

  RuleRootMfa:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: root-account-mfa-enabled
      Description: Root user custody is a permanent customer responsibility.
      MaximumExecutionFrequency: TwentyFour_Hours
      Source:
        Owner: AWS
        SourceIdentifier: ROOT_ACCOUNT_MFA_ENABLED

Outputs:
  PatchBaselineId:
    Value: !Ref LinuxPatchBaseline
  PatchGroup:
    Description: Tag instances with `Patch Group` = this value.
    Value: !Ref PatchGroupName
  MaintenanceWindowId:
    Value: !Ref PatchWindow
  InstanceProfileName:
    Value: !Ref ManagedInstanceProfile
  PatchLogBucketName:
    Value: !Ref PatchLogBucket
```

### 6.3 Launch template — cerrando las brechas de IMDS y cifrado

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  EC2 launch template encoding the guest-side controls the customer owns:
  IMDSv2 required, hop limit 1, encrypted EBS with a CMK, Nitro Enclaves off,
  detailed monitoring on, and the Patch Group tag that binds the instance to
  the maintenance window.

Parameters:
  PatchGroupName:
    Type: String
    Default: prod-linux
  InstanceProfileName:
    Type: String
    Description: Output InstanceProfileName from the patching stack.
  KmsKeyArn:
    Type: String
    Description: CMK ARN used to encrypt the root volume.
  InstanceType:
    Type: String
    Default: m6i.large
  AmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64'
    Description: Resolved from the AWS-published SSM public parameter.
  SecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id

Resources:
  HardenedLaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-hardened'
      LaunchTemplateData:
        ImageId: !Ref AmiId
        InstanceType: !Ref InstanceType
        IamInstanceProfile:
          Name: !Ref InstanceProfileName
        SecurityGroupIds:
          - !Ref SecurityGroupId
        # IMDSv2 required. This single block removes the SSRF -> credential
        # exfiltration path that IMDSv1 leaves open. 100% customer side.
        MetadataOptions:
          HttpTokens: required
          HttpPutResponseHopLimit: 1
          HttpEndpoint: enabled
          InstanceMetadataTags: enabled
        Monitoring:
          Enabled: true
        EnclaveOptions:
          Enabled: false
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeType: gp3
              VolumeSize: 30
              Iops: 3000
              Throughput: 125
              Encrypted: true
              KmsKeyId: !Ref KmsKeyArn
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: 'Patch Group'
                Value: !Ref PatchGroupName
              - Key: ResponsibilityBoundary
                Value: customer
          - ResourceType: volume
            Tags:
              - Key: 'Patch Group'
                Value: !Ref PatchGroupName
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euo pipefail
            # Fail fast if SSM Agent is absent: without it, the customer half
            # of the patch shared control cannot execute.
            systemctl enable --now amazon-ssm-agent
            systemctl is-active --quiet amazon-ssm-agent || {
              echo "FATAL: amazon-ssm-agent not running" >&2
              exit 1
            }
            dnf -y install amazon-cloudwatch-agent
            # Prove IMDSv1 is refused before the app ever starts.
            if curl -s -f --max-time 2 http://169.254.169.254/latest/meta-data/ ; then
              echo "FATAL: IMDSv1 is answering; launch template not applied" >&2
              exit 1
            fi

Outputs:
  LaunchTemplateId:
    Value: !Ref HardenedLaunchTemplate
  LaunchTemplateLatestVersion:
    Value: !GetAtt HardenedLaunchTemplate.LatestVersionNumber
```

### 6.4 Hacer irrepresentable el estado malo — Service Control Policy

Las reglas de Config *detectan*. Los SCPs *previenen*. Un SCP es la expresión más fuerte de "aceptamos esta responsabilidad y nos negamos a permitir la deriva".

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Organization-level guardrails. Deploy in the management account with
  SERVICE_CONTROL_POLICY enabled. SCPs set the permission CEILING; they never
  grant. An SCP cannot restrict the management account's root user.

Parameters:
  TargetOuId:
    Type: String
    Description: OU id (ou-xxxx-xxxxxxxx) to attach the policy to.
  HomeRegions:
    Type: CommaDelimitedList
    Default: 'eu-west-1,us-east-1'
    Description: Regions permitted for regional services (data residency).

Resources:
  ResponsibilityGuardrails:
    Type: AWS::Organizations::Policy
    Properties:
      Name: !Sub '${AWS::StackName}-responsibility-guardrails'
      Description: Prevents drift on customer-owned security controls.
      Type: SERVICE_CONTROL_POLICY
      TargetIds:
        - !Ref TargetOuId
      Content: !Sub
        - |
          {
            "Version": "2012-10-17",
            "Statement": [
              {
                "Sid": "DenyDisablingS3BlockPublicAccess",
                "Effect": "Deny",
                "Action": [
                  "s3:PutAccountPublicAccessBlock",
                  "s3:PutBucketPublicAccessBlock"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/BreakGlassAdmin"
                  }
                }
              },
              {
                "Sid": "DenyUnencryptedEbsVolumeCreation",
                "Effect": "Deny",
                "Action": "ec2:CreateVolume",
                "Resource": "*",
                "Condition": {
                  "Bool": { "ec2:Encrypted": "false" }
                }
              },
              {
                "Sid": "DenyRunInstancesWithoutImdsV2",
                "Effect": "Deny",
                "Action": "ec2:RunInstances",
                "Resource": "arn:aws:ec2:*:*:instance/*",
                "Condition": {
                  "StringNotEquals": {
                    "ec2:MetadataHttpTokens": "required"
                  }
                }
              },
              {
                "Sid": "DenyUnencryptedRdsCreation",
                "Effect": "Deny",
                "Action": [
                  "rds:CreateDBInstance",
                  "rds:CreateDBCluster"
                ],
                "Resource": "*",
                "Condition": {
                  "Bool": { "rds:StorageEncrypted": "false" }
                }
              },
              {
                "Sid": "DenyTurningOffAuditTelemetry",
                "Effect": "Deny",
                "Action": [
                  "cloudtrail:StopLogging",
                  "cloudtrail:DeleteTrail",
                  "cloudtrail:UpdateTrail",
                  "config:DeleteConfigurationRecorder",
                  "config:StopConfigurationRecorder",
                  "config:DeleteDeliveryChannel",
                  "config:DeleteConfigRule",
                  "guardduty:DeleteDetector",
                  "guardduty:DisassociateFromMasterAccount",
                  "securityhub:DisableSecurityHub",
                  "securityhub:DeleteMembers"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/SecurityAdmin"
                  }
                }
              },
              {
                "Sid": "DenyRootUserActions",
                "Effect": "Deny",
                "Action": "*",
                "Resource": "*",
                "Condition": {
                  "StringLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:root"
                  }
                }
              },
              {
                "Sid": "DenyKmsKeyDeletion",
                "Effect": "Deny",
                "Action": [
                  "kms:ScheduleKeyDeletion",
                  "kms:DisableKeyRotation"
                ],
                "Resource": "*",
                "Condition": {
                  "ArnNotLike": {
                    "aws:PrincipalArn": "arn:aws:iam::*:role/BreakGlassAdmin"
                  }
                }
              },
              {
                "Sid": "DenyOutsideHomeRegions",
                "Effect": "Deny",
                "NotAction": [
                  "iam:*",
                  "organizations:*",
                  "sts:*",
                  "route53:*",
                  "cloudfront:*",
                  "waf:*",
                  "wafv2:*",
                  "shield:*",
                  "support:*",
                  "budgets:*",
                  "ce:*",
                  "health:*",
                  "artifact:*"
                ],
                "Resource": "*",
                "Condition": {
                  "StringNotEquals": {
                    "aws:RequestedRegion": [ ${RegionList} ]
                  }
                }
              }
            ]
          }
        - RegionList: !Join
            - ', '
            - - !Sub ['"${R}"', {R: !Select [0, !Ref HomeRegions]}]
              - !Sub ['"${R}"', {R: !Select [1, !Ref HomeRegions]}]

Outputs:
  PolicyId:
    Value: !Ref ResponsibilityGuardrails
```

### 6.5 La mitad del cliente en EKS (`eks-customer-controls.yaml`)

AWS corre el plano de control. Todo lo que sigue es tuyo — y nada de esto se crea por vos.

```yaml
---
# Namespace with Pod Security Admission enforced at the "restricted" profile.
# AWS does not set this. An EKS cluster with no PSA labels admits privileged
# pods by default.
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    responsibility-boundary: customer
---
# Default-deny ingress AND egress. Requires the VPC CNI network policy agent
# (enableNetworkPolicy=true on the aws-node add-on) or Calico; without a policy
# engine installed this object is silently inert.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-gateway-and-dns-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # RDS in the VPC. Egress to the wider internet stays denied.
    - to:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 5432
---
# IRSA: the pod assumes an IAM role scoped to exactly what it needs.
# The trust policy on the IAM side must pin sub == this ServiceAccount.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/payments-api-irsa
    eks.amazonaws.com/sts-regional-endpoints: "true"
automountServiceAccountToken: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payments-api
      containers:
        - name: api
          # Digest-pinned. Tag-pinning is not supply-chain control.
          image: 111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api@sha256:3f8b1c2d4e5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app: payments-api
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

---

## 7. Verificación: probar cada lado de la línea

### 7.1 Establecer el principal y la cuenta

```console
$ aws sts get-caller-identity --output json
{
    "UserId": "AROA2XYZEXAMPLE7QF4:platform-sre",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/PlatformSRE/platform-sre"
}
```

### 7.2 Confirmar dónde se ubica realmente la frontera de AWS (Nitro)

`describe-instances` reporta `Hypervisor: xen` incluso en hosts Nitro, por compatibilidad hacia atrás de la API. Consultá el *tipo de instancia* en su lugar:

```console
$ aws ec2 describe-instance-types --instance-types m6i.large \
    --query 'InstanceTypes[].{Type:InstanceType,Hypervisor:Hypervisor,Nitro:NitroEnclavesSupport,BareMetal:BareMetal}' \
    --output table
-------------------------------------------------------------
|                   DescribeInstanceTypes                   |
+------------+-------------+-------------+------------------+
| BareMetal  | Hypervisor  |   Nitro     |      Type        |
+------------+-------------+-------------+------------------+
|  False     |  nitro      |  supported  |  m6i.large       |
+------------+-------------+-------------+------------------+
```

`Hypervisor: nitro` es la afirmación legible por máquina de que todo lo que está debajo del kernel invitado es de AWS.

### 7.3 Ver a AWS actuando de su lado de la línea

El mantenimiento iniciado por AWS aparece como eventos de instancia. Estos son AWS ejerciendo *su* responsabilidad mientras requiere *tu* cooperación:

```console
$ aws ec2 describe-instance-status --include-all-instances \
    --query 'InstanceStatuses[?Events].{Id:InstanceId,Event:Events[0].Code,Desc:Events[0].Description,NotBefore:Events[0].NotBefore}' \
    --output table
-------------------------------------------------------------------------------------------------------------
|                                          DescribeInstanceStatus                                           |
+------------------------------------------+---------------------+----------------------+-------------------+
|                   Desc                   |        Event        |          Id          |     NotBefore     |
+------------------------------------------+---------------------+----------------------+-------------------+
|  The instance is running on degraded ...  |  instance-retirement |  i-0a1b2c3d4e5f6a7b8 | 2026-09-17T00:00Z |
|  Scheduled reboot for host maintenance   |  system-reboot       |  i-09f8e7d6c5b4a3210 | 2026-09-10T02:00Z |
+------------------------------------------+---------------------+----------------------+-------------------+
```

Eventos del lado de AWS a nivel de flota (Business/Enterprise Support, endpoint global en `us-east-1`):

```console
$ aws health describe-events --region us-east-1 \
    --filter eventTypeCategories=scheduledChange,issue eventStatusCodes=open,upcoming \
    --query 'events[].{Arn:arn,Service:service,Category:eventTypeCategory,Region:region,Start:startTime}' \
    --output table
--------------------------------------------------------------------------------------------------------
|                                          DescribeEvents                                              |
+------------------+---------------------------------------------------+-----------+---------+---------+
|     Category     |                        Arn                        |  Region   | Service |  Start  |
+------------------+---------------------------------------------------+-----------+---------+---------+
| scheduledChange  | arn:aws:health:eu-west-1::event/EC2/AWS_EC2_...    | eu-west-1 | EC2     | ...     |
+------------------+---------------------------------------------------+-----------+---------+---------+
```

### 7.4 Probar tu mitad del control compartido de parcheo

```console
$ aws ssm describe-instance-information \
    --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName,Ver:PlatformVersion}' \
    --output table
--------------------------------------------------------------------------------------------
|                              DescribeInstanceInformation                                 |
+------------+----------------------+-----------+-------------------------+----------------+
|   Agent    |         Id           |   Ping    |        Platform         |      Ver       |
+------------+----------------------+-----------+-------------------------+----------------+
|  3.3.1345.0|  i-0a1b2c3d4e5f6a7b8 |  Online   |  Amazon Linux           |  2023          |
|  3.3.1345.0|  i-09f8e7d6c5b4a3210 |  Online   |  Amazon Linux           |  2023          |
|  3.2.2086.0|  i-0c0ffee1234567890 | ConnectionLost | Amazon Linux       |  2023          |
+------------+----------------------+-----------+-------------------------+----------------+
```

`ConnectionLost` significa que tu control de parcheo **no está corriendo** en esa instancia — un agujero de cumplimiento silencioso.

```console
$ aws ssm describe-instance-patch-states --instance-ids i-0a1b2c3d4e5f6a7b8 --output json
{
    "InstancePatchStates": [
        {
            "InstanceId": "i-0a1b2c3d4e5f6a7b8",
            "PatchGroup": "prod-linux",
            "BaselineId": "pb-0f1e2d3c4b5a69788",
            "SnapshotId": "9d4e2b1a-6c7f-4a3b-8e1d-2f5a7c9b0e34",
            "OperationStartTime": "2026-08-30T03:00:11.412000+00:00",
            "OperationEndTime": "2026-08-30T03:07:52.908000+00:00",
            "Operation": "Install",
            "RebootOption": "RebootIfNeeded",
            "InstalledCount": 41,
            "InstalledOtherCount": 226,
            "InstalledPendingRebootCount": 0,
            "InstalledRejectedCount": 1,
            "MissingCount": 0,
            "FailedCount": 0,
            "NotApplicableCount": 812,
            "UnreportedNotApplicableCount": 799,
            "CriticalNonCompliantCount": 0,
            "SecurityNonCompliantCount": 0,
            "OtherNonCompliantCount": 3
        }
    ]
}
```

Consolidado de flota:

```console
$ aws ssm describe-instance-patch-states-for-patch-group --patch-group prod-linux \
    --query 'InstancePatchStates[].{Id:InstanceId,Missing:MissingCount,Failed:FailedCount,CritNC:CriticalNonCompliantCount,SecNC:SecurityNonCompliantCount}' \
    --output table
----------------------------------------------------------------------------
|                DescribeInstancePatchStatesForPatchGroup                   |
+---------+----------+----------------------+-----------+------------------+
| CritNC  | Failed   |         Id           |  Missing  |      SecNC       |
+---------+----------+----------------------+-----------+------------------+
|  0      |  0       |  i-0a1b2c3d4e5f6a7b8 |  0        |  0               |
|  2      |  1       |  i-09f8e7d6c5b4a3210 |  7        |  5               |
+---------+----------+----------------------+-----------+------------------+
```

### 7.5 Probar los controles de cifrado y exposición

```console
$ aws s3api get-public-access-block --bucket shared-resp-data-111122223333-eu-west-1
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}

$ aws s3api get-bucket-encryption --bucket shared-resp-data-111122223333-eu-west-1 \
    --query 'ServerSideEncryptionConfiguration.Rules[0]'
{
    "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b"
    },
    "BucketKeyEnabled": true
}

$ aws s3api get-object-lock-configuration --bucket shared-resp-data-111122223333-eu-west-1
{
    "ObjectLockConfiguration": {
        "ObjectLockEnabled": "Enabled",
        "Rule": {
            "DefaultRetention": { "Mode": "GOVERNANCE", "Days": 30 }
        }
    }
}

$ aws kms get-key-rotation-status --key-id alias/shared-resp-data
{
    "KeyId": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b",
    "KeyRotationEnabled": true,
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-02-14T09:12:44.000000+00:00"
}

$ aws ec2 get-ebs-encryption-by-default --region eu-west-1
{
    "EbsEncryptionByDefault": true
}
```

RDS — las perillas del cliente sobre una plataforma administrada:

```console
$ aws rds describe-db-instances --db-instance-identifier payments-prod \
    --query 'DBInstances[0].{Engine:Engine,Version:EngineVersion,Encrypted:StorageEncrypted,Kms:KmsKeyId,MultiAZ:MultiAZ,Public:PubliclyAccessible,Backup:BackupRetentionPeriod,Window:PreferredMaintenanceWindow,AutoMinor:AutoMinorVersionUpgrade,DelProt:DeletionProtection}' \
    --output json
{
    "Engine": "postgres",
    "Version": "16.4",
    "Encrypted": true,
    "Kms": "arn:aws:kms:eu-west-1:111122223333:key/2b7d9e10-4c6a-4f83-9d21-70e5c8ab4419",
    "MultiAZ": true,
    "Public": false,
    "Backup": 14,
    "Window": "sun:03:00-sun:04:00",
    "AutoMinor": true,
    "DelProt": true
}

$ aws rds describe-db-parameters --db-parameter-group-name payments-pg16-hardened \
    --query "Parameters[?ParameterName=='rds.force_ssl'].{Name:ParameterName,Value:ParameterValue,Applied:ApplyType}" \
    --output table
--------------------------------------------------
|             DescribeDBParameters               |
+-----------+------------------+-----------------+
|  Applied  |      Name        |     Value       |
+-----------+------------------+-----------------+
|  static   |  rds.force_ssl   |  1              |
+-----------+------------------+-----------------+
```

Lambda — AWS es dueño del runtime, vos sos dueño del rol y del código:

```console
$ aws lambda get-function-configuration --function-name payments-settlement \
    --query '{Runtime:Runtime,Role:Role,Timeout:Timeout,Memory:MemorySize,Vpc:VpcConfig.SubnetIds,Kms:KMSKeyArn,Arch:Architectures}' \
    --output json
{
    "Runtime": "python3.12",
    "Role": "arn:aws:iam::111122223333:role/payments-settlement-exec",
    "Timeout": 30,
    "Memory": 1024,
    "Vpc": ["subnet-0a1b2c3d", "subnet-04e5f6a7"],
    "Kms": "arn:aws:kms:eu-west-1:111122223333:key/2b7d9e10-4c6a-4f83-9d21-70e5c8ab4419",
    "Arch": ["arm64"]
}
```

Los CVEs de tus dependencias, que AWS nunca va a parchear:

```console
$ aws inspector2 list-findings \
    --filter-criteria '{"resourceType":[{"comparison":"EQUALS","value":"AWS_LAMBDA_FUNCTION"}],"severity":[{"comparison":"EQUALS","value":"CRITICAL"}]}' \
    --query 'findings[].{Title:title,Pkg:packageVulnerabilityDetails.vulnerablePackages[0].name,Ver:packageVulnerabilityDetails.vulnerablePackages[0].version,Fix:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion,Res:resources[0].id}' \
    --output table
------------------------------------------------------------------------------------------------------------
|                                              ListFindings                                                |
+----------+---------------+------------+--------------------------------------------------+--------------+
|   Fix    |     Pkg       |    Ver     |                       Res                        |    Title     |
+----------+---------------+------------+--------------------------------------------------+--------------+
| 2.32.4   |  requests     |  2.28.1    | arn:aws:lambda:eu-west-1:111122223333:function...| CVE-2024-... |
+----------+---------------+------------+--------------------------------------------------+--------------+
```

### 7.6 Consumir la atestación de AWS (herencia de controles)

```console
$ aws artifact list-reports --region us-east-1 \
    --query 'reports[?contains(name, `SOC 2`)].{Id:id,Name:name,Series:series,State:state,Version:version,Period:periodEnd}' \
    --output table
------------------------------------------------------------------------------------------------------
|                                            ListReports                                             |
+-------------------------+------------------------------------+-----------+----------+-------------+
|           Id            |               Name                 |  Period   |  State   |   Version   |
+-------------------------+------------------------------------+-----------+----------+-------------+
| report-a1b2c3d4e5f6g7h8 | AWS SOC 2 Type II Report            | 2026-06-30| PUBLISHED|  14         |
+-------------------------+------------------------------------+-----------+----------+-------------+

$ aws artifact get-report --report-id report-a1b2c3d4e5f6g7h8 --report-version 14 \
    --term-token "$(aws artifact get-term-for-report --report-id report-a1b2c3d4e5f6g7h8 \
        --report-version 14 --query termToken --output text)" \
    --query documentPresignedUrl --output text
https://artifact-reports-prod.s3.us-east-1.amazonaws.com/soc2-type2-2026H1.pdf?X-Amz-Algorithm=...
```

Ese PDF es la *totalidad* de tu capacidad de verificar la mitad de AWS. Adjuntalo a la auditoría; dejá los controles heredados fuera del alcance de tu propia evaluación.

### 7.7 Postura de cumplimiento continuo

```console
$ aws configservice describe-compliance-by-config-rule \
    --config-rule-names ec2-instance-managed-by-ssm ec2-managedinstance-patch-compliance-status-check ec2-imdsv2-check encrypted-volumes root-account-mfa-enabled \
    --query 'ComplianceByConfigRules[].{Rule:ConfigRuleName,State:Compliance.ComplianceType,NonCompliant:Compliance.ComplianceContributorCount.CappedCount}' \
    --output table
--------------------------------------------------------------------------------------------
|                            DescribeComplianceByConfigRule                                |
+----------------+----------------------------------------------------+--------------------+
|  NonCompliant  |                       Rule                         |      State         |
+----------------+----------------------------------------------------+--------------------+
|  None          |  root-account-mfa-enabled                          |  COMPLIANT         |
|  1             |  ec2-instance-managed-by-ssm                       |  NON_COMPLIANT     |
|  1             |  ec2-managedinstance-patch-compliance-status-check |  NON_COMPLIANT     |
|  3             |  ec2-imdsv2-check                                  |  NON_COMPLIANT     |
|  None          |  encrypted-volumes                                 |  COMPLIANT         |
+----------------+----------------------------------------------------+--------------------+

$ aws securityhub get-findings \
    --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
    --max-results 5 \
    --query 'Findings[].{Ctl:ProductFields."ControlId",Title:Title,Res:Resources[0].Id}' \
    --output table
-------------------------------------------------------------------------------------------------
|                                          GetFindings                                          |
+-----------+---------------------------------------------------+-------------------------------+
|    Ctl    |                       Res                         |            Title              |
+-----------+---------------------------------------------------+-------------------------------+
|  IAM.6    |  AWS::::Account:111122223333                      | Hardware MFA should be enab...|
|  EC2.8    |  arn:aws:ec2:eu-west-1:111122223333:instance/i-0c..| EC2 instances should use IM...|
+-----------+---------------------------------------------------+-------------------------------+
```

Los checks básicos de Trusted Advisor son gratuitos; el conjunto completo requiere Business/Enterprise Support, y la API de Support solo responde en `us-east-1`:

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1 \
    --query 'checks[?category==`security`].{Id:id,Name:name}' --output table
-----------------------------------------------------------------------
|                    DescribeTrustedAdvisorChecks                     |
+--------------------------+------------------------------------------+
|            Id            |                  Name                    |
+--------------------------+------------------------------------------+
|  Pfx0RwqBli               |  Security Groups - Specific Ports Unre... |
|  HCP4007jGY               |  Security Groups - Unrestricted Access    |
|  DqdJqYeRm5               |  IAM Use                                  |
|  7DAFEmoDos               |  MFA on Root Account                      |
+--------------------------+------------------------------------------+
```

Si no tenés Business Support:

```console
$ aws support describe-trusted-advisor-checks --language en --region us-east-1

An error occurred (SubscriptionRequiredException) when calling the
DescribeTrustedAdvisorChecks operation: Amazon Web Services Premium Support
Subscription is required to use this service.
```

---

## 8. Diagnóstico de fallas: ¿de qué lado de la línea está esto?

### 8.1 El algoritmo de triage

```
Symptom observed
   │
   ├─ Does an AWS API call return an error code? ────────────────────► YOUR side (auth/config/quota)
   │     AccessDenied / UnauthorizedOperation → IAM, SCP, resource policy, KMS key policy
   │     LimitExceeded / RequestLimitExceeded → service quota (you request the increase)
   │
   ├─ Does the API succeed but the resource behaves wrongly? ────────► YOUR side (config/app)
   │
   ├─ Is the control plane itself unreachable / erroring 5xx
   │  across many principals and resources? ─────────────────────────► Check AWS Health + Service Health
   │     Event present → AWS side. Your job: failover, comms, credits.
   │     No event      → still YOUR side until proven otherwise.
   │
   ├─ Did a host/instance die with a scheduled event attached? ──────► AWS side hardware, YOUR side resilience
   │
   └─ Is data missing/corrupt?
         Deleted by an API call in CloudTrail?  → YOUR side (restore from versioning/backup)
         No such call, checksum mismatch?       → AWS side (open a support case; extremely rare)
```

**La suposición por defecto es que la falla es tuya.** Estadísticamente lo es, y arrancar desde "es AWS" desperdicia los primeros 30 minutos de cada incidente.

### 8.2 Tabla síntoma → causa raíz

| Síntoma | Dueño probable | Comando de diagnóstico | Causa raíz |
|---|---|---|---|
| `AccessDenied` en `s3:PutObject` aunque el llamador tiene `s3:*` | Vos | `aws s3api get-bucket-policy --bucket X` | `Deny` explícito en la bucket policy, en un SCP, o la trampa de `s3:x-amz-server-side-encryption` (§8.3) |
| `KMS.NotFoundException` / `AccessDeniedException` al descifrar objetos de S3 | Vos | `aws kms get-key-policy --key-id X --policy-name default` | La key policy no delega en IAM; un `Allow` de IAM por sí solo no alcanza para KMS |
| La instancia figura como `ConnectionLost` en SSM; los parches nunca se instalan | Vos | `aws ssm describe-instance-information` | Falta el instance profile, no hay ruta a los endpoints de SSM (sin NAT/VPC endpoints), o el agente está detenido |
| Patch Manager reporta `Missing: 7` después de una corrida exitosa | Vos | `aws ssm describe-instance-patch-states` | `RebootOption: NoReboot`, o parches bloqueados por `RejectedPatches` |
| La aplicación en Fargate sigue vulnerable después de que AWS publicó una actualización de plataforma | Vos | `aws ecs describe-tasks --query 'tasks[].platformVersion'` | Las tasks en ejecución conservan la platform version con la que se lanzaron; forzá un nuevo deployment |
| Los objetos `NetworkPolicy` de EKS existen pero el tráfico fluye libremente | Vos | `aws eks describe-addon --cluster-name X --addon-name vpc-cni` | La aplicación de network policy no está habilitada en el add-on de CNI |
| Instancia terminada durante la noche; app caída | AWS (hardware) + **vos** (resiliencia) | `aws ec2 describe-instance-status --include-all-instances` | Evento `instance-retirement`; diseño de una sola AZ/una sola instancia |
| RDS hizo failover a las 03:12 con una breve caída de conexiones | AWS (lo ejecutó) + **vos** (el cliente) | `aws rds describe-events --source-identifier X --source-type db-instance` | Failover Multi-AZ durante el mantenimiento; a la app le falta lógica de reintento/reconexión |
| Base de datos accesible desde internet | Vos | `... --query 'DBInstances[0].PubliclyAccessible'` | `PubliclyAccessible: true` + SG permisivo |
| Objetos desaparecidos, sin restauración posible | Vos | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteObject` | Versionado deshabilitado. La durabilidad de S3 protege contra la pérdida de *disco*, no contra *tu* `DELETE` |
| Lambda marcada como CRITICAL por Inspector; el runtime está actualizado | Vos | `aws inspector2 list-findings` | Dependencia empaquetada vulnerable — AWS parchea el runtime, no tu `site-packages` |
| La consola/API devuelve 503 en varios servicios de una Región | AWS | `aws health describe-events --region us-east-1` + Service Health Dashboard | Evento de servicio regional; ejecutá tu runbook de DR |
| Pico global de 4xx tras desplegar un SCP | Vos | `aws cloudtrail lookup-events` → `errorCode: AccessDenied`, `errorMessage` nombrando el SCP | El techo del SCP ahora excluye una acción legítima |

### 8.3 Diagnóstico trabajado — el bloqueo mutuo de la política de cifrado

**Síntoma.** Las subidas desde un rol con permisos correctos empiezan a fallar justo después de desplegar la bucket policy.

```console
$ aws s3 cp report.parquet s3://shared-resp-data-111122223333-eu-west-1/exports/report.parquet
upload failed: ./report.parquet to s3://shared-resp-data-111122223333-eu-west-1/exports/report.parquet
An error occurred (AccessDenied) when calling the PutObject operation:
User: arn:aws:sts::111122223333:assumed-role/etl-writer/etl is not authorized to
perform: s3:PutObject on resource "arn:aws:s3:::shared-resp-data-.../exports/report.parquet"
with an explicit deny in a resource-based policy
```

**Paso 1 — leé la última cláusula del error.** "explicit deny in a **resource-based policy**" localiza la falla en la bucket policy, no en IAM y no en un SCP (una denegación por SCP dice *"with an explicit deny in a service control policy"*).

**Paso 2 — reproducí la evaluación.**

```console
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/etl-writer \
    --action-names s3:PutObject \
    --resource-arns 'arn:aws:s3:::shared-resp-data-111122223333-eu-west-1/exports/report.parquet' \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,By:MatchedStatements[].SourcePolicyId}' \
    --output json
[
    {
        "Action": "s3:PutObject",
        "Decision": "explicitDeny",
        "By": ["DenyUnEncryptedObjectUploads"]
    }
]
```

**Paso 3 — la causa raíz.** La sentencia culpable era:

```json
{
  "Sid": "DenyUnEncryptedObjectUploads",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::shared-resp-data-.../*",
  "Condition": {
    "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" }
  }
}
```

En IAM, una condición `StringNotEquals` sobre una clave **ausente del request** evalúa a **verdadero**. La AWS CLI no envía el header `x-amz-server-side-encryption`, porque el cifrado por defecto del bucket lo va a aplicar. Pero **el cifrado por defecto del bucket se aplica después de la evaluación de la política**. Resultado: el objeto *habría quedado* cifrado con SSE-KMS, y sin embargo la política lo deniega. Tu control peleó contra el default de AWS y ganó — incorrectamente.

**Paso 4 — el patrón correcto**, como se usa en §6.1: confiá en el cifrado por defecto del bucket para la *aplicación*, y usá `StringNotEqualsIfExists` (más un guard `Null`) solo para rechazar una clave explícitamente equivocada, nunca un header ausente. Después dejá que una regla de Config (`S3_DEFAULT_ENCRYPTION_KMS`) pruebe el estado, en lugar de una política que adivina sobre el request.

**Paso 5 — verificá la corrección en el objeto, no en la política.**

```console
$ aws s3api head-object --bucket shared-resp-data-111122223333-eu-west-1 \
    --key exports/report.parquet \
    --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,BucketKey:BucketKeyEnabled}'
{
    "SSE": "aws:kms",
    "Key": "arn:aws:kms:eu-west-1:111122223333:key/8f2c1a3b-5d6e-47f8-9a0b-1c2d3e4f5a6b",
    "BucketKey": true
}
```

**La lección, en términos de responsabilidad compartida:** AWS te dio un default seguro. Vos agregaste un control que *asumía* que ese default no existía. Ambas mitades eran individualmente correctas; la costura entre ellas, no. Verificá siempre el **estado** resultante, nunca la intención de la política.

### 8.4 Atribuir un incidente con CloudTrail

Las acciones del lado del cliente llevan un principal IAM; la automatización del lado de AWS, no:

```console
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPublicAccessBlock \
    --start-time 2026-09-01T00:00:00Z \
    --query 'Events[].{Time:EventTime,User:Username,Src:CloudTrailEvent}' --max-results 1 \
    --output text | head -c 400
2026-09-02T14:22:07+00:00  platform-sre  {"eventVersion":"1.09","userIdentity":{"type":"AssumedRole",
"principalId":"AROA2XYZEXAMPLE7QF4:platform-sre","arn":"arn:aws:sts::111122223333:assumed-role/
PlatformSRE/platform-sre","accountId":"111122223333","sessionContext":{...}},"eventTime":
"2026-09-02T14:22:07Z","eventSource":"s3.amazonaws.com","eventName":"PutBucketPublicAccessBlock",
```

Regla práctica: `userIdentity.type` ∈ {`IAMUser`, `AssumedRole`, `Root`, `FederatedUser`} → **tu lado**. `userIdentity.type == "AWSService"` → un servicio de AWS actuando en tu nombre bajo un rol que **vos** otorgaste; la concesión sigue siendo tuya. **Las operaciones internas de AWS sobre su propia infraestructura nunca aparecen en tu trail** — que es precisamente por qué existen Artifact y AWS Health.

---

## 9. Destilado orientado al examen

Discriminadores comunes del CLF-C02, enunciados como reglas de decisión:

| Patrón del enunciado | Respuesta correcta |
|---|---|
| "Parchear el sistema operativo invitado en EC2" | Cliente |
| "Parchear el hypervisor / host" | AWS |
| "Parchear el motor de base de datos en Amazon RDS" | AWS |
| "Elegir la ventana de mantenimiento de RDS; realizar un upgrade de versión mayor" | Cliente |
| "Parchear el runtime de Lambda" | AWS |
| "Parchear las librerías dentro de un paquete de despliegue de Lambda" | Cliente |
| "Seguridad física de una Región" | AWS |
| "Seguridad física de la instalación que aloja un rack de AWS Outposts" | Cliente |
| "Configurar security groups y NACLs" | Cliente |
| "Asegurar la infraestructura de red física y el cableado" | AWS |
| "Cifrar datos en reposo" | El cliente decide y configura; AWS provee el mecanismo (KMS/integración del servicio) |
| "Gestionar usuarios, grupos, roles IAM y MFA" | Cliente |
| "Gestionar los HSMs físicos detrás de AWS KMS" | AWS |
| "Clasificar tus datos" | Cliente — siempre |
| "Decomisionar y destruir medios de almacenamiento" | AWS |
| "Gestión de parches" como *categoría* | **Control compartido** |
| "Gestión de configuración" como *categoría* | **Control compartido** |
| "Concientización y capacitación" como *categoría* | **Control compartido** |
| "¿Dónde obtengo el reporte SOC 2 / ISO 27001 / PCI?" | AWS Artifact |
| "¿Qué servicio chequea mi cuenta contra las mejores prácticas de seguridad?" | Trusted Advisor (amplio) / Security Hub (estándares) / Config (reglas) |
| "La aplicación se cayó porque falló una sola AZ" | Cliente — hay que arquitecturar entre AZs |

**Tres frases que vale la pena memorizar textualmente:**

1. AWS es responsable de la **seguridad *de* la nube**; el cliente es responsable de la **seguridad *en* la nube**.
2. La responsabilidad del cliente **aumenta** a medida que te movés hacia IaaS (EC2) y **disminuye** a medida que te movés hacia los servicios abstraídos (S3, Lambda) — pero **nunca llega a cero**, porque los datos y la identidad siempre son tuyos.
3. Los **controles compartidos** significan que el mismo objetivo de control se implementa **dos veces, de forma independiente** — una por AWS sobre la infraestructura, otra por vos sobre tu capa.

---

## 10. Referencias

**Primarias — alcance del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — página de certificación — https://aws.amazon.com/certification/certified-cloud-practitioner/

**El modelo en sí**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- Shared Responsibility Model — AWS Well-Architected Framework, Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/shared-responsibility.html
- Shared Responsibility Model for Resiliency — AWS Well-Architected Framework, Reliability Pillar — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/shared-responsibility-model-for-resiliency.html
- Security in AWS Outposts (responsabilidad compartida para Outposts) — https://docs.aws.amazon.com/outposts/latest/userguide/security.html

**Cumplimiento y atestación**
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- AWS Artifact API Reference — https://docs.aws.amazon.com/artifact/latest/APIReference/Welcome.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- AWS Customer Compliance Center — https://aws.amazon.com/compliance/customer-compliance-center/

**Fronteras específicas por servicio**
- Infrastructure security in Amazon EC2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/infrastructure-security.html
- The AWS Nitro System — https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/security-design-of-aws-nitro-system.html
- Use IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- Security in Amazon RDS — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.html
- Encrypting Amazon RDS resources — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html
- Security in AWS Lambda — https://docs.aws.amazon.com/lambda/latest/dg/lambda-security.html
- Lambda runtimes and deprecation policy — https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Amazon EKS security — https://docs.aws.amazon.com/eks/latest/userguide/security.html
- Amazon EKS Best Practices Guide for Security — https://docs.aws.amazon.com/eks/latest/best-practices/security.html
- AWS Fargate platform versions — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/platform_versions.html
- Security best practices for Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- Blocking public access to your Amazon S3 storage — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- Setting default server-side encryption behavior for S3 buckets — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html
- S3 Object Lock — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html
- AWS KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html

**Gobernanza, detección y remediación**
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- AWS Config Managed Rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- AWS Systems Manager Patch Manager — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-patch.html
- About patch baselines — https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager-patch-baselines.html
- AWS Security Hub standards and controls — https://docs.aws.amazon.com/securityhub/latest/userguide/standards-reference.html
- Amazon Inspector — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- AWS Trusted Advisor check reference — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor-check-reference.html
- AWS Health User Guide — https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
- Logging IAM and AWS STS API calls with CloudTrail — https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
- IAM policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html

**Acuerdos de nivel de servicio (documentos versionados — leé siempre la revisión vigente)**
- AWS Service Level Agreements index — https://aws.amazon.com/legal/service-level-agreements/
- Amazon Compute Service Level Agreement — https://aws.amazon.com/compute/sla/
- Amazon S3 Service Level Agreement — https://aws.amazon.com/s3/sla/