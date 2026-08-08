# ICA — Topic 4.2: Configuring Authentication (mTLS, JWT)

## Ejercicios guiados

> **Alcance.** Istio divide la autenticación en dos planos independientes: **autenticación de pares** (peer authentication, servicio a servicio, a nivel de transporte, gobernada por `PeerAuthentication` + certificados mTLS emitidos por `istiod`) y **autenticación de solicitud** (request authentication, de usuario final, a nivel de aplicación, gobernada por `RequestAuthentication` + JWT). Este laboratorio recorre ambos, desde el valor por defecto `PERMISSIVE` pasando por la imposición `STRICT` en toda la malla, y luego incorpora la validación de JWT y muestra cómo se entrelazan la autenticación y la **autorización**.
>
> **Requisitos previos.** Un clúster de Kubernetes con Istio instalado (perfil `demo` o `default`), `istioctl` en el `PATH`, y el contexto de `kubectl` apuntando al clúster. Confirmá antes de empezar:
>
> ```bash
> istioctl version
> ```
> ```text
> client version: 1.22.0
> control plane version: 1.22.0
> data plane version: 1.22.0 (4 proxies)
> ```
>
> A lo largo del ejercicio, reemplazá `release-1.22` en las URLs de ejemplo por la etiqueta que coincida con la versión de **tu** plano de control.

---

### Block 0 — Construir la topología de prueba

Creamos tres namespaces que aíslan los tres estados en que puede estar una carga de trabajo: con inyección (`foo`, `bar`) y sin inyección / sin sidecar (`legacy`). Esta es la forma canónica usada para *probar* que mTLS realmente está ocurriendo — un cliente sin sidecar no puede hablar mTLS de Istio, así que su éxito o fracaso te dice cuál es la política real del servidor.

1. Creá y etiquetá los namespaces:

   ```bash
   kubectl create namespace foo
   kubectl create namespace bar
   kubectl create namespace legacy
   kubectl label namespace foo    istio-injection=enabled
   kubectl label namespace bar    istio-injection=enabled
   # legacy is intentionally NOT labelled
   ```

2. Desplegá `httpbin` (servidor) y `sleep` (cliente) en cada namespace:

   ```bash
   for ns in foo bar legacy; do
     kubectl apply -n "$ns" -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/httpbin/httpbin.yaml
     kubectl apply -n "$ns" -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/sleep/sleep.yaml
   done
   ```

3. Confirmá los recuentos de sidecar. Los namespaces con inyección muestran `2/2` contenedores (app + `istio-proxy`); `legacy` muestra `1/1`:

   ```bash
   kubectl get pod -n foo
   kubectl get pod -n legacy
   ```
   ```text
   # foo
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7f9d8c9c4d-5nq2t   2/2     Running   0          40s
   sleep-6d5c9b7f8-x7k2p      2/2     Running   0          40s
   # legacy
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7f9d8c9c4d-qz8mn   1/1     Running   0          40s
   sleep-6d5c9b7f8-l4v9r      1/1     Running   0          40s
   ```

4. Establecé una línea base: sin **ningún** `PeerAuthentication` aplicado, el valor por defecto de Istio es `PERMISSIVE`. Todo cliente — con sidecar o no — debería alcanzar todos los `httpbin`:

   ```bash
   for from in foo bar legacy; do
     for to in foo bar legacy; do
       code=$(kubectl exec "$(kubectl get pod -l app=sleep -n "$from" -o jsonpath='{.items[0].metadata.name}')" \
         -c sleep -n "$from" -- \
         curl -s -o /dev/null -w "%{http_code}" "http://httpbin.$to:8000/ip" 2>/dev/null)
       echo "sleep.$from -> httpbin.$to: $code"
     done
   done
   ```
   ```text
   sleep.foo -> httpbin.foo: 200
   sleep.foo -> httpbin.bar: 200
   sleep.foo -> httpbin.legacy: 200
   sleep.bar -> httpbin.foo: 200
   ...
   sleep.legacy -> httpbin.foo: 200
   sleep.legacy -> httpbin.legacy: 200
   ```

