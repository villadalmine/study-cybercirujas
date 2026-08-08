# Tema 2.1 — Troubleshooting Configuration (Istio Certified Associate)

> **Perfil:** SRE / Platform Architect. **Peso en examen:** 7.
> **Alcance:** diagnóstico de configuración en un service mesh Istio: cómo un objeto declarativo (`VirtualService`, `DestinationRule`, `Gateway`, `PeerAuthentication`, `Sidecar`) se traduce a configuración de dato-plano (Envoy), dónde se rompe esa traducción y qué herramienta observa cada capa.

---

## 1. Motivación y problema arquitectónico de producción

Istio es, en esencia, un **compilador de configuración distribuido**. El operador escribe intención de alto nivel en CRDs de Kubernetes; el control-plane (`istiod`, componente histórico *Pilot*) la traduce al protocolo **xDS** y la empuja a cada sidecar Envoy. El estudiante debe internalizar una idea incómoda:

> **El YAML que aplicaste NO es lo que enforcea el proxy.** Es solo la entrada del compilador. Entre `kubectl apply` y el comportamiento real de una request hay cinco fronteras donde la configuración puede degradarse — y cuatro de ellas fallan *en silencio*.

### 1.1. Las cinco fronteras de la configuración

```
┌─────────────────────────────────────────────────────────────────────┐
│ (1) Kubernetes API server  → valida sintaxis/schema del CRD (OpenAPI +│
│                               validating webhook istiod)              │
│         ▼  admitido                                                   │
│ (2) istiod (Pilot)         → traduce CRD → xDS. Puede admitir un CRD  │
│                               sintácticamente válido pero            │
│                               SEMÁNTICAMENTE roto (host inexistente)  │
│         ▼  push xDS (ADS: CDS→EDS→LDS→RDS)                            │
│ (3) Envoy (sidecar)        → ACEPTA o RECHAZA el recurso xDS. Un      │
│                               rechazo NO revierte el estado previo:   │
│                               el proxy sigue con config vieja (STALE) │
│         ▼  config aplicada                                            │
│ (4) Runtime de la request  → matching de listener/route/cluster,     │
│                               selección de endpoint, mTLS handshake   │
│         ▼                                                             │
│ (5) Comportamiento observado → 503, reset, timeout, ruteo incorrecto  │
└─────────────────────────────────────────────────────────────────────┘
```

**Los tres modos de falla que definen este dominio:**

| Modo de falla | Síntoma típico | Por qué es difícil |
|---|---|---|
| **Rechazo silencioso en Pilot** | El CRD existe, `kubectl get vs` lo muestra, pero no tiene efecto | K8s lo admitió; el error solo aparece en `istioctl analyze` o logs de `istiod` |
| **Config STALE** | Cambio aplicado hace minutos, sin efecto; unos pods sí, otros no | Envoy rechazó el push xDS y retuvo la config anterior; `proxy-status` marca `STALE` |
| **Válido pero semánticamente incorrecto** | 503 `NR`/`UH`, ruteo al backend equivocado | typo en `host`, `subset` inexistente, `port name` sin prefijo de protocolo — todo pasa la validación de schema |

La consecuencia arquitectónica: **no se puede depurar un mesh leyendo YAML.** Hay que inspeccionar el estado *materializado* en Envoy y compararlo contra la intención. Ese es exactamente el conjunto de skills que evalúa 2.1.

### 1.2. El protocolo xDS y por qué importa para el diagnóstico

Envoy se configura dinámicamente mediante APIs de descubrimiento (xDS), servidas por `istiod` sobre gRPC (ADS — *Aggregated Discovery Service*, un único stream ordenado):

| xDS | Recurso Envoy | Deriva de (Istio) | Falla observable |
|---|---|---|---|
| **LDS** (Listener) | Puertos/filter-chains donde escucha | `Gateway`, `Sidecar`, puertos de `Service` | request no matchea ningún listener → conexión colgada/reset |
| **RDS** (Route) | Reglas HTTP: match → cluster | `VirtualService` | `NR` (no route) — 404/503 |
| **CDS** (Cluster) | Upstreams (backends) | `Service` + `DestinationRule` (subsets, policy) | `NC` (no cluster), 503 tras route |
| **EDS** (Endpoint) | IPs:puertos de cada cluster | `EndpointSlice`/`Endpoints` de K8s | `UH` (no healthy upstream) |
| **SDS** (Secret) | Certificados mTLS | `istiod` CA / `PeerAuthentication` | reset TLS, `UF`, cert expirado |

**Regla mnemónica de diagnóstico:** el flujo de una request es **Listener → Route → Cluster → Endpoint**. Un 503 se diagnostica *en ese orden*: si el listener no existe, nunca llegás al route; si el route no matchea, nunca al cluster. El `RESPONSE_FLAG` del access log de Envoy te dice exactamente en qué eslabón se cortó.

---

## 2. Comparativas técnicas y herramientas de diagnóstico

### 2.1. Qué herramienta inspecciona qué frontera

| Frontera | Pregunta que responde | Herramienta | Costo |
|---|---|---|---|
| (1) Schema | ¿El CRD es sintácticamente válido? | validating webhook (automático) + `istioctl validate -f` | Gratis, offline |
| (2) Semántica | ¿Referencia hosts/subsets que existen? ¿namespace inyectado? | **`istioctl analyze`** | Gratis, sin tocar el dato-plano |
| (2→3) Propagación | ¿istiod empujó la config y Envoy la aceptó? | **`istioctl proxy-status`** | Gratis, 1 llamada a istiod |
| (3) Estado materializado | ¿Qué listeners/routes/clusters/endpoints tiene ESTE Envoy? | **`istioctl proxy-config`** | Gratis, dump del proxy |
| (4) Grafo lógico | ¿Cómo ve Istio el ruteo de este pod/servicio? | **`istioctl x describe pod/svc`** | Gratis |
| (5) Runtime | ¿Qué pasó con ESTA request? | Envoy **access logs** + `RESPONSE_FLAGS` | Gratis (si logging on) |
| Control-plane | ¿istiod rechazó/no computó la traducción? | `kubectl logs deploy/istiod -n istio-system` | Gratis |

### 2.2. `analyze` vs `proxy-status` vs `proxy-config` — el error clásico

Confundir estas tres es el error #1 de los candidatos. No son intercambiables:

| Aspecto | `istioctl analyze` | `istioctl proxy-status` | `istioctl proxy-config` |
|---|---|---|---|
| **Fuente de verdad** | Los CRDs (intención) | istiod ↔ Envoy (sincronización) | El Envoy vivo (realidad) |
| **Responde** | "¿Tu config tiene errores lógicos?" | "¿Está sincronizada y aceptada?" | "¿Qué config tiene realmente el proxy?" |
| **Detecta typo en `host`** | ✅ `IST0101` | ❌ (config válida se sincroniza igual) | ✅ (verás un cluster faltante) |
| **Detecta STALE** | ❌ | ✅ `STALE` / `NOT SENT` | Indirectamente (config vieja) |
| **Requiere el pod corriendo** | ❌ (funciona pre-deploy con `-f`) | ✅ | ✅ |
| **Ámbito** | namespace/cluster | todos los proxies | un proxy concreto |

**Trade-off operativo:** `analyze` es tu *pre-flight* (barato, corré en CI antes de aplicar). `proxy-status` es tu *health check* de propagación. `proxy-config` es la *autopsia* cuando el 503 ya está ocurriendo. Un pipeline maduro corre `istioctl analyze` en CI y falla el merge si hay `Error`.

### 2.3. Subcomandos de `proxy-config` (mapa mental)

| Subcomando | Muestra | Se usa cuando el flag es… |
|---|---|---|
| `proxy-config listener` | Listeners (LDS) | conexión no matchea / puerto mal declarado |
| `proxy-config route` | Rutas HTTP (RDS) | `NR` (no route), ruteo incorrecto |
| `proxy-config cluster` | Clusters/subsets (CDS) | 503 tras rutear, subset faltante |
| `proxy-config endpoint` | Endpoints + health (EDS) | `UH` (no healthy upstream) |
| `proxy-config secret` | Certs mTLS (SDS) | reset TLS, `UF`, cert vencido |
| `proxy-config bootstrap` | Config estática inicial | problemas de arranque del proxy |
| `proxy-config log` | Niveles de log por componente | subir verbosidad para trace |
| `proxy-config all -o json` | Volcado completo (config_dump) | análisis profundo/diff |

---

## 3. Manifiestos completos (escenario de referencia)

Escenario: servicio `payments` con dos versiones (`v1`, `v2`) en el namespace `shop`, expuesto por un ingress gateway, con mTLS **STRICT** y canary 90/10. Estos manifiestos son la **línea base correcta**; en la §5 introducimos fallas reales sobre ellos.

```yaml
# 00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    # Habilita inyección automática del sidecar (default revision).
    # Sin este label -> pods SIN Envoy -> el mesh no ve el tráfico.
    istio-injection: enabled
```

```yaml
# 10-deploy-payments-v1.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-v1
  namespace: shop
  labels:
    app: payments
    version: v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments
      version: v1
  template:
    metadata:
      labels:
        app: payments          # <- usado por Service selector
        version: v1            # <- usado por DestinationRule subset
    spec:
      serviceAccountName: payments
      containers:
        - name: payments
          image: ghcr.io/example/payments:1.4.0
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-v2
  namespace: shop
  labels:
    app: payments
    version: v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments
      version: v2
  template:
    metadata:
      labels:
        app: payments
        version: v2
    spec:
      serviceAccountName: payments
      containers:
        - name: payments
          image: ghcr.io/example/payments:2.0.0
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
```

```yaml
# 20-service.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments
  namespace: shop
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: shop
  labels:
    app: payments
spec:
  selector:
    app: payments        # NO incluye 'version': el Service abarca v1 y v2
  ports:
    - name: http         # CRÍTICO: el prefijo del nombre determina el
      port: 8080         # protocolo que Istio le asigna al listener.
      targetPort: 8080   # 'http', 'http2', 'grpc', 'tcp', 'tls'...
      appProtocol: http  # Alternativa moderna al naming (Istio >=1.16)
```

```yaml
# 30-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments
  namespace: shop
spec:
  host: payments.shop.svc.cluster.local   # FQDN del Service
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL                   # el sidecar cliente usa mTLS de Istio
    connectionPool:
      http:
        http1MaxPendingRequests: 100
        maxRequestsPerConnection: 0
      tcp:
        maxConnections: 200
    outlierDetection:                      # ejección de endpoints enfermos
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1        # <- referenciado por el VirtualService
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

```yaml
# 40-virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payments
  namespace: shop
spec:
  hosts:
    - payments.shop.svc.cluster.local   # tráfico interno (mesh)
    - payments.example.com              # tráfico externo (via gateway)
  gateways:
    - mesh                              # 'mesh' = todos los sidecars
    - shop/payments-gateway             # ns/name del Gateway de ingress
  http:
    - name: canary
      route:
        - destination:
            host: payments.shop.svc.cluster.local
            subset: v1
          weight: 90
        - destination:
            host: payments.shop.svc.cluster.local
            subset: v2
          weight: 10
      timeout: 5s
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: connect-failure,refused-stream,503
```

```yaml
# 50-gateway.yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: payments-gateway
  namespace: shop
spec:
  selector:
    istio: ingressgateway   # DEBE matchear los labels del pod del ingress-gw
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "payments.example.com"
```

```yaml
# 60-peerauthentication.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: shop
spec:
  mtls:
    mode: STRICT   # el server RECHAZA tráfico plaintext. Fuente común de 503.
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1. Verificación básica del entorno

```console
$ istioctl version
client version: 1.22.1
control plane version: 1.22.1
data plane version: 1.22.1 (5 proxies)
```

> **Señal de alarma:** si `data plane version` lista varias versiones (ej. `1.21.3 (3 proxies), 1.22.1 (2 proxies)`), tenés sidecars sin reiniciar tras un upgrade. Skew de versión ⇒ campos xDS ignorados silenciosamente.

### 4.2. `istioctl analyze` — validación semántica (frontera 2)

```console
$ istioctl analyze -n shop
✔ No validation issues found when analyzing namespace: shop.
```

Ahora un ejemplo con problemas (ver §5 para las causas):

```console
$ istioctl analyze -n shop
Warning [IST0101] (VirtualService shop/payments) Referenced host+subset in destinationrule not found: "payments.shop.svc.cluster.local+v3"
Warning [IST0102] (Namespace shop) The namespace is not enabled for Istio injection. Run 'kubectl label namespace shop istio-injection=enabled' to enable it, or 'kubectl label namespace shop istio-injection=disabled' to explicitly mark it as not needing injection.
Info    [IST0118] (Service shop/payments) Port name  (port: 8080, targetPort: 8080) doesn't follow the naming convention of Istio port and may not be able to identify the protocol. Istio protocol selection is based on port name.
Error: Analyzers found issues when analyzing namespace: shop.
See https://istio.io/latest/docs/reference/config/analysis for more information about causes and resolutions.
```

