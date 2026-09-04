# 2.4 — Identificar componentes y recursos para la seguridad

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Dominio 2:** Seguridad y Cumplimiento (30% del examen)
**Peso del enunciado de la tarea:** 7.5
**Perfil de la audiencia:** SRE / Arquitecto de Plataforma. Escrito asumiendo que ya operás infraestructura en producción y necesitás la *mecánica*, no la taxonomía de marketing.

---

## 1. El problema arquitectónico que este enunciado de tarea realmente codifica

La guía del examen formula la tarea 2.4 de manera insulsa — "identificar componentes y recursos para la seguridad". El problema de producción que subyace es mucho más agudo, y es la razón por la que existe toda la lista de servicios:

> **En una AWS Organization multi-cuenta, ningún servicio por sí solo sabe si estás comprometido.** La señal está fragmentada entre siete planos de datos distintos, cada uno con su propia retención, su propio alcance de región, su propio interruptor de habilitación, y su propio modo de falla de *no producir nada silenciosamente*.

Concretamente. Operás 40 cuentas. Alguien exfiltra datos de un bucket de S3 a las 03:14 UTC usando credenciales estáticas de larga duración filtradas en un repositorio público. Para detectar eso, necesitás:

| Pregunta | Qué plano la responde | Qué debió haberse habilitado *antes* del evento |
|---|---|---|
| ¿Qué llamadas a la API se hicieron, por quién, desde dónde? | Eventos de gestión + de datos de **CloudTrail** | Trail de organización con eventos de datos de S3 (los eventos de datos están **desactivados por defecto** y cuestan dinero) |
| ¿El comportamiento del llamante fue anómalo? | **GuardDuty** (`UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration`, `Exfiltration:S3/AnomalousBehavior`) | Detector habilitado **por cuenta, por región**, con S3 Protection activo |
| ¿El bucket contenía datos regulados? | **Macie** | Trabajo de descubrimiento de datos sensibles o descubrimiento automatizado sobre ese bucket |
| ¿El bucket estaba público / mal configurado? | Reglas de **Config** + controles FSBP de **Security Hub** | Grabador de configuración corriendo en esa región |
| ¿Cuál es el radio de impacto de ese principal? | **IAM Access Analyzer** + **Detective** | Analyzer con alcance de organización; Detective habilitado ≥ 2 semanas antes, para tener historial en el grafo |
| ¿El tráfico realmente salió de la VPC? | **VPC Flow Logs** | Flow logs habilitados en la VPC/subred/ENI |
| ¿La credencial era alcanzable siquiera? | **Security Groups / NACLs / WAF** | Controles de red de línea base |

Cada fila es un **compromiso previo**. Los servicios de seguridad en AWS son casi universalmente *prospectivos*: habilitar GuardDuty hoy te da cero visibilidad sobre ayer. Esta es la propiedad operativamente más importante de todo el dominio, y es por eso que el examen sigue preguntando "¿qué servicio usarías para…?" — la respuesta debe elegirse y habilitarse antes del incidente.

El segundo hecho estructural: **el modelo de responsabilidad compartida traza la línea, y todo lo que hay en este enunciado de tarea vive del lado del cliente.** AWS te da los *controles*; habilitarlos, configurarlos, agregarlos y actuar sobre ellos es tuyo. AWS no va a activar GuardDuty por vos, no va a impedir que abras `0.0.0.0/0` en el puerto 22, y no te va a avisar que tu política de clave de KMS te dejó afuera.

### 1.1 Los tres planos

Todo en 2.4 se ordena limpiamente en tres planos. Aprendé esta forma y la lista de servicios deja de ser memorización:

```
                          ┌──────────────────────────────────────────┐
   PREVENT                │ IAM / SCPs / Security Groups / NACLs      │
   (block it happening)   │ WAF / Shield / Network Firewall           │
                          │ KMS / CloudHSM / ACM / Secrets Manager    │
                          └──────────────────────────────────────────┘
                                            │
                          ┌──────────────────────────────────────────┐
   DETECT                 │ GuardDuty / Inspector / Macie             │
   (know it happened)     │ Config / CloudTrail / Access Analyzer     │
                          │ Security Hub (aggregation + standards)    │
                          └──────────────────────────────────────────┘
                                            │
                          ┌──────────────────────────────────────────┐
   RESPOND                │ Detective / Security Incident Response    │
   (do something)         │ EventBridge → Lambda / SSM Automation     │
                          │ Shield Response Team (SRT) / AWS Support  │
                          └──────────────────────────────────────────┘
```

---

## 2. El plano de detección: cuatro servicios que se confunden constantemente

Esta es la comparación de mayor rendimiento de todo el dominio. GuardDuty, Inspector, Macie y Detective responden cuatro preguntas *diferentes*, y el examen evalúa exactamente esa distinción.

| | **Amazon GuardDuty** | **Amazon Inspector** | **Amazon Macie** | **Amazon Detective** |
|---|---|---|---|---|
| **Pregunta que responde** | "¿Está pasando algo malicioso *ahora mismo*?" | "¿Hay una vulnerabilidad conocida en mi software?" | "¿Dónde están mis datos sensibles?" | "¿Cuál es la historia completa detrás de este hallazgo?" |
| **Tipo** | Detección de amenazas (comportamiento / IoC) | Gestión de vulnerabilidades (CVE) | Clasificación de datos | Investigación / grafo de causa raíz |
| **Fuentes de datos primarias** | Eventos de gestión de CloudTrail, VPC Flow Logs, logs de consultas DNS de Route 53 Resolver (todos leídos *fuera de banda*, sin necesidad de habilitar logging) | Inventario del agente SSM + escaneo sin agente de snapshots de EBS; capas de imágenes de ECR; código y capas de Lambda | Contenido de objetos de S3 | CloudTrail, VPC Flow Logs, hallazgos de GuardDuty, logs de auditoría de EKS |
| **Planes de protección opcionales** | S3 Protection, EKS Audit Log Monitoring, RDS Protection, Lambda Protection, Malware Protection (EC2/EBS + S3), Runtime Monitoring (EC2/ECS-Fargate/EKS) | EC2, ECR, Lambda, **escaneos de benchmark CIS**, seguridad de código | Descubrimiento automatizado de datos sensibles + trabajos programados/puntuales | — |
| **¿Requiere agente?** | **No** para las fuentes fundacionales. **Sí** para Runtime Monitoring (agente de seguridad de GuardDuty) | Agente SSM para EC2 (o modo sin agente); ninguno para ECR/Lambda | No | No |
| **Latencia hasta el primer hallazgo** | Minutos | Minutos–horas tras el primer inventario | Horas (basado en trabajos) | Necesita ~2 semanas de historial ingerido para ser útil |
| **¿Retroactivo?** | ❌ No | ⚠️ Parcialmente — escanea el estado actual, así que un CVE viejo pero presente se encuentra | ⚠️ Escanea los objetos actuales | ❌ No — el grafo empieza en la habilitación |
| **Factor de costo** | Volumen de eventos/logs analizados (por millón de eventos de CloudTrail, por GB de logs de flujo/DNS) | Por instancia / por escaneo de imagen / por función por mes | Por bucket evaluado + por GB clasificado | Por GB de datos ingeridos al grafo |
| **Apagalo y…** | Perdés la detección *futura* al instante | Perdés los resultados de escaneo tras una ventana de retención | Los hallazgos persisten 90 días | Los datos del grafo caducan |
| **Respuesta incorrecta común con la que se confunde** | Inspector | GuardDuty | Amazon Comprehend | GuardDuty |

**Los discriminadores de una línea que el examen premia:**

- **GuardDuty** = *comportamiento*. Cripto-minería, exfiltración de credenciales, escaneo de puertos, consultas DNS a C2, tráfico Tor.
- **Inspector** = *CVEs conocidos y exposición de red no intencionada* en EC2, imágenes de ECR y Lambda.
- **Macie** = *PII / PHI / PCI en S3*.
- **Detective** = *investigar un hallazgo que ya tenés*. Nunca genera hallazgos propios.

### 2.1 Security Hub: la capa de agregación, y su dependencia oculta

AWS Security Hub **no es un detector**. Es:

1. Un **normalizador** — todo se convierte a AWS Security Finding Format (ASFF), un esquema JSON con `SeverityLabel`, `Compliance.Status`, `Resources[]`, `ProductArn`.
2. Un **agregador** — entre cuentas (vía administrador delegado de Organizations) y entre regiones (vía una región de agregación designada).
3. Un **motor de cumplimiento** — *sí* ejecuta sus propias verificaciones contra estándares de seguridad:
   - AWS Foundational Security Best Practices (FSBP) v1.0.0
   - CIS AWS Foundations Benchmark v1.2.0 / v1.4.0 / v3.0.0
   - PCI DSS v3.2.1 / v4.0.1
   - NIST SP 800-53 Rev. 5
   - AWS Resource Tagging Standard

> **La trampa:** la gran mayoría de los controles de Security Hub están implementados como **reglas gestionadas de AWS Config**. Si el grabador de configuración de AWS Config no está corriendo en esa cuenta+región, esos controles reportan `NO_DATA` y tu puntaje de cumplimiento es una mentira por omisión. Security Hub sin Config es un panel de nada.

### 2.2 El resto del plano de detección

| Servicio | Qué es | ¿Gratis? |
|---|---|---|
| **AWS CloudTrail** | Log de auditoría de la API. **Habilitado por defecto** como *Event history* de 90 días (solo eventos de gestión, por región, no duradero, no exportable a escala). Un **trail** es lo que te da entrega multi-región duradera a S3. **CloudTrail Lake** da SQL sobre almacenes de eventos inmutables. | Event history gratis; una copia de eventos de gestión por trail gratis; **los eventos de datos siempre cuestan** |
| **AWS Config** | Grabador de *estado* de configuración + línea de tiempo de cambios + evaluación de reglas + conformance packs + remediación. Responde "¿cómo se veía este recurso el 12 de agosto?" | ❌ Por elemento de configuración + por evaluación de regla |
| **IAM Access Analyzer** | Usa razonamiento automatizado (seguridad demostrable) para encontrar recursos compartidos **fuera de tu zona de confianza**; también hallazgos de **acceso no utilizado** y **validación/generación de políticas** | Analyzers de acceso externo/no utilizado tarifados por recurso; validación de políticas gratis |
| **AWS Trusted Advisor** | Verificaciones de buenas prácticas en 6 pilares incl. **Seguridad** (security groups abiertos, MFA en root, claves de acceso expuestas, permisos de S3) | Verificaciones básicas de seguridad + cuotas de servicio para todos; **el conjunto completo requiere soporte Business / Enterprise On-Ramp / Enterprise** |
| **AWS Audit Manager** | Recolecta evidencia continuamente y la mapea a marcos (SOC 2, PCI DSS, GDPR, HIPAA) para producir informes de evaluación listos para el auditor | ❌ Por recurso evaluado |
| **AWS Artifact** | Portal de autoservicio para los informes de cumplimiento **de AWS mismo** (SOC 1/2/3, ISO 27001, PCI AoC) y acuerdos (BAA, HIPAA) | ✅ Gratis |

> **Artifact vs Audit Manager — un par clásico del examen.** Artifact = evidencia sobre los controles *de AWS* (el lado del proveedor en la responsabilidad compartida). Audit Manager = evidencia sobre *tus* controles (el lado del cliente).

---

## 3. El plano de protección de red

### 3.1 Ruta del paquete y orden de evaluación

Saber *dónde* se ubica cada control es lo que hace significativa a la tabla de compensaciones.

```
Internet
  │
  ├─ AWS Shield Standard ......... always on, free, L3/L4, no config, at the edge
  │
  ├─ Amazon Route 53 ............. DNS; Shield-protected
  │
  ├─ Amazon CloudFront ........... edge PoP
  │     └─ AWS WAF (scope=CLOUDFRONT) .... L7, evaluated AT THE EDGE
  │
  ▼ ── AWS Region ────────────────────────────────────────────────────
  │
  ├─ Internet Gateway
  ├─ Route table            ◄── AWS Network Firewall inserted here, via routing
  ├─ Network ACL            ◄── STATELESS, subnet boundary, allow AND deny
  ├─ Elastic Load Balancer
  │     └─ AWS WAF (scope=REGIONAL) ...... L7, after NACL/SG of the ALB subnet
  ├─ Network ACL            ◄── app subnet
  ├─ Security Group         ◄── STATEFUL, ENI boundary, allow ONLY
  └─ Host OS firewall (yours)
```

Dos consecuencias con las que los SREs se llevan un golpe:

1. **Un WAF sobre un ALB no puede proteger al listener del propio ALB de una inundación volumétrica L3/L4** — ese paquete nunca llega a la etapa de evaluación del WAF. Ese es el trabajo de Shield.
2. **Un deny de NACL surte efecto antes de que el security group siquiera se consulte.** Si tu app es inalcanzable y el SG se ve perfecto, la NACL es lo siguiente que hay que revisar — y específicamente la dirección de *retorno*.

### 3.2 Security Groups vs Network ACLs

| | **Security Group** | **Network ACL** |
|---|---|---|
| Se adjunta a | ENI (instancia, nodo de ALB, RDS, Lambda-en-VPC, mount target de EFS) | Subred |
| Manejo de estado | **Con estado (stateful)** — el tráfico de retorno se permite automáticamente | **Sin estado (stateless)** — el tráfico de retorno necesita su propia regla explícita |
| Tipos de regla | **Solo allow** (no existe la regla deny) | **Allow y deny** |
| Evaluación | Se evalúan todas las reglas de todos los SGs adjuntos; **unión**; el orden es irrelevante | Las reglas se evalúan **en orden ascendente de número de regla; gana la primera coincidencia**; DENY `*` implícito al final |
| Por defecto (creado con la VPC) | SG por defecto: permite todo el *entrante desde sí mismo*, permite todo el saliente | NACL por defecto: **permite todo, entrante y saliente** |
| Por defecto (recién creado) | Deniega todo el entrante, permite todo el saliente | **Deniega todo, entrante y saliente** — una NACL personalizada recién creada bloquea todo |
| ¿Puede referenciar otro SG / prefix list? | ✅ Sí — `sg-xxxx` como origen es el patrón idiomático | ❌ Solo CIDR |
| Máximo por recurso | 5 SGs por ENI (ajustable a 16) | 1 NACL por subred (una NACL puede cubrir muchas subredes) |
| Uso típico | Control primario de la carga de trabajo — **usá esto por defecto** | Deny grueso a nivel de subred (bloquear un CIDR abusivo), defensa en profundidad en entornos regulados |
| Costo | Gratis | Gratis |

**La regla de los puertos efímeros.** Como las NACLs no tienen estado, una petición HTTPS entrante necesita un allow *saliente* para el puerto efímero de respuesta. El default del kernel de Linux es `32768–60999`; los nodos de ELB y los NAT gateways usan `1024–65535`. La propia guía de AWS es permitir `1024–65535` saliente, razón por la cual una NACL "endurecida" que solo permite `443` saliente rompe todas las capas web que se hayan construido jamás.

### 3.3 WAF vs Shield vs Network Firewall vs Firewall Manager

| | **AWS WAF** | **AWS Shield Standard** | **AWS Shield Advanced** | **AWS Network Firewall** | **AWS Firewall Manager** |
|---|---|---|---|---|---|
| Capa OSI | 7 (HTTP/HTTPS) | 3 / 4 | 3 / 4 / 7 (con WAF) | 3–7 (IPS Suricata) | n/a — gestor de políticas |
| Protege contra | SQLi, XSS, bots maliciosos, scrapers, inundaciones L7, abuso geo/IP | DDoS común de infraestructura (SYN flood, reflexión UDP) | DDoS grande/sofisticado + protección de costos | Filtrado de salida, listas de dominios permitidos, IDS/IPS, inspección TLS | — |
| Puntos de adjunción | CloudFront, ALB, API Gateway (REST), AppSync, user pool de Cognito, App Runner, Verified Access | Automático en CloudFront, Route 53, Global Accelerator, ELB, EIP de EC2 | Recursos protegidos explícitamente | VPC (vía enrutamiento hacia endpoints de firewall) | Aplica políticas de WAF/Shield Adv/SG/Network Firewall/DNS Firewall a nivel de organización |
| Habilitación | Opt-in, por Web ACL | **Siempre activo, nada que habilitar** | Suscripción | Desplegar endpoints + cambiar tablas de rutas | Requiere **AWS Organizations** + admin delegado |
| Extras clave | Grupos de reglas gestionadas (AWS + Marketplace), reglas basadas en tasa, Bot Control, Fraud Control / ATP, CAPTCHA y Challenge, fingerprinting JA3/JA4 | — | **Shield Response Team (SRT)** 24×7, **protección de costos DDoS** (créditos por cargos de escalado durante un ataque), detección basada en salud, WAF sin cargo adicional en los recursos protegidos | Grupos de reglas con estado en sintaxis Suricata, listas de dominios gestionadas | Auto-remediación de recursos no conformes; se auto-aplica a las cuentas *nuevas* |
| Precio de lista, orden de magnitud (us-east-1) | ~$5/Web ACL/mes + ~$1/regla/mes + ~$0.60/millón de peticiones | **$0** | **~$3.000/mes por organización**, compromiso de 1 año, + tarifas de DTO | ~$0.395/endpoint/h + ~$0.065/GB procesado | ~$100/política/región/mes |

> **Discriminadores a nivel de examen.** "Proteger una aplicación web de inyección SQL" → **WAF**. "Ya estamos protegidos contra DDoS común sin costo" → **Shield Standard**. "Necesitamos un equipo de respuesta 24/7 y reembolsos por costos de escalado provocados por un ataque" → **Shield Advanced**. "Aplicar las mismas reglas de WAF en 200 cuentas automáticamente, incluidas las cuentas creadas el mes que viene" → **Firewall Manager**. "Filtrar el tráfico *saliente* hacia solo dominios aprobados" → **Network Firewall** (o **Route 53 Resolver DNS Firewall** para la variante solo-DNS).

---

## 4. El plano de protección de datos

### 4.1 Cifrado en reposo vs en tránsito — y cifrado de sobre

**En tránsito** = TLS. Provisto por **AWS Certificate Manager (ACM)** para endpoints públicos (certificados públicos gratuitos, renovación automática — pero utilizables *solo* con servicios integrados: CloudFront, ALB/NLB, API Gateway, App Runner, Cognito; no podés exportar un certificado público de ACM a una instancia EC2). **AWS Private CA** emite certificados internos y se factura mensualmente por CA más por certificado.

**En reposo** = casi siempre **cifrado de sobre de AWS KMS**. La mecánica importa porque explica el precio, la latencia y los modos de falla:

```
1. Service calls kms:GenerateDataKey(KeyId=<CMK>, KeySpec=AES_256)
2. KMS returns { Plaintext: <256-bit DEK>, CiphertextBlob: <DEK encrypted under the CMK> }
3. Service encrypts the object/volume/row locally with the plaintext DEK  (fast, no KMS in the data path)
4. Service zeroises the plaintext DEK from memory and stores CiphertextBlob alongside the data
5. On read: service calls kms:Decrypt(CiphertextBlob) → plaintext DEK → decrypt data
```

El material de clave de KMS **nunca sale del HSM validado FIPS 140-3 Nivel 3**. Los datos masivos nunca se envían a KMS. Por eso `SSE-KMS` de S3 con **S3 Bucket Keys** habilitado reduce el costo de peticiones a KMS hasta en ~99% — la bucket key amortiza una llamada a `GenerateDataKey` entre muchos objetos.

### 4.2 Comparación de almacenes de claves y secretos

| | **AWS KMS** | **AWS CloudHSM** | **Secrets Manager** | **SSM Parameter Store** | **ACM** |
|---|---|---|---|---|---|
| Almacena | Claves de cifrado (simétricas, asimétricas, HMAC) | Claves de cifrado | Secretos (credenciales de BD, claves de API) | Valores de configuración + secretos (`SecureString`) | Certificados X.509 |
| Tenencia | Flota de HSM gestionada multi-tenant | **HSM dedicado, single-tenant, en tu VPC** | Gestionado | Gestionado | Gestionado |
| FIPS | 140-3 Nivel 3 | 140-3 Nivel 3 | (usa KMS) | (usa KMS) | — |
| Quién controla el material de clave | AWS opera los HSMs; vos controlás la política de clave. AWS **no** tiene acceso a tu material de clave | **Vos** — AWS no puede recuperar tus claves si perdés las credenciales | — | — | — |
| Rotación integrada | ✅ Rotación anual automática de claves (configurable 90–2560 días) + rotación bajo demanda | ❌ Manual | ✅ **Sí — nativa, vía función Lambda de rotación; RDS/Redshift/DocumentDB son llave en mano** | ❌ No | ✅ Renovación automática para certificados públicos |
| Entre cuentas | ✅ vía política de clave | Por diseño de la aplicación | ✅ vía política de recurso | ✅ (nivel advanced) | Limitado |
| Costo, orden de magnitud | ~$1/clave/mes + ~$0.03 por 10k peticiones | **~$1.45–$1.60/HSM/h** (≈$1.000+/mes por HSM, mín. 2 para HA) | ~$0.40/secreto/mes + ~$0.05 por 10k llamadas a la API | **Nivel standard gratis**; advanced ~$0.05/parámetro/mes | **Certificados públicos gratis**; Private CA ~$400/mes |
| Elegilo cuando | Por defecto para todo | Mandato regulatorio de HSM single-tenant, o necesitás offload PKCS#11/JCE/CNG | Necesitás **rotación automática** | Necesitás configuración barata; secretos sin rotación | Terminación TLS en servicios integrados con AWS |