**Verificación de comprensión — Block 0**
1. ¿Por qué un namespace *sin* inyección de sidecar (`legacy`) es esencial para este experimento en lugar de ser solo ruido?
2. ¿Cuál es el modo de autenticación de pares por defecto en toda la malla cuando no existe ningún recurso `PeerAuthentication`, y por qué Istio eligió ese valor por defecto en lugar de `STRICT`?
3. `sleep.legacy -> httpbin.foo` devolvió `200` aunque `httpbin.foo` tiene un sidecar. ¿Qué te dice eso sobre cómo un servidor `PERMISSIVE` trata el texto plano?

---

### Block 1 — Inspeccionar la identidad y los certificados detrás de mTLS

Antes de imponer nada, mirá *con qué* autentica mTLS: un SVID X.509 cuyo SAN codifica la identidad SPIFFE `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`.

1. Volcá el certificado de carga de trabajo que `istiod` emitió para `httpbin.foo`:

   ```bash
   HTTPBIN_FOO=$(kubectl get pod -l app=httpbin -n foo -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$HTTPBIN_FOO" -n foo -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 --decode \
     | openssl x509 -noout -text
   ```
   ```text
   Certificate:
       Data:
           Version: 3 (0x2)
           Issuer: O = cluster.local
           Validity
               Not Before: ...
               Not After : ...   (≈24h later)
           Subject:
           X509v3 extensions:
               X509v3 Subject Alternative Name: critical
                   URI:spiffe://cluster.local/ns/foo/sa/httpbin
   ```

2. Observá la ventana de validez corta (~24h por defecto) y que el `Subject` está vacío — la identidad vive enteramente en el URI del SAN. Confirmá el estado de autenticación efectivo que Istio calcula para la carga de trabajo:

   ```bash
   istioctl experimental describe pod "$HTTPBIN_FOO" -n foo
   ```
   ```text
   Pod: httpbin-7f9d8c9c4d-5nq2t.foo
   ...
   Effective PeerAuthentication:
      Workload mTLS mode: PERMISSIVE
   ```

**Verificación de comprensión — Block 1**
1. Decodificá la identidad `spiffe://cluster.local/ns/foo/sa/httpbin`: ¿qué tres piezas de metadatos de Kubernetes vincula entre sí, y qué componente la firma?
2. El certificado es válido por solo ~24 horas. ¿Qué propiedad operativa te compra esa vida útil corta, y qué componente de la malla es responsable de rotarlo antes de que expire?
3. Dos pods corren bajo el *mismo* ServiceAccount en el mismo namespace. ¿Puede un `PeerAuthentication` o `AuthorizationPolicy` distinguirlos por identidad criptográfica? ¿Por qué sí o por qué no?

---

### Block 2 — Imponer mTLS STRICT en un namespace

Ahora pasá `foo` a `STRICT`. Un servidor `STRICT` acepta **solo** conexiones mTLS y rechaza el texto plano en L4 (reset TCP) — así que `sleep.legacy` (sin sidecar, texto plano) debe romperse, mientras que los clientes con inyección siguen funcionando.

1. Aplicá un `PeerAuthentication` con alcance de namespace. Un `PeerAuthentication` **sin** `selector` se aplica a todo el namespace en el que vive:

   ```yaml
   # peerauth-foo-strict.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: foo
   spec:
     mtls:
       mode: STRICT
   ```
   ```bash
   kubectl apply -f peerauth-foo-strict.yaml
   ```

2. Volvé a ejecutar la matriz de alcanzabilidad del Block 0. Esperá que las conexiones con inyección → `httpbin.foo` sigan en `200`, pero que `sleep.legacy -> httpbin.foo` falle:

   ```bash
   for from in foo bar legacy; do
     code=$(kubectl exec "$(kubectl get pod -l app=sleep -n "$from" -o jsonpath='{.items[0].metadata.name}')" \
       -c sleep -n "$from" -- \
       curl -s -o /dev/null -w "%{http_code}" "http://httpbin.foo:8000/ip" 2>/dev/null)
     echo "sleep.$from -> httpbin.foo: ${code:-FAILED}"
   done
   ```
   ```text
   sleep.foo -> httpbin.foo: 200
   sleep.bar -> httpbin.foo: 200
   sleep.legacy -> httpbin.foo: FAILED
   ```

3. Observá el fallo real desde el cliente en texto plano — es un reset a nivel de transporte, no un estado HTTP:

   ```bash
   SLEEP_LEGACY=$(kubectl get pod -l app=sleep -n legacy -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -sS "http://httpbin.foo:8000/ip"
   ```
   ```text
   curl: (56) Recv failure: Connection reset by peer
   command terminated with exit code 56
   ```

4. Confirmá que los demás namespaces quedan intactos — `httpbin.bar` sigue aceptando al cliente legacy en texto plano:

   ```bash
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.bar:8000/ip"
   ```
   ```text
   200
   ```

**Verificación de comprensión — Block 2**
1. El `PeerAuthentication` se llama `default`. ¿Ese nombre es *funcionalmente* requerido para el efecto sobre todo el namespace, o el alcance está determinado por otra cosa? ¿Qué determina en realidad que se aplique a todo `foo`?
2. `sleep.legacy` obtuvo `curl: (56) Connection reset by peer`, no `403` ni `401`. ¿En qué capa OSI fue rechazado, y por qué no hay ningún código de estado HTTP en absoluto?
3. Tenés planificado un despliegue `STRICT` en toda la malla, pero algunos clientes legacy todavía envían texto plano. ¿Qué modo permite que los clientes con inyección hablen mTLS mientras el texto plano sigue funcionando durante la migración — y cuál es el peligro de dejarlo ahí permanentemente?

---

### Block 3 — Precedencia: overrides a nivel de carga de trabajo y de puerto

`PeerAuthentication` se resuelve por especificidad: **específico de carga de trabajo** (tiene un `selector`) prevalece sobre **todo el namespace** que prevalece sobre **toda la malla**. Dentro de un mismo recurso, **`portLevelMtls`** prevalece sobre el `mtls.mode` de nivel superior para puertos con nombre. Demostrá la jerarquía.

1. Mantené `foo` en `STRICT` de namespace (Block 2), pero recortá el puerto `8080` de `httpbin` (el puerto de contenedor detrás del puerto de servicio `8000`) de vuelta a `PERMISSIVE` usando un selector de carga de trabajo:

   ```yaml
   # peerauth-foo-httpbin-portoverride.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-port-override
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     mtls:
       mode: STRICT
     portLevelMtls:
       "8080":
         mode: PERMISSIVE
   ```
   ```bash
   kubectl apply -f peerauth-foo-httpbin-portoverride.yaml
   ```

   > Las claves de `portLevelMtls` son los **puertos de contenedor** de la carga de trabajo (`targetPort`), no el puerto del Service. `httpbin` escucha en el puerto de contenedor `8080`; el Service lo expone como `8000`.

2. El cliente legacy en texto plano ahora puede volver a alcanzar `httpbin.foo`, porque el puerto en el que aterriza es `PERMISSIVE`:

   ```bash
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip"
   ```
   ```text
   200
   ```

3. Preguntale a Istio qué política *gana* para esta carga de trabajo:

   ```bash
   istioctl experimental describe pod "$HTTPBIN_FOO" -n foo
   ```
   ```text
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
      Port 8080  mTLS mode: PERMISSIVE
   ```

4. Limpiá el override antes de continuar, para que `foo` vuelva a ser uniformemente `STRICT`:

   ```bash
   kubectl delete peerauthentication httpbin-port-override -n foo
   ```

**Verificación de comprensión — Block 3**
1. Ordená de mayor a menor precedencia: `PeerAuthentication` de toda la malla, `PeerAuthentication` de todo el namespace, `PeerAuthentication` con selector de carga de trabajo, entrada `portLevelMtls`.
2. La clave de `portLevelMtls` era `"8080"`, pero los clientes se conectan al Service en `8000`. Explicá el mapeo y por qué usar el puerto del Service aquí silenciosamente no haría nada.
3. Una política de toda la malla llamada `default` en el **namespace raíz** (`istio-system`) establece `STRICT`, y una política de namespace en `foo` establece `PERMISSIVE`. ¿Cuál es el modo efectivo para una carga de trabajo en `foo`, y qué hace que la de `istio-system` sea "de toda la malla" en lugar de simplemente otra política de namespace?

---

### Block 4 — El lado del cliente: modo TLS del DestinationRule

`PeerAuthentication` gobierna al **servidor**. El sidecar del **cliente** decide cómo *originar* la conexión mediante un `trafficPolicy.tls.mode` de `DestinationRule`. Con auto-mTLS (por defecto desde 1.5) Istio elige `ISTIO_MUTUAL` automáticamente hacia servidores capaces de mTLS — pero podés configurarlo mal, y este es un modo de fallo clásico en el examen.

1. Forzá al cliente hacia `httpbin.foo` a enviar **texto plano** con un `DISABLE` explícito, mientras el servidor es `STRICT`:

   ```yaml
   # dr-foo-disable.yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin-foo-disable-tls
     namespace: foo
   spec:
     host: httpbin.foo.svc.cluster.local
     trafficPolicy:
       tls:
         mode: DISABLE
   ```
   ```bash
   kubectl apply -f dr-foo-disable.yaml
   ```

2. Ahora un cliente **con inyección** falla, aunque tiene un sidecar — porque el `DestinationRule` le dijo al cliente que descartara mTLS mientras el servidor lo exige:

   ```bash
   SLEEP_BAR=$(kubectl get pod -l app=sleep -n bar -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_BAR" -c sleep -n bar -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip" || echo "FAILED (reset)"
   ```
   ```text
   000
   FAILED (reset)
   ```

3. Corregilo alineando al cliente a `ISTIO_MUTUAL` (o simplemente borrando la regla para dejar que auto-mTLS tome el control):

   ```bash
   kubectl patch destinationrule httpbin-foo-disable-tls -n foo --type=merge \
     -p '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'
   kubectl exec "$SLEEP_BAR" -c sleep -n bar -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip"
   ```
   ```text
   200
   ```

4. Eliminá el `DestinationRule` — auto-mTLS lo hace innecesario:

   ```bash
   kubectl delete destinationrule httpbin-foo-disable-tls -n foo
   ```

**Verificación de comprensión — Block 4**
1. En una oración cada uno, indicá el comportamiento de quién controla `PeerAuthentication` frente al comportamiento de quién controla el `trafficPolicy.tls` del `DestinationRule`.
2. ¿Cuál es la diferencia entre `MUTUAL` e `ISTIO_MUTUAL` en un `DestinationRule`, y cuál de los dos requiere que proporciones rutas a archivos de certificado?
3. Un servidor `STRICT` más un `DestinationRule` de cliente con `mode: DISABLE` produjo un reset. ¿Cuál de los dos lados cambiás para corregirlo si el requisito de seguridad es "el tráfico debe estar cifrado", y por qué borrar el `DestinationRule` es también una corrección válida aquí?

---

### Block 5 — Autenticación de solicitud con JWT

Cambiá de plano: la autenticación de pares prueba *qué servicio* está llamando; la **autenticación de solicitud** prueba *qué usuario final*. `RequestAuthentication` le dice al sidecar cómo validar un JWT (issuer, JWKS). Crucialmente, por sí solo **no exige** un token — solo rechaza los *inválidos*.

