# 4.3 — Understand and Use Alertmanager

> PCA Domain 4 (Observability / Alerting) · Peso del tema **4.5** · Idioma de autoría: English
> Lector objetivo: SRE / Platform Architect que opera Prometheus + Alertmanager en producción.

---

## 1. El problema de producción: por qué Prometheus por sí solo no puede alertar

Prometheus hace exactamente dos cosas de alerting y nada más:

1. **Evalúa las alerting rules** en cada intervalo del grupo de reglas. Cuando una expresión devuelve un vector no vacío durante al menos `for`, la time series correspondiente entra en `firing`.
2. **Envía** las alertas en `firing` (y resueltas), como JSON, a cada Alertmanager configurado mediante `POST /api/v2/alerts`.

Todo lo que a un humano realmente le importa — *no me pagines 500 veces por un deploy malo, no despiertes al on-call por un `warning`, callate durante la ventana de mantenimiento, pagina a PagerDuty ante un `critical` pero a Slack ante un `warning`, y avisame cuando termine* — **no** está en Prometheus. Vive en **Alertmanager**.

La razón arquitectónica de esta separación es el desacople y el fan-in:

```
                          POST /api/v2/alerts (every ~1m while firing)
 ┌────────────┐   ┌────────────┐          ┌──────────────────────────────┐
 │ Prometheus │──▶│            │          │        Alertmanager cluster    │
 │   (rules)  │   │ Prometheus │────────▶ │  am-0 ⇄ am-1 ⇄ am-2 (gossip)  │──▶ PagerDuty
 └────────────┘   │   (rules)  │────────▶ │  dedup · group · inhibit ·     │──▶ Slack
 ┌────────────┐   └────────────┘          │  silence · route · notify      │──▶ Email
 │ Prometheus │─────────────────────────▶ │                                │──▶ Webhook
 └────────────┘   many producers   →      └──────────────────────────────┘   few humans
```

Consecuencias clave que debés internalizar para el examen y para producción:

- **Prometheus no deduplica.** Envía la *misma* alerta a *todos* los Alertmanagers del cluster. La deduplicación es tarea de Alertmanager (vía el notification log propagado por gossip). Esto es deliberado: hace que el camino de alerting sea de alta disponibilidad sin necesidad de un líder.
- **Prometheus reenvía las alertas en `firing` periódicamente** (`--rules.alert.resend-delay`, por defecto `1m`) para que Alertmanager sepa que la alerta sigue activa. Cada alerta lleva un `startsAt` y un `endsAt`; si Prometheus deja de enviar, Alertmanager la auto-resuelve tras el `endsAt` (o tras `global.resolve_timeout`, por defecto `5m`, cuando falta el `endsAt`).
- **Alertmanager es stateful pero no durable.** Su estado crítico (silences + el notification log / `nflog`) vive en memoria y se propaga por gossip entre peers y se hace un snapshot periódicamente a `--storage.path`. Perder una sola instancia no pierde nada; perder todo el cluster pierde los silences y puede re-notificar.

---

## 2. El notification pipeline de Alertmanager

Una alerta entrante atraviesa dos capas: el **dispatcher** (grouping) y el **notification pipeline** por receiver (las etapas).

### 2.1 Dispatcher — routing y grouping

El **route tree** decide dos cosas para cada alerta: a qué **receiver** va, y cómo se **agrupan** las alertas (`group_by`). Las alertas que caen en el mismo route con los mismos valores para las labels de `group_by` forman un **aggregation group**, que es la unidad de una notificación.

Tres timers gobiernan la cadencia de un grupo:

| Parámetro | Por defecto | Significado | Intuición de tuning |
|---|---|---|---|
| `group_wait` | `30s` | Tiempo de buffer antes de la **primera** notificación de un grupo nuevo, para que una ráfaga se colapse en un solo mensaje. | Bajo para pages sensibles a la latencia (paginar al on-call), más alto (p. ej. `1m`) para agrupar en lotes. |
| `group_interval` | `5m` | Espera antes de enviar una **actualización** cuando *nuevas* alertas se suman a un grupo ya notificado. | Controla qué tan rápido te enterás de que un grupo está creciendo. |
| `repeat_interval` | `4h` | Re-notificar un grupo **sin cambios, aún en `firing`**. | El timer "insistente". `1h` para pages critical, `12h`+ para tickets. |

