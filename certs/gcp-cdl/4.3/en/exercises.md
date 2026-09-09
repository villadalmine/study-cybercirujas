# Cloud Digital Leader — Topic 4.3

## Describe the business value of application programming interfaces (APIs)

**Certification:** `gcp-cdl` — Google Cloud Digital Leader (exam guide version 2026-08-12)
**Exam weight:** 6.0
**Format:** guided exercises — numbered steps you execute, checkpoint questions after each block, answers collapsed at the end.

---

## Why this topic is worth doing hands-on

The Cloud Digital Leader exam asks *business* questions about APIs: why an organization exposes one, what it unlocks, which Google Cloud product fits which scenario. But the business answers are only memorable if you have seen the machinery that produces them. "APIs create new revenue streams" is a slogan until you have issued a consumer key, watched a quota return `429`, and read the per-consumer call counts that a finance team would invoice against.

These exercises build a small but production-shaped API programme:

| Exercise | What you build | Business capability it demonstrates |
|---|---|---|
| 1 | Private backend on Cloud Run | The asset that has value but no distribution |
| 2 | Managed gateway in front of it | Controlled exposure, single front door |
| 3 | API keys + quotas | Consumer identity, tiering, enforceable SLAs |
| 4 | Apigee proxy over a legacy target | Modernization without rewriting the system of record |
| 5 | API product, developer, app, key | Turning an endpoint into a *product* that can be sold |
| 6 | Usage analytics | Measuring adoption; the input to monetization |
| 7 | Integration-cost model (paper) | The `n(n-1)/2` argument, with numbers |
| 8 | Exam scenario drill | Product selection: Apigee vs API Gateway vs Endpoints |

---

## Prerequisites and cost

**Before you start:**

- A Google Cloud project with billing enabled, and `roles/owner` or an equivalent set on it.
- `gcloud` CLI installed and authenticated (`gcloud auth login`, `gcloud config set project <PROJECT_ID>`).
- `curl`, `jq`, and `zip` available in your shell.
- Exercises 4 and 5 additionally require an **Apigee organization**. Apigee has no permanent free tier; provisioning a time-limited *evaluation* organization is done from the console and takes 15–45 minutes. **Both exercises include a paper-only variant** if you do not want to provision Apigee — the exam does not require you to have run it, only to understand what it does.

**Cost note.** Cloud Run and API Gateway both have monthly free allowances that this lab stays comfortably inside; verify the current terms at <https://cloud.google.com/run/pricing> and <https://cloud.google.com/api-gateway/pricing>. Apigee is billed per environment-hour once an evaluation expires. **Exercise 9 is the teardown — run it.**

**On expected outputs.** Every output block below shows the *shape* you should get: field names, status codes, error bodies. Project IDs, hostnames, revision numbers, keys and timestamps will differ in your run. Compare structure, not strings.

---

## Exercise 1 — The asset with no distribution channel

A service that works but that nobody outside your team can safely call has zero external value. Start there, deliberately.

### Steps

1. Set your working variables. Use one shell for the whole lab.

   ```bash
   export PROJECT_ID="$(gcloud config get-value project)"
   export REGION="us-central1"
   export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
   echo "$PROJECT_ID / $PROJECT_NUMBER / $REGION"
   ```

2. Enable the services this lab needs.

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

   Expected: `Operation "operations/acat...." finished successfully.`

3. Deploy a backend service. Keep it **private** — no unauthenticated access. This is the point of the exercise.

   ```bash
   gcloud run deploy catalog-backend \
     --image=us-docker.pkg.dev/cloudrun/container/hello \
     --region="$REGION" \
     --no-allow-unauthenticated \
     --quiet
   ```

   Expected (abridged):

   ```
   Deploying container to Cloud Run service [catalog-backend] in project [my-proj] region [us-central1]
   ✓ Deploying new service... Done.
     ✓ Creating Revision...
     ✓ Routing traffic...
   Service [catalog-backend] revision [catalog-backend-00001-abc] has been deployed
   and is serving 100 percent of traffic.
   Service URL: https://catalog-backend-abc123-uc.a.run.app
   ```

4. Capture the URL and try to consume it the way an external partner would — anonymously.

   ```bash
   export BACKEND_URL="$(gcloud run services describe catalog-backend \
     --region="$REGION" --format='value(status.url)')"

   curl -s -o /dev/null -w '%{http_code}\n' "$BACKEND_URL"
   ```

   Expected: `403`

5. Now call it the way an internal engineer with a Google identity would.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
     "$BACKEND_URL"
   ```

   Expected: `200`

6. Ask the platform who has consumed this service, and how much. Try to answer "how many calls did partner X make last month?"

   ```bash
   gcloud logging read \
     'resource.type="cloud_run_revision" AND resource.labels.service_name="catalog-backend"' \
     --limit=3 --format='value(httpRequest.status, httpRequest.userAgent)'
   ```

   You will get request lines. You will **not** get a consumer identity you could invoice.

### Checkpoint questions

- **Q1.1** — Step 4 returned `403` and step 5 returned `200`. Both are "the service works." From a business standpoint, what does the service currently *not* have?
- **Q1.2** — A partner asks for access. With only what exists after step 5, what would you have to give them, and name two business risks of that.
- **Q1.3** — Finance asks you to bill three partners by consumption. Which single missing capability makes that impossible today?
- **Q1.4** — The exam guide frames APIs under "modernizing infrastructure and applications." Explain in one sentence why a *private, working* backend is not yet an API in the business sense.

---

## Exercise 2 — A managed front door

An API gateway is the control point where a technical endpoint becomes a governed interface: one hostname, one contract, one place to apply security, and one place that counts.

### Steps

1. Create a service account for the gateway and let it — and only it — invoke the backend.

   ```bash
   gcloud iam service-accounts create apigw-invoker \
     --display-name="API Gateway backend invoker"

   export GW_SA="apigw-invoker@${PROJECT_ID}.iam.gserviceaccount.com"

   gcloud run services add-iam-policy-binding catalog-backend \
     --region="$REGION" \
     --member="serviceAccount:${GW_SA}" \
     --role="roles/run.invoker"
   ```

2. Write the API contract. API Gateway consumes **OpenAPI 2.0 (Swagger)**, not 3.x — this is a real and frequently-hit constraint. Create `openapi2-run.yaml`:

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

3. Substitute the real backend address.

   ```bash
   sed -i "s|BACKEND_URL_PLACEHOLDER|${BACKEND_URL}|g" openapi2-run.yaml
   grep address openapi2-run.yaml
   ```

4. Create the API, then a config, then the gateway. Note that these are three distinct objects — that separation is what makes versioned, rollback-able releases possible.

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

   Expected (abridged, the config step takes 1–3 minutes):

   ```
   Waiting for API Config [catalog-cfg-v1] to be created for API [catalog-api]...done.
   Waiting for API Gateway [catalog-gw] to be created...done.
   ```

5. Read the public hostname and call the API with **no Google credentials at all**.

   ```bash
   export GW_HOST="$(gcloud api-gateway gateways describe catalog-gw \
     --location="$REGION" --format='value(defaultHostname)')"
   echo "$GW_HOST"

   curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products"
   ```

   Expected: `200` — and `GW_HOST` looks like `catalog-gw-1a2b3c4d.uc.gateway.dev`.

6. Confirm the backend is still closed. The gateway did not open the service; it *fronted* it.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "$BACKEND_URL"
   ```

   Expected: still `403`.

7. Inspect what the platform now knows about the API as an object.

   ```bash
   gcloud api-gateway apis describe catalog-api \
     --format='yaml(name, managedService, state)'
   ```

   Expected:

   ```yaml
   managedService: catalog-api-1a2b3c4d5e6f7.apigateway.my-proj.cloud.goog
   name: projects/my-proj/locations/global/apis/catalog-api
   state: ACTIVE
   ```

   Save it:

   ```bash
   export MANAGED_SERVICE="$(gcloud api-gateway apis describe catalog-api \
     --format='value(managedService)')"
   ```

### Checkpoint questions

- **Q2.1** — After step 5, an anonymous caller gets `200` through the gateway while step 6 still returns `403` directly. Describe the security posture this creates and why a CISO would prefer it to `--allow-unauthenticated` on Cloud Run.
- **Q2.2** — Steps 4 creates three separate objects: API, API config, gateway. What business capability does splitting *config* from *gateway* give you on release day?
- **Q2.3** — The team wants to move `catalog-backend` from Cloud Run to a GKE service next quarter. Which of the three objects changes, and what do the API's consumers have to do?
- **Q2.4** — Name the business term for "consumers depend on the contract, not the implementation," and give one cost consequence of *not* having it.
- **Q2.5** — Right now anyone on the internet who learns `GW_HOST` can call `/products` indefinitely. Which two commercial functions are still impossible?

---

## Exercise 3 — From endpoint to product: identity and quota

This is the exercise where the business model appears. A consumer key is not primarily a security control — it is a *meter*. Quotas are not primarily a defence — they are how you sell Bronze, Silver and Gold.

### Steps

1. Extend the contract with an API-key security definition and a quota model. Replace `openapi2-run.yaml` with this version — note the two new top-level blocks and the per-operation `security` and `x-google-quota`:

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

2. Fill both placeholders. The `host` field must match the gateway hostname — quota enforcement is bound to the managed service, which is bound to that host.

   ```bash
   sed -i "s|BACKEND_URL_PLACEHOLDER|${BACKEND_URL}|g;s|GATEWAY_HOST_PLACEHOLDER|${GW_HOST}|g" \
     openapi2-run.yaml
   head -8 openapi2-run.yaml
   ```

3. Publish a **new config revision** and roll the gateway onto it. The old config is untouched.

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

4. Enable the managed service in the project. Without this, key checks and quota counting cannot run.

   ```bash
   gcloud services enable "$MANAGED_SERVICE"
   ```

5. Call the API with no key. You are now an unregistered consumer.

   ```bash
   curl -s "https://${GW_HOST}/products" | head -c 400; echo
   ```

   Expected:

   ```json
   {"code":16,"message":"Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.","details":[...]}
   ```

6. Issue a consumer credential, restricted to this API only.

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

7. Call as a registered consumer.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products?key=${API_KEY}"
   ```

   Expected: `200`

8. Exceed the tier. The limit is 5 requests per minute; send 8.

   ```bash
   for i in $(seq 1 8); do
     printf '%d ' "$i"
     curl -s -o /dev/null -w '%{http_code}\n' "https://${GW_HOST}/products?key=${API_KEY}"
   done
   ```

   Expected (propagation can take a minute or two after step 4; retry if all 8 return `200`):

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

9. Read the rejection body — the wording matters for the exam's vocabulary.

   ```bash
   curl -s "https://${GW_HOST}/products?key=${API_KEY}" | head -c 300; echo
   ```

   Expected:

   ```json
   {"code":8,"message":"Quota exceeded for quota metric 'Catalog read requests' and limit 'read-limit' of service 'catalog-api-....apigateway.my-proj.cloud.goog' for consumer 'project_number:123456789012'.","details":[...]}
   ```

10. Model a second tier without touching a single line of backend code. Edit only the `values` block:

    ```yaml
       quota:
         limits:
           - name: "read-limit"
             metric: "read-requests"
             unit: "1/min/{project}"
             values:
               STANDARD: 5
    ```

    Change `STANDARD: 5` to `STANDARD: 60`, then publish `catalog-cfg-v3` and update the gateway as in step 3. Re-run step 8 and confirm all eight calls now return `200`.

### Checkpoint questions

- **Q3.1** — The error in step 5 says "unregistered callers … without established identity." Translate that into a business sentence about what an API key gives the API *owner* (not the consumer).
- **Q3.2** — Step 8 produced `429` on the sixth call. Give two distinct business reasons an organization deliberately rejects requests it has the capacity to serve.
- **Q3.3** — Step 10 created a new commercial tier without a backend deploy. Which cost line does that eliminate, and what does it do to time-to-market for a pricing change?
- **Q3.4** — In step 6 the key was restricted with `--api-target`. If a leaked key is restricted to one managed service, what is the blast radius, and how does that change the conversation with the partner's security team?
- **Q3.5** — API keys identify the *calling application*; they do not authenticate an *end user*. Name the standard you would add for end-user authorization, and give one business scenario that requires it.

---

## Exercise 4 — The façade: modernizing without rewriting

The single most commercially important thing an API layer does is let you sell, expose and reshape a system you are not allowed to touch — a mainframe, a SOAP service, a vendor ERP. Apigee is Google Cloud's full-lifecycle API management platform for exactly this.

> **No Apigee organization?** Do the *paper variant* under "Paper variant" below and answer the same questions. The bundle is real and syntactically valid; reading it is most of the learning.

### Steps

1. Confirm you have an Apigee organization and an environment.

   ```bash
   export APIGEE_ORG="$PROJECT_ID"
   export APIGEE_ENV="eval"
   export TOKEN="$(gcloud auth print-access-token)"

   gcloud apigee organizations list
   gcloud apigee environments list --organization="$APIGEE_ORG"
   ```

   Expected:

   ```
   NAME       ENVIRONMENTS
   my-proj    eval
   ```

2. Build the proxy bundle on disk. The directory layout is fixed — Apigee rejects anything else.

   ```bash
   mkdir -p apiproxy/proxies apiproxy/targets apiproxy/policies
   ```

3. `apiproxy/catalog-v1.xml` — the bundle manifest:

   ```xml
   <APIProxy revision="1" name="catalog-v1">
     <DisplayName>catalog-v1</DisplayName>
     <Description>Managed facade over the legacy catalog system of record</Description>
   </APIProxy>
   ```

4. `apiproxy/proxies/default.xml` — the consumer-facing side. Read the `PreFlow` top to bottom: it *is* the commercial contract, expressed as policy.

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

5. `apiproxy/targets/default.xml` — the provider-facing side. Substitute your Cloud Run URL; in a real modernization this is the legacy host.

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

6. `apiproxy/policies/SA-ProtectBackend.xml` — the legacy system has a fixed capacity you cannot grow. Smooth traffic before it arrives.

   ```xml
   <SpikeArrest continueOnError="false" enabled="true" name="SA-ProtectBackend">
     <DisplayName>SA-ProtectBackend</DisplayName>
     <Properties/>
     <Rate>30ps</Rate>
     <UseEffectiveCount>true</UseEffectiveCount>
   </SpikeArrest>
   ```

7. `apiproxy/policies/VA-VerifyKey.xml` — establishes *who* is calling and loads their entitlements.

   ```xml
   <VerifyAPIKey continueOnError="false" enabled="true" name="VA-VerifyKey">
     <DisplayName>VA-VerifyKey</DisplayName>
     <Properties/>
     <APIKey ref="request.queryparam.apikey"/>
   </VerifyAPIKey>
   ```

8. `apiproxy/policies/Q-ProductQuota.xml` — the commercially interesting one. Every value is a *reference* into the API product the consumer is subscribed to. Change the product, change the plan; the proxy is untouched.

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

9. `apiproxy/policies/AM-StripCredential.xml` — the consumer's key is a business credential; the backend never needs it.

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

10. `apiproxy/policies/AM-AddCacheHeaders.xml` — shapes the response for consumers without asking the legacy team for anything.

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

11. Package and import. The management REST API is the source of truth for bundle import.

    ```bash
    zip -r catalog-v1.zip apiproxy -x '*.DS_Store'

    curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -F "file=@catalog-v1.zip" \
      "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/apis?action=import&name=catalog-v1" \
      | jq '{name, revision}'
    ```

    Expected:

    ```json
    {
      "name": "catalog-v1",
      "revision": "1"
    }
    ```

12. Deploy the revision to the environment.

    ```bash
    gcloud apigee apis deploy 1 \
      --api=catalog-v1 \
      --environment="$APIGEE_ENV" \
      --organization="$APIGEE_ORG"

    gcloud apigee deployments list \
      --organization="$APIGEE_ORG" --environment="$APIGEE_ENV"
    ```

    Expected:

    ```
    API          REVISION  ENVIRONMENT  STATE
    catalog-v1   1         eval         READY
    ```

13. Call it without a key through the Apigee runtime hostname (your eval org's hostname is shown in the console under *Environment groups*):

    ```bash
    export APIGEE_HOST="<your-environment-group-hostname>"
    curl -s "https://${APIGEE_HOST}/catalog/v1/products" | jq .
    ```

    Expected:

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

    The proxy is live and refusing unidentified traffic. Exercise 5 issues the key.

### Paper variant (no Apigee org)

Read the bundle above and answer these in writing before checking the answers:

- Trace a single request through `PreFlow`. At each of the four steps, state what a *business stakeholder* gains.
- The legacy backend returns XML and the partner requires JSON. Which part of the bundle changes, and which team's backlog is *not* touched?
- The `Q-ProductQuota` policy contains no numbers. Where do the numbers live, and why is that the important design decision?

### Checkpoint questions

- **Q4.1** — Steps 4–10 add security, rate limiting, quota, credential hygiene and response headers *without a single change to `catalog-backend`*. Name the modernization pattern this implements and the risk it removes from a mainframe or ERP migration.
- **Q4.2** — `SA-ProtectBackend` (Spike Arrest) and `Q-ProductQuota` (Quota) both reject traffic. Explain the difference in *purpose* — one is operational, one is commercial.
- **Q4.3** — In `Q-ProductQuota`, `Allow`, `Interval` and `TimeUnit` are all `ref=` attributes pointing at the API product. What does a sales team gain from that indirection?
- **Q4.4** — Step 11 imported revision `1` and step 12 deployed it. Describe how you would ship a breaking change to a partner-facing API and keep existing partners working.
- **Q4.5** — A CFO asks why Apigee costs more than putting an nginx reverse proxy in front of the legacy service. Give three capabilities in this bundle that an unmanaged reverse proxy does not provide out of the box.

---

## Exercise 5 — The product, the developer, the app: where revenue starts

An API proxy is plumbing. An **API product** is the sellable unit: a named bundle of operations with a quota and an access policy. This distinction is directly examinable.

> **No Apigee organization?** Read the payloads, then answer the questions — they are conceptual.

### Steps

1. Create a Bronze product. Note that the quota lives here, not in the proxy.

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

   Expected:

   ```json
   { "name": "catalog-bronze", "approvalType": "auto" }
   ```

2. Create a Gold product over the *same proxy* — different quota, manual approval.

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

3. Register a developer — this is the *partner*, the entity in your CRM.

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

4. Register an app for that developer and subscribe it to Bronze. The credential is minted here.

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{ "name": "ada-mobile-catalog", "apiProducts": ["catalog-bronze"] }' \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps" \
     | jq '{name, credentials: [.credentials[] | {consumerKey, apiProducts: [.apiProducts[].apiproduct], status}]}'
   ```

   Expected:

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

5. Extract the key and call the proxy as Ada.

   ```bash
   export CONSUMER_KEY="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps/ada-mobile-catalog" \
     | jq -r '.credentials[0].consumerKey')"

   curl -s -o /dev/null -w '%{http_code}\n' \
     "https://${APIGEE_HOST}/catalog/v1/products?apikey=${CONSUMER_KEY}"
   ```

   Expected: `200`

6. Prove that entitlements are enforced from the product. Subscribe nothing and try again with a bogus key:

   ```bash
   curl -s "https://${APIGEE_HOST}/catalog/v1/products?apikey=not-a-real-key" | jq -r '.fault.faultstring'
   ```

   Expected:

   ```
   Invalid ApiKey
   ```

7. Upgrade Ada to Gold without issuing a new credential — the sales motion, executed as an API call:

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{ "apiProducts": ["catalog-gold"] }' \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/developers/ada@partner.example/apps/ada-mobile-catalog/keys/${CONSUMER_KEY}" \
     | jq '[.apiProducts[] | {apiproduct, status}]'
   ```

   Expected — `catalog-gold` present with `status` `pending` (Gold is `approvalType: manual`):

   ```json
   [
     { "apiproduct": "catalog-bronze", "status": "approved" },
     { "apiproduct": "catalog-gold",   "status": "pending" }
   ]
   ```

### Checkpoint questions

- **Q5.1** — One proxy (`catalog-v1`), two products (Bronze, Gold). Explain in business terms why the *product* is the correct place for the quota and the proxy is not.
- **Q5.2** — Bronze is `approvalType: auto`; Gold is `manual`. What commercial process does each encode, and what does `auto` do to partner acquisition cost?
- **Q5.3** — Step 7 changed a subscription with one API call, no code deploy, no key rotation. Name three teams whose work this removes from an upsell.
- **Q5.4** — Apigee includes a **developer portal** with self-service registration and generated reference docs. Which single adoption metric does a portal move most, and why does that metric predict revenue?
- **Q5.5** — Apigee **monetization** supports rate plans (fee-based, per-call, revenue-share). Give one real business model for each of those three and say which party pays.
- **Q5.6** — A retailer publishes an inventory API that its resellers embed in their own storefronts. Describe the value created for the retailer that has nothing to do with charging for calls.

---

## Exercise 6 — Measuring adoption: the data that justifies the programme

You cannot monetize what you cannot count, and you cannot get budget for what you cannot show. This exercise extracts the numbers.

### Steps

1. Generate a mixed traffic sample against the API Gateway API from Exercise 3 — successes and quota rejections.

   ```bash
   for i in $(seq 1 25); do
     curl -s -o /dev/null "https://${GW_HOST}/products?key=${API_KEY}"
   done
   curl -s -o /dev/null "https://${GW_HOST}/products"          # unregistered
   curl -s -o /dev/null "https://${GW_HOST}/does-not-exist?key=${API_KEY}"
   ```

2. Read the gateway's request logs and count outcomes by status code.

   ```bash
   gcloud logging read \
     'resource.type="apigateway.googleapis.com/Gateway"
      AND timestamp>="'"$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"'"' \
     --limit=200 --format='value(httpRequest.status)' \
     | sort | uniq -c | sort -rn
   ```

   Expected shape:

   ```
        20 200
         6 429
         1 404
         1 401
   ```

3. Discover which metrics the platform publishes for this API rather than assuming. Ask the Monitoring API:

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/metricDescriptors?filter=metric.type%3Dstarts_with(%22serviceruntime.googleapis.com%22)" \
     | jq -r '.metricDescriptors[].type' | sort -u
   ```

   Expected shape (a subset):

   ```
   serviceruntime.googleapis.com/api/request_count
   serviceruntime.googleapis.com/api/request_latencies
   serviceruntime.googleapis.com/quota/rate/net_usage
   ```

4. Read the consumed-API view, which is organized *by consumer* — this is the shape a billing system needs.

   ```bash
   gcloud services list --enabled --filter="config.name:apigateway" --format='value(config.name)'
   ```

   Then open, in the console, **APIs & Services → Enabled APIs → your managed service → Metrics**, and set the breakdown to *Credential*. Note that traffic is attributed per API key, not per IP.

5. If you completed Exercise 4/5, pull the equivalent from Apigee's analytics — note that the dimensions are commercial (`developer_app`, `api_product`), not infrastructural.

   ```bash
   curl -s -H "Authorization: Bearer ${TOKEN}" \
     "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/environments/${APIGEE_ENV}/stats/developer_app?select=sum(message_count),avg(total_response_time)&timeRange=$(date -u -d '1 day ago' +%m/%d/%Y)%2000:00~$(date -u +%m/%d/%Y)%2023:59&timeUnit=day" \
     | jq '.environments[0].dimensions[] | {app: .name, metrics: [.metrics[] | {name, values}]}'
   ```

   Expected shape:

   ```json
   {
     "app": "ada-mobile-catalog",
     "metrics": [
       { "name": "sum(message_count)",       "values": [{"timestamp": 0, "value": "26.0"}] },
       { "name": "avg(total_response_time)", "values": [{"timestamp": 0, "value": "84.3"}] }
     ]
   }
   ```