1. No hace falta promover `httpbin.foo` a ser alcanzado a través del ingress; probá dentro de la malla desde `sleep`. Primero aplicá un `RequestAuthentication` que acepte el issuer de demostración de Istio:

   ```yaml
   # req-auth-foo.yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata:
     name: httpbin-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     jwtRules:
       - issuer: "testing@secure.istio.io"
         jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/jwks.json"
   ```
   ```bash
   kubectl apply -f req-auth-foo.yaml
   ```

2. Solicitud con **ningún token** → sigue siendo `200`, porque `RequestAuthentication` por sí solo no obliga a presentar un token:

   ```bash
   SLEEP_FOO=$(kubectl get pod -l app=sleep -n foo -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

3. Solicitud con un token **deliberadamente malformado** → `401`, porque un token *presente* debe ser válido:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer deadbeef.not.ajwt" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   401
   ```

4. Obtené el token de demostración válido de Istio y enviálo → `200`:

   ```bash
   TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/demo.jwt)
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

**Verificación de comprensión — Block 5**
1. El paso 2 no envió **ningún** token y obtuvo `200`; el paso 3 envió un token **incorrecto** y obtuvo `401`. Enunciá la regla sobre `RequestAuthentication` que reconcilia esos dos resultados.
2. ¿A qué apunta `jwksUri`, y qué le pasaría a la validación de tokens si ese endpoint quedara inalcanzable en el momento de la solicitud (suponé que el conjunto de claves nunca se cacheó)?
3. Otros dos campos de `jwtRules` — `audiences` y `forwardOriginalToken` — ¿qué hacen? Da una razón de seguridad por la que podrías establecer cada uno.

---

### Block 6 — Exigir un JWT y autorizar por claims

Para realmente *exigir* un token válido combinás `RequestAuthentication` (validar) con un `AuthorizationPolicy` (exigir). El puente es el **`requestPrincipal`**, con formato `<issuer>/<subject>`. Luego autorizamos por un **claim** específico del JWT.

1. Exigí *cualquier* principal autenticado. `requestPrincipals: ["*"]` significa "la solicitud debe portar una identidad JWT validada":

   ```yaml
   # authz-require-jwt.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-require-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
       - from:
           - source:
               requestPrincipals: ["*"]
   ```
   ```bash
   kubectl apply -f authz-require-jwt.yaml
   ```

2. Ahora **ningún token** pasa de `200` a `403` (`RBAC: access denied`) — la solicitud no tiene ningún principal para satisfacer la regla:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -w " -> %{http_code}\n" "http://httpbin.foo:8000/headers"
   ```
   ```text
   RBAC: access denied -> 403
   ```

3. Con el token de demostración válido → `200` de nuevo:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

4. Ajustá hacia una verificación de **claim**. Reemplazá la política para exigir tanto un principal específico *como* la pertenencia al grupo `group1`. El token de ejemplo `groups-scope.jwt` de Istio porta `groups: ["group1", "group2"]`:

   ```yaml
   # authz-require-claim.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-require-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
       - from:
           - source:
               requestPrincipals: ["testing@secure.istio.io/testing@secure.istio.io"]
         when:
           - key: request.auth.claims[groups]
             values: ["group1"]
   ```
   ```bash
   kubectl apply -f authz-require-claim.yaml
   ```

5. El `demo.jwt` simple **no** tiene claim `groups` → `403`; el token `groups-scope.jwt` → `200`:

   ```bash
   GROUPS_TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/groups-scope.jwt)

   # demo.jwt: valid signature, but missing the groups claim
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "demo.jwt   -> %{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" "http://httpbin.foo:8000/headers"

   # groups-scope.jwt: carries groups=[group1, group2]
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "groups.jwt -> %{http_code}\n" \
     --header "Authorization: Bearer $GROUPS_TOKEN" "http://httpbin.foo:8000/headers"
   ```
   ```text
   demo.jwt   -> 403
   groups.jwt -> 200
   ```

6. Desmontá los recursos del topic:

   ```bash
   kubectl delete requestauthentication httpbin-jwt -n foo
   kubectl delete authorizationpolicy httpbin-require-jwt -n foo
   kubectl delete peerauthentication default -n foo
   kubectl delete namespace foo bar legacy
   ```

**Verificación de comprensión — Block 6**
1. Rastreá los dos rechazos distintos que produjiste: un token **incorrecto** devolvió `401`, pero un token **ausente** (con la política de exigir JWT) devolvió `403`. ¿Qué objeto de Istio es responsable de cada respuesta, y por qué los códigos de estado son diferentes?
2. En el paso 5, `demo.jwt` tenía una firma perfectamente válida y sin embargo fue denegado con `403`. Distinguí "la autenticación tuvo éxito" de "la autorización tuvo éxito" usando este caso exacto.
3. Si aplicaras **solo** el `AuthorizationPolicy` con `requestPrincipals: ["*"]` pero *olvidaras* el `RequestAuthentication`, ¿qué le pasaría a una solicitud que porta un token de apariencia válida, y por qué?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 0
1. **`legacy` es el grupo de control.** Un pod sin sidecar solo puede enviar **texto plano** — no tiene un Envoy para originar mTLS de Istio. Así que su capacidad (o incapacidad) de alcanzar un servidor es una *medición directa* de si ese servidor realmente exige mTLS. El tráfico de inyección-a-inyección puede tener éxito por razones no relacionadas con la política del servidor (auto-mTLS, ambos lados cifrando de todos modos), así que por sí solo no puede probar la imposición. El cliente sin inyección elimina esa ambigüedad.
2. El valor por defecto es **`PERMISSIVE`**. Istio lo eligió para que instalar la malla o inyectar sidecars en una aplicación existente **no rompa** el tráfico en texto plano el primer día. `STRICT` por defecto cortaría cada cliente sin inyección en el instante en que apareciera un sidecar, haciendo imposible la adopción incremental. `PERMISSIVE` es explícitamente un modo de **migración** — un servidor acepta *tanto* mTLS como texto plano simultáneamente.
3. Un servidor `PERMISSIVE` **acepta texto plano además de mTLS en el mismo puerto.** Envoy olfatea (sniff) la conexión: handshake TLS → tratar como mTLS; de lo contrario → tratar como texto plano. Así que el cliente legacy en texto plano es aceptado. Por eso exactamente `PERMISSIVE` es seguro para la migración pero **no** provee una garantía de seguridad — un atacante todavía puede conectarse en claro.

### Block 1
1. El SPIFFE ID vincula el **trust domain** (`cluster.local`), el **namespace** (`foo`) y el **ServiceAccount** (`httpbin`) — es decir, `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`. Está firmado por **`istiod`** (la CA de la malla), que emite el SVID X.509 de la carga de trabajo tras validar el token de ServiceAccount de Kubernetes del pod. La identidad está basada en el ServiceAccount de Kubernetes, *no* es por pod.
2. Las vidas útiles cortas **reducen el radio de impacto de una clave filtrada** y eliminan la necesidad de infraestructura de revocación CRL/OCSP — un certificado robado es inútil en un día. El **istio-agent** (canal: agent ↔ istiod SDS) solicita la rotación y recarga en caliente el nuevo certificado en Envoy vía SDS bastante antes del vencimiento, sin reinicio del pod.
3. **No.** La identidad criptográfica es por **ServiceAccount**, no por pod. Dos pods que comparten un ServiceAccount presentan la *misma* identidad SPIFFE y la misma clase de certificado, así que ninguna regla de autenticación de pares ni de `requestPrincipal`/`principal` puede diferenciarlos. Para distinguirlos debés darles **ServiceAccounts diferentes** (o autorizar por otros atributos como labels mediante otros mecanismos).

### Block 2
1. El nombre `default` **no** es funcionalmente requerido — un `PeerAuthentication` se aplica a todo el namespace siempre que no tenga **`selector`**, sin importar su nombre. (`default` es simplemente el nombre convencional.) Lo que lo hace de todo el namespace es la ausencia de un `selector`; lo que hace que se aplique a `foo` específicamente es que vive en el namespace `foo`. *(El nombre `default` **es** especial en exactamente un lugar: el **namespace raíz**, donde una política sin selector se convierte en el valor por defecto de toda la malla.)*
2. Fue rechazado en **L4 (transporte)**. `STRICT` requiere un handshake TLS; los bytes en texto plano nunca completan uno, así que Envoy resetea la conexión TCP. **No hay estado HTTP** porque la solicitud nunca se convirtió en un intercambio HTTP — la conexión murió por debajo de L7, de ahí `curl: (56) Connection reset by peer` en lugar de `401`/`403`.
3. **`PERMISSIVE`** — acepta tanto mTLS (de clientes con inyección) como texto plano (de clientes legacy) en el mismo puerto, así que podés inyectar sidecars de forma incremental. El peligro de dejarlo permanentemente es que no provee **ninguna imposición**: cualquier cliente en texto plano — incluido un atacante — sigue siendo aceptado, así que queda abierto un camino sin cifrar. El objetivo es alcanzar `STRICT` y quedarse ahí.

### Block 3
1. De mayor → menor: **entrada `portLevelMtls`** > **`PeerAuthentication` con selector de carga de trabajo** > **`PeerAuthentication` de todo el namespace** > **`PeerAuthentication` de toda la malla (namespace raíz)**. Lo más específico siempre gana.
2. Las claves de `portLevelMtls` son el **puerto de contenedor/`targetPort`** de la carga de trabajo (`8080` para `httpbin`), que es lo que Envoy realmente enlaza e impone. El puerto de Service `8000` es solo una abstracción de enrutamiento que el cliente disca; no es lo que la política del lado del servidor coincide. Usar `8000` como clave no coincidiría con ningún listener y el override **silenciosamente no tendría efecto**, dejando el puerto en el `STRICT` heredado.
3. El modo efectivo es **`PERMISSIVE`** — la política de namespace en `foo` es *más específica* que la de toda la malla y la anula. La política de `istio-system` es "de toda la malla" (no meramente de alcance de namespace) porque vive en el **namespace raíz** (el namespace de instalación de Istio, configurado como `meshConfig.rootNamespace`, por defecto `istio-system`) **y** no tiene selector; un `PeerAuthentication` sin selector allí se convierte en el valor por defecto para toda la malla.

### Block 4
1. **`PeerAuthentication`** controla el sidecar del **servidor** — si *requiere/acepta* mTLS en las conexiones entrantes. El **`trafficPolicy.tls` del `DestinationRule`** controla el sidecar del **cliente** — cómo *origina* la conexión saliente.
2. `MUTUAL` = TLS mutuo clásico donde **vos proporcionás** las rutas de archivo del certificado/clave/CA del cliente (`clientCertificate`, `privateKey`, `caCertificates`) — usado para TLS hacia servicios no-Istio / externos. `ISTIO_MUTUAL` = TLS mutuo usando los **certificados SVID autoaprovisionados por Istio**; no proporcionás **ninguna ruta** porque istiod los gestiona. `MUTUAL` requiere las rutas de archivo; `ISTIO_MUTUAL` no.
3. Si el requisito es "el tráfico debe estar cifrado", cambiás el **lado del cliente** — establecé el `DestinationRule` en `ISTIO_MUTUAL` (nunca debilites el servidor `STRICT` a `DISABLE`, que descartaría el cifrado). **Borrar el `DestinationRule`** es igualmente válido porque entonces entra en acción **auto-mTLS**: Istio detecta que el servidor es capaz de mTLS y origina `ISTIO_MUTUAL` automáticamente. El reset ocurrió solo porque un `DISABLE` explícito *anuló* auto-mTLS en el cliente.

### Block 5
1. **`RequestAuthentication` valida tokens pero no los exige.** Una solicitud sin **ningún** token se deja intacta (pasa → `200`); una solicitud **con** un token debe presentar uno *válido* para un issuer configurado, o es rechazada con `401`. Para *obligar* a un token necesitás un `AuthorizationPolicy` (Block 6).
2. `jwksUri` apunta al **JWKS** (JSON Web Key Set) del issuer — las claves públicas usadas para verificar la firma del JWT. Si fuera inalcanzable y el conjunto de claves nunca se hubiera obtenido/cacheado, el sidecar no podría verificar firmas, así que los tokens válidos serían **rechazados con `401`**. En la práctica Istio cachea el JWKS (y podés incrustar claves vía `jwks:`) para sobrevivir a cortes transitorios; un `jwksUri` permanentemente inalcanzable y nunca cacheado rompe toda la validación de tokens para esa regla.
3. **`audiences`** restringe los tokens aceptados a aquellos cuyo claim `aud` coincide con tu servicio — establecelo para que un token acuñado para el servicio A no pueda ser **reproducido (replay)** contra el servicio B (confinamiento de audiencia). **`forwardOriginalToken: true`** reenvía el token bearer original de `Authorization` a la aplicación upstream (por defecto Istio puede quitarlo tras la validación) — establecelo cuando el **backend necesita el token** para su propia inspección de claims o propagación downstream.

### Block 6
1. El **`RequestAuthentication`** produjo el **`401`** — un token *presente pero inválido* es un fallo de autenticación en la capa de request-auth. El **`AuthorizationPolicy`** produjo el **`403 RBAC: access denied`** — el token estaba **ausente**, así que la solicitud no tenía ningún `requestPrincipal` para satisfacer la regla `requestPrincipals: ["*"]`, y la autorización la denegó. `401` = "tu credencial es incorrecta"; `403` = "no tenés credencial / la credencial es insuficiente para esta política". Objetos diferentes, semánticas de fallo diferentes.
2. **La autenticación tuvo éxito** para `demo.jwt`: la firma se verificó contra el JWKS del issuer, así que Istio estableció un `requestPrincipal` válido (`testing@secure.istio.io/testing@secure.istio.io`). **La autorización falló**: la política adicionalmente exigía que `request.auth.claims[groups]` contuviera `group1`, y `demo.jwt` no porta **ningún claim `groups`**, así que la condición `when` no se cumplió → `403`. Probar la identidad (authn) es necesario pero no suficiente; el predicado de claim de la política (authz) es una compuerta separada.
3. Con **solo** el `AuthorizationPolicy` y **ningún** `RequestAuthentication`, Istio **no tiene issuer/JWKS configurado contra el cual validar**, así que nunca establece un `requestPrincipal` a partir del token bearer. La regla `requestPrincipals: ["*"]` por lo tanto coincide con **nada**, e incluso un token "de apariencia válida" produce **`403`**. `RequestAuthentication` es lo que convierte los bytes crudos del encabezado `Authorization` en un principal autenticado; sin él no hay ningún principal para que la autorización lo permita.

</details>

---

### Sources

- Istio — *Authentication* (concepts: peer vs. request auth, mTLS, identity/SPIFFE): https://istio.io/latest/docs/concepts/security/#authentication
- Istio — *Mutual TLS Migration* task (foo/bar/legacy topology, PERMISSIVE→STRICT): https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Authentication Policy* task (PeerAuthentication, RequestAuthentication, JWT samples): https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — *JWT-based authorization* / *Authorization for HTTP traffic* (requestPrincipals, claim conditions): https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
- API reference — `PeerAuthentication`: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- API reference — `RequestAuthentication`: https://istio.io/latest/docs/reference/config/security/request_authentication/
- API reference — `AuthorizationPolicy`: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- API reference — `DestinationRule` (`ClientTLSSettings` / TLS modes): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf