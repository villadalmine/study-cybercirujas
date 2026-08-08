# Ejercicios guiados — ICA Tema 3.1: Configuración del tráfico de Ingress y Egress

Estos laboratorios te llevan por los cuatro pilares del control de tráfico en el borde en Istio: exponer un servicio de la malla a través del **ingress gateway**, terminar **TLS** en el borde, restringir y admitir tráfico de **egress** con `ServiceEntry`, y canalizar el tráfico saliente a través de un **egress gateway** dedicado con originación de TLS. Cada bloque termina con preguntas de comprensión; las respuestas consolidadas están en la sección desplegable al final.

> **Referencias de fuentes**
> - Control de Ingress — https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
> - Ingress seguro (TLS) — https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
> - Control de Egress (`ServiceEntry`, `outboundTrafficPolicy`) — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
> - Egress gateway con originación de TLS — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
> - Referencia de API de `Gateway` — https://istio.io/latest/docs/reference/config/networking/gateway/
> - Referencia de API de `ServiceEntry` — https://istio.io/latest/docs/reference/config/networking/service-entry/
> - Referencia de API de `Sidecar` — https://istio.io/latest/docs/reference/config/networking/sidecar/

---

## Prerrequisitos

```bash
# A cluster with Istio installed (demo profile is fine for these labs).
istioctl version

# Enable automatic sidecar injection in the default namespace.
kubectl label namespace default istio-injection=enabled --overwrite

# Deploy the standard sample workloads (shipped with the Istio release).
kubectl apply -f samples/httpbin/httpbin.yaml
kubectl apply -f samples/sleep/sleep.yaml
kubectl get pods
```

Esperado (la columna READY `2/2` demuestra que el sidecar se inyectó junto a cada contenedor de aplicación):

```
NAME                       READY   STATUS    RESTARTS   AGE
httpbin-7c9f5c6b6d-abcde   2/2     Running   0          20s
sleep-6d6b49d8b8-fghij     2/2     Running   0          18s
```

```bash
# Capture the sleep pod name; we drive egress tests from it.
export SOURCE_POD=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
```

---

## Ejercicio 1 — Exponer un servicio HTTP a través del ingress gateway de Istio

**Objetivo:** publicar `httpbin` en el host virtual `httpbin.example.com` en el ingress gateway de la malla.

1. Confirmá que el ingress gateway está corriendo y anotá el tipo de su Service:

    ```bash
    kubectl get svc istio-ingressgateway -n istio-system
    ```

    ```
    NAME                   TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                        AGE
    istio-ingressgateway   LoadBalancer   10.96.120.14   <pending>     15021/TCP,80:31380/TCP,443:31390/TCP   5m
    ```

2. Creá el **`Gateway`** — esto configura el *listener* en el proxy de gateway compartido pero **no** enruta nada todavía:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: httpbin-gateway
      namespace: default
    spec:
      selector:
        istio: ingressgateway     # binds to the pod labeled istio=ingressgateway
      servers:
      - port:
          number: 80
          name: http
          protocol: HTTP
        hosts:
        - "httpbin.example.com"
    ```

    ```bash
    kubectl apply -f httpbin-gateway.yaml
    ```

3. Creá el **`VirtualService`** y adjuntalo al Gateway mediante el campo `gateways` — esto es lo que realmente enruta host + path al backend:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: httpbin
      namespace: default
    spec:
      hosts:
      - "httpbin.example.com"
      gateways:
      - httpbin-gateway            # same namespace; else use ns/name
      http:
      - match:
        - uri:
            prefix: /status
        - uri:
            prefix: /headers
        route:
        - destination:
            host: httpbin           # short name resolves to httpbin.default.svc.cluster.local
            port:
              number: 8000
    ```

    ```bash
    kubectl apply -f httpbin-vs.yaml
    ```

4. Resolvé el host y el puerto del ingress (se muestra la ruta de LoadBalancer; recurrí a NodePort si `EXTERNAL-IP` queda en `<pending>`):

    ```bash
    export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

    # NodePort fallback:
    # export INGRESS_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    # export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    ```

5. Enviá una petición. Inyectamos el encabezado `Host` para que el gateway coincida con nuestro host virtual sin DNS real:

    ```bash
    curl -sS -I -H "Host: httpbin.example.com" \
      "http://$INGRESS_HOST:$INGRESS_PORT/status/200"
    ```

    Esperado:

    ```
    HTTP/1.1 200 OK
    server: istio-envoy
    date: ...
    content-length: 0
    ```

6. Confirmá que una **ruta no configurada no se enruta** (demuestra que el match del `VirtualService`, no el Gateway, define la tabla de enrutamiento):

    ```bash
    curl -sS -o /dev/null -w "%{http_code}\n" -H "Host: httpbin.example.com" \
      "http://$INGRESS_HOST:$INGRESS_PORT/ip"
    ```

    Esperado: `404` (ningún prefijo de `http.match` cubre `/ip`).

**Preguntas de comprensión (1):**
1. ¿Qué selecciona realmente el `spec.selector` del Gateway, y qué pasa si ningún pod lleva esa etiqueta?
2. ¿Por qué aplicar solo el `Gateway` (sin el `VirtualService`) deja `httpbin.example.com` inalcanzable?
3. En el `VirtualService`, ¿cuál es el propósito de la lista `gateways:`, y qué significaría si le agregaras el valor reservado `mesh`?
4. La petición a `/ip` devolvió `404` mientras que `/status/200` devolvió `200`. ¿Qué recurso decide esa diferencia?

---

## Ejercicio 2 — Terminar TLS en el ingress gateway (modo SIMPLE)

**Objetivo:** servir `https://httpbin.example.com` con un certificado de servidor entregado al gateway vía SDS.

1. Creá una CA raíz y un certificado/clave de servidor para el host virtual:

    ```bash
    # Root CA
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
      -subj '/O=example Inc./CN=example.com' -keyout example.com.key -out example.com.crt

    # Server cert signed by that CA
    openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
      -keyout httpbin.example.com.key -subj "/CN=httpbin.example.com/O=httpbin org"
    openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
      -set_serial 0 -in httpbin.example.com.csr -out httpbin.example.com.crt
    ```

2. Guardá el certificado como un secret **`kubernetes.io/tls`** **en el namespace donde corre el pod del ingress gateway** (`istio-system`), porque ese proxy es el que debe cargarlo:

    ```bash
    kubectl create -n istio-system secret tls httpbin-credential \
      --key=httpbin.example.com.key \
      --cert=httpbin.example.com.crt
    ```

3. Actualizá el Gateway para agregar un servidor HTTPS que referencia el secret por `credentialName` (quitá el sufijo `.crt/.key` — Istio los agrega):

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: httpbin-gateway
      namespace: default
    spec:
      selector:
        istio: ingressgateway
      servers:
      - port:
          number: 443
          name: https
          protocol: HTTPS
        tls:
          mode: SIMPLE            # one-way TLS, gateway presents a server cert
          credentialName: httpbin-credential
        hosts:
        - "httpbin.example.com"
    ```

    ```bash
    kubectl apply -f httpbin-gateway-tls.yaml
    ```

4. Resolvé el puerto seguro y llamá al endpoint, fijando nuestra CA:

    ```bash
    export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

    curl -sS -v -HHost:httpbin.example.com \
      --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
      --cacert example.com.crt \
      "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/200"
    ```

    Esperado (el handshake tiene éxito y el certificado presentado encadena con nuestra CA):

    ```
    * Server certificate:
    *  subject: CN=httpbin.example.com; O=httpbin org
    *  SSL certificate verify ok.
    ...
    < HTTP/2 200
    ```

5. Verificá que el certificado llegó al proxy **sin reiniciar el gateway** — istiod lo envió vía SDS:

    ```bash
    istioctl proxy-config secret deploy/istio-ingressgateway.istio-system | grep httpbin-credential
    ```

    Esperado: una fila para `kubernetes://httpbin-credential` con un estado válido (no expirado).

**Preguntas de comprensión (2):**
1. ¿En qué namespace debe vivir el secret `httpbin-credential`, y por qué ponerlo en `default` es un error común que produce un `connection reset`?
2. Compará los valores de `tls.mode` `SIMPLE`, `MUTUAL` y `PASSTHROUGH`. ¿Cuál hace que el ingress gateway *no* descifre el tráfico en absoluto?
3. Rotaste el secret (`kubectl create secret ... --dry-run | kubectl apply`). ¿Necesitás reiniciar o volver a desplegar el ingress gateway para que el nuevo certificado tenga efecto? Explicá el mecanismo.
4. ¿Por qué el comando `curl` usa `--resolve` y `--cacert` en lugar de depender del DNS público y del almacén de confianza del sistema?

---

## Ejercicio 3 — Restringir y admitir tráfico de egress (`outboundTrafficPolicy` + `ServiceEntry`)

**Objetivo:** cambiar la malla de «permitir cualquier destino externo» a «solo registro», observar el bloqueo, y luego admitir un host externo con un `ServiceEntry`.

1. Inspeccioná la política de salida actual:

    ```bash
    kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | grep -A2 outboundTrafficPolicy
    ```

    En el perfil demo esto es `ALLOW_ANY` — los sidecars reenvían los destinos desconocidos a un `PassthroughCluster`.

2. Confirmá que el egress sin restricciones funciona hoy:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Esperado: `200`.

3. Ajustá la malla a **`REGISTRY_ONLY`** para que solo se puedan alcanzar los hosts presentes en el registro de servicios de Istio:

    ```bash
    istioctl install --set profile=demo \
      --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
    ```

4. Repetí la llamada externa — ahora cae en un agujero negro (black-hole):

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Esperado: `502` (el sidecar enrutó a `BlackHoleCluster`).

5. Admití exactamente ese host con un **`ServiceEntry`**, que inserta `httpbin.org` en el registro:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: ServiceEntry
    metadata:
      name: httpbin-ext
      namespace: default
    spec:
      hosts:
      - httpbin.org
      ports:
      - number: 80
        name: http
        protocol: HTTP
      - number: 443
        name: https
        protocol: HTTPS
      resolution: DNS          # Envoy resolves the host via DNS at request time
      location: MESH_EXTERNAL   # not part of the mesh; no mTLS expected
    ```

    ```bash
    kubectl apply -f httpbin-se.yaml
    ```

6. Volvé a probar — la llamada ahora tiene éxito a través de un cluster real (no black-hole):

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Esperado: `200`.

**Preguntas de comprensión (3):**
1. En una oración cada uno, contrastá `ALLOW_ANY` y `REGISTRY_ONLY`. ¿Cuál es la postura más segura y por qué?
2. En el paso 4 la llamada devolvió `502`, no un error de conexión TCP. ¿Qué cluster de Envoy produjo esa respuesta, y en qué se diferencia del `PassthroughCluster`?
3. El `ServiceEntry` establece `resolution: DNS`. ¿Qué significaría `resolution: NONE` en su lugar, y cuándo necesitarías `resolution: STATIC` con `endpoints` explícitos?
4. ¿`location: MESH_EXTERNAL` cambia si el sidecar intenta mTLS hacia el destino? Contrastá con `MESH_INTERNAL`.

---

## Ejercicio 4 — Enrutar el egress a través de un egress gateway dedicado con originación de TLS

**Objetivo:** forzar el tráfico saliente hacia `edition.cnn.com` a través del `istio-egressgateway`, y hacer que Istio *origine* TLS para que la aplicación pueda hablar HTTP plano internamente. Este es el patrón para un punto de salida de la malla controlado y auditable.

Ruta del tráfico: `sleep (HTTP :80)` → sidecar → **egress gateway** (mTLS dentro de la malla) → **TLS originado** → `edition.cnn.com:443`.

1. Definí el servicio externo en ambos puertos:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: ServiceEntry
    metadata:
      name: cnn
      namespace: default
    spec:
      hosts:
      - edition.cnn.com
      ports:
      - number: 80
        name: http-port
        protocol: HTTP
      - number: 443
        name: https-port
        protocol: HTTPS
      resolution: DNS
    ```

2. Creá el **`Gateway` de egress** escuchando en el puerto 80 pero con protocolo HTTPS + `ISTIO_MUTUAL` — el salto sidecar↔egress-gateway está asegurado por mTLS de la malla:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: istio-egressgateway
      namespace: default
    spec:
      selector:
        istio: egressgateway
      servers:
      - port:
          number: 80
          name: https-port-for-tls-origination
          protocol: HTTPS
        hosts:
        - edition.cnn.com
        tls:
          mode: ISTIO_MUTUAL
    ```

3. Creá un **`DestinationRule`** que describe el subset del egress gateway al que apuntarán los sidecars, con `ISTIO_MUTUAL` y el SNI correcto:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: DestinationRule
    metadata:
      name: egressgateway-for-cnn
      namespace: default
    spec:
      host: istio-egressgateway.istio-system.svc.cluster.local
      subsets:
      - name: cnn
        trafficPolicy:
          loadBalancer:
            simple: ROUND_ROBIN
          portLevelSettings:
          - port:
              number: 80
            tls:
              mode: ISTIO_MUTUAL
              sni: edition.cnn.com
    ```

4. Conectá los dos saltos con un único **`VirtualService`** vinculado *tanto* a `mesh` como al egress gateway:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: direct-cnn-through-egress-gateway
      namespace: default
    spec:
      hosts:
      - edition.cnn.com
      gateways:
      - istio-egressgateway
      - mesh                     # reserved keyword = every sidecar in the mesh
      http:
      - match:                   # HOP 1: sidecar → egress gateway
        - gateways:
          - mesh
          port: 80
        route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: cnn
            port:
              number: 80
          weight: 100
      - match:                   # HOP 2: egress gateway → external host
        - gateways:
          - istio-egressgateway
          port: 80
        route:
        - destination:
            host: edition.cnn.com
            port:
              number: 443        # target the TLS port
          weight: 100
    ```

5. Agregá el **`DestinationRule` que origina TLS** en el tramo externo (HTTP plano de entrada, HTTPS de salida):

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: DestinationRule
    metadata:
      name: originate-tls-for-edition-cnn-com
      namespace: default
    spec:
      host: edition.cnn.com
      trafficPolicy:
        portLevelSettings:
        - port:
            number: 443
          tls:
            mode: SIMPLE          # Istio performs the TLS handshake to CNN
    ```

    ```bash
    kubectl apply -f cnn-se.yaml -f egress-gw.yaml -f egress-dr.yaml -f egress-vs.yaml -f originate-tls-dr.yaml
    ```

6. Enviá **HTTP plano** desde la app y observá una respuesta exitosa respaldada por HTTPS:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sSL -o /dev/null -w "%{http_code}\n" \
      http://edition.cnn.com/politics
    ```

    Esperado: `200`.

7. Demostrá que el tráfico realmente transitó por el egress gateway (no una salida directa del sidecar):

    ```bash
    kubectl logs -l istio=egressgateway -n istio-system -c istio-proxy | tail -1
    ```

    Esperado: una línea de access-log que referencia `edition.cnn.com` y el cluster saliente `outbound|443||edition.cnn.com`.

**Preguntas de comprensión (4):**
1. La aplicación emite una petición `http://` en el puerto 80, sin embargo se llega a CNN por TLS en el 443. ¿Qué recurso realiza la originación de TLS, y en qué salto?
2. ¿Por qué el listener del egress gateway se declara como `protocol: HTTPS` con `mode: ISTIO_MUTUAL` aunque la app le habla en HTTP plano?
3. El `VirtualService` lista `mesh` e `istio-egressgateway` bajo `gateways`, y cada regla `http` coincide con un `gateways`/`port` específico. ¿Qué se rompe si omitís los selectores `match.gateways` y dejás que ambas reglas coincidan en todos lados?
4. Dá dos razones operativas por las que una organización fuerza el egress a través de un gateway en lugar de dejar que los sidecars salgan directamente.

---

## Ejercicio 5 — Diagnosticar la configuración del borde con `istioctl proxy-config`

**Objetivo:** leer la configuración de Envoy generada para confirmar tu intención, y reconocer la firma de black-hole/passthrough.

1. Inspeccioná los listeners del ingress gateway y la ruta HTTPS creada en el Ejercicio 2:

    ```bash
    istioctl proxy-config listeners deploy/istio-ingressgateway.istio-system
    istioctl proxy-config routes  deploy/istio-ingressgateway.istio-system \
      --name https.443.https.httpbin-gateway.default -o json | head -40
    ```

    Deberías ver un listener `0.0.0.0:8443` y una ruta cuyos `domains` incluyen `httpbin.example.com`.

2. Desde el sidecar de la app, confirmá que el `ServiceEntry` del Ejercicio 3 produjo un cluster real:

    ```bash
    istioctl proxy-config clusters "$SOURCE_POD" --fqdn httpbin.org
    ```

    Esperado: un cluster `outbound|80||httpbin.org` / `outbound|443||httpbin.org` de tipo `STRICT_DNS`.

3. Buscá los clusters sintéticos delatores:

    ```bash
    istioctl proxy-config clusters "$SOURCE_POD" | grep -E 'BlackHole|Passthrough'
    ```

    Bajo `REGISTRY_ONLY` verás `BlackHoleCluster`; bajo `ALLOW_ANY` verás `PassthroughCluster`.

4. Obtené un resumen legible para humanos de todo lo que afecta al pod, incluyendo qué `ServiceEntry`/`VirtualService` aplican:

    ```bash
    istioctl x describe pod "$SOURCE_POD"
    ```

**Preguntas de comprensión (5):**
1. Usando `proxy-config`, ¿qué subcomando y filtro demuestra que un host específico de `ServiceEntry` se convirtió en un cluster enrutable en un proxy dado?
2. Ves `BlackHoleCluster` en el volcado de clusters de un sidecar y las peticiones a un host externo devuelven `502`. ¿Qué única configuración a nivel de malla lo explica con mayor probabilidad, y cuál es la solución que *no* afloja toda la malla?
3. ¿Cuál es la diferencia práctica en el síntoma entre caer en `BlackHoleCluster` (HTTP `502`) y `PassthroughCluster` cuando el destino es genuinamente inalcanzable?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
1. `spec.selector` es un selector de etiquetas que se compara contra los **pods** de los proxies de gateway (por ejemplo, `istio=ingressgateway` en el deployment `istio-ingressgateway`). Si ningún pod lleva la etiqueta, la configuración del `Gateway` se genera pero no queda adjunta a nada, así que el listener nunca se materializa y el host queda inalcanzable.
2. Un `Gateway` solo abre un **listener** (puerto + protocolo + hosts permitidos) en el proxy. No lleva ninguna tabla de enrutamiento. Sin un `VirtualService` vinculado a él, el proxy acepta la conexión para `httpbin.example.com` pero no tiene ninguna `route` que le indique a qué backend reenviar, así que devuelve `404` (ningún virtual host/ruta coincidente) — efectivamente inalcanzable.
3. `gateways:` vincula las rutas del `VirtualService` a gateways específicos por nombre (`httpbin-gateway`, o `namespace/name` entre namespaces). Agregar el valor reservado **`mesh`** aplicaría además las mismas reglas de enrutamiento al tráfico *originado por sidecars* (este-oeste) dentro de la malla, no solo al tráfico norte-sur que entra a través del gateway.
4. El **`VirtualService`**. Su `http.match` solo cubre los prefijos `/status` y `/headers`; `/ip` no coincide con nada y produce `404`. El `Gateway` simplemente admitió el host en el puerto 80.

### Ejercicio 2
1. Debe vivir en **`istio-system`** — el namespace del **pod** del ingress gateway que lo carga, porque el cliente SDS de ese proxy obtiene la credencial. Un secret llamado `httpbin-credential` en `default` es invisible para el gateway, así que el listener TLS no tiene certificado y el handshake falla con un connection reset / error `Nc TLS`.
2. `SIMPLE` = TLS unidireccional: el gateway presenta un certificado de servidor y termina TLS (el cliente no se autentica). `MUTUAL` = mTLS: el gateway *también* valida el certificado del cliente contra una CA (agregá `caCertificates`/`credentialName` para la CA). `PASSTHROUGH` = el gateway **no** descifra; inspecciona solo el SNI de TLS y reenvía los bytes aún cifrados al backend (se usa con el match de rutas `tls` en el `VirtualService`).
3. **No se necesita reinicio.** istiod observa el `Secret`; ante un cambio envía el nuevo certificado al proxy del gateway vía **SDS** (Secret Discovery Service) como una actualización xDS. Envoy intercambia el certificado en caliente. Esto es precisamente por qué la rotación de certificados es una operación en vivo.
4. No hay ningún registro DNS público para `httpbin.example.com` y la CA es autofirmada. `--resolve` mapea el host virtual a la IP/puerto del ingress para que el SNI y el encabezado `Host` sean correctos, y `--cacert example.com.crt` confía en nuestra CA privada para que la verificación pase.

### Ejercicio 3
1. `ALLOW_ANY`: los sidecars reenvían el tráfico hacia destinos *desconocidos* a un `PassthroughCluster`, es decir, se puede alcanzar cualquier cosa. `REGISTRY_ONLY`: solo se permiten los hosts presentes en el registro de servicios de Istio (servicios del cluster + hosts de `ServiceEntry`); todo lo demás cae en un agujero negro. `REGISTRY_ONLY` es la postura más segura porque es de denegación por defecto — el acceso externo debe declararse explícitamente.
2. El **`BlackHoleCluster`** produjo el `502`. Es un cluster sintético sin endpoints al que Istio enruta el tráfico no permitido, así que la petición se *rechaza en L7 con un `502`* en lugar de salir del pod. El `PassthroughCluster` es lo opuesto: un cluster `ORIGINAL_DST` que reenvía la conexión a cualquier dirección que el cliente haya solicitado, permitiendo el tráfico.
3. `resolution: DNS` hace que Envoy resuelva el nombre de host por sí mismo y balancee la carga entre las IPs resueltas. `resolution: NONE` significa que Envoy **no** realiza ninguna resolución y se conecta a la IP de destino original que usó el cliente (estilo passthrough, para tráfico opaco/por IP). `resolution: STATIC` se requiere cuando enumerás IPs de backend fijas en `spec.endpoints` (por ejemplo, una flota de VMs heredada) en lugar de depender del DNS.
4. `location: MESH_EXTERNAL` le indica a Istio que el destino está fuera de la malla, así que el sidecar **no** intenta mTLS de Istio y lo trata como un endpoint externo plano (el TLS, si lo hay, es de la app o se origina vía un `DestinationRule`). `MESH_INTERNAL` marca el host como parte de la malla, haciéndolo elegible para mTLS e identidad de malla — apropiado para servicios que corren en VMs unidas a la malla.

### Ejercicio 4
1. El **`DestinationRule` `originate-tls-for-edition-cnn-com`** realiza la originación de TLS, en el **segundo salto** (egress gateway → `edition.cnn.com:443`). Su `portLevelSettings[443].tls.mode: SIMPLE` le indica a Envoy que abra una conexión TLS hacia CNN. La app y el salto sidecar-a-gateway permanecen en texto plano en lo que respecta a la app (el salto del gateway está envuelto en mTLS de la malla).
2. `ISTIO_MUTUAL` asegura el salto dentro de la malla entre el sidecar del cliente y el egress gateway con el mTLS automático de Istio (identidades/certificados de la malla). El listener es `HTTPS` porque ese mTLS *es* TLS; la app sigue hablando HTTP plano en el puerto 80, e Istio lo envuelve. Esto te da una ruta autenticada y cifrada hacia el nodo de salida sin que la app haga nada.
3. Las dos reglas `http` se desambiguan mediante `match.gateways` + `port`: la primera aplica solo al tráfico de `mesh`, la segunda solo al tráfico que llega *al* egress gateway. Si quitás los selectores, ambas reglas coinciden con el mismo tráfico; la primera (enviar-al-egress-gateway) también coincide en el gateway, creando un **bucle de enrutamiento / match ambiguo** donde el egress gateway sigue devolviéndose el tráfico a sí mismo en lugar de enviarlo hacia afuera a CNN.
4. Dos cualesquiera de: (a) un **único punto de salida auditado/monitoreado** para cumplimiento y registro de accesos; (b) aplicar **política de egress / listas de permitidos** y originación de TLS de forma centralizada en lugar de por app; (c) permitir que los nodos que corren sidecars permanezcan en una red privada mientras que solo los nodos del gateway necesitan egress público (listas de permitidos de firewall/NAT por las IPs del gateway); (d) descargar la originación de TLS y la gestión de certificados de las aplicaciones.

### Ejercicio 5
1. `istioctl proxy-config clusters <pod> --fqdn <host>` — si el host del `ServiceEntry` aparece como un cluster `outbound|<port>||<host>` (de tipo `STRICT_DNS`/`EDS`), se volvió enrutable en ese proxy. (`istioctl x describe pod` corrobora qué objetos de configuración aplican.)
2. La malla está configurada en **`outboundTrafficPolicy.mode: REGISTRY_ONLY`** y el host no está en el registro, así que cae en `BlackHoleCluster`. La solución acotada es agregar un `ServiceEntry` para ese host específico (opcionalmente acotado por namespace vía un recurso `Sidecar`) — esto admite solo el destino previsto y **no** afloja toda la malla de vuelta a `ALLOW_ANY`.
3. `BlackHoleCluster` es una **decisión de política**: el destino estaba *no permitido*, así que Envoy corta el circuito con un `502` limpio sin importar si el host está activo. `PassthroughCluster` significa que al tráfico *se le permitió salir*; si el destino es genuinamente inalcanzable ves en cambio fallos a nivel de conexión (timeouts, connection refused/reset, banderas upstream `503 UF`/`UO`) porque el paquete efectivamente salió y falló en la red — no un `502` de política.

</details>