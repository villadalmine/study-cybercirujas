# 3.7 — Servicios de IA/ML y analítica de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02, v1.0)
**Dominio:** 3 — Tecnología y servicios en la nube
**Peso del enunciado de tarea:** 4.25 % del examen
**Perfil de audiencia:** Platform Architect / SRE. El examen pregunta *qué servicio*; producción pregunta *a qué costo, con qué modo de fallo y quién es dueño de los datos*. Esta unidad responde ambas cosas, y marca claramente cuál es cuál.

---

## 1. Motivación: el problema arquitectónico que este dominio existe para resolver

### 1.1 Los dos pipelines que siempre aparecen

Toda plataforma que maneja datos termina desarrollando dos pipelines que parecen distintos pero comparten un sustrato:

```
                     ┌──────────────────────────────────────────────┐
   producers ───────►│  INGEST      Kinesis Data Streams / MSK /    │
   (apps, agents,    │              Data Firehose / DMS / DataSync  │
    IoT, logs, CDC)  └───────────────┬──────────────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────────────┐
                     │  STORE       Amazon S3 (object, 11 nines)    │
                     │              + open table format (Iceberg)   │
                     └───────────────┬──────────────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────────────┐
                     │  CATALOG &   AWS Glue Data Catalog           │
                     │  GOVERN      AWS Lake Formation (LF-Tags)    │
                     └───────┬───────────────────────┬──────────────┘
                             │                       │
        ┌────────────────────▼─────┐     ┌───────────▼────────────────┐
        │ ANALYTICS PLANE          │     │ AI/ML PLANE                │
        │ Athena · EMR · Redshift  │     │ Bedrock (FM API)           │
        │ OpenSearch · MSAF (Flink)│     │ SageMaker AI (build/train) │
        │ QuickSight (BI)          │     │ AI services (Comprehend,   │
        │                          │     │   Textract, Rekognition…)  │
        └──────────────────────────┘     └────────────────────────────┘
```

La decisión arquitectónica que gobierna ambos planos es la **separación entre almacenamiento y cómputo**. S3 es el piso durable, barato y neutral respecto del formato; cada motor por encima es elástico y descartable. Esa es toda la razón por la que un data lake le gana a un warehouse monolítico para un equipo de plataforma: podés correr Athena, EMR Spark, Redshift Spectrum y una Knowledge Base de Bedrock sobre *los mismos bytes* sin copiarlos, y podés borrar un motor un viernes sin perder datos.

### 1.2 Los tres modos de fallo de los que realmente trata este dominio

| Modo de fallo | Cómo se ve en producción | Qué elección de servicio lo evita |
|---|---|---|
| **Gravedad de datos / proliferación de copias** | Seis equipos mantienen cada uno un extracto privado de `events`; cuatro no coinciden en los números del mes pasado | Un solo lake en S3 + Glue Data Catalog como metastore único; Lake Formation para los permisos en lugar de copias por equipo |
| **Trabajo pesado indiferenciado** | Un equipo de SRE opera un clúster Kafka de 40 nodos y una flota de GPU para hacer análisis de sentimiento sobre 200 k tickets/mes | MSK (Kafka gestionado) o Firehose (ningún clúster); Comprehend en lugar de un modelo autoalojado |
| **Costo ilimitado e invisible** | Una única consulta de Athena sin particionar escanea 14 TB; un índice Kendra Developer olvidado factura ~$800/mes estando ocioso | `BytesScannedCutoffPerQuery` en el workgroup, partition projection, Budgets + `AWS::CE::AnomalyMonitor`, y saber qué servicios facturan por *existir* frente a los que facturan por *usarse* |

Esa última columna es la parte relevante para SRE del enunciado de tarea 3.7. El examen evalúa reconocimiento; el trabajo evalúa la tercera columna.

### 1.3 El eje más importante: ¿cuánto del stack de ML es tuyo?

AWS estratifica IA/ML en tres niveles. **Casi toda pregunta de escenario de CLF-C02 te está pidiendo ubicar un requisito en esta escalera.**

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ TIER 3 — AI SERVICES / APPLICATIONS                             │
  │ You call an API. AWS owns the model, training data, ops.        │
  │ Rekognition · Textract · Transcribe · Translate · Polly ·       │
  │ Comprehend · Lex · Kendra · Personalize · Fraud Detector ·      │
  │ Amazon Q (Developer / Business)                                 │
  │ Skill needed: none in ML. Time to value: hours.                 │
  ├─────────────────────────────────────────────────────────────────┤
  │ TIER 2 — MANAGED FM / PLATFORM                                  │
  │ You own the prompt, the data, the guardrails, the evaluation.   │
  │ AWS owns the model weights and the serving fleet.               │
  │ Amazon Bedrock (FM API, Knowledge Bases, Agents, Guardrails)    │
  │ Amazon SageMaker AI (notebooks, training jobs, endpoints,       │
  │   Feature Store, Pipelines, Model Monitor, JumpStart)           │
  │ Skill needed: ML/prompt engineering. Time to value: days–weeks. │
  ├─────────────────────────────────────────────────────────────────┤
  │ TIER 1 — INFRASTRUCTURE & FRAMEWORKS                            │
  │ You own everything above the hypervisor.                        │
  │ EC2 P5/G6/Trn2/Inf2 · EKS + Neuron/NVIDIA device plugins ·      │
  │ AWS Trainium / AWS Inferentia · Deep Learning AMIs & Containers │
  │ Skill needed: deep. Time to value: weeks–months.                │
  └─────────────────────────────────────────────────────────────────┘