6. Build the one-page programme scorecard. Fill this in from your own numbers:

   | KPI | Where it comes from | Your value |
   |---|---|---|
   | Registered consumers | developers / apps count | |
   | Calls in period | `sum(message_count)` / log count | |
   | Success rate | `2xx` ÷ total | |
   | Quota rejections | count of `429` | |
   | p50 / p99 latency | `request_latencies` | |
   | Consumers at >80% of quota | per-key counts vs limit | |

### Checkpoint questions

- **Q6.1** — Step 2 counts by status code; step 5 counts by `developer_app`. Which of the two can an invoice be generated from, and why is that the difference between infrastructure monitoring and API analytics?
- **Q6.2** — Your scorecard shows three consumers consistently at 95% of a Bronze quota. What is the commercial action, and which team should receive that signal automatically?
- **Q6.3** — Quota rejections jump from 6/day to 4,000/day and registered consumers are unchanged. Give two competing explanations and say what you would check first.
- **Q6.4** — "Time to first successful call" measures the gap between a developer signing up and their first `200`. Argue why this is a better leading indicator of API programme health than total call volume.
- **Q6.5** — A stakeholder wants to sunset `/products/{id}` in v1. Which numbers from this exercise make that a safe decision instead of a gamble?

---

## Exercise 7 — The integration-cost model (paper exercise)

The most quotable business argument for APIs is a piece of arithmetic. Do it yourself so you can reproduce it under exam pressure.

### Steps

1. Consider a company with **n = 12** internal systems that all need to exchange data. In a point-to-point architecture, every pair needs its own bespoke integration. Compute the number of integrations:

   ```
   point_to_point(n) = n × (n − 1) / 2
   point_to_point(12) = 12 × 11 / 2 = ____
   ```

2. Now assume each system exposes **one** API and consumes others through a shared API management layer. Compute the number of interfaces to build and maintain:

   ```
   api_mediated(n) = n
   api_mediated(12) = ____
   ```

3. Assign costs. Use conservative internal figures: **$40,000** to build one bespoke point-to-point integration, and **$8,000/year** to maintain it. Assume an API-mediated interface costs **$55,000** to build (it is a real product: documented, versioned, secured) and **$6,000/year** to maintain.

   ```
   Point-to-point:  build = ____ × $40,000 = $________
                    annual maintenance = ____ × $8,000 = $________

   API-mediated:    build = ____ × $55,000 = $________
                    annual maintenance = ____ × $6,000 = $________
   ```

4. Compute the three-year total cost of ownership for both, and the break-even point.

5. Now add the thirteenth system. Compute the *marginal* cost of onboarding it in each architecture:

   ```
   point_to_point marginal = n new integrations = ____ × $40,000 = $________
   api_mediated  marginal = 1 new interface     =    1 × $55,000 = $________
   ```

6. Repeat step 1 and step 5 for **n = 30** and write down both marginal costs.

### Checkpoint questions

- **Q7.1** — State your answers to steps 1, 2 and 5. What is the *shape* of each cost curve as `n` grows?
- **Q7.2** — At `n = 12` the API-mediated build cost is higher per interface. Explain to a CFO why you would still recommend it, using the step-5 number.
- **Q7.3** — The model above counts only build and maintenance. Name three costs a point-to-point estate incurs that this model omits entirely.
- **Q7.4** — An acquisition adds 8 systems overnight. Which architecture makes integration a project and which makes it onboarding? Quantify with the `n = 30` figures.
- **Q7.5** — This arithmetic is the internal case. State the external case — the revenue argument — in two sentences.

---

## Exercise 8 — Product-selection drill

The exam tests whether you can match a business situation to the right Google Cloud product. Do this closed-book.

### Steps

1. For each scenario, write down (a) the product you would recommend, and (b) the single sentence of business justification.

   | # | Scenario |
   |---|---|
   | S1 | A bank must expose account APIs to licensed third-party fintechs under open-banking regulation, with a self-service portal, per-partner SLAs, OAuth-based consent, and quarterly usage reports for the regulator. |
   | S2 | A startup has three Cloud Run services and wants one HTTPS hostname, API keys, and simple per-key rate limits. Nobody will be billed for calls. |
   | S3 | A telco runs its API runtime inside its own Kubernetes clusters in two on-premises data centres for data-residency reasons, but wants Google-managed API lifecycle, analytics and portal. |
   | S4 | A gRPC service running on GKE needs an authenticating proxy with an OpenAPI/gRPC contract and Cloud Monitoring integration, deployed as a sidecar alongside the workload. |
   | S5 | A logistics firm wants to charge shippers $0.002 per tracking lookup, with tiered volume discounts and monthly invoices generated from actual usage. |
   | S6 | A 30-year-old SOAP inventory service cannot be modified. Mobile teams need JSON REST, and the SOAP host melts above 40 requests/second. |
   | S7 | Internal teams keep rebuilding the same customer-lookup integration because nobody knows the existing one exists. |

2. For S1, S5 and S6, also name the *specific* capability that makes your choice correct — a policy, a feature or a component, not just the product name.

3. Rank S1–S7 by how strong the case is for full API management versus a plain gateway. Justify the two extremes.

### Checkpoint questions

- **Q8.1** — Give your product choice and justification for all seven scenarios.
- **Q8.2** — State the boundary in one sentence: when is API Gateway sufficient and when does an organization actually need Apigee?
- **Q8.3** — Two scenarios above are *not* really about technology. Identify them and say what they are about.
- **Q8.4** — A colleague says "an API gateway and API management are the same thing." Correct them in three sentences.

---

## Exercise 9 — Teardown

Run this. Apigee environments bill per hour; API keys are credentials.

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

Confirm nothing is left billing:

```bash
gcloud api-gateway gateways list --location="$REGION"
gcloud run services list --region="$REGION"
```

