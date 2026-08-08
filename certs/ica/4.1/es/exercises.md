# Topic 4.1 — Configuring Authorization (Istio `AuthorizationPolicy`)

> **Alcance.** Este lab recorre el subsistema de autorización de Istio de punta a punta: la postura deny‑by‑default, las acciones ALLOW/DENY/CUSTOM/AUDIT, la terna de reglas `from`/`to`/`when`, la identidad de origen vía principals de mTLS, los claims de JWT a nivel de request, la precedencia de políticas y los diagnósticos que usás cuando una política no se comporta como está escrita. Cada request se aplica en el sidecar mediante el filtro `envoy.filters.http.rbac` de Envoy — Istiod compila tus CRDs en la configuración de ese filtro y la empuja vía xDS. Entender *dónde* ocurre la aplicación es la mitad de entender *por qué* una regla coincidió o no.
>
> **Fuentes de referencia (oficiales):**
> - Concepto de autorización — https://istio.io/latest/docs/concepts/security/#authorization
> - API de `AuthorizationPolicy` — https://istio.io/latest/reference/config/security/authorization-policy/
> - Tarea de autorización HTTP — https://istio.io/latest/docs/tasks/security/authorization/authz-http/
> - Acción deny y precedencia — https://istio.io/latest/docs/tasks/security/authorization/authz-deny/
> - Autorización JWT — https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
> - Autorización externa (CUSTOM) — https://istio.io/latest/docs/tasks/security/authorization/authz-custom/
> - Condiciones normativas de `AuthorizationPolicy` — https://istio.io/latest/docs/reference/config/security/conditions/

---

## Exercise 0 — Build the test mesh

Necesitás dos namespaces para poder probar el comportamiento de identidad *cross‑namespace*, y una línea base de mTLS estricto para que los matchers `principals` y `namespaces` realmente tengan una identidad verificada contra la cual coincidir. Ajustá el tag de release de Istio en las URLs de JWKS/samples a la versión instalada en tu cluster (`istioctl version`).

1. Confirmá que Istio e `istioctl` están presentes:

   ```bash
   istioctl version
   kubectl -n istio-system get pods
   ```

2. Creá dos namespaces con inyección:

   ```bash
   kubectl create namespace foo
   kubectl label  namespace foo istio-injection=enabled
   kubectl create namespace bar
   kubectl label  namespace bar istio-injection=enabled
   ```

3. Desplegá el servidor (`httpbin`, puerto de servicio 8000) y un cliente en `foo`, y un segundo cliente en `bar`. El sample de `curl` trae su propio `ServiceAccount` llamado `curl`, que pasa a ser tu identidad de origen:

   ```bash
   kubectl apply -f samples/httpbin/httpbin.yaml -n foo
   kubectl apply -f samples/curl/curl.yaml       -n foo
   kubectl apply -f samples/curl/curl.yaml       -n bar
   ```

4. Forzá mTLS estricto en ambos namespaces para que las identidades queden verificadas criptográficamente:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: foo
   spec:
     mtls:
       mode: STRICT
   ---
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: bar
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f peerauth.yaml
   ```

5. Definí un helper de sondeo reutilizable y confirmá la línea base (todavía sin `AuthorizationPolicy` → **allow all**):

   ```bash
   FOO_CURL=$(kubectl get pod -l app=curl -n foo -o jsonpath='{.items[0].metadata.name}')
   BAR_CURL=$(kubectl get pod -l app=curl -n bar -o jsonpath='{.items[0].metadata.name}')

   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "from foo -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "from bar -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Esperado:

   ```
   from foo -> 200
   from bar -> 200
   ```

> **Preguntas de checkpoint**
> - **Q0.1** Con cero objetos `AuthorizationPolicy` en el mesh, ambos sondeos devuelven `200`. ¿Ese comportamiento "allow‑all" es una propiedad del filtro RBAC, o de la decisión de Istiod de *no instalar* un filtro RBAC? ¿Por qué importa la distinción para la latencia y para el mito del deny‑by‑default?
> - **Q0.2** ¿Por qué `PeerAuthentication: STRICT` es un prerequisito antes de confiar en `source.principals` o `source.namespaces` dentro de una `AuthorizationPolicy`? ¿Qué identidad verían esos matchers para un request en texto plano?

---

## Exercise 1 — Deny‑by‑default with an empty policy

Una `AuthorizationPolicy` con un `spec` vacío (`spec: {}`) es el objeto canónico de "allow‑nothing": es una política ALLOW **sin reglas**, así que nada puede coincidir nunca, así que todo lo seleccionado queda denegado.

1. Aplicá un deny‑all a nivel de namespace en `foo` (sin `selector` ⇒ todos los workloads en `foo`):

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-nothing
     namespace: foo
   spec: {}
   ```

   ```bash
   kubectl apply -f allow-nothing.yaml
   ```

2. Volvé a sondear, y esta vez mantené el body para ver la cadena de rechazo de Envoy:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -w "\nHTTP %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Esperado:

   ```
   RBAC: access denied
   HTTP 403
   ```

3. Comprobá que el deny está acotado solo a `foo` — `httpbin` no existe en `bar`, así que en su lugar confirmá que el *objeto de política* no está presente allí:

   ```bash
   kubectl get authorizationpolicy -A
   ```

   Esperado (una fila, en `foo`):

   ```
   NAMESPACE   NAME            AGE
   foo         allow-nothing   30s
   ```

> **Preguntas de checkpoint**
> - **Q1.1** `spec: {}` deniega todo, y sin embargo su campo `action` toma por defecto `ALLOW`. Reconciliá esos dos hechos en una sola oración.
> - **Q1.2** Querés un allow‑nothing *a nivel de todo el mesh*, no solo en `foo`. ¿En qué namespace debe vivir el objeto, y cómo se llama ese namespace en el modelo de Istio? ¿Qué único campo tendrías que cuidar de **no** setear para que aplique a todo el mesh?
> - **Q1.3** Un compañero escribe `spec:` con la clave presente pero el valor literalmente vacío/omitido en el YAML. ¿Es lo mismo que `spec: {}`? ¿Qué haría `kubectl apply`, y el objeto resultante sigue denegando todo?

---

## Exercise 2 — Grant a narrow ALLOW (selector + `to` operation)

Ahora abrí un agujero preciso: permitir solo `GET` sobre `/ip` y `/headers` contra `httpbin`, y nada más. Esto introduce el `selector`, `action: ALLOW` y el bloque `to.operation`.

1. Aplicá el ALLOW acotado al workload:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-get
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - to:
       - operation:
           methods: ["GET"]
           paths: ["/ip", "/headers"]
   ```

   ```bash
   kubectl apply -f httpbin-get.yaml
   ```

2. Sondeá una ruta permitida, una ruta no permitida y un método no permitido:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /ip      -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /get     -> %{http_code}\n" http://httpbin.foo:8000/get
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "POST /post    -> %{http_code}\n" -X POST http://httpbin.foo:8000/post
   ```

   Esperado:

   ```
   GET /ip      -> 200
   GET /get     -> 403
   POST /post    -> 403
   ```

3. Notá que `allow-nothing` del Exercise 1 **sigue aplicado**. Ambas son políticas ALLOW. Confirmá que entendés la unión eliminando el deny‑all y volviendo a probar `/get`:

   ```bash
   kubectl delete authorizationpolicy allow-nothing -n foo
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /get after delete -> %{http_code}\n" http://httpbin.foo:8000/get
   ```

   Esperado (sigue denegado — `httpbin-get` por sí sola es ahora la *única* política ALLOW que selecciona `httpbin`, así que los requests deben coincidir con ella):

   ```
   GET /get after delete -> 403
   ```

> **Preguntas de checkpoint**
> - **Q2.1** Después del paso 3 *eliminaste* el deny‑all, y sin embargo `/get` sigue en `403`. Explicá la regla: una vez que **cualquier** política ALLOW selecciona un workload, ¿qué les pasa a los requests que no coinciden con ninguna de las políticas ALLOW de ese workload?
> - **Q2.2** Dos políticas ALLOW seleccionan el mismo `httpbin` — una permite `GET /ip`, la otra permite `GET /headers`. ¿El permiso efectivo es la **unión** o la **intersección** de ambas? ¿Qué implica eso respecto a ampliar accidentalmente el acceso al agregar una segunda ALLOW?
> - **Q2.3** `paths: ["/ip"]` es una coincidencia exacta. ¿Cómo permitirías todo el subárbol `/api/*`, y cuál es la advertencia documentada sobre el matching de rutas cuando el request primero pasa por un gateway que reescribe o normaliza la ruta?

---

## Exercise 3 — Source identity: `principals` and `namespaces`

Restringí el acceso según *quién* llama. Acá es donde el mTLS estricto del Exercise 0 rinde: `principals` coincide con la identidad SPIFFE del peer transportada en el certificado de cliente.

1. Reemplazá la política anterior: permitir `GET` solo desde el service account `foo/curl`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-from-foo-curl
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           principals: ["cluster.local/ns/foo/sa/curl"]
       to:
       - operation:
           methods: ["GET"]
   ```

   ```bash
   kubectl delete authorizationpolicy httpbin-get -n foo
   kubectl apply  -f httpbin-from-foo-curl.yaml
   ```

2. Sondeá desde ambos namespaces:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "foo/curl -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar/curl -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Esperado:

   ```
   foo/curl -> 200
   bar/curl -> 403
   ```

3. Ampliá a *cualquier* workload en `bar` usando un matcher de namespace en lugar de un principal exacto:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-from-bar-ns
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["bar"]
       to:
       - operation:
           methods: ["GET"]
   ```

   ```bash
   kubectl apply -f httpbin-from-bar-ns.yaml
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar/curl now -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Esperado:

   ```
   bar/curl now -> 200
   ```

> **Preguntas de checkpoint**
> - **Q3.1** Descomponé la cadena de principal `cluster.local/ns/foo/sa/curl`. ¿Qué trust domain, namespace e identidad codifica cada segmento, y por dónde viaja físicamente esa cadena en el cable?
> - **Q3.2** Cambiás el `PeerAuthentication` del namespace `foo` a `PERMISSIVE` y un cliente en texto plano llama a `httpbin`. ¿Qué valor evalúan `source.principals` / `source.namespaces` para ese request, y la política `httpbin-from-foo-curl` lo admitirá? ¿Por qué `PERMISSIVE` + reglas de principal es una trampa de fallo silencioso?
> - **Q3.3** Dentro de una sola `rule`, tenés `from` (dos sources) **y** `to` (una operación). Dentro de un solo `source` listás dos `principals`. Enunciá la semántica AND/OR: entre `rules`, entre entradas de una lista como `from`, y entre valores dentro de una sola lista `principals`.

---

## Exercise 4 — Conditions with `when`

`when` agrega matching arbitrario de atributos por encima de `from`/`to` usando las claves de condición normativas (headers, IP de origen, claims de JWT, puertos…).

1. Requerí un header con secreto compartido además de la identidad:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-header-gate
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["foo", "bar"]
       to:
       - operation:
           methods: ["GET"]
       when:
       - key: request.headers[x-team]
         values: ["platform"]
   ```

   ```bash
   kubectl delete authorizationpolicy httpbin-from-foo-curl httpbin-from-bar-ns -n foo
   kubectl apply  -f httpbin-header-gate.yaml
   ```

2. Sondeá sin y con el header:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "no header   -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "x-team: platform" \
     -w "with header -> %{http_code}\n" http://httpbin.foo:8000/headers
   ```

   Esperado:

   ```
   no header   -> 403
   with header -> 200
   ```

> **Preguntas de checkpoint**
> - **Q4.1** `request.headers[x-team]` es un atributo de L7. ¿Qué debe ser cierto sobre mTLS/el protocolo para que esta condición sea siquiera evaluable, y qué le pasa a una condición de header en `when` adjunta a una política que termina coincidiendo con un puerto TCP crudo (no‑HTTP)?
> - **Q4.2** Un header es trivialmente falsificable por cualquier cliente que pueda alcanzar el sidecar. ¿Por qué `when: request.headers[...]` es aceptable como *defensa en profundidad* pero inaceptable como *único* control, y qué campo de esta misma política es el control de identidad real e infalsificable?
> - **Q4.3** Querés "IP de origen en `10.0.0.0/8`". ¿Qué clave de condición expresa la IP del cliente *original* versus la del peer *conectado directamente*, y por qué difieren detrás de un gateway o de una cadena `X‑Forwarded‑For`?

---

## Exercise 5 — DENY action and policy precedence

Las políticas DENY se evalúan **antes** que las políticas ALLOW. Usalas para guardrails que deben ganar sin importar qué reglas ALLOW agregue después un equipo.

1. Mantené el header gate del Exercise 4, luego agregá un DENY duro sobre métodos de escritura provenientes de `bar`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-writes-from-bar
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: DENY
     rules:
     - from:
       - source:
           namespaces: ["bar"]
       to:
       - operation:
           methods: ["POST", "PUT", "DELETE"]
   ```

   ```bash
   kubectl apply -f deny-writes-from-bar.yaml
   ```

2. Agregá también un ALLOW amplio que *permitiría* esas escrituras, para probar que el DENY gana:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-bar-everything
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["bar"]
   ```

   ```bash
   kubectl apply -f allow-bar-everything.yaml
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar POST /post -> %{http_code}\n" -X POST http://httpbin.foo:8000/post
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar GET  /ip   -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Esperado:

   ```
   bar POST /post -> 403
   bar GET  /ip   -> 200
   ```

> **Preguntas de checkpoint**
> - **Q5.1** Enunciá el orden completo de evaluación de las acciones para un único request. ¿Dónde se ubican `CUSTOM` y `AUDIT` respecto de `DENY` y `ALLOW`, y qué acción nunca influye en el resultado allow/deny?
> - **Q5.2** En el paso 2 el ALLOW `allow-bar-everything` claramente permite `POST`, y sin embargo el `POST` es denegado. ¿Qué política ganó y por qué — y qué te dice esto sobre quién debería ser dueño de los guardrails DENY versus las reglas ALLOW por servicio en un mesh multi‑equipo?
> - **Q5.3** Un request desde `bar` hace un `GET /ip`. Recorrelo por DENY y luego por ALLOW y explicá con precisión qué *ausencia de coincidencia* de una política y qué *coincidencia* de otra se combinan para producir `200`.

---

## Exercise 6 — Request‑level auth: JWT claims

La autorización de usuario final es independiente de la identidad de workload. `RequestAuthentication` valida el JWT (issuer, firma vía JWKS) pero por sí solo únicamente *rechaza tokens inválidos* — un request **sin** token igual lo pasa. Necesitás una `AuthorizationPolicy` sobre `requestPrincipals`/claims para *exigir* un token.

1. Registrá el issuer del JWT (ajustá el tag de release a tu versión instalada):

   ```yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata:
     name: jwt-testing
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     jwtRules:
     - issuer: "testing@secure.istio.io"
       jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"
   ```

2. Exigí un token válido Y que el claim `groups` contenga `group1`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: require-jwt-group
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
   # remove earlier ALLOW/DENY objects to isolate the JWT test
   kubectl delete authorizationpolicy httpbin-header-gate allow-bar-everything -n foo --ignore-not-found
   kubectl apply -f jwt-testing.yaml -f require-jwt-group.yaml
   ```

3. Traé los dos tokens de demo y sondeá. `demo.jwt` lleva `groups: [group1, group2]`; el token simple (`groups-scope`? usá `demo.jwt` vs una cadena inválida):

   ```bash
   TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/demo.jwt)

   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "no token    -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "Authorization: Bearer $TOKEN" \
     -w "valid token -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "Authorization: Bearer bogus.token.value" \
     -w "bad token   -> %{http_code}\n" http://httpbin.foo:8000/headers
   ```

   Esperado:

   ```
   no token    -> 403
   valid token -> 200
   bad token   -> 401
   ```

> **Preguntas de checkpoint**
> - **Q6.1** Aparecen tres resultados: `401` para un token inválido, `403` para ningún token, `200` para uno bueno. ¿Qué componente produjo el `401` y cuál produjo el `403`? ¿Por qué "sin token" es un `403` acá y no un `401`?
> - **Q6.2** Si eliminás `require-jwt-group` pero mantenés `RequestAuthentication`, ¿qué pasa con (a) un request con un token **válido**, (b) un request con un token **inválido** y (c) un request **sin** token? Enunciá la regla exacta que esto demuestra.
> - **Q6.3** `requestPrincipals` se escribe `<issuer>/<subject>`. ¿En qué difiere conceptualmente de los `principals` que usaste en el Exercise 3, y puede una sola regla de política exigir legítimamente *tanto* un principal de workload como un request principal al mismo tiempo?

---

## Exercise 7 — Diagnose it: why did a request match (or not)?

Cuando una política se comporta mal, no adivines — inspeccioná la configuración compilada y los logs de aplicación.

1. Listá cada política que afecta a un pod específico, resuelta por la propia lógica de Istiod:

   ```bash
   istioctl experimental authz check "$FOO_CURL.foo"
   ```

   Obtenés una tabla de ACTION / nombre de política / workload coincidente — esto es el autoritativo "qué aplica acá", incluidas las políticas heredadas del root namespace.

2. Inspeccioná el filtro RBAC real que Envoy está corriendo (prueba qué se empujó, no lo que *creés* que aplicaste):

   ```bash
   HTTPBIN=$(kubectl get pod -l app=httpbin -n foo -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config listener "$HTTPBIN.foo" -o json \
     | grep -A3 -i '"name": "envoy.filters.http.rbac"' | head -n 20
   ```

3. Activá el logging de debug de RBAC y observá cómo se aplica un request denegado:

   ```bash
   istioctl proxy-config log "$HTTPBIN.foo" --level rbac:debug
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null http://httpbin.foo:8000/ip || true
   kubectl logs "$HTTPBIN" -n foo -c istio-proxy --tail=20 | grep -i rbac
   ```

   Deberías ver una línea `enforced denied` (o `shadow`) nombrando la política y la regla coincidentes.

> **Preguntas de checkpoint**
> - **Q7.1** `istioctl experimental authz check` lee la configuración de Envoy, mientras que `kubectl get authorizationpolicy` lee el estado deseado en `etcd`. Nombrá un modo de falla que solo el *primero* puede revelar.
> - **Q7.2** En el access log de RBAC ves las cadenas `rbac_access_policy` versus `rbac_access_shadow_policy`. ¿Qué significa una decisión `shadow`, qué `action` la produce, y cómo la usarías para desplegar un nuevo DENY de forma segura?
> - **Q7.3** Una política en `foo` "no hace nada" — el request no es ni recién permitido ni denegado. Dá dos configuraciones erróneas concretas (una en `selector`, otra en `apiVersion`/`namespace`) que hacen que una `AuthorizationPolicy` aplique silenciosamente a *ningún* workload, y cómo se manifiesta cada una en `authz check`.

---

## Cleanup

```bash
kubectl delete namespace foo bar
```

---

<details>
<summary><strong>Answers &amp; explanations</strong></summary>

**Q0.1** Es Istiod *no instalando* el filtro RBAC. Cuando ninguna `AuthorizationPolicy` selecciona un workload, Istiod omite por completo `envoy.filters.http.rbac` de la configuración de ese proxy, así que hay cero evaluación de RBAC por request y cero latencia añadida — el tráfico se permite simplemente porque nada lo inspecciona. Por lo tanto Istio **no** es deny‑by‑default a nivel del mesh; vos *optás por entrar* al deny‑by‑default instalando una política allow‑nothing (Exercise 1). La distinción importa porque "sin política = abierto" sorprende a quienes asumen que un service mesh está cerrado hasta que se le indique lo contrario.

**Q0.2** `principals`/`namespaces` se derivan del certificado de cliente mTLS verificado del peer (su identidad SPIFFE). Sin mTLS STRICT un request en texto plano no presenta **ningún** certificado, así que `source.principal`/`source.namespace` quedan vacíos y nunca pueden coincidir con un matcher no vacío — el request se deniega (si una ALLOW selecciona el workload) por el motivo equivocado, o, bajo PERMISSIVE, evade silenciosamente los chequeos de identidad. STRICT garantiza que cada request lleve una identidad criptográfica contra la cual coincidir.

**Q1.1** Un `spec` vacío es una política ALLOW (la acción por defecto) que no contiene **ninguna regla**; sin regla que coincidir, ningún request se permite jamás, así que el workload queda totalmente denegado — deny por ausencia de cualquier allow.

**Q1.2** Debe vivir en el **root namespace** (por defecto `istio-system`), que Istio trata como el alcance de política a nivel de todo el mesh. Para aplicar a todo el mesh **no** debés setear un `selector` (un selector lo restringiría a los workloads coincidentes *solo dentro del root namespace*, no del mesh). Una política sin selector en el root namespace aplica a todos los workloads en todos los namespaces.

**Q1.3** Un `spec:` en YAML con el valor omitido parsea a `null`, no a `{}`. `kubectl apply` envía `spec: null`; el API server lo completa por defecto, y el objeto resultante sigue comportándose como un ALLOW sin reglas (deny‑all) — pero apoyarse en el defaulting de `null` es frágil; escribí `spec: {}` explícitamente para que la intención sea inequívoca.

**Q2.1** En el momento en que **cualquier** política ALLOW selecciona un workload, ese workload pasa a deny‑by‑default *para los atributos que esas políticas gobiernan*: cada request debe coincidir con al menos una regla de al menos una política ALLOW, o se deniega. Eliminar `allow-nothing` no abrió `/get`, porque `httpbin-get` (que no lista `/get`) sigue siendo una ALLOW que selecciona `httpbin`, así que `/get` no coincide con nada y se deniega.

**Q2.2** **Unión.** Múltiples políticas ALLOW (y múltiples reglas dentro de una) se combinan con OR — un request se permite si coincide con cualquier regla de cualquier política ALLOW. En consecuencia, agregar una segunda ALLOW solo puede *ampliar* el acceso, nunca reducirlo; no podés endurecer apilando ALLOWs — endurecés con DENY o quitando reglas.

**Q2.3** Usá un prefijo: `paths: ["/api/*"]` (Istio soporta wildcards `*` de prefijo/sufijo). Advertencia: el matching de rutas opera sobre la ruta que Envoy ve. Si un gateway reescribe o si la normalización de rutas difiere, entradas del estilo `/api/../admin` o el doble encoding pueden burlar reglas de prefijo ingenuas — Istio documenta habilitar la normalización de rutas y advierte que el matching exacto vs prefijo interactúa con las reescrituras del gateway, así que autorá las políticas contra la ruta *post‑normalización*.

**Q3.1** `cluster.local` = trust domain; `ns/foo` = namespace `foo`; `sa/curl` = ServiceAccount `curl`. Es el SPIFFE ID `spiffe://cluster.local/ns/foo/sa/curl`, codificado en el SAN del certificado de cliente mTLS del workload y verificado por el sidecar del servidor durante el handshake TLS — ahí es donde viaja en el cable.

**Q3.2** Bajo PERMISSIVE un request en texto plano no tiene certificado, así que `source.principal`/`source.namespace` quedan vacíos; la ALLOW basada en principal no puede coincidir, así que el request se deniega — *o*, si además tuvieras una ruta allow‑all, se cuela sin identidad. Esa es la trampa: PERMISSIVE deja existir silenciosamente a peers no autenticados, y las reglas ALLOW basadas en identidad dan una falsa sensación de aplicación. Usá STRICT donde sea que te apoyes en principals.

**Q3.3** Semántica: **entre `rules` separadas** → OR (coincide cualquier regla). **Dentro de una regla, `from` AND `to` AND `when`** deben satisfacerse todos → AND. **Entre múltiples entradas de una lista `from`** (múltiples bloques `source`) → OR. **Entre múltiples valores dentro de un solo campo como `principals`** → OR. Así que una regla es "(cualquier source) AND (cualquier operación) AND (todas las condiciones)".

**Q4.1** El request debe ser HTTP y, en un mesh, típicamente sobre mTLS para que el sidecar pueda parsear los headers de L7. Las condiciones de header solo aplican a HTTP; si la política termina coincidiendo con un puerto TCP crudo, campos exclusivos de HTTP como `request.headers[...]`/`methods`/`paths` no son aplicables e Istio los ignora/corta en corto (una regla que exige un atributo exclusivo de HTTP no puede coincidir con tráfico TCP, denegándolo efectivamente bajo una ALLOW).

**Q4.2** Cualquier cliente que alcance el sidecar puede setear un header arbitrario, así que `x-team` no prueba nada sobre la identidad — es un control de conveniencia/segmentación, aceptable como condición AND extra sobre un control verificado. El gate real e infalsificable en esa política es `from.source.namespaces` (identidad verificada por mTLS). Nunca dejes que un header sea lo único entre un llamante y los datos.

**Q4.3** `source.ip` (clave de condición `source.ip` / `remoteIp`) — Istio distingue la dirección del peer conectado directamente de la dirección del cliente original (`remote.ip`, derivada de `X‑Forwarded‑For` cuando se configura `numTrustedProxies`/el gateway). Detrás de un gateway el peer conectado es la IP del gateway, mientras que la verdadera IP del cliente solo está en la cadena XFF — así que debés usar la clave del cliente original y configurar los saltos de proxy confiables, o coincidirás con el gateway en lugar del usuario.

**Q5.1** Orden por request: **CUSTOM** (autorizador externo) primero → si deniega, se detiene. Luego políticas **DENY** → si alguna coincide, deny. Luego políticas **ALLOW** → si una ALLOW selecciona el workload, el request debe coincidir con una, si no deny; si ninguna ALLOW lo selecciona, allow. **AUDIT** nunca afecta el resultado — solo registra.

**Q5.2** Ganó `deny-writes-from-bar`, porque DENY se evalúa antes que ALLOW y un DENY coincidente corta en corto a `403` sin importar ningún ALLOW. Lección: los dueños de plataforma/seguridad deberían tener los guardrails DENY (no pueden ser sobreescritos por el ALLOW de un equipo), mientras que los equipos individuales gestionan sus reglas ALLOW por servicio dentro de esos guardrails.

**Q5.3** `GET /ip` desde `bar`: fase DENY — `deny-writes-from-bar` coincide solo con `POST/PUT/DELETE`, así que `GET` **no** coincide → sin denegación. Fase ALLOW — `allow-bar-everything` coincide con el source `bar` sin restricción de operación → coincide → `200`. El GET se permite precisamente porque el DENY no coincidió *y* un ALLOW sí.

**Q6.1** El `401` viene de **`RequestAuthentication`** (el filtro de JWT) rechazando un token estructural/de firma inválido. El `403` viene del filtro RBAC de la **`AuthorizationPolicy`**. "Sin token" es `403` porque `RequestAuthentication` acepta la ausencia de un token (solo valida tokens *presentes*); el request luego llega a RBAC, no coincide con ninguna regla de `requestPrincipals`, y se deniega por autorización → `403`.

**Q6.2** Con solo `RequestAuthentication`: (a) token válido → **permitido**, (b) token inválido → **401 rechazado**, (c) sin token → **permitido**. Esto demuestra que `RequestAuthentication` por sí solo nunca *exige* un token — solo rechaza los malos. Para hacer que un token sea obligatorio debés agregar una `AuthorizationPolicy` sobre `requestPrincipals`.

**Q6.3** `principals` es una identidad de **workload/peer** de mTLS (SPIFFE ID en el certificado de cliente). `requestPrincipals` es una identidad de **usuario final** `<issuer>/<subject>` de un JWT validado. Sí — una sola regla puede poner `principals` y `requestPrincipals` en el mismo `source`, exigiendo ambos con AND: p. ej., "los llamados deben provenir del service account `gateway` *y* llevar un token de usuario final válido" (identidad de workload AND identidad de usuario).

**Q7.1** Solo inspeccionar la configuración de Envoy (`authz check` / `proxy-config`) revela casos en que una política existe en `etcd` pero **no fue empujada / no fue compilada** al proxy — p. ej., un `selector` que no coincide con nada, una política en el namespace equivocado, un lag de push xDS, o un CRD con version‑skew que Istiod rechazó. `kubectl get` muestra que el objeto existe; no puede decirte que el sidecar realmente lo está aplicando.

**Q7.2** Una decisión `shadow` es un **dry‑run**: la regla se evalúa y se registra pero **no se aplica**, producida por políticas anotadas para dry‑run (`istio.io/dry-run`). Desplegás un nuevo DENY en modo dry‑run, observás las líneas de log `rbac_access_shadow_policy` para ver exactamente qué *bloquearía*, confirmás que no atrapa tráfico legítimo, y luego quitás la anotación de dry‑run para aplicarlo — un rollout seguro y observable.

**Q7.3** (1) **Desajuste de `selector`** — las labels en `matchLabels` no coinciden con las labels de ningún pod (typo, `app` vs `service`); `authz check` simplemente no listará la política contra el workload, y `proxy-config` no muestra ninguna regla RBAC correspondiente. (2) **`namespace` / `apiVersion` equivocados** — el objeto aterrizó en `default` en lugar del namespace del workload, o usa un `apiVersion` obsoleto/inválido que el API server acepta en una version de grupo distinta, de modo que Istiod lo ignora; de nuevo `authz check` lo omite. Ambos se manifiestan como "el objeto existe en `kubectl get`, ausente de `authz check`", que es la pista de que está aplicando a cero workloads.

</details>