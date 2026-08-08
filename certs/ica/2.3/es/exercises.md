# Ejercicios Guiados — Diagnóstico del Data Plane de la Mesh

> **Dominio 2.3 · peso en el examen 6 · Istio Certified Associate (ICA)**
>
> El *data plane* es el conjunto de proxies Envoy que realmente mueven tu tráfico: el sidecar (`istio-proxy`) inyectado junto a cada workload, más los gateways de ingress/egress. El *control plane* (`istiod`) solo calcula la configuración y la envía vía xDS; cuando una request se comporta mal, la verdad vive en lo que a Envoy realmente se le indicó y en lo que Envoy realmente hizo. Estos ejercicios entrenan el bucle reflejo que todo operador necesita: **¿está el proxy presente? → ¿está sincronizado? → qué config tiene → qué registró en el log → es mTLS el culpable → subí el volumen.** Cada comando es tooling real de `istioctl`/`kubectl`/Envoy; ejecutalos contra tu propio cluster y compará.

---

## Ejercicio 0 — Construí el laboratorio

Necesitás un cluster de Kubernetes con Istio instalado (el profile `demo` habilita access logs y tracing de fábrica) y dos workloads de ejemplo que se comuniquen entre sí.

1. Instalá Istio con un profile que emita access logs, y etiquetá un namespace para inyección automática de sidecars:

   ```bash
   istioctl install --set profile=demo -y
   kubectl label namespace default istio-injection=enabled --overwrite
   ```

2. Desplegá los samples estándar `sleep` (cliente) y `httpbin` (servidor) que vienen con el release de Istio:

   ```bash
   kubectl apply -f samples/sleep/sleep.yaml
   kubectl apply -f samples/httpbin/httpbin.yaml
   ```

3. Confirmá que ambos pods estén `Running` y fijate en la cantidad de containers:

   ```bash
   kubectl get pods
   ```

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-5d9f7c8b4-abcde    2/2     Running   0          40s
   sleep-9454cc476-fghij      2/2     Running   0          38s
   ```

4. Generá una request de referencia a través de la mesh para que los logs posteriores tengan algo para mostrar:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/status/200
   ```

**Verificación de comprensión**

- **Q0.1** El pod muestra `2/2` en `READY`. ¿Cuáles son esos dos containers, y cuál es el componente del data plane? ¿Qué te habría dicho un `1/1` sobre este ejercicio antes de correr un solo diagnóstico?
- **Q0.2** Ejecutaste el `curl` con `-c sleep`. ¿Por qué apuntar al container de la app explícitamente en lugar de dejar que `kubectl exec` elija el default?

---

## Ejercicio 1 — ¿Está siquiera el proxy ahí, y está sano?

La mitad de los tickets de "la mesh está rota" en realidad son "el sidecar nunca se inyectó" o "el proxy no está Ready." Descartá eso primero — no cuesta nada.

1. Pedile a `istioctl` un censo de toda la mesh con cada Envoy que el control plane conoce:

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                              CLUSTER      CDS      LDS      EDS      RDS      ECDS       ISTIOD                     VERSION
   httpbin-5d9f7c8b4-abcde.default   Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6f7b94d5c-xyz12     1.22.0
   sleep-9454cc476-fghij.default     Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6f7b94d5c-xyz12     1.22.0
   ```

2. Inspeccioná los containers inyectados y el cableado del readiness probe del pod servidor:

   ```bash
   kubectl get pod -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   kubectl describe pod -l app=httpbin | grep -A2 Readiness
   ```

   ```
   httpbin istio-proxy
   Readiness:  http-get http://:15021/healthz/ready delay=1s timeout=3s period=15s
   ```

3. Ahora simulá la falla más común. Desplegá un workload en un namespace que **no** esté etiquetado para inyección:

   ```bash
   kubectl create namespace legacy
   kubectl -n legacy apply -f samples/sleep/sleep.yaml
   kubectl -n legacy get pods
   ```

   ```
   NAME                     READY   STATUS    RESTARTS   AGE
   sleep-9454cc476-klmno    1/1     Running   0          10s
   ```

4. Confirmá que el control plane no lo ve, y después averiguá *por qué* fue omitido:

   ```bash
   istioctl proxy-status | grep legacy      # returns nothing
   kubectl get namespace -L istio-injection
   ```

**Verificación de comprensión**

- **Q1.1** Un workload aparece en `kubectl get pods` como `Running` pero nunca aparece en `istioctl proxy-status`. ¿Qué te dice esa combinación, y dónde mirás después?
- **Q1.2** El readiness probe de httpbin apunta al puerto **15021**, no al puerto 80 de la app. ¿Por qué Istio enruta el health check del kubelet a través del puerto del proxy, y qué se rompería si dejaras el `readinessProbe` original de la app apuntando directamente al container?
- **Q1.3** Nombrá los cuatro puertos del sidecar 15000, 15006, 15001 y 15090, y decí a cuál harías `port-forward` para llegar a la admin interface de Envoy.

---

## Ejercicio 2 — Leyendo el estado de sincronización: SYNCED, STALE, NOT SENT

`proxy-status` no es solo "¿está vivo?". Cada columna es el estado de acknowledgement de un subsistema xDS. Entender estas palabras es la diferencia entre culpar a la red y culpar a tu YAML.

1. Releé las columnas del Ejercicio 1 y mapeá cada acrónimo con lo que configura:

   - **CDS** — Clusters (definiciones de servicios upstream)
   - **LDS** — Listeners (los puertos que Envoy abre)
   - **EDS** — Endpoints (las IPs reales de los pods detrás de un cluster)
   - **RDS** — Routes (reglas de ruteo HTTP asociadas a los listeners)
   - **ECDS** — Extension Config (filtros WASM/ext_authz; `NOT SENT` cuando no se usan)

2. Profundizá en un solo proxy para ver los *version hashes* que tiene istiod versus los que Envoy reconoció (ACK):

   ```bash
   istioctl proxy-status httpbin-5d9f7c8b4-abcde.default
   ```

   Un proxy sano reporta nonces `Sent`/`Acked` coincidentes para cada tipo; una divergencia es lo que aparece como `STALE`.

3. Provocá drift. Aplicá un `VirtualService`, y después reverificá inmediatamente el status mientras el push se propaga:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts:
     - httpbin
     http:
     - route:
       - destination:
           host: httpbin
           port:
             number: 8000
   EOF
   istioctl proxy-status
   ```

4. Verificá de forma cruzada que la config que *escribiste* sea siquiera válida, ya que una config rechazada es una causa clásica de un estado atascado/stale:

   ```bash
   istioctl analyze
   ```

**Verificación de comprensión**

- **Q2.1** Distinguí `SYNCED`, `STALE` y `NOT SENT`. ¿Cuál es normal, cuál es una alarma, y cuál es simplemente "nada para enviar"?
- **Q2.2** Un proxy muestra `RDS: STALE` durante varios minutos y nunca se recupera. Enumerá dos causas mecánicamente distintas — una en el camino istiod→Envoy y otra causada por el contenido de la config en sí.
- **Q2.3** Agregaste un `EnvoyFilter` y ahora un proxy está `STALE`. ¿Cómo te permitirían `istioctl analyze` más los logs de istiod (`kubectl logs deploy/istiod`) decidir si Envoy *rechazó* (NACK) el push en lugar de nunca haberlo recibido?

---

## Ejercicio 3 — Recorriendo la configuración de Envoy con `proxy-config`

Cuando el ruteo se comporta mal, dejás de adivinar y leés la config que Envoy realmente está corriendo. El modelo mental es una cadena: una request llega a un **listener**, matchea una **route**, que nombra un **cluster**, que resuelve a **endpoints**. Debuggeá en ese orden.

1. Empezá por los listeners outbound del cliente y encontrá el del puerto de httpbin:

   ```bash
   istioctl proxy-config listeners deploy/sleep --port 8000
   ```

   ```
   ADDRESS   PORT   MATCH                                DESTINATION
   0.0.0.0   8000   Trans: raw_buffer; App: HTTP         Route: 8000
   0.0.0.0   8000   ALL                                  PassthroughCluster
   ```

2. Seguí la referencia `Route: 8000` para ver qué cluster selecciona una request a `httpbin`:

   ```bash
   istioctl proxy-config routes deploy/sleep --name 8000
   ```

   ```
   NAME     VHOST NAME                    DOMAINS                  MATCH     VIRTUAL SERVICE
   8000     httpbin.default.svc...:8000   httpbin, httpbin.default HTTP      httpbin.default
   ```

3. Resolvé ese cluster y confirmá el destino al que apunta:

   ```bash
   istioctl proxy-config clusters deploy/sleep --fqdn httpbin.default.svc.cluster.local --port 8000
   ```

   ```
   SERVICE FQDN                        PORT   SUBSET   DIRECTION   TYPE   DESTINATION RULE
   httpbin.default.svc.cluster.local   8000   -        outbound    EDS
   ```

4. Finalmente, listá los endpoints concretos y su salud — acá es donde "no healthy upstream" se prueba, no se asume:

   ```bash
   istioctl proxy-config endpoints deploy/sleep --cluster \
     "outbound|8000||httpbin.default.svc.cluster.local"
   ```

   ```
   ENDPOINT           STATUS      OUTLIER CHECK   CLUSTER
   10.244.0.15:80     HEALTHY     OK              outbound|8000||httpbin.default.svc.cluster.local
   ```

5. Dejá que un resumen legible por humanos relacione los recursos para un pod, incluyendo qué `VirtualService`/`DestinationRule` aplican y el modo mTLS efectivo:

   ```bash
   istioctl experimental describe pod -l app=httpbin
   ```

**Verificación de comprensión**

- **Q3.1** Poné los cuatro tipos de recursos en el orden en que una request los atraviesa, y enunciá la pregunta de una línea que responde cada uno ("¿qué puerto? → ¿qué cluster? → …").
- **Q3.2** El comando de endpoints devuelve **cero** filas para `outbound|8000||httpbin...`. ¿Qué capa está rota, y qué dos objetos de Kubernetes ajenos a Envoy inspeccionarías para explicar una lista EDS vacía?
- **Q3.3** En la salida del listener, ¿qué es `PassthroughCluster`, y por qué su presencia significa que una request a un puerto que Istio no reconoce es *reenviada* en lugar de descartada? ¿Cómo cambia ese comportamiento bajo `outboundTrafficPolicy: REGISTRY_ONLY`?

---

## Ejercicio 4 — Diagnosticando 503s con access logs y `RESPONSE_FLAGS`

Un `503` es una categoría, no un diagnóstico. Envoy estampa cada response con un **response flag** que te dice *por qué*. Leer ese flag convierte una caída vaga en una falla específica.

1. Hacé que el curl del cliente sea verboso para poder ver el status crudo, y después martillá una route que va a fallar:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code}\n" http://httpbin:8000/status/200
   ```

2. Obtené el access log del sidecar del **lado del cliente** — el proxy outbound registra la falla del upstream:

   ```bash
   kubectl logs deploy/sleep -c istio-proxy --tail=5
   ```

   Una línea representativa de una conexión upstream rota:

   ```
   [2026-08-08T12:34:56.789Z] "GET /status/200 HTTP/1.1" 503 UC
   upstream_reset_before_response_started{connection_termination} - "-"
   0 95 4 - "-" "curl/8.5.0" "b2c3d4e5-..." "httpbin:8000" "10.244.0.15:80"
   outbound|8000||httpbin.default.svc.cluster.local 10.244.0.20:41234
   10.96.1.10:8000 10.244.0.20:52344 - default
   ```

3. Leé los campos que importan: al `503` le sigue `UC` (el flag) y `upstream_reset_before_response_started{connection_termination}` (los `RESPONSE_CODE_DETAILS`). El `UPSTREAM_HOST` `10.244.0.15:80` y el `UPSTREAM_CLUSTER` te dicen exactamente a dónde fue.

4. Compará contra una falla de **no-route** haciendo una request a un host para el que la mesh no tiene route, y observá el flag distinto:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:9999/status/200
   kubectl logs deploy/sleep -c istio-proxy --tail=1
   ```

5. Construí la tabla flag→causa que vas a usar por siempre. Lo esencial:

   | Flag | Significado | Causa raíz típica |
   |------|---------|--------------------|
   | `UH` | No hay upstream sano | Todos los endpoints fallando los health/outlier checks |
   | `UF` | Falla de conexión al upstream | App caída, puerto incorrecto, **o falla del handshake mTLS** |
   | `UC` | Terminación de la conexión upstream | El upstream reseteó la conexión — a menudo la app la cerró, o un desajuste plaintext↔mTLS |
   | `NR` | No hay route configurada | `VirtualService` faltante/no coincidente, Host/puerto incorrecto |
   | `UO` | Overflow del upstream | Circuit breaker (`connectionPool`) disparado |
   | `URX` | Retry/límite excedido | Máximo de retries o máximo de requests alcanzado |
   | `-`  | Sin flag | La falla está en la app (un 503 real de httpbin mismo) |

**Verificación de comprensión**

- **Q4.1** Ves `503 UC` en el sidecar del *cliente* pero los logs de la app del pod *servidor* no muestran ninguna request llegando. ¿Dónde murió la request, y a qué reduce eso la causa?
- **Q4.2** Contrastá `503 NR` con `503 UF`. Uno es un problema de control-plane/config y otro es un problema de conectividad/handshake — cuál es cuál, y cuál es tu primer comando para cada uno?
- **Q4.3** Una línea del access log termina en `503` con el campo de response-flag mostrando `-` (sin flag). ¿Por qué esto *exonera* a la mesh, y a dónde llevás la investigación en su lugar?

---

## Ejercicio 5 — mTLS en el data plane: STRICT vs plaintext

La falla del data plane que más se diagnostica mal es un desajuste de mutual-TLS: el proxy servidor está aplicando `STRICT`, un cliente envía plaintext, la conexión se resetea, y el síntoma es un simple `503 UF`/`UC` que parece que la app está caída. Aprendé a probarlo.

1. Aplicá mTLS `STRICT` para el workload httpbin:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-strict
     namespace: default
   spec:
     selector:
       matchLabels:
         app: httpbin
     mtls:
       mode: STRICT
   EOF
   ```

2. Desde el cliente **dentro de la mesh**, la llamada sigue funcionando, porque su sidecar realiza el handshake mTLS de forma transparente:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "meshed=%{http_code}\n" http://httpbin:8000/status/200
   ```

3. Ahora llamá desde el pod `legacy/sleep` **sin inyectar** creado en el Ejercicio 1. Envía plaintext, el servidor lo rechaza, y obtenés una falla:

   ```bash
   kubectl -n legacy exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "plaintext=%{http_code}\n" \
     --max-time 5 http://httpbin.default:8000/status/200
   ```

4. Confirmá el modo mTLS *efectivo* que el servidor está aplicando y que el proxy cliente tiene certificados válidos:

   ```bash
   istioctl experimental describe pod -l app=httpbin | grep -i mtls
   istioctl proxy-config secret deploy/sleep
   ```

   ```
   RESOURCE NAME   TYPE           STATUS   VALID CERT   SERIAL NUMBER   NOT AFTER              NOT BEFORE
   default         Cert Chain     ACTIVE   true         3a...           2026-08-09T12:00:00Z   2026-08-08T11:58:00Z
   ROOTCA          CA             ACTIVE   true         1f...           2036-08-05T09:00:00Z   2026-08-05T09:00:00Z
   ```

5. Leé el log del sidecar servidor durante la llamada plaintext fallida para ver la razón del rechazo del handshake:

   ```bash
   kubectl logs deploy/httpbin -c istio-proxy --tail=10 | grep -i tls
   ```

**Verificación de comprensión**

- **Q5.1** El mismísimo `curl` al mismísimo Service tiene éxito desde `default/sleep` y falla desde `legacy/sleep`. ¿Qué única variable difiere, y por qué esa variable decide el resultado bajo `STRICT`?
- **Q5.2** Sospechás de mTLS pero querés prueba, no una corazonada. ¿Qué comando muestra el modo de aplicación *efectivo del servidor*, y cuál muestra si el *cliente* siquiera tiene un certificado de workload para presentar?
- **Q5.3** Si hubieras puesto el modo de `PeerAuthentication` en `PERMISSIVE` en lugar de `STRICT`, ¿habría tenido éxito la llamada plaintext desde `legacy/sleep`? Explicá qué le hace `PERMISSIVE` al listener del servidor y por qué existe como herramienta de migración.

---

## Ejercicio 6 — Subiendo el volumen: niveles de log de Envoy y la admin API

Cuando el access log no alcanza, entrás dentro de Envoy. Cada sidecar expone una admin interface en `15000` y un control de verbosidad por logger que podés cambiar *en tiempo de ejecución* sin reiniciar el pod.

1. Subí los loggers de connection y HTTP del proxy cliente a debug, acotados para que no te ahogues en ruido:

   ```bash
   istioctl proxy-config log deploy/sleep --level connection:debug,http:debug
   ```

2. Reproducí la request, y después leé el log recién verboso:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null http://httpbin:8000/status/200
   kubectl logs deploy/sleep -c istio-proxy --tail=40
   ```

3. Llegá directamente a la admin interface de Envoy para el estado real. Hacé port-forward de `15000` y consultá la salud del cluster y la config completa:

   ```bash
   kubectl port-forward deploy/sleep 15000:15000 &
   curl -s localhost:15000/clusters | grep httpbin | grep health_flags
   curl -s localhost:15000/config_dump | jq '.configs[].dynamic_active_clusters' | head
   ```

   O dejá que `istioctl` abra el mismo admin dashboard por vos:

   ```bash
   istioctl dashboard envoy deploy/sleep
   ```

4. Consultá las stats en vivo para cuantificar lo que los flags del Ejercicio 4 estaban contando:

   ```bash
   curl -s localhost:15000/stats | grep -E \
     'cluster.outbound.*httpbin.*(upstream_cx_connect_fail|upstream_rq_5xx|membership_healthy)'
   ```

5. Cuando termines, **reseteá el nivel de log** para no dejar un proxy escupiendo debug en tu pipeline de logging:

   ```bash
   istioctl proxy-config log deploy/sleep --level info
   # or reset every logger to its default:
   istioctl proxy-config log deploy/sleep --reset
   ```

**Verificación de comprensión**

- **Q6.1** `istioctl proxy-config log ... --level debug` cambió la verbosidad de Envoy sin reiniciar el pod. ¿Qué admin endpoint maneja realmente ese comando por debajo, y por qué poder hacer esto en vivo (no vía un redeploy) es crítico durante un incidente?
- **Q6.2** En `/clusters`, una línea de endpoint muestra `health_flags::/failed_active_hc`. Traducí eso a lenguaje llano y conectalo con qué `RESPONSE_FLAG` del Ejercicio 4 esperarías ver si *todos* los endpoints lo llevaran.
- **Q6.3** ¿Por qué `/config_dump` desde el admin port se considera más autoritativo que `istioctl proxy-config`, aunque ambos afirman mostrar "la config de Envoy"? (Pista: pensá en de dónde lee cada uno.)

---

## Más allá de los sidecars — una nota sobre el ambient data plane

Si tu mesh corre en **modo ambient**, el Envoy por-pod desaparece: L4 lo maneja el **ztunnel** por-nodo y L7 los proxies **waypoint**. Los verbos del troubleshooting son los mismos pero las herramientas cambian — `istioctl ztunnel-config workloads`, `istioctl ztunnel-config certificates`, y `kubectl logs` sobre el DaemonSet `ztunnel` reemplazan a `proxy-config` y al log del sidecar. El concepto se transfiere: identidad, después listeners/ruteo, después endpoints, después logs.

---

## Clave de respuestas

<details>
<summary><strong>Mostrar respuestas — Ejercicios 0 a 6</strong></summary>

**Q0.1** Los dos containers son tu container de aplicación (`sleep` o `httpbin`) e `istio-proxy`, el sidecar Envoy inyectado — ese sidecar *es* el componente del data plane para este workload. Un `1/1` habría significado que no se inyectó ningún sidecar: no hay mesh que diagnosticar para ese pod, y cada síntoma de "mesh" sería en realidad networking plano de Kubernetes.

**Q0.2** Con dos containers, `kubectl exec` necesita saber a cuál entrar. Nombrar `-c sleep` garantiza que ejecutes dentro del container de aplicación. Si accidentalmente hacés exec en `istio-proxy`, el conjunto de herramientas, la vista del network namespace y (críticamente) el contexto de redirección de iptables son distintos, así que los resultados pueden confundirte.

**Q1.1** `Running` + ausente de `proxy-status` = el pod no tiene un Envoy funcional que istiod reconozca, casi siempre porque **el sidecar nunca se inyectó**. Verificá la etiqueta `istio-injection=enabled` (o `istio.io/rev`) del namespace, cualquier anotación a nivel de pod `sidecar.istio.io/inject: "false"`, y que el mutating webhook fuera alcanzable cuando se creó el pod. Confirmá con la cantidad de containers (`1/1`).

**Q1.2** Las reglas de iptables de Istio redirigen el tráfico inbound del pod a través de Envoy en 15006; un probe apuntado directamente al puerto de la app puede ser interceptado o bloqueado por mTLS, causando falsos ciclos de "unready". Enrutar el probe a través de **15021** (`/healthz/ready`, un puerto explícitamente excluido servido por el agente, que además verifica que el propio Envoy haya arrancado) le da al kubelet una señal confiable de que tanto el proxy como la app están listos. Dejar el probe original en el puerto de la app arriesga que el kubelet falle el check porque no puede completar un handshake mTLS.

**Q1.3** 15000 = **admin** interface de Envoy; 15006 = puerto de captura **inbound**; 15001 = puerto de captura **outbound**; 15090 = **telemetría Prometheus** de Envoy. Hacés `port-forward` de **15000** para llegar a la admin interface.

**Q2.1** `SYNCED` = Envoy reconoció (ACK) la última config que istiod envió — el estado normal y sano. `STALE` = istiod envió una actualización pero Envoy no la reconoció — el estado de alarma, que significa que el push está atascado, rechazado, o el proxy está unhealthy/sobrecargado. `NOT SENT` = istiod no tenía nada de ese tipo para enviar (por ejemplo, `ECDS` sin filtros de extensión) — benigno.

**Q2.2** (1) Camino istiod→Envoy: el stream xDS está roto o el proxy está desconectado/sobrecargado, así que el ACK nunca llega — verificá la conectividad istiod↔proxy, la carga/CPU de istiod, y la salud del propio proxy. (2) Contenido de la config: istiod hizo push de una config que Envoy **rechazó (NACK)** — un `EnvoyFilter` malformado, una route inválida — así que nunca llega al ACK. Distinguilos con los logs de istiod e `istioctl analyze`.

**Q2.3** Ejecutá `istioctl analyze` para atrapar config estáticamente inválida, después grepeá los logs de istiod (`kubectl logs deploy/istiod -n istio-system`) buscando warnings de `NACK`/`rejected`/`ads` que nombren ese proxy. Un NACK significa que la config fue recibida y rechazada (arreglá la config); sin NACK y sin ACK significa que el push no está llegando en absoluto (un problema de entrega/conexión).

**Q3.1** **Listener → Route → Cluster → Endpoint.** Listener: "¿en qué puerto/protocolo llegó la request?" Route: "dado el Host/path, ¿qué cluster lo maneja?" Cluster: "¿qué servicio upstream, y cómo lo balanceo/aseguro?" Endpoint: "¿qué IPs concretas de pods, y están sanas?"

**Q3.2** La capa de **endpoint (EDS)** está rota — Envoy tiene un cluster pero sin backends. Los dos objetos ajenos a Envoy para inspeccionar son el **Service** de Kubernetes (¿su label selector coincide con los pods, y el puerto está nombrado/numerado correctamente?) y el **EndpointSlice/Endpoints** resultante (¿hay alguna IP de pod realmente listada y Ready?). Una lista EDS vacía casi siempre se rastrea a un desajuste de selector o puerto, o a todos los pods fallando la readiness.

**Q3.3** `PassthroughCluster` es el catch-all de Envoy que reenvía el tráfico a su IP:puerto de destino original sin ruteo de mesh, usado cuando una request apunta a algo que no está en el service registry. Bajo la política por defecto `ALLOW_ANY` esto deja pasar el tráfico desconocido/externo. Bajo `outboundTrafficPolicy: REGISTRY_ONLY`, ese catch-all se convierte en `BlackHoleCluster` y los destinos desconocidos son **rechazados** — así que la misma request que antes pasaba ahora falla (un bloqueo deliberado del egress, y una causa sorpresa frecuente de nuevos 502/503 después de endurecer la política).

**Q4.1** La request murió en el **intento del sidecar cliente de alcanzar el upstream** — nunca obtuvo una respuesta utilizable del servidor, y como la app del servidor no registró nada, la *aplicación* del servidor nunca la procesó. Eso reduce la causa a la conexión entre los dos proxies o al sidecar servidor rechazando la conexión: puerto incorrecto, upstream caído, o (muy comúnmente) un **desajuste de mTLS** que reseteó la conexión antes de alcanzar la app.

**Q4.2** `503 NR` = **No Route**: un problema de config — Envoy no tiene ninguna route que coincida con ese Host/puerto, así que arreglá el `VirtualService`/`Gateway` y verificá con `istioctl proxy-config routes`. `503 UF` = **Upstream Failure**: un problema de conectividad/handshake — la conexión al upstream falló, así que verificá la salud de los endpoints (`istioctl proxy-config endpoints`) y el estado de mTLS (`istioctl x describe pod`, `proxy-config secret`).

**Q4.3** Un response flag `-` significa que Envoy hizo proxy de la request de punta a punta exitosamente y simplemente retransmitió lo que el upstream devolvió — el `503` es la respuesta **propia de la aplicación**, no una falla inyectada por la mesh. La mesh hizo su trabajo; llevá la investigación a la propia aplicación httpbin (sus logs, sus dependencias, sus propios upstreams).

**Q5.1** La variable que difiere es **si el cliente tiene un sidecar** (`default/sleep` lo tiene, `legacy/sleep` no). Bajo `STRICT`, el inbound listener del servidor acepta *solo* conexiones mTLS; el sidecar del cliente dentro de la mesh presenta un certificado de workload y completa el handshake, mientras que el cliente sin inyectar envía plaintext, que el servidor rechaza — de ahí el éxito vs. la falla al Service idéntico.

**Q5.2** `istioctl experimental describe pod -l app=httpbin` reporta el modo mTLS **efectivo** del servidor (el resultado combinado de la `PeerAuthentication` a nivel de mesh, namespace y workload). `istioctl proxy-config secret deploy/sleep` muestra si el proxy **cliente** realmente tiene un cert de workload `default` válido (y el `ROOTCA`) para presentar — una lista de secrets vacía o expirada es en sí misma una causa raíz.

**Q5.3** No — bajo `PERMISSIVE` la llamada plaintext **tiene éxito**. `PERMISSIVE` hace que el listener del servidor acepte *tanto* mTLS como plaintext en el mismo puerto, que es exactamente por lo que existe: te permite incorporar workloads a la mesh de forma incremental sin un corte de flag-day, y después pasás a `STRICT` una vez que todos los clientes están dentro de la mesh. Es un modo de migración, no un estado objetivo.

**Q6.1** Maneja el endpoint admin **`POST /logging?level=...`** de Envoy en el puerto 15000. Poder cambiar la verbosidad en vivo es crítico porque un incidente a menudo no es reproducible después de un reinicio — reiniciar el pod destruye el mismísimo estado de conexión y la condición in-flight que estás tratando de observar. Los cambios de nivel de log en vivo te permiten capturar la falla mientras ocurre, y después bajar de nuevo sin perturbar el workload.

**Q6.2** `failed_active_hc` significa que ese endpoint **falló el active health check de Envoy**, así que Envoy lo removió del pool de balanceo de carga. Si *todos* los endpoints del cluster llevaran un health flag fallido, el cluster tendría cero miembros sanos y las requests devolverían **`503 UH`** (No Healthy Upstream).

**Q6.3** `/config_dump` se lee **directamente del proceso Envoy en ejecución** por su admin port — es la configuración real y en vivo que Envoy está ejecutando ahora mismo. `istioctl proxy-config` también consulta la admin API del proxy, pero la distinción significativa en la que los operadores confían es entre lo que *Envoy tiene* (ambas vistas admin) y lo que *istiod cree que envió* (`proxy-status`); ante la duda de si un push realmente aterrizó en el data plane, el `config_dump` del admin es la verdad de base, porque refleja el estado en vivo post-ACK en lugar de la intención del control plane.

</details>

---

### Fuentes

- Istio — *Debugging Envoy and Istiod* (`proxy-status`, `proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — *Diagnose your Configuration with Istioctl Analyze*: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Istio — *Understanding 503 errors / Network problems*: https://istio.io/latest/docs/ops/common-problems/network-issues/
- Istio — *Security problems* (mTLS troubleshooting): https://istio.io/latest/docs/ops/common-problems/security-issues/
- Istio — *Ports used by Istio*: https://istio.io/latest/docs/ops/deployment/requirements/
- Istio — *Getting Envoy's Access Logs*: https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Istio — *PeerAuthentication* reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — *istioctl* command reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Envoy — *Access logging — response flags*: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy — *Administration interface*: https://www.envoyproxy.io/docs/envoy/latest/operations/admin