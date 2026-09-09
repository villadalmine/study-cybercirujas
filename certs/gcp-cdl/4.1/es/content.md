# 4.1 — Cómo Google Cloud ayuda a las organizaciones a hacer la transición a la nube

**Certificación:** Google Cloud Digital Leader (versión del examen 2026-08-12)
**Peso del dominio:** 6.0
**Perfil de lectura:** Platform Architect / SRE. El examen pregunta esto a nivel de resultado de negocio; este material enseña la maquinaria que hay debajo, para que la respuesta de negocio sea una que puedas defender en una revisión de diseño.

---

## 1. Motivación: el problema arquitectónico que realmente es una "transición a la nube"

Una migración casi nunca es un problema tecnológico aislado. Es un **problema de grafo de dependencias ejecutado bajo un congelamiento de cambios, con un reloj de rollback corriendo**.

Considerá el caso canónico de producción. Una organización opera 1.400 VMs repartidas en tres clusters de VMware en dos instalaciones de colocation. El almacenamiento son 800 TB sobre NFS e iSCSI. Las bases de datos son 60 instancias de MySQL 8.0, 22 instancias de PostgreSQL 14 y un par Oracle RAC que nadie tiene permitido tocar. Hay una WAN MPLS, un par de balanceadores de carga físicos y un HSM por hardware. Restricciones de negocio: el leasing del hardware vence en 14 meses, la ventana de cierre financiero prohíbe cambios durante 5 días hábiles al mes, y el servicio de pagos tiene un SLO de disponibilidad del 99,95% con un error budget de 21,6 min/mes.

El encuadre ingenuo — "mover las VMs" — falla en cuatro frentes que todo programa real enfrenta:

| Modo de falla | Síntoma concreto | Causa raíz |
|---|---|---|
| **Grafo de dependencias desconocido** | Una app se mueve limpiamente; un job batch en un datacenter *distinto* se rompe a las 02:00 porque montaba un export NFS por IP. | El descubrimiento fue basado en inventario (una CMDB), no en tráfico. Nadie capturó los flujos L4. |
| **Inversión de latencia / split-brain** | Capa de aplicación en Google Cloud, base de datos todavía on-prem. El p99 pasa de 40 ms a 900 ms. | Un ORM charlatán que emite 300 round trips por request ahora paga 12 ms de RTT por salto en lugar de 0,2 ms. |
| **Gravedad de datos** | 800 TB sobre un enlace de 1 Gbps son ~74 días al 100% de utilización — y la fuente sigue cambiando. | El método de transferencia se eligió sin calcular el tiempo de transferencia contra la tasa de delta. |
| **Deuda de gobernanza materializándose a escala** | 300 proyectos creados ad hoc; sin IAM consistente, sin org policy, IPs públicas por todas partes, seis meses de remediación. | La landing zone se retrofiteó en lugar de ser el primer entregable. |

La respuesta de Google Cloud no es un solo producto. Es un **modelo de programa por etapas con herramientas asociadas a cada etapa**, y el examen espera que sepas nombrar la etapa y la herramienta.

### Las cuatro fases

```
   ASSESS            PLAN              DEPLOY             OPTIMIZE
   ──────            ────              ──────             ────────
 Inventory        Landing zone      Move workloads      Rightsize
 Dependencies     Identity          Move data           Autoscale
 TCO baseline     Network design    Cut over            Commit discounts
 Fit analysis     Resource hier.    Validate            Modernize further
 Skills gap       Migration waves   Rollback ready      SLO/error budget

 Migration        Cloud Setup /     M2VM, M2C, DMS,     Active Assist,
 Center,          landing-zone      Storage Transfer,   Recommender,
 StratoZone       blueprints,       Transfer Appliance, CUDs, FinOps Hub,
 discovery        Terraform CFT     BigQuery DTS        GKE Autopilot
```

Dos marcos ortogonales lo acompañan, y ambos son directamente examinables:

- **Google Cloud Adoption Framework (CAF)** — mide la preparación *organizacional* en cuatro temas (**Learn, Lead, Scale, Secure**) a lo largo de tres fases de madurez (**Tactical → Strategic → Transformational**). Salida: un conjunto de *epics* (líneas de trabajo) para cerrar las brechas.
- **CAMP** — el modelo cultural/DevOps: **C**ulture, **A**utomation, **M**easurement, **S**haring. Aquí es donde la práctica de SRE (SLOs, error budgets, postmortems sin culpa, reducción de toil) entra formalmente en el programa de migración.

> **Encuadre de examen:** CAF mide la *preparación*; las cuatro fases describen la *ejecución*. Una pregunta que dice "el CTO quiere saber si la organización está lista" apunta a CAF. Una pregunta que dice "el equipo tiene un inventario y necesita mover 400 VMs" apunta al herramental de Assess→Deploy.

---

## 2. Estrategia de migración: la tabla de trade-offs que tenés que poder reproducir

La guía de Google nombra cuatro caminos principales (las "6 R" de la industria se colapsan en estos más *retire* y *retain*):

| Estrategia | Término de Google | Qué cambia | Tiempo hasta el primer workload | Costo del cambio | Beneficio cloud-native obtenido | Falla típica |
|---|---|---|---|---|---|---|
| **Rehost** | Lift and shift | Nada por encima del hipervisor | Días–semanas | El más bajo | El más bajo — pagás precios de nube por una arquitectura de datacenter | "Lift and shift y olvidarse": 3× la factura, nada de elasticidad |
| **Replatform** | Move and improve *(o improve and move)* | Cambio a runtime/DB gestionados; código de la app casi intacto | Semanas–meses | Medio | Medio–alto: parcheo, HA, backup pasan a ser gestionados | Incompatibilidades ocultas (stored procs, supuestos sobre el filesystem) |
| **Refactor / re-architect** | Rip and replace / *invent* | Aplicación descompuesta; a menudo hacia contenedores o serverless | Meses–trimestres | El más alto | El más alto | Explosión de alcance; se pierde la fecha límite de la migración mientras ocurre una reescritura |
| **Retire** | — | Workload eliminado | Inmediato | Negativo (ahorro) | N/A | Nadie es dueño de la decisión; queda "por las dudas" |
| **Retain** | — | Se queda on-prem / híbrido | N/A | N/A | N/A vía runtime híbrido (GKE Enterprise) | Se vuelve un ancla de latencia permanente para todo lo demás |

**La regla del arquitecto:** la estrategia se elige *por workload*, no por programa, y la elección es función de tres entradas medibles — **tiempo restante de leasing/refresh**, **presupuesto de cambio** y **fan-in de dependencias**.

### Heurística de decisión (usable en producción)

```
if workload has no owner and <1 request/day for 90 days      -> RETIRE
elif regulatory/hardware pin (HSM, licence, latency <2ms)    -> RETAIN (hybrid via GKE Enterprise)
elif deadline < 6 months and dependency fan-in > 10          -> REHOST  (then replatform in Optimize)
elif stateful managed equivalent exists (MySQL/PG/Redis/Kafka)-> REPLATFORM (Cloud SQL / Memorystore / Managed Kafka)
elif team owns the code AND release cadence > weekly         -> REFACTOR (GKE / Cloud Run)
else                                                          -> REHOST
```

Notá la implicancia de secuenciamiento: **rehost primero, modernizar después** no es pereza, es gestión del error budget. No querés dos fuentes simultáneas de fallas novedosas (infraestructura nueva *y* topología de aplicación nueva) compartiendo una misma ventana de rollback.

### Herramienta de Google Cloud por estrategia

| Estrategia | Herramienta principal de Google | Secundaria |
|---|---|---|
| Rehost (VMware/AWS/Azure/físico → Compute Engine) | **Migrate to Virtual Machines (M2VM)** | Google Cloud VMware Engine (rehost *con* vSphere intacto) |
| Rehost sin re-IP | **Google Cloud VMware Engine (GCVE)** | Cloud Interconnect + HCX |
| Replatform (DB) | **Database Migration Service (DMS)** | Datastream (CDC hacia BigQuery), `pg_dump`/`mysqldump` para movidas en frío |
| Replatform (app → contenedor, sin reescritura) | **Migrate to Containers (M2C)** | Cloud Build + Artifact Registry |
| Refactor | GKE / GKE Autopilot / Cloud Run / Cloud Functions | Apigee para descomposición API-first |
| Datos en bloque | **Storage Transfer Service**, **Transfer Appliance**, BigQuery Data Transfer Service | `gcloud storage rsync`, Datastream |
| Híbrido / retain | **GKE Enterprise** (fleets, Config Sync, Cloud Service Mesh) | Cloud Interconnect, Network Connectivity Center |

---

## 3. Fase 1 — ASSESS: descubrimiento que produce un plan defendible

### 3.1 Migration Center

Migration Center es el servicio de evaluación gratuito y de primera parte (construido sobre la adquisición de StratoZone). Provee:

- **Inventario de activos** — desde un *discovery client* desplegado, desde exportaciones de vCenter/AWS/Azure, o desde importación manual de CSV/RVTools.
- **Recolección a nivel de guest** — software instalado, procesos en ejecución, puertos abiertos, series temporales de utilización de CPU/memoria/disco.
- **Mapeo de dependencias de red** — flujos L4 observados, que es la única forma confiable de construir *olas* de migración.
- **Análisis de encaje (fit assessment)** — qué VMs encajan en familias de máquinas de Compute Engine, cuáles en sole-tenant, cuáles en GKE.
- **Reportes de TCO / precios** — impulsados por *preference sets* (nivel de compromiso, región, modelo de licencia, agresividad del dimensionamiento).

Modelo de costo: la evaluación es sin cargo; solo pagás por lo que eventualmente ejecutés.

### 3.2 Recorrido por CLI

```bash
$ gcloud config set project acme-migration-prog
Updated property [core/project].

$ gcloud services enable migrationcenter.googleapis.com \
    compute.googleapis.com \
    cloudresourcemanager.googleapis.com
Operation "operations/acat.p2-812394871-3f1c9e0d-..." finished successfully.
```

Creá el grupo que contendrá la ola, luego un discovery client:

```bash
$ gcloud migration-center groups create wave-01-payments \
    --location=us-central1 \
    --display-name="Wave 01 - Payments" \
    --description="Payments API + MySQL, colo-A"
Create request issued for: [wave-01-payments]
Waiting for operation [projects/acme-migration-prog/locations/us-central1/operations/op-71a2] to complete... done.
Created group [wave-01-payments].

$ gcloud migration-center discovery-clients create colo-a-collector \
    --location=us-central1 \
    --display-name="colo-A vCenter collector" \
    --service-account=mc-collector@acme-migration-prog.iam.gserviceaccount.com
Created discovery client [colo-a-collector].
registrationToken: 8f2c1d9e-4b7a-4c11-9d3e-...
```

Una vez que la recolección corrió durante al menos un ciclo de negocio completo (**mínimo 2 semanas; 4 semanas si tenés un cierre mensual**), inspeccioná los activos:

```bash
$ gcloud migration-center assets list --location=us-central1 \
    --filter='attributes.osFamily="LINUX"' \
    --format='table(name.basename(), machineDetails.coreCount, machineDetails.memoryMb, machineDetails.platform.vmwareDetails.osid)'
NAME                 CORE_COUNT  MEMORY_MB  OSID
pay-api-01           8           32768      rhel8_64Guest
pay-api-02           8           32768      rhel8_64Guest
pay-api-03           8           32768      rhel8_64Guest
pay-mysql-01         16          131072     rhel8_64Guest
pay-mysql-02         16          131072     rhel8_64Guest
pay-batch-01         4           16384      ubuntu64Guest
...
Listed 143 items.
```

Agregá los activos al grupo y generá el reporte de TCO:

```bash
$ gcloud migration-center groups add-assets wave-01-payments \
    --location=us-central1 \
    --assets-from-file=wave01-assets.txt
Updated group [wave-01-payments]: 143 assets added.

$ gcloud migration-center preference-sets create prod-committed-3y \
    --location=us-central1 \
    --display-name="Prod, 3y CUD, us-central1" \
    --virtual-machine-preferences-file=prefs.yaml
Created preference set [prod-committed-3y].

$ gcloud migration-center reports create tco-wave-01 \
    --location=us-central1 \
    --report-config=rc-wave-01
Waiting for report generation... done.
state: SUCCEEDED
```

`prefs.yaml`:

```yaml
targetProduct: COMPUTE_ENGINE
commitmentPlan: COMMITMENT_PLAN_THREE_YEARS
sizingOptimizationStrategy: SIZING_OPTIMIZATION_STRATEGY_MODERATE
regionPreferences:
  preferredRegions:
    - us-central1
    - us-east4
computeEnginePreferences:
  licenseType: LICENSE_TYPE_BRING_YOUR_OWN_LICENSE
  machinePreferences:
    allowedMachineSeries:
      - code: "n2"
      - code: "n2d"
      - code: "c3"
vmwareEnginePreferences:
  commitmentPlan: ON_DEMAND
  cpuOvercommitRatio: 4.0
```

### 3.3 Qué debe producir "assess" antes de que Plan pueda empezar

Una ola no está lista hasta que existan los seis artefactos. Este es el gate; hacelo cumplir.

| Artefacto | Fuente | Criterio de aceptación |
|---|---|---|
| Inventario de activos | Migration Center | 100% de las IPs en alcance reconciliadas contra DHCP/DNS |
| Mapa de dependencias | Flujos de red de MC (≥14 días) | Ningún flujo entrante inexplicado en un puerto que el equipo de la app no sepa nombrar |
| Percentiles de utilización | Recolección de guest de MC | p95 de CPU/memoria, no promedio — los promedios esconden el pico de la ventana de cierre |
| Decisión de estrategia | Revisión de arquitectura | Una de rehost/replatform/refactor/retire/retain *por workload* |
| Volumen de datos + tasa de delta | Inventario de almacenamiento | GB totales **y** tasa de cambio en GB/día (determina §5) |
| Definición de rollback | Dueño de la app | Explícita: qué estado se descarta, y el tiempo máximo para revertir |

---

## 4. Fase 2 — PLAN: la landing zone es el primer entregable

La guía de landing zone de Google plantea cuatro decisiones: **onboarding de identidad, jerarquía de recursos, diseño de red, controles de seguridad**. Cada una de ellas es cara de cambiar una vez que existen 200 proyectos.

### 4.1 Jerarquía de recursos

```
Organization: acme.com
├── Folder: bootstrap            (Terraform state, CI service accounts, seed project)
├── Folder: common               (logging sink, org-wide monitoring, DNS, Interconnect)
├── Folder: environments
│   ├── Folder: prod
│   │   ├── Folder: payments
│   │   │   ├── Project: pay-prod-host      (Shared VPC host)
│   │   │   ├── Project: pay-prod-app       (service project)
│   │   │   └── Project: pay-prod-data      (service project)
│   │   └── Folder: identity
│   ├── Folder: nonprod
│   └── Folder: dev
└── Folder: migration-staging    (M2VM targets, quarantine before promotion)
```

La política se hereda hacia abajo; la carpeta `migration-staging` existe para que las VMs rehosteadas en vuelo — que inicialmente violarán los estándares de hardening — no te obliguen a debilitar la política de producción.

### 4.2 Terraform completo de la landing zone

```hcl
# ---------------------------------------------------------------------------
# landing-zone/main.tf
# Minimal but complete migration landing zone: hierarchy, org policy,
# Shared VPC, hybrid connectivity prerequisites, logging.
# Terraform >= 1.6, google provider >= 5.x
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
  backend "gcs" {
    bucket = "acme-tfstate-bootstrap"
    prefix = "landing-zone"
  }
}

provider "google" {
  billing_project       = var.seed_project_id
  user_project_override = true
}

variable "org_id"          { type = string }
variable "billing_account" { type = string }
variable "seed_project_id" { type = string }
variable "region"          { type = string  default = "us-central1" }

# ------------------------- Resource hierarchy ------------------------------

resource "google_folder" "common" {
  display_name = "common"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "environments" {
  display_name = "environments"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "prod" {
  display_name = "prod"
  parent       = google_folder.environments.name
}

resource "google_folder" "migration_staging" {
  display_name = "migration-staging"
  parent       = "organizations/${var.org_id}"
}

# ------------------------- Organization policies ---------------------------
# v2 org policy API. Applied at prod; migration-staging gets an exception
# for external IPs only while replication is in flight.

resource "google_org_policy_policy" "no_external_ip" {
  name   = "${google_folder.prod.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.prod.name

  spec {
    inherit_from_parent = false
    rules {
      deny_all = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "require_shielded_vm" {
  name   = "${google_folder.prod.name}/policies/compute.requireShieldedVm"
  parent = google_folder.prod.name

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "restrict_locations" {
  name   = "${google_folder.prod.name}/policies/gcp.resourceLocations"
  parent = google_folder.prod.name

  spec {
    rules {
      values {
        allowed_values = [
          "in:us-central1-locations",
          "in:us-east4-locations",
        ]
      }
    }
  }
}

resource "google_org_policy_policy" "sql_no_public_ip" {
  name   = "${google_folder.prod.name}/policies/sql.restrictPublicIp"
  parent = google_folder.prod.name

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# Exception: M2VM sole-tenant / staging instances may need egress while
# replication bootstraps. Scoped to the staging folder ONLY.
resource "google_org_policy_policy" "staging_external_ip_exception" {
  name   = "${google_folder.migration_staging.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.migration_staging.name

  spec {
    inherit_from_parent = false
    rules {
      allow_all = "TRUE"
    }
  }
}

# ------------------------- Shared VPC host project -------------------------

resource "google_project" "net_host" {
  name            = "pay-prod-host"
  project_id      = "acme-pay-prod-host"
  folder_id       = google_folder.prod.name
  billing_account = var.billing_account
}

resource "google_project_service" "host_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "networkconnectivity.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  project            = google_project.net_host.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_shared_vpc_host_project" "host" {
  project    = google_project.net_host.project_id
  depends_on = [google_project_service.host_apis]
}

resource "google_compute_network" "vpc" {
  project                         = google_project.net_host.project_id
  name                            = "vpc-prod"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
  mtu                             = 1460
  depends_on                      = [google_compute_shared_vpc_host_project.host]
}

resource "google_compute_subnetwork" "app" {
  project                  = google_project.net_host.project_id
  name                     = "sn-prod-app-usc1"
  ip_cidr_range            = "10.40.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.44.0.0/14"
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.48.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Landing subnet for rehosted VMs — deliberately separate so that the
# on-prem-equivalent address plan can be routed and later retired.
resource "google_compute_subnetwork" "migration_landing" {
  project                  = google_project.net_host.project_id
  name                     = "sn-migration-landing-usc1"
  ip_cidr_range            = "10.60.0.0/20"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# ------------------------- Firewall ----------------------------------------

resource "google_compute_firewall" "allow_iap_ssh" {
  project   = google_project.net_host.project_id
  name      = "allow-iap-ssh-rdp"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 1000

  # IAP TCP forwarding range — removes the need for bastion public IPs.
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }
}

resource "google_compute_firewall" "allow_onprem_to_app" {
  project       = google_project.net_host.project_id
  name          = "allow-onprem-to-app"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1100
  source_ranges = ["10.10.0.0/16", "10.11.0.0/16"] # colo-A, colo-B

  allow {
    protocol = "tcp"
    ports    = ["443", "3306", "5432"]
  }
  target_tags = ["migrated"]
}

resource "google_compute_firewall" "deny_all_ingress" {
  project   = google_project.net_host.project_id
  name      = "deny-all-ingress"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 65000

  deny { protocol = "all" }
  source_ranges = ["0.0.0.0/0"]
}

# ------------------------- Centralized logging -----------------------------

resource "google_project" "logging" {
  name            = "acme-common-logging"
  project_id      = "acme-common-logging"
  folder_id       = google_folder.common.name
  billing_account = var.billing_account
}

resource "google_logging_project_bucket_config" "audit" {
  project        = google_project.logging.project_id
  location       = "us"
  retention_days = 400
  bucket_id      = "org-audit"
}

resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-sink"
  org_id           = var.org_id
  include_children = true
  destination      = "logging.googleapis.com/projects/${google_project.logging.project_id}/locations/us/buckets/org-audit"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
  EOT
}

output "host_project"    { value = google_project.net_host.project_id }
output "vpc_self_link"   { value = google_compute_network.vpc.self_link }
output "landing_subnet"  { value = google_compute_subnetwork.migration_landing.self_link }
```

Aplicar y verificar:

```bash
$ terraform apply -auto-approve
...
Apply complete! Resources: 23 added, 0 changed, 0 destroyed.

Outputs:
host_project = "acme-pay-prod-host"
landing_subnet = "https://www.googleapis.com/compute/v1/projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1"
vpc_self_link = "https://www.googleapis.com/compute/v1/projects/acme-pay-prod-host/global/networks/vpc-prod"

$ gcloud org-policies describe compute.vmExternalIpAccess \
    --folder=$(terraform output -raw prod_folder_id) --effective
name: folders/482910371829/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

> Google publica esto como Terraform opinado y reutilizable: los blueprints del **Cloud Foundation Toolkit** y las etapas de **Fabric FAST**. En el examen, el nombre del concepto es *landing zone*; el camino rápido productizado es *Cloud Setup* en la consola más los blueprints de CFT.

### 4.3 Conectividad híbrida: la tabla de trade-offs

Toda migración es híbrida durante toda su duración. Esta elección fija el techo de throughput de tu migración.

| Opción | Ancho de banda | SLA | Tiempo de aprovisionamiento | Camino del tráfico | Forma del costo | Cuándo es la respuesta correcta |
|---|---|---|---|---|---|---|
| **HA VPN** | ~3 Gbps por túnel; escalá agregando túneles | 99,99% (dos interfaces, dos peers) | Minutos | Sobre internet pública, cifrado IPsec | Túnel por hora + egreso | Punto de partida por defecto; dev/test; <1 TB/día |
| **Classic VPN** | ~3 Gbps por túnel | 99,9% | Minutos | Internet pública | Igual | Solo legacy — obsoleto para diseños nuevos |
| **Dedicated Interconnect** | Circuitos de 10 o 100 Gbps, hasta 8 (o 2×100G) por conjunto de attachments | 99,9% / 99,99% según la topología | **Semanas–meses** (cross-connect, LOA-CFA) | Privado, no atraviesa internet | Circuito + attachment + egreso a tarifa reducida | Datos en bloque, >5 TB/día sostenidos, híbrido sensible a la latencia |
| **Partner Interconnect** | Attachments de VLAN de 50 Mbps – 50 Gbps | 99,9% / 99,99% | Días | Privado vía proveedor de servicio | Attachment + tarifa del partner | No estás en una instalación de colocation que haga peering con Google |
| **Cross-Cloud Interconnect** | 10 / 100 Gbps | 99,9% / 99,99% | Semanas | Privado hacia AWS/Azure/OCI | Basado en circuito | Migración multicloud, no on-prem |
| **Direct/Carrier Peering** | Variable | Ninguno | Días | Solo servicios públicos de Google, **no VPC** | Solo egreso | Acceso a APIs de Google — *no* es una opción de conectividad a la VPC |

Dos hechos que definen diseños reales:

1. **Cifrado:** Interconnect es privado pero **no está cifrado por defecto**. Si necesitás cifrado sobre Interconnect, superponé HA VPN encima o usá MACsec donde esté disponible.
2. **MTU/MSS:** Cloud VPN limita la carga útil cifrada a alrededor de 1460 bytes; una VPC configurada con jumbo frames de 8896 bytes hablando sobre VPN va a hacer blackhole de los segmentos TCP grandes salvo que el MSS clamping esté bien. Este es el bug "el túnel está arriba pero la app se cuelga" más común de todos.

### 4.4 HA VPN, completa y desplegable

```hcl
# ---------------------------------------------------------------------------
# hybrid/ha-vpn.tf — 99.99% HA VPN to on-prem, BGP over two interfaces.
# ---------------------------------------------------------------------------

variable "onprem_peer_ip_a" { type = string } # colo-A primary router
variable "onprem_peer_ip_b" { type = string } # colo-A secondary router
variable "onprem_asn"       { type = number  default = 65010 }
variable "shared_secret"    { type = string  sensitive = true }

resource "google_compute_ha_vpn_gateway" "onprem" {
  project = var.host_project
  name    = "ha-vpn-gw-onprem-usc1"
  region  = var.region
  network = var.vpc_self_link
}

resource "google_compute_external_vpn_gateway" "onprem" {
  project         = var.host_project
  name            = "peer-gw-colo-a"
  redundancy_type = "TWO_IPS_REDUNDANCY"
  description     = "colo-A edge routers"

  interface {
    id         = 0
    ip_address = var.onprem_peer_ip_a
  }
  interface {
    id         = 1
    ip_address = var.onprem_peer_ip_b
  }
}

resource "google_compute_router" "cr" {
  project = var.host_project
  name    = "cr-hybrid-usc1"
  region  = var.region
  network = var.vpc_self_link

  bgp {
    asn               = 64514
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]

    # Advertise the Private Google Access ranges so on-prem clients can
    # reach *.googleapis.com privately during and after migration.
    advertised_ip_ranges {
      range       = "199.36.153.8/30"
      description = "private.googleapis.com"
    }
    advertised_ip_ranges {
      range       = "199.36.153.4/30"
      description = "restricted.googleapis.com"
    }
  }
}

resource "google_compute_vpn_tunnel" "t0" {
  project                         = var.host_project
  name                            = "tun-onprem-if0"
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.onprem.id
  vpn_gateway_interface           = 0
  peer_external_gateway           = google_compute_external_vpn_gateway.onprem.id
  peer_external_gateway_interface = 0
  shared_secret                   = var.shared_secret
  router                          = google_compute_router.cr.id
  ike_version                     = 2
}

resource "google_compute_vpn_tunnel" "t1" {
  project                         = var.host_project
  name                            = "tun-onprem-if1"
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.onprem.id
  vpn_gateway_interface           = 1
  peer_external_gateway           = google_compute_external_vpn_gateway.onprem.id
  peer_external_gateway_interface = 1
  shared_secret                   = var.shared_secret
  router                          = google_compute_router.cr.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "if0" {
  project    = var.host_project
  name       = "ri-if0"
  router     = google_compute_router.cr.name
  region     = var.region
  ip_range   = "169.254.10.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.t0.name
}

resource "google_compute_router_interface" "if1" {
  project    = var.host_project
  name       = "ri-if1"
  router     = google_compute_router.cr.name
  region     = var.region
  ip_range   = "169.254.11.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.t1.name
}

resource "google_compute_router_peer" "peer0" {
  project                   = var.host_project
  name                      = "bgp-peer-if0"
  router                    = google_compute_router.cr.name
  region                    = var.region
  peer_ip_address           = "169.254.10.2"
  peer_asn                  = var.onprem_asn
  interface                 = google_compute_router_interface.if0.name
  advertised_route_priority = 100

  bfd {
    session_initialization_mode = "ACTIVE"
    min_transmit_interval       = 1000
    min_receive_interval        = 1000
    multiplier                  = 5
  }
}

resource "google_compute_router_peer" "peer1" {
  project                   = var.host_project
  name                      = "bgp-peer-if1"
  router                    = google_compute_router.cr.name
  region                    = var.region
  peer_ip_address           = "169.254.11.2"
  peer_asn                  = var.onprem_asn
  interface                 = google_compute_router_interface.if1.name
  advertised_route_priority = 200

  bfd {
    session_initialization_mode = "ACTIVE"
    min_transmit_interval       = 1000
    min_receive_interval        = 1000
    multiplier                  = 5
  }
}

# Cloud NAT for migrated VMs that need outbound package repos but no
# inbound exposure. Keeps compute.vmExternalIpAccess = deny satisfiable.
resource "google_compute_router_nat" "nat" {
  project                            = var.host_project
  name                               = "nat-usc1"
  router                             = google_compute_router.cr.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

Verificación — este es el comando que corrés antes de declarar terminada la red:

```bash
$ gcloud compute routers get-status cr-hybrid-usc1 \
    --region=us-central1 --project=acme-pay-prod-host \
    --format="yaml(result.bgpPeerStatus)"
result:
  bgpPeerStatus:
  - advertisedRoutes:
    - destRange: 10.40.0.0/20
    - destRange: 10.60.0.0/20
    - destRange: 199.36.153.8/30
    ipAddress: 169.254.10.1
    linkedVpnTunnel: .../tunnels/tun-onprem-if0
    name: bgp-peer-if0
    numLearnedRoutes: 14
    peerIpAddress: 169.254.10.2
    state: Established
    status: UP
    uptime: 3 hours, 12 minutes
  - advertisedRoutes:
    - destRange: 10.40.0.0/20
    - destRange: 10.60.0.0/20
    ipAddress: 169.254.11.1
    name: bgp-peer-if1
    numLearnedRoutes: 14
    peerIpAddress: 169.254.11.2
    state: Established
    status: UP
    uptime: 3 hours, 12 minutes
```

Ambos `Established`, ambos aprendiendo rutas: la topología del 99,99% es real, no aspiracional.

---

## 5. Fase 3 — DEPLOY (datos): elegí por tiempo de transferencia, no por preferencia

### 5.1 La aritmética que toma la decisión

```
transfer_days  =  total_bytes / (link_bps * utilization * 0.9 /8)      # 0.9 = protocol overhead
feasible       =  transfer_days < window_days  AND  delta_rate < drain_rate
```

800 TB sobre 1 Gbps al 70% de utilización aprovechable:

```
800e12 * 8 / (1e9 * 0.7 * 0.9) = 1.0e7 s ≈ 118 days
```

No es viable. Sobre un Dedicated Interconnect de 10 Gbps: ~12 días — viable, pero el Interconnect en sí tiene un tiempo de entrega de varias semanas. **Transfer Appliance** existe exactamente para este cuadrante.

| Método | Punto óptimo | Throughput | ¿Online? | Modelo de consistencia | Notas |
|---|---|---|---|---|---|
| `gcloud storage cp/rsync` | < 1 TB, ad hoc | Limitado por el enlace, un solo host | Sí | Por objeto | Uploads compuestos en paralelo; sin reintentos ni reportes gestionados |
| **Storage Transfer Service** (cloud→cloud) | S3 / Azure Blob / otro bucket de GCS, cualquier tamaño | Flota gestionada por Google, muy alto | Sí | Por objeto, con `deleteObjectsUniqueInSink` para semántica de sincronización | No hay egreso desde tu propia red en absoluto |
| **Storage Transfer Service** (basado en agentes, on-prem → GCS) | 100 GB – cientos de TB con buen enlace | Escala con la cantidad de agentes | Sí | Filesystem POSIX → objetos | Los agentes corren en Docker en tus hosts; paralelizable |
| **Transfer Appliance** | 100 TB – varios PB, enlace malo/caro | Limitado por el envío físico | No | Snapshot en un punto en el tiempo | Cifrado AES-256; vos tenés la clave. Formatos TA300/TA40 |
| **BigQuery Data Transfer Service** | Fuentes analíticas (S3, Redshift, Teradata, SaaS) | Gestionado | Sí | Batch programado | Aterriza directo en BigQuery, no en GCS |
| **Datastream** | CDC continuo desde Oracle/MySQL/PostgreSQL/SQL Server | Basado en logs, baja latencia | Sí | Stream de cambios | Alimenta BigQuery/GCS; se usa para *replatform-then-cut* |
| **Database Migration Service** | Replatform a DB gestionada con downtime mínimo | Dump completo + CDC | Sí | Transaccionalmente consistente al promover | El único que te da un verbo *promote* |

### 5.2 Storage Transfer Service, basado en agentes, completo

Instalá y arrancá los agentes on-prem (uno por host, varios por host para paralelismo):

```bash
$ gcloud transfer agents install \
    --pool=colo-a-pool \
    --count=8 \
    --mount-directories=/srv/nfs/payments,/srv/nfs/archive \
    --creds-file=/etc/gcp/sts-agent-sa.json
Checking for Docker...  [OK] Docker 26.1.3
Pulling image gcr.io/cloud-ingest/tsop-agent:latest ...  [OK]
Starting 8 agents in pool 'colo-a-pool'...
Agent IDs: transfer_service_agent_2f0a..., ...
[OK] 8 agents running. Verify at:
     https://console.cloud.google.com/transfer/agents
```

Creá el job:

```bash
$ gcloud transfer jobs create \
    posix:///srv/nfs/payments \
    gs://acme-pay-archive/payments \
    --source-agent-pool=projects/acme-migration-prog/agentPools/colo-a-pool \
    --name=payments-nfs-to-gcs \
    --description="Wave 01 payments NFS export" \
    --overwrite-when=different \
    --schedule-repeats-every=6h \
    --log-actions=copy,delete \
    --log-action-states=succeeded,failed \
    --notification-pubsub-topic=projects/acme-migration-prog/topics/sts-events \
    --notification-event-types=transfer_operation_success,transfer_operation_failed
Created job [transferJobs/payments-nfs-to-gcs].
```

Monitorear y validar:

```bash
$ gcloud transfer operations list --job-names=payments-nfs-to-gcs --format=json | jq -r '.[0].metadata.counters'
{
  "bytesCopiedToSink": "41203847284736",
  "bytesFoundFromSource": "88104857600000",
  "objectsCopiedToSink": "18402911",
  "objectsFoundFromSource": "39112044",
  "objectsFromSourceFailed": "17"
}

$ gcloud transfer operations describe transferOperations/transferJobs-payments-nfs-to-gcs-8817 \
    --format="value(errorBreakdowns)"
errorCode: PERMISSION_DENIED
errorCount: 17
errorLogEntries:
  url: posix:///srv/nfs/payments/.snapshot/hourly.0
  errorDetails: ['open /srv/nfs/payments/.snapshot/hourly.0: permission denied']
```

Diagnóstico: directorios de snapshot de NetApp, no datos reales. Excluílos y el job pasa a verde:

```bash
$ gcloud transfer jobs update payments-nfs-to-gcs \
    --exclude-prefixes='.snapshot/'
Updated job [transferJobs/payments-nfs-to-gcs].
```

Chequeo final de integridad — conteo de objetos y una verificación puntual de checksum:

```bash
$ gcloud storage ls -r gs://acme-pay-archive/payments/** | wc -l
39112027

$ gcloud storage hash gs://acme-pay-archive/payments/2026/01/ledger-0001.parquet --hex
---
crc32c_hash: 3f2b9c11
digest_format: hex
md5_hash: 9c1185a5c5e9fc54612808977ee8f548
url: gs://acme-pay-archive/payments/2026/01/ledger-0001.parquet

$ md5sum /srv/nfs/payments/2026/01/ledger-0001.parquet
9c1185a5c5e9fc54612808977ee8f548  /srv/nfs/payments/2026/01/ledger-0001.parquet
```

### 5.3 Database Migration Service: replatform con downtime casi nulo

DMS hace **dump completo + CDC continuo + promote**. El promote es el cutover.

```bash
# 1. Source connection profile (on-prem MySQL 8.0)
$ gcloud database-migration connection-profiles create mysql src-pay-mysql \
    --region=us-central1 \
    --host=10.10.4.21 --port=3306 \
    --username=dms_user --password-file=/run/secrets/dms_pw \
    --display-name="colo-A pay-mysql-01" \
    --ssl-type=SERVER_CLIENT \
    --ca-certificate=/etc/ssl/onprem-ca.pem \
    --client-certificate=/etc/ssl/dms-client.pem \
    --private-key=/etc/ssl/dms-client.key
Created connection profile [src-pay-mysql].

# 2. Destination: DMS creates the Cloud SQL instance for you
$ gcloud database-migration connection-profiles create cloudsql dst-pay-mysql \
    --region=us-central1 \
    --source-id=src-pay-mysql \
    --tier=db-custom-16-65536 \
    --edition=ENTERPRISE_PLUS \
    --storage-auto-resize \
    --data-disk-size=2000 \
    --availability-type=REGIONAL \
    --database-version=MYSQL_8_0_36 \
    --no-enable-ip-v4 \
    --private-network=projects/acme-pay-prod-host/global/networks/vpc-prod
Created connection profile [dst-pay-mysql] and Cloud SQL instance [pay-mysql-prod].

# 3. Migration job — CONTINUOUS = dump then CDC
$ gcloud database-migration migration-jobs create mj-pay-mysql \
    --region=us-central1 \
    --type=CONTINUOUS \
    --source=src-pay-mysql \
    --destination=dst-pay-mysql \
    --peer-vpc=projects/acme-pay-prod-host/global/networks/vpc-prod \
    --display-name="Wave01 payments MySQL"
Created migration job [mj-pay-mysql].

# 4. Verify BEFORE starting — this is the step teams skip
$ gcloud database-migration migration-jobs verify mj-pay-mysql --region=us-central1
Waiting for verification... done.
state: NOT_STARTED
phase: FULL_DUMP
error: null
[OK] Source binary logging enabled (log_bin=ON, binlog_format=ROW, binlog_row_image=FULL)
[OK] Source binlog retention 168h >= required
[OK] Replication user has REPLICATION SLAVE, REPLICATION CLIENT, SELECT
[WARN] 3 tables use the MyISAM engine and will not be replicated by CDC:
       payments.audit_legacy, payments.tmp_import, payments.zip_lookup
[OK] Connectivity from destination to 10.10.4.21:3306

$ gcloud database-migration migration-jobs start mj-pay-mysql --region=us-central1
Started migration job [mj-pay-mysql].
```

Observá el lag de replicación — este número es tu gate de cutover:

```bash
$ watch -n30 'gcloud database-migration migration-jobs describe mj-pay-mysql \
    --region=us-central1 --format="value(state,phase)"'
RUNNING  CDC

$ gcloud monitoring time-series list \
   --filter='metric.type="database.googleapis.com/mysql/replication/seconds_behind_master"' \
   --format='value(points[0].value.int64Value)'
2
```

Promové solo cuando el lag sea estable y bajo, y solo dentro de la ventana de cambio:

```bash
$ gcloud database-migration migration-jobs promote mj-pay-mysql --region=us-central1
This will stop replication and make the destination a standalone,
writable Cloud SQL instance. This cannot be undone. Continue (Y/n)?  Y
Waiting for promotion... done.
state: COMPLETED
phase: PROMOTE_IN_PROGRESS -> COMPLETED
```

**Verificación de realidad sobre el rollback:** después del `promote`, DMS no te devuelve nada. Tu rollback es "re-apuntar la app a on-prem y reconciliar las escrituras". Por eso el runbook debe definir, antes del promote: (a) la app está en solo lectura o detenida, (b) la duración de la ventana de promote, (c) el cambio exacto de DNS/configuración y su TTL.

---

## 6. Fase 3 — DEPLOY (cómputo): Migrate to Virtual Machines

M2VM replica los discos de las VMs de forma continua desde VMware/AWS/Azure/físico hacia Compute Engine mientras la fuente sigue funcionando, y luego hace un cutover corto.

Ciclo de vida: `Source → Migrating VM → replication cycles → Clone job (test, non-disruptive) → Cutover job (final, disruptive)`.

```bash
$ gcloud services enable vmmigration.googleapis.com
Operation finished successfully.

$ gcloud migration vms sources create vmware colo-a-vcenter \
    --location=us-central1 \
    --vcenter-ip=10.10.1.10 \
    --vcenter-username=svc-m2vm@vsphere.local \
    --vcenter-password-file=/run/secrets/vcenter_pw \
    --vcenter-thumbprint=A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:A1:B2:C3:D4
Created source [colo-a-vcenter].

$ gcloud migration vms sources list --location=us-central1
NAME             TYPE     STATE   CREATE_TIME
colo-a-vcenter   VMWARE   ACTIVE  2026-09-01T09:12:44Z

$ gcloud migration vms sources list-inventory colo-a-vcenter --location=us-central1 \
    --format='table(vmId, displayName, vmwareVmDetails.cpuCount, vmwareVmDetails.memoryMb, vmwareVmDetails.committedStorageMb)'
VM_ID       DISPLAY_NAME   CPU_COUNT  MEMORY_MB  COMMITTED_STORAGE_MB
vm-2201     pay-api-01     8          32768      204800
vm-2202     pay-api-02     8          32768      204800
vm-2203     pay-api-03     8          32768      204800
vm-2251     pay-batch-01   4          16384      512000
```

Creá la migrating VM con una forma de destino explícita (**no** aceptes ciegamente el dimensionamiento 1:1 — usá el p95 de Migration Center):

```bash
$ cat > pay-api-01-target.yaml <<'EOF'
targetProject: projects/acme-migration-prog/locations/global/targetProjects/pay-prod-app
name: pay-api-01
machineType: n2-standard-8
machineTypeSeries: n2
zone: us-central1-a
network: projects/acme-pay-prod-host/global/networks/vpc-prod
subnetwork: projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1
networkInterfaces:
  - network: projects/acme-pay-prod-host/global/networks/vpc-prod
    subnetwork: projects/acme-pay-prod-host/regions/us-central1/subnetworks/sn-migration-landing-usc1
    internalIp: 10.60.0.21
serviceAccount: sa-pay-api@acme-pay-prod-app.iam.gserviceaccount.com
diskType: COMPUTE_ENGINE_DISK_TYPE_BALANCED
licenseType: COMPUTE_ENGINE_LICENSE_TYPE_DEFAULT
bootOption: COMPUTE_ENGINE_BOOT_OPTION_EFI
labels:
  wave: "01"
  source: colo-a
  migrated-by: m2vm
additionalLicenses: []
metadata:
  enable-oslogin: "TRUE"
  block-project-ssh-keys: "TRUE"
networkTags:
  - migrated
  - pay-api
EOF

$ gcloud migration vms migrating-vms create pay-api-01 \
    --location=us-central1 \
    --source=colo-a-vcenter \
    --source-vm-id=vm-2201 \
    --compute-engine-target-defaults-from-file=pay-api-01-target.yaml \
    --replication-schedule="0 */4 * * *"
Created migrating VM [pay-api-01].

$ gcloud migration vms migrating-vms start-migration pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter
Started migration for [pay-api-01].
```

Seguir la replicación:

```bash
$ gcloud migration vms migrating-vms describe pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter \
    --format="yaml(state, currentSyncInfo, lastSync, recentCloneJobs)"
state: ACTIVE
currentSyncInfo:
  progressPercent: 100
  startTime: '2026-09-06T04:00:00Z'
  endTime: '2026-09-06T05:41:12Z'
  state: SUCCEEDED
lastSync:
  lastSyncTime: '2026-09-06T05:41:12Z'
```

**Siempre cloná antes de hacer el cutover.** Un clone job construye una instancia real desde el último punto de replicación *sin* tocar la fuente — este es tu ensayo general, y está libre de riesgo de producción:

```bash
$ gcloud migration vms clone-jobs create rehearsal-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01
Created clone job [rehearsal-01].

$ gcloud migration vms clone-jobs describe rehearsal-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01 \
    --format="value(state)"
SUCCEEDED

$ gcloud compute ssh pay-api-01 --zone=us-central1-a --tunnel-through-iap \
    --project=acme-pay-prod-app --command='systemctl is-system-running; systemctl --failed --no-legend'
degraded
  nfs-mount-archive.mount  loaded failed failed  /srv/archive
```

Ahí está el hallazgo clásico: una entrada de fstab apuntando a una IP de NFS on-prem que todavía no tiene ruta. Arreglalo en la fuente (para que el arreglo sobreviva al próximo ciclo de replicación), volvé a clonar, volvé a verificar. Después hacé el cutover:

```bash
$ gcloud migration vms cutover-jobs create cutover-pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01
Cutover will shut down the source VM after a final replication cycle. Continue (Y/n)? Y
Created cutover job [cutover-pay-api-01].

$ gcloud migration vms cutover-jobs describe cutover-pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter --migrating-vm=pay-api-01 \
    --format="yaml(state, steps)"
state: SUCCEEDED
steps:
- previousReplicationCycle: {state: SUCCEEDED}
- shuttingDownSourceVm:    {state: SUCCEEDED}
- finalSync:               {state: SUCCEEDED}
- instantiatingMigratedVm: {state: SUCCEEDED}
```

Finalizá para dejar de pagar por el almacenamiento de replicación:

```bash
$ gcloud migration vms migrating-vms finalize-migration pay-api-01 \
    --location=us-central1 --source=colo-a-vcenter
Finalized migration for [pay-api-01]. Replication resources released.
```

| Tipo de job de M2VM | Impacto en la fuente | Produce | Se usa para |
|---|---|---|---|
| Ciclo de replicación | Snapshot en la fuente (breve) | Estado del disco del lado de la nube | Continuo, en segundo plano |
| **Clone job** | Ninguno | Una instancia de GCE real y booteable | Prueba/validación, repetible |
| **Cutover job** | **La fuente se apaga** | La instancia de producción | La puerta de un solo sentido |
| Finalize | Ninguno | Libera los recursos de replicación | Después de la aceptación |

---

## 7. Fase 3 — DEPLOY (modernizar en el lugar): Migrate to Containers

M2C convierte un workload de VM en ejecución en artefactos de contenedor — una imagen equivalente a un Dockerfile más manifiestos de Kubernetes — sin reescritura. Encaja con VMs *más o menos stateless, Linux, de una sola app*; no encaja con bases de datos ni con nada que tenga módulos de kernel.

```bash
$ migctl setup install --json-key=m2c-install-sa.json
Installing Migrate to Containers on cluster 'm2c-processing'...
[OK] CRDs applied
[OK] Namespace v2k-system ready
[OK] Deployment migctl-controller available

$ migctl source create ce colo-a-src \
    --project=acme-migration-prog --json-key=m2c-src-sa.json
Created source [colo-a-src].

$ migctl migration create pay-web \
    --source colo-a-src \
    --vm-id pay-web-04 \
    --intent Image
Created migration [pay-web].

$ migctl migration status pay-web
NAME     CURRENT-OPERATION  PROGRESS  STEP              STATUS
pay-web  GenerateArtifacts  100%      Copying files     Completed

$ migctl migration get-artifacts pay-web
Artifacts written to ./pay-web/
  Dockerfile
  deployment_spec.yaml
  migration.yaml
```

El `deployment_spec.yaml` generado — revisado y endurecido, que es la parte que es tu trabajo, no el de la herramienta:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pay-web
  namespace: payments
  labels:
    app: pay-web
    migrated-from: pay-web-04
    wave: "01"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: pay-web
  template:
    metadata:
      labels:
        app: pay-web
      annotations:
        anthos-migrate.gcr.io/source: "pay-web-04"
    spec:
      serviceAccountName: pay-web
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: pay-web
      containers:
        - name: pay-web
          image: us-central1-docker.pkg.dev/acme-pay-prod-app/migrated/pay-web:v1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DB_HOST
              value: "10.40.2.3"          # Cloud SQL private IP after DMS promote
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=75.0"
          envFrom:
            - configMapRef:
                name: pay-web-config
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              memory: "2Gi"               # no CPU limit: avoids CFS throttling
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            failureThreshold: 60          # 5 min for legacy JVM warm-up
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 4
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]   # drain LB before exit
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: run
              mountPath: /var/run
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 512Mi }
        - name: run
          emptyDir: { medium: Memory, sizeLimit: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: pay-web
  namespace: payments
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "pay-web-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: pay-web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: pay-web-backendconfig
  namespace: payments
spec:
  timeoutSec: 30
  connectionDraining:
    drainingTimeoutSec: 60
  healthCheck:
    type: HTTP
    requestPath: /readyz
    port: 8080
    checkIntervalSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
  logging:
    enable: true
    sampleRate: 1.0
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: pay-web
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: pay-web
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pay-web
  namespace: payments
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pay-web
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pay-web-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: pay-web
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 10.40.2.3/32        # Cloud SQL private IP
      ports:
        - protocol: TCP
          port: 3306
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

Tabla de encaje de M2C — memorizá las exclusiones:

| Forma del workload | Encaje con M2C | Por qué |
|---|---|---|
| Servidor de aplicaciones Linux stateless (Tomcat, JBoss, nginx, Node) | **Bueno** | El filesystem es mayormente código + configuración |
| App de Windows IIS / .NET Framework | Bueno (hay soporte para Windows) | Imágenes de IIS containerizadas |
| MySQL/PostgreSQL/Oracle sobre una VM | **Malo** | Usá DMS / Cloud SQL / Bare Metal Solution en su lugar |
| Cualquier cosa con módulo de kernel personalizado, pineo de driver de GPU o acceso a `/dev` | **Malo** | El contenedor comparte el kernel del nodo |
| App con estado local hardcodeado en `/var/lib/app` | Condicional | Necesita un PersistentVolume o refactor |
| VM "todo en uno" con múltiples servicios | Condicional | Descomponé primero; un contenedor por proceso |

---

## 8. Retain e híbrido: GKE Enterprise como capa de consistencia

Para los workloads que no pueden moverse (regulatorios, latencia, licencia), la respuesta de Google es hacer que el *plano de control* sea consistente en lugar de forzar el movimiento del workload. Fleets + Config Sync te dan una única fuente de política a través de on-prem, Google Cloud y otras nubes.

```bash
$ gcloud container fleet memberships register colo-a-cluster \
    --context=onprem-colo-a \
    --kubeconfig=$HOME/.kube/config \
    --enable-workload-identity \
    --project=acme-fleet-host
Waiting for membership to be created...done.
Finished registering the cluster [colo-a-cluster] with the fleet.

$ gcloud container fleet memberships list --project=acme-fleet-host
NAME             UNIQUE_ID                             LOCATION
colo-a-cluster   4c1b8a7e-...                          global
gke-usc1-prod    9e2d31af-...                          us-central1
```

Habilitar Config Sync en toda la flota:

```yaml
# apply-spec.yaml
applySpecVersion: 1
spec:
  configmanagement:
    version: 1.19.0
    configSync:
      enabled: true
      sourceFormat: unstructured
      syncRepo: https://github.com/acme/platform-config
      syncBranch: main
      policyDir: clusters/
      secretType: gcpserviceaccount
      gcpServiceAccountEmail: config-sync@acme-fleet-host.iam.gserviceaccount.com
      preventDrift: true
    policyController:
      enabled: true
      templateLibraryInstalled: true
      referentialRulesEnabled: true
      auditIntervalSeconds: 60
```

```bash
$ gcloud beta container fleet config-management apply \
    --membership=colo-a-cluster --config=apply-spec.yaml --project=acme-fleet-host
Waiting for Feature Config Management to be updated...done.

$ gcloud beta container fleet config-management status --project=acme-fleet-host
Name             Status  Last_Synced_Token  Sync_Branch  Last_Synced_Time      Policy_Controller
colo-a-cluster   SYNCED  8f21ad3            main         2026-09-08T11:04:12Z  INSTALLED
gke-usc1-prod    SYNCED  8f21ad3            main         2026-09-08T11:04:09Z  INSTALLED
```

El objeto `RootSync` que lo maneja:

```yaml
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  sourceType: git
  git:
    repo: https://github.com/acme/platform-config
    branch: main
    dir: clusters/base
    auth: gcpserviceaccount
    gcpServiceAccountEmail: config-sync@acme-fleet-host.iam.gserviceaccount.com
    period: 30s
  override:
    resources:
      - containerName: reconciler
        cpuRequest: 100m
        memoryRequest: 512Mi
        memoryLimit: 1Gi
```

El punto a nivel de examen: **GKE Enterprise (antes Anthos) es la forma en que Google Cloud da soporte a las organizaciones cuya transición es parcial o híbrida permanente** — una API, un conjunto de políticas, un plano de observabilidad, sin importar si el cluster está en una región de Google, en tu colo o en AWS.

---

## 9. Cutover: un runbook de SRE, no un evento

El cutover es un cambio con un radio de impacto definido y un reloj de rollback. Escribilo así:

```yaml
# runbook/wave-01-cutover.yaml  (documentation-as-code; reviewed in PR)
wave: "01"
service: payments-api
slo:
  availability: 99.95%
  monthly_error_budget_minutes: 21.6
  budget_consumed_before_cutover: 4.1
  budget_allocated_to_cutover: 8.0     # hard stop: abort if exceeded

preconditions:
  - id: PRE-1
    check: "DMS replication lag < 5s sustained 30 min"
    cmd: "gcloud database-migration migration-jobs describe mj-pay-mysql --region=us-central1 --format='value(phase)'"
    expect: "CDC"
  - id: PRE-2
    check: "M2VM clone rehearsal passed with zero failed units"
    cmd: "gcloud compute ssh pay-api-01 --tunnel-through-iap --command='systemctl --failed --no-legend | wc -l'"
    expect: "0"
  - id: PRE-3
    check: "BGP sessions Established on both interfaces"
    cmd: "gcloud compute routers get-status cr-hybrid-usc1 --region=us-central1 --format='value(result.bgpPeerStatus[].state)'"
    expect: "Established;Established"
  - id: PRE-4
    check: "DNS TTL lowered to 60s at least 24h ago"
    cmd: "dig +noall +answer api.pay.acme.com"
    expect: "ttl<=60"
  - id: PRE-5
    check: "Rollback tested in staging within last 7 days"

steps:
  - t: "T-00:00"  action: "Enable maintenance page; drain LB backends on-prem"
  - t: "T-00:03"  action: "Confirm zero in-flight writes (SHOW PROCESSLIST)"
  - t: "T-00:05"  action: "gcloud database-migration migration-jobs promote mj-pay-mysql"
  - t: "T-00:12"  action: "Point app config at Cloud SQL private IP; restart app tier"
  - t: "T-00:15"  action: "Shift 10% of traffic via weighted DNS / LB traffic split"
  - t: "T-00:25"  action: "Verify golden signals at 10%; compare p99 and error rate to baseline"
  - t: "T-00:40"  action: "Shift to 50%"
  - t: "T-01:00"  action: "Shift to 100%; remove maintenance page"
  - t: "T-24:00"  action: "Raise DNS TTL to 3600; finalize M2VM; decommission source"

abort_criteria:
  - "error rate > 1% for 5 consecutive minutes"
  - "p99 latency > 2x baseline for 10 minutes"
  - "any data integrity check fails"
  - "cumulative error budget burn > 8.0 minutes"

rollback:
  rto_minutes: 15
  procedure:
    - "Revert DNS weight to 100% on-prem (TTL 60s => propagation <= 2 min)"
    - "Re-enable on-prem LB backends"
    - "Set Cloud SQL instance read-only; export delta writes for reconciliation"
    - "Open incident; do not retry same day"
  data_loss_window: "writes accepted by Cloud SQL after promote; reconcile from binlog"
```

Tomá la línea base de las golden signals *antes* de tocar nada — un cutover sin línea base previa al cambio no se puede juzgar:

```bash
$ gcloud monitoring time-series list \
    --filter='metric.type="loadbalancing.googleapis.com/https/total_latencies" AND resource.labels.forwarding_rule_name="pay-api-fr"' \
    --interval-start-time="2026-09-01T00:00:00Z" \
    --interval-end-time="2026-09-08T00:00:00Z" \
    --aggregation-alignment-period=300s \
    --aggregation-per-series-aligner=ALIGN_PERCENTILE_99 \
    --format='value(points[].value.distributionValue.mean)' | head -5
118.4
121.0
117.9
203.7
119.2
```

---

## 10. Fase 4 — OPTIMIZE: donde realmente se gana el caso de negocio

Un rehost que se detiene acá cuesta más que el datacenter. La optimización no es opcional, y Google la entrega como herramienta en lugar de como consejo.

| Palanca | Herramienta de Google | Ahorro típico realizado | Riesgo |
|---|---|---|---|
| Rightsizing | **Active Assist / Recommender** (`google.compute.instance.MachineTypeRecommender`) | 15–40% en cómputo | Subdimensionar un workload con picos; usá p95 sobre ≥14 días |
| Recuperación de recursos ociosos | Recommender: VM ociosa, disco ocioso, IP ociosa, Cloud SQL ocioso | 5–15% | Borrar algo con un ciclo de trabajo trimestral |
| Committed Use Discounts | CUDs por gasto / por recurso, de 1 o 3 años | Hasta ~55% (por recurso, 3 años) | El compromiso no es cancelable; comprometete al *piso*, no al pico |
| Spot VMs | Spot VM / node pools Spot de GKE | Hasta ~91% | Interrupción (preemption); solo para batch/tolerante a fallos |
| Autoscaling | Autoscaler de MIG, cluster autoscaler de GKE, **GKE Autopilot**, escalado a cero de Cloud Run | Muy variable | Cold start; escalar según la señal equivocada |
| Escalonamiento de almacenamiento | Object Lifecycle Management → Nearline/Coldline/Archive; Autoclass | 40–80% en datos fríos | Cargos por borrado temprano y por recuperación |
| Red | Standard vs Premium Tier, Cloud CDN | 10–25% de egreso | Standard Tier cambia la latencia y el SLA |

```bash
$ gcloud recommender recommendations list \
    --project=acme-pay-prod-app \
    --location=us-central1-a \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --format='table(name.basename(), primaryImpact.costProjection.cost.units, description)'
NAME                                  UNITS  DESCRIPTION
b1f2-3a9c-...                         -412   Save cost by changing machine type from n2-standard-16 to n2-standard-8.
c8d1-7e02-...                         -197   Save cost by changing machine type from n2-standard-8 to n2-standard-4.
Listed 34 items.

$ gcloud recommender recommendations list \
    --project=acme-pay-prod-app --location=global \
    --recommender=google.cloudsql.instance.IdleRecommender \
    --format='value(description)'
Save cost by stopping idle Cloud SQL instance pay-mysql-uat-old.

$ gcloud storage buckets update gs://acme-pay-archive \
    --lifecycle-file=lifecycle.json
Updating gs://acme-pay-archive/...
  Completed 1
```

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": { "age": 30, "matchesStorageClass": ["STANDARD"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 120, "matchesStorageClass": ["NEARLINE"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 365, "matchesStorageClass": ["COLDLINE"] }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "age": 2555, "isLive": true }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "daysSinceNoncurrentTime": 30 }
      }
    ]
  }
}
```

Gobernanza para que los ahorros no se evaporen — presupuestos con alertas programáticas:

```bash
$ gcloud billing budgets create \
    --billing-account=01ABCD-234567-89EFGH \
    --display-name="Wave 01 payments" \
    --filter-projects=projects/acme-pay-prod-app \
    --budget-amount=48000USD \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.8 \
    --threshold-rule=percent=1.0,basis=forecasted-spend \
    --all-updates-rule-pubsub-topic=projects/acme-common-billing/topics/budget-alerts
