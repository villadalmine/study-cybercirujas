# Cloud Digital Leader — Tema 4.3

## Describir el valor de negocio de las interfaces de programación de aplicaciones (APIs)

**Certificación:** `gcp-cdl` — Google Cloud Digital Leader (versión de la guía del examen 2026-08-12)
**Peso en el examen:** 6.0
**Formato:** ejercicios guiados — pasos numerados que ejecutás, preguntas de control después de cada bloque, respuestas plegadas al final.

---

## Por qué vale la pena hacer este tema con las manos

El examen Cloud Digital Leader hace preguntas *de negocio* sobre APIs: por qué una organización expone una, qué habilita, qué producto de Google Cloud encaja en cada escenario. Pero las respuestas de negocio solo quedan grabadas si viste la maquinaria que las produce. "Las APIs crean nuevas fuentes de ingresos" es un eslogan hasta que emitiste una consumer key, viste una cuota devolver `429` y leíste los conteos de llamadas por consumidor contra los que un equipo de finanzas facturaría.

Estos ejercicios construyen un programa de APIs pequeño pero con forma de producción:

| Ejercicio | Qué construís | Qué capacidad de negocio demuestra |
|---|---|---|
| 1 | Backend privado en Cloud Run | El activo que tiene valor pero no tiene distribución |
| 2 | Gateway gestionado por delante | Exposición controlada, una única puerta de entrada |
| 3 | API keys + cuotas | Identidad del consumidor, tiering, SLAs exigibles |
| 4 | Proxy de Apigee sobre un target legacy | Modernización sin reescribir el sistema de registro |
| 5 | API product, developer, app, key | Convertir un endpoint en un *producto* que se puede vender |
| 6 | Analítica de uso | Medir la adopción; el insumo de la monetización |
| 7 | Modelo de costo de integración (en papel) | El argumento `n(n-1)/2`, con números |
| 8 | Simulacro de escenarios de examen | Selección de producto: Apigee vs API Gateway vs Endpoints |

---

## Requisitos previos y costo

**Antes de empezar:**

- Un proyecto de Google Cloud con facturación habilitada, y `roles/owner` o un conjunto equivalente sobre él.
- La CLI `gcloud` instalada y autenticada (`gcloud auth login`, `gcloud config set project <PROJECT_ID>`).
- `curl`, `jq` y `zip` disponibles en tu shell.
- Los ejercicios 4 y 5 requieren además una **organización de Apigee**. Apigee no tiene una capa gratuita permanente; aprovisionar una organización de *evaluación* con tiempo limitado se hace desde la consola y lleva entre 15 y 45 minutos. **Ambos ejercicios incluyen una variante solo en papel** si no querés aprovisionar Apigee — el examen no exige haberlo ejecutado, solo entender qué hace.

**Nota sobre costos.** Cloud Run y API Gateway tienen asignaciones mensuales gratuitas dentro de las cuales este laboratorio se mantiene cómodamente; verificá las condiciones vigentes en <https://cloud.google.com/run/pricing> y <https://cloud.google.com/api-gateway/pricing>. Apigee se factura por hora de entorno una vez que la evaluación expira. **El ejercicio 9 es el desmantelamiento — ejecutalo.**

**Sobre las salidas esperadas.** Cada bloque de salida de abajo muestra la *forma* que deberías obtener: nombres de campos, códigos de estado, cuerpos de error. Los IDs de proyecto, hostnames, números de revisión, keys y timestamps van a diferir en tu ejecución. Compará la estructura, no las cadenas.

---

## Ejercicio 1 — El activo sin canal de distribución

Un servicio que funciona pero que nadie fuera de tu equipo puede llamar de forma segura tiene valor externo cero. Empezá ahí, deliberadamente.

### Pasos

1. Definí tus variables de trabajo. Usá una sola shell para todo el laboratorio.

   ```bash
   export PROJECT_ID="$(gcloud config get-value project)"
   export REGION="us-central1"
   export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
   echo "$PROJECT_ID / $PROJECT_NUMBER / $REGION"
   ```

2. Habilitá los servicios que este laboratorio necesita.

   ```bash
   gcloud services enable \
     run.googleapis.com \
     apigateway.googleapis.com \
     servicemanagement.googleapis.com \
     servicecontrol.googleapis.com \
     apikeys.googleapis.com \
     monitoring.googleapis.com \
     logging.googleapis.com
   ```

   Esperado: `Operation "operations/acat...." finished successfully.`

3. Desplegá un servicio de backend. Mantenelo **privado** — sin acceso no autenticado. Ese es el punto del ejercicio.

   ```bash
   gcloud run deploy catalog-backend \
     --image=us-docker.pkg.dev/cloudrun/container/hello \
     --region="$REGION" \
     --no-allow-unauthenticated \
     --quiet
   ```

   Esperado (abreviado):

   ```
   Deploying container to Cloud Run service [catalog-backend] in project [my-proj] region [us-central1]
   ✓ Deploying new service... Done.
     ✓ Creating Revision...
     ✓ Routing traffic...
   Service [catalog-backend] revision [catalog-backend-00001-abc] has been deployed
   and is serving 100 percent of traffic.
   Service URL: https://catalog-backend-abc123-uc.a.run.app
   ```

4. Capturá la URL e intentá consumirla como lo haría un partner externo — de forma anónima.

   ```bash
   export BACKEND_URL="$(gcloud run services describe catalog-backend \
     --region="$REGION" --format='value(status.url)')"

   curl -s -o /dev/null -w '%{http_code}\n' "$BACKEND_URL"
   ```

   Esperado: `403`

5. Ahora llamalo como lo haría una persona de ingeniería interna con identidad de Google.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
     "$BACKEND_URL"
   ```

   Esperado: `200`

6. Preguntale a la plataforma quién consumió este servicio, y cuánto. Intentá responder "¿cuántas llamadas hizo el partner X el mes pasado?".

   ```bash
   gcloud logging read \
     'resource.type="cloud_run_revision" AND resource.labels.service_name="catalog-backend"' \
     --limit=3 --format='value(httpRequest.status, httpRequest.userAgent)'
   ```

   Vas a obtener líneas de solicitudes. **No** vas a obtener una identidad de consumidor a la que le puedas facturar.

### Preguntas de control

- **Q1.1** — El paso 4 devolvió `403` y el paso 5 devolvió `200`. Ambos son "el servicio funciona". Desde el punto de vista del negocio, ¿qué es lo que el servicio *no* tiene todavía?
- **Q1.2** — Un partner pide acceso. Con lo único que existe después del paso 5, ¿qué tendrías que darle, y qué dos riesgos de negocio implica eso?
- **Q1.3** — Finanzas te pide facturar a tres partners por consumo. ¿Qué única capacidad faltante hace que eso sea imposible hoy?
- **Q1.4** — La guía del examen ubica a las APIs dentro de "modernizar infraestructura y aplicaciones". Explicá en una oración por qué un backend *privado y funcionando* todavía no es una API en el sentido de negocio.

---

## Ejercicio 2 — Una puerta de entrada gestionada

Un API gateway es el punto de control donde un endpoint técnico se convierte en una interfaz gobernada: un hostname, un contrato, un solo lugar donde aplicar la seguridad y un solo lugar que cuenta.

### Pasos

1. Creá una cuenta de servicio para el gateway y permitile — solo a ella — invocar el backend.

   ```bash
   gcloud iam service-accounts create apigw-invoker \
     --display-name="API Gateway backend invoker"

   export GW_SA="apigw-invoker@${PROJECT_ID}.iam.gserviceaccount.com"

   gcloud run services add-iam-policy-binding catalog-backend \
     --region="$REGION" \
     --member="serviceAccount:${GW_SA}" \
     --role="roles/run.invoker"
   ```

2. Escribí el contrato de la API. API Gateway consume **OpenAPI 2.0 (Swagger)**, no 3.x — es una restricción real y con la que se choca seguido. Creá `openapi2-run.yaml`:

   ```yaml
   swagger: "2.0"
   info:
     title: catalog-api
     description: Product catalog exposed as a managed, governed API
     version: "1.0.0"
   schemes:
     - https
   produces:
     - application/json
   paths:
     /products:
       get:
         summary: List products in the catalog
         operationId: listProducts
         x-google-backend:
           address: BACKEND_URL_PLACEHOLDER
           protocol: h2
         responses:
           "200":
             description: A list of products
           "403":
             description: Caller is not permitted
     /products/{id}:
       get:
         summary: Retrieve one product
         operationId: getProduct
         parameters:
           - name: id
             in: path
             required: true
             type: string
         x-google-backend:
           address: BACKEND_URL_PLACEHOLDER
           path_translation: APPEND_PATH_TO_ADDRESS
           protocol: h2
         responses:
           "200":
             description: A single product
           "404":
             description: No such product
   ```

3. Sustituí la dirección real del backend.

   ```bash
   sed -i "s|BACKEND_URL_PLACEHOLDER|${BACKEND_URL}|g" openapi2-run.yaml
   grep address openapi2-run.yaml
   ```

4. Creá la API, después un config, y después el gateway. Notá que son tres objetos distintos — esa separación es lo que hace posibles los lanzamientos versionados y reversibles.

   ```bash
   gcloud api-gateway apis create catalog-api

   gcloud api-gateway api-configs create catalog-cfg-v1 \
     --api=catalog-api \
     --openapi-spec=openapi2-run.yaml \
     --backend-auth-service-account="$GW_SA"

   gcloud api-gateway gateways create catalog-gw \
     --api=catalog-api \
     --api-config=catalog-cfg-v1 \
     --location="$REGION"
   ```

   Esperado (abreviado; el paso del config tarda entre 1 y 3 minutos):

   ```
   Waiting for API Config [catalog-cfg-v1] to be created for API [catalog-api]...done.
   Waiting for API Gateway [catalog-gw] to be created...done.
   ```

5. Leé el hostname público y llamá a la API **sin ninguna credencial de Google**.

   ```bash
   export GW_HOST="$(gcloud api-gateway gateways describe catalog-gw \
     --location="$REGION" --format='value(defaultHostname)')"
   echo "$GW_HOST"

   curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products"
   ```

   Esperado: `200` — y `GW_HOST` se ve como `catalog-gw-1a2b3c4d.uc.gateway.dev`.

6. Confirmá que el backend sigue cerrado. El gateway no abrió el servicio; lo *fronteó*.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "$BACKEND_URL"
   ```

   Esperado: sigue en `403`.

7. Inspeccioná qué sabe ahora la plataforma sobre la API como objeto.

   ```bash
   gcloud api-gateway apis describe catalog-api \
     --format='yaml(name, managedService, state)'
   ```

   Esperado:

   ```yaml
   managedService: catalog-api-1a2b3c4d5e6f7.apigateway.my-proj.cloud.goog
   name: projects/my-proj/locations/global/apis/catalog-api
   state: ACTIVE
   ```

   Guardalo:

   ```bash
   export MANAGED_SERVICE="$(gcloud api-gateway apis describe catalog-api \
     --format='value(managedService)')"
   ```

### Preguntas de control

- **Q2.1** — Después del paso 5, un llamador anónimo obtiene `200` a través del gateway mientras que el paso 6 sigue devolviendo `403` directo. Describí la postura de seguridad que esto crea y por qué un CISO la preferiría a `--allow-unauthenticated` en Cloud Run.
- **Q2.2** — El paso 4 crea tres objetos separados: API, API config y gateway. ¿Qué capacidad de negocio te da separar el *config* del *gateway* el día del lanzamiento?
- **Q2.3** — El equipo quiere mover `catalog-backend` de Cloud Run a un servicio de GKE el trimestre que viene. ¿Cuál de los tres objetos cambia, y qué tienen que hacer los consumidores de la API?
- **Q2.4** — Nombrá el término de negocio para "los consumidores dependen del contrato, no de la implementación", y dá una consecuencia de costo de *no* tenerlo.
- **Q2.5** — Ahora mismo cualquier persona en internet que descubra `GW_HOST` puede llamar a `/products` indefinidamente. ¿Qué dos funciones comerciales siguen siendo imposibles?

---

## Ejercicio 3 — De endpoint a producto: identidad y cuota

Este es el ejercicio donde aparece el modelo de negocio. Una consumer key no es principalmente un control de seguridad — es un *medidor*. Las cuotas no son principalmente una defensa — son la forma de vender Bronze, Silver y Gold.

### Pasos

1. Extendé el contrato con una definición de seguridad por API key y un modelo de cuotas. Reemplazá `openapi2-run.yaml` con esta versión — notá los dos bloques nuevos de nivel superior y el `security` y `x-google-quota` por operación:

   ```yaml
   swagger: "2.0"
   info:
     title: catalog-api
     description: Product catalog exposed as a managed, governed, metered API
     version: "1.1.0"
   host: GATEWAY_HOST_PLACEHOLDER
   schemes:
     - https
   produces:
     - application/json
   securityDefinitions:
     api_key:
       type: "apiKey"
       name: "key"
       in: "query"
   paths:
     /products:
       get:
         summary: List products in the catalog
         operationId: listProducts
         security:
           - api_key: []
         x-google-quota:
           metricCosts:
             read-requests: 1
         x-google-backend:
           address: BACKEND_URL_PLACEHOLDER
           protocol: h2
         responses:
           "200":
             description: A list of products
           "429":
             description: Quota exceeded for this consumer
     /products/{id}:
       get:
         summary: Retrieve one product
         operationId: getProduct
         security:
           - api_key: []
         parameters:
           - name: id
             in: path
             required: true
             type: string
         x-google-quota:
           metricCosts:
             read-requests: 1
         x-google-backend:
           address: BACKEND_URL_PLACEHOLDER
           path_translation: APPEND_PATH_TO_ADDRESS
           protocol: h2
         responses:
           "200":
             description: A single product
           "429":
             description: Quota exceeded for this consumer
   x-google-management:
     metrics:
       - name: "read-requests"
         displayName: "Catalog read requests"
         valueType: INT64
         metricKind: DELTA
     quota:
       limits:
         - name: "read-limit"
           metric: "read-requests"
           unit: "1/min/{project}"
           values:
             STANDARD: 5
   ```

2. Completá los dos placeholders. El campo `host` tiene que coincidir con el hostname del gateway — la aplicación de cuotas está atada al servicio gestionado, que a su vez está atado a ese host.

   ```bash
   sed -i "s|BACKEND_URL_PLACEHOLDER|${BACKEND_URL}|g;s|GATEWAY_HOST_PLACEHOLDER|${GW_HOST}|g" \
     openapi2-run.yaml
   head -8 openapi2-run.yaml
   ```

3. Publicá una **nueva revisión del config** y hacé rodar el gateway sobre ella. El config anterior queda intacto.

   ```bash
   gcloud api-gateway api-configs create catalog-cfg-v2 \
     --api=catalog-api \
     --openapi-spec=openapi2-run.yaml \
     --backend-auth-service-account="$GW_SA"

   gcloud api-gateway gateways update catalog-gw \
     --api=catalog-api \
     --api-config=catalog-cfg-v2 \
     --location="$REGION"
   ```

4. Habilitá el servicio gestionado en el proyecto. Sin esto, la verificación de keys y el conteo de cuotas no pueden funcionar.

   ```bash
   gcloud services enable "$MANAGED_SERVICE"
   ```

5. Llamá a la API sin key. Ahora sos un consumidor no registrado.

   ```bash
   curl -s "https://${GW_HOST}/products" | head -c 400; echo
   ```

   Esperado:

   ```json
   {"code":16,"message":"Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.","details":[...]}
   ```

6. Emití una credencial de consumidor, restringida solo a esta API.

   ```bash
   gcloud services api-keys create \
     --display-name="partner-bronze-key" \
     --api-target="service=${MANAGED_SERVICE}"

   export KEY_NAME="$(gcloud services api-keys list \
     --filter='displayName="partner-bronze-key"' \
     --format='value(name)' --limit=1)"

   export API_KEY="$(gcloud services api-keys get-key-string "$KEY_NAME" \
     --format='value(keyString)')"
   ```

7. Llamá como consumidor registrado.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products?key=${API_KEY}"
   ```

   Esperado: `200`

8. Excedé el tier. El límite es de 5 solicitudes por minuto; mandá 8.

   ```bash
   for i in $(seq 1 8); do
     printf '%d ' "$i"
     curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products?key=${API_KEY}"
   done
   ```

   Esperado (la propagación puede tardar un minuto o dos después del paso 4; reintentá si las 8 devuelven `200`):

   ```
   1 200
   2 200
   3 200
   4 200
   5 200
   6 429
   7 429
   8 429
   ```

9. Leé el cuerpo del rechazo — la redacción importa para el vocabulario del examen.

   ```bash
   curl -s "https://${GW_HOST}/products?key=${API_KEY}" | head -c 300; echo
   ```

   Esperado:

   ```json
   {"code":8,"message":"Quota exceeded for quota metric 'Catalog read requests' and limit 'read-limit' of service 'catalog-api-....apigateway.my-proj.cloud.goog' for consumer 'project_number:123456789012'.","details":[...]}
   ```

10. Modelá un segundo tier sin tocar una sola línea de código del backend. Editá únicamente el bloque `values`:

    ```yaml
       quota:
         limits:
           - name: "read-limit"
             metric: "read-requests"
             unit: "1/min/{project}"
             values:
               STANDARD: 5
    ```

    Cambiá `STANDARD: 5` por `STANDARD: 60`, después publicá `catalog-cfg-v3` y actualizá el gateway como en el paso 3. Volvé a correr el paso 8 y confirmá que ahora las ocho llamadas devuelven `200`.

### Preguntas de control

- **Q3.1** — El error del paso 5 dice "unregistered callers … without established identity". Traducí eso a una oración de negocio sobre qué le da una API key al *dueño* de la API (no al consumidor).
- **Q3.2** — El paso 8 produjo `429` en la sexta llamada. Dá dos razones de negocio distintas por las que una organización rechaza deliberadamente solicitudes que tiene capacidad de servir.
- **Q3.3** — El paso 10 creó un nuevo tier comercial sin un deploy del backend. ¿Qué línea de costo elimina eso, y qué le hace al time-to-market de un cambio de precios?
- **Q3.4** — En el paso 6 la key se restringió con `--api-target`. Si una key filtrada está restringida a un solo servicio gestionado, ¿cuál es el radio de impacto, y cómo cambia eso la conversación con el equipo de seguridad del partner?
- **Q3.5** — Las API keys identifican a la *aplicación que llama*; no autentican a un *usuario final*. Nombrá el estándar que agregarías para autorización de usuario final, y dá un escenario de negocio que lo requiera.

---

## Ejercicio 4 — La fachada: modernizar sin reescribir

Lo comercialmente más importante que hace una capa de API es permitirte vender, exponer y reformar un sistema que no tenés permitido tocar — un mainframe, un servicio SOAP, un ERP de un proveedor. Apigee es la plataforma de gestión de APIs de ciclo de vida completo de Google Cloud para exactamente esto.

> **¿No tenés organización de Apigee?** Hacé la *variante en papel* en la sección "Variante en papel" de abajo y respondé las mismas preguntas. El bundle es real y sintácticamente válido; leerlo es la mayor parte del aprendizaje.

### Pasos

1. Confirmá que tenés una organización de Apigee y un entorno.

   ```bash
   export APIGEE_ORG="$PROJECT_ID"
   export APIGEE_ENV="eval"
   export TOKEN="$(gcloud auth print-access-token)"

   gcloud apigee organizations list
   gcloud apigee environments list --organization="$APIGEE_ORG"
   ```

   Esperado:

   ```
   NAME       ENVIRONMENTS
   my-proj    eval
   ```

2. Construí el bundle del proxy en disco. El layout de directorios es fijo — Apigee rechaza cualquier otro.

   ```bash
   mkdir -p apiproxy/proxies apiproxy/targets apiproxy/policies
   ```

3. `apiproxy/catalog-v1.xml` — el manifiesto del bundle:

   ```xml
   <APIProxy revision="1" name="catalog-v1">
     <DisplayName>catalog-v1</DisplayName>
     <Description>Managed facade over the legacy catalog system of record</Description>
   </APIProxy>
   ```

4. `apiproxy/proxies/default.xml` — el lado que mira al consumidor. Leé el `PreFlow` de arriba abajo: *es* el contrato comercial, expresado como política.

   ```xml
   <ProxyEndpoint name="default">
     <PreFlow name="PreFlow">
       <Request>
         <Step><Name>SA-ProtectBackend</Name></Step>
         <Step><Name>VA-VerifyKey</Name></Step>
         <Step><Name>Q-ProductQuota</Name></Step>
         <Step><Name>AM-StripCredential</Name></Step>
       </Request>
       <Response/>
     </PreFlow>
     <Flows>
       <Flow name="ListProducts">
         <Description>List catalog products</Description>
         <Condition>(proxy.pathsuffix MatchesPath "/products") and (request.verb = "GET")</Condition>
         <Request/>
         <Response/>
       </Flow>
       <Flow name="GetProduct">
         <Description>Retrieve a single product</Description>
         <Condition>(proxy.pathsuffix MatchesPath "/products/*") and (request.verb = "GET")</Condition>
         <Request/>
         <Response/>
       </Flow>
     </Flows>
     <PostFlow name="PostFlow">
       <Request/>
       <Response>
         <Step><Name>AM-AddCacheHeaders</Name></Step>
       </Response>
     </PostFlow>
     <HTTPProxyConnection>
       <BasePath>/catalog/v1</BasePath>
     </HTTPProxyConnection>
     <RouteRule name="default">
       <TargetEndpoint>default</TargetEndpoint>
     </RouteRule>
   </ProxyEndpoint>
   ```

5. `apiproxy/targets/default.xml` — el lado que mira al proveedor. Sustituí tu URL de Cloud Run; en una modernización real este es el host legacy.

   ```xml
   <TargetEndpoint name="default">
     <HTTPTargetConnection>
       <URL>https://catalog-backend-abc123-uc.a.run.app</URL>
       <Properties>
         <Property name="connect.timeout.millis">5000</Property>
         <Property name="io.timeout.millis">15000</Property>
       </Properties>
     </HTTPTargetConnection>
   </TargetEndpoint>
   ```

6. `apiproxy/policies/SA-ProtectBackend.xml` — el sistema legacy tiene una capacidad fija que no podés hacer crecer. Suavizá el tráfico antes de que llegue.

   ```xml
   <SpikeArrest continueOnError="false" enabled="true" name="SA-ProtectBackend">
     <DisplayName>SA-ProtectBackend</DisplayName>
     <Properties/>
     <Rate>30ps</Rate>
     <UseEffectiveCount>true</UseEffectiveCount>
   </SpikeArrest>
   ```

7. `apiproxy/policies/VA-VerifyKey.xml` — establece *quién* está llamando y carga sus derechos de uso.

   ```xml
   <VerifyAPIKey continueOnError="false" enabled="true" name="VA-VerifyKey">
     <DisplayName>VA-VerifyKey</DisplayName>
     <Properties/>
     <APIKey ref="request.queryparam.apikey"/>
   </VerifyAPIKey>
   ```

8. `apiproxy/policies/Q-ProductQuota.xml` — la comercialmente interesante. Cada valor es una *referencia* al API product al que el consumidor está suscripto. Cambiá el producto, cambiás el plan; el proxy queda intacto.

   ```xml
   <Quota continueOnError="false" enabled="true" name="Q-ProductQuota" type="calendar">
     <DisplayName>Q-ProductQuota</DisplayName>
     <Properties/>
     <Identifier ref="verifyapikey.VA-VerifyKey.client_id"/>
     <Allow countRef="verifyapikey.VA-VerifyKey.apiproduct.developer.quota.limit"/>
     <Interval ref="verifyapikey.VA-VerifyKey.apiproduct.developer.quota.interval"/>
     <TimeUnit ref="verifyapikey.VA-VerifyKey.apiproduct.developer.quota.timeunit"/>
     <Distributed>true</Distributed>
     <Synchronous>true</Synchronous>
     <StartTime>2026-01-01 00:00:00</StartTime>
   </Quota>
   ```

9. `apiproxy/policies/AM-StripCredential.xml` — la key del consumidor es una credencial de negocio; el backend nunca la necesita.

   ```xml
   <AssignMessage continueOnError="false" enabled="true" name="AM-StripCredential">
     <DisplayName>AM-StripCredential</DisplayName>
     <Properties/>
     <Remove>
       <QueryParams>
         <QueryParam name="apikey"/>
       </QueryParams>
     </Remove>
     <AssignTo createNew="false" transport="http" type="request"/>
   </AssignMessage>
   ```

10. `apiproxy/policies/AM-AddCacheHeaders.xml` — moldea la respuesta para los consumidores sin pedirle nada al equipo de legacy.

    ```xml
    <AssignMessage continueOnError="false" enabled="true" name="AM-AddCacheHeaders">
      <DisplayName>AM-AddCacheHeaders</DisplayName>
      <Properties/>
      <Set>
        <Headers>
          <Header name="Cache-Control">public, max-age=60</Header>
          <Header name="X-API-Version">v1</Header>
        </Headers>
      </Set>
      <AssignTo createNew="false" transport="http" type="response"/>
    </AssignMessage>
    ```

11. Empaquetá e importá. La API REST de gestión es la fuente de verdad para importar bundles.

    ```bash
    zip -r catalog-v1.zip apiproxy -x '*.DS_Store'

    curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -F "file=@catalog-v1.zip" \
      "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apis?action=import&name=catalog-v1" \
      | jq '{name, revision}'
    ```

    Esperado:

    ```json
    {
      "name": "catalog-v1",
      "revision": "1"
    }
    ```

12. Desplegá la revisión en el entorno.

    ```bash
    gcloud apigee apis deploy 1 \
      --api=catalog-v1 \
      --environment="$APIGEE_ENV" \
      --organization="$APIGEE_ORG"

    gcloud apigee deployments list \
      --organization="$APIGEE_ORG" --environment="$APIGEE_ENV"
    ```

    Esperado:

    ```
    API          REVISION  ENVIRONMENT  STATE
    catalog-v1   1         eval         READY
    ```

13. Llamalo sin key a través del hostname de runtime de Apigee (el hostname de tu organización de evaluación aparece en la consola bajo *Environment groups*):

    ```bash
    export APIGEE_HOST="<your-environment-group-hostname>"
    curl -s "https://${APIGEE_HOST}/catalog/v1/products" | jq .
    ```

    Esperado:

    ```json
    {
      "fault": {
        "faultstring": "Failed to resolve API Key variable request.queryparam.apikey",
        "detail": {
          "errorcode": "steps.oauth.v2.FailedToResolveAPIKey"
        }
      }
    }
    ```

    El proxy está vivo y rechazando tráfico no identificado. El ejercicio 5 emite la key.

### Variante en papel (sin organización de Apigee)

Leé el bundle de arriba y respondé esto por escrito antes de mirar las respuestas:

- Rastreá una sola solicitud a través del `PreFlow`. En cada uno de los cuatro pasos, decí qué gana una *persona interesada del negocio*.
- El backend legacy devuelve XML y el partner requiere JSON. ¿Qué parte del bundle cambia, y el backlog de qué equipo *no* se toca?
- La política `Q-ProductQuota` no contiene ningún número. ¿Dónde viven los números, y por qué esa es la decisión de diseño importante?

### Preguntas de control

- **Q4.1** — Los pasos 4–10 agregan seguridad, limitación de tasa, cuota, higiene de credenciales y headers de respuesta *sin un solo cambio en `catalog-backend`*. Nombrá el patrón de modernización que esto implementa y el riesgo que le quita a una migración de mainframe o ERP.
- **Q4.2** — `SA-ProtectBackend` (Spike Arrest) y `Q-ProductQuota` (Quota) rechazan tráfico las dos. Explicá la diferencia de *propósito* — una es operativa, la otra comercial.
- **Q4.3** — En `Q-ProductQuota`, `Allow`, `Interval` y `TimeUnit` son todos atributos `ref=` que apuntan al API product. ¿Qué gana un equipo de ventas con esa indirección?
- **Q4.4** — El paso 11 importó la revisión `1` y el paso 12 la desplegó. Describí cómo lanzarías un cambio incompatible en una API de cara a partners manteniendo funcionando a los partners existentes.
- **Q4.5** — Un CFO pregunta por qué Apigee cuesta más que poner un proxy inverso nginx delante del servicio legacy. Dá tres capacidades de este bundle que un proxy inverso no gestionado no provee de fábrica.

---

## Ejercicio 5 — El producto, el developer, la app: donde empieza el ingreso

Un API proxy es plomería. Un **API product** es la unidad vendible: un paquete con nombre de operaciones con una cuota y una política de acceso. Esta distinción se toma directamente en el examen.

> **¿No tenés organización de Apigee?** Leé los payloads y después respondé las preguntas — son conceptuales.

### Pasos

1. Creá un producto Bronze. Notá que la cuota vive acá, no en el proxy.

   ```bash
   cat > product-bronze.json <<'EOF'
   {
     "name": "catalog-bronze",
     "displayName": "Catalog API — Bronze",
     "description": "Read-only catalog access for evaluation and small partners",
     "approvalType": "auto",
     "environments": ["eval"],
     "operationGroup": {
       "operationConfigType": "proxy",
       "operationConfigs": [
         {
           "apiSource": "catalog-v1",
           "operations": [
             { "resource": "/products", "methods": ["GET"] },
             { "resource": "/products/*", "methods": ["GET"] }
           ],
           "quota": { "limit": "100", "interval": "1", "timeUnit": "minute" }
         }
       ]
     },
     "attributes": [
       { "name": "access", "value": "public" },
       { "name": "tier",   "value": "bronze" }
     ]
   }
   EOF

   curl -s -X POST \
     -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d @product-bronze.json \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apiproducts" \
     | jq '{name, approvalType}'
   ```

   Esperado:

   ```json
   { "name": "catalog-bronze", "approvalType": "auto" }
   ```

2. Creá un producto Gold sobre el *mismo proxy* — distinta cuota, aprobación manual.

   ```bash
   sed -e 's/catalog-bronze/catalog-gold/' \
       -e 's/Catalog API — Bronze/Catalog API — Gold/' \
       -e 's/"approvalType": "auto"/"approvalType": "manual"/' \
       -e 's/"limit": "100"/"limit": "10000"/' \
       -e 's/"value": "bronze"/"value": "gold"/' \
       product-bronze.json > product-gold.json

   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" -d @product-gold.json \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apiproducts" \
     | jq '{name, approvalType}'
   ```

3. Registrá un developer — este es el *partner*, la entidad en tu CRM.

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{
           "email": "ada@partner.example",
           "firstName": "Ada",
           "lastName": "Lovelace",
           "userName": "ada"
         }' \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers" \
     | jq '{email, status}'
   ```

4. Registrá una app para ese developer y suscribila a Bronze. La credencial se acuña acá.

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{ "name": "ada-mobile-catalog", "apiProducts": ["catalog-bronze"] }' \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps" \
     | jq '{name, credentials: [.credentials[] | {consumerKey, apiProducts: [.apiProducts[].apiproduct], status}]}'
   ```

   Esperado:

   ```json
   {
     "name": "ada-mobile-catalog",
     "credentials": [
       {
         "consumerKey": "aBc1DeF2gHi3JkL4mNo5PqR6sTu7",
         "apiProducts": ["catalog-bronze"],
         "status": "approved"
       }
     ]
   }
   ```

5. Extraé la key y llamá al proxy como Ada.

   ```bash
   export CONSUMER_KEY="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps/ada-mobile-catalog" \
     | jq -r '.credentials[0].consumerKey')"

   curl -s -o /dev/null -w '%{http_code}\n' \
     "https://${APIGEE_HOST}/catalog/v1/products?apikey=${CONSUMER_KEY}"
   ```

   Esperado: `200`

6. Comprobá que los derechos de uso se aplican desde el producto. No suscribas nada y probá de nuevo con una key falsa:

   ```bash
   curl -s "https://${APIGEE_HOST}/catalog/v1/products?apikey=not-a-real-key" | jq -r '.fault.faultstring'
   ```

   Esperado:

   ```
   Invalid ApiKey
   ```

7. Ascendé a Ada a Gold sin emitir una credencial nueva — el movimiento de ventas, ejecutado como una llamada a la API:

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{ "apiProducts": ["catalog-gold"] }' \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps/ada-mobile-catalog/keys/${CONSUMER_KEY}" \
     | jq '[.apiProducts[] | {apiproduct, status}]'
   ```

   Esperado — `catalog-gold` presente con `status` `pending` (Gold es `approvalType: manual`):

   ```json
   [
     { "apiproduct": "catalog-bronze", "status": "approved" },
     { "apiproduct": "catalog-gold",   "status": "pending" }
   ]
   ```

### Preguntas de control

- **Q5.1** — Un proxy (`catalog-v1`), dos productos (Bronze, Gold). Explicá en términos de negocio por qué el *producto* es el lugar correcto para la cuota y el proxy no.
- **Q5.2** — Bronze es `approvalType: auto`; Gold es `manual`. ¿Qué proceso comercial codifica cada uno, y qué le hace `auto` al costo de adquisición de partners?
- **Q5.3** — El paso 7 cambió una suscripción con una sola llamada a la API, sin deploy de código y sin rotación de keys. Nombrá tres equipos a los que esto les saca trabajo de encima en un upsell.
- **Q5.4** — Apigee incluye un **portal de desarrolladores** con registro autogestionado y documentación de referencia generada. ¿Qué única métrica de adopción mueve más un portal, y por qué esa métrica predice ingresos?
- **Q5.5** — La **monetización** de Apigee soporta planes de tarifa (basados en cuota fija, por llamada, participación en ingresos). Dá un modelo de negocio real para cada uno de esos tres y decí qué parte paga.
- **Q5.6** — Un retailer publica una API de inventario que sus revendedores incrustan en sus propias tiendas. Describí el valor creado para el retailer que no tiene nada que ver con cobrar por las llamadas.

---

## Ejercicio 6 — Medir la adopción: los datos que justifican el programa

No podés monetizar lo que no podés contar, y no podés conseguir presupuesto para lo que no podés mostrar. Este ejercicio extrae los números.

### Pasos

1. Generá una muestra de tráfico mixto contra la API de API Gateway del ejercicio 3 — éxitos y rechazos por cuota.

   ```bash
   for i in $(seq 1 25); do
     curl -s -o /dev/null "https://${GW_HOST}/products?key=${API_KEY}"
   done
   curl -s -o /dev/null "https://${GW_HOST}/products"          # unregistered
   curl -s -o /dev/null "https://${GW_HOST}/does-not-exist?key=${API_KEY}"
   ```

2. Leé los logs de solicitudes del gateway y contá resultados por código de estado.

   ```bash
   gcloud logging read \
     'resource.type="apigateway.googleapis.com/Gateway"
      AND timestamp>="'"$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"'"' \
     --limit=200 --format='value(httpRequest.status)' \
     | sort | uniq -c | sort -rn
   ```

   Forma esperada:

   ```
        20 200
         6 429
         1 404
         1 401
   ```

3. Descubrí qué métricas publica la plataforma para esta API en lugar de suponerlo. Preguntale a la API de Monitoring:

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/metricDescriptors?filter=metric.type%3Dstarts_with(%22serviceruntime.googleapis.com%22)" \
     | jq -r '.metricDescriptors[].type' | sort -u
   ```

   Forma esperada (un subconjunto):

   ```
   serviceruntime.googleapis.com/api/request_count
   serviceruntime.googleapis.com/api/request_latencies
   serviceruntime.googleapis.com/quota/rate/net_usage
   ```

4. Leé la vista de APIs consumidas, que está organizada *por consumidor* — esta es la forma que necesita un sistema de facturación.

   ```bash
   gcloud services list --enabled --filter="config.name:apigateway" --format='value(config.name)'
   ```

   Después abrí, en la consola, **APIs & Services → Enabled APIs → tu servicio gestionado → Metrics**, y poné el desglose en *Credential*. Notá que el tráfico se atribuye por API key, no por IP.

5. Si completaste los ejercicios 4/5, sacá el equivalente desde la analítica de Apigee — notá que las dimensiones son comerciales (`developer_app`, `api_product`), no de infraestructura.

   ```bash
   curl -s -H "Authorization: Bearer ${TOKEN}" \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/environments/${APIGEE_ENV}/stats/developer_app?select=sum(message_count),avg(total_response_time)&timeRange=$(date -u -d '1 day ago' +%m/%d/%Y)%2000:00~$(date -u +%m/%d/%Y)%2023:59&timeUnit=day" \
     | jq '.environments[0].dimensions[] | {app: .name, metrics: [.metrics[] | {name, values}]}'
   ```

   Forma esperada:

   ```json
   {
     "app": "ada-mobile-catalog",
     "metrics": [
       { "name": "sum(message_count)",       "values": [{"timestamp": 0, "value": "26.0"}] },
       { "name": "avg(total_response_time)", "values": [{"timestamp": 0, "value": "84.3"}] }
     ]
   }
   ```

6. Armá el scorecard de una página del programa. Completalo con tus propios números:

   | KPI | De dónde sale | Tu valor |
   |---|---|---|
   | Consumidores registrados | cantidad de developers / apps | |
   | Llamadas en el período | `sum(message_count)` / conteo de logs | |
   | Tasa de éxito | `2xx` ÷ total | |
   | Rechazos por cuota | cantidad de `429` | |
   | Latencia p50 / p99 | `request_latencies` | |
   | Consumidores por encima del 80% de su cuota | conteos por key vs límite | |

### Preguntas de control

- **Q6.1** — El paso 2 cuenta por código de estado; el paso 5 cuenta por `developer_app`. ¿Con cuál de los dos se puede generar una factura, y por qué esa es la diferencia entre monitoreo de infraestructura y analítica de APIs?
- **Q6.2** — Tu scorecard muestra tres consumidores sostenidamente al 95% de una cuota Bronze. ¿Cuál es la acción comercial, y qué equipo debería recibir esa señal automáticamente?
- **Q6.3** — Los rechazos por cuota saltan de 6/día a 4.000/día y los consumidores registrados no cambian. Dá dos explicaciones que compiten entre sí y decí qué verificarías primero.
- **Q6.4** — "Tiempo hasta la primera llamada exitosa" mide la brecha entre que un developer se registra y su primer `200`. Argumentá por qué es un mejor indicador adelantado de la salud del programa de APIs que el volumen total de llamadas.
- **Q6.5** — Una persona interesada quiere dar de baja `/products/{id}` en la v1. ¿Qué números de este ejercicio hacen que eso sea una decisión segura en lugar de una apuesta?

---

## Ejercicio 7 — El modelo de costo de integración (ejercicio en papel)

El argumento de negocio más citable a favor de las APIs es una cuenta aritmética. Hacela vos para poder reproducirla bajo la presión del examen.

### Pasos

1. Considerá una empresa con **n = 12** sistemas internos que necesitan intercambiar datos entre todos. En una arquitectura punto a punto, cada par necesita su propia integración a medida. Calculá la cantidad de integraciones:

   ```
   point_to_point(n) = n × (n − 1) / 2
   point_to_point(12) = 12 × 11 / 2 = ____
   ```

2. Ahora asumí que cada sistema expone **una** API y consume las de los demás a través de una capa compartida de gestión de APIs. Calculá la cantidad de interfaces a construir y mantener:

   ```
   api_mediated(n) = n
   api_mediated(12) = ____
   ```

3. Asigná costos. Usá cifras internas conservadoras: **$40.000** para construir una integración punto a punto a medida, y **$8.000/año** para mantenerla. Asumí que una interfaz mediada por API cuesta **$55.000** construirla (es un producto real: documentado, versionado, asegurado) y **$6.000/año** mantenerla.

   ```
   Point-to-point:  build = ____ × $40,000 = $________
                    annual maintenance = ____ × $8,000 = $________

   API-mediated:    build = ____ × $55,000 = $________
                    annual maintenance = ____ × $6,000 = $________
   ```

4. Calculá el costo total de propiedad a tres años para ambos, y el punto de equilibrio.

5. Ahora agregá el decimotercer sistema. Calculá el costo *marginal* de incorporarlo en cada arquitectura:

   ```
   point_to_point marginal = n new integrations = ____ × $40,000 = $________
   api_mediated  marginal = 1 new interface     =    1 × $55,000 = $________
   ```

6. Repetí el paso 1 y el paso 5 para **n = 30** y anotá ambos costos marginales.

### Preguntas de control

- **Q7.1** — Enunciá tus respuestas a los pasos 1, 2 y 5. ¿Cuál es la *forma* de cada curva de costo a medida que crece `n`?
- **Q7.2** — Con `n = 12` el costo de construcción mediado por API es más alto por interfaz. Explicale a un CFO por qué igual lo recomendarías, usando el número del paso 5.
- **Q7.3** — El modelo de arriba cuenta solo construcción y mantenimiento. Nombrá tres costos en los que incurre un patrimonio punto a punto y que este modelo omite por completo.
- **Q7.4** — Una adquisición agrega 8 sistemas de un día para el otro. ¿Qué arquitectura convierte la integración en un proyecto y cuál la convierte en un onboarding? Cuantificá con las cifras de `n = 30`.
- **Q7.5** — Esta aritmética es el caso interno. Enunciá el caso externo — el argumento de ingresos — en dos oraciones.

---

## Ejercicio 8 — Simulacro de selección de producto

El examen evalúa si podés hacer coincidir una situación de negocio con el producto correcto de Google Cloud. Hacé esto a libro cerrado.

### Pasos

1. Para cada escenario, anotá (a) el producto que recomendarías, y (b) la única oración de justificación de negocio.

   | # | Escenario |
   |---|---|
   | S1 | Un banco tiene que exponer APIs de cuentas a fintechs terceras con licencia bajo regulación de open banking, con un portal autogestionado, SLAs por partner, consentimiento basado en OAuth e informes trimestrales de uso para el regulador. |
   | S2 | Una startup tiene tres servicios de Cloud Run y quiere un único hostname HTTPS, API keys y límites de tasa simples por key. No se le va a facturar a nadie por las llamadas. |
   | S3 | Una telco corre su runtime de APIs dentro de sus propios clusters de Kubernetes en dos centros de datos on-premises por razones de residencia de datos, pero quiere ciclo de vida, analítica y portal de APIs gestionados por Google. |
   | S4 | Un servicio gRPC corriendo en GKE necesita un proxy autenticador con contrato OpenAPI/gRPC e integración con Cloud Monitoring, desplegado como sidecar junto a la carga de trabajo. |
   | S5 | Una empresa de logística quiere cobrar a los transportistas $0,002 por consulta de seguimiento, con descuentos por volumen escalonados y facturas mensuales generadas a partir del uso real. |
   | S6 | Un servicio SOAP de inventario de 30 años de antigüedad no se puede modificar. Los equipos de mobile necesitan JSON REST, y el host SOAP se funde por encima de 40 solicitudes por segundo. |
   | S7 | Los equipos internos reconstruyen una y otra vez la misma integración de consulta de clientes porque nadie sabe que la existente ya existe. |

2. Para S1, S5 y S6, nombrá además la capacidad *específica* que hace correcta tu elección — una política, una funcionalidad o un componente, no solo el nombre del producto.

3. Ordená S1–S7 según la fuerza del caso a favor de gestión completa de APIs frente a un gateway simple. Justificá los dos extremos.

### Preguntas de control

- **Q8.1** — Dá tu elección de producto y su justificación para los siete escenarios.
- **Q8.2** — Enunciá el límite en una oración: ¿cuándo alcanza con API Gateway y cuándo una organización realmente necesita Apigee?
- **Q8.3** — Dos escenarios de arriba *no* son realmente sobre tecnología. Identificalos y decí sobre qué son.
- **Q8.4** — Un colega dice "un API gateway y la gestión de APIs son lo mismo". Corregilo en tres oraciones.

---

## Ejercicio 9 — Desmantelamiento

Ejecutá esto. Los entornos de Apigee se facturan por hora; las API keys son credenciales.

```bash
# API Gateway
gcloud api-gateway gateways delete catalog-gw --location="$REGION" --quiet
gcloud api-gateway api-configs delete catalog-cfg-v3 --api=catalog-api --quiet 2>/dev/null
gcloud api-gateway api-configs delete catalog-cfg-v2 --api=catalog-api --quiet
gcloud api-gateway api-configs delete catalog-cfg-v1 --api=catalog-api --quiet
gcloud api-gateway apis delete catalog-api --quiet

# Credential
gcloud services api-keys delete "$KEY_NAME" --quiet

# Backend and identity
gcloud run services delete catalog-backend --region="$REGION" --quiet
gcloud iam service-accounts delete "$GW_SA" --quiet

# Apigee (only if you completed exercises 4-5)
gcloud apigee apis undeploy 1 --api=catalog-v1 --environment="$APIGEE_ENV" \
  --organization="$APIGEE_ORG" --quiet 2>/dev/null
for p in catalog-bronze catalog-gold; do
  curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apiproducts/${p}" >/dev/null
done
curl -s -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example" >/dev/null
```

Confirmá que no quedó nada facturando:

```bash
gcloud api-gateway gateways list --location="$REGION"
gcloud run services list --region="$REGION"
```

Esperado: `Listed 0 items.` para ambos.

---

<details>
<summary><strong>Respuestas — expandí solo después de intentar todas las preguntas de control</strong></summary>

### Ejercicio 1 — El activo sin canal de distribución

**Q1.1** — No tiene **canal de distribución** ni **interfaz comercial**. La capacidad existe pero solo es alcanzable por quienes tengan identidades de Google Cloud en tu proyecto. Desde el punto de vista del negocio es un centro de costos interno: consume presupuesto de ingeniería y no produce valor externo, porque no hay forma de que un cliente, un partner o un desarrollador tercero lo consuma. El encuadre del examen es que una API convierte una capacidad interna en un *activo consumible y gobernado*.

**Q1.2** — Tendrías que otorgarles una identidad IAM en tu proyecto de Google Cloud (una cuenta de servicio, o `roles/run.invoker` sobre su principal). Riesgos: (1) **acoplar tu relación comercial a tu IAM de nube** — el partner ahora es un principal dentro de tu proyecto, y darlo de baja es un cambio de IAM, no la cancelación de una suscripción; (2) **sin granularidad** — `run.invoker` es todo o nada sobre el servicio entero; no podés otorgar lectura pero no escritura, o 1.000 llamadas pero no 1.000.000; (3) **sin medidor** — IAM autoriza pero no cuenta. Un tercer riesgo, muy citado: no escala organizacionalmente, ya que cada partner se convierte en una tarea de ingeniería de identidad a medida.

**Q1.3** — **Identidad del consumidor adjunta a cada solicitud.** Los logs de Cloud Run muestran solicitudes, IPs y user agents, pero nada que mapee una llamada a una *parte que paga*. Sin una credencial por consumidor presentada en cada llamada, la facturación basada en uso es imposible — podés contar solicitudes pero no atribuirlas.

**Q1.4** — Un backend privado que funciona es una *capacidad*; una API es un **contrato publicado, versionado y gobernado con consumidores identificados**, y solo el segundo se puede adoptar, medir, soportar o vender.

### Ejercicio 2 — Una puerta de entrada gestionada

**Q2.1** — El backend sigue cerrado a internet; el único camino hacia él pasa por un punto de control que termina TLS, aplica el contrato publicado y llama al backend usando una cuenta de servicio dedicada con mínimo privilegio (`roles/run.invoker`, nada más). Esto es defensa en profundidad: comprometer el gateway no otorga IAM sobre el proyecto, y el backend no se puede alcanzar ni siquiera si su URL se filtra. Comparado con `--allow-unauthenticated`, hay exactamente **una** puerta de entrada, así que los controles de seguridad, el logging y la limitación de tasa tienen un solo lugar donde vivir en lugar de reimplementarse por servicio.

**Q2.2** — **Lanzamientos seguros y reversibles.** El config es un artefacto inmutable y versionado; el gateway es un puntero a uno. Publicar un config nuevo no afecta al tráfico en vivo, y el rollback es reapuntar el gateway al config anterior — segundos, sin rebuild. Comercialmente esto baja el costo y el riesgo de cambiar el contrato, que es lo que hace viable iterar seguido sobre una API de cara a partners.

**Q2.3** — Solo cambia el **API config**: `x-google-backend.address` apunta al nuevo endpoint de GKE, publicás una nueva revisión del config y actualizás el gateway. **Los consumidores no hacen nada** — mismo hostname, mismos paths, mismas keys. Esta es la demostración concreta del desacoplamiento.

**Q2.4** — **Acoplamiento débil / abstracción — el contrato de la API es una fachada estable sobre una implementación cambiante.** Sin eso, cada cambio del backend se convierte en una migración coordinada con todos los consumidores: tenés que encontrarlos, notificarlos, lograr que agenden trabajo y correr ambas implementaciones hasta que el más lento migre. Ese costo de coordinación es lo que congela a los sistemas legacy en su lugar y suele ser la mayor línea oculta de un programa de modernización.

**Q2.5** — (1) **Cobrar por el uso** — no hay identidad de consumidor a la que atribuir las llamadas. (2) **Vender niveles de servicio diferenciados** — sin límites por consumidor, todos los llamadores obtienen el mismo acceso indiferenciado, así que no hay Bronze/Gold para vender ni SLA exigible. (También válido: revocar el acceso de un solo partner sin romperle a todos los demás.)

### Ejercicio 3 — De endpoint a producto

**Q3.1** — La key le da al dueño de la API **atribución**: cada llamada queda atada a un consumidor conocido, que es el prerrequisito para medir, facturar, limitar la tasa por consumidor, enviar avisos dirigidos de deprecación, investigar abusos y revocar selectivamente. Notá la dirección — una API key es *autenticación* débil pero *identificación* fuerte, y la identificación es lo que el negocio necesita.

**Q3.2** — (1) **Diferenciación comercial** — rechazar por encima del tier comprado es lo que hace reales a los tiers; si Bronze sirviera calladamente volúmenes de Gold, nadie compraría Gold. (2) **Proteger un recurso compartido y su costo** — un solo consumidor desbocado puede agotar la capacidad o disparar gasto no presupuestado para todos los demás, así que un techo exigible por consumidor convierte un pasivo sin límite en un costo predecible. (También válido: hacer cumplir el uso justo entre muchos consumidores chicos, y crear un disparador natural de upsell.)

**Q3.3** — Elimina el **costo de ingeniería de un cambio de precios** — sin trabajo de backend, sin code review, sin ventana de deploy, sin riesgo de regresión sobre la lógica de negocio. El time-to-market de un tier nuevo cae de un ciclo de release (semanas) a una publicación de configuración (minutos). La consecuencia estratégica: el precio pasa a ser una decisión de producto sobre la que el negocio puede iterar, en lugar de un proyecto de ingeniería que tiene que hacer cola.

**Q3.4** — El radio de impacto se limita a ese único servicio gestionado: la key no se puede usar contra ninguna otra API del proyecto, y no lleva permisos de IAM. La conversación con el partner cambia de "tenemos una brecha" a "rotamos una credencial acotada a una API de solo lectura", y la revocación es un solo delete que no afecta a nadie más. Este es el valor práctico de credenciales que son *angostas por construcción*.

**Q3.5** — **OAuth 2.0** (habitualmente con OpenID Connect / tokens bearer JWT). Se requiere siempre que la API opere sobre datos que pertenecen a un usuario final y no a la empresa que llama — open banking (un cliente autoriza a una fintech a leer *su* cuenta), historias clínicas, o cualquier delegación tipo "iniciar sesión con X". La distinción que quiere el examen: la API key dice *qué app*, OAuth dice *qué usuario, y a qué consintió*.

### Ejercicio 4 — La fachada

**Q4.1** — Este es el patrón de **fachada de API** (en un contexto de migración, el patrón **strangler fig**: se agrega capacidad nueva por delante del sistema legacy, que se va reemplazando progresivamente detrás de una interfaz que no cambia). El riesgo que elimina es la **reescritura big-bang**: en lugar de un reemplazo plurianual de todo-o-nada de un sistema de registro — la fuente clásica de programas de transformación fallidos — la organización entrega valor de forma incremental, mantiene el sistema legacy funcionando y puede cambiar la implementación después sin renegociar con un solo consumidor.

**Q4.2** — **Spike Arrest es protección operativa**: suaviza las ráfagas hasta una tasa que el backend pueda sobrevivir físicamente, protegiendo la disponibilidad de todos sin importar quién llama. Es sobre *capacidad*. **Quota es un control comercial**: aplica el volumen al que un consumidor específico tiene derecho en una ventana de tiempo de negocio (por minuto, día o mes), está atada a un API product, y excederla es un evento *contractual* que puede disparar un upsell. Es sobre *derecho de uso*. Se usan juntas con frecuencia: Spike Arrest protege el sistema, Quota hace cumplir el acuerdo.

**Q4.3** — Los términos comerciales viven en el **API product**, no en el código. Ventas puede crear un plan nuevo, cambiar un límite o mover un cliente entre tiers como un cambio de datos, sin revisión del proxy, sin despliegue y sin ticket de ingeniería. El principio general: el proxy codifica *cómo funciona la API*; el producto codifica *qué se vendió*. Mantener lo segundo fuera de lo primero es lo que permite que el negocio se mueva a velocidad de negocio.

**Q4.4** — Publicalo como una **versión nueva con un base path nuevo** (`/catalog/v2`) como una revisión separada del proxy y, típicamente, un API product separado. Los partners existentes siguen llamando a `/catalog/v1` sin que nada los toque. Después: anunciá una ventana de deprecación, usá la analítica para ver exactamente qué apps siguen llamando a v1, contactá a esos developers específicos, y retirá v1 recién cuando su tráfico sea efectivamente cero. El versionado más la analítica por consumidor es lo que convierte a la deprecación en un proceso gestionado y no en una caída de servicio.

**Q4.5** — Tres cualesquiera de: (1) **identidad y derechos de uso del consumidor** — `VerifyAPIKey` resuelve al llamador a una app registrada y carga lo que compró; nginx no tiene concepto de developer, app ni producto. (2) **Cuota manejada por producto** — límites que son datos de negocio, modificables sin tocar el proxy. (3) **Analítica de negocio** — uso por developer, app y API product, que es sobre lo que se construyen las facturas y los informes de adopción. (4) **Portal de desarrolladores y onboarding autogestionado** — un canal de distribución, no solo un proxy. (5) **Monetización** — planes de tarifa y facturación. (6) **Gobierno de ciclo de vida completo** — bundles versionados, entornos, promoción, historial de despliegues y auditoría. El encuadre que aterriza con un CFO: nginx mueve paquetes; la gestión de APIs opera un *canal de negocio*, y la alternativa es construir y mantener esas seis cosas vos mismo.

### Ejercicio 5 — Producto, developer, app

**Q5.1** — El proxy es un **activo técnico** — una implementación, compartida. El producto es un **empaquetado comercial** de ese activo — un paquete con nombre de operaciones con límites y una política de acceso. Poner la cuota en el proxy significaría un proxy por punto de precio: código duplicado, bugs duplicados y un deploy por cada cambio comercial. Ponerla en el producto significa que una implementación se puede vender de muchas formas, que es exactamente cómo funcionan los productos físicos (misma fábrica, distintos SKUs).

**Q5.2** — `auto` codifica **autoservicio sin fricción**: un developer se registra y está llamando a la API en minutos, con la cuota como baranda de seguridad. `manual` codifica una **compuerta de aprobación** — un contrato, una verificación crediticia, una revisión de cumplimiento, un acuerdo firmado de tratamiento de datos — antes de otorgar acceso de alto volumen o sensible. `auto` lleva el costo de adquisición de partners hacia cero porque no hay una persona en el circuito, que es todo el argumento económico de un portal de desarrolladores: la adquisición escala sin sumar personal.

**Q5.3** — Ingeniería (sin cambio de código), release/operaciones (sin despliegue) y el propio equipo de integración del partner (sin rotación de credenciales, sin cambio del cliente). Con frecuencia también revisión de seguridad, ya que no se emite ninguna credencial nueva. El upsell pasa a ser un **cambio de configuración hecho por el equipo de cuenta**, que es la diferencia entre un upsell que lleva un trimestre y uno que lleva una tarde.

**Q5.4** — **Tiempo hasta la primera llamada exitosa** (y, aguas arriba, la conversión de registro a integración). Predice ingresos porque la adopción de APIs es un embudo: los developers que no consiguen un `200` rápido abandonan y evalúan a un competidor, y los que *sí* integran quedan embebidos y son difíciles de desplazar. Un portal con keys autogestionadas, documentación de referencia que funciona y una consola de prueba comprime ese intervalo de días de correos a minutos, lo que sube la tasa de conversión en la boca del embudo — y todos los números de ingreso aguas abajo son un porcentaje de eso.

**Q5.5** — (1) **Cuota fija / suscripción**: un proveedor de datos de mercado cobra $2.000/mes por acceso a una API de cotizaciones financieras — paga el *consumidor* una tarifa fija. (2) **Por llamada / pago por uso**: una API de validación de direcciones o de SMS cobra por solicitud — el *consumidor* paga en proporción al uso. (3) **Participación en ingresos**: la API de reservas de un agregador de viajes le paga al *developer* una comisión por cada reserva completada que origine — acá el *proveedor de la API le paga al consumidor*, porque el consumidor es un canal de distribución. La idea relevante para el examen: monetizar no siempre significa cobrar; a veces la API te compra alcance.

**Q5.6** — **Distribución y fidelización del canal.** Cada tienda de un revendedor que incrusta la API de inventario se convierte en una superficie de venta que el retailer no tuvo que construir ni dotar de personal, mostrando su stock en vivo a clientes que nunca habría alcanzado directamente. Efectos secundarios: los datos del retailer pasan a ser la fuente de verdad del revendedor (costo de cambio), y la telemetría de uso de la API le da al retailer señales de demanda de todo el canal. Esta es la respuesta de "las APIs crean nuevos modelos de negocio / ecosistemas" a la que apunta la guía del examen — el valor es el alcance, no las tarifas.

### Ejercicio 6 — Medir la adopción

**Q6.1** — Solo el paso 5 (`developer_app`) puede generar una factura, porque atribuye cada llamada a una **entidad comercial** — una app registrada que pertenece a un developer conocido, suscripta a un API product conocido. El paso 2 cuenta *eventos*. El monitoreo de infraestructura responde "¿está sano el sistema?"; la analítica de APIs responde "¿quién usó qué, cuánto y bajo qué contrato?". La distinción del examen: una plataforma de gestión de APIs reporta sobre dimensiones de negocio (developer, app, producto, región) y no solo de infraestructura (instancia, código de estado, latencia).

**Q6.2** — La acción comercial es un **upsell proactivo al siguiente tier** — el consumidor está obteniendo valor de forma demostrable y está por chocar contra una pared que va a degradar su experiencia. La señal debería enrutarse automáticamente a ventas/gestión de cuentas (y al propio partner como notificación de uso). El principio general: la telemetría de cuotas es una señal de *ingresos*, no solo de operaciones, y la plataforma de APIs debería estar conectada al CRM.

**Q6.3** — (1) **Un consumidor legítimo cambió de comportamiento** — lanzó una nueva versión de su app, sacó el caché del lado del cliente, agregó un bucle de reintentos o corrió un trabajo por lotes; su negocio está bien y necesita un tier más grande. (2) **Una credencial está comprometida o se está abusando**, o un cliente quedó atrapado en una tormenta de reintentos que amplifica sus propias fallas. Verificar **primero**: si los rechazos están concentrados en una credencial o repartidos entre muchas. Una sola key → investigá a ese consumidor específicamente (compará su línea base de 7 días, mirá el patrón de llamadas y el user agent). Muchas keys → sospechá de un cambio del lado de la plataforma (una publicación de config que bajó un límite, o un failover regional) antes de culpar a los consumidores.

**Q6.4** — El volumen total de llamadas está dominado por consumidores que integraron hace mucho; puede verse saludable durante un año mientras la adquisición se detuvo por completo — es un indicador **rezagado** promediado sobre tu base instalada. El tiempo hasta la primera llamada exitosa mide la fricción que encuentra hoy un developer *nuevo*, así que se mueve en el momento en que el portal, la documentación, el sandbox o el onboarding empeoran, y condiciona directamente a todas las cohortes futuras. Si se degrada, el volumen de llamadas de mañana ya está perdido; solo que todavía no se ve en el gráfico de volumen.

**Q6.5** — Conteos de llamadas por operación (¿se usa `/products/{id}` siquiera?), y desglose por consumidor de *esas* llamadas (cuántas apps distintas, y de quiénes). Juntos convierten la decisión de "creemos que nadie lo usa" en una lista con nombres a la que podés contactar, una ventana de deprecación que podés dimensionar y un umbral de tráfico residual que podés vigilar hasta que llegue a cero. Sin eso, dar de baja un endpoint es una caída esperando a ser descubierta por un cliente.

### Ejercicio 7 — El modelo de costo de integración

**Q7.1** —
- Paso 1: `12 × 11 / 2 = 66` integraciones punto a punto.
- Paso 2: `12` interfaces mediadas por API.
- Paso 5 (agregando el 13.º sistema): punto a punto necesita **12** integraciones nuevas = **$480.000**; mediado por API necesita **1** = **$55.000**.

Forma: punto a punto crece **cuadráticamente** — `O(n²)` — mientras que el mediado por API crece **linealmente** — `O(n)`. Esa diferencia, y no el precio por interfaz, es todo el argumento.

TCO a tres años como referencia: punto a punto = `66 × $40.000 = $2.640.000` de construcción + `66 × $8.000 × 3 = $1.584.000` de mantenimiento = **$4.224.000**. Mediado por API = `12 × $55.000 = $660.000` de construcción + `12 × $6.000 × 3 = $216.000` = **$876.000**. El punto de equilibrio llega casi de inmediato con este `n`: los dos costos de construcción se cruzan aproximadamente en `n ≈ 3,75`, es decir que desde cuatro sistemas en adelante el enfoque de API ya es más barato de construir, antes de contar cualquier mantenimiento.

**Q7.2** — Porque el CFO no está comprando interfaces, está comprando **el costo del próximo cambio**. Con 12 sistemas el sobreprecio por interfaz es de $15.000; en el momento en que llega un decimotercer sistema — una adquisición, la adopción de un SaaS, un canal nuevo — el patrimonio punto a punto cobra $480.000 y el patrimonio de APIs cobra $55.000. Estás cambiando un pequeño sobreprecio único por un costo marginal permanentemente plano, y el costo marginal es lo que la empresa paga una y otra vez.

**Q7.3** — Tres cualesquiera de: (1) **overhead de coordinación y gestión de proyectos**, que a su vez crece con la cantidad de equipos tocados por cambio; (2) **costo de testing y regresión** — un cambio en un sistema tiene que reverificarse contra cada integración con partners; (3) **costo operativo y de incidentes** — 66 caminos a medida significa 66 modos de falla, 66 huecos de monitoreo y ningún lugar único para ver qué se rompió; (4) **costo de seguridad y cumplimiento** — autenticación, logging y auditoría reimplementados (de forma inconsistente) 66 veces, y 66 superficies para revisar; (5) **riesgo de conocimiento y de persona clave** — integraciones sin documentar cuyo único autor ya se fue; (6) **costo de oportunidad / time-to-market demorado** — el lanzamiento que se corre dos trimestres porque el trabajo de integración está encolado detrás de todo lo demás. Ese último suele ser el más grande y el menos medido.

**Q7.4** — Punto a punto lo convierte en un **proyecto**; mediado por API lo convierte en **onboarding**. Con `n = 30`: punto a punto son `30 × 29 / 2 = 435` integraciones, y el costo marginal del sistema 31 es `30 × $40.000 = $1.200.000`. Mediado por API son 30 interfaces, y el sistema 31 cuesta `1 × $55.000`. Agregar 8 sistemas de golpe a un patrimonio punto a punto de 30 sistemas son cientos de integraciones nuevas — un programa de integración post-adquisición medido en años, y una razón bien documentada de por qué las sinergias de M&A llegan tarde o no llegan.

**Q7.5** — Internamente, las APIs recortan el costo y el tiempo de conectar sistemas, convirtiendo la integración de un costo de proyecto cuadrático en un costo de onboarding lineal. Externamente, crean **nuevos ingresos y nuevo alcance**: capacidades que antes servían solo a tus propias aplicaciones se vuelven productos que podés vender directamente, o canales de distribución a través de los cuales los partners incrustan tu negocio en el suyo.

### Ejercicio 8 — Simulacro de selección de producto

**Q8.1** —

- **S1 — Apigee API Management.** Open banking necesita la pila comercial y de gobierno completa: un portal de desarrolladores para el autoservicio de partners, OAuth 2.0 con consentimiento del usuario final, productos y SLAs por partner, y analítica que produzca reportes de uso con calidad regulatoria. Esto es un *programa* de APIs, no un proxy.
- **S2 — API Gateway.** Backends serverless de Google Cloud, un hostname gestionado, API keys y cuotas simples, sin requisito de monetización ni portal. Elegir Apigee acá sería comprar capacidades que nadie necesita.
- **S3 — Apigee hybrid.** El plano de runtime corre en los propios clusters de Kubernetes del cliente (on-premises u otra nube) para que el tráfico y los datos queden en la jurisdicción requerida, mientras que el plano de gestión, la analítica y el portal siguen gestionados por Google.
- **S4 — Cloud Endpoints (ESPv2).** Un proxy configurado por OpenAPI/gRPC desplegado junto a la carga de trabajo en GKE/Compute Engine/App Engine, con autenticación e integración con Cloud Monitoring. Endpoints es la opción de *proxy que desplegás vos*; API Gateway es su primo serverless totalmente gestionado.
- **S5 — Apigee, con monetización.** El precio por llamada, los tiers por volumen y la facturación derivada del uso son exactamente para lo que existen los planes de tarifa y los reportes de monetización de Apigee.
- **S6 — Apigee.** Una fachada sobre un backend SOAP no modificable: transformación de mensajes a JSON/REST, más una política Spike Arrest para mantener el tráfico en los 40 rps que el host sobrevive. Tanto la mediación como la protección viven en el proxy, y el backlog del equipo de legacy queda intacto.
- **S7 — Apigee, específicamente su catálogo de APIs y su portal de desarrolladores.** El problema es la *descubribilidad*, y la solución es un catálogo gobernado donde una persona de ingeniería interna pueda encontrar, entender y autoservirse una API existente en lugar de reconstruirla.

**Q8.2** — **API Gateway** alcanza cuando necesitás una puerta de entrada gestionada para backends serverless de Google Cloud con keys y cuotas básicas y sin capa comercial; una organización necesita **Apigee** en el momento en que la API tiene *consumidores externos con contratos* — un portal, monetización, SLAs por partner, gobierno de ciclo de vida entre entornos, analítica de negocio o mediación sobre protocolos legacy.

**Q8.3** — **S5** y **S7**. S5 es una pregunta de **modelo de negocio** — la tecnología para servir consultas de seguimiento ya existe; lo que falta es medición, planes de tarifa y facturación. S7 es una pregunta **organizacional / de gobierno** — las integraciones duplicadas son un síntoma de que no hay catálogo, no hay propiedad y no hay descubrimiento, y ninguna configuración de gateway arregla una cultura donde nadie puede encontrar lo que ya existe. (S6 es una tercera respuesta legítima: es fundamentalmente una pregunta de estrategia de modernización, no de proxy.)

**Q8.4** — Un **gateway** de API es un componente de runtime: termina solicitudes, autentica, aplica límites de tasa y enruta a un backend. La **gestión** de APIs es una plataforma que incluye un gateway pero le agrega alrededor la capa de ciclo de vida y comercial — diseño y versionado, portal de desarrolladores y onboarding, API products y derechos de uso, analítica de negocio, monetización y gobierno entre entornos. En resumen: el gateway es la puerta, y la gestión de APIs es el negocio que opera el edificio — la puerta es necesaria pero no firma contratos, no manda facturas ni te dice quién entró.

</details>

---

## Fuentes

- Google Cloud, *Cloud Digital Leader Certification Exam Guide* — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Google Cloud, *Apigee documentation* — <https://cloud.google.com/apigee/docs>
- Google Cloud, *What is an API product?* — <https://cloud.google.com/apigee/docs/api-platform/publish/what-api-product>
- Google Cloud, *Quota policy* — <https://cloud.google.com/apigee/docs/api-platform/reference/policies/quota-policy>
- Google Cloud, *SpikeArrest policy* — <https://cloud.google.com/apigee/docs/api-platform/reference/policies/spike-arrest-policy>
- Google Cloud, *VerifyAPIKey policy* — <https://cloud.google.com/apigee/docs/api-platform/reference/policies/verify-api-key-policy>
- Google Cloud, *Apigee REST API reference* — <https://cloud.google.com/apigee/docs/reference/apis/apigee/rest>
- Google Cloud, *Apigee hybrid* — <https://cloud.google.com/apigee/docs/hybrid>
- Google Cloud, *API Gateway documentation* — <https://cloud.google.com/api-gateway/docs>
- Google Cloud, *API Gateway: OpenAPI overview* — <https://cloud.google.com/api-gateway/docs/openapi-overview>
- Google Cloud, *API Gateway: configuring quotas* — <https://cloud.google.com/api-gateway/docs/quotas-overview>
- Google Cloud, *Cloud Endpoints documentation* — <https://cloud.google.com/endpoints/docs>
- Google Cloud, *Cloud Run documentation* — <https://cloud.google.com/run/docs>
- Google Cloud, *Cloud Monitoring metrics list* — <https://cloud.google.com/monitoring/api/metrics_gcp>