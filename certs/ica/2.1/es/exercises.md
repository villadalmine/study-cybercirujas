# Tema 2.1 — Troubleshooting Configuration (ICA)

El diagnóstico de configuración en Istio se apoya en una **escalera de verificación**, y cada peldaño prueba una cosa distinta: que la config sea *válida* no prueba que esté *distribuida*, y que esté distribuida no prueba que el tráfico *funcione*. Los ejercicios de este tema recorren esa escalera de arriba hacia abajo:

1. **Análisis estático** — `istioctl analyze` valida los CRDs (`VirtualService`, `DestinationRule`, `Gateway`, `PeerAuthentication`, …) *antes* de que llegue tráfico, sin tocar el data plane.
2. **Distribución de configuración** — `istioctl proxy-status` compara el estado que `istiod` calculó contra lo que cada proxy Envoy ACKeó vía xDS (`CDS`/`LDS`/`EDS`/`RDS`/`ECDS`).
3. **Configuración por-proxy** — `istioctl proxy-config {routes|clusters|endpoints|listeners|secret}` dumpea el estado real de un Envoy concreto.
4. **Runtime** — los *access logs* de Envoy y sus `RESPONSE_FLAGS` explican *por qué* murió una request individual.

Un error de configuración puede manifestarse en cualquiera de esos peldaños, y —lección central del tema— un check que pasa en un peldaño superior **no** garantiza los inferiores: `istioctl analyze` puede dar limpio y el tráfico igual devolver `503`.

**Fuentes de referencia:**
- `istioctl analyze`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Catálogo de mensajes del analizador (códigos `IST0xxx`): https://istio.io/latest/docs/reference/config/analysis/
- Debug de Envoy/Pilot con `proxy-config`/`proxy-status`: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Problemas comunes de red (503, routing): https://istio.io/latest/docs/ops/common-problems/network-issues/
- Problemas comunes de inyección: https://istio.io/latest/docs/ops/common-problems/injection/
- Problemas comunes de seguridad (mTLS): https://istio.io/latest/docs/ops/common-problems/security-issues/
- Envoy `RESPONSE_FLAGS`: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags

---

## Prerrequisitos

Necesitás un cluster con Istio instalado (`kind`/`minikube` alcanza) y `istioctl` en el `PATH`, versión igual a la del control plane.

```bash
# Verificá que el control plane y el cliente coincidan en versión
istioctl version
# client version: 1.20.0
# control plane version: 1.20.0
# data plane version: 1.20.0 (3 proxies)

# Namespace de trabajo, SIN inyección todavía (a propósito)
kubectl create namespace mesh-lab
```

Desplegamos la app de ejemplo `helloworld` (dos versiones, `v1` y `v2`, misma `Service`) y un cliente `sleep` para generar tráfico desde adentro de la malla. Ambos manifiestos vienen con la distribución de Istio en `samples/`.

```bash
kubectl label namespace mesh-lab istio-injection=enabled
kubectl apply -n mesh-lab -f samples/helloworld/helloworld.yaml
kubectl apply -n mesh-lab -f samples/sleep/sleep.yaml
kubectl get pods -n mesh-lab
# NAME                             READY   STATUS    RESTARTS   AGE
# helloworld-v1-8d69f847d-abcde    2/2     Running   0          40s
# helloworld-v2-6c9b5b7f4-fghij    2/2     Running   0          40s
# sleep-9454cc476-klmno           2/2     Running   0          40s
```

El `2/2` es la primera señal de diagnóstico: el segundo contenedor es el sidecar `istio-proxy`. Un `1/1` acá significaría que la inyección no ocurrió.

---

## Ejercicio 1 — `istioctl analyze`: validación estática y detección de inyección

**Objetivo:** usar el analizador como primer filtro y entender que sus códigos `IST0xxx` mapean a categorías reproducibles de error.

**Pasos:**

1. Creá a propósito un namespace *sin* la etiqueta de inyección y meté un workload y una `Service` con un puerto mal nombrado:

   ```bash
   kubectl create namespace broken
   cat <<'EOF' | kubectl apply -n broken -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 1
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
         - name: web
           image: nginx:1.25
           ports:
           - containerPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
     - name: 8080          # <-- nombre sin prefijo de protocolo
       port: 8080
       targetPort: 8080
   EOF
   ```

2. Corré el analizador acotado a ese namespace:

   ```bash
   istioctl analyze -n broken
   ```

   Salida esperada (los códigos exactos pueden variar por versión, no así la categoría):

   ```
   Warning [IST0102] (Namespace broken) The namespace is not enabled for Istio injection. Run 'kubectl label namespace broken istio-injection=enabled' to enable it, or 'kubectl label namespace broken istio-injection=disabled' to explicitly mark it as not needing injection.
   Warning [IST0118] (Service web.broken) Port name 8080 (port: 8080, targetPort: 8080) doesn't follow the naming convention of Istio port and may not be able to identify the protocol.
   Error: Analyzers found issues when analyzing namespace: broken.
   See https://istio.io/latest/docs/reference/config/analysis for more information about causes and resolutions.
   ```

3. Analizá *todo el cluster*, no solo un namespace, para ver que `analyze` también correlaciona recursos entre namespaces:

   ```bash
   istioctl analyze --all-namespaces
   ```

4. Analizá un manifiesto en disco **sin aplicarlo** (validación pre-merge, útil en CI):

   ```bash
   istioctl analyze broken-service.yaml --use-kube=false
   ```

> **Preguntas de verificación (bloque 1):**
> 1. ¿Por qué `IST0118` (nombre de puerto sin prefijo de protocolo) es un problema *funcional* y no solo cosmético? ¿Qué comportamiento de Istio depende de ese nombre?
> 2. El mensaje `IST0102` es un `Warning`, no un `Error`, pero `istioctl analyze` igual termina con exit code distinto de cero. ¿Qué controla el umbral de severidad que hace fallar el comando, y para qué sirve eso en un pipeline?
> 3. ¿Qué diferencia hay entre `istioctl analyze -n broken` y `istioctl analyze archivo.yaml --use-kube=false`? ¿Cuál usarías en un hook de pre-commit y por qué?

---

## Ejercicio 2 — Distribución de configuración: `proxy-status` (SYNCED / STALE / NOT SENT)

**Objetivo:** distinguir "la config es válida" de "la config llegó al proxy". Un `VirtualService` correcto que no se propagó no cambia nada en runtime.

**Pasos:**

1. Pedí el estado de sincronización xDS de todos los proxies contra `istiod`:

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                                   CLUSTER      CDS      LDS      EDS      RDS      ECDS       ISTIOD                      VERSION
   helloworld-v1-8d69f847d-abcde.mesh-lab Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6b8d7c9f5-pq7rs      1.20.0
   helloworld-v2-6c9b5b7f4-fghij.mesh-lab Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6b8d7c9f5-pq7rs      1.20.0
   sleep-9454cc476-klmno.mesh-lab         Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6b8d7c9f5-pq7rs      1.20.0
   ```

2. Interpretá cada estado. En condiciones normales todo debe estar `SYNCED`; `NOT SENT` en `ECDS` es normal si no usás `EnvoyFilter` con extension config. Los estados posibles:
   - **SYNCED** — Envoy ACKeó la última config que `istiod` le envió. Es el estado sano.
   - **NOT SENT** — `istiod` no envió nada de ese subrecurso (no hay nada que enviar). Normal para `ECDS` sin extensiones.
   - **STALE** — `istiod` envió una actualización pero el proxy **no** la ACKeó. Indica un proxy atascado, sobrecargado, o pérdida de conexión ADS.

3. Provocá una divergencia y observá el diagnóstico. Escalá `istiod` a cero réplicas (solo en lab) y aplicá un cambio de config; los proxies quedan con la última buena y no reciben la nueva:

   ```bash
   kubectl -n istio-system scale deploy/istiod --replicas=0
   # aplicá cualquier VirtualService acá...
   istioctl proxy-status
   # ...y observá que los proxies siguen sirviendo la última config ACKeada.
   kubectl -n istio-system scale deploy/istiod --replicas=1
   ```

4. Para un proxy puntual, compará el hash de config que tiene Envoy contra el que `istiod` calculó:

   ```bash
   istioctl proxy-status helloworld-v1-8d69f847d-abcde.mesh-lab
   ```

> **Preguntas de verificación (bloque 2):**
> 1. Un compañero dice "apliqué el `DestinationRule` y `istioctl analyze` da limpio, pero el tráfico no cambió". ¿Qué columna de `proxy-status` mirás primero y qué valor te confirmaría que la config **no** llegó al data plane?
> 2. ¿Qué significan exactamente las siglas `CDS`, `LDS`, `EDS` y `RDS`, y qué tipo de recurso Istio afecta principalmente a cada una? (por ejemplo, ¿un `VirtualService` HTTP mueve mayormente cuál?)
> 3. Ves un solo proxy en `STALE` mientras el resto está `SYNCED`. ¿Es un problema de la *configuración* o del *proxy*? ¿Cuál es tu siguiente comando?

---

## Ejercicio 3 — Ruta a un subset inexistente (`IST0101`) y `proxy-config`

**Objetivo:** conectar un error que `analyze` **sí** detecta estáticamente con su manifestación en la config de Envoy (`routes` vs `clusters`).

**Pasos:**

1. Definí un `DestinationRule` con subsets `v1` y `v2`, pero un `VirtualService` que enruta 100% a un subset `v3` que **no existe**:

   ```bash
   cat <<'EOF' | kubectl apply -n mesh-lab -f -
   apiVersion: networking.istio.io/v1beta1
   kind: DestinationRule
   metadata:
     name: helloworld
   spec:
     host: helloworld.mesh-lab.svc.cluster.local
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
   ---
   apiVersion: networking.istio.io/v1beta1
   kind: VirtualService
   metadata:
     name: helloworld
   spec:
     hosts:
     - helloworld.mesh-lab.svc.cluster.local
     http:
     - route:
       - destination:
           host: helloworld.mesh-lab.svc.cluster.local
           subset: v3          # <-- no declarado en el DestinationRule
   EOF
   ```

2. Detectalo estáticamente:

   ```bash
   istioctl analyze -n mesh-lab
   ```

   ```
   Error [IST0101] (VirtualService helloworld.mesh-lab) Referenced host+subset in destinationrule not found: "helloworld.mesh-lab.svc.cluster.local+v3"
   Error: Analyzers found issues when analyzing namespace: mesh-lab.
   ```

3. Mirá cómo se ve en el Envoy del cliente. Primero la ruta que Pilot programó:

   ```bash
   istioctl proxy-config routes deploy/sleep -n mesh-lab \
     --name 5000 -o json | grep -A2 '"cluster"'
   ```

   La ruta apunta a un cluster con el subset `v3` embebido en el nombre:

   ```
   "cluster": "outbound|5000|v3|helloworld.mesh-lab.svc.cluster.local"
   ```

4. Ahora listá los clusters reales que tiene ese Envoy: el subset `v3` **no está**:

   ```bash
   istioctl proxy-config clusters deploy/sleep -n mesh-lab \
     --fqdn helloworld.mesh-lab.svc.cluster.local
   ```

   ```
   SERVICE FQDN                                    PORT   SUBSET   DIRECTION    TYPE   DESTINATION RULE
   helloworld.mesh-lab.svc.cluster.local           5000   -        outbound     EDS    helloworld.mesh-lab
   helloworld.mesh-lab.svc.cluster.local           5000   v1       outbound     EDS    helloworld.mesh-lab
   helloworld.mesh-lab.svc.cluster.local           5000   v2       outbound     EDS    helloworld.mesh-lab
   ```

5. Generá tráfico y observá el fallo en runtime. La ruta existe pero el cluster no, así que Envoy responde `503`:

   ```bash
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" helloworld:5000/hello
   # 503
   ```

6. Arreglalo declarando el subset `v3` en el `DestinationRule` (o corrigiendo el `VirtualService` a `v1`), y re-verificá con `analyze` + un `curl` que devuelva `200`.

> **Preguntas de verificación (bloque 3):**
> 1. En el nombre de cluster `outbound|5000|v3|helloworld...`, ¿qué representa cada uno de los cuatro campos separados por `|`? ¿Por qué el subset viaja *dentro* del nombre del cluster y no como parámetro aparte?
> 2. Este error lo agarró `istioctl analyze`. ¿En qué peldaño de la escalera de diagnóstico está, y por qué es preferible detectarlo ahí y no con el `curl` del paso 5?
> 3. En el access log del sidecar de `sleep`, ¿qué `RESPONSE_FLAG` esperás para "la ruta existe pero apunta a un cluster que Envoy no conoce", y en qué se diferencia semánticamente de `NR` (no route)?

---

## Ejercicio 4 — El `503 UH` que `analyze` NO detecta: subset sin endpoints

**Objetivo:** demostrar el límite del análisis estático. Un `DestinationRule` puede ser *sintáctica y referencialmente* correcto (analyze da limpio) y aun así no tener endpoints vivos detrás. Esto solo se ve en `proxy-config endpoints`.

**Pasos:**

1. Declará un subset `v3` **válido** (el `DestinationRule` ahora sí lo tiene) que selecciona por `version: v3`, pero **ningún pod** tiene esa etiqueta:

   ```bash
   cat <<'EOF' | kubectl apply -n mesh-lab -f -
   apiVersion: networking.istio.io/v1beta1
   kind: DestinationRule
   metadata:
     name: helloworld
   spec:
     host: helloworld.mesh-lab.svc.cluster.local
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
     - name: v3
       labels: { version: v3 }   # válido, pero no hay pods v3
   ---
   apiVersion: networking.istio.io/v1beta1
   kind: VirtualService
   metadata:
     name: helloworld
   spec:
     hosts:
     - helloworld.mesh-lab.svc.cluster.local
     http:
     - route:
       - destination:
           host: helloworld.mesh-lab.svc.cluster.local
           subset: v3
   EOF
   ```

2. Corré el analizador. **Da limpio** — no hay ninguna referencia rota:

   ```bash
   istioctl analyze -n mesh-lab
   # ✔ No validation issues found when analyzing namespace: mesh-lab.
   ```

3. Generá tráfico: ahora el fallo es distinto al del ejercicio 3.

   ```bash
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s helloworld:5000/hello
   # no healthy upstream
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" helloworld:5000/hello
   # 503
   ```

4. Ahora sí bajá al peldaño que expone la causa: el cluster `v3` existe pero tiene **cero endpoints**:

   ```bash
   istioctl proxy-config endpoints deploy/sleep -n mesh-lab \
     --cluster "outbound|5000|v3|helloworld.mesh-lab.svc.cluster.local"
   ```

   ```
   ENDPOINT   STATUS   OUTLIER CHECK   CLUSTER
   (vacío — sin filas)
   ```

   Compará con `v1`, que sí tiene endpoint:

   ```bash
   istioctl proxy-config endpoints deploy/sleep -n mesh-lab \
     --cluster "outbound|5000|v1|helloworld.mesh-lab.svc.cluster.local"
   ```

   ```
   ENDPOINT             STATUS   OUTLIER CHECK   CLUSTER
   10.244.0.21:5000     HEALTHY  OK              outbound|5000|v1|helloworld.mesh-lab.svc.cluster.local
   ```

5. Confirmá con `istioctl x describe pod` que reúne routing, mTLS y endpoints en una vista de diagnóstico:

   ```bash
   istioctl experimental describe pod -n mesh-lab \
     $(kubectl get pod -n mesh-lab -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   ```

6. Arreglalo apuntando el `VirtualService` a un subset con pods (`v1`), o etiquetando/desplegando un pod `version: v3`.

> **Preguntas de verificación (bloque 4):**
> 1. Los ejercicios 3 y 4 dan **ambos** `HTTP 503`, pero por causas distintas. Explicá la diferencia de raíz entre "cluster inexistente" (Ej. 3) y "cluster sin endpoints" (Ej. 4), y qué comando distingue uno de otro.
> 2. Este es el punto pedagógico central del tema: `istioctl analyze` dio *limpio* y el tráfico igual falló. ¿Por qué el análisis estático es incapaz, por diseño, de detectar el subset sin endpoints? ¿Qué información necesita que no está en los CRDs?
> 3. ¿Qué `RESPONSE_FLAG` de Envoy corresponde a "no healthy upstream" y en qué otros escenarios de producción (además de un subset vacío) lo verías? Nombrá al menos dos.

---

## Ejercicio 5 — `503 UC` por mismatch de mTLS (`PeerAuthentication` vs `DestinationRule`)

**Objetivo:** diagnosticar el `503` más traicionero de Istio: el que aparece al aplicar seguridad. El servidor exige mTLS (`STRICT`) pero un `DestinationRule` fuerza al cliente a mandar texto plano; el servidor corta la conexión y el cliente lo reporta como `UC` (*upstream connection termination*).

**Pasos:**

1. Poné el servidor `helloworld` en modo mTLS `STRICT` a nivel namespace:

   ```bash
   cat <<'EOF' | kubectl apply -n mesh-lab -f -
   apiVersion: security.istio.io/v1beta1
   kind: PeerAuthentication
   metadata:
     name: default
   spec:
     mtls:
       mode: STRICT
   EOF
   ```

2. Verificá que en este punto todo funciona (cliente con sidecar → mTLS automático):

   ```bash
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" helloworld:5000/hello
   # 200
   ```

3. Ahora introducí el conflicto: un `DestinationRule` que **desactiva** TLS del lado cliente hacia ese host. El cliente mandará texto plano a un servidor que exige mTLS:

   ```bash
   cat <<'EOF' | kubectl apply -n mesh-lab -f -
   apiVersion: networking.istio.io/v1beta1
   kind: DestinationRule
   metadata:
     name: helloworld-plaintext
   spec:
     host: helloworld.mesh-lab.svc.cluster.local
     trafficPolicy:
       tls:
         mode: DISABLE          # <-- cliente en texto plano
   EOF
   ```

4. Generá tráfico. Ahora falla:

   ```bash
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" helloworld:5000/hello
   # 503
   ```

5. `istioctl analyze` **no** te salva acá tampoco (la config es individualmente válida). Subí el log level del sidecar cliente y leé su access log para ver el flag:

   ```bash
   istioctl proxy-config log deploy/sleep -n mesh-lab --level debug
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null helloworld:5000/hello
   kubectl logs -n mesh-lab deploy/sleep -c istio-proxy --tail=1
   ```

   Access log típico (formato por defecto de Istio, fijate el `UC`):

   ```
   [2026-08-08T12:00:00.000Z] "GET /hello HTTP/1.1" 503 UC upstream_reset_before_response_started{connection_termination}
   0 95 4 - "-" "curl/8.5.0" "a1b2..." "helloworld:5000"
   "10.244.0.21:5000" outbound|5000|v1|helloworld.mesh-lab.svc.cluster.local - 10.244.0.21:5000 ...
   ```

6. Confirmá el diagnóstico de mTLS con la vista integrada, que te dice qué modo espera el destino:

   ```bash
   istioctl experimental describe pod -n mesh-lab \
     $(kubectl get pod -n mesh-lab -l app=helloworld,version=v1 -o jsonpath='{.items[0].metadata.name}')
   ```

   Salida relevante:

   ```
   Pod: helloworld-v1-8d69f847d-abcde.mesh-lab
      ...
   RBAC policies: ...
   helloworld.mesh-lab.svc.cluster.local over port 5000 (http)
      Effective PeerAuthentication mode: STRICT
      DestinationRule: helloworld-plaintext for "helloworld.mesh-lab.svc.cluster.local"
         WARNING POD IS STRICT BUT DESTINATIONRULE DISABLES CLIENT mTLS
   ```

7. Arreglalo. Las dos salidas válidas: (a) borrar el `DestinationRule` para volver a mTLS automático, o (b) cambiar su modo a `ISTIO_MUTUAL` para que el cliente presente su certificado:

   ```bash
   kubectl patch destinationrule helloworld-plaintext -n mesh-lab --type merge \
     -p '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'
   kubectl exec -n mesh-lab deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" helloworld:5000/hello
   # 200
   ```

> **Preguntas de verificación (bloque 5):**
> 1. La `PeerAuthentication` y el `DestinationRule` viven en planos distintos de la política de mTLS. Explicá qué controla cada uno (lado servidor vs lado cliente) y por qué son necesarios *los dos* para que mTLS funcione de punta a punta.
> 2. ¿Por qué `istioctl analyze` no marca este conflicto como error, si claramente rompe el tráfico? ¿Qué tendría que "saber" el analizador que no puede deducir de un solo recurso?
> 3. Distinguí los tres flags de terminación de conexión que podrías ver acá: `UC`, `UF` y `UR`. ¿Cuál corresponde a "el servidor STRICT cerró la conexión porque llegó texto plano", y por qué no es `UF`?
> 4. Un caso relacionado: un cliente **sin sidecar** (namespace sin inyección) intenta llamar a este servicio `STRICT`. El `curl` no devuelve `503` sino que muere con `exit code 56` / *Connection reset by peer*. ¿Por qué el síntoma es distinto al del paso 4?

---

## Ejercicio 6 — Referencia de campo: `RESPONSE_FLAGS` de Envoy

**Objetivo:** consolidar la lectura de access logs. El `RESPONSE_FLAGS` es la pieza de diagnóstico más densa: dos o tres letras que te dicen quién cortó la request y por qué. Es el peldaño más bajo de la escalera y donde termina casi todo troubleshooting de configuración.

**Pasos:**

1. Asegurate de tener access logs habilitados (en `IstioOperator`/mesh config: `meshConfig.accessLogFile: /dev/stdout`) y leé el sidecar:

   ```bash
   kubectl logs -n mesh-lab deploy/sleep -c istio-proxy --tail=20
   ```

2. Estudiá la tabla de flags más frecuentes en troubleshooting de configuración:

   | Flag | Significado | Causa típica de config en Istio |
   |------|-------------|----------------------------------|
   | `UH` | No healthy upstream | Subset sin endpoints; selector de `DestinationRule` sin pods (Ej. 4) |
   | `NR` | No route configured | Falta `VirtualService`/`Gateway`; host no matchea ninguna ruta; puerto mal nombrado (Ej. 1) |
   | `NC` | Upstream cluster not found | Ruta a un subset no declarado en `DestinationRule` (Ej. 3) |
   | `UC` | Upstream connection termination | Mismatch de mTLS: servidor STRICT, cliente texto plano (Ej. 5) |
   | `UF` | Upstream connection failure | El upstream no acepta conexión (app caída, puerto equivocado) |
   | `UO` | Upstream overflow | Circuit breaking por `connectionPool` del `DestinationRule` |
   | `URX` | Retry/connect limit exceeded | `retries` del `VirtualService` agotados |
   | `UT` | Upstream request timeout | `timeout` del `VirtualService` demasiado bajo |
   | `DC` | Downstream connection termination | El cliente cortó antes de la respuesta |

3. Reproducí un `UO` para fijar el concepto: apretá el circuit breaker y mandá tráfico concurrente.

   ```bash
   cat <<'EOF' | kubectl apply -n mesh-lab -f -
   apiVersion: networking.istio.io/v1beta1
   kind: DestinationRule
   metadata:
     name: helloworld-cb
   spec:
     host: helloworld.mesh-lab.svc.cluster.local
     trafficPolicy:
       connectionPool:
         http:
           http1MaxPendingRequests: 1
           maxRequestsPerConnection: 1
         tcp:
           maxConnections: 1
   EOF
   # Disparo de varias requests en paralelo -> algunas devuelven 503 con flag UO
   ```

> **Preguntas de verificación (bloque 6):**
> 1. Recibís un `503 NR`. Recorré la escalera de diagnóstico: ¿qué tres cosas chequeás, en orden, y con qué comandos?
> 2. `UO` y `URX` ambos aparecen bajo carga. ¿Cuál te dice "estás siendo limitado por el `connectionPool`" y cuál "los reintentos configurados se agotaron"? ¿Qué recurso de Istio controla cada uno?
> 3. ¿Por qué `UF` apunta a un problema de la *aplicación* (o del puerto) y `UC` apunta a un problema de la *malla* (mTLS), aunque los dos sean fallos de conexión al upstream?

---

## Respuestas

<details>
<summary>Mostrar respuestas de todos los bloques</summary>

### Bloque 1 — `istioctl analyze`

1. **`IST0118` es funcional porque Istio usa el nombre del puerto de la `Service` para determinar el protocolo L7** (`http`, `http2`, `grpc`, `tcp`, `tls`, …). El nombre debe ser el protocolo o tener el prefijo `protocolo-` (p. ej. `http`, `http-web`). Sin ese hint, y sin *protocol detection* explícito, Istio trata el puerto como TCP opaco: perdés routing HTTP, retries, timeouts, métricas L7 y matching por header en el `VirtualService`. Un `VirtualService` HTTP sobre un puerto detectado como TCP simplemente no aplica.
2. Lo controla el flag **`--failure-threshold`** (por defecto `Error`). Con el default, `Warning`/`Info` no cambian el exit code; pero si hay al menos un mensaje de nivel ≥ umbral, `analyze` termina con exit ≠ 0. En un pipeline eso te deja **fallar el build** ante errores reales y, si querés ser más estricto, bajás el umbral a `Warning` (`--failure-threshold Warning`) para bloquear también sobre warnings.
3. `-n broken` analiza el **estado vivo del cluster** (consulta la API de Kubernetes). `archivo.yaml --use-kube=false` analiza **solo los archivos**, sin contactar el cluster, ideal para CI/pre-commit porque es hermético y no depende de credenciales ni de que el recurso ya esté aplicado. Para un hook de pre-commit usás la segunda forma; podés combinar archivos + cluster omitiendo `--use-kube=false` para que valide el manifiesto *contra* lo que ya existe.

### Bloque 2 — `proxy-status`

1. Mirás las columnas de sincronización (`CDS`/`LDS`/`EDS`/`RDS`). Un valor **`STALE`** confirma que `istiod` calculó la nueva config pero el proxy no la ACKeó; un `NOT SENT` inesperado en un subrecurso que debería tener datos también es sospechoso. Si todo está `SYNCED` pero el tráfico no cambió, el problema **no** es de distribución y bajás a `proxy-config` para ver qué config tiene realmente el proxy.
2. `CDS` = *Cluster Discovery Service* (upstreams/clusters, moldeados por `Service`+`DestinationRule`/subsets). `LDS` = *Listener Discovery Service* (puertos/listeners, moldeados por `Gateway`/`Sidecar`). `EDS` = *Endpoint Discovery Service* (IPs vivas detrás de cada cluster, vienen de los `EndpointSlice`). `RDS` = *Route Discovery Service* (reglas de routing HTTP, moldeadas por `VirtualService`). Un `VirtualService` HTTP mueve **principalmente `RDS`** (y `CDS` si toca subsets).
3. Es un problema **del proxy**, no de la configuración: la config es la misma para todos y el resto sincronizó bien. Siguiente paso: inspeccionar ese proxy — `kubectl logs <pod> -c istio-proxy` y `istioctl proxy-config all <pod>`; causas comunes son un sidecar sobrecargado (CPU throttling), una conexión ADS caída, o un Envoy que quedó en un estado inconsistente y necesita reinicio del pod.

### Bloque 3 — subset inexistente (`IST0101` / `NC`)

1. El nombre `outbound|5000|v3|helloworld...` es `direction|port|subset|FQDN`: **dirección** del tráfico (`outbound`/`inbound`), **puerto** del servicio, **subset** del `DestinationRule`, y **FQDN** del host. El subset viaja dentro del nombre del cluster porque en el modelo xDS cada subset es un *cluster distinto* (con su propio `loadBalancer`, `connectionPool`, `tls`); la ruta selecciona a cuál mandar por ese identificador.
2. Está en el **peldaño 1 (análisis estático)**. Es preferible detectarlo ahí porque `analyze` no necesita tráfico, no consume una request de usuario real, corre en CI antes del merge, y te da un mensaje con el recurso y la causa exacta (`+v3`), mientras que el `curl` solo te da un `503` opaco que después tenés que rastrear hacia abajo por toda la escalera.
3. Esperás **`NC`** (*upstream cluster not found*): la ruta existe y matchea, pero apunta a un cluster que Envoy no tiene en su CDS. Se diferencia de **`NR`** (*no route*), donde el problema es que *ninguna ruta* matcheó la request (falta el `VirtualService`, host equivocado, puerto sin protocolo). `NC` = "sé a dónde debía ir pero ese destino no existe"; `NR` = "no supe a dónde mandarlo".

### Bloque 4 — subset sin endpoints (`UH`)

1. Ej. 3: el **cluster no existe** en CDS (subset nunca declarado) → `NC`. Ej. 4: el **cluster existe** (subset declarado, EDS creado) pero está **vacío** porque ningún pod matchea el selector → `UH`. El comando que los distingue es `istioctl proxy-config clusters` (¿aparece el subset?) seguido de `istioctl proxy-config endpoints --cluster ...` (¿tiene filas?).
2. El análisis estático solo ve los **CRDs**: puede validar que el subset `v3` esté *declarado* (referencia consistente), pero no puede saber cuántos **pods vivos** matchean `version: v3` — eso depende del estado dinámico del cluster (pods corriendo, `Ready`, etiquetas), que es EDS/`EndpointSlice`, no config. La correspondencia "selector → endpoints" solo se resuelve en runtime.
3. **`UH`** = *no healthy upstream*. Además del subset vacío, lo ves cuando: todos los pods del servicio están `NotReady`/caídos; *outlier detection* del `DestinationRule` ejectó a todos los endpoints por errores; un rollout dejó cero réplicas temporalmente; o los health checks fallan y sacan a todos los backends del pool.

### Bloque 5 — mTLS mismatch (`UC`)

1. La **`PeerAuthentication`** controla el **lado servidor**: qué acepta el sidecar receptor (`STRICT` = solo mTLS, `PERMISSIVE` = mTLS *o* texto plano, `DISABLE` = solo texto plano). El **`DestinationRule` (`trafficPolicy.tls`)** controla el **lado cliente**: cómo origina la conexión el sidecar emisor (`ISTIO_MUTUAL` = presenta el cert de la malla, `DISABLE` = texto plano, `SIMPLE`/`MUTUAL` = TLS con certs propios). Hacen falta los dos coherentes: el servidor tiene que *exigir/aceptar* mTLS y el cliente tiene que *originarlo*; si uno dice mTLS y el otro texto plano, se rompe.
2. Porque **cada recurso es válido por separado**: un `DestinationRule` con `tls.mode: DISABLE` es legítimo, y una `PeerAuthentication` `STRICT` también. El conflicto es *relacional* — surge de combinar dos recursos que apuntan al mismo host — y `analyze` tendría que correlacionar la política efectiva de peer authentication del destino con el modo TLS del cliente sobre ese FQDN. (`istioctl x describe pod` sí hace esa correlación y por eso lo marca con `WARNING`.)
3. **`UC`** (*upstream connection termination*) es el correcto: la conexión al upstream **se estableció** y el servidor STRICT la **cerró** al ver un handshake/tráfico que no es mTLS. **`UF`** (*upstream connection failure*) sería si ni siquiera se pudiera establecer la conexión TCP (app caída, puerto cerrado) — no es el caso, porque el servidor está vivo y escuchando. **`UR`** (*upstream remote reset*) es un reset explícito del upstream a nivel de stream; también posible según versión/mensaje, pero el síntoma clásico documentado del mismatch STRICT↔plaintext es `UC` con `connection_termination`.
4. Sin sidecar, **no hay Envoy cliente que traduzca el fallo a un `503` HTTP**. El `curl` habla TCP/HTTP plano directo contra el sidecar del servidor, que exige mTLS y **corta el socket TCP** durante el handshake; `curl` ve eso como `Connection reset by peer` y sale con `exit 56`. Con sidecar (paso 4), el fallo ocurre *entre* dos Envoys y el Envoy cliente lo materializa como una respuesta HTTP `503 UC` sintética hacia la app local.

### Bloque 6 — `RESPONSE_FLAGS`

1. Ante `503 NR`: (a) ¿existe una ruta para ese host/puerto? → `istioctl proxy-config routes <pod> --name <port>` y verificá que el host matchee un `VirtualService`; (b) ¿el puerto de la `Service` está bien nombrado (protocolo)? → `istioctl analyze` para el `IST0118`; (c) ¿el `Gateway`/`Sidecar` expone ese listener? → `istioctl proxy-config listeners <pod>`. `NR` casi siempre es "falta config de routing o el host/puerto no matchea".
2. **`UO`** (*upstream overflow*) = te limitó el **circuit breaker** del `connectionPool` del `DestinationRule` (superaste `maxConnections`/`http1MaxPendingRequests`). **`URX`** = se **agotaron los `retries`** definidos en el `VirtualService` (o el límite de intentos de conexión). Uno es control de saturación (`DestinationRule.connectionPool`), el otro es política de reintentos (`VirtualService.retries`).
3. **`UF`** es de la aplicación/puerto porque significa que Envoy **no pudo abrir la conexión TCP** al upstream: el proceso no escucha, el puerto es incorrecto, o el pod está caído — nada de eso es de la malla. **`UC`** es de la malla porque la conexión **sí se abrió** y fue **terminada** después: en Istio el disparador típico es el rechazo de mTLS del sidecar servidor (política de seguridad), es decir, un problema de configuración de la malla y no de la app.

</details>