Created budget [billingAccounts/01ABCD-234567-89EFGH/budgets/8b21-...].
```

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Escalera de verificación — corré en este orden

| Capa | Qué afirmás | Comando |
|---|---|---|
| L0 Política | La landing zone hace cumplir lo que diseñaste | `gcloud org-policies describe <constraint> --folder=<id> --effective` |
| L1 Alcanzabilidad | BGP arriba, rutas intercambiadas | `gcloud compute routers get-status <router> --region=<r>` |
| L2 Camino | La 5-tupla específica está permitida de extremo a extremo | `gcloud network-management connectivity-tests create ... && ... describe` |
| L3 Plano de datos | La VM/pod efectivamente responde | `curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' http://<ip>/readyz` |
| L4 Integridad de datos | Los conteos de filas/objetos y los checksums coinciden | `SELECT COUNT(*)` de ambos lados; `gcloud storage hash` |
| L5 Comportamiento | Golden signals dentro de la línea base | MQL/PromQL de Cloud Monitoring contra la línea base previa al cutover |
| L6 Costo | Los valores reales coinciden con la proyección de TCO | Exportación de facturación → BigQuery; delta de Recommender |

Connectivity Tests es la herramienta subutilizada de mayor valor — evalúa la *configuración* (rutas, firewall, políticas) sin necesitar tráfico:

```bash
$ gcloud network-management connectivity-tests create pay-app-to-sql \
    --source-instance=projects/acme-pay-prod-app/zones/us-central1-a/instances/pay-api-01 \
    --destination-ip-address=10.40.2.3 \
    --destination-port=3306 \
    --protocol=TCP \
    --project=acme-pay-prod-app
Created connectivity test [pay-app-to-sql].

$ gcloud network-management connectivity-tests describe pay-app-to-sql \
    --project=acme-pay-prod-app --format="yaml(reachabilityDetails)"
reachabilityDetails:
  result: UNREACHABLE
  traces:
  - steps:
    - description: Initial state - packet originating from instance pay-api-01
      state: START_FROM_INSTANCE
    - description: Config checking state - verify route
      state: APPLY_ROUTE
      route: {destIpRange: 10.40.0.0/20, nextHopType: NEXT_HOP_NETWORK}
    - description: Config checking state - verify egress firewall rule
      state: APPLY_EGRESS_FIREWALL_RULE
      firewall: {displayName: deny-all-egress, action: DENY, priority: 65000}
    - description: Packet could be dropped
      state: DROP
      causeCode: FIREWALL_RULE
  verifyTime: '2026-09-08T11:52:03Z'
```

La herramienta nombró la regla exacta. Eso es un diagnóstico de dos minutos en lugar de una captura de paquetes de dos horas.

### 11.2 Catálogo de fallas

| Síntoma | Causa más probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| Replicación de M2VM trabada en <100% durante horas | CBT de vSphere deshabilitado/reseteado, o cuota de snapshots del datastore agotada | `gcloud migration vms migrating-vms describe <vm> --format='yaml(error,currentSyncInfo)'` | Habilitar CBT en la VM origen, eliminar snapshots viejos, reiniciar el ciclo |
| Cutover de M2VM: la instancia arranca en shell de emergencia | Discordancia en la opción de arranque (BIOS vs UEFI) o `/etc/fstab` referencia discos inexistentes | Consola serie: `gcloud compute instances get-serial-port-output <vm>` | Configurar `bootOption: COMPUTE_ENGINE_BOOT_OPTION_EFI` correctamente; usar UUIDs en fstab **antes** del ciclo final |
| La VM migrada arranca pero sin red | NIC renombrada (`ens192` → `ens4`); la configuración estática referencia el nombre viejo | Salida de la consola serie; `ip -br link` | Usar DHCP + guest environment; instalar `google-guest-agent` en la fuente antes de migrar |
| No se puede hacer SSH a la VM migrada | OS Login no habilitado, sin IP externa por política, sin regla de firewall para IAP | `gcloud compute ssh <vm> --tunnel-through-iap --troubleshoot` | Permitir 35.235.240.0/20 en el 22; otorgar `roles/iap.tunnelResourceAccessor` |
| Job de DMS `FAILED` en `FULL_DUMP` | Permisos insuficientes, o tablas sin clave primaria (replicación lógica de PostgreSQL) | `gcloud database-migration migration-jobs describe <mj> --format='yaml(error)'` | Otorgar `REPLICATION SLAVE, REPLICATION CLIENT, SELECT`; agregar PKs o excluir esas tablas |
| El lag de CDC de DMS crece sin límite | Tier de destino subdimensionado, o una transacción de larga duración en la fuente | Monitorear `seconds_behind_master`; `SHOW ENGINE INNODB STATUS` en la fuente | Escalar el tier de Cloud SQL; matar la transacción larga; reintentar el cutover en la próxima ventana |
| DMS: error de gap en el binlog | `binlog_expire_logs_seconds` de la fuente demasiado corto respecto de la duración del dump | En la fuente: `SHOW VARIABLES LIKE 'binlog_expire%'` | Subir la retención a ≥ 7 días **antes** de arrancar; reiniciar el job |
| El job de STS basado en agentes transfiere 0 bytes | El agente no ve el mount, o la ruta del mount no está en `--mount-directories` | `docker logs <agent-container>`; `gcloud transfer agents list` | Reinstalar los agentes con la lista de mounts correcta; revisar UID/GID en el export |
| La sesión BGP se cae cada pocos minutos | Discordancia de MD5/ASN, o discordancia de intervalos BFD on-prem | `gcloud compute routers get-status` → `state: Connect`/`Idle` | Alinear ASN, temporizadores BFD; revisar `show ip bgp neighbors` on-prem |
| Túnel UP, BGP Established, pero las transferencias grandes se cuelgan | MTU/MSS: paquetes de 1500 bytes con DF sobre un camino VPN de 1460 bytes | `ping -M do -s 1400 <peer>` y luego `-s 1460` | Hacer MSS clamp a 1360 en el borde on-prem; configurar la MTU de la VPC de forma consistente |
| La app funciona desde GCE pero no desde un pod de GKE | Denegación de egreso de NetworkPolicy, o el IP masquerade excluye el rango on-prem | `kubectl exec -it <pod> -- nc -vz 10.10.4.21 3306`; `kubectl -n kube-system get cm ip-masq-agent -o yaml` | Agregar la regla de egreso; agregar el CIDR a `nonMasqueradeCIDRs` |
| `Private Google Access` falla desde on-prem | Falta el anuncio de ruta para 199.36.153.8/30 o falta la zona de reenvío DNS | `dig storage.googleapis.com @<onprem-resolver>` | Anunciar el rango en el Cloud Router; crear la zona DNS privada + response policy |
| Config Sync trabado en `PENDING` | Repo inalcanzable, o un manifiesto falla la admisión de Policy Controller | `nomos status`; `kubectl -n config-management-system logs deploy/root-reconciler` | Arreglar la autenticación del repo o el manifiesto ofensor; `preventDrift` lo reporta |
| Factura post-migración 3× la proyección de TCO | El dimensionamiento fue 1:1, sin CUDs, egreso no modelado, snapshots que nunca expiran | Exportación de facturación en BigQuery agrupada por SKU; `gcloud recommender recommendations list` | Rightsizing, aplicar CUDs, agregar políticas de ciclo de vida, revisar la topología de egreso |

```bash
$ nomos status
Connecting to clusters...
*colo-a-cluster
  --------------------
  <root>   https://github.com/acme/platform-config/clusters@main
  ERROR    KNV1021: The below resource is invalid: admission webhook
           "validation.gatekeeper.sh" denied the request: [require-resource-limits]
           container <pay-web> has no memory limit
  Last Synced Token: 7a92be1
```

---

## 12. Lente de examen: qué pregunta realmente el CDL sobre este objetivo

El examen Digital Leader no te pide que escribas el Terraform. Te pide que elijas la respuesta *nombrada* correcta de Google para un escenario de negocio. Mapeá esto:

| Pista del escenario en la pregunta | Respuesta correcta |
|---|---|
| "Evaluar la preparación, identificar brechas de habilidades y culturales" | **Google Cloud Adoption Framework** (Learn, Lead, Scale, Secure; Tactical/Strategic/Transformational) |
| "Inventariar servidores y estimar el costo antes de decidir" | **Migration Center** (evaluación gratuita, reporte de TCO) |
| "Mover VMs tal cual, cambios mínimos, plazo ajustado" | **Rehost / lift and shift** con **Migrate to VMs** |
| "Conservar las herramientas y habilidades de VMware, salir del datacenter rápido" | **Google Cloud VMware Engine** |
| "Mover MySQL a un servicio gestionado con downtime mínimo" | **Database Migration Service** |
| "Containerizar apps existentes sin reescribirlas" | **Migrate to Containers** |
| "Petabytes de datos, enlace de red malo" | **Transfer Appliance** |
| "Sincronización continua desde AWS S3 hacia Cloud Storage" | **Storage Transfer Service** |
| "Algunos workloads deben quedarse on-prem por cumplimiento" | **Híbrido / GKE Enterprise**; estrategia = *retain* |
| "Política consistente entre on-prem, Google Cloud y otras nubes" | **GKE Enterprise fleets + Config Sync + Policy Controller** |
| "Reducir el gasto después de migrar" | **Active Assist / Recommender**, **committed use discounts**, autoscaling |
| "Cambiar cómo trabajan los equipos — cultura, automatización, medición, compartir" | **CAMP** / prácticas DevOps + SRE |
| "Conexión privada de alto ancho de banda a Google, no por internet" | **Dedicated (o Partner) Interconnect** |
| "Conexión cifrada sobre internet pública, rápido" | **Cloud HA VPN** |

Tres distinciones que al examen le gusta evaluar:

1. **CAF ≠ las cuatro fases de migración.** CAF evalúa la organización; Assess/Plan/Deploy/Optimize ejecuta la migración.
2. **Rehost no es un fracaso.** Es la primera movida correcta bajo un plazo; la modernización pertenece a Optimize.
3. **El TCO incluye lo que dejás de pagar.** Energía del datacenter, refrigeración, renovación de hardware, ajustes de licencias y las horas de personal gastadas en parcheo — el examen lo encuadra como capex→opex y como reducción de toil operativo.

---

## 13. Resumen

- Una transición a la nube es un **programa por etapas** — Assess, Plan, Deploy, Optimize — con una herramienta de Google atada a cada etapa; nombrar primero la etapa es la forma de elegir la herramienta.
- **Assess es el gate.** Migration Center te da inventario, dependencias, encaje y TCO gratis; una ola sin mapa de dependencias es una ola que te va a despertar de madrugada.
- **La landing zone es el primer entregable**, no el último: jerarquía de recursos, identidad, red y org policy aplicadas antes del primer workload.
- **La estrategia es por workload**: rehost / replatform / refactor / retire / retain, elegida a partir del plazo, el presupuesto de cambio y el fan-in de dependencias.
- **El movimiento de datos es aritmética**, no preferencia: calculá el tiempo de transferencia contra la ventana de cambio antes de elegir entre STS, Transfer Appliance o Interconnect.
- **Todo cutover necesita un ensayo (clone job), una línea base, criterios de aborto y un rollback con un RTO declarado** — si no, es una caída con un plan de proyecto adosado.
- **El híbrido es un destino, no un defecto.** GKE Enterprise convierte "retain" en un estado gobernado en lugar de una excepción permanente.
- **En Optimize es donde se materializa el caso de negocio.** Rightsizing, CUDs, autoscaling y escalonamiento de almacenamiento son la diferencia entre una migración que se paga sola y una que se convierte en un incidente de costos.

---

## 14. Referencias

Fuentes oficiales de Google. Todas las URLs son documentación publicada por Google; la guía del examen es la definición autoritativa del alcance.

**Alcance del examen**
- Cloud Digital Leader exam guide (PDF) — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Marcos y modelo de programa**
- Migration to Google Cloud: getting started — https://cloud.google.com/architecture/migration-to-gcp-getting-started
- Migration to Google Cloud: assessing and discovering your workloads — https://cloud.google.com/architecture/migration-to-gcp-assessing-and-discovering-your-workloads
- Migration to Google Cloud: planning and building your foundation — https://cloud.google.com/architecture/migration-to-google-cloud-building-your-foundation
- Migration to Google Cloud: deploying your workloads — https://cloud.google.com/architecture/migration-to-google-cloud-deploying-your-workloads
- Migration to Google Cloud: optimizing your environment — https://cloud.google.com/architecture/migration-to-google-cloud-optimizing-your-environment
- Google Cloud Adoption Framework — https://cloud.google.com/adoption-framework
- Google Cloud Architecture Framework — https://cloud.google.com/architecture/framework
- DevOps / DORA capabilities (CAMP) — https://cloud.google.com/devops

**Landing zone y fundación**
- Landing zone design in Google Cloud — https://cloud.google.com/architecture/landing-zones
- Google Cloud enterprise foundations blueprint — https://cloud.google.com/architecture/security-foundations
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Cloud Foundation Toolkit — https://cloud.google.com/foundation-toolkit

**Evaluación**
- Migration Center overview — https://cloud.google.com/migration-center/docs/migration-center-overview
- Discovery client — https://cloud.google.com/migration-center/docs/discovery-client-overview
- Referencia de `gcloud migration-center` — https://cloud.google.com/sdk/gcloud/reference/migration-center

**Migración de cómputo**
- Migrate to Virtual Machines — https://cloud.google.com/migrate/virtual-machines/docs/5.0/get-started/migrate-to-vms-overview
- Migrating VMs from VMware — https://cloud.google.com/migrate/virtual-machines/docs/5.0/migrate/vmware-migration-overview
- Referencia de `gcloud migration vms` — https://cloud.google.com/sdk/gcloud/reference/migration/vms
- Google Cloud VMware Engine — https://cloud.google.com/vmware-engine/docs/overview
- Migrate to Containers — https://cloud.google.com/migrate/containers/docs/migrate-to-containers-overview
- Migrate to Containers: what can be migrated — https://cloud.google.com/migrate/containers/docs/migration-planning

**Migración de datos y bases de datos**
- Storage Transfer Service overview — https://cloud.google.com/storage-transfer/docs/overview
- Transfer from on-premises (agent-based) — https://cloud.google.com/storage-transfer/docs/on-prem-overview
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs/4.0/overview
- Database Migration Service — https://cloud.google.com/database-migration/docs
- DMS for MySQL: prerequisites and configuration — https://cloud.google.com/database-migration/docs/mysql/configure-source-database
- Datastream overview — https://cloud.google.com/datastream/docs/overview
- BigQuery Data Transfer Service — https://cloud.google.com/bigquery/docs/dts-introduction

**Conectividad híbrida**
- Network Connectivity products overview — https://cloud.google.com/network-connectivity/docs/how-to/choose-product
- Cloud VPN overview / HA VPN topologies — https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview y https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies
- Cloud Interconnect overview — https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview
- Cloud Router and BGP — https://cloud.google.com/network-connectivity/docs/router/concepts/overview
- Maximum transmission unit (MTU) — https://cloud.google.com/vpc/docs/mtu
- Private Google Access for on-premises hosts — https://cloud.google.com/vpc/docs/private-google-access-hybrid

**Runtime híbrido y multicloud**
- GKE Enterprise overview — https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview
- Fleet management — https://cloud.google.com/kubernetes-engine/fleet-management/docs/fleet-concepts
- Config Sync — https://cloud.google.com/kubernetes-engine/enterprise/config-sync/docs/overview
- Policy Controller — https://cloud.google.com/kubernetes-engine/enterprise/policy-controller/docs/overview

**Verificación, diagnóstico y optimización**
- Connectivity Tests — https://cloud.google.com/network-intelligence-center/docs/connectivity-tests/concepts/overview
- VPC Flow Logs — https://cloud.google.com/vpc/docs/flow-logs
- IAP TCP forwarding — https://cloud.google.com/iap/docs/using-tcp-forwarding
- Active Assist / Recommender — https://cloud.google.com/recommender/docs/overview
- Committed use discounts — https://cloud.google.com/docs/cus-and-suds y https://cloud.google.com/compute/docs/instances/committed-use-discounts-overview
- Object Lifecycle Management — https://cloud.google.com/storage/docs/lifecycle
- Cloud Billing budgets and alerts — https://cloud.google.com/billing/docs/how-to/budgets
- Google Cloud SLAs — https://cloud.google.com/terms/sla
- SRE practice: SLOs and error budgets — https://sre.google/workbook/implementing-slos/