# ICA 2.3 — Troubleshooting del Plano de Datos de la Malla

> **Peso del dominio en el examen: 6.** Este tema se sitúa en la intersección de todos los demás dominios: un `VirtualService` mal configurado, un `PeerAuthentication` en el modo equivocado, un subset que ningún endpoint matchea, o un push del plano de control que nunca llega — todos se manifiestan como un síntoma en el plano de datos (un `503`, una request colgada, un proxy que nunca pasa a `Ready`). Dominar el plano de datos significa poder caminar desde el *síntoma* → *qué objeto de configuración de Envoy está mal* → *por qué istiod lo produjo* sin adivinar.

---

## 1. Motivación y el problema arquitectónico de producción

El plano de datos de Istio es una flota de **sidecars Envoy** (contenedores `istio-proxy`) inyectados junto a cada workload, más los Envoys de gateway en el borde. El plano de control (`istiod`) nunca toca una sola request; solo *configura* esos Envoys mediante el protocolo gRPC **xDS**. Esta división es el sentido mismo de una malla de servicios — y es también todo el problema de troubleshooting:

**La configuración que escribís no es la configuración que corre.** Vos autorás la intención como CRDs de Kubernetes (`VirtualService`, `DestinationRule`, `PeerAuthentication`, `Sidecar`, `Gateway`). `istiod` observa esas CRDs, el registro de servicios (los `Endpoints`/`EndpointSlice` de Kubernetes) y la autoridad certificadora, y luego *traduce* todo eso a primitivas concretas de Envoy — **listeners, routes, clusters, endpoints, secrets** — y las transmite a cada proxy. Un incidente de producción es casi siempre un desajuste entre alguna de estas capas:

```
 Author intent        Control plane           Data plane                Reality
 ┌───────────┐   watch  ┌─────────┐   xDS/gRPC  ┌────────────┐  request  ┌──────────┐
 │ CRDs +    │────────▶ │ istiod  │───────────▶ │ Envoy       │◀────────▶ │ upstream │
 │ K8s Svc   │          │ (Pilot) │  :15012     │ LDS/RDS/    │  :15001   │ pods     │
 │ Endpoints │          │         │             │ CDS/EDS/SDS │  :15006   │          │
 └───────────┘          └─────────┘             └────────────┘           └──────────┘
   Layer 1                Layer 2                  Layer 3                  Layer 4
```

Una falla puede vivir en cualquier capa:

| Capa | Cómo se ve | El chequeo autoritativo |
|---|---|---|
| 1 — Intención | Advertencias del analizador, hosts en conflicto, subset sin pod que matchee | `istioctl analyze` |
| 2 — Distribución | El proxy muestra `STALE`/`NOT SENT`, errores de push en los logs de istiod | `istioctl proxy-status` |
| 3 — Config efectiva | Listener/route/cluster presente pero equivocado | `istioctl proxy-config …` |
| 4 — Runtime | `503`/`504`, fallos de handshake TLS, cuelgues | Logs de acceso de Envoy + `RESPONSE_FLAGS` |

El método disciplinado es **descender las capas en orden**. La mayoría de los ingenieros salta directo a la Capa 4 (leer `503`s) y quema una hora; el camino rápido es confirmar primero que las Capas 1–2 están en verde, porque si el proxy nunca recibió la configuración, ninguna cantidad de lectura de logs en la Capa 4 lo va a explicar.

### Por qué el modelo de sidecar hace esto difícil

- **Transparencia de iptables.** El contenedor `istio-init` (o el plugin `istio-cni`) instala reglas de `iptables` que redirigen todo el tráfico entrante a Envoy en el puerto **15006** y todo el saliente al **15001**. La aplicación cree que está hablando directamente con `reviews:9080`; en realidad habla con su propio sidecar. Cuando algo "no puede conectar", la primera pregunta es *de qué lado de la redirección de iptables se rompió*.
- **Consistencia eventual.** xDS es push-based y asíncrono. La configuración es *eventualmente* consistente, así que una carrera entre "el pod arrancó" y "la config llegó" produce `503 UH`/`NR` transitorios que desaparecen al reintentar — una clase de bug que solo existe porque el plano de datos y el plano de control están desacoplados.
- **Vista por proxy.** Cada Envoy tiene su *propia* config efectiva. Un `VirtualService` puede estar aplicado correctamente en el proxy A y faltar en el proxy B (namespace distinto, scope de `Sidecar` distinto). Siempre tenés que depurar **el proxy específico** que está fallando, nunca "la malla" en abstracto.

---

## 2. La anatomía del sidecar: puertos, xDS, y dónde cae cada falla

Cada contenedor `istio-proxy` expone un conjunto fijo de puertos. Conocerlos de memoria es la mitad de la depuración del plano de datos, porque el síntoma a menudo nombra el puerto.

| Puerto | Bindeado por | Propósito | Firma de la falla |
|---|---|---|---|
| **15000** | Envoy | API de administración (`/config_dump`, `/stats`, `/clusters`, `/logging`) | Si es inalcanzable, el propio Envoy está muerto |
| **15001** | Envoy | Captura de salida (iptables `REDIRECT`) | `503`s de salida, egress de malla roto |
| **15006** | Envoy | Captura de entrada (iptables `REDIRECT`) | Fallos de mTLS / auth de entrada |
| **15008** | Envoy | Túnel HBONE (ambient / mux de mTLS) | Fallos del camino L4 de ambient |
| **15020** | pilot-agent | Métricas de Prometheus fusionadas + agente | Huecos de scrape, salud del agente |
| **15021** | pilot-agent | Readiness `/healthz/ready` | Pod atascado en `0/2 Running`, nunca `Ready` |
| **15053** | pilot-agent | Proxy DNS (resolución local) | El DNS de `ServiceEntry` no resuelve |
| **15090** | Envoy | Telemetría cruda de Envoy (`/stats/prometheus`) | Faltan métricas a nivel de Envoy |
| **15012** | istiod | xDS + CA (TLS/mTLS) — el proxy marca *hacia afuera* aquí | `NR`/`STALE`, rotación de certs atascada |
| **15014** | istiod | Monitoreo del plano de control | Huecos de observabilidad de istiod |
| **15017** | istiod | Webhook de inyección + validación | Sidecar no inyectado, CRD rechazada |

### xDS: los cinco discovery services

`istiod` transmite cinco tipos de recurso a cada proxy sobre un único stream gRPC ADS (Aggregated Discovery Service) en el **15012**. La herramienta de depuración `istioctl proxy-config` mapea uno a uno sobre ellos:

| API xDS | Recurso de Envoy | Subcomando `proxy-config` | Responde la pregunta |
|---|---|---|---|
| **LDS** | Listeners | `listeners` | ¿Envoy está siquiera escuchando por este tráfico? |
| **RDS** | Routes | `routes` | Una vez matcheado, ¿a dónde va la request? |
| **CDS** | Clusters | `clusters` | ¿Existe el cluster de destino? ¿Cuál es su política de LB/TLS? |
| **EDS** | Endpoints | `endpoints` | ¿El cluster tiene alguna IP de backend sana? |
| **SDS** | Secrets | `secret` | ¿Los certs de mTLS están presentes y son válidos? |

El orden importa para razonar sobre una request: **una request llega a un LISTENER (LDS), matchea una ROUTE (RDS), que selecciona un CLUSTER (CDS), que resuelve a ENDPOINTS (EDS), asegurados por SECRETS (SDS).** Rompé la cadena en cualquier eslabón y obtenés una falla distinta y diagnosticable — ver §5.

---

## 3. La cadena de herramientas de diagnóstico de tres niveles (compromisos)

Tenés tres formas fundamentalmente distintas de inspeccionar el plano de datos. Elegir la equivocada desperdicia tiempo o, peor, te da una respuesta *desactualizada*.

| Herramienta | Fuente de verdad | Latencia | Mejor para | Trampa |
|---|---|---|---|---|
| `istioctl analyze` | **Capa 1** — CRDs en etcd | Instantánea | Errores de *intención* de config antes de que se envíen | No dice nada sobre lo que Envoy realmente corre |
| `istioctl proxy-status` | **Capa 2** — la vista de istiod de la versión ACK'd de cada proxy | Instantánea | "¿Aterrizó la config?" (SYNCED/STALE/NOT SENT) | Reporta *distribución*, no *correctitud* |
| `istioctl proxy-config` | **Capa 3** — el `config_dump` vivo del proxy (:15000) | Instantánea | La config *efectiva* de Envoy en un proxy | Salida grande; tenés que saber qué recurso leer |
| Logs de acceso / `/stats` de Envoy | **Capa 4** — runtime | Tiempo real | *Por qué esta request específica* falló (`RESPONSE_FLAGS`) | Desactivados por defecto en algunos perfiles; ruidosos |
| `istioctl x describe pod` | Sintetiza 1–3 | Instantánea | "Qué se aplica a este pod" en formato legible | Resumido — oculta casos borde |

> **Regla práctica:** `analyze` lo atrapa antes del deploy, `proxy-status` te dice *si se deployó*, `proxy-config` te dice *qué se deployó*, y los logs de acceso te dicen *por qué murió la request*. Descendé en ese orden.

### `proxy-config` vs. `config_dump` directo

`istioctl proxy-config clusters <pod>` es un wrapper amigable sobre el `GET localhost:15000/config_dump` crudo de Envoy. El wrapper es casi siempre lo que querés (filtra, formatea y agrega columnas). Bajá al dump crudo solo cuando necesitás un campo que el wrapper oculta:

```
$ kubectl exec deploy/productpage-v1 -c istio-proxy -- \
    curl -s localhost:15000/config_dump | jq '.configs[].dynamic_active_clusters | length'
```

---

## 4. Lab completo: una malla reproducible con una falla inyectada

Los siguientes manifiestos levantan un escenario mínimo pero con forma de producción que podés romper y arreglar. Asume que Istio está instalado con el perfil `demo` o `default` y la etiqueta `istio-injection=enabled`.

### 4.1 Namespace, deployment y service

```yaml
# 00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    istio-injection: enabled          # sidecar auto-injection webhook (:15017)
---
# 01-catalog.yaml — two subsets (v1, v2) so we can break subset routing
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-v1
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels: { app: catalog, version: v1 }
  template:
    metadata:
      labels: { app: catalog, version: v1 }
    spec:
      containers:
        - name: catalog
          image: hashicorp/http-echo:1.0
          args: ["-text=catalog-v1", "-listen=:9080"]
          ports:
            - containerPort: 9080
              name: http-catalog        # port name MUST start with http- for L7 features
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-v2
  namespace: shop
spec:
  replicas: 1
  selector:
    matchLabels: { app: catalog, version: v2 }
  template:
    metadata:
      labels: { app: catalog, version: v2 }
    spec:
      containers:
        - name: catalog
          image: hashicorp/http-echo:1.0
          args: ["-text=catalog-v2", "-listen=:9080"]
          ports:
            - containerPort: 9080
              name: http-catalog
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
  namespace: shop
spec:
  selector: { app: catalog }           # selects BOTH v1 and v2 pods
  ports:
    - name: http                       # protocol inferred from name → HTTP/L7
      port: 9080
      targetPort: 9080
```

> **Trampa de producción (Capa 1):** el puerto del Service **debe estar nombrado** con un prefijo reconocido por Istio (`http`, `http2`, `grpc`, `tcp`, `tls`, `mongo`, …) o setear `appProtocol`. Un puerto sin nombre o mal nombrado hace que Istio trate el tráfico como **TCP** opaco, deshabilitando silenciosamente el routing, los reintentos y la telemetría L7 — una de las 3 causas principales de "mi `VirtualService` no hace nada".

### 4.2 Las reglas de routing (con un bug deliberado en §4.4)

```yaml
# 02-routing.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: catalog
  namespace: shop
spec:
  host: catalog.shop.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL               # use mesh mTLS to upstream
    connectionPool:
      tcp: { maxConnections: 100 }
      http:
        http1MaxPendingRequests: 10
        maxRequestsPerConnection: 0
    outlierDetection:                  # passive health checking / ejection
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: catalog
  namespace: shop
spec:
  hosts: ["catalog.shop.svc.cluster.local"]
  http:
    - name: canary
      route:
        - destination: { host: catalog.shop.svc.cluster.local, subset: v1 }
          weight: 90
        - destination: { host: catalog.shop.svc.cluster.local, subset: v2 }
          weight: 10
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: connect-failure,refused-stream,5xx
      timeout: 10s
```

