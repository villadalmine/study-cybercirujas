# Tema 1.5 — Platform Engineering Goals, Objectives, and Strategic Approaches

**Certificación:** CNPA (Cloud Native Platform Engineering Associate) · versión de examen `2025-04-01`
**Dominio:** 1 — Platform Engineering Core Fundamentals · **Peso del tema: 7.2 %**
**Perfil del material:** Principal Platform Architect / SRE Senior

---

## 0. Qué evalúa realmente este tema

Este es el tema *bisagra* del dominio 1: los temas anteriores definen **qué es** una plataforma; este define **por qué se construye, cómo se mide y qué estrategia de adopción se elige**. En el examen aparece con preguntas que casi nunca son sintácticas — son de criterio arquitectónico:

- Dado un síntoma organizacional (equipos bloqueados, tickets, snowflakes), identificar el *goal* de plataforma que lo ataca.
- Distinguir **goal** (dirección) de **objective** (resultado medible) de **KR/SLI** (señal instrumentada) de **tactic** (implementación).
- Elegir entre **mandate** y **paved road / opt-in**, entre **build / buy / assemble**, entre **centralizado** y **federado**.
- Ubicar una organización en el **CNCF Platform Engineering Maturity Model** a partir de evidencias.
- Reconocer **anti-patterns**: ivory tower platform, platform-as-ticket-queue, big-bang migration, abstracción con fugas.

Lo que sigue traduce todo eso a artefactos que se pueden aplicar en un cluster real, porque la única forma de que una estrategia de plataforma sea verificable es que esté instrumentada.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El escenario que genera la necesidad

Organización de referencia — la usamos durante todo el material:

| Dimensión | Valor observado |
|---|---|
| Stream-aligned teams | 34 |
| Servicios en producción | 410 |
| Clusters Kubernetes | 11 (3 cloud providers + 2 on-prem) |
| Repos con Terraform propio | 96 |
| Charts de Helm mantenidos por producto | 210 |
| Pipelines CI distintos | 7 tecnologías (Jenkins, GH Actions, GitLab CI, Tekton, ...) |
| Lead time p50 (commit → prod) | 9,4 días |
| Deployment frequency mediana por servicio | 1,2 / mes |
| Change failure rate | 23 % |
| Failed deployment recovery time p90 | 11 h |
| Tickets al equipo de infra / semana | 340 |
| Tiempo de un dev nuevo hasta su primer deploy a prod (T2FD) | 21 días |

Ninguno de esos números es un problema de tecnología. Todos son síntomas de **carga cognitiva extrínseca distribuida**: cada equipo resolvió, por su cuenta, el mismo conjunto de problemas no diferenciales.

### 1.2 La aritmética de la carga cognitiva

Sweller distingue tres tipos de carga cognitiva; Team Topologies la aplica a equipos de software:

| Tipo | Definición | Ejemplo en el equipo de producto | ¿La plataforma debe...? |
|---|---|---|---|
| **Intrínseca** | Complejidad inherente al dominio del problema | Reglas de negocio de facturación, modelo de datos | **No tocarla.** Es el valor del equipo |
| **Extrínseca** | Complejidad accidental impuesta por el entorno | Escribir `NetworkPolicy`, rotar certificados, configurar un `ServiceMonitor`, elegir el `securityContext` correcto | **Absorberla.** Es el mandato central de la plataforma |
| **Germánica** | Esfuerzo dedicado a construir modelos mentales útiles | Aprender el modelo de fallo de su propio servicio, diseñar sus SLOs | **Habilitarla.** Golden paths + docs + enabling teams |

Cuantificación en el caso de referencia. Un equipo stream-aligned que quiere poner un servicio HTTP nuevo en producción sin plataforma debe sostener simultáneamente:

```
Conceptos requeridos por deploy "desde cero":
  Kubernetes core           Deployment, Service, Ingress/Gateway, HPA, PDB,
                            ResourceQuota, LimitRange, ServiceAccount, RBAC     ~11
  Seguridad                 SecurityContext, PSA labels, NetworkPolicy,
                            secrets (ESO/Vault), image signing/verification,
                            SBOM                                                 ~6
  Observabilidad            ServiceMonitor/PodMonitor, OTel SDK + Collector,
                            log pipeline, dashboards, alert rules, SLOs          ~6
  Entrega                   pipeline CI, registry, promoción, GitOps app,
                            estrategia de rollout, rollback                      ~6
  Infra de soporte          DNS, TLS/cert-manager, base de datos, cache,
                            message broker, IAM cloud, red/VPC                   ~7
  Cumplimiento              retención de logs, data residency, tagging de costos ~3
                                                                              -------
                                                                                 ~39
```

Con 34 equipos, la organización está pagando **~39 × 34 = 1.326 instancias del mismo aprendizaje**, de las cuales sólo una fracción diminuta es diferencial. Y como cada equipo lo resolvió distinto, la variación no genera valor: genera superficie de fallo y de auditoría.

> **Esta es la tesis arquitectónica del tema:** la plataforma no existe para "estandarizar por estandarizar" ni para "ahorrar licencias". Existe para **convertir carga cognitiva extrínseca duplicada N veces en una capacidad amortizada, consumida como self-service, con guardrails por default**.

### 1.3 El anti-modelo: la "shadow platform"

Cuando no hay plataforma explícita, siempre hay una implícita: un repo de Terraform que todos copian, un chart base que alguien mantiene "en sus ratos libres", un canal de Slack donde se piden accesos. Sus propiedades:

- **Sin contrato**: cambia sin versionado ni deprecación.
- **Sin SLO**: nadie es on-call de ella, pero todo el mundo depende de ella.
- **Sin producto**: no tiene roadmap, ni usuarios definidos, ni métricas de adopción.
- **Con bus factor 1**.

El objetivo estratégico inicial de una iniciativa de platform engineering casi siempre es **hacer explícita, contractual y operable la plataforma que ya existe de facto** — no inventar una nueva.

---

## 2. Vocabulario preciso: goal, objective, key result, SLI/SLO, tactic

El examen mezcla estos términos deliberadamente. La jerarquía correcta:

| Nivel | Pregunta que responde | Horizonte | Ejemplo | Propiedad |
|---|---|---|---|---|
| **Goal** | ¿Hacia dónde? | 12–24 meses | "Reducir la carga cognitiva extrínseca de los stream-aligned teams" | Cualitativo, estable, no se "cumple" |
| **Objective (O de OKR)** | ¿Qué resultado en este ciclo? | 1–2 trimestres | "El camino por default a producción es más rápido que cualquier alternativa" | Cualitativo, ambicioso, acotado |
| **Key Result** | ¿Cómo sé que pasó? | 1 trimestre | "T2FD p50 de 21 d → ≤ 2 d" | Cuantitativo, con baseline y target |
| **SLI / SLO** | ¿La plataforma está sana ahora? | Continuo | "99,5 % de los `WebService` claims llegan a `Ready` en ≤ 10 min (28 d)" | Instrumentado, con error budget |
| **Tactic** | ¿Con qué lo hago? | Sprint | "XRD `webservices.platform.acme.io` + Composition AWS estándar" | Reemplazable sin cambiar el goal |
| **Guardrail metric** | ¿Qué no puedo romper mientras optimizo? | Continuo | "CFR ≤ 15 %; costo/servicio no sube > 10 %" | Contra-métrica, evita gaming |

**Regla de oro para el examen:** un KR nunca es "entregar el portal" (eso es un output/tactic). Un KR es "el 60 % de los servicios nuevos se crean por el portal" (outcome).

### 2.1 Los seis goals canónicos de una plataforma cloud native

| # | Goal | Problema que ataca | Objective típico | KR / SLI primario | Guardrail |
|---|---|---|---|---|---|
| **G1** | Reducir carga cognitiva | Duplicación de complejidad accidental | "Un dev nuevo llega a prod sin leer YAML de Kubernetes" | T2FD p50, nº de conceptos en el golden path | Satisfacción del dev (no "reducimos carga escondiendo todo") |
| **G2** | Acelerar el flujo | Lead time, colas, handoffs | "El path por default es el más rápido" | DORA: deployment frequency, lead time for changes | CFR, recovery time |
| **G3** | Fiabilidad y operabilidad | Snowflakes, MTTR alto, on-call insostenible | "Cada servicio nace observable y con rollback" | Cobertura de SLO, % servicios con runbook y alertas de burn rate | Ruido de alertas, páginas/semana |
| **G4** | Seguridad y compliance *by default* | Controles como paso manual y tardío | "El cumplimiento es propiedad del path, no del reviewer" | % workloads conformes, hallazgos críticos abiertos, cobertura de firma/SBOM | Excepciones vigentes y su antigüedad |
| **G5** | Eficiencia de costos (FinOps) | Sobreaprovisionamiento, costo no atribuible | "Todo gasto es atribuible a un owner" | % recursos con tag de owner, costo por request/servicio | No degradar SLOs para bajar costo |
| **G6** | Estandarización sin osificación | Fragmentación vs. jaula | "Variación permitida donde agrega valor" | % servicios en golden path, nº de variantes soportadas | Tiempo de aprobación de un "off-road" |