### 2.2 Etapas por receiver (en orden)

Para cada receiver, Alertmanager construye un pipeline. El orden importa y es una fuente frecuente de incidentes "por qué no me paginaron":

```
GossipSettle → Inhibit(MuteStage) → Silence(MuteStage) → TimeMute →
   Wait(HA position) → Dedup(nflog) → Retry(send) → SetNotifies(nflog)
```

1. **GossipSettle** — al arrancar, esperar a que el cluster converja antes de enviar, para que un peer recién reiniciado no notifique dos veces.
2. **Inhibit** — descartar esta alerta si una alerta *source* que coincide (p. ej. una `critical`) está actualmente activa. Ver §5.3.
3. **Silence** — descartar si un silence que coincide está activo. Ver §5.4.
4. **TimeMute / TimeActive** — descartar si está dentro de una ventana de `mute_time_intervals` (o *fuera* de una ventana de `active_time_intervals`).
5. **Wait** — solo en HA: retrasar en `peer position × peer_timeout` (por defecto `15s`) para que los peers no disparen todos a la vez.
6. **Dedup** — consultar el `nflog` propagado por gossip; si un peer ya notificó este hash de grupo exacto, saltear.
7. **Retry** — llamar realmente a la integración (Slack/PagerDuty/…), reintentando con backoff ante fallos transitorios.
8. **SetNotifies** — registrar el éxito en el `nflog` y propagarlo por gossip, para que los peers deduplican.

### 2.3 Mecanismos de supresión comparados

Estos tres se confunden constantemente. Aprendé las distinciones:

| Mecanismo | Quién lo define | Alcance | Duración | Uso típico |
|---|---|---|---|---|
| **Silence** | Operador (ad hoc, vía UI/API/amtool) | Alertas que coinciden con label matchers | Inicio/fin explícito (`--duration`) | "Estoy haciendo mantenimiento en node1 por 2h." |
| **Inhibition** | Config (`inhibit_rules`) | Suprime alertas *target* mientras una alerta *source* está en `firing` | Mientras la source siga en `firing` | "Si todo el cluster está `critical` caído, no me pagines además por cada `warning` en él." |
| **Time interval mute** | Config (`time_intervals` + route) | Un route/receiver completo | Ventanas de calendario recurrentes | "Sin ruido `warning`/`info` en Slack los fines de semana / fuera del horario laboral." |

---

## 3. Alta disponibilidad: gossip y deduplicación

Alertmanager está diseñado para HA **sin** un líder ni un almacén de quórum externo. Los peers forman una malla usando el gossip de HashiCorp `memberlist` (escucha por defecto en `0.0.0.0:9094`, TCP+UDP). Replican dos cosas: **silences** y el **notification log (`nflog`)**.

El truco de dedup, con precisión:

- Cada peer calcula una **peer position** estable (ordenada por nombre en el cluster).
- La etapa **Wait** retrasa la notificación en `position × peer-timeout`. El peer 0 espera `0s`, el peer 1 espera `15s`, el peer 2 espera `30s`.
- El peer 0 envía primero, registra el éxito en su `nflog` y lo propaga por gossip. Para cuando expira la espera del peer 1, su etapa **Dedup** ve la entrada y saltea.
- Si el peer 0 está muerto o lento (no propagó por gossip a tiempo), el peer 1 envía. Esto es **at-least-once**: un duplicado es posible durante particiones, pero un page *perdido* no lo es. Ese es el sesgo correcto para alerting.

| Topología | Disponibilidad | Riesgo de duplicados | Riesgo de pérdida de estado | Recomendada para |
|---|---|---|---|---|
| **Instancia única** | Ninguna — SPOF | Cero | Silences/nflog perdidos ante crash | Dev, lab, práctica PCA |
| **2 peers** | Sobrevive la pérdida de 1 | Bajo (ventana ≤ `peer-timeout`) | Ninguno si sobrevive 1 | Prod pequeña |
| **3 peers** (recomendado) | Sobrevive la pérdida de 2 / 1 lado de partición | Bajo | Ninguno | Producción |
| **5+ peers** | Excesivo; más tráfico de gossip | Ligeramente mayor | Ninguno | Flotas muy grandes |

> **Regla crítica para HA:** apuntá **cada** Prometheus a **todos** los peers de Alertmanager (*no* hagas load-balance por delante de ellos). El fan-out de Prometheus + la dedup por gossip de Alertmanager es el diseño. Un único LB por delante anula la redundancia y puede descartar alertas si falla.

Flags de cluster (cada peer):

```
--cluster.listen-address=0.0.0.0:9094
--cluster.peer=am-0.alertmanager:9094
--cluster.peer=am-1.alertmanager:9094
--cluster.peer=am-2.alertmanager:9094
--cluster.peer-timeout=15s
--cluster.gossip-interval=200ms
--cluster.pushpull-interval=1m0s
--cluster.settle-timeout=1m0s
```

---

## 4. Manifiestos completos y válidos

### 4.1 Lado Prometheus — apuntando al cluster y cargando reglas

`prometheus.yml` (secciones relevantes, completas):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s        # how often alerting rules are evaluated
  external_labels:
    cluster: prod-eu-west-1        # attached to every alert; used in group_by/inhibit `equal`
    replica: prom-a                # HA Prometheus pair; Alertmanager dedups across replicas

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alert_relabel_configs:
    # Drop the replica label so the HA Prometheus pair produce identical alerts
    # that Alertmanager can deduplicate.
    - source_labels: [replica]
      action: labeldrop
  alertmanagers:
    - api_version: v2
      path_prefix: /
      timeout: 10s
      static_configs:
        - targets:
            - alertmanager-0.alertmanager:9093
            - alertmanager-1.alertmanager:9093
            - alertmanager-2.alertmanager:9093
      # In Kubernetes you would instead use kubernetes_sd_configs + relabeling:
      # kubernetes_sd_configs:
      #   - role: endpoints
      #     namespaces: { names: [monitoring] }
      # relabel_configs:
      #   - source_labels: [__meta_kubernetes_service_name]
      #     regex: alertmanager
      #     action: keep
```

`/etc/prometheus/rules/latency.yml` — un grupo de alerting rules real con `for` y `keep_firing_for`:

```yaml
groups:
  - name: api-slo
    interval: 15s
    rules:
      # Recording rule feeding the alert (keeps the alert expr cheap and stable)
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      - alert: HighRequestLatency
        expr: job:http_request_duration_seconds:p99_5m{job="payments-api"} > 0.5
        for: 10m                 # must hold 10m before firing (inactive→pending→firing)
        keep_firing_for: 5m      # stay firing 5m after it recovers, to avoid flapping
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "p99 latency on {{ $labels.job }} is {{ $value | humanizeDuration }}"
          description: >-
            p99 request latency is above 500ms for 10m on {{ $labels.job }}
            in cluster {{ $externalLabels.cluster }}.
          runbook_url: https://runbooks.example.com/payments/high-latency

      - alert: TargetDown
        expr: up{job="payments-api"} == 0
        for: 2m
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "Target {{ $labels.instance }} is down"
```

### 4.2 Lado Alertmanager — un `alertmanager.yml` completo

Esto intencionalmente no está truncado: route tree, receivers, inhibition, time intervals y templating.

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: smtp.example.com:587
  smtp_from: alertmanager@example.com
  smtp_auth_username: alertmanager@example.com
  smtp_auth_password_file: /etc/alertmanager/secrets/smtp_password
  slack_api_url_file: /etc/alertmanager/secrets/slack_url
  http_config:
    follow_redirects: true

templates:
  - /etc/alertmanager/templates/*.tmpl

# ---- Recurring calendar windows referenced by the route tree ----
time_intervals:
  - name: outside-business-hours
    time_intervals:
      - weekdays: ['saturday', 'sunday']
      - times:
          - start_time: '00:00'
            end_time: '09:00'
          - start_time: '18:00'
            end_time: '24:00'
        weekdays: ['monday:friday']
        location: 'Europe/Madrid'

# ---- The routing tree ----
route:
  receiver: default-email               # catch-all fallback
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # 1) Anything critical → PagerDuty, page fast, nag hourly.
    - matchers:
        - severity = "critical"
      receiver: pagerduty-critical
      group_wait: 10s
      repeat_interval: 1h
      continue: true            # keep evaluating siblings so it also lands in Slack

    # 2) Team-based fan-out for the payments team.
    - matchers:
        - team = "payments"
      receiver: payments-slack
      routes:
        # Mute non-critical payments noise outside business hours.
        - matchers:
            - severity =~ "warning|info"
          receiver: payments-slack
          mute_time_intervals:
            - outside-business-hours

    # 3) Watchdog / dead-man's-switch always-firing alert → healthcheck webhook.
    - matchers:
        - alertname = "Watchdog"
      receiver: 'null'
      group_wait: 0s
      group_interval: 1m
      repeat_interval: 1m

receivers:
  - name: 'null'                # black hole (used by Watchdog handled elsewhere)

  - name: default-email
    email_configs:
      - to: sre@example.com
        send_resolved: true

  - name: pagerduty-critical
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pd_routing_key
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
        send_resolved: true
        description: '{{ .CommonAnnotations.summary }}'
        details:
          cluster: '{{ .CommonLabels.cluster }}'
          num_firing: '{{ .Alerts.Firing | len }}'

  - name: payments-slack
    slack_configs:
      - channel: '#payments-alerts'
        send_resolved: true
        title: '{{ template "slack.title" . }}'
        text: '{{ template "slack.text" . }}'
        actions:
          - type: button
            text: 'Runbook'
            url: '{{ (index .Alerts 0).Annotations.runbook_url }}'

# ---- Inhibition: a critical suppresses warnings for the same service ----
inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'cluster', 'service']

  # If a whole node is down, don't also alert on individual pods on it.
  - source_matchers:
      - alertname = "NodeDown"
    target_matchers:
      - alertname =~ "PodNotReady|KubeletDown"
    equal: ['node']
```

Template personalizado `/etc/alertmanager/templates/slack.tmpl`:

```
{{ define "slack.title" }}[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}{{ end }}

{{ define "slack.text" }}
{{ range .Alerts -}}
*Severity:* {{ .Labels.severity }}
*Summary:* {{ .Annotations.summary }}
*Cluster:* {{ .Labels.cluster }}
{{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
{{ end }}
{{ end }}
```

### 4.3 Kubernetes: Alertmanager en HA como StatefulSet

Un despliegue HA crudo (sin Operator). El Service headless da nombres DNS estables para los peers de gossip.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: monitoring
  labels: { app: alertmanager }
spec:
  clusterIP: None            # headless → per-pod DNS: alertmanager-0.alertmanager...
  selector: { app: alertmanager }
  ports:
    - { name: web,     port: 9093, targetPort: 9093 }
    - { name: gossip-tcp, port: 9094, targetPort: 9094, protocol: TCP }
    - { name: gossip-udp, port: 9094, targetPort: 9094, protocol: UDP }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  serviceName: alertmanager
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: alertmanager }
  template:
    metadata:
      labels: { app: alertmanager }
    spec:
      containers:
        - name: alertmanager
          image: quay.io/prometheus/alertmanager:v0.27.0
          args:
            - --config.file=/etc/alertmanager/alertmanager.yml
            - --storage.path=/alertmanager
            - --data.retention=120h
            - --web.listen-address=0.0.0.0:9093
            - --web.external-url=https://alertmanager.example.com
            - --cluster.listen-address=0.0.0.0:9094
            - --cluster.peer=alertmanager-0.alertmanager:9094
            - --cluster.peer=alertmanager-1.alertmanager:9094
            - --cluster.peer=alertmanager-2.alertmanager:9094
            - --cluster.peer-timeout=15s
          ports:
            - { name: web, containerPort: 9093 }
            - { name: gossip-tcp, containerPort: 9094, protocol: TCP }
            - { name: gossip-udp, containerPort: 9094, protocol: UDP }
          readinessProbe:
            httpGet: { path: /-/ready, port: 9093 }
            initialDelaySeconds: 10
          livenessProbe:
            httpGet: { path: /-/healthy, port: 9093 }
          volumeMounts:
            - { name: config, mountPath: /etc/alertmanager }
            - { name: data,   mountPath: /alertmanager }
      volumes:
        - name: config
          configMap: { name: alertmanager-config }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        resources: { requests: { storage: 1Gi } }
```

### 4.4 Prometheus Operator: el CRD `AlertmanagerConfig`

Si corrés kube-prometheus-stack, definís el routing por namespace de forma declarativa:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: payments-routing
  namespace: payments
  labels:
    alertmanagerConfig: prod      # must match Alertmanager CR's configSelector
spec:
  route:
    receiver: payments-slack
    groupBy: ['alertname', 'severity']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: team
        value: payments
        matchType: '='
  receivers:
    - name: payments-slack
      slackConfigs:
        - channel: '#payments-alerts'
          sendResolved: true
          apiURL:
            name: slack-webhook      # references a Secret
            key: url
  inhibitRules:
    - sourceMatch:
        - name: severity
          value: critical
      targetMatch:
        - name: severity
          value: warning
      equal: ['alertname', 'service']
```

---

## 5. Recorridos por CLI y terminal (`$`)

### 5.1 Validar la config antes de enviarla (`amtool`)

```
$ amtool check-config /etc/alertmanager/alertmanager.yml
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 2 inhibit rules
 - 5 receivers
 - 1 time interval
 - 1 template file
```

Una config rota falla ruidosamente (y Alertmanager se niega a recargarla):

```
$ amtool check-config alertmanager.yml
Checking 'alertmanager.yml'  FAILED: undefined receiver "payments-slak" used in route
```

### 5.2 Inspeccionar y *probar* el routing tree

```
$ amtool config routes show --config.file=alertmanager.yml
Routing tree:
.
└── default-route  receiver: default-email
    ├── {severity="critical"}   receiver: pagerduty-critical  continue: true
    ├── {team="payments"}       receiver: payments-slack
    │   └── {severity=~"warning|info"}  receiver: payments-slack
    └── {alertname="Watchdog"}  receiver: null
```

Probá a qué receiver(s) llegaría una alerta hipotética — esto atrapa bugs de routing antes de que paginen:

```
$ amtool config routes test --config.file=alertmanager.yml \
    severity=critical team=payments service=payments-api
pagerduty-critical
payments-slack
```

```
$ amtool config routes test --config.file=alertmanager.yml \
    --verify.receivers=pagerduty-critical severity=critical
pagerduty-critical
```

### 5.3 Consultar alertas en vivo

```
$ amtool alert query --alertmanager.url=http://localhost:9093
Alertname          Starts At                Summary                                  State
HighRequestLatency 2026-08-09 09:12:04 UTC  p99 latency on payments-api is 812ms     active
TargetDown         2026-08-09 09:15:41 UTC  Target 10.0.3.7:8080 is down             suppressed
Watchdog           2026-08-09 06:00:00 UTC  This is an always-firing alert           active
```

`suppressed` arriba = inhibida o silenciada. Filtrá solo las suprimidas:

```
$ amtool alert query --alertmanager.url=http://localhost:9093 \
    'severity="warning"' --output=extended
```

### 5.4 Silences (el flujo de mantenimiento)

```
$ amtool silence add \
    --alertmanager.url=http://localhost:9093 \
    --author="sre@example.com" \
    --duration="2h" \
    --comment="Rolling node1 kernel upgrade — ticket OPS-4821" \
    alertname="TargetDown" instance=~"node1.*"
b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa

$ amtool silence query --alertmanager.url=http://localhost:9093
ID                                   Matchers                          Ends At                  Comment
b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa alertname="TargetDown" instance=~ 2026-08-09 11:34 UTC     Rolling node1 kernel upgrade...

$ amtool silence expire b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa \
    --alertmanager.url=http://localhost:9093
```

### 5.5 Disparar una alerta sintética de punta a punta (test de integración)

```
$ amtool alert add --alertmanager.url=http://localhost:9093 \
    alertname="SmokeTest" severity="warning" team="payments" \
    --annotation=summary="pipeline smoke test" \
    --start="2026-08-09T09:00:00Z"
```

O golpeá directamente la API v2 cruda (lo que hace Prometheus):

```
$ curl -sS -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {"alertname":"SmokeTest","severity":"warning","team":"payments"},
    "annotations": {"summary":"pipeline smoke test"},
    "startsAt": "2026-08-09T09:00:00Z",
    "endsAt":   "2026-08-09T09:10:00Z"
  }
]'
```

### 5.6 Recarga en caliente de la configuración (sin reinicio)

```
$ curl -sS -XPOST http://localhost:9093/-/reload      # requires --web.enable-lifecycle
$ # or, in-place:
$ kill -HUP $(pidof alertmanager)
```

Confirmá que la recarga realmente se aplicó (ver la métrica en §6).

---

## 6. Verificación y diagnóstico de fallos

### 6.1 La escalera de "¿se entregó mi alerta?"

Rastreá la alerta a través de cada salto; cada salto tiene una métrica que o bien prueba el éxito o bien localiza la falla.

| Síntoma | Dónde mirar | Métrica / chequeo |
|---|---|---|
| La alerta dispara en Prometheus pero Alertmanager nunca la ve | Enlace Prometheus → AM | `prometheus_notifications_dropped_total`, `prometheus_notifications_errors_total{alertmanager=...}`, `prometheus_notifications_sent_total`, `prometheus_notifications_queue_length` vs `_capacity` |
| Prometheus descubre 0 Alertmanagers | SD de Prometheus | `prometheus_notifications_alertmanagers_discovered` (debería igualar el conteo de peers); chequeá `/api/v1/alertmanagers` |
| AM recibe la alerta pero nunca notifica | Pipeline de AM | La alerta aparece como `suppressed` en `amtool alert query` → chequeá silences/inhibition/time-mute |
| Notificación intentada pero fallando | AM → integración | `alertmanager_notifications_failed_total{integration="slack"}` subiendo; chequeá los logs de la integración |
| Pages duplicados | HA / dedup de AM | `alertmanager_cluster_health_score` (0 = sano), `alertmanager_cluster_members`, `alertmanager_cluster_failed_peers` |
| El cambio de config no se aplicó | Reload de AM | `alertmanager_config_last_reload_successful` == 1, `alertmanager_config_last_reload_success_timestamp_seconds` |

### 6.2 Lado Prometheus — ¿está siquiera llegando a Alertmanager?

```
$ curl -sS http://localhost:9090/api/v1/alertmanagers | jq
{
  "status": "success",
  "data": {
    "activeAlertmanagers": [
      {"url": "http://alertmanager-0.alertmanager:9093/api/v2/alerts"},
      {"url": "http://alertmanager-1.alertmanager:9093/api/v2/alerts"},
      {"url": "http://alertmanager-2.alertmanager:9093/api/v2/alerts"}
    ],
    "droppedAlertmanagers": []
  }
}
```

Si `activeAlertmanagers` está vacío → el service discovery / relabeling / la red están rotos; nada río abajo importa todavía. Chequeá:

```
$ curl -sS 'http://localhost:9090/api/v1/query?query=prometheus_notifications_errors_total' | jq '.data.result'
$ curl -sS 'http://localhost:9090/api/v1/query?query=prometheus_notifications_queue_length' | jq '.data.result'
```

Un `queue_length` acercándose a `queue_capacity` (por defecto 10000) significa que Alertmanager no da abasto y Prometheus está a punto de *descartar* alertas (`prometheus_notifications_dropped_total` subiendo) — un incidente genuino de "perdimos alertas".

Confirmá que la regla realmente está en `firing` en el propio Prometheus (serie sintética `ALERTS`):

```
$ curl -sS 'http://localhost:9090/api/v1/query?query=ALERTS{alertstate="firing"}' | jq '.data.result[].metric'
```

### 6.3 Lado Alertmanager — salud del cluster

```
$ curl -sS http://localhost:9093/api/v2/status | jq '.cluster'
{
  "name": "01J...",
  "status": "ready",
  "peers": [
    {"name": "01J...a", "address": "10.0.1.5:9094"},
    {"name": "01J...b", "address": "10.0.1.6:9094"},
    {"name": "01J...c", "address": "10.0.1.7:9094"}
  ]
}
```

PromQL de health-score para alertar sobre tu propio alerting (meta-monitoring — **hacé siempre esto**):

```
# Cluster unhealthy
max(alertmanager_cluster_health_score) > 0

# A peer went missing
alertmanager_cluster_members < 3

# Config failed to reload
alertmanager_config_last_reload_successful == 0

# Notifications failing to an integration
rate(alertmanager_notifications_failed_total[5m]) > 0
```

### 6.4 El dead-man's-switch (Watchdog)

El patrón de verificación más importante: una alerta que está **siempre en `firing`** (`expr: vector(1)`), enrutada a un receiver que espera un *heartbeat*. Si el heartbeat se detiene, un sistema externo te pagina — probando que el *pipeline entero* (reglas de Prometheus → envío → Alertmanager → route → notify) está vivo. Sin él, un pipeline de alerting roto es silencioso por definición.

```yaml
- alert: Watchdog
  expr: vector(1)
  labels: { severity: none }
  annotations:
    summary: "Alerting pipeline is alive. If this stops, alerting is broken."
```

### 6.5 Modos de fallo comunes y causa raíz

| Fallo | Causa raíz | Solución |
|---|---|---|
| Sin page, alerta `suppressed` | Regla de inhibit superpuesta o silence olvidado | `amtool silence query`; chequeá las labels `equal` de `inhibit_rules` |
| Sin page, la alerta ni siquiera está en AM | `alert_relabel_configs` descartó una label necesaria, o el SD devuelve 0 AMs | `amtool config routes test` con las labels reales; chequeá `/api/v1/alertmanagers` |
| Receiver equivocado | Precedencia del matcher de route / falta `continue: true` | `amtool config routes test`; recordá que gana el primer match salvo `continue` |
| Pages duplicados | Los peers no pueden hacer gossip (puerto 9094 bloqueado), así que no hay dedup | Abrí TCP+UDP 9094; chequeá `alertmanager_cluster_failed_peers` |
| La alerta nunca se resuelve | Prometheus dejó de enviar pero `resolve_timeout` es muy largo, o el receiver no tiene `send_resolved: true` | Poné `send_resolved: true`; verificá la propagación del `endsAt` |
| Notificaciones con flapping | Sin `for` / sin `keep_firing_for`, o `group_interval` muy bajo | Agregá `for`, `keep_firing_for`; subí `repeat_interval` |
| La edición de config es ignorada | `--web.enable-lifecycle` no está seteado, así que `/-/reload` da 405 | Habilitá el flag o `SIGHUP`; verificá `config_last_reload_successful` |

### 6.6 Sintaxis de matchers — la trampa de la deprecación

Los viejos `match` / `match_re` (forma de mapa) están deprecados en favor de la lista `matchers`. Aprendé ambos; las configs de producción todavía los mezclan.

| Viejo (deprecado) | Nuevo (lista `matchers`) |
|---|---|
| `match: {severity: critical}` | `matchers: ['severity="critical"']` |
| `match_re: {service: (foo|bar)}` | `matchers: ['service=~"foo|bar"']` |
| — | `matchers: ['team!="db"']`, `matchers: ['env!~"dev|stg"']` |

Los valores en la nueva sintaxis siempre van **entre comillas**; los operadores son `=`, `!=`, `=~`, `!~`.

---

## 7. Referencias

- Alertmanager overview — https://prometheus.io/docs/alerting/latest/alertmanager/
- Alertmanager configuration reference — https://prometheus.io/docs/alerting/latest/configuration/
- Notification examples & templating — https://prometheus.io/docs/alerting/latest/notification_examples/ and https://prometheus.io/docs/alerting/latest/notifications/
- High availability — https://github.com/prometheus/alertmanager#high-availability
- `amtool` documentation — https://github.com/prometheus/alertmanager#amtool
- Alertmanager HTTP API (v2, OpenAPI) — https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml
- Prometheus alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus `alerting` / `alertmanager_config` — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
- Prometheus alertmanager overview — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/ and https://prometheus.io/docs/practices/alerting/
- Prometheus Operator `AlertmanagerConfig` CRD — https://prometheus-operator.dev/docs/developer/alerting/ and https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api-reference/api.md
- PCA Curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf