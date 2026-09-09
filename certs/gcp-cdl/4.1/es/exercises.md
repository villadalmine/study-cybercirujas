# gcp-cdl — Tema 4.1 · Ejercicios guiados

## Describir cómo Google Cloud ayuda a las organizaciones a hacer la transición a la nube

> **Alineación con el examen.** Cloud Digital Leader (versión 2026-08-12), Objetivo 4.1, peso en el examen **6.0**. Fuente: [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf).
>
> **Cómo usar esto.** Cada ejercicio es una secuencia numerada que ejecutás de verdad, seguida de preguntas de verificación. El examen no es técnico, pero las *decisiones* que evalúa — qué ruta de migración, qué mecanismo de transferencia, cuándo el modelo de descuentos cambia la respuesta — solo se vuelven memorables si viste el tooling comportarse. Las respuestas están en la sección desplegable del final.
>
> **Honestidad sobre las salidas.** Las salidas de los comandos que siguen están abreviadas y los IDs de recursos son ilustrativos. Los grupos de comandos marcados `alpha`/`beta` (Migration Center, Migrate to Virtual Machines) cambian de superficie entre releases — `gcloud <group> --help` siempre tiene más autoridad que cualquier documento, incluido este.

---

## Convenciones y prerrequisitos

```bash
# Tooling
gcloud version   # expect: Google Cloud SDK 5xx.0.0 or later

# Identifiers used throughout. Substitute your own.
export PROJECT_ID="acme-migration-prod"
export REGION="us-central1"
export ZONE="us-central1-a"
export BILLING_ACCOUNT="01ABCD-234567-89EFGH"
export ORG_ID="123456789012"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
```

IAM requerido en el proyecto, como mínimo: `roles/migrationcenter.admin`, `roles/compute.admin`, `roles/storagetransfer.admin`, `roles/datamigration.admin`, `roles/recommender.viewer`, `roles/billing.admin` en la cuenta de facturación.

**Escenario usado por todos los ejercicios.** *Acme Retail* corre 480 VMs distribuidas en dos datacenters on-premises sobre VMware vSphere, una base de datos OLTP MySQL 8.0 autogestionada de 12 TB, un archivo de 240 TB de documentos escaneados en un filer NFS, un data warehouse Teradata de 90 TB y una instancia SAP ECC que el proveedor solo soporta sobre hardware específico. El contrato de alquiler del datacenter vence en 14 meses. Su enlace WAN de salida es de 1 Gbps.

---

## Ejercicio 1 — Assess: construí el inventario antes de construir cualquier otra cosa

El framework de migración publicado por Google tiene cuatro fases — **assess, plan, deploy, optimize** ([Migration to Google Cloud: get started](https://cloud.google.com/architecture/migration-to-gcp-getting-started)). Todo lo de este ejercicio es la fase uno. No podés costear, secuenciar ni elegir una ruta para una carga de trabajo que no contaste.

1. Habilitá las APIs relacionadas con la evaluación:

```bash
gcloud services enable \
  migrationcenter.googleapis.com \
  cloudasset.googleapis.com \
  recommender.googleapis.com \
  cloudbilling.googleapis.com
```

```
Operation "operations/acat.p2-84...-f3a1" finished successfully.
```

2. Migration Center es la superficie unificada de evaluación: descubre activos, los agrupa, dimensiona los equivalentes en Google Cloud y produce un informe de TCO ([Migration Center overview](https://cloud.google.com/migration-center/docs/migration-center-overview)). Confirmá la superficie de CLI disponible antes de escribir scripts contra ella:

```bash
gcloud alpha migration-center --help | sed -n '/^GROUPS/,/^COMMANDS/p'
```

```
GROUPS
    assets              Manage discovered assets.
    discovery-clients   Manage discovery clients.
    groups               Manage asset groups.
    import-jobs          Manage import jobs.
    preference-sets      Manage preference sets.
    reports/report-configs
                         Manage assessment reports.
```

3. Creá un grupo — la unidad contra la que se generan los informes. Los grupos son la forma de separar "el parque SAP" de "los 400 servidores de aplicación stateless", porque esos dos reciben veredictos distintos:

```bash
gcloud alpha migration-center groups create app-tier-dc1 \
  --location="${REGION}" \
  --description="DC1 stateless application servers"
```

```
Create request issued for: [app-tier-dc1]
Waiting for operation [operation-1757...-6b2] to complete...done.
Created group [app-tier-dc1].
```

4. Alimentá el inventario. Migration Center acepta tres rutas de ingesta, y la elección es en sí misma un trade-off relevante para el examen:
   - el **discovery client** (una VM colectora que corre dentro de tu datacenter, continua, incluye muestras de rendimiento),
   - una exportación **RVTools** desde vSphere (`.xlsx`, de una sola vez, sin historial de rendimiento salvo que se incluya),
   - una **importación manual de CSV/archivo** (último recurso — precisa en la forma, ciega en la utilización).

   Creá un import job para un archivo manual. Los nombres exactos de las cabeceras del CSV se validan contra el esquema de importación publicado, así que tomalos de [la documentación de import-data](https://cloud.google.com/migration-center/docs/import-data-overview) en vez de la memoria; la forma es:

```csv
MachineId,MachineName,PrimaryIPAddress,AllocatedProcessorCoreCount,MemoryMiB,AllocatedStorageBytes,OsName,OsVersion,HostingLocation
vm-0001,app-dc1-001,10.10.4.11,8,32768,536870912000,Red Hat Enterprise Linux,8.9,DC1-RackB
vm-0002,app-dc1-002,10.10.4.12,8,32768,536870912000,Red Hat Enterprise Linux,8.9,DC1-RackB
vm-0003,sap-ecc-prd,10.10.9.5,64,786432,17592186044416,SUSE Linux Enterprise Server,15.5,DC1-RackF
```

5. Validá antes de ejecutar. Un import job corre en dos pasos — **validate**, después **run** — y esto es deliberado: un inventario malformado que se importa a medias en silencio produce un informe de TCO confiadamente equivocado.

```bash
gcloud alpha migration-center import-jobs create dc1-manual-2026q3 \
  --location="${REGION}" --asset-source=projects/${PROJECT_ID}/locations/${REGION}/sources/manual-dc1

gcloud alpha migration-center import-jobs validate dc1-manual-2026q3 --location="${REGION}"
gcloud alpha migration-center import-jobs run      dc1-manual-2026q3 --location="${REGION}"
gcloud alpha migration-center import-jobs describe dc1-manual-2026q3 --location="${REGION}" \
  --format="yaml(state, executionReport.framesReported, executionReport.executionErrors)"
```

```yaml
state: COMPLETED
executionReport:
  framesReported: 480
  executionErrors: {}
```

6. Leé el número de vuelta de forma independiente. `framesReported: 480` tiene que ser igual a la cantidad de filas que enviaste:

```bash
tail -n +2 dc1-inventory.csv | wc -l
```

```
480
```

> **Preguntas de control — bloque 1**
>
> **Q1.** Nombrá las cuatro fases del framework de migración de Google en orden.
> **Q2.** El CFO de Acme pide una estimación de costo de nube en la semana uno, antes de que se haya corrido cualquier descubrimiento. ¿Qué está mal en producirla, en términos del framework?
> **Q3.** El discovery client de Migration Center y una exportación RVTools producen ambos un inventario. ¿Qué te da el discovery client que una exportación RVTools de una sola vez no da, y qué decisión posterior depende de eso?
> **Q4.** ¿Por qué el import job separa `validate` de `run`?
> **Q5.** El paso 6 cuenta filas en el CSV y las compara con `framesReported`. ¿Por qué no alcanza con verificar el `state: COMPLETED` del job?

---

## Ejercicio 2 — Plan: asigná una ruta de migración a cada carga de trabajo

Google nombra tres rutas de migración ([Migration to Google Cloud: choosing your path](https://cloud.google.com/architecture/migration-to-gcp-getting-started)):

| Ruta | También llamada | Qué cambia | Destino típico |
|---|---|---|---|
| **Lift and shift** | rehost | Nada en la aplicación | Compute Engine |
| **Improve and move** | replatform | El empaquetado/runtime, no la estructura del código | GKE, Cloud SQL, Cloud Run |
| **Rip and replace** | refactor / rebuild | La aplicación se reescribe o se retira en favor de un producto SaaS | Servicios gestionados y serverless, Google Workspace, Marketplace SaaS |

La taxonomía más amplia de la industria agrega **retire** (borrarla) y **retain** (dejarla donde está). Ambas son resultados legítimos de una migración y ambas aparecen en escenarios del examen.

1. Generá un preference set — esto es lo que le dice a Migration Center *cómo* dimensionar y tarifar el destino, p. ej. sole-tenancy para licenciamiento, supuestos de committed-use, región destino:

```bash
gcloud alpha migration-center preference-sets create acme-default \
  --location="${REGION}" \
  --virtual-machine-preferences-target-product=COMPUTE_ENGINE \
  --virtual-machine-preferences-region-preferences-preferred-regions="${REGION}" \
  --virtual-machine-preferences-commitment-plan=COMMITMENT_PLAN_THREE_YEAR
```

2. Producí el informe de evaluación para el grupo y leé el veredicto de dimensionamiento:

```bash
gcloud alpha migration-center reports create tco-dc1-app-tier \
  --location="${REGION}" \
  --report-config=projects/${PROJECT_ID}/locations/${REGION}/reportConfigs/acme-rc \
  --type=TOTAL_COST_OF_OWNERSHIP
```

3. Ahora hacé la parte que ninguna herramienta hace por vos. Completá esta tabla para las seis clases de carga de trabajo de Acme. Escribí una ruta por fila y una oración de justificación:

| # | Carga de trabajo | Restricción dominante | Ruta | Servicio destino |
|---|---|---|---|---|
| 1 | 400 servidores de aplicación RHEL stateless, código propio, baja tasa de cambio | Alquiler del datacenter, 14 meses | ? | ? |
| 2 | MySQL 8.0 OLTP de 12 TB, requisito de 3 ms p99 | Carga operativa; parcheo; HA | ? | ? |
| 3 | Warehouse Teradata de 90 TB, 200 analistas | Costo de licencia; techo de concurrencia | ? | ? |
| 4 | SAP ECC, solo hardware certificado por el proveedor | Matriz de soporte del proveedor | ? | ? |
| 5 | Exchange interno + recursos compartidos de archivos para 6 000 empleados | No diferenciador; commodity | ? | ? |
| 6 | 40 VMs corriendo una herramienta de reporting de 2014 dada de baja, 0 logins en 90 días | Nadie la usa | ? | ? |

4. Para la carga de trabajo 1, verificá qué diría el right-sizing sobre las formas de máquina que estás por rehostear. Los recommenders de Active Assist operan sobre instancias de Compute Engine en ejecución, así que corré esto contra una oleada piloto ya en Google Cloud ([Recommender docs](https://cloud.google.com/recommender/docs)):

```bash
gcloud recommender recommendations list \
  --project="${PROJECT_ID}" \
  --location="${ZONE}" \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(name.basename(), \
                  content.overview.resourceName.basename():label=VM, \
                  content.overview.currentMachineType.name:label=CURRENT, \
                  content.overview.recommendedMachineType.name:label=RECOMMENDED, \
                  primaryImpact.costProjection.cost.units:label=USD_PER_MONTH)"
```

```
NAME                                  VM            CURRENT         RECOMMENDED      USD_PER_MONTH
0e9c1e2b-3f44-4a0e-9d31-8f2a1c7b55d1  app-dc1-001   n2-standard-8   n2-standard-4    -97
7a13f5c8-9b02-4d77-8e5a-2c6f4b1d90a2  app-dc1-014   n2-standard-8   n2-standard-2    -146
```

> **Preguntas de control — bloque 2**
>
> **Q6.** Dá el nombre preferido por Google para cada uno de: rehost, replatform, refactor.
> **Q7.** Para cada una de las seis cargas de trabajo de Acme, indicá la ruta que elegiste y la única restricción que la forzó.
> **Q8.** Un stakeholder argumenta que lift and shift es "la forma equivocada de hacer nube" y que todo debería refactorizarse antes de que venza el alquiler. Dá dos argumentos concretos a favor de lift and shift como *primer* paso, y un costo real de elegirlo.
> **Q9.** El recommender del paso 4 devuelve valores negativos de `USD_PER_MONTH`. ¿Qué significa el signo, y por qué este recommender es inútil durante la fase assess para VMs on-premises?
> **Q10.** ¿Cuál de las seis cargas de trabajo es la "migración" más barata posible, y qué te dice eso sobre el valor de la fase de evaluación?

---

## Ejercicio 3 — Deploy, ruta 1: rehostear VMs con Migrate to Virtual Machines

Migrate to Virtual Machines replica una VM origen en ejecución hacia Google Cloud, adapta el SO invitado (drivers, agentes, licenciamiento) y hace el cut-over ([Migrate to Virtual Machines docs](https://cloud.google.com/migrate/virtual-machines/docs)).

1. Habilitá el servicio e inspeccioná la superficie:

```bash
gcloud services enable vmmigration.googleapis.com
gcloud alpha migration vms --help | sed -n '/^GROUPS/,/^COMMANDS/p'
```

2. Un **migration source** representa el entorno on-premises. Para vSphere desplegás el appliance Migrate Connector (un OVA) dentro de vCenter, y este se registra contra el source. Listá lo que se registró:

```bash
gcloud alpha migration vms sources list --location="${REGION}"
```

```
NAME          LOCATION      STATE   CREATE_TIME
vsphere-dc1   us-central1   ACTIVE  2026-09-02T11:04:19Z
```

3. Agregá VMs a una migración y arrancá la replicación. La propiedad crítica: **la VM origen sigue sirviendo tráfico durante la replicación.** El connector hace una copia inicial completa y después copias incrementales repetidas usando changed-block tracking, así que el downtime queda acotado por el *último* incremento, no por el tamaño total de los datos.

```bash
gcloud alpha migration vms migrations list \
  --source=vsphere-dc1 --location="${REGION}" \
  --format="table(name.basename(), state, lastSync.lastSyncTime, currentSyncInfo.progressPercent)"
```

```
NAME          STATE       LAST_SYNC_TIME        PROGRESS
app-dc1-001   ACTIVE      2026-09-08T02:11:47Z  100
app-dc1-002   ACTIVE      2026-09-08T02:14:02Z  100
app-dc1-003   REPLICATING 2026-09-08T01:52:10Z  61
```

4. **Test-clone antes del cut-over.** Un clone construye una instancia real de Compute Engine a partir del último snapshot de replicación mientras la replicación sigue intacta. Este es el ensayo que desactiva el riesgo de la ventana de cut-over:

```bash
gcloud alpha migration vms migrations clone app-dc1-001 \
  --source=vsphere-dc1 --location="${REGION}"
```

5. Validá el clone como una instancia común de Compute Engine:

```bash
gcloud compute instances list --filter="name~app-dc1-001" \
  --format="table(name, zone.basename(), machineType.basename(), status, networkInterfaces[0].networkIP)"
```

```
NAME               ZONE           MACHINE_TYPE     STATUS   INTERNAL_IP
app-dc1-001-clone  us-central1-a  n2-standard-4    RUNNING  10.128.0.24
```

6. Hacé el cut-over solo después de que el clone pase las pruebas funcionales. El cut-over detiene la VM origen, ejecuta una última sincronización incremental y crea la instancia de producción.

> **Preguntas de control — bloque 3**
>
> **Q11.** Durante la replicación la VM origen está corriendo. ¿Qué determina la duración de la interrupción del cut-over, y por qué no es proporcional al tamaño de disco de la VM?
> **Q12.** ¿Para qué sirve un test-clone, y qué perderías si saltaras directo al cut-over?
> **Q13.** Acme rehostea una VM de 8 vCPU que el recommender de right-sizing después dice que debería ser de 4 vCPU. ¿Falló la migración? Respondé usando el framework de cuatro fases.
> **Q14.** ¿A qué fase del framework pertenece el test-clone, y a qué fase pertenece el cut-over del paso 6?

---

## Ejercicio 4 — Deploy, ruta 2: mover los datos

El movimiento de datos es donde las migraciones realmente se estancan, y el examen evalúa la regla de selección, no la sintaxis.

### 4a — Hacé primero la aritmética de ancho de banda

1. Calculá el volumen diario de transferencia alcanzable. Asumí que podés sostener ~80% de la capacidad nominal del enlace:

| Enlace | 80% efectivo | Por día | 240 TB tarda |
|---|---|---|---|
| 100 Mbps | 10 MB/s | 0,86 TB | ~278 días |
| 1 Gbps | 100 MB/s | 8,6 TB | **~28 días** |
| 10 Gbps | 1 GB/s | 86 TB | ~2,8 días |

2. Aplicá la guía publicada por Google: usá **Transfer Appliance** — un dispositivo de almacenamiento cifrado, enviado físicamente, ofrecido en capacidades de 40 TB y 300 TB — cuando una transferencia online tardaría más de aproximadamente una semana ([Transfer Appliance docs](https://cloud.google.com/transfer-appliance/docs)). El archivo de 240 TB de Acme sobre 1 Gbps son 28 días *con el enlace saturado*, lo que además deja sin recursos a cualquier otra carga de trabajo que comparta esa WAN.

### 4b — Transferencia online para lo que entra: Storage Transfer Service

3. Creá un agent pool e instalá los transfer agents junto a los datos ([Storage Transfer Service](https://cloud.google.com/storage-transfer/docs/overview)):

```bash
gcloud transfer agent-pools create acme-onprem-pool \
  --bandwidth-limit=400 \
  --display-name="DC1 NFS agents"

gcloud transfer agents install \
  --pool=acme-onprem-pool \
  --count=4 \
  --mount-directories=/mnt/archive
```

```
Created agent pool: projects/acme-migration-prod/agentPools/acme-onprem-pool
[4] agents installed and connected to pool [acme-onprem-pool].
```

Notá el `--bandwidth-limit=400` (MB/s): limitar la migración para que no consuma la WAN de producción es una decisión de diseño, no una ocurrencia posterior.

4. Creá el job. Un recurso `TransferJob` completo y sintácticamente válido, que es lo que la CLI construye por vos:

```json
{
  "description": "DC1 NFS archive -> GCS nearline landing",
  "projectId": "acme-migration-prod",
  "status": "ENABLED",
  "transferSpec": {
    "sourceAgentPoolName": "projects/acme-migration-prod/agentPools/acme-onprem-pool",
    "posixDataSource": {
      "rootDirectory": "/mnt/archive"
    },
    "gcsDataSink": {
      "bucketName": "acme-archive-landing",
      "path": "dc1/scanned-documents/"
    },
    "transferOptions": {
      "overwriteObjectsAlreadyExistingInSink": false,
      "deleteObjectsFromSourceAfterTransfer": false,
      "deleteObjectsUniqueInSink": false
    }
  },
  "schedule": {
    "scheduleStartDate": { "year": 2026, "month": 9, "day": 15 },
    "startTimeOfDay":    { "hours": 22, "minutes": 0, "seconds": 0, "nanos": 0 },
    "repeatInterval": "86400s"
  },
  "loggingConfig": {
    "logActions": ["COPY"],
    "logActionStates": ["SUCCEEDED", "FAILED"]
  }
}
```

5. El equivalente en una línea, y su salida:

```bash
gcloud transfer jobs create posix:///mnt/archive gs://acme-archive-landing/dc1/scanned-documents \
  --source-agent-pool=acme-onprem-pool \
  --name=dc1-archive-nightly \
  --schedule-repeats-every=24h \
  --no-delete-from=source
```

```
Created job: transferJobs/dc1-archive-nightly
```

### 4c — Migración de bases de datos con downtime mínimo

6. Database Migration Service mueve MySQL, PostgreSQL, Oracle y SQL Server hacia Cloud SQL / AlloyDB, con captura continua de cambios ([DMS docs](https://cloud.google.com/database-migration/docs)). Creá el perfil de conexión origen:

```bash
gcloud database-migration connection-profiles create mysql onprem-mysql-src \
  --region="${REGION}" \
  --host=10.10.9.40 --port=3306 \
  --username=dms_replica \
  --password="${DMS_PASSWORD}"     # in production: read from Secret Manager
```

7. Creá el perfil destino y el migration job. `--type=CONTINUOUS` es la elección que te compra un cut-over corto:

```bash
gcloud database-migration connection-profiles create cloudsql acme-mysql-target \
  --region="${REGION}" \
  --source-id=onprem-mysql-src \
  --tier=db-n1-standard-8 \
  --database-version=MYSQL_8_0 \
  --storage-auto-resize \
  --root-password="${ROOT_PASSWORD}"

gcloud database-migration migration-jobs create mysql-to-cloudsql \
  --region="${REGION}" \
  --type=CONTINUOUS \
  --source=onprem-mysql-src \
  --destination=acme-mysql-target \
  --peer-vpc="projects/${PROJECT_ID}/global/networks/acme-vpc"
```

8. **Verificá, después arrancá.** `verify` corre chequeos previos de conectividad, privilegios y configuración sin mover un byte:

```bash
gcloud database-migration migration-jobs verify mysql-to-cloudsql --region="${REGION}"
gcloud database-migration migration-jobs start  mysql-to-cloudsql --region="${REGION}"

gcloud database-migration migration-jobs describe mysql-to-cloudsql \
  --region="${REGION}" --format="yaml(state, phase, error)"
```

```yaml
state: RUNNING
phase: CDC
error: null
```

9. Hacé el cut-over promoviendo el destino. Solo en ese instante la réplica se convierte en un primario independiente y escribible:

```bash
gcloud database-migration migration-jobs promote mysql-to-cloudsql --region="${REGION}"
```

### 4d — El warehouse

10. El warehouse Teradata de 90 TB no es un problema de movimiento de datos; es un **rip and replace** hacia BigQuery, y BigQuery Migration Service existe para la parte que no son datos: el traductor de SQL por lotes convierte el dialecto DDL/DML de Teradata a GoogleSQL ([BigQuery migration overview](https://cloud.google.com/bigquery/docs/migration-intro)).

> **Preguntas de control — bloque 4**
>
> **Q15.** Acme tiene 240 TB sobre un enlace de 1 Gbps. Mostrá la aritmética que decide entre Storage Transfer Service y Transfer Appliance, e indicá la decisión.
> **Q16.** ¿Qué protege `--bandwidth-limit=400`, y qué te cuesta?
> **Q17.** En el job de DMS, ¿cuál es la diferencia práctica entre `--type=ONE_TIME` y `--type=CONTINUOUS` medida en downtime de la aplicación?
> **Q18.** `promote` es un comando separado y explícito. ¿Por qué eso es una característica y no un paso extra?
> **Q19.** El equipo de Acme propone mover Teradata a una VM grande de Compute Engine corriendo Teradata, "para migrar primero y modernizar después". Nombrá la ruta que eso representa, y un argumento fuerte en contra acá que no aplica a los 400 servidores de aplicación.
> **Q20.** ¿Cuál de estas cuatro herramientas — Storage Transfer Service, Transfer Appliance, Database Migration Service, BigQuery Migration Service — es la que no encaja, y por qué?

---

## Ejercicio 5 — Híbrido es un destino, no un fracaso

La instancia SAP ECC de Acme y un puñado de sistemas limitados por latencia se quedan on-premises más allá del alquiler. La respuesta de Google Cloud a "no podés mover todo" es conectividad híbrida más un plano de control consistente.

1. Elegí la conectividad. Opciones publicadas ([Network Connectivity docs](https://cloud.google.com/network-connectivity/docs/interconnect)):

| Opción | Capacidad | SLA sobre la conexión | Camino del tráfico |
|---|---|---|---|
| HA VPN | hasta 3 Gbps por túnel | 99,99% (dos interfaces) | Sobre la internet pública, cifrado con IPsec |
| Dedicated Interconnect | circuitos de 10 o 100 Gbps | 99,9% / 99,99% según la topología | Privado, directo a Google |
| Partner Interconnect | 50 Mbps – 50 Gbps | 99,9% / 99,99% según la topología | Privado, vía un proveedor de servicios |
| Direct / Carrier Peering | varía | ninguno | Llega a los servicios públicos de Google, **no** a tu VPC |

2. Construí HA VPN como enlace interino mientras se aprovisiona el circuito de Interconnect (Interconnect tiene un tiempo de espera físico; VPN no):

```bash
gcloud compute vpn-gateways create acme-ha-vpn-gw \
  --network=acme-vpc --region="${REGION}"

gcloud compute routers create acme-cr \
  --network=acme-vpc --region="${REGION}" --asn=65001

gcloud compute external-vpn-gateways create onprem-gw \
  --interfaces 0=203.0.113.10,1=203.0.113.11

gcloud compute vpn-tunnels create tunnel-0 \
  --region="${REGION}" \
  --vpn-gateway=acme-ha-vpn-gw --interface=0 \
  --peer-external-gateway=onprem-gw --peer-external-gateway-interface=0 \
  --ike-version=2 --shared-secret="${PSK}" --router=acme-cr

gcloud compute routers add-interface acme-cr \
  --region="${REGION}" --interface-name=if-tunnel-0 \
  --vpn-tunnel=tunnel-0 --ip-address=169.254.0.2 --mask-length=30

gcloud compute routers add-bgp-peer acme-cr \
  --region="${REGION}" --peer-name=bgp-onprem-0 \
  --interface=if-tunnel-0 --peer-ip-address=169.254.0.1 --peer-asn=65500
```

3. Confirmá el túnel y la sesión BGP — un túnel `ESTABLISHED` sin sesión BGP no aprende ninguna ruta:

```bash
gcloud compute vpn-tunnels describe tunnel-0 --region="${REGION}" \
  --format="value(status, detailedStatus)"
gcloud compute routers get-status acme-cr --region="${REGION}" \
  --format="table(result.bgpPeerStatus[].name, result.bgpPeerStatus[].state, \
                  result.bgpPeerStatus[].numLearnedRoutes)"
```

```
ESTABLISHED     Tunnel is up and running.

NAME           STATE        NUM_LEARNED_ROUTES
bgp-onprem-0   Established  14
```

4. Registrá el clúster de Kubernetes on-premises que sobrevive dentro de una **fleet**, para que un solo plano de control gobierne ambos lados ([Fleet management](https://cloud.google.com/kubernetes-engine/fleet-management/docs)):

```bash
gcloud container fleet memberships register on-prem-dc1 \
  --context=onprem-admin \
  --kubeconfig="${HOME}/.kube/config" \
  --enable-workload-identity

gcloud container fleet memberships list \
  --format="table(name.basename(), endpoint.kubernetesMetadata.kubernetesApiServerVersion, state.code)"
```

```
NAME         K8S_VERSION   STATE
on-prem-dc1  v1.31.4       READY
gke-prod-1   v1.32.2       READY
```

5. Aplicá una única línea base de política y configuración a ambos clústeres con Config Sync y Policy Controller. `apply-spec.yaml`:

```yaml
applySpecVersion: 1
spec:
  configSync:
    enabled: true
    sourceFormat: unstructured
    syncRepo: https://github.com/acme-retail/platform-config
    syncBranch: main
    policyDir: clusters/on-prem-dc1
    secretType: token
  policyController:
    enabled: true
    templateLibraryInstalled: true
    referentialRulesEnabled: true
    auditIntervalSeconds: 60
```

```bash
gcloud container fleet config-management enable
gcloud container fleet config-management apply \
  --membership=on-prem-dc1 --config=apply-spec.yaml
gcloud container fleet config-management status
```

```
Name         Status   Last_Synced_Token  Sync_Branch  Policy_Controller
on-prem-dc1  SYNCED   a91f3c7            main         INSTALLED
gke-prod-1   SYNCED   a91f3c7            main         INSTALLED
```

> **Preguntas de control — bloque 5**
>
> **Q21.** Acme necesita un enlace privado de 10 Gbps con SLA hacia su VPC en 8 semanas. ¿Qué opción, y qué opción desplegarías *esta semana* mientras tanto?
> **Q22.** Un colega propone Direct Peering para llegar a VMs de Compute Engine sobre una IP privada. ¿Qué está mal con eso?
> **Q23.** En el paso 3, el túnel está `ESTABLISHED` pero `NUM_LEARNED_ROUTES` es 0. ¿Está funcionando el enlace de migración? Explicá.
> **Q24.** Ambos clústeres reportan el mismo `Last_Synced_Token`. En una oración, ¿qué problema de negocio resuelve eso para una organización en medio de una transición?
> **Q25.** Dá una razón por la que una organización mantendría deliberadamente una carga de trabajo on-premises para siempre y aun así llamaría exitosa a su transición a la nube.

---

## Ejercicio 6 — La landing zone y el Cloud Adoption Framework

Una migración hacia una maraña de proyectos sin estructura es una futura re-migración. La **landing zone** es el hogar preconstruido: identidad, jerarquía de recursos, redes y controles de seguridad, en su lugar antes de que llegue la primera carga de trabajo ([Landing zone design](https://cloud.google.com/architecture/landing-zones)).

1. Establecé la jerarquía de recursos — Organization → Folders → Projects → recursos. La política definida en un nodo se hereda hacia abajo, que es la razón entera por la que la jerarquía es un control de seguridad y no solo prolijidad:

```bash
gcloud resource-manager folders create --display-name="core"        --organization="${ORG_ID}"
gcloud resource-manager folders create --display-name="production"  --organization="${ORG_ID}"
gcloud resource-manager folders create --display-name="non-production" --organization="${ORG_ID}"

gcloud resource-manager folders list --organization="${ORG_ID}" \
  --format="table(displayName, name.basename(), lifecycleState)"
```

```
DISPLAY_NAME     ID             LIFECYCLE_STATE
core             451209887301   ACTIVE
production       451209887302   ACTIVE
non-production   451209887303   ACTIVE
```

2. Expresá lo mismo como código, porque una landing zone que no podés reconstruir no es una landing zone. Terraform válido:

```hcl
resource "google_folder" "production" {
  display_name = "production"
  parent       = "organizations/123456789012"
}

resource "google_project" "app_prod" {
  name            = "acme-app-prod"
  project_id      = "acme-app-prod"
  folder_id       = google_folder.production.name
  billing_account = "01ABCD-234567-89EFGH"
}

# Inherited guardrail: no VM in production may have an external IP.
resource "google_org_policy_policy" "no_external_ip" {
  name   = "${google_folder.production.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.production.name

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}
```

3. Verificá que el guardrail sea heredado por el proyecto, y no meramente declarado en la carpeta:

```bash
gcloud org-policies describe compute.vmExternalIpAccess \
  --project="${PROJECT_ID}" --effective
```

```yaml
name: projects/acme-migration-prod/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

4. Puntuá a la *organización*, no a la tecnología. El [Google Cloud Adoption Framework](https://cloud.google.com/adoption-framework) evalúa cuatro temas — **Learn, Lead, Scale, Secure** — a través de tres fases de madurez — **Tactical, Strategic, Transformational**. Completalo para Acme tal como se la describió:

| Tema | Qué pregunta | Acme hoy | Fase |
|---|---|---|---|
| Learn | Calidad y escala de la capacitación; uso de partners | 3 ingenieros autodidactas, sin programa | ? |
| Lead | Patrocinio ejecutivo; equipos multifuncionales | El CTO patrocina; equipo de proyecto solo de IT | ? |
| Scale | Uso de servicios cloud-native; automatización | Todo manual, todo rehost | ? |
| Secure | Identidad, controles, cumplimiento automatizado | Modelo de perímetro, revisiones manuales | ? |

5. Abordá la brecha de Learn explícitamente — la transición es un problema de personas al menos tanto como un problema de cargas de trabajo. Las palancas publicadas por Google: capacitación y rutas de certificación de Google Cloud Skills Boost, el ecosistema de partners, engagements con la Professional Services Organization, y programas como el Rapid Assessment & Migration Program (RAMP), cuyo tooling de evaluación ahora se expone a través de Migration Center.

> **Preguntas de control — bloque 6**
>
> **Q26.** Nombrá los cuatro niveles de la jerarquía de recursos de Google Cloud, de arriba hacia abajo.
> **Q27.** Nombrá los cuatro temas del Cloud Adoption Framework y las tres fases de madurez.
> **Q28.** Asigná una fase de madurez a cada una de las cuatro filas de Acme del paso 4, con una oración cada una.
> **Q29.** El plan de Acme dice "construir la landing zone después de que aterricen las primeras 50 VMs, para mostrar progreso temprano". Dá el argumento técnico más fuerte en contra, haciendo referencia a la salida del paso 3.
> **Q30.** Acme puntúa Tactical en Learn pero se comprometió a una fecha límite de 14 meses. ¿Qué tema del CAF predice que la migración va a fallar, y por qué comprar más servicios de nube no es la solución?

---

## Ejercicio 7 — Optimize: la fase que la mayoría de las organizaciones se saltea

La economía de la nube es un cambio de **CapEx** (comprar hardware para el pico, depreciar en 5 años) a **OpEx** (pagar por consumo). Ese cambio solo rinde si alguien actúa sobre los datos de consumo.

1. Poné un presupuesto y alertas en su lugar antes de que aterricen las oleadas de migración, no después:

```bash
gcloud billing budgets create \
  --billing-account="${BILLING_ACCOUNT}" \
  --display-name="acme-migration-fy26" \
  --budget-amount=250000USD \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=0.8,basis=forecasted-spend
```

```
Created budget [billingAccounts/01ABCD-234567-89EFGH/budgets/8f2c...9b1].
```

Notá la regla `forecasted-spend`: dispara sobre la trayectoria, que es el único umbral que llega a tiempo de cambiar algo.

2. Encontrá el desperdicio que un lift and shift importa necesariamente — los recursos ociosos son el hábito on-premises que sobrevive a la mudanza:

```bash
gcloud recommender insights list \
  --project="${PROJECT_ID}" --location="${ZONE}" \
  --insight-type=google.compute.instance.IdleResourceInsight \
  --format="table(name.basename(), content.resourceName.basename():label=VM, \
                  insightSubtype, severity)"
```

```
NAME                                  VM             INSIGHT_SUBTYPE  SEVERITY
b0f31c9a-77d4-4f61-9c8e-2a5b41d0ee73  rpt-legacy-04  IDLE             HIGH
c4a92f18-2b60-4e35-a1d7-6f3c88b21a55  rpt-legacy-09  IDLE             HIGH
```

3. Preguntale a Google Cloud qué compromiso compraría, una vez que el parque se estabilizó:

```bash
gcloud recommender recommendations list \
  --project="${PROJECT_ID}" --location="${REGION}" \
  --recommender=google.compute.commitment.UsageCommitmentRecommender \
  --format="table(name.basename(), description, \
                  primaryImpact.costProjection.cost.units:label=MONTHLY_DELTA_USD)"
```

4. Razoná sobre el modelo de descuentos. Mecanismos publicados ([Compute Engine pricing](https://cloud.google.com/compute/vm-instance-pricing) — verificá las tarifas actuales, cambian):

| Mecanismo | Requiere un compromiso | Ahorro típico | Encaja con |
|---|---|---|---|
| Sustained use discounts (SUDs) | No — automático | hasta ~30% | VMs estables que te olvidaste de optimizar |
| CUDs basados en recursos (1 / 3 años) | Sí, sobre vCPU+RAM en una región | ~37% / ~55% | Línea base predecible |
| CUDs flexibles (basados en gasto) | Sí, sobre gasto por hora | ~28% / ~46% | Gasto predecible, formas cambiantes |
| Spot VMs | No | hasta ~60–91% | Batch tolerante a fallos e interrumpible |
| Tipos de máquina personalizados / right-sizing | No | varía | Cargas de trabajo que no encajan en ninguna forma predefinida |

5. Ahora el juicio relevante para el examen: determiná qué mecanismo aplica a cada uno de los casos de Acme.

   a. 400 servidores de aplicación, corriendo 24×7, con las formas todavía en proceso de right-sizing durante los próximos 4 meses.
   b. Granja de render batch nocturna de 6 horas, con checkpoints completos, tolerante a la expulsión.
   c. Base de datos de producción en Cloud SQL, tamaño fijo, que se queda 3+ años.
   d. VMs de dev/test que los ingenieros se olvidan de apagar el fin de semana.

6. Modelá el costo total correctamente. El gasto on-premises que desaparece tiene que contarse del lado del haber: renovación de hardware, alquiler y energía del datacenter, licenciamiento de hipervisor y SO, contratos de soporte de arrays de almacenamiento, y las horas de personal gastadas parcheándolos. Usá la [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) contra la salida dimensionada de Migration Center en vez de contra las formas de las VMs origen.

> **Preguntas de control — bloque 7**
>
> **Q31.** Explicá el cambio CapEx→OpEx en una oración, e indicá la única condición organizacional bajo la cual *falla* en ahorrar dinero.
> **Q32.** ¿Por qué la regla de umbral `forecasted-spend` es más útil que la regla de gasto real `percent=1.0`?
> **Q33.** Para cada uno de los cuatro casos del paso 5, nombrá el mecanismo de precios.
> **Q34.** ¿Por qué deliberadamente *no* comprarías un CUD de 3 años en el mes uno de una migración, aunque tenga el descuento más grande?
> **Q35.** El informe de TCO de Acme muestra a Google Cloud costando 8% más por año que la tasa de gasto actual del datacenter. Nombrá tres categorías de costo que probablemente falten del lado on-premises de esa comparación.

---

## Ejercicio 8 — Síntesis: secuenciá la transición completa

1. Producí un plan de 14 meses para Acme como una lista ordenada. Usá exactamente estos bloques constructivos, cada uno una vez, y justificá el orden:

`Migration Center assessment` · `landing zone` · `HA VPN` · `Dedicated Interconnect` · `retire the legacy reporting tool` · `Transfer Appliance for the archive` · `pilot wave of 20 rehosted VMs` · `DMS continuous migration + promote` · `remaining 380 VMs via Migrate to VMs` · `BigQuery Migration Service for Teradata` · `fleet registration for the SAP-adjacent cluster` · `CUD purchase` · `Active Assist right-sizing loop`

2. Para cada bloque, etiquetalo con su fase del framework: **assess / plan / deploy / optimize**.

3. Identificá los dos bloques que podrían haberse hecho en el mes uno a costo esencialmente cero y que habrían reducido el alcance de todo lo que viene después.

> **Preguntas de control — bloque 8**
>
> **Q36.** Dá tu plan ordenado con una etiqueta de fase por bloque.
> **Q37.** ¿Cuáles son los dos bloques de costo cero y reductores de alcance del paso 3?
> **Q38.** El directorio de Acme pide que "la migración a la nube" se declare completa cuando la última VM haga el cut-over. Argumentá, usando el framework de cuatro fases, por qué ese es el criterio de finalización equivocado.

---

## Limpieza

```bash
gcloud database-migration migration-jobs delete mysql-to-cloudsql --region="${REGION}" --quiet
gcloud transfer jobs delete transferJobs/dc1-archive-nightly
gcloud compute vpn-tunnels delete tunnel-0 --region="${REGION}" --quiet
gcloud compute vpn-gateways delete acme-ha-vpn-gw --region="${REGION}" --quiet
gcloud compute routers delete acme-cr --region="${REGION}" --quiet
gcloud alpha migration-center groups delete app-tier-dc1 --location="${REGION}" --quiet
gcloud container fleet memberships unregister on-prem-dc1 --context=onprem-admin
```

Verificá que nada esté facturando: `gcloud compute instances list` y `gcloud sql instances list` deberían devolver ambos vacío.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Assess

**Q1.** **Assess → Plan → Deploy → Optimize.**

**Q2.** Una estimación de la semana uno no tiene inventario detrás, así que tarifa un parque imaginado. La fase assess existe precisamente para producir los insumos — cantidad de cargas de trabajo, formas, utilización, dependencias, licenciamiento — que consume un modelo de costos. Producir el número primero invierte el framework y convierte una suposición en un compromiso que el CFO te va a reclamar. La respuesta correcta es una fecha para la estimación, no la estimación.

**Q3.** El discovery client recolecta **datos de rendimiento a lo largo del tiempo** (utilización real de CPU, memoria, disco y red), no solo la capacidad asignada. RVTools te dice que a una VM le *dieron* 8 vCPU; el discovery client te dice que *usó* 1,5. La decisión posterior que depende de eso es el **right-sizing** — y por lo tanto el modelo de costos entero. Dimensionar Google Cloud según las asignaciones on-premises reproduce años de sobreaprovisionamiento y produce un informe de TCO que hace ver cara a la nube.

**Q4.** Para que un inventario malformado falle ruidosa y completamente en vez de importarse parcialmente. Un inventario importado a medias igual genera un informe de evaluación — uno internamente consistente y externamente equivocado. `validate` chequea el esquema y reporta errores antes de que se cree ningún activo.

**Q5.** `state: COMPLETED` significa que el job corrió hasta terminar, no que ingirió todo lo que enviaste. Se pueden saltear o rechazar filas mientras el job en conjunto tiene éxito. La única prueba de completitud es comparar la cantidad que enviaste contra `framesReported` — verificá los conteos de forma independiente, por origen, en vez de confiar en un estado agregado.

### Bloque 2 — Plan

**Q6.** rehost = **lift and shift**; replatform = **improve and move**; refactor/rebuild = **rip and replace**.

**Q7.**

| # | Carga de trabajo | Restricción dominante | Ruta | Destino |
|---|---|---|---|---|
| 1 | 400 servidores de aplicación | El alquiler de 14 meses — tiempo, no elegancia | **Lift and shift** | Compute Engine |
| 2 | MySQL de 12 TB | Carga operativa (parcheo, backup, HA) que es trabajo no diferenciador | **Improve and move** | Cloud SQL for MySQL |
| 3 | Warehouse Teradata | Costo de licencia y un techo duro de concurrencia que ningún rehost elimina | **Rip and replace** | BigQuery |
| 4 | SAP ECC | Matriz de soporte del proveedor — una configuración no soportada no es una opción de migración | **Retain** (híbrido), revisar con la ruta certificada del proveedor | On-premises + Interconnect |
| 5 | Exchange + recursos compartidos | Commodity puro; correrlo uno mismo no le da a Acme ninguna ventaja | **Rip and replace** (repurchase) | Google Workspace / SaaS |
| 6 | Herramienta de reporting legacy | Cero usuarios en 90 días | **Retire** | Nada |

**Q8.** A favor: (1) es la única ruta que entra en el alquiler de 14 meses para 400 aplicaciones — refactorizar 400 apps en 14 meses no es un cronograma, es un deseo; (2) desacopla la salida del datacenter del programa de modernización, así un refactor que se atrasa deja de poner en riesgo una fecha límite dura de alquiler. Costo: importás tu ineficiencia existente — formas sobreaprovisionadas, configuración artesanal, operaciones manuales — y la pagás mensualmente en vez de haberla pagado una sola vez. Esa deuda hay que saldarla en la fase optimize o lift and shift genuinamente termina costando más.

**Q9.** Los valores negativos son **ahorros** — el *delta* de costo mensual proyectado si aplicás la recomendación. Es inútil durante assess para VMs on-premises porque el recommender solo observa instancias de Compute Engine en ejecución a través de Cloud Monitoring; no tiene visibilidad sobre vSphere. El insumo de right-sizing on-premises viene en cambio del discovery client de Migration Center.

**Q10.** La carga de trabajo 6, la herramienta de reporting retirada: 40 VMs que no cuestan nada migrar porque se borran. Esto es la fase de evaluación pagándose sola — la carga de trabajo más barata de migrar es la que descubrís que nadie usa. Las organizaciones que se saltean la evaluación migran su peso muerto y pagan alquiler por él para siempre.

### Bloque 3 — Rehost

**Q11.** La interrupción equivale al tiempo de aplicar la **sincronización incremental final** más el arranque y la validación, porque el grueso de los datos se copió mientras el origen todavía servía tráfico. El changed-block tracking significa que el último incremento contiene solo los bloques cambiados desde la sincronización anterior — minutos para una VM mayormente ociosa, sin importar si el disco es de 100 GB o de 2 TB. El tamaño del disco impulsa la duración de la replicación *inicial*, que ocurre con cero downtime.

**Q12.** Un test-clone construye una instancia real de Compute Engine desde el último punto de replicación *mientras la replicación continúa*, así que podés arrancar la VM, correr pruebas funcionales y de integración, y verificar drivers, licenciamiento y alcanzabilidad de red en el entorno destino — todo antes de comprometerte a una interrupción. Saltearlo significa que tu primer descubrimiento de una falla de arranque o un driver roto ocurre dentro de la ventana de cut-over, con el origen ya detenido.

**Q13.** No. El rehosteo es un resultado de la fase **deploy**; el right-sizing es una actividad de la fase **optimize**. El framework las separa deliberadamente para que la presión de cronograma en deploy no bloquee la salida del datacenter. La migración falla solo si la fase optimize nunca ocurre.

**Q14.** El test-clone pertenece a **deploy** (es parte de ejecutar la migración, específicamente su validación); el cut-over también es **deploy**. Ninguno es optimize — optimize empieza después de que la carga de trabajo está corriendo en Google Cloud y se la está ajustando.

### Bloque 4 — Datos

**Q15.** 1 Gbps al ~80% efectivo ≈ 100 MB/s ≈ 8,6 TB/día. 240 TB ÷ 8,6 TB/día ≈ **28 días** de una WAN completamente saturada. La guía de Google es usar Transfer Appliance cuando una transferencia online superaría aproximadamente una semana. Decisión: **Transfer Appliance** (240 TB entra en una unidad de 300 TB), dejando Storage Transfer Service para los deltas incrementales continuos después de que aterrice la carga inicial masiva.

**Q16.** Protege la WAN de producción — sin un tope, los transfer agents van a consumir el enlace entero y degradar cada sistema de cara al usuario que lo comparta. El costo es una transferencia más larga: limitar a 400 MB/s en un enlace que podría dar más extiende directamente la ventana de migración transcurrida. Es un intercambio explícito de velocidad de migración por estabilidad de producción.

**Q17.** `ONE_TIME` toma un dump completo y lo carga; la aplicación tiene que estar en reposo durante toda la duración del dump más la carga — horas o días para 12 TB. `CONTINUOUS` hace el dump inicial y después transmite los cambios vía CDC, así que la aplicación sigue escribiendo al origen todo el tiempo; el downtime es solo el cut-over final — parar las escrituras, dejar drenar el CDC, promover. Minutos en vez de días.

**Q18.** Porque la promoción es irreversible en efecto: rompe la replicación desde el origen y convierte la instancia de Cloud SQL en un primario independiente y escribible. Hacerla un comando separado y deliberado significa que el cut-over ocurre cuando *vos* elegís — después de la validación, en una ventana de mantenimiento, con el rollback todavía disponible hasta ese momento. Una promoción automática al sincronizar le sacaría la decisión al operador.

**Q19.** Eso es **lift and shift**. El argumento en contra, específico de esta carga de trabajo: las razones para dejar Teradata son su costo de licencia y su techo de concurrencia, y rehostear arrastra ambos a Compute Engine sin cambios — ahora pagás licenciamiento de Teradata *más* infraestructura de Google Cloud, y los analistas siguen haciendo cola. Para los 400 servidores de aplicación, rehostear genuinamente difiere costo; acá *agrega* costo sin entregar ninguno de los beneficios. Lift and shift es correcto cuando la restricción es el tiempo; es incorrecto cuando la restricción es el producto en sí.

**Q20.** **BigQuery Migration Service.** Las otras tres mueven bytes de un lugar a otro. El trabajo distintivo de BigQuery Migration Service es traducir el dialecto SQL y el esquema — convertir la *lógica* que rodea a los datos, porque un rip-and-replace cambia el motor, no solo la ubicación.

### Bloque 5 — Híbrido

**Q21.** **Dedicated Interconnect** para el requisito privado de 10 Gbps con SLA. Desplegá **HA VPN** esta semana: se aprovisiona por software en minutos y da 99,99% de disponibilidad, cubriendo el hueco mientras se aprovisiona el circuito físico de Interconnect. Correr ambos también es el diseño de respaldo estándar — VPN como backup del Interconnect.

**Q22.** Direct Peering (y Carrier Peering) provee acceso a los servicios **públicos** de Google y a endpoints de IP pública; no se conecta al espacio de direcciones privadas RFC 1918 de tu VPC, y no lleva SLA. Llegar a VMs de Compute Engine sobre IPs internas requiere Cloud VPN o Cloud Interconnect.

**Q23.** No. El túnel IPsec está arriba, pero sin sesión BGP establecida y sin rutas aprendidas, Cloud Router no tiene nada que anunciar a la tabla de rutas de la VPC y el tráfico no tiene camino. `ESTABLISHED` es una afirmación sobre el túnel, no sobre la alcanzabilidad — exactamente por eso el paso 3 verifica ambos, y es una causa común de "la VPN está arriba pero nada funciona".

**Q24.** Un solo commit de Git define política y configuración para los clústeres on-premises y de nube, así que una organización a caballo entre dos entornos durante una transición de varios años impone una única línea base de cumplimiento en vez de mantener dos divergentes — y la deriva de cualquiera de los lados se detecta y se revierte automáticamente.

**Q25.** Razones legítimas incluyen: una matriz de soporte del proveedor que no certifica ninguna configuración en la nube (el SAP ECC de Acme); restricciones de residencia de datos o regulatorias que ninguna región disponible satisface; latencia de sub-milisegundo hacia equipamiento de planta física; o una carga de trabajo cuyo período de amortización restante hace económicamente irracional moverla. Una transición exitosa es aquella en la que cada carga de trabajo está en su ubicación *correcta*, no una en la que la cantidad de ubicaciones es 1.

### Bloque 6 — Landing zone y CAF

**Q26.** **Organization → Folder → Project → Resource.**

**Q27.** Temas: **Learn, Lead, Scale, Secure.** Fases de madurez: **Tactical, Strategic, Transformational.**

**Q28.**
- Learn — **Tactical.** Tres ingenieros autodidactas y ningún programa es iniciativa individual, no capacidad organizacional.
- Lead — **Tactical**, tirando a Strategic. El patrocinio ejecutivo existe, pero un equipo solo de IT significa que el negocio no está co-apropiándose de los resultados; la fase Strategic del CAF requiere equipos multifuncionales.
- Scale — **Tactical.** Todo manual y todo rehost significa que la nube se está consumiendo como hardware alquilado, sin automatización ni apalancamiento de servicios gestionados.
- Secure — **Tactical.** Un modelo de perímetro con revisiones manuales es la postura on-premises trasplantada; Strategic requiere controles centrados en identidad y aplicación automatizada de políticas.

**Q29.** Porque los guardrails se **heredan**, y la herencia solo ayuda a recursos creados *debajo* del nodo que lleva la política. La salida de `--effective` del paso 3 muestra al proyecto recibiendo `denyAll: true` de su carpeta ancestro — un proyecto creado fuera de esa jerarquía no recibe nada. Aterrizar 50 VMs primero significa 50 cargas de trabajo sentadas en proyectos sin estructura, sin política heredada, sin red consistente y sin límites de propiedad; adaptarlas después significa mover proyectos, re-direccionar redes y rehacer IAM. La landing zone es barata de construir antes de la primera carga de trabajo y cara después de la quincuagésima.

**Q30.** **Learn.** La idea central del framework es que la adopción de nube está limitada por la capacidad organizacional, no por la tecnología disponible. Comprar más servicios gestionados contra un puntaje Tactical en Learn aumenta la superficie que nadie del personal puede operar, diagnosticar ni asegurar — convierte una brecha de habilidades en un incidente. La solución es una estrategia de capacitación y partners (rutas de Google Cloud Skills Boost, objetivos de certificación, un engagement con un partner o con PSO para las primeras oleadas) corriendo en paralelo con la migración, no después.

### Bloque 7 — Optimize

**Q31.** CapEx→OpEx reemplaza una gran compra inicial de capacidad dimensionada para el pico, depreciada a lo largo de años, por pago medido de lo que realmente consumís. Falla en ahorrar dinero cuando nadie actúa sobre el consumo — si los recursos se aprovisionan para el pico y nunca se reducen ni se apagan, conservaste el hábito de dimensionamiento on-premises y meramente convertiste un activo que se deprecia en una factura mensual permanente.

**Q32.** Los umbrales de gasto real son retrospectivos: `percent=1.0` dispara cuando el presupuesto ya se fue, y para entonces el gasto es irrecuperable. La regla de forecasted-spend dispara sobre la trayectoria — te avisa en la semana dos que el mes va camino a pasarse — que es la única alerta que llega mientras todavía podés cambiar el resultado.

**Q33.**
- a. 400 servidores de aplicación, formas todavía cambiando → **Sustained use discounts**, aplicados automáticamente sin compromiso, mientras continúa el right-sizing. No fijes un CUD contra formas que estás por cambiar.
- b. Batch con checkpoints y tolerante a la expulsión → **Spot VMs.**
- c. Base de datos de producción de tamaño fijo, 3+ años → **Committed use discount** (de 3 años; basado en recursos, o un compromiso de Cloud SQL según corresponda).
- d. VMs de dev/test olvidadas → no es un mecanismo de precios en absoluto: **recomendaciones de recursos ociosos de Active Assist** más parada/arranque programado de instancias. Descontar desperdicio sigue comprando desperdicio.

**Q34.** Porque un CUD de 3 años te compromete a una cantidad específica de recursos en una región, y en el mes uno todavía no conocés tu forma de estado estable — el right-sizing, el retiro de cargas de trabajo muertas y el replatforming van a reducir y remodelar el consumo. Comprometerse temprano te encierra a pagar por el parque *no optimizado* durante tres años, lo que fácilmente puede exceder al descuento. Dejá que el parque se estabilice, dejá que el Usage Commitment Recommender observe el consumo real, y después comprometete.

**Q35.** Comúnmente ausentes: (1) capital de renovación de hardware — el próximo ciclo de renovación de servidores, arrays de almacenamiento y red, más su depreciación; (2) instalaciones — alquiler del datacenter, energía, refrigeración, seguridad física y pasivo remanente del alquiler; (3) licenciamiento y contratos de soporte — renovaciones de soporte de hipervisor, SO, arrays de almacenamiento y bases de datos. También omitidos con frecuencia: horas de personal gastadas en parcheo, backup y planificación de capacidad; capacidad de recuperación ante desastres que queda ociosa; y el costo del tiempo de espera de aprovisionamiento (semanas para agregar capacidad versus minutos).

### Bloque 8 — Síntesis

**Q36.** Un orden defendible:

| # | Bloque | Fase |
|---|---|---|
| 1 | Migration Center assessment | **Assess** |
| 2 | Retire the legacy reporting tool | **Plan** (actuando sobre la salida de la evaluación; elimina 40 VMs de todos los pasos posteriores) |
| 3 | Landing zone | **Plan** |
| 4 | HA VPN | **Plan/Deploy** — conectividad disponible en días |
| 5 | Pilot wave of 20 rehosted VMs | **Deploy** — valida la landing zone y el tooling con bajo riesgo |
| 6 | Dedicated Interconnect | **Deploy** — aterriza después de su tiempo de aprovisionamiento, antes de las oleadas masivas |
| 7 | Transfer Appliance for the archive | **Deploy** — tiempo de envío físico, empezar temprano |
| 8 | Remaining 380 VMs via Migrate to VMs | **Deploy** |
| 9 | DMS continuous migration + promote | **Deploy** — cut-over agendado junto con la capa de aplicación que depende de ella |
| 10 | BigQuery Migration Service for Teradata | **Deploy** — vía independiente, la más larga porque es una reescritura |
| 11 | Fleet registration for the SAP-adjacent cluster | **Deploy** — hace gobernable el estado híbrido permanente |
| 12 | Active Assist right-sizing loop | **Optimize** |
| 13 | CUD purchase | **Optimize** — al final, después de que las formas se estabilizaron |

Fundamento del orden: la evaluación condiciona todo; el retiro achica el alcance antes de que pagues por mover nada; la landing zone tiene que preceder a la primera carga de trabajo porque la política se hereda; la conectividad y el appliance arrancan temprano porque tienen tiempos de espera físicos; el piloto precede a la oleada masiva; el right-sizing precede a la compra de compromisos.

**Q37.** **La evaluación con Migration Center** y **retirar la herramienta de reporting legacy.** Ambos cuestan esencialmente nada, y ambos achican el alcance de cada bloque subsiguiente — la evaluación hace right-sizing de 480 VMs antes de que sean tarifadas o movidas, y el retiro elimina 40 de ellas de plano.

**Q38.** Porque el último cut-over marca el final de la fase **deploy**, y el framework tiene cuatro. Declarar la victoria ahí garantiza que la ineficiencia importada del lift and shift — formas sobreaprovisionadas, recursos ociosos, bases de datos no gestionadas, hábitos operativos on-premises — se vuelva costo mensual permanente, y que las cargas de trabajo rehosteadas para cumplir con la fecha límite del alquiler nunca se modernicen. Los criterios honestos de finalización viven en **optimize**: right-sizing aplicado, recursos ociosos eliminados, compromisos comprados contra una línea base estable, operaciones no diferenciadoras entregadas a servicios gestionados, y los puntajes de Learn y Secure del Cloud Adoption Framework movidos fuera de Tactical.

</details>

---

## Fuentes

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Migration to Google Cloud: get started — https://cloud.google.com/architecture/migration-to-gcp-getting-started
- Migration Center overview — https://cloud.google.com/migration-center/docs/migration-center-overview
- Migrate to Virtual Machines — https://cloud.google.com/migrate/virtual-machines/docs
- Database Migration Service — https://cloud.google.com/database-migration/docs
- Storage Transfer Service — https://cloud.google.com/storage-transfer/docs/overview
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs
- BigQuery migration overview — https://cloud.google.com/bigquery/docs/migration-intro
- Cloud Interconnect — https://cloud.google.com/network-connectivity/docs/interconnect
- Cloud VPN overview — https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview
- Fleet management — https://cloud.google.com/kubernetes-engine/fleet-management/docs
- Landing zone design — https://cloud.google.com/architecture/landing-zones
- Google Cloud Adoption Framework — https://cloud.google.com/adoption-framework
- Recommender / Active Assist — https://cloud.google.com/recommender/docs
- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator