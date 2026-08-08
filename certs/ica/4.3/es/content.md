# 4.3 Asegurando el Tráfico de Borde con TLS

## 1. El problema arquitectónico: el borde es la frontera de confianza

Dentro de una malla Istio bien configurada, cada salto entre workloads ya está cifrado y mutuamente autenticado por los proxies sidecar (PeerAuthentication `STRICT` + mTLS emitido por Istio). Pero esa garantía **se detiene en la frontera de la malla**. Un cliente en la internet pública no tiene un sidecar de Istio, no posee una identidad SPIFFE ni habla el TLS mutuo de Istio. El primer paquete que envía un navegador o una API de un socio llega al **ingress gateway** — un Envoy autónomo que corre *sin* un contenedor de aplicación al lado — y todo lo anterior a ese Envoy es red no confiable.

Asegurar el tráfico de borde con TLS se trata, por lo tanto, de tres decisiones distintas, y confundirlas es el incidente de producción más común en esta área:

1. **¿Dónde termina TLS?** En el gateway (terminación), en el pod backend (passthrough), o en ambos con recifrado del lado de la malla?
2. **¿Quién autentica a quién?** ¿TLS solo del servidor (el cliente confía en el servidor), o mTLS en el borde (el gateway también exige un certificado de cliente a los llamadores externos)?
3. **¿Cómo llegan las claves privadas a Envoy?** ¿Montadas como archivos en el pod del gateway (requiere un redespliegue para rotar) o entregadas dinámicamente mediante el **Secret Discovery Service (SDS)** desde un secret de Kubernetes (recargado en caliente, sin reinicio)?

Los modos de falla son asimétricos y costosos. Terminá donde no deberías y tenés texto plano en un cable que asumiste cifrado. Montá una clave como archivo y una rotación de certificado ahora necesita un reinicio continuo del ingress durante el cual las conexiones se caen. Poné el secret de TLS en el namespace equivocado y el gateway sirve silenciosamente el certificado *anterior* — o ninguno — mientras cada chequeo gratuito (DNS, el LoadBalancer, el VirtualService) sigue pasando. Este tema tiene un peso de 8 porque el borde es simultáneamente la superficie más expuesta y aquella donde una mala configuración es invisible hasta que un cliente ve un error de certificado.

El modelo de referencia que hay que tener en la cabeza:

```
                          ┌──────────────────── Istio mesh (mTLS everywhere) ─────────────┐
   Internet               │                                                               │
   client ──TLS/443──▶ istio-ingressgateway ──ISTIO_MUTUAL──▶ sidecar ──▶ app pod         │
   (browser,          (Envoy, no app          (re-encrypted,        (plaintext localhost) │
    partner API)       container)              SPIFFE identity)                           │
                          │                                                               │
                          └───────────────────────────────────────────────────────────────┘
      ▲ untrusted network ▲ trust boundary ▲ authenticated, encrypted intra-mesh
```

El gateway es donde se presenta un certificado en el que confía el *público* (de Let's Encrypt, DigiCert, una PKI interna), y donde comienza el mTLS basado en SPIFFE del propio Istio del lado interno.

---

## 2. Una taxonomía de modos de TLS en el borde

### 2.1 Terminación vs. passthrough vs. recifrado

| Estrategia | TLS termina en | ¿El gateway puede enrutar en L7 (path/header)? | El backend ve | Cuándo usar |
|---|---|---|---|---|
| **Terminación en el borde** (`SIMPLE`/`MUTUAL`) | Ingress gateway | **Sí** — Envoy descifra, así que el enrutamiento HTTP, las reescrituras de headers y los reintentos funcionan todos | texto plano (luego recifrado por el mTLS del sidecar hacia la app) | El predeterminado. Controlás la malla y querés funciones L7 + observabilidad. |
| **Passthrough** (`PASSTHROUGH`) | Pod backend | **No** — Envoy solo ve el handshake de TLS; enruta solo por **SNI** | el texto cifrado original, de extremo a extremo | El backend debe poseer la clave privada (regulatorio), o termina un protocolo que Istio no debería descifrar. |
| **Recifrado** | Gateway, luego recifra hacia el backend | Sí en el borde | nueva sesión de TLS (mTLS de la malla) | Esto *es* el comportamiento normal de Istio: terminación `SIMPLE` en el borde + mTLS de sidecar `ISTIO_MUTUAL` hacia la app. |

El punto sutil que la mayoría de los operadores pasa por alto: con Istio casi nunca hacés "texto plano hacia el backend". Terminación en el borde + mTLS de sidecar *es* recifrado. El gateway descifra el TLS del cliente, aplica la política L7, y luego el propio equivalente-a-sidecar del gateway recifra con mTLS de Istio hacia el workload de destino. Obtenés control L7 **y** cifrado en el cable hasta el pod.

### 2.2 El campo `tls.mode` — toda la superficie de decisión

| `mode` | ¿El gateway presenta cert de servidor? | ¿El gateway verifica cert de cliente? | ¿TLS terminado? | Uso principal |
|---|---|---|---|---|
| `SIMPLE` | Sí | No | Sí | Terminación HTTPS estándar (navegador → gateway). |
| `MUTUAL` | Sí | **Sí** (contra una CA) | Sí | mTLS en el borde: solo pasan los clientes que poseen un cert firmado por tu CA. |
| `OPTIONAL_MUTUAL` | Sí | Si se presenta | Sí | Migración: aceptar tanto clientes mTLS como de TLS unidireccional durante el despliegue. |
| `PASSTHROUGH` | No | No | **No** — solo enrutamiento por SNI | El backend termina TLS; el gateway es un router L4 tonto por SNI. |
| `ISTIO_MUTUAL` | Usa certs de Istio | Usa certs de Istio | Sí | mTLS usando los propios certs SPIFFE de la malla (típicamente gateways este-oeste / internos de la malla, no el borde público). |
| `AUTO_PASSTHROUGH` | No | No | No | Gateways este-oeste multi-cluster; enruta por SNI codificando cluster/endpoint. No es un modo de borde público. |

Solo `SIMPLE`, `MUTUAL`, `OPTIONAL_MUTUAL` y `PASSTHROUGH` son elecciones orientadas al borde. `ISTIO_MUTUAL` y `AUTO_PASSTHROUGH` son modos de plomería de la malla y aparecen en gateways internos.

### 2.3 Cómo llega la clave a Envoy: SDS vs. montaje de archivo

| | **SDS (`credentialName`)** | **Montaje de archivo (`serverCertificate`/`privateKey`)** |
|---|---|---|
| Origen | Secret de Kubernetes, empujado por istiod mediante gRPC SDS | Archivos horneados en / montados sobre el pod del gateway |
| Rotación | Recarga en caliente, **sin reinicio**, sin conexiones caídas | Requiere remontar → **reinicio continuo** del gateway |
| Radio de explosión de un cert malo | Un secret | Todo el deployment del gateway |
| Integración con cert-manager | Nativa (escribe un Secret) | Torpe (necesita plomería de volúmenes) |
| Restricción de namespace | El Secret debe vivir donde corre el **workload del gateway** (por defecto `istio-system`) | N/A |
| Recomendación | **Siempre preferí esto.** | Solo legado / air-gapped. |

**El hecho operativo más importante de este tema:** con `credentialName`, el Secret referenciado debe existir en el **namespace del deployment del ingress gateway** (por defecto `istio-system`), **no** en el namespace del recurso `Gateway` ni el de la aplicación. Esta discrepancia es la falla silenciosa número uno del TLS de borde. (Las referencias de secret entre namespaces solo son posibles mediante la Kubernetes Gateway API con un `ReferenceGrant`, cubierto en §10.)

---

## 3. Anatomía del ingress gateway

El ingress gateway es un `Deployment` + `Service` de tipo `LoadBalancer` creado por la instalación de Istio. Es un Envoy plano sin contenedor de aplicación — existe para recibir tráfico externo y aplicar la configuración de `Gateway` + `VirtualService`.

```
$ kubectl get deploy,svc -n istio-system -l istio=ingressgateway
NAME                                   READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/istio-ingressgateway   1/1     1            1           14d

NAME                           TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                                      AGE
service/istio-ingressgateway   LoadBalancer   10.96.114.201   203.0.113.10    15021:31021/TCP,80:30080/TCP,443:31443/TCP   14d
```

Fijate en el mapeo de puertos. El **service** expone 80 y 443, pero el contenedor Envoy vincula puertos internos no privilegiados (`8080`, `8443`) porque corre como no-root:

```
$ kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}{" -> "}{.targetPort}{"\n"}{end}'
status-port     15021 -> 15021
http2           80 -> 8080
https           443 -> 8443
```

Consecuencia con la que *vas* a chocar mientras depurás: configurás el `Gateway` con `port.number: 443` (el puerto del **service**), pero `istioctl proxy-config listener` reporta el listener de Envoy en **8443**. Ambos son correctos; son capas diferentes.

Capturá la dirección del ingress una vez y reutilizala:

```
$ export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ export SECURE_INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
$ echo "$INGRESS_HOST:$SECURE_INGRESS_PORT"
203.0.113.10:443
```

(En clusters sin un LoadBalancer externo — kind, minikube, bare-metal sin MetalLB — leé `.spec.ports[?(@.name=="https")].nodePort` y usá en su lugar una IP de nodo.)

---

## 4. Terminación TLS simple — el camino completo

### 4.1 Generar una CA y un certificado de servidor (PKI de laboratorio)

En producción estos vienen de cert-manager o de tu PKI (§9); acá los construimos a mano para que cada campo sea visible.

```
$ mkdir -p certs && cd certs

# Root CA
$ openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
    -subj '/O=Example Inc./CN=example.com' \
    -keyout example.com.key -out example.com.crt
Generating a RSA private key
............................+++++
writing new private key to 'example.com.key'
-----

# Server key + CSR for httpbin.example.com
$ openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
    -keyout httpbin.example.com.key \
    -subj '/CN=httpbin.example.com/O=httpbin organization'

# Sign the server cert with the CA, adding a SAN (browsers require SAN, not CN)
$ openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
    -set_serial 1 -in httpbin.example.com.csr \
    -extfile <(printf "subjectAltName=DNS:httpbin.example.com") \
    -out httpbin.example.com.crt
Certificate request self-signature ok
subject=CN = httpbin.example.com, O = httpbin organization
```

### 4.2 Crear el secret de SDS **en el namespace del gateway**

```
$ kubectl create -n istio-system secret tls httpbin-credential \
    --key=httpbin.example.com.key \
    --cert=httpbin.example.com.crt
secret/httpbin-credential created
```

Un secret `kubernetes.io/tls` contiene exactamente `tls.crt` y `tls.key`. Eso es todo lo que el modo `SIMPLE` necesita.

### 4.3 El recurso `Gateway`

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: istio-system          # co-located with the workload; keeps secret + gateway together
spec:
  selector:
    istio: ingressgateway          # binds this config to the ingress gateway pods
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential   # -> secret httpbin-credential in THIS namespace
      minProtocolVersion: TLSV1_2          # refuse TLS 1.0/1.1 at the edge
    hosts:
    - httpbin.example.com
```

### 4.4 El `VirtualService` que realmente enruta la petición

Un `Gateway` abre un puerto y termina TLS; **no** decide adónde va la petición. Siempre lo emparejás con un `VirtualService`. Terminar TLS sin un `VirtualService` vinculado es el clásico síntoma de "el handshake tiene éxito, y luego un 404".

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
  namespace: default
spec:
  hosts:
  - httpbin.example.com
  gateways:
  - istio-system/httpbin-gateway    # namespace/name — MUST match the Gateway's location
  http:
  - match:
    - uri:
        prefix: /status
    - uri:
        prefix: /delay
    route:
    - destination:
        host: httpbin.default.svc.cluster.local
        port:
          number: 8000
```

Dos referencias cruzadas que deben alinearse exactamente, o te da un 404 silencioso:
- `VirtualService.spec.hosts` ⊇ el host que envía el cliente (y ⊆ los `hosts` del server del `Gateway`).
- `VirtualService.spec.gateways` nombra al gateway como `namespace/name`. Un simple `httpbin-gateway` se resuelve en el *propio* namespace del VirtualService (`default`), que no encontrará un gateway en `istio-system`.

### 4.5 Desplegar el backend de ejemplo y aplicar todo

```
$ kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/httpbin/httpbin.yaml
serviceaccount/httpbin created
service/httpbin created
deployment.apps/httpbin created

$ kubectl apply -f httpbin-gateway.yaml -f httpbin-vs.yaml
gateway.networking.istio.io/httpbin-gateway created
virtualservice.networking.istio.io/httpbin created
```

### 4.6 Verificar el handshake y la ruta de extremo a extremo

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
* Added httpbin.example.com:443:203.0.113.10 to DNS cache
*   Trying 203.0.113.10:443...
* Connected to httpbin.example.com (203.0.113.10) port 443
* ALPN: curl offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.2 (IN), TLS handshake, Server hello (2):
* TLSv1.2 (IN), TLS handshake, Certificate (11):
* Server certificate:
*  subject: CN=httpbin.example.com; O=httpbin organization
*  start date: Aug  8 00:00:00 2026 GMT
*  expire date: Aug  8 00:00:00 2027 GMT
*  subjectAltName: host "httpbin.example.com" matched cert's "httpbin.example.com"
*  issuer: O=Example Inc.; CN=example.com
*  SSL certificate verify ok.
* using HTTP/2
> GET /status/418 HTTP/2
> Host: httpbin.example.com
>
< HTTP/2 418
< server: istio-envoy
< x-more-info: http://tools.ietf.org/html/rfc2324

    -=[ teapot ]=-
```

`SSL certificate verify ok` + `server: istio-envoy` + el estado esperado prueban el camino completo: TLS terminado en el gateway con el cert correcto, y el `VirtualService` enrutó al backend.

---

## 5. Redirección HTTP→HTTPS y SNI multi-host

Los bordes reales sirven muchos hosts y no deben aceptar texto plano. Un solo `Gateway` puede llevar múltiples bloques `server`, cada uno con su propio conjunto de hosts SNI y su propio certificado, más un server en el puerto 80 que solo emite una redirección 301.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: edge-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  # 1) Plaintext port 80 exists ONLY to bounce clients to HTTPS.
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - httpbin.example.com
    - api.example.com
    tls:
      httpsRedirect: true          # 301 to https:// — no plaintext ever routed
  # 2) httpbin over its own cert.
  - port:
      number: 443
      name: https-httpbin
      protocol: HTTPS
    hosts:
    - httpbin.example.com
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential
      minProtocolVersion: TLSV1_2
  # 3) api on a different cert — Envoy selects the cert by SNI.
  - port:
      number: 443
      name: https-api
      protocol: HTTPS
    hosts:
    - api.example.com
    tls:
      mode: SIMPLE
      credentialName: api-credential
      minProtocolVersion: TLSV1_2
```

Dos servers pueden compartir el puerto 443 porque Envoy demultiplexa según el **SNI** en el ClientHello y presenta el certificado que corresponde. Por esto un cliente que omite el SNI (p. ej. `curl https://203.0.113.10` sin `Host`/`--resolve`) obtiene un error de TLS, no una respuesta HTTP útil — Envoy no tiene forma de elegir un certificado.

Verificá la redirección:

```
$ curl -sI -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:80:$INGRESS_HOST" \
    "http://httpbin.example.com/status/200"
HTTP/1.1 301 Moved Permanently
location: https://httpbin.example.com/status/200
server: istio-envoy
```

Verificá la selección de cert basada en SNI:

```
$ echo | openssl s_client -connect "$INGRESS_HOST:443" -servername api.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN = api.example.com, O = Example Inc.

$ echo | openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN = httpbin.example.com, O = httpbin organization
```

Misma IP, mismo puerto, dos certificados diferentes — seleccionados puramente por SNI.

---

## 6. TLS mutuo en el borde (`MUTUAL`)

El mTLS de borde hace que el gateway exija un certificado de cliente firmado por una CA en la que confiás — el patrón estándar para APIs B2B/de socios e ingress de confianza cero. El cliente se autentica por **posesión criptográfica de una clave**, no por un token de API.

### 6.1 Construir un cert de cliente y el secret de mTLS

```
$ openssl req -out client.example.com.csr -newkey rsa:2048 -nodes \
    -keyout client.example.com.key -subj '/CN=client.example.com/O=partner org'
$ openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
    -set_serial 2 -in client.example.com.csr -out client.example.com.crt
Certificate request self-signature ok
```

Para `MUTUAL`, el secret de SDS necesita la CA que firma los certs de **cliente** además del keypair del servidor. Creá un secret genérico que lleve `tls.crt`, `tls.key` y `ca.crt`:

```
$ kubectl create -n istio-system secret generic httpbin-credential-mtls \
    --from-file=tls.key=certs/httpbin.example.com.key \
    --from-file=tls.crt=certs/httpbin.example.com.crt \
    --from-file=ca.crt=certs/example.com.crt
secret/httpbin-credential-mtls created
```

> Istio localiza la CA de verificación de cliente de dos formas: la clave `ca.crt` dentro del mismo secret (mostrada acá), **o** un secret separado llamado `<credentialName>-cacert`. La forma de un solo secret es más limpia y rota atómicamente.

### 6.2 Gateway en modo `MUTUAL`

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: httpbin-mtls-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: MUTUAL
      credentialName: httpbin-credential-mtls   # provides server keypair + ca.crt for client verification
      minProtocolVersion: TLSV1_2
    hosts:
    - httpbin.example.com
```

### 6.3 Probar que rechaza clientes no autenticados y acepta los autenticados

Sin un cert de cliente — rechazado durante el handshake:

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:443:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    "https://httpbin.example.com/status/200"
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.2 (IN), TLS handshake, Server hello (2):
* TLSv1.2 (IN), TLS handshake, Request CERT (13):
* TLSv1.2 (OUT), TLS alert, unknown CA (560):
* OpenSSL/3.0.2: error:0A000418:SSL routines::tlsv1 alert unknown ca
curl: (35) error:0A000418:SSL routines::tlsv1 alert unknown ca
```

Con el cert + clave del cliente — aceptado:

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:443:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    --cert certs/client.example.com.crt \
    --key certs/client.example.com.key \
    "https://httpbin.example.com/status/200"
* TLSv1.2 (IN), TLS handshake, Request CERT (13):
* TLSv1.2 (OUT), TLS handshake, Certificate (11):
* TLSv1.2 (OUT), TLS handshake, Finished (20):
* SSL certificate verify ok.
< HTTP/2 200
< server: istio-envoy
```

### 6.4 mTLS autentica la conexión, no autoriza la identidad

`MUTUAL` prueba que el cliente posee *un* cert firmado por tu CA — **no** restringe *cuál* cliente. Para autorizar por identidad, superponé un `AuthorizationPolicy` en el ingress que haga match con el subject/SAN del certificado. Istio expone la identidad verificada del cliente mediante el header `X-Forwarded-Client-Cert` (XFCC) y como un principal de la petición:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-known-partners
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
  - from:
    - source:
        # SAN/DN pulled from the presented client certificate
        principals: ["client.example.com", "partner-b.example.com"]
```

Ahora un cert válido-pero-no-listado completa el handshake pero recibe un `403 RBAC: access denied`. Esta separación — autenticación en la capa de TLS, autorización en la capa de política — es el modelo mental relevante para el examen.

---

## 7. TLS passthrough — enrutamiento por SNI sin descifrado

Cuando el backend debe terminar TLS por sí mismo (posee la clave por cumplimiento normativo, o habla un protocolo que Istio no debe tocar), usá `PASSTHROUGH`. El gateway se convierte en un router de Capa 4 que lee solo el SNI del ClientHello y reenvía el stream cifrado sin tocarlo.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: passthrough-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH        # gateway holds NO cert; it never decrypts
    hosts:
    - nginx.example.com
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nginx
  namespace: istio-system
spec:
  hosts:
  - nginx.example.com
  gateways:
  - passthrough-gateway
  tls:                          # NOTE: tls match, not http — there is no L7 to match on
  - match:
    - port: 443
      sniHosts:
      - nginx.example.com       # sniHosts is mandatory in passthrough; it's the only routing key
    route:
    - destination:
        host: my-nginx.default.svc.cluster.local
        port:
          number: 443
```

Diferencias críticas respecto de la terminación, y trampas comunes del examen:
- El `VirtualService` usa un bloque de match **`tls`** con **`sniHosts`**, no un bloque `http`. No hay petición descifrada, así que el match por path/header es imposible.
- `sniHosts` es **obligatorio**. Omitirlo significa que nada enruta.
- El pod backend presenta su propio certificado; la cadena de confianza del cliente debe validar contra *ese* cert, y el certificado del gateway es irrelevante.

No podés combinar passthrough con ninguna función L7 — reintentos, reescrituras de headers, enrutamiento por path u observabilidad de las URLs — porque el gateway nunca ve texto plano. Ese es el precio del cifrado de extremo a extremo hasta el pod.

---

## 8. Endurecimiento de protocolo y cifrados

Los regímenes de cumplimiento (PCI-DSS, FedRAMP) exigen una versión mínima de TLS y una lista de cifrados aprobada. Configurá esto por server:

```yaml
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential
      minProtocolVersion: TLSV1_2        # reject TLS 1.0 / 1.1
      maxProtocolVersion: TLSV1_3
      cipherSuites:                      # applies to TLS 1.2 and below ONLY
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
```

| Campo | Significado | Truco |
|---|---|---|
| `minProtocolVersion` | Versión de TLS más baja aceptada | El predeterminado es el default de Envoy (actualmente TLS 1.2). Configuralo explícitamente para auditabilidad. |
| `maxProtocolVersion` | Versión de TLS más alta aceptada | Rara vez se restringe; dejalo en TLS 1.3. |
| `cipherSuites` | Lista de cifrados permitidos | **Ignorado para TLS 1.3** — sus cipher suites están fijados por el RFC y no son configurables en Envoy. `cipherSuites` solo restringe TLS ≤ 1.2. |

Los valores predeterminados a nivel de toda la malla pueden establecerse una vez en el `MeshConfig` (`meshConfig.tlsDefaults.minProtocolVersion`, `.cipherSuites`) para que cada gateway y sidecar los herede; los campos por `Gateway` luego sobrescriben solo donde haga falta.

Verificá lo que el borde realmente negocia — nunca confíes en el manifiesto, confiá en el cable:

```
# Should fail: TLS 1.1 must be refused
$ openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com -tls1_1 2>&1 | grep -E 'Protocol|handshake failure|alert'
140704...:error:0A0000102:SSL routines::unsupported protocol
* TLSv1.1 (OUT), TLS alert, protocol version (582):

# Should succeed: TLS 1.3, and report the negotiated cipher
$ openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com -tls1_3 2>/dev/null \
    | grep -E 'Protocol|Cipher'
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
```

Escaneá la postura negociada completa con `nmap`:

```
$ nmap --script ssl-enum-ciphers -p 443 "$INGRESS_HOST"
PORT    STATE SERVICE
443/tcp open  https
| ssl-enum-ciphers:
|   TLSv1.2:
|     ciphers:
|       TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|       TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 (secp256r1) - A
|     cipher preference: server
|   TLSv1.3:
|     ciphers:
|       TLS_AES_256_GCM_SHA384 (ecdh_x25519) - A
|_  least strength: A
```

Sin secciones TLSv1.0/1.1 = el piso está aplicado.

---

## 9. Automatizando certificados con cert-manager

Los certs hechos a mano son para laboratorios; los bordes de producción usan cert-manager para emitir y **rotar** certificados automáticamente. Porque el `credentialName` de Istio lee un Secret de Kubernetes y lo recarga en caliente mediante SDS, cert-manager se integra con cero pegamento: cert-manager escribe el Secret, istiod lo empuja al gateway, sin reinicio.

`ClusterIssuer` (ACME / Let's Encrypt, HTTP-01 resuelto a través del mismo ingress gateway):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: istio
```

`Certificate` — cert-manager escribe el keypair resultante en `istio-system` donde el gateway lo leerá:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin-example-com
  namespace: istio-system          # MUST be the gateway's namespace for credentialName to see it
spec:
  secretName: httpbin-credential   # <-- exactly the name the Gateway references
  duration: 2160h                  # 90d
  renewBefore: 360h                # rotate 15d before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  dnsNames:
  - httpbin.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

El `Gateway` de §4.3 no necesita ningún cambio — ya referencia `credentialName: httpbin-credential`. Observá la emisión y la rotación:

```
$ kubectl get certificate -n istio-system httpbin-example-com
NAME                  READY   SECRET               AGE
httpbin-example-com   True    httpbin-credential   47s

$ kubectl describe certificate -n istio-system httpbin-example-com | grep -A4 Events
Events:
  Type    Reason     Age   From          Message
  ----    ------     ----  ----          -------
  Normal  Issuing    50s   cert-manager  Issuing certificate as Secret does not exist
  Normal  Requested  49s   cert-manager  Created new CertificateRequest resource
  Normal  Issued     18s   cert-manager  Certificate issued successfully
```

Cuando cert-manager rota el Secret, istiod detecta el cambio y empuja por SDS el nuevo cert al gateway en ejecución. Confirmá que el gateway vivo lo tomó sin un reinicio en §11.

Para una PKI interna en lugar de ACME, cambiá el `ClusterIssuer` por un issuer `ca` (un Secret que contiene tu CA intermedia) o un issuer `vault`/`venafi` — el `Certificate` y el `Gateway` no cambian.

---

## 10. El equivalente en la Kubernetes Gateway API

Istio implementa la **Kubernetes Gateway API** upstream (`gateway.networking.k8s.io`) junto a sus propias CRDs. Para nuevos despliegues de borde esta es la dirección hacia la que se avanza; el examen espera familiaridad con el mapeo.

Terminación simple expresada en la Gateway API:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: default
spec:
  gatewayClassName: istio          # provisions a dedicated gateway Deployment/Service
  listeners:
  - name: https
    hostname: httpbin.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate              # == Istio SIMPLE
      certificateRefs:
      - kind: Secret
        name: httpbin-credential
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: default
spec:
  parentRefs:
  - name: httpbin-gateway
  hostnames:
  - httpbin.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /status
    backendRefs:
    - name: httpbin
      port: 8000
```

Traducción de conceptos:

| Istio API | Kubernetes Gateway API |
|---|---|
| `Gateway` (`networking.istio.io`) | `Gateway` (`gateway.networking.k8s.io`) + `GatewayClass` |
| `tls.mode: SIMPLE` | `tls.mode: Terminate` |
| `tls.mode: PASSTHROUGH` | `tls.mode: Passthrough` (en un `TLSRoute`) |
| `tls.credentialName` | `tls.certificateRefs[].name` |
| `VirtualService` (http) | `HTTPRoute` |
| `VirtualService` (tls/sni) | `TLSRoute` |
| El Secret debe estar en `istio-system` | El Secret está en el namespace del **`Gateway`**; entre namespaces necesita un `ReferenceGrant` |

Dos diferencias de comportamiento importantes:
- Con `gatewayClassName: istio`, Istio **provisiona un nuevo gateway dedicado** Deployment+Service por cada objeto `Gateway` (en el namespace del `Gateway`), en lugar de reutilizar el `istio-ingressgateway` compartido. El Secret del certificado, por lo tanto, vive junto a ese gateway, no en `istio-system`.
- Las referencias de certificado/backend entre namespaces son una concesión de primera clase y *explícita* (`ReferenceGrant`) en lugar de una colocación implícita en istio-system — una mejora de seguridad.

`ReferenceGrant` que permite a un `Gateway` en `default` leer un Secret en `certs`:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-cert
  namespace: certs
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: default
  to:
  - group: ""
    kind: Secret
```

---

## 11. Verificación y diagnóstico de fallas

El TLS de borde falla silenciosamente mucho más a menudo que de forma ruidosa. Trabajá la escalera desde "¿se acepta la configuración?" hacia arriba hasta "¿se comporta el cable?", y *confirmá de forma independiente* que el certificado realmente se cargó en el Envoy en ejecución — un `Gateway` que referencia un secret inexistente igual se aplica sin problemas.

### 11.1 Validación estática de la configuración primero (gratis, atrapa la mayoría de los errores)

```
$ istioctl analyze -n istio-system
Error [IST0101] (Gateway httpbin-gateway.istio-system) Referenced credentialName not found:
  "httpbin-credential" in namespace "istio-system"
Warning [IST0132] (VirtualService httpbin.default) one or more host [httpbin.example.com]
  defined in gateway istio-system/httpbin-gateway not found in the current namespace routes
```

`istioctl analyze` verifica de forma cruzada la vinculación Gateway↔Secret↔VirtualService y es la forma más rápida de atrapar las tres fallas principales (secret faltante, namespace equivocado, host no vinculado).

### 11.2 Confirmar que el cert está realmente cargado en el gateway en ejecución

Este es el chequeo que separa "el secret existe" de "Envoy lo está sirviendo". La entrega por SDS puede retrasarse o fallar incluso cuando el Secret está presente.

```
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
RESOURCE NAME                                   TYPE           STATUS     VALID CERT     SERIAL NUMBER   NOT AFTER                NOT BEFORE
kubernetes://httpbin-credential                 Cert Chain     ACTIVE     true           1               2027-08-08T00:00:00Z     2026-08-08T00:00:00Z
kubernetes://httpbin-credential-cacert          Cert Chain     ACTIVE     true           <n/a>           2027-08-08T00:00:00Z     2026-08-08T00:00:00Z
default                                          Cert Chain     ACTIVE     true           ...             ...                      ...
```

`STATUS: ACTIVE` + `VALID CERT: true` para `kubernetes://<credentialName>` es la prueba de que el push de SDS llegó. Si la fila falta, el secret está ausente, en el namespace equivocado o malformado (claves incorrectas). Volcá el leaf completo para inspeccionar SAN/expiración tal como Envoy lo ve:

```
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
    -o json | jq -r '.dynamicActiveSecrets[]
    | select(.name=="kubernetes://httpbin-credential")
    | .secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -subject -dates -ext subjectAltName
subject=CN = httpbin.example.com, O = httpbin organization
notBefore=Aug  8 00:00:00 2026 GMT
notAfter=Aug  8 00:00:00 2027 GMT
X509v3 Subject Alternative Name:
    DNS:httpbin.example.com
```

### 11.3 Confirmar que el listener y su filter chain existen

```
$ istioctl proxy-config listener deploy/istio-ingressgateway -n istio-system --port 8443
ADDRESS PORT  MATCH                          DESTINATION
0.0.0.0 8443  SNI: httpbin.example.com       Route: https.443.https.httpbin-gateway.istio-system
```

Sin fila en 8443 ⇒ el server HTTPS del `Gateway` nunca programó un listener (usualmente un `selector` que no hace match con ningún pod del gateway, o un bloque TLS inválido). El nombre `Route:` es la clave de unión con el `VirtualService`.

### 11.4 Los flags del access-log — leé el código de respuesta que asigna Envoy

```
$ kubectl logs -n istio-system deploy/istio-ingressgateway | tail -1
[2026-08-08T12:00:00.123Z] "GET /status/418 HTTP/2" 418 - via_upstream -
  "-" 0 135 4 3 "203.0.113.55" "curl/8.5.0" "b1e2..." "httpbin.example.com"
  "10.244.1.7:80" outbound|8000||httpbin.default.svc.cluster.local ...
```

El campo de response-flags es el diagnóstico más rápido en la malla. Los que aparecen en el borde de TLS:

| Flag | Significado en el borde | Causa probable |
|---|---|---|
| `NR` | Sin ruta configurada | El `VirtualService` no está vinculado a este gateway, o hay discrepancia de host/SNI → **404** |
| `NC` | Sin cluster | La ruta hizo match pero el `host`/`port` de destino no resuelve a un service |
| `UF` | Falla de conexión al upstream | Backend caído, o **discrepancia de mTLS de la malla** en el salto de recifrado |
| `UH` | Sin upstream sano | Todos los endpoints del backend no están sanos |
| `-` (via_upstream) | Éxito | La petición llegó al backend |

### 11.5 Tabla rápida síntoma → causa

| Síntoma | Causa más probable | Confirmar con |
|---|---|---|
| El handshake de TLS falla, ningún HTTP en absoluto | El cliente no envió **SNI**; Envoy no puede seleccionar un cert | agregá `--resolve`/`-servername`; `s_client -servername` funciona, la IP pelada falla |
| `curl: (60) SSL certificate problem: unable to get local issuer` | El cliente no confía en la CA del servidor | `--cacert` con la CA emisora; verificá que el SAN del leaf coincida con el host |
| Handshake OK, luego **404 not found** | `VirtualService` no vinculado o discrepancia de host | flag de log `NR`; `istioctl analyze`; verificá `spec.gateways` = `ns/name` |
| Handshake OK, luego **503 UF/UH** | El salto de recifrado falla (mTLS de la malla) o el backend está caído | flag de log `UF`/`UH`; verificá `PeerAuthentication`/`DestinationRule` |
| Alerta `unknown ca` durante el handshake | Modo `MUTUAL`; el cert de cliente no está firmado por el `ca.crt` del gateway | proveé `--cert/--key`; verificá el `ca.crt` en el secret |
| El gateway sirve el certificado **viejo** después de la rotación | El secret se actualizó pero en el namespace equivocado, o SDS no lo empujó | `proxy-config secret` muestra un serial obsoleto → arreglá el namespace / reiniciá el push de istiod |
| `503` solo después de una renovación de cert | Cert montado como archivo (no SDS) necesita un reinicio | migrá a `credentialName`/SDS |

### 11.6 Probar que la rotación en caliente funcionó (sin reinicio)

Después de que cert-manager renueve, el serial en el gateway vivo debería cambiar con **cero** reinicios del gateway:

```
$ kubectl get pods -n istio-system -l istio=ingressgateway   # note RESTARTS stays 0
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-6b9c7c8f7-x4k2p    1/1     Running   0          14d

$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
    | grep httpbin-credential
kubernetes://httpbin-credential   Cert Chain   ACTIVE   true   4   2027-11-06T00:00:00Z   2026-08-08T00:00:00Z
#                                                              ^ serial incremented, RESTARTS still 0 → SDS hot-reload confirmed
```

---

## 12. Referencias

- Istio — *Secure Gateways* (terminación TLS SIMPLE/MUTUAL, `credentialName`/SDS): https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
- Istio — *Ingress Gateways* (vinculación de Gateway + VirtualService): https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — *TLS Ingress with a file-mounted cert* (compromiso archivo vs SDS): https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/
- Istio API reference — `Gateway` / `Server` / `ServerTLSSettings` (`mode`, `minProtocolVersion`, `cipherSuites`, `httpsRedirect`): https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio API reference — `VirtualService` (enrutamiento `tls`/`sniHosts` para passthrough): https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — *Kubernetes Gateway API* support (`gatewayClassName: istio`, `ReferenceGrant`): https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/
- Istio — *Authorization Policy* (identidad desde certs de cliente en el borde): https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — *Debugging Envoy and Istiod* / `istioctl proxy-config` (`secret`, `listener`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — *Global mesh TLS defaults* (`meshConfig.tlsDefaults`): https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Envoy — *TLS / transport socket* (semántica de cifrado y versión de TLS, cifrados fijos de TLS 1.3): https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/transport_sockets/tls/v3/common.proto
- cert-manager — *Istio / Gateway certificate integration*: https://cert-manager.io/docs/usage/istio/
- Kubernetes Gateway API — *TLS configuration* (`Terminate`/`Passthrough`, `certificateRefs`, `ReferenceGrant`): https://gateway-api.sigs.k8s.io/guides/tls/
- CNCF — *ICA Curriculum* (dominios del examen Istio Certified Associate): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf