# 1.2 — Describir conceptos fundamentales de la nube

**Certificación:** Google Cloud Digital Leader (versión del examen 2026-08-12)
**Peso en el examen:** 9.0
**Perfil de audiencia:** Platform Architect / SRE. Este objetivo se evalúa como vocabulario, pero se *practica* como planificación de capacidad, diseño de dominios de falla y economía unitaria. El material que sigue enseña lo segundo, porque es la única forma confiable de responder lo primero sin memorizar.

---

## 1. Motivación: el problema arquitectónico que este objetivo existe para resolver

Cada "concepto fundamental de la nube" de la guía del examen es el nombre formal de una de dos fallas de producción que son anteriores a la computación en la nube:

**Falla 1 — el impuesto del aprovisionamiento por pico.** La capacidad on-premises es una función escalonada que se compra por adelantado contra un pronóstico. El pronóstico debe cubrir el pico, así que la flota se dimensiona para la peor hora del peor día del año. Una plataforma de retail cuyo pico de Black Friday es 4× su carga mediana funciona a ~25% de utilización promedio durante 364 días para sobrevivir uno. Pagás el 100% del capex para usar el 25% de la capacidad, y lo pagás 18 meses antes de que llegue el tráfico, sobre un cronograma de depreciación que sobrevive a la arquitectura.

**Falla 2 — el punto ciego de la falla correlacionada.** Un par de servidores "de alta disponibilidad" en el mismo rack comparte un switch top-of-rack, una PDU, un circuito de refrigeración, un edificio y una acometida eléctrica. La aritmética de disponibilidad asumía fallas independientes; la disposición física garantizaba fallas dependientes. Todo post-mortem real de una caída de esta clase termina con la misma frase: *teníamos dos de todo, en uno de algún lado.*

La computación en la nube no elimina ninguno de los dos problemas. Los **convierte en parámetros direccionables por API**:

| Problema pre-nube | Concepto de nube que lo nombra | El parámetro que ahora controlás |
|---|---|---|
| Capacidad comprada 18 meses antes | Autoservicio bajo demanda + elasticidad rápida | `--min-replicas` / `--max-replicas`, segundos para aprovisionar |
| 25% de utilización promedio | Agrupamiento de recursos + servicio medido | Facturación por segundo, Spot, descuentos por uso comprometido |
| Dos de todo en un solo edificio | Regiones y zonas | `--zone`, `--region`, `topologySpreadConstraints` |
| "¿Quién parcheó el kernel?" | Modelo de responsabilidad compartida | Elección entre IaaS / PaaS / SaaS |
| "El regulador dice que los datos no pueden salir del país" | Modelos de despliegue + residencia de datos | Org policy `gcp.resourceLocations` |
| Depreciación de capex vs. uso real | TCO, capex → opex | Exportación de facturación, presupuestos, costo unitario FinOps |

**El encuadre relevante para el examen:** estos conceptos no son marketing. Cada uno es una superficie de control con un valor por defecto que está mal para producción, y saber cuál es el default equivocado es la diferencia entre un Digital Leader que puede dimensionar una migración y uno que aprueba un lift-and-shift que triplica la factura.

---

## 2. Las cinco características esenciales (NIST SP 800-145), mapeadas a superficies de control reales

NIST SP 800-145 es la definición que siguen tanto la documentación de Google como la guía del examen. Memorizá los cinco nombres; entendelos a través del mecanismo.

| Característica NIST | Definición simple | Mecanismo en Google Cloud | Cómo *probás* que funciona | Modo de falla cuando no funciona |
|---|---|---|---|---|
| **Autoservicio bajo demanda** | Un consumidor puede aprovisionar capacidad unilateralmente, sin interacción humana del proveedor | Cloud Console, `gcloud`, REST API, Terraform, Deployment Manager | Un `gcloud compute instances create` devuelve `RUNNING` en <60 s sin ningún ticket | Una "nube" interna que exige un comité de aprobación de cambios tiene forma de IaaS, pero no es bajo demanda — el beneficio de elasticidad se evapora |
| **Acceso amplio a la red** | Capacidades disponibles por red mediante mecanismos estándar, desde clientes heterogéneos | Front-end global anycast, Cloud Load Balancing, niveles de red Premium/Standard, Cloud CDN | `curl -sI https://<GLB-IP>` resuelve a la misma VIP desde tres continentes | Endpoints solo regionales; clientes en APAC pagando una penalidad de 250 ms de RTT para llegar a `us-central1` |
| **Agrupamiento de recursos** | Modelo multi-tenant; recursos físicos/virtuales asignados dinámicamente; independencia de ubicación a un nivel abstracto (país/región/DC) | Live Migration, tipos de máquina personalizados, bin-packing de GKE, shared VPC | Dos VMs en el mismo host sobreviven un evento de mantenimiento del host sin reiniciar | Contención por vecino ruidoso; o lo opuesto — requisito regulatorio de single-tenancy, resuelto con **sole-tenant nodes** |
| **Elasticidad rápida** | Las capacidades se aprovisionan y liberan elásticamente, aparentando ser ilimitadas para el consumidor | Managed Instance Groups + autoscaler, GKE Cluster Autoscaler + HPA, escalado por concurrencia de Cloud Run hasta cero | Una prueba de carga lleva las réplicas de 3 → 40 → 3 sin acción humana | El autoscaler se enfría más lento de lo que sube el tráfico; o un techo de cuota limita el crecimiento en silencio (ver §8.2) |
| **Servicio medido** | El uso de recursos se mide, controla y reporta — transparencia para proveedor y consumidor | Exportación de Cloud Billing a BigQuery, facturación por segundo, Cloud Monitoring, presupuestos y alertas | Una consulta de BigQuery atribuye >95% del gasto a un equipo/servicio etiquetado | Recursos sin etiquetar; una factura que podés describir pero no descomponer — la falla FinOps más común de todas |

> **La trampa del examen.** *Elasticidad rápida* trata sobre la **velocidad y automatización** del escalado. *Agrupamiento de recursos* trata sobre **multi-tenancy y abstracción de ubicación**. *Servicio medido* trata sobre **medición y pago por uso**. Las preguntas que describen "solo pagás por los segundos que consumís" evalúan servicio medido, no elasticidad.

### 2.1 Probar el "servicio medido" — la consulta de exportación de facturación

El servicio medido no vale nada si no podés atribuirlo. Esta es la consulta que todo equipo de plataforma corre semanalmente:

```sql
-- Cost attribution by service, SKU, project and region for a billing period.
-- Requires the detailed (resource-level) Cloud Billing export to BigQuery.
SELECT
  service.description                              AS service,
  sku.description                                  AS sku,
  project.id                                       AS project,
  IFNULL(location.region, 'global')                AS region,
  (SELECT value FROM UNNEST(labels) WHERE key = 'team')     AS team,
  ROUND(SUM(usage.amount_in_pricing_units), 2)     AS usage_units,
  ANY_VALUE(usage.pricing_unit)                    AS unit,
  ROUND(SUM(cost), 2)                              AS gross_cost_usd,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS credits_usd,
  ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net_cost_usd
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_0123AB_4567CD_89EFGH`
WHERE DATE(_PARTITIONTIME) BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY service, sku, project, region, team
HAVING net_cost_usd > 50
ORDER BY net_cost_usd DESC
LIMIT 15;
```

```
$ bq query --use_legacy_sql=false --format=pretty < cost_attribution.sql
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
|       service       |                    sku                     |      project      |   region    |  team   | usage_units |   unit   | gross_cost_usd | credits_usd | net_cost_usd |
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
| Compute Engine      | N2 Instance Core running in Americas       | acme-prod-platform| us-central1 | platform|   198412.50 | hour     |       6272.99  |    -2071.05 |      4201.94 |
| Compute Engine      | N2 Instance Ram running in Americas        | acme-prod-platform| us-central1 | platform|   793650.00 | gibibyte |       3362.79  |    -1109.72 |      2253.07 |
| Networking          | Network Internet Egress from Americas to...| acme-prod-edge    | us-central1 | edge    |    15360.00 | gibibyte |       1791.36  |        0.00 |      1791.36 |
| Cloud Storage       | Standard Storage US Multi-region           | acme-prod-data    | us          | data    |    81920.00 | gibibyte |       2211.84  |        0.00 |      2211.84 |
| BigQuery            | Analysis (on demand)                       | acme-prod-data    | US          | data    |      284.10 | tebibyte |       1775.63  |        0.00 |      1775.63 |
| Kubernetes Engine   | Autopilot Pod Memory Requests (Regular)    | acme-prod-apps    | us-central1 | apps    |   410880.00 | gibibyte |       1808.00  |        0.00 |      1808.00 |
| Cloud SQL           | Cloud SQL for PostgreSQL: Regional - vCPU  | acme-prod-apps    | us-central1 | apps    |    11680.00 | hour     |        747.52  |        0.00 |       747.52 |
| Compute Engine      | Balanced PD Capacity                       | acme-prod-platform| us-central1 | platform|    20480.00 | gibibyte |       2048.00  |        0.00 |      2048.00 |
| Compute Engine      | Spot Preemptible N2 Instance Core          | acme-batch        | us-central1 | ml      |    87600.00 | hour     |        830.66  |        0.00 |       830.66 |
| Cloud Run           | CPU Allocation Time (Tier 1)               | acme-prod-api     | us-central1 | api     |   1204800.00| second   |        289.15  |        0.00 |       289.15 |
+---------------------+--------------------------------------------+-------------------+-------------+---------+-------------+----------+----------------+-------------+--------------+
```

Leé esa salida como arquitecto, no como contador. La línea que debería frenarte es **Network Internet Egress: $1.791 por 15 TiB** — una línea de costo sin cómputo, sin almacenamiento y sin ninguna funcionalidad asociada. El egress es el impuesto a la gravedad de los datos, y es invisible en todo diagrama de arquitectura jamás dibujado. La §7.4 lo cubre.

---

## 3. Modelos de servicio: IaaS, PaaS, SaaS — y los dos que la guía del examen da por implícitos

NIST nombra tres. La producción usa cinco escalones. El examen pregunta por los tres; la arquitectura depende de los cinco.

```
                            You manage ▓   Google manages ░
  ┌───────────────┬──────────────────────────────────────────────────────────┐
  │ On-premises   │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ IaaS   (GCE)  │ ░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ CaaS   (GKE)  │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ PaaS   (Run)  │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ FaaS (Functions)│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ SaaS (Workspace)│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓ │
  └───────────────┴──────────────────────────────────────────────────────────┘
    Facility→Hardware→Network→Hypervisor→OS→Runtime→App→Config→Data→Access
