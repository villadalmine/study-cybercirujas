# 3.1 — Describir conceptos fundamentales de AI y ML y cómo generan valor de negocio

**Certificación:** Google Cloud Digital Leader (CDL) · Guía de examen versión 2026-08-12
**Peso del dominio:** 9.0 %
**Perfil:** Principal Platform Architect / Senior SRE

---

## 0. Cómo se examina realmente este objetivo

El blueprint del CDL formula este objetivo en lenguaje de negocio, pero cada pregunta en realidad evalúa si sabés ubicar una carga de trabajo en el escalón correcto de la escalera de soluciones de AI de Google y justificarlo con un argumento de costo, latencia, gravedad de datos o gobernanza. Las tres formas recurrentes de pregunta son:

1. **Ubicación** — "Un retailer quiere X sin experiencia en ML in-house" → elegí el servicio de mayor abstracción que satisfaga la restricción.
2. **Preparación de los datos** — "El modelo rinde mal en producción" → la respuesta casi siempre es sobre calidad de datos, labeling, drift o skew, nunca sobre el algoritmo.
3. **Articulación del valor** — "¿Qué métrica demuestra valor de negocio?" → distinguí *métricas de modelo* (AUC, RMSE, perplexity) de *KPIs de negocio* (tasa de churn, costo por ticket resuelto, margen bruto).

Todo lo que sigue es el sustrato de producción que hay debajo de esas tres formas. Como SRE te van a paginar por los modos de fallo de la §12 mucho antes de que alguien te pregunte por el AUC.

---

## 1. Motivación: el problema de la arquitectura de producción

### 1.1 El modelo es la parte más pequeña del sistema

La propia investigación de Google (Sculley et al., *Hidden Technical Debt in Machine Learning Systems*, NeurIPS 2015) estableció el diagrama canónico: la caja rotulada "ML Code" es una fracción minúscula de un sistema de ML real. Las cajas circundantes — configuración, recolección de datos, extracción de features, verificación de datos, gestión de recursos de máquina, herramientas de análisis, herramientas de gestión de procesos, infraestructura de serving, monitoreo — son el problema del platform engineer.

Por eso Google Cloud no vende "un modelo". Vende **Vertex AI**, una plataforma cuyos componentes mapean uno a uno sobre esas cajas:

| Caja de deuda técnica (paper 2015) | Componente de Google Cloud |
|---|---|
| Recolección de datos | Cloud Storage, BigQuery, Pub/Sub, Datastream |
| Verificación de datos | Dataplex Universal Catalog, Dataform, BigQuery data quality scans |
| Extracción de features | Dataflow, BigQuery, Vertex AI Feature Store |
| Código ML | Vertex AI Training, BigQuery ML, Model Garden |
| Configuración | Parámetros de Vertex AI Pipelines, Artifact Registry, Cloud Build |
| Gestión de recursos de máquina | Vertex AI custom jobs, GKE, node pools TPU/GPU |
| Herramientas de análisis | Vertex AI Experiments, TensorBoard, Vertex AI Model Evaluation |
| Gestión de procesos | Vertex AI Pipelines (Kubeflow / TFX) |
| Infraestructura de serving | Vertex AI Endpoints, GKE + KServe, Cloud Run |
| Monitoreo | Vertex AI Model Monitoring, Cloud Monitoring, Cloud Logging |

### 1.2 CACE: Changing Anything Changes Everything

Los sistemas de ML erosionan los límites de módulo de los que depende la ingeniería de software clásica. Un modelo consume features; las features vienen de tablas upstream; las tablas vienen de servicios upstream. No hay contrato de interfaz que diga "la columna `user_tenure_days` va a seguir estando en días". En el momento en que un equipo upstream cambia esa columna a meses, tu modelo se degrada en silencio — **no se lanza ninguna excepción, no se emite ningún HTTP 500, no se quema ningún SLO**. La accuracy cae, los ingresos caen, y la primera señal es un dashboard de negocio tres semanas después.

Esta es la diferencia operativa definitoria entre un servicio de ML y un microservicio stateless:

| Propiedad | Microservicio stateless | Servicio de inferencia ML |
|---|---|---|
| Señal de fallo | Excepción, non-2xx, pico de latencia | Cambio en la distribución estadística — silencioso |
| Definición de corrección | Determinista, testeable | Probabilística, solo medible contra ground truth |
| Disponibilidad de ground truth | Inmediata | Diferida horas→meses (label lag) |
| Unidad de rollback | Imagen de contenedor | Imagen **+** artefacto del modelo **+** definiciones de features **+** código de preprocesamiento |
| Requisito de reproducibilidad | Mismo código → misma salida | Mismo código + mismos datos + misma semilla + mismas versiones de librerías |
| Costo dominante | vCPU-segundos | Horas de acelerador (entrenamiento) + tokens/QPS (serving) |
| Radio de impacto de un mal deploy | Errores, visibles | Respuestas incorrectas-pero-plausibles, invisibles |

La última fila es la razón por la que *Responsible AI* (§9) es un control de ingeniería, no una slide de compliance.

### 1.3 La arquitectura de dos loops

Todo sistema de ML en producción son dos loops corriendo a frecuencias distintas. Diseñarlos por separado es la decisión arquitectónica más importante.

```
                      ┌──────────────────── OUTER LOOP (training) ─────────────────────┐
                      │  hours → weeks                                                 │
  ┌──────────┐   ┌────▼─────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐   ┌────────┴───┐
  │ Sources  │──▶│ Ingest   │──▶│ Feature   │──▶│ Train    │──▶│ Evaluate │──▶│ Model      │
  │ OLTP/IoT │   │ Pub/Sub  │   │ engineer  │   │ Vertex   │   │ + fairness│  │ Registry   │
  │ logs/SaaS│   │ Datastream│  │ Dataflow  │   │ AI       │   │ gates     │  │ (versioned)│
  └──────────┘   └────┬─────┘   └─────┬─────┘   └──────────┘   └──────────┘   └────────┬───┘
                      │               │                                                │
                      ▼               ▼                                                ▼
                 ┌─────────┐    ┌──────────────┐                               ┌──────────────┐
                 │ BigQuery│◀──▶│ Feature Store│──────────────────────────────▶│  Endpoint    │
                 │ / GCS   │    │ (offline+    │       low-latency reads        │  (online)    │
                 └─────────┘    │  online)     │                               └──────┬───────┘
                      ▲         └──────────────┘                                      │
                      │                                                                │
                      │         ┌──────────────── INNER LOOP (serving) ────────────────┤
                      │         │  milliseconds                                        │
                      │    ┌────▼────┐    ┌──────────┐    ┌───────────┐    ┌───────────▼──┐
                      └────┤ Ground  │◀───┤ Business │◀───┤  Client   │───▶│  Prediction  │
                    labels │ truth   │    │ outcome  │    │  app      │    │  + logging   │
                           └─────────┘    └──────────┘    └───────────┘    └──────────────┘
                                 │                                                  │
                                 └────────────── Model Monitoring ◀─────────────────┘
                                        skew / drift / attribution alerts
```

El **Feature Store** está deliberadamente en la intersección: es el único componente que sirve los *mismos* valores de feature a ambos loops, lo cual es la cura estructural para el training-serving skew (§3.5).

---

## 2. Taxonomía: los conceptos, con precisión

### 2.1 Jerarquía de contención

```
Artificial Intelligence  ── any technique making machines exhibit goal-directed behaviour
 └── Machine Learning    ── systems that infer rules from data instead of being programmed with them
      └── Deep Learning  ── ML using multi-layer neural networks; learns its own features
           └── Generative AI ── deep models that produce new content (text, image, audio, code)
                └── Foundation models / LLMs ── large, self-supervised, task-general, adaptable
                     └── Agents ── an LLM plus tools, memory and a control loop that takes actions
```

**Distinción crítica para el examen:** el ML clásico *predice una etiqueta o un valor*; la AI generativa *produce contenido nuevo*. El scoring de fraude es ML. Redactar el resumen de la investigación de fraude es AI generativa. La mayoría de los sistemas reales son ambas cosas.

### 2.2 Paradigmas de aprendizaje

| Paradigma | Requisito de datos | Tarea canónica | Superficie en GCP | Salvedad en producción |
|---|---|---|---|---|
| **Supervisado** | Ejemplos etiquetados (X, y) | Clasificación, regresión, forecasting | AutoML Tabular, BigQuery ML, custom training | El costo de labeling domina; el label lag retrasa la evaluación |
| **No supervisado** | Solo X sin etiquetas | Clustering, detección de anomalías, reducción de dimensionalidad | `KMEANS`, `PCA` en BigQuery ML | No hay métrica objetiva de corrección — la validación es humana |
| **Semi-supervisado** | Pocas etiquetas + mucho sin etiquetar | Clasificación de documentos a escala | Custom training | Los errores de pseudo-labeling se acumulan en silencio |
| **Auto-supervisado** | Corpus crudo; etiquetas derivadas de los propios datos | Pre-entrenamiento de LLMs, embeddings | Model Garden (consumir, rara vez entrenar) | El pre-entrenamiento es un proyecto de escala capex, no un sprint |
| **Reinforcement learning** | Entorno + señal de recompensa | Control, bidding, alineamiento RLHF | Custom sobre Vertex AI | Reward hacking; necesita un simulador seguro |

### 2.3 Discriminativo vs generativo

| | Discriminativo | Generativo |
|---|---|---|
| Aprende | P(y \| x) — la frontera | P(x) o P(x, y) — la distribución |
| Salida | Una etiqueta, score o número | Contenido nuevo |
| Evaluación | Accuracy, AUC-ROC, RMSE, MAE | Perplexity, BLEU/ROUGE, preferencia humana, LLM-as-judge |
| Tamaño típico | KB → cientos de MB | GB → cientos de GB |
| Perfil de latencia | Un solo forward pass, ~1–20 ms | Autoregresivo, N tokens × costo por token |
| Modo de fallo | Mala clasificación | **Hallucination** — fluida, confiada, incorrecta |
| Driver de costo | QPS | Tokens de input + tokens de output |

### 2.4 Vocabulario de AI generativa que el examen espera

| Término | Definición | Consecuencia operativa |
|---|---|---|
| **Token** | Unidad sub-palabra; ~4 caracteres en inglés | Unidad de facturación; los límites de contexto son en tokens, no en caracteres |
| **Context window** | Máximo de tokens por request (input + output) | El contexto largo reduce la necesidad de chunking para RAG pero sube el costo por llamada y el TTFT |
| **Embedding** | Vector denso que codifica significado semántico | Habilita búsqueda por similitud; el sustrato de RAG |
| **Vector search** | Recuperación ANN sobre embeddings | Vertex AI Vector Search; también `VECTOR_SEARCH()` en BigQuery |
| **Prompt engineering** | Dar forma al input para dirigir la salida | Costo cero; siempre intentarlo antes de hacer tuning |
| **Grounding** | Restringir la salida a un corpus confiable | El control principal contra la hallucination |
| **RAG** | Recuperar documentos relevantes → inyectarlos en el prompt | Datos frescos sin reentrenar; la palanca de corrección más barata |
| **Fine-tuning (SFT/LoRA)** | Adaptar los pesos con ejemplos de dominio | Enseña *estilo/formato/tarea*, no hechos |
| **Distillation** | Entrenar un modelo chico con las salidas de uno grande | Reduce el costo de serving 5–20× con algo de pérdida de calidad |
| **Temperature / top-p / top-k** | Controles de aleatoriedad del sampling | Poné temperature≈0 para extracción/clasificación, más alta para ideación |
| **Hallucination** | Salida fluida sin sustento en evidencia | Mitigar con grounding + citas + human-in-the-loop |
| **Agent** | LLM + herramientas + loop | Introduce no determinismo *y* efectos secundarios — necesita sandboxing, presupuestos, auditoría |

**La escalera de adaptación — subí siempre desde arriba:**

| Técnica | ¿Cambia pesos? | Costo | Impacto en latencia | Corrige |
|---|---|---|---|---|
| Prompt engineering | No | ~0 | Ninguno | Formato, tono, razonamiento simple |
| Ejemplos few-shot | No | Costo de tokens por llamada | ↑ tokens de input | Patrón de la tarea |
| RAG / grounding | No | Infra de recuperación + tokens | +20–200 ms | **Exactitud factual, frescura** |
| Supervised fine-tuning (LoRA/PEFT) | Solo el adapter | Cientos → miles bajos de USD | Ninguno (adapter fusionado) | Estilo de dominio, esquema de salida, prompt más corto |
| Full fine-tuning | Sí, todos | Alto | Ninguno | Cambio profundo de dominio |
| Pre-training | Sí, desde cero | Escala capex | — | En la práctica, nunca justificado |

> **Trampa de examen:** "El modelo da respuestas desactualizadas sobre nuestro catálogo de productos." → **RAG/grounding**, no fine-tuning. El fine-tuning no instala hechos nuevos de manera confiable.

---

## 3. La base de datos — donde el valor realmente se gana o se pierde

### 3.1 Tipos de datos y dónde viven

| Tipo | Ejemplos | Store primario en GCP | Por qué |
|---|---|---|---|
| Estructurado | Transacciones, filas de telemetría | BigQuery, Cloud SQL, Spanner | SQL, escaneo columnar, BigQuery ML in place |
| Semi-estructurado | Eventos JSON, logs | BigQuery (tipo JSON), Bigtable | Flexibilidad de esquema + consulta |
| No estructurado | PDFs, imágenes, audio, video | Cloud Storage + Document AI / Vision API | Object storage + extracción a estructura |
| Vectorial | Embeddings | Vertex AI Vector Search, BigQuery, AlloyDB `pgvector` | Recuperación ANN para RAG |

### 3.2 Batch vs streaming

| Dimensión | Batch | Streaming |
|---|---|---|
| Frescura | Minutos → días | Sub-segundo → segundos |
| Camino en GCP | Cloud Storage → BigQuery / Dataflow batch | Pub/Sub → Dataflow streaming → BigQuery/Bigtable |
| Costo | Menor; amortizado | Mayor; workers siempre encendidos |
| Uso con ML | Batch prediction, reentrenamiento | Features online, fraude/personalización en tiempo real |
| Modo de fallo | Job tardío → modelo obsoleto | Backpressure, watermark lag → *features* obsoletas bajo tráfico en vivo |

### 3.3 Dimensiones de calidad de datos (el checklist de diagnóstico)

**Completitud · Exactitud · Consistencia · Oportunidad · Validez · Unicidad**

Cada una de estas mapea a un chequeo automatizable. Aplicalas *antes* del job de entrenamiento, no después — un test de datos fallido cuesta segundos; un mal modelo cuesta un día de acelerador más un incidente en producción.

### 3.4 Economía del labeling

Las etiquetas son el insumo escaso. Para un clasificador supervisado, presupuestá el pipeline de etiquetado explícitamente:

```
labels_needed ≈ 1,000–10,000 per class for tabular AutoML
cost_per_label = human_minutes × loaded_hourly_rate / 60
total = labels_needed × classes × cost_per_label × redundancy(2–3 for inter-rater agreement)
```

Un clasificador de tickets de soporte de 12 clases con 2.000 etiquetas/clase, 20 s/etiqueta, $30/h cargados, redundancia 2× ≈ **$8.000 solo en labeling** — habitualmente mayor que el presupuesto de cómputo, y es un costo *recurrente* porque las taxonomías derivan.

### 3.5 Training-serving skew — el asesino silencioso número uno

El skew ocurre cuando el camino de cómputo de features en tiempo de entrenamiento difiere del camino en tiempo de serving.

| Origen del skew | Ejemplo concreto | Corrección estructural |
|---|---|---|
| Caminos de código distintos | Entrenamiento en SQL/PySpark, serving en Java | Definición única de features en el Feature Store; librería de transformación compartida |
| Fuentes de datos distintas | Entrenamiento sobre un snapshot nocturno del warehouse, serving desde OLTP en vivo | Servir desde el mismo store que materializó las features de entrenamiento |
| Fuga por viaje en el tiempo | El entrenamiento hizo join con un valor conocido solo *después* del momento de la predicción | Joins point-in-time-correct (el Feature Store los impone) |
| Defaults distintos | Entrenamiento imputa NULL→0, serving pasa NULL tal cual | Mover la imputación dentro del grafo del modelo / contenedor de serving |

**Drift vs skew:**
- **Skew** = distribución de entrenamiento ≠ distribución de serving *ahora*.
- **Data drift** = la distribución de serving cambia *con el tiempo*.
- **Concept drift** = la relación P(y|x) misma cambia (modelos de demanda en la era COVID; nuevas tácticas de fraude).

El skew es un bug. El drift es física — se planifica con triggers de reentrenamiento.

### 3.6 Controles de gobernanza (relevantes para el examen, propiedad del SRE)

| Control | Servicio | Punto de aplicación |
|---|---|---|
| Descubrimiento y linaje | Dataplex Universal Catalog | Catálogo, linaje a nivel de columna |
| Descubrimiento y redacción de PII | Sensitive Data Protection (Cloud DLP) | Escaneo pre-ingesta, plantillas de des-identificación |
| Perímetro | VPC Service Controls | Previene la exfiltración de datos de entrenamiento/modelos |
| Claves de cifrado | CMEK (Cloud KMS) | Buckets, datasets de BigQuery, recursos de Vertex |
| Acceso | IAM + seguridad a nivel de fila/columna en BigQuery | Dataset, tabla, columna |
| Residencia | Recursos regionales + Org Policy `gcp.resourceLocations` | Proyecto/carpeta |
| Retención de datos | Object lifecycle, expiración de tablas de BigQuery | Bucket/dataset |

---

## 4. La escalera de soluciones de AI de Google Cloud — la decisión central de ubicación

```
 ABSTRACTION ▲
             │  ┌──────────────────────────────────────────────────────────────┐
        HIGH │  │ 1. Pre-built agents / applied AI                             │
             │  │    CCAI, Agentspace, Vertex AI Search, Document AI, Health AI│
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 2. Pre-trained APIs                                          │
             │  │    Vision, Speech-to-Text, Text-to-Speech, Translation,      │
             │  │    Natural Language, Video Intelligence                      │
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 3. Foundation models + adaptation                            │
             │  │    Gemini via Vertex AI Studio, Model Garden, RAG Engine,    │
             │  │    supervised tuning, Agent Builder / ADK                    │
             │  ├──────────────────────────────────────────────────────────────┤
             │  │ 4. Low-code custom models                                    │
             │  │    AutoML (tabular/image/text/video), BigQuery ML (SQL)      │
             │  ├──────────────────────────────────────────────────────────────┤
         LOW │  │ 5. Fully custom                                              │
             │  │    Vertex AI Training containers, GKE + GPU/TPU, Ray on VAI  │
             ▼  └──────────────────────────────────────────────────────────────┘
                CONTROL ▲ , TIME-TO-VALUE ▼ , TCO ▲ , REQUIRED SKILL ▲
```

### 4.1 Matriz de trade-offs

| Escalón | Datos que tenés que aportar | Skill de ML | Tiempo al primer valor | Modelo de costo marginal | Diferenciación | Elegilo cuando |
|---|---|---|---|---|---|---|
| **1. Agentes preconstruidos** | Tu contenido/corpus | Ninguno | Días | Por consulta / por sesión / por asiento | Ninguna | Problema vertical resuelto (contact center, búsqueda empresarial) |
| **2. APIs pre-entrenadas** | Ninguno (mandás el payload) | Ninguno | Horas | Por 1.000 unidades (imagen, minuto, carácter) | Ninguna | Tarea de percepción commodity; no existe señal propietaria |
| **3. Foundation models** | Prompts + corpus opcional | Skills de prompt/RAG | Días | Por 1M tokens de input + output | Media (tus datos vía RAG) | Lenguaje/multimodal, abierto, generativo |
| **4. AutoML / BigQuery ML** | Datos tabulares/media etiquetados | Nivel analista | Días–semanas | Node-hours (AutoML) o bytes escaneados + slots (BQML) | **Alta** — tus datos | Datos estructurados propietarios, tarea estándar |
| **5. Custom training** | Todo | ML engineers + equipo de plataforma | Semanas–meses | Horas de acelerador + nodos de serving | **La más alta** | Arquitectura novedosa, escala/latencia extremas, foso de IP |

**Procedimiento de decisión (enunciarlo en este orden — el examen lo premia):**

1. ¿Es un problema vertical *resuelto*? → escalón 1.
2. ¿Es una tarea de percepción *genérica* (OCR, transcripción, traducción, detección de objetos)? → escalón 2.
3. ¿La salida es *contenido generado* o lenguaje abierto? → escalón 3.
4. ¿Tenés *datos estructurados propietarios etiquetados* y una tarea estándar? → escalón 4. Preferí **BigQuery ML** si los datos ya están en BigQuery — la gravedad de los datos le gana a todo.
5. Solo si 1–4 fallan → escalón 5.

> **Nunca bajes un escalón por prestigio.** El escalón 5 multiplica headcount, superficie de on-call y TCO por aproximadamente un orden de magnitud respecto del escalón 4 para el mismo KPI de negocio.

### 4.2 AutoML vs BigQuery ML vs custom

| | BigQuery ML | Vertex AI AutoML | Custom training |
|---|---|---|---|
| Interfaz | SQL | Consola / API | Python + contenedor |
| Movimiento de datos | **Cero** (los datos quedan en BigQuery) | Export/import | Pipeline completo |
| Tipos de modelo | Lineal/logístico, k-means, boosted trees, DNN, ARIMA_PLUS, factorización de matrices, PCA, autoencoder, modelos Gemini remotos | Tabular, imagen, texto, video | Cualquiera |
| Feature engineering | Cláusula `TRANSFORM` — persistida en el modelo, **elimina el serving skew** | Automático | A tu cargo |
| Tiempo típico de entrenamiento | Minutos | 1–24 h (node-hours) | Horas–días |
| Serving | `ML.PREDICT` en SQL, o export a un Vertex Endpoint | Vertex Endpoint / batch | Cualquiera |
| Mejor para | Equipos de analistas, datos residentes en el warehouse, baselines rápidos | Media + tabular, sin código | Grado investigación, SLO extremo |

---

## 5. Sustrato de cómputo: CPU vs GPU vs TPU

| | CPU | GPU (L4 / A100 / H100) | TPU (v5e / v5p / Trillium) |
|---|---|---|---|
| Modelo de paralelismo | Pocos núcleos generales rápidos | Miles de núcleos SIMT | Arreglo sistólico para matmul denso |
| Mejor encaje | Modelos tabulares chicos, preprocesamiento, inferencia de bajo QPS | Entrenamiento e inferencia de deep learning, kernels CUDA custom, cargas mixtas | Entrenamiento de transformers densos muy grandes y serving de alto throughput |
| Ecosistema | Universal | CUDA — el soporte de frameworks más amplio | JAX / TensorFlow / PyTorch-XLA |
| Interconexión | — | NVLink / NVSwitch dentro del host | Inter-Chip Interconnect, toro 2D/3D a través de pods |
| Costo/rendimiento a escala | Malo para DL | Bueno | Mejor rendimiento por dólar para modelos grandes soportados |
| Truco de elasticidad | Preemptible/Spot | GPUs Spot, DWS (Dynamic Workload Scheduler) | TPUs Spot, queued resources |
| Ojo con | Nada | Cuota por región, pinning de versión de driver/CUDA | El modelo debe ser compatible con XLA; el sharding es tarea de diseño |

**Ranking de palancas de costo para entrenamiento (mayor impacto primero):** capacidad Spot/DWS → acelerador bien dimensionado → precisión mixta (bf16) → pipeline de datos eficiente (la inanición del input pipeline desperdicia el 100 % del acelerador) → estrategia distribuida → modelo más chico/distillation.

---

## 6. Arquitecturas de serving

| Opción | Latencia | Autoescala a cero | Carga operativa | Usar cuando |
|---|---|---|---|---|
| **Vertex AI online Endpoint** | ~10–100 ms | No (min replicas ≥ 1 para dedicados) | Baja | Predicción online estándar, traffic splitting, monitoreo integrado |
| **Vertex AI batch prediction** | Minutos–horas | N/A | La más baja | Scorear millones de filas cada noche; lo más barato por predicción |
| **BigQuery `ML.PREDICT`** | En tiempo de consulta | N/A | La más baja | Scores consumidos por analytics/BI; sin egreso de datos |
| **GKE + KServe / Triton** | Alcanzable en un dígito de ms | Sí (KServe/Knative) | Alta | Runtimes custom, multi-modelo, GPU sharing, control estricto de costos, híbrido |
| **Cloud Run (+ GPU)** | ~50–500 ms incl. cold start | **Sí** | Baja | Cargas con picos y bajo QPS promedio |
| **Edge / on-device** | Sub-ms, offline | N/A | Media | Air-gapped, privacidad, ancho de banda limitado |

**Aritmética del presupuesto de latencia para un SLO de 200 ms de cara al usuario:**

```
  client → LB               ~10 ms
  auth / API gateway        ~15 ms
  feature fetch (online FS) ~20 ms   ← Bigtable-backed, p99
  vector retrieval (RAG)    ~35 ms
  model forward pass        ~40 ms   ← the only part people optimise
  post-process + response   ~15 ms
  ------------------------------------
  budget consumed          ~135 ms
  headroom for p99 tail     ~65 ms
```

El modelo es el 30 % del presupuesto. Optimizarlo aisladamente es la mala asignación clásica.

---

## 7. Madurez de MLOps — el modelo operativo

| Nivel | Descripción | Trigger de entrenamiento | Unidad de despliegue | Cadencia típica | Forma del equipo |
|---|---|---|---|---|---|
| **0 — Manual** | Notebook → traspaso → deploy manual | Humano | Artefacto de modelo entrenado | Meses | Solo data scientists |
| **1 — Automatización del pipeline de ML** | Pipeline de entrenamiento automatizado y parametrizado; continuous training (CT) | Agenda, volumen de datos, alerta de drift | **El pipeline**, más el modelo | Semanas → días | + ML engineer |
| **2 — Automatización de pipeline CI/CD** | Build/test/deploy de componentes del pipeline disparado desde el código fuente | Commit de código, datos, drift, performance | *Componentes* del pipeline (contenedores) | Días → horas | + Platform/SRE |

**Artefactos requeridos en el nivel 2:**
- Definición del pipeline bajo control de versiones (KFP/TFX) y contenedores de componentes en Artifact Registry.
- Model Registry con versiones inmutables, linaje hasta el snapshot de datos + SHA del código.
- **Gates** de evaluación automatizados (piso de accuracy, slices de fairness, latencia, esquema del payload).
- Entrega progresiva: shadow → canary (traffic split) → completo, con rollback automático.
- Model Monitoring con alertas hacia la misma rotación de on-call que el resto de la plataforma.

---

## 8. Valor de negocio — la parte que el examen realmente califica

### 8.1 La cadena de valor

```
Data asset ──▶ Model metric ──▶ Decision change ──▶ Operational KPI ──▶ Financial outcome
(clean,        (AUC 0.87)       (auto-route 62 %   (AHT −90 s,        (−$2.1 M/yr opex,
 governed)                       of tickets)        CSAT +4 pts)        +$0.9 M retained rev)
```

**Una métrica de modelo nunca es el caso de negocio.** Un AUC de 0,87 vale exactamente $0 hasta que una decisión cambia. Toda propuesta de AI debe nombrar (a) la decisión, (b) quién o qué la toma hoy, (c) el baseline contrafactual y (d) el plan de medición.

### 8.2 Los cuatro arquetipos de valor

| Arquetipo | Mecanismo | Ejemplo | KPI principal |
|---|---|---|---|
| **Reducción de costos** | Automatizar/asistir el esfuerzo humano | Triage de tickets, extracción de documentos, asistencia de código | Costo por transacción, tiempo de gestión, horas-FTE |
| **Crecimiento de ingresos** | Mejor targeting/personalización | Recomendaciones, propensión, pricing dinámico | Conversión, AOV, LTV, tasa de attach |
| **Reducción de riesgo** | Detectar lo que los humanos no ven | Fraude, AML, mantenimiento predictivo, detección de anomalías | Tasa de pérdida, tasa de falsos negativos, downtime no planificado |
| **Nueva capacidad** | Productos imposibles sin AI | Traducción en tiempo real, diseño generativo, productos conversacionales | Ingresos por productos nuevos, entrada a mercados |

### 8.3 Unit economics — el modelo que todo arquitecto debería poder esbozar

> Las cifras de abajo son **aritmética ilustrativa**, no cotizaciones. Recalculá siempre contra las páginas de precios vigentes de la §14 para tu región y SKU.

```
Use case: classify 3,000,000 support tickets/month into 12 queues.

OPTION A — Vertex AI online Endpoint (AutoML tabular/text, n1-standard-4 replicas)
  Peak 40 QPS, avg 12 QPS → 3 replicas steady, 6 at peak (~4 avg replicas)
  Serving:      4 replicas × 730 h × $node_hour
  Training:     ~6 node-hours/retrain × 2 retrains/month
  Monitoring:   per-prediction sampling
  → Fixed monthly floor exists even at 03:00 traffic.

OPTION B — Vertex AI batch prediction, hourly windows
  3M rows/month, batched 4,200/hour
  → No always-on replicas; cost scales with rows, ~1 order of magnitude cheaper
  → Acceptable ONLY if a ≤60 min routing delay meets the business SLA.

OPTION C — Gemini via Vertex AI, zero-shot with a rubric prompt
  avg 900 input + 15 output tokens per ticket
  3M × 900  = 2.70 B input tokens/month
  3M × 15   = 0.045 B output tokens/month
  → cost = 2700 × $in_per_1M + 45 × $out_per_1M
  → Levers: prompt compression (−40 % input tokens), context caching for the
    shared rubric, batch API discount, distillation to a small model.

DECISION RULE
  Latency SLA ≤ seconds and QPS high & stable      → A
  Latency SLA in minutes/hours                     → B  (usually 5–20× cheaper)
  Taxonomy volatile / no labels / needs rationale  → C, then distil to A or B once
                                                     you have accumulated labels
```

La regla generalizable: **la AI generativa te compra time-to-value y flexibilidad; el ML clásico te compra costo unitario.** Los sistemas maduros arrancan en C para bootstrapear etiquetas y terminan en A/B para el volumen de régimen.

### 8.4 Costo total de propiedad — lo que las propuestas olvidan

| Línea de costo | ¿Se omite con frecuencia? | Notas |
|---|---|---|
| Cómputo de entrenamiento | No | Suele sobreestimarse |
| Cómputo de serving | A veces | Domina en modelos online, siempre encendidos |
| **Labeling de datos** | **Sí** | A menudo la mayor línea individual; recurrente |
| **Ingeniería del pipeline de datos** | **Sí** | 40–60 % del esfuerzo total |
| Almacenamiento (crudo + features + artefactos + logs) | Sí | Loguear predicciones a escala no es trivial |
| Monitoreo y evaluación | Sí | Incluye paneles de revisión humana para GenAI |
| **Cadencia de reentrenamiento** | **Sí** | El drift es perpetuo; presupuestalo como run-rate, no como proyecto |
| Gobernanza, model cards, auditoría | Sí | En industrias reguladas: significativo |
| Carga de on-call / incidentes | Sí | Nueva clase de alertas, nuevos runbooks |
| Baja del modelo | Sí | Las dependencias en la sombra son difíciles de encontrar |

### 8.5 Instrumentación de KPIs

| Capa | Indicador adelantado | Indicador rezagado | Responsable |
|---|---|---|---|
| Datos | Lag de frescura, tasa de nulos, violaciones de esquema | Fallos de reentrenamiento | Data platform |
| Modelo | Estabilidad de la distribución de predicciones, score de feature drift, attribution drift | Accuracy/AUC sobre etiquetas diferidas | ML engineering |
| Servicio | Latencia p99, tasa de errores, saturación de réplicas, costo/1k predicciones | Gasto mensual | SRE |
| Producto | % de adopción, tasa de override/rechazo, tasa de escalamiento humano | Conversión, churn, AHT, tasa de pérdida | Producto |
| Negocio | Margen incremental por decisión | Impacto anualizado en P&L | Finanzas/Negocio |

**La tasa de override es la métrica más subestimada.** Si los agentes anulan al modelo el 45 % de las veces, el modelo produce cero cambio de decisión sin importar su AUC.

### 8.6 Medir causalmente

Los dashboards correlacionales ("los usuarios que vieron recomendaciones convirtieron 22 % más") no son evidencia. Usá:
1. **Test A/B** — el holdout aleatorizado es lo predeterminado y lo más fuerte.
2. **Switchback / geo test** — cuando la interferencia entre usuarios rompe el A/B.
3. **Pre-post con grupo de control** — el más débil; solo cuando la aleatorización es imposible.

Mantené siempre una **población de holdout** permanente (1–5 %) sin el modelo aplicado. Es la única forma de saber, doce meses después, cuánto vale el modelo.

---

## 9. Responsible AI como control de ingeniería

### 9.1 Los AI Principles de Google

El framework original de 2018 enumeraba **siete principios** — la AI debe (1) ser socialmente beneficiosa, (2) evitar crear o reforzar sesgos injustos, (3) ser construida y probada en función de la seguridad, (4) rendir cuentas a las personas, (5) incorporar principios de diseño de privacidad, (6) sostener altos estándares de excelencia científica, (7) ponerse a disposición para usos acordes con estos principios — más cuatro áreas de aplicación que Google no perseguirá (tecnologías que causen daño general, armas, vigilancia que viole normas internacionales y usos que contravengan el derecho internacional y los derechos humanos). Google reestructuró sus AI Principles publicados en 2025 en torno a **innovación audaz, desarrollo y despliegue responsables, y progreso colaborativo**; los compromisos subyacentes (fairness, seguridad, privacidad, accountability, supervisión humana) persisten. Para el examen, sabé que Google publica AI Principles vinculantes y podés articular fairness, seguridad, privacidad, explicabilidad y accountability como requisitos de diseño — verificá el texto exacto vigente en la URL de la §14.

### 9.2 Taxonomía de sesgos — y por dónde entran a tu pipeline

| Tipo de sesgo | Entra en | Detección | Mitigación |
|---|---|---|---|
| Selección / muestreo | Recolección de datos | Comparar la distribución de entrenamiento con la de la población | Reponderación, recolección dirigida |
| Histórico | El mundo que los datos registran | Análisis de performance por slices | Replantear la etiqueta, agregar restricción de fairness |
| Medición | Diferencias de instrumentación por grupo | Distribuciones de features por grupo | Arreglar la instrumentación, quitar features proxy |
| Etiquetado | Anotadores humanos | Acuerdo inter-anotador por cohorte de anotadores | Rúbricas, pools diversos, adjudicación |
| Agregación | Un solo modelo para grupos heterogéneos | Métricas por slice | Modelos por segmento o features de grupo |
| Despliegue / feedback loop | La salida del modelo moldea los futuros datos de entrenamiento | Comparación con el holdout a lo largo del tiempo | Exploración aleatorizada, holdout permanente |

**La fairness es una métrica a nivel de slice, nunca agregada.** Una accuracy general del 94 % con 71 % en un slice protegido es una falla de gobernanza que el número principal oculta. Cableá la evaluación por slices dentro del gate del pipeline.

### 9.3 Explicabilidad y supervisión humana

- **Vertex Explainable AI** provee atribuciones de features (sampled Shapley, integrated gradients, XRAI) para modelos tabulares y de imagen. El *drift* de atribución es un indicador adelantado de concept drift — las importancias de features se desplazan antes de que la accuracy se degrade visiblemente.
- **Model Cards** documentan uso previsto, uso fuera de alcance, datos de entrenamiento, slices de evaluación y limitaciones. Tratalas como artefactos de release obligatorios, igual que un runbook.
- **Human-in-the-loop**, ubicación por nivel de riesgo:

| Nivel de riesgo | Ejemplos | Patrón |
|---|---|---|
| Bajo | Recomendaciones de productos, ranking | Totalmente automatizado, monitoreado |
| Medio | Ruteo de tickets, categorización de gastos | Automatizado con umbral de confianza; baja confianza → humano |
| Alto | Crédito, contratación, medicina, legal | **Decide el humano**; el modelo asesora con explicación, la decisión se loguea y es auditable |

### 9.4 Controles de seguridad específicos de GenAI

Grounding a un corpus autoritativo · citas devueltas con cada respuesta · filtros de seguridad (acoso, odio, sexual, contenido peligroso) · defensa contra prompt injection para agentes (nunca dejar que el texto recuperado porte autoridad sobre herramientas) · des-identificación de PII antes del prompt · validación de la salida contra un esquema JSON · presupuestos de tokens y de llamadas a herramientas por sesión · logueo completo de request/response para auditoría.

---

## 10. Implementación de referencia — infraestructura completa

### 10.1 Terraform: base de la plataforma

```hcl
# ─────────────────────────────────────────────────────────────────────────────
# main.tf — Vertex AI platform foundation for a churn-prediction workload
# Terraform >= 1.6, google provider >= 5.30
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
  }
  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "ai-platform/churn"
  }
}

variable "project_id" {
  type        = string
  description = "Target Google Cloud project"
}

variable "region" {
  type        = string
  default     = "europe-west4"
  description = "Region for all regional resources; must satisfy data residency"
}

variable "kms_key_ring" {
  type        = string
  default     = "ai-platform"
}

locals {
  labels = {
    workload    = "churn-prediction"
    env         = "prod"
    cost_center = "cc-4471"
    data_class  = "confidential"
    owner       = "ml-platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── 1. Enable the APIs the platform depends on ───────────────────────────────
resource "google_project_service" "required" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "dataflow.googleapis.com",
    "dlp.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "notebooks.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
  ])
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# ── 2. Customer-managed encryption ───────────────────────────────────────────
resource "google_kms_key_ring" "ai" {
  name     = var.kms_key_ring
  location = var.region
  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "ai" {
  name            = "vertex-artifacts"
  key_ring        = google_kms_key_ring.ai.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"
  lifecycle {
    prevent_destroy = true
  }
}

# ── 3. Identity: one service account per pipeline stage (least privilege) ────
resource "google_service_account" "training" {
  account_id   = "sa-vertex-training"
  display_name = "Vertex AI training jobs (churn)"
}

resource "google_service_account" "serving" {
  account_id   = "sa-vertex-serving"
  display_name = "Vertex AI online prediction (churn)"
}

resource "google_service_account" "pipeline" {
  account_id   = "sa-vertex-pipeline"
  display_name = "Vertex AI Pipelines orchestrator (churn)"
}

resource "google_project_iam_member" "training_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.training.email}"
}

resource "google_project_iam_member" "serving_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.serving.email}"
}

resource "google_project_iam_member" "pipeline_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_kms_crypto_key_iam_member" "vertex_sa_kms" {
  crypto_key_id = google_kms_crypto_key.ai.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
}

data "google_project" "this" {
  project_id = var.project_id
}

# ── 4. Storage: staging, artifacts, prediction logs ──────────────────────────
resource "google_storage_bucket" "staging" {
  name                        = "${var.project_id}-vertex-staging"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false
  public_access_prevention    = "enforced"
  labels                      = local.labels

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ai.id
  }

  lifecycle_rule {
    condition { age = 45 }
    action     { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.vertex_sa_kms]
}

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-model-artifacts"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ai.id
  }

  # Model artifacts are the rollback surface: retain, do not delete.
  lifecycle_rule {
    condition { num_newer_versions = 20 }
    action     { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.vertex_sa_kms]
}

# ── 5. BigQuery: feature and label warehouse ─────────────────────────────────
resource "google_bigquery_dataset" "ml" {
  dataset_id                 = "ml_churn"
  friendly_name              = "Churn ML feature and label store"
  location                   = "EU"
  delete_contents_on_destroy = false
  labels                     = local.labels

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.ai.id
  }

  access {
    role          = "OWNER"
    user_by_email = google_service_account.pipeline.email
  }
  access {
    role          = "READER"
    user_by_email = google_service_account.training.email
  }
}

# ── 6. Container registry for pipeline components ────────────────────────────
resource "google_artifact_registry_repository" "components" {
  location      = var.region
  repository_id = "ml-components"
  description   = "Pipeline component and serving container images"
  format        = "DOCKER"
  kms_key_name  = google_kms_crypto_key.ai.id
  labels        = local.labels

  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"
    most_recent_versions {
      keep_count = 30
    }
  }
}

# ── 7. Serving: model + endpoint ─────────────────────────────────────────────
resource "google_vertex_ai_endpoint" "churn" {
  name         = "churn-scoring-prod"
  display_name = "churn-scoring-prod"
  description  = "Online churn propensity scoring, p99 SLO 120 ms"
  location     = var.region
  region       = var.region
  labels       = local.labels

  encryption_spec {
    kms_key_name = google_kms_crypto_key.ai.id
  }
}

# ── 8. Retraining trigger topic (drift alerts fan out to here) ───────────────
resource "google_pubsub_topic" "retrain_trigger" {
  name   = "ml-churn-retrain-trigger"
  labels = local.labels
}

# ── 9. Alerting on the drift/skew signal ─────────────────────────────────────
resource "google_monitoring_notification_channel" "oncall" {
  display_name = "ML Platform on-call"
  type         = "pubsub"
  labels = {
    topic = google_pubsub_topic.retrain_trigger.id
  }
}

resource "google_monitoring_alert_policy" "prediction_latency" {
  display_name = "churn-endpoint p99 latency > 120ms"
  combiner     = "OR"

  conditions {
    display_name = "p99 prediction latency"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"aiplatform.googleapis.com/Endpoint\"",
        "metric.type = \"aiplatform.googleapis.com/prediction/online/response_latencies\"",
        "resource.label.endpoint_id = \"${google_vertex_ai_endpoint.churn.name}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 120
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.oncall.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "Runbook: docs/runbooks/churn-endpoint-latency.md"
    mime_type = "text/markdown"
  }
}

output "endpoint_id" {
  value       = google_vertex_ai_endpoint.churn.id
  description = "Fully-qualified endpoint resource name"
}

output "artifact_bucket" {
  value = google_storage_bucket.artifacts.url
}
```

### 10.2 Vertex AI Pipeline (Kubeflow Pipelines v2) — definición del pipeline de entrenamiento

```python
# pipeline.py — compiled with: kfp dsl-compile / compiler.Compiler()
# Produces churn_training_pipeline.yaml, submitted to Vertex AI Pipelines.
from kfp import dsl, compiler
from kfp.dsl import Dataset, Input, Metrics, Model, Output

PROJECT = "acme-ml-prod"
REGION = "europe-west4"
IMAGE = f"{REGION}-docker.pkg.dev/{PROJECT}/ml-components/churn-trainer:1.7.3"


@dsl.component(base_image=IMAGE, packages_to_install=["google-cloud-bigquery==3.25.0"])
def validate_data(
    bq_table: str,
    min_rows: int,
    max_null_ratio: float,
    validated: Output[Dataset],
) -> None:
    """Fail the pipeline BEFORE spending accelerator time on bad data."""
    from google.cloud import bigquery

    client = bigquery.Client()
    query = f"""
    SELECT
      COUNT(*)                                          AS row_count,
      COUNTIF(tenure_days IS NULL) / COUNT(*)           AS null_tenure,
      COUNTIF(monthly_spend IS NULL) / COUNT(*)         AS null_spend,
      COUNTIF(churned IS NULL) / COUNT(*)               AS null_label,
      COUNT(DISTINCT customer_id)                       AS distinct_customers,
      MAX(snapshot_date)                                AS freshest
    FROM `{bq_table}`
    """
    row = list(client.query(query).result())[0]

    if row.row_count < min_rows:
        raise ValueError(f"completeness: {row.row_count} rows < {min_rows}")
    for name in ("null_tenure", "null_spend", "null_label"):
        if getattr(row, name) > max_null_ratio:
            raise ValueError(f"completeness: {name}={getattr(row, name):.4f} > {max_null_ratio}")
    if row.distinct_customers != row.row_count:
        raise ValueError("uniqueness: duplicate customer_id in training snapshot")

    with open(validated.path, "w") as fh:
        fh.write(bq_table)


@dsl.component(base_image=IMAGE)
def train_model(
    validated: Input[Dataset],
    learning_rate: float,
    max_depth: int,
    n_estimators: int,
    model: Output[Model],
    metrics: Output[Metrics],
) -> None:
    import json, os, joblib
    import pandas as pd
    from google.cloud import bigquery
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.metrics import roc_auc_score, average_precision_score
    from sklearn.model_selection import train_test_split

    table = open(validated.path).read().strip()
    df = bigquery.Client().query(f"SELECT * FROM `{table}`").to_dataframe()

    feature_cols = [c for c in df.columns if c not in ("customer_id", "churned", "snapshot_date")]
    X, y = df[feature_cols], df["churned"]
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, stratify=y, random_state=42)

    clf = GradientBoostingClassifier(
        learning_rate=learning_rate, max_depth=max_depth,
        n_estimators=n_estimators, random_state=42,
    )
    clf.fit(X_tr, y_tr)

    proba = clf.predict_proba(X_te)[:, 1]
    auc = float(roc_auc_score(y_te, proba))
    pr_auc = float(average_precision_score(y_te, proba))

    metrics.log_metric("roc_auc", auc)
    metrics.log_metric("pr_auc", pr_auc)
    metrics.log_metric("train_rows", int(len(X_tr)))
    metrics.log_metric("positive_rate", float(y.mean()))

    os.makedirs(model.path, exist_ok=True)
    joblib.dump(clf, os.path.join(model.path, "model.joblib"))
    with open(os.path.join(model.path, "feature_order.json"), "w") as fh:
        json.dump(feature_cols, fh)  # serving must replay this exact order


@dsl.component(base_image=IMAGE)
def evaluate_fairness(
    validated: Input[Dataset],
    model: Input[Model],
    slice_column: str,
    min_slice_auc: float,
    max_auc_gap: float,
    report: Output[Metrics],
) -> bool:
    """Gate: no slice may fall below the floor, and the spread is bounded."""
    import json, joblib, os
    from google.cloud import bigquery
    from sklearn.metrics import roc_auc_score

    table = open(validated.path).read().strip()
    df = bigquery.Client().query(f"SELECT * FROM `{table}`").to_dataframe()
    clf = joblib.load(os.path.join(model.path, "model.joblib"))
    order = json.load(open(os.path.join(model.path, "feature_order.json")))

    slice_aucs = {}
    for value, grp in df.groupby(slice_column):
        if len(grp) < 500 or grp["churned"].nunique() < 2:
            continue
        slice_aucs[str(value)] = float(
            roc_auc_score(grp["churned"], clf.predict_proba(grp[order])[:, 1])
        )

    for name, auc in slice_aucs.items():
        report.log_metric(f"auc_{name}", auc)

    worst, best = min(slice_aucs.values()), max(slice_aucs.values())
    report.log_metric("worst_slice_auc", worst)
    report.log_metric("auc_gap", best - worst)

    return worst >= min_slice_auc and (best - worst) <= max_auc_gap


@dsl.component(base_image=IMAGE)
def register_and_deploy(
    project: str,
    region: str,
    endpoint_id: str,
    model: Input[Model],
    display_name: str,
    canary_percent: int,
) -> None:
    from google.cloud import aiplatform

    aiplatform.init(project=project, location=region)
    uploaded = aiplatform.Model.upload(
        display_name=display_name,
        artifact_uri=model.uri,
        serving_container_image_uri=(
            f"{region}-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest"
        ),
        labels={"workload": "churn-prediction", "env": "prod"},
    )
    endpoint = aiplatform.Endpoint(endpoint_id)
    uploaded.deploy(
        endpoint=endpoint,
        deployed_model_display_name=display_name,
        machine_type="n1-standard-4",
        min_replica_count=2,
        max_replica_count=10,
        traffic_percentage=canary_percent,   # progressive delivery, not big-bang
        enable_access_logging=True,
    )


@dsl.pipeline(
    name="churn-training-pipeline",
    description="Validated, gated, canary-deployed churn model",
    pipeline_root="gs://acme-ml-prod-vertex-staging/pipelines/churn",
)
def churn_pipeline(
    bq_table: str = "acme-ml-prod.ml_churn.training_snapshot",
    endpoint_id: str = "projects/acme-ml-prod/locations/europe-west4/endpoints/churn-scoring-prod",
    learning_rate: float = 0.05,
    max_depth: int = 4,
    n_estimators: int = 400,
    min_rows: int = 250000,
    max_null_ratio: float = 0.02,
    slice_column: str = "region_code",
    min_slice_auc: float = 0.78,
    max_auc_gap: float = 0.07,
    canary_percent: int = 10,
):
    v = validate_data(bq_table=bq_table, min_rows=min_rows, max_null_ratio=max_null_ratio)
    v.set_caching_options(False)  # data changes even when parameters do not

    t = train_model(
        validated=v.outputs["validated"],
        learning_rate=learning_rate,
        max_depth=max_depth,
        n_estimators=n_estimators,
    )
    t.set_cpu_limit("8").set_memory_limit("32G")
    t.set_retry(num_retries=2, backoff_duration="60s")

    f = evaluate_fairness(
        validated=v.outputs["validated"],
        model=t.outputs["model"],
        slice_column=slice_column,
        min_slice_auc=min_slice_auc,
        max_auc_gap=max_auc_gap,
    )

    with dsl.If(f.output == True, name="fairness-gate-passed"):
        register_and_deploy(
            project="acme-ml-prod",
            region="europe-west4",
            endpoint_id=endpoint_id,
            model=t.outputs["model"],
            display_name="churn-gbc",
            canary_percent=canary_percent,
        )


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=churn_pipeline,
        package_path="churn_training_pipeline.yaml",
    )
```

### 10.3 Job de Vertex AI Model Monitoring (drift + skew) — payload del request

```yaml
# monitoring-job.yaml — POST to
#   https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/
#   locations/europe-west4/modelDeploymentMonitoringJobs
displayName: churn-scoring-prod-monitoring
endpoint: projects/acme-ml-prod/locations/europe-west4/endpoints/churn-scoring-prod

# Sample 20% of live traffic; 100% is rarely necessary and costs storage.
loggingSamplingStrategy:
  randomSampleConfig:
    sampleRate: 0.2

modelDeploymentMonitoringScheduleConfig:
  monitorInterval: 3600s          # hourly analysis window

modelMonitoringAlertConfig:
  emailAlertConfig:
    userEmails:
      - ml-platform-oncall@acme.example
  enableLogging: true             # emits to Cloud Logging → alert policy → Pub/Sub

# The training baseline. Skew = live vs THIS. Drift = live vs previous window.
modelDeploymentMonitoringObjectiveConfigs:
  - deployedModelId: "4471029384756201984"
    objectiveConfig:
      trainingDataset:
        dataFormat: bigquery
        bigquerySource:
          inputUri: bq://acme-ml-prod.ml_churn.training_snapshot
        targetField: churned
      trainingPredictionSkewDetectionConfig:
        skewThresholds:
          tenure_days:        { value: 0.10 }
          monthly_spend:      { value: 0.10 }
          support_tickets_30d:{ value: 0.15 }
          region_code:        { value: 0.05 }
          plan_tier:          { value: 0.05 }
        attributionScoreSkewThresholds:
          tenure_days:   { value: 0.20 }
          monthly_spend: { value: 0.20 }
      predictionDriftDetectionConfig:
        driftThresholds:
          tenure_days:        { value: 0.10 }
          monthly_spend:      { value: 0.10 }
          support_tickets_30d:{ value: 0.15 }
          region_code:        { value: 0.05 }
          plan_tier:          { value: 0.05 }
        attributionScoreDriftThresholds:
          tenure_days:   { value: 0.20 }
          monthly_spend: { value: 0.20 }
      explanationConfig:
        enableFeatureAttributes: true

logTtl: 2592000s                  # 30 days of prediction logs
labels:
  workload: churn-prediction
  env: prod
```

### 10.4 Serving autogestionado en GKE con KServe (escalón 5 / con control de costos)

```yaml
# ─── namespace + quota: an ML namespace without a quota WILL consume the cluster
apiVersion: v1
kind: Namespace
metadata:
  name: ml-serving
  labels:
    workload: churn-prediction
    env: prod
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ml-serving-quota
  namespace: ml-serving
spec:
  hard:
    requests.cpu: "64"
    requests.memory: 256Gi
    requests.nvidia.com/gpu: "8"
    limits.cpu: "128"
    limits.memory: 512Gi
    persistentvolumeclaims: "20"
---
# ─── Workload Identity: no service-account keys on disk, ever
apiVersion: v1
kind: ServiceAccount
metadata:
  name: churn-serving
  namespace: ml-serving
  annotations:
    iam.gke.io/gcp-service-account: sa-vertex-serving@acme-ml-prod.iam.gserviceaccount.com
---
# ─── KServe InferenceService: model server + transformer, autoscaled on concurrency
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: churn-scorer
  namespace: ml-serving
  annotations:
    serving.kserve.io/enable-prometheus-scraping: "true"
    autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
    autoscaling.knative.dev/metric: concurrency
    autoscaling.knative.dev/target: "8"
    autoscaling.knative.dev/window: "60s"
spec:
  predictor:
    serviceAccountName: churn-serving
    minReplicas: 2
    maxReplicas: 20
    scaleTarget: 8
    scaleMetric: concurrency
    containerConcurrency: 16
    timeout: 5
    sklearn:
      protocolVersion: v2
      storageUri: gs://acme-ml-prod-model-artifacts/churn/v1.7.3/
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          cpu: "4"
          memory: 8Gi
      env:
        - name: OMP_NUM_THREADS
          value: "2"                 # prevents BLAS thread storms under high replica count
    nodeSelector:
      cloud.google.com/compute-class: Balanced
    tolerations:
      - key: ml-serving
        operator: Equal
        value: "true"
        effect: NoSchedule
  transformer:
    serviceAccountName: churn-serving
    minReplicas: 2
    maxReplicas: 20
    containers:
      - name: kserve-container
        image: europe-west4-docker.pkg.dev/acme-ml-prod/ml-components/churn-transformer:1.7.3
        args:
          - --model_name=churn-scorer
          - --feature_store_endpoint=featurestore.googleapis.com
          - --feature_view=customer_online_v3
        resources:
          requests:
            cpu: "1"
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
        readinessProbe:
          httpGet:
            path: /v2/health/ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /v2/health/live
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 15
---
# ─── Canary via KServe canaryTrafficPercent is set on update; explicit PDB here
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: churn-scorer-pdb
  namespace: ml-serving
spec:
  minAvailable: 1
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
---
# ─── Deny-by-default egress: a model server has no business calling the internet
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: churn-scorer-egress
  namespace: ml-serving
spec:
  podSelector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 199.36.153.8/30      # private.googleapis.com
      ports:
        - protocol: TCP
          port: 443
---
# ─── SLO burn-rate alert as code
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: churn-scorer-metrics
  namespace: ml-serving
spec:
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: churn-scorer
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### 10.5 Cloud Build: CI para los componentes del pipeline (MLOps nivel 2)

```yaml
# cloudbuild.yaml — triggered on push to main under ml/churn/**
substitutions:
  _REGION: europe-west4
  _REPO: ml-components
  _PIPELINE_ROOT: gs://acme-ml-prod-vertex-staging/pipelines/churn
  _SA: sa-vertex-pipeline@acme-ml-prod.iam.gserviceaccount.com

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: E2_HIGHCPU_8
  dynamicSubstitutions: true

steps:
  - id: unit-tests
    name: python:3.12-slim
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir -r ml/churn/requirements-dev.txt
        pytest ml/churn/tests -q --junitxml=/workspace/junit.xml

  - id: data-contract-test
    name: python:3.12-slim
    waitFor: ['unit-tests']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir -r ml/churn/requirements-dev.txt
        python ml/churn/tests/assert_schema.py \
          --table acme-ml-prod.ml_churn.training_snapshot \
          --contract ml/churn/contracts/training_snapshot.yaml

  - id: build-trainer
    name: gcr.io/cloud-builders/docker
    waitFor: ['data-contract-test']
    args:
      - build
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer:$SHORT_SHA
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer:latest
      - -f
      - ml/churn/Dockerfile.trainer
      - ml/churn

  - id: build-transformer
    name: gcr.io/cloud-builders/docker
    waitFor: ['data-contract-test']
    args:
      - build
      - -t
      - ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-transformer:$SHORT_SHA
      - -f
      - ml/churn/Dockerfile.transformer
      - ml/churn

  - id: push
    name: gcr.io/cloud-builders/docker
    waitFor: ['build-trainer', 'build-transformer']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        docker push --all-tags ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-trainer
        docker push --all-tags ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPO}/churn-transformer

  - id: compile-pipeline
    name: python:3.12-slim
    waitFor: ['push']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir kfp==2.9.0 google-cloud-aiplatform==1.71.0
        python ml/churn/pipeline.py
        gsutil cp churn_training_pipeline.yaml \
          ${_PIPELINE_ROOT}/definitions/churn_training_pipeline_$SHORT_SHA.yaml

  - id: submit-pipeline
    name: python:3.12-slim
    waitFor: ['compile-pipeline']
    entrypoint: bash
    args:
      - -c
      - |
        set -euo pipefail
        pip install --no-cache-dir google-cloud-aiplatform==1.71.0
        python - <<'PY'
        import os
        from google.cloud import aiplatform
        aiplatform.init(project="acme-ml-prod", location="europe-west4",
                        staging_bucket="gs://acme-ml-prod-vertex-staging")
        job = aiplatform.PipelineJob(
            display_name=f"churn-training-{os.environ['SHORT_SHA']}",
            template_path="churn_training_pipeline.yaml",
            pipeline_root="gs://acme-ml-prod-vertex-staging/pipelines/churn",
            parameter_values={"canary_percent": 10},
            enable_caching=True,
        )
        job.submit(service_account="sa-vertex-pipeline@acme-ml-prod.iam.gserviceaccount.com")
        print(job.resource_name)
        PY

artifacts:
  objects:
    location: gs://acme-ml-prod-vertex-staging/builds/$SHORT_SHA/
    paths: ['churn_training_pipeline.yaml', 'junit.xml']

timeout: 2400s
```

---

## 11. Recorrido por CLI

### 11.1 Establecer la escalera empíricamente — primero la API pre-entrenada

```bash
$ gcloud config set project acme-ml-prod
Updated property [core/project].

$ gcloud services enable vision.googleapis.com aiplatform.googleapis.com \
    bigquery.googleapis.com
Operation "operations/acat.p2-812446903715-3f0a1c9e-4b21-4d77-9c8e-5a1f0b7e2d31" finished successfully.

$ gcloud ml vision detect-text gs://acme-docs-inbound/invoice-88213.pdf 2>/dev/null | head -20
{
  "responses": [
    {
      "fullTextAnnotation": {
        "text": "ACME SUPPLIES LTD\nInvoice 88213\nDate 2026-08-19\nTotal EUR 4,182.50\n"
      },
      "textAnnotations": [
        {
          "description": "ACME SUPPLIES LTD",
          "locale": "en",
          "boundingPoly": {
            "vertices": [
              { "x": 118, "y": 94 },
              { "x": 612, "y": 94 },
```

> El escalón 2 resolvió el OCR en un comando y con cero entrenamiento. Solo si la pregunta *de negocio* es "¿a qué cuenta contable va?" — un mapeo propietario y aprendido — bajás al escalón 4.

### 11.2 Escalón 4: BigQuery ML — entrenar donde los datos ya están

```bash
$ bq query --use_legacy_sql=false --format=pretty '
CREATE OR REPLACE MODEL `acme-ml-prod.ml_churn.churn_baseline`
OPTIONS(
  model_type            = "BOOSTED_TREE_CLASSIFIER",
  input_label_cols      = ["churned"],
  auto_class_weights    = TRUE,
  max_iterations        = 50,
  early_stop            = TRUE,
  data_split_method     = "AUTO_SPLIT",
  enable_global_explain = TRUE
) AS
SELECT
  tenure_days,
  monthly_spend,
  support_tickets_30d,
  region_code,
  plan_tier,
  churned
FROM `acme-ml-prod.ml_churn.training_snapshot`
WHERE snapshot_date BETWEEN "2025-09-01" AND "2026-08-31";'

Waiting on bqjob_r5c9d1e77a4b3f02_0000019a3c1d8f21_1 ... (312s) Current status: DONE
Created acme-ml-prod.ml_churn.churn_baseline

$ bq query --use_legacy_sql=false --format=pretty '
SELECT * FROM ML.EVALUATE(MODEL `acme-ml-prod.ml_churn.churn_baseline`);'

+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
|      precision      |       recall        |      accuracy       |      f1_score       |      log_loss       |       roc_auc       |
+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+
| 0.71483920571043321 | 0.66207812338129014 | 0.89412773981004812 | 0.68744186046511627 | 0.24917338402271055 | 0.87326114820044319 |
+---------------------+---------------------+---------------------+---------------------+---------------------+---------------------+

$ bq query --use_legacy_sql=false --format=pretty '
SELECT * FROM ML.GLOBAL_EXPLAIN(MODEL `acme-ml-prod.ml_churn.churn_baseline`)
ORDER BY attribution DESC;'

+---------------------+----------------------+
|      feature        |     attribution      |
+---------------------+----------------------+
| support_tickets_30d |  0.41182930014772385 |
| tenure_days         |  0.28840117299102846 |
| monthly_spend       |  0.19203881744012093 |
| plan_tier           |  0.07118440229417755 |
| region_code         |  0.03654630712694921 |
+---------------------+----------------------+
```

**Leé esto como arquitecto, no como data scientist.** Una accuracy de 0,894 parece excelente pero la clase positiva es ~8 % — un modelo que siempre prediga "no churneó" sacaría 0,92. Los números significativos son **ROC-AUC 0,873** y **recall 0,662**: capturás dos de cada tres churners. La pregunta de negocio se desprende de inmediato: *¿cuánto cuesta un churner no detectado frente a una oferta de retención desperdiciada?* Esa relación, y no el F1 score, fija el umbral de decisión.

### 11.3 Evaluación por slices — el gate de fairness, en SQL

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  region_code,
  COUNT(*) AS n,
  ROUND(AVG(CAST(churned AS INT64)), 4) AS base_rate,
  ROUND(SUM(CASE WHEN predicted_churned = 1 AND churned THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN churned THEN 1 ELSE 0 END), 0), 4) AS recall
FROM ML.PREDICT(MODEL `acme-ml-prod.ml_churn.churn_baseline`,
      (SELECT * FROM `acme-ml-prod.ml_churn.holdout_snapshot`))
GROUP BY region_code
ORDER BY recall ASC;'

+-------------+--------+-----------+--------+
| region_code |   n    | base_rate | recall |
+-------------+--------+-----------+--------+
| NORDIC      |   4182 |    0.0391 | 0.4118 |
| IBERIA      |  11907 |    0.0722 | 0.5804 |
| BENELUX     |   9341 |    0.0810 | 0.6431 |
| DACH        |  28114 |    0.0847 | 0.6902 |
| UKI         |  31776 |    0.0918 | 0.7215 |
+-------------+--------+-----------+--------+
```

El recall agregado de 0,662 oculta un **0,412 en NORDIC** — subrepresentada en el entrenamiento (4.182 filas) y con una tasa base distinta. Este es un hallazgo de sesgo de agregación/selección, y es un bloqueante de release, no una nota al pie. Remediación: recolección de datos dirigida para NORDIC, umbrales por región, o un modelo condicionado por región.

### 11.4 Registry, endpoint y entrega progresiva

```bash
$ gcloud ai models list --region=europe-west4 \
    --format="table(displayName, name.basename(), versionId, createTime.date('%Y-%m-%d %H:%M'))"
DISPLAY_NAME  NAME                 VERSION_ID  CREATE_TIME
churn-gbc     8830174562931081216  3           2026-08-28 04:11
churn-gbc     8830174562931081216  2           2026-08-07 04:09
churn-gbc     8830174562931081216  1           2026-07-17 04:12

$ gcloud ai endpoints describe churn-scoring-prod --region=europe-west4 \
    --format="yaml(displayName, deployedModels[].id, deployedModels[].displayName, trafficSplit)"
deployedModels:
- displayName: churn-gbc-v2
  id: '4471029384756201984'
- displayName: churn-gbc-v3
  id: '5590318472910385664'
displayName: churn-scoring-prod
trafficSplit:
  '4471029384756201984': 90
  '5590318472910385664': 10

# Canary healthy after 24 h of monitoring — promote.
$ gcloud ai endpoints update churn-scoring-prod --region=europe-west4 \
    --traffic-split=5590318472910385664=100
Updated Vertex AI endpoint [projects/812446903715/locations/europe-west4/endpoints/churn-scoring-prod].

# Rollback is a traffic-split write, not a redeploy — seconds, not minutes.
$ gcloud ai endpoints update churn-scoring-prod --region=europe-west4 \
    --traffic-split=4471029384756201984=100
Updated Vertex AI endpoint [projects/812446903715/locations/europe-west4/endpoints/churn-scoring-prod].
```

### 11.5 Predicción online y verificación de latencia

```bash
$ cat > /tmp/instances.json <<'EOF'
{
  "instances": [
    {"tenure_days": 412, "monthly_spend": 89.90, "support_tickets_30d": 4,
     "region_code": "IBERIA", "plan_tier": "PRO"},
    {"tenure_days": 61,  "monthly_spend": 19.00, "support_tickets_30d": 0,
     "region_code": "UKI",    "plan_tier": "BASIC"}
  ]
}
EOF

$ gcloud ai endpoints predict churn-scoring-prod \
    --region=europe-west4 --json-request=/tmp/instances.json
[[0.1183, 0.8817], [0.9642, 0.0358]]

$ ENDPOINT=$(gcloud ai endpoints describe churn-scoring-prod \
    --region=europe-west4 --format="value(name)")
$ TOKEN=$(gcloud auth print-access-token)

$ for i in $(seq 1 10); do
    curl -s -o /dev/null -w "%{time_total}\n" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d @/tmp/instances.json \
      "https://europe-west4-aiplatform.googleapis.com/v1/${ENDPOINT}:predict"
  done | sort -n | awk '{a[NR]=$1} END {printf "p50=%.3fs p90=%.3fs max=%.3fs n=%d\n", a[int(NR*0.5)], a[int(NR*0.9)], a[NR], NR}'
p50=0.043s p90=0.071s max=0.118s n=10
```

### 11.6 Model Monitoring — creación y una alerta real de drift

```bash
$ curl -s -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -d @monitoring-job.json \
    "https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/locations/europe-west4/modelDeploymentMonitoringJobs" \
  | jq -r '.name, .state'
projects/812446903715/locations/europe-west4/modelDeploymentMonitoringJobs/2277104839561216000
JOB_STATE_PENDING

$ gcloud logging read '
  resource.type="aiplatform.googleapis.com/Endpoint"
  jsonPayload.anomaly_type="feature_drift"' \
  --limit=3 --freshness=6h --format=json | jq -r '.[].jsonPayload
    | "\(.feature_display_name)  observed=\(.deviation)  threshold=\(.threshold)"'
support_tickets_30d  observed=0.3418  threshold=0.15
monthly_spend        observed=0.1922  threshold=0.10
tenure_days          observed=0.0611  threshold=0.10
```

**Interpretación.** `support_tickets_30d` — la feature de mayor atribución (§11.2) — derivó 2,3× por encima de su umbral. Dos hipótesis, y exigen respuestas opuestas:

- *El mundo cambió* (un incidente de producto disparó el volumen de tickets) → concept drift → reentrenar con datos recientes y considerar una cadencia de reentrenamiento más corta.
- *El pipeline cambió* (un equipo upstream alteró la ventana de conteo de tickets de 30 a 7 días) → esto es un **bug**, y reentrenar lo dejaría horneado adentro.

Distinguilos revisando primero los datos upstream, siempre:

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  DATE_TRUNC(snapshot_date, WEEK) AS wk,
  COUNT(*) AS rows,
  ROUND(AVG(support_tickets_30d), 3) AS avg_tickets,
  ROUND(APPROX_QUANTILES(support_tickets_30d, 100)[OFFSET(99)], 3) AS p99
FROM `acme-ml-prod.ml_churn.serving_features`
WHERE snapshot_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 8 WEEK)
GROUP BY wk ORDER BY wk;'

+------------+---------+-------------+-------+
|     wk     |  rows   | avg_tickets |  p99  |
+------------+---------+-------------+-------+
| 2026-07-13 | 1041882 |       1.114 |  11.0 |
| 2026-07-20 | 1043019 |       1.098 |  11.0 |
| 2026-07-27 | 1044771 |       1.121 |  12.0 |
| 2026-08-03 | 1046203 |       1.109 |  11.0 |
| 2026-08-10 | 1047558 |       0.312 |   3.0 |   ← step change, not a trend
| 2026-08-17 | 1048901 |       0.308 |   3.0 |
| 2026-08-24 | 1050334 |       0.315 |   3.0 |
| 2026-08-31 | 1051902 |       0.311 |   3.0 |
+------------+---------+-------------+-------+
```

Un **cambio escalonado** en una única semana con conteos de filas estables es un cambio de esquema/semántica upstream, no drift orgánico. Arreglá el pipeline; no reentrenes.

### 11.7 AI generativa sobre la misma plataforma

```bash
$ gcloud ai model-garden models list --region=europe-west4 --limit=5 \
    --format="table(name, supportedActions)"
NAME                                     SUPPORTED_ACTIONS
publishers/google/models/gemini-2.5-pro   PREDICT, DEPLOY_GKE
publishers/google/models/gemini-2.5-flash PREDICT, DEPLOY_GKE
publishers/google/models/text-embedding   PREDICT
publishers/meta/models/llama-3.3          DEPLOY, DEPLOY_GKE
publishers/anthropic/models/claude        PREDICT

# Zero-shot classification, grounded, deterministic — the bootstrap path
# for a taxonomy that has no labels yet.
$ cat > /tmp/gen.json <<'EOF'
{
  "contents": [{
    "role": "user",
    "parts": [{"text": "Classify this support ticket into exactly one of: BILLING, OUTAGE, HOWTO, BUG, ACCOUNT. Reply with only the label.\n\nTicket: \"Charged twice for the August invoice, the second charge is still pending.\""}]
  }],
  "generationConfig": { "temperature": 0, "maxOutputTokens": 8, "topP": 1 }
}
EOF

$ curl -s -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" -d @/tmp/gen.json \
    "https://europe-west4-aiplatform.googleapis.com/v1/projects/acme-ml-prod/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent" \
  | jq -r '.candidates[0].content.parts[0].text, .usageMetadata'
BILLING
{
  "promptTokenCount": 58,
  "candidatesTokenCount": 2,
  "totalTokenCount": 60
}
```

El bloque `usageMetadata` es el instrumento de unit economics: 60 tokens × 3 M de tickets es el número que entra en la comparación de la §8.3, y está medido, no estimado.

### 11.8 Atribución de costos — probar el caso de negocio

```bash
$ bq query --use_legacy_sql=false --format=pretty '
SELECT
  service.description                       AS service,
  sku.description                           AS sku,
  ROUND(SUM(cost), 2)                       AS cost_usd,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS credits
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_01ABCD_234567_89EFGH`
WHERE DATE(usage_start_time) BETWEEN "2026-08-01" AND "2026-08-31"
  AND EXISTS (SELECT 1 FROM UNNEST(labels) l
              WHERE l.key = "workload" AND l.value = "churn-prediction")
GROUP BY service, sku
ORDER BY cost_usd DESC
LIMIT 8;'

+-------------------+------------------------------------------+----------+---------+
|      service      |                   sku                    | cost_usd | credits |
+-------------------+------------------------------------------+----------+---------+
| Vertex AI         | Online Prediction n1-standard-4 (europe) |  1284.66 |    0.00 |
| BigQuery          | Analysis (on-demand)                     |   311.42 |  -18.20 |
| Vertex AI         | Model Monitoring prediction sampling     |   146.03 |    0.00 |
| Cloud Storage     | Standard Storage EU multi-region         |    88.71 |    0.00 |
| Vertex AI         | Custom Training n1-highmem-8             |    72.19 |  -30.11 |
| Cloud Logging     | Log Ingestion                            |    41.88 |    0.00 |
| Artifact Registry | Storage                                  |    12.44 |    0.00 |
| Pub/Sub           | Message Delivery                         |     3.07 |    0.00 |
+-------------------+------------------------------------------+----------+---------+
```

**El serving es el 66 % del gasto; el entrenamiento, el 3,7 %.** Ese único dato redirige el esfuerzo de optimización — dimensionar bien las réplicas, evaluar batch prediction para la porción no urgente del tráfico, y dejar de tunear el job de entrenamiento. Las labels de recursos (`local.labels` en §10.1) son lo que hace posible esta consulta; sin ellas la carga de AI es invisible dentro del total del proyecto y el caso de ROI no se puede defender.

---

## 12. Verificación y diagnóstico de fallas

### 12.1 Escalera de verificación previa al vuelo

Recorrela de arriba hacia abajo; cada escalón es barato respecto del siguiente.

| # | Pregunta | Comando | Criterio de aprobación |
|---|---|---|---|
| 1 | ¿Están habilitadas las APIs? | `gcloud services list --enabled --filter="aiplatform OR bigquery"` | Todas presentes |
| 2 | ¿La SA tiene exactamente los roles que necesita? | `gcloud projects get-iam-policy $P --flatten="bindings[].members" --filter="bindings.members:sa-vertex-*"` | Sin `roles/editor`, sin `roles/owner` |
| 3 | ¿Los datos de entrenamiento están completos/son válidos? | Componente `validate_data` (§10.2) | Cero violaciones |
| 4 | ¿Hay label leakage? | Un AUC ≈ 1,0 es un bug, no un triunfo — auditá los timestamps de las features | AUC plausible para el dominio |
| 5 | ¿Las métricas por slice son aceptables? | Consulta de §11.3 | Peor slice ≥ piso; gap ≤ máximo |
| 6 | ¿El contenedor de serving reproduce los scores de entrenamiento? | Scorear 1.000 filas de entrenamiento por el endpoint y comparar | Delta absoluto máximo < 1e-6 |
| 7 | ¿El endpoint cumple el SLO de latencia? | Loop de §11.5, luego prueba de carga | p99 dentro del presupuesto |
| 8 | ¿El monitoreo está vivo y alertando? | `gcloud ai model-deployment-monitoring-jobs list` | `JOB_STATE_RUNNING` |
| 9 | ¿El gasto es atribuible? | Consulta de §11.8 | Resultado no vacío |
| 10 | ¿El rollback está probado? | Cambiar el traffic split y volver, en staging | < 60 s, sin errores |

El escalón 6 es el que los equipos se saltean y el que atrapa el training-serving skew antes que los clientes.

### 12.2 Catálogo de fallas

| Síntoma | Causa más probable | Comando de diagnóstico | Remediación |
|---|---|---|---|
| Alta accuracy offline, malos resultados en producción | **Training-serving skew** | Escalón 6 de arriba; comparar distribuciones de features entre entrenamiento y logs de serving | Unificar el cómputo de features; mover el preprocesamiento dentro del artefacto del modelo |
| AUC ≈ 0,99 en evaluación | **Label leakage** — una feature codifica el futuro | Inspeccionar `ML.GLOBAL_EXPLAIN`; chequear los timestamps de cada feature contra el momento de la predicción | Quitar la feature que filtra; imponer joins point-in-time |
| La accuracy decae gradualmente durante semanas | **Concept drift** | Métricas de drift del monitoreo; accuracy por slice a lo largo del tiempo | Acortar la cadencia de reentrenamiento; agregar ponderación por recencia |
| La accuracy cae como un escalón en un día | **Cambio en el pipeline upstream** | Consulta de agregado semanal de §11.6 | Arreglar upstream; NO reentrenar hasta que esté arreglado |
| El p99 del endpoint pega picos, el p50 plano | Réplicas frías / lag de autoescalado / pausas de GC | `gcloud logging read` sobre el endpoint; métrica de conteo de réplicas | Subir `minReplicaCount`; pre-calentar; ajustar el target de concurrencia |
| El endpoint devuelve 429 | Cuota o saturación de réplicas | `gcloud ai endpoints describe`; `replica_count` en Monitoring | Subir `maxReplicaCount`; pedir cuota; agregar batching |
| El job de entrenamiento muere por OOM | Cargar el dataset completo en memoria | Logs del job; métrica de memoria pico | Streamear/shardear los datos; máquina `highmem` más grande; reducir el batch size |
| Utilización del acelerador < 30 % | **Inanición del input pipeline** | Profiler de TensorBoard; métricas de `tf.data` | Prefetch, parallel interleave, cache; guardar los datos en la misma región |
| Errores de cuota de GPU al enviar el job | Cuota regional de aceleradores | `gcloud compute regions describe $R --format="value(quotas)"` | Pedir cuota; probar otra región; usar DWS/Spot |
| El deploy del modelo falla, el contenedor nunca queda listo | Ruta del health check o contrato del contenedor no coinciden | Logs del deploy del endpoint; correr el contenedor localmente | Implementar `/health` y `/predict` según el contrato de Vertex |
| El pipeline reutiliza un resultado obsoleto | Caching de KFP en un paso dependiente de datos | Revisar la atribución de caché del paso en el grafo del run | `set_caching_options(False)` en los pasos que leen datos |
| La auditoría de provenance falla | Modelo subido fuera del pipeline | Linaje en el Model Registry | Prohibir la subida manual con IAM; la SA del pipeline es el único escritor |
| El LLM responde con seguridad y se equivoca | **Sin grounding** | Inspeccionar si la recuperación devolvió algo | Agregar RAG/grounding; devolver citas; bajar la temperature; agregar camino de abstención |
| Costo del LLM 5× lo pronosticado | Prompt inflado / sin caching / modelo sobredimensionado | `usageMetadata` por llamada, agregado | Comprimir el prompt, cachear el contexto compartido, rutear los casos fáciles a un modelo más chico, batchear |
| Un agente ejecuta una acción insegura | Prompt injection vía contenido recuperado | Log de auditoría completo de llamadas a herramientas | Nunca otorgar autoridad sobre herramientas desde texto recuperado; whitelist de herramientas; exigir confirmación para escrituras |
| El gate de fairness pasa, el regulador objeta | Evaluación solo agregada | Métricas por slice (§11.3) | Agregar gates de slices protegidos al pipeline; publicar una Model Card |

### 12.3 Runbook — "el modelo está equivocado en producción"

```
1. SCOPE      Is it all traffic or a slice? Query prediction logs grouped by
              slice keys. A slice-local failure is almost always data.

2. FRESHNESS  When did the feature pipeline last succeed?
              Stale features are the #1 cause. Check the Dataflow/scheduled
              query watermark before anything else.

3. IDENTITY   Which model version is serving?
              gcloud ai endpoints describe ... --format="yaml(trafficSplit)"
              Confirm it matches what the change log says.

4. SKEW       Replay 1,000 training rows through the live endpoint.
              Any delta > 1e-6 is a serving-path bug — stop here and fix it.

5. DRIFT      Compare live feature distributions to the training baseline.
              Step change → upstream bug. Gradual → concept drift.

6. MITIGATE   Roll back traffic split to the last known-good version.
              This is a seconds-long operation; do it before root-causing.

7. GROUND     Only after the above: retrain. Retraining on unfixed bad data
              converts a transient incident into a permanent regression.

8. POSTMORTEM Add the failure signal as a pipeline gate. Every ML incident
              should end with one new automated data or evaluation test.
```

---

## 13. Repaso rápido para el examen

| Enunciado en la pregunta | Respuesta correcta |
|---|---|
| "Sin experiencia en ML, lo necesita la semana que viene, tarea genérica" | API pre-entrenada |
| "Sin experiencia en ML, datos propietarios etiquetados" | AutoML o BigQuery ML |
| "Datos ya en BigQuery, analistas fluidos en SQL" | BigQuery ML |
| "Resumir / redactar / conversar / generar" | Gemini en Vertex AI |
| "Las respuestas deben venir de *nuestros* documentos y citarlos" | Grounding / RAG (Vertex AI Search) |
| "Tono equivocado / formato de salida equivocado, los hechos están bien" | Fine-tuning |
| "Los hechos están desactualizados" | RAG, **no** fine-tuning |
| "El modelo estaba bien, ahora se degrada" | Drift → monitoreo + reentrenamiento |
| "Excelente en testing, malo en producción" | Training-serving skew |
| "Plataforma unificada para todo el ciclo de vida de ML" | Vertex AI |
| "Asegurar que el modelo no perjudique a un grupo" | Responsible AI: evaluación por slices, mitigación de sesgos, supervisión humana |
| "Reducir el costo de scorear millones de filas cada noche" | Batch prediction |
| "¿Qué métrica muestra valor de negocio?" | El KPI operativo/financiero, nunca la métrica del modelo |
| "La AI necesita buenos datos primero" | Gobernanza, calidad y labeling de datos — el prerrequisito |

---

## 14. Referencias

**Examen y certificación**
- Cloud Digital Leader exam guide (PDF) — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification page — https://cloud.google.com/learn/certification/cloud-digital-leader

**Plataforma central de AI/ML**
- Vertex AI documentation — https://cloud.google.com/vertex-ai/docs
- Vertex AI Model Garden — https://cloud.google.com/vertex-ai/docs/start/explore-models
- Vertex AI Pipelines — https://cloud.google.com/vertex-ai/docs/pipelines/introduction
- Vertex AI Model Registry — https://cloud.google.com/vertex-ai/docs/model-registry/introduction
- Vertex AI Model Monitoring — https://cloud.google.com/vertex-ai/docs/model-monitoring/overview
- Vertex AI Feature Store — https://cloud.google.com/vertex-ai/docs/featurestore/latest/overview
- Vertex Explainable AI — https://cloud.google.com/vertex-ai/docs/explainable-ai/overview
- Vertex AI online prediction — https://cloud.google.com/vertex-ai/docs/predictions/get-online-predictions
- Vertex AI batch prediction — https://cloud.google.com/vertex-ai/docs/predictions/get-batch-predictions

**AI generativa**
- Generative AI on Vertex AI — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/overview
- Grounding overview — https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/overview
- Vertex AI RAG Engine — https://cloud.google.com/vertex-ai/generative-ai/docs/rag-overview
- Model tuning — https://cloud.google.com/vertex-ai/generative-ai/docs/models/tune-models
- Vertex AI Agent Builder — https://cloud.google.com/products/agent-builder
- Prompt design strategies — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/prompt-design-strategies

**ML low-code / residente en los datos**
- BigQuery ML introduction — https://cloud.google.com/bigquery/docs/bqml-introduction
- BigQuery ML `CREATE MODEL` syntax — https://cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create
- AutoML on Vertex AI — https://cloud.google.com/vertex-ai/docs/training-overview

**APIs pre-entrenadas**
- Cloud Vision API — https://cloud.google.com/vision/docs
- Cloud Natural Language API — https://cloud.google.com/natural-language/docs
- Speech-to-Text — https://cloud.google.com/speech-to-text/docs
- Cloud Translation — https://cloud.google.com/translate/docs
- Document AI — https://cloud.google.com/document-ai/docs
- Contact Center AI — https://cloud.google.com/solutions/contact-center

**Guía de MLOps y arquitectura**
- MLOps: continuous delivery and automation pipelines in ML — https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning
- Practitioners guide to MLOps (whitepaper) — https://services.google.com/fh/files/misc/practitioners_guide_to_mlops_whitepaper.pdf
- Architecture Framework: AI and ML perspective — https://cloud.google.com/architecture/framework/perspectives/ai-ml
- Rules of Machine Learning (Google) — https://developers.google.com/machine-learning/guides/rules-of-ml
- Hidden Technical Debt in Machine Learning Systems (Sculley et al., NeurIPS 2015) — https://papers.nips.cc/paper_files/paper/2015/file/86df7dcfd896fcaf2674f757a2463eba-Paper.pdf

**Base de datos y gobernanza**
- Dataplex Universal Catalog — https://cloud.google.com/dataplex/docs
- Sensitive Data Protection (Cloud DLP) — https://cloud.google.com/sensitive-data-protection/docs
- VPC Service Controls — https://cloud.google.com/vpc-service-controls/docs/overview
- CMEK — https://cloud.google.com/kms/docs/cmek

**Responsible AI**
- Google AI Principles — https://ai.google/responsibility/principles/
- Responsible AI on Vertex AI — https://cloud.google.com/vertex-ai/generative-ai/docs/learn/responsible-ai
- People + AI Guidebook — https://pair.withgoogle.com/guidebook/
- Model Cards — https://modelcards.withgoogle.com/about
- Secure AI Framework (SAIF) — https://saif.google/

**Cómputo y costos**
- Cloud TPU documentation — https://cloud.google.com/tpu/docs
- GPUs on Google Cloud — https://cloud.google.com/compute/docs/gpus
- Vertex AI pricing — https://cloud.google.com/vertex-ai/pricing
- BigQuery pricing — https://cloud.google.com/bigquery/pricing
- Dynamic Workload Scheduler — https://cloud.google.com/blog/products/compute/introducing-dynamic-workload-scheduler

**Serving en Kubernetes**
- KServe documentation — https://kserve.github.io/website/
- AI/ML orchestration on GKE — https://cloud.google.com/kubernetes-engine/docs/integrations/ai-infra