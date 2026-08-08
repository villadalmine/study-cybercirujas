# Tema 3.7 — Uso de la Inyección de Fallos

> **Alcance (ICA, peso en el examen 5).** La inyección de fallos te permite introducir fallos de forma *deliberada* — latencia añadida y respuestas de error HTTP/gRPC — en las peticiones que coinciden con una ruta, sin cambiar una sola línea del código de la aplicación. Es la herramienta del mesh para las **pruebas de resiliencia**: validás que los timeouts, los reintentos (retries), los circuit breakers y la lógica de degradación gradual (graceful degradation) se comportan realmente como asume el diseño. En Istio es un campo de la ruta HTTP del `VirtualService`: `spec.http[].fault`, con dos subobjetos independientes, `delay` y `abort`.
>
> **Modelo mental clave que debés llevar a lo largo de este laboratorio:** el fallo lo inyecta el **proxy Envoy del *cliente* (el que llama)**, en la ruta *saliente* (outbound) hacia el host de destino — no el sidecar del destino ni la aplicación de destino. El destino puede que ni siquiera vea la petición (un `abort` hace cortocircuito localmente). Este único hecho explica cada paso de diagnóstico que sigue.
>
> **Fuentes de referencia (oficiales):**
> - Tarea: `https://istio.io/latest/docs/tasks/traffic-management/fault-injection/`
> - API — `HTTPFaultInjection`: `https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPFaultInjection`
> - API — `Delay` / `Abort` / `Percent`: la misma página, anclas `#HTTPFaultInjection-Delay`, `#HTTPFaultInjection-Abort`, `#Percent`
> - Filtro de fallos de Envoy (implementación subyacente): `https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter`

---

## Ejercicio 0 — Construir un entorno de laboratorio determinista

Usamos dos de las cargas de trabajo (workloads) de ejemplo estándar de Istio para que cada resultado sea reproducible: `httpbin` (el destino) y `sleep` (un cliente equipado con curl). Un namespace dedicado con inyección automática de sidecar mantiene contenido el radio de impacto (blast radius).

1. Creá el namespace y activá la inyección, luego desplegá ambos workloads:

   ```bash
   kubectl create namespace fault-lab
   kubectl label namespace fault-lab istio-injection=enabled

   kubectl apply -n fault-lab -f samples/httpbin/httpbin.yaml
   kubectl apply -n fault-lab -f samples/sleep/sleep.yaml
   ```

2. Confirmá que cada pod tiene **dos** contenedores (app + `istio-proxy`) y está en `Running`:

   ```bash
   kubectl get pods -n fault-lab
   ```

   Esperado (el `2/2` es la prueba del sidecar):

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7b8b9c8f9d-4qk2t   2/2     Running   0          40s
   sleep-6c4f8d7b5-9xr7p      2/2     Running   0          38s
   ```

3. Capturá el nombre del pod cliente y ejecutá una llamada de referencia (baseline). El `/status/200` de `httpbin` devuelve el código que le pedís, así que este es un control limpio:

   ```bash
   export CLIENT=$(kubectl get pod -n fault-lab -l app=sleep -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Esperado (baseline, todavía sin VirtualService, así que aplica el enrutamiento por defecto del mesh):

   ```
   code=200 time=0.012s
   ```

**Comprobación de comprensión 0**
1. Ambos pods reportan `2/2` aunque `httpbin.yaml` define un único contenedor de aplicación. ¿De dónde salió el segundo contenedor y qué lo desencadenó?
2. Cuando finalmente apliques un fallo al host `httpbin`, ¿el Envoy de qué pod ejecutará realmente la lógica del fallo — el de `sleep` o el de `httpbin`? ¿Por qué importa eso para *dónde mirás* al depurar?

---

## Ejercicio 1 — Inyectar un fallo de retardo (delay) HTTP

Un fallo `delay` retiene la petición en el proxy del cliente durante una duración fija **antes** de reenviarla upstream. Usalo para simular una dependencia lenta, congestión de red o un backend sobrecargado.

1. Aplicá un VirtualService que retarda el **100%** del tráfico hacia `httpbin` en 5 segundos:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         delay:
           percentage:
             value: 100
           fixedDelay: 5s
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-delay.yaml
   ```

2. Medí el ida y vuelta (round trip). La petición aún **tiene éxito** — un delay no hace fallar la petición, solo la ralentiza:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Esperado:

   ```
   code=200 time=5.013s
   ```

3. Hacelo *parcial*. Editá `percentage.value` a `50`, volvé a aplicar y lanzá diez peticiones. Como cada petición extrae una muestra de Bernoulli independiente, verás aproximadamente — no exactamente — la mitad retardadas:

   ```yaml
         delay:
           percentage:
             value: 50
           fixedDelay: 5s
   ```

   ```bash
   for i in $(seq 1 10); do
     kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
       curl -s -o /dev/null -w "%{time_total}s\n" http://httpbin:8000/status/200
   done
   ```

   Esperado (el orden y el reparto exacto varían — esto es una muestra, no una rotación):

   ```
   0.011s
   5.010s
   5.009s
   0.010s
   0.012s
   5.011s
   0.011s
   5.010s
   0.010s
   5.012s
   ```

**Comprobación de comprensión 1**
1. Un colega configura `percentage: { value: 0.5 }` con la intención de "la mitad de todas las peticiones" y reporta que "casi nada se retarda". ¿Qué configuró en realidad y qué valor quería?
2. Las peticiones retardadas devolvieron `code=200`, no un error. En una frase, ¿qué modo de fallo del mundo real está pensado para probar un fallo `delay` puro?
3. Con `value: 50`, ¿está garantizado que exactamente 5 de 10 peticiones se retarden? Explicá el modelo de muestreo.

---

## Ejercicio 2 — Inyectar un fallo de aborto (abort) HTTP

Un fallo `abort` hace que el proxy del cliente sintetice una respuesta de error **localmente** y la devuelva de inmediato; el destino upstream **nunca es contactado** para las peticiones abortadas.

1. Reemplazá el delay con un abort que devuelve HTTP `500` para el **100%** del tráfico:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         abort:
           percentage:
             value: 100
           httpStatus: 500
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-abort.yaml
   ```

2. Llamá al servicio e inspeccioná el **cuerpo (body)**, no solo el código. Envoy estampa una cadena de firma:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -w "\ncode=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Esperado:

   ```
   fault filter abort
   code=500 time=0.006s
   ```

3. Demostrá que el destino fue omitido. Pedile a `httpbin` un `/status/200` — un código para el que *habría* devuelto `200` — y observá que aún obtenés `500` en ~0 ms, mucho más rápido que cualquier ida y vuelta real a un backend. (Para destinos gRPC, en su lugar establecerías `grpcStatus`, p. ej. `grpcStatus: 14` para `UNAVAILABLE`, en vez de `httpStatus`.)

4. Bajalo a `percentage.value: 50` para un escenario realista de "una dependencia está inestable (flapping)", luego volvé a aplicar y a ejecutar el bucle de 10 peticiones del Ejercicio 1 (cambiá el write-out a `%{http_code}`).

**Comprobación de comprensión 2**
1. Las respuestas de abort volvieron en ~6 ms mientras que una llamada normal a `httpbin` también tardó ~12 ms — pero el abort *nunca llegó* a `httpbin`. ¿Dónde se generó el `500`?
2. Querés probar cómo maneja el que llama (caller) que un servicio esté *completamente caído* frente a que esté *lento*. ¿Qué tipo de fallo modela cada caso y por qué un único fallo no puede hacer ambas tareas a la vez para la misma petición en la forma simple de arriba?
3. ¿Cuál es la importancia de la cadena del cuerpo `fault filter abort` al triar un `500` en producción — cómo te permite distinguir un fallo inyectado de un error genuino de la aplicación?

---

## Ejercicio 3 — Acotar el fallo: controlar el radio de impacto (blast radius) con `match`

Inyectar un fallo en el 100% de un servicio compartido en un clúster real es temerario. El patrón profesional es condicionar el fallo tras una condición `match` — típicamente una cabecera (header) que establece tu arnés de pruebas (test harness) — para que solo *tu* tráfico sintético se vea afectado mientras todos los demás enrutan normalmente.

1. Aplicá un VirtualService con **dos** rutas ordenadas: una ruta coincidente (matched) que aborta, y una ruta catch-all que se comporta normalmente. El orden importa — Istio evalúa `http[]` de arriba abajo y toma la primera coincidencia:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - match:
       - headers:
           x-fault-test:
             exact: "true"
       fault:
         abort:
           percentage:
             value: 100
           httpStatus: 503
       route:
       - destination:
           host: httpbin
     - route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-scoped.yaml
   ```

2. El tráfico normal — **sin** cabecera — queda intacto:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "no-header  code=%{http_code}\n" \
     http://httpbin:8000/status/200
   ```

   Esperado:

   ```
   no-header  code=200
   ```

3. El tráfico de prueba — que lleva la cabecera — golpea el fallo:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "with-header code=%{http_code}\n" \
     -H "x-fault-test: true" http://httpbin:8000/status/200
   ```

   Esperado:

   ```
   with-header code=503
   ```

**Comprobación de comprensión 3**
1. Si *intercambiaras* el orden de las dos entradas `http[]` (catch-all primero), ¿qué le pasaría a una petición que lleva `x-fault-test: true`, y por qué?
2. En un clúster de staging compartido usado por cinco equipos, ¿por qué es dramáticamente más seguro un fallo condicionado por cabecera que el VirtualService de abort al 100% del Ejercicio 2?
3. El fallo reside solo en la ruta *coincidente*. Si una petición coincide con la segunda ruta (catch-all), ¿experimenta algún fallo? ¿Qué te dice esto sobre la relación entre `match`, `fault` y `route` dentro de una única entrada de ruta HTTP?

---

## Ejercicio 4 — Descubrir un bug de timeout oculto (interacción delay × timeout)

Esta es la razón estrella por la que la inyección de fallos existe en el examen: revela discrepancias entre la latencia real de una dependencia y el timeout que asume un caller. Construimos la discrepancia de forma determinista.

1. Aplicá una ruta que **a la vez** inyecta un delay de 5 s **y** declara un timeout de petición de 3 s en el mismo destino:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         delay:
           percentage:
             value: 100
           fixedDelay: 5s
       timeout: 3s
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-delay-timeout.yaml
   ```

2. Llamala y observá cómo el timeout gana la carrera — la petición falla a ~3 s, no a los 5 s:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Esperado:

   ```
   code=504 time=3.010s
   ```

3. Interpretá el resultado. La latencia inyectada de 5 s excede el timeout de 3 s, así que Envoy aborta la petición con `504 Gateway Timeout`. **Esta es exactamente la clase de bug que la técnica existe para encontrar**: en la tarea canónica de Bookinfo, un delay de 7 s inyectado en `ratings` saca a la luz un timeout codificado a mano (hard-coded) y demasiado corto entre `reviews:v2/v3` y `ratings`, produciendo un cartel de "Error fetching product reviews!" aunque ningún servicio se haya caído realmente. El arreglo es *subir el timeout* (o *bajar la latencia asumida de la dependencia*) hasta que sobreviva al delay — aquí, establecé `timeout: 6s` y volvé a aplicar para ver cómo la misma petición tiene éxito a ~5 s.

4. Volvé a ejecutar con `timeout: 6s` para confirmar el arreglo:

   ```
   code=200 time=5.011s
   ```

**Comprobación de comprensión 4**
1. La petición devolvió `504` a ~3 s, pero la app (`httpbin`) está perfectamente sana y es rápida. ¿Qué dos números configurados están en conflicto y cuál "ganó"?
2. En el escenario de Bookinfo, el bug es un timeout de aplicación codificado a mano (hard-coded) que *no podés* ver en ningún manifiesto. Explicá cómo la inyección de fallos hizo visible una suposición invisible a nivel de código sin leer el código fuente de la aplicación.
3. «Arreglaste» el laboratorio subiendo el `timeout` del VirtualService a 6 s. En un sistema real, nombrá una situación en la que subir el timeout del caller sea el arreglo *equivocado* y en la que en cambio lo correcto sea bajar el presupuesto de latencia (latency budget) de la dependencia.

---

## Ejercicio 5 — Verificar y diagnosticar la inyección de fallos desde el plano de datos (data plane)

Tenés que ser capaz de *demostrar* que un fallo está programado y de *observar* cómo se dispara — no simplemente confiar en que `kubectl apply` funcionó. Cada comprobación de abajo lee el sidecar del cliente, porque ahí es donde vive el fallo.

1. Volvé a aplicar el delay simple al 100% del Ejercicio 1. Luego volcá la configuración de rutas del cliente y confirmá que el filtro de fallos está presente en la ruta saliente (outbound) hacia `httpbin`:

   ```bash
   istioctl proxy-config routes "$CLIENT.fault-lab" \
     --name 8000 -o json | \
     grep -A6 '"envoy.filters.http.fault"'
   ```

   Fragmento esperado (el fallo se adjunta vía `typedPerFilterConfig`, indexado por el nombre del filtro de fallos de Envoy):

   ```json
   "envoy.filters.http.fault": {
     "@type": "type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault",
     "delay": {
       "percentage": { "numerator": 100 },
       "fixedDelay": "5s"
     }
   }
   ```

2. Leé los contadores de fallos de Envoy desde el proxy **cliente**. `delays_injected` / `aborts_injected` se incrementan cada vez que un fallo se dispara realmente:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c istio-proxy -- \
     pilot-agent request GET stats | grep 'fault\.'
   ```

   Esperado (los valores crecen a medida que enviás tráfico):

   ```
   http.outbound_...httpbin...8000.fault.delays_injected: 12
   http.outbound_...httpbin...8000.fault.aborts_injected: 0
   ```

3. Correlacioná con las **banderas de respuesta (response flags) del access log**. Activá los access logs si hace falta (API de Telemetry o configuración del mesh), enviá tráfico e inspeccioná el log del sidecar del cliente. Envoy estampa `DI` para una petición con delay inyectado y `FI` para una abortada por fallo en el campo `%RESPONSE_FLAGS%`:

   ```bash
   kubectl logs -n fault-lab "$CLIENT" -c istio-proxy --tail=3
   ```

   Esperado (fijate en la bandera `DI`):

   ```
   [2026-08-08T12:00:03.101Z] "GET /status/200 HTTP/1.1" 200 DI ... 5013 ...
   ```

   Si volvés al fallo de abort, el mismo campo muestra `FI` con un `500`.

**Comprobación de comprensión 5**
1. Consultaste `istioctl proxy-config routes` contra el pod **`sleep`**, no `httpbin`, para encontrar la configuración del fallo — y ahí estaba. Reformulá la regla que esto confirma sobre *dónde* programa Istio las reglas de enrutamiento/fallos de un VirtualService.
2. Un compañero insiste en que el fallo "no funciona" pero está leyendo `fault.aborts_injected` en el sidecar de **`httpbin`** y ve `0`. Diagnosticá su error en una frase.
3. En un access log, ves un `504` con las response flags `DI`. Recorré qué te dice esa única línea sobre cómo murió la petición.

---

## Limpieza

```bash
kubectl delete virtualservice httpbin -n fault-lab --ignore-not-found
kubectl delete namespace fault-lab
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0
1. **El sidecar se inyectó automáticamente.** Etiquetar el namespace con `istio-injection=enabled` hace que el mutating admission webhook de Istio (`sidecar-injector`) reescriba cada spec de pod nuevo para añadir el contenedor `istio-proxy` (Envoy) más el init container `istio-init`. `httpbin.yaml` define un contenedor de aplicación; el mesh añade el segundo. `2/2 Running` es tu prueba de que la inyección tuvo éxito — un workload `1/1` *no* está en el mesh y ningún VirtualService/fallo se le aplica.
2. **El Envoy de `sleep` ejecuta el fallo**, no el de `httpbin`. Istio programa las rutas HTTP de un VirtualService (incluido `fault`) en el listener/ruta **saliente (outbound)** de los sidecars *cliente* del mesh que llaman al host. Así que al depurar inspeccionás el proxy del **que llama (caller)** (rutas, stats, logs), no el del destino. Mirar el sidecar de `httpbin` en busca del fallo es el error más común.

### Ejercicio 1
1. `percentage.value` es un **porcentaje en una escala de 0–100**, expresado como float — no una fracción. `value: 0.5` significa **0.5%** (una petición de cada doscientas), que es por lo que se retardó "casi nada". Querían `value: 50`.
2. Prueba la tolerancia del caller a una **dependencia lenta** (latencia / congestión de red / un backend sobrecargado pero que aún responde) — la petición finalmente tiene éxito, así que ejercita el manejo de timeouts y del camino lento (slow path) en lugar del manejo de errores.
3. **No.** Cada petición es un ensayo de Bernoulli independiente con p = 0.50; el número de peticiones retardadas en 10 intentos sigue una distribución binomial. Esperás ≈5 pero cualquier valor de 0–10 es posible. El porcentaje de fallo es una probabilidad por petición, nunca una rotación fija como "una petición sí y otra no".

### Ejercicio 2
1. **En el Envoy de `sleep` (cliente).** Un fallo `abort` es una *respuesta local (local reply)* sintetizada por el filtro de fallos de Envoy en la ruta saliente. La petición hace cortocircuito antes de salir del proxy del cliente, que es por lo que vuelve en microsegundos y por lo que `httpbin` nunca la registra.
2. `abort` modela una dependencia que está **caída / devolviendo errores** (código de error inmediato); `delay` modela una que está **lenta** (latencia añadida, éxito eventual). Un único bloque `fault` simple prueba un modo de fallo por petición coincidente — una petición abortada nunca experimenta el camino del delay, ya que el abort le hace cortocircuito. (Sí *podés* configurar tanto `delay` como `abort` en una ruta; cada uno se muestrea entonces de forma independiente, pero para una petición abortada dada el delay es irrelevante porque nunca se reenvía.)
3. `fault filter abort` es el cuerpo fijo de Envoy para un abort inyectado. Verlo en un cuerpo `500`/`503` — o la response flag `FI` en los access logs — te dice que el error fue **inyectado sintéticamente por el mesh**, no emitido por la aplicación. En producción eso descarta al instante un bug de la app y te apunta a un VirtualService de inyección de fallos que quedó rezagado.

### Ejercicio 3
1. El catch-all (sin `match`) coincidiría **primero** con cada petición, incluida una que lleve `x-fault-test: true`. Istio evalúa `http[]` **en orden y se detiene en la primera coincidencia**; un catch-all al frente hace inalcanzable la ruta con fallo — la petición con la cabecera devolvería `200`, y el fallo nunca se dispararía silenciosamente.
2. Como el fallo solo se aplica a las peticiones que llevan la cabecera de prueba, el tráfico normal de los otros cuatro equipos cae hasta la ruta catch-all y se sirve normalmente. Un abort general al 100% rompería el servicio compartido para **todos**, convirtiendo una prueba en una caída (outage).
3. Una petición que coincide con la segunda ruta (catch-all) **no experimenta ningún fallo** — esa entrada no tiene bloque `fault`. Esto muestra que `match`, `fault` y `route` están acotados **a la entrada de ruta HTTP individual**: un fallo se aplica solo a las peticiones que coinciden con las condiciones de *esa* entrada y siguen la ruta de *esa* entrada. Los fallos son por ruta (per-route), no por VirtualService.

### Ejercicio 4
1. El **delay inyectado de 5 s** y el **timeout de 3 s** de la ruta están en conflicto. El **timeout ganó**: se disparó primero y Envoy devolvió `504 Gateway Timeout` a ~3 s. El propio `httpbin` nunca fue el cuello de botella.
2. El delay reprodujo, bajo demanda, la latencia exacta que exhibiría una dependencia lenta real. Esa latencia extra excedió un timeout que vivía **solo en el código / en suposiciones de configuración** — no visible en ningún manifiesto — así que el timeout saltó y afloró como un error de cara al usuario. La inyección de fallos convirtió una suposición invisible de presupuesto de latencia en un `504`/cartel de error observable **sin tocar ni leer el código fuente de la aplicación**.
3. Subir el timeout del caller es incorrecto siempre que el propio caller esté en un **camino sensible a la latencia** — p. ej. sostiene una petición de usuario (un navegador se rendirá), consume una conexión/hilo de un pool acotado, o es llamado por *su* upstream bajo un timeout aún más ajustado. Alargar el timeout ahí solo propaga la lentitud en cascada y arriesga el agotamiento de recursos. El arreglo correcto es devolver la **latencia de la dependencia por debajo del presupuesto existente** (optimizarla, cachear, añadir un fallback / degradación gradual) para que el timeout siga siendo realista.

### Ejercicio 5
1. Istio programa las reglas de enrutamiento y de fallos de un VirtualService en la **configuración saliente (outbound) de los sidecars cliente (caller)**. La regla vive dondequiera que el *tráfico se origine* hacia el host — aquí, el pod `sleep` — que es exactamente por lo que la configuración apareció en `sleep`, no en `httpbin`.
2. Está leyendo el **proxy equivocado**: el fallo se dispara en la ruta saliente del sidecar **cliente** (`sleep`), así que `fault.aborts_injected` se incrementa ahí; el sidecar de `httpbin` nunca procesa la petición abortada y correctamente muestra `0`.
3. Un `504` con la bandera `DI` significa: la petición recibió **delay inyectado** por el filtro de fallos (`DI`), el delay inyectado empujó el tiempo total más allá del timeout de la ruta, y Envoy entonces terminó la petición con un gateway timeout (`504`). Una línea te dice que el fallo fue una **latencia inyectada por fallo colisionando con un timeout** — una prueba sintética de dependencia lenta que hace saltar un timeout demasiado corto — no una caída (outage) real del upstream.

</details>