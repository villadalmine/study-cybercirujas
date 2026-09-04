# 2.2 — Conceptos de seguridad, gobernanza y cumplimiento en la nube de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0) · **Dominio 2: Seguridad y cumplimiento** · **Enunciado de tarea 2.2** · **Peso del dominio: 25% · esta tarea ≈ 7,5%**

---

## 1. El problema en producción: la gobernanza no escala por intención

### 1.1 El modo de fallo que este tema existe para prevenir

Pensá en un equipo de plataforma que opera 180 cuentas de AWS. Cada cuenta se crea a partir de un módulo de Terraform que adjunta un permission set de IAM bien revisado. Un martes a la tarde, alguien del equipo de datos hace esto en la cuenta `ml-research`:

```
$ aws s3api put-bucket-policy --bucket ml-feature-store-prod \
    --policy file://allow-partner.json
```

La política otorga `s3:GetObject` a `"Principal": "*"`. Esa persona tiene `AdministratorAccess` en esa cuenta —legítimamente, porque es un sandbox—. Once minutos después, un dataset de entrenamiento que contiene PII de clientes queda legible por todo el mundo.

Nada en la cuenta estaba mal configurado respecto de su propio modelo de IAM. La identidad tenía el permiso. El control que faltaba *no es un control de identidad*: es un **invariante organizacional**: "ningún principal, en ninguna cuenta, jamás, puede hacer que un bucket de S3 sea legible públicamente". Ese invariante no puede vivir dentro de la cuenta, porque el administrador de la cuenta puede sacarlo.

Esta es la idea arquitectónica central del Dominio 2.2, y es lo que el examen realmente evalúa por debajo de los nombres de servicios:

> **La seguridad en una sola cuenta es un problema de identidad. La seguridad a lo largo de una organización es un problema del *plano de políticas*.** Necesitás controles que un administrador de cuenta comprometido o descuidado no pueda apagar, evidencia que un administrador comprometido no pueda falsificar, y cifrado cuyas claves un administrador comprometido no pueda exfiltrar.

Esos tres requisitos se corresponden exactamente con las tres familias de servicios de AWS de este enunciado de tarea:

| Requisito | Familia de control | Servicios representativos |
|---|---|---|
| Invariantes que el dueño de la cuenta no puede quitar | **Gobernanza preventiva** | AWS Organizations, SCPs, RCPs, políticas declarativas, AWS Control Tower, permissions boundaries |
| Registro a prueba de manipulación de lo que pasó | **Detectivo / auditoría** | CloudTrail (org trail + validación de archivos de log), AWS Config, Security Hub, GuardDuty, Inspector, Macie, Detective, Audit Manager, Security Lake |
| Datos ilegibles incluso con acceso al almacenamiento | **Criptográfico** | AWS KMS, CloudHSM, ACM, Secrets Manager, Nitro System / Nitro Enclaves |

### 1.2 Dónde cae la línea de responsabilidad compartida para la gobernanza

El Dominio 2.1 enseña el modelo de responsabilidad compartida; el 2.2 es donde lo *aplicás* al cumplimiento. La formulación operativamente útil:

| Capa | Quién | Consecuencia para el cumplimiento |
|---|---|---|
| Hardware, centros de datos, acceso físico, hipervisor (Nitro) | AWS | Vos **heredás** estos controles. No auditás el centro de datos; descargás el informe SOC 2 desde AWS Artifact y lo referenciás. |
| Parcheo de servicios administrados (S3, DynamoDB, runtime de Lambda, versiones menores del motor de RDS cuando auto-minor-upgrade está activo) | AWS | Heredado o **compartido** — vos seguís siendo dueño de la selección de versión y del fin de vida. |
| SO invitado, aplicación, identidades de IAM, ACLs de red, *configuración* del cifrado, clasificación de datos | Vos | Estos son los controles que prueba **tu** auditor. Es lo que cubren las reglas de Config, los estándares de Security Hub y la evidencia de Audit Manager. |

La frase relevante para el examen: **AWS cumple *de* la nube; vos tenés que demostrar cumplimiento *en* la nube.** Una atestación PCI DSS de AWS no hace que tu carga de trabajo cumpla PCI: hace que la infraestructura subyacente sea elegible para formar parte de una carga de trabajo que cumple.

---

## 2. El plano de control de gobernanza

### 2.1 AWS Organizations: la raíz de todo

AWS Organizations es el contenedor que hace posible cualquier otro control de gobernanza. Mecánicas clave que un arquitecto tiene que saber de memoria:

- Una **cuenta de administración** (antes "master"). Paga las facturas (facturación consolidada) y está **exenta de las SCPs**. Por eso la cuenta de administración no debe contener nada más que herramientas organizacionales: sin cargas de trabajo, sin datos. Un compromiso de la cuenta de administración no tiene límite.
- Las **unidades organizativas (OUs)** forman un árbol. Las políticas se adjuntan al Root, a una OU o a una cuenta, y se **heredan hacia abajo**.
- **Administrador delegado**: la mayoría de los servicios de seguridad (GuardDuty, Security Hub, Config, IAM Access Analyzer, Detective, Macie, CloudTrail) se pueden delegar a una cuenta dedicada de *Security Tooling*, de modo que la operación diaria no requiera credenciales de la cuenta de administración.
- La **facturación consolidada** agrega el uso para precios por volumen y comparte Reserved Instances / Savings Plans entre cuentas de forma predeterminada.

Una distribución canónica de OUs (es la estructura del whitepaper "Organizing Your AWS Environment" de AWS y aparece en las preguntas de escenario):

```
Root
├── Security          (Log Archive, Security Tooling)      ← delegated admins live here
├── Infrastructure    (Network, Shared Services)
├── Workloads
│   ├── Prod
│   └── NonProd
├── Sandbox           (loose SCPs, hard billing caps, no data)
├── PolicyStaging     (test new SCPs here before Root)
└── Suspended         (deny-all SCP for decommissioned accounts)
```

### 2.2 Tipos de política: qué frena realmente el `put-bucket-policy` malo

Esta es la parte más malinterpretada del dominio. Cinco mecanismos distintos restringen una solicitud, y se componen de maneras diferentes.

| Mecanismo | Se adjunta a | ¿Otorga acceso? | Se evalúa contra | ¿Le gana a un admin de cuenta? | Uso típico |
|---|---|---|---|---|---|
| **Política de identidad de IAM** | Usuario / grupo / rol | Sí | El principal | No — el admin puede editarla | Permisos del día a día |
| **Política de recurso** (bucket policy, key policy, política de SQS) | El recurso | Sí (incluido cross-account) | El recurso | No | Compartición entre cuentas, aplicación de `aws:SecureTransport` |
| **Permissions boundary** | Usuario/rol de IAM | No — solo limita | El principal | No (aunque un boundary puede protegerse de forma autorreferencial mediante una SCP) | Delegación segura de IAM a desarrolladores |
| **SCP (Service Control Policy)** | Root / OU / cuenta | **No — solo limita** | Todo principal *dentro de la cuenta miembro* | **Sí** | Invariantes de toda la organización: bloqueo de regiones, denegar el borrado de CloudTrail |
| **RCP (Resource Control Policy)** | Root / OU / cuenta | **No — solo limita** | Toda solicitud *hacia un recurso de la cuenta*, **incluidos principals externos** | **Sí** | "Ningún recurso de esta organización puede compartirse fuera de la organización" |

**Permiso efectivo = (política de identidad ∩ SCP ∩ boundary ∩ RCP) ∪ concesiones aplicables de políticas de recurso**, con cualquier **`Deny` explícito ganando incondicionalmente**.

Comportamientos críticos de las SCPs que generan distractores de examen e incidentes reales a las 3 de la mañana:

- Las SCPs **nunca otorgan** nada. Adjuntar `AdministratorAccess` como SCP no le da acceso a nadie; solo eleva el techo.
- Las SCPs **no aplican a la cuenta de administración** — nunca.
- Las SCPs **no aplican a los service-linked roles** (`AWSServiceRoleFor*`).
- La SCP predeterminada `FullAWSAccess` está adjunta en todos lados. Si adjuntás una SCP de lista de denegación, conservala; si pasás a una SCP de lista de permitidos, quitar `FullAWSAccess` es lo que hace que la lista de permitidos muerda — y también es la forma en que los equipos se dejan afuera a sí mismos.
- Las **RCPs** (resource control policies) cierran el hueco que dejan las SCPs: una SCP restringe a *tus* principals, pero una bucket policy que otorga acceso a una cuenta externa sigue funcionando. Las RCPs restringen el lado del recurso. En su lanzamiento, las RCPs soportan Amazon S3, AWS STS, Amazon SQS, AWS KMS y AWS Secrets Manager.
- Las **políticas declarativas** son un control más nuevo, a nivel de atributo de servicio (inicialmente Amazon EC2): fijan una *configuración deseada* —por ejemplo, IMDSv2 requerido, VPC Block Public Access, proveedores de AMI permitidos— que persiste incluso a medida que AWS agrega nuevas APIs, en lugar de enumerar acciones de API para denegar.

### 2.3 AWS Control Tower: el ensamblado opinado

Control Tower no es un plano de control nuevo; es una capa de orquestación que levanta Organizations + una cuenta Log Archive + una cuenta Audit + una configuración de IAM Identity Center + un catálogo curado de controles, y los mantiene verificados contra deriva.

| Tipo de control en Control Tower | Implementado como | Cuándo se dispara |
|---|---|---|
| **Preventivo** | SCP | Antes de que la llamada a la API tenga éxito — la solicitud se deniega |
| **Detectivo** | Regla de AWS Config | Después de que el recurso existe — hallazgo de no conformidad |
| **Proactivo** | CloudFormation Hook | Durante el despliegue del stack — antes de que se creen los recursos |

Tabla de compromisos para la decisión de "cómo levanto una landing zone":

| Enfoque | Tiempo hasta la primera cuenta gobernada | Flexibilidad | Gestión de deriva | Riesgo de lock-in | Ideal para |
|---|---|---|---|---|---|
| Control Tower + Account Factory | Horas | Media — controles curados, regiones protegidas | Detección de deriva y reinscripción integradas | Medio (el estado de inscripción es propiedad de CT) | La mayoría de las empresas, startups reguladas |
| Control Tower + Account Factory for Terraform (AFT) | Días | Alta — pipeline de personalización IaC | Deriva de CT + tu pipeline | Medio | Equipos de plataforma nativos en Terraform |
| Organizations puro + tu propio IaC (Terraform/CDK) | Días–semanas | Total | Lo construís vos | Bajo | Equipos con una plataforma existente y madura |
| Landing Zone Accelerator on AWS | Días | Alta, guiada por archivo de configuración | Gestionada por la solución | Medio | Entornos muy regulados (FedRAMP, DoD) |

### 2.4 El etiquetado como primitiva de gobernanza

Las etiquetas son la clave de unión entre seguridad, costo y operaciones. Dos mecanismos a nivel de organización:

- **Tag policies** (Organizations): imponen *mayúsculas/minúsculas y valores permitidos* para una clave de etiqueta. **No** obligan a que una etiqueta exista al momento de la creación — eso requiere una SCP con condiciones `aws:RequestTag`/`aws:TagKeys`, o una regla de Config (`required-tags`) para detección.
- **Control de acceso basado en atributos (ABAC)**: políticas de IAM condicionadas por `aws:PrincipalTag` frente a `aws:ResourceTag`, de modo que una sola política escala a N equipos.

---

## 3. Protección de datos: cifrado en reposo y en tránsito

### 3.1 Internals de KMS — cifrado de sobre

Tenés que entender *por qué* KMS devuelve dos cosas, porque eso explica todos los errores de permisos de KMS que vas a depurar en tu vida.

Las claves de KMS nunca salen del límite del HSM validado FIPS 140-3. Por eso KMS nunca cifra tu objeto de 4 TB; cifra una **clave de datos**:

```
GenerateDataKey(KeyId, KeySpec=AES_256)
   └─► { Plaintext:  <32 raw bytes>          ← used locally, then zeroized
         CiphertextBlob: <the same key, encrypted under the KMS key> }
```

El servicio (S3, EBS, RDS) cifra tus datos con la clave de datos en texto plano, la descarta de la memoria y guarda el `CiphertextBlob` junto al texto cifrado. Al leer, llama a `kms:Decrypt` con el blob para recuperar la clave de datos. Consecuencias:

1. **Rendimiento**: una llamada a KMS por objeto/volumen/snapshot, no por byte. Las **Bucket Keys** de S3 reducen esto todavía más, alrededor de un 99%, derivando una clave a nivel de bucket — crítico cuando llegás a la cuota de solicitudes de KMS (predeterminada de 5.500 a 50.000 req/s según la región y la especificación de clave).
2. **El control de acceso es `kms:Decrypt`, no ACLs a nivel de objeto.** Revocar el `kms:Decrypt` de un principal vuelve los datos ilegibles para él, aunque todavía tenga `s3:GetObject`. Este es el patrón de "trituración criptográfica".
3. **El contexto de cifrado** —un mapa clave/valor AAD— queda ligado al texto cifrado. Si no coincide al descifrar → `InvalidCiphertextException`. Los servicios lo configuran automáticamente (por ejemplo, `aws:cloudtrail:arn`).

### 3.2 Taxonomía de claves de KMS

| Tipo de clave | Quién es dueño de la política | Rotación | Visible en tu cuenta | Costo | Uso entre cuentas |
|---|---|---|---|---|---|
| **AWS owned** | AWS | Definida por AWS | No | $0 | No |
| **AWS managed** (`aws/s3`, `aws/ebs`, …) | AWS | Automática, cada año | Sí (política de solo lectura) | $0 por la clave; las llamadas a la API se facturan | No |
| **Customer managed (CMK)** | Vos | Opcional; predeterminado 365 d, configurable de 90 a 2560 d; rotación bajo demanda disponible | Sí | ~$1/clave/mes + $0,03 por cada 10k solicitudes | **Sí**, vía key policy |
| **Customer managed, custom key store (CloudHSM)** | Vos | Manual | Sí | Costo de la clave + del clúster CloudHSM | Sí |
| **Customer managed, external key store (XKS)** | Vos | Manual, externa | Sí | Clave + tu HSM | Sí |
| **Clave multirregión** | Vos | La réplica comparte el material de clave | Sí | Por réplica | Sí |

**La key policy es obligatoria y primaria.** A diferencia de casi cualquier otra política de recurso de AWS, una política de IAM por sí sola no puede otorgar acceso a KMS: la key policy tiene que delegar en IAM (`"Principal": {"AWS": "arn:aws:iam::111122223333:root"}` + `kms:*`) o nombrar al principal directamente. Borrar una clave es una operación **programada** con un período de espera de 7 a 30 días, y es irreversible: el texto cifrado queda permanentemente ilegible.

### 3.3 KMS frente a CloudHSM

| Dimensión | AWS KMS | AWS CloudHSM |
|---|---|---|
| Tenencia | Multi-tenant, flota de HSM administrada por AWS | Clúster HSM de un solo tenant en tu VPC |
| Validación FIPS | 140-3 Level 3 (módulos HSM de un solo tenant) | FIPS 140-3 Level 3 |
| Quién puede acceder a las claves | Nadie, incluidos los operadores de AWS | **Solo vos** — AWS no tiene credenciales para tu HSM |
| Interfaces | Solo la API de AWS | PKCS#11, JCE, motor dinámico de OpenSSL, herramientas afines a KMIP, más la API de AWS vía custom key store |
| Integración nativa con servicios de AWS | ~120 servicios | Solo vía custom key store de KMS |
| Carga operativa | Ninguna | Vos gestionás usuarios, quórum (M de N), backups, capacidad del clúster |
| Motivo típico | Opción por defecto | Mandato regulatorio de custodia exclusiva, offloading de SSL, criptografía a medida (por ejemplo, emitir la raíz de una CA privada, Oracle TDE con claves en poder del cliente) |
| Modelo de costo | Por clave + por solicitud | Por hora de HSM (sustancialmente más caro) |

**Regla de decisión:** usá KMS salvo que un regulador o un contrato exija que ningún tercero pueda alcanzar física o lógicamente el material de clave — ahí, CloudHSM, opcionalmente con un custom key store de KMS por delante para conservar la integración con los servicios.

### 3.4 Cifrado en tránsito

- **ACM** emite y renueva automáticamente **certificados TLS públicos gratuitos** para usar con servicios integrados: CloudFront, ALB/NLB, API Gateway, App Runner, Cognito. La validación es por DNS (CNAME — recomendada, habilita la renovación automática sin intervención humana) o por correo electrónico. Los certificados tienen alcance regional; **CloudFront requiere el certificado en `us-east-1`**. Los certificados públicos de ACM no son exportables de forma predeterminada — para terminación en EC2/on-premises usá **AWS Private CA** o la opción de pago de certificado público exportable.
- **AWS Private CA** emite certificados internos para mTLS, service meshes, IoT y webhooks de EKS. Se cobra por CA por mes más por certificado.
- Imponer TLS es un acto de *política*, no de *servicio*: la condición `aws:SecureTransport` (§6.2) es lo que realmente lo vuelve no opcional.
- Los **endpoints de VPC (PrivateLink / gateway endpoints)** mantienen el tráfico hacia los servicios de AWS completamente fuera de internet público; las políticas de endpoint más las condiciones `aws:SourceVpce`/`aws:SourceVpc` convierten la posición en la red en una señal de autorización.

### 3.5 Secretos: Secrets Manager frente a Parameter Store

| | Secrets Manager | SSM Parameter Store (SecureString) |
|---|---|---|
| Cifrado | KMS, siempre | KMS para `SecureString` |
| **Rotación automática** | **Sí** — rotación administrada por Lambda para RDS, Redshift, DocumentDB; Lambda propia para cualquier otra cosa | No (lo construís vos con EventBridge + Lambda) |
| Replicación entre cuentas / entre regiones | Nativa | No (replicás vos) |
| Costo | ~$0,40/secreto/mes + ~$0,05 por cada 10k llamadas a la API | Nivel estándar gratuito (10k parámetros); Advanced ~$0,05/parámetro/mes |
| Límite de tamaño | 64 KB | 4 KB estándar / 8 KB advanced |
| Ideal para | Credenciales de bases de datos, claves de API de terceros que necesitan rotación | Valores de configuración, ajustes que no rotan, feature flags |

**Ninguno de los dos va en una variable de entorno commiteada a un repositorio.** En producción, preferí el driver CSI respaldado por Secrets Manager (EKS) o la integración `secrets` en las definiciones de tarea de ECS, para que el valor se inyecte en tiempo de ejecución y nunca quede en una revisión de la definición de tarea.

---

## 4. Controles detectivos y auditoría

### 4.1 AWS CloudTrail — el registro probatorio

CloudTrail registra la actividad de la API. Tres categorías de eventos, con costos y valor materialmente distintos:

| Tipo de evento | Qué captura | Predeterminado | Costo |
|---|---|---|---|
| **Eventos de administración** | Llamadas del plano de control: `RunInstances`, `PutBucketPolicy`, `AssumeRole`, `CreateKey` | Activado (Event history de 90 días, gratis); una copia gratuita por trail | La primera copia es gratis; las copias adicionales se facturan |
| **Eventos de datos** | Llamadas del plano de datos: `s3:GetObject`, `lambda:Invoke`, `dynamodb:PutItem` | **Desactivado** — hay que habilitarlo | Por evento, alto volumen — acotalo con advanced event selectors |
| **Eventos de Insights** | Desviaciones anómalas en tasa de llamadas o de errores | Desactivado | Por evento analizado |

Configuración de producción no negociable:

1. **Organization trail** creado en la cuenta de administración (o en el administrador delegado) → toda cuenta miembro, actual y futura, queda cubierta automáticamente, y los administradores miembros no pueden deshabilitarlo.
2. **Validación de archivos de log activada** → CloudTrail escribe **archivos digest** por hora que contienen hashes SHA-256 de cada archivo de log y un hash del digest anterior, firmados con una clave privada de CloudTrail. Esto produce una cadena de hashes: borrar o alterar un solo archivo de log rompe la validación. Esto es lo que convierte al trail en *evidencia* en lugar de *telemetría*.
3. **Entrega a un bucket en una cuenta Log Archive separada**, con Object Lock (WORM) y una bucket policy que deniegue el borrado.
4. **SSE-KMS con una CMK** cuya key policy permita a CloudTrail cifrar pero no permita a las cuentas de carga de trabajo descifrar.

**CloudTrail Lake** es el almacén de datos de eventos administrado, inmutable y consultable por SQL (retención de 7 años o más) — la alternativa a llevarte los logs a Athena por tu cuenta.

### 4.2 AWS Config — estado, no llamadas

CloudTrail responde *"quién llamó a qué"*. Config responde *"cómo se veía este recurso a las 14:32, y cumplía?"*. Registra **elementos de configuración (CIs)** al haber cambios, construye una línea de tiempo de configuración y un grafo de relaciones, y evalúa **reglas**.

- **Reglas administradas** (cientos): `encrypted-volumes`, `s3-bucket-server-side-encryption-enabled`, `iam-root-access-key-check`, `rds-storage-encrypted`, `required-tags`, `restricted-ssh`.
- **Reglas personalizadas**: Lambda o Guard (DSL de política como código).
- **Conformance packs**: un paquete YAML desplegable de reglas + remediaciones, mapeado a un marco (CIS, PCI DSS, NIST 800-53, HIPAA), desplegable en toda la organización.
- **Remediación**: adjuntá un documento de SSM Automation para corrección automática (por ejemplo, volver a habilitar el bloqueo de acceso público del bucket).
- **Agregador**: una vista única de cumplimiento multicuenta y multirregión.

Advertencia de costo: Config factura por elemento de configuración registrado y por evaluación de regla. Registrar *todos* los tipos de recurso en una cuenta con mucha rotación (autoscaling, versiones de Lambda) puede dominar el presupuesto de seguridad — usá exclusiones en la estrategia de registro de manera deliberada.

### 4.3 La matriz de servicios de detección

Esta tabla es el artefacto de mayor rendimiento de todo el enunciado de tarea: el examen pregunta una y otra vez "qué servicio hace X".

| Servicio | Pregunta que responde | Fuente de datos principal | ¿Requiere agente? | Salida |
|---|---|---|---|---|
| **Amazon GuardDuty** | "¿Alguien está actuando maliciosamente *ahora mismo*?" | CloudTrail, VPC Flow Logs, logs DNS de Route 53, logs de auditoría de EKS, eventos de datos de S3, actividad de login de RDS, actividad de red de Lambda — **consumidos sin que tengas que habilitarlos** | No | Hallazgos de amenaza (criptominería, exfiltración de credenciales hacia un nodo de salida Tor, llamadas de API con viaje imposible) |
| **Amazon Inspector** | "¿Mi software es vulnerable?" | EC2, imágenes de contenedor en ECR, funciones y capas de Lambda, repositorios de código fuente | Usa el SSM Agent para EC2 (hay opción sin agente) | Hallazgos de CVE con una puntuación de riesgo de Inspector |
| **Amazon Macie** | "¿Dónde están mis datos sensibles?" | Objetos de Amazon S3 | No | Hallazgos de datos sensibles (PII, credenciales, PHI) + inventario de buckets |
| **Amazon Detective** | "¿Cuál es el radio de impacto de este hallazgo?" | CloudTrail, VPC Flow Logs, GuardDuty, logs de auditoría de EKS → grafo de comportamiento | No | Grafo de investigación, líneas de tiempo de entidades |
| **AWS Security Hub** | "¿Cuál es mi postura general, en un solo lugar?" | Agrega GuardDuty, Inspector, Macie, Config, IAM Access Analyzer, Firewall Manager, productos de partners | No | Hallazgos ASFF normalizados, puntuaciones de seguridad, cumplimiento de estándares (AWS FSBP, CIS, PCI DSS, NIST 800-53) |
| **AWS Audit Manager** | "¿Puedo entregarle evidencia a mi auditor sin una planilla?" | CloudTrail, Config, Security Hub, llamadas a la API | No | Evidencia mapeada a marcos, con marca de tiempo, y un informe de evaluación |
| **AWS Trusted Advisor** | "¿Estoy siguiendo las buenas prácticas de AWS?" | Metadatos de la cuenta + APIs de servicios | No | Verificaciones de optimización de costos, rendimiento, **seguridad**, tolerancia a fallos, límites de servicio y excelencia operativa |
| **IAM Access Analyzer** | "¿Hay algo alcanzable desde fuera de mi zona de confianza? ¿Qué permisos no se usan?" | Razonamiento automatizado (seguridad demostrable) sobre políticas de recurso y de identidad | No | Hallazgos de acceso externo y de acceso no usado; verificaciones de políticas personalizadas en CI |
| **Amazon Security Lake** | "¿Puedo consultar cinco años de telemetría de seguridad de todas las cuentas?" | Normaliza logs de AWS y de terceros a **OCSF** en tu S3 | No | Lago consultable (Athena, OpenSearch, SIEM de partner) |

Pares mnemotécnicos que desambiguan los distractores clásicos:

- **GuardDuty = amenazas (comportamiento)** · **Inspector = vulnerabilidades (software)** · **Macie = datos (contenido)** · **Config = configuración (estado)** · **CloudTrail = acciones (quién)** · **Detective = investigación (por qué / hasta dónde)** · **Security Hub = agregación (todo lo anterior)**.
- **Trusted Advisor = consejos**, no un pipeline de hallazgos de seguridad. **Audit Manager = evidencia para auditores**, no detección.

### 4.4 Dónde encaja CloudWatch

CloudWatch es *observabilidad*, pero dos funciones son portantes para la gobernanza:

- **Metric filters + alarmas de CloudWatch Logs** sobre el grupo de logs de CloudTrail — los controles clásicos del CIS Benchmark (alarma por uso de la cuenta root, por cambios en políticas de IAM, por cambios en la configuración de CloudTrail).
- **Reglas de EventBridge** sobre eventos de CloudTrail para respuesta casi en tiempo real (por ejemplo, `DeleteTrail` → aviso por SNS + Lambda que lo vuelve a crear).

---

## 5. Cumplimiento, geografía y soberanía

### 5.1 AWS Artifact

**AWS Artifact es el portal de autoservicio para la evidencia de cumplimiento de la propia AWS** — esta es la respuesta a "¿de dónde descargo el informe SOC 2 de AWS?"

- **Artifact Reports**: SOC 1/2/3, ISO 27001/27017/27018/9001, AOC de PCI DSS, paquetes FedRAMP, C5 (Alemania), IRAP (Australia), HITRUST e informes de terceros de ISV.
- **Artifact Agreements**: aceptar acuerdos legales en nombre de tu cuenta o de tu organización — en particular el **Business Associate Addendum (BAA) de HIPAA** y los NDA necesarios para acceder a ciertos informes.

El acceso se controla mediante IAM; varios informes requieren aceptar un NDA antes de descargarlos. Artifact **no** produce evidencia sobre *tus* cargas de trabajo — eso es Audit Manager.

### 5.2 Los programas de cumplimiento varían según geografía e industria

| Impulsor | Programa | Consecuencia práctica en AWS |
|---|---|---|
| Salud en EE. UU. | HIPAA/HITECH | Aceptá el BAA en Artifact; usá solo servicios elegibles para HIPAA; cifrá la PHI en reposo y en tránsito |
| Tarjetas de pago | PCI DSS Nivel 1 | AWS es un Proveedor de Servicios de Nivel 1; vos igual tenés que delimitar tu CDE, segmentarlo y producir tu propio AOC |
| Datos personales de la UE | GDPR | AWS ofrece un Data Processing Addendum; vos elegís la región, controlás las transferencias y seguís siendo el responsable del tratamiento |
| Federal de EE. UU. | FedRAMP / DoD SRG | Usá **AWS GovCloud (US)** o regiones aprobadas; cargas de trabajo ITAR → GovCloud |
| Alemania | BSI C5 | Atestaciones regionales disponibles en Artifact |
| Australia | IRAP | Declarado para regiones específicas |
| China | CSL/MLPS | Las particiones de **AWS China (Pekín/Ningxia)** están operadas por socios chinos (Sinnet, NWCD), son una **partición separada** (`aws-cn`), requieren una cuenta aparte y no forman parte de la organización global |

### 5.3 Residencia de datos y soberanía

- **Tus datos permanecen en la región que elijas.** AWS no replica datos de clientes entre regiones a menos que vos lo configures (S3 CRR, tablas globales de DynamoDB, copia de AMI, copia de backup). Algunos *metadatos de servicio* (por ejemplo, IAM, Route 53, CloudFront, Organizations — servicios globales) son inherentemente globales; sabé qué servicios son globales y cuáles regionales.
- **La aplicación es un acto de política**, no una esperanza. La condición de SCP `aws:RequestedRegion` (§6.2) es el mecanismo.
- **Niveles de soberanía**, de menor a mayor aislamiento: región estándar → **Dedicated Local Zones** / **Outposts** (infraestructura de AWS en tus instalaciones o en una instalación designada) → **AWS European Sovereign Cloud** (operativamente independiente, personal y plano de control residentes en la UE) → **GovCloud (US)** → **partición de AWS China** (entidad legal y partición separadas).
- **El AWS Nitro System** sostiene el argumento técnico: el hipervisor Nitro no tiene mecanismo de acceso interactivo, no hay SSH de operador y no hay capacidad de leer la memoria de la instancia. **Nitro Enclaves** extiende esto a cómputo aislado sin almacenamiento persistente, sin acceso interactivo y sin red externa — con atestación criptográfica que una key policy de KMS puede exigir mediante la condición `kms:RecipientAttestation`.

---

## 6. Infraestructura completa: una línea base de gobernanza

### 6.1 CloudFormation — organization trail, CMK, Config, Security Hub, GuardDuty

Desplegalo en la cuenta **Log Archive / Security Tooling** para el bucket, y en la **cuenta de administración (o el administrador delegado)** para el organization trail. Se presenta como una sola plantilla por legibilidad; en producción, dividila entre stack sets.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Governance baseline: tamper-evident organization CloudTrail encrypted with a
  customer managed KMS key, AWS Config recorder with core compliance rules,
  Security Hub with FSBP enabled, GuardDuty, and an alerting path for
  security-control tampering.

Parameters:
  OrganizationId:
    Type: String
    Description: AWS Organizations ID (o-xxxxxxxxxx). Used in the S3 log prefix.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
  ManagementAccountId:
    Type: String
    Description: Account ID of the Organizations management account.
    AllowedPattern: '^[0-9]{12}$'
  TrailName:
    Type: String
    Default: org-governance-trail
  SecurityContactEmail:
    Type: String
    Description: Subscribed to the security alert topic.
  LogRetentionDays:
    Type: Number
    Default: 2555          # 7 years, typical financial-services retention
    MinValue: 365

