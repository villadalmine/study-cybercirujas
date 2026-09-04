# 3.3 — Identificar los servicios de cómputo de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Dominio 3:** Tecnología y servicios en la nube
**Task statement 3.3:** Identificar los servicios de cómputo de AWS
**Peso en el examen:** 4.25

---

## 1. El problema arquitectónico

Toda carga de trabajo que ejecutás necesita tres cosas: un lugar donde el proceso se ejecute, una forma de que ese lugar aparezca y desaparezca bajo demanda, y una forma de que el tráfico lo encuentre. "Cómputo" es la respuesta a la primera, pero la ingeniería interesante está en la segunda y la tercera.

Considerá la forma de un incidente de producción concreto que se repite en distintas organizaciones:

> Una API de pagos corre sobre 12 máquinas virtuales de larga vida detrás de un balanceador de carga. El tráfico es bimodal: ~400 req/s durante 20 horas al día, ~6.000 req/s durante una ventana de liquidación de 90 minutos. La flota está dimensionada para el pico. Durante 22,5 horas al día, el 92% del CPU comprado está ocioso. Cuando un host muere a las 03:00, se despierta a una persona para reemplazarlo. Cuando la ventana de liquidación crece un 15%, alguien tiene que acordarse de subir el tamaño de la flota, y alguien tiene que acordarse de bajarlo de nuevo.

Cada falla en esa descripción es una falla de *acoplamiento de elasticidad* — la capacidad que pagás está acoplada al pico, no a la demanda, y la recuperación de una unidad caída está acoplada a un humano. Los servicios de cómputo de AWS se entienden mejor no como "tipos de servidores" sino como **puntos en un espectro de cuánto del trabajo indiferenciado delegás**, y cada delegación intercambia control por elasticidad.

Las cuatro preguntas que deciden en qué punto de ese espectro cae una carga de trabajo:

1. **¿Cuál es la unidad de falla y de reemplazo?** ¿Un host? ¿Un contenedor? ¿Una sola invocación?
2. **¿Cuál es la granularidad de la facturación?** ¿Horas? ¿Segundos? ¿Milisegundos de GB-segundo?
3. **¿Quién parchea el sistema operativo?** ¿Vos, o AWS?
4. **¿Cuánto dura una unidad de trabajo, y necesita mantener estado entre unidades?**

De un Cloud Practitioner se espera que *identifique* los servicios. De un Platform Architect se espera que responda esas cuatro preguntas antes de elegir uno. Este material hace ambas cosas.

---

## 2. El espectro de cómputo — un eje, cinco paradas

```
  MORE CONTROL                                                 LESS OPERATIONAL WORK
  ◄────────────────────────────────────────────────────────────────────────────────►

  Outposts /      EC2            ECS/EKS on EC2   ECS/EKS on      Lambda
  Dedicated       (VM)           (containers on   Fargate         (function)
  Hosts                           your VMs)       (containers,     App Runner
  (hardware)                                       no VMs)         Beanstalk*

  You own:        You own:        You own:         You own:        You own:
  hardware        OS, patching,   OS, patching,    container       code
  placement,      capacity,       cluster nodes,   image,          + config
  licensing       scaling         container image  task size
                  policy

  Billed:         Billed:         Billed:          Billed:         Billed:
  per host        per second      per second       per second      per request
  (3yr)           (min 60s)       (min 60s) of     of vCPU/GB      + GB-second
                                  the underlying   requested       consumed
                                  EC2 fleet
```

\* Elastic Beanstalk es una *capa de aprovisionamiento y ciclo de vida* sobre EC2/ASG/ELB — las instancias EC2 están en tu cuenta y podés entrar por SSH. Reduce trabajo sin quitar control.

### 2.1 La línea de responsabilidad compartida, hecha concreta

| Capa | EC2 | ECS/EKS on EC2 | Fargate | Lambda |
|---|---|---|---|---|
| Host físico, hipervisor | AWS | AWS | AWS | AWS |
| SO invitado + parcheo del kernel | **Vos** | **Vos** | AWS | AWS |
| Runtime de contenedores / agente | n/a | **Vos** (vía AMI) | AWS | AWS |
| Runtime del lenguaje | **Vos** | **Vos** (imagen) | **Vos** (imagen) | AWS (runtimes gestionados) |
| Código de la aplicación | **Vos** | **Vos** | **Vos** | **Vos** |
| Política de capacidad/escalado | **Vos** | **Vos** | **Vos** (cantidad de tasks) | AWS (concurrencia) |
| Aislamiento de red (SG/subnet) | **Vos** | **Vos** | **Vos** | **Vos** (si está en la VPC) |

La formulación del examen para esto: *"¿Qué servicio requiere que el cliente parchee el sistema operativo invitado?"* → EC2 (y ECS/EKS **sobre EC2**, porque los nodos son EC2). Fargate y Lambda no.

---

## 3. Amazon EC2 — el sustrato

Amazon Elastic Compute Cloud provee máquinas virtuales redimensionables ("instancias") lanzadas desde una Amazon Machine Image (AMI) dentro de una subnet de tu VPC.

### 3.1 El sistema Nitro — por qué el comportamiento de las instancias modernas es distinto

Desde la generación C5/M5, EC2 corre sobre el **AWS Nitro System**: el stack de virtualización (red, almacenamiento, seguridad, monitoreo) se descarga del CPU principal hacia Nitro Cards dedicadas, y el hipervisor es un componente liviano basado en KVM. Tres consecuencias que importan operativamente:

- **Rendimiento cercano al bare-metal.** Prácticamente todo el CPU y la memoria del host quedan disponibles para los invitados; no hay un "impuesto dom0" que presupuestar.
- **Los volúmenes EBS son dispositivos de bloque NVMe.** Los nombres de dispositivo dentro del invitado son `/dev/nvme0n1`, `/dev/nvme1n1`… y **no** el `/dev/sdf` que especificaste en el block device mapping. Los scripts que hardcodean `/dev/xvdf` se rompen en Nitro — hay que resolver el mapeo con `lsblk`/`nvme id-ctrl`.
- **Existen los tipos de instancia `.metal`**, que le dan a tu SO acceso directo al procesador para cargas que necesitan su propio hipervisor o licenciamiento bare-metal.

**Nitro Enclaves** talla un entorno de cómputo aislado y endurecido a partir del CPU y la memoria de la propia instancia, sin almacenamiento persistente, sin acceso interactivo y sin red externa — se usa para procesar datos altamente sensibles (PII, claves) con atestación criptográfica.

### 3.2 Familias de instancias — leer el nombre

El nombre del tipo es una gramática, no una etiqueta opaca:

```
        m 7 g d n . 2xlarge
        │ │ │ │ │      │
        │ │ │ │ │      └── size (vCPU/memory scale)
        │ │ │ │ └───────── n = network/EBS-optimized (higher bandwidth)
        │ │ │ └─────────── d = local NVMe instance store attached
        │ │ └───────────── processor: g = AWS Graviton (arm64), a = AMD EPYC,
        │ │                           i = Intel, (none) = generation default
        │ └─────────────── generation (7 = current gen at time of writing)
        └───────────────── family: workload class
```

Otros sufijos que vas a encontrar: `e` (memoria/almacenamiento extra), `z` (alta frecuencia de CPU), `b` (optimizado para almacenamiento de bloque), `q` (Qualcomm, inferencia), `flex` (por ejemplo `m7i-flex` — más barato, alcanza el CPU completo el 95% del tiempo).

| Clase de familia | Letras | Ratio / característica | Uso representativo en producción |
|---|---|---|---|
| Propósito general | M, T, Mac | Balanceada ~4 GB por vCPU | Capa web, servidores de aplicación, bases de datos chicas, agentes de CI |
| Optimizada para cómputo | C | ~2 GB por vCPU, alto clock | Ad serving, codificación por lotes, servidores de juegos, front-ends de HPC |
| Optimizada para memoria | R, X, U, z1d | 8–32+ GB por vCPU | Cachés en memoria, SAP HANA, bases relacionales grandes, executors de Spark |
| Optimizada para almacenamiento | I, D, H | NVMe local / HDD denso, IOPS muy altas | Nodos de datos de Elasticsearch/OpenSearch, ClickHouse, NoSQL, data warehouses |
| Cómputo acelerado | P, G, Trn, Inf, F, VT | GPU / AWS Trainium / Inferentia / FPGA | Entrenamiento de modelos, inferencia, transcodificación, genómica |
| HPC | Hpc6a, Hpc7g | Alto rendimiento por core + red EFA | CFD, meteorología, dinámica molecular |

**Graviton (arm64)** es la elección de arquitectura por defecto para nuevas cargas stateless: AWS publica hasta un **40% mejor precio-rendimiento** frente a instancias x86 comparables para las cargas soportadas. El costo de adoptarlo es tu pipeline de build — necesitás imágenes de contenedor arm64 y cualquier dependencia nativa compilada para arm64.

### 3.3 La familia T y la economía de créditos — un clásico incidente de las 3 a.m.

Las instancias burstables (T2/T3/T3a/T4g) **no** te dan el vCPU completo de forma continua. Entregan una fracción **baseline** y acumulan **créditos de CPU** mientras están por debajo de ella; cada crédito compra un vCPU-minuto al 100%.

| Tipo | vCPU | Baseline por vCPU | Créditos ganados/hora | Máximo de créditos acumulados |
|---|---|---|---|---|
| t3.nano | 2 | 5% | 6 | 144 |
| t3.micro | 2 | 10% | 12 | 288 |
| t3.small | 2 | 20% | 24 | 576 |
| t3.medium | 2 | 20% | 24 | 576 |
| t3.large | 2 | 30% | 36 | 864 |
| t3.xlarge | 4 | 40% | 96 | 2304 |
| t3.2xlarge | 8 | 40% | 192 | 4608 |

Dos modos:

- **Standard** — cuando los créditos llegan a cero, la instancia queda *throttled* al baseline. Barato, y catastrófico para la latencia. Este es el default de T2.
- **Unlimited** — la instancia sigue haciendo burst y se te factura una tarifa de excedente por vCPU-hora. Este es el default de **T3/T3a/T4g**.

> **Firma de la falla:** la latencia p99 sube de 40 ms a 3.000 ms a lo largo de ~2 horas sin cambio de tráfico y sin deploy de código. `CPUUtilization` está clavado exactamente en el baseline (por ejemplo, 20%) y `CPUCreditBalance` es 0. La instancia no está "lenta" — está siendo throttled por diseño. Solución: pasar a modo unlimited, o mover a una familia de rendimiento fijo (M/C).

### 3.4 Opciones de compra — la palanca de costo

| Opción | Compromiso | Descuento típico | ¿Interrumpible? | Mejor encaje |
|---|---|---|---|---|
| **On-Demand** | ninguno | 0% (baseline) | No | Demanda con picos/desconocida, dev, pruebas cortas |
| **Savings Plans — Compute** | 1 o 3 años, $/hora | hasta **66%** | No | Baseline estable; aplica a EC2 **y Fargate y Lambda**, cualquier región, cualquier familia |
| **Savings Plans — EC2 Instance** | 1 o 3 años, $/hora | hasta **72%** | No | Baseline estable atado a una familia + región |
| **Reserved Instances — Standard** | 1 o 3 años, capacidad | hasta **72%** | No | Muy estable, tipo de instancia conocido |
| **Reserved Instances — Convertible** | 1 o 3 años | hasta **66%** | No | Gasto estable, con cambios de familia esperados |
| **Spot Instances** | ninguno | hasta **90%** | **Sí — aviso de 2 min** | Stateless, tolerante a fallos, con checkpoints: CI, batch, rendering, big-data, web stateless detrás de un ASG |
| **Dedicated Instances** | ninguno / RI | premium | No | Hardware aislado de otras cuentas de AWS |
| **Dedicated Hosts** | ninguno / RI / SP | premium | No | Licencias **BYOL** atadas a socket/core (Windows Server, Oracle, SQL Server), visibilidad del servidor físico, compliance |
| **On-Demand Capacity Reservations (ODCR)** | ninguno, se factura mientras se retiene | 0% (combinable con SP/RI) | No | Garantizar capacidad en una AZ para failover de DR o un evento de lanzamiento |

Distinciones críticas que el examen sondea:

- **Los Savings Plans y las RIs son construcciones de facturación, no garantías de capacidad** — excepto las RIs *zonales*, que sí incluyen una reserva de capacidad en una AZ específica. Las RIs regionales **no** reservan capacidad.
- **Solo los Dedicated Hosts te dan visibilidad de sockets/cores y soportan la mayoría de los modelos BYOL.** Las Dedicated *Instances* dan aislamiento pero no afinidad de host ni visibilidad de licenciamiento.
- **Spot no es "On-Demand barato"** — es capacidad sobrante que AWS reclama con un aviso de 2 minutos. Diseñá para eso, o no lo uses.

Manejo de la interrupción de Spot — la instancia consulta sus propios metadatos:

```bash
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/spot/instance-action
{"action":"terminate","time":"2026-09-04T14:22:31Z"}
```

Antes del aviso de terminación, AWS puede emitir una **EC2 Instance Rebalance Recommendation** — una señal más temprana y suave de que esta instancia está en riesgo elevado. Auto Scaling con **Capacity Rebalancing** habilitado lanza un reemplazo ante esa señal en lugar de esperar el aviso de 2 minutos.

### 3.5 Placement groups — controlar la topología física

| Tipo | Ubicación | Límite duro | Usar para |
|---|---|---|---|
| **Cluster** | Empaquetadas en un rack, una AZ | — (limitado por capacidad) | Latencia más baja, mayor throughput por flujo: HPC, MPI fuertemente acoplado |
| **Spread** | Cada instancia en hardware distinto | **7 instancias en ejecución por AZ por grupo** | Números pequeños de instancias críticas e independientes (por ejemplo, 3 miembros de un quórum) |
| **Partition** | Grupos de racks que no comparten nada | **7 particiones por AZ**, muchas instancias cada una | Sistemas distribuidos conscientes del rack: HDFS, Cassandra, Kafka |

Los cluster placement groups maximizan el rendimiento y *minimizan* el aislamiento de fallos — un evento a nivel de rack se lleva todo el grupo. Ese es el trade-off; explicitalo en una revisión de diseño.

### 3.6 Instance store vs EBS

| | Instance store (tipos `d`) | Amazon EBS |
|---|---|---|
| Conexión | Físicamente en el host | Conectado por red |
| Vida útil | **Se pierde al detener, hibernar o ante falla del host** | Persiste independientemente de la instancia |
| Rendimiento | IOPS más altas, latencia más baja | Alto, pero limitado por red (io2 Block Express hasta 256.000 IOPS) |
| Snapshot | No es posible | Hacia Amazon S3 |
| Uso | Scratch, caché, buffers, espacio de shuffle, nodos de BD replicados | Volúmenes raíz, datos durables |

### 3.7 Auto Scaling groups — donde vive realmente la elasticidad

Un **Auto Scaling group (ASG)** mantiene una cantidad deseada de instancias distribuidas entre AZs, reemplaza las que no están sanas y ajusta la capacidad a partir de políticas. Es el componente que arregla las dos fallas del incidente inicial.

Tipos de políticas de escalado:

| Política | Mecanismo | Cuándo usarla |
|---|---|---|
| **Target tracking** | Mantener una métrica en un objetivo (por ejemplo, `ALBRequestCountPerTarget = 1000`) | Elección por defecto — la respuesta correcta más simple |
| **Step scaling** | Alarma de CloudWatch → agregar/quitar N según la magnitud de la violación | Cuando se necesita respuesta no lineal |
| **Simple scaling** | Alarma → un único ajuste + cooldown | Legacy; evitar |
| **Scheduled** | Cambiar min/max/desired en un horario | Ventanas conocidas (la liquidación de 90 minutos) |
| **Predictive** | Pronóstico por ML a partir del histórico, pre-escala | Patrones diarios/semanales recurrentes con instancias de arranque lento |

Tipos de health check: **EC2** (status checks del hipervisor/instancia) y **ELB** (salud del target group). Si usás solo health checks de EC2, una instancia cuya *aplicación* se colgó pero cuyo *kernel* está bien va a quedar en servicio para siempre. Siempre adjuntá health checks de ELB para una capa balanceada.

Los **warm pools** mantienen instancias pre-inicializadas y detenidas listas, de modo que la latencia de scale-out sea de segundos en lugar del tiempo completo de boot + bootstrap.

---

## 4. Elastic Load Balancing — la puerta de entrada del tráfico

| Tipo | Capa OSI | Protocolos | Capacidad clave | Uso típico |
|---|---|---|---|---|
| **Application Load Balancer (ALB)** | 7 | HTTP, HTTPS, gRPC, WebSocket | Enrutamiento por host/path/header/query, auth OIDC, integración con WAF, targets Lambda | Microservicios, contenedores, APIs web |
| **Network Load Balancer (NLB)** | 4 | TCP, UDP, TLS | Millones de req/s, latencia ultra baja, **IP estática por AZ / Elastic IP**, preserva la IP de origen | No-HTTP, gaming, IoT, endpoints para PrivateLink |
| **Gateway Load Balancer (GWLB)** | 3 (gateway) | IP / GENEVE | Inserción transparente de appliances virtuales de terceros | Firewalls en línea, IDS/IPS, inspección profunda de paquetes |
| **Classic Load Balancer (CLB)** | 4 y 7 | TCP, SSL, HTTP(S) | Legacy (era EC2-Classic) | Migrar hacia otra opción |

Trampa de examen: *"necesita una dirección IP estática"* → **NLB**. *"enrutar `/api/v2/*` a un target group distinto"* → **ALB**.

---

## 5. Contenedores en AWS

### 5.1 Las tres decisiones ortogonales

Las decisiones de contenedores en AWS son tres ejes independientes, y confundirlos es la fuente de confusión más común:

1. **Registro** — dónde viven las imágenes: **Amazon ECR** (privado o público).
2. **Orquestador** — qué decide dónde corren los contenedores: **Amazon ECS** (nativo de AWS) o **Amazon EKS** (Kubernetes conforme al upstream).
3. **Launch type / cómputo** — *sobre* qué corren los contenedores: instancias **EC2** que gestionás vos, o **AWS Fargate** (serverless).

Podés combinar cualquier orquestador con cualquiera de los dos launch types.

### 5.2 ECS vs EKS

| | Amazon ECS | Amazon EKS |
|---|---|---|
| API | Propietaria de AWS (task definitions, services, clusters) | API de Kubernetes upstream, conforme a CNCF |
| Costo del control plane | **Gratis** | Cargo por hora por cluster |
| Curva de aprendizaje | Baja — IAM, ALB, CloudWatch tal como ya los conocés | Alta — primitivas de Kubernetes + integración con AWS (IRSA, VPC CNI, controllers) |
| Portabilidad | Solo AWS (ECS Anywhere lo extiende a on-prem) | Portable entre nubes y on-prem (EKS Anywhere, EKS Distro) |
| Ecosistema | Nativo de AWS | Helm, Operators, Argo, Istio, Karpenter, Prometheus |
| Redes | El modo `awsvpc` le da a cada task su propia ENI + SG | VPC CNI le da a cada pod una IP de la VPC |
| Carga de upgrades | Casi ninguna | Versión menor de Kubernetes cada ~4 meses |
| Mejor para | Equipos que quieren contenedores sin poseer un scheduler | Equipos con skills de Kubernetes, requisitos de portabilidad o de ecosistema |

### 5.3 Launch type EC2 vs Fargate

| | ECS/EKS on EC2 | AWS Fargate |
|---|---|---|
| Vos gestionás | AMI, parcheo, escalado de nodos, bin-packing, contenedores daemon | Nada por debajo del contenedor |
| Unidad de facturación | Las instancias EC2 (en ejecución u ociosas) | vCPU-segundos + GB-segundos **solicitados por el task**, mínimo 1 minuto |
| Densidad | La controlás vos — podés empaquetar muchos tasks chicos por host | Un task = una micro-VM; sin sobresuscripción |
| GPU / hardware especial | Sí | Limitado (sin GPU para Fargate) |
| Contenedores privilegiados, host networking, DaemonSets | Sí | **No** |
| Disco local persistente | Instance store / EBS | 20 GB efímeros por defecto, configurable hasta **200 GB**; EFS para persistencia compartida |
| Latencia de arranque | Rápida si un nodo tiene lugar; lenta si hay que lanzar un nodo | Decenas de segundos, consistente |
| Perfil de costo | Más barato con utilización alta y estable (>~70%) | Más barato para cargas con picos, de baja densidad, o de muchos servicios chicos |

**El dimensionamiento de tasks en Fargate es una matriz fija.** No podés pedir combinaciones arbitrarias:

| vCPU | Memoria válida |
|---|---|
| 0.25 | 0,5, 1, 2 GB |
| 0.5 | 1–4 GB (pasos de 1 GB) |
| 1 | 2–8 GB (pasos de 1 GB) |
| 2 | 4–16 GB (pasos de 1 GB) |
| 4 | 8–30 GB (pasos de 1 GB) |
| 8 | 16–60 GB (pasos de 4 GB) |
| 16 | 32–120 GB (pasos de 8 GB) |

**FARGATE_SPOT** aplica el modelo Spot a los tasks de Fargate (Linux/X86) con un descuento sustancial, con un `SIGTERM` 2 minutos antes de la reclamación.

---

## 6. AWS Lambda — funciones dirigidas por eventos

Lambda ejecuta tu código en respuesta a eventos, sin servidor ni contenedor que tengas que aprovisionar. Se te factura por **request** y por **GB-segundo** de memoria-tiempo consumido, redondeado al milisegundo.

### 6.1 El modelo de ejecución — y por qué existen los cold starts

```
 EVENT ──► [ Lambda service ]
              │
              ├─ warm execution environment available? ──► INVOKE handler ──► response
              │                                              (Duration)
              └─ none available ──► DOWNLOAD code/image
                                 ──► START runtime (micro-VM: Firecracker)
                                 ──► RUN init code (outside the handler)   ◄── InitDuration
                                 ──► INVOKE handler
```

La fase `InitDuration` corre **una vez por entorno de ejecución**, no una vez por invocación. Todo lo que ubiques fuera del handler — clientes del SDK, pools de conexiones a BD, parseo de configuración — se paga en el init y se reutiliza en las invocaciones subsiguientes sobre el mismo entorno. Esta es la optimización de Lambda con mayor apalancamiento.

Mitigaciones para rutas sensibles al cold start:
- **Provisioned Concurrency** — mantener N entornos inicializados y calientes; se factura por hora.
- **SnapStart** — tomar un snapshot del entorno post-init y restaurar desde ahí (Java, Python, .NET). Cuidado: la entropía y los IDs únicos generados en el init se clonan entre restauraciones; usá los runtime hooks para re-sembrar.

### 6.2 Cuotas duras alrededor de las cuales tenés que diseñar

| Cuota | Valor |
|---|---|
| Timeout máximo de ejecución | **900 s (15 minutos)** |
| Memoria | 128 MB – **10.240 MB** (incrementos de 1 MB) |
| Asignación de vCPU | Proporcional a la memoria; ~1.769 MB ≈ 1 vCPU completo, hasta 6 vCPU |
| Almacenamiento efímero `/tmp` | 512 MB – 10.240 MB |
| Paquete de despliegue (zip, subida directa) | 50 MB |
| Paquete de despliegue (descomprimido, incl. layers) | 250 MB |
| Imagen de contenedor | 10 GB |
| Layers por función | 5 |
| Payload síncrono de request/response | 6 MB |
| Payload de evento asíncrono | 256 KB |
| Variables de entorno (total) | 4 KB |
| Ejecuciones concurrentes por defecto por cuenta/región | 1.000 (blando — ampliable) |

**La memoria es tu único dial de rendimiento.** Como el CPU escala con la memoria, una función CPU-bound a 1.024 MB puede terminar en la mitad del tiempo a 2.048 MB — costando los *mismos* GB-segundos mientras reduce la latencia a la mitad. Nunca ajustes la memoria de Lambda por intuición; medí.

### 6.3 Vocabulario de concurrencia

- **Concurrencia no reservada / de cuenta** — el pool compartido (por defecto 1.000).
- **Concurrencia reservada** — un techo *y* una garantía para una función. Talla capacidad fuera del pool compartido. Ponerla en `0` es el interruptor de emergencia que detiene el mundo para una función que se está portando mal.
- **Concurrencia aprovisionada** — entornos pre-inicializados, tomados de la capacidad reservada (o no reservada) de la función.

### 6.4 Dónde Lambda es la respuesta equivocada

- Trabajo que excede los 15 minutos → **AWS Batch**, un task de ECS/Fargate, o Step Functions orquestando fragmentos.
- Cómputo sostenido, predecible y de alto throughput → EC2/Fargate es más barato por unidad de trabajo.
- Cargas que requieren un sistema de archivos local persistente mayor a 10 GB o estado compartido → Fargate + EFS, o EC2.
- Cualquier cosa que necesite un socket de escucha de larga vida (una base de datos, un gateway con estado).

---

## 7. Los servicios de mayor abstracción y los especializados

| Servicio | Qué es | Elegilo cuando |
|---|---|---|
| **AWS Elastic Beanstalk** | PaaS que aprovisiona y gestiona EC2 + ASG + ELB + CloudWatch a partir del código que subís. Soporta Java, .NET, PHP, Node.js, Python, Ruby, Go, Docker. | Querés un entorno completo sin escribir infraestructura, pero seguís queriendo acceso a nivel EC2. Beanstalk en sí es **gratis** — pagás por los recursos que crea. |
| **AWS App Runner** | Totalmente gestionado: apuntalo a una imagen de contenedor en ECR o a un repositorio de código; él construye, despliega, balancea la carga y auto-escala un servicio HTTPS. | Un único servicio/API web en contenedor sin ganas de ver una VPC, un balanceador de carga o un cluster. |
| **Amazon Lightsail** | VPS empaquetado: instancia + almacenamiento + transferencia a un precio mensual fijo y predecible. También bases de datos, contenedores, balanceadores de carga. | Sitios web simples, WordPress, sandboxes de desarrollo, usuarios que quieren una factura fija. |
| **AWS Batch** | Scheduling de batch gestionado: colas de jobs, definiciones de jobs, entornos de cómputo sobre EC2 (incl. Spot), Fargate o EKS. Maneja array jobs y grafos de dependencias. | Miles de jobs independientes — genómica, simulación de riesgo, transcodificación de medios — donde querés selección óptima de instancias y economía de Spot. |
| **AWS Outposts** | Racks/servidores diseñados por AWS instalados en **tu** centro de datos, corriendo APIs nativas de AWS, gestionados por AWS. | Baja latencia hacia sistemas on-prem, o requisitos de residencia de datos que prohíben la Región. |
| **AWS Local Zones** | Infraestructura de AWS ubicada en un área metropolitana cerca de grandes poblaciones. | Latencia de un solo dígito de milisegundos hacia usuarios finales en una ciudad específica (medios, gaming, estaciones de trabajo remotas). |
| **AWS Wavelength** | Cómputo embebido en las redes 5G de los proveedores de telecomunicaciones. | Latencia ultra baja hacia dispositivos móviles — AR/VR, vehículos conectados, video en vivo. |
| **AWS Snowball Edge (Compute Optimized)** | Dispositivo ruggedizado con cómputo compatible con EC2 y almacenamiento locales. | Entornos desconectados, remotos u hostiles: barcos, minas, respuesta a desastres. |
| **Lambda@Edge / CloudFront Functions** | Código ejecutado en las ubicaciones de borde de CloudFront. CloudFront Functions: sub-milisegundo, JS, manipulación de headers/URL. Lambda@Edge: más pesado, runtime completo de Lambda. | Manipulación de request/response, enrutamiento A/B, auth en el borde. |
| **AWS Compute Optimizer** | Analiza métricas de CloudWatch y recomienda configuraciones correctamente dimensionadas de EC2, ASG, EBS, Lambda y ECS-on-Fargate. | Revisiones de optimización de costos. |

---

## 8. Matriz de decisión — la única tabla para internalizar

| Requisito en el enunciado de la pregunta | Servicio correcto |
|---|---|
| Control total sobre el SO, instalar módulos de kernel personalizados | **EC2** |
| Necesitar agentes de build macOS para iOS | **EC2 Mac instances** |
| Traer tu propia licencia de Windows/Oracle atada a cores físicos | **EC2 Dedicated Hosts** |
| Aislamiento físico de otros clientes de AWS, sin necesidades de licenciamiento | **EC2 Dedicated Instances** |
| Batch stateless tolerante a fallos, minimizar costo, tolerar interrupciones | **EC2 Spot Instances** |
| Uso en estado estable por 1–3 años, querer el máximo descuento sobre EC2 + Fargate + Lambda | **Compute Savings Plans** |
| Correr contenedores Docker, orquestador nativo de AWS, sin cargo de control plane | **Amazon ECS** |
| Correr Kubernetes, mantener portabilidad y el ecosistema CNCF | **Amazon EKS** |
| Correr contenedores sin gestionar ningún servidor | **AWS Fargate** |
| Almacenar y escanear imágenes de contenedor | **Amazon ECR** |
| Ejecutar código en respuesta a una subida a S3 / un mensaje de SQS, pagar por invocación | **AWS Lambda** |
| El job corre 45 minutos y procesa un dataset grande | **AWS Batch** (o un task de Fargate/ECS) — *no* Lambda |
| Desplegar una aplicación sin configurar infraestructura, pero conservar acceso a EC2 | **AWS Elastic Beanstalk** |
| Desplegar un único contenedor como servicio web con cero configuración de infraestructura | **AWS App Runner** |
| VPS simple, de precio mensual fijo, para un sitio web chico | **Amazon Lightsail** |
| Correr servicios de AWS físicamente dentro de mi propio centro de datos | **AWS Outposts** |
| Latencia de un solo dígito de ms hacia usuarios en una ciudad específica | **AWS Local Zones** |
| Latencia ultra baja hacia usuarios móviles 5G | **AWS Wavelength** |
| Reemplazar automáticamente instancias no sanas y ajustar la capacidad a la demanda | **EC2 Auto Scaling** |
| Enrutar tráfico HTTPS por path de URL hacia distintos servicios | **Application Load Balancer** |
| Millones de conexiones TCP con una IP estática | **Network Load Balancer** |
| Recomendar instancias correctamente dimensionadas a partir de la utilización real | **AWS Compute Optimizer** |

---

## 9. Infraestructura completa — CloudFormation

Una capa EC2 con forma de producción: IMDSv2 obligatorio, Graviton con fallback a x86 vía una mixed-instances policy, Spot para una parte de la capacidad, target tracking del ALB, SSM Session Manager en lugar de SSH, EBS cifrado, instance refresh al cambiar el template.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Reference EC2 compute tier for CLF-C02 topic 3.3 — Auto Scaling group with a
  mixed-instances policy (Graviton on-demand baseline + Spot burst) behind an
  Application Load Balancer, IMDSv2 enforced, access via SSM Session Manager.

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC that already contains the public and private subnets below.

  PublicSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two public subnets in distinct AZs, for the ALB.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two private subnets in distinct AZs, for the instances.

  LatestArm64AmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
    Description: >-
      Resolved at stack create/update time from the AWS-published SSM public
      parameter. Never hardcode an AMI ID — they are region-specific and go stale.

  OnDemandBaseCapacity:
    Type: Number
    Default: 2
    Description: Instances always served by On-Demand before Spot is used.

  OnDemandPercentageAboveBase:
    Type: Number
    Default: 25
    Description: Percentage of capacity above the base that is On-Demand.

  MinSize:
    Type: Number
    Default: 2

  MaxSize:
    Type: Number
    Default: 20

Resources:

  # ------------------------------------------------------------------
  # Security groups
  # ------------------------------------------------------------------
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Ingress for the public Application Load Balancer
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Public HTTPS
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-alb-sg'

  InstanceSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application instances — only the ALB may reach them
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          SourceSecurityGroupId: !Ref AlbSecurityGroup
          Description: Application port from the ALB only
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-instance-sg'

  # ------------------------------------------------------------------
  # Instance identity: no SSH keys, no long-lived credentials
  # ------------------------------------------------------------------
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

  # ------------------------------------------------------------------
  # Launch template
  # ------------------------------------------------------------------
  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${AWS::StackName}-lt'
      LaunchTemplateData:
        ImageId: !Ref LatestArm64AmiId
        IamInstanceProfile:
          Arn: !GetAtt InstanceProfile.Arn
        SecurityGroupIds:
          - !Ref InstanceSecurityGroup
        MetadataOptions:
          HttpTokens: required          # IMDSv2 only — blocks SSRF credential theft
          HttpPutResponseHopLimit: 1    # raise to 2 only if containers need IMDS
          HttpEndpoint: enabled
        Monitoring:
          Enabled: true                 # 1-minute CloudWatch metrics
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: 30
              VolumeType: gp3
              Iops: 3000
              Throughput: 125
              Encrypted: true
              DeleteOnTermination: true
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - Key: Name
                Value: !Sub '${AWS::StackName}-app'
              - Key: Environment
                Value: production
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -euxo pipefail

            dnf -y update
            dnf -y install python3.12 amazon-cloudwatch-agent

            # Minimal health-serving application so the target group can pass.
            cat >/opt/app.py <<'PYEOF'
            from http.server import BaseHTTPRequestHandler, HTTPServer

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path == "/healthz":
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.end_headers()
                        self.wfile.write(b"ok\n")
                    else:
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.end_headers()
                        self.wfile.write(b"hello from the compute tier\n")

                def log_message(self, fmt, *args):
                    pass

            HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
            PYEOF

            cat >/etc/systemd/system/app.service <<'UNITEOF'
            [Unit]
            Description=Demo application
            After=network-online.target
            Wants=network-online.target

            [Service]
            ExecStart=/usr/bin/python3.12 /opt/app.py
            Restart=always
            RestartSec=2

            [Install]
            WantedBy=multi-user.target
            UNITEOF

            systemctl daemon-reload
            systemctl enable --now app.service

            # Handle Spot interruption: drain before the 2-minute deadline expires.
            cat >/opt/spot-watch.sh <<'SPOTEOF'
            #!/bin/bash
            while true; do
              TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
              CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "X-aws-ec2-metadata-token: $TOKEN" \
                http://169.254.169.254/latest/meta-data/spot/instance-action)
              if [ "$CODE" = "200" ]; then
                logger -t spot-watch "interruption notice received; stopping app"
                systemctl stop app.service   # fail health checks -> ALB deregisters
                sleep 120
              fi
              sleep 5
            done
            SPOTEOF
            chmod +x /opt/spot-watch.sh

            cat >/etc/systemd/system/spot-watch.service <<'SWEOF'
            [Unit]
            Description=Spot interruption watcher

            [Service]
            ExecStart=/opt/spot-watch.sh
            Restart=always

            [Install]
            WantedBy=multi-user.target
            SWEOF

            systemctl daemon-reload
            systemctl enable --now spot-watch.service

  # ------------------------------------------------------------------
  # Load balancer
  # ------------------------------------------------------------------
  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${AWS::StackName}-alb'
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      Subnets: !Ref PublicSubnetIds
      SecurityGroups:
        - !Ref AlbSecurityGroup
      LoadBalancerAttributes:
        - Key: routing.http.drop_invalid_header_fields.enabled
          Value: 'true'
        - Key: deletion_protection.enabled
          Value: 'true'

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${AWS::StackName}-tg'
      VpcId: !Ref VpcId
      Port: 8080
      Protocol: HTTP
      TargetType: instance
      HealthCheckPath: /healthz
      HealthCheckProtocol: HTTP
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Matcher:
        HttpCode: '200'
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '30'
        - Key: load_balancing.algorithm.type
          Value: least_outstanding_requests

  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Port: 443
      Protocol: HTTPS
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      Certificates:
        - CertificateArn: !Ref AcmCertificateArn
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup

  # ------------------------------------------------------------------
  # Auto Scaling group — the elasticity and self-healing layer
  # ------------------------------------------------------------------
  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref MinSize
        MaxBatchSize: 2
        PauseTime: PT5M
        WaitOnResourceSignals: false
        SuspendProcesses:
          - HealthCheck
          - ReplaceUnhealthy
          - AZRebalance
          - AlarmNotification
          - ScheduledActions
    Properties:
      AutoScalingGroupName: !Sub '${AWS::StackName}-asg'
      VPCZoneIdentifier: !Ref PrivateSubnetIds
      MinSize: !Ref MinSize
      MaxSize: !Ref MaxSize
      DesiredCapacity: !Ref MinSize
      HealthCheckType: ELB              # application health, not just kernel health
      HealthCheckGracePeriod: 180       # must exceed boot + bootstrap time
      CapacityRebalance: true           # act on Spot rebalance recommendations
      TargetGroupARNs:
        - !Ref TargetGroup
      MetricsCollection:
        - Granularity: 1Minute
      MixedInstancesPolicy:
        InstancesDistribution:
          OnDemandBaseCapacity: !Ref OnDemandBaseCapacity
          OnDemandPercentageAboveBaseCapacity: !Ref OnDemandPercentageAboveBase
          SpotAllocationStrategy: price-capacity-optimized
          OnDemandAllocationStrategy: lowest-price
        LaunchTemplate:
          LaunchTemplateSpecification:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          Overrides:
            # Multiple types = multiple Spot capacity pools = fewer interruptions
            # and a real answer to InsufficientInstanceCapacity.
            - InstanceType: m7g.large
            - InstanceType: m6g.large
            - InstanceType: c7g.large
            - InstanceType: c6g.large
            - InstanceType: r7g.large
      Tags:
        - Key: Name
          Value: !Sub '${AWS::StackName}-app'
          PropagateAtLaunch: true

  ScaleOnRequestCount:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      PolicyType: TargetTrackingScaling
      EstimatedInstanceWarmup: 180
      TargetTrackingConfiguration:
        TargetValue: 1000
        PredefinedMetricSpecification:
          PredefinedMetricType: ALBRequestCountPerTarget
          ResourceLabel: !Join
            - '/'
            - - !GetAtt LoadBalancer.LoadBalancerFullName
              - !GetAtt TargetGroup.TargetGroupFullName

  # Deterministic pre-scale for the known settlement window (UTC).
  ScheduledSettlementScaleOut:
    Type: AWS::AutoScaling::ScheduledAction
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      Recurrence: '45 21 * * *'
      MinSize: 12
      DesiredCapacity: 12
      MaxSize: !Ref MaxSize
      TimeZone: UTC

  ScheduledSettlementScaleIn:
    Type: AWS::AutoScaling::ScheduledAction
    Properties:
      AutoScalingGroupName: !Ref AutoScalingGroup
      Recurrence: '30 23 * * *'
      MinSize: !Ref MinSize
      DesiredCapacity: !Ref MinSize
      MaxSize: !Ref MaxSize
      TimeZone: UTC

Outputs:
  LoadBalancerDnsName:
    Description: Public DNS name of the ALB
    Value: !GetAtt LoadBalancer.DNSName
    Export:
      Name: !Sub '${AWS::StackName}-alb-dns'

  AutoScalingGroupName:
    Description: Name of the Auto Scaling group
    Value: !Ref AutoScalingGroup

  TargetGroupArn:
    Description: ARN of the target group
    Value: !Ref TargetGroup
```

> El template referencia un parámetro `AcmCertificateArn` usado por `HttpsListener`. Agregalo a `Parameters` como `Type: String` con la descripción "ARN of an ACM certificate in this Region for the ALB listener" antes de desplegar — CloudFormation valida las referencias a parámetros en el momento del parseo del template y de lo contrario va a rechazar el stack.

---

## 10. Contenedores — definición completa de ECS on Fargate

### 10.1 Task definition (registrala directamente con la CLI)

`task-definition.json`:

```json
{
  "family": "payments-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "ephemeralStorage": {
    "sizeInGiB": 21
  },
  "executionRoleArn": "arn:aws:iam::111122223333:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::111122223333:role/paymentsApiTaskRole",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api:2026.09.04-a1b2c3d",
      "essential": true,
      "cpu": 896,
      "memoryReservation": 1536,
      "portMappings": [
        {
          "name": "http",
          "containerPort": 8080,
          "protocol": "tcp",
          "appProtocol": "http"
        }
      ],
      "environment": [
        { "name": "LOG_LEVEL", "value": "info" },
        { "name": "AWS_REGION", "value": "eu-west-1" }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:prod/payments/db-AbCdEf"
        }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -fsS http://localhost:8080/healthz || exit 1"],
        "interval": 15,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      },
      "ulimits": [
        { "name": "nofile", "softLimit": 65536, "hardLimit": 65536 }
      ],
      "stopTimeout": 30,
      "readonlyRootFilesystem": true,
      "linuxParameters": {
        "initProcessEnabled": true
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/payments-api",
          "awslogs-region": "eu-west-1",
          "awslogs-stream-prefix": "api",
          "awslogs-create-group": "true",
          "mode": "non-blocking",
          "max-buffer-size": "4m"
        }
      }
    },
    {
      "name": "otel-collector",
      "image": "public.ecr.aws/aws-observability/aws-otel-collector:latest",
      "essential": false,
      "cpu": 128,
      "memoryReservation": 512,
      "command": ["--config=/etc/ecs/ecs-default-config.yaml"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/payments-api",
          "awslogs-region": "eu-west-1",
          "awslogs-stream-prefix": "otel",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
```

Notá que los valores de `cpu` a nivel contenedor (896 + 128 = 1024) suman el `cpu` a nivel task. `readonlyRootFilesystem: true` e `initProcessEnabled: true` (que cosecha procesos zombis) son defaults de producción, no un pulido opcional.

### 10.2 El servicio de ECS, en CloudFormation

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: ECS service on Fargate with a Spot-weighted capacity provider strategy.

Parameters:
  ClusterName:
    Type: String
  TaskDefinitionArn:
    Type: String
  TargetGroupArn:
    Type: String
  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
  ServiceSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id

Resources:
  Service:
    Type: AWS::ECS::Service
    Properties:
      ServiceName: payments-api
      Cluster: !Ref ClusterName
      TaskDefinition: !Ref TaskDefinitionArn
      DesiredCount: 6
      PropagateTags: SERVICE
      EnableExecuteCommand: true        # `aws ecs execute-command` shell, no bastion
      HealthCheckGracePeriodSeconds: 60

      # Two On-Demand tasks always; everything above that is 3:1 Spot:On-Demand.
      CapacityProviderStrategy:
        - CapacityProvider: FARGATE
          Base: 2
          Weight: 1
        - CapacityProvider: FARGATE_SPOT
          Base: 0
          Weight: 3

      NetworkConfiguration:
        AwsvpcConfiguration:
          Subnets: !Ref PrivateSubnetIds
          SecurityGroups:
            - !Ref ServiceSecurityGroupId
          AssignPublicIp: DISABLED      # requires NAT GW or ECR/S3/Logs VPC endpoints

      LoadBalancers:
        - ContainerName: api
          ContainerPort: 8080
          TargetGroupArn: !Ref TargetGroupArn

      DeploymentConfiguration:
        MaximumPercent: 200
        MinimumHealthyPercent: 100
        DeploymentCircuitBreaker:
          Enable: true
          Rollback: true                # auto-revert a deployment that never stabilises

  ScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: ecs
      ScalableDimension: ecs:service:DesiredCount
      ResourceId: !Sub 'service/${ClusterName}/payments-api'
      MinCapacity: 6
      MaxCapacity: 60
      RoleARN: !Sub 'arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService'
    DependsOn: Service

  ScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: payments-api-cpu-target
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref ScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: 60.0
        PredefinedMetricSpecification:
          PredefinedMetricType: ECSServiceAverageCPUUtilization
        ScaleInCooldown: 300
        ScaleOutCooldown: 60
```

### 10.3 La misma carga de trabajo sobre EKS

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # IRSA: the pod assumes this IAM role via an OIDC-federated web identity.
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/paymentsApiPodRole
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
    spec:
      serviceAccountName: payments-api
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Spread across AZs so one AZ event cannot take a majority of replicas.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: 111122223333.dkr.ecr.eu-west-1.amazonaws.com/payments-api:2026.09.04-a1b2c3d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: LOG_LEVEL
              value: info
          resources:
            # requests == limits for memory (no overcommit on a non-compressible
            # resource). CPU limit omitted deliberately: CFS throttling at the
            # limit hurts p99 more than a noisy neighbour does.
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              memory: 1Gi
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 3
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /livez, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 5
          lifecycle:
            preStop:
              exec:
                # Let the ALB deregister before the process dies.
                command: ["/bin/sh", "-c", "sleep 15"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payments-api
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments
spec:
  minAvailable: 80%
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 6
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
---
# Run this namespace's pods on Fargate — no worker nodes to patch.
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: payments-prod
  region: eu-west-1
fargateProfiles:
  - name: payments
    selectors:
      - namespace: payments
        labels:
          app.kubernetes.io/name: payments-api
    subnets:
      - subnet-0a1b2c3d4e5f60718
      - subnet-0b2c3d4e5f6071829
```

---

## 11. Serverless — un template completo de AWS SAM

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: >-
  Event-driven settlement processor: SQS -> Lambda -> DynamoDB, with a
  dead-letter queue, reserved concurrency and X-Ray tracing.

Globals:
  Function:
    Runtime: python3.12
    Architectures: [arm64]        # ~20% cheaper per GB-second than x86_64
    Timeout: 60
    MemorySize: 1024
    Tracing: Active
    LoggingConfig:
      LogFormat: JSON
      ApplicationLogLevel: INFO
      SystemLogLevel: WARN
    Environment:
      Variables:
        POWERTOOLS_SERVICE_NAME: settlement
        TABLE_NAME: !Ref SettlementTable

Resources:

  SettlementQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: settlement-events
      VisibilityTimeout: 360        # >= 6 x function timeout, per AWS guidance
      MessageRetentionPeriod: 345600
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt SettlementDlq.Arn
        maxReceiveCount: 3

  SettlementDlq:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: settlement-events-dlq
      MessageRetentionPeriod: 1209600   # 14 days, the maximum

  SettlementTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: settlement-records
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: pk
          AttributeType: S
        - AttributeName: sk
          AttributeType: S
      KeySchema:
        - AttributeName: pk
          KeyType: HASH
        - AttributeName: sk
          KeyType: RANGE
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true
      SSESpecification:
        SSEEnabled: true

  SettlementFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: settlement-processor
      CodeUri: src/settlement/
      Handler: app.lambda_handler
      # Ceiling AND floor: caps blast radius on a poison-pill storm and
      # guarantees this function is never starved by a noisy neighbour.
      ReservedConcurrentExecutions: 100
      ProvisionedConcurrencyConfig:
        ProvisionedConcurrentExecutions: 10
      AutoPublishAlias: live
      DeploymentPreference:
        Type: Canary10Percent5Minutes
        Alarms:
          - !Ref FunctionErrorAlarm
      Policies:
        - DynamoDBCrudPolicy:
            TableName: !Ref SettlementTable
        - SQSPollerPolicy:
            QueueName: !GetAtt SettlementQueue.QueueName
      Events:
        SqsBatch:
          Type: SQS
          Properties:
            Queue: !GetAtt SettlementQueue.Arn
            BatchSize: 10
            MaximumBatchingWindowInSeconds: 5
            FunctionResponseTypes:
              - ReportBatchItemFailures   # partial batch failure, not all-or-nothing
            ScalingConfig:
              MaximumConcurrency: 50

  FunctionErrorAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: settlement-processor-errors
      Namespace: AWS/Lambda
      MetricName: Errors
      Dimensions:
        - Name: FunctionName
          Value: !Ref SettlementFunction
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 5
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching

  ThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: settlement-processor-throttles
      Namespace: AWS/Lambda
      MetricName: Throttles
      Dimensions:
        - Name: FunctionName
          Value: !Ref SettlementFunction
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching

Outputs:
  QueueUrl:
    Value: !Ref SettlementQueue
  FunctionArn:
    Value: !GetAtt SettlementFunction.Arn
```

---

## 12. Laboratorio de verificación por CLI — comandos y salidas reales

### 12.1 Descubrir tipos de instancia por atributo, no por memoria del catálogo

```bash
$ aws ec2 describe-instance-types \
    --filters "Name=processor-info.supported-architecture,Values=arm64" \
              "Name=vcpu-info.default-vcpus,Values=2" \
              "Name=memory-info.size-in-mib,Values=8192" \
              "Name=current-generation,Values=true" \
    --query 'InstanceTypes[].{Type:InstanceType,vCPU:VCpuInfo.DefaultVCpus,MiB:MemoryInfo.SizeInMiB,Net:NetworkInfo.NetworkPerformance,Nitro:HypervisorType}' \
    --output table
--------------------------------------------------------------------
|                      DescribeInstanceTypes                        |
+-------+-------------+---------------------------+--------+--------+
| MiB   | Net         | Nitro                     | Type   | vCPU   |
+-------+-------------+---------------------------+--------+--------+
| 8192  | Up to 12.5  | nitro                     | m7g.lar| 2      |
| 8192  | Up to 12.5  | nitro                     | m6g.lar| 2      |
| 8192  | Up to 12.5  | nitro                     | m7gd.la| 2      |
+-------+-------------+---------------------------+--------+--------+
```

### 12.2 Comparar Spot con On-Demand antes de comprometerte con una estrategia

```bash
$ aws ec2 describe-spot-price-history \
    --instance-types m7g.large \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].{AZ:AvailabilityZone,Price:SpotPrice,When:Timestamp}' \
    --output table
------------------------------------------------------------
|                 DescribeSpotPriceHistory                  |
+---------------+----------+-------------------------------+
|      AZ       |  Price   |             When              |
+---------------+----------+-------------------------------+
|  eu-west-1a   |  0.026500|  2026-09-04T13:52:14+00:00    |
|  eu-west-1b   |  0.024800|  2026-09-04T13:52:14+00:00    |
|  eu-west-1c   |  0.031200|  2026-09-04T13:52:14+00:00    |
+---------------+----------+-------------------------------+
```

Frente a una tarifa On-Demand de aproximadamente `$0.0856/hr` para `m7g.large` en esta Región, `eu-west-1b` es ~71% más barata. Inspeccioná también el riesgo de *interrupción*, no solo el precio:

```bash
$ aws ec2 describe-spot-placement-scores \
    --instance-types m7g.large m6g.large c7g.large \
    --target-capacity 40 \
    --target-capacity-unit-type units \
    --region-names eu-west-1 \
    --query 'SpotPlacementScores[].{Region:Region,Score:Score}' \
    --output table
-------------------------------
| DescribeSpotPlacementScores |
+-------------+---------------+
|   Region    |     Score     |
+-------------+---------------+
|  eu-west-1  |  9            |
+-------------+---------------+
```

Los puntajes van de 1 a 10; 9 significa que es muy probable que esta solicitud diversificada se satisfaga sin interrupciones.

### 12.3 Desplegar y verificar la capa de cómputo

```bash
$ aws cloudformation deploy \
    --template-file compute-tier.yaml \
    --stack-name payments-compute \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        VpcId=vpc-0aa11bb22cc33dd44 \
        PublicSubnetIds=subnet-0111,subnet-0222 \
        PrivateSubnetIds=subnet-0333,subnet-0444 \
        AcmCertificateArn=arn:aws:acm:eu-west-1:111122223333:certificate/1a2b3c4d-...

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - payments-compute
```

```bash
$ aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names payments-compute-asg \
    --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,
             Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,
             Lifecycle:LifecycleState,Health:HealthStatus,
             Type:InstanceType,Market:InstanceLifecycle}}' \
    --output json
{
    "Desired": 4,
    "Min": 2,
    "Max": 20,
    "Instances": [
        {
            "Id": "i-0f3c9a1b2d4e5f607",
            "AZ": "eu-west-1a",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m7g.large",
            "Market": null
        },
        {
            "Id": "i-0a7b8c9d0e1f2a3b4",
            "AZ": "eu-west-1b",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m7g.large",
            "Market": null
        },
        {
            "Id": "i-01c2d3e4f5a6b7c8d",
            "AZ": "eu-west-1b",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "c7g.large",
            "Market": "spot"
        },
        {
            "Id": "i-09e8d7c6b5a4f3e21",
            "AZ": "eu-west-1c",
            "Lifecycle": "InService",
            "Health": "Healthy",
            "Type": "m6g.large",
            "Market": "spot"
        }
    ]
}
```

`Market: null` significa On-Demand; `Market: "spot"` confirma que la mixed-instances policy está respetando `OnDemandBaseCapacity: 2` y diversificando Spot entre tres tipos y tres AZs.

```bash
$ aws elbv2 describe-target-health \
    --target-group-arn arn:aws:elasticloadbalancing:eu-west-1:111122223333:targetgroup/payments-compute-tg/6d0ecf831eec9f09 \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table
-----------------------------------------------------------------------
|                        DescribeTargetHealth                          |
+----------------------+-------+--------+------------------------------+
|          Id          | Port  | State  |            Reason            |
+----------------------+-------+--------+------------------------------+
| i-0f3c9a1b2d4e5f607  | 8080  |healthy |  None                        |
| i-0a7b8c9d0e1f2a3b4  | 8080  |healthy |  None                        |
| i-01c2d3e4f5a6b7c8d  | 8080  |healthy |  None                        |
| i-09e8d7c6b5a4f3e21  | 8080  |initial |  Elb.RegistrationInProgress   |
+----------------------+-------+--------+------------------------------+
```

Entrá por shell a una instancia **sin clave SSH, sin bastión, sin puerto 22 entrante**:

```bash
$ aws ssm start-session --target i-0f3c9a1b2d4e5f607

Starting session with SessionId: platform-eng-0b1c2d3e4f5a6b7c8
sh-5.2$ systemctl is-active app.service
active
sh-5.2$ curl -s localhost:8080/healthz
ok
sh-5.2$ exit
Exiting session with sessionId: platform-eng-0b1c2d3e4f5a6b7c8.
```

### 12.4 Registrar y ejecutar el task de ECS

```bash
$ aws ecs register-task-definition --cli-input-json file://task-definition.json \
    --query 'taskDefinition.{Family:family,Rev:revision,Cpu:cpu,Mem:memory,Arch:runtimePlatform.cpuArchitecture,Status:status}' \
    --output table
------------------------------------------------------------
|                 RegisterTaskDefinition                    |
+--------+--------+---------------+--------+-------+--------+
|  Arch  |  Cpu   |    Family     |  Mem   |  Rev  | Status |
+--------+--------+---------------+--------+-------+--------+
| ARM64  | 1024   | payments-api  | 2048   | 17    | ACTIVE |
+--------+--------+---------------+--------+-------+--------+
```

```bash
$ aws ecs describe-services --cluster payments-prod --services payments-api \
    --query 'services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount,
             Status:status,Deployments:deployments[].{Id:id,Status:status,
             Running:runningCount,Rollout:rolloutState,Reason:rolloutStateReason}}' \
    --output json
{
    "Running": 6,
    "Desired": 6,
    "Pending": 0,
    "Status": "ACTIVE",
    "Deployments": [
        {
            "Id": "ecs-svc/9223370461234567890",
            "Status": "PRIMARY",
            "Running": 6,
            "Rollout": "COMPLETED",
            "Reason": "ECS deployment ecs-svc/9223370461234567890 completed."
        }
    ]
}
```

Confirmá que la división Spot/On-Demand efectivamente se materializó:

```bash
$ aws ecs list-tasks --cluster payments-prod --service-name payments-api --query 'taskArns' --output text \
  | xargs aws ecs describe-tasks --cluster payments-prod --tasks \
  | jq -r '.tasks[] | "\(.taskArn | split("/")[-1])  \(.capacityProviderName)  \(.availabilityZone)  \(.lastStatus)"'
3f9a1b2c4d5e6f708192a3b4c5d6e7f8  FARGATE       eu-west-1a  RUNNING
4a0b2c3d5e6f7081  92a3b4c5d6e7f809  FARGATE       eu-west-1b  RUNNING
5b1c3d4e6f708192  a3b4c5d6e7f80a1b  FARGATE_SPOT  eu-west-1a  RUNNING
6c2d4e5f70819    2a3b4c5d6e7f80a1c  FARGATE_SPOT  eu-west-1b  RUNNING
7d3e5f6081929    3b4c5d6e7f80a1b2d  FARGATE_SPOT  eu-west-1c  RUNNING
8e4f60719203     a4c5d6e7f80a1b2c3e FARGATE_SPOT  eu-west-1c  RUNNING
```

Base de 2 On-Demand + 4 Spot — exactamente la estrategia declarada.

Shell interactiva dentro de un task de Fargate, sin SSH y sin bastión:

```bash
$ aws ecs execute-command --cluster payments-prod \
    --task 3f9a1b2c4d5e6f708192a3b4c5d6e7f8 \
    --container api --interactive --command "/bin/sh"

The Session Manager plugin was installed successfully.
Starting session with SessionId: ecs-execute-command-0a1b2c3d4e5f6a7b8
/ $ cat /proc/self/cgroup | head -1
0::/
/ $ nproc
2
/ $ exit
```

### 12.5 Verificación de Lambda

```bash
$ aws lambda get-function-configuration --function-name settlement-processor \
    --query '{Runtime:Runtime,Arch:Architectures[0],Mem:MemorySize,Timeout:Timeout,
              Concurrency:ReservedConcurrentExecutions,Tmp:EphemeralStorage.Size,
              State:State,LastUpdate:LastUpdateStatus}' --output table
-------------------------------------------------------------------------
|                       GetFunctionConfiguration                         |
+-------+-------------+------+---------------+------+--------+-----+-----+
| Arch  | Concurrency | Mem  |  LastUpdate   | Run..| State  |Time.| Tmp |
+-------+-------------+------+---------------+------+--------+-----+-----+
| arm64 | 100         | 1024 | Successful    |pyth..| Active | 60  | 512 |
+-------+-------------+------+---------------+------+--------+-----+-----+
```

Invocá y leé la línea de facturación — cada invocación de Lambda termina con un registro `REPORT` que es tu telemetría principal de costo y de cold start:

```bash
$ aws lambda invoke --function-name settlement-processor \
    --payload '{"Records":[{"body":"{\"txId\":\"tx-8812\"}","messageId":"m-1"}]}' \
    --cli-binary-format raw-in-base64-out \
    --log-type Tail \
    /tmp/out.json \
    --query 'LogResult' --output text | base64 -d
START RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10 Version: 12
{"level":"INFO","service":"settlement","message":"processed 1 record","tx":"tx-8812"}
END RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10
REPORT RequestId: 6b1f0a44-5e3c-4a7d-9f21-0c8e2a4b6d10	Duration: 41.83 ms	Billed Duration: 42 ms	Memory Size: 1024 MB	Max Memory Used: 96 MB	Init Duration: 412.77 ms	XRAY TraceId: 1-68b95c1a-0f3a2b4c5d6e7f8091a2b3c4	SegmentId: 2d3e4f5a6b7c8d9e	Sampled: true
```

Leelo como un SRE:

- `Init Duration: 412.77 ms` — ocurrió un cold start. **No** está en `Billed Duration` para invocaciones estándar, pero *sí* está en la latencia que percibe el usuario.
- `Max Memory Used: 96 MB` de `1024 MB` — la función está sobre-aprovisionada en memoria *si* es I/O-bound. Si es CPU-bound, los 1.024 MB están comprando CPU, no memoria, y bajarlos va a hacerla más lenta. Medí ambas cosas antes de cambiar.
- `Billed Duration: 42 ms` × `1 GB` = 0,042 GB-segundos. A la tarifa publicada de arm64 de `$0.0000133334` por GB-segundo más `$0.20` por millón de requests, un millón de invocaciones así cuesta aproximadamente `0.042 × 1e6 × 0.0000133334 + 0.20 ≈ $0.76`.

Seguí los logs en vivo durante un incidente:

```bash
$ aws logs tail /aws/lambda/settlement-processor --follow --since 5m --format short
2026-09-04T14:03:11 INIT_START Runtime Version: python:3.12.v41
2026-09-04T14:03:12 START RequestId: 9c2d... Version: 12
2026-09-04T14:03:12 {"level":"ERROR","service":"settlement","message":"DynamoDB ProvisionedThroughputExceeded","tx":"tx-8813"}
2026-09-04T14:03:12 END RequestId: 9c2d...
2026-09-04T14:03:12 REPORT RequestId: 9c2d... Duration: 1204.11 ms Billed Duration: 1205 ms Memory Size: 1024 MB Max Memory Used: 102 MB
```

### 12.6 Preguntarle a AWS qué piensa que debería ser tu flota

```bash
$ aws compute-optimizer get-ec2-instance-recommendations \
    --query 'instanceRecommendations[].{Id:instanceArn,Current:currentInstanceType,
             Finding:finding,Best:recommendationOptions[0].instanceType,
             Saving:recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value}' \
    --output table
---------------------------------------------------------------------------
|                  GetEC2InstanceRecommendations                           |
+--------------+-------------+---------------+---------------+-------------+
|    Best      |   Current   |    Finding    |      Id       |   Saving    |
+--------------+-------------+---------------+---------------+-------------+
|  m7g.large   |  m5.2xlarge |  OVER_PROVIS..| arn:...i-0f3c |  187.42     |
|  c7g.xlarge  |  c5.2xlarge |  OVER_PROVIS..| arn:...i-0a7b |  142.08     |
|  r7g.large   |  r5.large   |  OPTIMIZED    | arn:...i-01c2 |  21.33      |
+--------------+-------------+---------------+---------------+-------------+
```

---

## 13. Runbook de diagnóstico — firmas de falla reales

### 13.1 `InsufficientInstanceCapacity` — el ASG no puede lanzar

```bash
$ aws autoscaling describe-scaling-activities \
    --auto-scaling-group-name payments-compute-asg --max-items 3 \
    --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:StatusMessage}' --output json
[
    {
        "Time": "2026-09-04T14:11:03.442000+00:00",
        "Status": "Failed",
        "Cause": "Launching a new EC2 instance. Status Reason: We currently do not have sufficient m7g.large capacity in the Availability Zone you requested (eu-west-1a). Our system will be working on provisioning additional capacity. Launching EC2 instance failed."
    }
]
```

| Causa | Remediación, en orden de preferencia |
|---|---|
| Un solo tipo de instancia, una sola AZ | Agregar `Overrides` con 4–6 tipos compatibles y abarcar todas las AZs — para eso está la mixed-instances policy |
| Familia genuinamente escasa (GPU, `.metal`) | Comprar por adelantado una **On-Demand Capacity Reservation** en la AZ que necesitás |
| Pool de Spot agotado | `SpotAllocationStrategy: price-capacity-optimized` + más pools; habilitar `CapacityRebalance` |
| Estructural | Usar **selección de tipos de instancia basada en atributos** (`InstanceRequirements`) para que el ASG elija cualquier tipo que cumpla los límites de vCPU/memoria |

### 13.2 Bucle de lanzamiento/terminación del ASG — las instancias nunca llegan a `InService`

```
Launching a new EC2 instance: i-0abc...      (InProgress)
Terminating EC2 instance: i-0abc...
  Cause: At 2026-09-04T14:20:11Z an instance was taken out of service in
  response to an ELB system health check failure.
```

El bootstrap no terminó antes de que el target group declare la falla. Revisá, en este orden:

1. **`HealthCheckGracePeriod` más corto que el tiempo de boot + `UserData`.** Con `dnf update` en `UserData`, 180 s puede ser demasiado poco. Medilo, y después poné el período de gracia en 2× ese valor.
2. **Security group** — el SG de la instancia tiene que permitir el puerto del target group *desde el SG del ALB*.
3. **El path del health check está mal** o devuelve algo fuera de `Matcher.HttpCode`.
4. **`UserData` falló.** Corre como root, una sola vez, y su salida va a un log — leelo en la instancia:

```bash
$ aws ssm start-session --target i-0abc123def456789
sh-5.2$ sudo tail -20 /var/log/cloud-init-output.log
+ dnf -y install python3.12 amazon-cloudwatch-agent
Error: Unable to find a match: amazon-cloudwatch-agent
+ exit 1
sh-5.2$ sudo systemctl status app.service
● app.service - Demo application
     Loaded: loaded (/etc/systemd/system/app.service; disabled)
     Active: inactive (dead)
```

`set -euxo pipefail` en `UserData` es lo que hace esto diagnosticable en lugar de silencioso. Sin `-e`, cloud-init reporta éxito mientras la aplicación nunca arranca.

### 13.3 El task de ECS no arranca — leé `stoppedReason` primero, siempre

```bash
$ aws ecs describe-tasks --cluster payments-prod --tasks 3f9a1b2c4d5e6f708192a3b4c5d6e7f8 \
    --query 'tasks[0].{Last:lastStatus,Desired:desiredStatus,Stopped:stoppedReason,
             Containers:containers[].{Name:name,Reason:reason,Exit:exitCode}}' --output json
{
    "Last": "STOPPED",
    "Desired": "STOPPED",
    "Stopped": "ResourceInitializationError: unable to pull secrets or registry auth: execution resource retrieval failed: unable to retrieve ecr registry auth: service call has been retried 3 time(s): RequestError: send request failed caused by: Post \"https://api.ecr.eu-west-1.amazonaws.com/\": dial tcp 10.0.3.14:443: i/o timeout",
    "Containers": [
        { "Name": "api", "Reason": null, "Exit": null }
    ]
}
```

| `stoppedReason` / firma | Causa raíz | Solución |
|---|---|---|
| `ResourceInitializationError … dial tcp … i/o timeout` | Task de Fargate en una subnet privada con `AssignPublicIp: DISABLED` y **sin ruta hacia ECR/Secrets Manager/CloudWatch Logs** | Agregar un NAT gateway, o (más barato y más seguro) VPC interface endpoints para `ecr.api`, `ecr.dkr`, `secretsmanager`, `logs` más un **gateway** endpoint de S3 para el almacén de capas de ECR |
| `CannotPullContainerError: … 403 Forbidden` | Al rol de **ejecución** del task le falta `ecr:GetAuthorizationToken` / `ecr:BatchGetImage` | Adjuntar `AmazonECSTaskExecutionRolePolicy` al rol de ejecución |
| `CannotPullContainerError: manifest unknown` | El tag no existe, o la arquitectura es incorrecta (task arm64, imagen solo amd64) | Verificar con `aws ecr describe-images`; construir un manifest multi-arch |
| Contenedor `Exit: 137` | `SIGKILL` — el contenedor excedió su límite de memoria (OOM) | Subir la memoria del task/contenedor, o arreglar la fuga; correlacionar con `MemoryUtilization` |
| Contenedor `Exit: 139` | `SIGSEGV` en el proceso | Bug de la aplicación o desajuste de biblioteca nativa/arquitectura |
| `Task failed ELB health checks` | La app arranca más lento que el período de gracia | Subir `HealthCheckGracePeriodSeconds` y agregar un `startPeriod` al contenedor |
| `RESOURCE:ENI` en los eventos del servicio | Las subnets del task se quedaron sin direcciones IP libres | `awsvpc` le da a cada task una ENI con una IP de la VPC — usá subnets más grandes, o tasks menos numerosos/más grandes |
| Los eventos del servicio dicen `unable to place a task because no container instance met all of its requirements` | **Solo launch type EC2** — ningún nodo tiene suficiente CPU/memoria/puertos libres | Escalar el ASG / usar un capacity provider de ECS con managed scaling, o reducir la reserva del task |

Leé siempre el stream de eventos del servicio — es el lugar más denso en información de ECS:

```bash
$ aws ecs describe-services --cluster payments-prod --services payments-api \
    --query 'services[0].events[:5].[createdAt,message]' --output text
2026-09-04T14:22:41+00:00	(service payments-api) has reached a steady state.
2026-09-04T14:21:55+00:00	(service payments-api) registered 2 targets in (target-group arn:aws:elasticloadbalancing:...)
2026-09-04T14:20:12+00:00	(service payments-api) has started 2 tasks: (task 5b1c3d4e...) (task 6c2d4e5f...).
2026-09-04T14:19:03+00:00	(service payments-api) was unable to place a task because no container instance met all of its requirements. The closest matching container-instance i-0cc... has insufficient memory available.
```

### 13.4 Throttling de Lambda

```bash
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Throttles \
    --dimensions Name=FunctionName,Value=settlement-processor \
    --start-time "$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[-5:].{T:Timestamp,Throttles:Sum}' --output table
--------------------------------------------
|          GetMetricStatistics              |
+------------+------------------------------+
| Throttles  |             T                |
+------------+------------------------------+
|  0.0       |  2026-09-04T14:00:00+00:00   |
|  412.0     |  2026-09-04T14:01:00+00:00   |
|  1893.0    |  2026-09-04T14:02:00+00:00   |
|  2044.0    |  2026-09-04T14:03:00+00:00   |
+------------+------------------------------+
```

Los llamadores ven `429 TooManyRequestsException` con `Rate Exceeded`. Tres causas distintas, tres soluciones distintas:

1. **Se alcanzó el límite de concurrencia de la cuenta (por defecto 1.000).** Verificá el margen:
   ```bash
   $ aws lambda get-account-settings --query 'AccountLimit.{Concurrent:ConcurrentExecutions,Unreserved:UnreservedConcurrentExecutions}'
   { "Concurrent": 1000, "Unreserved": 300 }
   ```
   Solo quedan 300 sin reservar — otra función reservó 700. Pedí un aumento de cuota en Service Quotas, o rebalanceá las reservas.
2. **El propio `ReservedConcurrentExecutions` de esta función es el techo.** Por diseño; subilo o aceptá la contrapresión.
3. **Se excedió la tasa de burst.** Lambda escala a una tasa acotada; un salto instantáneo de concurrencia de 0→5.000 hace throttle del excedente incluso con cuota disponible. Amortiguá con SQS, o usá concurrencia aprovisionada para el salto conocido.

Distinguí un timeout de un error — el log es inequívoco:

```
2026-09-04T14:05:22 END RequestId: a1b2...
2026-09-04T14:05:22 REPORT RequestId: a1b2... Duration: 60000.00 ms Billed Duration: 60000 ms Memory Size: 1024 MB Max Memory Used: 108 MB
2026-09-04T14:05:22 2026-09-04T14:05:22.881Z a1b2... Task timed out after 60.00 seconds
```

Una `Duration` exactamente igual al `Timeout` configurado es la firma. Investigá el llamado aguas abajo en el que la función está bloqueada — y verificá que el `VisibilityTimeout` de SQS sea al menos 6× el timeout de la función, o el mismo mensaje va a ser reentregado mientras la primera invocación sigue corriendo.

### 13.5 La imposición de IMDSv2 rompió algo

```bash
$ curl -s http://169.254.169.254/latest/meta-data/instance-id
<?xml version="1.0" encoding="iso-8859-1"?>
<html><head><title>401 - Unauthorized</title></head>
<body><h1>401 - Unauthorized</h1></body></html>
```

Esperado — `HttpTokens: required` rechaza la llamada IMDSv1 no autenticada. Cualquier agente o SDK anterior al despliegue de IMDSv2 tiene que actualizarse. Una variante más sutil: un **contenedor** en esa instancia recibe un timeout de red en lugar de un 401, porque el `HttpPutResponseHopLimit: 1` por defecto descarta el paquete después de un salto fuera del namespace de red del contenedor. Poné el hop limit en `2` — y solo en `2`, ya que valores más altos amplían la exposición a SSRF.

### 13.6 La factura se disparó sin cambio de tráfico

```bash
$ aws ce get-cost-and-usage \
    --time-period Start=2026-08-01,End=2026-09-01 \
    --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
    --query 'ResultsByTime[0].Groups[?to_number(Metrics.UnblendedCost.Amount)>`50`].[Keys[0],Metrics.UnblendedCost.Amount]' \
    --output text
EUW1-BoxUsage:m7g.large      1842.11
EUW1-CPUCredits:t3           612.40
EUW1-SpotUsage:c7g.large      203.77
EUW1-NatGateway-Bytes         488.02
```

`EUW1-CPUCredits:t3` en $612 es una flota T3 en **modo unlimited** corriendo permanentemente por encima del baseline — estás pagando una tarifa de excedente para simular que una instancia burstable es una de rendimiento fijo. Mové esa capa a la familia M; la instancia fija es más barata que el excedente.

---

## 14. Resumen enfocado en el examen

**Memorizá esto como reflejos:**

- Las tres piezas de contenedores: **ECR** (registro) → **ECS/EKS** (orquestador) → **EC2 o Fargate** (cómputo).
- **Fargate = contenedores serverless. Lambda = funciones serverless.** Ambos sacan el parcheo del SO de tus responsabilidades.
- **El techo duro de Lambda son 15 minutos.** Cualquier pregunta que mencione un job más largo no es una pregunta de Lambda.
- **Spot = hasta 90% de descuento, interrumpible con un aviso de 2 minutos**, solo para cargas tolerantes a fallos.
- **Savings Plans/RIs = compromiso a cambio de descuento, no de capacidad.** **Dedicated Hosts = BYOL y visibilidad del servidor físico.** **Capacity Reservations = capacidad garantizada, sin descuento por sí mismas.**
- **Auto Scaling = elasticidad + auto-reparación.** ELB = distribución. Son servicios distintos que resuelven problemas distintos y casi siempre aparecen juntos.
- **ALB = capa 7 / enrutamiento HTTP. NLB = capa 4 / IP estática / throughput extremo.**
- **Beanstalk despliega tu app sobre EC2 que todavía podés ver. App Runner y Lambda esconden todo. Lightsail es un paquete de precio fijo.**
- Beanstalk, Auto Scaling, CloudFormation y Compute Optimizer son **gratis**; pagás por los recursos que crean o miden.
- Escalera de borde/híbrido: **Outposts** (tu centro de datos) → **Local Zones** (tu ciudad) → **Wavelength** (red 5G) → **Snowball Edge** (desconectado).

**Preguntas trampa y sus respuestas:**

| Enunciado | Distractor que parece correcto | Respuesta correcta |
|---|---|---|
| "…sin gestionar servidores, corriendo contenedores" | Lambda | **Fargate** |
| "…corre 3 horas por job, miles de jobs, minimizar costo" | Lambda | **AWS Batch** (con Spot) |
| "…no debe interrumpirse, corre 24/7 durante 3 años" | Spot | **Reserved Instances / Savings Plans** |
| "…necesita una IP estática para una allowlist de firewall" | ALB | **NLB** |
| "…debe satisfacer una licencia de software por core físico" | Dedicated Instances | **Dedicated Hosts** |
| "…desplegar código sin configurar infraestructura, pero el equipo sigue necesitando acceso al SO" | App Runner | **Elastic Beanstalk** |
| "…latencia de un solo dígito de milisegundos hacia usuarios en una ciudad" | CloudFront | **AWS Local Zones** |
| "…reemplazar instancias fallidas automáticamente" | ELB | **EC2 Auto Scaling** |

---

## Referencias

Fuente primaria para este task statement:

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

Documentación oficial de AWS usada para construir el contenido técnico de arriba:

- Amazon EC2 User Guide — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html
- Amazon EC2 instance types — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html
- Burstable performance instances and CPU credits — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html
- Amazon EC2 instance purchasing options — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html
- Amazon EC2 Spot Instances — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
- Spot Instance interruption notices — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html
- Amazon EC2 Dedicated Hosts — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
- Placement groups — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-groups.html
- Instance metadata service (IMDSv2) — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS Nitro System — https://aws.amazon.com/ec2/nitro/
- AWS Nitro Enclaves — https://docs.aws.amazon.com/enclaves/latest/user/nitro-enclave.html
- AWS Graviton — https://aws.amazon.com/ec2/graviton/
- Amazon EC2 Auto Scaling User Guide — https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
- Auto Scaling groups with multiple instance types and purchase options — https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html
- Elastic Load Balancing — https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/what-is-load-balancing.html
- Amazon ECS Developer Guide — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html
- Amazon ECS task definition parameters — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html
- AWS Fargate for Amazon ECS — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html
- Amazon ECS stopped task error messages — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/stopped-task-error-codes.html
- Amazon EKS User Guide — https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html
- AWS Fargate for Amazon EKS — https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
- Amazon ECR User Guide — https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html
- AWS Lambda Developer Guide — https://docs.aws.amazon.com/lambda/latest/dg/welcome.html
- Lambda quotas — https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Lambda function scaling and concurrency — https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html
- Improving startup performance with Lambda SnapStart — https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html
- AWS Batch User Guide — https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html
- AWS Elastic Beanstalk Developer Guide — https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/Welcome.html
- AWS App Runner Developer Guide — https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html
- Amazon Lightsail — https://docs.aws.amazon.com/lightsail/latest/userguide/what-is-amazon-lightsail.html
- AWS Outposts — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- AWS Local Zones — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Compute Optimizer — https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html
- AWS Savings Plans User Guide — https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
- AWS Serverless Application Model (SAM) specification — https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html
- AWS CloudFormation resource reference — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/

> Los precios y las cuotas citados en este material reflejan las cifras publicadas para `us-east-1`/`eu-west-1` y son ilustrativos para razonar sobre trade-offs. Verificá los valores actuales contra la AWS Pricing Calculator (https://calculator.aws/) y la consola de Service Quotas antes de tomar una decisión de compromiso.