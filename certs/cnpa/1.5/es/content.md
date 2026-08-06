# Tema 1.5 — Platform Engineering: Goals, Objectives y Strategic Approaches

**Certificación:** CNPA (Cloud Native Platform Engineering Associate) · Currículum 2025-04-01
**Dominio:** 1 — Platform Engineering Core Fundamentals · **Peso:** 7.2%

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 El escenario

Una organización con 42 stream-aligned teams, 310 servicios, 6 clusters de Kubernetes (2 regiones × dev/stage/prod) y despliegues en tres cloud providers. No existe un platform team formal: cada squad resolvió por su cuenta el camino desde "commit" hasta "tráfico productivo".

El inventario real después de una auditoría:

```
$ grep -rl "kind: Deployment" --include="*.yaml" . | wc -l
1187

$ find . -name "Chart.yaml" -exec yq -r '.name + " " + .version' {} \; | sort -u | wc -l
94

$ find . -name "*.tf" | xargs grep -h "source *=" | sort | uniq -c | sort -rn | head -8
     61   source = "terraform-aws-modules/eks/aws"
     38   source = "../../modules/rds"
     29   source = "git::ssh://git@github.com/acme/tf-modules.git//rds?ref=v2.1.0"
     27   source = "git::ssh://git@github.com/acme/tf-modules.git//rds?ref=v1.4.2"
     22   source = "git::ssh://git@github.com/acme/tf-modules.git//rds?ref=main"
     19   source = "./rds"
     14   source = "terraform-aws-modules/rds/aws"
      9   source = "git::ssh://git@github.com/acme/tf-modules.git//rds?ref=v0.9.0"
```

Cinco versiones distintas del mismo módulo de RDS conviviendo en producción, tres de ellas sin pin (`main`) y una copiada localmente. Noventa y cuatro charts de Helm para 310 servicios. Ese es el síntoma. El problema es otro.

### 1.2 La factura oculta: cognitive load

La carga cognitiva de un equipo es finita. Skelton y Pais, apoyándose en la taxonomía de Sweller, la descomponen en tres tipos:

| Tipo | Definición | Ejemplo en un stream-aligned team | Quién debería absorberla |
|---|---|---|---|
| **Intrinsic** | Complejidad inherente al dominio del problema | Reglas de negocio de facturación, modelo de riesgo crediticio | El propio equipo (es su razón de existir) |
| **Extraneous** | Complejidad accidental impuesta por la forma de trabajar | Escribir un `Ingress` a mano, rotar credenciales de RDS, configurar OIDC en Argo CD, elegir entre 5 módulos de Terraform | **La plataforma** |
| **Germane** | Esfuerzo de aprendizaje que construye capacidad duradera | Aprender el modelo de consistencia de su base de datos | El equipo, con soporte de un enabling team |

El objetivo estratégico primario de platform engineering es **minimizar la carga extraneous para maximizar el presupuesto cognitivo disponible para la carga intrinsic**. No es "estandarizar", no es "reducir costos de cloud", no es "hacer que todos usen Kubernetes". Esos son efectos de segundo orden, y confundirlos con el objetivo primario es la causa raíz de la mayoría de las plataformas que fracasan.

Cuantificación operativa del problema en el escenario anterior:

```
$ ./scripts/onboarding-audit.sh --team payments --since 2025-01-01
Time to first commit merged .................. 2 days
Time to first deploy in dev .................. 11 days
Time to first deploy in prod ................. 34 days
Distinct systems requiring an account ........ 9
Tickets opened to infra/SRE .................. 23
Wall-clock time blocked on tickets ........... 19 days (56% of onboarding)
Distinct YAML schemas authored by the team ... 7
```

Diecinueve de treinta y cuatro días bloqueados esperando a otro equipo. Ese es el número que una plataforma existe para atacar.

### 1.3 Qué es una plataforma (definición CNCF)

El *CNCF Platforms White Paper* define una plataforma como:

> Un conjunto **curado** e **integrado** de capacidades, expuestas mediante **interfaces autoservicio**, diseñadas y operadas **como un producto** para sus usuarios internos.

Cuatro palabras cargan todo el peso conceptual y **las cuatro aparecen en el examen**:

| Palabra | Implicación técnica | Anti-patrón que excluye |
|---|---|---|
| **Curado** | Hay opiniones. Un camino recomendado, no un catálogo infinito | "Wiki con 40 links a documentación de AWS" |
| **Integrado** | Las capacidades se componen entre sí: identidad, telemetría y policy atraviesan todas | "Colección de herramientas sueltas que el usuario debe pegar" |
| **Autoservicio** | El usuario obtiene el resultado sin intervención humana del platform team | "Portal que abre un ticket en Jira" |
| **Como producto** | Usuarios, no súbditos. Adopción voluntaria, roadmap, feedback, métricas de uso | "Mandato del CTO sin discovery" |

Una plataforma **no es**:
- Un cluster de Kubernetes (eso es infraestructura).
- Un portal (eso es *una* de las interfaces posibles).
- El equipo de SRE con otro nombre.
- Un wrapper de `kubectl`.

### 1.4 Los tres modos de fallo estratégicos

| Modo de fallo | Mecánica | Señal temprana medible | Contramedida estratégica |
|---|---|---|---|
| **Ticket-ops con esteroides** | La plataforma expone una UI, pero cada operación no trivial requiere aprobación manual del platform team | `p95(time_to_provision)` en horas/días; ratio de PRs al repo de plataforma abiertos por el platform team > 60% | Automatizar el path de aprobación con policy-as-code; convertir excepciones en capabilities |
| **Abstracción con fuga (leaky abstraction)** | La abstracción oculta la complejidad hasta que falla; entonces el usuario debe entender ambas capas | Volumen de tickets de tipo "mi claim está `Ready: False` y no entiendo por qué" | Exponer estado y errores del sistema subyacente en la interfaz de alto nivel; `status.conditions` propagadas |
| **Plataforma sin usuarios** | Se construyó lo que el platform team quería construir, no lo que los stream-aligned teams necesitaban | Adoption rate estancada < 30% a 6 meses; existencia de "shadow platforms" | Product management real: entrevistas, TVP, adopción voluntaria como test de valor |

---

## 2. Goals, Objectives y Key Results: la jerarquía que el examen evalúa

CNPA distingue explícitamente entre tres niveles. Confundirlos es el error más común del dominio.

| Nivel | Pregunta que responde | Horizonte | Propiedad | Ejemplo |
|---|---|---|---|---|
| **Goal** (meta) | ¿Por qué existe la plataforma? | 1–3 años | Cualitativo, direccional, **no medible por sí mismo** | "Reducir la carga cognitiva extraneous de los stream-aligned teams" |
| **Objective** (objetivo) | ¿Qué cambio observable buscamos este trimestre/semestre? | 1–2 trimestres | Medible, acotado en el tiempo | "Llevar el time-to-first-production-deploy de un servicio nuevo de 34 días a menos de 3" |
| **Key Result / SLO** | ¿Cómo sabemos que lo logramos? | Continuo | Numérico, con umbral y ventana | "p95 de `platform_service_provision_duration_seconds` < 900s sobre ventana rolling de 28d, con 99% de éxito" |

### 2.1 Cadena de derivación completa (goal → SLI)

```
GOAL       Reducir carga cognitiva extraneous
   │
   ├── OBJECTIVE 1  Onboarding de servicio nuevo < 3 días
   │      ├── KR 1.1  95% de los servicios nuevos creados vía golden path
   │      │      └── SLI  golden_path_services / total_new_services
   │      └── KR 1.2  p95 provisioning end-to-end < 15 min
   │             └── SLI  histogram_quantile(0.95, platform_service_provision_duration_seconds_bucket)
   │
   ├── OBJECTIVE 2  Eliminar el ticket como interfaz
   │      └── KR 2.1  < 5% de las operaciones de plataforma requieren intervención humana
   │             └── SLI  manual_interventions_total / platform_operations_total
   │
   └── OBJECTIVE 3  La plataforma no es un SPOF del delivery
          └── KR 3.1  Disponibilidad del control plane de plataforma 99.9% mensual
                 └── SLI  sum(rate(apiserver_request_total{code!~"5.."}[5m])) / sum(rate(apiserver_request_total[5m]))
```

**Regla mnemotécnica para el examen:** un *goal* nunca lleva número. Un *objective* siempre lleva número y fecha. Un *key result* es el SLI con su umbral. Si una pregunta presenta "aumentar la satisfacción del desarrollador" como *objective*, es incorrecto: es un *goal*; el *objective* sería "elevar el eNPS de la plataforma de 12 a 30 para el Q4".

### 2.2 Marcos de medición: DORA, SPACE y métricas propias de plataforma

Tres familias, tres propósitos distintos. El examen espera que se sepa **cuál usar para qué**.

| Marco | Qué mide | Unidad de análisis | Uso correcto en platform engineering | Uso incorrecto (trampa de examen) |
|---|---|---|---|---|
| **DORA** (4 keys) | Rendimiento del sistema de delivery: Deployment Frequency, Lead Time for Changes, Change Failure Rate, Failed Deployment Recovery Time | El **sistema** de entrega de un equipo | Medir el efecto de la plataforma sobre el delivery de los equipos que la adoptaron vs. los que no | Comparar equipos entre sí; usarlo como métrica de performance individual |
| **SPACE** | Productividad multidimensional: **S**atisfaction & well-being, **P**erformance, **A**ctivity, **C**ommunication & collaboration, **E**fficiency & flow | Individuo, equipo y sistema simultáneamente | Complementar DORA con la dimensión humana (satisfacción con la plataforma, fricción percibida) | Reducirlo a la "A" de Activity (líneas de código, commits) |
| **Platform-specific** | Salud del producto plataforma: adoption rate, golden path coverage, time-to-first-deploy, self-service ratio, error budget de la plataforma | La **plataforma** como producto | Gestionar el producto: priorizar roadmap, detectar abandono | Confundir "uso" con "valor" (un usuario cautivo por mandato no valida nada) |

Punto crítico: **DORA mide el resultado, no la plataforma**. Si la deployment frequency sube, puede ser por la plataforma o por un cambio de proceso. La forma metodológicamente correcta de atribuir es comparar cohortes: equipos on-platform vs. off-platform, sobre el mismo período.

| Métrica de plataforma | Fórmula | Objetivo de referencia | Qué detecta cuando se degrada |
|---|---|---|---|
| **Adoption rate** | `servicios_on_platform / servicios_totales` | > 80% con adopción voluntaria | El producto no resuelve un dolor real |
| **Golden path coverage** | `casos_de_uso_cubiertos / casos_de_uso_relevantes` | > 70% | Demasiadas excepciones → la abstracción es muy angosta |
| **Self-service ratio** | `1 − (intervenciones_manuales / operaciones)` | > 0.95 | Regresión hacia ticket-ops |
| **Time to first deploy (T2FD)** | Mediana desde `repo created` hasta `first prod deploy` | < 1 día | Fricción en onboarding |
| **Platform error budget burn** | `(1 − SLI) / (1 − SLO_target)` | < 1.0 sobre la ventana | La plataforma es un SPOF del delivery |
| **Escape hatch rate** | `deploys_con_excepción / deploys_totales` | < 10% y **estable o decreciente** | El paved road no cubre la realidad |

---

## 3. Strategic approaches

### 3.1 Build vs Buy vs Assemble vs Fork-and-own

| Enfoque | Descripción | Costo inicial | Costo operativo | Time to value | Diferenciación | Cuándo elegirlo |
|---|---|---|---|---|---|---|
| **Build** | Desarrollo propio desde cero (control plane, APIs, UI) | Muy alto | Muy alto | 12–24 meses | Máxima | Solo si la plataforma **es** ventaja competitiva y hay >20 ingenieros dedicados |
| **Buy** | SaaS/producto comercial end-to-end (Heroku-like, PaaS gestionado) | Bajo | Bajo–medio (licencias) | Semanas | Nula | Organizaciones pequeñas, o dominios no diferenciadores |
| **Assemble** | Integrar componentes CNCF open source detrás de una interfaz propia y delgada | Medio | Medio | 3–6 meses | Media (está en la integración) | **Default recomendado** para la mayoría de organizaciones medianas/grandes |
| **Fork-and-own** | Tomar un producto open source y mantener un fork divergente | Medio | Muy alto y creciente | Meses | Baja | Casi nunca: la deuda de merge crece sin límite |

El enfoque **assemble** es el que asume el ecosistema CNCF. La plataforma es *pegamento opinado* sobre componentes maduros:

```
Interfaces        Backstage / CLI propia / API REST / GitOps repo
    │
Orquestación      Crossplane · Kubernetes Resource Model · Argo CD / Flux
    │
Capacidades       cert-manager · External Secrets · Kyverno/OPA · Prometheus ·
                  OpenTelemetry · Istio/Linkerd · Knative · KEDA
    │
Infra             Kubernetes · cloud providers · redes · almacenamiento
```

La regla de decisión práctica: **construir solo la capa de interfaz y composición; comprar o ensamblar todo lo demás**. El valor diferencial está en las opiniones codificadas, no en reimplementar un controlador de certificados.

### 3.2 Modelos operativos (Team Topologies aplicado)

| Modelo | Estructura | Interacción con stream-aligned teams | Ventaja | Riesgo dominante |
|---|---|---|---|---|
| **Centralized platform team** | Un equipo dedicado, dueño del producto plataforma | **X-as-a-Service** (autoservicio, baja interacción) | Coherencia, economías de escala | Se convierte en cuello de botella si degrada a ticket-ops |
| **Enabling team** | Equipo que capacita, no opera | **Facilitating** (alta interacción, temporal) | Transfiere capacidad; no crea dependencia | No escala si no hay plataforma detrás |
| **Federated / guild** | Contribuciones distribuidas con un core pequeño | **Collaboration** → luego X-as-a-Service | Alta cobertura de casos de uso | Fragmentación, sin dueño de la coherencia |
| **Embedded SRE** | SREs dentro de cada stream-aligned team | Collaboration permanente | Contexto profundo | No produce reutilización; multiplica el costo por N equipos |
| **Complicated-subsystem team** | Equipo para un componente de alta especialización (p. ej. motor de ML, engine de trading) | X-as-a-Service | Concentra expertise escasa | Confundirlo con platform team: su producto no es autoservicio general |

Modelo de referencia para el escenario del §1.1: **platform team centralizado (X-as-a-Service) + enabling team temporal** para acompañar la migración de los primeros 5–8 equipos. La interacción *collaboration* es aceptable durante el discovery, pero debe tener **fecha de expiración explícita**; si a los 6 meses el platform team sigue colaborando en modo alta interacción con todos, la plataforma no existe como producto.

### 3.3 Modelos de adopción

| Modelo | Mecánica | Adopción a 12 meses (típica) | Señal de calidad del producto | Riesgo |
|---|---|---|---|---|
| **Mandate (top-down)** | La dirección obliga a usar la plataforma | 100% nominal | **Ninguna** — el uso no valida valor | Shadow platforms, resentimiento, plataforma mala que nadie puede evitar |
| **Pull / voluntary** | Adopción puramente voluntaria | 30–70% | **Máxima** — cada adopción es un voto | Fragmentación persistente si el producto no convence |
| **Paved road con escape hatch** | Camino recomendado con beneficios reales (velocidad, compliance automático); salirse es posible pero costoso y visible | 80–95% | Alta | Requiere disciplina para no cerrar la escotilla por decreto |
| **Guardrails obligatorios + camino opcional** | Las políticas de seguridad/compliance se aplican a todos vía admission control; el *cómo* llegar a cumplirlas es libre, pero el golden path ya cumple | 85–95% | Alta | Complejidad de las policies |

**El enfoque canónico de CNPA es "paved road con guardrails".** Descompuesto en dos planos que no deben confundirse:

- **Paved road (golden path)** → *opt-in*. Es una propuesta de valor: "usá esto y en 12 minutos tenés un servicio en producción con TLS, observabilidad, secrets y CI".
- **Guardrails** → *obligatorios y no negociables*. Se aplican por admission control a todo el cluster, esté en el golden path o no: "ningún pod corre como root, ninguna imagen sin firmar, ningún namespace sin `NetworkPolicy`".

La escotilla de escape (*escape hatch*) es un requisito de diseño, no una concesión: sin ella, el primer caso de uso no soportado se convierte en un bloqueo de negocio y la plataforma pierde legitimidad. Pero debe ser **medible** (`escape_hatch_rate`) y cada uso debe generar un ítem de backlog.

### 3.4 Thinnest Viable Platform (TVP)

Concepto de Team Topologies que el examen puede evaluar: la plataforma debe ser **lo más delgada posible** para cumplir su propósito, y crecer solo bajo demanda demostrada.

Una TVP válida puede ser literalmente:

```markdown
# Golden Path: HTTP service (TVP v0.1)

1. `gh repo create --template acme/tpl-http-service`
2. Editá `service.yaml` (name, port, resources)
3. `git push` → CI construye, firma y despliega a dev automáticamente
4. Promoción a prod: aprobá el PR que abre el bot en `acme/deployments`

Soporte: #platform-help · SLO de respuesta: 4h hábiles
Escape hatch: agregá `platform.acme.io/exception: <ticket>` y avisanos
```

Cuatro pasos, un template de repo, un pipeline y un archivo de configuración. Si eso resuelve el 70% de los casos, es una plataforma. Construir un portal de Backstage con 14 plugins antes de validar ese flujo es el error de secuencia más caro del dominio.

### 3.5 CNCF Platform Engineering Maturity Model

Modelo de referencia de CNCF, **contenido directamente examinable**. Cinco *aspects* × cuatro *levels*.

| Aspect | Nivel 1 — Provisional | Nivel 2 — Operational | Nivel 3 — Scalable | Nivel 4 — Optimizing |
|---|---|---|---|---|
| **Investment** | Esfuerzo voluntario, sin presupuesto; individuos en su tiempo libre | Equipo dedicado con presupuesto asignado | Inversión sostenida y planificada; la plataforma tiene roadmap financiado | Inversión ajustada dinámicamente según valor medido |
| **Adoption** | Ad-hoc; algunos equipos, por relación personal | Adopción impulsada activamente (evangelismo, mandato parcial) | Los usuarios eligen la plataforma porque es el camino más fácil | Adopción es el default; los equipos contribuyen de vuelta |
| **Interfaces** | Herramientas sueltas, sin interfaz común; documentación dispersa | Interfaces documentadas y consistentes para casos comunes | Autoservicio completo con múltiples interfaces (API, CLI, UI, GitOps) | Interfaces evolucionadas con el usuario; versionadas y con deprecation policy |
| **Operations** | Manual, reactivo, best-effort | Procesos definidos; el platform team opera el servicio | Operación automatizada con SLOs y error budgets | Auto-remediación; la operación informa el diseño del producto |
| **Measurement** | Sin medición, o solo anecdótica | Métricas básicas de uso recolectadas | Métricas de negocio y experiencia ligadas a decisiones de roadmap | Medición continua que dispara cambios automáticos de priorización |

Uso correcto del modelo: **no es una escalera que hay que subir hasta el 4 en todos los aspects**. Es un instrumento de diagnóstico para detectar *desbalances*. El patrón patológico más frecuente:

```
Interfaces:    ████████████████  Nivel 4  (Backstage con 20 plugins)
Adoption:      ████              Nivel 1  (3 equipos, por favor personal)
Measurement:   ████              Nivel 1  (nadie sabe si sirve)
Investment:    ████████          Nivel 2
Operations:    ████████          Nivel 2
```

Interfaces en nivel 4 con Adoption y Measurement en nivel 1 es la firma de una plataforma construida por entusiasmo técnico sin product management. La acción correcta no es agregar plugins: es medir y hacer discovery.

---

## 4. Manifiestos e infraestructura

Los manifiestos siguientes implementan una plataforma mínima pero completa que materializa la estrategia: **una API declarativa de alto nivel (golden path), guardrails obligatorios, delivery GitOps y medición de los objectives**.

### 4.1 El objective, codificado: OpenSLO del golden path

`platform/slo/golden-path-provisioning.yaml`

```yaml
apiVersion: openslo/v1
kind: Service
metadata:
  name: platform-golden-path
  displayName: Golden Path — HTTP Service
spec:
  description: >
    Self-service provisioning of a production-ready HTTP service:
    namespace, database, TLS ingress, observability and GitOps app.
---
apiVersion: openslo/v1
kind: SLO
metadata:
  name: golden-path-provision-latency
  displayName: Provisioning latency (KR 1.2)
  annotations:
    platform.acme.io/objective: "Onboarding of a new service under 3 days"
    platform.acme.io/goal: "Reduce extraneous cognitive load"
spec:
  description: >
    95% of XService claims must reach Ready=True in under 900 seconds,
    measured over a rolling 28-day window.
  service: platform-golden-path
  indicator:
    metadata:
      name: provision-under-900s
    spec:
      ratioMetric:
        counter: true
        good:
          metricSource:
            type: Prometheus
            spec:
              query: >
                sum(increase(
                  platform_service_provision_duration_seconds_bucket{le="900"}[28d]
                ))
        total:
          metricSource:
            type: Prometheus
            spec:
              query: >
                sum(increase(
                  platform_service_provision_duration_seconds_count[28d]
                ))
  timeWindow:
    - duration: 28d
      isRolling: true
  budgetingMethod: Occurrences
  objectives:
    - displayName: 95% under 15 minutes
      target: 0.95
---
apiVersion: openslo/v1
kind: SLO
metadata:
  name: golden-path-availability
  displayName: Platform control plane availability (KR 3.1)
spec:
  description: >
    The platform control plane must not become a single point of failure
    for the delivery of stream-aligned teams.
  service: platform-golden-path
  indicator:
    metadata:
      name: control-plane-success-ratio
    spec:
      ratioMetric:
        counter: true
        good:
          metricSource:
            type: Prometheus
            spec:
              query: >
                sum(rate(apiserver_request_total{
                  group="platform.acme.io", code!~"5.."
                }[30d]))
        total:
          metricSource:
            type: Prometheus
            spec:
              query: >
                sum(rate(apiserver_request_total{group="platform.acme.io"}[30d]))
  timeWindow:
    - duration: 30d
      isRolling: false
  budgetingMethod: Occurrences
  objectives:
    - displayName: 99.9% monthly
      target: 0.999
```

### 4.2 La interfaz: CompositeResourceDefinition (Crossplane)

Esta es *la* abstracción del golden path. El contrato entre plataforma y usuario. Todo lo que no está en este schema es carga cognitiva que el usuario ya no soporta.

`platform/apis/xservice-definition.yaml`

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xservices.platform.acme.io
  annotations:
    platform.acme.io/golden-path: "http-service"
    platform.acme.io/owner: "platform-team"
    platform.acme.io/stability: "beta"
spec:
  group: platform.acme.io
  names:
    kind: XService
    plural: xservices
  claimNames:
    kind: Service
    plural: services
  defaultCompositionRef:
    name: xservice-aws-standard
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
              properties:
                name:
                  type: string
                  description: Logical service name; becomes the namespace and DNS label.
                  pattern: '^[a-z][a-z0-9-]{2,29}$'
                team:
                  type: string
                  description: Owning stream-aligned team; must exist in the org catalog.
                  pattern: '^[a-z][a-z0-9-]{2,29}$'
                tier:
                  type: string
                  description: >
                    Criticality tier. Drives replica count, PDB, backup retention
                    and on-call routing. This is the ONLY capacity knob exposed.
                  enum: ["experimental", "standard", "critical"]
                  default: "standard"
                repository:
                  type: string
                  description: Git repository URL that holds the service manifests.
                  pattern: '^https://github\.com/acme/[a-z0-9-]+$'
                database:
                  type: object
                  description: Optional managed PostgreSQL instance.
                  properties:
                    enabled:
                      type: boolean
                      default: false
                    sizeGB:
                      type: integer
                      minimum: 20
                      maximum: 1000
                      default: 20
                    engineVersion:
                      type: string
                      enum: ["15", "16"]
                      default: "16"
                  required:
                    - enabled
                exposure:
                  type: object
                  properties:
                    public:
                      type: boolean
                      default: false
                    hostname:
                      type: string
                      description: FQDN; must live under an owned zone.
                      pattern: '^[a-z0-9.-]+\.acme\.io$'
              required:
                - name
                - team
                - repository
                - database
            status:
              type: object
              properties:
                url:
                  type: string
                  description: Public URL, if exposed.
                namespace:
                  type: string
                databaseEndpoint:
                  type: string
                argoApplication:
                  type: string
                provisionedAt:
                  type: string
                  format: date-time
      additionalPrinterColumns:
        - name: TEAM
          type: string
          jsonPath: ".spec.team"
        - name: TIER
          type: string
          jsonPath: ".spec.tier"
        - name: URL
          type: string
          jsonPath: ".status.url"
        - name: READY
          type: string
          jsonPath: ".status.conditions[?(@.type=='Ready')].status"
        - name: AGE
          type: date
          jsonPath: ".metadata.creationTimestamp"
```

> **Nota de versión.** Este XRD usa `apiextensions.crossplane.io/v1` con `claimNames`, el modelo de Crossplane v1.x. En Crossplane v2 los composite resources son namespaced por defecto y el par XR/Claim se unifica; verificar la versión instalada con `kubectl get deploy -n crossplane-system crossplane -o jsonpath='{.spec.template.spec.containers[0].image}'` antes de aplicar.

### 4.3 La implementación: Composition

`platform/apis/xservice-composition-aws.yaml`

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xservice-aws-standard
  labels:
    provider: aws
    golden-path: http-service
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XService
  writeConnectionSecretsToNamespace: crossplane-system
  mode: Pipeline
  pipeline:
    - step: render-resources
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:

          # ---------- 1. Namespace with platform-managed labels ----------
          - name: namespace
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: Namespace
                    metadata:
                      name: placeholder
                      labels:
                        platform.acme.io/managed: "true"
                        platform.acme.io/golden-path: "http-service"
                        pod-security.kubernetes.io/enforce: restricted
                        pod-security.kubernetes.io/audit: restricted
                        pod-security.kubernetes.io/warn: restricted
                providerConfigRef:
                  name: kubernetes-default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-namespace"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.team
                toFieldPath: spec.forProvider.manifest.metadata.labels['platform.acme.io/team']
              - type: FromCompositeFieldPath
                fromFieldPath: spec.tier
                toFieldPath: spec.forProvider.manifest.metadata.labels['platform.acme.io/tier']
              - type: ToCompositeFieldPath
                fromFieldPath: spec.forProvider.manifest.metadata.name
                toFieldPath: status.namespace

          # ---------- 2. Default-deny NetworkPolicy (guardrail) ----------
          - name: network-policy-baseline
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: networking.k8s.io/v1
                    kind: NetworkPolicy
                    metadata:
                      name: default-deny-ingress
                      namespace: placeholder
                    spec:
                      podSelector: {}
                      policyTypes:
                        - Ingress
                      ingress:
                        - from:
                            - namespaceSelector:
                                matchLabels:
                                  kubernetes.io/metadata.name: ingress-nginx
                            - namespaceSelector:
                                matchLabels:
                                  kubernetes.io/metadata.name: observability
                providerConfigRef:
                  name: kubernetes-default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-netpol"

          # ---------- 3. Managed PostgreSQL (optional) ----------
          - name: database
            base:
              apiVersion: rds.aws.upbound.io/v1beta1
              kind: Instance
              spec:
                forProvider:
                  region: eu-west-1
                  engine: postgres
                  engineVersion: "16"
                  instanceClass: db.t4g.medium
                  allocatedStorage: 20
                  storageEncrypted: true
                  username: platform
                  autoGeneratePassword: true
                  passwordSecretRef:
                    namespace: crossplane-system
                    name: placeholder-db-password
                    key: password
                  skipFinalSnapshot: false
                  backupRetentionPeriod: 7
                  deletionProtection: true
                  publiclyAccessible: false
                  vpcSecurityGroupIdSelector:
                    matchLabels:
                      platform.acme.io/purpose: database
                  dbSubnetGroupNameSelector:
                    matchLabels:
                      platform.acme.io/purpose: database
                  tags:
                    managed-by: crossplane
                    golden-path: http-service
                writeConnectionSecretToRef:
                  namespace: crossplane-system
                  name: placeholder-db-conn
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-db"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.passwordSecretRef.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-db-password"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.writeConnectionSecretToRef.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-db-conn"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.database.sizeGB
                toFieldPath: spec.forProvider.allocatedStorage
              - type: FromCompositeFieldPath
                fromFieldPath: spec.database.engineVersion
                toFieldPath: spec.forProvider.engineVersion
              - type: FromCompositeFieldPath
                fromFieldPath: spec.team
                toFieldPath: spec.forProvider.tags[team]
              # Tier drives instance class and backup retention.
              - type: FromCompositeFieldPath
                fromFieldPath: spec.tier
                toFieldPath: spec.forProvider.instanceClass
                transforms:
                  - type: map
                    map:
                      experimental: db.t4g.micro
                      standard: db.t4g.medium
                      critical: db.r6g.large
              - type: FromCompositeFieldPath
                fromFieldPath: spec.tier
                toFieldPath: spec.forProvider.backupRetentionPeriod
                transforms:
                  - type: map
                    map:
                      experimental: "1"
                      standard: "7"
                      critical: "35"
                  - type: convert
                    convert:
                      toType: int64
              - type: ToCompositeFieldPath
                fromFieldPath: status.atProvider.address
                toFieldPath: status.databaseEndpoint
            # Render this resource only when the user asked for a database.
            readinessChecks:
              - type: MatchCondition
                matchCondition:
                  type: Ready
                  status: "True"

          # ---------- 4. GitOps Application (Argo CD) ----------
          - name: argocd-application
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: argoproj.io/v1alpha1
                    kind: Application
                    metadata:
                      name: placeholder
                      namespace: argocd
                      finalizers:
                        - resources-finalizer.argocd.argoproj.io
                    spec:
                      project: stream-aligned
                      source:
                        repoURL: placeholder
                        targetRevision: main
                        path: deploy
                      destination:
                        server: https://kubernetes.default.svc
                        namespace: placeholder
                      syncPolicy:
                        automated:
                          prune: true
                          selfHeal: true
                        syncOptions:
                          - CreateNamespace=false
                          - ServerSideApply=true
                        retry:
                          limit: 5
                          backoff:
                            duration: 10s
                            factor: 2
                            maxDuration: 5m
                providerConfigRef:
                  name: kubernetes-default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-argoapp"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.manifest.spec.destination.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.repository
                toFieldPath: spec.forProvider.manifest.spec.source.repoURL
              - type: ToCompositeFieldPath
                fromFieldPath: spec.forProvider.manifest.metadata.name
                toFieldPath: status.argoApplication

          # ---------- 5. Public exposure: certificate + ingress ----------
          - name: certificate
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: cert-manager.io/v1
                    kind: Certificate
                    metadata:
                      name: tls
                      namespace: placeholder
                    spec:
                      secretName: tls-cert
                      issuerRef:
                        name: letsencrypt-prod
                        kind: ClusterIssuer
                      dnsNames:
                        - placeholder
                providerConfigRef:
                  name: kubernetes-default
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-cert"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.name
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.exposure.hostname
                toFieldPath: spec.forProvider.manifest.spec.dnsNames[0]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.exposure.hostname
                toFieldPath: status.url
                policy:
                  fromFieldPath: Optional
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "https://%s"
```

### 4.4 El claim: la superficie que ve el usuario

`services/checkout-api/service.yaml`

```yaml
apiVersion: platform.acme.io/v1alpha1
kind: Service
metadata:
  name: checkout-api
  namespace: team-payments
spec:
  name: checkout-api
  team: payments
  tier: critical
  repository: https://github.com/acme/checkout-api
  database:
    enabled: true
    sizeGB: 100
    engineVersion: "16"
  exposure:
    public: true
    hostname: checkout.acme.io
```

Diecisiete líneas. Sin VPC, sin security groups, sin subnet groups, sin `ClusterIssuer`, sin sintaxis de Argo CD, sin `PodSecurity`, sin política de backup. Todo eso existe, está aplicado y es auditable — pero no forma parte de la carga cognitiva del equipo de payments. **Ese delta es la plataforma.**

### 4.5 Los guardrails: policy-as-code (Kyverno)

`platform/policies/guardrails.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-guardrails
  annotations:
    policies.kyverno.io/title: Non-negotiable platform guardrails
    policies.kyverno.io/category: Platform Engineering
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >
      Applies to every workload regardless of whether it came through the
      golden path. The golden path already satisfies these rules by
      construction; off-road workloads must satisfy them explicitly.
spec:
  validationFailureAction: Enforce
  background: true
  rules:

    - name: require-signed-images
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  platform.acme.io/managed: "true"
      validate:
        message: >-
          Images must come from the internal registry. Public images require
          promotion through the platform mirror. See go/acme-registry
        pattern:
          spec:
            containers:
              - image: "registry.acme.io/*"

    - name: require-ownership-labels
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - CronJob
      validate:
        message: >-
          Every workload must declare its owning team via the label
          platform.acme.io/team. Unowned workloads cannot be paged for.
        pattern:
          metadata:
            labels:
              platform.acme.io/team: "?*"

    - name: require-resource-limits
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - crossplane-system
      validate:
        message: "CPU requests and memory limits are mandatory."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                  limits:
                    memory: "?*"

    # The escape hatch: explicit, time-bound, auditable, and it emits a metric.
    - name: audit-golden-path-exceptions
      match:
        any:
          - resources:
              kinds:
                - Deployment
      preconditions:
        all:
          - key: "{{ request.object.metadata.annotations.\"platform.acme.io/exception\" || '' }}"
            operator: NotEquals
            value: ""
      validate:
        message: >-
          An exception annotation must reference a tracking issue in the form
          PLAT-<number> and include an expiry date in
          platform.acme.io/exception-expires (RFC3339).
        pattern:
          metadata:
            annotations:
              platform.acme.io/exception: "PLAT-*"
              platform.acme.io/exception-expires: "?*"
---
# Report-only policy: measures golden path coverage without blocking anyone.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: measure-golden-path-coverage
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: workload-should-be-golden-path
      match:
        any:
          - resources:
              kinds:
                - Deployment
      validate:
        message: "Workload not provisioned through the golden path."
        pattern:
          metadata:
            labels:
              platform.acme.io/golden-path: "?*"
```

### 4.6 La medición: PrometheusRule con DORA y métricas de adopción

`platform/observability/platform-metrics.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-objectives
  namespace: observability
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:

    - name: dora.rules
      interval: 5m
      rules:
        - record: dora:deployment_frequency:rate1d
          expr: |
            sum by (team, environment) (
              rate(argocd_app_sync_total{phase="Succeeded", environment="prod"}[1d])
            ) * 86400

        - record: dora:lead_time_for_changes:p50
          expr: |
            histogram_quantile(0.50,
              sum by (le, team) (
                rate(platform_commit_to_prod_duration_seconds_bucket[7d])
              )
            )

        - record: dora:change_failure_rate:ratio7d
          expr: |
            sum by (team) (increase(platform_deploy_outcome_total{outcome="failed"}[7d]))
            /
            clamp_min(
              sum by (team) (increase(platform_deploy_outcome_total[7d])), 1
            )

        - record: dora:failed_deployment_recovery_time:p95
          expr: |
            histogram_quantile(0.95,
              sum by (le, team) (
                rate(platform_deploy_recovery_duration_seconds_bucket[30d])
              )
            )

    - name: platform.adoption.rules
      interval: 5m
      rules:
        # KR 1.1 — adoption rate
        - record: platform:adoption_rate:ratio
          expr: |
            count(kube_deployment_labels{label_platform_acme_io_golden_path!=""})
            /
            clamp_min(count(kube_deployment_labels), 1)

        # Escape hatch rate — must stay low and non-increasing
        - record: platform:escape_hatch_rate:ratio
          expr: |
            count(kube_deployment_annotations{annotation_platform_acme_io_exception!=""})
            /
            clamp_min(count(kube_deployment_labels), 1)

        # KR 2.1 — self-service ratio
        - record: platform:self_service_ratio:ratio7d
          expr: |
            1 - (
              sum(increase(platform_manual_intervention_total[7d]))
              /
              clamp_min(sum(increase(platform_operation_total[7d])), 1)
            )

        # KR 1.2 — provisioning latency
        - record: platform:provision_duration:p95
          expr: |
            histogram_quantile(0.95,
              sum by (le) (rate(platform_service_provision_duration_seconds_bucket[28d]))
            )

    - name: platform.objectives.alerts
      rules:
        - alert: PlatformProvisioningSLOBurn
          expr: |
            (
              1 - (
                sum(increase(platform_service_provision_duration_seconds_bucket{le="900"}[1h]))
                / clamp_min(sum(increase(platform_service_provision_duration_seconds_count[1h])), 1)
              )
            ) > (14.4 * 0.05)
          for: 5m
          labels:
            severity: page
            slo: golden-path-provision-latency
          annotations:
            summary: "Golden path provisioning is burning its error budget 14.4x too fast"
            description: >
              KR 1.2 (p95 provisioning < 900s at 95%) is at risk. At the current
              burn rate the 28-day budget is exhausted in under 2 days.
            runbook_url: "https://runbooks.acme.io/platform/provisioning-slow"

        - alert: PlatformAdoptionStalled
          expr: |
            delta(platform:adoption_rate:ratio[30d]) < 0.02
            and platform:adoption_rate:ratio < 0.6
          for: 24h
          labels:
            severity: ticket
            objective: "OBJ-1"
          annotations:
            summary: "Adoption below 60% and flat over 30 days"
            description: >
              The product is not being pulled by users. This is a product
              discovery problem, not an engineering one. Do not respond by
              adding features; interview non-adopting teams first.

        - alert: PlatformRegressingToTicketOps
          expr: platform:self_service_ratio:ratio7d < 0.90
          for: 6h
          labels:
            severity: ticket
            objective: "OBJ-2"
          annotations:
            summary: "More than 10% of platform operations required a human"
            description: >
              KR 2.1 violated. Identify which operation types are driving
              manual intervention and convert them into capabilities.

        - alert: EscapeHatchRateGrowing
          expr: |
            platform:escape_hatch_rate:ratio > 0.10
            and delta(platform:escape_hatch_rate:ratio[14d]) > 0
          for: 12h
          labels:
            severity: ticket
          annotations:
            summary: "Escape hatch usage above 10% and rising"
            description: >
              The paved road does not cover real use cases. Each exception is a
              backlog item, not a policy violation to punish.
```

### 4.7 El delivery de la propia plataforma: ApplicationSet

`platform/gitops/platform-components.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-components
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  platform.acme.io/tier: "managed"
          - list:
              elements:
                - component: crossplane
                  path: platform/components/crossplane
                  wave: "0"
                - component: cert-manager
                  path: platform/components/cert-manager
                  wave: "0"
                - component: external-secrets
                  path: platform/components/external-secrets
                  wave: "0"
                - component: kyverno
                  path: platform/components/kyverno
                  wave: "1"
                - component: platform-apis
                  path: platform/apis
                  wave: "2"
                - component: platform-policies
                  path: platform/policies
                  wave: "3"
                - component: platform-observability
                  path: platform/observability
                  wave: "3"
  template:
    metadata:
      name: '{{.name}}-{{.component}}'
      annotations:
        argocd.argoproj.io/sync-wave: '{{.wave}}'
      labels:
        platform.acme.io/component: '{{.component}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform
        targetRevision: main
        path: '{{.path}}'
      destination:
        server: '{{.server}}'
        namespace: platform-system
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 10
          backoff:
            duration: 15s
            factor: 2
            maxDuration: 10m
  templatePatch: |
    {{- if eq .component "platform-policies" }}
    spec:
      ignoreDifferences:
        - group: kyverno.io
          kind: ClusterPolicy
          jsonPointers:
            - /spec/rules/0/generate/synchronize
    {{- end }}
```

### 4.8 Infraestructura base: OpenTofu para el management cluster

`infra/platform-baseline/main.tf`

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {
    bucket         = "acme-platform-tfstate"
    key            = "platform-baseline/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "acme-platform-tflock"
    encrypt        = true
  }
}

locals {
  cluster_name = "acme-platform-mgmt"
  common_tags = {
    "platform.acme.io/managed" = "true"
    "platform.acme.io/owner"   = "platform-team"
    "platform.acme.io/purpose" = "control-plane"
  }
}

# IRSA role consumed by the Crossplane AWS provider ServiceAccount.
# The platform control plane is the ONLY principal allowed to create
# stream-aligned team infrastructure; teams never hold cloud credentials.
data "aws_iam_policy_document" "crossplane_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:crossplane-system:provider-aws"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crossplane" {
  name               = "${local.cluster_name}-crossplane"
  assume_role_policy = data.aws_iam_policy_document.crossplane_assume.json
  tags               = local.common_tags
}

# Scoped to what the golden path actually provisions. Not AdministratorAccess.
data "aws_iam_policy_document" "crossplane_permissions" {
  statement {
    sid    = "ManageGoldenPathDatabases"
    effect = "Allow"
    actions = [
      "rds:CreateDBInstance",
      "rds:DeleteDBInstance",
      "rds:DescribeDBInstances",
      "rds:ModifyDBInstance",
      "rds:AddTagsToResource",
      "rds:ListTagsForResource",
      "rds:CreateDBSubnetGroup",
      "rds:DescribeDBSubnetGroups",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/golden-path"
      values   = ["http-service"]
    }
  }

  statement {
    sid       = "ReadNetworking"
    effect    = "Allow"
    actions   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DenyProductionDataDeletion"
    effect    = "Deny"
    actions   = ["rds:DeleteDBInstance"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/platform.acme.io/tier"
      values   = ["critical"]
    }
  }
}

resource "aws_iam_policy" "crossplane" {
  name   = "${local.cluster_name}-crossplane"
  policy = data.aws_iam_policy_document.crossplane_permissions.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane" {
  role       = aws_iam_role.crossplane.name
  policy_arn = aws_iam_policy.crossplane.arn
}

output "crossplane_role_arn" {
  description = "Annotate the provider-aws ServiceAccount with this ARN."
  value       = aws_iam_role.crossplane.arn
}
```

---

## 5. Comandos CLI y salidas reales

### 5.1 Verificar que la interfaz existe y está servida

```
$ kubectl get xrd
NAME                            ESTABLISHED   OFFERED   AGE
xservices.platform.acme.io      True          True      41d

$ kubectl get crd | grep platform.acme.io
services.platform.acme.io        2025-06-24T09:12:03Z
xservices.platform.acme.io       2025-06-24T09:12:03Z

$ kubectl get composition
NAME                       XR-KIND    XR-APIVERSION                     AGE
xservice-aws-standard      XService   platform.acme.io/v1alpha1         41d
xservice-gcp-standard      XService   platform.acme.io/v1alpha1         18d
```

`ESTABLISHED=True` significa que la CRD del composite existe; `OFFERED=True`, que la CRD del claim (la cara de usuario) también. **Si `OFFERED` es `False`, el usuario no puede crear nada aunque el XRD exista.**

### 5.2 Descubrimiento desde el punto de vista del usuario

```
$ kubectl explain service.spec --api-version=platform.acme.io/v1alpha1
GROUP:      platform.acme.io
KIND:       Service
VERSION:    v1alpha1

FIELD: spec <Object>

FIELDS:
  database      <Object> -required-
    Optional managed PostgreSQL instance.
  exposure      <Object>
  name          <string> -required-
    Logical service name; becomes the namespace and DNS label.
  repository    <string> -required-
    Git repository URL that holds the service manifests.
  team          <string> -required-
    Owning stream-aligned team; must exist in the org catalog.
  tier          <string>
    Criticality tier. Drives replica count, PDB, backup retention and on-call
    routing. This is the ONLY capacity knob exposed.
```

La documentación de la plataforma vive en el schema, no en una wiki. Esto es *discoverability* y es un atributo de plataforma exigido por el white paper de CNCF.

### 5.3 Provisioning end-to-end, cronometrado

```
$ time kubectl apply -f services/checkout-api/service.yaml
service.platform.acme.io/checkout-api created

real    0m0.412s

$ kubectl get service.platform.acme.io -n team-payments -w
NAME           TEAM       TIER       URL   READY   AGE
checkout-api   payments   critical         False   3s
checkout-api   payments   critical         False   47s
checkout-api   payments   critical         False   4m12s
checkout-api   payments   critical   https://checkout.acme.io   True    9m38s
```

Nueve minutos y treinta y ocho segundos, sin intervención humana. Comparar contra los 34 días del baseline del §1.1. **Ese delta es el objective, medido.**

### 5.4 Trazar la composición (diagnóstico de primera línea)

```
$ crossplane beta trace service checkout-api -n team-payments
NAME                                    SYNCED   READY   STATUS
Service/checkout-api (team-payments)    True     True    Available
└─ XService/checkout-api-7fk2m          True     True    Available
   ├─ Object/checkout-api-namespace     True     True    Available
   ├─ Object/checkout-api-netpol        True     True    Available
   ├─ Instance/checkout-api-db          True     True    Available
   ├─ Object/checkout-api-argoapp       True     True    Available
   └─ Object/checkout-api-cert          True     True    Available
```

### 5.5 Consultar los key results

```
$ promtool query instant http://prometheus.observability:9090 \
    'platform:adoption_rate:ratio'
platform:adoption_rate:ratio => 0.847 @[1754481600]

$ promtool query instant http://prometheus.observability:9090 \
    'platform:provision_duration:p95'
platform:provision_duration:p95 => 638.4 @[1754481600]

$ promtool query instant http://prometheus.observability:9090 \
    'platform:self_service_ratio:ratio7d'
platform:self_service_ratio:ratio7d => 0.968 @[1754481600]

$ promtool query instant http://prometheus.observability:9090 \
    'platform:escape_hatch_rate:ratio'
platform:escape_hatch_rate:ratio => 0.061 @[1754481600]

$ promtool query instant http://prometheus.observability:9090 \
    'topk(5, dora:lead_time_for_changes:p50)'
dora:lead_time_for_changes:p50{team="legacy-billing"} => 259200 @[1754481600]
dora:lead_time_for_changes:p50{team="risk"}           => 86400 @[1754481600]
dora:lead_time_for_changes:p50{team="payments"}       => 3420 @[1754481600]
dora:lead_time_for_changes:p50{team="catalog"}        => 2880 @[1754481600]
dora:lead_time_for_changes:p50{team="search"}         => 2640 @[1754481600]
```

Lectura: `payments`, `catalog` y `search` están on-platform (lead time en el orden de la hora). `legacy-billing` está en 3 días y `risk` en 1 día: son los off-platform. **La comparación de cohortes es la evidencia de atribución**, no el número absoluto.

### 5.6 Medir cobertura del golden path con el reporte de Kyverno

```
$ kubectl get policyreport -A \
    -o jsonpath='{range .items[*]}{.summary.fail}{"\n"}{end}' \
  | awk '{s+=$1} END {print "workloads off golden path:", s}'
workloads off golden path: 47

$ kubectl get policyreport -A -o json \
  | jq -r '.items[].results[]
           | select(.policy=="measure-golden-path-coverage" and .result=="fail")
           | .resources[0].namespace' \
  | sort | uniq -c | sort -rn | head -5
     19 legacy-billing
     11 risk
      8 data-eng
      6 ml-inference
      3 ops-tools
```

Esto identifica **dónde** está la brecha de adopción. `data-eng` y `ml-inference` no son "equipos rebeldes": son casos de uso que el golden path de HTTP service no cubre. La respuesta correcta es un segundo golden path (batch/stream processing), no una política más estricta.

### 5.7 Validar guardrails antes del merge (shift-left)

```
$ kyverno apply platform/policies/guardrails.yaml \
    --resource services/checkout-api/deploy/ \
    --policy-report

Applying 4 policy rule(s) to 3 resource(s)...

policy platform-guardrails -> resource team-payments/Deployment/checkout-api passed
policy platform-guardrails -> resource team-payments/Deployment/checkout-worker failed:
  1. require-ownership-labels: validation error: Every workload must declare its
     owning team via the label platform.acme.io/team. Unowned workloads cannot be
     paged for. rule require-ownership-labels failed at path /metadata/labels/

pass: 5, fail: 1, warn: 0, error: 0, skip: 2
```

```
$ echo $?
1
```

Exit code 1: el pipeline de CI falla antes del merge. El feedback llega en segundos, no en el admission webhook de producción.

### 5.8 Estado del delivery de la plataforma

```
$ argocd app list -l platform.acme.io/component --output wide
NAME                             CLUSTER         NAMESPACE        PROJECT   STATUS   HEALTH   SYNCPOLICY
mgmt-crossplane                  in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-cert-manager                in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-external-secrets            in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-kyverno                     in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-platform-apis               in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-platform-policies           in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
mgmt-platform-observability      in-cluster      platform-system  platform  Synced   Healthy  Auto-Prune
prod-eu-crossplane               prod-eu-west-1  platform-system  platform  Synced   Healthy  Auto-Prune
prod-eu-kyverno                  prod-eu-west-1  platform-system  platform  OutOfSync Healthy Auto-Prune
```

### 5.9 La API HTTP de la plataforma (interfaz alternativa)

```
$ curl -sS -H "Authorization: Bearer $(acme auth token)" \
    https://api.platform.acme.io/v1/services/checkout-api | jq
{
  "name": "checkout-api",
  "team": "payments",
  "tier": "critical",
  "ready": true,
  "url": "https://checkout.acme.io",
  "namespace": "checkout-api",
  "database": {
    "engine": "postgres",
    "version": "16",
    "endpoint": "checkout-api-db.cq7x.eu-west-1.rds.amazonaws.com",
    "backupRetentionDays": 35
  },
  "gitops": {
    "application": "checkout-api",
    "syncStatus": "Synced",
    "lastSync": "2025-08-06T11:42:17Z"
  },
  "provisionedAt": "2025-06-27T08:31:55Z",
  "goldenPath": "http-service@v1alpha1"
}
```

**Punto de examen:** una plataforma madura (Interfaces nivel 3–4 del maturity model) ofrece **múltiples interfaces sobre la misma API**: `kubectl` para quien vive en Kubernetes, HTTP/CLI para quien no, GitOps para el flujo de cambio auditado, y un portal para descubrimiento. Lo que **no** varía es el modelo de recursos subyacente. Si cada interfaz tiene su propia lógica, hay N plataformas divergentes.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Health check de la plataforma como producto

```bash
#!/usr/bin/env bash
# platform-health.sh — verifies the platform against its stated objectives.
set -euo pipefail

PROM="${PROM:-http://prometheus.observability:9090}"

q() { promtool query instant "$PROM" "$1" 2>/dev/null | awk -F'=> ' '{print $2}' | awk '{print $1}'; }

check() { # name value operator threshold
  local name="$1" val="$2" op="$3" thr="$4"
  if awk -v v="$val" -v t="$thr" "BEGIN{exit !(v $op t)}"; then
    printf "  [ OK ] %-32s %s (%s %s)\n" "$name" "$val" "$op" "$thr"
  else
    printf "  [FAIL] %-32s %s (expected %s %s)\n" "$name" "$val" "$op" "$thr"
    FAILED=1
  fi
}

FAILED=0
echo "== Interface availability =="
kubectl get xrd xservices.platform.acme.io \
  -o jsonpath='{.status.conditions[?(@.type=="Offered")].status}' | grep -q True \
  && echo "  [ OK ] XRD offered to users" || { echo "  [FAIL] XRD not offered"; FAILED=1; }

echo "== Objectives =="
check "adoption_rate"        "$(q 'platform:adoption_rate:ratio')"        ">=" 0.80
check "self_service_ratio"   "$(q 'platform:self_service_ratio:ratio7d')" ">=" 0.95
check "provision_p95_secs"   "$(q 'platform:provision_duration:p95')"     "<=" 900
check "escape_hatch_rate"    "$(q 'platform:escape_hatch_rate:ratio')"    "<=" 0.10

echo "== Guardrails =="
kubectl get clusterpolicy platform-guardrails \
  -o jsonpath='{.spec.validationFailureAction}' | grep -qi enforce \
  && echo "  [ OK ] guardrails enforcing" || { echo "  [FAIL] guardrails not enforcing"; FAILED=1; }

exit "$FAILED"
```

```
$ ./platform-health.sh
== Interface availability ==
  [ OK ] XRD offered to users
== Objectives ==
  [ OK ] adoption_rate                    0.847 (>= 0.80)
  [ OK ] self_service_ratio               0.968 (>= 0.95)
  [ OK ] provision_p95_secs               638.4 (<= 900)
  [ OK ] escape_hatch_rate                0.061 (<= 0.10)
== Guardrails ==
  [ OK ] guardrails enforcing

$ echo $?
0
```

### 6.2 Matriz de diagnóstico: síntoma → causa raíz → acción

| Síntoma observable | Hipótesis dominante | Comando de confirmación | Acción correcta | Acción **incorrecta** (trampa) |
|---|---|---|---|---|
| `adoption_rate` plana < 60% a 6 meses | El producto no resuelve un dolor priorizado por los usuarios | `kubectl get policyreport -A -o json \| jq -r '...' \| sort \| uniq -c` para ver qué namespaces están afuera | Entrevistar a 5 equipos no adoptantes; construir la capability faltante | Emitir un mandato; agregar features que nadie pidió |
| `self_service_ratio` cae de 0.97 a 0.82 | Regresión a ticket-ops: alguna operación volvió a requerir humano | `sum by (operation) (increase(platform_manual_intervention_total[7d]))` | Automatizar el path de aprobación con policy-as-code | Contratar más gente para el platform team |
| `escape_hatch_rate` sube sostenidamente | El paved road no cubre casos de uso reales | `kubectl get deploy -A -o json \| jq -r '...annotations["platform.acme.io/exception"]' \| sort \| uniq -c` | Cada excepción → ítem de backlog; considerar un segundo golden path | Cerrar la escotilla por decreto (produce shadow platforms) |
| `provision_p95` sube de 640s a 2400s | Degradación en el control plane o en el provider cloud | `crossplane beta trace` + `kubectl -n crossplane-system logs deploy/provider-aws --tail=200` | Aislar la etapa lenta; agregar timeout y retry a la composition | Aumentar el umbral del SLO para que deje de alertar |
| Claims quedan `Ready: False` sin mensaje útil | Abstracción con fuga: el error del recurso subyacente no se propaga | `kubectl describe xservice <name>` y comparar con `kubectl describe instance <name>-db` | Añadir `ToCompositeFieldPath` de `status.conditions`; mejorar los mensajes | Decirle al usuario "mirá los logs de Crossplane" |
| DORA mejora pero eNPS de plataforma baja | La velocidad se logró a costa de autonomía percibida | Encuesta SPACE (dimensión S) + entrevistas | Revisar dónde la abstracción es una jaula; ampliar la escotilla | Ignorarlo porque "las métricas duras están bien" |
| Interfaces nivel 4, Measurement nivel 1 | Plataforma construida por entusiasmo técnico sin product management | Autoevaluación con el CNCF Maturity Model | Instrumentar antes de construir más | Agregar plugins al portal |

### 6.3 Diagnóstico profundo de un claim atascado

```
$ kubectl get service.platform.acme.io -n team-risk fraud-scoring
NAME            TEAM   TIER       URL   READY   AGE
fraud-scoring   risk   critical         False   23m

$ kubectl describe service.platform.acme.io -n team-risk fraud-scoring | tail -18
Status:
  Conditions:
    Last Transition Time:  2025-08-06T11:04:12Z
    Reason:                Composing resources
    Status:                False
    Type:                  Ready
    Last Transition Time:  2025-08-06T11:04:09Z
    Reason:                ReconcileSuccess
    Status:                True
    Type:                  Synced
Events:
  Type     Reason                   Age                 From                Message
  ----     ------                   ----                ----                -------
  Normal   ConfigureCompositeResource  23m              defined/claim       Successfully composed resources
  Warning  ComposeResources            2m (x14 over 23m) rbac/compositeresourcedefinition
           cannot compose resources: pipeline step "render-resources": cannot render
           composed resource "database": observed composed resource is not ready
```

```
$ crossplane beta trace service fraud-scoring -n team-risk
NAME                                     SYNCED   READY   STATUS
Service/fraud-scoring (team-risk)        True     False   Waiting: ...
└─ XService/fraud-scoring-x9v2p          True     False   Creating: ...
   ├─ Object/fraud-scoring-namespace     True     True    Available
   ├─ Object/fraud-scoring-netpol        True     True    Available
   ├─ Instance/fraud-scoring-db          False    False   ReconcileError: ...
   ├─ Object/fraud-scoring-argoapp       True     True    Available
   └─ Object/fraud-scoring-cert          True     False   Creating: ...

$ kubectl describe instance fraud-scoring-db | grep -A6 "Conditions:"
Conditions:
  Type:     Synced
  Status:   False
  Reason:   ReconcileError
  Message:  async create failed: InvalidParameterCombination: Cannot find version
            16 for postgres. Valid versions in eu-west-1: 15.5, 15.6, 16.1, 16.2
```

**Causa raíz:** el `enum` del XRD acepta `"16"`, pero el provider de AWS exige una versión menor explícita. La abstracción tiene fuga: el error del sistema subyacente no es interpretable por el usuario.

Corrección en la Composition — mapear el valor de alto nivel a la versión concreta soportada, y propagar el error hacia arriba:

```yaml
              - type: FromCompositeFieldPath
                fromFieldPath: spec.database.engineVersion
                toFieldPath: spec.forProvider.engineVersion
                transforms:
                  - type: map
                    map:
                      "15": "15.6"
                      "16": "16.2"
```

Y en el XRD, exponer el error para que sea legible desde el claim:

```yaml
            status:
              type: object
              properties:
                databaseError:
                  type: string
                  description: >
                    Human-readable reason the database could not be provisioned.
                    Surfaced so the user never needs to inspect provider logs.
```

Con el `ToCompositeFieldPath` correspondiente:

```yaml
              - type: ToCompositeFieldPath
                fromFieldPath: status.conditions[0].message
                toFieldPath: status.databaseError
                policy:
                  fromFieldPath: Optional
```

**Principio estratégico que esto ilustra:** una abstracción de plataforma tiene la obligación de propagar el estado y los errores del sistema que oculta. Ocultar la complejidad en el camino feliz y exponerla cruda en el fallo **duplica** la carga cognitiva en vez de reducirla — el usuario ahora debe entender la abstracción *y* la implementación.

### 6.4 Verificación del modelo de adopción (¿el mandato está enmascarando fracaso?)

```
$ kubectl get deploy -A -o json | jq -r '
    .items[]
    | select(.metadata.labels["platform.acme.io/golden-path"] != null)
    | select(.metadata.annotations["platform.acme.io/exception"] != null)
    | .metadata.namespace' | sort | uniq -c | sort -rn
     14 ml-inference
      9 data-eng
      2 risk
```

Veinticinco workloads que están *nominalmente* en el golden path pero llevan una excepción. Adoption rate reporta 84.7%; la adopción **efectiva** es menor. Esta es la firma de un mandato: los equipos cumplen la letra (la label) y evaden el espíritu (la excepción). Si la adopción fuese por pull, no habría incentivo para poner la label sin usar el camino.

Corrección de la métrica:

```yaml
        - record: platform:effective_adoption_rate:ratio
          expr: |
            (
              count(kube_deployment_labels{label_platform_acme_io_golden_path!=""})
              -
              count(kube_deployment_annotations{annotation_platform_acme_io_exception!=""})
            )
            / clamp_min(count(kube_deployment_labels), 1)
```

```
$ promtool query instant http://prometheus.observability:9090 \
    'platform:effective_adoption_rate:ratio'
platform:effective_adoption_rate:ratio => 0.712 @[1754481600]
```

71.2%, no 84.7%. **Medir mal es peor que no medir**, porque produce confianza injustificada en la estrategia.

---

## 7. Puntos de recuerdo rápido para el examen

1. **Goal ≠ objective ≠ key result.** El goal es direccional y sin número; el objective es medible y acotado en el tiempo; el key result es el SLI con umbral.
2. El objetivo primario de platform engineering es **reducir la carga cognitiva extraneous**, no estandarizar ni ahorrar costos.
3. Los cuatro atributos CNCF de una plataforma: **curada, integrada, autoservicio, gestionada como producto**.
4. **Paved road = opt-in. Guardrails = obligatorios.** Son planos distintos y no deben mezclarse.
5. El **escape hatch** es un requisito de diseño, y su tasa de uso es una métrica de producto, no una infracción.
6. **DORA mide el sistema de delivery; SPACE agrega la dimensión humana; las métricas de plataforma miden el producto.** La atribución se hace por comparación de cohortes on/off-platform.
7. **Maturity Model CNCF:** aspects = Investment, Adoption, Interfaces, Operations, Measurement. Levels = Provisional, Operational, Scalable, Optimizing. Se usa para detectar **desbalances**, no para llegar a 4 en todo.
8. **Assemble** es el enfoque por defecto; build solo la capa de interfaz y composición.
9. **Thinnest Viable Platform:** empezar con lo mínimo que resuelva un dolor real y crecer bajo demanda demostrada.
10. Un mandato produce 100% de uso y **cero** información sobre valor. La adopción voluntaria es el único test honesto del producto.
11. Una abstracción debe propagar el estado y los errores de lo que oculta; si no, duplica la carga cognitiva en el fallo.
12. Interaction mode del platform team con stream-aligned teams: **X-as-a-Service** en estado estacionario; *collaboration* solo con fecha de expiración.

---

## 8. Referencias

**Currículum oficial de la certificación**
- CNPA Curriculum (PDF oficial, CNCF) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Repositorio de currículos CNCF — https://github.com/cncf/curriculum
- Cloud Native Platform Engineering Associate (CNPA), página del programa — https://www.cncf.io/training/certification/cnpa/

**Documentos fundacionales de CNCF**
- CNCF Platforms White Paper — *Platforms for Cloud Native Computing* — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNCF Platforms Working Group (portal) — https://platforms.cncf.io/
- CNCF App Delivery TAG — https://tag-app-delivery.cncf.io/

**Marcos de medición**
- DORA — *State of DevOps Report* y definiciones de las cuatro métricas clave — https://dora.dev/
- DORA Core Model (capabilities y outcomes) — https://dora.dev/research/
- SPACE Framework — Forsgren, Storey, Maddila, Zimmermann, Houck, Butler, *The SPACE of Developer Productivity*, ACM Queue — https://queue.acm.org/detail.cfm?id=3454124
- Google SRE Workbook — *Implementing SLOs* — https://sre.google/workbook/implementing-slos/
- Google SRE Workbook — *Alerting on SLOs* (multiwindow multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/

**Modelos organizativos**
- Team Topologies — https://teamtopologies.com/
- Team Topologies — Interaction modes y Thinnest Viable Platform — https://teamtopologies.com/key-concepts

**Proyectos citados en los manifiestos**
- Crossplane — Composite Resource Definitions — https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane — Compositions y composition functions — https://docs.crossplane.io/latest/concepts/compositions/
- Argo CD — ApplicationSet Controller — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD — Sync waves y sync phases — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- Kyverno — Writing policies (validate rules) — https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Policy Reports — https://kyverno.io/docs/policy-reports/
- OpenSLO — especificación v1 — https://github.com/OpenSLO/OpenSLO
- Prometheus — Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus Operator — PrometheusRule CRD — https://prometheus-operator.dev/docs/api-reference/api/
- kube-state-metrics — métricas de labels y annotations — https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/deployment-metrics.md
- Kubernetes — Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Backstage — Software Templates (scaffolder) — https://backstage.io/docs/features/software-templates/
- cert-manager — Certificate resource — https://cert-manager.io/docs/usage/certificate/
- CNOE (Cloud Native Operational Excellence) — https://cnoe.io/