Cada goal se **mide con dos familias distintas**: métricas de *entrega* (DORA) y métricas de *experiencia* (SPACE / DevEx). Optimizar sólo DORA produce plataformas rápidas que la gente odia; optimizar sólo satisfacción produce plataformas queridas que no mueven el negocio.

### 2.2 DORA y SPACE — qué mide cada una

**DORA (four keys + reliability).** Referencia: `https://dora.dev/`.

| Métrica | Definición operativa | Fuente de datos en la plataforma |
|---|---|---|
| Deployment frequency | Nº de despliegues exitosos a producción por servicio y ventana | Eventos del controlador GitOps / pipeline |
| Lead time for changes | commit → running en producción | Timestamp de commit vs. `Synced/Healthy` |
| Change failure rate | % de despliegues que requieren remediación (rollback, hotfix, incidente) | Deploy events correlacionados con incidentes |
| Failed deployment recovery time | Tiempo de restauración tras un deploy fallido (antes llamado MTTR) | Incidente/rollback: inicio → resolución |

Los clusters de rendimiento (Elite / High / Medium / Low) y sus umbrales exactos se recalibran en cada *State of DevOps Report*; **para el examen importa el orden de magnitud y la relación, no el número**: velocidad y estabilidad se mueven **juntas** en organizaciones de alto rendimiento — no son un trade-off.

**SPACE.** Referencia: Forsgren et al., ACM Queue, `https://queue.acm.org/detail.cfm?id=3454124`.

| Dimensión | Qué captura | Instrumento típico en plataforma |
|---|---|---|
| **S**atisfaction & well-being | ¿La plataforma les gusta? ¿hay burnout? | DevEx survey trimestral, eNPS de plataforma |
| **P**erformance | Resultado del sistema | SLOs de producto, calidad |
| **A**ctivity | Volumen de outputs | Deploys, PRs, claims creados |
| **C**ommunication & collaboration | Fricción entre equipos | Tiempo de respuesta en canal de soporte, nº de handoffs |
| **E**fficiency & flow | Interrupciones y esperas | Tiempo en cola, T2FD, % de tareas self-service |

**Regla SPACE:** nunca reportar una sola dimensión. Un aumento de *Activity* sin *Satisfaction* suele indicar reintentos, no productividad.

---

## 3. Enfoques estratégicos y sus trade-offs

### 3.1 Modelo de adopción: mandate vs. paved road vs. enabling

| Enfoque | Mecanismo | Velocidad inicial | Riesgo | Cuándo es correcto |
|---|---|---|---|---|
| **Mandate (top-down)** | Política obligatoria, migración forzada | Alta | Resentimiento, workarounds, plataforma que nadie mejora porque nadie puede irse | Requisitos regulatorios duros, deprecación de infra insegura, deadline externo |
| **Paved road / golden path (pull)** | El camino por default es el más fácil y rápido; salirse es *posible pero costoso* | Media | Adopción lenta si el path no es genuinamente mejor | **Default recomendado.** Fuerza a la plataforma a competir por sus usuarios |
| **Enabling team (facilitating)** | El equipo de plataforma acompaña temporalmente a un stream-aligned team | Baja | No escala; puede degenerar en staff augmentation | Bootstrapping, dominios complejos, descubrimiento de requisitos |
| **Ticket ops (anti-pattern)** | El equipo de plataforma ejecuta pedidos | — | Cola infinita, plataforma = equipo, no = producto | Nunca como estado final |

> **Formulación del paved road:** *"Podés salir del camino pavimentado. Vas a llegar igual. Pero manejás vos, y el seguro lo pagás vos."* Traducido a mecanismos concretos: fuera del golden path no hay SLO de plataforma, no hay on-call compartido, y el compliance recae en el equipo, con evidencia propia.

**Patrón híbrido de producción (el que suele ser la respuesta correcta):**
`guardrails obligatorios` (G4, no negociables, aplicados por policy engine) **+** `golden path opcional` (G1/G2/G6, gana por conveniencia) **+** `enabling team` para casos borde.

### 3.2 Build vs. Buy vs. Assemble

| Criterio | **Build** (desde cero) | **Buy** (PaaS / IDP comercial) | **Assemble** (integrar OSS CNCF) |
|---|---|---|---|
| Time-to-value | Meses–años | Semanas | Semanas–meses |
| Costo inicial | Alto (headcount) | Licencia + integración | Medio |
| Costo marginal | Bajo | Crece con seats/workloads | Operacional (on-call) |
| Ajuste al dominio | Total | Bajo–medio | Alto |
| Lock-in | Interno (bus factor) | De proveedor | De arquitectura |
| Carga operativa | Máxima | Mínima | Alta |
| Diferencial competitivo | Sólo si la plataforma *es* el negocio | Nulo | Selectivo |
| Talento requerido | Escaso y caro | Bajo | Medio–alto |
| Riesgo dominante | Reinventar mal lo commodity | Techo funcional y precio | Integration sprawl |

**Heurística de decisión:** *build* sólo la capa de **interfaces y abstracciones específicas del dominio** (XRDs, plantillas, portal, políticas propias); *assemble* la capa de **capacidades commodity** (Kubernetes, Argo CD, Prometheus, cert-manager, External Secrets, OPA/Kyverno, Backstage); *buy* aquello cuyo fallo no es diferencial pero cuya operación es cara (identidad, secrets management, observability backend en escala).

Aplicado al caso de referencia:

| Capacidad | Decisión | Justificación |
|---|---|---|
| Runtime de contenedores | Assemble (K8s gestionado) | Commodity absoluto |
| GitOps | Assemble (Argo CD) | Estándar de facto, CNCF graduated |
| API de plataforma | **Build** (Crossplane XRDs propios) | Es donde vive el modelo de dominio |
| Portal de desarrollador | Assemble (Backstage) + build de plugins | El catálogo es genérico; los scorecards son propios |
| Policy engine | Assemble (Kyverno) | Las *políticas* son build; el engine no |
| Observability backend | Buy o Assemble según escala | Operar TSDB multi-tenant a escala es caro y no diferencial |
| Secrets | Buy (Vault/cloud KMS) + Assemble (External Secrets) | Riesgo de seguridad, no diferencial |

### 3.3 Topología del equipo de plataforma

| Modelo | Estructura | Ventaja | Falla característica |
|---|---|---|---|
| **Centralizado** | Un equipo dueño de toda la plataforma | Coherencia, contrato único | Cuello de botella; distancia del usuario → ivory tower |
| **Federado** | Core team + contribuciones de stream-aligned teams (inner source) | Escala, ownership distribuido | Deriva de estándares sin un *architecture review* fuerte |
| **Embedded / rotational** | Miembros de plataforma rotan dentro de equipos de producto | Empatía y feedback loop cortísimo | Se pierde foco de producto; rotación cara |
| **Platform-of-platforms** | Plataforma base + plataformas de dominio encima | Escala organizacional grande | Duplicación de capacidades entre capas; contratos ambiguos |

**Team Topologies** (Skelton & Pais) aporta la restricción clave: el modo de interacción por default entre el **platform team** y los **stream-aligned teams** debe ser **X-as-a-Service**. `Collaboration` es válido pero **temporal y explícito** — si se vuelve permanente, la plataforma no tiene interfaz, tiene reuniones.

**Thinnest Viable Platform (TVP):** el mínimo conjunto de capacidades que reduce carga cognitiva sin crear una carga nueva. Un TVP legítimo puede ser un repositorio de documentación con tres plantillas validadas. Empezar por un IDP completo antes de conocer los golden paths reales es el camino más rápido a una plataforma sin usuarios.

### 3.4 Profundidad de abstracción — el trade-off de las fugas

| Estrategia | Qué expone | Ventaja | Costo |
|---|---|---|---|
| **Passthrough** (`kubectl` directo + docs) | Todo | Cero fuga; cero lock-in interno | Cero reducción de carga cognitiva |
| **Templating** (Helm/Kustomize base) | Casi todo | Simple, transparente, debuggeable | Copy-paste drift; upgrades manuales |
| **Facade / API declarativa** (XRD, Score, CRD propio) | Sólo lo del dominio | Máxima reducción de carga; contrato versionable | Superficie de mantenimiento; **fugas en el debugging** |
| **Full abstraction** (PaaS opaca) | Casi nada | Máxima simplicidad | Techo funcional; usuarios bloqueados sin escape hatch |

> **Ley de las abstracciones con fugas aplicada a plataformas:** toda abstracción falla eventualmente, y falla **en producción, a las 3 AM, para alguien que no la construyó**. Por eso una API de plataforma no es válida sin: (a) trazabilidad hacia los recursos subyacentes, (b) mensajes de error en el vocabulario del usuario, (c) un **escape hatch** documentado.

### 3.5 Modelo de financiamiento

| Modelo | Mecánica | Incentivo que crea | Riesgo |
|---|---|---|---|
| **Cost center central** | Presupuesto propio, consumo gratis | Máxima adopción | Demanda infinita; sin señal de valor; primer recorte en crisis |
| **Showback** | Se reporta el costo atribuido, no se cobra | Conciencia de costo sin fricción | Se ignora si no hay consecuencia |
| **Chargeback** | Se factura internamente por consumo | Eficiencia real | Equipos evitan la plataforma para ahorrar → shadow IT |
| **Híbrido (recomendado)** | Capacidades base gratis (guardrails, CI, observabilidad) + chargeback de infra (compute, storage, DB) | Adopción del path + responsabilidad del gasto | Requiere tagging correcto — G5 depende de esto |

### 3.6 Estrategia de migración

| Enfoque | Descripción | Cuándo |
|---|---|---|
| **Strangler fig** | Servicios nuevos nacen en el golden path; los viejos migran por oportunidad | Default. Riesgo mínimo, valor temprano |
| **Wave / cohorte** | Olas explícitas: canary → early adopters → general | Cuando hay deadline (deprecación de infra) |
| **Big bang** | Corte total en una fecha | Casi nunca. Sólo si mantener ambos es imposible |
| **Wrap & extend** | La plataforma envuelve el sistema legacy con la nueva API | Legacy que no puede tocarse, pero cuyo consumo debe unificarse |

---

## 4. El CNCF Platform Engineering Maturity Model

Documento oficial: `https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/`

Cinco **aspectos** × cuatro **niveles**. En el examen se evalúa que puedas ubicar una organización a partir de evidencia observable.

| Aspecto | **1 · Provisional** | **2 · Operational** | **3 · Scalable** | **4 · Optimizing** |
|---|---|---|---|---|
| **Investment** (¿cómo se financia y dota?) | Voluntarios, tiempo residual | Equipo dedicado, presupuesto anual | Equipo con product manager; financiamiento sostenido | Inversión ajustada por valor medido; el negocio la trata como capacidad estratégica |
| **Adoption** (¿quién y por qué la usa?) | Usuarios pioneros ad-hoc | Adopción por mandato o por proyecto | Adopción por conveniencia (pull); onboarding self-service | Los usuarios contribuyen; inner source; la plataforma evoluciona con ellos |
| **Interfaces** (¿cómo se consume?) | Tickets, wikis, "preguntá en Slack" | Documentación + scripts/templates estandarizados | API/portal self-service, versionado, contrato explícito | Interfaces compuestas y extensibles; los usuarios crean sus propios golden paths sobre las primitivas |
| **Operations** (¿cómo se opera y evoluciona?) | Best-effort, sin on-call | Operación reactiva definida; releases manuales | SLOs, on-call, ciclo de release automatizado, deprecación con política | Operación proactiva; capacity planning; chaos/game days; deprecación anunciada y automatizada |
| **Measurement** (¿cómo se sabe si funciona?) | Anecdótica ("nos dijeron que está bueno") | Métricas de uso/actividad | DORA + SLOs de plataforma + encuestas periódicas | Métricas conectadas a resultados de negocio; experimentación y decisiones basadas en datos |

**Cómo usarlo estratégicamente** (y esto suele ser pregunta de examen): el modelo **no es una escalera a subir hasta el nivel 4 en todos los aspectos**. Es un instrumento de diagnóstico de *desbalance*. El patrón de fallo más común y más caro:

```
Interfaces:   ███████████████  Nivel 3–4  (portal precioso, APIs elegantes)
Operations:   ████             Nivel 1    (sin SLO, sin on-call, sin deprecación)
Adoption:     ████             Nivel 1    (nadie la usa)
Measurement:  ████             Nivel 1    (no sabemos que nadie la usa)
```

Es la **ivory tower platform**: se invirtió en la superficie visible antes que en la evidencia de valor. La corrección es siempre la misma: subir **Measurement** primero (es el aspecto más barato), porque sin él no se puede priorizar ningún otro.

---

## 5. Instrumentación: manifiestos completos

Estrategia sin instrumentación es opinión. Esta sección materializa los goals de §2.1 en artefactos aplicables.

### 5.1 SLOs de la plataforma como producto (Sloth)

La plataforma tiene usuarios y por lo tanto tiene SLOs propios. Aquí, el SLI primario es **"un claim del golden path llega a `Ready` dentro del presupuesto de tiempo"** — la promesa de producto, no la salud del pod.

```yaml
# platform/slo/platform-api-slo.yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata:
  name: platform-golden-path
  namespace: platform-system
  labels:
    app.kubernetes.io/part-of: platform
spec:
  service: platform-golden-path
  labels:
    tier: platform
    owner: team-platform
  slos:
    # --- G2: el camino por default debe ser rápido y confiable ---
    - name: provisioning-success
      objective: 99.0          # 99% de los claims completan sin error, ventana 30d
      description: >-
        Fraction of WebService claims that reconcile to Ready without a
        terminal error. This is the platform's core product promise.
      sli:
        events:
          errorQuery: |
            sum(rate(platform_claim_reconcile_total{outcome="failed",api="webservices.platform.acme.io"}[{{.window}}]))
          totalQuery: |
            sum(rate(platform_claim_reconcile_total{api="webservices.platform.acme.io"}[{{.window}}]))
      alerting:
        name: GoldenPathProvisioningErrorBudgetBurn
        labels:
          category: platform-availability
        annotations:
          summary: "Golden path provisioning is burning its error budget"
          runbook_url: "https://backstage.acme.io/docs/platform/runbooks/provisioning"
        pageAlert:
          labels:
            severity: critical
            routing_key: platform-oncall
        ticketAlert:
          labels:
            severity: warning
            routing_key: platform-backlog

    - name: provisioning-latency
      objective: 95.0          # 95% de los claims Ready en <= 600s
      description: >-
        Fraction of WebService claims that reach Ready within 10 minutes.
        Directly backs the "time to first deploy" key result.
      sli:
        events:
          errorQuery: |
            (
              sum(rate(platform_claim_ready_seconds_count{api="webservices.platform.acme.io"}[{{.window}}]))
              -
              sum(rate(platform_claim_ready_seconds_bucket{api="webservices.platform.acme.io",le="600"}[{{.window}}]))
            )
          totalQuery: |
            sum(rate(platform_claim_ready_seconds_count{api="webservices.platform.acme.io"}[{{.window}}]))
      alerting:
        name: GoldenPathProvisioningSlow
        labels:
          category: platform-latency
        annotations:
          summary: "Golden path provisioning latency budget burning"
          runbook_url: "https://backstage.acme.io/docs/platform/runbooks/provisioning-latency"
        pageAlert:
          disable: true          # latencia no paginable: degrada, no rompe
        ticketAlert:
          labels:
            severity: warning
            routing_key: platform-backlog

    # --- G3: el portal es la interfaz; si cae, la plataforma "no existe" ---
    - name: portal-availability
      objective: 99.5
      description: Backstage portal availability as seen by developers.
      sli:
        events:
          errorQuery: |
            sum(rate(http_requests_total{job="backstage",code=~"5.."}[{{.window}}]))
          totalQuery: |
            sum(rate(http_requests_total{job="backstage"}[{{.window}}]))
      alerting:
        name: DeveloperPortalErrorBudgetBurn
        labels:
          category: platform-availability
        annotations:
          summary: "Developer portal is burning its error budget"
          runbook_url: "https://backstage.acme.io/docs/platform/runbooks/portal"
        pageAlert:
          labels:
            severity: critical
            routing_key: platform-oncall
        ticketAlert:
          labels:
            severity: warning
            routing_key: platform-backlog
```

Equivalente vendor-neutral en **OpenSLO** (útil cuando el SLO debe ser legible por herramientas fuera de Prometheus):

```yaml
# platform/slo/openslo/provisioning.yaml
apiVersion: openslo/v1
kind: SLO
metadata:
  name: golden-path-provisioning-success
  displayName: Golden Path Provisioning Success
spec:
  description: >-
    Share of golden-path provisioning requests that complete successfully.
    Owner: team-platform. Consumers: all stream-aligned teams.
  service: platform-golden-path
  indicator:
    metadata:
      name: provisioning-success-ratio
    spec:
      ratioMetric:
        counter: true
        good:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(increase(platform_claim_reconcile_total{outcome="succeeded"}[1h]))
        total:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(increase(platform_claim_reconcile_total[1h]))
  timeWindow:
    - duration: 30d
      isRolling: true
  budgetingMethod: Occurrences
  objectives:
    - displayName: 99% success
      target: 0.99
  alertPolicies:
    - alertPolicyRef: platform-multiwindow-burn
```

### 5.2 Reglas de registro DORA — los KRs como series de tiempo

Sin esto, los OKRs se reportan a mano en un slide y se degradan a ficción en dos trimestres.

```yaml
# platform/observability/dora-recording-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-dora-metrics
  namespace: platform-system
  labels:
    app.kubernetes.io/part-of: platform
    prometheus: platform
    role: recording-rules
spec:
  groups:
    - name: dora.deployment-frequency
      interval: 5m
      rules:
        - record: dora:deployment_frequency:7d
          expr: |
            sum by (service, team, env) (
              increase(platform_deployment_total{result="success", env="prod"}[7d])
            )
        - record: dora:deployment_frequency_org:7d
          expr: sum(dora:deployment_frequency:7d)
        - record: dora:services_deploying_weekly:ratio
          expr: |
            count(dora:deployment_frequency:7d > 0)
            /
            count(platform_service_info{env="prod"})

    - name: dora.lead-time
      interval: 5m
      rules:
        - record: dora:lead_time_seconds:p50_30d
          expr: |
            histogram_quantile(0.50,
              sum by (le, team) (
                rate(platform_change_lead_time_seconds_bucket{env="prod"}[30d])
              )
            )
        - record: dora:lead_time_seconds:p95_30d
          expr: |
            histogram_quantile(0.95,
              sum by (le, team) (
                rate(platform_change_lead_time_seconds_bucket{env="prod"}[30d])
              )
            )

    - name: dora.change-failure-rate
      interval: 5m
      rules:
        - record: dora:change_failure_rate:30d
          expr: |
            sum by (service, team) (
              increase(platform_deployment_total{result="failure", env="prod"}[30d])
            )
            /
            clamp_min(
              sum by (service, team) (
                increase(platform_deployment_total{env="prod"}[30d])
              ), 1
            )

    - name: dora.recovery-time
      interval: 5m
      rules:
        - record: dora:failed_deployment_recovery_seconds:p90_30d
          expr: |
            histogram_quantile(0.90,
              sum by (le) (
                rate(platform_deployment_recovery_seconds_bucket{env="prod"}[30d])
              )
            )

    # --- Métricas de estrategia: adopción y T2FD (no son DORA, son de producto) ---
    - name: platform.adoption
      interval: 5m
      rules:
        - record: platform:golden_path_adoption:ratio
          expr: |
            count(platform_workload_info{provisioned_by="golden-path", env="prod"})
            /
            clamp_min(count(platform_workload_info{env="prod"}), 1)
        - record: platform:selfservice_ratio:30d
          expr: |
            sum(increase(platform_request_total{channel="self-service"}[30d]))
            /
            clamp_min(sum(increase(platform_request_total[30d])), 1)
        - record: platform:time_to_first_deploy_seconds:p50_90d
          expr: |
            histogram_quantile(0.50,
              sum by (le) (rate(platform_time_to_first_deploy_seconds_bucket[90d]))
            )

    - name: platform.strategy-alerts
      rules:
        - alert: GoldenPathAdoptionStalled
          expr: |
            delta(platform:golden_path_adoption:ratio[28d]) < 0.02
            and platform:golden_path_adoption:ratio < 0.6
          for: 24h
          labels:
            severity: warning
            routing_key: platform-product
          annotations:
            summary: "Golden path adoption is flat below target"
            description: >-
              Adoption moved less than 2 points in 28 days and is under 60%.
              Treat as a product problem, not an engineering one:
              run user interviews before shipping more features.
            runbook_url: "https://backstage.acme.io/docs/platform/runbooks/adoption-stall"

        - alert: TicketOpsRegression
          expr: |
            1 - platform:selfservice_ratio:30d > 0.25
          for: 48h
          labels:
            severity: warning
            routing_key: platform-product
          annotations:
            summary: "More than 25% of platform requests still arrive as tickets"
            description: >-
              The platform is drifting back toward ticket ops. Identify the top
              3 ticket categories and convert them into self-service capabilities.
```

### 5.3 El golden path como API versionada (Crossplane XRD)

Este es el artefacto que materializa **G1 + G6**: reduce ~39 conceptos a 6 campos, y hace del contrato algo versionable y deprecable.

```yaml
# platform/apis/xrd-webservice.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xwebservices.platform.acme.io
  annotations:
    platform.acme.io/tier: golden-path
    platform.acme.io/owner: team-platform
    platform.acme.io/support: "#platform-support"
    platform.acme.io/slo: "99% provisioning success, p95 <= 10m"
spec:
  group: platform.acme.io
  names:
    kind: XWebService
    plural: xwebservices
  claimNames:
    kind: WebService
    plural: webservices
  defaultCompositionRef:
    name: webservice-standard
  connectionSecretKeys:
    - endpoint
    - database-uri
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              description: >-
                The entire contract a stream-aligned team must understand in
                order to run an HTTP service in production on this platform.
              properties:
                image:
                  type: string
                  description: OCI image reference; must be signed and from the internal registry.
                  pattern: '^registry\.acme\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$'
                port:
                  type: integer
                  description: Container port serving HTTP traffic.
                  default: 8080
                  minimum: 1
                  maximum: 65535
                size:
                  type: string
                  description: >-
                    T-shirt sizing. The platform owns the mapping to CPU/memory,
                    replica counts and autoscaling bounds.
                  enum: ["xs", "s", "m", "l", "xl"]
                  default: "s"
                environment:
                  type: string
                  enum: ["dev", "staging", "prod"]
                  default: "dev"
                publicHostname:
                  type: string
                  description: Optional public DNS name; TLS is issued automatically.
                  pattern: '^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$'
                database:
                  type: object
                  description: Optional managed PostgreSQL instance.
                  properties:
                    enabled:
                      type: boolean
                      default: false
                    sizeGB:
                      type: integer
                      default: 20
                      minimum: 20
                      maximum: 1000
                  required: ["enabled"]
                ownership:
                  type: object
                  description: Required for cost attribution (G5) and paging (G3).
                  properties:
                    team:
                      type: string
                      pattern: '^team-[a-z0-9-]+$'
                    costCenter:
                      type: string
                      pattern: '^CC-[0-9]{4}$'
                    oncallRoutingKey:
                      type: string
                  required: ["team", "costCenter", "oncallRoutingKey"]
              required:
                - image
                - ownership
            status:
              type: object
              properties:
                endpoint:
                  type: string
                  description: Public or cluster-internal URL of the service.
                goldenPathVersion:
                  type: string
                  description: Version of the composition that produced this service.
                observability:
                  type: object
                  properties:
                    dashboardURL:
                      type: string
                    sloStatus:
                      type: string
      additionalPrinterColumns:
        - name: ENDPOINT
          type: string
          jsonPath: ".status.endpoint"
        - name: SIZE
          type: string
          jsonPath: ".spec.size"
        - name: TEAM
          type: string
          jsonPath: ".spec.ownership.team"
        - name: PATH-VERSION
          type: string
          jsonPath: ".status.goldenPathVersion"
        - name: SYNCED
          type: string
          jsonPath: ".status.conditions[?(@.type=='Synced')].status"
        - name: READY
          type: string
          jsonPath: ".status.conditions[?(@.type=='Ready')].status"
        - name: AGE
          type: date
          jsonPath: ".metadata.creationTimestamp"
```

Y el consumo por parte de un stream-aligned team — **esta es la medida real de la reducción de carga cognitiva**:

```yaml
# apps/checkout/platform/webservice.yaml
apiVersion: platform.acme.io/v1alpha1
kind: WebService
metadata:
  name: checkout-api
  namespace: team-payments
spec:
  image: registry.acme.io/payments/checkout-api@sha256:3f1a9d0c7b6e4c2a8d5f1e0b9c7a6d4f2e1b0a9c8d7e6f5a4b3c2d1e0f9a8b7c
  port: 8080
  size: m
  environment: prod
  publicHostname: checkout.acme.io
  database:
    enabled: true
    sizeGB: 100
  ownership:
    team: team-payments
    costCenter: CC-4711
    oncallRoutingKey: pd-payments-primary
```

**39 conceptos → 8 campos.** Ese delta *es* el KR de G1, y es medible: cuente los campos obligatorios y las líneas del manifiesto que el usuario escribe.

La `Composition` que lo respalda, en modo pipeline, aplicando los defaults de seguridad y observabilidad que el usuario ya no tiene que conocer:

```yaml
# platform/apis/composition-webservice-standard.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: webservice-standard
  labels:
    platform.acme.io/golden-path-version: "1.8.3"
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XWebService
  mode: Pipeline
  writeConnectionSecretsToNamespace: platform-system
  pipeline:
    - step: render-workload
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: deployment
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: apps/v1
                    kind: Deployment
                    metadata:
                      labels:
                        app.kubernetes.io/managed-by: platform
                        platform.acme.io/provisioned-by: golden-path
                    spec:
                      selector:
                        matchLabels:
                          app.kubernetes.io/name: placeholder
                      template:
                        metadata:
                          labels:
                            app.kubernetes.io/name: placeholder
                        spec:
                          # Defaults de seguridad: G4 sin que el usuario los escriba
                          automountServiceAccountToken: false
                          securityContext:
                            runAsNonRoot: true
                            runAsUser: 10001
                            fsGroup: 10001
                            seccompProfile:
                              type: RuntimeDefault
                          containers:
                            - name: app
                              image: placeholder
                              ports:
                                - name: http
                                  containerPort: 8080
                              securityContext:
                                allowPrivilegeEscalation: false
                                readOnlyRootFilesystem: true
                                capabilities:
                                  drop: ["ALL"]
                              readinessProbe:
                                httpGet:
                                  path: /healthz
                                  port: http
                                initialDelaySeconds: 5
                                periodSeconds: 10
                              livenessProbe:
                                httpGet:
                                  path: /healthz
                                  port: http
                                initialDelaySeconds: 20
                                periodSeconds: 30
                              env:
                                - name: OTEL_EXPORTER_OTLP_ENDPOINT
                                  value: http://otel-collector.observability:4317
                                - name: OTEL_SERVICE_NAME
                                  value: placeholder
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.ownership.team
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.spec.selector.matchLabels["app.kubernetes.io/name"]
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.spec.template.metadata.labels["app.kubernetes.io/name"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.ownership.team
                toFieldPath: spec.forProvider.manifest.metadata.labels["platform.acme.io/owner"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.ownership.costCenter
                toFieldPath: spec.forProvider.manifest.metadata.labels["platform.acme.io/cost-center"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.image
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].image
              - type: FromCompositeFieldPath
                fromFieldPath: spec.port
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].ports[0].containerPort
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].env[1].value
              # T-shirt size -> requests/limits/replicas: la plataforma es dueña del mapeo
              - type: FromCompositeFieldPath
                fromFieldPath: spec.size
                toFieldPath: spec.forProvider.manifest.spec.replicas
                transforms:
                  - type: map
                    map:
                      xs: "1"
                      s:  "2"
                      m:  "3"
                      l:  "6"
                      xl: "12"
                  - type: convert
                    convert:
                      toType: int64
              - type: FromCompositeFieldPath
                fromFieldPath: spec.size
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].resources.requests.cpu
                transforms:
                  - type: map
                    map: { xs: "100m", s: "250m", m: "500m", l: "1", xl: "2" }
              - type: FromCompositeFieldPath
                fromFieldPath: spec.size
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].resources.requests.memory
                transforms:
                  - type: map
                    map: { xs: "128Mi", s: "256Mi", m: "512Mi", l: "1Gi", xl: "2Gi" }
              - type: FromCompositeFieldPath
                fromFieldPath: spec.size
                toFieldPath: spec.forProvider.manifest.spec.template.spec.containers[0].resources.limits.memory
                transforms:
                  - type: map
                    map: { xs: "256Mi", s: "512Mi", m: "1Gi", l: "2Gi", xl: "4Gi" }

          - name: servicemonitor
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: monitoring.coreos.com/v1
                    kind: ServiceMonitor
                    metadata:
                      labels:
                        platform.acme.io/provisioned-by: golden-path
                    spec:
                      endpoints:
                        - port: http
                          path: /metrics
                          interval: 30s
                      selector:
                        matchLabels:
                          app.kubernetes.io/name: placeholder
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.ownership.team
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.spec.selector.matchLabels["app.kubernetes.io/name"]

    - step: mark-golden-path-version
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        patchSets: []
        resources: []

    - step: detect-readiness
      functionRef:
        name: function-auto-ready
```

### 5.4 Guardrails obligatorios y el *ramp* Audit → Enforce (Kyverno)

La política es donde vive la estrategia: **`Audit` durante el ramp para medir el impacto sin romper, `Enforce` cuando la evidencia dice que se puede.** Aplicar `Enforce` el día uno es un mandate disfrazado y produce incidentes de plataforma.

```yaml
# platform/policy/golden-path-guardrails.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-ownership-and-provenance
  annotations:
    policies.kyverno.io/title: Ownership and Provenance Guardrails
    policies.kyverno.io/category: Platform Strategy
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Deployment, StatefulSet
    policies.kyverno.io/description: >-
      Every production workload must declare an owning team and a cost center
      (goal G5, cost attribution) and must record how it was provisioned
      (goal G6, adoption measurement). Starts in Audit while adoption ramps;
      moves to Enforce for namespaces already on the golden path.
spec:
  validationFailureAction: Audit      # <-- se promueve a Enforce por ola
  background: true
  failurePolicy: Fail
  rules:
    - name: require-ownership-labels
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              namespaceSelector:
                matchLabels:
                  platform.acme.io/tenant: "true"
      validate:
        message: >-
          Workloads must carry platform.acme.io/owner and
          platform.acme.io/cost-center labels. The golden path sets these
          automatically: https://backstage.acme.io/docs/platform/golden-path
        pattern:
          metadata:
            labels:
              platform.acme.io/owner: "team-?*"
              platform.acme.io/cost-center: "CC-?*"

    - name: record-provisioning-provenance
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              namespaceSelector:
                matchLabels:
                  platform.acme.io/tenant: "true"
      validate:
        message: >-
          Workloads must declare provenance via platform.acme.io/provisioned-by
          (golden-path | legacy-import | approved-offroad). This label feeds the
          adoption metric; misreporting it corrupts platform strategy decisions.
        pattern:
          metadata:
            labels:
              platform.acme.io/provisioned-by: "golden-path | legacy-import | approved-offroad"

    - name: require-resource-requests
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              namespaceSelector:
                matchLabels:
                  platform.acme.io/tenant: "true"
      validate:
        message: >-
          Containers must declare CPU and memory requests. Without them the
          scheduler cannot bin-pack and cost attribution (G5) is meaningless.
        foreach:
          - list: "request.object.spec.template.spec.containers"
            pattern:
              resources:
                requests:
                  cpu: "?*"
                  memory: "?*"
```

El **escape hatch explícito** — sin él, el guardrail se convierte en gate y la gente construye shadow platforms:

```yaml
# platform/policy/exceptions/legacy-batch.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: legacy-batch-ownership-exception
  namespace: team-analytics
  annotations:
    platform.acme.io/approved-by: team-platform
    platform.acme.io/expires: "2026-03-31"
    platform.acme.io/ticket: "PLAT-2841"
    platform.acme.io/rationale: >-
      Legacy Spark operator workloads predate the ownership label contract.
      Migration tracked in PLAT-2841; exception expires with the migration wave.
spec:
  exceptions:
    - policyName: platform-ownership-and-provenance
      ruleNames:
        - require-ownership-labels
  match:
    any:
      - resources:
          namespaces:
            - team-analytics
          kinds:
            - Deployment
          names:
            - "spark-legacy-*"
```

> **Criterio de gobierno:** toda excepción lleva **owner, rationale, ticket y fecha de expiración**. Un inventario de excepciones sin fecha es deuda de compliance invisible, y es exactamente lo que el aspecto *Operations* del maturity model evalúa en el nivel 3.

### 5.5 Rollout por olas del golden path (Argo CD ApplicationSet)

Traduce §3.6 (estrategia de migración por cohorte) a un artefacto ejecutable.

```yaml
# platform/delivery/appset-golden-path-runtime.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: golden-path-runtime
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            platform.acme.io/golden-path: "enabled"
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: platform.acme.io/wave
              operator: In
              values: ["canary"]
        - matchExpressions:
            - key: platform.acme.io/wave
              operator: In
              values: ["early-adopters"]
          maxUpdate: 25%
        - matchExpressions:
            - key: platform.acme.io/wave
              operator: In
              values: ["general"]
          maxUpdate: 10%
  template:
    metadata:
      name: '{{ .name }}-golden-path'
      labels:
        platform.acme.io/wave: '{{ index .metadata.labels "platform.acme.io/wave" }}'
        app.kubernetes.io/part-of: platform
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-runtime.git
        targetRevision: v1.8.3
        path: charts/golden-path
        helm:
          valueFiles:
            - values.yaml
            - 'envs/{{ index .metadata.labels "platform.acme.io/env" }}.yaml'
      destination:
        server: '{{ .server }}'
        namespace: platform-system
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 5
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 10m
```

### 5.6 El catálogo y el scorecard (Backstage)

El catálogo es lo que convierte "adopción" de anécdota en dato consultable.

```yaml
# apps/checkout/catalog-info.yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-api
  description: Checkout and payment orchestration API
  annotations:
    backstage.io/kubernetes-id: checkout-api
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: checkout-api
    platform.acme.io/golden-path: "webservice@v1alpha1"
    platform.acme.io/slo-dashboard: "https://grafana.acme.io/d/slo/checkout-api"
  tags:
    - golden-path
    - tier-1
  links:
    - url: https://backstage.acme.io/docs/platform/runbooks/checkout
      title: Runbook
      icon: docs
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: payments
  providesApis:
    - checkout-api-v2
  dependsOn:
    - resource:checkout-postgres
```

Checks de scorecard (Tech Insights, motor de reglas JSON) — cada check es la **evidencia automatizada de un goal**:

```yaml
# backstage/app-config.platform.yaml
techInsights:
  factRetrievers:
    entityOwnershipFactRetriever:
      cadence: '0 */6 * * *'
      lifecycle: { timeToLive: { weeks: 2 } }
  factChecker:
    checks:
      # G6 - adopción del golden path
      golden-path-adoption:
        type: json-rules-engine
        name: Uses a golden path
        description: Component is provisioned through a supported platform API.
        factIds: ['entityMetadataFactRetriever']
        rule:
          conditions:
            all:
              - fact: hasGoldenPathAnnotation
                operator: equal
                value: true
      # G3 - operabilidad
      has-owner-and-runbook:
        type: json-rules-engine
        name: Has owner and runbook
        description: Someone is on call and knows what to do.
        factIds: ['entityOwnershipFactRetriever']
        rule:
          conditions:
            all:
              - fact: hasOwner
                operator: equal
                value: true
              - fact: hasRunbookLink
                operator: equal
                value: true
      # G3 - observabilidad
      has-slo:
        type: json-rules-engine
        name: Has an SLO
        description: Service defines at least one SLO with an error budget.
        factIds: ['sloFactRetriever']
        rule:
          conditions:
            all:
              - fact: sloCount
                operator: greaterThan
                value: 0
      # G4 - seguridad
      signed-images-only:
        type: json-rules-engine
        name: Deploys signed images
        description: All running images have a verified signature.
        factIds: ['supplyChainFactRetriever']
        rule:
          conditions:
            all:
              - fact: unsignedImageCount
                operator: equal
                value: 0
```

> **Nota de versión:** la forma exacta de declarar checks de Tech Insights depende de la versión de Backstage y del fact checker instalado; el modelo conceptual (fact retriever → check → scorecard) es estable. Verificá contra `https://backstage.io/docs/features/tech-insights/`.

---

## 6. Comandos CLI y salidas reales

### 6.1 Verificar que la API de plataforma existe y está sana

```console
$ kubectl get xrd
NAME                             ESTABLISHED   OFFERED   AGE
xwebservices.platform.acme.io    True          True      63d
xpostgresinstances.platform.acme.io   True     True      63d
xobjectstores.platform.acme.io   True          True      41d

$ kubectl get composition -l platform.acme.io/golden-path-version
NAME                        XR-KIND        XR-APIVERSION                    AGE
webservice-standard         XWebService    platform.acme.io/v1alpha1        63d
webservice-multiregion      XWebService    platform.acme.io/v1alpha1        12d

$ kubectl get composition webservice-standard \
    -o jsonpath='{.metadata.labels.platform\.acme\.io/golden-path-version}{"\n"}'
1.8.3
```

### 6.2 Ejercer el golden path de punta a punta (la prueba de G1/G2)

```console
$ time kubectl apply -f apps/checkout/platform/webservice.yaml
webservice.platform.acme.io/checkout-api created

real    0m0.412s

$ kubectl -n team-payments get webservice checkout-api -w
NAME           ENDPOINT   SIZE   TEAM            PATH-VERSION   SYNCED   READY   AGE
checkout-api              m      team-payments                  True     False   4s
checkout-api              m      team-payments   1.8.3          True     False   38s
checkout-api   https://checkout.acme.io   m   team-payments   1.8.3   True   True   3m52s
```

`3m52s` es el dato que alimenta `platform_claim_ready_seconds` y, por lo tanto, el SLO de §5.1 y el KR de T2FD. **Si no lo medís, el objective no existe.**

### 6.3 Inspeccionar la abstracción cuando falla (escape hatch de diagnóstico)

```console
$ kubectl crossplane beta trace webservice checkout-api -n team-payments
NAME                                          SYNCED   READY   STATUS
WebService/checkout-api (team-payments)       True     False   Waiting: ...
└─ XWebService/checkout-api-x7k2p             True     False   Creating: Resources not ready
   ├─ Object/checkout-api-deployment          True     True    Available
   ├─ Object/checkout-api-service             True     True    Available
   ├─ Object/checkout-api-servicemonitor      True     True    Available
   ├─ Object/checkout-api-httproute           True     True    Available
   └─ Instance/checkout-api-db                False    False   ReconcileError: creating RDS instance:
                                                               InvalidParameterCombination: Cannot find
                                                               version 15.4 for postgres
```

La **fuga de la abstracción es aquí visible y aceptable**: el usuario ve, en una sola pantalla, cuál de los recursos subyacentes falló y por qué. Una plataforma que sólo muestra `READY: False` sin esta traza obliga a escalar por ticket — y eso es una regresión a nivel 1 del aspecto *Interfaces*.

### 6.4 Censo de adopción — el dato duro detrás del KR de G6

```console
$ kubectl get deployments -A \
    -L platform.acme.io/provisioned-by \
    --no-headers 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -rn
    247 golden-path
    112 legacy-import
     38 <none>
     13 approved-offroad

$ echo "scale=3; 247 / (247+112+38+13)" | bc
.602
```

**60,2 % de adopción.** Nótese el `<none>`: 38 workloads que no declaran procedencia son un **agujero en la medición**, no un 0 en la adopción. Antes de reportar el KR hay que resolverlos — reportar una métrica sobre un denominador incompleto es la falla clásica del aspecto *Measurement*.

Cruzado por equipo, para identificar dónde intervenir:

```console
$ kubectl get deployments -A -o json \
  | jq -r '.items[]
      | select(.metadata.labels["platform.acme.io/owner"] != null)
      | [ .metadata.labels["platform.acme.io/owner"],
          (.metadata.labels["platform.acme.io/provisioned-by"] // "unknown") ]
      | @tsv' \
  | sort | uniq -c \
  | awk '{print $2"\t"$3"\t"$1}' | column -t
team-payments   golden-path      31
team-payments   legacy-import     4
team-search     golden-path      18
team-search     legacy-import    41    # <-- outlier: investigar, no regañar
team-identity   golden-path      27
team-analytics  approved-offroad 13
```

`team-search` con 41 legacy contra 18 golden-path es una **señal de producto**: o el golden path no cubre su caso de uso, o el costo de migración excede el beneficio percibido. La acción correcta es una entrevista de usuario, no un mandate.

### 6.5 Consultar los KRs directamente contra Prometheus

```console
$ curl -sG http://prometheus.observability:9090/api/v1/query \
    --data-urlencode 'query=platform:golden_path_adoption:ratio' \
  | jq -r '.data.result[] | .value[1]'
0.602

$ curl -sG http://prometheus.observability:9090/api/v1/query \
    --data-urlencode 'query=dora:lead_time_seconds:p50_30d' \
  | jq -r '.data.result[] | "\(.metric.team)\t\(.value[1] | tonumber / 3600 | floor)h"'
team-payments   14h
team-search     71h
team-identity   9h
team-analytics  188h

$ curl -sG http://prometheus.observability:9090/api/v1/query \
    --data-urlencode 'query=topk(5, dora:change_failure_rate:30d)' \
  | jq -r '.data.result[] | "\(.metric.service)\t\(.value[1] | tonumber * 100 | floor)%"'
legacy-billing-worker   41%
search-indexer          33%
notification-relay      19%
checkout-api             6%
identity-gateway         4%
```

Correlación que sostiene la estrategia: los servicios con CFR alto son exactamente los que están fuera del golden path. **Ese es el argumento de adopción — evidencia, no autoridad.**

### 6.6 Validar SLOs y reglas antes de aplicarlas

```console
$ sloth generate -i platform/slo/platform-api-slo.yaml -o /tmp/slo-rules.yaml
INFO[0000] Sloth Prometheus SLO generator  version=v0.11.0
INFO[0000] Generating from Kubernetes Prometheus spec    out=/tmp/slo-rules.yaml
INFO[0000] SLO period windows loaded                     windows=2
INFO[0000] Multiwindow-multiburn alerts generated        alerts=8 slo=provisioning-success
INFO[0000] SLI recording rules generated                 rules=8 slo=provisioning-success
INFO[0000] Metadata recording rules generated            rules=7 slo=provisioning-success
INFO[0000] Multiwindow-multiburn alerts generated        alerts=8 slo=provisioning-latency
INFO[0000] SLI recording rules generated                 rules=8 slo=provisioning-latency
INFO[0000] Metadata recording rules generated            rules=7 slo=provisioning-latency
INFO[0000] Multiwindow-multiburn alerts generated        alerts=8 slo=portal-availability
INFO[0000] SLI recording rules generated                 rules=8 slo=portal-availability
INFO[0000] Metadata recording rules generated            rules=7 slo=portal-availability

$ promtool check rules platform/observability/dora-recording-rules.yaml
Checking platform/observability/dora-recording-rules.yaml
  SUCCESS: 14 rules found

$ kubectl -n platform-system get prometheusservicelevel
NAME                    SERVICE                 DESIRED SLOS   READY SLOS   GEN   AGE
platform-golden-path    platform-golden-path    3              3            2     19d

$ kubectl -n platform-system get prometheusrule -l app.kubernetes.io/generated-by=sloth
NAME                          AGE
sloth-slo-platform-golden-path 19d
```

### 6.7 Medir el impacto de una política **antes** de pasarla a `Enforce`

```console
$ kyverno apply platform/policy/golden-path-guardrails.yaml \
    --cluster --policy-report -n team-search 2>/dev/null | tail -20

Applying 3 policy rule(s) to 59 resource(s)...

pass: 18, fail: 41, warn: 0, error: 0, skip: 0

$ kubectl get policyreport -A \
    -o custom-columns='NS:.metadata.namespace,PASS:.summary.pass,FAIL:.summary.fail,WARN:.summary.warn' \
  | sort -k3 -rn | head
NS               PASS   FAIL   WARN
team-search      18     41     0
team-analytics   9      13     0
team-payments    35     4      0
team-identity    27     0      0

$ kubectl get polr -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail") | .rule' \
  | sort | uniq -c | sort -rn
     52 require-ownership-labels
     41 record-provisioning-provenance
     11 require-resource-requests
```

**Decisión estratégica basada en este dato:** `team-identity` (0 fails) puede pasar a `Enforce` hoy; `team-search` necesita trabajo de migración primero. Promoverlo globalmente ahora causaría 105 rechazos de admisión y un incidente de plataforma — que es la forma más rápida de destruir la confianza que la adopción voluntaria requiere.

Promoción por namespace, sin tocar la política global:

```console
$ kubectl label ns team-identity platform.acme.io/policy-mode=enforce --overwrite
namespace/team-identity labeled

$ kubectl get ns -L platform.acme.io/policy-mode,platform.acme.io/wave
NAME             STATUS   AGE    POLICY-MODE   WAVE
team-identity    Active   412d   enforce       canary
team-payments    Active   398d   audit         early-adopters
team-search      Active   401d   audit         general
team-analytics   Active   377d   audit         general
```

### 6.8 Estado del rollout por olas

```console
$ argocd appset get golden-path-runtime -o wide
Name:               argocd/golden-path-runtime
Project:            platform
Server:             https://argocd.acme.io
Generators:         Clusters
Strategy:           RollingSync (3 steps)

STEP  SELECTOR                  TOTAL  SYNCED  PROGRESSING  HEALTHY
1     wave in (canary)          2      2       0            2
2     wave in (early-adopters)  4      4       0            4
3     wave in (general)         5      2       1            2

$ argocd app list -l app.kubernetes.io/part-of=platform \
    -o wide 2>/dev/null | head -8
NAME                        CLUSTER          NAMESPACE        PROJECT   STATUS      HEALTH    SYNCPOLICY  REVISION
eu-west-1-prod-golden-path  eu-west-1-prod   platform-system  platform  Synced      Healthy   Auto-Prune  v1.8.3
us-east-1-prod-golden-path  us-east-1-prod   platform-system  platform  Synced      Healthy   Auto-Prune  v1.8.3
eu-central-stg-golden-path  eu-central-stg   platform-system  platform  Synced      Healthy   Auto-Prune  v1.8.3
onprem-dc1-golden-path      onprem-dc1       platform-system  platform  OutOfSync   Progressing Auto-Prune v1.8.2
```

### 6.9 Extraer deployment frequency real desde el sistema de entrega

```console
$ gh api -X GET /repos/acme/checkout-api/deployments \
    -f environment=production -f per_page=100 --paginate \
    --jq '.[].created_at' \
  | cut -d'T' -f1 | sort | uniq -c | tail -7
      3 2026-07-30
      5 2026-07-31
      2 2026-08-01
      4 2026-08-03
      6 2026-08-04
      4 2026-08-05
      2 2026-08-06
```

26 deploys a producción en 7 días para un solo servicio, contra la mediana organizacional de 1,2/mes. **Esa diferencia entre un servicio en el golden path y la mediana es el argumento de negocio de la plataforma**, y es reproducible por cualquiera.

---

## 7. Verificación y diagnóstico de fallas estratégicas

Las plataformas rara vez fallan por un bug. Fallan porque **nadie las usa, nadie las mide, o nadie confía en ellas**. Este es el runbook.

### 7.1 Tabla de diagnóstico

| Síntoma observable | Hipótesis primaria | Comando de verificación | Señal que confirma | Corrección estratégica |
|---|---|---|---|---|
| Adopción plana < 60 % durante ≥ 2 sprints | El golden path no es más fácil que la alternativa | `kubectl get deploy -A -L platform.acme.io/provisioned-by \| awk '{print $NF}' \| sort \| uniq -c` + entrevistas | Concentración de `legacy-import` en 1–2 equipos con un caso de uso común | Product discovery: entender el caso faltante. **No** mandate |
| Alta adopción **pero** DevEx survey en caída | Abstracción con fugas; usuarios atrapados sin escape hatch | `kubectl crossplane beta trace ...` sobre un claim fallido; medir tiempo hasta root cause | Traza opaca; el usuario debe abrir ticket para entender un fallo | Mejorar observabilidad de la abstracción; documentar escape hatch |
| Nº de tickets no baja tras lanzar el portal | Se automatizó el 20 % fácil; el 80 % del volumen sigue manual | `1 - platform:selfservice_ratio:30d`; taxonomía de tickets por categoría | Top-3 categorías de ticket sin capacidad self-service equivalente | Priorizar por volumen de ticket, no por elegancia técnica |
| Deploy frequency sube, CFR sube igual | Se optimizó velocidad sin guardrails; falta la contra-métrica | `dora:change_failure_rate:30d` por servicio, cruzado con `provisioned_by` | CFR alto concentrado *dentro* del golden path | El path pavimentado tiene un pozo: falta rollout progresivo/rollback automático |
| Nadie sabe si la plataforma "anda" | Aspecto *Measurement* en nivel 1 | `kubectl -n platform-system get prometheusservicelevel` | Cero SLOs, o SLOs sobre pods en lugar de sobre la promesa de producto | Definir SLI sobre el resultado del usuario (claim → Ready), no sobre infra |
| El equipo de plataforma es on-call de todo | Interacción degradó a `Collaboration` permanente | Analizar páginas por origen: plataforma vs. aplicación | > 40 % de páginas son de servicios de terceros | Restablecer X-as-a-Service: contrato de responsabilidad explícito |
| Migración estancada al 70 % | Falta forcing function; el last mile nunca se prioriza | `kubectl get polr -A` + inventario de `PolicyException` sin expiración | Excepciones perpetuas y sin owner | Fecha de deprecación anunciada + retiro de soporte para el path viejo |
| Costo de la plataforma cuestionado por finanzas | Valor no traducido a términos de negocio | `dora:lead_time_seconds:p50_30d` golden-path vs. legacy | Delta grande y estable, sin narrativa asociada | Reportar en horas-ingeniero e incidentes evitados, no en features entregadas |
| Un release de plataforma rompió a varios equipos | Ausencia de contrato versionado / de olas | `argocd appset get ...`; historial de versiones de la Composition | Rollout simultáneo global, sin canary | RollingSync por olas + versionado de la API + política de deprecación |

### 7.2 Procedimiento: "la adopción está estancada"

```console
# 1) Confirmar el hecho, con denominador limpio
$ kubectl get deploy -A -L platform.acme.io/provisioned-by --no-headers \
  | awk '{print ($NF=="" ? "UNLABELED" : $NF)}' | sort | uniq -c
    247 golden-path
    112 legacy-import
     38 UNLABELED
     13 approved-offroad

# 2) Cerrar el agujero de medición ANTES de concluir nada
$ kubectl get deploy -A -o json \
  | jq -r '.items[] | select(.metadata.labels["platform.acme.io/provisioned-by"] == null)
      | "\(.metadata.namespace)/\(.metadata.name)"' | head
team-search/legacy-crawler
team-search/legacy-crawler-eu
team-analytics/airflow-scheduler
...

# 3) Localizar la concentración
$ kubectl get deploy -A -o json \
  | jq -r '.items[] | select((.metadata.labels["platform.acme.io/provisioned-by"] // "none") != "golden-path")
      | .metadata.namespace' | sort | uniq -c | sort -rn | head -3
     54 team-search
     22 team-analytics
      9 team-payments

# 4) Verificar que el path funciona para ese caso (¿es incapacidad o es fricción?)
$ kubectl -n team-search apply --dry-run=server -f /tmp/probe-webservice.yaml
Error from server (BadRequest): admission webhook "..." denied the request:
  spec.image in body should match '^registry\.acme\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$'
```

**Root cause encontrado en el paso 4:** el XRD exige imágenes por digest desde el registry interno; `team-search` construye con tags mutables en un registry externo. La adopción no está estancada por resistencia cultural — está estancada por un **requisito no negociado**. La corrección es de producto (soportar el caso o financiar la migración del registry), no disciplinaria.

### 7.3 Procedimiento: "el SLO de la plataforma quema presupuesto"

```console
$ curl -sG http://prometheus.observability:9090/api/v1/query \
    --data-urlencode 'query=slo:current_burn_rate:ratio_rate5m{sloth_service="platform-golden-path"}' \
  | jq -r '.data.result[] | "\(.metric.sloth_slo)\t\(.value[1])"'
provisioning-success    7.41
provisioning-latency    1.02
portal-availability     0.11

$ curl -sG http://prometheus.observability:9090/api/v1/query \
    --data-urlencode 'query=sum by (reason) (increase(platform_claim_reconcile_total{outcome="failed"}[1h]))' \
  | jq -r '.data.result[] | "\(.metric.reason)\t\(.value[1])"'
provider-aws-throttled   38
composition-render-error  2
webhook-timeout           1

$ kubectl -n crossplane-system logs deploy/provider-aws-rds --tail=5
2026-08-06T11:42:07Z ERROR  cannot create external resource
  {"error": "ThrottlingException: Rate exceeded", "request-id": "a1f...", "retries": 6}
```

**Diagnóstico:** el fallo no es de la plataforma sino de un límite de API upstream, pero **el usuario lo experimenta como "la plataforma no anda"**. Esa es precisamente la responsabilidad que se asume al ofrecer una abstracción: *el SLO es de la promesa, no del componente*. Remediaciones: backoff y rate limiting en el provider, cuota de claims concurrentes por tenant, y — crítico para la confianza — **comunicar el estado en el portal**, no en un canal interno de plataforma.

### 7.4 Checklist de verificación estratégica (trimestral)

```console
# ¿Cada goal tiene un KR instrumentado, no una opinión?
$ promtool query instant http://prometheus.observability:9090 \
    'group by (__name__) ({__name__=~"platform:.*|dora:.*"})' | wc -l
14

# ¿Los SLOs de plataforma existen y están Ready?
$ kubectl get prometheusservicelevel -A \
    -o custom-columns='NAME:.metadata.name,DESIRED:.status.processedSLOs,READY:.status.promOpRulesGenerated'
NAME                   DESIRED   READY
platform-golden-path   3         true

# ¿Hay excepciones de política vencidas? (deuda de compliance invisible)
$ kubectl get policyexception -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.platform\.acme\.io/expires}{"\n"}{end}'
team-analytics/legacy-batch-ownership-exception    2026-03-31
team-search/registry-exception                     <none>

# ^ dos hallazgos: una vencida y una sin fecha. Ambas son bloqueantes del nivel 3
#   del aspecto Operations del CNCF Maturity Model.

# ¿El contrato de la API está versionado y hay plan de deprecación?
$ kubectl get xrd xwebservices.platform.acme.io \
    -o jsonpath='{range .spec.versions[*]}{.name}{"\tserved="}{.served}{"\treferenceable="}{.referenceable}{"\n"}{end}'
v1alpha1    served=true    referenceable=true
```

---

## 8. Anti-patterns — reconocimiento y remedio

| Anti-pattern | Cómo se ve en producción | Aspecto del maturity model que delata | Remedio |
|---|---|---|---|
| **Ivory tower platform** | Diseñada sin usuarios; arquitectónicamente elegante; adopción < 20 % | `Interfaces` alto, `Adoption` bajo | User research; product manager dedicado; medir antes de construir |
| **Platform as ticket queue** | Portal existe pero todo pedido real termina en Jira | `Interfaces` nivel 1–2 | Automatizar por volumen de ticket, no por elegancia |
| **Mandate sin producto** | Adopción 100 % por decreto, satisfacción en el piso, workarounds proliferando | `Adoption` alto pero SPACE-S bajo | Reintroducir opcionalidad donde no sea regulatorio |
| **Big bang migration** | "Todos migran para el Q3"; incidente masivo; congelamiento | `Operations` nivel 1 | Strangler fig + olas + rollback por ola |
| **Abstracción sin escape hatch** | El caso 5 % imposible bloquea al equipo; se construye shadow platform | `Interfaces` nivel 3 sin nivel 4 | `approved-offroad` documentado + primitivas expuestas |
| **Métricas de vanidad** | Se reporta "nº de features de plataforma entregadas" | `Measurement` nivel 1–2 | Reemplazar outputs por outcomes: DORA + adopción + SPACE |
| **Plataforma sin SLO ni on-call** | Cae un viernes; nadie responde; la confianza no se recupera | `Operations` nivel 1 | SLOs de producto (§5.1) + rotación on-call + status page |
| **Golden path sin versionar** | Un cambio en la Composition rompe 200 servicios | `Operations` nivel 2 | Versionado de API, olas, política de deprecación con ventana anunciada |
| **Optimizar una sola métrica** | Deploy frequency sube 5×; CFR sube 3× | `Measurement` nivel 2 | Guardrail metrics obligatorias en cada OKR |
| **Plataforma que compite con el negocio** | Se construyen capacidades que ya existen mejores en el mercado | `Investment` desalineado | Aplicar la matriz build/buy/assemble (§3.2) explícitamente |

---

## 9. Síntesis operativa — la estrategia en una página

```
GOAL          G1 Reducir carga cognitiva
   OBJECTIVE  "El camino por default a producción no requiere conocer Kubernetes"
      KR1     Campos obligatorios en el manifiesto del usuario: 39 conceptos -> <= 10
              [medición: schema del XRD, revisable en cada release]
      KR2     T2FD p50: 21 d -> <= 2 d
              [medición: platform:time_to_first_deploy_seconds:p50_90d]
      GUARD    DevEx survey satisfaction >= 4.0/5 (no "simplificar" ocultando)
      TACTIC   XRD webservices.platform.acme.io v1alpha1 + Composition webservice-standard

GOAL          G2 Acelerar el flujo
   OBJECTIVE  "El path por default es el más rápido disponible"
      KR1     Lead time p50 golden-path <= 4 h
              [dora:lead_time_seconds:p50_30d]
      KR2     Servicios que despliegan >= 1x/semana: 18% -> 55%
              [dora:services_deploying_weekly:ratio]
      GUARD    CFR <= 15%  [dora:change_failure_rate:30d]
      TACTIC   Argo CD + ApplicationSet RollingSync + rollback automatizado

GOAL          G4 Compliance by default
   OBJECTIVE  "El cumplimiento es propiedad del path, no del reviewer"
      KR1     Workloads conformes: 61% -> 95%   [kubectl get polr -A]
      KR2     Excepciones con owner + fecha de expiración: 100%
      GUARD    Rechazos de admisión por semana <= 5 (guardrail, no gate)
      TACTIC   Kyverno Audit -> Enforce por ola + PolicyException con TTL

GOAL          G6 Estandarización sin osificación
   OBJECTIVE  "El golden path cubre el caso común; salirse es posible y trazable"
      KR1     Adopción golden path: 60.2% -> 80%
              [platform:golden_path_adoption:ratio]
      KR2     Workloads sin etiqueta de procedencia: 38 -> 0
      GUARD    Tiempo de aprobación de un off-road <= 5 días hábiles
      TACTIC   Etiqueta provisioned-by obligatoria + PolicyReport + censo semanal
```

**Reglas mnemotécnicas para el examen:**

1. **Goal ≠ Objective ≠ KR ≠ Tactic.** Si se puede "entregar", es un output; un KR es un cambio medido en el comportamiento del sistema o de los usuarios.
2. **Velocidad y estabilidad no son un trade-off** (hallazgo central de DORA). Si su plataforma los enfrenta, la estrategia está mal.
3. **Paved road por default; mandate sólo para lo regulatorio.**
4. **Thinnest Viable Platform primero.** El IDP completo es consecuencia, no punto de partida.
5. **El maturity model diagnostica desbalances, no ordena escalones.** El aspecto más barato y más urgente casi siempre es *Measurement*.
6. **Plataforma sin SLO no es un producto, es un side project con usuarios.**
7. **Toda abstracción necesita un escape hatch documentado**, o la organización construirá uno indocumentado.
8. **X-as-a-Service es el modo de interacción por default**; `Collaboration` es válido pero explícitamente temporal.

---

## 10. Referencias

**Fuente primaria del examen**
- CNCF — *Cloud Native Platform Engineering Associate (CNPA) Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Linux Foundation — CNPA certification: https://training.linuxfoundation.org/certification/cloud-native-platform-engineering-associate-cnpa/

**Documentos normativos de CNCF sobre platform engineering**
- CNCF TAG App Delivery — *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNCF TAG App Delivery — *Platforms White Paper* (definición de plataforma y capabilities): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — repositorio fuente: https://github.com/cncf/tag-app-delivery
- CNCF Glossary — *Platform Engineering*: https://glossary.cncf.io/platform-engineering/

**Métricas y marcos de medición**
- DORA — *State of DevOps Research* y definición de las métricas: https://dora.dev/
- DORA — Capabilities catalog: https://dora.dev/capabilities/
- Forsgren, Storey, Maddila, Zimmermann, Houck, Butler — *The SPACE of Developer Productivity*, ACM Queue: https://queue.acm.org/detail.cfm?id=3454124
- Four Keys (implementación de referencia de métricas DORA): https://github.com/dora-team/fourkeys
- OpenTelemetry — CI/CD semantic conventions: https://opentelemetry.io/docs/specs/semconv/cicd/

**Modelos organizacionales**
- Team Topologies — team types e interaction modes: https://teamtopologies.com/key-concepts
- Team Topologies — *Thinnest Viable Platform*: https://teamtopologies.com/key-concepts-content/what-is-a-thinnest-viable-platform-tvp

**Herramientas citadas en los manifiestos**
- Crossplane — Composite Resource Definitions: https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane — Compositions: https://docs.crossplane.io/latest/concepts/compositions/
- Argo CD — ApplicationSet Progressive Syncs: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/
- Kyverno — Policy definition y `validationFailureAction`: https://kyverno.io/docs/policy-types/cluster-policy/
- Kyverno — PolicyException: https://kyverno.io/docs/exceptions/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Sloth — Prometheus SLO generator: https://sloth.dev/
- OpenSLO — especificación: https://github.com/OpenSLO/OpenSLO
- Prometheus Operator — `PrometheusRule`: https://prometheus-operator.dev/docs/api-reference/api/
- Backstage — Software Catalog descriptor format: https://backstage.io/docs/features/software-catalog/descriptor-format
- Backstage — Tech Insights (scorecards): https://backstage.io/docs/features/tech-insights/
- Score — workload specification (CNCF Sandbox): https://score.dev/
- Google SRE Workbook — *Implementing SLOs* y *Alerting on SLOs*: https://sre.google/workbook/implementing-slos/

**Contexto de industria**
- Puppet — *State of DevOps Report: Platform Engineering Edition*: https://www.puppet.com/resources/state-of-platform-engineering
- CNCF Blog — Platforms Working Group: https://www.cncf.io/blog/2023/06/08/a-guide-to-platform-engineering/