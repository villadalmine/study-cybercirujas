# Tema 1.2 — Describir conceptos fundamentales de la nube
## Ejercicios guiados (gcp-cdl · versión de examen 2026-08-12 · peso en el examen 9.0)

> **Qué te pide realmente este tema.** La sección 1.2 de la guía del examen Cloud Digital Leader no es "nombrá las cinco características del NIST". Te pide *razonar sobre una decisión de negocio*: CapEx vs OpEx, el costo total de propiedad, qué modelo de servicio traslada qué carga operativa, y a qué compromete a una organización elegir "pública / privada / híbrida / multicloud". Por eso cada ejercicio de abajo termina en un artefacto que podés poner delante de un CFO, no simplemente en un comando que se ejecutó.
>
> Fuente de referencia: [Cloud Digital Leader exam guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf). Base conceptual: [NIST SP 800-145, *The NIST Definition of Cloud Computing*](https://csrc.nist.gov/pubs/sp/800/145/final).

**Tiempo estimado:** 150–180 minutos. **Gasto estimado:** menos de **USD 2** si completás la sección de limpieza. La mayoría de los pasos son gratuitos (`describe`, `list`, Catalog API); los facturables están marcados con 💸.

---

## Ejercicio 0 — Armá el laboratorio, y ponéle primero un cerco al dinero

Una cuenta de nube sin presupuesto es la forma más común de que un laboratorio "gratis" se convierta en una factura de USD 400. *Servicio medido* significa que el medidor arranca en el instante en que el recurso existe, lo uses o no. Construí la barrera antes que la carga de trabajo.

### Bloque 0.1 — Entorno e identidad

1. Abrí [Cloud Shell](https://cloud.google.com/shell/docs) (`>_` en la consola de Cloud) o instalá la [gcloud CLI](https://cloud.google.com/sdk/docs/install) localmente. Acá Cloud Shell es preferible: es en sí mismo un producto PaaS, y vas a usar ese hecho en el Ejercicio 3.

2. Confirmá el toolchain y la identidad activa:

```bash
gcloud version
gcloud auth list
```

Esperado (las versiones varían; lo que importa es la forma):

```
Google Cloud SDK 5xx.0.0
bq 2.1.x
core 2026.xx.xx
gcloud-crc32c 1.0.0
gsutil 5.xx

     Credentialed Accounts
ACTIVE  ACCOUNT
*       you@example.com

To set the active account, run:
    $ gcloud config set account `ACCOUNT`
```

3. Creá un proyecto dedicado. Un proyecto es la frontera de facturación, cuota e IAM — nunca corras un laboratorio dentro de un proyecto que contenga algo que te importe:

```bash
export PROJECT_ID="cdl-12-lab-$(date +%s | tail -c 6)"
gcloud projects create "$PROJECT_ID" --name="CDL 1.2 lab"
gcloud config set project "$PROJECT_ID"
```

```
Create in progress for [https://cloudresourcemanager.googleapis.com/v1/projects/cdl-12-lab-84021].
Waiting for [operations/cp.7412...] to finish...done.
Enabling service [cloudapis.googleapis.com] on project [cdl-12-lab-84021]...
Updated property [core/project].
```

4. Inspeccioná la jerarquía de recursos en la que aterrizó el proyecto:

```bash
gcloud projects describe "$PROJECT_ID" --format="yaml(projectId,parent,lifecycleState)"
```

```yaml
lifecycleState: ACTIVE
parent:
  id: '481920374652'
  type: organization
projectId: cdl-12-lab-84021
```

Si `parent` no aparece, tu proyecto no tiene organización (una cuenta personal de Gmail). Tomá nota de esa diferencia — cambia quién puede imponer políticas, que es justamente el punto del Ejercicio 4.

### Bloque 0.2 — Vinculá la facturación y poné el cerco

5. Listá las cuentas de facturación sobre las que podés actuar:

```bash
gcloud billing accounts list
```

```
ACCOUNT_ID            NAME                 OPEN  MASTER_ACCOUNT_ID
01A2B3-C4D5E6-F7G8H9  My Billing Account   True
```

6. Vinculá el proyecto y habilitá las APIs que se usan a lo largo del laboratorio:

```bash
export BILLING_ACCOUNT="01A2B3-C4D5E6-F7G8H9"   # substitute yours
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  cloudresourcemanager.googleapis.com \
  recommender.googleapis.com
```

```
billingAccountName: billingAccounts/01A2B3-C4D5E6-F7G8H9
billingEnabled: true
name: projects/cdl-12-lab-84021/billingInfo
projectId: cdl-12-lab-84021

Operation "operations/acat.p2-481920374652-9c1e..." finished successfully.
```

7. Creá un presupuesto con una alerta **basada en pronóstico**, no solamente una alerta de gasto real. Las alertas de gasto real te avisan que ya perdiste la plata:

```bash
gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="CDL 1.2 lab guard" \
  --budget-amount=10USD \
  --filter-projects="projects/$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=0.9,basis=forecasted-spend
```

```
Created budget [billingAccounts/01A2B3-C4D5E6-F7G8H9/budgets/8f3a1c0e-...].
```

8. Verificá que existe, y leé lo que un presupuesto *no* es:

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --format="table(displayName, amount.specifiedAmount.units, thresholdRules[].thresholdPercent)"
```

```
DISPLAY_NAME       UNITS  THRESHOLD_PERCENT
CDL 1.2 lab guard  10     [0.5, 0.9, 0.9]
```

> Referencia: [Create, edit, or delete budgets and budget alerts](https://cloud.google.com/billing/docs/how-to/budgets).

**Control de comprensión — Ejercicio 0**

- **Q1.** Un presupuesto de USD 10 con un umbral del 100% dispara una alerta. ¿Qué les pasa a las VMs en ejecución en ese momento, por defecto?
- **Q2.** ¿Qué característica esencial del NIST demuestra la existencia de un registro de facturación por proyecto y por SKU, y por qué esa característica hace posible la contabilidad OpEx en primer lugar?
- **Q3.** Vinculaste un *proyecto* a una *cuenta de facturación*. Explicá, en los términos que usa un CFO, a qué corresponde cada uno de esos dos objetos en un modelo financiero tradicional.
- **Q4.** ¿Por qué un umbral basado en pronóstico es operativamente más útil que un umbral de gasto real en un laboratorio, y *menos* útil que una cuota rígida en producción?

---

## Ejercicio 1 — "Servicio medido" es literal: leé la lista de precios como una API

La compra tradicional le pide una cotización a un proveedor. El precio de la nube es un catálogo consultable, versionado y legible por máquina. Entender esto es lo que separa un modelo real de TCO de una adivinanza.

1. Enumerá los servicios facturables. Cada uno tiene un ID de servicio estable:

```bash
TOKEN=$(gcloud auth print-access-token)

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
| jq -r '.services[] | select(.displayName | test("Compute Engine|Cloud Run|Cloud Storage|BigQuery")) | "\(.serviceId)  \(.displayName)"'
```

```
6F81-5844-456A  Compute Engine
152E-C115-5142  Cloud Run
95FF-2EF5-5EA1  Cloud Storage
24E6-581D-38E5  BigQuery
```

2. Traé los SKUs de Compute Engine y aislá un precio unitario concreto — la vCPU-hora on-demand de la familia N2 en `us-central1`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
| jq -r '
  .skus[]
  | select(.category.resourceGroup=="CPU")
  | select(.description | test("^N2 Instance Core running in Americas$"))
  | {
      sku: .skuId,
      desc: .description,
      regions: .serviceRegions,
      usage: .pricingInfo[0].pricingExpression.usageUnitDescription,
      nanos: .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos
    }'
```

```json
{
  "sku": "9B1F-3D07-A9F1",
  "desc": "N2 Instance Core running in Americas",
  "regions": ["us-central1", "us-east1", "us-east4", "us-west1", "..."],
  "usage": "hour",
  "nanos": 31611000
}
```

3. Convertí nanos a dólares y derivá el costo mensual de una máquina que está encendida y nadie toca:

```bash
python3 - <<'PY'
vcpu_hr  = 31611000 / 1e9        # USD per vCPU-hour  (nanos -> USD)
gib_hr   =  4237000 / 1e9        # USD per GiB-hour, N2 RAM, Americas
vcpus, gib, hours = 4, 16, 730   # n2-standard-4, one average month
print(f"vCPU: ${vcpu_hr*vcpus*hours:7.2f}")
print(f"RAM : ${gib_hr*gib*hours:7.2f}")
print(f"TOTAL on-demand, 24x7: ${(vcpu_hr*vcpus + gib_hr*gib)*hours:7.2f}/month")
PY
```

```
vCPU: $  92.30
RAM : $  49.49
TOTAL on-demand, 24x7: $ 141.79/month
```

> ⚠️ Los precios cambian. Los valores de `nanos` de arriba son ilustrativos; el *método* es el entregable. Releelos siempre desde la [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) o la [Pricing Calculator](https://cloud.google.com/products/calculator).

4. Ahora poné precio a la misma forma de máquina en tres regiones y observá que la geografía es una dimensión de precio:

```bash
for R in us-central1 europe-west3 southamerica-east1 asia-northeast1; do
  printf '%-20s' "$R"
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
  | jq -r --arg r "$R" '
      [ .skus[]
        | select(.category.resourceGroup=="CPU")
        | select(.description | startswith("N2 Instance Core running in"))
        | select(.serviceRegions | index($r))
        | .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos ][0] // "n/a"'
done
```

```
us-central1         31611000
europe-west3        37773000
southamerica-east1  49962000
asia-northeast1     40398000
```

**Control de comprensión — Bloque 1**

- **Q5.** La misma `n2-standard-4` cuesta aproximadamente un 58% más en `southamerica-east1` que en `us-central1`. Dá dos razones de negocio por las que un arquitecto igualmente desplegaría ahí, y nombrá la que *no* es negociable.
- **Q6.** La API devolvió un precio por **vCPU-hora** y un precio aparte por **GiB-hora**, no un precio por "servidor". ¿Qué te permite hacer esa descomposición que una cotización tradicional de servidor no permite?
- **Q7.** Un CFO pregunta: "¿Cuánto vamos a gastar en cómputo el año que viene?". Explicá con precisión por qué la respuesta honesta es un *pronóstico con un supuesto de demanda*, y qué característica del NIST hace que sea así.

---

## Ejercicio 2 — Geografía: zonas, regiones, multirregión y la velocidad de la luz

"La nube" tiene coordenadas. Disponibilidad, latencia, costo y exposición legal se desprenden de ellas.

### Bloque 2.1 — La jerarquía

1. Listá las regiones y leé las columnas de cuota como una declaración de capacidad:

```bash
gcloud compute regions list --format="table(name, status, quotas[0].metric, quotas[0].limit)" | head -12
```

```
NAME                     STATUS  METRIC  LIMIT
africa-south1            UP      CPUS    24.0
asia-east1               UP      CPUS    24.0
asia-northeast1          UP      CPUS    24.0
australia-southeast1     UP      CPUS    24.0
europe-north1            UP      CPUS    24.0
europe-west1             UP      CPUS    24.0
me-central1              UP      CPUS    24.0
southamerica-east1       UP      CPUS    24.0
us-central1              UP      CPUS    24.0
```

2. Expandí una región en sus zonas:

```bash
gcloud compute zones list --filter="region:( us-central1 europe-west4 )" \
  --format="table(name, region.basename(), status, nextMaintenanceWindow)"
```

```
NAME             REGION        STATUS  NEXT_MAINTENANCE
europe-west4-a   europe-west4  UP
europe-west4-b   europe-west4  UP
europe-west4-c   europe-west4  UP
us-central1-a    us-central1   UP
us-central1-b    us-central1   UP
us-central1-c    us-central1   UP
us-central1-f    us-central1   UP
```

3. Contá las zonas por región en toda la plataforma — este es tu mapa de radio de impacto:

```bash
gcloud compute zones list --format="value(region.basename())" | sort | uniq -c | sort -rn | head -8
```

```
      4 us-central1
      3 us-east1
      3 europe-west1
      3 asia-east1
      3 southamerica-east1
      ...
```

4. Confirmá que no toda familia de máquinas existe en toda zona. La capacidad es regional, no global:

```bash
for Z in us-central1-a europe-west4-a southamerica-east1-a; do
  printf '%-22s' "$Z"
  gcloud compute machine-types list --zones="$Z" \
    --filter="name~^c3-standard" --format="value(name)" | wc -l
done
```

```
us-central1-a         9
europe-west4-a        9
southamerica-east1-a  0
```

**Control de comprensión — Bloque 2.1**

- **Q8.** Definí *zona* y *región* de modo que alguien sin formación técnica entienda por qué "dos VMs en `us-central1-a` y `us-central1-b`" tiene más disponibilidad que "dos VMs en `us-central1-a`", y por qué eso todavía no es un plan de recuperación ante desastres.
- **Q9.** `southamerica-east1-a` devolvió cero tipos de máquina `c3-standard`. ¿Qué te dice eso sobre el supuesto de que "la nube tiene capacidad infinita de todo tipo, en todos lados"?

### Bloque 2.2 — La latencia es física, no configuración

5. Medí la latencia real de ida y vuelta desde tu ubicación hacia las regiones de Google Cloud usando la herramienta de la propia Google:

```bash
# Cloud Shell: Go is preinstalled
go install github.com/GoogleCloudPlatform/gcping/cmd/gcping@latest
"$(go env GOPATH)/bin/gcping" -n 5 -t 10s
```

```
 1.  us-central1                 12 ms
 2.  us-east4                    28 ms
 3.  us-west1                    41 ms
 4.  northamerica-northeast1     47 ms
 5.  europe-west2               104 ms
 6.  europe-west3               112 ms
 7.  southamerica-east1         156 ms
 8.  asia-northeast1            168 ms
 9.  asia-south1                241 ms
10.  australia-southeast1       196 ms
```

(¿No tenés Go? La misma medición corre en el navegador en [gcping.com](https://gcping.com).)

6. Calculá el piso teórico y comparalo con lo que mediste:

```bash
python3 - <<'PY'
# Great-circle distance is ~ the shortest possible fibre path.
# Light in glass travels at ~2/3 c => ~200,000 km/s. RTT doubles the distance.
for city, km in [("US-central <-> Europe", 7500), ("US-central <-> São Paulo", 8300),
                 ("US-central <-> Tokyo", 10000)]:
    floor_ms = (2 * km) / 200_000 * 1000
    print(f"{city:28s} theoretical RTT floor: {floor_ms:5.1f} ms")
PY
```

```
US-central <-> Europe        theoretical RTT floor:  75.0 ms
US-central <-> São Paulo     theoretical RTT floor:  83.0 ms
US-central <-> Tokyo         theoretical RTT floor: 100.0 ms
```

7. Contrastá un recurso **regional** con uno **multirregión**. Creá dos buckets y leé su tipo de ubicación:

```bash
gcloud storage buckets create "gs://${PROJECT_ID}-regional"    --location=us-central1
gcloud storage buckets create "gs://${PROJECT_ID}-multiregion" --location=us

gcloud storage buckets describe "gs://${PROJECT_ID}-regional"    --format="value(location,location_type)"
gcloud storage buckets describe "gs://${PROJECT_ID}-multiregion" --format="value(location,location_type)"
```

```
US-CENTRAL1     region
US              multi-region
```

> Referencias: [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Cloud locations](https://cloud.google.com/about/locations).

**Control de comprensión — Bloque 2.2**

- **Q10.** Tu RTT medido hacia una región lejana está cerca del piso teórico. ¿Qué prueba eso sobre el valor de "optimizar la aplicación" para arreglar la latencia intercontinental?
- **Q11.** Un minorista europeo debe atender a clientes en Fráncfort con cargas de página por debajo de 50 ms **y** mantener los registros de clientes dentro de la UE. ¿Qué dos conceptos distintos de 1.2 está combinando este requisito, y cuál se puede resolver con una CDN mientras que el otro no?
- **Q12.** Explicá la diferencia de durabilidad/disponibilidad entre el bucket de `us-central1` y el bucket multirregión `US`, y enunciá la consecuencia en costos.

---

## Ejercicio 3 — La escalera de modelos de servicio: corré una misma carga como IaaS, PaaS y SaaS

El examen quiere que ubiques una carga de trabajo en la escalera IaaS/PaaS/SaaS y digas *qué dejó de hacer la organización*. Construí el mismo resultado "servir una página HTTP" de tres formas y contá las tareas.

### Bloque 3.1 — IaaS 💸

1. Creá una VM e instalá vos mismo un servidor web:

```bash
gcloud compute instances create iaas-web \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --tags=http-lab \
  --metadata=startup-script='#!/bin/bash
apt-get update -y
apt-get install -y nginx
echo "IaaS: I chose the OS, I patch the OS." > /var/www/html/index.html
systemctl enable --now nginx'
```

```
Created [https://www.googleapis.com/compute/v1/projects/cdl-12-lab-84021/zones/us-central1-a/instances/iaas-web].
NAME      ZONE           MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP    STATUS
iaas-web  us-central1-a  e2-micro                   10.128.0.2   34.121.55.198  RUNNING
```

2. Ahora también sos dueño del firewall. No le llega nada hasta que vos lo digas:

```bash
gcloud compute firewall-rules create allow-http-lab \
  --allow=tcp:80 --target-tags=http-lab --source-ranges=0.0.0.0/0
sleep 45
curl -s "http://$(gcloud compute instances describe iaas-web --zone=us-central1-a \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
```

```
Creating firewall...done.
IaaS: I chose the OS, I patch the OS.
```

3. Enumerá lo que heredaste al elegir IaaS:

```bash
gcloud compute ssh iaas-web --zone=us-central1-a --command="
  echo '--- kernel you are responsible for ---'; uname -r
  echo '--- pending security updates you are responsible for ---'
  apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true
  echo '--- uptime you are billed for regardless of traffic ---'; uptime -p
"
```

```
--- kernel you are responsible for ---
6.1.0-28-cloud-amd64
--- pending security updates you are responsible for ---
14
--- uptime you are billed for regardless of traffic ---
up 3 minutes
```

**Control de comprensión — Bloque 3.1**

- **Q13.** Enumerá las cuatro tareas operativas que realizaste en el Bloque 3.1 que un PaaS habría eliminado por completo.
- **Q14.** La VM informa 14 actualizaciones de paquetes pendientes. En el modelo de responsabilidad compartida, ¿quién debe aplicarlas, y cambiaría esa respuesta en Cloud Run?

### Bloque 3.2 — PaaS 💸 (centavos)

4. Desplegá el resultado equivalente como plataforma de contenedores gestionada. Sin SO, sin regla de firewall, sin parcheo:

```bash
gcloud run deploy paas-web \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region=us-central1 \
  --allow-unauthenticated \
  --min-instances=0 --max-instances=5
```

```
Deploying container to Cloud Run service [paas-web] in project [cdl-12-lab-84021] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [paas-web] revision [paas-web-00001-kip] has been deployed
and is serving 100 percent of traffic.
Service URL: https://paas-web-1a2b3c4d5e-uc.a.run.app
```

5. Comprobá la diferencia económica — escalar a cero:

```bash
URL=$(gcloud run services describe paas-web --region=us-central1 --format='value(status.url)')
curl -s -o /dev/null -w "cold start: %{time_total}s\n" "$URL"
curl -s -o /dev/null -w "warm:       %{time_total}s\n" "$URL"

gcloud run services describe paas-web --region=us-central1 \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
```

```
cold start: 1.284s
warm:       0.061s
0
```

6. Preguntále a la plataforma qué gestiona en tu nombre:

```bash
gcloud run services describe paas-web --region=us-central1 \
  --format="yaml(status.conditions, spec.template.spec.containers[0].image)"
```

```yaml
spec:
  template:
    spec:
      containers:
      - image: us-docker.pkg.dev/cloudrun/container/hello
status:
  conditions:
  - status: 'True'
    type: Ready
  - status: 'True'
    type: ConfigurationsReady
  - status: 'True'
    type: RoutesReady
```

No hay versión de kernel en esa salida porque no hay ningún kernel que sea tuyo.

### Bloque 3.3 — SaaS (gratis)

7. Venís usando SaaS durante todo el laboratorio. Confirmalo:

```bash
gcloud services list --enabled --format="table(config.name, config.title)" | head
```

```
NAME                              TITLE
cloudbilling.googleapis.com       Cloud Billing API
cloudresourcemanager.googleapis.com  Cloud Resource Manager API
compute.googleapis.com            Compute Engine API
run.googleapis.com                Cloud Run Admin API
```

La consola de Cloud, Google Workspace y Looker Studio se consumen de la misma manera: vos configurás y usás; nunca ves un número de versión, un servidor ni una ventana de mantenimiento.

8. Construí la tabla comparativa, que es el verdadero entregable de este ejercicio:

```bash
cat <<'MD' > ~/service-models.md
| Layer                     | On-premises | IaaS (GCE) | PaaS (Cloud Run) | SaaS (Workspace) |
|---------------------------|:-----------:|:----------:|:----------------:|:----------------:|
| Data & access policy      | You         | You        | You              | You              |
| Application code          | You         | You        | You              | Provider         |
| Runtime / libraries       | You         | You        | Provider         | Provider         |
| Container / OS patching   | You         | **You**    | Provider         | Provider         |
| Virtualisation            | You         | Provider   | Provider         | Provider         |
| Servers, storage, network | You         | Provider   | Provider         | Provider         |
| Facility, power, physical | You         | Provider   | Provider         | Provider         |
| Billed when idle?         | Always      | **Yes**    | No (min=0)       | Per seat/licence |
MD
cat ~/service-models.md
```

> Referencias: [What is Cloud Run](https://cloud.google.com/run/docs/overview/what-is-cloud-run) · [Compute Engine documentation](https://cloud.google.com/compute/docs) · [Google Cloud service terms](https://cloud.google.com/terms/services).

**Control de comprensión — Bloque 3.3**

- **Q15.** La VM IaaS y el servicio de Cloud Run sirven una respuesta HTTP idéntica. Enunciá las dos dimensiones en las que divergen sus curvas de costo, y nombrá el perfil de tráfico que hace más barata a cada una.
- **Q16.** En la tabla de arriba hay una fila que nunca pasa al proveedor en ningún modelo de servicio. ¿Cuál fila, y cuál es el principio de seguridad que garantiza que nunca se mueva?
- **Q17.** Una empresa dice "nos mudamos a la nube" después de levantar 300 VMs a Compute Engine sin cambios. Usando la escalera, explicá qué ganaron y qué explícitamente *no* ganaron.

---

## Ejercicio 4 — Responsabilidad compartida, y el "destino compartido" de Google

La línea entre cliente y proveedor no es un diagrama en una diapositiva — está impuesta en la API. Encontrá la línea tocándola.

1. Preguntá qué lado es dueño del cifrado en reposo por defecto:

```bash
gcloud compute disks describe iaas-web --zone=us-central1-a \
  --format="yaml(name, sizeGb, diskEncryptionKey)"
```

```yaml
name: iaas-web
sizeGb: '10'
```

La ausencia del bloque `diskEncryptionKey` es la respuesta: Google cifra en reposo todo disco persistente con claves gestionadas por Google, siempre, sin ninguna acción de tu parte. Para recuperar *vos* esa responsabilidad, tendrías que aportar una CMEK.

2. Ahora encontrá algo que Google **no** va a hacer por vos — revisá quién puede acceder al proyecto:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format="table(bindings.role, bindings.members)"
```

```
ROLE                  MEMBERS
roles/owner           user:you@example.com
roles/editor          serviceAccount:481920374652@cloudservices.gserviceaccount.com
```

3. Creá deliberadamente la mala configuración de nube más común que existe, y después detectala:

```bash
gcloud storage buckets add-iam-policy-binding "gs://${PROJECT_ID}-regional" \
  --member=allUsers --role=roles/storage.objectViewer

gcloud storage buckets get-iam-policy "gs://${PROJECT_ID}-regional" \
  --format="json(bindings)" | jq '.bindings[] | select(.members[]=="allUsers")'
```

```json
{
  "members": ["allUsers"],
  "role": "roles/storage.objectViewer"
}
```

La infraestructura de Google funcionó perfecto. El bucket es legible por todo el mundo porque *vos* lo dijiste. Revertilo:

```bash
gcloud storage buckets remove-iam-policy-binding "gs://${PROJECT_ID}-regional" \
  --member=allUsers --role=roles/storage.objectViewer
```

4. Observá el **destino compartido** — el proveedor ayudándote activamente a quedarte del lado correcto de la línea, en vez de simplemente documentar dónde está:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" \
  --location=global \
  --recommender=google.iam.policy.Recommender \
  --format="table(description.flatten(), priority)" 2>/dev/null \
  || echo "(No IAM recommendations yet — the recommender needs ~90 days of usage data.)"
```

```
(No IAM recommendations yet — the recommender needs ~90 days of usage data.)
```

Inspeccioná también la maquinaria que usa una organización para hacer que el lado del cliente sea *difícil de equivocar* — Organization Policy:

```bash
gcloud resource-manager org-policies list --project="$PROJECT_ID" 2>/dev/null \
  || echo "(Requires an organization: constraints such as storage.publicAccessPrevention live here.)"
```

5. Leé la mitad del contrato referida a disponibilidad:

```bash
gcloud compute instances describe iaas-web --zone=us-central1-a \
  --format="value(scheduling.onHostMaintenance, scheduling.automaticRestart)"
```

```
MIGRATE  True
```

La migración en vivo es Google cumpliendo su obligación de SLA. Una única instancia de Compute Engine tiene un compromiso mensual de disponibilidad del **99,9%**; instancias distribuidas en dos o más zonas de una región tienen el **99,99%**. La arquitectura que se gana el número más alto la construís vos.

> Referencias: [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [Compute Engine SLA](https://cloud.google.com/compute/sla) · [Google Cloud SLAs](https://cloud.google.com/terms/sla/).

**Control de comprensión — Ejercicio 4**

- **Q18.** En el paso 3 expusiste un bucket a todo internet y ningún control de Google te lo impidió. ¿Fue esto una falla del proveedor? Justificá tu respuesta usando el modelo de responsabilidad compartida.
- **Q19.** Distinguí *responsabilidad compartida* de *destino compartido* en una oración cada uno, y dá una función concreta de Google Cloud que exista únicamente por la segunda idea.
- **Q20.** El SLA de Compute Engine ofrece 99,9% para una instancia única. Convertilo a tiempo fuera de servicio permitido por mes de 30 días, y explicá por qué un SLA es un mecanismo de **crédito** y no una garantía de disponibilidad.

---

## Ejercicio 5 — Elasticidad vs escalabilidad, demostradas

Dos palabras que el examen trata como distintas: *escalabilidad* es la capacidad de crecer; *elasticidad* es la capacidad de crecer **y encogerse automáticamente** con la demanda. La elasticidad es lo que convierte costo fijo en costo variable.

1. 💸 Armá un grupo de instancias gestionado con autoescalado — la expresión IaaS de la elasticidad:

```bash
gcloud compute instance-templates create elastic-tpl \
  --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --tags=http-lab \
  --metadata=startup-script='#!/bin/bash
apt-get update -y && apt-get install -y nginx stress-ng
echo "elastic node $(hostname)" > /var/www/html/index.html
systemctl enable --now nginx'

gcloud compute instance-groups managed create elastic-mig \
  --template=elastic-tpl --size=1 --zone=us-central1-a

gcloud compute instance-groups managed set-autoscaling elastic-mig \
  --zone=us-central1-a \
  --min-num-replicas=1 --max-num-replicas=4 \
  --target-cpu-utilization=0.60 \
  --cool-down-period=60
```

```
Created [.../instanceTemplates/elastic-tpl].
Created [.../instanceGroupManagers/elastic-mig].
Updated [.../autoscalers/elastic-mig].
```

2. Leé de vuelta la política de decisión del autoescalador — este es el contrato entre demanda y gasto:

```bash
gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a \
  --format="yaml(targetSize, status.autoscaler.basename(), currentActions)"

gcloud compute autoscalers describe elastic-mig --zone=us-central1-a \
  --format="yaml(autoscalingPolicy)"
```

```yaml
currentActions:
  creating: 0
  deleting: 0
  none: 1
  recreating: 0
status.autoscaler: elastic-mig
targetSize: 1
---
autoscalingPolicy:
  coolDownPeriodSec: 60
  cpuUtilization:
    predictiveMethod: NONE
    utilizationTarget: 0.6
  maxNumReplicas: 4
  minNumReplicas: 1
  mode: 'ON'
```

3. Generá carga y mirá crecer al grupo (dale 3–5 minutos; el autoescalador está amortiguado a propósito):

```bash
NODE=$(gcloud compute instance-groups managed list-instances elastic-mig \
  --zone=us-central1-a --format="value(instance.basename())" | head -1)

gcloud compute ssh "$NODE" --zone=us-central1-a --command="nohup stress-ng --cpu 2 --timeout 420s >/dev/null 2>&1 &"

for i in $(seq 1 10); do
  printf '%s  targetSize=' "$(date +%H:%M:%S)"
  gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a --format="value(targetSize)"
  sleep 60
done
```

```
14:02:11  targetSize=1
14:03:12  targetSize=1
14:04:13  targetSize=2
14:05:14  targetSize=3
14:06:15  targetSize=3
14:07:16  targetSize=3
```

4. Cortá la carga y observá la asimetría — reducir la escala es más lento que aumentarla, a propósito:

```bash
gcloud compute ssh "$NODE" --zone=us-central1-a --command="pkill stress-ng || true"
# Recheck after ~10-15 minutes:
gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a --format="value(targetSize)"
```

```
1
```

5. Contrastá con la expresión PaaS de la misma idea — ninguna política que escribir, y un piso de **cero**:

```bash
gcloud run services describe paas-web --region=us-central1 \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/maxScale'],
                  spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
```

```
5    0
```

> Referencias: [Autoscaling groups of instances](https://cloud.google.com/compute/docs/autoscaler) · [About Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling).

**Control de comprensión — Ejercicio 5**

- **Q21.** El piso del MIG es 1 y el de Cloud Run es 0. Expresá esa única diferencia como una afirmación de costo mensual para un servicio que recibe tráfico 4 horas por día hábil.
- **Q22.** Escalar hacia arriba llevó ~2 minutos; escalar hacia abajo llevó ~12. ¿Por qué esa asimetría es una decisión de ingeniería deliberada y no un defecto?
- **Q23.** Un equipo de finanzas pide un presupuesto mensual de nube fijo con autoescalado habilitado. Nombrá las dos perillas que hacen que esto sea respondible, y explicá el compromiso que impone cada una.
- **Q24.** Distinguí *escalabilidad* de *elasticidad* usando este ejercicio, y después decí cuál de las dos puede ofrecer genuinamente un datacenter on-premises.

---

## Ejercicio 6 — Modelos de despliegue: pública, privada, híbrida, multicloud

1. Creá la frontera de red. Una VPC es lo que hace que la "nube pública" se comporte como infraestructura privada:

```bash
gcloud compute networks create lab-vpc --subnet-mode=custom
gcloud compute networks subnets create lab-subnet \
  --network=lab-vpc --region=us-central1 --range=10.10.0.0/24 \
  --enable-private-ip-google-access
```

```
Created [.../networks/lab-vpc].
NAME     SUBNET_MODE  BGP_ROUTING_MODE  IPV4_RANGE  GATEWAY_IPV4
lab-vpc  CUSTOM       REGIONAL

Created [.../subnetworks/lab-subnet].
NAME        REGION       NETWORK  RANGE
lab-subnet  us-central1  lab-vpc  10.10.0.0/24
```

2. 💸 Lanzá una VM **sin IP externa** y comprobá que igual llega a las APIs de Google — este es un patrón de despliegue privado dentro de una nube pública:

```bash
gcloud compute instances create private-node \
  --zone=us-central1-a --machine-type=e2-micro \
  --subnet=lab-subnet --no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --scopes=cloud-platform

gcloud compute instances describe private-node --zone=us-central1-a \
  --format="value(networkInterfaces[0].networkIP, networkInterfaces[0].accessConfigs)"
```

```
10.10.0.2
```

La segunda columna vacía es el punto: sin dirección pública, sin camino desde internet, y aun así Private Google Access le permite llamar a `storage.googleapis.com`.

3. Modelá el borde **híbrido**. Inspeccioná en qué consistiría una conexión a un datacenter on-premises, sin pagar por una:

```bash
gcloud compute interconnects list
gcloud compute vpn-gateways list
gcloud compute routers list
```

```
Listed 0 items.
Listed 0 items.
Listed 0 items.
```

Ahora creá la mitad gratuita — un Cloud Router, el hablante BGP que intercambiaría rutas con tu borde on-prem:

```bash
gcloud compute routers create lab-router \
  --network=lab-vpc --region=us-central1 --asn=64514

gcloud compute routers describe lab-router --region=us-central1 \
  --format="yaml(name, bgp.asn, network.basename())"
```

```yaml
bgp:
  asn: 64514
name: lab-router
network: lab-vpc
```

Un ASN y BGP son la pista: la conectividad híbrida es *enrutamiento*, no una casilla de VPN. Las opciones de producción son [HA VPN](https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview) (sobre internet público, cifrada, SLA de 99,99% cuando se configura con dos interfaces) y [Cloud Interconnect](https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview) (Dedicated o Partner, circuitos físicos privados, sin tránsito por internet).

4. Modelá **multicloud**. Consultá la API de fleet que registraría un clúster corriendo en otro proveedor:

```bash
gcloud container fleet memberships list 2>/dev/null \
  || echo "(Enable gkehub.googleapis.com — fleet memberships can include AWS/Azure/on-prem clusters.)"
```

```
(Enable gkehub.googleapis.com — fleet memberships can include AWS/Azure/on-prem clusters.)
```

5. Escribí el registro de decisión. Esto, y no los comandos, es el artefacto relevante para el examen:

```bash
cat <<'MD' > ~/deployment-models.md
| Model       | Where compute runs            | Chosen because                                   | Principal cost                          |
|-------------|-------------------------------|--------------------------------------------------|-----------------------------------------|
| Public      | Provider infrastructure only  | Speed, elasticity, no CapEx, global reach         | Egress fees; provider-specific services |
| Private     | Owned/leased DC, or GDC       | Sovereignty, air-gap, unmovable legacy hardware   | CapEx, capacity planning, low elasticity|
| Hybrid      | Both, connected by Interconnect/HA VPN | Mainframe or data gravity stays put; burst to cloud | Two operating models; link is now critical |
| Multicloud  | Two or more public providers  | Provider risk, per-provider strengths, M&A reality | Duplicated skills, tooling, egress      |
MD
cat ~/deployment-models.md
```

> Referencias: [VPC overview](https://cloud.google.com/vpc/docs/overview) · [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access) · [GKE Enterprise overview](https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview) · [Google Distributed Cloud](https://cloud.google.com/distributed-cloud) · [BigQuery Omni](https://cloud.google.com/bigquery/docs/omni-introduction).

**Control de comprensión — Ejercicio 6**

- **Q25.** `private-node` no tiene IP externa. ¿Eso lo convierte en un despliegue de *nube privada*? Respondé con precisión.
- **Q26.** Un banco mantiene su libro contable central en un mainframe que no se puede mover, y quiere ML sobre esos datos en Google Cloud. Nombrá el modelo de despliegue, el producto de conectividad que especificarías, y la única razón técnica por la que rechazarías HA VPN para esto.
- **Q27.** Un CIO dice "multicloud para que nunca nos aten a un proveedor". Dá el contraargumento más fuerte en una oración, y el único escenario en el que el CIO simplemente tiene razón.
- **Q28.** El egress aparece como costo en tres filas de tu tabla. Explicá por qué la transferencia de datos *hacia afuera* es la dimensión de precio que más seguido sorprende a las organizaciones en un diseño híbrido o multicloud.

---

## Ejercicio 7 — Costo total de propiedad: construí el modelo, y después atacalo

Todo lo anterior a este ejercicio existe para que este sea honesto.

1. Establecé la línea base on-premises. El TCO nunca es solamente el hardware:

```bash
python3 - <<'PY'
years = 3
onprem = {
  "Servers (10 x 2-socket, incl. 3y support)": 148_000,
  "Storage array + expansion":                  62_000,
  "Network (ToR switches, optics, cabling)":    24_000,
  "Hypervisor + backup licences (3y)":          51_000,
  "Rack, power, cooling (3y)":                  39_000,
  "Datacentre space / colo (3y)":               72_000,
  "DR site (contracted, 3y)":                   58_000,
  "Ops staff share (0.6 FTE x 3y)":            234_000,
  "Refresh/disposal at end of life":            11_000,
}
total = sum(onprem.values())
for k, v in onprem.items():
    print(f"{k:46s} ${v:>9,}")
print("-" * 58)
print(f"{'3-YEAR ON-PREM TCO':46s} ${total:>9,}")
print(f"{'Per month':46s} ${total/(years*12):>9,.0f}")
PY
```

```
Servers (10 x 2-socket, incl. 3y support)      $  148,000
Storage array + expansion                      $   62,000
Network (ToR switches, optics, cabling)        $   24,000
Hypervisor + backup licences (3y)              $   51,000
Rack, power, cooling (3y)                      $   39,000
Datacentre space / colo (3y)                   $   72,000
DR site (contracted, 3y)                       $   58,000
Ops staff share (0.6 FTE x 3y)                 $  234,000
Refresh/disposal at end of life                $   11,000
----------------------------------------------------------
3-YEAR ON-PREM TCO                             $  699,000
Per month                                      $   19,417
```

2. Construí el lado de la nube usando los mecanismos de descuento, y fijate cuáles son automáticos:

```bash
python3 - <<'PY'
base = 141.79            # n2-standard-4, 24x7 on-demand, from Exercise 1
fleet = 40               # equivalent VMs

scenarios = {
  "On-demand, 24x7":                       base * fleet,
  "+ Sustained use discount (automatic)":  base * fleet * 0.80,
  "+ 1-year CUD (resource-based)":         base * fleet * 0.63,
  "+ 3-year CUD (resource-based)":         base * fleet * 0.45,
  "Spot VMs (fault-tolerant tier only)":   base * fleet * 0.25,
  "Right-sized: 40 -> 26 VMs, 3-year CUD": base * 26   * 0.45,
}
for name, monthly in scenarios.items():
    print(f"{name:42s} ${monthly:8,.0f}/mo   ${monthly*36:10,.0f} / 3y")
PY
```

```
On-demand, 24x7                            $   5,672/mo   $   204,178 / 3y
+ Sustained use discount (automatic)       $   4,537/mo   $   163,342 / 3y
+ 1-year CUD (resource-based)              $   3,573/mo   $   128,632 / 3y
+ 3-year CUD (resource-based)              $   2,552/mo   $    91,880 / 3y
Spot VMs (fault-tolerant tier only)        $   1,418/mo   $    51,044 / 3y
Right-sized: 40 -> 26 VMs, 3-year CUD      $   1,659/mo   $    59,722 / 3y
```

Mecánica de los descuentos, según la documentación:
- **[Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts)** — automáticos, sin compromiso, aplicados cuando los tipos de máquina elegibles (N1, N2, N2D, C2, C2D y las familias optimizadas para memoria) corren buena parte del mes. E2 y Tau T2D/T2A **no** reciben SUDs; su precio on-demand ya es más bajo.
- **[Committed use discounts](https://cloud.google.com/docs/cuds)** — compromisos de 1 o 3 años. Los CUDs basados en recursos comprometen vCPU/memoria en una región; los basados en gasto (flexibles) comprometen un monto por hora en dólares y te siguen entre servicios. Descuentos profundos, pero pagás lo uses o no.
- **[Spot VMs](https://cloud.google.com/compute/docs/instances/spot)** — 60–91% de descuento, sin tiempo mínimo de ejecución, interrumpibles con aviso de 30 segundos. Solo para trabajo que puede morir y reintentarse.

3. Verificá que la cifra de dimensionamiento correcto del paso 2 no sea una ficción — la plataforma te lo va a decir:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" --location=us-central1-a \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(description.flatten(), primaryImpact.costProjection.cost.units)" 2>/dev/null \
  || echo "(Needs ~8 days of metrics. In production this is where the right-sizing number comes from — measured, not assumed.)"
```

4. Poné los dos lados en un mismo cuadro y explicitá los supuestos:

```bash
python3 - <<'PY'
onprem_3y, cloud_3y = 699_000, 59_722
print(f"On-prem 3y : ${onprem_3y:>9,}   (CapEx-heavy, paid up front, 3-5y refresh cycle)")
print(f"Cloud   3y : ${cloud_3y:>9,}   (OpEx, monthly, exits with the workload)")
print(f"Delta      : ${onprem_3y-cloud_3y:>9,}")
print()
for a in [
  "Fleet is 40 VMs -> 26 after right-sizing (MUST be measured, not assumed)",
  "Egress volume is unpriced above (network egress is the #1 TCO surprise)",
  "Migration project cost is excluded (one-time, often 6-12 months of effort)",
  "Ops FTE is reduced, not eliminated: cloud ops is a different job, not no job",
  "Licence portability (BYOL for OS/DB) is not modelled",
  "On-prem sunk cost: hardware already bought changes the decision entirely",
]:
    print(f"  ! {a}")
PY
```

```
On-prem 3y : $  699,000   (CapEx-heavy, paid up front, 3-5y refresh cycle)
Cloud   3y : $   59,722   (OpEx, monthly, exits with the workload)
Delta      : $  639,278

  ! Fleet is 40 VMs -> 26 after right-sizing (MUST be measured, not assumed)
  ! Egress volume is unpriced above (network egress is the #1 TCO surprise)
  ! Migration project cost is excluded (one-time, often 6-12 months of effort)
  ! Ops FTE is reduced, not eliminated: cloud ops is a different job, not no job
  ! Licence portability (BYOL for OS/DB) is not modelled
  ! On-prem sunk cost: hardware already bought changes the decision entirely
```

5. Reproducí la línea de cómputo en la [Pricing Calculator](https://cloud.google.com/products/calculator) y confirmá que tu cifra cae dentro de ~5% de la herramienta. Si no, tu modelo tiene un supuesto equivocado, no una herramienta equivocada.

**Control de comprensión — Ejercicio 7**

- **Q29.** Dos de los nueve ítems on-premises no tienen ningún equivalente en la nube. ¿Cuáles dos, y qué dice su desaparición sobre lo que la organización está comprando realmente?
- **Q30.** La fila de dimensionamiento correcto ahorra más que las filas de descuento para la misma flota del paso 2. Enunciá el principio general que se desprende, en el orden en que aplicarías las optimizaciones.
- **Q31.** Un CUD a 3 años es la opción comprometida más barata. Nombrá la circunstancia de negocio específica que hace que firmarlo sea un error.
- **Q32.** Explicá el efecto del cambio de CapEx→OpEx más allá del total: nombrá una consecuencia en el balance y una consecuencia *de comportamiento* dentro de un equipo de ingeniería.
- **Q33.** Tu modelo muestra la nube al 8,5% del costo on-premises. Dá las dos razones más probables de que ese número sea demasiado bueno, y cómo probarías cada una.

---

## Limpieza — borrá todo (esto es parte de la lección)

El *servicio medido* corre en ambas direcciones. Todo lo que dejes atrás factura para siempre.

```bash
gcloud compute instance-groups managed delete elastic-mig --zone=us-central1-a --quiet
gcloud compute instance-templates delete elastic-tpl --quiet
gcloud compute instances delete iaas-web private-node --zone=us-central1-a --quiet
gcloud run services delete paas-web --region=us-central1 --quiet
gcloud compute firewall-rules delete allow-http-lab --quiet
gcloud compute routers delete lab-router --region=us-central1 --quiet
gcloud compute networks subnets delete lab-subnet --region=us-central1 --quiet
gcloud compute networks delete lab-vpc --quiet
gcloud storage rm -r "gs://${PROJECT_ID}-regional" "gs://${PROJECT_ID}-multiregion"
```

Verificá que nada facture, y después eliminá el proyecto — la única eliminación que es realmente completa:

```bash
gcloud compute instances list; gcloud run services list; gcloud compute disks list
gcloud projects delete "$PROJECT_ID"
```

```
Listed 0 items.
Listed 0 items.
Listed 0 items.

Your project will be deleted.
Do you want to continue (Y/n)?  Y
Deleted [https://cloudresourcemanager.googleapis.com/v1/projects/cdl-12-lab-84021].
```

La eliminación de un proyecto es reversible por ~30 días, y después permanente. La cuenta de facturación sobrevive — borrá el presupuesto por separado si ya no lo querés.

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Ejercicio 0

**A1.** Nada. Una alerta de presupuesto es una **notificación**, no un control. Las VMs siguen corriendo y siguen facturando. Para que imponga algo, conectá el tema de Pub/Sub del presupuesto a una Cloud Function que deshabilite la facturación del proyecto o elimine recursos — y entendé que deshabilitar la facturación corta las cargas de trabajo abruptamente. El punto relevante para el examen: los presupuestos dan *visibilidad*; las cuotas y la Organization Policy dan *cumplimiento forzoso*.

**A2.** *Servicio medido.* El uso de recursos se mide, controla e informa con una granularidad que el cliente puede ver. Sin medición por SKU no hay precio unitario, y sin precio unitario no podés convertir la infraestructura en un gasto operativo que varíe con el consumo — volvés a comprar un activo fijo.

**A3.** La **cuenta de facturación** es el instrumento de pago y la factura — el centro de costos o la tarjeta corporativa. El **proyecto** es la etiqueta de asignación de costos — el departamento, producto o entorno al que se le carga el gasto. Una cuenta de facturación se abre hacia muchos proyectos, que es exactamente cómo funciona el chargeback/showback: la factura llega una vez, atribuida por proyecto, etiqueta y carpeta.

**A4.** En un laboratorio, el gasto es chico y la velocidad de detección lo es todo — una alerta por pronóstico se dispara en el momento en que aparece una tendencia descontrolada, horas antes que un umbral sobre gasto real. En producción es *insuficiente* porque un pronóstico sigue siendo solo una advertencia: no puede impedir que un job mal configurado levante 500 GPUs. Las cuotas (`gcloud compute project-info describe`, límites de cuota por región/recurso) son el techo rígido; los presupuestos son el detector de humo.

### Ejercicio 1

**A5.** Razones legítimas: (a) **latencia** hacia los usuarios finales de la región; (b) **residencia de datos / ley de soberanía** que exige que los datos permanezcan en el país; (c) menor egress al mantener los datos cerca de donde se producen; (d) objetivos de sostenibilidad ligados al puntaje de energía libre de carbono de la región. La **no negociable** es la residencia de datos — un requisito legal no se puede sortear con arquitectura mudándose a una región más barata, mientras que la latencia se puede mitigar parcialmente con CDN y caché.

**A6.** Te permite comprar exactamente la forma de recurso que la carga necesita, incluidos los **tipos de máquina personalizados** con una relación vCPU:RAM no estándar, y convierte el dimensionamiento correcto en una palanca financiera continua en vez de un evento de renovación de hardware. Una cotización de servidor empaqueta CPU, RAM, disco y chasis en una unidad indivisible que sobredimensionás una vez y con la que convivís durante años.

**A7.** Porque el costo de la nube es `precio unitario × consumo`, y solo el **precio unitario** se conoce de antemano. El consumo es función de la demanda, que es un pronóstico de negocio, no un hecho de ingeniería. Esto se desprende directamente de *servicio medido* y *elasticidad rápida*: la plataforma cobra por lo que usás, así que el gasto es genuinamente variable. El entregable correcto es un modelo con supuestos de demanda explícitos y un rango de sensibilidad, más cobertura de uso comprometido para el piso de demanda del que estás seguro.

### Ejercicio 2

**A8.** Una **zona** es un área de despliegue dentro de una región respaldada por uno o más clústeres — es el dominio de falla para eventos de infraestructura correlacionados, como una falla de energía o de refrigeración. Una **región** es un área geográfica independiente que contiene tres o más zonas, conectadas por enlaces de baja latencia. Dos VMs en zonas distintas sobreviven a la pérdida de una zona; dos VMs en la misma zona no. Aun así no es un plan de DR porque una región entera puede quedar indisponible (desastre natural, evento de red a gran escala) y porque la redundancia zonal no hace nada contra los modos de falla que en realidad causan la mayoría de las caídas — despliegues malos, datos corrompidos y recursos borrados, que se replican alegremente entre zonas.

**A9.** La capacidad y la *capacidad funcional* son finitas y regionales. Las familias de máquinas más nuevas, las GPUs, las TPUs y algunos servicios se despliegan región por región; la cuota es por región y por proyecto. Arquitectónicamente esto significa que la selección de región restringe qué productos podés usar, y los diseños multirregión deben verificar que cada dependencia exista en cada región objetivo antes de comprometerse.

**A10.** Prueba que la latencia está dominada por el **retardo de propagación en la fibra**, que ninguna cantidad de optimización de aplicación puede eliminar. Los únicos arreglos reales son arquitectónicos: acercar el cómputo al usuario (despliegues regionales), acercar la respuesta (Cloud CDN, caché en el borde), o eliminar viajes de ida y vuelta (batching, protocolos asincrónicos, escribir localmente y replicar después). Por eso "hagan la app más rápida" es la respuesta equivocada a una queja de latencia intercontinental.

**A11.** Combina **latencia/proximidad** con **residencia/soberanía de datos**. Una CDN resuelve la primera — cachear activos estáticos y el esqueleto de página en ubicaciones de borde cerca de Fráncfort. No puede resolver la segunda: cachear datos personales en un borde global los movería fuera de la UE, que es precisamente lo que el requisito prohíbe. La restricción de residencia obliga a una región `europe-*` para la capa de datos, potencialmente con Assured Workloads para imponerlo técnicamente.

**A12.** Ambos ofrecen la misma durabilidad nominal de objeto. La diferencia es de **disponibilidad y dominio de falla**: el bucket de `us-central1` almacena los datos de forma redundante dentro de una región y queda inalcanzable si esa región cae; el bucket multirregión `US` replica entre regiones geográficamente separadas dentro de Estados Unidos y sobrevive a la pérdida de una. La consecuencia en costos es que el almacenamiento multirregión tiene un precio por GB más alto, y por eso deberías reservarlo para datos cuya indisponibilidad realmente detenga el negocio.

### Ejercicio 3

**A13.** (1) Elegir y aprovisionar una imagen de SO; (2) instalar y configurar el servidor web mediante un startup script; (3) abrir una regla de firewall para admitir tráfico; (4) hacerte cargo del parcheo de SO/kernel en adelante. Una quinta, implícita: dimensionar la máquina de antemano. Cloud Run no requirió ninguna de estas — entregaste una imagen de contenedor y te devolvieron una URL.

**A14.** En IaaS el **cliente** parchea el SO invitado. Google parchea el hipervisor, el host y las capas físicas; el invitado es tuyo. En Cloud Run la respuesta cambia: Google es dueño del sistema operativo y del runtime de contenedores, y la responsabilidad del cliente termina en el contenido de la imagen del contenedor — lo que igualmente incluye parchear la imagen base y las bibliotecas que empaquetaste. La responsabilidad se estrecha; no desaparece.

**A15.** Divergen en (1) **granularidad de facturación** — la VM factura por su existencia en tiempo de reloj, Cloud Run factura por el tiempo sirviendo solicitudes en incrementos finos; y (2) **piso de inactividad** — la VM tiene un piso permanente, el de Cloud Run es cero. Cloud Run es más barato para tráfico **con picos, intermitente o de bajo ciclo de trabajo**. La VM siempre encendida se vuelve más barata con utilización **alta, sostenida y predecible**, donde el precio por solicitud más el margen de plataforma supera la tarifa plana — y donde aplican SUDs/CUDs.

**A16.** **Datos y política de acceso.** Nunca se mueve porque el proveedor no puede conocer tus reglas de negocio: quién debería ver qué, cuánto tiempo se retienen los datos, qué clasificación tienen. Este es el invariante del modelo de responsabilidad compartida — el proveedor asegura la infraestructura, el cliente asegura lo que pone dentro y a quién deja acercarse. Incluso en SaaS, vos sos dueño de la configuración de compartición y de las cuentas.

**A17.** Ganaron los beneficios de **infraestructura**: sin renovación de hardware, capacidad bajo demanda, regiones globales, CapEx→OpEx, y la posibilidad de escalar una VM en minutos. **No** ganaron los beneficios operativos por encima de la línea del hipervisor — siguen parcheando 300 sistemas operativos, siguen dimensionando máquinas, siguen cargando ese trabajo pesado en headcount. Lift-and-shift es un primer paso válido (frena la hemorragia de un contrato de datacenter) pero es un cambio de *ubicación*, no de *modelo operativo*; el beneficio de modernización llega solo cuando las cargas suben por la escalera.

### Ejercicio 4

**A18.** No — es el modelo funcionando exactamente como fue diseñado. La responsabilidad de Google es que el sistema IAM aplique fielmente la política que vos definiste, que la API te autentique, y que la infraestructura sea segura. Tu responsabilidad es la política en sí. El proveedor no va a cuestionar la concesión explícita de un administrador autorizado. (También por eso existe el *destino compartido*: `storage.publicAccessPrevention` como restricción de Organization Policy, y los hallazgos de Security Command Center, son Google haciendo que el error sea más difícil de cometer — dejándote la decisión a vos.)

**A19.** La *responsabilidad compartida* traza la línea: esto asegura el proveedor, esto asegurás vos — y de ahí el cliente queda solo de su lado. El *destino compartido* es Google asumiendo corresponsabilidad activa por tu éxito de tu lado de la línea: configuraciones seguras por defecto, blueprints, Assured Workloads, seguro de protección de riesgos y recomendadores — para que el camino seguro sea el camino fácil. Un artefacto concreto de lo segundo: el **Risk Protection Program** / la oferta de ciberseguro, o el blueprint de fundaciones de seguridad — ninguno tiene sentido bajo responsabilidad compartida pura.

**A20.** El 99,9% de un mes de 30 días permite alrededor de **43 minutos 12 segundos** de caída (30 × 24 × 60 × 0,001). Un SLA es un mecanismo de **crédito financiero**: si el proveedor no alcanza el objetivo, recibís un crédito porcentual contra tu factura. No garantiza que tu servicio siga arriba, y el crédito nunca se va a acercar a los ingresos perdidos por una caída. La disponibilidad, por lo tanto, es algo que vos *arquitecturás* (multizona, multirregión, degradación elegante) y el SLA es aquello a lo que *recurrís* — que es exactamente por qué el nivel de 99,99% exige que despliegues entre zonas.

### Ejercicio 5

**A21.** El MIG factura 730 horas por mes sin importar el tráfico. El servicio de Cloud Run factura aproximadamente 4 h × ~21 días hábiles ≈ **84 horas** de tiempo activo — cerca del 11% del tiempo de reloj — y nada por el ~89% restante. Misma carga de trabajo, una diferencia de un orden de magnitud en costo, surgida puramente de si el piso de inactividad es 1 o 0.

**A22.** Escalar hacia arriba protege la **experiencia del usuario**: bajo carga, llegar tarde es estar caído, así que el autoescalador reacciona rápido y peca de sobreaprovisionar. Escalar hacia abajo protege la **estabilidad**: la remoción agresiva arriesga oscilaciones (ir y venir entre tamaños), terminar instancias en medio de una solicitud y pagar repetidamente el costo de arranque en frío. Como sobreaprovisionar por diez minutos extra es barato y una flota oscilante es cara tanto en dinero como en confiabilidad, el amortiguamiento es deliberado — el `coolDownPeriodSec` y la ventana de estabilización codifican exactamente esa asimetría.

**A23.** (1) **`maxNumReplicas` / `--max-instances`** — un techo rígido que vuelve computable el costo en el peor caso (`máx × precio unitario × horas`); el compromiso es que el tráfico por encima del techo se encola, se limita o se descarta, así que convertiste un riesgo de costo en un riesgo de disponibilidad. (2) **Descuentos por uso comprometido dimensionados al piso de demanda** — comprometé la línea base, quemá on-demand para el pico; el compromiso es pagar el compromiso incluso en un mes tranquilo. El planteo honesto para finanzas: podés tener un *techo de costo* o *elasticidad ilimitada*, no ambos.

**A24.** La **escalabilidad** es la capacidad de manejar crecimiento — agregás nodos, obtenés más rendimiento; el MIG podía llegar a 4, el datacenter podía racker más servidores. La **elasticidad** es escalar *automáticamente en ambas direcciones* en respuesta a la demanda, de modo que el costo siga al uso. Un datacenter on-premises puede ofrecer escalabilidad (comprar y montar más hardware, en una escala de compra de semanas a meses) pero **no** elasticidad: nunca puede escalar *hacia abajo*, porque liberar un servidor no te devuelve la plata. Ese trinquete de una sola dirección es la razón estructural por la que la capacidad on-premises se dimensiona para el pico y está ociosa la mayor parte del tiempo.

### Ejercicio 6

**A25.** No. `private-node` es una carga de trabajo con **direccionamiento de red privado** corriendo sobre **nube pública** — infraestructura multiinquilino, propiedad de Google. "Nube privada" describe la *propiedad y la tenencia* de la infraestructura subyacente (un datacenter propio o infraestructura dedicada de un solo inquilino, como Google Distributed Cloud), no si una VM tiene IP externa. Confundir las dos cosas es un distractor clásico de examen: una VPC te da *direccionamiento y aislamiento* privados sobre nube pública, que es una propiedad de red, no un modelo de despliegue.

**A26.** Modelo de despliegue: **nube híbrida**. Conectividad: **Cloud Interconnect** — Dedicated Interconnect si podés llegar a una instalación de colocación, Partner Interconnect si no. Rechazá HA VPN por la única razón de que atraviesa **internet público**, de modo que ancho de banda y latencia son de mejor esfuerzo e impredecibles, y el rendimiento por túnel está limitado — inaceptable para enviar continuamente grandes volúmenes del libro contable hacia un pipeline de entrenamiento. (El cifrado *no* es la razón para rechazarlo — HA VPN va cifrada; Interconnect es privado pero no cifrado por defecto, y se le agrega MACsec o cifrado en la capa de aplicación si hace falta.)

**A27.** Contraargumento: multicloud normalmente **cambia el lock-in de proveedor por lock-in de complejidad** — pasás a correr sobre el mínimo común denominador de servicios, duplicás habilidades, herramientas, postura de seguridad y evidencia de cumplimiento entre proveedores, y pagás egress para mover datos entre ellos; la portabilidad que compraste muchas veces nunca se ejerce, mientras el costo se paga todos los días. El CIO **tiene razón** cuando el impulsor no es filosófico sino fáctico: un requisito regulatorio de diversidad de proveedores (como en algunas jurisdicciones de servicios financieros), una fusión que llegó con una segunda nube ya en producción, o un servicio específico best-in-class que existe en un solo proveedor.

**A28.** Porque **el ingress suele ser gratis y el egress no**, así que el costo se acumula en la dirección que nadie presupuesta. Los diseños que en un diagrama se ven simétricos no lo son en la factura: un pipeline analítico híbrido que trae datos de la nube de vuelta a on-prem, un diseño multicloud con la base de datos en un proveedor y el cómputo en otro, o una malla de microservicios conversadora que cruza proveedores, todos generan egress continuo a través de la frontera. La sorpresa se agrava porque el volumen escala con el *crecimiento de uso*, que es exactamente cómo se ve el éxito — así que la factura crece más rápido justo cuando el proyecto se declara un triunfo. Mitigaciones: co-ubicar el cómputo con los datos, usar Cloud Interconnect (que tiene tarifas de egress más bajas que el egress por internet), cachear agresivamente y medir el egress explícitamente en el modelo de TCO en vez de dejarlo como nota al pie.

### Ejercicio 7

**A29.** **"Refresh/disposal at end of life"** y **"Rack, power, cooling"** (las líneas de sitio de DR y colo están estrechamente relacionadas). Su desaparición muestra que la infraestructura on-premises se compra como un **activo físico que se deprecia sobre un ciclo de renovación**, con todo un aparato de soporte — espacio, energía, refrigeración, disposición final, y la planificación de capacidad que debe predecir la demanda a 3–5 años. Lo que la organización realmente compra en la nube no es "servidores, más baratos"; es la **eliminación del ciclo de vida del activo** y de la obligación de pronosticar capacidad con años de anticipación.

**A30.** El principio: **eliminá antes de descontar.** Un descuento sobre un recurso que no necesitabas sigue siendo plata gastada. Aplicá en orden: (1) **borrá** lo que no se usa — discos huérfanos, IPs ociosas, entornos de desarrollo olvidados; (2) **dimensioná correctamente** según utilización medida; (3) **reprogramá** — apagá lo que no es producción fuera del horario laboral; (4) **rearquitecturá** donde la ganancia sea estructural — pasá a servicios gestionados/serverless para que estar ocioso no cueste nada; (5) **recién entonces** comprometé — aplicá CUDs al piso de demanda que sobrevive a los pasos 1–4, y Spot a la capa tolerante a fallos. Comprometerse primero congela tu desperdicio actual por tres años.

**A31.** Cuando **la demanda es incierta o la arquitectura está por cambiar.** En concreto: estás en plena migración y esperás rearquitecturar hacia serverless o servicios gestionados dentro de un año; el negocio es estacional o está en un mercado volátil; el producto podría discontinuarse; o una fusión podría relocalizar la carga. Un CUD basado en recursos factura lo consumas o no y está acotado a región y familia de recursos, así que un compromiso a 3 años contra una flota que planeás encoger o mudar convierte un costo variable otra vez en uno fijo — entregando exactamente la flexibilidad que justificó la mudanza a la nube. Los CUDs flexibles (basados en gasto) mitigan esto parcialmente porque siguen al gasto entre servicios en lugar de fijar una familia de máquinas.

**A32.** **Consecuencia en el balance:** el gasto sale del balance como activo capitalizado y depreciado y pasa al estado de resultados como gasto operativo mensual. El efectivo no queda inmovilizado por años de anticipación, y el costo se alinea en el tiempo con los ingresos que genera la carga de trabajo — aunque la organización también pierde el escudo de la depreciación y gana un compromiso recurrente que nunca termina. **Consecuencia de comportamiento:** la infraestructura pasa a ser una decisión de autoservicio tomada en segundos por un ingeniero, en vez de un ciclo de compras aprobado por un comité. Eso es al mismo tiempo el desbloqueo de productividad y el riesgo de gobernanza — que es precisamente por qué presupuestos, cuotas, etiquetas y showback (Ejercicio 0) no son burocracia sino el sistema de control que hace seguro al OpEx.

**A33.** Dos razones probables y cómo probar cada una. (1) **La carga de trabajo no se modeló honestamente** — el lado de la nube asume dimensionamiento a 26 VMs y solo pone precio al cómputo, omitiendo almacenamiento, egress, balanceo de carga, backup, licencias y entornos que no son de producción. *Prueba:* reconstruí la estimación a partir de un inventario real en la Pricing Calculator con cada SKU que la carga toca, y reconciliá contra un mes de exportación de facturación real en BigQuery después de una migración piloto. (2) **La comparación no es equivalente** — la cifra on-premises incluye DR, personal e instalaciones, mientras que la cifra de nube asume calladamente que eso pasa a ser gratis; en la realidad las operaciones de nube, FinOps, herramientas de seguridad y el proyecto de migración por única vez cuestan plata. *Prueba:* agregá una línea de migración y una línea de FTE de operaciones de nube al lado de la nube, y verificá si el hardware on-prem ya es **costo hundido** — si está pago y le quedan dos años de vida, la comparación de corto plazo es solo contra el costo marginal de operación, y la respuesta honesta puede ser migrar en el límite de la renovación en vez de inmediatamente.

</details>

---

### Fuentes

- [Cloud Digital Leader exam guide (official PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)
- [NIST SP 800-145 — The NIST Definition of Cloud Computing](https://csrc.nist.gov/pubs/sp/800/145/final)
- [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Cloud locations](https://cloud.google.com/about/locations)
- [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [Google Cloud SLAs](https://cloud.google.com/terms/sla/) · [Compute Engine SLA](https://cloud.google.com/compute/sla)
- [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) · [Pricing Calculator](https://cloud.google.com/products/calculator) · [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets) · [Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
- [Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts) · [Committed use discounts](https://cloud.google.com/docs/cuds) · [Spot VMs](https://cloud.google.com/compute/docs/instances/spot)
- [Autoscaling groups of instances](https://cloud.google.com/compute/docs/autoscaler) · [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling) · [What is Cloud Run](https://cloud.google.com/run/docs/overview/what-is-cloud-run)
- [VPC overview](https://cloud.google.com/vpc/docs/overview) · [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access) · [Cloud Interconnect](https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview) · [Cloud VPN](https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview)
- [GKE Enterprise overview](https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview) · [Google Distributed Cloud](https://cloud.google.com/distributed-cloud) · [BigQuery Omni](https://cloud.google.com/bigquery/docs/omni-introduction)
- [gcping — latency measurement tool](https://github.com/GoogleCloudPlatform/gcping) · [gcping.com](https://gcping.com)