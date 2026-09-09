# Tema 4.2 — Ejercicios guiados

## Describe the functionality, business use cases, and business value of Google Cloud's infrastructure offerings

**Certificación:** Google Cloud Digital Leader (guía de examen 2026-08-12) · **Peso de la sección 4:** 6.0

---

### Cómo usar este documento

Cada ejercicio es un **bloque de ejecución numerado** seguido de **preguntas de verificación**. Ejecutá los comandos; no los leas. Los comandos están deliberadamente sesgados hacia el *descubrimiento* (`list`, `describe`, Billing Catalog API) antes que hacia el *aprovisionamiento*, porque el examen evalúa si sabés **mapear un requisito de negocio a una oferta de infraestructura y defender el costo**, no si podés escribir `gcloud compute instances create` de memoria.

Las respuestas a todas las preguntas están en la única sección colapsable del final.

> **Advertencia de costo.** Los ejercicios 3, 6 y 9 crean recursos facturables. Cada bloque termina con un paso de desmontaje. El gasto total, si seguís el desmontaje, es inferior a **USD 1.00**. El ejercicio 9 (MIG regional) es el único que se puede descontrolar — configurá una alerta de presupuesto antes de empezar.
>
> **Los precios y el inventario de este documento son valores de lista capturados al momento de escribirlo.** Google cambia SKUs, cantidad de regiones y porcentajes de descuento continuamente. Todo ejercicio que cite un número te da también el comando para traer el número *en vivo*. Cuando no coincidan, el número en vivo es el correcto y este documento está desactualizado. Ese hábito — nunca citar un precio de nube de memoria — es en sí mismo parte del objetivo.

### Requisitos previos

| Requisito | Verificación |
|---|---|
| `gcloud` CLI ≥ 480.0.0 | `gcloud version` |
| Un proyecto con una cuenta de facturación asociada | `gcloud beta billing projects describe $PROJECT_ID` |
| `jq` | `jq --version` |
| Roles | `roles/compute.viewer`, `roles/billing.viewer`, y `roles/compute.instanceAdmin.v1` para los bloques de aprovisionamiento |
| APIs | `compute.googleapis.com`, `cloudbilling.googleapis.com`, `run.googleapis.com` |

---

## Ejercicio 0 — Establecer una shell reproducible

**Objetivo:** todos los bloques posteriores asumen estas variables. Las decisiones de infraestructura son decisiones *regionales*; fijar una región de memoria es la fuente más común de respuestas de costo equivocadas.

### Pasos

1. Fijá el proyecto y un par región/zona de trabajo.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export ZONE="us-central1-a"
gcloud config set project "$PROJECT_ID"
gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"
```

2. Habilitá las APIs que necesitan los ejercicios. Esto es idempotente.

```bash
gcloud services enable \
  compute.googleapis.com \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  run.googleapis.com \
  recommender.googleapis.com
```

3. Confirmá que la cuenta de facturación está activa — un proyecto sin facturación degrada silenciosamente la mitad de los comandos de abajo a `PERMISSION_DENIED`.

```bash
gcloud beta billing projects describe "$PROJECT_ID" \
  --format="value(billingAccountName, billingEnabled)"
```

Salida esperada:

```
billingAccounts/01A2B3-C4D5E6-F7G8H9	True
```

4. Poné una barrera dura antes de aprovisionar nada.

```bash
gcloud billing budgets create \
  --billing-account="01A2B3-C4D5E6-F7G8H9" \
  --display-name="cdl-4.2-lab-guardrail" \
  --budget-amount=5USD \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --filter-projects="projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
```

### Preguntas de verificación

**Q0.1** — Un presupuesto con reglas de umbral **no** detiene el gasto. ¿Cuál es la distinción de negocio, relevante para el examen, entre una *alerta de presupuesto*, una *cuota* y un *committed use discount*, y cuál de las tres es el único tope de gasto real?

**Q0.2** — ¿Por qué `gcloud config set compute/region` cambia la *respuesta* a una pregunta de TCO, y no solo el destino de un comando? Nombrá dos componentes de costo que varían por región.

---

## Ejercicio 1 — El sustrato físico: regiones, zonas y el backbone privado

**Objetivo:** la historia de infraestructura de Google Cloud empieza por debajo de la lista de productos. Las regiones/zonas determinan simultáneamente latencia, residencia de datos, SLA de disponibilidad, precio e intensidad de carbono. El examen lo formula como "business value of Google Cloud's global infrastructure".

### Pasos

1. Contá la huella real desde la API en lugar de desde una diapositiva.

```bash
gcloud compute regions list --format="value(name)" | wc -l
gcloud compute zones  list --format="value(name)" | wc -l
```

Salida representativa (tus números van a ser mayores — Google agrega regiones continuamente):

```
42
127
```

2. Inspeccioná la estructura y el sobre de capacidad de una sola región.

```bash
gcloud compute regions describe "$REGION" \
  --format="yaml(name, status, zones.basename())"
```

```yaml
name: us-central1
status: UP
zones:
- us-central1-a
- us-central1-b
- us-central1-c
- us-central1-f
```

3. Mostrá que las zonas son **dominios de fallo independientes con hardware distinto**, no etiquetas cosméticas. Compará las plataformas de CPU disponibles por zona:

```bash
for z in $(gcloud compute zones list \
             --filter="region:($REGION)" --format="value(name)"); do
  printf '%-18s %s\n' "$z" \
    "$(gcloud compute zones describe "$z" \
         --format='value(availableCpuPlatforms.list())')"
done
```

```
us-central1-a      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,Intel Skylake,AMD Rome,AMD Milan,AMD Genoa
us-central1-b      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Sapphire Rapids,Intel Skylake,AMD Rome,AMD Milan
us-central1-c      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Skylake,AMD Rome,AMD Milan,AMD Genoa
us-central1-f      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Skylake,AMD Rome
```

4. Comprobá que el *inventario* de máquinas es zonal, no regional. Pedile a dos zonas de la misma región la misma familia de máquinas:

```bash
gcloud compute machine-types list \
  --filter="zone:($REGION-a) AND name~^c4-standard" \
  --format="table(name, guestCpus, memoryMb)"

gcloud compute machine-types list \
  --filter="zone:($REGION-f) AND name~^c4-standard" \
  --format="table(name, guestCpus, memoryMb)"
```

Si el segundo comando devuelve menos filas (o `Listed 0 items.`), acabás de descubrir — gratis, antes de escribir un plan de Terraform — que una zona de tu región objetivo no puede alojar el tipo de máquina que asumía tu modelo de capacidad.

5. Leé los metadatos de ubicación multi-region y dual-region, que es de donde salen realmente las respuestas de residencia de datos:

```bash
gcloud storage buckets create "gs://cdl-42-multiregion-${RANDOM}" \
  --location=US --dry-run
```

```
Would create: gs://cdl-42-multiregion-14822 with location "US" (multi-region),
storage class "STANDARD", uniform bucket-level access disabled.
```

6. Traé las características de carbono de las regiones candidatas. Es una cifra publicada por región — el porcentaje de energía libre de carbono de Google (CFE%) y la intensidad de carbono de la red eléctrica (gCO₂eq/kWh) — y hoy es una entrada rutinaria en la selección de región para clientes regulados y con reporte ESG. Consultá <https://cloud.google.com/sustainability/region-carbon>; el selector de regiones de la consola de Cloud expone los mismos datos como una insignia **Low CO₂**.

### Preguntas de verificación

**Q1.1** — Un banco minorista debe mantener los registros de clientes dentro de un único estado miembro de la UE, y debe sobrevivir a la pérdida de un edificio de datacenter. ¿Qué construcción de ubicación de Google Cloud satisface ambas cosas, y cuál no satisface *ninguna* pese a sonar más segura? Explicalo en términos de dominio de fallo y frontera de residencia.

**Q1.2** — El paso 3 mostró plataformas de CPU distintas en distintas zonas de una misma región. ¿Qué incidente concreto de producción provoca esto cuando desplegás un managed instance group regional con un tipo de máquina que fija `minCpuPlatform`, y cuál es la consecuencia de negocio?

**Q1.3** — El tráfico entre regiones de Google viaja por un backbone de fibra de propiedad privada con cables submarinos, mientras que una arquitectura multi-sitio on-premises comparable viaja por proveedores de tránsito. Traducí ese hecho de ingeniería a dos afirmaciones de *valor de negocio* que un CFO aceptaría.

**Q1.4** — Los usuarios de una carga de trabajo están 80% en São Paulo y sus datos deben replicarse para DR. Desplegar en `southamerica-east1` da baja latencia pero una intensidad de carbono de red mayor que `us-central1`. ¿Bajo qué condiciones de gobernanza es defendible elegir igualmente la región con más carbono?

**Fuentes:** <https://cloud.google.com/docs/geography-and-regions> · <https://cloud.google.com/compute/docs/regions-zones> · <https://cloud.google.com/about/locations> · <https://cloud.google.com/sustainability/region-carbon>

---

## Ejercicio 2 — La escalera de abstracción de cómputo

**Objetivo:** la forma de pregunta favorita del examen es "qué oferta de cómputo encaja en este escenario de negocio". La decisión no es una preferencia tecnológica; es sobre **quién es responsable de qué**, y cada peldaño que subís cambia control por costo operativo eliminado.

| Peldaño | Oferta | Vos gestionás | Google gestiona | Granularidad de facturación |
|---|---|---|---|---|
| IaaS | **Bare Metal Solution / Sole-tenant nodes** | SO, parcheo, licenciamiento, HA | Instalación física, energía, red | Por nodo/hora, mínimo mensual |
| IaaS | **Compute Engine** | SO, parcheo, política de escalado, diseño de HA | Hipervisor, mantenimiento de host, live migration | Por segundo (mínimo 60 s) |
| IaaS | **Google Cloud VMware Engine** | Cargas vSphere, ciclo de vida de las VM | Stack ESXi/vSAN/NSX, hardware, upgrades | Por nodo/hora |
| CaaS | **GKE Standard** | Node pools, upgrades, capacidad | Control plane, healing | Por nodo/segundo + tarifa de control plane |
| CaaS | **GKE Autopilot** | Especificaciones de los Pods, requests/limits | Nodos, escalado, postura de seguridad de nodos | Por **pod resource request**/segundo |
| PaaS | **App Engine / Cloud Run** | Imagen del contenedor, concurrencia, min/max | Todo lo que está debajo del contenedor | Por request o por instancia-segundo |
| FaaS | **Cloud Run functions** | El cuerpo de una función | Todo lo demás | Por invocación + GB-s |

### Pasos

1. Desplegá la *misma* capacidad de negocio en dos peldaños distintos y compará el artefacto que tuviste que escribir. Primero, el peldaño serverless — un manifiesto de servicio Knative completo y válido:

```yaml
# checkout-service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: checkout-api
  labels:
    cost-center: "retail-payments"
    env: "prod"
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/maxScale: "100"
        run.googleapis.com/cpu-throttling: "false"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/startup-cpu-boost: "true"
    spec:
      containerConcurrency: 80
      timeoutSeconds: 300
      serviceAccountName: checkout-sa@PROJECT_ID.iam.gserviceaccount.com
      containers:
        - image: us-docker.pkg.dev/cloudrun/container/hello
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          env:
            - name: LOG_LEVEL
              value: "info"
  traffic:
    - percent: 100
      latestRevision: true
```

```bash
sed -i "s/PROJECT_ID/$PROJECT_ID/" checkout-service.yaml
gcloud run services replace checkout-service.yaml --region="$REGION"
```

```
Applying new configuration to Cloud Run service [checkout-api] in project [my-proj] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
Done.
Service [checkout-api] revision [checkout-api-00001-abc] has been deployed
and is serving 100 percent of traffic.
Service URL: https://checkout-api-abcdefghij-uc.a.run.app
```

2. Contá la superficie operativa que **no** tuviste que escribir: sin imagen de SO, sin calendario de parcheo, sin recurso de autoscaler, sin balanceador de carga, sin certificado TLS, sin health check.

```bash
gcloud run services describe checkout-api --region="$REGION" \
  --format="value(status.url, status.traffic[0].revisionName)"
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  "$(gcloud run services describe checkout-api --region=$REGION --format='value(status.url)')"
```

```
200 0.284510s
```

3. Ahora expresá la misma carga de trabajo en el peldaño CaaS. Este es el conjunto de manifiestos que deberías en GKE — fijate en lo que aparece y que Cloud Run hacía por vos implícitamente:

```yaml
# checkout-gke.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      nodeSelector:
        cloud.google.com/compute-class: Balanced
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout
      containers:
        - name: checkout
          image: us-docker.pkg.dev/cloudrun/container/hello
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
              ephemeral-storage: 1Gi
            limits:
              cpu: 500m
              memory: 512Mi
              ephemeral-storage: 1Gi
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: shop
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: checkout
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-hpa
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

4. **No** crees un cluster (un cluster de GKE Autopilot cuesta dinero real por hora). En su lugar, poné precio a la diferencia analíticamente en el ejercicio 4.

5. Desmontá el servicio de Cloud Run — escala a cero, pero la revisión retiene una referencia de imagen y una URL:

```bash
gcloud run services delete checkout-api --region="$REGION" --quiet
```

### Preguntas de verificación

**Q2.1** — En el manifiesto de Cloud Run se fijó `minScale: "1"`. Nombrá el trade-off de negocio que codifica esa única línea, y cuantificalo: ¿qué compra el cliente, y qué deja de recibir?

**Q2.2** — GKE Autopilot factura por **pod resource request**, GKE Standard factura por **nodo**. Un equipo fija habitualmente los `requests` en 3× el uso medido. ¿Qué modelo de facturación castiga ese comportamiento, cuál lo oculta, y qué implica eso para un programa de FinOps?

**Q2.3** — Una empresa de logística tiene una aplicación Windows monolítica con un driver licenciado de terceros que requiere acceso al kernel, y necesita salir del datacenter corporativo en nueve meses. Ordená los peldaños de la escalera para este escenario y justificá la mejor opción en una frase de lenguaje de negocio.

**Q2.4** — Ambos manifiestos declaran `cpu: 500m`/`cpu: "1"`. En Cloud Run esto afecta el *precio por request*; en GKE Standard no afecta directamente la factura en absoluto. Explicá por qué.

**Fuentes:** <https://cloud.google.com/run/docs/overview/what-is-cloud-run> · <https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview> · <https://cloud.google.com/docs/overview/cloud-platform-services>

---

## Ejercicio 3 — Familias de máquinas, right-sizing y live migration

**Objetivo:** el valor de negocio de Compute Engine *no* es "existen máquinas virtuales". Es la combinación de formas personalizadas, facturación por segundo, recomendaciones automáticas de right-sizing y mantenimiento de host transparente.

### Pasos

1. Enumerá las familias de máquinas visibles en tu zona y agrupalas por prefijo. El prefijo *es* la familia, y la familia *es* el contrato de precio/rendimiento.

```bash
gcloud compute machine-types list --zones="$ZONE" \
  --format="value(name)" \
  | sed 's/-.*//' | sort -u | tr '\n' ' '
```

```
a2 a3 c2 c2d c3 c3d c4 c4a e2 f1 g2 h3 m1 m2 m3 n1 n2 n2d n4 t2a t2d z3
```

2. Leé la forma de un miembro de cada una de las cuatro clases de propósito:

```bash
gcloud compute machine-types describe n4-standard-8 --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)"
gcloud compute machine-types describe c4-highcpu-8   --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)" 2>/dev/null
gcloud compute machine-types describe m3-ultramem-32  --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)" 2>/dev/null
```

```
NAME           GUEST_CPUS  MEMORY_MB
n4-standard-8  8           32768
NAME           GUEST_CPUS  MEMORY_MB
c4-highcpu-8   8           16384
NAME            GUEST_CPUS  MEMORY_MB
m3-ultramem-32  32          976000
```

La proporción es toda la historia: general-purpose ≈ 4 GB/vCPU, compute-optimized ≈ 2 GB/vCPU, memory-optimized ≈ 30 GB/vCPU.

3. Creá un **custom machine type** — una forma que el catálogo estándar de ningún otro proveedor grande ofrece — dimensionado a una carga de trabajo medida de 6 vCPU / 20 GB, y observá el comportamiento automático de mantenimiento:

```bash
gcloud compute instances create cdl-42-rightsize \
  --zone="$ZONE" \
  --custom-cpu=6 \
  --custom-memory=20GB \
  --custom-vm-type=n2 \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-type=pd-balanced --boot-disk-size=20GB \
  --maintenance-policy=MIGRATE \
  --labels=cost-center=cdl-lab,owner=student \
  --metadata=enable-oslogin=TRUE
```

```
Created [https://www.googleapis.com/compute/v1/projects/my-proj/zones/us-central1-a/instances/cdl-42-rightsize].
NAME              ZONE           MACHINE_TYPE               PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP    STATUS
cdl-42-rightsize  us-central1-a  n2-custom-6-20480                       10.128.0.14  34.66.112.203  RUNNING
```

4. Confirmá el contrato de mantenimiento que diferencia a Compute Engine de la mayoría de sus competidores IaaS:

```bash
gcloud compute instances describe cdl-42-rightsize --zone="$ZONE" \
  --format="yaml(name, machineType.basename(), scheduling)"
```

```yaml
machineType: n2-custom-6-20480
name: cdl-42-rightsize
scheduling:
  automaticRestart: true
  onHostMaintenance: MIGRATE
  preemptible: false
  provisioningModel: STANDARD
```

`onHostMaintenance: MIGRATE` significa que Google mueve esta VM en ejecución a otro host físico durante el mantenimiento del datacenter **sin reiniciar el guest**. Leé <https://cloud.google.com/compute/docs/instances/live-migration-process>.

5. Preguntale a la plataforma qué opina de tu dimensionamiento. Las recomendaciones necesitan ~24 h de métricas, así que esperá un conjunto vacío en una VM recién creada — ejecutalo contra un proyecto de larga vida si tenés uno:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" \
  --location="$ZONE" \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(description, primaryImpact.costProjection.cost.units, stateInfo.state)"
```

```
DESCRIPTION                                                        UNITS  STATE
Save cost by changing machine type from n2-standard-8 to n2-standard-4.  -71  ACTIVE
```

6. Inspeccioná la opción de sole-tenancy sin comprar una — esta es la respuesta a los requisitos de licenciamiento por core y de aislamiento físico por cumplimiento:

```bash
gcloud compute sole-tenancy node-types list --zones="$ZONE" \
  --format="table(name, cpuCount, memoryMb, localSsdGb)"
```

```
NAME          CPU_COUNT  MEMORY_MB  LOCAL_SSD_GB
c2-node-60-240      60     245760            0
m3-node-128-3904   128    3997696         3000
n2-node-80-640      80     655360            0
```

7. **Desmontaje.**

```bash
gcloud compute instances delete cdl-42-rightsize --zone="$ZONE" --quiet
```

### Preguntas de verificación

**Q3.1** — El paso 3 produjo `n2-custom-6-20480`. Las formas predefinidas más cercanas son `n2-standard-8` (8/32) y `n2-highcpu-8` (8/8). Enunciá el valor de negocio de la forma personalizada en un número y una frase, y nombrá las dos situaciones en las que una forma personalizada es la elección *equivocada*.

**Q3.2** — `onHostMaintenance: MIGRATE` frente a `TERMINATE`. ¿Qué cargas de trabajo *deben* usar `TERMINATE`, y qué arquitectura compensatoria necesitan? ¿Cuál es el valor de negocio visible para el cliente del `MIGRATE` por defecto?

**Q3.3** — Un proveedor de software licencia por core físico y audita anualmente. El cliente corre 40 VMs en Compute Engine. Explicá, en términos de licenciamiento, por qué los sole-tenant nodes pueden *reducir* el costo total aunque el SKU del nodo sea más caro por hora que las VMs equivalentes en tenencia compartida.

**Q3.4** — El Machine Type Recommender propuso una reducción de tamaño que vale ~USD 71/mes para una VM. ¿Por qué el valor *organizacional* de las recomendaciones de Active Assist suele ser mayor que la suma de los ahorros individuales?

**Fuentes:** <https://cloud.google.com/compute/docs/machine-resource> · <https://cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type> · <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes> · <https://cloud.google.com/compute/docs/instances/live-migration-process>

---

## Ejercicio 4 — Las cuatro palancas de precio, y un modelo de TCO defendible

**Objetivo:** este es el ejercicio de mayor rendimiento del tema. En este examen, "business value" casi siempre se resuelve en: *qué mecanismo de descuento aplica, y qué compromiso exige a cambio.*

Las cuatro palancas:

| Palanca | Compromiso | Reducción típica | Aplica a |
|---|---|---|---|
| **Sustained use discount (SUD)** | Ninguno — automático | hasta ~20–30% | Familias más antiguas (N1 hasta ~30%; N2/N2D/C2/C2D/M1–M3 hasta ~20%). **No** E2 ni las familias más nuevas (N4, C3, C4) |
| **Resource-based CUD** | 1 o 3 años, por región, por familia | ~37% (1 año) / ~55% (3 años) general-purpose; más para memory-optimized | vCPU + RAM comprometidos |
| **Flexible (spend-based) CUD** | 1 o 3 años, gasto por hora | ~28% (1 año) / ~46% (3 años) | Portable entre familias, regiones y varios servicios |
| **Spot VMs** | Ninguno — preemptible con ~30 s de aviso, sin SLA | 60–91% | Tolerante a fallos / batch |

### Pasos

1. Traé precios de lista **en vivo** desde la Cloud Billing Catalog API en lugar de confiar en la tabla de arriba. Primero encontrá el ID de servicio de Compute Engine:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
  | jq -r '.services[] | select(.displayName|test("Compute Engine")) | "\(.serviceId)\t\(.displayName)"'
```

```
6F81-5844-456A	Compute Engine
```

2. Extraé los SKUs on-demand y Spot para vCPU N2 en tu región:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
  | jq -r --arg R "$REGION" '
      .skus[]
      | select(.serviceRegions[]? == $R)
      | select(.description | test("N2 Instance (Core|Ram)"))
      | "\(.description)\t\(.pricingInfo[0].pricingExpression.tieredRates[-1].unitPrice.nanos/1e9)\t\(.pricingInfo[0].pricingExpression.usageUnitDescription)"'
```

Salida representativa:

```
N2 Instance Core running in Americas	0.031611	hour
N2 Instance Ram running in Americas	0.004237	gibibyte hour
Spot Preemptible N2 Instance Core running in Americas	0.007652	hour
Spot Preemptible N2 Instance Ram running in Americas	0.001026	gibibyte hour
```

3. Construí a mano el precio por hora on-demand de `n2-standard-8` (8 vCPU, 32 GB) — el examen espera que sepas que Compute Engine pone precio a **recursos**, no a nombres de SKU:

```
(8 × 0.031611) + (32 × 0.004237) = 0.252888 + 0.135584 = 0.388472 USD/hour
730 h/month × 0.388472 = 283.58 USD/VM/month
```

4. Aplicá cada palanca a una flota de 100 VMs corriendo 24/7:

| Escenario | Tarifa efectiva | 100 VMs / mes | vs on-demand |
|---|---|---|---|
| On-demand, sin descuento | $283.58 | **$28,358** | — |
| Solo SUD (N2, mes completo, ~20%) | $226.86 | **$22,686** | −20% |
| Resource CUD a 1 año (~37%) | $178.66 | **$17,866** | −37% |
| Resource CUD a 3 años (~55%) | $127.61 | **$12,761** | −55% |
| Spot (~70% observado) | $85.07 | **$8,507** | −70% |

5. Ahora construí la forma a la que un equipo de plataforma real se comprometería de verdad — una flota **mixta**, porque comprometer el 100% es apostar a que la flota nunca se achica:

```
 60 VMs × 3-year CUD   =  60 × 127.61 =  $7,656.60
 25 VMs × on-demand+SUD =  25 × 226.86 =  $5,671.50
 15 VMs × Spot (batch)  =  15 ×  85.07 =  $1,276.05
                                        -----------
                            blended     = $14,604.15 / month
                            vs on-demand $28,358.00 → 48.5% reduction
```

6. Verificá vos mismo el contrato de una instancia Spot — el precio es real y el desalojo también:

```bash
gcloud compute instances create cdl-42-spot \
  --zone="$ZONE" \
  --machine-type=n2-standard-2 \
  --provisioning-model=SPOT \
  --instance-termination-action=DELETE \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=20GB --boot-disk-type=pd-balanced

gcloud compute instances describe cdl-42-spot --zone="$ZONE" \
  --format="yaml(scheduling)"
```

```yaml
scheduling:
  automaticRestart: false
  instanceTerminationAction: DELETE
  onHostMaintenance: TERMINATE
  preemptible: true
  provisioningModel: SPOT
```

Fijate en lo que Google no te dejó configurar: `automaticRestart: false` y `onHostMaintenance: TERMINATE` están forzados. Esa es la exclusión del SLA hecha mecánica.

7. Inspeccioná los compromisos existentes (vacío en un proyecto de laboratorio, pero este es el comando de auditoría):

```bash
gcloud compute commitments list \
  --format="table(name, region.basename(), plan, status, endTimestamp)"
```

8. **Desmontaje.**

```bash
gcloud compute instances delete cdl-42-spot --zone="$ZONE" --quiet
```

### Preguntas de verificación

**Q4.1** — Los sustained use discounts no requieren compromiso y se aplican automáticamente, y sin embargo las familias de máquinas más nuevas de Google (N4, C3, C4) y E2 **no** los ofrecen. ¿Qué les dio Google a los clientes en su lugar, y por qué eso es discutiblemente mejor para un cliente con una práctica de FinOps madura?

**Q4.2** — Un resource-based CUD se compra por región y por familia. Una empresa compromete 3 años de N2 en `us-central1`, y después re-plataforma a C4 en `europe-west4` en el segundo año. ¿Qué pasa con el compromiso, y qué instrumento de descuento habría evitado la trampa?

**Q4.3** — Usando el modelo mixto del paso 5: el CFO pregunta "¿por qué no comprometer el 100% a 3 años y ahorrar 55% en todo?". Dá la respuesta en dos partes — una financiera, una arquitectónica.

**Q4.4** — Un batch nocturno de simulación de riesgo tarda 6 horas en 200 VMs y puede hacer checkpoint cada 5 minutos. Una API de pagos de cara al cliente corre en 12 VMs. Asigná una palanca de precio a cada una y enunciá la propiedad *específica* de la carga de trabajo que lo justifica.

**Q4.5** — Compute Engine factura por segundo con un mínimo de 60 segundos. Nombrá un patrón de carga de trabajo donde esa granularidad vale más que cualquier porcentaje de descuento.

**Fuentes:** <https://cloud.google.com/compute/docs/sustained-use-discounts> · <https://cloud.google.com/docs/cuds> · <https://cloud.google.com/compute/docs/instances/spot> · <https://cloud.google.com/billing/docs/how-to/catalog-api> · <https://cloud.google.com/products/calculator>

---

## Ejercicio 5 — Ofertas de almacenamiento: el triángulo costo / latencia / durabilidad

**Objetivo:** mapear cuatro *productos* de almacenamiento distintos — objetos, bloque, archivos y los niveles de archivado — sobre cuatro requisitos de negocio distintos.

### Pasos

1. Enumerá los tipos de almacenamiento en bloque disponibles para una VM. La división generacional importa: Persistent Disk acopla el rendimiento a la capacidad; Hyperdisk los desacopla.

```bash
gcloud compute disk-types list --zones="$ZONE" \
  --format="table(name, validDiskSize)"
```

```
NAME                 VALID_DISK_SIZE
hyperdisk-balanced   4GB-65536GB
hyperdisk-extreme    64GB-65536GB
hyperdisk-ml         4GB-65536GB
hyperdisk-throughput 2048GB-32768GB
local-ssd            375GB-375GB
pd-balanced          10GB-65536GB
pd-extreme           500GB-65536GB
pd-ssd               10GB-65536GB
pd-standard          10GB-65536GB
```

2. Creá uno de cada generación y leé el contrato de rendimiento:

```bash
gcloud compute disks create cdl-42-pd \
  --zone="$ZONE" --type=pd-balanced --size=100GB

gcloud compute disks create cdl-42-hd \
  --zone="$ZONE" --type=hyperdisk-balanced --size=100GB \
  --provisioned-iops=6000 --provisioned-throughput=200

gcloud compute disks describe cdl-42-hd --zone="$ZONE" \
  --format="yaml(name, type.basename(), sizeGb, provisionedIops, provisionedThroughput)"
```

```yaml
name: cdl-42-hd
provisionedIops: '6000'
provisionedThroughput: '200'
sizeGb: '100'
type: hyperdisk-balanced
```

En `pd-balanced` no podés fijar esos campos en absoluto — comprás IOPS sobreaprovisionando capacidad que no necesitás. Ese sobreaprovisionamiento **es** la diferencia de costo.

3. Creá un bucket por clase de almacenamiento y leé el contrato de clase:

```bash
BUCKET="cdl-42-${RANDOM}"
for CLASS in STANDARD NEARLINE COLDLINE ARCHIVE; do
  gcloud storage buckets create "gs://${BUCKET}-$(echo $CLASS | tr 'A-Z' 'a-z')" \
    --location="$REGION" --default-storage-class="$CLASS" \
    --uniform-bucket-level-access
done

gcloud storage buckets list --format="table(name, location, storageClass)" \
  --filter="name~^${BUCKET}"
```

```
NAME                    LOCATION     STORAGE_CLASS
cdl-42-14822-archive    US-CENTRAL1  ARCHIVE
cdl-42-14822-coldline   US-CENTRAL1  COLDLINE
cdl-42-14822-nearline   US-CENTRAL1  NEARLINE
cdl-42-14822-standard   US-CENTRAL1  STANDARD
```

4. Adjuntá una política de ciclo de vida — el mecanismo que convierte una *tabla* de clases de almacenamiento en una curva de costo real:

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
        "condition": { "age": 90, "matchesStorageClass": ["NEARLINE"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 365, "matchesStorageClass": ["COLDLINE"] }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "age": 2555, "numNewerVersions": 3 }
      }
    ]
  }
}
```

```bash
cat > lifecycle.json <<'EOF'
{ ... paste the JSON above ... }
EOF
gcloud storage buckets update "gs://${BUCKET}-standard" --lifecycle-file=lifecycle.json
gcloud storage buckets describe "gs://${BUCKET}-standard" --format="yaml(lifecycle)"
```

5. Hacé la aritmética que justifica la política. 100 TB de logs de auditoría, 10% leídos en cualquier mes, precios de lista ≈ Standard $0.020, Nearline $0.010, Coldline $0.004, Archive $0.0012 por GB-mes (regional, `us-central1`):

```
Flat Standard:  102,400 GB × 0.020                     = $2,048.00 / month
Tiered:          10,240 GB × 0.020 (Standard, hot)     =   $204.80
                 30,720 GB × 0.010 (Nearline)          =   $307.20
                 61,440 GB × 0.0012 (Archive)          =    $73.73
                                                         ----------
                                                          $585.73 / month  (−71%)
   + retrieval:  Nearline $0.01/GB, Coldline $0.02/GB, Archive $0.05/GB
```

6. Mirá el peldaño de archivos — la oferta que existe porque "levantar el servidor NFS" es un requisito de migración real:

```bash
gcloud filestore instances create cdl-42-nfs \
  --zone="$ZONE" --tier=BASIC_HDD \
  --file-share=name=share1,capacity=1TB \
  --network=name=default \
  --dry-run 2>&1 | head -5
```

Los tiers de Filestore (`BASIC_HDD`, `BASIC_SSD`, `ZONAL`, `REGIONAL`, `ENTERPRISE`) intercambian capacidad mínima y precio contra IOPS y alcance de disponibilidad; `REGIONAL`/`ENTERPRISE` son los que tienen una postura de disponibilidad regional. **No crees uno de verdad** — la capacidad mínima facturable es 1 TB.

7. **Desmontaje.**

```bash
gcloud compute disks delete cdl-42-pd cdl-42-hd --zone="$ZONE" --quiet
for CLASS in standard nearline coldline archive; do
  gcloud storage rm --recursive "gs://${BUCKET}-${CLASS}" --quiet
done
```

### Preguntas de verificación

**Q5.1** — La clase Archive cuesta ~$0.0012/GB-mes contra los ~$0.020 de Standard — una diferencia de 16× — y tiene la *misma* durabilidad de diseño de 11 nueves. Nombrá los tres mecanismos de costo que hacen que Archive sea caro para la carga de trabajo equivocada, y describí un escenario donde el tiering de ciclo de vida a Archive **aumenta** la factura.

**Q5.2** — Hyperdisk te permite aprovisionar IOPS y throughput independientemente de la capacidad. Expresá el valor de negocio como una frase sobre una base de datos con un dataset de 200 GB que necesita 60.000 IOPS.

**Q5.3** — Local SSD está fijo en incrementos de 375 GB, está físicamente conectado al host y es **efímero**. Dado eso, ¿para qué sirve realmente, y qué te dice su existencia sobre cómo están pensados para componerse los niveles de almacenamiento de Compute Engine?

**Q5.4** — Un equipo propone reemplazar un share de Filestore de 4 TB por un bucket de Cloud Storage "porque los objetos son más baratos por GB". ¿Qué se rompe, y cuál es el criterio de decisión correcto entre almacenamiento de archivos y de objetos?

**Fuentes:** <https://cloud.google.com/storage/docs/storage-classes> · <https://cloud.google.com/storage/docs/lifecycle> · <https://cloud.google.com/compute/docs/disks> · <https://cloud.google.com/filestore/docs/service-tiers> · <https://cloud.google.com/storage/sla>

---

## Ejercicio 6 — Ofertas de red: tiers, balanceo de carga y conectividad híbrida

**Objetivo:** la red de Google es la oferta que los clientes más a menudo no logran costear y más a menudo subestiman como diferenciador. Dos decisiones dominan: el **network service tier** y el **tipo de conectividad híbrida**.

### Pasos

1. Leé el network tier por defecto del proyecto y cambialo explícitamente. Los valores por defecto que cuestan dinero nunca deberían ser implícitos:

```bash
gcloud compute project-info describe \
  --format="value(defaultNetworkTier)"
```

```
PREMIUM
```

2. Reservá una dirección en cada tier y observá la restricción que impone la plataforma:

```bash
gcloud compute addresses create cdl-42-premium \
  --region="$REGION" --network-tier=PREMIUM

gcloud compute addresses create cdl-42-standard \
  --region="$REGION" --network-tier=STANDARD

gcloud compute addresses list \
  --format="table(name, address, region.basename(), networkTier, status)" \
  --filter="name~^cdl-42"
```

```
NAME             ADDRESS         REGION       NETWORK_TIER  STATUS
cdl-42-premium   34.66.112.210   us-central1  PREMIUM       RESERVED
cdl-42-standard  35.184.20.17    us-central1  STANDARD      RESERVED
```

3. Intentá construir una IP externa **global** en Standard tier — el fallo es la lección:

```bash
gcloud compute addresses create cdl-42-global-standard \
  --global --network-tier=STANDARD
```

```
ERROR: (gcloud.compute.addresses.create) Could not fetch resource:
 - Invalid value for field 'resource.networkTier': 'STANDARD'.
   Global addresses only support PREMIUM network tier.
```

Standard Tier es **regional por construcción**. El balanceo de carga global anycast — una IP servida desde la más cercana de las ubicaciones de borde de Google — es una capacidad de Premium Tier.

4. Poné precio a la decisión de tier sobre 10 TB/mes de egress a internet (precios de lista, Premium escalonado a ~$0.12/GB para el primer TiB y después ~$0.11/GB; Standard ~$0.085/GB):

```
Premium:  1,024 GB × 0.12 = $122.88
          9,216 GB × 0.11 = $1,013.76      → $1,136.64 / month
Standard: 10,240 GB × 0.085                → $  870.40 / month   (−23%)
```

El ahorro del 23% compra: nada de IP global anycast, nada de cold-potato routing (el tráfico sale del backbone de Google en la región *origen* en lugar de en el borde más cercano al usuario), balanceo de carga solo regional, y un perfil de latencia/jitter fijado por internet pública.

5. Enumerá las familias de balanceadores de carga — el examen evalúa la *selección*, así que aprendé los ejes: externo/interno, global/regional, proxy/passthrough, L7/L4.

```bash
gcloud compute backend-services list \
  --format="table(name, loadBalancingScheme, protocol, region.basename())"
```

| Balanceador de carga | Esquema | Alcance | Capa | Caso de uso de negocio |
|---|---|---|---|---|
| Global external Application LB | `EXTERNAL_MANAGED` | Global | L7 | Web/API pública, una IP anycast mundial, Cloud CDN + Cloud Armor se conectan acá |
| Regional external Application LB | `EXTERNAL_MANAGED` | Regional | L7 | Capa web atada a residencia de datos |
| External proxy Network LB | `EXTERNAL_MANAGED` | Global/Regional | L4 proxy | Descarga TCP/SSL para protocolos no HTTP |
| External passthrough Network LB | `EXTERNAL` | Regional | L4 passthrough | Preservar la IP del cliente, UDP, protocolos arbitrarios; basado en Maglev |
| Internal Application LB | `INTERNAL_MANAGED` | Regional/Cross-region | L7 | Microservicio a microservicio con ruteo por path |
| Internal passthrough Network LB | `INTERNAL` | Regional | L4 | Gateway por defecto / inserción de NVA, VIPs de base de datos |

6. Compará los productos de conectividad híbrida contra un requisito de negocio, no contra un número de ancho de banda:

| Producto | Ancho de banda | SLA | ¿Atraviesa internet pública? | Motor típico |
|---|---|---|---|---|
| **HA VPN** | ~3 Gbps/túnel, agregado | 99.99% (configuración HA) | Sí, cifrado (IPsec) | Rápido de levantar, poco ancho de banda, sin presencia en colo |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | 99.9% / 99.99% según topología | No | Sin presencia en colo, pero necesita un camino privado y predecible |
| **Dedicated Interconnect** | Circuitos de 10 o 100 Gbps | 99.9% / 99.99% según topología | No | Volumen alto sostenido; además **baja el precio del egress** |
| **Cross-Cloud Interconnect** | 10 / 100 Gbps | Según topología | No | Enlace privado a AWS/Azure/OCI para planos de datos multicloud reales |
| **Network Connectivity Center** | n/a (plano de control) | n/a | n/a | Tránsito hub-and-spoke entre VPCs, sitios y nubes |

7. **Desmontaje.**

```bash
gcloud compute addresses delete cdl-42-premium cdl-42-standard \
  --region="$REGION" --quiet
```

### Preguntas de verificación

**Q6.1** — Explicá el "cold-potato routing" y por qué el uso que hace Google de él en Premium Tier es una decisión de *producto* con una consecuencia de *costo*, no solo una preferencia de ruteo.

**Q6.2** — Una empresa de videojuegos atiende jugadores en 30 países desde una región y está considerando Standard Tier para ahorrar 23% en egress. ¿Qué única restricción técnica del paso 3 hace que sea un mal negocio para ellos, y qué tendría que ser cierto sobre su arquitectura para que Standard Tier pasara a ser correcto?

**Q6.3** — Un fabricante mueve 400 TB/mes entre un ERP on-prem y BigQuery. Actualmente usan HA VPN. Dá las dos razones independientes por las que Dedicated Interconnect gana acá, una de rendimiento y una financiera.

**Q6.4** — ¿Cuándo un Network Load Balancer **internal passthrough** le gana a un Load Balancer **internal Application**, dado que el Application LB tiene estrictamente más funcionalidades?

**Fuentes:** <https://cloud.google.com/network-tiers/docs/overview> · <https://cloud.google.com/load-balancing/docs/load-balancing-overview> · <https://cloud.google.com/network-connectivity/docs/interconnect> · <https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview>

---

## Ejercicio 7 — Cuando el datacenter no puede irse del todo: GCVE, GDC y hardware especializado

**Objetivo:** el examen incluye escenarios donde "migrar a Compute Engine" es la respuesta equivocada — soberanía, latencia hacia una planta fabril, un appliance licenciado inamovible, o una salida de datacenter fija a nueve meses.

### Pasos

1. Mapeá las cuatro salidas de emergencia antes de necesitarlas:

| Oferta | Qué es | Dónde corre | Motor de negocio principal |
|---|---|---|---|
| **Google Cloud VMware Engine (GCVE)** | Stack VMware gestionado (vSphere, vSAN, NSX, HCX) sobre nodos dedicados | Región de Google | Salida del datacenter con fecha límite y **cero refactorización de aplicaciones**; conserva las herramientas y las habilidades VMware |
| **Sole-tenant nodes** | Host físico dedicado a las VMs de un solo cliente | Región de Google | Licenciamiento por core físico; aislamiento físico por cumplimiento |
| **Google Distributed Cloud (connected)** | Hardware/software gestionado por Google que corre en *tu* datacenter o en el borde, enlazado a Google Cloud | Instalaciones del cliente / borde | Gravedad de datos, baja latencia hacia la maquinaria, procesamiento local con plano de control en la nube |
| **Google Distributed Cloud (air-gapped)** | Stack completo **sin** conexión a Google Cloud | Instalaciones del cliente | Soberanía, cargas clasificadas, jurisdicciones que prohíben cualquier egress |

2. Verificá la disponibilidad por región de GCVE — las ofertas híbridas están mucho más restringidas por región que el cómputo central, lo que frecuentemente da vuelta un plan de migración:

```bash
gcloud vmware private-clouds list --location="$REGION-a" 2>&1 | head -3
```

```
Listed 0 items.
```

```bash
gcloud vmware locations list --format="table(name.basename())" 2>&1 | head -10
```

3. Razoná sobre el **desplazamiento de la responsabilidad compartida**. Para cada oferta, anotá quién parchea el hipervisor y quién parchea el SO invitado:

```
Compute Engine     → Google: hypervisor + host.  Customer: guest OS, apps.
GCVE               → Google: hardware + ESXi/vSAN/NSX lifecycle.  Customer: VMs, guest OS, apps.
GDC (connected)    → Google: platform software lifecycle.  Customer: physical security, power, workloads.
GDC (air-gapped)   → Customer: everything Google cannot reach — including update delivery.
```

4. Tomá nota del caso especial de las bases de datos. Las cargas Oracle han sido históricamente el mayor bloqueante individual para salir del datacenter. El camino actual es **Oracle Database@Google Cloud** — infraestructura Oracle Exadata ubicada físicamente en datacenters de Google Cloud con un interconnect de baja latencia hacia tu VPC. Si un escenario menciona un parque Oracle heredado, esta es la respuesta moderna; verificá el producto actual y la lista de regiones en <https://cloud.google.com/oracle/database/docs> antes de citar disponibilidad, y consultá el estado de la oferta más antigua de Bare Metal Solution en la misma documentación en lugar de asumirlo.

### Preguntas de verificación

**Q7.1** — Una aseguradora europea debe abandonar dos datacenters en 11 meses. Corre 1.400 VMs VMware, tiene un equipo de operaciones formado en vSphere, y no tiene el código fuente de las aplicaciones para un tercio del parque. Ordená GCVE, Compute Engine (rehost) y refactorizar a GKE, y defendé el orden con el argumento de *time-to-value*.

**Q7.2** — Contrastá GDC connected y GDC air-gapped en un único eje: ¿qué capacidad *pierde* la variante air-gapped, y qué clientes aceptan esa pérdida deliberadamente?

**Q7.3** — Una planta automotriz necesita inferencia sub-10ms sobre un modelo de visión que vigila una línea de producción, y debe seguir operando durante una caída de la WAN. ¿Qué oferta, y qué dos palabras del requisito lo decidieron?

**Q7.4** — Los nodos de GCVE se facturan por nodo/hora con un tamaño mínimo de cluster, frente a la facturación por segundo de Compute Engine. ¿Por qué el modelo de facturación *menos* granular es a veces el que prefiere un CFO?

**Fuentes:** <https://cloud.google.com/vmware-engine/docs/overview> · <https://cloud.google.com/distributed-cloud/docs> · <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes> · <https://cloud.google.com/oracle/database/docs>

---

## Ejercicio 8 — La ruta de migración y la evaluación que la precede

**Objetivo:** las ofertas de infraestructura se eligen durante una evaluación, no durante un taller de diseño. El examen espera que conozcas las fases de migración y qué herramienta sirve a cada una.

### Pasos

1. Aprendé las cuatro fases que nombra Google, y qué produce cada una:

```
Assess    → inventory, dependency map, TCO comparison   → Migration Center
Plan      → landing zone, IAM, network, org policy      → Cloud Foundation / landing zone
Deploy    → move workloads                              → Migrate to Virtual Machines,
                                                          Database Migration Service,
                                                          Storage Transfer Service,
                                                          Transfer Appliance
Optimize  → right-size, commit, modernize               → Active Assist, CUDs, refactor
```

2. Mapeá las *estrategias* de migración sobre las ofertas de los ejercicios 2 y 7:

| Estrategia | Significado | Aterriza en | Esfuerzo | Beneficio de nube realizado |
|---|---|---|---|---|
| Rehost ("lift and shift") | Mover la VM tal cual | Compute Engine, GCVE | El menor | El menor |
| Replatform ("move and improve") | Cambiar componentes por servicios gestionados | Compute Engine + Cloud SQL, GKE | Medio | Medio |
| Refactor / re-arquitecturar | Reescribir para cloud-native | Cloud Run, GKE Autopilot, BigQuery | El mayor | El mayor |
| Repurchase | Reemplazar por SaaS | Google Workspace, SaaS de terceros | Bajo | Varía |
| Retire | Borrar | — | El menor | Inmediato |
| Retain | Dejar donde está, revisar después | — | Ninguno | Ninguno |

3. Inspeccioná la superficie de evaluación sin correr un descubrimiento completo:

```bash
gcloud migration-center groups list --location="$REGION" 2>&1 | head -3
gcloud migration-center assets list --location="$REGION" \
  --format="table(name.basename(), assetType, updateTime)" 2>&1 | head -5
```

```
Listed 0 items.
```

Un inventario vacío es el estado inicial correcto — y lo correcto para señalar cuando alguien propone una ola de migración sin datos de descubrimiento.

4. Calculá el lado de disponibilidad del caso de negocio. El SLA de Compute Engine es **99.99%** para instancias distribuidas en múltiples zonas de una región corriendo la misma carga de trabajo, y **99.9%** para una instancia única con los tipos de disco requeridos. Convertilo a presupuesto de error:

```
Monthly minutes = 43,800
99.9%   → 43.80 minutes of allowed downtime per month  (~8h 46m per year)
99.95%  → 21.90 minutes per month                      (~4h 23m per year)
99.99%  →  4.38 minutes per month                      (~52m 34s per year)
```

5. Convertí eso en dinero. Una plataforma de e-commerce factura USD 240.000/hora de ingreso bruto en pico:

```
Single-zone (99.9%)   : 8.76 h/yr × 240,000 = $2,102,400 expected annual revenue at risk
Multi-zone  (99.99%)  : 0.88 h/yr × 240,000 =   $211,200
                                              -----------
Value of the multi-zone design               = $1,891,200 / year
```

Comparalo con el costo incremental de correr en tres zonas — típicamente un balanceador de carga, tráfico entre zonas y margen de capacidad ociosa. **Este cálculo es todo el argumento de valor de negocio de la arquitectura regional**, y es la forma de respuesta que el examen premia.

6. Construí la infraestructura regional y auto-reparable que se gana esa cifra de 99.99%. Terraform completo y válido:

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region"     { type = string  default = "us-central1" }

resource "google_compute_health_check" "web" {
  name                = "web-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "web" {
  name_prefix  = "web-"
  machine_type = "n4-standard-4"
  region       = var.region

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "hyperdisk-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network = "default"
  }

  scheduling {
    provisioning_model  = "STANDARD"
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
  }

  labels = {
    cost-center = "retail-web"
    env         = "prod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "web" {
  name                      = "web-mig"
  region                    = var.region
  base_instance_name        = "web"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-c"]

  version {
    instance_template = google_compute_instance_template.web.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.web.id
    initial_delay_sec = 120
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_autoscaler" "web" {
  name   = "web-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.web.id

  autoscaling_policy {
    min_replicas    = 3
    max_replicas    = 30
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}
```

Tres detalles de diseño sostienen el SLA: `distribution_policy_zones` (distribución entre dominios de fallo), `auto_healing_policies` (recrear ante fallo del health check, no solo ante caída de la VM), y `max_unavailable_fixed = 0` junto con `max_surge_fixed = 3` (la actualización progresiva nunca baja de la capacidad).

7. **No hagas `terraform apply`** salvo que tengas intención de pagar por tres VMs `n4-standard-4`. `terraform validate` y `terraform plan` son gratis y demuestran el manifiesto:

```bash
terraform init -backend=false && terraform validate
```

```
Success! The configuration is valid.
```

### Preguntas de verificación

**Q8.1** — En el paso 6, `max_unavailable_fixed = 0` y `max_surge_fixed = 3`. Explicá la garantía de disponibilidad que codifica ese par durante una actualización progresiva, y qué se rompería si en cambio pusieras `max_surge_fixed = 0`.

**Q8.2** — La matemática de SLA del paso 5 asumió que el despliegue multizona rinde 99.99%. Nombrá dos errores de diseño que dejarían a un cliente pagando por tres zonas mientras sigue teniendo una disponibilidad *efectiva* de 99.9% (o peor).

**Q8.3** — Un CIO quiere "rehostear todo y modernizar después". Enunciá el argumento más fuerte **a favor** y el más fuerte **en contra**, y dá la condición que decide entre ambos.

**Q8.4** — ¿Por qué la estructura de créditos del SLA de Google (créditos de servicio, no efectivo) hace que el cálculo de ingreso en riesgo del paso 5 sea la *única* manera honesta de ponerle precio a la disponibilidad?

**Q8.5** — El descubrimiento de Migration Center produce un mapa de dependencias. Nombrá el fallo de migración específico que existe para prevenir.

**Fuentes:** <https://cloud.google.com/migration-center/docs/migration-center-overview> · <https://cloud.google.com/migrate/virtual-machines/docs> · <https://cloud.google.com/compute/sla> · <https://cloud.google.com/architecture/framework/reliability>

---

## Ejercicio 9 — Armar la narrativa para el directorio

**Objetivo:** la última habilidad que evalúa este objetivo es la traducción — de `n2-standard-8` a una frase que un comité ejecutivo pueda votar.

### Pasos

1. Traé los cuatro números que ahora sabés producir, para una salida hipotética de datacenter de 400 VMs:

```
(a) Infrastructure run-rate, on-demand           Exercise 4, step 4
(b) Infrastructure run-rate, blended commitments Exercise 4, step 5
(c) Storage cost, flat vs lifecycle-tiered       Exercise 5, step 5
(d) Revenue at risk, single-zone vs multi-zone   Exercise 8, step 5
```

2. Escribí el resumen de cinco líneas. Cada línea debe ser trazable a un comando que ejecutaste:

```
1. CAPEX ELIMINATION   — no hardware refresh cycle; datacenter lease exits in month 11.
2. RUN-RATE            — blended commitment model lands 48.5% under on-demand list
                         (3-yr CUD baseline + SUD burst + Spot batch).
3. DATA COST CURVE     — lifecycle tiering cuts archive storage 71% with no
                         application change.
4. AVAILABILITY        — regional MIG raises the SLA floor from 99.9% to 99.99%,
                         removing ~$1.89M/yr of expected revenue at risk.
5. OPTIONALITY         — the same platform hosts VMware (GCVE), containers (GKE),
                         and serverless (Cloud Run); modernization becomes incremental,
                         not a second migration.
```

3. Identificá las tres afirmaciones de ese resumen que un auditor podría falsear, y la evidencia de cada una:

```
Claim 2 → Billing Catalog API export + signed commitment records (`gcloud compute commitments list`)
Claim 3 → Storage Insights / bucket lifecycle config + billing export by storage class
Claim 4 → Compute Engine SLA text + MIG distribution_policy_zones in the Terraform state
```

4. Confirmá que no te quedaron recursos facturables sueltos de ningún ejercicio:

```bash
gcloud compute instances list --format="table(name, zone.basename(), status)"
gcloud compute disks list     --format="table(name, zone.basename(), sizeGb)"
gcloud compute addresses list --format="table(name, region.basename(), status)"
gcloud run services list      --format="table(metadata.name, region)"
gcloud storage buckets list   --filter="name~cdl-42" --format="value(name)"
```

Todos los comandos deben devolver `Listed 0 items.` antes de que cierres el laboratorio.

### Preguntas de verificación

**Q9.1** — La línea 1 dice "CAPEX elimination". Un CFO objeta que un committed use discount a 3 años es económicamente un compromiso de capital. ¿La objeción es correcta? Respondé con precisión.

**Q9.2** — La línea 5 afirma "optionality". ¿Cuál es el contraargumento que debería plantear un miembro escéptico del directorio, y cuál es la respuesta honesta?

**Q9.3** — De las cinco líneas, ¿cuál es el caso de negocio *más débil* por sí solo, y por qué las propuestas de infraestructura igual arrancan con él?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — Una **alerta de presupuesto** es observacional: manda notificaciones en los umbrales y nunca bloquea una llamada de API, así que el gasto continúa más allá del 100%. Una **cuota** es un techo técnico duro sobre la cantidad o la tasa de recursos (por ejemplo, vCPUs por región) y *es* el único tope real — una petición por encima de la cuota falla con `QUOTA_EXCEEDED`. Un **committed use discount** no es ni un tope ni una alerta; es una obligación de compra que baja la *tarifa* mientras le garantiza a Google un gasto mínimo, así que solo puede subir tu piso, nunca bajar tu techo. El encuadre relevante para el examen: los presupuestos dan visibilidad, las cuotas dan control, los CUDs dan precio. El control de costos requiere los tres; los clientes que compran solo el CUD se sorprenden dos veces.

**A0.2** — Tanto el **precio del recurso** como el **precio de transferencia de datos** dependen de la región. La misma `n2-standard-8` cuesta materialmente más en `southamerica-east1` o `asia-northeast1` que en `us-central1`, y el precio del egress a internet varía tanto por región de origen como por continente de destino. Un tercer componente, a menudo olvidado, es la **replicación entre regiones** del almacenamiento multi-region. Así que "¿cuánto cuesta esto?" es incontestable sin una región, y un TCO construido en `us-central1` y ejecutado en `europe-west3` está simplemente equivocado.

### Ejercicio 1

**A1.1** — Una **región con múltiples zonas** (por ejemplo, `europe-west3` con `-a/-b/-c`) satisface ambas cosas: la frontera de residencia es el único estado miembro, y las zonas son dominios de fallo independientes — energía, refrigeración y red separadas dentro de la región, de modo que perder un edificio no pierde el servicio. Una ubicación **multi-region** (por ejemplo, `EU`) no satisface ninguna de las dos limpiamente para este requisito: suena más segura porque abarca una geografía más amplia, pero replica los datos entre *múltiples países* dentro de la UE, lo que viola la regla de residencia en un único estado miembro. La lección: un alcance geográfico más amplio no es automáticamente mejor — la residencia es una restricción que estrecha, la disponibilidad es una restricción que ensancha, y entran en conflicto.

**A1.2** — Un MIG regional distribuye instancias entre las zonas que enumerás. Si tu instance template fija `minCpuPlatform: "Intel Emerald Rapids"` y una de las zonas no ofrece esa plataforma, la creación de instancias en esa zona falla con un error de recurso. En la práctica esto se manifiesta como un MIG que reporta el tamaño equivocado, un autoscaler que no puede escalar hacia afuera durante un pico de tráfico, o un auto-heal que nunca reemplaza una VM fallada. La consecuencia de negocio: pagaste por un diseño de tres zonas, documentaste un SLA de 99.99%, y bajo carga estás corriendo en dos zonas con capacidad reducida — una regresión de disponibilidad que solo aparece durante el incidente que se suponía que iba a prevenir.

**A1.3** — (1) **Rendimiento predecible sin un contrato negociado.** El tráfico entre regiones se mantiene sobre fibra de propiedad privada en lugar de transitar redes de terceros, así que la latencia y la pérdida de paquetes son propiedades de ingeniería que Google controla, no el SLA de un proveedor que renegociás cada año. (2) **El costo del alcance global ya está en el precio unitario.** Llegar a una geografía nueva no requiere un contrato de carrier nuevo, un colo nuevo ni un proyecto de capital — es un flag de región en un despliegue. El encuadre para el CFO en ambos casos: convierte una expansión de red impredecible, dirigida por contratos e intensiva en capital, en un costo operativo variable sin ciclo de compras.

**A1.4** — Es defendible cuando (a) la latencia hacia la población primaria de usuarios es un **requisito declarado y medible** con ingresos asociados, o la ley de residencia de datos prohíbe la alternativa; (b) el delta de carbono está **cuantificado y reportado** en lugar de ignorado — la exportación de Carbon Footprint a BigQuery hace que el número sea auditable; y (c) la decisión queda **registrada con un responsable y una fecha de revisión**, para que se revise cuando mejore el CFE% regional. Lo que *no* es defendible es elegir la región con más carbono sin medir el delta. El encuadre de sostenibilidad del examen es transparencia y rendición de cuentas, no una regla absoluta de que siempre gana la región más verde.

### Ejercicio 2

**A2.1** — `minScale: "1"` mantiene una instancia caliente permanentemente. El cliente **compra** la eliminación de la latencia de arranque en frío en la primera petición después de un período ocioso — para una API de pagos esto es la diferencia entre un p99 de 40 ms y uno de 2.000 ms para el usuario desafortunado. El cliente **deja de recibir** el escalado a cero, que es la mayor ventaja de costo de Cloud Run: ahora el servicio factura continuamente, 730 horas al mes, lo llame alguien o no. El trade-off es exactamente "latencia predecible frente a costo ocioso cero", y la respuesta correcta depende de si el patrón de tráfico tiene períodos ociosos suficientemente largos como para que se reclamen las instancias.

**A2.2** — **Autopilot lo castiga directamente**: se te factura por el 3× solicitado, así que el desperdicio aparece como una línea en la factura el día que se despliega. **GKE Standard lo oculta**: pagás por nodos, así que sobre-solicitar aparece solo como mal bin-packing — el cluster necesita más nodos de los que la carga real justifica, y el costo parece "necesitamos un cluster más grande" en lugar de "nuestros requests están mal". La implicación para FinOps es que Autopilot convierte los resource requests en una señal *financiera*, lo que alinea al desarrollador que escribe el manifiesto con la persona que paga la factura. En Standard, cerrar ese lazo requiere herramientas separadas (asignación de costos por namespace, recomendaciones de VPA) porque el modelo de facturación no lo va a hacer por vos.

**A2.3** — Orden: **(1) Compute Engine o GCVE (rehost), (2) GKE Standard, (3) Cloud Run/Autopilot — efectivamente excluidos.** El driver con acceso al kernel descarta todos los peldaños de contenedores gestionados y serverless, porque esos corren tu código en un contenedor sobre un host que no controlás; GKE Autopilot directamente prohíbe pods privilegiados. Justificación de negocio: *el plazo de nueve meses y la dependencia del kernel implican que las únicas opciones que terminan a tiempo son las que mueven la máquina, no la aplicación — rehostear a Compute Engine (o GCVE si el parque es VMware) elimina el datacenter sin tocar el software, y la modernización pasa a ser una decisión separada y opcional, tomada después desde una posición segura.*

**A2.4** — En Cloud Run se te factura por **CPU y memoria asignadas por instancia-segundo** (más las peticiones), así que los valores de `cpu`/`memory` son literalmente el multiplicador del precio — reducirlos a la mitad reduce a la mitad la porción de cómputo de la factura. En GKE Standard se te factura por los **nodos**, que existen se programen pods sobre ellos o no; los `requests` de un pod afectan solo la *planificación*, es decir, cuántos pods entran por nodo. Bajar los requests reduce el costo en GKE Standard solo *indirectamente y solo si* la mejor densidad permite que el cluster autoscaler quite nodos. Esta es la ilustración más nítida del trade-off de la escalera de abstracción: en los peldaños altos, las declaraciones de recursos son un precio; en los bajos, son una pista.

### Ejercicio 3

**A3.1** — El número: la forma personalizada es ~6/8 de las vCPU y ~20/32 de la RAM de `n2-standard-8`, así que roughly **30% más barata** que el tipo predefinido que mejor encaja, sin pérdida de rendimiento para una carga medida en 6/20. La frase: *pagás por la forma real de la carga de trabajo en lugar de redondear hacia arriba al catálogo del proveedor.* Custom es la elección **equivocada** cuando (a) querés committed use discounts bajo un modelo de compromiso simple y auditable y las formas estándar hacen que el compromiso sea más fácil de razonar, o, más importante, (b) la familia no soporta formas personalizadas en absoluto — las familias más nuevas (C3, C4, N4 y las familias de aceleradores/optimizadas para almacenamiento) son solo predefinidas, así que una estrategia de formas personalizadas te ata silenciosamente a generaciones más viejas. Un tercer caso, más suave: la estandarización de toda la flota vale más que la optimización por VM cuando tenés miles de VMs y un equipo de plataforma chico.

**A3.2** — Cargas que **deben** usar `TERMINATE`: VMs con GPU o TPU adjuntas en configuraciones que no soportan migración, VMs Spot/preemptible (forzado), y algunas configuraciones de sole-tenant y confidential computing. Su arquitectura compensatoria es **checkpointing más orquestación**: el trabajo debe ser reanudable, y un MIG, Batch o un controlador de Kubernetes debe recrear la instancia y reanudar desde el último checkpoint. El valor de negocio de `MIGRATE` como opción por defecto es que **el mantenimiento del datacenter de Google es invisible para el cliente** — sin ventanas de mantenimiento que negociar con el negocio, sin tickets de comité de cambios para parchear hosts, sin HA a nivel aplicación requerida solo para sobrevivir al trabajo rutinario de infraestructura. En términos on-premises, elimina todo un ritual operativo recurrente.

**A3.3** — El licenciamiento por core físico cobra por los cores del *host*, no por las vCPU del guest. En Compute Engine con tenencia compartida no podés ver ni acotar el host físico, así que un auditor estricto puede exigir licenciar todo el parque en el que la VM podría teóricamente aterrizar — una exposición ilimitada e impresupuestable. Un **sole-tenant node** te da un host físico conocido con una cantidad de cores conocida, y la afinidad de nodo fija tus VMs a él. Ahora licenciás *los cores de ese nodo*, un número fijo y demostrable, y podés empaquetar muchas VMs encima. La aritmética que importa: si la licencia cuesta más por core que la infraestructura, el objetivo de optimización pasa de "minimizar vCPU-horas" a "maximizar VMs por core físico licenciado", y el SKU de nodo más caro gana en costo total. Esta es también la razón por la que los sole-tenant nodes soportan escenarios de **bring-your-own-license** que la tenencia compartida no puede.

**A3.4** — Porque la recomendación individual es un síntoma, y el agregado es una **señal de gestión**. Los $71/mes de una VM son ruido. Pero una exportación de Recommender a nivel proyecto u organización te dice: cuánto de tu flota está sistemáticamente sobre-aprovisionado, qué equipos sobre-aprovisionan, si el patrón está empeorando, y si tus valores por defecto de aprovisionamiento (plantillas, módulos de Terraform, golden images) están mal en el origen. Arreglar el valor por defecto arregla todas las VMs futuras; arreglar una VM arregla una VM. El valor de negocio de Active Assist es, por lo tanto, **detección de desperdicio continua y automatizada, integrada en la plataforma**, en lugar de un ejercicio trimestral de consultoría — y su salida es una entrada de gobernanza, no solo una línea de ahorro.

### Ejercicio 4

**A4.1** — Google le dio a esas familias **precios de lista on-demand más bajos** y orientó a los clientes hacia los **flexible (spend-based) CUDs**. Para una práctica de FinOps madura esto es mejor porque el SUD es un descuento *pasivo* alrededor del cual no podés planificar — depende de cuántas horas corrió cada VM en un mes calendario, se reinicia cada mes, y no se puede pronosticar en un presupuesto con confianza. Un CUD flexible es un instrumento explícito, portable y pronosticable: te comprometés a un gasto por hora, conocés el porcentaje de descuento, y el descuento sigue a tu arquitectura a medida que cambia. Cambiar un descuento automático impredecible por uno comprado y predecible es el trade correcto para cualquiera que haga planificación de capacidad; es un peor trade para un cliente chico con uso ráfaga y no planificado, que es por lo que existe el precio base on-demand más bajo para compensar.

**A4.2** — Un resource-based CUD está **atado a una región y a una familia de máquinas** y sigue facturando por su plazo completo, lo uses o no. Mudarse a C4 en `europe-west4` te deja pagando capacidad N2 sin usar en `us-central1` durante los dos años restantes — el clásico varamiento de compromiso. Mitigaciones en orden de preferencia: (1) comprar un **CUD flexible / spend-based**, que es portable entre familias, regiones y varios servicios y habría sobrevivido intacto al cambio de plataforma; (2) si ya se tienen compromisos basados en recursos, algunos pueden **modificarse o transferirse dentro de una cuenta de facturación** — verificá las reglas vigentes antes de asumirlo; (3) hacé coincidir el *plazo* del compromiso con tu certeza arquitectónica — 3 años es apropiado para un parque estable, 1 año para uno bajo modernización activa. El principio general: **la profundidad de descuento que comprás no debería exceder la certeza arquitectónica que tenés.**

**A4.3** — *Financiera:* un compromiso a 3 años es una obligación de pago independientemente del uso. Comprometer el 100% convierte toda ganancia futura de eficiencia — right-sizing, refactorizar a Cloud Run, retirar un servicio, una caída del negocio — en costo varado, porque los ahorros que diseñás ya están pagados. Estarías comprando un descuento del 55% sobre capacidad que pensás dejar de usar. *Arquitectónica:* la flota no es una sola cosa. La capacidad base que corre 24/7 durante tres años tiene genuinamente forma de compromiso; la capacidad de ráfaga no (está ociosa la mayor parte del mes, así que un compromiso no cubre nada); y el batch tolerante a fallos tiene forma de Spot, donde el descuento es más profundo que cualquier compromiso y no requiere obligación alguna. La postura correcta es **comprometer el piso, no el pico** — típicamente el P50–P70 del uso en estado estable — y dejar que las palancas por encima del piso queden elásticas. Por eso el modelo mixto aterriza en 48,5% de ahorro real y es *más seguro* que el 55% del titular.

**A4.4** — **Simulación batch → Spot VMs.** La propiedad que lo justifica no es "es un trabajo batch", es el **checkpointing cada 5 minutos con un aviso de preemption de ~30 segundos**: el trabajo máximo perdido por un desalojo está acotado y es pequeño, y el trabajo no tiene ningún compromiso externo de disponibilidad. La holgura del plazo también importa — un trabajo de 6 horas en una ventana nocturna tolera ser reprogramado. **API de pagos → committed use discount (más margen on-demand).** La propiedad que lo justifica es que es de cara al cliente con un compromiso de disponibilidad, así que nunca debe ser desalojada; y corre continuamente en un piso predecible, que es exactamente la forma de uso que un compromiso tarifa bien. Notá la simetría: el descuento de Spot es la compensación por aceptar riesgo de desalojo, y la API de pagos es precisamente la carga que no puede aceptarlo a ningún precio.

**A4.5** — **Cargas de trabajo en ráfaga, de vida corta y alto paralelismo** — granjas de build de CI/CD, ejecutores de pruebas por commit, trabajos efímeros de renderizado o transcodificación, procesamiento de datos ad-hoc. Si un build tarda 4 minutos y corrés 500 por día, la facturación por hora te cobraría 500 horas por 33 horas de trabajo: un sobrecosto de 15× que **ningún porcentaje de descuento puede recuperar**, porque el desperdicio está en la granularidad de facturación, no en la tarifa. La facturación por segundo con un mínimo de 60 segundos hace que "levantar 200 VMs por tres minutos" sea económicamente racional, lo que a su vez hace asequible una *arquitectura distinta* — paralelismo masivo de vida corta en lugar de un cluster chico siempre encendido con una cola. La granularidad no solo reduce una factura; habilita un diseño.

### Ejercicio 5

**A5.1** — Los tres mecanismos: (1) **Duración mínima de almacenamiento** — los objetos Archive se facturan por 365 días incluso si se borran el día 2, como cargo de borrado anticipado. (2) **Tarifas de recuperación** — aproximadamente $0.05/GB, cobradas cada vez que leés, contra el cero de Standard. (3) **Cargos por operaciones (Clase A/B)**, que dominan cuando la cantidad de objetos es alta y los objetos son chicos. El escenario donde el tiering *aumenta* la factura: un archivo de cumplimiento con muchos objetos pequeños que una herramienta de auditoría trimestral escanea por completo. A 100 TB, una sola lectura completa cuesta ~$5.120 solo en recuperación; cuatro escaneos al año superan todo el costo anual de almacenamiento en clase Standard que estabas tratando de evitar. **La clase de almacenamiento es una apuesta sobre la frecuencia de acceso, y una apuesta equivocada sale más cara que no haber hecho tiering nunca.** Notá también que todas las clases comparten la misma durabilidad de diseño de ~11 nueves y la misma ruta de acceso con latencia de milisegundos — los niveles difieren en el *costo de acceso*, no en velocidad ni en seguridad, que es el hecho más comúnmente mal enunciado sobre Cloud Storage.

**A5.2** — *"Comprás el rendimiento que la base de datos necesita sin comprar la capacidad que no necesita."* Bajo el modelo de Persistent Disk, las IOPS escalan con el tamaño aprovisionado, así que llegar a 60.000 IOPS te obliga a aprovisionar terabytes de disco para un dataset de 200 GB — pagás capacidad puramente como medio para comprar rendimiento. Hyperdisk te permite aprovisionar 200 GB de capacidad y 60.000 IOPS como dimensiones independientes y facturadas por separado. El encuadre de negocio: elimina un impuesto estructural de sobreaprovisionamiento sobre exactamente las cargas más sensibles al rendimiento y menos hambrientas de capacidad — las bases de datos transaccionales.

**A5.3** — Local SSD es para **datos efímeros, críticos en latencia y reconstruibles**: espacio de scratch, archivos temporales, espacio de shuffle/spill para motores analíticos, y cachés. Está físicamente conectado al host, así que entrega la latencia más baja y las IOPS más altas disponibles, y no sobrevive a la detención de la instancia, la migración de host ni la terminación. Lo que su existencia te dice: el almacenamiento de Compute Engine está pensado para **componerse por requisito de durabilidad, no para elegirse una sola vez**. Una VM bien construida usa comúnmente un volumen de arranque en Persistent Disk o Hyperdisk (durable, sobrevive a la instancia), Hyperdisk para el dataset (durable, rendimiento aprovisionado) y Local SSD para scratch (rápido, descartable). Poner datos durables en Local SSD para "hacerlos rápidos" es el fallo clásico; el movimiento correcto es ubicar cada dataset en el nivel que corresponde a *qué tan grave es perderlo*.

**A5.4** — Lo que se rompe: **las semánticas POSIX**. Cloud Storage es un almacén de objetos con un espacio de nombres plano, sin directorios reales, sin bloqueo de archivos, sin escrituras parciales en el lugar, y sin `open()`/`seek()`/`write()` — los objetos se reemplazan atómicamente enteros. Las aplicaciones que esperan un sistema de archivos montado (aplicaciones heredadas, directorios home compartidos, edición de medios, muchos pipelines de renderizado y HPC, cualquier cosa que use file locks) o fallan o rinden catastróficamente. Existen adaptadores basados en FUSE, pero no restauran el bloqueo ni las semánticas de escritura POSIX, y agregan latencia. El criterio de decisión correcto: **elegí por el protocolo de acceso y las semánticas de consistencia que la aplicación requiere, no por el precio por GB.** Si la aplicación necesita un sistema de archivos, Filestore (o NetApp Volumes para funcionalidades empresariales) es la respuesta y el sobreprecio por GB es el precio del protocolo. Si la aplicación se puede modificar para hablar APIs de objetos, la refactorización suele valer la pena — pero esa es una decisión de *refactorización*, no de sustitución de almacenamiento.

### Ejercicio 6

**A6.1** — Cold-potato routing significa que Google lleva el tráfico por **su propio backbone tanto como sea posible**, entregándolo a la internet pública en la ubicación de borde más cercana al *usuario*. El hot-potato routing (Standard Tier, y típico de las redes que minimizan costo de tránsito) hace lo contrario: descarga el tráfico en la internet pública en el borde más cercano al *origen*, dejando que la red de otro lo lleve el resto del camino. Es una decisión de producto porque Google elige gastar su propia capacidad de backbone — un costo real — para controlar latencia, jitter y pérdida de paquetes de punta a punta, y tarifa Premium Tier en consecuencia. El lado del cliente en el trade: el precio por GB más alto de Premium es el costo de que el rendimiento siga siendo una propiedad de ingeniería en lugar de una propiedad del clima de internet.

**A6.2** — La restricción es que **Standard Tier no puede usar IPs externas globales ni balanceo de carga global** — es solo regional. Con una región y jugadores en 30 países, Standard Tier significa que el tráfico de cada jugador sale en la región de origen y cruza la internet pública todo el camino, y no podés presentar una única IP anycast servida desde el borde más cercano. Para un juego sensible a la latencia eso es una regresión directa de calidad de producto, y un 23% menos de egress no va a compensar el churn. Standard Tier pasa a ser correcto cuando la arquitectura **ya es regional y los usuarios son locales a esa región** — por ejemplo, un servicio solo doméstico, una carga interna o batch, un pipeline de exportación de datos a un endpoint conocido, o un entorno de dev/test. La regla práctica: Standard Tier es correcto cuando de todos modos nunca ibas a usar el borde global.

**A6.3** — *Rendimiento:* 400 TB/mes son ~1,2 Gbps de promedio sostenido, con picos mucho más altos durante las ventanas batch del ERP. Los túneles HA VPN topean alrededor de 3 Gbps cada uno y corren sobre la internet pública, así que el throughput está limitado y — más importante — **el jitter y la pérdida de paquetes quedan fuera de tu control**, que es exactamente lo que destruye las transferencias sostenidas grandes. Dedicated Interconnect provee circuitos de 10 o 100 Gbps sobre un camino privado con un perfil determinista. *Financiera:* el egress sobre Interconnect se factura a una **tarifa por GB sustancialmente menor que el egress a internet**, así que a 400 TB/mes el ahorro solo en transferencia de datos típicamente eclipsa el cargo fijo de puerto del circuito. La forma general: la VPN es barata para empezar y cara a volumen; Interconnect tiene un piso fijo y una tarifa marginal mucho menor, y el punto de cruce llega muy por debajo de 400 TB.

**A6.4** — Cuando necesitás cualquiera de estas cosas: **preservación de la IP del cliente** (el passthrough LB no termina la conexión, así que los backends ven la dirección de origen real — requerido para listas de permitidos por IP, geolocalización, registro de auditoría y algunos licenciamientos), **protocolos no HTTP** incluyendo UDP y protocolos IP arbitrarios, **latencia muy baja** (sin salto de proxy, sin terminación de conexión), o que **actúe como siguiente salto / gateway por defecto** para inserción de network virtual appliances y ruteo personalizado. El Application LB tiene más funcionalidades precisamente *porque* termina y re-origina conexiones — y esa terminación es justo lo que estás tratando de evitar. Más funcionalidades no es más adecuado; el conjunto de funcionalidades que querés acá es el conjunto vacío más fidelidad de cable.

### Ejercicio 7

**A7.1** — Orden: **(1) GCVE, (2) rehost a Compute Engine, (3) refactorizar a GKE.** GCVE gana en time-to-value: las VMs se mueven como VMs a un entorno vSphere que el equipo existente ya opera, usando HCX para la migración masiva, así que la salida del datacenter es un *proyecto de migración* en lugar de 1.400 proyectos individuales de aplicación. El rehost a Compute Engine va segundo — técnicamente viable y más barato por unidad, pero cada VM requiere trabajo de drivers en el SO invitado, re-direccionamiento IP y validación por aplicación, y el tercio del parque sin código fuente es exactamente donde esa validación es más riesgosa. Refactorizar va último y, con 11 meses para 1.400 VMs, no es un plan: no podés refactorizar aplicaciones cuyo código no tenés. El argumento de time-to-value en lenguaje de negocio: *el plazo es fijo y externo (el contrato de alquiler), así que la estrategia correcta es la que desacopla "salir del datacenter" de "modernizar las aplicaciones" — GCVE hace eso completamente, y la modernización procede después aplicación por aplicación, financiada por su propio caso de negocio, sin ningún plazo atado.*

**A7.2** — La variante air-gapped **pierde la conexión al plano de control de Google Cloud** — y por lo tanto pierde la gestión del lado de la nube, la telemetría que fluye hacia Google, las actualizaciones automáticas entregadas por red, y el acceso al catálogo de servicios de Google Cloud. Todo debe operarse, actualizarse y monitorearse localmente, con las actualizaciones entregadas mediante un proceso físico o controlado. Clientes que aceptan esto deliberadamente: defensa e inteligencia, cargas gubernamentales clasificadas, cierta infraestructura crítica nacional, y jurisdicciones cuya ley prohíbe que *cualquier* dato o metadato salga del control nacional — incluida la telemetría operativa, que es el detalle que descarta la variante connected para ellos. No eligen air-gapped porque desconfíen de la nube; la eligen porque la regulación está escrita sobre la conectividad misma.

**A7.3** — **Google Distributed Cloud (connected), en el borde.** Las dos palabras decisivas son **"sub-10ms"** y **"durante una caída de la WAN"**. Sub-10ms hasta una región es físicamente imposible para la mayoría de las ubicaciones de planta — la velocidad de la luz más los saltos de red fijan un piso — así que el cómputo debe estar en la planta. "Durante una caída de la WAN" significa que la inferencia debe seguir corriendo sin enlace a Google Cloud, lo que excluye cualquier arquitectura donde el plano de control o la ruta de servicio del modelo cruce la WAN. GDC connected da ejecución local con un ciclo de vida gestionado desde la nube cuando el enlace está arriba. Notá que cualquiera de los dos requisitos por separado habría bastado; juntos no dejan alternativa.

**A7.4** — Porque **la previsibilidad a menudo le gana a la optimalidad en un ciclo presupuestario**. Un modelo por nodo/hora con un tamaño mínimo de cluster produce una tasa de gasto que el CFO puede pronosticar al dólar con doce meses de anticipación, poner en un plan y comparar contra el costo del datacenter que reemplaza. La facturación por segundo es más barata en agregado pero produce una cifra mensual variable que se mueve con el comportamiento de ingeniería, lo que convierte la varianza en una conversación permanente. Hay una segunda razón, más sutil: un cluster de capacidad fija **acota el riesgo a la baja** — ningún ingeniero puede multiplicar accidentalmente la factura por 10 de un día para el otro. La mayor fortaleza de la facturación elástica y su mayor debilidad de gobernanza son la misma propiedad. Las organizaciones maduras lo reconcilian con presupuestos, cuotas y compromisos; las organizaciones que están empezando su camino en la nube a menudo prefieren el modelo que no las puede sorprender.

### Ejercicio 8

**A8.1** — `max_unavailable_fixed = 0` significa que el MIG nunca puede bajar de su tamaño objetivo durante una actualización; `max_surge_fixed = 3` significa que puede crear temporalmente hasta tres instancias *extra*. Juntos codifican **capacidad completa durante toda la actualización progresiva**: las instancias nuevas se crean y pasan los health checks *antes* de que se eliminen las viejas, así que en ningún momento se reduce la capacidad de servicio. Si pusieras `max_surge_fixed = 0`, el MIG no tendría margen para agregar instancias primero, así que con `max_unavailable = 0` no podría avanzar en absoluto — y en la configuración donde además permitís indisponibilidad, tendría que **borrar antes de crear**, ejecutando la actualización con capacidad reducida. Durante un pico de tráfico eso es una interrupción parcial autoinfligida. El costo de la configuración segura son las tres horas-instancia extra por actualización; el costo de la insegura se mide en el informe del incidente.

**A8.2** — (1) **Una dependencia zonal por debajo de una capa de cómputo regional** — el caso clásico es una base de datos zonal, un Persistent Disk zonal, una instancia de Filestore zonal, o un montaje NFS de una sola zona del que dependen las VMs de las tres zonas. El cómputo es regional; la disponibilidad sigue siendo zonal, porque el componente más débil fija el piso. (2) **Sin auto-healing dirigido por health checks, o un health check que solo prueba la vitalidad de la VM en lugar de la de la aplicación.** Una VM que está `RUNNING` pero devolviendo 500s se cuenta como sana, nunca se reemplaza, y sigue recibiendo tráfico — tenés tres zonas de instancias y ningún mecanismo que note que un tercio está roto. Una tercera común que vale la pena nombrar: **margen de capacidad insuficiente** — correr exactamente al límite de capacidad en tres zonas significa que perder una zona te deja al 67% y el servicio se degrada aunque nada haya "fallado".

**A8.3** — *A favor:* colapsa dos proyectos riesgosos en uno, cumple el plazo del datacenter, detiene inmediatamente el gasto en renovación de hardware, y mueve el parque a una plataforma donde la modernización puede después ocurrir de forma incremental y financiarse por aplicación. Rehostear es la única estrategia cuyo cronograma podés predecir de verdad. *En contra:* rehostear realiza el menor beneficio de nube — estás corriendo la misma arquitectura con las mismas ineficiencias a precios de nube, lo que para algunas cargas es *más* caro de lo que era el datacenter, y "modernizamos después" es una promesa que compite con cada pedido de funcionalidad a partir de ese momento. Las organizaciones que rehostean sin un seguimiento financiado terminan con un datacenter más caro y nada de la agilidad. *La condición decisiva:* **¿hay una función forzante externa y con fecha?** Si el alquiler vence, el hardware está fuera de soporte, o el datacenter cierra, rehosteá — el plazo domina y optimizás después. Si no hay plazo, la migración es discrecional y deberías replataformar o refactorizar las cargas donde el caso de negocio sea más fuerte, y retirar o retener el resto.

**A8.4** — Porque los créditos de servicio **no compensan la pérdida del negocio**. Un incumplimiento de 99.9% gana un crédito porcentual contra la factura de Compute Engine de ese mes — una cifra denominada en tu gasto de infraestructura, que típicamente es una fracción pequeña del ingreso que costó la caída. En el ejemplo trabajado, 8,76 horas de caída anual representan $2,1M de ingreso en riesgo, mientras que el crédito de SLA contra una factura de cómputo de ~$28k/mes son como mucho unos pocos miles de dólares. Tratar el crédito del SLA como el valor de la disponibilidad lo subestima, entonces, en dos o tres órdenes de magnitud. El método honesto es ponerle precio a la disponibilidad desde **el impacto de negocio de la caída**, y tratar el SLA como una *especificación de lo que la plataforma se compromete a dar* — la entrada a tu decisión de arquitectura — en lugar de como un seguro. Esta es también la razón por la que la arquitectura multizona se justifica por protección de ingresos, no por créditos de SLA.

**A8.5** — Existe para prevenir **migrar una carga de trabajo sin sus dependencias** — mover un servidor de aplicación dejando atrás una base de datos, un servidor de licencias, un file share, una dependencia de LDAP/AD, una IP hardcodeada, o un trabajo batch que le escribe todas las noches. El modo de fallo es característico: la migración tiene éxito, las pruebas de humo pasan, y la aplicación se rompe días después en el cierre de mes o cuando un sistema aguas arriba no descubierto intenta llegar a la vieja dirección. El mapeo de dependencias basado en descubrimiento convierte las olas de migración de "qué VMs son fáciles" a "qué VMs forman una unidad completa y movible", que es la diferencia entre una ola que corta limpio y una que requiere un rollback.

### Ejercicio 9

**A9.1** — La objeción es **parcialmente correcta, y la distinción importa**. Un CUD a 3 años es una obligación contractual de gasto, así que desde el punto de vista del compromiso de caja sí se parece a un compromiso de capital: debés el dinero uses o no la capacidad. Lo que *no* es, es gasto de capital en el sentido contable — no hay un activo que se deprecie en el balance, no hay valor residual que gestionar, no hay disposición, y (según el tratamiento contable que aplique tu controller) generalmente se reconoce como gasto operativo a lo largo del plazo. Las diferencias genuinas que sobreviven a la objeción: el compromiso es **parcial** (comprometés la base, no todo el parque), está **denominado en gasto y no en hardware**, así que no te ata a una máquina específica, y no acarrea **riesgo tecnológico** — un dólar comprometido puede comprar la familia de máquinas del año que viene, mientras que un servidor comprado no puede convertirse en un servidor más nuevo. La respuesta honesta y precisa al CFO: *"Tenés razón en que es un compromiso. No es un activo de capital, cubre solo nuestro piso de estado estable y, a diferencia del hardware, no se vuelve obsoleto."*

**A9.2** — El contraargumento: **"optionality" es la palabra que usa la gente cuando no decidió nada.** Toda presentación de migración promete modernización incremental, y la mayoría de los parques rehostean y se quedan ahí; la *capacidad* de la plataforma de correr contenedores y serverless no crea valor alguno salvo que alguien financie el trabajo, y mientras tanto cargás con el costo de la arquitectura rehosteada más cara. La respuesta honesta es convertir la optionality en compromisos: nombrá las primeras dos o tres cargas a modernizar, atá a cada una un caso de negocio y una fecha, asigná un responsable, y poné el presupuesto de modernización en el mismo plan que el presupuesto de migración. La optionality que no se ejerce es solo una funcionalidad sin usar — la afirmación defendible no es "podríamos modernizar", es "vamos a modernizar estas cargas, en este cronograma, por este retorno, y la plataforma es la razón por la que podemos".

**A9.3** — **La línea 1 (CAPEX elimination) es la más débil por sí sola.** Evitar una renovación de hardware es un beneficio de timing por única vez, y el costo simplemente reaparece como gasto operativo — a menudo con un costo total similar o mayor para un parque rehosteado. No dice nada sobre si el negocio funciona mejor después. Las líneas más fuertes son la 2 y la 4, porque son recurrentes y medibles: una reducción del 48,5% en la tasa de gasto se compone todos los meses, y $1,89M/año de riesgo de ingresos eliminado es un número que el negocio ya entiende. Aun así, las propuestas de infraestructura arrancan con la línea 1 porque es el **número más fácil de acordar** — la cotización de renovación de hardware es una factura real con una fecha real, no requiere supuestos de modelado, y mapea a una línea presupuestaria que el equipo de finanzas ya sigue. Es una buena apertura y un mal caso. La versión disciplinada de esta lámina abre con CAPEX para establecer el disparador, y después dedica el resto de su tiempo a la tasa de gasto y a la disponibilidad, que es donde está el valor duradero de verdad.

</details>

---

### Fuentes consolidadas

- Guía del examen Cloud Digital Leader — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Geografía y regiones — <https://cloud.google.com/docs/geography-and-regions>
- Regiones y zonas (Compute Engine) — <https://cloud.google.com/compute/docs/regions-zones>
- Guía de recursos de familias de máquinas — <https://cloud.google.com/compute/docs/machine-resource>
- Live migration — <https://cloud.google.com/compute/docs/instances/live-migration-process>
- Sole-tenant nodes — <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes>
- Sustained use discounts — <https://cloud.google.com/compute/docs/sustained-use-discounts>
- Committed use discounts — <https://cloud.google.com/docs/cuds>
- Spot VMs — <https://cloud.google.com/compute/docs/instances/spot>
- Cloud Billing Catalog API — <https://cloud.google.com/billing/docs/how-to/catalog-api>
- Clases de almacenamiento — <https://cloud.google.com/storage/docs/storage-classes>
- Gestión del ciclo de vida de objetos — <https://cloud.google.com/storage/docs/lifecycle>
- Opciones de almacenamiento en bloque — <https://cloud.google.com/compute/docs/disks>
- Tiers de servicio de Filestore — <https://cloud.google.com/filestore/docs/service-tiers>
- Network service tiers — <https://cloud.google.com/network-tiers/docs/overview>
- Panorama de Cloud Load Balancing — <https://cloud.google.com/load-balancing/docs/load-balancing-overview>
- Cloud Interconnect — <https://cloud.google.com/network-connectivity/docs/interconnect>
- Cloud VPN — <https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview>
- Cloud Run — <https://cloud.google.com/run/docs/overview/what-is-cloud-run>
- GKE Autopilot — <https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview>
- Google Cloud VMware Engine — <https://cloud.google.com/vmware-engine/docs/overview>
- Google Distributed Cloud — <https://cloud.google.com/distributed-cloud/docs>
- Oracle Database@Google Cloud — <https://cloud.google.com/oracle/database/docs>
- Migration Center — <https://cloud.google.com/migration-center/docs/migration-center-overview>
- Migrate to Virtual Machines — <https://cloud.google.com/migrate/virtual-machines/docs>
- SLA de Compute Engine — <https://cloud.google.com/compute/sla>
- SLA de Cloud Storage — <https://cloud.google.com/storage/sla>
- Well-Architected Framework, confiabilidad — <https://cloud.google.com/architecture/framework/reliability>
- Energía libre de carbono por región — <https://cloud.google.com/sustainability/region-carbon>
- Reporte de Carbon Footprint — <https://cloud.google.com/carbon-footprint/docs>