> El *exit code* es **≠ 0** cuando hay al menos un `Error`, lo que lo hace apto para gate de CI. Con `--use-kube=false -f ./manifests/` valida offline, sin cluster.

### 4.3. `istioctl proxy-status` — sincronización (frontera 2→3)

```console
$ istioctl proxy-status
NAME                                       CLUSTER    CDS        LDS        EDS        RDS        ECDS       ISTIOD                     VERSION
payments-v1-6c9f7b-abcde.shop              Kubernetes SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-5f8c9-2xk7q         1.22.1
payments-v1-6c9f7b-fghij.shop              Kubernetes SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-5f8c9-2xk7q         1.22.1
payments-v2-7d1a2c-klmno.shop              Kubernetes SYNCED     STALE      SYNCED     STALE      NOT SENT   istiod-5f8c9-2xk7q         1.22.1
ingressgateway-84b6-pqrst.istio-system     Kubernetes SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-5f8c9-2xk7q         1.22.1
```

Interpretación de estados:

| Estado | Significado | Acción |
|---|---|---|
| `SYNCED` | Envoy confirmó (ACK) la última config enviada | OK |
| `STALE` | istiod envió, Envoy **no confirmó** (o rechazó, o gRPC lento) | Ver logs de `istiod` y del proxy; buscar `NACK`/`rejecting` |
| `NOT SENT` | istiod nunca envió ese tipo (normal para `ECDS` si no hay `EnvoyFilter`) | Normal salvo que esperes ese recurso |
| (pod ausente) | El proxy no aparece | Sidecar no inyectado o pod caído |

> Arriba, `payments-v2` está `STALE` en LDS/RDS: aceptó CDS/EDS pero **rechazó** el listener/route nuevo. Retiene config vieja — *fail-static*.

### 4.4. `istioctl proxy-config` — estado materializado (frontera 3)

**Clusters (¿existe el backend y su subset?):**

```console
$ istioctl proxy-config cluster deploy/payments-v1 -n shop \
    --fqdn payments.shop.svc.cluster.local
SERVICE FQDN                          PORT   SUBSET   DIRECTION   TYPE   DESTINATION RULE
payments.shop.svc.cluster.local       8080   -        outbound    EDS    payments.shop
payments.shop.svc.cluster.local       8080   v1       outbound    EDS    payments.shop
payments.shop.svc.cluster.local       8080   v2       outbound    EDS    payments.shop
```

> Si el `VirtualService` apunta a `subset: v3` y acá no aparece la fila `v3`, ahí está el 503. El cluster que Envoy busca sería `outbound|8080|v3|payments.shop.svc.cluster.local` y no existe ⇒ `NR`/503.

**Listeners (¿el puerto está declarado con el protocolo correcto?):**

```console
$ istioctl proxy-config listener deploy/payments-v1 -n shop --port 8080
ADDRESS   PORT   MATCH                                DESTINATION
0.0.0.0   8080   Trans: raw_buffer; App: HTTP         Route: 8080
0.0.0.0   8080   Trans: raw_buffer                    Cluster: BlackHoleCluster
0.0.0.0   8080   Trans: tls                           Cluster: BlackHoleCluster
```

> `App: HTTP` confirma que Istio detectó protocolo HTTP (por el `name: http` del Service). Si el puerto se llamara `payments` (sin prefijo), verías `App: TCP` y **NO** habría filtros HTTP: sin routing L7, sin `VirtualService`, sin retries.

**Routes (¿la ruta matchea y a qué cluster manda?):**

```console
$ istioctl proxy-config route deploy/payments-v1 -n shop --name 8080 -o json | \
    jq '.[].virtualHosts[].routes[].route.weightedClusters'
{
  "clusters": [
    { "name": "outbound|8080|v1|payments.shop.svc.cluster.local", "weight": 90 },
    { "name": "outbound|8080|v2|payments.shop.svc.cluster.local", "weight": 10 }
  ]
}
```

**Endpoints (¿hay backends sanos?):**

```console
$ istioctl proxy-config endpoint deploy/payments-v1 -n shop \
    --cluster "outbound|8080|v1|payments.shop.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK   CLUSTER
10.244.1.23:8080     HEALTHY     OK              outbound|8080|v1|payments.shop.svc.cluster.local
10.244.2.41:8080     HEALTHY     OK              outbound|8080|v1|payments.shop.svc.cluster.local
```

> `STATUS HEALTHY` + `OUTLIER CHECK OK`. Si vieras `OUTLIER CHECK FAILED`, el endpoint fue **ejectado** por `outlierDetection` (5xx consecutivos) ⇒ 503 `UH` cuando todos caen.

**Secrets (mTLS — frontera SDS):**

```console
$ istioctl proxy-config secret deploy/payments-v1 -n shop
RESOURCE NAME   TYPE       STATUS   VALID CERT   SERIAL NUMBER      NOT AFTER              NOT BEFORE
default         Cert Chain ACTIVE   true         3a9f...c1          2026-08-09T11:20:33Z   2026-08-08T11:18:33Z
ROOTCA          CA         ACTIVE   true         88b2...7e          2027-08-08T09:00:00Z   2026-08-08T09:00:00Z
```

> `VALID CERT: true` y `NOT AFTER` en el futuro. Un cert `default` vencido o `STATUS: WARMING` explica resets TLS y 503 `UF` intermitentes.

### 4.5. `istioctl x describe` — el grafo lógico

```console
$ istioctl experimental describe pod payments-v1-6c9f7b-abcde -n shop
Pod: payments-v1-6c9f7b-abcde
   Pod Revision: default
   Pod Ports: 8080 (payments), 15090 (istio-proxy)
--------------------
Service: payments
   Port: http 8080/HTTP targets pod port 8080
DestinationRule: payments for "payments.shop.svc.cluster.local"
   Matching subsets: v1
      (Non-matching subsets v2)
   Traffic Policy TLS Mode: ISTIO_MUTUAL
VirtualService: payments
   Weight 90%
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
```

> Una sola pantalla te dice: puerto HTTP OK, subset `v1` matchea, mTLS `STRICT`, peso 90%. Si `Port` dijera `8080/UnsupportedProtocol` o faltara el `VirtualService`, el bug salta a la vista.

### 4.6. Runtime: access logs y `RESPONSE_FLAGS`

```console
$ kubectl logs -n shop deploy/payments-v1 -c istio-proxy --tail=1
[2026-08-08T14:03:11.512Z] "GET /charge HTTP/1.1" 503 UH
  "-" "no_healthy_upstream" 0 19 4 - "-" "curl/8.4.0"
  "7c1f-..." "payments.shop:8080"
  "outbound|8080|v1|payments.shop.svc.cluster.local" -
  10.244.1.9:0 10.96.4.12:8080 10.244.1.9:51122 - default
```

El campo tras el status (`503 UH`) es el `RESPONSE_FLAG` — el diagnóstico condensado:

| Flag | Significado | Eslabón roto | Causa raíz frecuente |
|---|---|---|---|
| `NR` | No route configured | RDS | `VirtualService` no matchea host/path; subset/host con typo |
| `NC` | No cluster found | CDS | `DestinationRule`/subset ausente; host inexistente |
| `UH` | No healthy upstream | EDS | 0 endpoints; todos ejectados por outlier; readiness fallando |
| `UF` | Upstream connection failure | Conexión | mTLS mismatch; backend caído; NetworkPolicy |
| `UC` | Upstream connection termination | Conexión | keep-alive/timeout del server; app cierra la conexión |
| `UO` | Upstream overflow | Circuit breaker | `connectionPool` saturado (backpressure) |
| `URX` | Retry limit exceeded | Retries | backend devuelve 5xx repetido |
| `-` | Sin flag (respuesta normal) | — | el 5xx vino del backend, no de Envoy |

> **Regla de oro:** un `503` **con** flag Envoy (`UH`/`NR`/`UF`) es un problema de *mesh/config*. Un `503` **sin** flag (`-`) lo generó tu aplicación. No pierdas horas en Istio si el flag es `-`.

### 4.7. Subir verbosidad en caliente (sin reiniciar el pod)

```console
$ istioctl proxy-config log deploy/payments-v1 -n shop --level "connection:debug,router:debug"
payments-v1-6c9f7b-abcde.shop:
active loggers:
  connection: debug
  router: debug
  (... resto en 'warning')
```

Y para inspeccionar el control-plane cuando algo se rechaza:

```console
$ kubectl logs -n istio-system deploy/istiod --tail=200 | grep -iE "rejected|nack|error"
2026-08-08T14:01:55.220Z  warn  ads  ADS:LDS: ACK ERROR ... Internal:Error adding/updating
  listener(s) 0.0.0.0_8080: error building filter chain ... version "2.0.0" NACK
```

---

## 5. Guía de verificación y diagnóstico de fallas

Metodología: recorrer las fronteras **de afuera hacia adentro**, dejando que el `RESPONSE_FLAG` te salte etapas. Nunca empieces editando YAML; primero *observá el estado materializado*.

### 5.1. Runbook de decisión (503 en el mesh)

```
1. ¿Hay sidecar?  kubectl get pod -n shop -o jsonpath='{.items[*].spec.containers[*].name}'
   └─ ¿aparece 'istio-proxy'?  NO → §5.2 (inyección)
2. istioctl proxy-status
   └─ ¿STALE / falta el pod?  SÍ → §5.6 (config rechazada / no propagada)
3. istioctl analyze -n shop
   └─ ¿Error/Warning IST0101/IST0118?  SÍ → §5.3 / §5.4
4. Leé el RESPONSE_FLAG del access log:
   ├─ NR / NC  → §5.4  (route/cluster: host o subset mal)
   ├─ UH       → §5.5  (endpoints: 0 sanos / outlier)
   ├─ UF + reset TLS → §5.7 (mTLS mismatch)
   └─ '-'      → NO es Istio: la app devolvió el 5xx
```

### 5.2. Falla: sidecar NO inyectado

**Síntoma:** el pod tiene 1 container en vez de 2; el tráfico no aparece en el mesh; `proxy-status` no lista el pod.

```console
$ kubectl get pod payments-v1-6c9f7b-abcde -n shop \
    -o jsonpath='{.spec.containers[*].name}'
payments
```

Solo `payments`, falta `istio-proxy`. Causas y verificación:

```console
$ kubectl get ns shop --show-labels
NAME   STATUS   AGE   LABELS
shop   Active   2d    kubernetes.io/metadata.name=shop        # falta istio-injection!

# Fix:
$ kubectl label namespace shop istio-injection=enabled --overwrite
$ kubectl rollout restart deploy/payments-v1 deploy/payments-v2 -n shop
```

> Checklist de por qué NO se inyecta: (1) label del namespace ausente; (2) `sidecar.istio.io/inject: "false"` en el pod; (3) `webhook` `istio-sidecar-injector` caído (`kubectl get mutatingwebhookconfiguration`); (4) `NamespaceSelector` de la revisión no matchea (canary/rev tags). **La inyección solo ocurre al crear el pod** — hay que reiniciar, no basta con poner el label.

### 5.3. Falla: `port name` sin protocolo → sin L7

**Síntoma:** `VirtualService` "no hace nada" — sin routing por peso, sin retries, sin fault injection.

```console
$ istioctl analyze -n shop
Info [IST0118] (Service shop/payments) Port name  (port: 8080) doesn't follow the naming convention...

$ istioctl proxy-config listener deploy/payments-v1 -n shop --port 8080
ADDRESS   PORT   MATCH             DESTINATION
0.0.0.0   8080   Trans: raw_buffer Cluster: outbound|8080||payments.shop.svc.cluster.local
```

`Cluster:` directo (no `Route:`) ⇒ Envoy trata el puerto como **TCP opaco**. Fix: nombrar el puerto `http` (o usar `appProtocol: http`) y reaplicar. Verificación de éxito: la línea del listener debe mostrar `App: HTTP` + `Route: 8080` (§4.4).

### 5.4. Falla: `host`/`subset` inexistente → `NR`/`NC`

**Síntoma:** `503 NR` o `503 NC` en el access log.

```console
# El VS apunta a subset v3 que no existe en el DestinationRule:
$ istioctl analyze -n shop
Warning [IST0101] (VirtualService shop/payments) Referenced host+subset in
destinationrule not found: "payments.shop.svc.cluster.local+v3"

# Confirmación en el dato-plano: el cluster v3 no existe
$ istioctl proxy-config cluster deploy/payments-v1 -n shop \
    --fqdn payments.shop.svc.cluster.local | grep v3
# (sin salida) -> Envoy no tiene 'outbound|8080|v3|...' -> NR
```

> **Trampa clásica:** `host` con FQDN corto/incorrecto. `host: payments` desde OTRO namespace resuelve mal; usá siempre el FQDN `payments.shop.svc.cluster.local`. `istioctl analyze` (IST0101) lo detecta *antes* de que llegue un 503.

### 5.5. Falla: `UH` — no healthy upstream

```console
$ istioctl proxy-config endpoint deploy/payments-v1 -n shop \
    --cluster "outbound|8080|v2|payments.shop.svc.cluster.local"
ENDPOINT   STATUS   OUTLIER CHECK   CLUSTER
# (sin endpoints) -> el subset v2 no tiene pods Ready
```

Cadena de verificación: **subset labels ↔ pod labels ↔ readiness**.

```console
$ kubectl get pods -n shop -l app=payments,version=v2
NAME                          READY   STATUS    RESTARTS   AGE
payments-v2-7d1a2c-klmno      0/2     Running   0          40s      # 0/2 -> no Ready

$ kubectl describe pod payments-v2-7d1a2c-klmno -n shop | grep -A3 Readiness
    Readiness probe failed: HTTP probe failed with statuscode: 500
```

Causas de `UH`: (1) 0 pods con el label del subset; (2) todos NotReady (readiness fallando); (3) todos **ejectados** por `outlierDetection` — se ve como `OUTLIER CHECK FAILED`. Si es outlier, la app está devolviendo 5xx y Envoy la sacó de rotación (comportamiento *correcto*, mirá la app).

### 5.6. Falla: config STALE / rechazada por Envoy

**Síntoma:** cambio aplicado, sin efecto; `proxy-status` = `STALE`.

```console
$ istioctl proxy-status | grep payments-v2
payments-v2-7d1a2c-klmno.shop  Kubernetes  SYNCED  STALE  SYNCED  STALE  NOT SENT  istiod-... 1.22.1

$ kubectl logs -n istio-system deploy/istiod | grep -i "nack\|rejected" | tail
... ADS:LDS: ACK ERROR ... rejecting ... duplicate listener ... EnvoyFilter shop/broken-ef

# Ver el error exacto que reporta el propio Envoy:
$ istioctl proxy-config all deploy/payments-v2 -n shop -o json | \
    jq '.configs[]?.dynamicActiveClusters // empty' | head
```

> `STALE` casi siempre significa que un `EnvoyFilter` mal formado, un skew de versión, o un recurso duplicado hizo que Envoy hiciera **NACK** del push. Envoy retiene la config previa (*fail-static*): el mesh sigue "funcionando con lo viejo". Corregí/eliminá el recurso ofensor y confirmá que vuelve a `SYNCED`.

### 5.7. Falla: mTLS mismatch (STRICT vs plaintext) → `UF`/reset

**Síntoma:** `503 UF`, `connection reset by peer`, intermitencia tras poner `PeerAuthentication: STRICT`.

Escenario típico: un cliente **sin sidecar** (o un `DestinationRule` con `tls.mode: DISABLE`) hablándole a un server `STRICT`.

```console
# 1. ¿Qué modo efectivo tiene el workload server?
$ istioctl x describe pod payments-v1-6c9f7b-abcde -n shop | grep -i mtls
Effective PeerAuthentication: Workload mTLS mode: STRICT

# 2. ¿El cliente está mandando mTLS? Revisá el DestinationRule del lado cliente:
$ kubectl get destinationrule -n shop payments -o jsonpath='{.spec.trafficPolicy.tls.mode}'
DISABLE            # <- CONFLICTO: server STRICT exige mTLS, cliente lo DESHABILITA

# 3. Confirmación desde el server (filter chain no matchea plaintext):
$ kubectl logs -n shop deploy/payments-v1 -c istio-proxy | grep -i "tls\|handshake" | tail
... "GET /charge HTTP/1.1" 503 UF "-" "TLS_error:...:SSLV3_ALERT_CERTIFICATE_UNKNOWN"
```

Matriz de compatibilidad mTLS (server `PeerAuthentication` × cliente `DestinationRule tls.mode`):

| Server ↓ / Cliente → | `ISTIO_MUTUAL` | `DISABLE` (plaintext) | sin sidecar |
|---|---|---|---|
| `STRICT` | ✅ OK | ❌ `UF`/reset | ❌ `UF`/reset |
| `PERMISSIVE` | ✅ OK (mTLS) | ✅ OK (plaintext) | ✅ OK (plaintext) |
| `DISABLE` | ❌ (cliente espera TLS) | ✅ OK | ✅ OK |

> **Trade-off de migración:** por eso el path recomendado a `STRICT` pasa por `PERMISSIVE` primero (acepta ambos), se verifica con la métrica `istio_requests_total{connection_security_policy="mutual_tls"}` que todo el tráfico ya es mTLS, y **recién ahí** se cierra a `STRICT`. Saltar directo a `STRICT` con un cliente legacy fuera del mesh = 503 masivo.

### 5.8. Falla: `Gateway` sin efecto (selector mismatch)

**Síntoma:** el host externo da 404/timeout; el ingress no rutea.

```console
# El Gateway selecciona por label; debe matchear el pod del ingressgateway:
$ kubectl get gateway payments-gateway -n shop -o jsonpath='{.spec.selector}'
{"istio":"ingressgateway"}

$ kubectl get pods -n istio-system -l istio=ingressgateway
NAME                            READY   STATUS
istio-ingressgateway-84b6-...   1/1     Running          # OK, el label matchea

# ¿El listener del gateway tiene el host?
$ istioctl proxy-config route deploy/istio-ingressgateway -n istio-system \
    -o json | jq '.[].virtualHosts[].domains'
[ "payments.example.com", "payments.example.com:80" ]
```

> Dos causas dominantes: (1) `selector` del `Gateway` no matchea los labels del pod ingress (verás listeners sin el server) ; (2) el `VirtualService` no lista el `Gateway` en `spec.gateways` (o falta `mesh`), así que el host queda sin ruta. `istioctl analyze` emite `IST0104` cuando un `Gateway` no puede bindear a ningún workload.

### 5.9. Checklist de verificación (post-fix)

```console
# 1. Semántica limpia
$ istioctl analyze -n shop            # -> "No validation issues found"
# 2. Todo sincronizado
$ istioctl proxy-status | grep shop   # -> todas las columnas SYNCED
# 3. La ruta materializada es la esperada
$ istioctl proxy-config route deploy/payments-v1 -n shop --name 8080 -o json \
    | jq '.[].virtualHosts[].routes[].route.weightedClusters'
# 4. Endpoints sanos en ambos subsets
$ for s in v1 v2; do
    istioctl proxy-config endpoint deploy/payments-v1 -n shop \
      --cluster "outbound|8080|$s|payments.shop.svc.cluster.local"
  done
# 5. Prueba end-to-end desde dentro del mesh
$ kubectl exec -n shop deploy/payments-v1 -c payments -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payments.shop.svc.cluster.local:8080/charge
200
# 6. Confirmar mTLS efectivo (no plaintext)
$ istioctl x describe pod -n shop payments-v1-6c9f7b-abcde | grep mTLS
```

---

## 6. Referencias

- CNCF — Istio Certified Associate (ICA) Curriculum (repositorio oficial): <https://github.com/cncf/curriculum> · PDF: <https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf>
- Istio — Diagnostic Tools (índice): <https://istio.io/latest/docs/ops/diagnostic-tools/>
- Istio — Debugging Envoy and Istiod with `proxy-status` / `proxy-config`: <https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/>
- Istio — Diagnose your Configuration with `istioctl analyze`: <https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/>
- Istio — Understand your Mesh with `istioctl describe`: <https://istio.io/latest/docs/ops/diagnostic-tools/understand-your-mesh/>
- Istio — Configuration Analysis Messages (catálogo IST0xxx): <https://istio.io/latest/docs/reference/config/analysis/>
- Istio — Common Problems (routing, mTLS, injection): <https://istio.io/latest/docs/ops/common-problems/>
- Istio — Sidecar Injection Problems: <https://istio.io/latest/docs/ops/common-problems/injection/>
- Istio — Network / Traffic Management Problems (503, no route): <https://istio.io/latest/docs/ops/common-problems/network-issues/>
- Istio — Security Problems (mTLS troubleshooting): <https://istio.io/latest/docs/ops/common-problems/security-issues/>
- Istio — Mutual TLS Migration (PERMISSIVE → STRICT): <https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/>
- Istio — Protocol Selection (port naming / `appProtocol`): <https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/>
- Istio — Reference: `VirtualService`, `DestinationRule`, `Gateway`, `PeerAuthentication`: <https://istio.io/latest/docs/reference/config/networking/> · <https://istio.io/latest/docs/reference/config/security/peer_authentication/>
- Envoy — Access Logging & `RESPONSE_FLAGS` (UH/UF/NR/NC/UO…): <https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage>
- Envoy — xDS / Aggregated Discovery Service (ADS) overview: <https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/dynamic_configuration>