```

### 3.1 Matriz de compromisos

| Dimensión | IaaS (Compute Engine) | CaaS (GKE Standard) | CaaS gestionado (GKE Autopilot) | PaaS (Cloud Run) | FaaS (Cloud Run functions) | SaaS (Workspace, Looker) |
|---|---|---|---|---|---|---|
| **Unidad de despliegue** | Imagen de disco de VM | Contenedor + node pool | Contenedor + spec de Pod | Imagen de contenedor | Código fuente de la función | Nada — vos configurás |
| **Vos parcheás** | SO invitado, kernel, runtime, app | SO del nodo (o usás auto-upgrade), imagen, app | Imagen, app | Imagen, app | Código de la función | Nada |
| **Escala a cero** | No | No (los nodos persisten) | No (el control plane persiste) | **Sí** | **Sí** | N/A |
| **Latencia de aprovisionamiento (en frío)** | 20–60 s (arranque de VM) | 30–120 s (scale-up de nodo) | 30–120 s | ~0,1–3 s típico, depende del tamaño de imagen | ~0,1–2 s | 0 |
| **Granularidad de facturación** | Por segundo, mínimo 1 min | Por segundo sobre los nodos | Por segundo sobre los **requests** del Pod | Por cada 100 ms de CPU/memoria + solicitudes | Por cada 100 ms + invocaciones | Por asiento / por usuario |
| **Control máximo (módulos de kernel, GPUs, NIC personalizada)** | Total | Alto | Restringido | Bajo (sin privileged, sin daemons) | Muy bajo | Ninguno |
| **Portabilidad / lock-in** | Alta portabilidad (imágenes de VM) | La más alta (Kubernetes plano) | Alta (API de Kubernetes) | Media (compatible con Knative) | Baja (contrato de eventos) | Lock-in total |
| **Radio de impacto de tu error** | Toda la flota de VMs | Cluster / namespace | Namespace | Una sola revisión (rollback por traffic-split) | Una sola función | Solo configuración |
| **Quién recibe la llamada a las 03:00 por un CVE de kernel** | Vos | Vos (salvo auto-upgrade) | Google | Google | Google | Google |
| **Quién recibe la llamada a las 03:00 por tus 500s** | Vos | Vos | Vos | Vos | Vos | El proveedor |
| **Costo típico en régimen estable para una carga constante de 4 vCPU** | El más bajo con CUD a 3 años | Bajo | Medio | Más alto | El más alto | Plano por asiento |
| **Costo típico para una carga con picos, 3% de ciclo de trabajo** | El más alto (VMs ociosas) | Alto | Medio | **El más bajo** | **El más bajo** | N/A |

> **La regla de decisión que sobrevive al contacto con producción:** elegí el escalón *más alto* de la escalera que todavía satisfaga tus restricciones duras (acceso al kernel, afinidad de licencias, latencia sub-milisegundo, ciclo de trabajo sostenido al 100%). Cada escalón que subís elimina una rotación de guardia. Cada escalón que subís también elimina una salida de emergencia — así que documentá *qué restricción* te obligó a dejar de subir, porque esa restricción es justamente lo que hay que reexaminar en 18 meses.

### 3.2 La misma carga de trabajo, de cuatro formas — definiciones completas y desplegables

La carga: una API HTTP sin estado, `acme/checkout-api:1.14.2`, escuchando en `:8080`, `/healthz` para liveness, `/ready` para readiness, necesita ~500 m de CPU y 512 MiB por réplica.

#### 3.2.1 IaaS — MIG regional de Compute Engine con autoscaling (Terraform)

```hcl
# main.tf — IaaS: full control, you own the OS.
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region"     { type = string, default = "us-central1" }

# --- Instance template: immutable definition of one VM ------------------------
resource "google_compute_instance_template" "checkout" {
  name_prefix  = "checkout-api-"
  machine_type = "n2-standard-2"
  region       = var.region

  # Rolling replacement instead of in-place mutation.
  lifecycle {
    create_before_destroy = true
  }

  disk {
    source_image = "projects/cos-cloud/global/images/family/cos-stable"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 20
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block => no external IP. Egress via Cloud NAT.
  }

  service_account {
    email  = google_service_account.checkout.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # Container-Optimized OS declarative container spec.
    "gce-container-declaration" = yamlencode({
      spec = {
        containers = [{
          name  = "checkout-api"
          image = "us-central1-docker.pkg.dev/${var.project_id}/apps/checkout-api:1.14.2"
          env = [
            { name = "PORT",     value = "8080" },
            { name = "LOG_LEVEL", value = "info" },
          ]
          securityContext = { privileged = false }
          stdin           = false
          tty             = false
        }]
        restartPolicy = "Always"
      }
    })
    "google-logging-enabled"    = "true"
    "google-monitoring-enabled" = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  tags = ["checkout-api", "allow-health-check"]

  labels = {
    team        = "api"
    environment = "prod"
    cost-center = "cc-4471"
  }
}

# --- Regional MIG: spreads instances across all zones in the region -----------
resource "google_compute_region_instance_group_manager" "checkout" {
  name   = "checkout-api-mig"
  region = var.region

  base_instance_name        = "checkout-api"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]
  # EVEN is the default and the whole point: one zone loss removes ~1/4 of capacity.
  distribution_policy_target_shape = "EVEN"

  version {
    instance_template = google_compute_instance_template.checkout.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.checkout.id
    initial_delay_sec = 90     # Grace period: longer than worst-case cold start.
  }

  update_policy {
    type                           = "PROACTIVE"
    instance_redistribution_type   = "PROACTIVE"
    minimal_action                 = "REPLACE"
    max_surge_fixed                = 4   # Must be >= number of zones for regional MIGs.
    max_unavailable_fixed          = 0   # Zero-downtime rollout.
    replacement_method             = "SUBSTITUTE"
  }
}

# --- Rapid elasticity, expressed as code -------------------------------------
resource "google_compute_region_autoscaler" "checkout" {
  name   = "checkout-api-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.checkout.id

  autoscaling_policy {
    min_replicas    = 4    # One per zone: survives a zonal outage with capacity left.
    max_replicas    = 40
    cooldown_period = 90   # Must exceed boot + warm-up, or you thrash.

    cpu_utilization {
      target            = 0.60
      predictive_method = "OPTIMIZE_AVAILABILITY"  # Scales ahead of a learned daily cycle.
    }

    load_balancing_utilization {
      target = 0.70
    }

    scale_in_control {
      max_scaled_in_replicas {
        percent = 20     # Never remove more than 20% of the fleet per window.
      }
      time_window_sec = 300
    }
  }
}

resource "google_compute_health_check" "checkout" {
  name                = "checkout-api-hc"
  check_interval_sec  = 5
  timeout_sec         = 3
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }

  log_config { enable = true }
}

# --- Network plumbing ---------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "acme-prod-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "checkout-${var.region}"
  ip_cidr_range            = "10.20.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true   # Reach Google APIs without an external IP.

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_health_check" {
  name    = "allow-lb-health-check"
  network = google_compute_network.vpc.id

  # Google's published health-check and LB proxy ranges. Not arbitrary.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["allow-health-check"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_service_account" "checkout" {
  account_id   = "checkout-api"
  display_name = "checkout-api workload identity"
}

output "mig_self_link" {
  value = google_compute_region_instance_group_manager.checkout.self_link
}
```

#### 3.2.2 CaaS — Deployment de GKE con distribución correcta entre dominios de falla

```yaml
# checkout-api.yaml — CaaS: you own the image and the Pod spec; Google owns the
# control plane (and, on Autopilot, the nodes).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/version: "1.14.2"
    team: api
spec:
  replicas: 6
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
        app.kubernetes.io/version: "1.14.2"
    spec:
      serviceAccountName: checkout-api          # Bound via Workload Identity Federation.
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # --- Resource pooling made explicit: spread across ZONES, then NODES ----
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule        # Hard: never concentrate in one zone.
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway       # Soft: prefer node spread.
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout-api
      containers:
        - name: checkout-api
          image: us-central1-docker.pkg.dev/acme-prod-apps/apps/checkout-api:1.14.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: PORT
              value: "8080"
            - name: POD_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['topology.kubernetes.io/zone']
          resources:
            requests:                 # On Autopilot, requests ARE the billing unit.
              cpu: "500m"
              memory: "512Mi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "1000m"
              memory: "512Mi"         # limit == request for memory: avoids OOM surprises.
              ephemeral-storage: "1Gi"
          startupProbe:               # Protects slow starts from the liveness probe.
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          lifecycle:
            preStop:
              exec:
                # Let the LB deprogram this endpoint before the process dies.
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    cloud.google.com/neg: '{"ingress": true}'   # Container-native load balancing.
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
# --- Rapid elasticity at the Pod layer ---------------------------------------
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 6
  maxReplicas: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second     # Exported via Managed Service for Prometheus.
        target:
          type: AverageValue
          averageValue: "120"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 10
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300       # Scale in slowly; scale out fast.
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
# --- Guarantees the autoscaler and node upgrades cannot break the SLO ---------
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: checkout
spec:
  minAvailable: 4            # Survives a full zone drain in a 4-zone region.
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
```

#### 3.2.3 PaaS — servicio de Cloud Run (YAML estilo Knative, escala a cero)

```yaml
# service.yaml — PaaS: no nodes, no OS, no cluster. Deploy with:
#   gcloud run services replace service.yaml --region=us-central1
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: checkout-api
  namespace: "471829304517"        # Project number.
  labels:
    cloud.googleapis.com/location: us-central1
    team: api
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
    run.googleapis.com/launch-stage: GA
spec:
  template:
    metadata:
      name: checkout-api-01142-abc          # Revision name: enables traffic splitting.
      annotations:
        autoscaling.knative.dev/minScale: "2"    # 0 = true scale-to-zero, at the cost
        autoscaling.knative.dev/maxScale: "100"  #     of cold starts on the first request.
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/cpu-throttling: "false"   # Always-allocated CPU: costs more,
                                                      # required for background work.
        run.googleapis.com/startup-cpu-boost: "true"
        run.googleapis.com/vpc-access-connector: projects/acme-prod-api/locations/us-central1/connectors/run-connector
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      containerConcurrency: 80          # Requests served in parallel per instance.
      timeoutSeconds: 60
      serviceAccountName: checkout-api@acme-prod-api.iam.gserviceaccount.com
      containers:
        - name: checkout-api
          image: us-central1-docker.pkg.dev/acme-prod-api/apps/checkout-api:1.14.2
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: LOG_LEVEL
              value: info
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  key: latest
                  name: checkout-db-password    # Secret Manager, not a env literal.
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 2
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
  traffic:
    - revisionName: checkout-api-01142-abc
      percent: 90
    - revisionName: checkout-api-01141-xyz
      percent: 10                        # Canary: the PaaS rollback primitive.
```

#### 3.2.4 SaaS — no hay manifiesto

Ese es justamente el punto. El SaaS se consume, no se despliega. Tus artefactos son la configuración del IdP, las reglas de DLP, los roles de administración y un plan de salida (exportación de datos). Google Workspace, Looker (como producto alojado), Google Security Operations y Apigee viven acá.

```
$ gcloud identity groups memberships list \
    --group-email="checkout-oncall@acme.example" --format="table(preferredMemberKey.id,roles[0].name)"
ID                              NAME
alicia.moreno@acme.example      MEMBER
r.okonkwo@acme.example          MEMBER
sre-lead@acme.example           MANAGER
```

---

## 4. El modelo de responsabilidad compartida — y la extensión de "destino compartido" de Google

### 4.1 La matriz clásica

El límite se mueve con el modelo de servicio. Todo lo que está **por debajo** de la línea es de Google; todo lo que está **por encima** es tuyo. Nada se comparte nunca en el sentido de "alguien lo va a levantar".

| Capa | On-prem | IaaS (GCE) | CaaS (GKE Std) | CaaS (Autopilot) | PaaS (Cloud Run) | SaaS |
|---|---|---|---|---|---|---|
| Instalación física, energía, refrigeración | Vos | **Google** | **Google** | **Google** | **Google** | **Google** |
| Hardware, fabric de red, seguridad física | Vos | **Google** | **Google** | **Google** | **Google** | **Google** |
| Hypervisor / kernel del host | Vos | **Google** | **Google** | **Google** | **Google** | **Google** |
| SO del nodo + parcheo del kernel | Vos | **Vos** | Vos (auto-upgrade disponible) | **Google** | **Google** | **Google** |
| Control plane de Kubernetes | n/a | n/a | **Google** | **Google** | n/a | n/a |
| Runtime de contenedores | Vos | Vos | **Google** | **Google** | **Google** | **Google** |
| **Contenido de la imagen de contenedor / VM (CVEs en tu imagen base)** | Vos | **Vos** | **Vos** | **Vos** | **Vos** | **Google** |
| Código de aplicación y dependencias | Vos | **Vos** | **Vos** | **Vos** | **Vos** | **Google** |
| Controles de red (VPC, firewall, Cloud Armor) | Vos | **Vos** | **Vos** | **Vos** | **Vos** (parámetro de ingress) | Solo configuración |
| Política de IAM / quién puede hacer qué | Vos | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** |
| Cifrado **en reposo** (por defecto) | Vos | **Google** (siempre activo) | **Google** | **Google** | **Google** | **Google** |
| **Gestión** de claves de cifrado (CMEK/CSEK) | Vos | Vos, si optás por ello | Vos, si optás por ello | Vos, si optás por ello | Vos, si optás por ello | Limitada (CSE) |
| **Contenido, clasificación y retención de los datos** | Vos | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** |
| Fuente de verdad de identidad (usuarios, MFA) | Vos | **Vos** | **Vos** | **Vos** | **Vos** | **Vos** |

> **Dos filas nunca se mueven, en ningún escalón: tus datos y tu gestión de accesos.** Si una pregunta del examen describe una brecha causada por un bucket de almacenamiento público, un binding de IAM demasiado permisivo o una clave de service account sin rotar, la respuesta es *responsabilidad del cliente* sin importar el modelo de servicio. A la inversa, un escape del hypervisor o una intrusión física en un datacenter es *responsabilidad del proveedor* en todos los escalones por encima de on-prem.

### 4.2 Destino compartido — la parte que distingue el encuadre de Google

El Architecture Framework de Google sostiene que la *responsabilidad* compartida por sí sola deja al cliente con una lista de obligaciones y ninguna ayuda para cumplirlas. El **destino compartido (shared fate)** es el compromiso declarado de hacer que el camino seguro sea el camino por defecto y el más fácil:

| Mecanismo de destino compartido | Qué hace realmente | Dónde aparece |
|---|---|---|
| Postura segura por defecto | Cifrado en reposo y en tránsito activado por defecto; sin IP pública salvo que se pida; defaults de Shielded VM | Todos los servicios |
| Blueprints de fundaciones de seguridad | Landing zone opinada, entregada vía Terraform (org policies, VPC-SC, sinks de logging) | `terraform-google-modules/cloud-foundation-fabric` |
| Assured Workloads | Impone controles de ubicación del personal, residencia de datos y soporte para regímenes regulados (FedRAMP, IL4, regiones de la UE, ITAR) como *producto*, no como checklist | `gcloud assured workloads` |
| Risk Protection Program | Ciberseguro cotizado a partir de tu postura medida en Security Command Center | Suscrito por aseguradoras externas |
| Policy Intelligence / Recommender | Recomendaciones de mínimo privilegio de IAM generadas por máquina a partir de 90 días de uso real | `gcloud recommender` |

Valor diagnóstico: el destino compartido convierte "¿somos compliant?" en una consulta.

```
$ gcloud recommender recommendations list \
    --project=acme-prod-platform \
    --location=global \
    --recommender=google.iam.policy.Recommender \
    --format="table(name.basename(),primaryImpact.category,description)" --limit=3
NAME                                  CATEGORY  DESCRIPTION
1a0f3c9e-9c1a-4f8b-b3d2-77f1c0a2e5b1  SECURITY  Replace the role roles/editor with roles/artifactregistry.writer on serviceAccount:ci-deployer@…
c72b8e41-2d33-4a19-9f01-5b6e2a83d4aa  SECURITY  Remove the role roles/owner from user:contractor@vendor.example (unused for 137 days)
9e14d7b6-08cd-4c22-8a55-1f0b7e93c6d0  SECURITY  Replace roles/storage.admin with roles/storage.objectViewer on serviceAccount:reporting@…
```

---

## 5. Modelos de despliegue: público, privado, híbrido, multicloud

| Modelo | Definición | Realización en Google Cloud | Se elige porque | Costo real |
|---|---|---|---|---|
| **Nube pública** | Infraestructura aprovisionada para uso abierto del público general, propiedad del proveedor | Regiones de Google Cloud, proyectos estándar | Elasticidad, alcance global, capex cero, servicios gestionados | Economía del egress; percepción de vecino ruidoso; exposición jurisdiccional |
| **Nube privada** | Aprovisionada para uso exclusivo de una sola organización; on-premises o fuera | **Google Distributed Cloud** (conectada y air-gapped), **sole-tenant nodes**, **Bare Metal Solution**, VMware Engine | El regulador exige aislamiento físico o air-gap; términos de licencia atados a cores físicos; latencia sub-ms hacia la planta industrial | Volvés a la rueda del capex/aprovisionamiento por pico para esa huella |
| **Nube híbrida** | Composición de dos o más infraestructuras distintas unidas por tecnología que habilita la portabilidad de datos/apps | GKE Enterprise (Anthos) + Cloud Interconnect / HA VPN, Config Sync, Cloud Service Mesh | Migración por etapas; un mainframe o una DB licenciada que no se puede mover; edge limitado por latencia | Dos control planes, dos modelos de falla, un camino de red que ahora está en la ruta crítica |
| **Multicloud** | Cargas de trabajo repartidas entre más de un proveedor de nube pública | GKE Enterprise sobre AWS/Azure, BigQuery Omni, Cross-Cloud Interconnect | Poder de negociación; reglas regulatorias de riesgo de concentración (p. ej. DORA en la UE); herencia por adquisición | **Arquitectura de mínimo común denominador**: solo podés usar las funcionalidades que todos los proveedores comparten |

> **Advertencia de arquitecto que el examen no va a decir pero que toda migración demuestra:** el multicloud como *postura por defecto* te cuesta los servicios gestionados que hicieron que valiera la pena adoptar la nube. El multicloud como *decisión deliberada y por carga de trabajo* — analítica en BigQuery leyendo datos en su lugar sobre S3 vía BigQuery Omni, mientras el sistema transaccional se queda donde está — es sensato. "Multicloud por portabilidad" sin un failover jamás ejercitado es un impuesto sobre cada funcionalidad futura.

### 5.1 La residencia de datos como política ejecutable, no como diapositiva

Las preguntas sobre modelos de despliegue habitualmente se reducen a *dónde tienen permitido estar los datos*. Eso es una restricción de Organization Policy, y se aplica en la API, no por revisión:

```yaml
# resource-locations.yaml — deny creation of any resource outside the EU.
# Apply with: gcloud org-policies set-policy resource-locations.yaml
name: organizations/613295847201/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations          # Value group: all EU regions and multi-regions.
          - in:europe-west1-locations
        deniedValues:
          - in:us-locations
---
# Second policy: forbid external IPs on VMs (blast-radius reduction).
name: organizations/613295847201/policies/compute.vmExternalIpAccess
spec:
  rules:
    - enforce: true
```

```
$ gcloud org-policies set-policy resource-locations.yaml
Created policy [organizations/613295847201/policies/gcp.resourceLocations].

$ gcloud compute instances create test-us --zone=us-central1-a --project=acme-eu-prod
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/gcp.resourceLocations violated for projects/acme-eu-prod.
   us-central1-a violates constraint constraints/gcp.resourceLocations.
```

Ese exit distinto de cero es todo el control. Una política que produce un PDF no es un control; una política que produce un error de API sí lo es.

### 5.2 Opciones de conectividad híbrida — una tabla de decisión

| Opción | Ancho de banda | SLA | Perfil de latencia | Cifrado | Uso típico |
|---|---|---|---|---|---|
| **HA VPN** (IPsec sobre internet) | Hasta 3 Gbps por túnel, 10 Gbps agregados | 99,99% con dos interfaces | Variable como internet, cola impredecible | IPsec, siempre | Arranque rápido, dev/test, replicación de bajo volumen |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | 99,9% / 99,99% según la topología | Predecible, depende del proveedor | No por defecto (agregar MACsec/IPsec) | Sin presencia en una instalación de colocation de Google |
| **Dedicated Interconnect** | Circuitos de 10 o 100 Gbps | 99,9% / 99,99% según la topología | La más baja, determinista | No por defecto (MACsec disponible) | Varios TB/día sostenidos, reducción del costo de egress |
| **Cross-Cloud Interconnect** | 10 o 100 Gbps | Mismos niveles | Determinista, de proveedor a proveedor | MACsec disponible | Plano de datos multicloud (GCP ↔ AWS/Azure/OCI) |
| **Direct/Carrier Peering** | Variable | Sin SLA | Variable | Ninguno | Entrega de contenido público, no acceso a la VPC |

El nivel de 99,99% no es una casilla de verificación — requiere **cuatro** conexiones de interconnect en **dos** áreas metropolitanas con **dos** Cloud Routers. Una configuración de 99,9% publicitada internamente como "de alta disponibilidad" es el mismo error de falla correlacionada de la §1, mudado a la WAN.

---

## 6. Geografía: regiones, zonas, y qué falla junto de verdad

### 6.1 La jerarquía y su semántica de fallas

```
  Multi-region  (e.g. "us", "eu", "asia")  ── async/sync replication across regions
    └── Region  (e.g. us-central1, europe-west4)  ── metro area, <1 ms inter-zone RTT
          └── Zone  (e.g. us-central1-a)  ── one or more clusters, independent
                │      power / cooling / networking failure domain
                └── Cluster / rack / host
```

- **Zona**: un área de despliegue *dentro* de una región. Un nombre de zona (`us-central1-a`) se mapea a un **cluster físico distinto por proyecto** — Google mezcla el mapeo letra-a-hardware entre organizaciones justamente para que no se amontonen todos en `-a`.
- **Región**: un área geográfica independiente que contiene tres o más zonas. La latencia de ida y vuelta entre zonas dentro de una región es típicamente **sub-milisegundo** — lo bastante baja para replicación síncrona (por eso existen los Persistent Disk regionales y la HA regional de Cloud SQL).
- **Multi-región**: un conjunto de regiones usadas como una sola localidad de almacenamiento/servicio (Cloud Storage `US`, Spanner `nam3`, BigQuery `EU`).
- Google Cloud opera actualmente **más de 40 regiones y más de 120 zonas**, además de una red de edge/PoP mucho más grande. La cuenta cambia cada trimestre — la lista autoritativa es `gcloud compute regions list` y la documentación de geografía.

### 6.2 Alcance del recurso y el SLA que compra

| Alcance | Recursos de ejemplo | ¿Sobrevive la pérdida de una **zona**? | ¿Sobrevive la pérdida de una **región**? | SLA publicado representativo |
|---|---|---|---|---|
| **Zonal** | Instancia de VM, PD zonal, MIG zonal, control plane de cluster GKE zonal | ❌ | ❌ | Instancia única de Compute Engine: **99,9%** |
| **Regional** | MIG regional, PD regional, control plane regional de GKE, HA de Cloud SQL, bucket regional de GCS | ✅ | ❌ | Compute Engine, instancias en ≥2 zonas: **99,99%**; control plane regional de GKE: **99,95%** (zonal: 99,5%) |
| **Multi-regional** | Bucket multi-región de GCS, Spanner multi-región, Global Load Balancer externo, Cloud DNS | ✅ | ✅ | GCS Standard multi-región: **99,95%**; Spanner multi-región: **99,999%** |
| **Global** | Red VPC, política de IAM, zona de Cloud DNS, IP anycast del LB HTTP(S) global, imágenes/snapshots | ✅ | ✅ | Varía según el servicio |

> **La aritmética que importa.** Tres VMs zonales en una misma zona te dan 99,9% de disponibilidad, no 99,9997%, porque sus fallas están perfectamente correlacionadas en el límite de la zona. Lo que multiplica es la independencia; compartir un dominio de falla la destruye. Esta es la idea más valiosa de todo este objetivo, y es evaluable en todos los niveles de certificación de Google.

### 6.3 Aritmética del presupuesto de latencia (la razón por la que "usá una sola región" falla)

Velocidad de la luz en fibra ≈ 200.000 km/s ⇒ **~5 µs por km, en un sentido**; **~10 µs por km ida y vuelta**, antes de conmutación, encolamiento y TLS.

| Trayecto | Distancia de círculo máximo | RTT teórico | RTT observado realista |
|---|---|---|---|
| Misma zona (`us-central1-a` ↔ `us-central1-a`) | <1 km | ~0 | **0,1 – 0,3 ms** |
| Entre zonas, misma región (`us-central1-a` ↔ `-c`) | ~10–50 km | 0,1–0,5 ms | **0,3 – 1,0 ms** |
| `us-central1` ↔ `us-east4` | ~1.500 km | 15 ms | **~25 – 35 ms** |
| `us-central1` ↔ `europe-west1` | ~7.000 km | 70 ms | **~95 – 110 ms** |
| `us-central1` ↔ `asia-southeast1` | ~15.500 km | 155 ms | **~180 – 210 ms** |
| `europe-west1` ↔ `australia-southeast1` | ~16.500 km | 165 ms | **~250 – 280 ms** |

Una página que hace **12 llamadas secuenciales** a un backend con una base de datos a 100 ms gasta **1,2 s** solo en velocidad de la luz. Ninguna cantidad de CPU arregla eso. Por eso el "acceso amplio a la red" de NIST se convierte, en la práctica, en *front-end global anycast + backends regionales + una CDN* — y por eso un escenario de examen que menciona "usuarios en Europa se quejan de lentitud mientras la app corre en Iowa" es una pregunta de **ubicación de región / balanceo de carga global**, no de escalado.

Medilo, no lo supongas:

```
$ gcloud compute instances create probe-a --zone=us-central1-a \
    --machine-type=e2-micro --subnet=checkout-us-central1 --no-address
Created [https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-a/instances/probe-a].
NAME     ZONE           MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
probe-a  us-central1-a  e2-micro                   10.20.0.14                RUNNING

$ gcloud compute ssh probe-a --zone=us-central1-a --tunnel-through-iap \
    --command="ping -c 5 -q 10.20.0.27"
PING 10.20.0.27 (10.20.0.27) 56(84) bytes of data.

--- 10.20.0.27 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4006ms
rtt min/avg/max/mdev = 0.412/0.507/0.688/0.094 ms      # <- inter-zone, same region

$ gcloud compute ssh probe-a --zone=us-central1-a --tunnel-through-iap \
    --command="ping -c 5 -q 10.60.1.9"
--- 10.60.1.9 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4007ms
rtt min/avg/max/mdev = 96.214/97.033/98.551/0.812 ms   # <- us-central1 -> europe-west1
```

### 6.4 Enumerar la geografía

```
$ gcloud compute regions list --format="table(name,status,quotas[0].limit:label=CPU_QUOTA)" --limit=8
NAME                     STATUS  CPU_QUOTA
africa-south1            UP      24.0
asia-east1               UP      72.0
asia-northeast1          UP      72.0
asia-south1              UP      24.0
australia-southeast1     UP      24.0
europe-north1            UP      24.0
europe-west1             UP      72.0
us-central1              UP      600.0

$ gcloud compute zones list --filter="region:( us-central1 )" \
    --format="table(name,status,availableCpuPlatforms.list():label=CPU_PLATFORMS)"
NAME           STATUS  CPU_PLATFORMS
us-central1-a  UP      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,AMD Genoa
us-central1-b  UP      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,AMD Genoa
us-central1-c  UP      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Sapphire Rapids,AMD Milan
us-central1-f  UP      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake

$ gcloud compute machine-types list --zones=us-central1-a --filter="name~^n2-standard" \
    --format="table(name,guestCpus,memoryMb)" --limit=5
NAME             CPUS  MEMORY_MB
n2-standard-2    2     8192
n2-standard-4    4     16384
n2-standard-8    8     32768
n2-standard-16   16    65536
n2-standard-32   32    131072
```

Notá que `us-central1-f` no tiene Sapphire Rapids. Si tu MIG fija `--min-cpu-platform="Intel Sapphire Rapids"` y además lista `us-central1-f` en `distribution_policy_zones`, una cuarta parte de tus intentos de scale-out va a fallar. Ese es un bug de capacidad real, común y silencioso.

---

## 7. Economía: capex, opex, TCO y los modelos de precios

### 7.1 Capex vs. opex

| | **Capex** (gasto de capital) | **Opex** (gasto operativo) |
|---|---|---|
| Definición | Compra anticipada de un activo, depreciado a lo largo de su vida útil | Gasto continuo consumido en el período en que se incurre |
| Forma del flujo de caja | Grande, discontinuo, por adelantado | Pequeño, continuo, a posteriori |
| Contabilidad | Balance general; la depreciación impacta el estado de resultados durante 3–5 años | Estado de resultados de inmediato |
| Latencia de decisión | Ciclo de compras: semanas a trimestres | Llamada a la API: segundos |
| Riesgo | El riesgo de pronóstico se asume por adelantado y es irreversible | El riesgo de pronóstico se re-valúa continuamente |
| Análogo en la nube | Servidores físicos, plazo de Bare Metal Solution, licencias on-prem | Compute Engine, Cloud Run, BigQuery bajo demanda |

La nube desplaza capex hacia opex — pero esto es un *desplazamiento*, no un descuento. Los descuentos por uso comprometido son un movimiento deliberado y parcial **de vuelta hacia** el capex (una obligación fija a cambio de una tarifa unitaria menor), que es exactamente el trade correcto para una línea de base genuinamente estable.

### 7.2 Modelos de precios de cómputo

| Modelo | Descuento vs. bajo demanda | Compromiso | Interrumpible | Mejor para |
|---|---|---|---|---|
| **Bajo demanda** | 0% (línea de base) | Ninguno | No | Impredecible, de corta vida, exploratorio |
| **Descuento por uso sostenido (SUD)** | Automático, hasta ~30% (N1) / ~20% (N2, N2D, C2, C2D); **E2 no es elegible** — su precio de lista ya lo refleja | Ninguno — se aplica automáticamente por mes de ejecución | No | Cualquier cosa que quede corriendo la mayor parte de un mes |
| **CUD basado en recursos** | ~37% (1 año) / ~55% (3 años) para propósito general; más en memory-optimized a 3 años | Región + familia de máquina, vCPU y RAM | No | Línea de base estable y bien pronosticada en una región conocida |
| **CUD flexible / basado en gasto** | ~28% (1 año) / ~46% (3 años) | Un piso de gasto en dólares por hora; portable entre regiones y familias elegibles | No | Línea de base que no podés fijar a una sola región o familia |
| **Spot VMs** | 60–91% | Ninguno | **Sí** — aviso de apagado ACPI de 30 s, sin tiempo máximo de ejecución | Batch, CI, renderizado, entrenamiento de ML con checkpointing, desborde sin estado |
| **Free tier / Always Free** | 100% dentro de los límites | Ninguno | No | Aprendizaje, utilidades diminutas siempre encendidas |

> Los porcentajes exactos y la elegibilidad por familia cambian; las tablas de arriba reflejan el comportamiento del precio de lista al momento de escribir. Confirmá siempre contra las páginas de precios enlazadas en la §10 antes de comprometerte a una obligación de tres años.

La estratificación que un equipo de plataforma competente realmente opera:

```
   Fleet capacity
   ▲
   │  ░░░░░░░░░░░░░░░░  Spot          (batch + burst overflow, 60–91% off)
   │  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  On-demand     (headroom above the committed floor)
   │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  3-yr CUD      (the true 24/7/365 baseline, ~55% off)
   └──────────────────────────────────────────────────────────► time
     Commit ONLY to the p5 of your annual load, never the p50.
```

Comprometerse a la mediana es el autogol clásico de FinOps: un compromiso sin usar se factura igual, así que un sobrecompromiso es capex sin ninguno de sus valores residuales.

### 7.3 Una comparación de TCO trabajada

*Escenario:* una carga que requiere 200 vCPU / 800 GiB en régimen estable, con picos de hasta 400 vCPU durante ~6 h/día, más una capa de batch nocturno, 20 TiB de almacenamiento en bloque, 100 TiB de almacenamiento de objetos de archivo y 15 TiB/mes de egress a internet.

**Opción A — on-premises (amortización a 4 años):**

| Concepto | Base | Anual |
|---|---|---|
| Servidores (20 × 2 sockets, 48 cores, 512 GiB) | $18.000 cada uno, lineal a 4 años | $90.000 |
| Arreglo de almacenamiento + fabric SAN | $260.000, a 5 años | $52.000 |
| Red (ToR, spine, firewalls) | $160.000, a 5 años | $32.000 |
| Colocation: 3 racks, energía, refrigeración | $2.500/rack/mes | $90.000 |
| Licencias de hypervisor + backup + monitoreo | Renovación | $35.000 |
| Personal de operaciones de infraestructura | 1,5 FTE @ $120k costo total | $180.000 |
| Sitio de DR (frío, 40% del primario) | | $58.000 |
| **Total** | | **≈ $537.000/año** |
| **Utilización promedio efectiva** | Dimensionado para el pico | **≈ 28%** |
| **Costo por vCPU-hora entregada** | | **≈ $0,35** |

**Opción B — Google Cloud, con ingeniería (no lift-and-shift):**

| Concepto | Configuración | Anual |
|---|---|---|
| Cómputo de línea de base | 12 × `n2-standard-16`, CUD por recursos a 3 años (~55% de descuento ≈ $255/mes cada uno) | $36.720 |
| Cómputo de pico | 8 × `n2-standard-16`, bajo demanda @ ~$0,777/h, 6 h/día | $13.430 |
| Capa de batch | 5 × `n2-standard-16` **Spot** @ ~70% de descuento, 24/7 | $10.210 |
| Almacenamiento en bloque | 20 TiB de Balanced PD @ ~$0,10/GiB-mes | $24.576 |
| Almacenamiento de objetos | 100 TiB Nearline @ ~$0,010/GiB-mes | $12.288 |
| **Egress a internet** | 15 TiB/mes, nivel Premium (10 TiB @ $0,12 + 5 TiB @ $0,11) | **$21.500** |
| Enhanced Support | Base + % del gasto | ≈ $9.000 |
| Ingeniería de plataforma | 0,5 FTE @ $150k — **la nube cambia las operaciones, no las elimina** | $75.000 |
| **Total** | | **≈ $202.700/año** |
| **Utilización promedio efectiva** | Autoescalada | **≈ 65%** |
| **Costo por vCPU-hora entregada** | | **≈ $0,06** |

**Opción C — la misma carga migrada tal cual, sin rediseño:** 20 × `n2-standard-16` corriendo 24/7 bajo demanda sin CUD, sin Spot, sin autoscaling, más el mismo almacenamiento, egress y soporte ≈ **$228.000/año solo en cómputo**, total ≈ **más de $300.000**. Sigue siendo más barato que on-prem, pero renuncia a aproximadamente la mitad del ahorro disponible y agrega una línea de egress que el datacenter nunca tuvo.

**Las tres conclusiones para llevarse al examen y a un caso de negocio real:**

1. El TCO debe incluir **personas, instalaciones, licencias, DR y el costo de la capacidad ociosa** — comparar el precio de un servidor contra el precio de una VM no es un TCO.
2. El ahorro proviene de **eliminar la capacidad ociosa**, no de un cómputo más barato por hora. Si no autoescalás, no migraste; alquilaste los servidores ociosos de otro.
3. **El egress y el personal son las dos líneas que todo modelo ingenuo omite**, y son las dos que con más frecuencia convierten un ahorro proyectado en un empate proyectado.

### 7.4 Egress: la línea de costo sin ninguna funcionalidad asociada

| Trayecto de tráfico | Precio de lista aproximado | Consecuencia arquitectónica |
|---|---|---|
| Misma zona, IP interna | **Gratis** | Coubicá los servicios conversadores en una zona — y después distribuí las *réplicas* entre zonas para disponibilidad |
| Entre zonas, misma región | ~$0,01/GiB en cada dirección | Un service mesh entre zonas con mTLS y reintentos puede costar en silencio más que el cómputo |
| Entre regiones, mismo continente | ~$0,02–$0,05/GiB | La replicación entre regiones es una línea de presupuesto, no una casilla de verificación |
| Entre continentes | ~$0,05–$0,15/GiB | La gravedad de los datos es real: movés el cómputo hacia los datos, nunca los datos hacia el cómputo |
| Egress a internet, nivel Premium | ~$0,12/GiB (0–10 TiB), ~$0,11 (10–150 TiB), ~$0,08 (>150 TiB) | Poné una CDN delante de todo lo que sea cacheable |
| **Ingress** desde internet | **Gratis** | Las subidas son gratis; la asimetría condiciona muchos diseños |
| Egress para llenado de caché de Cloud CDN | Tarifa reducida de cache-fill | La tasa de aciertos de caché es un KPI de *costo*, no solo de latencia |
| Egress al **migrar fuera** de Google Cloud | **Gratis**, a pedido | Reduce materialmente el argumento del lock-in — confirmá los términos vigentes |

Barreras de protección, expresadas como un presupuesto con alertas programáticas:

```
$ gcloud billing budgets create \
    --billing-account=0123AB-4567CD-89EFGH \
    --display-name="acme-prod egress guardrail" \
    --budget-amount=2500USD \
    --filter-projects=projects/471829304517 \
    --filter-services=services/E505-1370-73D6 \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.9 \
    --threshold-rule=percent=1.0,basis=forecasted-spend \
    --all-updates-rule-pubsub-topic=projects/acme-prod-platform/topics/billing-alerts \
    --all-updates-rule-monitoring-notification-channels=projects/acme-prod-platform/notificationChannels/8827441905663210
Created budget [billingAccounts/0123AB-4567CD-89EFGH/budgets/9d1e77a4-3b0c-4f22-9a86-5e2c1f7b4d33].
```

Fijate en `basis=forecasted-spend` en la regla del 100%. Alertar sobre el gasto *real* al 100% te avisa que la plata ya se fue; alertar sobre el *pronóstico* te avisa que está por irse.

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Verificar que la elasticidad es real

```
$ gcloud compute instance-groups managed describe checkout-api-mig \
    --region=us-central1 \
    --format="yaml(name,targetSize,status.isStable,currentActions,distributionPolicy.zones)"
currentActions:
  abandoning: 0
  creating: 0
  deleting: 0
  none: 6
  recreating: 0
  refreshing: 0
  restarting: 0
  verifying: 0
distributionPolicy:
  zones:
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-a
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-b
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-c
  - zone: https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-f
name: checkout-api-mig
status:
  isStable: true
targetSize: 6
```

Aplicá carga, después confirmá que el autoscaler se movió y **que las instancias nuevas aterrizaron en zonas distintas**:

```
$ gcloud compute instance-groups managed list-instances checkout-api-mig \
    --region=us-central1 --format="table(name,zone.basename(),status,instanceHealth[0].detailedHealthState)"
NAME                ZONE           STATUS   DETAILED_HEALTH_STATE
checkout-api-4f2q   us-central1-a  RUNNING  HEALTHY
checkout-api-7k9m   us-central1-a  RUNNING  HEALTHY
checkout-api-b1xd   us-central1-b  RUNNING  HEALTHY
checkout-api-c8vr   us-central1-b  RUNNING  HEALTHY
checkout-api-h3lp   us-central1-c  RUNNING  HEALTHY
checkout-api-m5tw   us-central1-c  RUNNING  HEALTHY
checkout-api-q0zn   us-central1-f  RUNNING  HEALTHY
checkout-api-r6ya   us-central1-f  RUNNING  HEALTHY
checkout-api-s2jc   us-central1-a  RUNNING  TIMEOUT
checkout-api-t9wp   us-central1-b  RUNNING  HEALTHY
```

Un `TIMEOUT` es el auto-healer a punto de hacer su trabajo. Diez instancias repartidas parejo sobre cuatro zonas es como se ve "agrupamiento de recursos + elasticidad rápida + conciencia de dominios de falla" cuando es verdad y no una afirmación.

En GKE:

```
$ kubectl get pods -n checkout -o custom-columns=\
NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.phase
NAME                            NODE                                       ZONE           STATUS
checkout-api-6d4f8b9c7-2xkqz    gke-prod-default-pool-a1b2c3-9f4k          us-central1-a  Running
checkout-api-6d4f8b9c7-5mn8v    gke-prod-default-pool-d4e5f6-2p7r          us-central1-b  Running
checkout-api-6d4f8b9c7-7rt2w    gke-prod-default-pool-g7h8i9-6t1x          us-central1-c  Running
checkout-api-6d4f8b9c7-9wq4x    gke-prod-default-pool-a1b2c3-3m8n          us-central1-a  Running
checkout-api-6d4f8b9c7-bk7pl    gke-prod-default-pool-d4e5f6-8s2y          us-central1-b  Running
checkout-api-6d4f8b9c7-dz3hc    gke-prod-default-pool-g7h8i9-4v9z          us-central1-c  Running

$ kubectl get hpa checkout-api -n checkout
NAME           REFERENCE                 TARGETS                        MINPODS  MAXPODS  REPLICAS  AGE
checkout-api   Deployment/checkout-api   cpu: 41%/60%, 78/120 (avg)     6        60       6         14d

$ kubectl get pdb -n checkout
NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
checkout-api   4               N/A               2                     14d
```

### 8.2 Catálogo de fallas

#### F1 — Agotamiento de recursos zonales (un stockout, no un problema de cuota)

```
$ gcloud compute instances create burst-01 --zone=us-central1-a \
    --machine-type=c3-highmem-176 --project=acme-prod-platform
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - The zone 'projects/acme-prod-platform/zones/us-central1-a' does not have enough
   resources available to fulfill the request. '(resource type:compute)'.
   ZONE_RESOURCE_POOL_EXHAUSTED
```

**Diagnóstico:** esto no es tu cuota. Es capacidad física para esa familia de máquina en esa zona en ese momento.
**Solución, en orden de preferencia:**
1. Usá un MIG **regional** con múltiples zonas para que la API reintente en otra automáticamente — esa es la razón entera por la que existen los MIG regionales.
2. Relajá la familia de máquina (`c3` → `n2`/`n2d`) o la forma (menos y más grandes vs. más y más chicas).
3. Para capacidad garantizada, comprá una **reserva futura** o una reserva bajo demanda.
4. Nunca trates "reintentar en bucle contra la misma zona" como una mitigación.

```
$ gcloud compute reservations create checkout-peak-nov \
    --zone=us-central1-b --vm-count=40 \
    --machine-type=n2-standard-16 --require-specific-reservation
Created [https://www.googleapis.com/compute/v1/projects/acme-prod-platform/zones/us-central1-b/reservations/checkout-peak-nov].
```

#### F2 — Techo de cuota limitando la elasticidad en silencio

```
$ gcloud compute instances create burst-42 --zone=us-central1-a --machine-type=n2-standard-16
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Quota 'N2_CPUS' exceeded. Limit: 600.0 in region us-central1.

$ gcloud compute regions describe us-central1 \
    --format="table(quotas.metric,quotas.usage,quotas.limit)" | grep -E "N2_CPUS|IN_USE_ADDRESSES"
N2_CPUS                600.0   600.0
IN_USE_ADDRESSES        32.0    64.0
```

**Diagnóstico:** la "apariencia de capacidad ilimitada" de la definición de elasticidad rápida de NIST está acotada por cuotas por proyecto y por región. Los autoscalers **no** te avisan con anticipación; simplemente dejan de crecer mientras tu SLO de latencia se consume.
**Solución:** alertá sobre la utilización de cuota como un SLI de primera clase (`serviceruntime.googleapis.com/quota/allocation/usage` en Cloud Monitoring), y pedí los aumentos antes de la temporada pico, no durante.

#### F3 — Costo de egress entre zonas por un diseño "de alta disponibilidad"

Síntoma: la línea de Networking en la exportación de facturación crece al mismo paso que el volumen de solicitudes, sin tráfico de internet que lo explique.

```sql
SELECT sku.description, ROUND(SUM(cost),2) AS usd, ROUND(SUM(usage.amount)/POW(1024,3),1) AS gib
FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_0123AB_4567CD_89EFGH`
WHERE service.description = 'Networking'
  AND DATE(_PARTITIONTIME) BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY 1 ORDER BY usd DESC LIMIT 5;
```
```
+---------------------------------------------------------------+---------+----------+
| sku.description                                               | usd     | gib      |
+---------------------------------------------------------------+---------+----------+
| Network Inter Zone Data Transfer Out                          | 4128.77 | 412877.0 |
| Network Internet Egress from Americas to Americas             | 1791.36 |  15360.0 |
| Network Inter Region Data Transfer Out (Americas to Americas)  |  612.44 |  12248.8 |
+---------------------------------------------------------------+---------+----------+
```

**Diagnóstico:** una capa sin estado repartida en tres zonas hablando con una capa de caché también repartida en tres zonas manda ~2/3 de su tráfico cruzando un límite de zona por pura probabilidad.
**Solución:** habilitá el enrutamiento consciente de la topología para que un cliente prefiera un endpoint de la misma zona, manteniendo el cruce de zonas como failover.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-cache
  namespace: checkout
spec:
  selector:
    app.kubernetes.io/name: redis-cache
  ports:
    - port: 6379
      targetPort: 6379
  # Prefer endpoints in the same zone; fall back to the whole region if none are ready.
  trafficDistribution: PreferClose
```

#### F4 — Arranques en frío culpados a la capa equivocada

```
$ gcloud logging read \
    'resource.type="cloud_run_revision" AND
     resource.labels.service_name="checkout-api" AND
     httpRequest.latency>="2s"' \
    --limit=3 --format="table(timestamp,httpRequest.latency,labels.instanceId,textPayload)"
TIMESTAMP                       LATENCY   INSTANCE_ID                                TEXT_PAYLOAD
2026-09-05T03:14:22.881443Z     3.412s    00bf4b2f8d9c1a...  Default STARTUP TCP probe succeeded after 1 attempt
2026-09-05T03:14:19.204118Z     2.887s    00bf4b2f8d9c1a...  Container called exit(0) — scaled to zero
2026-09-05T02:58:41.663902Z     2.104s    00c71e3a5f2b8e...  Default STARTUP TCP probe succeeded after 1 attempt
```

**Diagnóstico:** los picos de latencia p99 se correlacionan perfectamente con valores nuevos de `instanceId`. Esto es escalado desde cero, no una base de datos lenta.
**Solución (y el compromiso que estás eligiendo):**

| Palanca | Efecto | Costo |
|---|---|---|
| `minScale: 2` | Elimina el arranque en frío para las primeras 2 solicitudes concurrentes | Pagás 2 instancias ociosas 24/7 — renunciaste al escalado a cero |
| `startup-cpu-boost: true` | CPU extra solo durante la inicialización | Bajo |
| Imagen más liviana (distroless, capas más chicas) | Descarga y arranque más rápidos | Tiempo de ingeniería |
| `containerConcurrency` más alto | Menos instancias, menos arranques en frío | Mayor radio de impacto por instancia; latencia de cola bajo carga |

#### F5 — "Es una caída zonal" — secuencia de triage

```
$ gcloud compute operations list --filter="operationType~compute.instances AND status!=DONE" --limit=5
NAME                                     TYPE                       TARGET             STATUS
operation-1757043221-62f1a8b0c4d21-...   compute.instances.insert   burst-88           RUNNING

$ gcloud compute instances list --filter="zone:us-central1-a" \
    --format="table(name,status,lastStartTimestamp)" | head -5
NAME               STATUS       LAST_START_TIMESTAMP
checkout-api-4f2q  TERMINATED   2026-09-05T02:41:09.442-07:00
checkout-api-7k9m  TERMINATED   2026-09-05T02:41:11.083-07:00
checkout-api-s2jc  TERMINATED   2026-09-05T02:41:12.771-07:00

$ curl -s https://status.cloud.google.com/incidents.json | \
    jq -r '.[] | select(.end == null) | "\(.begin)  \(.service_name)  \(.external_desc[0:80])"'
2026-09-05T09:38:00Z  Google Compute Engine  We are investigating an issue with Compute Engine in us-central1-a affecting...
```

**Playbook:**
1. Confirmá que el radio de impacto es una zona (no una familia de máquina, no un proyecto).
2. Confirmá que el MIG regional / control plane regional de GKE está redistribuyendo — la capacidad debería reaparecer en las zonas sobrevivientes automáticamente.
3. Confirmá que el balanceador de carga **quitó** los backends fallidos (el conteo de `HEALTHY` debería bajar, no fallar las solicitudes).
4. Verificá tus dependencias de alcance zonal: PD zonal, Cloud SQL zonal, NFS zonal, una instancia de Memorystore de una sola zona. **Estas son las cosas que no hacen failover, y siempre son la razón por la que el diseño "regional" igual se cayó.**
5. Post-incidente: cada recurso zonal en la ruta crítica se convierte en un ticket de actualización a regional.

```
$ gcloud compute backend-services get-health checkout-api-backend --global \
    --format="table(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)"
INSTANCE            HEALTH_STATE
checkout-api-b1xd   HEALTHY
checkout-api-c8vr   HEALTHY
checkout-api-h3lp   HEALTHY
checkout-api-m5tw   HEALTHY
checkout-api-q0zn   HEALTHY
checkout-api-r6ya   HEALTHY
checkout-api-4f2q   UNHEALTHY
```

#### F6 — Brecha de responsabilidad compartida encontrada en una auditoría

```
$ gcloud scc findings list organizations/613295847201 \
    --filter="state=\"ACTIVE\" AND category=\"PUBLIC_BUCKET_ACL\"" \
    --format="table(finding.category,finding.resourceName,finding.severity)"
CATEGORY            RESOURCE_NAME                                              SEVERITY
PUBLIC_BUCKET_ACL   //storage.googleapis.com/projects/_/buckets/acme-exports   HIGH
```

**Diagnóstico:** esto es 100% responsabilidad del cliente en todos los modelos de servicio. Google cifró el objeto en reposo y aseguró el datacenter; vos le diste lectura a `allUsers`.
**Solución y prevención (la jugada de destino compartido — hacerlo estructuralmente imposible, no meramente prohibido):**

```
$ gcloud storage buckets update gs://acme-exports --no-public-access-prevention --dry-run
$ gcloud storage buckets update gs://acme-exports --public-access-prevention
Updating gs://acme-exports/...
  Completed 1

$ gcloud resource-manager org-policies enable-enforce \
    storage.publicAccessPrevention --organization=613295847201
Enabled constraint [constraints/storage.publicAccessPrevention] on [organizations/613295847201].
```

### 8.3 Checklist de preproducción para este objetivo

| # | Verificación | Comando / artefacto | Condición de aprobación |
|---|---|---|---|
| 1 | Ninguna ruta crítica en una sola zona | `gcloud compute instances list --format="value(zone)" \| sort \| uniq -c` | Cada capa presente en ≥2 zonas |
| 2 | Control plane regional en GKE | `gcloud container clusters describe … --format="value(location)"` | El valor es una **región**, no una zona |
| 3 | El PDB no bloquea un drain de nodo | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS ≥ 1` para toda carga de trabajo |
| 4 | Techo del autoscaler por encima del pico pronosticado | `gcloud compute region-autoscalers describe …` | `maxReplicas ≥ 1,5 × pico pronosticado` |
| 5 | Margen de cuota por encima del techo | `gcloud compute regions describe <r>` | Uso/límite < 70% en el pico pronosticado |
| 6 | Todo recurso etiquetado para atribución de costos | Consulta de exportación de facturación, §2.1 | ≥95% del gasto lleva una etiqueta `team` |
| 7 | Presupuesto con alerta de **gasto pronosticado** | `gcloud billing budgets list` | Al menos una regla usa `basis=forecasted-spend` |
| 8 | Política de residencia de datos aplicada en la API | `gcloud org-policies describe gcp.resourceLocations …` | Crear fuera de la región devuelve un código distinto de cero |
| 9 | Sin IPs públicas salvo justificación | `constraints/compute.vmExternalIpAccess` | Aplicada con una allowlist explícita |
| 10 | El compromiso coincide con la línea de base real | Informe de utilización de CUD | Utilización ≥ 95%, y compromiso ≤ carga anual p5 |

---

## 9. Distinciones enfocadas en el examen

Estas son las confusiones que efectivamente cuestan puntos.

| Si la pregunta dice… | Está evaluando… | Respondé con… |
|---|---|---|
| "aprovisionar sin contactar al proveedor" | Autoservicio bajo demanda | Autoservicio por consola/API/CLI |
| "parece ilimitado, escala en minutos" | Elasticidad rápida | Autoscaling |
| "multi-tenant, recursos asignados dinámicamente" | Agrupamiento de recursos | Infraestructura física compartida, abstracción de ubicación |
| "pagar solo por lo que se usa, el uso se reporta" | Servicio medido | Facturación por segundo, exportación de facturación |
| "acceso desde laptops, teléfonos y tablets con protocolos estándar" | Acceso amplio a la red | Acceso estándar HTTP(S)/API |
| "necesitamos root y un módulo de kernel personalizado" | Modelo de servicio | **IaaS** |
| "queremos desplegar código y nunca ver un servidor" | Modelo de servicio | **PaaS** / serverless |
| "compramos una licencia por usuario y la configuramos" | Modelo de servicio | **SaaS** |
| "algunas cargas se quedan en nuestro datacenter permanentemente" | Modelo de despliegue | **Híbrido** |
| "corremos en Google Cloud y en AWS" | Modelo de despliegue | **Multicloud** |
| "el regulador exige aislamiento físico / air-gap" | Modelo de despliegue | **Privado** (Google Distributed Cloud, sole-tenant nodes) |
| "¿quién parchea el SO invitado en una VM?" | Responsabilidad compartida | **El cliente** |
| "¿quién asegura el datacenter?" | Responsabilidad compartida | **Google** |
| "¿quién clasifica y protege los datos?" | Responsabilidad compartida | **El cliente, siempre** |
| "Google nos ayuda a ser seguros por defecto y comparte el riesgo" | **Destino compartido** | Blueprints, Assured Workloads, Risk Protection Program |
| "la app debe sobrevivir la pérdida de un datacenter en la misma ciudad" | Geografía | Múltiples **zonas** en una región |
| "la app debe sobrevivir la pérdida de un área geográfica entera" | Geografía | Múltiples **regiones** / recursos multi-región |
| "usuarios en todo el mundo, un solo endpoint" | Geografía + red | **Application Load Balancer externo global** (anycast) |
| "compramos servidores por adelantado y los depreciamos" | Economía | **Capex** |
| "pagamos mensualmente por lo que consumimos" | Economía | **Opex** |
| "línea de base estable 24/7, queremos la tarifa más baja" | Precios | **Descuento por uso comprometido** |
| "trabajo batch, reiniciable, lo más barato posible" | Precios | **Spot VMs** |
| "dejamos la VM corriendo todo el mes y nos dieron un descuento automáticamente" | Precios | **Descuento por uso sostenido** |
| "comparar el costo total incluyendo personal, energía y licencias" | Economía | **TCO** |

---

## 10. Referencias

**Examen y certificación**
- Guía del examen Cloud Digital Leader (PDF, lista autoritativa de objetivos): https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Página de la certificación Cloud Digital Leader: https://cloud.google.com/learn/certification/cloud-digital-leader

**Definiciones fundacionales**
- NIST SP 800-145, *The NIST Definition of Cloud Computing*: https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-145.pdf
- Qué es la computación en la nube (Google Cloud): https://cloud.google.com/learn/what-is-cloud-computing
- IaaS vs. PaaS vs. SaaS: https://cloud.google.com/learn/paas-vs-iaas-vs-saas
- Híbrido y multicloud: https://cloud.google.com/learn/what-is-hybrid-cloud

**Geografía, regiones, zonas, confiabilidad**
- Geografía y regiones de Google Cloud: https://cloud.google.com/docs/geography-and-regions
- Regiones y zonas (Compute Engine): https://cloud.google.com/compute/docs/regions-zones
- Recursos globales, regionales y zonales: https://cloud.google.com/compute/docs/regions-zones/global-regional-zonal-resources
- Regiones con el menor impacto de carbono: https://cloud.google.com/sustainability/region-carbon
- Architecture Framework — Confiabilidad: https://cloud.google.com/architecture/framework/reliability
- Guía de planificación de recuperación ante desastres: https://cloud.google.com/architecture/dr-scenarios-planning-guide

**Acuerdos de nivel de servicio**
- Todos los SLA de Google Cloud: https://cloud.google.com/terms/sla/
- SLA de Compute Engine: https://cloud.google.com/compute/sla
- SLA de Google Kubernetes Engine: https://cloud.google.com/kubernetes-engine/sla
- SLA de Cloud Storage: https://cloud.google.com/storage/sla
- SLA de Cloud Run: https://cloud.google.com/run/sla
- Panel de estado de servicios de Google Cloud: https://status.cloud.google.com/

**Responsabilidad compartida y destino compartido**
- Responsabilidad compartida y destino compartido en Google Cloud: https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Architecture Framework — Seguridad, privacidad y cumplimiento: https://cloud.google.com/architecture/framework/security
- Descripción general de Assured Workloads: https://cloud.google.com/assured-workloads/docs/overview
- Risk Protection Program: https://cloud.google.com/security/products/risk-protection-program
- Descripción general de Security Command Center: https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Cifrado en reposo (whitepaper): https://cloud.google.com/docs/security/encryption/default-encryption

**Modelos de despliegue y conectividad**
- Descripción general de GKE Enterprise (Anthos): https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Google Distributed Cloud: https://cloud.google.com/distributed-cloud/docs
- Sole-tenant nodes: https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes
- Bare Metal Solution: https://cloud.google.com/bare-metal/docs
- Descripción general del producto Network Connectivity: https://cloud.google.com/network-connectivity/docs
- Descripción general de Cloud Interconnect: https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- Cross-Cloud Interconnect: https://cloud.google.com/network-connectivity/docs/interconnect/concepts/cross-cloud-interconnect
- Topologías de HA VPN: https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies

**Economía, precios y FinOps**
- Descripción general de precios de Google Cloud: https://cloud.google.com/pricing
- Calculadora de precios: https://cloud.google.com/products/calculator
- Descuentos por uso comprometido: https://cloud.google.com/docs/cuds
- Descuentos por uso sostenido: https://cloud.google.com/compute/docs/sustained-use-discounts
- Spot VMs: https://cloud.google.com/compute/docs/instances/spot
- Programa gratuito de Google Cloud (Always Free): https://cloud.google.com/free/docs/free-cloud-features
- Precios de red VPC (egress y transferencia de datos): https://cloud.google.com/vpc/network-pricing
- Exportar datos de Cloud Billing a BigQuery: https://cloud.google.com/billing/docs/how-to/export-data-bigquery
- Crear, editar o eliminar presupuestos y alertas de presupuesto: https://cloud.google.com/billing/docs/how-to/budgets
- Architecture Framework — Optimización de costos: https://cloud.google.com/architecture/framework/cost-optimization

**Elasticidad, escalado y aplicación de políticas**
- Autoscaling de grupos de instancias: https://cloud.google.com/compute/docs/autoscaler
- Grupos de instancias administrados regionales: https://cloud.google.com/compute/docs/instance-groups/regional-migs
- Cluster autoscaler de GKE: https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler
- Descripción general de GKE Autopilot: https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview
- Cloud Run: acerca del autoscaling de instancias: https://cloud.google.com/run/docs/about-instance-autoscaling
- Introducción al servicio de Organization Policy: https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Restringir ubicaciones de recursos: https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
- Trabajar con cuotas: https://cloud.google.com/docs/quotas/view-manage
- Reservas de Compute Engine: https://cloud.google.com/compute/docs/instances/reservations-overview