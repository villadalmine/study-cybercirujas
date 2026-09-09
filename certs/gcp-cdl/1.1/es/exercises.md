# Ejercicios guiados — Tema 1.1
## Explicar por qué y cómo la nube está revolucionando los negocios
**Certificación:** Google Cloud Digital Leader (guía del examen versión 2026-08-12) · **Peso en el examen:** 9.0

---

## Para qué sirve este conjunto de ejercicios

El examen Cloud Digital Leader hace preguntas *de negocio*, pero te evalúa según si entendés la *mecánica* que hay debajo. "La nube convierte CapEx en OpEx" es un eslogan hasta que consultaste un precio en la Cloud Billing Catalog API, construiste un modelo de costo por vCPU-hora entregada, viste un servicio escalar a cero y encontraste el punto donde la respuesta on-premises realmente gana.

Estos ejercicios son ejecutables. Vas a correr comandos `gcloud` reales contra un proyecto real y a leer números reales. Cada vez que aparece un número en una salida esperada, tratalo como **representativo**: los precios de lista, la cantidad de regiones y las cifras de carbono cambian, y leer el valor en vivo *es el ejercicio*.

**Referencia principal:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## Requisitos previos y control de costos

Antes de empezar:

1. Un proyecto de Google Cloud con una cuenta de facturación asociada (sirve una cuenta de prueba gratuita).
2. CLI de `gcloud` ≥ 460.0.0 instalada y autenticada, más `jq`, `curl`, `python3` y `bq`.
3. Roles sobre el proyecto: `roles/owner` o la combinación `roles/billing.viewer` + `roles/run.admin` + `roles/compute.admin` + `roles/monitoring.viewer`.

> **Advertencia de costos.** Los ejercicios 3, 4 y 6 crean recursos facturables. Todo lo que hay acá está diseñado para caber dentro del [Google Cloud Free Tier](https://cloud.google.com/free/docs/free-cloud-features) (Cloud Run: 2M de solicitudes, 180.000 vCPU-segundos, 360.000 GiB-segundos/mes; Compute Engine: una `e2-micro` en `us-west1`, `us-central1` o `us-east1`). Esperá bastante menos de **US$1** si completás el desmontaje del Ejercicio 10 el mismo día. El Ejercicio 9 marca deliberadamente el Global External Application Load Balancer como **solo en papel**, porque una regla de reenvío se factura por hora fluya o no fluya tráfico.

Definí tus variables de trabajo una sola vez:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export BILLING_ACCOUNT="$(gcloud billing accounts list \
  --filter='open=true' --format='value(name)' --limit=1 | sed 's|billingAccounts/||')"

echo "project=$PROJECT_ID region=$REGION billing=$BILLING_ACCOUNT"
```

Salida representativa:

```
project=cdl-lab-471203 region=us-central1 billing=01A2B3-C4D5E6-F7G8H9
```

Si `BILLING_ACCOUNT` queda vacío, no tenés ninguna cuenta de facturación que puedas leer: detenete y resolvé eso primero, porque seis de los diez ejercicios dependen de ella.

---

## Ejercicio 1 — La unidad de costo: convertir una compra de hardware en una consulta de precio

La diferencia mecánica más importante entre los dos modelos es la *granularidad*. On-premises, lo más chico que podés comprar es un servidor, y lo comprás una vez, para años. En la nube, lo más chico que podés comprar es un **SKU × unidad de consumo**, y el precio es una API pública.

### Pasos

1. Habilitá la Cloud Billing Catalog API:

    ```bash
    gcloud services enable cloudbilling.googleapis.com --project="$PROJECT_ID"
    ```

2. Listá los servicios facturables. Cada producto de Google Cloud tiene un ID de servicio estable:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
    | jq -r '.services[] | [.serviceId, .displayName] | @tsv' \
    | sort -k2 | head -20
    ```

    Salida representativa:

    ```
    2062-016F-44A2	AI Platform
    5AD9-C69C-B617	Access Approval
    6F81-5844-456A	Compute Engine
    9662-B51E-5089	Cloud Storage
    152E-C115-5142	Cloud Run
    ...
    ```

    Fijate en `6F81-5844-456A` — Compute Engine. Ese ID es una constante; lo vas a reutilizar.

3. Obtené el precio bajo demanda de una vCPU-hora N2 y de una GiB-hora N2 en las Américas:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=5000" \
    | jq -r '
        .skus[]
        | select(.category.usageType == "OnDemand")
        | select(.description | test("^N2 Instance (Core|Ram) running in Americas$"))
        | [ .description,
            .pricingInfo[0].pricingExpression.usageUnitDescription,
            ( (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.units | tonumber)
              + (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos / 1e9) )
          ] | @tsv'
    ```

    Salida representativa:

    ```
    N2 Instance Core running in Americas	hour	0.031611
    N2 Instance Ram running in Americas	gibibyte hour	0.004237
    ```

4. Calculá el precio de lista de una `n2-standard-8` (8 vCPU, 32 GiB) por una hora, y por un año funcionando de forma continua:

    ```bash
    python3 - <<'PY'
    vcpu_h, gib_h = 0.031611, 0.004237      # <-- replace with YOUR values from step 3
    hourly = 8 * vcpu_h + 32 * gib_h
    print(f"n2-standard-8  hourly = ${hourly:.6f}")
    print(f"n2-standard-8  1 year = ${hourly * 8760:,.2f}")
    print(f"n2-standard-8  1 hour of a 4-hour daily peak, for a year = ${hourly * 4 * 365:,.2f}")
    PY
    ```

    Salida representativa:

    ```
    n2-standard-8  hourly = $0.388472
    n2-standard-8  1 year = $3,402.02
    n2-standard-8  1 hour of a 4-hour daily peak, for a year = $567.17
    ```

5. Ahora buscá la *misma* capacidad como Spot VM, que es el mismo hardware con un contrato de interrupción adosado:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=5000" \
    | jq -r '
        .skus[]
        | select(.category.usageType == "Preemptible")
        | select(.description | test("^Spot Preemptible N2 Instance (Core|Ram) running in Americas$"))
        | [ .description,
            ( (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.units | tonumber)
              + (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos / 1e9) )
          ] | @tsv'
    ```

    Salida representativa:

    ```
    Spot Preemptible N2 Instance Core running in Americas	0.007533
    Spot Preemptible N2 Instance Ram running in Americas	0.001010
    ```

**Fuentes:** [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) · [Compute Engine pricing](https://cloud.google.com/compute/all-pricing) · [Spot VMs](https://cloud.google.com/compute/docs/instances/spot)

### Comprobá tu comprensión — Bloque 1

1. **Q1.1** — En el paso 4, la misma máquina cuesta $3.402 funcionando todo el año y $567 funcionando cuatro horas por día. Nada del hardware cambió. ¿Qué capacidad de negocio representa esa relación, y por qué es estructuralmente imposible obtenerla de un servidor comprado?
2. **Q1.2** — El precio Spot del paso 5 está aproximadamente un 76% por debajo del on-demand para hardware idéntico. ¿Por qué está pagando menos el cliente, exactamente? Nombrá una clase de carga de trabajo donde ese descuento sea dinero gratis y otra donde sea inutilizable.
3. **Q1.3** — Un CFO pregunta: "¿Por qué necesitamos una API para los precios? Los proveedores mandan cotizaciones." Dá la razón operativa por la que un catálogo de precios público y legible por máquina cambia cómo se toman las decisiones de arquitectura.
4. **Q1.4** — El SKU de vCPU y el SKU de RAM se facturan por separado y de forma independiente. ¿Qué libertad arquitectónica crea esa descomposición que un catálogo de servidores 1U fijos no ofrece?

---

## Ejercicio 2 — Construí el modelo de TCO y después encontrá dónde se da vuelta

La mayoría de las afirmaciones de "la nube es más barata" comparan las cantidades equivocadas: un costo on-premises *aprovisionado* contra un costo de nube *consumido*. La métrica honesta es el **costo por vCPU-hora entregada** — costo dividido por la capacidad que efectivamente hizo trabajo.

### Pasos

1. Creá el modelo. Guardalo como `tco.py`:

    ```python
    #!/usr/bin/env python3
    """Cost per DELIVERED vCPU-hour: on-premises vs Google Cloud.
    Every input is an assumption. Change them and re-run; that is the point."""

    # ---------- workload ----------
    SERVERS         = 24
    VCPU_PER_SERVER = 32
    GIB_PER_VCPU    = 4

    # ---------- on-premises assumptions ----------
    SERVER_CAPEX     = 9_500      # USD per server
    REFRESH_YEARS    = 4
    ARRAY_CAPEX      = 180_000    # storage + top-of-rack + core switching
    ARRAY_YEARS      = 5
    RACKS            = 3
    COLO_PER_RACK_MO = 1_200
    KW_DRAWN         = 6.0        # average IT load
    PUE              = 1.6
    KWH_PRICE        = 0.14
    OPS_FTE          = 1.5
    FTE_LOADED       = 130_000
    LICENSING_YR     = 28_000
    ONPREM_UTIL      = 0.22       # classic steady-state utilisation

    # ---------- cloud assumptions (replace with YOUR Exercise 1 values) ----------
    VCPU_HOUR   = 0.031611
    GIB_HOUR    = 0.004237
    CUD_3YR     = 0.55            # 3-year resource-based commitment discount
    CLOUD_UTIL  = 0.65            # achievable with autoscaling
    CLOUD_OPS_FTE = 0.75
    CLOUD_STORAGE_EGRESS_YR = 60_000

    # ---------- on-premises ----------
    onprem = {
        "hardware":  SERVERS * SERVER_CAPEX / REFRESH_YEARS,
        "array":     ARRAY_CAPEX / ARRAY_YEARS,
        "colo":      RACKS * COLO_PER_RACK_MO * 12,
        "power":     KW_DRAWN * PUE * 8760 * KWH_PRICE,
        "ops":       OPS_FTE * FTE_LOADED,
        "licensing": LICENSING_YR,
    }
    onprem_yr   = sum(onprem.values())
    provisioned = SERVERS * VCPU_PER_SERVER * 8760
    delivered   = provisioned * ONPREM_UTIL

    # ---------- cloud: same DELIVERED capacity ----------
    unit_ondemand = VCPU_HOUR + GIB_PER_VCPU * GIB_HOUR
    unit_cud      = unit_ondemand * (1 - CUD_3YR)
    cloud_provisioned = delivered / CLOUD_UTIL
    cloud = {
        "compute": cloud_provisioned * unit_cud,
        "ops":     CLOUD_OPS_FTE * FTE_LOADED,
        "storage_egress": CLOUD_STORAGE_EGRESS_YR,
    }
    cloud_yr = sum(cloud.values())

    def show(label, breakdown, total, prov):
        print(f"\n=== {label} ===")
        for k, v in breakdown.items():
            print(f"  {k:<16} ${v:>12,.0f}/yr")
        print(f"  {'TOTAL':<16} ${total:>12,.0f}/yr")
        print(f"  provisioned vCPU-h {prov:>14,.0f}")
        print(f"  delivered   vCPU-h {delivered:>14,.0f}")
        print(f"  $/provisioned vCPU-h  ${total/prov:.4f}")
        print(f"  $/DELIVERED   vCPU-h  ${total/delivered:.4f}")

    show("ON-PREMISES", onprem, onprem_yr, provisioned)
    show("GOOGLE CLOUD", cloud, cloud_yr, cloud_provisioned)
    print(f"\nDelta: ${onprem_yr - cloud_yr:,.0f}/yr "
          f"({100*(onprem_yr-cloud_yr)/onprem_yr:.1f}% lower)")
    ```

2. Ejecutalo:

    ```bash
    python3 tco.py
    ```

    Salida representativa:

    ```
    === ON-PREMISES ===
      hardware         $      57,000/yr
      array            $      36,000/yr
      colo             $      43,200/yr
      power            $      11,773/yr
      ops              $     195,000/yr
      licensing        $      28,000/yr
      TOTAL            $     370,973/yr
      provisioned vCPU-h      6,727,680
      delivered   vCPU-h      1,480,090
      $/provisioned vCPU-h  $0.0551
      $/DELIVERED   vCPU-h  $0.2506

    === GOOGLE CLOUD ===
      compute          $      49,754/yr
      ops              $      97,500/yr
      storage_egress   $      60,000/yr
      TOTAL            $     207,254/yr
      provisioned vCPU-h      2,277,062
      delivered   vCPU-h      1,480,090
      $/provisioned vCPU-h  $0.0910
      $/DELIVERED   vCPU-h  $0.1400

    Delta: $163,719/yr (44.1% lower)
    ```

3. **Leé la paradoja.** Por vCPU-hora *aprovisionada* la nube es un 65% **más cara** ($0.0910 vs $0.0551). Por vCPU-hora *entregada* es un 44% más barata. Confirmá que podés explicar eso antes de continuar.

4. **Rompé el modelo.** Volvé a ejecutarlo cuatro veces, cambiando una entrada por vez, y registrá el delta:

    ```bash
    sed -i 's/^ONPREM_UTIL.*/ONPREM_UTIL      = 0.70/'  tco.py && python3 tco.py | tail -2
    sed -i 's/^ONPREM_UTIL.*/ONPREM_UTIL      = 0.22/'  tco.py
    sed -i 's/^REFRESH_YEARS.*/REFRESH_YEARS    = 7/'   tco.py && python3 tco.py | tail -2
    sed -i 's/^REFRESH_YEARS.*/REFRESH_YEARS    = 4/'   tco.py
    sed -i 's/^OPS_FTE.*/OPS_FTE          = 0.5/'       tco.py && python3 tco.py | tail -2
    sed -i 's/^OPS_FTE.*/OPS_FTE          = 1.5/'       tco.py
    sed -i 's/^CUD_3YR.*/CUD_3YR     = 0.0/'            tco.py && python3 tco.py | tail -2
    sed -i 's/^CUD_3YR.*/CUD_3YR     = 0.55/'           tco.py
    ```

5. Verificá que el descuento que asumiste sea real. Los descuentos por uso comprometido están documentados, no se negocian:

    ```bash
    gcloud compute commitments list --project="$PROJECT_ID"   # empty in a lab project
    ```

    ```
    Listed 0 items.
    ```

    En cambio, leé las tarifas publicadas: los compromisos a 1 año llegan a alrededor del 37% y los de 3 años a alrededor del 55% para compromisos basados en recursos de propósito general. Los descuentos por uso sostenido (automáticos, sin compromiso) llegan a alrededor del 20–30% según la familia de máquina, y **no se acumulan** con los CUD.

**Fuentes:** [Committed use discounts](https://cloud.google.com/docs/cuds) · [Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts) · [Google Cloud pricing philosophy](https://cloud.google.com/pricing)

### Comprobá tu comprensión — Bloque 2

1. **Q2.1** — Explicá la paradoja del paso 3 en una sola oración que un CFO aceptaría: ¿cómo puede la nube ser simultáneamente más cara por unidad y más barata en total?
2. **Q2.2** — En el paso 4, ¿qué cambio de una sola entrada estuvo más cerca de borrar la ventaja de la nube? ¿Qué organización del mundo real describe esa entrada?
3. **Q2.3** — Un descuento por uso comprometido a 3 años fija el gasto por tres años. Argumentá que un CUD es un instrumento con forma de CapEx vendido bajo un contrato de OpEx. ¿Comprar uno hace perder el beneficio de la elasticidad? Sé preciso.
4. **Q2.4** — El modelo on-premises carga 1,5 FTE y el modelo de nube 0,75 FTE. Un líder de infraestructura escéptico dice que esto es el autor poniendo el pulgar en la balanza. ¿Qué trabajo concreto desaparece, y qué trabajo nuevo aparece, en la columna de la nube?
5. **Q2.5** — Nombrá dos categorías de costo que no aparecen en *ninguna* de las dos columnas y que sin embargo afectan materialmente una decisión real de migración.

---

## Ejercicio 3 — Elasticidad que podés observar: escalar a cero y volver

La elasticidad es la propiedad que hace posibles los números del Ejercicio 2. Acá vas a ver capacidad aparecer y desaparecer en segundos.

### Pasos

1. Habilitá y desplegá el contenedor de ejemplo de Google en Cloud Run:

    ```bash
    gcloud services enable run.googleapis.com --project="$PROJECT_ID"

    gcloud run deploy elasticity-demo \
      --image=us-docker.pkg.dev/cloudrun/container/hello \
      --region="$REGION" \
      --allow-unauthenticated \
      --min-instances=0 \
      --max-instances=20 \
      --cpu=1 --memory=512Mi \
      --project="$PROJECT_ID"
    ```

    Salida representativa:

    ```
    Deploying container to Cloud Run service [elasticity-demo] in project [cdl-lab-471203] region [us-central1]
    ✓ Deploying new service... Done.
      ✓ Creating Revision...
      ✓ Routing traffic...
      ✓ Setting IAM Policy...
    Done.
    Service [elasticity-demo] revision [elasticity-demo-00001-abc] has been deployed
    and is serving 100 percent of traffic.
    Service URL: https://elasticity-demo-a1b2c3d4e5-uc.a.run.app
    ```

2. Capturá la URL y confirmá que el servicio responde:

    ```bash
    export SVC_URL="$(gcloud run services describe elasticity-demo \
      --region="$REGION" --format='value(status.url)')"

    curl -s -o /dev/null -w "http=%{http_code} total=%{time_total}s\n" "$SVC_URL"
    ```

3. Medí el **arranque en frío** — el costo honesto del escalado a cero. Esperá a que el servicio quede inactivo y después pegale una vez:

    ```bash
    echo "waiting 15 minutes for the instance to be reclaimed..."; sleep 900
    curl -s -o /dev/null -w "COLD  total=%{time_total}s\n" "$SVC_URL"
    curl -s -o /dev/null -w "WARM  total=%{time_total}s\n" "$SVC_URL"
    ```

    Salida representativa:

    ```
    COLD  total=1.284051s
    WARM  total=0.061733s
    ```

4. Generá una ráfaga y mirá cómo se materializan las instancias. Cincuenta clientes concurrentes durante 30 segundos:

    ```bash
    seq 1 50 | xargs -P 50 -I{} sh -c \
      'end=$(( $(date +%s) + 30 )); while [ $(date +%s) -lt $end ]; do curl -s -o /dev/null '"$SVC_URL"'; done'
    ```

5. Leé la cantidad real de instancias desde Cloud Monitoring — no desde la consola, desde la API:

    ```bash
    gcloud services enable monitoring.googleapis.com --project="$PROJECT_ID"

    END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    START="$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -G "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries" \
      --data-urlencode 'filter=metric.type="run.googleapis.com/container/instance_count" AND resource.labels.service_name="elasticity-demo"' \
      --data-urlencode "interval.startTime=$START" \
      --data-urlencode "interval.endTime=$END" \
      --data-urlencode 'aggregation.alignmentPeriod=60s' \
      --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MAX' \
    | jq -r '.timeSeries[] | .metric.labels.state as $s
             | .points[] | [$s, .interval.endTime, .value.doubleValue] | @tsv' \
    | sort -k2
    ```

    Salida representativa:

    ```
    idle	2026-09-06T14:31:00Z	0
    active	2026-09-06T14:31:00Z	0
    active	2026-09-06T14:38:00Z	11
    idle	2026-09-06T14:38:00Z	2
    active	2026-09-06T14:39:00Z	0
    idle	2026-09-06T14:39:00Z	3
    active	2026-09-06T14:52:00Z	0
    idle	2026-09-06T14:52:00Z	0
    ```

6. Ahora comprá la eliminación del arranque en frío y leé el precio de esa decisión:

    ```bash
    gcloud run services update elasticity-demo \
      --region="$REGION" --min-instances=2 --project="$PROJECT_ID"

    gcloud run services describe elasticity-demo --region="$REGION" \
      --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
    ```

    ```
    2
    ```

7. Restablecelo, para que el desmontaje quede limpio y se preserve el free tier:

    ```bash
    gcloud run services update elasticity-demo --region="$REGION" --min-instances=0
    ```

**Fuentes:** [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling) · [Cloud Run pricing](https://cloud.google.com/run/pricing) · [Cloud Run metrics](https://cloud.google.com/monitoring/api/metrics_gcp#gcp-run)

### Comprobá tu comprensión — Bloque 3

1. **Q3.1** — En el paso 5 la cantidad de instancias pasó de 0 a 11 y volvió a 0 en unos ~15 minutos. Reformulalo como una afirmación de *compras*: ¿cuál habría sido la transacción on-premises equivalente, y cuánto habría tardado?
2. **Q3.2** — El paso 3 muestra una solicitud en frío que tarda ~20× más que una en caliente. Poner `--min-instances=2` la elimina. Describí el compromiso en los términos exactos que usa el examen, y decí qué parte interesada es dueña de la decisión.
3. **Q3.3** — `--max-instances=20` se definió explícitamente. En una plataforma elástica, ¿por qué alguien pondría un techo? Dá la razón de costo y la razón de corrección.
4. **Q3.4** — La métrica está dividida en estados `active` e `idle`. ¿Por qué el modelo de facturación por solicitudes, que es el predeterminado de Cloud Run, vuelve esa distinción financieramente significativa, y qué cambia con la facturación basada en instancias?
5. **Q3.5** — Un equipo argumenta que la elasticidad es irrelevante porque su tráfico es perfectamente plano 24/7. Dá dos maneras en que la elasticidad igual les entrega valor.

---

## Ejercicio 4 — Alcance global como un valor de configuración

"Entrar en un mercado nuevo" solía significar firmar el alquiler de un centro de datos. Acá es una bandera.

### Pasos

1. Contá la huella a la que podés llegar ahora mismo:

    ```bash
    gcloud compute regions list --format='value(name)' | wc -l
    gcloud compute zones list --format='value(name)' | wc -l
    gcloud compute regions list --format='table(name, description, status)' | head -12
    ```

    Salida representativa:

    ```
    43
    132
    NAME                     DESCRIPTION                          STATUS
    africa-south1            Johannesburg, South Africa           UP
    asia-east1               Changhua County, Taiwan              UP
    asia-northeast1          Tokyo, Japan                         UP
    australia-southeast1     Sydney, Australia                    UP
    europe-west1             St. Ghislain, Belgium                UP
    ...
    ```

    Registrá *tus* dos números: son más altos que los impresos acá.

2. Desplegá el servicio idéntico en tres continentes. Este es todo el ejercicio de entrada a mercado:

    ```bash
    for R in us-central1 europe-west1 asia-northeast1; do
      gcloud run deploy reach-demo \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --region="$R" --allow-unauthenticated --min-instances=0 \
        --project="$PROJECT_ID" --quiet
    done
    ```

3. Medí lo que sentirían tus usuarios desde donde estás sentado:

    ```bash
    for R in us-central1 europe-west1 asia-northeast1; do
      U="$(gcloud run services describe reach-demo --region="$R" --format='value(status.url)')"
      curl -s -o /dev/null "$U"    # warm it
      printf "%-18s " "$R"
      curl -s -o /dev/null -w "connect=%{time_connect}s  ttfb=%{time_starttransfer}s\n" "$U"
    done
    ```

    Salida representativa (medida desde Sudamérica):

    ```
    us-central1        connect=0.142s  ttfb=0.298s
    europe-west1       connect=0.231s  ttfb=0.462s
    asia-northeast1    connect=0.318s  ttfb=0.641s
    ```

4. Inspeccioná el producto de red que estás comprando implícitamente:

    ```bash
    gcloud compute project-info describe --project="$PROJECT_ID" \
      --format="value(defaultNetworkTier)"
    ```

    ```
    PREMIUM
    ```

    El Premium Tier transporta el tráfico por la red troncal privada de Google desde el punto de presencia más cercano al usuario; el Standard Tier lo entrega a la internet pública en la región. Eso es una elección de *precio y rendimiento* por proyecto y por recurso, no la construcción de un centro de datos.

5. Confirmá la dimensión de residencia. Las regiones no son intercambiables cuando hay leyes de por medio:

    ```bash
    gcloud compute regions list --filter='name~^europe' --format='value(name, description)'
    ```

    ```
    europe-central2   Warsaw, Poland
    europe-north1     Hamina, Finland
    europe-southwest1 Madrid, Spain
    europe-west1      St. Ghislain, Belgium
    europe-west3      Frankfurt, Germany
    europe-west4      Eemshaven, Netherlands
    europe-west9      Paris, France
    ...
    ```

**Fuentes:** [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Network Service Tiers](https://cloud.google.com/network-tiers/docs/overview)

### Comprobá tu comprensión — Bloque 4

1. **Q4.1** — El paso 2 puso un servicio apto para producción en tres continentes en menos de dos minutos con un costo fijo efectivamente nulo. Escribí la oración de caso de negocio que esto reemplaza, e identificá qué clase de empresa se beneficia *desproporcionadamente*.
2. **Q4.2** — Una zona y una región no son el mismo dominio de falla. Definí cada una, y decí contra qué protege un despliegue "multi-región" que uno "multi-zona" no protege.
3. **Q4.3** — El Standard Tier es más barato que el Premium Tier para los mismos bytes. Nombrá una carga de trabajo donde elegir Standard sea ingeniería correcta y no un recorte.
4. **Q4.4** — El paso 5 lista siete regiones europeas en siete países. Dá dos razones de negocio distintas —una regulatoria, otra comercial— para elegir `europe-west9` por sobre la más barata `europe-west4`.
5. **Q4.5** — La latencia del paso 3 correlaciona con la distancia física. ¿Qué te dice eso sobre los límites de "la nube está en todas partes"?

---

## Ejercicio 5 — Modelos de servicio: qué estás comprando realmente

IaaS / PaaS / SaaS es un ítem de vocabulario de la guía del examen, pero en realidad es una pregunta sobre *dónde está el límite de responsabilidad*. Ejecutá la misma carga de trabajo trivial de dos maneras y mirá el límite directamente.

### Pasos

1. **IaaS.** Creá una VM y anotá todo lo que ahora te pertenece:

    ```bash
    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"

    gcloud compute instances create iaas-demo \
      --zone="${REGION}-a" \
      --machine-type=e2-micro \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size=10GB \
      --project="$PROJECT_ID"
    ```

    Salida representativa:

    ```
    Created [.../zones/us-central1-a/instances/iaas-demo].
    NAME       ZONE           MACHINE_TYPE  INTERNAL_IP  EXTERNAL_IP    STATUS
    iaas-demo  us-central1-a  e2-micro      10.128.0.7   34.72.101.204  RUNNING
    ```

2. Enumerá la superficie que heredaste:

    ```bash
    gcloud compute ssh iaas-demo --zone="${REGION}-a" --command='
      echo "--- kernel ---";  uname -r
      echo "--- distro ---";  . /etc/os-release && echo "$PRETTY_NAME"
      echo "--- pending security updates ---"
      sudo apt-get -qq update >/dev/null 2>&1
      apt list --upgradable 2>/dev/null | grep -ci security || echo 0
      echo "--- listening sockets ---"; sudo ss -tlnp | tail -n +2 | wc -l
      echo "--- uptime you must manage ---"; uptime -p'
    ```

    Salida representativa:

    ```
    --- kernel ---
    6.1.0-23-cloud-amd64
    --- distro ---
    Debian GNU/Linux 12 (bookworm)
    --- pending security updates ---
    7
    --- listening sockets ---
    4
    --- uptime you must manage ---
    up 3 minutes
    ```

3. **PaaS / serverless.** Hacele las mismas preguntas al servicio de Cloud Run del Ejercicio 3:

    ```bash
    gcloud run services describe elasticity-demo --region="$REGION" --format=yaml \
      | grep -Ei 'kernel|osImage|patch|sshKey' || echo "no OS surface is exposed — there is nothing here to patch"
    ```

    ```
    no OS surface is exposed — there is nothing here to patch
    ```

4. Compará el contrato operativo cuantitativamente:

    ```bash
    echo "--- IaaS knobs you own ---"
    gcloud compute instances describe iaas-demo --zone="${REGION}-a" --format=json \
      | jq '[paths(scalars)] | length'

    echo "--- PaaS knobs you own ---"
    gcloud run services describe elasticity-demo --region="$REGION" --format=json \
      | jq '[paths(scalars)] | length'
    ```

    Salida representativa:

    ```
    --- IaaS knobs you own ---
    213
    --- PaaS knobs you own ---
    97
    ```

    El conteo es una aproximación, no una ley — pero la dirección es la lección.

5. **SaaS.** Venís usando uno todo el tiempo. `gcloud`, la Cloud Console y la Billing API son software operado por Google que consumís sin aprovisionar nada:

    ```bash
    gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)' | head
    ```

    ```
    bigquery.googleapis.com
    cloudbilling.googleapis.com
    compute.googleapis.com
    logging.googleapis.com
    monitoring.googleapis.com
    run.googleapis.com
    ```

    No instalaste, parcheaste, escalaste ni respaldaste ninguno de estos.

**Fuentes:** [What is IaaS](https://cloud.google.com/learn/what-is-iaas) · [What is PaaS](https://cloud.google.com/learn/what-is-paas) · [What is SaaS](https://cloud.google.com/learn/what-is-saas) · [Cloud Run overview](https://cloud.google.com/run/docs/overview/what-is-cloud-run)

### Comprobá tu comprensión — Bloque 5

1. **Q5.1** — El paso 2 encontró 7 actualizaciones de seguridad pendientes en una VM de tres minutos de antigüedad. El paso 3 no encontró ninguna superficie de SO. Reformulá esto como la definición del límite IaaS/PaaS, sin usar las palabras "IaaS" ni "PaaS".
2. **Q5.2** — Ordená IaaS, PaaS y SaaS por (a) control del cliente y (b) carga operativa del cliente. ¿Cuál es la relación entre los dos ordenamientos, y por qué eso es todo el intercambio?
3. **Q5.3** — Un equipo quiere operaciones de nivel PaaS pero tiene una aplicación licenciada que requiere un módulo de kernel específico. ¿Qué modelo deben usar, y cuál es el costo honesto de esa restricción?
4. **Q5.4** — Migrar una VM a Google Cloud sin cambios ("lift and shift") aterriza en IaaS. ¿Qué porción de los ahorros del Ejercicio 2 captura eso, y qué porción deja sobre la mesa?
5. **Q5.5** — Clasificá cada uno y justificá: Compute Engine, Google Kubernetes Engine Autopilot, Cloud Run, BigQuery, Google Workspace. ¿Cuál es el más difícil de clasificar limpiamente, y por qué eso es instructivo?

---

## Ejercicio 6 — Responsabilidad compartida, y el destino compartido de Google

Todo proveedor de nube publica un modelo de responsabilidad compartida. Google agrega el **destino compartido** (shared fate): en lugar de trazar la línea y hacerse a un lado, Google toma una participación activa en el lado del cliente.

### Pasos

1. Comprobá que el límite de seguridad es real encontrando dónde empieza *tu* obligación. La VM del Ejercicio 5 tiene una postura de firewall predeterminada — inspeccionala:

    ```bash
    gcloud compute firewall-rules list \
      --format='table(name, network, direction, sourceRanges.list(), allowed[].map().firewall_rule().list())'
    ```

    Salida representativa:

    ```
    NAME                    NETWORK  DIRECTION  SRC_RANGES     ALLOW
    default-allow-icmp      default  INGRESS    0.0.0.0/0      icmp
    default-allow-internal  default  INGRESS    10.128.0.0/9   tcp:0-65535,udp:0-65535,icmp
    default-allow-rdp       default  INGRESS    0.0.0.0/0      tcp:3389
    default-allow-ssh       default  INGRESS    0.0.0.0/0      tcp:22
    ```

    Google proporcionó la red. **Vos** sos dueño del hecho de que TCP/22 esté abierto a toda la internet.

2. Verificá quién es responsable del parcheo del SO — y confirmá que Google ofrece ayudar sin asumir la obligación:

    ```bash
    gcloud services enable osconfig.googleapis.com --project="$PROJECT_ID"
    gcloud compute os-config patch-deployments list --project="$PROJECT_ID"
    ```

    ```
    Listed 0 items.
    ```

    Cero. VM Manager existe, es gratuito y es *opcional*. Nada se parchea hasta que vos lo digas — ese es el límite en un solo comando.

3. Contrastá con el lado gestionado. Preguntá qué revisión de Cloud Run está corriendo y qué versión de cualquier cosa la sustenta:

    ```bash
    gcloud run revisions list --service=elasticity-demo --region="$REGION" \
      --format='table(name, active, creationTimestamp)'
    ```

    ```
    NAME                        ACTIVE  CREATION_TIMESTAMP
    elasticity-demo-00002-xyz   yes     2026-09-06T14:55:11Z
    elasticity-demo-00001-abc           2026-09-06T14:22:03Z
    ```

    No hay host, kernel ni versión de runtime que puedas consultar, porque no hay ninguno que vos debas parchear.

4. Inspeccioná el límite de identidad — la parte que *siempre* es tuya, sin importar el modelo de servicio:

    ```bash
    gcloud projects get-iam-policy "$PROJECT_ID" \
      --flatten='bindings[].members' \
      --format='table(bindings.role, bindings.members)' | head -15
    ```

    Salida representativa:

    ```
    ROLE                            MEMBERS
    roles/owner                     user:villadalmine@gmail.com
    roles/editor                    serviceAccount:471203-compute@developer.gserviceaccount.com
    roles/run.serviceAgent          serviceAccount:service-471203@serverless-robot-prod.iam.gserviceaccount.com
    ```

    Fijate en que la cuenta de servicio predeterminada de Compute Engine tiene `roles/editor`. Google la creó; vos sos dueño de la decisión de dejarla así.

5. Leé los mecanismos de destino compartido y verificá cuáles están disponibles para vos sin cargo:

    ```bash
    gcloud services list --available --filter='config.name~(securitycenter|assuredworkloads|recommender)' \
      --format='value(config.name)' 2>/dev/null
    ```

    ```
    assuredworkloads.googleapis.com
    recommender.googleapis.com
    securitycenter.googleapis.com
    ```

    `recommender.googleapis.com` alimenta IAM Recommender, que propone reducciones de roles hacia el mínimo privilegio a partir del uso observado — Google analizando *tu* lado del límite y entregándote la solución. Eso es destino compartido en la práctica.

**Fuentes:** [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [VM Manager](https://cloud.google.com/compute/docs/vm-manager) · [IAM Recommender](https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview)

### Comprobá tu comprensión — Bloque 6

1. **Q6.1** — En el paso 1, Google construyó una red con `default-allow-ssh` desde `0.0.0.0/0`. Si esa VM se ve comprometida a través de una credencial SSH débil, ¿de quién es la responsabilidad de la brecha bajo el modelo de responsabilidad compartida? Justificá desde el modelo, no desde la intuición.
2. **Q6.2** — El paso 2 muestra que el parcheo es opcional. Reformulá la regla general de cómo se mueve el límite de responsabilidad a medida que vas de IaaS → PaaS → SaaS. ¿Qué única responsabilidad nunca se mueve?
3. **Q6.3** — Distinguí responsabilidad *compartida* de destino *compartido* en una oración cada uno. Dá el ejemplo concreto del paso 5.
4. **Q6.4** — La cuenta de servicio predeterminada de Compute Engine tiene `roles/editor` (paso 4). ¿Por qué existe ese valor predeterminado, y qué te dice su existencia sobre el compromiso de diseño del proveedor entre fricción de adopción y valores predeterminados seguros?
5. **Q6.5** — Un ejecutivo dice "nos mudamos a la nube, así que la seguridad ahora es problema de Google". Corregilo en tres oraciones, y nombrá una cosa que genuinamente *sí* pasó a ser problema de Google.

---

## Ejercicio 7 — El circuito de retroalimentación de costos que el CapEx nunca tuvo

El costo de un servidor comprado se conoce una sola vez, en el momento de la compra. El costo de un recurso de nube se conoce continuamente — y eso cambia cómo se comportan las organizaciones.

### Pasos

1. Creá un conjunto de datos de BigQuery para recibir la exportación de facturación:

    ```bash
    gcloud services enable bigquery.googleapis.com --project="$PROJECT_ID"
    bq --location=US mk --dataset --description "Cloud Billing export" "${PROJECT_ID}:billing_export"
    bq ls --project_id="$PROJECT_ID"
    ```

    ```
      datasetId
     ---------------
      billing_export
    ```

2. **Habilitá la exportación.** Este paso no tiene equivalente en `gcloud`: la configuración de la exportación de Cloud Billing es solo por consola. Andá a **Billing → Billing export → BigQuery export → Standard usage cost → Edit settings**, seleccioná este proyecto y el conjunto de datos `billing_export`, y guardá.

    > Los datos empiezan a llegar en unas pocas horas y no son retroactivos. Anotá la hora; después vas a consultarlos.

3. Confirmá que la tabla aparece (volvé a ejecutar tras unas horas si está vacía):

    ```bash
    bq ls --format=prettyjson "${PROJECT_ID}:billing_export" | jq -r '.[].tableReference.tableId'
    ```

    ```
    gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9
    ```

4. Hacé la pregunta que ningún sistema financiero on-premises puede responder — costo por servicio, por día:

    ```bash
    bq query --use_legacy_sql=false --format=pretty "
    SELECT
      service.description         AS service,
      DATE(usage_start_time)      AS day,
      ROUND(SUM(cost), 4)         AS cost_usd,
      ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 4) AS credits_usd
    FROM \`${PROJECT_ID}.billing_export.gcp_billing_export_v1_$(echo "$BILLING_ACCOUNT" | tr '-' '_')\`
    GROUP BY service, day
    ORDER BY day DESC, cost_usd DESC
    LIMIT 20"
    ```

    Salida representativa:

    ```
    +--------------------+------------+----------+-------------+
    |      service       |    day     | cost_usd | credits_usd |
    +--------------------+------------+----------+-------------+
    | Compute Engine     | 2026-09-06 |   0.0731 |     -0.0731 |
    | Cloud Run          | 2026-09-06 |   0.0042 |     -0.0042 |
    | Networking         | 2026-09-06 |   0.0011 |      0.0    |
    +--------------------+------------+----------+-------------+
    ```

    La columna `credits_usd` es el free tier cancelando el cargo — el mecanismo, hecho visible.

5. Cerrá el circuito con un control automatizado:

    ```bash
    gcloud services enable billingbudgets.googleapis.com --project="$PROJECT_ID"

    gcloud billing budgets create \
      --billing-account="$BILLING_ACCOUNT" \
      --display-name="cdl-lab-guardrail" \
      --budget-amount=10USD \
      --threshold-rule=percent=0.5 \
      --threshold-rule=percent=0.9 \
      --threshold-rule=percent=1.0 \
      --filter-projects="projects/$PROJECT_ID"
    ```

    Salida representativa:

    ```
    Created budget [billingAccounts/01A2B3-C4D5E6-F7G8H9/budgets/9f2c1e44-...]
    displayName: cdl-lab-guardrail
    amount:
      specifiedAmount:
        currencyCode: USD
        units: '10'
    thresholdRules:
    - thresholdPercent: 0.5
    - thresholdPercent: 0.9
    - thresholdPercent: 1.0
    ```

6. Verificá que exista y entendé qué hace — y qué no hace:

    ```bash
    gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
      --format='table(displayName, amount.specifiedAmount.units, thresholdRules.len())'
    ```

**Fuentes:** [Export billing data to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery) · [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets) · [Billing export schema](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/standard-usage)

### Comprobá tu comprensión — Bloque 7

1. **Q7.1** — El paso 4 produjo costo por servicio y por día a partir de una consulta SQL en vivo. Nombrá tres decisiones organizacionales que esto hace posibles y que los cronogramas de depreciación anual no.
2. **Q7.2** — Una alerta de presupuesto notifica; **no** detiene el gasto. ¿Por qué ese es el comportamiento predeterminado, y qué construirías para volverlo coercitivo?
3. **Q7.3** — La exportación de facturación no es retroactiva (paso 2). ¿Qué implica eso sobre la *primera* acción a tomar cuando una organización nueva adopta Google Cloud?
4. **Q7.4** — Explicá cómo este ejercicio conecta con el Ejercicio 2. ¿Qué entrada del modelo pasa a ser *medida* en lugar de asumida una vez que existe la exportación de facturación?
5. **Q7.5** — El examen enmarca esto como "el gasto operativo habilita la agilidad". Usando los artefactos que construiste, explicá la cadena causal desde la *facturación granular* hasta las *decisiones de producto más rápidas*.

---

## Ejercicio 8 — La sostenibilidad como impulsor de negocio, no como eslogan

El reporte de carbono se volvió un requisito de compras en mercados regulados. También es un diferenciador genuino entre la nube y el on-premises, porque la eficiencia a hiperescala y la contratación de energía limpia no son reproducibles en un rack alquilado.

### Pasos

1. Obtené los datos de carbono por región publicados por Google — una fuente oficial, legible por máquina y gratuita:

    ```bash
    curl -sL https://raw.githubusercontent.com/GoogleCloudPlatform/region-carbon-info/main/data/yearly/2023.csv \
      | column -t -s,
    ```

    Salida representativa (abreviada):

    ```
    Region             CFE%   Grid carbon intensity (gCO2eq/kWh)
    europe-north1      0.91   127
    europe-west1       0.85   110
    us-central1        0.64   394
    asia-northeast1    0.28   468
    australia-southeast1 0.24  600
    ```

2. Ordená las regiones a las que realmente podrías desplegar, por limpieza:

    ```bash
    curl -sL https://raw.githubusercontent.com/GoogleCloudPlatform/region-carbon-info/main/data/yearly/2023.csv \
      | tail -n +2 | sort -t, -k2 -rn | head -8 \
      | awk -F, '{printf "%-24s CFE=%.0f%%  grid=%s gCO2eq/kWh\n", $1, $2*100, $3}'
    ```

3. Cuantificá una decisión de carga de trabajo. Tomá las 1.480.090 vCPU-horas entregadas del Ejercicio 2 y compará dos regiones:

    ```bash
    python3 - <<'PY'
    DELIVERED_VCPU_H = 1_480_090
    WATTS_PER_VCPU   = 6.0          # rough, for illustration only
    kwh = DELIVERED_VCPU_H * WATTS_PER_VCPU / 1000

    for region, cfe, gco2 in [("europe-north1", 0.91, 127),
                              ("us-central1",   0.64, 394),
                              ("asia-northeast1",0.28, 468)]:
        tonnes = kwh * (1 - cfe) * gco2 / 1e6
        print(f"{region:<18} {kwh:>10,.0f} kWh  ->  {tonnes:>7.1f} tCO2e/yr")
    PY
    ```

    Salida representativa:

    ```
    europe-north1           8,881 kWh  ->      0.1 tCO2e/yr
    us-central1             8,881 kWh  ->      1.3 tCO2e/yr
    asia-northeast1         8,881 kWh  ->      3.0 tCO2e/yr
    ```

4. Verificá si el informe de huella de carbono de tu propia cuenta está disponible. Como la exportación de facturación, se habilita en la consola (**Billing → Carbon Footprint**) y se exporta a BigQuery:

    ```bash
    bq ls --format=prettyjson "${PROJECT_ID}:billing_export" 2>/dev/null \
      | jq -r '.[].tableReference.tableId' | grep -i carbon || echo "carbon export not configured"
    ```

5. Anotá las afirmaciones que deberías poder enunciar en el examen, y dónde están publicadas:
    - Google iguala el 100% de su consumo anual global de electricidad con compras de energía renovable desde 2017.
    - Google es neutral en carbono en sus operaciones desde 2007.
    - El objetivo declarado es operar con energía libre de carbono 24/7 en cada red eléctrica donde opera para 2030.
    - Los clientes de Google Cloud heredan estas propiedades al usar la plataforma; las emisiones de Alcance 2 que el cliente reporta para esa carga de trabajo se mueven en consecuencia.

**Fuentes:** [Carbon-free energy by region](https://cloud.google.com/sustainability/region-carbon) · [region-carbon-info dataset](https://github.com/GoogleCloudPlatform/region-carbon-info) · [Carbon Footprint](https://cloud.google.com/carbon-footprint) · [Google Sustainability](https://sustainability.google/operating-sustainably/)

### Comprobá tu comprensión — Bloque 8

1. **Q8.1** — El paso 3 muestra una diferencia de emisiones de 30×, para cómputo idéntico, decidida por una cadena de texto en un comando de despliegue. ¿Qué función organizacional debería ser dueña de esa cadena, y por qué normalmente la posee la equivocada?
2. **Q8.2** — Distinguí "neutral en carbono" de "energía libre de carbono 24/7". ¿Por qué lo segundo es dramáticamente más difícil, y por qué le importa a un cliente y no solo a Google?
3. **Q8.3** — La elección de región intercambia carbono contra latencia (Ejercicio 4) y precio (Ejercicio 1). Construí un caso donde la región *más limpia* sea la elección equivocada, y otro donde sea la correcta a pesar de ser más lenta.
4. **Q8.4** — Un centro de datos on-premises con PUE 1,6 (el supuesto del Ejercicio 2) frente a una instalación de hiperescala cerca de 1,1: expresá esa brecha como porcentaje de la energía total y explicá qué compra el cliente que no podría construir.
5. **Q8.5** — ¿Por qué una exportación de huella de carbono *legible por máquina* es un producto distinto de un PDF de informe de sostenibilidad?

---

## Ejercicio 9 — Síntesis: escribí el caso de negocio (ejercicio en papel)

Sin comandos. Este es el entregable que realmente se le pide a un Cloud Digital Leader, y el examen evalúa si podés producirlo.

### Escenario

**Meridian Freight** es una empresa regional de logística con 40 años de historia. 620 empleados. Dos salas de centro de datos alquiladas con ~180 servidores físicos, utilización promedio del 19%, renovación de hardware prevista en 11 meses con una cotización de **US$2,4M**. Su aplicación central de despacho es un monolito Java sobre Oracle. La carga pico es 5,5× la línea base durante las dos semanas de fiestas; el año pasado perdieron envíos porque no pudieron agregar capacidad. Un competidor financiado por capital de riesgo lanzó hace 14 meses con optimización de rutas en el día y les está quitando cuentas del mercado medio. El directorio pidió una recomendación antes de la compra de renovación.

### Pasos

1. Completá esta tabla. Una fila por impulsor, y cada celda de "Evidencia" debe hacer referencia a un ejercicio que efectivamente ejecutaste.

    | # | Presión de negocio | Capacidad de la nube | Evidencia (ejercicio) | Riesgo si no hacemos nada |
    |---|---|---|---|---|
    | 1 | Renovación de US$2,4M, utilización del 19% | | | |
    | 2 | Pico estacional de 5,5× | | | |
    | 3 | El competidor lanza funcionalidades más rápido | | | |
    | 4 | Sin visibilidad del costo de servir por cliente | | | |
    | 5 | Personal de operaciones consumido por el parcheo | | | |
    | 6 | Las licitaciones empresariales ahora exigen reporte de carbono | | | |

2. Escribí la recomendación al directorio en tres oraciones. Restricción: sin adjetivos, un número por oración, y un próximo paso con nombre propio.

3. Argumentá el caso **opuesto** en 150 palabras. Encontrá la razón genuina más fuerte por la que Meridian debería comprar el hardware. Si no podés construir una que un CFO competente tomaría en serio, todavía no entendés el compromiso.

4. Elegí un enfoque de migración y justificalo con un cronograma:
    - **Rehost** (lift and shift a Compute Engine)
    - **Replatform** (rehost, después mover Oracle a Cloud SQL y la capa web a Cloud Run)
    - **Refactor** (reescribir el monolito como servicios)
    - **Híbrido** (el despacho se queda on-premises vía GKE Enterprise; el desborde y la analítica en la nube)

    Decí con cuál empezarías en el mes 1, y qué tendría que ser verdad para el mes 6 para pasar al siguiente.

5. Identificá las dos cosas que realmente van a matar este programa, y no son técnicas. Nombralas y proponé una mitigación para cada una.

**Fuentes:** [Cloud Adoption Framework](https://cloud.google.com/adoption-framework) · [Migration to Google Cloud](https://cloud.google.com/architecture/migration-to-gcp-getting-started) · [Google Cloud Architecture Framework](https://cloud.google.com/architecture/framework)

### Comprobá tu comprensión — Bloque 9

1. **Q9.1** — ¿Cuál de las seis presiones del paso 1 *no* se resuelve solo con adoptar la nube, y qué más se requiere?
2. **Q9.2** — La cotización de renovación es de US$2,4M y el plazo es de 11 meses. ¿Por qué ese plazo es el hecho más importante del escenario, y qué significa si el directorio se demora seis meses?
3. **Q9.3** — El rehosting captura una fracción del valor (ver Q5.4) y es el camino más rápido. Defendelo igual como la elección correcta para el mes 1.
4. **Q9.4** — El diferenciador de Meridian son 40 años de datos de rutas y entregas. ¿Qué capacidad de la nube convierte eso, de un centro de costos, en la respuesta competitiva frente al rival financiado por capital de riesgo?
5. **Q9.5** — Nombrá el modo de falla en el que una empresa migra con éxito, ahorra dinero y aun así pierde frente al competidor. ¿Qué te dice eso sobre la diferencia entre *migración a la nube* y *transformación digital*?

---

## Ejercicio 10 — Desmontaje

Ejecutá esto. Elasticidad significa que dejás de pagar cuando dejás de consumir — pero solo si efectivamente dejás.

```bash
# Cloud Run, all three regions
for R in us-central1 europe-west1 asia-northeast1; do
  gcloud run services delete reach-demo --region="$R" --quiet 2>/dev/null
done
gcloud run services delete elasticity-demo --region="$REGION" --quiet

# Compute Engine
gcloud compute instances delete iaas-demo --zone="${REGION}-a" --quiet

# Budget (keep it if you intend to keep using the project)
BUDGET="$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --filter='displayName=cdl-lab-guardrail' --format='value(name)')"
[ -n "$BUDGET" ] && gcloud billing budgets delete "$BUDGET" --quiet

# BigQuery dataset (this deletes the billing export history)
bq rm -r -f --dataset "${PROJECT_ID}:billing_export"

# Verify nothing is left running
echo "--- remaining instances ---"; gcloud compute instances list
echo "--- remaining services ---";  gcloud run services list
```

Salida representativa:

```
--- remaining instances ---
Listed 0 items.
--- remaining services ---
Listed 0 items.
```

Después revisá la factura en 24 horas. El número que veas es el último ejercicio.

---

<details>
<summary><strong>Respuestas</strong> — abrir solo después de intentar cada bloque</summary>

### Bloque 1 — La unidad de costo

**A1.1** — La relación representa **pagar por consumo en lugar de por capacidad**. El costo de un servidor comprado queda fijado en el momento de la compra y es completamente independiente de cuántas horas hace trabajo útil; sus horas ociosas cuestan exactamente lo mismo que sus horas ocupadas. La diferencia de 6× no es un descuento — es la ausencia de un cargo por las 20 horas diarias en que la máquina no se necesita. Es estructuralmente imposible en hardware propio porque la transacción de CapEx ya se completó: no hay mecanismo por el cual no usar un servidor devuelva parte de su precio de compra, de su espacio en rack, de su circuito eléctrico o de su depreciación.

**A1.2** — El cliente está pagando menos por **el derecho a no ser interrumpido**. La capacidad Spot es el inventario sobrante de Compute Engine, recuperable con un aviso de terminación de ~30 segundos y una vida máxima de 24 horas. Dinero gratis: renderizado por lotes, flotas de build de CI/CD, ETL, entrenamiento de ML con checkpointing, transcodificación de video, fuzzing — cualquier cosa sin estado, reiniciable, y con un plazo medido en horas y no en segundos. Inutilizable: la réplica primaria de una base de datos con estado, una capa web con afinidad de sesión sin drenaje de conexiones, un appliance licenciado con una secuencia de arranque larga, o cualquier cosa bajo un SLO de latencia que un desalojo de 30 segundos violaría.

**A1.3** — Porque traslada el costo de una actividad de *compras* a una de *ingeniería*. Cuando los precios son cotizaciones, el costo se descubre en el momento de la compra, por otro departamento, en un ciclo trimestral — así que la arquitectura se elige primero y se costea después, y el costo es inmodificable una vez descubierto. Cuando los precios son una API, se puede construir un modelo de costos durante el diseño, correrlo en CI, adjuntarlo a un pull request y reevaluarlo automáticamente cuando Google cambia un precio. El arquitecto y el contador leen el mismo número al mismo tiempo. Esa es la diferencia entre el costo como una restricción que descubrís y el costo como una variable contra la cual diseñás.

**A1.4** — Te permite comprar la *forma* de tu carga de trabajo en lugar de la forma del SKU de un proveedor. On-premises, una carga hambrienta de memoria te obliga a comprar las CPU atornilladas a esa memoria, y esos núcleos ociosos son puro desperdicio que pagaste. Los SKU separados de vCPU y RAM son lo que hace posibles los tipos de máquina personalizados — una instancia de 4 vCPU / 32 GiB cuesta exactamente 4 núcleos más 32 GiB, sin redondear hacia arriba al ítem de catálogo más cercano. La generalización: el precio descompuesto permite escalar dimensiones de recursos de forma independiente, que es el mismo principio que hace que el almacenamiento sea independiente del cómputo en BigQuery.

### Bloque 2 — TCO

**A2.1** — "Pagamos una tarifa más alta por servidor-hora pero compramos aproximadamente un tercio de las servidor-horas, porque solo pagamos las horas que realmente usamos." Ambas afirmaciones son verdaderas simultáneamente porque los denominadores son distintos: el precio on-premises se amortiza sobre capacidad que existe trabaje o no, y el precio de la nube se cobra contra capacidad que solo existe mientras trabaja.

**A2.2** — Subir `ONPREM_UTIL` de 0,22 a 0,70 es de lejos el movimiento individual más grande, porque más que triplica el denominador on-premises sin cambiar su numerador. Describe una organización que ya hizo la parte difícil: una práctica madura de virtualización o contenedores con bin-packing real, consolidación agresiva, demanda estable y predecible, y sin un margen de seguridad ocioso grande. Esas organizaciones existen — trading de alta frecuencia, cierto cómputo científico, nubes privadas maduras — y para ellas el caso de costo de la nube es genuinamente débil. Su caso hay que construirlo sobre agilidad, alcance global o servicios gestionados. Alargar `REFRESH_YEARS` a 7 es el segundo más grande, y describe una organización que corre hardware más allá de su vida eficiente, lo que traslada costo desde la línea de CapEx hacia las líneas de riesgo y energía, donde este modelo no lo captura.

**A2.3** — Un CUD es una promesa de gastar un monto fijo por un plazo fijo a cambio de un descuento. Estructuralmente eso es exactamente lo que es una compra de hardware: capacidad pagada por adelantado, no reembolsable, dimensionada sobre un pronóstico. Las diferencias son reales pero más estrechas de lo que suenan — el compromiso es financiero y no físico, no tiene valor residual ni problema de descarte, y puede adosarse a distintas instancias de máquina a lo largo de su vida. **No** hace perder la elasticidad, y la razón importa: el patrón correcto es comprometer tu *piso* y quemar on-demand o Spot para todo lo que esté por encima. Comprometé el percentil 60 de la demanda, no el pico. Conservás elasticidad en la capacidad marginal, que es exactamente donde la elasticidad tiene valor, y comprás el descuento sobre la línea base, donde no la tiene.

**A2.4** — Genuinamente desaparecen: adquisición de hardware y gestión de proveedores, instalación física y cableado, reconstrucciones de RAID y reemplazo de discos, actualizaciones de firmware y BIOS, ciclo de vida del hipervisor, reuniones de planificación de capacidad, acceso al centro de datos y escoltas, inventario de repuestos, y la guardia por fallas físicas. Genuinamente aparecen: diseño de IAM y de políticas de organización, gestión de costos de nube (una disciplina nueva — ver Ejercicio 7), habilidades de Terraform/IaC, peering de red y conectividad híbrida, gestión de cuotas de servicio, y una superficie de seguridad considerablemente mayor para configurar. El supuesto 1,5 → 0,75 del modelo es defendible pero es un supuesto; el encuadre honesto es que la dotación *se desplaza desde operaciones indiferenciadas hacia ingeniería de plataforma*, y las organizaciones que migran sin hacer ese desplazamiento no capturan ninguno de los dos ahorros.

**A2.5** — Varias son válidas; las respuestas fuertes incluyen: (i) **costo único de migración** — evaluación, herramientas, correr ambos entornos en paralelo durante el corte, remediación de aplicaciones, que típicamente es el número más grande del primer año y no aparece en ningún modelo de régimen estable; (ii) **capacitación y contratación**; (iii) **relicenciamiento de software** — las licencias por núcleo frecuentemente se valúan distinto sobre infraestructura de nube, y Oracle en particular puede dominar toda la comparación; (iv) **cargos de egreso** para arquitecturas intensivas en datos o multinube; (v) **el valor residual y el costo hundido del hardware ya propio**; (vi) **el costo de oportunidad del tiempo de ingeniería** gastado migrando en lugar de construir producto.

### Bloque 3 — Elasticidad

**A3.1** — Transacción on-premises equivalente: adquirir y aprovisionar once servidores, y luego darlos de baja quince minutos después. En la práctica eso es un pedido de capacidad, una aprobación de presupuesto, una orden de compra, un plazo de fabricación y envío de cuatro a doce semanas, montaje en rack, cableado, imagen y configuración de red — digamos de uno a tres meses y un gasto irreversible de cinco cifras — seguido de ser dueño del hardware por los próximos cuatro años. La versión en la nube costó unos centavos y no requirió ninguna decisión humana. Este es el mecanismo detrás de la palabra "agilidad" del examen: no es que la nube sea más rápida en la misma tarea, es que la tarea dejó de ser un evento de compras.

**A3.2** — El intercambio es **costo contra latencia**, y es la decisión canónica de serverless. `--min-instances=0` significa que no pagás nada en reposo y que el primer usuario tras un período ocioso absorbe un arranque en frío del contenedor. `--min-instances=2` significa que dos instancias se facturan continuamente — 24/7, para siempre — y que ningún usuario paga nunca un arranque. La decisión pertenece al **dueño del producto o del negocio**, no a ingeniería, porque es la compra de experiencia de usuario con dinero y el tipo de cambio es cuantificable: costo mensual del piso caliente contra el impacto en conversión de una penalidad de ~1,2 segundos en la primera solicitud. El trabajo de ingeniería es valuar ambos lados con precisión, no elegir.

**A3.3** — **Costo:** el techo es el radio de explosión de un bug o de un ataque. Una tormenta de reintentos, un cliente descontrolado o un pequeño DDoS contra un servicio sin tope se convierten directamente en una factura ilimitada, y a diferencia de una flota fija de servidores nada lo detiene. **Corrección:** las dependencias aguas abajo tienen capacidad finita. Si cada instancia de Cloud Run abre conexiones a la base de datos, el escalado sin límite agota el pool de conexiones de la base y tira abajo a todos los consumidores de esa base — la capa elástica destruye la capa inelástica que tiene detrás. `--max-instances` es el mecanismo que hace que la capa elástica respete los límites de la capa de la que depende.

**A3.4** — Bajo la facturación **por solicitudes** predeterminada de Cloud Run, se te cobra CPU y memoria solo durante el procesamiento de solicitudes; una instancia que existe pero está ociosa entre solicitudes se factura a una tarifa mucho menor, o nada por CPU. Así que la división `active`/`idle` se mapea casi directamente sobre la factura, y una instancia mantenida caliente por razones de latencia es mucho más barata que una VM facturada de forma continua. Bajo la facturación **basada en instancias** (`--no-cpu-throttling`, necesaria para trabajo en segundo plano, colas dentro del proceso o conexiones de larga duración) la CPU siempre está asignada y siempre se factura durante toda la vida de la instancia — el conteo `idle` deja de ser gratis y empieza a verse exactamente como una VM en ejecución. Elegir la facturación basada en instancias cambia entonces tanto el modelo de concurrencia *como* la economía, y por eso es una bandera deliberada y no un valor predeterminado.

**A3.5** — (i) **Recuperación ante fallas y despliegue.** La elasticidad es la misma maquinaria que reemplaza una instancia caída y que ejecuta un rollout blue/green o canary — obtenés reemplazo transparente de capacidad y despliegues sin caída a partir de la misma primitiva, sin importar si la demanda varía. (ii) **Dimensionamiento correcto sin riesgo.** Con demanda plana el valor pasa de escalar *hacia afuera* a escalar *hacia abajo*: como la capacidad es reversible, podés recortar recursos aprovisionados hacia el uso real y deshacer el cambio en segundos si te pasaste. En hardware propio, sobreaprovisionar es la elección racional porque subaprovisionar es irrecuperable; la elasticidad quita la penalidad por estimar bajo. También es aceptable: el crecimiento no siempre es diario — el tráfico plano de hoy igual se vuelve 3× después de un lanzamiento exitoso, y la elasticidad es el valor opción sobre eso.

### Bloque 4 — Alcance global

**A4.1** — Caso de negocio reemplazado: "Entrar al mercado europeo — 18 meses, selección del sitio, entidad legal, alquiler de centro de datos, compra y envío de hardware, contratación de operaciones locales, varios millones de dólares comprometidos antes del primer cliente." Ahora: una cadena de región y un despliegue, reversible con un comando. El beneficiario desproporcionado es **la empresa chica o nueva**, y este es el punto estructuralmente importante: la nube no solo reduce el costo de operar globalmente, elimina el alcance global como *barrera de entrada*. Un startup de tres personas y una multinacional ahora despliegan en las mismas más de 40 regiones y en los mismos términos. Esa simetría —y no el ahorro de costos— es la verdadera revolución que nombra el objetivo del examen, y es por eso que los incumbentes pierden ante recién llegados que antes nunca habrían podido competir.

**A4.2** — Una **zona** es un área de despliegue dentro de una región, diseñada como un dominio de falla independiente: energía, refrigeración y red separadas, de modo que una falla de hardware, de energía o de software en una zona no debería afectar a otra. Una **región** es una ubicación geográfica independiente que contiene tres o más zonas, típicamente dentro de un área metropolitana. Multi-zona protege contra fallas de equipamiento, un evento de energía o refrigeración a nivel de centro de datos, y la mayoría de las fallas de mantenimiento y despliegue. Multi-región protege además contra eventos de alcance regional — desastre natural, pérdida prolongada de energía o red regional, interrupción de servicio en toda la región — y es la única configuración que aborda la residencia de datos y la latencia por proximidad al usuario, que no son en absoluto cuestiones de disponibilidad.

**A4.3** — Cualquier carga donde el tráfico sea masivo, tolerante a la latencia y contenido regionalmente. Concretamente: replicación nocturna de respaldos a Cloud Storage, envío de logs por lotes, transferencias de grandes conjuntos de datos entre sistemas del mismo continente, egreso de analítica interna, o una aplicación solo interna cuyos usuarios están todos en la misma región que los recursos. El Premium Tier te compra la red troncal privada de Google desde el borde más cercano al usuario — lo que vale la pena pagar cuando los usuarios están lejos y la latencia es visible para ellos, y no vale nada cuando los bytes son de máquina a máquina y nadie está esperando.

**A4.4** — **Regulatoria:** un cliente del sector público francés, un contrato de salud o de defensa, o una cláusula contractual de residencia de datos pueden exigir que los datos se almacenen y procesen dentro de Francia específicamente, no meramente dentro de la UE. `europe-west4` en los Países Bajos satisface el GDPR pero falla un requisito de residencia francés, y la restricción es binaria — ningún ahorro de costos vuelve aceptable una arquitectura no conforme. **Comercial:** latencia y credibilidad de mercado. Los usuarios en Francia ven una latencia materialmente menor desde París, y para un producto sensible a la latencia eso es una diferencia medible en conversión; por separado, "alojado en Francia" es una afirmación que gana negocios empresariales franceses de forma independiente de cualquier requisito legal. Ambas son razones de negocio que pesan más que la diferencia de precio, que es la lección general: la selección de región es una decisión de negocio con insumos técnicos, no al revés.

**A4.5** — Que la velocidad de la luz no es una funcionalidad del proveedor. Google puede poner una región cerca de tus usuarios, pero no puede acercar Tokio a São Paulo. "La nube está en todas partes" significa *que podés elegir dónde estás*, no que la ubicación haya dejado de importar — y esa elección sigue siendo una decisión arquitectónica real con compromisos reales contra costo, carbono y complejidad operativa. Las arquitecturas que ignoran esto (una única región sirviendo a una base de usuarios global) obtienen una latencia limitada por la física que ninguna cantidad de escalado arregla.

### Bloque 5 — Modelos de servicio

**A5.1** — Por debajo del límite, el proveedor entrega un sistema que funciona y lo actualiza sin preguntarte; por encima del límite, recibís un sistema que se va a degradar y volver inseguro salvo que vos personalmente lo mantengas. El límite está definido por **quién está obligado a actuar cuando se publica una vulnerabilidad**. Todo lo que está por debajo es obligación del proveedor; todo lo que está por encima, incluida la obligación de enterarte, es tuya.

**A5.2** — (a) Control: IaaS > PaaS > SaaS. (b) Carga operativa: IaaS > PaaS > SaaS. Los ordenamientos son **idénticos**, y ese es todo el intercambio: control y carga son la misma cantidad vista desde dos lados. Cada perilla que conservás es una perilla que tenés que configurar bien, mantener bien, y por la que te van a llamar de madrugada. No hay ningún modelo que dé más control con menos trabajo — elegir un modelo de servicio es elegir de cuánto de la pila querés ser responsable, y la elección correcta es el mínimo control que aún satisface el requisito.

**A5.3** — Deben usar **IaaS** (Compute Engine, o GKE Standard con una imagen de nodo personalizada si pueden contenerizar). Un módulo de kernel requiere acceso al kernel, y las plataformas PaaS no proveen kernel que modificar — esto no es una limitación que haya que rodear, es la definición del nivel. Costo honesto: ahora son dueños del parcheo del SO, las actualizaciones de kernel, el ciclo de vida de la imagen, el endurecimiento, el monitoreo a nivel de host, la planificación de capacidad y el autoescalado de nodos para ese componente, más el riesgo permanente de que el módulo del proveedor se atrase respecto de las correcciones de seguridad del kernel. La respuesta arquitectónica madura es **acotar la restricción**: aislar el componente licenciado en IaaS y correr en PaaS todo lo que no necesite el módulo, en lugar de dejar que un requisito arrastre toda la arquitectura un nivel para abajo.

**A5.4** — El rehosting captura la **economía de infraestructura** y poco más: elasticidad en la cantidad de VM, sin renovación de hardware, sin alquiler de centro de datos, facturación por hora, elección global de región y la capacidad de dimensionar correctamente — que en el modelo del Ejercicio 2 son las líneas de hardware, array, colo y energía. Deja sobre la mesa los ahorros **operativos**, que eran la línea individual más grande de ese modelo: la VM sigue necesitando parcheo, respaldo, monitoreo y planificación de capacidad, así que el número de FTE de operaciones apenas se mueve. También deja completamente intactos los beneficios de servicios gestionados y de velocidad de desarrollo. La advertencia importante: las migraciones de solo rehost frecuentemente producen facturas *más altas* que el parque on-premises, porque un lift-and-shift preserva la utilización del 19% para la que fue construido mientras cambia a un modelo de precios que castiga la ociosidad. El rehosting es un primer paso válido pero un mal estado final.

**A5.5** —
- **Compute Engine** — IaaS. Elegís tipo de máquina, imagen, discos y red; sos dueño del SO.
- **GKE Autopilot** — PaaS en la práctica, aunque se comercialice como Kubernetes gestionado. Google es dueño de los nodos, del SO de los nodos, del escalado y de la seguridad de los nodos; vos sos dueño de las cargas de trabajo y de la configuración a nivel de clúster. GKE *Standard*, en cambio, está mucho más cerca de IaaS porque sos dueño de los pools de nodos.
- **Cloud Run** — PaaS (específicamente CaaS serverless). Vos aportás un contenedor; Google aporta todo lo que hay debajo.
- **BigQuery** — PaaS según la taxonomía estándar, y el más difícil de ubicar. Es completamente gestionado y serverless, sin ninguna infraestructura expuesta, lo que se lee como SaaS, pero vos escribís los esquemas y el SQL y es un componente con el que *construís*, no una aplicación que usás.
- **Google Workspace** — SaaS. Aplicación terminada, sin paso de construcción, consumida por usuarios finales.

La parte instructiva es BigQuery. La taxonomía de tres modelos fue diseñada para un mundo de máquinas virtuales, y los productos modernos de datos e IA serverless no encajan limpiamente en ella. El examen todavía usa la taxonomía, así que aprendela — pero la pregunta *útil* en la práctica no es "cuál de tres letras es esto" sino "exactamente qué responsabilidades asume el proveedor, y cuáles siguen siendo mías". Esa pregunta siempre tiene una respuesta precisa; la taxonomía a veces no.

### Bloque 6 — Responsabilidad compartida y destino compartido

**A6.1** — Responsabilidad **del cliente**, sin ambigüedad. La obligación de Google es la seguridad *de* la nube: la instalación física, el hardware, el hipervisor, el tejido de red y el funcionamiento correcto del servicio de firewall. La obligación del cliente es la seguridad *en* la nube: qué reglas hace cumplir ese firewall, qué credenciales existen y cómo se protegen. Google entregó una red predeterminada optimizada para los primeros cinco minutos de un desarrollador y documenta que no es una postura de producción; dejar `0.0.0.0/0` en el puerto 22 es una decisión de configuración del cliente. La crítica justa es al *valor predeterminado*, no al límite — ver A6.4.

**A6.2** — A medida que vas de IaaS → PaaS → SaaS, el límite se mueve **hacia arriba en la pila, transfiriendo responsabilidades del cliente al proveedor**: primero lo físico y la virtualización (siempre del proveedor), luego el SO, el parcheo y el runtime, luego el mantenimiento y la disponibilidad de la aplicación, y finalmente la aplicación misma. La responsabilidad que **nunca se mueve** es la del cliente: **los datos, y la identidad/el acceso a ellos**. Sea cual sea el modelo, vos decidís qué datos ponés, quién puede alcanzarlos, cómo se clasifican y si las concesiones de acceso son correctas. Google puede cifrarlos, replicarlos y auditar el acceso a ellos — Google no puede decidir en tu nombre que determinada persona no debería haber sido Owner.

**A6.3** — La **responsabilidad compartida** es una división estática del trabajo: una matriz publicada que indica qué capas asegura el proveedor y cuáles el cliente, de modo que ninguno suponga que el otro se está ocupando de algo. El **destino compartido** es que el proveedor tome una participación activa y continua en la mitad del cliente — proveyendo configuraciones seguras por defecto, blueprints, análisis continuo de la postura del propio cliente, y en algunos programas reparto de riesgo financiero — bajo la premisa de que una brecha del cliente también es problema del proveedor. El ejemplo del paso 5 es **IAM Recommender**: Google analiza continuamente el uso real de permisos dentro de tu proyecto y propone reducciones de roles hacia el mínimo privilegio. La configuración de IAM es de lleno responsabilidad del cliente según la matriz, y Google hace el análisis y te entrega la solución igual. El propio encuadre de Google es que la responsabilidad compartida describe *quién rinde cuentas*, mientras que el destino compartido describe *cómo el proveedor ayuda al cliente a tener éxito en su parte*.

**A6.4** — Existe para eliminar la fricción de adopción: sin una cuenta de servicio predeterminada con permisos amplios, la primera VM de un usuario nuevo no puede escribir logs, leer de Cloud Storage ni llamar a ninguna API, y la experiencia de primeros pasos se convierte en un tutorial de IAM. El compromiso es explícito y es la tensión recurrente del diseño de plataformas de nube — **un valor predeterminado seguro para todos es incómodo para principiantes, y un valor predeterminado cómodo para principiantes es inseguro a escala.** La existencia de `roles/editor` en esa cuenta te dice que Google eligió la adopción en la capa de valores predeterminados y empujó la corrección a una capa *separada* y opcional: políticas de organización (`iam.automaticIamGrantsForDefaultServiceAccounts` puede desactivarlo), IAM Recommender, hallazgos de Security Command Center. La lección práctica para un arquitecto: **los valores predeterminados de la plataforma no son sus recomendaciones.** Nunca trates un valor predeterminado como una revisión de seguridad.

**A6.5** — "La infraestructura física, el hipervisor y el tejido de red sí pasaron a ser problema de Google, y Google es medible mente mejor en eso de lo que éramos nosotros. Lo que no se movió son nuestros datos y quién puede acceder a ellos — cada brecha significativa de nube registrada fue una configuración incorrecta del cliente, no un compromiso del proveedor. Nuestro trabajo de seguridad no desapareció; cambió de parchear servidores a hacer bien identidad, acceso y configuración, y actualmente tenemos una cuenta de servicio predeterminada con derechos de editor y SSH abierto a internet." Algo concreto que genuinamente sí pasó a ser problema de Google: la seguridad física del centro de datos, la integridad de la cadena de suministro de hardware, el aislamiento del hipervisor entre inquilinos, y el cifrado en reposo por defecto.

### Bloque 7 — Circuito de retroalimentación de costos

**A7.1** — Tres cualesquiera de: **(i) Economía unitaria** — unir los datos de facturación con las etiquetas de la aplicación para calcular el costo por cliente, por inquilino, por transacción o por funcionalidad, lo que vuelve las decisiones de precio y margen basadas en evidencia en lugar de asignadas por una estimación de metros cuadrados. **(ii) Chargeback y showback** — atribuir el costo real al equipo que lo causó, lo que cambia el comportamiento de ingeniería en días en lugar de en el próximo ciclo presupuestario. **(iii) Decisiones de baja** — ver que una funcionalidad cuesta más operarla de lo que genera, y retirarla. **(iv) Focalización de la optimización** — identificar el SKU de mayor costo y arreglar ese, en vez de correr un programa de eficiencia sin objetivo. **(v) Detección de regresiones** — tratar un pico de costo como una falla de build, porque un cambio que triplica el gasto suele además ser un bug. **(vi) Pronóstico preciso** — modelar el próximo trimestre a partir de una tendencia medida y no de una cotización de proveedor.

**A7.2** — Los presupuestos alertan en lugar de imponer porque **detener el gasto significa detener el negocio**. Un tope duro que deshabilita la facturación tira producción abajo, borra recursos y convierte un sobrecosto —recuperable— en una caída y una posible pérdida de datos —a veces no recuperable—. Google no puede saber si tu sobrecosto es un bucle de prueba descontrolado o el Black Friday. Para volverlo coercitivo, construís el circuito vos: presupuesto → notificación de Pub/Sub → Cloud Function que toma una acción *acotada y reversible*. Acciones sensatas en orden creciente: notificar al equipo dueño, reducir `--max-instances` en servicios que no sean de producción, detener las VM de desarrollo etiquetadas, cancelar trabajos de BigQuery de larga duración. Deshabilitar la facturación del proyecto es el último recurso documentado y debería reservarse para proyectos sandbox que no contengan nada que extrañarías. El principio de diseño: automatizá la respuesta, pero mantené el radio de explosión proporcional y la acción reversible.

**A7.3** — Que la **primera acción sustantiva** en una organización nueva de Google Cloud — antes de las cargas de trabajo, antes de terminar la landing zone — es habilitar la exportación de facturación, junto con un estándar de etiquetado y un presupuesto a nivel de organización. Cada hora de demora es una hora de historial de costos que nunca se puede recuperar, y el historial de costos es de lo que dependen toda optimización, pronóstico y conversación de chargeback posteriores. Es gratis, lleva minutos, y es lo más común que las organizaciones se saltean y luego lamentan doce meses después, cuando no pueden responder "¿cuándo empezó esto?".

**A7.4** — En el Ejercicio 2, `CLOUD_UTIL`, las tarifas por hora, `CLOUD_STORAGE_EGRESS_YR` y en la práctica toda la columna de la nube eran **supuestos**. Con la exportación de facturación se convierten en **mediciones** tomadas de tu propia cuenta, y el modelo pasa de ser un artefacto de venta previo a la migración a ser un tablero operativo en vivo que volvés a correr cada mes. Esto cierra el circuito que las finanzas on-premises nunca pudieron: la columna on-premises sigue siendo una estimación para siempre, porque un cronograma de depreciación no puede decirte qué carga de trabajo consumió qué fracción de un array compartido. Esa asimetría —un lado medible, el otro permanentemente estimado— es en sí misma parte del argumento.

**A7.5** — La cadena: la facturación granular significa que cada equipo puede ver el costo de sus propias decisiones casi en tiempo real → el costo deja de ser un gasto general asignado centralmente y pasa a ser una propiedad del cambio → los equipos pueden evaluar por sí mismos la economía de una propuesta sin una compuerta de finanzas → los experimentos se vuelven baratos de *evaluar*, no solo baratos de *ejecutar* → la organización puede probar muchas cosas chicas, medir cuáles rinden y matar el resto rápido. La agilidad viene de que el OpEx elimina **dos** barreras, y la segunda es la que la gente pasa por alto: la primera es que no hace falta aprobación de capital para empezar, y la segunda es que no se incurre en una baja contable de capital para parar. Cuando fracasar es barato y reversible, la cantidad racional de experimentos sube — y correr más experimentos es cómo una empresa supera en innovación a otra que tiene que acertar a la primera.

### Bloque 8 — Sostenibilidad

**A8.1** — Debería ser propiedad de quien sea dueño del **registro de decisiones de arquitectura** — la función de plataforma o de gobierno de la nube —, codificada como una política de organización (`gcp.resourceLocations`) y como un valor predeterminado en las plantillas de despliegue, de modo que la elección consciente del carbono sea el camino de menor resistencia y no un juicio por equipo. Normalmente es propiedad del desarrollador individual, que selecciona una región copiando la región del tutorial que estaba leyendo — que es por lo que tanta carga de trabajo de nube del mundo está en `us-central1`. La lección general: una decisión tan consecuente no debería vivir en el valor predeterminado de un comando copiado y pegado.

**A8.2** — **Neutral en carbono** significa que las emisiones netas anuales se llevan a cero mediante compensaciones y compras renovables equiparadas — una contabilidad *anual y neteada*. Google es neutral en carbono en sus operaciones desde 2007 y ha igualado el 100% del consumo anual de electricidad con compras renovables desde 2017. **Energía libre de carbono 24/7** significa que cada hora, en cada red eléctrica, la electricidad efectivamente consumida proviene de fuentes libres de carbono — sin neteo a través del tiempo ni de la geografía. Es dramáticamente más difícil porque no se resuelve comprando más renovables en algún lugar soleado: requiere generación limpia disponible a las 3 de la mañana en esa red específica, lo que exige almacenamiento, geotermia, nuclear o transmisión a escala de red que en muchas regiones todavía no existe. Le importa al cliente porque los estándares de contabilidad de carbono y los reguladores se están moviendo hacia un reporte horario y basado en la ubicación, bajo el cual el equiparado anual deja de ser suficiente — así que un proveedor en la ruta 24/7 está protegiendo la posición *futura* de cumplimiento del cliente, no solo la actual.

**A8.3** — **La más limpia es incorrecta:** un servicio de autorización de pagos en tiempo real o de puja publicitaria para usuarios japoneses ubicado en `europe-north1` por su 91% de CFE agregaría aproximadamente 250 ms de ida y vuelta, violando el SLO y arruinando el producto. El carbono no puede comprarle la vuelta a la física; el movimiento correcto es la región más limpia *dentro* del sobre de latencia. **La más limpia es correcta:** un trabajo por lotes nocturno — entrenamiento de modelos, agregación de logs, reconstrucción de un data warehouse — con una ventana de finalización de doce horas y sin usuario interactivo. La latencia es irrelevante, así que la elección de región queda libre para optimizar carbono y precio, y una reducción de emisiones de 30× no cuesta nada. La regla generalizable: **el carbono es un criterio de desempate legítimo entre regiones que ya satisfacen las restricciones duras**, y las cargas por lotes casi no tienen restricciones duras, que es por lo que la planificación consciente del carbono empieza ahí.

**A8.4** — PUE 1,6 significa 0,6 kWh de sobrecarga — refrigeración, conversión de energía, iluminación — por cada 1,0 kWh entregado al cómputo; el consumo total son 1,6 unidades por 1 unidad de trabajo útil, así que el 37,5% de toda la energía es sobrecarga. Con PUE 1,1 la sobrecarga es del 9%. Pasar de 1,6 a 1,1 recorta el consumo total de energía para cómputo idéntico en alrededor del 31%. Lo que el cliente compra y no podría construir: instalaciones diseñadas a propósito a una escala que justifica refrigeración a medida, gestión térmica dirigida por ML, distribución eléctrica personalizada y hardware co-diseñado con el edificio — más acuerdos de compra de energía de largo plazo con nueva generación limpia, que requieren una solvencia y un volumen que prácticamente ninguna empresa individual posee. Esta es una economía de escala en sentido estricto: la eficiencia no es una técnica que se esté ocultando, es solo alcanzable *a* esa escala.

**A8.5** — Porque un PDF es una *divulgación* y una exportación es un *insumo*. Una exportación legible por máquina se puede unir con la exportación de facturación del Ejercicio 7, atribuir a un proyecto, equipo, servicio o cliente, poner en un tablero al lado del costo, verificar en CI, alimentar una presentación regulatoria y usar para tomar una decisión de despliegue *antes* de que la carga de trabajo se ejecute. Un PDF solo se puede leer después del hecho y volver a tipear. El patrón es idéntico al de A1.3: en el momento en que un número se vuelve una API en vez de un documento, pasa de ser algo que reportás a algo contra lo cual hacés ingeniería.

### Bloque 9 — Síntesis

**A9.1** — **La presión 3, "el competidor lanza funcionalidades más rápido".** La infraestructura de nube elimina un *obstáculo* a la velocidad de lanzamiento; no crea velocidad. También se requiere: CI/CD, pruebas automatizadas, descomposición del monolito Java para que los cambios puedan liberarse de forma independiente, equipos de producto con poder de liberar sin un comité de aprobación de cambios, y observabilidad suficiente para que lanzar frecuentemente sea seguro. Un monolito rehospedado con un tren de releases trimestral lanza exactamente igual de lento en Compute Engine que on-premises, a un costo comparable o mayor. Esta es la palabra "cómo" del objetivo — la tecnología es necesaria y ni de cerca suficiente.

**A9.2** — Porque es el momento en que la decisión se vuelve **irreversible por cuatro años**. Cada mes antes de la compra, migrar es una opción; el día que se firma la orden de compra, existen US$2,4M de capital hundido y toda propuesta de nube posterior tiene que argumentar en contra de abandonarlo, que es un argumento político que nadie gana. Las fechas de renovación son el punto natural de decisión para una migración precisamente porque son los únicos momentos en que el statu quo también requiere firmar un cheque grande — la comparación por fin es de igual a igual. Si el directorio se demora seis meses, el resultado práctico es que van a comprar el hardware: cinco meses no alcanzan para evaluar, planificar y comenzar una migración de 180 servidores, así que el predeterminado "seguro" gana por dejar correr el reloj. La recomendación correcta incluye entonces una fecha de decisión bastante antes del undécimo mes.

**A9.3** — Porque la restricción vinculante es el plazo de 11 meses, no el óptimo. El rehosting es el único enfoque que puede mover demostrablemente suficiente carga de trabajo fuera del parque existente a tiempo para cancelar la compra de renovación — y cancelar esa compra es lo que financia y desriesga todo lo que viene después. También adelanta el aprendizaje organizacional (IAM, redes, IaC, gestión de costos) sobre cargas de bajo riesgo, de modo que el equipo sea competente antes de tocar la aplicación de despacho. La disciplina que lo vuelve defendible en vez de perezoso es comprometerse de antemano con lo que sigue: rehost con *dimensionamiento correcto aplicado en la migración* en lugar de un clon igual a igual de VM al 19% de utilización, con un objetivo de replatform con nombre y fecha. El rehosting es un buen primer movimiento y un mal destino; el modo de falla no es elegirlo, es quedarse ahí.

**A9.4** — La **pila de datos e IA/ML** — consolidar cuatro décadas de datos de rutas, tiempos de entrega, combustible y excepciones en BigQuery, y luego construir sobre eso optimización de rutas y predicción de tiempos de entrega. Este es el núcleo estratégico de la respuesta. El competidor tiene mejor software pero 14 meses de datos; Meridian tiene peor software y 40 años de datos. La economía de la nube es lo que vuelve utilizable ese activo: consultar décadas de historial requiere un cómputo enorme, en ráfagas e intermitente, que es absurdo comprar como hardware y trivial alquilar por una hora. Notá que este es el único ítem de la lista que es *ofensivo* y no defensivo — los ítems de costo, capacidad y parcheo hacen que Meridian sea más barata de operar, pero este es el único que puede recuperar un cliente.

**A9.5** — El modo de falla es **rehospedar y detenerse**: la empresa completa una migración técnicamente limpia, da de baja el centro de datos, reporta el ahorro de infraestructura y canta victoria — mientras el monolito, el tren de releases trimestral, el comité de aprobación de cambios y el organigrama sobreviven intactos. Los costos bajan quizás un 20%; la velocidad de funcionalidades no cambia; el competidor sigue ganando cuentas. La lección es que **la migración a la nube es un cambio de sede y la transformación digital es un cambio de modelo operativo**. La migración es la precondición necesaria y la mitad fácil; se mide en servidores movidos. La transformación se mide en qué tan rápido la empresa puede convertir una idea en algo que un cliente usa, y requiere cambios en la estructura de equipos, el proceso de release, el modelo de financiamiento y los derechos de decisión que ningún comando `gcloud` ejecuta. Una empresa que hace lo primero y lo llama lo segundo compró la factura sin el beneficio — que es la razón precisa por la que este objetivo del examen está formulado como *por qué y cómo*, y no meramente *qué*.

</details>