Resources:

  # ------------------------------------------------------------------
  # 1. Customer managed KMS key for the trail
  # ------------------------------------------------------------------
  TrailKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: Encrypts organization CloudTrail log files.
      EnableKeyRotation: true
      RotationPeriodInDays: 365
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Id: trail-key-policy
        Statement:
          - Sid: EnableIamUserPermissions
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
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${ManagementAccountId}:trail/*'
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: AllowCloudTrailDescribeKey
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'kms:DescribeKey'
            Resource: '*'

          - Sid: AllowOrgMembersToDecryptTheirOwnLogs
            Effect: Allow
            Principal:
              AWS: '*'
            Action:
              - 'kms:Decrypt'
              - 'kms:ReEncryptFrom'
            Resource: '*'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrganizationId
              StringLike:
                'kms:EncryptionContext:aws:cloudtrail:arn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:*:${ManagementAccountId}:trail/*'

  TrailKmsKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: alias/org-cloudtrail
      TargetKeyId: !Ref TrailKmsKey

  # ------------------------------------------------------------------
  # 2. WORM log archive bucket
  # ------------------------------------------------------------------
  TrailBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub 'org-cloudtrail-${AWS::AccountId}-${AWS::Region}'
      ObjectLockEnabled: true
      ObjectLockConfiguration:
        ObjectLockEnabled: Enabled
        Rule:
          DefaultRetention:
            Mode: COMPLIANCE      # not even the root user can shorten this
            Days: 365
      VersioningConfiguration:
        Status: Enabled
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true
            ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !Ref TrailKmsKey
      LifecycleConfiguration:
        Rules:
          - Id: tier-and-expire
            Status: Enabled
            Transitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 90
              - StorageClass: GLACIER
                TransitionInDays: 365
            ExpirationInDays: !Ref LogRetentionDays
      Tags:
        - Key: DataClassification
          Value: audit-evidence
        - Key: Compliance
          Value: 'soc2,pci-dss,iso27001'

  TrailBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref TrailBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AWSCloudTrailAclCheck
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:GetBucketAcl'
            Resource: !GetAtt TrailBucket.Arn
            Condition:
              StringEquals:
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: AWSCloudTrailWriteOrgLogs
            Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 's3:PutObject'
            Resource:
              - !Sub '${TrailBucket.Arn}/AWSLogs/${ManagementAccountId}/*'
              - !Sub '${TrailBucket.Arn}/AWSLogs/${OrganizationId}/*'
            Condition:
              StringEquals:
                's3:x-amz-acl': 'bucket-owner-full-control'
                'aws:SourceArn':
                  !Sub 'arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${ManagementAccountId}:trail/${TrailName}'

          - Sid: DenyUnencryptedTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt TrailBucket.Arn
              - !Sub '${TrailBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

          - Sid: DenyLogTampering
            Effect: Deny
            Principal: '*'
            Action:
              - 's3:DeleteObject'
              - 's3:DeleteObjectVersion'
              - 's3:PutObjectRetention'
              - 's3:PutLifecycleConfiguration'
            Resource: !Sub '${TrailBucket.Arn}/*'
            Condition:
              StringNotEquals:
                'aws:PrincipalArn':
                  !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/LogArchiveBreakGlass'

  # ------------------------------------------------------------------
  # 3. Organization trail  (deploy this resource in the management account)
  # ------------------------------------------------------------------
  OrganizationTrail:
    Type: AWS::CloudTrail::Trail
    DependsOn: TrailBucketPolicy
    Properties:
      TrailName: !Ref TrailName
      S3BucketName: !Ref TrailBucket
      KMSKeyId: !Ref TrailKmsKey
      IsLogging: true
      IsMultiRegionTrail: true
      IsOrganizationTrail: true
      IncludeGlobalServiceEvents: true
      EnableLogFileValidation: true         # <-- produces the signed digest chain
      CloudWatchLogsLogGroupArn: !GetAtt TrailLogGroup.Arn
      CloudWatchLogsRoleArn: !GetAtt TrailToCwlRole.Arn
      AdvancedEventSelectors:
        - Name: All management events
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Management']
        - Name: S3 data events on classified buckets only
          FieldSelectors:
            - Field: eventCategory
              Equals: ['Data']
            - Field: resources.type
              Equals: ['AWS::S3::Object']
            - Field: resources.ARN
              StartsWith:
                - !Sub 'arn:${AWS::Partition}:s3:::regulated-'
      Tags:
        - Key: Purpose
          Value: audit-evidence

  TrailLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/cloudtrail/org-governance
      RetentionInDays: 365
      KmsKeyId: !GetAtt TrailKmsKey.Arn

  TrailToCwlRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: cloudtrail.amazonaws.com
            Action: 'sts:AssumeRole'
      Policies:
        - PolicyName: write-to-cwl
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                Resource: !Sub '${TrailLogGroup.Arn}:log-stream:*'

  # ------------------------------------------------------------------
  # 4. AWS Config
  # ------------------------------------------------------------------
  ConfigRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWS_ConfigRole'
      Policies:
        - PolicyName: config-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 's3:PutObject'
                Resource: !Sub '${TrailBucket.Arn}/config/*'
                Condition:
                  StringEquals:
                    's3:x-amz-acl': 'bucket-owner-full-control'
              - Effect: Allow
                Action: 's3:GetBucketAcl'
                Resource: !GetAtt TrailBucket.Arn
              - Effect: Allow
                Action:
                  - 'kms:GenerateDataKey'
                  - 'kms:Decrypt'
                Resource: !GetAtt TrailKmsKey.Arn

  ConfigRecorder:
    Type: AWS::Config::ConfigurationRecorder
    Properties:
      Name: default
      RoleARN: !GetAtt ConfigRole.Arn
      RecordingGroup:
        AllSupported: true
        IncludeGlobalResourceTypes: true
      RecordingMode:
        RecordingFrequency: CONTINUOUS

  ConfigDeliveryChannel:
    Type: AWS::Config::DeliveryChannel
    Properties:
      Name: default
      S3BucketName: !Ref TrailBucket
      S3KeyPrefix: config
      S3KmsKeyArn: !GetAtt TrailKmsKey.Arn
      ConfigSnapshotDeliveryProperties:
        DeliveryFrequency: TwentyFour_Hours

  RuleCloudTrailEnabled:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: cloudtrail-enabled
      Description: A CloudTrail trail must be enabled in this account.
      Source:
        Owner: AWS
        SourceIdentifier: CLOUD_TRAIL_ENABLED

  RuleEncryptedVolumes:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: encrypted-volumes
      Description: All attached EBS volumes must be encrypted.
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Volume'
      Source:
        Owner: AWS
        SourceIdentifier: ENCRYPTED_VOLUMES

  RuleS3PublicReadProhibited:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: s3-bucket-public-read-prohibited
      Scope:
        ComplianceResourceTypes:
          - 'AWS::S3::Bucket'
      Source:
        Owner: AWS
        SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED

  RuleRootAccessKeyCheck:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: iam-root-access-key-check
      MaximumExecutionFrequency: TwentyFour_Hours
      Source:
        Owner: AWS
        SourceIdentifier: IAM_ROOT_ACCESS_KEY_CHECK

  RuleRequiredTags:
    Type: AWS::Config::ConfigRule
    DependsOn: ConfigRecorder
    Properties:
      ConfigRuleName: required-tags
      Scope:
        ComplianceResourceTypes:
          - 'AWS::EC2::Instance'
          - 'AWS::S3::Bucket'
          - 'AWS::RDS::DBInstance'
      InputParameters:
        tag1Key: Owner
        tag2Key: CostCenter
        tag3Key: DataClassification
      Source:
        Owner: AWS
        SourceIdentifier: REQUIRED_TAGS

  # ------------------------------------------------------------------
  # 5. Detection services
  # ------------------------------------------------------------------
  GuardDutyDetector:
    Type: AWS::GuardDuty::Detector
    Properties:
      Enable: true
      FindingPublishingFrequency: FIFTEEN_MINUTES
      DataSources:
        S3Logs:
          Enable: true
        Kubernetes:
          AuditLogs:
            Enable: true
        MalwareProtection:
          ScanEc2InstanceWithFindings:
            EbsVolumes: true

  SecurityHub:
    Type: AWS::SecurityHub::Hub
    Properties:
      Tags:
        Purpose: posture-management

  FoundationalSecurityStandard:
    Type: AWS::SecurityHub::Standard
    DependsOn: SecurityHub
    Properties:
      StandardsArn:
        !Sub 'arn:${AWS::Partition}:securityhub:${AWS::Region}::standards/aws-foundational-security-best-practices/v/1.0.0'

  # ------------------------------------------------------------------
  # 6. Tamper alerting
  # ------------------------------------------------------------------
  SecurityAlertTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: security-control-tampering
      KmsMasterKeyId: alias/aws/sns
      Subscription:
        - Protocol: email
          Endpoint: !Ref SecurityContactEmail

  SecurityAlertTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics:
        - !Ref SecurityAlertTopic
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowEventBridgePublish
            Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: 'sns:Publish'
            Resource: !Ref SecurityAlertTopic

  ControlTamperingRule:
    Type: AWS::Events::Rule
    Properties:
      Name: detect-security-control-tampering
      Description: Fires when someone tries to disable an audit or detection control.
      EventPattern:
        source:
          - aws.cloudtrail
          - aws.config
          - aws.guardduty
          - aws.kms
        detail-type:
          - 'AWS API Call via CloudTrail'
        detail:
          eventName:
            - StopLogging
            - DeleteTrail
            - UpdateTrail
            - PutEventSelectors
            - DeleteConfigurationRecorder
            - StopConfigurationRecorder
            - DeleteDeliveryChannel
            - DeleteDetector
            - UpdateDetector
            - DisableSecurityHub
            - ScheduleKeyDeletion
            - DisableKeyRotation
      State: ENABLED
      Targets:
        - Id: notify-security
          Arn: !Ref SecurityAlertTopic
          InputTransformer:
            InputPathsMap:
              account: '$.account'
              region: '$.region'
              event: '$.detail.eventName'
              who: '$.detail.userIdentity.arn'
              time: '$.time'
            InputTemplate: >-
              "SECURITY CONTROL TAMPERING: <event> in account <account> (<region>)
              by <who> at <time>."

Outputs:
  TrailBucketName:
    Description: WORM audit-evidence bucket.
    Value: !Ref TrailBucket
    Export:
      Name: !Sub '${AWS::StackName}-TrailBucket'
  TrailKmsKeyArn:
    Description: CMK protecting audit evidence.
    Value: !GetAtt TrailKmsKey.Arn
    Export:
      Name: !Sub '${AWS::StackName}-TrailKmsKey'
  OrganizationTrailArn:
    Value: !GetAtt OrganizationTrail.Arn
```

### 6.2 Service Control Policy — los invariantes

`scp-baseline-guardrails.json`, adjunta a la OU **Workloads**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeavingTheOrganization",
      "Effect": "Deny",
      "Action": [
        "organizations:LeaveOrganization",
        "organizations:DeleteOrganization"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectAuditAndDetectionControls",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "config:DeleteConfigurationRecorder",
        "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:DeleteConfigRule",
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:UpdateDetector",
        "securityhub:DisableSecurityHub",
        "securityhub:DeleteMembers",
        "macie2:DisableMacie",
        "access-analyzer:DeleteAnalyzer"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/AWSControlTowerExecution",
            "arn:aws:iam::*:role/OrgSecurityAutomation"
          ]
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
      "Sid": "RegionLockForDataResidency",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "route53:*",
        "cloudfront:*",
        "support:*",
        "budgets:*",
        "waf:*",
        "wafv2:*",
        "shield:*",
        "health:*",
        "trustedadvisor:*",
        "artifact:*",
        "account:*",
        "ce:*",
        "cur:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": [
            "eu-central-1",
            "eu-west-1"
          ]
        }
      }
    },
    {
      "Sid": "RequireEncryptionAtRestOnEbsAndRds",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateVolume",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "ec2:Encrypted": "false"
        }
      }
    },
    {
      "Sid": "RequireImdsV2OnLaunch",
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
      "Sid": "ProtectKmsKeyMaterial",
      "Effect": "Deny",
      "Action": [
        "kms:ScheduleKeyDeletion",
        "kms:DisableKeyRotation",
        "kms:DisableKey",
        "kms:PutKeyPolicy"
      ],
      "Resource": "arn:aws:kms:*:*:key/*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:role/KmsKeyAdministrator"
        }
      }
    },
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
          "aws:PrincipalArn": "arn:aws:iam::*:role/OrgSecurityAutomation"
        }
      }
    }
  ]
}
```

> **Nota sobre `DenyRootUserActions`:** las SCPs no aplican a la cuenta de administración, y ciertas tareas realmente requieren root (cerrar una cuenta, cambiar el correo de root de la cuenta, algunas operaciones de MFA-delete en S3). Acotá esta sentencia con cuidado y mantené un procedimiento de break-glass documentado y con alarmas.

### 6.3 Resource Control Policy — cerrando el hueco de compartición externa

`rcp-no-external-sharing.json`, adjunta a la OU **Workloads**. Deniega *cualquier* acceso a recursos de S3, STS, SQS, KMS y Secrets Manager en esas cuentas por parte de principals ajenos a la organización, sin importar lo que diga una bucket policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnforceOrgIdentityPerimeter",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:*",
        "sts:AssumeRole",
        "sqs:*",
        "kms:*",
        "secretsmanager:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEqualsIfExists": {
          "aws:PrincipalOrgID": "o-a1b2c3d4e5"
        },
        "BoolIfExists": {
          "aws:PrincipalIsAWSService": "false"
        }
      }
    },
    {
      "Sid": "EnforceTlsOnAllDataResources",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:*",
        "sqs:*",
        "secretsmanager:*"
      ],
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
```

### 6.4 Tag policy

`tag-policy-cost-and-classification.json`:

```json
{
  "tags": {
    "DataClassification": {
      "tag_key": { "@@assign": "DataClassification" },
      "tag_value": {
        "@@assign": ["public", "internal", "confidential", "restricted"]
      },
      "enforced_for": {
        "@@assign": ["s3:bucket", "rds:db", "dynamodb:table", "ec2:volume"]
      }
    },
    "CostCenter": {
      "tag_key": { "@@assign": "CostCenter" },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db"] }
    },
    "Owner": {
      "tag_key": { "@@assign": "Owner" }
    }
  }
}
```

### 6.5 Terraform — adjuntando las políticas a toda la organización

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  region = "eu-central-1"
  # Runs with management-account credentials.
}

data "aws_organizations_organization" "this" {}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_policy" "baseline_guardrails" {
  name        = "baseline-guardrails"
  description = "Org invariants: no leaving, no control tampering, region lock, encryption required."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/scp-baseline-guardrails.json")
}

resource "aws_organizations_policy_attachment" "baseline_to_workloads" {
  policy_id = aws_organizations_policy.baseline_guardrails.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "identity_perimeter" {
  name    = "no-external-sharing"
  type    = "RESOURCE_CONTROL_POLICY"
  content = file("${path.module}/policies/rcp-no-external-sharing.json")
}

resource "aws_organizations_policy_attachment" "rcp_to_workloads" {
  policy_id = aws_organizations_policy.identity_perimeter.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "tagging" {
  name    = "cost-and-classification-tags"
  type    = "TAG_POLICY"
  content = file("${path.module}/policies/tag-policy-cost-and-classification.json")
}

resource "aws_organizations_policy_attachment" "tags_to_root" {
  policy_id = aws_organizations_policy.tagging.id
  target_id = data.aws_organizations_organization.this.roots[0].id
}

# Delegate security service administration out of the management account.
resource "aws_organizations_delegated_administrator" "guardduty" {
  account_id        = var.security_tooling_account_id
  service_principal = "guardduty.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "securityhub" {
  account_id        = var.security_tooling_account_id
  service_principal = "securityhub.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "config" {
  account_id        = var.security_tooling_account_id
  service_principal = "config.amazonaws.com"
}

variable "security_tooling_account_id" {
  type        = string
  description = "Account ID of the Security Tooling account."
}
```

---

## 7. Operaciones por CLI

### 7.1 Inspeccionar la organización y sus políticas

```console
$ aws organizations describe-organization --query 'Organization.[Id,MasterAccountId,FeatureSet]' --output text
o-a1b2c3d4e5    111122223333    ALL

$ aws organizations list-roots --query 'Roots[0].PolicyTypes'
[
    {
        "Type": "SERVICE_CONTROL_POLICY",
        "Status": "ENABLED"
    },
    {
        "Type": "RESOURCE_CONTROL_POLICY",
        "Status": "ENABLED"
    },
    {
        "Type": "TAG_POLICY",
        "Status": "ENABLED"
    }
]

$ aws organizations list-policies-for-target \
    --target-id ou-ab12-3cdefgh4 \
    --filter SERVICE_CONTROL_POLICY \
    --output table
-------------------------------------------------------------------------------
|                          ListPoliciesForTarget                              |
+-------------+---------------------------+----------------+------------------+
|     Arn     |        Description        |      Id        |      Name        |
+-------------+---------------------------+----------------+------------------+
| arn:aws:... | Allows access to every... | p-FullAWSAccess| FullAWSAccess    |
| arn:aws:... | Org invariants: no lea... | p-8x2k9m4q     | baseline-guard.. |
+-------------+---------------------------+----------------+------------------+
```

### 7.2 Cómo se ve realmente una solicitud bloqueada

```console
$ aws ec2 run-instances --image-id ami-0abcdef1234567890 \
    --instance-type t3.micro --region us-west-2

An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation. User:
arn:aws:sts::444455556666:assumed-role/PlatformEngineer/alex is not authorized to
perform: ec2:RunInstances with an explicit deny in a service control policy.
```

La frase **"with an explicit deny in a service control policy"** es la señal diagnóstica: la política de identidad es irrelevante; andá a leer la cadena de SCPs. Comparalo con la forma de RCP:

```console
$ aws s3api get-object --bucket regulated-eu-features \
    --key train.parquet /tmp/train.parquet --profile partner-account

An error occurred (AccessDenied) when calling the GetObject operation: User:
arn:aws:iam::999988887777:user/partner-etl is not authorized to perform:
s3:GetObject on resource: "arn:aws:s3:::regulated-eu-features/train.parquet"
with an explicit deny in a resource control policy.
```

### 7.3 Probar que el rastro de auditoría está intacto

```console
$ aws cloudtrail get-trail-status --name org-governance-trail \
    --query '[IsLogging,LatestDeliveryTime,LatestDeliveryError]' --output text
True    2026-09-03T11:04:18+00:00    None

$ aws cloudtrail describe-trails --trail-name-list org-governance-trail \
    --query 'trailList[0].[IsOrganizationTrail,LogFileValidationEnabled,KmsKeyId]' \
    --output text
True    True    arn:aws:kms:eu-central-1:222233334444:key/1a2b3c4d-5e6f-7890-abcd-ef1234567890

$ aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:eu-central-1:111122223333:trail/org-governance-trail \
    --start-time 2026-09-01T00:00:00Z \
    --end-time   2026-09-03T00:00:00Z

Validating log files for trail arn:aws:cloudtrail:eu-central-1:111122223333:trail/org-governance-trail
between 2026-09-01T00:00:00Z and 2026-09-03T00:00:00Z

Results requested for 2026-09-01T00:00:00Z to 2026-09-03T00:00:00Z
Results found for 2026-09-01T00:00:00Z to 2026-09-03T00:00:00Z:

48/48 digest files valid
1,204/1,204 log files valid
```

Un archivo manipulado falla ruidosamente y nombra el archivo:

```console
$ aws cloudtrail validate-logs --trail-arn arn:aws:cloudtrail:...:trail/org-governance-trail \
    --start-time 2026-08-28T00:00:00Z

Log file  s3://org-cloudtrail-222233334444-eu-central-1/AWSLogs/o-a1b2c3d4e5/444455556666/CloudTrail/eu-central-1/2026/08/28/444455556666_CloudTrail_eu-central-1_20260828T1420Z_kQ2mR9.json.gz
INVALID: hash value doesn't match

24/25 digest files valid
611/612 log files valid
```

### 7.4 Consultas de cumplimiento en Config

```console
$ aws configservice describe-configuration-recorder-status \
    --query 'ConfigurationRecordersStatus[0].[name,recording,lastStatus]' --output text
default True    SUCCESS

$ aws configservice describe-compliance-by-config-rule \
    --config-rule-names encrypted-volumes s3-bucket-public-read-prohibited \
    --output table
------------------------------------------------------------------
|                  DescribeComplianceByConfigRule                 |
+------------------------------------+----------------------------+
|            ConfigRuleName          |      ComplianceType        |
+------------------------------------+----------------------------+
|  encrypted-volumes                 |  NON_COMPLIANT             |
|  s3-bucket-public-read-prohibited  |  COMPLIANT                 |
+------------------------------------+----------------------------+

$ aws configservice get-compliance-details-by-config-rule \
    --config-rule-name encrypted-volumes \
    --compliance-types NON_COMPLIANT \
    --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' \
    --output text
vol-0f2a91c4e8b7d3a10    vol-04c81b9de77f2a3b5

$ aws configservice select-resource-config \
    --expression "SELECT resourceId, resourceName, tags WHERE resourceType = 'AWS::S3::Bucket' AND tags.key = 'DataClassification' AND tags.value = 'restricted'"
{
    "Results": [
        "{\"resourceId\":\"regulated-eu-features\",\"resourceName\":\"regulated-eu-features\",\"tags\":[{\"key\":\"DataClassification\",\"value\":\"restricted\"}]}"
    ]
}
```

### 7.5 KMS

```console
$ aws kms describe-key --key-id alias/org-cloudtrail \
    --query 'KeyMetadata.[KeyId,KeyState,KeyManager,KeySpec,MultiRegion]' --output text
1a2b3c4d-5e6f-7890-abcd-ef1234567890    Enabled    CUSTOMER    SYMMETRIC_DEFAULT    False

$ aws kms get-key-rotation-status --key-id alias/org-cloudtrail
{
    "KeyRotationEnabled": true,
    "KeyId": "arn:aws:kms:eu-central-1:222233334444:key/1a2b3c4d-5e6f-7890-abcd-ef1234567890",
    "RotationPeriodInDays": 365,
    "NextRotationDate": "2027-02-14T09:31:02+00:00"
}

# Envelope encryption, by hand — this is exactly what S3 and EBS do for you.
$ aws kms generate-data-key --key-id alias/app-data --key-spec AES_256 \
    --encryption-context tenant=acme,env=prod \
    --query '[Plaintext,CiphertextBlob]' --output text
wEXAMPLEplaintextkeybase64...=    AQIDAHjRYlEXAMPLEciphertextblob...==

$ aws kms decrypt --ciphertext-blob fileb://key.enc \
    --encryption-context tenant=acme,env=prod \
    --query Plaintext --output text | base64 -d > /dev/shm/dek.bin
```

Un contexto de cifrado equivocado es un fallo duro — este es el caso de soporte de KMS más común:

```console
$ aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context tenant=acme

An error occurred (InvalidCiphertextException) when calling the Decrypt operation:
```

### 7.6 Servicios de detección y Artifact

```console
$ aws guardduty list-detectors --query DetectorIds --output text
d4c2f19a83b7e05d61ff3a9c8e77b214

$ aws guardduty get-findings-statistics --detector-id d4c2f19a83b7e05d61ff3a9c8e77b214 \
    --finding-statistic-types COUNT_BY_SEVERITY
{
    "FindingStatistics": {
        "CountBySeverity": {
            "2": 41,
            "5": 7,
            "8": 2
        }
    }
}

$ aws securityhub get-findings \
    --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
    --max-results 3 \
    --query 'Findings[].[ProductName,Title,Resources[0].Id]' --output text
GuardDuty   UnauthorizedAccess:EC2/MaliciousIPCaller.Custom   arn:aws:ec2:eu-central-1:444455556666:instance/i-0d91ac2f7b8e4c530
Inspector   CVE-2026-21894 - openssl                          arn:aws:ecr:eu-central-1:444455556666:repository/api/sha256:9f3c...
Security Hub  S3.8 S3 Block Public Access should be enabled   arn:aws:s3:::ml-feature-store-prod

$ aws securityhub get-enabled-standards \
    --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' --output text
arn:aws:securityhub:eu-central-1::standards/aws-foundational-security-best-practices/v/1.0.0   READY
arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.4.0                            READY

$ aws artifact list-reports --query 'reports[?contains(name, `SOC 2`)].[id,name,version]' --output text
report-a1b2c3d4e5f6   SOC 2 Type II Report   18
report-b2c3d4e5f6a7   SOC 2 Type II Bridge Letter   4

$ aws artifact get-report --report-id report-a1b2c3d4e5f6 --report-version 18 \
    --term-token $(aws artifact get-term-for-report --report-id report-a1b2c3d4e5f6 \
                     --report-version 18 --query termToken --output text) \
    --query documentPresignedUrl --output text
https://artifact-reports-prod.s3.amazonaws.com/soc2-type2-v18.pdf?X-Amz-Algorithm=...
```

### 7.7 IAM Access Analyzer — encontrar la exposición externa antes que un auditor

```console
$ aws accessanalyzer create-analyzer --analyzer-name org-external-access \
    --type ORGANIZATION --query arn --output text
arn:aws:access-analyzer:eu-central-1:222233334444:analyzer/org-external-access

$ aws accessanalyzer list-findings \
    --analyzer-arn arn:aws:access-analyzer:eu-central-1:222233334444:analyzer/org-external-access \
    --filter '{"status":{"eq":["ACTIVE"]}}' \
    --query 'findings[].[resourceType,resource,principal,isPublic]' --output text
AWS::S3::Bucket    arn:aws:s3:::ml-feature-store-prod    {"AWS":"*"}    True
AWS::IAM::Role     arn:aws:iam::444455556666:role/PartnerIngest    {"AWS":"999988887777"}    False
```

---

## 8. Verificación y diagnóstico de fallos

### 8.1 La verificación previa al vuelo de la gobernanza

Ejecutá esto antes de declarar que una landing zone está lista para producción. Cada línea tiene que pasar.

```bash
#!/usr/bin/env bash
# governance-preflight.sh — verify the Domain 2.2 baseline is actually in effect.
set -euo pipefail

fail() { printf '  [FAIL] %s\n' "$1"; RC=1; }
ok()   { printf '  [ OK ] %s\n' "$1"; }
RC=0

echo "== 1. Organization trail =="
TRAIL=$(aws cloudtrail describe-trails --output json)
echo "$TRAIL" | jq -e '.trailList[] | select(.IsOrganizationTrail == true)' >/dev/null \
  && ok "organization trail exists" || fail "no organization trail"
echo "$TRAIL" | jq -e '.trailList[] | select(.LogFileValidationEnabled == true)' >/dev/null \
  && ok "log file validation enabled" || fail "log file validation OFF - logs are not evidence"
echo "$TRAIL" | jq -e '.trailList[] | select(.KmsKeyId != null)' >/dev/null \
  && ok "trail encrypted with a CMK" || fail "trail using default encryption"

echo "== 2. Config recorder =="
aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].recording' --output text | grep -q True \
  && ok "config recorder running" || fail "config recorder stopped"

echo "== 3. Detection services =="
[ -n "$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)" ] \
  && ok "GuardDuty enabled" || fail "GuardDuty not enabled"
aws securityhub get-enabled-standards >/dev/null 2>&1 \
  && ok "Security Hub enabled" || fail "Security Hub not enabled"

echo "== 4. Account-level S3 public access block =="
aws s3control get-public-access-block --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'PublicAccessBlockConfiguration' --output json \
  | jq -e 'all(.[]; . == true)' >/dev/null \
  && ok "account-level BPA fully on" || fail "account-level Block Public Access incomplete"

echo "== 5. Root user has no access keys =="
aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent' --output text | grep -q '^0$' \
  && ok "no root access keys" || fail "root access keys exist - delete them now"

echo "== 6. KMS rotation on every customer managed key =="
for k in $(aws kms list-keys --query 'Keys[].KeyId' --output text); do
  mgr=$(aws kms describe-key --key-id "$k" --query 'KeyMetadata.KeyManager' --output text)
  [ "$mgr" = "CUSTOMER" ] || continue
  aws kms get-key-rotation-status --key-id "$k" --query KeyRotationEnabled --output text \
    | grep -q True || fail "rotation disabled on key $k"
done
ok "KMS rotation audit complete"

exit $RC
```

### 8.2 Matriz de diagnóstico de fallos

| Síntoma | Causa más probable | Cómo confirmarlo | Solución |
|---|---|---|---|
| `AccessDenied … with an explicit deny in a service control policy` mientras el principal tiene `AdministratorAccess` | Una SCP en una OU ancestro deniega la acción | `aws organizations list-policies-for-target --target-id <account-id> --filter SERVICE_CONTROL_POLICY`, y después leé cada política | Agregá una excepción acotada (condición sobre `aws:PrincipalArn`) o mové la cuenta a otra OU. **Nunca** amplíes la SCP globalmente. |
| Una SCP de lista de permitidos dejó a todos afuera de una cuenta | Se desadjuntó `FullAWSAccess` y la lista de permitidos está incompleta | No podés arreglarlo desde la cuenta miembro | Desadjuntá o reemplazá la SCP desde la **cuenta de administración** (está exenta). Para esto existe la OU `PolicyStaging`. |
| La SCP parece no tener efecto | El objetivo es la cuenta de administración, o el principal es un service-linked role | `aws sts get-caller-identity` → comparalo con `Organization.MasterAccountId` | Sacá las cargas de trabajo de la cuenta de administración. Permanentemente. |
| `kms:Decrypt` denegado aunque la política de IAM lo permite | La key policy no delega en IAM y no nombra al principal | `aws kms get-key-policy --key-id <k> --policy-name default` | Agregá la sentencia de delegación al root de la cuenta o una sentencia con el principal directo a la **key policy** |
| El acceso a KMS entre cuentas falla y ambas políticas parecen correctas | El acceso entre cuentas requiere permiso en **ambas**: la key policy *y* la política de IAM de quien llama; además `kms:ViaService` puede excluir al llamador | `aws kms decrypt` desde el llamador y leé el ARN completo del error | Otorgá de los dos lados; revisá las condiciones `kms:ViaService` y `kms:CallerAccount` |
| `InvalidCiphertextException` al descifrar | Contexto de cifrado que no coincide, o texto cifrado producido por otra clave | Compará el contexto usado al cifrar y al descifrar | Pasá el mapa de contexto idéntico; el contexto es independiente del orden pero distingue mayúsculas y minúsculas |
| Datos permanentemente ilegibles después de una limpieza | El borrado de la clave de KMS se completó tras la ventana pendiente de 7 a 30 días | `aws kms describe-key` → `KeyState: PendingDeletion` (recuperable) frente a clave inexistente (irrecuperable) | Recuperable solo *antes* de que expire la ventana: `aws kms cancel-key-deletion`. Prevenilo con la SCP `ProtectKmsKeyMaterial`. |
| Una regla de Config muestra `NOT_APPLICABLE` para todo | El recorder no está registrando ese tipo de recurso, o el alcance de la regla es incorrecto | `aws configservice describe-configuration-recorders` → revisá `recordingGroup` | Habilitá el tipo de recurso; volvé a revisar el `Scope` de la regla |
| El recorder de Config se detuvo con `insufficientPermissions` | El rol de servicio perdió `s3:PutObject` sobre el bucket de entrega, o `kms:GenerateDataKey` sobre la CMK del bucket | `describe-delivery-channel-status` muestra el último error de entrega | Restaurá la política del rol; si el bucket es de otra cuenta, corregí también la bucket policy |
| CloudTrail con `LatestDeliveryError: InsufficientEncryptionPolicyException` | A la key policy del trail le falta la sentencia `GenerateDataKey*` para `cloudtrail.amazonaws.com`, o la condición `aws:SourceArn` no coincide | `aws cloudtrail get-trail-status --name <t>` | Corregí las condiciones `EncryptionContext`/`SourceArn` de la key policy (§6.1) |
| `validate-logs` informa `INVALID: hash value doesn't match` | Archivo de log alterado o truncado en el bucket | Compará versiones del objeto: `aws s3api list-object-versions --bucket … --prefix …` | Tratalo como un **incidente de seguridad**. Restaurá la versión anterior; habilitá Object Lock en modo COMPLIANCE; auditá quién tenía `s3:PutObject` |
| `validate-logs` informa archivos digest faltantes | El trail estuvo detenido durante esa ventana | Buscá eventos `StopLogging` en CloudTrail | El hueco tiene que documentarse para el auditor; desplegá la SCP `ProtectAuditAndDetectionControls` |
| Certificado de ACM trabado en `PENDING_VALIDATION` | El registro CNAME de validación DNS nunca se publicó, o se publicó en la zona alojada equivocada | `aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.DomainValidationOptions'` | Creá el nombre/valor CNAME exacto en la zona autoritativa; la validación se completa en minutos u horas |
| Un certificado de ACM no aparece seleccionable en una distribución de CloudFront | El certificado no está en `us-east-1` | `aws acm list-certificates --region us-east-1` | Reemitilo en `us-east-1` |
| Una carga de trabajo se rompió justo después de agregar el deny de `aws:SecureTransport` | Algún cliente sigue usando HTTP, o se está usando la ruta de un **gateway** endpoint de VPC para S3 con un SDK viejo | `errorCode: AccessDenied` en CloudTrail + el campo `tlsDetails` del evento | Actualizá los clientes a TLS 1.2 o superior; el bloque `tlsDetails` en los eventos de CloudTrail te dice la versión y el cifrado negociados |
| GuardDuty no produce hallazgos en una cuenta miembro | La cuenta miembro nunca aceptó la invitación, o el auto-enable para cuentas nuevas está desactivado | `aws guardduty list-members --detector-id <id> --query 'Members[].[AccountId,RelationshipStatus]'` | Habilitá `auto-enable` en el administrador delegado; reinvitá |
| La puntuación de Security Hub cayó de un día para el otro sin ningún cambio | Se habilitaron automáticamente una nueva versión de estándar o nuevos controles | `aws securityhub describe-standards-control-associations` | Comportamiento esperado; triageá los controles nuevos o deshabilitalos con una justificación documentada |
| La factura de AWS Config se disparó | `AllSupported: true` en una cuenta con mucha rotación registra cada versión de Lambda, cada cambio de ASG y cada ENI | Cost Explorer filtrado por `AWSConfig`, agrupado por tipo de uso | Usá exclusiones de registro o una estrategia de registro por tipo de recurso; pasá a reglas periódicas diarias donde no haga falta continuo |

### 8.3 Árbol de decisión para elegir un control

```
Need to stop an action before it happens, org-wide, even from an account admin?
├── Constrains YOUR principals ──────────────► SCP
├── Constrains access TO your resources
│      (including external principals) ──────► RCP
├── A service attribute you want to persist
│      (IMDSv2, VPC BPA, allowed AMIs) ──────► Declarative policy
├── Delegating IAM to developers safely ─────► Permissions boundary
└── Should block at deploy time,
       inside CloudFormation ────────────────► Proactive control / CFN Hook

Need to know something happened?
├── Who made the API call ───────────────────► CloudTrail
├── What the resource looked like / drift ───► AWS Config
├── Malicious behavior ──────────────────────► GuardDuty
├── Vulnerable software ─────────────────────► Inspector
├── Sensitive data in S3 ────────────────────► Macie
├── One aggregated view + benchmarks ────────► Security Hub
├── Investigate scope of a finding ──────────► Detective
└── Long-term multi-source query ────────────► Security Lake / CloudTrail Lake

Need to satisfy an auditor?
├── Evidence about AWS's controls ───────────► AWS Artifact
├── Evidence about YOUR workloads ───────────► Audit Manager
└── Best-practice advisory checks ───────────► Trusted Advisor
```

---

## 9. Destilado orientado al examen

Una línea por servicio: el dato discriminante que responde la pregunta:

| Servicio | Lo único |
|---|---|
| **AWS Organizations** | Gestión centralizada + facturación consolidada; las SCPs viven acá; la cuenta de administración está exenta de las SCPs |
| **SCP** | Fija los permisos *máximos*; no otorga nada |
| **AWS Control Tower** | Landing zone multicuenta automatizada y opinada, con controles preventivos/detectivos/proactivos |
| **AWS Artifact** | Descargar los informes de cumplimiento **de AWS** (SOC, ISO, PCI) y aceptar acuerdos (BAA de HIPAA) |
| **AWS Audit Manager** | Recopila continuamente evidencia sobre **tus** cargas de trabajo, mapeada a marcos |
| **AWS Config** | Historial de configuración de recursos + reglas de cumplimiento |
| **AWS CloudTrail** | Historial de llamadas a la API; habilitá la validación de archivos de log para tener evidencia a prueba de manipulación |
| **Amazon GuardDuty** | Detección inteligente de amenazas; sin agentes; consume logs que no tenés que habilitar |
| **Amazon Inspector** | Escaneo automatizado de vulnerabilidades (CVE) en EC2, imágenes de ECR y Lambda |
| **Amazon Macie** | Descubre y clasifica datos sensibles en S3 |
| **Amazon Detective** | Investiga la causa raíz y el alcance de un hallazgo |
| **AWS Security Hub** | Panel único; agrega hallazgos; ejecuta los estándares CIS/PCI/FSBP |
| **AWS Trusted Advisor** | Verificaciones de buenas prácticas en costo, rendimiento, seguridad, tolerancia a fallos, límites de servicio y excelencia operativa |
| **AWS KMS** | Claves administradas, integradas con casi todos los servicios de AWS; nunca tocás el material de clave |
| **AWS CloudHSM** | HSM de un solo tenant, FIPS 140-3 Level 3; **AWS no puede acceder a tus claves** |
| **AWS Certificate Manager** | Certificados TLS públicos gratuitos con renovación automática para servicios integrados |
| **AWS Secrets Manager** | Secretos con **rotación automática incorporada** |
| **AWS Systems Manager Parameter Store** | Almacenamiento de configuración y secretos; sin rotación incorporada; nivel estándar gratuito |
| **IAM Access Analyzer** | Encuentra recursos compartidos fuera de tu zona de confianza; hallazgos de acceso no usado |
| **AWS Firewall Manager** | Aplica centralmente reglas de WAF/Shield/grupos de seguridad en toda la organización |

Tres frases que vale la pena memorizar textualmente:

1. **"El cifrado en reposo y en tránsito es responsabilidad del cliente configurarlo; la responsabilidad de AWS es proveer la capacidad."**
2. **"AWS Artifact te da los documentos de cumplimiento de AWS; no evalúa tus cargas de trabajo."**
3. **"Una SCP no puede otorgar permisos: solo puede restringir lo que de otro modo una política de IAM podría permitir, y un deny explícito en cualquier lugar siempre gana."**

---

## 10. Referencias

**Examen y certificación**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Gobernanza y Organizations**
- AWS Organizations User Guide — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_introduction.html
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Resource control policies (RCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_rcps.html
- Declarative policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_declarative.html
- Tag policies — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html
- Policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- AWS Control Tower User Guide — https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html
- Controls reference (preventive / detective / proactive) — https://docs.aws.amazon.com/controltower/latest/controlreference/controls.html
- Organizing Your AWS Environment Using Multiple Accounts — https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html

**Cifrado y gestión de claves**
- AWS KMS Developer Guide — https://docs.aws.amazon.com/kms/latest/developerguide/overview.html
- KMS key policies — https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- Rotating AWS KMS keys — https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- Encryption context — https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#encrypt_context
- AWS KMS Cryptographic Details — https://docs.aws.amazon.com/kms/latest/cryptographic-details/intro.html
- AWS CloudHSM User Guide — https://docs.aws.amazon.com/cloudhsm/latest/userguide/introduction.html
- AWS Certificate Manager User Guide — https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- The Security Design of the AWS Nitro System — https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/security-design-of-aws-nitro-system.html

**Auditoría y detección**
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- Validating CloudTrail log file integrity — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- Creating a trail for an organization — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/creating-trail-organization.html
- AWS Config Developer Guide — https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
- AWS Config managed rules — https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html
- Conformance packs — https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html
- Amazon GuardDuty User Guide — https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- Amazon Inspector User Guide — https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
- Amazon Macie User Guide — https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
- Amazon Detective User Guide — https://docs.aws.amazon.com/detective/latest/userguide/what-is-detective.html
- AWS Security Hub User Guide — https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
- AWS Audit Manager User Guide — https://docs.aws.amazon.com/audit-manager/latest/userguide/what-is.html
- Amazon Security Lake User Guide — https://docs.aws.amazon.com/security-lake/latest/userguide/what-is-security-lake.html
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- AWS Trusted Advisor — https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html

**Cumplimiento y soberanía**
- AWS Cloud Compliance — https://aws.amazon.com/compliance/
- AWS Compliance Programs — https://aws.amazon.com/compliance/programs/
- AWS Artifact User Guide — https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
- Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Digital Sovereignty — https://aws.amazon.com/compliance/digital-sovereignty/
- Data Privacy FAQ (data residency) — https://aws.amazon.com/compliance/data-privacy-faq/
- AWS GovCloud (US) User Guide — https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/whatis.html
- AWS Well-Architected Framework — Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Security Reference Architecture (AWS SRA) — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html