Expected: `Listed 0 items.` for both.

---

<details>
<summary><strong>Answers — expand only after attempting every checkpoint</strong></summary>

### Exercise 1 — The asset with no distribution channel

**Q1.1** — It has no **distribution channel** and no **commercial interface**. The capability exists but is reachable only by holders of Google Cloud identities in your project. From a business standpoint it is an internal cost centre: it consumes engineering budget and produces no external value, because there is no way for a customer, partner or third-party developer to consume it. The exam framing is that an API turns an internal capability into a *consumable, governed asset*.

**Q1.2** — You would have to grant them an IAM identity in your Google Cloud project (a service account, or `roles/run.invoker` on their principal). Risks: (1) **coupling your customer relationship to your cloud IAM** — the partner is now a principal inside your project, and offboarding them is an IAM change, not a subscription cancellation; (2) **no granularity** — `run.invoker` is all-or-nothing over the whole service; you cannot grant read but not write, or 1,000 calls but not 1,000,000; (3) **no meter** — IAM authorizes but does not count. A third, often-cited risk: it does not scale organizationally, since every partner becomes a bespoke identity engineering task.

**Q1.3** — **Consumer identity attached to each request.** Cloud Run logs show requests, IPs and user agents, but nothing that maps a call to a *paying party*. Without a per-consumer credential presented on every call, usage-based billing is impossible — you can count requests but not attribute them.

**Q1.4** — A private, working backend is a *capability*; an API is a **published, versioned, governed contract with identified consumers**, and only the second can be adopted, measured, supported or sold.

### Exercise 2 — A managed front door

**Q2.1** — The backend remains closed to the internet; the only path to it runs through a control point that terminates TLS, enforces the published contract, and calls the backend using a dedicated service account with least privilege (`roles/run.invoker`, nothing more). This is defence in depth: compromising the gateway does not grant IAM over the project, and the backend cannot be reached even if its URL leaks. Compared with `--allow-unauthenticated`, there is exactly **one** front door, so security controls, logging and rate limiting have a single place to live rather than being reimplemented per service.

**Q2.2** — **Safe, reversible releases.** The config is an immutable, versioned artifact; the gateway is a pointer to one. Publishing a new config does not affect live traffic, and rollback is repointing the gateway at the previous config — seconds, no rebuild. Commercially this lowers the cost and risk of changing the contract, which is what makes frequent iteration on a partner-facing API viable.

**Q2.3** — Only the **API config** changes: `x-google-backend.address` points at the new GKE endpoint, you publish a new config revision and update the gateway. **Consumers do nothing** — same hostname, same paths, same keys. This is the concrete demonstration of decoupling.

**Q2.4** — **Loose coupling / abstraction — the API contract is a stable façade over a changeable implementation.** Without it, every backend change becomes a coordinated migration across every consumer: you must find them, notify them, get them to schedule work, and run both implementations until the slowest one migrates. That coordination cost is what freezes legacy systems in place and is routinely the largest hidden line item in a modernization programme.

**Q2.5** — (1) **Charging for usage** — there is no consumer identity to attribute calls to. (2) **Selling differentiated service levels** — with no per-consumer limits, every caller gets the same undifferentiated access, so there is no Bronze/Gold to sell and no enforceable SLA. (Also acceptable: revoking a single partner's access without breaking everyone else.)

### Exercise 3 — From endpoint to product

**Q3.1** — The key gives the API owner **attribution**: every call is tied to a known consumer, which is the prerequisite for metering, invoicing, per-consumer rate limiting, targeted deprecation notices, abuse investigation, and selective revocation. Note the direction — an API key is weak *authentication* but strong *identification*, and identification is what the business needs.

**Q3.2** — (1) **Commercial differentiation** — rejecting above the purchased tier is what makes tiers real; if Bronze silently served Gold volumes, nobody would buy Gold. (2) **Protecting a shared resource and its cost** — a single runaway consumer can exhaust capacity or drive unbudgeted spend for everyone else, so an enforceable ceiling per consumer converts an unbounded liability into a predictable cost. (Also valid: enforcing fair use across many small consumers, and creating a natural upsell trigger.)

**Q3.3** — It eliminates the **engineering cost of a pricing change** — no backend work, no code review, no deploy window, no regression risk to the business logic. Time-to-market for a new tier drops from a release cycle (weeks) to a configuration publish (minutes). The strategic consequence: pricing becomes a product decision the business can iterate on, instead of an engineering project it must queue.

**Q3.4** — The blast radius is limited to that one managed service: the key cannot be used against any other API in the project, and it carries no IAM permissions. The conversation with the partner changes from "we have a breach" to "we rotate one credential scoped to one read-only API," and revocation is a single delete that affects no one else. This is the practical value of credentials that are *narrow by construction*.

**Q3.5** — **OAuth 2.0** (commonly with OpenID Connect / JWT bearer tokens). Required whenever the API acts on data belonging to an end user rather than to the calling company — open banking (a customer authorizes a fintech to read *their* account), healthcare records, or any "sign in with X" delegation. The distinction the exam wants: the API key says *which app*, OAuth says *which user, and what they consented to*.

### Exercise 4 — The façade

**Q4.1** — This is the **API façade** pattern (in a migration context, the **strangler fig** pattern: new capability is added in front of the legacy system, which is progressively replaced behind an unchanged interface). The risk it removes is the **big-bang rewrite**: instead of a multi-year, all-or-nothing replacement of a system of record — the classic source of failed transformation programmes — the organization ships value incrementally, keeps the legacy system running, and can swap the implementation later without renegotiating with a single consumer.

**Q4.2** — **Spike Arrest is operational protection**: it smooths bursts to a rate the backend can physically survive, protecting availability for everyone regardless of who is calling. It is about *capacity*. **Quota is a commercial control**: it enforces the volume a specific consumer is entitled to over a business time window (per minute, day or month), it is bound to an API product, and exceeding it is a *contractual* event that may trigger an upsell. It is about *entitlement*. They are frequently used together: Spike Arrest protects the system, Quota enforces the deal.

**Q4.3** — The commercial terms live in the **API product**, not in code. Sales can create a new plan, change a limit, or move a customer between tiers as a data change, with no proxy revision, no deployment, and no engineering ticket. The general principle: the proxy encodes *how the API works*; the product encodes *what was sold*. Keeping the second out of the first is what lets the business move at business speed.

**Q4.4** — Publish it as a **new version with a new base path** (`/catalog/v2`) as a separate proxy revision and, typically, a separate API product. Existing partners keep calling `/catalog/v1` untouched. Then: announce a deprecation window, use analytics to see exactly which apps still call v1, contact those specific developers, and only retire v1 when its traffic is effectively zero. Versioning plus per-consumer analytics is what makes deprecation a managed process rather than an outage.

**Q4.5** — Any three of: (1) **consumer identity and entitlement** — `VerifyAPIKey` resolves the caller to a registered app and loads what they bought; nginx has no concept of a developer, an app or a product. (2) **Product-driven quota** — limits that are business data, changeable without touching the proxy. (3) **Business analytics** — usage by developer, app and API product, which is what invoices and adoption reports are built from. (4) **Developer portal and self-service onboarding** — a distribution channel, not just a proxy. (5) **Monetization** — rate plans and billing. (6) **Full lifecycle governance** — versioned bundles, environments, promotion, deployment history and audit. The framing that lands with a CFO: nginx moves packets; API management runs a *business channel*, and the alternative is building and maintaining all six of those yourself.

### Exercise 5 — Product, developer, app

**Q5.1** — The proxy is a **technical asset** — one implementation, shared. The product is a **commercial packaging** of that asset — a named bundle of operations with limits and an access policy. Putting the quota in the proxy would mean one proxy per price point: duplicated code, duplicated bugs, and a deploy for every commercial change. Putting it in the product means one implementation can be sold many ways, which is exactly how physical products work (same factory, different SKUs).

**Q5.2** — `auto` encodes **frictionless self-service**: a developer signs up and is calling the API in minutes, with the quota as the safety rail. `manual` encodes an **approval gate** — a contract, a credit check, a compliance review, a signed data-processing agreement — before high-volume or sensitive access is granted. `auto` drives partner acquisition cost toward zero because no human is in the loop, which is the whole economic argument for a developer portal: acquisition scales without headcount.

**Q5.3** — Engineering (no code change), release/operations (no deployment), and the partner's own integration team (no credential rotation, no client change). Often also security review, since no new credential is issued. The upsell becomes a **configuration change made by the account team**, which is the difference between an upsell that takes a quarter and one that takes an afternoon.

**Q5.4** — **Time to first successful call** (and, upstream of it, sign-up-to-integration conversion). It predicts revenue because API adoption is a funnel: developers who cannot get a `200` quickly abandon and evaluate a competitor, and the ones who *do* integrate become embedded and hard to displace. A portal with self-service keys, working reference docs and a try-it console compresses that interval from days of email to minutes, which raises the conversion rate at the top of the funnel — and every downstream revenue number is a percentage of that.

**Q5.5** — (1) **Fee-based / subscription**: a market-data provider charges $2,000/month for access to a financial-quotes API — the *consumer* pays a fixed fee. (2) **Per-call / pay-as-you-go**: an address-validation or SMS API charges per request — the *consumer* pays in proportion to usage. (3) **Revenue share**: a travel aggregator's booking API pays the *developer* a commission on each completed booking they originate — here the *API provider pays the consumer*, because the consumer is a distribution channel. The exam-relevant insight: monetization does not always mean charging; sometimes the API buys you reach.

**Q5.6** — **Distribution and channel lock-in.** Every reseller storefront that embeds the inventory API becomes a sales surface the retailer did not have to build or staff, showing the retailer's live stock to customers it would never have reached directly. Secondary effects: the retailer's data becomes the reseller's source of truth (switching cost), and the API's usage telemetry gives the retailer demand signals across the whole channel. This is the "APIs create new business models / ecosystems" answer the exam guide is pointing at — the value is reach, not fees.

### Exercise 6 — Measuring adoption

**Q6.1** — Only step 5 (`developer_app`) can generate an invoice, because it attributes each call to a **commercial entity** — a registered app belonging to a known developer, subscribed to a known API product. Step 2 counts *events*. Infrastructure monitoring answers "is the system healthy?"; API analytics answers "who used what, how much, and under which contract?" The exam distinction: an API management platform reports along business dimensions (developer, app, product, region) rather than only infrastructure ones (instance, status code, latency).

**Q6.2** — The commercial action is a **proactive upsell to the next tier** — the consumer is demonstrably getting value and is about to hit a wall that will degrade their experience. The signal should route automatically to sales/account management (and to the partner themselves as a usage notification). The general principle: quota telemetry is a *revenue* signal, not only an ops signal, and the API platform should be wired into the CRM.

**Q6.3** — (1) **A legitimate consumer changed behaviour** — shipped a new app version, removed client-side caching, added a retry loop, or ran a batch job; their business is fine and they need a bigger tier. (2) **A credential is compromised or being abused**, or a client is stuck in a retry storm amplifying its own failures. Check **first**: whether the rejections are concentrated in one credential or spread across many. One key → investigate that consumer specifically (compare its 7-day baseline, look at the calling pattern and user agent). Many keys → suspect a platform-side change (a config publish that lowered a limit, or a regional failover) before blaming consumers.

**Q6.4** — Total call volume is dominated by consumers who integrated long ago; it can look healthy for a year while acquisition has stopped completely — it is a **lagging** indicator averaged over your installed base. Time to first successful call measures the friction a *new* developer meets today, so it moves the moment the portal, docs, sandbox or onboarding regress, and it directly gates every future cohort. If it degrades, tomorrow's call volume is already lost; you just cannot see it in the volume chart yet.

**Q6.5** — Per-operation call counts (is `/products/{id}` used at all?), and per-consumer breakdown of *those* calls (how many distinct apps, and whose?). Together they convert the decision from "we think nobody uses it" into a named list you can contact, a deprecation window you can size, and a residual-traffic threshold you can watch until it reaches zero. Without them, sunsetting an endpoint is an outage waiting to be discovered by a customer.

### Exercise 7 — The integration-cost model

**Q7.1** —
- Step 1: `12 × 11 / 2 = 66` point-to-point integrations.
- Step 2: `12` API-mediated interfaces.
- Step 5 (adding the 13th system): point-to-point needs **12** new integrations = **$480,000**; API-mediated needs **1** = **$55,000**.

Shape: point-to-point grows **quadratically** — `O(n²)` — while API-mediated grows **linearly** — `O(n)`. That difference, not the per-interface price, is the whole argument.

Three-year TCO for reference: point-to-point = `66 × $40,000 = $2,640,000` build + `66 × $8,000 × 3 = $1,584,000` maintenance = **$4,224,000**. API-mediated = `12 × $55,000 = $660,000` build + `12 × $6,000 × 3 = $216,000` = **$876,000**. Break-even arrives almost immediately at this `n`: the two build costs cross at roughly `n ≈ 3.75`, i.e. from four systems onward the API approach is already cheaper to build, before any maintenance is counted.

**Q7.2** — Because the CFO is not buying interfaces, they are buying **the cost of the next change**. At 12 systems the per-interface premium is $15,000; the moment a thirteenth system arrives — an acquisition, a SaaS adoption, a new channel — the point-to-point estate charges $480,000 and the API estate charges $55,000. You are trading a small, one-time premium for a permanently flat marginal cost, and the marginal cost is what the company pays over and over.

**Q7.3** — Any three of: (1) **coordination and project-management overhead**, which itself grows with the number of teams touched per change; (2) **testing and regression cost** — a change to one system must be re-verified against every partner integration; (3) **operational and incident cost** — 66 bespoke paths means 66 failure modes, 66 monitoring gaps, and no single place to see what broke; (4) **security and compliance cost** — auth, logging and audit reimplemented (inconsistently) 66 times, and 66 surfaces to review; (5) **knowledge and key-person risk** — undocumented integrations whose only author has left; (6) **opportunity cost / delayed time-to-market** — the launch that slips two quarters because integration work is queued behind everything else. That last one is usually the largest and the least measured.

**Q7.4** — Point-to-point makes it a **project**; API-mediated makes it **onboarding**. At `n = 30`: point-to-point is `30 × 29 / 2 = 435` integrations, and the marginal cost of the 31st system is `30 × $40,000 = $1,200,000`. API-mediated is 30 interfaces, and the 31st system costs `1 × $55,000`. Adding 8 systems at once to a 30-system point-to-point estate is hundreds of new integrations — an acquisition-integration programme measured in years, and a well-documented reason M&A synergies arrive late or not at all.

**Q7.5** — Internally, APIs cut the cost and lead time of connecting systems, turning integration from a quadratic project cost into a linear onboarding cost. Externally, they create **new revenue and new reach**: capabilities that previously served only your own applications become products you can sell directly, or distribution channels through which partners embed your business in theirs.

### Exercise 8 — Product-selection drill

**Q8.1** —

- **S1 — Apigee API Management.** Open banking needs the full commercial and governance stack: a developer portal for partner self-service, OAuth 2.0 with end-user consent, per-partner products and SLAs, and analytics that produce regulator-grade usage reporting. This is an API *programme*, not a proxy.
- **S2 — API Gateway.** Serverless Google Cloud backends, one managed hostname, API keys and simple quotas, no monetization or portal requirement. Choosing Apigee here would buy capabilities nobody needs.
- **S3 — Apigee hybrid.** The runtime plane runs in the customer's own Kubernetes clusters (on-premises or another cloud) so traffic and data stay in the required jurisdiction, while the management plane, analytics and portal remain Google-managed.
- **S4 — Cloud Endpoints (ESPv2).** An OpenAPI/gRPC-configured proxy deployed alongside the workload on GKE/Compute Engine/App Engine, with authentication and Cloud Monitoring integration. Endpoints is the *deploy-it-yourself proxy* option; API Gateway is its fully managed serverless cousin.
- **S5 — Apigee, with monetization.** Per-call pricing, volume tiers and usage-derived invoicing are exactly what Apigee's rate plans and monetization reporting exist for.
- **S6 — Apigee.** A façade over an unmodifiable SOAP backend: message transformation to JSON/REST, plus a Spike Arrest policy to hold traffic at the 40 rps the host survives. Both the mediation and the protection live in the proxy, and the legacy team's backlog is untouched.
- **S7 — Apigee, specifically its API catalog and developer portal.** The problem is *discoverability*, and the fix is a governed catalog where an internal engineer can find, understand and self-serve an existing API instead of rebuilding it.

**Q8.2** — **API Gateway** is sufficient when you need a managed front door for Google Cloud serverless backends with basic keys and quotas and no commercial layer; an organization needs **Apigee** the moment the API has *external consumers with contracts* — a portal, monetization, per-partner SLAs, lifecycle governance across environments, business analytics, or mediation over legacy protocols.

**Q8.3** — **S5** and **S7**. S5 is a **business-model** question — the technology to serve tracking lookups already exists; what is missing is metering, rate plans and invoicing. S7 is an **organizational / governance** question — duplicated integrations are a symptom of no catalog, no ownership and no discovery, and no gateway configuration fixes a culture where nobody can find what already exists. (S6 is a legitimate third answer: it is fundamentally a modernization-strategy question, not a proxy question.)

**Q8.4** — An API **gateway** is a runtime component: it terminates requests, authenticates, applies rate limits and routes to a backend. API **management** is a platform that includes a gateway but adds the lifecycle and commercial layer around it — design and versioning, developer portal and onboarding, API products and entitlements, business analytics, monetization, and governance across environments. In short: the gateway is the door, and API management is the business that runs the building — the door is necessary but does not sign contracts, send invoices or tell you who came in.

</details>

---

## Sources

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