> **La decisión que cuesta dinero:** Secrets Manager vs `SecureString` de Parameter Store. Con 500 secretos eso son ~$200/mes vs $0. El diferenciador por el que vale la pena pagar es la **rotación nativa** y las **políticas de recurso entre cuentas**. Si un secreto nunca rota, el nivel standard de Parameter Store es la respuesta de ingeniería correcta.

> **Tipos de clave de KMS en el examen:** *AWS owned keys* (invisibles, gratis, compartidas entre clientes, sin control de rotación) → *AWS managed keys* (`aws/s3`, `aws/ebs`, una por servicio por cuenta, gratis, auto-rotadas, **política de clave no editable**) → *Customer managed keys* (las creás vos, definís la política de clave, podés deshabilitarlas/programar su eliminación a 7–30 días, podés auditar cada uso en CloudTrail). Solo una **customer managed key** te da la capacidad de *denegar* servicios de AWS o de destruir datos criptográficamente programando la eliminación de la clave.

---

## 5. Infraestructura completa — línea base de seguridad de la organización

Lo siguiente son artefactos completos y desplegables. No se omite nada.

### 5.1 `security-baseline.yaml` — CloudTrail + Config + GuardDuty + Security Hub

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Security detection baseline for the delegated security/audit account:
  KMS-encrypted log archive, organization CloudTrail with log-file validation,
  AWS Config recorder, GuardDuty detector with all protection plans, and
  Security Hub with FSBP + CIS v3.0.0. Deploy once per region you operate in.

Parameters:
  OrganizationId:
    Type: String
    Description: AWS Organizations ID (o-xxxxxxxxxx) used for the org-trail S3 prefix.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
  TrailName:
    Type: String
    Default: org-security-trail
  LogRetentionDays:
    Type: Number
    Default: 400
    MinValue: 1
  SecurityContactEmail:
    Type: String
    Description: Address subscribed to CRITICAL/HIGH Security Hub findings.
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'

Resources:

  # ---------------------------------------------------------------- KMS ----
  SecurityLogsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: CMK for the security log archive (CloudTrail + Config).
      EnableKeyRotation: true
      KeySpec: SYMMETRIC_DEFAULT
      KeyUsage: ENCRYPT_DECRYPT
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: security-logs-key-policy
        Statement:
          # Without this statement the key is orphaned and unmanageable.
          - Sid: EnableIAMPoliciesInThisAccount
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowCloudTrailToEncryptLogs
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:GenerateDataKey*'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${AWS::AccountId}:trail/*'
          - Sid: AllowCloudTrailToDescribeKey
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:DescribeKey'
            Resource: '*'
          - Sid: AllowConfigToEncryptDeliveries
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action:
              - 'kms:GenerateDataKey*'
              - 'kms:Decrypt'
              - 'kms:DescribeKey'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
          - Sid: AllowOrgMembersToDecryptTheirOwnLogs
            Effect: Allow
            Principal: '*'
            Action:
              - 'kms:Decrypt'
              - 'kms:DescribeKey'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrganizationId

  SecurityLogsKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: alias/security-logs
      TargetKeyId: !Ref SecurityLogsKey

  # ----------------------------------------------------------------- S3 ----
  SecurityLogsBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub 'security-logs-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true
            ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt SecurityLogsKey.Arn
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
          - Id: transition-and-expire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
            ExpirationInDays: !Ref LogRetentionDays
            NoncurrentVersionExpiration:
              NoncurrentDays: 30

  SecurityLogsBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref SecurityLogsBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt SecurityLogsBucket.Arn
              - !Sub '${SecurityLogsBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyUnencryptedObjectUploads
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${SecurityLogsBucket.Arn}/*'
            Condition:
              StringNotEquals:
                's3:x-amz-server-side-encryption': 'aws:kms'
          - Sid: AWSCloudTrailAclCheck
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:GetBucketAcl'
            Resource: !GetAtt SecurityLogsBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/${TrailName}'
          - Sid: AWSCloudTrailWrite
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:PutObject'
            Resource:
              # Both prefixes are required: the management account writes under its
              # own account ID, member accounts write under the organization ID.
              - !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/*'
              - !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${OrganizationId}/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/${TrailName}'
          - Sid: AWSConfigBucketPermissionsCheck
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action:
              - 's3:GetBucketAcl'
              - 's3:ListBucket'
            Resource: !GetAtt SecurityLogsBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
          - Sid: AWSConfigBucketDelivery
            Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/Config/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  # ---------------------------------------------------------- CloudTrail ----
  OrganizationTrail:
    Type: AWS::CloudTrail::Trail
    DependsOn: SecurityLogsBucketPolicy
    Properties:
      TrailName: !Ref TrailName
      S3BucketName: !Ref SecurityLogsBucket
      IsLogging: true
      IsMultiRegionTrail: true
      IsOrganizationTrail: true
      IncludeGlobalServiceEvents: true
      EnableLogFileValidation: true
      KMSKeyId: !GetAtt SecurityLogsKey.Arn
      AdvancedEventSelectors:
        - Name: Log all management events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Management']
        - Name: Log S3 object-level data events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::S3::Object']
            # Exclude the log archive itself, or the trail records its own writes
            # in an unbounded feedback loop.
            - Field: resources.ARN
              NotStartsWith:
                - !Sub '${SecurityLogsBucket.Arn}/'
        - Name: Log Lambda invocation data events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::Lambda::Function']

  # -------------------------------------------------------------- Config ----
  ConfigServiceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub 'AWSConfigRole-${AWS::Region}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWS_ConfigRole'
      Policies:
        - PolicyName: config-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 's3:PutObject'
                Resource: !Sub '${SecurityLogsBucket.Arn}/AWSLogs/${AWS::AccountId}/Config/*'
                Condition:
                  StringEquals:
                    's3:x-amz-acl': 'bucket-owner-full-control'
              - Effect: Allow
                Action: 's3:GetBucketAcl'
                Resource: !GetAtt SecurityLogsBucket.Arn
              - Effect: Allow
                Action:
                  - 'kms:GenerateDataKey'
                  - 'kms:Decrypt'
                Resource: !GetAtt SecurityLogsKey.Arn

  ConfigDeliveryChannel:
    Type: AWS::Config::DeliveryChannel
    DependsOn: SecurityLogsBucketPolicy
    Properties:
      Name: default
      S3BucketName: !Ref SecurityLogsBucket
      S3KmsKeyArn: !GetAtt SecurityLogsKey.Arn
      ConfigSnapshotDeliveryProperties:
        DeliveryFrequency: TwentyFour_Hours

  ConfigRecorder:
    Type: AWS::Config::ConfigurationRecorder
    DependsOn: ConfigDeliveryChannel
    Properties:
      Name: default
      RoleARN: !GetAtt ConfigServiceRole.Arn
      RecordingGroup:
        AllSupported: true
        IncludeGlobalResourceTypes: true
      RecordingMode:
        RecordingFrequency: CONTINUOUS

  # ----------------------------------------------------------- GuardDuty ----
  GuardDutyDetector:
    Type: AWS::GuardDuty::Detector
    Properties:
      Enable: true
      FindingPublishingFrequency: FIFTEEN_MINUTES
      Features:
        - Name: S3_DATA_EVENTS
          Status: ENABLED
        - Name: EKS_AUDIT_LOGS
          Status: ENABLED
        - Name: EBS_MALWARE_PROTECTION
          Status: ENABLED
        - Name: RDS_LOGIN_EVENTS
          Status: ENABLED
        - Name: LAMBDA_NETWORK_LOGS
          Status: ENABLED
        - Name: RUNTIME_MONITORING
          Status: ENABLED
          AdditionalConfiguration:
            - Name: EKS_ADDON_MANAGEMENT
              Status: ENABLED
            - Name: ECS_FARGATE_AGENT_MANAGEMENT
              Status: ENABLED
            - Name: EC2_AGENT_MANAGEMENT
              Status: ENABLED

  # --------------------------------------------------------- Security Hub ----
  SecurityHub:
    Type: AWS::SecurityHub::Hub
    DependsOn: ConfigRecorder
    Properties:
      EnableDefaultStandards: false
      ControlFindingGenerator: SECURITY_CONTROL
      AutoEnableControls: true
      Tags:
        Owner: platform-security

  FoundationalSecurityBestPractices:
    Type: AWS::SecurityHub::Standard
    DependsOn: SecurityHub
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/aws-foundational-security-best-practices/v/1.0.0'

  CISBenchmark:
    Type: AWS::SecurityHub::Standard
    DependsOn: FoundationalSecurityBestPractices
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/cis-aws-foundations-benchmark/v/3.0.0'

  # ------------------------------------------------------------ Alerting ----
  SecurityAlertsTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: security-critical-findings
      KmsMasterKeyId: !Ref SecurityLogsKey
      Subscription:
        - Protocol: email
          Endpoint: !Ref SecurityContactEmail

  SecurityAlertsTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SecurityAlertsTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SecurityAlertsTopic
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'

  CriticalFindingRule:
    Type: AWS::Events::Rule
    Properties:
      Name: securityhub-critical-and-high
      Description: Route new CRITICAL/HIGH Security Hub findings to the security topic.
      State: ENABLED
      EventPattern:
        source:
          - aws.securityhub
        detail-type:
          - 'Security Hub Findings - Imported'
        detail:
          findings:
            Severity:
              Label:
                - CRITICAL
                - HIGH
            Workflow:
              Status:
                - NEW
            RecordState:
              - ACTIVE
      Targets:
        - Id: security-topic
          Arn: !Ref SecurityAlertsTopic
          InputTransformer:
            InputPathsMap:
              severity: '$.detail.findings[0].Severity.Label'
              title: '$.detail.findings[0].Title'
              account: '$.detail.findings[0].AwsAccountId'
              region: '$.detail.findings[0].Region'
              resource: '$.detail.findings[0].Resources[0].Id'
              product: '$.detail.findings[0].ProductName'
            InputTemplate: |
              "[<severity>] <product>: <title>"
              "Account: <account>  Region: <region>"
              "Resource: <resource>"

Outputs:
  LogArchiveBucket:
    Description: S3 bucket holding CloudTrail and Config deliveries.
    Value: !Ref SecurityLogsBucket
    Export:
      Name: !Sub '${AWS::StackName}-LogBucket'
  LogArchiveKeyArn:
    Description: CMK protecting the log archive.
    Value: !GetAtt SecurityLogsKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-LogKeyArn'
  GuardDutyDetectorId:
    Description: Detector ID for this account/region.
    Value: !Ref GuardDutyDetector
  SecurityAlertsTopicArn:
    Value: !Ref SecurityAlertsTopic
```

### 5.2 `network-guardrails.yaml` — SGs de tres capas y una NACL sin estado

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Three-tier network segmentation demonstrating stateful security groups
  (SG-to-SG references) alongside a stateless network ACL with the explicit
  ephemeral-port return rules that stateless filtering requires.

Parameters:
  VpcCidr:
    Type: String
    Default: 10.40.0.0/16
  AdminCidr:
    Type: String
    Default: 10.0.0.0/8
    Description: Trusted CIDR permitted to reach the bastion. Never 0.0.0.0/0.

Resources:

  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: prod-vpc

  PublicSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: false
      Tags:
        - Key: Name
          Value: prod-public-a

  AppSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: prod-app-a

  DataSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 6, 8]]
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: prod-data-a

  # ------------------------------------------------------ Security Groups ---
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Public ALB - terminates TLS from the internet.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: HTTPS from the internet
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Placeholder - real egress added by AlbToAppEgress
      Tags:
        - Key: Name
          Value: sg-alb

  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Application tier - reachable only from the ALB.
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Outbound HTTPS to AWS APIs and package mirrors
      Tags:
        - Key: Name
          Value: sg-app

  DataSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: PostgreSQL - reachable only from the application tier.
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 127.0.0.1/32
          Description: Database initiates no outbound connections
      Tags:
        - Key: Name
          Value: sg-data

  BastionSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Break-glass bastion. Prefer SSM Session Manager over this.
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: !Ref AdminCidr
          Description: SSH from the trusted admin network only
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          DestinationSecurityGroupId: !Ref AppSecurityGroup
          Description: SSH into the application tier
      Tags:
        - Key: Name
          Value: sg-bastion

  # Separate rule resources: SG-to-SG references are mutually recursive and
  # cannot be expressed inline without a circular dependency.
  AlbToAppEgress:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AlbSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      DestinationSecurityGroupId: !Ref AppSecurityGroup
      Description: ALB to application listener

  AppFromAlbIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 8080
      ToPort: 8080
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: Application listener, ALB only

  AppFromBastionIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 22
      ToPort: 22
      SourceSecurityGroupId: !Ref BastionSecurityGroup
      Description: Break-glass SSH from the bastion

  AppToDataEgress:
    Type: AWS::EC2::SecurityGroupEgress
    Properties:
      GroupId: !Ref AppSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      DestinationSecurityGroupId: !Ref DataSecurityGroup
      Description: Application to PostgreSQL

  DataFromAppIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DataSecurityGroup
      IpProtocol: tcp
      FromPort: 5432
      ToPort: 5432
      SourceSecurityGroupId: !Ref AppSecurityGroup
      Description: PostgreSQL, application tier only

  # ---------------------------------------------------------- Network ACL ---
  DataTierNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: nacl-data-tier

  DataTierNaclAssociation:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties:
      SubnetId: !Ref DataSubnetA
      NetworkAclId: !Ref DataTierNacl

  # Inbound: PostgreSQL from the app tier only.
  NaclInboundPostgres:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 100
      Protocol: 6            # TCP
      RuleAction: allow
      Egress: false
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, 8]]
      PortRange:
        From: 5432
        To: 5432

  # Inbound: return traffic for connections the data tier initiates
  # (e.g. RDS reaching S3 for backups through a gateway endpoint).
  NaclInboundEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: false
      CidrBlock: !Ref VpcCidr
      PortRange:
        From: 1024
        To: 65535

  NaclInboundDenyAllOther:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 32000
      Protocol: -1
      RuleAction: deny
      Egress: false
      CidrBlock: 0.0.0.0/0

  # Outbound: THIS is the rule people forget. A NACL is stateless, so the
  # response to an inbound :5432 request leaves from an ephemeral source port
  # and needs its own explicit allow. Linux uses 32768-60999; ELB and NAT
  # gateway use 1024-65535, so allow the wider range.
  NaclOutboundEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 100
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: !Ref VpcCidr
      PortRange:
        From: 1024
        To: 65535

  NaclOutboundHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 110
      Protocol: 6
      RuleAction: allow
      Egress: true
      CidrBlock: 0.0.0.0/0
      PortRange:
        From: 443
        To: 443

  NaclOutboundDenyAllOther:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataTierNacl
      RuleNumber: 32000
      Protocol: -1
      RuleAction: deny
      Egress: true
      CidrBlock: 0.0.0.0/0

  # ------------------------------------------------------- VPC Flow Logs ----
  FlowLogsGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/vpc/prod-flowlogs
      RetentionInDays: 90

  FlowLogsRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: vpc-flow-logs.amazonaws.com
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref 'AWS::AccountId'
      Policies:
        - PolicyName: publish-flow-logs
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                  - 'logs:DescribeLogStreams'
                Resource: !GetAtt FlowLogsGroup.Arn

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceType: VPC
      ResourceId: !Ref Vpc
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogsGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogsRole.Arn
      MaxAggregationInterval: 60
      LogFormat: >-
        ${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr}
        ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end}
        ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id}
        ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr} ${flow-direction}

Outputs:
  VpcId:
    Value: !Ref Vpc
  AlbSecurityGroupId:
    Value: !Ref AlbSecurityGroup
  AppSecurityGroupId:
    Value: !Ref AppSecurityGroup
  DataSecurityGroupId:
    Value: !Ref DataSecurityGroup
```

### 5.3 `waf-webacl.yaml` — una Web ACL regional con reglas gestionadas, límite de tasa y logging

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Regional AWS WAF Web ACL for an Application Load Balancer: AWS managed rule
  groups, IP reputation, an anonymous-IP block, a per-IP rate limit, and full
  request logging with credential redaction.

Parameters:
  LoadBalancerArn:
    Type: String
    Description: ARN of the ALB to associate the Web ACL with.
  RateLimitPer5Min:
    Type: Number
    Default: 2000
    MinValue: 10
    Description: Requests per 5-minute sliding window per source IP.

Resources:

  WafLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      # The name MUST start with aws-waf-logs- or the LoggingConfiguration
      # is rejected with WAFInvalidParameterException.
      LogGroupName: aws-waf-logs-prod-alb
      RetentionInDays: 30

  ProdWebAcl:
    Type: AWS::WAFv2::WebACL
    Properties:
      Name: prod-alb-protection
      Scope: REGIONAL          # CLOUDFRONT would require deploying in us-east-1
      Description: Baseline L7 protection for the production ALB.
      DefaultAction:
        Allow: {}
      VisibilityConfig:
        SampledRequestsEnabled: true
        CloudWatchMetricsEnabled: true
        MetricName: prod-alb-protection
      Rules:

        # 10 - Amazon IP reputation list: known malicious sources.
        - Name: AWSManagedRulesAmazonIpReputationList
          Priority: 10
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesAmazonIpReputationList
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: ip-reputation

        # 20 - Core rule set (OWASP-style baseline). SizeRestrictions_BODY is
        # excluded because our upload endpoint legitimately exceeds 8 KB.
        - Name: AWSManagedRulesCommonRuleSet
          Priority: 20
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesCommonRuleSet
              RuleActionOverrides:
                - Name: SizeRestrictions_BODY
                  ActionToUse:
                    Count: {}
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: common-rule-set

        # 30 - Known bad inputs: Log4j (Log4JRCE), path traversal, host header injection.
        - Name: AWSManagedRulesKnownBadInputsRuleSet
          Priority: 30
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesKnownBadInputsRuleSet
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: known-bad-inputs

        # 40 - SQL injection, scoped to the request body and query string.
        - Name: AWSManagedRulesSQLiRuleSet
          Priority: 40
          OverrideAction:
            None: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesSQLiRuleSet
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: sqli

        # 50 - Anonymising infrastructure. Started in COUNT: measure before
        # you block, or you will page yourself at 02:00 for your own VPN.
        - Name: AWSManagedRulesAnonymousIpList
          Priority: 50
          OverrideAction:
            Count: {}
          Statement:
            ManagedRuleGroupStatement:
              VendorName: AWS
              Name: AWSManagedRulesAnonymousIpList
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: anonymous-ip

        # 60 - Per-IP rate limit, excluding static assets which fan out heavily.
        - Name: RateLimitPerSourceIp
          Priority: 60
          Action:
            Block:
              CustomResponse:
                ResponseCode: 429
                ResponseHeaders:
                  - Name: Retry-After
                    Value: '300'
          Statement:
            RateBasedStatement:
              Limit: !Ref RateLimitPer5Min
              AggregateKeyType: IP
              ScopeDownStatement:
                NotStatement:
                  Statement:
                    ByteMatchStatement:
                      SearchString: /static/
                      FieldToMatch:
                        UriPath: {}
                      TextTransformations:
                        - Priority: 0
                          Type: LOWERCASE
                      PositionalConstraint: STARTS_WITH
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: rate-limit-per-ip

        # 70 - Stricter rate limit on the login endpoint (credential stuffing).
        - Name: RateLimitLoginEndpoint
          Priority: 70
          Action:
            Block: {}
          Statement:
            RateBasedStatement:
              Limit: 100
              AggregateKeyType: IP
              ScopeDownStatement:
                ByteMatchStatement:
                  SearchString: /api/v1/login
                  FieldToMatch:
                    UriPath: {}
                  TextTransformations:
                    - Priority: 0
                      Type: LOWERCASE
                  PositionalConstraint: EXACTLY
          VisibilityConfig:
            SampledRequestsEnabled: true
            CloudWatchMetricsEnabled: true
            MetricName: rate-limit-login

  WebAclAssociation:
    Type: AWS::WAFv2::WebACLAssociation
    Properties:
      ResourceArn: !Ref LoadBalancerArn
      WebACLArn: !GetAtt ProdWebAcl.Arn

  WebAclLogging:
    Type: AWS::WAFv2::LoggingConfiguration
    Properties:
      ResourceArn: !GetAtt ProdWebAcl.Arn
      LogDestinationConfigs:
        - !GetAtt WafLogGroup.Arn
      RedactedFields:
        - SingleHeader:
            Name: authorization
        - SingleHeader:
            Name: cookie
        - SingleHeader:
            Name: x-api-key
      LoggingFilter:
        DefaultBehavior: DROP        # Only persist non-ALLOW outcomes
        Filters:
          - Behavior: KEEP
            Requirement: MEETS_ANY
            Conditions:
              - ActionCondition:
                  Action: BLOCK
              - ActionCondition:
                  Action: COUNT
              - ActionCondition:
                  Action: CAPTCHA

Outputs:
  WebAclArn:
    Value: !GetAtt ProdWebAcl.Arn
  WebAclId:
    Value: !GetAtt ProdWebAcl.Id
```

### 5.4 `scp-protect-security-services.json` — una Service Control Policy

Una SCP es el único mecanismo que impide que un *administrador de cuenta* deshabilite tu plano de detección. Adjuntala a la unidad organizativa que contiene las cuentas de carga de trabajo.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDisablingSecurityServices",
      "Effect": "Deny",
      "Action": [
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:DisassociateMembers",
        "guardduty:UpdateDetector",
        "guardduty:StopMonitoringMembers",
        "securityhub:DisableSecurityHub",
        "securityhub:DisassociateFromMasterAccount",
        "securityhub:DeleteMembers",
        "securityhub:BatchDisableStandards",
        "config:DeleteConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:StopConfigurationRecorder",
        "config:DeleteConfigRule",
        "config:PutConfigurationRecorder",
        "config:PutDeliveryChannel",
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "macie2:DisableMacie",
        "macie2:DisassociateFromAdministratorAccount",
        "inspector2:Disable",
        "inspector2:DisassociateMember",
        "detective:DeleteGraph",
        "access-analyzer:DeleteAnalyzer"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalARN": [
            "arn:aws:iam::*:role/OrganizationAccountAccessRole",
            "arn:aws:iam::*:role/SecurityBreakGlassRole",
            "arn:aws:iam::*:role/aws-service-role/*"
          ]
        }
      }
    },
    {
      "Sid": "DenyTamperingWithTheLogArchive",
      "Effect": "Deny",
      "Action": [
        "s3:DeleteBucket",
        "s3:DeleteBucketPolicy",
        "s3:PutBucketPolicy",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketVersioning",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": [
        "arn:aws:s3:::security-logs-*",
        "arn:aws:s3:::security-logs-*/*"
      ],
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalARN": "arn:aws:iam::*:role/SecurityBreakGlassRole"
        }
      }
    },
    {
      "Sid": "DenyDisablingOrDeletingTheLogArchiveKey",
      "Effect": "Deny",
      "Action": [
        "kms:ScheduleKeyDeletion",
        "kms:DisableKey",
        "kms:DisableKeyRotation",
        "kms:PutKeyPolicy"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Purpose": "security-log-archive"
        }
      }
    },
    {
      "Sid": "RequireEncryptionInTransitForS3",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    },
    {
      "Sid": "DenyUnencryptedEbsVolumeCreation",
      "Effect": "Deny",
      "Action": "ec2:CreateVolume",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "ec2:Encrypted": "false"
        }
      }
    }
  ]
}
```

> **Las SCPs nunca otorgan permiso.** Establecen el permiso máximo disponible para las cuentas de la OU. Una acción se permite solo si está autorizada *tanto* por la SCP *como* por una política de identidad/recurso. Las SCPs no aplican a la **cuenta de gestión** — que es la razón arquitectónica por la que no corrés cargas de trabajo ahí.

---

## 6. Recorrido por la CLI

### 6.1 Desplegar y confirmar la línea base

```console
$ aws cloudformation deploy \
    --template-file security-baseline.yaml \
    --stack-name security-baseline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        OrganizationId=o-a1b2c3d4e5 \
        SecurityContactEmail=secops@example.com \
    --region us-east-1

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - security-baseline
```

```console
$ aws cloudformation describe-stacks \
    --stack-name security-baseline \
    --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
    --output table

--------------------------------------------------------------------------------
|                               DescribeStacks                                 |
+-----------------------+------------------------------------------------------+
|          Key          |                        Value                         |
+-----------------------+------------------------------------------------------+
|  LogArchiveBucket     |  security-logs-111122223333-us-east-1                |
|  LogArchiveKeyArn     |  arn:aws:kms:us-east-1:111122223333:key/3f2c8e1a-... |
|  GuardDutyDetectorId  |  d4bc1a2f9e8746d3b0f5c7a19e2d4b60                    |
|  SecurityAlertsTopic  |  arn:aws:sns:us-east-1:111122223333:security-crit... |
+-----------------------+------------------------------------------------------+
```

### 6.2 CloudTrail — ¿está realmente registrando, y el archivo está íntegro?

```console
$ aws cloudtrail get-trail-status --name org-security-trail \
    --query '{Logging:IsLogging,LastDelivery:LatestDeliveryTime,DeliveryError:LatestDeliveryError,DigestDelivery:LatestDigestDeliveryTime}'
{
    "Logging": true,
    "LastDelivery": "2026-09-04T14:18:07.412000+00:00",
    "DeliveryError": null,
    "DigestDelivery": "2026-09-04T14:00:11.883000+00:00"
}
```

`DeliveryError` es el campo que importa. Un trail con `IsLogging: true` y un `LatestDeliveryError` no nulo está produciendo **nada** — casi siempre un problema de política de bucket de S3 o de política de clave de KMS.

Verificar la integridad criptográfica del archivo (esto requiere `EnableLogFileValidation: true` al crear el trail — no puede aplicarse retroactivamente):

```console
$ aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:us-east-1:111122223333:trail/org-security-trail \
    --start-time 2026-09-01T00:00:00Z \
    --region us-east-1

Validating log files for trail arn:aws:cloudtrail:us-east-1:111122223333:trail/org-security-trail between 2026-09-01T00:00:00Z and 2026-09-04T14:22:31Z

Results requested for 2026-09-01T00:00:00Z to 2026-09-04T14:22:31Z
Results found for 2026-09-01T00:00:00Z to 2026-09-04T14:22:31Z:

3/3 digest files valid
412/412 log files valid
```

Averiguar quién borró un bucket, directamente desde el Event history:

```console
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteBucket \
    --start-time 2026-09-03T00:00:00Z \
    --max-results 5 \
    --query 'Events[].{Time:EventTime,User:Username,Resource:Resources[0].ResourceName}' \
    --output table

------------------------------------------------------------------------------
|                                LookupEvents                                |
+----------------------------+----------------+------------------------------+
|            Time            |      User      |          Resource            |
+----------------------------+----------------+------------------------------+
|  2026-09-03T09:41:22+00:00 |  ci-deployer   |  legacy-artifacts-staging    |
+----------------------------+----------------+------------------------------+
```

### 6.3 GuardDuty — habilitación, cobertura, hallazgos

```console
$ aws guardduty list-detectors
{
    "DetectorIds": [
        "d4bc1a2f9e8746d3b0f5c7a19e2d4b60"
    ]
}

$ aws guardduty get-detector --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --query '{Status:Status,Frequency:FindingPublishingFrequency,Features:Features[].{Name:Name,Status:Status}}'
{
    "Status": "ENABLED",
    "Frequency": "FIFTEEN_MINUTES",
    "Features": [
        { "Name": "S3_DATA_EVENTS",         "Status": "ENABLED" },
        { "Name": "EKS_AUDIT_LOGS",         "Status": "ENABLED" },
        { "Name": "EBS_MALWARE_PROTECTION", "Status": "ENABLED" },
        { "Name": "RDS_LOGIN_EVENTS",       "Status": "ENABLED" },
        { "Name": "LAMBDA_NETWORK_LOGS",    "Status": "ENABLED" },
        { "Name": "RUNTIME_MONITORING",     "Status": "ENABLED" }
    ]
}
```

Generar hallazgos de muestra para validar toda la cadena de alertas **antes** de un incidente real:

```console
$ aws guardduty create-sample-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-types \
        UnauthorizedAccess:EC2/SSHBruteForce \
        CryptoCurrency:EC2/BitcoinTool.B!DNS \
        Exfiltration:S3/AnomalousBehavior
```

```console
$ aws guardduty list-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-criteria '{"Criterion":{"severity":{"Gte":7},"service.archived":{"Eq":["false"]}}}' \
    --query 'FindingIds' --output text | tr '\t' '\n' | head -3
1cc4a1e2f0b93d7a5e8c6b4f2a91d073
7ab3f9c5d2e1408b6c3a7f9e5d1b2c48
0e5d8a4b7c2f316d9a0e4b8c5f7a2d19

$ aws guardduty get-findings \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --finding-ids 1cc4a1e2f0b93d7a5e8c6b4f2a91d073 \
    --query 'Findings[0].{Type:Type,Severity:Severity,Count:Service.Count,Resource:Resource.ResourceType,Instance:Resource.InstanceDetails.InstanceId,Actor:Service.Action.NetworkConnectionAction.RemoteIpDetails.IpAddressV4,Country:Service.Action.NetworkConnectionAction.RemoteIpDetails.Country.CountryName,First:Service.EventFirstSeen,Last:Service.EventLastSeen}'
{
    "Type": "UnauthorizedAccess:EC2/SSHBruteForce",
    "Severity": 8,
    "Count": 47,
    "Resource": "Instance",
    "Instance": "i-0a1b2c3d4e5f60718",
    "Actor": "198.51.100.77",
    "Country": "Netherlands",
    "First": "2026-09-04T13:02:41.000Z",
    "Last": "2026-09-04T14:31:09.000Z"
}
```

Verificar la cobertura a nivel de toda la organización — la respuesta a "¿están las 40 cuentas realmente protegidas?":

```console
$ aws guardduty list-members --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --query 'Members[].{Account:AccountId,Status:RelationshipStatus,Email:Email}' --output table \
    | head -12

--------------------------------------------------------------------
|                           ListMembers                            |
+---------------+--------------+-----------------------------------+
|    Account    |    Status    |              Email                |
+---------------+--------------+-----------------------------------+
|  444455556666 |  Enabled     |  aws+prod-web@example.com         |
|  555566667777 |  Enabled     |  aws+prod-data@example.com        |
|  666677778888 |  Disabled    |  aws+sandbox-ml@example.com       |
+---------------+--------------+-----------------------------------+
```

`Disabled` en la cuenta `666677778888` es una brecha real. `auto-enable-organization-members` la cierra para las cuentas futuras:

```console
$ aws guardduty update-organization-configuration \
    --detector-id d4bc1a2f9e8746d3b0f5c7a19e2d4b60 \
    --auto-enable-organization-members ALL
```

### 6.4 Security Hub — postura de cumplimiento en un solo comando

```console
$ aws securityhub get-enabled-standards \
    --query 'StandardsSubscriptions[].{Standard:StandardsArn,Status:StandardsStatus}' --output table

-----------------------------------------------------------------------------------------------
|                                    GetEnabledStandards                                      |
+-------------------------------------------------------------------------+-------------------+
|                                Standard                                 |      Status       |
+-------------------------------------------------------------------------+-------------------+
|  arn:aws:securityhub:us-east-1::standards/aws-foundational-security-...  |  READY            |
|  arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-bench...   |  READY            |
+-------------------------------------------------------------------------+-------------------+
```

```console
$ aws securityhub get-findings \
    --filters '{
        "SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],
        "RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],
        "WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]
      }' \
    --max-results 5 \
    --query 'Findings[].{Account:AwsAccountId,Product:ProductName,Title:Title,Resource:Resources[0].Id}' \
    --output table

------------------------------------------------------------------------------------------------------
|                                            GetFindings                                             |
+--------------+---------------+--------------------------------------+------------------------------+
|   Account    |    Product    |                Title                 |          Resource            |
+--------------+---------------+--------------------------------------+------------------------------+
| 666677778888 | Security Hub  | S3 general purpose buckets should    | arn:aws:s3:::ml-scratch-2024 |
|              |               | block public read access             |                              |
| 444455556666 | Security Hub  | IAM root user access key should not  | AWS::::Account:444455556666  |
|              |               | exist                                |                              |
| 555566667777 | GuardDuty     | Credentials for the EC2 instance     | arn:aws:ec2:us-east-1:5555.. |
|              |               | role were used from a remote AWS acc.| ..:instance/i-0f3a9c...      |
+--------------+---------------+--------------------------------------+------------------------------+
```

La consulta de postura más útil de todas — los controles que están fallando en todo el estándar:

```console
$ aws securityhub describe-standards-controls \
    --standards-subscription-arn 'arn:aws:securityhub:us-east-1:111122223333:subscription/aws-foundational-security-best-practices/v/1.0.0' \
    --query 'Controls[?ControlStatus==`ENABLED`].{Id:ControlId,Severity:SeverityRating,Title:Title}' \
    --output text | wc -l
318
```

### 6.5 Controles de red — SGs, NACLs y Reachability Analyzer

Encontrar todos los security groups abiertos a internet en un puerto de gestión. Esta es la verificación que Trusted Advisor y el control FSBP `EC2.19` ejecutan por vos, pero hacerla a mano enseña la forma:

```console
$ aws ec2 describe-security-groups \
    --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
    --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId,Ports:IpPermissions[?contains(IpRanges[].CidrIp,`0.0.0.0/0`)].{From:FromPort,To:ToPort,Proto:IpProtocol}}' \
    --output json

[
    {
        "Id": "sg-0c9d2e1f8a7b34506",
        "Name": "sg-alb",
        "Vpc": "vpc-08f1a2b3c4d5e6f70",
        "Ports": [ { "From": 443, "To": 443, "Proto": "tcp" } ]
    },
    {
        "Id": "sg-04e7f1a9b2c8d3065",
        "Name": "legacy-jumpbox",
        "Vpc": "vpc-08f1a2b3c4d5e6f70",
        "Ports": [ { "From": 22, "To": 22, "Proto": "tcp" },
                   { "From": 3389, "To": 3389, "Proto": "tcp" } ]
    }
]
```

`sg-04e7f1a9b2c8d3065` es el hallazgo: SSH y RDP abiertos al mundo.

Probar que un camino está bloqueado sin generar tráfico — **VPC Reachability Analyzer** hace análisis simbólico de rutas, NACLs y SGs:

```console
$ aws ec2 create-network-insights-path \
    --source i-0a1b2c3d4e5f60718 \
    --destination i-0f3a9c8b7d6e5f402 \
    --protocol tcp --destination-port 5432 \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text
nip-0d8c1a2b3e4f5a6b7

$ aws ec2 start-network-insights-analysis \
    --network-insights-path-id nip-0d8c1a2b3e4f5a6b7 \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text
nia-071e2f3a4b5c6d7e8

$ aws ec2 describe-network-insights-analyses \
    --network-insights-analysis-ids nia-071e2f3a4b5c6d7e8 \
    --query 'NetworkInsightsAnalyses[0].{Status:Status,Reachable:NetworkPathFound,Blocker:Explanations[0].ExplanationCode,Component:Explanations[0].Acl.Id}'
{
    "Status": "succeeded",
    "Reachable": false,
    "Blocker": "ACL_RULE_DENY",
    "Component": "acl-06b2c3d4e5f7a8091"
}
```

`ACL_RULE_DENY` — la NACL, no el security group. Exactamente la falla que predice la distinción stateless/stateful.

### 6.6 WAF — ¿está la Web ACL asociada, y qué está bloqueando realmente?

```console
$ aws wafv2 list-web-acls --scope REGIONAL \
    --query 'WebACLs[].{Name:Name,Id:Id,Capacity:null}' --output table

------------------------------------------------------------------
|                          ListWebACLs                           |
+----------------------+-----------------------------------------+
|         Name         |                   Id                    |
+----------------------+-----------------------------------------+
|  prod-alb-protection |  6c1f2a3b-4d5e-6f70-8192-a3b4c5d6e7f8   |
+----------------------+-----------------------------------------+

$ aws wafv2 get-web-acl-for-resource \
    --resource-arn arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/prod-alb/9f8e7d6c5b4a3210 \
    --query 'WebACL.Name' --output text
prod-alb-protection
```

Si ese último comando no devuelve nada, la Web ACL existe pero **no protege nada** — el recurso de asociación es la pieza que la gente olvida.

Inspeccionar qué atrapó una regla, sin esperar a que aterricen los logs:

```console
$ aws wafv2 get-sampled-requests \
    --web-acl-arn arn:aws:wafv2:us-east-1:111122223333:regional/webacl/prod-alb-protection/6c1f2a3b-4d5e-6f70-8192-a3b4c5d6e7f8 \
    --rule-metric-name sqli \
    --scope REGIONAL \
    --time-window StartTime=2026-09-04T13:00:00Z,EndTime=2026-09-04T14:00:00Z \
    --max-items 2 \
    --query 'SampledRequests[].{Action:Action,URI:Request.URI,IP:Request.ClientIP,Country:Request.Country,Rule:RuleNameWithinRuleGroup}'

[
    {
        "Action": "BLOCK",
        "URI": "/api/v1/search",
        "IP": "203.0.113.44",
        "Country": "RU",
        "Rule": "SQLi_QUERYARGUMENTS"
    },
    {
        "Action": "BLOCK",
        "URI": "/api/v1/products",
        "IP": "203.0.113.44",
        "Country": "RU",
        "Rule": "SQLi_BODY"
    }
]
```

### 6.7 KMS — cifrado de sobre de punta a punta

```console
$ aws kms describe-key --key-id alias/security-logs \
    --query 'KeyMetadata.{Id:KeyId,State:KeyState,Manager:KeyManager,Spec:KeySpec,Usage:KeyUsage,Origin:Origin,MultiRegion:MultiRegion}'
{
    "Id": "3f2c8e1a-7b94-4d05-a2c6-1e8f0b3d9a47",
    "State": "Enabled",
    "Manager": "CUSTOMER",
    "Spec": "SYMMETRIC_DEFAULT",
    "Usage": "ENCRYPT_DECRYPT",
    "Origin": "AWS_KMS",
    "MultiRegion": false
}

$ aws kms get-key-rotation-status --key-id alias/security-logs
{
    "KeyRotationEnabled": true,
    "KeyId": "arn:aws:kms:us-east-1:111122223333:key/3f2c8e1a-7b94-4d05-a2c6-1e8f0b3d9a47",
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-06-14T09:11:52.000000+00:00"
}
```

El sobre, a mano:

```console
$ aws kms generate-data-key --key-id alias/security-logs --key-spec AES_256 \
    --query '{Plaintext:Plaintext,Ciphertext:CiphertextBlob}' --output json > dek.json

$ jq -r .Plaintext dek.json | base64 -d > /dev/shm/dek.bin
$ ls -l /dev/shm/dek.bin
-rw-------. 1 sre sre 32 Sep  4 14:41 /dev/shm/dek.bin      # 32 bytes = AES-256

$ openssl enc -aes-256-cbc -pbkdf2 -in report.pdf -out report.pdf.enc \
    -pass file:/dev/shm/dek.bin
$ shred -u /dev/shm/dek.bin        # the plaintext DEK must not survive

# Later, to read it back — only the encrypted DEK was ever stored:
$ jq -r .Ciphertext dek.json | base64 -d > dek.enc
$ aws kms decrypt --ciphertext-blob fileb://dek.enc \
    --key-id alias/security-logs \
    --query Plaintext --output text | base64 -d > /dev/shm/dek.bin
$ openssl enc -d -aes-256-cbc -pbkdf2 -in report.pdf.enc -out report.pdf \
    -pass file:/dev/shm/dek.bin
```

Notá que `report.pdf` nunca fue a AWS. Solo lo hizo la clave de 32 bytes.

### 6.8 Inspector, Macie y Access Analyzer

```console
$ aws inspector2 batch-get-account-status \
    --query 'accounts[0].resourceState.{EC2:ec2.status,ECR:ecr.status,Lambda:lambda.status,LambdaCode:lambdaCode.status}'
{
    "EC2": "ENABLED",
    "ECR": "ENABLED",
    "Lambda": "ENABLED",
    "LambdaCode": "ENABLED"
}

$ aws inspector2 list-findings \
    --filter-criteria '{"severity":[{"comparison":"EQUALS","value":"CRITICAL"}],"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' \
    --max-results 3 \
    --query 'findings[].{CVE:packageVulnerabilityDetails.vulnerabilityId,Score:inspectorScore,Resource:resources[0].id,Package:packageVulnerabilityDetails.vulnerablePackages[0].name,Fixed:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion}' \
    --output table

------------------------------------------------------------------------------------------
|                                      ListFindings                                      |
+----------------+-------+----------------------------+-----------------+----------------+
|      CVE       | Score |          Resource          |     Package     |     Fixed      |
+----------------+-------+----------------------------+-----------------+----------------+
| CVE-2021-44228 |  10.0 | i-0a1b2c3d4e5f60718        | log4j-core      | 2.17.1         |
| CVE-2024-3094  |  10.0 | i-0f3a9c8b7d6e5f402        | xz-libs         | 5.4.6-1.el9_4  |
| CVE-2023-44487 |   7.5 | sha256:9f2a1b0c3d4e5f6a... | nghttp2         | 1.55.1         |
+----------------+-------+----------------------------+-----------------+----------------+
```

```console
$ aws macie2 get-macie-session --query '{Status:status,Frequency:findingPublishingFrequency}'
{
    "Status": "ENABLED",
    "Frequency": "FIFTEEN_MINUTES"
}

$ aws macie2 list-findings \
    --finding-criteria '{"criterion":{"severity.description":{"eq":["High"]},"archived":{"eq":["false"]}}}' \
    --max-results 2 --query 'findingIds' --output text
2b7e1a9c4f0d38e5a6b7c8d9e0f1a2b3	8d4c3b2a1f0e9d8c7b6a5e4f3d2c1b0a

$ aws macie2 get-findings --finding-ids 2b7e1a9c4f0d38e5a6b7c8d9e0f1a2b3 \
    --query 'findings[0].{Type:type,Bucket:resourcesAffected.s3Bucket.name,Object:resourcesAffected.s3Object.key,Public:resourcesAffected.s3Bucket.publicAccess.effectivePermission,Data:classificationDetails.result.sensitiveData[].category}'
{
    "Type": "SensitiveData:S3Object/Personal",
    "Bucket": "ml-scratch-2024",
    "Object": "exports/customers_full_dump.csv",
    "Public": "PUBLIC",
    "Data": [ "PERSONAL_INFORMATION", "FINANCIAL_INFORMATION" ]
}
```

Esa única salida es una brecha de datos reportable: datos sensibles más permiso efectivo `PUBLIC`.

```console
$ aws accessanalyzer list-findings \
    --analyzer-arn arn:aws:access-analyzer:us-east-1:111122223333:analyzer/org-external-access \
    --filter '{"status":{"eq":["ACTIVE"]},"isPublic":{"eq":["true"]}}' \
    --query 'findings[].{Resource:resource,Type:resourceType,Principal:principal,Actions:action}' \
    --output table

-----------------------------------------------------------------------------------------
|                                     ListFindings                                      |
+-------------------------------+-----------------+-------------+-----------------------+
|           Resource            |      Type       |  Principal  |        Actions        |
+-------------------------------+-----------------+-------------+-----------------------+
| arn:aws:s3:::ml-scratch-2024  | AWS::S3::Bucket | {"AWS":"*"} | s3:GetObject          |
+-------------------------------+-----------------+-------------+-----------------------+
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 La lista de comprobación previa al vuelo

Ejecutá esto antes de declarar la línea base "terminada". Es un único script; cada línea es una afirmación que podés demostrar.

```bash
#!/usr/bin/env bash
# verify-security-baseline.sh — exits non-zero if any control is not effective.
set -uo pipefail
FAIL=0
REGION="${AWS_REGION:-us-east-1}"
note() { printf '%-46s %s\n' "$1" "$2"; }
bad()  { note "$1" "FAIL: $2"; FAIL=1; }

# 1. CloudTrail is logging AND delivering.
read -r LOGGING ERR < <(aws cloudtrail get-trail-status --name org-security-trail \
  --query '[IsLogging, LatestDeliveryError]' --output text 2>/dev/null)
[[ "$LOGGING" == "True" ]] || bad "cloudtrail.logging" "IsLogging=$LOGGING"
[[ "$ERR" == "None" ]]     || bad "cloudtrail.delivery" "$ERR"
[[ "$LOGGING" == "True" && "$ERR" == "None" ]] && note "cloudtrail.logging+delivery" "OK"

# 2. The trail is multi-region and org-wide, with log-file validation.
read -r MR ORG LFV < <(aws cloudtrail describe-trails --trail-name-list org-security-trail \
  --query 'trailList[0].[IsMultiRegionTrail,IsOrganizationTrail,LogFileValidationEnabled]' --output text)
[[ "$MR$ORG$LFV" == "TrueTrueTrue" ]] \
  && note "cloudtrail.scope+validation" "OK" \
  || bad "cloudtrail.scope+validation" "multiregion=$MR org=$ORG validation=$LFV"

# 3. Config is RECORDING, not merely configured.
REC=$(aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].recording' --output text 2>/dev/null)
[[ "$REC" == "True" ]] && note "config.recording" "OK" || bad "config.recording" "recording=$REC"

# 4. GuardDuty detector exists and is enabled.
DET=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)
if [[ "$DET" == "None" || -z "$DET" ]]; then
  bad "guardduty.detector" "no detector in $REGION"
else
  ST=$(aws guardduty get-detector --detector-id "$DET" --query Status --output text)
  [[ "$ST" == "ENABLED" ]] && note "guardduty.detector" "OK ($DET)" || bad "guardduty.detector" "$ST"
fi

# 5. Security Hub is on and has at least one READY standard.
RDY=$(aws securityhub get-enabled-standards \
  --query 'length(StandardsSubscriptions[?StandardsStatus==`READY`])' --output text 2>/dev/null)
[[ "${RDY:-0}" -ge 1 ]] && note "securityhub.standards" "OK ($RDY ready)" \
                        || bad "securityhub.standards" "ready=${RDY:-0}"

# 6. No security group exposes SSH or RDP to the internet.
OPEN=$(aws ec2 describe-security-groups \
  --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
  --query 'length(SecurityGroups[?IpPermissions[?(FromPort==`22`||FromPort==`3389`) && contains(IpRanges[].CidrIp,`0.0.0.0/0`)]])' \
  --output text)
[[ "$OPEN" == "0" ]] && note "ec2.no-open-admin-ports" "OK" \
                     || bad "ec2.no-open-admin-ports" "$OPEN group(s) open"

# 7. The root user has no access keys (CIS 1.4 / FSBP IAM.4).
KEYS=$(aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent' --output text)
[[ "$KEYS" == "0" ]] && note "iam.root-no-access-keys" "OK" || bad "iam.root-no-access-keys" "present"

# 8. EBS encryption by default is on for this region.
EBS=$(aws ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault --output text)
[[ "$EBS" == "True" ]] && note "ec2.ebs-default-encryption" "OK" || bad "ec2.ebs-default-encryption" "off"

exit "$FAIL"
```

```console
$ ./verify-security-baseline.sh
cloudtrail.logging+delivery                    OK
cloudtrail.scope+validation                    OK
config.recording                               OK
guardduty.detector                             OK (d4bc1a2f9e8746d3b0f5c7a19e2d4b60)
securityhub.standards                          OK (2 ready)
ec2.no-open-admin-ports                        FAIL: 1 group(s) open
iam.root-no-access-keys                        OK
ec2.ebs-default-encryption                     FAIL: off
$ echo $?
1
```

### 7.2 Catálogo de fallas

| # | Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|---|
| 1 | Security Hub muestra un puntaje de cumplimiento alto pero casi ningún control evaluado | El grabador de Config no está corriendo en esa región → los controles devuelven `NO_DATA`, que se excluye del denominador del puntaje | `aws configservice describe-configuration-recorder-status` → `recording: false` | Iniciar el grabador; desplegar el StackSet de Config en todas las regiones habilitadas |
| 2 | El trail dice `IsLogging: true` pero el prefijo de S3 está vacío | A la política del bucket le falta el prefijo con el ID de organización (`AWSLogs/o-xxxx/*`) o la condición `aws:SourceArn` no coincide con el ARN del trail | `get-trail-status` → `LatestDeliveryError: "InsufficientBucketPolicy"` | Agregar ambos recursos, `AWSLogs/${AccountId}/*` y `AWSLogs/${OrgId}/*` |
| 3 | Igual que #2 pero el error es `KMS.KMSInvalidStateException` / `AccessDenied` | A la política de clave de KMS le falta el permiso `kms:GenerateDataKey*` para `cloudtrail.amazonaws.com`, o la condición de contexto de cifrado no coincide | Leer `LatestDeliveryError` textualmente | Agregar la sentencia `AllowCloudTrailToEncryptLogs` con la condición `kms:EncryptionContext:aws:cloudtrail:arn` |
| 4 | Nadie puede usar una clave de KMS, ni siquiera el administrador de la cuenta | La política de clave no tiene ninguna sentencia que otorgue `kms:*` al root de la cuenta, así que las políticas de IAM no pueden delegar | `aws kms get-key-policy --policy-name default` no muestra ningún principal root | **No podés arreglar esto vos mismo.** Abrí un caso con AWS Support. Prevenilo: incluí siempre `EnableIAMPoliciesInThisAccount` |
| 5 | La app es inalcanzable; los security groups se ven correctos | La NACL no tiene estado y falta la regla de *retorno* para el puerto efímero | Reachability Analyzer → `ACL_RULE_DENY`; los flow logs muestran `REJECT` en puertos de origen altos | Permitir `1024–65535` en la dirección de retorno |
| 6 | La Web ACL de WAF existe, no bloquea nada | Nunca se creó `AWS::WAFv2::WebACLAssociation`, o la Web ACL se creó con `Scope: REGIONAL` para una distribución de CloudFront | `aws wafv2 get-web-acl-for-resource --resource-arn ...` devuelve vacío | Crear la asociación; para CloudFront usar `Scope: CLOUDFRONT` **en us-east-1** |
| 7 | Los logs de WAF muestran `COUNT`, nunca `BLOCK`, para un grupo de reglas gestionadas | El `OverrideAction` del grupo de reglas es `Count: {}` — la anulación de conteo aplica a *todas* las reglas dentro del grupo | `get-web-acl` → `OverrideAction: {"Count":{}}` | Cambiar a `OverrideAction: {"None":{}}` una vez que hayás validado la tasa de falsos positivos |
| 8 | GuardDuty está "activo" pero no produjo nada durante un incidente real | Detector habilitado solo en una región; el ataque golpeó otra | `for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do aws guardduty list-detectors --region $r; done` | Habilitarlo a nivel de organización con `--auto-enable-organization-members ALL` en **todas** las regiones, incluidas las que no se usan |
| 9 | Las cuentas nuevas se suman a la organización sin servicios de seguridad | No se configuró `auto-enable` para GuardDuty / Security Hub / Config / Firewall Manager | Comparar `list-members` contra `organizations list-accounts` | Activar auto-enable en cada servicio, más una línea base de Control Tower / StackSet |
| 10 | Inspector reporta cero hallazgos de EC2 en instancias en ejecución | El agente SSM no está corriendo, o el perfil de instancia carece de `AmazonSSMManagedInstanceCore`, así que la instancia no es un nodo gestionado | `aws ssm describe-instance-information` — la instancia no aparece | Adjuntar la política gestionada, asegurar que el agente corra, o habilitar el escaneo sin agente |
| 11 | Un administrador de cuenta apagó CloudTrail antes de hacer daño | Ninguna SCP protegiendo el plano de detección | `cloudtrail:StopLogging` aparece en el trail de organización (registrado por el trail de organización antes de detenerse) | Aplicar la SCP de §5.4; mantener el archivo de logs en una cuenta separada con S3 Object Lock |
| 12 | Shield Advanced está suscripto pero un recurso igual recibió un golpe fuerte | El recurso nunca se agregó a una protección; Shield Advanced es por recurso protegido | `aws shield list-protections` | `aws shield create-protection`, o usar Firewall Manager para auto-proteger por etiqueta |
| 13 | La rotación de Secrets Manager "tiene éxito" pero la app se rompe | La rotación avanzó `AWSCURRENT` mientras la app tenía en caché el valor viejo; sin soporte del contrato de rotación de cuatro etapas | Los logs de la aplicación muestran fallas de autenticación ~un intervalo de rotación después de un período saludable | Obtener los secretos en el momento de conectar, respetar `AWSPENDING`/`AWSPREVIOUS`, probar con `rotate-secret --rotate-immediately` |

### 7.3 Barrido de regiones — la brecha que atrapa a todo el mundo

```console
$ for R in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
>   D=$(aws guardduty list-detectors --region "$R" --query 'DetectorIds[0]' --output text 2>/dev/null)
>   printf '%-16s %s\n' "$R" "${D:-none}"
> done | grep -E 'None|none'

ap-northeast-3   None
ap-south-2       None
eu-south-2       None
```

Tres regiones sin detector. Un atacante que asuma un rol en tu cuenta puede levantar recursos en *cualquier* región habilitada. **O habilitás detección en todas partes, o deshabilitás las regiones que no usás** (Configuración de la cuenta → Regiones, o una SCP con `aws:RequestedRegion`).

---

## 8. Dónde encontrar información de seguridad de AWS

Esta es una parte explícitamente evaluable de la tarea 2.4 — el examen pregunta *dónde mirás*, no solo *qué servicio usás*.

| Recurso | Qué te da | Cuándo recurrir a él |
|---|---|---|
| **AWS Trust Center** (`aws.amazon.com/trust-center/`) | Centro neurálgico de la postura de seguridad, privacidad y cumplimiento de AWS; reemplaza la vieja página de Cloud Security | Responder un cuestionario de un cliente/auditor |
| **AWS Security Bulletins** (`aws.amazon.com/security/security-bulletins/`) | Avisos de CVE que afectan a servicios de AWS, con la evaluación de AWS y la acción requerida del cliente | Aparece un CVE y tenés que saber si estás afectado |
| **AWS Security Blog** (`aws.amazon.com/blogs/security/`) | Artículos técnicos en profundidad, anuncios de funcionalidades nuevas, patrones de referencia | Diseñar un control; aprender un servicio nuevo |
| **AWS Knowledge Center** (`repost.aws/knowledge-center`) | Respuestas curadas a las preguntas de soporte más comunes | "¿Por qué mi CloudTrail dice InsufficientBucketPolicy?" |
| **AWS re:Post** (`repost.aws`) | Comunidad de preguntas y respuestas gestionada por AWS | Respuestas de pares/empleados de AWS cuando la documentación no alcanza |
| **AWS Artifact** (consola) | Descarga bajo demanda de los informes de auditoría de AWS (SOC 1/2/3, ISO 27001/27017/27018, PCI DSS AoC, FedRAMP) y acuerdos legales (BAA, informes protegidos por NDA) | Un auditor pide evidencia de los controles *de AWS* |
| **AWS Compliance Programs** (`aws.amazon.com/compliance/programs/`) | Qué certificaciones tiene AWS, por región y por servicio | Delimitar el alcance de una carga de trabajo regulada |
| **AWS Security Reference Architecture (SRA)** (`docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/`) | La estructura canónica de cuentas de seguridad multi-cuenta, con código desplegable | Diseño de landing zone desde cero |
| **AWS Well-Architected Framework — Pilar de Seguridad** | Principios de diseño y un proceso de revisión | Revisión formal de arquitectura |
| **AWS Marketplace** (`aws.amazon.com/marketplace`) | Productos de seguridad **de terceros**: firewalls de nueva generación, grupos de reglas gestionadas de WAF, CSPM, SIEM, EDR, escáneres de vulnerabilidades. Facturados en tu factura de AWS, desplegables como AMIs, contenedores, SaaS o Professional Services; admite ofertas privadas y descuento de gasto del Enterprise Discount Program | Necesitás un control de un proveedor que AWS no ofrece, y lo querés en una sola factura |
| **AWS Customer Support / Shield Response Team (SRT)** | El SRT es asistencia de ingeniería DDoS 24×7, **solo Shield Advanced** | Bajo ataque DDoS activo |
| **AWS Security Incident Response** (servicio) | Respuesta a incidentes gestionada 24×7 con el AWS Customer Incident Response Team (CIRT), triaje automatizado de hallazgos de GuardDuty/Security Hub, gestión de casos | No tenés un equipo de IR interno |
| **Equipo de abuso de AWS** (`abuse@amazonaws.com`, o el formulario de reporte) | Reportar recursos de AWS que se están usando para atacarte: spam, escaneos de puertos, DDoS, malware alojado, intentos de intrusión | Una instancia EC2 que no es tuya te está atacando |
| **Reporte de vulnerabilidades de AWS** (`aws-security@amazon.com`) | Reportar una vulnerabilidad **en AWS mismo** | Encontraste una falla en un servicio de AWS |
| **AWS Customer Support Policy for Penetration Testing** | Lista las 8+ categorías de servicios que podés someter a pentest **sin aprobación previa**; otras pruebas, y **todas las de DDoS simulado / pruebas de estrés**, requieren autorización previa | Antes de ejecutar un ejercicio de red team |

> **La distinción abuso-vs-vulnerabilidad es evaluable.** Abuso = alguien está usando indebidamente recursos de AWS *contra* vos → equipo de Trust & Safety / abuso de AWS. Vulnerabilidad = una falla de seguridad *en AWS* → `aws-security@amazon.com`. Una falla en *tu propia* aplicación es enteramente tuya bajo el modelo de responsabilidad compartida.

---

## 9. Matriz de recuerdo rápido

| Si la pregunta dice… | La respuesta es |
|---|---|
| "Monitorear continuamente en busca de actividad maliciosa y comportamiento no autorizado" | **Amazon GuardDuty** |
| "Escanear instancias EC2 e imágenes de contenedor en busca de vulnerabilidades de software (CVEs)" | **Amazon Inspector** |
| "Descubrir y clasificar datos sensibles como PII en S3" | **Amazon Macie** |
| "Analizar e investigar la causa raíz de un hallazgo de seguridad" | **Amazon Detective** |
| "Panel único; agregar hallazgos y verificar el cumplimiento contra CIS/PCI" | **AWS Security Hub** |
| "Registrar un historial completo de cambios de configuración; evaluar contra reglas" | **AWS Config** |
| "¿Quién hizo esta llamada a la API, cuándo, y desde qué IP?" | **AWS CloudTrail** |
| "Proteger una aplicación web contra inyección SQL y cross-site scripting" | **AWS WAF** |
| "Protección automática y sin costo contra DDoS común de capa de red/transporte" | **AWS Shield Standard** |
| "Equipo de respuesta DDoS 24/7 y reembolsos por costos de escalado provocados por un ataque" | **AWS Shield Advanced** |
| "Firewall con estado e IDS/IPS para el tráfico que entra y sale de una VPC" | **AWS Network Firewall** |
| "Configurar centralmente reglas de WAF/Shield/SG en todas las cuentas de la organización" | **AWS Firewall Manager** |
| "Firewall virtual con estado, a nivel de instancia" | **Security group** |
| "Filtro sin estado a nivel de subred que admite deny explícito" | **Network ACL** |
| "Crear y controlar claves de cifrado; integrado con la mayoría de los servicios de AWS" | **AWS KMS** |
| "Módulo de seguridad de hardware dedicado, single-tenant, bajo mi control exclusivo" | **AWS CloudHSM** |
| "Aprovisionar, gestionar y auto-renovar certificados TLS públicos sin costo" | **AWS Certificate Manager** |
| "Almacenar credenciales de base de datos con rotación automática" | **AWS Secrets Manager** |
| "Almacenar parámetros de configuración y secretos, sin rotación, bajo costo" | **SSM Parameter Store** |
| "¿Qué recursos están compartidos fuera de mi cuenta/organización?" | **IAM Access Analyzer** |
| "Verificaciones de buenas prácticas incluyendo seguridad, costo y cuotas de servicio" | **AWS Trusted Advisor** |
| "Descargar el informe SOC 2 de AWS o firmar un BAA" | **AWS Artifact** |
| "Recolectar evidencia continuamente y mapearla a un marco de cumplimiento" | **AWS Audit Manager** |
| "Comprar un firewall o SIEM de terceros facturado a través de AWS" | **AWS Marketplace** |
| "Reportar una instancia EC2 que ataca mi red" | **AWS Abuse / Trust & Safety** |
| "Impedir que cualquier cuenta de la OU deshabilite CloudTrail" | **Service Control Policy (SCP)** |

---

## 10. Nota sobre costos

Cada cifra en dólares de este documento es un **precio de lista de us-east-1 redondeado al momento de escribir**, dado únicamente para razonar en órdenes de magnitud. Los precios de AWS cambian, son escalonados y varían por región. Validá contra `https://aws.amazon.com/<service>/pricing/` y la AWS Pricing Calculator antes de comprometerte con nada de esto. Las dos cifras que vale la pena internalizar porque cambian decisiones de arquitectura:

- **Shield Advanced cuesta ~$3.000/mes por organización con un compromiso de 1 año.** No es algo que habilites a la ligera.
- **Los eventos de datos de CloudTrail y S3 Protection de GuardDuty escalan con el volumen de peticiones, no con la cantidad de recursos.** Una sola aplicación habladora puede mover a ambos de decenas de dólares a miles.

---

## Referencias

**Examen y certificación**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Detección y gestión de la postura**
- Amazon GuardDuty User Guide — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- GuardDuty finding types — https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html
- Amazon Inspector User Guide — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie User Guide — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective Administration Guide — https://docs.aws.amazon.com/detective/latest/adminguide/what-is-detective.html
- AWS Security Hub User Guide — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Foundational Security Best Practices standard — https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html
- AWS Security Finding Format (ASFF) — https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-findings-format.html

**Auditoría, configuración y gobernanza**
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Validating CloudTrail log file integrity — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- AWS Config Developer Guide — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
- AWS Audit Manager User Guide — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- Service Control Policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html

**Protección de red**
- Security groups for your VPC — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- Control subnet traffic with network ACLs — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- AWS WAF Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html
- AWS Managed Rules rule groups — https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html
- AWS Shield Developer Guide — https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html
- AWS Network Firewall Developer Guide — https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
- AWS Firewall Manager — https://docs.aws.amazon.com/waf/latest/developerguide/fms-chapter.html
- VPC Reachability Analyzer — https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html
- VPC Flow Logs — https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html

**Protección de datos**
- AWS KMS Developer Guide — https://docs.aws.amazon.com/kms/latest/developerguide/overview.html
- KMS envelope encryption — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#enveloping
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- AWS CloudHSM User Guide — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- AWS Certificate Manager User Guide — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- SSM Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html

**Información de seguridad y respuesta**
- AWS Trust Center — https://aws.amazon.com/trust-center/
- AWS Security Bulletins — https://aws.amazon.com/security/security-bulletins/
- AWS Security Blog — https://aws.amazon.com/blogs/security/
- AWS Knowledge Center (re:Post) — https://repost.aws/knowledge-center
- AWS Security Reference Architecture — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html
- AWS Well-Architected Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Security Incident Response — https://docs.aws.amazon.com/security-ir/latest/userguide/what-is-security-ir.html
- Customer Support Policy for Penetration Testing — https://aws.amazon.com/security/penetration-testing/
- Reporting abuse of AWS resources — https://support.aws.amazon.com/#/contacts/report-abuse
- Vulnerability reporting — https://aws.amazon.com/security/vulnerability-reporting/
- AWS Marketplace security category — https://aws.amazon.com/marketplace/solutions/security

**Referencias de infraestructura como código**
- `AWS::GuardDuty::Detector` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-guardduty-detector.html
- `AWS::SecurityHub::Hub` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-securityhub-hub.html
- `AWS::CloudTrail::Trail` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-cloudtrail-trail.html
- `AWS::Config::ConfigurationRecorder` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-config-configurationrecorder.html
- `AWS::WAFv2::WebACL` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-wafv2-webacl.html
- `AWS::EC2::NetworkAclEntry` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ec2-networkaclentry.html