```

**Heurística de examen:** la respuesta correcta es el *nivel más alto que satisface el requisito enunciado*. "Extraer texto de facturas escaneadas" → Tier 3 (Textract), no "entrenar un modelo en SageMaker". "Ajustar (fine-tune) sobre nuestro dataset etiquetado propietario con una loss personalizada" → Tier 2 (SageMaker AI). Solo un "necesitamos un kernel CUDA propio / una compilación específica del framework" explícito te empuja al Tier 1.

---

## 2. Los servicios de IA/ML, con sus compromisos

### 2.1 Tier 3 — Servicios de IA (API gestionada, sin experiencia en ML)

| Servicio | Modalidad | Trabajo principal | Síncrono / Asíncrono | Soporte de modelo personalizado | Frase disparadora clásica del examen |
|---|---|---|---|---|---|
| **Amazon Rekognition** | Imagen, video | Etiquetas de objetos/escenas, rostros, moderación, texto en imagen, EPP | Ambos (asíncrono para video almacenado) | Custom Labels | "detectar imágenes inapropiadas", "contar personas en un video" |
| **Amazon Textract** | Documento | OCR + **estructura**: formularios (clave/valor), tablas, firmas, queries | Síncrono (1 página) / Asíncrono (PDF de varias páginas) | Adapters (Custom Queries) | "extraer campos de formularios/facturas escaneados" |
| **Amazon Transcribe** | Audio → texto | ASR, diarización de hablantes, redacción de PII, analítica médica/de llamadas | Ambos (streaming + batch) | Vocabulario personalizado, modelo de lenguaje personalizado | "generar subtítulos", "transcribir llamadas de soporte" |
| **Amazon Polly** | Texto → audio | TTS; motores standard / neural / long-form / generative; SSML; speech marks | Síncrono (+ asíncrono para textos largos) | Brand Voice (personalizada, vía AWS) | "convertir artículos a voz", "prompts de IVR" |
| **Amazon Translate** | Texto → texto | Traducción automática neuronal, más de 75 idiomas, controles de formalidad y groserías | Ambos | Active Custom Translation, terminología personalizada | "localizar la UI/el contenido a N idiomas" |
| **Amazon Comprehend** | Texto | Sentimiento, entidades, frases clave, idioma, **detección de PII**, modelado de temas | Ambos | Clasificación personalizada, reconocimiento de entidades personalizado | "analizar el sentimiento de las reseñas", "encontrar PII en documentos" |
| **Amazon Lex** | Conversacional | Bots con ASR + NLU, intents/slots; impulsa el IVR de Connect | Síncrono | A nivel de bot (vos escribís los intents) | "construir un chatbot", "IVR por voz" |
| **Amazon Kendra** | Búsqueda | Búsqueda semántica empresarial sobre conectores (S3, SharePoint, Confluence…), consciente de ACL | Síncrono | Ajuste de relevancia, sinónimos personalizados | "búsqueda en lenguaje natural sobre documentos internos" |
| **Amazon Personalize** | Recomendación | Personalización en tiempo real, ítems similares, ranking | Síncrono (campaign) / batch | Vos aportás el dataset de interacciones | "recomendaciones de productos como las de Amazon.com" |
| **Amazon Fraud Detector** | Tabular | Puntuación de fraude/abuso en línea a partir de datos históricos de fraude | Síncrono | Vos aportás los eventos etiquetados | "detectar cuentas/pagos fraudulentos nuevos" |
| **Amazon Augmented AI (A2I)** | Bucle humano | Deriva predicciones de baja confianza a revisores humanos | Flujo asíncrono | n/a | "revisión humana cuando la confianza es baja" |

> **Advertencia de vigencia (relevante para SRE, irrelevante para el examen).** AWS cerró varios servicios de IA antiguos a nuevos clientes o anunció su fin de soporte después de que se publicara la guía del examen CLF-C02 v1.0 — entre ellos **Amazon Forecast**, **Amazon Lookout for Metrics**, **Amazon Monitron** y **Amazon DeepComposer**; **Amazon CodeGuru Reviewer** y **Amazon CodeWhisperer** se integraron en **Amazon Q Developer**. Para el examen, tratalos como "el servicio de pronóstico", "el servicio de detección de anomalías", etc. Para un diseño real, consultá la página de FAQ del servicio antes de construir sobre él. Renombres que **sí** vas a ver en el examen con el nombre viejo: **Kinesis Data Firehose → Amazon Data Firehose**, **Kinesis Data Analytics → Amazon Managed Service for Apache Flink**, **Amazon Elasticsearch Service → Amazon OpenSearch Service**, **Amazon SageMaker → Amazon SageMaker AI** (la plataforma de ML).

### 2.2 Tier 2 — Bedrock frente a SageMaker AI: la decisión que realmente cuesta dinero

| Dimensión | **Amazon Bedrock** | **Amazon SageMaker AI** |
|---|---|---|
| Unidad de trabajo | Una llamada a la API de un foundation model alojado | Un training job, un processing job, un endpoint que vos dimensionás |
| Qué aprovisionás | Nada (bajo demanda) o *Provisioned Throughput* en Model Units | Instancias: `ml.g6.xlarge`, `ml.p5.48xlarge`, `ml.m5.large`… |
| Forma de facturación | **Por token** (entrada/salida), o por MU-hora si es aprovisionado | **Por instancia-segundo**, llegue o no tráfico |
| Costo en reposo | **Cero** bajo demanda | Costo completo del endpoint 24×7 salvo serverless/asíncrono |
| Arranque en frío | Ninguno (bajo demanda) | Creación/actualización de endpoint: minutos; Serverless Inference: segundos |
| Elección de modelo | Anthropic, Meta, Mistral, Cohere, AI21, Stability, Amazon Nova/Titan, DeepSeek… | Cualquier cosa que puedas containerizar; JumpStart para modelos preconstruidos |
| Personalización | Prompting → RAG (Knowledge Bases) → fine-tuning → continued pre-training | Total: arquitecturas propias, loss personalizada, entrenamiento distribuido |
| Aislamiento de datos | Tus prompts/completions **no** se usan para entrenar los modelos base; las copias ajustadas son privadas de tu cuenta | Tu VPC, tus contenedores, tus pesos |
| Controles de seguridad | **Guardrails** (filtros de contenido, temas denegados, PII, grounding contextual) como recurso de primera clase, independiente del modelo | Lo construís vos |
| Adecuado para | Funciones de GenAI, RAG, agentes, resumen, clasificación por prompt | ML clásico (tabular, pronóstico, visión), deep learning a medida, latencia/costo estrictos con QPS alto y sostenido |

**El punto de cruce.** Bedrock bajo demanda le gana a un endpoint dedicado hasta que la utilización es alta y sostenida. Una regla aproximada de producción: si un endpoint de clase `ml.g6.xlarge` estuviera por encima de ~60 % de utilización 24×7, una opción autoalojada o de provisioned throughput empieza a ganar; por debajo de eso gana el pago por token bajo demanda, y gana *enormemente* en cargas con picos (un batch nocturno que corre 20 minutos paga 20 minutos, no 24 horas).

**Funciones de producción de Bedrock que tenés que saber que existen:**

| Función | Problema que resuelve |
|---|---|
| **Knowledge Bases** | RAG gestionado: S3 → chunk → embedding → vector store (OpenSearch Serverless / Aurora pgvector / Pinecone / Neptune Analytics) → `RetrieveAndGenerate` con citas |
| **Agents** | Uso de herramientas en varios pasos: action groups respaldados por Lambda + esquema OpenAPI |
| **Guardrails** | Política independiente del modelo: filtros de contenido, temas denegados, filtros de palabras, anonimización/bloqueo de PII, **grounding contextual** (chequeo de alucinaciones contra el contexto recuperado) |
| **Model Evaluation** | Trabajos de evaluación automática y humana para comparar modelos candidatos sobre tus datos |
| **Provisioned Throughput** | TPS garantizado, requerido para algunos modelos personalizados/ajustados |
| **Perfiles de inferencia entre regiones** | Enruta una petición entre regiones de una geografía por capacidad/resiliencia ante throttling; IDs de modelo con prefijo `us.`, `eu.`, `apac.` |
| **Inferencia por lotes** | ~50 % más barato para trabajos masivos tolerantes a latencia, S3 de entrada / S3 de salida |
| **Prompt caching / Prompt management / Flows** | Reducción de costo sobre contexto repetido; prompts versionados; orquestación visual |

**Amazon Q** se ubica por encima de Bedrock como una aplicación terminada: **Q Developer** (programación en el IDE, `/dev`, transformación de código, agente de CLI) y **Q Business** (asistente empresarial sobre conectores con ACL conscientes de la identidad, integrado con IAM Identity Center). Pista de examen: "los empleados hacen preguntas en lenguaje natural sobre documentos de la empresa, respetando los permisos existentes" → **Amazon Q Business** (o Kendra si el requisito habla de *resultados de búsqueda*, no de *respuestas generadas*).

### 2.3 Tier 1 — economía de los aceleradores

| Chip / familia | Propósito | Instancia | Notas |
|---|---|---|---|
| **AWS Trainium** (Trn1/Trn2) | Entrenamiento | `trn1.32xlarge`, `trn2.48xlarge` | Silicio de AWS; mejor $/token entrenado vía el Neuron SDK |
| **AWS Inferentia** (Inf1/Inf2) | Inferencia | `inf2.xlarge` … `inf2.48xlarge` | Silicio de AWS; menor $/inferencia para los modelos soportados |
| **NVIDIA** | Ambos | `g6`/`g6e` (L4/L40S), `p5`/`p5e` (H100/H200) | La compatibilidad de frameworks más amplia; el precio más alto |

Conclusión a nivel examen: **Trainium = entrenar, Inferentia = inferir, ambos = silicio diseñado por AWS para bajar el costo.** Conclusión a nivel plataforma: Neuron requiere compilar el modelo (`torch-neuronx`) y no toda arquitectura está soportada — validalo antes de comprometer una flota.

---

## 3. Los servicios de analítica, con sus compromisos

### 3.1 Ingesta: la familia Kinesis y MSK (la pregunta de examen que más se falla en este dominio)

| Servicio | Modelo | Qué gestionás | Retención | Replay | Consumidores | Usalo cuando |
|---|---|---|---|---|---|---|
| **Kinesis Data Streams** | Shards ordenados, pull | Cantidad de shards (provisioned) o nada (on-demand) | 24 h → 365 d | **Sí** | Muchos, independientes, a su propio ritmo | Varios equipos necesitan el mismo stream; necesitás replay y orden por clave |
| **Amazon Data Firehose** *(ex-Kinesis Data Firehose)* | Entrega con búfer, push | **Nada** | Ninguna (transitoria) | **No** | Exactamente un destino | "Simplemente depositalo en S3/Redshift/OpenSearch/Splunk/Iceberg" con conversión de formato |
| **Managed Service for Apache Flink** *(ex-Kinesis Data Analytics)* | Procesamiento de stream con estado | Paralelismo / KPUs | n/a | vía la fuente | n/a | Agregaciones por ventana, joins, detección de anomalías **sobre el stream** |
| **Kinesis Video Streams** | Ingesta de medios | Nada | Configurable | Sí | Rekognition Video, reproductores HLS/DASH | Pipelines de cámaras/medios |
| **Amazon MSK** | Apache Kafka | Dimensionamiento de brokers (o MSK Serverless) | Configurable | **Sí** | Ecosistema Kafka | Ya tenés clientes/Connect/Streams de Kafka y querés compatibilidad |

La trampa canónica: *"transmitir datos a S3 con mínima sobrecarga operativa / sin código"* → **Data Firehose**. *"Varias aplicaciones deben procesar los mismos registros, y debemos poder reprocesar los últimos 3 días"* → **Kinesis Data Streams**. *"Los productores Kafka existentes deben funcionar sin cambios"* → **MSK**.

**Detalle del modelo de capacidad que muerde a los SRE:** un shard de Kinesis Data Streams admite 1 MB/s o 1 000 registros/s **de entrada**, y 2 MB/s **de salida** compartidos entre los consumidores estándar (Enhanced Fan-Out le da a cada consumidor sus propios 2 MB/s). Las claves de partición calientes crean shards calientes, y un shard caliente sufre throttling *aun cuando el promedio del stream está al 5 % de utilización*. El modo **On-Demand** elimina la gestión de shards (escala hasta 200 MB/s de entrada, duplicando dentro de los 15 min de un nuevo pico) con un sobrecosto de aproximadamente 30–40 % con utilización alta y estable — es el valor por defecto correcto para tráfico desconocido o con picos, y el equivocado para un flujo plano y predecible de 24×7.

### 3.2 Consulta y procesamiento

| Servicio | Motor | Aprovisionamiento | Facturación | Clase de latencia | Bueno para | Débil en |
|---|---|---|---|---|---|---|
| **Amazon Athena** | Trino/Presto (SQL), también Spark | **Serverless** | **Por TB escaneado** (≈$5/TB, mínimo de 10 MB por consulta) | Segundos → minutos | SQL ad-hoc sobre S3, análisis de logs, exploración puntual | Dashboards de alta concurrencia; los escaneos completos repetidos se vuelven caros rápido |
| **Amazon Redshift** | Warehouse columnar MPP | Provisioned (RA3) o **Serverless** (RPUs) | Horas de nodo, u horas de RPU | Sub-segundo → segundos | Joins complejos, concurrencia de BI, vistas materializadas, Zero-ETL desde Aurora/RDS/DynamoDB | Proliferación semiestructurada; clústeres provisionados ociosos |
| **Amazon EMR** | Spark, Hive, Trino, HBase, Flink | Clústeres (EC2/EKS) o **EMR Serverless** | Horas de instancia + tarifa de EMR | Minutos → horas | ETL pesado, ingeniería de features para ML, pipelines centrados en código, economía de Spot | Cualquier cosa que ya haga un motor SQL; superficie operativa |
| **AWS Glue** | Spark serverless + Data Catalog | **Serverless** | **Horas de DPU** (≈$0.44/DPU-h) | Minutos | ETL catalogado, crawlers, ETL en streaming, DataBrew (preparación sin código) | Trabajo interactivo de larga duración; ajuste fino de Spark muy grande |
| **Amazon OpenSearch Service** | Lucene / OpenSearch | Dominios o **Serverless** | Horas de instancia u OCUs | **Milisegundos** | Búsqueda de logs, observabilidad, texto completo, **búsqueda vectorial** para RAG | Joins analíticos grandes; costo con retención alta |
| **Amazon QuickSight** | BI + motor en memoria SPICE | Serverless | **Por usuario/mes** + GB de SPICE | Sub-segundo (SPICE) | Dashboards, analítica embebida, **Q** (preguntas en lenguaje natural), informes con maquetación exacta | Ser un motor de consulta — lee *desde* los de arriba |

**El límite entre Athena y Redshift, planteado como corresponde.** El costo de Athena es función de los *bytes escaneados*; el de Redshift, del *tiempo aprovisionado*. Una consulta ejecutada una vez al día sobre 50 GB es trivialmente barata en Athena y absurda en un clúster 24×7. La misma consulta ejecutada 4 000 veces por día por un dashboard es al revés. Redshift Serverless (auto-pausa, facturación de RPU por segundo, piso de 8 RPU) reduce buena parte de esa brecha — la regla moderna es: **Athena para exploración y escaneos infrecuentes; Redshift para BI gobernado, concurrente y con joins; EMR/Glue para transformación; OpenSearch para la aguja en el pajar y búsquedas sub-segundo.**

### 3.3 Catalogar, gobernar, compartir

| Servicio | Rol |
|---|---|
| **AWS Glue Data Catalog** | El metastore compatible con Hive. **Un catálogo por cuenta por región**, compartido por Athena, EMR, Redshift Spectrum, Glue y Lake Formation. Tablas = esquema + ubicación en S3 + particiones + SerDe |
| **AWS Glue crawlers** | Infieren esquema y particiones desde S3. Cómodos; también la fuente n.º 1 de tablas sorpresa y deriva de esquema |
| **AWS Lake Formation** | Autorización de grano fino (base de datos/tabla/**columna**/fila/celda) vía LF-Tags, sobre Glue Catalog + S3. Reemplaza al "escribir 200 políticas de bucket de S3" |
| **Amazon DataZone / SageMaker Catalog** | Catálogo de datos de negocio, dominios, flujos de publicación/suscripción, productos de datos entre cuentas |
| **AWS Data Exchange** | Encontrar, suscribirse y usar datasets de **terceros** (entregados a S3, Redshift o vía API) |
| **AWS Clean Rooms** | Dos partes cruzan datos para analizarlos **sin que ninguna copie ni vea las filas crudas de la otra** |
| **AWS Glue DataBrew** | Preparación de datos visual y sin código (más de 250 transformaciones) para analistas |

Pistas de examen: "comprar/suscribirse a datos de mercado externos" → **Data Exchange**. "colaborar con un socio sobre clientes en común sin compartir PII" → **Clean Rooms**. "dar acceso a un equipo solo a las columnas sin PII de una tabla" → **Lake Formation**.

### 3.4 Resumen del modelo de costos — qué servicios facturan por *existir*

Esta tabla es la que ahorra dinero de verdad. Precios de lista, `us-east-1`, y cambian — la **forma** es la parte durable, los números son solo para calibrar (verificalos en §8).

| Servicio | ¿Factura estando ocioso? | Principal generador de costo | Control del radio de impacto |
|---|---|---|---|
| Athena | No | Bytes escaneados | `BytesScannedCutoffPerQuery` del workgroup; particionado; formato columnar |
| Glue jobs / crawlers | No | Horas de DPU (mínimo de 1 min) | `MaxCapacity`/cantidad de workers; frecuencia del crawler; usar partition projection en su lugar |
| Data Firehose | No | GB ingeridos (~$0.029/GB los primeros 500 TB) | Buffering hints; compresión |
| Kinesis Data Streams (provisioned) | **Sí** — por hora de shard | Horas de shard (~$0.015) + unidades PUT | Dimensionar bien los shards; On-Demand para tráfico con picos |
| Kinesis Data Streams (on-demand) | **Sí** — por hora de stream (~$0.04) | GB de entrada/salida | Eliminar streams sin uso |
| Redshift provisioned | **Sí** — horas de nodo | Tipo de nodo × cantidad | Pausar el clúster; RA3 + Spectrum |
| Redshift Serverless | No (auto-pausa) | Horas de RPU (~$0.36) | Piso de RPU base, tope máximo de RPU, límites de uso |
| Clúster EMR | **Sí** — horas de instancia | Instancias + recargo de EMR | Auto-terminación, nodos task en Spot, EMR Serverless |
| Dominio OpenSearch | **Sí** — horas de instancia + EBS | Cantidad/tipo de nodos, almacenamiento | Niveles UltraWarm/Cold; OCUs de OpenSearch Serverless |
| QuickSight | **Sí** — por usuario/mes | Autores, lectores, GB de SPICE | Precio por capacidad de lectores; eliminar autores inactivos |
| Kendra | **Sí** — por hora de índice (Developer ≈ $1.13/h ≈ **$820/mes ocioso**) | Edición del índice | Borrar los índices de desarrollo cada noche; este es el susto de factura clásico |
| Endpoint en tiempo real de SageMaker | **Sí** — horas de instancia | Tipo de instancia × cantidad | Serverless Inference; Async Inference (escala a cero); auto-scaling |
| Bedrock bajo demanda | **No** | Tokens de entrada/salida | Guardrails + `maxTokens`; modo batch; prompt caching |
| Bedrock Provisioned Throughput | **Sí** — horas de MU | Model units × compromiso | Comprarlo solo después de medir el TPS sostenido |

---

## 4. Infraestructura completa: tres manifiestos de nivel productivo

### 4.1 Stack A — Lakehouse de streaming: Kinesis → Firehose (Parquet, particiones dinámicas) → Glue Catalog → Athena

CloudFormation completo y desplegable. Esta es la implementación de referencia del camino ingesta→almacenamiento→catálogo→consulta.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Streaming lakehouse - Kinesis Data Streams -> Amazon Data Firehose
  (JSON -> Parquet, dynamic partitioning) -> S3 -> Glue Data Catalog -> Athena.
  Cost guardrails and delivery-freshness alarms included.

Parameters:
  ProjectName:
    Type: String
    Default: teach-plat
    AllowedPattern: '^[a-z][a-z0-9-]{2,32}$'
    Description: Lowercase prefix used for every resource name.
  RetentionHours:
    Type: Number
    Default: 24
    MinValue: 24
    MaxValue: 8760
    Description: Kinesis stream retention. 24h is free; beyond that is billed extra.
  AthenaScanCapBytes:
    Type: Number
    Default: 107374182400   # 100 GiB per query = ~USD 0.50 at 5 USD/TB
    Description: Hard per-query scan ceiling enforced by the Athena workgroup.
  DataFreshnessThresholdSeconds:
    Type: Number
    Default: 900
    Description: Alarm if Firehose has undelivered data older than this.

Resources:

  # ---------------------------------------------------------------- KMS ----
  LakeKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${ProjectName} lakehouse at-rest encryption'
      EnableKeyRotation: true
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableAccountRoot
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowServiceUse
            Effect: Allow
            Principal:
              Service:
                - firehose.amazonaws.com
                - athena.amazonaws.com
                - glue.amazonaws.com
            Action:
              - kms:Decrypt
              - kms:GenerateDataKey
              - kms:DescribeKey
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId

  LakeKeyAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${ProjectName}-lake'
      TargetKeyId: !Ref LakeKey

  # ----------------------------------------------------------------- S3 ----
  LakeBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-lake-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - BucketKeyEnabled: true          # cuts KMS request cost by ~99%
            ServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
              KMSMasterKeyID: !Ref LakeKey
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration:
        Status: Enabled
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      LifecycleConfiguration:
        Rules:
          - Id: expire-athena-results
            Status: Enabled
            Prefix: athena-results/
            ExpirationInDays: 14
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 3
          - Id: tier-curated-data
            Status: Enabled
            Prefix: curated/
            Transitions:
              - StorageClass: INTELLIGENT_TIERING
                TransitionInDays: 0
            NoncurrentVersionExpirationInDays: 30
          - Id: expire-quarantine
            Status: Enabled
            Prefix: quarantine/
            ExpirationInDays: 30

  LakeBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref LakeBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt LakeBucket.Arn
              - !Sub '${LakeBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  # --------------------------------------------------------- Glue meta ----
  GlueDatabase:
    Type: AWS::Glue::Database
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseInput:
        Name: !Sub '${ProjectName}_lakehouse'
        Description: Curated event tables backed by S3 Parquet.
        LocationUri: !Sub 's3://${LakeBucket}/curated/'

  # The schema is declared explicitly: Firehose data-format conversion READS
  # this table to build the Parquet writer. A crawler cannot be the source of
  # truth here, because it would run AFTER the data is already written.
  EventsTable:
    Type: AWS::Glue::Table
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseName: !Ref GlueDatabase
      TableInput:
        Name: events
        TableType: EXTERNAL_TABLE
        Parameters:
          classification: parquet
          'parquet.compression': SNAPPY
          # Partition projection: Athena derives partitions from the prefix
          # pattern instead of reading them from the catalog. No crawler, no
          # MSCK REPAIR, no per-partition GetPartitions latency.
          'projection.enabled': 'true'
          'projection.dt.type': date
          'projection.dt.range': '2026-01-01,NOW'
          'projection.dt.format': 'yyyy-MM-dd'
          'projection.dt.interval': '1'
          'projection.dt.interval.unit': DAYS
          'projection.tenant.type': injected
          'storage.location.template':
            !Sub 's3://${LakeBucket}/curated/events/dt=${!dt}/tenant=${!tenant}'
        PartitionKeys:
          - { Name: dt,     Type: string }
          - { Name: tenant, Type: string }
        StorageDescriptor:
          Location: !Sub 's3://${LakeBucket}/curated/events/'
          InputFormat: org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat
          OutputFormat: org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat
          Compressed: true
          SerdeInfo:
            SerializationLibrary: org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe
            Parameters:
              'serialization.format': '1'
          Columns:
            - { Name: event_id,   Type: string }
            - { Name: event_time, Type: string }
            - { Name: tenant_id,  Type: string }
            - { Name: user_id,    Type: string }
            - { Name: action,     Type: string }
            - { Name: cert_id,    Type: string }
            - { Name: topic_id,   Type: string }
            - { Name: latency_ms, Type: bigint }
            - { Name: status,     Type: string }
            - { Name: attributes, Type: 'map<string,string>' }

  # ------------------------------------------------------------ Kinesis ----
  IngestStream:
    Type: AWS::Kinesis::Stream
    Properties:
      Name: !Sub '${ProjectName}-events'
      StreamModeDetails:
        StreamMode: ON_DEMAND        # no shard management; scales with traffic
      RetentionPeriodHours: !Ref RetentionHours
      StreamEncryption:
        EncryptionType: KMS
        KeyId: !Ref LakeKey

  # ----------------------------------------------------------- Firehose ----
  FirehoseLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub '/aws/kinesisfirehose/${ProjectName}'
      RetentionInDays: 30

  FirehoseLogStream:
    Type: AWS::Logs::LogStream
    Properties:
      LogGroupName: !Ref FirehoseLogGroup
      LogStreamName: S3Delivery

  FirehoseRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: firehose.amazonaws.com }
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'sts:ExternalId': !Ref AWS::AccountId
      Policies:
        - PolicyName: firehose-delivery
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - s3:AbortMultipartUpload
                  - s3:GetBucketLocation
                  - s3:GetObject
                  - s3:ListBucket
                  - s3:ListBucketMultipartUploads
                  - s3:PutObject
                Resource:
                  - !GetAtt LakeBucket.Arn
                  - !Sub '${LakeBucket.Arn}/*'
              - Effect: Allow
                Action:
                  - kinesis:DescribeStream
                  - kinesis:GetShardIterator
                  - kinesis:GetRecords
                  - kinesis:ListShards
                Resource: !GetAtt IngestStream.Arn
              - Effect: Allow            # required for data-format conversion
                Action:
                  - glue:GetTable
                  - glue:GetTableVersion
                  - glue:GetTableVersions
                Resource:
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:catalog'
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:database/${GlueDatabase}'
                  - !Sub 'arn:${AWS::Partition}:glue:${AWS::Region}:${AWS::AccountId}:table/${GlueDatabase}/events'
              - Effect: Allow
                Action:
                  - kms:Decrypt
                  - kms:GenerateDataKey
                Resource: !GetAtt LakeKey.Arn
              - Effect: Allow
                Action:
                  - logs:PutLogEvents
                Resource: !GetAtt FirehoseLogGroup.Arn

  DeliveryStream:
    Type: AWS::KinesisFirehose::DeliveryStream
    Properties:
      DeliveryStreamName: !Sub '${ProjectName}-events-to-lake'
      DeliveryStreamType: KinesisStreamAsSource
      KinesisStreamSourceConfiguration:
        KinesisStreamARN: !GetAtt IngestStream.Arn
        RoleARN: !GetAtt FirehoseRole.Arn
      ExtendedS3DestinationConfiguration:
        BucketARN: !GetAtt LakeBucket.Arn
        RoleARN: !GetAtt FirehoseRole.Arn
        # Prefix keys MUST match the Glue PartitionKeys, in the same order.
        Prefix: 'curated/events/dt=!{partitionKeyFromQuery:dt}/tenant=!{partitionKeyFromQuery:tenant}/'
        # CRITICAL: the error prefix lives OUTSIDE the table location.
        # Quarantined JSON under a Parquet table location breaks every query
        # with HIVE_CURSOR_ERROR: Not valid Parquet file.
        ErrorOutputPrefix: 'quarantine/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/'
        BufferingHints:
          IntervalInSeconds: 60      # dynamic partitioning requires >= 60
          SizeInMBs: 128             # target ~128 MB objects: fewer, larger files
        CompressionFormat: UNCOMPRESSED   # MUST be UNCOMPRESSED when converting
                                          # to Parquet (Parquet compresses itself)
        EncryptionConfiguration:
          KMSEncryptionConfig:
            AWSKMSKeyARN: !GetAtt LakeKey.Arn
        DynamicPartitioningConfiguration:
          Enabled: true                   # cannot be enabled after creation
          RetryOptions:
            DurationInSeconds: 300
        ProcessingConfiguration:
          Enabled: true
          Processors:
            - Type: MetadataExtraction
              Parameters:
                - ParameterName: MetadataExtractionQuery
                  ParameterValue: '{dt:.event_time[0:10],tenant:.tenant_id}'
                - ParameterName: JsonParsingEngine
                  ParameterValue: JQ-1.6
        DataFormatConversionConfiguration:
          Enabled: true
          SchemaConfiguration:
            CatalogId: !Ref AWS::AccountId
            DatabaseName: !Ref GlueDatabase
            TableName: events
            Region: !Ref AWS::Region
            RoleARN: !GetAtt FirehoseRole.Arn
            VersionId: LATEST
          InputFormatConfiguration:
            Deserializer:
              OpenXJsonSerDe:
                CaseInsensitive: false
          OutputFormatConfiguration:
            Serializer:
              ParquetSerDe:
                Compression: SNAPPY
                WriterVersion: V1
        CloudWatchLoggingOptions:
          Enabled: true
          LogGroupName: !Ref FirehoseLogGroup
          LogStreamName: !Ref FirehoseLogStream
      Tags:
        - { Key: Project, Value: !Ref ProjectName }
        - { Key: DataClassification, Value: internal }

  # ------------------------------------------------------------- Athena ----
  AnalyticsWorkGroup:
    Type: AWS::Athena::WorkGroup
    Properties:
      Name: !Sub '${ProjectName}-analytics'
      Description: Governed workgroup with a hard per-query scan ceiling.
      State: ENABLED
      RecursiveDeleteOption: true
      WorkGroupConfiguration:
        EnforceWorkGroupConfiguration: true      # users cannot override
        PublishCloudWatchMetricsEnabled: true
        BytesScannedCutoffPerQuery: !Ref AthenaScanCapBytes
        RequesterPaysEnabled: false
        EngineVersion:
          SelectedEngineVersion: AUTO
        ResultConfiguration:
          OutputLocation: !Sub 's3://${LakeBucket}/athena-results/'
          EncryptionConfiguration:
            EncryptionOption: SSE_KMS
            KmsKey: !GetAtt LakeKey.Arn
          ExpectedBucketOwner: !Ref AWS::AccountId

  # ------------------------------------------------------------- Alarms ----
  AlarmTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub '${ProjectName}-analytics-alarms'
      KmsMasterKeyId: !Ref LakeKey

  FirehoseFreshnessAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-firehose-data-freshness'
      AlarmDescription: >
        Oldest undelivered record exceeds the freshness SLO. Root causes, in
        order of frequency: S3/KMS permission denial, Glue schema mismatch,
        dynamic-partition key missing from the payload.
      Namespace: AWS/Firehose
      MetricName: DeliveryToS3.DataFreshness
      Dimensions:
        - Name: DeliveryStreamName
          Value: !Ref DeliveryStream
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: !Ref DataFreshnessThresholdSeconds
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions: [ !Ref AlarmTopic ]

  FirehoseConversionFailureAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-firehose-format-conversion-failed'
      Namespace: AWS/Firehose
      MetricName: FailedConversion.Records
      Dimensions:
        - Name: DeliveryStreamName
          Value: !Ref DeliveryStream
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

  KinesisIteratorAgeAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-kinesis-consumer-lag'
      AlarmDescription: Consumers are falling behind; data loss once age > retention.
      Namespace: AWS/Kinesis
      MetricName: GetRecords.IteratorAgeMilliseconds
      Dimensions:
        - Name: StreamName
          Value: !Ref IngestStream
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: 600000          # 10 minutes
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

  KinesisWriteThrottleAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub '${ProjectName}-kinesis-write-throttled'
      AlarmDescription: Hot partition key or insufficient capacity.
      Namespace: AWS/Kinesis
      MetricName: WriteProvisionedThroughputExceeded
      Dimensions:
        - Name: StreamName
          Value: !Ref IngestStream
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 3
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [ !Ref AlarmTopic ]

Outputs:
  LakeBucketName:
    Value: !Ref LakeBucket
    Export: { Name: !Sub '${AWS::StackName}-LakeBucket' }
  StreamName:
    Value: !Ref IngestStream
    Export: { Name: !Sub '${AWS::StackName}-StreamName' }
  DeliveryStreamName:
    Value: !Ref DeliveryStream
  GlueDatabaseName:
    Value: !Ref GlueDatabase
  AthenaWorkGroup:
    Value: !Ref AnalyticsWorkGroup
  SampleQuery:
    Description: Partition-pruned query - scans one day of one tenant only.
    Value: !Sub >-
      SELECT action, count(*) AS n, approx_percentile(latency_ms, 0.95) AS p95
      FROM "${GlueDatabase}"."events"
      WHERE dt = '2026-09-03' AND tenant = 'tenant-7f3a'
      GROUP BY action ORDER BY n DESC;
```

Tres detalles de esa plantilla son los que la gente hace mal, y cada uno tiene una firma de fallo correspondiente en §6: `CompressionFormat: UNCOMPRESSED` con conversión a Parquet, `ErrorOutputPrefix` fuera de la ubicación de la tabla, y el rol de Firehose necesitando `glue:GetTableVersions` (en plural) para la búsqueda de esquema.

### 4.2 Stack B — Knowledge Base de Bedrock con Guardrails (RAG gestionado)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Managed RAG on Amazon Bedrock: S3 corpus -> Knowledge Base -> OpenSearch
  Serverless vector collection, fronted by a Guardrail with PII anonymisation
  and contextual grounding.

Parameters:
  ProjectName:
    Type: String
    Default: teach-plat
  EmbeddingModelId:
    Type: String
    Default: amazon.titan-embed-text-v2:0
  VectorIndexName:
    Type: String
    Default: bedrock-kb-index
    Description: >
      MUST already exist in the collection. CloudFormation does not create
      OpenSearch indexes; see the runbook in section 6.
  GroundingThreshold:
    Type: Number
    Default: 0.75
    Description: Below this, the answer is treated as ungrounded and blocked.

Resources:

  CorpusBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub '${ProjectName}-kb-corpus-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: { SSEAlgorithm: AES256 }
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      VersioningConfiguration: { Status: Enabled }

  # ------------------------------------------- OpenSearch Serverless -------
  VectorCollectionEncryptionPolicy:
    Type: AWS::OpenSearchServerless::SecurityPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-enc'
      Type: encryption
      Policy: !Sub '{"Rules":[{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"]}],"AWSOwnedKey":true}'

  VectorCollectionNetworkPolicy:
    Type: AWS::OpenSearchServerless::SecurityPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-net'
      Type: network
      Policy: !Sub '[{"Rules":[{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"]},{"ResourceType":"dashboard","Resource":["collection/${ProjectName}-kb"]}],"AllowFromPublic":true}]'

  VectorCollection:
    Type: AWS::OpenSearchServerless::Collection
    DependsOn:
      - VectorCollectionEncryptionPolicy
      - VectorCollectionNetworkPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb'
      Type: VECTORSEARCH
      Description: Vector store for the Bedrock Knowledge Base.

  VectorDataAccessPolicy:
    Type: AWS::OpenSearchServerless::AccessPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb-access'
      Type: data
      Policy: !Sub
        - '[{"Rules":[{"ResourceType":"index","Resource":["index/${ProjectName}-kb/*"],"Permission":["aoss:*"]},{"ResourceType":"collection","Resource":["collection/${ProjectName}-kb"],"Permission":["aoss:*"]}],"Principal":["${RoleArn}"]}]'
        - RoleArn: !GetAtt KnowledgeBaseRole.Arn

  # ------------------------------------------------------------- IAM ------
  KnowledgeBaseRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub 'AmazonBedrockExecutionRoleForKnowledgeBase_${ProjectName}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: bedrock.amazonaws.com }
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
              ArnLike:
                'aws:SourceArn': !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}:${AWS::AccountId}:knowledge-base/*'
      Policies:
        - PolicyName: kb-permissions
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: 'bedrock:InvokeModel'
                Resource: !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}::foundation-model/${EmbeddingModelId}'
              - Effect: Allow
                Action: 'aoss:APIAccessAll'
                Resource: !GetAtt VectorCollection.Arn
              - Effect: Allow
                Action: [ 's3:GetObject', 's3:ListBucket' ]
                Resource:
                  - !GetAtt CorpusBucket.Arn
                  - !Sub '${CorpusBucket.Arn}/*'
                Condition:
                  StringEquals:
                    's3:ResourceAccount': !Ref AWS::AccountId

  # ------------------------------------------------------- Knowledge Base --
  KnowledgeBase:
    Type: AWS::Bedrock::KnowledgeBase
    DependsOn: VectorDataAccessPolicy
    Properties:
      Name: !Sub '${ProjectName}-kb'
      Description: Certification syllabi and study material corpus.
      RoleArn: !GetAtt KnowledgeBaseRole.Arn
      KnowledgeBaseConfiguration:
        Type: VECTOR
        VectorKnowledgeBaseConfiguration:
          EmbeddingModelArn: !Sub 'arn:${AWS::Partition}:bedrock:${AWS::Region}::foundation-model/${EmbeddingModelId}'
      StorageConfiguration:
        Type: OPENSEARCH_SERVERLESS
        OpensearchServerlessConfiguration:
          CollectionArn: !GetAtt VectorCollection.Arn
          VectorIndexName: !Ref VectorIndexName
          FieldMapping:
            VectorField: bedrock-knowledge-base-default-vector
            TextField: AMAZON_BEDROCK_TEXT_CHUNK
            MetadataField: AMAZON_BEDROCK_METADATA

  CorpusDataSource:
    Type: AWS::Bedrock::DataSource
    Properties:
      Name: !Sub '${ProjectName}-corpus'
      KnowledgeBaseId: !Ref KnowledgeBase
      DataDeletionPolicy: RETAIN
      DataSourceConfiguration:
        Type: S3
        S3Configuration:
          BucketArn: !GetAtt CorpusBucket.Arn
          InclusionPrefixes:
            - 'certs/'
      VectorIngestionConfiguration:
        ChunkingConfiguration:
          ChunkingStrategy: FIXED_SIZE
          FixedSizeChunkingConfiguration:
            MaxTokens: 512
            OverlapPercentage: 20

  # ------------------------------------------------------------ Guardrail --
  ContentGuardrail:
    Type: AWS::Bedrock::Guardrail
    Properties:
      Name: !Sub '${ProjectName}-guardrail'
      Description: Safety and grounding policy applied to every model call.
      BlockedInputMessaging: 'That request is outside the scope of this assistant.'
      BlockedOutputsMessaging: 'I could not produce a grounded answer from the available material.'
      ContentPolicyConfig:
        FiltersConfig:
          - { Type: HATE,          InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: INSULTS,       InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: SEXUAL,        InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: VIOLENCE,      InputStrength: MEDIUM, OutputStrength: MEDIUM }
          - { Type: MISCONDUCT,    InputStrength: HIGH,   OutputStrength: HIGH }
          - { Type: PROMPT_ATTACK, InputStrength: HIGH,   OutputStrength: NONE }
      SensitiveInformationPolicyConfig:
        PiiEntitiesConfig:
          - { Type: EMAIL,               Action: ANONYMIZE }
          - { Type: PHONE,               Action: ANONYMIZE }
          - { Type: NAME,                Action: ANONYMIZE }
          - { Type: CREDIT_DEBIT_CARD_NUMBER, Action: BLOCK }
          - { Type: AWS_ACCESS_KEY,      Action: BLOCK }
          - { Type: AWS_SECRET_KEY,      Action: BLOCK }
        RegexesConfig:
          - Name: internal-ticket-id
            Description: Redact internal ticket identifiers.
            Pattern: 'TP-[0-9]{6}'
            Action: ANONYMIZE
      TopicPolicyConfig:
        TopicsConfig:
          - Name: ExamAnswerLeakage
            Type: DENY
            Definition: >
              Requests to reproduce verbatim questions or answer keys from a
              live certification exam, or to obtain exam content under NDA.
            Examples:
              - 'Give me the real CLF-C02 questions from the exam.'
              - 'What were the answers on the test you took yesterday?'
      ContextualGroundingPolicyConfig:
        FiltersConfig:
          - { Type: GROUNDING, Threshold: !Ref GroundingThreshold }
          - { Type: RELEVANCE, Threshold: 0.60 }

  GuardrailVersion:
    Type: AWS::Bedrock::GuardrailVersion
    Properties:
      GuardrailIdentifier: !GetAtt ContentGuardrail.GuardrailId
      Description: Initial immutable version pinned by the application.

Outputs:
  KnowledgeBaseId:
    Value: !Ref KnowledgeBase
  DataSourceId:
    Value: !GetAtt CorpusDataSource.DataSourceId
  GuardrailId:
    Value: !GetAtt ContentGuardrail.GuardrailId
  GuardrailVersion:
    Value: !GetAtt GuardrailVersion.Version
  CollectionEndpoint:
    Value: !GetAtt VectorCollection.CollectionEndpoint
```

### 4.3 Stack C — Kubernetes: un gateway de inferencia en EKS que llama a Bedrock, más un node pool de Inferentia

El patrón del equipo de plataforma: mantener la aplicación en EKS, mantener el modelo en Bedrock, autenticar con IRSA — sin claves de larga duración en ninguna parte.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ai-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
# IRSA: the trust policy on this IAM role binds the OIDC subject
# system:serviceaccount:ai-platform:rag-gateway. No secrets in the cluster.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rag-gateway
  namespace: ai-platform
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eks-ai-platform-rag-gateway
    eks.amazonaws.com/sts-regional-endpoints: "true"
automountServiceAccountToken: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rag-gateway-config
  namespace: ai-platform
data:
  AWS_REGION: "eu-west-1"
  # Cross-region inference profile: the "eu." prefix lets Bedrock route the
  # request across EU regions when the home region is at capacity.
  BEDROCK_MODEL_ID: "eu.anthropic.claude-sonnet-4-20250514-v1:0"
  BEDROCK_KB_ID: "KBQ7X3P1AZ"
  BEDROCK_GUARDRAIL_ID: "gr-9k2mfp0qra41"
  BEDROCK_GUARDRAIL_VERSION: "1"
  MAX_OUTPUT_TOKENS: "1024"
  REQUEST_TIMEOUT_SECONDS: "60"
  RETRY_MAX_ATTEMPTS: "5"
  RETRY_MODE: "adaptive"        # botocore client-side throttle backoff
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-gateway
  namespace: ai-platform
  labels:
    app.kubernetes.io/name: rag-gateway
    app.kubernetes.io/component: inference-gateway
spec:
  replicas: 3
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rag-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: rag-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: rag-gateway
      containers:
        - name: gateway
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/rag-gateway:1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http,    containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          envFrom:
            - configMapRef:
                name: rag-gateway-config
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ "ALL" ]
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            # Must verify STS assume-role + a Bedrock control-plane call, not
            # just that the process is listening. An IRSA misconfiguration is
            # otherwise invisible until the first user request fails.
            httpGet: { path: /readyz, port: http }
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 20
            failureThreshold: 3
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: rag-gateway
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rag-gateway
  namespace: ai-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rag-gateway
  minReplicas: 3
  maxReplicas: 20
  metrics:
    # Bedrock calls are I/O-bound: CPU is a poor signal. Scale on in-flight
    # requests per pod, exported by the gateway itself.
    - type: Pods
      pods:
        metric: { name: bedrock_inflight_requests }
        target:
          type: AverageValue
          averageValue: "8"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - { type: Percent, value: 25, periodSeconds: 60 }
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
---
# Egress-only network policy: the gateway talks to AWS APIs and nothing else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rag-gateway-egress
  namespace: ai-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: rag-gateway
  policyTypes: [ Egress ]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [ 169.254.169.254/32 ]
      ports:
        - { protocol: TCP, port: 443 }
---
# Optional Tier-1 path: self-hosted inference on AWS Inferentia, for the
# workloads where per-token Bedrock pricing loses to sustained utilisation.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: neuron-inference
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-teach-plat
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: teach-plat }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: teach-plat }
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi        # Neuron-compiled artefacts are large
        volumeType: gp3
        throughput: 250
        deleteOnTermination: true
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required          # IMDSv2 only
    httpPutResponseHopLimit: 1
  tags:
    Project: teach-plat
    Workload: neuron-inference
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: neuron-inference
spec:
  template:
    metadata:
      labels:
        workload: neuron-inference
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: neuron-inference
      taints:
        - key: aws.amazon.com/neuron
          value: "true"
          effect: NoSchedule
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: [ "inf2" ]
        - key: karpenter.sh/capacity-type
          operator: In
          values: [ "on-demand" ]   # accelerator Spot reclaim is disruptive
        - key: kubernetes.io/arch
          operator: In
          values: [ "amd64" ]
      expireAfter: 720h
      terminationGracePeriod: 5m
  limits:
    cpu: "192"
    aws.amazon.com/neuron: "16"     # hard ceiling on accelerator spend
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 10m
    budgets:
      - nodes: "10%"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embedder-neuron
  namespace: ai-platform
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: embedder-neuron }
  template:
    metadata:
      labels: { app.kubernetes.io/name: embedder-neuron }
    spec:
      nodeSelector:
        workload: neuron-inference
      tolerations:
        - key: aws.amazon.com/neuron
          operator: Exists
          effect: NoSchedule
      containers:
        - name: server
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/embedder-neuron:0.9.1
          ports:
            - { name: http, containerPort: 8080 }
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              aws.amazon.com/neuron: 1   # exposed by the Neuron device plugin
            limits:
              cpu: "8"
              memory: 24Gi
              aws.amazon.com/neuron: 1
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            initialDelaySeconds: 60      # Neuron model load is slow
            periodSeconds: 10
```

---

## 5. CLI: comandos reales y salida real

Se asume la región `eu-west-1`, la cuenta `123456789012`, AWS CLI v2.

### 5.1 Verificar el camino de ingesta de punta a punta

```console
$ aws kinesis describe-stream-summary --stream-name teach-plat-events \
    --query 'StreamDescriptionSummary.{Mode:StreamModeDetails.StreamMode,Shards:OpenShardCount,Retention:RetentionPeriodHours,Status:StreamStatus,Enc:EncryptionType}'
{
    "Mode": "ON_DEMAND",
    "Shards": 4,
    "Retention": 24,
    "Status": "ACTIVE",
    "Enc": "KMS"
}

$ aws kinesis put-record \
    --stream-name teach-plat-events \
    --partition-key "tenant-7f3a" \
    --cli-binary-format raw-in-base64-out \
    --data '{"event_id":"e-0191c3","event_time":"2026-09-04T11:02:31Z","tenant_id":"tenant-7f3a","user_id":"u-4412","action":"lab.start","cert_id":"aws-clf","topic_id":"3.7","latency_ms":184,"status":"ok","attributes":{"region":"eu-west-1"}}'
{
    "ShardId": "shardId-000000000002",
    "SequenceNumber": "49661398472039485710294857102948571029485710294857102914",
    "EncryptionType": "KMS"
}
```

Confirmá que Firehose está consumiendo y dónde escribe:

```console
$ aws firehose describe-delivery-stream --delivery-stream-name teach-plat-events-to-lake \
    --query 'DeliveryStreamDescription.{Status:DeliveryStreamStatus,Type:DeliveryStreamType,Prefix:Destinations[0].ExtendedS3DestinationDescription.Prefix,Errors:Destinations[0].ExtendedS3DestinationDescription.ErrorOutputPrefix,DynPart:Destinations[0].ExtendedS3DestinationDescription.DynamicPartitioningConfiguration.Enabled}'
{
    "Status": "ACTIVE",
    "Type": "KinesisStreamAsSource",
    "Prefix": "curated/events/dt=!{partitionKeyFromQuery:dt}/tenant=!{partitionKeyFromQuery:tenant}/",
    "Errors": "quarantine/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/",
    "DynPart": true
}
```

Esperá un intervalo de buffering y después comprobá que los objetos aterrizaron en la partición correcta:

```console
$ aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/curated/events/dt=2026-09-04/tenant=tenant-7f3a/ --human-readable
2026-09-04 11:04:12   14.8 MiB teach-plat-events-to-lake-3-2026-09-04-11-03-11-1f0c9a3e-...parquet
2026-09-04 11:05:14   15.2 MiB teach-plat-events-to-lake-3-2026-09-04-11-04-12-8b41d772-...parquet

$ aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/quarantine/ --recursive --summarize | tail -3

Total Objects: 0
   Total Size: 0
```

Cero objetos en cuarentena es la condición de aprobado. Cualquier cosa ahí significa que hubo registros rechazados — §6.2.

### 5.2 Athena: comprobar el partition pruning y medir el costo de la consulta

```console
$ QID=$(aws athena start-query-execution \
    --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT action, count(*) AS n, approx_percentile(latency_ms, 0.95) AS p95 FROM events WHERE dt='2026-09-03' AND tenant='tenant-7f3a' GROUP BY action ORDER BY n DESC" \
    --query QueryExecutionId --output text)

$ aws athena get-query-execution --query-execution-id "$QID" \
    --query 'QueryExecution.{State:Status.State,ScannedBytes:Statistics.DataScannedInBytes,QueueMs:Statistics.QueryQueueTimeInMillis,EngineMs:Statistics.EngineExecutionTimeInMillis,TotalMs:Statistics.TotalExecutionTimeInMillis}'
{
    "State": "SUCCEEDED",
    "ScannedBytes": 44040192,
    "QueueMs": 118,
    "EngineMs": 1_642,
    "TotalMs": 1_940
}
```

44 040 192 B = 42 MiB ≈ **$0.0002** a $5/TB. Ahora la misma consulta sin el predicado de partición:

```console
$ QID2=$(aws athena start-query-execution \
    --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT action, count(*) AS n FROM events GROUP BY action" \
    --query QueryExecutionId --output text)

$ aws athena get-query-execution --query-execution-id "$QID2" \
    --query 'QueryExecution.Status.{State:State,Reason:StateChangeReason}'
{
    "State": "FAILED",
    "Reason": "Query exhausted resources at this scale factor: bytes scanned limit exceeded. This query scanned more than the 107374182400 bytes allowed by workgroup teach-plat-analytics."
}
```

El tope del workgroup hizo su trabajo: un escaneo sin límite falló a $0.50 en lugar de tener éxito a $60. **Este es el control de costos de mayor apalancamiento de todo el dominio de analítica.**

Traer los resultados:

```console
$ aws athena get-query-results --query-execution-id "$QID" \
    --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
action  n       p95
lab.start       48210   184.0
topic.view      31877   62.0
lab.complete    27044   211.0
quiz.submit     19338   97.0
video.play      11205   143.0
```

### 5.3 Glue: inspección del catálogo y una ejecución de crawler

```console
$ aws glue get-table --database-name teach_plat_lakehouse --name events \
    --query 'Table.{Cols:StorageDescriptor.Columns[].Name,Parts:PartitionKeys[].Name,Loc:StorageDescriptor.Location,Projection:Parameters."projection.enabled"}'
{
    "Cols": ["event_id","event_time","tenant_id","user_id","action","cert_id","topic_id","latency_ms","status","attributes"],
    "Parts": ["dt","tenant"],
    "Loc": "s3://teach-plat-lake-123456789012-eu-west-1/curated/events/",
    "Projection": "true"
}

$ aws glue start-crawler --name teach-plat-events-crawler
$ aws glue get-crawler --name teach-plat-events-crawler \
    --query 'Crawler.{State:State,LastStatus:LastCrawl.Status,Msg:LastCrawl.ErrorMessage,LogGroup:LastCrawl.LogGroup}'
{
    "State": "READY",
    "LastStatus": "SUCCEEDED",
    "Msg": null,
    "LogGroup": "/aws-glue/crawlers"
}
```

Con partition projection habilitado no deberías necesitar el crawler en absoluto para descubrir particiones — ese es el punto. Conservalo para detectar deriva de esquema, con una programación diaria, no horaria.

### 5.4 Bedrock: listar, invocar y ver un guardrail actuando

```console
$ aws bedrock list-foundation-models --by-provider anthropic \
    --by-inference-type ON_DEMAND \
    --query 'modelSummaries[].{Id:modelId,Name:modelName,In:inputModalities,Stream:responseStreamingSupported}' \
    --output table
---------------------------------------------------------------------------------------------
|                                    ListFoundationModels                                    |
+--------------------------------------------------+------------------+-----------+---------+
|                        Id                        |       Name       |    In     | Stream  |
+--------------------------------------------------+------------------+-----------+---------+
|  anthropic.claude-3-5-haiku-20241022-v1:0        |  Claude 3.5 Haiku|  TEXT     |  True   |
|  anthropic.claude-3-7-sonnet-20250219-v1:0       |  Claude 3.7 Sonnet| TEXT,IMAGE| True   |
|  anthropic.claude-sonnet-4-20250514-v1:0         |  Claude Sonnet 4 |TEXT,IMAGE |  True   |
+--------------------------------------------------+------------------+-----------+---------+

$ aws bedrock-runtime converse \
    --model-id eu.anthropic.claude-sonnet-4-20250514-v1:0 \
    --messages '[{"role":"user","content":[{"text":"In one sentence: when does Amazon Athena cost more than Amazon Redshift Serverless?"}]}]' \
    --inference-config '{"maxTokens":200,"temperature":0}' \
    --query '{Text:output.message.content[0].text,Stop:stopReason,In:usage.inputTokens,Out:usage.outputTokens,LatencyMs:metrics.latencyMs}'
{
    "Text": "Athena costs more once the same data is scanned repeatedly at high concurrency, because you pay per terabyte scanned on every query while Redshift Serverless amortises a provisioned RPU-hour across many queries.",
    "Stop": "end_turn",
    "In": 27,
    "Out": 41,
    "LatencyMs": 1183
}
```

Al precio de lista de la clase Sonnet, 27 de entrada + 41 de salida ≈ **$0.0007**. Ahora con el guardrail adjunto, enviando algo que la política de PII debe atrapar:

```console
$ aws bedrock-runtime converse \
    --model-id eu.anthropic.claude-sonnet-4-20250514-v1:0 \
    --guardrail-config '{"guardrailIdentifier":"gr-9k2mfp0qra41","guardrailVersion":"1","trace":"enabled"}' \
    --messages '[{"role":"user","content":[{"guardContent":{"text":{"text":"Summarise this ticket: user villadalmine@example.com on TP-004417 reports lab timeouts."}}}]}]' \
    --query '{Stop:stopReason,Text:output.message.content[0].text,Pii:trace.guardrail.inputAssessment.*.sensitiveInformationPolicy.piiEntities[].{T:type,A:action}}'
{
    "Stop": "end_turn",
    "Text": "The ticket reports that a user ({EMAIL}) experienced lab environment timeouts on ticket {internal-ticket-id}.",
    "Pii": [
        { "T": "EMAIL", "A": "ANONYMIZED" }
    ]
}
```

El correo electrónico nunca llegó al modelo. Fijate en `guardContent` — solo se evalúa el texto envuelto en él, lo que te permite eximir del filtro a las instrucciones del sistema.

Consultar la Knowledge Base con citas:

```console
$ aws bedrock-agent-runtime retrieve-and-generate \
    --input '{"text":"Which AWS service converts speech to text in real time?"}' \
    --retrieve-and-generate-configuration '{
        "type":"KNOWLEDGE_BASE",
        "knowledgeBaseConfiguration":{
            "knowledgeBaseId":"KBQ7X3P1AZ",
            "modelArn":"arn:aws:bedrock:eu-west-1:123456789012:inference-profile/eu.anthropic.claude-sonnet-4-20250514-v1:0",
            "retrievalConfiguration":{"vectorSearchConfiguration":{"numberOfResults":5}}
        }}' \
    --query '{Answer:output.text,Sources:citations[].retrievedReferences[].location.s3Location.uri}'
{
    "Answer": "Amazon Transcribe performs automatic speech recognition and supports streaming transcription for real-time audio.",
    "Sources": [
        "s3://teach-plat-kb-corpus-123456789012-eu-west-1/certs/aws-clf/3.7/en/content.md",
        "s3://teach-plat-kb-corpus-123456789012-eu-west-1/certs/aws-clf/3.7/en/exercises.md"
    ]
}
```

### 5.5 Los servicios de IA de Tier 3 en una sola pasada

```console
$ aws comprehend detect-sentiment --language-code en \
    --text "The lab environment kept timing out, but support fixed it within ten minutes."
{
    "Sentiment": "MIXED",
    "SentimentScore": {
        "Positive": 0.28415,
        "Negative": 0.11037,
        "Neutral": 0.05762,
        "Mixed": 0.54786
    }
}

$ aws comprehend detect-pii-entities --language-code en \
    --text "Contact a.rivas@example.org or +34 600 123 456 about invoice INV-88213." \
    --query 'Entities[].{Type:Type,Score:Score,Begin:BeginOffset,End:EndOffset}'
[
    { "Type": "EMAIL",  "Score": 0.99938, "Begin": 8,  "End": 27 },
    { "Type": "PHONE",  "Score": 0.99127, "Begin": 31, "End": 46 }
]

$ aws rekognition detect-labels \
    --image '{"S3Object":{"Bucket":"teach-plat-media","Name":"lab-rack-01.jpg"}}' \
    --max-labels 5 --min-confidence 80 \
    --query 'Labels[].{Name:Name,Conf:Confidence}' --output table
------------------------------
|        DetectLabels        |
+------------------+---------+
|       Name       |  Conf   |
+------------------+---------+
|  Computer Hardware| 99.42  |
|  Server           | 97.83  |
|  Electronics      | 96.15  |
|  Cable            | 91.07  |
|  Data Center      | 88.64  |
+------------------+---------+

$ aws textract analyze-document \
    --document '{"S3Object":{"Bucket":"teach-plat-media","Name":"invoice-2026-08.png"}}' \
    --feature-types '["FORMS","TABLES"]' \
    --query 'length(Blocks[?BlockType==`KEY_VALUE_SET`])'
34

$ aws polly synthesize-speech --engine neural --voice-id Ruth --language-code en-US \
    --output-format mp3 \
    --text "Amazon Athena charges per terabyte of data scanned." \
    /tmp/narration.mp3
{
    "ContentType": "audio/mpeg",
    "RequestCharacters": "51"
}

$ aws translate translate-text --source-language-code en --target-language-code es \
    --text "Separation of storage and compute is the defining property of a data lake." \
    --query 'TranslatedText' --output text
La separación del almacenamiento y el cómputo es la propiedad que define un lago de datos.

$ aws transcribe start-transcription-job \
    --transcription-job-name lab-walkthrough-2026-09-04 \
    --language-code en-US \
    --media '{"MediaFileUri":"s3://teach-plat-media/audio/lab-walkthrough.mp4"}' \
    --output-bucket-name teach-plat-media \
    --settings '{"ShowSpeakerLabels":true,"MaxSpeakerLabels":3}' \
    --query 'TranscriptionJob.{Name:TranscriptionJobName,Status:TranscriptionJobStatus}'
{
    "Name": "lab-walkthrough-2026-09-04",
    "Status": "IN_PROGRESS"
}
```

### 5.6 Redshift Serverless vía la Data API (sin drivers, sin ruta de VPC, autenticado con IAM)

```console
$ aws redshift-serverless get-workgroup --workgroup-name teach-plat-wg \
    --query 'workgroup.{Status:status,BaseRPU:baseCapacity,MaxRPU:maxCapacity,Public:publiclyAccessible,Endpoint:endpoint.address}'
{
    "Status": "AVAILABLE",
    "BaseRPU": 8,
    "MaxRPU": 64,
    "Public": false,
    "Endpoint": "teach-plat-wg.123456789012.eu-west-1.redshift-serverless.amazonaws.com"
}

$ SID=$(aws redshift-data execute-statement \
    --workgroup-name teach-plat-wg --database analytics \
    --sql "SELECT cert_id, count(DISTINCT user_id) AS learners FROM lakehouse.events WHERE dt >= '2026-08-01' GROUP BY cert_id ORDER BY learners DESC LIMIT 5" \
    --query Id --output text)

$ aws redshift-data describe-statement --id "$SID" \
    --query '{Status:Status,DurationNs:Duration,Rows:ResultRows,Bytes:ResultSize}'
{
    "Status": "FINISHED",
    "DurationNs": 412874193,
    "Rows": 5,
    "Bytes": 187
}
```

`Duration` está en **nanosegundos** — 412 874 193 ns = 0,41 s. Leerlo como milisegundos es una falsa alarma habitual en los dashboards.

### 5.7 Lake Formation: comprobar que el permiso de columna es real

```console
$ aws lakeformation list-permissions \
    --resource '{"Table":{"CatalogId":"123456789012","DatabaseName":"teach_plat_lakehouse","Name":"events"}}' \
    --query 'PrincipalResourcePermissions[].{Principal:Principal.DataLakePrincipalIdentifier,Perms:Permissions,Cols:Resource.TableWithColumns.ColumnNames}'
[
    {
        "Principal": "arn:aws:iam::123456789012:role/analytics-readonly",
        "Perms": ["SELECT"],
        "Cols": ["dt","tenant","action","latency_ms","status"]
    }
]
```

`user_id` no aparece en el permiso. Una consulta que lo seleccione con ese rol falla en el motor, no en S3:

```console
$ aws athena start-query-execution --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT user_id FROM events WHERE dt='2026-09-03' LIMIT 1" \
    --query QueryExecutionId --output text
b7c1a930-4f2e-4a11-9c88-0d61f3ae2210

$ aws athena get-query-execution --query-execution-id b7c1a930-4f2e-4a11-9c88-0d61f3ae2210 \
    --query 'QueryExecution.Status.StateChangeReason' --output text
COLUMN_NOT_FOUND: line 1:8: Column 'user_id' cannot be resolved
```

Lake Formation elimina la columna del esquema que ve el principal en lugar de devolver "acceso denegado" — esto sorprende a la gente y es exactamente el comportamiento buscado.

### 5.8 Salud de un endpoint de SageMaker AI

```console
$ aws sagemaker describe-endpoint --endpoint-name churn-rt \
    --query '{Status:EndpointStatus,Reason:FailureReason,Variants:ProductionVariants[].{V:VariantName,Instances:CurrentInstanceCount,Desired:DesiredInstanceCount,Weight:CurrentWeight}}'
{
    "Status": "InService",
    "Reason": null,
    "Variants": [
        { "V": "blue",  "Instances": 2, "Desired": 2, "Weight": 0.9 },
        { "V": "green", "Instances": 1, "Desired": 1, "Weight": 0.1 }
    ]
}

$ aws cloudwatch get-metric-statistics --namespace AWS/SageMaker \
    --metric-name ModelLatency \
    --dimensions Name=EndpointName,Value=churn-rt Name=VariantName,Value=blue \
    --start-time 2026-09-04T10:00:00Z --end-time 2026-09-04T11:00:00Z \
    --period 300 --statistics Average p99 \
    --query 'sort_by(Datapoints,&Timestamp)[-3:].{T:Timestamp,Avg:Average,P99:p99,U:Unit}' --output table
-------------------------------------------------------------------
|                      GetMetricStatistics                        |
+--------------------------+---------+---------+------------------+
|            T             |   Avg   |   P99   |        U         |
+--------------------------+---------+---------+------------------+
|  2026-09-04T10:50:00Z    |  8412.0 | 21903.0 |  Microseconds    |
|  2026-09-04T10:55:00Z    |  8177.0 | 20488.0 |  Microseconds    |
|  2026-09-04T11:00:00Z    |  9310.0 | 34771.0 |  Microseconds    |
+--------------------------+---------+---------+------------------+
```

`ModelLatency` está en **microsegundos** y mide únicamente el contenedor. `OverheadLatency` es el agregado del lado de SageMaker. Si la latencia observada por el cliente supera `ModelLatency + OverheadLatency`, el problema está de tu lado del endpoint — red, serialización, o un cliente sin reutilización de conexiones.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Las métricas que importan, por servicio

| Servicio | Señal dorada | Namespace / métrica | Qué significa una violación |
|---|---|---|---|
| Kinesis Data Streams | Retraso del consumidor | `AWS/Kinesis` · `GetRecords.IteratorAgeMilliseconds` | Los consumidores van más lento que los productores; **pérdida de datos** cuando la edad > retención |
| Kinesis Data Streams | Throttling de escritura | `WriteProvisionedThroughputExceeded` | Clave de partición caliente o muy pocos shards |
| Kinesis Data Streams | Throttling de lectura | `ReadProvisionedThroughputExceeded` | Demasiados consumidores estándar compartiendo 2 MB/s; usá Enhanced Fan-Out |
| Data Firehose | Frescura de entrega | `AWS/Firehose` · `DeliveryToS3.DataFreshness` | Destino inalcanzable, denegación de IAM, o conversión de esquema fallando |
| Data Firehose | Errores de conversión | `FailedConversion.Records` | El payload no coincide con el esquema de Glue |
| Data Firehose | Throttling en el origen | `ThrottledRecords` | Cuota de Firehose excedida (5 000 reg/s o 5 MiB/s por stream, según la región) |
| Athena | Costo | `AWS/Athena` · `ProcessedBytes` | El partition pruning no está ocurriendo |
| Athena | Contención | `QueryQueueTime` | Cuota de concurrencia alcanzada; mové los dashboards a Redshift |
| Glue | Presión de memoria | `glue.ALL.jvm.heap.usage` > 0.9 | Join sesgado o muy pocos DPU; esperá un OOM |
| Glue | Volcado a disco | `glue.driver.BlockManager.disk.diskSpaceUsed_MB` en aumento | El shuffle excede la memoria |
| Redshift Serverless | Capacidad | `AWS/Redshift-Serverless` · `ComputeCapacity` en `MaxRPU` | Subí el tope o arreglá la consulta |
| OpenSearch | Salud del clúster | `AWS/ES` · `ClusterStatus.red`, `JVMMemoryPressure` > 80 % | Shards sin asignar / espiral de muerte por GC |
| Bedrock | Throttles | `AWS/Bedrock` · `InvocationThrottles` | Cuota TPM/RPM de la cuenta; usá perfiles de inferencia o pedí un aumento |
| Bedrock | Costo | `InputTokenCount` + `OutputTokenCount` | Prompts inflados; habilitá prompt caching |
| Endpoint de SageMaker | Desglose de latencia | `AWS/SageMaker` · `ModelLatency`, `OverheadLatency` | Atribución contenedor vs plataforma |
| Endpoint de SageMaker | Saturación | `InvocationsPerInstance`, `CPUUtilization` | Falta el objetivo de auto-scaling |

### 6.2 Runbook — síntoma → causa → comando

**Athena / lakehouse**

| Síntoma | Causa raíz | Diagnóstico y solución |
|---|---|---|
| `HIVE_PARTITION_SCHEMA_MISMATCH: ... declared as type 'bigint', but partition ... as type 'string'` | Un crawler volvió a inferir el tipo de una columna tras una deriva aguas arriba | `aws glue get-partition --database-name … --partition-values …` y compará `StorageDescriptor.Columns` con los de la tabla. Arreglá el origen, después eliminá y volvé a agregar la partición. A largo plazo: declará el esquema explícitamente (como en §4.1) y dejá de permitir que un crawler sea su dueño |
| `HIVE_CURSOR_ERROR: Not valid Parquet file` | JSON en cuarentena o archivos `_temporary` bajo la ubicación S3 de la tabla | `aws s3 ls s3://…/curated/events/ --recursive \| grep -v '\.parquet$'`. Mové `ErrorOutputPrefix` fuera del prefijo de la tabla |
| `Insufficient permissions to execute the query. Amazon S3 access denied on s3://…` | El llamador de Athena carece de `s3:GetObject`, o de `kms:Decrypt` sobre la CMK del bucket | Decrypt es lo habitual. `aws kms describe-key --key-id alias/teach-plat-lake` y revisá la política de la clave, no solo la política de IAM |
| La consulta devuelve **0 filas** pero hay datos en S3 | Particiones no registradas, o la plantilla de projection no coincide con el prefijo real | `SELECT DISTINCT dt FROM events LIMIT 5`, después `aws s3 ls s3://…/curated/events/`. Los **nombres y el orden** de las claves de la plantilla deben coincidir exactamente con `PartitionKeys` |
| `COLUMN_NOT_FOUND` para una columna que existe | El permiso a nivel de columna de Lake Formation la excluye | `aws lakeformation list-permissions --resource '{"Table":…}'` (§5.7) |
| Pico de costo sin cambio en el tráfico | Alguien quitó el predicado de partición, o hay muchos archivos chicos | `aws athena list-query-executions` + `batch-get-query-execution`, ordenado por `DataScannedInBytes`. Revisá también la cantidad de objetos: miles de archivos Parquet de 200 KB cuestan más en sobrecarga de peticiones de lo que ahorran |

**Kinesis / Firehose**

| Síntoma | Causa raíz | Diagnóstico y solución |
|---|---|---|
| `ProvisionedThroughputExceededException: Rate exceeded for shard shardId-000000000001` | Clave de partición caliente — un tenant domina | Revisá `IncomingBytes` por shard (dimensión `ShardId`). Arreglá la clave: `tenant_id#<random 0..N>` o pasá a `ON_DEMAND` |
| `DataFreshness` subiendo, sin objetos en S3 | El rol de Firehose fue denegado en S3 o KMS | `aws logs tail /aws/kinesisfirehose/teach-plat --since 30m --format short` — la línea de log nombra la acción denegada exacta |
| Los registros aterrizan bajo `quarantine/format-conversion-failed/` | El payload no coincide con el esquema de Glue | Leé un objeto en cuarentena: contiene `rawData` (base64) más el error. Causas comunes: `latency_ms` enviado como string, o un campo nuevo que la tabla de Glue no tiene (`OpenXJsonSerDe` tolera extras solo si `CaseInsensitive`/el mapeo lo permiten) |
| Los registros aterrizan bajo `quarantine/processing-failed/` | La `MetadataExtractionQuery` de jq devolvió null para una clave de partición | Cada registro debe producir **todas** las claves de partición dinámica. Agregá un valor por defecto: `{dt:(.event_time[0:10] // "unknown"),tenant:(.tenant_id // "unknown")}` |
| Firehose entrega, pero los objetos son diminutos y numerosos | `BufferingHints` demasiado agresivo | Subí `SizeInMBs` hacia 128 e `IntervalInSeconds` a 300 si el SLO de frescura lo permite. La cantidad de objetos determina el costo de peticiones de Athena y el tiempo de los jobs de Glue |
| El `DeliveryStream` no se puede actualizar para agregar particionado dinámico | Es solo en el momento de creación | Creá un delivery stream nuevo y migrá. Verificá con `describe-delivery-stream` antes de borrar el viejo |
| El `IteratorAge` del consumidor crece de forma monótona | Throughput del consumidor por debajo de la tasa del productor | Escalá los consumidores hasta como máximo la cantidad de shards (un consumidor por shard para consumidores estándar), o adoptá Enhanced Fan-Out. Vigilá la retención: con 24 h, una edad de 20 h significa que estás a 4 h de la pérdida permanente |

**Bedrock**

| Error / síntoma | Causa | Solución |
|---|---|---|
| `AccessDeniedException: You don't have access to the model with the specified model ID.` | Acceso al modelo no habilitado para la cuenta/región | Consola de Bedrock → *Model access* → solicitar acceso. Es un interruptor a nivel de cuenta y por región, no de IAM |
| `ValidationException: Invocation of model ID anthropic.claude-sonnet-4-… with on-demand throughput isn't supported. Retry your request with the ID or ARN of an inference profile that contains this model.` | Los modelos más nuevos solo son accesibles a través de perfiles de inferencia | Antepone la geografía al ID: `eu.anthropic.claude-sonnet-4-…`. `aws bedrock list-inference-profiles --query 'inferenceProfileSummaries[].inferenceProfileId'` |
| `ThrottlingException: Too many requests, please wait before trying again.` | Cuota TPM/RPM de la cuenta | `retry_mode = adaptive` en el cliente, perfil de inferencia entre regiones, o aumento vía Service Quotas. Provisioned Throughput si la carga es sostenida |
| `ResourceNotFoundException` en `retrieve-and-generate` | La fuente de datos nunca se ingirió, o el índice vectorial no existe | `aws bedrock-agent list-ingestion-jobs --knowledge-base-id … --data-source-id …`; una KB con cero trabajos de ingesta completados no devuelve nada nunca |
| La creación de la KB falla: *"The knowledge base storage configuration provided is invalid… no such index"* | CloudFormation **no** crea el índice vectorial de OpenSearch Serverless | Creá primero el índice (`PUT /bedrock-kb-index` con un campo `knn_vector` de la dimensión del modelo de embeddings — 1024 para `titan-embed-text-v2`), y después creá la KB. Este es el rollback de stack n.º 1 de §4.2 |
| Las respuestas son erróneas con seguridad | Sin filtro de grounding contextual | Configurá `ContextualGroundingPolicyConfig` (§4.2) e inspeccioná `trace.guardrail.outputAssessments[].contextualGroundingPolicy` |
| `stopReason: "max_tokens"`, respuestas truncadas | `maxTokens` demasiado bajo | Subilo — pero tené en cuenta que también es tu techo de costo; a veces la truncación es el compromiso correcto |

**SageMaker AI**

| Síntoma | Causa | Solución |
|---|---|---|
| El endpoint se queda en `Creating` → `Failed`, `FailureReason: "...did not pass the ping health check"` | El contenedor no responde `GET /ping` con 200 dentro de la ventana de arranque | `aws logs tail /aws/sagemaker/Endpoints/<name> --since 20m`. Normalmente es una ruta de artefacto del modelo o una dependencia faltante |
| `ModelError: Received server error (503)` al invocar | OOM del contenedor o worker de un solo hilo saturado | Subí el objetivo de `InvocationsPerInstance` en el auto-scaling, o pasá a una instancia más grande. Revisá `MemoryUtilization` |
| El endpoint cuesta dinero sin tráfico | Los endpoints en tiempo real facturan por hora de instancia sin importar el tráfico | Cambiá a **Serverless Inference** (escala a cero, arranque en frío aceptable) o **Asynchronous Inference** (respaldado por cola, escala a cero, payloads grandes) |
| Training job con `ResourceLimitExceeded` | La cuota de servicio por tipo de instancia es 0 por defecto para los tipos con GPU | `aws service-quotas list-service-quotas --service-code sagemaker --query "Quotas[?contains(QuotaName,'ml.g6')]"` y pedí un aumento |

### 6.3 Una checklist de verificación para correr antes de declarar sano el pipeline

```console
# 1. Producer path accepts writes
$ aws kinesis put-record --stream-name teach-plat-events --partition-key smoke \
    --cli-binary-format raw-in-base64-out \
    --data '{"event_id":"smoke","event_time":"2026-09-04T11:30:00Z","tenant_id":"smoke","action":"healthcheck","latency_ms":1,"status":"ok"}' >/dev/null && echo OK
OK

# 2. Nothing is being quarantined
$ test "$(aws s3 ls s3://teach-plat-lake-123456789012-eu-west-1/quarantine/ --recursive | wc -l)" -eq 0 && echo "no rejects"
no rejects

# 3. Delivery is fresh (seconds of undelivered backlog)
$ aws cloudwatch get-metric-statistics --namespace AWS/Firehose \
    --metric-name DeliveryToS3.DataFreshness \
    --dimensions Name=DeliveryStreamName,Value=teach-plat-events-to-lake \
    --start-time "$(date -u -d '15 min ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
    --period 300 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum'
73.0

# 4. The catalog resolves and the query engine can read the data
$ aws athena start-query-execution --work-group teach-plat-analytics \
    --query-execution-context 'Database=teach_plat_lakehouse' \
    --query-string "SELECT count(*) FROM events WHERE dt = date_format(current_date, '%Y-%m-%d')" \
    --query QueryExecutionId --output text
9f2a44e1-5b03-4c8d-a1e0-77c2b6f4e5aa

# 5. Cost guardrail is actually enforced (not just configured)
$ aws athena get-work-group --work-group teach-plat-analytics \
    --query 'WorkGroup.Configuration.{Cap:BytesScannedCutoffPerQuery,Enforced:EnforceWorkGroupConfiguration}'
{
    "Cap": 107374182400,
    "Enforced": true
}

# 6. The model path is reachable with the identity the app actually uses
$ kubectl -n ai-platform exec deploy/rag-gateway -- \
    aws sts get-caller-identity --query Arn --output text
arn:aws:sts::123456789012:assumed-role/eks-ai-platform-rag-gateway/botocore-session-1757000000
```

El paso 6 es el que la gente saltea. Que `aws bedrock-runtime converse` funcione desde tu laptop no prueba nada sobre si el rol IRSA del pod puede hacerlo.

---

## 7. Hoja de decisión enfocada en el examen

Mapeá la frase del requisito al servicio. Estos son los discriminadores que CLF-C02 realmente usa.

| Si la pregunta dice… | Respuesta |
|---|---|
| "ejecutar SQL directamente sobre datos en S3, sin infraestructura" | **Amazon Athena** |
| "data warehouse a escala de petabytes para BI" | **Amazon Redshift** |
| "clústeres gestionados de Hadoop/Spark/Hive" | **Amazon EMR** |
| "ETL serverless y un catálogo de datos" | **AWS Glue** |
| "preparar datos visualmente sin escribir código" | **AWS Glue DataBrew** |
| "dashboards de inteligencia de negocio, insights potenciados por ML" | **Amazon QuickSight** |
| "buscar y analizar datos de logs, analítica operativa" | **Amazon OpenSearch Service** |
| "cargar datos en streaming hacia S3/Redshift/OpenSearch sin código" | **Amazon Data Firehose** |
| "múltiples consumidores, registros ordenados, replay" | **Amazon Kinesis Data Streams** |
| "procesamiento/agregación en tiempo real de un stream" | **Amazon Managed Service for Apache Flink** |
| "Apache Kafka totalmente gestionado" | **Amazon MSK** |
| "gobernar y asegurar centralmente un data lake, acceso a nivel de columna" | **AWS Lake Formation** |
| "encontrar y suscribirse a datasets de terceros" | **AWS Data Exchange** |
| "analizar datos combinados con un socio sin compartir datos crudos" | **AWS Clean Rooms** |
| "construir, entrenar y desplegar modelos de ML" | **Amazon SageMaker AI** |
| "acceder a foundation models vía API, construir apps de IA generativa" | **Amazon Bedrock** |
| "asistente de IA generativa para desarrolladores / para la empresa" | **Amazon Q Developer / Amazon Q Business** |
| "extraer texto y datos de documentos escaneados" | **Amazon Textract** |
| "analizar imágenes y video, moderación de contenido" | **Amazon Rekognition** |
| "convertir voz a texto" | **Amazon Transcribe** |
| "convertir texto en voz realista" | **Amazon Polly** |
| "traducir texto entre idiomas" | **Amazon Translate** |
| "encontrar insights, sentimiento, entidades y PII en texto" | **Amazon Comprehend** |
| "construir un chatbot / una interfaz de voz" | **Amazon Lex** |
| "búsqueda empresarial inteligente en múltiples repositorios" | **Amazon Kendra** |
| "recomendaciones de productos en tiempo real" | **Amazon Personalize** |
| "detectar fraude en línea sin experiencia en ML" | **Amazon Fraud Detector** |
| "revisión humana de predicciones de ML de baja confianza" | **Amazon Augmented AI (A2I)** |
| "chip de propósito específico para entrenar modelos a menor costo" | **AWS Trainium** |
| "chip de propósito específico para inferencia de bajo costo" | **AWS Inferentia** |

**Tres distinciones que vale la pena memorizar porque son confundibles a propósito:**

1. **Kendra frente a Q Business.** Kendra *devuelve documentos* (búsqueda); Q Business *genera una respuesta* (asistente) — y Q Business puede usar Kendra como su recuperador.
2. **Comprehend frente a Bedrock.** Comprehend es una API de NLP de propósito fijo (sentimiento, entidades, PII) sin prompt; Bedrock es un foundation model general al que le das instrucciones. Si el requisito nombra una tarea de NLP específica, Comprehend es la respuesta más barata y más determinista.
3. **Data Firehose frente a Data Streams.** Firehose = entrega, con búfer, un destino, sin replay. Streams = un log durable, muchos consumidores, replay. Si el escenario necesita *reprocesamiento*, es Streams.

---

## 8. Referencias

**Guía del examen (alcance autoritativo para este enunciado de tarea)**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Página de certificación y preguntas de muestra — https://aws.amazon.com/certification/certified-cloud-practitioner/

**IA/ML**
- Amazon Bedrock User Guide — https://docs.aws.amazon.com/bedrock/latest/userguide/
- Bedrock Guardrails — https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html
- Bedrock Knowledge Bases — https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html
- Bedrock cross-region inference — https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html
- Bedrock data protection / privacy — https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html
- Amazon SageMaker AI Developer Guide — https://docs.aws.amazon.com/sagemaker/latest/dg/
- SageMaker Serverless Inference — https://docs.aws.amazon.com/sagemaker/latest/dg/serverless-endpoints.html
- SageMaker Asynchronous Inference — https://docs.aws.amazon.com/sagemaker/latest/dg/async-inference.html
- Amazon Q Developer — https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/
- Amazon Q Business — https://docs.aws.amazon.com/amazonq/latest/qbusiness-ug/
- Amazon Comprehend — https://docs.aws.amazon.com/comprehend/latest/dg/
- Amazon Textract — https://docs.aws.amazon.com/textract/latest/dg/
- Amazon Rekognition — https://docs.aws.amazon.com/rekognition/latest/dg/
- Amazon Transcribe — https://docs.aws.amazon.com/transcribe/latest/dg/
- Amazon Polly — https://docs.aws.amazon.com/polly/latest/dg/
- Amazon Translate — https://docs.aws.amazon.com/translate/latest/dg/
- Amazon Lex V2 — https://docs.aws.amazon.com/lexv2/latest/dg/
- Amazon Kendra — https://docs.aws.amazon.com/kendra/latest/dg/
- Amazon Personalize — https://docs.aws.amazon.com/personalize/latest/dg/
- Amazon Fraud Detector — https://docs.aws.amazon.com/frauddetector/latest/ug/
- Amazon Augmented AI (A2I) — https://docs.aws.amazon.com/sagemaker/latest/dg/a2i-use-augmented-ai-a2i-human-review-loops.html
- AWS Trainium — https://aws.amazon.com/ai/machine-learning/trainium/
- AWS Inferentia — https://aws.amazon.com/ai/machine-learning/inferentia/
- Documentación del AWS Neuron SDK — https://awsdocs-neuron.readthedocs-hosted.com/

**Analítica**
- Amazon Athena User Guide — https://docs.aws.amazon.com/athena/latest/ug/
- Athena partition projection — https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html
- Athena workgroups and data-usage controls — https://docs.aws.amazon.com/athena/latest/ug/workgroups-setting-control-limits-cloudwatch.html
- Athena troubleshooting — https://docs.aws.amazon.com/athena/latest/ug/troubleshooting-athena.html
- Amazon Redshift Management Guide — https://docs.aws.amazon.com/redshift/latest/mgmt/
- Redshift Serverless — https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-whatis.html
- Redshift Data API — https://docs.aws.amazon.com/redshift/latest/mgmt/data-api.html
- Amazon EMR — https://docs.aws.amazon.com/emr/latest/ManagementGuide/
- EMR Serverless — https://docs.aws.amazon.com/emr/latest/EMR-Serverless-UserGuide/
- AWS Glue Developer Guide — https://docs.aws.amazon.com/glue/latest/dg/
- AWS Glue DataBrew — https://docs.aws.amazon.com/databrew/latest/dg/
- Amazon Kinesis Data Streams — https://docs.aws.amazon.com/streams/latest/dev/
- Kinesis Data Streams CloudWatch monitoring — https://docs.aws.amazon.com/streams/latest/dev/monitoring-with-cloudwatch.html
- Amazon Data Firehose — https://docs.aws.amazon.com/firehose/latest/dev/
- Firehose dynamic partitioning — https://docs.aws.amazon.com/firehose/latest/dev/dynamic-partitioning.html
- Firehose record format conversion — https://docs.aws.amazon.com/firehose/latest/dev/record-format-conversion.html
- Amazon Managed Service for Apache Flink — https://docs.aws.amazon.com/managed-flink/latest/java/
- Amazon MSK — https://docs.aws.amazon.com/msk/latest/developerguide/
- Amazon OpenSearch Service — https://docs.aws.amazon.com/opensearch-service/latest/developerguide/
- OpenSearch Serverless vector search — https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-vector-search.html
- Amazon QuickSight — https://docs.aws.amazon.com/quicksight/latest/user/
- AWS Lake Formation — https://docs.aws.amazon.com/lake-formation/latest/dg/
- Amazon DataZone — https://docs.aws.amazon.com/datazone/latest/userguide/
- AWS Data Exchange — https://docs.aws.amazon.com/data-exchange/latest/userguide/
- AWS Clean Rooms — https://docs.aws.amazon.com/clean-rooms/latest/userguide/

**Infraestructura como código y Kubernetes**
- `AWS::KinesisFirehose::DeliveryStream` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-kinesisfirehose-deliverystream.html
- `AWS::Glue::Table` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-glue-table.html
- `AWS::Athena::WorkGroup` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-athena-workgroup.html
- `AWS::Bedrock::KnowledgeBase` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bedrock-knowledgebase.html
- `AWS::Bedrock::Guardrail` — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-bedrock-guardrail.html
- IAM roles for service accounts (IRSA) en EKS — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- Documentación de Karpenter — https://karpenter.sh/docs/
- AWS Neuron device plugin para Kubernetes — https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/

**Precios (verificar antes de citar — las cifras de esta unidad son precios de lista de `us-east-1` usados para calibrar)**
- Athena — https://aws.amazon.com/athena/pricing/
- Redshift — https://aws.amazon.com/redshift/pricing/
- Glue — https://aws.amazon.com/glue/pricing/
- Kinesis Data Streams — https://aws.amazon.com/kinesis/data-streams/pricing/
- Amazon Data Firehose — https://aws.amazon.com/firehose/pricing/
- OpenSearch Service — https://aws.amazon.com/opensearch-service/pricing/
- QuickSight — https://aws.amazon.com/quicksight/pricing/
- Bedrock — https://aws.amazon.com/bedrock/pricing/
- SageMaker — https://aws.amazon.com/sagemaker/pricing/
- Kendra — https://aws.amazon.com/kendra/pricing/