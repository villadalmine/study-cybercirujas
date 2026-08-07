# CNCF / LPI 701-100 (v1.0) Tema 5.1: Operaciones de TI y Monitoreo - Guía de Estudio de Nivel de Producción y Laboratorios Prácticos

## 1. Referencias Oficiales e Inmersión Profunda en la Arquitectura Técnica

* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Prometheus Official Architecture & Documentation**: [https://prometheus.io/docs/introduction/overview/](https://prometheus.io/docs/introduction/overview/)
* **Google SRE Book - Service Level Objectives**: [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
* **Prometheus Alerting & Alertmanager Specification**: [https://prometheus.io/docs/alerting/latest/overview/](https://prometheus.io/docs/alerting/latest/overview/)

---

### Principios Fundamentales de SRE y Observabilidad

Las operaciones de TI modernas transicionan del monitoreo tradicional centrado en el host (ping ICMP, umbrales arbitrarios de porcentaje de CPU) a los principios de **Service Reliability Engineering (SRE)** basados en resultados de negocio y experiencia de usuario.

1. **Service Level Indicator (SLI)**: Una métrica cuantificable medida en tiempo real que refleja la calidad del servicio.
   * *Ejemplo de Fórmula*: $\text{SLI} = \frac{\text{Good Requests (Latency } < 200\text{ms y Status } \neq 5xx)}{\text{Total Valid Requests}} \times 100$
2. **Service Level Objective (SLO)**: Un valor objetivo o rango de valores para un nivel de servicio que es medido por un SLI, acordado entre los equipos de producto y SRE (por ejemplo, $99.9\%$ de respuestas HTTP exitosas durante una ventana móvil de 30 días).
3. **Service Level Agreement (SLA)**: Un contrato legal con consecuencias financieras u operativas si se incumple el SLO.
4. **Error Budget**: El margen de falla aceptable derivado del SLO ($100\% - \text{SLO}$). Para un SLO del $99.9\%$, el Error Budget es del $0.1\%$. Los despliegues se detienen cuando el Error Budget se agota.
5. **The Four Golden Signals**:
   * **Latency**: El tiempo necesario para atender una solicitud (diferenciando entre solicitudes exitosas y fallidas).
   * **Traffic**: Una medida de la demanda sobre el sistema (por ejemplo, solicitudes HTTP/sec, transacciones concurrentes).
   * **Errors**: La tasa de solicitudes que fallan (respuestas 5xx explícitas, timeouts implícitos o violaciones de políticas).
   * **Saturation**: Qué tan "lleno" está el servicio (por ejemplo, utilización de memoria, agotamiento del thread pool, profundidad de la cola).

---

### Arquitectura de Almacenamiento y Scraping de Prometheus

```
+-------------------------------------------------------------------------------+
|                               PROMETHEUS SERVER                               |
|                                                                               |
|  +--------------------+     +---------------------+     +------------------+  |
|  | Retrieval (Scraper)| --> | TSDB (Head / Disk)  | --> |  PromQL Engine   |  |
|  +--------------------+     +---------------------+     +------------------+  |
|            ^                           |                          |           |
+------------|---------------------------|--------------------------|-----------+
             | (HTTP Pull)               v (WAL / Chomp)            | (Evaluate)
             |                    +---------------+                 v
    +-----------------+           | Disk Storage  |        +-----------------+
    | Exporters /     |           | Block 2h / 2h |        |  Alertmanager   |
    | Target Endpoints|           +---------------+        +-----------------+
    +-----------------+                                             |
                                                                    v
                                                            +-----------------+
                                                            | PagerDuty / Mail|
                                                            +-----------------+
```

#### Mecánica Interna de TSDB (Time Series Database)
Prometheus utiliza una Time Series Database (TSDB) personalizada de solo anexado (append-only) almacenada en el sistema de archivos del disco local:
* **Head Block**: Búfer en memoria donde se escriben primero las métricas entrantes en bruto. Contiene un Write-Ahead Log (WAL) para la recuperación ante fallas.
* **Compresión Gorilla Float64 & Delta-of-Delta**: Las marcas de tiempo (timestamps) se almacenan utilizando compresión double-delta. Los valores de las métricas (flotantes de 64 bits) se comprimen mediante XOR contra los valores precedentes, reduciendo el footprint de memoria a ~1.37 bytes por muestra.
* **Diseño de Bloque (Block Layout)**: Cada 2 horas, los datos en memoria se compactan y se vuelcan a disco como un **Block** inmutable que contiene:
  * `chunks/`: Datos brutos comprimidos de series temporales.
  * `index`: Índice invertido que mapea etiquetas de métricas a IDs de series.
  * `meta.json`: Metadatos del bloque (tiempo mín/máx, estadísticas, nivel de compactación).
  * `tombstones`: Registros de métricas eliminadas.
* **Trade-offs de la Arquitectura Pull vs. Push**:
  * *Modelo Pull (Predeterminado en Prometheus)*: El servidor inicia solicitudes HTTP GET a los endpoints `/metrics` del objetivo. Centraliza el estado de scrape, detecta automáticamente estados caídos del objetivo (a través de la métrica `up`) y evita que los objetivos sobrecarguen los backends de monitoreo.
  * *Modelo Push (vía Pushgateway)*: Requerido para trabajos efímeros/batch de corta duración que finalizan antes de que ocurra un ciclo de scrape. *Trade-off*: Pushgateway actúa como un caché de métricas y un punto único de falla; no puede detectar automáticamente la caída de un objetivo.

---

## 2. Ejercicio 1: Desplegar y Validar un Stack de Prometheus de Nivel de Producción

### Paso 1: Definir la Configuración del Servidor Prometheus
Cree un directorio de trabajo y escriba una configuración `prometheus.yml` completa y sintácticamente válida especificando reglas de scraping dinámico de objetivos y relabeling de métricas.

Ejecutar en la terminal:
```bash
mkdir -p ~/prometheus-lab/config
cd ~/prometheus-lab
```

Escribir `~/prometheus-lab/config/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    environment: production
    datacenter: us-east-1

rule_files:
  - "alerts.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "localhost:9093"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_exporter"
    scrape_interval: 5s
    static_configs:
      - targets: ["localhost:9100"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        regex: "([^:]+):.*"
        replacement: "${1}"
      - target_label: tier
        replacement: infrastructure
```

### Paso 2: Definir Reglas de Alerta de Prometheus Sintácticamente Válidas
Cree el archivo de reglas `alerts.yml` referenciado en `prometheus.yml`.

Escribir `~/prometheus-lab/config/alerts.yml`:
```yaml
groups:
  - name: node_infrastructure_alerts
    rules:
      - alert: NodeExporterDown
        expr: up{job="node_exporter"} == 0
        for: 30s
        labels:
          severity: critical
          team: platform-sre
        annotations:
          summary: "Node Exporter instance {{ $labels.instance }} is unreachable"
          description: "Target {{ $labels.instance }} has been down for more than 30 seconds."

      - alert: HighCpuUtilization
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 2m
        labels:
          severity: warning
          team: platform-sre
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU utilization on {{ $labels.instance }} is at {{ printf \"%.2f\" $value }}%."
```

### Paso 3: Validar Configuraciones vía `promtool`
Antes de iniciar Prometheus, valide la sintaxis de sus archivos de configuración utilizando `promtool`.

Ejecutar:
```bash
promtool check config ~/prometheus-lab/config/prometheus.yml
```

Salida Esperada:
```text
Checking /home/user/prometheus-lab/config/prometheus.yml
  SUCCESS: 1 rule files found

Checking /home/user/prometheus-lab/config/alerts.yml
  SUCCESS: 2 rules found
```

Ejecutar verificación de validación unitaria de reglas:
```bash
promtool check rules ~/prometheus-lab/config/alerts.yml
```

Salida Esperada:
```text
Checking /home/user/prometheus-lab/config/alerts.yml
  SUCCESS: 2 rules found
```

### Paso 4: Ejecutar Contenedores de Node Exporter, Alertmanager y Prometheus
Ejecute el stack completo de observabilidad utilizando hooks de red de Docker/Podman.

Ejecutar:
```bash
docker network create monitoring-net

# 1. Run Node Exporter
docker run -d \
  --name node_exporter \
  --network monitoring-net \
  -p 9100:9100 \
  prom/node-exporter:v1.7.0

# 2. Run Alertmanager
docker run -d \
  --name alertmanager \
  --network monitoring-net \
  -p 9093:9093 \
  prom/alertmanager:v0.26.0

# 3. Run Prometheus Server
docker run -d \
  --name prometheus \
  --network monitoring-net \
  -p 9090:9090 \
  -v ~/prometheus-lab/config/prometheus.yml:/etc/prometheus/prometheus.yml \
  -v ~/prometheus-lab/config/alerts.yml:/etc/prometheus/alerts.yml \
  prom/prometheus:v2.48.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.enable-lifecycle
```

### Paso 5: Verificar Objetivos de Scraping vía API HTTP
Consulte la API HTTP de Prometheus para verificar que los scrapers de los objetivos estén activos y saludables.

Ejecutar:
```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .discoveredLabels.job, health: .health, lastScrape: .lastScrape}'
```

Salida Esperada:
```json
{
  "job": "prometheus",
  "health": "up",
  "lastScrape": "2026-08-07T08:30:12.145Z"
}
{
  "job": "node_exporter",
  "health": "up",
  "lastScrape": "2026-08-07T08:30:14.892Z"
}
```

---

### Preguntas de Verificación (Ejercicio 1)

1. ¿Cuál es la diferencia entre `relabel_configs` y `metric_relabel_configs` en un archivo de configuración de Prometheus?
2. Si `promtool check config` devuelve `FAILED: parsing YAML file: line 12: did not find expected key`, ¿cómo debería un operador aislar sistemáticamente el error?
3. ¿Cuál es el impacto operativo de ejecutar Prometheus con el flag `--web.enable-lifecycle` habilitado?

---

## 3. Ejercicio 2: Análisis de Métricas en PromQL, Tipos de Métricas y Cálculos de SLI/SLO en SRE

### Inmersión Profunda: Tipos de Datos de Prometheus

| Tipo | Definición | Comportamiento ante Reinicios (Reset) | Funciones PromQL |
| :--- | :--- | :--- | :--- |
| **Counter** | Contador acumulativo monótonamente creciente (solo puede subir o reiniciarse a 0 al reiniciar el servicio). | Se reinicia a 0 en caso de falla del servicio. | `rate()`, `increase()`, `irate()` |
| **Gauge** | Valor numérico único que puede subir o bajar arbitrariamente. | Representa capturas instantáneas del estado actual. | `avg_over_time()`, `max_over_time()`, `delta()` |
| **Histogram** | Muestrea observaciones (generalmente duraciones o tamaños) en buckets configurables (`_bucket{le="..."}`). También rastrea `_sum` y `_count`. | Los buckets son contadores acumulativos. | `histogram_quantile()`, `rate()` |
| **Summary** | Calcula quantiles configurables (por ejemplo, 0.95, 0.99) directamente del lado del cliente. Incluye `_sum` y `_count`. | No se puede agregar entre instancias de forma segura. | Lectura directa de quantiles, `rate()` en `_count` |

---

### Paso 1: Inspeccionar Métricas en Bruto del Exporter
Obtenga métricas en bruto directamente de Node Exporter para comprender la representación de métricas basadas en texto.

Ejecutar:
```bash
curl -s http://localhost:9100/metrics | grep -E '^node_cpu_seconds_total' | head -n 6
```

Salida Esperada:
```text
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 14820.45
node_cpu_seconds_total{cpu="0",mode="iowait"} 12.30
node_cpu_seconds_total{cpu="0",mode="irq"} 0.00
node_cpu_seconds_total{cpu="0",mode="nice"} 0.15
```

### Paso 2: Formular Consultas PromQL para Tasa y Agregación

#### 1. Calcular la Tasa por Segundo de Contadores Monótonos
`rate()` maneja automáticamente los reinicios de contadores (por ejemplo, reinicios de procesos).

Ejecutar Instant Query vía API:
```bash
curl -s -g 'http://localhost:9090/api/v1/query?query=sum(rate(node_cpu_seconds_total{mode!="idle"}[5m]))by(instance)' | jq .
```

Salida Esperada:
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "instance": "localhost"
        },
        "value": [
          1757233825.123,
          "0.14500000000000002"
        ]
      }
    ]
  }
}
```

#### 2. Calcular la Latencia del Percentil 99 a partir de Histogramas
Para calcular los percentiles de latencia a través de nodos agregados utilizando `histogram_quantile()`:

$$\text{Quantile}_{\text{p99}} = \text{histogram\_quantile}\left(0.99, \sum_{\text{le}}\left(\text{rate}\left(\text{http\_request\_duration\_seconds\_bucket}[5\text{m}]\right)\right)\right)$$

Sintaxis PromQL:
```promql
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
```

### Paso 3: Calcular el SLI/SLO de Disponibilidad de SRE en PromQL
Calcule el SLI de disponibilidad HTTP durante una ventana móvil de 30 días:

Sintaxis PromQL:
```promql
(
  sum(rate(http_requests_total{status!~"5.."}[30d]))
  /
  sum(rate(http_requests_total[30d]))
) * 100
```

Para calcular la **Tasa de Consumo del Error Budget (Burn Rate)**:
$$\text{Burn Rate} = \frac{1 - \text{SLI}_{\text{actual}}}{1 - \text{SLO}_{\text{target}}}$$

Consulta PromQL para un SLO del $99.9\%$ (tasa de error admisible de $0.001$) durante 1 hora:
```promql
(
  sum(rate(http_requests_total{status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total[1h]))
) / 0.001
```
*Nota*: Una tasa de consumo (burn rate) de $1$ significa que el servicio agotará su Error Budget en exactamente 30 días. Una tasa de consumo de $14.4$ significa que el $2\%$ del Error Budget se consume en 1 hora.

---

### Preguntas de Verificación (Ejercicio 2)

1. ¿Por qué aplicar `sum()` antes de `rate()` en una métrica de tipo Counter (por ejemplo, `rate(sum(node_cpu_seconds_total)[5m])`) es matemáticamente incorrecto en PromQL?
2. ¿Cuál es el inconveniente operativo fundamental de utilizar métricas de tipo `Summary` en comparación con las métricas de tipo `Histogram` en clusters de producción multinodo?
3. ¿En qué se diferencia `irate()` de `rate()`, y en qué escenario de monitoreo se debe evitar `irate()` para alertas a largo plazo?

---

## 4. Ejercicio 3: Pipeline de Alertas, Configuración de Alertmanager y Diagnóstico de Fallas

### Paso 1: Configurar Rutas y Receptores de Alertmanager
Cree `~/prometheus-lab/config/alertmanager.yml` para definir pipelines de agrupación, inhibición y enrutamiento.

Escribir `~/prometheus-lab/config/alertmanager.yml`:
```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  receiver: 'default-webhook'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-high-priority'
      continue: false

inhibit_rules:
  - source_match:
      alertname: 'NodeExporterDown'
    target_match:
      severity: 'warning'
    equal: ['instance']

receivers:
  - name: 'default-webhook'
    webhook_configs:
      - url: 'http://127.0.0.1:5001/webhook'
        send_resolved: true

  - name: 'pagerduty-high-priority'
    webhook_configs:
      - url: 'http://127.0.0.1:5002/pagerduty'
        send_resolved: true
```

### Paso 2: Validar la Sintaxis de Alertmanager vía `amtool`
Ejecutar la validación utilizando `amtool`:
```bash
docker exec -it alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```

Salida Esperada:
```text
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
```

### Paso 3: Simular una Falla
Simule una falla en el objetivo deteniendo el contenedor de Node Exporter para hacer la transición de `NodeExporterDown` de `Pending` a `Firing`.

Ejecutar:
```bash
docker stop node_exporter
```

Espere 35 segundos y luego verifique la API de Alertas de Prometheus:

Ejecutar:
```bash
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname: .labels.alertname, state: .state, activeAt: .activeAt}'
```

Salida Esperada:
```json
{
  "alertname": "NodeExporterDown",
  "state": "firing",
  "activeAt": "2026-08-07T08:35:10.512Z"
}
```

### Paso 4: Inspeccionar las Alertas Activas en Alertmanager
Verifique que Prometheus haya reenviado con éxito la alerta activa (firing) a Alertmanager.

Ejecutar:
```bash
docker exec -it alertmanager amtool alert --alertmanager.url=http://localhost:9093
```

Salida Esperada:
```text
Alertname         Starts At                Summary
NodeExporterDown  2026-08-07 08:35:10 UTC  Node Exporter instance localhost:9100 is unreachable
```

### Paso 5: Implementar un Silencio Operativo
Para evitar la fatiga por alertas durante un mantenimiento programado, aplique un silencio operativo utilizando `amtool`.

Ejecutar:
```bash
docker exec -it alertmanager amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --author="SRE-OnCall" \
  --comment="Scheduled maintenance window for node exporter" \
  --duration=1h \
  alertname="NodeExporterDown"
```

Salida Esperada:
```text
4a8b1c9d-8e7f-4a3b-2c1d-0e9f8a7b6c5d
```

Verificar silencios activos:
```bash
docker exec -it alertmanager amtool silence query --alertmanager.url=http://localhost:9093
```

Salida Esperada:
```text
ID                                    Matchers                  Ends At                  Created By  Comment
4a8b1c9d-8e7f-4a3b-2c1d-0e9f8a7b6c5d  alertname=NodeExporterDown 2026-08-07 09:35:10 UTC  SRE-OnCall  Scheduled maintenance window for node exporter
```

Limpiar el entorno:
```bash
docker start node_exporter
```

---

### Preguntas de Verificación (Ejercicio 3)

1. ¿Qué sucede cuando una alerta coincide con una regla de inhibición en Alertmanager?
2. ¿Cuál es el rol de `group_wait` frente a `group_interval` en los árboles de enrutamiento de Alertmanager?
3. Si el estado de una alerta es `Pending` en Prometheus, ¿Alertmanager envía notificaciones a los receptores (por ejemplo, PagerDuty)? Explique la mecánica.

---

## 5. Soluciones y Explicaciones Detalladas

<details>
<summary>Haga clic para expandir las Respuestas y Explicaciones Detalladas</summary>

### Respuestas del Ejercicio 1

1. **`relabel_configs` vs `metric_relabel_configs`**:
   * `relabel_configs` se aplica **antes** de realizar el scrape del objetivo, durante la fase de service discovery. Modifica las etiquetas de metadatos del objetivo (por ejemplo, `__address__`, `__scheme__`) para determinar *si* Prometheus debe realizar el scrape y *cómo* hacerlo.
   * `metric_relabel_configs` ocurre **después** de que se completa el scrape, pero **antes** de que las muestras se escriban en la TSDB. Permite a los operadores descartar métricas innecesarias (`action: drop`), reescribir nombres de métricas o eliminar etiquetas costosas de alta cardinalidad para ahorrar almacenamiento.

2. **Aislamiento de Fallas de Parseo YAML**:
   * Los errores de YAML suelen ser causados por sangría inválida (mezclar tabulaciones y espacios), corchetes de plantillas sin escapar (`{{ }}`), o claves de mapeo inválidas.
   * *Aislamiento Sistemático*:
     1. Ejecutar `promtool check config <path>` para obtener el número exacto de línea.
     2. Inspeccionar el archivo alrededor de esa línea utilizando `sed -n '5,15p' file.yml` o `cat -A file.yml` (para exponer los caracteres de tabulación `^I`).
     3. Verificar las comillas en escalares de bloque alrededor de expresiones PromQL o plantillas de Go (por ejemplo, `description: "Value is {{ $value }}"`).

3. **Impacto de `--web.enable-lifecycle`**:
   * Habilitar `--web.enable-lifecycle` expone endpoints administrativos HTTP (`POST /-/reload` y `POST /-/quit`).
   * Permite a los operadores o pipelines de CI/CD recargar dinámicamente las reglas y configuraciones de Prometheus sin reiniciar el proceso del contenedor (`curl -X POST http://localhost:9090/-/reload`), garantizando un tiempo de inactividad cero en el monitoreo.
   * *Riesgo de Seguridad*: Si no está autenticado, usuarios no autorizados pueden recargar configuraciones erróneas o detener Prometheus.

---

### Respuestas del Ejercicio 2

1. **Inexactitud de `sum()` antes de `rate()`**:
   * Las métricas de tipo Counter se reinician a `0` cada vez que se reinicia un proceso. La función `rate()` detecta disminuciones en el contador (por ejemplo, $100 \to 2$) e incluye implícitamente el valor previo al reinicio ($100$) para compensar el reinicio.
   * Si `sum()` se ejecuta antes de `rate()` (es decir, `rate(sum(counter)[5m])`), los reinicios de instancias individuales quedan ocultos dentro de la suma combinada. Cuando una instancia se reinicia, `sum()` cae ligeramente, lo que hace que `rate()` interprete falsamente el cambio como un único reinicio de contador en todo el conjunto agregado, corrompiendo los cálculos matemáticos.

2. **Inconveniente de las Métricas `Summary` del Lado del Cliente**:
   * Las métricas de tipo `Summary` calculan quantiles (por ejemplo, $p99$) en el cliente de la aplicación utilizando ventanas de tiempo deslizantes y emiten valores flotantes precomputados.
   * Los quantiles no se pueden agregar entre instancias. Calcular el promedio de resúmenes $p99$ a través de 10 pods ($\text{avg}(p99)$) es matemáticamente inválido y produce representaciones de latencia inexactas. Los `Histograms` exportan contadores acumulativos de buckets en bruto (`_bucket`), lo que permite a PromQL (`histogram_quantile()`) calcular con precisión percentiles a nivel de todo el cluster.

3. **Mecánica de `irate()` vs `rate()`**:
   * `rate()` calcula la tasa de crecimiento promedio por segundo a lo largo de toda la ventana de tiempo (por ejemplo, `[5m]`) comparando el primer y el último punto dentro del rango. Suaviza los picos y es ideal para reglas de alerta.
   * `irate()` (instant rate) calcula la tasa por segundo basándose estrictamente en los últimos **dos** puntos de datos dentro de la ventana del rango. Reacciona al instante a ráfagas rápidas, lo que lo hace ideal para tableros (dashboards) de alta resolución, pero es propenso a falsas alarmas si se usa en reglas de alerta debido a la volatilidad de la métrica.

---

### Respuestas del Ejercicio 3

1. **Mecánica de Inhibición de Alertmanager**:
   * La inhibición suprime las notificaciones para las alertas entrantes (target) si una alerta de origen (source) que coincide con criterios específicos ya está activa (firing).
   * *Ejemplo*: Si `NodeExporterDown` (origen) está activa para `instance="host-1"`, Alertmanager inhibe `HighCpuUtilization` (objetivo) para `instance="host-1"`. Esto evita inundaciones de notificaciones durante caídas de infraestructura.

2. **`group_wait` vs `group_interval`**:
   * `group_wait`: El retraso inicial que espera Alertmanager antes de enviar la primerísima notificación para un grupo de alertas recién creado. Esto amortigua las alertas iniciales para agrupar problemas relacionados que ocurren al mismo tiempo en un solo payload de alerta.
   * `group_interval`: El intervalo que espera Alertmanager antes de enviar notificaciones de actualización sobre nuevas alertas agregadas a un grupo activo *ya existente*.

3. **Mecánica del Estado Pending en Alertas**:
   * Una alerta en estado `Pending` ha satisfecho la expresión PromQL (`expr`), pero aún no ha alcanzado la duración requerida especificada por la cláusula `for:` (por ejemplo, `for: 2m`).
   * Durante el estado `Pending`, Prometheus rastrea la duración localmente. **Alertmanager NO recibe ni envía notificaciones** mientras la alerta está en `Pending`. Las notificaciones se enrutan a Alertmanager solo después de que la condición persista más allá de la duración especificada en `for:`, cambiando el estado a `Firing`.

</details>