### 4.3 Un cliente desde el que podamos hacer `curl`

```yaml
# 03-client.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  namespace: shop
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata:
      labels: { app: sleep }
    spec:
      containers:
        - name: sleep
          image: curlimages/curl:8.9.1
          command: ["/bin/sleep", "infinity"]
```

### 4.4 Forzar mTLS STRICT (aquí es donde plantamos la falla en §5.3)

```yaml
# 04-peerauth.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: shop
spec:
  mtls:
    mode: STRICT                       # reject any plaintext on inbound :15006
```

Aplicá y confirmá que ambos contenedores estén arriba:

```
$ kubectl apply -f 00-namespace.yaml -f 01-catalog.yaml -f 02-routing.yaml -f 03-client.yaml -f 04-peerauth.yaml
namespace/shop created
deployment.apps/catalog-v1 created
deployment.apps/catalog-v2 created
service/catalog created
destinationrule.networking.istio.io/catalog created
virtualservice.networking.istio.io/catalog created
deployment.apps/sleep created
peerauthentication.security.istio.io/default created

$ kubectl -n shop get pods
NAME                          READY   STATUS    RESTARTS   AGE
catalog-v1-6c9f4b7d8f-4nq2z   2/2     Running   0          40s
catalog-v1-6c9f4b7d8f-r7t9k   2/2     Running   0          40s
catalog-v2-77d5c8b6c4-lm2xp   2/2     Running   0          40s
sleep-5d9f8c7b6d-w8kqv        2/2     Running   0          40s
```

`READY 2/2` = contenedor de app + `istio-proxy` inyectado. Un pod atascado en `1/2` o `0/2` es tu primera señal del plano de datos (ver §5.1).

---

## 5. Playbook de diagnóstico — del síntoma a la causa raíz

### 5.1 Síntoma: el pod nunca llega a `Ready` (`0/2` o `1/2`)

El gate de readiness del proxy es `pilot-agent` sirviendo `/healthz/ready` en el **15021**. Reporta `Ready` solo después de que Envoy recibió su config *inicial* desde istiod. Si nunca se activa, el proxy no puede alcanzar a istiod.

```
$ kubectl -n shop describe pod catalog-v1-6c9f4b7d8f-4nq2z | sed -n '/Events/,$p'
Events:
  Type     Reason     Message
  ----     ------     -------
  Warning  Unhealthy  Readiness probe failed: Get "http://10.244.1.7:15021/healthz/ready":
                      dial tcp 10.244.1.7:15021: connect: connection refused

$ kubectl -n shop logs catalog-v1-6c9f4b7d8f-4nq2z -c istio-proxy | grep -i "connect\|error" | head
warning envoy config    StreamAggregatedResources gRPC config stream to xds-grpc closed:
                        14, connection error: desc = "transport: Error while dialing:
                        dial tcp 10.96.0.10:15012: i/o timeout"
```

**Escalera de causa raíz:**
1. Confirmá que istiod está arriba: `kubectl -n istio-system get pods -l app=istiod`.
2. Confirmá que el proxy puede resolver/alcanzar `istiod.istio-system.svc:15012` — una `NetworkPolicy` que bloquee el egress a `istio-system` es el culpable clásico.
3. Confirmá que los certs inyectados son válidos: `istioctl proxy-config secret <pod>` (ver §5.3).

### 5.2 Síntoma: las ediciones de config no surten efecto — ¿siquiera se distribuyó?

Siempre empezá con `proxy-status`. Esto es la Capa 2: compara la versión de config que istiod *envió* contra lo que cada proxy *ACK'd*.

```
$ istioctl proxy-status
NAME                                       CLUSTER      CDS        LDS        EDS        RDS          ECDS         ISTIOD                       VERSION
catalog-v1-6c9f4b7d8f-4nq2z.shop           Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
catalog-v2-77d5c8b6c4-lm2xp.shop           Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
sleep-5d9f8c7b6d-w8kqv.shop                Kubernetes   STALE      SYNCED     SYNCED     STALE        NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
```

| Estado | Significado | Acción |
|---|---|---|
| `SYNCED` | Envoy hizo ACK del último push | Sano — pasá a la Capa 3 |
| `STALE` | istiod envió una actualización; el proxy no hizo ACK | Proxy sobrecargado, red inestable, o un NACK — leé los logs de istiod |
| `NOT SENT` | istiod no tiene nada de este tipo para enviar | Usualmente benigno (ej. no hay recursos ECDS) |

Un **`STALE` persistente** significa una config rechazada (NACK'd). Encontralo en istiod:

```
$ kubectl -n istio-system logs deploy/istiod | grep -i "nack\|rejected\|error" | tail
warning ads   ADS:LDS: ACK ERROR sleep-5d9f8c7b6d-w8kqv.shop Internal:Error adding/updating
              listener(s) 0.0.0.0_9080: error initializing configuration '...':
              duplicate listener 0.0.0.0_9080 found
```

Ese NACK te dice exactamente qué recurso rechazó Envoy — el arreglo pertenece a la Capa 1.

### 5.3 Síntoma: `503` en cada request — caminá la cadena LDS→RDS→CDS→EDS

Desde el cliente, la request falla de inmediato:

```
$ kubectl -n shop exec deploy/sleep -c sleep -- curl -s -o /dev/null -w "%{http_code}\n" catalog:9080
503
```

Un `503` desde el sidecar *local* es una falla de **upstream**. Leé el log de acceso y — críticamente — los **`RESPONSE_FLAGS`**, la explicación de un solo token de Envoy sobre *por qué*.

```
$ kubectl -n shop logs deploy/sleep -c istio-proxy | tail -1
[2026-08-08T14:22:07.451Z] "GET / HTTP/1.1" 503 UH
  "-" "-" 0 19 1 - "-" "curl/8.9.1" "8f2a...-" "catalog:9080"
  "-" outbound|9080|v1|catalog.shop.svc.cluster.local - 10.96.44.12:9080 10.244.2.9:39820 - default
```

El token después del status es la response flag: **`UH` = No Healthy Upstream.** Aquí está la tabla canónica de flags — memorizá las filas de arriba, cubren ~90% de los incidentes:

| Flag | Significado | Dónde suele estar la falla |
|---|---|---|
| **UH** | Sin upstream sano — el cluster tiene cero endpoints sanos | EDS vacío (labels de subset mal), o outlier detection expulsó todos los hosts |
| **NR** | No hay route configurada para la request | Desajuste de host o puerto en RDS/VirtualService |
| **NC** | No se encontró cluster | CDS faltante — DestinationRule/subset ausente |
| **UF** | Falla de conexión al upstream | Desajuste de mTLS, upstream caído, network policy |
| **UC** | Terminación de conexión del upstream (RST a mitad de stream) | Upstream crasheó, o desajuste plaintext↔mTLS |
| **UO** | Desbordamiento de upstream — circuit breaker disparado | Límites de `connectionPool` demasiado bajos para la carga |
| **URX** | Límite de reintentos/intentos superado | Upstream fallando persistentemente; reintentos agotados |
| **UT** | Timeout de request al upstream | `timeout`/`perTryTimeout` más corto que el backend |
| **DC** | Terminación de conexión del downstream | El cliente colgó |
| **RL** | Rate limited (local) | `EnvoyFilter`/rate limit local |
| **LH** | Falló el health-check local | La app falla su propia health probe |

`UH` dice que el cluster existe pero no tiene **endpoints sanos**. Descendé a la Capa 3 y leé el cluster y sus endpoints:

```
$ istioctl proxy-config cluster deploy/sleep.shop --fqdn catalog.shop.svc.cluster.local --subset v1
SERVICE FQDN                            PORT     SUBSET   DIRECTION     TYPE     DESTINATION RULE
catalog.shop.svc.cluster.local          9080     v1       outbound      EDS      catalog.shop

$ istioctl proxy-config endpoints deploy/sleep.shop --cluster \
    "outbound|9080|v1|catalog.shop.svc.cluster.local"
ENDPOINT   STATUS   OUTLIER CHECK   CLUSTER
                                    outbound|9080|v1|catalog.shop.svc.cluster.local
```

Lista de endpoints vacía → el **selector del subset no matcheó ningún pod**, o **outlier detection los expulsó**. Cruzá los labels del subset contra los pods:

```
$ kubectl -n shop get pods -l app=catalog --show-labels
NAME                          READY   STATUS    LABELS
catalog-v1-6c9f4b7d8f-4nq2z   2/2     Running   app=catalog,version=v1,...
catalog-v2-77d5c8b6c4-lm2xp   2/2     Running   app=catalog,version=v2,...
```

Si el subset del `DestinationRule` decía `labels: { version: v1.0 }` pero los pods llevan `version: v1`, EDS está vacío y obtenés `UH` en el 90% del tráfico ruteado a `v1`. **El subset es un selector de labels; un typo ahí es invisible para `kubectl` y solo aparece como un EDS vacío.**

Si los endpoints *sí* existen pero muestran `STATUS: UNHEALTHY / OUTLIER CHECK: FAILED`, entonces **outlier detection** (§4.2) los expulsó tras 5 `5xx` consecutivos — el arreglo es la estabilidad del upstream, no el routing.

### 5.4 Síntoma: `503 UF`/`UC` con un desajuste de mTLS (la trampa de STRICT)

El incidente del plano de datos más común del mundo real: un cliente sin sidecar (o en modo `DISABLE`) le habla a un servicio bajo `PeerAuthentication` `STRICT`. El Envoy del lado receptor exige un cert de cliente; el plaintext es reseteado.

Reproducilo haciendo curl desde un pod **fuera de la malla** (sin sidecar) hacia `catalog`:

```
$ kubectl run raw --image=curlimages/curl:8.9.1 -n default --restart=Never -- \
    sleep infinity
$ kubectl -n default exec raw -- curl -s -o /dev/null -w "%{http_code}\n" \
    catalog.shop:9080
000        # connection reset — TLS handshake with no client cert
```

En el proxy *receptor* el log muestra `UF`/`UC` y un error de TLS:

```
$ kubectl -n shop logs catalog-v1-6c9f4b7d8f-4nq2z -c istio-proxy | grep -i tls | tail -1
warning envoy conn_handler   TLS error: 268435612:SSL routines:
                             OPENSSL_internal:HTTP_REQUEST  ← plaintext hit an mTLS listener
```

**Diagnosticá mTLS de forma autoritativa** con `x describe` — imprime la política *efectiva* para un pod, reconciliando `PeerAuthentication` + `DestinationRule`:

```
$ istioctl x describe pod catalog-v1-6c9f4b7d8f-4nq2z.shop
Pod: catalog-v1-6c9f4b7d8f-4nq2z.shop
   Pod Revision: default
   Pod Ports: 9080 (catalog), 15090 (istio-proxy)
--------------------
Service: catalog.shop
   Port: http 9080/HTTP targets pod port 9080
DestinationRule: catalog.shop for "catalog.shop.svc.cluster.local"
   Matching subsets: v1,v2
   Traffic Policy TLS Mode: ISTIO_MUTUAL
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT     ← inbound requires client certs
```

Y confirmá que los certs realmente existen y no están vencidos (SDS / Capa 3):

```
$ istioctl proxy-config secret catalog-v1-6c9f4b7d8f-4nq2z.shop
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2a:f1:...:9c         2026-08-09T14:20:03Z     2026-08-08T14:18:03Z
ROOTCA            CA             ACTIVE     true           01                   2036-08-05T09:11:44Z     2026-08-05T09:11:44Z
```

`VALID CERT: false` o un `NOT AFTER` vencido apunta a una falla de rotación de certs (el proxy no puede alcanzar la CA en el `15012`). Aquí los certs son válidos — la falla es puramente que el llamante envió plaintext. **Opciones de arreglo, con sus compromisos:**

| Arreglo | Efecto | Compromiso |
|---|---|---|
| Meter al llamante en la malla (inyectar sidecar) | El llamante presenta un cert → mTLS tiene éxito | Correcto a largo plazo; requiere que el llamante sea gestionado por la malla |
| `PeerAuthentication mode: PERMISSIVE` | Acepta *ambos*, mTLS y plaintext | Debilita zero-trust; usar solo durante la migración |
| Excepción de `PeerAuthentication` a nivel de puerto | STRICT en todos lados menos un puerto PERMISSIVE | Quirúrgico; riesgo de drift/excepción olvidada |

### 5.5 Síntoma: `404`/`NR` — la request no matcheó ninguna route

`NR` significa que la request llegó a un listener pero **ninguna route matcheó**. Leé las routes efectivas y confirmá que los `domains`/`match` realmente cubren tu request:

```
$ istioctl proxy-config routes deploy/sleep.shop --name 9080 -o json | \
    jq '.[].virtualHosts[] | {name, domains}'
{
  "name": "catalog.shop.svc.cluster.local:9080",
  "domains": [
    "catalog.shop.svc.cluster.local",
    "catalog.shop.svc.cluster.local:9080",
    "catalog", "catalog:9080",
    "catalog.shop", "catalog.shop:9080",
    "catalog.shop.svc", "catalog.shop.svc:9080",
    "10.96.44.12", "10.96.44.12:9080"
  ]
}
```

Si tu `curl` usó un Host header (`-H "Host: catalog.other"`) que no está en `domains`, obtenés `NR`. Para gateways, `NR` suele significar que el `VirtualService` no está bindeado al `Gateway` (falta la entrada `gateways:` o los `hosts` están mal).

### 5.6 Síntoma: `503 UC`/`URX` intermitentes bajo carga — connection pools y resets por idle

Envoy multiplexa conexiones upstream. Dos clásicos de producción:

- **`maxRequestsPerConnection: 0`** (ilimitado) + un upstream (o un LB intermedio) que cierra keep-alives idle → Envoy reutiliza una conexión medio cerrada → `UC`. Setear `maxRequestsPerConnection: 1` o un `idleTimeout` corto lo mitiga.
- **Circuit breaking (`UO`)** cuando `http1MaxPendingRequests`/`maxConnections` son demasiado bajos para la carga real. La prueba definitiva es el contador de Envoy, no una conjetura:

```
$ kubectl -n shop exec deploy/sleep -c istio-proxy -- \
    curl -s localhost:15000/stats | grep 'catalog.*v1.*overflow'
cluster.outbound|9080|v1|catalog.shop.svc.cluster.local.upstream_cx_pool_overflow: 0
cluster.outbound|9080|v1|catalog.shop.svc.cluster.local.upstream_rq_pending_overflow: 142
```

`upstream_rq_pending_overflow: 142` = 142 requests rechazadas por el circuit breaker de pending-request → subí `http1MaxPendingRequests` o escalá el backend. **El contador es la verdad; la flag del log `UO` es solo el síntoma.**

---

## 6. Herramientas transversales a las que deberías recurrir

### 6.1 `istioctl analyze` — atrapá errores de Capa 1 antes de que se envíen

```
$ istioctl analyze -n shop
Warning [IST0101] (VirtualService catalog.shop) Referenced host+subset in
  destination is not found: "catalog.shop.svc.cluster.local+v3".
Error [IST0106] (DestinationRule catalog.shop) Schema validation error:
  subsets[2].labels: unknown field
Info  [IST0102] (Namespace shop) The namespace is enabled for Istio injection.
```

Corré esto en CI contra tus manifiestos renderizados — convierte un incidente de `NR`/`NC` en runtime en una falla de build.

### 6.2 Subir la verbosidad del log de Envoy en vivo (sin reiniciar)

```
$ istioctl proxy-config log deploy/sleep.shop --level upstream:debug,router:debug
active loggers:
  ...
  router: debug
  upstream: debug

# ... reproduce the failure, read logs, then reset ...
$ istioctl proxy-config log deploy/sleep.shop --level warning
```

Esto cambia el logging de administración de Envoy en el `:15000` en el lugar — invaluable para un bug transitorio que no te podés dar el lujo de perder por un reinicio de pod.

### 6.3 Habilitar logging de acceso a nivel de malla cuando el perfil lo deshabilitó

Si los logs de acceso están vacíos, la malla puede tener `accessLogFile` sin setear. Activalo con un recurso `Telemetry` (preferido por sobre parchear la config de la malla):

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-access-logs
  namespace: istio-system          # istio-system = mesh-wide default
spec:
  accessLogging:
    - providers:
        - name: envoy               # the built-in Envoy file access log provider
```

### 6.4 El árbol de decisión compacto

```
503 / failure at the client sidecar
│
├─ pod not 2/2 Ready? ──────────────▶ §5.1  (proxy ↔ istiod on :15012, certs, NetworkPolicy)
│
├─ proxy-status STALE/persistent? ──▶ §5.2  (NACK — read istiod logs, fix the CRD)
│
└─ read access log RESPONSE_FLAGS:
     UH ─▶ empty EDS: subset labels? outlier ejection?      §5.3
     NC ─▶ missing cluster: DestinationRule/subset absent   §5.3
     NR ─▶ no route: VirtualService host/gateway binding    §5.5
     UF/UC + TLS error ─▶ mTLS mode mismatch (STRICT trap)   §5.4
     UO/URX ─▶ circuit breaking: check *overflow stats       §5.6
     UT ─▶ timeout shorter than backend latency             §5.6
```

---

## 7. Checklist de verificación (gate listo para producción)

Antes de declarar resuelto un problema del plano de datos, todo lo siguiente debe cumplirse para el proxy afectado:

1. **Inyección:** `kubectl get pod <p> -o jsonpath='{.spec.containers[*].name}'` incluye `istio-proxy`, y el pod está `2/2 Ready`.
2. **Distribución:** `istioctl proxy-status` muestra `SYNCED` para CDS/LDS/EDS/RDS en ese proxy.
3. **Sin errores de intención:** `istioctl analyze -n <ns>` no devuelve hallazgos de nivel `Error`.
4. **Cluster presente:** `istioctl proxy-config cluster <p> --fqdn <svc>` lista el destino.
5. **Endpoints sanos:** `istioctl proxy-config endpoints <p> --cluster <c>` muestra ≥1 endpoint con `STATUS: HEALTHY`.
6. **La route matchea:** los `domains` de `istioctl proxy-config routes <p>` incluyen la authority del llamante.
7. **mTLS coherente:** `istioctl x describe pod <p>` muestra el modo pretendido; `proxy-config secret <p>` muestra `VALID CERT: true` y un `NOT AFTER` futuro.
8. **Runtime limpio:** un `curl` en vivo devuelve el status esperado, y el campo `RESPONSE_FLAGS` del log de acceso es `-` (sin flag).
9. **Sin overflow de circuit-breaker:** los contadores `upstream_rq_pending_overflow` / `upstream_cx_overflow` están estables (no incrementando) bajo carga representativa.

Solo cuando 1–9 están en verde el camino del plano de datos queda probado de extremo a extremo — desde la distribución del plano de control hasta una request real en el cable.

---

## Referencias

- Istio — Diagnostic Tools overview: https://istio.io/latest/docs/ops/diagnostic-tools/
- Istio — Debugging Envoy and Istiod (`proxy-status`, `proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — Understand your mesh with `istioctl describe`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/
- Istio — Component debugging & config distribution: https://istio.io/latest/docs/ops/diagnostic-tools/component-debugging/
- Istio — Common problems / troubleshooting (503s, mTLS): https://istio.io/latest/docs/ops/common-problems/
- Istio — Network / traffic management problems: https://istio.io/latest/docs/ops/common-problems/network-issues/
- Istio — Security / mTLS problems: https://istio.io/latest/docs/ops/common-problems/security-issues/
- Istio — Ports used by the sidecar and control plane: https://istio.io/latest/docs/ops/deployment/application-requirements/
- Istio — Mutual TLS & `PeerAuthentication`: https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — Circuit breaking / outlier detection: https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — Enabling Envoy access logs: https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Istio — `Telemetry` API: https://istio.io/latest/docs/reference/config/telemetry/
- Envoy — Access log format & `%RESPONSE_FLAGS%`: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy — Admin interface (`/config_dump`, `/stats`, `/clusters`, `/logging`): https://www.envoyproxy.io/docs/envoy/latest/operations/admin
- Envoy — xDS / Aggregated Discovery Service protocol: https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf