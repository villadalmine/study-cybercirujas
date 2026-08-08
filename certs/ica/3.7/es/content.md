# 3.7 Uso de la Inyección de Fallos (Fault Injection)

> **Certification:** Istio Certified Associate (ICA) · **Dominio 3 – Traffic Management** · **Peso del tema: 5%**

---

## 1. Motivación: el problema de producción que resuelve la inyección de fallos

Un mesh de microservicios falla de maneras que los tests unitarios nunca alcanzan. Los fallos interesantes son **emergentes**: un servicio downstream que está *lento pero no caído*, una dependencia que devuelve `503` en el 2% de las requests, una tormenta de reintentos que amplifica un tropiezo transitorio hasta convertirlo en una caída. Estas son precisamente las condiciones que tu configuración de resiliencia — timeouts, retries, circuit breakers, connection pools — se *supone* que debe absorber. El problema arquitectónico es que **no podés saber si esa configuración funciona hasta que el fallo realmente ocurre**, y para entonces ya es un incidente en producción.

La trampa clásica es el **timeout oculto y hard-codeado**. Un equipo de servicio configura un timeout del lado del cliente en el código de la aplicación hace años; nadie lo recuerda. Operaciones más tarde configura un timeout a nivel del mesh más largo, asumiendo que es el que manda. Los dos no coinciden, y la discrepancia es invisible hasta que una dependencia real se ralentiza. La inyección de fallos te permite *reproducir esa ralentización a demanda, en un radio de impacto controlado*, y observar el desajuste antes de que lo haga un cliente.

Istio implementa la inyección de fallos **en la Capa 7, dentro del sidecar de Envoy**, desacoplada por completo del código de la aplicación. Esta es la propiedad decisiva: estás probando el servicio *real*, sobre el camino de red *real*, con la config de resiliencia *real*, sin recompilar nada ni tocar el servicio bajo prueba. El fallo es una propiedad de la **route**, evaluada por el filtro `envoy.filters.http.fault` en el proxy que posee esa configuración de route.

Dos primitivas de fallo cubren la mayoría de los fallos del mundo real:

- **Delay** — inyecta latencia antes de reenviar. Simula un upstream sobrecargado, con pausas de GC o degradado a nivel de red. Prueba los **timeouts** y los **latency budgets**.
- **Abort** — devuelve un error HTTP/gRPC sintético *sin* contactar al upstream. Simula un upstream caído, sobrecargado o con mal comportamiento. Prueba los **retries**, los **fallbacks** y el comportamiento del **circuit-breaker**.

### Dónde se aplica el fallo — la mecánica

Para el tráfico interno del mesh, la configuración de route del VirtualService se programa en el **sidecar del lado del cliente (origen)** — el Envoy que posee el outbound listener para el host de destino. Ese proxy ejecuta el filtro de fault HTTP *antes* de que el router reenvíe al upstream. Consecuencias que hacen tropezar a la gente en producción:

1. **El pod de origen debe estar en el mesh.** Si el llamador no tiene sidecar (o está excluido de la inyección), la configuración de route de salida — y por lo tanto el fallo — nunca se evalúa. No se aplica ningún fallo.
2. **Los aborts inyectados nunca llegan al upstream.** El upstream ve cero tráfico para las requests abortadas; el error se sintetiza localmente. Por eso el abort es barato e instantáneo.
3. **Los delays inyectados consumen el presupuesto de request del llamador.** El delay se suma a la latencia observada por el llamador y cuenta contra *su* timeout — que es exactamente lo que lo convierte en una prueba útil.
4. **El porcentaje se muestrea por-request**, de forma independiente, contra un valor de runtime. 10% no significa "cada 10ª request"; significa que cada request tiene una probabilidad independiente del 10%.

```
                    source pod (in mesh)                         destination pod
   ┌──────────────────────────────────────────┐            ┌───────────────────────┐
   │  app  ──▶  istio-proxy (Envoy)            │            │  istio-proxy ──▶ app  │
   │            ├─ outbound listener :9080     │            │                       │
   │            ├─ HTTP conn manager           │            │                       │
   │            │    └─ envoy.filters.http.fault│──abort?──╳ (upstream NEVER hit)   │
   │            │         ├─ delay  (sleep)     │            │                       │
   │            │         └─ abort  (503/…)     │            │                       │
   │            └─ router ─────────────────────────delay?──▶ │  (hit after latency)  │
   └──────────────────────────────────────────┘            └───────────────────────┘
```

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Delay vs Abort

| Dimensión | **Delay** | **Abort** |
|---|---|---|
| Acción de Envoy | Retiene la request `fixedDelay`, luego la reenvía | Devuelve un status sintético; **no** la reenvía |
| Simula | Upstream lento/sobrecargado, latencia de red, pausa de GC | Upstream caído, tormentas de 5xx, connection refused |
| Config de resiliencia que ejercita | Timeouts, latency budgets, propagación de deadlines | Retries, matching de `retryOn`, fallbacks, outlier detection |
| Impacto en la carga del upstream | El upstream igual es alcanzado (tras el delay) | El upstream recibe **cero** tráfico para las requests abortadas |
| Impacto en la latencia del llamador | Aumenta en `fixedDelay` | Efectivamente cero (error inmediato) |
| Interacción con los retries | El delay se vuelve a incurrir en cada intento de retry | Se reintenta **solo si** el status coincide con `retryOn` |
| Costo de ejecución | Retiene un request slot durante el delay (cuidá los connection pools) | Insignificante |
| Falso negativo común | Los retries enmascaran la latencia; timeout mayor que el delay | Status no está en `retryOn`, así que no se prueba ningún camino de retry |

### 2.2 Capa de inyección de fallos — Istio vs alternativas

| Herramienta | Capa | Granularidad | Inyecta | Cambios en la app | Control del radio de impacto | Ideal para |
|---|---|---|---|---|---|---|
| **Istio fault injection** | L7 (HTTP/gRPC, en Envoy) | Por-route, por-header, por-% | Delay, abort HTTP/gRPC | Ninguno | Match de header/route, % | Tests de resiliencia deterministas y dirigidos dentro de un mesh |
| **Chaos Mesh** | L3/L4 + pod/OS | Pod, node, red, IO, kernel | Pod kill, netem delay/loss, partition | Ninguno | Label selectors | Chaos a nivel de infra (pérdida de nodo, pérdida de paquetes, disco) |
| **Litmus** | Pod/infra | Experiment CRDs | Chaos de pod/red/recursos | Ninguno | Label selectors | GameDays, pipelines de chaos programado |
| **Toxiproxy** | Proxy L4 | Por-conexión | Latencia, ancho de banda, slicing | Reconfigurar el endpoint hacia el proxy | Por-proxy | Harnesses de test locales/de integración |
| **App-level (ej. hooks de test de Failsafe/Resilience4j)** | In-process | Llamada a método | Excepciones, delay | **Sí** | Camino de código | Tests unitarios/de componentes |

**Resumen del trade-off.** Istio opera en L7, así que entiende los HTTP status codes y los gRPC statuses y puede apuntar a un *único usuario* por header — algo que una regla netem de L3 no puede hacer. Su limitación es la otra cara: solo puede provocar fallos en el tráfico que atraviesa un proxy Envoy sobre una route HTTP/gRPC. Para provocar un fallo en una dependencia TCP cruda, una resolución DNS o el nodo en sí, necesitás chaos de L3/L4 (Chaos Mesh). En producción, los dos son **complementarios**: Istio para la resiliencia del request-path, Chaos Mesh para la resiliencia de la infraestructura.

### 2.3 `percentage` vs `percent` (trampa de la API)

| Campo | Tipo | Rango | Estado | Significado si se omite |
|---|---|---|---|---|
| `fault.delay.percentage.value` | double | `0.0`–`100.0` | **Actual** | Se trata como **100%** |
| `fault.abort.percentage.value` | double | `0.0`–`100.0` | **Actual** | Se trata como **100%** |
| `fault.delay.percent` | int32 | `0`–`100` | **Deprecado** | — |

> **Trampa de diagnóstico:** omitir el porcentaje por completo significa inyección al **100%**, no al 0%. Un VirtualService que provoca un fallo "solo para ver qué pasa" sin un porcentaje va a fallar en *todas* las requests que coincidan. Configurá siempre un `percentage.value` explícito, y acotá siempre con un `match` cuando pruebes en un entorno compartido.

---

## 3. Manifiestos completos y sintácticamente válidos

Los ejemplos apuntan a la aplicación estándar **Bookinfo**. Las requests fluyen `productpage → reviews → ratings`. Inyectamos fallos en los edges `productpage → reviews` y `reviews → ratings`.

### 3.1 Prerrequisito: DestinationRules (subsets)

Los VirtualServices que inyectan fallos enrutan hacia subsets con nombre, que deben declararse una vez en un DestinationRule.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ratings
  namespace: bookinfo
spec:
  host: ratings
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

### 3.2 Fallo de delay — dirigido a un único usuario (reproducción de un bug de Bookinfo)

Inyectar un delay de **7 s** en `ratings`, pero **solo** para las requests que llevan `end-user: jason`. Todo el resto del tráfico se enruta normalmente. Esta es la prueba de resiliencia canónica.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      delay:
        percentage:
          value: 100.0      # 100% of jason's requests
        fixedDelay: 7s
    route:
    - destination:
        host: ratings
        subset: v1
  - route:                  # everyone else: no fault
    - destination:
        host: ratings
        subset: v1
```

**Por qué esto expone un bug.** `reviews:v2/v3` tiene un timeout hard-codeado en la aplicación de **10 s** en su llamada a `ratings`, así que un delay de 7 s *debería* pasar. Pero `productpage → reviews` lleva un **timeout de 3 s con 1 retry = 6 s** de presupuesto total. Como `7s > 6s`, la llamada `productpage → reviews` sufre un timeout a los ~6 s y la página muestra *"Sorry, product reviews are currently unavailable for this book."* Los dos timeouts no coinciden — exactamente el fallo de timeout oculto que la inyección de fallos está diseñada para sacar a la luz.

### 3.3 Fallo de abort — 500 sintético para un único usuario

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      abort:
        percentage:
          value: 100.0
        httpStatus: 500
    route:
    - destination:
        host: ratings
        subset: v1
  - route:
    - destination:
        host: ratings
        subset: v1
```

La página carga **inmediatamente** para jason y muestra *"Ratings service is currently unavailable"* — `reviews` se degrada con elegancia porque ratings devuelve un error duro rápidamente, a diferencia del caso del delay.

### 3.4 Abort parcial + abort de gRPC (simulación de tasa de error en estado estacionario)

Provocar un fallo en el **10%** del tráfico no coincidente (de todos los usuarios) con un `503`, y demostrar la forma gRPC para un upstream gRPC.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings-partial
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - fault:
      abort:
        percentage:
          value: 10.0       # each request independently has a 10% chance
        httpStatus: 503
    route:
    - destination:
        host: ratings
        subset: v1
---
# gRPC upstream variant — abort with a gRPC status instead of HTTP
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: grpc-catalog
  namespace: bookinfo
spec:
  hosts:
  - catalog.bookinfo.svc.cluster.local
  http:
  - fault:
      abort:
        percentage:
          value: 5.0
        grpcStatus: "UNAVAILABLE"   # maps to gRPC code 14
    route:
    - destination:
        host: catalog.bookinfo.svc.cluster.local
```

### 3.5 Fault + timeout + retries en una sola route (interacción bajo prueba)

Este es el manifiesto que realmente ejecutás para validar una política de resiliencia de punta a punta. Inyecta un delay **y** declara el timeout/retry a nivel del mesh que querés demostrar correcto.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-resilience
  namespace: bookinfo
spec:
  hosts:
  - reviews
  http:
  - fault:
      delay:
        percentage:
          value: 50.0
        fixedDelay: 5s
    timeout: 3s              # mesh timeout: 5s delay > 3s ⇒ deadline exceeded
    retries:
      attempts: 2
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,retriable-4xx,reset
    route:
    - destination:
        host: reviews
        subset: v2
```

> **Semántica para interiorizar:** el delay inyectado de 5 s se vuelve a incurrir en *cada* intento de retry. Con `perTryTimeout: 2s` y un delay de 5 s, **cada** intento se corta a los 2 s. Notá que `retryOn` aquí **no** incluye `503`; por lo tanto, un *abort* inyectado de `503` **no** se reintentaría. Para probar el camino de retry con un abort, inyectá un status que figure en `retryOn` (ej. `retriable-4xx` → `503`? no — usá `gateway-error`, que cubre 502/503/504). Hacé coincidir el status inyectado con tu conjunto de `retryOn` o el camino de código del retry nunca se ejercita — un falso negativo silencioso.

---

## 4. Comandos de la CLI y salida real de la terminal

### 4.1 Aplicar y confirmar que los recursos existen

```console
$ kubectl apply -f ratings-delay-jason.yaml -n bookinfo
virtualservice.networking.istio.io/ratings configured

$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.

$ kubectl get virtualservice ratings -n bookinfo -o jsonpath='{.spec.http[0].fault}' | jq
{
  "delay": {
    "fixedDelay": "7s",
    "percentage": {
      "value": 100
    }
  }
}
```

### 4.2 Probar que el fallo está programado en Envoy (no solo aceptado por la API)

Que la API acepte un manifiesto **no** prueba que el proxy lo aplicó. Inspeccioná la configuración de route del sidecar de origen. El fallo vive bajo `typedPerFilterConfig["envoy.filters.http.fault"]`.

```console
$ REVIEWS_POD=$(kubectl get pod -n bookinfo -l app=reviews,version=v2 -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config route "$REVIEWS_POD.bookinfo" --name 9080 -o json \
    | jq '.[].virtualHosts[] | select(.name|test("ratings")) | .routes[].typedPerFilterConfig'
{
  "envoy.filters.http.fault": {
    "@type": "type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault",
    "delay": {
      "fixedDelay": "7s",
      "percentage": {
        "numerator": 100,
        "denominator": "HUNDRED"
      }
    }
  }
}
```

> Si este bloque está **ausente**, el fallo no está activo en ese camino — verificá que estés inspeccionando el proxy de **origen** (llamador), que la route coincida (headers/subset), y que `istioctl analyze` esté limpio.

### 4.3 Disparar y observar — delay

```console
$ GATEWAY_URL=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):80

# Without the header: fast, normal
$ curl -s -o /dev/null -w 'HTTP %{http_code}  total=%{time_total}s\n' \
    "http://$GATEWAY_URL/productpage"
HTTP 200  total=0.048s

# As user jason: the injected 7s delay trips the 6s productpage→reviews budget
$ curl -s -o /dev/null -w 'HTTP %{http_code}  total=%{time_total}s\n' \
    -b 'session=jason-cookie' -H 'end-user: jason' \
    "http://$GATEWAY_URL/productpage"
HTTP 200  total=6.031s
```

La página devuelve `200` en ~6 s (el presupuesto de timeout de `reviews`), **no** en 7 s — la sección de reviews muestra el error "unavailable". Esa brecha de 1 segundo entre el delay inyectado y la latencia observada *es* el bug.

### 4.4 Disparar y observar — abort

```console
$ curl -s -H 'end-user: jason' "http://$GATEWAY_URL/productpage" | grep -o 'Ratings service is currently unavailable'
Ratings service is currently unavailable

# Direct call from an in-mesh client to see the raw synthetic status
$ kubectl exec -n bookinfo deploy/productpage-v1 -c productpage -- \
    curl -s -o /dev/null -w '%{http_code}\n' -H 'end-user: jason' http://ratings:9080/ratings/0
500
```

### 4.5 Contadores de fault de Envoy — la verdad de fondo

Envoy incrementa contadores dedicados cada vez que un fallo realmente se dispara. Estos son la prueba autoritativa de la inyección.

```console
$ kubectl exec -n bookinfo "$REVIEWS_POD" -c istio-proxy -- \
    pilot-agent request GET stats | grep -E 'fault\.(delays_injected|aborts_injected|active_faults)'
http.outbound_0.0.0.0_9080.fault.aborts_injected: 0
http.outbound_0.0.0.0_9080.fault.delays_injected: 42
http.outbound_0.0.0.0_9080.fault.active_faults: 0
http.outbound_0.0.0.0_9080.fault.faults_overflow: 0
```

`delays_injected: 42` confirma que 42 requests fueron efectivamente demoradas. `active_faults` muestra los delays concurrentes en vuelo (vigilá esto contra los límites del connection-pool bajo carga). `faults_overflow` se incrementa cuando se alcanza el tope `max_active_faults` de Envoy y un fallo es *omitido* — una razón crítica y fácil de pasar por alto por la cual un test de carga ve menos fallos que el porcentaje configurado.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Escalera de verificación (lo más barato primero)

| Peldaño | Pregunta | Comando | Prueba |
|---|---|---|---|
| 1 | ¿El manifiesto es válido y consistente? | `istioctl analyze -n bookinfo` | Config sana, los subsets existen |
| 2 | ¿El fallo está en el objeto de la API? | `kubectl get vs … -o jsonpath='{.spec.http[*].fault}'` | La intención del autor está almacenada |
| 3 | ¿Está programado en el proxy de **origen**? | `istioctl proxy-config route <src-pod> -o json` | Envoy realmente tiene la config del filtro |
| 4 | ¿Una request se comporta como se espera? | `curl -w '%{http_code} %{time_total}'` | Comportamiento observable |
| 5 | ¿Envoy realmente disparó el fallo? | `pilot-agent request GET stats \| grep fault` | Contadores de la verdad de fondo |

Nunca te detengas en el peldaño 2. "La API lo aceptó" y "el proxy lo está aplicando" son afirmaciones distintas — la brecha entre ambas es donde ocurre la mayor parte del debugging de inyección de fallos.

### 5.2 Tabla de diagnóstico

| Síntoma | Causa probable | Confirmar | Solución |
|---|---|---|---|
| Ningún fallo se dispara nunca | El pod de origen no está en el mesh, o inspeccionaste el proxy equivocado (destino) | El peldaño 3 no muestra `envoy.filters.http.fault` en el **llamador** | Asegurate de que el llamador tenga inyección de sidecar; inspeccioná el proxy de origen |
| El fallo se dispara para *todos* | `percentage` omitido (defaultea a 100%) o `match` faltante | El peldaño 2 no muestra `percentage`; el contador del peldaño 5 ≈ total de requests | Agregá un `percentage.value` explícito y un `match` de header |
| Menos fallos que el % bajo carga | `faults_overflow` — se alcanzó `max_active_faults`, o los retries re-muestrean | `…fault.faults_overflow > 0` | Reducí la concurrencia, o tené en cuenta el tope en las cuentas del test |
| El abort inyectado no se reintenta | El status no está en `retryOn` | La route tiene retries pero el status del abort está excluido | Inyectá un status que esté en `retryOn`, o agregalo |
| El delay es menor que el efecto observado | Los retries multiplican el delay (se vuelve a incurrir por intento) | El contador `…upstream_rq_retry` sube | Configurá `perTryTimeout`; razoná sobre `attempts × delay` |
| Fallo en el host equivocado | Coincidió con un subset/orden de route distinto | `istioctl proxy-config route` muestra el orden de match | Poné el bloque `match` específico **antes** de la route catch-all |
| `503 UF`/`NR` en vez del código inyectado | Subset/DestinationRule faltante, sin endpoints sanos | `istioctl proxy-config endpoint <pod>` vacío | Creá el subset del DestinationRule al que apunta la route |

### 5.3 Correlacionar con distributed traces

Como el fallo es un filtro de Envoy en el camino de la request, los delays y aborts inyectados aparecen en la línea de tiempo del span. En la UI de traces el span demorado muestra la latencia añadida dentro del egress del Envoy del llamador, y una request abortada produce un span etiquetado con el `error=true` / `http.status_code=500` sintético — distinguiendo visualmente un fallo *sintético* de un fallo genuino del upstream. Así es como confirmás, durante un GameDay, que la latencia observada vino de la inyección y no de una regresión real.

### 5.4 Rollback seguro

La inyección de fallos es una edición en vivo del data plane. Removela de forma limpia y re-verificá hasta cero:

```console
$ kubectl delete virtualservice ratings -n bookinfo
virtualservice.networking.istio.io "ratings" deleted
# or restore the fault-free baseline:
$ kubectl apply -f samples/bookinfo/networking/virtual-service-all-v1.yaml -n bookinfo

$ kubectl exec -n bookinfo "$REVIEWS_POD" -c istio-proxy -- \
    pilot-agent request GET stats | grep fault.delays_injected
http.outbound_0.0.0.0_9080.fault.delays_injected: 42   # counter frozen; no new injections
```

Mejores prácticas para meshes de producción: **acotá siempre con un `match` de header** para que solo se vean afectados los usuarios de prueba sintéticos; mantené el porcentaje explícito y bajo para el chaos en estado estacionario; ejecutá la inyección a través de una ventana con gestión de cambios y acotada en el tiempo; y tratá `faults_overflow` y la saturación del connection-pool como señales de primera clase cuando inyectás *delays* bajo carga.

---

## 6. Referencias

- Istio — Fault Injection task (delay & abort walkthrough): https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio — Virtual Service API reference (`HTTPFaultInjection`, `Delay`, `Abort`): https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPFaultInjection
- Istio — Request Timeouts task: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — Request Routing & the Bookinfo application: https://istio.io/latest/docs/examples/bookinfo/
- Istio — Traffic Management concepts: https://istio.io/latest/docs/concepts/traffic-management/
- Envoy — HTTP fault injection filter (`envoy.filters.http.fault`): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter
- Envoy — Fault filter runtime & statistics (`delays_injected`, `aborts_injected`, `active_faults`, `faults_overflow`): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter#statistics
- Istio — `istioctl proxy-config route` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config-route
- CNCF — ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf