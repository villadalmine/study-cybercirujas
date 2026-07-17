# CKA 1.35 — 5.4: Use the Gateway API to manage Ingress traffic

> Peso en el examen: 3.33%
> Fuentes de referencia: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf), [Gateway API — sig-network](https://gateway-api.sigs.k8s.io/), [Envoy Gateway docs](https://gateway.envoyproxy.io/latest/)

Gateway API es el sucesor de Ingress: separa responsabilidades en tres roles (infrastructure provider → `GatewayClass`, cluster operator → `Gateway`, application developer → `HTTPRoute`/`GRPCRoute`), es extensible por diseño (no depende de annotations) y soporta features nativas como traffic splitting por weight, header/query matching y cross-namespace routing controlado.

En estos ejercicios vas a instalar las CRDs, desplegar un controlador (`Envoy Gateway`), y ejercitar los recursos `GatewayClass`, `Gateway` y `HTTPRoute` de punta a punta. Necesitás `kubectl`, `helm` y permisos de `cluster-admin`.

---

## Ejercicio 1 — Instalar las CRDs de Gateway API

1. Verificá si el clúster ya tiene las CRDs instaladas:
   ```bash
   kubectl get crd | grep gateway.networking.k8s.io
   ```
2. Si no aparecen, instalá el *standard channel* (recursos GA: `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`):
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   ```
3. Confirmá que quedaron instaladas y revisá el scope/versión servida:
   ```bash
   kubectl get crd -l gateway.networking.k8s.io/bundle-version
   kubectl explain gateway.spec
   kubectl explain httproute.spec.rules
   ```

**Preguntas:**
1. ¿Qué diferencia hay entre el *standard channel* y el *experimental channel* de las CRDs de Gateway API?
2. De los recursos instalados por `standard-install.yaml`, ¿cuáles ya son GA (`v1`) y cuál sigue en `v1beta1`?

---

## Ejercicio 2 — Desplegar un controlador (GatewayClass)

Una CRD sin un controlador que la implemente no enruta tráfico. Vamos a instalar Envoy Gateway como implementación.

1. Instalá el controlador vía Helm:
   ```bash
   helm install eg oci://docker.io/envoyproxy/gateway-helm \
     --version v1.2.0 \
     -n envoy-gateway-system --create-namespace
   ```
2. Esperá a que el deployment esté disponible:
   ```bash
   kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
   ```
3. Listá las `GatewayClass` (Envoy Gateway crea una llamada `eg` automáticamente) y verificá su estado:
   ```bash
   kubectl get gatewayclass
   kubectl describe gatewayclass eg
   ```

**Preguntas:**
1. ¿Qué campo de `spec` en una `GatewayClass` vincula ese objeto con un controlador específico?
2. Si `kubectl get gatewayclass` muestra `ACCEPTED=False`, ¿qué deberías revisar primero?

---

## Ejercicio 3 — Backends y Gateway

1. Creá el namespace de trabajo y las apps backend:
   ```bash
   kubectl create namespace gw-demo
   kubectl -n gw-demo create deployment web --image=nginxdemos/hello --replicas=2
   kubectl -n gw-demo expose deployment web --port=80
   kubectl -n gw-demo create deployment api --image=nginxdemos/hello --replicas=2
   kubectl -n gw-demo expose deployment api --port=80
   ```
2. Creá el `Gateway` que va a recibir el tráfico:
   ```yaml
   # gateway.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: demo-gateway
     namespace: gw-demo
   spec:
     gatewayClassName: eg
     listeners:
       - name: http
         protocol: HTTP
         port: 80
         allowedRoutes:
           namespaces:
             from: Same
   ```
   ```bash
   kubectl apply -f gateway.yaml
   ```
3. Verificá que el Gateway fue aceptado y programado por el controlador:
   ```bash
   kubectl -n gw-demo get gateway demo-gateway -o wide
   kubectl -n gw-demo describe gateway demo-gateway
   ```

**Preguntas:**
1. En `status.conditions` de un `Gateway`, ¿qué diferencia hay entre `Accepted` y `Programmed`?
2. ¿Qué controla `allowedRoutes.namespaces.from` en un listener, y qué otros valores puede tomar además de `Same`?

---

## Ejercicio 4 — HTTPRoute básico (host + path)

1. Creá un `HTTPRoute` que enrute por hostname hacia `web`:
   ```yaml
   # web-route.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: web-route
     namespace: gw-demo
   spec:
     parentRefs:
       - name: demo-gateway
     hostnames:
       - "web.example.local"
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: web
             port: 80
   ```
   ```bash
   kubectl apply -f web-route.yaml
   ```
2. Ubicá la `Service` que expone el proxy de Envoy Gateway y hacé port-forward:
   ```bash
   kubectl -n envoy-gateway-system get svc
   kubectl -n envoy-gateway-system port-forward svc/envoy-gw-demo-<sufijo> 8080:80
   ```
3. Probá el enrutamiento por hostname:
   ```bash
   curl -H "Host: web.example.local" http://localhost:8080/
   curl -H "Host: otro.example.local" http://localhost:8080/
   ```

**Preguntas:**
1. ¿Por qué la segunda llamada `curl` (con `Host: otro.example.local`) no llega al backend `web`?
2. ¿Qué campo del `HTTPRoute` referencia al `Gateway` al que se "adjunta" la ruta, y qué pasa si ese `Gateway` no existe?

---

## Ejercicio 5 — Enrutamiento por path a múltiples backends

1. Editá `web-route.yaml` para agregar una regla de path hacia `api`:
   ```yaml
   spec:
     parentRefs:
       - name: demo-gateway
     hostnames:
       - "web.example.local"
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /api
         backendRefs:
           - name: api
             port: 80
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: web
             port: 80
   ```
2. Aplicá y probá ambos paths:
   ```bash
   kubectl apply -f web-route.yaml
   curl -H "Host: web.example.local" http://localhost:8080/
   curl -H "Host: web.example.local" http://localhost:8080/api
   ```

**Preguntas:**
1. Escribiste la regla de `/api` después de la de `/` en el YAML, pero igual matchea correctamente antes que `/`. ¿Por qué el orden de declaración no determina la precedencia en `HTTPRoute`?
2. ¿Qué pasaría si dos reglas tuvieran el mismo `path.type: Exact` y el mismo `value`, apuntando a backends distintos?

---

## Ejercicio 6 — Traffic splitting (canary) con weights

1. Desplegá una segunda versión de `web`:
   ```bash
   kubectl -n gw-demo create deployment web-v2 --image=nginxdemos/hello --replicas=1
   kubectl -n gw-demo expose deployment web-v2 --port=80
   ```
2. Modificá la regla de `/` en `web-route.yaml` para repartir tráfico:
   ```yaml
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: web
             port: 80
             weight: 90
           - name: web-v2
             port: 80
             weight: 10
   ```
3. Aplicá y ejecutá varias requests para observar la distribución:
   ```bash
   kubectl apply -f web-route.yaml
   for i in $(seq 1 20); do curl -s -H "Host: web.example.local" http://localhost:8080/ | grep -i "server name"; done
   ```

**Preguntas:**
1. Si un `backendRef` no define `weight`, ¿qué valor toma por default y cómo afecta eso a la proporción calculada?
2. ¿Cómo harías un rollback inmediato del canary sin borrar el `Deployment web-v2`?

---

## Ejercicio 7 — Cross-namespace routing con ReferenceGrant

1. Creá un backend en otro namespace:
   ```bash
   kubectl create namespace billing
   kubectl -n billing create deployment reports --image=nginxdemos/hello
   kubectl -n billing expose deployment reports --port=80
   ```
2. Agregá una regla en `web-route.yaml` que referencia ese Service cruzando namespaces:
   ```yaml
       - matches:
           - path:
               type: PathPrefix
               value: /reports
         backendRefs:
           - name: reports
             namespace: billing
             port: 80
   ```
3. Aplicá y revisá el estado (va a fallar la resolución):
   ```bash
   kubectl apply -f web-route.yaml
   kubectl -n gw-demo describe httproute web-route
   ```
4. Autorizá el cruce con un `ReferenceGrant` en el namespace destino:
   ```yaml
   # referencegrant.yaml
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: ReferenceGrant
   metadata:
     name: allow-gw-demo-to-billing
     namespace: billing
   spec:
     from:
       - group: gateway.networking.k8s.io
         kind: HTTPRoute
         namespace: gw-demo
     to:
       - group: ""
         kind: Service
   ```
   ```bash
   kubectl apply -f referencegrant.yaml
   kubectl -n gw-demo describe httproute web-route
   ```

**Preguntas:**
1. Antes de aplicar el `ReferenceGrant`, ¿qué condition en `status.parents[].conditions` del `HTTPRoute` indica el problema, y qué valor toma?
2. ¿En qué namespace se crea el `ReferenceGrant`, el de origen (`gw-demo`) o el de destino (`billing`)? ¿Por qué ese diseño evita que un namespace "robe" tráfico de otro?

---

## Ejercicio 8 — TLS termination en el Gateway

1. Generá un certificado self-signed y guardalo como Secret:
   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout tls.key -out tls.crt -subj "/CN=web.example.local"
   kubectl -n gw-demo create secret tls web-tls --cert=tls.crt --key=tls.key
   ```
2. Agregá un listener HTTPS al `Gateway`:
   ```yaml
   spec:
     gatewayClassName: eg
     listeners:
       - name: http
         protocol: HTTP
         port: 80
         allowedRoutes:
           namespaces:
             from: Same
       - name: https
         protocol: HTTPS
         port: 443
         tls:
           mode: Terminate
           certificateRefs:
             - name: web-tls
         allowedRoutes:
           namespaces:
             from: Same
   ```
3. Aplicá y probá contra el puerto TLS (ajustando el port-forward a 443):
   ```bash
   kubectl apply -f gateway.yaml
   curl -k -H "Host: web.example.local" https://localhost:8443/
   ```

**Preguntas:**
1. ¿Qué diferencia hay entre `tls.mode: Terminate` y `tls.mode: Passthrough` en un listener de `Gateway`?
2. Si el Secret `web-tls` estuviera en un namespace distinto al del `Gateway`, ¿qué recurso adicional necesitarías?

---

## Ejercicio 9 — Troubleshooting de status conditions

1. Borrá temporalmente la `GatewayClass` para simular una falla de infraestructura:
   ```bash
   kubectl delete gatewayclass eg
   ```
2. Observá cómo se propaga el estado hacia abajo:
   ```bash
   kubectl -n gw-demo get gateway demo-gateway -o yaml | grep -A5 conditions
   kubectl -n gw-demo get httproute web-route -o yaml | grep -A5 conditions
   ```
3. Restaurá la `GatewayClass` y confirmá que todo vuelve a `True`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: eg
   spec:
     controllerName: gateway.envoyproxy.io/gatewayclass-controller
   ```
   ```bash
   kubectl apply -f -
   kubectl -n gw-demo get gateway,httproute
   ```

**Preguntas:**
1. ¿Por qué un `HTTPRoute` puede mostrar `Accepted: True` en su propio recurso pero seguir sin recibir tráfico real?
2. Nombrá los tres recursos, en orden, cuyo estado revisarías ante un fallo de enrutamiento (del más general al más específico).

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
1. El *standard channel* solo incluye recursos GA/beta estables (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`), aptos para producción. El *experimental channel* agrega recursos en `v1alpha2` como `TCPRoute`, `UDPRoute`, `TLSRoute` y campos experimentales, sujetos a cambios breaking.
2. `GatewayClass`, `Gateway`, `HTTPRoute` y `GRPCRoute` son `v1` (GA). `ReferenceGrant` sigue en `v1beta1`.

**Ejercicio 2**
1. `spec.controllerName`: un string reverse-DNS que el controlador reconoce para decidir si esa `GatewayClass` le pertenece.
2. Revisar que el controlador (Envoy Gateway) esté corriendo y sano (`kubectl get pods -n envoy-gateway-system`), y los eventos/condition `message` de la `GatewayClass` con `kubectl describe`.

**Ejercicio 3**
1. `Accepted` indica que el controlador validó la sintaxis/semántica del `Gateway` (listeners válidos, `GatewayClass` existente). `Programmed` indica que el data plane (proxy real) ya fue configurado y está listo para servir tráfico — pueden estar desfasados en el tiempo.
2. Controla desde qué namespaces se pueden adjuntar `HTTPRoute`s a ese listener. Valores posibles: `Same` (solo el mismo namespace del Gateway), `All` (cualquier namespace) y `Selector` (namespaces que matcheen un `labelSelector`).

**Ejercicio 4**
1. Porque el listener del `Gateway` no restringe hostname, pero el `HTTPRoute` sí declara `hostnames: ["web.example.local"]`; una request con otro `Host` header no matchea ninguna regla del route y el proxy devuelve 404.
2. `spec.parentRefs`. Si el `Gateway` referenciado no existe, el `HTTPRoute` queda con la condition `Accepted: False` (reason `NoMatchingParent` o similar) en `status.parents`, y no se programa ninguna ruta real.

**Ejercicio 5**
1. Porque Gateway API define precedencia por especificidad, no por orden de aparición: `Exact` > `PathPrefix` más largo > `PathPrefix` más corto > matches con `Headers`/`Method` adicionales como desempate. El controlador reordena las reglas internamente al programar el proxy.
2. Es un conflicto no determinístico: la spec dice que la implementación puede elegir cualquiera de los dos (o rechazar el conflicto), y debería reflejarlo con una condition de warning; no hay garantía de cuál gana.

**Ejercicio 6**
1. El default es `weight: 1`. Si `web` tiene `weight: 90` y `web-v2` no define weight, `web-v2` toma `1`, y la proporción real sería 90:1 (≈98.9%/1.1%), no 90:10 como uno esperaría.
2. Editando el `HTTPRoute` para que la regla de `/` tenga un único `backendRef` (`web`, sin `web-v2`) o poniendo `weight: 0` en `web-v2` — no hace falta tocar el `Deployment`.

**Ejercicio 7**
1. `ResolvedRefs: False`, típicamente con reason `RefNotPermitted`, indicando que el backend referenciado en otro namespace no está autorizado.
2. Se crea en el namespace **destino** (`billing`, donde vive el `Service`). Este diseño invierte el control: el dueño del recurso referenciado es quien autoriza explícitamente quién puede apuntarle, evitando que cualquier `HTTPRoute` de otro namespace "robe" tráfico hacia servicios ajenos sin consentimiento.

**Ejercicio 8**
1. `Terminate` descifra el TLS en el Gateway (usando el certificado del Secret) y reenvía el tráfico en texto plano (o re-encriptado) al backend; `Passthrough` reenvía los bytes TLS sin descifrar, dejando la terminación al backend — en ese modo el routing solo puede basarse en SNI, no en paths ni headers HTTP.
2. Un `ReferenceGrant` en el namespace donde vive el Secret, autorizando a `Gateway` (`group: gateway.networking.k8s.io`) a referenciar `Secret`s desde el namespace del `Gateway`.

**Ejercicio 9**
1. Porque `Accepted` en el `HTTPRoute` solo valida su propia sintaxis y que el `parentRef` exista; si el `Gateway` padre (o su `GatewayClass`) no está `Programmed`, el proxy real nunca recibe la configuración aunque el `HTTPRoute` "parezca" válido.
2. `GatewayClass` → `Gateway` → `HTTPRoute` (del más general/infraestructura al más específico/aplicación).

</details>