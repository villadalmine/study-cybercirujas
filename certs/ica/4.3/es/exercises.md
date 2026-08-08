# ICA — Topic 4.3: Securing Edge Traffic with TLS — Ejercicios Guiados

> **Alcance.** Estos labs cubren la terminación y el reenvío de TLS en el ingress gateway de Istio: terminación `SIMPLE`, redirección HTTP→HTTPS, autenticación `MUTUAL` (certificado de cliente), `PASSTHROUGH` con enrutamiento por SNI, endurecimiento de TLS y diagnóstico basado en SDS. Cada paso es lo bastante idempotente como para volver a ejecutarse; borrá los objetos que crees al final de cada ejercicio si querés partir de cero.
>
> **Entorno asumido.** Un clúster con Istio instalado (`istioctl install` / perfil demo), el Service `istio-ingressgateway` presente en `istio-system`, y `kubectl`, `istioctl`, `openssl` y `curl` en tu path. Donde no haya una IP de `LoadBalancer` disponible (kind/minikube), los labs muestran la alternativa con `NodePort`/port-forward.
>
> **Referencias oficiales**
> - Secure Ingress Gateways — https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
> - Ingress Gateway without TLS Termination (SNI passthrough) — https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/
> - `Gateway` / `ServerTLSSettings` reference — https://istio.io/latest/docs/reference/config/networking/gateway/
> - TLS configuration operations guide — https://istio.io/latest/docs/ops/configuration/traffic-management/tls-configuration/
> - ICA curriculum — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

---

## Exercise 0 — Lab bootstrap: carga de trabajo de ejemplo y coordenadas del ingress

Necesitás un backend al cual enrutar y la dirección del ingress gateway. Se usa `httpbin` en todo el recorrido porque su endpoint `/status/<code>` hace que el éxito/fallo sea inequívoco.

1. Creá un namespace con inyección de sidecar y desplegá `httpbin`:

   ```bash
   kubectl create namespace edge-tls
   kubectl label namespace edge-tls istio-injection=enabled
   kubectl apply -n edge-tls \
     -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/httpbin/httpbin.yaml
   ```

2. Confirmá que el pod está corriendo con **dos** contenedores (app + `istio-proxy`):

   ```bash
   kubectl get pod -n edge-tls -l app=httpbin
   ```
   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7c8b9f4d5b-mxz2k   2/2     Running   0          25s
   ```

3. Capturá el host del ingress y los dos puertos que vas a usar (HTTP `80`, HTTPS `443`):

   ```bash
   export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
   export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
   echo "HOST=$INGRESS_HOST  HTTP=$INGRESS_PORT  HTTPS=$SECURE_INGRESS_PORT"
   ```
   ```
   HOST=203.0.113.10  HTTP=80  HTTPS=443
   ```

4. **Alternativa si `INGRESS_HOST` queda vacío** (sin load balancer externo). Usá los NodePorts y una IP de nodo en su lugar:

   ```bash
   export INGRESS_HOST=$(kubectl get nodes \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
   export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   ```

**Comprehension check**

- Q0.1 — ¿Por qué `kubectl get pod` muestra `2/2` y no `1/1`, y cuál contenedor realiza efectivamente el trabajo de TLS para el tráfico de edge — el que está en `edge-tls` o el que está en `istio-system`?
- Q0.2 — El Service `httpbin` escucha en el puerto HTTP plano `8000`. Dado eso, ¿en qué salto del camino `client → ingress → httpbin` se termina realmente el TLS que configurás en los ejercicios siguientes?

---

## Exercise 1 — Terminación de TLS en el edge (modo `SIMPLE`)

Aquí el gateway termina TLS: el cliente habla HTTPS con el gateway, y el gateway habla texto plano con `httpbin`.

1. Creá una CA raíz autofirmada y luego un certificado de servidor para `httpbin.example.com` firmado por ella:

   ```bash
   mkdir -p certs && cd certs

   # Root CA
   openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
     -subj '/O=example Inc./CN=example.com' \
     -keyout example.com.key -out example.com.crt

   # Server key + CSR
   openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
     -keyout httpbin.example.com.key \
     -subj "/CN=httpbin.example.com/O=httpbin organization"

   # Sign the server cert with the CA
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 1 \
     -in httpbin.example.com.csr -out httpbin.example.com.crt
   cd ..
   ```

2. Cargá el certificado/clave de servidor en un **Secret `tls` de Kubernetes en el namespace `istio-system`** (el namespace donde corre la carga de trabajo del gateway — *no* `edge-tls`):

   ```bash
   kubectl create -n istio-system secret tls httpbin-credential \
     --key=certs/httpbin.example.com.key \
     --cert=certs/httpbin.example.com.crt
   ```

3. Declará un `Gateway` que sirva HTTPS en `443` en modo `SIMPLE`, referenciando el secret por nombre vía `credentialName`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: httpbin-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway            # matches the istio-ingressgateway pod labels
     servers:
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential   # secret name in the gateway's namespace
       hosts:
       - httpbin.example.com
   ```

4. Vinculá un `VirtualService` a ese gateway para que el host efectivamente se enrute a `httpbin`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: edge-tls
   spec:
     hosts:
     - httpbin.example.com
     gateways:
     - httpbin-gateway
     http:
     - match:
       - uri:
           prefix: /status
       route:
       - destination:
           host: httpbin.edge-tls.svc.cluster.local
           port:
             number: 8000
   ```

5. Aplicá ambos manifiestos (asumí que los guardaste como `gw-simple.yaml` y `vs-httpbin.yaml`):

   ```bash
   kubectl apply -f gw-simple.yaml -f vs-httpbin.yaml
   ```

6. Enviá una petición HTTPS. `--resolve` fuerza el SNI/Host `httpbin.example.com` hacia tu IP de ingress, y `--cacert` confía en tu CA:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * Server certificate:
   *  subject: CN=httpbin.example.com; O=httpbin organization
   *  issuer: O=example Inc.; CN=example.com
   *  SSL certificate verify ok.
   > GET /status/418 HTTP/2
   < HTTP/2 418
   ...
   -=[ teapot ]=-
   ```

**Comprehension check**

- Q1.1 — Creaste el secret en `istio-system`, pero el objeto `Gateway` vive en `edge-tls`. ¿Por qué `credentialName` se resuelve contra `istio-system` y no `edge-tls`? ¿Qué único síntoma aparece en el cliente si hubieras creado el secret en `edge-tls` por error?
- Q1.2 — El `selector` del `Gateway` es `istio: ingressgateway`. ¿Qué hace ese selector realmente, y qué le pasa a la config del `Gateway` si ningún pod lleva esa etiqueta?
- Q1.3 — Tras editar el Secret con un certificado renovado, ¿necesitás reiniciar o redesplegar el pod `istio-ingressgateway` para que se sirva el nuevo cert? Nombrá el mecanismo que hace que tu respuesta sea verdadera.
- Q1.4 — En `curl`, ¿cuál es la diferencia de propósito entre `--resolve` y `--cacert` aquí? ¿Cuál dejarías de usar si el SAN del cert ya coincidiera con un nombre DNS real que controlás?

---

## Exercise 2 — Forzar HTTPS: redirección HTTP→HTTPS

Servir `443` no alcanza; el puerto `80` no debería servir texto plano en silencio.

1. Agregá un bloque de servidor HTTP en el puerto `80` con `httpsRedirect: true`. Editá el mismo `Gateway` para que ahora tenga **dos** servidores:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: httpbin-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway
     servers:
     - port:
         number: 80
         name: http
         protocol: HTTP
       tls:
         httpsRedirect: true          # 301 to https:// for this host
       hosts:
       - httpbin.example.com
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential
       hosts:
       - httpbin.example.com
   ```

2. Aplicá y probá el puerto de texto plano. Deberías recibir una redirección, no contenido:

   ```bash
   kubectl apply -f gw-simple.yaml
   curl -sI --resolve "httpbin.example.com:$INGRESS_PORT:$INGRESS_HOST" \
     "http://httpbin.example.com:$INGRESS_PORT/status/418"
   ```
   ```
   HTTP/1.1 301 Moved Permanently
   location: https://httpbin.example.com/status/418
   server: istio-envoy
   ```

**Comprehension check**

- Q2.1 — `httpsRedirect: true` se ubica bajo `tls:` aunque el protocolo del bloque de servidor sea `HTTP`. ¿Dónde ocurre la redirección — en el gateway (Envoy) o en el backend — y qué código de estado y encabezado lo prueban?
- Q2.2 — El encabezado `Location` apunta a `https://httpbin.example.com/...` sin puerto. Si tu puerto HTTPS de ingress es un NodePort como `31390`, ¿por qué esta redirección puede romper un navegador real, y qué solución de producción elimina el problema?

---

## Exercise 3 — TLS mutuo en el edge (modo `MUTUAL`)

Ahora el gateway también autentica al **cliente**: solo pasan los llamadores que presentan un certificado firmado por una CA en la que confiás.

1. Creá una clave/cert de cliente firmada por la misma CA:

   ```bash
   cd certs
   openssl req -out client.example.com.csr -newkey rsa:2048 -nodes \
     -keyout client.example.com.key \
     -subj "/CN=client.example.com/O=client organization"
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 2 \
     -in client.example.com.csr -out client.example.com.crt
   cd ..
   ```

2. Recreá la credencial como un **Secret genérico que lleve el cert de la CA** bajo `ca.crt`, junto con el `tls.crt`/`tls.key` del servidor. Borrá el viejo primero:

   ```bash
   kubectl delete -n istio-system secret httpbin-credential
   kubectl create -n istio-system secret generic httpbin-credential \
     --from-file=tls.key=certs/httpbin.example.com.key \
     --from-file=tls.crt=certs/httpbin.example.com.crt \
     --from-file=ca.crt=certs/example.com.crt
   ```

3. Cambiá el `mode` del bloque de servidor HTTPS de `SIMPLE` a `MUTUAL`:

   ```yaml
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: MUTUAL
         credentialName: httpbin-credential
       hosts:
       - httpbin.example.com
   ```
   ```bash
   kubectl apply -f gw-simple.yaml
   ```

4. Comprobá que una petición **sin** certificado de cliente ahora se rechaza en el handshake:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * TLSv1.3 (OUT), TLS handshake, Client hello (1):
   * TLSv1.3 (IN), TLS alert, unknown (628):
   * OpenSSL/3.x: error:0A000418:SSL routines::tlsv1 alert unknown ca
   * Closing connection
   ```

5. Ahora presentá el cert/clave de cliente y tené éxito:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     --cert certs/client.example.com.crt \
     --key certs/client.example.com.key \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * TLSv1.3 (OUT), TLS handshake, Certificate (11):
   < HTTP/2 418
   -=[ teapot ]=-
   ```

**Comprehension check**

- Q3.1 — ¿Cuál clave del Secret (`tls.crt`, `tls.key` o `ca.crt`) es la que `MUTUAL` necesita y `SIMPLE` ignora, y para qué se usa durante el handshake?
- Q3.2 — La petición fallida del paso 4 aborta durante el handshake de TLS, antes de que se envíe ninguna línea de petición HTTP. ¿Por qué es esto arquitectónicamente significativo comparado con imponer la identidad del cliente en el código de la aplicación o en una `RequestAuthentication`?
- Q3.3 — Istio también soporta un Secret separado llamado `<credentialName>-cacert` como alternativa a incrustar `ca.crt`. ¿Cuándo preferirías el Secret `-cacert` separado sobre un único Secret combinado?
- Q3.4 — `MUTUAL` rechaza a los clientes que no tienen cert. ¿Qué modo de `ServerTLSSettings` te permitiría *solicitar* un certificado de cliente pero aun así admitir a los clientes que no presentan ninguno (por ejemplo, durante una migración)?

---

## Exercise 4 — TLS passthrough con enrutamiento por SNI (modo `PASSTHROUGH`)

A veces el backend debe terminar TLS él mismo (cifrado de extremo a extremo, o la app posee su propio cert). El gateway entonces enruta puramente según el SNI del ClientHello, sin descifrar.

1. Desplegá un NGINX que termine su **propio** TLS en `443`. Primero construí su config y cert en secrets:

   ```bash
   cd certs
   openssl req -out nginx.example.com.csr -newkey rsa:2048 -nodes \
     -keyout nginx.example.com.key \
     -subj "/CN=nginx.example.com/O=some organization"
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 3 \
     -in nginx.example.com.csr -out nginx.example.com.crt
   cd ..

   kubectl create -n edge-tls secret tls nginx-server-certs \
     --key certs/nginx.example.com.key \
     --cert certs/nginx.example.com.crt
   ```

2. Provéé una config de NGINX que sirva HTTPS, guardala como un ConfigMap, y desplegá NGINX montando ambos:

   ```bash
   cat > nginx.conf <<'EOF'
   events {}
   http {
     log_format main '$remote_addr - $remote_user [$time_local] $status "$request"';
     access_log /var/log/nginx/access.log main;
     server {
       listen 443 ssl;
       root /usr/share/nginx/html;
       index index.html;
       server_name nginx.example.com;
       ssl_certificate     /etc/nginx-server-certs/tls.crt;
       ssl_certificate_key /etc/nginx-server-certs/tls.key;
     }
   }
   EOF
   kubectl create -n edge-tls configmap nginx-configmap --from-file=nginx.conf=nginx.conf
   ```

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: my-nginx
     namespace: edge-tls
     labels: { run: my-nginx }
   spec:
     ports:
     - port: 443
       protocol: TCP
     selector: { run: my-nginx }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: my-nginx
     namespace: edge-tls
   spec:
     selector: { matchLabels: { run: my-nginx } }
     replicas: 1
     template:
       metadata: { labels: { run: my-nginx } }
       spec:
         containers:
         - name: my-nginx
           image: nginx
           ports: [ { containerPort: 443 } ]
           volumeMounts:
           - { name: nginx-config, mountPath: /etc/nginx, readOnly: true }
           - { name: nginx-server-certs, mountPath: /etc/nginx-server-certs, readOnly: true }
         volumes:
         - name: nginx-config
           configMap: { name: nginx-configmap }
         - name: nginx-server-certs
           secret: { secretName: nginx-server-certs }
   ```

3. Definí un `Gateway` cuyo servidor use `protocol: TLS` y `mode: PASSTHROUGH`. Notá que **no hay `credentialName`** — el gateway no tiene ningún cert:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: nginx-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway
     servers:
     - port:
         number: 443
         name: https
         protocol: TLS
       tls:
         mode: PASSTHROUGH
       hosts:
       - nginx.example.com
   ```

4. Enrutá con un bloque `tls` de `VirtualService` que haga match sobre `sniHosts` (no sobre rutas HTTP — el gateway no puede ver dentro del stream cifrado):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: nginx
     namespace: edge-tls
   spec:
     hosts:
     - nginx.example.com
     gateways:
     - nginx-gateway
     tls:
     - match:
       - port: 443
         sniHosts:
         - nginx.example.com
       route:
       - destination:
           host: my-nginx.edge-tls.svc.cluster.local
           port:
             number: 443
   ```

5. Aplicá y probá. El cert de la respuesta está firmado por tu CA y emitido para `nginx.example.com` — prueba de que el **backend**, no el gateway, terminó TLS:

   ```bash
   kubectl apply -f nginx.yaml -f gw-passthrough.yaml -f vs-nginx.yaml
   curl -v --resolve "nginx.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://nginx.example.com:$SECURE_INGRESS_PORT/"
   ```
   ```
   * Server certificate:
   *  subject: CN=nginx.example.com; O=some organization
   *  issuer: O=example Inc.; CN=example.com
   < HTTP/1.1 200 OK
   < server: nginx/1.27.0
   ```

**Comprehension check**

- Q4.1 — En `PASSTHROUGH`, ¿por qué el `VirtualService` enruta sobre `tls.match.sniHosts` en lugar de `http.match.uri`? ¿Cuál es lo *único* que el gateway puede ver para tomar una decisión de enrutamiento?
- Q4.2 — El bloque de servidor usa `protocol: TLS`, mientras que los ejercicios de `SIMPLE`/`MUTUAL` usaban `protocol: HTTPS`. Explicá la diferencia semántica entre `HTTPS` y `TLS` aquí.
- Q4.3 — Un cliente se conecta con SNI `other.example.com`, para el cual no existe ningún match de `sniHosts`. ¿Qué hace el gateway con esa conexión, y por qué *no* es un 404?
- Q4.4 — Con passthrough, ¿cuáles dos features de Istio quedan indisponibles para este tráfico que *sí* tendrías con la terminación `SIMPLE` (pensá en enrutamiento L7 y observabilidad)?

---

## Exercise 5 — Endurecer el listener de TLS

Los edges de producción fijan una versión mínima de protocolo y una lista de cifrados aprobada.

1. Agregá `minProtocolVersion` y una lista explícita de `cipherSuites` al bloque de servidor HTTPS `SIMPLE`/`MUTUAL` (revertí el `mode` a `SIMPLE` primero si lo dejaste en `MUTUAL`):

   ```yaml
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential
         minProtocolVersion: TLSV1_2
         maxProtocolVersion: TLSV1_3
         cipherSuites:
         - ECDHE-ECDSA-AES256-GCM-SHA384
         - ECDHE-RSA-AES256-GCM-SHA384
         - ECDHE-ECDSA-AES128-GCM-SHA256
         - ECDHE-RSA-AES128-GCM-SHA256
   ```
   ```bash
   kubectl apply -f gw-simple.yaml
   ```

2. Comprobá que un cliente TLS 1.1 es rechazado y un cliente TLS 1.2+ tiene éxito:

   ```bash
   # Forced down-level handshake — must fail
   curl -v --tlsv1.1 --tls-max 1.1 \
     --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/200"
   ```
   ```
   * TLSv1.1 (OUT), TLS handshake, Client hello (1):
   * OpenSSL/3.x: error: ... tlsv1 alert protocol version
   ```

**Comprehension check**

- Q5.1 — `cipherSuites` aquí usa nombres de cifrados de TLS 1.2, pero también permitiste `TLSV1_3`. ¿Gobierna `cipherSuites` la selección de cifrado de TLS 1.3? Explicá qué ocurre realmente en un handshake de TLS 1.3.
- Q5.2 — Además de los `ServerTLSSettings` por `Gateway`, nombrá el lugar a nivel de malla donde podrías imponer una versión mínima de TLS para *todos* los gateways a la vez, para que un equipo nuevo no pueda desplegar un listener más débil.

---

## Exercise 6 — Diagnosticar el TLS de edge con `istioctl` y SDS

Cuando el handshake falla, la pregunta es siempre: *¿el cert efectivamente llegó a Envoy?*

1. Encontrá el pod del ingress gateway e inspeccioná los secrets que Envoy recibió vía **SDS** (Secret Discovery Service):

   ```bash
   INGRESS_POD=$(kubectl -n istio-system get pod -l istio=ingressgateway \
     -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$INGRESS_POD" -n istio-system
   ```
   ```
   RESOURCE NAME                          TYPE           STATUS      VALID CERT     SERIAL NUMBER   NOT AFTER
   kubernetes://httpbin-credential        Cert Chain     ACTIVE      true           1               2027-08-08T...
   kubernetes://httpbin-credential-cacert Cert Chain     ACTIVE      true           -               2027-08-08T...
   default                                Cert Chain     ACTIVE      true           ...             ...
   ROOTCA                                 CA             ACTIVE      true           ...             ...
   ```

2. Confirmá que efectivamente existe un listener en `443` y está conectado a la credencial:

   ```bash
   istioctl proxy-config listener "$INGRESS_POD" -n istio-system --port 443 -o json \
     | grep -A2 -i 'sdsConfig\|serverNames\|filterChainMatch' | head -30
   ```

3. Si SDS muestra el secret como `WARMING` o ausente, observá los logs del gateway mientras vuelves a aplicar el Secret:

   ```bash
   kubectl logs -n istio-system "$INGRESS_POD" | grep -iE 'sds|secret|warming|failed'
   ```

4. Verificá lo que el gateway presenta en el cable, independientemente de Istio, con `openssl s_client`:

   ```bash
   openssl s_client -connect "$INGRESS_HOST:$SECURE_INGRESS_PORT" \
     -servername httpbin.example.com -CAfile certs/example.com.crt </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates
   ```
   ```
   subject=CN=httpbin.example.com, O=httpbin organization
   issuer=O=example Inc., CN=example.com
   notBefore=... notAfter=...
   ```

**Comprehension check**

- Q6.1 — `istioctl proxy-config secret` muestra una entrada `kubernetes://httpbin-credential` con `STATUS: ACTIVE`. ¿Qué prueba eso que un `kubectl get secret` en `istio-system` *no* prueba?
- Q6.2 — Actualizaste el Secret pero SDS sigue mostrando el número de serie viejo. Dá dos causas plausibles y el primer comando que ejecutarías para cada una.
- Q6.3 — En el paso 4 evitás deliberadamente las flags de `curl` conscientes de Istio y usás `openssl s_client -servername`. ¿Por qué pasar `-servername` es esencial para reproducir lo que hace el gateway, especialmente una vez que más de un host comparte el puerto `443`?

---

## Cleanup

```bash
kubectl delete namespace edge-tls
kubectl delete -n istio-system secret httpbin-credential nginx-server-certs --ignore-not-found
rm -rf certs nginx.conf gw-*.yaml vs-*.yaml nginx.yaml
```

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 0**

- **A0.1** — `2/2` significa que el pod corre el contenedor de la app `httpbin` más el sidecar `istio-proxy` (Envoy) inyectado, porque el namespace `edge-tls` lleva `istio-injection=enabled`. Pero el trabajo de TLS de edge en estos labs lo hace un Envoy *diferente*: el pod compartido `istio-ingressgateway` en `istio-system`. El sidecar de `edge-tls` maneja el tráfico este-oeste/de malla hacia `httpbin`, no el handshake de TLS norte-sur con el cliente externo.
- **A0.2** — Con terminación `SIMPLE`/`MUTUAL`, TLS se termina en el **ingress gateway** (`istio-system`). Del gateway a `httpbin:8000` el tráfico es HTTP en texto plano dentro de la malla (opcionalmente re-cifrado con mTLS de Istio entre los sidecars, pero ese es un mecanismo separado del cert de edge que configurás aquí). Con `PASSTHROUGH` el gateway no termina nada y TLS se termina en el pod backend.

**Exercise 1**

- **A1.1** — `credentialName` lo resuelve el `istio-agent` del ingress gateway, que obtiene el Secret de **su propio namespace** — el namespace donde corre la carga de trabajo `istio-ingressgateway` (`istio-system`), sin importar dónde viva el objeto `Gateway`. Si ponés el Secret en `edge-tls`, el gateway nunca obtiene un certificado de servidor, el listener de TLS queda en un estado de warming/sin-cert, y el cliente ve un reset de conexión / fallo de handshake (`curl` reporta un error de TLS, no un estado HTTP).
- **A1.2** — El `selector` hace match sobre las **etiquetas del pod** de la carga de trabajo del gateway (los pods del Deployment `istio-ingressgateway` llevan `istio: ingressgateway`). Istio programa la config del `Gateway` solo en los Envoys cuyos pods coinciden. Si ningún pod lleva la etiqueta, la config es aceptada por el API server pero nunca se programa en ningún proxy — nada escucha, y las peticiones fallan a nivel de red.
- **A1.3** — No hace falta reiniciar. El gateway usa **SDS (Secret Discovery Service)**: `istio-agent` observa el Secret de Kubernetes y transmite las actualizaciones del cert a Envoy dinámicamente sobre la API gRPC de SDS. Rotar el Secret hace un hot-swap del cert sin reinicio de pod y sin recarga de config.
- **A1.4** — `--resolve` sobrescribe DNS para que el SNI/Host `httpbin.example.com` mapee a tu IP:puerto de ingress (necesario porque el nombre no está en el DNS real). `--cacert` le dice a `curl` que confíe en tu CA autofirmada para que la verificación del cert de servidor pase. Si `httpbin.example.com` fuera un nombre DNS real apuntando al ingress, podrías dejar de usar `--resolve`; `--cacert` seguiría siendo requerido hasta que el cert sea emitido por una CA de confianza pública.

**Exercise 2**

- **A2.1** — La redirección la emite el **gateway (Envoy)** mismo; la petición nunca llega a `httpbin`. Prueba: `HTTP/1.1 301 Moved Permanently`, un encabezado `location:` apuntando a la URL `https://`, y `server: istio-envoy`. `httpsRedirect` es una propiedad de la configuración TLS del listener HTTP aunque el listener hable texto plano, porque gobierna cómo responde ese listener.
- **A2.2** — Envoy construye el destino de la redirección como `https://<host>/<path>` usando el puerto HTTPS *estándar* (443), descartando cualquier NodePort no estándar. Un navegador entonces intenta `https://httpbin.example.com/` en 443, que no es donde escucha el gateway, así que falla. La solución de producción es exponer el gateway en el `443` estándar (un LoadBalancer real o un LB externo/NodePort mapeando 443→ingress), para que la redirección aterrice en un puerto que esté escuchando.

**Exercise 3**

- **A3.1** — `ca.crt` (el bundle de la CA). `MUTUAL` lo usa para verificar el certificado de cliente que el llamador presenta durante el handshake. `SIMPLE` nunca pide un cert de cliente, así que `ca.crt` es irrelevante ahí; solo se usan `tls.crt`/`tls.key` (la identidad del servidor).
- **A3.2** — El rechazo ocurre **durante el handshake de TLS**, antes de que la petición HTTP sea parseada o siquiera recibida por completo. Un cliente no autorizado no puede enviar un cuerpo de petición, explotar un bug del parser L7, ni consumir recursos del backend — la conexión se cierra en la capa de transporte. Las verificaciones a nivel de aplicación o de `RequestAuthentication`/JWT corren *después* de que la petición es decodificada y admitida, una superficie de ataque estrictamente mayor.
- **A3.3** — Usá el Secret `<credentialName>-cacert` separado cuando el bundle de confianza de la CA sea gestionado por un equipo/cadencia de rotación distinta que el cert del servidor, o cuando quieras actualizar la lista de CAs de confianza sin tocar (ni arriesgar) la clave/cert del servidor. Combinarlos es más simple pero acopla sus ciclos de vida.
- **A3.4** — `OPTIONAL_MUTUAL`. Solicita un certificado de cliente y lo verifica si se presenta, pero aun así admite a los clientes que no envían ninguno — útil para incorporar clientes a mTLS de forma gradual.

**Exercise 4**

- **A4.1** — En passthrough el gateway **no** descifra el stream, así que no puede ver el método HTTP, la ruta ni los encabezados — el único texto en claro disponible es el **SNI (Server Name Indication)** en el ClientHello de TLS. El enrutamiento debe por lo tanto hacer match sobre `sniHosts`. Los matches a nivel HTTP (`uri`, `headers`) son imposibles.
- **A4.2** — `protocol: HTTPS` le dice a Istio que el gateway termina TLS y luego trata el tráfico interno como HTTP (habilitando enrutamiento/observabilidad L7). `protocol: TLS` (con `PASSTHROUGH`) le dice a Istio que trate la conexión como un stream TLS opaco a reenviar según el SNI, sin terminación y sin visibilidad L7.
- **A4.3** — Sin una ruta de `sniHosts` que coincida, no hay filter chain / ruta para ese SNI, así que Envoy **cierra/resetea la conexión** en la capa de TLS. No puede devolver un 404 porque un 404 es una respuesta HTTP, y el gateway nunca termina TLS para hablar HTTP — no hay ninguna petición descifrada que responder.
- **A4.4** — Se pierden las features L7: (1) el enrutamiento a nivel HTTP (match por path/header/method, reintentos, inyección de fallos, manipulación de encabezados), y (2) la telemetría/observabilidad L7 (métricas por petición, tracing, access logs con detalles HTTP). Solo obtenés datos L4 a nivel de conexión.

**Exercise 5**

- **A5.1** — No. El campo `cipherSuites` controla únicamente la selección de cifrado de **TLS 1.2 (y anteriores)**. TLS 1.3 usa su propio conjunto fijo de cipher suites AEAD negociados por el stack de TLS (BoringSSL/Envoy); la lista `cipherSuites` no los restringe. Si debés prohibir los cifrados de TLS 1.3, tendrías que limitar `maxProtocolVersion` a `TLSV1_2` — pero ese suele ser el trade-off equivocado.
- **A5.2** — El `MeshConfig` a nivel de malla (`meshConfig.meshMTLS.minProtocolVersion`, y defaults de TLS como `meshConfig.tlsDefaults`/`minProtocolVersion`) te deja fijar un piso aplicado a lo largo de los proxies, para que una config por `Gateway` no pueda caer silenciosamente por debajo del mínimo de la organización. (En la práctica esto se impone vía la instalación de Istio/`IstioOperator` `meshConfig`.)

**Exercise 6**

- **A6.1** — `kubectl get secret` prueba que el Secret *existe en el API server*. `istioctl proxy-config secret ... STATUS: ACTIVE` prueba que el cert efectivamente fue **entregado a Envoy sobre SDS y cargado** en el proxy en ejecución — es decir, el data path está armado. Un Secret puede existir y sin embargo nunca llegar a Envoy (namespace equivocado, nombres de clave equivocados, error de SDS), lo cual el segundo comando detecta y el primero no.
- **A6.2** — (1) SDS todavía no hizo push / está atascado en warming → ejecutá `kubectl logs -n istio-system "$INGRESS_POD" | grep -i sds` (o reiniciá el agent como último recurso). (2) Las claves del Secret están equivocadas (por ejemplo `cert`/`key` en lugar de `tls.crt`/`tls.key`, o falta `ca.crt` para `MUTUAL`) así que el material nuevo fue rechazado → ejecutá `kubectl get secret httpbin-credential -n istio-system -o yaml` y verificá los nombres de clave. Un serial obsoleto también puede significar que editaste un Secret/namespace *diferente* del que resuelve `credentialName`.
- **A6.3** — Cuando múltiples hosts comparten el puerto `443`, Envoy selecciona la filter chain / cert de servidor por **SNI**. Sin `-servername`, `openssl s_client` no envía SNI, así que podrías dar con una chain default/otra y ver el cert equivocado (o un fallo de handshake) — no lo que obtendría un cliente real pidiendo `httpbin.example.com`. `-servername httpbin.example.com` reproduce la selección exacta basada en SNI que realiza el gateway.

</details>